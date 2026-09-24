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

/// A glyph quad's vertical extent and the texture v range it samples.
pub const GlyphSpanY = struct { y0: f32, y1: f32, v0: f32, v1: f32 };

/// Trim a box-drawing glyph (U+2500–257F) to its cell rows [top, bottom),
/// cutting the texture v range in proportion; any other glyph is returned
/// unchanged. These glyphs are drawn to join the next row's, and a font's
/// outline often overshoots the cell (Menlo's │ at 13pt: 1px above, 2px
/// below). A row redrawn under its own scissor loses that ink while a full
/// redraw kept it, so the join blended twice depending on which path drew
/// last; trimming the quad makes every path draw the same pixels.
pub fn trimBoxDrawingSpanY(scalar: u32, span: GlyphSpanY, top: f32, bottom: f32) GlyphSpanY {
    if (scalar < 0x2500 or scalar > 0x257F) return span;
    const height = span.y1 - span.y0;
    if (height <= 0) return span;
    const y0 = std.math.clamp(span.y0, top, bottom);
    const y1 = std.math.clamp(span.y1, top, bottom);
    const v_per_px = (span.v1 - span.v0) / height;
    return .{
        .y0 = y0,
        .y1 = y1,
        .v0 = span.v0 + (y0 - span.y0) * v_per_px,
        .v1 = span.v0 + (y1 - span.y0) * v_per_px,
    };
}

test "trimBoxDrawingSpanY trims box drawing only, in proportion" {
    const span = GlyphSpanY{ .y0 = 9, .y1 = 22, .v0 = 0, .v1 = 1.3 };
    const trimmed = trimBoxDrawingSpanY(0x2502, span, 10, 20);
    try std.testing.expectApproxEqAbs(@as(f32, 10), trimmed.y0, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 20), trimmed.y1, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.1), trimmed.v0, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 1.1), trimmed.v1, 0.0001);

    // Both ends of the block, and just outside it.
    try std.testing.expectApproxEqAbs(@as(f32, 10), trimBoxDrawingSpanY(0x2500, span, 10, 20).y0, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 20), trimBoxDrawingSpanY(0x257F, span, 10, 20).y1, 0.0001);
    try std.testing.expectEqual(span, trimBoxDrawingSpanY(0x24FF, span, 10, 20));
    try std.testing.expectEqual(span, trimBoxDrawingSpanY(0x2580, span, 10, 20));

    // A glyph already inside its cell is untouched.
    const inside = GlyphSpanY{ .y0 = 12, .y1 = 18, .v0 = 0.2, .v1 = 0.8 };
    try std.testing.expectEqual(inside, trimBoxDrawingSpanY(0x2502, inside, 10, 20));
}
