// marks_navigate — test m (set mark) and ' (jump to mark) operations.
// Exercises: mark creation, mark jumping, cursor tracking across jumps.

const std = @import("std");
const Harness = @import("../harness.zig").Harness;

pub fn run(alloc: std.mem.Allocator) !void {
    var h = try Harness.init(alloc, .{});
    defer h.deinit();

    // Insert 5 lines numbered 0-4. Open each new line with `o` from normal
    // mode; reusing `i` while still in insert mode (from a prior `o`) would
    // type a literal 'i' into the line.
    try h.input("i0<Esc>");
    var i: u8 = 1;
    while (i < 5) : (i += 1) {
        try h.input("o");
        try h.input(&.{i + '0'});
        try h.input("<Esc>");
    }

    // Cursor is at line 4. Set mark 'a' here.
    try h.input("ma");
    try h.waitCursor(4, 0, h.opts.timeout_ms);

    // Jump to line 0 and set mark 'b' there.
    try h.input("gg");
    try h.waitCursor(0, 0, h.opts.timeout_ms);
    try h.input("mb");

    // Jump back to mark 'a' (line 4).
    try h.input("'a");
    try h.waitCursor(4, 0, h.opts.timeout_ms);

    // Jump to mark 'b' (line 0).
    try h.input("'b");
    try h.waitCursor(0, 0, h.opts.timeout_ms);
}
