// visual/pmenusel_bounds — verify completion popup pmenusel highlight
// respects cell boundaries with no 1-cell overpaint.
//
// A popup menu with pmenusel (selected item) highlight must extend exactly
// to cell width, not overflow by 1 cell. This catches the class of bug where
// the highlight quad is calculated beyond grid extent.

const std = @import("std");
const fixture = @import("fixture.zig");
const visual = @import("../../visual.zig");

pub fn run(alloc: std.mem.Allocator) !void {
    var g = try fixture.open(alloc);
    defer g.deinit();

    // Set up a buffer with completable content
    try g.exec(
        \\setline(1, ['apple', 'apricot', 'avocado', 'banana', 'blueberry', 'cherry'])
    );
    try g.exec("execute('normal! gg0')");

    // Set up completion to use popup style
    try g.exec("set completeopt=menuone,popup");

    // Start insert mode and type a prefix to trigger completion
    try g.exec("execute('normal! Aa')");

    // Trigger completion with Ctrl-N
    try g.remoteSend("<C-n>");

    var img = try g.captureStable(.{ .w_pt = 600, .h_pt = 300 }, 8000);
    defer img.deinit(alloc);
    try visual.assertMatch(alloc, "pmenusel_bounds", img, .{});
}
