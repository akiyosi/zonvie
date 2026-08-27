//! Shared identity and record types for the Windows smooth-scroll pipeline.

const std = @import("std");

/// Logical identity of one external grid surface. The coordinator never owns
/// a TBS pointer or HWND; it addresses surfaces through this token only.
pub const SurfaceToken = struct {
    grid_id: i64,

    /// Increments on every external window creation. Prevents applying stale
    /// callbacks and records to a new surface when a grid ID or HWND is
    /// reused after window destruction.
    incarnation: u64,

    pub fn eql(a: SurfaceToken, b: SurfaceToken) bool {
        return a.grid_id == b.grid_id and a.incarnation == b.incarnation;
    }
};

pub const ScrollSessionId = struct {
    generation: u64,
    surface: SurfaceToken,
};

/// Which presentation path owns a semantic record.
pub const RecordKind = enum {
    /// Contract A1: bound to a live Direct Manipulation scroll session.
    a1_session,
    /// External displacement seed; session-independent, so
    /// session_generation is 0 and FIFO consumption happens at the owning
    /// window's outermost paint.
    a2_settle,
    /// Contract B: main-composite ease record (grid >= 2 inside the main
    /// window); session-independent (session_generation 0), drained at the
    /// main window's paint barrier.
    b_ease,
};

/// Semantic screen-row movement bound to a TBS commit revision.
/// Stored in the target external TBS's ring, protected by that TBS's
/// rotation_mu for every access.
pub const SemanticCommitRecord = struct {
    kind: RecordKind = .a1_session,
    session_generation: u64,
    surface: SurfaceToken,
    commit_rev: u64,

    /// Positive means content moved up on screen (same sign convention as
    /// on_grid_scroll's rows_delta).
    rows_delta: i32,

    /// Whether rows_delta has been folded into the coordinator's
    /// acknowledged_rows. The record itself stays in the ring until the
    /// revision is published (Present + epoch Commit succeeded).
    ack_delivered: bool = false,
};

pub const MaxSemanticCommits = 32;

/// Direct Manipulation viewport status, mirroring DIRECTMANIPULATION_STATUS.
pub const DmStatus = enum(u32) {
    building = 0,
    enabled = 1,
    disabled = 2,
    running = 3,
    inertia = 4,
    ready = 5,
    suspended = 6,
};

/// Latest Direct Manipulation state. The DM delegate callback overwrites this
/// mailbox and posts a coalesced WM_APP_DM_UPDATE; only the UI thread reads it.
pub const DmSnapshot = struct {
    generation: u64,
    status: DmStatus,
    output_y: f64,
    qpc: i64,
};

/// Fixed-capacity FIFO ring. No allocation; safe on flush and paint paths.
pub fn FixedRing(comptime T: type, comptime capacity: usize) type {
    return struct {
        buf: [capacity]T = undefined,
        head: usize = 0,
        len: usize = 0,

        const Self = @This();

        pub fn count(self: *const Self) usize {
            return self.len;
        }

        pub fn isEmpty(self: *const Self) bool {
            return self.len == 0;
        }

        pub fn isFull(self: *const Self) bool {
            return self.len == capacity;
        }

        /// Returns false when full; the caller decides the fail-closed policy
        /// (Contract A: stop the scroll session, never abort the flush).
        pub fn push(self: *Self, item: T) bool {
            if (self.len == capacity) return false;
            self.buf[(self.head + self.len) % capacity] = item;
            self.len += 1;
            return true;
        }

        pub fn front(self: *Self) ?*T {
            if (self.len == 0) return null;
            return &self.buf[self.head];
        }

        pub fn popFront(self: *Self) ?T {
            if (self.len == 0) return null;
            const item = self.buf[self.head];
            self.head = (self.head + 1) % capacity;
            self.len -= 1;
            return item;
        }

        /// Pointer to the i-th oldest element. Asserts i < count().
        pub fn at(self: *Self, i: usize) *T {
            std.debug.assert(i < self.len);
            return &self.buf[(self.head + i) % capacity];
        }

        pub fn clear(self: *Self) void {
            self.head = 0;
            self.len = 0;
        }
    };
}

test "FixedRing FIFO order, capacity, and wraparound" {
    var ring: FixedRing(i32, 3) = .{};
    try std.testing.expect(ring.isEmpty());
    try std.testing.expect(ring.push(1));
    try std.testing.expect(ring.push(2));
    try std.testing.expect(ring.push(3));
    try std.testing.expect(ring.isFull());
    try std.testing.expect(!ring.push(4));
    try std.testing.expectEqual(@as(i32, 1), ring.popFront().?);
    try std.testing.expect(ring.push(4));
    try std.testing.expectEqual(@as(i32, 2), ring.front().?.*);
    try std.testing.expectEqual(@as(i32, 3), ring.at(1).*);
    try std.testing.expectEqual(@as(i32, 2), ring.popFront().?);
    try std.testing.expectEqual(@as(i32, 3), ring.popFront().?);
    try std.testing.expectEqual(@as(i32, 4), ring.popFront().?);
    try std.testing.expect(ring.popFront() == null);
}

test "SurfaceToken equality covers incarnation" {
    const a: SurfaceToken = .{ .grid_id = 5, .incarnation = 1 };
    const b: SurfaceToken = .{ .grid_id = 5, .incarnation = 2 };
    const c: SurfaceToken = .{ .grid_id = 5, .incarnation = 1 };
    try std.testing.expect(!a.eql(b));
    try std.testing.expect(a.eql(c));
}
