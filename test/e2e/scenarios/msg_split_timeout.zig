// msg_split_timeout — a route timeout must close the split, but never while
// the cursor sits inside it.
//
// Phase 1 (regression): the split path used to ignore `route_result.timeout`
// entirely, so a configured timeout left the window open forever. The timer
// now lives in the generated Lua and restarts on every show.
//
// Phase 2: the countdown pauses while the cursor is inside the split (the
// user is reading it) and re-arms with the full timeout on leave — so the
// split must survive a hold longer than the timeout, then close on its own
// only after the cursor moves back out.

const std = @import("std");
const zc = @import("zonvie_core");
const Harness = @import("../harness.zig").Harness;

// 1.5s: long enough that the appearance wait (polling every ≤20ms) cannot
// miss the split's lifetime, and that phase 2 can move the cursor inside
// before the timer fires even under a CI scheduling stall; short enough that
// the 4s closure waits stay comfortable.
var routes = [_]zc.config.MsgRoute{
    .{ .filter = .{ .event = .msg_show }, .view = .split, .opts = .{ .timeout = 1.5 } },
};

/// Hold for `ms` while the event loop keeps running: a never-true wait whose
/// Timeout is the success case.
fn holdMs(h: *Harness, ms: u64) !void {
    h.waitUntil({}, struct {
        fn check(_: void, _: *Harness) bool {
            return false;
        }
    }.check, ms) catch |e| switch (e) {
        error.Timeout => {},
        else => return e,
    };
}

pub fn run(alloc: std.mem.Allocator) !void {
    var h = try Harness.init(alloc, .{ .ext_messages = true, .msg_routes = &routes });
    defer h.deinit();

    const start_windows = h.windowCount();
    const buffer_grid = h.winGrid();

    // Phase 1: untouched split auto-closes.
    try h.command("echo 'transient'");
    try h.waitWindowCount(start_windows + 1, h.opts.timeout_ms);

    // The timer is armed inside Neovim, so the window goes away on its own.
    // Allow well over the 1.5s deadline: this asserts "eventually closes",
    // not the precise instant, so a slow machine cannot make it flake.
    try h.waitWindowCount(start_windows, 4000);

    // Phase 2: a split the cursor sits in survives past the timeout.
    try h.command("echo 'held open'");
    try h.waitWindowCount(start_windows + 1, h.opts.timeout_ms);

    const ids = try h.positionedGridsAlloc(alloc);
    defer alloc.free(ids);
    var split_grid: i64 = 0;
    for (ids) |id| {
        if (id != buffer_grid and !h.isExternalGrid(id)) split_grid = id;
    }
    if (split_grid == 0) return error.SplitGridNotFound;

    try h.input("<C-w>w");
    try h.waitCursorGrid(split_grid, h.opts.timeout_ms);

    // Hold well past the 1.5s timeout; the paused countdown must not fire.
    try holdMs(h, 2500);
    if (h.windowCount() != start_windows + 1) {
        std.debug.print("[e2e] msg_split_timeout: split closed while the cursor was inside\n", .{});
        return error.ClosedWhileCursorInside;
    }

    // Leaving re-arms the full timeout; the split then closes on its own.
    try h.input("<C-w>w");
    try h.waitCursorGrid(buffer_grid, h.opts.timeout_ms);
    try h.waitWindowCount(start_windows, 4000);
}
