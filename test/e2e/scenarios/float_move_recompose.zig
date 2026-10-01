// float_move_recompose — a position-only float move (win_float_pos with NO
// content change) must reach the frontend as a new placement in the main
// surface's layout, which is what it repaints the rows the float left and
// entered from. Once the float stayed rendered at the stale row until an
// unrelated content change forced a rebuild (visible as float lag during
// scrolling).

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

    // enter=false: keep the cursor (and all content) untouched.
    try h.command(
        "lua _G.e2e_win = vim.api.nvim_open_win(vim.api.nvim_create_buf(false, true), false, " ++
            "{relative='editor', row=5, col=10, width=20, height=3})",
    );

    // Find the float's grid and wait for its initial placement.
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

    const after = try h.positionedGridsAlloc(alloc);
    defer alloc.free(after);
    var float_grid: i64 = 0;
    for (after) |id| {
        if (!contains(before, id)) float_grid = id;
    }
    try std.testing.expect(float_grid != 0);

    const PosCtx = struct { grid: i64, row: u32 };
    try h.waitUntil(PosCtx{ .grid = float_grid, .row = 5 }, struct {
        fn check(c: PosCtx, hh: *Harness) bool {
            const pos = hh.gridPos(c.grid) orelse return false;
            return pos.row == c.row;
        }
    }.check, h.opts.timeout_ms);

    // The placement the main surface was told before the move.
    const GridCtx = struct { grid: i64 };
    try h.waitUntil(GridCtx{ .grid = float_grid }, struct {
        fn check(c: GridCtx, hh: *Harness) bool {
            return hh.layoutPlacement(1, c.grid) != null;
        }
    }.check, h.opts.timeout_ms);
    const y_at_row5 = h.layoutPlacement(1, float_grid).?.y_px;

    // Move the float WITHOUT touching any content.
    try h.command("lua vim.api.nvim_win_set_config(_G.e2e_win, {relative='editor', row=8, col=10})");

    try h.waitUntil(PosCtx{ .grid = float_grid, .row = 8 }, struct {
        fn check(c: PosCtx, hh: *Harness) bool {
            const pos = hh.gridPos(c.grid) orelse return false;
            return pos.row == c.row;
        }
    }.check, h.opts.timeout_ms);

    // The fix under test: the position-only move reaches the frontend as the
    // float's new place in the layout, rows 5 -> 8 in the main surface's
    // pixels.
    const MovedCtx = struct { grid: i64, was: i32 };
    h.waitUntil(MovedCtx{ .grid = float_grid, .was = y_at_row5 }, struct {
        fn check(c: MovedCtx, hh: *Harness) bool {
            const p = hh.layoutPlacement(1, c.grid) orelse return false;
            return p.y_px != c.was;
        }
    }.check, h.opts.timeout_ms) catch {
        std.debug.print("[e2e] float moved (row 5 -> 8) but the main layout still places it at y={d}\n", .{y_at_row5});
        return error.FloatMoveNotRecomposed;
    };
    const y_at_row8 = h.layoutPlacement(1, float_grid).?.y_px;
    try std.testing.expectEqual(y_at_row5 * 8, y_at_row8 * 5);
}
