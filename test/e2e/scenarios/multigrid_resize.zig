// multigrid_resize — :vsplit creates a second window grid at roughly half
// width; closing it removes the grid.
// Exercises: grid_resize, win_pos, grid_destroy under ext_multigrid.

const std = @import("std");
const Harness = @import("../harness.zig").Harness;

fn positionedCount(h: *Harness) usize {
    const ids = h.positionedGridsAlloc(h.alloc) catch return 0;
    defer h.alloc.free(ids);
    return ids.len;
}

pub fn run(alloc: std.mem.Allocator) !void {
    var h = try Harness.init(alloc, .{});
    defer h.deinit();

    const base_count = positionedCount(h);
    const main_grid = h.winGrid();
    const main_size = h.subGridSize(main_grid) orelse return error.GridNotFound;

    try h.command("vsplit");
    const Ctx = struct { base: usize };
    try h.waitUntil(Ctx{ .base = base_count }, struct {
        fn check(c: Ctx, hh: *Harness) bool {
            return positionedCount(hh) == c.base + 1;
        }
    }.check, h.opts.timeout_ms);

    // The new (focused) window grid is roughly half the original width.
    const split_grid = h.winGrid();
    try std.testing.expect(split_grid != main_grid);
    const split_size = h.subGridSize(split_grid) orelse return error.GridNotFound;
    try std.testing.expect(split_size.cols < main_size.cols);
    try std.testing.expect(split_size.cols >= main_size.cols / 2 - 2);

    try h.command("close");
    try h.waitUntil(Ctx{ .base = base_count }, struct {
        fn check(c: Ctx, hh: *Harness) bool {
            return positionedCount(hh) == c.base;
        }
    }.check, h.opts.timeout_ms);
}
