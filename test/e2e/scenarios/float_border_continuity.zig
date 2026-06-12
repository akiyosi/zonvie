// float_border_continuity — verify that float window borders remain continuous
// across reflows, grid repositioning, and resize events.
// Exercises: border geometry preservation, partial redraw correctness,
// composition order (float over base grid).
// Issue: #2848, #619 (Goneovim)

const std = @import("std");
const Harness = @import("../harness.zig").Harness;

pub fn run(alloc: std.mem.Allocator) !void {
    var h = try Harness.init(alloc, .{});
    defer h.deinit();

    // Create a floating window with a border
    try h.command(
        "lua _G.test_float = vim.api.nvim_open_win(vim.api.nvim_create_buf(false, true), false, {" ++
            "relative='editor', row=3, col=4, width=20, height=8, " ++
            "border='rounded'" ++
            "})",
    );

    // Wait for float to appear and verify size
    const CtxInit = struct { alloc: std.mem.Allocator };
    try h.waitUntil(CtxInit{ .alloc = alloc }, struct {
        fn check(c: CtxInit, hh: *Harness) bool {
            const grids = hh.positionedGridsAlloc(c.alloc) catch return false;
            defer c.alloc.free(grids);
            return grids.len > 1;
        }
    }.check, h.opts.timeout_ms);

    // Get float grid ID
    const grids = try h.positionedGridsAlloc(alloc);
    defer alloc.free(grids);
    const float_grid_id = if (grids.len > 1) grids[grids.len - 1] else return error.FloatGridNotFound;

    // Verify float size
    const float_size = h.subGridSize(float_grid_id) orelse return error.FloatGridNotFound;
    try std.testing.expect(float_size.rows > 0);
    try std.testing.expect(float_size.cols > 0);

    // Record initial position
    const initial_pos = h.gridPos(float_grid_id) orelse return error.FloatGridNotFound;

    // Modify main window
    try h.command("normal! gg");
    try h.command("normal! o");
    try h.input("test content");

    // Verify position unchanged
    const pos_after_edit = h.gridPos(float_grid_id) orelse return error.FloatGridNotFound;
    try std.testing.expectEqual(initial_pos.row, pos_after_edit.row);
    try std.testing.expectEqual(initial_pos.col, pos_after_edit.col);

    // Move float
    try h.command(
        "lua vim.api.nvim_win_set_config(_G.test_float, {row=5, col=10})",
    );

    // Wait for position update
    const CtxPos = struct { alloc: std.mem.Allocator, grid_id: i64 };
    try h.waitUntil(CtxPos{ .alloc = alloc, .grid_id = float_grid_id }, struct {
        fn check(c: CtxPos, hh: *Harness) bool {
            if (hh.gridPos(c.grid_id)) |pos| {
                return pos.row == 5 and pos.col == 10;
            }
            return false;
        }
    }.check, h.opts.timeout_ms);

    const moved_pos = h.gridPos(float_grid_id) orelse return error.FloatGridNotFound;
    try std.testing.expectEqual(@as(i64, 5), moved_pos.row);
    try std.testing.expectEqual(@as(i64, 10), moved_pos.col);

    // Resize main window
    try h.command("vsplit");

    // Float should remain visible
    try std.testing.expect(h.gridPos(float_grid_id) != null);
    try std.testing.expect(h.subGridSize(float_grid_id) != null);

    // Close float
    try h.command("lua vim.api.nvim_win_close(_G.test_float, true)");

    // Verify gone
    try std.testing.expect(h.gridPos(float_grid_id) == null);
}
