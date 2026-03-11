const std = @import("std");
const app_mod = @import("app.zig");
const App = app_mod.App;
const c = app_mod.c;
const applog = app_mod.applog;
const d3d11 = app_mod.d3d11;
const dwrite_d2d = app_mod.dwrite_d2d;


// ---- Logging globals for atlas ensure callbacks ----
var log_atlas_ensure_calls: u64 = 0;
var log_atlas_ensure_suspicious: u64 = 0;
var log_atlas_ensure_last_report_ns: i128 = 0;
var log_atlas_zero_bbox_count: u32 = 0;
var log_row_no_glyphs_count: u32 = 0;
var log_row_bad_uv_count: u32 = 0;

// Track styled glyph stats
var log_styled_glyph_calls: u64 = 0;
var log_styled_glyph_ok: u64 = 0;
var log_styled_glyph_fail: u64 = 0;
var log_styled_glyph_last_report_ns: i128 = 0;

// =========================================================================
// Helper functions used by callbacks
// =========================================================================

/// Convert NDC cursor vertices to a pixel RECT using the D3D11 viewport
/// dimensions. The viewport is snapped to cell boundaries (content_height),
/// which is typically smaller than the full client area. Using the client
/// rect directly would cause cumulative position drift toward the bottom.
pub fn cursorRectInViewport(
    verts: []const app_mod.Vertex,
    vp_x: u32,
    vp_y: u32,
    vp_w: u32,
    vp_h: u32,
    clamp_right: i32,
    clamp_bottom: i32,
) ?c.RECT {
    if (verts.len == 0) return null;

    var minx: f32 = verts[0].position[0];
    var maxx: f32 = minx;
    var miny: f32 = verts[0].position[1];
    var maxy: f32 = miny;

    for (verts) |v| {
        if (v.position[0] < minx) minx = v.position[0];
        if (v.position[0] > maxx) maxx = v.position[0];
        if (v.position[1] < miny) miny = v.position[1];
        if (v.position[1] > maxy) maxy = v.position[1];
    }

    const w_f: f32 = @floatFromInt(vp_w);
    const h_f: f32 = @floatFromInt(vp_h);
    const x_off_f: f32 = @floatFromInt(vp_x);
    const y_off_f: f32 = @floatFromInt(vp_y);

    // NDC -> viewport pixel (absolute coords)
    const l_f = x_off_f + (minx + 1.0) * 0.5 * w_f;
    const r_f = x_off_f + (maxx + 1.0) * 0.5 * w_f;
    const t_f = y_off_f + (1.0 - maxy) * 0.5 * h_f;
    const b_f = y_off_f + (1.0 - miny) * 0.5 * h_f;

    var l: i32 = @intFromFloat(@floor(l_f));
    var r: i32 = @intFromFloat(@ceil(r_f));
    var t: i32 = @intFromFloat(@floor(t_f));
    var b: i32 = @intFromFloat(@ceil(b_f));

    if (l < 0) l = 0;
    if (t < 0) t = 0;
    if (r > clamp_right) r = clamp_right;
    if (b > clamp_bottom) b = clamp_bottom;

    if (r <= l or b <= t) return null;
    return .{ .left = l, .top = t, .right = r, .bottom = b };
}

pub fn rectFromVerts(hwnd: c.HWND, verts: []const app_mod.Vertex) ?c.RECT {
    if (verts.len == 0) return null;

    var client: c.RECT = undefined;
    _ = c.GetClientRect(hwnd, &client);

    const w_f: f32 = @floatFromInt(@max(1, client.right - client.left));
    const h_f: f32 = @floatFromInt(@max(1, client.bottom - client.top));

    var minx: f32 = verts[0].position[0];
    var maxx: f32 = verts[0].position[0];
    var miny: f32 = verts[0].position[1];
    var maxy: f32 = verts[0].position[1];

    for (verts) |v| {
        const x = v.position[0];
        const y = v.position[1];
        if (x < minx) minx = x;
        if (x > maxx) maxx = x;
        if (y < miny) miny = y;
        if (y > maxy) maxy = y;
    }

    // NDC -> pixel
    const l_f = (minx + 1.0) * 0.5 * w_f;
    const r_f = (maxx + 1.0) * 0.5 * w_f;
    const t_f = (1.0 - maxy) * 0.5 * h_f;
    const b_f = (1.0 - miny) * 0.5 * h_f;

    var l: i32 = @intFromFloat(@floor(l_f));
    var r: i32 = @intFromFloat(@ceil(r_f));
    var t: i32 = @intFromFloat(@floor(t_f));
    var b: i32 = @intFromFloat(@ceil(b_f));

    // clamp
    if (l < 0) l = 0;
    if (t < 0) t = 0;
    if (r > client.right) r = client.right;
    if (b > client.bottom) b = client.bottom;

    if (r <= l or b <= t) return null;

    return .{ .left = l, .top = t, .right = r, .bottom = b };
}

pub fn markDirtyRowsByRect(app: *App, rc: c.RECT) void {
    const row_h: u32 = @max(1, app.cell_h_px + app.linespace_px);

    // When ext_tabline is enabled (and content_hwnd is not used), the rect coordinates
    // are in hwnd (main window) coordinate system which includes the tabbar.
    // We need to subtract the tabbar height to get the correct row number.
    const y_offset: i32 = if (app.ext_tabline_enabled and app.content_hwnd == null)
        app.scalePx(app_mod.TablineState.TAB_BAR_HEIGHT)
    else
        0;

    const top_u: u32 = @intCast(@max(0, rc.top - y_offset));
    const bot_u: u32 = @intCast(@max(0, rc.bottom - y_offset));

    var r0: u32 = top_u / row_h;
    var r1: u32 = (bot_u + (row_h - 1)) / row_h; // ceil

    // Clamp to current grid rows to avoid out-of-bounds (e.g. r == rows).
    const max_rows: u32 = app.rows;
    if (max_rows != 0) {
        if (r0 > max_rows) r0 = max_rows;
        if (r1 > max_rows) r1 = max_rows;
    }

    var r: u32 = r0;
    while (r < r1) : (r += 1) {
        _ = app.dirty_rows.put(app.alloc, r, {}) catch {};
    }
}

fn shiftVertsY(verts: []app_mod.Vertex, delta_y: f32) void {
    for (verts) |*v| {
        v.position[1] += delta_y;
    }
}

fn recomputeRowValidCount(app: *App) void {
    var count: u32 = 0;
    var i: usize = 0;
    while (i < app.row_valid.bit_length) : (i += 1) {
        if (app.row_valid.isSet(i)) count += 1;
    }
    app.row_valid_count = count;
}

pub fn appendRowsFromUpdateRegion(
    hwnd: c.HWND,
    app: *App,
    rows_to_draw: *std.ArrayListUnmanaged(u32),
    row_verts_len: u32,
) void {
    const log_enabled = applog.isEnabled();
    const log_t0_ns: i128 = if (log_enabled) std.time.nanoTimestamp() else 0;

    // Pre-allocate capacity for worst case (all rows dirty)
    rows_to_draw.ensureTotalCapacity(app.alloc, row_verts_len) catch {};

    var log_rect_area_sum: u64 = 0;
    var log_rows_appended: u32 = 0;

    // Create an empty region to receive the update region.
    const hrgn = c.CreateRectRgn(0, 0, 0, 0) orelse return;
    defer _ = c.DeleteObject(hrgn);

    // Populate hrgn with the window's update region (do not erase).
    const rgn_type: c.INT = c.GetUpdateRgn(hwnd, hrgn, c.FALSE);
    if (rgn_type == c.ERROR) return;

    const need_bytes: c.DWORD = c.GetRegionData(hrgn, 0, null);
    if (need_bytes == 0) return;

    if (log_enabled) {
        applog.appLog("[win] updateRgn need_bytes={d} rgn_type={d}\n", .{ need_bytes, rgn_type });
    }

    // RGNDATA needs alignment; use alignedAlloc.
    const alignment: std.mem.Alignment =
        @enumFromInt(@ctz(@as(usize, @alignOf(c.RGNDATA))));

    const buf = app.alloc.alignedAlloc(u8, alignment, need_bytes) catch return;
    defer app.alloc.free(buf);

    const rgndata: *c.RGNDATA = @ptrCast(@alignCast(buf.ptr));
    const got_bytes: c.DWORD = c.GetRegionData(hrgn, need_bytes, rgndata);
    if (got_bytes == 0) return;

    const row_h_px0: i32 = @intCast(@as(i32, @intCast(app.cell_h_px + app.linespace_px)));

    // RECT array starts at rgndata.Buffer (flexible array).
    const rects_ptr_u8: [*]u8 = @ptrCast(&rgndata.Buffer);
    const rects_ptr: [*]c.RECT = @ptrCast(@alignCast(rects_ptr_u8));

    const n: usize = @intCast(rgndata.rdh.nCount);

    var i: usize = 0;
    while (i < n) : (i += 1) {
        const dr = rects_ptr[i];

        const top_px: i32 = @max(0, dr.top);
        const bottom_px: i32 = @max(0, dr.bottom);

        // area accumulation (clamp negatives)
        const w_i32: i32 = dr.right - dr.left;
        const h_i32: i32 = dr.bottom - dr.top;
        if (w_i32 > 0 and h_i32 > 0) {
            log_rect_area_sum += @as(u64, @intCast(w_i32)) * @as(u64, @intCast(h_i32));
        }

        // [top_row, bottom_row)
        const top_row_i32: i32 = @divTrunc(top_px, row_h_px0);
        const bottom_row_i32: i32 = @divTrunc(bottom_px + (row_h_px0 - 1), row_h_px0);

        const top_row: u32 = @intCast(@max(0, top_row_i32));
        const bottom_row: u32 = @intCast(@min(@as(i32, @intCast(row_verts_len)), bottom_row_i32));

        var rr: u32 = top_row;
        while (rr < bottom_row) : (rr += 1) {
            rows_to_draw.appendAssumeCapacity(rr);
            log_rows_appended += 1;
        }
    }

    if (log_enabled) {
        const log_t1_ns: i128 = std.time.nanoTimestamp();
        const log_dur_us: u64 = @intCast(@max(@as(i128, 0), log_t1_ns - log_t0_ns) / 1_000);
        applog.appLog(
            "[win] updateRgn rects={d} rows_appended={d} area_px={d} dur_us={d} got_bytes={d}\n",
            .{ n, log_rows_appended, log_rect_area_sum, log_dur_us, got_bytes },
        );
    }
}

pub fn unionRect(a: c.RECT, b: c.RECT) c.RECT {
    return .{
        .left = if (a.left < b.left) a.left else b.left,
        .top = if (a.top < b.top) a.top else b.top,
        .right = if (a.right > b.right) a.right else b.right,
        .bottom = if (a.bottom > b.bottom) a.bottom else b.bottom,
    };
}

// =========================================================================
// Vertex / rendering callbacks
// =========================================================================

pub fn onVertices(
    ctx: ?*anyopaque,
    main_ptr: [*]const app_mod.Vertex,
    main_count: usize,
    cursor_ptr: [*]const app_mod.Vertex,
    cursor_count: usize,
) callconv(.c) void {
        const app: *App = @ptrCast(@alignCast(ctx.?));
        app.mu.lock();
        defer app.mu.unlock();

    app.main_verts.clearRetainingCapacity();
    app.cursor_verts.clearRetainingCapacity();

    // On OOM, skip ALL vertex copies (all-or-nothing to avoid drawing
    // cursor-only frames) but still fall through to InvalidateRect
    // so the screen can retry on the next frame.
    const main_ok = if (app.main_verts.ensureTotalCapacity(app.alloc, main_count)) true else |_| false;
    const cursor_ok = if (main_ok)
        (if (app.cursor_verts.ensureTotalCapacity(app.alloc, cursor_count)) true else |_| false)
    else
        false;
    if (main_ok and cursor_ok) {
        app.main_verts.appendSliceAssumeCapacity(main_ptr[0..main_count]);
        app.cursor_verts.appendSliceAssumeCapacity(cursor_ptr[0..cursor_count]);
    }

    if (app.row_mode) {
        app.row_mode = false;
    }

    if (app.hwnd) |hwnd| {
        _ = c.InvalidateRect(hwnd, null, c.FALSE);
        app.paint_full = true;
        app.paint_rects.clearRetainingCapacity();
    }
}

pub fn onVerticesPartial(
    ctx: ?*anyopaque,
    main_ptr: ?[*]const app_mod.Vertex,
    main_count: usize,
    cursor_ptr: ?[*]const app_mod.Vertex,
    cursor_count: usize,
    flags: u32,
) callconv(.c) void {
    const app: *App = @ptrCast(@alignCast(ctx.?));

    if (applog.isEnabled()) applog.appLog(
        "[win] onVerticesPartial flags=0x{x} main_count={d} cursor_count={d}\n",
        .{ flags, main_count, cursor_count },
    );

    app.mu.lock();

    var row_mode = app.row_mode;

    // Track whether we already invalidated something specific.
    var did_invalidate: bool = false;
    // Track if cursor was updated (for blink update after unlock)
    var cursor_updated: bool = false;

    // Flags specification: keep the side that is not updated
    if ((flags & app_mod.VERT_UPDATE_MAIN) != 0) {
        if (row_mode) {
            app.row_mode = false;
            row_mode = false;
        }
        // Note: We don't set content_rows_dirty here.
        // For non-row-mode, full repaints are triggered anyway.
        // For row-mode, WM_PAINT determines if it's cursor-only.

        app.main_verts.clearRetainingCapacity();
        if (main_ptr != null and main_count != 0) {
            app.main_verts.appendSlice(app.alloc, main_ptr.?[0..main_count]) catch {};
        }

        // Non-row-mode: main update implies screen update; invalidate whole client.
        // Row-mode: main_verts is not used for drawing; do not force full invalidate here.
        if (!row_mode) {
            if (app.hwnd) |hwnd| {
                _ = c.InvalidateRect(hwnd, null, c.FALSE);
                did_invalidate = true;
                app.paint_full = true;
                app.paint_rects.clearRetainingCapacity();
            }
        }
    }

    if ((flags & app_mod.VERT_UPDATE_CURSOR) != 0) {
        // compute old rect before overwriting cursor_verts
        const old_rc = app.last_cursor_rect_px;

        app.cursor_verts.clearRetainingCapacity();
        if (cursor_ptr != null and cursor_count != 0) {
            const slice = cursor_ptr.?[0..cursor_count];

            // Log cursor vertex data for debugging
            if (applog.isEnabled() and slice.len >= 1) {
                const v0 = slice[0];
                applog.appLog(
                    "[win] onVerticesPartial cursor v0: pos=({d:.2},{d:.2}) col=({d:.3},{d:.3},{d:.3},{d:.3})\n",
                    .{ v0.position[0], v0.position[1], v0.color[0], v0.color[1], v0.color[2], v0.color[3] },
                );
            }
            app.cursor_verts.appendSlice(app.alloc, slice) catch {};

            if (app.hwnd) |hwnd| {
                // Compute viewport-aware cursor rect matching D3D11 viewport.
                const rect_hwnd = if (app.content_hwnd) |ch| ch else hwnd;
                var rect_client: c.RECT = undefined;
                _ = c.GetClientRect(rect_hwnd, &rect_client);

                const vp_y: u32 = if (app.ext_tabline_enabled and app.tabline_style == .titlebar and app.content_hwnd == null)
                    @intCast(app.scalePx(app_mod.TablineState.TAB_BAR_HEIGHT))
                else
                    0;
                const vp_x: u32 = if (app.ext_tabline_enabled and app.tabline_style == .sidebar and !app.sidebar_position_right)
                    @intCast(app.scalePx(@as(c_int, @intCast(app.sidebar_width_px))))
                else
                    0;
                const sidebar_r: u32 = if (app.ext_tabline_enabled and app.tabline_style == .sidebar and app.sidebar_position_right)
                    @intCast(app.scalePx(@as(c_int, @intCast(app.sidebar_width_px))))
                else
                    0;
                const client_w: u32 = @intCast(@max(1, rect_client.right));
                const client_h: u32 = @intCast(@max(1, rect_client.bottom));
                const base_w: u32 = if (app.config.scrollbar.enabled and app.config.scrollbar.isAlways())
                    app_mod.getEffectiveContentWidth(app, client_w)
                else
                    client_w;
                const vp_w: u32 = if (base_w > vp_x + sidebar_r) base_w - vp_x - sidebar_r else 1;
                const cell_total_h: u32 = @max(1, app.cell_h_px + app.linespace_px);
                const drawable_h: u32 = if (client_h > vp_y) client_h - vp_y else 0;
                const vp_h: u32 = @max((drawable_h / cell_total_h) * cell_total_h, cell_total_h);

                const new_rc = cursorRectInViewport(slice, vp_x, vp_y, vp_w, vp_h, rect_client.right, rect_client.bottom);
                app.last_cursor_rect_px = new_rc;

                // Row-mode: cursor move should only invalidate cursor rects.
                if (row_mode) {
                    if (!app.cursor_overlay_active) {
                        app.cursor_overlay_active = true;
                        app.need_full_seed.store(true, .seq_cst);
                        _ = c.InvalidateRect(hwnd, null, c.FALSE);
                        app.paint_full = true;
                        app.paint_rects.clearRetainingCapacity();
                    }
                    if (old_rc) |r0| {
                        _ = c.InvalidateRect(hwnd, &r0, c.FALSE);
                        did_invalidate = true;

                        // NEW: record exact damage rect we requested
                        app.paint_rects.append(app.alloc, r0) catch {};
                    }
                    if (new_rc) |r1| {
                        _ = c.InvalidateRect(hwnd, &r1, c.FALSE);
                        did_invalidate = true;

                        // NEW: record exact damage rect we requested
                        app.paint_rects.append(app.alloc, r1) catch {};
                    }
                    if (old_rc) |r0| {
                        markDirtyRowsByRect(app, r0);
                    }
                    if (new_rc) |r1| {
                        markDirtyRowsByRect(app, r1);
                    }

                } else {
                    // Non-row-mode: still try to invalidate only cursor union instead of full screen.
                    if (old_rc != null and new_rc != null) {
                        var u = unionRect(old_rc.?, new_rc.?);
                        _ = c.InvalidateRect(hwnd, &u, c.FALSE);
                        did_invalidate = true;
                    } else if (old_rc) |r0| {
                        _ = c.InvalidateRect(hwnd, &r0, c.FALSE);
                        did_invalidate = true;
                    } else if (new_rc) |r1| {
                        _ = c.InvalidateRect(hwnd, &r1, c.FALSE);
                        did_invalidate = true;
                    }
                }
            }
        } else {
            // no cursor verts -> clear last rect
            app.last_cursor_rect_px = null;

            // If cursor disappeared, invalidate old cursor rect only (if any).
            if (app.hwnd) |hwnd| {
                if (old_rc) |r0| {
                    _ = c.InvalidateRect(hwnd, &r0, c.FALSE);
                    did_invalidate = true;
                }
            }
            if (row_mode) {
                if (old_rc) |r0| {
                    markDirtyRowsByRect(app, r0);
                }
            }
        }

        // NEW: cursor verts updated => bump generation
        app.cursor_gen +%= 1;
        cursor_updated = true;
    }

    // If nothing was invalidated (should be rare):
    // - Non-row-mode: request a repaint (fallback to full client).
    // - Row-mode: DO NOT full-invalidate here; row updates come via onVerticesRow and
    //   cursor updates via onVerticesPartial(cursor). A full invalidate here defeats dirty-rect rendering.
    if (!did_invalidate) {
        if (!row_mode) {
            if (app.hwnd) |hwnd| {
                _ = c.InvalidateRect(hwnd, null, c.FALSE);
                app.paint_full = true;
                app.paint_rects.clearRetainingCapacity();
            }
        }
    }

    // Get hwnd before unlock
    const hwnd_for_blink = app.hwnd;

    app.mu.unlock();

    // Post message to update cursor blinking (avoid deadlock by doing it on UI thread)
    if (cursor_updated) {
        if (hwnd_for_blink) |hwnd| {
            _ = c.PostMessageW(hwnd, app_mod.WM_APP_UPDATE_CURSOR_BLINK, 0, 0);
        }
    }
}

pub fn onRenderPlan(
    ctx: ?*anyopaque,
    bg_spans: ?[*]const app_mod.BgSpan,
    bg_span_count: usize,
    text_runs: ?[*]const app_mod.TextRun,
    text_run_count: usize,
    rows: u32,
    cols: u32,
    cursor_ptr: ?*const app_mod.Cursor,
) callconv(.c) void {
    _ = bg_spans;
    _ = bg_span_count;
    _ = text_runs;
    _ = text_run_count;

    const app: *App = @ptrCast(@alignCast(ctx.?));

    // Read cursor outside lock (cursor_ptr is valid for duration of callback)
    var new_cursor: ?app_mod.Cursor = null;
    if (cursor_ptr) |p| new_cursor = p.*;

    // Keep the latest grid size for bounds checks / clamping.
    // Use single lock region to prevent race conditions.
    app.mu.lock();
    defer app.mu.unlock();

    if (rows != app.rows or cols != app.cols) {
        app.rows = rows;
        app.cols = cols;
        app.seed_pending = true;
        app.seed_clear_pending = true;
        app.row_valid_count = 0;
        app.row_mode_max_row_end = 0;
        app.row_layout_gen +%= 1;
        if (rows != 0) {
            app.row_valid.resize(app.alloc, @intCast(rows), false) catch {};
            app.row_valid.unsetAll();
        } else if (app.row_valid.bit_length != 0) {
            app.row_valid.unsetAll();
        }
        // Clear old row vertex data to prevent ghost rendering from stale vertices.
        // Each RowVerts entry's verts array is cleared; GPU VBs will be re-uploaded.
        for (app.row_verts.items) |*rv| {
            rv.verts.clearRetainingCapacity();
            rv.gen +%= 1; // Invalidate any cached GPU upload
        }
    } else {
        app.rows = rows;
        app.cols = cols;
    }

    // NOTE: cursor_ptr may be null => treat as disabled/none
    app.cursor = new_cursor;

    if (applog.isEnabled()) applog.appLog("[win] on_render_plan rows={d} cols={d}\n", .{ rows, cols });
}

pub fn onVerticesRow(
    ctx: ?*anyopaque,
    grid_id: i64,
    row_start: u32,
    row_count: u32,
    verts_ptr: ?[*]const app_mod.Vertex,
    vert_count: usize,
    flags: u32,
    total_rows: u32,
    total_cols: u32,
) callconv(.c) void {
    const app: *App = @ptrCast(@alignCast(ctx.?));
    app.mu.lock();
    defer app.mu.unlock();

    if (applog.isEnabled()) {
        var cur_enabled: u32 = 0;
        var cur_row: u32 = 0;
        var cur_col: u32 = 0;
        if (app.cursor) |cur| {
            cur_enabled = cur.enabled;
            cur_row = cur.row;
            cur_col = cur.col;
        }
        if (applog.isEnabled()) applog.appLog(
            "[win] on_vertices_row row_start={d} row_count={d} vert_count={d} flags=0x{x} cursor_en={d} cursor_row={d} cursor_col={d} rows={d} row_valid={d} row_verts_len={d}\n",
            .{
                row_start,
                row_count,
                vert_count,
                flags,
                cur_enabled,
                cur_row,
                cur_col,
                app.rows,
                app.row_valid_count,
                app.row_verts.items.len,
            },
        );
    }
    if (row_count != 1 and applog.isEnabled()) {
        applog.appLog(
            "[win] on_vertices_row WARN row_count={d} row_start={d} vert_count={d}\n",
            .{ row_count, row_start, vert_count },
        );
    }
    if (applog.isEnabled() and verts_ptr != null and vert_count != 0) {
        const verts = verts_ptr.?[0..vert_count];
        var glyph_verts: u32 = 0;
        var bad_uv: u32 = 0;
        var bad_pos: u32 = 0;
        var i: usize = 0;
        while (i < verts.len) : (i += 1) {
            const v = verts[i];
            const u = v.texCoord[0];
            const v2 = v.texCoord[1];
            if (!(u == -1.0 and v2 == -1.0)) {
                glyph_verts += 1;
                if (!std.math.isFinite(u) or !std.math.isFinite(v2)) {
                    bad_uv += 1;
                } else if (u < 0.0 or u > 1.0 or v2 < 0.0 or v2 > 1.0) {
                    bad_uv += 1;
                }
            }
            if (!std.math.isFinite(v.position[0]) or !std.math.isFinite(v.position[1])) {
                bad_pos += 1;
            }
        }
        if (glyph_verts == 0 and vert_count >= 12 and log_row_no_glyphs_count < 16) {
            applog.appLog(
                "[win] on_vertices_row WARN no_glyphs row_start={d} vert_count={d}\n",
                .{ row_start, vert_count },
            );
            log_row_no_glyphs_count += 1;
        }
        if ((bad_uv != 0 or bad_pos != 0) and log_row_bad_uv_count < 16) {
            applog.appLog(
                "[win] on_vertices_row WARN bad_verts row_start={d} vert_count={d} bad_uv={d} bad_pos={d}\n",
                .{ row_start, vert_count, bad_uv, bad_pos },
            );
            log_row_bad_uv_count += 1;
        }
        // Log first few vertex details for diagnostic (only for rows with glyphs)
        if (glyph_verts > 0 and row_start <= 2) {
            const log_count = @min(verts.len, 6);
            var vi: usize = 0;
            while (vi < log_count) : (vi += 1) {
                const v = verts[vi];
                applog.appLog(
                    "[win] on_vertices_row row={d} v[{d}] pos=({d:.2},{d:.2}) uv=({d:.4},{d:.4}) col=({d:.3},{d:.3},{d:.3},{d:.3})\n",
                    .{
                        row_start, vi,
                        v.position[0], v.position[1],
                        v.texCoord[0], v.texCoord[1],
                        v.color[0], v.color[1], v.color[2], v.color[3],
                    },
                );
            }
            // Also log first few GLYPH vertices (UV != -1,-1)
            var glyph_logged: u32 = 0;
            var gi: usize = 0;
            while (gi < verts.len and glyph_logged < 3) : (gi += 1) {
                const v = verts[gi];
                if (!(v.texCoord[0] == -1.0 and v.texCoord[1] == -1.0)) {
                    applog.appLog(
                        "[win] on_vertices_row row={d} GLYPH v[{d}] pos=({d:.2},{d:.2}) uv=({d:.4},{d:.4}) col=({d:.3},{d:.3},{d:.3},{d:.3})\n",
                        .{
                            row_start, gi,
                            v.position[0], v.position[1],
                            v.texCoord[0], v.texCoord[1],
                            v.color[0], v.color[1], v.color[2], v.color[3],
                        },
                    );
                    glyph_logged += 1;
                }
            }
        }
    }

    // Handle external grids (grid_id != 1) separately
    // External grids use their own vertex storage (ext_win.verts or pending_external_verts)
    if (grid_id != 1) {
        if (applog.isEnabled()) applog.appLog(
            "[win] on_vertices_row external grid_id={d} row_start={d} vert_count={d} total_rows={d} total_cols={d}\n",
            .{ grid_id, row_start, vert_count, total_rows, total_cols },
        );

        // Try to find existing external window for this grid
        if (app.external_windows.getPtr(grid_id)) |ext_win| {
            // Skip windows that are pending close
            if (ext_win.is_pending_close) return;

            // Window exists - store vertices
            // Clear verts when row 0 is received (start of new frame)
            if (row_start == 0) {
                ext_win.verts.clearRetainingCapacity();
                ext_win.vert_count = 0;
            }

            // Append this row's vertices
            if (verts_ptr != null and vert_count != 0) {
                ext_win.verts.ensureTotalCapacity(app.alloc, ext_win.verts.items.len + vert_count) catch return;
                ext_win.verts.appendSliceAssumeCapacity(verts_ptr.?[0..vert_count]);
                ext_win.vert_count = ext_win.verts.items.len;
            }

            // Check if size changed before updating
            const size_changed = (ext_win.rows != total_rows or ext_win.cols != total_cols);

            ext_win.rows = total_rows;
            ext_win.cols = total_cols;
            ext_win.needs_redraw = true;

            // Resize popupmenu window if size changed (keep top-left position)
            // Use deferred resize via PostMessage to avoid deadlock with WM_SIZE handler
            if (grid_id == app_mod.POPUPMENU_GRID_ID and size_changed) {
                const cell_w = app.cell_w_px;
                const cell_h = app.cell_h_px + app.linespace_px;
                const content_w: c_int = @intCast(total_cols * cell_w);
                const content_h: c_int = @intCast(total_rows * cell_h);

                // Calculate window size (WS_POPUP has no decorations, so client = window)
                var rect: c.RECT = .{ .left = 0, .top = 0, .right = content_w, .bottom = content_h };
                _ = c.AdjustWindowRectEx(&rect, c.WS_POPUP, 0, c.WS_EX_TOPMOST);
                const window_w: c_int = rect.right - rect.left;
                const window_h: c_int = rect.bottom - rect.top;

                if (applog.isEnabled()) applog.appLog("[win] on_vertices_row popupmenu resize pending: content=({d},{d}) window=({d},{d})\n", .{ content_w, content_h, window_w, window_h });

                // Store pending resize info and post message to do the actual resize outside of callback
                ext_win.needs_window_resize = true;
                ext_win.pending_window_w = window_w;
                ext_win.pending_window_h = window_h;
                ext_win.needs_renderer_resize = true;

                // Post message to main window to trigger resize asynchronously (outside of lock)
                if (app.hwnd) |main_hwnd| {
                    if (c.PostMessageW(main_hwnd, app_mod.WM_APP_RESIZE_POPUPMENU, @bitCast(app_mod.POPUPMENU_GRID_ID), 0) == 0) {
                        // PostMessage failed, reset flag to avoid stale state
                        ext_win.needs_window_resize = false;
                        if (applog.isEnabled()) applog.appLog("[win] on_vertices_row popupmenu PostMessageW failed\n", .{});
                    }
                } else {
                    // No main hwnd, reset flag
                    ext_win.needs_window_resize = false;
                }
            }

            // Invalidate window to trigger repaint
            _ = c.InvalidateRect(ext_win.hwnd, null, 0);

            if (applog.isEnabled()) applog.appLog(
                "[win] on_vertices_row external grid_id={d} updated ext_win vert_count={d}\n",
                .{ grid_id, ext_win.vert_count },
            );
        } else {
            // Window doesn't exist yet - store in pending_external_verts
            // Find or create pending entry for this grid_id
            var found_idx: ?usize = null;
            for (app.pending_external_verts.items, 0..) |*pv, i| {
                if (pv.grid_id == grid_id) {
                    found_idx = i;
                    break;
                }
            }

            if (found_idx) |idx| {
                // Update existing pending entry
                const pv = &app.pending_external_verts.items[idx];
                // Clear when row 0 is received
                if (row_start == 0) {
                    pv.verts.clearRetainingCapacity();
                }
                if (verts_ptr != null and vert_count != 0) {
                    pv.verts.ensureTotalCapacity(app.alloc, pv.verts.items.len + vert_count) catch return;
                    pv.verts.appendSliceAssumeCapacity(verts_ptr.?[0..vert_count]);
                }
                pv.rows = total_rows;
                pv.cols = total_cols;
            } else {
                // Create new pending entry
                var new_pv = app_mod.PendingExternalVertices{
                    .grid_id = grid_id,
                    .rows = total_rows,
                    .cols = total_cols,
                };
                if (verts_ptr != null and vert_count != 0) {
                    new_pv.verts.ensureTotalCapacity(app.alloc, vert_count) catch return;
                    new_pv.verts.appendSliceAssumeCapacity(verts_ptr.?[0..vert_count]);
                }
                app.pending_external_verts.append(app.alloc, new_pv) catch return;
            }

            if (applog.isEnabled()) applog.appLog(
                "[win] on_vertices_row external grid_id={d} stored in pending_external_verts\n",
                .{grid_id},
            );
        }
        return; // Don't process as main grid
    }

    const end_row_hint: u32 = row_start + row_count;
    if (end_row_hint > app.row_mode_max_row_end) {
        app.row_mode_max_row_end = end_row_hint;
        if (applog.isEnabled()) applog.appLog(
            "[win] on_vertices_row max_row_end={d} rows={d} row_verts_len={d}\n",
            .{ app.row_mode_max_row_end, app.rows, app.row_verts.items.len },
        );
    }

    // Update app.rows based on total_rows from core (handles both growth and shrink)
    if (total_rows != app.rows) {
        const old_rows = app.rows;
        app.rows = total_rows;
        app.cols = total_cols;
        app.seed_pending = true;
        app.seed_clear_pending = true;
        app.row_valid_count = 0;
        app.row_layout_gen +%= 1;
        if (total_rows != 0) {
            app.row_valid.resize(app.alloc, @intCast(total_rows), false) catch {};
            app.row_valid.unsetAll();
        } else if (app.row_valid.bit_length != 0) {
            app.row_valid.unsetAll();
        }
        // Clear old row vertex data to prevent ghost rendering from stale vertices.
        for (app.row_verts.items) |*rv| {
            rv.verts.clearRetainingCapacity();
            rv.gen +%= 1;
        }
        // Shrink row_verts if significantly oversized
        app.maybeShrinkRowStorage(total_rows);
        if (applog.isEnabled()) applog.appLog(
            "[win] on_vertices_row resize old={d} new={d} row_valid={d}\n",
            .{ old_rows, total_rows, app.row_valid_count },
        );
    }

    // Row callback is meaningful only when MAIN is updated.
    // If MAIN isn't updated, do NOT mark dirty rows nor invalidate;
    // otherwise cursor-only operations can accidentally explode dirty_rows.
    if ((flags & app_mod.VERT_UPDATE_MAIN) == 0) {
        return;
    }

    // Note: We don't set content_rows_dirty here anymore.
    // The WM_PAINT handler will determine if it's cursor-only by checking
    // if all dirty rows are covered by cursor rects from paint_rects_snapshot.

    // Mark row-mode and remember which rows are dirty.
    // When we enter row-mode for the first time, request a one-time full seed.
    if (!app.row_mode) {
        app.row_mode = true;
        app.need_full_seed.store(true, .seq_cst);
        app.seed_pending = true;
        app.seed_clear_pending = true;
        app.row_valid_count = 0;
        if (app.rows != 0) {
            app.row_valid.resize(app.alloc, @intCast(app.rows), false) catch {};
            app.row_valid.unsetAll();
        }
    } else {
        app.row_mode = true;
    }

    // Mark rows dirty (now gated by MAIN flag).
    // Clamp to [0, app.rows) to avoid index==rows.
    const max_rows: u32 = app.rows;

    if (max_rows != 0 and row_start >= max_rows) {
        return;
    }

    const end_row_unclamped: u32 = row_start + row_count;
    const end_row: u32 = if (max_rows != 0 and end_row_unclamped > max_rows) max_rows else end_row_unclamped;

    var r: u32 = row_start;
    while (r < end_row) : (r += 1) {
        _ = app.dirty_rows.put(app.alloc, r, {}) catch {};
    }


    if (row_count == 1) {
        // Single-row path (normal case): store vertices for this row.
        const row: u32 = row_start;

        // Extra safety: if rows is known, do not store beyond it.
        if (max_rows != 0 and row >= max_rows) {
            return;
        }

        app.ensureRowStorage(row);

        // Verify row storage was allocated (may fail if row >= max_row_buffers)
        if (row >= app.row_verts.items.len) return;

        var rv = &app.row_verts.items[@intCast(row)];
        rv.verts.clearRetainingCapacity();

        if (verts_ptr != null and vert_count != 0) {
            rv.verts.appendSlice(app.alloc, verts_ptr.?[0..vert_count]) catch {};
        }

        rv.gen +%= 1;
    } else if (row_count > 1) {
        // Multi-row path: the vertex array covers multiple rows but we cannot
        // split it per-row (no per-row vertex boundaries in the API).
        // Do NOT store the combined vertices — they would render garbled at
        // row_start while other rows show stale content.
        // Instead, keep existing row vertices intact and request a full re-seed
        // so the core resends each row individually.
        //
        // NOTE: This relies on Core's flush loop responding to need_full_seed
        // by iterating per-row with row_count=1 (see src/core/flush.zig).
        // If a future Core change sends row_count>1 even for re-seed responses,
        // the API contract must be extended with per-row vertex counts.
        if (applog.isEnabled()) applog.appLog(
            "[win] on_vertices_row row_count>1 ({d}) row_start={d} -> requesting re-seed\n",
            .{ row_count, row_start },
        );
        app.need_full_seed.store(true, .seq_cst);
    }

    // Mark the row valid only when we have exact single-row vertex data.
    if (app.rows != 0 and row_count == 1) {
        const idx: usize = @intCast(row_start);
        if (idx < app.row_valid.bit_length and !app.row_valid.isSet(idx)) {
            app.row_valid.set(idx);
            app.row_valid_count += 1;
        }
        if (app.row_valid_count == app.rows) {
            if (applog.isEnabled()) applog.appLog("[win] on_vertices_row seed_ready rows={d}\n", .{app.rows});
        }
    }

    if (app.hwnd) |hwnd| {
        // Invalidate only the affected row rectangle in pixels.
        const fallback_row_h: u32 = app.cell_h_px + app.linespace_px;
        const row_h_px_u32 = app_mod.rowHeightPxFromClient(hwnd, app.rows, fallback_row_h);
        const row_h_px: i32 = @intCast(@as(i32, @intCast(row_h_px_u32)));

        var rc: c.RECT = .{
            .left = 0,
            .top = @intCast(@as(i32, @intCast(row_start)) * row_h_px),
            .right = 0, // will be set to client.right below
            .bottom = @intCast(@as(i32, @intCast(row_start + row_count)) * row_h_px),
        };
        var client: c.RECT = undefined;
        _ = c.GetClientRect(hwnd, &client);
        rc.right = client.right;

        _ = c.InvalidateRect(hwnd, &rc, c.FALSE);
    }
}

pub fn onMainRowScroll(
    ctx: ?*anyopaque,
    row_start: u32,
    row_end: u32,
    col_start: u32,
    col_end: u32,
    rows_delta: i32,
    total_rows: u32,
    total_cols: u32,
) callconv(.c) void {
    const app: *App = @ptrCast(@alignCast(ctx.?));
    app.mu.lock();
    defer app.mu.unlock();

    if (rows_delta == 0 or row_end <= row_start) return;
    if (col_start != 0 or col_end != total_cols) return;

    if (total_rows != app.rows) {
        app.rows = total_rows;
        app.cols = total_cols;
        if (total_rows != 0) {
            app.row_valid.resize(app.alloc, @intCast(total_rows), false) catch {};
            app.row_valid.unsetAll();
        } else if (app.row_valid.bit_length != 0) {
            app.row_valid.unsetAll();
        }
        app.row_valid_count = 0;
        app.row_layout_gen +%= 1;
    } else {
        app.rows = total_rows;
        app.cols = total_cols;
    }

    if (total_rows == 0) return;
    if (row_start >= total_rows or row_end > total_rows) return;

    const region_height: u32 = row_end - row_start;
    const abs_rows: u32 = @intCast(if (rows_delta < 0) -rows_delta else rows_delta);
    if (abs_rows == 0 or abs_rows >= region_height) return;

    app.row_mode = true;
    if (app.row_valid.bit_length < total_rows) {
        app.row_valid.resize(app.alloc, @intCast(total_rows), false) catch {};
    }

    const last_row: u32 = row_end - 1;
    app.ensureRowStorage(last_row);
    if (last_row >= app.row_verts.items.len) return;

    const content_h: f32 = @floatFromInt(@max(@as(u32, 1), app.rows * (app.cell_h_px + app.linespace_px)));
    const row_h: f32 = @floatFromInt(app.cell_h_px + app.linespace_px);
    const delta_y: f32 = @as(f32, @floatFromInt(rows_delta)) * row_h / content_h * 2.0;

    const start_idx: usize = @intCast(row_start);
    const end_idx: usize = @intCast(row_end);
    const shift: usize = @intCast(abs_rows);

    if (rows_delta > 0) {
        var dst: usize = start_idx;
        while (dst + shift < end_idx) : (dst += 1) {
            const src = dst + shift;
            std.mem.swap(app_mod.RowVerts, &app.row_verts.items[dst], &app.row_verts.items[src]);
            shiftVertsY(app.row_verts.items[dst].verts.items, delta_y);
            app.row_verts.items[dst].gen +%= 1;
            if (src < app.row_valid.bit_length and app.row_valid.isSet(src)) {
                app.row_valid.set(dst);
            } else if (dst < app.row_valid.bit_length) {
                app.row_valid.unset(dst);
            }
        }
        var vacated: usize = end_idx - shift;
        while (vacated < end_idx) : (vacated += 1) {
            app.row_verts.items[vacated].verts.clearRetainingCapacity();
            app.row_verts.items[vacated].gen +%= 1;
            if (vacated < app.row_valid.bit_length) app.row_valid.unset(vacated);
        }
    } else {
        var dst: usize = end_idx;
        while (dst > start_idx + shift) {
            dst -= 1;
            const src = dst - shift;
            std.mem.swap(app_mod.RowVerts, &app.row_verts.items[dst], &app.row_verts.items[src]);
            shiftVertsY(app.row_verts.items[dst].verts.items, delta_y);
            app.row_verts.items[dst].gen +%= 1;
            if (src < app.row_valid.bit_length and app.row_valid.isSet(src)) {
                app.row_valid.set(dst);
            } else if (dst < app.row_valid.bit_length) {
                app.row_valid.unset(dst);
            }
        }
        var vacated: usize = start_idx;
        while (vacated < start_idx + shift) : (vacated += 1) {
            app.row_verts.items[vacated].verts.clearRetainingCapacity();
            app.row_verts.items[vacated].gen +%= 1;
            if (vacated < app.row_valid.bit_length) app.row_valid.unset(vacated);
        }
    }

    recomputeRowValidCount(app);

    var row: u32 = row_start;
    while (row < row_end) : (row += 1) {
        _ = app.dirty_rows.put(app.alloc, row, {}) catch {};
    }

    if (row_end > app.row_mode_max_row_end) {
        app.row_mode_max_row_end = row_end;
    }

    if (app.hwnd) |hwnd| {
        const fallback_row_h: u32 = app.cell_h_px + app.linespace_px;
        const row_h_px_u32 = app_mod.rowHeightPxFromClient(hwnd, app.rows, fallback_row_h);
        const row_h_px: i32 = @intCast(@as(i32, @intCast(row_h_px_u32)));

        var rc: c.RECT = .{
            .left = 0,
            .top = @intCast(@as(i32, @intCast(row_start)) * row_h_px),
            .right = 0,
            .bottom = @intCast(@as(i32, @intCast(row_end)) * row_h_px),
        };
        var client: c.RECT = undefined;
        _ = c.GetClientRect(hwnd, &client);
        rc.right = client.right;
        _ = c.InvalidateRect(hwnd, &rc, c.FALSE);
    }
}

/// Called once per flush (from core thread via on_flush_end callback).
/// Posts a single WM_APP_UPDATE_SCROLLBAR with atomic coalescing to avoid
/// flooding the message queue when flushes are frequent.
pub fn onFlushEnd(ctx: ?*anyopaque) callconv(.c) void {
    const ctxp = ctx orelse return;
    const ctx_bits: usize = @intFromPtr(ctxp);
    if (ctx_bits % @alignOf(App) != 0) return;
    const app: *App = @ptrFromInt(ctx_bits);

    // Report DWrite rasterization stats for this flush (only when logging enabled)
    if (applog.isEnabled()) {
        const raster_count = app.rasterize_call_count.swap(0, .monotonic);
        if (raster_count > 0) {
            const raster_total = app.rasterize_total_ns.swap(0, .monotonic);
            const raster_max = app.rasterize_max_ns.swap(0, .monotonic);
            applog.appLog("[perf] flush_rasterize calls={d} total_us={d} max_us={d}\n", .{
                raster_count,
                @as(u64, @divTrunc(raster_total, 1000)),
                @as(u64, @divTrunc(raster_max, 1000)),
            });
        }
    }

    // Coalesce: only post if not already pending (atomic CAS: false -> true)
    if (app.scrollbar_update_pending.cmpxchgStrong(false, true, .release, .monotonic) == null) {
        // CAS succeeded: we own the pending slot
        if (app.hwnd) |hwnd| {
            if (c.PostMessageW(hwnd, app_mod.WM_APP_UPDATE_SCROLLBAR, 0, 0) == 0) {
                // PostMessage failed: reset pending to avoid permanent stall
                app.scrollbar_update_pending.store(false, .release);
            }
        } else {
            // No hwnd yet: reset pending
            app.scrollbar_update_pending.store(false, .release);
        }
    }

    // Ensure the window repaints after flush (needed for glow config changes
    // that arrive via RPC response outside the normal vertex submission path).
    // InvalidateRect is idempotent and cheap; WM_PAINT is coalesced by Windows.
    if (app.hwnd) |hwnd| {
        _ = c.InvalidateRect(hwnd, null, c.FALSE);
    }
}

pub fn onAtlasEnsureGlyph(ctx: ?*anyopaque, scalar: u32, out_entry: *app_mod.GlyphEntry) callconv(.c) c_int {
    const ctxp = ctx orelse return 0;
    const ctx_bits: usize = @intFromPtr(ctxp);
    if (ctx_bits % @alignOf(App) != 0) {
        if (applog.isEnabled()) applog.appLog("onAtlasEnsureGlyph: MISALIGNED ctx=0x{x} align={d} scalar=0x{x}", .{ ctx_bits, @alignOf(App), scalar });
        return 0;
    }
    const app: *App = @ptrFromInt(ctx_bits);

    // ---- aggregate stats (very low overhead) ----
    log_atlas_ensure_calls += 1;
    if (scalar > 0x10FFFF) {
        log_atlas_ensure_suspicious += 1;
    }

    if (applog.isEnabled()) {
        const now_ns: i128 = std.time.nanoTimestamp();
        if (log_atlas_ensure_last_report_ns == 0) log_atlas_ensure_last_report_ns = now_ns;

        // report once per second
        if (now_ns - log_atlas_ensure_last_report_ns >= @as(i128, 1_000_000_000)) {
            applog.appLog(
                "[atlas] ensureGlyph calls/s={d} suspicious/s={d}\n",
                .{ log_atlas_ensure_calls, log_atlas_ensure_suspicious },
            );
            log_atlas_ensure_calls = 0;
            log_atlas_ensure_suspicious = 0;
            log_atlas_ensure_last_report_ns = now_ns;
        }
    }

    // Synchronize read of app.atlas to avoid data race with UI thread initialization.
    var atlas_ptr: ?*dwrite_d2d.Renderer = null;
    {
        app.mu.lock();
        if (app.atlas) |*a| atlas_ptr = a;
        app.mu.unlock();
    }
    if (atlas_ptr) |a| {
        const e = a.atlasEnsureGlyphEntry(scalar) catch |err| {
            if (applog.isEnabled()) applog.appLog("atlasEnsureGlyph: atlasEnsureGlyphEntry ERROR scalar=0x{x} err={any}", .{ scalar, err });
            return 0;
        };
        if (applog.isEnabled() and log_atlas_zero_bbox_count < 16 and scalar != 0 and scalar != 32) {
            if (e.bbox_size_px[0] <= 0 or e.bbox_size_px[1] <= 0) {
                applog.appLog(
                    "[atlas] ensureGlyph zero_bbox scalar=0x{x} bbox=({d:.3},{d:.3}) uv=({d:.4},{d:.4})-({d:.4},{d:.4}) adv={d:.3} asc={d:.3} desc={d:.3}\n",
                    .{
                        scalar,
                        e.bbox_size_px[0],
                        e.bbox_size_px[1],
                        e.uv_min[0],
                        e.uv_min[1],
                        e.uv_max[0],
                        e.uv_max[1],
                        e.advance_px,
                        e.ascent_px,
                        e.descent_px,
                    },
                );
                log_atlas_zero_bbox_count += 1;
            } else if (e.uv_max[0] <= e.uv_min[0] or e.uv_max[1] <= e.uv_min[1]) {
                applog.appLog(
                    "[atlas] ensureGlyph invalid_uv scalar=0x{x} uv=({d:.4},{d:.4})-({d:.4},{d:.4}) bbox=({d:.3},{d:.3})\n",
                    .{
                        scalar,
                        e.uv_min[0],
                        e.uv_min[1],
                        e.uv_max[0],
                        e.uv_max[1],
                        e.bbox_size_px[0],
                        e.bbox_size_px[1],
                    },
                );
                log_atlas_zero_bbox_count += 1;
            }
        }
        out_entry.* = e;
        return 1;
    } else {
        // Atlas not ready yet - queue for later processing
        app.mu.lock();
        defer app.mu.unlock();
        app.pending_glyphs.append(app.alloc, .{ .scalar = scalar, .style_flags = 0 }) catch {};
        return 0;
    }
}

pub fn onAtlasEnsureGlyphStyled(ctx: ?*anyopaque, scalar: u32, style_flags: u32, out_entry: *app_mod.GlyphEntry) callconv(.c) c_int {
    const ctxp = ctx orelse return 0;
    const ctx_bits: usize = @intFromPtr(ctxp);
    if (ctx_bits % @alignOf(App) != 0) {
        if (applog.isEnabled()) applog.appLog("onAtlasEnsureGlyphStyled: MISALIGNED ctx=0x{x} align={d} scalar=0x{x} style=0x{x}", .{ ctx_bits, @alignOf(App), scalar, style_flags });
        return 0;
    }
    const app: *App = @ptrFromInt(ctx_bits);

    log_styled_glyph_calls += 1;

    // Synchronize read of app.atlas to avoid data race with UI thread initialization.
    var atlas_ptr_s: ?*dwrite_d2d.Renderer = null;
    {
        app.mu.lock();
        if (app.atlas) |*a| atlas_ptr_s = a;
        app.mu.unlock();
    }
    if (atlas_ptr_s) |a| {
        const e = a.atlasEnsureGlyphEntryStyled(scalar, style_flags) catch |err| {
            log_styled_glyph_fail += 1;
            if (applog.isEnabled()) applog.appLog("atlasEnsureGlyphStyled: ERROR scalar=0x{x} style=0x{x} err={any}", .{ scalar, style_flags, err });
            return 0;
        };
        log_styled_glyph_ok += 1;

        // Report stats once per second
        if (applog.isEnabled()) {
            const now_ns: i128 = std.time.nanoTimestamp();
            if (log_styled_glyph_last_report_ns == 0) log_styled_glyph_last_report_ns = now_ns;
            if (now_ns - log_styled_glyph_last_report_ns >= @as(i128, 1_000_000_000)) {
                applog.appLog("[styled] calls/s={d} ok/s={d} fail/s={d}\n", .{ log_styled_glyph_calls, log_styled_glyph_ok, log_styled_glyph_fail });
                log_styled_glyph_calls = 0;
                log_styled_glyph_ok = 0;
                log_styled_glyph_fail = 0;
                log_styled_glyph_last_report_ns = now_ns;
            }
        }

        out_entry.* = e;
        return 1;
    } else {
        // Atlas not ready yet - queue for later processing
        app.mu.lock();
        defer app.mu.unlock();
        app.pending_glyphs.append(app.alloc, .{ .scalar = scalar, .style_flags = style_flags }) catch {};
        return 0;
    }
}

// =========================================================================
// Phase 2: Core-managed atlas callbacks
// =========================================================================

pub fn onRasterizeGlyph(ctx: ?*anyopaque, scalar: u32, style_flags: u32, out_bitmap: *app_mod.GlyphBitmap) callconv(.c) c_int {
    const ctxp = ctx orelse return 0;
    const ctx_bits: usize = @intFromPtr(ctxp);
    if (ctx_bits % @alignOf(App) != 0) return 0;
    const app: *App = @ptrFromInt(ctx_bits);

    var atlas_ptr: ?*dwrite_d2d.Renderer = null;
    {
        app.mu.lock();
        if (app.atlas) |*a| atlas_ptr = a;
        app.mu.unlock();
    }
    if (atlas_ptr) |a| {
        if (applog.isEnabled()) {
            const t0 = std.time.nanoTimestamp();
            a.rasterizeGlyphOnly(scalar, style_flags, out_bitmap) catch return 0;
            const elapsed_ns: u64 = @intCast(@max(0, std.time.nanoTimestamp() - t0));
            _ = app.rasterize_call_count.fetchAdd(1, .monotonic);
            _ = app.rasterize_total_ns.fetchAdd(elapsed_ns, .monotonic);
            var cur_max = app.rasterize_max_ns.load(.monotonic);
            while (elapsed_ns > cur_max) {
                if (app.rasterize_max_ns.cmpxchgWeak(cur_max, elapsed_ns, .monotonic, .monotonic)) |actual| {
                    cur_max = actual;
                } else break;
            }
        } else {
            a.rasterizeGlyphOnly(scalar, style_flags, out_bitmap) catch return 0;
        }
        return 1;
    }
    return 0;
}

pub fn onAtlasUpload(ctx: ?*anyopaque, dest_x: u32, dest_y: u32, width: u32, height: u32, bitmap: *const app_mod.GlyphBitmap) callconv(.c) void {
    const ctxp = ctx orelse return;
    const ctx_bits: usize = @intFromPtr(ctxp);
    if (ctx_bits % @alignOf(App) != 0) return;
    const app: *App = @ptrFromInt(ctx_bits);

    var atlas_ptr: ?*dwrite_d2d.Renderer = null;
    {
        app.mu.lock();
        if (app.atlas) |*a| atlas_ptr = a;
        app.mu.unlock();
    }
    if (atlas_ptr) |a| {
        a.uploadAtlasRegion(dest_x, dest_y, width, height, bitmap) catch {};
    }
}

pub fn onAtlasCreate(ctx: ?*anyopaque, atlas_w: u32, atlas_h: u32) callconv(.c) void {
    const ctxp = ctx orelse return;
    const ctx_bits: usize = @intFromPtr(ctxp);
    if (ctx_bits % @alignOf(App) != 0) return;
    const app: *App = @ptrFromInt(ctx_bits);

    var atlas_ptr: ?*dwrite_d2d.Renderer = null;
    {
        app.mu.lock();
        if (app.atlas) |*a| atlas_ptr = a;
        app.mu.unlock();
    }
    if (atlas_ptr) |a| {
        a.recreateAtlasTexture(atlas_w, atlas_h);
    }
}

// =========================================================================
// Text-run shaping callbacks (ligature + ASCII fast path support)
// =========================================================================

pub fn onShapeTextRun(
    ctx: ?*anyopaque,
    scalars: [*]const u32,
    scalar_count: usize,
    style_flags: u32,
    out_glyph_ids: [*]u32,
    out_clusters: [*]u32,
    out_x_advance: [*]i32,
    out_x_offset: [*]i32,
    out_y_offset: [*]i32,
    out_cap: usize,
) callconv(.c) usize {
    const ctxp = ctx orelse return 0;
    const ctx_bits: usize = @intFromPtr(ctxp);
    if (ctx_bits % @alignOf(App) != 0) return 0;
    const app: *App = @ptrFromInt(ctx_bits);

    var atlas_ptr: ?*dwrite_d2d.Renderer = null;
    {
        app.mu.lock();
        if (app.atlas) |*a| atlas_ptr = a;
        app.mu.unlock();
    }
    if (atlas_ptr) |a| {
        return a.shapeTextRunDWrite(
            scalars,
            scalar_count,
            style_flags,
            out_glyph_ids,
            out_clusters,
            out_x_advance,
            out_x_offset,
            out_y_offset,
            out_cap,
        );
    }
    return 0;
}

pub fn onRasterizeGlyphById(
    ctx: ?*anyopaque,
    glyph_id: u32,
    style_flags: u32,
    out_bitmap: *app_mod.GlyphBitmap,
) callconv(.c) c_int {
    const ctxp = ctx orelse return 0;
    const ctx_bits: usize = @intFromPtr(ctxp);
    if (ctx_bits % @alignOf(App) != 0) return 0;
    const app: *App = @ptrFromInt(ctx_bits);

    var atlas_ptr: ?*dwrite_d2d.Renderer = null;
    {
        app.mu.lock();
        if (app.atlas) |*a| atlas_ptr = a;
        app.mu.unlock();
    }
    if (atlas_ptr) |a| {
        if (applog.isEnabled()) {
            const t0 = std.time.nanoTimestamp();
            a.rasterizeGlyphByIdDWrite(glyph_id, style_flags, out_bitmap) catch return 0;
            const elapsed_ns: u64 = @intCast(@max(0, std.time.nanoTimestamp() - t0));
            _ = app.rasterize_call_count.fetchAdd(1, .monotonic);
            _ = app.rasterize_total_ns.fetchAdd(elapsed_ns, .monotonic);
            var cur_max = app.rasterize_max_ns.load(.monotonic);
            while (elapsed_ns > cur_max) {
                if (app.rasterize_max_ns.cmpxchgWeak(cur_max, elapsed_ns, .monotonic, .monotonic)) |actual| {
                    cur_max = actual;
                } else break;
            }
        } else {
            a.rasterizeGlyphByIdDWrite(glyph_id, style_flags, out_bitmap) catch return 0;
        }
        return 1;
    }
    return 0;
}

pub fn onGetAsciiTable(
    ctx: ?*anyopaque,
    style_flags: u32,
    out_glyph_ids: [*]u32,
    out_x_advances: [*]i32,
    out_lig_triggers: [*]u8,
) callconv(.c) c_int {
    const ctxp = ctx orelse return 0;
    const ctx_bits: usize = @intFromPtr(ctxp);
    if (ctx_bits % @alignOf(App) != 0) return 0;
    const app: *App = @ptrFromInt(ctx_bits);

    var atlas_ptr: ?*dwrite_d2d.Renderer = null;
    {
        app.mu.lock();
        if (app.atlas) |*a| atlas_ptr = a;
        app.mu.unlock();
    }
    if (atlas_ptr) |a| {
        return if (a.getAsciiTableDWrite(style_flags, out_glyph_ids, out_x_advances, out_lig_triggers)) 1 else 0;
    }
    return 0;
}

// =========================================================================
// Logging callback
// =========================================================================

pub fn onLog(ctx: ?*anyopaque, bytes: [*c]const u8, len: usize) callconv(.c) void {
    _ = ctx;
    if (!applog.isEnabled()) return;
    if (bytes == null or len == 0) return;

    const s: []const u8 = @as([*]const u8, @ptrCast(bytes))[0..len];
    // Prefix is optional; keep empty for now.
    applog.appLogBytes("", s);
}

// =========================================================================
// Font / linespace callbacks
// =========================================================================

pub fn onGuiFont(ctx: ?*anyopaque, bytes: ?[*]const u8, len: usize) callconv(.c) void {
    const app: *App = @ptrCast(@alignCast(ctx.?));

    // Font priority: guifont > config.font.family > OS default (Consolas)
    const os_default_font = "Consolas";
    const default_font_pt: f32 = 14.0;

    // Get config font (fallback to OS default if empty)
    const config_font = if (app.config.font.family.len > 0) app.config.font.family else os_default_font;
    const config_pt: f32 = if (app.config.font.size > 0.0) app.config.font.size else default_font_pt;

    var name: []const u8 = "";
    var pt: f32 = config_pt;
    var features_str: []const u8 = "";

    if (bytes != null and len != 0) {
        const s = bytes.?[0..len];
        // Format: "<name>\t<size>" or "<name>\t<size>\t<features>"
        if (std.mem.indexOfScalar(u8, s, '\t')) |tab1| {
            name = s[0..tab1];
            const after_name = s[tab1 + 1 ..];
            // Look for second tab (features separator)
            if (std.mem.indexOfScalar(u8, after_name, '\t')) |tab2| {
                const size_str = after_name[0..tab2];
                features_str = after_name[tab2 + 1 ..];
                const parsed_pt = std.fmt.parseFloat(f32, size_str) catch 0;
                pt = if (parsed_pt > 0) parsed_pt else config_pt;
            } else {
                const parsed_pt = std.fmt.parseFloat(f32, after_name) catch 0;
                pt = if (parsed_pt > 0) parsed_pt else config_pt;
            }
        } else {
            // No tab => treat as invalid; use config font.
            if (applog.isEnabled()) applog.appLog("onGuiFont: invalid payload (no tab), using config font", .{});
        }
    } else {
        if (applog.isEnabled()) applog.appLog("onGuiFont: empty payload, using config font", .{});
    }

    // If guifont name is empty, use config font
    if (name.len == 0) {
        name = config_font;
        if (applog.isEnabled()) applog.appLog("onGuiFont: guifont empty, using config font '{s}'", .{config_font});
    }

    app.mu.lock();

    if (app.atlas) |*a| {
        var applied_name: []const u8 = name;
        var applied_pt: f32 = pt;

        const try_primary = a.setFontUtf8WithFeatures(name, pt, features_str);
        if (try_primary) |_| {} else |e| {
            if (applog.isEnabled()) applog.appLog("onGuiFont: setFontUtf8 failed name='{s}' pt={d}: {any}", .{ name, pt, e });

            // Fallback chain: config font -> OS default (features only apply to primary)
            const fallback_name = if (std.mem.eql(u8, name, config_font)) os_default_font else config_font;

            const try_fb = a.setFontUtf8WithFeatures(fallback_name, pt, features_str);
            if (try_fb) |_| {
                applied_name = fallback_name;
                applied_pt = pt;
                if (applog.isEnabled()) applog.appLog("onGuiFont: fallback applied name='{s}' pt={d}", .{ applied_name, applied_pt });
            } else |e2| {
                if (applog.isEnabled()) applog.appLog("onGuiFont: fallback setFontUtf8 failed name='{s}' pt={d}: {any}", .{ fallback_name, pt, e2 });
                // Last resort: try OS default if we haven't already
                if (!std.mem.eql(u8, fallback_name, os_default_font)) {
                    const try_os = a.setFontUtf8WithFeatures(os_default_font, pt, features_str);
                    if (try_os) |_| {
                        applied_name = os_default_font;
                        applied_pt = pt;
                        if (applog.isEnabled()) applog.appLog("onGuiFont: OS default applied name='{s}' pt={d}", .{ applied_name, applied_pt });
                    } else |e3| {
                        if (applog.isEnabled()) applog.appLog("onGuiFont: OS default setFontUtf8 failed: {any}", .{e3});
                    }
                }
            }
        }

        app.cell_w_px = a.cellW();
        app.cell_h_px = a.cellH();
        if (applog.isEnabled()) applog.appLog("onGuiFont: applied name='{s}' pt={d} cell=({d},{d})", .{ applied_name, applied_pt, app.cell_w_px, app.cell_h_px });
    } else {
        if (applog.isEnabled()) applog.appLog("onGuiFont: atlas is null", .{});
    }

    const hwnd = app.hwnd;
    if (hwnd) |h| {
        app_mod.updateRowsColsFromClientForce(h, app);
    }

    // Clear saved cmdline position so it re-centers with the new font size
    app.cmdline_saved_x = null;
    app.cmdline_saved_y = null;

    // Calculate pending resize for all external windows (same as onLineSpace)
    const cell_w = app.cell_w_px;
    const cell_h = app.cell_h_px + app.linespace_px;
    var ext_it = app.external_windows.iterator();
    while (ext_it.next()) |entry| {
        const grid_id = entry.key_ptr.*;
        const ext_win = entry.value_ptr;

        if (ext_win.is_pending_close) continue;

        const rows = ext_win.rows;
        const cols = ext_win.cols;

        var content_w: c_int = @intCast(cols * cell_w);
        var content_h: c_int = @intCast(rows * cell_h);

        const is_cmdline = (grid_id == app_mod.CMDLINE_GRID_ID);
        const is_msg_show = (grid_id == app_mod.MESSAGE_GRID_ID);
        const is_msg_history = (grid_id == app_mod.MSG_HISTORY_GRID_ID);

        if (is_cmdline) {
            const cmdline_icon_total_width: u32 = app_mod.CMDLINE_ICON_MARGIN_LEFT + app_mod.CMDLINE_ICON_SIZE + app_mod.CMDLINE_ICON_MARGIN_RIGHT;
            const cmdline_total_padding: u32 = app_mod.CMDLINE_PADDING * 2;
            content_w += @as(c_int, @intCast(cmdline_icon_total_width + cmdline_total_padding));
            content_h += @as(c_int, @intCast(cmdline_total_padding));
        } else if (is_msg_show or is_msg_history) {
            const scaled_msg_pad = app.scalePx(@as(c_int, app_mod.MSG_PADDING)) * 2;
            content_w += scaled_msg_pad;
            content_h += scaled_msg_pad;
        }

        const dwStyle: c.DWORD = c.WS_POPUP;
        const dwExStyle: c.DWORD = c.WS_EX_TOPMOST;
        var rect: c.RECT = .{ .left = 0, .top = 0, .right = content_w, .bottom = content_h };
        _ = c.AdjustWindowRectEx(&rect, dwStyle, 0, dwExStyle);

        ext_win.pending_window_w = rect.right - rect.left;
        ext_win.pending_window_h = rect.bottom - rect.top;
        ext_win.needs_window_resize = true;
        ext_win.needs_renderer_resize = true;

        if (applog.isEnabled()) applog.appLog("onGuiFont: queued ext_win resize grid_id={d} to ({d},{d})\n", .{ grid_id, ext_win.pending_window_w, ext_win.pending_window_h });

        if (hwnd) |mh| {
            _ = c.PostMessageW(mh, app_mod.WM_APP_RESIZE_POPUPMENU, @bitCast(grid_id), 0);
        }
    }

    app.mu.unlock();

    if (hwnd) |h| {
        app_mod.updateLayoutToCore(h, app);
        _ = c.InvalidateRect(h, null, 0);
        app.mu.lock();
        app.paint_full = true;
        app.paint_rects.clearRetainingCapacity();
        // Trigger full seed to clear back buffer and sync all swapchain buffers.
        // This ensures gutter areas (outside the new grid) are properly cleared.
        app.need_full_seed.store(true, .seq_cst);
        app.seed_pending = true;
        app.seed_clear_pending = true;
        app.mu.unlock();
    }
}

pub fn onLineSpace(ctx: ?*anyopaque, linespace_px: i32) callconv(.c) void {
    const app: *App = @ptrCast(@alignCast(ctx.?));

    const v: u32 = if (linespace_px <= 0) 0 else @intCast(linespace_px);

    if (applog.isEnabled()) applog.appLog(
        "[win] onLineSpace: linespace_px={d} v={d} cell_h_px={d} -> row_h={d}\n",
        .{ linespace_px, v, app.cell_h_px, app.cell_h_px + v },
    );

    // Defer external window resizes via PostMessage to avoid deadlock.
    // SetWindowPos sends WM_SIZE synchronously, and WM_SIZE handler calls
    // zonvie_core_try_resize_grid which needs core locks held by the flush path.
    app.mu.lock();
    app.linespace_px = v;
    const hwnd = app.hwnd;
    if (hwnd) |h| {
        app_mod.updateRowsColsFromClientForce(h, app);
    }

    // Calculate pending resize for all external windows
    const cell_w = app.cell_w_px;
    const cell_h = app.cell_h_px + v;
    var ext_it = app.external_windows.iterator();
    while (ext_it.next()) |entry| {
        const grid_id = entry.key_ptr.*;
        const ext_win = entry.value_ptr;

        if (ext_win.is_pending_close) continue;

        const rows = ext_win.rows;
        const cols = ext_win.cols;

        var content_w: c_int = @intCast(cols * cell_w);
        var content_h: c_int = @intCast(rows * cell_h);

        const is_cmdline = (grid_id == app_mod.CMDLINE_GRID_ID);
        const is_msg_show = (grid_id == app_mod.MESSAGE_GRID_ID);
        const is_msg_history = (grid_id == app_mod.MSG_HISTORY_GRID_ID);

        if (is_cmdline) {
            const cmdline_icon_total_width: u32 = app_mod.CMDLINE_ICON_MARGIN_LEFT + app_mod.CMDLINE_ICON_SIZE + app_mod.CMDLINE_ICON_MARGIN_RIGHT;
            const cmdline_total_padding: u32 = app_mod.CMDLINE_PADDING * 2;
            content_w += @as(c_int, @intCast(cmdline_icon_total_width + cmdline_total_padding));
            content_h += @as(c_int, @intCast(cmdline_total_padding));
        } else if (is_msg_show or is_msg_history) {
            const scaled_msg_pad = app.scalePx(@as(c_int, app_mod.MSG_PADDING)) * 2;
            content_w += scaled_msg_pad;
            content_h += scaled_msg_pad;
        }

        const dwStyle: c.DWORD = c.WS_POPUP;
        const dwExStyle: c.DWORD = c.WS_EX_TOPMOST;
        var rect: c.RECT = .{ .left = 0, .top = 0, .right = content_w, .bottom = content_h };
        _ = c.AdjustWindowRectEx(&rect, dwStyle, 0, dwExStyle);

        ext_win.pending_window_w = rect.right - rect.left;
        ext_win.pending_window_h = rect.bottom - rect.top;
        ext_win.needs_window_resize = true;
        ext_win.needs_renderer_resize = true;

        if (applog.isEnabled()) applog.appLog("[win] onLineSpace: queued ext_win resize grid_id={d} to ({d},{d})\n", .{ grid_id, ext_win.pending_window_w, ext_win.pending_window_h });

        // PostMessageW does not block, so it's safe to call while holding the lock.
        if (hwnd) |mh| {
            _ = c.PostMessageW(mh, app_mod.WM_APP_RESIZE_POPUPMENU, @bitCast(grid_id), 0);
        }
    }

    app.mu.unlock();

    if (hwnd) |h| {
        app_mod.updateLayoutToCore(h, app);
        _ = c.InvalidateRect(h, null, 0);
        app.mu.lock();
        app.paint_full = true;
        app.paint_rects.clearRetainingCapacity();
        // Trigger full seed to clear back buffer and sync all swapchain buffers.
        // This ensures gutter areas (outside the new grid) are properly cleared.
        app.need_full_seed.store(true, .seq_cst);
        app.seed_pending = true;
        app.seed_clear_pending = true;
        app.mu.unlock();
    }
}

// =========================================================================
// Exit / IME / quit / title callbacks
// =========================================================================

pub fn onExit(ctx: ?*anyopaque, exit_code: i32) callconv(.c) void {
    const app: *App = @ptrCast(@alignCast(ctx.?));
    if (applog.isEnabled()) applog.appLog("[win] on_exit: code={d}\n", .{exit_code});
    // Mark Neovim as exited (to skip requestQuit in WM_CLOSE)
    app.neovim_exited.store(true, .release);
    // Store exit code globally (Nvy style - returned from main instead of ExitProcess)
    app_mod.g_exit_code.store(@intCast(@as(u32, @bitCast(exit_code)) & 0xFF), .seq_cst);
    if (app.hwnd) |hwnd| {
        _ = c.PostMessageW(hwnd, c.WM_CLOSE, 0, 0);
    }
}

pub fn onIMEOff(ctx: ?*anyopaque) callconv(.c) void {
    const app: *App = @ptrCast(@alignCast(ctx.?));
    if (app.hwnd) |hwnd| {
        // Post message to main thread (IME APIs must be called from the window's thread)
        _ = c.PostMessageW(hwnd, app_mod.WM_APP_IME_OFF, 0, 0);
    }
}

pub fn onQuitRequested(ctx: ?*anyopaque, has_unsaved: c_int) callconv(.c) void {
    const app: *App = @ptrCast(@alignCast(ctx.?));
    if (applog.isEnabled()) applog.appLog("[win] onQuitRequested: has_unsaved={d}\n", .{has_unsaved});

    // Post message to main thread to avoid blocking RPC thread
    if (app.hwnd) |hwnd| {
        _ = c.PostMessageW(hwnd, app_mod.WM_APP_QUIT_REQUESTED, @intCast(has_unsaved), 0);
    }
}

pub fn onDefaultColorsSet(ctx: ?*anyopaque, fg: u32, bg: u32) callconv(.c) void {
    const app: *App = @ptrCast(@alignCast(ctx.?));

    if (applog.isEnabled()) applog.appLog("[win] onDefaultColorsSet: fg=0x{x:0>8} bg=0x{x:0>8}\n", .{ fg, bg });

    // 0xFFFFFFFF means "not set" — only update the color that is valid
    app.mu.lock();
    if (bg != 0xFFFFFFFF) app.colorscheme_bg = bg;
    if (fg != 0xFFFFFFFF) app.colorscheme_fg = fg;
    app.mu.unlock();

    // Invalidate tabline/sidebar to repaint with new colors
    if (app.hwnd) |hwnd| {
        _ = c.PostMessageW(hwnd, app_mod.WM_APP_TABLINE_INVALIDATE, 0, 0);
    }
}

pub fn onSetTitle(ctx: ?*anyopaque, title_ptr: ?[*]const u8, title_len: usize) callconv(.c) void {
    const app: *App = @ptrCast(@alignCast(ctx.?));

    if (applog.isEnabled()) applog.appLog("[win] onSetTitle: len={d}\n", .{title_len});

    if (title_ptr == null or title_len == 0) return;

    const title = title_ptr.?[0..title_len];
    if (applog.isEnabled()) applog.appLog("[win] onSetTitle: {s}\n", .{title});

    // Defer SetWindowTextW to UI thread via PostMessage to avoid deadlock.
    // SetWindowTextW from a non-owning thread is an implicit cross-thread
    // SendMessage(WM_SETTEXT), which blocks with grid_mu held.
    const hwnd = app.hwnd orelse return;

    // Truncate UTF-8 input to fit the pending_title buffer (511 UTF-16 units + null).
    // If the full title doesn't fit, progressively shorten the UTF-8 slice at
    // codepoint boundaries until it fits, so we always get a partial update
    // rather than silently dropping the title.
    app.mu.lock();
    var src = title;
    var wide_len: usize = 0;
    while (src.len > 0) {
        wide_len = std.unicode.utf8ToUtf16Le(&app.pending_title, src) catch {
            // Shorten src by one codepoint from the end and retry.
            var trim = src.len - 1;
            while (trim > 0 and (src[trim] & 0xC0) == 0x80) trim -= 1;
            src = src[0..trim];
            continue;
        };
        break;
    }
    const clamped_len = @min(wide_len, app.pending_title.len - 1);
    app.pending_title[clamped_len] = 0; // null terminate
    app.pending_title_len = clamped_len;
    app.mu.unlock();

    if (clamped_len > 0) {
        _ = c.PostMessageW(hwnd, app_mod.WM_APP_SET_TITLE, 0, 0);
    }
}

// =========================================================================
// ext_cmdline callbacks
// =========================================================================

pub fn onCmdlineShow(
    ctx: ?*anyopaque,
    _: ?[*]const app_mod.CmdlineChunk, // content
    _: usize, // content_count
    _: u32, // pos
    firstc: u8,
    _: ?[*]const u8, // prompt
    _: usize, // prompt_len
    _: u32, // indent
    _: u32, // level
    _: u32, // prompt_hl_id
) callconv(.c) void {
    const app: *App = @ptrCast(@alignCast(ctx.?));
    if (applog.isEnabled()) applog.appLog("[win] on_cmdline_show: firstc={c}({d})\n", .{ firstc, firstc });

    app.mu.lock();
    app.cmdline_firstc = firstc;
    app.mu.unlock();

    // Request UI thread to update cmdline colors from core highlights.
    // We can't call zonvie_core_get_hl_by_name here (callback context) because
    // core holds an internal lock during callbacks, causing deadlock.
    // Post message to UI thread which will call updateCmdlineColors().
    if (app.hwnd) |hwnd| {
        _ = c.PostMessageW(hwnd, app_mod.WM_APP_UPDATE_CMDLINE_COLORS, 0, 0);
    }
}

pub fn onCmdlineHide(ctx: ?*anyopaque, _: u32) callconv(.c) void {
    const app: *App = @ptrCast(@alignCast(ctx.?));
    if (applog.isEnabled()) applog.appLog("[win] on_cmdline_hide\n", .{});

    app.mu.lock();
    app.cmdline_firstc = 0;
    app.mu.unlock();
}

// =========================================================================
// Clipboard and SSH auth callbacks
// =========================================================================

pub fn onClipboardGet(
    ctx: ?*anyopaque,
    register: [*]const u8,
    out_buf: [*]u8,
    out_len: *usize,
    max_len: usize,
) callconv(.c) c_int {
    _ = register;

    if (applog.isEnabled()) applog.appLog("[win] clipboard_get: called\n", .{});

    const app: *App = if (ctx) |ctxp| @ptrCast(@alignCast(ctxp)) else {
        out_len.* = 0;
        return 1;
    };

    const hwnd = app.hwnd orelse {
        out_len.* = 0;
        return 1;
    };

    // Create event if not exists (manual-reset, initially non-signaled)
    if (app.clipboard_event == null) {
        app.clipboard_event = c.CreateEventW(null, c.TRUE, c.FALSE, null);
        if (app.clipboard_event == null) {
            if (applog.isEnabled()) applog.appLog("[win] clipboard_get: CreateEventW failed\n", .{});
            out_len.* = 0;
            return 1;
        }
    }

    // Reset event
    _ = c.ResetEvent(app.clipboard_event);

    // Post message to UI thread
    if (c.PostMessageW(hwnd, app_mod.WM_APP_CLIPBOARD_GET, 0, 0) == 0) {
        if (applog.isEnabled()) applog.appLog("[win] clipboard_get: PostMessageW failed\n", .{});
        out_len.* = 0;
        return 1;
    }

    // Wait for UI thread to complete (timeout: 5 seconds)
    const wait_result = c.WaitForSingleObject(app.clipboard_event, 5000);
    if (wait_result != c.WAIT_OBJECT_0) {
        if (applog.isEnabled()) applog.appLog("[win] clipboard_get: WaitForSingleObject failed or timeout\n", .{});
        out_len.* = 0;
        return 1;
    }

    // Copy result
    const copy_len = @min(app.clipboard_len, max_len);
    if (copy_len > 0) {
        @memcpy(out_buf[0..copy_len], app.clipboard_buf[0..copy_len]);
    }
    out_len.* = copy_len;

    if (applog.isEnabled()) applog.appLog("[win] clipboard_get: len={d}\n", .{copy_len});
    return app.clipboard_result;
}

pub fn onClipboardSet(
    ctx: ?*anyopaque,
    register: [*]const u8,
    data: [*]const u8,
    len: usize,
) callconv(.c) c_int {
    _ = register;

    if (applog.isEnabled()) applog.appLog("[win] clipboard_set: called len={d}\n", .{len});

    if (len == 0) return 1;

    const app: *App = if (ctx) |ctxp| @ptrCast(@alignCast(ctxp)) else return 0;

    const hwnd = app.hwnd orelse return 0;

    // Create event if not exists
    if (app.clipboard_event == null) {
        app.clipboard_event = c.CreateEventW(null, c.TRUE, c.FALSE, null);
        if (app.clipboard_event == null) {
            if (applog.isEnabled()) applog.appLog("[win] clipboard_set: CreateEventW failed\n", .{});
            return 0;
        }
    }

    // Reset event
    _ = c.ResetEvent(app.clipboard_event);

    // Store data pointer and length for UI thread
    app.clipboard_set_data = data;
    app.clipboard_set_len = len;

    // Post message to UI thread
    if (c.PostMessageW(hwnd, app_mod.WM_APP_CLIPBOARD_SET, 0, 0) == 0) {
        if (applog.isEnabled()) applog.appLog("[win] clipboard_set: PostMessageW failed\n", .{});
        return 0;
    }

    // Wait for UI thread to complete (timeout: 5 seconds)
    const wait_result = c.WaitForSingleObject(app.clipboard_event, 5000);
    if (wait_result != c.WAIT_OBJECT_0) {
        if (applog.isEnabled()) applog.appLog("[win] clipboard_set: WaitForSingleObject failed or timeout\n", .{});
        return 0;
    }

    if (applog.isEnabled()) applog.appLog("[win] clipboard_set: result={d}\n", .{app.clipboard_result});
    return app.clipboard_result;
}

/// SSH authentication prompt callback
/// Called when SSH mode detects a password prompt
pub fn onSSHAuthPrompt(
    ctx: ?*anyopaque,
    prompt: [*]const u8,
    prompt_len: usize,
) callconv(.c) void {
    if (applog.isEnabled()) applog.appLog("[win] ssh_auth_prompt: called len={d}\n", .{prompt_len});

    const app: *App = if (ctx) |ctxp| @ptrCast(@alignCast(ctxp)) else return;

    // Post message to UI thread to show password dialog
    const hwnd = app.hwnd orelse return;

    // Copy prompt data into owned buffer (core may free original after callback returns)
    const owned = app.alloc.alloc(u8, prompt_len) catch {
        if (applog.isEnabled()) applog.appLog("[win] ssh_auth_prompt: OOM copying prompt\n", .{});
        return;
    };
    @memcpy(owned, prompt[0..prompt_len]);

    // Free any previous owned prompt that was not consumed
    if (app.ssh_prompt_owned) |old| {
        app.alloc.free(old);
    }
    app.ssh_prompt_owned = owned;

    if (c.PostMessageW(hwnd, app_mod.WM_APP_SSH_AUTH_PROMPT, 0, 0) == 0) {
        if (applog.isEnabled()) applog.appLog("[win] ssh_auth_prompt: PostMessageW failed\n", .{});
        // UI thread will never consume this prompt, free it now.
        app.alloc.free(owned);
        app.ssh_prompt_owned = null;
    }
}
