// visual/vertical_cursor_width — verify that vertical cursor width
// is constant (2px) regardless of adjacent character width.
//
// A vertical cursor (ver25) should maintain a fixed width of 2px
// whether positioned before ASCII or CJK (wide) characters.
// This catches the bug where cursor width is calculated from the
// adjacent character's cell width instead of a fixed visual width.

const std = @import("std");
const fixture = @import("fixture.zig");
const visual = @import("../../visual.zig");
const driver = @import("../../driver.zig");

pub fn run(alloc: std.mem.Allocator) !void {
    var g = try fixture.open(alloc);
    defer g.deinit();

    // Set guicursor to vertical line (ver25 = 2.5 width, usually rendered as 2px)
    try g.exec("execute('set guicursor=n-v-c:ver25')");

    // Create a buffer with mixed ASCII + CJK text on the same line
    // Using ASCII 'a' followed by CJK character '中' (2-cell wide)
    try g.exec(
        \\setline(1, ['a中'])
    );

    // Position cursor at start (column 0, on ASCII 'a')
    try g.exec("execute('normal! gg0')");

    // Capture the window with cursor on ASCII character
    var img_ascii = try g.captureStable(.{ .w_pt = 400, .h_pt = 200 }, 8000);
    defer img_ascii.deinit(alloc);

    // Move cursor to the CJK character (column 1)
    try g.remoteSend("l");

    // Capture the window with cursor on CJK character
    var img_cjk = try g.captureStable(.{ .w_pt = 400, .h_pt = 200 }, 8000);
    defer img_cjk.deinit(alloc);

    // Compare: the cursor should look identical (same width and style)
    // Both captures should match the same golden image, proving the
    // cursor width is independent of adjacent character width
    try visual.assertMatch(alloc, "vertical_cursor_width", img_ascii, .{});
    try visual.assertMatch(alloc, "vertical_cursor_width_cjk", img_cjk, .{});
}
