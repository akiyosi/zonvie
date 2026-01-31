const std = @import("std");
const Allocator = std.mem.Allocator;

const raster = @import("rasterize_freetype.zig");

pub const AtlasRect = struct {
    x: u32,
    y: u32,
    w: u32,
    h: u32,
};

pub const AtlasBackend = struct {
    pub const UploadFn = *const fn (ctx: *anyopaque, rect: AtlasRect, pixels: []const u8, pitch: i32) anyerror!void;
    ctx: *anyopaque,
    upload: UploadFn,
};

pub const GlyphOnAtlas = struct {
    rect: AtlasRect,

    // Bearing (bitmap left/top) in pixels
    left: i32,
    top: i32,

    // Advance in 26.6
    advance_x_26_6: i32,
    advance_y_26_6: i32,
};

pub const Quad = struct {
    // Screen-space (or your local space) in pixels
    x0: f32,
    y0: f32,
    x1: f32,
    y1: f32,

    // UVs (0..1 in atlas texture space)
    u0: f32,
    v0: f32,
    u1: f32,
    v1: f32,
};

pub const SimpleAtlas = struct {
    allocator: Allocator,
    width: u32,
    height: u32,

    // Extremely simple shelf allocator:
    cursor_x: u32 = 0,
    cursor_y: u32 = 0,
    shelf_h: u32 = 0,

    backend: AtlasBackend,

    pub fn init(allocator: Allocator, width: u32, height: u32, backend: AtlasBackend) SimpleAtlas {
        return .{
            .allocator = allocator,
            .width = width,
            .height = height,
            .backend = backend,
        };
    }

    pub fn allocRect(self: *SimpleAtlas, w: u32, h: u32) !AtlasRect {
        if (w > self.width or h > self.height) return error.AtlasTooSmall;

        // New shelf?
        if (self.cursor_x + w > self.width) {
            self.cursor_x = 0;
            self.cursor_y += self.shelf_h;
            self.shelf_h = 0;
        }
        if (self.cursor_y + h > self.height) return error.AtlasFull;

        const rect: AtlasRect = .{ .x = self.cursor_x, .y = self.cursor_y, .w = w, .h = h };
        self.cursor_x += w;
        self.shelf_h = @max(self.shelf_h, h);
        return rect;
    }

    pub fn uploadGlyphBitmap(self: *SimpleAtlas, bm: *const raster.GlyphBitmap) !GlyphOnAtlas {
        const rect = try self.allocRect(bm.width, bm.height);

        // Delegate to GPU backend upload (you can do staging buffer, etc).
        try self.backend.upload(self.backend.ctx, rect, bm.buffer, bm.pitch);

        return .{
            .rect = rect,
            .left = bm.left,
            .top = bm.top,
            .advance_x_26_6 = bm.advance_x_26_6,
            .advance_y_26_6 = bm.advance_y_26_6,
        };
    }

    pub fn makeQuad(
        self: *const SimpleAtlas,
        pen_x: f32,
        pen_y: f32,
        glyph: *const GlyphOnAtlas,
    ) Quad {
        _ = self;

        // Bitmap box in screen space:
        // x = pen_x + left
        // y = pen_y - top  (top is distance from baseline up)
        const x0 = pen_x + @as(f32, @floatFromInt(glyph.left));
        const y0 = pen_y - @as(f32, @floatFromInt(glyph.top));
        const x1 = x0 + @as(f32, @floatFromInt(glyph.rect.w));
        const y1 = y0 + @as(f32, @floatFromInt(glyph.rect.h));

        // UVs
        const inv_w = 1.0 / @as(f32, @floatFromInt(self.width));
        const inv_h = 1.0 / @as(f32, @floatFromInt(self.height));

        const u0 = @as(f32, @floatFromInt(glyph.rect.x)) * inv_w;
        const v0 = @as(f32, @floatFromInt(glyph.rect.y)) * inv_h;
        const u1 = @as(f32, @floatFromInt(glyph.rect.x + glyph.rect.w)) * inv_w;
        const v1 = @as(f32, @floatFromInt(glyph.rect.y + glyph.rect.h)) * inv_h;

        return .{ .x0 = x0, .y0 = y0, .x1 = x1, .y1 = y1, .u0 = u0, .v0 = v0, .u1 = u1, .v1 = v1 };
    }
};

