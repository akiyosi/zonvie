// float_move_recompose — regression test for cff54bb: a position-only
// float move (win_float_pos with NO content change) must bump content_rev
// so the next flush recomposes the overlay at its new position. Before the
// fix the float stayed rendered at the stale row until an unrelated
// content change forced a rebuild (visible as float lag during scrolling).

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

    // Snapshot the revision once the screen has settled, then move the
    // float WITHOUT touching any content.
    const rev_before_move = h.contentRev();
    try h.command("lua vim.api.nvim_win_set_config(_G.e2e_win, {relative='editor', row=8, col=10})");

    try h.waitUntil(PosCtx{ .grid = float_grid, .row = 8 }, struct {
        fn check(c: PosCtx, hh: *Harness) bool {
            const pos = hh.gridPos(c.grid) orelse return false;
            return pos.row == c.row;
        }
    }.check, h.opts.timeout_ms);

    // The fix under test: the position-only move must have bumped
    // content_rev so the overlay recomposes at the new row.
    const rev_after_move = h.contentRev();
    if (rev_after_move == rev_before_move) {
        std.debug.print(
            "[e2e] float moved (row 5 -> 8) but content_rev stayed at {d} — overlay will not recompose\n",
            .{rev_before_move},
        );
        return error.FloatMoveNotRecomposed;
    }
}
