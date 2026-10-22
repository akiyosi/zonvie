//! One grid's smooth scroll (core scroll_ease.zig) and the rows that
//! scrolled out of it, kept drawable while the offset still shows the band
//! they left. Lives with the grid's committed rows, so it is touched only
//! under App.mu.

const std = @import("std");
const core = @import("zonvie_core");
const scroll_ease = core.scroll_ease;
const Vertex = core.Vertex;

/// What a commit's scroll reads once per flush.
pub const ScrollInput = struct {
    now_ns: i64,
    row_h_px: u32,
    /// 'mousescroll' ver, read live: it caps every arrival.
    mousescroll_ver: i32,
    large_jump: scroll_ease.LargeJumpBehavior,
};

/// A row outside the scroll region, at grid row `row`; its vertices are
/// already positioned there.
pub const RetainedRow = struct {
    verts: std.ArrayListUnmanaged(Vertex) = .empty,
    row: i32 = 0,
    live: bool = false,
};

pub const GridEase = struct {
    spring: scroll_ease.Ease = .{},
    retained: [2 * scroll_ease.retention_depth_rows]RetainedRow = @splat(.{}),
    /// Set by `plan`: this frame draws the scroll region at `offset_px`. The
    /// frame that brings the ease to rest is one too, so the last offset
    /// drawn is zero.
    easing: bool = false,
    offset_px: f32 = 0,

    pub fn deinit(self: *GridEase, alloc: std.mem.Allocator) void {
        for (&self.retained) |*r| r.verts.deinit(alloc);
    }

    pub fn moving(self: *const GridEase) bool {
        return self.spring.moving();
    }

    /// The scroll region `plan` settled on, half-open in grid rows; empty
    /// when this frame does not ease.
    pub fn region(self: *const GridEase) [2]u32 {
        if (!self.easing) return .{ 0, 0 };
        return .{ self.spring.region_start, self.spring.region_end };
    }

    /// Before the committed rows rotate: advance the spring to the commit and
    /// move the kept rows with the region. Rows kept beside another region
    /// mean nothing beside this one.
    pub fn beforeShift(self: *GridEase, row_start: u32, row_end: u32, rows_delta: i32, in: ScrollInput) void {
        self.spring.tick(in.now_ns);
        if (row_start != self.spring.region_start or row_end != self.spring.region_end) self.dropRetained();
        const dy: f32 = @floatFromInt(-rows_delta * @as(i32, @intCast(in.row_h_px)));
        for (&self.retained) |*r| {
            if (!r.live) continue;
            r.row = scroll_ease.shiftedRow(r.row, rows_delta);
            r.live = scroll_ease.keepsRetained(r.row, row_start, row_end);
            if (r.live) moveVerts(r.verts.items, dy);
        }
    }

    /// After the rotation, `rows` (the grid's committed rows) holds the
    /// scrolled-out content in the band the shift vacated. Seeds the spring
    /// and, when it took the scroll, keeps that content: each kept row swaps
    /// with a free entry, so no allocation happens. The band is left empty
    /// for the resend the core owes it.
    pub fn seedAndRetain(
        self: *GridEase,
        rows: anytype,
        row_start: u32,
        row_end: u32,
        rows_delta: i32,
        in: ScrollInput,
    ) void {
        const seeded = self.spring.seed(in.now_ns, rows_delta, @intCast(in.row_h_px), row_start, row_end, in.mousescroll_ver, in.large_jump);
        if (seeded) {
            const n: u32 = @intCast(@abs(rows_delta));
            const band_start: u32 = if (rows_delta > 0) row_end - n else row_start;
            var k: u32 = 0;
            while (k < n) : (k += 1) {
                const i = band_start + k;
                // The rotation carried old row `row_start + k` (up) or
                // `row_end - n + k` (down) into the band.
                const old_row: i32 = @intCast(if (rows_delta > 0) row_start + k else row_end - n + k);
                const row = scroll_ease.shiftedRow(old_row, rows_delta);
                if (i >= rows.len) break;
                if (rows[i].verts.items.len == 0 or !scroll_ease.keepsRetained(row, row_start, row_end)) continue;
                const entry = for (&self.retained) |*e| {
                    if (!e.live) break e;
                } else break;
                std.mem.swap(std.ArrayListUnmanaged(Vertex), &entry.verts, &rows[i].verts);
                rows[i].verts.clearRetainingCapacity();
                entry.row = row;
                entry.live = true;
            }
        }
        if (!self.spring.moving()) self.dropRetained();
    }

    /// Advance the ease for a frame drawn at `now_ns` and settle whether it
    /// draws the grid eased. `row_limit` is the grid's committed row count.
    pub fn plan(self: *GridEase, now_ns: i64, row_h_px: u32, row_limit: usize) void {
        const s = &self.spring;
        const was_moving = s.moving();
        s.tick(now_ns);
        if (s.row_h_px != 0 and (s.row_h_px != @as(i32, @intCast(row_h_px)) or s.region_end > row_limit)) s.reset();
        if (!s.moving()) self.dropRetained();
        self.easing = (was_moving or s.moving()) and s.region_end > s.region_start;
        self.offset_px = @floatCast(s.spring.offset_px);
    }

    /// Retained rows stop being drawn; their buffers stay for the next capture.
    pub fn dropRetained(self: *GridEase) void {
        for (&self.retained) |*r| r.live = false;
    }
};

/// Rebase vertices by `dy_px`, for content that moved rows without being
/// regenerated.
pub fn moveVerts(verts: []Vertex, dy_px: f32) void {
    for (verts) |*vt| vt.position[1] += dy_px;
}

const testing = std.testing;

const TestRow = struct { verts: std.ArrayListUnmanaged(Vertex) = .empty };

fn vtx(y: f32) Vertex {
    return .{ .position = .{ 0, y }, .texCoord = .{ -1, -1 }, .color = .{ 1, 1, 1, 1 }, .grid_id = 2, .deco_flags = 0, .deco_phase = 0 };
}

const input: ScrollInput = .{ .now_ns = 1, .row_h_px = 10, .mousescroll_ver = 3, .large_jump = .partial };

test "a seeded scroll keeps the scrolled-out row above the region and empties the band" {
    var e: GridEase = .{};
    defer e.deinit(testing.allocator);
    // Region [0,4) scrolled up by 1: after rotation old row 0 sits at row 3,
    // already rebased to y = -10.
    var rows: [4]TestRow = .{ .{}, .{}, .{}, .{} };
    defer for (&rows) |*r| r.verts.deinit(testing.allocator);
    try rows[3].verts.append(testing.allocator, vtx(-10));
    e.beforeShift(0, 4, 1, input);
    e.seedAndRetain(&rows, 0, 4, 1, input);
    try testing.expectEqual(@as(usize, 0), rows[3].verts.items.len);
    try testing.expect(e.retained[0].live);
    try testing.expectEqual(@as(i32, -1), e.retained[0].row);
    try testing.expectEqual(@as(f32, -10), e.retained[0].verts.items[0].position[1]);
    try testing.expectEqual(@as(f64, 10), e.spring.spring.offset_px);
}

test "a kept row travels with the next scroll and leaves past retention depth" {
    var e: GridEase = .{};
    defer e.deinit(testing.allocator);
    var rows: [4]TestRow = .{ .{}, .{}, .{}, .{} };
    defer for (&rows) |*r| r.verts.deinit(testing.allocator);
    try rows[0].verts.append(testing.allocator, vtx(40));
    // Down by 1: old row 3 sits at row 0 rebased to y = 40, kept at row 4.
    e.beforeShift(0, 4, -1, input);
    e.seedAndRetain(&rows, 0, 4, -1, input);
    try testing.expectEqual(@as(i32, 4), e.retained[0].row);
    e.beforeShift(0, 4, -2, input);
    try testing.expectEqual(@as(i32, 6), e.retained[0].row);
    try testing.expectEqual(@as(f32, 60), e.retained[0].verts.items[0].position[1]);
    e.beforeShift(0, 4, -8, input);
    try testing.expect(!e.retained[0].live);
}

test "a refused seed keeps nothing" {
    var e: GridEase = .{};
    defer e.deinit(testing.allocator);
    var rows: [4]TestRow = .{ .{}, .{}, .{}, .{} };
    defer for (&rows) |*r| r.verts.deinit(testing.allocator);
    try rows[3].verts.append(testing.allocator, vtx(-10));
    const snap: ScrollInput = .{ .now_ns = 1, .row_h_px = 10, .mousescroll_ver = 0, .large_jump = .snap };
    e.beforeShift(0, 4, 1, snap);
    e.seedAndRetain(&rows, 0, 4, 1, snap);
    try testing.expect(!e.retained[0].live);
    try testing.expect(!e.moving());
}

test "plan eases until rest, drawing the resting frame once" {
    var e: GridEase = .{};
    defer e.deinit(testing.allocator);
    var rows: [4]TestRow = .{ .{}, .{}, .{}, .{} };
    defer for (&rows) |*r| r.verts.deinit(testing.allocator);
    e.beforeShift(0, 4, 1, input);
    e.seedAndRetain(&rows, 0, 4, 1, input);
    var now: i64 = 1;
    var frames: usize = 0;
    while (true) : (frames += 1) {
        e.plan(now, 10, 4);
        if (!e.moving()) break;
        try testing.expect(e.easing);
        now += std.time.ns_per_s / 60;
        try testing.expect(frames < 120);
    }
    try testing.expect(e.easing);
    try testing.expectEqual(@as(f32, 0), e.offset_px);
    e.plan(now + 1, 10, 4);
    try testing.expect(!e.easing);
}

test "a row height change voids the ease" {
    var e: GridEase = .{};
    defer e.deinit(testing.allocator);
    var rows: [4]TestRow = .{ .{}, .{}, .{}, .{} };
    defer for (&rows) |*r| r.verts.deinit(testing.allocator);
    e.beforeShift(0, 4, 1, input);
    e.seedAndRetain(&rows, 0, 4, 1, input);
    e.plan(2, 12, 4);
    try testing.expect(!e.moving());
}
