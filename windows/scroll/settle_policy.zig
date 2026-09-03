//! Pure row-limit policy shared by external and main displacement easing.

const std = @import("std");

pub const LargeJumpBehavior = enum {
    partial,
    snap,
};

pub const RowLimitDecision = struct {
    animate_rows: i64,
    snap_rows: i64,
};

pub const LargeJumpBehaviorConfig = struct {
    behavior: LargeJumpBehavior = .partial,
    invalid: bool = false,
};

fn exceedsMagnitude(value: i64, limit: i64) bool {
    if (value >= 0) return value > limit;
    return value < -limit;
}

fn clampRows(value: i64, cap: i64) i64 {
    if (value >= 0) return @min(value, cap);
    return @max(value, -cap);
}

/// Animated arrival clamp shared by the main ledger and the external spring:
/// the live 'mousescroll' ver bounded below by zero and above by the
/// retention depth. Distinct from limitRows' snap threshold, which follows
/// ver beyond the depth.
pub fn animatedCapRows(live_ver: i32, retention_depth_rows: i32) i32 {
    return std.math.clamp(live_ver, 0, retention_depth_rows);
}

/// Split a flush-aggregated row batch into its animated and already-presented
/// portions. Bounds are small signed values, so the negative minInt case never
/// needs an overflowing absolute-value operation.
pub fn limitRows(rows_delta: i64, live_ver: i32, cap: i32, mode: LargeJumpBehavior) RowLimitDecision {
    const threshold: i64 = @intCast(std.math.clamp(live_ver, 0, 32));
    const animated_cap: i64 = @intCast(@max(cap, 0));
    if (mode == .snap and exceedsMagnitude(rows_delta, threshold)) {
        return .{ .animate_rows = 0, .snap_rows = rows_delta };
    }
    const animate_rows = clampRows(rows_delta, animated_cap);
    return .{ .animate_rows = animate_rows, .snap_rows = rows_delta - animate_rows };
}

/// Map the already-parsed [scroll].large_jump_behavior config string to the
/// policy enum. Unknown values fall back to partial and are flagged invalid.
pub fn parseBehaviorString(value: []const u8) LargeJumpBehaviorConfig {
    if (std.mem.eql(u8, value, "partial")) return .{ .behavior = .partial, .invalid = false };
    if (std.mem.eql(u8, value, "snap")) return .{ .behavior = .snap, .invalid = false };
    return .{ .behavior = .partial, .invalid = true };
}

test "partial policy handles zero, signs, and cap boundaries" {
    try std.testing.expectEqual(RowLimitDecision{ .animate_rows = 0, .snap_rows = 0 }, limitRows(0, 3, 3, .partial));
    try std.testing.expectEqual(RowLimitDecision{ .animate_rows = 3, .snap_rows = 0 }, limitRows(3, 3, 3, .partial));
    try std.testing.expectEqual(RowLimitDecision{ .animate_rows = -3, .snap_rows = 0 }, limitRows(-3, 3, 3, .partial));
    try std.testing.expectEqual(RowLimitDecision{ .animate_rows = 3, .snap_rows = 1 }, limitRows(4, 3, 3, .partial));
    try std.testing.expectEqual(RowLimitDecision{ .animate_rows = -3, .snap_rows = -1 }, limitRows(-4, 3, 3, .partial));
}

test "snap policy uses the live threshold" {
    try std.testing.expectEqual(RowLimitDecision{ .animate_rows = 3, .snap_rows = 0 }, limitRows(3, 3, 8, .snap));
    try std.testing.expectEqual(RowLimitDecision{ .animate_rows = -3, .snap_rows = 0 }, limitRows(-3, 3, 8, .snap));
    try std.testing.expectEqual(RowLimitDecision{ .animate_rows = 0, .snap_rows = 4 }, limitRows(4, 3, 8, .snap));
    try std.testing.expectEqual(RowLimitDecision{ .animate_rows = 0, .snap_rows = -4 }, limitRows(-4, 3, 8, .snap));
}

test "row limit handles i64 minimum and maximum without overflow" {
    const min_value = std.math.minInt(i64);
    const max_value = std.math.maxInt(i64);
    try std.testing.expectEqual(RowLimitDecision{ .animate_rows = -3, .snap_rows = min_value + 3 }, limitRows(min_value, 3, 3, .partial));
    try std.testing.expectEqual(RowLimitDecision{ .animate_rows = 3, .snap_rows = max_value - 3 }, limitRows(max_value, 3, 3, .partial));
}

test "snap mode with zero threshold snaps every nonzero batch" {
    try std.testing.expectEqual(RowLimitDecision{ .animate_rows = 0, .snap_rows = -1 }, limitRows(-1, 0, 8, .snap));
    try std.testing.expectEqual(RowLimitDecision{ .animate_rows = 0, .snap_rows = 0 }, limitRows(0, 0, 8, .snap));
}

test "ver zero leaves only the zero batch animatable" {
    try std.testing.expectEqual(RowLimitDecision{ .animate_rows = 0, .snap_rows = 1 }, limitRows(1, 0, 8, .snap));
    try std.testing.expectEqual(RowLimitDecision{ .animate_rows = 0, .snap_rows = -1 }, limitRows(-1, 0, 8, .snap));
    try std.testing.expectEqual(RowLimitDecision{ .animate_rows = 0, .snap_rows = 1 }, limitRows(1, 0, 0, .partial));
    try std.testing.expectEqual(RowLimitDecision{ .animate_rows = 0, .snap_rows = -1 }, limitRows(-1, 0, 0, .partial));
}

test "behavior string accepts valid values and flags the rest" {
    try std.testing.expectEqual(LargeJumpBehaviorConfig{ .behavior = .partial, .invalid = false }, parseBehaviorString("partial"));
    try std.testing.expectEqual(LargeJumpBehaviorConfig{ .behavior = .snap, .invalid = false }, parseBehaviorString("snap"));
    try std.testing.expectEqual(LargeJumpBehaviorConfig{ .behavior = .partial, .invalid = true }, parseBehaviorString("unexpected"));
    try std.testing.expectEqual(LargeJumpBehaviorConfig{ .behavior = .partial, .invalid = true }, parseBehaviorString(""));
}
