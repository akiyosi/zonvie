// substitute — :%s replaces text and the grid reflects the new content.
// Exercises a command-driven multi-cell rewrite across the line.

const std = @import("std");
const Harness = @import("../harness.zig").Harness;

pub fn run(alloc: std.mem.Allocator) !void {
    var h = try Harness.init(alloc, .{});
    defer h.deinit();

    try h.input("ifoo foo foo<Esc>");
    const g = h.winGrid();
    try h.waitRowText(g, 0, "foo foo foo", h.opts.timeout_ms);

    try h.command("%s/foo/bar/g");
    try h.waitRowText(g, 0, "bar bar bar", h.opts.timeout_ms);
}
