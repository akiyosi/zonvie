//! Pure accounting coordinator for Contract A smooth scrolling.
//!
//! This module deliberately has no platform imports and no allocator use. The
//! UI thread feeds typed observations into the coordinator and executes the
//! returned effects.

const std = @import("std");
const scroll_types = @import("types.zig");

pub const SurfaceToken = scroll_types.SurfaceToken;
pub const ScrollSessionId = scroll_types.ScrollSessionId;
pub const SemanticCommitRecord = scroll_types.SemanticCommitRecord;
pub const DmSnapshot = scroll_types.DmSnapshot;
pub const DmStatus = scroll_types.DmStatus;
pub const FixedRing = scroll_types.FixedRing;

pub const credit_capacity = 16;
pub const semantic_capacity = scroll_types.MaxSemanticCommits;
pub const effect_capacity = 32;

pub const borrow_retry_delay_ms: u32 = 66;
pub const credit_stale_confirmed_ms: u32 = 66;
pub const credit_stale_fallback_ms: u32 = 200;

pub const Direction = enum {
    positive,
    negative,

    pub fn sign(self: Direction) i32 {
        return switch (self) {
            .positive => 1,
            .negative => -1,
        };
    }

    pub fn fromRows(rows: i32) ?Direction {
        if (rows > 0) return .positive;
        if (rows < 0) return .negative;
        return null;
    }
};

pub const Phase = enum {
    idle,
    arming_borrow,
    direct,
    reversing,
    settling,
};

pub const DeadlineKind = enum {
    borrow_retry,
    credit_stale,
    restore_retry,
};

pub const Deadline = struct {
    kind: DeadlineKind,
    delay_ms: u32,
};

pub const ResetReason = enum {
    protocol_mismatch,
    foreign_scroll,
    lag,
    content_rect_edge,
    ring_overflow,
    edge_blocked,
    generation_mismatch,
    presentation_failure,
};

pub const Effect = union(enum) {
    send_scroll: Direction,
    arm_deadline: Deadline,
    stop_dm: void,
    apply_epoch_px: f64,
    restore_smoothscroll: i64,
    reset: ResetReason,
};

pub const EffectBuffer = struct {
    generation: u64 = 0,
    items: [effect_capacity]Effect = undefined,
    len: usize = 0,

    pub fn clear(self: *EffectBuffer, generation: u64) void {
        self.generation = generation;
        self.len = 0;
    }

    pub fn append(self: *EffectBuffer, effect: Effect) void {
        if (self.len == self.items.len) return;
        self.items[self.len] = effect;
        self.len += 1;
    }

    pub fn slice(self: *const EffectBuffer) []const Effect {
        return self.items[0..self.len];
    }
};

pub const RequestCredit = struct {
    rows_remaining: i32,
    sent_qpc: i64,
};

pub const BeginInput = struct {
    session: ScrollSessionId,
    row_height_px: f64,
    quantum_rows: i32,
    output_origin_y_px: f64,
    restore_smoothscroll_value: i64 = 0,
};

pub const PublishedInput = struct {
    generation: u64,
    surface: SurfaceToken,
    commit_rev: u64,
    present_succeeded: bool,
    epoch_commit_succeeded: bool,
    outermost_paint: bool = true,
};

pub const ViewportEdgeInfo = struct {
    generation: u64,
    surface: SurfaceToken,
    direction: Direction,
    viewport_edge: bool = false,
    content_rect_edge: bool = false,
};

/// Result of the non-blocking viewport edge probe performed before a request.
pub const EdgeProbe = struct {
    direction: Direction,
    confirmed: bool,
};

pub const ScrollCoordinator = struct {
    session: ?ScrollSessionId = null,
    phase: Phase = .idle,
    row_height_px: f64 = 0,
    quantum_rows: i32 = 0,
    max_ahead_rows: i32 = 0,
    max_residual_rows: i32 = 0,
    output_origin_y_px: f64 = 0,
    dm_travel_px: f64 = 0,

    requested_rows: i64 = 0,
    acknowledged_rows: i64 = 0,
    published_rows: i64 = 0,
    epoch_offset_px: f64 = 0,

    borrow_active: bool = false,
    borrow_outstanding: bool = false,
    restore_smoothscroll_value: i64 = 0,
    restore_pending: bool = false,
    active_direction: ?Direction = null,
    staged_rows: i64 = 0,

    request_credits: FixedRing(RequestCredit, credit_capacity) = .{},
    semantic_commits: FixedRing(SemanticCommitRecord, semantic_capacity) = .{},
    effects: EffectBuffer = .{},

    const Self = @This();

    pub fn init() Self {
        return .{};
    }

    pub fn effectBuffer(self: *const Self) *const EffectBuffer {
        return &self.effects;
    }

    pub fn effectsSlice(self: *const Self) []const Effect {
        return self.effects.slice();
    }

    pub fn creditCount(self: *const Self) usize {
        return self.request_credits.count();
    }

    pub fn semanticCommitCount(self: *const Self) usize {
        return self.semantic_commits.count();
    }

    pub fn residual_px(self: *const Self) f64 {
        return self.dm_travel_px - @as(f64, @floatFromInt(self.published_rows)) * self.row_height_px;
    }

    pub fn beginSession(self: *Self, input: BeginInput) void {
        self.clearEffects(input.session.generation);
        self.resetStateOnly();
        self.session = input.session;
        self.row_height_px = input.row_height_px;
        self.quantum_rows = input.quantum_rows;
        self.max_ahead_rows = input.quantum_rows;
        self.max_residual_rows = @max(2 * input.quantum_rows, 6);
        self.output_origin_y_px = input.output_origin_y_px;
        self.restore_smoothscroll_value = input.restore_smoothscroll_value;
        self.restore_pending = false;
        if (input.row_height_px <= 0 or input.quantum_rows <= 0) {
            self.resetSession(.protocol_mismatch);
            return;
        }
        self.phase = .arming_borrow;
        self.borrow_outstanding = true;
    }

    pub fn onBorrowResult(self: *Self, generation: u64, success: bool) void {
        self.clearEffects(generation);
        if (!self.matchesGeneration(generation) or self.phase != .arming_borrow) return;
        self.borrow_outstanding = false;
        if (success) {
            self.borrow_active = true;
            self.phase = .direct;
        } else {
            self.effects.append(.{ .arm_deadline = .{ .kind = .borrow_retry, .delay_ms = borrow_retry_delay_ms } });
        }
    }

    pub fn endSession(self: *Self, generation: u64) void {
        self.clearEffects(generation);
        if (!self.matchesGeneration(generation)) return;
        self.effects.append(.{ .stop_dm = {} });
        if (self.borrow_active) {
            self.effects.append(.{ .restore_smoothscroll = self.restore_smoothscroll_value });
            self.restore_pending = true;
        }
        self.effects.append(.{ .apply_epoch_px = 0 });
        self.resetStateOnly();
        self.session = null;
        self.phase = .idle;
    }

    pub fn onDmSnapshot(self: *Self, snapshot: DmSnapshot) void {
        self.onDmSnapshotWithEdgeProbe(snapshot, null);
    }

    pub fn onDmSnapshotWithEdgeProbe(self: *Self, snapshot: DmSnapshot, edge_probe: ?EdgeProbe) void {
        self.clearEffects(snapshot.generation);
        if (!self.matchesGeneration(snapshot.generation)) return;
        self.dm_travel_px = -(snapshot.output_y - self.output_origin_y_px);
        if (self.absResidualRows() > self.max_residual_rows) {
            self.resetSession(.lag);
            return;
        }
        if (snapshot.status == .disabled or snapshot.status == .suspended) {
            self.resetSession(.protocol_mismatch);
            return;
        }
        self.emitLookahead(snapshot.qpc, edge_probe);
    }

    pub fn onGridScroll(self: *Self, rows_delta: i32) void {
        self.clearEffects(self.currentGeneration());
        if (self.phase == .idle or rows_delta == 0) return;
        const direction = Direction.fromRows(rows_delta) orelse return;
        const first = self.request_credits.front() orelse {
            self.resetSession(.foreign_scroll);
            return;
        };
        if (oppositeSigns(first.rows_remaining, direction.sign())) {
            self.resetSession(.protocol_mismatch);
            return;
        }
        var remaining = rows_delta;
        while (remaining != 0) {
            const credit = self.request_credits.front() orelse {
                self.resetSession(.foreign_scroll);
                return;
            };
            if (oppositeSigns(credit.rows_remaining, remaining)) {
                self.resetSession(.protocol_mismatch);
                return;
            }
            const take_abs = @min(absI32(credit.rows_remaining), absI32(remaining));
            const take = @as(i32, @intCast(take_abs)) * direction.sign();
            credit.rows_remaining -= take;
            remaining -= take;
            self.staged_rows += take;
            if (credit.rows_remaining == 0) _ = self.request_credits.popFront();
        }
        if (self.request_credits.isEmpty() and self.phase == .reversing) {
            self.phase = if (self.staged_rows == 0) .direct else .settling;
        }
    }

    pub fn onGridScrollFor(self: *Self, generation: u64, surface: SurfaceToken, rows_delta: i32) void {
        self.clearEffects(generation);
        if (!self.matchesSurface(generation, surface)) return;
        self.onGridScroll(rows_delta);
    }

    pub fn onSemanticCommit(self: *Self, record: SemanticCommitRecord) void {
        self.clearEffects(record.session_generation);
        if (!self.matchesSurface(record.session_generation, record.surface)) return;
        if (record.ack_delivered) return;
        const available_rows = self.requested_rows - self.acknowledged_rows;
        if (record.rows_delta == 0 or absI64(@as(i64, record.rows_delta)) > absI64(available_rows) or
            (@as(i64, record.rows_delta) > 0 and self.staged_rows <= 0) or
            (@as(i64, record.rows_delta) < 0 and self.staged_rows >= 0))
        {
            self.resetSession(.protocol_mismatch);
            return;
        }
        if (absI64(@as(i64, record.rows_delta)) > absI64(self.staged_rows)) {
            self.resetSession(.foreign_scroll);
            return;
        }
        self.staged_rows -= record.rows_delta;
        self.acknowledged_rows += record.rows_delta;
        if (!self.semantic_commits.push(record)) {
            self.resetSession(.ring_overflow);
            return;
        }
        if ((self.phase == .settling or self.phase == .reversing) and self.request_credits.isEmpty() and self.staged_rows == 0) {
            self.phase = .direct;
        }
    }

    pub fn onTargetCommitWithoutJoin(self: *Self, generation: u64, surface: SurfaceToken) void {
        self.clearEffects(generation);
        if (!self.matchesSurface(generation, surface)) return;
        self.resetSession(.protocol_mismatch);
    }

    pub fn onPublished(self: *Self, input: PublishedInput) void {
        self.clearEffects(input.generation);
        if (!self.matchesSurface(input.generation, input.surface)) return;
        if (!input.outermost_paint) return;
        if (!input.present_succeeded) {
            // Keep the semantic records and published counter for a paint retry.
            return;
        }
        if (!input.epoch_commit_succeeded) {
            if (self.hasDueRevision(input.commit_rev)) self.resetSession(.presentation_failure);
            return;
        }
        var published_delta: i64 = 0;
        var count: usize = 0;
        while (count < self.semantic_commits.count()) {
            const record = self.semantic_commits.at(count);
            if (record.commit_rev > input.commit_rev) break;
            published_delta += record.rows_delta;
            count += 1;
        }
        if (count == 0) return;
        const candidate = self.published_rows + published_delta;
        var remaining_sum: i64 = 0;
        var remaining_index = count;
        while (remaining_index < self.semantic_commits.count()) : (remaining_index += 1) {
            remaining_sum += self.semantic_commits.at(remaining_index).rows_delta;
        }
        if (self.acknowledged_rows != candidate + remaining_sum) {
            self.resetSession(.protocol_mismatch);
            return;
        }
        var i: usize = 0;
        while (i < count) : (i += 1) _ = self.semantic_commits.popFront();
        self.published_rows = candidate;
        self.epoch_offset_px = @as(f64, @floatFromInt(self.published_rows)) * self.row_height_px;
        self.effects.append(.{ .apply_epoch_px = self.epoch_offset_px });
    }

    pub fn onDeadlineExpired(self: *Self, generation: u64, kind: DeadlineKind) void {
        self.clearEffects(generation);
        if (!self.matchesGeneration(generation)) return;
        switch (kind) {
            .borrow_retry => if (self.phase == .arming_borrow) self.effects.append(.{ .arm_deadline = .{ .kind = .borrow_retry, .delay_ms = borrow_retry_delay_ms } }),
            .credit_stale => if (!self.request_credits.isEmpty()) self.resetSession(.edge_blocked),
            .restore_retry => if (self.restore_pending) self.effects.append(.{ .restore_smoothscroll = self.restore_smoothscroll_value }),
        }
    }

    pub fn onViewportEdge(self: *Self, info: ViewportEdgeInfo) void {
        self.clearEffects(info.generation);
        if (!self.matchesSurface(info.generation, info.surface)) return;
        if (info.content_rect_edge) {
            self.resetSession(.content_rect_edge);
        } else if (info.viewport_edge) {
            self.resetSession(.edge_blocked);
        }
    }

    pub fn onContentRectEdge(self: *Self, generation: u64, surface: SurfaceToken, at_edge: bool) void {
        self.clearEffects(generation);
        if (at_edge) self.onViewportEdge(.{ .generation = generation, .surface = surface, .direction = .positive, .content_rect_edge = true });
    }

    fn emitLookahead(self: *Self, sent_qpc: i64, edge_probe: ?EdgeProbe) void {
        if (self.phase == .idle or self.phase == .arming_borrow or self.quantum_rows <= 0) return;
        const unbooked_px = self.dm_travel_px - @as(f64, @floatFromInt(self.requested_rows)) * self.row_height_px;
        const direction = Direction.fromRows(if (unbooked_px > 0) 1 else -1) orelse .negative;
        if (direction.sign() * unbooked_px <= 0) return;
        if (self.active_direction) |old| {
            const old_direction_outstanding = !self.request_credits.isEmpty() or self.staged_rows != 0;
            if (old != direction and old_direction_outstanding) {
                self.phase = .reversing;
                return;
            }
            if (old != direction) self.phase = .direct;
        }
        const requested_delta = @as(i64, self.quantum_rows) * @as(i64, direction.sign());
        const next_requested_rows = self.requested_rows + requested_delta;
        if (absI64(next_requested_rows - self.published_rows) > @as(u64, @intCast(self.max_ahead_rows))) return;
        self.active_direction = direction;
        if (!self.request_credits.push(.{ .rows_remaining = self.quantum_rows * direction.sign(), .sent_qpc = sent_qpc })) {
            self.resetSession(.ring_overflow);
            return;
        }
        self.requested_rows = next_requested_rows;
        self.effects.append(.{ .send_scroll = direction });
        const stale_delay_ms = if (edge_probe) |probe|
            if (probe.direction == direction and probe.confirmed) credit_stale_confirmed_ms else credit_stale_fallback_ms
        else
            credit_stale_fallback_ms;
        self.effects.append(.{ .arm_deadline = .{ .kind = .credit_stale, .delay_ms = stale_delay_ms } });
    }

    fn resetSession(self: *Self, reason: ResetReason) void {
        self.effects.append(.{ .stop_dm = {} });
        if (self.borrow_active or self.borrow_outstanding) {
            self.effects.append(.{ .restore_smoothscroll = self.restore_smoothscroll_value });
            self.restore_pending = true;
        }
        self.effects.append(.{ .apply_epoch_px = 0 });
        self.effects.append(.{ .reset = reason });
        self.resetStateOnly();
        self.phase = .idle;
        self.session = null;
    }

    fn resetStateOnly(self: *Self) void {
        self.phase = .idle;
        self.row_height_px = 0;
        self.quantum_rows = 0;
        self.max_ahead_rows = 0;
        self.max_residual_rows = 0;
        self.output_origin_y_px = 0;
        self.dm_travel_px = 0;
        self.requested_rows = 0;
        self.acknowledged_rows = 0;
        self.published_rows = 0;
        self.epoch_offset_px = 0;
        self.borrow_active = false;
        self.borrow_outstanding = false;
        self.active_direction = null;
        self.staged_rows = 0;
        self.request_credits.clear();
        self.semantic_commits.clear();
    }

    fn clearEffects(self: *Self, generation: u64) void {
        self.effects.clear(generation);
    }

    fn currentGeneration(self: *const Self) u64 {
        return if (self.session) |s| s.generation else 0;
    }

    fn matchesGeneration(self: *const Self, generation: u64) bool {
        return if (self.session) |s| s.generation == generation else false;
    }

    fn matchesSurface(self: *const Self, generation: u64, surface: SurfaceToken) bool {
        return if (self.session) |s| s.generation == generation and s.surface.eql(surface) else false;
    }

    fn hasDueRevision(self: *const Self, commit_rev: u64) bool {
        const ring = @constCast(&self.semantic_commits);
        for (0..ring.count()) |i| if (ring.at(i).commit_rev <= commit_rev) return true;
        return false;
    }

    fn absResidualRows(self: *const Self) i32 {
        if (self.row_height_px <= 0) return 0;
        return @intFromFloat(@ceil(@abs(self.residual_px()) / self.row_height_px));
    }
};

fn absI32(value: i32) u32 {
    return if (value < 0) @intCast(-@as(i64, value)) else @intCast(value);
}

fn absI64(value: i64) u64 {
    return if (value < 0) @intCast(-value) else @intCast(value);
}

fn oppositeSigns(a: i32, b: i32) bool {
    return (a < 0 and b > 0) or (a > 0 and b < 0);
}

fn hasSendScroll(coordinator: *const ScrollCoordinator, expected: Direction) bool {
    for (coordinator.effectsSlice()) |effect| {
        switch (effect) {
            .send_scroll => |direction| if (direction == expected) return true,
            else => {},
        }
    }
    return false;
}

fn creditStaleDelay(coordinator: *const ScrollCoordinator) ?u32 {
    for (coordinator.effectsSlice()) |effect| {
        switch (effect) {
            .arm_deadline => |deadline| if (deadline.kind == .credit_stale) return deadline.delay_ms,
            else => {},
        }
    }
    return null;
}

test "idle coordinator has no credits, semantic records, or epoch" {
    const c = ScrollCoordinator.init();
    try std.testing.expectEqual(Phase.idle, c.phase);
    try std.testing.expectEqual(@as(usize, 0), c.creditCount());
    try std.testing.expectEqual(@as(usize, 0), c.semanticCommitCount());
    try std.testing.expectEqual(@as(i64, 0), c.published_rows);
    try std.testing.expectEqual(@as(f64, 0), c.epoch_offset_px);
    try std.testing.expect(!c.borrow_active and !c.borrow_outstanding);
}

test "publication requires semantic record and both presentation gates" {
    const surface: SurfaceToken = .{ .grid_id = 2, .incarnation = 1 };
    var c = ScrollCoordinator.init();
    c.beginSession(.{ .session = .{ .generation = 1, .surface = surface }, .row_height_px = 10, .quantum_rows = 3, .output_origin_y_px = 0 });
    c.onBorrowResult(1, true);
    c.onDmSnapshot(.{ .generation = 1, .status = .running, .output_y = -20, .qpc = 1 });
    c.onGridScroll(3);
    c.onSemanticCommit(.{ .session_generation = 1, .surface = surface, .commit_rev = 4, .rows_delta = 3 });
    c.onPublished(.{ .generation = 1, .surface = surface, .commit_rev = 4, .present_succeeded = false, .epoch_commit_succeeded = true });
    try std.testing.expectEqual(@as(i64, 0), c.published_rows);
    try std.testing.expectEqual(@as(usize, 1), c.semanticCommitCount());
    c.onPublished(.{ .generation = 1, .surface = surface, .commit_rev = 4, .present_succeeded = true, .epoch_commit_succeeded = true });
    try std.testing.expectEqual(@as(i64, 3), c.published_rows);
    try std.testing.expectEqual(@as(f64, 30), c.epoch_offset_px);
}

test "generation-mismatched DM callback changes nothing" {
    const surface: SurfaceToken = .{ .grid_id = 2, .incarnation = 1 };
    var c = ScrollCoordinator.init();
    c.beginSession(.{ .session = .{ .generation = 7, .surface = surface }, .row_height_px = 10, .quantum_rows = 1, .output_origin_y_px = 5 });
    c.onBorrowResult(7, true);
    c.onDmSnapshot(.{ .generation = 99, .status = .running, .output_y = -100, .qpc = 1 });
    try std.testing.expectEqual(@as(f64, 0), c.dm_travel_px);
    try std.testing.expectEqual(Phase.direct, c.phase);
}

test "residual clamp and content rect edge reset" {
    const surface: SurfaceToken = .{ .grid_id = 2, .incarnation = 1 };
    var c = ScrollCoordinator.init();
    c.beginSession(.{ .session = .{ .generation = 1, .surface = surface }, .row_height_px = 10, .quantum_rows = 1, .output_origin_y_px = 0 });
    c.onBorrowResult(1, true);
    c.onDmSnapshot(.{ .generation = 1, .status = .running, .output_y = -70, .qpc = 1 });
    try std.testing.expectEqual(Phase.idle, c.phase);
    try std.testing.expectEqual(ResetReason.lag, c.effects.items[c.effects.len - 1].reset);

    c.beginSession(.{ .session = .{ .generation = 2, .surface = surface }, .row_height_px = 10, .quantum_rows = 1, .output_origin_y_px = 0 });
    c.onContentRectEdge(2, surface, true);
    try std.testing.expectEqual(Phase.idle, c.phase);
    try std.testing.expectEqual(ResetReason.content_rect_edge, c.effects.items[c.effects.len - 1].reset);
}

test "staging and acknowledgement never publish before Present" {
    const surface: SurfaceToken = .{ .grid_id = 9, .incarnation = 3 };
    var c = ScrollCoordinator.init();
    c.beginSession(.{ .session = .{ .generation = 4, .surface = surface }, .row_height_px = 8, .quantum_rows = 2, .output_origin_y_px = 0 });
    c.onBorrowResult(4, true);
    c.onDmSnapshot(.{ .generation = 4, .status = .running, .output_y = -8, .qpc = 10 });
    c.onGridScroll(2);
    c.onSemanticCommit(.{ .session_generation = 4, .surface = surface, .commit_rev = 10, .rows_delta = 2 });
    try std.testing.expectEqual(@as(i64, 2), c.acknowledged_rows);
    try std.testing.expectEqual(@as(i64, 0), c.published_rows);
    try std.testing.expectEqual(@as(f64, 0), c.epoch_offset_px);
    try std.testing.expect(c.acknowledged_rows <= c.requested_rows);
}

test "foreign or over-credit scroll resets and reversal does not create opposite credit" {
    const surface: SurfaceToken = .{ .grid_id = 3, .incarnation = 1 };
    var c = ScrollCoordinator.init();
    c.beginSession(.{ .session = .{ .generation = 1, .surface = surface }, .row_height_px = 10, .quantum_rows = 1, .output_origin_y_px = 0 });
    c.onBorrowResult(1, true);
    c.onDmSnapshot(.{ .generation = 1, .status = .running, .output_y = -10, .qpc = 1 });
    try std.testing.expectEqual(@as(usize, 1), c.creditCount());
    c.onDmSnapshot(.{ .generation = 1, .status = .running, .output_y = 10, .qpc = 2 });
    try std.testing.expectEqual(Phase.reversing, c.phase);
    try std.testing.expectEqual(@as(usize, 1), c.creditCount());

    c.beginSession(.{ .session = .{ .generation = 2, .surface = surface }, .row_height_px = 10, .quantum_rows = 1, .output_origin_y_px = 0 });
    c.onBorrowResult(2, true);
    c.onGridScroll(1);
    try std.testing.expectEqual(Phase.idle, c.phase);
    try std.testing.expectEqual(ResetReason.foreign_scroll, c.effects.items[c.effects.len - 1].reset);
}

test "same-direction lookahead continues across publish catch-up cycles" {
    const surface: SurfaceToken = .{ .grid_id = 11, .incarnation = 1 };
    var c = ScrollCoordinator.init();
    c.beginSession(.{ .session = .{ .generation = 1, .surface = surface }, .row_height_px = 10, .quantum_rows = 3, .output_origin_y_px = 0 });
    c.onBorrowResult(1, true);

    const output_y_values = [_]f64{ -30, -60, -90 };
    for (output_y_values, 0..) |output_y, index| {
        c.onDmSnapshot(.{ .generation = 1, .status = .running, .output_y = output_y, .qpc = @intCast(index + 1) });
        try std.testing.expect(hasSendScroll(&c, .positive));
        c.onGridScroll(3);
        c.onSemanticCommit(.{ .session_generation = 1, .surface = surface, .commit_rev = @intCast(index + 1), .rows_delta = 3 });
        c.onPublished(.{ .generation = 1, .surface = surface, .commit_rev = @intCast(index + 1), .present_succeeded = true, .epoch_commit_succeeded = true });
        try std.testing.expectEqual(Phase.direct, c.phase);
        try std.testing.expect(c.session != null);
    }
    try std.testing.expectEqual(@as(i64, 9), c.published_rows);
}

test "reversal blocks opposite request until old credit is acknowledged" {
    const surface: SurfaceToken = .{ .grid_id = 12, .incarnation = 1 };
    var c = ScrollCoordinator.init();
    c.beginSession(.{ .session = .{ .generation = 2, .surface = surface }, .row_height_px = 10, .quantum_rows = 3, .output_origin_y_px = 0 });
    c.onBorrowResult(2, true);
    c.onDmSnapshot(.{ .generation = 2, .status = .running, .output_y = -30, .qpc = 1 });
    try std.testing.expect(hasSendScroll(&c, .positive));

    c.onDmSnapshot(.{ .generation = 2, .status = .running, .output_y = 30, .qpc = 2 });
    try std.testing.expectEqual(Phase.reversing, c.phase);
    try std.testing.expectEqual(@as(usize, 1), c.creditCount());

    c.onGridScroll(3);
    try std.testing.expectEqual(Phase.settling, c.phase);
    c.onDmSnapshot(.{ .generation = 2, .status = .running, .output_y = 30, .qpc = 3 });
    try std.testing.expectEqual(@as(usize, 0), c.effectsSlice().len);

    c.onSemanticCommit(.{ .session_generation = 2, .surface = surface, .commit_rev = 7, .rows_delta = 3 });
    try std.testing.expectEqual(Phase.direct, c.phase);
    c.onDmSnapshot(.{ .generation = 2, .status = .running, .output_y = 30, .qpc = 4 });
    try std.testing.expect(hasSendScroll(&c, .negative));
    try std.testing.expectEqual(@as(usize, 1), c.creditCount());
}

test "credit stale deadline uses confirmed and fallback edge probe delays" {
    const surface: SurfaceToken = .{ .grid_id = 13, .incarnation = 1 };
    var c = ScrollCoordinator.init();
    c.beginSession(.{ .session = .{ .generation = 3, .surface = surface }, .row_height_px = 10, .quantum_rows = 1, .output_origin_y_px = 0 });
    c.onBorrowResult(3, true);
    c.onDmSnapshotWithEdgeProbe(
        .{ .generation = 3, .status = .running, .output_y = -10, .qpc = 1 },
        .{ .direction = .positive, .confirmed = true },
    );
    try std.testing.expectEqual(@as(?u32, credit_stale_confirmed_ms), creditStaleDelay(&c));

    c.beginSession(.{ .session = .{ .generation = 4, .surface = surface }, .row_height_px = 10, .quantum_rows = 1, .output_origin_y_px = 0 });
    c.onBorrowResult(4, true);
    c.onDmSnapshotWithEdgeProbe(
        .{ .generation = 4, .status = .running, .output_y = -10, .qpc = 2 },
        .{ .direction = .positive, .confirmed = false },
    );
    try std.testing.expectEqual(@as(?u32, credit_stale_fallback_ms), creditStaleDelay(&c));
}

test "mismatched callback clears effects from the previous call" {
    const surface: SurfaceToken = .{ .grid_id = 14, .incarnation = 1 };
    var c = ScrollCoordinator.init();
    c.beginSession(.{ .session = .{ .generation = 5, .surface = surface }, .row_height_px = 10, .quantum_rows = 1, .output_origin_y_px = 0 });
    c.onBorrowResult(5, true);
    c.onDmSnapshot(.{ .generation = 5, .status = .running, .output_y = -10, .qpc = 1 });
    c.onGridScroll(1);
    c.onSemanticCommit(.{ .session_generation = 5, .surface = surface, .commit_rev = 1, .rows_delta = 1 });
    c.onPublished(.{ .generation = 5, .surface = surface, .commit_rev = 1, .present_succeeded = true, .epoch_commit_succeeded = true });
    try std.testing.expect(c.effectsSlice().len > 0);
    c.onDeadlineExpired(99, .credit_stale);
    try std.testing.expectEqual(@as(usize, 0), c.effectsSlice().len);
}

test "multi-reversal publication validates the ring invariant" {
    const surface: SurfaceToken = .{ .grid_id = 15, .incarnation = 1 };
    var c = ScrollCoordinator.init();
    c.beginSession(.{ .session = .{ .generation = 6, .surface = surface }, .row_height_px = 10, .quantum_rows = 2, .output_origin_y_px = 0 });
    c.onBorrowResult(6, true);
    const forward_outputs = [_]f64{ -20, -40, -60 };
    for (forward_outputs, 0..) |output_y, index| {
        c.onDmSnapshot(.{ .generation = 6, .status = .running, .output_y = output_y, .qpc = @intCast(index + 1) });
        c.onGridScroll(2);
        c.onSemanticCommit(.{ .session_generation = 6, .surface = surface, .commit_rev = @intCast(index + 1), .rows_delta = 2 });
        c.onPublished(.{ .generation = 6, .surface = surface, .commit_rev = @intCast(index + 1), .present_succeeded = true, .epoch_commit_succeeded = true });
    }
    try std.testing.expectEqual(@as(i64, 6), c.published_rows);

    // Permit two acknowledged-but-unpublished reverse credits so a stale
    // outermost paint observes candidate > acknowledged with a negative delta.
    c.max_ahead_rows = 4;
    c.onDmSnapshot(.{ .generation = 6, .status = .running, .output_y = -20, .qpc = 10 });
    c.onGridScroll(-2);
    c.onSemanticCommit(.{ .session_generation = 6, .surface = surface, .commit_rev = 10, .rows_delta = -2 });
    c.onDmSnapshot(.{ .generation = 6, .status = .running, .output_y = 0, .qpc = 11 });
    c.onGridScroll(-2);
    c.onSemanticCommit(.{ .session_generation = 6, .surface = surface, .commit_rev = 11, .rows_delta = -2 });
    try std.testing.expectEqual(@as(i64, 2), c.acknowledged_rows);

    c.onPublished(.{ .generation = 6, .surface = surface, .commit_rev = 10, .present_succeeded = true, .epoch_commit_succeeded = true });
    try std.testing.expectEqual(@as(i64, 4), c.published_rows);
    try std.testing.expectEqual(Phase.direct, c.phase);
    c.onPublished(.{ .generation = 6, .surface = surface, .commit_rev = 11, .present_succeeded = true, .epoch_commit_succeeded = true });
    try std.testing.expectEqual(@as(i64, 2), c.published_rows);
    try std.testing.expect(c.session != null);
}
