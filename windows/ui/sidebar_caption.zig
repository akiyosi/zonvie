//! Captionless sidebar window: `[window] titlebar_style = "transparent"` with
//! `[tabline] style = "sidebar"`. The native caption is gone and the sidebar
//! reaches the window top; its top band drags the window. The window buttons
//! float over the top-right corner and a sidebar toggle over the sidebar's
//! corner: top-left, or left of the window buttons for a right sidebar.
//! The toggle slides the sidebar closed and open. Hovering the top edge of
//! the editor for a while reveals a bar that drags the window.
const std = @import("std");
const app_mod = @import("../app.zig");
const App = app_mod.App;
const c = app_mod.c;
const TablineState = app_mod.TablineState;
const tabline_mod = @import("tabbar.zig");
const input = @import("../input.zig");

const SLIDE_MS: u64 = 400;
const SLIDE_TICK_MS: c.UINT = 16;
const DRAG_BAR_REVEAL_MS: c.UINT = 2000;
/// The toggle's number among the caption buttons; 0-2 are minimize, maximize
/// and close, as `TablineState.hovered_window_btn` numbers them.
const TOGGLE_BTN: u8 = 3;

pub fn enabled(app: *const App) bool {
    return app.ext_tabline_enabled and app.tabline_style == .sidebar and
        app.config.window.titlebar_style == .transparent;
}

/// Height of the band the caption used to occupy.
pub fn bandPx(app: *const App) c_int {
    return app.scalePx(TablineState.TAB_BAR_HEIGHT);
}

fn fullPx(app: *const App) c_int {
    return app.scalePx(@as(c_int, @intCast(app.sidebar_width_px)));
}

fn sliding(app: *const App) bool {
    return app.sidebar_sliding;
}

/// Width of the sidebar on screen. Mid-slide it follows an ease-in-out curve,
/// the same in both directions. Reads the clock sampled at the last slide
/// tick, never the live one, so every caller in one paint agrees.
pub fn coveredPx(app: *const App) c_int {
    const full = fullPx(app);
    if (!enabled(app)) return full;
    if (!sliding(app)) return if (app.sidebar_collapsed) 0 else full;
    const elapsed = app.sidebar_slide_now_ms -| app.sidebar_slide_start_ms;
    const t: f32 = @min(1.0, @as(f32, @floatFromInt(elapsed)) / @as(f32, @floatFromInt(SLIDE_MS)));
    const eased = t * t * (3.0 - 2.0 * t);
    const open = if (app.sidebar_collapsed) 1.0 - eased else eased;
    return @intFromFloat(@round(@as(f32, @floatFromInt(full)) * open));
}

pub const Insets = struct { left: c_int = 0, right: c_int = 0 };

/// Pixels the grid leaves to the sidebar at each side. Mid-slide the grid
/// keeps the open width and only moves, so Neovim is resized once per toggle
/// (before opening, after closing).
pub fn gridInsetsPx(app: *const App) Insets {
    if (!(app.ext_tabline_enabled and app.tabline_style == .sidebar)) return .{};
    const full = fullPx(app);
    const covered = coveredPx(app);
    if (sliding(app)) {
        return if (app.sidebar_position_right) .{ .right = full } else .{ .left = covered, .right = full - covered };
    }
    return if (app.sidebar_position_right) .{ .right = covered } else .{ .left = covered };
}

fn buttonWidthPx(app: *const App) c_int {
    return app.scalePx(TablineState.WINDOW_BTN_WIDTH);
}

/// The caption button under client (x, y), or null.
pub fn buttonAt(app: *const App, client_w: c_int, x: c_int, y: c_int) ?u8 {
    if (y < 0 or y >= bandPx(app)) return null;
    const w = buttonWidthPx(app);
    if (!app.sidebar_position_right and x >= 0 and x < w) return TOGGLE_BTN;
    const from_right = client_w - x;
    if (from_right <= 0) return null;
    // Slots count from the right: close, maximize, minimize, then the toggle
    // for a right sidebar.
    const slot = @divTrunc(from_right - 1, w);
    if (slot < 3) return 2 - @as(u8, @intCast(slot));
    return if (app.sidebar_position_right and slot == 3) TOGGLE_BTN else null;
}

/// Left edge of the toggle's slot.
fn toggleLeftPx(app: *const App, width: c_int) c_int {
    return if (app.sidebar_position_right) width - buttonWidthPx(app) * 4 else 0;
}

/// What the band at client (x, y) is for WM_NCHITTEST: the buttons take the
/// click, the sidebar's top and a revealed drag bar move the window, and the
/// rest is the editor's.
pub fn bandHitTest(app: *App, hwnd: c.HWND, x: c_int, y: c_int) c.LRESULT {
    var client: c.RECT = undefined;
    _ = c.GetClientRect(hwnd, &client);
    if (buttonAt(app, client.right, x, y) != null) return c.HTCLIENT;
    if (coveredPx(app) > 0 and tabline_mod.pointInSidebar(app, hwnd, x)) return c.HTCAPTION;
    if (app.drag_bar_revealed) return c.HTCAPTION;
    return c.HTCLIENT;
}

/// The overlay strip: transparent except for the buttons and, when revealed,
/// the drag bar. Pixels left in the palette's bar colour are made transparent
/// on upload (renderOffscreenToD3D).
pub fn drawOverlayContent(app: *App, hdc: c.HDC, width: c_int) void {
    const pal = tabline_mod.currentTitlebarPalette(app);
    const band = bandPx(app);
    const btn_w = buttonWidthPx(app);
    const group_left = width - btn_w * 3;

    const bg_brush = c.CreateSolidBrush(pal.bar_bg);
    defer _ = c.DeleteObject(bg_brush);
    var all = c.RECT{ .left = 0, .top = 0, .right = width, .bottom = band };
    _ = c.FillRect(hdc, &all, bg_brush);

    if (app.drag_bar_revealed) {
        const bar_brush = c.CreateSolidBrush(pal.wbtn_hover_bg);
        defer _ = c.DeleteObject(bar_brush);
        // Over the editor only: the sidebar's own top already drags the window.
        const inset = gridInsetsPx(app);
        const bar_right = if (app.sidebar_position_right) @min(toggleLeftPx(app, width), width - inset.right) else group_left;
        var bar = c.RECT{ .left = @max(btn_w, inset.left), .top = 0, .right = bar_right, .bottom = band };
        _ = c.FillRect(hdc, &bar, bar_brush);
    }

    // The sidebar toggle: a window outline with the sidebar's divider.
    if (app.tabline_state.hovered_window_btn == TOGGLE_BTN) {
        const hover_brush = c.CreateSolidBrush(pal.wbtn_hover_bg);
        defer _ = c.DeleteObject(hover_brush);
        const tl = toggleLeftPx(app, width);
        var r = c.RECT{ .left = tl, .top = 0, .right = tl + btn_w, .bottom = band };
        _ = c.FillRect(hdc, &r, hover_brush);
    }
    const icon_w = app.scalePx(14);
    const icon_h = app.scalePx(11);
    const ix = toggleLeftPx(app, width) + @divTrunc(btn_w - icon_w, 2);
    const iy = @divTrunc(band - icon_h, 2);
    const pen = c.CreatePen(c.PS_SOLID, @max(1, app.scalePx(1)), pal.wbtn_icon);
    defer _ = c.DeleteObject(pen);
    const old_pen = c.SelectObject(hdc, pen);
    defer _ = c.SelectObject(hdc, old_pen);
    const old_brush = c.SelectObject(hdc, c.GetStockObject(c.NULL_BRUSH));
    defer _ = c.SelectObject(hdc, old_brush);
    _ = c.Rectangle(hdc, ix, iy, ix + icon_w, iy + icon_h);
    const div_x = if (app.sidebar_position_right) ix + icon_w - @divTrunc(icon_w, 3) else ix + @divTrunc(icon_w, 3);
    _ = c.MoveToEx(hdc, div_x, iy, null);
    _ = c.LineTo(hdc, div_x, iy + icon_h);

    tabline_mod.drawWindowButtons(app, hdc, width, pal);
}

/// The overlay over the editor, drawn into back_tex after the rows so the
/// rows under it never cover it.
pub fn drawOverlay(g: *app_mod.d3d11.Renderer) !void {
    g.setFullViewport();
    try g.drawTablineTexture();
}

fn repaint(hwnd: c.HWND, app: *App) void {
    // The overlay is drawn over retained rows with transparent pixels, which
    // cannot erase a hover or bar that went away: redraw everything under it.
    app_mod.requestMainFullPaint(app);
    _ = c.InvalidateRect(hwnd, null, c.FALSE);
}

pub fn toggle(hwnd: c.HWND, app: *App) void {
    if (!enabled(app) or sliding(app)) return;
    app.sidebar_collapsed = !app.sidebar_collapsed;
    const now = c.GetTickCount64();
    app.sidebar_sliding = true;
    app.sidebar_slide_start_ms = now;
    app.sidebar_slide_now_ms = now;
    concealDragBar(hwnd, app);
    app_mod.updateLayoutToCore(hwnd, app);
    _ = c.SetTimer(hwnd, app_mod.TIMER_SIDEBAR_SLIDE, SLIDE_TICK_MS, null);
    repaint(hwnd, app);
}

/// True when `id` was one of this module's timers.
pub fn onTimer(hwnd: c.HWND, app: *App, id: usize) bool {
    if (id == app_mod.TIMER_SIDEBAR_SLIDE) {
        app.sidebar_slide_now_ms = c.GetTickCount64();
        if (app.sidebar_slide_now_ms -| app.sidebar_slide_start_ms >= SLIDE_MS) {
            app.sidebar_sliding = false;
            _ = c.KillTimer(hwnd, app_mod.TIMER_SIDEBAR_SLIDE);
            app_mod.updateLayoutToCore(hwnd, app);
        }
        repaint(hwnd, app);
        return true;
    }
    if (id == app_mod.TIMER_DRAG_BAR_REVEAL) {
        _ = c.KillTimer(hwnd, app_mod.TIMER_DRAG_BAR_REVEAL);
        app.drag_bar_timer_armed = false;
        const p = input.cursorClientPos(hwnd);
        if (dragBarAllowed(app) and p.y >= 0 and p.y < bandPx(app)) {
            app.drag_bar_revealed = true;
            repaint(hwnd, app);
        }
        return true;
    }
    return false;
}

fn dragBarAllowed(app: *const App) bool {
    return enabled(app) and !sliding(app);
}

fn concealDragBar(hwnd: c.HWND, app: *App) void {
    if (app.drag_bar_timer_armed) {
        _ = c.KillTimer(hwnd, app_mod.TIMER_DRAG_BAR_REVEAL);
        app.drag_bar_timer_armed = false;
    }
    if (app.drag_bar_revealed) {
        app.drag_bar_revealed = false;
        repaint(hwnd, app);
    }
}

fn setHover(hwnd: c.HWND, app: *App, btn: ?u8) void {
    if (app.tabline_state.hovered_window_btn == btn) return;
    app.tabline_state.hovered_window_btn = btn;
    repaint(hwnd, app);
}

/// WM_MOUSEMOVE. True when the pointer is on a caption button (the move is
/// the button's, not the editor's).
pub fn onMouseMove(hwnd: c.HWND, app: *App, x: c_int, y: c_int) bool {
    if (!enabled(app)) return false;
    var client: c.RECT = undefined;
    _ = c.GetClientRect(hwnd, &client);
    const btn = buttonAt(app, client.right, x, y);
    if (app.tabline_state.pressed_window_btn) |pressed| {
        if (btn != pressed) {
            app.tabline_state.pressed_window_btn = null;
            _ = c.ReleaseCapture();
        }
    }
    setHover(hwnd, app, btn);
    if (btn != null) input.trackMouseLeave(hwnd);

    if (y >= 0 and y < bandPx(app) and btn == null and dragBarAllowed(app)) {
        if (!app.drag_bar_revealed and !app.drag_bar_timer_armed) {
            _ = c.SetTimer(hwnd, app_mod.TIMER_DRAG_BAR_REVEAL, DRAG_BAR_REVEAL_MS, null);
            app.drag_bar_timer_armed = true;
            input.trackMouseLeave(hwnd);
        }
    } else if (btn == null) {
        concealDragBar(hwnd, app);
    }
    return btn != null;
}

/// WM_NCMOUSEMOVE: a revealed bar is caption, so leaving the window from it
/// sends WM_NCMOUSELEAVE only when asked for.
pub fn onNcMouseMove(hwnd: c.HWND, app: *App) void {
    if (!enabled(app) or !app.drag_bar_revealed) return;
    var tme: c.TRACKMOUSEEVENT = .{
        .cbSize = @sizeOf(c.TRACKMOUSEEVENT),
        .dwFlags = c.TME_LEAVE | c.TME_NONCLIENT,
        .hwndTrack = hwnd,
        .dwHoverTime = 0,
    };
    _ = c.TrackMouseEvent(&tme);
}

/// WM_MOUSELEAVE / WM_NCMOUSELEAVE. Moving between the client band and the
/// revealed (caption) bar also "leaves", so the bar stays while the pointer
/// is still in the band.
pub fn onLeave(hwnd: c.HWND, app: *App) void {
    if (!enabled(app)) return;
    setHover(hwnd, app, null);
    var pt: c.POINT = undefined;
    _ = c.GetCursorPos(&pt);
    var wr: c.RECT = undefined;
    _ = c.GetWindowRect(hwnd, &wr);
    const inside = pt.x >= wr.left and pt.x < wr.right and pt.y >= wr.top and pt.y < wr.bottom;
    _ = c.ScreenToClient(hwnd, &pt);
    if (!inside or pt.y < 0 or pt.y >= bandPx(app)) concealDragBar(hwnd, app);
}

/// A press on a caption button. True when it was one.
pub fn onMouseDown(hwnd: c.HWND, app: *App, msg: c.UINT, x: c_int, y: c_int) bool {
    if (!enabled(app)) return false;
    var client: c.RECT = undefined;
    _ = c.GetClientRect(hwnd, &client);
    const btn = buttonAt(app, client.right, x, y) orelse return false;
    if (msg == c.WM_LBUTTONDOWN) {
        app.tabline_state.pressed_window_btn = btn;
        _ = c.SetCapture(hwnd);
    }
    return true;
}

/// The release of a pressed caption button. True when one was pressed.
pub fn onMouseUp(hwnd: c.HWND, app: *App, x: c_int, y: c_int) bool {
    if (!enabled(app)) return false;
    const pressed = app.tabline_state.pressed_window_btn orelse return false;
    app.tabline_state.pressed_window_btn = null;
    _ = c.ReleaseCapture();
    var client: c.RECT = undefined;
    _ = c.GetClientRect(hwnd, &client);
    if (buttonAt(app, client.right, x, y) != pressed) return true;
    switch (pressed) {
        0 => _ = c.ShowWindow(hwnd, c.SW_MINIMIZE),
        1 => _ = c.ShowWindow(hwnd, if (c.IsZoomed(hwnd) != 0) c.SW_RESTORE else c.SW_MAXIMIZE),
        2 => _ = c.PostMessageW(hwnd, c.WM_CLOSE, 0, 0),
        else => toggle(hwnd, app),
    }
    return true;
}

test "buttonAt: window buttons from the right edge, toggle at the left" {
    var app: App = undefined;
    app.dpi_scale = 1.0;
    app.sidebar_position_right = false;
    try std.testing.expectEqual(@as(?u8, 2), buttonAt(&app, 400, 399, 5));
    try std.testing.expectEqual(@as(?u8, 2), buttonAt(&app, 400, 354, 5));
    try std.testing.expectEqual(@as(?u8, 1), buttonAt(&app, 400, 353, 5));
    try std.testing.expectEqual(@as(?u8, 0), buttonAt(&app, 400, 262, 5));
    try std.testing.expectEqual(@as(?u8, null), buttonAt(&app, 400, 261, 5));
    try std.testing.expectEqual(@as(?u8, null), buttonAt(&app, 400, 46, 5));
    try std.testing.expectEqual(@as(?u8, TOGGLE_BTN), buttonAt(&app, 400, 45, 5));
    try std.testing.expectEqual(@as(?u8, TOGGLE_BTN), buttonAt(&app, 400, 0, 5));
    try std.testing.expectEqual(@as(?u8, null), buttonAt(&app, 400, 399, 40));
}

test "buttonAt: a right sidebar puts the toggle left of the window buttons" {
    var app: App = undefined;
    app.dpi_scale = 1.0;
    app.sidebar_position_right = true;
    try std.testing.expectEqual(@as(?u8, 0), buttonAt(&app, 400, 262, 5));
    try std.testing.expectEqual(@as(?u8, TOGGLE_BTN), buttonAt(&app, 400, 261, 5));
    try std.testing.expectEqual(@as(?u8, TOGGLE_BTN), buttonAt(&app, 400, 216, 5));
    try std.testing.expectEqual(@as(?u8, null), buttonAt(&app, 400, 215, 5));
    try std.testing.expectEqual(@as(?u8, null), buttonAt(&app, 400, 0, 5));
}
