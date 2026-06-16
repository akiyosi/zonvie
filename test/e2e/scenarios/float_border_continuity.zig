// float_border_continuity — verify a float's grid position is tracked correctly
// across main-window edits, a reposition, and a split, and is removed on close.
// Border PIXEL continuity (Neovide #2848 / Goneovim #619) is a rendering
// concern verified in the GUI visual test `visual_float_border_continuity`;
// the headless harness has no pixels, so this covers the logical-state half
// (win_float_pos tracking). A border is intentionally NOT used here — it only
// offsets the content grid and adds nothing the logical harness can check.

const std = @import("std");
const Harness = @import("../harness.zig").Harness;

fn contains(ids: []const i64, id: i64) bool {
    for (ids) |x| if (x == id) return true;
    return false;
}

pub fn run(alloc: std.mem.Allocator) !void {
    var h = try Harness.init(alloc, .{});
    defer h.deinit();

    // Snapshot positioned grids before opening the float so we can identify it
    // by diff. Picking grids[len-1] is unreliable — the main window grid is
    // also positioned and HashMap iteration order is not stable.
    const before = try h.positionedGridsAlloc(alloc);
    defer alloc.free(before);

    try h.command(
        "lua _G.test_float = vim.api.nvim_open_win(vim.api.nvim_create_buf(false, true), false, {" ++
            "relative='editor', row=3, col=4, width=20, height=8" ++
            "})",
    );

    // Wait for the new positioned grid and identify it.
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

    // Float placed at (3,4) with a known size.
    const size = h.subGridSize(float_grid) orelse return error.FloatGridNotFound;
    try std.testing.expect(size.rows > 0 and size.cols > 0);
    const initial_pos = h.gridPos(float_grid) orelse return error.FloatGridNotFound;
    try std.testing.expectEqual(@as(u32, 3), initial_pos.row);
    try std.testing.expectEqual(@as(u32, 4), initial_pos.col);

    // Editing the main window must not move the float.
    try h.input("ggomain text<Esc>");
    const pos_after_edit = h.gridPos(float_grid) orelse return error.FloatGridNotFound;
    try std.testing.expectEqual(initial_pos.row, pos_after_edit.row);
    try std.testing.expectEqual(initial_pos.col, pos_after_edit.col);

    // Reposition the float (nvim_win_set_config requires `relative`).
    try h.command("lua vim.api.nvim_win_set_config(_G.test_float, {relative='editor', row=5, col=10})");
    const Pos = struct { g: i64, r: u32, c: u32 };
    try h.waitUntil(Pos{ .g = float_grid, .r = 5, .c = 10 }, struct {
        fn check(p: Pos, hh: *Harness) bool {
            const gp = hh.gridPos(p.g) orelse return false;
            return gp.row == p.r and gp.col == p.c;
        }
    }.check, h.opts.timeout_ms);

    // A split must not drop the float.
    try h.command("vsplit");
    try std.testing.expect(h.gridPos(float_grid) != null);
    try std.testing.expect(h.subGridSize(float_grid) != null);

    // Close the float; its positioned-grid entry must disappear.
    try h.command("lua vim.api.nvim_win_close(_G.test_float, true)");
    try h.waitUntil(Pos{ .g = float_grid, .r = 0, .c = 0 }, struct {
        fn check(p: Pos, hh: *Harness) bool {
            return hh.gridPos(p.g) == null;
        }
    }.check, h.opts.timeout_ms);
}
