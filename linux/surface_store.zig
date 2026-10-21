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

    /// Caller holds App.mu. Allocation happens only when a grid grows.
    pub fn commit(self: *GridRows, alloc: std.mem.Allocator) void {
        defer self.cancel();
        if (self.staged_clear) {
            for (self.front.items) |*r| r.verts.deinit(alloc);
            self.front.clearRetainingCapacity();
            return;
        }
        if (self.staged_shift) |s| self.applyShift(s);
        const len: usize = self.staged_len orelse self.front.items.len;
        while (self.front.items.len < len) self.front.append(alloc, .{}) catch return;
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
    g.commit(testing.allocator);
    try testing.expectEqual(@as(?f32, 10), firstY(&g, 0));
}

test "rows not resent keep previous contents" {
    var g: GridRows = .{};
    defer g.deinit(testing.allocator);
    try g.stageRow(testing.allocator, 0, &.{v(1)}, 2);
    try g.stageRow(testing.allocator, 1, &.{v(2)}, 2);
    g.commit(testing.allocator);
    try g.stageRow(testing.allocator, 1, &.{v(20)}, 2);
    g.commit(testing.allocator);
    try testing.expectEqual(@as(?f32, 1), firstY(&g, 0));
    try testing.expectEqual(@as(?f32, 20), firstY(&g, 1));
}

test "cancel keeps committed rows" {
    var g: GridRows = .{};
    defer g.deinit(testing.allocator);
    try g.stageRow(testing.allocator, 0, &.{v(1)}, 1);
    g.commit(testing.allocator);
    try g.stageRow(testing.allocator, 0, &.{v(99)}, 1);
    g.cancel();
    g.commit(testing.allocator); // a later empty commit must not resurrect the cancelled row
    try testing.expectEqual(@as(?f32, 1), firstY(&g, 0));
}

test "resize shrink then grow" {
    var g: GridRows = .{};
    defer g.deinit(testing.allocator);
    for (0..4) |i| try g.stageRow(testing.allocator, @intCast(i), &.{v(@floatFromInt(i))}, 4);
    g.commit(testing.allocator);
    try g.stageRow(testing.allocator, 0, &.{v(0)}, 2);
    g.commit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), g.committedRows().len);
    try g.stageRow(testing.allocator, 0, &.{v(0)}, 4);
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
    g.commit(testing.allocator);
    g.stageShift(0, 4, 1);
    try g.stageRow(testing.allocator, 3, &.{v(40)}, 4);
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
    g.commit(testing.allocator);
    g.stageShift(1, 4, -1);
    try g.stageRow(testing.allocator, 1, &.{v(10)}, 4);
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
    g.commit(testing.allocator);
    g.stageClear();
    g.commit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), g.committedRows().len);
}
