const std = @import("std");
const core = @import("zonvie_core");
const app_mod = @import("../app.zig");
const App = app_mod.App;
const c = app_mod.c;
const applog = app_mod.applog;
const input = @import("../input.zig");
const callbacks = @import("../callbacks.zig");

pub const ViewportRead = enum { fresh, cached, none };

/// Non-blocking viewport query with cache fallback (mirrors macOS's
/// getViewportNonBlocking / ZonvieCore.swift's cachedViewports). Every
/// scrollbar call site here used to block on the core's grid lock every
/// WM_PAINT/flush/mouse-move; this lets the UI thread never wait on the
/// core thread's handleRedraw. Fills out_vp and returns .fresh on tryLock
/// success, .cached when the lock was busy and a previously cached value
/// (at most one flush stale) was served, .none when there is no viewport
/// info available at all (grid genuinely has none, and no prior cached
/// value exists for it). Callers that were triggered by a one-shot message
/// must treat .cached as "the triggering change may not be visible yet"
/// and schedule a retry rather than dropping the update.
fn getViewportNonBlocking(app: *App, grid_id: i64, out_vp: *app_mod.ViewportInfo) ViewportRead {
    const corep = app.corep orelse return .none;
    const result = app_mod.zonvie_core_try_get_viewport(corep, grid_id, out_vp);
    if (result == 1) {
        app.viewport_cache.put(app.alloc, grid_id, out_vp.*) catch {};
        return .fresh;
    }
    if (result == 0) {
        // Grid genuinely has no viewport info -- drop any stale cache entry.
        _ = app.viewport_cache.remove(grid_id);
        return .none;
    }
    // result == -1: core's grid lock was busy -- serve the cached value.
    if (app.viewport_cache.get(grid_id)) |cached| {
        out_vp.* = cached;
        return .cached;
    }
    return .none;
}

fn trackDamageRect(client_width: i32, client_height: i32, dpi_scale: f32, top_offset_px: f32) ?c.RECT {
    if (client_width <= 0 or client_height <= 0) return null;

    const cw: f32 = @floatFromInt(client_width);
    const ch: f32 = @floatFromInt(client_height);
    const margin = app_mod.scrollbarMargin(dpi_scale);
    const width = app_mod.scrollbarWidth(dpi_scale);

    var left: i32 = @intFromFloat(@floor(cw - width - margin));
    var right: i32 = @intFromFloat(@ceil(cw - margin));
    var top: i32 = @intFromFloat(@floor(margin + top_offset_px));
    var bottom: i32 = @intFromFloat(@ceil(ch - margin));
    left = @max(0, left);
    right = @min(client_width, right);
    top = @max(0, top);
    bottom = @min(client_height, bottom);
    if (right <= left or bottom <= top) return null;
    return .{ .left = left, .top = top, .right = right, .bottom = bottom };
}

/// Pixel damage covered by the main scrollbar track. This deliberately does
/// not query the core viewport: it is also needed once fade-out reaches zero,
/// when only the previously saved overlay must be restored.
pub fn getScrollbarTrackRect(app: *App, client_width: i32, client_height: i32) ?c.RECT {
    const tabbar_offset: f32 = if (app.ext_tabline_enabled and
        app.tabline_style == .titlebar and
        app.content_hwnd == null)
        @floatFromInt(app.scalePx(app_mod.TablineState.TAB_BAR_HEIGHT))
    else
        0;
    return trackDamageRect(client_width, client_height, app.dpi_scale, tabbar_offset);
}

pub fn getScrollbarTrackRectForExternal(client_width: i32, client_height: i32, dpi_scale: f32) ?c.RECT {
    return trackDamageRect(client_width, client_height, dpi_scale, 0);
}

fn invalidateScrollbarTrack(hwnd: c.HWND, app: *App) void {
    var client: c.RECT = undefined;
    _ = c.GetClientRect(hwnd, &client);
    if (getScrollbarTrackRect(app, client.right - client.left, client.bottom - client.top)) |rect| {
        _ = c.InvalidateRect(hwnd, &rect, c.FALSE);
    } else {
        _ = c.InvalidateRect(hwnd, null, c.FALSE);
    }
}

fn invalidateScrollbarTrackForExternal(hwnd: c.HWND, dpi_scale: f32) void {
    var client: c.RECT = undefined;
    _ = c.GetClientRect(hwnd, &client);
    if (getScrollbarTrackRectForExternal(client.right - client.left, client.bottom - client.top, dpi_scale)) |rect| {
        _ = c.InvalidateRect(hwnd, &rect, c.FALSE);
    } else {
        _ = c.InvalidateRect(hwnd, null, c.FALSE);
    }
}

/// Scrollbar track and knob for one grid. The main window and the external
/// windows differ only in the three parameters: which grid to read, how much
/// vertical space the tabline takes above the track, and whose DPI scale
/// applies (external windows may sit on a different monitor).
fn scrollbarGeometryFor(
    app: *App,
    grid_id: i64,
    client_width: i32,
    client_height: i32,
    dpi: f32,
    top_offset_px: f32,
) app_mod.ScrollbarGeometry {
    var vp: app_mod.ViewportInfo = undefined;
    if (getViewportNonBlocking(app, grid_id, &vp) == .none) return .{
        .track_left = 0,
        .track_top = 0,
        .track_right = 0,
        .track_bottom = 0,
        .knob_top = 0,
        .knob_bottom = 0,
        .is_scrollable = false,
    };

    // The rule is the core's (`zonvie_core_scrollbar_metrics`). It was written
    // out here and again in the macOS frontend, and the two answers differed at
    // three corners -- and the second site in THIS file disagreed with the one
    // above it, lacking the zero-row guard.
    var metrics: app_mod.zonvie_scrollbar_metrics = undefined;
    app_mod.zonvie_core_scrollbar_metrics(vp.topline, vp.botline, vp.line_count, &metrics);
    const is_scrollable = metrics.is_scrollable != 0;

    const cw: f32 = @floatFromInt(client_width);
    const ch: f32 = @floatFromInt(client_height);

    const sb_width = app_mod.scrollbarWidth(dpi);
    const sb_margin = app_mod.scrollbarMargin(dpi);
    const sb_min_knob = app_mod.scrollbarMinKnobHeight(dpi);

    // Track position (right edge)
    const track_left = cw - sb_width - sb_margin;
    const track_right = cw - sb_margin;
    const track_top = sb_margin + top_offset_px;
    const track_bottom = ch - sb_margin;
    const track_height = track_bottom - track_top;

    if (!is_scrollable or track_height <= 0) {
        return .{
            .track_left = track_left,
            .track_top = track_top,
            .track_right = track_right,
            .track_bottom = track_bottom,
            .knob_top = track_top,
            .knob_bottom = track_bottom,
            .is_scrollable = false,
        };
    }

    // Fractions from the core; the minimum knob height is this frontend's own
    // chrome, and clamping the knob into the track is what the core's clamped
    // position buys -- a window scrolled past EOF used to place it below
    // `track_bottom`.
    var knob_height = track_height * @as(f32, @floatCast(metrics.knob_proportion));
    knob_height = @max(sb_min_knob, knob_height);
    const knob_travel = track_height - knob_height;
    const knob_top = track_top + knob_travel * @as(f32, @floatCast(metrics.scroll_position));

    return .{
        .track_left = track_left,
        .track_top = track_top,
        .track_right = track_right,
        .track_bottom = track_bottom,
        .knob_top = knob_top,
        .knob_bottom = knob_top + knob_height,
        .is_scrollable = true,
    };
}

/// The grid this surface's scrollbar should show. The core answers it — the
/// cursor's grid when this surface composites it, the surface's own root
/// otherwise — because both frontends were asking for -1 on the main window
/// and following a scroll in a window they do not draw.
///
/// Falls back to the surface's own root when the core's grid lock is held,
/// which is the same grid the knob is already showing.
fn scrollbarGrid(app: *App, surface_id: i64) i64 {
    const corep = app.corep orelse return surface_id;
    var grid: i64 = surface_id;
    if (app_mod.zonvie_core_try_scrollbar_grid(corep, surface_id, &grid) == 0) return surface_id;
    return grid;
}

pub fn getScrollbarGeometry(app: *App, client_width: i32, client_height: i32) app_mod.ScrollbarGeometry {
    // Only titlebar mode occupies vertical space above the terminal; sidebar
    // mode shifts content horizontally and must keep the track at the top.
    const tabbar_offset: f32 = if (app.ext_tabline_enabled and
        app.tabline_style == .titlebar and
        app.content_hwnd == null)
        @floatFromInt(app.scalePx(app_mod.TablineState.TAB_BAR_HEIGHT))
    else
        0;
    return scrollbarGeometryFor(app, scrollbarGrid(app, 1), client_width, client_height, app.dpi_scale, tabbar_offset);
}

pub fn getScrollbarGeometryForExternal(app: *App, grid_id: i64, client_width: i32, client_height: i32, dpi_scale: f32) app_mod.ScrollbarGeometry {
    // No tabline sits above an external window's content, so no top offset.
    // dpi_scale is this window's own monitor DPI, which may differ from
    // app.dpi_scale on a mixed-DPI multi-monitor setup.
    return scrollbarGeometryFor(app, scrollbarGrid(app, grid_id), client_width, client_height, dpi_scale, 0);
}

/// Emit the track and knob quads for a scrollbar whose geometry is already
/// resolved. The main window and the external windows produced these twelve
/// vertices identically apart from knob_inset_px.
///
/// That inset is a parameter, not a unified constant: external windows inset
/// the knob 1px inside its track and the main window does not, so the two
/// look different today. Passing it through keeps this refactor
/// bit-identical for both; making them agree changes what the main window
/// draws and is a decision for the user, not a side effect of sharing code.
fn scrollbarVerticesFrom(
    geom: app_mod.ScrollbarGeometry,
    cfg_opacity: f32,
    is_always_mode: bool,
    scrollbar_alpha: f32,
    client_width: i32,
    client_height: i32,
    knob_inset_px: f32,
    out_verts: *[12]app_mod.Vertex,
) usize {
    const cw: f32 = @floatFromInt(client_width);
    const ch: f32 = @floatFromInt(client_height);

    // Convert to NDC (-1..1)
    const to_ndc_x = struct {
        fn f(px: f32, w: f32) f32 {
            return (px / w) * 2.0 - 1.0;
        }
    }.f;
    const to_ndc_y = struct {
        fn f(py: f32, h: f32) f32 {
            return 1.0 - (py / h) * 2.0; // Y flipped
        }
    }.f;

    const alpha = scrollbar_alpha * cfg_opacity;
    const track_alpha: f32 = if (is_always_mode) 1.0 else alpha * 0.5;
    const track_color = [4]f32{ 0.2, 0.2, 0.2, track_alpha };
    const knob_color = [4]f32{ 0.7, 0.7, 0.7, alpha };

    const tl = to_ndc_x(geom.track_left, cw);
    const tr = to_ndc_x(geom.track_right, cw);
    const tt = to_ndc_y(geom.track_top, ch);
    const tb = to_ndc_y(geom.track_bottom, ch);

    out_verts[0] = .{ .position = .{ tl, tt }, .texCoord = .{ -1.0, 0 }, .color = track_color, .grid_id = 1, .deco_flags = 0, .deco_phase = 0 };
    out_verts[1] = .{ .position = .{ tr, tt }, .texCoord = .{ -1.0, 0 }, .color = track_color, .grid_id = 1, .deco_flags = 0, .deco_phase = 0 };
    out_verts[2] = .{ .position = .{ tl, tb }, .texCoord = .{ -1.0, 0 }, .color = track_color, .grid_id = 1, .deco_flags = 0, .deco_phase = 0 };
    out_verts[3] = .{ .position = .{ tr, tt }, .texCoord = .{ -1.0, 0 }, .color = track_color, .grid_id = 1, .deco_flags = 0, .deco_phase = 0 };
    out_verts[4] = .{ .position = .{ tr, tb }, .texCoord = .{ -1.0, 0 }, .color = track_color, .grid_id = 1, .deco_flags = 0, .deco_phase = 0 };
    out_verts[5] = .{ .position = .{ tl, tb }, .texCoord = .{ -1.0, 0 }, .color = track_color, .grid_id = 1, .deco_flags = 0, .deco_phase = 0 };

    const kl = to_ndc_x(geom.track_left + knob_inset_px, cw);
    const kr = to_ndc_x(geom.track_right - knob_inset_px, cw);
    const kt = to_ndc_y(geom.knob_top, ch);
    const kb = to_ndc_y(geom.knob_bottom, ch);

    out_verts[6] = .{ .position = .{ kl, kt }, .texCoord = .{ -1.0, 0 }, .color = knob_color, .grid_id = 1, .deco_flags = 0, .deco_phase = 0 };
    out_verts[7] = .{ .position = .{ kr, kt }, .texCoord = .{ -1.0, 0 }, .color = knob_color, .grid_id = 1, .deco_flags = 0, .deco_phase = 0 };
    out_verts[8] = .{ .position = .{ kl, kb }, .texCoord = .{ -1.0, 0 }, .color = knob_color, .grid_id = 1, .deco_flags = 0, .deco_phase = 0 };
    out_verts[9] = .{ .position = .{ kr, kt }, .texCoord = .{ -1.0, 0 }, .color = knob_color, .grid_id = 1, .deco_flags = 0, .deco_phase = 0 };
    out_verts[10] = .{ .position = .{ kr, kb }, .texCoord = .{ -1.0, 0 }, .color = knob_color, .grid_id = 1, .deco_flags = 0, .deco_phase = 0 };
    out_verts[11] = .{ .position = .{ kl, kb }, .texCoord = .{ -1.0, 0 }, .color = knob_color, .grid_id = 1, .deco_flags = 0, .deco_phase = 0 };

    return 12;
}

/// Generate scrollbar vertices for external window
pub fn generateScrollbarVerticesForExternal(
    app: *App,
    scrollbar_alpha: f32,
    grid_id: i64,
    client_width: i32,
    client_height: i32,
    out_verts: *[12]app_mod.Vertex,
    dpi_scale: f32,
) usize {
    if (!app.config.scrollbar.enabled) return 0;
    if (scrollbar_alpha <= 0.001) return 0;

    const geom = getScrollbarGeometryForExternal(app, grid_id, client_width, client_height, dpi_scale);
    if (!geom.is_scrollable and !app.config.scrollbar.isAlways()) return 0;

    return scrollbarVerticesFrom(
        geom,
        app.config.scrollbar.opacity,
        app.config.scrollbar.isAlways(),
        scrollbar_alpha,
        client_width,
        client_height,
        1, // external windows inset the knob inside its track
        out_verts,
    );
}

/// Which part of an already-resolved scrollbar a point falls on.
pub const ScrollbarHit = enum { none, knob, track_above, track_below };

/// Both hit tests were this, verbatim, around their own geometry call.
fn scrollbarHitFrom(geom: app_mod.ScrollbarGeometry, mouse_x: i32, mouse_y: i32) ScrollbarHit {
    if (!geom.is_scrollable) return .none;

    const mx: f32 = @floatFromInt(mouse_x);
    const my: f32 = @floatFromInt(mouse_y);

    if (mx < geom.track_left or mx > geom.track_right) return .none;
    if (my < geom.track_top or my > geom.track_bottom) return .none;

    if (my >= geom.knob_top and my <= geom.knob_bottom) return .knob;
    if (my < geom.knob_top) return .track_above;
    return .track_below;
}

/// Hit test scrollbar area for external window
pub fn scrollbarHitTestForExternal(
    app: *App,
    grid_id: i64,
    client_width: i32,
    client_height: i32,
    mouse_x: i32,
    mouse_y: i32,
    dpi_scale: f32,
) ScrollbarHit {
    if (!app.config.scrollbar.enabled) return .none;
    return scrollbarHitFrom(
        getScrollbarGeometryForExternal(app, grid_id, client_width, client_height, dpi_scale),
        mouse_x,
        mouse_y,
    );
}

/// Show scrollbar for external window
pub fn showScrollbarForExternal(hwnd: c.HWND, ext_win: *app_mod.ExternalWindow) void {
    ext_win.scrollbar_visible = true;
    ext_win.scrollbar_target_alpha = 1.0;

    // Start fade animation if not already at target
    if (ext_win.scrollbar_alpha < 1.0) {
        _ = c.SetTimer(hwnd, app_mod.TIMER_SCROLLBAR_FADE, app_mod.SCROLLBAR_FADE_INTERVAL, null);
    }
}

/// Hide scrollbar for external window
pub fn hideScrollbarForExternal(hwnd: c.HWND, app: *App, ext_win: *app_mod.ExternalWindow) void {
    if (app.config.scrollbar.isAlways()) return; // Never hide in always mode
    if (ext_win.scrollbar_dragging) return; // Don't hide while dragging

    ext_win.scrollbar_target_alpha = 0.0;

    // Start fade animation if not already at target
    if (ext_win.scrollbar_alpha > 0.0) {
        _ = c.SetTimer(hwnd, app_mod.TIMER_SCROLLBAR_FADE, app_mod.SCROLLBAR_FADE_INTERVAL, null);
    }
}

/// Page scroll for external window
pub fn scrollbarPageScrollForExternal(app: *App, grid_id: i64, direction: i8) void {
    const corep = app.corep orelse return;

    // The grid this window's knob shows, so a float it hosts pages too.
    app_mod.zonvie_core_page_scroll(corep, scrollbarGrid(app, grid_id), direction > 0);
}

/// Handle scrollbar mouse down for external window
pub fn scrollbarMouseDownForExternal(hwnd: c.HWND, app: *App, ext_win: *app_mod.ExternalWindow, grid_id: i64, mouse_x: i32, mouse_y: i32) bool {
    var client: c.RECT = undefined;
    _ = c.GetClientRect(hwnd, &client);

    const hit = scrollbarHitTestForExternal(app, grid_id, client.right, client.bottom, mouse_x, mouse_y, ext_win.dpi_scale);

    if (app.corep == null) return false;

    switch (hit) {
        .knob => {
            // Start dragging
            ext_win.scrollbar_dragging = true;
            ext_win.scrollbar_drag_start_y = mouse_y;

            var vp: app_mod.ViewportInfo = undefined;
            if (getViewportNonBlocking(app, grid_id, &vp) != .none) {
                ext_win.scrollbar_drag_start_topline = vp.topline;
            }

            _ = c.SetCapture(hwnd);
            return true;
        },
        .track_above => {
            // Page up - execute immediately and start repeat timer
            scrollbarPageScrollForExternal(app, grid_id, -1);
            ext_win.scrollbar_repeat_dir = -1;
            _ = c.SetCapture(hwnd);
            ext_win.scrollbar_repeat_timer = c.SetTimer(hwnd, app_mod.TIMER_SCROLLBAR_REPEAT, app_mod.SCROLLBAR_REPEAT_DELAY, null);
            showScrollbarForExternal(hwnd, ext_win);
            return true;
        },
        .track_below => {
            // Page down - execute immediately and start repeat timer
            scrollbarPageScrollForExternal(app, grid_id, 1);
            ext_win.scrollbar_repeat_dir = 1;
            _ = c.SetCapture(hwnd);
            ext_win.scrollbar_repeat_timer = c.SetTimer(hwnd, app_mod.TIMER_SCROLLBAR_REPEAT, app_mod.SCROLLBAR_REPEAT_DELAY, null);
            showScrollbarForExternal(hwnd, ext_win);
            return true;
        },
        .none => return false,
    }
}

/// Handle scrollbar mouse move (dragging) for external window
pub fn scrollbarMouseMoveForExternal(hwnd: c.HWND, app: *App, ext_win: *app_mod.ExternalWindow, grid_id: i64, mouse_y: i32) void {
    if (!ext_win.scrollbar_dragging) return;

    const corep = app.corep orelse return;

    var client: c.RECT = undefined;
    _ = c.GetClientRect(hwnd, &client);

    const geom = getScrollbarGeometryForExternal(app, grid_id, client.right, client.bottom, ext_win.dpi_scale);
    if (!geom.is_scrollable) return;

    var vp: app_mod.ViewportInfo = undefined;
    if (getViewportNonBlocking(app, grid_id, &vp) == .none) return;

    const visible_lines = vp.botline - vp.topline;
    if (visible_lines <= 0) return;

    // Calculate knob travel range
    const track_height = geom.track_bottom - geom.track_top;
    const visible_f: f32 = @floatFromInt(visible_lines);
    const total_f: f32 = @floatFromInt(@max(1, vp.line_count));
    const knob_proportion = @min(1.0, visible_f / total_f);
    var knob_height = track_height * knob_proportion;
    // Per-window DPI, matching the geometry above: on a mixed-DPI setup the
    // global scale gives the drag a different knob_travel from the drawn knob,
    // so the knob jumps away from the cursor whenever the clamp is active.
    knob_height = @max(app_mod.scrollbarMinKnobHeight(ext_win.dpi_scale), knob_height);
    const knob_travel = track_height - knob_height;
    if (knob_travel <= 0) return;

    // Calculate target topline from mouse position relative to track
    const mouse_in_track: f32 = @as(f32, @floatFromInt(mouse_y)) - geom.track_top - knob_height / 2.0;
    const scroll_ratio = @max(0.0, @min(1.0, mouse_in_track / knob_travel));

    // The core's rule, shared with the main window and both macOS surfaces.
    var drag: app_mod.zonvie_scrollbar_drag_target = undefined;
    app_mod.zonvie_core_scrollbar_drag_target(scroll_ratio, vp.topline, vp.botline, vp.line_count, &drag);
    const target_line: i64 = drag.line;
    const use_bottom = drag.use_bottom != 0;

    // Always store pending position
    ext_win.scrollbar_pending_line = target_line;
    ext_win.scrollbar_pending_use_bottom = use_bottom;

    // Throttle: only send RPC if enough time has passed
    const now: i64 = @intCast(c.GetTickCount64());
    if (now - ext_win.scrollbar_last_update < app_mod.SCROLLBAR_THROTTLE_MS) return;
    ext_win.scrollbar_last_update = now;

    // The grid this window's knob shows — dragging it ran against whatever
    // window held the cursor.
    app_mod.zonvie_core_scroll_to_line(corep, scrollbarGrid(app, grid_id), target_line, use_bottom);

    ext_win.scrollbar_pending_line = -1;
}

/// Handle scrollbar mouse up for external window
pub fn scrollbarMouseUpForExternal(hwnd: c.HWND, app: *App, ext_win: *app_mod.ExternalWindow, grid_id: i64) void {
    if (ext_win.scrollbar_dragging) {
        ext_win.scrollbar_dragging = false;
        _ = c.ReleaseCapture();

        // Flush any pending scroll on mouse up
        if (ext_win.scrollbar_pending_line >= 0) {
            if (app.corep) |corep| {
                app_mod.zonvie_core_scroll_to_line(corep, scrollbarGrid(app, grid_id), ext_win.scrollbar_pending_line, ext_win.scrollbar_pending_use_bottom);
            }
            ext_win.scrollbar_pending_line = -1;
        }
    }

    if (ext_win.scrollbar_repeat_timer != 0) {
        _ = c.KillTimer(hwnd, app_mod.TIMER_SCROLLBAR_REPEAT);
        ext_win.scrollbar_repeat_timer = 0;
        ext_win.scrollbar_repeat_dir = 0;
        _ = c.ReleaseCapture();
    }
}

/// Update scrollbar fade animation for external window
pub fn updateScrollbarFadeForExternal(hwnd: c.HWND, app: *App, ext_win: *app_mod.ExternalWindow) void {
    const delta: f32 = 0.1; // Fade step
    var changed = false;

    if (ext_win.scrollbar_alpha < ext_win.scrollbar_target_alpha) {
        ext_win.scrollbar_alpha = @min(ext_win.scrollbar_target_alpha, ext_win.scrollbar_alpha + delta);
        changed = true;
    } else if (ext_win.scrollbar_alpha > ext_win.scrollbar_target_alpha) {
        ext_win.scrollbar_alpha = @max(ext_win.scrollbar_target_alpha, ext_win.scrollbar_alpha - delta);
        changed = true;
    }

    if (changed) {
        // Row-mode paint restores the narrow saved scrollbar underlay before
        // drawing the new alpha. No terminal rows need to be regenerated.
        app.mu.lockUncancelable(core.clock.io());
        ext_win.needs_redraw = true;
        app.mu.unlock(core.clock.io());
        invalidateScrollbarTrackForExternal(hwnd, ext_win.dpi_scale);
    }

    // Check if we've reached target
    if (@abs(ext_win.scrollbar_alpha - ext_win.scrollbar_target_alpha) < 0.01) {
        ext_win.scrollbar_alpha = ext_win.scrollbar_target_alpha;
        _ = c.KillTimer(hwnd, app_mod.TIMER_SCROLLBAR_FADE);

        if (ext_win.scrollbar_alpha <= 0.0) {
            ext_win.scrollbar_visible = false;
            app.mu.lockUncancelable(core.clock.io());
            ext_win.needs_redraw = true;
            app.mu.unlock(core.clock.io());
            invalidateScrollbarTrackForExternal(hwnd, ext_win.dpi_scale);
        }
    }
}

pub fn generateScrollbarVertices(app: *App, client_width: i32, client_height: i32, out_verts: *[12]app_mod.Vertex) usize {
    if (!app.config.scrollbar.enabled) return 0;
    if (app.scrollbar_alpha <= 0.001) return 0;

    const geom = getScrollbarGeometry(app, client_width, client_height);
    if (!geom.is_scrollable and !app.config.scrollbar.isAlways()) return 0;

    return scrollbarVerticesFrom(
        geom,
        app.config.scrollbar.opacity,
        app.config.scrollbar.isAlways(),
        app.scrollbar_alpha,
        client_width,
        client_height,
        0, // the main window's knob fills its track edge to edge
        out_verts,
    );
}

/// Hit test scrollbar area
pub fn scrollbarHitTest(app: *App, client_width: i32, client_height: i32, mouse_x: i32, mouse_y: i32) ScrollbarHit {
    if (!app.config.scrollbar.enabled) return .none;
    return scrollbarHitFrom(
        getScrollbarGeometry(app, client_width, client_height),
        mouse_x,
        mouse_y,
    );
}

/// Handle scrollbar mouse down
pub fn scrollbarMouseDown(hwnd: c.HWND, app: *App, mouse_x: i32, mouse_y: i32) bool {
    var client: c.RECT = undefined;
    _ = c.GetClientRect(hwnd, &client);

    const geom = getScrollbarGeometry(app, client.right, client.bottom);
    const hit = scrollbarHitTest(app, client.right, client.bottom, mouse_x, mouse_y);

    if (applog.isEnabled()) applog.appLog("[scrollbar] mouseDown x={d} y={d} client=({d},{d}) track=({d:.0},{d:.0})-({d:.0},{d:.0}) knob=({d:.0},{d:.0}) hit={s}\n", .{
        mouse_x,         mouse_y,          client.right,     client.bottom,
        geom.track_left, geom.track_top,   geom.track_right, geom.track_bottom,
        geom.knob_top,   geom.knob_bottom, @tagName(hit),
    });

    if (app.corep == null) return false;

    switch (hit) {
        .knob => {
            // Start dragging
            app.scrollbar_dragging = true;
            app.scrollbar_drag_start_y = mouse_y;

            var vp: app_mod.ViewportInfo = undefined;
            if (getViewportNonBlocking(app, scrollbarGrid(app, 1), &vp) != .none) {
                app.scrollbar_drag_start_topline = vp.topline;
            }

            _ = c.SetCapture(hwnd);
            return true;
        },
        .track_above => {
            // Page up - execute immediately and start repeat timer
            if (applog.isEnabled()) applog.appLog("[scrollbar] track_above: executing page scroll up\n", .{});
            scrollbarPageScroll(app, -1);
            // Armed after SetCapture: it synchronously delivers
            // WM_CAPTURECHANGED to whichever window held capture, and that
            // handler clears the repeat state.
            _ = c.SetCapture(hwnd);
            app.scrollbar_repeat_dir = -1;
            app.scrollbar_repeat_timer = c.SetTimer(hwnd, app_mod.TIMER_SCROLLBAR_REPEAT, app_mod.SCROLLBAR_REPEAT_DELAY, null);
            showScrollbar(hwnd, app);
            return true;
        },
        .track_below => {
            // Page down - execute immediately and start repeat timer
            if (applog.isEnabled()) applog.appLog("[scrollbar] track_below: executing page scroll down\n", .{});
            scrollbarPageScroll(app, 1);
            // Armed after SetCapture — see track_above.
            _ = c.SetCapture(hwnd);
            app.scrollbar_repeat_dir = 1;
            app.scrollbar_repeat_timer = c.SetTimer(hwnd, app_mod.TIMER_SCROLLBAR_REPEAT, app_mod.SCROLLBAR_REPEAT_DELAY, null);
            showScrollbar(hwnd, app);
            return true;
        },
        .none => return false,
    }
}

/// Handle scrollbar mouse move (dragging)
pub fn scrollbarMouseMove(hwnd: c.HWND, app: *App, mouse_y: i32) void {
    if (!app.scrollbar_dragging) return;

    const corep = app.corep orelse return;

    var client: c.RECT = undefined;
    _ = c.GetClientRect(hwnd, &client);

    const geom = getScrollbarGeometry(app, client.right, client.bottom);
    if (!geom.is_scrollable) return;

    var vp: app_mod.ViewportInfo = undefined;
    if (getViewportNonBlocking(app, scrollbarGrid(app, 1), &vp) == .none) return;

    const visible_lines = vp.botline - vp.topline;
    if (visible_lines <= 0) return;

    // Calculate knob travel range
    const track_height = geom.track_bottom - geom.track_top;
    const visible_f: f32 = @floatFromInt(visible_lines);
    const total_f: f32 = @floatFromInt(@max(1, vp.line_count));
    const knob_proportion = @min(1.0, visible_f / total_f);
    var knob_height = track_height * knob_proportion;
    knob_height = @max(app_mod.scrollbarMinKnobHeight(app.dpi_scale), knob_height);
    const knob_travel = track_height - knob_height;
    if (knob_travel <= 0) return;

    // Calculate target topline from mouse position relative to track
    // mouse_y relative to track top -> position in track
    const mouse_in_track: f32 = @as(f32, @floatFromInt(mouse_y)) - geom.track_top - knob_height / 2.0;
    const scroll_ratio = @max(0.0, @min(1.0, mouse_in_track / knob_travel));

    // The line the ratio names is the core's rule, shared with the external
    // window and both macOS surfaces.
    var drag: app_mod.zonvie_scrollbar_drag_target = undefined;
    app_mod.zonvie_core_scrollbar_drag_target(scroll_ratio, vp.topline, vp.botline, vp.line_count, &drag);
    const target_line: i64 = drag.line;
    const use_bottom = drag.use_bottom != 0;

    // Always store pending position
    app.scrollbar_pending_line = target_line;
    app.scrollbar_pending_use_bottom = use_bottom;

    // Throttle: only send RPC if enough time has passed
    const now: i64 = @intCast(c.GetTickCount64());
    const elapsed = now - app.scrollbar_last_scroll_time;

    if (elapsed >= app_mod.SCROLLBAR_THROTTLE_MS) {
        if (applog.isEnabled()) applog.appLog("[scrollbar] mouseMove y={d} ratio={d:.3} line={d} bottom={any} (sending)\n", .{
            mouse_y, scroll_ratio, target_line, use_bottom,
        });
        app_mod.zonvie_core_scroll_to_line(corep, scrollbarGrid(app, 1), target_line, use_bottom);
        app.scrollbar_last_scroll_time = now;
        app.scrollbar_pending_line = -1; // Clear pending
    }
}

/// Execute page scroll in given direction (-1 = up, 1 = down)
pub fn scrollbarPageScroll(app: *App, direction: i8) void {
    const corep = app.corep orelse {
        if (applog.isEnabled()) applog.appLog("[scrollbar] scrollbarPageScroll: corep is null\n", .{});
        return;
    };

    if (applog.isEnabled()) applog.appLog("[scrollbar] scrollbarPageScroll: direction={d}\n", .{direction});

    // The grid this scrollbar SHOWS, which is the one it has to act on:
    // grid -1 is the cursor's window, so this paged an external window
    // whenever the cursor was in one.
    app_mod.zonvie_core_page_scroll(corep, scrollbarGrid(app, 1), direction > 0);
}

/// Handle scrollbar mouse up
pub fn scrollbarMouseUp(hwnd: c.HWND, app: *App) void {
    if (app.scrollbar_dragging) {
        // Send any pending scroll position before releasing
        if (app.scrollbar_pending_line > 0) {
            if (app.corep) |corep| {
                if (applog.isEnabled()) applog.appLog("[scrollbar] mouseUp sending pending line={d} bottom={any}\n", .{ app.scrollbar_pending_line, app.scrollbar_pending_use_bottom });
                app_mod.zonvie_core_scroll_to_line(corep, scrollbarGrid(app, 1), app.scrollbar_pending_line, app.scrollbar_pending_use_bottom);
            }
            app.scrollbar_pending_line = -1;
        }
        app.scrollbar_dragging = false;
        _ = c.ReleaseCapture();
    }

    // Stop repeat timer if running
    if (app.scrollbar_repeat_timer != 0) {
        _ = c.KillTimer(hwnd, app_mod.TIMER_SCROLLBAR_REPEAT);
        app.scrollbar_repeat_timer = 0;
        app.scrollbar_repeat_dir = 0;
        _ = c.ReleaseCapture();
    }
}

/// Update scrollbar state based on viewport info (called from message loop)
pub fn updateScrollbar(hwnd: c.HWND, app: *App) void {
    if (!app.config.scrollbar.enabled) return;

    const corep = app.corep;
    if (corep == null) return;

    // When the cursor is in a grid an external window shows (its root or a
    // float it hosts), that window's scrollbar is the one this update is
    // for; the main window scrollbar only reflects grids composited on the
    // main window. The external one used to be skipped outright, so a
    // keyboard or programmatic scroll there never showed its bar — only the
    // wheel handler did. macOS updates both views after every flush.
    // Non-blocking: on lock contention this serves the cached position; a
    // cold cache (-1) simply falls through to the main-window update below.
    var cur_row: i32 = 0;
    var cur_col: i32 = 0;
    var cursor_stale = false;
    const cursor_grid = input.getCursorPositionNonBlocking(app, corep.?, &cur_row, &cur_col, &cursor_stale);
    const cursor_ext = blk: {
        if (cursor_grid <= 1) break :blk null;
        app.mu.lockUncancelable(core.clock.io());
        defer app.mu.unlock(core.clock.io());
        break :blk callbacks.externalWindowShowingGridLocked(app, cursor_grid);
    };
    if (cursor_ext) |shown| {
        if (cursor_stale) {
            // The cached "on an external grid" position may predate the
            // flush that posted this one-shot WM_APP_UPDATE_SCROLLBAR; the
            // cursor may already be back on the main grid. Retry shortly
            // instead of silently dropping the main-window scrollbar update
            // (mirrors the viewport-read retry a few lines below).
            // Deliberately not re-posted on SetTimer failure: the message would
            // re-enter this same handler with no delay, and the condition that
            // fails SetTimer (USER handle pressure) persists, so it spins the
            // message loop ahead of WM_PAINT. Losing one cosmetic scrollbar
            // update is the milder failure.
            _ = c.SetTimer(hwnd, app_mod.TIMER_SCROLLBAR_RETRY, app_mod.LOCK_RETRY_INTERVAL_MS, null);
            return;
        }
        updateScrollbarForExternal(hwnd, app, shown.win, shown.root_grid_id);
        return;
    }

    // Get current viewport info
    var vp: app_mod.ViewportInfo = undefined;
    switch (getViewportNonBlocking(app, scrollbarGrid(app, 1), &vp)) {
        .fresh => {},
        .none => return,
        .cached => {
            // Lock busy: the cached viewport predates the flush that posted
            // this one-shot WM_APP_UPDATE_SCROLLBAR (already consumed), so
            // acting on it would silently drop the post-scroll show/repaint.
            // Retry shortly instead (mirrors macOS's 16ms timer re-arm).
            // Not re-posted on SetTimer failure — see the note above.
            _ = c.SetTimer(hwnd, app_mod.TIMER_SCROLLBAR_RETRY, app_mod.LOCK_RETRY_INTERVAL_MS, null);
            return;
        },
    }

    // Check if viewport changed
    const viewport_changed = vp.topline != app.last_viewport_topline or
        vp.line_count != app.last_viewport_line_count or
        vp.botline != app.last_viewport_botline or
        app.last_viewport_topline == -1;

    if (!viewport_changed) return;

    app.last_viewport_topline = vp.topline;
    app.last_viewport_line_count = vp.line_count;
    app.last_viewport_botline = vp.botline;

    var metrics: app_mod.zonvie_scrollbar_metrics = undefined;
    app_mod.zonvie_core_scrollbar_metrics(vp.topline, vp.botline, vp.line_count, &metrics);

    if (metrics.is_scrollable == 0 and !app.config.scrollbar.isAlways()) {
        hideScrollbar(hwnd, app);
        return;
    }

    // Show scrollbar based on mode
    if (app.config.scrollbar.isScroll() or app.config.scrollbar.isAlways()) {
        showScrollbar(hwnd, app);
    }

    // Request repaint for scrollbar area
    invalidateScrollbarTrack(hwnd, app);
}

/// updateScrollbar for an external window: the same viewport comparison
/// and show/hide rule as the main window, against this window's own
/// last-seen viewport. `main_hwnd` receives the lock-busy retry, which
/// re-enters updateScrollbar and routes here again.
fn updateScrollbarForExternal(main_hwnd: c.HWND, app: *App, ext_win: *app_mod.ExternalWindow, root_grid_id: i64) void {
    var vp: app_mod.ViewportInfo = undefined;
    switch (getViewportNonBlocking(app, scrollbarGrid(app, root_grid_id), &vp)) {
        .fresh => {},
        .none => return,
        .cached => {
            _ = c.SetTimer(main_hwnd, app_mod.TIMER_SCROLLBAR_RETRY, app_mod.LOCK_RETRY_INTERVAL_MS, null);
            return;
        },
    }

    const viewport_changed = vp.topline != ext_win.last_viewport_topline or
        vp.line_count != ext_win.last_viewport_line_count or
        vp.botline != ext_win.last_viewport_botline or
        ext_win.last_viewport_topline == -1;
    if (!viewport_changed) return;

    ext_win.last_viewport_topline = vp.topline;
    ext_win.last_viewport_line_count = vp.line_count;
    ext_win.last_viewport_botline = vp.botline;

    var metrics: app_mod.zonvie_scrollbar_metrics = undefined;
    app_mod.zonvie_core_scrollbar_metrics(vp.topline, vp.botline, vp.line_count, &metrics);

    if (metrics.is_scrollable == 0 and !app.config.scrollbar.isAlways()) {
        hideScrollbarForExternal(ext_win.hwnd, app, ext_win);
        return;
    }
    if (app.config.scrollbar.isScroll() or app.config.scrollbar.isAlways()) {
        showScrollbarForExternal(ext_win.hwnd, ext_win);
        // Auto-hide after the delay, as the wheel handler arms it.
        if (app.config.scrollbar.isScroll() and !app.config.scrollbar.isAlways()) {
            const delay_ms: c.UINT = @intFromFloat(app.config.scrollbar.delay * 1000.0);
            _ = c.SetTimer(ext_win.hwnd, app_mod.TIMER_SCROLLBAR_AUTOHIDE, delay_ms, null);
        }
    }
    invalidateScrollbarTrackForExternal(ext_win.hwnd, ext_win.dpi_scale);
}

/// Show scrollbar with fade-in animation
pub fn showScrollbar(hwnd: c.HWND, app: *App) void {
    if (!app.config.scrollbar.enabled) return;

    app.scrollbar_visible = true;
    app.scrollbar_target_alpha = 1.0;

    // Start fade animation if not already at target
    if (app.scrollbar_alpha < 1.0) {
        _ = c.SetTimer(hwnd, app_mod.TIMER_SCROLLBAR_FADE, app_mod.SCROLLBAR_FADE_INTERVAL, null);
    }

    // Cancel existing hide timer
    if (app.scrollbar_hide_timer != 0) {
        _ = c.KillTimer(hwnd, app_mod.TIMER_SCROLLBAR_AUTOHIDE);
        app.scrollbar_hide_timer = 0;
    }

    // Set auto-hide timer if in scroll mode and not always visible
    if (app.config.scrollbar.isScroll() and !app.config.scrollbar.isAlways()) {
        const delay_ms: c.UINT = @intFromFloat(app.config.scrollbar.delay * 1000.0);
        app.scrollbar_hide_timer = c.SetTimer(hwnd, app_mod.TIMER_SCROLLBAR_AUTOHIDE, delay_ms, null);
    }
}

/// Hide scrollbar with fade-out animation
pub fn hideScrollbar(hwnd: c.HWND, app: *App) void {
    if (!app.config.scrollbar.enabled) return;
    if (app.config.scrollbar.isAlways()) return; // Never hide in always mode
    if (app.scrollbar_dragging) return; // Don't hide while dragging

    app.scrollbar_target_alpha = 0.0;

    // Start fade animation if not already at target
    if (app.scrollbar_alpha > 0.0) {
        _ = c.SetTimer(hwnd, app_mod.TIMER_SCROLLBAR_FADE, app_mod.SCROLLBAR_FADE_INTERVAL, null);
    }
}

/// Update scrollbar fade animation (called from timer)
pub fn updateScrollbarFade(hwnd: c.HWND, app: *App) void {
    const fade_speed: f32 = 0.15; // Alpha change per frame

    if (app.scrollbar_alpha < app.scrollbar_target_alpha) {
        app.scrollbar_alpha = @min(app.scrollbar_target_alpha, app.scrollbar_alpha + fade_speed);
    } else if (app.scrollbar_alpha > app.scrollbar_target_alpha) {
        app.scrollbar_alpha = @max(app.scrollbar_target_alpha, app.scrollbar_alpha - fade_speed);
    }

    // Stop timer when animation complete
    if (@abs(app.scrollbar_alpha - app.scrollbar_target_alpha) < 0.01) {
        app.scrollbar_alpha = app.scrollbar_target_alpha;
        _ = c.KillTimer(hwnd, app_mod.TIMER_SCROLLBAR_FADE);

        if (app.scrollbar_alpha <= 0.0) {
            app.scrollbar_visible = false;
        }
    }

    // Request repaint
    invalidateScrollbarTrack(hwnd, app);
}
