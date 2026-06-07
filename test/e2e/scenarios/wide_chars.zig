// wide_chars — CJK (double width) and emoji + VS16 (multi-codepoint cell).
// Exercises: wide-char continuation cells and the cell_overflow map.

const std = @import("std");
const Harness = @import("../harness.zig").Harness;

pub fn run(alloc: std.mem.Allocator) !void {
    var h = try Harness.init(alloc, .{});
    defer h.deinit();

    // "あ" U+3042 (wide), "a", "⚠️" U+26A0 + U+FE0F (multi-codepoint cell).
    try h.input("iあa⚠️<Esc>");
    const g = h.winGrid();
    try h.waitRowText(g, 0, "あa⚠️", h.opts.timeout_ms);

    // Wide char occupies col 0; col 1 is the continuation cell (cp == 0).
    const c0 = h.cellAt(g, 0, 0);
    try std.testing.expectEqual(@as(u32, 0x3042), c0.cp);
    const c1 = h.cellAt(g, 0, 1);
    try std.testing.expectEqual(@as(u32, 0), c1.cp);
}
