const std = @import("std");
const core = @import("zonvie_core");
const clock = core.clock;
const callbacks = @import("callbacks.zig");
const App = @import("app.zig").App;
const gl_renderer = @import("renderer/gl_renderer.zig");
const gtk = @import("gtk_bindings.zig");
const input = @import("input.zig");
const applog = @import("app_log.zig");
const config_mod = @import("config.zig");
const ui_widgets = @import("ui_widgets.zig");

const default_w_logical = 1000;
const default_h_logical = 700;
const layout_retry_ms = 8;

const Startup = struct {
    /// Tokenized by the core (rpc_session.zig tokenizeCommand).
    nvim_cmd: [:0]const u8,
    /// ext_* UI extensions: config.toml's `external` keys, or a CLI flag.
    ext_cmdline: bool = false,
    ext_popupmenu: bool = false,
    ext_messages: bool = false,
    ext_tabline: bool = false,
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
    if (!gl_renderer.realize(app)) return;
    if (app.gl_realized_once) return;
    app.gl_realized_once = true;
    startCore(app, area);
}

fn onUnrealize(widget: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    gtk.gtk_gl_area_make_current(widget.?);
    gl_renderer.unrealize(appFrom(data));
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
    if (startup.ext_cmdline) core.zonvie_core_set_ext_cmdline(cp, 1);
    if (startup.ext_popupmenu) core.zonvie_core_set_ext_popupmenu(cp, 1);
    if (startup.ext_messages) core.zonvie_core_set_ext_messages(cp, 1);
    if (startup.ext_tabline) core.zonvie_core_set_ext_tabline(cp, 1);

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
    const rc = core.zonvie_core_start(cp, startup.nvim_cmd.ptr, rows, cols);
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

fn onActivate(gapp: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const app = appFrom(data);
    if (app.window != null) return;
    const win = gtk.gtk_application_window_new(gapp.?) orelse return;
    app.window = win;
    gtk.gtk_window_set_title(win, "zonvie");
    gtk.gtk_window_set_default_size(win, default_w_logical, default_h_logical);

    const area = gtk.gtk_gl_area_new() orelse return;
    app.gl_area = area;
    gtk.gtk_gl_area_set_required_version(area, 3, 3);
    gtk.gtk_gl_area_set_has_depth_buffer(area, 0);
    gtk.gtk_gl_area_set_allowed_apis(area, gtk.GDK_GL_API_GL);
    gtk.gtk_widget_set_focusable(area, 1);
    _ = gtk.g_signal_connect(area, "realize", @ptrCast(&onRealize), app);
    _ = gtk.g_signal_connect(area, "unrealize", @ptrCast(&onUnrealize), app);
    _ = gtk.g_signal_connect(area, "render", @ptrCast(&onRender), app);
    _ = gtk.g_signal_connect(area, "resize", @ptrCast(&onResize), app);
    input.attach(app, area);

    gtk.gtk_window_set_child(win, ui_widgets.build(app, area));
    _ = gtk.g_signal_connect(win, "close-request", @ptrCast(&onCloseRequest), app);
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
    clock.init();
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var args_arena = std.heap.ArenaAllocator.init(alloc);
    defer args_arena.deinit();
    const aa = args_arena.allocator();
    const args = init.args.toSlice(aa) catch return 1;

    var config = config_mod.load(alloc);
    defer config.deinit();

    var nvim_path: []const u8 = if (config.neovim.path.len > 0) config.neovim.path else "nvim";
    var log_path: ?[]const u8 = null;
    var ext_cmdline = config.cmdline.external;
    var ext_popupmenu = config.popup.external;
    var ext_messages = config.messages.external;
    var ext_tabline = config.tabline.external;
    var extra: std.ArrayListUnmanaged([]const u8) = .empty;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--")) {
            for (args[i + 1 ..]) |a| extra.append(aa, a) catch return 1;
            break;
        } else if (std.mem.eql(u8, arg, "--nvim") and i + 1 < args.len) {
            i += 1;
            nvim_path = args[i];
        } else if (std.mem.startsWith(u8, arg, "--nvim=")) {
            nvim_path = arg["--nvim=".len..];
        } else if (std.mem.eql(u8, arg, "--extcmdline")) {
            ext_cmdline = true;
        } else if (std.mem.eql(u8, arg, "--extpopup")) {
            ext_popupmenu = true;
        } else if (std.mem.eql(u8, arg, "--extmessages")) {
            ext_messages = true;
        } else if (std.mem.eql(u8, arg, "--exttabline")) {
            ext_tabline = true;
        } else if (std.mem.eql(u8, arg, "--log") and i + 1 < args.len) {
            i += 1;
            log_path = args[i];
        } else {
            extra.append(aa, arg) catch return 1;
        }
    }
    if (log_path) |p| {
        applog.setEnabled(true);
        applog.setLogPath(p);
    }
    defer applog.deinit();

    var cmd: std.ArrayListUnmanaged(u8) = .empty;
    appendArg(&cmd, aa, nvim_path) catch return 1;
    for (extra.items) |a| appendArg(&cmd, aa, a) catch return 1;
    const startup = Startup{
        .nvim_cmd = aa.dupeZ(u8, cmd.items) catch return 1,
        .ext_cmdline = ext_cmdline,
        .ext_popupmenu = ext_popupmenu,
        .ext_messages = ext_messages,
        .ext_tabline = ext_tabline,
    };

    const app = alloc.create(App) catch return 1;
    defer alloc.destroy(app);
    app.* = .{
        .alloc = alloc,
        .startup = @constCast(@ptrCast(&startup)),
        .large_jump = config.scroll.large_jump_behavior,
    };
    defer app.deinit();
    ui_widgets.the_app = app;

    // Each process owns its own nvim, so a second launch must not forward
    // to the first instance.
    const gapp = gtk.gtk_application_new("io.github.akiyosi.zonvie", gtk.G_APPLICATION_NON_UNIQUE) orelse return 1;
    app.gtk_app = gapp;
    _ = gtk.g_signal_connect(gapp, "activate", @ptrCast(&onActivate), app);
    _ = gtk.g_application_run(gapp, 0, null);

    // The loop no longer serves clipboard idles; release a core thread
    // waiting on one so destroy does not sit out its timeout.
    callbacks.abandonClipboardWait(app);
    // Lifecycle thread, outside any callback.
    if (app.corep) |cp| core.zonvie_core_destroy(cp);
    app.corep = null;
    // Run idles still queued, so stale clipboard tasks free themselves.
    while (gtk.g_main_context_iteration(null, 0) != 0) {}
    // Destroys the window; unrealize still needs `app`.
    gtk.g_object_unref(gapp);
    app.gtk_app = null;

    if (app.start_failed) return 1;
    const code = app.exit_code orelse 0;
    return @intCast(std.math.clamp(code, 0, 255));
}
