//! Pure policy helpers for Contract A2's presentation-time decisions.

const std = @import("std");
const math = @import("settle_math.zig");

pub const BeginTime = struct {
    begin_qpc: i64,
    frequency_qpc: f64,
    stats_valid: bool,
};

pub const AggregateDecision = enum {
    settle,
    event_limit,
    accumulated_limit,
};

/// Sum the rows drained from one A2 publication ring.  The caller owns the
/// ring and performs the lock/pop; this helper is deliberately allocation-free
/// so the drain policy can be tested without Win32 or live COM.
pub fn aggregateRows(rows: []const i32) i64 {
    var total: i64 = 0;
    for (rows) |delta| total += delta;
    return total;
}

/// Apply the same per-event and sampled-offset limits used by the presenter
/// after one or more ring records have been aggregated into one delta.
pub fn decideAggregatedRows(rows_delta: i64, row_height_px: f64, sampled_offset_px: f64) AggregateDecision {
    if (@abs(rows_delta) > @as(i64, math.settle_limit_rows_default) or
        rows_delta < @as(i64, std.math.minInt(i32)) or rows_delta > @as(i64, std.math.maxInt(i32)))
        return .event_limit;
    return switch (math.decideTrip(
        @intCast(rows_delta),
        row_height_px,
        sampled_offset_px,
        math.settle_limit_rows_default,
        math.settle_max_rows_default * row_height_px,
    )) {
        .settle => .settle,
        .trip => .accumulated_limit,
    };
}

/// A1 owns the handoff window; A2 may resume as soon as that owner flag clears.
pub fn a2RetargetAllowed(a1_active: bool) bool {
    return !a1_active;
}

/// Select the frame-statistics time base when it is usable, otherwise retain
/// the caller's QPC clock and current time. This deliberately carries no COM
/// types so the fallback contract can be tested on the native host.
pub fn resolveBeginTime(
    get_statistics_succeeded: bool,
    statistics_frequency_qpc: i64,
    next_estimated_frame_qpc: i64,
    fallback_now_qpc: i64,
    fallback_frequency_qpc: f64,
) BeginTime {
    const valid = get_statistics_succeeded and statistics_frequency_qpc > 0 and next_estimated_frame_qpc > 0;
    if (valid) {
        return .{
            .begin_qpc = next_estimated_frame_qpc,
            .frequency_qpc = @floatFromInt(statistics_frequency_qpc),
            .stats_valid = true,
        };
    }
    return .{
        .begin_qpc = fallback_now_qpc,
        .frequency_qpc = fallback_frequency_qpc,
        .stats_valid = false,
    };
}

test "resolveBeginTime uses valid frame statistics" {
    const resolved = resolveBeginTime(true, 10_000_000, 42_000, 7_000, 9_000_000.0);
    try std.testing.expect(resolved.stats_valid);
    try std.testing.expectEqual(@as(i64, 42_000), resolved.begin_qpc);
    try std.testing.expectEqual(@as(f64, 10_000_000.0), resolved.frequency_qpc);
}

test "resolveBeginTime falls back for invalid frame statistics" {
    const resolved = resolveBeginTime(true, 0, 42_000, 7_000, 9_000_000.0);
    try std.testing.expect(!resolved.stats_valid);
    try std.testing.expectEqual(@as(i64, 7_000), resolved.begin_qpc);
    try std.testing.expectEqual(@as(f64, 9_000_000.0), resolved.frequency_qpc);
}

test "resolveBeginTime falls back when statistics query fails" {
    const resolved = resolveBeginTime(false, 10_000_000, 42_000, 7_000, 9_000_000.0);
    try std.testing.expect(!resolved.stats_valid);
    try std.testing.expectEqual(@as(i64, 7_000), resolved.begin_qpc);
    try std.testing.expectEqual(@as(f64, 9_000_000.0), resolved.frequency_qpc);
}

test "aggregateRows drains a flush batch before applying one trip decision" {
    const rows = [_]i32{ 1, 1, 1, 1 };
    const total = aggregateRows(&rows);
    try std.testing.expectEqual(@as(i64, 4), total);
    try std.testing.expectEqual(AggregateDecision.event_limit, decideAggregatedRows(total, 20.0, 0.0));
}

test "old settle plus large jump trips the accumulated limit" {
    try std.testing.expectEqual(AggregateDecision.accumulated_limit, decideAggregatedRows(1, 20.0, 60.0));
}

test "A1 suppression resumes after the active flag clears" {
    try std.testing.expect(!a2RetargetAllowed(true));
    try std.testing.expect(a2RetargetAllowed(false));
}
