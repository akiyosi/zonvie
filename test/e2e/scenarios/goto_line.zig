// goto_line — jump to specific line via :N command and verify cursor movement.
// Exercises: goto command, line jumping, cursor repositioning.

const std = @import("std");
const Harness = @import("../harness.zig").Harness;

pub fn run(alloc: std.mem.Allocator) !void {
    var h = try Harness.init(alloc, .{});
    defer h.deinit();

    // Insert 10 lines of text (0-9).
    var i: u8 = 0;
    while (i < 10) : (i += 1) {
        try h.input("i");
        try h.input(&.{i + '0'});
        try h.input("<Esc>o");
    }

    // Jump to line 5 via :5.
    try h.command("5");
    try h.waitCursor(4, 0, h.opts.timeout_ms);

    // Jump to line 1 via :1.
    try h.command("1");
    try h.waitCursor(0, 0, h.opts.timeout_ms);

    // Jump to last line.
    try h.command("$");
    try h.waitCursor(9, 0, h.opts.timeout_ms);
}
