//! Top-origin displacement and retention-ring bookkeeping for external frames.
//!
//! `source_y = destination_y - offset_px`; positive offsets display content
//! lower and therefore read retained pixels from the top edge.

const std = @import("std");

pub const RetentionDepth: u32 = 8;

pub fn sourceY(dst_y_px: f64, offset_px: f64) f64 {
    return dst_y_px - offset_px;
}

pub const BandEdge = enum { top, bottom };

pub fn vacatedEdge(offset_px: f64) ?BandEdge {
    if (offset_px > 0.0) return .top;
    if (offset_px < 0.0) return .bottom;
    return null;
}

pub fn bandRows(offset_rows: f64, depth_rows: u32) u32 {
    const magnitude = @abs(offset_rows);
    return @intFromFloat(@min(@as(f64, @floatFromInt(depth_rows)), @ceil(magnitude)));
}

pub fn minimumRowsForOffset(offset_px: f64, row_height_px: f64, depth_rows: u32) u32 {
    if (row_height_px <= 0.0 or offset_px == 0.0) return 0;
    return bandRows(offset_px / row_height_px, depth_rows);
}

pub fn trimRowsPreservingMinimum(retained_rows: u32, reduction_rows: u32, minimum_rows: u32) u32 {
    if (retained_rows <= minimum_rows) return 0;
    return @min(reduction_rows, retained_rows - minimum_rows);
}

pub fn plannedBatchRows(snapshot_shift_rows: i64, animated_seed_rows: i64, prior_offset_px: f64) i64 {
    const skipped_opposite = snapshot_shift_rows != 0 and prior_offset_px != 0.0 and
        (snapshot_shift_rows > 0) != (prior_offset_px > 0.0) and animated_seed_rows == 0;
    if (snapshot_shift_rows != 0 and !skipped_opposite) return snapshot_shift_rows;
    return animated_seed_rows;
}

pub fn shouldSkipPureEaseFrame(
    offset_nonzero: bool,
    pending_scroll_records: bool,
    dirty_rows: bool,
    atlas_work: bool,
    other_damage: bool,
) bool {
    return offset_nonzero and !pending_scroll_records and !dirty_rows and !atlas_work and !other_damage;
}

pub fn retentionRowCoordinate(src_y_rows: f64, viewport_height_rows: f64, rows_stored: u32) ?u32 {
    if (rows_stored == 0 or viewport_height_rows <= 0.0) return null;
    if (src_y_rows >= 0.0 and src_y_rows < viewport_height_rows) return null;
    if (src_y_rows < 0.0) {
        const coordinate = @as(f64, @floatFromInt(rows_stored)) + src_y_rows;
        return @intFromFloat(@floor(std.math.clamp(coordinate, 0.0, @as(f64, @floatFromInt(rows_stored - 1)))));
    }
    const coordinate = src_y_rows - viewport_height_rows;
    return @intFromFloat(@floor(std.math.clamp(coordinate, 0.0, @as(f64, @floatFromInt(rows_stored - 1)))));
}

pub fn physicalRetentionRow(origin: u32, logical_row: u32) u32 {
    return (origin + logical_row) % RetentionDepth;
}

pub const RingMetadata = struct {
    // Top captures are stored far-to-adjacent in screen row order. Bottom
    // captures are stored adjacent-to-far, so both edges can add new rows at
    // the content boundary without reversing pixels inside a captured row.
    rows_stored: u32 = 0,
    physical_origin: u32 = 0,
    edge: ?BandEdge = null,
    append_count: u64 = 0,
    evict_count: u64 = 0,

    pub fn append(self: *RingMetadata, rows: u32, edge: BandEdge) u32 {
        const accepted = @min(rows, RetentionDepth);
        if (self.edge != null and self.edge.? != edge) self.discardAll();
        self.edge = edge;
        const evicted = if (self.rows_stored + accepted > RetentionDepth)
            self.rows_stored + accepted - RetentionDepth
        else
            0;
        if (edge == .top) {
            self.physical_origin = (self.physical_origin + evicted) % RetentionDepth;
        } else {
            self.physical_origin = (self.physical_origin + RetentionDepth - accepted % RetentionDepth) % RetentionDepth;
        }
        self.rows_stored = self.rows_stored + accepted - evicted;
        self.append_count += accepted;
        self.evict_count += evicted;
        return evicted;
    }

    pub fn discardAll(self: *RingMetadata) void {
        self.rows_stored = 0;
        self.physical_origin = 0;
        self.edge = null;
    }

    pub fn trimAdjacent(self: *RingMetadata, rows: u32) u32 {
        const removed = @min(rows, self.rows_stored);
        if (removed == 0) return 0;
        if (self.edge) |edge| {
            if (edge == .bottom) {
                self.physical_origin = (self.physical_origin + removed) % RetentionDepth;
            }
        }
        self.rows_stored -= removed;
        if (self.rows_stored == 0) {
            self.physical_origin = 0;
            self.edge = null;
        }
        return removed;
    }
};

test "contract B sign and band convention" {
    try std.testing.expectEqual(@as(f64, 7.25), sourceY(10.0, 2.75));
    try std.testing.expectEqual(BandEdge.top, vacatedEdge(0.01).?);
    try std.testing.expectEqual(BandEdge.bottom, vacatedEdge(-0.01).?);
    try std.testing.expectEqual(@as(u32, 3), bandRows(2.01, RetentionDepth));
    try std.testing.expectEqual(@as(u32, 8), bandRows(-99.0, RetentionDepth));
    try std.testing.expect(vacatedEdge(0) == null);
    try std.testing.expectEqual(@as(u32, 7), retentionRowCoordinate(-0.25, 100.0, 8).?);
    try std.testing.expectEqual(@as(u32, 6), retentionRowCoordinate(-1.25, 100.0, 8).?);
    try std.testing.expectEqual(@as(u32, 5), retentionRowCoordinate(-2.25, 100.0, 8).?);
    try std.testing.expectEqual(@as(u32, 0), retentionRowCoordinate(100.25, 100.0, 8).?);
    try std.testing.expectEqual(@as(u32, 7), retentionRowCoordinate(140.0, 100.0, 8).?);
    try std.testing.expect(retentionRowCoordinate(50.5, 100.0, 8) == null);
    try std.testing.expect(retentionRowCoordinate(-0.25, 100.0, 0) == null);
}

test "retention ring append, eviction, and discard" {
    var ring = RingMetadata{};
    try std.testing.expectEqual(@as(u32, 0), ring.append(3, .top));
    try std.testing.expectEqual(@as(u32, 3), ring.rows_stored);
    try std.testing.expectEqual(@as(u32, 3), ring.append(8, .top));
    try std.testing.expectEqual(@as(u32, RetentionDepth), ring.rows_stored);
    try std.testing.expectEqual(@as(u64, 11), ring.append_count);
    try std.testing.expectEqual(@as(u64, 3), ring.evict_count);
    try std.testing.expectEqual(@as(u32, 3), ring.physical_origin);
    try std.testing.expectEqual(@as(u32, 2), physicalRetentionRow(ring.physical_origin, 7));
    ring.discardAll();
    try std.testing.expectEqual(@as(u32, 0), ring.rows_stored);
    try std.testing.expectEqual(@as(u32, 0), ring.physical_origin);
    try std.testing.expectEqual(@as(u32, 0), ring.append(99, .bottom));
    try std.testing.expectEqual(@as(u32, RetentionDepth), ring.rows_stored);
    try std.testing.expectEqual(BandEdge.bottom, ring.edge.?);
}

test "bottom-edge captures prepend and evict at the far edge" {
    var ring: RingMetadata = .{};
    _ = ring.append(3, .bottom);
    try std.testing.expectEqual(@as(u32, 5), ring.physical_origin);
    _ = ring.append(2, .bottom);
    try std.testing.expectEqual(@as(u32, 3), ring.physical_origin);
    try std.testing.expectEqual(@as(u32, 5), ring.rows_stored);
    try std.testing.expectEqual(@as(u32, 3), physicalRetentionRow(ring.physical_origin, 0));
    try std.testing.expectEqual(@as(u32, 7), physicalRetentionRow(ring.physical_origin, 4));
    try std.testing.expectEqual(@as(u32, 3), ring.append(6, .bottom));
    try std.testing.expectEqual(@as(u32, 5), ring.physical_origin);
    try std.testing.expectEqual(@as(u32, 8), ring.rows_stored);
}

test "changing capture edge discards before recapture" {
    var ring: RingMetadata = .{};
    _ = ring.append(4, .top);
    _ = ring.append(2, .bottom);
    try std.testing.expectEqual(BandEdge.bottom, ring.edge.?);
    try std.testing.expectEqual(@as(u32, 2), ring.rows_stored);
    try std.testing.expectEqual(@as(u32, 6), ring.physical_origin);
}

test "opposite arrivals trim the content-adjacent end" {
    var top: RingMetadata = .{};
    _ = top.append(5, .top);
    try std.testing.expectEqual(@as(u32, 2), top.trimAdjacent(2));
    try std.testing.expectEqual(@as(u32, 3), top.rows_stored);
    try std.testing.expectEqual(@as(u32, 0), top.physical_origin);

    var bottom: RingMetadata = .{};
    _ = bottom.append(5, .bottom);
    try std.testing.expectEqual(@as(u32, 2), bottom.trimAdjacent(2));
    try std.testing.expectEqual(@as(u32, 3), bottom.rows_stored);
    try std.testing.expectEqual(@as(u32, 5), bottom.physical_origin);
}

test "nonzero offset retention minimum is never exceeded by trimming" {
    const minimum = minimumRowsForOffset(60.0, 20.0, RetentionDepth);
    try std.testing.expectEqual(@as(u32, 3), minimum);
    const trimmed = trimRowsPreservingMinimum(8, 8, minimum);
    try std.testing.expectEqual(@as(u32, 5), trimmed);
    try std.testing.expect(8 - trimmed >= minimum);
}

test "skipped reverse record does not plan retention mutation" {
    var ring = RingMetadata{};
    _ = ring.append(3, .top);
    const before = ring;
    const offset_px = 60.0;
    const plan = plannedBatchRows(-4, 0, offset_px);
    if (plan != 0) _ = ring.trimAdjacent(@intCast(@abs(plan)));
    try std.testing.expectEqual(@as(i64, 0), plan);
    try std.testing.expectEqualDeep(before, ring);
    try std.testing.expect(offset_px != 0.0);
    try std.testing.expectEqual(@as(i64, 3), plannedBatchRows(3, 0, 60.0));
}

test "pure ease skip requires every damage source to be absent" {
    try std.testing.expect(shouldSkipPureEaseFrame(true, false, false, false, false));
    try std.testing.expect(!shouldSkipPureEaseFrame(false, false, false, false, false));
    try std.testing.expect(!shouldSkipPureEaseFrame(true, true, false, false, false));
    try std.testing.expect(!shouldSkipPureEaseFrame(true, false, true, false, false));
    try std.testing.expect(!shouldSkipPureEaseFrame(true, false, false, true, false));
    try std.testing.expect(!shouldSkipPureEaseFrame(true, false, false, false, true));
}
