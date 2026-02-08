// Shelf-based atlas packer for core-managed glyph atlas (Phase 2).
// Zero allocations: all state is inline fields.

pub const Rect = struct {
    x: u32,
    y: u32,
    w: u32,
    h: u32,
};

pub const ShelfPacker = struct {
    width: u32,
    height: u32,
    next_x: u32 = 1, // start at 1 for 1-pixel border
    next_y: u32 = 1,
    row_h: u32 = 0,
    padding: u32 = 1,

    pub fn init(w: u32, h: u32) ShelfPacker {
        return .{ .width = w, .height = h };
    }

    /// Allocate a rect for a glyph of the given pixel size.
    /// The returned rect includes padding on all sides.
    /// Returns null if the atlas is full.
    pub fn alloc(self: *ShelfPacker, glyph_w: u32, glyph_h: u32) ?Rect {
        const packed_w = glyph_w + self.padding * 2;
        const packed_h = glyph_h + self.padding * 2;

        // Wrap to next shelf row if current row is too narrow.
        if (self.next_x + packed_w > self.width) {
            self.next_x = 1;
            self.next_y += self.row_h;
            self.row_h = 0;
        }

        // Atlas full: no more vertical space.
        if (self.next_y + packed_h > self.height) return null;

        const rect = Rect{
            .x = self.next_x,
            .y = self.next_y,
            .w = packed_w,
            .h = packed_h,
        };
        self.next_x += packed_w;
        self.row_h = @max(self.row_h, packed_h);
        return rect;
    }

    /// Reset packer state (after atlas recreation).
    pub fn reset(self: *ShelfPacker) void {
        self.next_x = 1;
        self.next_y = 1;
        self.row_h = 0;
    }

    /// Compute normalized UV coordinates for a glyph bitmap placed at (rect_x, rect_y).
    /// Returns { u0, v0, u1, v1 } in [0..1] range, excluding padding.
    pub fn computeUV(self: *const ShelfPacker, rect_x: u32, rect_y: u32, bitmap_w: u32, bitmap_h: u32) [4]f32 {
        const p = self.padding;
        const inv_w = 1.0 / @as(f32, @floatFromInt(self.width));
        const inv_h = 1.0 / @as(f32, @floatFromInt(self.height));
        return .{
            @as(f32, @floatFromInt(rect_x + p)) * inv_w,
            @as(f32, @floatFromInt(rect_y + p)) * inv_h,
            @as(f32, @floatFromInt(rect_x + p + bitmap_w)) * inv_w,
            @as(f32, @floatFromInt(rect_y + p + bitmap_h)) * inv_h,
        };
    }
};
