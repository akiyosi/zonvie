//! `[window] titlebar_style = "hidden"`: a captionless window draws its
//! window buttons only while the pointer is in its caption band. The state
//! lives with the window (App for the main one, ExternalWindow for the rest);
//! this module decides it from the cursor and leaves the repaint to the caller.
const std = @import("std");
const core = @import("zonvie_core");
const app_mod = @import("../app.zig");
const App = app_mod.App;
const c = app_mod.c;

/// DWM's "hand the colour back to the system theme".
pub const DWMWA_COLOR_DEFAULT: c.COLORREF = 0xFFFFFFFF;

pub const CaptionColors = struct { caption: c.COLORREF, text: c.COLORREF };

/// A native caption's colours: tinted (in place of a title band)
/// with the editor's default bg/fg (0xRRGGBB, 0xFFFFFFFF = not yet known);
/// untinted, or with an unknown bg, the theme's.
pub fn captionColors(tint: bool, bg_rgb: u32, fg_rgb: u32) CaptionColors {
    const Pack = struct {
        fn colorref(rgb: u32) c.COLORREF {
            if (rgb == 0xFFFFFFFF) return DWMWA_COLOR_DEFAULT;
            return @intCast(((rgb & 0xFF) << 16) | (rgb & 0xFF00) | ((rgb >> 16) & 0xFF));
        }
    };
    if (!tint or bg_rgb == 0xFFFFFFFF) return .{ .caption = DWMWA_COLOR_DEFAULT, .text = DWMWA_COLOR_DEFAULT };
    return .{ .caption = Pack.colorref(bg_rgb), .text = Pack.colorref(fg_rgb) };
}

/// The chrome of a normal external window: it has no tabline of its own.
pub fn externalLayout(app: *const App) app_mod.config_mod.Config.TitlebarLayout {
    return .{ .style = app.config.window.titlebar_style, .tabline = .other };
}

pub const buttonsShown = core.frontend_rules.captionButtonsShown;
pub const inBand = core.frontend_rules.inCaptionBand;
pub const DragBar = core.frontend_rules.DragBar;

/// Run `step`'s timer action on `hwnd` and store its state. True when the
/// drawn bar changed.
pub fn applyDragBar(hwnd: c.HWND, bar: *DragBar, step: DragBar.Step) bool {
    switch (step.timer) {
        .keep => {},
        .set => _ = c.SetTimer(hwnd, app_mod.TIMER_DRAG_BAR_REVEAL, DragBar.reveal_ms, null),
        .kill => _ = c.KillTimer(hwnd, app_mod.TIMER_DRAG_BAR_REVEAL),
    }
    const changed = bar.revealed != step.next.revealed;
    bar.* = step.next;
    return changed;
}

/// An external window's self-drawn caption. Buttons: 0 minimize, 1 maximize,
/// 2 close, as TablineState numbers the main window's.
pub const ExternalCaption = struct {
    revealed: bool = false,
    hovered_btn: ?u8 = null,
    pressed_btn: ?u8 = null,
    drag_bar: DragBar = .{},
};

/// The window button under client (x, y): three `btn_w` slots at the right
/// end of the top `band_px`, close outermost.
pub fn buttonAt(btn_w: c_int, band_px: c_int, client_w: c_int, x: c_int, y: c_int) ?u8 {
    if (btn_w <= 0 or !inBand(band_px, client_w, x, y)) return null;
    const slot = @divTrunc(client_w - 1 - x, btn_w);
    return if (slot < 3) 2 - @as(u8, @intCast(slot)) else null;
}

/// Which mouse message drove the update; null for a leave notice.
pub const Source = enum { client, nonclient };

/// Recompute `revealed` from the cursor position. Returns true when it
/// changed; the caller repaints the band. While revealed it asks for the
/// leave notice of `source`, whose handler calls back with null: re-arming
/// from a leave notice would bounce between client and non-client forever.
pub fn update(hwnd: c.HWND, revealed: *bool, band_px: c_int, source: ?Source) bool {
    const now = pointerInBand(hwnd, band_px);
    if (now) if (source) |s| trackLeave(hwnd, s);
    if (now == revealed.*) return false;
    revealed.* = now;
    return true;
}

/// The live cursor is inside `hwnd` and in its top `band_px`. The one
/// "in the band" test for reveal and for both DragBar inputs, so a captured
/// pointer outside the window never counts.
pub fn pointerInBand(hwnd: c.HWND, band_px: c_int) bool {
    var pt: c.POINT = undefined;
    if (c.GetCursorPos(&pt) == 0) return false;
    var wr: c.RECT = undefined;
    _ = c.GetWindowRect(hwnd, &wr);
    const in_window = pt.x >= wr.left and pt.x < wr.right and pt.y >= wr.top and pt.y < wr.bottom;
    _ = c.ScreenToClient(hwnd, &pt);
    var client: c.RECT = undefined;
    _ = c.GetClientRect(hwnd, &client);
    return in_window and inBand(band_px, client.right, pt.x, pt.y);
}

fn trackLeave(hwnd: c.HWND, source: Source) void {
    var tme: c.TRACKMOUSEEVENT = .{
        .cbSize = @sizeOf(c.TRACKMOUSEEVENT),
        .dwFlags = if (source == .nonclient) c.TME_LEAVE | c.TME_NONCLIENT else c.TME_LEAVE,
        .hwndTrack = hwnd,
        .dwHoverTime = 0,
    };
    _ = c.TrackMouseEvent(&tme);
}

test "buttonAt: close, maximize, minimize from the right edge, band only" {
    try std.testing.expectEqual(@as(?u8, 2), buttonAt(46, 32, 400, 399, 0));
    try std.testing.expectEqual(@as(?u8, 2), buttonAt(46, 32, 400, 354, 31));
    try std.testing.expectEqual(@as(?u8, 1), buttonAt(46, 32, 400, 353, 0));
    try std.testing.expectEqual(@as(?u8, 0), buttonAt(46, 32, 400, 262, 0));
    try std.testing.expectEqual(@as(?u8, null), buttonAt(46, 32, 400, 261, 0));
    try std.testing.expectEqual(@as(?u8, null), buttonAt(46, 32, 400, 399, 32));
    try std.testing.expectEqual(@as(?u8, null), buttonAt(0, 32, 400, 399, 0));
}

test "captionColors: tinted swaps to COLORREF, else or unknown bg keeps the theme" {
    const theme: CaptionColors = .{ .caption = DWMWA_COLOR_DEFAULT, .text = DWMWA_COLOR_DEFAULT };
    try std.testing.expectEqual(CaptionColors{ .caption = 0x00332211, .text = 0x00665544 }, captionColors(true, 0x112233, 0x445566));
    try std.testing.expectEqual(theme, captionColors(false, 0x112233, 0x445566));
    try std.testing.expectEqual(theme, captionColors(true, 0xFFFFFFFF, 0x445566));
    try std.testing.expectEqual(CaptionColors{ .caption = 0x00332211, .text = DWMWA_COLOR_DEFAULT }, captionColors(true, 0x112233, 0xFFFFFFFF));
}

