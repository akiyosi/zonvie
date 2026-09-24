//! Where an external popupmenu window goes relative to the cell it completes.
//!
//! Both frontends prefer the popup below the anchor cell and flip it above
//! when it does not fit, but they asked "fits" of different things: macOS of
//! the reference window (the editor or the external window holding the
//! anchor), Windows of the monitor's work area. Near the bottom of a window
//! that is not at the bottom of the screen the popup hung below the window
//! on Windows and flipped up on macOS. Neovim's own popupmenu flips when the
//! editor has no room below, which is the reference-window answer.
//!
//! Y grows downward, in whatever unit the caller measures both axes in.

const std = @import("std");

/// The popup's top edge. `anchor_top`/`anchor_height` are the anchor cell,
/// `ref_bottom` the bottom edge of the window the anchor is in, and
/// `screen_top` the top of the usable screen area.
pub fn top(anchor_top: i32, anchor_height: i32, popup_height: i32, ref_bottom: i32, screen_top: i32) i32 {
    const below = anchor_top +| anchor_height;
    if (below +| popup_height <= ref_bottom) return below;
    const above = anchor_top -| popup_height;
    if (above >= screen_top) return above;
    return below;
}

/// The top edge of a cmdline completion popup: `gap` above the cmdline window
/// (`cmdline_top`..`cmdline_bottom`) while it clears `screen_top`, else `gap`
/// below it. Windows used to place it above unconditionally, off-screen when
/// the cmdline sat near the top.
pub fn cmdlineTop(cmdline_top: i32, cmdline_bottom: i32, popup_height: i32, gap: i32, screen_top: i32) i32 {
    const above = cmdline_top -| gap -| popup_height;
    if (above >= screen_top) return above;
    return cmdline_bottom +| gap;
}

test "cmdline completion sits above the cmdline, flipping below with no room" {
    // Cmdline at 500..540, popup 200 tall, 4px gap, screen from 0.
    try std.testing.expectEqual(@as(i32, 296), cmdlineTop(500, 540, 200, 4, 0));
    // Exactly reaching the screen top still fits above.
    try std.testing.expectEqual(@as(i32, 0), cmdlineTop(204, 244, 200, 4, 0));
    // One pixel short: below the cmdline.
    try std.testing.expectEqual(@as(i32, 247), cmdlineTop(203, 243, 200, 4, 0));
}

test "prefers below the anchor while the popup fits in the reference window" {
    // Anchor row 100..120, popup 200 tall, window bottom at 400.
    try std.testing.expectEqual(@as(i32, 120), top(100, 20, 200, 400, 0));
    // Exactly reaching the bottom still fits.
    try std.testing.expectEqual(@as(i32, 120), top(100, 20, 280, 400, 0));
}

test "flips above when the window has no room below, whatever the screen has" {
    // 300 tall would end at 420, past the window bottom at 400: above.
    try std.testing.expectEqual(@as(i32, -200), top(100, 20, 300, 400, -1000));
}

test "stays below when neither side fits" {
    // Above would start at -200, off the top of the screen at 0.
    try std.testing.expectEqual(@as(i32, 120), top(100, 20, 300, 400, 0));
}
