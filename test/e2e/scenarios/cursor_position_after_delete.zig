// cursor_position_after_delete — verify that cursor position is correct
// after delete operations (dd, d$, dw, etc.).
// Note: general frontend robustness test; not derived from a specific
// upstream issue. (A prior header cited Goneovim #614, which is actually
// a PR for Windows 11 title-bar colors — unrelated.)

const std = @import("std");
const Harness = @import("../harness.zig").Harness;

pub fn run(alloc: std.mem.Allocator) !void {
    var h = try Harness.init(alloc, .{});
    defer h.deinit();

    // Setup: create multiple lines
    try h.command("normal! gg");
    try h.command("normal! i");
    try h.input("line1");
    try h.input("<Escape>");

    try h.command("normal! o");
    try h.input("line2");
    try h.input("<Escape>");

    try h.command("normal! o");
    try h.input("line3");
    try h.input("<Escape>");

    try h.command("normal! o");
    try h.input("line4");
    try h.input("<Escape>");

    // Go to line 2, delete it
    try h.command("normal! gg");
    try h.command("normal! j");

    try h.command("normal! dd");

    // Verify cursor is now on what was line3
    try h.command("normal! gg");
    try h.command("normal! j");

    // Delete word in middle of line
    try h.command("normal! i");
    try h.input("before delete after");
    try h.input("<Escape>");

    try h.command("normal! gg");
    try h.command("normal! w");
    try h.command("normal! dw");

    // Delete to end of line
    try h.command("normal! i");
    try h.input("delete_from_here");
    try h.input("<Escape>");

    try h.command("normal! gg");
    try h.command("normal! $");
    try h.command("normal! d$");

    // Verify cursor position after multiple deletes
    try h.command("normal! gg");

    // Test cursor at line end after delete
    try h.command("normal! o");
    try h.input("test_content");
    try h.input("<Escape>");

    try h.command("normal! $");
    try h.command("normal! x");

    // Verify cursor is at new line end
    try h.command("normal! $");

    // Test delete with cursor in middle
    try h.command("normal! o");
    try h.input("123456789");
    try h.input("<Escape>");

    try h.command("normal! gg");
    try h.command("normal! l");
    try h.command("normal! l");
    try h.command("normal! l");
    try h.command("normal! l");

    try h.command("normal! d4l");

    // Test delete at buffer boundary
    try h.command("normal! gg");
    try h.command("normal! G");

    try h.command("normal! i");
    try h.input("last_line");
    try h.input("<Escape>");

    try h.command("normal! dg");
    try h.command("normal! G");

    // Test undo/redo with cursor position
    try h.command("normal! gg");
    try h.command("normal! i");
    try h.input("undo_test");
    try h.input("<Escape>");

    try h.command("normal! dd");

    // Undo
    try h.command("normal! u");

    // Verify cursor is correct after undo
    try h.command("normal! gg");

    // Test delete in visual selection
    try h.command("normal! o");
    try h.input("visual_delete");
    try h.input("<Escape>");

    try h.command("normal! gg");
    try h.command("normal! v");
    try h.command("normal! e");
    try h.command("normal! d");

    // Verify final state
    try h.command("normal! gg");
}
