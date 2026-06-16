// visual/float_border_continuity — verify floating window borders render
// continuously with no gaps or discontinuities at grid boundaries.
//
// A float with a border cell should not have gaps between border segments,
// overpaint beyond bounds, or missing corners. This catches the class of
// bug where cell quad generation miscalculates float extent, leaving visual
// artifacts in the completed border.

const std = @import("std");
const fixture = @import("fixture.zig");
const visual = @import("../../visual.zig");

pub fn run(alloc: std.mem.Allocator) !void {
    var g = try fixture.open(alloc);
    defer g.deinit();

    // Set up main buffer with visible text for context
    try g.exec(
        \\setline(1, ['line 1', 'line 2', 'line 3', 'line 4', 'line 5', 'line 6', 'line 7', 'line 8'])
    );
    try g.exec("execute('normal! gg0')");

    // Create a floating window with a single border
    try g.exec(
        \\luaeval('(function() local b = vim.api.nvim_create_buf(false, true) vim.api.nvim_buf_set_lines(b, 0, -1, false, {"border test", "content line"}) vim.api.nvim_open_win(b, false, {relative="editor", row=3, col=5, width=20, height=3, style="minimal", border="single"}) return 1 end)()')
    );

    var img = try g.captureStable(.{ .w_pt = 600, .h_pt = 300 }, 8000);
    defer img.deinit(alloc);
    try visual.assertMatch(alloc, "float_border_continuity", img, .{});
}
