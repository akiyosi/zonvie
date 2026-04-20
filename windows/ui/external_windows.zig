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
const core = @import("zonvie_core");

const ExternalSurfaceKind = enum {
    normal,
    cmdline,
    popupmenu,
    msg_show,
    msg_history,
};

fn classifyExternalSurface(grid_id: i64) ExternalSurfaceKind {
    return switch (grid_id) {
        app_mod.CMDLINE_GRID_ID => .cmdline,
        app_mod.POPUPMENU_GRID_ID => .popupmenu,
        app_mod.MESSAGE_GRID_ID => .msg_show,
        app_mod.MSG_HISTORY_GRID_ID => .msg_history,
        else => .normal,
    };
}

fn drawDecoratedExternalSurface(
    kind: ExternalSurfaceKind,
    g: *d3d11.Renderer,
    app: *App,
    grid_id: i64,
    verts: []const app_mod.Vertex,
    vert_count: usize,
    cmdline_firstc: u8,
    glow_enabled: bool,
    glow_intensity: f32,
) !void {
    switch (kind) {
        .cmdline => {
            const window_w: f32 = @floatFromInt(g.width);
            const window_h: f32 = @floatFromInt(g.height);

            app.mu.lock();
            const ext_win_relookup = app.external_windows.getPtr(grid_id);
            const content_rows = if (ext_win_relookup) |ew| ew.surface.rows else 0;
            const content_cols = if (ext_win_relookup) |ew| ew.surface.cols else 0;
            const cell_w = app.cell_w_px;
            const cell_h = app.cell_h_px + app.linespace_px;
            const hide_cursor_for_ime = app.ime_composing;
            const border_r = app.cmdline_border_color[0];
            const border_g = app.cmdline_border_color[1];
            const border_b = app.cmdline_border_color[2];
            const icon_r = app.cmdline_icon_color[0];
            const icon_g = app.cmdline_icon_color[1];
            const icon_b = app.cmdline_icon_color[2];
            app.mu.unlock();

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

            const extra_verts = 6 + 24 + 20;
            var cmdline_verts = try app.alloc.alloc(app_mod.Vertex, vert_count + extra_verts);
            defer app.alloc.free(cmdline_verts);

            var orig_bg_r: f32 = 0.0;
            var orig_bg_g: f32 = 0.0;
            var orig_bg_b: f32 = 0.0;
            var found_bg_vertex = false;
            for (verts[0..vert_count]) |v| {
                if (v.texCoord[0] < 0) {
                    orig_bg_r = v.color[0];
                    orig_bg_g = v.color[1];
                    orig_bg_b = v.color[2];
                    found_bg_vertex = true;
                    break;
                }
            }
            if (!found_bg_vertex) {
                app.mu.lock();
                if (app.external_windows.getPtr(grid_id)) |ew| {
                    if (ew.cached_bg_color) |cached| {
                        orig_bg_r = cached[0];
                        orig_bg_g = cached[1];
                        orig_bg_b = cached[2];
                    }
                }
                app.mu.unlock();
            } else {
                app.mu.lock();
                if (app.external_windows.getPtr(grid_id)) |ew| {
                    ew.cached_bg_color = .{ orig_bg_r, orig_bg_g, orig_bg_b };
                }
                app.mu.unlock();
            }

            const adjusted = app_mod.adjustBrightnessForCmdline(orig_bg_r, orig_bg_g, orig_bg_b);
            const bg_color: [4]f32 = .{ adjusted[0], adjusted[1], adjusted[2], app.config.window.opacity };
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
            const border_w_ndc: f32 = @as(f32, @floatFromInt(app_mod.CMDLINE_BORDER_WIDTH)) / (window_w / 2.0);
            const border_h_ndc: f32 = @as(f32, @floatFromInt(app_mod.CMDLINE_BORDER_WIDTH)) / (window_h / 2.0);
            const border_color: [4]f32 = .{ border_r, border_g, border_b, 1.0 };
            const border_tex: [2]f32 = .{ -1.0, -1.0 };
            extra_idx = app_mod.addRectVerts(cmdline_verts, extra_idx, -1.0, 1.0, 2.0, border_h_ndc, border_color, border_tex, grid_id);
            extra_idx = app_mod.addRectVerts(cmdline_verts, extra_idx, -1.0, -1.0 + border_h_ndc, 2.0, border_h_ndc, border_color, border_tex, grid_id);
            extra_idx = app_mod.addRectVerts(cmdline_verts, extra_idx, -1.0, 1.0 - border_h_ndc, border_w_ndc, 2.0 - 2.0 * border_h_ndc, border_color, border_tex, grid_id);
            extra_idx = app_mod.addRectVerts(cmdline_verts, extra_idx, 1.0 - border_w_ndc, 1.0 - border_h_ndc, border_w_ndc, 2.0 - 2.0 * border_h_ndc, border_color, border_tex, grid_id);

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
            var pum_verts = try app.alloc.alloc(app_mod.Vertex, vert_count + extra_verts);
            defer app.alloc.free(pum_verts);
            @memcpy(pum_verts[0..vert_count], verts[0..vert_count]);

            app.mu.lock();
            const border_r = app.cmdline_border_color[0];
            const border_g = app.cmdline_border_color[1];
            const border_b = app.cmdline_border_color[2];
            app.mu.unlock();

            var extra_idx: usize = vert_count;
            const border_w_ndc: f32 = @as(f32, @floatFromInt(app_mod.CMDLINE_BORDER_WIDTH)) / (window_w / 2.0);
            const border_h_ndc: f32 = @as(f32, @floatFromInt(app_mod.CMDLINE_BORDER_WIDTH)) / (window_h / 2.0);
            const border_color: [4]f32 = .{ border_r, border_g, border_b, 1.0 };
            const border_tex: [2]f32 = .{ -1.0, -1.0 };
            extra_idx = app_mod.addRectVerts(pum_verts, extra_idx, -1.0, 1.0, 2.0, border_h_ndc, border_color, border_tex, grid_id);
            extra_idx = app_mod.addRectVerts(pum_verts, extra_idx, -1.0, -1.0 + border_h_ndc, 2.0, border_h_ndc, border_color, border_tex, grid_id);
            extra_idx = app_mod.addRectVerts(pum_verts, extra_idx, -1.0, 1.0 - border_h_ndc, border_w_ndc, 2.0 - 2.0 * border_h_ndc, border_color, border_tex, grid_id);
            extra_idx = app_mod.addRectVerts(pum_verts, extra_idx, 1.0 - border_w_ndc, 1.0 - border_h_ndc, border_w_ndc, 2.0 - 2.0 * border_h_ndc, border_color, border_tex, grid_id);

            try g.draw(pum_verts[0..extra_idx], &[_]app_mod.Vertex{}, null);
            if (glow_enabled) {
                g.drawBloomFromVerts(pum_verts[0..extra_idx], &[_]app_mod.Vertex{}, glow_intensity, 0, 0, g.width, g.height);
            }
        },
        .msg_show, .msg_history => {
            const window_w: f32 = @floatFromInt(g.width);
            const window_h: f32 = @floatFromInt(g.height);

            app.mu.lock();
            const ext_win_relookup2 = app.external_windows.getPtr(grid_id);
            const content_rows = if (ext_win_relookup2) |ew| ew.surface.rows else 0;
            const content_cols = if (ext_win_relookup2) |ew| ew.surface.cols else 0;
            const cell_w = app.cell_w_px;
            const cell_h = app.cell_h_px + app.linespace_px;
            app.mu.unlock();
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

            var msg_verts = try app.alloc.alloc(app_mod.Vertex, vert_count + 6);
            defer app.alloc.free(msg_verts);

            var orig_bg_r: f32 = 0.0;
            var orig_bg_g: f32 = 0.0;
            var orig_bg_b: f32 = 0.0;
            var found_bg_vertex = false;
            for (verts[0..vert_count]) |v| {
                if (v.texCoord[0] < 0) {
                    orig_bg_r = v.color[0];
                    orig_bg_g = v.color[1];
                    orig_bg_b = v.color[2];
                    found_bg_vertex = true;
                    break;
                }
            }
            if (!found_bg_vertex) {
                app.mu.lock();
                if (app.external_windows.getPtr(grid_id)) |ew| {
                    if (ew.cached_bg_color) |cached| {
                        orig_bg_r = cached[0];
                        orig_bg_g = cached[1];
                        orig_bg_b = cached[2];
                    }
                }
                app.mu.unlock();
            } else {
                app.mu.lock();
                if (app.external_windows.getPtr(grid_id)) |ew| {
                    ew.cached_bg_color = .{ orig_bg_r, orig_bg_g, orig_bg_b };
                }
                app.mu.unlock();
            }

            const adjusted = app_mod.adjustBrightnessForCmdline(orig_bg_r, orig_bg_g, orig_bg_b);
            const bg_color: [4]f32 = .{ adjusted[0], adjusted[1], adjusted[2], app.config.window.opacity };
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

            const msg_total = bg_idx + vert_count;
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
) !void {
    const log_enabled = applog.isEnabled();

    // Row-mode path: use per-row VB rendering with scissor (same as main window).
    if (tbs_committed.row_mode) {
        try drawNormalExternalSurfaceRowMode(
            g,
            app,
            ext_win,
            tbs_committed,
            grid_id,
            cursor_blink_visible,
            scrollbar_alpha,
            dirty_row_keys,
            force_full,
            glow_enabled,
            glow_intensity,
            tbs_snap,
        );
        return;
    }

    // Flat-mode fallback: snapshot-based flat draw (decorated surfaces or non-row-mode).
    if (log_enabled) applog.appLog("[win] drawNormalExternalSurface: flat mode grid_id={d}\n", .{grid_id});

    var scrollbar_verts: [12]app_mod.Vertex = undefined;
    var scrollbar_vert_count: usize = 0;

    if (app.config.scrollbar.enabled and scrollbar_alpha > 0.001) {
        scrollbar_vert_count = scrollbar.generateScrollbarVerticesForExternal(
            app,
            scrollbar_alpha,
            grid_id,
            @intCast(g.width),
            @intCast(g.height),
            &scrollbar_verts,
        );
    }

    try app_mod.drawExternalSurfaceFlat(
        g,
        &ext_win.flat_draw_scratch,
        app.alloc,
        verts,
        vert_count,
        cursor_blink_visible,
        scrollbar_verts[0..scrollbar_vert_count],
        glow_enabled,
        glow_intensity,
    );
}

/// Row-mode VB rendering for normal external windows.
/// Uses TBS committed set + drawRowModeSetupAndRowsFromSlots for lock-free rendering.
/// Then handles cursor overlay, scrollbar overlay, and bloom post-process.
fn drawNormalExternalSurfaceRowMode(
    g: *d3d11.Renderer,
    app: *App,
    ext_win: *app_mod.ExternalWindow,
    tbs_committed: *const app_mod.VertexSet,
    grid_id: i64,
    cursor_blink_visible: bool,
    scrollbar_alpha: f32,
    dirty_row_keys: []u32,
    force_full: bool,
    glow_enabled: bool,
    glow_intensity: f32,
    tbs_snap: app_mod.PaintSnapshot,
) !void {
    const log_enabled = applog.isEnabled();
    const fallback_row_h: u32 = app.cell_h_px + app.linespace_px;
    const row_h_px: i32 = @intCast(fallback_row_h);
    const content_right: i32 = @intCast(g.width);

    // back_tex is persistent, so we only need to redraw dirty rows.
    // The full back_tex→swapchain copy in presentOnlyFromBack handles
    // FLIP_SEQUENTIAL buffer rotation (swapchain buffers don't retain
    // previous content, but back_tex does).
    // Transparency mode (opacity < 1.0) must also force full rows:
    // premultiplied alpha blending accumulates alpha on redrawn rows
    // unless back_tex is cleared first, which requires force_full to
    // set preserve_back=false → should_clear=true in drawEx.
    const force_full_rows = force_full or glow_enabled or (g.opacity < 1.0);

    // Build sorted, deduplicated rows_to_draw list.
    var rows_to_draw: std.ArrayListUnmanaged(u32) = .{};
    defer rows_to_draw.deinit(app.alloc);

    const ext_rows = tbs_committed.rows;
    app_mod.computeRowsToDraw(
        app.alloc,
        &rows_to_draw,
        force_full_rows,
        dirty_row_keys,
        ext_rows,
        ext_rows, // max_valid_row = total rows (no row_verts_len / rows mismatch on ext)
    );

    const has_cursor = tbs_committed.cursor_verts.items.len > 0;
    if (rows_to_draw.items.len == 0 and !force_full_rows and !has_cursor) {
        if (log_enabled) applog.appLog("[win] drawNormalExtRowMode: no dirty rows and no cursor, skip grid_id={d}\n", .{grid_id});
        return;
    }

    const draw_params = app_mod.RowModeDrawParams{
        .content_height = app_mod.snappedContentHeight(g.height, fallback_row_h, 0),
        .row_h_px = row_h_px,
        .content_right = content_right,
        .preserve_back = !force_full_rows,
        .glow_enabled = glow_enabled,
    };

    var bloom_verts: std.ArrayListUnmanaged(app_mod.Vertex) = .{};
    defer bloom_verts.deinit(app.alloc);

    // Ensure row_vbs array covers committed set's row count.
    {
        const need_len = tbs_committed.row_map.items.len;
        if (ext_win.row_vbs.items.len < need_len) {
            const old_len = ext_win.row_vbs.items.len;
            ext_win.row_vbs.resize(app.alloc, need_len) catch {};
            for (ext_win.row_vbs.items[old_len..]) |*rvb| {
                rvb.* = .{};
            }
        }
    }

    // Apply scroll pixel shift (shared with main window).
    // Scroll state is bundled in tbs_snap, atomically consistent with committed set.
    if (!force_full_rows) {
        if (tbs_snap.scroll_rect) |sr| {
            _ = app_mod.applyScrollShift(
                g,
                app.alloc,
                ext_win.row_vbs.items,
                &ext_win.row_vbs_shift_scratch,
                &rows_to_draw,
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
        app.alloc,
        tbs_committed.row_map.items,
        &ext_win.tbs.pool,
        ext_win.row_vbs.items,
        rows_to_draw.items,
        &bloom_verts,
        draw_params,
    );

    if (log_enabled) {
        applog.appLog(
            "[win] drawNormalExtRowMode: grid_id={d} drawn={d} skipped={d} rows_to_draw={d}\n",
            .{ grid_id, result.metrics.drawn_rows, result.metrics.skipped_empty, rows_to_draw.items.len },
        );
    }

    // Cursor overlay — shared helper handles upload, scissor, draw/blink-off, and tracking.
    app_mod.drawCursorOverlay(g, .{
        .cursor_verts = tbs_committed.cursor_verts.items,
        .cursor_row = tbs_committed.last_cursor_row,
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
    });

    // Scrollbar overlay.
    if (app.config.scrollbar.enabled and scrollbar_alpha > 0.001) {
        var scrollbar_verts: [12]app_mod.Vertex = undefined;
        const scrollbar_vert_count = scrollbar.generateScrollbarVerticesForExternal(
            app,
            scrollbar_alpha,
            grid_id,
            @intCast(g.width),
            @intCast(g.height),
            &scrollbar_verts,
        );
        app_mod.drawScrollbarOverlay(g, &ext_win.scrollbar_vb, &ext_win.scrollbar_vb_bytes, scrollbar_verts[0..scrollbar_vert_count]);
    }

    // Bloom/glow post-process.
    // Cursor verts are stored separately (not in row_verts/bloom_verts).
    // Pass cursor snapshot for bloom only when cursor is visible (same as main window).
    if (glow_enabled) {
        const bloom_cursor = if (cursor_blink_visible) ext_win.flat_draw_scratch.items else &[_]app_mod.Vertex{};
        app_mod.drawBloomOverlay(g, bloom_verts.items, bloom_cursor, glow_intensity, draw_params);
    }
}

pub fn onExternalWindow(ctx: ?*anyopaque, grid_id: i64, win: i64, rows: u32, cols: u32, start_row: i32, start_col: i32) callconv(.c) void {
    const app: *App = @ptrCast(@alignCast(ctx.?));
    if (applog.isEnabled()) applog.appLog("[win] on_external_window: grid_id={d} win={d} rows={d} cols={d} pos=({d},{d})\n", .{ grid_id, win, rows, cols, start_row, start_col });

    app.mu.lock();
    defer app.mu.unlock();

    // Check if already exists
    if (app.external_windows.get(grid_id) != null) {
        if (applog.isEnabled()) applog.appLog("[win] external window already exists for grid_id={d}\n", .{grid_id});
        return;
    }

    // Queue the request for UI thread processing
    app.pending_external_windows.append(app.alloc, .{
        .grid_id = grid_id,
        .win = win,
        .rows = rows,
        .cols = cols,
        .start_row = start_row,
        .start_col = start_col,
    }) catch |e| {
        if (applog.isEnabled()) applog.appLog("[win] failed to queue external window request: {any}\n", .{e});
        return;
    };

    // Post message to UI thread to create the window
    if (app.hwnd) |main_hwnd| {
        _ = c.PostMessageW(main_hwnd, app_mod.WM_APP_CREATE_EXTERNAL_WINDOW, 0, 0);
    }
}

/// Actually create external window (must be called on UI thread)
pub fn createExternalWindowOnUIThread(app: *App, req: app_mod.PendingExternalWindow) void {
    if (applog.isEnabled()) applog.appLog("[win] createExternalWindowOnUIThread: grid_id={d} rows={d} cols={d}\n", .{ req.grid_id, req.rows, req.cols });

    // Ensure external window class is registered
    if (!ensureExternalWindowClassRegistered()) {
        if (applog.isEnabled()) applog.appLog("[win] external window class registration failed\n", .{});
        return;
    }

    // Get cell dimensions from main atlas
    // Note: cell_h must include linespace_px to match core's vertex generation
    const cell_w: u32 = app.cell_w_px;
    const cell_h: u32 = app.cell_h_px + app.linespace_px;
    const content_w: c_int = @intCast(req.cols * cell_w);
    const content_h: c_int = @intCast(req.rows * cell_h);

    // Check if this is a special window (cmdline, popupmenu, msg_show, msg_history)
    const is_cmdline = (req.grid_id == app_mod.CMDLINE_GRID_ID);
    const is_popupmenu = (req.grid_id == app_mod.POPUPMENU_GRID_ID);
    const is_msg_show = (req.grid_id == app_mod.MESSAGE_GRID_ID);
    const is_msg_history = (req.grid_id == app_mod.MSG_HISTORY_GRID_ID);

    // For cmdline: add margin and icon area
    // Total width = icon_margin_left + icon_size + icon_margin_right + content + padding*2
    const cmdline_icon_total_width: c_int = if (is_cmdline) @as(c_int, app_mod.CMDLINE_ICON_MARGIN_LEFT + app_mod.CMDLINE_ICON_SIZE + app_mod.CMDLINE_ICON_MARGIN_RIGHT) else 0;
    const cmdline_total_padding: c_int = if (is_cmdline) @as(c_int, app_mod.CMDLINE_PADDING * 2) else 0;

    // For msg_show/msg_history: add margin around content (DPI-scaled)
    const scaled_msg_padding: c_int = if (is_msg_show or is_msg_history) app.scalePx(@as(c_int, app_mod.MSG_PADDING)) * 2 else 0;

    var client_w: c_int = content_w + cmdline_icon_total_width + cmdline_total_padding + scaled_msg_padding;
    const client_h: c_int = content_h + cmdline_total_padding + scaled_msg_padding;

    // Clamp cmdline width to monitor work area minus margin (matching macOS cmdlineScreenMargin)
    if (is_cmdline) {
        if (app.hwnd) |main_hwnd| {
            const monitor = c.MonitorFromWindow(main_hwnd, c.MONITOR_DEFAULTTONEAREST);
            if (monitor) |mon| {
                var mi: c.MONITORINFO = std.mem.zeroes(c.MONITORINFO);
                mi.cbSize = @sizeOf(c.MONITORINFO);
                if (c.GetMonitorInfoW(mon, &mi) != 0) {
                    const work_w: c_int = mi.rcWork.right - mi.rcWork.left;
                    const screen_margin: c_int = @intCast(app_mod.CMDLINE_SCREEN_MARGIN);
                    const max_w: c_int = work_w - screen_margin;
                    if (client_w > max_w) {
                        client_w = max_w;
                    }
                }
            }
        }
    }

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
    const now_ms = std.time.milliTimestamp();
    const pending_age_ms = now_ms - app.pending_external_window_position_time;
    if (!is_special_window and app.pending_external_window_position != null and pending_age_ms < pending_timeout_ms) {
        const pos = app.pending_external_window_position.?;
        // Position so the window is centered horizontally on cursor, below cursor
        pos_x = pos.x - @divTrunc(window_w, 2);
        pos_y = pos.y;
        app.pending_external_window_position = null;  // Clear after use
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
        app.mu.lock();
        const anchor_hwnd: ?c.HWND = if (req.win > 0) blk: {
            if (app.external_windows.get(req.win)) |ew| {
                break :blk ew.hwnd;
            }
            break :blk null;
        } else null;
        app.mu.unlock();

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
        app.mu.lock();
        const msg_win = app.message_window;
        app.mu.unlock();

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
            app.mu.lock();
            const saved_x = app.cmdline_saved_x;
            const saved_y = app.cmdline_saved_y;
            app.mu.unlock();

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
        app.mu.lock();
        const cmdline_win = app.external_windows.get(app_mod.CMDLINE_GRID_ID);
        app.mu.unlock();

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
    } else if (is_msg_history) {
        // Message history: position at top-right based on config
        app.mu.lock();
        const target_rect = app.getExtFloatTargetRect();
        app.mu.unlock();
        pos_x = target_rect.right - window_w - 10;
        pos_y = target_rect.top + 10; // 10px from top
        if (applog.isEnabled()) applog.appLog("[win] msg_history at top-right: ({d},{d})\n", .{ pos_x, pos_y });
    } else if (is_msg_show) {
        // Message show (e.g. "Press ENTER..."): position below msg_history if visible, otherwise at top-right
        app.mu.lock();
        const msg_history_win = app.external_windows.get(app_mod.MSG_HISTORY_GRID_ID);
        const target_rect = app.getExtFloatTargetRect();
        app.mu.unlock();

        if (msg_history_win) |hw| {
            // Position below msg_history window
            var history_rect: c.RECT = undefined;
            if (c.GetWindowRect(hw.hwnd, &history_rect) != 0) {
                pos_x = target_rect.right - window_w - 10;
                pos_y = history_rect.bottom + 4; // 4px gap below history window
                if (applog.isEnabled()) applog.appLog("[win] msg_show below msg_history: ({d},{d})\n", .{ pos_x, pos_y });
            } else {
                // Fallback: top-right
                pos_x = target_rect.right - window_w - 10;
                pos_y = target_rect.top + 10;
                if (applog.isEnabled()) applog.appLog("[win] msg_show at top-right (fallback): ({d},{d})\n", .{ pos_x, pos_y });
            }
        } else {
            // No msg_history: position at top-right
            pos_x = target_rect.right - window_w - 10;
            pos_y = target_rect.top + 10;
            if (applog.isEnabled()) applog.appLog("[win] msg_show at top-right: ({d},{d})\n", .{ pos_x, pos_y });
        }
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

    if (hwnd == null) {
        if (applog.isEnabled()) applog.appLog("[win] CreateWindowExW failed for external grid\n", .{});
        return;
    }

    // Show window without activating (SW_SHOWNA = 8)
    _ = c.ShowWindow(hwnd, 8);

    // Initialize D3D11 renderer for external window (with transparency if enabled)
    const renderer = d3d11.Renderer.init(app.alloc, hwnd, app.config.window.opacity) catch |e| {
        if (applog.isEnabled()) applog.appLog("[win] d3d11.Renderer.init failed for external window: {any}\n", .{e});
        _ = c.DestroyWindow(hwnd);
        return;
    };

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

    app.mu.lock();

    // Store external window
    const ext_window = app_mod.ExternalWindow{
        .hwnd = hwnd.?,
        .win_id = req.win,
        .renderer = renderer,
        .surface = .{ .rows = req.rows, .cols = req.cols },
        .is_float_external = is_float,
    };

    app.external_windows.put(app.alloc, req.grid_id, ext_window) catch |e| {
        if (applog.isEnabled()) applog.appLog("[win] failed to store external window: {any}\n", .{e});
        app.mu.unlock();
        var tmp_renderer = renderer;
        tmp_renderer.deinit();
        _ = c.DestroyWindow(hwnd);
        return;
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

    // Check for pending vertices and apply them
    var pending_idx: ?usize = null;
    for (app.pending_external_verts.items, 0..) |*pv, i| {
        if (pv.grid_id == req.grid_id) {
            pending_idx = i;
            break;
        }
    }

    if (pending_idx) |idx| {
        const pv = &app.pending_external_verts.items[idx];
        if (applog.isEnabled()) applog.appLog("[win] applying pending vertices for grid_id={d}: vert_count={d} row_mode={}\n", .{ req.grid_id, pv.surface.verts.items.len, pv.surface.row_mode });

        if (app.external_windows.getPtr(req.grid_id)) |ext_win| {
            ext_win.surface.row_mode = pv.surface.row_mode;
            ext_win.surface.rows = pv.surface.rows;
            ext_win.surface.cols = pv.surface.cols;
            ext_win.needs_redraw = true;

            if (pv.surface.row_mode) {
                ext_win.surface.verts.clearRetainingCapacity();
                var row_idx: usize = 0;
                while (row_idx < pv.surface.row_verts.items.len) : (row_idx += 1) {
                    ext_win.surface.ensureRowStorage(app.alloc, @intCast(row_idx));
                    ext_win.surface.row_verts.items[row_idx].verts.clearRetainingCapacity();
                    if (pv.surface.row_verts.items[row_idx].verts.items.len != 0) {
                        ext_win.surface.row_verts.items[row_idx].verts.appendSlice(app.alloc, pv.surface.row_verts.items[row_idx].verts.items) catch {};
                    }
                    // Copy gen and origin_row so VB upload and viewport Y
                    // translation work correctly for pending rows.
                    ext_win.surface.row_verts.items[row_idx].gen = pv.surface.row_verts.items[row_idx].gen;
                    ext_win.surface.row_verts.items[row_idx].origin_row = pv.surface.row_verts.items[row_idx].origin_row;
                }
                ext_win.surface.clearExtraRows(pv.surface.rows);
                ext_win.recomputeVertCount();
            } else {
                ext_win.surface.verts.clearRetainingCapacity();
                ext_win.surface.verts.ensureTotalCapacity(app.alloc, pv.surface.verts.items.len) catch {};
                ext_win.surface.verts.appendSliceAssumeCapacity(pv.surface.verts.items);
                ext_win.vert_count = pv.surface.verts.items.len;
            }

            // TBS: seed the initial committed set so paintExternalWindow can read data immediately.
            // The ext_win was just created; no flush has committed data to TBS yet.
            {
                const ci = ext_win.tbs.committed_index;
                const cs = &ext_win.tbs.sets[ci];
                cs.row_mode = pv.surface.row_mode;
                cs.rows = pv.surface.rows;
                cs.cols = pv.surface.cols;
                if (pv.surface.row_mode) {
                    cs.ensureRowStorage(app.alloc, @intCast(if (pv.surface.row_verts.items.len > 0) pv.surface.row_verts.items.len - 1 else 0));
                    var ri: usize = 0;
                    while (ri < pv.surface.row_verts.items.len) : (ri += 1) {
                        if (ri < cs.row_map.items.len) {
                            // Allocate a slot and copy pending verts into it.
                            const new_idx = ext_win.tbs.pool.acquireSlot(app.alloc) orelse continue;
                            ext_win.tbs.pool.retain(new_idx);
                            const slot = &ext_win.tbs.pool.slots.items[new_idx];
                            slot.verts.clearRetainingCapacity();
                            if (pv.surface.row_verts.items[ri].verts.items.len != 0) {
                                slot.verts.appendSlice(app.alloc, pv.surface.row_verts.items[ri].verts.items) catch {};
                            }
                            slot.origin_row = pv.surface.row_verts.items[ri].origin_row;
                            slot.ver = pv.surface.row_verts.items[ri].gen;
                            cs.row_map.items[ri] = .{ .slot = new_idx };
                        }
                    }
                } else {
                    cs.flat_verts.clearRetainingCapacity();
                    cs.flat_verts.appendSlice(app.alloc, pv.surface.verts.items) catch {};
                }
                // Mark full paint so first acquireForPaint triggers full draw.
                ext_win.tbs.pending_paint_full = true;
            }

            // Trigger redraw
            _ = c.InvalidateRect(ext_win.hwnd, null, 0);
        }

        // Remove pending entry (free its verts and swap-remove from list)
        pv.deinit(app.alloc);
        _ = app.pending_external_verts.swapRemove(idx);
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

    app.mu.unlock();

    // Now call SetWindowPos outside the lock to avoid deadlock
    if (deferred_setpos) |sp| {
        _ = c.SetWindowPos(sp.hwnd, sp.hwnd_insert_after, sp.x, sp.y, 0, 0, sp.flags);
        if (applog.isEnabled()) applog.appLog("[win] repositioned msg_show below msg_history: ({d},{d})\n", .{ sp.x, sp.y });
    }
    if (deferred_setpos_cmdline) |sp| {
        _ = c.SetWindowPos(sp.hwnd, sp.hwnd_insert_after, sp.x, sp.y, 0, 0, sp.flags);
        if (applog.isEnabled()) applog.appLog("[win] put message window below cmdline (cmdline created)\n", .{});
    }

    // Activate this external window
    _ = c.SetForegroundWindow(hwnd);
}

pub fn onExternalWindowClose(ctx: ?*anyopaque, grid_id: i64) callconv(.c) void {
    const app: *App = @ptrCast(@alignCast(ctx.?));
    if (applog.isEnabled()) applog.appLog("[win] on_external_window_close: grid_id={d}\n", .{grid_id});

    // Mark the window as pending close (don't remove from HashMap yet to avoid use-after-free)
    // The actual removal and cleanup will happen on the UI thread in closeExternalWindowOnUIThread
    app.mu.lock();
    const main_hwnd = app.hwnd;
    if (app.external_windows.getPtr(grid_id)) |ext_win| {
        ext_win.is_pending_close = true;
    }
    app.mu.unlock();

    // Post message to UI thread to do the actual close
    // (DestroyWindow must be called from the thread that created the window)
    if (main_hwnd) |hwnd| {
        _ = c.PostMessageW(hwnd, app_mod.WM_APP_CLOSE_EXTERNAL_WINDOW, @bitCast(grid_id), 0);
    }
}

/// Actually close external window (must be called on UI thread)
/// Removes from HashMap and destroys the window
pub fn closeExternalWindowOnUIThread(app: *App, grid_id: i64) void {
    if (applog.isEnabled()) applog.appLog("[win] closeExternalWindowOnUIThread: grid_id={d}\n", .{grid_id});

    // Check if paint is in progress - if so, defer the close
    // DXGI operations can pump messages, so close could be triggered during paint
    app.mu.lock();
    if (app.external_windows.getPtr(grid_id)) |ew| {
        if (ew.paint_ref_count > 0) {
            // Paint is in progress - just mark as pending and let paint trigger close when done
            ew.is_pending_close = true;
            if (applog.isEnabled()) applog.appLog("[win] closeExternalWindowOnUIThread: paint in progress (ref={d}), deferring close\n", .{ew.paint_ref_count});
            app.mu.unlock();
            return;
        }
    }

    // Save window position before removing (for tab switch restoration)
    if (app.external_windows.getPtr(grid_id)) |ew| {
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
    app.mu.unlock();

    if (entry) |e| {
        var ext_win = e.value;

        // Check if IME overlay was parented to this external window
        // If so, destroy it and reset the handle so main window can create a new one
        app.mu.lock();
        if (app.ime_overlay_hwnd) |overlay| {
            const parent = c.GetParent(overlay);
            if (parent == ext_win.hwnd) {
                _ = c.DestroyWindow(overlay);
                app.ime_overlay_hwnd = null;
                if (applog.isEnabled()) applog.appLog("[win] destroyed IME overlay parented to external window\n", .{});
            }
        }
        app.mu.unlock();

        // deinit handles DestroyWindow and resource cleanup
        ext_win.deinit(app.alloc);
        if (applog.isEnabled()) applog.appLog("[win] destroyed external window hwnd={*}\n", .{ext_win.hwnd});
    }

    // Note: We intentionally do NOT remove pending_external_verts here because
    // the pending verts might belong to a new window with the same grid_id that
    // was created after the close event was queued but before this handler ran.
}

pub fn onCursorGridChanged(ctx: ?*anyopaque, grid_id: i64) callconv(.c) void {
    const app: *App = @ptrCast(@alignCast(ctx.?));
    if (applog.isEnabled()) applog.appLog("[win] on_cursor_grid_changed: grid_id={d}\n", .{grid_id});

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
    wc.lpszClassName = @ptrCast(external_window_class_name.ptr);

    if (c.RegisterClassExW(&wc) == 0) {
        if (applog.isEnabled()) applog.appLog("[win] Failed to register external window class\n", .{});
        return false;
    }

    external_window_class_registered = true;
    if (applog.isEnabled()) applog.appLog("[win] Registered external window class\n", .{});
    return true;
}

pub fn handleMouseWheel(
    hwnd: c.HWND,
    wParam: c.WPARAM,
    lParam: c.LPARAM,
    app: *App,
    grid_id: i64,
    scroll_accum: *i16,
    horizontal: bool,
) void {
    // Extract scroll delta from high word of wParam
    const delta: i16 = @bitCast(@as(u16, @truncate(wParam >> 16)));
    if (delta == 0) return;

    // Use a smaller threshold for better trackpad support.
    // Standard WHEEL_DELTA is 120, but trackpads send smaller deltas.
    // Using 40 (WHEEL_DELTA/3) provides good responsiveness for both
    // trackpads and regular mice.
    const SCROLL_THRESHOLD: i16 = 40;

    // Get mouse position (in screen coordinates)
    const x_screen: i16 = @bitCast(@as(u16, @truncate(@as(usize, @bitCast(lParam)))));
    const y_screen: i16 = @bitCast(@as(u16, @truncate(@as(usize, @bitCast(lParam)) >> 16)));

    // Convert to client coordinates
    var pt: c.POINT = .{ .x = x_screen, .y = y_screen };
    _ = c.ScreenToClient(hwnd, &pt);

    // Get cell dimensions
    app.mu.lock();
    const cell_w = app.cell_w_px;
    const cell_h = app.cell_h_px;
    const linespace = app.linespace_px;
    const corep = app.corep;
    app.mu.unlock();

    // Calculate cell position (include linespace in row height)
    const row_h = cell_h + linespace;
    const col: i32 = if (cell_w > 0) @divTrunc(pt.x, @as(c.LONG, @intCast(cell_w))) else 0;
    // When ext_tabline is enabled on main window, subtract tabbar height to get content-relative Y coordinate.
    // External windows (floating windows) don't have a tabbar, so only apply offset for main window.
    const is_main_window = if (app.hwnd) |main_hwnd| hwnd == main_hwnd else false;
    const content_y: c.LONG = if (is_main_window and app.ext_tabline_enabled and app.content_hwnd == null)
        pt.y - @as(c.LONG, app.scalePx(app_mod.TablineState.TAB_BAR_HEIGHT))
    else
        pt.y;
    const row: i32 = if (row_h > 0) @divTrunc(@max(0, content_y), @as(c.LONG, @intCast(row_h))) else 0;

    // Build modifier string from wParam flags and GetKeyState
    var mod_buf: [5]u8 = .{ 0, 0, 0, 0, 0 };
    var mod_len: usize = 0;
    if ((wParam & c.MK_SHIFT) != 0) {
        mod_buf[mod_len] = 'S';
        mod_len += 1;
    }
    if ((wParam & c.MK_CONTROL) != 0) {
        mod_buf[mod_len] = 'C';
        mod_len += 1;
    }
    if (c.GetKeyState(c.VK_MENU) < 0) {
        mod_buf[mod_len] = 'A';
        mod_len += 1;
    }
    if (c.GetKeyState(c.VK_LWIN) < 0 or c.GetKeyState(c.VK_RWIN) < 0) {
        mod_buf[mod_len] = 'D';
        mod_len += 1;
    }
    mod_buf[mod_len] = 0;

    // Accumulate scroll delta
    scroll_accum.* += delta;

    // Determine scroll direction
    // Vertical: positive delta = scroll up (wheel away from user)
    // Horizontal: positive delta = scroll right (wheel tilt right)
    const direction: [*:0]const u8 = if (horizontal)
        (if (scroll_accum.* > 0) "right" else "left")
    else
        (if (scroll_accum.* > 0) "up" else "down");

    // Send scroll events for each threshold accumulated
    while (scroll_accum.* >= SCROLL_THRESHOLD or scroll_accum.* <= -SCROLL_THRESHOLD) {
        app_mod.zonvie_core_send_mouse_scroll(corep, grid_id, row, col, direction, @as([*:0]const u8, @ptrCast(&mod_buf)));
        if (scroll_accum.* > 0) {
            scroll_accum.* -= SCROLL_THRESHOLD;
        } else {
            scroll_accum.* += SCROLL_THRESHOLD;
        }
    }
}

pub export fn ExternalWndProc(
    hwnd: c.HWND,
    msg: c.UINT,
    wParam: c.WPARAM,
    lParam: c.LPARAM,
) callconv(.winapi) c.LRESULT {
    switch (msg) {
        c.WM_PAINT => {
            if (applog.isEnabled()) applog.appLog("[win] ExternalWndProc WM_PAINT hwnd={*}\n", .{hwnd});
            if (app_mod.getApp(hwnd)) |app| {
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
                app.mu.lock();
                const ime_composing = app.ime_composing;
                app.mu.unlock();

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
                        vk, scancode,
                        &tmp_chars, &tmp_ign,
                        &out_chars, &out_ign,
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
                    return 0;
                }

                // Skip surrogates for now
                if (ch0 >= 0xD800 and ch0 <= 0xDFFF) {
                    return 0;
                }

                var tmp: [8]u8 = undefined;
                if (input.utf16UnitsToUtf8(&tmp, ch0, null)) |s| {
                    input.sendKeyEventToCore(app, 0, mods, s, null);
                }
                return 0;
            }
        },
        c.WM_SIZE => {
            if (app_mod.getApp(hwnd)) |app| {
                // Get new client area size
                var rc: c.RECT = undefined;
                _ = c.GetClientRect(hwnd, &rc);
                const client_w: u32 = @intCast(rc.right - rc.left);
                const client_h: u32 = @intCast(rc.bottom - rc.top);

                if (client_w == 0 or client_h == 0) {
                    return 0;
                }

                app.mu.lock();

                // Find grid_id and ext_window for this hwnd
                var grid_id: ?i64 = null;
                var suppress = false;
                var it = app.external_windows.iterator();
                while (it.next()) |entry| {
                    if (entry.value_ptr.hwnd == hwnd) {
                        grid_id = entry.key_ptr.*;
                        suppress = entry.value_ptr.suppress_resize_callback;
                        break;
                    }
                }

                const cell_w = app.cell_w_px;
                const cell_h = app.cell_h_px + app.linespace_px;
                const corep = app.corep;

                app.mu.unlock();

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
                app.mu.lock();
                var grid_id: ?i64 = null;
                var ext_window: ?*app_mod.ExternalWindow = null;
                var it = app.external_windows.iterator();
                while (it.next()) |entry| {
                    if (entry.value_ptr.hwnd == hwnd) {
                        grid_id = entry.key_ptr.*;
                        ext_window = entry.value_ptr;
                        break;
                    }
                }
                app.mu.unlock();

                if (grid_id != null and ext_window != null) {
                    handleMouseWheel(hwnd, wParam, lParam, app, grid_id.?, &ext_window.?.scroll_accum, false);

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
                app.mu.lock();
                var grid_id: ?i64 = null;
                var ext_window: ?*app_mod.ExternalWindow = null;
                var it = app.external_windows.iterator();
                while (it.next()) |entry| {
                    if (entry.value_ptr.hwnd == hwnd) {
                        grid_id = entry.key_ptr.*;
                        ext_window = entry.value_ptr;
                        break;
                    }
                }
                app.mu.unlock();

                if (grid_id != null and ext_window != null) {
                    handleMouseWheel(hwnd, wParam, lParam, app, grid_id.?, &ext_window.?.h_scroll_accum, true);
                }
                return 0;
            }
        },

        // --- Scrollbar mouse handling for external windows ---
        c.WM_LBUTTONDOWN => {
            if (app_mod.getApp(hwnd)) |app| {
                const x: i32 = @bitCast(@as(u32, @intCast(lParam & 0xFFFF)));
                const y: i32 = @bitCast(@as(u32, @intCast((lParam >> 16) & 0xFFFF)));

                app.mu.lock();
                var grid_id: ?i64 = null;
                var ext_window: ?*app_mod.ExternalWindow = null;
                var it = app.external_windows.iterator();
                while (it.next()) |entry| {
                    if (entry.value_ptr.hwnd == hwnd) {
                        grid_id = entry.key_ptr.*;
                        ext_window = entry.value_ptr;
                        break;
                    }
                }
                app.mu.unlock();

                if (grid_id != null and ext_window != null) {
                    if (scrollbar.scrollbarMouseDownForExternal(hwnd, app, ext_window.?, grid_id.?, x, y)) {
                        return 0;
                    }
                }
            }
        },

        c.WM_LBUTTONUP => {
            if (app_mod.getApp(hwnd)) |app| {
                app.mu.lock();
                var grid_id: ?i64 = null;
                var ext_window: ?*app_mod.ExternalWindow = null;
                var it = app.external_windows.iterator();
                while (it.next()) |entry| {
                    if (entry.value_ptr.hwnd == hwnd) {
                        grid_id = entry.key_ptr.*;
                        ext_window = entry.value_ptr;
                        break;
                    }
                }
                app.mu.unlock();

                if (grid_id != null and ext_window != null) {
                    scrollbar.scrollbarMouseUpForExternal(hwnd, app, ext_window.?, grid_id.?);
                }
            }
        },

        c.WM_MOUSEMOVE => {
            if (app_mod.getApp(hwnd)) |app| {
                const x: i32 = @bitCast(@as(u32, @intCast(lParam & 0xFFFF)));
                const y: i32 = @bitCast(@as(u32, @intCast((lParam >> 16) & 0xFFFF)));

                app.mu.lock();
                var grid_id: ?i64 = null;
                var ext_window: ?*app_mod.ExternalWindow = null;
                var it = app.external_windows.iterator();
                while (it.next()) |entry| {
                    if (entry.value_ptr.hwnd == hwnd) {
                        grid_id = entry.key_ptr.*;
                        ext_window = entry.value_ptr;
                        break;
                    }
                }
                app.mu.unlock();

                if (grid_id != null and ext_window != null) {
                    const ext_win = ext_window.?;

                    // Handle scrollbar dragging
                    if (ext_win.scrollbar_dragging) {
                        scrollbar.scrollbarMouseMoveForExternal(hwnd, app, ext_win, grid_id.?, y);
                        return 0;
                    }

                    // Check for scrollbar hover
                    if (app.config.scrollbar.enabled and app.config.scrollbar.isHover()) {
                        var client: c.RECT = undefined;
                        _ = c.GetClientRect(hwnd, &client);
                        const hit = scrollbar.scrollbarHitTestForExternal(app, grid_id.?, client.right, client.bottom, x, y);
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

        c.WM_MOUSELEAVE => {
            if (app_mod.getApp(hwnd)) |app| {
                app.mu.lock();
                var ext_window: ?*app_mod.ExternalWindow = null;
                var it = app.external_windows.iterator();
                while (it.next()) |entry| {
                    if (entry.value_ptr.hwnd == hwnd) {
                        ext_window = entry.value_ptr;
                        break;
                    }
                }
                app.mu.unlock();

                if (ext_window) |ext_win| {
                    ext_win.scrollbar_hover = false;
                    scrollbar.hideScrollbarForExternal(hwnd, app, ext_win);
                }
            }
        },

        c.WM_TIMER => {
            if (app_mod.getApp(hwnd)) |app| {
                const timer_id = wParam;

                app.mu.lock();
                var grid_id: ?i64 = null;
                var ext_window: ?*app_mod.ExternalWindow = null;
                var it = app.external_windows.iterator();
                while (it.next()) |entry| {
                    if (entry.value_ptr.hwnd == hwnd) {
                        grid_id = entry.key_ptr.*;
                        ext_window = entry.value_ptr;
                        break;
                    }
                }
                app.mu.unlock();

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
                app.mu.lock();
                app.ime_composing = true;
                app.ime_composition_str.clearRetainingCapacity();
                app.ime_composition_utf8.clearRetainingCapacity();
                app.ime_clause_info.clearRetainingCapacity();
                app.ime_cursor_pos = 0;
                app.ime_target_start = 0;
                app.ime_target_end = 0;
                app.mu.unlock();

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
                const himc = c.ImmGetContext(hwnd);
                if (himc != null) {
                    defer _ = c.ImmReleaseContext(hwnd, himc);

                    // Get composition string
                    if ((lParam & c.GCS_COMPSTR) != 0) {
                        const byte_len = c.ImmGetCompositionStringW(himc, c.GCS_COMPSTR, null, 0);
                        if (byte_len > 0) {
                            const char_len: usize = @intCast(@divTrunc(byte_len, 2));
                            app.mu.lock();
                            app.ime_composition_str.resize(app.alloc, char_len) catch {
                                app.mu.unlock();
                                return c.DefWindowProcW(hwnd, msg, wParam, lParam);
                            };
                            _ = c.ImmGetCompositionStringW(himc, c.GCS_COMPSTR, app.ime_composition_str.items.ptr, @intCast(byte_len));
                            input.updateImeCompositionUtf8(app);
                            app.mu.unlock();
                        } else {
                            app.mu.lock();
                            app.ime_composition_str.clearRetainingCapacity();
                            app.ime_composition_utf8.clearRetainingCapacity();
                            app.mu.unlock();
                        }
                    }

                    // Get clause info
                    if ((lParam & c.GCS_COMPCLAUSE) != 0) {
                        const clause_byte_len = c.ImmGetCompositionStringW(himc, c.GCS_COMPCLAUSE, null, 0);
                        if (clause_byte_len > 0) {
                            const clause_count: usize = @intCast(@divTrunc(clause_byte_len, 4));
                            app.mu.lock();
                            app.ime_clause_info.resize(app.alloc, clause_count) catch {
                                app.mu.unlock();
                                return c.DefWindowProcW(hwnd, msg, wParam, lParam);
                            };
                            _ = c.ImmGetCompositionStringW(himc, c.GCS_COMPCLAUSE, app.ime_clause_info.items.ptr, @intCast(clause_byte_len));
                            app.mu.unlock();
                        }
                    }

                    // Get cursor position
                    if ((lParam & c.GCS_CURSORPOS) != 0) {
                        const cursor_pos = c.ImmGetCompositionStringW(himc, c.GCS_CURSORPOS, null, 0);
                        app.mu.lock();
                        app.ime_cursor_pos = @intCast(@max(0, cursor_pos));
                        app.mu.unlock();
                    }

                    // Get target clause (same logic as main window)
                    // Always try to get COMPATTR, not just when flag is set
                    {
                        const attr_len = c.ImmGetCompositionStringW(himc, c.GCS_COMPATTR, null, 0);
                        if (attr_len > 0) {
                            var attr_buf: [256]u8 = undefined;
                            const len: usize = @intCast(@min(@as(usize, @intCast(@max(0, attr_len))), 256));
                            _ = c.ImmGetCompositionStringW(himc, c.GCS_COMPATTR, &attr_buf, @intCast(len));

                            // Find target clause (ATTR_TARGET_CONVERTED=0x01 or ATTR_TARGET_NOTCONVERTED=0x03)
                            app.mu.lock();
                            app.ime_target_start = 0;
                            app.ime_target_end = 0;
                            var found_start: bool = false;
                            var i: u32 = 0;
                            while (i < len) : (i += 1) {
                                const attr = attr_buf[i];
                                if (attr == 0x01 or attr == 0x03) {
                                    if (!found_start) {
                                        app.ime_target_start = i;
                                        found_start = true;
                                    }
                                    app.ime_target_end = i + 1;
                                }
                            }
                            app.mu.unlock();
                        }
                    }
                }

                // Update preedit overlay (must be called WITHOUT app.mu held,
                // because updateImePreeditOverlay acquires app.mu internally).
                input.updateImePreeditOverlay(hwnd, app);
            }
            // Let DefWindowProc handle for default IME processing
            return c.DefWindowProcW(hwnd, msg, wParam, lParam);
        },

        c.WM_IME_ENDCOMPOSITION => {
            if (applog.isEnabled()) applog.appLog("[IME][ext] WM_IME_ENDCOMPOSITION hwnd={*}\n", .{hwnd});
            if (app_mod.getApp(hwnd)) |app| {
                app.mu.lock();
                app.ime_composing = false;
                app.ime_composition_str.clearRetainingCapacity();
                app.ime_composition_utf8.clearRetainingCapacity();
                app.ime_clause_info.clearRetainingCapacity();
                app.ime_cursor_pos = 0;
                app.ime_target_start = 0;
                app.ime_target_end = 0;
                app.mu.unlock();

                // Hide overlay
                input.hideImePreeditOverlay(app);

                // Trigger redraw to show cursor after IME composition ends
                _ = c.InvalidateRect(hwnd, null, 0);
            }
            return 0;
        },

        c.WM_IME_CHAR => {
            // IME committed character - send to Neovim
            if (applog.isEnabled()) applog.appLog("[IME][ext] WM_IME_CHAR wParam=0x{x}\n", .{wParam});
            if (app_mod.getApp(hwnd)) |app| {
                const ch: u16 = @intCast(wParam);

                // Skip surrogate pairs for now
                if (ch >= 0xD800 and ch <= 0xDFFF) {
                    return 0;
                }

                var out: [8]u8 = undefined;
                const s = input.utf16UnitsToUtf8(&out, ch, null) orelse return 0;

                input.sendKeyEventToCore(app, 0, 0, s, s);
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
                app.mu.lock();
                defer app.mu.unlock();

                // Check if this is the cmdline window
                if (app.external_windows.get(app_mod.CMDLINE_GRID_ID)) |cw| {
                    if (cw.hwnd == hwnd) {
                        // Return HTCAPTION to make entire window draggable
                        return c.HTCAPTION;
                    }
                }
            }
            // For other windows, use default behavior
            return c.DefWindowProcW(hwnd, msg, wParam, lParam);
        },

        // Save cmdline window position when moved
        c.WM_MOVE => {
            if (app_mod.getApp(hwnd)) |app| {
                app.mu.lock();
                defer app.mu.unlock();

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
    app.mu.lock();
    const cached_bg: u32 = switch (kind) {
        .normal => if (ext_win.is_float_external) app.cached_normal_float_bg else 0xFFFFFFFF,
        .cmdline, .msg_show, .msg_history => app.cached_msg_area_bg,
        .popupmenu => app.cached_pmenu_bg,
    };
    const fallback_bg = app.colorscheme_bg;
    app.mu.unlock();

    const bg_rgb = if (cached_bg != 0xFFFFFFFF) cached_bg else fallback_bg;
    if (bg_rgb != 0xFFFFFFFF) {
        g.setDefaultBgColor(bg_rgb);
    }
}

pub fn finishExternalWindowPaint(app: *App, grid_id: i64) void {
    app.mu.lock();
    var should_post_close = false;
    if (app.external_windows.getPtr(grid_id)) |ew| {
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
        }
    }
    app.mu.unlock();

    // Post the close message after unlocking, so it's processed after WM_PAINT completes
    if (should_post_close) {
        if (app.hwnd) |hwnd| {
            const post_result = c.PostMessageW(hwnd, app_mod.WM_APP_CLOSE_EXTERNAL_WINDOW, @bitCast(grid_id), 0);
            if (post_result == 0) {
                // PostMessageW failed. This can happen if the message queue is full or
                // the window is being destroyed. We cannot call closeExternalWindowOnUIThread
                // directly here because that would destroy the window before EndPaint completes.
                // Leave is_pending_close=true; the window will be cleaned up at process exit.
                if (applog.isEnabled()) applog.appLog("[win] finishExternalWindowPaint: PostMessageW failed for grid_id={d}, deferring to shutdown\n", .{grid_id});
            }
        } else {
            // Main window is gone (shutdown scenario). We cannot PostMessage, and calling
            // closeExternalWindowOnUIThread directly would destroy the window before EndPaint.
            // Leave is_pending_close=true; the window will be cleaned up at process exit.
            if (applog.isEnabled()) applog.appLog("[win] finishExternalWindowPaint: main hwnd is null, deferring close for grid_id={d} to shutdown\n", .{grid_id});
        }
    }
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

    if (app.corep) |corep| {
        var fg_rgb: u32 = 0;
        var bg_rgb: u32 = 0;
        // Border color from Search highlight background
        if (app_mod.zonvie_core_get_hl_by_name(corep, "Search", &fg_rgb, &bg_rgb) != 0) {
            border_r = @as(f32, @floatFromInt((bg_rgb >> 16) & 0xFF)) / 255.0;
            border_g = @as(f32, @floatFromInt((bg_rgb >> 8) & 0xFF)) / 255.0;
            border_b = @as(f32, @floatFromInt(bg_rgb & 0xFF)) / 255.0;
        }
        // Icon color from Comment highlight foreground
        if (app_mod.zonvie_core_get_hl_by_name(corep, "Comment", &fg_rgb, &bg_rgb) != 0) {
            icon_r = @as(f32, @floatFromInt((fg_rgb >> 16) & 0xFF)) / 255.0;
            icon_g = @as(f32, @floatFromInt((fg_rgb >> 8) & 0xFF)) / 255.0;
            icon_b = @as(f32, @floatFromInt(fg_rgb & 0xFF)) / 255.0;
        }
    }

    // Resolve highlight group bg colors for external window clear color cache.
    // Read during WM_PAINT (setExternalWindowClearColor) where grid_mu is unsafe.
    var normal_float_bg: u32 = 0xFFFFFFFF;
    var msg_area_bg: u32 = 0xFFFFFFFF;
    var pmenu_bg: u32 = 0xFFFFFFFF;
    if (app.corep) |corep| {
        var discard_fg: u32 = 0;
        if (core.zonvie_core_get_hl_by_name(corep, "NormalFloat", &discard_fg, &normal_float_bg) == 0) {
            normal_float_bg = 0xFFFFFFFF;
        }
        if (core.zonvie_core_get_hl_by_name(corep, "MsgArea", &discard_fg, &msg_area_bg) == 0) {
            msg_area_bg = 0xFFFFFFFF;
        }
        if (core.zonvie_core_get_hl_by_name(corep, "Pmenu", &discard_fg, &pmenu_bg) == 0) {
            pmenu_bg = 0xFFFFFFFF;
        }
    }

    app.mu.lock();
    app.cmdline_border_color = .{ border_r, border_g, border_b };
    app.cmdline_icon_color = .{ icon_r, icon_g, icon_b };
    app.cached_normal_float_bg = normal_float_bg;
    app.cached_msg_area_bg = msg_area_bg;
    app.cached_pmenu_bg = pmenu_bg;
    app.mu.unlock();
}

/// Paint an external window (simpler rendering path than main window)
pub fn paintExternalWindow(hwnd: c.HWND, app: *App) void {
    if (applog.isEnabled()) applog.appLog("[win] paintExternalWindow start hwnd={*}\n", .{hwnd});
    var ps: c.PAINTSTRUCT = undefined;
    _ = c.BeginPaint(hwnd, &ps);
    defer _ = c.EndPaint(hwnd, &ps);

    app.mu.lock();

    // Find the external window for this hwnd (also get grid_id)
    var ext_win_ptr: ?*app_mod.ExternalWindow = null;
    var found_grid_id: i64 = 0;
    var ext_it = app.external_windows.iterator();
    while (ext_it.next()) |entry| {
        if (applog.isEnabled()) applog.appLog("[win] paintExternalWindow checking entry hwnd={*} vs {*}\n", .{ entry.value_ptr.hwnd, hwnd });
        if (entry.value_ptr.hwnd == hwnd) {
            ext_win_ptr = entry.value_ptr;
            found_grid_id = entry.key_ptr.*;
            break;
        }
    }

    const ext_win = ext_win_ptr orelse {
        app.mu.unlock();
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
        app.mu.unlock();
        if (applog.isEnabled()) applog.appLog("[win] paintExternalWindow: is_pending_close=true, skipping\n", .{});
        return;
    }

    if (ext_win.vert_count == 0) {
        app.mu.unlock();
        if (applog.isEnabled()) applog.appLog("[win] paintExternalWindow: vert_count=0, skipping\n", .{});
        return;
    }

    // Increment paint reference count to prevent ext_win from being freed during paint.
    // DXGI operations (resize, present) can pump Win32 messages, which could trigger close.
    // This ensures ext_win remains valid until paint completes.
    ext_win.paint_ref_count += 1;
    if (applog.isEnabled()) applog.appLog("[win] paintExternalWindow: paint_ref_count++ -> {d}\n", .{ext_win.paint_ref_count});

    // TBS: acquire committed set for painting (lock-free vertex reads).
    const tbs_snapshot = ext_win.tbs.acquireForPaint();
    defer {
        const needs_reinvalidate = ext_win.tbs.releaseFromPaint(tbs_snapshot.committed_index);
        if (needs_reinvalidate) {
            _ = c.InvalidateRect(hwnd, null, 0);
        }
    }
    const tbs_committed = &ext_win.tbs.sets[tbs_snapshot.committed_index];

    // Get renderer and atlas
    const gpu_ptr: ?*d3d11.Renderer = &ext_win.renderer;
    var atlas_ptr: ?*dwrite_d2d.Renderer = null;
    if (app.atlas) |*a| atlas_ptr = a;

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
            ext_win.paint_ref_count -= 1;
            app.mu.unlock();
            if (applog.isEnabled()) applog.appLog("[win] paintExternalWindow: failed to grow scratch buffer\n", .{});
            return;
        }
        // Append cursor vertices so decorated surfaces (cmdline) can render the cursor.
        const cursor_items = ext_win.surface.cursor_verts.items;
        if (cursor_items.len > 0) {
            ext_win.paint_scratch.appendSlice(app.alloc, cursor_items) catch {};
            vert_count += cursor_items.len;
        }
    }

    const cursor_blink_visible = ext_win.cursor_blink_state;
    ext_win.needs_redraw = false;

    // Dirty state snapshot from TBS (row-mode normal windows only).
    var dirty_row_keys: std.ArrayListUnmanaged(u32) = .{};
    if (is_row_mode_normal) {
        var dit = ext_win.tbs.paint_dirty_snapshot.iterator(.{});
        while (dit.next()) |row_idx| {
            dirty_row_keys.append(app.alloc, @intCast(row_idx)) catch break;
        }
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

    // Check if we need to upload the full atlas (atlas version changed)
    const current_atlas_version: u64 = if (atlas_ptr) |a| a.atlas_version else 0;
    const need_full_atlas_upload = ext_win.atlas_version < current_atlas_version;
    if (need_full_atlas_upload) {
        ext_win.atlas_version = current_atlas_version;
    }

    // Scroll state is now bundled in tbs_snap (atomically consistent with committed set).

    app.mu.unlock();

    defer dirty_row_keys.deinit(app.alloc);

    // Query glow state from core (thread-safe, no lock needed)
    const glow_enabled = if (app.corep) |cp| core.zonvie_core_get_glow_enabled(cp) else false;
    const glow_intensity = if (app.corep) |cp| core.zonvie_core_get_glow_intensity(cp) else @as(f32, 0.8);

    // Ensure paint_ref_count is decremented when we exit (handles all return paths)
    defer finishExternalWindowPaint(app, grid_id);

    // Use the per-window scratch buffer (safe: each window has its own)
    const verts = ext_win.paint_scratch.items;

    if (gpu_ptr) |g| {
        g.lockContext();
        defer g.unlockContext();

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
            };
            // back_tex was recreated — force full repaint so all rows are redrawn.
            ext_paint_full = true;

            // After resize, DXGI may have pumped messages. Check if ext_win was closed.
            app.mu.lock();
            const still_valid = app.external_windows.contains(grid_id);
            app.mu.unlock();
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
            ext_win.atlas_upload_cursor = app_mod.flushAtlasUploads(a, g, ext_win.atlas_upload_cursor, need_full_atlas_upload);
        }

        // Set clear color from cached highlight group bg colors (no grid_mu acquisition).
        // NormalFloat for float-origin externals, MsgArea for cmdline/messages, Pmenu for popupmenu.
        setExternalWindowClearColor(g, app, surface_kind, ext_win);

        if (surface_kind != .normal) {
            drawDecoratedExternalSurface(surface_kind, g, app, grid_id, verts, vert_count, cmdline_firstc, glow_enabled, glow_intensity) catch |e| {
                if (applog.isEnabled()) applog.appLog("[win] paintExternalWindow decorated draw failed: {any}\n", .{e});
                return;
            };
            if (applog.isEnabled()) applog.appLog("[win] paintExternalWindow draw succeeded, presenting\n", .{});
            g.presentOnlyFromBack(null) catch |e| {
                if (applog.isEnabled()) applog.appLog("[win] paintExternalWindow present failed: {any}\n", .{e});
                return;
            };
            if (applog.isEnabled()) applog.appLog("[win] paintExternalWindow present succeeded\n", .{});
            return;
        }

        switch (surface_kind) {
            .normal => {
                drawNormalExternalSurface(
                    g,
                    app,
                    ext_win,
                    tbs_committed,
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
                ) catch |e| {
                    if (applog.isEnabled()) applog.appLog("[win] paintExternalWindow normal draw failed: {any}\n", .{e});
                    return;
                };
            },
            else => unreachable,
        }

        if (applog.isEnabled()) applog.appLog("[win] paintExternalWindow draw succeeded, presenting\n", .{});

        // Always full-present for external windows. They are small enough
        // that the full back→front copy cost is negligible, and partial
        // present (presentOnlyFromBackRectsNoResize) causes black regions
        // with DXGI flip-model triple buffering because non-covered areas
        // of the front buffer retain stale/uninitialized content.
        g.presentOnlyFromBack(null) catch |e| {
            if (applog.isEnabled()) applog.appLog("[win] paintExternalWindow present failed: {any}\n", .{e});
            return;
        };

        if (applog.isEnabled()) applog.appLog("[win] paintExternalWindow present succeeded\n", .{});
    } else {
        if (applog.isEnabled()) applog.appLog("[win] paintExternalWindow no gpu_ptr\n", .{});
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
        const ext = entry.value_ptr;
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

/// Swap positions of two windows by HWND, keeping each window's own size.
fn swapWindowPositions(hwnd_a: c.HWND, rect_a: c.RECT, hwnd_b: c.HWND, rect_b: c.RECT) void {
    const w_a = rect_a.right - rect_a.left;
    const h_a = rect_a.bottom - rect_a.top;
    const w_b = rect_b.right - rect_b.left;
    const h_b = rect_b.bottom - rect_b.top;
    // A moves to B's position but keeps A's size
    _ = c.SetWindowPos(hwnd_a, null, rect_b.left, rect_b.top, w_a, h_a, c.SWP_NOZORDER | c.SWP_NOACTIVATE);
    // B moves to A's position but keeps B's size
    _ = c.SetWindowPos(hwnd_b, null, rect_a.left, rect_a.top, w_b, h_b, c.SWP_NOZORDER | c.SWP_NOACTIVATE);
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

    app.mu.lock();
    const coll = collectWindowInfos(app, true);
    app.mu.unlock();

    const infos = coll.infos[0..coll.count];
    if (findInDirection(infos, grid_id, flags, 1)) |target| {
        // Find source rect
        for (infos) |info| {
            if (info.grid_id == grid_id) {
                swapWindowPositions(info.hwnd, info.rect, target.hwnd, target.rect);
                break;
            }
        }
    }
}

pub fn onWinExchange(ctx: ?*anyopaque, grid_id: i64, win: i64, count: i32) callconv(.c) void {
    _ = win;
    const app: *App = @ptrCast(@alignCast(ctx.?));
    if (applog.isEnabled()) applog.appLog("[win] on_win_exchange: grid={d} count={d}\n", .{ grid_id, count });

    app.mu.lock();
    const coll = collectWindowInfos(app, true);
    app.mu.unlock();

    if (coll.count < 2) return;
    var sorted: [MAX_WIN_INFOS]WindowInfo = coll.infos;
    sortSpatially(sorted[0..coll.count]);

    // Find source index
    var src_idx: ?usize = null;
    for (sorted[0..coll.count], 0..) |info, i| {
        if (info.grid_id == grid_id) { src_idx = i; break; }
    }
    const si = src_idx orelse return;

    // count=0 means "next window" (default for <C-w>x without count prefix)
    const effective_count: i32 = if (count == 0) 1 else count;
    const n: i32 = @intCast(coll.count);
    var dst: i32 = @as(i32, @intCast(si)) + effective_count;
    dst = @mod(dst, n);
    if (dst < 0) dst += n;
    const di: usize = @intCast(dst);
    if (di == si) return;

    swapWindowPositions(sorted[si].hwnd, sorted[si].rect, sorted[di].hwnd, sorted[di].rect);
}

/// Defers SetWindowPos to UI thread via PostMessage to avoid blocking the core
/// thread on cross-thread message processing while grid_mu is held.
pub fn onWinRotate(ctx: ?*anyopaque, grid_id: i64, win: i64, direction: i32, count: i32) callconv(.c) void {
    _ = grid_id;
    _ = win;
    const app: *App = @ptrCast(@alignCast(ctx.?));
    if (applog.isEnabled()) applog.appLog("[win] on_win_rotate: direction={d} count={d}\n", .{ direction, count });

    app.mu.lock();
    const coll = collectWindowInfos(app, true);
    const hwnd = app.hwnd;

    if (coll.count < 2) {
        app.mu.unlock();
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

    // count=0 means "rotate once" (default for <C-w>r without count prefix)
    const effective_count: usize = if (count == 0) 1 else @intCast(count);
    const n = coll.count;
    for (0..effective_count) |_| {
        if (direction == 0) {
            // Downward rotation
            const last_left = lefts[n - 1];
            const last_top = tops[n - 1];
            var i: usize = n - 1;
            while (i > 0) : (i -= 1) {
                lefts[i] = lefts[i - 1];
                tops[i] = tops[i - 1];
            }
            lefts[0] = last_left;
            tops[0] = last_top;
        } else {
            // Upward rotation
            const first_left = lefts[0];
            const first_top = tops[0];
            for (0..n - 1) |i| {
                lefts[i] = lefts[i + 1];
                tops[i] = tops[i + 1];
            }
            lefts[n - 1] = first_left;
            tops[n - 1] = first_top;
        }
    }

    // Replace semantics: reset count before writing new batch
    app.deferred_win_ops_count = 0;
    for (0..n) |i| {
        if (i >= App.MAX_DEFERRED_WIN_OPS) break;
        app.deferred_win_ops[i] = .{
            .hwnd = sorted[i].hwnd,
            .x = lefts[i],
            .y = tops[i],
            .w = sorted[i].rect.right - sorted[i].rect.left,
            .h = sorted[i].rect.bottom - sorted[i].rect.top,
            .flags = c.SWP_NOZORDER | c.SWP_NOACTIVATE,
        };
        app.deferred_win_ops_count = i + 1;
    }
    app.mu.unlock();

    if (hwnd) |h| {
        if (c.PostMessageW(h, app_mod.WM_APP_DEFERRED_WIN_POS, 0, 0) == 0) {
            if (applog.isEnabled()) applog.appLog("[win] on_win_rotate: PostMessageW failed\n", .{});
            app.mu.lock();
            app.deferred_win_ops_count = 0;
            app.mu.unlock();
        }
    }
}

/// Make all windows equal size (including main window).
/// Defers SetWindowPos to UI thread via PostMessage to avoid deadlock:
/// SetWindowPos on the main window from core thread sends WM_SIZE → updateLayoutToCore → grid_mu.lock()
/// while grid_mu is already held by the core thread during this callback.
pub fn onWinResizeEqual(ctx: ?*anyopaque) callconv(.c) void {
    const app: *App = @ptrCast(@alignCast(ctx.?));
    if (applog.isEnabled()) applog.appLog("[win] on_win_resize_equal\n", .{});

    app.mu.lock();
    const coll = collectWindowInfos(app, true);
    const hwnd = app.hwnd;

    if (coll.count < 2) {
        app.mu.unlock();
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

    // Replace semantics: reset count before writing new batch
    app.deferred_win_ops_count = 0;
    for (infos, 0..) |info, i| {
        if (i >= App.MAX_DEFERRED_WIN_OPS) break;
        app.deferred_win_ops[i] = .{
            .hwnd = info.hwnd,
            .x = info.rect.left,
            .y = info.rect.top,
            .w = avg_w,
            .h = avg_h,
            .flags = c.SWP_NOZORDER | c.SWP_NOACTIVATE,
        };
        app.deferred_win_ops_count = i + 1;
    }
    app.mu.unlock();

    if (hwnd) |h| {
        if (c.PostMessageW(h, app_mod.WM_APP_DEFERRED_WIN_POS, 0, 0) == 0) {
            if (applog.isEnabled()) applog.appLog("[win] on_win_resize_equal: PostMessageW failed\n", .{});
            app.mu.lock();
            app.deferred_win_ops_count = 0;
            app.mu.unlock();
        }
    }
}

pub fn onWinMoveCursor(ctx: ?*anyopaque, direction: i32, count: i32) callconv(.c) i64 {
    const app: *App = @ptrCast(@alignCast(ctx.?));
    if (applog.isEnabled()) applog.appLog("[win] on_win_move_cursor: direction={d} count={d}\n", .{ direction, count });

    app.mu.lock();
    const cursor_grid = app.last_cursor_grid;
    const coll = collectWindowInfos(app, true);
    const corep = app.corep;
    app.mu.unlock();

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
