//! Captionless main window: `[window] titlebar_style = "transparent"` with
//! any tabline but the titlebar one (which draws its own caption). The
//! native caption is gone and the editor reaches the window top. The window
//! buttons float over the top-right corner while the pointer is in the band
//! (caption_reveal.zig). Hovering the top edge of the editor for a while
//! reveals a bar that drags the window.
//! With `[tabline] style = "sidebar"` the sidebar also reaches the top; its
//! top band drags the window, and a sidebar toggle sits over the sidebar's
//! corner: top-left, or left of the window buttons for a right sidebar.
//! The toggle slides the sidebar closed and open.
const std = @import("std");
const app_mod = @import("../app.zig");
const App = app_mod.App;
const Config = app_mod.config_mod.Config;
const c = app_mod.c;
const TablineState = app_mod.TablineState;
const tabline_mod = @import("tabbar.zig");
const caption_reveal = @import("caption_reveal.zig");
const input = @import("../input.zig");

const SLIDE_MS: u64 = 400;
const SLIDE_TICK_MS: c.UINT = 16;
/// The toggle's number among the caption buttons; 0-2 are minimize, maximize
/// and close, as `TablineState.hovered_window_btn` numbers them.
const TOGGLE_BTN: u8 = 3;

/// The main window's chrome for its titlebar style and tabline placement.
pub fn layout(app: *const App) Config.TitlebarLayout {
    const tabline: Config.TablinePlacement = if (!app.ext_tabline_enabled) .other else switch (app.tabline_style) {
        .titlebar => .titlebar,
        .sidebar => .sidebar,
    };
    return .{ .style = app.config.window.titlebar_style, .tabline = tabline };
}

/// No native caption and no titlebar tabline drawing one; the editor runs
/// under the band.
pub fn captionless(app: *const App) bool {
    return layout(app).captionless();
}

/// The band is drawn over the editor's side with the title, the editor
/// starts below it, and the sidebar still reaches the window top.
pub fn titleBand(app: *const App) bool {
    return layout(app).titleBand();
}

/// The main window draws this module's band overlay instead of a caption.
pub fn drawsBand(app: *const App) bool {
    return layout(app).drawsBand();
}

/// Where the main window's editor starts: below titlebar tabs or the title
/// band, else at the client top.
pub fn editorTopPx(app: *const App) c_int {
    return if (layout(app).editorBelowBand()) bandPx(app) else 0;
}

/// Whether the band's buttons follow the pointer. Off while an open right
/// sidebar sits under them: it pins them shown.
pub fn captionButtonsHoverGated(app: *const App) bool {
    const pinned = enabled(app) and app.sidebar_position_right and coveredPx(app) > 0;
    return captionless(app) and !pinned;
}

/// Whether the main window's buttons (and a captionless sidebar's toggle)
/// are drawn: under hover reveal only while the pointer is in the band.
pub fn captionButtonsShown(app: *const App) bool {
    return caption_reveal.buttonsShown(captionButtonsHoverGated(app), app.caption_buttons_revealed, app.tabline_state.pressed_window_btn != null);
}

pub const Columns = struct { lo: c_int, hi: c_int };

/// Columns of a `width` px band overlay where its bar colour is see-through:
/// all of a captionless band (the editor runs under it), only the sidebar's
/// part of the title band (the sidebar is drawn under it; over the editor the
/// band is chrome itself).
pub fn seeThroughColumnsPx(app: *const App, width: c_int) Columns {
    // coveredPx reports the full width without a sidebar; a title band
    // without one has nothing under it to show.
    const covered = if (enabled(app)) coveredPx(app) else 0;
    return seeThroughColumns(titleBand(app), app.sidebar_position_right, covered, width);
}

/// seeThroughColumnsPx's rule. `covered_px` is clamped to the band, so the
/// range always lies within [0, width].
fn seeThroughColumns(title_band: bool, sidebar_right: bool, covered_px: c_int, width: c_int) Columns {
    std.debug.assert(width >= 0);
    if (!title_band) return .{ .lo = 0, .hi = width };
    const covered = std.math.clamp(covered_px, 0, width);
    return if (sidebar_right) .{ .lo = width - covered, .hi = width } else .{ .lo = 0, .hi = covered };
}

test "seeThroughColumns: the whole band, or only the sidebar's side of a title band" {
    try std.testing.expectEqual(Columns{ .lo = 0, .hi = 800 }, seeThroughColumns(false, false, 200, 800));
    try std.testing.expectEqual(Columns{ .lo = 0, .hi = 200 }, seeThroughColumns(true, false, 200, 800));
    try std.testing.expectEqual(Columns{ .lo = 600, .hi = 800 }, seeThroughColumns(true, true, 200, 800));
    try std.testing.expectEqual(Columns{ .lo = 0, .hi = 0 }, seeThroughColumns(true, false, 0, 800));
    try std.testing.expectEqual(Columns{ .lo = 0, .hi = 800 }, seeThroughColumns(true, true, 900, 800));
}

/// A band with the sidebar: the toggle, the slide and the sidebar's top band.
pub fn enabled(app: *const App) bool {
    return drawsBand(app) and app.ext_tabline_enabled and app.tabline_style == .sidebar;
}

pub const SeparatorEdge = struct { fade_px: f32 = 0, hard: bool = false };

/// How window separators meet the band (`[window] titlebar_edge`), in the
/// root grid's own pixels: they fade in across the band, or, with a border,
/// are hidden where the band lies over the grid.
pub fn separatorEdge(app: *const App) SeparatorEdge {
    if (!drawsBand(app)) return .{};
    const band: f32 = @floatFromInt(bandPx(app));
    return switch (app.config.window.titlebar_edge) {
        .fade => .{ .fade_px = band },
        .none => .{},
        // A captionless window shows no band, so there is no edge to border:
        // its separators fade under the hidden caption instead. The title
        // band is chrome above the editor, which starts below it.
        .border => if (captionless(app)) .{ .fade_px = band } else .{ .hard = true },
    };
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
/// `with_toggle`: the sidebar toggle has a slot (a captionless sidebar).
pub fn buttonAt(app: *const App, with_toggle: bool, client_w: c_int, x: c_int, y: c_int) ?u8 {
    if (y < 0 or y >= bandPx(app)) return null;
    const w = buttonWidthPx(app);
    if (with_toggle and !app.sidebar_position_right and x >= 0 and x < w) return TOGGLE_BTN;
    const from_right = client_w - x;
    if (from_right <= 0) return null;
    // Slots count from the right: close, maximize, minimize, then the toggle
    // for a right sidebar.
    const slot = @divTrunc(from_right - 1, w);
    if (slot < 3) return 2 - @as(u8, @intCast(slot));
    return if (with_toggle and app.sidebar_position_right and slot == 3) TOGGLE_BTN else null;
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
    if (buttonAt(app, enabled(app), client.right, x, y) != null) return c.HTCLIENT;
    // The title band is chrome across the window: all of it moves the window.
    if (titleBand(app)) return c.HTCAPTION;
    if (enabled(app) and coveredPx(app) > 0 and tabline_mod.pointInSidebar(app, hwnd, x)) return c.HTCAPTION;
    if (app.drag_bar.revealed) return c.HTCAPTION;
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

    const with_toggle = enabled(app);
    if (app.drag_bar.revealed) {
        const bar_brush = c.CreateSolidBrush(pal.wbtn_hover_bg);
        defer _ = c.DeleteObject(bar_brush);
        // Over the editor only: the sidebar's own top already drags the window.
        const inset = gridInsetsPx(app);
        const toggle_right = with_toggle and app.sidebar_position_right;
        const toggle_left = with_toggle and !app.sidebar_position_right;
        const bar_right = if (toggle_right) @min(toggleLeftPx(app, width), width - inset.right) else group_left;
        var bar = c.RECT{ .left = if (toggle_left) @max(btn_w, inset.left) else inset.left, .top = 0, .right = bar_right, .bottom = band };
        _ = c.FillRect(hdc, &bar, bar_brush);
    }

    if (separatorEdge(app).hard) drawHairline(app, hdc, width, pal);
    if (titleBand(app)) drawTitle(app, hdc, width);
    if (with_toggle and captionButtonsShown(app)) drawToggle(app, hdc, width, pal);
    tabline_mod.drawWindowButtons(app, hdc, width, pal);
}

/// `titlebar_edge = "border"`: a one-pixel line in WinSeparator's colour
/// along the band's bottom, over the editor's columns.
fn drawHairline(app: *App, hdc: c.HDC, width: c_int, pal: tabline_mod.TitlebarPalette) void {
    const inset = gridInsetsPx(app);
    const fg = app.cached_separator_fg;
    var color: c.COLORREF = if (fg == 0xFFFFFFFF) pal.wbtn_icon else c.RGB(@as(u8, @intCast((fg >> 16) & 0xFF)), @as(u8, @intCast((fg >> 8) & 0xFF)), @as(u8, @intCast(fg & 0xFF)));
    // The bar colour is the overlay's transparency key; the line must not vanish into it.
    if (color == pal.bar_bg) color ^= 1;
    const brush = c.CreateSolidBrush(color);
    defer _ = c.DeleteObject(brush);
    const band = bandPx(app);
    var r = c.RECT{ .left = inset.left, .top = band - 1, .right = width - inset.right, .bottom = band };
    _ = c.FillRect(hdc, &r, brush);
}

/// The title band's window title, centered over the editor's side in the
/// editor's default fg. Reads `pending_title`, which the caller's app.mu
/// hold keeps stable.
fn drawTitle(app: *App, hdc: c.HDC, width: c_int) void {
    const len = app.pending_title_len;
    if (len == 0) return;
    const inset = gridInsetsPx(app);
    // Clear of the window buttons on the right and the toggle on the left.
    const btn_w = buttonWidthPx(app);
    var r = c.RECT{ .left = inset.left + btn_w, .top = 0, .right = width - inset.right - btn_w * 4, .bottom = bandPx(app) };
    if (r.right <= r.left) return;
    const font = tabline_mod.createTabFont(app, -12);
    defer _ = c.DeleteObject(font);
    const old_font = c.SelectObject(hdc, font);
    defer _ = c.SelectObject(hdc, old_font);
    _ = c.SetBkMode(hdc, c.TRANSPARENT);
    const fg = app.colorscheme_fg;
    _ = c.SetTextColor(hdc, if (fg == 0xFFFFFFFF) tabline_mod.currentTitlebarPalette(app).wbtn_icon else c.RGB(@as(u8, @intCast((fg >> 16) & 0xFF)), @as(u8, @intCast((fg >> 8) & 0xFF)), @as(u8, @intCast(fg & 0xFF))));
    _ = c.DrawTextW(hdc, &app.pending_title, @intCast(len), &r, c.DT_CENTER | c.DT_VCENTER | c.DT_SINGLELINE | c.DT_END_ELLIPSIS | c.DT_NOPREFIX);
}

/// The sidebar toggle: a window outline with the sidebar's divider.
fn drawToggle(app: *App, hdc: c.HDC, width: c_int, pal: tabline_mod.TitlebarPalette) void {
    const band = bandPx(app);
    const btn_w = buttonWidthPx(app);
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
}

/// The overlay over the editor, drawn into back_tex after the rows so the
/// rows under it never cover it.
pub fn drawOverlay(g: *app_mod.d3d11.Renderer) !void {
    g.setFullViewport();
    try g.drawTablineTexture();
}

pub fn repaint(hwnd: c.HWND, app: *App) void {
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
        const in_band = caption_reveal.pointerInBand(hwnd, bandPx(app));
        stepDragBar(hwnd, app, app.drag_bar.onTimer(in_band, dragBarAllowed(app), c.GetTickCount64()));
        return true;
    }
    return false;
}

/// An editor selection or scrollbar-knob drag on the main window owns the
/// pointer: the chrome neither consumes its moves nor reveals under it.
pub fn editorDrag(app: *const App) bool {
    return app.surf.scrollbar.dragging or editorPressHeld(app);
}

/// A press that reached an editor grid is held. The claim is app-wide, so it
/// covers the external windows' grids too.
pub fn editorPressHeld(app: *const App) bool {
    return app.press_claim.owner != 0 and app.mouse_press_grid_id != 0;
}

/// The one gate for both DragBar inputs: a pointer move and the timer fire.
fn dragBarAllowed(app: *const App) bool {
    return captionless(app) and !sliding(app) and !editorDrag(app);
}

fn stepDragBar(hwnd: c.HWND, app: *App, step: caption_reveal.DragBar.Step) void {
    if (caption_reveal.applyDragBar(hwnd, &app.drag_bar, step)) repaint(hwnd, app);
}

fn concealDragBar(hwnd: c.HWND, app: *App) void {
    stepDragBar(hwnd, app, app.drag_bar.onPointer(false, false, false, 0));
}

fn setHover(hwnd: c.HWND, app: *App, btn: ?u8) void {
    if (app.tabline_state.hovered_window_btn == btn) return;
    app.tabline_state.hovered_window_btn = btn;
    repaint(hwnd, app);
}

/// WM_MOUSEMOVE. True when the pointer is on a caption button (the move is
/// the button's, not the editor's).
pub fn onMouseMove(hwnd: c.HWND, app: *App, x: c_int, y: c_int) bool {
    if (!drawsBand(app)) return false;
    var client: c.RECT = undefined;
    _ = c.GetClientRect(hwnd, &client);
    const btn = buttonAt(app, enabled(app), client.right, x, y);
    if (app.tabline_state.pressed_window_btn) |pressed| {
        if (btn != pressed) {
            app.tabline_state.pressed_window_btn = null;
            _ = c.ReleaseCapture();
        }
    }
    setHover(hwnd, app, btn);
    if (btn != null) input.trackMouseLeave(hwnd);

    // Same coordinates as `btn`: a captured move outside the client is off the band.
    const in_band = caption_reveal.inBand(bandPx(app), client.right, x, y);
    const step = app.drag_bar.onPointer(in_band, btn != null, dragBarAllowed(app), c.GetTickCount64());
    if (step.timer == .set) input.trackMouseLeave(hwnd);
    stepDragBar(hwnd, app, step);
    return btn != null;
}

/// WM_NCMOUSEMOVE: a revealed bar is caption, so leaving the window from it
/// sends WM_NCMOUSELEAVE only when asked for.
pub fn onNcMouseMove(hwnd: c.HWND, app: *App) void {
    if (!captionless(app) or !app.drag_bar.revealed) return;
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
    if (!drawsBand(app)) return;
    setHover(hwnd, app, null);
    if (!caption_reveal.pointerInBand(hwnd, bandPx(app))) concealDragBar(hwnd, app);
}

/// A press on a caption button. True when it was one.
pub fn onMouseDown(hwnd: c.HWND, app: *App, msg: c.UINT, x: c_int, y: c_int) bool {
    if (!drawsBand(app)) return false;
    var client: c.RECT = undefined;
    _ = c.GetClientRect(hwnd, &client);
    const btn = buttonAt(app, enabled(app), client.right, x, y) orelse return false;
    if (msg == c.WM_LBUTTONDOWN) {
        app.tabline_state.pressed_window_btn = btn;
        _ = c.SetCapture(hwnd);
    }
    return true;
}

/// The release of a pressed caption button. True when one was pressed.
pub fn onMouseUp(hwnd: c.HWND, app: *App, x: c_int, y: c_int) bool {
    if (!drawsBand(app)) return false;
    const pressed = app.tabline_state.pressed_window_btn orelse return false;
    app.tabline_state.pressed_window_btn = null;
    _ = c.ReleaseCapture();
    var client: c.RECT = undefined;
    _ = c.GetClientRect(hwnd, &client);
    if (buttonAt(app, enabled(app), client.right, x, y) != pressed) return true;
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
    try std.testing.expectEqual(@as(?u8, 2), buttonAt(&app, true, 400, 399, 5));
    try std.testing.expectEqual(@as(?u8, 2), buttonAt(&app, true, 400, 354, 5));
    try std.testing.expectEqual(@as(?u8, 1), buttonAt(&app, true, 400, 353, 5));
    try std.testing.expectEqual(@as(?u8, 0), buttonAt(&app, true, 400, 262, 5));
    try std.testing.expectEqual(@as(?u8, null), buttonAt(&app, true, 400, 261, 5));
    try std.testing.expectEqual(@as(?u8, null), buttonAt(&app, true, 400, 46, 5));
    try std.testing.expectEqual(@as(?u8, TOGGLE_BTN), buttonAt(&app, true, 400, 45, 5));
    try std.testing.expectEqual(@as(?u8, TOGGLE_BTN), buttonAt(&app, true, 400, 0, 5));
    try std.testing.expectEqual(@as(?u8, null), buttonAt(&app, true, 400, 399, 40));
}

test "buttonAt: a right sidebar puts the toggle left of the window buttons" {
    var app: App = undefined;
    app.dpi_scale = 1.0;
    app.sidebar_position_right = true;
    try std.testing.expectEqual(@as(?u8, 0), buttonAt(&app, true, 400, 262, 5));
    try std.testing.expectEqual(@as(?u8, TOGGLE_BTN), buttonAt(&app, true, 400, 261, 5));
    try std.testing.expectEqual(@as(?u8, TOGGLE_BTN), buttonAt(&app, true, 400, 216, 5));
    try std.testing.expectEqual(@as(?u8, null), buttonAt(&app, true, 400, 215, 5));
    try std.testing.expectEqual(@as(?u8, null), buttonAt(&app, true, 400, 0, 5));
}
