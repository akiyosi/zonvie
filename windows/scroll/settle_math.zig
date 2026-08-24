//! Platform-independent math for Contract A2 discrete settle animations.
//!
//! The coefficients in SettleAnimationState are the f32 values submitted to
//! DirectComposition. Analytic replay intentionally evaluates those values,
//! rather than retaining a separate f64 ideal curve.

const std = @import("std");

pub const settle_limit_rows_default: i32 = 3;
pub const settle_max_rows_default: f64 = 3.0;
pub const settle_duration_ms: u32 = 120;
pub const settle_duration_min_ms: u32 = 60;
pub const settle_duration_max_ms: u32 = 200;

pub const settle_duration_sec: f64 = @as(f64, @floatFromInt(settle_duration_ms)) / 1000.0;

/// The f32 cubic sent to IDCompositionAnimation, together with its time base.
pub const SettleAnimationState = struct {
    begin_time_qpc: i64,
    duration_sec: f64,
    coeff_constant_f32: f32,
    coeff_linear_f32: f32,
    coeff_quadratic_f32: f32,
    coeff_cubic_f32: f32,
};

pub const SettleSample = struct {
    position_px: f64,
    velocity_px_per_sec: f64,
};

pub const TripDecision = union(enum) {
    settle: f64,
    trip: void,
};

/// Compute the cubic coefficients from the four pinned boundary conditions.
/// Inputs and intermediate values are f64; only the submitted coefficients are
/// rounded to f32.
pub fn init(begin_time_qpc: i64, x0_px: f64, v0_px_per_sec: f64, duration_sec_value: f64) SettleAnimationState {
    const duration_squared_sec = duration_sec_value * duration_sec_value;
    const duration_cubed_sec = duration_squared_sec * duration_sec_value;
    const coeff_quadratic = -(3.0 * x0_px + 2.0 * v0_px_per_sec * duration_sec_value) / duration_squared_sec;
    const coeff_cubic = (2.0 * x0_px + v0_px_per_sec * duration_sec_value) / duration_cubed_sec;

    return .{
        .begin_time_qpc = begin_time_qpc,
        .duration_sec = duration_sec_value,
        .coeff_constant_f32 = @floatCast(x0_px),
        .coeff_linear_f32 = @floatCast(v0_px_per_sec),
        .coeff_quadratic_f32 = @floatCast(coeff_quadratic),
        .coeff_cubic_f32 = @floatCast(coeff_cubic),
    };
}

/// Return the velocity cone that reaches zero monotonically for x0_px.
pub fn clampVelocity(x0_px: f64, v0_px_per_sec: f64, duration_sec_value: f64) f64 {
    if (x0_px == 0.0 or duration_sec_value <= 0.0) return 0.0;
    const cone_speed_px_per_sec = 3.0 * @abs(x0_px) / duration_sec_value;
    if (x0_px > 0.0) return std.math.clamp(v0_px_per_sec, -cone_speed_px_per_sec, 0.0);
    return std.math.clamp(v0_px_per_sec, 0.0, cone_speed_px_per_sec);
}

/// Replay the f32 cubic at a QPC sample. QPC is converted using the contract's
/// t_sec = (sample_qpc - begin_qpc) / time_frequency_qpc expression.
pub fn evaluate(state: SettleAnimationState, sample_qpc: i64, time_frequency_qpc: f64) SettleSample {
    const begin_qpc_f64 = @as(f64, @floatFromInt(state.begin_time_qpc));
    const sample_qpc_f64 = @as(f64, @floatFromInt(sample_qpc));
    const t_sec = (sample_qpc_f64 - begin_qpc_f64) / time_frequency_qpc;
    if (t_sec <= 0.0) {
        return .{
            .position_px = @as(f64, state.coeff_constant_f32),
            .velocity_px_per_sec = @as(f64, state.coeff_linear_f32),
        };
    }
    if (t_sec >= state.duration_sec) return .{ .position_px = 0.0, .velocity_px_per_sec = 0.0 };

    const constant = @as(f64, state.coeff_constant_f32);
    const linear = @as(f64, state.coeff_linear_f32);
    const quadratic = @as(f64, state.coeff_quadratic_f32);
    const cubic = @as(f64, state.coeff_cubic_f32);
    const t_squared_sec = t_sec * t_sec;
    return .{
        .position_px = ((cubic * t_sec + quadratic) * t_sec + linear) * t_sec + constant,
        .velocity_px_per_sec = (3.0 * cubic * t_squared_sec) + (2.0 * quadratic * t_sec) + linear,
    };
}

/// Retarget at sample_qpc while preserving the old sampled position plus the
/// semantic delta. The inherited velocity is clamped for monotonicity.
pub fn retarget(
    previous: SettleAnimationState,
    sample_qpc: i64,
    time_frequency_qpc: f64,
    delta_px: f64,
) SettleAnimationState {
    const old_sample = evaluate(previous, sample_qpc, time_frequency_qpc);
    const new_offset_px = old_sample.position_px + delta_px;
    const new_velocity_px_per_sec = clampVelocity(new_offset_px, old_sample.velocity_px_per_sec, previous.duration_sec);
    return init(sample_qpc, new_offset_px, new_velocity_px_per_sec, previous.duration_sec);
}

/// Decide whether one semantic event can settle or must snap. The returned
/// settle value is the pixel delta to add to the current settle offset.
pub fn decideTrip(
    rows_delta: i32,
    row_height_px: f64,
    sampled_offset_px: f64,
    settle_limit_rows: i32,
    settle_max_px: f64,
) TripDecision {
    if (@abs(rows_delta) > settle_limit_rows) return .trip;
    const delta_px = @as(f64, @floatFromInt(rows_delta)) * row_height_px;
    if (@abs(sampled_offset_px + delta_px) > settle_max_px) return .trip;
    return .{ .settle = delta_px };
}

fn idealCoefficients(x0_px: f64, v0_px_per_sec: f64, duration_sec_value: f64) struct { d: f64, c: f64, b: f64, a: f64 } {
    return .{
        .d = x0_px,
        .c = v0_px_per_sec,
        .b = -(3.0 * x0_px + 2.0 * v0_px_per_sec * duration_sec_value) / (duration_sec_value * duration_sec_value),
        .a = (2.0 * x0_px + v0_px_per_sec * duration_sec_value) / (duration_sec_value * duration_sec_value * duration_sec_value),
    };
}

fn expectNear(actual: f64, expected: f64, tolerance: f64) !void {
    try std.testing.expect(@abs(actual - expected) <= tolerance);
}

test "cubic coefficients satisfy boundary conditions after f32 submission" {
    const x0_px = 37.5;
    const v0_px_per_sec = -42.0;
    const duration_sec_value = 0.12;
    const state = init(100, x0_px, v0_px_per_sec, duration_sec_value);
    const a = @as(f64, state.coeff_cubic_f32);
    const b = @as(f64, state.coeff_quadratic_f32);
    const c = @as(f64, state.coeff_linear_f32);
    const d = @as(f64, state.coeff_constant_f32);
    const endpoint_position_px = ((a * duration_sec_value + b) * duration_sec_value + c) * duration_sec_value + d;
    const endpoint_velocity_px_per_sec = (3.0 * a * duration_sec_value * duration_sec_value) + (2.0 * b * duration_sec_value) + c;
    try expectNear(d, x0_px, 0.00001);
    try expectNear(c, v0_px_per_sec, 0.00001);
    try expectNear(endpoint_position_px, 0.0, 0.0001);
    try expectNear(endpoint_velocity_px_per_sec, 0.0, 0.001);
}

test "retarget preserves composed-image position and cone-clamped velocity" {
    const frequency_qpc = 10_000_000.0;
    const previous = init(0, 20.0, 0.0, settle_duration_sec);
    const sample_qpc: i64 = 40_000;
    const old_sample = evaluate(previous, sample_qpc, frequency_qpc);
    const delta_px = -7.0;
    const next = retarget(previous, sample_qpc, frequency_qpc, delta_px);
    const next_at_begin = evaluate(next, sample_qpc, frequency_qpc);
    try expectNear(next_at_begin.position_px, old_sample.position_px + delta_px, 0.0001);
    const expected_velocity = clampVelocity(next_at_begin.position_px, old_sample.velocity_px_per_sec, settle_duration_sec);
    try expectNear(next_at_begin.velocity_px_per_sec, expected_velocity, 0.0001);
}

test "rapid retarget chain remains position-continuous at every junction" {
    const frequency_qpc = 10_000_000.0;
    var state = init(0, 20.0, 0.0, settle_duration_sec);
    var frame: i64 = 1;
    while (frame <= 10) : (frame += 1) {
        const sample_qpc = frame * 80_000;
        const delta_px: f64 = if ((frame & 1) == 0) -2.0 else 1.5;
        const old_sample = evaluate(state, sample_qpc, frequency_qpc);
        state = retarget(state, sample_qpc, frequency_qpc, delta_px);
        const new_sample = evaluate(state, sample_qpc, frequency_qpc);
        try expectNear(new_sample.position_px, old_sample.position_px + delta_px, 0.0002);
    }
}

test "cone clamp keeps cubic monotone and bounded for both signs" {
    const duration_sec_value = settle_duration_sec;
    const cases = [_]struct { x0_px: f64, inherited_velocity_px_per_sec: f64 }{
        .{ .x0_px = 60.0, .inherited_velocity_px_per_sec = 900.0 },
        .{ .x0_px = -60.0, .inherited_velocity_px_per_sec = -900.0 },
    };
    for (cases) |case| {
        const velocity_px_per_sec = clampVelocity(case.x0_px, case.inherited_velocity_px_per_sec, duration_sec_value);
        const state = init(0, case.x0_px, velocity_px_per_sec, duration_sec_value);
        var sample_index: usize = 0;
        while (sample_index <= 240) : (sample_index += 1) {
            const t_sec = duration_sec_value * @as(f64, @floatFromInt(sample_index)) / 240.0;
            const sample_qpc: i64 = @intFromFloat(t_sec * 10_000_000.0);
            const sample = evaluate(state, sample_qpc, 10_000_000.0);
            if (case.x0_px > 0.0) {
                try std.testing.expect(sample.position_px >= -0.0001);
            } else {
                try std.testing.expect(sample.position_px <= 0.0001);
            }
            try std.testing.expect(@abs(sample.position_px) <= @abs(case.x0_px) + 0.0001);
        }
    }
}

test "reversal retarget clamps inherited velocity before overshoot" {
    const frequency_qpc = 10_000_000.0;
    const previous = init(0, 20.0, 0.0, settle_duration_sec);
    const sample_qpc: i64 = 300_000;
    const old_sample = evaluate(previous, sample_qpc, frequency_qpc);
    const delta_px = -old_sample.position_px + 5.0;
    const state = retarget(previous, sample_qpc, frequency_qpc, delta_px);
    const new_sample = evaluate(state, sample_qpc, frequency_qpc);
    try expectNear(new_sample.position_px, 5.0, 0.0002);
    try std.testing.expect(new_sample.velocity_px_per_sec >= -3.0 * 5.0 / settle_duration_sec - 0.0001);
    try std.testing.expect(new_sample.velocity_px_per_sec <= 0.0001);
    var sample_index: usize = 0;
    while (sample_index <= 240) : (sample_index += 1) {
        const sample_qpc_at = sample_qpc + @as(i64, @intFromFloat(settle_duration_sec * @as(f64, @floatFromInt(sample_index)) / 240.0 * frequency_qpc));
        const sample = evaluate(state, sample_qpc_at, frequency_qpc);
        try std.testing.expect(sample.position_px >= -0.0001);
        try std.testing.expect(@abs(sample.position_px) <= 5.0001);
    }
}

test "trip policy enforces per-event and accumulated limits" {
    const max_px = settle_max_rows_default * 20.0;
    try std.testing.expect(decideTrip(4, 20.0, 0.0, settle_limit_rows_default, max_px) == .trip);
    try std.testing.expect(decideTrip(1, 20.0, 45.0, settle_limit_rows_default, max_px) == .trip);
    switch (decideTrip(1, 20.0, 20.0, settle_limit_rows_default, max_px)) {
        .settle => |delta_px| try expectNear(delta_px, 20.0, 0.0),
        .trip => return error.ExpectedSettle,
    }
}

test "finished state evaluates to exact zero position and velocity" {
    const state = init(100, 20.0, 0.0, settle_duration_sec);
    const finished = evaluate(state, 100 + 2_000_000, 10_000_000.0);
    try std.testing.expectEqual(@as(f64, 0.0), finished.position_px);
    try std.testing.expectEqual(@as(f64, 0.0), finished.velocity_px_per_sec);
}

test "f32 replay stays within tolerance of the f64 ideal" {
    const duration_sec_value = settle_duration_sec;
    const frequency_qpc = 10_000_000.0;
    const magnitudes_px = [_]f64{ 20.0, 60.0 };
    for (magnitudes_px) |x0_px| {
        const state = init(0, x0_px, 0.0, duration_sec_value);
        const ideal = idealCoefficients(x0_px, 0.0, duration_sec_value);
        var sample_index: usize = 1;
        while (sample_index < 10) : (sample_index += 1) {
            const t_sec = duration_sec_value * @as(f64, @floatFromInt(sample_index)) / 10.0;
            const sample_qpc: i64 = @intFromFloat(t_sec * frequency_qpc);
            const actual = evaluate(state, sample_qpc, frequency_qpc);
            const ideal_position_px = ((ideal.a * t_sec + ideal.b) * t_sec + ideal.c) * t_sec + ideal.d;
            try expectNear(actual.position_px, ideal_position_px, 0.0001);
        }
    }
}

test "QPC conversion and begin estimate error match the contract bounds" {
    const frequency_qpc = 10_000_000.0;
    const state = init(1_000_000, 20.0, 0.0, settle_duration_sec);
    const one_frame_late = evaluate(state, 1_000_000 + 166_666, frequency_qpc);
    const two_frames_late = evaluate(state, 1_000_000 + 333_333, frequency_qpc);
    const one_frame_error_px = 20.0 - one_frame_late.position_px;
    const two_frame_error_px = 20.0 - two_frames_late.position_px;
    try expectNear(one_frame_error_px, 1.05, 0.02);
    try expectNear(two_frame_error_px, 3.77, 0.03);
    const qpc_state = init(5_000, 12.0, 0.0, settle_duration_sec);
    const qpc_sample = evaluate(qpc_state, 5_000 + 600_000, 10_000_000.0);
    const expected_t_sec = 0.06;
    const expected_position_px = 12.0 * (1.0 - 3.0 * std.math.pow(f64, expected_t_sec / settle_duration_sec, 2.0) + 2.0 * std.math.pow(f64, expected_t_sec / settle_duration_sec, 3.0));
    try expectNear(qpc_sample.position_px, expected_position_px, 0.0002);
}
