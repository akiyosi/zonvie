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

    try g.exec(
        \\setline(1, ['split pane line 1', 'split pane line 2', 'split pane line 3', 'split pane line 4'])
    );
    try g.exec("execute('vsplit')");
    // Pin the divider to a fixed column. `:vsplit` alone halves the CURRENT
    // width, and the window size is not constant across runs: the app
    // autosaves its frame, so a scenario earlier in the suite that resizes
    // the window (set_columns_lines) leaves a different width behind for this
    // one. Halving a varying width put the divider — and with it the whole
    // right pane — in a different place than the golden.
    try g.exec("execute('vertical resize 40')");
    try g.exec("execute('normal! gg0')");

    var img = try g.captureStable(.{ .w_pt = 600, .h_pt = 300 }, 8000);
    defer img.deinit(alloc);
    try visual.assertMatch(alloc, "split", img, .{});
}
