// float_position_update_race — rapid float repositioning settles at the final
// position without losing the grid or leaving it at a stale spot.
// Note: general frontend robustness test; not derived from a specific
// upstream issue. (A prior header cited Goneovim #603, which is actually
// "Goneovim crash when using LazyVim" — unrelated.)

const std = @import("std");
const Harness = @import("../harness.zig").Harness;

fn contains(ids: []const i64, id: i64) bool {
    for (ids) |x| if (x == id) return true;
    return false;
}

pub fn run(alloc: std.mem.Allocator) !void {
    var h = try Harness.init(alloc, .{});
    defer h.deinit();

    const before = try h.positionedGridsAlloc(alloc);
    defer alloc.free(before);

    // Open a float.
    try h.command(
        "lua _G.test_float = vim.api.nvim_open_win(vim.api.nvim_create_buf(false, true), false, " ++
            "{relative='editor', row=2, col=2, width=10, height=4})",
    );

    // Identify the float's grid.
    const Ctx = struct { before: []const i64 };
    try h.waitUntil(Ctx{ .before = before }, struct {
        fn check(c: Ctx, hh: *Harness) bool {
            const now = hh.positionedGridsAlloc(hh.alloc) catch return false;
            defer hh.alloc.free(now);
            for (now) |id| if (!contains(c.before, id)) return true;
            return false;
        }
    }.check, h.opts.timeout_ms);

    const after = try h.positionedGridsAlloc(alloc);
    defer alloc.free(after);
    var float_grid: i64 = 0;
    for (after) |id| if (!contains(before, id)) {
        float_grid = id;
    };
    try std.testing.expect(float_grid != 0);

    // Fire several repositions back to back (each must carry `relative`, which
    // nvim_win_set_config requires to move a float). The final win_float_pos
    // must win: the grid settles at (5,5), not a stale intermediate.
    try h.command("lua vim.api.nvim_win_set_config(_G.test_float, {relative='editor', row=3, col=3})");
    try h.command("lua vim.api.nvim_win_set_config(_G.test_float, {relative='editor', row=4, col=4})");
    try h.command("lua vim.api.nvim_win_set_config(_G.test_float, {relative='editor', row=5, col=5})");

    const Pos = struct { g: i64, r: u32, c: u32 };
    try h.waitUntil(Pos{ .g = float_grid, .r = 5, .c = 5 }, struct {
        fn check(p: Pos, hh: *Harness) bool {
            const gp = hh.gridPos(p.g) orelse return false;
            return gp.row == p.r and gp.col == p.c;
        }
    }.check, h.opts.timeout_ms);

    // Reposition once more while the main buffer is edited; the float tracks
    // the new position and the grid is still present.
    try h.input("ggomain text<Esc>");
    try h.command("lua vim.api.nvim_win_set_config(_G.test_float, {relative='editor', row=8, col=8})");
    try h.waitUntil(Pos{ .g = float_grid, .r = 8, .c = 8 }, struct {
        fn check(p: Pos, hh: *Harness) bool {
            const gp = hh.gridPos(p.g) orelse return false;
            return gp.row == p.r and gp.col == p.c;
        }
    }.check, h.opts.timeout_ms);

    // Close the float; its positioned-grid entry must disappear.
    try h.command("lua vim.api.nvim_win_close(_G.test_float, true)");
    try h.waitUntil(Pos{ .g = float_grid, .r = 0, .c = 0 }, struct {
        fn check(p: Pos, hh: *Harness) bool {
            return hh.gridPos(p.g) == null;
        }
    }.check, h.opts.timeout_ms);
}
