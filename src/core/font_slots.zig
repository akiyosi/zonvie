//! Per-grid font slots. Slot 0 is the global font and is never handed out.
//! A slot is keyed by (normalized guifont string, scale); the empty string
//! means "the global font", so a scale-only slot is re-measured whenever the
//! global font changes (global_gen).

const std = @import("std");

pub const max_slots: u32 = 64;
pub const max_guifont_bytes: usize = 512;

pub const Slot = struct {
    guifont_buf: [max_guifont_bytes]u8 = undefined,
    guifont_len: u16 = 0,
    scale: f32 = 1.0,
    cell_w_px: u32 = 0,
    cell_h_px: u32 = 0,
    refcount: u32 = 0,
    /// Table.global_gen when the frontend last measured this slot.
    global_gen: u32 = 0,
    /// The frontend holds a face for this id (between load and release).
    loaded: bool = false,

    pub fn guifont(self: *const Slot) []const u8 {
        return self.guifont_buf[0..self.guifont_len];
    }

    fn matches(self: *const Slot, guifont_str: []const u8, scale: f32) bool {
        return self.scale == scale and std.mem.eql(u8, self.guifont(), guifont_str);
    }
};

pub const Acquired = struct { font_id: u32, needs_load: bool };

pub const Table = struct {
    slots: [max_slots]Slot = [_]Slot{.{}} ** max_slots,
    global_gen: u32 = 0,

    pub fn acquire(self: *Table, guifont_str: []const u8, scale: f32) error{ SlotsFull, GuifontTooLong }!Acquired {
        if (guifont_str.len > max_guifont_bytes) return error.GuifontTooLong;
        var free: ?u32 = null;
        var i: u32 = 1;
        while (i < max_slots) : (i += 1) {
            const s = &self.slots[i];
            if ((s.refcount > 0 or s.loaded) and s.matches(guifont_str, scale)) {
                s.refcount += 1;
                const stale = !s.loaded or s.global_gen != self.global_gen;
                return .{ .font_id = i, .needs_load = stale };
            }
            if (free == null and s.refcount == 0 and !s.loaded) free = i;
        }
        const id = free orelse return error.SlotsFull;
        const s = &self.slots[id];
        s.* = .{};
        @memcpy(s.guifont_buf[0..guifont_str.len], guifont_str);
        s.guifont_len = @intCast(guifont_str.len);
        s.scale = scale;
        s.refcount = 1;
        return .{ .font_id = id, .needs_load = true };
    }

    pub fn markLoaded(self: *Table, font_id: u32, cell_w_px: u32, cell_h_px: u32) void {
        std.debug.assert(font_id != 0 and font_id < max_slots);
        const s = &self.slots[font_id];
        s.cell_w_px = cell_w_px;
        s.cell_h_px = cell_h_px;
        s.global_gen = self.global_gen;
        s.loaded = true;
    }

    /// Drop one reference. True when it was the last one: the caller then
    /// tells the frontend (on_font_slot_release) and the id becomes free.
    pub fn release(self: *Table, font_id: u32) bool {
        if (font_id == 0 or font_id >= max_slots) return false;
        const s = &self.slots[font_id];
        if (s.refcount == 0) return false;
        s.refcount -= 1;
        if (s.refcount != 0) return false;
        s.loaded = false;
        return true;
    }

    pub fn slot(self: *const Table, font_id: u32) *const Slot {
        return &self.slots[font_id];
    }

    pub fn bumpGlobalGen(self: *Table) void {
        self.global_gen +%= 1;
    }

    pub fn reset(self: *Table) void {
        self.* = .{ .global_gen = self.global_gen +% 1 };
    }
};

test "font slot dedup shares one slot and counts references" {
    var t: Table = .{};
    const a = try t.acquire("Menlo\t12", 1.0);
    try std.testing.expect(a.needs_load);
    try std.testing.expect(a.font_id != 0);
    t.markLoaded(a.font_id, 7, 15);
    const b = try t.acquire("Menlo\t12", 1.0);
    try std.testing.expectEqual(a.font_id, b.font_id);
    try std.testing.expect(!b.needs_load);
    try std.testing.expectEqual(@as(u32, 2), t.slot(a.font_id).refcount);
    const c = try t.acquire("Menlo\t12", 0.5);
    try std.testing.expect(c.font_id != a.font_id);
}

test "font slot release frees at zero and the slot is reused" {
    var t: Table = .{};
    const a = try t.acquire("A\t10", 1.0);
    t.markLoaded(a.font_id, 6, 12);
    _ = try t.acquire("A\t10", 1.0);
    try std.testing.expect(!t.release(a.font_id));
    try std.testing.expect(t.release(a.font_id));
    try std.testing.expect(!t.slot(a.font_id).loaded);
    const b = try t.acquire("B\t20", 1.0);
    try std.testing.expectEqual(a.font_id, b.font_id);
    try std.testing.expect(b.needs_load);
}

test "a global generation bump makes a loaded slot reload on next acquire" {
    var t: Table = .{};
    const a = try t.acquire("", 0.5);
    t.markLoaded(a.font_id, 4, 9);
    t.bumpGlobalGen();
    const b = try t.acquire("", 0.5);
    try std.testing.expectEqual(a.font_id, b.font_id);
    try std.testing.expect(b.needs_load);
}

test "the slot table refuses when full and never hands out slot 0" {
    var t: Table = .{};
    var buf: [16]u8 = undefined;
    var i: u32 = 1;
    while (i < max_slots) : (i += 1) {
        const name = try std.fmt.bufPrint(&buf, "F{d}", .{i});
        const got = try t.acquire(name, 1.0);
        try std.testing.expect(got.font_id != 0);
    }
    try std.testing.expectError(error.SlotsFull, t.acquire("overflow", 1.0));
    const long = [_]u8{'x'} ** (max_guifont_bytes + 1);
    try std.testing.expectError(error.GuifontTooLong, t.acquire(&long, 1.0));
}
