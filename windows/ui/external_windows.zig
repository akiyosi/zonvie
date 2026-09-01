const std = @import("std");
const app_mod = @import("../app.zig");
const App = app_mod.App;
const c = app_mod.c;
const applog = app_mod.applog;
const d3d11 = app_mod.d3d11;
const dwrite_d2d = app_mod.dwrite_d2d;
const scrollbar = @import("scrollbar.zig");
const input = @import("../input.zig");
const messages = @import("messages.zig");
const dialogs = @import("dialogs.zig");
const drop_target = @import("drop_target.zig");
const window_mod = @import("../window.zig");
const render_pipeline_helpers = @import("../render_pipeline_helpers.zig");
const msg_float_layout = @import("msg_float_layout.zig");
const core = @import("zonvie_core");

const ExternalSurfaceKind = enum {
    normal,
    cmdline,
    popupmenu,
    msg_show,
    msg_history,
};

fn externalWakeState(hwnd: c.HWND) usize {
    return @bitCast(c.GetWindowLongPtrW(hwnd, window_mod.WINDOW_WAKE_STATE_OFFSET));
}

fn externalWakeCookie(hwnd: c.HWND) usize {
    return window_mod.windowWakeCookie(hwnd);
}

fn classifyExternalSurface(grid_id: i64) ExternalSurfaceKind {
    return switch (grid_id) {
        app_mod.CMDLINE_GRID_ID => .cmdline,
        app_mod.POPUPMENU_GRID_ID => .popupmenu,
        app_mod.MESSAGE_GRID_ID => .msg_show,
        app_mod.MSG_HISTORY_GRID_ID => .msg_history,
        else => .normal,
    };
}

/// Report pointer enter/exit on a message surface so the core holds the view's
/// auto-hide countdown while the user reads it or reaches for the copy button.
/// Only transitions are posted, so an ordinary mouse move over the surface
/// costs nothing.
fn setMsgHover(app: *App, ext_win: *app_mod.ExternalWindow, grid_id: i64, hovered: bool) void {
    switch (classifyExternalSurface(grid_id)) {
        .msg_show, .msg_history => {},
        else => return,
    }
    if (ext_win.msg_hover == hovered) return;
    const hwnd = app.hwnd orelse return;
    const wparam: c.WPARAM = if (hovered) 1 else 0;
    if (c.PostMessageW(hwnd, app_mod.WM_APP_MSG_HOVER, wparam, @intCast(grid_id)) == 0) return;
    ext_win.msg_hover = hovered;
}

/// Client-pixel padding a decorated external surface adds around its grid:
/// the cmdline's icon strip and padding, a message surface's padding, and the
/// copy-content button's trailing reservation.
///
/// Every site that sizes an external window must go through this. The two
/// resize paths in callbacks.zig used to re-derive the first two terms and
/// omit the third, so a guifont or linespace change while a cmdline or
/// message window was open sent it back one copy-button width too narrow.
pub const ExternalSurfaceInsets = struct { w: c_int, h: c_int };

pub fn externalSurfaceInsetsPx(app: *App, grid_id: i64) ExternalSurfaceInsets {
    const kind = classifyExternalSurface(grid_id);
    const is_cmdline = kind == .cmdline;
    const is_msg = kind == .msg_show or kind == .msg_history;

    const cmdline_icon_w: c_int = if (is_cmdline) @intCast(app_mod.CMDLINE_ICON_MARGIN_LEFT +
        app_mod.CMDLINE_ICON_SIZE + app_mod.CMDLINE_ICON_MARGIN_RIGHT) else 0;
    const cmdline_padding: c_int = if (is_cmdline) @intCast(app_mod.CMDLINE_PADDING * 2) else 0;
    const msg_padding: c_int = if (is_msg) app.scalePx(@as(c_int, app_mod.MSG_PADDING)) * 2 else 0;

    return .{
        .w = cmdline_icon_w + cmdline_padding + msg_padding + copyButtonReservedPx(app, kind),
        .h = cmdline_padding + msg_padding,
    };
}

/// The cmdline may not grow past the work area of the monitor the main window
/// is on. Other surfaces are returned unchanged.
pub fn clampCmdlineWidthToWorkArea(app: *App, grid_id: i64, client_w: c_int) c_int {
    if (classifyExternalSurface(grid_id) != .cmdline) return client_w;
    const main_hwnd = app.hwnd orelse return client_w;
    const monitor = c.MonitorFromWindow(main_hwnd, c.MONITOR_DEFAULTTONEAREST) orelse return client_w;
    var mi: c.MONITORINFO = std.mem.zeroes(c.MONITORINFO);
    mi.cbSize = @sizeOf(c.MONITORINFO);
    if (c.GetMonitorInfoW(monitor, &mi) == 0) return client_w;
    return @min(client_w, mi.rcWork.right - mi.rcWork.left - @as(c_int, @intCast(app_mod.CMDLINE_SCREEN_MARGIN)));
}

/// Find the external window a message was delivered to. Caller must already
/// hold app.mu -- this deliberately does not take it, because several window
/// procedure arms keep the lock past the lookup to read further App state.
///
/// Eight arms of ExternalWndProc walked the map inline with the same
/// predicate. The WM_DPICHANGED arm does not use this: it does its work
/// inside the loop rather than extracting a match.
const ExtWindowHit = struct { grid_id: i64, win: *app_mod.ExternalWindow };

fn findExternalWindowByHwndLocked(app: *App, hwnd: c.HWND) ?ExtWindowHit {
    var it = app.external_windows.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.*.hwnd == hwnd) {
            return .{ .grid_id = entry.key_ptr.*, .win = entry.value_ptr.* };
        }
    }
    return null;
}

/// Append the four edge rects that frame a decorated surface, in NDC. The
/// cmdline and the popupmenu drew this identically; the border width is the
/// same constant for both.
///
/// Returns the vertex index past the last one written.
fn appendDecoratedBorderVerts(
    verts: []app_mod.Vertex,
    start_idx: usize,
    window_w: f32,
    window_h: f32,
    border_color: [4]f32,
    grid_id: i64,
) usize {
    const w_ndc: f32 = @as(f32, @floatFromInt(app_mod.CMDLINE_BORDER_WIDTH)) / (window_w / 2.0);
    const h_ndc: f32 = @as(f32, @floatFromInt(app_mod.CMDLINE_BORDER_WIDTH)) / (window_h / 2.0);
    const tex: [2]f32 = .{ -1.0, -1.0 };
    var idx = start_idx;
    // top, bottom, left, right
    idx = app_mod.addRectVerts(verts, idx, -1.0, 1.0, 2.0, h_ndc, border_color, tex, grid_id);
    idx = app_mod.addRectVerts(verts, idx, -1.0, -1.0 + h_ndc, 2.0, h_ndc, border_color, tex, grid_id);
    idx = app_mod.addRectVerts(verts, idx, -1.0, 1.0 - h_ndc, w_ndc, 2.0 - 2.0 * h_ndc, border_color, tex, grid_id);
    idx = app_mod.addRectVerts(verts, idx, 1.0 - w_ndc, 1.0 - h_ndc, w_ndc, 2.0 - 2.0 * h_ndc, border_color, tex, grid_id);
    return idx;
}

/// The background colour a decorated surface should paint, taken from the
/// first background quad the core sent. Both decorated draw paths -- the
/// cmdline and the message surfaces -- resolved it this way.
///
/// A frame with no background quad at all reuses the last one seen for this
/// grid; without that a transient all-glyph frame would flash the wrong
/// colour. A frame that has one refreshes the cache.
///
/// `orig` is what the core sent, which the caller needs to recognise which
/// vertices to make transparent; `adjusted` is what it should paint.
const DecoratedBgColor = struct { orig: [3]f32, adjusted: [3]f32 };

fn resolveDecoratedBgColor(app: *App, grid_id: i64, verts: []const app_mod.Vertex) DecoratedBgColor {
    var orig: [3]f32 = .{ 0.0, 0.0, 0.0 };
    var found = false;
    for (verts) |v| {
        if (v.texCoord[0] < 0) {
            orig = .{ v.color[0], v.color[1], v.color[2] };
            found = true;
            break;
        }
    }

    app.mu.lockUncancelable(core.clock.io());
    if (app.external_windows.get(grid_id)) |ew| {
        if (found) {
            ew.cached_bg_color = orig;
        } else if (ew.cached_bg_color) |cached| {
            orig = cached;
        }
    }
    app.mu.unlock(core.clock.io());

    return .{ .orig = orig, .adjusted = app_mod.adjustBrightnessForCmdline(orig[0], orig[1], orig[2]) };
}

/// Whether the decorated surface of `kind` shows a copy-content button.
fn copyButtonEnabled(app: *App, kind: ExternalSurfaceKind) bool {
    return switch (kind) {
        .cmdline => app.config.cmdline.copy_button,
        .msg_show, .msg_history => app.config.messages.copy_button,
        .popupmenu, .normal => false,
    };
}

/// Width the copy-content button reserves on the trailing edge, in client
/// pixels. Zero when the surface has no button.
fn copyButtonReservedPx(app: *App, kind: ExternalSurfaceKind) c_int {
    if (!copyButtonEnabled(app, kind)) return 0;
    return app.scalePx(@as(c_int, app_mod.COPY_BUTTON_MARGIN_LEFT +
        app_mod.COPY_BUTTON_SIZE + app_mod.COPY_BUTTON_MARGIN_RIGHT));
}

/// Copy-button box in client pixels, or null when the surface has no button.
/// The cmdline is a single row so its button is centred vertically; the
/// multi-row message surfaces pin it near the top instead.
fn copyButtonRectPx(app: *App, kind: ExternalSurfaceKind, client_w: c_int, client_h: c_int) ?c.RECT {
    if (!copyButtonEnabled(app, kind)) return null;
    const size = app.scalePx(@as(c_int, app_mod.COPY_BUTTON_SIZE));
    const margin_right = app.scalePx(@as(c_int, app_mod.COPY_BUTTON_MARGIN_RIGHT));
    if (client_w <= size + margin_right or client_h < size) return null;

    const left = client_w - size - margin_right;
    const centred_top = @divTrunc(client_h - size, 2);
    const top = if (kind == .cmdline) centred_top else @min(margin_right, centred_top);
    return .{ .left = left, .top = top, .right = left + size, .bottom = top + size };
}

/// True when (x, y) in client coordinates falls on the copy-content button.
fn hitTestCopyButton(hwnd: c.HWND, app: *App, grid_id: i64, x: i32, y: i32) bool {
    var client: c.RECT = undefined;
    if (c.GetClientRect(hwnd, &client) == 0) return false;
    const rect = copyButtonRectPx(
        app,
        classifyExternalSurface(grid_id),
        client.right,
        client.bottom,
    ) orelse return false;
    return x >= rect.left and x < rect.right and y >= rect.top and y < rect.bottom;
}

/// Copy a decorated surface's rendered text to the clipboard.
///
/// The text comes straight from the core's grid, so what lands on the
/// clipboard is exactly what the surface displays. The core holds its grid
/// lock for the whole of handleRedraw, so the read is a try-lock and a
/// contended click is simply dropped rather than stalling the UI thread.
fn copyExternalSurfaceText(hwnd: c.HWND, app: *App, grid_id: i64) void {
    // Sized for a cmdline / notification; a longer :messages history falls
    // back to a heap buffer of the exact size the core reports.
    var stack_buf: [4096]u8 = undefined;
    const needed = core.zonvie_core_try_get_grid_text(app.corep, grid_id, &stack_buf, stack_buf.len);
    if (needed < 0) {
        if (applog.isEnabled()) applog.appLog("[win] copy_button: grid lock unavailable grid_id={d}\n", .{grid_id});
        return;
    }
    if (needed == 0) return;

    const len: usize = @intCast(needed);
    if (len <= stack_buf.len) {
        _ = dialogs.setClipboardTextUtf8(hwnd, stack_buf[0..len]);
        return;
    }

    const heap_buf = app.alloc.alloc(u8, len) catch {
        if (applog.isEnabled()) applog.appLog("[win] copy_button: allocation failed len={d}\n", .{len});
        return;
    };
    defer app.alloc.free(heap_buf);
    const second = core.zonvie_core_try_get_grid_text(app.corep, grid_id, heap_buf.ptr, heap_buf.len);
    if (second <= 0) return;
    _ = dialogs.setClipboardTextUtf8(hwnd, heap_buf[0..@min(len, @as(usize, @intCast(second)))]);
}

/// Append the copy-content icon at the surface's trailing edge. Returns the
/// new vertex index, unchanged when the surface has no button. Reserve
/// app_mod.COPY_ICON_VERTS in the scratch buffer before calling.
fn appendCopyIconVerts(
    app: *App,
    kind: ExternalSurfaceKind,
    grid_id: i64,
    verts: []app_mod.Vertex,
    idx: usize,
    window_w: f32,
    window_h: f32,
    color: [4]f32,
    hovered: bool,
) usize {
    const rect = copyButtonRectPx(
        app,
        kind,
        @intFromFloat(window_w),
        @intFromFloat(window_h),
    ) orelse return idx;

    const half_w = window_w / 2.0;
    const half_h = window_h / 2.0;
    const x_ndc: f32 = @as(f32, @floatFromInt(rect.left)) / half_w - 1.0;
    const y_ndc: f32 = 1.0 - @as(f32, @floatFromInt(rect.top)) / half_h;
    const w_ndc: f32 = @as(f32, @floatFromInt(rect.right - rect.left)) / half_w;
    const h_ndc: f32 = @as(f32, @floatFromInt(rect.bottom - rect.top)) / half_h;

    var next = idx;
    if (hovered) {
        // Wash behind the icon, keyed off the icon colour so it stays visible
        // on both dark and light colorschemes (mirrors CopyContentButton's
        // hoverBackgroundColor on macOS).
        const wash: [4]f32 = .{ color[0], color[1], color[2], 0.22 };
        next = app_mod.addRoundFillVerts(verts, next, x_ndc, y_ndc, w_ndc, h_ndc, wash, grid_id);
    }
    return app_mod.addCopyIconVerts(verts, next, x_ndc, y_ndc, w_ndc, h_ndc, color, grid_id);
}

fn drawDecoratedExternalSurface(
    kind: ExternalSurfaceKind,
    g: *d3d11.Renderer,
    app: *App,
    grid_id: i64,
    verts: []const app_mod.Vertex,
    vert_count: usize,
    cmdline_firstc: u8,
    scratch: *std.ArrayListUnmanaged(app_mod.Vertex),
    glow_enabled: bool,
    glow_intensity: f32,
) !void {
    switch (kind) {
        .cmdline => {
            const window_w: f32 = @floatFromInt(g.width);
            const window_h: f32 = @floatFromInt(g.height);

            app.mu.lockUncancelable(core.clock.io());
            const ext_win_relookup = app.external_windows.get(grid_id);
            const content_rows = if (ext_win_relookup) |ew| ew.surface.rows else 0;
            const content_cols = if (ext_win_relookup) |ew| ew.surface.cols else 0;
            const copy_hover = if (ext_win_relookup) |ew| ew.copy_button_hover else false;
            const cell_w = app.cell_w_px;
            const cell_h = app.rowHeightPx();
            const hide_cursor_for_ime = app.ime_composing;
            const border_r = app.cmdline_border_color[0];
            const border_g = app.cmdline_border_color[1];
            const border_b = app.cmdline_border_color[2];
            const icon_r = app.cmdline_icon_color[0];
            const icon_g = app.cmdline_icon_color[1];
            const icon_b = app.cmdline_icon_color[2];
            app.mu.unlock(core.clock.io());

            if (content_rows == 0 or content_cols == 0) return;

            const content_w: f32 = @floatFromInt(content_cols * cell_w);
            const content_h: f32 = @floatFromInt(content_rows * cell_h);
            if (!(window_w > 0 and window_h > 0 and content_w > 0 and content_h > 0)) {
                try g.draw(verts[0..vert_count], &[_]app_mod.Vertex{}, null);
                return;
            }

            const content_left: f32 = @floatFromInt(app_mod.CMDLINE_PADDING + app_mod.CMDLINE_ICON_MARGIN_LEFT + app_mod.CMDLINE_ICON_SIZE + app_mod.CMDLINE_ICON_MARGIN_RIGHT);
            const content_top: f32 = @floatFromInt(app_mod.CMDLINE_PADDING);
            const left_ndc: f32 = content_left / window_w * 2.0 - 1.0;
            const right_ndc: f32 = (content_left + content_w) / window_w * 2.0 - 1.0;
            const top_ndc: f32 = 1.0 - content_top / window_h * 2.0;
            const bottom_ndc: f32 = 1.0 - (content_top + content_h) / window_h * 2.0;
            const scale_x: f32 = (right_ndc - left_ndc) / 2.0;
            const scale_y: f32 = (top_ndc - bottom_ndc) / 2.0;
            const offset_x: f32 = (right_ndc + left_ndc) / 2.0;
            const offset_y: f32 = (top_ndc + bottom_ndc) / 2.0;

            const extra_verts = 6 + 24 + 20 + app_mod.COPY_ICON_VERTS;
            scratch.clearRetainingCapacity();
            try scratch.resize(app.alloc, vert_count + extra_verts);
            const cmdline_verts = scratch.items;

            const bg = resolveDecoratedBgColor(app, grid_id, verts[0..vert_count]);
            const orig_bg_r = bg.orig[0];
            const orig_bg_g = bg.orig[1];
            const orig_bg_b = bg.orig[2];
            const bg_color: [4]f32 = .{ bg.adjusted[0], bg.adjusted[1], bg.adjusted[2], app.config.window.opacity };
            const bg_tex: [2]f32 = .{ -1.0, -1.0 };
            var bg_idx: usize = 0;
            bg_idx = app_mod.addRectVerts(cmdline_verts, bg_idx, -1.0, 1.0, 2.0, 2.0, bg_color, bg_tex, grid_id);

            const tolerance: f32 = 0.005;
            for (verts[0..vert_count], 0..) |v, i| {
                const dest_idx = bg_idx + i;
                cmdline_verts[dest_idx] = v;
                cmdline_verts[dest_idx].position[0] = v.position[0] * scale_x + offset_x;
                cmdline_verts[dest_idx].position[1] = v.position[1] * scale_y + offset_y;
                if ((v.deco_flags & core.DECO_CURSOR) != 0) {
                    if (hide_cursor_for_ime) cmdline_verts[dest_idx].color[3] = 0.0;
                    continue;
                }
                if (v.texCoord[0] < 0) {
                    const matches_bg = @abs(v.color[0] - orig_bg_r) < tolerance and
                        @abs(v.color[1] - orig_bg_g) < tolerance and
                        @abs(v.color[2] - orig_bg_b) < tolerance;
                    if (matches_bg) cmdline_verts[dest_idx].color[3] = 0.0;
                }
            }

            var extra_idx: usize = bg_idx + vert_count;
            extra_idx = appendDecoratedBorderVerts(cmdline_verts, extra_idx, window_w, window_h, .{ border_r, border_g, border_b, 1.0 }, grid_id);

            const icon_color: [4]f32 = .{ icon_r, icon_g, icon_b, 1.0 };
            const icon_x_px: f32 = @floatFromInt(app_mod.CMDLINE_PADDING + app_mod.CMDLINE_ICON_MARGIN_LEFT);
            const icon_y_px: f32 = (window_h - @as(f32, @floatFromInt(app_mod.CMDLINE_ICON_SIZE))) / 2.0;
            const icon_size_px: f32 = @floatFromInt(app_mod.CMDLINE_ICON_SIZE);
            const icon_x_ndc: f32 = icon_x_px / (window_w / 2.0) - 1.0;
            const icon_y_ndc: f32 = 1.0 - icon_y_px / (window_h / 2.0);
            const icon_w_ndc: f32 = icon_size_px / (window_w / 2.0);
            const icon_h_ndc: f32 = icon_size_px / (window_h / 2.0);
            if (cmdline_firstc == '/' or cmdline_firstc == '?') {
                extra_idx = app_mod.addSearchIconVerts(cmdline_verts, extra_idx, icon_x_ndc, icon_y_ndc, icon_w_ndc, icon_h_ndc, icon_color, grid_id);
            } else {
                extra_idx = app_mod.addChevronIconVerts(cmdline_verts, extra_idx, icon_x_ndc, icon_y_ndc, icon_w_ndc, icon_h_ndc, icon_color, grid_id);
            }

            extra_idx = appendCopyIconVerts(app, kind, grid_id, cmdline_verts, extra_idx, window_w, window_h, icon_color, copy_hover);

            try g.draw(cmdline_verts[0..extra_idx], &[_]app_mod.Vertex{}, null);
            if (glow_enabled) {
                g.drawBloomFromVerts(cmdline_verts[0..extra_idx], &[_]app_mod.Vertex{}, glow_intensity, 0, 0, g.width, g.height);
            }
        },
        .popupmenu => {
            const window_w: f32 = @floatFromInt(g.width);
            const window_h: f32 = @floatFromInt(g.height);
            if (!(window_w > 0 and window_h > 0)) {
                try g.draw(verts[0..vert_count], &[_]app_mod.Vertex{}, null);
                return;
            }

            const extra_verts = 24;
            scratch.clearRetainingCapacity();
            try scratch.resize(app.alloc, vert_count + extra_verts);
            const pum_verts = scratch.items;
            @memcpy(pum_verts[0..vert_count], verts[0..vert_count]);

            app.mu.lockUncancelable(core.clock.io());
            const border_r = app.cmdline_border_color[0];
            const border_g = app.cmdline_border_color[1];
            const border_b = app.cmdline_border_color[2];
            app.mu.unlock(core.clock.io());

            var extra_idx: usize = vert_count;
            extra_idx = appendDecoratedBorderVerts(pum_verts, extra_idx, window_w, window_h, .{ border_r, border_g, border_b, 1.0 }, grid_id);

            try g.draw(pum_verts[0..extra_idx], &[_]app_mod.Vertex{}, null);
            if (glow_enabled) {
                g.drawBloomFromVerts(pum_verts[0..extra_idx], &[_]app_mod.Vertex{}, glow_intensity, 0, 0, g.width, g.height);
            }
        },
        .msg_show, .msg_history => {
            const window_w: f32 = @floatFromInt(g.width);
            const window_h: f32 = @floatFromInt(g.height);

            app.mu.lockUncancelable(core.clock.io());
            const ext_win_relookup2 = app.external_windows.get(grid_id);
            const content_rows = if (ext_win_relookup2) |ew| ew.surface.rows else 0;
            const content_cols = if (ext_win_relookup2) |ew| ew.surface.cols else 0;
            const copy_hover = if (ext_win_relookup2) |ew| ew.copy_button_hover else false;
            const cell_w = app.cell_w_px;
            const cell_h = app.rowHeightPx();
            const icon_color: [4]f32 = .{
                app.cmdline_icon_color[0],
                app.cmdline_icon_color[1],
                app.cmdline_icon_color[2],
                1.0,
            };
            app.mu.unlock(core.clock.io());
            if (content_rows == 0 or content_cols == 0) return;

            const content_w: f32 = @floatFromInt(content_cols * cell_w);
            const content_h: f32 = @floatFromInt(content_rows * cell_h);
            if (!(window_w > 0 and window_h > 0 and content_w > 0 and content_h > 0)) {
                try g.draw(verts[0..vert_count], &[_]app_mod.Vertex{}, null);
                return;
            }

            const content_left: f32 = @floatFromInt(app.scalePx(@as(c_int, app_mod.MSG_PADDING)));
            const content_top: f32 = @floatFromInt(app.scalePx(@as(c_int, app_mod.MSG_PADDING)));
            const left_ndc: f32 = content_left / window_w * 2.0 - 1.0;
            const right_ndc: f32 = (content_left + content_w) / window_w * 2.0 - 1.0;
            const top_ndc: f32 = 1.0 - content_top / window_h * 2.0;
            const bottom_ndc: f32 = 1.0 - (content_top + content_h) / window_h * 2.0;
            const scale_x: f32 = (right_ndc - left_ndc) / 2.0;
            const scale_y: f32 = (top_ndc - bottom_ndc) / 2.0;
            const offset_x: f32 = (right_ndc + left_ndc) / 2.0;
            const offset_y: f32 = (top_ndc + bottom_ndc) / 2.0;

            scratch.clearRetainingCapacity();
            try scratch.resize(app.alloc, vert_count + 6 + app_mod.COPY_ICON_VERTS);
            const msg_verts = scratch.items;

            const bg = resolveDecoratedBgColor(app, grid_id, verts[0..vert_count]);
            const orig_bg_r = bg.orig[0];
            const orig_bg_g = bg.orig[1];
            const orig_bg_b = bg.orig[2];
            const bg_color: [4]f32 = .{ bg.adjusted[0], bg.adjusted[1], bg.adjusted[2], app.config.window.opacity };
            const bg_tex: [2]f32 = .{ -1.0, -1.0 };
            var bg_idx: usize = 0;
            bg_idx = app_mod.addRectVerts(msg_verts, bg_idx, -1.0, 1.0, 2.0, 2.0, bg_color, bg_tex, grid_id);

            const tolerance: f32 = 0.005;
            for (verts[0..vert_count], 0..) |v, i| {
                msg_verts[bg_idx + i] = v;
                msg_verts[bg_idx + i].position[0] = v.position[0] * scale_x + offset_x;
                msg_verts[bg_idx + i].position[1] = v.position[1] * scale_y + offset_y;
                if ((v.deco_flags & core.DECO_CURSOR) != 0) continue;
                if (v.texCoord[0] < 0) {
                    const matches_bg = @abs(v.color[0] - orig_bg_r) < tolerance and
                        @abs(v.color[1] - orig_bg_g) < tolerance and
                        @abs(v.color[2] - orig_bg_b) < tolerance;
                    if (matches_bg) msg_verts[bg_idx + i].color[3] = 0.0;
                }
            }

            const msg_total = appendCopyIconVerts(
                app,
                kind,
                grid_id,
                msg_verts,
                bg_idx + vert_count,
                window_w,
                window_h,
                icon_color,
                copy_hover,
            );
            try g.draw(msg_verts[0..msg_total], &[_]app_mod.Vertex{}, null);
            if (glow_enabled) {
                g.drawBloomFromVerts(msg_verts[0..msg_total], &[_]app_mod.Vertex{}, glow_intensity, 0, 0, g.width, g.height);
            }
        },
        .normal => unreachable,
    }
}

fn drawNormalExternalSurface(
    g: *d3d11.Renderer,
    app: *App,
    ext_win: *app_mod.ExternalWindow,
    tbs_committed: *const app_mod.VertexSet,
    tbs_cursor: *const app_mod.CursorSet,
    grid_id: i64,
    verts: []const app_mod.Vertex,
    vert_count: usize,
    cursor_blink_visible: bool,
    scrollbar_alpha: f32,
    dirty_row_keys: []u32,
    force_full: bool,
    glow_enabled: bool,
    glow_intensity: f32,
    tbs_snap: app_mod.PaintSnapshot,
    row_h_px_snapshot: u32,
) !bool {
    const log_enabled = applog.isEnabled();
    ext_win.paint_present_rects.clearRetainingCapacity();

    // All normal modes share the same retained back_tex. Restore a prior
    // row/flat scrollbar before either path mutates or clears it.
    const restored_scrollbar_rect = try g.restoreScrollbarUnderlay();

    // Row-mode path: use per-row VB rendering with scissor (same as main window).
    if (tbs_committed.row_mode) {
        return try drawNormalExternalSurfaceRowMode(
            g,
            app,
            ext_win,
            tbs_committed,
            tbs_cursor,
            grid_id,
            cursor_blink_visible,
            scrollbar_alpha,
            dirty_row_keys,
            force_full,
            glow_enabled,
            glow_intensity,
            tbs_snap,
            row_h_px_snapshot,
            restored_scrollbar_rect,
        );
    }

    // Flat-mode fallback: snapshot-based flat draw (decorated surfaces or non-row-mode).
    _ = app_mod.resizeRowVBsForPaint(
        app.alloc,
        &ext_win.row_vbs,
        &app.row_vb_budget,
        &ext_win.row_vb_retained_bytes,
        0,
    );
    if (log_enabled) applog.appLog("[win] drawNormalExternalSurface: flat mode grid_id={d}\n", .{grid_id});

    try app_mod.drawExternalSurfaceFlat(
        g,
        &ext_win.flat_draw_scratch,
        app.alloc,
        verts,
        vert_count,
        cursor_blink_visible,
        &[_]app_mod.Vertex{},
        glow_enabled,
        glow_intensity,
    );

    // Keep the alpha overlay out of the full-content draw so flat↔row mode
    // transitions use the same clean-underlay contract.
    if (app.config.scrollbar.enabled and scrollbar_alpha > 0.001) {
        var scrollbar_verts: [12]app_mod.Vertex = undefined;
        const scrollbar_vert_count = scrollbar.generateScrollbarVerticesForExternal(
            app,
            scrollbar_alpha,
            grid_id,
            @intCast(g.width),
            @intCast(g.height),
            &scrollbar_verts,
            ext_win.dpi_scale,
        );
        if (scrollbar_vert_count != 0) {
            if (scrollbar.getScrollbarTrackRectForExternal(@intCast(g.width), @intCast(g.height), ext_win.dpi_scale)) |track_rect| {
                if (try g.captureScrollbarUnderlay(track_rect)) |_| {
                    try app_mod.drawScrollbarOverlay(g, &ext_win.scrollbar_vb, &ext_win.scrollbar_vb_bytes, scrollbar_verts[0..scrollbar_vert_count]);
                }
            }
        }
    }
    // Flat drawEx redraws/clears the complete retained back texture.
    return true;
}

/// Row-mode VB rendering for normal external windows.
/// Uses TBS committed set + drawRowModeSetupAndRowsFromSlots for lock-free rendering.
/// Then handles cursor overlay, scrollbar overlay, and bloom post-process.
fn drawNormalExternalSurfaceRowMode(
    g: *d3d11.Renderer,
    app: *App,
    ext_win: *app_mod.ExternalWindow,
    tbs_committed: *const app_mod.VertexSet,
    tbs_cursor: *const app_mod.CursorSet,
    grid_id: i64,
    cursor_blink_visible: bool,
    scrollbar_alpha: f32,
    dirty_row_keys: []u32,
    force_full: bool,
    glow_enabled: bool,
    glow_intensity: f32,
    tbs_snap: app_mod.PaintSnapshot,
    row_h_px_snapshot: u32,
    restored_scrollbar_rect: ?c.RECT,
) !bool {
    const log_enabled = applog.isEnabled();
    const fallback_row_h = row_h_px_snapshot;
    const row_h_px: i32 = @intCast(fallback_row_h);
    const content_right: i32 = @intCast(g.width);

    // back_tex is persistent, so we only need to redraw dirty rows. Present
    // queues the resulting damage for every FLIP_SEQUENTIAL buffer; each
    // rotating buffer catches up from back_tex when it next becomes current.
    // Transparency mode (opacity < 1.0) must also force full rows:
    // premultiplied alpha blending accumulates alpha on redrawn rows
    // unless back_tex is cleared first, which requires force_full to
    // set preserve_back=false → should_clear=true in drawEx.
    const force_full_rows = force_full or
        glow_enabled or
        (g.opacity < 1.0);

    // Build sorted, deduplicated rows_to_draw list in per-window scratch.
    const rows_to_draw = &ext_win.paint_rows_to_draw;

    const ext_rows = tbs_committed.rows;
    if (!app_mod.computeRowsToDraw(
        app.alloc,
        rows_to_draw,
        force_full_rows,
        dirty_row_keys,
        ext_rows,
        ext_rows, // max_valid_row = total rows (no row_verts_len / rows mismatch on ext)
    )) return error.OutOfMemory;

    const has_cursor = tbs_cursor.verts.items.len > 0;
    const has_scrollbar_work = scrollbar_alpha > 0.001 or
        restored_scrollbar_rect != null or
        g.hasScrollbarUnderlay();
    if (rows_to_draw.items.len == 0 and !force_full_rows and !has_cursor and !has_scrollbar_work) {
        if (log_enabled) applog.appLog("[win] drawNormalExtRowMode: no dirty rows and no cursor, skip grid_id={d}\n", .{grid_id});
        ext_win.paint_present_rects.clearRetainingCapacity();
        return false;
    }

    const cursor_row_before = ext_win.last_painted_cursor_row;
    var scroll_damage: ?c.RECT = null;

    const draw_params = app_mod.RowModeDrawParams{
        .content_height = app_mod.snappedContentHeight(g.height, fallback_row_h, 0),
        .row_h_px = row_h_px,
        .content_right = content_right,
        .preserve_back = !force_full_rows,
    };

    // Ensure row_vbs array covers committed set's row count.
    {
        const need_len: usize = @intCast(tbs_committed.rows);
        if (!app_mod.resizeRowVBsForPaint(
            app.alloc,
            &ext_win.row_vbs,
            &app.row_vb_budget,
            &ext_win.row_vb_retained_bytes,
            need_len,
        ))
            return error.OutOfMemory;
    }

    // Apply scroll pixel shift (shared with main window).
    // Scroll state is bundled in tbs_snap, atomically consistent with committed set.
    if (!force_full_rows) {
        if (tbs_snap.scroll_rect) |sr| {
            const shift_result = app_mod.applyScrollShift(
                g,
                app.alloc,
                ext_win.row_vbs.items,
                &ext_win.row_vbs_shift_scratch,
                rows_to_draw,
                &ext_win.scroll_rows_merge_scratch,
                sr,
                tbs_snap.scroll_dy_px,
                tbs_snap.vb_shift,
                tbs_snap.scroll_row_start,
                tbs_snap.scroll_row_end,
                &ext_win.last_painted_cursor_row,
                row_h_px,
                ext_rows,
                0, // no content_y_offset for external windows
            );
            if (!shift_result.rows_complete) return error.OutOfMemory;
            scroll_damage = shift_result.scroll_rect;
        }
    } else {
        // Consume pending shift state to avoid stale accumulation.
        if (tbs_snap.vb_shift != 0 and tbs_snap.scroll_row_end > tbs_snap.scroll_row_start) {
            const abs_shift: u32 = @intCast(if (tbs_snap.vb_shift < 0) -tbs_snap.vb_shift else tbs_snap.vb_shift);
            app_mod.ensureShiftScratch(app.alloc, &ext_win.row_vbs_shift_scratch, abs_shift);
            app_mod.shiftRowVBs(ext_win.row_vbs.items, tbs_snap.vb_shift, tbs_snap.scroll_row_start, tbs_snap.scroll_row_end, ext_win.row_vbs_shift_scratch.items);
        }
    }

    // TBS lock-free draw: committed set is protected by refcount,
    // no app.mu needed during VB upload + draw.
    const result = try app_mod.drawRowModeSetupAndRowsFromSlots(
        g,
        &app.row_vb_budget,
        &ext_win.row_vb_retained_bytes,
        tbs_committed.row_map.items,
        &ext_win.tbs.pool,
        ext_win.row_vbs.items,
        rows_to_draw.items,
        draw_params,
    );

    if (log_enabled) {
        applog.appLog(
            "[win] drawNormalExtRowMode: grid_id={d} drawn={d} skipped={d} failed={d} rows_to_draw={d}\n",
            .{ grid_id, result.metrics.drawn_rows, result.metrics.skipped_empty, result.metrics.failed_rows, rows_to_draw.items.len },
        );
    }
    if (result.metrics.failed_rows != 0) return error.RowVBRenderFailed;

    // Cursor overlay — shared helper handles upload, scissor, draw/blink-off, and tracking.
    try app_mod.drawCursorOverlay(g, .{
        .cursor_verts = tbs_cursor.verts.items,
        .cursor_row = tbs_cursor.last_cursor_row,
        .cursor_vb = &ext_win.cursor_vb,
        .cursor_vb_bytes = &ext_win.cursor_vb_bytes,
        .row_vbs = ext_win.row_vbs.items,
        .row_map = tbs_committed.row_map.items,
        .pool = &ext_win.tbs.pool,
        .blink_visible = cursor_blink_visible,
        .content_right = content_right,
        .content_height = draw_params.content_height,
        .row_h_px = row_h_px,
        .ctx_ptr = result.ctx_ptr,
        .rs_set_sc_fn = result.rs_set_sc_fn,
        .last_painted_cursor_row = &ext_win.last_painted_cursor_row,
        // External windows preserve back_tex and may not redraw the cursor row on
        // an in-place shape change, so erase the stale overlay before redrawing.
        // A full-row frame already cleared the back texture and redrew every row;
        // clearing again would accumulate alpha on the cursor row when transparent.
        .erase_cursor_row = !force_full_rows,
        .row_already_redrawn = force_full_rows,
    });

    // Build the exact retained-back damage before drawing the overlays below.
    // The renderer carries this damage independently for every rotating flip
    // buffer, so a buffer not current this frame catches up when it rotates in.
    // The main window builds the same row-run spans in window.zig. The two are
    // NOT shared: this path reserves exactly rows + 5 up front and appends with
    // appendAssumeCapacity, while the main path appends fallibly and swallows
    // the error, backed by its force-full-present fallback. A shared helper
    // returning Allocator.Error would force a `catch unreachable` here; one
    // taking pre-reserved capacity would turn the main path's tolerant catch
    // into a panic on a short reservation. Reviewed under the 2026-08-25 audit,
    // observation 1, finding 332; left duplicated on purpose. The tail is
    // already shared through compactDamageRects.
    const present_rects = &ext_win.paint_present_rects;
    present_rects.clearRetainingCapacity();
    present_rects.ensureTotalCapacity(app.alloc, rows_to_draw.items.len + 5) catch return error.OutOfMemory;

    var span_start: ?u32 = null;
    var span_end: u32 = 0;
    for (rows_to_draw.items) |row| {
        if (span_start == null) {
            span_start = row;
            span_end = row + 1;
        } else if (row == span_end) {
            span_end += 1;
        } else {
            present_rects.appendAssumeCapacity(.{
                .left = 0,
                .top = @as(i32, @intCast(span_start.?)) * row_h_px,
                .right = @intCast(g.width),
                .bottom = @as(i32, @intCast(span_end)) * row_h_px,
            });
            span_start = row;
            span_end = row + 1;
        }
    }
    if (span_start) |start_row| {
        present_rects.appendAssumeCapacity(.{
            .left = 0,
            .top = @as(i32, @intCast(start_row)) * row_h_px,
            .right = @intCast(g.width),
            .bottom = @as(i32, @intCast(span_end)) * row_h_px,
        });
    }
    if (scroll_damage) |rect| present_rects.appendAssumeCapacity(rect);
    if (restored_scrollbar_rect) |rect| present_rects.appendAssumeCapacity(rect);

    // Cursor shape/blink changes can clear/redraw a row even when no content
    // row was dirty. Include both the old and new overlay rows.
    if (cursor_row_before) |row| {
        present_rects.appendAssumeCapacity(.{
            .left = 0,
            .top = @as(i32, @intCast(row)) * row_h_px,
            .right = @intCast(g.width),
            .bottom = @as(i32, @intCast(row + 1)) * row_h_px,
        });
    }
    if (ext_win.last_painted_cursor_row) |row| {
        present_rects.appendAssumeCapacity(.{
            .left = 0,
            .top = @as(i32, @intCast(row)) * row_h_px,
            .right = @intCast(g.width),
            .bottom = @as(i32, @intCast(row + 1)) * row_h_px,
        });
    }

    // Bloom/glow post-process.
    // Cursor verts are stored separately from the row VBs.
    // Pass cursor snapshot for bloom only when cursor is visible (same as main window).
    if (glow_enabled) {
        const bloom_cursor = if (cursor_blink_visible) tbs_cursor.verts.items else &[_]app_mod.Vertex{};
        app_mod.drawBloomRowsOverlay(
            g,
            tbs_committed.row_map.items,
            &ext_win.tbs.pool,
            ext_win.row_vbs.items,
            bloom_cursor,
            glow_intensity,
            draw_params,
        );
    }

    // Scrollbar overlay. Capture the clean, fully-composited strip after
    // bloom so restoring it on the next fade tick does not punch a no-glow
    // seam through the right edge.
    if (app.config.scrollbar.enabled and scrollbar_alpha > 0.001) {
        var scrollbar_verts: [12]app_mod.Vertex = undefined;
        const scrollbar_vert_count = scrollbar.generateScrollbarVerticesForExternal(
            app,
            scrollbar_alpha,
            grid_id,
            @intCast(g.width),
            @intCast(g.height),
            &scrollbar_verts,
            ext_win.dpi_scale,
        );
        if (scrollbar_vert_count != 0) {
            if (scrollbar.getScrollbarTrackRectForExternal(@intCast(g.width), @intCast(g.height), ext_win.dpi_scale)) |track_rect| {
                if (try g.captureScrollbarUnderlay(track_rect)) |captured_rect| {
                    try app_mod.drawScrollbarOverlay(g, &ext_win.scrollbar_vb, &ext_win.scrollbar_vb_bytes, scrollbar_verts[0..scrollbar_vert_count]);
                    present_rects.appendAssumeCapacity(captured_rect);
                }
            }
        }
    }

    if (present_rects.items.len > 1) {
        present_rects.items.len = render_pipeline_helpers.compactDamageRects(c.RECT, present_rects.items);
    }

    // A custom shader writes the complete current swapchain buffer. Mark all
    // rotating buffers full so disabling the shader cannot expose stale shader
    // pixels outside this frame's terminal dirty rectangles.
    return force_full_rows or g.custom_shader_pipelines.items.len != 0;
}

pub fn onExternalWindow(ctx: ?*anyopaque, grid_id: i64, win: i64, rows: u32, cols: u32, start_row: i32, start_col: i32) callconv(.c) void {
    const app: *App = @ptrCast(@alignCast(ctx.?));
    if (applog.isEnabled()) applog.appLog("[win] on_external_window: grid_id={d} win={d} rows={d} cols={d} pos=({d},{d})\n", .{ grid_id, win, rows, cols, start_row, start_col });

    app.mu.lockUncancelable(core.clock.io());
    defer app.mu.unlock(core.clock.io());

    // Check if already exists. If the existing entry is is_pending_close
    // (queued for destruction by an earlier on_external_window_close —
    // typically from resetSessionState clearing channel-bound state at a
    // :restart / :connect boundary), we must NOT short-circuit: the new
    // session can legitimately reuse the same grid_id, and rejecting it
    // here would leave the new server's window unattached. The pending
    // close message is already in the UI thread queue ahead of the
    // create message we are about to post, so FIFO ordering guarantees
    // the old window is destroyed before the new one is created.
    if (app.external_windows.get(grid_id)) |existing| {
        if (!existing.is_pending_close) {
            // Core emits this callback again when rows/cols or anchor position
            // change. Queue it through the same revisioned lifecycle path so
            // the UI thread updates the existing HWND transactionally.
            if (applog.isEnabled()) applog.appLog("[win] external window geometry changed for grid_id={d}\n", .{grid_id});
        } else {
            if (applog.isEnabled()) applog.appLog("[win] external window for grid_id={d} is pending close; queueing new request behind it\n", .{grid_id});
        }
    }

    // Coalesce: if the queue already has a request for this grid_id (UI
    // thread hasn't dequeued it yet, or all pending entries for this
    // grid_id are blocked by an is_pending_close existing window),
    // replace its mutable fields in place but PRESERVE the existing
    // entry's seq. The original WM_APP_CREATE_EXTERNAL_WINDOW message
    // already in the UI queue carries that seq in lParam, and the
    // handler will match exactly the entry whose seq matches. If creation is
    // already using an older snapshot, update_revision retains the replaced
    // data for a following in-place geometry pass.
    //
    // Without coalesce, multiple enqueues for the same grid_id would
    // each spawn a createExternalWindowOnUIThread; the second put()
    // would overwrite the first window's HWND in external_windows —
    // leaking the first and confusing the close handler.
    for (app.pending_external_windows.items, 0..) |item, i| {
        if (item.grid_id == grid_id) {
            // An in-progress request cancelled by a preceding close belongs to
            // the old lifecycle generation. Keep it only until its creator
            // unwinds; a reopened same grid gets a fresh seq/queue entry.
            if (item.cancel_requested) continue;
            app.pending_external_windows.items[i] = .{
                .grid_id = grid_id,
                .win = win,
                .rows = rows,
                .cols = cols,
                .start_row = start_row,
                .start_col = start_col,
                .seq = item.seq, // preserve so existing in-flight message still matches
                .create_in_progress = item.create_in_progress,
                .update_revision = item.update_revision +% 1,
            };
            if (applog.isEnabled()) applog.appLog("[win] coalesced pending external window request for grid_id={d} (seq={d})\n", .{ grid_id, item.seq });
            return;
        }
    }

    // No existing pending entry: take a fresh seq, append, post.
    const seq = app.pending_external_seq_counter;
    app.pending_external_seq_counter += 1;

    app.pending_external_windows.append(app.alloc, .{
        .grid_id = grid_id,
        .win = win,
        .rows = rows,
        .cols = cols,
        .start_row = start_row,
        .start_col = start_col,
        .seq = seq,
    }) catch |e| {
        if (applog.isEnabled()) applog.appLog("[win] failed to queue external window request: {any}\n", .{e});
        if (app.corep) |corep| core.zonvie_core_abort_flush(corep);
        return;
    };
    if (app.hwnd) |main_hwnd| {
        if (c.PostMessageW(main_hwnd, app_mod.WM_APP_CREATE_EXTERNAL_WINDOW, 0, @bitCast(seq)) == 0) {
            // This callback runs on the core thread, which cannot arm a timer
            // owned by the UI thread. Remove the unwakeable entry and abort the
            // flush so the normal core retry invokes this callback again.
            if (applog.isEnabled()) applog.appLog("[win] onExternalWindow: PostMessageW failed for grid_id={d} seq={d}, dropping queued request\n", .{ grid_id, seq });
            var k: usize = 0;
            while (k < app.pending_external_windows.items.len) {
                if (app.pending_external_windows.items[k].seq == seq) {
                    _ = app.pending_external_windows.orderedRemove(k);
                    break;
                }
                k += 1;
            }
            // The lifecycle callback has no return value. Abort the enclosing
            // core flush so it does not publish this grid as known; the normal
            // flush retry will invoke onExternalWindow again.
            if (app.corep) |corep| core.zonvie_core_abort_flush(corep);
        }
    } else {
        _ = app.pending_external_windows.pop();
        if (app.corep) |corep| core.zonvie_core_abort_flush(corep);
    }
}

/// Post wakes for every queued create that is not already executing. This is
/// called only from the UI thread. PostMessageW does not dispatch synchronously,
/// so it is safe to keep app.mu while walking the allocation-free pending list.
pub fn wakePendingExternalWindowCreates(app: *App) void {
    const main_hwnd = app.hwnd orelse return;
    var post_failed = false;

    app.mu.lockUncancelable(core.clock.io());
    if (app.external_window_create_in_progress) {
        app.mu.unlock(core.clock.io());
        return;
    }
    for (app.pending_external_windows.items) |item| {
        if (item.create_in_progress) continue;
        if (c.PostMessageW(main_hwnd, app_mod.WM_APP_CREATE_EXTERNAL_WINDOW, 0, @bitCast(item.seq)) == 0) {
            post_failed = true;
            break;
        }
    }
    app.mu.unlock(core.clock.io());

    if (post_failed) {
        retryPendingExternalWindowCreates(app);
    }
}

/// UI-thread-only fallback after a fallible create step retained its request.
pub fn retryPendingExternalWindowCreates(app: *App) void {
    const main_hwnd = app.hwnd orelse return;
    if (app.external_create_retry_armed) return;

    const delay_ms = app.external_create_retry_delay_ms;
    app.external_create_retry_delay_ms = render_pipeline_helpers.nextBackoffDelayMs(delay_ms, app_mod.EXTERNAL_CREATE_RETRY_MAX_MS);
    app.external_create_retry_generation +%= 1;
    if (app.external_create_retry_generation == 0) app.external_create_retry_generation = 1;
    const generation = app.external_create_retry_generation;
    app.external_create_retry_deadline_ms = c.GetTickCount64() + delay_ms;
    app.external_create_retry_armed = true;
    app.external_create_retry_needed = false;

    if (window_mod.scheduleReliableWindowMessage(
        main_hwnd,
        app_mod.WM_APP_EXTERNAL_CREATE_RETRY_FALLBACK,
        generation,
        @bitCast(app.window_wake_cookie),
        delay_ms,
    )) {
        app.external_create_retry_fallback_wake_issued = false;
        return;
    }

    // The main message loop waits on this deadline directly, so retry
    // liveness does not depend on allocating either kind of Win32 timer.
    app.external_create_retry_fallback_wake_issued = true;
}

pub fn consumeExternalCreateRetryWake(app: *App, generation: u32) void {
    if (!app.external_create_retry_armed or app.external_create_retry_generation != generation) return;
    app.external_create_retry_armed = false;
    app.external_create_retry_deadline_ms = 0;
    wakePendingExternalWindowCreates(app);
}

pub fn serviceDeferredRetries(app: *App, now_ms: u64) void {
    _ = app_mod.g_external_create_retry_delivery_failed.swap(false, .acq_rel);
    if (app.external_create_retry_armed and
        app.external_create_retry_deadline_ms != 0 and
        app.external_create_retry_deadline_ms <= now_ms)
    {
        consumeExternalCreateRetryWake(app, app.external_create_retry_generation);
    }
    servicePaintRetryDeadlines(app, now_ms);
    if (!app.external_create_retry_needed or app.external_create_retry_armed) return;
    app.external_create_retry_needed = false;
    retryPendingExternalWindowCreates(app);
}

fn servicePaintRetryDeadlines(app: *App, now_ms: u64) void {
    if (app.external_paint_retry_deadline_ms == 0 or app.external_paint_retry_deadline_ms > now_ms) return;

    var next_deadline_ms: u64 = 0;
    app.mu.lockUncancelable(core.clock.io());
    var it = app.external_windows.valueIterator();
    while (it.next()) |ext_win_ptr| {
        const ext_win = ext_win_ptr.*;
        if (ext_win.paint_retry_deadline_ms != 0 and ext_win.paint_retry_deadline_ms <= now_ms) {
            ext_win.paint_retry_deadline_ms = 0;
            _ = ext_win.paint_retry.timerFired(ext_win.paint_retry.generation);
            _ = c.InvalidateRect(ext_win.hwnd, null, c.FALSE);
        } else if (ext_win.paint_retry_deadline_ms != 0 and
            (next_deadline_ms == 0 or ext_win.paint_retry_deadline_ms < next_deadline_ms))
        {
            next_deadline_ms = ext_win.paint_retry_deadline_ms;
        }
    }
    app.mu.unlock(core.clock.io());
    app.external_paint_retry_deadline_ms = next_deadline_ms;
}

pub fn nextPaintRetryDeadlineMs(app: *App) u64 {
    return app.external_paint_retry_deadline_ms;
}

pub fn resetExternalCreateRetryIfIdle(app: *App) void {
    app.mu.lockUncancelable(core.clock.io());
    const idle = app.pending_external_windows.items.len == 0;
    app.mu.unlock(core.clock.io());
    if (!idle) return;
    app.external_create_retry_delay_ms = app_mod.EXTERNAL_CREATE_RETRY_INTERVAL_MS;
    app.external_create_retry_generation +%= 1;
    if (app.external_create_retry_generation == 0) app.external_create_retry_generation = 1;
    app.external_create_retry_armed = false;
    app.external_create_retry_needed = false;
    app.external_create_retry_fallback_wake_issued = false;
    app.external_create_retry_deadline_ms = 0;
}

pub const ExternalWindowCreateResult = enum {
    published,
    obsolete,
    retry,
};

/// Apply a pre-window vertex capture into a newly-created external surface.
/// Caller holds app.mu. Every fallible reservation happens before dimensions
/// and vertex contents are published; on failure the pending capture remains
/// intact and a later WM_PAINT retries this function.
fn applyPendingExternalVerticesLocked(app: *App, grid_id: i64, ext_win: *app_mod.ExternalWindow) bool {
    var pending_idx: ?usize = null;
    for (app.pending_external_verts.items, 0..) |pv, i| {
        if (pv.grid_id == grid_id) {
            pending_idx = i;
            break;
        }
    }
    const idx = pending_idx orelse return true;
    const pv = &app.pending_external_verts.items[idx];
    const row_count = pv.surface.row_verts.items.len;

    // Reserve the legacy surface copy.
    if (pv.surface.row_mode) {
        if (row_count != 0 and !ext_win.surface.ensureRowStorage(app.alloc, @intCast(row_count - 1))) return false;
        for (pv.surface.row_verts.items, 0..) |src_row, row_idx| {
            ext_win.surface.row_verts.items[row_idx].verts.ensureTotalCapacity(app.alloc, src_row.verts.items.len) catch return false;
        }
    } else {
        ext_win.surface.verts.ensureTotalCapacity(app.alloc, pv.surface.verts.items.len) catch return false;
    }
    ext_win.surface.cursor_verts.ensureTotalCapacity(app.alloc, pv.surface.cursor_verts.items.len) catch return false;

    // A window published during an active core flush joins that transaction.
    // Seed its write set so later row callbacks and onFlushEnd publish one
    // complete frame; outside a flush, initialize the committed set directly.
    const cs = if (ext_win.tbs.is_in_flush)
        ext_win.tbs.writeSet()
    else
        &ext_win.tbs.sets[ext_win.tbs.committed_index];
    if (ext_win.tbs.is_in_flush) {
        if (!ext_win.tbs.prepareRowSyncTracking(app.alloc, row_count)) return false;
        ext_win.tbs.requireFullRowSync();
    }
    if (pv.surface.row_mode) {
        if (row_count != 0 and !cs.ensureRowStorage(app.alloc, @intCast(row_count - 1))) return false;
        for (pv.surface.row_verts.items, 0..) |src_row, row_idx| {
            const mapping = &cs.row_map.items[row_idx];
            if (mapping.slot == app_mod.SLOT_NONE) {
                const new_idx = ext_win.tbs.pool.acquireSlot(app.alloc) orelse return false;
                mapping.slot = new_idx;
                ext_win.tbs.pool.retain(new_idx);
            }
            const slot = ext_win.tbs.pool.slotPtr(mapping.slot);
            slot.verts.ensureTotalCapacity(app.alloc, src_row.verts.items.len) catch return false;
        }
    } else {
        cs.flat_verts.ensureTotalCapacity(app.alloc, pv.surface.verts.items.len) catch return false;
    }
    if (!ext_win.tbs.reserveMainCursorCapacity(app.alloc, pv.surface.cursor_verts.items.len)) return false;

    // All allocations succeeded. Publish the complete surface atomically
    // while app.mu still excludes core vertex callbacks.
    ext_win.surface.row_mode = pv.surface.row_mode;
    ext_win.surface.rows = pv.surface.rows;
    ext_win.surface.cols = pv.surface.cols;
    ext_win.needs_redraw = true;

    if (pv.surface.row_mode) {
        ext_win.surface.verts.clearRetainingCapacity();
        for (pv.surface.row_verts.items, 0..) |src_row, row_idx| {
            const dst_row = &ext_win.surface.row_verts.items[row_idx];
            dst_row.verts.clearRetainingCapacity();
            dst_row.verts.appendSliceAssumeCapacity(src_row.verts.items);
            dst_row.gen = src_row.gen;
            dst_row.origin_row = src_row.origin_row;
        }
        _ = ext_win.surface.truncateRows(app.alloc, pv.surface.rows);
        ext_win.recomputeVertCount();
    } else {
        ext_win.surface.verts.clearRetainingCapacity();
        ext_win.surface.verts.appendSliceAssumeCapacity(pv.surface.verts.items);
        ext_win.vert_count = pv.surface.verts.items.len;
    }
    ext_win.surface.cursor_verts.clearRetainingCapacity();
    ext_win.surface.cursor_verts.appendSliceAssumeCapacity(pv.surface.cursor_verts.items);
    ext_win.surface.last_cursor_row = pv.surface.last_cursor_row;

    cs.row_mode = pv.surface.row_mode;
    cs.rows = pv.surface.rows;
    cs.cols = pv.surface.cols;
    cs.metrics_gen = pv.metrics_gen;
    if (pv.surface.row_mode) {
        cs.flat_verts.clearRetainingCapacity();
        for (pv.surface.row_verts.items, 0..) |src_row, row_idx| {
            const slot = ext_win.tbs.pool.slotPtr(cs.row_map.items[row_idx].slot);
            slot.verts.clearRetainingCapacity();
            slot.verts.appendSliceAssumeCapacity(src_row.verts.items);
            slot.origin_row = src_row.origin_row;
            slot.ver = src_row.gen;
        }
        var extra = row_count;
        while (extra < cs.row_map.items.len) : (extra += 1) {
            const mapping = &cs.row_map.items[extra];
            if (mapping.slot != app_mod.SLOT_NONE) {
                ext_win.tbs.pool.release(app.alloc, mapping.slot);
                mapping.slot = app_mod.SLOT_NONE;
            }
        }
    } else {
        cs.releaseAllSlots(app.alloc, &ext_win.tbs.pool);
        cs.row_map.clearRetainingCapacity();
        cs.flat_verts.clearRetainingCapacity();
        cs.flat_verts.appendSliceAssumeCapacity(pv.surface.verts.items);
    }
    if (!ext_win.tbs.storeMainCursor(
        app.alloc,
        pv.surface.cursor_verts.items,
        pv.surface.last_cursor_row,
    )) return false;
    ext_win.tbs.markFlushPaintFull();
    if (!ext_win.tbs.is_in_flush) ext_win.tbs.commitFlush(app.alloc);

    var applied = app.pending_external_verts.swapRemove(idx);
    applied.deinit(app.alloc);
    return true;
}

/// Apply a changed lifecycle callback to an already-published HWND without
/// replacing its renderer/surface contents. Must be called on the UI thread.
/// Top-right placement for the message floats. Resolves the Win32 state and
/// defers the arithmetic to msg_float_layout, which is covered by
/// windows/ui/msg_float_layout_test.zig.
///
/// Must be called with `app.mu` NOT held; getExtFloatTargetRect expects the
/// lock and does not take it itself.
fn msgFloatTopRight(app: *App, is_msg_history: bool, window_w: c_int) msg_float_layout.Point {
    app.mu.lockUncancelable(core.clock.io());
    const target_rect = app.getExtFloatTargetRect();
    // msg_show stacks below msg_history when both are up; msg_history itself
    // always sits at the top.
    const history_hwnd: ?c.HWND = if (is_msg_history) null else blk: {
        if (app.external_windows.get(app_mod.MSG_HISTORY_GRID_ID)) |hw| break :blk hw.hwnd;
        break :blk null;
    };
    app.mu.unlock(core.clock.io());

    var history_bottom: ?i32 = null;
    if (history_hwnd) |hwnd| {
        var history_rect: c.RECT = undefined;
        if (c.GetWindowRect(hwnd, &history_rect) != 0) history_bottom = history_rect.bottom;
    }

    return msg_float_layout.msgFloatTopRight(.{
        .left = target_rect.left,
        .top = target_rect.top,
        .right = target_rect.right,
        .bottom = target_rect.bottom,
    }, window_w, history_bottom);
}

pub fn updateExternalWindowGeometryOnUIThread(app: *App, req: app_mod.PendingExternalWindow) bool {
    const is_cmdline = req.grid_id == app_mod.CMDLINE_GRID_ID;
    const is_popupmenu = req.grid_id == app_mod.POPUPMENU_GRID_ID;
    const is_msg_show = req.grid_id == app_mod.MESSAGE_GRID_ID;
    const is_msg_history = req.grid_id == app_mod.MSG_HISTORY_GRID_ID;
    const is_special_window = is_cmdline or is_popupmenu or is_msg_show or is_msg_history;
    const cell_w = app.cell_w_px;
    const cell_h = app.rowHeightPx();

    const insets = externalSurfaceInsetsPx(app, req.grid_id);
    var client_w: c_int = @as(c_int, @intCast(req.cols * cell_w)) + insets.w;
    const client_h: c_int = @as(c_int, @intCast(req.rows * cell_h)) + insets.h;
    client_w = clampCmdlineWidthToWorkArea(app, req.grid_id, client_w);

    const style: c.DWORD = if (is_special_window) c.WS_POPUP else c.WS_OVERLAPPEDWINDOW;
    const ex_style: c.DWORD = (if (is_special_window) @as(c.DWORD, @intCast(c.WS_EX_TOPMOST)) else 0) |
        @as(c.DWORD, @intCast(c.WS_EX_NOREDIRECTIONBITMAP));
    var rect: c.RECT = .{ .left = 0, .top = 0, .right = client_w, .bottom = client_h };
    _ = c.AdjustWindowRectEx(&rect, style, 0, ex_style);
    const window_w = rect.right - rect.left;
    const window_h = rect.bottom - rect.top;

    app.mu.lockUncancelable(core.clock.io());
    const target_hwnd = if (app.external_windows.get(req.grid_id)) |ext_win| blk: {
        if (ext_win.is_pending_close) break :blk null;
        ext_win.win_id = req.win;
        ext_win.suppress_resize_callback = true;
        break :blk ext_win.hwnd;
    } else null;
    const anchor_hwnd: ?c.HWND = if (req.win > 0) blk: {
        if (app.external_windows.get(req.win)) |anchor| break :blk anchor.hwnd;
        break :blk null;
    } else null;
    const main_hwnd = app.hwnd;
    const main_y_offset: c_int = if (anchor_hwnd == null and app.ext_tabline_enabled and app.content_hwnd == null)
        app.scalePx(app_mod.TablineState.TAB_BAR_HEIGHT)
    else
        0;
    app.mu.unlock(core.clock.io());
    const hwnd = target_hwnd orelse return false;

    var x: c_int = 0;
    var y: c_int = 0;
    var flags: c.UINT = c.SWP_NOZORDER | c.SWP_NOACTIVATE;
    if (req.start_row >= 0 and req.start_col >= 0) {
        const origin_hwnd: ?c.HWND = if (anchor_hwnd != null) anchor_hwnd else main_hwnd;
        if (origin_hwnd) |origin| {
            var client_origin: c.POINT = .{ .x = 0, .y = 0 };
            if (c.ClientToScreen(origin, &client_origin) != 0) {
                x = client_origin.x + @as(c_int, @intCast(req.start_col)) * @as(c_int, @intCast(cell_w));
                const anchor_y = client_origin.y + main_y_offset + @as(c_int, @intCast(req.start_row)) * @as(c_int, @intCast(cell_h));
                y = if (is_popupmenu) popupmenuPositionY(anchor_y, @intCast(cell_h), window_h, origin) else anchor_y;
            } else {
                flags |= c.SWP_NOMOVE;
            }
        } else {
            flags |= c.SWP_NOMOVE;
        }
    } else if (is_msg_show or is_msg_history) {
        const pos = msgFloatTopRight(app, is_msg_history, window_w);
        x = pos.x;
        y = pos.y;
        if (applog.isEnabled()) applog.appLog("[win] msg float re-anchored top-right: ({d},{d}) w={d}\n", .{ x, y, window_w });
    } else {
        flags |= c.SWP_NOMOVE;
    }

    const updated = c.SetWindowPos(hwnd, null, x, y, window_w, window_h, flags) != 0;
    app.mu.lockUncancelable(core.clock.io());
    if (app.external_windows.get(req.grid_id)) |ext_win| {
        if (ext_win.hwnd == hwnd) ext_win.suppress_resize_callback = false;
    }
    app.mu.unlock(core.clock.io());
    if (updated) _ = c.InvalidateRect(hwnd, null, c.FALSE);
    return updated;
}

/// Actually create external window (must be called on UI thread).
pub fn createExternalWindowOnUIThread(app: *App, req: app_mod.PendingExternalWindow) ExternalWindowCreateResult {
    if (applog.isEnabled()) applog.appLog("[win] createExternalWindowOnUIThread: grid_id={d} rows={d} cols={d}\n", .{ req.grid_id, req.rows, req.cols });

    // Ensure external window class is registered
    if (!ensureExternalWindowClassRegistered()) {
        if (applog.isEnabled()) applog.appLog("[win] external window class registration failed\n", .{});
        return .retry;
    }

    // Get cell dimensions from main atlas
    // Note: cell_h must include linespace_px to match core's vertex generation
    const cell_w: u32 = app.cell_w_px;
    const cell_h: u32 = app.rowHeightPx();
    const content_w: c_int = @intCast(req.cols * cell_w);
    const content_h: c_int = @intCast(req.rows * cell_h);

    // Check if this is a special window (cmdline, popupmenu, msg_show, msg_history)
    const is_cmdline = (req.grid_id == app_mod.CMDLINE_GRID_ID);
    const is_popupmenu = (req.grid_id == app_mod.POPUPMENU_GRID_ID);
    const is_msg_show = (req.grid_id == app_mod.MESSAGE_GRID_ID);
    const is_msg_history = (req.grid_id == app_mod.MSG_HISTORY_GRID_ID);

    const insets = externalSurfaceInsetsPx(app, req.grid_id);
    var client_w: c_int = content_w + insets.w;
    const client_h: c_int = content_h + insets.h;
    client_w = clampCmdlineWidthToWorkArea(app, req.grid_id, client_w);

    // Window style: borderless popup for cmdline, popupmenu, and msg_history, normal for others
    // Note: WS_VISIBLE is NOT included - we use ShowWindow(SW_SHOWNA) to show without activating
    const is_special_window = is_cmdline or is_popupmenu or is_msg_show or is_msg_history;
    const dwStyle: c.DWORD = if (is_special_window) c.WS_POPUP else c.WS_OVERLAPPEDWINDOW;
    // Always use WS_EX_NOREDIRECTIONBITMAP: all rendering via DXGI + DirectComposition.
    const dwExStyle: c.DWORD = (if (is_special_window) @as(c.DWORD, @intCast(c.WS_EX_TOPMOST)) else @as(c.DWORD, 0)) |
        @as(c.DWORD, @intCast(c.WS_EX_NOREDIRECTIONBITMAP));

    var rect: c.RECT = .{
        .left = 0,
        .top = 0,
        .right = client_w,
        .bottom = client_h,
    };
    _ = c.AdjustWindowRectEx(&rect, dwStyle, 0, dwExStyle);
    const window_w: c_int = rect.right - rect.left;
    const window_h: c_int = rect.bottom - rect.top;

    if (applog.isEnabled()) applog.appLog("[win] external window: content=({d},{d}) client=({d},{d}) window=({d},{d}) is_cmdline={}\n", .{ content_w, content_h, client_w, client_h, window_w, window_h, is_cmdline });

    // Calculate window position
    var pos_x: c_int = c.CW_USEDEFAULT;
    var pos_y: c_int = c.CW_USEDEFAULT;

    // Restore saved position from previous tab switch (only for regular external windows)
    if (!is_special_window) {
        if (app.saved_external_window_positions.get(req.grid_id)) |saved| {
            pos_x = saved.x;
            pos_y = saved.y;
            if (applog.isEnabled()) applog.appLog("[win] restored saved position for grid_id={d}: ({d},{d})\n", .{ req.grid_id, pos_x, pos_y });
        }
    }

    // Tab externalization: use pending position if set (only for regular external windows, not special windows)
    // Also check timeout (500ms) to prevent stale position from affecting unrelated windows.
    const pending_timeout_ms: i64 = 500;
    const now_ms = @as(i64, @intCast(@divTrunc(core.clock.nowNs(), std.time.ns_per_ms)));
    const pending_age_ms = now_ms - app.pending_external_window_position_time;
    if (!is_special_window and app.pending_external_window_position != null and pending_age_ms < pending_timeout_ms) {
        const pos = app.pending_external_window_position.?;
        // Position so the window is centered horizontally on cursor, below cursor
        pos_x = pos.x - @divTrunc(window_w, 2);
        pos_y = pos.y;
        app.pending_external_window_position = null; // Clear after use
        if (applog.isEnabled()) applog.appLog("[win] external window positioned from pending position: ({d},{d}) age={d}ms\n", .{ pos_x, pos_y, pending_age_ms });
    } else if (app.pending_external_window_position != null and pending_age_ms >= pending_timeout_ms) {
        // Pending position expired, clear it
        if (applog.isEnabled()) applog.appLog("[win] clearing stale pending_external_window_position (age={d}ms)\n", .{pending_age_ms});
        app.pending_external_window_position = null;
    }

    if (pos_x != c.CW_USEDEFAULT) {
        // Position already set from pending position, skip other positioning logic
    } else if (req.start_row >= 0 and req.start_col >= 0) {
        // Check if anchor window (req.win) is an external window
        // Copy hwnd while holding lock to avoid use-after-free
        app.mu.lockUncancelable(core.clock.io());
        const anchor_hwnd: ?c.HWND = if (req.win > 0) blk: {
            if (app.external_windows.get(req.win)) |ew| {
                break :blk ew.hwnd;
            }
            break :blk null;
        } else null;
        app.mu.unlock(core.clock.io());

        if (anchor_hwnd) |ahwnd| {
            // Position relative to anchor external window
            var anchor_rect: c.RECT = undefined;
            if (c.GetWindowRect(ahwnd, &anchor_rect) != 0) {
                var client_pt: c.POINT = .{ .x = 0, .y = 0 };
                _ = c.ClientToScreen(ahwnd, &client_pt);

                const px_x: c_int = @intCast(@as(i32, @intCast(req.start_col)) * @as(i32, @intCast(cell_w)));
                const px_y: c_int = @intCast(@as(i32, @intCast(req.start_row)) * @as(i32, @intCast(cell_h)));

                pos_x = client_pt.x + px_x;
                if (is_popupmenu) {
                    pos_y = popupmenuPositionY(client_pt.y + px_y, @intCast(cell_h), window_h, ahwnd);
                } else {
                    pos_y = client_pt.y + px_y;
                }
                if (applog.isEnabled()) applog.appLog("[win] external window position from anchor ext_win={d}: ({d},{d}) cell=({d},{d})\n", .{ req.win, pos_x, pos_y, req.start_col, req.start_row });
            }
        } else if (app.hwnd) |main_hwnd| {
            // Position relative to main window using win_pos
            var main_rect: c.RECT = undefined;
            if (c.GetWindowRect(main_hwnd, &main_rect) != 0) {
                // Get main window client area origin
                var client_pt: c.POINT = .{ .x = 0, .y = 0 };
                _ = c.ClientToScreen(main_hwnd, &client_pt);

                // Calculate position in pixels from cell coordinates
                const px_x: c_int = @intCast(@as(i32, @intCast(req.start_col)) * @as(i32, @intCast(cell_w)));
                var px_y: c_int = @intCast(@as(i32, @intCast(req.start_row)) * @as(i32, @intCast(cell_h)));

                // When ext_tabline is enabled, grid coordinates start below the tabbar
                if (app.ext_tabline_enabled and app.content_hwnd == null) {
                    px_y += app.scalePx(app_mod.TablineState.TAB_BAR_HEIGHT);
                }

                pos_x = client_pt.x + px_x;
                if (is_popupmenu) {
                    pos_y = popupmenuPositionY(client_pt.y + px_y, @intCast(cell_h), window_h, main_hwnd);
                } else {
                    pos_y = client_pt.y + px_y;
                }
                if (applog.isEnabled()) applog.appLog("[win] external window position from win_pos: ({d},{d}) cell=({d},{d}) ext_tabline={}\n", .{ pos_x, pos_y, req.start_col, req.start_row, app.ext_tabline_enabled });
            }
        }
    } else if (is_cmdline) {
        // Position cmdline window
        // If message window is visible (confirm dialog), position directly below it
        app.mu.lockUncancelable(core.clock.io());
        const msg_win = app.message_window;
        app.mu.unlock(core.clock.io());

        if (msg_win) |mw| {
            var msg_rect: c.RECT = undefined;
            if (c.GetWindowRect(mw.hwnd, &msg_rect) != 0) {
                // Position directly below message window, centered horizontally
                const msg_width = msg_rect.right - msg_rect.left;
                pos_x = msg_rect.left + @divTrunc(msg_width - window_w, 2);
                pos_y = msg_rect.bottom + 4; // 4px gap below message window
                if (applog.isEnabled()) applog.appLog("[win] cmdline window below message: ({d},{d})\n", .{ pos_x, pos_y });
            } else {
                // Fallback: center on screen
                const screen_w = c.GetSystemMetrics(c.SM_CXSCREEN);
                const screen_h = c.GetSystemMetrics(c.SM_CYSCREEN);
                pos_x = @divTrunc(screen_w - window_w, 2);
                pos_y = @divTrunc(screen_h - window_h, 3);
                if (applog.isEnabled()) applog.appLog("[win] cmdline window position (fallback): ({d},{d})\n", .{ pos_x, pos_y });
            }
        } else {
            // No message window: use saved position if available, otherwise center on screen
            app.mu.lockUncancelable(core.clock.io());
            const saved_x = app.cmdline_saved_x;
            const saved_y = app.cmdline_saved_y;
            app.mu.unlock(core.clock.io());

            if (saved_x != null and saved_y != null) {
                // Use saved position, but ensure window stays on screen
                const screen_w = c.GetSystemMetrics(c.SM_CXSCREEN);
                const screen_h = c.GetSystemMetrics(c.SM_CYSCREEN);
                pos_x = @max(0, @min(saved_x.?, screen_w - window_w));
                pos_y = @max(0, @min(saved_y.?, screen_h - window_h));
                if (applog.isEnabled()) applog.appLog("[win] cmdline window using saved position: ({d},{d})\n", .{ pos_x, pos_y });
            } else {
                // Default: center on screen
                const screen_w = c.GetSystemMetrics(c.SM_CXSCREEN);
                const screen_h = c.GetSystemMetrics(c.SM_CYSCREEN);
                pos_x = @divTrunc(screen_w - window_w, 2);
                pos_y = @divTrunc(screen_h - window_h, 3); // Slightly above center (1/3 from top)
                if (applog.isEnabled()) applog.appLog("[win] cmdline window position (default): ({d},{d}) screen=({d},{d})\n", .{ pos_x, pos_y, screen_w, screen_h });
            }
        }
    } else if (is_popupmenu and req.start_row == -1) {
        // Popupmenu for cmdline completion: position above cmdline window
        app.mu.lockUncancelable(core.clock.io());
        const cmdline_win = app.external_windows.get(app_mod.CMDLINE_GRID_ID);
        app.mu.unlock(core.clock.io());

        if (cmdline_win) |cw| {
            var cmdline_rect: c.RECT = undefined;
            if (c.GetWindowRect(cw.hwnd, &cmdline_rect) != 0) {
                const cmdline_content_x: c_int =
                    @as(c_int, @intCast(app_mod.CMDLINE_PADDING)) +
                    @as(c_int, @intCast(app_mod.CMDLINE_ICON_MARGIN_LEFT + app_mod.CMDLINE_ICON_SIZE + app_mod.CMDLINE_ICON_MARGIN_RIGHT));
                const popupmenu_padding: c_int = 8;
                // Position above cmdline window with small gap
                pos_x = cmdline_rect.left + cmdline_content_x +
                    @as(c_int, @intCast(req.start_col)) * @as(c_int, @intCast(cell_w)) -
                    popupmenu_padding;
                pos_y = cmdline_rect.top - window_h - 4; // 4px gap
                if (applog.isEnabled()) applog.appLog("[win] popupmenu above cmdline: ({d},{d})\n", .{ pos_x, pos_y });
            }
        } else {
            // Fallback: center on screen
            const screen_w = c.GetSystemMetrics(c.SM_CXSCREEN);
            const screen_h = c.GetSystemMetrics(c.SM_CYSCREEN);
            pos_x = @divTrunc(screen_w - window_w, 2);
            pos_y = @divTrunc(screen_h - window_h, 2);
            if (applog.isEnabled()) applog.appLog("[win] popupmenu fallback center: ({d},{d})\n", .{ pos_x, pos_y });
        }
    } else if (is_msg_history or is_msg_show) {
        // Message floats: top-right, msg_show stacked below msg_history.
        // Shared with the geometry-update path so the two cannot drift apart.
        const pos = msgFloatTopRight(app, is_msg_history, window_w);
        pos_x = pos.x;
        pos_y = pos.y;
        if (applog.isEnabled()) applog.appLog("[win] msg float at top-right: ({d},{d}) history={any}\n", .{ pos_x, pos_y, is_msg_history });
    }

    // Create window using external window class
    var title_utf8: [64]u8 = undefined;
    const title_str = std.fmt.bufPrint(&title_utf8, "Window {d}", .{req.win}) catch "Window";
    var title_wide: [65]u16 = undefined; // +1 for null terminator
    const title_len = std.unicode.utf8ToUtf16Le(&title_wide, title_str) catch 0;
    title_wide[title_len] = 0; // null terminate

    const hwnd = c.CreateWindowExW(
        dwExStyle,
        external_window_class_name.ptr,
        @ptrCast(title_wide[0..title_len :0].ptr),
        dwStyle, // No WS_VISIBLE - show with SW_SHOWNA to avoid activation
        pos_x,
        pos_y,
        window_w,
        window_h,
        null,
        null,
        c.GetModuleHandleW(null),
        null,
    );

    if (hwnd != null and !is_special_window) {
        // Mirror the main HWND's OS-theme titlebar handling. WS_POPUP
        // children (cmdline/popupmenu/msg_show/msg_history) have no caption
        // so we skip them.
        window_mod.applyOsTitlebarTheme(hwnd);
    }

    if (hwnd == null) {
        if (applog.isEnabled()) applog.appLog("[win] CreateWindowExW failed for external grid\n", .{});
        return .retry;
    }

    // Only the cmdline accepts file drops; a drop there inserts the path as
    // text instead of opening the file. The other decorated surfaces have
    // nothing to insert into.
    if (is_cmdline) {
        c.DragAcceptFiles(hwnd, 1);
    }

    // Apply the same acrylic backdrop as the main window so external float
    // windows and ext-cmdline/popupmenu/msg overlays get the frosted blur +
    // shadow (the backdrop is per-HWND on Windows).
    if (app.config.window.blur) {
        window_mod.applyWindowBackdrop(hwnd);
    }

    // Show window without activating (SW_SHOWNA = 8)
    _ = c.ShowWindow(hwnd, 8);

    // Initialize D3D11 renderer for external window (with transparency if enabled)
    var renderer = d3d11.Renderer.init(app.alloc, hwnd, app.config.window.opacity) catch |e| {
        if (applog.isEnabled()) applog.appLog("[win] d3d11.Renderer.init failed for external window: {any}\n", .{e});
        _ = c.DestroyWindow(hwnd);
        return .retry;
    };
    // Load the same custom post-process shaders the main window uses,
    // so cmdline/popupmenu/msg/etc. overlay get the same shader effect
    // applied through their own back_tex.
    renderer.loadCustomShaderPipelines(&app.config);
    if (app.corep) |corep| {
        if (core.zonvie_core_get_glow_enabled(corep)) {
            _ = renderer.prepareBloomShaders();
        }
    }

    // Collect SetWindowPos info while holding the lock, then call SetWindowPos after releasing
    // to avoid deadlock (SetWindowPos sends WM_SIZE synchronously, and WM_SIZE handler locks app.mu)
    const DeferredSetWindowPos = struct {
        hwnd: c.HWND,
        hwnd_insert_after: c.HWND, // non-optional; use null for "no change" with SWP_NOZORDER
        x: c_int,
        y: c_int,
        flags: c.UINT,
    };
    var deferred_setpos: ?DeferredSetWindowPos = null;
    var deferred_setpos_cmdline: ?DeferredSetWindowPos = null;

    // Determine if this is a float-origin external window (nvim_open_win external=true)
    // vs a regular split externalized by ext_windows. Query core before acquiring app.mu.
    const is_float = if (app.corep) |cp| core.zonvie_core_is_float_external(cp, req.grid_id) != 0 else false;

    app.mu.lockUncancelable(core.clock.io());

    // Revalidate the lifecycle entry immediately before publication. Core
    // callbacks can update or close it while CreateWindowExW/D3D initialization
    // runs without app.mu. Keeping this lock through the map put makes the
    // validation and publication one transaction.
    var request_found = false;
    var request_cancelled = app.pending_destroy_after_active_operation;
    var request_superseded = false;
    for (app.pending_external_windows.items) |item| {
        if (item.seq != req.seq) continue;
        request_found = true;
        request_cancelled = request_cancelled or item.cancel_requested;
        request_superseded = item.update_revision != req.update_revision;
        break;
    }
    if (!request_found or request_cancelled or request_superseded) {
        app.mu.unlock(core.clock.io());
        var tmp_renderer = renderer;
        tmp_renderer.deinit();
        _ = c.DestroyWindow(hwnd);
        return if (request_superseded) .retry else .obsolete;
    }

    // Defense-in-depth: refuse to overwrite a live external_windows entry
    // (i.e., one that is NOT is_pending_close). The main caller flow
    // already coalesces same-grid_id requests in pending_external_windows
    // and the WM_APP_CREATE_EXTERNAL_WINDOW handler skips items blocked
    // by an is_pending_close entry, so reaching this branch implies a
    // bug elsewhere — but if we did put() over a live entry, the old
    // HWND would leak and the close handler would later destroy whichever
    // entry is currently in the map (the new one). Tear down our just-
    // created HWND/renderer instead.
    if (app.external_windows.get(req.grid_id)) |existing| {
        if (!existing.is_pending_close) {
            app.mu.unlock(core.clock.io());
            if (applog.isEnabled()) applog.appLog("[win] createExternalWindowOnUIThread: live entry for grid_id={d} would be overwritten; aborting (probable upstream coalesce miss)\n", .{req.grid_id});
            var tmp_renderer = renderer;
            tmp_renderer.deinit();
            _ = c.DestroyWindow(hwnd);
            return .obsolete;
        }
        // is_pending_close: should have been filtered by the
        // WM_APP_CREATE_EXTERNAL_WINDOW blocked-skip path. Reaching
        // here means we got dequeued before close ran — also a bug.
        // Same teardown response.
        app.mu.unlock(core.clock.io());
        if (applog.isEnabled()) applog.appLog("[win] createExternalWindowOnUIThread: pending-close entry for grid_id={d} still in map; aborting (close not yet completed)\n", .{req.grid_id});
        var tmp_renderer = renderer;
        tmp_renderer.deinit();
        _ = c.DestroyWindow(hwnd);
        return .retry;
    }

    // Store external window. Heap-allocate the ExternalWindow so its address
    // never moves when external_windows (AutoHashMapUnmanaged(i64,
    // *ExternalWindow)) rehashes -- rehashing only relocates the stored
    // pointer, never the pointee. See W-H2 in the fix-plan doc.
    const ext_window_ptr = app.alloc.create(app_mod.ExternalWindow) catch |e| {
        if (applog.isEnabled()) applog.appLog("[win] failed to allocate external window: {any}\n", .{e});
        app.mu.unlock(core.clock.io());
        var tmp_renderer = renderer;
        tmp_renderer.deinit();
        _ = c.DestroyWindow(hwnd);
        return .retry;
    };
    ext_window_ptr.* = app_mod.ExternalWindow{
        .hwnd = hwnd.?,
        .window_wake_cookie = app_mod.nextWindowWakeCookie(),
        .win_id = req.win,
        .renderer = renderer,
        .surface = .{ .rows = req.rows, .cols = req.cols },
        .is_float_external = is_float,
    };
    if (!window_mod.installWindowWakeCookie(hwnd.?, ext_window_ptr.window_wake_cookie)) {
        app.mu.unlock(core.clock.io());
        ext_window_ptr.tbs.deinit(app.alloc);
        app.alloc.destroy(ext_window_ptr);
        var tmp_renderer = renderer;
        tmp_renderer.deinit();
        _ = c.DestroyWindow(hwnd);
        return .retry;
    }

    // If onFlushBegin already ran, this HWND was absent from its surface scan.
    // Open a write bracket before publishing the map entry; pending seed rows
    // and all later callbacks then land in the same set committed by
    // onFlushEnd. A new TBS always has free sets, so failure here is allocation
    // pressure and the retained lifecycle request must retry.
    if (app.core_flush_active.load(.acquire) and !ext_window_ptr.tbs.beginFlush(app.alloc)) {
        app.mu.unlock(core.clock.io());
        ext_window_ptr.tbs.deinit(app.alloc);
        app.alloc.destroy(ext_window_ptr);
        var tmp_renderer = renderer;
        tmp_renderer.deinit();
        _ = c.DestroyWindow(hwnd);
        return .retry;
    }

    app.external_windows.put(app.alloc, req.grid_id, ext_window_ptr) catch |e| {
        if (applog.isEnabled()) applog.appLog("[win] failed to store external window: {any}\n", .{e});
        app.mu.unlock(core.clock.io());
        ext_window_ptr.tbs.deinit(app.alloc);
        app.alloc.destroy(ext_window_ptr);
        var tmp_renderer = renderer;
        tmp_renderer.deinit();
        _ = c.DestroyWindow(hwnd);
        return .retry;
    };

    // If msg_history window was just created/shown, reposition msg_show window below it
    if (is_msg_history) {
        if (app.external_windows.get(app_mod.MESSAGE_GRID_ID)) |msg_win| {
            var history_rect: c.RECT = undefined;
            var msg_rect: c.RECT = undefined;
            if (c.GetWindowRect(hwnd, &history_rect) != 0 and c.GetWindowRect(msg_win.hwnd, &msg_rect) != 0) {
                const msg_width = msg_rect.right - msg_rect.left;
                const target_rect = app.getExtFloatTargetRect();
                const new_x = target_rect.right - msg_width - 10;
                const new_y = history_rect.bottom + 4;
                // Defer SetWindowPos to after lock release
                deferred_setpos = .{
                    .hwnd = msg_win.hwnd,
                    .hwnd_insert_after = null,
                    .x = new_x,
                    .y = new_y,
                    .flags = c.SWP_NOSIZE | c.SWP_NOZORDER | c.SWP_NOACTIVATE,
                };
            }
        }
    }

    // Set last_cursor_grid to this grid
    app.last_cursor_grid = req.grid_id;

    // Set App pointer as user data for WndProc access
    app_mod.setApp(hwnd.?, app);

    if (app.external_windows.get(req.grid_id)) |ext_win| {
        if (!applyPendingExternalVerticesLocked(app, req.grid_id, ext_win) and applog.isEnabled()) {
            applog.appLog("[win] pending external vertex apply OOM; retaining transaction grid_id={d}\n", .{req.grid_id});
        }
        _ = c.InvalidateRect(ext_win.hwnd, null, 0);
    }

    if (applog.isEnabled()) applog.appLog("[win] created external window hwnd={*} for grid_id={d}\n", .{ hwnd, req.grid_id });

    // For cmdline window: if there's a confirm/prompt dialog visible, put message BELOW cmdline
    // This is needed because confirm dialog is shown before cmdline window is created
    if (is_cmdline) {
        if (app.message_window) |msg_win| {
            const msg_kind = msg_win.kind[0..msg_win.kind_len];
            const is_confirm_visible = std.mem.eql(u8, msg_kind, "confirm") or
                std.mem.eql(u8, msg_kind, "confirm_sub") or
                std.mem.eql(u8, msg_kind, "return_prompt");
            if (is_confirm_visible) {
                // Defer SetWindowPos to after lock release
                deferred_setpos_cmdline = .{
                    .hwnd = msg_win.hwnd,
                    .hwnd_insert_after = hwnd, // cmdline hwnd
                    .x = 0,
                    .y = 0,
                    .flags = c.SWP_NOMOVE | c.SWP_NOSIZE | c.SWP_NOACTIVATE,
                };
            }
        }
    }

    app.mu.unlock(core.clock.io());

    // Register the OLE drop target outside the lock: RegisterDragDrop is a COM
    // call and must not run with app.mu held. Registration is what makes the
    // drag cursor show that a drop here inserts a path rather than opening the
    // file; the DragAcceptFiles above stays as the fallback if it fails.
    if (is_cmdline) {
        ext_window_ptr.drop_target = drop_target.register(app, hwnd, true);
    }

    // Now call SetWindowPos outside the lock to avoid deadlock
    if (deferred_setpos) |sp| {
        _ = c.SetWindowPos(sp.hwnd, sp.hwnd_insert_after, sp.x, sp.y, 0, 0, sp.flags);
        if (applog.isEnabled()) applog.appLog("[win] repositioned msg_show below msg_history: ({d},{d})\n", .{ sp.x, sp.y });
    }
    if (deferred_setpos_cmdline) |sp| {
        _ = c.SetWindowPos(sp.hwnd, sp.hwnd_insert_after, sp.x, sp.y, 0, 0, sp.flags);
        if (applog.isEnabled()) applog.appLog("[win] put message window below cmdline (cmdline created)\n", .{});
    }

    // A message float routinely appears right under a stationary pointer, and
    // no WM_MOUSEMOVE follows one that never moves. Seed the hover state from
    // the cursor's actual position, after the deferred repositioning above has
    // settled the window's final rect.
    var window_rect: c.RECT = undefined;
    var cursor: c.POINT = undefined;
    if (c.GetWindowRect(hwnd, &window_rect) != 0 and c.GetCursorPos(&cursor) != 0) {
        if (c.PtInRect(&window_rect, cursor) != 0) {
            setMsgHover(app, ext_window_ptr, req.grid_id, true);
        }
    }

    // Activate this external window
    _ = c.SetForegroundWindow(hwnd);
    return .published;
}

pub fn onExternalWindowClose(ctx: ?*anyopaque, grid_id: i64) callconv(.c) void {
    const app: *App = @ptrCast(@alignCast(ctx.?));
    if (applog.isEnabled()) applog.appLog("[win] on_external_window_close: grid_id={d}\n", .{grid_id});

    // Mark the window as pending close (don't remove from HashMap yet to avoid use-after-free)
    // The actual removal and cleanup will happen on the UI thread in closeExternalWindowOnUIThread.
    //
    // Drop any idle pending_external_windows entries for this grid_id. They
    // belong to the OLD session. An entry actively owned by the UI create
    // handler cannot be removed without losing its cancellation state; mark it
    // instead, and the handler will tear down a window published after close.
    // The seq tag on each entry is unique so the old WM_APP_CREATE
    // message — which carries the removed entry's seq in lParam —
    // will find no match and be a no-op when the UI thread processes it.
    app.mu.lockUncancelable(core.clock.io());
    const main_hwnd = app.hwnd;
    if (app.external_windows.get(grid_id)) |ext_win| {
        ext_win.is_pending_close = true;
        app.external_close_drain_needed = true;
    }
    var i: usize = 0;
    var removed: usize = 0;
    var cancelled: usize = 0;
    while (i < app.pending_external_windows.items.len) {
        if (app.pending_external_windows.items[i].grid_id == grid_id) {
            if (app.pending_external_windows.items[i].create_in_progress) {
                // The UI thread owns a snapshot of this entry. Preserve its
                // storage until that create unwinds, but make publication
                // self-cancelling even if close ran before the map put.
                app.pending_external_windows.items[i].cancel_requested = true;
                cancelled += 1;
                i += 1;
            } else {
                _ = app.pending_external_windows.orderedRemove(i);
                removed += 1;
            }
        } else {
            i += 1;
        }
    }
    // Drop any pending_external_verts entry for this grid_id too, for the
    // same reason as pending_external_windows above: it belongs to the OLD
    // session/window and must not seed a NEW window that later reuses this
    // grid_id (e.g. after :restart or a reconnect — nvim hands out grid_ids
    // from a fresh, low-numbered space that can collide with a stale entry
    // left behind here). See resetSessionState (src/core/nvim_core.zig),
    // which fires this callback for every known external grid on reset.
    var j: usize = 0;
    var verts_removed: usize = 0;
    while (j < app.pending_external_verts.items.len) {
        if (app.pending_external_verts.items[j].grid_id == grid_id) {
            var removed_pv = app.pending_external_verts.orderedRemove(j);
            removed_pv.deinit(app.alloc);
            verts_removed += 1;
        } else {
            j += 1;
        }
    }
    app.mu.unlock(core.clock.io());
    if (removed > 0 and applog.isEnabled()) {
        applog.appLog("[win] on_external_window_close: dropped {d} stale pending request(s) for grid_id={d}\n", .{ removed, grid_id });
    }
    if (cancelled > 0 and applog.isEnabled()) {
        applog.appLog("[win] on_external_window_close: cancelled {d} in-progress request(s) for grid_id={d}\n", .{ cancelled, grid_id });
    }
    if (verts_removed > 0 and applog.isEnabled()) {
        applog.appLog("[win] on_external_window_close: dropped {d} stale pending_external_verts entr(y/ies) for grid_id={d}\n", .{ verts_removed, grid_id });
    }

    // Post message to UI thread to do the actual close
    // (DestroyWindow must be called from the thread that created the window)
    if (main_hwnd) |hwnd| {
        if (c.PostMessageW(hwnd, app_mod.WM_APP_CLOSE_EXTERNAL_WINDOW, @bitCast(grid_id), 0) == 0) {
            // Queue exhaustion means the message loop already has work. Its
            // deferred-service pass consumes external_close_drain_needed even
            // when the main HWND is hidden and no WM_PAINT is generated.
            _ = c.InvalidateRect(hwnd, null, c.FALSE);
        }
    }
}

pub fn closePendingExternalWindowsOnUIThread(app: *App) void {
    while (true) {
        var grid_id: ?i64 = null;
        app.mu.lockUncancelable(core.clock.io());
        if (!app.external_close_drain_needed) {
            app.mu.unlock(core.clock.io());
            return;
        }
        var it = app.external_windows.iterator();
        while (it.next()) |entry| {
            const ew = entry.value_ptr.*;
            if (ew.is_pending_close and ew.paint_ref_count == 0) {
                grid_id = entry.key_ptr.*;
                break;
            }
        }
        if (grid_id == null) app.external_close_drain_needed = false;
        app.mu.unlock(core.clock.io());

        const id = grid_id orelse return;
        closeExternalWindowOnUIThread(app, id);
    }
}

/// Actually close external window (must be called on UI thread)
/// Removes from HashMap and destroys the window
pub fn closeExternalWindowOnUIThread(app: *App, grid_id: i64) void {
    if (applog.isEnabled()) applog.appLog("[win] closeExternalWindowOnUIThread: grid_id={d}\n", .{grid_id});

    // Check if paint is in progress - if so, defer the close
    // DXGI operations can pump messages, so close could be triggered during paint
    app.mu.lockUncancelable(core.clock.io());
    if (app.external_windows.get(grid_id)) |ew| {
        if (ew.paint_ref_count > 0) {
            // Paint is in progress - just mark as pending and let paint trigger close when done
            ew.is_pending_close = true;
            if (applog.isEnabled()) applog.appLog("[win] closeExternalWindowOnUIThread: paint in progress (ref={d}), deferring close\n", .{ew.paint_ref_count});
            app.mu.unlock(core.clock.io());
            return;
        }
    }

    // Save window position before removing (for tab switch restoration)
    if (app.external_windows.get(grid_id)) |ew| {
        if (ew.hwnd) |hwnd| {
            var rect: c.RECT = undefined;
            if (c.GetWindowRect(hwnd, &rect) != 0) {
                // Evict oldest entry (smallest grid_id) when inserting a new key
                // to bound memory growth (matches macOS 100-entry cap).
                if (app.saved_external_window_positions.getPtr(grid_id) == null and
                    app.saved_external_window_positions.count() > 100)
                {
                    var min_key: i64 = std.math.maxInt(i64);
                    var pos_it = app.saved_external_window_positions.iterator();
                    while (pos_it.next()) |e| {
                        if (e.key_ptr.* < min_key) min_key = e.key_ptr.*;
                    }
                    if (min_key != std.math.maxInt(i64)) {
                        _ = app.saved_external_window_positions.remove(min_key);
                    }
                }
                app.saved_external_window_positions.put(app.alloc, grid_id, .{
                    .x = rect.left,
                    .y = rect.top,
                }) catch {};
                if (applog.isEnabled()) applog.appLog("[win] saved position for grid_id={d}: ({d},{d})\n", .{ grid_id, rect.left, rect.top });
            }
        }
    }

    // Remove from external_windows HashMap and get the entry
    const entry = app.external_windows.fetchRemove(grid_id);
    // Evict the scrollbar viewport cache entry for this grid; nothing else
    // removes it once the grid is gone (a dead grid_id is never re-queried),
    // so long sessions would otherwise accumulate one stale entry per
    // closed external window.
    _ = app.viewport_cache.remove(grid_id);
    app.mu.unlock(core.clock.io());

    if (entry) |e| {
        const ext_win = e.value; // *ExternalWindow (the heap box), not a value copy

        // Check if IME overlay was parented to this external window
        // If so, destroy it and reset the handle so main window can create a new one
        app.mu.lockUncancelable(core.clock.io());
        if (app.ime_overlay_hwnd) |overlay| {
            const parent = c.GetParent(overlay);
            if (parent == ext_win.hwnd) {
                _ = c.DestroyWindow(overlay);
                app.ime_overlay_hwnd = null;
                if (applog.isEnabled()) applog.appLog("[win] destroyed IME overlay parented to external window\n", .{});
            }
        }
        app.mu.unlock(core.clock.io());

        // Revoke before deinit's DestroyWindow: OLE holds a reference to the
        // target for as long as the window is registered.
        if (ext_win.drop_target) |target| {
            drop_target.revoke(ext_win.hwnd, @ptrCast(@alignCast(target)));
            ext_win.drop_target = null;
        }

        // deinit handles DestroyWindow and resource cleanup
        ext_win.deinit(app.alloc, &app.row_vb_budget);
        if (applog.isEnabled()) applog.appLog("[win] destroyed external window hwnd={*}\n", .{ext_win.hwnd});
        app.alloc.destroy(ext_win); // free the heap box itself; deinit() only frees its owned sub-resources
    }

    // Note: We intentionally do NOT remove pending_external_verts here because
    // the pending verts might belong to a new window with the same grid_id that
    // was created after the close event was queued but before this handler ran.
    // (onExternalWindowClose DOES remove them, and that is safe: it runs on the
    // core thread, and verts for a re-created same-grid_id window are enqueued
    // on that same thread strictly AFTER the close callback — an ordering this
    // UI-thread handler, which runs behind a posted message, cannot rely on.)
    //
    // Likewise we do NOT remove pending_external_windows entries by grid_id.
    // The new session can legitimately enqueue a same-grid_id create after
    // we posted WM_APP_CLOSE_EXTERNAL_WINDOW, and we cannot tell those
    // apart from old-session entries by grid_id alone.
    //
    // Wake any pending creates that were blocked by our is_pending_close
    // entry. The WM_APP_CREATE_EXTERNAL_WINDOW handler skips queue items
    // whose grid_id is held by an is_pending_close entry (to avoid
    // racing with paint that still holds a pointer into ext_win); now
    // that we have removed the old entry from external_windows, those
    // items are safe to retry. Wake the pending queue through the shared
    // helper so a queue-full PostMessageW failure gets a timer fallback.
    if (entry != null) {
        if (applog.isEnabled()) applog.appLog("[win] closeExternalWindowOnUIThread: waking pending creates after grid_id={d} close\n", .{grid_id});
        wakePendingExternalWindowCreates(app);
    }
}

pub fn onCursorGridChanged(ctx: ?*anyopaque, grid_id: i64) callconv(.c) void {
    const app: *App = @ptrCast(@alignCast(ctx.?));
    if (applog.isEnabled()) applog.appLog("[win] on_cursor_grid_changed: grid_id={d}\n", .{grid_id});

    // Update last_cursor_grid synchronously so position calculations done by
    // other posted messages (e.g. WM_APP_MSG_SHOW -> updateMiniWindows) see
    // the new value even if those messages are processed by the UI thread
    // before WM_APP_CURSOR_GRID_CHANGED. Without this, a typical
    // `:echo` from cmdline produces this race:
    //   1. cmdline_hide moves cursor from grid -100 (cmdline) to grid 2
    //   2. msg_show fires on_msg_show -> Windows posts WM_APP_MSG_SHOW
    //   3. UI thread runs WM_APP_MSG_SHOW -> updateMiniWindows reads
    //      app.last_cursor_grid (still -100) -> anchors mini to the
    //      closing cmdline ext_win's rect
    //   4. on_cursor_grid_changed fires -> posts WM_APP_CURSOR_GRID_CHANGED
    //   5. UI thread updates app.last_cursor_grid = 2 (too late)
    app.mu.lockUncancelable(core.clock.io());
    app.last_cursor_grid = grid_id;
    app.mu.unlock(core.clock.io());

    // Post message to UI thread to handle window activation
    if (app.hwnd) |main_hwnd| {
        _ = c.PostMessageW(main_hwnd, app_mod.WM_APP_CURSOR_GRID_CHANGED, @bitCast(grid_id), 0);
    }
}

// External window class name
pub const external_window_class_name: [:0]const u16 = std.unicode.utf8ToUtf16LeStringLiteral("ZonvieExternalWin");
pub var external_window_class_registered: bool = false;

/// Register the external window class (call once before creating external windows)
pub fn ensureExternalWindowClassRegistered() bool {
    if (external_window_class_registered) return true;

    var wc: c.WNDCLASSEXW = std.mem.zeroes(c.WNDCLASSEXW);
    wc.cbSize = @sizeOf(c.WNDCLASSEXW);
    wc.style = c.CS_HREDRAW | c.CS_VREDRAW;
    wc.lpfnWndProc = ExternalWndProc;
    wc.hInstance = c.GetModuleHandleW(null);
    wc.hCursor = c.LoadCursorW(null, @ptrFromInt(32512)); // IDC_ARROW
    wc.hbrBackground = null;
    wc.cbWndExtra = @sizeOf(isize);
    wc.lpszClassName = @ptrCast(external_window_class_name.ptr);

    if (c.RegisterClassExW(&wc) == 0) {
        if (applog.isEnabled()) applog.appLog("[win] Failed to register external window class\n", .{});
        return false;
    }

    external_window_class_registered = true;
    if (applog.isEnabled()) applog.appLog("[win] Registered external window class\n", .{});
    return true;
}

pub export fn ExternalWndProc(
    hwnd: c.HWND,
    msg: c.UINT,
    wParam: c.WPARAM,
    lParam: c.LPARAM,
) callconv(.winapi) c.LRESULT {
    switch (msg) {
        // Keep the acrylic backdrop blurred when the window is inactive by
        // forcing DWM to treat it as active (matches the main window).
        c.WM_NCACTIVATE => {
            if (app_mod.getApp(hwnd)) |app| {
                if (app.config.window.blur) {
                    return c.DefWindowProcW(hwnd, msg, 1, lParam);
                }
            }
            return c.DefWindowProcW(hwnd, msg, wParam, lParam);
        },
        0x02E0 => { // WM_DPICHANGED
            if (app_mod.getApp(hwnd)) |app| {
                // Device/D2D/renderer creation in WM_APP_DEVICE_LOST_RECOVER
                // can pump messages and reenter this handler on the same UI
                // thread while that handler still holds app.mu/atlas.mu for
                // parts of its own work — proceeding here could self-deadlock
                // the same way main window's WM_PAINT/WM_SIZE/WM_DPICHANGED
                // would without their guard. Apply only the suggested HWND
                // rect; recovery replays this window's current DPI and client
                // size before publishing the new renderer.
                if (app.device_lost_recovering) {
                    const suggested: *const c.RECT = @ptrFromInt(@as(usize, @bitCast(lParam)));
                    _ = c.SetWindowPos(
                        hwnd,
                        null,
                        suggested.left,
                        suggested.top,
                        suggested.right - suggested.left,
                        suggested.bottom - suggested.top,
                        c.SWP_NOZORDER | c.SWP_NOACTIVATE,
                    );
                    return 0;
                }
                const new_dpi: u32 = @as(u32, @intCast(wParam & 0xFFFF)); // LOWORD
                if (applog.isEnabled()) applog.appLog("[win] ExternalWndProc WM_DPICHANGED hwnd={*} new_dpi={d}\n", .{ hwnd, new_dpi });

                app.mu.lockUncancelable(core.clock.io());
                var it = app.external_windows.iterator();
                while (it.next()) |entry| {
                    if (entry.value_ptr.*.hwnd == hwnd) {
                        // Update ONLY this window's own scrollbar-geometry
                        // DPI. Do NOT call atlas.updateDpi()/
                        // invalidate_glyph_cache here: app.atlas is a single
                        // instance shared by the main window and every
                        // external window (see MED-5 in the fix-plan doc)
                        // -- rescaling it here based on one external
                        // window's monitor would corrupt every other
                        // window's glyph rendering on their next repaint.
                        entry.value_ptr.*.dpi_scale = @as(f32, @floatFromInt(new_dpi)) / 96.0;
                        break;
                    }
                }
                app.mu.unlock(core.clock.io());

                // Resize this window to the suggested rect from WM_DPICHANGED
                // so it doesn't end up the wrong physical size after the move.
                const suggested: *const c.RECT = @ptrFromInt(@as(usize, @bitCast(lParam)));
                _ = c.SetWindowPos(
                    hwnd,
                    null,
                    suggested.left,
                    suggested.top,
                    suggested.right - suggested.left,
                    suggested.bottom - suggested.top,
                    c.SWP_NOZORDER | c.SWP_NOACTIVATE,
                );
            }
            return 0;
        },
        c.WM_PAINT => {
            if (applog.isEnabled()) applog.appLog("[win] ExternalWndProc WM_PAINT hwnd={*}\n", .{hwnd});
            if (app_mod.getApp(hwnd)) |app| {
                app.mu.lockUncancelable(core.clock.io());
                var retry_it = app.external_windows.valueIterator();
                while (retry_it.next()) |ext_win_ptr| {
                    if (ext_win_ptr.*.hwnd == hwnd) {
                        ext_win_ptr.*.paint_retry_deadline_ms = 0;
                        ext_win_ptr.*.paint_retry.paintStarted();
                        break;
                    }
                }
                app.mu.unlock(core.clock.io());
                if (app.wm_paint_in_progress or
                    app.in_present_shader_animation_frame or
                    app.glow_prepare_in_progress or
                    app.device_lost_recovering or
                    app.main_resize_in_progress or
                    app.main_dpi_change_in_progress)
                {
                    // Reentrant WM_PAINT on the shared App/Renderer — see
                    // the identical guard in window.zig's WM_PAINT handler
                    // for why this must not call into g.lockContext().
                    var ps_reentrant: c.PAINTSTRUCT = undefined;
                    _ = c.BeginPaint(hwnd, &ps_reentrant);
                    _ = c.EndPaint(hwnd, &ps_reentrant);
                    app.wm_paint_reinvalidate_all = true;
                    return 0;
                }
                app.wm_paint_in_progress = true;
                defer {
                    app.wm_paint_in_progress = false;
                    _ = app.finishActiveOperation();
                }
                // Check if this is the message window
                if (app.message_window) |msg_win| {
                    if (msg_win.hwnd == hwnd) {
                        if (applog.isEnabled()) applog.appLog("[win] ExternalWndProc calling paintMessageWindow\n", .{});
                        messages.paintMessageWindow(hwnd, app);
                        return 0;
                    }
                }
                // Check if this is a mini window
                inline for ([_]app_mod.MiniWindowId{ .showmode, .showcmd, .ruler }) |id| {
                    const idx = @intFromEnum(id);
                    if (app.mini_windows[idx].hwnd) |mini_hwnd| {
                        if (mini_hwnd == hwnd) {
                            if (applog.isEnabled()) applog.appLog("[win] ExternalWndProc calling paintMiniWindow for {s}\n", .{@tagName(id)});
                            messages.paintMiniWindow(hwnd, app);
                            return 0;
                        }
                    }
                }
                if (applog.isEnabled()) applog.appLog("[win] ExternalWndProc calling paintExternalWindow\n", .{});
                paintExternalWindow(hwnd, app);
            } else {
                if (applog.isEnabled()) applog.appLog("[win] ExternalWndProc getApp returned null\n", .{});
                // Must call BeginPaint/EndPaint even if we don't draw
                var ps: c.PAINTSTRUCT = undefined;
                _ = c.BeginPaint(hwnd, &ps);
                _ = c.EndPaint(hwnd, &ps);
            }
            return 0;
        },
        c.WM_CLOSE => {
            // Don't destroy - just hide or let the core handle it
            _ = c.ShowWindow(hwnd, c.SW_HIDE);
            return 0;
        },
        c.WM_SETTINGCHANGE => {
            // OS theme toggle — defer to the shared helper, which also
            // filters out caption-less popups via WS_CAPTION. Non-color
            // settings broadcasts fall through to DefWindowProcW so the OS
            // can do its standard handling.
            if (window_mod.handleImmersiveColorSet(hwnd, lParam)) return 0;
            return c.DefWindowProcW(hwnd, msg, wParam, lParam);
        },
        c.WM_THEMECHANGED => {
            // Best-effort titlebar refresh, then fall through to the OS so
            // the standard uxtheme handling still runs (and caption-less
            // popups are not silently swallowed).
            _ = window_mod.handleThemeChanged(hwnd);
            return c.DefWindowProcW(hwnd, msg, wParam, lParam);
        },
        c.WM_DESTROY => {
            // Clear userdata
            _ = c.SetWindowLongPtrW(hwnd, c.GWLP_USERDATA, 0);
            return 0;
        },
        // Forward keyboard input to core (same as main window)
        c.WM_KEYDOWN, c.WM_SYSKEYDOWN => {
            if (app_mod.getApp(hwnd)) |app| {
                const vk: u32 = @intCast(wParam);
                const mods = input.queryMods();
                const keycode: u32 = input.KEYCODE_WINVK_FLAG | vk;
                const scancode: u32 = @intCast((@as(u32, @intCast(lParam)) >> 16) & 0xFF);

                // Check if IME is composing
                app.mu.lockUncancelable(core.clock.io());
                const ime_composing = app.ime_composing;
                app.mu.unlock(core.clock.io());

                // Skip VK_RETURN and VK_BACK when IME is composing to avoid double-input
                if (ime_composing and (vk == c.VK_RETURN or vk == c.VK_BACK)) {
                    // Let IME handle Enter/Backspace
                    return c.DefWindowProcW(hwnd, msg, wParam, lParam);
                }

                // Special keys (arrows, function keys, etc.) go through send_key_event
                if (input.isSpecialVk(vk)) {
                    input.sendKeyEventToCore(app, keycode, mods, null, null);
                    return 0;
                }

                // Ctrl/Alt combos: use toUnicodePairUtf8 to get character for <C-x> etc.
                if ((mods & (input.MOD_CTRL | input.MOD_ALT)) != 0) {
                    var tmp_chars: [16]u16 = undefined;
                    var tmp_ign: [16]u16 = undefined;
                    var out_chars: [8]u8 = undefined;
                    var out_ign: [8]u8 = undefined;

                    const pair = input.toUnicodePairUtf8(
                        vk,
                        scancode,
                        &tmp_chars,
                        &tmp_ign,
                        &out_chars,
                        &out_ign,
                    );

                    input.sendKeyEventToCore(app, keycode, mods, pair.chars, pair.ign);
                    return 0;
                }
                // Otherwise let WM_CHAR handle normal text
            }
        },
        c.WM_CHAR, c.WM_SYSCHAR => {
            if (app_mod.getApp(hwnd)) |app| {
                const mods = input.queryMods();

                // Skip if Ctrl/Alt (handled in WM_KEYDOWN)
                if ((mods & (input.MOD_CTRL | input.MOD_ALT)) != 0) {
                    return 0;
                }

                const ch0: u16 = @as(u16, @intCast(wParam));

                // Skip control characters handled by WM_KEYDOWN
                if (ch0 == 0x08 or ch0 == 0x09 or ch0 == 0x0D or ch0 == 0x1B) {
                    app.pending_high_surrogate_char = 0;
                    return 0;
                }

                // Pair surrogate halves for non-BMP characters (emoji etc).
                var tmp: [8]u8 = undefined;
                var s: ?[]const u8 = null;
                if (ch0 >= 0xD800 and ch0 <= 0xDBFF) {
                    app.pending_high_surrogate_char = ch0;
                    return 0;
                } else if (ch0 >= 0xDC00 and ch0 <= 0xDFFF) {
                    const hi = app.pending_high_surrogate_char;
                    app.pending_high_surrogate_char = 0;
                    if (hi == 0) return 0;
                    s = input.utf16UnitsToUtf8(&tmp, hi, ch0);
                } else {
                    app.pending_high_surrogate_char = 0;
                    s = input.utf16UnitsToUtf8(&tmp, ch0, null);
                }

                if (s) |text| {
                    input.sendKeyEventToCore(app, 0, mods, text, null);
                }
                return 0;
            }
        },
        c.WM_SIZE => {
            if (app_mod.getApp(hwnd)) |app| {
                // See WM_DPICHANGED's identical guard above — device-lost
                // recovery can reenter this handler on the same UI thread
                // while still holding app.mu/atlas.mu for parts of its own
                // work.
                if (app.device_lost_recovering) {
                    scheduleExternalSizeReplay(hwnd, app);
                    return 0;
                }
                // Get new client area size
                var rc: c.RECT = undefined;
                _ = c.GetClientRect(hwnd, &rc);
                const client_w: u32 = @intCast(rc.right - rc.left);
                const client_h: u32 = @intCast(rc.bottom - rc.top);

                if (client_w == 0 or client_h == 0) {
                    return 0;
                }

                app.mu.lockUncancelable(core.clock.io());

                // Find grid_id and ext_window for this hwnd
                var grid_id: ?i64 = null;
                var suppress = false;
                if (findExternalWindowByHwndLocked(app, hwnd)) |hit| {
                    grid_id = hit.grid_id;
                    suppress = hit.win.suppress_resize_callback;
                }

                const cell_w = app.cell_w_px;
                const cell_h = app.rowHeightPx();
                const corep = app.corep;

                app.mu.unlock(core.clock.io());

                // Skip tryResizeGrid when window is being resized programmatically
                // (from Neovim grid_resize). Only report back on user-initiated resizes.
                if (suppress) return 0;

                if (grid_id) |gid| {
                    if (cell_w > 0 and cell_h > 0) {
                        const new_cols: u32 = client_w / cell_w;
                        const new_rows: u32 = client_h / cell_h;

                        if (new_rows > 0 and new_cols > 0) {
                            if (applog.isEnabled()) applog.appLog("[win] external WM_SIZE grid_id={d} client=({d},{d}) cell=({d},{d}) -> rows={d} cols={d}\n", .{
                                gid, client_w, client_h, cell_w, cell_h, new_rows, new_cols,
                            });
                            app_mod.zonvie_core_try_resize_grid(corep, gid, new_rows, new_cols);
                        }
                    }
                }
            }
            return 0;
        },
        c.WM_MOUSEWHEEL => {
            if (app_mod.getApp(hwnd)) |app| {
                // Find grid_id and ext_window for this hwnd
                app.mu.lockUncancelable(core.clock.io());
                var grid_id: ?i64 = null;
                var ext_window: ?*app_mod.ExternalWindow = null;
                if (findExternalWindowByHwndLocked(app, hwnd)) |hit| {
                    grid_id = hit.grid_id;
                    ext_window = hit.win;
                }
                app.mu.unlock(core.clock.io());

                if (grid_id != null and ext_window != null) {
                    input.handleMouseWheel(hwnd, wParam, lParam, app, grid_id.?, false);

                    // Show scrollbar on scroll if in scroll mode
                    if (app.config.scrollbar.enabled and app.config.scrollbar.isScroll()) {
                        scrollbar.showScrollbarForExternal(hwnd, ext_window.?);
                        // Auto-hide after delay
                        const delay_ms: c.UINT = @intFromFloat(app.config.scrollbar.delay * 1000.0);
                        _ = c.SetTimer(hwnd, app_mod.TIMER_SCROLLBAR_AUTOHIDE, delay_ms, null);
                    }
                }
                return 0;
            }
        },

        c.WM_MOUSEHWHEEL => {
            if (app_mod.getApp(hwnd)) |app| {
                app.mu.lockUncancelable(core.clock.io());
                var grid_id: ?i64 = null;
                var ext_window: ?*app_mod.ExternalWindow = null;
                if (findExternalWindowByHwndLocked(app, hwnd)) |hit| {
                    grid_id = hit.grid_id;
                    ext_window = hit.win;
                }
                app.mu.unlock(core.clock.io());

                if (grid_id != null and ext_window != null) {
                    input.handleMouseWheel(hwnd, wParam, lParam, app, grid_id.?, true);
                }
                return 0;
            }
        },

        // --- Scrollbar mouse handling for external windows ---
        c.WM_LBUTTONDOWN => {
            if (app_mod.getApp(hwnd)) |app| {
                const x: i32 = @bitCast(@as(u32, @intCast(lParam & 0xFFFF)));
                const y: i32 = @bitCast(@as(u32, @intCast((lParam >> 16) & 0xFFFF)));

                app.mu.lockUncancelable(core.clock.io());
                var grid_id: ?i64 = null;
                var ext_window: ?*app_mod.ExternalWindow = null;
                if (findExternalWindowByHwndLocked(app, hwnd)) |hit| {
                    grid_id = hit.grid_id;
                    ext_window = hit.win;
                }
                app.mu.unlock(core.clock.io());

                if (grid_id != null and ext_window != null) {
                    // Claim the press so the copy button's release is not
                    // interpreted as a scrollbar or grid interaction.
                    if (hitTestCopyButton(hwnd, app, grid_id.?, x, y)) return 0;
                    if (scrollbar.scrollbarMouseDownForExternal(hwnd, app, ext_window.?, grid_id.?, x, y)) {
                        return 0;
                    }
                }
            }
        },

        c.WM_CAPTURECHANGED => {
            // WM_LBUTTONUP never arrives once capture is stolen, and that is the
            // only place the scrollbar track repeat is killed — without this it
            // keeps issuing page scrolls indefinitely.
            if (app_mod.getApp(hwnd)) |app| {
                app.mu.lockUncancelable(core.clock.io());
                var it = app.external_windows.iterator();
                while (it.next()) |entry| {
                    const ew = entry.value_ptr.*;
                    if (ew.hwnd != hwnd) continue;
                    // The drag is cancelled rather than committed: its pending
                    // line was never confirmed by a mouse-up. Leaving
                    // scrollbar_dragging set would make every later
                    // button-up-less WM_MOUSEMOVE scroll the buffer.
                    if (ew.scrollbar_dragging) {
                        ew.scrollbar_dragging = false;
                        ew.scrollbar_pending_line = -1;
                    }
                    if (ew.scrollbar_repeat_timer != 0 or ew.scrollbar_repeat_dir != 0) {
                        _ = c.KillTimer(hwnd, app_mod.TIMER_SCROLLBAR_REPEAT);
                        ew.scrollbar_repeat_timer = 0;
                        ew.scrollbar_repeat_dir = 0;
                    }
                    break;
                }
                app.mu.unlock(core.clock.io());
            }
            return 0;
        },

        c.WM_LBUTTONUP => {
            if (app_mod.getApp(hwnd)) |app| {
                const x: i32 = @bitCast(@as(u32, @intCast(lParam & 0xFFFF)));
                const y: i32 = @bitCast(@as(u32, @intCast((lParam >> 16) & 0xFFFF)));

                app.mu.lockUncancelable(core.clock.io());
                var grid_id: ?i64 = null;
                var ext_window: ?*app_mod.ExternalWindow = null;
                if (findExternalWindowByHwndLocked(app, hwnd)) |hit| {
                    grid_id = hit.grid_id;
                    ext_window = hit.win;
                }
                app.mu.unlock(core.clock.io());

                if (grid_id != null and ext_window != null) {
                    if (hitTestCopyButton(hwnd, app, grid_id.?, x, y)) {
                        copyExternalSurfaceText(hwnd, app, grid_id.?);
                        return 0;
                    }
                    scrollbar.scrollbarMouseUpForExternal(hwnd, app, ext_window.?, grid_id.?);
                }
            }
        },

        c.WM_MOUSEMOVE => {
            if (app_mod.getApp(hwnd)) |app| {
                const x: i32 = @bitCast(@as(u32, @intCast(lParam & 0xFFFF)));
                const y: i32 = @bitCast(@as(u32, @intCast((lParam >> 16) & 0xFFFF)));

                app.mu.lockUncancelable(core.clock.io());
                var grid_id: ?i64 = null;
                var ext_window: ?*app_mod.ExternalWindow = null;
                if (findExternalWindowByHwndLocked(app, hwnd)) |hit| {
                    grid_id = hit.grid_id;
                    ext_window = hit.win;
                }
                app.mu.unlock(core.clock.io());

                if (grid_id != null and ext_window != null) {
                    const ext_win = ext_window.?;

                    // Handle scrollbar dragging
                    if (ext_win.scrollbar_dragging) {
                        scrollbar.scrollbarMouseMoveForExternal(hwnd, app, ext_win, grid_id.?, y);
                        return 0;
                    }

                    // Copy-button hover: repaint only on a state change so an
                    // ordinary mouse move over the surface costs nothing.
                    const copy_hover = hitTestCopyButton(hwnd, app, grid_id.?, x, y);
                    if (copy_hover != ext_win.copy_button_hover) {
                        ext_win.copy_button_hover = copy_hover;
                        _ = c.InvalidateRect(hwnd, null, c.FALSE);
                    }

                    // The pointer is somewhere on the surface, copy button
                    // included — the message must not vanish under it.
                    setMsgHover(app, ext_win, grid_id.?, true);

                    // Check for scrollbar hover
                    if (app.config.scrollbar.enabled and app.config.scrollbar.isHover()) {
                        var client: c.RECT = undefined;
                        _ = c.GetClientRect(hwnd, &client);
                        const hit = scrollbar.scrollbarHitTestForExternal(app, grid_id.?, client.right, client.bottom, x, y, ext_win.dpi_scale);
                        if (hit != .none) {
                            if (!ext_win.scrollbar_hover) {
                                ext_win.scrollbar_hover = true;
                                scrollbar.showScrollbarForExternal(hwnd, ext_win);
                            }
                        } else {
                            if (ext_win.scrollbar_hover) {
                                ext_win.scrollbar_hover = false;
                                scrollbar.hideScrollbarForExternal(hwnd, app, ext_win);
                            }
                        }
                    }

                    // Track mouse for WM_MOUSELEAVE
                    var tme: c.TRACKMOUSEEVENT = .{
                        .cbSize = @sizeOf(c.TRACKMOUSEEVENT),
                        .dwFlags = c.TME_LEAVE,
                        .hwndTrack = hwnd,
                        .dwHoverTime = 0,
                    };
                    _ = c.TrackMouseEvent(&tme);
                }
            }
        },

        c.WM_DROPFILES => {
            // Only the cmdline window has DragAcceptFiles, so a drop here is
            // always a path insertion, whatever mode the editor reports.
            const hDrop: c.HDROP = @ptrFromInt(@as(usize, wParam));
            defer c.DragFinish(hDrop);
            if (app_mod.getApp(hwnd)) |app| window_mod.handleDroppedFiles(app, hDrop, true);
            return 0;
        },

        c.WM_MOUSELEAVE => {
            if (app_mod.getApp(hwnd)) |app| {
                app.mu.lockUncancelable(core.clock.io());
                var grid_id: ?i64 = null;
                var ext_window: ?*app_mod.ExternalWindow = null;
                if (findExternalWindowByHwndLocked(app, hwnd)) |hit| {
                    grid_id = hit.grid_id;
                    ext_window = hit.win;
                }
                app.mu.unlock(core.clock.io());

                if (ext_window) |ext_win| {
                    setMsgHover(app, ext_win, grid_id.?, false);
                    if (ext_win.copy_button_hover) {
                        ext_win.copy_button_hover = false;
                        _ = c.InvalidateRect(hwnd, null, c.FALSE);
                    }
                    ext_win.scrollbar_hover = false;
                    scrollbar.hideScrollbarForExternal(hwnd, app, ext_win);
                }
            }
        },

        app_mod.WM_APP_PAINT_RETRY_FALLBACK => {
            if (app_mod.getApp(hwnd)) |app| {
                const cookie = externalWakeCookie(hwnd);
                if (cookie == 0 or cookie != @as(usize, @bitCast(lParam))) return 0;
                if (app.device_lost_recovering) {
                    // Recovery will invalidate every successfully rebuilt
                    // surface. Keep this generation armed until that paint
                    // succeeds instead of touching recovery-held state here.
                    return 0;
                }
                var should_invalidate = false;
                app.mu.lockUncancelable(core.clock.io());
                var it = app.external_windows.valueIterator();
                while (it.next()) |ext_win_ptr| {
                    const ext_win = ext_win_ptr.*;
                    if (ext_win.hwnd == hwnd and
                        ext_win.window_wake_cookie == @as(usize, @bitCast(lParam)))
                    {
                        should_invalidate = ext_win.paint_retry.timerFired(@intCast(wParam));
                        if (should_invalidate) ext_win.paint_retry_deadline_ms = 0;
                        break;
                    }
                }
                app.mu.unlock(core.clock.io());
                if (should_invalidate) _ = c.InvalidateRect(hwnd, null, 0);
            }
            return 0;
        },

        app_mod.WM_APP_SIZE_REPLAY_FALLBACK => {
            const cookie = externalWakeCookie(hwnd);
            if (cookie != 0 and cookie == @as(usize, @bitCast(lParam))) {
                _ = c.SendMessageW(hwnd, c.WM_SIZE, 0, 0);
            }
            return 0;
        },

        c.WM_TIMER => {
            if (app_mod.getApp(hwnd)) |app| {
                // See WM_DPICHANGED's identical guard above.
                const timer_id = wParam;
                if (timer_id == app_mod.TIMER_EXTERNAL_SIZE_REPLAY) {
                    if (app.device_lost_recovering) {
                        scheduleExternalSizeReplay(hwnd, app);
                    } else {
                        _ = c.KillTimer(hwnd, app_mod.TIMER_EXTERNAL_SIZE_REPLAY);
                        _ = c.SendMessageW(hwnd, c.WM_SIZE, 0, 0);
                    }
                    return 0;
                }
                if (app.device_lost_recovering) return 0;

                app.mu.lockUncancelable(core.clock.io());
                var grid_id: ?i64 = null;
                var ext_window: ?*app_mod.ExternalWindow = null;
                if (findExternalWindowByHwndLocked(app, hwnd)) |hit| {
                    grid_id = hit.grid_id;
                    ext_window = hit.win;
                }
                app.mu.unlock(core.clock.io());

                if (ext_window) |ext_win| {
                    if (timer_id == app_mod.TIMER_SCROLLBAR_FADE) {
                        scrollbar.updateScrollbarFadeForExternal(hwnd, app, ext_win);
                        return 0;
                    } else if (timer_id == app_mod.TIMER_SCROLLBAR_REPEAT) {
                        if (grid_id != null and ext_win.scrollbar_repeat_dir != 0) {
                            // Change to faster interval after first fire
                            if (ext_win.scrollbar_repeat_timer != 0) {
                                _ = c.KillTimer(hwnd, app_mod.TIMER_SCROLLBAR_REPEAT);
                                ext_win.scrollbar_repeat_timer = c.SetTimer(hwnd, app_mod.TIMER_SCROLLBAR_REPEAT, app_mod.SCROLLBAR_REPEAT_INTERVAL, null);
                            }
                            scrollbar.scrollbarPageScrollForExternal(app, grid_id.?, ext_win.scrollbar_repeat_dir);
                        }
                        return 0;
                    } else if (timer_id == app_mod.TIMER_SCROLLBAR_AUTOHIDE) {
                        // Auto-hide scrollbar after scroll mode timeout
                        _ = c.KillTimer(hwnd, app_mod.TIMER_SCROLLBAR_AUTOHIDE);
                        scrollbar.hideScrollbarForExternal(hwnd, app, ext_win);
                        return 0;
                    }
                }
            }
        },

        // --- IME message handling for external windows ---
        c.WM_IME_STARTCOMPOSITION => {
            if (applog.isEnabled()) applog.appLog("[IME][ext] WM_IME_STARTCOMPOSITION hwnd={*}\n", .{hwnd});
            if (app_mod.getApp(hwnd)) |app| {
                input.resetImeComposition(app, false);

                // Position IME candidate window at cursor (using this external window)
                input.positionImeCandidateWindow(hwnd, app);

                // Trigger redraw to hide cursor during IME composition
                _ = c.InvalidateRect(hwnd, null, 0);
            }
            return 0;
        },

        c.WM_IME_COMPOSITION => {
            if (applog.isEnabled()) applog.appLog("[IME][ext] WM_IME_COMPOSITION lParam=0x{x}\n", .{@as(u32, @intCast(lParam & 0xFFFFFFFF))});
            if (app_mod.getApp(hwnd)) |app| {
                if (input.handleImeComposition(app, hwnd, lParam) == .alloc_failed) return c.DefWindowProcW(hwnd, msg, wParam, lParam);
            }
            // Let DefWindowProc handle for default IME processing
            return c.DefWindowProcW(hwnd, msg, wParam, lParam);
        },

        c.WM_IME_ENDCOMPOSITION => {
            if (applog.isEnabled()) applog.appLog("[IME][ext] WM_IME_ENDCOMPOSITION hwnd={*}\n", .{hwnd});
            if (app_mod.getApp(hwnd)) |app| {
                input.resetImeComposition(app, true);

                // Clear any inline preedit extmark and hide the overlay.
                if (app.corep) |corep| app_mod.zonvie_core_clear_preedit(corep);
                input.hideImePreeditOverlay(app);

                // Trigger redraw to show cursor after IME composition ends
                _ = c.InvalidateRect(hwnd, null, 0);
            }
            return 0;
        },

        c.WM_IME_CHAR => {
            // IME committed character - send to Neovim.
            if (applog.isEnabled()) applog.appLog("[IME][ext] WM_IME_CHAR wParam=0x{x}\n", .{wParam});
            if (app_mod.getApp(hwnd)) |app| {
                input.handleImeChar(app, @intCast(wParam));
                return 0;
            }
        },

        c.WM_SETFOCUS => {
            // Post message to update IME position asynchronously
            // This avoids deadlock when WM_SETFOCUS is triggered while app.mu is held
            // (e.g., during closeExternalWindowOnUIThread destroying a window)
            _ = c.PostMessageW(hwnd, app_mod.WM_APP_UPDATE_IME_POSITION, 0, 0);
        },

        app_mod.WM_APP_UPDATE_IME_POSITION => {
            if (app_mod.getApp(hwnd)) |app| {
                input.positionImeCandidateWindow(hwnd, app);
            }
        },

        // Enable drag-to-move for cmdline window (entire window acts as title bar)
        c.WM_NCHITTEST => {
            if (app_mod.getApp(hwnd)) |app| {
                app.mu.lockUncancelable(core.clock.io());
                const is_cmdline_window = if (app.external_windows.get(app_mod.CMDLINE_GRID_ID)) |cw|
                    cw.hwnd == hwnd
                else
                    false;
                app.mu.unlock(core.clock.io());

                if (is_cmdline_window) {
                    // HTCAPTION over the whole window would make every mouse
                    // message arrive as its WM_NC* variant, so the copy button
                    // would receive neither hover (WM_MOUSEMOVE) nor clicks
                    // (WM_LBUTTON*) and a press on it would start a window
                    // drag. Carve the button out as client area.
                    // lParam is in SCREEN coordinates for WM_NCHITTEST, and
                    // the coordinates are signed (multi-monitor).
                    const lp: usize = @bitCast(lParam);
                    var pt: c.POINT = .{
                        .x = @as(i16, @bitCast(@as(u16, @truncate(lp)))),
                        .y = @as(i16, @bitCast(@as(u16, @truncate(lp >> 16)))),
                    };
                    if (c.ScreenToClient(hwnd, &pt) != 0 and
                        hitTestCopyButton(hwnd, app, app_mod.CMDLINE_GRID_ID, pt.x, pt.y))
                    {
                        return c.HTCLIENT;
                    }
                    // Return HTCAPTION to make the rest of the window draggable
                    return c.HTCAPTION;
                }
            }
            // For other windows, use default behavior
            return c.DefWindowProcW(hwnd, msg, wParam, lParam);
        },

        // Save cmdline window position when moved
        c.WM_MOVE => {
            if (app_mod.getApp(hwnd)) |app| {
                app.mu.lockUncancelable(core.clock.io());
                defer app.mu.unlock(core.clock.io());

                // Check if this is the cmdline window
                if (app.external_windows.get(app_mod.CMDLINE_GRID_ID)) |cw| {
                    if (cw.hwnd == hwnd) {
                        // Get new window position
                        var rect: c.RECT = undefined;
                        if (c.GetWindowRect(hwnd, &rect) != 0) {
                            app.cmdline_saved_x = rect.left;
                            app.cmdline_saved_y = rect.top;
                            if (applog.isEnabled()) applog.appLog("[win] cmdline position saved: ({d},{d})\n", .{ rect.left, rect.top });
                        }
                    }
                }
            }
            return 0;
        },

        else => {},
    }
    return c.DefWindowProcW(hwnd, msg, wParam, lParam);
}

/// Set the clear color for an external window from cached highlight group bg colors.
/// Uses values pre-resolved in updateExternalWindowColors (UI thread, safe context).
/// Does NOT call core APIs that acquire grid_mu — safe for WM_PAINT context.
/// Float-origin normal windows use NormalFloat; ext_windows splits use default bg.
fn setExternalWindowClearColor(g: *d3d11.Renderer, app: *App, kind: ExternalSurfaceKind, ext_win: *const app_mod.ExternalWindow) void {
    app.mu.lockUncancelable(core.clock.io());
    const cached_bg: u32 = switch (kind) {
        .normal => if (ext_win.is_float_external) app.cached_normal_float_bg else 0xFFFFFFFF,
        .cmdline, .msg_show, .msg_history => app.cached_msg_area_bg,
        .popupmenu => app.cached_pmenu_bg,
    };
    const fallback_bg = app.colorscheme_bg;
    app.mu.unlock(core.clock.io());

    const bg_rgb = if (cached_bg != 0xFFFFFFFF) cached_bg else fallback_bg;
    if (bg_rgb != 0xFFFFFFFF) {
        g.setDefaultBgColor(bg_rgb);
    }
}

pub fn finishExternalWindowPaint(app: *App, grid_id: i64) void {
    app.mu.lockUncancelable(core.clock.io());
    var should_post_close = false;
    if (app.external_windows.get(grid_id)) |ew| {
        if (ew.paint_ref_count > 0) {
            ew.paint_ref_count -= 1;
            if (applog.isEnabled()) applog.appLog("[win] finishExternalWindowPaint: paint_ref_count-- -> {d}\n", .{ew.paint_ref_count});
        }
        // If paint finished and close was pending, schedule the close via PostMessage.
        // We must NOT call closeExternalWindowOnUIThread directly here because
        // this function is called from defer in paintExternalWindow, and EndPaint
        // hasn't been called yet. DestroyWindow before EndPaint causes undefined behavior.
        if (ew.paint_ref_count == 0 and ew.is_pending_close) {
            if (applog.isEnabled()) applog.appLog("[win] finishExternalWindowPaint: scheduling deferred close for grid_id={d}\n", .{grid_id});
            should_post_close = true;
            app.external_close_drain_needed = true;
        }
    }
    app.mu.unlock(core.clock.io());

    // Post the close message after unlocking, so it's processed after WM_PAINT completes
    if (should_post_close) {
        if (app.hwnd) |hwnd| {
            const post_result = c.PostMessageW(hwnd, app_mod.WM_APP_CLOSE_EXTERNAL_WINDOW, @bitCast(grid_id), 0);
            if (post_result == 0) {
                // PostMessageW failed. This can happen if the message queue is full or
                // the window is being destroyed. We cannot call closeExternalWindowOnUIThread
                // directly here because that would destroy the window before EndPaint completes.
                // is_pending_close plus external_close_drain_needed are
                // durable; the next message-loop service pass drains it even
                // if the main window is hidden and never paints.
                _ = c.InvalidateRect(hwnd, null, c.FALSE);
                if (applog.isEnabled()) applog.appLog("[win] finishExternalWindowPaint: PostMessageW failed for grid_id={d}, waking main close drain\n", .{grid_id});
            }
        } else {
            // Main window is gone (shutdown scenario). We cannot PostMessage, and calling
            // closeExternalWindowOnUIThread directly would destroy the window before EndPaint.
            // Leave is_pending_close=true; the window will be cleaned up at process exit.
            if (applog.isEnabled()) applog.appLog("[win] finishExternalWindowPaint: main hwnd is null, deferring close for grid_id={d} to shutdown\n", .{grid_id});
        }
    }
}

fn armExternalPaintRetry(
    app: *App,
    hwnd: c.HWND,
    ext_win: *app_mod.ExternalWindow,
    ticket: app_mod.PaintRetryState.Ticket,
) void {
    ext_win.paint_retry_deadline_ms = c.GetTickCount64() + ticket.delay_ms;
    if (app.external_paint_retry_deadline_ms == 0 or
        ext_win.paint_retry_deadline_ms < app.external_paint_retry_deadline_ms)
    {
        app.external_paint_retry_deadline_ms = ext_win.paint_retry_deadline_ms;
    }
    if (!window_mod.scheduleReliableWindowMessage(
        hwnd,
        app_mod.WM_APP_PAINT_RETRY_FALLBACK,
        ticket.generation,
        @bitCast(ext_win.window_wake_cookie),
        ticket.delay_ms,
    )) _ = ext_win.paint_retry.timerArmFailed(ticket.generation);
}

fn scheduleExternalSizeReplay(hwnd: c.HWND, app: *App) void {
    const cookie = externalWakeCookie(hwnd);
    if (cookie == 0) return;

    if (c.SetTimer(hwnd, app_mod.TIMER_EXTERNAL_SIZE_REPLAY, app_mod.DEVICE_LOST_RETRY_INTERVAL_MS, null) != 0) return;
    if (!window_mod.scheduleReliableWindowMessage(
        hwnd,
        app_mod.WM_APP_SIZE_REPLAY_FALLBACK,
        0,
        @bitCast(cookie),
        app_mod.DEVICE_LOST_RETRY_INTERVAL_MS,
    )) {
        if (c.PostMessageW(hwnd, app_mod.WM_APP_SIZE_REPLAY_FALLBACK, 0, @bitCast(cookie)) == 0) {
            const wake_state = externalWakeState(hwnd);
            _ = c.SetWindowLongPtrW(hwnd, window_mod.WINDOW_WAKE_STATE_OFFSET, @bitCast(wake_state | 1));
            app.external_size_replay_needed = true;
            if (app.hwnd) |main_hwnd| _ = c.InvalidateRect(main_hwnd, null, c.FALSE);
        }
    }
}

pub fn serviceDeferredSizeReplays(app: *App) void {
    if (!app.external_size_replay_needed or app.device_lost_recovering) return;
    app.external_size_replay_needed = false;
    while (true) {
        var replay_hwnd: ?c.HWND = null;
        app.mu.lockUncancelable(core.clock.io());
        var it = app.external_windows.valueIterator();
        while (it.next()) |ext_win_ptr| {
            const hwnd = ext_win_ptr.*.hwnd;
            const wake_state = externalWakeState(hwnd);
            if ((wake_state & 1) != 0) {
                _ = c.SetWindowLongPtrW(hwnd, window_mod.WINDOW_WAKE_STATE_OFFSET, @bitCast(wake_state & ~@as(usize, 1)));
                replay_hwnd = hwnd;
                break;
            }
        }
        app.mu.unlock(core.clock.io());
        const target = replay_hwnd orelse break;
        _ = c.SendMessageW(target, c.WM_SIZE, 0, 0);
    }
}

fn requeueExternalFullPaint(app: *App, grid_id: i64, hwnd: c.HWND) void {
    var post_device_recovery = false;
    var main_hwnd: ?c.HWND = null;
    var retry_ticket: ?app_mod.PaintRetryState.Ticket = null;
    app.mu.lockUncancelable(core.clock.io());
    const ext_win = app.external_windows.get(grid_id);
    if (ext_win) |ew| {
        ew.surface.paint_full = true;
        ew.needs_redraw = true;
        retry_ticket = ew.paint_retry.fail();
        if (ew.renderer.device_lost) {
            post_device_recovery = true;
            main_hwnd = app.hwnd;
        }
    }
    app.mu.unlock(core.clock.io());
    if (ext_win) |ew| {
        ew.tbs.rotation_mu.lockUncancelable(core.clock.io());
        ew.tbs.pending_paint_full = true;
        ew.tbs.rotation_mu.unlock(core.clock.io());
    }
    if (retry_ticket) |ticket| {
        if (ext_win) |ew| armExternalPaintRetry(app, hwnd, ew, ticket);
    }
    if (post_device_recovery) {
        if (main_hwnd) |target| {
            window_mod.postDeviceLostRecovery(target, app);
        }
    }
}

fn completeExternalPaintRetry(ext_win: *app_mod.ExternalWindow) void {
    ext_win.paint_retry_deadline_ms = 0;
    _ = ext_win.paint_retry.succeeded();
}

/// Update cached border/icon colors for external windows (cmdline, popupmenu).
/// Must be called from UI thread (not from core callbacks) to avoid deadlock.
/// Colors are derived from core highlights: Search (border) and Comment (icon).
pub fn updateExternalWindowColors(app: *App) void {
    var border_r: f32 = 1.0;
    var border_g: f32 = 1.0;
    var border_b: f32 = 0.0;
    var icon_r: f32 = 0.5;
    var icon_g: f32 = 0.5;
    var icon_b: f32 = 0.5;

    // Resolve highlight group bg colors for external window clear color cache.
    // Read during WM_PAINT (setExternalWindowClearColor) where grid_mu is unsafe.
    var normal_float_bg: u32 = 0xFFFFFFFF;
    var msg_area_bg: u32 = 0xFFFFFFFF;
    var pmenu_bg: u32 = 0xFFFFFFFF;

    // All 5 highlight groups in one grid_mu acquisition instead of 5
    // separate lock round-trips (was: Search, Comment each own call, then
    // NormalFloat/MsgArea/Pmenu each own call).
    if (app.corep) |corep| {
        const names = [_]?[*:0]const u8{ "Search", "Comment", "NormalFloat", "MsgArea", "Pmenu" };
        var fg: [5]u32 = undefined;
        var bg: [5]u32 = undefined;
        var found: [5]i32 = undefined;
        _ = app_mod.zonvie_core_get_hl_by_names_batch(corep, &names, &fg, &bg, &found, names.len);

        if (found[0] != 0) {
            border_r = @as(f32, @floatFromInt((bg[0] >> 16) & 0xFF)) / 255.0;
            border_g = @as(f32, @floatFromInt((bg[0] >> 8) & 0xFF)) / 255.0;
            border_b = @as(f32, @floatFromInt(bg[0] & 0xFF)) / 255.0;
        }
        if (found[1] != 0) {
            icon_r = @as(f32, @floatFromInt((fg[1] >> 16) & 0xFF)) / 255.0;
            icon_g = @as(f32, @floatFromInt((fg[1] >> 8) & 0xFF)) / 255.0;
            icon_b = @as(f32, @floatFromInt(fg[1] & 0xFF)) / 255.0;
        }
        if (found[2] != 0) normal_float_bg = bg[2];
        if (found[3] != 0) msg_area_bg = bg[3];
        if (found[4] != 0) pmenu_bg = bg[4];
    }

    app.mu.lockUncancelable(core.clock.io());
    app.cmdline_border_color = .{ border_r, border_g, border_b };
    app.cmdline_icon_color = .{ icon_r, icon_g, icon_b };
    app.cached_normal_float_bg = normal_float_bg;
    app.cached_msg_area_bg = msg_area_bg;
    app.cached_pmenu_bg = pmenu_bg;
    app.mu.unlock(core.clock.io());
}

/// Paint an external window (simpler rendering path than main window)
pub fn paintExternalWindow(hwnd: c.HWND, app: *App) void {
    if (applog.isEnabled()) applog.appLog("[win] paintExternalWindow start hwnd={*}\n", .{hwnd});
    var ps: c.PAINTSTRUCT = undefined;
    _ = c.BeginPaint(hwnd, &ps);
    defer _ = c.EndPaint(hwnd, &ps);

    // Read core-owned render settings before entering the atlas reader
    // transaction. Keeping core calls outside minimizes reader lifetime and
    // avoids needless non-blocking atlas-reset abort/retry cycles.
    const glow_enabled = if (app.corep) |cp| core.zonvie_core_get_glow_enabled(cp) else false;
    const glow_intensity = if (app.corep) |cp| core.zonvie_core_get_glow_intensity(cp) else @as(f32, 0.8);

    app.mu.lockUncancelable(core.clock.io());

    // Find the external window for this hwnd (also get grid_id)
    var ext_win_ptr: ?*app_mod.ExternalWindow = null;
    var found_grid_id: i64 = 0;
    var ext_it = app.external_windows.iterator();
    while (ext_it.next()) |entry| {
        if (applog.isEnabled()) applog.appLog("[win] paintExternalWindow checking entry hwnd={*} vs {*}\n", .{ entry.value_ptr.*.hwnd, hwnd });
        if (entry.value_ptr.*.hwnd == hwnd) {
            ext_win_ptr = entry.value_ptr.*;
            found_grid_id = entry.key_ptr.*;
            break;
        }
    }

    const ext_win = ext_win_ptr orelse {
        app.mu.unlock(core.clock.io());
        if (applog.isEnabled()) applog.appLog("[win] paintExternalWindow: no external window for hwnd={*}\n", .{hwnd});
        return;
    };

    const grid_id = found_grid_id;
    const surface_kind = classifyExternalSurface(grid_id);

    if (applog.isEnabled()) applog.appLog(
        "[win] paintExternalWindow found ext_win vert_count={d} grid_id={d} kind={s}\n",
        .{ ext_win.vert_count, grid_id, @tagName(surface_kind) },
    );

    // Skip painting if window is pending close (renderer may be freed soon)
    if (ext_win.is_pending_close) {
        app.mu.unlock(core.clock.io());
        if (applog.isEnabled()) applog.appLog("[win] paintExternalWindow: is_pending_close=true, skipping\n", .{});
        return;
    }

    if (!applyPendingExternalVerticesLocked(app, grid_id, ext_win)) {
        app.mu.unlock(core.clock.io());
        requeueExternalFullPaint(app, grid_id, hwnd);
        if (applog.isEnabled()) applog.appLog("[win] paintExternalWindow: pending vertex transaction still OOM, retrying\n", .{});
        return;
    }

    // Cover the committed-set and atlas-generation snapshots as well as the
    // draw. A reset that commits in the gap between those snapshots and a
    // late admission check would pair old vertex UVs with the new atlas.
    if (!app.beginAtlasPaint()) {
        ext_win.tbs.rotation_mu.lockUncancelable(core.clock.io());
        ext_win.tbs.pending_paint_full = true;
        ext_win.tbs.rotation_mu.unlock(core.clock.io());
        app.mu.unlock(core.clock.io());
        return;
    }
    defer app.endAtlasPaint();

    // Increment paint reference count to prevent ext_win from being freed during paint.
    // DXGI operations (resize, present) can pump Win32 messages, which could trigger close.
    // This ensures ext_win remains valid until paint completes.
    ext_win.paint_ref_count += 1;
    if (applog.isEnabled()) applog.appLog("[win] paintExternalWindow: paint_ref_count++ -> {d}\n", .{ext_win.paint_ref_count});

    // TBS: acquire committed set for painting (lock-free vertex reads).
    const tbs_snapshot = ext_win.tbs.acquireForPaint(app.alloc);
    defer {
        const needs_reinvalidate = ext_win.tbs.releaseFromPaint(tbs_snapshot.committed_index, tbs_snapshot.cursor_index);
        if (ext_win.paint_retry.shouldInvalidateAfterRelease(needs_reinvalidate)) {
            if (!app.atlas_reset_active.load(.seq_cst)) {
                _ = c.InvalidateRect(hwnd, null, 0);
            }
        }
    }
    const tbs_committed = &ext_win.tbs.sets[tbs_snapshot.committed_index];
    const tbs_cursor = &ext_win.tbs.main_cursor_sets[tbs_snapshot.cursor_index];
    // Shared font/cell/linespace metrics are protected by app.mu. Pair the
    // snapshot with the generation stored alongside the committed row
    // vertices so an old vertex set is never drawn using new scissor/row
    // geometry.
    const shared_metrics_gen_snapshot = app.shared_metrics_gen;
    const row_h_px_snapshot = app.rowHeightPx();

    // Get renderer and atlas
    const gpu_ptr: ?*d3d11.Renderer = &ext_win.renderer;
    var atlas_ptr: ?*dwrite_d2d.Renderer = null;
    if (app.atlas) |*a| atlas_ptr = a;

    // Update custom-shader screen-space override so this HWND samples
    // the main window's shader universe at its own offset/size. Without
    // this, each ext window would get its own compressed shader space
    // (a star field squeezed into the cmdline bar, etc.).
    if (gpu_ptr) |g_sh| {
        if (g_sh.custom_shader_pipelines.items.len > 0) {
            var screen_w: u32 = g_sh.width;
            var screen_h: u32 = g_sh.height;
            var off_x: f32 = 0;
            var off_y: f32 = 0;
            if (app.hwnd) |main_hwnd| {
                if (app.renderer) |*main_r| {
                    if (main_r.width != 0 and main_r.height != 0) {
                        screen_w = main_r.width;
                        screen_h = main_r.height;
                    }
                }
                // Use each HWND's client-area origin rather than
                // GetWindowRect. GetWindowRect includes any window
                // frame / title bar (WS_OVERLAPPEDWINDOW on regular
                // external windows), so subtracting it pushes the
                // shader offset into the decoration strip — the
                // rendered shader pixels in the client area end up
                // shifted by the frame thickness. Shader pixels live
                // in client coords, so use client origins on both
                // sides.
                var main_client_origin: c.POINT = .{ .x = 0, .y = 0 };
                var ext_client_origin: c.POINT = .{ .x = 0, .y = 0 };
                if (c.ClientToScreen(main_hwnd, &main_client_origin) != 0 and c.ClientToScreen(hwnd, &ext_client_origin) != 0) {
                    off_x = @floatFromInt(ext_client_origin.x - main_client_origin.x);
                    off_y = @floatFromInt(ext_client_origin.y - main_client_origin.y);
                }
                // If this ext surface holds the active cursor (cmdline
                // / popupmenu / float window currently has focus),
                // forward its rect into the main renderer's shader
                // cursor state so cursor shaders track the visible
                // cursor instead of the main grid's stale cursor. The
                // ext verts are in this view's local NDC; translate
                // to main-window drawable px using the offset above.
                const ext_cursor_verts = tbs_cursor.verts.items;
                if (ext_cursor_verts.len != 0) {
                    if (app.renderer) |*main_r2| {
                        var minx_c: f32 = ext_cursor_verts[0].position[0];
                        var maxx_c: f32 = minx_c;
                        var miny_c: f32 = ext_cursor_verts[0].position[1];
                        var maxy_c: f32 = miny_c;
                        for (ext_cursor_verts) |v| {
                            if (v.position[0] < minx_c) minx_c = v.position[0];
                            if (v.position[0] > maxx_c) maxx_c = v.position[0];
                            if (v.position[1] < miny_c) miny_c = v.position[1];
                            if (v.position[1] > maxy_c) maxy_c = v.position[1];
                        }
                        const ext_w_f: f32 = @floatFromInt(g_sh.width);
                        const ext_h_f: f32 = @floatFromInt(g_sh.height);
                        // Position the cursor at the NDC center, but
                        // size it using main grid's cell metrics. ext
                        // cmdline / popupmenu drawables are often
                        // taller than a single cell (multi-row
                        // prompt / padding) and cursor verts span the
                        // full NDC y = -1..+1, so translating that
                        // across the full ext drawable height makes
                        // the cursor SDF render at the drawable's
                        // height instead of the actual cell height.
                        const center_x = off_x + (minx_c + maxx_c + 2.0) * 0.25 * ext_w_f;
                        const center_y = off_y + (2.0 - miny_c - maxy_c) * 0.25 * ext_h_f;
                        const cell_w: f32 = @floatFromInt(app.cell_w_px);
                        const cell_h: f32 = @floatFromInt(app.rowHeightPx());
                        const left_main = center_x - cell_w * 0.5;
                        const right_main = center_x + cell_w * 0.5;
                        const top_main = center_y - cell_h * 0.5;
                        const bot_main = center_y + cell_h * 0.5;
                        // Ghostty's cursor shaders treat iCurrentCursor.y
                        // as the BOTTOM edge of the cursor rect.
                        const cv0 = ext_cursor_verts[0];
                        main_r2.setCursorShaderState(
                            .{ left_main, bot_main, right_main - left_main, bot_main - top_main },
                            cv0.color,
                        );
                    }
                }

                if (app.renderer) |*main_r3| {
                    // Mirror cursor uniforms + iTime origin from main
                    // so cursor shaders work in cmdline / popupmenu /
                    // float windows. Without this, ext renderers see
                    // (0, 0, 0, 0) for iCurrentCursor and a separate
                    // iTime origin, so iTime - iTimeCursorChange ends
                    // up nonsense for shaders rendered through the ext
                    // renderer's shader pass.
                    if (main_r3.custom_shader_start_qpc != 0) {
                        g_sh.custom_shader_start_qpc = main_r3.custom_shader_start_qpc;
                    }
                    g_sh.shader_cursor_current = main_r3.shader_cursor_current;
                    g_sh.shader_cursor_previous = main_r3.shader_cursor_previous;
                    g_sh.shader_cursor_current_color = main_r3.shader_cursor_current_color;
                    g_sh.shader_cursor_previous_color = main_r3.shader_cursor_previous_color;
                    g_sh.shader_cursor_change_time = main_r3.shader_cursor_change_time;
                }
            }
            g_sh.shader_screen_w = screen_w;
            g_sh.shader_screen_h = screen_h;
            g_sh.shader_window_offset_x = off_x;
            g_sh.shader_window_offset_y = off_y;
        }
    }

    // Determine rendering mode from TBS committed set.
    const tbs_row_mode = tbs_committed.row_mode;
    const is_row_mode_normal = tbs_row_mode and surface_kind == .normal;

    // Snapshot vertex data. Row-mode normal surfaces use TBS committed set
    // (lock-free via refcount). Decorated surfaces and flat-mode still need snapshot.
    var vert_count = ext_win.vert_count;
    if (!is_row_mode_normal) {
        if (!app_mod.snapshotSurfaceRows(
            app.alloc,
            &ext_win.paint_scratch,
            &ext_win.paint_row_ranges,
            ext_win.surface.row_mode,
            ext_win.surface.row_verts.items,
            ext_win.surface.verts.items,
            vert_count,
        )) {
            ext_win.surface.paint_full = true;
            ext_win.needs_redraw = true;
            ext_win.paint_ref_count -= 1;
            app.mu.unlock(core.clock.io());
            ext_win.tbs.rotation_mu.lockUncancelable(core.clock.io());
            ext_win.tbs.pending_paint_full = true;
            ext_win.tbs.rotation_mu.unlock(core.clock.io());
            requeueExternalFullPaint(app, grid_id, hwnd);
            if (applog.isEnabled()) applog.appLog("[win] paintExternalWindow: failed to grow scratch buffer\n", .{});
            return;
        }
        // Append cursor vertices so decorated surfaces (cmdline) can render the cursor.
        const cursor_items = tbs_cursor.verts.items;
        if (cursor_items.len > 0) {
            ext_win.paint_scratch.ensureUnusedCapacity(app.alloc, cursor_items.len) catch {
                ext_win.surface.paint_full = true;
                ext_win.needs_redraw = true;
                ext_win.paint_ref_count -= 1;
                app.mu.unlock(core.clock.io());
                ext_win.tbs.rotation_mu.lockUncancelable(core.clock.io());
                ext_win.tbs.pending_paint_full = true;
                ext_win.tbs.rotation_mu.unlock(core.clock.io());
                requeueExternalFullPaint(app, grid_id, hwnd);
                return;
            };
            ext_win.paint_scratch.appendSliceAssumeCapacity(cursor_items);
            vert_count = ext_win.paint_scratch.items.len;
        }
    }

    const cursor_blink_visible = ext_win.cursor_blink_state;
    ext_win.needs_redraw = false;

    // Dirty state snapshot from TBS (row-mode normal windows only).
    const dirty_row_keys = &ext_win.paint_dirty_row_keys;
    dirty_row_keys.clearRetainingCapacity();
    var dirty_snapshot_ok = true;
    if (is_row_mode_normal) {
        const dirty_count = ext_win.tbs.paint_dirty_snapshot.count();
        dirty_row_keys.ensureTotalCapacity(app.alloc, dirty_count) catch {
            dirty_snapshot_ok = false;
        };
        if (dirty_snapshot_ok) {
            var dit = ext_win.tbs.paint_dirty_snapshot.iterator(.{});
            while (dit.next()) |row_idx| {
                dirty_row_keys.appendAssumeCapacity(@intCast(row_idx));
            }
        }
    }
    if (!dirty_snapshot_ok) {
        ext_win.surface.paint_full = true;
        ext_win.paint_ref_count -= 1;
        app.mu.unlock(core.clock.io());
        ext_win.tbs.rotation_mu.lockUncancelable(core.clock.io());
        ext_win.tbs.pending_paint_full = true;
        ext_win.tbs.rotation_mu.unlock(core.clock.io());
        requeueExternalFullPaint(app, grid_id, hwnd);
        return;
    }
    var ext_paint_full = tbs_snapshot.paint_full or ext_win.surface.paint_full;
    ext_win.surface.paint_full = false;

    // Check if renderer resize is needed (deferred from onExternalVertices to avoid deadlock)
    const needs_resize = ext_win.needs_renderer_resize;
    if (needs_resize) {
        ext_win.needs_renderer_resize = false;
    }

    // Get cmdline firstc for icon rendering
    const cmdline_firstc = app.cmdline_firstc;

    // Copy scrollbar_alpha for later use (scrollbar rendering in normal external windows)
    // This avoids use-after-free if the window is closed while we're painting
    const scrollbar_alpha = ext_win.scrollbar_alpha;

    // Check if we need to upload the full atlas (a TRUE reset happened since
    // this window last fully re-uploaded — not just "some glyph was added").
    // Guarded by a.mu: recreateAtlasTexture() bumps this field from
    // ensureGlyph, which can run concurrently with this paint (same pattern as the
    // atlas_reset_pending read elsewhere in this function).
    var current_atlas_reset_generation: u64 = 0;
    if (atlas_ptr) |a| {
        a.mu.lockUncancelable(core.clock.io());
        current_atlas_reset_generation = a.atlas_reset_generation;
        a.mu.unlock(core.clock.io());
    }
    const need_full_atlas_upload = ext_win.atlas_reset_generation < current_atlas_reset_generation;

    // Scroll state is now bundled in tbs_snap (atomically consistent with committed set).

    app.mu.unlock(core.clock.io());

    // Ensure paint_ref_count is decremented when we exit (handles all return paths)
    defer finishExternalWindowPaint(app, grid_id);

    if (is_row_mode_normal and tbs_committed.metrics_gen != shared_metrics_gen_snapshot) {
        requeueExternalFullPaint(app, grid_id, hwnd);
        return;
    }

    // Use the per-window scratch buffer (safe: each window has its own)
    const verts = ext_win.paint_scratch.items;

    if (gpu_ptr) |g| {
        g.lockContext();
        defer g.unlockContext();

        // Resize this external window's own D3D atlas texture to match the
        // shared/configured atlas_size (mirrors the main window's WM_PAINT
        // handling at window.zig:1320-1336). Without this, external windows'
        // GPU atlas textures stay frozen at the d3d11.Renderer default
        // (2048x2048) forever, causing silently-dropped UpdateSubresource
        // uploads or wrong-denominator UVs whenever atlas_size != 2048.
        // recreateAtlasTextureIfNeeded no-ops cheaply when size is unchanged
        // (see d3d11_renderer.zig:4103), so this is safe to call every paint.
        if (atlas_ptr) |a| {
            var cur_atlas_w: u32 = 0;
            var cur_atlas_h: u32 = 0;
            {
                a.mu.lockUncancelable(core.clock.io());
                defer a.mu.unlock(core.clock.io());
                cur_atlas_w = a.atlas_w;
                cur_atlas_h = a.atlas_h;
            }
            g.recreateAtlasTextureIfNeeded(cur_atlas_w, cur_atlas_h) catch |e| {
                if (applog.isEnabled()) applog.appLog("[win] paintExternalWindow: D3D atlas texture recreation failed: {any}\n", .{e});
                requeueExternalFullPaint(app, grid_id, hwnd);
                return;
            };
        }

        // Perform deferred renderer resize (outside app.mu lock to avoid deadlock)
        // WARNING: D3D/DXGI operations can pump Win32 messages internally.
        // This means WM_APP_CLOSE_EXTERNAL_WINDOW could be processed during resize,
        // freeing ext_win and invalidating our `g` pointer. We must re-validate after resize.
        //
        // Also detect client-area size mismatch (e.g. WM_SIZE from user drag-resize)
        // that was not captured by needs_renderer_resize. If the renderer back_tex
        // is recreated inside presentOnlyFromBack AFTER row drawing, all drawn
        // content is lost. Resizing here and forcing a full repaint prevents that.
        const size_mismatch = blk: {
            if (needs_resize) break :blk true;
            var rc: c.RECT = undefined;
            _ = c.GetClientRect(g.hwnd, &rc);
            const cw: u32 = @intCast(@max(1, rc.right - rc.left));
            const ch: u32 = @intCast(@max(1, rc.bottom - rc.top));
            break :blk (cw != g.width or ch != g.height);
        };
        if (size_mismatch) {
            g.resize() catch |e| {
                if (applog.isEnabled()) applog.appLog("[win] paintExternalWindow deferred resize failed: {any}\n", .{e});
                requeueExternalFullPaint(app, grid_id, hwnd);
                return;
            };
            // back_tex was recreated — force full repaint so all rows are redrawn.
            ext_paint_full = true;

            // After resize, DXGI may have pumped messages. Check if ext_win was closed.
            app.mu.lockUncancelable(core.clock.io());
            const still_valid = app.external_windows.contains(grid_id);
            app.mu.unlock(core.clock.io());
            if (!still_valid) {
                if (applog.isEnabled()) applog.appLog("[win] paintExternalWindow: ext_win was closed during resize, aborting\n", .{});
                return;
            }
        }

        if (applog.isEnabled()) applog.appLog("[win] paintExternalWindow drawing vert_count={d}\n", .{vert_count});

        // Upload atlas to external window's D3D context.
        // Uses since-based cursor so each window independently tracks its
        // position in the append-only pending_uploads queue.
        if (atlas_ptr) |a| {
            if (need_full_atlas_upload) {
                if (applog.isEnabled()) applog.appLog("[win] paintExternalWindow uploading full atlas\n", .{});
            }
            const upload = app_mod.flushAtlasUploads(a, g, ext_win.atlas_upload_cursor, need_full_atlas_upload);
            if (upload.success) {
                ext_win.atlas_upload_cursor = upload.cursor;
                if (need_full_atlas_upload) {
                    ext_win.atlas_reset_generation = current_atlas_reset_generation;
                }
            } else {
                requeueExternalFullPaint(app, grid_id, hwnd);
                return;
            }
        }

        // Set clear color from cached highlight group bg colors (no grid_mu acquisition).
        // NormalFloat for float-origin externals, MsgArea for cmdline/messages, Pmenu for popupmenu.
        setExternalWindowClearColor(g, app, surface_kind, ext_win);

        if (surface_kind != .normal) {
            // Decorated surfaces never consume row VBs. Release buffers left
            // by an earlier normal row-mode incarnation of this window.
            _ = app_mod.resizeRowVBsForPaint(
                app.alloc,
                &ext_win.row_vbs,
                &app.row_vb_budget,
                &ext_win.row_vb_retained_bytes,
                0,
            );

            // cmdline/msg_show/msg_history derive their content dims from
            // ext_win.surface.rows/cols (same computation as the matching
            // internal checks inside drawDecoratedExternalSurface). A
            // transient zero-dimension state there returns a plain success
            // (not an error), so without this check execution would fall
            // through to Present() below and show stale back-buffer content
            // from the previous frame (see LOW-13 in the fix-plan doc).
            if (surface_kind == .cmdline or surface_kind == .msg_show or surface_kind == .msg_history) {
                app.mu.lockUncancelable(core.clock.io());
                const content_rows = ext_win.surface.rows;
                const content_cols = ext_win.surface.cols;
                app.mu.unlock(core.clock.io());
                if (content_rows == 0 or content_cols == 0) {
                    if (applog.isEnabled()) applog.appLog("[win] paintExternalWindow: skipping draw+present for zero-dimension grid_id={d}\n", .{grid_id});
                    completeExternalPaintRetry(ext_win);
                    return;
                }
            }
            drawDecoratedExternalSurface(surface_kind, g, app, grid_id, verts, vert_count, cmdline_firstc, &ext_win.flat_draw_scratch, glow_enabled, glow_intensity) catch |e| {
                if (applog.isEnabled()) applog.appLog("[win] paintExternalWindow decorated draw failed: {any}\n", .{e});
                requeueExternalFullPaint(app, grid_id, hwnd);
                return;
            };
            if (applog.isEnabled()) applog.appLog("[win] paintExternalWindow draw succeeded, presenting\n", .{});
            g.presentOnlyFromBack(null) catch |e| {
                if (applog.isEnabled()) applog.appLog("[win] paintExternalWindow present failed: {any}\n", .{e});
                requeueExternalFullPaint(app, grid_id, hwnd);
                return;
            };
            if (g.device_lost) {
                requeueExternalFullPaint(app, grid_id, hwnd);
                return;
            }
            if (applog.isEnabled()) applog.appLog("[win] paintExternalWindow present succeeded\n", .{});
            completeExternalPaintRetry(ext_win);
            return;
        }

        const force_full_present = drawNormalExternalSurface(
            g,
            app,
            ext_win,
            tbs_committed,
            tbs_cursor,
            grid_id,
            verts,
            vert_count,
            cursor_blink_visible,
            scrollbar_alpha,
            dirty_row_keys.items,
            ext_paint_full,
            glow_enabled,
            glow_intensity,
            tbs_snapshot,
            row_h_px_snapshot,
        ) catch |e| {
            if (applog.isEnabled()) applog.appLog("[win] paintExternalWindow normal draw failed: {any}\n", .{e});
            if (e == error.RowVBPhysicalBudgetExceeded) {
                app.row_vb_budget_failed = true;
                if (app.corep) |corep| core.zonvie_core_fail_render_budget(corep);
                return;
            }
            requeueExternalFullPaint(app, grid_id, hwnd);
            return;
        };

        if (is_row_mode_normal) {
            app.mu.lockUncancelable(core.clock.io());
            const metrics_still_current = app.shared_metrics_gen == shared_metrics_gen_snapshot;
            app.mu.unlock(core.clock.io());
            if (!metrics_still_current) {
                requeueExternalFullPaint(app, grid_id, hwnd);
                return;
            }
        }

        if (!force_full_present and ext_win.paint_present_rects.items.len == 0) {
            if (applog.isEnabled()) applog.appLog("[win] paintExternalWindow: no retained-back damage, skipping present\n", .{});
            completeExternalPaintRetry(ext_win);
            return;
        }

        g.presentFromBackRectsWithCursorNoResize(
            ext_win.paint_present_rects.items,
            null,
            0,
            null,
            force_full_present,
            null,
            null,
        ) catch |e| {
            if (applog.isEnabled()) applog.appLog("[win] paintExternalWindow partial present failed: {any}\n", .{e});
            requeueExternalFullPaint(app, grid_id, hwnd);
            return;
        };
        if (g.device_lost) {
            requeueExternalFullPaint(app, grid_id, hwnd);
            return;
        }
        completeExternalPaintRetry(ext_win);
    } else {
        if (applog.isEnabled()) applog.appLog("[win] paintExternalWindow no gpu_ptr\n", .{});
        requeueExternalFullPaint(app, grid_id, hwnd);
    }
}

// --- ext_windows layout operation callbacks ---

const WindowInfo = struct {
    grid_id: i64,
    win_id: i64,
    rect: c.RECT,
    hwnd: c.HWND,
};

const MAX_WIN_INFOS = 32;

/// Collect layout info for all visible windows. Caller must hold app.mu.
/// `include_main`: all ext_windows operations pass true. Parameter retained for future use.
/// Main window is registered as grid 2 (Neovim's default editor grid).
/// Called from the core thread; GetWindowRect/SetWindowPos are thread-safe Win32 APIs,
/// and app.mu serializes access against concurrent window operations.
fn collectWindowInfos(app: *App, include_main: bool) struct { infos: [MAX_WIN_INFOS]WindowInfo, count: usize } {
    var result: [MAX_WIN_INFOS]WindowInfo = undefined;
    var count: usize = 0;

    // Main window (grid 2)
    if (include_main) {
        if (app.hwnd) |main_hwnd| {
            var rect: c.RECT = std.mem.zeroes(c.RECT);
            _ = c.GetWindowRect(main_hwnd, &rect);
            // Do NOT call zonvie_core_get_win_id here — this function may run
            // during redraw callbacks where grid_mu is already held, and
            // zonvie_core_get_win_id would re-acquire grid_mu causing deadlock.
            // Callers that need win_id must resolve it separately.
            const main_win_id: i64 = 0;
            result[count] = .{ .grid_id = 2, .win_id = main_win_id, .rect = rect, .hwnd = main_hwnd };
            count += 1;
        }
    }

    // External windows (skip special, pending-close, and hidden windows)
    var it = app.external_windows.iterator();
    while (it.next()) |entry| {
        if (count >= MAX_WIN_INFOS) {
            if (applog.isEnabled()) applog.appLog("[win] collectWindowInfos: MAX_WIN_INFOS ({d}) reached, some windows omitted\n", .{MAX_WIN_INFOS});
            break;
        }
        const grid_id = entry.key_ptr.*;
        if (grid_id < 0) continue; // Skip special windows (cmdline, popupmenu, etc.)
        const ext = entry.value_ptr.*;
        if (ext.is_pending_close) continue;
        if (c.IsWindowVisible(ext.hwnd) == 0) continue; // Skip hidden windows
        var rect: c.RECT = std.mem.zeroes(c.RECT);
        _ = c.GetWindowRect(ext.hwnd, &rect);
        result[count] = .{ .grid_id = grid_id, .win_id = ext.win_id, .rect = rect, .hwnd = ext.hwnd };
        count += 1;
    }

    return .{ .infos = result, .count = count };
}

/// Find nearest window in direction. Returns matching WindowInfo or null.
/// direction: 0=down, 1=up, 2=right, 3=left
/// Falls back to the nearest window overall when no candidate is found in the strict direction
/// (e.g. when window centers align on the checked axis).
fn findInDirection(infos: []const WindowInfo, ref_grid: i64, direction: i32, count: i32) ?WindowInfo {
    // Find reference
    var ref_cx: i32 = 0;
    var ref_cy: i32 = 0;
    var found_ref = false;
    for (infos) |info| {
        if (info.grid_id == ref_grid) {
            ref_cx = @divTrunc(info.rect.left + info.rect.right, 2);
            ref_cy = @divTrunc(info.rect.top + info.rect.bottom, 2);
            found_ref = true;
            break;
        }
    }
    if (!found_ref) return null;

    // Collect directional candidates
    var candidates: [MAX_WIN_INFOS]WindowInfo = undefined;
    var distances: [MAX_WIN_INFOS]i32 = undefined;
    var cand_count: usize = 0;

    for (infos) |info| {
        if (info.grid_id == ref_grid) continue;
        const cx = @divTrunc(info.rect.left + info.rect.right, 2);
        const cy = @divTrunc(info.rect.top + info.rect.bottom, 2);

        const match = switch (direction) {
            0 => cy > ref_cy, // down (Win32: higher Y = lower on screen)
            1 => cy < ref_cy, // up
            2 => cx > ref_cx, // right
            3 => cx < ref_cx, // left
            else => false,
        };
        if (match) {
            const dist = absI32(cx - ref_cx) + absI32(cy - ref_cy);
            candidates[cand_count] = info;
            distances[cand_count] = dist;
            cand_count += 1;
        }
    }

    // Fallback: if no directional candidates, collect all other windows
    if (cand_count == 0) {
        for (infos) |info| {
            if (info.grid_id == ref_grid) continue;
            const cx = @divTrunc(info.rect.left + info.rect.right, 2);
            const cy = @divTrunc(info.rect.top + info.rect.bottom, 2);
            const dist = absI32(cx - ref_cx) + absI32(cy - ref_cy);
            candidates[cand_count] = info;
            distances[cand_count] = dist;
            cand_count += 1;
        }
    }

    if (cand_count == 0) return null;

    // Sort by distance (simple selection sort)
    for (0..cand_count) |i| {
        var min_idx = i;
        for (i + 1..cand_count) |j| {
            if (distances[j] < distances[min_idx]) min_idx = j;
        }
        if (min_idx != i) {
            std.mem.swap(WindowInfo, &candidates[i], &candidates[min_idx]);
            std.mem.swap(i32, &distances[i], &distances[min_idx]);
        }
    }

    const idx: usize = if (count > 0) @intCast(count - 1) else 0;
    return if (idx < cand_count) candidates[idx] else candidates[0];
}

/// Calculate popupmenu Y position, preferring below the anchor cell.
/// Falls back to above if below would go off-screen.
/// Mirrors macOS popupmenuWindowRect() logic adapted to Windows coords (Y-down).
fn popupmenuPositionY(anchor_top: c_int, cell_h: c_int, popup_h: c_int, ref_hwnd: c.HWND) c_int {
    const below_y = anchor_top + cell_h;
    const above_y = anchor_top - popup_h;

    // Get work area (screen minus taskbar) for the monitor containing ref_hwnd
    var monitor_info: c.MONITORINFO = std.mem.zeroes(c.MONITORINFO);
    monitor_info.cbSize = @sizeOf(c.MONITORINFO);
    const monitor = c.MonitorFromWindow(ref_hwnd, c.MONITOR_DEFAULTTONEAREST);
    if (c.GetMonitorInfoW(monitor, &monitor_info) != 0) {
        const screen_bottom = monitor_info.rcWork.bottom;
        const screen_top = monitor_info.rcWork.top;

        // Prefer below; if it overflows screen bottom, try above
        if (below_y + popup_h <= screen_bottom) {
            return below_y;
        } else if (above_y >= screen_top) {
            return above_y;
        }
    }

    // Fallback: below
    return below_y;
}

fn absI32(v: i32) i32 {
    return if (v < 0) -v else v;
}

/// Append a two-window position swap (A moves to B's position keeping A's
/// size; B moves to A's position keeping B's size) to app.deferred_win_ops.
/// Appends after any ops a previous call queued whose
/// WM_APP_DEFERRED_WIN_POS the UI thread has not drained yet — resetting the
/// count here would silently drop that earlier op set. Returns false (drops
/// the swap) when fewer than 2 slots remain. Caller MUST hold app.mu while
/// calling this, and MUST PostMessageW(hwnd, WM_APP_DEFERRED_WIN_POS, 0, 0)
/// after unlocking -- SetWindowPos on a cross-thread-owned window sends
/// WM_SIZE synchronously to the UI thread, which calls
/// updateLayoutToCore -> grid_mu.lock(); calling it directly from the core
/// thread while grid_mu is held (as this function's callers are) deadlocks.
/// This mirrors the existing onWinRotate/onWinResizeEqual deferred pattern.
fn queueSwapWindowPositions(app: *App, hwnd_a: c.HWND, rect_a: c.RECT, hwnd_b: c.HWND, rect_b: c.RECT) bool {
    const base = app.deferred_win_ops_count;
    if (base + 2 > App.MAX_DEFERRED_WIN_OPS) {
        if (applog.isEnabled()) applog.appLog("[win] queueSwapWindowPositions: deferred_win_ops full, dropping swap\n", .{});
        return false;
    }
    const w_a = rect_a.right - rect_a.left;
    const h_a = rect_a.bottom - rect_a.top;
    const w_b = rect_b.right - rect_b.left;
    const h_b = rect_b.bottom - rect_b.top;
    app.deferred_win_ops[base] = .{ .hwnd = hwnd_a, .x = rect_b.left, .y = rect_b.top, .w = w_a, .h = h_a, .flags = c.SWP_NOZORDER | c.SWP_NOACTIVATE };
    app.deferred_win_ops[base + 1] = .{ .hwnd = hwnd_b, .x = rect_a.left, .y = rect_a.top, .w = w_b, .h = h_b, .flags = c.SWP_NOZORDER | c.SWP_NOACTIVATE };
    app.deferred_win_ops_count = base + 2;
    return true;
}

/// Sort window infos spatially: top-to-bottom, left-to-right.
fn sortSpatially(infos: []WindowInfo) void {
    for (0..infos.len) |i| {
        var min_idx = i;
        for (i + 1..infos.len) |j| {
            const a_cy = @divTrunc(infos[min_idx].rect.top + infos[min_idx].rect.bottom, 2);
            const b_cy = @divTrunc(infos[j].rect.top + infos[j].rect.bottom, 2);
            const a_cx = @divTrunc(infos[min_idx].rect.left + infos[min_idx].rect.right, 2);
            const b_cx = @divTrunc(infos[j].rect.left + infos[j].rect.right, 2);
            if (b_cy < a_cy or (b_cy == a_cy and b_cx < a_cx)) {
                min_idx = j;
            }
        }
        if (min_idx != i) std.mem.swap(WindowInfo, &infos[i], &infos[min_idx]);
    }
}

pub fn onWinMove(ctx: ?*anyopaque, grid_id: i64, win: i64, flags: i32) callconv(.c) void {
    _ = win;
    const app: *App = @ptrCast(@alignCast(ctx.?));
    if (applog.isEnabled()) applog.appLog("[win] on_win_move: grid={d} flags={d}\n", .{ grid_id, flags });

    app.mu.lockUncancelable(core.clock.io());
    const coll = collectWindowInfos(app, true);
    const hwnd = app.hwnd;

    var queued = false;
    const infos = coll.infos[0..coll.count];
    if (findInDirection(infos, grid_id, flags, 1)) |target| {
        // Find source rect
        for (infos) |info| {
            if (info.grid_id == grid_id) {
                queued = queueSwapWindowPositions(app, info.hwnd, info.rect, target.hwnd, target.rect);
                break;
            }
        }
    }
    app.mu.unlock(core.clock.io());

    if (queued) {
        if (hwnd) |h| {
            if (c.PostMessageW(h, app_mod.WM_APP_DEFERRED_WIN_POS, 0, 0) == 0) {
                if (applog.isEnabled()) applog.appLog("[win] on_win_move: PostMessageW failed\n", .{});
                // Remove only the 2 ops this call appended. If a drain already
                // consumed them (count < 2), there is nothing to remove.
                app.mu.lockUncancelable(core.clock.io());
                if (app.deferred_win_ops_count >= 2) app.deferred_win_ops_count -= 2;
                app.mu.unlock(core.clock.io());
            }
        }
    }
}

pub fn onWinExchange(ctx: ?*anyopaque, grid_id: i64, win: i64, count: i32) callconv(.c) void {
    _ = win;
    const app: *App = @ptrCast(@alignCast(ctx.?));
    if (applog.isEnabled()) applog.appLog("[win] on_win_exchange: grid={d} count={d}\n", .{ grid_id, count });

    app.mu.lockUncancelable(core.clock.io());
    const coll = collectWindowInfos(app, true);
    const hwnd = app.hwnd;

    if (coll.count < 2) {
        app.mu.unlock(core.clock.io());
        return;
    }
    var sorted: [MAX_WIN_INFOS]WindowInfo = coll.infos;
    sortSpatially(sorted[0..coll.count]);

    // Find source index
    var src_idx: ?usize = null;
    for (sorted[0..coll.count], 0..) |info, i| {
        if (info.grid_id == grid_id) {
            src_idx = i;
            break;
        }
    }
    const si = src_idx orelse {
        app.mu.unlock(core.clock.io());
        return;
    };

    // count=0 means "next window" (default for <C-w>x without count prefix)
    const effective_count: i32 = if (count == 0) 1 else count;
    const n: i32 = @intCast(coll.count);
    var dst: i32 = @as(i32, @intCast(si)) + effective_count;
    dst = @mod(dst, n);
    if (dst < 0) dst += n;
    const di: usize = @intCast(dst);
    var queued = false;
    if (di != si) {
        queued = queueSwapWindowPositions(app, sorted[si].hwnd, sorted[si].rect, sorted[di].hwnd, sorted[di].rect);
    }
    app.mu.unlock(core.clock.io());

    if (queued) {
        if (hwnd) |h| {
            if (c.PostMessageW(h, app_mod.WM_APP_DEFERRED_WIN_POS, 0, 0) == 0) {
                if (applog.isEnabled()) applog.appLog("[win] on_win_exchange: PostMessageW failed\n", .{});
                // Remove only the 2 ops this call appended. If a drain already
                // consumed them (count < 2), there is nothing to remove.
                app.mu.lockUncancelable(core.clock.io());
                if (app.deferred_win_ops_count >= 2) app.deferred_win_ops_count -= 2;
                app.mu.unlock(core.clock.io());
            }
        }
    }
}

/// Defers SetWindowPos to UI thread via PostMessage to avoid blocking the core
/// thread on cross-thread message processing while grid_mu is held.
pub fn onWinRotate(ctx: ?*anyopaque, grid_id: i64, win: i64, direction: i32, count: i32) callconv(.c) void {
    _ = grid_id;
    _ = win;
    const app: *App = @ptrCast(@alignCast(ctx.?));
    if (applog.isEnabled()) applog.appLog("[win] on_win_rotate: direction={d} count={d}\n", .{ direction, count });

    app.mu.lockUncancelable(core.clock.io());
    const coll = collectWindowInfos(app, true);
    const hwnd = app.hwnd orelse {
        app.mu.unlock(core.clock.io());
        return;
    };

    if (coll.count < 2) {
        app.mu.unlock(core.clock.io());
        return;
    }
    var sorted: [MAX_WIN_INFOS]WindowInfo = coll.infos;
    sortSpatially(sorted[0..coll.count]);

    // Save original positions (left, top) only — each window keeps its own size
    var lefts: [MAX_WIN_INFOS]c.LONG = undefined;
    var tops: [MAX_WIN_INFOS]c.LONG = undefined;
    for (0..coll.count) |i| {
        lefts[i] = sorted[i].rect.left;
        tops[i] = sorted[i].rect.top;
    }

    // count=0 means "rotate once" (default for <C-w>r without count prefix).
    // Reject malformed negative counts and reduce huge counts modulo the number
    // of windows instead of doing attacker-controlled O(count * windows) work.
    if (count < 0) {
        app.mu.unlock(core.clock.io());
        return;
    }
    const n = coll.count;
    const effective_count: usize = @mod(if (count == 0) @as(usize, 1) else @as(usize, @intCast(count)), n);
    if (effective_count == 0) {
        app.mu.unlock(core.clock.io());
        return;
    }

    // Append after any ops still awaiting their WM_APP_DEFERRED_WIN_POS drain
    // (resetting the count here would silently drop that earlier op set).
    const base = app.deferred_win_ops_count;
    if (base > App.MAX_DEFERRED_WIN_OPS or n > App.MAX_DEFERRED_WIN_OPS - base) {
        app.mu.unlock(core.clock.io());
        return;
    }
    for (0..n) |i| {
        // Compute directly from the immutable position snapshot. This keeps
        // even attacker-sized counts O(window_count), after the modulo above.
        const source_index = if (direction == 0)
            (i + n - effective_count) % n
        else
            (i + effective_count) % n;
        app.deferred_win_ops[base + i] = .{
            .hwnd = sorted[i].hwnd,
            .x = lefts[source_index],
            .y = tops[source_index],
            .w = sorted[i].rect.right - sorted[i].rect.left,
            .h = sorted[i].rect.bottom - sorted[i].rect.top,
            .flags = c.SWP_NOZORDER | c.SWP_NOACTIVATE,
        };
    }
    app.deferred_win_ops_count = base + n;
    // Post while app.mu still excludes both the UI drain and other appenders;
    // a failed post can therefore roll back exactly this transaction.
    if (c.PostMessageW(hwnd, app_mod.WM_APP_DEFERRED_WIN_POS, 0, 0) == 0) {
        app.deferred_win_ops_count = base;
        if (applog.isEnabled()) applog.appLog("[win] on_win_rotate: PostMessageW failed\n", .{});
    }
    app.mu.unlock(core.clock.io());
}

/// Make all windows equal size (including main window).
/// Defers SetWindowPos to UI thread via PostMessage to avoid deadlock:
/// SetWindowPos on the main window from core thread sends WM_SIZE → updateLayoutToCore → grid_mu.lock()
/// while grid_mu is already held by the core thread during this callback.
pub fn onWinResizeEqual(ctx: ?*anyopaque) callconv(.c) void {
    const app: *App = @ptrCast(@alignCast(ctx.?));
    if (applog.isEnabled()) applog.appLog("[win] on_win_resize_equal\n", .{});

    app.mu.lockUncancelable(core.clock.io());
    const coll = collectWindowInfos(app, true);
    const hwnd = app.hwnd;

    if (coll.count < 2) {
        app.mu.unlock(core.clock.io());
        return;
    }
    const infos = coll.infos[0..coll.count];

    // Calculate average size
    var total_w: i32 = 0;
    var total_h: i32 = 0;
    for (infos) |info| {
        total_w += info.rect.right - info.rect.left;
        total_h += info.rect.bottom - info.rect.top;
    }
    const n: i32 = @intCast(coll.count);
    const avg_w = @divTrunc(total_w, n);
    const avg_h = @divTrunc(total_h, n);

    // Append after any ops still awaiting their WM_APP_DEFERRED_WIN_POS drain
    // (resetting the count here would silently drop that earlier op set).
    const base = app.deferred_win_ops_count;
    var appended: usize = 0;
    for (infos, 0..) |info, i| {
        if (base + i >= App.MAX_DEFERRED_WIN_OPS) break;
        app.deferred_win_ops[base + i] = .{
            .hwnd = info.hwnd,
            .x = info.rect.left,
            .y = info.rect.top,
            .w = avg_w,
            .h = avg_h,
            .flags = c.SWP_NOZORDER | c.SWP_NOACTIVATE,
        };
        appended = i + 1;
    }
    app.deferred_win_ops_count = base + appended;
    app.mu.unlock(core.clock.io());

    if (hwnd) |h| {
        if (c.PostMessageW(h, app_mod.WM_APP_DEFERRED_WIN_POS, 0, 0) == 0) {
            if (applog.isEnabled()) applog.appLog("[win] on_win_resize_equal: PostMessageW failed\n", .{});
            // Remove only what this call appended. If a drain already
            // consumed it (count < appended), there is nothing to remove.
            app.mu.lockUncancelable(core.clock.io());
            if (app.deferred_win_ops_count >= appended) app.deferred_win_ops_count -= appended;
            app.mu.unlock(core.clock.io());
        }
    }
}

pub fn onWinMoveCursor(ctx: ?*anyopaque, direction: i32, count: i32) callconv(.c) i64 {
    const app: *App = @ptrCast(@alignCast(ctx.?));
    if (applog.isEnabled()) applog.appLog("[win] on_win_move_cursor: direction={d} count={d}\n", .{ direction, count });

    app.mu.lockUncancelable(core.clock.io());
    const cursor_grid = app.last_cursor_grid;
    const coll = collectWindowInfos(app, true);
    const corep = app.corep;
    app.mu.unlock(core.clock.io());

    const infos = coll.infos[0..coll.count];
    if (findInDirection(infos, cursor_grid, direction, count)) |target| {
        // collectWindowInfos sets win_id=0 for grid 2 (main window) to avoid
        // calling zonvie_core_get_win_id while grid_mu might be held.
        // Resolve it here where app.mu is released and grid_mu is not held.
        var win_id = target.win_id;
        if (win_id == 0 and target.grid_id == 2) {
            if (corep) |cp| {
                win_id = app_mod.zonvie_core_get_win_id(cp, 2);
            }
        }
        if (applog.isEnabled()) applog.appLog("[win] on_win_move_cursor: -> win_id={d}\n", .{win_id});
        return win_id;
    }
    return 0;
}
