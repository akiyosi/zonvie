//! CPU-side retention bookkeeping for Contract B smooth scrolling.
//!
//! The ring deliberately knows nothing about vertices or D3D.  `storage_slot`
//! is an index into vertex storage owned by the application; this keeps the
//! transaction rules testable with the native Zig test runner.

const std = @import("std");

pub const max_retained_grids: usize = 8;
pub const retention_depth_rows: usize = 8;
pub const in_flight_slots: usize = 4;
pub const capacity: usize = max_retained_grids * retention_depth_rows * in_flight_slots;
pub const max_replay_steps: usize = retention_depth_rows;
pub const ring_capacity = capacity;

pub const SlotState = enum { free, staged, published };

pub const Capture = struct {
    source_row: i32,
    target_row: i32,
    grid_id: i64,
    cell_height: f32,
    vertex_count: u32,
    /// Index into the application's fixed vertex ArrayList array.
    storage_slot: u16,
};

pub const Slot = struct {
    state: SlotState = .free,
    capture: Capture = undefined,
    rollback_capture: Capture = undefined,
    staged_from_published: bool = false,
    /// A carried (restaged-from-published) row that a beginStep drop rule
    /// removed. The removal only takes effect at commit; until then abort can
    /// restore the prior publication, and the paint view keeps showing the
    /// pre-shift capture (macOS: published stays intact until commit).
    dropped_pending: bool = false,
};

pub const ReplayStep = struct {
    grid_id: i64,
    rows_delta: i32,
};

pub const Ring = struct {
    slots: [capacity]Slot = [_]Slot{.{}} ** capacity,
    next_slot: usize = 0,
    staged_count: usize = 0,
    published_count_: usize = 0,
    flush_open: bool = false,
    /// A grid which overflowed is disabled for this bracket.  This is
    /// fail-closed: callers must fall back to ordinary row rendering.
    dropped_grids: [max_retained_grids]i64 = undefined,
    dropped_count: usize = 0,
    replay: [max_replay_steps]ReplayStep = undefined,
    replay_count: usize = 0,

    const Self = @This();

    pub fn init() Self {
        return .{};
    }

    pub fn stagedCount(self: *const Self) usize { return self.staged_count; }
    pub fn publishedCount(self: *const Self) usize { return self.published_count_; }
    pub fn count(self: *const Self) usize { return self.published_count_; }
    pub fn slotState(self: *const Self, index: usize) SlotState {
        std.debug.assert(index < capacity);
        return self.slots[index].state;
    }
    pub fn stagedAt(self: *const Self, index: usize) ?Capture {
        return self.findAt(.staged, index);
    }
    pub fn publishedAt(self: *const Self, index: usize) ?Capture {
        return self.findAt(.published, index);
    }

    fn findAt(self: *const Self, state: SlotState, wanted: usize) ?Capture {
        var seen: usize = 0;
        for (self.slots) |slot| {
            if (slot.state != state) continue;
            if (seen == wanted) return slot.capture;
            seen += 1;
        }
        return null;
    }

    fn wasDropped(self: *const Self, grid_id: i64) bool {
        for (self.dropped_grids[0..self.dropped_count]) |id| {
            if (id == grid_id) return true;
        }
        return false;
    }

    fn markDropped(self: *Self, grid_id: i64) void {
        if (self.wasDropped(grid_id)) return;
        if (self.dropped_count < max_retained_grids) {
            self.dropped_grids[self.dropped_count] = grid_id;
            self.dropped_count += 1;
        }
    }

    fn dropStagedGrid(self: *Self, grid_id: i64) void {
        for (&self.slots) |*slot| {
            if (slot.state == .staged and slot.capture.grid_id == grid_id) {
                slot.state = .free;
                slot.staged_from_published = false;
                slot.dropped_pending = false;
                self.staged_count -= 1;
            }
        }
        self.markDropped(grid_id);
    }

    fn findFree(self: *Self) ?usize {
        var i: usize = 0;
        while (i < capacity) : (i += 1) {
            const index = (self.next_slot + i) % capacity;
            if (self.slots[index].state == .free) {
                self.next_slot = (index + 1) % capacity;
                return index;
            }
        }
        return null;
    }

    /// Start a flush bracket. Any stage left by a previous uncommitted
    /// bracket is discarded; published slots remain untouched.
    pub fn beginFlush(self: *Self) void {
        if (self.flush_open) {
            self.abort();
        } else {
            for (&self.slots) |*slot| {
                if (slot.state == .staged) {
                    slot.state = .free;
                    slot.staged_from_published = false;
                }
            }
        }
        self.staged_count = 0;
        self.dropped_count = 0;
        self.flush_open = true;
    }

    /// Stage metadata and reserve one application-owned storage slot. A null
    /// result means this grid was dropped for the bracket.
    pub fn stage(self: *Self, capture: Capture) ?usize {
        if (!self.flush_open or self.wasDropped(capture.grid_id)) return null;
        var held: usize = 0;
        for (self.slots) |slot| {
            // The published set belongs to the previous commit and is
            // released by commit; only this bracket's stage is depth-limited.
            if (slot.state == .staged and slot.capture.grid_id == capture.grid_id) held += 1;
        }
        if (held >= retention_depth_rows) {
            // Keep the newest band.  This is normal depth clamping, not an
            // overflow: only exhaustion of the fixed ring drops a grid.
            for (&self.slots) |*slot| {
                if (slot.state == .staged and slot.capture.grid_id == capture.grid_id) {
                    slot.state = .free;
                    slot.staged_from_published = false;
                    self.staged_count -= 1;
                    break;
                }
            }
        }
        const index = self.findFree() orelse {
            self.dropStagedGrid(capture.grid_id);
            return null;
        };
        // The application owns vertex storage with the same fixed indexing;
        // pin the metadata to the slot selected by the bookkeeping ring.
        var pinned = capture;
        pinned.storage_slot = @intCast(index);
        self.slots[index] = .{ .state = .staged, .capture = pinned, .staged_from_published = false };
        self.staged_count += 1;
        return index;
    }

    /// Restage one existing capture without copying its vertex payload. A
    /// published capture is remembered for abort so the shifted stage can be
    /// discarded while the prior publication remains available.
    pub fn restageSlot(self: *Self, index: usize) bool {
        if (!self.flush_open or index >= capacity) return false;
        const slot = &self.slots[index];
        switch (slot.state) {
            .published => {
                slot.rollback_capture = slot.capture;
                slot.staged_from_published = true;
                slot.state = .staged;
                self.published_count_ -= 1;
                self.staged_count += 1;
                return true;
            },
            .staged => return true,
            .free => return false,
        }
    }

    pub fn updateTargetRow(self: *Self, index: usize, target_row: i32) bool {
        if (index >= capacity) return false;
        if (self.slots[index].state == .free) return false;
        self.slots[index].capture.target_row = target_row;
        return true;
    }

    pub fn captureAt(self: *const Self, index: usize) ?Capture {
        if (index >= capacity or self.slots[index].state == .free) return null;
        return self.slots[index].capture;
    }

    pub fn droppedPendingAt(self: *const Self, index: usize) bool {
        if (index >= capacity) return false;
        return self.slots[index].state == .staged and self.slots[index].dropped_pending;
    }

    /// The capture a PAINT may draw for this slot right now. Published slots
    /// expose their capture; a carried row restaged by an open bracket exposes
    /// its pre-shift rollback capture, because on-screen content is still the
    /// previous commit until the bracket publishes. Fresh stages are invisible
    /// to paints until commit.
    pub fn paintViewAt(self: *const Self, index: usize) ?Capture {
        if (index >= capacity) return null;
        const slot = &self.slots[index];
        return switch (slot.state) {
            .published => slot.capture,
            .staged => if (slot.staged_from_published) slot.rollback_capture else null,
            .free => null,
        };
    }

    /// Publish staged captures while retaining published captures belonging to
    /// grids that did not participate in this bracket.
    pub fn commit(self: *Self) bool {
        if (!self.flush_open) return false;
        for (&self.slots) |*slot| {
            if (slot.state == .staged) {
                if (slot.dropped_pending) {
                    slot.state = .free;
                    slot.staged_from_published = false;
                    slot.dropped_pending = false;
                    continue;
                }
                slot.state = .published;
                slot.staged_from_published = false;
                self.published_count_ += 1;
            }
        }
        self.staged_count = 0;
        self.flush_open = false;
        self.replay_count = 0;
        return self.published_count_ != 0;
    }

    /// Abort the bracket, retaining replay requests supplied by the caller.
    pub fn abort(self: *Self) void {
        for (&self.slots) |*slot| {
            if (slot.state != .staged) continue;
            if (slot.staged_from_published) {
                slot.capture = slot.rollback_capture;
                slot.state = .published;
                slot.staged_from_published = false;
                slot.dropped_pending = false;
                self.published_count_ += 1;
            } else {
                slot.state = .free;
                slot.staged_from_published = false;
                slot.dropped_pending = false;
            }
        }
        self.staged_count = 0;
        self.flush_open = false;
    }

    pub fn clearPublished(self: *Self) void {
        for (&self.slots) |*slot| {
            if (slot.state == .published) {
                slot.state = .free;
                slot.staged_from_published = false;
            }
        }
        self.published_count_ = 0;
    }

    pub fn publishedCountForGrid(self: *const Self, grid_id: i64) usize {
        var n: usize = 0;
        for (self.slots) |slot| {
            if (slot.state == .published and slot.capture.grid_id == grid_id) n += 1;
        }
        return n;
    }

    pub fn prunePublished(self: *Self, predicate: anytype) usize {
        var removed: usize = 0;
        for (&self.slots) |*slot| {
            if (slot.state == .published and predicate(slot.capture)) {
                slot.state = .free;
                slot.staged_from_published = false;
                removed += 1;
            }
        }
        self.published_count_ -= removed;
        return removed;
    }

    /// Release one staged slot by its stable ring index (per-grid fail-closed
    /// paths free exactly what they staged instead of aborting the bracket).
    /// A carried publication is not freed here: it flips to dropped_pending so
    /// commit finalizes the removal while abort can still restore it.
    pub fn releaseStagedSlot(self: *Self, index: usize) bool {
        if (index >= capacity or self.slots[index].state != .staged) return false;
        if (self.slots[index].staged_from_published) {
            self.slots[index].dropped_pending = true;
            return true;
        }
        self.slots[index].state = .free;
        self.staged_count -= 1;
        return true;
    }

    /// Remove one published slot by its stable ring index.
    pub fn prunePublishedSlot(self: *Self, index: usize) bool {
        if (index >= capacity or self.slots[index].state != .published) return false;
        self.slots[index].state = .free;
        self.slots[index].staged_from_published = false;
        self.published_count_ -= 1;
        return true;
    }

    pub fn takeDroppedGrid(self: *Self) ?i64 {
        if (self.dropped_count == 0) return null;
        const id = self.dropped_grids[0];
        std.mem.copyForwards(i64, self.dropped_grids[0 .. self.dropped_count - 1], self.dropped_grids[1..self.dropped_count]);
        self.dropped_count -= 1;
        return id;
    }

    pub fn queueReplay(self: *Self, step: ReplayStep) void {
        if (self.replay_count == max_replay_steps) {
            std.mem.copyForwards(ReplayStep, self.replay[0 .. max_replay_steps - 1], self.replay[1..]);
            self.replay_count -= 1;
        }
        self.replay[self.replay_count] = step;
        self.replay_count += 1;
    }
    pub fn replayCount(self: *const Self) usize { return self.replay_count; }
    pub fn replayAt(self: *const Self, index: usize) ?ReplayStep {
        if (index >= self.replay_count) return null;
        return self.replay[index];
    }
    pub fn clearReplay(self: *Self) void { self.replay_count = 0; }
};

pub const RetentionRing = Ring;
pub const RetainedRow = Capture;

test "capacity and overflow drop per grid" {
    var ring = Ring.init(); ring.beginFlush();
    var grid: usize = 0;
    while (grid < capacity / retention_depth_rows) : (grid += 1) {
        var row: usize = 0;
        while (row < retention_depth_rows) : (row += 1) {
            try std.testing.expect(ring.stage(.{ .source_row = @intCast(row), .target_row = 0, .grid_id = @intCast(grid), .cell_height = 20, .vertex_count = 2, .storage_slot = @intCast(row) }) != null);
        }
    }
    try std.testing.expect(ring.stage(.{ .source_row = 9, .target_row = 0, .grid_id = 99, .cell_height = 20, .vertex_count = 2, .storage_slot = 9 }) == null);
    try std.testing.expectEqual(@as(usize, capacity), ring.stagedCount());
    try std.testing.expectEqual(@as(?i64, 99), ring.takeDroppedGrid());
}

test "staged commit publication, prune and clear" {
    var ring = Ring.init(); ring.beginFlush();
    _ = ring.stage(.{ .source_row = 1, .target_row = 2, .grid_id = 3, .cell_height = 18, .vertex_count = 4, .storage_slot = 2 });
    try std.testing.expectEqual(@as(usize, 0), ring.publishedCount());
    try std.testing.expect(ring.commit());
    try std.testing.expectEqual(@as(usize, 1), ring.publishedCountForGrid(3));
    try std.testing.expectEqual(@as(usize, 1), ring.prunePublished(struct { fn f(c: Capture) bool { return c.target_row == 2; } }.f));
    ring.clearPublished();
    try std.testing.expectEqual(@as(usize, 0), ring.publishedCount());
}

test "begin flush discards uncommitted stage and abort replay survives" {
    var ring = Ring.init(); ring.beginFlush();
    _ = ring.stage(.{ .source_row = 1, .target_row = 1, .grid_id = 2, .cell_height = 1, .vertex_count = 1, .storage_slot = 0 });
    ring.queueReplay(.{ .grid_id = 2, .rows_delta = 1 });
    ring.abort();
    try std.testing.expectEqual(@as(usize, 0), ring.stagedCount());
    try std.testing.expectEqual(@as(usize, 1), ring.replayCount());
    ring.beginFlush();
    try std.testing.expectEqual(@as(usize, 0), ring.stagedCount());
    _ = ring.stage(.{ .source_row = 1, .target_row = 0, .grid_id = 2, .cell_height = 1, .vertex_count = 1, .storage_slot = 0 });
    try std.testing.expect(ring.commit());
    try std.testing.expectEqual(@as(usize, 0), ring.replayCount());
}

test "restaged rows accumulate across commits and preserve untouched grids" {
    var ring = Ring.init();
    var step: usize = 0;
    while (step < retention_depth_rows + 3) : (step += 1) {
        ring.beginFlush();
        for (0..capacity) |index| {
            if (ring.slotState(index) != .published) continue;
            const capture = ring.captureAt(index) orelse continue;
            if (capture.grid_id != 7) continue;
            try std.testing.expect(ring.restageSlot(index));
            const shifted = capture.target_row - 1;
            try std.testing.expect(ring.updateTargetRow(index, shifted));
            if (shifted <= -@as(i32, @intCast(retention_depth_rows))) {
                try std.testing.expect(ring.releaseStagedSlot(index));
            }
        }
        _ = ring.stage(.{
            .source_row = @intCast(step),
            .target_row = 0,
            .grid_id = 7,
            .cell_height = 20,
            .vertex_count = 2,
            .storage_slot = 0,
        });
        if (step == 0) {
            _ = ring.stage(.{
                .source_row = 40,
                .target_row = 40,
                .grid_id = 8,
                .cell_height = 20,
                .vertex_count = 2,
                .storage_slot = 0,
            });
        }
        try std.testing.expect(ring.commit());
    }

    try std.testing.expectEqual(@as(usize, retention_depth_rows), ring.publishedCountForGrid(7));
    try std.testing.expectEqual(@as(usize, 1), ring.publishedCountForGrid(8));
    var seen = [_]bool{false} ** retention_depth_rows;
    for (0..capacity) |index| {
        if (ring.slotState(index) != .published) continue;
        const capture = ring.captureAt(index) orelse continue;
        if (capture.grid_id != 7) continue;
        try std.testing.expect(capture.target_row <= 0);
        try std.testing.expect(capture.target_row >= -@as(i32, @intCast(retention_depth_rows - 1)));
        seen[@intCast(-capture.target_row)] = true;
    }
    for (seen) |present| {
        try std.testing.expect(present);
    }
}

test "restage abort restores the prior publication while losing the shifted stage" {
    var ring = Ring.init();
    ring.beginFlush();
    _ = ring.stage(.{
        .source_row = 1,
        .target_row = 0,
        .grid_id = 3,
        .cell_height = 20,
        .vertex_count = 2,
        .storage_slot = 0,
    });
    try std.testing.expect(ring.commit());

    ring.beginFlush();
    for (0..capacity) |index| {
        if (ring.slotState(index) != .published) continue;
        const capture = ring.captureAt(index) orelse continue;
        if (capture.grid_id != 3) continue;
        try std.testing.expect(ring.restageSlot(index));
        try std.testing.expect(ring.updateTargetRow(index, capture.target_row - 1));
    }
    ring.abort();
    try std.testing.expectEqual(@as(usize, 1), ring.publishedCountForGrid(3));
    for (0..capacity) |index| {
        if (ring.slotState(index) != .published) continue;
        const capture = ring.captureAt(index) orelse continue;
        if (capture.grid_id == 3) try std.testing.expectEqual(@as(i32, 0), capture.target_row);
    }
}
