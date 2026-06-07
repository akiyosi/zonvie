// insert_basic — type text in insert mode, assert cell content and cursor.
// Exercises: grid_line, grid_cursor_goto, flush.

const std = @import("std");
const Harness = @import("../harness.zig").Harness;

pub fn run(alloc: std.mem.Allocator) !void {
    var h = try Harness.init(alloc, .{});
    defer h.deinit();

    try h.input("ihello<Esc>");
    const g = h.winGrid();
    try h.waitRowText(g, 0, "hello", h.opts.timeout_ms);
    // After <Esc> the cursor sits on the last typed char.
    try h.waitCursor(0, 4, h.opts.timeout_ms);
}
