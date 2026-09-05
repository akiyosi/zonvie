// ext_anchor_scroll_under_float — when an external anchor grid scrolls under
// a float composited into its rows, the core publishes the shift AND resends
// the rows the float covers. PASSES: the guard 935bdc0 removed is not needed
// here, and this pins the property that makes its removal survivable.
//
// Per-grid rendering made every window grid its own layer, which is why
// 935bdc0 could drop the float-overlap exclusion from the row-shift fast path
// (`externalFloatAnchorEntries` in dispatchGridRowScroll, plus a
// generation-side twin `ext_has_float_overlay`). For a float on the MAIN
// surface that reasoning is airtight: the float is a layer of its own, so
// shifting the grid under it cannot move its pixels.
//
// A float anchored to an EXTERNAL grid is the case the rationale does not
// reach. `collectMainLayerEntries` (flush.zig) skips it precisely because its
// anchor is external, and `buildExternalFloatRowIndexWithLimits` composites it
// into the anchor's OWN rows instead — the rows on_grid_row_scroll asks the
// frontend to shift. What keeps that safe is not a guard but Neovim: it
// re-announces the float in the same batch as the scroll, and setWinFloatPos
// dirties the covered anchor rows through dirtyCompositedRow, so the shifted
// float pixels are painted over.
//
// The gate below on `start_row >= 0` is load-bearing. An external grid that
// was never composited keeps start_row == -1 (grid.zig setWinExternalPos), and
// BOTH compositing paths return early on that — dirtyCompositedRow
// (grid.zig:2275) and buildExternalFloatRowIndexWithLimits (flush.zig:4861).
// In that configuration the float has no pixels in the anchor's rows at all,
// nothing is resent because there is nothing to resend, and this scenario
// would assert against a screen it is not describing. Measured: reaching the
// external window with `nvim_open_win{external=true}` yields start_row == -1,
// while settling an ordinary split first and detaching it with
// `nvim_win_set_config{external=true}` yields start_row == 0.

const std = @import("std");
const Harness = @import("../harness.zig").Harness;

/// 'scroll' is pinned so each shift is one the fast path accepts (it refuses a
/// delta past half the region) and small enough that the vacated band cannot
/// reach the float's rows on its own.
const rows_delta_expected: i32 = 3;

const ext_rows: u32 = 20;
const ext_cols: u32 = 40;
/// Anchor-local placement of the float. Kept clear of both the top and the
/// vacated band so neither can account for its rows being dirty.
const float_row: u32 = 10;
const float_rows: u32 = 6;

fn contains(ids: []const i64, id: i64) bool {
    for (ids) |x| {
        if (x == id) return true;
    }
    return false;
}

fn dirtyMapAlloc(h: *Harness, alloc: std.mem.Allocator, grid_id: i64, rows: u32) ![]u8 {
    const out = try alloc.alloc(u8, rows);
    for (out, 0..) |*c, i| c.* = if (h.isRowDirty(grid_id, @intCast(i))) '1' else '.';
    return out;
}

pub fn run(alloc: std.mem.Allocator) !void {
    var h = try Harness.init(alloc, .{});
    defer h.deinit();

    // 300 distinct lines, so a shifted row can never coincidentally match the
    // row that used to be there.
    try h.command("call setline(1, map(range(1, 300), '\"line \" . v:val'))");
    const main_grid = h.winGrid();
    try h.waitRowText(main_grid, 0, "line 1", h.opts.timeout_ms);

    // An ordinary split FIRST, so win_pos holds an entry for this grid when
    // setWinExternalPos reads it; that entry is where start_row comes from.
    // Detaching a window that was never composited would leave start_row at
    // -1 and silently disable the compositing this scenario is about.
    try h.command("lua _G.e2e_ext = vim.api.nvim_open_win(0, true, {split='right', width=40})");
    const CtxSplit = struct { home: i64 };
    try h.waitUntil(CtxSplit{ .home = main_grid }, struct {
        fn check(c: CtxSplit, hh: *Harness) bool {
            const g = hh.cursor().grid_id;
            return g != c.home and g != 1 and hh.gridPos(g) != null;
        }
    }.check, h.opts.timeout_ms);

    try h.command("lua vim.api.nvim_win_set_config(_G.e2e_ext, {external=true, width=40, height=20})");
    const CtxExt = struct { home: i64 };
    try h.waitUntil(CtxExt{ .home = main_grid }, struct {
        fn check(c: CtxExt, hh: *Harness) bool {
            const cur = hh.cursor();
            if (cur.grid_id == c.home) return false;
            return hh.isExternalGrid(cur.grid_id);
        }
    }.check, h.opts.timeout_ms);

    const ext_grid = h.cursor().grid_id;
    const ext_size = h.subGridSize(ext_grid) orelse return error.GridNotFound;
    try std.testing.expectEqual(ext_rows, ext_size.rows);
    try std.testing.expectEqual(ext_cols, ext_size.cols);

    // The frontend cannot remap retained row slots until the external window's
    // open callback has seeded a surface, and dispatchGridRowScroll refuses a
    // grid absent from known_external_grids. Seeing the callback proves the
    // seed happened, so a later silence would be a decision and not a gap.
    try std.testing.expect(h.ext_win_shows.load(.seq_cst) > 0);

    const before_pos = try h.positionedGridsAlloc(alloc);
    defer alloc.free(before_pos);

    // A float anchored to the external window, on its own scratch buffer so
    // nothing it holds changes while the anchor scrolls.
    try h.command(
        "lua _G.e2e_float = vim.api.nvim_open_win(vim.api.nvim_create_buf(false, true), false, " ++
            "{relative='win', win=_G.e2e_ext, row=10, col=2, width=20, height=6, style='minimal'})",
    );

    const Ctx2 = struct { before: []const i64, ext: i64 };
    try h.waitUntil(Ctx2{ .before = before_pos, .ext = ext_grid }, struct {
        fn check(c: Ctx2, hh: *Harness) bool {
            const now = hh.positionedGridsAlloc(hh.alloc) catch return false;
            defer hh.alloc.free(now);
            for (now) |id| {
                if (contains(c.before, id)) continue;
                const p = hh.gridPos(id) orelse continue;
                if (p.anchor_grid == c.ext) return true;
            }
            return false;
        }
    }.check, h.opts.timeout_ms);

    const after_pos = try h.positionedGridsAlloc(alloc);
    defer alloc.free(after_pos);
    var float_grid: i64 = 0;
    for (after_pos) |id| {
        if (contains(before_pos, id)) continue;
        const p = h.gridPos(id) orelse continue;
        if (p.anchor_grid == ext_grid) float_grid = id;
    }
    try std.testing.expect(float_grid != 0);

    // Compositing is LIVE. Without this gate the scenario passes just as
    // happily on an anchor whose start_row is -1, where the float is drawn
    // into the anchor's rows by nobody and "the covered rows came back" would
    // mean nothing. See the header.
    const start_row = h.externalGridStartRow(ext_grid);
    if (start_row < 0) {
        std.debug.print(
            "[e2e] ext_anchor_scroll_under_float: anchor grid {d} has start_row={d}; " ++
                "the float is not composited into its rows and this scenario would prove nothing\n",
            .{ ext_grid, start_row },
        );
        return error.ExternalAnchorNotCompositing;
    }

    // The two properties that put this float in the anchor's own rows rather
    // than on a surface of its own: its anchor is external (what
    // collectMainLayerEntries skips on) and it is not itself external.
    const float_pos = h.gridPos(float_grid) orelse return error.FloatNotPositioned;
    try std.testing.expect(h.isExternalGrid(float_pos.anchor_grid));
    try std.testing.expect(!h.isExternalGrid(float_grid));
    const float_size = h.subGridSize(float_grid) orelse return error.GridNotFound;
    try std.testing.expectEqual(float_rows, float_size.rows);

    // Anchor-local band, the way the ext composite computes it
    // (`float_pos.row - start_row`, flush.zig ext overlay).
    const band_start: u32 = @intCast(@as(i64, float_pos.row) - @as(i64, start_row));
    try std.testing.expectEqual(float_row, band_start);
    const band_end = band_start + float_size.rows;
    try std.testing.expect(band_end <= ext_size.rows - @as(u32, @intCast(rows_delta_expected)));

    // <C-d> scrolls by 'scroll' lines; pin it so the shift is one the fast
    // path accepts. nvim_input does not queue behind nvim_command, so move the
    // cursor with an ordered command and wait for its effect: seeing it proves
    // every command above has run.
    try h.command("setlocal scroll=3");
    try h.command("normal! 2G");
    try h.waitCursor(1, 0, h.opts.timeout_ms);
    try std.testing.expectEqual(ext_grid, h.cursor().grid_id);

    h.resetRowScrolls();

    // Two shifts, i.e. steady-state scrolling rather than the first frame of a
    // gesture, with the dirty set cleared before each so what is read back is
    // one frame's worth — the way a real flush starts from a set its own
    // clearDirty() emptied. On the very FIRST shift after a clear the float's
    // dirty marks are the ones Neovim set BEFORE the grid_scroll, which
    // GridBuf.scroll then shifts along with the content, so they land
    // `rows_delta` above the float and the band's bottom rows are missed. From
    // the second shift on, the marks Neovim sets after the scroll cover it.
    h.clearDirtyRows(ext_grid);
    try h.input("<C-d>");
    try h.waitRowText(ext_grid, 0, "line 4", h.opts.timeout_ms);

    h.clearDirtyRows(ext_grid);
    try h.input("<C-d>");
    try h.waitRowText(ext_grid, 0, "line 7", h.opts.timeout_ms);

    // The waits above already proved the anchor's content moved, so a silent
    // callback could not be mistaken for a scroll that never happened. The
    // float meanwhile did not scroll: its own grid was never republished, so
    // any movement of its pixels comes from the anchor's shift alone.
    try std.testing.expectEqual(@as(u32, 0), h.rowScrollCalls(float_grid));

    // The core DOES publish the shift for an external anchor carrying a
    // composited float — 935bdc0's guard is gone and stays gone.
    if (h.rowScrollCalls(ext_grid) == 0) {
        std.debug.print(
            "[e2e] ext_anchor_scroll_under_float: no on_grid_row_scroll for external anchor " ++
                "grid {d}; something refuses the fast path again, so the resend property below " ++
                "no longer describes what the frontend does\n",
            .{ext_grid},
        );
        return error.ExternalAnchorRowScrollNotPublished;
    }
    try std.testing.expectEqual(rows_delta_expected, h.rowScrollDelta(ext_grid));

    // What makes that publish safe: every row the float covers is dirty, so
    // the frontend repaints the float pixels its shift dragged.
    var row: u32 = band_start;
    while (row < band_end) : (row += 1) {
        if (h.isRowDirty(ext_grid, row)) continue;
        const map = try dirtyMapAlloc(h, alloc, ext_grid, ext_size.rows);
        defer alloc.free(map);
        std.debug.print(
            "[e2e] ext_anchor_scroll_under_float: anchor grid {d} shifted {d} rows with float " ++
                "grid {d} composited at rows {d}..{d}, but row {d} was not resent. The frontend " ++
                "drags the float's pixels with the text and nothing repaints them. dirty={s}\n",
            .{ ext_grid, h.rowScrollDelta(ext_grid), float_grid, band_start, band_end, row, map },
        );
        return error.CoveredFloatRowNotResent;
    }

    // Stuck-true tripwire: a readback that reported every row dirty — or a
    // dirty_all the scroll left set — would satisfy the loop above without
    // proving anything. The row just below the float's band is regenerated by
    // neither the composite nor the vacated band, so it must be clean.
    try std.testing.expect(!h.isRowDirty(ext_grid, band_end));
}
