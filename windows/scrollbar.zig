const std = @import("std");
const app_mod = @import("app.zig");
const App = app_mod.App;
const c = app_mod.c;
const applog = app_mod.applog;

pub fn getScrollbarGeometry(app: *App, client_width: i32, client_height: i32) struct {
    track_left: f32,
    track_top: f32,
    track_right: f32,
    track_bottom: f32,
    knob_top: f32,
    knob_bottom: f32,
    is_scrollable: bool,
} {
    const corep = app.corep;
    if (corep == null) return .{
        .track_left = 0,
        .track_top = 0,
        .track_right = 0,
        .track_bottom = 0,
        .knob_top = 0,
        .knob_bottom = 0,
        .is_scrollable = false,
    };

    var vp: app_mod.ViewportInfo = undefined;
    if (app_mod.zonvie_core_get_viewport(corep, -1, &vp) == 0) return .{
        .track_left = 0,
        .track_top = 0,
        .track_right = 0,
        .track_bottom = 0,
        .knob_top = 0,
        .knob_bottom = 0,
        .is_scrollable = false,
    };

    const visible_lines = vp.botline - vp.topline;
    const is_scrollable = vp.line_count > visible_lines and visible_lines > 0;

    const cw: f32 = @floatFromInt(client_width);
    const ch: f32 = @floatFromInt(client_height);

    // When ext_tabline is enabled, scrollbar should start below the tabbar
    const tabbar_offset: f32 = if (app.ext_tabline_enabled and app.content_hwnd == null)
        @floatFromInt(app_mod.TablineState.TAB_BAR_HEIGHT)
    else
        0;

    // Track position (right edge)
    const track_left = cw - app_mod.SCROLLBAR_WIDTH - app_mod.SCROLLBAR_MARGIN;
    const track_right = cw - app_mod.SCROLLBAR_MARGIN;
    const track_top = app_mod.SCROLLBAR_MARGIN + tabbar_offset;
    const track_bottom = ch - app_mod.SCROLLBAR_MARGIN;
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

    // Knob size proportional to visible portion
    const visible_f: f32 = @floatFromInt(visible_lines);
    const total_f: f32 = @floatFromInt(@max(1, vp.line_count));
    const knob_proportion = @min(1.0, visible_f / total_f);
    var knob_height = track_height * knob_proportion;
    knob_height = @max(app_mod.SCROLLBAR_MIN_KNOB_HEIGHT, knob_height);

    // Knob position
    const scroll_range = total_f - visible_f;
    const scroll_pos: f32 = if (scroll_range > 0) @as(f32, @floatFromInt(vp.topline)) / scroll_range else 0;
    const knob_travel = track_height - knob_height;
    const knob_top = track_top + knob_travel * scroll_pos;
    const knob_bottom = knob_top + knob_height;

    return .{
        .track_left = track_left,
        .track_top = track_top,
        .track_right = track_right,
        .track_bottom = track_bottom,
        .knob_top = knob_top,
        .knob_bottom = knob_bottom,
        .is_scrollable = true,
    };
}

pub fn getScrollbarGeometryForExternal(app: *App, grid_id: i64, client_width: i32, client_height: i32) app_mod.ScrollbarGeometry {
    const corep = app.corep;
    if (corep == null) return .{
        .track_left = 0,
        .track_top = 0,
        .track_right = 0,
        .track_bottom = 0,
        .knob_top = 0,
        .knob_bottom = 0,
        .is_scrollable = false,
    };

    var vp: app_mod.ViewportInfo = undefined;
    if (app_mod.zonvie_core_get_viewport(corep, grid_id, &vp) == 0) return .{
        .track_left = 0,
        .track_top = 0,
        .track_right = 0,
        .track_bottom = 0,
        .knob_top = 0,
        .knob_bottom = 0,
        .is_scrollable = false,
    };

    const visible_lines = vp.botline - vp.topline;
    const is_scrollable = vp.line_count > visible_lines and visible_lines > 0;

    const cw: f32 = @floatFromInt(client_width);
    const ch: f32 = @floatFromInt(client_height);

    // Track position (right edge) - no tabbar offset for external windows
    const track_left = cw - app_mod.SCROLLBAR_WIDTH - app_mod.SCROLLBAR_MARGIN;
    const track_right = cw - app_mod.SCROLLBAR_MARGIN;
    const track_top = app_mod.SCROLLBAR_MARGIN;
    const track_bottom = ch - app_mod.SCROLLBAR_MARGIN;
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

    // Knob size proportional to visible portion
    const visible_f: f32 = @floatFromInt(visible_lines);
    const total_f: f32 = @floatFromInt(@max(1, vp.line_count));
    const knob_proportion = @min(1.0, visible_f / total_f);
    var knob_height = track_height * knob_proportion;
    knob_height = @max(app_mod.SCROLLBAR_MIN_KNOB_HEIGHT, knob_height);

    // Knob position
    const scroll_range = total_f - visible_f;
    const scroll_pos: f32 = if (scroll_range > 0) @as(f32, @floatFromInt(vp.topline)) / scroll_range else 0;
    const knob_travel = track_height - knob_height;
    const knob_top = track_top + knob_travel * scroll_pos;
    const knob_bottom = knob_top + knob_height;

    return .{
        .track_left = track_left,
        .track_top = track_top,
        .track_right = track_right,
        .track_bottom = track_bottom,
        .knob_top = knob_top,
        .knob_bottom = knob_bottom,
        .is_scrollable = true,
    };
}

/// Generate scrollbar vertices for external window
pub fn generateScrollbarVerticesForExternal(
    app: *App,
    scrollbar_alpha: f32,
    grid_id: i64,
    client_width: i32,
    client_height: i32,
    out_verts: *[12]app_mod.Vertex,
) usize {
    if (!app.config.scrollbar.enabled) return 0;
    if (scrollbar_alpha <= 0.001) return 0;

    const geom = getScrollbarGeometryForExternal(app, grid_id, client_width, client_height);
    if (!geom.is_scrollable and !app.config.scrollbar.isAlways()) return 0;

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

    const alpha = scrollbar_alpha * app.config.scrollbar.opacity;

    // Track color
    const is_always_mode = app.config.scrollbar.isAlways();
    const track_alpha: f32 = if (is_always_mode) 1.0 else alpha * 0.5;
    const track_color = [4]f32{ 0.2, 0.2, 0.2, track_alpha };
    // Knob color
    const knob_color = [4]f32{ 0.7, 0.7, 0.7, alpha };

    // Track quad (background) - 6 vertices
    const tl = to_ndc_x(geom.track_left, cw);
    const tr = to_ndc_x(geom.track_right, cw);
    const tt = to_ndc_y(geom.track_top, ch);
    const tb = to_ndc_y(geom.track_bottom, ch);

    // Track Triangle 1
    out_verts[0] = .{ .position = .{ tl, tt }, .texCoord = .{ -1.0, 0 }, .color = track_color, .grid_id = 1, .deco_flags = 0, .deco_phase = 0 };
    out_verts[1] = .{ .position = .{ tr, tt }, .texCoord = .{ -1.0, 0 }, .color = track_color, .grid_id = 1, .deco_flags = 0, .deco_phase = 0 };
    out_verts[2] = .{ .position = .{ tl, tb }, .texCoord = .{ -1.0, 0 }, .color = track_color, .grid_id = 1, .deco_flags = 0, .deco_phase = 0 };

    // Track Triangle 2
    out_verts[3] = .{ .position = .{ tr, tt }, .texCoord = .{ -1.0, 0 }, .color = track_color, .grid_id = 1, .deco_flags = 0, .deco_phase = 0 };
    out_verts[4] = .{ .position = .{ tr, tb }, .texCoord = .{ -1.0, 0 }, .color = track_color, .grid_id = 1, .deco_flags = 0, .deco_phase = 0 };
    out_verts[5] = .{ .position = .{ tl, tb }, .texCoord = .{ -1.0, 0 }, .color = track_color, .grid_id = 1, .deco_flags = 0, .deco_phase = 0 };

    // Knob quad - 6 vertices
    const kl = to_ndc_x(geom.track_left + 1, cw); // Inset by 1px
    const kr = to_ndc_x(geom.track_right - 1, cw);
    const kt = to_ndc_y(geom.knob_top, ch);
    const kb = to_ndc_y(geom.knob_bottom, ch);

    // Knob Triangle 1
    out_verts[6] = .{ .position = .{ kl, kt }, .texCoord = .{ -1.0, 0 }, .color = knob_color, .grid_id = 1, .deco_flags = 0, .deco_phase = 0 };
    out_verts[7] = .{ .position = .{ kr, kt }, .texCoord = .{ -1.0, 0 }, .color = knob_color, .grid_id = 1, .deco_flags = 0, .deco_phase = 0 };
    out_verts[8] = .{ .position = .{ kl, kb }, .texCoord = .{ -1.0, 0 }, .color = knob_color, .grid_id = 1, .deco_flags = 0, .deco_phase = 0 };

    // Knob Triangle 2
    out_verts[9] = .{ .position = .{ kr, kt }, .texCoord = .{ -1.0, 0 }, .color = knob_color, .grid_id = 1, .deco_flags = 0, .deco_phase = 0 };
    out_verts[10] = .{ .position = .{ kr, kb }, .texCoord = .{ -1.0, 0 }, .color = knob_color, .grid_id = 1, .deco_flags = 0, .deco_phase = 0 };
    out_verts[11] = .{ .position = .{ kl, kb }, .texCoord = .{ -1.0, 0 }, .color = knob_color, .grid_id = 1, .deco_flags = 0, .deco_phase = 0 };

    return 12;
}

/// Hit test scrollbar area for external window
pub fn scrollbarHitTestForExternal(
    app: *App,
    grid_id: i64,
    client_width: i32,
    client_height: i32,
    mouse_x: i32,
    mouse_y: i32,
) enum { none, knob, track_above, track_below } {
    if (!app.config.scrollbar.enabled) return .none;

    const geom = getScrollbarGeometryForExternal(app, grid_id, client_width, client_height);
    if (!geom.is_scrollable) return .none;

    const mx: f32 = @floatFromInt(mouse_x);
    const my: f32 = @floatFromInt(mouse_y);

    // Check if in track area horizontally
    if (mx < geom.track_left or mx > geom.track_right) return .none;

    // Check vertical position
    if (my < geom.track_top or my > geom.track_bottom) return .none;

    if (my >= geom.knob_top and my <= geom.knob_bottom) {
        return .knob;
    } else if (my < geom.knob_top) {
        return .track_above;
    } else {
        return .track_below;
    }
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

    var vp: app_mod.ViewportInfo = undefined;
    if (app_mod.zonvie_core_get_viewport(corep, grid_id, &vp) == 0) return;

    const visible_lines = vp.botline - vp.topline;
    const steps = @max(1, visible_lines - 2);
    const dir_str: [*:0]const u8 = if (direction < 0) "up" else "down";

    var i: i64 = 0;
    while (i < steps) : (i += 1) {
        app_mod.zonvie_core_send_mouse_scroll(corep, grid_id, 0, 0, dir_str);
    }
}

/// Handle scrollbar mouse down for external window
pub fn scrollbarMouseDownForExternal(hwnd: c.HWND, app: *App, ext_win: *app_mod.ExternalWindow, grid_id: i64, mouse_x: i32, mouse_y: i32) bool {
    var client: c.RECT = undefined;
    _ = c.GetClientRect(hwnd, &client);

    const hit = scrollbarHitTestForExternal(app, grid_id, client.right, client.bottom, mouse_x, mouse_y);

    const corep = app.corep orelse return false;

    switch (hit) {
        .knob => {
            // Start dragging
            ext_win.scrollbar_dragging = true;
            ext_win.scrollbar_drag_start_y = mouse_y;

            var vp: app_mod.ViewportInfo = undefined;
            if (app_mod.zonvie_core_get_viewport(corep, grid_id, &vp) != 0) {
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

    const geom = getScrollbarGeometryForExternal(app, grid_id, client.right, client.bottom);
    if (!geom.is_scrollable) return;

    var vp: app_mod.ViewportInfo = undefined;
    if (app_mod.zonvie_core_get_viewport(corep, grid_id, &vp) == 0) return;

    const visible_lines = vp.botline - vp.topline;
    if (visible_lines <= 0) return;

    // Calculate knob travel range
    const track_height = geom.track_bottom - geom.track_top;
    const visible_f: f32 = @floatFromInt(visible_lines);
    const total_f: f32 = @floatFromInt(@max(1, vp.line_count));
    const knob_proportion = @min(1.0, visible_f / total_f);
    var knob_height = track_height * knob_proportion;
    knob_height = @max(app_mod.SCROLLBAR_MIN_KNOB_HEIGHT, knob_height);
    const knob_travel = track_height - knob_height;
    if (knob_travel <= 0) return;

    // Calculate target topline from mouse position relative to track
    const mouse_in_track: f32 = @as(f32, @floatFromInt(mouse_y)) - geom.track_top - knob_height / 2.0;
    const scroll_ratio = @max(0.0, @min(1.0, mouse_in_track / knob_travel));

    // scroll_range is max topline value (0-based: 0 to line_count - visible_lines)
    const scroll_range = @max(0, vp.line_count - visible_lines);
    const target_topline_0based: i64 = @intFromFloat(scroll_ratio * @as(f32, @floatFromInt(scroll_range)));

    // 1-based topline for Neovim
    const target_topline_1based: i64 = target_topline_0based + 1;

    // Determine scroll mode: top half uses zt (top), bottom half uses zb (bottom)
    const use_bottom = scroll_ratio >= 0.5;
    const target_line: i64 = if (use_bottom) blk: {
        const bottom_line = target_topline_1based + visible_lines - 1;
        break :blk @min(bottom_line, vp.line_count);
    } else target_topline_1based;

    // Always store pending position
    ext_win.scrollbar_pending_line = target_line;
    ext_win.scrollbar_pending_use_bottom = use_bottom;

    // Throttle: only send RPC if enough time has passed
    const now: i64 = @intCast(c.GetTickCount64());
    if (now - ext_win.scrollbar_last_update < app_mod.SCROLLBAR_THROTTLE_MS) return;
    ext_win.scrollbar_last_update = now;

    // Send scroll command to Neovim
    app_mod.zonvie_core_scroll_to_line(corep, target_line, use_bottom);

    ext_win.scrollbar_pending_line = -1;
}

/// Handle scrollbar mouse up for external window
pub fn scrollbarMouseUpForExternal(hwnd: c.HWND, app: *App, ext_win: *app_mod.ExternalWindow, _: i64) void {
    if (ext_win.scrollbar_dragging) {
        ext_win.scrollbar_dragging = false;
        _ = c.ReleaseCapture();

        // Flush any pending scroll on mouse up
        if (ext_win.scrollbar_pending_line >= 0) {
            if (app.corep) |corep| {
                app_mod.zonvie_core_scroll_to_line(corep, ext_win.scrollbar_pending_line, ext_win.scrollbar_pending_use_bottom);
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
pub fn updateScrollbarFadeForExternal(hwnd: c.HWND, _: *App, ext_win: *app_mod.ExternalWindow) void {
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
        _ = c.InvalidateRect(hwnd, null, 0);
    }

    // Check if we've reached target
    if (@abs(ext_win.scrollbar_alpha - ext_win.scrollbar_target_alpha) < 0.01) {
        ext_win.scrollbar_alpha = ext_win.scrollbar_target_alpha;
        _ = c.KillTimer(hwnd, app_mod.TIMER_SCROLLBAR_FADE);

        // Force full repaint when scrollbar hidden
        if (ext_win.scrollbar_alpha <= 0.0) {
            ext_win.scrollbar_visible = false;
            ext_win.needs_redraw = true;
            _ = c.InvalidateRect(hwnd, null, 0);
        }
    }
}

pub fn generateScrollbarVertices(app: *App, client_width: i32, client_height: i32, out_verts: *[12]app_mod.Vertex) usize {
    if (!app.config.scrollbar.enabled) return 0;
    if (app.scrollbar_alpha <= 0.001) return 0;

    const geom = getScrollbarGeometry(app, client_width, client_height);
    if (!geom.is_scrollable and !app.config.scrollbar.isAlways()) return 0;

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

    const alpha = app.scrollbar_alpha * app.config.scrollbar.opacity;

    // Track color: fully opaque in "always" mode to prevent ghosting, semi-transparent otherwise
    const is_always_mode = app.config.scrollbar.isAlways();
    const track_alpha: f32 = if (is_always_mode) 1.0 else alpha * 0.5;
    const track_color = [4]f32{ 0.2, 0.2, 0.2, track_alpha };
    // Knob color (light gray with alpha)
    const knob_color = [4]f32{ 0.7, 0.7, 0.7, alpha };

    // Track quad (background) - 6 vertices
    const tl = to_ndc_x(geom.track_left, cw);
    const tr = to_ndc_x(geom.track_right, cw);
    const tt = to_ndc_y(geom.track_top, ch);
    const tb = to_ndc_y(geom.track_bottom, ch);

    // Track Triangle 1
    out_verts[0] = .{ .position = .{ tl, tt }, .texCoord = .{ -1.0, 0 }, .color = track_color, .grid_id = 1, .deco_flags = 0, .deco_phase = 0 };
    out_verts[1] = .{ .position = .{ tr, tt }, .texCoord = .{ -1.0, 0 }, .color = track_color, .grid_id = 1, .deco_flags = 0, .deco_phase = 0 };
    out_verts[2] = .{ .position = .{ tl, tb }, .texCoord = .{ -1.0, 0 }, .color = track_color, .grid_id = 1, .deco_flags = 0, .deco_phase = 0 };

    // Track Triangle 2
    out_verts[3] = .{ .position = .{ tr, tt }, .texCoord = .{ -1.0, 0 }, .color = track_color, .grid_id = 1, .deco_flags = 0, .deco_phase = 0 };
    out_verts[4] = .{ .position = .{ tr, tb }, .texCoord = .{ -1.0, 0 }, .color = track_color, .grid_id = 1, .deco_flags = 0, .deco_phase = 0 };
    out_verts[5] = .{ .position = .{ tl, tb }, .texCoord = .{ -1.0, 0 }, .color = track_color, .grid_id = 1, .deco_flags = 0, .deco_phase = 0 };

    // Knob quad (2 triangles = 6 vertices)
    const kl = to_ndc_x(geom.track_left, cw);
    const kr = to_ndc_x(geom.track_right, cw);
    const kt = to_ndc_y(geom.knob_top, ch);
    const kb = to_ndc_y(geom.knob_bottom, ch);

    // Knob Triangle 1: top-left, top-right, bottom-left
    out_verts[6] = .{ .position = .{ kl, kt }, .texCoord = .{ -1.0, 0 }, .color = knob_color, .grid_id = 1, .deco_flags = 0, .deco_phase = 0 };
    out_verts[7] = .{ .position = .{ kr, kt }, .texCoord = .{ -1.0, 0 }, .color = knob_color, .grid_id = 1, .deco_flags = 0, .deco_phase = 0 };
    out_verts[8] = .{ .position = .{ kl, kb }, .texCoord = .{ -1.0, 0 }, .color = knob_color, .grid_id = 1, .deco_flags = 0, .deco_phase = 0 };

    // Knob Triangle 2: top-right, bottom-right, bottom-left
    out_verts[9] = .{ .position = .{ kr, kt }, .texCoord = .{ -1.0, 0 }, .color = knob_color, .grid_id = 1, .deco_flags = 0, .deco_phase = 0 };
    out_verts[10] = .{ .position = .{ kr, kb }, .texCoord = .{ -1.0, 0 }, .color = knob_color, .grid_id = 1, .deco_flags = 0, .deco_phase = 0 };
    out_verts[11] = .{ .position = .{ kl, kb }, .texCoord = .{ -1.0, 0 }, .color = knob_color, .grid_id = 1, .deco_flags = 0, .deco_phase = 0 };

    return 12; // 6 for track + 6 for knob
}

/// Hit test scrollbar area
pub fn scrollbarHitTest(app: *App, client_width: i32, client_height: i32, mouse_x: i32, mouse_y: i32) enum { none, knob, track_above, track_below } {
    if (!app.config.scrollbar.enabled) return .none;

    const geom = getScrollbarGeometry(app, client_width, client_height);
    if (!geom.is_scrollable) return .none;

    const mx: f32 = @floatFromInt(mouse_x);
    const my: f32 = @floatFromInt(mouse_y);

    // Check if in track area horizontally
    if (mx < geom.track_left or mx > geom.track_right) return .none;

    // Check vertical position
    if (my < geom.track_top or my > geom.track_bottom) return .none;

    if (my >= geom.knob_top and my <= geom.knob_bottom) {
        return .knob;
    } else if (my < geom.knob_top) {
        return .track_above;
    } else {
        return .track_below;
    }
}

/// Handle scrollbar mouse down
pub fn scrollbarMouseDown(hwnd: c.HWND, app: *App, mouse_x: i32, mouse_y: i32) bool {
    var client: c.RECT = undefined;
    _ = c.GetClientRect(hwnd, &client);

    const geom = getScrollbarGeometry(app, client.right, client.bottom);
    const hit = scrollbarHitTest(app, client.right, client.bottom, mouse_x, mouse_y);

    applog.appLog("[scrollbar] mouseDown x={d} y={d} client=({d},{d}) track=({d:.0},{d:.0})-({d:.0},{d:.0}) knob=({d:.0},{d:.0}) hit={s}\n", .{
        mouse_x, mouse_y, client.right, client.bottom,
        geom.track_left, geom.track_top, geom.track_right, geom.track_bottom,
        geom.knob_top, geom.knob_bottom,
        @tagName(hit),
    });

    const corep = app.corep orelse return false;

    switch (hit) {
        .knob => {
            // Start dragging
            app.scrollbar_dragging = true;
            app.scrollbar_drag_start_y = mouse_y;

            var vp: app_mod.ViewportInfo = undefined;
            if (app_mod.zonvie_core_get_viewport(corep, -1, &vp) != 0) {
                app.scrollbar_drag_start_topline = vp.topline;
            }

            _ = c.SetCapture(hwnd);
            return true;
        },
        .track_above => {
            // Page up - execute immediately and start repeat timer
            applog.appLog("[scrollbar] track_above: executing page scroll up\n", .{});
            scrollbarPageScroll(app, -1);
            app.scrollbar_repeat_dir = -1;
            _ = c.SetCapture(hwnd);
            app.scrollbar_repeat_timer = c.SetTimer(hwnd, app_mod.TIMER_SCROLLBAR_REPEAT, app_mod.SCROLLBAR_REPEAT_DELAY, null);
            showScrollbar(hwnd, app);
            return true;
        },
        .track_below => {
            // Page down - execute immediately and start repeat timer
            applog.appLog("[scrollbar] track_below: executing page scroll down\n", .{});
            scrollbarPageScroll(app, 1);
            app.scrollbar_repeat_dir = 1;
            _ = c.SetCapture(hwnd);
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
    if (app_mod.zonvie_core_get_viewport(corep, -1, &vp) == 0) return;

    const visible_lines = vp.botline - vp.topline;
    if (visible_lines <= 0) return;

    // Calculate knob travel range
    const track_height = geom.track_bottom - geom.track_top;
    const visible_f: f32 = @floatFromInt(visible_lines);
    const total_f: f32 = @floatFromInt(@max(1, vp.line_count));
    const knob_proportion = @min(1.0, visible_f / total_f);
    var knob_height = track_height * knob_proportion;
    knob_height = @max(app_mod.SCROLLBAR_MIN_KNOB_HEIGHT, knob_height);
    const knob_travel = track_height - knob_height;
    if (knob_travel <= 0) return;

    // Calculate target topline from mouse position relative to track
    // mouse_y relative to track top -> position in track
    const mouse_in_track: f32 = @as(f32, @floatFromInt(mouse_y)) - geom.track_top - knob_height / 2.0;
    const scroll_ratio = @max(0.0, @min(1.0, mouse_in_track / knob_travel));

    // scroll_range is max topline value (0-based: 0 to line_count - visible_lines)
    const scroll_range = @max(0, vp.line_count - visible_lines);
    const target_topline_0based: i64 = @intFromFloat(scroll_ratio * @as(f32, @floatFromInt(scroll_range)));

    // 1-based topline for Neovim
    const target_topline_1based: i64 = target_topline_0based + 1;

    // Determine scroll mode: top half uses zt (top), bottom half uses zb (bottom)
    // This allows scrolling to the very end of the file
    const use_bottom = scroll_ratio >= 0.5;
    const target_line: i64 = if (use_bottom) blk: {
        // For bottom mode, calculate the bottom line of the viewport
        const bottom_line = target_topline_1based + visible_lines - 1;
        // Clamp to line_count
        break :blk @min(bottom_line, vp.line_count);
    } else target_topline_1based;

    // Always store pending position
    app.scrollbar_pending_line = target_line;
    app.scrollbar_pending_use_bottom = use_bottom;

    // Throttle: only send RPC if enough time has passed
    const now: i64 = @intCast(c.GetTickCount64());
    const elapsed = now - app.scrollbar_last_scroll_time;

    if (elapsed >= app_mod.SCROLLBAR_THROTTLE_MS) {
        applog.appLog("[scrollbar] mouseMove y={d} ratio={d:.3} line={d} bottom={any} (sending)\n", .{
            mouse_y, scroll_ratio, target_line, use_bottom,
        });
        app_mod.zonvie_core_scroll_to_line(corep, target_line, use_bottom);
        app.scrollbar_last_scroll_time = now;
        app.scrollbar_pending_line = -1; // Clear pending
    }
}

/// Execute page scroll in given direction (-1 = up, 1 = down)
pub fn scrollbarPageScroll(app: *App, direction: i8) void {
    const corep = app.corep orelse {
        applog.appLog("[scrollbar] scrollbarPageScroll: corep is null\n", .{});
        return;
    };

    var vp: app_mod.ViewportInfo = undefined;
    if (app_mod.zonvie_core_get_viewport(corep, -1, &vp) == 0) {
        applog.appLog("[scrollbar] scrollbarPageScroll: get_viewport failed\n", .{});
        return;
    }

    const visible_lines = vp.botline - vp.topline;
    // Scroll by one page (visible_lines - 2 for overlap)
    const page_size = @max(1, visible_lines - 2);

    applog.appLog("[scrollbar] scrollbarPageScroll: direction={d} visible={d} page_size={d} topline={d} botline={d} line_count={d}\n", .{
        direction, visible_lines, page_size, vp.topline, vp.botline, vp.line_count,
    });

    if (direction < 0) {
        // Page up: scroll to topline - page_size
        const new_topline = @max(1, vp.topline - page_size + 1);
        app_mod.zonvie_core_scroll_to_line(corep, new_topline, false);
    } else {
        // Page down: scroll to topline + page_size
        const new_topline = @min(vp.line_count - visible_lines + 1, vp.topline + page_size + 1);
        const target_line = @max(1, new_topline);
        app_mod.zonvie_core_scroll_to_line(corep, target_line, false);
    }
}

/// Handle scrollbar mouse up
pub fn scrollbarMouseUp(hwnd: c.HWND, app: *App) void {
    if (app.scrollbar_dragging) {
        // Send any pending scroll position before releasing
        if (app.scrollbar_pending_line > 0) {
            if (app.corep) |corep| {
                applog.appLog("[scrollbar] mouseUp sending pending line={d} bottom={any}\n", .{ app.scrollbar_pending_line, app.scrollbar_pending_use_bottom });
                app_mod.zonvie_core_scroll_to_line(corep, app.scrollbar_pending_line, app.scrollbar_pending_use_bottom);
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

    // Get current viewport info
    var vp: app_mod.ViewportInfo = undefined;
    if (app_mod.zonvie_core_get_viewport(corep, -1, &vp) == 0) return;

    // Check if viewport changed
    const viewport_changed = vp.topline != app.last_viewport_topline or
        vp.line_count != app.last_viewport_line_count or
        vp.botline != app.last_viewport_botline or
        app.last_viewport_topline == -1;

    if (!viewport_changed) return;

    app.last_viewport_topline = vp.topline;
    app.last_viewport_line_count = vp.line_count;
    app.last_viewport_botline = vp.botline;

    const visible_lines = vp.botline - vp.topline;
    const is_scrollable = vp.line_count > visible_lines;

    if (!is_scrollable and !app.config.scrollbar.isAlways()) {
        hideScrollbar(hwnd, app);
        return;
    }

    // Show scrollbar based on mode
    if (app.config.scrollbar.isScroll() or app.config.scrollbar.isAlways()) {
        showScrollbar(hwnd, app);
    }

    // Request repaint for scrollbar area
    _ = c.InvalidateRect(hwnd, null, c.FALSE);
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
            // Force full repaint to clear the scrollbar area from the back buffer.
            // This is necessary because the scrollbar may overlap the gutter area
            // (outside the grid), which is not redrawn by row updates.
            app.need_full_seed.store(true, .seq_cst);
        }
    }

    // Request repaint
    _ = c.InvalidateRect(hwnd, null, c.FALSE);
}
