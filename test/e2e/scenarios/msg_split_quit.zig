// msg_split_quit — a leftover message split must not keep Neovim alive.
//
// Reported: with the split still open, `:q` closed the editor window and left
// the scratch split as the only window, so nvim never exited. The split now
// closes itself on QuitPre when it would be the last window standing.

const std = @import("std");
const zc = @import("zonvie_core");
const Harness = @import("../harness.zig").Harness;

var routes = [_]zc.config.MsgRoute{
    .{ .filter = .{ .event = .msg_show }, .view = .split, .opts = .{ .timeout = 0 } },
};

pub fn run(alloc: std.mem.Allocator) !void {
    var h = try Harness.init(alloc, .{ .ext_messages = true, .msg_routes = &routes });
    defer h.deinit();

    const start_windows = h.windowCount();

    try h.command("echo 'still here'");
    try h.waitWindowCount(start_windows + 1, h.opts.timeout_ms);

    // The split does not take focus, so `:q` targets the editor window.
    // With the split counted as an ordinary window, this used to leave nvim
    // running with nothing but the scratch buffer on screen.
    try h.command("q");
    h.waitExit(4000) catch |e| switch (e) {
        error.Timeout => {
            std.debug.print(
                "[e2e] msg_split_quit: nvim still running after :q ({d} window(s) left)\n",
                .{h.windowCount()},
            );
            return error.SplitBlockedQuit;
        },
        else => return e,
    };
}
