const std = @import("std");
const c_api = @import("c_api.zig");

// C API: hbft
const hbft = @cImport({
    @cInclude("zonvie_hbft.h");
});

// You will map this to your C callbacks struct (zonvie_callbacks).
pub const AtlasEnsureGlyphFn = *const fn (
    ctx: ?*anyopaque,
    scalar: u32,
    out_entry: *c_api.GlyphEntry, // <-- match your c_api.zig struct name
) callconv(.c) i32;

/// Persistent buffers for HarfBuzz shaping output.
/// Reuse across calls to avoid per-call heap allocations on the hot path.
pub const ShapingBuffers = struct {
    glyph_ids: std.ArrayListUnmanaged(u32) = .{},
    clusters: std.ArrayListUnmanaged(u32) = .{},
    x_adv: std.ArrayListUnmanaged(i32) = .{},
    y_adv: std.ArrayListUnmanaged(i32) = .{},
    x_off: std.ArrayListUnmanaged(i32) = .{},
    y_off: std.ArrayListUnmanaged(i32) = .{},

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

fn ndc(x_px: f32, y_px: f32, drawable_w: f32, drawable_h: f32) [2]f32 {
    const nx = (x_px / drawable_w) * 2.0 - 1.0;
    const ny = 1.0 - (y_px / drawable_h) * 2.0;
    return .{ nx, ny };
}

fn rgbaFromRgb24(rgb: u32) [4]f32 {
    const r = @as(f32, @floatFromInt((rgb >> 16) & 0xFF)) / 255.0;
    const g = @as(f32, @floatFromInt((rgb >> 8) & 0xFF)) / 255.0;
    const b = @as(f32, @floatFromInt(rgb & 0xFF)) / 255.0;
    return .{ r, g, b, 1.0 };
}

/// Append 6 vertices (2 triangles) for a textured quad.
/// Uses batch addition to reduce overhead (1 capacity check instead of 6).
fn appendQuad(
    out: *std.ArrayList(c_api.Vertex),
    p0: [2]f32, p1: [2]f32, p2: [2]f32, p3: [2]f32,
    uv0: [2]f32, uv1: [2]f32, uv2: [2]f32, uv3: [2]f32,
    color: [4]f32,
) !void {
    try out.ensureUnusedCapacity(6);
    const v = out.addManyAsSliceAssumeCapacity(6);
    // Triangle 1: p0-p1-p2
    v[0] = .{ .position = p0, .texCoord = uv0, .color = color };
    v[1] = .{ .position = p1, .texCoord = uv1, .color = color };
    v[2] = .{ .position = p2, .texCoord = uv2, .color = color };
    // Triangle 2: p1-p3-p2
    v[3] = .{ .position = p1, .texCoord = uv1, .color = color };
    v[4] = .{ .position = p3, .texCoord = uv3, .color = color };
    v[5] = .{ .position = p2, .texCoord = uv2, .color = color };
}

pub const VertexGenParams = struct {
    drawable_w_px: f32,
    drawable_h_px: f32,
    cell_w_px: f32,
    cell_h_px: f32,

    // Font handle used by zonvie_hb_shape_utf32
    font: *hbft.zonvie_ft_hb_font,

    // C callback to UI side atlas
    atlas_ctx: ?*anyopaque,
    ensure_glyph: AtlasEnsureGlyphFn,
};


