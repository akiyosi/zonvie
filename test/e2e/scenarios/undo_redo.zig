// undo_redo — buffer content round-trips through undo and redo, and the
// grid reflects each step. Exercises full-line rewrites driven by content
// changes rather than direct typing.

const std = @import("std");
const Harness = @import("../harness.zig").Harness;

pub fn run(alloc: std.mem.Allocator) !void {
    var h = try Harness.init(alloc, .{});
    defer h.deinit();

    try h.input("ihello world<Esc>");
    const g = h.winGrid();
    try h.waitRowText(g, 0, "hello world", h.opts.timeout_ms);

    // Undo removes the insert: line 0 becomes empty.
    try h.input("u");
    try h.waitRowText(g, 0, "", h.opts.timeout_ms);

    // Redo re-applies it.
    try h.input("<C-r>");
    try h.waitRowText(g, 0, "hello world", h.opts.timeout_ms);
}
