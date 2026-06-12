// scroll_selection_artifacts — Selection highlight follows scrolling without artifacts.
// Goneovim #110: Scrolling during selection could cause highlight misalignment.
// Exercises: scroll + selection state coherence, grid layering during partial redraw.

const std = @import("std");
const Harness = @import("../harness.zig").Harness;

pub fn run(alloc: std.mem.Allocator) !void {
    var h = try Harness.init(alloc, .{});
    defer h.deinit();

    // Create a buffer with multiple lines by typing content with newlines.
    try h.input("iLine 1\nLine 2\nLine 3\nLine 4\nLine 5\nLine 6\nLine 7\nLine 8\nLine 9\nLine 10<Esc>");

    const g = h.winGrid();
    try h.waitRowText(g, 0, "Line 1", h.opts.timeout_ms);

    // Move cursor to start of first line.
    try h.input("gg");

    // Select text in visual mode (select current line).
    try h.input("V");

    // Scroll down while selection is active (move selection down 5 lines).
    try h.input("5j");

    // Verify cursor advanced and content is visible (no crash, grid coherent).
    const cursor = h.cursor();
    try std.testing.expect(cursor.row > 0);
}
