// float_position_update_race — verify that rapid float position updates
// don't cause rendering artifacts or position inconsistencies.
// Issue: #603 (Goneovim)

const std = @import("std");
const Harness = @import("../harness.zig").Harness;

pub fn run(alloc: std.mem.Allocator) !void {
    var h = try Harness.init(alloc, .{});
    defer h.deinit();

    // Create a floating window
    try h.command(
        "lua _G.test_float = vim.api.nvim_open_win(vim.api.nvim_create_buf(false, true), false, {" ++
            "relative='editor', row=2, col=2, width=10, height=4" ++
            "})",
    );

    // Wait for float to appear
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

    // Rapid position updates
    try h.command(
        "lua vim.api.nvim_win_set_config(_G.test_float, {row=3, col=3})",
    );

    try h.command(
        "lua vim.api.nvim_win_set_config(_G.test_float, {row=4, col=4})",
    );

    try h.command(
        "lua vim.api.nvim_win_set_config(_G.test_float, {row=5, col=5})",
    );

    // Wait for final position
    const CtxPos = struct { alloc: std.mem.Allocator, grid_id: i64, target_row: i64 };
    try h.waitUntil(CtxPos{ .alloc = alloc, .grid_id = float_grid_id, .target_row = 5 }, struct {
        fn check(c: CtxPos, hh: *Harness) bool {
            if (hh.gridPos(c.grid_id)) |pos| {
                return pos.row == c.target_row and pos.col == c.target_row;
            }
            return false;
        }
    }.check, h.opts.timeout_ms);

    const final_pos = h.gridPos(float_grid_id) orelse return error.FloatGridNotFound;
    try std.testing.expectEqual(@as(i64, 5), final_pos.row);
    try std.testing.expectEqual(@as(i64, 5), final_pos.col);

    // Edit main window while repositioning float
    try h.command("normal! gg");
    try h.command("normal! o");

    try h.input("content");

    // Position update
    try h.command(
        "lua vim.api.nvim_win_set_config(_G.test_float, {row=8, col=8})",
    );

    try h.input(" more");
    try h.input("<Esc>");

    // Verify position
    try h.waitUntil(CtxPos{ .alloc = alloc, .grid_id = float_grid_id, .target_row = 8 }, struct {
        fn check(c: CtxPos, hh: *Harness) bool {
            if (hh.gridPos(c.grid_id)) |pos| {
                return pos.row == c.target_row and pos.col == c.target_row;
            }
            return false;
        }
    }.check, h.opts.timeout_ms);

    const pos_after_edit = h.gridPos(float_grid_id) orelse return error.FloatGridNotFound;
    try std.testing.expectEqual(@as(i64, 8), pos_after_edit.row);
    try std.testing.expectEqual(@as(i64, 8), pos_after_edit.col);

    // Position update during scroll
    try h.command("normal! gg");
    try h.command("normal! j");

    try h.command(
        "lua vim.api.nvim_win_set_config(_G.test_float, {row=3, col=3})",
    );

    try h.command("normal! <C-d>");

    try h.command(
        "lua vim.api.nvim_win_set_config(_G.test_float, {row=10, col=10})",
    );

    // Wait for final position
    try h.waitUntil(CtxPos{ .alloc = alloc, .grid_id = float_grid_id, .target_row = 10 }, struct {
        fn check(c: CtxPos, hh: *Harness) bool {
            if (hh.gridPos(c.grid_id)) |pos| {
                return pos.row == c.target_row and pos.col == c.target_row;
            }
            return false;
        }
    }.check, h.opts.timeout_ms);

    // Close float
    try h.command("lua vim.api.nvim_win_close(_G.test_float, true)");
}
