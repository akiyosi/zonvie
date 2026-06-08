// visual/float — floating window compositing.
//
// An internal float (nvim_open_win, relative='editor', with a border) is
// composited over the main grid. This anchors float compositing in the
// client area — the area where the Windows "float double-cursor"/recompose
// class of drawing bug (73fb272) lives. enter=false keeps the cursor in
// the main grid (steady), so only the float's content/border varies the
// pixels from the baseline.

const std = @import("std");
const fixture = @import("fixture.zig");
const visual = @import("../../visual.zig");

pub fn run(alloc: std.mem.Allocator) !void {
    var g = try fixture.open(alloc);
    defer g.deinit();

    try fixture.exec(g,
        \\setline(1, ['main buffer line 1', 'main buffer line 2', 'main buffer line 3', 'main buffer line 4', 'main buffer line 5'])
    );
    try fixture.exec(g, "execute('normal! gg0')");
    // Internal float with a single border, fixed position/size/content.
    try fixture.exec(g,
        \\luaeval('(function() local b = vim.api.nvim_create_buf(false, true) vim.api.nvim_buf_set_lines(b, 0, -1, false, {"float A", "float B"}) vim.api.nvim_open_win(b, false, {relative="editor", row=2, col=8, width=16, height=2, style="minimal", border="single"}) return 1 end)()')
    );

    var img = try g.captureStable(.{ .w_pt = 600, .h_pt = 300 }, 8000);
    defer img.deinit(alloc);
    try visual.assertMatch(alloc, "float", img, .{});
}
