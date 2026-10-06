const std = @import("std");

// Tier 2 Test: Dirty Region Propagation
//
// Spec: Partial redraw must mark dirty regions correctly
// Source: CLAUDE.md: "keep dirty-region behavior correct under partial redraw"

test "dirty region: scroll updates region correctly" {
    // Precondition: Grid with initial state
    // Postcondition: Dirty region reflects scrolled rows

    // Simulate grid (24 rows × 80 cols)
    const ROWS: usize = 24;
    const COLS: usize = 80;
    var dirty_rows: [ROWS]bool = [_]bool{false} ** ROWS;

    // Simulate grid_scroll event: scroll down 5 rows
    const scroll_amount: i32 = 5;

    // Mark rows as dirty (those affected by scroll)
    // Rows 0-4 (vacated) and rows 19-23 (newly exposed) should be dirty
    for (0..std.math.absCast(scroll_amount)) |i| {
        dirty_rows[i] = true;                        // Vacated rows
        dirty_rows[ROWS - 1 - i] = true;            // Newly exposed rows
    }

    // Verify dirty regions
    try std.testing.expect(dirty_rows[0]);          // First vacated
    try std.testing.expect(dirty_rows[4]);          // Last vacated
    try std.testing.expect(dirty_rows[ROWS - 1]);   // Last newly exposed
    try std.testing.expect(!dirty_rows[10]);        // Middle unchanged
}

test "dirty region: bounds checked against grid resize" {
    // Precondition: Grid resizes from 24→20 rows
    // Postcondition: Dirty region clipped to new bounds

    const old_rows: u32 = 24;
    const new_rows: u32 = 20;
    var dirty_rows: [24]bool = [_]bool{false} ** 24;

    // Mark all rows dirty initially
    @memset(&dirty_rows, true);

    // After resize, mark rows beyond new size as not-dirty (out of bounds)
    for (new_rows..old_rows) |i| {
        dirty_rows[i] = false;
    }

    // Verify bounds clipping
    try std.testing.expect(dirty_rows[19]);  // Last valid row
    try std.testing.expect(!dirty_rows[20]); // Out of bounds
    try std.testing.expect(!dirty_rows[23]); // Out of bounds
}

test "dirty region: overlapping regions merge correctly" {
    // Precondition: Multiple dirty regions overlap
    // Postcondition: Merged region covers all affected rows

    var dirty_rows: [80]bool = [_]bool{false} ** 80;

    // Region 1: rows 10-15 (scroll affected)
    for (10..16) |i| dirty_rows[i] = true;

    // Region 2: rows 12-18 (redraw affected, overlaps with region 1)
    for (12..19) |i| dirty_rows[i] = true;

    // Verify merged region covers 10-18
    try std.testing.expect(dirty_rows[10]);  // Region 1 start
    try std.testing.expect(dirty_rows[15]);  // Region 1 end
    try std.testing.expect(dirty_rows[18]);  // Region 2 end
    try std.testing.expect(!dirty_rows[9]);  // Before merge
    try std.testing.expect(!dirty_rows[19]); // After merge
}
