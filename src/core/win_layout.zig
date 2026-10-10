//! Window-layout operations over OS windows: `win_move`, `win_exchange`,
//! `win_rotate`, `win_resize_equal` and `win_move_cursor`.
//!
//! Both frontends answered these with their own copies of the same geometry --
//! the direction search, the spatial order, the swap, the rotation, the
//! averaging -- and the copies had drifted: macOS sorted with a 20pt row band
//! that is not a strict order, Windows compared centres exactly; macOS looped a
//! rotation `count` times and trapped on a negative one, Windows reduced it.
//! This is the one copy. A frontend collects its windows' frames, asks for a
//! plan, and applies the frames it gets back.
//!
//! Frames are top-left origin, y growing down, in whatever unit the frontend
//! uses; only comparisons and top-left positions matter, so macOS passes
//! `y = -maxY` without knowing the screen height.

const std = @import("std");

pub const Frame = extern struct {
    id: i64,
    x: f64,
    y: f64,
    w: f64,
    h: f64,

    fn cx(self: Frame) f64 {
        return self.x + self.w / 2;
    }
    fn cy(self: Frame) f64 {
        return self.y + self.h / 2;
    }
};

/// Neovim's direction codes for win_move / win_move_cursor.
pub const Direction = enum(i32) { down = 0, up = 1, right = 2, left = 3, _ };

/// Order `frames` top to bottom, then left to right. Centres within
/// `row_band` of the first centre of a row belong to that row, so windows a
/// few pixels apart in height still read as side by side. Deterministic: rows
/// are cut from the centres in vertical order, not decided pairwise.
pub fn sortSpatially(frames: []Frame, row_band: f64) void {
    std.mem.sort(Frame, frames, {}, lessByCy);
    var start: usize = 0;
    while (start < frames.len) {
        const row_cy = frames[start].cy();
        var end = start + 1;
        while (end < frames.len and frames[end].cy() - row_cy <= row_band) : (end += 1) {}
        std.mem.sort(Frame, frames[start..end], {}, lessByCx);
        start = end;
    }
}

fn lessByCy(_: void, a: Frame, b: Frame) bool {
    return a.cy() < b.cy();
}
fn lessByCx(_: void, a: Frame, b: Frame) bool {
    return a.cx() < b.cx();
}

fn indexOf(frames: []const Frame, id: i64) ?usize {
    for (frames, 0..) |f, i| if (f.id == id) return i;
    return null;
}

/// The `count`-th nearest window from `source_id` in `direction` (1-based,
/// 0 meaning 1; past the last candidate, the nearest), or the nearest overall
/// when nothing lies that way -- windows whose centres align on the tested
/// axis would otherwise never be reachable. Distance is Manhattan between
/// centres, ties broken by position in `frames`.
pub fn findInDirection(frames: []const Frame, source_id: i64, direction: Direction, count: i32) ?usize {
    if (frames.len > max_frames) return null;
    const src = frames[indexOf(frames, source_id) orelse return null];
    var candidates: [max_frames]Candidate = undefined;
    var n: usize = 0;
    for (frames, 0..) |win, i| {
        if (win.id == source_id or !inDirection(win, src, direction)) continue;
        candidates[n] = .{ .index = i, .dist = distance(win, src) };
        n += 1;
    }
    if (n == 0) {
        for (frames, 0..) |win, i| {
            if (win.id == source_id) continue;
            candidates[n] = .{ .index = i, .dist = distance(win, src) };
            n += 1;
        }
    }
    if (n == 0) return null;
    std.mem.sort(Candidate, candidates[0..n], {}, Candidate.less);
    const rank: usize = if (count <= 1) 0 else @intCast(count - 1);
    return candidates[if (rank < n) rank else 0].index;
}

const Candidate = struct {
    index: usize,
    dist: f64,
    fn less(_: void, a: Candidate, b: Candidate) bool {
        return a.dist < b.dist or (a.dist == b.dist and a.index < b.index);
    }
};

fn distance(a: Frame, b: Frame) f64 {
    return @abs(a.cx() - b.cx()) + @abs(a.cy() - b.cy());
}

fn inDirection(win: Frame, src: Frame, direction: Direction) bool {
    return switch (direction) {
        .down => win.cy() > src.cy(),
        .up => win.cy() < src.cy(),
        .right => win.cx() > src.cx(),
        .left => win.cx() < src.cx(),
        _ => false,
    };
}

/// Swap two windows' top-left corners, each keeping its own size.
fn swapPositions(a: *Frame, b: *Frame) void {
    const ax = a.x;
    const ay = a.y;
    a.x = b.x;
    a.y = b.y;
    b.x = ax;
    b.y = ay;
}

pub const Op = enum(i32) { move = 0, exchange = 1, rotate = 2, resize_equal = 3, _ };

/// Plan `op` over `frames` in place. `arg` is the direction for `move` and
/// `rotate` (0 = down/forward, anything else = up/backward for rotate), and
/// ignored otherwise. Returns whether any frame changed; the frontend applies
/// every frame when it did. Frames come back in their original order.
pub fn plan(op: Op, arg: i32, count: i32, source_id: i64, row_band: f64, frames: []Frame) bool {
    if (frames.len < 2 or frames.len > max_frames) return false;
    switch (op) {
        .move => {
            const si = indexOf(frames, source_id) orelse return false;
            const ti = findInDirection(frames, source_id, @enumFromInt(arg), 1) orelse return false;
            swapPositions(&frames[si], &frames[ti]);
            return true;
        },
        .exchange => {
            const order = spatialOrder(frames, row_band);
            const si = indexInOrder(order.slice(), frames, source_id) orelse return false;
            const n: i64 = @intCast(frames.len);
            const step: i64 = if (count == 0) 1 else count;
            const di: usize = @intCast(@mod(@as(i64, @intCast(si)) + step, n));
            if (di == si) return false;
            swapPositions(&frames[order.items[si]], &frames[order.items[di]]);
            return true;
        },
        .rotate => {
            // A negative count is malformed; a huge one reduces modulo n
            // rather than doing count x n work.
            if (count < 0) return false;
            const n = frames.len;
            const k: usize = @mod(if (count == 0) @as(usize, 1) else @as(usize, @intCast(count)), n);
            if (k == 0) return false;
            const order = spatialOrder(frames, row_band);
            var xs: [max_frames]f64 = undefined;
            var ys: [max_frames]f64 = undefined;
            for (order.slice(), 0..) |fi, i| {
                xs[i] = frames[fi].x;
                ys[i] = frames[fi].y;
            }
            for (order.slice(), 0..) |fi, i| {
                // Forward: each window takes the position of the one k before.
                const src = if (arg == 0) (i + n - k) % n else (i + k) % n;
                frames[fi].x = xs[src];
                frames[fi].y = ys[src];
            }
            return true;
        },
        .resize_equal => {
            var total_w: f64 = 0;
            var total_h: f64 = 0;
            for (frames) |f| {
                total_w += f.w;
                total_h += f.h;
            }
            const n: f64 = @floatFromInt(frames.len);
            // Top-left corners stay; only the sizes change.
            for (frames) |*f| {
                f.w = total_w / n;
                f.h = total_h / n;
            }
            return true;
        },
        _ => return false,
    }
}

/// Windows a frontend can hand in at once; more is refused rather than
/// allocated for on a user command.
pub const max_frames = 64;

const Order = struct {
    items: [max_frames]usize = undefined,
    len: usize = 0,
    fn slice(self: *const Order) []const usize {
        return self.items[0..self.len];
    }
};

/// Caller has checked frames.len <= max_frames.
fn spatialOrder(frames: []const Frame, row_band: f64) Order {
    var sorted: [max_frames]Frame = undefined;
    const n = frames.len;
    @memcpy(sorted[0..n], frames[0..n]);
    sortSpatially(sorted[0..n], row_band);
    var order = Order{ .len = n };
    for (sorted[0..n], 0..) |f, i| order.items[i] = indexOf(frames, f.id).?;
    return order;
}

fn indexInOrder(order: []const usize, frames: []const Frame, id: i64) ?usize {
    for (order, 0..) |fi, i| if (frames[fi].id == id) return i;
    return null;
}

// ---------------------------------------------------------------------------

fn fr(id: i64, x: f64, y: f64, w: f64, h: f64) Frame {
    return .{ .id = id, .x = x, .y = y, .w = w, .h = h };
}

test "side-by-side windows a few pixels apart in height are one row" {
    var frames = [_]Frame{ fr(2, 500, 10, 400, 300), fr(1, 0, 0, 400, 300), fr(3, 0, 400, 400, 300) };
    sortSpatially(&frames, 20);
    try std.testing.expectEqual(@as(i64, 1), frames[0].id);
    try std.testing.expectEqual(@as(i64, 2), frames[1].id);
    try std.testing.expectEqual(@as(i64, 3), frames[2].id);
}

test "a direction search takes the nearest window that way, else the nearest at all" {
    const frames = [_]Frame{ fr(1, 0, 0, 100, 100), fr(2, 200, 0, 100, 100), fr(3, 400, 0, 100, 100), fr(4, 0, 200, 100, 100) };
    try std.testing.expectEqual(@as(?usize, 1), findInDirection(&frames, 1, .right, 1));
    try std.testing.expectEqual(@as(?usize, 2), findInDirection(&frames, 1, .right, 2));
    try std.testing.expectEqual(@as(?usize, 3), findInDirection(&frames, 1, .down, 1));
    // Nothing above window 1: the nearest overall.
    try std.testing.expectEqual(@as(?usize, 1), findInDirection(&frames, 1, .up, 1));
}

test "move swaps corners with the window in that direction, sizes kept" {
    var frames = [_]Frame{ fr(1, 0, 0, 100, 50), fr(2, 200, 0, 300, 80) };
    try std.testing.expect(plan(.move, @intFromEnum(Direction.right), 1, 1, 20, &frames));
    try std.testing.expectEqual(Frame{ .id = 1, .x = 200, .y = 0, .w = 100, .h = 50 }, frames[0]);
    try std.testing.expectEqual(Frame{ .id = 2, .x = 0, .y = 0, .w = 300, .h = 80 }, frames[1]);
}

test "exchange swaps with the next window in reading order" {
    var frames = [_]Frame{ fr(1, 0, 0, 100, 100), fr(2, 200, 0, 100, 100), fr(3, 0, 200, 100, 100) };
    try std.testing.expect(plan(.exchange, 0, 0, 2, 20, &frames));
    try std.testing.expectEqual(@as(f64, 0), frames[1].x);
    try std.testing.expectEqual(@as(f64, 200), frames[1].y);
    try std.testing.expectEqual(@as(f64, 200), frames[2].x);
    try std.testing.expectEqual(@as(f64, 0), frames[2].y);
}

test "rotate refuses a negative count and reduces a huge one" {
    var frames = [_]Frame{ fr(1, 0, 0, 100, 100), fr(2, 200, 0, 100, 100), fr(3, 400, 0, 100, 100) };
    try std.testing.expect(!plan(.rotate, 0, -1, 0, 20, &frames));
    try std.testing.expectEqual(@as(f64, 0), frames[0].x);
    // 3 windows: a count of 3 is a full turn and changes nothing.
    try std.testing.expect(!plan(.rotate, 0, 3, 0, 20, &frames));
    // One step forward: each takes the position of the one before it.
    try std.testing.expect(plan(.rotate, 0, std.math.maxInt(i32), 0, 20, &frames));
    const k: usize = @mod(@as(usize, std.math.maxInt(i32)), 3);
    try std.testing.expectEqual(@as(usize, 1), k);
    // Window 0 wraps to the last window's position.
    try std.testing.expectEqual(@as(f64, 400), frames[0].x);
    try std.testing.expectEqual(@as(f64, 0), frames[1].x);
    try std.testing.expectEqual(@as(f64, 200), frames[2].x);
}

test "resize_equal averages sizes and keeps every top-left corner" {
    var frames = [_]Frame{ fr(1, 10, 20, 100, 50), fr(2, 300, 40, 300, 150) };
    try std.testing.expect(plan(.resize_equal, 0, 0, 0, 20, &frames));
    try std.testing.expectEqual(Frame{ .id = 1, .x = 10, .y = 20, .w = 200, .h = 100 }, frames[0]);
    try std.testing.expectEqual(Frame{ .id = 2, .x = 300, .y = 40, .w = 200, .h = 100 }, frames[1]);
}
