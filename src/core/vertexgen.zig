const std = @import("std");

/// Persistent buffers for HarfBuzz shaping output.
/// Reuse across calls to avoid per-call heap allocations on the hot path.
pub const ShapingBuffers = struct {
    glyph_ids: std.ArrayListUnmanaged(u32) = .empty,
    clusters: std.ArrayListUnmanaged(u32) = .empty,
    x_adv: std.ArrayListUnmanaged(i32) = .empty,
    y_adv: std.ArrayListUnmanaged(i32) = .empty,
    x_off: std.ArrayListUnmanaged(i32) = .empty,
    y_off: std.ArrayListUnmanaged(i32) = .empty,

    /// Ensure all buffers have at least `cap` capacity.
    pub fn ensureCapacity(self: *ShapingBuffers, alloc: std.mem.Allocator, cap: usize) !void {
        try self.glyph_ids.ensureTotalCapacity(alloc, cap);
        try self.clusters.ensureTotalCapacity(alloc, cap);
        try self.x_adv.ensureTotalCapacity(alloc, cap);
        try self.y_adv.ensureTotalCapacity(alloc, cap);
        try self.x_off.ensureTotalCapacity(alloc, cap);
        try self.y_off.ensureTotalCapacity(alloc, cap);
    }

    /// Set the logical length of all buffers (must have capacity).
    pub fn setLen(self: *ShapingBuffers, n: usize) void {
        self.glyph_ids.items.len = n;
        self.clusters.items.len = n;
        self.x_adv.items.len = n;
        self.y_adv.items.len = n;
        self.x_off.items.len = n;
        self.y_off.items.len = n;
    }

    /// Free all backing memory.
    pub fn deinit(self: *ShapingBuffers, alloc: std.mem.Allocator) void {
        self.glyph_ids.deinit(alloc);
        self.clusters.deinit(alloc);
        self.x_adv.deinit(alloc);
        self.y_adv.deinit(alloc);
        self.x_off.deinit(alloc);
        self.y_off.deinit(alloc);
    }
};

pub fn fixed26_6ToPx(v: i32) f32 {
    return @as(f32, @floatFromInt(v)) / 64.0;
}
