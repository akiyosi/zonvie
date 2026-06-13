// copy_paste_yank — test y (yank) and p (paste) register operations.
// Exercises: register management, yank buffer, paste operations.

const std = @import("std");
const Harness = @import("../harness.zig").Harness;

pub fn run(alloc: std.mem.Allocator) !void {
    var h = try Harness.init(alloc, .{});
    defer h.deinit();

    const g = h.winGrid();

    // Insert initial text "hello world".
    try h.input("ihello world<Esc>");
    try h.waitRowText(g, 0, "hello world", h.opts.timeout_ms);

    // Yank the whole line (linewise) and paste it below; the pasted copy must
    // match the original. Linewise yy/p is unambiguous about register contents
    // and paste position — charwise yaw/p depends on aw's trailing-space and
    // p's after-cursor semantics, which made the previous assertion wrong.
    try h.input("yy");
    try h.input("p");
    try h.waitRowText(g, 1, "hello world", h.opts.timeout_ms);
}
