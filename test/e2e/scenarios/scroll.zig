// scroll — fill 100 lines, jump to the bottom, assert the viewport scrolled.
// Exercises: grid_scroll (and the scroll fast path bookkeeping).

const std = @import("std");
const Harness = @import("../harness.zig").Harness;

pub fn run(alloc: std.mem.Allocator) !void {
    var h = try Harness.init(alloc, .{});
    defer h.deinit();

    try h.command("call setline(1, map(range(1, 100), 'string(v:val)'))");
    const g = h.winGrid();
    try h.waitRowText(g, 0, "1", h.opts.timeout_ms);

    try h.input("G");
    // After G the window's last row shows line 100.
    const size = h.subGridSize(g) orelse return error.GridNotFound;
    try h.waitRowText(g, size.rows - 1, "100", h.opts.timeout_ms);
}
