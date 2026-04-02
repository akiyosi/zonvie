// Cell overflow map correctness tests.
// Exercises put/get/remove/clear/scroll/resize with >64 entries
// to verify no double-free, dangling pointer, or stale entry bugs.

const std = @import("std");
const zonvie_core = @import("zonvie_core");
const grid_mod = zonvie_core.grid_mod;
const Grid = grid_mod.Grid;

// ============================================================================
// Helpers
// ============================================================================

fn setupGrid(alloc: std.mem.Allocator, rows: u32, cols: u32) !Grid {
    var g = Grid.init(alloc);
    try g.resize(rows, cols);
    return g;
}

fn setupGridWithSubgrid(alloc: std.mem.Allocator, main_rows: u32, main_cols: u32, sg_rows: u32, sg_cols: u32) !Grid {
    var g = Grid.init(alloc);
    try g.resize(main_rows, main_cols);
    try g.resizeGrid(2, sg_rows, sg_cols);
    try g.setWinPos(2, 0, 0, 0);
    return g;
}

/// Populate N overflow entries for a given grid_id, row 0, cols 0..N-1.
fn populateOverflow(g: *Grid, grid_id: i64, count: u32) void {
    var col: u32 = 0;
    while (col < count) : (col += 1) {
        g.putOverflow(grid_id, 0, col, &[_]u32{0xFE0F});
    }
}

/// Populate N overflow entries across multiple rows.
fn populateOverflowRows(g: *Grid, grid_id: i64, row_start: u32, row_end: u32, cols: u32) void {
    var row = row_start;
    while (row < row_end) : (row += 1) {
        var col: u32 = 0;
        while (col < cols) : (col += 1) {
            g.putOverflow(grid_id, row, col, &[_]u32{0xFE0F});
        }
    }
}

/// Count overflow entries for a given grid_id by scanning the map.
fn countOverflowForGrid(g: *const Grid, grid_id: i64) u32 {
    var count: u32 = 0;
    var it = g.cell_overflow.iterator();
    while (it.next()) |e| {
        if (e.key_ptr.grid_id == grid_id) count += 1;
    }
    return count;
}

// ============================================================================
// Basic put/get/remove
// ============================================================================

test "put and get overflow" {
    const alloc = std.testing.allocator;
    var g = try setupGrid(alloc, 10, 80);
    defer g.deinit();

    g.putOverflow(1, 0, 5, &[_]u32{ 0xFE0F, 0x200D });

    const extras = g.getOverflow(1, 0, 5);
    try std.testing.expect(extras != null);
    try std.testing.expectEqual(@as(usize, 2), extras.?.len);
    try std.testing.expectEqual(@as(u32, 0xFE0F), extras.?[0]);
    try std.testing.expectEqual(@as(u32, 0x200D), extras.?[1]);

    // Non-existent cell returns null
    try std.testing.expect(g.getOverflow(1, 0, 6) == null);
}

test "remove overflow" {
    const alloc = std.testing.allocator;
    var g = try setupGrid(alloc, 10, 80);
    defer g.deinit();

    g.putOverflow(1, 3, 7, &[_]u32{0xFE0F});
    try std.testing.expect(g.getOverflow(1, 3, 7) != null);

    g.removeOverflow(1, 3, 7);
    try std.testing.expect(g.getOverflow(1, 3, 7) == null);

    // Double remove is safe
    g.removeOverflow(1, 3, 7);
}

test "put overwrites existing overflow" {
    const alloc = std.testing.allocator;
    var g = try setupGrid(alloc, 10, 80);
    defer g.deinit();

    g.putOverflow(1, 0, 0, &[_]u32{0xFE0F});
    g.putOverflow(1, 0, 0, &[_]u32{ 0xFE0E, 0x200D });

    const extras = g.getOverflow(1, 0, 0);
    try std.testing.expect(extras != null);
    try std.testing.expectEqual(@as(usize, 2), extras.?.len);
    try std.testing.expectEqual(@as(u32, 0xFE0E), extras.?[0]);
}

// ============================================================================
// clearOverflowForGrid with >64 entries
// ============================================================================

test "clearOverflowForGrid handles >64 entries without double-free" {
    const alloc = std.testing.allocator;
    var g = try setupGrid(alloc, 10, 200);
    defer g.deinit();

    // Populate 100 overflow entries for grid 1
    populateOverflow(&g, 1, 100);
    try std.testing.expectEqual(@as(u32, 100), countOverflowForGrid(&g, 1));

    g.clearOverflowForGrid(1);
    try std.testing.expectEqual(@as(u32, 0), countOverflowForGrid(&g, 1));
    try std.testing.expectEqual(@as(u32, 0), g.cell_overflow.count());
}

test "clearOverflowForGrid does not affect other grids" {
    const alloc = std.testing.allocator;
    var g = try setupGridWithSubgrid(alloc, 10, 200, 10, 200);
    defer g.deinit();

    // 80 entries for grid 1, 80 for grid 2
    populateOverflow(&g, 1, 80);
    populateOverflow(&g, 2, 80);
    try std.testing.expectEqual(@as(u32, 160), g.cell_overflow.count());

    g.clearOverflowForGrid(1);
    try std.testing.expectEqual(@as(u32, 0), countOverflowForGrid(&g, 1));
    try std.testing.expectEqual(@as(u32, 80), countOverflowForGrid(&g, 2));
}

// ============================================================================
// clearGrid / resizeGrid clear overflow
// ============================================================================

test "clearGrid removes overflow entries" {
    const alloc = std.testing.allocator;
    var g = try setupGrid(alloc, 10, 200);
    defer g.deinit();

    populateOverflow(&g, 1, 100);
    g.clearGrid(1);
    try std.testing.expectEqual(@as(u32, 0), countOverflowForGrid(&g, 1));
}

test "resizeGrid preserves overflow in overlap region and trims out-of-bounds" {
    const alloc = std.testing.allocator;
    var g = try setupGrid(alloc, 10, 200);
    defer g.deinit();

    // 100 entries at row 0, cols 0..99
    populateOverflow(&g, 1, 100);
    try std.testing.expectEqual(@as(u32, 100), countOverflowForGrid(&g, 1));

    // Resize to 20 rows, 50 cols → cols 50..99 are out of bounds
    try g.resizeGrid(1, 20, 50);

    // Entries in overlap [0, 10) x [0, 50) are preserved
    try std.testing.expectEqual(@as(u32, 50), countOverflowForGrid(&g, 1));
    // Entry within bounds still accessible
    try std.testing.expect(g.getOverflow(1, 0, 0) != null);
    try std.testing.expect(g.getOverflow(1, 0, 49) != null);
    // Entry out of bounds removed
    try std.testing.expect(g.getOverflow(1, 0, 50) == null);
    try std.testing.expect(g.getOverflow(1, 0, 99) == null);
}

test "resizeGrid shrinking rows trims overflow" {
    const alloc = std.testing.allocator;
    var g = try setupGrid(alloc, 20, 80);
    defer g.deinit();

    // Entries at rows 0..19, col 0
    populateOverflowRows(&g, 1, 0, 20, 1);
    try std.testing.expectEqual(@as(u32, 20), countOverflowForGrid(&g, 1));

    // Shrink to 10 rows → rows 10..19 out of bounds
    try g.resizeGrid(1, 10, 80);
    try std.testing.expectEqual(@as(u32, 10), countOverflowForGrid(&g, 1));
    try std.testing.expect(g.getOverflow(1, 9, 0) != null);
    try std.testing.expect(g.getOverflow(1, 10, 0) == null);
}

// ============================================================================
// scrollOverflow with >64 entries
// ============================================================================

test "scrollOverflow moves entries correctly (scroll up)" {
    const alloc = std.testing.allocator;
    var g = try setupGrid(alloc, 100, 80);
    defer g.deinit();

    // Put overflow at rows 5..14 (10 rows), col 0
    var row: u32 = 5;
    while (row < 15) : (row += 1) {
        g.putOverflow(1, row, 0, &[_]u32{0xFE0F});
    }
    try std.testing.expectEqual(@as(u32, 10), countOverflowForGrid(&g, 1));

    // Scroll up by 3 in region [0, 20)
    g.scrollOverflow(1, 0, 20, 0, 80, 3);

    // Rows 0..2 scrolled out (but we had nothing there)
    // Rows 3..16 remain, shifted up by 3:
    //   row 5 → row 2, row 6 → row 3, ..., row 14 → row 11
    // Rows 5..14 had overflow → now at rows 2..11
    var found: u32 = 0;
    row = 0;
    while (row < 20) : (row += 1) {
        if (g.getOverflow(1, row, 0) != null) found += 1;
    }
    try std.testing.expectEqual(@as(u32, 10), found);

    // Verify specific positions
    try std.testing.expect(g.getOverflow(1, 2, 0) != null); // was row 5
    try std.testing.expect(g.getOverflow(1, 11, 0) != null); // was row 14
    try std.testing.expect(g.getOverflow(1, 12, 0) == null); // nothing here
}

test "scrollOverflow moves entries correctly (scroll down)" {
    const alloc = std.testing.allocator;
    var g = try setupGrid(alloc, 100, 80);
    defer g.deinit();

    g.putOverflow(1, 2, 0, &[_]u32{0xFE0F});
    g.putOverflow(1, 3, 0, &[_]u32{0xFE0F});

    // Scroll down by 5 in region [0, 20)
    g.scrollOverflow(1, 0, 20, 0, 80, -5);

    // row 2 → row 7, row 3 → row 8
    try std.testing.expect(g.getOverflow(1, 2, 0) == null);
    try std.testing.expect(g.getOverflow(1, 3, 0) == null);
    try std.testing.expect(g.getOverflow(1, 7, 0) != null);
    try std.testing.expect(g.getOverflow(1, 8, 0) != null);
}

test "scrollOverflow handles >64 entries" {
    const alloc = std.testing.allocator;
    var g = try setupGrid(alloc, 200, 200);
    defer g.deinit();

    // 100 entries across rows 10..19, cols 0..9
    populateOverflowRows(&g, 1, 10, 20, 10);
    try std.testing.expectEqual(@as(u32, 100), countOverflowForGrid(&g, 1));

    // Scroll up by 5 in region [0, 100)
    g.scrollOverflow(1, 0, 100, 0, 200, 5);

    // Rows 0..4 scrolled out (nothing there).
    // Rows 10..19 → rows 5..14.
    try std.testing.expectEqual(@as(u32, 100), countOverflowForGrid(&g, 1));
    // Check first and last moved entry
    try std.testing.expect(g.getOverflow(1, 5, 0) != null); // was row 10
    try std.testing.expect(g.getOverflow(1, 14, 9) != null); // was row 19
    // row 10 now has the entry that was at row 15 (shifted up by 5)
    try std.testing.expect(g.getOverflow(1, 10, 0) != null);
    // row 15 and above should be empty (moved down)
    try std.testing.expect(g.getOverflow(1, 15, 0) == null);
}

test "scrollOverflow discards scrolled-out entries (>64)" {
    const alloc = std.testing.allocator;
    var g = try setupGrid(alloc, 200, 200);
    defer g.deinit();

    // 100 entries at rows 0..9, cols 0..9
    populateOverflowRows(&g, 1, 0, 10, 10);
    try std.testing.expectEqual(@as(u32, 100), countOverflowForGrid(&g, 1));

    // Scroll up by 10 in region [0, 20) → all entries scrolled out
    g.scrollOverflow(1, 0, 20, 0, 200, 10);

    try std.testing.expectEqual(@as(u32, 0), countOverflowForGrid(&g, 1));
}

// ============================================================================
// scroll() early return (shift >= height) clears overflow
// ============================================================================

test "global grid scroll with shift >= height clears overflow" {
    const alloc = std.testing.allocator;
    var g = try setupGrid(alloc, 50, 80);
    defer g.deinit();

    populateOverflow(&g, 1, 70);
    try std.testing.expectEqual(@as(u32, 70), countOverflowForGrid(&g, 1));

    // Scroll up by 50 in region [0, 50) — shift >= height → early return path
    g.scroll(0, 50, 0, 80, 50, 0);

    try std.testing.expectEqual(@as(u32, 0), countOverflowForGrid(&g, 1));
}

// ============================================================================
// clearOverflowRect with >64 entries
// ============================================================================

test "clearOverflowRect handles >64 entries" {
    const alloc = std.testing.allocator;
    var g = try setupGrid(alloc, 100, 200);
    defer g.deinit();

    // 100 entries at row 0, cols 0..99
    populateOverflow(&g, 1, 100);

    // Clear rect covering cols 0..49 (50 entries)
    g.clearOverflowRect(1, 0, 1, 0, 50);
    try std.testing.expectEqual(@as(u32, 50), countOverflowForGrid(&g, 1));

    // Clear remaining 50
    g.clearOverflowRect(1, 0, 1, 50, 100);
    try std.testing.expectEqual(@as(u32, 0), countOverflowForGrid(&g, 1));
}

// ============================================================================
// destroyGrid clears overflow
// ============================================================================

test "destroyGrid removes overflow for that grid" {
    const alloc = std.testing.allocator;
    var g = try setupGridWithSubgrid(alloc, 10, 200, 10, 200);
    defer g.deinit();

    populateOverflow(&g, 1, 50);
    populateOverflow(&g, 2, 50);

    g.destroyGrid(2);
    try std.testing.expectEqual(@as(u32, 50), countOverflowForGrid(&g, 1));
    try std.testing.expectEqual(@as(u32, 0), countOverflowForGrid(&g, 2));
}

// ============================================================================
// Float overlay map + getOverflowForCell integration tests
// ============================================================================

const flush_mod = zonvie_core.flush_mod;
const nvim_core = zonvie_core.nvim_core;
const Core = nvim_core.Core;
const RenderCells = flush_mod.RenderCells;
const FloatOverlayKey = flush_mod.FloatOverlayKey;
const FloatOverlayMap = flush_mod.FloatOverlayMap;

/// Create a minimal RenderCells with grid_ids set to a single value.
fn setupRenderCells(alloc: std.mem.Allocator, cols: u32, grid_id: i64) !RenderCells {
    var rc = RenderCells{};
    try rc.ensureTotalCapacity(alloc, cols);
    rc.setLen(cols);
    @memset(rc.grid_ids.items[0..cols], grid_id);
    return rc;
}

test "FloatOverlayMap last-write-wins with overlapping floats" {
    const alloc = std.testing.allocator;
    var map = FloatOverlayMap{};
    defer map.deinit(alloc);

    const vs16 = [_]u32{0xFE0F};
    const zwj = [_]u32{0x200D};

    // Float A writes VS16 at (5, 10)
    try map.put(alloc, .{ .row = 5, .col = 10 }, &vs16);
    // Float B overwrites same cell with no overflow (null = shadow)
    try map.put(alloc, .{ .row = 5, .col = 10 }, null);

    // Last write wins: null (shadowed, no overflow)
    const result = map.get(.{ .row = 5, .col = 10 });
    try std.testing.expect(result != null); // key exists
    try std.testing.expect(result.? == null); // but extras is null

    // Reverse scenario: float A has no overflow, float B has ZWJ
    try map.put(alloc, .{ .row = 6, .col = 10 }, null);
    try map.put(alloc, .{ .row = 6, .col = 10 }, &zwj);

    const result2 = map.get(.{ .row = 6, .col = 10 });
    try std.testing.expect(result2 != null);
    try std.testing.expect(result2.? != null);
    try std.testing.expectEqual(@as(u32, 0x200D), result2.?.?[0]);
}

test "FloatOverlayMap shadows base grid overflow" {
    const alloc = std.testing.allocator;
    var map = FloatOverlayMap{};
    defer map.deinit(alloc);

    // Float occupies (3, 7) without overflow → shadows base
    try map.put(alloc, .{ .row = 3, .col = 7 }, null);

    // Verify: key exists, value is null (shadow)
    try std.testing.expect(map.contains(.{ .row = 3, .col = 7 }));
    try std.testing.expect(map.get(.{ .row = 3, .col = 7 }).? == null);

    // Cell not covered by float → no entry
    try std.testing.expect(!map.contains(.{ .row = 3, .col = 8 }));
}

test "getOverflowForCell prefers float overlay over persistent map" {
    const alloc = std.testing.allocator;

    // Create a Core with test grid
    var core = Core.initForTest(alloc);
    defer core.deinitForTest();

    // Set up ext grid (id=5) with VS16 overflow at (2, 3)
    try core.grid.resizeGrid(5, 10, 80);
    core.grid.putOverflow(5, 2, 3, &[_]u32{0xFE0F});

    // Set up RenderCells with grid_id=5 (simulating ext grid row composition)
    var rc = try setupRenderCells(alloc, 80, 5);
    defer rc.deinit(alloc);

    // Without float overlay: should find base grid's VS16
    const base_result = flush_mod.getOverflowForCell(&core, &rc, 2, 3);
    try std.testing.expect(base_result != null);
    try std.testing.expectEqual(@as(u32, 0xFE0F), base_result.?[0]);

    // With float overlay that shadows (2, 3) with null (no overflow)
    var map = FloatOverlayMap{};
    defer map.deinit(alloc);
    try map.put(alloc, .{ .row = 2, .col = 3 }, null);
    core.flush_float_overlay = &map;

    // Float shadows base → should return null (NOT the base VS16)
    const shadowed = flush_mod.getOverflowForCell(&core, &rc, 2, 3);
    try std.testing.expect(shadowed == null);

    // Cell not covered by float → falls back to persistent map
    const fallback = flush_mod.getOverflowForCell(&core, &rc, 2, 4);
    try std.testing.expect(fallback == null); // no overflow at (2, 4)

    // Float with its own VS16 at (2, 5)
    const float_vs16 = [_]u32{0xFE0F};
    try map.put(alloc, .{ .row = 2, .col = 5 }, &float_vs16);

    const float_result = flush_mod.getOverflowForCell(&core, &rc, 2, 5);
    try std.testing.expect(float_result != null);
    try std.testing.expectEqual(@as(u32, 0xFE0F), float_result.?[0]);

    // Clean up
    core.flush_float_overlay = null;
}

test "cellIsEmojiCluster with float overlay" {
    const alloc = std.testing.allocator;

    var core = Core.initForTest(alloc);
    defer core.deinitForTest();

    try core.grid.resizeGrid(5, 10, 80);
    core.grid.putOverflow(5, 0, 0, &[_]u32{0xFE0F}); // base has VS16

    var rc = try setupRenderCells(alloc, 80, 5);
    defer rc.deinit(alloc);

    // Without overlay: base VS16 visible
    try std.testing.expect(flush_mod.cellIsEmojiCluster(&core, &rc, 0, 0));

    // Float shadows with no overflow
    var map = FloatOverlayMap{};
    defer map.deinit(alloc);
    try map.put(alloc, .{ .row = 0, .col = 0 }, null);
    core.flush_float_overlay = &map;

    // Shadowed: no VS16
    try std.testing.expect(!flush_mod.cellIsEmojiCluster(&core, &rc, 0, 0));

    core.flush_float_overlay = null;
}

test "cellIsEmojiCluster detects ZWJ in overflow" {
    const alloc = std.testing.allocator;

    var core = Core.initForTest(alloc);
    defer core.deinitForTest();

    try core.grid.resizeGrid(5, 10, 80);

    var rc = try setupRenderCells(alloc, 80, 5);
    defer rc.deinit(alloc);

    // ZWJ sequence: 👩‍💻 = U+1F469 + U+200D + U+1F4BB
    core.grid.putOverflow(5, 0, 0, &[_]u32{ 0x200D, 0x1F4BB });
    try std.testing.expect(flush_mod.cellIsEmojiCluster(&core, &rc, 0, 0));

    // Skin tone modifier: 👩🏽 = U+1F469 + U+1F3FD
    core.grid.putOverflow(5, 0, 1, &[_]u32{0x1F3FD});
    try std.testing.expect(flush_mod.cellIsEmojiCluster(&core, &rc, 0, 1));

    // Non-emoji combining: U+0308 (combining diaeresis) → NOT emoji
    core.grid.putOverflow(5, 0, 2, &[_]u32{0x0308});
    try std.testing.expect(!flush_mod.cellIsEmojiCluster(&core, &rc, 0, 2));

    // VS16 still works
    core.grid.putOverflow(5, 0, 3, &[_]u32{0xFE0F});
    try std.testing.expect(flush_mod.cellIsEmojiCluster(&core, &rc, 0, 3));
}

test "different ZWJ sequences get different cache keys" {
    // 👩‍💻 overflow = [U+200D, U+1F4BB]
    // 👩‍🔬 overflow = [U+200D, U+1F52C]
    const key1 = flush_mod.clusterCacheKey(0x1F469, 0, &[_]u32{ 0x200D, 0x1F4BB });
    const key2 = flush_mod.clusterCacheKey(0x1F469, 0, &[_]u32{ 0x200D, 0x1F52C });
    const key_no_overflow = flush_mod.clusterCacheKey(0x1F469, 0, null);

    try std.testing.expect(key1 != key2);
    try std.testing.expect(key1 != key_no_overflow);
    try std.testing.expect(key2 != key_no_overflow);
}
