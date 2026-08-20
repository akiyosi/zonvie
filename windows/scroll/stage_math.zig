//! Pure flush-local stage accumulation for the smooth-scroll semantic bridge.
//!
//! Contract: .agents/docs/windows-smooth-scroll-a2-discrete-settle.md
//! (「A0 拡張 — A2 publication」). One flush may carry per-grid deltas for
//! several external grids: the grid owned by the active A1 session stages as
//! an a1_session entry with the session's identity (exactly the previous
//! single-slot behavior), while every other external grid stages as an
//! a2_settle entry with session_generation 0. Non-external grids (main grid 1
//! and the reserved negative ids) are ignored.
//!
//! std-only: runs as a native unit test on any host. No allocation anywhere;
//! callbacks.zig keeps one global instance touched only by the core thread
//! between on_flush_begin and on_flush_end.

const std = @import("std");
const types = @import("types.zig");

/// Distinct grids one flush can stage (A1 slot included). Excess A2 deltas
/// are counted in dropped_a2 and discarded; the A1 slot is staged at flush
/// begin and can never be displaced by overflow.
pub const stage_capacity = 8;

pub const StageEntry = struct {
    kind: types.RecordKind,
    grid_id: i64,
    /// a1_session: the active session generation. a2_settle: always 0.
    session_generation: u64,
    /// a1_session: surface incarnation snapshotted at flush begin.
    /// a2_settle: 0 here; the commit loop resolves the window's current
    /// incarnation under app.mu at commit time.
    surface_incarnation: u64,
    rows_delta: i32,
};

pub const FlushStage = struct {
    entries: [stage_capacity]StageEntry = undefined,
    len: usize = 0,
    /// True when entries[0] is the active A1 session's slot. The slot exists
    /// from flush begin even while its delta is still 0, preserving the
    /// original single-slot stage semantics.
    a1_active: bool = false,
    /// A2 deltas dropped because the stage was full. Reported via applog by
    /// the consumer; never affects the A1 slot or the flush itself.
    dropped_a2: u32 = 0,

    /// Reset for a new flush and snapshot the active A1 session (if any)
    /// into slot 0.
    pub fn beginFlush(self: *FlushStage, session: ?types.ScrollSessionId) void {
        self.* = .{};
        if (session) |s| {
            self.entries[0] = .{
                .kind = .a1_session,
                .grid_id = s.surface.grid_id,
                .session_generation = s.generation,
                .surface_incarnation = s.surface.incarnation,
                .rows_delta = 0,
            };
            self.len = 1;
            self.a1_active = true;
        }
    }

    /// Accumulate one on_grid_scroll notification.
    /// The A1 session's grid keeps its original routing (checked first, before
    /// any other filter, exactly as the single-slot stage did). Everything
    /// else stages as an A2 settle delta unless it is a non-external grid.
    pub fn addGridScroll(self: *FlushStage, grid_id: i64, rows_delta: i32) void {
        if (self.a1_active and grid_id == self.entries[0].grid_id) {
            self.entries[0].rows_delta +|= rows_delta;
            return;
        }
        // Non-external grids: main grid 1 and the reserved negative ids
        // (cmdline / popupmenu / messages / msg_history) are ignored, never
        // mixed-fatal.
        if (grid_id <= 1) return;
        if (rows_delta == 0) return;
        var i: usize = if (self.a1_active) 1 else 0;
        while (i < self.len) : (i += 1) {
            if (self.entries[i].grid_id == grid_id) {
                self.entries[i].rows_delta +|= rows_delta;
                return;
            }
        }
        if (self.len == stage_capacity) {
            self.dropped_a2 +%= 1;
            return;
        }
        self.entries[self.len] = .{
            .kind = .a2_settle,
            .grid_id = grid_id,
            .session_generation = 0,
            .surface_incarnation = 0,
            .rows_delta = rows_delta,
        };
        self.len += 1;
    }

    /// The A1 session slot staged at flush begin, or null when no session
    /// was active. A zero rows_delta is still returned; the commit loop keeps
    /// its original "delta != 0" gate.
    pub fn a1Entry(self: *const FlushStage) ?StageEntry {
        if (!self.a1_active) return null;
        return self.entries[0];
    }

    /// The accumulated A2 settle delta staged for grid_id, or null when the
    /// grid staged nothing (or only owned the A1 slot).
    pub fn a2DeltaForGrid(self: *const FlushStage, grid_id: i64) ?i32 {
        var i: usize = if (self.a1_active) 1 else 0;
        while (i < self.len) : (i += 1) {
            if (self.entries[i].grid_id == grid_id) return self.entries[i].rows_delta;
        }
        return null;
    }
};

test "A1 slot staged at begin, accumulates only its grid, others become A2" {
    var stage: FlushStage = .{};
    stage.beginFlush(.{ .generation = 7, .surface = .{ .grid_id = 5, .incarnation = 3 } });

    stage.addGridScroll(5, 1);
    stage.addGridScroll(1, 10); // main grid: ignored
    stage.addGridScroll(6, 2);
    stage.addGridScroll(5, -3);
    stage.addGridScroll(6, 1);

    const a1 = stage.a1Entry().?;
    try std.testing.expectEqual(types.RecordKind.a1_session, a1.kind);
    try std.testing.expectEqual(@as(i64, 5), a1.grid_id);
    try std.testing.expectEqual(@as(u64, 7), a1.session_generation);
    try std.testing.expectEqual(@as(u64, 3), a1.surface_incarnation);
    try std.testing.expectEqual(@as(i32, -2), a1.rows_delta);

    try std.testing.expectEqual(@as(i32, 3), stage.a2DeltaForGrid(6).?);
    try std.testing.expect(stage.a2DeltaForGrid(5) == null); // A1 slot, not A2
    try std.testing.expect(stage.a2DeltaForGrid(1) == null);
    try std.testing.expectEqual(@as(u32, 0), stage.dropped_a2);
}

test "A2 tagging without an active session" {
    var stage: FlushStage = .{};
    stage.beginFlush(null);
    try std.testing.expect(stage.a1Entry() == null);

    stage.addGridScroll(3, 1);
    stage.addGridScroll(3, 2);
    stage.addGridScroll(4, -1);

    try std.testing.expectEqual(@as(i32, 3), stage.a2DeltaForGrid(3).?);
    try std.testing.expectEqual(@as(i32, -1), stage.a2DeltaForGrid(4).?);
    try std.testing.expectEqual(@as(usize, 2), stage.len);
    try std.testing.expectEqual(types.RecordKind.a2_settle, stage.entries[0].kind);
    try std.testing.expectEqual(@as(u64, 0), stage.entries[0].session_generation);
}

test "non-external grids are ignored" {
    var stage: FlushStage = .{};
    stage.beginFlush(null);
    stage.addGridScroll(1, 5); // main grid
    stage.addGridScroll(-100, 1); // cmdline
    stage.addGridScroll(-101, 1); // popupmenu
    stage.addGridScroll(-102, 1); // messages
    stage.addGridScroll(-103, 1); // msg_history
    try std.testing.expectEqual(@as(usize, 0), stage.len);
    try std.testing.expectEqual(@as(u32, 0), stage.dropped_a2);
}

test "capacity overflow drops excess A2 entries and never the A1 slot" {
    var stage: FlushStage = .{};
    stage.beginFlush(.{ .generation = 1, .surface = .{ .grid_id = 100, .incarnation = 1 } });

    // 7 distinct A2 grids fill the stage next to the A1 slot.
    var grid: i64 = 2;
    while (grid < 9) : (grid += 1) stage.addGridScroll(grid, 1);
    try std.testing.expectEqual(@as(usize, stage_capacity), stage.len);

    // A new distinct grid overflows and is dropped...
    stage.addGridScroll(9, 4);
    try std.testing.expectEqual(@as(u32, 1), stage.dropped_a2);
    try std.testing.expect(stage.a2DeltaForGrid(9) == null);

    // ...but already-staged grids and the A1 slot keep accumulating.
    stage.addGridScroll(2, 1);
    stage.addGridScroll(100, 3);
    try std.testing.expectEqual(@as(i32, 2), stage.a2DeltaForGrid(2).?);
    const a1 = stage.a1Entry().?;
    try std.testing.expectEqual(@as(i32, 3), a1.rows_delta);
    try std.testing.expectEqual(@as(u64, 1), a1.session_generation);
}

test "zero-delta notifications never occupy an A2 slot" {
    var stage: FlushStage = .{};
    stage.beginFlush(null);
    stage.addGridScroll(2, 0);
    try std.testing.expectEqual(@as(usize, 0), stage.len);
    try std.testing.expect(stage.a2DeltaForGrid(2) == null);
}
