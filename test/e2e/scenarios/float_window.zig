// float_window — open a float via nvim_open_win, assert grid placement
// and size; close it, assert it is gone.
// Exercises: win_float_pos → win_pos, grid_resize for the float's grid.

const std = @import("std");
const Harness = @import("../harness.zig").Harness;

fn contains(ids: []const i64, id: i64) bool {
    for (ids) |x| {
        if (x == id) return true;
    }
    return false;
}

pub fn run(alloc: std.mem.Allocator) !void {
    var h = try Harness.init(alloc, .{});
    defer h.deinit();

    const before = try h.positionedGridsAlloc(alloc);
    defer alloc.free(before);

    try h.command(
        "lua _G.e2e_win = vim.api.nvim_open_win(vim.api.nvim_create_buf(false, true), false, " ++
            "{relative='editor', row=5, col=10, width=20, height=3})",
    );

    // Wait for a new positioned grid to appear.
    const Ctx = struct { before: []const i64 };
    try h.waitUntil(Ctx{ .before = before }, struct {
        fn check(c: Ctx, hh: *Harness) bool {
            const now = hh.positionedGridsAlloc(hh.alloc) catch return false;
            defer hh.alloc.free(now);
            for (now) |id| {
                if (!contains(c.before, id)) return true;
            }
            return false;
        }
    }.check, h.opts.timeout_ms);

    // Identify the new grid and assert placement + size.
    const after = try h.positionedGridsAlloc(alloc);
    defer alloc.free(after);
    var float_grid: i64 = 0;
    for (after) |id| {
        if (!contains(before, id)) float_grid = id;
    }
    try std.testing.expect(float_grid != 0);

    const pos = h.gridPos(float_grid) orelse return error.FloatNotPositioned;
    try std.testing.expectEqual(@as(u32, 5), pos.row);
    try std.testing.expectEqual(@as(u32, 10), pos.col);

    const size = h.subGridSize(float_grid) orelse return error.GridNotFound;
    try std.testing.expectEqual(@as(u32, 3), size.rows);
    try std.testing.expectEqual(@as(u32, 20), size.cols);

    // Close the float; its win_pos entry must disappear.
    try h.command("lua vim.api.nvim_win_close(_G.e2e_win, true)");
    const Ctx2 = struct { float_grid: i64 };
    try h.waitUntil(Ctx2{ .float_grid = float_grid }, struct {
        fn check(c: Ctx2, hh: *Harness) bool {
            return hh.gridPos(c.float_grid) == null;
        }
    }.check, h.opts.timeout_ms);
}
