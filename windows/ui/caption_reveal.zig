//! `[window] titlebar_style = "hidden"`: a captionless window draws its
//! window buttons only while the pointer is in its caption band. The state
//! lives with the window (App for the main one, ExternalWindow for the rest);
//! this module decides it from the cursor and leaves the repaint to the caller.
const std = @import("std");
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

/// Whether the window buttons are drawn: always without hover reveal; with
/// it while revealed, or while one is held pressed so its release lands on
/// what the user sees.
pub fn buttonsShown(reveal_on: bool, revealed: bool, pressed: bool) bool {
    return !reveal_on or revealed or pressed;
}

/// Client point (x, y) in the top `band_px` of a `client_w` wide client.
pub fn inBand(band_px: c_int, client_w: c_int, x: c_int, y: c_int) bool {
    return x >= 0 and x < client_w and y >= 0 and y < band_px;
}

/// The bar that drags a captionless window, revealed after the pointer rests
/// in the band off the buttons. One state machine for the main and the
/// external windows; the transitions are pure and the caller runs the timer.
pub const DragBar = struct {
    revealed: bool = false,
    timer_armed: bool = false,
    /// When the pending rest began; meaningful only while `timer_armed`.
    armed_at_ms: u64 = 0,

    /// How long the pointer rests in the band before the bar shows.
    pub const reveal_ms: u32 = 2000;

    pub const Timer = enum { keep, set, kill };
    pub const Step = struct { next: DragBar, timer: Timer = .keep };

    /// The pointer moved or left at `now_ms`. `in_band`: it is inside the
    /// window and in the top band; `on_button`: over a caption button;
    /// `allowed`: the window may show the bar now.
    pub fn onPointer(self: DragBar, in_band: bool, on_button: bool, allowed: bool, now_ms: u64) Step {
        if (on_button) return .{ .next = self };
        if (in_band and allowed) {
            if (self.revealed or self.timer_armed) return .{ .next = self };
            return .{ .next = .{ .timer_armed = true, .armed_at_ms = now_ms }, .timer = .set };
        }
        return .{ .next = .{}, .timer = if (self.timer_armed) .kill else .keep };
    }

    /// The reveal timer's WM_TIMER arrived at `now_ms`. KillTimer and a
    /// re-arming SetTimer leave a WM_TIMER already queued, so a fire is
    /// stale unless armed and a rest has nearly elapsed: a stale fire keeps
    /// the live timer. Half the delay separates the two, since a stale fire
    /// lands right after a re-arm while timer and tick resolution jitter by
    /// one clock tick.
    pub fn onTimer(self: DragBar, in_band: bool, allowed: bool, now_ms: u64) Step {
        if (!self.timer_armed) return .{ .next = self };
        if (now_ms -| self.armed_at_ms < reveal_ms / 2) return .{ .next = self };
        return .{ .next = .{ .revealed = in_band and allowed }, .timer = .kill };
    }
};

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

test "buttonsShown: hidden only with reveal on, not revealed and nothing pressed" {
    try std.testing.expect(buttonsShown(false, false, false));
    try std.testing.expect(!buttonsShown(true, false, false));
    try std.testing.expect(buttonsShown(true, true, false));
    try std.testing.expect(buttonsShown(true, false, true));
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

test "DragBar: arms in the band, reveals after a full rest, conceals outside" {
    const t0: u64 = 10_000;
    const due = t0 + DragBar.reveal_ms;
    const idle: DragBar = .{};
    // Off the band or not allowed: nothing to arm.
    try std.testing.expectEqual(DragBar.Step{ .next = idle }, idle.onPointer(false, false, true, t0));
    try std.testing.expectEqual(DragBar.Step{ .next = idle }, idle.onPointer(true, false, false, t0));
    // Over a button: the bar keeps whatever it had.
    try std.testing.expectEqual(DragBar.Step{ .next = idle }, idle.onPointer(true, true, true, t0));
    // In the band: arm once, stamped with the rest's start.
    const armed = idle.onPointer(true, false, true, t0);
    try std.testing.expectEqual(DragBar.Step{ .next = .{ .timer_armed = true, .armed_at_ms = t0 }, .timer = .set }, armed);
    try std.testing.expectEqual(DragBar.Step{ .next = armed.next }, armed.next.onPointer(true, false, true, t0 + 500));
    // Resting on a button edge keeps the timer running.
    try std.testing.expectEqual(DragBar.Step{ .next = armed.next }, armed.next.onPointer(true, true, true, t0 + 500));
    // Leaving while armed kills the timer.
    try std.testing.expectEqual(DragBar.Step{ .next = idle, .timer = .kill }, armed.next.onPointer(false, false, true, t0 + 500));
    // An editor drag starting while armed kills the pending reveal.
    try std.testing.expectEqual(DragBar.Step{ .next = idle, .timer = .kill }, armed.next.onPointer(true, false, false, t0 + 500));
    // A full rest reveals only while the pointer is still in the band and
    // allowed; every due fire kills the timer.
    try std.testing.expectEqual(DragBar.Step{ .next = .{ .revealed = true }, .timer = .kill }, armed.next.onTimer(true, true, due));
    try std.testing.expectEqual(DragBar.Step{ .next = idle, .timer = .kill }, armed.next.onTimer(false, true, due));
    try std.testing.expectEqual(DragBar.Step{ .next = idle, .timer = .kill }, armed.next.onTimer(true, false, due));
    // Tick jitter: a fire one clock tick early still counts.
    try std.testing.expectEqual(DragBar.Step{ .next = .{ .revealed = true }, .timer = .kill }, armed.next.onTimer(true, true, due - 16));
    // Stale fires: none armed, or queued before a re-arm, keep the live timer.
    try std.testing.expectEqual(DragBar.Step{ .next = idle }, idle.onTimer(true, true, due));
    const rearmed = idle.onPointer(true, false, true, due).next;
    try std.testing.expectEqual(DragBar.Step{ .next = rearmed }, rearmed.onTimer(true, true, due + 1));
    // A stale fire keeps the timer even out of the band: concealing is the
    // pointer's job, not a stale message's.
    try std.testing.expectEqual(DragBar.Step{ .next = rearmed }, rearmed.onTimer(false, true, due + 1));
    try std.testing.expectEqual(DragBar.Step{ .next = rearmed }, rearmed.onTimer(true, false, due + 1));
    // The rest threshold is half the delay: one ms short is stale, at it is due.
    const half = DragBar.reveal_ms / 2;
    try std.testing.expectEqual(DragBar.Step{ .next = rearmed }, rearmed.onTimer(true, true, due + half - 1));
    try std.testing.expectEqual(DragBar.Step{ .next = .{ .revealed = true }, .timer = .kill }, rearmed.onTimer(true, true, due + half));
    // Revealed: stays in the band and over buttons, conceals outside or on a drag.
    const shown: DragBar = .{ .revealed = true };
    try std.testing.expectEqual(DragBar.Step{ .next = shown }, shown.onPointer(true, false, true, due));
    try std.testing.expectEqual(DragBar.Step{ .next = shown }, shown.onPointer(true, true, true, due));
    try std.testing.expectEqual(DragBar.Step{ .next = idle }, shown.onPointer(false, false, true, due));
    try std.testing.expectEqual(DragBar.Step{ .next = idle }, shown.onPointer(true, false, false, due));
    try std.testing.expectEqual(DragBar.Step{ .next = shown }, shown.onTimer(true, true, due));
    try std.testing.expectEqual(DragBar.Step{ .next = shown }, shown.onTimer(false, true, due));
    try std.testing.expectEqual(DragBar.Step{ .next = shown }, shown.onTimer(true, false, due));
}

test "inBand: the top band_px rows across the client width" {
    try std.testing.expect(inBand(32, 400, 0, 0));
    try std.testing.expect(inBand(32, 400, 399, 31));
    try std.testing.expect(!inBand(32, 400, 399, 32));
    try std.testing.expect(!inBand(32, 400, 400, 0));
    try std.testing.expect(!inBand(32, 400, -1, 0));
    try std.testing.expect(!inBand(32, 400, 0, -1));
}
