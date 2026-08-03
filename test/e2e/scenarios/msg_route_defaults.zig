// msg_route_defaults — declaring one route must not disable the others.
//
// Regression for the reported bug: a lone `[[messages.routes]]` entry used to
// REPLACE the whole route table, so msg_showmode and msg_history_show
// silently fell through to "none" and nothing appeared. User routes are now
// prepended to the built-in defaults.
//
// Both untouched-default checks are real observations:
//   * msg_showmode is recorded via the harness's on_msg_showmode callback,
//     which the core only invokes when the event routed to a visible view —
//     under the replace bug it routed to `none` and the callback never fired.
//   * msg_history_show's default is `split`, observed as a real Neovim
//     window appearing.

const std = @import("std");
const zc = @import("zonvie_core");
const Harness = @import("../harness.zig").Harness;
const MsgShowEvent = @import("../harness.zig").MsgShowEvent;

const view_mini: u8 = 0;

// The user declares exactly one rule, exactly as in the bug report.
var routes = [_]zc.config.MsgRoute{
    .{ .filter = .{ .event = .msg_show }, .view = .mini },
};

pub fn run(alloc: std.mem.Allocator) !void {
    var h = try Harness.init(alloc, .{ .ext_messages = true, .msg_routes = &routes });
    defer h.deinit();

    const start_windows = h.windowCount();

    // The declared route works. echomsg (rather than echo) so the message
    // also lands in `:messages` history for the third check.
    try h.command("echomsg 'routed'");
    try h.waitMsgShow(struct {
        fn p(e: MsgShowEvent) bool {
            return e.view == view_mini and std.mem.indexOf(u8, e.content, "routed") != null;
        }
    }.p, h.opts.timeout_ms);

    // msg_showmode keeps its default (mini): entering insert mode emits
    // "-- INSERT --" through on_msg_showmode. Under the replace bug the
    // event routed to `none` and this wait would time out.
    try h.input("i");
    try h.waitMsgShowmode(struct {
        fn p(e: MsgShowEvent) bool {
            return e.view == view_mini and std.mem.indexOf(u8, e.content, "INSERT") != null;
        }
    }.p, h.opts.timeout_ms);
    try h.input("<Esc>");
    try h.waitMode("normal", h.opts.timeout_ms);

    // msg_history_show keeps its default (split): `:messages` must open a
    // real window even though the user's route never mentioned history.
    try h.command("messages");
    h.waitWindowCount(start_windows + 1, h.opts.timeout_ms) catch |e| {
        std.debug.print("[e2e] msg_route_defaults: :messages produced no split — history default was lost\n", .{});
        return e;
    };
}
