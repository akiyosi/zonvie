//! Which parts of the main view a frame repaints. The commits since the last
//! frame name surface rows (Pending); the frames a back buffer has missed
//! name more (History, by EGL buffer age). Anything no row expresses makes
//! the frame whole. Pure; the painter folds the spans into the core's damage
//! bands (damage_bands.zig).

const std = @import("std");
const core = @import("zonvie_core");

pub const Band = core.damage_bands.Band;

/// Spans one frame may owe before it is drawn whole instead.
pub const max_spans = 32;
/// Bands one frame draws; damage_bands.bands lets the last absorb the rest.
pub const max_bands = 8;
/// Back buffers older than this are redrawn whole.
pub const max_age = 4;

/// What the main view owes: surface rows in view px, or everything.
pub const Pending = struct {
    full: bool = true,
    spans: [max_spans]Band = undefined,
    n: usize = 0,

    pub fn markFull(self: *Pending) void {
        self.full = true;
        self.n = 0;
    }

    /// Rows [top_px, bottom_px) of the view; an empty span owes nothing.
    pub fn add(self: *Pending, top_px: i32, bottom_px: i32) void {
        if (self.full or bottom_px <= top_px) return;
        if (self.n == max_spans) return self.markFull();
        self.spans[self.n] = .{ .top_px = top_px, .bottom_px = bottom_px };
        self.n += 1;
    }

    pub fn addAll(self: *Pending, spans: []const Band) void {
        for (spans) |s| self.add(s.top_px, s.bottom_px);
    }

    pub fn isEmpty(self: *const Pending) bool {
        return !self.full and self.n == 0;
    }

    /// What is owed, leaving nothing owed.
    pub fn take(self: *Pending) Pending {
        const out = self.*;
        self.* = .{ .full = false };
        return out;
    }
};

/// The bands the frames last drawn changed, newest first; null for a frame
/// that changed everything. A frame drawn whole only to catch an old buffer
/// up changed its own bands alone.
pub const History = struct {
    frames: [max_age]?Frame = @splat(null),
    count: usize = 0,

    const Frame = struct { bands: [max_bands]Band = undefined, n: usize = 0 };

    pub fn pushFull(self: *History) void {
        self.push(null);
    }

    pub fn pushBands(self: *History, bands: []const Band) void {
        var f: Frame = .{ .n = bands.len };
        @memcpy(f.bands[0..bands.len], bands);
        self.push(f);
    }

    fn push(self: *History, f: ?Frame) void {
        std.mem.copyBackwards(?Frame, self.frames[1..], self.frames[0 .. max_age - 1]);
        self.frames[0] = f;
        self.count = @min(self.count + 1, max_age);
    }

    /// Adds to `out` what the frames drawn since a back buffer `age` frames
    /// old changed: the age - 1 newest. False when that buffer must be
    /// redrawn whole: its age is unknown (0), past the history (or there is
    /// none), or a frame since was whole.
    pub fn catchUp(self: *const History, age: u32, out: *Pending) bool {
        if (age == 0 or self.count == 0 or age - 1 > self.count) return false;
        for (self.frames[0 .. age - 1]) |f| {
            const frame = f orelse return false;
            out.addAll(frame.bands[0..frame.n]);
        }
        return !out.full;
    }
};

const testing = std.testing;

test "a fresh pending is whole, and take leaves nothing owed" {
    var p: Pending = .{};
    try testing.expect(p.take().full);
    try testing.expect(p.isEmpty());
    p.add(10, 20);
    const t = p.take();
    try testing.expect(!t.full);
    try testing.expectEqual(@as(usize, 1), t.n);
    try testing.expect(p.isEmpty());
}

test "too many spans make the frame whole" {
    var p: Pending = .{ .full = false };
    for (0..max_spans) |i| p.add(@intCast(i * 10), @intCast(i * 10 + 5));
    try testing.expect(!p.full);
    p.add(1000, 1010);
    try testing.expect(p.full);
    try testing.expectEqual(@as(usize, 0), p.n);
}

test "an empty span owes nothing" {
    var p: Pending = .{ .full = false };
    p.add(10, 10);
    try testing.expect(p.isEmpty());
}

test "a buffer one frame old needs only this frame's damage" {
    var h: History = .{};
    h.pushBands(&.{.{ .top_px = 0, .bottom_px = 10 }});
    var p: Pending = .{ .full = false };
    try testing.expect(h.catchUp(1, &p));
    try testing.expect(p.isEmpty());
}

test "an older buffer takes the frames it missed" {
    var h: History = .{};
    h.pushBands(&.{.{ .top_px = 0, .bottom_px = 10 }});
    h.pushBands(&.{.{ .top_px = 50, .bottom_px = 60 }});
    var p: Pending = .{ .full = false };
    try testing.expect(h.catchUp(3, &p));
    try testing.expectEqual(@as(usize, 2), p.n);
    try testing.expectEqual(@as(i32, 50), p.spans[0].top_px);
    try testing.expectEqual(@as(i32, 0), p.spans[1].top_px);
}

test "an unknown, too old, or wholly redrawn-since buffer is redrawn whole" {
    var h: History = .{};
    var p: Pending = .{ .full = false };
    try testing.expect(!h.catchUp(0, &p));
    try testing.expect(!h.catchUp(1, &p));
    h.pushFull();
    try testing.expect(h.catchUp(1, &p));
    h.pushBands(&.{.{ .top_px = 0, .bottom_px = 10 }});
    try testing.expect(!h.catchUp(3, &p));
    try testing.expect(h.catchUp(2, &p));
    for (0..max_age) |_| h.pushFull();
    try testing.expect(!h.catchUp(max_age + 1, &p));
}
