// visual/split — multigrid split rendering.
//
// A :vsplit composites two window grids side by side with a vertical
// divider. This anchors split-window compositing in the client area —
// the area where the Windows "stale cursor in split windows" class of
// drawing bug (15cad19) lives. The cursor is parked steady in the left
// pane so its rendering is deterministic.

const std = @import("std");
const fixture = @import("fixture.zig");
const visual = @import("../../visual.zig");

pub fn run(alloc: std.mem.Allocator) !void {
    var g = try fixture.open(alloc);
    defer g.deinit();

    try fixture.exec(g,
        \\setline(1, ['split pane line 1', 'split pane line 2', 'split pane line 3', 'split pane line 4'])
    );
    try fixture.exec(g, "execute('vsplit')");
    try fixture.exec(g, "execute('normal! gg0')");

    var img = try g.captureStable(.{ .w_pt = 600, .h_pt = 300 }, 8000);
    defer img.deinit(alloc);
    try visual.assertMatch(alloc, "split", img, .{});
}
