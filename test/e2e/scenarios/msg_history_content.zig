// msg_history_content — `:messages` must show every message, once, in order.
//
// msg_history_split proves the assembled buffer is not CLIPPED (it grew past
// the old fixed 8 KiB limit). It does not prove the buffer is CORRECT: the
// assembly loop in showChannelView's `.split` arm (flush.zig:8975-8981) was
// reworked so an allocation failure aborts the flush for retry, and a retry
// that re-enters assembly without a clean `clearRetainingCapacity` would
// duplicate every entry — invisible to a length-only check, and invisible to
// a "some history line is on screen" check.
//
// So this asserts the three properties a user would notice: all N entries
// present, each exactly once, in the order Neovim emitted them.

const std = @import("std");
const zc = @import("zonvie_core");
const Harness = @import("../harness.zig").Harness;

const entry_count = 12;

pub fn run(alloc: std.mem.Allocator) !void {
    // Built-in defaults: view_history is `split` (msg_route.zig:156).
    var h = try Harness.init(alloc, .{ .ext_messages = true });
    defer h.deinit();

    const start_windows = h.windowCount();
    const buffer_grid = h.winGrid();

    // Distinct, unambiguous entries. `echomsg` so they enter :messages.
    // The ordered marker edit afterwards proves the loop finished before
    // `:messages` is asked for anything.
    try h.command("for i in range(12) | echomsg 'hist-entry-' .. i .. '-end' | endfor");
    try h.input("iDONE<Esc>");
    try h.waitRowText(buffer_grid, 0, "DONE", h.opts.timeout_ms);

    try h.command("messages");
    try h.waitWindowCount(start_windows + 1, h.opts.timeout_ms);

    // The split's content is assembled during the same dispatch that creates
    // the window, so by the time the window is observable the buffer holds
    // this show's text.
    const content = try h.splitContentAlloc(alloc);
    defer alloc.free(content);

    var search_from: usize = 0;
    var i: usize = 0;
    while (i < entry_count) : (i += 1) {
        var needle_buf: [32]u8 = undefined;
        const needle = try std.fmt.bufPrint(&needle_buf, "hist-entry-{d}-end", .{i});

        // Present, and after the previous entry: order.
        const at = std.mem.indexOfPos(u8, content, search_from, needle) orelse {
            std.debug.print(
                "[e2e] msg_history_content: entry {d} missing or out of order in {d} bytes of history\n",
                .{ i, content.len },
            );
            return error.HistoryEntryMissingOrUnordered;
        };

        // Exactly once: no second occurrence anywhere in the buffer.
        const first = std.mem.indexOf(u8, content, needle).?;
        if (std.mem.indexOfPos(u8, content, first + needle.len, needle) != null) {
            std.debug.print("[e2e] msg_history_content: entry {d} appears more than once\n", .{i});
            return error.HistoryEntryDuplicated;
        }

        search_from = at + needle.len;
    }
}
