// visual/emoji_cursor_width — Cursor width is 1 cell regardless of neighbor width.
//
// Tests the contract: cursor block is always 1 cell wide, even when placed
// before a wide character (emoji, CJK). A regression would render the cursor
// at 2 cells wide before emoji, causing pixel-level visual mismatch against
// the golden baseline.

const std = @import("std");
const fixture = @import("fixture.zig");
const visual = @import("../../visual.zig");

pub fn run(alloc: std.mem.Allocator) !void {
    var g = try fixture.open(alloc);
    defer g.deinit();

    // Disable cursor blinking to keep snapshots deterministic.
    try g.exec("execute('set guicursor=a:block,a:blinkon0')");

    // Create buffer: "a😀b" (ASCII, emoji, ASCII).
    try g.exec(
        \\setline(1, ['a😀b'])
    );

    // Position 1: cursor on 'a' (ASCII).
    try g.exec("execute('normal! gg0')");
    var img = try g.captureStable(.{ .w_pt = 300, .h_pt = 150 }, 4000);
    defer img.deinit(alloc);
    try visual.assertMatch(alloc, "emoji_cursor_width_pos1_ascii", img, .{});

    // Position 2: cursor on '😀' (emoji, 2 cells wide in font metrics, but cursor = 1 cell).
    try g.exec("execute('normal! l')");
    img = try g.captureStable(.{ .w_pt = 300, .h_pt = 150 }, 4000);
    defer img.deinit(alloc);
    try visual.assertMatch(alloc, "emoji_cursor_width_pos2_emoji", img, .{});

    // Position 3: cursor on 'b' (ASCII again).
    try g.exec("execute('normal! l')");
    img = try g.captureStable(.{ .w_pt = 300, .h_pt = 150 }, 4000);
    defer img.deinit(alloc);
    try visual.assertMatch(alloc, "emoji_cursor_width_pos3_ascii", img, .{});

    // The visual assertion will fail if the cursor is rendered at 2 cells before the emoji,
    // which would show as a wider block in the middle position.
}
