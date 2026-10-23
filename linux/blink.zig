//! Cursor blink and app focus. The cadence is the core's
//! (frontend_rules.Blink, shared with macOS and Windows); this file keeps the
//! timer, the gate and the repaints. GTK main thread only.
//!
//! The app is "active" while any of its windows is: focus moving between the
//! main window and an external one is not FocusLost. The state is settled in
//! an idle because GTK deactivates the old window before activating the new.

const std = @import("std");
const core = @import("zonvie_core");
const clock = core.clock;
const Blink = core.frontend_rules.Blink;
const App = @import("app.zig").App;
const gtk = @import("gtk_bindings.zig");
const applog = @import("app_log.zig");

/// Retry delay when the core's grid lock is busy (Windows' LOCK_RETRY_INTERVAL_MS).
const lock_retry_ms = 16;

/// Watches `win`'s is-active; call for every toplevel the app opens.
pub fn watchWindow(app: *App, win: *anyopaque) void {
    _ = gtk.g_signal_connect(win, "notify::is-active", @ptrCast(&onIsActive), app);
}

fn onIsActive(win: ?*anyopaque, pspec: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    _ = win;
    _ = pspec;
    const app: *App = @ptrCast(@alignCast(data.?));
    if (app.active_idle_queued) return;
    app.active_idle_queued = true;
    _ = gtk.g_idle_add(&idleSettleActive, app);
}

fn anyWindowActive(app: *App) bool {
    if (app.window) |w| if (gtk.gtk_window_is_active(w) != 0) return true;
    var it = app.ext_windows.valueIterator();
    while (it.next()) |e| if (e.*.window) |w| if (gtk.gtk_window_is_active(w) != 0) return true;
    return false;
}

fn idleSettleActive(data: ?*anyopaque) callconv(.c) c_int {
    const app: *App = @ptrCast(@alignCast(data.?));
    app.active_idle_queued = false;
    const active = anyWindowActive(app);
    if (active == app.app_active) return 0;
    app.app_active = active;
    if (app.corep) |cp| core.zonvie_core_set_focus(cp, active);
    // The timer stops with the app, as on macOS and Windows; activation
    // re-arms it through the gate.
    if (active) update(app) else pause(app);
    return 0;
}

const Op = union(enum) { start: [3]u32, tick, stop };

/// Steps the cadence under App.mu (the renderer reads `visible` under it) and
/// repaints on a phase change. Returns the delay to the next tick, 0 for none.
fn step(app: *App, op: Op) u32 {
    app.mu.lockUncancelable(clock.io());
    const b = &app.cursor_blink;
    const was = b.visible;
    const delay_ms = switch (op) {
        .start => |s| b.start(s[0], s[1], s[2]),
        .tick => b.tick(),
        .stop => blk: {
            b.stop();
            break :blk 0;
        },
    };
    const toggled = b.visible != was;
    const visible = b.visible;
    app.mu.unlock(clock.io());
    if (toggled) {
        applog.appLog("[blink] toggled to {}\n", .{visible});
        app.queueRenderAll();
    }
    return delay_ms;
}

fn arm(app: *App, delay_ms: u32) void {
    if (delay_ms == 0) return;
    app.blink_timer = gtk.g_timeout_add(delay_ms, &onTick, app);
}

fn disarm(app: *App) void {
    if (app.blink_timer == 0) return;
    _ = gtk.g_source_remove(app.blink_timer);
    app.blink_timer = 0;
}

fn onTick(data: ?*anyopaque) callconv(.c) c_int {
    const app: *App = @ptrCast(@alignCast(data.?));
    // One-shot: each phase has its own interval.
    app.blink_timer = 0;
    arm(app, step(app, .tick));
    return 0;
}

fn startWith(app: *App, wait_ms: u32, on_ms: u32, off_ms: u32) void {
    disarm(app);
    arm(app, step(app, .{ .start = .{ wait_ms, on_ms, off_ms } }));
}

/// Stop the timer and leave the cursor drawn.
fn pause(app: *App) void {
    disarm(app);
    _ = step(app, .stop);
}

fn onLockRetry(data: ?*anyopaque) callconv(.c) c_int {
    const app: *App = @ptrCast(@alignCast(data.?));
    app.blink_retry_queued = false;
    update(app);
    return 0;
}

/// Re-reads guicursor's cadence for the current mode and (re)arms the timer
/// when it changed or was stopped. Called after every committed flush.
pub fn update(app: *App) void {
    const cp = app.corep orelse return;
    // try_get leaves these untouched on a busy lock, which retries instead.
    var wait_ms = app.cursor_blink.wait_ms;
    var on_ms = app.cursor_blink.on_ms;
    var off_ms = app.cursor_blink.off_ms;
    if (!core.zonvie_core_try_get_cursor_blink(cp, &wait_ms, &on_ms, &off_ms)) {
        if (!app.blink_retry_queued) {
            app.blink_retry_queued = true;
            _ = gtk.g_timeout_add(lock_retry_ms, &onLockRetry, app);
        }
        return;
    }
    const changed = !app.cursor_blink.sameSettings(wait_ms, on_ms, off_ms);
    if (Blink.blinks(on_ms, off_ms)) {
        // Only where it can be seen: a background window does not repaint
        // twice a second.
        if (!app.app_active) {
            if (app.blink_timer != 0) pause(app);
            return;
        }
        if (changed or app.blink_timer == 0) startWith(app, wait_ms, on_ms, off_ms);
    } else if (changed) {
        // start() records the settings and leaves the cursor shown, no timer.
        startWith(app, wait_ms, on_ms, off_ms);
    }
}
