//! The main window's lifecycle around nvim, on the GTK main thread: closing
//! (lifecycle.Quit decides), the quit timeout and its "Neovim Not
//! Responding" dialog, showing a window that waited for the first frame,
//! files handed over before nvim could take them, the title, and the
//! toplevel's visibility for the cursor blink.

const std = @import("std");
const core = @import("zonvie_core");
const App = @import("app.zig").App;
const gtk = @import("gtk_bindings.zig");
const applog = @import("app_log.zig");
const lifecycle = @import("lifecycle.zig");
const blink = @import("blink.zig");
const tray = @import("tray.zig");

fn appFrom(data: ?*anyopaque) *App {
    return @ptrCast(@alignCast(data.?));
}

fn session(app: *App) lifecycle.Session {
    if (app.dc_up_cancel != null) return .building;
    if (app.corep == null or app.start_failed) return .none;
    app.mu.lockUncancelable(core.clock.io());
    const exited = app.exit_code != null;
    app.mu.unlock(core.clock.io());
    return if (exited) .none else .running;
}

/// The main window's close-request. Returns 1 to keep the window open.
pub fn onCloseRequest(app: *App) c_int {
    // [server] close_to_tray: hide instead; nvim keeps running and the tray
    // brings the window back. Its Quit asks for one real close (consumed
    // here, so a cancelled quit leaves close-to-tray on), as on Windows.
    const tray_quit = app.tray.quit_requested;
    app.tray.quit_requested = false;
    if (app.close_to_tray and app.tray.conn != null and !tray_quit) {
        if (app.window) |w| gtk.gtk_widget_set_visible(w, 0);
        applog.appLog("[linux] close: hidden to the tray\n", .{});
        return 1;
    }
    switch (app.quit.close(session(app))) {
        .close => return 0,
        .cancel_start => {
            applog.appLog("[linux] close: cancelling the pending devcontainer start\n", .{});
            // The completion sees the cancel and starts nothing.
            gtk.g_cancellable_cancel(app.dc_up_cancel.?);
            app.dc_up_cancel = null;
            return 0;
        },
        .ignore => {
            applog.appLog("[linux] close: quit already pending, ignoring\n", .{});
            return 1;
        },
        .request_quit => {
            applog.appLog("[linux] close: requesting quit (timeout={d}ms)\n", .{lifecycle.quit_timeout_ms});
            std.debug.assert(app.quit_timer == 0);
            app.quit_timer = gtk.g_timeout_add(lifecycle.quit_timeout_ms, &onQuitTimeout, app);
            // The core answers through on_quit_requested, then on_exit.
            core.zonvie_core_request_quit(app.corep.?);
            return 1;
        },
    }
}

/// on_quit_requested reached the GTK thread. Returns whether to act on it;
/// either way the timeout is no longer armed.
pub fn takeQuitReply(app: *App) bool {
    if (!app.quit.reply()) {
        applog.appLog("[linux] quit answer after the timeout fired: ignored\n", .{});
        return false;
    }
    if (app.quit_timer != 0) {
        _ = gtk.g_source_remove(app.quit_timer);
        app.quit_timer = 0;
    }
    return true;
}

fn onQuitTimeout(data: ?*anyopaque) callconv(.c) c_int {
    const app = appFrom(data);
    app.quit_timer = 0;
    if (!app.quit.timeout()) return 0;
    applog.appLog("[linux] quit timeout: Neovim not responding\n", .{});
    const dialog = gtk.gtk_alert_dialog_new("%s", "Neovim Not Responding") orelse return 0;
    gtk.gtk_alert_dialog_set_detail(dialog, "Neovim is not responding. Do you want to force quit?");
    const labels = [_:null]?[*:0]const u8{ "Force Quit", "Wait" };
    gtk.gtk_alert_dialog_set_buttons(dialog, &labels);
    gtk.gtk_alert_dialog_set_cancel_button(dialog, 1);
    gtk.gtk_alert_dialog_set_default_button(dialog, 0);
    gtk.gtk_alert_dialog_choose(dialog, parentWindow(app), null, &onNotRespondingDone, app);
    return 0;
}

fn onNotRespondingDone(source: ?*anyopaque, result: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    var err: ?*anyopaque = null;
    const choice = gtk.gtk_alert_dialog_choose_finish(source.?, result, &err);
    if (err) |e| gtk.g_error_free(e);
    gtk.g_object_unref(source.?);
    // "Wait": nothing; closing again asks nvim again.
    if (choice != 0) return;
    applog.appLog("[linux] quit timeout: user chose Force Quit\n", .{});
    // The core's teardown after the loop ends stops nvim.
    if (appFrom(data).gtk_app) |a| gtk.g_application_quit(a);
}

/// The main window when it can parent a dialog, null while it is hidden.
pub fn parentWindow(app: *App) ?*anyopaque {
    const w = app.window orelse return null;
    return if (gtk.gtk_widget_get_visible(w) != 0) w else null;
}

/// Neovim drew its first frame. Idempotent.
pub fn onReady(app: *App) void {
    if (app.nvim_ready) return;
    app.nvim_ready = true;
    if (app.show_when_ready) if (app.window) |w| gtk.gtk_window_present(w);
    const cp = app.corep orelse return;
    if (app.pending_opens.items.len == 0) return;
    sendOpens(app, cp, app.pending_opens.items);
    for (app.pending_opens.items) |p| app.alloc.free(p);
    app.pending_opens.clearRetainingCapacity();
}

/// Files a later launch handed over: `:drop`ped through the core, each in a
/// tab unless open_mode is "current" for a single file; queued until nvim
/// can take them (the core cannot send before it is attached).
pub fn openPaths(app: *App, paths: []const [:0]u8) void {
    if (paths.len == 0) return;
    if (app.nvim_ready) if (app.corep) |cp| return sendOpens(app, cp, paths);
    for (paths) |p| {
        const owned = app.alloc.dupeZ(u8, p) catch return;
        app.pending_opens.append(app.alloc, owned) catch return app.alloc.free(owned);
    }
}

fn sendOpens(app: *App, cp: *core.zonvie_core, paths: []const [:0]u8) void {
    var ptrs: [64][*]const u8 = undefined;
    var lens: [64]usize = undefined;
    const n = @min(paths.len, ptrs.len);
    for (paths[0..n], 0..) |p, i| {
        ptrs[i] = p.ptr;
        lens[i] = p.len;
    }
    const tab_per_file = !app.open_mode_current or n > 1;
    core.zonvie_core_drop_paths(cp, &ptrs, &lens, n, @intFromBool(tab_per_file));
}

/// Sets the main window's title from nvim's `title` and the session name.
pub fn applyTitle(app: *App, title: []const u8) void {
    const w = app.window orelse return;
    var buf: [384]u8 = undefined;
    gtk.gtk_window_set_title(w, lifecycle.sessionTitle(&buf, title, app.session_name).ptr);
}

/// Follows the main window's toplevel state once it has a surface: a
/// minimized or suspended window stops the cursor blink and repaints when
/// it comes back. Connect to the window's "realize".
pub fn onWindowRealize(win: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const surface = gtk.gtk_native_get_surface(win.?) orelse return;
    _ = gtk.g_signal_connect(surface, "notify::state", @ptrCast(&onToplevelState), data);
}

fn onToplevelState(surface: ?*anyopaque, pspec: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    _ = pspec;
    const app = appFrom(data);
    const hidden = lifecycle.toplevelHidden(gtk.gdk_toplevel_get_state(surface.?));
    if (hidden == app.window_hidden) return;
    app.window_hidden = hidden;
    applog.appLog("[linux] main window {s}\n", .{if (hidden) "hidden" else "shown"});
    blink.update(app);
    if (!hidden) app.queueRenderAll();
}
