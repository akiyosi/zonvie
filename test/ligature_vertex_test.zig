// Ligature vertex generation tests.
// Validates glyph quad positioning for calt/liga shaping patterns
// using mock callbacks that reproduce real JetBrains Mono behavior.
//
// Real data from JetBrains Mono (observed via [shape_dump] / [glyph_quad]):
//
//   ==  → gid=[1649, 1387]  glyph 0: bbox_w=12, ox=+3
//                             glyph 1: bbox_w=30, ox=-15 (covers both cells)
//
//   === → gid=[1649, 1649, 1388]  glyph 0,1: bbox_w=12, ox=+3 (normal =)
//                                  glyph 2:   bbox_w=47, ox=-32 (covers all 3 cells)
//
// The "last glyph draws all" calt pattern: preceding glyphs render a normal =,
// the last glyph has a wide bitmap with negative bearing that covers the entire
// ligature span.  Without suppression, the normal = quads overlap with the
// ligature quad, causing double-compositing artifacts.

const std = @import("std");
const c_api = @import("zonvie_core");
const nvim_core = c_api.nvim_core;
const flush_mod = c_api.flush_mod;

const Core = nvim_core.Core;

// ============================================================================
// Mock context
// ============================================================================

const MockCtx = struct {
    pattern: ShapePattern = .one_to_one,
    cell_px: u32 = 17, // JetBrains Mono 15pt ≈ 17px cell width
    pixel: [4]u8 = .{ 0xFF, 0xFF, 0xFF, 0xFF },

    const ShapePattern = enum {
        one_to_one,
        // Real JetBrains Mono == pattern:
        //   glyph 0: gid=1649, bbox 12px, bearing_x=+3  (normal =)
        //   glyph 1: gid=1387, bbox 30px, bearing_x=-15  (combined ==)
        calt_eq_eq,
        // Real JetBrains Mono === pattern:
        //   glyph 0: gid=1649, bbox 12px, bearing_x=+3  (normal =)
        //   glyph 1: gid=1649, bbox 12px, bearing_x=+3  (normal =)
        //   glyph 2: gid=1388, bbox 47px, bearing_x=-32  (combined ===)
        calt_eq_eq_eq,
    };
};

// ============================================================================
// Mock callbacks
// ============================================================================

fn mockShapeTextRun(
    ctx_raw: ?*anyopaque,
    _: [*]const u32,
    scalar_count: usize,
    _: u32,
    out_glyph_ids: [*]u32,
    out_clusters: [*]u32,
    out_x_advance: [*]i32,
    out_x_offset: [*]i32,
    out_y_offset: [*]i32,
    out_cap: usize,
) callconv(.c) usize {
    if (out_cap < scalar_count) return scalar_count;
    const mctx: *MockCtx = @ptrCast(@alignCast(ctx_raw));
    const adv26_6: i32 = @intCast(@as(u32, mctx.cell_px) * 64);

    for (0..scalar_count) |i| {
        out_clusters[i] = @intCast(i);
        out_x_advance[i] = adv26_6;
        out_x_offset[i] = 0;
        out_y_offset[i] = 0;
    }

    switch (mctx.pattern) {
        .one_to_one => {
            for (0..scalar_count) |i| {
                out_glyph_ids[i] = 100 + @as(u32, @intCast(i));
            }
        },
        .calt_eq_eq => {
            if (scalar_count >= 2) {
                out_glyph_ids[0] = 1649; // normal =
                out_glyph_ids[1] = 1387; // combined ==
                for (2..scalar_count) |i| out_glyph_ids[i] = 100 + @as(u32, @intCast(i));
            } else {
                for (0..scalar_count) |i| out_glyph_ids[i] = 100 + @as(u32, @intCast(i));
            }
        },
        .calt_eq_eq_eq => {
            if (scalar_count >= 3) {
                out_glyph_ids[0] = 1649; // normal =
                out_glyph_ids[1] = 1649; // normal =
                out_glyph_ids[2] = 1388; // combined ===
                for (3..scalar_count) |i| out_glyph_ids[i] = 100 + @as(u32, @intCast(i));
            } else {
                for (0..scalar_count) |i| out_glyph_ids[i] = 100 + @as(u32, @intCast(i));
            }
        },
    }
    return scalar_count;
}

fn mockRasterizeGlyphById(
    ctx_raw: ?*anyopaque,
    glyph_id: u32,
    _: u32,
    out_bitmap: *c_api.GlyphBitmap,
) callconv(.c) c_int {
    const mctx: *MockCtx = @ptrCast(@alignCast(ctx_raw));
    const cell: i32 = @intCast(mctx.cell_px);

    // Default: normal single-cell glyph
    var w: u32 = mctx.cell_px - 5; // 12px for 17px cell
    var bx: i32 = 3;

    // Combined == ligature: 30px wide, bearing_x = -15
    if (glyph_id == 1387) {
        w = @intCast(cell * 2 - 4); // 30px
        bx = -(cell - 2); // -15
    }
    // Combined === ligature: 47px wide, bearing_x = -32
    if (glyph_id == 1388) {
        w = @intCast(cell * 3 - 4); // 47px
        bx = -(cell * 2 + 2 - 4); // -32 (approx, covers 2 preceding cells)
    }

    out_bitmap.pixels = &mctx.pixel;
    out_bitmap.width = w;
    out_bitmap.height = 20;
    out_bitmap.pitch = @intCast(w);
    out_bitmap.bearing_x = bx;
    out_bitmap.bearing_y = 15;
    out_bitmap.advance_26_6 = @intCast(@as(u32, mctx.cell_px) * 64);
    out_bitmap.ascent_px = 15.0;
    out_bitmap.descent_px = 5.0;
    out_bitmap.bytes_per_pixel = 1;
    return 1;
}

fn mockRasterizeGlyph(
    ctx_raw: ?*anyopaque,
    _: u32,
    _: u32,
    out_bitmap: *c_api.GlyphBitmap,
) callconv(.c) c_int {
    const mctx: *MockCtx = @ptrCast(@alignCast(ctx_raw));
    out_bitmap.pixels = &mctx.pixel;
    out_bitmap.width = mctx.cell_px - 5;
    out_bitmap.height = 20;
    out_bitmap.pitch = @intCast(mctx.cell_px - 5);
    out_bitmap.bearing_x = 3;
    out_bitmap.bearing_y = 15;
    out_bitmap.advance_26_6 = @intCast(@as(u32, mctx.cell_px) * 64);
    out_bitmap.ascent_px = 15.0;
    out_bitmap.descent_px = 5.0;
    out_bitmap.bytes_per_pixel = 1;
    return 1;
}

fn mockAtlasUpload(_: ?*anyopaque, _: u32, _: u32, _: u32, _: u32, _: *const c_api.GlyphBitmap) callconv(.c) void {}
fn mockAtlasCreate(_: ?*anyopaque, _: u32, _: u32) callconv(.c) void {}

// ============================================================================
// Helpers
// ============================================================================

const FG: u32 = 0xFFFFFF;
const BG: u32 = 0x000000;

fn setupCore(alloc: std.mem.Allocator, mctx: *MockCtx) Core {
    var core = Core.init(alloc, .{
        .on_shape_text_run = &mockShapeTextRun,
        .on_rasterize_glyph_by_id = &mockRasterizeGlyphById,
        .on_rasterize_glyph = &mockRasterizeGlyph,
        .on_atlas_upload = &mockAtlasUpload,
        .on_atlas_create = &mockAtlasCreate,
    }, @ptrCast(mctx));
    core.drawable_w_px = 800;
    core.drawable_h_px = 600;
    core.cell_w_px = mctx.cell_px;
    core.cell_h_px = 34;
    // Populate ASCII base glyph ID table for style_index=0 (regular).
    // This enables the forward-scan suppression to detect GSUB-substituted glyphs
    // by comparing shaped glyph IDs against the base (unshaped) IDs.
    // For test purposes: '=' (0x3d) base gid = 1649, '-' (0x2d) base gid = 100+0x2d.
    // Mock calt patterns use gid=1649 for placeholder and different gids for covering.
    core.ascii_glyph_ids[0]['='] = 1649;
    core.ascii_glyph_ids[0]['-'] = 100 + '-';
    // one_to_one pattern uses gid = 100+index; set base for '=' so it matches gi=0
    // (gid=100). For calt patterns, gi=0 gid=1649 matches base → placeholder.
    // For one_to_one, gi=0 gid=100 matches base=100 → not suppressed (good: covering
    // glyph condition (c) also fails since gid=base for all glyphs).
    core.ascii_glyph_ids[0]['='] = 1649;
    // Mark '=' as a ligature trigger so the ASCII fast path is bypassed
    // and HarfBuzz shaping (mock) is used for runs containing '='.
    core.ascii_lig_triggers[0]['='] = 1;
    core.ascii_tables_valid = true;
    return core;
}

fn fillRow(core: *Core, cols: u32, scalars: []const u32) !void {
    const rc = &core.row_cells;
    try rc.ensureTotalCapacity(core.alloc, cols);
    rc.setLen(cols);
    for (0..cols) |i| {
        const s: u32 = if (i < scalars.len) scalars[i] else 0x20;
        rc.scalars.items[i] = s;
        rc.fg_rgbs.items[i] = FG;
        rc.bg_rgbs.items[i] = BG;
        rc.sp_rgbs.items[i] = 0;
        rc.grid_ids.items[i] = 1;
        rc.style_flags_arr.items[i] = 0;
        rc.overline_arr.items[i] = 0;
        rc.glow_arr.items[i] = 0;
        rc.deco_base_flags.items[i] = 0;
    }
}

fn genParams(cols: u32, cell_w: f32) flush_mod.RowGenParams {
    return .{
        .row = 0,
        .cols = cols,
        .vw = 800.0,
        .vh = 600.0,
        .cell_w = cell_w,
        .cell_h = 34.0,
        .top_pad = 0,
        .default_bg = BG,
        .blur_enabled = false,
        .background_opacity = 1.0,
        .is_cmdline = false,
        .glow_enabled = false,
    };
}

/// Count how many textured glyph quads are in the vertex buffer.
/// Each glyph quad = 6 vertices with texCoord >= 0.
/// Returns the count of non-degenerate (position != 0,0) textured quads.
fn countVisibleGlyphQuads(verts: []const c_api.Vertex) usize {
    var count: usize = 0;
    var i: usize = 0;
    while (i + 5 < verts.len) : (i += 6) {
        // Textured quad: texCoord[0] >= 0
        if (verts[i].texCoord[0] >= 0) {
            // Non-degenerate: at least one vertex has non-zero position
            var has_area = false;
            for (0..6) |k| {
                if (verts[i + k].position[0] != 0 or verts[i + k].position[1] != 0) {
                    has_area = true;
                    break;
                }
            }
            if (has_area) count += 1;
        }
    }
    return count;
}

// ============================================================================
// Tests
// ============================================================================

test "one_to_one: 3 glyphs, 3 visible quads (no suppression)" {
    const alloc = std.testing.allocator;
    var mctx = MockCtx{ .pattern = .one_to_one };
    var core = setupCore(alloc, &mctx);
    defer core.deinitForTest();

    try fillRow(&core, 3, &[_]u32{ '=', '=', '=' });

    var out: std.ArrayListUnmanaged(c_api.Vertex) = .{};
    defer out.deinit(alloc);

    _ = try flush_mod.generateRowVertices(&core, genParams(3, @floatFromInt(mctx.cell_px)), &out);

    const visible = countVisibleGlyphQuads(out.items);
    // 3 glyphs, each within its cell, no suppression → 3 visible quads
    try std.testing.expectEqual(@as(usize, 3), visible);
}

test "calt_eq_eq: == suppresses placeholder, 1 visible quad" {
    const alloc = std.testing.allocator;
    var mctx = MockCtx{ .pattern = .calt_eq_eq };
    var core = setupCore(alloc, &mctx);
    defer core.deinitForTest();

    try fillRow(&core, 2, &[_]u32{ '=', '=' });

    var out: std.ArrayListUnmanaged(c_api.Vertex) = .{};
    defer out.deinit(alloc);

    _ = try flush_mod.generateRowVertices(&core, genParams(2, @floatFromInt(mctx.cell_px)), &out);

    const visible = countVisibleGlyphQuads(out.items);
    // glyph 0 (gid=1649, 12px, fits in cell) is suppressed by
    // glyph 1 (gid=1387, 30px, extends backward >= 1 cellW).
    try std.testing.expectEqual(@as(usize, 1), visible);
}

test "calt_eq_eq_eq: === suppresses placeholders, 1 visible quad" {
    const alloc = std.testing.allocator;
    var mctx = MockCtx{ .pattern = .calt_eq_eq_eq };
    var core = setupCore(alloc, &mctx);
    defer core.deinitForTest();

    try fillRow(&core, 3, &[_]u32{ '=', '=', '=' });

    var out: std.ArrayListUnmanaged(c_api.Vertex) = .{};
    defer out.deinit(alloc);

    _ = try flush_mod.generateRowVertices(&core, genParams(3, @floatFromInt(mctx.cell_px)), &out);

    const visible = countVisibleGlyphQuads(out.items);
    // glyphs 0,1 (gid=1649, 12px, fit in cell) are suppressed by
    // glyph 2 (gid=1388, 47px, extends backward >= 2 cellW).
    try std.testing.expectEqual(@as(usize, 1), visible);
}
