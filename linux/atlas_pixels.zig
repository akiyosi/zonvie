const std = @import("std");
const core = @import("zonvie_core");
const testing = std.testing;

/// `out` is width*height*4 bytes. HBFT emits bytes_per_pixel 1 (gray coverage),
/// 3 (LCD coverage, R G B samples per pixel) or 4 (BGRA, FT_PIXEL_MODE_BGRA);
/// anything else becomes transparent. LCD coverage collapses to its luminance,
/// the weights Windows' shader reads ClearType coverage with, so text has no
/// colour fringes on any frontend.
pub fn toRgba8(bm: *const core.GlyphBitmap, out: []u8) void {
    const w: usize = bm.width;
    const h: usize = bm.height;
    const src = bm.pixels orelse {
        @memset(out[0 .. w * h * 4], 0);
        return;
    };
    if (bm.pitch < 0 or @as(usize, @intCast(bm.pitch)) < w * bm.bytes_per_pixel) {
        @memset(out[0 .. w * h * 4], 0);
        return;
    }
    const pitch: usize = @intCast(bm.pitch);
    for (0..h) |y| {
        const dst = out[y * w * 4 ..][0 .. w * 4];
        switch (bm.bytes_per_pixel) {
            1 => for (0..w) |x| {
                const c = src[y * pitch + x];
                dst[x * 4 ..][0..4].* = .{ c, c, c, c };
            },
            3 => for (0..w) |x| {
                const c = lcdCoverage(src[y * pitch + x * 3 ..][0..3].*);
                dst[x * 4 ..][0..4].* = .{ c, c, c, c };
            },
            4 => for (0..w) |x| {
                const p = src[y * pitch + x * 4 ..][0..4];
                dst[x * 4 ..][0..4].* = .{ p[2], p[1], p[0], p[3] };
            },
            else => @memset(dst, 0),
        }
    }
}

/// One pixel's coverage from its R, G, B LCD samples: luminance, rounded.
pub fn lcdCoverage(rgb: [3]u8) u8 {
    const sum: u32 = 299 * @as(u32, rgb[0]) + 587 * @as(u32, rgb[1]) + 114 * @as(u32, rgb[2]);
    return @intCast((sum + 500) / 1000);
}

test "LCD samples collapse to their luminance" {
    try testing.expectEqual(@as(u8, 255), lcdCoverage(.{ 255, 255, 255 }));
    try testing.expectEqual(@as(u8, 0), lcdCoverage(.{ 0, 0, 0 }));
    try testing.expectEqual(@as(u8, 76), lcdCoverage(.{ 255, 0, 0 }));
    try testing.expectEqual(@as(u8, 150), lcdCoverage(.{ 0, 255, 0 }));
}

test "3-byte LCD coverage expands to its luminance in every channel" {
    const px = [_]u8{ 255, 255, 255, 0, 0, 0 };
    const bm = core.GlyphBitmap{ .pixels = &px, .width = 2, .height = 1, .pitch = 6, .bearing_x = 0, .bearing_y = 0, .advance_26_6 = 0, .ascent_px = 0, .descent_px = 0, .bytes_per_pixel = 3 };
    var out: [8]u8 = undefined;
    toRgba8(&bm, &out);
    try testing.expectEqualSlices(u8, &.{ 255, 255, 255, 255, 0, 0, 0, 0 }, &out);
}

test "1-byte coverage expands to RGBA with coverage in every channel" {
    const px = [_]u8{ 0, 128, 255, 7 };
    const bm = core.GlyphBitmap{ .pixels = &px, .width = 2, .height = 2, .pitch = 2, .bearing_x = 0, .bearing_y = 0, .advance_26_6 = 0, .ascent_px = 0, .descent_px = 0, .bytes_per_pixel = 1 };
    var out: [16]u8 = undefined;
    toRgba8(&bm, &out);
    try testing.expectEqualSlices(u8, &.{ 128, 128, 128, 128 }, out[4..8]);
}

test "pitch padding is skipped" {
    const px = [_]u8{ 1, 9, 2, 9 }; // width 1, pitch 2
    const bm = core.GlyphBitmap{ .pixels = &px, .width = 1, .height = 2, .pitch = 2, .bearing_x = 0, .bearing_y = 0, .advance_26_6 = 0, .ascent_px = 0, .descent_px = 0, .bytes_per_pixel = 1 };
    var out: [8]u8 = undefined;
    toRgba8(&bm, &out);
    try testing.expectEqual(@as(u8, 2), out[4]);
}

test "4-byte BGRA is swizzled to RGBA" {
    const px = [_]u8{ 10, 20, 30, 40 }; // B G R A
    const bm = core.GlyphBitmap{ .pixels = &px, .width = 1, .height = 1, .pitch = 4, .bearing_x = 0, .bearing_y = 0, .advance_26_6 = 0, .ascent_px = 0, .descent_px = 0, .bytes_per_pixel = 4 };
    var out: [4]u8 = undefined;
    toRgba8(&bm, &out);
    try testing.expectEqualSlices(u8, &.{ 30, 20, 10, 40 }, &out);
}

test "negative pitch yields zeros" {
    const px = [_]u8{ 1, 2, 3, 4 };
    const bm = core.GlyphBitmap{ .pixels = &px, .width = 2, .height = 2, .pitch = -2, .bearing_x = 0, .bearing_y = 0, .advance_26_6 = 0, .ascent_px = 0, .descent_px = 0, .bytes_per_pixel = 1 };
    var out: [16]u8 = .{9} ** 16;
    toRgba8(&bm, &out);
    try testing.expectEqualSlices(u8, &(.{0} ** 16), &out);
}

test "pitch smaller than a row yields zeros" {
    const px = [_]u8{ 1, 2, 3, 4 };
    const bm = core.GlyphBitmap{ .pixels = &px, .width = 2, .height = 2, .pitch = 1, .bearing_x = 0, .bearing_y = 0, .advance_26_6 = 0, .ascent_px = 0, .descent_px = 0, .bytes_per_pixel = 1 };
    var out: [16]u8 = .{9} ** 16;
    toRgba8(&bm, &out);
    try testing.expectEqualSlices(u8, &(.{0} ** 16), &out);
}

test "unsupported bytes_per_pixel and null pixels yield zeros" {
    const px = [_]u8{ 1, 2 };
    var bm = core.GlyphBitmap{ .pixels = &px, .width = 1, .height = 1, .pitch = 2, .bearing_x = 0, .bearing_y = 0, .advance_26_6 = 0, .ascent_px = 0, .descent_px = 0, .bytes_per_pixel = 2 };
    var out: [4]u8 = .{ 9, 9, 9, 9 };
    toRgba8(&bm, &out);
    try testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0 }, &out);
    bm.bytes_per_pixel = 1;
    bm.pixels = null;
    out = .{ 9, 9, 9, 9 };
    toRgba8(&bm, &out);
    try testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0 }, &out);
}

/// Box-filters a premultiplied 4-byte-per-pixel bitmap (src_w x src_h, rows
/// `src_pitch` bytes apart) into `dst` (dst_w x dst_h, tightly packed): each
/// destination pixel averages the source pixels its footprint covers. For
/// fixed-strike colour emoji, whose only size is larger than the cell.
pub fn downscale4(src: []const u8, src_w: usize, src_h: usize, src_pitch: usize, dst: []u8, dst_w: usize, dst_h: usize) void {
    for (0..dst_h) |dy| {
        const y0 = dy * src_h / dst_h;
        const y1 = @max(y0 + 1, (dy + 1) * src_h / dst_h);
        for (0..dst_w) |dx| {
            const x0 = dx * src_w / dst_w;
            const x1 = @max(x0 + 1, (dx + 1) * src_w / dst_w);
            var sum: [4]u32 = .{ 0, 0, 0, 0 };
            for (y0..y1) |y| {
                for (x0..x1) |x| {
                    const p = src[y * src_pitch + x * 4 ..][0..4];
                    inline for (0..4) |c| sum[c] += p[c];
                }
            }
            const n: u32 = @intCast((y1 - y0) * (x1 - x0));
            const o = dst[(dy * dst_w + dx) * 4 ..][0..4];
            inline for (0..4) |c| o[c] = @intCast((sum[c] + n / 2) / n);
        }
    }
}

test "downscale4 averages each footprint" {
    // 2x2 -> 1x1: the mean of four pixels, per channel.
    const src = [_]u8{ 0, 0, 0, 0, 100, 100, 100, 100, 200, 200, 200, 200, 100, 100, 100, 100 };
    var dst: [4]u8 = undefined;
    downscale4(&src, 2, 2, 8, &dst, 1, 1);
    try testing.expectEqualSlices(u8, &.{ 100, 100, 100, 100 }, &dst);
}
