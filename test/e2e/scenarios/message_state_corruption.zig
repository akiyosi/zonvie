// message_state_corruption — verify that message/statusline state
// doesn't get corrupted when messages are displayed, cleared, and
// updated rapidly.
// Issue: #625 (Goneovim)

const std = @import("std");
const Harness = @import("../harness.zig").Harness;

pub fn run(alloc: std.mem.Allocator) !void {
    var h = try Harness.init(alloc, .{});
    defer h.deinit();

    // Create initial content
    try h.command("normal! gg");
    try h.command("normal! i");
    try h.input("test content");
    try h.input("<Escape>");

    // Trigger messages via search
    try h.command("/test");
    try h.input("<Escape>");

    // Trigger error message
    try h.command("normal! gg");
    try h.command("normal! 1000j");

    // Trigger multiple operations that generate messages
    try h.command("set showmode");

    try h.command("normal! i");
    try h.input("insert_mode");
    try h.input("<Escape>");

    // Command that produces message
    try h.command(":echo 'hello world'");

    // Search again
    try h.command("/content");
    try h.input("<Escape>");

    // Rapid command execution
    try h.command(":echo 'msg1'");
    try h.command(":echo 'msg2'");
    try h.command(":echo 'msg3'");

    // Message during editing
    try h.command("normal! i");
    try h.input("edit");
    try h.input("<Escape>");

    // Trigger substitution
    try h.command(":%s/test/TEST/");

    // More operations
    try h.command("normal! gg");
    try h.command("normal! dd");

    // Search with no matches
    try h.command("/nonexistent");
    try h.input("<Escape>");

    // Undo message
    try h.command("normal! u");

    // Redo message
    try h.command("normal! <C-r>");

    // Large operation (undo/redo multiple times)
    try h.command("normal! u");
    try h.command("normal! u");
    try h.command("normal! <C-r>");
    try h.command("normal! <C-r>");

    // More messages
    try h.command(":set ruler");
    try h.command(":set noruler");

    // Edit and error together
    try h.command("normal! i");
    try h.input("abc");
    try h.input("<Escape>");

    try h.command("normal! 999G");

    // Rapid escape key presses
    try h.input("<Escape>");
    try h.input("<Escape>");

    // More message-generating operations
    try h.command("normal! gg");
    try h.command("normal! yy");

    // Paste operation
    try h.command("normal! p");

    // Final state verification
    try h.command("normal! gg");
}
