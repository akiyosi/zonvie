//! Per-grid row vertices for one surface, staged by the core thread inside
//! a flush and published at on_flush_end. `back` is touched only by the core
//! thread; `front` only under App.mu. commit swaps exactly the rows sent this
//! flush, so a row not resent keeps its committed contents.

const std = @import("std");
const core = @import("zonvie_core");
const Vertex = core.Vertex;

pub const Row = struct {
    verts: std.ArrayListUnmanaged(Vertex) = .empty,
};

const Shift = struct { row_start: u32, row_end: u32, rows_delta: i32 };

pub const GridRows = struct {
    front: std.ArrayListUnmanaged(Row) = .empty,
    back: std.ArrayListUnmanaged(Row) = .empty,
    dirty: std.DynamicBitSetUnmanaged = .{},
    /// Row count the staged flush will publish; null when unchanged.
    staged_len: ?u32 = null,
    staged_clear: bool = false,
    /// The core sends at most one shift per grid per flush (zonvie_core.h).
    staged_shift: ?Shift = null,

    pub fn deinit(self: *GridRows, alloc: std.mem.Allocator) void {
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
        self.staged_len = total_rows;
        if (row >= total_rows) return;
        try self.ensureBack(alloc, total_rows);
        const dst = &self.back.items[row].verts;
        dst.clearRetainingCapacity();
        try dst.appendSlice(alloc, verts);
        self.dirty.set(row);
    }

    pub fn stageShift(self: *GridRows, row_start: u32, row_end: u32, rows_delta: i32) void {
        self.staged_shift = .{ .row_start = row_start, .row_end = row_end, .rows_delta = rows_delta };
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

    /// Caller holds App.mu; prepareCommit must have succeeded since the last stage.
    pub fn commit(self: *GridRows, alloc: std.mem.Allocator) void {
        defer self.cancel();
        if (self.staged_clear) {
            for (self.front.items) |*r| r.verts.deinit(alloc);
            self.front.clearRetainingCapacity();
            return;
        }
        if (self.staged_shift) |s| self.applyShift(s);
        const len: usize = self.staged_len orelse self.front.items.len;
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

    fn applyShift(self: *GridRows, s: Shift) void {
        const end = @min(s.row_end, @as(u32, @intCast(self.front.items.len)));
        if (s.row_start >= end) return;
        const region = self.front.items[s.row_start..end];
        const n: usize = @intCast(@abs(s.rows_delta));
        if (n >= region.len) return;
        // rows_delta > 0: content moves up (row i takes row i+n); matches
        // windows/render_pipeline_helpers.zig rotateRegion.
        if (s.rows_delta > 0) std.mem.rotate(Row, region, n) else std.mem.rotate(Row, region, region.len - n);
    }

    pub fn committedRows(self: *const GridRows) []const Row {
        return self.front.items;
    }
};

pub const SurfaceStore = struct {
    grids: std.AutoHashMapUnmanaged(i64, *GridRows) = .empty,
    layers_front: std.ArrayListUnmanaged(core.Layer) = .empty,
    layers_back: std.ArrayListUnmanaged(core.Layer) = .empty,
    layers_staged: bool = false,
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
        self.layers_front.deinit(alloc);
        self.layers_back.deinit(alloc);
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

    pub fn stageLayers(self: *SurfaceStore, alloc: std.mem.Allocator, layers: []const core.Layer, rows: u32, cols: u32) !void {
        _ = rows;
        _ = cols;
        self.layers_back.clearRetainingCapacity();
        try self.layers_back.appendSlice(alloc, layers);
        self.layers_staged = true;
    }

    pub fn stageCursor(self: *SurfaceStore, alloc: std.mem.Allocator, grid_id: i64, verts: []const Vertex) !void {
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
        self.layers_staged = false;
        self.cursor_staged = false;
        self.destroyed.clearRetainingCapacity();
    }

    /// Caller holds App.mu. The only fallible step of a commit; on error the caller cancels.
    pub fn prepareCommit(self: *SurfaceStore, alloc: std.mem.Allocator) !void {
        var it = self.grids.valueIterator();
        while (it.next()) |g| try g.*.prepareCommit(alloc);
    }

    /// Caller holds App.mu; prepareCommit must have succeeded since the last stage.
    pub fn commit(self: *SurfaceStore, alloc: std.mem.Allocator) void {
        var it = self.grids.valueIterator();
        while (it.next()) |g| g.*.commit(alloc);
        if (self.layers_staged) {
            std.mem.swap(std.ArrayListUnmanaged(core.Layer), &self.layers_front, &self.layers_back);
            self.layers_staged = false;
        }
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
        for (self.layers_front.items) |l| if (l.grid_id == grid_id) return true;
        return false;
    }

    pub fn committedLayers(self: *const SurfaceStore) []const core.Layer {
        return self.layers_front.items;
    }

    pub fn committedGrid(self: *const SurfaceStore, grid_id: i64) ?*const GridRows {
        return self.grids.get(grid_id);
    }

    pub fn committedCursor(self: *const SurfaceStore) struct { grid_id: i64, verts: []const Vertex } {
        return .{ .grid_id = self.cursor_front_grid, .verts = self.cursor_front.items };
    }
};

const testing = std.testing;

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
    g.commit(testing.allocator);
    try testing.expectEqual(@as(?f32, 10), firstY(&g, 0));
}

test "rows not resent keep previous contents" {
    var g: GridRows = .{};
    defer g.deinit(testing.allocator);
    try g.stageRow(testing.allocator, 0, &.{v(1)}, 2);
    try g.stageRow(testing.allocator, 1, &.{v(2)}, 2);
    try g.prepareCommit(testing.allocator);
    g.commit(testing.allocator);
    try g.stageRow(testing.allocator, 1, &.{v(20)}, 2);
    try g.prepareCommit(testing.allocator);
    g.commit(testing.allocator);
    try testing.expectEqual(@as(?f32, 1), firstY(&g, 0));
    try testing.expectEqual(@as(?f32, 20), firstY(&g, 1));
}

test "cancel keeps committed rows" {
    var g: GridRows = .{};
    defer g.deinit(testing.allocator);
    try g.stageRow(testing.allocator, 0, &.{v(1)}, 1);
    try g.prepareCommit(testing.allocator);
    g.commit(testing.allocator);
    try g.stageRow(testing.allocator, 0, &.{v(99)}, 1);
    g.cancel();
    try g.prepareCommit(testing.allocator);
    g.commit(testing.allocator); // a later empty commit must not resurrect the cancelled row
    try testing.expectEqual(@as(?f32, 1), firstY(&g, 0));
}

test "resize shrink then grow" {
    var g: GridRows = .{};
    defer g.deinit(testing.allocator);
    for (0..4) |i| try g.stageRow(testing.allocator, @intCast(i), &.{v(@floatFromInt(i))}, 4);
    try g.prepareCommit(testing.allocator);
    g.commit(testing.allocator);
    try g.stageRow(testing.allocator, 0, &.{v(0)}, 2);
    try g.prepareCommit(testing.allocator);
    g.commit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), g.committedRows().len);
    try g.stageRow(testing.allocator, 0, &.{v(0)}, 4);
    try g.prepareCommit(testing.allocator);
    g.commit(testing.allocator);
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
    g.commit(testing.allocator);
    g.stageShift(0, 4, 1);
    try g.stageRow(testing.allocator, 3, &.{v(40)}, 4);
    try g.prepareCommit(testing.allocator);
    g.commit(testing.allocator);
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
    g.commit(testing.allocator);
    g.stageShift(1, 4, -1);
    try g.stageRow(testing.allocator, 1, &.{v(10)}, 4);
    try g.prepareCommit(testing.allocator);
    g.commit(testing.allocator);
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
    g.commit(testing.allocator);
    g.stageClear();
    try g.prepareCommit(testing.allocator);
    g.commit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), g.committedRows().len);
}

test "failed prepareCommit then cancel keeps the committed frame, even with a shift staged" {
    var g: GridRows = .{};
    defer g.deinit(testing.allocator);
    for (0..2) |i| try g.stageRow(testing.allocator, @intCast(i), &.{v(@floatFromInt(i))}, 2);
    try g.prepareCommit(testing.allocator);
    try g.prepareCommit(testing.allocator);
    g.commit(testing.allocator);

    g.stageShift(0, 2, 1);
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
    try s.stageLayers(testing.allocator, &.{ layer(1, 0), layer(2, 1) }, 10, 10);
    try testing.expectEqual(@as(usize, 0), s.committedLayers().len);
    try s.prepareCommit(testing.allocator);
    s.commit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), s.committedLayers().len);
}

test "cursor-only update never touches rows" {
    var s: SurfaceStore = .{};
    defer s.deinit(testing.allocator);
    try (try s.rowsFor(testing.allocator, 2)).stageRow(testing.allocator, 0, &.{v(5)}, 1);
    try s.prepareCommit(testing.allocator);
    s.commit(testing.allocator);
    try s.stageLayers(testing.allocator, &.{layer(2, 0)}, 10, 10);
    try s.stageCursor(testing.allocator, 2, &.{v(77)});
    try s.prepareCommit(testing.allocator);
    s.commit(testing.allocator);
    try testing.expectEqual(@as(?f32, 5), firstY(s.committedGrid(2).?, 0));
    try testing.expectEqual(@as(f32, 77), s.committedCursor().verts[0].position[1]);
}

test "layout drop hides a grid's rows and its cursor" {
    var s: SurfaceStore = .{};
    defer s.deinit(testing.allocator);
    try s.stageLayers(testing.allocator, &.{ layer(1, 0), layer(3, 1) }, 10, 10);
    try s.stageCursor(testing.allocator, 3, &.{v(1)});
    try s.prepareCommit(testing.allocator);
    s.commit(testing.allocator);
    try s.stageLayers(testing.allocator, &.{layer(1, 0)}, 10, 10);
    try s.prepareCommit(testing.allocator);
    s.commit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), s.committedLayers().len);
    try testing.expectEqual(@as(usize, 0), s.committedCursor().verts.len);
}

test "cancel keeps committed layers and cursor" {
    var s: SurfaceStore = .{};
    defer s.deinit(testing.allocator);
    try s.stageLayers(testing.allocator, &.{layer(1, 0)}, 10, 10);
    try s.stageCursor(testing.allocator, 1, &.{v(1)});
    try s.prepareCommit(testing.allocator);
    s.commit(testing.allocator);
    try s.stageLayers(testing.allocator, &.{ layer(1, 0), layer(2, 1) }, 10, 10);
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
    s.commit(testing.allocator);
    try s.stageDestroy(testing.allocator, 4);
    try testing.expect(s.committedGrid(4) != null);
    try s.prepareCommit(testing.allocator);
    s.commit(testing.allocator);
    try testing.expect(s.committedGrid(4) == null);
}

test "failed prepareCommit then cancel keeps committed layers, cursor and rows" {
    var s: SurfaceStore = .{};
    defer s.deinit(testing.allocator);
    try s.stageLayers(testing.allocator, &.{layer(1, 0)}, 10, 10);
    try s.stageCursor(testing.allocator, 1, &.{v(1)});
    try (try s.rowsFor(testing.allocator, 1)).stageRow(testing.allocator, 0, &.{v(9)}, 1);
    try s.prepareCommit(testing.allocator);
    s.commit(testing.allocator);

    try s.stageLayers(testing.allocator, &.{ layer(1, 0), layer(2, 1) }, 10, 10);
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
