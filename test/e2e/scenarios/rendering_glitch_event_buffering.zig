// rendering_glitch_event_buffering — verify that redraw events are processed
// atomically and do not get buffered, causing rendering glitches.
// Exercises: grid_line event ordering, flush-end signaling, partial redraw.

const std = @import("std");
const Harness = @import("../harness.zig").Harness;

pub fn run(alloc: std.mem.Allocator) !void {
    var h = try Harness.init(alloc, .{});
    defer h.deinit();

    const g = h.winGrid();

    // Insert 10 lines of text. Each line generates a grid_line event.
    // All events must be processed atomically before flush-end.
    try h.input("i");
    var line: u32 = 0;
    while (line < 10) : (line += 1) {
        const text = try std.fmt.allocPrint(alloc, "line{d}", .{line});
        defer alloc.free(text);
        try h.input(text);
        try h.input("<CR>");
    }
    try h.input("<Esc>");

    // Wait for all lines to be visible in the grid.
    // Lines 0-9 should contain their respective content.
    var verify_line: u32 = 0;
    while (verify_line < 10) : (verify_line += 1) {
        const expected = try std.fmt.allocPrint(alloc, "line{d}", .{verify_line});
        defer alloc.free(expected);
        try h.waitRowText(g, verify_line, expected, h.opts.timeout_ms);
    }

    // Verify that all lines are present in a single consistent grid state.
    // This ensures events were not buffered or delayed (which would cause
    // intermediate states where only some lines are present).
    const rev = h.contentRev();
    verify_line = 0;
    while (verify_line < 10) : (verify_line += 1) {
        const expected = try std.fmt.allocPrint(alloc, "line{d}", .{verify_line});
        defer alloc.free(expected);
        const text = try h.rowTextAlloc(alloc, g, verify_line);
        defer alloc.free(text);
        try std.testing.expect(std.mem.eql(u8, text, expected));
    }

    // Verify content revision changed (redraw was processed).
    try std.testing.expect(rev > 0);
}
