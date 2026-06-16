// edit_dd — delete a line, assert the remaining lines shift up.
// Exercises: grid_line rewrites across multiple rows.

const std = @import("std");
const Harness = @import("../harness.zig").Harness;

pub fn run(alloc: std.mem.Allocator) !void {
    var h = try Harness.init(alloc, .{});
    defer h.deinit();

    try h.input("ione<CR>two<CR>three<Esc>");
    const g = h.winGrid();
    try h.waitRowText(g, 2, "three", h.opts.timeout_ms);

    try h.input("ggdd");
    try h.waitRowText(g, 0, "two", h.opts.timeout_ms);
    try h.waitRowText(g, 1, "three", h.opts.timeout_ms);
}
