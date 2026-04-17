// Scroll-aware flush correctness tests.
// Tests pending_scroll tracking, touched row recording, eligibility checking,
// and scroll cache invalidation/fallback.

const std = @import("std");
const zonvie_core = @import("zonvie_core");
const grid_mod = zonvie_core.grid_mod;
const flush_mod = zonvie_core.flush_mod;
const Grid = grid_mod.Grid;

// ============================================================================
// Helper: create a Grid with a single sub_grid that mimics the typical
// multigrid layout (grid_id=2, win_pos row=0 col=0).
// ============================================================================

fn setupGridWithSubgrid(alloc: std.mem.Allocator, main_rows: u32, main_cols: u32, sg_rows: u32, sg_cols: u32) !Grid {
    var g = Grid.init(alloc);
    try g.resize(main_rows, main_cols);
    try g.resizeGrid(2, sg_rows, sg_cols);
    try g.setWinPos(2, 0, 0, 0);
    return g;
}

// ============================================================================
// A. pending_scroll + touched_rows tracking
// ============================================================================

test "scrollGrid sets pending_scroll with correct fields" {
    const alloc = std.testing.allocator;
    var g = try setupGridWithSubgrid(alloc, 42, 80, 42, 80);
    defer g.deinit();

    g.scrollGrid(2, 1, 42, 0, 80, 1, 0);

    const ps = g.pending_scroll orelse return error.TestUnexpectedNull;
    try std.testing.expectEqual(@as(i64, 2), ps.grid_id);
    try std.testing.expectEqual(@as(u32, 1), ps.top);
    try std.testing.expectEqual(@as(u32, 42), ps.bot);
    try std.testing.expectEqual(@as(u32, 0), ps.left);
    try std.testing.expectEqual(@as(u32, 80), ps.right);
    try std.testing.expectEqual(@as(i32, 1), ps.rows);
    try std.testing.expectEqual(@as(i32, 0), ps.cols);
    try std.testing.expectEqual(@as(u32, 42), ps.target_rows);
    try std.testing.expectEqual(@as(u32, 80), ps.target_cols);
    try std.testing.expectEqual(@as(u32, 0), ps.win_pos_row);
    try std.testing.expectEqual(@as(u8, 0), g.scroll_touched_count);
}

test "putCellGrid records touched row after scroll (1 row)" {
    const alloc = std.testing.allocator;
    var g = try setupGridWithSubgrid(alloc, 42, 80, 42, 80);
    defer g.deinit();

    g.scrollGrid(2, 1, 42, 0, 80, 1, 0);
    // Simulate grid_line for the new bottom row (subgrid row 41 → main row 41)
    g.putCellGrid(2, 41, 0, 'A', 0);

    try std.testing.expectEqual(@as(u8, 1), g.scroll_touched_count);
    try std.testing.expectEqual(@as(u32, 41), g.scroll_touched_rows[0]);
    // pending_scroll should still be set
    try std.testing.expect(g.pending_scroll != null);
}

test "putCellGrid records multiple touched rows (2-3 rows)" {
    const alloc = std.testing.allocator;
    var g = try setupGridWithSubgrid(alloc, 42, 80, 42, 80);
    defer g.deinit();

    g.scrollGrid(2, 1, 42, 0, 80, 1, 0);
    g.putCellGrid(2, 41, 0, 'A', 0); // new bottom row
    g.putCellGrid(2, 41, 1, 'B', 0); // same row, no duplicate
    g.putCellGrid(2, 10, 0, 'C', 1); // different row (cursor line update)

    try std.testing.expectEqual(@as(u8, 2), g.scroll_touched_count);
    try std.testing.expectEqual(@as(u32, 41), g.scroll_touched_rows[0]);
    try std.testing.expectEqual(@as(u32, 10), g.scroll_touched_rows[1]);
}

test "putCellGrid with 3 distinct touched rows" {
    const alloc = std.testing.allocator;
    var g = try setupGridWithSubgrid(alloc, 42, 80, 42, 80);
    defer g.deinit();

    g.scrollGrid(2, 1, 42, 0, 80, 1, 0);
    g.putCellGrid(2, 41, 0, 'A', 0);
    g.putCellGrid(2, 10, 0, 'B', 1);
    g.putCellGrid(2, 0, 0, 'C', 2); // tabline row

    try std.testing.expectEqual(@as(u8, 3), g.scroll_touched_count);
}

test "touched row overflow blocks fast path but preserves pending_scroll" {
    const alloc = std.testing.allocator;
    var g = try setupGridWithSubgrid(alloc, 42, 80, 42, 80);
    defer g.deinit();

    g.scrollGrid(2, 1, 42, 0, 80, 1, 0);
    // Fill up all 32 slots (scroll_touched_rows capacity)
    var i: u32 = 0;
    while (i < 32) : (i += 1) {
        g.putCellGrid(2, i, 0, 'X', i);
    }
    try std.testing.expect(g.pending_scroll != null);
    try std.testing.expect(!g.scroll_fast_path_blocked);

    // 33rd distinct row overflows — blocks fast path but keeps pending_scroll
    // so subsequent grid_scroll events in the same batch can still accumulate.
    g.putCellGrid(2, 32, 0, 'Y', 32);
    try std.testing.expect(g.pending_scroll != null);
    try std.testing.expect(g.scroll_fast_path_blocked);
    try std.testing.expectEqual(@as(u8, 32), g.scroll_touched_count);
}

test "second scrollGrid accumulates when same grid and region" {
    const alloc = std.testing.allocator;
    var g = try setupGridWithSubgrid(alloc, 42, 80, 42, 80);
    defer g.deinit();

    g.scrollGrid(2, 1, 42, 0, 80, 1, 0);
    try std.testing.expect(g.pending_scroll != null);

    // Second scroll in same batch, same grid+region: accumulate, not blocked
    g.scrollGrid(2, 1, 42, 0, 80, 1, 0);
    try std.testing.expect(g.pending_scroll != null);
    try std.testing.expect(!g.scroll_fast_path_blocked);
    try std.testing.expectEqual(@as(i32, 2), g.pending_scroll.?.rows);
}

test "second scrollGrid blocks when different grid" {
    const alloc = std.testing.allocator;
    var g = try setupGridWithSubgrid(alloc, 42, 80, 42, 80);
    defer g.deinit();

    g.scrollGrid(2, 1, 42, 0, 80, 1, 0);
    try std.testing.expect(g.pending_scroll != null);

    // Scroll on main grid (different grid_id): blocks fast path
    g.scrollGrid(1, 1, 42, 0, 80, 1, 0);
    try std.testing.expect(g.scroll_fast_path_blocked);
}

test "clearScrollState resets all scroll tracking" {
    const alloc = std.testing.allocator;
    var g = try setupGridWithSubgrid(alloc, 42, 80, 42, 80);
    defer g.deinit();

    g.scrollGrid(2, 1, 42, 0, 80, 1, 0);
    g.putCellGrid(2, 41, 0, 'A', 0);
    g.setCursor(2, 10, 5);
    g.setCursor(2, 11, 5); // triggers prev_cursor_row

    try std.testing.expect(g.pending_scroll != null);
    try std.testing.expect(g.scroll_touched_count > 0);
    try std.testing.expect(g.prev_cursor_row != null);

    g.clearScrollState();

    try std.testing.expect(g.pending_scroll == null);
    try std.testing.expect(!g.scroll_fast_path_blocked);
    try std.testing.expectEqual(@as(u8, 0), g.scroll_touched_count);
    try std.testing.expect(g.prev_cursor_row == null);
}

test "setCursor records prev_cursor_row in main grid coordinates" {
    const alloc = std.testing.allocator;
    var g = try setupGridWithSubgrid(alloc, 42, 80, 42, 80);
    defer g.deinit();

    // Initial cursor position
    g.setCursor(2, 10, 5);
    try std.testing.expect(g.prev_cursor_row == null); // first set, no prev

    // Move cursor
    g.setCursor(2, 11, 5);
    // prev_cursor_row = win_pos_row(0) + old_row(10) = 10
    const pcr = g.prev_cursor_row orelse return error.TestUnexpectedNull;
    try std.testing.expectEqual(@as(u32, 10), pcr);
}

test "currentCursorMainRow returns current row in main grid coordinates" {
    const alloc = std.testing.allocator;
    var g = try setupGridWithSubgrid(alloc, 42, 80, 42, 80);
    defer g.deinit();

    g.setCursor(2, 11, 5);

    const current = g.currentCursorMainRow(2) orelse return error.TestUnexpectedNull;
    try std.testing.expectEqual(@as(u32, 11), current);
    try std.testing.expect(g.currentCursorMainRow(1) == null);
}

test "prevCursorMainRowAfterScroll applies scroll delta to previous cursor row" {
    const alloc = std.testing.allocator;
    var g = try setupGridWithSubgrid(alloc, 42, 80, 42, 80);
    defer g.deinit();

    g.setCursor(2, 24, 5);
    g.scrollGrid(2, 1, 42, 0, 80, 1, 0);
    g.setCursor(2, 23, 5);

    const ps = g.pending_scroll orelse return error.TestUnexpectedNull;
    const shifted = g.prevCursorMainRowAfterScroll(ps) orelse return error.TestUnexpectedNull;
    try std.testing.expectEqual(@as(u32, 23), shifted);
}

// ============================================================================
// B. Eligibility (checkScrollFastPath)
// ============================================================================

// Standard CachedSubgrid for the scrolling editor grid (grid_id=2, row 0..42, col 0..80).
// cells pointer is not accessed by checkScrollFastPath, so we use a dummy.
const dummy_cells: [1]grid_mod.Cell = .{.{ .cp = 0, .hl = 0 }};

fn scrollingSubgrid() flush_mod.CachedSubgrid {
    return .{
        .grid_id = 2,
        .row_start = 0,
        .row_end = 42,
        .col_start = 0,
        .sg_cols = 80,
        .sg_rows = 42,
        .cells = &dummy_cells,
        .margin_top = 0,
        .margin_bottom = 0,
    };
}

fn makeEligibleGrid(alloc: std.mem.Allocator) !Grid {
    var g = try setupGridWithSubgrid(alloc, 42, 80, 42, 80);
    g.scrollGrid(2, 1, 42, 0, 80, 1, 0);
    return g;
}

test "eligible: standard 1-line scroll down" {
    const alloc = std.testing.allocator;
    var g = try makeEligibleGrid(alloc);
    defer g.deinit();

    const sgs = [_]flush_mod.CachedSubgrid{scrollingSubgrid()};
    const result = flush_mod.checkScrollFastPath(&g, false, false, 1, &sgs);
    try std.testing.expect(result.eligible);
    try std.testing.expectEqual(flush_mod.ScrollFallbackReason.eligible, result.reason);
}

test "ineligible: scrolled_count != 1" {
    const alloc = std.testing.allocator;
    var g = try makeEligibleGrid(alloc);
    defer g.deinit();

    const sgs = [_]flush_mod.CachedSubgrid{scrollingSubgrid()};
    const result = flush_mod.checkScrollFastPath(&g, false, false, 2, &sgs);
    try std.testing.expect(!result.eligible);
    try std.testing.expectEqual(flush_mod.ScrollFallbackReason.multi_scroll_batch, result.reason);
}

test "eligible: accumulated same-grid scroll in same batch" {
    const alloc = std.testing.allocator;
    var g = try makeEligibleGrid(alloc);
    defer g.deinit();

    // Second scroll accumulates (same grid+region), not blocked
    g.scrollGrid(2, 1, 42, 0, 80, 1, 0);
    try std.testing.expect(!g.scroll_fast_path_blocked);

    const sgs = [_]flush_mod.CachedSubgrid{scrollingSubgrid()};
    const result = flush_mod.checkScrollFastPath(&g, false, false, 1, &sgs);
    try std.testing.expect(result.eligible);
    try std.testing.expectEqual(@as(i32, 2), result.scroll_op.?.rows);
}

test "ineligible: grid_id < 2" {
    const alloc = std.testing.allocator;
    var g = Grid.init(alloc);
    defer g.deinit();
    try g.resize(42, 80);
    // scroll on global grid (grid_id=1)
    g.scrollGrid(1, 1, 42, 0, 80, 1, 0);

    const sgs = [_]flush_mod.CachedSubgrid{scrollingSubgrid()};
    const result = flush_mod.checkScrollFastPath(&g, false, false, 1, &sgs);
    try std.testing.expect(!result.eligible);
}

test "eligible: multi-row scroll (3 rows within half region)" {
    const alloc = std.testing.allocator;
    var g = try setupGridWithSubgrid(alloc, 42, 80, 42, 80);
    defer g.deinit();
    g.scrollGrid(2, 1, 42, 0, 80, 3, 0); // 3 rows, region height=41, 3 <= 41/2

    const sgs = [_]flush_mod.CachedSubgrid{scrollingSubgrid()};
    const result = flush_mod.checkScrollFastPath(&g, false, false, 1, &sgs);
    try std.testing.expect(result.eligible);
}

test "ineligible: multi-row scroll exceeds half region" {
    const alloc = std.testing.allocator;
    var g = try setupGridWithSubgrid(alloc, 42, 80, 42, 80);
    defer g.deinit();
    g.scrollGrid(2, 1, 42, 0, 80, 21, 0); // 21 rows, region height=41, 21 > 41/2=20

    const sgs = [_]flush_mod.CachedSubgrid{scrollingSubgrid()};
    const result = flush_mod.checkScrollFastPath(&g, false, false, 1, &sgs);
    try std.testing.expect(!result.eligible);
    try std.testing.expectEqual(flush_mod.ScrollFallbackReason.multi_row_scroll, result.reason);
}

test "ineligible: scroll rows >= region height" {
    const alloc = std.testing.allocator;
    var g = try setupGridWithSubgrid(alloc, 42, 80, 42, 80);
    defer g.deinit();
    g.scrollGrid(2, 1, 42, 0, 80, 41, 0); // 41 rows = entire region

    const sgs = [_]flush_mod.CachedSubgrid{scrollingSubgrid()};
    const result = flush_mod.checkScrollFastPath(&g, false, false, 1, &sgs);
    try std.testing.expect(!result.eligible);
    try std.testing.expectEqual(flush_mod.ScrollFallbackReason.multi_row_scroll, result.reason);
}

test "eligible: top == 0 (full grid scroll)" {
    const alloc = std.testing.allocator;
    var g = try setupGridWithSubgrid(alloc, 42, 80, 42, 80);
    defer g.deinit();
    g.scrollGrid(2, 0, 42, 0, 80, 1, 0); // top=0, full grid

    const sgs = [_]flush_mod.CachedSubgrid{scrollingSubgrid()};
    const result = flush_mod.checkScrollFastPath(&g, false, false, 1, &sgs);
    try std.testing.expect(result.eligible);
    try std.testing.expectEqual(flush_mod.ScrollFallbackReason.eligible, result.reason);
}

test "eligible: partial region bot < target_rows" {
    const alloc = std.testing.allocator;
    var g = try setupGridWithSubgrid(alloc, 42, 80, 42, 80);
    defer g.deinit();
    g.scrollGrid(2, 1, 40, 0, 80, 1, 0); // bot=40, target_rows=42

    const sgs = [_]flush_mod.CachedSubgrid{scrollingSubgrid()};
    const result = flush_mod.checkScrollFastPath(&g, false, false, 1, &sgs);
    try std.testing.expect(result.eligible);
    try std.testing.expectEqual(flush_mod.ScrollFallbackReason.eligible, result.reason);
}

test "ineligible: bot > target_rows" {
    const alloc = std.testing.allocator;
    var g = try setupGridWithSubgrid(alloc, 42, 80, 42, 80);
    defer g.deinit();
    g.scrollGrid(2, 1, 43, 0, 80, 1, 0); // bot=43 > target_rows=42

    const sgs = [_]flush_mod.CachedSubgrid{scrollingSubgrid()};
    const result = flush_mod.checkScrollFastPath(&g, false, false, 1, &sgs);
    try std.testing.expect(!result.eligible);
    try std.testing.expectEqual(flush_mod.ScrollFallbackReason.not_full_region, result.reason);
}

test "ineligible: partial width" {
    const alloc = std.testing.allocator;
    var g = try setupGridWithSubgrid(alloc, 42, 80, 42, 80);
    defer g.deinit();
    g.scrollGrid(2, 1, 42, 5, 80, 1, 0); // left=5

    const sgs = [_]flush_mod.CachedSubgrid{scrollingSubgrid()};
    const result = flush_mod.checkScrollFastPath(&g, false, false, 1, &sgs);
    try std.testing.expect(!result.eligible);
    try std.testing.expectEqual(flush_mod.ScrollFallbackReason.partial_width, result.reason);
}

test "ineligible: rebuild_all" {
    const alloc = std.testing.allocator;
    var g = try makeEligibleGrid(alloc);
    defer g.deinit();

    const sgs = [_]flush_mod.CachedSubgrid{scrollingSubgrid()};
    const result = flush_mod.checkScrollFastPath(&g, true, false, 1, &sgs);
    try std.testing.expect(!result.eligible);
    try std.testing.expectEqual(flush_mod.ScrollFallbackReason.rebuild_all_set, result.reason);
}

test "ineligible: atlas_retried" {
    const alloc = std.testing.allocator;
    var g = try makeEligibleGrid(alloc);
    defer g.deinit();

    const sgs = [_]flush_mod.CachedSubgrid{scrollingSubgrid()};
    const result = flush_mod.checkScrollFastPath(&g, false, true, 1, &sgs);
    try std.testing.expect(!result.eligible);
    try std.testing.expectEqual(flush_mod.ScrollFallbackReason.atlas_retried, result.reason);
}

test "ineligible: non-scrolling subgrid overlaps scroll region" {
    const alloc = std.testing.allocator;
    var g = try makeEligibleGrid(alloc);
    defer g.deinit();

    // Scrolling grid (grid_id=2) at rows 0..42, scroll region top=1 bot=42 → global rows 1..42
    // Float window (grid_id=5) at rows 10..15 overlaps the scroll region
    const sgs = [_]flush_mod.CachedSubgrid{
        scrollingSubgrid(),
        .{
            .grid_id = 5,
            .row_start = 10,
            .row_end = 15,
            .col_start = 20,
            .sg_cols = 30,
            .sg_rows = 5,
            .cells = &dummy_cells,
            .margin_top = 0,
            .margin_bottom = 0,
        },
    };
    const result = flush_mod.checkScrollFastPath(&g, false, false, 1, &sgs);
    try std.testing.expect(!result.eligible);
    try std.testing.expectEqual(flush_mod.ScrollFallbackReason.subgrid_overlaps_scroll, result.reason);
}

test "eligible: non-scrolling subgrid outside scroll region (msg_set_pos)" {
    const alloc = std.testing.allocator;
    var g = try setupGridWithSubgrid(alloc, 44, 80, 42, 80);
    defer g.deinit();
    // Editor grid at row 1 (win_pos_row=1), msg grid at row 43 (outside scroll region)
    try g.setWinPos(2, 0, 1, 0);
    g.scrollGrid(2, 1, 42, 0, 80, 1, 0); // scroll region top=1 bot=42, win_pos_row=1 → global rows 2..43

    const sgs = [_]flush_mod.CachedSubgrid{
        .{
            .grid_id = 2,
            .row_start = 1,
            .row_end = 43,
            .col_start = 0,
            .sg_cols = 80,
            .sg_rows = 42,
            .cells = &dummy_cells,
            .margin_top = 0,
            .margin_bottom = 0,
        },
        .{
            .grid_id = 3,
            .row_start = 43,
            .row_end = 44,
            .col_start = 0,
            .sg_cols = 80,
            .sg_rows = 1,
            .cells = &dummy_cells,
            .margin_top = 0,
            .margin_bottom = 0,
        },
    };
    const result = flush_mod.checkScrollFastPath(&g, false, false, 1, &sgs);
    try std.testing.expect(result.eligible);
    try std.testing.expectEqual(flush_mod.ScrollFallbackReason.eligible, result.reason);
}

test "ineligible: scroll region exceeds global grid bounds (win_pos_row)" {
    const alloc = std.testing.allocator;
    // Global grid has 20 rows, subgrid has 20 rows at win_pos_row=5.
    // scroll bot=20 + win_pos_row=5 → global row 25, but global grid only has 20 rows.
    var g = try setupGridWithSubgrid(alloc, 20, 80, 20, 80);
    defer g.deinit();
    try g.setWinPos(2, 0, 5, 0);
    g.scrollGrid(2, 1, 20, 0, 80, 1, 0); // bot=20, win_pos_row=5 → scroll_row_end=25 > 20

    const sgs = [_]flush_mod.CachedSubgrid{
        .{
            .grid_id = 2,
            .row_start = 5,
            .row_end = 25, // extends beyond global grid
            .col_start = 0,
            .sg_cols = 80,
            .sg_rows = 20,
            .cells = &dummy_cells,
            .margin_top = 0,
            .margin_bottom = 0,
        },
    };
    const result = flush_mod.checkScrollFastPath(&g, false, false, 1, &sgs);
    try std.testing.expect(!result.eligible);
    try std.testing.expectEqual(flush_mod.ScrollFallbackReason.not_full_region, result.reason);
}

test "ineligible: no pending_scroll" {
    const alloc = std.testing.allocator;
    var g = Grid.init(alloc);
    defer g.deinit();
    try g.resize(42, 80);

    const sgs = [_]flush_mod.CachedSubgrid{scrollingSubgrid()};
    const result = flush_mod.checkScrollFastPath(&g, false, false, 1, &sgs);
    try std.testing.expect(!result.eligible);
    try std.testing.expectEqual(flush_mod.ScrollFallbackReason.no_pending_scroll, result.reason);
}

test "eligible: reverse single-line scroll (rows == -1)" {
    const alloc = std.testing.allocator;
    var g = try setupGridWithSubgrid(alloc, 42, 80, 42, 80);
    defer g.deinit();
    g.scrollGrid(2, 1, 42, 0, 80, -1, 0);

    const sgs = [_]flush_mod.CachedSubgrid{scrollingSubgrid()};
    const result = flush_mod.checkScrollFastPath(&g, false, false, 1, &sgs);
    try std.testing.expect(result.eligible);
    try std.testing.expectEqual(flush_mod.ScrollFallbackReason.eligible, result.reason);
}

// ============================================================================
// C. Scroll cache invalidation / fallback
// ============================================================================

test "ensureScrollCache sizes correctly" {
    const alloc = std.testing.allocator;
    const nvim_core_mod = zonvie_core.nvim_core;
    var core = nvim_core_mod.Core.initForTest(alloc);
    defer core.deinitForTest();

    try core.ensureScrollCache(42);
    try std.testing.expectEqual(@as(u32, 42), core.scroll_cache_rows);
    try std.testing.expectEqual(@as(usize, 42), core.scroll_cache.items.len);
    try std.testing.expectEqual(@as(usize, 42), core.scroll_cache_valid.bit_length);

    // All bits should be unset (fresh)
    var any_set = false;
    for (0..42) |i| {
        if (core.scroll_cache_valid.isSet(i)) {
            any_set = true;
            break;
        }
    }
    try std.testing.expect(!any_set);
}

test "invalidateScrollCache clears valid bits" {
    const alloc = std.testing.allocator;
    const nvim_core_mod = zonvie_core.nvim_core;
    var core = nvim_core_mod.Core.initForTest(alloc);
    defer core.deinitForTest();

    try core.ensureScrollCache(10);
    // Manually set some bits
    core.scroll_cache_valid.set(0);
    core.scroll_cache_valid.set(5);
    core.scroll_cache_valid.set(9);

    core.invalidateScrollCache();

    // scroll_cache_rows reset to 0
    try std.testing.expectEqual(@as(u32, 0), core.scroll_cache_rows);
    // After invalidation, all bits should be unset
    // (bitset is still allocated but all unset)
    for (0..10) |i| {
        try std.testing.expect(!core.scroll_cache_valid.isSet(i));
    }
}

test "ensureScrollCache resize shrinks correctly" {
    const alloc = std.testing.allocator;
    const nvim_core_mod = zonvie_core.nvim_core;
    var core = nvim_core_mod.Core.initForTest(alloc);
    defer core.deinitForTest();

    try core.ensureScrollCache(10);
    try core.ensureScrollCache(5);

    try std.testing.expectEqual(@as(u32, 5), core.scroll_cache_rows);
    try std.testing.expectEqual(@as(usize, 5), core.scroll_cache.items.len);
}

// ============================================================================
// D. Flush fast path integration: shiftScrollCacheAndValidate
// ============================================================================

const c_api = zonvie_core;
const Vertex = c_api.Vertex;

fn makeVertex(y: f32) Vertex {
    return .{
        .position = .{ 0.0, y },
        .texCoord = .{ 0.0, 0.0 },
        .color = .{ 1.0, 1.0, 1.0, 1.0 },
        .grid_id = 1,
        .deco_flags = 0,
        .deco_phase = 0,
    };
}

/// Populate row `r` of the scroll cache with a single vertex at NDC y = row_ndc_y(r).
/// NDC y for row r: 1.0 - (r * cellH / dh) * 2.0
fn populateRow(core: *zonvie_core.nvim_core.Core, r: usize, total_rows: u32) !void {
    const cellH: f32 = 20.0;
    const dh: f32 = @as(f32, @floatFromInt(total_rows)) * cellH;
    const ndc_y: f32 = 1.0 - (@as(f32, @floatFromInt(r)) * cellH / dh) * 2.0;
    var row_buf = &core.scroll_cache.items[r];
    row_buf.clearRetainingCapacity();
    try row_buf.append(core.alloc, makeVertex(ndc_y));
    core.scroll_cache_valid.set(r);
}

test "valid cache: cached rows emitted after shift (scroll down)" {
    // 5 rows, scroll region [1..5), scroll_rows=1, regen={4} (new bottom row)
    // After shift: row1←row2, row2←row3, row3←row4, row4=vacant(invalid)
    // Regen row 4 → invalid. Non-regen rows 0,1,2,3 should all be valid.
    const alloc = std.testing.allocator;
    const nvim_core_mod = zonvie_core.nvim_core;
    var core = nvim_core_mod.Core.initForTest(alloc);
    defer core.deinitForTest();

    const total_rows: u32 = 5;
    try core.ensureScrollCache(total_rows);
    // Populate all rows with valid cache
    for (0..total_rows) |r| {
        try populateRow(&core, r, total_rows);
    }

    // cellH=20, dh=5*20=100. delta_y = 1 * 20 / 100 * 2.0 = 0.4
    const delta_y: f32 = 1.0 * 20.0 / 100.0 * 2.0;
    const regen = [_]u32{4};

    const result = flush_mod.shiftScrollCacheAndValidate(
        &core, 1, 5, 1, delta_y, total_rows, &regen,
    );

    // Fast path should be OK: rows 0,1,2,3 valid, row 4 is regen
    try std.testing.expect(result.fast_path_ok);
    try std.testing.expectEqual(@as(u32, 4), result.cached_emit_count); // rows 0,1,2,3
    try std.testing.expectEqual(@as(u32, 0), result.empty_emit_count);

    // Verify y-coordinates were adjusted for shifted rows.
    // Row 1 now has old row 2's data with y adjusted by +delta_y.
    // Original row 2 NDC y = 1.0 - (2*20/100)*2.0 = 1.0 - 0.8 = 0.2
    // After adjust: 0.2 + 0.4 = 0.6
    // Row 1's expected y = 1.0 - (1*20/100)*2.0 = 1.0 - 0.4 = 0.6 ✓
    const row1_y = core.scroll_cache.items[1].items[0].position[1];
    try std.testing.expectApproxEqAbs(@as(f32, 0.6), row1_y, 0.001);

    // Row 0 (outside scroll region) should be untouched
    // Original row 0 NDC y = 1.0 - 0 = 1.0
    const row0_y = core.scroll_cache.items[0].items[0].position[1];
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), row0_y, 0.001);
    try std.testing.expect(core.scroll_cache_valid.isSet(0));
}

test "invalid cache: fast path cancelled when non-regen row is invalid" {
    // Simulate: invalidateScrollCache() was called (font change),
    // then ensureScrollCache(5) re-sizes but leaves all bits unset.
    // Scroll fast path should be cancelled.
    const alloc = std.testing.allocator;
    const nvim_core_mod = zonvie_core.nvim_core;
    var core = nvim_core_mod.Core.initForTest(alloc);
    defer core.deinitForTest();

    const total_rows: u32 = 5;
    // Populate cache, then invalidate (simulating font change)
    try core.ensureScrollCache(total_rows);
    for (0..total_rows) |r| {
        try populateRow(&core, r, total_rows);
    }
    core.invalidateScrollCache();
    // Re-ensure (as flush does at top of row-mode block)
    try core.ensureScrollCache(total_rows);

    const delta_y: f32 = 1.0 * 20.0 / 100.0 * 2.0;
    const regen = [_]u32{4};

    const result = flush_mod.shiftScrollCacheAndValidate(
        &core, 1, 5, 1, delta_y, total_rows, &regen,
    );

    // Fast path should be cancelled: all valid bits are false
    try std.testing.expect(!result.fast_path_ok);
}

test "empty cached row emitted with vert_count==0" {
    // Row 3 has valid cache but 0 vertices (background-only row).
    // After shift, it should appear as cached_emit with empty_emit_count=1.
    const alloc = std.testing.allocator;
    const nvim_core_mod = zonvie_core.nvim_core;
    var core = nvim_core_mod.Core.initForTest(alloc);
    defer core.deinitForTest();

    const total_rows: u32 = 5;
    try core.ensureScrollCache(total_rows);
    // Populate all rows
    for (0..total_rows) |r| {
        try populateRow(&core, r, total_rows);
    }
    // Make row 2 an empty row (valid but 0 vertices) — will shift to row 1
    core.scroll_cache.items[2].clearRetainingCapacity();
    // Valid bit stays set (it's a legitimate empty row)

    const delta_y: f32 = 1.0 * 20.0 / 100.0 * 2.0;
    const regen = [_]u32{4};

    const result = flush_mod.shiftScrollCacheAndValidate(
        &core, 1, 5, 1, delta_y, total_rows, &regen,
    );

    try std.testing.expect(result.fast_path_ok);
    try std.testing.expectEqual(@as(u32, 4), result.cached_emit_count);
    // Row 2 shifted to row 1 → empty row is now at index 1
    try std.testing.expectEqual(@as(u32, 1), result.empty_emit_count);
    // Verify the empty row is at index 1 with len==0
    try std.testing.expectEqual(@as(usize, 0), core.scroll_cache.items[1].items.len);
    try std.testing.expect(core.scroll_cache_valid.isSet(1));
}

test "multi-row scroll down (rows=3): shift and vacate 3 rows" {
    // 10 rows, scroll region [1..10), scroll_rows=3, regen={7,8,9}
    // After shift: row1←row4, row2←row5, ..., row6←row9
    // Vacated: rows 7,8,9 (invalid). Row 0 untouched.
    const alloc = std.testing.allocator;
    const nvim_core_mod = zonvie_core.nvim_core;
    var core = nvim_core_mod.Core.initForTest(alloc);
    defer core.deinitForTest();

    const total_rows: u32 = 10;
    try core.ensureScrollCache(total_rows);
    for (0..total_rows) |r| {
        try populateRow(&core, r, total_rows);
    }

    // cellH=20, dh=10*20=200. delta_y = 3 * 20 / 200 * 2.0 = 0.6
    const delta_y: f32 = 3.0 * 20.0 / 200.0 * 2.0;
    const regen = [_]u32{ 7, 8, 9 };

    const result = flush_mod.shiftScrollCacheAndValidate(
        &core, 1, 10, 3, delta_y, total_rows, &regen,
    );

    try std.testing.expect(result.fast_path_ok);
    // Non-regen rows: 0,1,2,3,4,5,6 = 7 rows
    try std.testing.expectEqual(@as(u32, 7), result.cached_emit_count);

    // Row 0 (outside scroll region): untouched, original y = 1.0
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), core.scroll_cache.items[0].items[0].position[1], 0.001);

    // Row 1 now has old row 4's data, y-adjusted.
    // Original row 4 y = 1.0 - (4*20/200)*2.0 = 1.0 - 0.8 = 0.2
    // After adjust: 0.2 + 0.6 = 0.8
    // Expected for row 1: 1.0 - (1*20/200)*2.0 = 1.0 - 0.2 = 0.8 ✓
    try std.testing.expectApproxEqAbs(@as(f32, 0.8), core.scroll_cache.items[1].items[0].position[1], 0.001);

    // Vacated rows 7,8,9 must be invalid
    try std.testing.expect(!core.scroll_cache_valid.isSet(7));
    try std.testing.expect(!core.scroll_cache_valid.isSet(8));
    try std.testing.expect(!core.scroll_cache_valid.isSet(9));

    // Vacated rows should have empty buffers (cleared)
    try std.testing.expectEqual(@as(usize, 0), core.scroll_cache.items[7].items.len);
    try std.testing.expectEqual(@as(usize, 0), core.scroll_cache.items[8].items.len);
    try std.testing.expectEqual(@as(usize, 0), core.scroll_cache.items[9].items.len);
}

test "multi-row scroll up (rows=-3): shift and vacate 3 rows" {
    // 10 rows, scroll region [1..10), scroll_rows=-3, regen={1,2,3}
    // After shift: row9←row6, row8←row5, ..., row4←row1
    // Vacated: rows 1,2,3 (invalid). Row 0 untouched.
    const alloc = std.testing.allocator;
    const nvim_core_mod = zonvie_core.nvim_core;
    var core = nvim_core_mod.Core.initForTest(alloc);
    defer core.deinitForTest();

    const total_rows: u32 = 10;
    try core.ensureScrollCache(total_rows);
    for (0..total_rows) |r| {
        try populateRow(&core, r, total_rows);
    }

    // delta_y = -3 * 20 / 200 * 2.0 = -0.6
    const delta_y: f32 = -3.0 * 20.0 / 200.0 * 2.0;
    const regen = [_]u32{ 1, 2, 3 };

    const result = flush_mod.shiftScrollCacheAndValidate(
        &core, 1, 10, -3, delta_y, total_rows, &regen,
    );

    try std.testing.expect(result.fast_path_ok);
    // Non-regen rows: 0,4,5,6,7,8,9 = 7 rows
    try std.testing.expectEqual(@as(u32, 7), result.cached_emit_count);

    // Row 0 untouched
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), core.scroll_cache.items[0].items[0].position[1], 0.001);

    // Row 9 now has old row 6's data, y-adjusted.
    // Original row 6 y = 1.0 - (6*20/200)*2.0 = 1.0 - 1.2 = -0.2
    // After adjust: -0.2 + (-0.6) = -0.8
    // Expected for row 9: 1.0 - (9*20/200)*2.0 = 1.0 - 1.8 = -0.8 ✓
    try std.testing.expectApproxEqAbs(@as(f32, -0.8), core.scroll_cache.items[9].items[0].position[1], 0.001);

    // Row 4 now has old row 1's data, y-adjusted.
    // Original row 1 y = 1.0 - (1*20/200)*2.0 = 1.0 - 0.2 = 0.8
    // After adjust: 0.8 + (-0.6) = 0.2
    // Expected for row 4: 1.0 - (4*20/200)*2.0 = 1.0 - 0.8 = 0.2 ✓
    try std.testing.expectApproxEqAbs(@as(f32, 0.2), core.scroll_cache.items[4].items[0].position[1], 0.001);

    // Vacated rows 1,2,3 must be invalid
    try std.testing.expect(!core.scroll_cache_valid.isSet(1));
    try std.testing.expect(!core.scroll_cache_valid.isSet(2));
    try std.testing.expect(!core.scroll_cache_valid.isSet(3));

    // Vacated rows should have empty buffers
    try std.testing.expectEqual(@as(usize, 0), core.scroll_cache.items[1].items.len);
    try std.testing.expectEqual(@as(usize, 0), core.scroll_cache.items[2].items.len);
    try std.testing.expectEqual(@as(usize, 0), core.scroll_cache.items[3].items.len);
}
