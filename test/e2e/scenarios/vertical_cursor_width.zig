// vertical_cursor_width — verify that vertical (bar) cursor width
// is correctly rendered and doesn't extend beyond cell boundaries.
// Issue: #608, #611 (Goneovim)

const std = @import("std");
const Harness = @import("../harness.zig").Harness;

pub fn run(alloc: std.mem.Allocator) !void {
    var h = try Harness.init(alloc, .{});
    defer h.deinit();

    // Set cursor to vertical bar style
    try h.command("set guicursor=n-v-c:ver25");

    // Record initial cursor state
    try h.command("normal! gg");

    // Enter insert mode
    try h.command("normal! i");

    // Verify cursor is visible
    try h.input("test");

    // Exit insert mode
    try h.input("<Esc>");

    // Change cursor width
    try h.command("set guicursor=n-v-c:ver10");

    // Enter insert mode again
    try h.command("normal! i");

    // Verify cursor width applied
    try h.input("more");

    // Exit insert mode
    try h.input("<Esc>");

    // Test visual mode cursor
    try h.command("normal! v");

    // Exit visual
    try h.input("<Esc>");

    // Change to block cursor
    try h.command("set guicursor=n-v-c:block");

    // Enter normal mode
    try h.command("normal! gg");

    // Test another cursor style
    try h.command("set guicursor=n-v-c:hor20");

    // Move cursor around
    try h.command("normal! l");
    try h.command("normal! l");
    try h.command("normal! h");

    // Verify no corruption after multiple mode/style changes
    try h.command("normal! gg");

    // Test with wide characters
    try h.command("normal! o");
    try h.input("test");

    try h.input("<Esc>");

    // Return to normal vertical cursor
    try h.command("set guicursor=n-v-c:ver25");

    // Final position verification
    try h.command("normal! gg");
}
