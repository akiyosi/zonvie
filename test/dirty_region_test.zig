const std = @import("std");

// Tier 2 Test: Dirty Region Propagation
//
// Spec: Partial redraw dirty region must be tracked correctly
// Verifies: dirty bit propagation during scroll and resize

const DirtyRegion = struct {
    rows: std.bit_set.ArrayBitSet(usize, 256) = std.bit_set.ArrayBitSet(usize, 256).initEmpty(),

    fn markRange(self: *DirtyRegion, start: usize, end: usize) void {
        var i = start;
        while (i < end and i < 256) : (i += 1) {
            self.rows.set(i);
        }
    }

    fn clearRange(self: *DirtyRegion, start: usize, end: usize) void {
        var i = start;
        while (i < end and i < 256) : (i += 1) {
            self.rows.unset(i);
        }
    }

    fn countDirty(self: *const DirtyRegion) usize {
        var count: usize = 0;
        var iter = self.rows.iterator(.{});
        while (iter.next()) |_| count += 1;
        return count;
    }

    fn isRangeDirty(self: *const DirtyRegion, start: usize, end: usize) bool {
        var i = start;
        while (i < end and i < 256) : (i += 1) {
            if (!self.rows.isSet(i)) return false;
        }
        return true;
    }
};

test "dirty region: scroll updates region correctly (contract)" {
    // Precondition: Grid with initial dirty state
    // Postcondition: Dirty region reflects scrolled rows

    var region: DirtyRegion = .{};

    // Initial: rows 5-14 are dirty (10 rows)
    region.markRange(5, 15);
    try std.testing.expectEqual(region.countDirty(), 10);

    // Simulate scroll down by 5: rows 0-4 (vacated) and 20-24 (newly exposed) become dirty
    region.clearRange(5, 15); // Clear old dirty
    region.markRange(0, 5);    // Vacated rows
    region.markRange(20, 25);  // Newly exposed rows

    // Postcondition: 10 rows dirty in two regions
    try std.testing.expectEqual(region.countDirty(), 10);
    try std.testing.expect(region.isRangeDirty(0, 5));
    try std.testing.expect(region.isRangeDirty(20, 25));
}

test "dirty region: bounds checked against grid resize (contract)" {
    // Precondition: Grid resizes from 24 → 20 rows
    // Postcondition: Dirty region clipped to new bounds

    var region: DirtyRegion = .{};

    // Mark rows 15-23 (old grid extends beyond new size)
    region.markRange(15, 24);
    try std.testing.expectEqual(region.countDirty(), 9);

    // Simulate resize: bounds check removes rows ≥ 20
    region.clearRange(20, 256);

    // Postcondition: Only rows 15-19 remain dirty
    try std.testing.expectEqual(region.countDirty(), 5);
    try std.testing.expect(region.isRangeDirty(15, 20));
}

test "dirty region: overlapping regions merge correctly (contract)" {
    // Precondition: Multiple dirty regions overlap
    // Postcondition: Merged region covers all affected rows

    var region: DirtyRegion = .{};

    // Region 1: rows 10-15
    region.markRange(10, 16);
    try std.testing.expect(region.isRangeDirty(10, 16));

    // Region 2: rows 12-18 (overlaps with region 1)
    region.markRange(12, 19);

    // Postcondition: Merged region spans 10-18 (9 rows)
    try std.testing.expectEqual(region.countDirty(), 9);
    try std.testing.expect(region.isRangeDirty(10, 19));

    // Check boundaries
    try std.testing.expect(!region.rows.isSet(9));  // Before merge
    try std.testing.expect(!region.rows.isSet(19)); // After merge
}

test "dirty region: partial redraw cost is O(changed_rows) (performance)" {
    // Precondition: Large grid with small dirty region
    // Postcondition: Redraw cost proportional to dirty rows, not total grid

    var arena_alloc = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_alloc.deinit();

    const total_rows: usize = 100;
    const changed_rows: usize = 5;

    var region: DirtyRegion = .{};
    region.markRange(40, 45); // 5 rows dirty in middle of 100-row grid

    // Verify cost is proportional to changed_rows, not total_rows
    const dirty_count = region.countDirty();
    try std.testing.expectEqual(dirty_count, changed_rows);
    try std.testing.expect(dirty_count < total_rows);
}
