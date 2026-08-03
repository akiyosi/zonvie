// msg_no_accumulation — messages whose display was handed off, or that were
// never displayed at all, must not pile up in the core.
//
// Regression: `skip`-routed messages were not counted as transient, so they
// accumulated toward the 1000-message cap, re-routed on every flush and
// eventually evicting real messages.
//
// Ordering: `requestCommand` is fire-and-forget, so the sample must not be
// taken until the 200 messages have demonstrably been processed. The buffer
// edit after the loop is the ordered signal — nvim executes the input keys
// only after the loop command completes, and the core applies redraw batches
// in order, so once "DONE" is visible every preceding msg_show batch (and the
// flush that dispatched it) has run.

const std = @import("std");
const zc = @import("zonvie_core");
const Harness = @import("../harness.zig").Harness;

// Explicitly hidden, which is a different thing from "no route matched".
var routes = [_]zc.config.MsgRoute{
    .{ .filter = .{ .event = .msg_show }, .opts = .{ .skip = true } },
};

pub fn run(alloc: std.mem.Allocator) !void {
    var h = try Harness.init(alloc, .{ .ext_messages = true, .msg_routes = &routes });
    defer h.deinit();

    const g = h.winGrid();
    try h.input("ianchor<Esc>");
    try h.waitRowText(g, 0, "anchor", h.opts.timeout_ms);

    // 200 hidden messages, then an ordered marker edit.
    try h.command("for i in range(200) | echomsg 'noise ' .. i | endfor");
    try h.input("oDONE<Esc>");
    try h.waitRowText(g, 1, "DONE", h.opts.timeout_ms);

    // All 200 messages have been through a dispatch cycle by now. A handful
    // from the final batch may legitimately still be in flight; hundreds is
    // the bug (accumulation would hold ~200 here).
    const pending = h.pendingMessageCount();
    if (pending > 16) {
        std.debug.print(
            "[e2e] msg_no_accumulation: core still holds {d} messages\n",
            .{pending},
        );
        return error.MessagesAccumulated;
    }
}
