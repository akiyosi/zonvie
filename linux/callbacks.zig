//! Core callbacks. They run with grid_mu held, on the core thread or, for a
//! flush a core_timers tick runs, on the main thread; so they never call a
//! core API that takes grid_mu, never paint, and reach the window only
//! through g_idle_add.

const std = @import("std");
const core = @import("zonvie_core");
const clock = core.clock;
const rules = core.frontend_rules;
const App = @import("app.zig").App;
const atlas_pixels = @import("atlas_pixels.zig");
const glib = @import("glib.zig");
const ui = @import("ui.zig");
const applog = @import("app_log.zig");
const input = @import("ui.zig").input;
const overlay_layout = @import("overlay_layout.zig");
const ui_widgets = @import("ui.zig").ui_widgets;
const ext_window = @import("ui.zig").ext_window;
const panel_popup = @import("ui.zig").panel_popup;
const blink = @import("ui.zig").blink;
const scrollbar = @import("scrollbar.zig");
const core_timers = @import("core_timers.zig");
const font_picker = @import("ui.zig").font_picker;
const window_size = @import("ui.zig").window_size;
const ime_off = @import("ui.zig").ime_off;
const font_mod = @import("renderer/font.zig");
const Fonts = font_mod.Fonts;
const font_spec = @import("font_spec.zig");
const layer_geom = @import("layer_geom.zig");
const session = @import("ui.zig").session;

pub fn makeCallbacks() core.Callbacks {
    return .{
        .abi_version = core.CALLBACKS_ABI_VERSION,
        .on_vertices_row = onVerticesRow,
        .on_flush_begin = onFlushBegin,
        .on_flush_end = onFlushEnd,
        .on_surface_layout = onSurfaceLayout,
        .on_grid_destroy = onGridDestroy,
        .on_grid_row_scroll = onGridRowScroll,
        .on_external_window = onExternalWindow,
        .on_external_window_close = onExternalWindowClose,
        .on_popupmenu_show = onPopupmenuShow,
        .on_cmdline_show = onCmdlineShow,
        .on_msg_show = onMsgShow,
        .on_msg_clear = onMsgClear,
        .on_msg_showmode = onMsgShowmode,
        .on_msg_showcmd = onMsgShowcmd,
        .on_msg_ruler = onMsgRuler,
        .on_tabline_update = onTablineUpdate,
        .on_tabline_hide = onTablineHide,
        .on_agent_status = onAgentStatus,
        .on_cell_age_stamps = onCellAgeStamps,
        .on_atlas_create = onAtlasCreate,
        .on_atlas_upload = onAtlasUpload,
        .on_rasterize_glyph = onRasterizeGlyph,
        .on_rasterize_glyph_by_id = onRasterizeGlyphById,
        .on_shape_text_run = onShapeTextRun,
        .on_get_ascii_table = onGetAsciiTable,
        .on_font_slot_load = onFontSlotLoad,
        .on_font_slot_release = onFontSlotRelease,
        .on_grid_font = onGridFont,
        .on_shape_text_run_ex = onShapeTextRunEx,
        .on_rasterize_glyph_ex = onRasterizeGlyphEx,
        .on_rasterize_glyph_by_id_ex = onRasterizeGlyphByIdEx,
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
        .on_restart = onRestart,
        .on_connect = onConnect,
    };
}

/// One structured render-trace line, stamped with the flush it belongs to
/// (windows/callbacks.zig traceRender). Core thread.
fn traceRender(app: *App, comptime fmt: []const u8, args: anytype) void {
    if (!applog.isVerbose()) return;
    applog.appLog("[render_trace] side=linux flush={d} " ++ fmt, .{app.trace_flush} ++ args);
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
/// A callback the core sends outside a flush (a session reset's closes) has
/// no flush to abort and nothing that retries it: its failure is logged.
fn failFlush(app: *App) void {
    if (!app.in_flush) return applog.appLog("[linux] a callback outside a flush failed and is not retried\n", .{});
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
    rows.stageShift(row_start, row_end, rows_delta, total_rows, core.zonvie_core_grid_view_moved_locked(app.corep, grid_id));
}

fn onSurfaceLayout(
    ctx: ?*anyopaque,
    surface_id: i64,
    layers: [*]const core.Layer,
    count: usize,
    surface_rows: u32,
    surface_cols: u32,
) callconv(.c) void {
    _ = surface_rows;
    _ = surface_cols;
    const app = appFrom(ctx);
    traceRender(app, "event=layout_stage surface={d} layers={d}\n", .{ surface_id, count });
    lock(app);
    defer unlock(app);
    app.surface.stageLayers(app.alloc, surface_id, layers[0..count]) catch failFlush(app);
}

/// Immediate (zonvie_core.h): applied now and kept if the flush is refused.
/// A repeat for an open surface updates its size and anchor.
fn onExternalWindow(ctx: ?*anyopaque, grid_id: i64, win: i64, rows: u32, cols: u32, start_row: i32, start_col: i32) callconv(.c) void {
    const app = appFrom(ctx);
    applog.appLog("[linux] external window open grid={d} win={d} {d}x{d} at ({d},{d})\n", .{ grid_id, win, rows, cols, start_row, start_col });
    {
        lock(app);
        defer unlock(app);
        // Not recorded by the core when the flush aborts: the retry opens it.
        app.surface.openSurface(app.alloc, grid_id) catch return failFlush(app);
        if (overlay_layout.kindOf(grid_id)) |kind| {
            app.overlays[@intFromEnum(kind)] = .{ .open = true, .win = win, .rows = rows, .cols = cols, .start_row = start_row, .start_col = start_col };
            return;
        }
        // An ext_windows grid: a window of its own, opened on the main thread.
        app.ext_ops.append(app.alloc, .{ .kind = .open, .grid_id = grid_id, .win = win, .rows = rows, .cols = cols, .start_row = start_row, .start_col = start_col }) catch return failFlush(app);
    }
    ext_window.queueApply(app);
}

fn onExternalWindowClose(ctx: ?*anyopaque, grid_id: i64) callconv(.c) void {
    const app = appFrom(ctx);
    applog.appLog("[linux] external window close grid={d}\n", .{grid_id});
    {
        lock(app);
        defer unlock(app);
        if (overlay_layout.kindOf(grid_id)) |kind| {
            app.overlays[@intFromEnum(kind)] = .{};
            // msg_show is pinned only until it closes; the next one starts
            // at its anchor with no pointer on it.
            if (kind == .msg_show) {
                app.msg_chrome.reset();
                app.msg_show_user = null;
            }
        } else {
            // Reserved before closing, so a refused close leaves the surface
            // open for the retry to close again.
            app.ext_ops.ensureUnusedCapacity(app.alloc, 1) catch return failFlush(app);
            app.ext_ops.appendAssumeCapacity(.{ .kind = .close, .grid_id = grid_id });
        }
        app.surface.closeSurface(app.alloc, grid_id);
    }
    ext_window.queueApply(app);
    queueRender(app);
}

fn onPopupmenuShow(
    ctx: ?*anyopaque,
    items: ?*const anyopaque,
    item_count: usize,
    selected: i32,
    row: i32,
    col: i32,
    grid_id: i64,
    colors: ?*const core.PopupmenuColors,
) callconv(.c) void {
    _ = items;
    _ = item_count;
    _ = selected;
    _ = row;
    _ = col;
    _ = grid_id;
    // The core draws the items on its own grid; only the fill is ours.
    const c = colors orelse return;
    const app = appFrom(ctx);
    lock(app);
    defer unlock(app);
    app.pmenu_bg = c.pmenu_bg;
}

fn onCmdlineShow(
    ctx: ?*anyopaque,
    _: [*]const core.CmdlineChunk,
    _: usize,
    _: u32,
    firstc: u8,
    _: [*]const u8,
    _: usize,
    _: u32,
    _: u32,
    _: u32,
) callconv(.c) void {
    const app = appFrom(ctx);
    lock(app);
    app.cmdline_firstc = firstc;
    unlock(app);
    queuePanelColors(app);
}

/// Any thread; at most one idle is outstanding.
fn queuePanelColors(app: *App) void {
    if (!app.panel_colors_queued.swap(true, .acq_rel)) _ = glib.g_idle_add(&idlePanelColors, app);
}

/// main thread: the highlight lookups take grid_mu, which the core holds
/// around every callback.
fn idlePanelColors(data: ?*anyopaque) callconv(.c) c_int {
    const app: *App = @ptrCast(@alignCast(data.?));
    app.panel_colors_queued.store(false, .release);
    const cp = app.corep orelse return 0;
    const names = [_]?[*:0]const u8{ "Search", "Comment" };
    var fg: [2]u32 = undefined;
    var bg: [2]u32 = undefined;
    var found: [2]c_int = undefined;
    _ = core.zonvie_core_get_hl_by_names_batch(cp, &names, &fg, &bg, &found, names.len);
    lock(app);
    app.cmdline_border_rgb = if (found[0] != 0) bg[0] else 0xffff00;
    app.cmdline_icon_rgb = if (found[1] != 0) fg[1] else 0x808080;
    unlock(app);
    app.queueRenderAll();
    return 0;
}

// The frontend-drawn ext UI (ui_state.zig). Immediate callbacks: state is
// written under App.mu and the main thread is asked to refresh.

fn onMsgShow(
    ctx: ?*anyopaque,
    view: core.zonvie_msg_view_type,
    kind: [*]const u8,
    kind_len: usize,
    chunks: [*]const core.MsgChunk,
    chunk_count: usize,
    replace_last: c_int,
    history: c_int,
    append: c_int,
    msg_id: i64,
    timeout_ms: u32,
) callconv(.c) void {
    _ = history;
    _ = msg_id;
    const app = appFrom(ctx);
    lock(app);
    app.ui.msgShow(view, kind[0..kind_len], chunks[0..chunk_count], replace_last != 0, append != 0, timeout_ms);
    unlock(app);
    ui_widgets.queueRefresh(app);
}

fn onMsgClear(ctx: ?*anyopaque) callconv(.c) void {
    const app = appFrom(ctx);
    lock(app);
    app.ui.msgClear();
    unlock(app);
    ui_widgets.queueRefresh(app);
}

fn msgStatus(ctx: ?*anyopaque, which: @import("ui_state.zig").Mini, view: core.zonvie_msg_view_type, chunks: [*]const core.MsgChunk, chunk_count: usize) void {
    const app = appFrom(ctx);
    lock(app);
    app.ui.status(which, view, chunks[0..chunk_count]);
    unlock(app);
    ui_widgets.queueRefresh(app);
}

fn onMsgShowmode(ctx: ?*anyopaque, view: core.zonvie_msg_view_type, chunks: [*]const core.MsgChunk, chunk_count: usize) callconv(.c) void {
    msgStatus(ctx, .showmode, view, chunks, chunk_count);
}

fn onMsgShowcmd(ctx: ?*anyopaque, view: core.zonvie_msg_view_type, chunks: [*]const core.MsgChunk, chunk_count: usize) callconv(.c) void {
    msgStatus(ctx, .showcmd, view, chunks, chunk_count);
}

fn onMsgRuler(ctx: ?*anyopaque, view: core.zonvie_msg_view_type, chunks: [*]const core.MsgChunk, chunk_count: usize) callconv(.c) void {
    msgStatus(ctx, .ruler, view, chunks, chunk_count);
}

fn onTablineUpdate(
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
    const app = appFrom(ctx);
    lock(app);
    app.ui.tabline(curtab, tabs[0..tab_count]);
    unlock(app);
    ui_widgets.queueRefresh(app);
}

/// Cells the core stamped as just edited, for iCellAge: into the CPU mirror,
/// which each window's next shaded draw uploads. Core thread, grid_mu held.
fn onCellAgeStamps(ctx: ?*anyopaque, stamps: ?[*]const core.zonvie_cell_stamp, n: usize, clear: c_int) callconv(.c) void {
    const app = appFrom(ctx);
    const now: f32 = @floatCast(@as(f64, @floatFromInt(clock.nowNs() - app.shader_epoch_ns)) / std.time.ns_per_s);
    const slice: []const core.zonvie_cell_stamp = if (stamps != null and n > 0) stamps.?[0..n] else &.{};
    app.cell_age.apply(slice, clear != 0, now);
}

/// Not coupled to a flush: a background tab's agent still updates.
fn onAgentStatus(ctx: ?*anyopaque, tab_handle: i64, state: u8, title: [*c]const u8, title_len: usize) callconv(.c) void {
    const app = appFrom(ctx);
    const t: []const u8 = if (title != null) title[0..title_len] else "";
    lock(app);
    app.ui.agentStatus(tab_handle, state, t, app.tabline_cfg.agent_notification);
    unlock(app);
    ui_widgets.queueRefresh(app);
}

fn onTablineHide(ctx: ?*anyopaque) callconv(.c) void {
    const app = appFrom(ctx);
    lock(app);
    app.ui.tabline_visible = false;
    unlock(app);
    ui_widgets.queueRefresh(app);
}

fn onGridDestroy(ctx: ?*anyopaque, grid_id: i64) callconv(.c) void {
    const app = appFrom(ctx);
    {
        lock(app);
        defer unlock(app);
        app.surface.dropGridFont(grid_id);
    }
    if (!app.in_flush) {
        // A session teardown (SurfaceStore.destroyNow), not a flush's.
        traceRender(app, "event=destroy_now grid={d}\n", .{grid_id});
        lock(app);
        app.surface.destroyNow(app.alloc, grid_id);
        unlock(app);
        queueRender(app);
        return;
    }
    traceRender(app, "event=destroy_stage grid={d}\n", .{grid_id});
    app.surface.stageDestroy(app.alloc, grid_id) catch failFlush(app);
}

fn onFlushBegin(ctx: ?*anyopaque) callconv(.c) void {
    const app = appFrom(ctx);
    app.flush_failed = false;
    app.in_flush = true;
    app.trace_flush += 1;
    traceRender(app, "event=begin\n", .{});
}

fn onFlushEnd(ctx: ?*anyopaque) callconv(.c) void {
    const app = appFrom(ctx);
    app.in_flush = false;
    const cp = app.corep;
    const failed = app.flush_failed or
        core.zonvie_core_flush_had_atlas_corruption(cp) or
        core.zonvie_core_flush_was_aborted(cp);
    app.flush_failed = false;
    var committed = false;
    defer traceRender(app, "event=end outcome={s}\n", .{if (committed) "commit" else "abort"});
    // The anchor this flush published (before on_flush_end), taken before
    // App.mu: the core's anchor lock is a leaf, never held under App.mu.
    var anchor: core.MsgAnchor = undefined;
    const have_anchor = !failed and core.zonvie_core_msg_anchor(cp, &anchor);
    {
        lock(app);
        defer unlock(app);
        // atlas_pending's uploads are left alone either way: those that
        // returned are cached by the core, whatever happens to the rows.
        if (failed) {
            app.surface.cancel();
            // An abort causes no further flush by itself; core_timers
            // retries it. A fixed resource limit would only fail again.
            if (core.zonvie_core_flush_is_retryable(cp)) {
                core.zonvie_core_force_resend_locked(cp);
                app.flush_outcome.store(.aborted, .release);
            }
        } else if (app.surface.prepareCommit(app.alloc)) |_| {
            // With the rows it places messages against, so a frame drawn
            // from this commit has both.
            app.msg_anchor = if (have_anchor) anchor else null;
            // The grids this commit frees, released with it.
            for (app.surface.destroyed.items) |id| traceRender(app, "event=destroy_release grid={d}\n", .{id});
            app.surface.commit(app.alloc, .{
                .now_ns = @intCast(clock.nowNs()),
                .row_h_px = app.cell_h_px,
                // Lock-free: an atomic the core's reporter keeps current.
                .mousescroll_ver = @intCast(@min(core.zonvie_core_get_mousescroll_ver(cp), 32)),
                .large_jump = app.large_jump,
            });
            scrollbar.commitViews(app);
            // The committed rows are the new atlas's from here on.
            app.atlas_pending.held = false;
            committed = true;
            app.flush_outcome.store(.committed, .release);
            if (app.panel_colors_stale) {
                app.panel_colors_stale = false;
                queuePanelColors(app);
            }
        } else |_| {
            app.surface.cancel();
            core.zonvie_core_abort_flush(cp);
            app.flush_outcome.store(.aborted, .release);
        }
    }
    queueRender(app);
}

/// Callable from any thread; at most one idle is outstanding.
pub fn queueRender(app: *App) void {
    if (app.render_idle_queued.swap(true, .acq_rel)) return;
    _ = glib.g_idle_add(&idleQueueRender, app);
}

fn idleQueueRender(data: ?*anyopaque) callconv(.c) c_int {
    const app = appFrom(data);
    if (app.render_idle_queued.swap(false, .acq_rel)) runQueuedRender(app);
    return 0;
}

/// How long the resize handler waits for Neovim's answer, and how often it
/// looks: under half a 60 Hz frame.
const resize_wait_ns = 8 * std.time.ns_per_ms;
const resize_poll_ns = 200 * std.time.ns_per_us;

/// From the window's configure handler, after the new layout went to the
/// core. The new size is drawn right after, and Neovim answers a resize
/// within a few ms: without waiting, that draw shows the grid laid out for
/// the old size, clipped or short, and the right one a frame later. Waits
/// only while Neovim's screen is up and is not the grid the window holds; a
/// Neovim that keeps its size (another UI holds it smaller) costs the full
/// wait. Main thread.
pub fn awaitResizeAnswer(app: *App) void {
    lock(app);
    const cw = app.cell_w_px;
    const ch = app.cell_h_px;
    const w = app.drawable_w_px;
    const h = app.drawable_h_px;
    const scale = app.scale;
    unlock(app);
    if (cw == 0 or ch == 0) return;
    const want = scrollbar.gridFor(app.scrollbar_cfg, w, h, cw, ch, scale);
    const rows = want.rows;
    const cols = want.cols;
    const io = clock.io();
    const deadline_ns = clock.nowNs() + resize_wait_ns;
    while (true) {
        lock(app);
        const root: [2]u32 = for (app.surface.committedLayers()) |l| {
            if (l.grid_id == 1) break .{ l.rows, l.cols };
        } else .{ 0, 0 };
        unlock(app);
        // The frame drawn after this wait shows what is committed by then.
        if (root[0] == 0 or (root[0] == rows and root[1] == cols)) return;
        if (clock.nowNs() >= deadline_ns) return;
        std.Io.sleep(io, .{ .nanoseconds = resize_poll_ns }, .awake) catch {};
    }
}

fn runQueuedRender(app: *App) void {
    // The anchor as the core holds it now, which a flush not yet committed
    // may have moved: the panels are placed against it at once, as the
    // commit that follows draws the rows (onFlushEnd). Taken before App.mu,
    // which the core's own lock is never held under.
    var anchor: core.MsgAnchor = undefined;
    const have_anchor = if (app.corep) |cp| core.zonvie_core_msg_anchor(cp, &anchor) else false;
    lock(app);
    app.msg_anchor = if (have_anchor) anchor else null;
    // Neovim's first layout: the core's own first flush, before attach,
    // commits an empty one.
    const nvim_drawn = for (app.surface.committedLayers()) |l| {
        if (l.rows != 0) break true;
    } else false;
    unlock(app);
    ui_widgets.placeMessages(app);
    panel_popup.update(app);
    input.refreshPanelHover(app);
    if (nvim_drawn) {
        ui_widgets.hideProgress(app);
        session.onReady(app);
    }
    app.queueRenderAll();
    input.updateImeCursor(app);
    // Every flush may carry a mode change, and with it a new cadence.
    blink.update(app);
    scrollbar.update(app);
    // A flush can arm, move or clear the core's message deadline.
    core_timers.scheduleMsg(app);
    core_timers.settleFlush(app);
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
    const stride = @as(usize, atlas_w) * 4;
    if (ops.w == atlas_w and ops.h == atlas_h and ops.mirror.len == stride * atlas_h) {
        // Same size: only the rows uploads reached hold anything but zero.
        @memset(ops.mirror[0 .. stride * ops.dirty_rows], 0);
    } else {
        // The kernel hands anonymous pages out zeroed, and only as they are
        // written: zeroing 16 MB here would sit in Neovim's first flush.
        ops.unmapMirror();
        const p = std.c.mmap(null, stride * atlas_h, .{ .READ = true, .WRITE = true }, .{ .TYPE = .PRIVATE, .ANONYMOUS = true }, -1, 0);
        if (p == std.c.MAP_FAILED) {
            ops.w = 0;
            ops.h = 0;
            return core.zonvie_core_abort_flush(app.corep);
        }
        ops.mirror = @as([*]u8, @ptrCast(p))[0 .. stride * atlas_h];
    }
    ops.dirty_rows = 0;
    ops.recreate = true;
    ops.held = true;
    ops.gen +%= 1;
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
        @memcpy(ops.mirror[dst_off..][0..row_bytes], src[r * row_bytes ..][0..row_bytes]);
    }
    ops.dirty_rows = @max(ops.dirty_rows, dest_y + height);
    if (ops.recreate) {
        // The new texture is filled from the mirror: nothing to queue.
        ops.pixels.shrinkRetainingCapacity(offset);
    } else {
        ops.uploads.appendAssumeCapacity(.{ .x = dest_x, .y = dest_y, .w = width, .h = height, .offset = offset });
    }
    ops.gen +%= 1;
}

fn onRasterizeGlyph(ctx: ?*anyopaque, scalar: u32, style_flags: u32, out_bitmap: *core.GlyphBitmap) callconv(.c) c_int {
    const app = appFrom(ctx);
    ensureFont(app);
    // Valid only during this callback (zonvie_core.h).
    var cluster_len: u8 = 0;
    const cluster_ptr = core.zonvie_core_get_emoji_cluster(app.corep, &cluster_len);
    const cluster: []const u32 = if (cluster_ptr) |p| p[0..cluster_len] else &.{};
    return @intFromBool(app.fonts.rasterizeScalar(app.alloc, scalar, style_flags, cluster, out_bitmap));
}

fn onRasterizeGlyphById(ctx: ?*anyopaque, glyph_id: u32, style_flags: u32, out_bitmap: *core.GlyphBitmap) callconv(.c) c_int {
    const app = appFrom(ctx);
    ensureFont(app);
    return @intFromBool(app.fonts.rasterizeGlyphId(app.alloc, glyph_id, style_flags, out_bitmap));
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

// Per-grid fonts (zonvie_core.h on_font_slot_load ff.). Core thread with
// grid_mu held, like the global font's callbacks; the _ex ones come only
// with a font_id the core loaded and has not released.

/// The loaded face set of a non-zero font_id.
fn slotFonts(app: *App, font_id: u32) ?*Fonts {
    if (font_id == 0 or font_id >= app.slot_fonts.len) return null;
    return app.slot_fonts[font_id];
}

fn releaseSlot(app: *App, font_id: u32) void {
    const f = slotFonts(app, font_id) orelse return;
    lock(app);
    app.slot_preedit[font_id] = .{};
    unlock(app);
    f.deinit(app.alloc);
    app.alloc.destroy(f);
    app.slot_fonts[font_id] = null;
}

/// The first candidate of the payload that loads, at its size times
/// `scale`; an empty name or size is the global font's. Post on 1: the slot
/// holds that face set and the out cell is its cell, the row height with
/// 'linespace' as the global cell has it. On 0 the slot is unchanged.
fn onFontSlotLoad(ctx: ?*anyopaque, font_id: u32, utf8: [*]const u8, len: usize, scale: f32, out_cell_w_px: *u32, out_cell_h_px: *u32) callconv(.c) c_int {
    const app = appFrom(ctx);
    if (font_id == 0 or font_id >= app.slot_fonts.len) return 0;
    ensureFont(app);
    lock(app);
    const global_pt = app.font_pt;
    unlock(app);
    const global: font_spec.Defaults = .{
        .family = app.fonts.family[0..app.fonts.family_len],
        .point_size = if (global_pt > 0) global_pt else configPt(app),
        .features = app.fonts.features[0..app.fonts.features_len],
    };
    const fonts = app.alloc.create(Fonts) catch return 0;
    fonts.* = .{};
    const payload: []const u8 = if (len != 0) utf8[0..len] else "";
    var it = std.mem.splitScalar(u8, payload, '\n');
    while (it.next()) |line| {
        const cand = font_spec.slotCandidate(line, global, scale) orelse continue;
        const base: font_mod.BaseStyle = if (cand.global_face) app.fonts.base else .{};
        if (!fonts.load(app.alloc, cand.family, pixelSize(app, cand.point_size), cand.features, base)) continue;
        releaseSlot(app, font_id);
        app.slot_fonts[font_id] = fonts;
        lock(app);
        app.slot_preedit[font_id] = ui_widgets.PreeditFont.of(fonts.family[0..fonts.family_len], fonts.pixel_size, app.scale);
        unlock(app);
        out_cell_w_px.* = fonts.cell_w_px;
        out_cell_h_px.* = rowHeightPx(fonts.cell_h_px, app.linespace_px);
        applog.appLog("[font_slot] load id={d} {s} {d}pt cell={d}x{d}\n", .{ font_id, cand.family, cand.point_size, out_cell_w_px.*, out_cell_h_px.* });
        return 1;
    }
    fonts.deinit(app.alloc);
    app.alloc.destroy(fonts);
    applog.appLog("[font_slot] load id={d} failed\n", .{font_id});
    return 0;
}

fn onFontSlotRelease(ctx: ?*anyopaque, font_id: u32) callconv(.c) void {
    releaseSlot(appFrom(ctx), font_id);
}

/// Staged for the next commit (zonvie_core.h on_grid_font): the grid's
/// committed rows are still in the font they were laid out in.
fn onGridFont(ctx: ?*anyopaque, grid_id: i64, font_id: u32, cell_w_px: u32, cell_h_px: u32, extent_w_px: u32, extent_h_px: u32) callconv(.c) void {
    const app = appFrom(ctx);
    const font: ?layer_geom.GridFont = if (font_id == 0 or cell_w_px == 0 or cell_h_px == 0) null else .{
        .font_id = font_id,
        .cell_w_px = cell_w_px,
        .cell_h_px = cell_h_px,
        .extent_w_px = extent_w_px,
        .extent_h_px = extent_h_px,
    };
    lock(app);
    defer unlock(app);
    app.surface.stageGridFont(app.alloc, grid_id, font) catch {
        // Not resent by the core: the grid would be drawn in a font it is
        // not laid out in. Rare (OOM); logged.
        applog.appLog("[font_slot] grid_font dropped grid={d}: out of memory\n", .{grid_id});
    };
}

fn onShapeTextRunEx(
    ctx: ?*anyopaque,
    font_id: u32,
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
    const f = slotFonts(app, font_id) orelse return 0;
    return f.shape(app.alloc, scalars, scalar_count, style_flags, out_glyph_ids, out_clusters, out_x_advance, out_x_offset, out_y_offset, out_cap);
}

fn onRasterizeGlyphEx(ctx: ?*anyopaque, font_id: u32, scalar: u32, style_flags: u32, out_bitmap: *core.GlyphBitmap) callconv(.c) c_int {
    const app = appFrom(ctx);
    const f = slotFonts(app, font_id) orelse return 0;
    var cluster_len: u8 = 0;
    const cluster_ptr = core.zonvie_core_get_emoji_cluster(app.corep, &cluster_len);
    const cluster: []const u32 = if (cluster_ptr) |p| p[0..cluster_len] else &.{};
    return @intFromBool(f.rasterizeScalar(app.alloc, scalar, style_flags, cluster, out_bitmap));
}

fn onRasterizeGlyphByIdEx(ctx: ?*anyopaque, font_id: u32, glyph_id: u32, style_flags: u32, out_bitmap: *core.GlyphBitmap) callconv(.c) c_int {
    const app = appFrom(ctx);
    const f = slotFonts(app, font_id) orelse return 0;
    return @intFromBool(f.rasterizeGlyphId(app.alloc, glyph_id, style_flags, out_bitmap));
}

// =========================================================================
// Font and metrics
// =========================================================================

const default_family = "monospace";

fn pixelSize(app: *App, pt: f32) u32 {
    lock(app);
    const scale = app.scale;
    unlock(app);
    // A logical 96 dpi, times the surface scale.
    return @intFromFloat(@max(1.0, @round(pt * 96.0 / 72.0 * scale)));
}

/// [font] size when config.toml sets it, else the Linux default.
fn configPt(app: *App) f32 {
    // [font] size, else the default `--help` documents (Config.FontConfig).
    return if (app.font_cfg.size > 0) app.font_cfg.size else (core.config.Config.FontConfig{}).size;
}

const FontLoad = enum { failed, loaded, unchanged };

/// What a candidate list loads depends on, besides [font] size, which is
/// fixed for the session. Never 0, which App.font_request keeps for "none".
fn fontRequestKey(list: []const u8, size_explicit: bool, base: font_mod.BaseStyle) u64 {
    var h = std.hash.Wyhash.init(0);
    h.update(list);
    h.update(&.{ @intFromBool(size_explicit), @intFromBool(base.bold), @intFromBool(base.italic) });
    return h.final() | 1;
}

/// Loads the first candidate of a newline-separated list (a guifont payload,
/// or [font] family through the core's formatter) that fontconfig accepts.
/// `unchanged` when the faces already come from this very list: Neovim's
/// default guifont at attach names what a config-less start loaded, and an
/// explicit [font] family is asked for again at every guifont.
fn loadFirst(app: *App, list: []const u8, size_explicit: bool, base: font_mod.BaseStyle) FontLoad {
    const key = fontRequestKey(list, size_explicit, base);
    if (app.fonts.regular != null and app.font_request == key) return .unchanged;
    var it = std.mem.splitScalar(u8, list, '\n');
    while (it.next()) |line| {
        const cand = core.config.parseFontCandidateLine(line, configPt(app), size_explicit) orelse continue;
        if (app.fonts.load(app.alloc, cand.name, pixelSize(app, cand.point_size), cand.features, base)) {
            applog.appLog("[linux] font: {s} {d}pt features={s}\n", .{ cand.name, cand.point_size, cand.features });
            app.font_request = key;
            lock(app);
            app.font_pt = cand.point_size;
            unlock(app);
            return .loaded;
        }
    }
    return .failed;
}

/// [font] family as a candidate list: each entry inherits [font] size
/// unless it carries its own `:hN`.
fn loadConfigFamily(app: *App) FontLoad {
    var arena = std.heap.ArenaAllocator.init(app.alloc);
    defer arena.deinit();
    const list = core.config.formatFontFamilyAsCandidateList(arena.allocator(), app.font_cfg.family, configPt(app), default_family) catch return .failed;
    return loadFirst(app, list, false, .{});
}

/// The last resort: fontconfig's own monospace at [font] size.
fn loadDefaultFamily(app: *App) bool {
    app.font_request = 0;
    return app.fonts.load(app.alloc, default_family, pixelSize(app, configPt(app)), "", .{});
}

/// Loads [font] (or its defaults) when no guifont has been applied yet.
/// Core thread, or any thread before zonvie_core_start.
pub fn ensureFont(app: *App) void {
    if (app.fonts.regular != null) return;
    if (loadConfigFamily(app) == .failed) _ = loadDefaultFamily(app);
    updateMetrics(app);
}

/// A font cell's row height with 'linespace', floored at 1: the unit
/// zonvie_core_update_layout_px and on_font_slot_load take as cell_h_px.
fn rowHeightPx(cell_h_px: u32, linespace_px: i32) u32 {
    return @intCast(@max(1, @as(i32, @intCast(cell_h_px)) + linespace_px));
}

/// Publishes the font cell plus linespace.
fn updateMetrics(app: *App) void {
    const h = rowHeightPx(app.fonts.cell_h_px, app.linespace_px);
    lock(app);
    app.cell_w_px = app.fonts.cell_w_px;
    app.cell_h_px = h;
    const n = app.fonts.family_len;
    @memcpy(app.preedit_family[0..n], app.fonts.family[0..n]);
    app.preedit_family_len = n;
    app.preedit_px = @as(f32, @floatFromInt(app.fonts.pixel_size)) / app.scale;
    unlock(app);
    // The line the GUI harness reads the cell size from, as on Windows.
    applog.appLog("[cell_metrics] cellW={d} cellH={d}\n", .{ app.fonts.cell_w_px, h });
    // The windows follow the new cell: the main one snaps to it, external
    // ones keep their grids' rows and columns.
    window_size.queueSnap(app);
    ext_window.queueRefit(app);
}

fn sendLayout(app: *App) void {
    lock(app);
    const w = app.drawable_w_px;
    const h = app.drawable_h_px;
    const cw = app.cell_w_px;
    const ch = app.cell_h_px;
    const scale = app.scale;
    unlock(app);
    if (w == 0 or h == 0 or cw == 0) return;
    const cols = cmdlineCols(app, w, cw);
    const grid_w = scrollbar.gridWidthPx(app.scrollbar_cfg, w, scale);
    // On the redraw thread the core applies this under the grid_mu it holds.
    _ = core.zonvie_core_try_update_layout_px(app.corep, grid_w, h, cw, ch, cols.screen_cols, cols.default_cols);
}

/// The cmdline's width budget, less the panel chrome and the screen margin:
/// the main view's width. Caller does not hold App.mu.
pub fn cmdlineCols(app: *App, main_w_px: u32, cell_w_px: u32) rules.CmdlineCols {
    lock(app);
    const scale: u32 = @intFromFloat(app.scale);
    const copy = app.copy_cmdline;
    unlock(app);
    const chrome: u32 = @intCast(overlay_layout.cmdlineChromePx(@intCast(scale), copy));
    const margin: u32 = 2 * scale * @as(u32, @intCast(overlay_layout.cmdline_screen_margin_pt));
    return rules.cmdlineCols(main_w_px, main_w_px, chrome, margin, cell_w_px);
}

fn onGuiFont(ctx: ?*anyopaque, bytes: [*]const u8, len: usize) callconv(.c) void {
    const app = appFrom(ctx);
    // `:set guifont=*` asks for the font dialog.
    if (len == 1 and bytes[0] == '*') return font_picker.request(app);
    // An explicit [font] family wins over guifont, as on macOS and Windows:
    // Neovim sends its own default guifont at attach even when the user set
    // none. An explicit [font] size wins over each entry's `:hN`. A pick
    // from the font dialog wins over both.
    const picked = app.font_picked.swap(false, .acq_rel);
    // The pick's weight and slant are the regular face's; any other guifont
    // is the family's regular face, and the next dialog starts from that.
    const base: font_mod.BaseStyle = if (picked) .{ .bold = app.picked_bold.load(.acquire), .italic = app.picked_italic.load(.acquire) } else .{};
    if (!picked) {
        app.picked_bold.store(false, .release);
        app.picked_italic.store(false, .release);
    }
    const loaded = if (app.font_cfg.family_explicit and !picked)
        loadConfigFamily(app)
    else
        loadFirst(app, bytes[0..len], app.font_cfg.size_explicit and !picked, base);
    if (loaded == .unchanged) return;
    if (loaded == .failed) {
        if (app.fonts.regular != null) return;
        if (!loadDefaultFamily(app)) return;
    }
    // The core reset its glyph caches and the atlas before this callback and
    // rasterizes nothing until it returns.
    updateMetrics(app);
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
    // Search / Comment are read after the flush that ends this batch, when
    // its hl_attr_define / hl_group_set are in as well (as Windows refreshes
    // its cmdline colours on a colourscheme commit).
    app.panel_colors_stale = true;
    unlock(app);
    // The widget stylesheet follows Normal.
    ui_widgets.queueRefresh(app);
}

fn onSetTitle(ctx: ?*anyopaque, title: [*]const u8, title_len: usize) callconv(.c) void {
    const app = appFrom(ctx);
    lock(app);
    app.title_len = rules.copyUtf8Truncated(app.title[0 .. app.title.len - 1], title[0..title_len]);
    unlock(app);
    _ = glib.g_idle_add(&idleSetTitle, app);
}

fn idleSetTitle(data: ?*anyopaque) callconv(.c) c_int {
    const app = appFrom(data);
    var buf: [256]u8 = undefined;
    lock(app);
    @memcpy(buf[0..app.title_len], app.title[0..app.title_len]);
    const n = app.title_len;
    unlock(app);
    session.applyTitle(app, buf[0..n]);
    return 0;
}

fn onExit(ctx: ?*anyopaque, exit_code: i32) callconv(.c) void {
    const app = appFrom(ctx);
    lock(app);
    app.exit_code = exit_code;
    unlock(app);
    _ = glib.g_idle_add(&idleQuit, app);
}

fn idleQuit(data: ?*anyopaque) callconv(.c) c_int {
    const app = appFrom(data);
    lock(app);
    const code = app.exit_code orelse 0;
    unlock(app);
    // A remote start that ended before its first frame: an alert, then quit.
    if (session.failEarlyExit(app, code)) return 0;
    ui.window.quit(appFrom(data));
    return 0;
}

fn onQuitRequested(ctx: ?*anyopaque, has_unsaved: c_int) callconv(.c) void {
    const app = appFrom(ctx);
    app.quit_has_unsaved.store(has_unsaved != 0, .release);
    _ = glib.g_idle_add(&idleQuitRequested, app);
}

/// Closing the window sends Neovim its own `:confirm qa` (main.zig onClose)
/// and never asks the core, so this answers only a quit the core raised by
/// itself: with nothing unsaved it may go on; otherwise it is left unanswered,
/// as a cancelled dialog would leave it.
fn idleQuitRequested(data: ?*anyopaque) callconv(.c) c_int {
    const app = appFrom(data);
    const cp = app.corep orelse return 0;
    if (!app.quit_has_unsaved.load(.acquire)) core.zonvie_core_quit_confirmed(cp, 0);
    return 0;
}

/// `:restart` / `:connect`: the core reconnects by itself and no on_exit
/// follows (zonvie_core.h). The Linux frontend keeps no per-session
/// surface generation or cursor-grid memory (Windows' onSessionSwap): ext
/// windows open and close in the core's order through one queue, so there
/// is nothing to reset; the address is logged.
fn onRestart(ctx: ?*anyopaque, addr: [*]const u8, addr_len: usize) callconv(.c) void {
    applog.appLog("[linux] on_restart: reconnecting to listen_addr={s}\n", .{addr[0..addr_len]});
    onSessionSwap(appFrom(ctx));
}

fn onConnect(ctx: ?*anyopaque, addr: [*]const u8, addr_len: usize) callconv(.c) void {
    applog.appLog("[linux] on_connect: hot-swap to server_addr={s}\n", .{addr[0..addr_len]});
    onSessionSwap(appFrom(ctx));
}

/// `:restart` / `:connect`: another nvim takes over this window (the core
/// swaps sessions without tearing the UI down). Core thread.
/// Reset here: what names the old server's state, nvim_ready (main thread,
/// in the idle).
/// Kept: the ext_ops queue (ordered; the core's closes for the old
/// session's windows still have to reach them), the panel popups (redrawn
/// from the next flush's state).
fn onSessionSwap(app: *App) void {
    _ = glib.g_idle_add(&idleSessionSwap, app);
}

fn idleSessionSwap(data: ?*anyopaque) callconv(.c) c_int {
    const app = appFrom(data);
    // Files handed over now wait for the new server's first frame (its
    // flushes only start once it is attached), as at startup. The window is
    // already shown, so that frame must not present it again.
    app.nvim_ready = false;
    app.show_when_ready = false;
    return 0;
}

fn onImeOff(ctx: ?*anyopaque) callconv(.c) void {
    _ = glib.g_idle_add(&idleImeOff, appFrom(ctx));
}

fn idleImeOff(data: ?*anyopaque) callconv(.c) c_int {
    _ = data;
    ime_off.off();
    return 0;
}

fn onMainGridSize(ctx: ?*anyopaque, rows: u32, cols: u32) callconv(.c) void {
    const app = appFrom(ctx);
    lock(app);
    app.requested_rows = rows;
    app.requested_cols = cols;
    unlock(app);
    _ = glib.g_idle_add(&idleResizeToGrid, app);
}

fn idleResizeToGrid(data: ?*anyopaque) callconv(.c) c_int {
    const app = appFrom(data);
    lock(app);
    const rows = app.requested_rows;
    const cols = app.requested_cols;
    unlock(app);
    window_size.resizeToGrid(app, rows, cols);
    return 0;
}

fn onLog(ctx: ?*anyopaque, p: [*]const u8, n: usize) callconv(.c) void {
    const s = p[0..n];
    // Before the first frame of a remote start: kept for an early exit.
    appFrom(ctx).start_output.append(core.clock.io(), s);
    // The core's render traces carry no flush id: stamp this side's, which
    // counts the same flushes (windows/callbacks.zig onLog).
    const tag = "[render_trace] ";
    if (std.mem.startsWith(u8, s, tag)) {
        if (applog.isVerbose()) applog.appLog("[render_trace] flush={d} {s}", .{ appFrom(ctx).trace_flush, s[tag.len..] });
        return;
    }
    applog.appLogBytes("[core] ", s);
}

fn onCallbackError(ctx: ?*anyopaque, code: u32, component: [*]const u8, component_len: usize) callconv(.c) void {
    _ = ctx;
    applog.appLog("[linux] callback error code={d} component={s}\n", .{ code, component[0..component_len] });
}

// =========================================================================
// Clipboard: the core thread blocks (bounded) while the main thread does the work.
// =========================================================================

const ClipboardTask = struct {
    app: *App,
    seq: u64,
    selection: Selection,
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
/// On timeout it bumps the seq so a late completion is ignored.
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

/// The X11 / Wayland selection a register is: `*` the PRIMARY selection
/// (what a mouse selection sets and a middle click pastes), `+` (and any
/// other) the CLIPBOARD, as Neovim's own Linux providers (xclip, xsel,
/// wl-copy) map them.
const Selection = enum { clipboard, primary };

fn selectionFor(register_name: [*:0]const u8) Selection {
    return if (register_name[0] == '*') .primary else .clipboard;
}

test "the star register is the primary selection, plus the clipboard" {
    try std.testing.expectEqual(Selection.primary, selectionFor("*"));
    try std.testing.expectEqual(Selection.clipboard, selectionFor("+"));
    try std.testing.expectEqual(Selection.clipboard, selectionFor(""));
}

fn onClipboardGet(ctx: ?*anyopaque, register: [*]const u8, out_buf: [*]u8, out_len: *usize, max_len: usize) callconv(.c) c_int {
    const app = appFrom(ctx);
    out_len.* = 0;
    const seq = beginClipboardOp(app);
    const task = app.alloc.create(ClipboardTask) catch return 0;
    task.* = .{ .app = app, .seq = seq, .selection = selectionFor(@ptrCast(register)), .buf = &.{} };
    _ = glib.g_idle_add(&idleClipboardGet, task);

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
    defer freeTask(task);
    const text = ui.window.selectionGet(task.selection == .primary) orelse {
        signalClipboardDone(task.app, task.seq, 0, "");
        return 0;
    };
    defer std.c.free(text.ptr);
    signalClipboardDone(task.app, task.seq, 1, text);
    return 0;
}

fn onClipboardSet(ctx: ?*anyopaque, register: [*]const u8, data: [*]const u8, len: usize) callconv(.c) c_int {
    const app = appFrom(ctx);
    // An empty register empties the clipboard (it is set to ""), as on
    // macOS and Windows. The idle owns its copy, so a later set cannot
    // overwrite text still being handed over.
    const buf = app.alloc.alloc(u8, len + 1) catch return 0;
    @memcpy(buf[0..len], data[0..len]);
    buf[len] = 0;
    const task = app.alloc.create(ClipboardTask) catch {
        app.alloc.free(buf);
        return 0;
    };
    task.* = .{ .app = app, .seq = beginClipboardOp(app), .selection = selectionFor(@ptrCast(register)), .buf = buf };
    _ = glib.g_idle_add(&idleClipboardSet, task);

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
    // `buf` carries a trailing 0 the selection does not.
    const ok = ui.window.selectionSet(task.selection == .primary, task.buf[0 .. task.buf.len - 1]);
    signalClipboardDone(app, task.seq, @intFromBool(ok), "");
    return 0;
}
