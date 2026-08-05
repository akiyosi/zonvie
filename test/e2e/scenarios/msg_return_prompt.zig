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
//
// HONEST LIMITATION: this scenario currently cannot fail. Probing nine
// command surfaces under Neovim 0.12 with `ext_messages` attached (long
// :echo, :!cmd, :echoerr, :source of a missing file, :version, :messages
// after 80 :echomsg, each both typed and via nvim_command) produced zero
// return_prompt events in the core log — the event appears not to be emitted
// to an ext_messages UI at all, though that was inferred from the absence,
// not from Neovim's source. A mutation making the core send two <CR>s left
// the whole suite green. It is kept as a tripwire for the day the event
// reappears; the assertions below are correct, they simply have nothing to
// observe today. The real coverage for the answer logic is the unit tests in
// src/core/flush.zig.

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
