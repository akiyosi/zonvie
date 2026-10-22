//! Per-grid row vertices for one surface, staged by the core thread inside
//! a flush and published at on_flush_end. `back` is touched only by the core
//! thread; `front` only under App.mu. commit swaps exactly the rows sent this
//! flush, so a row not resent keeps its committed contents.

const std = @import("std");
const core = @import("zonvie_core");
const Vertex = core.Vertex;
const grid_ease = @import("grid_ease.zig");
pub const ScrollInput = grid_ease.ScrollInput;

pub const Row = struct {
    verts: std.ArrayListUnmanaged(Vertex) = .empty,
};

/// `total_rows` is the grid's row count the scroll was made at.
const Shift = struct { row_start: u32, row_end: u32, rows_delta: i32, total_rows: u32 };

pub const GridRows = struct {
    front: std.ArrayListUnmanaged(Row) = .empty,
    back: std.ArrayListUnmanaged(Row) = .empty,
    dirty: std.DynamicBitSetUnmanaged = .{},
    /// Row count the staged flush will publish; null when unchanged.
    staged_len: ?u32 = null,
    staged_clear: bool = false,
    /// The core sends at most one shift per grid per flush (zonvie_core.h).
    staged_shift: ?Shift = null,
    ease: grid_ease.GridEase = .{},

    pub fn deinit(self: *GridRows, alloc: std.mem.Allocator) void {
        self.ease.deinit(alloc);
        for (self.front.items) |*r| r.verts.deinit(alloc);
        for (self.back.items) |*r| r.verts.deinit(alloc);
        self.front.deinit(alloc);
        self.back.deinit(alloc);
        self.dirty.deinit(alloc);
    }

    fn ensureBack(self: *GridRows, alloc: std.mem.Allocator, len: usize) !void {
        while (self.back.items.len < len) try self.back.append(alloc, .{});
        if (self.dirty.bit_length < len) try self.dirty.resize(alloc, len, false);
    }

    pub fn stageRow(self: *GridRows, alloc: std.mem.Allocator, row: u32, verts: []const Vertex, total_rows: u32) !void {
        // total_rows == 0 carries no row count (frontend_rules.zig:116, :151-152):
        // the row is still content, and the length only grows to hold it.
        const len: u32 = if (total_rows != 0) total_rows else @max(self.staged_len orelse @as(u32, @intCast(self.front.items.len)), row + 1);
        self.staged_len = len;
        if (row >= len) return;
        try self.ensureBack(alloc, len);
        const dst = &self.back.items[row].verts;
        dst.clearRetainingCapacity();
        try dst.appendSlice(alloc, verts);
        self.dirty.set(row);
    }

    pub fn stageShift(self: *GridRows, row_start: u32, row_end: u32, rows_delta: i32, total_rows: u32) void {
        self.staged_shift = .{ .row_start = row_start, .row_end = row_end, .rows_delta = rows_delta, .total_rows = total_rows };
    }

    pub fn stageClear(self: *GridRows) void {
        self.staged_clear = true;
        self.staged_len = 0;
    }

    pub fn cancel(self: *GridRows) void {
        self.dirty.unsetAll();
        self.staged_len = null;
        self.staged_clear = false;
        self.staged_shift = null;
    }

    /// Caller holds App.mu. The only fallible step of a commit; on error the caller cancels and `front` is untouched.
    pub fn prepareCommit(self: *GridRows, alloc: std.mem.Allocator) !void {
        if (self.staged_clear) return;
        const len: usize = self.staged_len orelse self.front.items.len;
        try self.front.ensureTotalCapacity(alloc, len);
    }

    /// Caller holds App.mu; prepareCommit must have succeeded since the last
    /// stage. `eases` says whether this grid's scrolls animate.
    pub fn commit(self: *GridRows, alloc: std.mem.Allocator, eases: bool, in: ScrollInput) void {
        defer self.cancel();
        if (self.staged_clear) {
            for (self.front.items) |*r| r.verts.deinit(alloc);
            self.front.clearRetainingCapacity();
            self.ease.spring.reset();
            self.ease.dropRetained();
            return;
        }
        const len: usize = self.staged_len orelse self.front.items.len;
        if (self.staged_shift) |s| {
            self.ease.beforeShift(s.row_start, s.row_end, s.rows_delta, in);
            if (self.applyShift(s, in.row_h_px)) |end| {
                // A scroll made at another size cannot be given back.
                if (eases and s.total_rows == len) {
                    self.ease.seedAndRetain(self.front.items, s.row_start, end, s.rows_delta, in);
                } else {
                    self.ease.spring.reset();
                    self.ease.dropRetained();
                }
            }
        }
        while (self.front.items.len < len) self.front.appendAssumeCapacity(.{});
        while (self.front.items.len > len) {
            var r = self.front.pop().?;
            r.verts.deinit(alloc);
        }
        var it = self.dirty.iterator(.{});
        while (it.next()) |i| {
            if (i >= len) break;
            std.mem.swap(Row, &self.front.items[i], &self.back.items[i]);
        }
    }

    /// Rotates the region and rebases every row in it by the distance it
    /// moved, so committed vertices always sit at their current row. Returns
    /// the clamped region end, or null when nothing moved.
    fn applyShift(self: *GridRows, s: Shift, row_h_px: u32) ?u32 {
        const end = @min(s.row_end, @as(u32, @intCast(self.front.items.len)));
        if (s.row_start >= end) return null;
        const region = self.front.items[s.row_start..end];
        const n: usize = @intCast(@abs(s.rows_delta));
        if (n >= region.len) return null;
        // rows_delta > 0: content moves up (row i takes row i+n); matches
        // windows/render_pipeline_helpers.zig rotateRegion.
        if (s.rows_delta > 0) std.mem.rotate(Row, region, n) else std.mem.rotate(Row, region, region.len - n);
        const dy: f32 = @floatFromInt(-s.rows_delta * @as(i32, @intCast(row_h_px)));
        for (region) |*r| grid_ease.moveVerts(r.verts.items, dy);
        return end;
    }

    pub fn committedRows(self: *const GridRows) []const Row {
        return self.front.items;
    }

    pub fn retainedRows(self: *const GridRows) []const grid_ease.RetainedRow {
        return &self.ease.retained;
    }
};

/// One surface's layer list, staged like the rows.
pub const Layers = struct {
    front: std.ArrayListUnmanaged(core.Layer) = .empty,
    back: std.ArrayListUnmanaged(core.Layer) = .empty,
    staged: bool = false,

    fn deinit(self: *Layers, alloc: std.mem.Allocator) void {
        self.front.deinit(alloc);
        self.back.deinit(alloc);
    }

    fn stage(self: *Layers, alloc: std.mem.Allocator, layers: []const core.Layer) !void {
        self.back.clearRetainingCapacity();
        try self.back.appendSlice(alloc, layers);
        self.staged = true;
    }

    fn commit(self: *Layers) void {
        if (!self.staged) return;
        std.mem.swap(std.ArrayListUnmanaged(core.Layer), &self.front, &self.back);
        self.staged = false;
    }

    fn has(self: *const Layers, grid_id: i64) bool {
        for (self.front.items) |l| if (l.grid_id == grid_id) return true;
        return false;
    }
};

pub const SurfaceStore = struct {
    grids: std.AutoHashMapUnmanaged(i64, *GridRows) = .empty,
    /// Surface 1, the main window.
    main: Layers = .{},
    /// External surfaces by root grid id. Opened and closed immediately
    /// (on_external_window is not transactional); their layers are staged.
    others: std.AutoHashMapUnmanaged(i64, *Layers) = .empty,
    cursor_front: std.ArrayListUnmanaged(Vertex) = .empty,
    cursor_back: std.ArrayListUnmanaged(Vertex) = .empty,
    cursor_front_grid: i64 = 0,
    cursor_back_grid: i64 = 0,
    cursor_staged: bool = false,
    destroyed: std.ArrayListUnmanaged(i64) = .empty,

    pub fn deinit(self: *SurfaceStore, alloc: std.mem.Allocator) void {
        var it = self.grids.valueIterator();
        while (it.next()) |g| {
            g.*.deinit(alloc);
            alloc.destroy(g.*);
        }
        self.grids.deinit(alloc);
        self.main.deinit(alloc);
        var oit = self.others.valueIterator();
        while (oit.next()) |l| {
            l.*.deinit(alloc);
            alloc.destroy(l.*);
        }
        self.others.deinit(alloc);
        self.cursor_front.deinit(alloc);
        self.cursor_back.deinit(alloc);
        self.destroyed.deinit(alloc);
    }

    /// Core thread only. The map grows only on a grid's first row, so App.mu
    /// must be held around this call (paint iterates the same map).
    pub fn rowsFor(self: *SurfaceStore, alloc: std.mem.Allocator, grid_id: i64) !*GridRows {
        const gop = try self.grids.getOrPut(alloc, grid_id);
        if (!gop.found_existing) {
            gop.value_ptr.* = alloc.create(GridRows) catch |e| {
                _ = self.grids.remove(grid_id);
                return e;
            };
            gop.value_ptr.*.* = .{};
        }
        return gop.value_ptr.*;
    }

    /// A surface not opened is ignored: the core opens one before its first
    /// layout (zonvie_core.h on_surface_layout).
    pub fn stageLayers(self: *SurfaceStore, alloc: std.mem.Allocator, surface_id: i64, layers: []const core.Layer) !void {
        const l = self.surfaceLayers(surface_id) orelse return;
        try l.stage(alloc, layers);
    }

    /// Caller holds App.mu. Repeated opens of one id are the same surface.
    pub fn openSurface(self: *SurfaceStore, alloc: std.mem.Allocator, surface_id: i64) !void {
        const gop = try self.others.getOrPut(alloc, surface_id);
        if (gop.found_existing) return;
        gop.value_ptr.* = alloc.create(Layers) catch |e| {
            _ = self.others.remove(surface_id);
            return e;
        };
        gop.value_ptr.*.* = .{};
    }

    /// Caller holds App.mu. Its grids keep their rows until on_grid_destroy.
    pub fn closeSurface(self: *SurfaceStore, alloc: std.mem.Allocator, surface_id: i64) void {
        const kv = self.others.fetchRemove(surface_id) orelse return;
        kv.value.deinit(alloc);
        alloc.destroy(kv.value);
        if (!self.hasLayer(self.cursor_front_grid)) self.cursor_front.clearRetainingCapacity();
    }

    fn surfaceLayers(self: *SurfaceStore, surface_id: i64) ?*Layers {
        if (surface_id == 1) return &self.main;
        return self.others.get(surface_id);
    }

    pub fn stageCursor(self: *SurfaceStore, alloc: std.mem.Allocator, grid_id: i64, verts: []const Vertex) !void {
        // Clearing another grid must not clear the owner's cursor (zonvie_core.h
        // on_vertices_row; windows/render_pipeline_helpers.zig:318 ignoresCursorClear).
        const owner = if (self.cursor_staged) self.cursor_back_grid else self.cursor_front_grid;
        if (verts.len == 0 and grid_id != owner) return;
        self.cursor_back.clearRetainingCapacity();
        try self.cursor_back.appendSlice(alloc, verts);
        self.cursor_back_grid = grid_id;
        self.cursor_staged = true;
    }

    pub fn stageDestroy(self: *SurfaceStore, alloc: std.mem.Allocator, grid_id: i64) !void {
        // Bounded by live grid count; capacity is reused across flushes.
        try self.destroyed.append(alloc, grid_id);
    }

    pub fn cancel(self: *SurfaceStore) void {
        var it = self.grids.valueIterator();
        while (it.next()) |g| g.*.cancel();
        self.main.staged = false;
        var oit = self.others.valueIterator();
        while (oit.next()) |l| l.*.staged = false;
        self.cursor_staged = false;
        self.destroyed.clearRetainingCapacity();
    }

    /// Caller holds App.mu. The only fallible step of a commit; on error the caller cancels.
    pub fn prepareCommit(self: *SurfaceStore, alloc: std.mem.Allocator) !void {
        var it = self.grids.valueIterator();
        while (it.next()) |g| try g.*.prepareCommit(alloc);
    }

    /// Caller holds App.mu; prepareCommit must have succeeded since the last stage.
    pub fn commit(self: *SurfaceStore, alloc: std.mem.Allocator, in: ScrollInput) void {
        var it = self.grids.iterator();
        // Grid 1 is the root, holding chrome and messages, and negative ids
        // are UI the core owns: neither eases.
        while (it.next()) |kv| kv.value_ptr.*.commit(alloc, kv.key_ptr.* >= 2, in);
        self.main.commit();
        var oit = self.others.valueIterator();
        while (oit.next()) |l| l.*.commit();
        if (self.cursor_staged) {
            std.mem.swap(std.ArrayListUnmanaged(Vertex), &self.cursor_front, &self.cursor_back);
            self.cursor_front_grid = self.cursor_back_grid;
            self.cursor_staged = false;
        }
        // A cursor whose grid left the layout must stop displaying (zonvie_core.h).
        if (!self.hasLayer(self.cursor_front_grid)) self.cursor_front.clearRetainingCapacity();
        for (self.destroyed.items) |id| {
            if (self.grids.fetchRemove(id)) |kv| {
                kv.value.deinit(alloc);
                alloc.destroy(kv.value);
            }
        }
        self.destroyed.clearRetainingCapacity();
    }

    fn hasLayer(self: *const SurfaceStore, grid_id: i64) bool {
        if (self.main.has(grid_id)) return true;
        var it = self.others.valueIterator();
        while (it.next()) |l| if (l.*.has(grid_id)) return true;
        return false;
    }

    /// The main surface's layers.
    pub fn committedLayers(self: *const SurfaceStore) []const core.Layer {
        return self.main.front.items;
    }

    /// An external surface's layers; empty when it is not open.
    pub fn committedSurfaceLayers(self: *const SurfaceStore, surface_id: i64) []const core.Layer {
        if (surface_id == 1) return self.main.front.items;
        const l = self.others.get(surface_id) orelse return &.{};
        return l.front.items;
    }

    pub fn committedGrid(self: *const SurfaceStore, grid_id: i64) ?*const GridRows {
        return self.grids.get(grid_id);
    }

    /// Caller holds App.mu. The paint settles each drawn grid's ease here.
    pub fn gridEase(self: *SurfaceStore, grid_id: i64) ?*grid_ease.GridEase {
        const g = self.grids.get(grid_id) orelse return null;
        return &g.ease;
    }

    pub fn committedCursor(self: *const SurfaceStore) struct { grid_id: i64, verts: []const Vertex } {
        return .{ .grid_id = self.cursor_front_grid, .verts = self.cursor_front.items };
    }
};

const testing = std.testing;

/// No row height: shifts rotate without rebasing and nothing eases.
const no_scroll: ScrollInput = .{ .now_ns = 1, .row_h_px = 0, .mousescroll_ver = 3, .large_jump = .partial };

fn v(y: f32) Vertex {
    return .{ .position = .{ 0, y }, .texCoord = .{ -1, -1 }, .color = .{ 1, 1, 1, 1 }, .grid_id = 2, .deco_flags = 0, .deco_phase = 0 };
}

fn firstY(g: *const GridRows, row: usize) ?f32 {
    const r = g.committedRows();
    if (row >= r.len or r[row].verts.items.len == 0) return null;
    return r[row].verts.items[0].position[1];
}

test "staged row is invisible until commit" {
    var g: GridRows = .{};
    defer g.deinit(testing.allocator);
    try g.stageRow(testing.allocator, 0, &.{v(10)}, 3);
    try testing.expectEqual(@as(?f32, null), firstY(&g, 0));
    try g.prepareCommit(testing.allocator);
    g.commit(testing.allocator, true, no_scroll);
    try testing.expectEqual(@as(?f32, 10), firstY(&g, 0));
}

test "rows not resent keep previous contents" {
    var g: GridRows = .{};
    defer g.deinit(testing.allocator);
    try g.stageRow(testing.allocator, 0, &.{v(1)}, 2);
    try g.stageRow(testing.allocator, 1, &.{v(2)}, 2);
    try g.prepareCommit(testing.allocator);
    g.commit(testing.allocator, true, no_scroll);
    try g.stageRow(testing.allocator, 1, &.{v(20)}, 2);
    try g.prepareCommit(testing.allocator);
    g.commit(testing.allocator, true, no_scroll);
    try testing.expectEqual(@as(?f32, 1), firstY(&g, 0));
    try testing.expectEqual(@as(?f32, 20), firstY(&g, 1));
}

test "cancel keeps committed rows" {
    var g: GridRows = .{};
    defer g.deinit(testing.allocator);
    try g.stageRow(testing.allocator, 0, &.{v(1)}, 1);
    try g.prepareCommit(testing.allocator);
    g.commit(testing.allocator, true, no_scroll);
    try g.stageRow(testing.allocator, 0, &.{v(99)}, 1);
    g.cancel();
    try g.prepareCommit(testing.allocator);
    g.commit(testing.allocator, true, no_scroll); // a later empty commit must not resurrect the cancelled row
    try testing.expectEqual(@as(?f32, 1), firstY(&g, 0));
}

test "resize shrink then grow" {
    var g: GridRows = .{};
    defer g.deinit(testing.allocator);
    for (0..4) |i| try g.stageRow(testing.allocator, @intCast(i), &.{v(@floatFromInt(i))}, 4);
    try g.prepareCommit(testing.allocator);
    g.commit(testing.allocator, true, no_scroll);
    try g.stageRow(testing.allocator, 0, &.{v(0)}, 2);
    try g.prepareCommit(testing.allocator);
    g.commit(testing.allocator, true, no_scroll);
    try testing.expectEqual(@as(usize, 2), g.committedRows().len);
    try g.stageRow(testing.allocator, 0, &.{v(0)}, 4);
    try g.prepareCommit(testing.allocator);
    g.commit(testing.allocator, true, no_scroll);
    try testing.expectEqual(@as(usize, 4), g.committedRows().len);
    try testing.expectEqual(@as(?f32, null), firstY(&g, 3)); // new row is empty, not stale
}

test "shift then vacated rows" {
    // Rows A,B,C,D; content scrolls up by 1 (rows_delta = 1, as <C-e>):
    // expect B,C,D,new where only row 3 is resent.
    var g: GridRows = .{};
    defer g.deinit(testing.allocator);
    for (0..4) |i| try g.stageRow(testing.allocator, @intCast(i), &.{v(@floatFromInt(i))}, 4);
    try g.prepareCommit(testing.allocator);
    g.commit(testing.allocator, true, no_scroll);
    g.stageShift(0, 4, 1, 4);
    try g.stageRow(testing.allocator, 3, &.{v(40)}, 4);
    try g.prepareCommit(testing.allocator);
    g.commit(testing.allocator, true, no_scroll);
    try testing.expectEqual(@as(?f32, 1), firstY(&g, 0));
    try testing.expectEqual(@as(?f32, 3), firstY(&g, 2));
    try testing.expectEqual(@as(?f32, 40), firstY(&g, 3));
}

test "shift down by 1 with region" {
    // rows_delta = -1 within [1,4): row1<-new, row2<-old1, row3<-old2; row0 untouched.
    var g: GridRows = .{};
    defer g.deinit(testing.allocator);
    for (0..4) |i| try g.stageRow(testing.allocator, @intCast(i), &.{v(@floatFromInt(i))}, 4);
    try g.prepareCommit(testing.allocator);
    g.commit(testing.allocator, true, no_scroll);
    g.stageShift(1, 4, -1, 4);
    try g.stageRow(testing.allocator, 1, &.{v(10)}, 4);
    try g.prepareCommit(testing.allocator);
    g.commit(testing.allocator, true, no_scroll);
    try testing.expectEqual(@as(?f32, 0), firstY(&g, 0));
    try testing.expectEqual(@as(?f32, 10), firstY(&g, 1));
    try testing.expectEqual(@as(?f32, 1), firstY(&g, 2));
    try testing.expectEqual(@as(?f32, 2), firstY(&g, 3));
}

test "stageClear empties every row at commit" {
    var g: GridRows = .{};
    defer g.deinit(testing.allocator);
    try g.stageRow(testing.allocator, 0, &.{v(1)}, 1);
    try g.prepareCommit(testing.allocator);
    g.commit(testing.allocator, true, no_scroll);
    g.stageClear();
    try g.prepareCommit(testing.allocator);
    g.commit(testing.allocator, true, no_scroll);
    try testing.expectEqual(@as(usize, 0), g.committedRows().len);
}

test "failed prepareCommit then cancel keeps the committed frame, even with a shift staged" {
    var g: GridRows = .{};
    defer g.deinit(testing.allocator);
    for (0..2) |i| try g.stageRow(testing.allocator, @intCast(i), &.{v(@floatFromInt(i))}, 2);
    try g.prepareCommit(testing.allocator);
    try g.prepareCommit(testing.allocator);
    g.commit(testing.allocator, true, no_scroll);

    g.stageShift(0, 2, 1, 2);
    try g.stageRow(testing.allocator, 1, &.{v(50)}, 64);
    var failing = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    try testing.expectError(error.OutOfMemory, g.prepareCommit(failing.allocator()));
    g.cancel();

    try testing.expectEqual(@as(usize, 2), g.committedRows().len);
    try testing.expectEqual(@as(?f32, 0), firstY(&g, 0));
    try testing.expectEqual(@as(?f32, 1), firstY(&g, 1));
}

fn layer(grid: i64, z: i32) core.Layer {
    return .{ .grid_id = grid, .anchor_grid = 1, .x_px = 0, .y_px = 0, .rows = 2, .cols = 2, .z = z, .flags = 0 };
}

test "layers publish at commit only" {
    var s: SurfaceStore = .{};
    defer s.deinit(testing.allocator);
    try s.stageLayers(testing.allocator, 1, &.{ layer(1, 0), layer(2, 1) });
    try testing.expectEqual(@as(usize, 0), s.committedLayers().len);
    try s.prepareCommit(testing.allocator);
    s.commit(testing.allocator, no_scroll);
    try testing.expectEqual(@as(usize, 2), s.committedLayers().len);
}

test "cursor-only update never touches rows" {
    var s: SurfaceStore = .{};
    defer s.deinit(testing.allocator);
    try (try s.rowsFor(testing.allocator, 2)).stageRow(testing.allocator, 0, &.{v(5)}, 1);
    try s.prepareCommit(testing.allocator);
    s.commit(testing.allocator, no_scroll);
    try s.stageLayers(testing.allocator, 1, &.{layer(2, 0)});
    try s.stageCursor(testing.allocator, 2, &.{v(77)});
    try s.prepareCommit(testing.allocator);
    s.commit(testing.allocator, no_scroll);
    try testing.expectEqual(@as(?f32, 5), firstY(s.committedGrid(2).?, 0));
    try testing.expectEqual(@as(f32, 77), s.committedCursor().verts[0].position[1]);
}

test "layout drop hides a grid's rows and its cursor" {
    var s: SurfaceStore = .{};
    defer s.deinit(testing.allocator);
    try s.stageLayers(testing.allocator, 1, &.{ layer(1, 0), layer(3, 1) });
    try s.stageCursor(testing.allocator, 3, &.{v(1)});
    try s.prepareCommit(testing.allocator);
    s.commit(testing.allocator, no_scroll);
    try s.stageLayers(testing.allocator, 1, &.{layer(1, 0)});
    try s.prepareCommit(testing.allocator);
    s.commit(testing.allocator, no_scroll);
    try testing.expectEqual(@as(usize, 1), s.committedLayers().len);
    try testing.expectEqual(@as(usize, 0), s.committedCursor().verts.len);
}

test "cancel keeps committed layers and cursor" {
    var s: SurfaceStore = .{};
    defer s.deinit(testing.allocator);
    try s.stageLayers(testing.allocator, 1, &.{layer(1, 0)});
    try s.stageCursor(testing.allocator, 1, &.{v(1)});
    try s.prepareCommit(testing.allocator);
    s.commit(testing.allocator, no_scroll);
    try s.stageLayers(testing.allocator, 1, &.{ layer(1, 0), layer(2, 1) });
    try s.stageCursor(testing.allocator, 2, &.{v(2)});
    s.cancel();
    try testing.expectEqual(@as(usize, 1), s.committedLayers().len);
    try testing.expectEqual(@as(i64, 1), s.committedCursor().grid_id);
}

test "destroy frees the grid at commit, not before" {
    var s: SurfaceStore = .{};
    defer s.deinit(testing.allocator);
    try (try s.rowsFor(testing.allocator, 4)).stageRow(testing.allocator, 0, &.{v(1)}, 1);
    try s.prepareCommit(testing.allocator);
    s.commit(testing.allocator, no_scroll);
    try s.stageDestroy(testing.allocator, 4);
    try testing.expect(s.committedGrid(4) != null);
    try s.prepareCommit(testing.allocator);
    s.commit(testing.allocator, no_scroll);
    try testing.expect(s.committedGrid(4) == null);
}

test "failed prepareCommit then cancel keeps committed layers, cursor and rows" {
    var s: SurfaceStore = .{};
    defer s.deinit(testing.allocator);
    try s.stageLayers(testing.allocator, 1, &.{layer(1, 0)});
    try s.stageCursor(testing.allocator, 1, &.{v(1)});
    try (try s.rowsFor(testing.allocator, 1)).stageRow(testing.allocator, 0, &.{v(9)}, 1);
    try s.prepareCommit(testing.allocator);
    s.commit(testing.allocator, no_scroll);

    try s.stageLayers(testing.allocator, 1, &.{ layer(1, 0), layer(2, 1) });
    try s.stageCursor(testing.allocator, 2, &.{v(2)});
    try (try s.rowsFor(testing.allocator, 1)).stageRow(testing.allocator, 0, &.{v(50)}, 64);
    var failing = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    try testing.expectError(error.OutOfMemory, s.prepareCommit(failing.allocator()));
    s.cancel();

    try testing.expectEqual(@as(usize, 1), s.committedLayers().len);
    try testing.expectEqual(@as(i64, 1), s.committedCursor().grid_id);
    try testing.expectEqual(@as(f32, 1), s.committedCursor().verts[0].position[1]);
    try testing.expectEqual(@as(usize, 1), s.committedGrid(1).?.committedRows().len);
    try testing.expectEqual(@as(?f32, 9), firstY(s.committedGrid(1).?, 0));
}

fn twoGridStore(s: *SurfaceStore) !void {
    try s.stageLayers(testing.allocator, 1, &.{ layer(1, 0), layer(2, 1) });
}

test "cursor clear from a non-owner in the same flush keeps the owner's cursor" {
    var s: SurfaceStore = .{};
    defer s.deinit(testing.allocator);
    try twoGridStore(&s);
    try s.stageCursor(testing.allocator, 2, &.{v(7)});
    try s.stageCursor(testing.allocator, 1, &.{});
    try s.prepareCommit(testing.allocator);
    s.commit(testing.allocator, no_scroll);
    try testing.expectEqual(@as(i64, 2), s.committedCursor().grid_id);
    try testing.expectEqual(@as(usize, 1), s.committedCursor().verts.len);
}

test "cursor clear from a non-owner in a later flush keeps the committed cursor" {
    var s: SurfaceStore = .{};
    defer s.deinit(testing.allocator);
    try twoGridStore(&s);
    try s.stageCursor(testing.allocator, 2, &.{v(7)});
    try s.prepareCommit(testing.allocator);
    s.commit(testing.allocator, no_scroll);
    try s.stageCursor(testing.allocator, 1, &.{});
    try s.prepareCommit(testing.allocator);
    s.commit(testing.allocator, no_scroll);
    try testing.expectEqual(@as(i64, 2), s.committedCursor().grid_id);
    try testing.expectEqual(@as(usize, 1), s.committedCursor().verts.len);
}

test "cursor clear from the owner empties the cursor" {
    var s: SurfaceStore = .{};
    defer s.deinit(testing.allocator);
    try twoGridStore(&s);
    try s.stageCursor(testing.allocator, 2, &.{v(7)});
    try s.prepareCommit(testing.allocator);
    s.commit(testing.allocator, no_scroll);
    try s.stageCursor(testing.allocator, 2, &.{});
    try s.prepareCommit(testing.allocator);
    s.commit(testing.allocator, no_scroll);
    try testing.expectEqual(@as(usize, 0), s.committedCursor().verts.len);
}

test "a row with no total_rows is content and never shrinks the grid" {
    var g: GridRows = .{};
    defer g.deinit(testing.allocator);
    try g.stageRow(testing.allocator, 0, &.{v(1)}, 3);
    try g.prepareCommit(testing.allocator);
    g.commit(testing.allocator, true, no_scroll);
    try g.stageRow(testing.allocator, 1, &.{v(2)}, 0);
    try g.prepareCommit(testing.allocator);
    g.commit(testing.allocator, true, no_scroll);
    try testing.expectEqual(@as(usize, 3), g.committedRows().len);
    try testing.expectEqual(@as(?f32, 1), firstY(&g, 0));
    try testing.expectEqual(@as(?f32, 2), firstY(&g, 1));
    // First seed with no row count grows to hold the row.
    var h: GridRows = .{};
    defer h.deinit(testing.allocator);
    try h.stageRow(testing.allocator, 2, &.{v(5)}, 0);
    try h.prepareCommit(testing.allocator);
    h.commit(testing.allocator, true, no_scroll);
    try testing.expectEqual(@as(usize, 3), h.committedRows().len);
    try testing.expectEqual(@as(?f32, 5), firstY(&h, 2));
}

test "a shift rebases moved rows to their new row" {
    var g: GridRows = .{};
    defer g.deinit(testing.allocator);
    const in: ScrollInput = .{ .now_ns = 1, .row_h_px = 10, .mousescroll_ver = 0, .large_jump = .snap };
    for (0..4) |i| try g.stageRow(testing.allocator, @intCast(i), &.{v(@floatFromInt(i * 10))}, 4);
    try g.prepareCommit(testing.allocator);
    g.commit(testing.allocator, true, in);
    g.stageShift(0, 4, 1, 4);
    try g.stageRow(testing.allocator, 3, &.{v(30)}, 4);
    try g.prepareCommit(testing.allocator);
    g.commit(testing.allocator, true, in);
    for (0..4) |i| try testing.expectEqual(@as(?f32, @floatFromInt(i * 10)), firstY(&g, i));
}

test "an eased shift keeps the scrolled-out row and the resend fills the band" {
    var g: GridRows = .{};
    defer g.deinit(testing.allocator);
    const in: ScrollInput = .{ .now_ns = 1, .row_h_px = 10, .mousescroll_ver = 3, .large_jump = .partial };
    for (0..4) |i| try g.stageRow(testing.allocator, @intCast(i), &.{v(@floatFromInt(i * 10))}, 4);
    try g.prepareCommit(testing.allocator);
    g.commit(testing.allocator, true, in);
    g.stageShift(0, 4, 1, 4);
    try g.stageRow(testing.allocator, 3, &.{v(30)}, 4);
    try g.prepareCommit(testing.allocator);
    g.commit(testing.allocator, true, in);
    try testing.expectEqual(@as(?f32, 30), firstY(&g, 3));
    const kept = g.retainedRows()[0];
    try testing.expect(kept.live);
    try testing.expectEqual(@as(i32, -1), kept.row);
    try testing.expectEqual(@as(f32, -10), kept.verts.items[0].position[1]);
    try testing.expect(g.ease.moving());
}

test "the root grid never eases" {
    var s: SurfaceStore = .{};
    defer s.deinit(testing.allocator);
    const in: ScrollInput = .{ .now_ns = 1, .row_h_px = 10, .mousescroll_ver = 3, .large_jump = .partial };
    const g = try s.rowsFor(testing.allocator, 1);
    for (0..4) |i| try g.stageRow(testing.allocator, @intCast(i), &.{v(@floatFromInt(i * 10))}, 4);
    try s.prepareCommit(testing.allocator);
    s.commit(testing.allocator, in);
    g.stageShift(0, 4, 1, 4);
    try g.stageRow(testing.allocator, 3, &.{v(30)}, 4);
    try s.prepareCommit(testing.allocator);
    s.commit(testing.allocator, in);
    try testing.expect(!g.ease.moving());
}

test "an external surface publishes its layers at commit and keeps the cursor on it" {
    var s: SurfaceStore = .{};
    defer s.deinit(testing.allocator);
    try s.openSurface(testing.allocator, -100);
    try s.openSurface(testing.allocator, -100);
    try s.stageLayers(testing.allocator, -100, &.{layer(-100, 0)});
    try s.stageCursor(testing.allocator, -100, &.{v(3)});
    try testing.expectEqual(@as(usize, 0), s.committedSurfaceLayers(-100).len);
    try s.prepareCommit(testing.allocator);
    s.commit(testing.allocator, no_scroll);
    try testing.expectEqual(@as(usize, 1), s.committedSurfaceLayers(-100).len);
    try testing.expectEqual(@as(usize, 1), s.committedCursor().verts.len);
    s.closeSurface(testing.allocator, -100);
    try testing.expectEqual(@as(usize, 0), s.committedSurfaceLayers(-100).len);
    try testing.expectEqual(@as(usize, 0), s.committedCursor().verts.len);
}

test "layers for a surface never opened are dropped" {
    var s: SurfaceStore = .{};
    defer s.deinit(testing.allocator);
    try s.stageLayers(testing.allocator, -101, &.{layer(-101, 0)});
    try s.prepareCommit(testing.allocator);
    s.commit(testing.allocator, no_scroll);
    try testing.expectEqual(@as(usize, 0), s.committedSurfaceLayers(-101).len);
}
