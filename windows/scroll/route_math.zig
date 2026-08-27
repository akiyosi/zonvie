//! Pure helpers for the main semantic scroll record.
//!
//! One flush's staged non-A1 deltas route by grid ownership:
//! a grid that currently has an external window keeps its displacement-seed
//! routing (a2_settle_commits ring of that window's TBS), every other staged
//! grid is a main-composite grid (>= 2) and publishes as a .b_ease record in
//! the MAIN TBS's ring. Grid 1 and the reserved negative ids never reach the
//! stage at all: stage_math.addGridScroll rejects grid_id <= 1 (seed matrix,
//! covered by stage_math's "non-external grids are ignored" test).
//!
//! std-only: runs as a native unit test on any host. No allocation anywhere;
//! the ledger is a fixed-capacity UI-thread-confined struct.

const std = @import("std");
const stage_math = @import("stage_math.zig");
const ease_math = @import("ease_math.zig");
const scroll_policy = @import("settle_policy.zig");

/// The non-A1 staged entries of one flush, in stage order. These are the
/// routing candidates described above; the A1 session slot (entries[0] when
/// a1_active) keeps its dedicated external delivery and is never returned.
pub fn settleEntries(stage: *const stage_math.FlushStage) []const stage_math.StageEntry {
    const start: usize = if (stage.a1_active) 1 else 0;
    return stage.entries[start..stage.len];
}

/// Distinct grids the main ease ledger can track at once. Larger than the
/// flush stage capacity so several flushes' worth of distinct grids can be
/// retained between paints without dropping.
pub const max_ledger_grids = 16;

/// Per-grid ease offset ledger (pixels, not rows).
/// UI-thread confinement keeps this lock-free. Fixed
/// capacity, no allocation: safe to touch on the paint path. Drained b_ease
/// records are converted here one event at a time at the paint barrier.
pub const EaseOffsetLedger = struct {
    grid_ids: [max_ledger_grids]i64 = undefined,
    offsets_px: [max_ledger_grids]f64 = undefined,
    velocities_px_s: [max_ledger_grids]f64 = undefined,
    len: usize = 0,

    /// Set (or overwrite) one grid's offset, zeroing its velocity. Test
    /// fixture only. Overwriting an in-flight entry
    /// breaks the v5 velocity continuity invariant, so production arrivals
    /// must go through seedArrival instead. Returns false when the ledger is
    /// full and the grid is new: the seed is dropped.
    pub fn seed(self: *EaseOffsetLedger, grid_id: i64, offset_px: f64) bool {
        var i: usize = 0;
        while (i < self.len) : (i += 1) {
            if (self.grid_ids[i] == grid_id) {
                self.offsets_px[i] = offset_px;
                self.velocities_px_s[i] = 0.0;
                return true;
            }
        }
        if (self.len == max_ledger_grids) return false;
        self.grid_ids[self.len] = grid_id;
        self.offsets_px[self.len] = offset_px;
        self.velocities_px_s[self.len] = 0.0;
        self.len += 1;
        return true;
    }

    /// Convert one arrived main-grid record into a spring seed. The arrival
    /// clamp is the sole per-grid limit; excess rows are partially snapped.
    /// This method is UI-thread confined and does not allocate.
    pub fn seedArrival(
        self: *EaseOffsetLedger,
        grid_id: i64,
        rows_delta: i32,
        row_height_px: f64,
        external_grid: bool,
    ) ArrivalSeedOutcome {
        return self.seedArrivalWithPolicy(grid_id, rows_delta, row_height_px, external_grid, 32, .partial);
    }

    /// Apply the shared large-jump policy before creating a main-window seed.
    /// The policy acts only as a beyond-threshold gate in snap mode; any batch
    /// that seeds at all must reach arrivalSeed's state-aware sum-then-clamp
    /// unmodified, or a residual opposite-sign offset under-animates.
    pub fn seedArrivalWithPolicy(
        self: *EaseOffsetLedger,
        grid_id: i64,
        rows_delta: i32,
        row_height_px: f64,
        external_grid: bool,
        live_ver: i32,
        mode: scroll_policy.LargeJumpBehavior,
    ) ArrivalSeedOutcome {
        if (!ease_math.shouldSeedGrid(grid_id, external_grid) or rows_delta == 0) {
            return .skipped;
        }
        const decision = scroll_policy.limitRows(@as(i64, rows_delta), live_ver, ease_math.retention_depth_rows, mode);
        if (mode == .snap and decision.animate_rows == 0) return .skipped;
        const seed_rows: i32 = rows_delta;
        if (self.find(grid_id)) |i| {
            const prev = self.offsets_px[i];
            const next = ease_math.arrivalSeed(prev, seed_rows, row_height_px, ease_math.retention_depth_rows);
            // v5.1: a seed that flips the offset's sign is a direction
            // reversal; velocity accumulated toward the old direction (worst
            // at the clamp) would lurch rows past the new target, so it
            // resets. Same-direction arrivals always preserve velocity.
            if (next != 0.0 and prev != 0.0 and (next < 0.0) != (prev < 0.0)) {
                self.velocities_px_s[i] = 0.0;
            }
            self.offsets_px[i] = next;
            return .seeded;
        }
        if (self.len == max_ledger_grids) return .capacity_drop;
        self.grid_ids[self.len] = grid_id;
        self.offsets_px[self.len] = ease_math.arrivalSeed(0.0, seed_rows, row_height_px, ease_math.retention_depth_rows);
        self.velocities_px_s[self.len] = 0.0;
        self.len += 1;
        return .seeded;
    }

    fn find(self: *const EaseOffsetLedger, grid_id: i64) ?usize {
        var i: usize = 0;
        while (i < self.len) : (i += 1) {
            if (self.grid_ids[i] == grid_id) return i;
        }
        return null;
    }

    pub fn offsetForGrid(self: *const EaseOffsetLedger, grid_id: i64) ?f64 {
        var i: usize = 0;
        while (i < self.len) : (i += 1) {
            if (self.grid_ids[i] == grid_id) return self.offsets_px[i];
        }
        return null;
    }

    pub fn count(self: *const EaseOffsetLedger) usize {
        return self.len;
    }

    /// Returns true whenever an entry exists; springTick removes settled entries.
    pub fn hasActive(self: *const EaseOffsetLedger) bool {
        return self.len > 0;
    }

    /// Advance every entry with the closed-form critically damped spring.
    /// Settled entries are swap-removed; the returned flag carries the
    /// one-frame final-zero notification for the recompose contract.
    pub fn tick(self: *EaseOffsetLedger, dt_sec: f64) bool {
        var reached_zero = false;
        var i: usize = 0;
        while (i < self.len) {
            const result = ease_math.springTick(
                .{ .offset_px = self.offsets_px[i], .velocity_px_s = self.velocities_px_s[i] },
                dt_sec,
            );
            if (result.state.offset_px == 0.0 and result.state.velocity_px_s == 0.0) {
                reached_zero = reached_zero or result.state.final_zero_frame_pending or result.final_zero_frame;
                // Swap-remove the settled entry.
                self.len -= 1;
                self.grid_ids[i] = self.grid_ids[self.len];
                self.offsets_px[i] = self.offsets_px[self.len];
                self.velocities_px_s[i] = self.velocities_px_s[self.len];
                continue;
            }
            self.offsets_px[i] = result.state.offset_px;
            self.velocities_px_s[i] = result.state.velocity_px_s;
            i += 1;
        }
        return reached_zero;
    }

    /// Forced drop on resize, DPI change, or device loss: drop
    /// every offset wholesale. Returns true when an active offset was dropped;
    /// the caller must then arm the final-zero pending flag so the drop still
    /// produces exactly one final recompose frame.
    pub fn dropAll(self: *EaseOffsetLedger) bool {
        const was_active = self.hasActive();
        self.len = 0;
        return was_active;
    }

    /// Drop one grid's offset and compact the ledger with a swap-remove.
    /// Returns true when the grid had an active entry.
    pub fn dropGrid(self: *EaseOffsetLedger, grid_id: i64) bool {
        const index = self.find(grid_id) orelse return false;
        self.len -= 1;
        self.grid_ids[index] = self.grid_ids[self.len];
        self.offsets_px[index] = self.offsets_px[self.len];
        self.velocities_px_s[index] = self.velocities_px_s[self.len];
        return true;
    }
};

pub const ArrivalSeedOutcome = enum {
    seeded,
    skipped,
    capacity_drop,
};

/// A paint may drive another frame only while an offset is visible or while
/// the required final-zero recompose frame is pending.  The outermost-paint
/// guard belongs here so callers cannot accidentally create nested invalidation
/// loops.  No idle counter is needed: once both conditions are false this
/// predicate remains false.
pub fn shouldScheduleNextFrame(
    offset_active: bool,
    final_zero_frame_pending: bool,
    outermost_paint: bool,
) bool {
    return outermost_paint and (offset_active or final_zero_frame_pending);
}

pub const should_schedule_next_frame = shouldScheduleNextFrame;

/// Inputs of the per-paint recompose derivation.
/// All fields are produced by steps 1-3 of the same paint's tick order.
pub const PaintTickInput = struct {
    /// Ledger holds an entry after this paint's spring tick (`active_now`).
    offset_active: bool,
    /// Step 2 (drain / debug hook) seeded an offset this paint (`seeded_now`).
    seeded_this_frame: bool,
    /// This paint's spring tick just crossed an offset to zero (natural
    /// final-zero semantics).
    reached_zero_this_frame: bool,
    /// A forced drop happened since the previous paint.
    forced_zero_pending: bool,
    /// `was_active_last_frame` persisted from the previous paint.
    was_active_last_frame: bool,
};

pub const PaintTickResult = struct {
    recompose: ease_math.RecomposeState,
    shader_recompose_frame: bool,
    /// Persist as `was_active_last_frame` for the next paint.
    was_active_next: bool,
};

/// Pure per-paint recompose derivation:
///   active_now = ledger has any offset of at least 1 px
///   seeded_now = a record seeded during this paint
///   final_zero = was_active_last_frame and !active_now
///   recompose  = active_now or seeded_now or final_zero
/// The caller must treat the result as frozen for the whole paint.
pub fn deriveRecomposeForPaint(in: PaintTickInput) PaintTickResult {
    const state: ease_math.RecomposeState = .{
        .offset_active = in.offset_active,
        .seeded_this_frame = in.seeded_this_frame,
        .final_zero_frame_pending = in.reached_zero_this_frame or in.forced_zero_pending,
        .final_zero_frame = in.was_active_last_frame and !in.offset_active,
    };
    return .{
        .recompose = state,
        .shader_recompose_frame = ease_math.shader_recompose_frame(state),
        .was_active_next = in.offset_active,
    };
}

test "settleEntries excludes the A1 slot and preserves stage order" {
    var stage: stage_math.FlushStage = .{};
    stage.beginFlush(.{ .generation = 3, .surface = .{ .grid_id = 9, .incarnation = 1 } });
    stage.addGridScroll(9, 2); // A1 slot
    stage.addGridScroll(4, 1);
    stage.addGridScroll(7, -2);
    stage.addGridScroll(4, 1);

    const entries = settleEntries(&stage);
    try std.testing.expectEqual(@as(usize, 2), entries.len);
    try std.testing.expectEqual(@as(i64, 4), entries[0].grid_id);
    try std.testing.expectEqual(@as(i32, 2), entries[0].rows_delta);
    try std.testing.expectEqual(@as(i64, 7), entries[1].grid_id);
    try std.testing.expectEqual(@as(i32, -2), entries[1].rows_delta);
}

test "settleEntries without an active session returns every staged entry" {
    var stage: stage_math.FlushStage = .{};
    stage.beginFlush(null);
    stage.addGridScroll(2, 1);
    stage.addGridScroll(3, 1);

    const entries = settleEntries(&stage);
    try std.testing.expectEqual(@as(usize, 2), entries.len);
    try std.testing.expectEqual(@as(i64, 2), entries[0].grid_id);
    try std.testing.expectEqual(@as(i64, 3), entries[1].grid_id);
}

test "seed matrix: grid 1 and reserved ids never become routing candidates" {
    var stage: stage_math.FlushStage = .{};
    stage.beginFlush(null);
    stage.addGridScroll(1, 5); // main grid 1: never seeds
    stage.addGridScroll(-100, 1); // reserved ext pum/cmdline/msg ids
    stage.addGridScroll(-101, 1);
    stage.addGridScroll(-102, 1);
    stage.addGridScroll(-103, 1);
    try std.testing.expectEqual(@as(usize, 0), settleEntries(&stage).len);
}

test "recompose derivation covers active seeded and final-zero conditions" {
    // Each of the three contract conditions alone forces a recompose frame.
    const active = deriveRecomposeForPaint(.{
        .offset_active = true,
        .seeded_this_frame = false,
        .reached_zero_this_frame = false,
        .forced_zero_pending = false,
        .was_active_last_frame = false,
    });
    try std.testing.expect(active.shader_recompose_frame);
    try std.testing.expect(active.was_active_next);

    const seeded = deriveRecomposeForPaint(.{
        .offset_active = false,
        .seeded_this_frame = true,
        .reached_zero_this_frame = false,
        .forced_zero_pending = false,
        .was_active_last_frame = false,
    });
    try std.testing.expect(seeded.shader_recompose_frame);
    try std.testing.expect(!seeded.was_active_next);

    const final_zero = deriveRecomposeForPaint(.{
        .offset_active = false,
        .seeded_this_frame = false,
        .reached_zero_this_frame = true,
        .forced_zero_pending = false,
        .was_active_last_frame = true,
    });
    try std.testing.expect(final_zero.shader_recompose_frame);
    try std.testing.expect(final_zero.recompose.final_zero_frame);

    const idle = deriveRecomposeForPaint(.{
        .offset_active = false,
        .seeded_this_frame = false,
        .reached_zero_this_frame = false,
        .forced_zero_pending = false,
        .was_active_last_frame = false,
    });
    try std.testing.expect(!idle.shader_recompose_frame);
}

test "natural spring produces exactly one final recompose frame" {
    var ledger: EaseOffsetLedger = .{};
    try std.testing.expect(ledger.seed(2, 40.0));
    var was_active = false;
    var recompose_after_inactive: u32 = 0;
    var frames: u32 = 0;
    while (frames < 32) : (frames += 1) {
        const reached_zero = ledger.tick(1.0 / 60.0);
        const paint = deriveRecomposeForPaint(.{
            .offset_active = ledger.hasActive(),
            .seeded_this_frame = false,
            .reached_zero_this_frame = reached_zero,
            .forced_zero_pending = false,
            .was_active_last_frame = was_active,
        });
        was_active = paint.was_active_next;
        if (!paint.recompose.offset_active and paint.shader_recompose_frame) {
            recompose_after_inactive += 1;
        }
        if (!paint.shader_recompose_frame) break;
    }
    // One final-zero frame after activity, then the blit path resumes.
    try std.testing.expectEqual(@as(u32, 1), recompose_after_inactive);
    try std.testing.expectEqual(@as(usize, 0), ledger.count());
}

test "forced drop arms exactly one final recompose frame" {
    var ledger: EaseOffsetLedger = .{};
    try std.testing.expect(ledger.seed(3, 60.0));
    try std.testing.expect(ledger.hasActive());

    // Paint 1: offset active.
    const active_paint = deriveRecomposeForPaint(.{
        .offset_active = ledger.hasActive(),
        .seeded_this_frame = false,
        .reached_zero_this_frame = false,
        .forced_zero_pending = false,
        .was_active_last_frame = false,
    });
    try std.testing.expect(active_paint.shader_recompose_frame);

    // Forced drops between paints must arm the pending flag.
    var forced_pending = false;
    if (ledger.dropAll()) forced_pending = true;
    try std.testing.expect(forced_pending);
    try std.testing.expect(!ledger.hasActive());

    // Paint 2: forced final-zero frame (both the pending flag and the
    // was_active rule report it).
    const final_paint = deriveRecomposeForPaint(.{
        .offset_active = ledger.hasActive(),
        .seeded_this_frame = false,
        .reached_zero_this_frame = false,
        .forced_zero_pending = forced_pending,
        .was_active_last_frame = active_paint.was_active_next,
    });
    forced_pending = false;
    try std.testing.expect(final_paint.shader_recompose_frame);
    try std.testing.expect(final_paint.recompose.final_zero_frame);

    // Paint 3: back on the ordinary blit path.
    const idle_paint = deriveRecomposeForPaint(.{
        .offset_active = ledger.hasActive(),
        .seeded_this_frame = false,
        .reached_zero_this_frame = false,
        .forced_zero_pending = forced_pending,
        .was_active_last_frame = final_paint.was_active_next,
    });
    try std.testing.expect(!idle_paint.shader_recompose_frame);

    // Dropping an already-empty ledger must not arm another final frame.
    try std.testing.expect(!ledger.dropAll());
}

test "EaseOffsetLedger seed overwrites and respects capacity" {
    var ledger: EaseOffsetLedger = .{};
    try std.testing.expect(ledger.seed(2, 10.0));
    try std.testing.expect(ledger.seed(2, 25.0));
    try std.testing.expectEqual(@as(f64, 25.0), ledger.offsetForGrid(2).?);
    try std.testing.expectEqual(@as(usize, 1), ledger.count());

    var grid: i64 = 3;
    while (grid < 2 + @as(i64, max_ledger_grids)) : (grid += 1) {
        try std.testing.expect(ledger.seed(grid, 5.0));
    }
    try std.testing.expect(!ledger.seed(1000, 5.0)); // full: new grid dropped
    try std.testing.expect(ledger.seed(3, 7.0)); // known grid still writable
    try std.testing.expectEqual(@as(f64, 7.0), ledger.offsetForGrid(3).?);
}

test "EaseOffsetLedger dropGrid swap-removes only the requested grid" {
    var ledger: EaseOffsetLedger = .{};
    try std.testing.expect(ledger.seed(2, 20.0));
    try std.testing.expect(ledger.seed(3, -40.0));
    try std.testing.expect(ledger.seed(4, 60.0));

    try std.testing.expect(ledger.dropGrid(3));
    try std.testing.expectEqual(@as(usize, 2), ledger.count());
    try std.testing.expectEqual(@as(f64, 20.0), ledger.offsetForGrid(2).?);
    try std.testing.expectEqual(@as(f64, 60.0), ledger.offsetForGrid(4).?);
    try std.testing.expect(ledger.offsetForGrid(3) == null);

    try std.testing.expect(!ledger.dropGrid(3));
    try std.testing.expect(ledger.dropGrid(2));
    try std.testing.expect(ledger.dropGrid(4));
    try std.testing.expectEqual(@as(usize, 0), ledger.count());
    try std.testing.expect(!ledger.dropGrid(4));
}

test "arrival seeds for mixed grids remain independent and exclusions skip" {
    var ledger: EaseOffsetLedger = .{};
    try std.testing.expectEqual(ArrivalSeedOutcome.seeded, ledger.seedArrival(2, 1, 20.0, false));
    try std.testing.expectEqual(ArrivalSeedOutcome.seeded, ledger.seedArrival(3, -2, 20.0, false));
    try std.testing.expectEqual(@as(f64, 20.0), ledger.offsetForGrid(2).?);
    try std.testing.expectEqual(@as(f64, -40.0), ledger.offsetForGrid(3).?);
    try std.testing.expectEqual(ArrivalSeedOutcome.skipped, ledger.seedArrival(1, 1, 20.0, false));
    try std.testing.expectEqual(ArrivalSeedOutcome.skipped, ledger.seedArrival(-100, 1, 20.0, false));
    try std.testing.expectEqual(ArrivalSeedOutcome.skipped, ledger.seedArrival(4, 1, 20.0, true));
    try std.testing.expectEqual(@as(usize, 2), ledger.count());
}

test "arrival train keeps one entry and preserves velocity" {
    var ledger: EaseOffsetLedger = .{};
    try std.testing.expectEqual(ArrivalSeedOutcome.seeded, ledger.seedArrival(9, 1, 20.0, false));
    _ = ledger.tick(1.0 / 60.0);
    const velocity_before_seed = ledger.velocities_px_s[ledger.find(9).?];
    try std.testing.expectEqual(ArrivalSeedOutcome.seeded, ledger.seedArrival(9, 1, 20.0, false));
    try std.testing.expectEqual(velocity_before_seed, ledger.velocities_px_s[ledger.find(9).?]);

    ledger = .{};
    var previous_velocity: f64 = 0.0;
    var tick: usize = 0;
    while (tick < 30 * 6) : (tick += 1) {
        if (tick % 6 == 0)
            try std.testing.expectEqual(ArrivalSeedOutcome.seeded, ledger.seedArrival(2, 1, 20.0, false));
        _ = ledger.tick(1.0 / 60.0);
        if (ledger.find(2)) |i| {
            if (tick > 6) try std.testing.expect(@abs(ledger.velocities_px_s[i] - previous_velocity) < 20.0 * 30.0);
            previous_velocity = ledger.velocities_px_s[i];
        }
        try std.testing.expectEqual(@as(usize, 1), ledger.count());
    }
}

test "reversal seed resets velocity accumulated at the clamp" {
    var ledger: EaseOffsetLedger = .{};
    // Saturate the clamp: keep re-seeding at the cap while ticking so the
    // spring accumulates consume-direction velocity against a pinned offset.
    var tick: usize = 0;
    while (tick < 60) : (tick += 1) {
        try std.testing.expectEqual(ArrivalSeedOutcome.seeded, ledger.seedArrival(2, 8, 20.0, false));
        _ = ledger.tick(1.0 / 60.0);
    }
    try std.testing.expect(@abs(ledger.velocities_px_s[ledger.find(2).?]) > 500.0);
    // A sign-flipping arrival is a direction reversal: velocity resets so the
    // stale momentum cannot lurch rows past the new target.
    try std.testing.expectEqual(ArrivalSeedOutcome.seeded, ledger.seedArrival(2, -20, 20.0, false));
    try std.testing.expect(ledger.offsetForGrid(2).? < 0.0);
    try std.testing.expectEqual(@as(f64, 0.0), ledger.velocities_px_s[ledger.find(2).?]);

    // A same-direction arrival never touches velocity (continuity invariant).
    _ = ledger.tick(1.0 / 60.0);
    const velocity_before = ledger.velocities_px_s[ledger.find(2).?];
    try std.testing.expectEqual(ArrivalSeedOutcome.seeded, ledger.seedArrival(2, -1, 20.0, false));
    try std.testing.expectEqual(velocity_before, ledger.velocities_px_s[ledger.find(2).?]);
}

test "arrival seed at clamp boundary drops only excess" {
    var ledger: EaseOffsetLedger = .{};
    try std.testing.expectEqual(ArrivalSeedOutcome.seeded, ledger.seedArrival(2, 8, 20.0, false));
    try std.testing.expectEqual(ArrivalSeedOutcome.seeded, ledger.seedArrival(2, 20, 20.0, false));
    try std.testing.expectEqual(@as(f64, 160.0), ledger.offsetForGrid(2).?);
    try std.testing.expectEqual(@as(usize, 1), ledger.count());
}

test "snap mode drops a batch beyond the live threshold" {
    var ledger: EaseOffsetLedger = .{};
    try std.testing.expectEqual(ArrivalSeedOutcome.skipped, ledger.seedArrivalWithPolicy(2, 4, 20.0, false, 3, .snap));
    try std.testing.expectEqual(ArrivalSeedOutcome.seeded, ledger.seedArrivalWithPolicy(2, 3, 20.0, false, 3, .snap));
    try std.testing.expectEqual(@as(f64, 60.0), ledger.offsetForGrid(2).?);
}

test "snap mode within threshold matches the state-aware partial clamp" {
    // Residual opposite-sign offset: the raw delta must reach arrivalSeed so
    // the sum-then-clamp pins the full cap, identical to partial mode.
    var snap_ledger: EaseOffsetLedger = .{};
    try std.testing.expectEqual(ArrivalSeedOutcome.seeded, snap_ledger.seedArrivalWithPolicy(2, -3, 20.0, false, 32, .snap));
    try std.testing.expectEqual(ArrivalSeedOutcome.seeded, snap_ledger.seedArrivalWithPolicy(2, 20, 20.0, false, 32, .snap));
    var partial_ledger: EaseOffsetLedger = .{};
    try std.testing.expectEqual(ArrivalSeedOutcome.seeded, partial_ledger.seedArrivalWithPolicy(2, -3, 20.0, false, 32, .partial));
    try std.testing.expectEqual(ArrivalSeedOutcome.seeded, partial_ledger.seedArrivalWithPolicy(2, 20, 20.0, false, 32, .partial));
    try std.testing.expectEqual(partial_ledger.offsetForGrid(2).?, snap_ledger.offsetForGrid(2).?);
}

test "external spring seeding matches the main ledger rules" {
    var ledger: EaseOffsetLedger = .{};
    var external: ease_math.ExternalSpringState = .{};
    try std.testing.expectEqual(ArrivalSeedOutcome.seeded, ledger.seedArrivalWithPolicy(2, -3, 20.0, false, 8, .partial));
    try std.testing.expectEqual(ease_math.ExternalSeedOutcome.animate, external.seedArrivalWithPolicy(-3, 20.0, 8, .partial).outcome);
    ledger.velocities_px_s[ledger.find(2).?] = 250.0;
    external.velocity_px_s = 250.0;
    try std.testing.expectEqual(ArrivalSeedOutcome.seeded, ledger.seedArrivalWithPolicy(2, 20, 20.0, false, 8, .partial));
    const external_result = external.seedArrivalWithPolicy(20, 20.0, 8, .partial);
    try std.testing.expectEqual(ease_math.ExternalSeedOutcome.animate, external_result.outcome);
    try std.testing.expect(external_result.sign_flipped);
    try std.testing.expectEqual(ledger.offsetForGrid(2).?, external.offset_px);
    try std.testing.expectEqual(ledger.velocities_px_s[ledger.find(2).?], external.velocity_px_s);

    var snap_ledger: EaseOffsetLedger = .{};
    var snap_external: ease_math.ExternalSpringState = .{};
    try std.testing.expectEqual(ArrivalSeedOutcome.skipped, snap_ledger.seedArrivalWithPolicy(2, 4, 20.0, false, 3, .snap));
    try std.testing.expectEqual(ease_math.ExternalSeedOutcome.skip, snap_external.seedArrivalWithPolicy(4, 20.0, 3, .snap).outcome);
}

test "external snap policy preserves FIFO record boundaries" {
    var external: ease_math.ExternalSpringState = .{};
    try std.testing.expectEqual(ease_math.ExternalSeedOutcome.animate, external.seedArrivalWithPolicy(3, 20.0, 3, .snap).outcome);
    try std.testing.expectEqual(ease_math.ExternalSeedOutcome.animate, external.seedArrivalWithPolicy(3, 20.0, 3, .snap).outcome);
    try std.testing.expectEqual(@as(f64, 60.0), external.offset_px);

    var aggregated: ease_math.ExternalSpringState = .{};
    try std.testing.expectEqual(ease_math.ExternalSeedOutcome.skip, aggregated.seedArrivalWithPolicy(6, 20.0, 3, .snap).outcome);
    try std.testing.expectEqual(@as(f64, 0.0), aggregated.offset_px);
}

test "partial policy keeps the historical final-offset clamp" {
    var ledger: EaseOffsetLedger = .{};
    try std.testing.expectEqual(ArrivalSeedOutcome.seeded, ledger.seedArrivalWithPolicy(2, 8, 20.0, false, 1, .partial));
    try std.testing.expectEqual(ArrivalSeedOutcome.seeded, ledger.seedArrivalWithPolicy(2, -20, 20.0, false, 1, .partial));
    try std.testing.expectEqual(@as(f64, -160.0), ledger.offsetForGrid(2).?);
}

test "frame driver schedules only active or final-zero outermost paints" {
    try std.testing.expect(shouldScheduleNextFrame(true, false, true));
    try std.testing.expect(shouldScheduleNextFrame(false, true, true));
    try std.testing.expect(!shouldScheduleNextFrame(false, false, true));
    try std.testing.expect(!shouldScheduleNextFrame(true, true, false));
}
