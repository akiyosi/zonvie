// visual/baseline — anchor for the screenshot layer (Phase 2).
//
// Renders a fixed buffer (text, digits, box-drawing glyphs) in the real
// frontend, captures the client area, and compares to a per-OS golden.
// Catches glyph/shaping/color/layout regressions the logical-grid and
// window-count layers cannot see.

const std = @import("std");
const fixture = @import("fixture.zig");
const visual = @import("../../visual.zig");

pub fn run(alloc: std.mem.Allocator) !void {
    var g = try fixture.open(alloc);
    defer g.deinit();

    try fixture.exec(g,
        \\setline(1, ['Zonvie visual baseline', 'abcdefg 0123456789', '┌──────┐', '│ box  │', '└──────┘'])
    );
    try fixture.exec(g, "execute('normal! gg0')");

    var img = try g.captureStable(.{ .w_pt = 600, .h_pt = 300 }, 8000);
    defer img.deinit(alloc);
    try visual.assertMatch(alloc, "baseline", img, .{});
}
