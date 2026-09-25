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

/// One surface's scrollbar: the window it is drawn in, its state, the root grid
/// whose knob it shows, and the chrome around it. The main window and every
/// external window go through the same functions below with their own
/// Surface; the two used to have a copy each.
pub const Surface = struct {
    hwnd: c.HWND,
    state: *app_mod.ScrollbarState,
    root_grid: i64,
    dpi_scale: f32,
    /// Space a titlebar tabline takes above the track (main window only).
    top_offset_px: f32,
    /// External windows inset the knob 1px inside its track and the main
    /// window does not; the two look different, and making them agree is a
    /// visual decision, not a side effect of sharing code.
    knob_inset_px: f32,
    /// An external window repaints only on its needs_redraw flag.
    ext_win: ?*app_mod.ExternalWindow = null,
};

pub fn mainSurface(hwnd: c.HWND, app: *App) Surface {
    // Only titlebar mode occupies vertical space above the terminal; sidebar
    // mode shifts content horizontally and must keep the track at the top.
    return .{
        .hwnd = hwnd,
        .state = &app.scrollbar,
        .root_grid = 1,
        .dpi_scale = app.dpi_scale,
        .top_offset_px = @floatFromInt(input.surfaceOriginPx(app, true).y),
        .knob_inset_px = 0,
    };
}

/// dpi_scale is the window's own monitor DPI, which may differ from
/// app.dpi_scale on a mixed-DPI setup; no tabline sits above its content.
pub fn externalSurface(ext_win: *app_mod.ExternalWindow, grid_id: i64) Surface {
    return .{
        .hwnd = ext_win.hwnd,
        .state = &ext_win.scrollbar,
        .root_grid = grid_id,
        .dpi_scale = ext_win.dpi_scale,
        .top_offset_px = 0,
        .knob_inset_px = 1,
        .ext_win = ext_win,
    };
}

/// Pixel damage covered by the track. This deliberately does not query the
/// core viewport: it is also needed once fade-out reaches zero, when only the
/// previously saved overlay must be restored.
pub fn trackRect(sf: Surface, client_width: i32, client_height: i32) ?c.RECT {
    return trackDamageRect(client_width, client_height, sf.dpi_scale, sf.top_offset_px);
}

fn invalidateTrack(sf: Surface) void {
    var client: c.RECT = undefined;
    _ = c.GetClientRect(sf.hwnd, &client);
    if (trackRect(sf, client.right - client.left, client.bottom - client.top)) |rect| {
        _ = c.InvalidateRect(sf.hwnd, &rect, c.FALSE);
    } else {
        _ = c.InvalidateRect(sf.hwnd, null, c.FALSE);
    }
}

/// Row-mode paint restores the narrow saved scrollbar underlay before drawing
/// the new alpha; an external window paints only when told to.
fn repaintTrack(app: *App, sf: Surface) void {
    if (sf.ext_win) |ew| {
        app.mu.lockUncancelable(core.clock.io());
        ew.needs_redraw = true;
        app.mu.unlock(core.clock.io());
    }
    invalidateTrack(sf);
}

pub fn geometry(app: *App, sf: Surface, client_width: i32, client_height: i32) app_mod.ScrollbarGeometry {
    return scrollbarGeometryFor(app, scrollbarGrid(app, sf.root_grid), client_width, client_height, sf.dpi_scale, sf.top_offset_px);
}

/// The track and knob quads at `alpha` (a paint passes the alpha it
/// snapshotted under its lock).
pub fn vertices(app: *App, sf: Surface, alpha: f32, client_width: i32, client_height: i32, out_verts: *[12]app_mod.Vertex) usize {
    if (!app.config.scrollbar.enabled) return 0;
    if (alpha <= 0.001) return 0;

    const geom = geometry(app, sf, client_width, client_height);
    if (!geom.is_scrollable and !app.config.scrollbar.isAlways()) return 0;

    return scrollbarVerticesFrom(
        geom,
        app.config.scrollbar.opacity,
        app.config.scrollbar.isAlways(),
        alpha,
        client_width,
        client_height,
        sf.knob_inset_px,
        out_verts,
    );
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

/// Draw the bar over the clean strip under it, saving that strip first so the
/// next fade step restores it instead of repainting rows. Returns the rect
/// the save captured (the present has to include it), null when nothing was
/// drawn.
pub fn drawOverlay(
    app: *App,
    g: *app_mod.d3d11.Renderer,
    sf: Surface,
    alpha: f32,
    client_width: i32,
    client_height: i32,
    vb: *?*c.ID3D11Buffer,
    vb_bytes: *usize,
) !?c.RECT {
    if (!app.config.scrollbar.enabled or alpha <= 0.001) return null;
    var verts: [12]app_mod.Vertex = undefined;
    const n = vertices(app, sf, alpha, client_width, client_height, &verts);
    if (n == 0) return null;
    const rect = trackRect(sf, client_width, client_height) orelse return null;
    return app_mod.drawScrollbarOverlayOverUnderlay(g, vb, vb_bytes, verts[0..n], rect);
}

pub fn hitTest(app: *App, sf: Surface, client_width: i32, client_height: i32, mouse_x: i32, mouse_y: i32) ScrollbarHit {
    if (!app.config.scrollbar.enabled) return .none;
    return scrollbarHitFrom(geometry(app, sf, client_width, client_height), mouse_x, mouse_y);
}

/// Page the grid this scrollbar shows (-1 = up, 1 = down), so a float the
/// surface hosts pages too; grid -1 would be the cursor's window.
pub fn pageScroll(app: *App, sf: Surface, direction: i8) void {
    const corep = app.corep orelse return;
    app_mod.zonvie_core_page_scroll(corep, scrollbarGrid(app, sf.root_grid), direction > 0);
}

pub fn mouseDown(app: *App, sf: Surface, mouse_x: i32, mouse_y: i32) bool {
    var client: c.RECT = undefined;
    _ = c.GetClientRect(sf.hwnd, &client);

    const hit = hitTest(app, sf, client.right, client.bottom, mouse_x, mouse_y);
    if (applog.isEnabled()) applog.appLog("[scrollbar] mouseDown grid={d} x={d} y={d} hit={s}\n", .{ sf.root_grid, mouse_x, mouse_y, @tagName(hit) });

    if (app.corep == null) return false;
    const st = sf.state;

    switch (hit) {
        .knob => {
            st.dragging = true;
            st.drag_start_y = mouse_y;
            var vp: app_mod.ViewportInfo = undefined;
            if (getViewportNonBlocking(app, scrollbarGrid(app, sf.root_grid), &vp) != .none) {
                st.drag_start_topline = vp.topline;
            }
            _ = c.SetCapture(sf.hwnd);
            return true;
        },
        .track_above, .track_below => {
            const dir: i8 = if (hit == .track_above) -1 else 1;
            // Page once now, then repeat while held. Armed after SetCapture:
            // it synchronously delivers WM_CAPTURECHANGED to whichever window
            // held capture, and that handler clears the repeat state.
            pageScroll(app, sf, dir);
            _ = c.SetCapture(sf.hwnd);
            st.repeat_dir = dir;
            st.repeat_timer = c.SetTimer(sf.hwnd, app_mod.TIMER_SCROLLBAR_REPEAT, app_mod.SCROLLBAR_REPEAT_DELAY, null);
            show(app, sf);
            return true;
        },
        .none => return false,
    }
}

/// Knob drag: the line under the knob, sent at most every
/// SCROLLBAR_THROTTLE_MS and kept pending in between.
pub fn mouseMove(app: *App, sf: Surface, mouse_y: i32) void {
    const st = sf.state;
    if (!st.dragging) return;
    const corep = app.corep orelse return;

    var client: c.RECT = undefined;
    _ = c.GetClientRect(sf.hwnd, &client);
    const geom = geometry(app, sf, client.right, client.bottom);
    if (!geom.is_scrollable) return;

    const grid = scrollbarGrid(app, sf.root_grid);
    var vp: app_mod.ViewportInfo = undefined;
    if (getViewportNonBlocking(app, grid, &vp) == .none) return;
    if (vp.botline - vp.topline <= 0) return;

    // The drawn knob's own travel, so the knob stays under the pointer.
    const knob_height = geom.knob_bottom - geom.knob_top;
    const knob_travel = (geom.track_bottom - geom.track_top) - knob_height;
    if (knob_travel <= 0) return;

    const mouse_in_track: f32 = @as(f32, @floatFromInt(mouse_y)) - geom.track_top - knob_height / 2.0;
    const scroll_ratio = @max(0.0, @min(1.0, mouse_in_track / knob_travel));

    // The line the ratio names is the core's rule, shared with both macOS
    // surfaces.
    var drag: app_mod.zonvie_scrollbar_drag_target = undefined;
    app_mod.zonvie_core_scrollbar_drag_target(scroll_ratio, vp.topline, vp.botline, vp.line_count, &drag);
    st.pending_line = drag.line;
    st.pending_use_bottom = drag.use_bottom != 0;

    const now: i64 = @intCast(c.GetTickCount64());
    if (now - st.last_scroll_time < app_mod.SCROLLBAR_THROTTLE_MS) return;
    st.last_scroll_time = now;
    app_mod.zonvie_core_scroll_to_line(corep, grid, st.pending_line, st.pending_use_bottom);
    st.pending_line = -1;
}

pub fn mouseUp(app: *App, sf: Surface) void {
    const st = sf.state;
    if (st.dragging) {
        // Send the position the throttle held back before releasing.
        if (st.pending_line >= 0) {
            if (app.corep) |corep| {
                app_mod.zonvie_core_scroll_to_line(corep, scrollbarGrid(app, sf.root_grid), st.pending_line, st.pending_use_bottom);
            }
            st.pending_line = -1;
        }
        st.dragging = false;
        _ = c.ReleaseCapture();
    }
    if (st.repeat_timer != 0) {
        _ = c.KillTimer(sf.hwnd, app_mod.TIMER_SCROLLBAR_REPEAT);
        st.repeat_timer = 0;
        st.repeat_dir = 0;
        _ = c.ReleaseCapture();
    }
}

/// Capture was taken away: WM_LBUTTONUP will not arrive, and it is the only
/// place a drag or track-repeat ends. The drag is cancelled rather than
/// committed -- its pending line was never confirmed by a mouse-up.
pub fn cancelPointer(sf: Surface) void {
    const st = sf.state;
    if (st.dragging) {
        st.dragging = false;
        st.pending_line = -1;
    }
    if (st.repeat_timer != 0 or st.repeat_dir != 0) {
        _ = c.KillTimer(sf.hwnd, app_mod.TIMER_SCROLLBAR_REPEAT);
        st.repeat_timer = 0;
        st.repeat_dir = 0;
    }
}

/// Hover mode: show while the pointer is over the track. Returns true when
/// the pointer just entered it (the caller may need WM_MOUSELEAVE).
pub fn hover(app: *App, sf: Surface, mouse_x: i32, mouse_y: i32) bool {
    if (!app.config.scrollbar.enabled or !app.config.scrollbar.isHover()) return false;
    var client: c.RECT = undefined;
    _ = c.GetClientRect(sf.hwnd, &client);
    const in_track = hitTest(app, sf, client.right, client.bottom, mouse_x, mouse_y) != .none;
    if (in_track and !sf.state.hover) {
        sf.state.hover = true;
        show(app, sf);
        return true;
    }
    if (!in_track and sf.state.hover) leave(app, sf);
    return false;
}

/// The pointer left the track (or the window).
pub fn leave(app: *App, sf: Surface) void {
    if (!sf.state.hover) return;
    sf.state.hover = false;
    if (!app.config.scrollbar.isAlways() and !app.config.scrollbar.isScroll()) hide(app, sf);
}

/// Fade in, and in scroll mode arm the auto-hide.
pub fn show(app: *App, sf: Surface) void {
    if (!app.config.scrollbar.enabled) return;
    const st = sf.state;
    st.visible = true;
    st.target_alpha = 1.0;
    if (st.alpha < 1.0) {
        _ = c.SetTimer(sf.hwnd, app_mod.TIMER_SCROLLBAR_FADE, app_mod.SCROLLBAR_FADE_INTERVAL, null);
    }
    if (st.hide_timer != 0) {
        _ = c.KillTimer(sf.hwnd, app_mod.TIMER_SCROLLBAR_AUTOHIDE);
        st.hide_timer = 0;
    }
    if (app.config.scrollbar.isScroll() and !app.config.scrollbar.isAlways()) {
        const delay_ms: c.UINT = @intFromFloat(app.config.scrollbar.delay * 1000.0);
        st.hide_timer = c.SetTimer(sf.hwnd, app_mod.TIMER_SCROLLBAR_AUTOHIDE, delay_ms, null);
    }
}

pub fn hide(app: *App, sf: Surface) void {
    if (!app.config.scrollbar.enabled) return;
    if (app.config.scrollbar.isAlways()) return; // Never hide in always mode
    const st = sf.state;
    if (st.dragging) return; // Don't hide while dragging
    st.target_alpha = 0.0;
    if (st.alpha > 0.0) {
        _ = c.SetTimer(sf.hwnd, app_mod.TIMER_SCROLLBAR_FADE, app_mod.SCROLLBAR_FADE_INTERVAL, null);
    }
}

/// One fade step, from the fade timer.
pub fn fade(app: *App, sf: Surface) void {
    const step: f32 = 0.15;
    const st = sf.state;
    var changed = false;
    if (st.alpha < st.target_alpha) {
        st.alpha = @min(st.target_alpha, st.alpha + step);
        changed = true;
    } else if (st.alpha > st.target_alpha) {
        st.alpha = @max(st.target_alpha, st.alpha - step);
        changed = true;
    }
    if (@abs(st.alpha - st.target_alpha) < 0.01) {
        st.alpha = st.target_alpha;
        _ = c.KillTimer(sf.hwnd, app_mod.TIMER_SCROLLBAR_FADE);
        if (st.alpha <= 0.0) {
            st.visible = false;
            changed = true;
        }
    }
    if (changed) repaintTrack(app, sf);
}

/// The scrollbar's timers. Returns false for any other timer id.
pub fn onTimer(app: *App, sf: Surface, timer_id: usize) bool {
    const st = sf.state;
    if (timer_id == app_mod.TIMER_SCROLLBAR_FADE) {
        fade(app, sf);
    } else if (timer_id == app_mod.TIMER_SCROLLBAR_REPEAT) {
        if (st.repeat_dir != 0) {
            pageScroll(app, sf, st.repeat_dir);
            // After the first delay, repeat at the faster interval.
            _ = c.KillTimer(sf.hwnd, app_mod.TIMER_SCROLLBAR_REPEAT);
            st.repeat_timer = c.SetTimer(sf.hwnd, app_mod.TIMER_SCROLLBAR_REPEAT, app_mod.SCROLLBAR_REPEAT_INTERVAL, null);
        }
    } else if (timer_id == app_mod.TIMER_SCROLLBAR_AUTOHIDE) {
        _ = c.KillTimer(sf.hwnd, app_mod.TIMER_SCROLLBAR_AUTOHIDE);
        st.hide_timer = 0;
        hide(app, sf);
    } else return false;
    return true;
}

/// Update scrollbar state based on viewport info (called from message loop)
pub fn updateScrollbar(hwnd: c.HWND, app: *App) void {
    if (!app.config.scrollbar.enabled) return;

    const corep = app.corep;
    if (corep == null) return;

    // When the cursor is in a grid an external window shows (its root or a
    // float it hosts), that window's scrollbar is the one this update is
    // for; the main window scrollbar only reflects grids composited on the
    // main window. macOS updates both views after every flush.
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
            // instead of silently dropping the update. Deliberately not
            // re-posted on SetTimer failure: the message would re-enter this
            // handler with no delay, and the condition that fails SetTimer
            // (USER handle pressure) persists, so it spins the message loop
            // ahead of WM_PAINT. Losing one cosmetic update is milder.
            _ = c.SetTimer(hwnd, app_mod.TIMER_SCROLLBAR_RETRY, app_mod.LOCK_RETRY_INTERVAL_MS, null);
            return;
        }
        updateSurface(hwnd, app, externalSurface(shown.win, shown.root_grid_id));
        return;
    }
    updateSurface(hwnd, app, mainSurface(hwnd, app));
}

/// Show or hide one surface's bar for the viewport its grid shows now.
/// `retry_hwnd` (the main window) receives the lock-busy retry, which
/// re-enters updateScrollbar.
fn updateSurface(retry_hwnd: c.HWND, app: *App, sf: Surface) void {
    var vp: app_mod.ViewportInfo = undefined;
    switch (getViewportNonBlocking(app, scrollbarGrid(app, sf.root_grid), &vp)) {
        .fresh => {},
        .none => return,
        .cached => {
            // Lock busy: the cached viewport predates the flush that posted
            // this one-shot WM_APP_UPDATE_SCROLLBAR (already consumed), so
            // acting on it would silently drop the post-scroll show/repaint.
            // Retry shortly instead (mirrors macOS's 16ms timer re-arm).
            _ = c.SetTimer(retry_hwnd, app_mod.TIMER_SCROLLBAR_RETRY, app_mod.LOCK_RETRY_INTERVAL_MS, null);
            return;
        },
    }

    const st = sf.state;
    const viewport_changed = vp.topline != st.last_viewport_topline or
        vp.line_count != st.last_viewport_line_count or
        vp.botline != st.last_viewport_botline or
        st.last_viewport_topline == -1;
    if (!viewport_changed) return;

    st.last_viewport_topline = vp.topline;
    st.last_viewport_line_count = vp.line_count;
    st.last_viewport_botline = vp.botline;

    var metrics: app_mod.zonvie_scrollbar_metrics = undefined;
    app_mod.zonvie_core_scrollbar_metrics(vp.topline, vp.botline, vp.line_count, &metrics);

    if (metrics.is_scrollable == 0 and !app.config.scrollbar.isAlways()) {
        hide(app, sf);
        return;
    }
    if (app.config.scrollbar.isScroll() or app.config.scrollbar.isAlways()) show(app, sf);
    repaintTrack(app, sf);
}
