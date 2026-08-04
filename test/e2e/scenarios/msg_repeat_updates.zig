// msg_repeat_updates — repeated messages must update the ext_float view, not
// stack up in it or leak into the core's message array.
//
// ext_float is the one `retained` view (msg_view.zig:37-46): its messages are
// deliberately NOT dropped after dispatch, because the grid is rebuilt from
// the array every cycle. That makes it the only view where an accumulation
// bug is invisible to msg_no_accumulation (which uses a transient view), and
// where the 1000-message cap is reachable through ordinary use.
//
// timeout = 0 so nothing is swept away by an auto-hide while the scenario is
// looking at it — accumulation has to be ruled out on its own merits.
//
// Ordering: `requestCommand` is fire-and-forget, so every assertion is made
// only after an ordered signal. Content appearing in the message grid is that
// signal for the two-message case; for the 100-message burst it is a buffer
// edit issued after the loop, which nvim cannot execute until the loop has
// finished and whose redraw the core applies strictly after every preceding
// msg_show batch.

const std = @import("std");
const zc = @import("zonvie_core");
const Harness = @import("../harness.zig").Harness;

const msg_grid: i64 = -102;

var routes = [_]zc.config.MsgRoute{
    .{ .filter = .{ .event = .msg_show }, .view = .ext_float, .opts = .{ .timeout = 0 } },
};

fn gridHas(h: *Harness, needle: []const u8) bool {
    var row: u32 = 0;
    while (row < 64) : (row += 1) {
        const text = h.rowTextAlloc(h.alloc, msg_grid, row) catch continue;
        defer h.alloc.free(text);
        if (std.mem.indexOf(u8, text, needle) != null) return true;
    }
    return false;
}

pub fn run(alloc: std.mem.Allocator) !void {
    var h = try Harness.init(alloc, .{ .ext_messages = true, .msg_routes = &routes });
    defer h.deinit();

    const buffer_grid = h.winGrid();
    try h.input("ianchor<Esc>");
    try h.waitRowText(buffer_grid, 0, "anchor", h.opts.timeout_ms);

    // Two messages in a row: the second must be reachable in the view.
    try h.command("echo 'alpha marker'");
    try h.waitUntil({}, struct {
        fn check(_: void, hh: *Harness) bool {
            return gridHas(hh, "alpha marker");
        }
    }.check, h.opts.timeout_ms);
    const after_first = h.pendingMessageCount();

    try h.command("echo 'bravo marker'");
    h.waitUntil({}, struct {
        fn check(_: void, hh: *Harness) bool {
            return gridHas(hh, "bravo marker");
        }
    }.check, h.opts.timeout_ms) catch |e| {
        std.debug.print("[e2e] msg_repeat_updates: a second message did not update the view\n", .{});
        return e;
    };
    const after_second = h.pendingMessageCount();
    if (after_second > after_first + 1) {
        std.debug.print(
            "[e2e] msg_repeat_updates: one extra message grew the array from {d} to {d}\n",
            .{ after_first, after_second },
        );
        return error.MessageArrayGrewUnexpectedly;
    }

    // 100 messages, then an ordered marker edit. The array must not be
    // holding a message per echo by the time the marker lands.
    try h.command("for i in range(100) | echo 'burst ' .. i | endfor");
    try h.input("oDONE<Esc>");
    try h.waitRowText(buffer_grid, 1, "DONE", h.opts.timeout_ms);

    const pending = h.pendingMessageCount();
    if (pending > 4) {
        std.debug.print(
            "[e2e] msg_repeat_updates: core holds {d} messages after 100 echoes\n",
            .{pending},
        );
        return error.MessagesStacked;
    }

    // And the view still reflects the LAST message of the burst, not a
    // stale one from the start of it.
    h.waitUntil({}, struct {
        fn check(_: void, hh: *Harness) bool {
            return gridHas(hh, "burst 99");
        }
    }.check, h.opts.timeout_ms) catch |e| {
        std.debug.print("[e2e] msg_repeat_updates: the last message of the burst is not in the view\n", .{});
        return e;
    };
}
