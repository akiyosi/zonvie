//! The Linux frontend: Zonvie on a bare Wayland xdg_toplevel, with no
//! toolkit. The window, its EGL surface, the keyboard and pointer, the
//! selections and the input method are wl/window.c; this file drives it and
//! the core. There is no X11
//! backend.
//!
//! One thread runs a GLib main loop (GLib alone): the modules that face the
//! core queue their main-thread work with g_idle_add and g_timeout_add, and
//! the Wayland socket is one more source of that loop.

const std = @import("std");
const core = @import("zonvie_core");
const clock = core.clock;
const App = @import("app.zig").App;
const applog = @import("app_log.zig");
const callbacks = @import("callbacks.zig");
const cli = @import("cli.zig");
const config_mod = @import("config.zig");
const gl_renderer = @import("renderer/gl_renderer.zig");
const keymap = @import("keymap.zig");
const core_timers = @import("core_timers.zig");
const ime_off_dbus = @import("ime_off.zig");
const trackpad = @import("trackpad.zig");
const pointer_rules = @import("pointer.zig");
const scrollbar = @import("scrollbar.zig");
const lifecycle = @import("lifecycle.zig");
const window_state = @import("window_size.zig");
const crash = @import("crash.zig");
const blink = @import("blink.zig");
const shell = @import("shell.zig");
const chrome = @import("chrome.zig");
const ui_layer = @import("ui_layer.zig");
const pixel_scroll = @import("pixel_scroll.zig");
const single_instance = @import("single_instance.zig");
const form = @import("form.zig");
const tray = @import("tray.zig");
const ext_window = @import("ext_window.zig");
const panel_popup = @import("panel_popup.zig");
const overlay_layout = @import("overlay_layout.zig");

/// A panic's report goes to the log and, without a terminal, a crash file.
pub const panic = std.debug.FullPanic(crash.onPanic);

const app_id = "io.github.akiyosi.zonvie";
const default_w_logical = 1000;
const default_h_logical = 700;

// wl/window.h
const Listener = extern struct {
    configure: ?*const fn (?*anyopaque, i32, i32) callconv(.c) void,
    close: ?*const fn (?*anyopaque) callconv(.c) void,
    focus: ?*const fn (?*anyopaque, c_int, i64) callconv(.c) void,
    key: ?*const fn (?*anyopaque, u32, u32, u32, u32, u32, u32, c_int, c_int) callconv(.c) void,
    frame: ?*const fn (?*anyopaque) callconv(.c) void,
    pointer_motion: ?*const fn (?*anyopaque, f64, f64) callconv(.c) void,
    pointer_leave: ?*const fn (?*anyopaque) callconv(.c) void,
    pointer_button: ?*const fn (?*anyopaque, u32, c_int, u32) callconv(.c) void,
    pointer_axis: ?*const fn (?*anyopaque, f64, f64, i32, i32, u32) callconv(.c) void,
    pointer_axis_stop: ?*const fn (?*anyopaque, f64, f64) callconv(.c) void,
    ime_preedit: ?*const fn (?*anyopaque, [*:0]const u8, i32, i32) callconv(.c) void,
    ime_commit: ?*const fn (?*anyopaque, [*:0]const u8) callconv(.c) void,
    keys_reset: ?*const fn (?*anyopaque) callconv(.c) void,
    drop: ?*const fn (?*anyopaque, [*]const u8, usize) callconv(.c) void,
    ext_configure: ?*const fn (?*anyopaque, i64, i32, i32) callconv(.c) void,
    ext_close: ?*const fn (?*anyopaque, i64) callconv(.c) void,
    ext_frame: ?*const fn (?*anyopaque, i64) callconv(.c) void,
    pointer_window: ?*const fn (?*anyopaque, i64) callconv(.c) void,
};
extern "c" fn zwl_open(l: *const Listener, data: ?*anyopaque) c_int;
extern "c" fn zwl_fd() c_int;
extern "c" fn zwl_scale() c_int;
extern "c" fn zwl_window(app_id: [*:0]const u8, title: [*:0]const u8, server_decorations: c_int) c_int;
extern "c" fn zwl_set_title(title: [*:0]const u8) void;
extern "c" fn zwl_placed() c_int;
extern "c" fn zwl_blur() void;
extern "c" fn zwl_set_buffer_scale(scale: i32) void;
extern "c" fn zwl_request_frame() void;
extern "c" fn zwl_frame_pending() c_int;
extern "c" fn zwl_hide() void;
extern "c" fn zwl_show(app_id: [*:0]const u8, title: [*:0]const u8) void;
extern "c" fn zwl_repeat_info(rate: *i32, delay: *i32) void;
extern "c" fn zwl_mods() u32;
extern "c" fn zwl_cursor(shape: c_int) void;
extern "c" fn zwl_move() void;
extern "c" fn zwl_resize(edge: u32) void;
extern "c" fn zwl_toggle_maximize() void;
extern "c" fn zwl_minimize() void;
extern "c" fn zwl_maximized() c_int;
extern "c" fn zwl_server_decorations() c_int;
extern "c" fn zwl_ime_cursor(x: i32, y: i32, w: i32, h: i32) void;
extern "c" fn zwl_ime_reset() void;
extern "c" fn zwl_selection_set(primary: c_int, text: [*]const u8, len: usize) c_int;
extern "c" fn zwl_selection_get(primary: c_int, out_len: *usize) ?[*]u8;
extern "c" fn zwl_egl_init(w_px: i32, h_px: i32) c_int;
extern "c" fn zwl_egl_resize(w_px: i32, h_px: i32) void;
extern "c" fn zwl_swap() c_int;
extern "c" fn zwl_buffer_stale() c_int;
extern "c" fn zwl_buffer_age() c_int;
extern "c" fn zwl_swap_damage(rects: [*]const [4]i32, n: i32) c_int;
extern "c" fn zwl_dispatch() c_int;
extern "c" fn zwl_dispatch_pending() c_int;
extern "c" fn zwl_flush() c_int;

// GLib's loop.
const GSourceFunc = *const fn (?*anyopaque) callconv(.c) c_int;
extern "c" fn g_main_loop_new(context: ?*anyopaque, is_running: c_int) ?*anyopaque;
extern "c" fn g_main_loop_run(loop: *anyopaque) void;
extern "c" fn g_main_loop_quit(loop: *anyopaque) void;
extern "c" fn g_unix_fd_add(fd: c_int, condition: c_uint, func: *const fn (c_int, c_uint, ?*anyopaque) callconv(.c) c_int, data: ?*anyopaque) c_uint;
extern "c" fn g_timeout_add(interval: c_uint, func: GSourceFunc, data: ?*anyopaque) c_uint;
extern "c" fn g_source_remove(tag: c_uint) c_int;
extern "c" fn g_idle_add(func: GSourceFunc, data: ?*anyopaque) c_uint;
extern "c" fn g_unix_signal_add(signum: c_int, handler: GSourceFunc, data: ?*anyopaque) c_uint;
const G_IO_IN: c_uint = 1;

/// The window's side of the App: main thread only.
const Window = struct {
    app: *App,
    loop: *anyopaque,
    scale: i32,
    /// The size a configure that leaves it to the client gets: the last
    /// run's, else the default. Logical px.
    free_w: i32 = default_w_logical,
    free_h: i32 = default_h_logical,
    /// The toplevel's size as last configured, logical px.
    w_logical: i32 = 0,
    h_logical: i32 = 0,
    /// The view a user, the compositor or Neovim last chose, device px; 0
    /// before the first. The snap's own resize never changes it: that is
    /// what is snapped again when the cell changes
    /// (frontend_rules.snapTerminalPx).
    desired_w_px: u32 = 0,
    desired_h_px: u32 = 0,
    /// A configure arrived, so a buffer may be attached.
    configured: bool = false,
    /// A change waits for the frame callback of the frame before it.
    dirty: bool = false,
    /// The first buffer was attached: the window is on screen.
    shown: bool = false,
    /// Unmapped to the tray: nothing is drawn until showWindow's configure.
    hidden: bool = false,
    showing: bool = false,
    /// When the first configure came; the first buffer waits from then.
    configured_ns: i128 = 0,
    layout_ready_sent: bool = false,
    layout_retry_queued: bool = false,
    repeat_timer: c_uint = 0,
    repeat_key: u32 = 0,
    repeat: Key = undefined,
};

const Key = struct { sym: u32, base_sym: u32, utf32: u32, base_utf32: u32, mods: u32 };

var window: Window = undefined;

fn lock(app: *App) void {
    app.mu.lockUncancelable(clock.io());
}

fn unlock(app: *App) void {
    app.mu.unlock(clock.io());
}

// =========================================================================
// Frames
// =========================================================================

/// Draws the committed state now, or when the frame before it has been
/// shown. main thread. ui.zig's queueRenderMain.
pub fn queueRender(app: *App) void {
    ext_window.renderAll(app);
    panel_popup.queueRender(app);
    if (!window.configured or window.hidden) return;
    if (!window.shown and !firstFrameReady(app)) return;
    if (zwl_frame_pending() != 0) {
        window.dirty = true;
        return;
    }
    draw();
}

/// How long the window stays unmapped for Neovim's first screen.
const first_frame_wait_ms = 250;

/// The first buffer maps the window. It waits for Neovim's screen at the
/// window's own grid, so the window appears with its content instead of
/// empty and then again laid out for another size; a Neovim that takes
/// longer gets an empty window after `first_frame_wait_ms`.
fn firstFrameReady(app: *App) bool {
    if (clock.nowNs() - window.configured_ns >= first_frame_wait_ms * std.time.ns_per_ms) return true;
    // A start that announces itself (a container being built) has
    // something to show before Neovim does.
    if (app.progress.len != 0) return true;
    lock(app);
    defer unlock(app);
    if (app.cell_w_px == 0 or app.cell_h_px == 0) return false;
    const g = scrollbar.gridFor(app.scrollbar_cfg, app.drawable_w_px, app.drawable_h_px, app.cell_w_px, app.cell_h_px, app.scale);
    for (app.surface.committedLayers()) |l| {
        if (l.grid_id == 1) return l.rows == g.rows and l.cols == g.cols;
    }
    return false;
}

fn onFirstFrameTimeout(_: ?*anyopaque) callconv(.c) c_int {
    if (!window.shown) queueRender(window.app);
    return 0;
}

fn draw() void {
    // An unmapped surface gets no buffer back from the compositor: a swap
    // would wait for one forever.
    if (window.hidden) return;
    window.dirty = false;
    window.shown = true;
    if (applog.isEnabled()) applog.appLog("[wl] draw\n", .{});
    var age = zwl_buffer_age();
    if (zwl_buffer_stale() != 0) {
        // Taken before the window was resized: a frame drawn into it would
        // be scaled to the window, and stay so while nothing changes. Given
        // back undrawn; the frame goes whole into a buffer of the new size.
        _ = zwl_swap();
        gl_renderer.drawWholeNext(&window.app.gl);
        age = zwl_buffer_age();
    }
    const swap = gl_renderer.render(window.app, @intCast(@max(0, age)));
    // Nothing changed: the frame on screen stays, and no buffer is spent.
    if (swap.skip) return pump();
    zwl_request_frame();
    if (zwl_swap_damage(swap.rects.ptr, @intCast(swap.rects.len)) != 0) {
        // The frame never left: the damage history counts one no buffer
        // holds, so the next frame owes the whole window.
        gl_renderer.drawWholeNext(&window.app.gl);
        applog.appLog("[wl] swap failed\n", .{});
    }
    pump();
}

/// Test only: SIGUSR2 to an app run with ZONVIE_TEST_FULL_REDRAW=1 draws the
/// next main frame whole (test/gui/linux_window.zig forceFullRedraw).
fn onTestFullRedraw(data: ?*anyopaque) callconv(.c) c_int {
    const app: *App = @ptrCast(@alignCast(data.?));
    app.test_full_redraw = true;
    queueRender(app);
    return 1;
}

/// EGL reads the socket too (its own roundtrips, a swap), and what it reads
/// for this queue then waits there with the socket no longer readable:
/// dispatched here, after every call that may have done so.
fn pump() void {
    _ = zwl_dispatch_pending();
    _ = zwl_flush();
}

/// A grid eases or a shader animates: the frame after this one is drawn
/// too. Called from inside the draw. ui.zig's keepFrames.
pub fn keepFrames(app: *App) void {
    _ = app;
    window.dirty = true;
}

fn onFrame(_: ?*anyopaque) callconv(.c) void {
    if (window.dirty) draw();
}

// =========================================================================
// Size
// =========================================================================

const layout_retry_ms = 2;

fn retryLayout(_: ?*anyopaque) callconv(.c) c_int {
    window.layout_retry_queued = false;
    pushLayout(window.app);
    return 0;
}

fn pushLayout(app: *App) void {
    const cp = app.corep orelse return;
    lock(app);
    const w = app.drawable_w_px;
    const h = app.drawable_h_px;
    const cw = app.cell_w_px;
    const ch = app.cell_h_px;
    const scale = app.scale;
    unlock(app);
    if (w == 0 or h == 0 or cw == 0 or ch == 0) return;
    const cols = callbacks.cmdlineCols(app, w, cw);
    const grid_w = scrollbar.gridWidthPx(app.scrollbar_cfg, w, scale);
    // The core holds its grid lock through a flush: asked again shortly.
    if (!core.zonvie_core_try_update_layout_px(cp, grid_w, h, cw, ch, cols.screen_cols, cols.default_cols)) {
        if (!window.layout_retry_queued) {
            window.layout_retry_queued = true;
            _ = g_timeout_add(layout_retry_ms, &retryLayout, null);
        }
        return;
    }
    if (!window.layout_ready_sent) {
        window.layout_ready_sent = true;
        const g = scrollbar.gridFor(app.scrollbar_cfg, w, h, cw, ch, scale);
        core.zonvie_core_notify_layout_ready(cp, g.rows, g.cols);
    }
}

fn onConfigure(_: ?*anyopaque, w_logical: i32, h_logical: i32) callconv(.c) void {
    const was = [2]i32{ window.w_logical, window.h_logical };
    window.w_logical = if (w_logical > 0) w_logical else window.free_w;
    window.h_logical = if (h_logical > 0) h_logical else window.free_h;
    if (window.hidden) {
        // Only the configure that answers showWindow maps the window again.
        if (!window.showing) return;
        window.hidden = false;
        window.showing = false;
        window.w_logical = if (w_logical > 0) w_logical else window.w_logical;
        window.h_logical = if (h_logical > 0) h_logical else window.h_logical;
        applyWindowSize(false);
        // The size may be the one it had: the buffer that maps the window
        // is attached either way.
        return draw();
    }
    const first = !window.configured;
    window.configured = true;
    if (first) {
        window.configured_ns = clock.nowNs();
        _ = g_timeout_add(first_frame_wait_ms, &onFirstFrameTimeout, null);
    }
    applyWindowSize(first);
    // A size other than the one the window had is someone's choice. A
    // configure that repeats the size a snap set is not.
    if (window.w_logical != was[0] or window.h_logical != was[1]) {
        const app = window.app;
        lock(app);
        window.desired_w_px = app.drawable_w_px;
        window.desired_h_px = app.drawable_h_px;
        unlock(app);
    }
    scheduleSnap();
}

/// The window is `window.w_logical` x `window.h_logical`: the editor view
/// takes what the shell's chrome leaves of it, Neovim is asked for the grid
/// that fits, and the new size is drawn.
fn applyWindowSize(first: bool) void {
    const app = window.app;
    const win_w: u32 = @intCast(window.w_logical * window.scale);
    const win_h: u32 = @intCast(window.h_logical * window.scale);
    const in = shell.insets(app);
    const w_px: u32 = win_w -| @as(u32, @intCast(in.left + in.right));
    const h_px: u32 = win_h -| @as(u32, @intCast(in.top + in.bottom));
    lock(app);
    const win_changed = app.win_w_px != win_w or app.win_h_px != win_h;
    const changed = app.drawable_w_px != w_px or app.drawable_h_px != h_px;
    app.win_w_px = win_w;
    app.win_h_px = win_h;
    app.view_x_px = in.left;
    app.view_y_px = in.top;
    app.drawable_w_px = w_px;
    app.drawable_h_px = h_px;
    unlock(app);
    if (win_changed) zwl_egl_resize(@intCast(win_w), @intCast(win_h));
    if (changed) {
        pushLayout(app);
        callbacks.awaitResizeAnswer(app);
    }
    if (!changed and !win_changed and !first) return;
    shell.rebuild(app, false);
    // A new size is drawn at once, not at the frame callback of the frame
    // before it: that frame has the old size, and the compositor waits for
    // this one.
    if (window.shown) draw() else queueRender(app);
}

/// Gives the window a size of its own choosing, device px of the editor
/// view: a compositor that places the window (a tile, maximized,
/// fullscreen) keeps its say, so nothing happens then.
fn setViewPx(w_px: u32, h_px: u32) void {
    if (!window.shown or zwl_placed() != 0) return;
    const in = shell.insets(window.app);
    const s: u32 = @intCast(window.scale);
    // Whole logical px: rounded up, the view never loses a cell to it.
    window.w_logical = @intCast((w_px + @as(u32, @intCast(in.left + in.right)) + s - 1) / s);
    window.h_logical = @intCast((h_px + @as(u32, @intCast(in.top + in.bottom)) + s - 1) / s);
    applyWindowSize(false);
}

/// Neovim resized its grid (`:set lines` / `:set columns`): the window
/// follows. Main thread. ui.zig's window_size.resizeToGrid.
pub fn resizeToGrid(app: *App, rows: u32, cols: u32) void {
    lock(app);
    const cw = app.cell_w_px;
    const ch = app.cell_h_px;
    const vw = app.drawable_w_px;
    const scale = app.scale;
    unlock(app);
    if (rows == 0 or cols == 0 or cw == 0 or ch == 0 or vw == 0) return;
    // The cells are the grid's: a "column" scrollbar's strip stays as it is.
    const strip = vw - scrollbar.gridWidthPx(app.scrollbar_cfg, vw, scale);
    applog.appLog("[window_size] grid {d}x{d} -> view {d}x{d} px\n", .{ rows, cols, cols * cw + strip, rows * ch });
    window.desired_w_px = cols * cw + strip;
    window.desired_h_px = rows * ch;
    setViewPx(cols * cw + strip, rows * ch);
}

/// macOS's debounce before a resize ends in a snap.
const settle_ms = 300;
var snap_timer: c_uint = 0;
var snap_queued = std.atomic.Value(bool).init(false);

fn scheduleSnap() void {
    if (snap_timer != 0) _ = g_source_remove(snap_timer);
    snap_timer = g_timeout_add(settle_ms, &onSnap, null);
}

/// The cell changed (a font, a scale): the window snaps to whole cells
/// again. Callable from any thread. ui.zig's window_size.queueSnap.
pub fn queueSnap(app: *App) void {
    _ = app;
    if (snap_queued.swap(true, .acq_rel)) return;
    _ = g_idle_add(&onSnap, null);
}

/// Sizes the window so the view holds whole cells of the size last chosen
/// for it: the remainder of a free size would be a strip of background at
/// the right and the bottom.
fn onSnap(_: ?*anyopaque) callconv(.c) c_int {
    snap_timer = 0;
    snap_queued.store(false, .release);
    const app = window.app;
    lock(app);
    const cw = app.cell_w_px;
    const ch = app.cell_h_px;
    const vw = app.drawable_w_px;
    const vh = app.drawable_h_px;
    const scale = app.scale;
    unlock(app);
    const strip = scrollbar.columnStripPx(app.scrollbar_cfg, scale);
    if (vw <= strip) return 0;
    // The view is the grid's cells and the "column" scrollbar's strip
    // beside them: the strip is the "chrome" between the two sizes.
    const desired_w = if (window.desired_w_px > strip) window.desired_w_px - strip else 0;
    const snap = core.frontend_rules.snapMainWindowOuterSize(@intCast(vw), @intCast(vh), vw - strip, vh, desired_w, window.desired_h_px, cw, ch) orelse return 0;
    setViewPx(@intCast(snap.outer_w), @intCast(snap.outer_h));
    return 0;
}

/// The compositor's close: Neovim's own `:confirm qa`, which asks in its
/// command line when a buffer is unsaved and otherwise exits, ending the loop
/// through on_exit. No Neovim (it never started, or is gone): just the loop.
fn onClose(_: ?*anyopaque) callconv(.c) void {
    const app = window.app;
    // [server] close_to_tray: hide instead; Neovim keeps running and the
    // tray brings the window back. Its Quit asks for one real close
    // (consumed here, so a cancelled quit leaves close-to-tray on).
    const tray_quit = app.tray.quit_requested;
    app.tray.quit_requested = false;
    if (app.close_to_tray and app.tray.hosted and !tray_quit and window.shown and !window.hidden) {
        window.hidden = true;
        stopRepeat();
        // A popup dies with its parent's mapping.
        panel_popup.hideAll(app);
        zwl_hide();
        return;
    }
    const cp = app.corep orelse return g_main_loop_quit(window.loop);
    const cmd = "confirm qa";
    core.zonvie_core_send_command(cp, cmd, cmd.len);
}

/// ui.zig's session.applyTitle.
pub fn setTitle(app: *App, title: []const u8) void {
    var buf: [384]u8 = undefined;
    zwl_set_title(lifecycle.sessionTitle(&buf, title, app.session_name).ptr);
    _ = zwl_flush();
}

// =========================================================================
// Keys
// =========================================================================

fn sendKey(k: Key) void {
    const app = window.app;
    const cp = app.corep orelse return;
    // While a preedit is active the IME owns every key, including Return.
    if (app.preedit_active) return;
    const code = keymap.coreKeycode(k.sym);
    const mods = keymap.coreMods(k.mods);
    var buf: [4]u8 = undefined;
    var n: usize = 0;
    const cp_u = keymap.swapColonSemicolon(k.utf32, app.input_cfg.swap_colon_semicolon);
    if (cp_u != 0) n = std.unicode.utf8Encode(@intCast(cp_u), &buf) catch 0;
    // A bare modifier or dead key: nothing the core can format.
    if (code == 0 and n == 0) return;
    // A modified key names its unshifted key (<C-S-2>, not <C-S-@>).
    var ign: [4]u8 = undefined;
    var ign_n: usize = n;
    @memcpy(ign[0..n], buf[0..n]);
    if (mods & (core.MOD_CTRL | core.MOD_ALT | core.MOD_SUPER) != 0 and k.base_utf32 != 0) {
        ign_n = std.unicode.utf8Encode(@intCast(k.base_utf32), &ign) catch ign_n;
    }
    core.zonvie_core_send_key_event(cp, code, mods, &buf, @intCast(n), &ign, @intCast(ign_n));
}

// =========================================================================
// The frontend's own shortcuts
// =========================================================================

/// The tab keys exist only with [tabline] style = "menu".
fn menuStyle(app: *const App) bool {
    return app.ext_tabline and std.mem.eql(u8, app.tabline_cfg.style, "menu");
}

fn command(app: *App, cmd: []const u8) void {
    const cp = app.corep orelse return;
    core.zonvie_core_send_command(cp, cmd.ptr, cmd.len);
}

fn runShortcut(app: *App, sc: keymap.AppShortcut) void {
    switch (sc) {
        .new_session => openNewSession(),
        .quit => quitApp(),
        .about => showAbout(),
        .new_tab => command(app, "tabnew"),
        .close_tab => command(app, "tabclose"),
        .select_tab => |n| {
            var buf: [32]u8 = undefined;
            command(app, std.fmt.bufPrint(&buf, "{d}tabnext", .{n}) catch return);
        },
    }
}

/// Another zonvie, in a session of its own so it outlives this one: this
/// executable again, opening with the connection dialog.
pub fn openNewSession() void {
    var exe: [std.fs.max_path_bytes:0]u8 = undefined;
    const n = std.c.readlink("/proc/self/exe", &exe, exe.len - 1);
    if (n <= 0) return;
    exe[@intCast(n)] = 0;
    const pid = fork();
    if (pid != 0) return;
    // The child of a fork in a threaded process: only async-signal-safe
    // calls from here to the exec.
    _ = std.c.setsid();
    const argv = [_:null]?[*:0]const u8{ &exe, "--nofork", "--dialog" };
    _ = execvp(&exe, &argv);
    _exit(127);
}

/// About: the version, in Neovim's own message area.
pub fn showAbout() void {
    const app = window.app;
    var buf: [160]u8 = undefined;
    command(app, std.fmt.bufPrint(&buf, "echomsg 'Zonvie {s} - a Neovim GUI (Wayland)'", .{std.mem.span(core.zonvie_version())}) catch return);
}

fn stopRepeat() void {
    if (window.repeat_timer != 0) _ = g_source_remove(window.repeat_timer);
    window.repeat_timer = 0;
}

fn onRepeat(_: ?*anyopaque) callconv(.c) c_int {
    sendKey(window.repeat);
    return 1;
}

fn onRepeatDelay(_: ?*anyopaque) callconv(.c) c_int {
    var rate: i32 = 0;
    var delay: i32 = 0;
    zwl_repeat_info(&rate, &delay);
    sendKey(window.repeat);
    window.repeat_timer = if (rate > 0) g_timeout_add(@intCast(@divTrunc(1000, rate)), &onRepeat, null) else 0;
    return 0;
}

fn onKey(_: ?*anyopaque, key: u32, sym: u32, base_sym: u32, utf32: u32, base_utf32: u32, mods: u32, pressed: c_int, repeats: c_int) callconv(.c) void {
    if (pressed == 0) {
        if (key == window.repeat_key) stopRepeat();
        return;
    }
    const k: Key = .{ .sym = sym, .base_sym = base_sym, .utf32 = utf32, .base_utf32 = base_utf32, .mods = mods };
    // The frontend's own keys (Ctrl+Shift+...): Neovim never sees them, and
    // they do not repeat.
    if (keymap.appShortcut(base_sym, sym, mods, menuStyle(window.app))) |sc| {
        stopRepeat();
        return runShortcut(window.app, sc);
    }
    sendKey(k);
    stopRepeat();
    if (repeats == 0) return;
    var rate: i32 = 0;
    var delay: i32 = 0;
    zwl_repeat_info(&rate, &delay);
    if (rate <= 0) return;
    window.repeat_key = key;
    window.repeat = k;
    window.repeat_timer = g_timeout_add(@intCast(@max(1, delay)), &onRepeatDelay, null);
}

fn onKeysReset(_: ?*anyopaque) callconv(.c) void {
    stopRepeat();
}

fn onFocus(_: ?*anyopaque, focused: c_int, surface_id: i64) callconv(.c) void {
    if (focused == 0) stopRepeat();
    const app = window.app;
    if (surface_id != 0) {
        lock(app);
        const moved = app.focus_surface != surface_id;
        app.focus_surface = surface_id;
        unlock(app);
        // The cmdline follows the keyboard (gl_renderer.overlayInputs); in
        // the views when the panels are no popups.
        if (moved) app.queueRenderAll();
    }
    blink.setActive(app, focused != 0);
    // Most panels are taken off while the app is inactive.
    panel_popup.update(window.app);
}

// =========================================================================
// Input method
// =========================================================================

/// A composition starts or ends.
fn setComposing(app: *App, on: bool) void {
    if (app.preedit_active == on) return;
    app.preedit_active = on;
    app.ime_composing.store(on, .release);
    app.queueRenderAll();
}

/// The composition shell.zig draws at the cursor: empty while there is none
/// or the core shows it in the buffer.
fn setPreeditOverlay(app: *App, text: []const u8, clause: [2]usize) void {
    const n = @min(text.len, app.preedit_text.len);
    if (n == 0 and app.preedit_len == 0) return;
    @memcpy(app.preedit_text[0..n], text[0..n]);
    app.preedit_len = n;
    app.preedit_clause = if (clause[1] <= n) clause else .{ 0, 0 };
    shell.rebuild(app, true);
}

/// The composition as the input method has it now. The core shows it in the
/// buffer in insert and replace mode with [input] ime_preedit_mode =
/// "inline"; otherwise shell.zig draws it over the cursor.
fn onImePreedit(_: ?*anyopaque, text: [*:0]const u8, begin: i32, end: i32) callconv(.c) void {
    const app = window.app;
    const cp = app.corep orelse return;
    const t = std.mem.span(text);
    // The input method has the keyboard: a key held before it took over
    // sends no release here.
    if (t.len != 0) stopRepeat();
    if (t.len == 0) {
        if (app.preedit_active) core.zonvie_core_clear_preedit(cp);
        setComposing(app, false);
        setPreeditOverlay(app, "", .{ 0, 0 });
        return;
    }
    setComposing(app, true);
    // text-input-v3 carries the cursor's range, which input methods set to
    // the clause being converted.
    const clause: [2]usize = if (begin >= 0 and end > begin and end <= t.len) .{ @intCast(begin), @intCast(end) } else .{ 0, 0 };
    const shown_inline = core.zonvie_core_set_preedit(cp, t.ptr, t.len, clause[0], clause[1]) != 0;
    setPreeditOverlay(app, if (shown_inline) "" else t, clause);
}

fn onImeCommit(_: ?*anyopaque, text: [*:0]const u8) callconv(.c) void {
    const app = window.app;
    const cp = app.corep orelse return;
    const t = std.mem.span(text);
    if (app.preedit_active) {
        setComposing(app, false);
        core.zonvie_core_clear_preedit(cp);
        setPreeditOverlay(app, "", .{ 0, 0 });
    }
    if (t.len == 0) return;
    core.zonvie_core_send_input(cp, t.ptr, t.len);
}

/// Switches the input method off ([input] ime_disable_on_modechange and the
/// like): the composition is dropped, then the IM framework is asked over
/// D-Bus (ime_off.zig). main thread. ui.zig's ime_off.off.
pub fn imeOff() void {
    const app = window.app;
    if (app.preedit_active) {
        if (app.corep) |cp| core.zonvie_core_clear_preedit(cp);
        setComposing(app, false);
        setPreeditOverlay(app, "", .{ 0, 0 });
    }
    zwl_ime_reset();
    ime_off_dbus.off();
}

/// Tells the input method where the text cursor is, after a frame's state
/// was committed. main thread. ui.zig's input.updateImeCursor.
pub fn updateImeCursor(app: *App) void {
    lock(app);
    defer unlock(app);
    const cur = app.surface.committedCursor();
    if (cur.verts.len == 0) return;
    const layer = for (app.surface.committedSurfaceLayers(1)) |l| {
        if (l.grid_id == cur.grid_id) break l;
    } else return;
    const b = core.cursor_rect.bounds(core.Vertex, cur.verts, @floatFromInt(layer.x_px + app.view_x_px), @floatFromInt(layer.y_px + app.view_y_px)) orelse return;
    const s = app.scale;
    zwl_ime_cursor(
        @intFromFloat(b.left / s),
        @intFromFloat(b.top / s),
        @intFromFloat(@max(1.0, (b.right - b.left) / s)),
        @intFromFloat(@max(1.0, (b.bottom - b.top) / s)),
    );
}

// =========================================================================
// Selections
// =========================================================================

/// The clipboard's text, or the primary selection's; null when it holds
/// none. The caller frees it with std.c.free. main thread. ui.zig's
/// selectionGet.
pub fn selectionGet(primary: bool) ?[]u8 {
    var len: usize = 0;
    const p = zwl_selection_get(@intFromBool(primary), &len) orelse return null;
    return p[0..len];
}

/// main thread. ui.zig's selectionSet.
pub fn selectionSet(primary: bool, text: []const u8) bool {
    return zwl_selection_set(@intFromBool(primary), text.ptr, text.len) == 0;
}

// =========================================================================
// Pointer
// =========================================================================

/// A Linux button code as PressClaim's number (zonvie_core.h) and Neovim's name.
const Button = struct { claim: u8, name: [*:0]const u8 };

fn buttonOf(code: u32) ?Button {
    return switch (code) {
        0x110 => .{ .claim = 1, .name = "left" },
        0x111 => .{ .claim = 2, .name = "right" },
        0x112 => .{ .claim = 3, .name = "middle" },
        0x113 => .{ .claim = 4, .name = "x1" },
        0x114 => .{ .claim = 5, .name = "x2" },
        else => null,
    };
}

fn claimName(claim: u8) ?[*:0]const u8 {
    return switch (claim) {
        1 => "left",
        2 => "right",
        3 => "middle",
        4 => "x1",
        5 => "x2",
        else => null,
    };
}

/// The pointer in the window, logical px: the UI layer is hit-tested with it.
var pointer_win: [2]f64 = .{ 0, 0 };

/// Window logical px as the editor view's.
fn toView(app: *App, x: f64, y: f64) [2]f64 {
    lock(app);
    defer unlock(app);
    return .{ x - @as(f64, @floatFromInt(app.view_x_px)) / app.scale, y - @as(f64, @floatFromInt(app.view_y_px)) / app.scale };
}

/// The UI layer's hit region under the pointer.
fn uiHit(app: *App) ?ui_layer.Hit {
    lock(app);
    defer unlock(app);
    return app.chrome_layer.hitAt(@intFromFloat(@floor(pointer_win[0] * app.scale)), @intFromFloat(@floor(pointer_win[1] * app.scale)));
}

fn onPointerMotion(_: ?*anyopaque, sx: f64, sy: f64) callconv(.c) void {
    const app = window.app;
    var wx = sx;
    var wy = sy;
    if (pointer_popup) |kind| {
        const h = panel_popup.toHost(app, kind, sx, sy);
        wx = h.x;
        wy = h.y;
        ext_window.onPointerWindow(app, if (h.host == 1) 0 else h.host);
    }
    const ext = ext_window.pointer_target;
    const p = if (ext) |e| &e.pointer else &app.pointer;
    pointer_win = .{ wx, wy };
    // An external window is all view: no chrome, no inset.
    const v = if (ext != null) [2]f64{ wx, wy } else toView(app, wx, wy);
    const x = v[0];
    const y = v[1];
    p.x = x;
    p.y = y;
    if (ext == null) {
        lock(app);
        const s = app.scale;
        unlock(app);
        const hit = uiHit(app);
        if (chrome.motion(app, @intFromFloat(@floor(wx * s)), @intFromFloat(@floor(wy * s)), hit)) return;
        if (resizeEdge(app)) |edge| return setCursor(edgeCursor(edge));
        // Over the frontend's own regions the pointer is an arrow.
        if (hit != null) return setCursor(1);
        if (!p.url_hand) setCursor(9);
    }
    p.hover_at = .{ x, y };
    pointer_rules.panelHover(p, .{ x, y });
    if (p.panel_press) |*pp| {
        if (!pp.badge) pointer_rules.dragPanel(p, pp, x, y);
        return;
    }
    if (scrollbar.motion(app, p.surface_id, x, y)) return showUrlHand(p, false);
    const cp = app.corep orelse return;
    const name = claimName(p.claim.owner) orelse return updateUrlHand(p, cp, x, y);
    const c = pointer_rules.inPressGrid(p, x, y, true) orelse return;
    if (c.row == p.drag_row and c.col == p.drag_col) return;
    p.drag_row = c.row;
    p.drag_col = c.col;
    var mods: [5]u8 = undefined;
    const m = keymap.mouseModString(zwl_mods(), &mods);
    core.zonvie_core_send_mouse_input(cp, name, "drag", m.ptr, c.grid_id, c.row, c.col);
}

fn onPointerLeave(_: ?*anyopaque) callconv(.c) void {
    const app = window.app;
    const p = if (ext_window.pointer_target) |e| &e.pointer else &app.pointer;
    if (ext_window.pointer_target == null) chrome.leave(app);
    pointer_rules.panelLeft(p);
    scrollbar.leave(app, p.surface_id);
    showUrlHand(p, false);
}

/// The hand over a cell whose highlight carries a URL, as a click there
/// would name it. A busy core (-1) keeps the last answer.
fn updateUrlHand(p: *pointer_rules.Pointer, cp: *core.zonvie_core, x: f64, y: f64) void {
    if (pointer_rules.panelAt(p, x, y) != null) return showUrlHand(p, false);
    const c = pointer_rules.resolve(p, cp, x, y, 0) orelse return showUrlHand(p, false);
    const has = core.zonvie_core_try_cell_has_url(cp, c.grid_id, c.row, c.col);
    if (has >= 0) showUrlHand(p, has == 1);
}

fn showUrlHand(p: *pointer_rules.Pointer, on: bool) void {
    if (p.url_hand == on) return;
    p.url_hand = on;
    setCursor(if (on) 4 else 9);
}

/// The pointer's shape, a wp_cursor_shape_device_v1.shape.
fn setCursor(shape: c_int) void {
    zwl_cursor(shape);
    _ = zwl_flush();
}

/// The window edge under the pointer, as xdg_toplevel.resize_edge, where the
/// frontend draws its own frame and the window is free to be resized.
fn resizeEdge(app: *App) ?u32 {
    if (chrome.plan(app.titlebarLayout()).header == .desktop or zwl_placed() != 0) return null;
    const grip = 5.0;
    const x = pointer_win[0];
    const y = pointer_win[1];
    const w: f64 = @floatFromInt(window.w_logical);
    const h: f64 = @floatFromInt(window.h_logical);
    var edge: u32 = 0;
    if (y < grip) edge |= 1 else if (y >= h - grip) edge |= 2;
    if (x < grip) edge |= 4 else if (x >= w - grip) edge |= 8;
    return if (edge == 0) null else edge;
}

fn edgeCursor(edge: u32) c_int {
    return switch (edge) {
        1 => 19,
        2 => 22,
        4 => 25,
        8 => 18,
        5 => 21,
        9 => 20,
        6 => 24,
        10 => 23,
        else => 1,
    };
}

// The window's own requests, as chrome.zig asks for them (ui.zig window).

pub fn isMaximized() bool {
    return zwl_maximized() != 0;
}

pub fn toggleMaximize() void {
    zwl_toggle_maximize();
    _ = zwl_flush();
}

pub fn minimize() void {
    zwl_minimize();
    _ = zwl_flush();
}

/// The compositor moves the window with the pointer, from the press just seen.
pub fn beginMove() void {
    zwl_move();
    _ = zwl_flush();
}

pub fn closeWindow() void {
    onClose(null);
}

/// Brings the window back from the tray (tray.zig).
pub fn showWindow() void {
    if (!window.hidden or window.showing) return;
    window.showing = true;
    const app = window.app;
    var buf: [384]u8 = undefined;
    lock(app);
    const title = lifecycle.sessionTitle(&buf, app.title[0..app.title_len], app.session_name);
    unlock(app);
    zwl_show(app_id, title.ptr);
}

/// The app menu's Quit: a real close, tray or not.
pub fn quitApp() void {
    window.app.tray.quit_requested = true;
    onClose(null);
}

/// The chrome's share of the window changed: the view is laid out again.
pub fn relayout() void {
    if (window.configured) applyWindowSize(false);
}

pub fn rebuildChrome() void {
    shell.rebuild(window.app, true);
}

fn onPointerButton(_: ?*anyopaque, code: u32, pressed: c_int, mods_mask: u32) callconv(.c) void {
    const app = window.app;
    const ext = ext_window.pointer_target;
    const p = if (ext) |e| &e.pointer else &app.pointer;
    const cp = app.corep orelse return;
    const left = code == 0x110;
    if (pressed != 0) {
        // The frontend's own regions first, then the panels drawn over the
        // grids: neither press reaches Neovim.
        if (ext == null) if (uiHit(app)) |hit| {
            lock(app);
            const s = app.scale;
            unlock(app);
            shell.press(app, hit, @intFromFloat(@floor(pointer_win[0] * s)), @intFromFloat(@floor(pointer_win[1] * s)), left, code == 0x112);
            return;
        };
        // A window without the desktop's frame is resized by its own edges.
        if (left and ext == null) if (resizeEdge(app)) |edge| return zwl_resize(edge);
        if (pointer_rules.panelAt(p, p.x, p.y)) |h| return pointer_rules.pressPanel(p, h, left, p.x, p.y);
    } else if (left) {
        if (ext == null and chrome.release(app)) return;
        if (p.panel_press) |pp| {
            p.panel_press = null;
            return pointer_rules.releasePanel(p, pp, p.x, p.y);
        }
    }
    // The scrollbar takes a left press on it; Neovim never sees that one.
    if (code == 0x110) {
        if (pressed != 0 and p.claim.held_mask == 0 and scrollbar.press(app, p.surface_id, p.x, p.y)) {
            p.bar_held = true;
            return;
        }
        if (pressed == 0 and p.bar_held) {
            p.bar_held = false;
            _ = scrollbar.release(app, p.surface_id);
            return;
        }
    }
    const b = buttonOf(code) orelse return;
    var mods: [5]u8 = undefined;
    const m = keymap.mouseModString(mods_mask, &mods);
    if (pressed != 0) {
        const c = pointer_rules.resolve(p, cp, p.x, p.y, 0) orelse return;
        if (p.claim.press(b.claim)) {
            p.press_grid_id = c.grid_id;
            p.drag_row = c.row;
            p.drag_col = c.col;
        }
        core.zonvie_core_send_mouse_input(cp, b.name, "press", m.ptr, c.grid_id, c.row, c.col);
        return;
    }
    // Every sent press gets its release, to the claim's grid.
    if (!p.claim.release(b.claim).send) return;
    const c = pointer_rules.inPressGrid(p, p.x, p.y, false) orelse return;
    core.zonvie_core_send_mouse_input(cp, b.name, "release", m.ptr, c.grid_id, c.row, c.col);
}

/// A flick: the text keeps moving and slows down (trackpad.zig).
fn onPointerAxisStop(_: ?*anyopaque, vx: f64, vy: f64) callconv(.c) void {
    const app = window.app;
    const p = if (ext_window.pointer_target) |e| &e.pointer else &app.pointer;
    if (pointer_rules.panelAt(p, p.x, p.y) != null) return;
    trackpad.decelerate(p, vx, vy);
}

/// Touchpad px per wheel step over a message panel: about a text line.
const panel_step_px = 20.0;

/// One event per wheel step.
fn sendSteps(cp: *core.zonvie_core, c: pointer_rules.Cell, dir: [*:0]const u8, mods: [*:0]const u8, steps: i32) void {
    var i: u32 = 0;
    while (i < @min(16, @abs(steps))) : (i += 1) core.zonvie_core_send_mouse_scroll(cp, c.grid_id, c.row, c.col, dir, mods);
}

fn onPointerAxis(_: ?*anyopaque, dx: f64, dy: f64, steps_x: i32, steps_y: i32, mods_mask: u32) callconv(.c) void {
    const app = window.app;
    const p = if (ext_window.pointer_target) |e| &e.pointer else &app.pointer;
    const cp = app.corep orelse return;
    var mods: [5]u8 = undefined;
    const m = keymap.mouseModString(mods_mask, &mods);
    const sx = steps_x;
    const sy = steps_y;
    if (pointer_rules.panelAt(p, p.x, p.y)) |h| {
        // The panel's own grid: the core scrolls a message panel itself and
        // drops the wheel on the cmdline and popupmenu, so it never reaches
        // the buffer under them. A touchpad's pixels count a step a line.
        const py = if (sy != 0) sy else pixel_scroll.takeSteps(&p.scroll.v_acc, dy / panel_step_px);
        const px = if (sx != 0) sx else pixel_scroll.takeSteps(&p.scroll.h_acc, dx / panel_step_px);
        const c = h.cell();
        if (py != 0) sendSteps(cp, c, if (py > 0) "down" else "up", m.ptr, py);
        if (px != 0) sendSteps(cp, c, if (px > 0) "right" else "left", m.ptr, px);
        core_timers.scheduleMsg(app);
        return;
    }
    if (sx == 0 and sy == 0) {
        // A touchpad: its travel moves the text by the pixel (trackpad.zig).
        trackpad.scroll(p, cp, dx, dy, m.ptr);
        core_timers.scheduleMsg(app);
        return;
    }
    if (sy != 0) {
        // Vertical only: a float showing all its lines lets the wheel through.
        const c = pointer_rules.resolve(p, cp, p.x, p.y, 1) orelse return;
        sendSteps(cp, c, if (sy > 0) "down" else "up", m.ptr, sy);
    }
    if (sx != 0) {
        const c = pointer_rules.resolve(p, cp, p.x, p.y, 0) orelse return;
        sendSteps(cp, c, if (sx > 0) "right" else "left", m.ptr, sx);
    }
    // A scroll of a message float can be throttled into a message deadline.
    core_timers.scheduleMsg(app);
}

// =========================================================================
// File drops
// =========================================================================

/// One line of a text/uri-list as a path: a file:// URI, percent-decoded.
/// Null for a comment, another scheme, or a line that does not fit `buf`.
fn uriPath(buf: []u8, line: []const u8) ?[]const u8 {
    const prefix = "file://";
    if (!std.mem.startsWith(u8, line, prefix)) return null;
    // file://host/path: the path starts at the first slash after the host.
    const rest = line[prefix.len..];
    const path_at = std.mem.indexOfScalar(u8, rest, '/') orelse return null;
    var n: usize = 0;
    var i: usize = path_at;
    while (i < rest.len) : (i += 1) {
        if (n == buf.len) return null;
        if (rest[i] == '%' and i + 2 < rest.len) {
            if (std.fmt.parseInt(u8, rest[i + 1 .. i + 3], 16)) |byte| {
                buf[n] = byte;
                n += 1;
                i += 2;
                continue;
            } else |_| {}
        }
        buf[n] = rest[i];
        n += 1;
    }
    return buf[0..n];
}

/// Dropped files open in Neovim, or in the command line and a terminal go in
/// as their escaped paths.
fn onDrop(_: ?*anyopaque, uri_list: [*]const u8, len: usize) callconv(.c) void {
    const app = window.app;
    const cp = app.corep orelse return;
    var arena = std.heap.ArenaAllocator.init(app.alloc);
    defer arena.deinit();
    const a = arena.allocator();
    var paths: std.ArrayListUnmanaged([]const u8) = .empty;
    var lines = std.mem.tokenizeAny(u8, uri_list[0..len], "\r\n");
    while (lines.next()) |line| {
        const buf = a.alloc(u8, line.len) catch return;
        const path = uriPath(buf, line) orelse continue;
        paths.append(a, path) catch return;
    }
    if (paths.items.len == 0) return;

    const mode = std.mem.span(core.zonvie_core_get_current_mode(cp));
    if (core.frontend_rules.dropInsertsPath(mode, false, false)) {
        var line: std.ArrayListUnmanaged(u8) = .empty;
        for (paths.items) |path| {
            const buf = a.alloc(u8, 2 * path.len + 1) catch return;
            const esc = core.frontend_rules.escapePathForCmdline(buf, path, false) orelse continue;
            if (line.items.len != 0) line.append(a, ' ') catch return;
            line.appendSlice(a, esc) catch return;
        }
        if (line.items.len != 0) core.zonvie_core_send_input(cp, line.items.ptr, @intCast(line.items.len));
        return;
    }
    // Unescaped: the server escapes each with its own fnameescape().
    const ptrs = a.alloc([*]const u8, paths.items.len) catch return;
    const lens = a.alloc(usize, paths.items.len) catch return;
    for (paths.items, ptrs, lens) |path, *pp, *l| {
        pp.* = path.ptr;
        l.* = path.len;
    }
    core.zonvie_core_drop_paths(cp, ptrs.ptr, lens.ptr, paths.items.len, 0);
}

const listener: Listener = .{
    .configure = &onConfigure,
    .close = &onClose,
    .focus = &onFocus,
    .key = &onKey,
    .frame = &onFrame,
    .pointer_motion = &onPointerMotion,
    .pointer_leave = &onPointerLeave,
    .pointer_button = &onPointerButton,
    .pointer_axis = &onPointerAxis,
    .pointer_axis_stop = &onPointerAxisStop,
    .ime_preedit = &onImePreedit,
    .ime_commit = &onImeCommit,
    .keys_reset = &onKeysReset,
    .drop = &onDrop,
    .ext_configure = &onExtConfigure,
    .ext_close = &onExtClose,
    .ext_frame = &onExtFrame,
    .pointer_window = &onPointerWindow,
};

// wl/window.c's further windows: an external window by its grid's id, a
// panel's popup by a negative one (panel_popup.kindOfId).

fn onExtConfigure(_: ?*anyopaque, id: i64, w: i32, h: i32) callconv(.c) void {
    if (panel_popup.kindOfId(id)) |kind| return panel_popup.onConfigure(window.app, kind);
    ext_window.onConfigure(window.app, id, w, h);
    panel_popup.update(window.app);
}

fn onExtClose(_: ?*anyopaque, id: i64) callconv(.c) void {
    if (panel_popup.kindOfId(id)) |kind| return panel_popup.onDismissed(window.app, kind);
    ext_window.onClose(window.app, id);
}

fn onExtFrame(_: ?*anyopaque, id: i64) callconv(.c) void {
    if (panel_popup.kindOfId(id)) |kind| return panel_popup.onFrame(window.app, kind);
    ext_window.onFrame(window.app, id);
}

/// The popup the pointer is in: its events are its host's, at the place
/// the panel was laid out there (panel_popup.toHost).
var pointer_popup: ?overlay_layout.Kind = null;

fn onPointerWindow(_: ?*anyopaque, id: i64) callconv(.c) void {
    pointer_popup = panel_popup.kindOfId(id);
    if (pointer_popup == null) ext_window.onPointerWindow(window.app, id);
}

fn onWayland(_: c_int, _: c_uint, _: ?*anyopaque) callconv(.c) c_int {
    if (zwl_dispatch() < 0) g_main_loop_quit(window.loop);
    _ = zwl_flush();
    return 1;
}

/// Ends the loop: Neovim exited. main thread. ui.zig's quit.
pub fn quit(app: *App) void {
    _ = app;
    g_main_loop_quit(window.loop);
}

// =========================================================================
// Entry point
// =========================================================================

/// The connection dialog: this executable as a form, started from `seed`.
/// Null when it was cancelled. The answer's slices are `a`'s.
fn runConnectDialog(a: std.mem.Allocator, seed: form.Connect) ?form.Connect {
    var exe: [std.fs.max_path_bytes:0]u8 = undefined;
    const n = std.c.readlink("/proc/self/exe", &exe, exe.len - 1);
    if (n <= 0) return null;
    exe[@intCast(n)] = 0;
    var result_buf: [std.fs.max_path_bytes]u8 = undefined;
    const result = form.tempPath(&result_buf, "connect") orelse return null;
    var seed_buf: [std.fs.max_path_bytes]u8 = undefined;
    const seed_path = std.fmt.bufPrintZ(&seed_buf, "{s}.seed", .{result}) catch return null;
    const text = std.fmt.allocPrint(a, "mode={s}\nname={s}\nnvim={s}\nssh_host={s}\nssh_identity={s}\ndc_workspace={s}\ndc_config={s}\ndc_rebuild={d}\n", .{
        seed.mode, seed.name, seed.nvim, seed.ssh_host, seed.ssh_identity, seed.dc_workspace, seed.dc_config, @intFromBool(seed.dc_rebuild),
    }) catch return null;
    _ = form.writeFile(seed_path, text);
    form.remove(result);
    _ = cli.setenv(form.env_kind, "connect", 1);
    _ = cli.setenv(form.env_result, result.ptr, 1);
    const pid = fork();
    if (pid == 0) {
        const argv = [_:null]?[*:0]const u8{&exe};
        _ = execvp(&exe, &argv);
        _exit(127);
    }
    _ = cli.unsetenv(form.env_kind);
    _ = cli.unsetenv(form.env_result);
    if (pid < 0) return null;
    var status: c_int = 0;
    while (waitpid(pid, &status, 0) < 0) {}
    const answer = form.readFile(a, result) orelse return null;
    form.remove(result);
    return form.Connect.parse(answer);
}

/// A wrong option: on stderr, where a terminal start shows it.
fn optionError(msg: []const u8) u8 {
    std.debug.print("{s}\n", .{msg});
    return 1;
}

fn appendArg(list: *std.ArrayListUnmanaged(u8), alloc: std.mem.Allocator, arg: []const u8) ?u8 {
    cli.appendSpawnArg(list, alloc, arg) catch |e| {
        if (e != error.Unquotable) return 1;
        std.debug.print("zonvie: this argument cannot be passed to nvim (a space together with both quote kinds, or a trailing backslash): {s}\n", .{arg});
        return 1;
    };
    return null;
}

/// What the core is started with, set by main before the window exists.
const Start = struct {
    alloc: std.mem.Allocator,
    nvim_cmd: [:0]const u8,
    connect_addr: ?[]const u8,
    nofork: bool,
    ext_cmdline: bool,
    ext_popupmenu: bool,
    ext_messages: bool,
    ext_tabline: bool,
    ext_windows: bool,
};
var start: Start = undefined;

/// Creates the core and starts Neovim (or connects to one), attached at the
/// start size; the first configure corrects it. False when it did not start,
/// the reason on stderr.
/// Stops the core and joins its threads, so that no callback runs while or
/// after the app is torn down (zonvie_core.h zonvie_core_destroy). Main
/// thread, outside any callback; a second call does nothing.
fn stopCore(app: *App) void {
    const cp = app.corep orelse return;
    // A core thread waiting on the clipboard would hold the join back.
    callbacks.abandonClipboardWait(app);
    core.zonvie_core_destroy(cp);
    app.corep = null;
}

fn startCore(app: *App) bool {
    var cb = callbacks.makeCallbacks();
    app.corep = core.zonvie_core_create(&cb, @sizeOf(core.Callbacks), app);
    const cp = app.corep orelse return false;
    if (config_mod.getConfigFilePath(start.alloc)) |path| {
        defer start.alloc.free(path);
        if (start.alloc.dupeZ(u8, path)) |z| {
            defer start.alloc.free(z);
            _ = core.zonvie_core_load_config(cp, z.ptr);
        } else |_| {}
    } else |_| {}
    core.zonvie_core_set_log_enabled(cp, @intFromBool(applog.isEnabled()));
    if (applog.isVerbose()) core.zonvie_core_set_log_verbose(cp, 1);
    if (app.log_perf_only) core.zonvie_core_set_log_perf_only(cp, 1);
    if (app.log_scroll_only) core.zonvie_core_set_log_scroll_only(cp, 1);
    core.zonvie_core_set_background_opacity(cp, app.window_cfg.opacity);
    core.zonvie_core_set_blur_enabled(cp, @intFromBool(app.window_cfg.blur));
    // Started from a shell that waits (--nofork), Neovim keeps the directory
    // its arguments are relative to.
    if (start.nofork) core.zonvie_core_set_inherit_cwd(cp, 1);
    if (start.ext_cmdline) core.zonvie_core_set_ext_cmdline(cp, 1);
    if (start.ext_popupmenu) core.zonvie_core_set_ext_popupmenu(cp, 1);
    if (start.ext_messages) core.zonvie_core_set_ext_messages(cp, 1);
    if (start.ext_tabline) core.zonvie_core_set_ext_tabline(cp, 1);
    if (start.ext_windows) core.zonvie_core_set_ext_windows(cp, 1);
    lock(app);
    if (app.drawable_w_px == 0 or app.drawable_h_px == 0) {
        app.drawable_w_px = @intCast(window.free_w * window.scale);
        app.drawable_h_px = @intCast(window.free_h * window.scale);
    }
    const w_px = app.drawable_w_px;
    const h_px = app.drawable_h_px;
    // Before the faces gave a cell there is only Neovim's own default.
    const g: scrollbar.Grid = if (app.cell_w_px != 0 and app.cell_h_px != 0)
        scrollbar.gridFor(app.scrollbar_cfg, w_px, h_px, app.cell_w_px, app.cell_h_px, app.scale)
    else
        .{ .rows = 24, .cols = 80 };
    const rows = g.rows;
    const cols = g.cols;
    unlock(app);
    const rc = if (start.connect_addr) |addr|
        core.zonvie_core_start_connect(cp, addr.ptr, addr.len, rows, cols)
    else
        core.zonvie_core_start(cp, start.nvim_cmd.ptr, rows, cols);
    if (rc != 0) {
        std.debug.print("zonvie: {s} (rc={d})\n", .{ cli.startFailureReason(rc), rc });
        return false;
    }
    pushLayout(app);
    return true;
}

/// `devcontainer up` ended: Neovim is started in the container it brought
/// up, or the window closes with the reason on stderr.
fn onDevcontainerUp(pid: c_int, status: c_int, _: ?*anyopaque) callconv(.c) void {
    _ = pid;
    const app = window.app;
    if (status != 0) {
        std.debug.print("zonvie: devcontainer up failed\n", .{});
        return g_main_loop_quit(window.loop);
    }
    app.progress = "Connecting to devcontainer...";
    shell.rebuild(app, true);
    if (!startCore(app)) g_main_loop_quit(window.loop);
}

/// The form's Neovim has quit: its answer goes where the form was asked
/// for. The exit code is the process's.
fn finishForm(a: std.mem.Allocator, kind: form.Kind, result_path: ?[:0]const u8, script_path: ?[:0]const u8) u8 {
    if (script_path) |p| form.remove(p);
    const path = result_path orelse return 0;
    switch (kind) {
        // ssh reads the password from stdout; no answer is a cancel.
        .secret => {
            const text = form.readFile(a, path) orelse return 1;
            form.remove(path);
            var rest: []const u8 = text;
            while (rest.len > 0) {
                const n = std.c.write(1, rest.ptr, rest.len);
                if (n <= 0) return 1;
                rest = rest[@intCast(n)..];
            }
            _ = std.c.write(1, "\n", 1);
            return 0;
        },
        // The connection dialog's answer is read by the process that asked.
        .connect, .message => return 0,
    }
}

extern "c" fn fork() c_int;
extern "c" fn execvp(file: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) c_int;
extern "c" fn waitpid(pid: c_int, status: *c_int, options: c_int) c_int;
extern "c" fn _exit(code: c_int) noreturn;
extern "c" fn g_child_watch_add(pid: c_int, func: *const fn (c_int, c_int, ?*anyopaque) callconv(.c) void, data: ?*anyopaque) c_uint;

pub fn main(init: std.process.Init.Minimal) u8 {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();
    var args_arena = std.heap.ArenaAllocator.init(alloc);
    defer args_arena.deinit();
    const aa = args_arena.allocator();
    const args = init.args.toSlice(aa) catch return 1;

    if (cli.hasFlag(args, "--help") or cli.hasFlag(args, "-h")) {
        cli.printHelp();
        return 0;
    }
    if (cli.hasFlag(args, "--version")) {
        cli.printVersion();
        return 0;
    }
    // This executable as a form (form.zig): ssh's password prompt, the
    // connection dialog, the crash report. Its markers go before anything is
    // spawned, so nothing below inherits the mode.
    const form_kind = form.requested();
    var form_result_buf: [std.fs.max_path_bytes]u8 = undefined;
    var form_script_buf: [std.fs.max_path_bytes]u8 = undefined;
    var form_result: ?[:0]const u8 = null;
    var form_script: ?[:0]const u8 = null;
    if (form_kind) |kind| {
        form_result = if (std.c.getenv(form.env_result)) |p|
            std.fmt.bufPrintZ(&form_result_buf, "{s}", .{std.mem.span(p)}) catch null
        else
            form.tempPath(&form_result_buf, "answer");
        form_script = form.tempPath(&form_script_buf, "form.lua");
        var seed: form.Connect = .{};
        var seed_buf: [std.fs.max_path_bytes]u8 = undefined;
        if (kind == .connect) if (form_result) |r| if (std.fmt.bufPrintZ(&seed_buf, "{s}.seed", .{r}) catch null) |sp| {
            if (form.readFile(aa, sp)) |text| seed = form.Connect.parse(text);
            form.remove(sp);
        };
        const text: []const u8 = if (args.len > 1 and kind != .connect) args[1] else if (kind == .secret) "Password:" else "";
        const lua = form.script(aa, kind, text, form_result orelse "", seed) catch return 1;
        if (form_script == null or !form.writeFile(form_script.?, lua)) return 1;
        for ([_][*:0]const u8{ form.env_kind, form.env_result, form.env_askpass, form.env_crash }) |name| _ = cli.unsetenv(name);
    }
    const nofork = cli.hasFlag(args, "--nofork") or form_kind != null;
    // Attaching to a server never forks: its failures must reach the shell's
    // exit code. Nor does a launch with no terminal to leave. Before any
    // thread exists.
    const connects = cli.hasPrefix(args, "--connect-nvim") or cli.hasPrefix(args, "--remote-ui");
    if (!nofork and !connects and std.c.isatty(0) != 0 and cli.detach()) return 0;

    clock.init();
    if (cli.hasFlag(args, "--install")) return cli.install(alloc);
    // First launch: the default config and the desktop entry. An existing
    // desktop entry is kept.
    if (config_mod.getConfigFilePath(alloc)) |p| alloc.free(p) else |_| cli.installFirstLaunch(alloc);
    // A launcher start has no shell behind it: take the login shell's
    // environment (PATH for LSPs and the like).
    if (std.c.getenv("TERM") == null) cli.importLoginShellEnv(alloc);
    _ = cli.setenv("CLAUDE_CODE_NATIVE_CURSOR", "1", 1);

    var config = config_mod.load(alloc);
    defer config.deinit();

    const config_nvim = cli.nvimPath(config.neovim.path);
    var nvim_path: []const u8 = if (config_nvim.path.len > 0) config_nvim.path else "nvim";
    var cli_nvim_path: ?[]const u8 = null;
    var log_path: ?[]const u8 = null;
    var ext_cmdline = config.cmdline.external;
    var ext_popupmenu = config.popup.external;
    var ext_messages = config.messages.external;
    var ext_tabline = config.tabline.external;
    var ext_windows = config.windows.external;
    var connect_addr: ?[]const u8 = null;
    var ssh: ?cli.Ssh = if (config.neovim.ssh) if (config.neovim.ssh_host) |h| cli.Ssh{ .host = h, .port = config.neovim.ssh_port, .identity = config.neovim.ssh_identity } else null else null;
    var ssh_identity: ?[]const u8 = config.neovim.ssh_identity;
    var devcontainer: ?cli.Devcontainer = null;
    var devcontainer_config: ?[]const u8 = null;
    var devcontainer_rebuild = false;
    var extra: std.ArrayListUnmanaged([]const u8) = .empty;
    // The file arguments among them, absolute: what a second launch hands a
    // running instance under [server] single_instance.
    var files: std.ArrayListUnmanaged([:0]const u8) = .empty;
    var dialog = false;
    var i: usize = if (form_kind != null) args.len else 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        const next: ?[]const u8 = if (i + 1 < args.len) args[i + 1] else null;
        if (std.mem.eql(u8, arg, "--")) {
            // Everything after is nvim's own command line.
            var scan: core.frontend_rules.NvimArgScan = .{};
            for (args[i + 1 ..]) |a| {
                if (!scan.isFile(a)) {
                    extra.append(aa, a) catch return 1;
                    continue;
                }
                const abs = cli.absolutePath(aa, a) catch return 1;
                extra.append(aa, abs) catch return 1;
                files.append(aa, aa.dupeZ(u8, abs) catch return 1) catch return 1;
            }
            break;
        } else if (std.mem.eql(u8, arg, "--nvim") and next != null) {
            i += 1;
            cli_nvim_path = args[i];
        } else if (std.mem.startsWith(u8, arg, "--nvim=")) {
            cli_nvim_path = arg["--nvim=".len..];
        } else if (std.mem.startsWith(u8, arg, "--ssh=")) {
            const t = core.frontend_rules.sshTarget(arg["--ssh=".len..]);
            ssh = .{ .host = t.host, .port = t.port };
        } else if (std.mem.eql(u8, arg, "--ssh")) {
            if (core.frontend_rules.cliNextIsValue(next)) {
                i += 1;
                const t = core.frontend_rules.sshTarget(args[i]);
                ssh = .{ .host = t.host, .port = t.port };
            }
        } else if (std.mem.startsWith(u8, arg, "--ssh-identity=")) {
            ssh_identity = arg["--ssh-identity=".len..];
        } else if (std.mem.eql(u8, arg, "--ssh-identity")) {
            if (core.frontend_rules.cliNextIsValue(next)) {
                i += 1;
                ssh_identity = args[i];
            }
        } else if (std.mem.startsWith(u8, arg, "--devcontainer=")) {
            devcontainer = .{ .workspace = arg["--devcontainer=".len..] };
        } else if (std.mem.eql(u8, arg, "--devcontainer")) {
            if (core.frontend_rules.cliNextIsValue(next)) {
                i += 1;
                devcontainer = .{ .workspace = args[i] };
            }
        } else if (std.mem.startsWith(u8, arg, "--devcontainer-config=")) {
            devcontainer_config = arg["--devcontainer-config=".len..];
        } else if (std.mem.eql(u8, arg, "--devcontainer-config")) {
            if (core.frontend_rules.cliNextIsValue(next)) {
                i += 1;
                devcontainer_config = args[i];
            }
        } else if (std.mem.eql(u8, arg, "--devcontainer-rebuild")) {
            devcontainer_rebuild = true;
        } else if (std.mem.eql(u8, arg, "--extcmdline")) {
            ext_cmdline = true;
        } else if (std.mem.eql(u8, arg, "--extpopup") or std.mem.eql(u8, arg, "--extpopupmenu")) {
            ext_popupmenu = true;
        } else if (std.mem.eql(u8, arg, "--extmessages")) {
            ext_messages = true;
        } else if (std.mem.eql(u8, arg, "--exttabline")) {
            ext_tabline = true;
        } else if (std.mem.eql(u8, arg, "--extwindows")) {
            ext_windows = true;
        } else if (std.mem.startsWith(u8, arg, "--connect-nvim=")) {
            connect_addr = arg["--connect-nvim=".len..];
        } else if (std.mem.startsWith(u8, arg, "--remote-ui=")) {
            connect_addr = arg["--remote-ui=".len..];
        } else if (std.mem.eql(u8, arg, "--connect-nvim") or std.mem.eql(u8, arg, "--remote-ui")) {
            // Bare, it is still this option: never nvim's argument.
            connect_addr = if (next != null) blk: {
                i += 1;
                break :blk args[i];
            } else "";
        } else if (std.mem.eql(u8, arg, "--log") and next != null) {
            i += 1;
            log_path = args[i];
        } else if (std.mem.eql(u8, arg, "--dialog")) {
            dialog = true;
        } else if (std.mem.startsWith(u8, arg, "--renderer=")) {
            // Taken and ignored, so that an older command line still starts:
            // there is one renderer.
        } else if (std.mem.eql(u8, arg, "--nofork") or std.mem.eql(u8, arg, "--install")) {
            // Handled above.
        } else {
            const fwd = cli.absoluteFileArg(aa, args[i - 1], arg, false) catch return 1;
            extra.append(aa, fwd) catch return 1;
            if (core.frontend_rules.nvimArgIsFile(args[i - 1], arg, false)) files.append(aa, aa.dupeZ(u8, fwd) catch return 1) catch return 1;
        }
    }
    applog.setVerbose(config.log.verbose and !config.log.perf_only and !config.log.scroll_only);
    applog.setFilters(config.log.perf_only, config.log.scroll_only);
    // --log wins over [log]; [log] enabled without a path logs to stderr.
    if (log_path) |p| {
        applog.setEnabled(true);
        applog.setLogPath(p);
    } else if (config.log.enabled) {
        applog.setEnabled(true);
        applog.setLogPath(config.log.path);
    }
    defer applog.deinit();

    if (cli_nvim_path) |raw| {
        const p = cli.nvimPath(raw);
        cli_nvim_path = if (p.path.len != 0) p.path else null;
        if (cli_nvim_path) |v| nvim_path = v;
    }
    if (dialog and connect_addr != null) {
        return optionError("--dialog chooses the connection, so it cannot be combined with --connect-nvim. Remove the conflicting option and retry.");
    }
    var session_name_override: []const u8 = "";
    if (dialog) {
        // The CLI and config seed the dialog; its answer replaces them. The
        // dialog is this executable again, as a form.
        const answer = runConnectDialog(aa, .{
            .mode = if (ssh != null) "ssh" else if (devcontainer != null) "devcontainer" else "local",
            .nvim = cli_nvim_path orelse "",
            .ssh_host = if (ssh) |s| s.host else "",
            .ssh_identity = ssh_identity orelse "",
            .dc_workspace = if (devcontainer) |d| d.workspace else "",
            .dc_config = devcontainer_config orelse "",
            .dc_rebuild = devcontainer_rebuild,
        }) orelse return 0;
        session_name_override = answer.name;
        if (answer.nvim.len != 0) cli_nvim_path = answer.nvim;
        ssh = null;
        devcontainer = null;
        if (std.mem.eql(u8, answer.mode, "ssh") and answer.ssh_host.len != 0) {
            const t = core.frontend_rules.sshTarget(answer.ssh_host);
            ssh = .{ .host = t.host, .port = t.port };
            ssh_identity = if (answer.ssh_identity.len != 0) answer.ssh_identity else null;
        } else if (std.mem.eql(u8, answer.mode, "devcontainer") and answer.dc_workspace.len != 0) {
            devcontainer = .{ .workspace = answer.dc_workspace };
            devcontainer_config = if (answer.dc_config.len != 0) answer.dc_config else null;
            devcontainer_rebuild = answer.dc_rebuild;
        }
    }
    if (connect_addr) |a| if (a.len == 0) {
        return optionError("zonvie: --connect-nvim / --remote-ui requires a non-empty address (e.g. /tmp/nvim.sock or 127.0.0.1:6789).");
    };
    if (@as(u8, @intFromBool(ssh != null)) + @intFromBool(connect_addr != null) + @intFromBool(devcontainer != null) > 1) {
        return optionError("--connect-nvim, --ssh (or [neovim] ssh in config.toml) and --devcontainer are mutually exclusive. Remove the conflicting option and retry.");
    }

    // --ssh: nvim runs on the host, and --nvim names the remote executable;
    // local file arguments do not apply there.
    var dc_up_argv: ?[*:null]const ?[*:0]const u8 = null;
    const nvim_cmd: [:0]const u8 = if (form_kind != null) blk: {
        // A plain Neovim that runs the form's Lua and nothing of the user's.
        var cmd: std.ArrayListUnmanaged(u8) = .empty;
        if (appendArg(&cmd, aa, nvim_path)) |rc| return rc;
        for ([_][]const u8{ "-u", "NONE", "-i", "NONE", "-n", "--cmd" }) |a| if (appendArg(&cmd, aa, a)) |rc| return rc;
        const run = std.fmt.allocPrint(aa, "luafile {s}", .{form_script.?}) catch return 1;
        if (appendArg(&cmd, aa, run)) |rc| return rc;
        break :blk aa.dupeZ(u8, cmd.items) catch return 1;
    } else if (ssh) |s| blk: {
        var target = s;
        target.identity = ssh_identity;
        // A password or a passphrase is asked for by this executable, as a
        // form (form.zig).
        cli.setAskpassEnv(form.env_askpass);
        break :blk cli.sshCommand(aa, target, cli_nvim_path orelse "nvim") catch return 1;
    } else if (devcontainer) |d| blk: {
        const target: cli.Devcontainer = .{
            .workspace = cli.expandTilde(aa, d.workspace) catch return 1,
            .config = if (devcontainer_config) |c| cli.expandTilde(aa, c) catch return 1 else null,
            .rebuild = devcontainer_rebuild,
        };
        if (devcontainer_rebuild) dc_up_argv = cli.devcontainerUpArgv(aa, target, cli.nvimConfigDir(aa) catch return 1) catch return 1;
        break :blk cli.devcontainerCommand(aa, target) catch return 1;
    } else blk: {
        var cmd: std.ArrayListUnmanaged(u8) = .empty;
        if (appendArg(&cmd, aa, nvim_path)) |rc| return rc;
        // An empty argument has no token; the tokenizer always dropped it.
        for (extra.items) |a| if (a.len != 0) if (appendArg(&cmd, aa, a)) |rc| return rc;
        break :blk aa.dupeZ(u8, cmd.items) catch return 1;
    };
    // Without [server] single_instance each process owns its own nvim. With
    // it, a local launch hands its files to the instance that listens, if
    // one does, and ends here.
    const single = config.server.single_instance and form_kind == null and !dialog and ssh == null and connect_addr == null and devcontainer == null;
    if (single and single_instance.forward(files.items)) return 0;

    const start_kind: lifecycle.StartKind = if (ssh != null) .ssh else if (connect_addr != null) .connect else if (devcontainer != null) .devcontainer else .local;
    var name_buf: [256]u8 = undefined;
    const session_name = if (session_name_override.len != 0)
        session_name_override
    else
        aa.dupe(u8, lifecycle.defaultSessionName(&name_buf, start_kind, if (ssh) |s| s.host else if (devcontainer) |d| d.workspace else "")) catch "";

    const app = alloc.create(App) catch return 1;
    defer alloc.destroy(app);
    app.* = .{
        .alloc = alloc,
        .large_jump = config.scroll.large_jump_behavior,
        .font_cfg = config.font,
        .msg_pos = config.messages.msg_pos,
        .input_cfg = config.input,
        .window_cfg = config.window,
        .scrollbar_cfg = config.scrollbar,
        .tabline_cfg = config.tabline,
        .ext_cmdline = ext_cmdline,
        .ext_tabline = ext_tabline,
        .copy_cmdline = config.cmdline.copy_button,
        .copy_messages = config.messages.copy_button,
        .log_perf_only = config.log.perf_only,
        .log_scroll_only = config.log.scroll_only,
        .shader_paths = if (config.shaders.enabled) config.shaders.paths else &.{},
        .shader_preserve_alpha = config.shaders.preserve_alpha,
        .shader_epoch_ns = clock.nowNs(),
        .cell_age = core.cell_age_store.Stores.init(alloc),
        .cell_text = core.cell_text_store.Stores.init(alloc),
        .session_name = session_name,
        .start_kind = start_kind,
        .open_mode_current = std.mem.eql(u8, config.server.open_mode, "current"),
    };
    defer app.deinit();
    // Before the app goes: the core's threads call back into it.
    defer stopCore(app);
    if (single) single_instance.serve(app);
    defer single_instance.stop();
    app.pointer = .{ .app = app };

    if (zwl_open(&listener, null) != 0) {
        std.debug.print("zonvie: no Wayland compositor\n", .{});
        return 1;
    }
    const scale = zwl_scale();
    const loop = g_main_loop_new(null, 0) orelse return 1;
    window = .{ .app = app, .loop = loop, .scale = scale };
    if (config.server.close_to_tray and form_kind == null) app.close_to_tray = tray.init(app);
    // "native" keeps the desktop's title bar: where the compositor has no
    // way to draw one (GNOME) or draws none (tiling ones), it acts as
    // "hidden" (chrome.effectiveStyle).
    app.desktop_titlebar = zwl_server_decorations() != 0 and
        chrome.desktopDrawsTitlebar(if (std.c.getenv("XDG_CURRENT_DESKTOP")) |v| std.mem.span(v) else null);
    if (window_state.restored()) |s| {
        window.free_w = s.size[0];
        window.free_h = s.size[1];
    }
    app.scale = @floatFromInt(scale);

    start = .{
        .alloc = alloc,
        .nvim_cmd = nvim_cmd,
        .connect_addr = connect_addr,
        .nofork = nofork or form_kind != null,
        .ext_cmdline = ext_cmdline,
        .ext_popupmenu = ext_popupmenu,
        .ext_messages = ext_messages,
        .ext_tabline = ext_tabline,
        .ext_windows = ext_windows,
    };
    const w_px: u32 = @intCast(window.free_w * scale);
    const h_px: u32 = @intCast(window.free_h * scale);
    // The faces now: the outputs' scale is known since zwl_open, so they are
    // loaded once, at the size they are drawn at.
    callbacks.ensureFont(app);
    app.progress = if (devcontainer != null)
        (if (dc_up_argv != null) "Building devcontainer..." else "Connecting to devcontainer...")
    else
        lifecycle.revealText(start_kind) orelse "";
    crash.is_form = form_kind != null;
    // The core and Neovim first: Neovim loads while the window and its GL
    // context come up. A container that is rebuilt first has no Neovim to
    // start yet: that start follows `devcontainer up` (onDevcontainerUp).
    if (dc_up_argv == null and !startCore(app)) return 1;

    // The desktop's own title bar only where the layout leaves the caption
    // to it; with a header of its own the window asks for none.
    const desktop_header = chrome.plan(app.titlebarLayout()).header == .desktop;
    if (zwl_window(app_id, "zonvie", @intFromBool(desktop_header)) != 0) return 1;
    zwl_set_buffer_scale(scale);
    if (app.window_cfg.blur) zwl_blur();
    if (zwl_egl_init(@intCast(w_px), @intCast(h_px)) != 0) {
        std.debug.print("zonvie: no OpenGL 3.3 context\n", .{});
        return 1;
    }
    if (!gl_renderer.realize(&app.gl)) return 1;
    panel_popup.init(app);
    if (dc_up_argv) |argv| {
        const pid = fork();
        if (pid == 0) {
            _ = execvp(argv[0].?, argv);
            _exit(127);
        }
        if (pid < 0) return optionError("zonvie: devcontainer up could not be started");
        _ = g_child_watch_add(pid, &onDevcontainerUp, null);
    }

    _ = g_unix_fd_add(zwl_fd(), G_IO_IN, &onWayland, null);
    if (std.c.getenv("ZONVIE_TEST_FULL_REDRAW")) |v| {
        if (std.mem.eql(u8, std.mem.span(v), "1")) _ = g_unix_signal_add(@intFromEnum(std.posix.SIG.USR2), &onTestFullRedraw, app);
    }
    pump();
    g_main_loop_run(loop);
    stopCore(app);
    panel_popup.deinit(app);
    ext_window.closeAll(app);
    if (form_kind) |kind| return finishForm(aa, kind, form_result, form_script);
    // The size for the next run, unless the compositor chose it (a tile, a
    // maximized or fullscreen window): that one keeps the last free size.
    if (window.shown and zwl_placed() == 0 and window.w_logical > 0 and window.h_logical > 0) {
        window_state.store(.{ .size = .{ window.w_logical, window.h_logical } });
    }
    return 0;
}
