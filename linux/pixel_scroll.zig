//! The arithmetic of pixel-precise trackpad scrolling, as macOS's
//! SessionScrollModel does it: the content follows the finger by a sub-cell
//! offset, Neovim is asked for rows before the finger reaches them, and each
//! answer is cancelled against the offset so the picture never jumps. At a
//! buffer edge the offset stretches with resistance and springs back once the
//! fingers lift. Pure; its caller (trackpad.zig) and the grid's ease
//! (grid_ease.zig) own the state.
//!
//! Signs follow scroll_ease.zig: a positive offset draws the content lower,
//! and a positive `rows_delta` / pending count is content moving up (wheel
//! "down").

const std = @import("std");
const scroll_ease = @import("zonvie_core").scroll_ease;

/// Wheel events one pan step may send (macOS maxLookaheadEventsPerInput).
pub const max_events_per_input: i32 = 3;
/// Rubber-band depth at a buffer edge, in rows (macOS scrollMaxOverscrollCells).
pub const max_overscroll_rows: f64 = 2.0;
/// Requests unanswered this long were refused: the view is at an edge the
/// viewport did not show (macOS scrollEdgeFallbackSeconds).
pub const stale_ns: i64 = 200 * std.time.ns_per_ms;
/// Momentum friction per second; GTK's own kinetic scrolling uses 4.
pub const momentum_friction_per_s: f64 = 4.0;
/// Momentum below this speed, in device px/s, has ended.
pub const momentum_stop_px_s: f64 = 30.0;

/// One grid's gesture bookkeeping. Lives with the grid's ease, under App.mu.
pub const Hold = struct {
    /// A gesture (fingers or momentum) owns the offset: the spring stands
    /// still and arrivals are credited instead of seeded.
    held: bool = false,
    /// Rows asked of Neovim and not yet answered; positive asked for wheel
    /// "down" (content up).
    pending_rows: i32 = 0,
    /// When the oldest unanswered request was sent; 0 with none pending.
    pending_since_ns: i64 = 0,
    /// The direction Neovim refuses to scroll: +1 content cannot move down
    /// (top of buffer), -1 cannot move up (bottom), 0 none known.
    edge: i8 = 0,

    /// Whether a committed scroll of this grid is the gesture's to credit.
    pub fn owns(self: Hold) bool {
        return self.held or self.pending_rows != 0;
    }
};

pub const PanInput = struct {
    /// Finger travel in device px; positive moves the content down.
    delta_px: f64,
    row_h_px: f64,
    /// 'mousescroll' ver: rows one wheel event moves. Must be >= 1.
    rows_per_event: i32,
    /// The viewport shows Neovim cannot move the content in `delta_px`'s
    /// direction; null when the viewport is not known.
    edge_now: ?bool,
    now_ns: i64,
};

pub const PanResult = struct {
    offset_px: f64,
    /// Wheel events to send: positive "down", negative "up".
    events: i32,
    /// The pan pushed into a known edge and only stretched the offset.
    at_edge: bool,
};

/// Rows the offset may be drawn away from the committed rows: what the
/// retained rows can fill.
fn limitPx(row_h_px: f64) f64 {
    return @as(f64, @floatFromInt(scroll_ease.retention_depth_rows)) * row_h_px;
}

/// Moves `offset_px` by one finger step and books the requests the step
/// needs. Pre: `in.row_h_px > 0`, `in.rows_per_event >= 1`. Post: `hold`
/// counts the returned events; |offset| stays within the retention depth.
pub fn pan(hold: *Hold, offset_px: f64, in: PanInput) PanResult {
    std.debug.assert(in.row_h_px > 0 and in.rows_per_event >= 1);
    expireStale(hold, in.now_ns);
    if (in.delta_px == 0) return .{ .offset_px = offset_px, .events = 0, .at_edge = false };
    const dir: i8 = if (in.delta_px > 0) 1 else -1;
    const dir_f: f64 = @floatFromInt(dir);
    if (in.edge_now) |blocked| {
        if (blocked) {
            if (offset_px * dir_f >= 0) hold.edge = dir;
        } else if (hold.edge == dir) hold.edge = 0;
    }
    const limit = limitPx(in.row_h_px);
    if (hold.edge == dir and offset_px * dir_f >= 0) {
        return .{ .offset_px = std.math.clamp(rubberBand(offset_px, in.delta_px, in.row_h_px), -limit, limit), .events = 0, .at_edge = true };
    }
    // Moving away from an edge leaves it.
    if (hold.edge != 0 and hold.edge != dir) hold.edge = 0;
    const offset = std.math.clamp(offset_px + in.delta_px, -limit, limit);
    const step: i32 = in.rows_per_event;
    // Content moving down needs "up" events (negative pending), and the
    // arrivals take their rows back out of the offset: ask while the offset
    // is ahead of what is already asked for.
    const max_pending = 8 * step;
    var lookahead = offset + @as(f64, @floatFromInt(hold.pending_rows)) * in.row_h_px;
    var events: i32 = 0;
    while (lookahead * dir_f > 0 and @abs(events) < max_events_per_input and @abs(hold.pending_rows) + @as(u32, @intCast(step)) <= @as(u32, @intCast(max_pending))) {
        if (hold.pending_rows == 0) hold.pending_since_ns = in.now_ns;
        hold.pending_rows -= dir * step;
        events -= dir;
        lookahead -= dir_f * @as(f64, @floatFromInt(step)) * in.row_h_px;
    }
    return .{ .offset_px = offset, .events = events, .at_edge = false };
}

/// Finger travel against an edge: harder the further the offset already
/// stretched, none past `max_overscroll_rows`.
pub fn rubberBand(offset_px: f64, delta_px: f64, row_h_px: f64) f64 {
    const max_px = row_h_px * max_overscroll_rows;
    const frac = @min(1.0, @abs(offset_px) / max_px);
    return offset_px + delta_px * (1.0 - frac) * (1.0 - frac);
}

/// Requests Neovim left unanswered for `stale_ns` were refused: the view is
/// at the edge they pushed toward.
pub fn expireStale(hold: *Hold, now_ns: i64) void {
    if (hold.pending_rows == 0 or now_ns - hold.pending_since_ns < stale_ns) return;
    // Pending "up" (negative) pushed the content down: the top edge.
    hold.edge = if (hold.pending_rows < 0) 1 else -1;
    hold.pending_rows = 0;
    hold.pending_since_ns = 0;
}

/// Neovim moved the content `rows_delta` rows: what the offset becomes so
/// the picture stays where the finger left it (macOS
/// ScrollRetention.creditedOffsetPx for the driving window). Booked rows are
/// credited, not reported ones: a 'wrap'ped line answers one event with every
/// row it spans. An answer clears a known edge. Pre: `row_h_px > 0`.
pub fn credit(hold: *Hold, offset_px: f64, rows_delta: i32, row_h_px: f64, rows_per_event: i32) f64 {
    std.debug.assert(row_h_px > 0);
    hold.edge = 0;
    const booked = hold.pending_rows;
    var credited: i32 = rows_delta;
    // An answer in the booked direction pays at most the booking.
    if (booked != 0 and (booked > 0) == (rows_delta > 0)) {
        const consumed: i32 = @intCast(@min(@abs(booked), @abs(rows_delta)));
        credited = if (rows_delta < 0) -consumed else consumed;
        hold.pending_rows -= credited;
    }
    hold.pending_since_ns = if (hold.pending_rows == 0) 0 else hold.pending_since_ns;
    var offset = offset_px + @as(f64, @floatFromInt(credited)) * row_h_px;
    // Handing back may overshoot zero by one step, the allowance the
    // lookahead runs on; a credit pushing away from zero may not deepen an
    // offset that already holds something.
    const step_px = row_h_px * @as(f64, @floatFromInt(@max(1, rows_per_event)));
    const deepens = offset_px == 0 or (offset < 0) == (offset_px < 0);
    const cap = if (deepens) (if (offset_px == 0) step_px else @abs(offset_px)) else step_px;
    offset = std.math.clamp(offset, -cap, cap);
    return if (@abs(offset) < scroll_ease.epsilon_px) 0 else offset;
}

/// Momentum after a lift: the travel of one frame of `dt_s` and the speed
/// left, in px and px/s. Zero speed once it falls below the stop speed.
pub fn momentumStep(velocity_px_s: f64, dt_s: f64) struct { delta_px: f64, velocity_px_s: f64 } {
    const f = @exp(-momentum_friction_per_s * @max(dt_s, 0));
    // Exact travel of an exponentially decaying speed over the frame.
    const delta = velocity_px_s * (1.0 - f) / momentum_friction_per_s;
    const v = velocity_px_s * f;
    return .{ .delta_px = delta, .velocity_px_s = if (@abs(v) < momentum_stop_px_s) 0 else v };
}

/// Whole steps out of a running sum of fractional ones (a high-resolution
/// wheel, or pixels over a step size); the remainder stays in `acc`.
pub fn takeSteps(acc: *f64, delta: f64) i32 {
    acc.* += delta;
    const steps = @trunc(acc.*);
    acc.* -= steps;
    return @intFromFloat(std.math.clamp(steps, -64, 64));
}

/// A horizontal trackpad swipe as wheel events: one per `step_px` travelled
/// ('mousescroll' hor columns), and nothing for sideways jitter of a mostly
/// vertical swipe, which also drops what was gathered (macOS
/// HorizontalScrollAccumulator). Positive is "right".
pub fn horizontalSteps(acc: *f64, dx_px: f64, dy_px: f64, step_px: f64) i32 {
    if (dx_px == 0) return 0;
    if (step_px <= 0 or @abs(dx_px) <= @abs(dy_px)) {
        acc.* = 0;
        return 0;
    }
    return takeSteps(acc, dx_px / step_px);
}

/// Whether Neovim can move the view no further in the content direction
/// `dir` (+1 content down, toward the buffer's top), from its viewport.
pub fn edgeFromViewport(topline: i64, line_count: i64, dir: i8) ?bool {
    if (line_count <= 0) return null;
    return if (dir > 0) topline <= 0 else topline >= line_count - 1;
}

const testing = std.testing;

fn testStep(delta: f64, now: i64) PanInput {
    return .{ .delta_px = delta, .row_h_px = 10, .rows_per_event = 3, .edge_now = false, .now_ns = now };
}

test "the first pixel asks for the next event and the answer keeps the picture" {
    var h: Hold = .{};
    // Finger moves the content up by 4 px: wheel "down".
    const r = pan(&h, 0, testStep(-4, 1));
    try testing.expectEqual(@as(f64, -4), r.offset_px);
    try testing.expectEqual(@as(i32, 1), r.events);
    try testing.expectEqual(@as(i32, 3), h.pending_rows);
    // A further pixel within the booked rows asks for nothing more.
    const r2 = pan(&h, r.offset_px, testStep(-1, 2));
    try testing.expectEqual(@as(i32, 0), r2.events);
    // Neovim moved the content up 3 rows: drawn 3 rows lower, 5 px above
    // where it started.
    const off = credit(&h, r2.offset_px, 3, 10, 3);
    try testing.expectEqual(@as(f64, 25), off);
    try testing.expectEqual(@as(i32, 0), h.pending_rows);
    try testing.expect(!h.owns());
}

test "a fast step books at most three events" {
    var h: Hold = .{};
    const r = pan(&h, 0, testStep(-75, 1));
    try testing.expectEqual(@as(i32, 3), r.events);
    try testing.expectEqual(@as(i32, 9), h.pending_rows);
}

test "content moving down asks for wheel up" {
    var h: Hold = .{};
    const r = pan(&h, 0, testStep(2, 1));
    try testing.expectEqual(@as(i32, -1), r.events);
    try testing.expectEqual(@as(i32, -3), h.pending_rows);
    try testing.expectEqual(@as(f64, -28), credit(&h, r.offset_px, -3, 10, 3));
}

test "an over-reported answer credits only the booking" {
    var h: Hold = .{};
    _ = pan(&h, 0, testStep(-4, 1));
    // A wrapped line answered with 12 rows: only the 3 booked are credited.
    try testing.expectEqual(@as(f64, 26), credit(&h, -4, 12, 10, 3));
}

test "a known edge stretches with resistance and sends nothing" {
    var h: Hold = .{};
    var input = testStep(10, 1);
    input.edge_now = true;
    const r = pan(&h, 0, input);
    try testing.expect(r.at_edge);
    try testing.expectEqual(@as(i32, 0), r.events);
    try testing.expectEqual(@as(f64, 10), r.offset_px);
    const r2 = pan(&h, r.offset_px, input);
    try testing.expect(r2.offset_px < 20 and r2.offset_px > 10);
    // Fully stretched, the band no longer moves.
    try testing.expectEqual(@as(f64, 20), pan(&h, 20, input).offset_px);
    // Pulling back leaves the edge.
    input.delta_px = -5;
    input.edge_now = null;
    const back = pan(&h, 20, input);
    try testing.expect(!back.at_edge);
    try testing.expectEqual(@as(i8, 0), h.edge);
}

test "unanswered requests expire into an edge" {
    var h: Hold = .{};
    _ = pan(&h, 0, testStep(3, 1));
    try testing.expectEqual(@as(i32, -3), h.pending_rows);
    expireStale(&h, 1 + stale_ns);
    try testing.expectEqual(@as(i32, 0), h.pending_rows);
    try testing.expectEqual(@as(i8, 1), h.edge);
    var input = testStep(3, 2 + stale_ns);
    input.edge_now = null;
    try testing.expect(pan(&h, 3, input).at_edge);
}

test "the offset never leaves the retention depth" {
    var h: Hold = .{};
    const r = pan(&h, 0, testStep(-1000, 1));
    try testing.expectEqual(@as(f64, -80), r.offset_px);
}

test "momentum decays to a stop and travels v / friction" {
    var v: f64 = 2000;
    var travelled: f64 = 0;
    var frames: usize = 0;
    while (v != 0) : (frames += 1) {
        const s = momentumStep(v, 1.0 / 60.0);
        travelled += s.delta_px;
        v = s.velocity_px_s;
        try testing.expect(frames < 600);
    }
    try testing.expect(travelled > 480 and travelled <= 500);
}

test "fractional wheel steps add up to whole events" {
    var acc: f64 = 0;
    try testing.expectEqual(@as(i32, 0), takeSteps(&acc, 0.5));
    try testing.expectEqual(@as(i32, 1), takeSteps(&acc, 0.5));
    try testing.expectEqual(@as(i32, -1), takeSteps(&acc, -1.0));
    try testing.expectEqual(@as(i32, 1), takeSteps(&acc, 1.0));
}

test "a horizontal swipe sends one event per step and ignores jitter" {
    var acc: f64 = 0;
    try testing.expectEqual(@as(i32, 0), horizontalSteps(&acc, 15, 2, 24));
    try testing.expectEqual(@as(i32, 1), horizontalSteps(&acc, 15, 2, 24));
    // Mostly vertical: dropped, and the gathered travel with it.
    try testing.expectEqual(@as(i32, 0), horizontalSteps(&acc, 3, 10, 24));
    try testing.expectEqual(@as(f64, 0), acc);
    try testing.expectEqual(@as(i32, -2), horizontalSteps(&acc, -50, 0, 24));
}

test "the viewport names the edges" {
    try testing.expectEqual(@as(?bool, true), edgeFromViewport(0, 100, 1));
    try testing.expectEqual(@as(?bool, false), edgeFromViewport(0, 100, -1));
    try testing.expectEqual(@as(?bool, true), edgeFromViewport(99, 100, -1));
    try testing.expectEqual(@as(?bool, null), edgeFromViewport(0, 0, 1));
}
