// cmdline_cursor_animation — verify that cursor animation in command line
// works smoothly without flickering or position jumps.
// Issue: #3484 (Neovide)

const std = @import("std");
const Harness = @import("../harness.zig").Harness;

pub fn run(alloc: std.mem.Allocator) !void {
    var h = try Harness.init(alloc, .{});
    defer h.deinit();

    // Enable cursor animation
    try h.command("set guicursor+=a:blinkwait700-blinkoff400-blinkon400");

    // Enter command mode
    try h.input(":");

    // Type command character by character
    try h.input("e");
    try h.input("c");
    try h.input("h");
    try h.input("o");

    // Move cursor back within command
    try h.input("<Left>");

    // Verify cursor position
    try h.input("x");

    // Move forward
    try h.input("<Right>");

    // Delete character
    try h.input("<BS>");

    // Append more text
    try h.input(" ");
    try h.input("t");
    try h.input("e");
    try h.input("s");
    try h.input("t");

    // Move to beginning
    try h.input("<Home>");

    // Move to end
    try h.input("<End>");

    // Move back character by character
    try h.input("<Left>");
    try h.input("<Left>");
    try h.input("<Left>");

    // Cancel command
    try h.input("<Esc>");

    // Test again with longer input
    try h.input(":");

    // Type a longer command
    try h.input("s");
    try h.input("e");
    try h.input("t");
    try h.input(" ");
    try h.input("n");
    try h.input("u");
    try h.input("m");
    try h.input("b");
    try h.input("e");
    try h.input("r");

    // Navigate and edit
    try h.input("<Home>");
    try h.input("<Right>");
    try h.input("<Right>");
    try h.input("<Right>");

    // Delete and retype
    try h.input("<BS>");
    try h.input("l");

    // Cancel
    try h.input("<Esc>");

    // Test with special characters
    try h.input(":");

    try h.input("!");
    try h.input("l");
    try h.input("s");

    // Navigate through special chars
    try h.input("<Left>");
    try h.input("<Left>");

    // Cancel
    try h.input("<Esc>");

    // Final test: rapid cursor movement in cmdline
    try h.input(":");

    try h.input("a");
    try h.input("b");
    try h.input("c");
    try h.input("<Left>");
    try h.input("<Left>");
    try h.input("<Right>");
    try h.input("<Left>");
    try h.input("<Right>");
    try h.input("<Right>");

    try h.input("<Esc>");
}
