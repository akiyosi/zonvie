// msg_split_timeout — a route timeout must actually close the split.
//
// Regression: the split path never read `route_result.timeout`, so a
// configured timeout was silently ignored and the window stayed forever.
// The timer now lives in the generated Lua and restarts on every show.

const std = @import("std");
const zc = @import("zonvie_core");
const Harness = @import("../harness.zig").Harness;

// 1.0s: long enough that the appearance wait (polling every ≤20ms) cannot
// miss the split's whole lifetime even under a CI scheduling stall; short
// enough that the 4s closure wait stays comfortable.
var routes = [_]zc.config.MsgRoute{
    .{ .filter = .{ .event = .msg_show }, .view = .split, .opts = .{ .timeout = 1.0 } },
};

pub fn run(alloc: std.mem.Allocator) !void {
    var h = try Harness.init(alloc, .{ .ext_messages = true, .msg_routes = &routes });
    defer h.deinit();

    const start_windows = h.windowCount();

    try h.command("echo 'transient'");
    try h.waitWindowCount(start_windows + 1, h.opts.timeout_ms);

    // The timer is armed inside Neovim, so the window goes away on its own.
    // Allow well over the 1.0s deadline: this asserts "eventually closes",
    // not the precise instant, so a slow machine cannot make it flake.
    try h.waitWindowCount(start_windows, 4000);
}
