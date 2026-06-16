// external_window_cursor — open an external window (separate OS window
// grid) with enter=true, assert the cursor moves into its grid; close it,
// assert the cursor returns and the external grid is gone.
// Exercises: win_external_pos → external_grids (via ext_multigrid; the
// ext_windows attach option is NOT needed and stock nvim rejects it),
// on_external_window / on_external_window_close frontend callbacks.

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

    const home = h.cursor();
    const before = try h.externalGridsAlloc(alloc);
    defer alloc.free(before);

    // enter=true: the cursor must follow into the external window.
    try h.command(
        "lua _G.e2e_win = vim.api.nvim_open_win(vim.api.nvim_create_buf(false, true), true, " ++
            "{external=true, width=30, height=10})",
    );

    // Wait until a new external grid is tracked AND the cursor lives in it.
    const Ctx = struct { before: []const i64, home_grid: i64 };
    try h.waitUntil(Ctx{ .before = before, .home_grid = home.grid_id }, struct {
        fn check(c: Ctx, hh: *Harness) bool {
            const cur = hh.cursor();
            if (cur.grid_id == c.home_grid) return false;
            return hh.isExternalGrid(cur.grid_id);
        }
    }.check, h.opts.timeout_ms);

    const ext_grid = h.cursor().grid_id;
    try std.testing.expect(!contains(before, ext_grid));

    // Frontend contract: on_external_window fired for this grid.
    try std.testing.expect(h.ext_win_shows.load(.seq_cst) > 0);
    try std.testing.expectEqual(ext_grid, h.last_ext_win_grid.load(.seq_cst));

    // Type into the external window: content lands in its grid.
    try h.input("iext<Esc>");
    try h.waitRowText(ext_grid, 0, "ext", h.opts.timeout_ms);

    // Close it: cursor returns to the original grid, external grid is gone,
    // and the close callback fired.
    try h.command("lua vim.api.nvim_win_close(_G.e2e_win, true)");
    const Ctx2 = struct { home_grid: i64, ext_grid: i64 };
    try h.waitUntil(Ctx2{ .home_grid = home.grid_id, .ext_grid = ext_grid }, struct {
        fn check(c: Ctx2, hh: *Harness) bool {
            return hh.cursor().grid_id == c.home_grid and
                !hh.isExternalGrid(c.ext_grid);
        }
    }.check, h.opts.timeout_ms);
    try std.testing.expect(h.ext_win_closes.load(.seq_cst) > 0);
}
