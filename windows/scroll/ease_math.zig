//! Pure math and policy for per-grid shader offsets.
//!
//! This module deliberately has no platform imports.  It is used by the
//! Windows renderer later, but its contract is native-testable on every host.

const std = @import("std");
const scroll_policy = @import("settle_policy.zig");

pub const epsilon_px_default: f64 = 1.0;
pub const offset_epsilon_px: f64 = epsilon_px_default;
/// The single tunable settle-time constant for the critically damped spring.
/// At 30/s the animation settles in approximately 200 ms.
pub const spring_omega: f64 = 30.0;

pub const SpringState = struct {
    offset_px: f64,
    velocity_px_s: f64,
    final_zero_frame_pending: bool = false,
};

pub const SpringResult = struct {
    state: SpringState,
    /// True only for the one frame after a non-zero offset crossed epsilon.
    final_zero_frame: bool,
};

pub fn springTick(state: SpringState, dt_sec: f64) SpringResult {
    if (state.final_zero_frame_pending) {
        return .{
            .state = .{ .offset_px = 0.0, .velocity_px_s = 0.0 },
            .final_zero_frame = true,
        };
    }
    const dt = @max(dt_sec, 0.0);
    const a = state.velocity_px_s + spring_omega * state.offset_px;
    const factor = std.math.exp(-spring_omega * dt);
    const next_x = (state.offset_px + a * dt) * factor;
    const next_v = (state.velocity_px_s - a * spring_omega * dt) * factor;
    if (@abs(next_x) < epsilon_px_default and @abs(next_v) < spring_omega * epsilon_px_default) {
        return .{
            .state = .{ .offset_px = 0.0, .velocity_px_s = 0.0, .final_zero_frame_pending = true },
            .final_zero_frame = false,
        };
    }
    return .{ .state = .{ .offset_px = next_x, .velocity_px_s = next_v }, .final_zero_frame = false };
}

pub fn arrivalSeed(current_offset_px: f64, rows_delta: i32, row_height_px: f64, max_rows: i32) f64 {
    const next = current_offset_px + @as(f64, @floatFromInt(rows_delta)) * row_height_px;
    const limit = @as(f64, @floatFromInt(@max(max_rows, 0))) * row_height_px;
    if (@abs(next) > limit) return if (next < 0.0) -limit else limit;
    return next;
}

pub const ExternalSeedOutcome = enum { animate, skip };

pub const ExternalSeedResult = struct {
    outcome: ExternalSeedOutcome,
    sign_flipped: bool = false,
};

/// One external surface's UI-thread-owned spring state.
pub const ExternalSpringState = struct {
    offset_px: f64 = 0.0,
    velocity_px_s: f64 = 0.0,
    last_tick_qpc: i64 = 0,
    incarnation: u64 = 0,
    reset_serial: u64 = 0,

    pub fn ensureIncarnation(self: *ExternalSpringState, incarnation: u64) bool {
        if (self.incarnation == incarnation) return false;
        const next_reset_serial = self.reset_serial +% 1;
        self.* = .{ .incarnation = incarnation, .reset_serial = next_reset_serial };
        return true;
    }

    pub fn tickAt(self: *ExternalSpringState, now_qpc: i64, frequency_qpc: f64) void {
        const dt_sec: f64 = if (self.last_tick_qpc <= 0 or frequency_qpc <= 0.0)
            0.0
        else
            @as(f64, @floatFromInt(@max(now_qpc - self.last_tick_qpc, 0))) / frequency_qpc;
        self.last_tick_qpc = now_qpc;
        const tick = springTick(.{
            .offset_px = self.offset_px,
            .velocity_px_s = self.velocity_px_s,
        }, dt_sec);
        self.offset_px = tick.state.offset_px;
        self.velocity_px_s = tick.state.velocity_px_s;
    }

    pub fn seedArrivalWithPolicy(
        self: *ExternalSpringState,
        rows_delta: i32,
        row_height_px: f64,
        live_ver: i32,
        mode: scroll_policy.LargeJumpBehavior,
    ) ExternalSeedResult {
        const animated_cap_rows = @min(std.math.clamp(live_ver, 0, 32), retention_depth_rows);
        if (rows_delta == 0 or row_height_px <= 0.0 or animated_cap_rows == 0) {
            return .{ .outcome = .skip };
        }
        const decision = scroll_policy.limitRows(rows_delta, live_ver, animated_cap_rows, mode);
        if (mode == .snap and decision.animate_rows == 0) return .{ .outcome = .skip };

        const previous_offset_px = self.offset_px;
        const next_offset_px = arrivalSeed(previous_offset_px, rows_delta, row_height_px, animated_cap_rows);
        const sign_flipped = next_offset_px != 0.0 and previous_offset_px != 0.0 and
            (next_offset_px < 0.0) != (previous_offset_px < 0.0);
        if (sign_flipped) self.velocity_px_s = 0.0;
        self.offset_px = next_offset_px;
        return .{ .outcome = .animate, .sign_flipped = sign_flipped };
    }

    /// Returns whether a visible displacement was dropped.
    pub fn reset(self: *ExternalSpringState) bool {
        const was_active = self.offset_px != 0.0 or self.velocity_px_s != 0.0;
        const current_incarnation = self.incarnation;
        const next_reset_serial = self.reset_serial +% 1;
        self.* = .{ .incarnation = current_incarnation, .reset_serial = next_reset_serial };
        return was_active;
    }
};

pub const retention_depth_rows: i32 = 8;

pub const RecomposeState = struct {
    offset_active: bool,
    seeded_this_frame: bool,
    final_zero_frame_pending: bool,
    final_zero_frame: bool = false,
};

/// `shader_recompose_frame` predicate.
pub fn shader_recompose_frame(state: RecomposeState) bool {
    return state.offset_active or state.seeded_this_frame or
        state.final_zero_frame_pending or state.final_zero_frame;
}

pub const shaderRecomposeFrame = shader_recompose_frame;

/// `scrollBackTex` is legal only on the ordinary (non-recompose) path.
pub fn scrollBackTexAllowed(recompose_frame: bool) bool {
    return !recompose_frame;
}

/// Seed matrix: grid 1, reserved IDs, and external grids do not
/// seed; every other grid is admitted by this pure policy predicate.
pub fn shouldSeedGrid(grid_id: i64, external_grid: bool) bool {
    const reserved = grid_id >= -103 and grid_id <= -100;
    return !external_grid and grid_id != 1 and !reserved;
}

pub const should_seed = shouldSeedGrid;

pub const NdcBand = struct {
    local_y_px: f64,
    local_ndc_y: f64,
    offset_ndc: f64,
};

pub fn localYpx(sv_position_y_px: f64, content_viewport_top_px: f64) f64 {
    return sv_position_y_px - content_viewport_top_px;
}

pub fn localNdcY(local_y_px: f64, content_viewport_height_px: f64) f64 {
    if (content_viewport_height_px <= 0.0) return 0.0;
    return 1.0 - 2.0 * local_y_px / content_viewport_height_px;
}

pub fn offsetNdc(offset_px: f64, content_viewport_height_px: f64) f64 {
    if (content_viewport_height_px <= 0.0) return 0.0;
    return -2.0 * offset_px / content_viewport_height_px;
}

pub fn snapViewportHeightPx(viewport_height_px: f64, cell_height_px: f64) f64 {
    if (viewport_height_px <= 0.0 or cell_height_px <= 0.0) return 0.0;
    return @floor(viewport_height_px / cell_height_px) * cell_height_px;
}

pub fn ndcBand(
    sv_position_y_px: f64,
    content_viewport_top_px: f64,
    content_viewport_height_px: f64,
    offset_px: f64,
) NdcBand {
    const local_y_px = localYpx(sv_position_y_px, content_viewport_top_px);
    return .{
        .local_y_px = local_y_px,
        .local_ndc_y = localNdcY(local_y_px, content_viewport_height_px),
        .offset_ndc = offsetNdc(offset_px, content_viewport_height_px),
    };
}

pub fn rowTranslation(logical_row: i32, origin_row: i32) i32 {
    return logical_row - origin_row;
}

pub const RetentionPlan = struct {
    first_row: i32,
    count_rows: i32,
    pivot_target_row: i32,
};

/// Port of `ScrollRetention.plan` and `planRow`,
/// macos/Sources/Rendering/MetalTypes.swift:313-342.
pub fn planRetention(row_start: i32, row_end: i32, rows_delta: i32, depth_rows: i32) ?RetentionPlan {
    const moved: i32 = @intCast(@abs(rows_delta));
    if (moved <= 0 or moved >= row_end - row_start) return null;
    const count = @min(moved, depth_rows);
    if (count <= 0) return null;
    const first = if (rows_delta > 0) row_start + moved - count else row_end - moved;
    const edge_adjacent = if (rows_delta > 0) first + count - 1 else first;
    return .{ .first_row = first, .count_rows = count, .pivot_target_row = edge_adjacent - rows_delta };
}

pub fn planRetentionRow(plan: RetentionPlan, index: i32, rows_delta: i32) i32 {
    return if (rows_delta > 0)
        plan.first_row + index
    else
        plan.first_row + plan.count_rows - 1 - index;
}

pub const planRow = planRetentionRow;

/// Port of `ScrollRetention.coversBand`,
/// macos/Sources/Rendering/MetalTypes.swift:345-358.  The caller clears
/// `pin_edges` when this returns true.
pub fn coversBand(retained_rows: i32, offset_ndc: f64, cell_height_ndc: f64) bool {
    if (cell_height_ndc <= 0.0) return false;
    const band_rows = @as(i32, @intFromFloat(@ceil(@abs(offset_ndc) / cell_height_ndc - 0.001)));
    return retained_rows >= band_rows;
}

fn expectNear(actual: f64, expected: f64, tolerance: f64) !void {
    try std.testing.expect(@abs(actual - expected) <= tolerance);
}

test "spring converges and exposes one final-zero frame" {
    var state = SpringState{ .offset_px = 80.0, .velocity_px_s = 0.0 };
    var pending = false;
    for (0..240) |_| {
        const tick = springTick(state, 1.0 / 60.0);
        state = tick.state;
        if (tick.state.final_zero_frame_pending) {
            pending = true;
            break;
        }
    }
    try std.testing.expect(pending);
    try std.testing.expectEqual(@as(f64, 0.0), state.offset_px);
    const final = springTick(state, 0.0);
    try std.testing.expect(final.final_zero_frame);
    try std.testing.expect(!springTick(final.state, 0.0).final_zero_frame);
}

test "arrival seed changes offset without changing velocity" {
    const state = SpringState{ .offset_px = 4.0, .velocity_px_s = 17.0 };
    try expectNear(arrivalSeed(state.offset_px, 2, 20.0, retention_depth_rows), 44.0, 0.0);
    try expectNear(state.velocity_px_s, 17.0, 0.0);
}

test "external arrival uses raw-delta sum then live-cap clamp" {
    var state: ExternalSpringState = .{ .offset_px = -60.0, .velocity_px_s = 17.0, .incarnation = 4 };
    const result = state.seedArrivalWithPolicy(20, 20.0, 3, .partial);
    try std.testing.expectEqual(ExternalSeedOutcome.animate, result.outcome);
    try expectNear(state.offset_px, 60.0, 0.0);
    try std.testing.expect(result.sign_flipped);
    try expectNear(state.velocity_px_s, 0.0, 0.0);
}

test "external snap gate skips a record beyond the live threshold" {
    var state: ExternalSpringState = .{ .offset_px = 20.0, .velocity_px_s = -30.0 };
    const result = state.seedArrivalWithPolicy(4, 20.0, 3, .snap);
    try std.testing.expectEqual(ExternalSeedOutcome.skip, result.outcome);
    try expectNear(state.offset_px, 20.0, 0.0);
    try expectNear(state.velocity_px_s, -30.0, 0.0);
}

test "external live version caps animated offset" {
    var state: ExternalSpringState = .{};
    const result = state.seedArrivalWithPolicy(9, 20.0, 3, .partial);
    try std.testing.expectEqual(ExternalSeedOutcome.animate, result.outcome);
    try std.testing.expectEqual(@as(f64, 60.0), state.offset_px);
}

test "external QPC tick uses monotonic elapsed time" {
    var state: ExternalSpringState = .{ .offset_px = 80.0, .last_tick_qpc = 1_000 };
    var expected = springTick(.{ .offset_px = 80.0, .velocity_px_s = 0.0 }, 0.25).state;
    state.tickAt(1_250, 1_000.0);
    try expectNear(state.offset_px, expected.offset_px, 1e-12);
    try expectNear(state.velocity_px_s, expected.velocity_px_s, 1e-12);
    expected = springTick(.{ .offset_px = state.offset_px, .velocity_px_s = state.velocity_px_s }, 0.0).state;
    state.tickAt(1_200, 1_000.0);
    try expectNear(state.offset_px, expected.offset_px, 1e-12);
}

test "external reset drops spring timing and preserves incarnation" {
    var state: ExternalSpringState = .{
        .offset_px = 42.0,
        .velocity_px_s = -90.0,
        .last_tick_qpc = 300,
        .incarnation = 7,
    };
    try std.testing.expect(state.reset());
    try expectNear(state.offset_px, 0.0, 0.0);
    try expectNear(state.velocity_px_s, 0.0, 0.0);
    try std.testing.expectEqual(@as(i64, 0), state.last_tick_qpc);
    try std.testing.expectEqual(@as(u64, 7), state.incarnation);
    try std.testing.expectEqual(@as(u64, 1), state.reset_serial);
    try std.testing.expect(!state.reset());
    try std.testing.expect(state.ensureIncarnation(8));
    try std.testing.expectEqual(@as(u64, 8), state.incarnation);
    try std.testing.expectEqual(@as(u64, 3), state.reset_serial);
}

test "spring is rate independent" {
    var split = SpringState{ .offset_px = 64.0, .velocity_px_s = -11.0 };
    var full = split;
    for (0..2) |_| split = springTick(split, 0.01).state;
    full = springTick(full, 0.02).state;
    try expectNear(split.offset_px, full.offset_px, 1e-9);
    try expectNear(split.velocity_px_s, full.velocity_px_s, 1e-9);
}

test "arrival seed clamps partial snap" {
    try expectNear(arrivalSeed(0.0, 20, 20.0, retention_depth_rows), 160.0, 0.0);
}

test "constant cadence arrivals keep displacement ripple bounded" {
    var state = SpringState{ .offset_px = 0.0, .velocity_px_s = 0.0 };
    var previous: f64 = 0.0;
    for (0..180) |tick_index| {
        if (tick_index % 6 == 0 and tick_index / 6 < 30) {
            state.offset_px = arrivalSeed(state.offset_px, 1, 20.0, retention_depth_rows);
        }
        const next = springTick(state, 1.0 / 60.0);
        state = next.state;
        if (tick_index > 12) try std.testing.expect(@abs(state.offset_px - previous) <= 20.0);
        previous = state.offset_px;
    }
}

test "seed matrix excludes grid one reserved ids and external grids" {
    try std.testing.expect(!shouldSeedGrid(1, false));
    try std.testing.expect(!shouldSeedGrid(-100, false));
    try std.testing.expect(!shouldSeedGrid(-103, false));
    try std.testing.expect(!shouldSeedGrid(2, true));
    try std.testing.expect(shouldSeedGrid(2, false));
    try std.testing.expect(shouldSeedGrid(0, false));
}

test "NDC band includes tab-bar viewport origin and snapped height" {
    const height = snapViewportHeightPx(901.0, 20.0);
    try expectNear(height, 900.0, 0.0);
    const band = ndcBand(150.0, 100.0, height, 20.0);
    try expectNear(band.local_y_px, 50.0, 0.0);
    try expectNear(band.local_ndc_y, 1.0 - 100.0 / 900.0, 0.000001);
    try expectNear(band.offset_ndc, -40.0 / 900.0, 0.000001);
}

test "row translation is logical row minus origin row" {
    try std.testing.expectEqual(@as(i32, -2), rowTranslation(3, 5));
    try std.testing.expectEqual(@as(i32, 4), rowTranslation(7, 3));
}

test "retention depth plan and row order match macOS" {
    try std.testing.expectEqual(@as(i32, 8), retention_depth_rows);
    const plan = planRetention(0, 10, 3, 2) orelse return error.ExpectedPlan;
    try std.testing.expectEqual(@as(i32, 1), plan.first_row);
    try std.testing.expectEqual(@as(i32, 2), plan.count_rows);
    try std.testing.expectEqual(@as(i32, -1), plan.pivot_target_row);
    try std.testing.expectEqual(@as(i32, 1), planRetentionRow(plan, 0, 3));
    try std.testing.expectEqual(@as(i32, 2), planRetentionRow(plan, 1, 3));
    const reverse = planRetention(0, 10, -2, 4) orelse return error.ExpectedReversePlan;
    try std.testing.expectEqual(@as(i32, 8), reverse.first_row);
    try std.testing.expectEqual(@as(i32, 9), planRetentionRow(reverse, 0, -2));
    try std.testing.expectEqual(@as(i32, 8), planRetentionRow(reverse, 1, -2));
    try std.testing.expect(planRetention(0, 3, 3, 2) == null);
}

test "coversBand clears pin edges only when the complete band is retained" {
    try std.testing.expect(coversBand(2, 0.99, 0.5));
    try std.testing.expect(!coversBand(1, 0.99, 0.5));
    try std.testing.expect(!coversBand(2, 1.0, 0.0));
}

test "shader recompose predicate covers active seed and final frame" {
    try std.testing.expect(shader_recompose_frame(.{ .offset_active = true, .seeded_this_frame = false, .final_zero_frame_pending = false }));
    try std.testing.expect(shader_recompose_frame(.{ .offset_active = false, .seeded_this_frame = true, .final_zero_frame_pending = false }));
    try std.testing.expect(shader_recompose_frame(.{ .offset_active = false, .seeded_this_frame = false, .final_zero_frame_pending = true }));
    try std.testing.expect(!shader_recompose_frame(.{ .offset_active = false, .seeded_this_frame = false, .final_zero_frame_pending = false }));
    try std.testing.expect(!scrollBackTexAllowed(true));
    try std.testing.expect(scrollBackTexAllowed(false));
}
