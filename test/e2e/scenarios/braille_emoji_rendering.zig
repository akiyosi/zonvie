// braille_emoji_rendering — Braille patterns and emoji render correctly without width artifacts.
// Neovide #3470: Braille and emoji characters were rendered with incorrect width calculations.
// Exercises: glyph width calculation, unicode character handling.

const std = @import("std");
const Harness = @import("../harness.zig").Harness;

pub fn run(alloc: std.mem.Allocator) !void {
    var h = try Harness.init(alloc, .{});
    defer h.deinit();

    // Insert braille patterns and emoji in a single line.
    // ⠿ = U+283F (Braille Pattern All Dots), 😀 = U+1F600 (Grinning Face emoji).
    try h.input("i⠿⠿⠿ 😀 test<Esc>");
    const g = h.winGrid();
    try h.waitRowText(g, 0, "⠿⠿⠿ 😀 test", h.opts.timeout_ms);

    // Verify that each braille character occupies exactly 1 cell.
    // Row 0: ⠿(col 0), ⠿(col 1), ⠿(col 2), space(col 3), 😀(col 4-5, wide).
    const c0 = h.cellAt(g, 0, 0);
    try std.testing.expectEqual(@as(u32, 0x283F), c0.cp); // First braille
    const c1 = h.cellAt(g, 0, 1);
    try std.testing.expectEqual(@as(u32, 0x283F), c1.cp); // Second braille
    const c2 = h.cellAt(g, 0, 2);
    try std.testing.expectEqual(@as(u32, 0x283F), c2.cp); // Third braille
    const c3 = h.cellAt(g, 0, 3);
    try std.testing.expectEqual(@as(u32, ' '), c3.cp); // Space
    const c4 = h.cellAt(g, 0, 4);
    try std.testing.expectEqual(@as(u32, 0x1F600), c4.cp); // Emoji (starts at col 4, wide)
    const c5 = h.cellAt(g, 0, 5);
    try std.testing.expectEqual(@as(u32, 0), c5.cp); // Emoji continuation (col 5 should be 0)
}
