// scrollbind_layers_fast_path — three scroll-bound window grids plus an
// overlapping float all take the core's row-shift fast path when one <C-d>
// scrolls the whole group.
//
// Under per-grid rendering every window owns its own rows, so a shift in one
// grid cannot disturb a neighbour. That is what makes a vertical split, the
// content UNDER a float, and the float itself eligible at the same time
// (flush.zig gridScrollFastPathRegion). This scenario locks that in against a
// real nvim: it asserts on_grid_row_scroll for all four window grids from one
// gesture, all reporting the same shift.
//
// Eligibility is tight on purpose, so the numbers here are chosen not
// arbitrary: the fast path refuses a shift larger than half the region, and
// the float is only 8 rows tall, so 'scroll' is pinned to 3 (3 <= 8/2) rather
// than left at nvim's half-window default (11 for a 22-row split), which the
// float would refuse.
//
// on_vertices_row is deliberately absent from this harness and is not needed
// here: the core's dispatch loop is gated on on_grid_row_scroll alone and runs
// before vertex generation.

const std = @import("std");
const Harness = @import("../harness.zig").Harness;

const rows_delta_expected: i32 = 3;

/// A positioned grid that win_viewport has named a Neovim window. The filter
/// matters: win_pos also carries nvim's message grid (grid 3, one row below
/// the last window), which is not a window and never reports a viewport.
const WinGrid = struct { grid_id: i64, win: i64 };

fn windowGridsAlloc(h: *Harness, alloc: std.mem.Allocator) ![]WinGrid {
    const ids = try h.positionedGridsAlloc(alloc);
    defer alloc.free(ids);
    var out: std.ArrayListUnmanaged(WinGrid) = .empty;
    errdefer out.deinit(alloc);
    for (ids) |id| {
        const win = h.viewportWin(id);
        if (win == 0) continue;
        try out.append(alloc, .{ .grid_id = id, .win = win });
    }
    return out.toOwnedSlice(alloc);
}

fn windowGridCount(h: *Harness) usize {
    const wgs = windowGridsAlloc(h, h.alloc) catch return 0;
    defer h.alloc.free(wgs);
    return wgs.len;
}

fn containsGrid(wgs: []const WinGrid, grid_id: i64) bool {
    for (wgs) |w| {
        if (w.grid_id == grid_id) return true;
    }
    return false;
}

pub fn run(alloc: std.mem.Allocator) !void {
    var h = try Harness.init(alloc, .{});
    defer h.deinit();

    // 300 distinct lines, so a scrolled row can never coincidentally match the
    // row that used to be there.
    try h.command("call setline(1, map(range(1, 300), '\"line \" . v:val'))");
    const first_grid = h.winGrid();
    try h.waitRowText(first_grid, 0, "line 1", h.opts.timeout_ms);

    // Two vertical splits -> three side-by-side window grids.
    try h.command("vsplit");
    try h.command("vsplit");
    const CountCtx = struct { want: usize };
    try h.waitUntil(CountCtx{ .want = 3 }, struct {
        fn check(c: CountCtx, hh: *Harness) bool {
            return windowGridCount(hh) == c.want;
        }
    }.check, h.opts.timeout_ms);

    const splits = try windowGridsAlloc(h, alloc);
    defer alloc.free(splits);
    try std.testing.expectEqual(@as(usize, 3), splits.len);

    // Float over the MIDDLE split: 80 cols / 3 windows puts the middle one at
    // cols 27..52, so cols 25..54 covers it and laps onto both neighbours.
    try h.command(
        "lua _G.e2e_float = vim.api.nvim_open_win(0, false, " ++
            "{relative='editor', row=3, col=25, width=30, height=8, style='minimal'})",
    );
    try h.waitUntil(CountCtx{ .want = 4 }, struct {
        fn check(c: CountCtx, hh: *Harness) bool {
            return windowGridCount(hh) == c.want;
        }
    }.check, h.opts.timeout_ms);

    const all_wins = try windowGridsAlloc(h, alloc);
    defer alloc.free(all_wins);
    try std.testing.expectEqual(@as(usize, 4), all_wins.len);
    var float_grid: i64 = 0;
    for (all_wins) |w| {
        if (!containsGrid(splits, w.grid_id)) float_grid = w.grid_id;
    }
    try std.testing.expect(float_grid != 0);
    const float_size = h.subGridSize(float_grid) orelse return error.GridNotFound;
    try std.testing.expectEqual(@as(u32, 8), float_size.rows);

    // scrollbind on every window INCLUDING the float, set per window handle:
    // `:windo` would skip the float.
    for (all_wins) |w| {
        var buf: [128]u8 = undefined;
        const cmd = try std.fmt.bufPrint(
            &buf,
            "lua vim.api.nvim_set_option_value('scrollbind', true, {{win={d}}})",
            .{w.win},
        );
        try h.command(cmd);
    }
    try h.command("syncbind");

    // <C-d> scrolls by 'scroll' lines; pin it so the shift stays inside the
    // float's half-region ceiling (see the header note).
    try h.command("setlocal scroll=3");

    // nvim_input does not queue behind nvim_command: without a round trip the
    // <C-d> below can be processed while 'scroll' is still the 11-line default,
    // which the 8-row float refuses. Moving the cursor is an ordered command
    // whose effect the harness can see, so observing it proves every command
    // above has run.
    try h.command("normal! 2G");
    try h.waitCursor(1, 0, h.opts.timeout_ms);

    const focus_grid = h.winGrid();
    try std.testing.expect(containsGrid(splits, focus_grid));
    const before_top = h.getViewportTopAndDelta(focus_grid).top;

    h.resetRowScrolls();
    try h.input("<C-d>");

    // Scrollbind's sync timing is nvim's business: the bound grids may land in
    // a later batch than the focused one, so wait for the CONDITION, not for a
    // single flush.
    const Ctx = struct { wins: []const WinGrid };
    h.waitUntil(Ctx{ .wins = all_wins }, struct {
        fn check(c: Ctx, hh: *Harness) bool {
            for (c.wins) |w| {
                if (hh.rowScrollCalls(w.grid_id) == 0) return false;
                if (hh.rowScrollDelta(w.grid_id) != rows_delta_expected) return false;
            }
            return true;
        }
    }.check, h.opts.timeout_ms) catch |e| {
        for (all_wins) |w| {
            std.debug.print(
                "[e2e] scrollbind_layers_fast_path: grid={d} row_scroll_calls={d} rows_delta={d}\n",
                .{ w.grid_id, h.rowScrollCalls(w.grid_id), h.rowScrollDelta(w.grid_id) },
            );
        }
        std.debug.print("[e2e] underlying wait error: {any}\n", .{e});
        return error.RowShiftFastPathNotTaken;
    };

    // The wait accepts whatever the constant says; state the shape of that
    // shift separately so a future edit cannot quietly make it zero or one row.
    try std.testing.expect(@abs(rows_delta_expected) > 1);

    // Grid 1 never scrolls itself under ext_multigrid, and the core refuses
    // grid_id < 2 outright (flush.zig dispatchGridRowScroll).
    try std.testing.expectEqual(@as(u32, 0), h.rowScrollCalls(1));

    // A no-op cannot pass: the content really moved three lines, in the focused
    // split and inside the float bound to it.
    try h.waitRowText(focus_grid, 0, "line 4", h.opts.timeout_ms);
    try h.waitRowText(float_grid, 0, "line 4", h.opts.timeout_ms);
    const after_vp = h.getViewportTopAndDelta(focus_grid);
    try std.testing.expect(after_vp.top > before_top);
}
