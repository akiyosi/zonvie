// callbacks.zig — All zonvie_callbacks implementations for Linux frontend.
//
// These callbacks run on the core/redraw thread (grid_mu held).
// GUI updates must be dispatched to the GTK main thread via g_idle_add.

const std = @import("std");
const app_mod = @import("app.zig");
const App = app_mod.App;
const gtk_mod = app_mod.gtk_mod;
const applog = app_mod.applog;
const gl_renderer = @import("renderer/gl_renderer.zig");
const ft_renderer = @import("renderer/ft_renderer.zig");
const core = @import("zonvie_core");
const main_mod = @import("main.zig");

// =========================================================================
// Helper: extract App pointer from callback context
// =========================================================================

fn getApp(ctx: ?*anyopaque) ?*App {
    const ctxp = ctx orelse return null;
    const ctx_bits: usize = @intFromPtr(ctxp);
    if (ctx_bits % @alignOf(App) != 0) return null;
    return @ptrFromInt(ctx_bits);
}

// =========================================================================
// Helper functions for row vertex management
// =========================================================================

fn swapAndShiftRows(
    row_verts: []app_mod.RowVerts,
    row_start: u32,
    row_end: u32,
    rows_delta: i32,
    row_valid: ?*std.DynamicBitSetUnmanaged,
) void {
    const abs_rows: u32 = @intCast(if (rows_delta < 0) -rows_delta else rows_delta);
    const start_idx: usize = @intCast(row_start);
    const end_idx: usize = @intCast(row_end);
    const shift: usize = @intCast(abs_rows);

    if (rows_delta > 0) {
        var dst: usize = start_idx;
        while (dst + shift < end_idx) : (dst += 1) {
            std.mem.swap(app_mod.RowVerts, &row_verts[dst], &row_verts[srcIdx(dst, shift)]);
            if (row_valid) |rv| {
                const s = dst + shift;
                if (s < rv.bit_length and rv.isSet(s)) {
                    rv.set(dst);
                } else if (dst < rv.bit_length) {
                    rv.unset(dst);
                }
            }
        }
        var vacated: usize = end_idx - shift;
        while (vacated < end_idx) : (vacated += 1) {
            row_verts[vacated].verts.clearRetainingCapacity();
            row_verts[vacated].gen +%= 1;
            if (row_valid) |rv| {
                if (vacated < rv.bit_length) rv.unset(vacated);
            }
        }
    } else {
        var dst: usize = end_idx;
        while (dst > start_idx + shift) {
            dst -= 1;
            std.mem.swap(app_mod.RowVerts, &row_verts[dst], &row_verts[dst - shift]);
            if (row_valid) |rv| {
                const s = dst - shift;
                if (s < rv.bit_length and rv.isSet(s)) {
                    rv.set(dst);
                } else if (dst < rv.bit_length) {
                    rv.unset(dst);
                }
            }
        }
        var vacated: usize = start_idx;
        while (vacated < start_idx + shift) : (vacated += 1) {
            row_verts[vacated].verts.clearRetainingCapacity();
            row_verts[vacated].gen +%= 1;
            if (row_valid) |rv| {
                if (vacated < rv.bit_length) rv.unset(vacated);
            }
        }
    }
}

fn srcIdx(dst: usize, shift: usize) usize {
    return dst + shift;
}

fn remapRowSlots(
    row_map: []app_mod.RowMapping,
    pool: *app_mod.SlotPool,
    row_start: u32,
    row_end: u32,
    rows_delta: i32,
) void {
    const abs_rows: u32 = @intCast(if (rows_delta < 0) -rows_delta else rows_delta);
    const start_idx: usize = @intCast(row_start);
    const end_idx: usize = @intCast(row_end);
    const shift: usize = @intCast(abs_rows);

    if (rows_delta > 0) {
        var saved: [256]app_mod.RowMapping = undefined;
        const save_count = @min(shift, 256);
        var si: usize = 0;
        while (si < save_count) : (si += 1) {
            saved[si] = row_map[start_idx + si];
        }
        var dst: usize = start_idx;
        while (dst + shift < end_idx) : (dst += 1) {
            row_map[dst] = row_map[dst + shift];
        }
        var vacated: usize = end_idx - shift;
        var vi: usize = 0;
        while (vacated < end_idx) : ({
            vacated += 1;
            vi += 1;
        }) {
            if (vi < save_count) {
                row_map[vacated] = saved[vi];
            }
            if (row_map[vacated].slot != app_mod.SLOT_NONE) {
                const slot = &pool.slots.items[row_map[vacated].slot];
                slot.verts.clearRetainingCapacity();
                slot.ver +%= 1;
                slot.origin_row = @intCast(vacated);
            }
        }
    } else {
        var saved: [256]app_mod.RowMapping = undefined;
        const save_count = @min(shift, 256);
        var si: usize = 0;
        while (si < save_count) : (si += 1) {
            saved[si] = row_map[end_idx - shift + si];
        }
        var dst: usize = end_idx;
        while (dst > start_idx + shift) {
            dst -= 1;
            row_map[dst] = row_map[dst - shift];
        }
        var vacated: usize = start_idx;
        var vi: usize = 0;
        while (vacated < start_idx + shift) : ({
            vacated += 1;
            vi += 1;
        }) {
            if (vi < save_count) {
                row_map[vacated] = saved[vi];
            }
            if (row_map[vacated].slot != app_mod.SLOT_NONE) {
                const slot = &pool.slots.items[row_map[vacated].slot];
                slot.verts.clearRetainingCapacity();
                slot.ver +%= 1;
                slot.origin_row = @intCast(vacated);
            }
        }
    }
}

// =========================================================================
// Flush callbacks
// =========================================================================

pub fn onFlushBegin(ctx: ?*anyopaque) callconv(.c) void {
    const app = getApp(ctx) orelse return;

    if (applog.isEnabled()) applog.appLog("[tbs] onFlushBegin enter\n", .{});

    var can_flush = app.tbs.hasFreeSet();
    if (can_flush) {
        app.mu.lock();
        var it = app.external_windows.iterator();
        while (it.next()) |entry| {
            if (!entry.value_ptr.tbs.hasFreeSet()) {
                can_flush = false;
                break;
            }
        }
        app.mu.unlock();
    }

    if (!can_flush) {
        if (app.corep) |corep| app_mod.zonvie_core_abort_flush(corep);
        return;
    }

    var ok = app.tbs.beginFlush(app.alloc);
    if (ok) {
        app.mu.lock();
        var it = app.external_windows.iterator();
        while (it.next()) |entry| {
            if (!entry.value_ptr.tbs.beginFlush(app.alloc)) {
                ok = false;
                break;
            }
        }
        app.mu.unlock();
    }

    if (!ok) {
        app.tbs.cancelFlush();
        app.mu.lock();
        var it2 = app.external_windows.iterator();
        while (it2.next()) |entry| {
            entry.value_ptr.tbs.cancelFlush();
        }
        app.mu.unlock();
        if (app.corep) |corep| app_mod.zonvie_core_abort_flush(corep);
        return;
    }
}

pub fn onFlushEnd(ctx: ?*anyopaque) callconv(.c) void {
    const app = getApp(ctx) orelse return;

    if (applog.isEnabled()) {
        const ws = app.tbs.writeSet();
        applog.appLog("[tbs] onFlushEnd: write_idx={d} vs_ptr={x} is_in_flush={d} ws.row_mode={d} ws.flat={d} ws.rows={d}\n", .{
            app.tbs.write_index,
            @intFromPtr(ws),
            @as(u8, if (app.tbs.is_in_flush) 1 else 0),
            @as(u8, if (ws.row_mode) 1 else 0),
            ws.flat_verts.items.len,
            ws.row_map.items.len,
        });
    }

    // Commit triple-buffered write sets
    app.tbs.commitFlush(app.alloc);

    // Record viewport dimensions at flush time for stable rendering during resize
    app.last_flush_w = app.drawable_w_px;
    app.last_flush_h = app.drawable_h_px;
    {
        app.mu.lock();
        var ext_it = app.external_windows.iterator();
        while (ext_it.next()) |entry| {
            // Overlay grids (cmdline, popupmenu) may be created mid-flush
            // so beginFlush was never called for them (is_in_flush=false).
            // Force is_in_flush=true so commitFlush actually commits.
            if (!entry.value_ptr.tbs.is_in_flush) {
                const gid = entry.key_ptr.*;
                if (gid == app_mod.CMDLINE_GRID_ID or gid == app_mod.POPUPMENU_GRID_ID or
                    gid == app_mod.MESSAGE_GRID_ID or gid == app_mod.MSG_HISTORY_GRID_ID)
                {
                    entry.value_ptr.tbs.is_in_flush = true;
                }
            }
            entry.value_ptr.tbs.commitFlush(app.alloc);
        }
        app.mu.unlock();
    }

    // Queue redraw + cursor blink update on GTK main thread
    _ = gtk_mod.g_idle_add(&idlePostFlush, @ptrCast(app));
}

fn idlePostFlush(user_data: ?*anyopaque) callconv(.c) c_int {
    const app = getApp(user_data) orelse return 0;
    if (app.gl_area) |area| {
        main_mod.gtk_externs.widget_queue_draw(area);
    }
    updateCursorBlinking(app);
    updateScrollbar(app);
    return 0; // G_SOURCE_REMOVE
}

fn idleQueueDraw(user_data: ?*anyopaque) callconv(.c) c_int {
    const app = getApp(user_data) orelse return 0;
    if (app.gl_area) |area| {
        main_mod.gtk_externs.widget_queue_draw(area);
    }
    return 0; // G_SOURCE_REMOVE
}

// =========================================================================
// Cursor blink
// =========================================================================

fn updateCursorBlinking(app: *App) void {
    var wait_ms: u32 = 0;
    var on_ms: u32 = 0;
    var off_ms: u32 = 0;

    if (app.corep) |core_ptr| {
        app_mod.zonvie_core_get_cursor_blink(core_ptr, &wait_ms, &on_ms, &off_ms);
    }

    const settings_changed = wait_ms != app.cursor_blink_wait_ms or
        on_ms != app.cursor_blink_on_ms or
        off_ms != app.cursor_blink_off_ms;

    const timer_stopped = app.cursor_blink_timer == 0;

    if (on_ms > 0 and off_ms > 0) {
        if (settings_changed or timer_stopped) {
            startCursorBlinking(app, wait_ms, on_ms, off_ms);
        }
    } else {
        if (settings_changed) {
            stopCursorBlinking(app);
        }
    }
}

fn startCursorBlinking(app: *App, wait_ms: u32, on_ms: u32, off_ms: u32) void {
    stopCursorBlinking(app);

    if (on_ms == 0) return;

    app.cursor_blink_wait_ms = wait_ms;
    app.cursor_blink_on_ms = on_ms;
    app.cursor_blink_off_ms = off_ms;

    if (wait_ms > 0) {
        app.cursor_blink_phase = 0;
        app.cursor_blink_state = true;
        app.cursor_blink_timer = gtk_mod.g_timeout_add(wait_ms, &onCursorBlinkTimer, @ptrCast(app));
    } else {
        enterBlinkCycle(app);
    }
}

fn enterBlinkCycle(app: *App) void {
    app.cursor_blink_phase = 1;
    app.cursor_blink_state = true;
    scheduleNextBlink(app, true);
    if (app.gl_area) |area| {
        main_mod.gtk_externs.widget_queue_draw(area);
    }
}

fn scheduleNextBlink(app: *App, is_currently_on: bool) void {
    const interval = if (is_currently_on) app.cursor_blink_on_ms else app.cursor_blink_off_ms;
    if (interval == 0) return;
    app.cursor_blink_timer = gtk_mod.g_timeout_add(interval, &onCursorBlinkTimer, @ptrCast(app));
}

fn onCursorBlinkTimer(user_data: ?*anyopaque) callconv(.c) c_int {
    const app = getApp(user_data) orelse return 0;
    app.cursor_blink_timer = 0;

    if (app.cursor_blink_phase == 0) {
        enterBlinkCycle(app);
    } else {
        app.cursor_blink_state = !app.cursor_blink_state;

        if (app.gl_area) |area| {
            main_mod.gtk_externs.widget_queue_draw(area);
        }

        scheduleNextBlink(app, app.cursor_blink_state);
    }

    return 0; // G_SOURCE_REMOVE (one-shot timer)
}

// =========================================================================
// Scrollbar
// =========================================================================

fn updateScrollbar(app: *App) void {
    if (app.corep == null) return;
    if (!app.config.scrollbar.enabled) return;

    var vp: app_mod.ViewportInfo = undefined;
    _ = app_mod.zonvie_core_get_viewport(app.corep, 1, &vp);

    app.scrollbar.updateFromViewport(vp);
    app.scrollbar.visible = (vp.line_count > 0);
}

fn stopCursorBlinking(app: *App) void {
    if (app.cursor_blink_timer != 0) {
        _ = gtk_mod.g_source_remove(app.cursor_blink_timer);
        app.cursor_blink_timer = 0;
    }
    app.cursor_blink_phase = 0;
    app.cursor_blink_state = true;
}

// =========================================================================
// Vertex callbacks
// =========================================================================

pub fn onVertices(
    ctx: ?*anyopaque,
    main_verts: [*]const app_mod.Vertex,
    main_count: usize,
    cursor_verts: [*]const app_mod.Vertex,
    cursor_count: usize,
) callconv(.c) void {
    const app = getApp(ctx) orelse return;
    const vs = app.tbs.writeSet();

    vs.flat_verts.clearRetainingCapacity();
    if (main_count > 0) {
        vs.flat_verts.appendSlice(app.alloc, main_verts[0..main_count]) catch {};
    }

    vs.cursor_verts.clearRetainingCapacity();
    if (cursor_count > 0) {
        vs.cursor_verts.appendSlice(app.alloc, cursor_verts[0..cursor_count]) catch {};
    }

    vs.row_mode = false;
    app.tbs.flush_paint_full = true;
    app.flush_needs_invalidate = true;
}

pub fn onVerticesPartial(
    ctx: ?*anyopaque,
    main_verts: ?[*]const app_mod.Vertex,
    main_count: usize,
    cursor_verts: ?[*]const app_mod.Vertex,
    cursor_count: usize,
    flags: u32,
) callconv(.c) void {
    const app = getApp(ctx) orelse return;
    const vs = app.tbs.writeSet();

    if ((flags & app_mod.VERT_UPDATE_MAIN) != 0) {
        vs.flat_verts.clearRetainingCapacity();
        if (main_verts) |mv| {
            if (main_count > 0) {
                vs.flat_verts.appendSlice(app.alloc, mv[0..main_count]) catch {};
            }
        }
    }

    if ((flags & app_mod.VERT_UPDATE_CURSOR) != 0) {
        vs.cursor_verts.clearRetainingCapacity();
        if (cursor_verts) |cv| {
            if (cursor_count > 0) {
                vs.cursor_verts.appendSlice(app.alloc, cv[0..cursor_count]) catch {};
            }
        }
    }

    // Only switch to flat mode when main vertices are replaced.
    // Cursor-only updates must preserve the current rendering mode.
    if ((flags & app_mod.VERT_UPDATE_MAIN) != 0) {
        vs.row_mode = false;
    }
    app.tbs.flush_paint_full = true;
    app.flush_needs_invalidate = true;
}

pub fn onVerticesRow(
    ctx: ?*anyopaque,
    grid_id: i64,
    row_start: u32,
    row_count: u32,
    verts: ?[*]const app_mod.Vertex,
    vert_count: usize,
    flags: u32,
    total_rows: u32,
    total_cols: u32,
) callconv(.c) void {
    const app = getApp(ctx) orelse return;

    if (applog.isEnabled() and row_start == 0) {
        applog.appLog("[tbs] onVerticesRow: grid={d} row={d} count={d} verts={d} flags={d} total={d}x{d}\n", .{
            grid_id, row_start, row_count, vert_count, flags, total_rows, total_cols,
        });
    }

    // Route to external window if grid_id != 1 (main grid)
    // External grids include both regular ext_windows (grid_id > 1) and
    // special grids like cmdline (CMDLINE_GRID_ID = -100)
    if (grid_id != 1) {
        app.mu.lock();
        if (app.external_windows.getPtr(grid_id)) |ext| {
            storeExternalRowVerts(app, ext, row_start, row_count, verts, vert_count, flags, total_rows, total_cols);

            // Overlay grids (cmdline, popupmenu): core may send vertices
            // after on_flush_end because notifyCmdlineChanges/notifyPopupmenuChanges
            // run outside the flush bracket in rpc_session.  The overlay tbs was
            // created mid-flush so beginFlush was never called, leaving
            // is_in_flush=false.  Force a commit when all data has arrived:
            //   - cursor update (VERT_UPDATE_CURSOR) for cmdline
            //   - last row for popupmenu (which has no cursor)
            const is_overlay_grid = (grid_id == app_mod.CMDLINE_GRID_ID or grid_id == app_mod.POPUPMENU_GRID_ID or
                grid_id == app_mod.MESSAGE_GRID_ID or grid_id == app_mod.MSG_HISTORY_GRID_ID);
            const is_cursor = (flags & app_mod.VERT_UPDATE_CURSOR) != 0;
            const is_last_row = (row_start + row_count >= total_rows) and !is_cursor;
            if (is_overlay_grid and (is_cursor or is_last_row)) {
                if (!ext.tbs.is_in_flush) {
                    ext.tbs.is_in_flush = true;
                }
                ext.tbs.commitFlush(app.alloc);
                app.mu.unlock();
                _ = gtk_mod.g_idle_add(&idleQueueRedraw, @ptrCast(app));
                return;
            }
        }
        app.mu.unlock();
        return;
    }

    const vs = app.tbs.writeSet();
    vs.row_mode = true;
    vs.rows = total_rows;
    vs.cols = total_cols;

    if (applog.isEnabled() and row_start == 0) {
        applog.appLog("[tbs] onVerticesRow AFTER set: write_idx={d} vs_ptr={x} row_mode={d}\n", .{
            app.tbs.write_index,
            @intFromPtr(vs),
            @as(u8, if (vs.row_mode) 1 else 0),
        });
    }

    // Store cursor verts if included
    if ((flags & app_mod.VERT_UPDATE_CURSOR) != 0) {
        vs.cursor_verts.clearRetainingCapacity();
    }

    // Ensure row storage exists
    vs.ensureRowStorage(app.alloc, row_start + row_count -| 1);

    // Resize dirty bitset if needed
    if (app.tbs.flush_dirty.bit_length < total_rows) {
        app.tbs.flush_dirty.resize(app.alloc, total_rows, false) catch {};
    }

    // Store vertices for each row
    var r: u32 = row_start;
    while (r < row_start + row_count) : (r += 1) {
        // COW detach the row slot for exclusive write
        const slot = app.tbs.cowDetachRow(app.alloc, r) orelse continue;

        slot.verts.clearRetainingCapacity();
        if (verts) |v| {
            if (vert_count > 0 and row_count == 1) {
                // Single row: all verts belong to this row
                slot.verts.appendSlice(app.alloc, v[0..vert_count]) catch {};
            }
        }
        slot.origin_row = r;
        slot.ver +%= 1;

        // Mark dirty
        if (r < app.tbs.flush_dirty.bit_length) {
            app.tbs.flush_dirty.set(r);
        }
    }

    app.flush_needs_invalidate = true;
}

fn storeExternalRowVerts(
    app: *App,
    ext: *app_mod.ExternalWindow,
    row_start: u32,
    row_count: u32,
    verts: ?[*]const app_mod.Vertex,
    vert_count: usize,
    flags: u32,
    total_rows: u32,
    total_cols: u32,
) void {
    const vs = ext.tbs.writeSet();
    vs.row_mode = true;
    vs.rows = total_rows;
    vs.cols = total_cols;

    // Cursor vertices are sent separately with VERT_UPDATE_CURSOR flag
    if ((flags & app_mod.VERT_UPDATE_CURSOR) != 0) {
        vs.cursor_verts.clearRetainingCapacity();
        if (verts) |v| {
            if (vert_count > 0) {
                vs.cursor_verts.appendSlice(app.alloc, v[0..vert_count]) catch {};
            }
        }
        ext.needs_redraw = true;
        return;
    }

    vs.ensureRowStorage(app.alloc, row_start + row_count -| 1);

    var r: u32 = row_start;
    while (r < row_start + row_count) : (r += 1) {
        const slot = ext.tbs.cowDetachRow(app.alloc, r) orelse continue;
        slot.verts.clearRetainingCapacity();
        if (verts) |v| {
            if (vert_count > 0 and row_count == 1) {
                slot.verts.appendSlice(app.alloc, v[0..vert_count]) catch {};
            }
        }
        slot.origin_row = r;
        slot.ver +%= 1;
    }

    ext.needs_redraw = true;
}

// =========================================================================
// Scroll callbacks
// =========================================================================

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
    _ = col_start;
    _ = col_end;
    const app = getApp(ctx) orelse return;

    const vs = app.tbs.writeSet();
    vs.rows = total_rows;
    vs.cols = total_cols;

    // Remap slot indices in the write set's row_map
    if (vs.row_map.items.len >= row_end) {
        remapRowSlots(
            vs.row_map.items,
            &app.tbs.pool,
            row_start,
            row_end,
            rows_delta,
        );
    }

    // Mark all rows in scroll region as dirty
    if (app.tbs.flush_dirty.bit_length < total_rows) {
        app.tbs.flush_dirty.resize(app.alloc, total_rows, false) catch {};
    }
    var r: u32 = row_start;
    while (r < row_end) : (r += 1) {
        if (r < app.tbs.flush_dirty.bit_length) {
            app.tbs.flush_dirty.set(r);
        }
    }

    app.flush_needs_invalidate = true;
}

pub fn onGridRowScroll(
    ctx: ?*anyopaque,
    grid_id: i64,
    row_start: u32,
    row_end: u32,
    col_start: u32,
    col_end: u32,
    rows_delta: i32,
    total_rows: u32,
    total_cols: u32,
) callconv(.c) void {
    _ = col_start;
    _ = col_end;
    const app = getApp(ctx) orelse return;

    app.mu.lock();
    defer app.mu.unlock();

    if (app.external_windows.getPtr(grid_id)) |ext| {
        const vs = ext.tbs.writeSet();
        vs.rows = total_rows;
        vs.cols = total_cols;

        if (vs.row_map.items.len >= row_end) {
            remapRowSlots(
                vs.row_map.items,
                &ext.tbs.pool,
                row_start,
                row_end,
                rows_delta,
            );
        }
        ext.needs_redraw = true;
    }
}

// =========================================================================
// Render plan callback (unused when row mode is active)
// =========================================================================

pub fn onRenderPlan(
    ctx: ?*anyopaque,
    bg_spans: [*]const app_mod.BgSpan,
    bg_span_count: usize,
    text_runs: [*]const app_mod.TextRun,
    text_run_count: usize,
    rows: u32,
    cols: u32,
    cursor: ?*const app_mod.Cursor,
) callconv(.c) void {
    _ = ctx;
    _ = bg_spans;
    _ = bg_span_count;
    _ = text_runs;
    _ = text_run_count;
    _ = rows;
    _ = cols;
    _ = cursor;
}

// =========================================================================
// Atlas callbacks (Phase 2: core-managed)
// =========================================================================

pub fn onRasterizeGlyph(ctx: ?*anyopaque, scalar: u32, style_flags: u32, out_bitmap: *app_mod.GlyphBitmap) callconv(.c) c_int {
    const app = getApp(ctx) orelse return 0;
    return if (ft_renderer.rasterizeGlyph(app, scalar, style_flags, out_bitmap)) 1 else 0;
}

pub fn onAtlasUpload(ctx: ?*anyopaque, dest_x: u32, dest_y: u32, width: u32, height: u32, bitmap: *const app_mod.GlyphBitmap) callconv(.c) void {
    const app = getApp(ctx) orelse {
        if (applog.isEnabled()) applog.appLog("[atlas] onAtlasUpload: getApp failed\n", .{});
        return;
    };
    if (applog.isEnabled()) applog.appLog("[atlas] onAtlasUpload: dest=({d},{d}) size={d}x{d} pixels={} bpp={d} pitch={d}\n", .{
        dest_x, dest_y, width, height, bitmap.pixels != null, bitmap.bytes_per_pixel, bitmap.pitch,
    });
    if (bitmap.pixels == null or width == 0 or height == 0) return;

    const bpp = bitmap.bytes_per_pixel;
    const abs_pitch: u32 = if (bitmap.pitch >= 0) @intCast(bitmap.pitch) else @intCast(-bitmap.pitch);
    const row_bytes: u32 = if (abs_pitch > 0) abs_pitch else width * bpp;
    const total_bytes: usize = @as(usize, row_bytes) * @as(usize, height);

    const pixel_copy = app.alloc.alloc(u8, total_bytes) catch return;
    const src: [*]const u8 = @ptrCast(bitmap.pixels.?);
    @memcpy(pixel_copy, src[0..total_bytes]);

    app.atlas_mu.lock();
    defer app.atlas_mu.unlock();
    app.pending_atlas_ops.append(app.alloc, .{ .upload = .{
        .dest_x = dest_x,
        .dest_y = dest_y,
        .width = width,
        .height = height,
        .pixels = pixel_copy,
        .bpp = bpp,
        .pitch = bitmap.pitch,
    } }) catch {
        app.alloc.free(pixel_copy);
    };
}

pub fn onAtlasCreate(ctx: ?*anyopaque, atlas_w: u32, atlas_h: u32) callconv(.c) void {
    const app = getApp(ctx) orelse return;

    app.atlas_mu.lock();
    defer app.atlas_mu.unlock();
    app.pending_atlas_ops.append(app.alloc, .{ .create = .{
        .w = atlas_w,
        .h = atlas_h,
    } }) catch {};
}

// =========================================================================
// Text shaping callbacks
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
    const app = getApp(ctx) orelse return 0;
    return ft_renderer.shapeTextRun(
        app,
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

pub fn onRasterizeGlyphById(
    ctx: ?*anyopaque,
    glyph_id: u32,
    style_flags: u32,
    out_bitmap: *app_mod.GlyphBitmap,
) callconv(.c) c_int {
    const app = getApp(ctx) orelse return 0;
    return if (ft_renderer.rasterizeGlyphById(app, glyph_id, style_flags, out_bitmap)) 1 else 0;
}

pub fn onGetAsciiTable(
    ctx: ?*anyopaque,
    style_flags: u32,
    out_glyph_ids: [*]u32,
    out_x_advances: [*]i32,
    out_lig_triggers: [*]u8,
) callconv(.c) c_int {
    const app = getApp(ctx) orelse return 0;
    return if (ft_renderer.getAsciiTable(app, style_flags, out_glyph_ids, out_x_advances, out_lig_triggers)) 1 else 0;
}

// =========================================================================
// Phase 1 atlas callbacks (fallback, not used with Phase 2)
// =========================================================================

pub fn onAtlasEnsureGlyph(ctx: ?*anyopaque, scalar: u32, out_entry: *app_mod.GlyphEntry) callconv(.c) c_int {
    _ = ctx;
    _ = scalar;
    _ = out_entry;
    return 0;
}

pub fn onAtlasEnsureGlyphStyled(ctx: ?*anyopaque, scalar: u32, style_flags: u32, out_entry: *app_mod.GlyphEntry) callconv(.c) c_int {
    _ = ctx;
    _ = scalar;
    _ = style_flags;
    _ = out_entry;
    return 0;
}

// =========================================================================
// Logging callback
// =========================================================================

pub fn onLog(ctx: ?*anyopaque, bytes: [*]const u8, len: usize) callconv(.c) void {
    _ = ctx;
    if (!applog.isEnabled()) return;
    if (len == 0) return;
    const s: []const u8 = bytes[0..len];
    applog.appLogBytes("", s);
}

// =========================================================================
// Font / linespace callbacks
// =========================================================================

pub fn onGuiFont(ctx: ?*anyopaque, bytes: [*]const u8, len: usize) callconv(.c) void {
    const app = getApp(ctx) orelse return;

    const os_default_font = "monospace";
    const default_font_pt: f32 = 14.0;

    const config_font = if (app.config.font.family.len > 0) app.config.font.family else os_default_font;
    const config_pt: f32 = if (app.config.font.size > 0.0) app.config.font.size else default_font_pt;

    var font_name: []const u8 = config_font;
    var font_pt: f32 = config_pt;

    // Parse guifont string: "font_name\tsize"
    if (len > 0) {
        const guifont_str: []const u8 = bytes[0..len];
        if (std.mem.indexOfScalar(u8, guifont_str, '\t')) |tab_idx| {
            const name_part = guifont_str[0..tab_idx];
            const size_part = guifont_str[tab_idx + 1 ..];
            if (name_part.len > 0) font_name = name_part;
            if (std.fmt.parseFloat(f32, size_part)) |pt| {
                if (pt > 0.0) font_pt = pt;
            } else |_| {}
        }
    }

    if (applog.isEnabled()) {
        applog.appLog("[linux] onGuiFont: {s} {d:.1}pt\n", .{ font_name, font_pt });
    }

    // Load font synchronously (CRITICAL: must complete before vertex generation resumes)
    if (ft_renderer.loadFont(app.alloc, app, font_name, font_pt, app.dpi_scale)) {
        // Notify core of updated cell dimensions (cell height includes linespace)
        const ch: u32 = @max(1, app.cell_h_px + app.linespace_px);
        if (app.corep != null and app.drawable_w_px > 0 and app.drawable_h_px > 0) {
            app_mod.zonvie_core_update_layout_px(
                app.corep,
                app.drawable_w_px,
                app.drawable_h_px,
                app.cell_w_px,
                ch,
            );
            // Cannot call zonvie_core_set_screen_cols from callback context
            // (core holds grid_mu). Defer to GTK main thread.
            _ = gtk_mod.g_idle_add(&idleUpdateScreenCols, @ptrCast(app));
        }
    }
}

pub fn onLineSpace(ctx: ?*anyopaque, linespace_px: i32) callconv(.c) void {
    const app = getApp(ctx) orelse return;
    app.linespace_px = @intCast(@max(0, linespace_px));

    if (applog.isEnabled()) {
        applog.appLog("[linux] onLineSpace: {d}px\n", .{linespace_px});
    }
}

// =========================================================================
// Exit / quit callbacks
// =========================================================================

pub fn onExit(ctx: ?*anyopaque, exit_code: i32) callconv(.c) void {
    const app = getApp(ctx) orelse return;
    app_mod.g_exit_code.store(@intCast(@max(0, @min(255, exit_code))), .seq_cst);

    // Dispatch quit to GTK main thread
    _ = gtk_mod.g_idle_add(&idleQuit, @ptrCast(app));
}

fn idleQuit(user_data: ?*anyopaque) callconv(.c) c_int {
    const app = getApp(user_data) orelse return 0;
    if (app.gtk_app) |gapp| {
        main_mod.gtk_externs.application_quit(gapp);
    }
    return 0; // G_SOURCE_REMOVE
}

pub fn onQuitRequested(ctx: ?*anyopaque, has_unsaved: c_int) callconv(.c) void {
    const app = getApp(ctx) orelse return;

    if (has_unsaved != 0) {
        // Dispatch dialog to GTK main thread
        _ = gtk_mod.g_idle_add(&idleShowQuitDialog, @ptrCast(app));
    } else {
        if (app.corep) |corep| {
            app_mod.zonvie_core_quit_confirmed(corep, 0);
        }
    }
}

fn idleShowQuitDialog(user_data: ?*anyopaque) callconv(.c) c_int {
    const app = getApp(user_data) orelse return 0;
    const win = app.main_window orelse return 0;

    const GTK_DIALOG_MODAL = 0x01;
    const GTK_DIALOG_DESTROY_WITH_PARENT = 0x02;
    const GTK_MESSAGE_WARNING = 3;
    const GTK_BUTTONS_NONE = 0;
    const dialog = gtk_message_dialog_new(
        win,
        GTK_DIALOG_MODAL | GTK_DIALOG_DESTROY_WITH_PARENT,
        GTK_MESSAGE_WARNING,
        GTK_BUTTONS_NONE,
        "There are unsaved changes. Quit anyway?",
    ) orelse return 0;

    _ = gtk_dialog_add_button(dialog, "Cancel", 0);
    _ = gtk_dialog_add_button(dialog, "Discard and Quit", 1);

    _ = gtk_mod.g_signal_connect(dialog, "response", @ptrCast(&onQuitDialogResponse), @ptrCast(app));
    gtk_widget_set_visible(dialog, 1);

    return 0; // G_SOURCE_REMOVE
}

fn onQuitDialogResponse(dialog: ?*anyopaque, response_id: c_int, user_data: ?*anyopaque) callconv(.c) void {
    const app = getApp(user_data) orelse return;

    if (dialog) |d| {
        gtk_window_destroy(d);
    }

    if (response_id == 1) {
        // Discard and quit
        if (app.corep) |corep| {
            app_mod.zonvie_core_quit_confirmed(corep, 1);
        }
    }
    // else: cancel, do nothing
}

extern "c" fn gtk_message_dialog_new(
    parent: ?*anyopaque,
    flags: c_uint,
    msg_type: c_int,
    buttons: c_int,
    message: [*:0]const u8,
    ...,
) ?*anyopaque;
extern "c" fn gtk_dialog_add_button(dialog: *anyopaque, label: [*:0]const u8, response_id: c_int) ?*anyopaque;
extern "c" fn gtk_widget_set_visible(widget: *anyopaque, visible: c_int) void;
extern "c" fn gtk_window_destroy(window: *anyopaque) void;

// =========================================================================
// Default colors callback
// =========================================================================

pub fn onDefaultColorsSet(ctx: ?*anyopaque, fg: u32, bg: u32) callconv(.c) void {
    const app = getApp(ctx) orelse return;
    if (fg != 0xFFFFFFFF) app.default_fg = fg;
    if (bg != 0xFFFFFFFF) {
        app.default_bg = bg;
        // Update GTK CSS background to match, preventing window-color flicker during resize
        if (app.css_provider) |provider| {
            const r = (bg >> 16) & 0xFF;
            const g = (bg >> 8) & 0xFF;
            const b = bg & 0xFF;
            var css_buf: [128]u8 = undefined;
            const css = std.fmt.bufPrint(&css_buf, ".zonvie-gl {{ background-color: rgb({d},{d},{d}); }}\x00", .{ r, g, b }) catch return;
            const css_z: [*:0]const u8 = @ptrCast(css.ptr);
            main_mod.gtk_externs.css_provider_load_from_string(provider, css_z);
        }
    }
    app.flush_needs_invalidate = true;
}

// =========================================================================
// Set title callback
// =========================================================================

pub fn onSetTitle(ctx: ?*anyopaque, title: [*]const u8, title_len: usize) callconv(.c) void {
    const app = getApp(ctx) orelse return;
    if (title_len == 0) return;

    const copy_len = @min(title_len, app.pending_title.len - 1);
    @memcpy(app.pending_title[0..copy_len], title[0..copy_len]);
    app.pending_title[copy_len] = 0;
    app.pending_title_len = copy_len;

    _ = gtk_mod.g_idle_add(&idleSetTitle, @ptrCast(app));
}

fn idleSetTitle(user_data: ?*anyopaque) callconv(.c) c_int {
    const app = getApp(user_data) orelse return 0;
    const win = app.main_window orelse return 0;
    if (app.pending_title_len > 0) {
        gtk_window_set_title(win, @ptrCast(&app.pending_title));
    }
    return 0; // G_SOURCE_REMOVE
}

extern "c" fn gtk_window_set_title(window: *anyopaque, title: [*:0]const u8) void;

// =========================================================================
// IME callback
// =========================================================================

pub fn onIMEOff(ctx: ?*anyopaque) callconv(.c) void {
    const app = getApp(ctx) orelse return;
    // Dispatch to GTK main thread
    _ = gtk_mod.g_idle_add(&idleIMEReset, @ptrCast(app));
}

fn idleIMEReset(user_data: ?*anyopaque) callconv(.c) c_int {
    const app = getApp(user_data) orelse return 0;
    if (app.im_context) |im| {
        main_mod.gtk_externs.im_context_reset(im);
    }
    return 0;
}

// =========================================================================
// Clipboard callbacks
// =========================================================================

pub fn onClipboardGet(
    ctx: ?*anyopaque,
    register: [*]const u8,
    out_buf: [*]u8,
    out_len: *usize,
    max_len: usize,
) callconv(.c) c_int {
    _ = register;
    const app = getApp(ctx) orelse {
        out_len.* = 0;
        return 1;
    };

    if (applog.isEnabled()) applog.appLog("[linux] clipboard_get: called\n", .{});

    // Reset state and post to GTK main thread
    app.clipboard_mu.lock();
    app.clipboard_ready = false;
    app.clipboard_len = 0;
    app.clipboard_result = 1;
    app.clipboard_mu.unlock();

    _ = gtk_mod.g_idle_add(&idleClipboardGet, @ptrCast(app));

    // Wait for GTK main thread to complete (timeout 5s)
    app.clipboard_mu.lock();
    defer app.clipboard_mu.unlock();
    if (!app.clipboard_ready) {
        app.clipboard_cond.timedWait(&app.clipboard_mu, 5_000_000_000) catch {};
    }

    if (!app.clipboard_ready) {
        if (applog.isEnabled()) applog.appLog("[linux] clipboard_get: timeout\n", .{});
        out_len.* = 0;
        return 1;
    }

    const copy_len = @min(app.clipboard_len, max_len);
    if (copy_len > 0) {
        @memcpy(out_buf[0..copy_len], app.clipboard_buf[0..copy_len]);
    }
    out_len.* = copy_len;

    if (applog.isEnabled()) applog.appLog("[linux] clipboard_get: len={d}\n", .{copy_len});
    return app.clipboard_result;
}

fn idleClipboardGet(user_data: ?*anyopaque) callconv(.c) c_int {
    const app = getApp(user_data) orelse return 0;
    const display = gdk_display_get_default() orelse {
        signalClipboardDone(app, 1, 0);
        return 0;
    };
    const clipboard = gdk_display_get_clipboard(display) orelse {
        signalClipboardDone(app, 1, 0);
        return 0;
    };
    gdk_clipboard_read_text_async(clipboard, null, &onClipboardReadFinish, @ptrCast(app));
    return 0; // G_SOURCE_REMOVE
}

fn onClipboardReadFinish(source: ?*anyopaque, result: ?*anyopaque, user_data: ?*anyopaque) callconv(.c) void {
    const app = getApp(user_data) orelse return;
    const clipboard = source orelse {
        signalClipboardDone(app, 1, 0);
        return;
    };

    var err: ?*anyopaque = null;
    const text_ptr: ?[*:0]const u8 = gdk_clipboard_read_text_finish(clipboard, result, &err);
    if (err != null) {
        g_error_free(err.?);
        signalClipboardDone(app, 1, 0);
        return;
    }
    if (text_ptr == null) {
        signalClipboardDone(app, 1, 0);
        return;
    }

    const text = std.mem.span(text_ptr.?);
    const copy_len = @min(text.len, app.clipboard_buf.len);
    @memcpy(app.clipboard_buf[0..copy_len], text[0..copy_len]);
    g_free(@ptrCast(@constCast(text_ptr.?)));
    signalClipboardDone(app, 0, copy_len);
}

fn signalClipboardDone(app: *App, result: c_int, len: usize) void {
    app.clipboard_mu.lock();
    defer app.clipboard_mu.unlock();
    app.clipboard_result = result;
    app.clipboard_len = len;
    app.clipboard_ready = true;
    app.clipboard_cond.signal();
}

pub fn onClipboardSet(
    ctx: ?*anyopaque,
    register: [*]const u8,
    data: [*]const u8,
    len: usize,
) callconv(.c) c_int {
    _ = register;
    const app = getApp(ctx) orelse return 0;

    if (applog.isEnabled()) applog.appLog("[linux] clipboard_set: called len={d}\n", .{len});
    if (len == 0) return 1;

    // Reset state, store data pointer for GTK thread
    app.clipboard_mu.lock();
    app.clipboard_ready = false;
    app.clipboard_set_data = data;
    app.clipboard_set_len = len;
    app.clipboard_result = 0;
    app.clipboard_mu.unlock();

    _ = gtk_mod.g_idle_add(&idleClipboardSet, @ptrCast(app));

    // Wait for GTK main thread to complete
    app.clipboard_mu.lock();
    defer app.clipboard_mu.unlock();
    if (!app.clipboard_ready) {
        app.clipboard_cond.timedWait(&app.clipboard_mu, 5_000_000_000) catch {};
    }

    if (!app.clipboard_ready) {
        // Invalidate data pointer to prevent GTK callback from reading stale memory
        app.clipboard_set_data = null;
        app.clipboard_set_len = 0;
        if (applog.isEnabled()) applog.appLog("[linux] clipboard_set: timeout\n", .{});
        return 0;
    }

    if (applog.isEnabled()) applog.appLog("[linux] clipboard_set: result={d}\n", .{app.clipboard_result});
    return app.clipboard_result;
}

fn idleClipboardSet(user_data: ?*anyopaque) callconv(.c) c_int {
    const app = getApp(user_data) orelse return 0;
    const display = gdk_display_get_default() orelse {
        signalClipboardDone(app, 0, 0);
        return 0;
    };
    const clipboard = gdk_display_get_clipboard(display) orelse {
        signalClipboardDone(app, 0, 0);
        return 0;
    };

    app.clipboard_mu.lock();
    const data = app.clipboard_set_data;
    const len = app.clipboard_set_len;
    app.clipboard_mu.unlock();

    if (data) |d| {
        // Copy to a NUL-terminated buffer for gdk_clipboard_set_text
        const copy_len = @min(len, app.clipboard_buf.len - 1);
        @memcpy(app.clipboard_buf[0..copy_len], d[0..copy_len]);
        app.clipboard_buf[copy_len] = 0;
        gdk_clipboard_set_text(clipboard, @ptrCast(&app.clipboard_buf));
        signalClipboardDone(app, 1, copy_len);
    } else {
        signalClipboardDone(app, 0, 0);
    }

    return 0; // G_SOURCE_REMOVE
}

// GDK clipboard extern declarations
extern "c" fn gdk_display_get_default() ?*anyopaque;
extern "c" fn gdk_display_get_clipboard(display: *anyopaque) ?*anyopaque;
extern "c" fn gdk_clipboard_read_text_async(clipboard: *anyopaque, cancellable: ?*anyopaque, callback: *const fn (?*anyopaque, ?*anyopaque, ?*anyopaque) callconv(.c) void, user_data: ?*anyopaque) void;
extern "c" fn gdk_clipboard_read_text_finish(clipboard: *anyopaque, result: ?*anyopaque, err: *?*anyopaque) ?[*:0]const u8;
extern "c" fn gdk_clipboard_set_text(clipboard: *anyopaque, text: [*:0]const u8) void;
extern "c" fn g_free(ptr: ?*anyopaque) void;
extern "c" fn g_error_free(err: *anyopaque) void;

// =========================================================================
// SSH auth prompt callback
// =========================================================================

pub fn onSSHAuthPrompt(ctx: ?*anyopaque, prompt: [*]const u8, prompt_len: usize) callconv(.c) void {
    _ = ctx;
    _ = prompt;
    _ = prompt_len;
    // TODO: show GTK password dialog, send password via zonvie_core_send_stdin_data
}

// =========================================================================
// Screen cols for cmdline width clamping
// =========================================================================

/// Update core screen_cols so cmdline grid width is clamped to the available viewport.
/// Must be called when drawable size or cell size changes.
pub fn updateScreenCols(app: *App) void {
    const corep = app.corep orelse return;
    const cell_w = app.cell_w_px;
    if (cell_w == 0) return;

    const drawable_w = app.drawable_w_px;
    if (drawable_w == 0) return;

    // Subtract cmdline decoration overhead from available width
    const overhead: u32 = app_mod.CMDLINE_PADDING * 2 +
        app_mod.CMDLINE_ICON_MARGIN_LEFT + app_mod.CMDLINE_ICON_SIZE + app_mod.CMDLINE_ICON_MARGIN_RIGHT;
    const avail_px: u32 = if (drawable_w > overhead) drawable_w - overhead else drawable_w;
    const screen_cols: u32 = @max(40, avail_px / cell_w);
    app_mod.zonvie_core_set_screen_cols(corep, screen_cols);
}

fn idleUpdateScreenCols(user_data: ?*anyopaque) callconv(.c) c_int {
    const app = getApp(user_data) orelse return 0;
    updateScreenCols(app);
    return 0; // G_SOURCE_REMOVE
}

// =========================================================================
// Cmdline callbacks (ext_cmdline)
// =========================================================================

pub fn onCmdlineShow(
    ctx: ?*anyopaque,
    _: [*]const app_mod.CmdlineChunk, // content
    _: usize, // content_count
    _: u32, // pos
    firstc: u8,
    _: [*]const u8, // prompt
    _: usize, // prompt_len
    _: u32, // indent
    _: u32, // level
    _: u32, // prompt_hl_id
) callconv(.c) void {
    const app = getApp(ctx) orelse return;
    if (applog.isEnabled()) applog.appLog("[linux] on_cmdline_show: firstc={c}({d})\n", .{ firstc, firstc });

    app.mu.lock();
    app.cmdline_firstc = firstc;
    app.cmdline_visible = true;
    app.mu.unlock();

    // Schedule cmdline color update on GTK main thread
    // (cannot call core hl lookup from callback context — core lock is held)
    _ = gtk_mod.g_idle_add(&idleUpdateCmdlineColors, @ptrCast(app));
}

pub fn onCmdlineHide(ctx: ?*anyopaque, _: u32) callconv(.c) void {
    const app = getApp(ctx) orelse return;
    if (applog.isEnabled()) applog.appLog("[linux] on_cmdline_hide\n", .{});

    app.mu.lock();
    app.cmdline_firstc = 0;
    app.cmdline_visible = false;
    app.mu.unlock();

    // Request redraw to clear the overlay
    if (app.gl_area) |area| {
        _ = gtk_mod.g_idle_add(&idleQueueRedraw, @ptrCast(app));
        _ = area;
    }
}

fn idleQueueRedraw(user_data: ?*anyopaque) callconv(.c) c_int {
    const app = getApp(user_data) orelse return 0;
    if (app.gl_area) |area| {
        main_mod.gtk_externs.widget_queue_draw(area);
    }
    return 0; // remove idle source
}

fn idleUpdateCmdlineColors(user_data: ?*anyopaque) callconv(.c) c_int {
    const app = getApp(user_data) orelse return 0;
    const corep = app.corep orelse return 0;

    // Colors derived from core highlights (matching Windows/macOS):
    //   Border: Search highlight background
    //   Icon:   Comment highlight foreground
    var border_r: f32 = 1.0;
    var border_g: f32 = 1.0;
    var border_b: f32 = 0.0; // default yellow
    var icon_r: f32 = 0.5;
    var icon_g: f32 = 0.5;
    var icon_b: f32 = 0.5; // default gray

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

    app.mu.lock();
    app.cmdline_border_color = .{ border_r, border_g, border_b };
    app.cmdline_icon_color = .{ icon_r, icon_g, icon_b };
    app.mu.unlock();

    // Trigger redraw
    if (app.gl_area) |area| {
        main_mod.gtk_externs.widget_queue_draw(area);
    }
    return 0; // remove idle source
}

pub fn onCmdlinePos(ctx: ?*anyopaque, _: u32, _: u32) callconv(.c) void {
    _ = ctx;
    // Cursor position update — rendering uses core-generated vertices, nothing extra needed
}

pub fn onCmdlineSpecialChar(ctx: ?*anyopaque, _: [*]const u8, _: usize, _: bool, _: u32) callconv(.c) void {
    _ = ctx;
    // Special character display handled by core grid
}

pub fn onCmdlineBlockShow(ctx: ?*anyopaque, _: [*]const core.CmdlineBlockLine, _: usize) callconv(.c) void {
    _ = ctx;
    // Block mode (multi-line cmdline) — TODO if needed
}

pub fn onCmdlineBlockAppend(ctx: ?*anyopaque, _: ?[*]const app_mod.CmdlineChunk, _: usize) callconv(.c) void {
    _ = ctx;
}

pub fn onCmdlineBlockHide(ctx: ?*anyopaque) callconv(.c) void {
    _ = ctx;
}

// =========================================================================
// Popupmenu callbacks (ext_popupmenu)
// =========================================================================

pub fn onPopupmenuShow(
    ctx: ?*anyopaque,
    _: ?*const anyopaque, // items
    _: usize, // item_count
    _: i32, // selected
    row: i32,
    col: i32,
    grid_id: i64,
) callconv(.c) void {
    const app = getApp(ctx) orelse return;
    if (applog.isEnabled()) applog.appLog("[linux] on_popupmenu_show: row={d} col={d} grid={d}\n", .{ row, col, grid_id });

    app.mu.lock();
    app.popupmenu_visible = true;
    app.popupmenu_anchor_row = row;
    app.popupmenu_anchor_col = col;
    app.popupmenu_anchor_grid = grid_id;
    app.mu.unlock();
}

pub fn onPopupmenuHide(ctx: ?*anyopaque) callconv(.c) void {
    const app = getApp(ctx) orelse return;
    if (applog.isEnabled()) applog.appLog("[linux] on_popupmenu_hide\n", .{});

    app.mu.lock();
    app.popupmenu_visible = false;
    app.mu.unlock();

    _ = gtk_mod.g_idle_add(&idleQueueRedraw, @ptrCast(app));
}

pub fn onPopupmenuSelect(ctx: ?*anyopaque, _: i32) callconv(.c) void {
    _ = ctx;
    // Selection change is handled by core vertex generation
}

// =========================================================================
// Message callbacks (ext_messages)
// =========================================================================

pub fn onMsgShow(
    ctx: ?*anyopaque,
    view: app_mod.zonvie_msg_view_type,
    kind: [*]const u8,
    kind_len: usize,
    chunks: [*]const app_mod.MsgChunk,
    chunk_count: usize,
    replace_last: c_int,
    history: c_int,
    append: c_int,
    msg_id: i64,
    timeout_ms: u32,
) callconv(.c) void {
    _ = history;
    _ = msg_id;
    _ = replace_last;
    _ = append;
    _ = chunks;
    _ = chunk_count;
    const app = getApp(ctx) orelse return;

    if (view == .none) return;

    if (applog.isEnabled()) applog.appLog("[linux] on_msg_show: kind={s} view={d} timeout_ms={d}\n", .{
        kind[0..kind_len], @intFromEnum(view), timeout_ms,
    });

    // Route based on view type
    switch (view) {
        .mini => {
            // Mini messages are handled by showmode/showcmd/ruler callbacks
            return;
        },
        .notification => {
            // OS-level notifications not yet supported on Linux
            return;
        },
        else => {},
    }

    // ext_float / confirm / split: rendered via MESSAGE_GRID_ID overlay grid.
    // Core generates grid vertices and sends them through onExternalWindow +
    // onVerticesRow for MESSAGE_GRID_ID. We only need to manage the auto-hide timer.
    const timeout_sec: f32 = if (timeout_ms > 0) @as(f32, @floatFromInt(timeout_ms)) / 1000.0 else 4.0;
    scheduleMsgHideTimer(app, timeout_sec);

    _ = gtk_mod.g_idle_add(&idleQueueRedraw, @ptrCast(app));
}

fn scheduleMsgHideTimer(app: *App, timeout_sec: f32) void {
    // Cancel existing timer
    if (app.msg_hide_timer != 0) {
        _ = gtk_mod.g_source_remove(app.msg_hide_timer);
        app.msg_hide_timer = 0;
    }

    if (timeout_sec > 0) {
        const interval_ms: c_uint = @intFromFloat(timeout_sec * 1000.0);
        if (interval_ms > 0) {
            app.msg_hide_timer = gtk_mod.g_timeout_add(interval_ms, &onMsgHideTimer, @ptrCast(app));
        }
    }
}

fn onMsgHideTimer(user_data: ?*anyopaque) callconv(.c) c_int {
    const app = getApp(user_data) orelse return 0;
    app.msg_hide_timer = 0;

    // Tell core to tick message throttle which will close expired grids
    if (app.corep) |corep| {
        app_mod.zonvie_core_tick_msg_throttle(corep);
    }

    if (app.gl_area) |area| {
        main_mod.gtk_externs.widget_queue_draw(area);
    }
    return 0; // G_SOURCE_REMOVE
}

pub fn onMsgClear(ctx: ?*anyopaque) callconv(.c) void {
    const app = getApp(ctx) orelse return;

    if (applog.isEnabled()) applog.appLog("[linux] on_msg_clear\n", .{});

    if (app.msg_hide_timer != 0) {
        _ = gtk_mod.g_source_remove(app.msg_hide_timer);
        app.msg_hide_timer = 0;
    }

    // Core will close MESSAGE_GRID_ID which triggers onExternalWindowClose → redraw
}

pub fn onMsgShowmode(
    ctx: ?*anyopaque,
    view: app_mod.zonvie_msg_view_type,
    chunks: [*]const app_mod.MsgChunk,
    chunk_count: usize,
) callconv(.c) void {
    handleMsgMini(ctx, view, .showmode, chunks, chunk_count);
}

pub fn onMsgShowcmd(
    ctx: ?*anyopaque,
    view: app_mod.zonvie_msg_view_type,
    chunks: [*]const app_mod.MsgChunk,
    chunk_count: usize,
) callconv(.c) void {
    handleMsgMini(ctx, view, .showcmd, chunks, chunk_count);
}

pub fn onMsgRuler(
    ctx: ?*anyopaque,
    view: app_mod.zonvie_msg_view_type,
    chunks: [*]const app_mod.MsgChunk,
    chunk_count: usize,
) callconv(.c) void {
    handleMsgMini(ctx, view, .ruler, chunks, chunk_count);
}

fn handleMsgMini(
    ctx: ?*anyopaque,
    view: app_mod.zonvie_msg_view_type,
    mini_id: app_mod.MiniWindowId,
    chunks: [*]const app_mod.MsgChunk,
    chunk_count: usize,
) void {
    const app = getApp(ctx) orelse return;

    if (view == .none) return;

    // Build text from chunks
    var text_buf: [256]u8 = undefined;
    var text_len: usize = 0;
    for (chunks[0..chunk_count]) |chunk| {
        const text = chunk.text[0..chunk.text_len];
        const copy_len = @min(text.len, text_buf.len - text_len);
        @memcpy(text_buf[text_len..][0..copy_len], text[0..copy_len]);
        text_len += copy_len;
        if (text_len >= text_buf.len) break;
    }

    const idx = @intFromEnum(mini_id);
    app.mu.lock();
    @memcpy(app.mini_windows[idx].text[0..text_len], text_buf[0..text_len]);
    app.mini_windows[idx].text_len = text_len;
    app.mu.unlock();

    _ = gtk_mod.g_idle_add(&idleUpdateMiniLabel, @ptrCast(app));
}

fn idleUpdateMiniLabel(user_data: ?*anyopaque) callconv(.c) c_int {
    const app = getApp(user_data) orelse return 0;
    const label = app.mini_label orelse return 0;

    // Combine all mini windows into one string: "showmode  showcmd  ruler"
    var combined: [768]u8 = undefined;
    var combined_len: usize = 0;

    app.mu.lock();
    for (app.mini_windows) |mw| {
        if (mw.text_len > 0) {
            if (combined_len > 0 and combined_len < combined.len - 2) {
                combined[combined_len] = ' ';
                combined[combined_len + 1] = ' ';
                combined_len += 2;
            }
            const copy_len = @min(mw.text_len, combined.len - combined_len);
            @memcpy(combined[combined_len..][0..copy_len], mw.text[0..copy_len]);
            combined_len += copy_len;
        }
    }
    app.mu.unlock();

    if (combined_len > 0 and combined_len < combined.len) {
        combined[combined_len] = 0;
        main_mod.gtk_externs.label_set_text(label, @ptrCast(&combined));
        main_mod.gtk_externs.widget_set_visible(label, 1);
    } else {
        main_mod.gtk_externs.label_set_text(label, "");
        main_mod.gtk_externs.widget_set_visible(label, 0);
    }

    return 0; // G_SOURCE_REMOVE
}

pub fn onMsgHistoryShow(
    ctx: ?*anyopaque,
    entries: [*]const app_mod.MsgHistoryEntry,
    entry_count: usize,
    prev_cmd: c_int,
) callconv(.c) void {
    _ = prev_cmd;
    _ = entries;
    const app = getApp(ctx) orelse return;

    if (applog.isEnabled()) applog.appLog("[linux] on_msg_history_show: entries={d}\n", .{entry_count});

    // Core renders history via MSG_HISTORY_GRID_ID overlay grid.
    _ = gtk_mod.g_idle_add(&idleQueueRedraw, @ptrCast(app));
}

// =========================================================================
// Tabline callbacks (ext_tabline)
// =========================================================================

pub fn onTablineUpdate(
    ctx: ?*anyopaque,
    curtab: i64,
    tabs: [*]const core.TabEntry,
    tab_count: usize,
    curbuf: i64,
    buffers: [*]const core.BufferEntry,
    buffer_count: usize,
) callconv(.c) void {
    _ = curbuf;
    _ = buffers;
    _ = buffer_count;
    const app = getApp(ctx) orelse return;

    if (applog.isEnabled()) applog.appLog("[linux] onTablineUpdate: curtab={d} tab_count={d}\n", .{ curtab, tab_count });

    app.mu.lock();
    defer app.mu.unlock();

    app.tabline.clear(app.alloc);
    app.tabline.current_tab = curtab;
    app.tabline.visible = true;

    for (tabs[0..tab_count]) |tab| {
        const name_slice = tab.name[0..tab.name_len];
        const name_copy = app.alloc.dupe(u8, name_slice) catch continue;
        app.tabline.tabs.append(app.alloc, .{
            .tab_handle = tab.tab_handle,
            .name = name_copy,
            .name_owned = true,
        }) catch {
            app.alloc.free(name_copy);
            continue;
        };
    }

    _ = gtk_mod.g_idle_add(&idleUpdateTabBar, @ptrCast(app));
}

pub fn onTablineHide(ctx: ?*anyopaque) callconv(.c) void {
    const app = getApp(ctx) orelse return;

    if (applog.isEnabled()) applog.appLog("[linux] onTablineHide\n", .{});

    app.mu.lock();
    app.tabline.visible = false;
    app.mu.unlock();

    _ = gtk_mod.g_idle_add(&idleUpdateTabBar, @ptrCast(app));
}

fn idleUpdateTabBar(user_data: ?*anyopaque) callconv(.c) c_int {
    const app = getApp(user_data) orelse return 0;
    const tab_box = app.tab_bar_box orelse return 0;

    // Remove all existing children
    removeAllBoxChildren(tab_box);

    // Copy tab info under lock to avoid holding mutex during GTK operations
    const MAX_TABS = 64;
    var tab_names: [MAX_TABS][64]u8 = undefined;
    var tab_name_lens: [MAX_TABS]usize = undefined;
    var tab_handles: [MAX_TABS]i64 = undefined;
    var copy_count: usize = 0;
    var current_tab: i64 = 0;
    var visible: bool = false;

    {
        app.mu.lock();
        defer app.mu.unlock();
        visible = app.tabline.visible;
        current_tab = app.tabline.current_tab;
        copy_count = @min(app.tabline.tabs.items.len, MAX_TABS);
        for (app.tabline.tabs.items[0..copy_count], 0..) |tab, i| {
            const name_len = @min(tab.name.len, tab_names[i].len - 1);
            @memcpy(tab_names[i][0..name_len], tab.name[0..name_len]);
            tab_names[i][name_len] = 0;
            tab_name_lens[i] = name_len;
            tab_handles[i] = tab.tab_handle;
        }
    }

    if (!visible or copy_count == 0) {
        main_mod.gtk_externs.widget_set_visible(tab_box, 0);
        return 0;
    }

    // Create a button for each tab (mutex released, safe for GTK calls)
    for (0..copy_count) |i| {
        const btn = main_mod.gtk_externs.button_new_with_label(@ptrCast(&tab_names[i])) orelse continue;
        main_mod.gtk_externs.widget_set_size_request(btn, 80, 28);

        if (tab_handles[i] == current_tab) {
            gtk_widget_add_css_class(btn, "current");
        }

        const idx_ptr: ?*anyopaque = @ptrFromInt(i + 1); // 1-based
        _ = gtk_mod.g_signal_connect(btn, "clicked", @ptrCast(&onTabButtonClicked), idx_ptr);

        main_mod.gtk_externs.box_append(tab_box, btn);
    }

    main_mod.gtk_externs.widget_set_visible(tab_box, 1);
    return 0;
}

fn onTabButtonClicked(button: ?*anyopaque, user_data: ?*anyopaque) callconv(.c) void {
    _ = button;
    const idx: usize = if (user_data) |p| @intFromPtr(p) else return;
    if (idx == 0) return;

    const app = app_mod.g_app orelse return;
    const corep = app.corep orelse return;

    var cmd_buf: [64]u8 = undefined;
    const cmd = std.fmt.bufPrint(&cmd_buf, "tabn {d}", .{idx}) catch return;
    // NUL-terminate in-place
    if (cmd.len < cmd_buf.len) {
        cmd_buf[cmd.len] = 0;
    }
    app_mod.zonvie_core_send_command(corep, @ptrCast(&cmd_buf), cmd.len);
}

extern "c" fn gtk_widget_add_css_class(widget: *anyopaque, css_class: [*:0]const u8) void;
extern "c" fn gtk_widget_get_first_child(widget: *anyopaque) ?*anyopaque;
extern "c" fn gtk_widget_get_next_sibling(widget: *anyopaque) ?*anyopaque;
extern "c" fn gtk_box_remove(box: *anyopaque, child: *anyopaque) void;

fn removeAllBoxChildren(box: *anyopaque) void {
    while (gtk_widget_get_first_child(box)) |child| {
        gtk_box_remove(box, child);
    }
}

// =========================================================================
// External window callbacks (ext_windows)
// =========================================================================

pub fn onExternalWindow(
    ctx: ?*anyopaque,
    grid_id: i64,
    win: i64,
    rows: u32,
    cols: u32,
    start_row: i32,
    start_col: i32,
) callconv(.c) void {
    const app = getApp(ctx) orelse return;

    const is_overlay = (grid_id == app_mod.CMDLINE_GRID_ID or
        grid_id == app_mod.POPUPMENU_GRID_ID or
        grid_id == app_mod.MESSAGE_GRID_ID or
        grid_id == app_mod.MSG_HISTORY_GRID_ID);

    if (is_overlay) {
        // Cmdline, popupmenu, and message grids are rendered as overlays on the main GLArea.
        // Register in external_windows without creating a GtkWindow.
        if (applog.isEnabled()) applog.appLog("[linux] onExternalWindow: overlay grid_id={d} rows={d} cols={d} start=({d},{d})\n", .{ grid_id, rows, cols, start_row, start_col });

        app.mu.lock();
        defer app.mu.unlock();

        if (app.external_windows.getPtr(grid_id)) |ext| {
            ext.rows = rows;
            ext.cols = cols;
            ext.start_row = start_row;
            ext.start_col = start_col;
        } else {
            app.external_windows.put(app.alloc, grid_id, .{
                .rows = rows,
                .cols = cols,
                .start_row = start_row,
                .start_col = start_col,
            }) catch {};
        }

        // Popupmenu: set visible and anchor from start_row/start_col
        // (onPopupmenuShow may not be called by core)
        if (grid_id == app_mod.POPUPMENU_GRID_ID) {
            app.popupmenu_visible = true;
            app.popupmenu_anchor_row = start_row;
            app.popupmenu_anchor_col = start_col;
            app.popupmenu_anchor_grid = win; // win field carries the anchor grid_id
        }
        return;
    }

    app.mu.lock();
    defer app.mu.unlock();

    app.pending_external_windows.append(app.alloc, .{
        .grid_id = grid_id,
        .win = win,
        .rows = rows,
        .cols = cols,
        .start_row = start_row,
        .start_col = start_col,
    }) catch {};

    // Dispatch window creation to GTK main thread
    _ = gtk_mod.g_idle_add(&idleCreateExternalWindow, @ptrCast(app));
}

fn idleCreateExternalWindow(user_data: ?*anyopaque) callconv(.c) c_int {
    const app = getApp(user_data) orelse return 0;
    // TODO: create GtkWindow + GLArea for each pending external window
    _ = app;
    return 0;
}

pub fn onExternalWindowClose(ctx: ?*anyopaque, grid_id: i64) callconv(.c) void {
    const app = getApp(ctx) orelse return;

    const is_overlay = (grid_id == app_mod.CMDLINE_GRID_ID or
        grid_id == app_mod.POPUPMENU_GRID_ID or
        grid_id == app_mod.MESSAGE_GRID_ID or
        grid_id == app_mod.MSG_HISTORY_GRID_ID);

    if (is_overlay) {
        if (applog.isEnabled()) applog.appLog("[linux] onExternalWindowClose: overlay grid_id={d}\n", .{grid_id});
        app.mu.lock();
        if (app.external_windows.fetchRemove(grid_id)) |kv| {
            var ext = kv.value;
            ext.deinit(app.alloc);
        }
        if (grid_id == app_mod.CMDLINE_GRID_ID) app.cmdline_visible = false;
        if (grid_id == app_mod.POPUPMENU_GRID_ID) app.popupmenu_visible = false;
        app.mu.unlock();
        _ = gtk_mod.g_idle_add(&idleQueueRedraw, @ptrCast(app));
        return;
    }

    // TODO: dispatch window destruction to GTK main thread for regular ext_windows
}

pub fn onExternalVertices(
    ctx: ?*anyopaque,
    grid_id: i64,
    verts: [*]const app_mod.Vertex,
    vert_count: usize,
    rows: u32,
    cols: u32,
) callconv(.c) void {
    const app = getApp(ctx) orelse return;

    app.mu.lock();

    if (app.external_windows.getPtr(grid_id)) |ext| {
        ext.rows = rows;
        ext.cols = cols;
        const vs = ext.tbs.writeSet();
        vs.flat_verts.clearRetainingCapacity();
        if (vert_count > 0) {
            vs.flat_verts.appendSlice(app.alloc, verts[0..vert_count]) catch {};
        }
        ext.needs_redraw = true;
    }

    app.mu.unlock();

    // For overlay grids, queue a redraw of the main GLArea
    if (grid_id == app_mod.CMDLINE_GRID_ID or grid_id == app_mod.POPUPMENU_GRID_ID or
        grid_id == app_mod.MESSAGE_GRID_ID or grid_id == app_mod.MSG_HISTORY_GRID_ID)
    {
        _ = gtk_mod.g_idle_add(&idleQueueRedraw, @ptrCast(app));
    }
}

pub fn onCursorGridChanged(ctx: ?*anyopaque, grid_id: i64) callconv(.c) void {
    _ = ctx;
    _ = grid_id;
    // TODO: activate corresponding window
}

pub fn onGridScroll(ctx: ?*anyopaque, grid_id: i64) callconv(.c) void {
    _ = ctx;
    _ = grid_id;
    // TODO: clear smooth scroll offset
}

// =========================================================================
// Window layout operation callbacks (ext_windows)
// =========================================================================

pub fn onWinMove(ctx: ?*anyopaque, grid_id: i64, win: i64, flags: i32) callconv(.c) void {
    _ = ctx;
    _ = grid_id;
    _ = win;
    _ = flags;
    // TODO: implement window move
}

pub fn onWinExchange(ctx: ?*anyopaque, grid_id: i64, win: i64, count: i32) callconv(.c) void {
    _ = ctx;
    _ = grid_id;
    _ = win;
    _ = count;
    // TODO: implement window exchange
}

pub fn onWinRotate(ctx: ?*anyopaque, grid_id: i64, win: i64, direction: i32, count: i32) callconv(.c) void {
    _ = ctx;
    _ = grid_id;
    _ = win;
    _ = direction;
    _ = count;
    // TODO: implement window rotate
}

pub fn onWinResizeEqual(ctx: ?*anyopaque) callconv(.c) void {
    _ = ctx;
    // TODO: implement window resize equal
}

pub fn onWinMoveCursor(ctx: ?*anyopaque, direction: i32, count: i32) callconv(.c) i64 {
    _ = ctx;
    _ = direction;
    _ = count;
    // TODO: implement window move cursor
    return 0;
}
