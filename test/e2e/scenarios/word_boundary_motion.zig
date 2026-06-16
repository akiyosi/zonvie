// word_boundary_motion — test w/b/e word boundary movements.
// Exercises: word-wise cursor navigation, boundary detection.

const std = @import("std");
const Harness = @import("../harness.zig").Harness;

pub fn run(alloc: std.mem.Allocator) !void {
    var h = try Harness.init(alloc, .{});
    defer h.deinit();

    const g = h.winGrid();

    // Insert: "hello world test" (16 chars, indices 0-15)
    try h.input("ihello world test<Esc>");
    try h.waitRowText(g, 0, "hello world test", h.opts.timeout_ms);

    // After Esc, cursor is at last char 't' (col 15).
    try h.waitCursor(0, 15, h.opts.timeout_ms);

    // Move to start of line.
    try h.input("0");
    try h.waitCursor(0, 0, h.opts.timeout_ms);

    // Move forward one word: cursor should be at 'w' of "world" (col 6).
    try h.input("w");
    try h.waitCursor(0, 6, h.opts.timeout_ms);

    // Move forward one word: cursor should be at 't' of "test" (col 12).
    try h.input("w");
    try h.waitCursor(0, 12, h.opts.timeout_ms);

    // Move back one word: cursor should be at 'w' of "world" (col 6).
    try h.input("b");
    try h.waitCursor(0, 6, h.opts.timeout_ms);

    // Move to end of current word "world" (col 10).
    try h.input("e");
    try h.waitCursor(0, 10, h.opts.timeout_ms);
}
