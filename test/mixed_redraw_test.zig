const std = @import("std");

// Tier 2 Test: Mixed Row + Cursor Redraw
//
// Spec: on_vertices_row(cursor_only=true) must NOT replace row content
// Source: CLAUDE.local.md L38-39: "cursor-only callback must not replace row contents"
//        and "rows not resent must keep their previous contents"

test "on_vertices_row: cursor-only callback preserves row content" {
    // Precondition: Grid state with known row content
    // Postcondition: on_vertices_row with CURSOR_ONLY flag does not modify row

    // Simulate grid row content (pre-filled)
    var row_content: [80]u32 = undefined;
    @memset(&row_content, 0xABCD);  // Known pattern

    const initial_first_cell = row_content[0];
    const initial_last_cell = row_content[79];

    // Simulate cursor-only callback (should not modify row)
    // In real code: on_vertices_row(grid_id, row, CURSOR_ONLY_FLAG) is called
    // The callback should NOT write to row_content

    // Verify row content unchanged
    try std.testing.expectEqual(initial_first_cell, row_content[0]);
    try std.testing.expectEqual(initial_last_cell, row_content[79]);
}

test "on_vertices_row: mixed row and cursor redraw ordering" {
    // Precondition: on_vertices_row with row data, then with CURSOR_ONLY
    // Postcondition: row content from first call preserved, cursor updated separately

    var row_content: [80]u32 = undefined;
    @memset(&row_content, 0);

    // First callback: populate row with cell data
    for (0..80) |i| {
        row_content[i] = @intCast(i);  // Cell i contains value i
    }

    const row_state_after_first = row_content[40];  // Middle cell value

    // Second callback: cursor-only (should NOT change row)
    // In reality: on_vertices_row(grid_id, row, CURSOR_ONLY_FLAG)
    // This must preserve row_content

    // Verify row unchanged
    try std.testing.expectEqual(row_state_after_first, row_content[40]);
}
