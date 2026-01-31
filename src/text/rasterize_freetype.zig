const std = @import("std");
const Allocator = std.mem.Allocator;

// You already have a freetype package in the repo (pkg/freetype).
// Adjust this import to match your build/package wiring.
const ft = @import("freetype");

pub const BitmapFormat = enum {
    gray8,
};

pub const GlyphBitmap = struct {
    width: u32,
    height: u32,
    pitch: i32,          // bytes per row (may be negative in some cases)
    left: i32,           // bitmap_left
    top: i32,            // bitmap_top
    buffer: []u8,        // owned, tightly packed row-by-row using pitch
    format: BitmapFormat = .gray8,

    // Advances in 26.6 fixed-point pixels
    advance_x_26_6: i32,
    advance_y_26_6: i32,

    pub fn deinit(self: *GlyphBitmap, allocator: Allocator) void {
        allocator.free(self.buffer);
        self.* = undefined;
    }
};

pub const RasterizeOptions = struct {
    render_mode: ft.FT_Render_Mode = ft.FT_RENDER_MODE_NORMAL,
    load_flags: i32 = ft.FT_LOAD_DEFAULT,
};

pub fn rasterizeGlyph(
    allocator: Allocator,
    face: ft.FT_Face,
    glyph_id: u32,
    opts: RasterizeOptions,
) !GlyphBitmap {
    // Load
    if (ft.FT_Load_Glyph(face, glyph_id, opts.load_flags) != 0) return error.LoadGlyphFailed;

    // Render (face->glyph is FT_GlyphSlot)
    if (ft.FT_Render_Glyph(face.*.glyph, opts.render_mode) != 0) return error.RenderGlyphFailed;

    const slot = face.*.glyph;
    const bm = slot.*.bitmap;

    // Only handle 8-bit gray for now.
    if (bm.pixel_mode != ft.FT_PIXEL_MODE_GRAY) return error.UnsupportedPixelMode;
    if (bm.num_grays != 256) return error.UnsupportedGrayDepth;

    const w: u32 = @intCast(bm.width);
    const h: u32 = @intCast(bm.rows);
    const pitch: i32 = bm.pitch;

    // Copy the bitmap buffer (respect pitch)
    // NOTE: For simplicity, we store exactly |pitch|*rows bytes.
    const row_bytes: usize = @intCast(@abs(pitch));
    const total: usize = row_bytes * @as(usize, h);

    var out_buf = try allocator.alloc(u8, total);
    errdefer allocator.free(out_buf);

    const src_ptr: [*]const u8 = @ptrCast(bm.buffer);
    @memcpy(out_buf, src_ptr[0..total]);

    return .{
        .width = w,
        .height = h,
        .pitch = pitch,
        .left = slot.*.bitmap_left,
        .top = slot.*.bitmap_top,
        .buffer = out_buf,
        .format = .gray8,
        .advance_x_26_6 = slot.*.advance.x,
        .advance_y_26_6 = slot.*.advance.y,
    };
}

