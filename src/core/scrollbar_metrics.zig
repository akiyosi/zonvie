//! Whether a viewport needs a scrollbar, and where its knob sits on the track.
//!
//! Both frontends worked this out from `zonvie_viewport_info`, and the two
//! answers differed in three places. macOS let a zero-row viewport count as
//! scrollable, divided by `max(1, line_count - visible)` so a window showing
//! everything reported a position of `topline` rather than 0, and relied on
//! AppKit clamping the result into a scroller's 0..1. Windows guarded both of
//! those and clamped neither end, so a window scrolled past EOF -- where
//! Neovim reports `botline` beyond `line_count` -- drew its knob below the
//! bottom of its own track.
//!
//! Only the part that is the same question lives here. Track rectangles,
//! DPI-scaled widths and a minimum knob height are chrome, and stay with the
//! frontend that draws them.

const std = @import("std");

pub const Metrics = extern struct {
    /// 1 when the buffer holds more lines than the viewport shows.
    is_scrollable: u8,
    /// Where the knob sits along its travel: 0 at the top, 1 at the bottom.
    /// Defined even when nothing scrolls, where it is 0.
    scroll_position: f64,
    /// How much of the track the knob covers, 0..1.
    knob_proportion: f64,
};

/// `botline` is exclusive, and Neovim reports it past `line_count` for a
/// window showing the region beyond the last line.
pub fn compute(topline: i64, botline: i64, line_count: i64) Metrics {
    // Both annotated: `@max` against a comptime 0 narrows to an unsigned type,
    // and `lines - visible` is legitimately negative for a window showing past
    // the end of its buffer.
    const visible: i64 = @max(0, botline - topline);
    const lines: i64 = @max(0, line_count);

    // A viewport showing no rows scrolls nothing, whatever the buffer holds.
    const scrollable = visible > 0 and lines > visible;

    const proportion: f64 = if (lines <= 0)
        // Nothing known about the buffer: a full knob says "nothing to scroll",
        // which is what the caller draws while a viewport is still unreported.
        1.0
    else
        @min(1.0, @as(f64, @floatFromInt(visible)) / @as(f64, @floatFromInt(lines)));

    const range = lines - visible;
    const position: f64 = if (range <= 0)
        0
    else
        // Clamped: past EOF `visible` covers rows the buffer does not have, so
        // `topline` can exceed the range and the raw ratio passes 1.
        @min(1.0, @max(0.0, @as(f64, @floatFromInt(topline)) / @as(f64, @floatFromInt(range))));

    return .{
        .is_scrollable = @intFromBool(scrollable),
        .scroll_position = position,
        .knob_proportion = proportion,
    };
}

// ── tests ────────────────────────────────────────────────────────────────

const testing = std.testing;

test "a window showing part of its buffer scrolls, with the knob in proportion" {
    const m = compute(0, 20, 100);
    try testing.expectEqual(@as(u8, 1), m.is_scrollable);
    try testing.expectEqual(@as(f64, 0), m.scroll_position);
    try testing.expectApproxEqAbs(@as(f64, 0.2), m.knob_proportion, 1e-9);
}

test "the knob reaches the bottom exactly when the last line is shown" {
    const m = compute(80, 100, 100);
    try testing.expectEqual(@as(u8, 1), m.is_scrollable);
    try testing.expectApproxEqAbs(@as(f64, 1.0), m.scroll_position, 1e-9);
}

test "a window showing everything does not scroll, and reports position 0" {
    // macOS divided by max(1, line_count - visible) here, so a buffer of 20
    // lines in a 20-row window reported `topline` as the position.
    const m = compute(0, 20, 20);
    try testing.expectEqual(@as(u8, 0), m.is_scrollable);
    try testing.expectEqual(@as(f64, 0), m.scroll_position);
    try testing.expectApproxEqAbs(@as(f64, 1.0), m.knob_proportion, 1e-9);
}

test "a zero-row viewport scrolls nothing however long the buffer is" {
    // macOS said scrollable and handed its scroller a zero-width knob.
    const m = compute(5, 5, 10_000);
    try testing.expectEqual(@as(u8, 0), m.is_scrollable);
}

test "scrolled past EOF the knob stops at the bottom of its track" {
    // The window shows 20 rows of a 100-line buffer starting at line 95, so
    // botline runs 15 lines past the end. range = 80 < topline = 95, and the
    // raw ratio is 1.19: Windows multiplied its knob travel by that and drew
    // the knob below its own track.
    const m = compute(95, 115, 100);
    try testing.expectEqual(@as(u8, 1), m.is_scrollable);
    try testing.expectApproxEqAbs(@as(f64, 1.0), m.scroll_position, 1e-9);
}

test "an unreported viewport asks for a full knob and no scrolling" {
    const m = compute(0, 0, 0);
    try testing.expectEqual(@as(u8, 0), m.is_scrollable);
    try testing.expectApproxEqAbs(@as(f64, 1.0), m.knob_proportion, 1e-9);
    try testing.expectEqual(@as(f64, 0), m.scroll_position);
}

test "a viewport reported backwards is treated as empty rather than negative" {
    const m = compute(30, 10, 100);
    try testing.expectEqual(@as(u8, 0), m.is_scrollable);
    try testing.expectApproxEqAbs(@as(f64, 0.0), m.knob_proportion, 1e-9);
}

test "the knob never covers more of the track than the buffer fills" {
    const m = compute(0, 500, 100);
    try testing.expectApproxEqAbs(@as(f64, 1.0), m.knob_proportion, 1e-9);
    try testing.expectEqual(@as(u8, 0), m.is_scrollable);
}
