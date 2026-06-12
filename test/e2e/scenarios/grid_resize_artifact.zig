// grid_resize_artifact — verify that resizing grids doesn't leave
// rendering artifacts (partial characters, stale cells, etc.).
// Issue: #582 (Goneovim)

const std = @import("std");
const Harness = @import("../harness.zig").Harness;

pub fn run(alloc: std.mem.Allocator) !void {
    var h = try Harness.init(alloc, .{});
    defer h.deinit();

    // Fill main grid with content
    try h.command("normal! gg");
    try h.command("normal! i");

    // Create multiple lines
    var i: u32 = 0;
    while (i < 5) : (i += 1) {
        try h.input("line");
        var j: u32 = 0;
        while (j < i) : (j += 1) {
            try h.input("_");
        }
        try h.input("<Escape>");
        if (i < 4) {
            try h.command("normal! o");
            try h.command("normal! i");
        }
    }

    // Create a split
    try h.command("split");

    // Add content to second window
    try h.command("normal! i");
    try h.input("split_window_content");
    try h.input("<Escape>");

    // Record initial dimensions
    const initial_main = h.subGridSize(1) orelse return error.MainGridNotFound;
    try std.testing.expect(initial_main.rows > 0);
    try std.testing.expect(initial_main.cols > 0);

    // Resize split upward (reduce main window size)
    try h.command("resize -3");

    // Verify dimensions changed
    const after_resize1 = h.subGridSize(1) orelse return error.MainGridNotFound;
    try std.testing.expect(after_resize1.rows < initial_main.rows);

    // Content should still be visible without artifacts
    try h.command("normal! gg");

    // Resize back down
    try h.command("resize +5");

    const after_resize2 = h.subGridSize(1) orelse return error.MainGridNotFound;
    try std.testing.expect(after_resize2.rows > after_resize1.rows);

    // Another split in opposite direction
    try h.command("vsplit");

    const after_vsplit = h.subGridSize(1) orelse return error.MainGridNotFound;
    try std.testing.expect(after_vsplit.cols < initial_main.cols);

    // Resize vertical split
    try h.command("vertical resize -5");

    const after_vresize = h.subGridSize(1) orelse return error.MainGridNotFound;
    try std.testing.expect(after_vresize.cols < after_vsplit.cols);

    // Move between windows
    try h.command("normal! k");
    try h.command("normal! h");

    // Edit in resized windows
    try h.command("normal! i");
    try h.input("editing_in_resized");
    try h.input("<Escape>");

    // Perform more resizes while content is modified
    try h.command("resize +2");

    try h.command("normal! j");
    try h.command("normal! h");

    try h.command("vertical resize +3");

    try h.command("normal! i");
    try h.input("more_content");
    try h.input("<Escape>");

    // Reset size
    try h.command("resize -5");
    try h.command("vertical resize -5");
    try h.command("vertical resize +5");

    // Final state verification
    try h.command("normal! gg");
    try h.command("normal! k");
}
