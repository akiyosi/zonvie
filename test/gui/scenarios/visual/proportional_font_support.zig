// visual/proportional_font_support — Variable-width fonts layout correctly.
// Goneovim #591: Proportional fonts could cause alignment artifacts.
// Tests: font metric calculation, glyph width handling in variable-pitch fonts.

const std = @import("std");
const fixture = @import("fixture.zig");
const visual = @import("../../visual.zig");

pub fn run(alloc: std.mem.Allocator) !void {
    var g = try fixture.open(alloc);
    defer g.deinit();

    // Disable cursor blinking to keep snapshots deterministic.
    try g.exec("execute('set guicursor=a:block,a:blinkon0')");

    // Set a proportional font (if available; fallback to default if not).
    // Helvetica is available on macOS; on other platforms, the system will choose.
    try g.exec("execute('set guifont=Helvetica:h12')");

    // Create test content with variable-width characters:
    // "iiiii" (narrow) vs "mmmmmm" (wide in proportional fonts).
    try g.exec(
        \\setline(1, ['iiiiii', 'mmmmmm'])
    );

    // Capture row 0 (narrow characters).
    // Distinct variable per capture: `defer img.deinit` evaluates `img` at
    // scope exit, so a reused variable would double-free the last image and
    // leak the earlier one.
    try g.exec("execute('normal! gg0')");
    var img_narrow = try g.captureStable(.{ .w_pt = 400, .h_pt = 150 }, 4000);
    defer img_narrow.deinit(alloc);
    try visual.assertMatch(alloc, "proportional_font_narrow", img_narrow, .{});

    // Capture row 1 (wide characters).
    try g.exec("execute('normal! j0')");
    var img_wide = try g.captureStable(.{ .w_pt = 400, .h_pt = 150 }, 4000);
    defer img_wide.deinit(alloc);
    try visual.assertMatch(alloc, "proportional_font_wide", img_wide, .{});
}
