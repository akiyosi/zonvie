//! One grid's smooth scroll (core scroll_ease.zig) and the rows that
//! scrolled out of it, kept drawable while the offset still shows the band
//! they left. Lives with the grid's committed rows, so it is touched only
//! under App.mu.

const std = @import("std");
const core = @import("zonvie_core");
const scroll_ease = core.scroll_ease;
const Vertex = core.Vertex;
const pixel_scroll = @import("pixel_scroll.zig");

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
    /// A trackpad gesture's hold on the offset (pixel_scroll.zig).
    hold: pixel_scroll.Hold = .{},

    pub fn deinit(self: *GridEase, alloc: std.mem.Allocator) void {
        for (&self.retained) |*r| r.verts.deinit(alloc);
    }

    /// The spring animates: frames must keep coming. A held offset only
    /// moves with input, which asks for its own frames.
    pub fn moving(self: *const GridEase) bool {
        return !self.hold.held and self.spring.moving();
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
        if (!self.hold.held) self.spring.tick(in.now_ns);
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
        view_moved: bool,
        in: ScrollInput,
    ) void {
        const seeded = if (self.hold.owns())
            self.creditGesture(row_start, row_end, rows_delta, in)
        else
            self.spring.seed(in.now_ns, view_moved, rows_delta, @intCast(in.row_h_px), row_start, row_end, in.mousescroll_ver, in.large_jump);
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
        if (!self.spring.moving() and !self.hold.held) self.dropRetained();
    }

    /// A gesture's answer: cancelled against the held offset instead of
    /// seeded, whatever its size, so the picture stays under the finger.
    fn creditGesture(self: *GridEase, row_start: u32, row_end: u32, rows_delta: i32, in: ScrollInput) bool {
        if (in.row_h_px == 0 or row_end <= row_start) return false;
        const s = &self.spring;
        s.row_h_px = @intCast(in.row_h_px);
        s.region_start = row_start;
        s.region_end = row_end;
        const h: f64 = @floatFromInt(in.row_h_px);
        s.spring.offset_px = pixel_scroll.credit(&self.hold, s.spring.offset_px, rows_delta, h, @max(1, in.mousescroll_ver));
        if (self.hold.held) s.spring.velocity_px_s = 0;
        if (s.spring.last_tick_ns == 0) s.spring.last_tick_ns = in.now_ns;
        return true;
    }

    /// One finger step of `delta_px` (positive moves the content down) over
    /// the scroll region [region_start, region_end). Takes the offset from
    /// the spring, which stands still until `release`. Returns the wheel
    /// events to send, positive "down". Pre: `row_h_px > 0`, `ver >= 1`.
    pub fn pan(self: *GridEase, delta_px: f64, region_start: u32, region_end: u32, row_h_px: u32, ver: i32, edge_now: ?bool, now_ns: i64) pixel_scroll.PanResult {
        const s = &self.spring;
        if (s.row_h_px != @as(i32, @intCast(row_h_px)) or s.region_start != region_start or s.region_end != region_end) {
            // An offset built against another region means nothing here.
            if (s.moving()) self.dropRetained();
            s.* = .{ .row_h_px = @intCast(row_h_px), .region_start = region_start, .region_end = region_end };
        }
        // A new hold asks the viewport afresh rather than trusting an edge
        // an earlier one inferred.
        if (!self.hold.held) self.hold.edge = 0;
        self.hold.held = true;
        s.spring.velocity_px_s = 0;
        const r = pixel_scroll.pan(&self.hold, s.spring.offset_px, .{
            .delta_px = delta_px,
            .row_h_px = @floatFromInt(row_h_px),
            .rows_per_event = ver,
            .edge_now = edge_now,
            .now_ns = now_ns,
        });
        s.spring.offset_px = r.offset_px;
        return r;
    }

    /// The gesture let go: the spring takes the offset back to rest, which
    /// is the bounce at an edge. Requests still in flight stay booked.
    pub fn release(self: *GridEase) void {
        if (!self.hold.held) return;
        self.hold.held = false;
        self.hold.edge = 0;
        self.spring.spring.velocity_px_s = 0;
        // The first tick after the lift integrates nothing.
        self.spring.spring.last_tick_ns = 0;
    }

    /// Advance the ease for a frame drawn at `now_ns` and settle whether it
    /// draws the grid eased. `row_limit` is the grid's committed row count.
    pub fn plan(self: *GridEase, now_ns: i64, row_h_px: u32, row_limit: usize) void {
        const s = &self.spring;
        const was_moving = s.moving();
        if (!self.hold.held) s.tick(now_ns);
        pixel_scroll.expireStale(&self.hold, now_ns);
        if (s.row_h_px != 0 and (s.row_h_px != @as(i32, @intCast(row_h_px)) or s.region_end > row_limit)) s.reset();
        if (!s.moving() and !self.hold.held) self.dropRetained();
        self.easing = (self.hold.held or was_moving or s.moving()) and s.region_end > s.region_start;
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
    e.seedAndRetain(&rows, 0, 4, 1, true, input);
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
    e.seedAndRetain(&rows, 0, 4, -1, true, input);
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
    e.seedAndRetain(&rows, 0, 4, 1, true, snap);
    try testing.expect(!e.retained[0].live);
    try testing.expect(!e.moving());
}

test "plan eases until rest, drawing the resting frame once" {
    var e: GridEase = .{};
    defer e.deinit(testing.allocator);
    var rows: [4]TestRow = .{ .{}, .{}, .{}, .{} };
    defer for (&rows) |*r| r.verts.deinit(testing.allocator);
    e.beforeShift(0, 4, 1, input);
    e.seedAndRetain(&rows, 0, 4, 1, true, input);
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
    e.seedAndRetain(&rows, 0, 4, 1, true, input);
    e.plan(2, 12, 4);
    try testing.expect(!e.moving());
}

test "a held pan stands still in plan, is credited by the answer and springs back on release" {
    var e: GridEase = .{};
    defer e.deinit(testing.allocator);
    var rows: [6]TestRow = .{ .{}, .{}, .{}, .{}, .{}, .{} };
    defer for (&rows) |*r| r.verts.deinit(testing.allocator);
    const r = e.pan(-4, 0, 6, 10, 3, false, 1);
    try testing.expectEqual(@as(i32, 1), r.events);
    // Held: frames draw it eased but do not move it, nor keep the tick alive.
    e.plan(1 + std.time.ns_per_s / 60, 10, 6);
    try testing.expect(e.easing);
    try testing.expectEqual(@as(f32, -4), e.offset_px);
    try testing.expect(!e.moving());
    // The answer: content up 3 rows, credited, the scrolled-out rows kept.
    try rows[3].verts.append(testing.allocator, vtx(-10));
    e.beforeShift(0, 6, 3, input);
    e.seedAndRetain(&rows, 0, 6, 3, true, input);
    try testing.expectEqual(@as(f64, 26), e.spring.spring.offset_px);
    try testing.expect(e.retained[0].live);
    e.release();
    try testing.expect(e.moving());
    var now: i64 = 2 * std.time.ns_per_s;
    var frames: usize = 0;
    while (e.moving()) : (frames += 1) {
        e.plan(now, 10, 6);
        now += std.time.ns_per_s / 60;
        try testing.expect(frames < 120);
    }
}

test "a stretch at the edge bounces back on release" {
    var e: GridEase = .{};
    defer e.deinit(testing.allocator);
    const r = e.pan(12, 0, 6, 10, 3, true, 1);
    try testing.expect(r.at_edge);
    try testing.expectEqual(@as(i32, 0), r.events);
    e.release();
    var now: i64 = 2;
    var frames: usize = 0;
    while (e.moving()) : (frames += 1) {
        e.plan(now, 10, 6);
        now += std.time.ns_per_s / 60;
        try testing.expect(frames < 120);
    }
    try testing.expectEqual(@as(f32, 0), e.offset_px);
}
