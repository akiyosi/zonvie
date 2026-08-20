//! UI-thread owner for Contract A2's permanent DirectComposition settle visual.

const std = @import("std");
const c = @import("../win32.zig").c;
const applog = @import("../app_log.zig");
const math = @import("settle_math.zig");
const policy = @import("settle_policy.zig");
const dcomp = @import("dcomp_presenter.zig");

pub const TripReason = enum {
    event_limit,
    accumulated_limit,
    invalid_metrics,
};

pub const InstallResult = union(enum) {
    bound,
    trip: TripReason,
    failed,
};

/// The owner is embedded in ExternalWindow and is accessed only by the UI
/// thread. A fresh animation is created for every retarget: End makes an
/// animation immutable except for Reset, and rebuilding avoids relying on a
/// driver-specific Reset/rebind interaction. COM creation is not allocator
/// heap work on the paint path.
pub const SettlePresenter = struct {
    state: ?math.SettleAnimationState = null,
    animation: ?*dcomp.IDCompositionAnimation = null,

    pub fn drop(self: *SettlePresenter, com_alive: bool) void {
        if (self.animation) |animation| {
            // A device-loss generation is already torn down.  Even Release
            // would dereference an object owned by that dead COM world.
            if (com_alive) {
                _ = animation.lpVtbl.Reset(animation);
                _ = animation.lpVtbl.Release(animation);
            }
        }
        self.animation = null;
        self.state = null;
    }

    pub fn snap(self: *SettlePresenter, visual: *dcomp.IDCompositionVisual, com_alive: bool) bool {
        if (!com_alive) {
            self.drop(false);
            return false;
        }
        const hr = visual.lpVtbl.SetOffsetY(visual, 0.0);
        if (c.FAILED(hr)) {
            reportHr("SetOffsetY(snap)", hr);
            return false;
        }
        self.drop(true);
        return true;
    }

    pub fn install(
        self: *SettlePresenter,
        visual: *dcomp.IDCompositionVisual,
        device: *dcomp.IDCompositionDevice,
        rows_delta: i64,
        row_height_px: f64,
        now_qpc: i64,
        time_frequency_qpc: f64,
    ) InstallResult {
        if (rows_delta < std.math.minInt(i32) or rows_delta > std.math.maxInt(i32)) {
            _ = self.snap(visual, true);
            return .{ .trip = .event_limit };
        }
        if (row_height_px <= 0.0 or time_frequency_qpc <= 0.0) {
            _ = self.snap(visual, true);
            return .{ .trip = .invalid_metrics };
        }

        var stats: dcomp.DCOMPOSITION_FRAME_STATISTICS = std.mem.zeroes(dcomp.DCOMPOSITION_FRAME_STATISTICS);
        const stats_hr = device.lpVtbl.GetFrameStatistics(device, &stats);
        const begin_time = policy.resolveBeginTime(
            !c.FAILED(stats_hr),
            stats.timeFrequency.QuadPart,
            stats.nextEstimatedFrameTime.QuadPart,
            now_qpc,
            time_frequency_qpc,
        );
        const stats_valid = begin_time.stats_valid;
        const frequency = begin_time.frequency_qpc;
        const begin_qpc = begin_time.begin_qpc;

        const sampled_offset_px = if (self.state) |previous|
            math.evaluate(previous, begin_qpc, frequency).position_px
        else
            0.0;
        if (@abs(@as(i32, @intCast(rows_delta))) > math.settle_limit_rows_default) {
            _ = self.snap(visual, true);
            return .{ .trip = .event_limit };
        }
        const decision = math.decideTrip(
            @intCast(rows_delta),
            row_height_px,
            sampled_offset_px,
            math.settle_limit_rows_default,
            math.settle_max_rows_default * row_height_px,
        );
        const delta_px = switch (decision) {
            .settle => |delta| delta,
            .trip => {
                _ = self.snap(visual, true);
                return .{ .trip = .accumulated_limit };
            },
        };

        const next_state = if (self.state) |previous|
            math.retarget(previous, begin_qpc, frequency, delta_px)
        else
            math.init(begin_qpc, delta_px, 0.0, math.settle_duration_sec);

        var next_animation: ?*dcomp.IDCompositionAnimation = null;
        const create_hr = device.lpVtbl.CreateAnimation(device, &next_animation);
        if (c.FAILED(create_hr) or next_animation == null) {
            reportHr("CreateAnimation", create_hr);
            if (next_animation) |animation| releaseAnimation(animation);
            _ = self.snap(visual, true);
            return .failed;
        }
        const animation = next_animation.?;

        // SetAbsoluteBeginTime is optional only when frame statistics are
        // unavailable or invalid; valid statistics use the predicted QPC.
        if (stats_valid) {
            var absolute_begin: c.LARGE_INTEGER = undefined;
            absolute_begin.QuadPart = begin_qpc;
            const begin_hr = animation.lpVtbl.SetAbsoluteBeginTime(animation, absolute_begin);
            if (c.FAILED(begin_hr)) {
                reportHr("SetAbsoluteBeginTime", begin_hr);
                releaseAnimation(animation);
                return .failed;
            }
        }
        const cubic_hr = animation.lpVtbl.AddCubic(
            animation,
            0.0,
            next_state.coeff_constant_f32,
            next_state.coeff_linear_f32,
            next_state.coeff_quadratic_f32,
            next_state.coeff_cubic_f32,
        );
        if (c.FAILED(cubic_hr)) {
            reportHr("AddCubic", cubic_hr);
            releaseAnimation(animation);
            return .failed;
        }
        const end_hr = animation.lpVtbl.End(animation, next_state.duration_sec, 0.0);
        if (c.FAILED(end_hr)) {
            reportHr("End", end_hr);
            releaseAnimation(animation);
            return .failed;
        }
        const bind_hr = visual.lpVtbl.SetOffsetYAnimation(visual, animation);
        if (c.FAILED(bind_hr)) {
            reportHr("SetOffsetY(animation)", bind_hr);
            releaseAnimation(animation);
            return .failed;
        }

        // The new animation is now retained by the visual. Ended animations
        // cannot be rebound, so reset and release the old one after binding.
        if (self.animation) |old_animation| {
            _ = old_animation.lpVtbl.Reset(old_animation);
            _ = old_animation.lpVtbl.Release(old_animation);
        }
        next_animation = null;
        self.animation = animation;
        self.state = next_state;
        return .bound;
    }
};

fn releaseAnimation(animation: *dcomp.IDCompositionAnimation) void {
    _ = animation.lpVtbl.Reset(animation);
    _ = animation.lpVtbl.Release(animation);
}

fn reportHr(operation: []const u8, hr: c.HRESULT) void {
    if (applog.isEnabled()) applog.appLog("[settle] {s} failed: 0x{x}\n", .{ operation, @as(u32, @bitCast(hr)) });
}
