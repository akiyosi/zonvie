const std = @import("std");
const core = @import("zonvie_core");
const clock = core.clock;
const callbacks = @import("callbacks.zig");
const App = @import("app.zig").App;
const gl_renderer = @import("renderer/gl_renderer.zig");
const postfx = @import("renderer/postfx.zig");
const gtk = @import("gtk_bindings.zig");
const input = @import("input.zig");
const applog = @import("app_log.zig");
const config_mod = @import("config.zig");
const ui_widgets = @import("ui_widgets.zig");
const ext_window = @import("ext_window.zig");
const latency_bench = @import("latency_bench.zig");
const render_thread = @import("render_thread.zig");
const panel_popup = @import("panel_popup.zig");
const blink = @import("blink.zig");
const cli = @import("cli.zig");
const askpass = @import("askpass.zig");
const connect_dialog = @import("connect_dialog.zig");
const window_size = @import("window_size.zig");
const x11_place = @import("x11_place.zig");
const blur = @import("blur.zig");
const scrollbar = @import("scrollbar.zig");
const session = @import("session.zig");
const lifecycle = @import("lifecycle.zig");
const tray = @import("tray.zig");
const crash = @import("crash.zig");

/// Panics reach the log and, without a terminal, a crash file and an alert.
pub const panic = std.debug.FullPanic(crash.onPanic);

const default_w_logical = 1000;
const default_h_logical = 700;
const layout_retry_ms = 8;

const Startup = struct {
    /// Tokenized by the core (rpc_session.zig tokenizeCommand).
    nvim_cmd: [:0]const u8,
    /// --connect-nvim / --remote-ui: attach to this running server instead
    /// of spawning nvim.
    connect_addr: ?[]const u8 = null,
    /// ext_* UI extensions: config.toml's `external` keys, or a CLI flag.
    ext_cmdline: bool = false,
    ext_popupmenu: bool = false,
    ext_messages: bool = false,
    ext_tabline: bool = false,
    ext_windows: bool = false,
    /// --renderer=thread: draw the main window on a render thread into
    /// dmabufs; the GLArea otherwise, and when that is unavailable.
    threaded: bool = false,
    /// --nofork: nvim keeps the shell's cwd; otherwise the core starts it
    /// in $HOME, as on macOS.
    inherit_cwd: bool = false,
    /// Shown over the window until the first frame (a devcontainer start).
    progress: ?[:0]const u8 = null,
    /// `devcontainer up`'s argv, run before the core starts (a rebuild);
    /// `nvim_cmd` then execs into the container it brought up.
    dc_up_argv: ?[*:null]const ?[*:0]const u8 = null,
    /// The window waits for Neovim's first frame (SSH, --connect-nvim): an
    /// SSH password is asked in a window of its own (askpass.zig).
    hide_until_ready: bool = false,
    /// The connection dialog's "Name", else one from the connection.
    session_name: []const u8 = "",
};

fn appFrom(data: ?*anyopaque) *App {
    return @ptrCast(@alignCast(data.?));
}

fn lock(app: *App) void {
    app.mu.lockUncancelable(clock.io());
}

fn unlock(app: *App) void {
    app.mu.unlock(clock.io());
}

// =========================================================================
// GLArea
// =========================================================================

fn onRealize(widget: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const app = appFrom(data);
    const area = widget.?;
    gtk.gtk_gl_area_make_current(area);
    if (gtk.gtk_gl_area_get_error(area) != null) {
        applog.appLog("[linux] GLArea realize error\n", .{});
        return;
    }
    // A realize after an unrealize leaves the texture empty; the next render
    // rebuilds it from the CPU atlas mirror (gl_renderer.drainAtlas).
    if (!gl_renderer.realize(&app.gl)) return;
    if (app.gl_realized_once) return;
    app.gl_realized_once = true;
    startCore(app, area);
}

fn onUnrealize(widget: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    gtk.gtk_gl_area_make_current(widget.?);
    const app = appFrom(data);
    postfx.unrealize(&app.postfx);
    gl_renderer.unrealize(&app.gl);
}

fn onRender(area: ?*anyopaque, context: ?*anyopaque, data: ?*anyopaque) callconv(.c) c_int {
    _ = area;
    _ = context;
    gl_renderer.render(appFrom(data));
    return 1;
}

/// `w_px`/`h_px` are device px.
fn onResize(area: ?*anyopaque, w_px: c_int, h_px: c_int, data: ?*anyopaque) callconv(.c) void {
    const app = appFrom(data);
    if (w_px <= 0 or h_px <= 0) return;
    lock(app);
    app.drawable_w_px = @intCast(w_px);
    app.drawable_h_px = @intCast(h_px);
    unlock(app);
    setScale(app, area.?);
    window_size.noteResize(app, @intCast(w_px), @intCast(h_px));
    pushLayout(app);
}

/// The main window's integer scale, read from `widget`. A change reloads the
/// faces at the new pixel size (callbacks.applyScale) and refits the external
/// windows, which draw in the same cell. Both the scale-factor notify and
/// the area's resize land here, whichever comes first.
///
/// GTK reports fractional output scales (1.25, 1.5) as the next integer
/// here and lets the compositor downsample; gdk_surface_get_scale would
/// give the fraction, but a GLArea's framebuffer is still allocated at the
/// integer scale, so drawing at the fraction would need a viewporter path
/// GTK does not expose to GL widgets.
fn setScale(app: *App, widget: *anyopaque) void {
    const scale: f32 = @floatFromInt(@max(1, gtk.gtk_widget_get_scale_factor(widget)));
    lock(app);
    const changed = app.scale != scale;
    unlock(app);
    if (!changed) return;
    callbacks.applyScale(app, scale);
    ext_window.refitAll(app);
    app.queueRenderAll();
}

fn onScaleFactor(widget: ?*anyopaque, pspec: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    _ = pspec;
    const app = appFrom(data);
    setScale(app, widget.?);
    pushLayout(app);
}

// =========================================================================
// Render-thread mode: a drawing area takes size and input, a picture shows
// the thread's frames over it.
// =========================================================================

fn onAreaRealize(widget: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const app = appFrom(data);
    if (app.gl_realized_once) return;
    app.gl_realized_once = true;
    startCore(app, widget.?);
}

/// GtkDrawingArea reports logical px.
fn onAreaResize(area: ?*anyopaque, w: c_int, h: c_int, data: ?*anyopaque) callconv(.c) void {
    const app = appFrom(data);
    if (w <= 0 or h <= 0) return;
    const scale = @max(1, gtk.gtk_widget_get_scale_factor(area.?));
    const w_px: u32 = @intCast(w * scale);
    const h_px: u32 = @intCast(h * scale);
    lock(app);
    app.drawable_w_px = w_px;
    app.drawable_h_px = h_px;
    unlock(app);
    setScale(app, area.?);
    if (app.render_thread) |rt| rt.resize(w_px, h_px, @intCast(scale));
    window_size.noteResize(app, w_px, h_px);
    pushLayout(app);
}

/// The editor widget and the picture over it, with the render thread
/// started; null (nothing built) when this system cannot run it.
fn buildThreaded(app: *App) ?[2]*anyopaque {
    const picture = gtk.gtk_picture_new() orelse return null;
    gtk.gtk_picture_set_can_shrink(picture, 1);
    gtk.gtk_picture_set_content_fit(picture, gtk.GTK_CONTENT_FIT_FILL);
    gtk.gtk_widget_set_can_target(picture, 0);
    const rt = render_thread.create(app, picture) orelse {
        gtk.g_object_unref(gtk.g_object_ref_sink(picture));
        return null;
    };
    app.render_thread = rt;
    const area = gtk.gtk_drawing_area_new() orelse return null;
    gtk.gtk_widget_set_focusable(area, 1);
    _ = gtk.g_signal_connect(area, "realize", @ptrCast(&onAreaRealize), app);
    _ = gtk.g_signal_connect(area, "resize", @ptrCast(&onAreaResize), app);
    app.frame_widget = picture;
    return .{ area, picture };
}

/// What the editor view leaves at each side of the window (a tab strip or
/// sidebar, an editor card's margin and padding), device px, in the field
/// form the GUI driver parses. As laid out now: called from the view's
/// resize, which every change of those follows.
fn logGridInsets(app: *App, scale: f32) void {
    const win = app.window orelse return;
    const view = app.widgets.overlay orelse return;
    var r: gtk.GrapheneRect = .{};
    if (gtk.gtk_widget_compute_bounds(view, win, &r) == 0) return;
    const win_w: f32 = @floatFromInt(gtk.gtk_widget_get_width(win));
    const win_h: f32 = @floatFromInt(gtk.gtk_widget_get_height(win));
    const px = struct {
        fn f(v: f32, k: f32) i32 {
            return @intFromFloat(@round(@max(0, v) * k));
        }
    }.f;
    applog.appLog("[grid_insets] left={d} top={d} right={d} bottom={d} scale={d}\n", .{
        px(r.x, scale), px(r.y, scale), px(win_w - r.x - r.w, scale), px(win_h - r.y - r.h, scale), scale,
    });
}

/// Non-blocking: grid_mu can be held for seconds (clipboard), so a busy core
/// is retried on a short timeout with the latest size.
fn pushLayout(app: *App) void {
    const cp = app.corep orelse return;
    // Not started yet (`devcontainer up` runs): launch() sends the layout.
    if (app.dc_up_cancel != null) return;
    lock(app);
    const w = app.drawable_w_px;
    const h = app.drawable_h_px;
    const cw = app.cell_w_px;
    const ch = app.cell_h_px;
    const scale = app.scale;
    unlock(app);
    if (w == 0 or h == 0 or cw == 0 or ch == 0) return;
    if (applog.isEnabled()) logGridInsets(app, scale);
    panel_popup.noteMonitor(app);
    const cols = callbacks.cmdlineCols(app, w, cw);
    // The grid leaves the "column" scrollbar its strip; the cmdline overlay
    // still spans the whole view.
    const grid_w = scrollbar.gridWidthPx(app.scrollbar_cfg, w, scale);
    if (!core.zonvie_core_try_update_layout_px(cp, grid_w, h, cw, ch, cols.screen_cols, cols.default_cols)) {
        if (!app.layout_retry_queued) {
            app.layout_retry_queued = true;
            _ = gtk.g_timeout_add(layout_retry_ms, &retryLayout, app);
        }
        return;
    }
    if (!app.layout_ready_sent) {
        app.layout_ready_sent = true;
        core.zonvie_core_notify_layout_ready(cp, @max(1, h / ch), @max(1, grid_w / cw));
    }
}

fn retryLayout(data: ?*anyopaque) callconv(.c) c_int {
    const app = appFrom(data);
    app.layout_retry_queued = false;
    pushLayout(app);
    return 0;
}

// =========================================================================
// Core startup
// =========================================================================

fn startCore(app: *App, area: *anyopaque) void {
    const startup: *const Startup = @ptrCast(@alignCast(app.startup.?));
    const scale: f32 = @floatFromInt(@max(1, gtk.gtk_widget_get_scale_factor(area)));
    lock(app);
    app.scale = scale;
    unlock(app);
    // Before zonvie_core_start, so no core thread touches the fonts yet.
    callbacks.ensureFont(app);

    var cb = callbacks.makeCallbacks();
    if (x11_place.active()) callbacks.addWindowLayout(&cb);
    app.corep = core.zonvie_core_create(&cb, @sizeOf(core.Callbacks), app);
    const cp = app.corep orelse return failStart(app, -1);
    if (config_mod.getConfigFilePath(app.alloc)) |path| {
        defer app.alloc.free(path);
        if (app.alloc.dupeZ(u8, path)) |z| {
            defer app.alloc.free(z);
            _ = core.zonvie_core_load_config(cp, z.ptr);
        } else |_| {}
    } else |_| {}
    // Both ways, as macOS and Windows: the core logs from creation on, and
    // with logging off on_log must carry only the child's stderr (the
    // early-exit alert reads it, session.failEarlyExit).
    core.zonvie_core_set_log_enabled(cp, @intFromBool(applog.isEnabled()));
    if (applog.isVerbose()) core.zonvie_core_set_log_verbose(cp, 1);
    if (app.log_perf_only) core.zonvie_core_set_log_perf_only(cp, 1);
    if (app.log_scroll_only) core.zonvie_core_set_log_scroll_only(cp, 1);
    if (startup.inherit_cwd) core.zonvie_core_set_inherit_cwd(cp, 1);
    // Default-background cells take this alpha (0.5 under blur), as on Windows.
    core.zonvie_core_set_background_opacity(cp, app.window_cfg.opacity);
    core.zonvie_core_set_blur_enabled(cp, @intFromBool(app.window_cfg.blur));
    if (startup.ext_cmdline) core.zonvie_core_set_ext_cmdline(cp, 1);
    if (startup.ext_popupmenu) core.zonvie_core_set_ext_popupmenu(cp, 1);
    if (startup.ext_messages) core.zonvie_core_set_ext_messages(cp, 1);
    if (startup.ext_tabline) core.zonvie_core_set_ext_tabline(cp, 1);
    if (startup.ext_windows) core.zonvie_core_set_ext_windows(cp, 1);
    if (startup.dc_up_argv) |argv| return runDevcontainerUp(app, area, argv);
    launch(app, area);
}

/// Starts the created core in `area`'s size.
fn launch(app: *App, area: *anyopaque) void {
    const startup: *const Startup = @ptrCast(@alignCast(app.startup.?));
    const cp = app.corep.?;
    const scale = app.scale;
    lock(app);
    const cw = app.cell_w_px;
    const ch = app.cell_h_px;
    unlock(app);
    const w_logical = gtk.gtk_widget_get_width(area);
    const h_logical = gtk.gtk_widget_get_height(area);
    const w_px: u32 = @intFromFloat(@as(f32, @floatFromInt(if (w_logical > 0) w_logical else default_w_logical)) * scale);
    const h_px: u32 = @intFromFloat(@as(f32, @floatFromInt(if (h_logical > 0) h_logical else default_h_logical)) * scale);
    const rows: u32 = if (ch != 0) @max(1, h_px / ch) else 24;
    const cols: u32 = if (cw != 0) @max(1, w_px / cw) else 80;
    // A remote start's stderr, for the alert if it ends before its first
    // frame. With logging on, on_log also carries the core's own lines,
    // which cannot be told apart: the alert then points at the log.
    if (app.start_kind != .local and !applog.isEnabled()) app.start_output.open.store(true, .release);
    const rc = if (startup.connect_addr) |addr|
        core.zonvie_core_start_connect(cp, addr.ptr, addr.len, rows, cols)
    else
        core.zonvie_core_start(cp, startup.nvim_cmd.ptr, rows, cols);
    if (rc != 0) return failStart(app, rc);
    // A window waiting for the first frame is not allocated, so no resize
    // comes before nvim attaches: lay out at the start size; the resize on
    // presenting corrects it.
    if (app.show_when_ready) {
        lock(app);
        if (app.drawable_w_px == 0 or app.drawable_h_px == 0) {
            app.drawable_w_px = w_px;
            app.drawable_h_px = h_px;
        }
        unlock(app);
    }
    // A resize that arrived before the core existed.
    pushLayout(app);
}

fn failStart(app: *App, rc: c_int) void {
    applog.appLog("[linux] core start failed rc={d}\n", .{rc});
    var buf: [256]u8 = undefined;
    const detail = std.fmt.bufPrintZ(&buf, "{s} (rc={d})", .{ cli.startFailureReason(rc), rc }) catch "Unknown error.";
    failWith(app, "Zonvie failed to start", detail);
}

const failWith = session.failWith;

// =========================================================================
// Devcontainer rebuild: `devcontainer up` before the core starts
// =========================================================================

extern "c" fn memfd_create(name: [*:0]const u8, flags: c_uint) c_int;

const DcUp = struct {
    app: *App,
    area: *anyopaque,
    cancel: *anyopaque,
    /// `up`'s merged stdout and stderr, read back for a failure's tail.
    out_fd: c_int,
};

/// Runs `devcontainer up` as macOS and Windows do, outside the core, so its
/// failure can be shown and closing the window abandons the start. Its
/// output goes to an anonymous file, not a pipe: an abandoned `up` keeps
/// running to completion, as on those platforms, with nobody reading.
fn runDevcontainerUp(app: *App, area: *anyopaque, argv: [*:null]const ?[*:0]const u8) void {
    const fd = memfd_create("devcontainer-up", 0);
    const launcher = gtk.g_subprocess_launcher_new(gtk.G_SUBPROCESS_FLAGS_STDERR_MERGE) orelse return failStart(app, -2);
    defer gtk.g_object_unref(launcher);
    if (fd >= 0) gtk.g_subprocess_launcher_take_stdout_fd(launcher, std.c.dup(fd));
    var err: ?*anyopaque = null;
    const sub = gtk.g_subprocess_launcher_spawnv(launcher, argv, &err) orelse {
        if (fd >= 0) _ = std.c.close(fd);
        var buf: [512]u8 = undefined;
        const msg: [*:0]const u8 = if (err) |e| (@as(*gtk.GError, @ptrCast(@alignCast(e))).message orelse "") else "";
        const detail = std.fmt.bufPrintZ(&buf, "Could not run `devcontainer up`: {s}", .{std.mem.span(msg)}) catch "Could not run `devcontainer up`.";
        if (err) |e| gtk.g_error_free(e);
        return failWith(app, "Devcontainer failed to start", detail);
    };
    const up = app.alloc.create(DcUp) catch return failStart(app, -2);
    up.* = .{ .app = app, .area = area, .cancel = gtk.g_cancellable_new().?, .out_fd = fd };
    app.dc_up_cancel = up.cancel;
    applog.appLog("[linux] devcontainer up started\n", .{});
    gtk.g_subprocess_wait_check_async(sub, up.cancel, &onDevcontainerUpDone, up);
    gtk.g_object_unref(sub);
}

fn onDevcontainerUpDone(source: ?*anyopaque, result: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const up: *DcUp = @ptrCast(@alignCast(data.?));
    const app = up.app;
    defer {
        if (up.out_fd >= 0) _ = std.c.close(up.out_fd);
        gtk.g_object_unref(up.cancel);
        app.alloc.destroy(up);
    }
    var err: ?*anyopaque = null;
    const ok = gtk.g_subprocess_wait_check_finish(source.?, result, &err) != 0;
    if (err) |e| gtk.g_error_free(e);
    // Closing the window abandoned the start (session.onCloseRequest).
    if (gtk.g_cancellable_is_cancelled(up.cancel) != 0) return;
    app.dc_up_cancel = null;
    if (ok) {
        applog.appLog("[linux] devcontainer up completed\n", .{});
        ui_widgets.showProgress(app, "Connecting to devcontainer...");
        return launch(app, up.area);
    }
    // The tail of what `up` printed (macOS: 20 lines, 800 characters).
    var out_buf: [16 * 1024]u8 = undefined;
    var out: []const u8 = "";
    if (up.out_fd >= 0) {
        const size = std.c.lseek(up.out_fd, 0, std.c.SEEK.END);
        if (size > 0) {
            const from: usize = @intCast(@max(0, size - @as(i64, out_buf.len)));
            const n = std.c.pread(up.out_fd, &out_buf, out_buf.len, @intCast(from));
            if (n > 0) out = out_buf[0..@intCast(n)];
        }
    }
    const tail = lifecycle.outputTail(out, 20, 800);
    applog.appLog("[linux] devcontainer up failed. Output tail:\n{s}\n", .{tail});
    var detail_buf: [804]u8 = undefined;
    const detail = if (tail.len == 0)
        "`devcontainer up` failed. See the log for details."
    else
        std.fmt.bufPrintZ(&detail_buf, "{s}", .{tail}) catch unreachable;
    failWith(app, "Devcontainer failed to start", detail);
}

// =========================================================================
// Window
// =========================================================================

fn onCloseRequest(window: ?*anyopaque, data: ?*anyopaque) callconv(.c) c_int {
    _ = window;
    return session.onCloseRequest(appFrom(data));
}

/// Files a later launch handed over ([server] single_instance): `:drop`ped
/// through the core, each in a tab unless open_mode is "current" for a
/// single file, and the window raised.
fn onOpen(gapp: ?*anyopaque, gfiles: [*]const *anyopaque, n_files: c_int, hint: ?[*:0]const u8, data: ?*anyopaque) callconv(.c) void {
    _ = gapp;
    _ = hint;
    const app = appFrom(data);
    if (app.window) |w| gtk.gtk_window_present(w);
    const n: usize = @intCast(@max(0, n_files));
    var paths: [64][:0]u8 = undefined;
    var count: usize = 0;
    for (gfiles[0..n]) |f| {
        if (count == paths.len) break;
        const p = gtk.g_file_get_path(f) orelse continue;
        paths[count] = std.mem.span(p);
        count += 1;
    }
    defer for (paths[0..count]) |p| gtk.g_free(p.ptr);
    // Queued until nvim has drawn: the core cannot send before it attached.
    session.openPaths(app, paths[0..count]);
}

fn onActivate(gapp: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const app = appFrom(data);
    // A later launch under single_instance with no files: just come forward.
    if (app.window) |w| return gtk.gtk_window_present(w);
    const win = gtk.gtk_application_window_new(gapp.?) orelse return;
    app.window = win;
    session.applyTitle(app, "");
    _ = gtk.g_signal_connect(win, "realize", @ptrCast(&session.onWindowRealize), app);
    if (app.translucent()) gtk.gtk_widget_add_css_class(win, "zonvie-translucent");
    if (app.window_cfg.blur) blur.watch(app, win);
    const saved = window_size.restored();
    const size = if (saved) |s| s.size else .{ default_w_logical, default_h_logical };
    gtk.gtk_window_set_default_size(win, size[0], size[1]);
    if (saved) |s| if (s.pos) |p| window_size.restorePosition(app, win, p);

    const startup: *const Startup = @ptrCast(@alignCast(app.startup.?));
    var area: *anyopaque = undefined;
    var frames: ?*anyopaque = null;
    const threaded = if (startup.threaded) buildThreaded(app) else null;
    if (threaded) |t| {
        area = t[0];
        frames = t[1];
        render_thread.attachWindow(app.render_thread.?, win);
    } else {
        if (startup.threaded) applog.appLog("[linux] render thread unavailable; using the GLArea\n", .{});
        area = gtk.gtk_gl_area_new() orelse return;
        app.gl_area = area;
        app.frame_widget = area;
        gtk.gtk_gl_area_set_required_version(area, 3, 3);
        gtk.gtk_gl_area_set_has_depth_buffer(area, 0);
        gtk.gtk_gl_area_set_allowed_apis(area, gtk.GDK_GL_API_GL);
        gtk.gtk_widget_set_focusable(area, 1);
        _ = gtk.g_signal_connect(area, "realize", @ptrCast(&onRealize), app);
        _ = gtk.g_signal_connect(area, "unrealize", @ptrCast(&onUnrealize), app);
        _ = gtk.g_signal_connect(area, "render", @ptrCast(&onRender), app);
        _ = gtk.g_signal_connect(area, "resize", @ptrCast(&onResize), app);
    }
    latency_bench.init(app, if (app.render_thread != null) "thread" else "glarea");
    app.pointer = .{ .app = app };
    input.attach(&app.pointer, area);

    gtk.gtk_window_set_child(win, ui_widgets.build(app, area, frames));
    panel_popup.init(app);
    if (startup.progress) |text| ui_widgets.showProgress(app, text);
    _ = gtk.g_signal_connect(win, "close-request", @ptrCast(&onCloseRequest), app);
    _ = gtk.g_signal_connect(win, "notify::scale-factor", @ptrCast(&onScaleFactor), app);
    blink.watchWindow(app, win);
    if (app.close_to_tray and !tray.init(app)) app.close_to_tray = false;
    if (startup.hide_until_ready) {
        // Realized without being shown, so the core starts now; the first
        // frame presents the window (session.onReady).
        app.show_when_ready = true;
        gtk.gtk_widget_realize(area);
        session.armReveal(app);
    } else {
        gtk.gtk_window_present(win);
    }
    _ = gtk.gtk_widget_grab_focus(area);
}

// =========================================================================
// Entry point
// =========================================================================

/// One nvim argument into the spawn command; an argument the core's
/// tokenizer cannot carry is an option error naming it, since nvim would
/// otherwise get a different argument (or fail to spawn) with no message.
fn appendArg(list: *std.ArrayListUnmanaged(u8), alloc: std.mem.Allocator, arg: []const u8) ?u8 {
    cli.appendSpawnArg(list, alloc, arg) catch |e| {
        if (e != error.Unquotable) return 1;
        const msg = std.fmt.allocPrintSentinel(alloc, "zonvie: this argument cannot be passed to nvim (a space together with both quote kinds, or a trailing backslash): {s}", .{arg}, 0) catch return 1;
        return optionError(msg);
    };
    return null;
}

/// A refused Neovim path (cli.nvimPath): on stderr, in the log, and in an
/// alert when no terminal shows stderr, as the dialog's own warning. The
/// start goes on with the default.
fn nvimPathWarning(what: []const u8) void {
    std.debug.print("zonvie: {s} contains a quote character and was ignored; the default Neovim is used.\n", .{what});
    if (applog.isEnabled()) applog.appLog("[linux] {s} contains a quote character; ignored\n", .{what});
    if (std.c.isatty(0) == 0) connect_dialog.alert(null, "The Neovim path contains a quote character and was ignored.", "The default Neovim is used.");
}

/// An option error: on stderr, and in an alert when no terminal shows
/// stderr (a launcher start, or a detached one), as macOS does when started
/// from Finder. Returns the exit status.
fn optionError(msg: [:0]const u8) u8 {
    std.debug.print("{s}\n", .{msg});
    if (std.c.isatty(0) == 0) connect_dialog.alert(null, "Zonvie cannot start", msg);
    return 1;
}

pub fn main(init: std.process.Init.Minimal) u8 {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var args_arena = std.heap.ArenaAllocator.init(alloc);
    defer args_arena.deinit();
    const aa = args_arena.allocator();
    const args = init.args.toSlice(aa) catch return 1;

    // ssh running this executable as its SSH_ASKPASS, with the prompt.
    if (askpass.requested()) return askpass.run(if (args.len > 1) args[1] else "Password:");
    // This executable started by the panic handler to show its report.
    if (crash.requested()) return crash.runAlert(if (args.len > 1) args[1] else "");

    if (cli.hasFlag(args, "--help") or cli.hasFlag(args, "-h")) {
        cli.printHelp();
        return 0;
    }
    if (cli.hasFlag(args, "--version")) {
        cli.printVersion();
        return 0;
    }
    const nofork = cli.hasFlag(args, "--nofork");
    // Attaching to a server never forks, as on macOS: its failures must
    // reach the shell's exit code. Nor does a launch with no terminal to
    // leave (a desktop launcher). Before any thread exists.
    const connects = cli.hasPrefix(args, "--connect-nvim") or cli.hasPrefix(args, "--remote-ui");
    if (!nofork and !connects and std.c.isatty(0) != 0 and cli.detach()) return 0;

    // Also makes a write to a dead nvim's pipe fail with EPIPE instead of
    // killing the process: std.Io.Threaded installs a SIGPIPE handler.
    clock.init();
    if (cli.hasFlag(args, "--install")) return cli.install(alloc);
    // First launch: the default config and the desktop entry, as Windows
    // does (macOS only on --install). An existing desktop entry is kept.
    if (config_mod.getConfigFilePath(alloc)) |p| alloc.free(p) else |_| cli.installFirstLaunch(alloc);
    // A launcher start has no shell behind it: take the login shell's
    // environment (PATH for LSPs and the like), as macOS does from Finder.
    if (std.c.getenv("TERM") == null) cli.importLoginShellEnv(alloc);
    // Claude Code in a :terminal draws its cursor natively; nvim and its
    // children inherit the environment at spawn.
    _ = cli.setenv("CLAUDE_CODE_NATIVE_CURSOR", "1", 1);

    var config = config_mod.load(alloc);
    defer config.deinit();

    // `[neovim] path` written with quotes loses one pair, as on Windows.
    const config_nvim = cli.nvimPath(config.neovim.path);
    const default_nvim: []const u8 = if (config_nvim.path.len > 0) config_nvim.path else "nvim";
    var nvim_path = default_nvim;
    var log_path: ?[]const u8 = null;
    var ext_cmdline = config.cmdline.external;
    var ext_popupmenu = config.popup.external;
    var ext_messages = config.messages.external;
    var ext_tabline = config.tabline.external;
    var ext_windows = config.windows.external;
    var threaded = false;
    var connect_addr: ?[]const u8 = null;
    var cli_nvim_path: ?[]const u8 = null;
    var ssh: ?cli.Ssh = if (config.neovim.ssh) if (config.neovim.ssh_host) |h| cli.Ssh{ .host = h, .port = config.neovim.ssh_port, .identity = config.neovim.ssh_identity } else null else null;
    var ssh_identity: ?[]const u8 = config.neovim.ssh_identity;
    var devcontainer: ?cli.Devcontainer = null;
    var devcontainer_config: ?[]const u8 = null;
    var devcontainer_rebuild = false;
    var dialog = false;
    // A bare `--ssh` / `--devcontainer` still picks the dialog's tab.
    var ssh_tab = config.neovim.ssh;
    var dc_tab = false;
    var extra: std.ArrayListUnmanaged([]const u8) = .empty;
    // The file arguments among them, absolute: what a second launch hands a
    // running instance under [server] single_instance.
    var files: std.ArrayListUnmanaged([:0]const u8) = .empty;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--")) {
            // Everything after is nvim's own command line, which may carry
            // its own `--` before files.
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
        } else if (std.mem.eql(u8, arg, "--nvim") and i + 1 < args.len) {
            i += 1;
            nvim_path = args[i];
            cli_nvim_path = args[i];
        } else if (std.mem.startsWith(u8, arg, "--nvim=")) {
            nvim_path = arg["--nvim=".len..];
            cli_nvim_path = nvim_path;
        } else if (std.mem.startsWith(u8, arg, "--ssh=")) {
            const t = core.frontend_rules.sshTarget(arg["--ssh=".len..]);
            ssh = .{ .host = t.host, .port = t.port };
        } else if (std.mem.eql(u8, arg, "--ssh")) {
            ssh_tab = true;
            if (core.frontend_rules.cliNextIsValue(if (i + 1 < args.len) args[i + 1] else null)) {
                i += 1;
                const t = core.frontend_rules.sshTarget(args[i]);
                ssh = .{ .host = t.host, .port = t.port };
            }
        } else if (std.mem.startsWith(u8, arg, "--devcontainer=")) {
            devcontainer = .{ .workspace = arg["--devcontainer=".len..] };
        } else if (std.mem.eql(u8, arg, "--devcontainer")) {
            dc_tab = true;
            if (core.frontend_rules.cliNextIsValue(if (i + 1 < args.len) args[i + 1] else null)) {
                i += 1;
                devcontainer = .{ .workspace = args[i] };
            }
        } else if (std.mem.startsWith(u8, arg, "--devcontainer-config=")) {
            devcontainer_config = arg["--devcontainer-config=".len..];
        } else if (std.mem.eql(u8, arg, "--devcontainer-config")) {
            if (core.frontend_rules.cliNextIsValue(if (i + 1 < args.len) args[i + 1] else null)) {
                i += 1;
                devcontainer_config = args[i];
            }
        } else if (std.mem.eql(u8, arg, "--devcontainer-rebuild")) {
            devcontainer_rebuild = true;
        } else if (std.mem.eql(u8, arg, "--dialog")) {
            dialog = true;
        } else if (std.mem.startsWith(u8, arg, "--ssh-identity=")) {
            ssh_identity = arg["--ssh-identity=".len..];
        } else if (std.mem.eql(u8, arg, "--ssh-identity")) {
            if (core.frontend_rules.cliNextIsValue(if (i + 1 < args.len) args[i + 1] else null)) {
                i += 1;
                ssh_identity = args[i];
            }
        } else if (std.mem.eql(u8, arg, "--extcmdline")) {
            ext_cmdline = true;
        } else if (std.mem.eql(u8, arg, "--extpopup") or std.mem.eql(u8, arg, "--extpopupmenu")) {
            ext_popupmenu = true;
        } else if (std.mem.eql(u8, arg, "--extmessages")) {
            ext_messages = true;
        } else if (std.mem.eql(u8, arg, "--exttabline")) {
            ext_tabline = true;
        } else if (std.mem.startsWith(u8, arg, "--connect-nvim=")) {
            connect_addr = arg["--connect-nvim=".len..];
        } else if (std.mem.startsWith(u8, arg, "--remote-ui=")) {
            connect_addr = arg["--remote-ui=".len..];
        } else if (std.mem.eql(u8, arg, "--connect-nvim") or std.mem.eql(u8, arg, "--remote-ui")) {
            // Bare, it is still this option: never nvim's argument.
            connect_addr = if (i + 1 < args.len) blk: {
                i += 1;
                break :blk args[i];
            } else "";
        } else if (std.mem.eql(u8, arg, "--renderer=thread")) {
            threaded = true;
        } else if (std.mem.eql(u8, arg, "--renderer=glarea")) {
            threaded = false;
        } else if (std.mem.eql(u8, arg, "--extwindows")) {
            ext_windows = true;
        } else if (std.mem.eql(u8, arg, "--log") and i + 1 < args.len) {
            i += 1;
            log_path = args[i];
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
    // --log wins over [log], as on Windows; [log] enabled without a path
    // logs to stderr.
    if (log_path) |p| {
        applog.setEnabled(true);
        applog.setLogPath(p);
    } else if (config.log.enabled) {
        applog.setEnabled(true);
        applog.setLogPath(config.log.path);
    }
    defer applog.deinit();

    // --nvim follows the same rule; a refused one falls back to the config's
    // path or nvim, as macOS and Windows do. For --ssh it names the remote
    // nvim, which the same quoting carries.
    if (config_nvim.ignored) nvimPathWarning("[neovim] path in config.toml");
    if (cli_nvim_path) |raw| {
        const p = cli.nvimPath(raw);
        if (p.ignored) nvimPathWarning("The --nvim path");
        cli_nvim_path = if (p.path.len != 0) p.path else null;
        nvim_path = cli_nvim_path orelse default_nvim;
    }

    if (connect_addr) |a| if (a.len == 0) {
        return optionError("zonvie: --connect-nvim / --remote-ui requires a non-empty address (e.g. /tmp/nvim.sock or 127.0.0.1:6789).");
    };
    if (dialog and connect_addr != null) {
        return optionError("--dialog chooses the connection, so it cannot be combined with --connect-nvim. Remove the conflicting option and retry.");
    }
    var session_name: []const u8 = "";
    if (dialog) {
        // The CLI and config seed the dialog; its answer replaces them.
        var seed: connect_dialog.Choice = .{
            .mode = if (ssh != null or ssh_tab) .ssh else if (devcontainer != null or dc_tab) .devcontainer else .local,
            .nvim_path = cli_nvim_path orelse "",
            .ssh_host = if (ssh) |s| s.host else "",
            .ssh_identity = ssh_identity orelse "",
            .dc_workspace = if (devcontainer) |d| d.workspace else "",
            .dc_config = devcontainer_config orelse "",
            .dc_rebuild = devcontainer_rebuild,
            .ext = .{ ext_cmdline, ext_popupmenu, ext_messages, ext_tabline, ext_windows },
        };
        var port_buf: [8]u8 = undefined;
        if (ssh) |s| if (s.port) |p| {
            seed.ssh_port = std.fmt.bufPrint(&port_buf, "{d}", .{p}) catch "";
        };
        const c = (connect_dialog.run(aa, seed) catch return 1) orelse return 0;
        session_name = c.name;
        if (c.nvim_path.len != 0) {
            nvim_path = c.nvim_path;
            cli_nvim_path = c.nvim_path;
        }
        ssh = null;
        devcontainer = null;
        switch (c.mode) {
            .local => {},
            .ssh => if (c.ssh_host.len != 0) {
                const t = core.frontend_rules.sshTarget(c.ssh_host);
                ssh = .{ .host = t.host, .port = std.fmt.parseInt(u16, c.ssh_port, 10) catch t.port };
                ssh_identity = if (c.ssh_identity.len != 0) c.ssh_identity else null;
            },
            .devcontainer => if (c.dc_workspace.len != 0) {
                devcontainer = .{ .workspace = c.dc_workspace };
                devcontainer_config = if (c.dc_config.len != 0) c.dc_config else null;
                devcontainer_rebuild = c.dc_rebuild;
            },
        }
        ext_cmdline, ext_popupmenu, ext_messages, ext_tabline, ext_windows = c.ext;
        // Before the core spawns nvim, which inherits them.
        var lines = std.mem.splitScalar(u8, c.env, '\n');
        while (lines.next()) |line| {
            const t = std.mem.trim(u8, line, " \t\r");
            const eq = std.mem.indexOfScalar(u8, t, '=') orelse continue;
            if (eq == 0) continue;
            const k = aa.dupeZ(u8, t[0..eq]) catch return 1;
            const v = aa.dupeZ(u8, t[eq + 1 ..]) catch return 1;
            _ = cli.setenv(k, v, 1);
        }
    }
    if (@as(u8, @intFromBool(ssh != null)) + @intFromBool(connect_addr != null) + @intFromBool(devcontainer != null) > 1) {
        return optionError("--connect-nvim, --ssh (or [neovim] ssh in config.toml) and --devcontainer are mutually exclusive. Remove the conflicting option and retry.");
    }
    var dc_up_argv: ?[*:null]const ?[*:0]const u8 = null;
    // --ssh: nvim runs on the host; local file arguments do not apply there,
    // as on macOS and Windows. --nvim names the remote executable.
    const nvim_cmd: [:0]const u8 = if (ssh) |s| blk: {
        var target = s;
        target.identity = ssh_identity;
        cli.setAskpassEnv(askpass.env_mode);
        break :blk cli.sshCommand(aa, target, cli_nvim_path orelse "nvim") catch return 1;
    } else if (devcontainer) |d| blk: {
        // Paths in the container's terms are the host's: `~` is expanded
        // here, as macOS does, since `--devcontainer=~/x` reaches no shell.
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
    const start_kind: lifecycle.StartKind = if (ssh != null) .ssh else if (connect_addr != null) .connect else if (devcontainer != null) .devcontainer else .local;
    if (session_name.len == 0) {
        var name_buf: [256]u8 = undefined;
        const target = if (ssh) |s| s.host else if (devcontainer) |d| d.workspace else "";
        session_name = aa.dupe(u8, lifecycle.defaultSessionName(&name_buf, start_kind, target)) catch "";
    }
    const progress: ?[:0]const u8 = if (devcontainer != null)
        (if (devcontainer_rebuild) "Building devcontainer..." else "Connecting to devcontainer...")
    else
        null;
    const startup = Startup{
        .nvim_cmd = nvim_cmd,
        .ext_cmdline = ext_cmdline,
        .ext_popupmenu = ext_popupmenu,
        .ext_messages = ext_messages,
        .ext_tabline = ext_tabline,
        .ext_windows = ext_windows,
        .threaded = threaded,
        .connect_addr = connect_addr,
        .inherit_cwd = nofork,
        .progress = progress,
        .dc_up_argv = dc_up_argv,
        // A devcontainer start shows its progress in the window, which
        // closing also cancels, so that window shows at once (macOS and
        // Windows show a progress window of its own instead).
        .hide_until_ready = ssh != null or connect_addr != null,
        .session_name = session_name,
    };

    // Without [server] single_instance each process owns its own nvim, so a
    // second launch must not forward to the first instance. With it, the
    // first registers the id on the session bus and a later launch hands it
    // its files (or just raises it) and exits, as Windows does.
    // A `--dialog` launch is a new session (New Session spawns one), so it
    // never hands itself to a running instance.
    const single = config.server.single_instance and !dialog;
    // The X11 WM_CLASS GTK derives from the program name, and the icon the
    // desktop shows for every window: both the desktop entry's
    // (StartupWMClass, Icon), so the window is matched to it as under Wayland,
    // where the application id already does it.
    gtk.g_set_prgname(cli.app_id);
    gtk.gtk_window_set_default_icon_name(cli.app_id);
    const gapp = gtk.gtk_application_new(cli.app_id, if (single) gtk.G_APPLICATION_HANDLES_OPEN else gtk.G_APPLICATION_NON_UNIQUE) orelse return 1;
    if (single and gtk.g_application_register(gapp, null, null) != 0 and gtk.g_application_get_is_remote(gapp) != 0) {
        // GApplication's own command line turns these into an Open call on
        // the running instance (an Activate without files).
        var argv: std.ArrayListUnmanaged(?[*:0]const u8) = .empty;
        argv.append(aa, "zonvie") catch return 1;
        for (files.items) |f| argv.append(aa, f.ptr) catch return 1;
        argv.append(aa, null) catch return 1;
        return @intCast(gtk.g_application_run(gapp, @intCast(argv.items.len - 1), @ptrCast(argv.items.ptr)));
    }

    const app = alloc.create(App) catch return 1;
    defer alloc.destroy(app);
    app.* = .{
        .alloc = alloc,
        .startup = @constCast(@ptrCast(&startup)),
        .large_jump = config.scroll.large_jump_behavior,
        .font_cfg = config.font,
        .msg_pos = config.messages.msg_pos,
        .input_cfg = config.input,
        .window_cfg = config.window,
        .desktop_titlebar = @import("chrome.zig").desktopDrawsTitlebar(if (std.c.getenv("XDG_CURRENT_DESKTOP")) |v| std.mem.span(v) else null),
        .scrollbar_cfg = config.scrollbar,
        .tabline_cfg = config.tabline,
        .ext_tabline = startup.ext_tabline,
        .ext_cmdline = startup.ext_cmdline,
        .copy_cmdline = config.cmdline.copy_button,
        .copy_messages = config.messages.copy_button,
        .open_mode_current = std.mem.eql(u8, config.server.open_mode, "current"),
        .log_perf_only = config.log.perf_only,
        .log_scroll_only = config.log.scroll_only,
        .shader_paths = if (config.shaders.enabled) config.shaders.paths else &.{},
        .shader_preserve_alpha = config.shaders.preserve_alpha,
        .shader_epoch_ns = clock.nowNs(),
        .cell_age = core.cell_age_store.Stores.init(alloc),
        .session_name = session_name,
        .close_to_tray = config.server.close_to_tray,
        .start_kind = start_kind,
    };
    defer app.deinit();
    ui_widgets.the_app = app;
    defer latency_bench.deinit(app);

    app.gtk_app = gapp;
    _ = gtk.g_signal_connect(gapp, "activate", @ptrCast(&onActivate), app);
    if (single) _ = gtk.g_signal_connect(gapp, "open", @ptrCast(&onOpen), app);
    _ = gtk.g_application_run(gapp, 0, null);
    // Its source would outlive the App in the iterations below.
    session.stopReveal(app);

    // The loop no longer serves clipboard idles; release a core thread
    // waiting on one so destroy does not sit out its timeout.
    callbacks.abandonClipboardWait(app);
    ext_window.abandonFindWait(app);
    // Lifecycle thread, outside any callback.
    if (app.corep) |cp| core.zonvie_core_destroy(cp);
    app.corep = null;
    // Run idles still queued, so stale clipboard tasks free themselves.
    while (gtk.g_main_context_iteration(null, 0) != 0) {}
    ext_window.closeAll(app);
    // Destroys the window; unrealize still needs `app`.
    gtk.g_object_unref(gapp);
    app.gtk_app = null;
    // After the window: its textures' destroy notifies reach the thread's
    // buffers, so they must all have run.
    while (gtk.g_main_context_iteration(null, 0) != 0) {}
    // The popups went with the window; their unrealize read them.
    panel_popup.deinit(app);
    if (app.render_thread) |rt| render_thread.destroy(rt);
    app.render_thread = null;

    if (app.start_failed) return 1;
    const code = app.exit_code orelse 0;
    return @intCast(std.math.clamp(code, 0, 255));
}
