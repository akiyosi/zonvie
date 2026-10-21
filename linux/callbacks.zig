//! Core callbacks. They run on the core thread with grid_mu held, so they
//! never call a core API that takes grid_mu, never paint, and reach GTK only
//! through g_idle_add.

const std = @import("std");
const core = @import("zonvie_core");
const clock = core.clock;
const rules = core.frontend_rules;
const App = @import("app.zig").App;
const atlas_pixels = @import("atlas_pixels.zig");
const gtk = @import("gtk_bindings.zig");
const applog = @import("app_log.zig");
const input = @import("input.zig");

pub fn makeCallbacks() core.Callbacks {
    return .{
        .abi_version = core.CALLBACKS_ABI_VERSION,
        .on_vertices_row = onVerticesRow,
        .on_flush_begin = onFlushBegin,
        .on_flush_end = onFlushEnd,
        .on_surface_layout = onSurfaceLayout,
        .on_grid_destroy = onGridDestroy,
        .on_grid_row_scroll = onGridRowScroll,
        .on_atlas_create = onAtlasCreate,
        .on_atlas_upload = onAtlasUpload,
        .on_rasterize_glyph = onRasterizeGlyph,
        .on_rasterize_glyph_by_id = onRasterizeGlyphById,
        .on_shape_text_run = onShapeTextRun,
        .on_get_ascii_table = onGetAsciiTable,
        .on_guifont = onGuiFont,
        .on_linespace = onLineSpace,
        .on_default_colors_set = onDefaultColorsSet,
        .on_set_title = onSetTitle,
        .on_exit = onExit,
        .on_clipboard_get = onClipboardGet,
        .on_clipboard_set = onClipboardSet,
        .on_main_grid_size = onMainGridSize,
        .on_log = onLog,
        .on_callback_error = onCallbackError,
        .on_quit_requested = onQuitRequested,
        .on_ime_off = onImeOff,
    };
}

fn appFrom(ctx: ?*anyopaque) *App {
    return @ptrCast(@alignCast(ctx.?));
}

fn lock(app: *App) void {
    app.mu.lockUncancelable(clock.io());
}

fn unlock(app: *App) void {
    app.mu.unlock(clock.io());
}

/// The flush cannot be accepted; on_flush_end cancels the staged frame.
fn failFlush(app: *App) void {
    app.flush_failed = true;
    core.zonvie_core_abort_flush(app.corep);
}

fn rowsFor(app: *App, grid_id: i64) ?*@import("surface_store.zig").GridRows {
    lock(app);
    defer unlock(app);
    return app.surface.rowsFor(app.alloc, grid_id) catch null;
}

// =========================================================================
// Transactional row / layout callbacks
// =========================================================================

fn onVerticesRow(
    ctx: ?*anyopaque,
    grid_id: i64,
    row_start: u32,
    row_count: u32,
    verts_ptr: ?[*]const core.Vertex,
    vert_count: usize,
    flags: u32,
    total_rows: u32,
    total_cols: u32,
) callconv(.c) void {
    const app = appFrom(ctx);
    const verts: []const core.Vertex = if (verts_ptr) |p| p[0..vert_count] else &.{};
    const update = rules.rowUpdate(flags);
    // A cursor-only send never touches row contents.
    if (update == .cursor_only) {
        app.surface.stageCursor(app.alloc, grid_id, verts) catch failFlush(app);
        return;
    }
    switch (rules.rootRowDisposition(update, row_start, row_count, vert_count, total_rows, total_cols)) {
        .retain_rows => {},
        .multi_row => {
            applog.appLog("[linux] on_vertices_row: multi-row send grid={d} rows={d}\n", .{ grid_id, row_count });
            failFlush(app);
        },
        .layout_only => (rowsFor(app, grid_id) orelse return failFlush(app)).stageClear(),
        .out_of_range, .no_row => (rowsFor(app, grid_id) orelse return failFlush(app)).staged_len = total_rows,
        .single_row => {
            const rows = rowsFor(app, grid_id) orelse return failFlush(app);
            rows.stageRow(app.alloc, row_start, verts, total_rows) catch failFlush(app);
        },
    }
}

fn onGridRowScroll(
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
    _ = total_rows;
    const app = appFrom(ctx);
    if (rows_delta == 0 or row_end <= row_start) return;
    // Rows are stored full-width; a partial-width shift cannot be applied
    // (zonvie_core.h on_grid_row_scroll), so ask for the full resend.
    if (col_start != 0 or col_end != total_cols) {
        core.zonvie_core_force_resend_locked(app.corep);
        failFlush(app);
        return;
    }
    const rows = rowsFor(app, grid_id) orelse return failFlush(app);
    rows.stageShift(row_start, row_end, rows_delta);
}

fn onSurfaceLayout(
    ctx: ?*anyopaque,
    surface_id: i64,
    layers: [*]const core.Layer,
    count: usize,
    surface_rows: u32,
    surface_cols: u32,
) callconv(.c) void {
    const app = appFrom(ctx);
    // ext_windows stays off in M1, so only the main surface exists. A force
    // resend here would loop, since no surface will ever register.
    if (surface_id != 1) {
        if (!app.foreign_surface_logged) {
            applog.appLog("[linux] on_surface_layout: ignoring surface {d}\n", .{surface_id});
            app.foreign_surface_logged = true;
        }
        return;
    }
    app.surface.stageLayers(app.alloc, layers[0..count], surface_rows, surface_cols) catch failFlush(app);
}

fn onGridDestroy(ctx: ?*anyopaque, grid_id: i64) callconv(.c) void {
    const app = appFrom(ctx);
    app.surface.stageDestroy(app.alloc, grid_id) catch failFlush(app);
}

fn onFlushBegin(ctx: ?*anyopaque) callconv(.c) void {
    appFrom(ctx).flush_failed = false;
}

fn onFlushEnd(ctx: ?*anyopaque) callconv(.c) void {
    const app = appFrom(ctx);
    const cp = app.corep;
    const failed = app.flush_failed or
        core.zonvie_core_flush_had_atlas_corruption(cp) or
        core.zonvie_core_flush_was_aborted(cp);
    app.flush_failed = false;
    {
        lock(app);
        defer unlock(app);
        // atlas_pending is left alone either way: uploads that returned are
        // cached by the core, whatever happens to the rows.
        if (failed) {
            app.surface.cancel();
            if (core.zonvie_core_flush_is_retryable(cp)) core.zonvie_core_force_resend_locked(cp);
        } else if (app.surface.prepareCommit(app.alloc)) |_| {
            app.surface.commit(app.alloc);
        } else |_| {
            app.surface.cancel();
            core.zonvie_core_abort_flush(cp);
        }
    }
    queueRender(app);
}

/// Callable from any thread; at most one idle is outstanding.
pub fn queueRender(app: *App) void {
    if (app.render_idle_queued.swap(true, .acq_rel)) return;
    _ = gtk.g_idle_add(&idleQueueRender, app);
}

fn idleQueueRender(data: ?*anyopaque) callconv(.c) c_int {
    const app = appFrom(data);
    app.render_idle_queued.store(false, .release);
    if (app.gl_area) |area| gtk.gtk_gl_area_queue_render(area);
    input.updateImeCursor(app);
    return 0;
}

// =========================================================================
// Atlas, rasterization and shaping
// =========================================================================

fn onAtlasCreate(ctx: ?*anyopaque, atlas_w: u32, atlas_h: u32) callconv(.c) void {
    const app = appFrom(ctx);
    lock(app);
    defer unlock(app);
    // The new texture starts zeroed; anything queued for the old one is moot.
    const ops = &app.atlas_pending;
    ops.clearQueued();
    // Allocates only on create; the texture is recreated from this mirror.
    ops.mirror.resize(app.alloc, @as(usize, atlas_w) * atlas_h * 4) catch {
        ops.mirror.clearRetainingCapacity();
        ops.w = 0;
        ops.h = 0;
        return core.zonvie_core_abort_flush(app.corep);
    };
    @memset(ops.mirror.items, 0);
    ops.recreate = true;
    ops.w = atlas_w;
    ops.h = atlas_h;
}

fn onAtlasUpload(ctx: ?*anyopaque, dest_x: u32, dest_y: u32, width: u32, height: u32, bitmap: *const core.GlyphBitmap) callconv(.c) void {
    const app = appFrom(ctx);
    if (width == 0 or height == 0) return;
    // An upload that does not land must abort inside this callback so the
    // core does not cache the glyph (zonvie_core.h on_atlas_upload).
    if (bitmap.pixels == null or bitmap.width != width or bitmap.height != height) return core.zonvie_core_abort_flush(app.corep);
    lock(app);
    defer unlock(app);
    const ops = &app.atlas_pending;
    if (@as(u64, dest_x) + width > ops.w or @as(u64, dest_y) + height > ops.h) return core.zonvie_core_abort_flush(app.corep);
    const offset = ops.pixels.items.len;
    const len = @as(usize, width) * height * 4;
    ops.uploads.ensureUnusedCapacity(app.alloc, 1) catch return core.zonvie_core_abort_flush(app.corep);
    ops.pixels.resize(app.alloc, offset + len) catch return core.zonvie_core_abort_flush(app.corep);
    const src = ops.pixels.items[offset..][0..len];
    atlas_pixels.toRgba8(bitmap, src);
    const row_bytes = @as(usize, width) * 4;
    const stride = @as(usize, ops.w) * 4;
    var r: usize = 0;
    while (r < height) : (r += 1) {
        const dst_off = (@as(usize, dest_y) + r) * stride + @as(usize, dest_x) * 4;
        @memcpy(ops.mirror.items[dst_off..][0..row_bytes], src[r * row_bytes ..][0..row_bytes]);
    }
    ops.uploads.appendAssumeCapacity(.{ .x = dest_x, .y = dest_y, .w = width, .h = height, .offset = offset });
}

fn onRasterizeGlyph(ctx: ?*anyopaque, scalar: u32, style_flags: u32, out_bitmap: *core.GlyphBitmap) callconv(.c) c_int {
    const app = appFrom(ctx);
    ensureFont(app);
    return @intFromBool(app.fonts.rasterizeScalar(scalar, style_flags, out_bitmap));
}

fn onRasterizeGlyphById(ctx: ?*anyopaque, glyph_id: u32, style_flags: u32, out_bitmap: *core.GlyphBitmap) callconv(.c) c_int {
    const app = appFrom(ctx);
    ensureFont(app);
    return @intFromBool(app.fonts.rasterizeGlyphId(glyph_id, style_flags, out_bitmap));
}

fn onShapeTextRun(
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
    const app = appFrom(ctx);
    ensureFont(app);
    return app.fonts.shape(app.alloc, scalars, scalar_count, style_flags, out_glyph_ids, out_clusters, out_x_advance, out_x_offset, out_y_offset, out_cap);
}

fn onGetAsciiTable(ctx: ?*anyopaque, style_flags: u32, out_glyph_ids: [*]u32, out_x_advances: [*]i32, out_lig_triggers: [*]u8) callconv(.c) c_int {
    const app = appFrom(ctx);
    ensureFont(app);
    return @intFromBool(app.fonts.asciiTable(style_flags, out_glyph_ids, out_x_advances, out_lig_triggers));
}

// =========================================================================
// Font and metrics
// =========================================================================

const default_family = "monospace";
const default_pt: f32 = 12.0;

fn pixelSize(app: *App, pt: f32) u32 {
    lock(app);
    const scale = app.scale;
    unlock(app);
    // GTK's logical 96 dpi, times the surface scale.
    return @intFromFloat(@max(1.0, @round(pt * 96.0 / 72.0 * scale)));
}

/// Loads `monospace 12` when no guifont has been applied yet. Core thread,
/// or any thread before zonvie_core_start.
pub fn ensureFont(app: *App) void {
    if (app.fonts.regular != null) return;
    _ = app.fonts.load(app.alloc, default_family, pixelSize(app, default_pt));
    updateMetrics(app);
}

/// Publishes the font cell plus linespace.
fn updateMetrics(app: *App) void {
    const h: i32 = @as(i32, @intCast(app.fonts.cell_h_px)) + app.linespace_px;
    lock(app);
    app.cell_w_px = app.fonts.cell_w_px;
    app.cell_h_px = @intCast(@max(1, h));
    unlock(app);
}

fn sendLayout(app: *App) void {
    lock(app);
    const w = app.drawable_w_px;
    const h = app.drawable_h_px;
    const cw = app.cell_w_px;
    const ch = app.cell_h_px;
    unlock(app);
    if (w == 0 or h == 0 or cw == 0) return;
    // On the redraw thread the core applies this without taking grid_mu.
    core.zonvie_core_update_layout_px(app.corep, w, h, cw, ch);
}

fn onGuiFont(ctx: ?*anyopaque, bytes: [*]const u8, len: usize) callconv(.c) void {
    const app = appFrom(ctx);
    var loaded = false;
    var it = std.mem.splitScalar(u8, bytes[0..len], '\n');
    while (it.next()) |line| {
        const cand = core.config.parseFontCandidateLine(line, default_pt, false) orelse continue;
        if (app.fonts.load(app.alloc, cand.name, pixelSize(app, cand.point_size))) {
            applog.appLog("[linux] guifont: {s} {d}pt\n", .{ cand.name, cand.point_size });
            loaded = true;
            break;
        }
    }
    if (!loaded) {
        if (app.fonts.regular != null) return;
        if (!app.fonts.load(app.alloc, default_family, pixelSize(app, default_pt))) return;
    }
    updateMetrics(app);
    if (app.corep) |cp| core.zonvie_core_invalidate_glyph_cache(cp);
    sendLayout(app);
}

fn onLineSpace(ctx: ?*anyopaque, linespace_px: i32) callconv(.c) void {
    const app = appFrom(ctx);
    app.linespace_px = linespace_px;
    updateMetrics(app);
    sendLayout(app);
}

// =========================================================================
// Notifications
// =========================================================================

fn onDefaultColorsSet(ctx: ?*anyopaque, fg: u32, bg: u32) callconv(.c) void {
    const app = appFrom(ctx);
    lock(app);
    app.default_fg = fg;
    app.default_bg = bg;
    unlock(app);
}

fn onSetTitle(ctx: ?*anyopaque, title: [*]const u8, title_len: usize) callconv(.c) void {
    const app = appFrom(ctx);
    lock(app);
    app.title_len = rules.copyUtf8Truncated(app.title[0 .. app.title.len - 1], title[0..title_len]);
    unlock(app);
    _ = gtk.g_idle_add(&idleSetTitle, app);
}

fn idleSetTitle(data: ?*anyopaque) callconv(.c) c_int {
    const app = appFrom(data);
    const window = app.window orelse return 0;
    var buf: [256]u8 = undefined;
    lock(app);
    @memcpy(buf[0..app.title_len], app.title[0..app.title_len]);
    buf[app.title_len] = 0;
    unlock(app);
    gtk.gtk_window_set_title(window, @ptrCast(&buf));
    return 0;
}

fn onExit(ctx: ?*anyopaque, exit_code: i32) callconv(.c) void {
    const app = appFrom(ctx);
    lock(app);
    app.exit_code = exit_code;
    unlock(app);
    _ = gtk.g_idle_add(&idleQuit, app);
}

fn idleQuit(data: ?*anyopaque) callconv(.c) c_int {
    if (appFrom(data).gtk_app) |a| gtk.g_application_quit(a);
    return 0;
}

fn onQuitRequested(ctx: ?*anyopaque, has_unsaved: c_int) callconv(.c) void {
    const app = appFrom(ctx);
    app.quit_has_unsaved.store(has_unsaved != 0, .release);
    _ = gtk.g_idle_add(&idleQuitRequested, app);
}

fn idleQuitRequested(data: ?*anyopaque) callconv(.c) c_int {
    const app = appFrom(data);
    const cp = app.corep orelse return 0;
    if (!app.quit_has_unsaved.load(.acquire)) {
        core.zonvie_core_quit_confirmed(cp, 0);
        return 0;
    }
    const dialog = gtk.gtk_alert_dialog_new("%s", "Quit with unsaved changes?") orelse return 0;
    gtk.gtk_alert_dialog_set_detail(dialog, "Some buffers have unsaved changes. They will be lost.");
    const labels = [_:null]?[*:0]const u8{ "Cancel", "Discard and Quit" };
    gtk.gtk_alert_dialog_set_buttons(dialog, &labels);
    gtk.gtk_alert_dialog_set_cancel_button(dialog, 0);
    gtk.gtk_alert_dialog_set_default_button(dialog, 0);
    gtk.gtk_alert_dialog_choose(dialog, app.window, null, &onQuitDialogDone, app);
    return 0;
}

fn onQuitDialogDone(source: ?*anyopaque, result: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const app = appFrom(data);
    var err: ?*anyopaque = null;
    const choice = gtk.gtk_alert_dialog_choose_finish(source.?, result, &err);
    if (err) |e| gtk.g_error_free(e);
    gtk.g_object_unref(source.?);
    if (choice != 1) return;
    if (app.corep) |cp| core.zonvie_core_quit_confirmed(cp, 1);
}

fn onImeOff(ctx: ?*anyopaque) callconv(.c) void {
    _ = gtk.g_idle_add(&idleImeOff, appFrom(ctx));
}

fn idleImeOff(data: ?*anyopaque) callconv(.c) c_int {
    if (appFrom(data).im_context) |im| gtk.gtk_im_context_reset(im);
    return 0;
}

fn onMainGridSize(ctx: ?*anyopaque, rows: u32, cols: u32) callconv(.c) void {
    const app = appFrom(ctx);
    lock(app);
    app.requested_rows = rows;
    app.requested_cols = cols;
    unlock(app);
    _ = gtk.g_idle_add(&idleResizeToGrid, app);
}

/// Sizes the window so the GLArea holds the requested cells; the GLArea
/// resize that follows reports the layout to the core.
fn idleResizeToGrid(data: ?*anyopaque) callconv(.c) c_int {
    const app = appFrom(data);
    const window = app.window orelse return 0;
    const area = app.gl_area orelse return 0;
    lock(app);
    const rows = app.requested_rows;
    const cols = app.requested_cols;
    const cw = app.cell_w_px;
    const ch = app.cell_h_px;
    const scale = app.scale;
    unlock(app);
    if (rows == 0 or cols == 0 or cw == 0 or ch == 0) return 0;
    // Window chrome (a CSD titlebar) is the window/area size difference.
    const chrome_w = @max(0, gtk.gtk_widget_get_width(window) - gtk.gtk_widget_get_width(area));
    const chrome_h = @max(0, gtk.gtk_widget_get_height(window) - gtk.gtk_widget_get_height(area));
    const w_logical: c_int = @intFromFloat(@ceil(@as(f32, @floatFromInt(cols * cw)) / scale));
    const h_logical: c_int = @intFromFloat(@ceil(@as(f32, @floatFromInt(rows * ch)) / scale));
    gtk.gtk_window_set_default_size(window, w_logical + chrome_w, h_logical + chrome_h);
    return 0;
}

fn onLog(ctx: ?*anyopaque, p: [*]const u8, n: usize) callconv(.c) void {
    _ = ctx;
    applog.appLogBytes("[core] ", p[0..n]);
}

fn onCallbackError(ctx: ?*anyopaque, code: u32, component: [*]const u8, component_len: usize) callconv(.c) void {
    _ = ctx;
    applog.appLog("[linux] callback error code={d} component={s}\n", .{ code, component[0..component_len] });
}

// =========================================================================
// Clipboard: the core thread blocks (bounded) while GTK does the work.
// =========================================================================

const ClipboardTask = struct {
    app: *App,
    seq: u64,
    /// Owned NUL-terminated text for a set; empty for a get.
    buf: []u8,
};

fn beginClipboardOp(app: *App) u64 {
    app.clipboard_mu.lockUncancelable(clock.io());
    defer app.clipboard_mu.unlock(clock.io());
    app.clipboard_ready = false;
    app.clipboard_text.clearRetainingCapacity();
    app.clipboard_result = 0;
    app.clipboard_seq +%= 1;
    return app.clipboard_seq;
}

/// Called and returns with clipboard_mu held. std.Io.Condition has no timed
/// wait, so this polls for up to 5 s, releasing the mutex while sleeping.
/// On timeout it bumps the seq so a late GTK completion is ignored.
fn waitClipboardReadyLocked(app: *App) bool {
    const io = clock.io();
    const deadline_ns = clock.nowNs() + 5 * std.time.ns_per_s;
    while (!app.clipboard_ready and clock.nowNs() < deadline_ns) {
        app.clipboard_mu.unlock(io);
        std.Io.sleep(io, .{ .nanoseconds = std.time.ns_per_ms }, .awake) catch {};
        app.clipboard_mu.lockUncancelable(io);
    }
    if (!app.clipboard_ready) app.clipboard_seq +%= 1;
    return app.clipboard_ready;
}

/// Signals the waiter only if `seq` is still its operation. `text` (a get's
/// result) is copied into clipboard_text under the lock.
fn signalClipboardDone(app: *App, seq: u64, result: c_int, text: []const u8) void {
    app.clipboard_mu.lockUncancelable(clock.io());
    defer app.clipboard_mu.unlock(clock.io());
    if (app.clipboard_seq != seq) return;
    app.clipboard_text.clearRetainingCapacity();
    app.clipboard_result = result;
    app.clipboard_text.appendSlice(app.alloc, text) catch {
        app.clipboard_text.clearRetainingCapacity();
        app.clipboard_result = 0;
    };
    app.clipboard_ready = true;
}

/// Releases a core thread waiting on the clipboard with an empty failure,
/// as its timeout would; the bumped seq makes the pending task stale.
pub fn abandonClipboardWait(app: *App) void {
    app.clipboard_mu.lockUncancelable(clock.io());
    defer app.clipboard_mu.unlock(clock.io());
    app.clipboard_seq +%= 1;
    app.clipboard_text.clearRetainingCapacity();
    app.clipboard_result = 0;
    app.clipboard_ready = true;
}

fn isStale(task: *ClipboardTask) bool {
    task.app.clipboard_mu.lockUncancelable(clock.io());
    defer task.app.clipboard_mu.unlock(clock.io());
    return task.app.clipboard_seq != task.seq;
}

fn freeTask(task: *ClipboardTask) void {
    const alloc = task.app.alloc;
    alloc.free(task.buf);
    alloc.destroy(task);
}

fn defaultClipboard() ?*anyopaque {
    const display = gtk.gdk_display_get_default() orelse return null;
    return gtk.gdk_display_get_clipboard(display);
}

fn onClipboardGet(ctx: ?*anyopaque, register: [*]const u8, out_buf: [*]u8, out_len: *usize, max_len: usize) callconv(.c) c_int {
    _ = register;
    const app = appFrom(ctx);
    out_len.* = 0;
    const seq = beginClipboardOp(app);
    const task = app.alloc.create(ClipboardTask) catch return 0;
    task.* = .{ .app = app, .seq = seq, .buf = &.{} };
    _ = gtk.g_idle_add(&idleClipboardGet, task);

    app.clipboard_mu.lockUncancelable(clock.io());
    defer app.clipboard_mu.unlock(clock.io());
    if (!waitClipboardReadyLocked(app)) {
        applog.appLog("[linux] clipboard_get: timeout\n", .{});
        return 0;
    }
    const text = app.clipboard_text.items;
    const n = @min(text.len, max_len);
    if (n > 0) @memcpy(out_buf[0..n], text[0..n]);
    // The full size, so the core can detect truncation and retry.
    out_len.* = text.len;
    return app.clipboard_result;
}

fn idleClipboardGet(data: ?*anyopaque) callconv(.c) c_int {
    const task: *ClipboardTask = @ptrCast(@alignCast(data.?));
    if (isStale(task)) {
        freeTask(task);
        return 0;
    }
    const clipboard = defaultClipboard() orelse {
        signalClipboardDone(task.app, task.seq, 0, "");
        freeTask(task);
        return 0;
    };
    gtk.gdk_clipboard_read_text_async(clipboard, null, &onClipboardReadFinish, task);
    return 0;
}

fn onClipboardReadFinish(source: ?*anyopaque, result: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const task: *ClipboardTask = @ptrCast(@alignCast(data.?));
    defer freeTask(task);
    var err: ?*anyopaque = null;
    const text = gtk.gdk_clipboard_read_text_finish(source.?, result, &err);
    if (err) |e| gtk.g_error_free(e);
    const t = text orelse return signalClipboardDone(task.app, task.seq, 0, "");
    defer gtk.g_free(t);
    signalClipboardDone(task.app, task.seq, 1, std.mem.span(t));
}

fn onClipboardSet(ctx: ?*anyopaque, register: [*]const u8, data: [*]const u8, len: usize) callconv(.c) c_int {
    _ = register;
    const app = appFrom(ctx);
    if (len == 0) return 1;
    // The idle owns its copy, so a later set cannot overwrite text GDK is
    // still reading.
    const buf = app.alloc.alloc(u8, len + 1) catch return 0;
    @memcpy(buf[0..len], data[0..len]);
    buf[len] = 0;
    const task = app.alloc.create(ClipboardTask) catch {
        app.alloc.free(buf);
        return 0;
    };
    task.* = .{ .app = app, .seq = beginClipboardOp(app), .buf = buf };
    _ = gtk.g_idle_add(&idleClipboardSet, task);

    app.clipboard_mu.lockUncancelable(clock.io());
    defer app.clipboard_mu.unlock(clock.io());
    if (!waitClipboardReadyLocked(app)) {
        applog.appLog("[linux] clipboard_set: timeout\n", .{});
        return 0;
    }
    return app.clipboard_result;
}

fn idleClipboardSet(data: ?*anyopaque) callconv(.c) c_int {
    const task: *ClipboardTask = @ptrCast(@alignCast(data.?));
    defer freeTask(task);
    const app = task.app;
    {
        // A stale task belongs to a caller that already gave up.
        app.clipboard_mu.lockUncancelable(clock.io());
        defer app.clipboard_mu.unlock(clock.io());
        if (app.clipboard_seq != task.seq) return 0;
    }
    const clipboard = defaultClipboard() orelse {
        signalClipboardDone(app, task.seq, 0, "");
        return 0;
    };
    gtk.gdk_clipboard_set_text(clipboard, @ptrCast(task.buf.ptr));
    signalClipboardDone(app, task.seq, 1, "");
    return 0;
}
