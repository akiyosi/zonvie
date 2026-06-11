// float_lifecycle — verify float grid creation, rendering, and destruction
// with no orphan grids left behind in the render list.
// Exercises: grid creation → rendering in draw list → cleanup on float close.

const std = @import("std");
const Harness = @import("../harness.zig").Harness;

pub fn run(alloc: std.mem.Allocator) !void {
    var h = try Harness.init(alloc, .{});
    defer h.deinit();

    // Record baseline grids (should be just grid 1, the main window)
    const baseline = try h.positionedGridsAlloc(alloc);
    defer alloc.free(baseline);

    // Create a floating window
    try h.command(
        "lua _G.test_float = vim.api.nvim_open_win(vim.api.nvim_create_buf(false, true), false, " ++
            "{relative='editor', row=2, col=5, width=15, height=4})",
    );

    // Wait for the float grid to appear
    const Ctx = struct { baseline: []const i64 };
    try h.waitUntil(Ctx{ .baseline = baseline }, struct {
        fn check(c: Ctx, hh: *Harness) bool {
            const now = hh.positionedGridsAlloc(hh.alloc) catch return false;
            defer hh.alloc.free(now);
            for (now) |id| {
                for (c.baseline) |bid| {
                    if (id == bid) break;
                } else return true;
            }
            return false;
        }
    }.check, h.opts.timeout_ms);

    // Record the float grid ID
    const after_create = try h.positionedGridsAlloc(alloc);
    defer alloc.free(after_create);
    var float_grid_id: i64 = 0;
    for (after_create) |id| {
        for (baseline) |bid| {
            if (id == bid) break;
        } else float_grid_id = id;
    }
    try std.testing.expect(float_grid_id != 0);

    // Verify the float grid is visible (has non-zero size)
    const float_size = h.subGridSize(float_grid_id) orelse return error.FloatGridNotFound;
    try std.testing.expect(float_size.rows > 0);
    try std.testing.expect(float_size.cols > 0);

    // Close the float
    try h.command("lua vim.api.nvim_win_close(_G.test_float, true)");

    // Wait for the float grid to be removed from positioned grids
    const Ctx2 = struct { float_grid_id: i64 };
    try h.waitUntil(Ctx2{ .float_grid_id = float_grid_id }, struct {
        fn check(c: Ctx2, hh: *Harness) bool {
            return hh.gridPos(c.float_grid_id) == null;
        }
    }.check, h.opts.timeout_ms);

    // Verify the final state matches baseline: no orphan grids
    const final = try h.positionedGridsAlloc(alloc);
    defer alloc.free(final);

    try std.testing.expectEqual(baseline.len, final.len);
    for (baseline) |bid| {
        for (final) |fid| {
            if (bid == fid) break;
        } else return error.BaselineGridMissing;
    }
}
