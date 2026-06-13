// goto_line — jump to specific line via :N command and verify cursor movement.
// Exercises: goto command, line jumping, cursor repositioning.

const std = @import("std");
const Harness = @import("../harness.zig").Harness;

pub fn run(alloc: std.mem.Allocator) !void {
    var h = try Harness.init(alloc, .{});
    defer h.deinit();

    // Insert 10 lines numbered 0-9. Open each new line with `o` from normal
    // mode; reusing `i` while still in insert mode (left over from a prior `o`)
    // would type a literal 'i' into the line and leave a trailing empty line.
    try h.input("i0<Esc>");
    var i: u8 = 1;
    while (i < 10) : (i += 1) {
        try h.input("o");
        try h.input(&.{i + '0'});
        try h.input("<Esc>");
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
