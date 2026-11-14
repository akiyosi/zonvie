//! The one-shot timers the core leaves to its frontend (zonvie_core.h): the
//! message and render-maintenance deadline, and the retry of an aborted
//! flush. Neither is driven by a redraw, so without them a message float
//! outlives its timeout and an aborted frame stays stale while Neovim is
//! idle. GTK main thread only.
//!
//! Both ticks run a flush on this thread with grid_mu held, so the core
//! callbacks then run here too, never while App.mu is held.

const std = @import("std");
const core = @import("zonvie_core");
const App = @import("app.zig").App;
const gtk = @import("gtk_bindings.zig");

/// Retry delay when the core's grid lock is busy.
const lock_retry_ms = 16;
/// An aborted flush is retried after this long, doubling while it keeps
/// failing: a long cap leaves a recovered frame stale for as long.
const flush_retry_first_ms = 16;
const flush_retry_max_ms = 128;

fn appFrom(data: ?*anyopaque) *App {
    return @ptrCast(@alignCast(data.?));
}

/// Re-arms the message timer from the core's earliest deadline. Call after
/// anything that can move it: a flush end, a scroll sent to the core.
pub fn scheduleMsg(app: *App) void {
    if (app.msg_timer != 0) {
        _ = gtk.g_source_remove(app.msg_timer);
        app.msg_timer = 0;
    }
    const cp = app.corep orelse return;
    const ms = core.zonvie_core_try_next_msg_timeout_ms(cp);
    if (ms == -1) return;
    // -2: the lock was busy, which is not "nothing pending".
    if (ms < 0) {
        app.msg_timer = gtk.g_timeout_add(lock_retry_ms, &onMsgLockRetry, app);
        return;
    }
    app.msg_timer = gtk.g_timeout_add(@intCast(@min(ms, std.math.maxInt(c_uint))), &onMsgDue, app);
}

fn onMsgLockRetry(data: ?*anyopaque) callconv(.c) c_int {
    const app = appFrom(data);
    app.msg_timer = 0;
    scheduleMsg(app);
    return 0;
}

fn onMsgDue(data: ?*anyopaque) callconv(.c) c_int {
    const app = appFrom(data);
    app.msg_timer = 0;
    if (app.corep) |cp| core.zonvie_core_tick_msg_throttle(cp);
    scheduleMsg(app);
    return 0;
}

/// Acts on what the flushes since the last call came to: a commit ends the
/// retries, a retryable abort arms one.
pub fn settleFlush(app: *App) void {
    switch (app.flush_outcome.swap(.none, .acq_rel)) {
        .none => {},
        .committed => {
            if (app.flush_retry_timer != 0) _ = gtk.g_source_remove(app.flush_retry_timer);
            app.flush_retry_timer = 0;
            app.flush_retry_delay_ms = flush_retry_first_ms;
        },
        .aborted => {
            if (app.flush_retry_timer != 0) return;
            app.flush_retry_timer = gtk.g_timeout_add(app.flush_retry_delay_ms, &onFlushRetry, app);
            app.flush_retry_delay_ms = @min(app.flush_retry_delay_ms * 2, flush_retry_max_ms);
        },
    }
}

fn onFlushRetry(data: ?*anyopaque) callconv(.c) c_int {
    const app = appFrom(data);
    app.flush_retry_timer = 0;
    if (app.corep) |cp| core.zonvie_core_retry_flush(cp);
    return 0;
}
