// message_state_corruption — a burst of message-generating commands (echoes,
// searches) must not corrupt the buffer grid or leave nvim unresponsive.
// Note: general frontend robustness test; not derived from a specific
// upstream issue. (A prior header cited Goneovim #625, which is actually
// a PR for forcing IME off on mode change — unrelated.)

const std = @import("std");
const Harness = @import("../harness.zig").Harness;

pub fn run(alloc: std.mem.Allocator) !void {
    var h = try Harness.init(alloc, .{});
    defer h.deinit();

    const g = h.winGrid();

    // Put known content in the buffer.
    try h.input("itest content<Esc>");
    try h.waitRowText(g, 0, "test content", h.opts.timeout_ms);

    // Burst of messages: rapid echoes plus a search. None of these should
    // disturb the buffer grid (messages render in the cmdline area, not the
    // buffer rows).
    try h.command("echo 'msg1'");
    try h.command("echo 'msg2'");
    try h.command("echo 'msg3'");
    try h.command("nohlsearch");

    // Buffer content must still be intact after the message burst.
    try h.waitRowText(g, 0, "test content", h.opts.timeout_ms);

    // nvim is still responsive: a further edit applies normally.
    try h.input("oand more<Esc>");
    try h.waitRowText(g, 1, "and more", h.opts.timeout_ms);
}
