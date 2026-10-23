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
const blink = @import("blink.zig");
const cli = @import("cli.zig");
const askpass = @import("askpass.zig");
const connect_dialog = @import("connect_dialog.zig");

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
    app.scale = @floatFromInt(@max(1, gtk.gtk_widget_get_scale_factor(area.?)));
    unlock(app);
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
    app.scale = @floatFromInt(scale);
    unlock(app);
    if (app.render_thread) |rt| rt.resize(w_px, h_px);
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
    // Not in a GtkGraphicsOffload: GTK hands the dmabuf to the compositor
    // with the modifier GBM reports (LINEAR for an implicit-modifier buffer),
    // which a compositor may reject as a protocol error that kills the
    // client. GTK's own renderer imports it instead.
    return .{ area, picture };
}

/// Non-blocking: grid_mu can be held for seconds (clipboard), so a busy core
/// is retried on a short timeout with the latest size.
fn pushLayout(app: *App) void {
    const cp = app.corep orelse return;
    lock(app);
    const w = app.drawable_w_px;
    const h = app.drawable_h_px;
    const cw = app.cell_w_px;
    const ch = app.cell_h_px;
    unlock(app);
    if (w == 0 or h == 0 or cw == 0 or ch == 0) return;
    const cols = callbacks.cmdlineCols(app, w, cw);
    if (!core.zonvie_core_try_update_layout_px(cp, w, h, cw, ch, cols.screen_cols, cols.default_cols)) {
        if (!app.layout_retry_queued) {
            app.layout_retry_queued = true;
            _ = gtk.g_timeout_add(layout_retry_ms, &retryLayout, app);
        }
        return;
    }
    if (!app.layout_ready_sent) {
        app.layout_ready_sent = true;
        core.zonvie_core_notify_layout_ready(cp, @max(1, h / ch), @max(1, w / cw));
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
    app.corep = core.zonvie_core_create(&cb, @sizeOf(core.Callbacks), app);
    const cp = app.corep orelse return failStart(app, -1);
    if (config_mod.getConfigFilePath(app.alloc)) |path| {
        defer app.alloc.free(path);
        if (app.alloc.dupeZ(u8, path)) |z| {
            defer app.alloc.free(z);
            _ = core.zonvie_core_load_config(cp, z.ptr);
        } else |_| {}
    } else |_| {}
    if (applog.isEnabled()) core.zonvie_core_set_log_enabled(cp, 1);
    if (applog.isVerbose()) core.zonvie_core_set_log_verbose(cp, 1);
    if (startup.inherit_cwd) core.zonvie_core_set_inherit_cwd(cp, 1);
    // Default-background cells take this alpha (0.5 under blur), as on Windows.
    core.zonvie_core_set_background_opacity(cp, app.window_cfg.opacity);
    core.zonvie_core_set_blur_enabled(cp, @intFromBool(app.window_cfg.blur));
    if (startup.ext_cmdline) core.zonvie_core_set_ext_cmdline(cp, 1);
    if (startup.ext_popupmenu) core.zonvie_core_set_ext_popupmenu(cp, 1);
    if (startup.ext_messages) core.zonvie_core_set_ext_messages(cp, 1);
    if (startup.ext_tabline) core.zonvie_core_set_ext_tabline(cp, 1);
    if (startup.ext_windows) core.zonvie_core_set_ext_windows(cp, 1);

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
    const rc = if (startup.connect_addr) |addr|
        core.zonvie_core_start_connect(cp, addr.ptr, addr.len, rows, cols)
    else
        core.zonvie_core_start(cp, startup.nvim_cmd.ptr, rows, cols);
    if (rc != 0) return failStart(app, rc);
    // A resize that arrived before the core existed.
    pushLayout(app);
}

fn failStart(app: *App, rc: c_int) void {
    applog.appLog("[linux] core start failed rc={d}\n", .{rc});
    app.start_failed = true;
    const dialog = gtk.gtk_alert_dialog_new("Failed to start Neovim (error %d)", rc) orelse {
        if (app.gtk_app) |a| gtk.g_application_quit(a);
        return;
    };
    gtk.gtk_alert_dialog_choose(dialog, app.window, null, &onStartFailDone, app);
}

fn onStartFailDone(source: ?*anyopaque, result: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    var err: ?*anyopaque = null;
    _ = gtk.gtk_alert_dialog_choose_finish(source.?, result, &err);
    if (err) |e| gtk.g_error_free(e);
    gtk.g_object_unref(source.?);
    if (appFrom(data).gtk_app) |a| gtk.g_application_quit(a);
}

// =========================================================================
// Window
// =========================================================================

fn onCloseRequest(window: ?*anyopaque, data: ?*anyopaque) callconv(.c) c_int {
    _ = window;
    const app = appFrom(data);
    const cp = app.corep orelse return 0;
    if (app.start_failed) return 0;
    lock(app);
    const exited = app.exit_code != null;
    unlock(app);
    if (exited) return 0;
    // The core answers through on_quit_requested, then on_exit.
    core.zonvie_core_request_quit(cp);
    return 1;
}

/// Files a later launch handed over ([server] single_instance): `:drop`ped
/// through the core, each in a tab unless open_mode is "current" for a
/// single file, and the window raised.
fn onOpen(gapp: ?*anyopaque, gfiles: [*]const *anyopaque, n_files: c_int, hint: ?[*:0]const u8, data: ?*anyopaque) callconv(.c) void {
    _ = gapp;
    _ = hint;
    const app = appFrom(data);
    if (app.window) |w| gtk.gtk_window_present(w);
    const cp = app.corep orelse return;
    const n: usize = @intCast(@max(0, n_files));
    var paths: [64][*:0]u8 = undefined;
    var lens: [64]usize = undefined;
    var count: usize = 0;
    for (gfiles[0..n]) |f| {
        if (count == paths.len) break;
        const p = gtk.g_file_get_path(f) orelse continue;
        paths[count] = p;
        lens[count] = std.mem.len(p);
        count += 1;
    }
    defer for (paths[0..count]) |p| gtk.g_free(p);
    if (count == 0) return;
    const tab_per_file = !app.open_mode_current or count > 1;
    core.zonvie_core_drop_paths(cp, @ptrCast(&paths), &lens, count, @intFromBool(tab_per_file));
}

fn onActivate(gapp: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const app = appFrom(data);
    // A later launch under single_instance with no files: just come forward.
    if (app.window) |w| return gtk.gtk_window_present(w);
    const win = gtk.gtk_application_window_new(gapp.?) orelse return;
    app.window = win;
    gtk.gtk_window_set_title(win, "zonvie");
    if (app.translucent()) gtk.gtk_widget_add_css_class(win, "zonvie-translucent");
    gtk.gtk_window_set_default_size(win, default_w_logical, default_h_logical);

    const startup: *const Startup = @ptrCast(@alignCast(app.startup.?));
    var area: *anyopaque = undefined;
    var frames: ?*anyopaque = null;
    const threaded = if (startup.threaded) buildThreaded(app) else null;
    if (threaded) |t| {
        area = t[0];
        frames = t[1];
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
    if (startup.progress) |text| ui_widgets.showProgress(app, text);
    _ = gtk.g_signal_connect(win, "close-request", @ptrCast(&onCloseRequest), app);
    blink.watchWindow(app, win);
    gtk.gtk_window_present(win);
    _ = gtk.gtk_widget_grab_focus(area);
}

// =========================================================================
// Entry point
// =========================================================================

fn appendArg(list: *std.ArrayListUnmanaged(u8), alloc: std.mem.Allocator, arg: []const u8) !void {
    if (list.items.len != 0) try list.append(alloc, ' ');
    // An argument no quote can carry keeps double quotes, as on Windows.
    const q = core.frontend_rules.spawnArgQuote(arg) orelse '"';
    if (q != 0) try list.append(alloc, q);
    try list.appendSlice(alloc, arg);
    if (q != 0) try list.append(alloc, q);
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

    clock.init();
    if (cli.hasFlag(args, "--install")) return cli.install(alloc);

    var config = config_mod.load(alloc);
    defer config.deinit();

    var nvim_path: []const u8 = if (config.neovim.path.len > 0) config.neovim.path else "nvim";
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
            var nvim_dash_dash = false;
            for (args[i + 1 ..], i + 1..) |a, j| {
                const prev: ?[]const u8 = if (j > i + 1) args[j - 1] else null;
                const fwd = cli.absoluteFileArg(aa, prev, a, nvim_dash_dash) catch return 1;
                extra.append(aa, fwd) catch return 1;
                if (core.frontend_rules.nvimArgIsFile(prev, a, nvim_dash_dash)) files.append(aa, aa.dupeZ(u8, fwd) catch return 1) catch return 1;
                if (!nvim_dash_dash and std.mem.eql(u8, a, "--")) nvim_dash_dash = true;
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
            if (core.frontend_rules.cliNextIsValue(if (i + 1 < args.len) args[i + 1] else null)) {
                i += 1;
                const t = core.frontend_rules.sshTarget(args[i]);
                ssh = .{ .host = t.host, .port = t.port };
            }
        } else if (std.mem.startsWith(u8, arg, "--devcontainer=")) {
            devcontainer = .{ .workspace = arg["--devcontainer=".len..] };
        } else if (std.mem.eql(u8, arg, "--devcontainer")) {
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
        } else if (std.mem.eql(u8, arg, "--extpopup")) {
            ext_popupmenu = true;
        } else if (std.mem.eql(u8, arg, "--extmessages")) {
            ext_messages = true;
        } else if (std.mem.eql(u8, arg, "--exttabline")) {
            ext_tabline = true;
        } else if (std.mem.startsWith(u8, arg, "--connect-nvim=")) {
            connect_addr = arg["--connect-nvim=".len..];
        } else if (std.mem.startsWith(u8, arg, "--remote-ui=")) {
            connect_addr = arg["--remote-ui=".len..];
        } else if ((std.mem.eql(u8, arg, "--connect-nvim") or std.mem.eql(u8, arg, "--remote-ui")) and i + 1 < args.len) {
            i += 1;
            connect_addr = args[i];
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
    // --log wins over [log], as on Windows.
    if (log_path orelse if (config.log.enabled) config.log.path else null) |p| {
        applog.setEnabled(true);
        applog.setLogPath(p);
    }
    defer applog.deinit();

    if (dialog and connect_addr != null) {
        std.debug.print("--dialog chooses the connection, so it cannot be combined with --connect-nvim. Remove the conflicting option and retry.\n", .{});
        return 1;
    }
    if (dialog) {
        // The CLI and config seed the dialog; its answer replaces them.
        var seed: connect_dialog.Choice = .{
            .mode = if (ssh != null) .ssh else if (devcontainer != null) .devcontainer else .local,
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
        std.debug.print("--connect-nvim, --ssh (or [neovim] ssh in config.toml) and --devcontainer are mutually exclusive. Remove the conflicting option and retry.\n", .{});
        return 1;
    }
    var cmd: std.ArrayListUnmanaged(u8) = .empty;
    appendArg(&cmd, aa, nvim_path) catch return 1;
    for (extra.items) |a| appendArg(&cmd, aa, a) catch return 1;
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
        break :blk cli.devcontainerCommand(aa, target, cli.nvimConfigDir(aa) catch return 1) catch return 1;
    } else aa.dupeZ(u8, cmd.items) catch return 1;
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
    };

    // Without [server] single_instance each process owns its own nvim, so a
    // second launch must not forward to the first instance. With it, the
    // first registers the id on the session bus and a later launch hands it
    // its files (or just raises it) and exits, as Windows does.
    const single = config.server.single_instance;
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
        .scrollbar_cfg = config.scrollbar,
        .tabline_cfg = config.tabline,
        .copy_cmdline = config.cmdline.copy_button,
        .copy_messages = config.messages.copy_button,
        .open_mode_current = std.mem.eql(u8, config.server.open_mode, "current"),
        .shader_paths = if (config.shaders.enabled) config.shaders.paths else &.{},
        .shader_preserve_alpha = config.shaders.preserve_alpha,
        .shader_epoch_ns = clock.nowNs(),
        .cell_age = core.cell_age_store.Stores.init(alloc),
    };
    defer app.deinit();
    ui_widgets.the_app = app;
    defer latency_bench.deinit(app);

    app.gtk_app = gapp;
    _ = gtk.g_signal_connect(gapp, "activate", @ptrCast(&onActivate), app);
    if (single) _ = gtk.g_signal_connect(gapp, "open", @ptrCast(&onOpen), app);
    _ = gtk.g_application_run(gapp, 0, null);

    // The loop no longer serves clipboard idles; release a core thread
    // waiting on one so destroy does not sit out its timeout.
    callbacks.abandonClipboardWait(app);
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
    if (app.render_thread) |rt| render_thread.destroy(rt);
    app.render_thread = null;

    if (app.start_failed) return 1;
    const code = app.exit_code orelse 0;
    return @intCast(std.math.clamp(code, 0, 255));
}
