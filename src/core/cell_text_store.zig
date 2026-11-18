//! The CPU side of every surface's iCellText texture, shared by both
//! frontends: one store per texture, keyed like the cell-age stores
//! (`Row.grid`) — 1 for the main window's screen-space cells, otherwise the
//! grid id of an external window, indexed by that grid.
//!
//! The core thread writes it from on_cell_text_row, one row at a time as the
//! flush sends that row's vertices, into a staging copy; the frontend commits
//! the staged rows from on_flush_end together with the vertices they
//! describe, or discards them with a refused flush, so a frame never samples
//! text its rows do not show yet. A row the flush does not resend keeps its
//! codepoints, the same contract as on_vertices_row. `mu` is a leaf: nothing
//! under it calls out except the caller's own upload between `sync` and
//! `endUpload`.

const std = @import("std");
const clock = @import("clock.zig");

/// One row of codepoints for one texture. Layout matches
/// `zonvie_cell_text_row` in `include/zonvie_core.h`.
pub const Row = extern struct {
    /// 1 = the main window's texture, else an external window's grid id.
    grid: i64,
    /// The texture's cell grid. A change starts the texture blank, which is
    /// safe because the core resends every row of the surface with it; the
    /// blank grid is published with the flush that fills it.
    tex_rows: u32,
    tex_cols: u32,
    /// Where `cps` lands on the texture: a composited float's row is offset
    /// by its win_pos, a grid in its own font's row sits in its band below
    /// the root's rows.
    row: u32,
    col: u32,
    count: u32,
    _pad: u32 = 0,
    cps: [*]const u32,
};

/// Textures whose clean frames skip the lock. A store past this many still
/// works, through the locked path every frame.
const slot_count: usize = 16;
const no_slot: u32 = std.math.maxInt(u32);

const Store = struct {
    grid: i64,
    slot: u32 = no_slot,
    cols: u32 = 0,
    rows: u32 = 0,
    values: []u32 = &.{},
    /// A new cell grid the flush in progress writes, blank but for its staged
    /// rows: commit makes it `values`. Until then a draw sees only the
    /// committed grid, which pairs with the committed rows.
    pending: []u32 = &.{},
    pending_cols: u32 = 0,
    pending_rows: u32 = 0,
    /// Rows written since the last commit, at the cell grid they were
    /// written for (`pending`'s when there is one), and which rows they are.
    staged: []u32 = &.{},
    staged_rows: std.DynamicBitSetUnmanaged = .{},
    any_staged: bool = false,
    dirty: bool = false,

    fn stagedCols(st: *const Store) u32 {
        return if (st.pending_cols != 0) st.pending_cols else st.cols;
    }

    fn stagedRows(st: *const Store) u32 {
        return if (st.pending_cols != 0) st.pending_rows else st.rows;
    }
};

pub const SyncResult = enum(i32) {
    /// No texture can be bound: no flush has committed a row yet, or out of
    /// memory.
    unavailable = 0,
    /// The texture already holds the mirror.
    clean = 1,
    /// `values` must be uploaded at `cache.cols` x `cache.rows`; `mu` stays
    /// held until `endUpload`.
    dirty = 2,
};

/// What one texture's owner saw at its last `sync`; see cell_age_store.
pub const SyncCache = extern struct {
    version: u64 = 0,
    slot: u32 = 0,
    cols: u32 = 0,
    rows: u32 = 0,
};

pub const Stores = struct {
    alloc: std.mem.Allocator,
    mu: std.Io.Mutex = .init,
    slot_versions: [slot_count]std.atomic.Value(u64) = @splat(.init(1)),
    slot_used: [slot_count]bool = @splat(false),
    stores: std.ArrayListUnmanaged(Store) = .empty,

    pub fn init(alloc: std.mem.Allocator) Stores {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *Stores) void {
        for (self.stores.items) |*st| self.freeValues(st);
        self.stores.deinit(self.alloc);
        self.* = undefined;
    }

    /// Stage one row. Core thread. Allocates only when the texture's cell
    /// grid changes (a resize), never per row.
    pub fn applyRow(self: *Stores, r: Row) void {
        if (r.tex_rows == 0 or r.tex_cols == 0 or r.count == 0) return;
        self.lock();
        defer self.unlock();
        const st = self.sized(r.grid, r.tex_cols, r.tex_rows) orelse return;
        const cols = st.stagedCols();
        if (r.row >= st.stagedRows() or r.col >= cols) return;
        const n: usize = @min(@as(usize, r.count), @as(usize, cols - r.col));
        const base: usize = @as(usize, r.row) * cols + r.col;
        // A row's first write of a flush starts from what the texture shows,
        // so a partial row (a float's run) keeps the cells around it; on a
        // new cell grid, from blank.
        if (!st.staged_rows.isSet(r.row)) {
            const row_base: usize = @as(usize, r.row) * cols;
            const dst = st.staged[row_base .. row_base + cols];
            if (st.pending_cols != 0) @memset(dst, 0) else @memcpy(dst, st.values[row_base .. row_base + cols]);
            st.staged_rows.set(r.row);
            st.any_staged = true;
        }
        @memcpy(st.staged[base .. base + n], r.cps[0..n]);
    }

    /// Publish `grid`'s staged rows: the flush that wrote them committed.
    /// Core thread, from the surface's own commit, under the lock its draw
    /// snapshots rows and syncs this texture with, so a frame never pairs
    /// one flush's rows with another's text.
    pub fn commit(self: *Stores, grid: i64) void {
        self.lock();
        defer self.unlock();
        for (self.stores.items) |*st| {
            if (st.grid != grid) continue;
            if (st.pending_cols != 0) {
                self.publishPending(st);
                continue;
            }
            if (!st.any_staged) continue;
            var changed = false;
            var it = st.staged_rows.iterator(.{});
            while (it.next()) |r| {
                const base: usize = r * st.cols;
                const src = st.staged[base .. base + st.cols];
                const dst = st.values[base .. base + st.cols];
                if (std.mem.eql(u32, dst, src)) continue;
                @memcpy(dst, src);
                changed = true;
            }
            st.staged_rows.unsetAll();
            st.any_staged = false;
            if (changed) {
                st.dirty = true;
                self.bump(st);
            }
        }
    }

    /// Make the pending cell grid, with the staged rows written into it, the
    /// committed one. Allocates nothing: sized() made the buffer.
    fn publishPending(self: *Stores, st: *Store) void {
        const cols = st.pending_cols;
        var it = st.staged_rows.iterator(.{});
        while (it.next()) |r| {
            const base: usize = r * cols;
            @memcpy(st.pending[base .. base + cols], st.staged[base .. base + cols]);
        }
        st.staged_rows.unsetAll();
        st.any_staged = false;
        if (st.values.len != 0) self.alloc.free(st.values);
        st.values = st.pending;
        st.cols = cols;
        st.rows = st.pending_rows;
        st.pending = &.{};
        st.pending_cols = 0;
        st.pending_rows = 0;
        st.dirty = true;
        self.bump(st);
    }

    /// Drop every staged row: the flush that wrote them was refused, and
    /// its rows will be sent again. A pending cell grid stays pending: the
    /// retry writes the same one.
    pub fn discard(self: *Stores) void {
        self.lock();
        defer self.unlock();
        for (self.stores.items) |*st| {
            if (!st.any_staged) continue;
            st.staged_rows.unsetAll();
            st.any_staged = false;
        }
    }

    /// Report whether `grid`'s texture needs an upload. `force` marks the
    /// mirror dirty first, for a texture that was just created and holds
    /// garbage. On `.dirty`, `out_values` is the mirror and `mu` is held
    /// until `endUpload`. Drawing thread.
    pub inline fn sync(self: *Stores, grid: i64, force: bool, cache: *SyncCache, out_values: *[]const u32) SyncResult {
        if (!force and cache.slot < slot_count and cache.cols > 0 and
            cache.version == self.slot_versions[cache.slot].load(.acquire)) return .clean;
        return self.syncLocked(grid, force, cache, out_values);
    }

    noinline fn syncLocked(self: *Stores, grid: i64, force: bool, cache: *SyncCache, out_values: *[]const u32) SyncResult {
        self.lock();
        const st = self.find(grid) orelse {
            cache.* = .{};
            self.unlock();
            return .unavailable;
        };
        if (st.cols == 0) {
            cache.* = .{};
            self.unlock();
            return .unavailable;
        }
        cache.* = .{
            .version = if (st.slot != no_slot) self.slot_versions[st.slot].load(.monotonic) else 0,
            .slot = st.slot,
            .cols = st.cols,
            .rows = st.rows,
        };
        if (force) st.dirty = true;
        if (!st.dirty) {
            self.unlock();
            return .clean;
        }
        st.dirty = false;
        out_values.* = st.values;
        return .dirty;
    }

    pub fn endUpload(self: *Stores) void {
        self.unlock();
    }

    /// Forget an external window's store when that window goes away.
    pub fn drop(self: *Stores, grid: i64) void {
        self.lock();
        defer self.unlock();
        for (self.stores.items, 0..) |*st, i| {
            if (st.grid != grid) continue;
            self.release(st);
            _ = self.stores.swapRemove(i);
            break;
        }
    }

    pub fn removeAll(self: *Stores) void {
        self.lock();
        defer self.unlock();
        for (self.stores.items) |*st| self.release(st);
        self.stores.clearRetainingCapacity();
    }

    fn find(self: *Stores, grid: i64) ?*Store {
        for (self.stores.items) |*st| {
            if (st.grid == grid) return st;
        }
        return null;
    }

    fn sized(self: *Stores, grid: i64, cols: u32, rows: u32) ?*Store {
        const st = self.find(grid) orelse blk: {
            const st = self.stores.addOne(self.alloc) catch return null;
            st.* = .{ .grid = grid };
            for (&self.slot_used, 0..) |*used, i| {
                if (used.*) continue;
                used.* = true;
                st.slot = @intCast(i);
                break;
            }
            break :blk st;
        };
        if (st.stagedCols() == cols and st.stagedRows() == rows) return st;
        // A new cell grid waits in `pending` for the commit: a draw before it
        // keeps the texture it has, which still pairs with the committed rows.
        const n: usize = @as(usize, cols) * @as(usize, rows);
        const buf = self.alloc.alloc(u32, n) catch return null;
        const staged = self.alloc.alloc(u32, n) catch {
            self.alloc.free(buf);
            return null;
        };
        var bits = std.DynamicBitSetUnmanaged.initEmpty(self.alloc, rows) catch {
            self.alloc.free(buf);
            self.alloc.free(staged);
            return null;
        };
        @memset(buf, 0);
        @memset(staged, 0);
        if (st.pending.len != 0) self.alloc.free(st.pending);
        if (st.staged.len != 0) self.alloc.free(st.staged);
        st.staged_rows.deinit(self.alloc);
        st.pending = buf;
        st.pending_cols = cols;
        st.pending_rows = rows;
        st.staged = staged;
        st.staged_rows = bits;
        bits = .{};
        st.any_staged = false;
        return st;
    }

    fn freeValues(self: *Stores, st: *Store) void {
        if (st.values.len != 0) self.alloc.free(st.values);
        if (st.pending.len != 0) self.alloc.free(st.pending);
        st.pending = &.{};
        st.pending_cols = 0;
        st.pending_rows = 0;
        if (st.staged.len != 0) self.alloc.free(st.staged);
        st.staged_rows.deinit(self.alloc);
        st.values = &.{};
        st.staged = &.{};
        st.staged_rows = .{};
        st.any_staged = false;
        st.cols = 0;
        st.rows = 0;
    }

    fn bump(self: *Stores, st: *const Store) void {
        if (st.slot != no_slot) _ = self.slot_versions[st.slot].fetchAdd(1, .release);
    }

    fn release(self: *Stores, st: *Store) void {
        self.freeValues(st);
        if (st.slot == no_slot) return;
        self.bump(st);
        self.slot_used[st.slot] = false;
        st.slot = no_slot;
    }

    fn lock(self: *Stores) void {
        self.mu.lockUncancelable(clock.io());
    }

    fn unlock(self: *Stores) void {
        self.mu.unlock(clock.io());
    }
};

const testing = std.testing;

fn row(grid: i64, tex_rows: u32, tex_cols: u32, r: u32, c: u32, cps: []const u32) Row {
    return .{ .grid = grid, .tex_rows = tex_rows, .tex_cols = tex_cols, .row = r, .col = c, .count = @intCast(cps.len), .cps = cps.ptr };
}

/// Stage one row and commit it, as a flush the frontend accepted does.
fn put(s: *Stores, r: Row) void {
    s.applyRow(r);
    s.commit(r.grid);
}

/// A fresh cache per call: always the locked path, as on a first frame.
fn syncValues(s: *Stores, grid: i64) ?[]const u32 {
    var cache: SyncCache = .{};
    var v: []const u32 = &.{};
    return switch (s.sync(grid, false, &cache, &v)) {
        .dirty => blk: {
            s.endUpload();
            break :blk v;
        },
        else => null,
    };
}

test "rows land on the texture their grid names and unsent rows keep their text" {
    var s = Stores.init(testing.allocator);
    defer s.deinit();
    var cache: SyncCache = .{};
    var v: []const u32 = &.{};
    try testing.expectEqual(SyncResult.unavailable, s.sync(1, false, &cache, &v));
    put(&s, row(1, 2, 3, 0, 0, &.{ 'a', 'b', 'c' }));
    put(&s, row(1, 2, 3, 1, 1, &.{ 'x', 'y' }));
    put(&s, row(7, 1, 2, 0, 0, &.{ 'q', 'r' }));
    try testing.expectEqualSlices(u32, &.{ 'a', 'b', 'c', 0, 'x', 'y' }, syncValues(&s, 1).?);
    try testing.expectEqualSlices(u32, &.{ 'q', 'r' }, syncValues(&s, 7).?);
    // Resending row 1 leaves row 0 as it was.
    put(&s, row(1, 2, 3, 1, 0, &.{ 'd', 'e', 'f' }));
    try testing.expectEqualSlices(u32, &.{ 'a', 'b', 'c', 'd', 'e', 'f' }, syncValues(&s, 1).?);
}

test "a row is clipped to the texture and one past its edge is dropped" {
    var s = Stores.init(testing.allocator);
    defer s.deinit();
    put(&s, row(1, 1, 3, 0, 2, &.{ 'a', 'b', 'c' }));
    put(&s, row(1, 1, 3, 0, 3, &.{'z'}));
    put(&s, row(1, 1, 3, 1, 0, &.{'z'}));
    try testing.expectEqualSlices(u32, &.{ 0, 0, 'a' }, syncValues(&s, 1).?);
}

test "a cached sync stays clean until the text changes; a resize starts blank" {
    var s = Stores.init(testing.allocator);
    defer s.deinit();
    var cache: SyncCache = .{};
    var v: []const u32 = &.{};
    put(&s, row(1, 1, 2, 0, 0, &.{ 'a', 'b' }));
    try testing.expectEqual(SyncResult.dirty, s.sync(1, false, &cache, &v));
    s.endUpload();
    try testing.expectEqual(@as(u32, 2), cache.cols);
    try testing.expectEqual(SyncResult.clean, s.sync(1, false, &cache, &v));
    // The same text again is not a change: the frame stays lock-free.
    put(&s, row(1, 1, 2, 0, 0, &.{ 'a', 'b' }));
    try testing.expectEqual(cache.version, s.slot_versions[cache.slot].load(.monotonic));
    try testing.expectEqual(SyncResult.clean, s.sync(1, false, &cache, &v));
    put(&s, row(1, 1, 2, 0, 1, &.{'c'}));
    try testing.expectEqual(SyncResult.dirty, s.sync(1, false, &cache, &v));
    try testing.expectEqualSlices(u32, &.{ 'a', 'c' }, v);
    s.endUpload();
    // force re-uploads a clean mirror, for a texture just (re)created.
    try testing.expectEqual(SyncResult.dirty, s.sync(1, true, &cache, &v));
    s.endUpload();
    // A new cell grid is a new, blank texture; the row written with it stays.
    put(&s, row(1, 2, 2, 1, 0, &.{ 'd', 'e' }));
    try testing.expectEqual(SyncResult.dirty, s.sync(1, false, &cache, &v));
    try testing.expectEqualSlices(u32, &.{ 0, 0, 'd', 'e' }, v);
    s.endUpload();
    try testing.expectEqual(@as(u32, 2), cache.rows);
}

test "a dropped grid is forgotten and its slot's old cache is turned away" {
    var s = Stores.init(testing.allocator);
    defer s.deinit();
    var cache: SyncCache = .{};
    var v: []const u32 = &.{};
    put(&s, row(7, 1, 1, 0, 0, &.{'a'}));
    try testing.expectEqual(SyncResult.dirty, s.sync(7, false, &cache, &v));
    s.endUpload();
    s.drop(7);
    try testing.expectEqual(SyncResult.unavailable, s.sync(7, false, &cache, &v));
    put(&s, row(7, 1, 1, 0, 0, &.{'b'}));
    try testing.expectEqualSlices(u32, &.{'b'}, syncValues(&s, 7).?);
}

test "staged rows reach the texture on commit and vanish on discard" {
    var s = Stores.init(testing.allocator);
    defer s.deinit();
    put(&s, row(1, 1, 4, 0, 0, &.{ 'a', 'b', 'c', 'd' }));
    var cache: SyncCache = .{};
    var v: []const u32 = &.{};
    try testing.expectEqual(SyncResult.dirty, s.sync(1, false, &cache, &v));
    s.endUpload();
    // Mid-flush the frame must keep showing the committed text.
    s.applyRow(row(1, 1, 4, 0, 1, &.{ 'X', 'Y' }));
    try testing.expectEqual(SyncResult.clean, s.sync(1, false, &cache, &v));
    s.discard();
    try testing.expectEqual(SyncResult.clean, s.sync(1, false, &cache, &v));
    // A float's run over a row keeps the cells beside it.
    s.applyRow(row(1, 1, 4, 0, 2, &.{'Z'}));
    s.commit(1);
    try testing.expectEqualSlices(u32, &.{ 'a', 'b', 'Z', 'd' }, syncValues(&s, 1).?);
    // Two runs on one row within a flush land together.
    s.applyRow(row(1, 1, 4, 0, 0, &.{ 'p', 'q', 'r', 's' }));
    s.applyRow(row(1, 1, 4, 0, 3, &.{'t'}));
    s.commit(1);
    try testing.expectEqualSlices(u32, &.{ 'p', 'q', 'r', 't' }, syncValues(&s, 1).?);
}

test "a new cell grid is published with the flush that fills it, not before" {
    var s = Stores.init(testing.allocator);
    defer s.deinit();
    put(&s, row(1, 1, 2, 0, 0, &.{ 'a', 'b' }));
    var cache: SyncCache = .{};
    var v: []const u32 = &.{};
    try testing.expectEqual(SyncResult.dirty, s.sync(1, false, &cache, &v));
    s.endUpload();
    // A band appears: the first row of the flush carries the taller plane.
    // Until the flush commits, a frame keeps the texture it has.
    s.applyRow(row(1, 2, 2, 0, 0, &.{ 'a', 'b' }));
    try testing.expectEqual(SyncResult.clean, s.sync(1, false, &cache, &v));
    try testing.expectEqual(@as(u32, 1), cache.rows);
    // A refused flush leaves it so; the retry publishes the new plane even
    // where its rows match the blank mirror.
    s.discard();
    try testing.expectEqual(SyncResult.clean, s.sync(1, false, &cache, &v));
    s.applyRow(row(1, 2, 2, 1, 0, &.{ 0, 0 }));
    s.commit(1);
    try testing.expectEqual(SyncResult.dirty, s.sync(1, false, &cache, &v));
    try testing.expectEqual(@as(u32, 2), cache.rows);
    s.endUpload();
    // Published once: an unchanged flush after it stays clean.
    s.applyRow(row(1, 2, 2, 1, 0, &.{ 0, 0 }));
    s.commit(1);
    try testing.expectEqual(SyncResult.clean, s.sync(1, false, &cache, &v));
}

test "a commit not yet uploaded still shows its own text when the next flush starts a new cell grid" {
    var s = Stores.init(testing.allocator);
    defer s.deinit();
    var cache: SyncCache = .{};
    var v: []const u32 = &.{};
    put(&s, row(1, 1, 2, 0, 0, &.{ 'a', 'b' }));
    try testing.expectEqual(SyncResult.dirty, s.sync(1, false, &cache, &v));
    s.endUpload();
    // Flush N commits; no draw uploads it before flush N+1 resizes.
    put(&s, row(1, 1, 2, 0, 0, &.{ 'c', 'd' }));
    s.applyRow(row(1, 2, 2, 0, 0, &.{ 'e', 'f' }));
    try testing.expectEqual(SyncResult.dirty, s.sync(1, false, &cache, &v));
    try testing.expectEqualSlices(u32, &.{ 'c', 'd' }, v);
    s.endUpload();
    try testing.expectEqual(@as(u32, 1), cache.rows);
    // A texture made now (force) gets the committed grid too.
    try testing.expectEqual(SyncResult.dirty, s.sync(1, true, &cache, &v));
    try testing.expectEqualSlices(u32, &.{ 'c', 'd' }, v);
    s.endUpload();
    // A refused flush keeps it; the retry publishes the new grid whole.
    s.discard();
    try testing.expectEqual(SyncResult.clean, s.sync(1, false, &cache, &v));
    s.applyRow(row(1, 2, 2, 1, 0, &.{ 'g', 'h' }));
    s.commit(1);
    try testing.expectEqual(SyncResult.dirty, s.sync(1, false, &cache, &v));
    try testing.expectEqualSlices(u32, &.{ 0, 0, 'g', 'h' }, v);
    s.endUpload();
}

test "no texture is offered before a flush commits the first row" {
    var s = Stores.init(testing.allocator);
    defer s.deinit();
    var cache: SyncCache = .{};
    var v: []const u32 = &.{};
    s.applyRow(row(1, 1, 2, 0, 0, &.{ 'a', 'b' }));
    try testing.expectEqual(SyncResult.unavailable, s.sync(1, true, &cache, &v));
    s.commit(1);
    try testing.expectEqual(SyncResult.dirty, s.sync(1, false, &cache, &v));
    try testing.expectEqualSlices(u32, &.{ 'a', 'b' }, v);
    s.endUpload();
}
