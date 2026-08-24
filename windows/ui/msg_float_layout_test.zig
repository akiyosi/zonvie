const std = @import("std");
const layout = @import("msg_float_layout.zig");

const target: layout.Rect = .{ .left = 0, .top = 0, .right = 1920, .bottom = 1080 };

test "x is measured from the right edge, not from a stored left edge" {
    const p = layout.msgFloatTopRight(target, 400, null);
    try std.testing.expectEqual(@as(i32, 1920 - 400 - 10), p.x);
    try std.testing.expectEqual(@as(i32, 10), p.y);
}

test "the right edge is invariant across every width" {
    // The regression: the geometry-update path resized in place with
    // SWP_NOMOVE, so a short message kept the previous long message's left
    // edge. Pinning the RIGHT edge is the whole contract — the left edge must
    // move whenever the width does.
    const widths = [_]i32{ 1, 80, 400, 401, 1200, 1910 };
    var previous_x: ?i32 = null;
    for (widths) |w| {
        const p = layout.msgFloatTopRight(target, w, null);
        try std.testing.expectEqual(target.right - layout.margin_px, p.x + w);
        if (previous_x) |prev| try std.testing.expect(p.x != prev);
        previous_x = p.x;
    }
}

test "a short message after a long one is not left where the long one was" {
    const long = layout.msgFloatTopRight(target, 900, null);
    const short = layout.msgFloatTopRight(target, 120, null);
    try std.testing.expect(short.x > long.x);
    try std.testing.expectEqual(long.x + 900, short.x + 120);
}

test "msg_show stacks below msg_history without changing its x" {
    const history = layout.msgFloatTopRight(target, 600, null);
    const history_bottom = history.y + 300;
    const show = layout.msgFloatTopRight(target, 240, history_bottom);
    try std.testing.expectEqual(history_bottom + layout.history_gap_px, show.y);
    try std.testing.expectEqual(target.right - layout.margin_px, show.x + 240);
}

test "placement follows a target rect that is not the screen origin" {
    // msg_pos = window/grid hands over the cursor window's rect in screen
    // coordinates, which is offset on both axes.
    const windowed: layout.Rect = .{ .left = 300, .top = 150, .right = 1400, .bottom = 900 };
    const p = layout.msgFloatTopRight(windowed, 500, null);
    try std.testing.expectEqual(@as(i32, 1400 - 500 - 10), p.x);
    try std.testing.expectEqual(@as(i32, 160), p.y);
}

test "a float wider than the target rect overhangs the left, never the right" {
    // Clamping is not this function's job, but the right edge must still hold
    // so the overflow is visibly on the side the user can scroll/resize from.
    const p = layout.msgFloatTopRight(target, 2400, null);
    try std.testing.expectEqual(target.right - layout.margin_px, p.x + 2400);
    try std.testing.expect(p.x < target.left);
}
