// float_fixed_after_move — a float that moved once does not thereby follow
// every later scroll.
//
// macOS reads `follows_scroll` as permission to translate a float's pixels by
// the parent's smooth-scroll offset (ExternalGridView.drawHostedLayers,
// MetalTerminalView.appendFloatScrollOffsets). The flag used to latch on at the
// first vertical reposition and never clear, so a float moved once kept
// pixel-following scrolls it was never part of, then snapped back when the
// gesture settled.
//
// One scroll, two floats, measured against real Neovim. The `relative='win'`
// float is pinned to a window row and is NOT repositioned; the `bufpos` float
// is pinned to a buffer line and IS. settleFloatScrollFollowing reads that
// batch as the measurement it is, and each float gets the answer it earned.

const std = @import("std");
const Harness = @import("../harness.zig").Harness;

const fixed_first_row: u32 = 5;
const fixed_moved_row: u32 = 7;
/// Buffer line the tracking float is pinned to, far enough down that three
/// rows of scrolling cannot push it off the top.
const tracked_bufpos_line: u32 = 20;
const scroll_rows: u32 = 3;

fn contains(ids: []const i64, id: i64) bool {
    for (ids) |x| {
        if (x == id) return true;
    }
    return false;
}

/// The one grid in `now` that is not in `before`.
fn newGrid(before: []const i64, now: []const i64) i64 {
    for (now) |id| {
        if (!contains(before, id)) return id;
    }
    return 0;
}

const PosCtx = struct { grid: i64, row: u32 };

fn waitAtRow(h: *Harness, grid: i64, row: u32) !void {
    try h.waitUntil(PosCtx{ .grid = grid, .row = row }, struct {
        fn check(c: PosCtx, hh: *Harness) bool {
            const pos = hh.gridPos(c.grid) orelse return false;
            return pos.row == c.row;
        }
    }.check, h.opts.timeout_ms);
}

/// Open one float and return its grid id, waiting for its placement.
fn openFloat(h: *Harness, alloc: std.mem.Allocator, lua: []const u8) !i64 {
    const before = try h.positionedGridsAlloc(alloc);
    defer alloc.free(before);

    try h.command(lua);

    const Ctx = struct { before: []const i64 };
    try h.waitUntil(Ctx{ .before = before }, struct {
        fn check(c: Ctx, hh: *Harness) bool {
            const now = hh.positionedGridsAlloc(hh.alloc) catch return false;
            defer hh.alloc.free(now);
            return newGrid(c.before, now) != 0;
        }
    }.check, h.opts.timeout_ms);

    const after = try h.positionedGridsAlloc(alloc);
    defer alloc.free(after);
    const grid = newGrid(before, after);
    try std.testing.expect(grid != 0);
    return grid;
}

pub fn run(alloc: std.mem.Allocator) !void {
    var h = try Harness.init(alloc, .{});
    defer h.deinit();

    try h.command("call setline(1, map(range(1, 300), '\"line \" . v:val'))");
    const main_grid = h.winGrid();
    try h.waitRowText(main_grid, 0, "line 1", h.opts.timeout_ms);

    // relative='win' pins the float to a row of the WINDOW, which is exactly
    // the placement Neovim leaves alone when that window scrolls.
    const fixed_grid = try openFloat(h, alloc, "lua _G.e2e_fixed = vim.api.nvim_open_win(vim.api.nvim_create_buf(false, true), false, " ++
        "{relative='win', win=0, row=5, col=2, width=20, height=3})");
    try waitAtRow(h, fixed_grid, fixed_first_row);
    // A float that has never moved makes no claim.
    try std.testing.expect(!(h.gridPos(fixed_grid) orelse unreachable).follows_scroll);

    // One reposition. This alone used to be enough to set the flag for good.
    try h.command("lua vim.api.nvim_win_set_config(_G.e2e_fixed, {relative='win', win=0, row=7, col=2})");
    try waitAtRow(h, fixed_grid, fixed_moved_row);
    try std.testing.expect((h.gridPos(fixed_grid) orelse unreachable).follows_scroll);

    // bufpos pins the float to a BUFFER line, so Neovim recomputes its screen
    // row on every scroll. This is a float that really does track the buffer.
    const tracked_grid = try openFloat(h, alloc, "lua _G.e2e_tracked = vim.api.nvim_open_win(vim.api.nvim_create_buf(false, true), false, " ++
        "{relative='win', win=0, bufpos={19, 0}, row=1, col=40, width=16, height=2})");
    const tracked_row_before = (h.gridPos(tracked_grid) orelse unreachable).row;
    try std.testing.expect(tracked_row_before >= tracked_bufpos_line);

    // Scroll the parent and let the screen settle.
    const top_before = h.getViewportTop(main_grid);
    try h.input("3\x05"); // 3<C-e>
    const TopCtx = struct { grid: i64, was: u32 };
    try h.waitUntil(TopCtx{ .grid = main_grid, .was = top_before }, struct {
        fn check(c: TopCtx, hh: *Harness) bool {
            return hh.getViewportTop(c.grid) != c.was;
        }
    }.check, h.opts.timeout_ms);
    try h.waitRowText(main_grid, 0, "line 4", h.opts.timeout_ms);
    try waitAtRow(h, tracked_grid, tracked_row_before - scroll_rows);
    try std.testing.expectEqual(@as(u32, scroll_rows), h.getViewportTop(main_grid) - top_before);

    // The measurement. One batch, one scroll, two floats: Neovim moved the
    // tracking one with the buffer and left the fixed one alone.
    const fixed_pos = h.gridPos(fixed_grid) orelse unreachable;
    try std.testing.expectEqual(@as(u32, fixed_moved_row), fixed_pos.row);
    try std.testing.expect(!fixed_pos.follows_scroll);

    // And the control: clearing the claim is not the same as clearing it for
    // everyone. A float that earned it keeps it.
    try std.testing.expect((h.gridPos(tracked_grid) orelse unreachable).follows_scroll);
}
