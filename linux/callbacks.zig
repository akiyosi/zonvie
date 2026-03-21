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
            entry.value_ptr.tbs.commitFlush(app.alloc);
        }
        app.mu.unlock();
    }

    // Queue redraw on GTK main thread
    _ = gtk_mod.g_idle_add(&idleQueueDraw, @ptrCast(app));
}

fn idleQueueDraw(user_data: ?*anyopaque) callconv(.c) c_int {
    const app = getApp(user_data) orelse return 0;
    if (app.gl_area) |area| {
        main_mod.gtk_externs.widget_queue_draw(area);
    }
    return 0; // G_SOURCE_REMOVE
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

    // Route to external window if grid_id > 1
    if (grid_id > 1) {
        app.mu.lock();
        defer app.mu.unlock();
        if (app.external_windows.getPtr(grid_id)) |ext| {
            storeExternalRowVerts(app, ext, row_start, row_count, verts, vert_count, flags, total_rows, total_cols);
            return;
        }
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
    _ = flags;
    const vs = ext.tbs.writeSet();
    vs.row_mode = true;
    vs.rows = total_rows;
    vs.cols = total_cols;

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
        // TODO: show GTK confirmation dialog
        // For now, force quit
        if (app.corep) |corep| {
            app_mod.zonvie_core_quit_confirmed(corep, 1);
        }
    } else {
        if (app.corep) |corep| {
            app_mod.zonvie_core_quit_confirmed(corep, 0);
        }
    }
}

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

    // Must dispatch to GTK main thread
    _ = app;
    _ = title;
    // TODO: g_idle_add with title data
}

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
    _ = ctx;
    _ = register;
    _ = out_buf;
    _ = max_len;
    // TODO: implement GDK clipboard read (async -> sync bridge)
    out_len.* = 0;
    return 0;
}

pub fn onClipboardSet(
    ctx: ?*anyopaque,
    register: [*]const u8,
    data: [*]const u8,
    len: usize,
) callconv(.c) c_int {
    _ = ctx;
    _ = register;
    _ = data;
    _ = len;
    // TODO: implement GDK clipboard write
    return 0;
}

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
// Cmdline callbacks (ext_cmdline)
// =========================================================================

pub fn onCmdlineShow(
    ctx: ?*anyopaque,
    content: [*]const app_mod.CmdlineChunk,
    content_count: usize,
    pos: u32,
    firstc: u8,
    prompt: [*]const u8,
    prompt_len: usize,
    indent: u32,
    level: u32,
    prompt_hl_id: u32,
) callconv(.c) void {
    _ = ctx;
    _ = content;
    _ = content_count;
    _ = pos;
    _ = firstc;
    _ = prompt;
    _ = prompt_len;
    _ = indent;
    _ = level;
    _ = prompt_hl_id;
    // TODO: implement ext_cmdline show
}

pub fn onCmdlineHide(ctx: ?*anyopaque, level: u32) callconv(.c) void {
    _ = ctx;
    _ = level;
    // TODO: implement ext_cmdline hide
}

// =========================================================================
// Popupmenu callbacks (ext_popupmenu)
// =========================================================================

pub fn onPopupmenuShow(
    ctx: ?*anyopaque,
    items: ?*const anyopaque,
    item_count: usize,
    selected: i32,
    row: i32,
    col: i32,
    grid_id: i64,
) callconv(.c) void {
    _ = ctx;
    _ = items;
    _ = item_count;
    _ = selected;
    _ = row;
    _ = col;
    _ = grid_id;
    // TODO: implement ext_popupmenu show
}

pub fn onPopupmenuHide(ctx: ?*anyopaque) callconv(.c) void {
    _ = ctx;
    // TODO: implement ext_popupmenu hide
}

pub fn onPopupmenuSelect(ctx: ?*anyopaque, selected: i32) callconv(.c) void {
    _ = ctx;
    _ = selected;
    // TODO: implement ext_popupmenu select
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
    _ = ctx;
    _ = view;
    _ = kind;
    _ = kind_len;
    _ = chunks;
    _ = chunk_count;
    _ = replace_last;
    _ = history;
    _ = append;
    _ = msg_id;
    _ = timeout_ms;
    // TODO: implement ext_messages show
}

pub fn onMsgClear(ctx: ?*anyopaque) callconv(.c) void {
    _ = ctx;
    // TODO: implement ext_messages clear
}

pub fn onMsgShowmode(
    ctx: ?*anyopaque,
    view: app_mod.zonvie_msg_view_type,
    chunks: [*]const app_mod.MsgChunk,
    chunk_count: usize,
) callconv(.c) void {
    _ = ctx;
    _ = view;
    _ = chunks;
    _ = chunk_count;
    // TODO: implement ext_messages showmode
}

pub fn onMsgShowcmd(
    ctx: ?*anyopaque,
    view: app_mod.zonvie_msg_view_type,
    chunks: [*]const app_mod.MsgChunk,
    chunk_count: usize,
) callconv(.c) void {
    _ = ctx;
    _ = view;
    _ = chunks;
    _ = chunk_count;
    // TODO: implement ext_messages showcmd
}

pub fn onMsgRuler(
    ctx: ?*anyopaque,
    view: app_mod.zonvie_msg_view_type,
    chunks: [*]const app_mod.MsgChunk,
    chunk_count: usize,
) callconv(.c) void {
    _ = ctx;
    _ = view;
    _ = chunks;
    _ = chunk_count;
    // TODO: implement ext_messages ruler
}

pub fn onMsgHistoryShow(
    ctx: ?*anyopaque,
    entries: [*]const app_mod.MsgHistoryEntry,
    entry_count: usize,
    prev_cmd: c_int,
) callconv(.c) void {
    _ = ctx;
    _ = entries;
    _ = entry_count;
    _ = prev_cmd;
    // TODO: implement ext_messages history show
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
    _ = ctx;
    _ = curtab;
    _ = tabs;
    _ = tab_count;
    _ = curbuf;
    _ = buffers;
    _ = buffer_count;
    // TODO: implement ext_tabline update
}

pub fn onTablineHide(ctx: ?*anyopaque) callconv(.c) void {
    _ = ctx;
    // TODO: implement ext_tabline hide
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
    _ = grid_id;
    // TODO: dispatch window destruction to GTK main thread
    _ = app;
}

pub fn onExternalVertices(
    ctx: ?*anyopaque,
    grid_id: i64,
    verts: [*]const app_mod.Vertex,
    vert_count: usize,
    rows: u32,
    cols: u32,
) callconv(.c) void {
    _ = rows;
    _ = cols;
    const app = getApp(ctx) orelse return;

    app.mu.lock();
    defer app.mu.unlock();

    if (app.external_windows.getPtr(grid_id)) |ext| {
        const vs = ext.tbs.writeSet();
        vs.flat_verts.clearRetainingCapacity();
        if (vert_count > 0) {
            vs.flat_verts.appendSlice(app.alloc, verts[0..vert_count]) catch {};
        }
        ext.needs_redraw = true;
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
