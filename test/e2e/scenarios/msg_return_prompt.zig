// msg_return_prompt — a press-enter prompt is answered, never displayed.
//
// noice answers return_prompt at the event layer with a single
// `nvim_input("<cr>")` (ui/init.lua:122-126) rather than routing it. Two
// defects this pins:
//   * the CR used to be sent twice, once by the route and once by the split
//   * once the route hardcode was removed, return_prompt fell through to the
//     catch-all and its text was rendered into the message grid, where it
//     also never got dropped
//
// Both show up as "return_prompt reached a view", so that is what is asserted.

const std = @import("std");
const Harness = @import("../harness.zig").Harness;
const MsgShowEvent = @import("../harness.zig").MsgShowEvent;

pub fn run(alloc: std.mem.Allocator) !void {
    // Default routing: the catch-all sends msg_show to ext_float.
    var h = try Harness.init(alloc, .{ .ext_messages = true });
    defer h.deinit();

    const g = h.winGrid();
    try h.input("ianchor<Esc>");
    try h.waitRowText(g, 0, "anchor", h.opts.timeout_ms);

    // More output than fits the message area is what makes Neovim ask for
    // a press-enter confirmation.
    try h.command("echo join(map(range(60), 'v:val'), \"\\n\")");

    // If the prompt were left unanswered, nvim would be blocked here and this
    // edit would never land.
    try h.input("oresponsive<Esc>");
    try h.waitRowText(g, 1, "responsive", h.opts.timeout_ms);

    // And the prompt itself must never have been handed to a view.
    if (h.hasMsgShow(struct {
        fn p(e: MsgShowEvent) bool {
            return std.mem.eql(u8, e.kind, "return_prompt");
        }
    }.p)) {
        h.dumpMsgShows();
        return error.ReturnPromptWasDisplayed;
    }
}
