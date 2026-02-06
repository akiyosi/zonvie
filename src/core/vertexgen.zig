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

/// Build vertices for a text run using HarfBuzz shaping.
/// Uses persistent ShapingBuffers to avoid per-call heap allocations.
pub fn buildVerticesForTextRun(
    shaping_bufs: *ShapingBuffers,
    alloc: std.mem.Allocator,
    params: VertexGenParams,
    run: c_api.TextRun,
    // baseline in px; recommend: row*cellH + ascenderPx
    baseline_y_px: f32,
    out_main: *std.ArrayList(c_api.Vertex),
) !void {
    if (run.len == 0 or run.scalars == null) return;

    const scalar_count: usize = run.len;
    const scalars: [*]const u32 = run.scalars.?;

    // Use persistent buffers (grow as needed, never shrink within session).
    var cap: usize = @max(256, shaping_bufs.glyph_ids.capacity);
    while (true) {
        try shaping_bufs.ensureCapacity(alloc, cap);
        shaping_bufs.setLen(cap);

        var asc_26_6: i32 = 0;
        var desc_26_6: i32 = 0;
        var height_26_6: i32 = 0;

        const n_or_needed = hbft.zonvie_hb_shape_utf32(
            params.font,
            scalars,
            scalar_count,
            shaping_bufs.glyph_ids.items.ptr,
            shaping_bufs.clusters.items.ptr,
            shaping_bufs.x_adv.items.ptr,
            shaping_bufs.y_adv.items.ptr,
            shaping_bufs.x_off.items.ptr,
            shaping_bufs.y_off.items.ptr,
            cap,
            &asc_26_6,
            &desc_26_6,
            &height_26_6,
        );

        if (n_or_needed <= cap) {
            const glyph_count: usize = n_or_needed;

            var pen_x_px: f32 = @as(f32, @floatFromInt(run.col_start)) * params.cell_w_px;
            const fg = rgbaFromRgb24(run.fgRGB);

            var i: usize = 0;
            while (i < glyph_count) : (i += 1) {
                const gid: u32 = shaping_bufs.glyph_ids.items[i];

                // Ask UI-side atlas for uv/metrics
                var ge: c_api.GlyphEntry = undefined;
                const ok = params.ensure_glyph(params.atlas_ctx, gid, &ge);
                if (ok == 0) continue;

                const x_offset_px = fixed26_6ToPx(shaping_bufs.x_off.items[i]);
                const y_offset_px = fixed26_6ToPx(shaping_bufs.y_off.items[i]);

                const w = ge.bbox_size_px[0];
                const h = ge.bbox_size_px[1];
                if (w > 0 and h > 0) {
                    // Same geometry as Swift code:
                    // x0 = penX + xOffset + bboxOrigin.x
                    // y0 = (baselineY + yOffset) - (bboxOrigin.y + h)
                    const x0 = pen_x_px + x_offset_px + ge.bbox_origin_px[0];
                    const y0 = (baseline_y_px + y_offset_px) - (ge.bbox_origin_px[1] + h);
                    const x1 = x0 + w;
                    const y1 = y0 + h;

                    const p0 = ndc(x0, y0, params.drawable_w_px, params.drawable_h_px);
                    const p1 = ndc(x1, y0, params.drawable_w_px, params.drawable_h_px);
                    const p2 = ndc(x0, y1, params.drawable_w_px, params.drawable_h_px);
                    const p3 = ndc(x1, y1, params.drawable_w_px, params.drawable_h_px);

                    const uv0: [2]f32 = .{ ge.uv_min[0], ge.uv_min[1] };
                    const uv1: [2]f32 = .{ ge.uv_max[0], ge.uv_min[1] };
                    const uv2: [2]f32 = .{ ge.uv_min[0], ge.uv_max[1] };
                    const uv3: [2]f32 = .{ ge.uv_max[0], ge.uv_max[1] };

                    try appendQuad(out_main, p0, p1, p2, p3, uv0, uv1, uv2, uv3, fg);
                }

                // Cluster-based pen advance in *cells*, matching Swift logic.
                const this_cluster_raw: usize = @as(usize, @intCast(shaping_bufs.clusters.items[i]));
                const this_cluster = std.math.clamp(this_cluster_raw, 0, scalar_count);

                const next_cluster_raw: usize = if (i + 1 < glyph_count)
                    @as(usize, @intCast(shaping_bufs.clusters.items[i + 1]))
                else
                    scalar_count;

                const next_cluster = std.math.clamp(next_cluster_raw, this_cluster, scalar_count);
                const cells_consumed = next_cluster - this_cluster;

                pen_x_px += @as(f32, @floatFromInt(cells_consumed)) * params.cell_w_px;
            }

            return;
        }

        // Need bigger buffers - loop will grow capacity
        cap = n_or_needed;
    }
}

/// Legacy wrapper for backward compatibility (allocates per call).
/// Prefer using the ShapingBuffers version for hot paths.
pub fn buildVerticesForTextRunLegacy(
    alloc: std.mem.Allocator,
    params: VertexGenParams,
    run: c_api.TextRun,
    baseline_y_px: f32,
    out_main: *std.ArrayList(c_api.Vertex),
) !void {
    var bufs: ShapingBuffers = .{};
    defer bufs.deinit(alloc);
    try buildVerticesForTextRun(&bufs, alloc, params, run, baseline_y_px, out_main);
}

