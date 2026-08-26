// ext_images_resample.zig — platform-independent bilinear resampler for the
// ext_images store. Split from ext_images.zig so its tests run in the native
// `zig build test` step, which cannot compile the WIC-including store.

const std = @import("std");

/// Scale premultiplied RGBA with box-filter halving passes down to <2x the
/// target, then one bilinear pass. Plain bilinear reads only a 2x2 footprint
/// per output pixel, so past ~2x downscale it skips a growing majority of the
/// source (moire/speckle on fine detail); the halving chain keeps every source
/// pixel contributing, approximating the area-averaging quality macOS gets
/// from CGInterpolationQuality.high.
pub fn scalePRGBA(
    alloc: std.mem.Allocator,
    src: []const u8,
    src_w: u32,
    src_h: u32,
    dst: []u8,
    dst_w: u32,
    dst_h: u32,
) error{OutOfMemory}!void {
    var cur: []const u8 = src;
    var cur_w = src_w;
    var cur_h = src_h;
    var owned: ?[]u8 = null;
    defer if (owned) |o| alloc.free(o);

    while (cur_w >= dst_w * 2 and cur_h >= dst_h * 2 and cur_w >= 2 and cur_h >= 2) {
        const next_w = cur_w / 2;
        const next_h = cur_h / 2;
        const next = try alloc.alloc(u8, @as(usize, next_w) * next_h * 4);
        halvePRGBA(cur, cur_w, next, next_w, next_h);
        if (owned) |o| alloc.free(o);
        owned = next;
        cur = next;
        cur_w = next_w;
        cur_h = next_h;
    }
    bilinearPRGBA(cur, cur_w, cur_h, dst, dst_w, dst_h);
}

/// One 2x box-filter pass: each output pixel is the rounded average of its
/// 2x2 source block. An odd trailing row/column is dropped — at the ratios
/// where halving runs, half a source pixel is beneath notice.
fn halvePRGBA(src: []const u8, src_w: u32, dst: []u8, dst_w: u32, dst_h: u32) void {
    const src_stride: usize = @as(usize, src_w) * 4;
    const dst_stride: usize = @as(usize, dst_w) * 4;
    var y: usize = 0;
    while (y < dst_h) : (y += 1) {
        const r0 = (y * 2) * src_stride;
        const r1 = r0 + src_stride;
        var x: usize = 0;
        while (x < dst_w) : (x += 1) {
            const c0 = x * 2 * 4;
            const d = dst[y * dst_stride + x * 4 ..][0..4];
            inline for (0..4) |ch| {
                const sum = @as(u16, src[r0 + c0 + ch]) + src[r0 + c0 + 4 + ch] +
                    src[r1 + c0 + ch] + src[r1 + c0 + 4 + ch];
                d[ch] = @intCast((sum + 2) / 4);
            }
        }
    }
}

/// Bilinear resample of premultiplied RGBA (bilinear is linear, so operating
/// on premultiplied channels is the correct order of operations). Runs once
/// per placement, off the per-tile path.
pub fn bilinearPRGBA(src: []const u8, src_w: u32, src_h: u32, dst: []u8, dst_w: u32, dst_h: u32) void {
    if (src_w == 0 or src_h == 0 or dst_w == 0 or dst_h == 0) return;
    const sx_step = @as(f32, @floatFromInt(src_w)) / @as(f32, @floatFromInt(dst_w));
    const sy_step = @as(f32, @floatFromInt(src_h)) / @as(f32, @floatFromInt(dst_h));
    const src_stride: usize = @as(usize, src_w) * 4;
    const dst_stride: usize = @as(usize, dst_w) * 4;

    var dy: u32 = 0;
    while (dy < dst_h) : (dy += 1) {
        // Sample at the pixel centre, clamped to the source interior.
        const fy = (@as(f32, @floatFromInt(dy)) + 0.5) * sy_step - 0.5;
        const fy_c = @max(0.0, @min(fy, @as(f32, @floatFromInt(src_h - 1))));
        const y0: usize = @intFromFloat(fy_c);
        const y1 = @min(y0 + 1, src_h - 1);
        const wy = fy_c - @as(f32, @floatFromInt(y0));

        var dx: u32 = 0;
        while (dx < dst_w) : (dx += 1) {
            const fx = (@as(f32, @floatFromInt(dx)) + 0.5) * sx_step - 0.5;
            const fx_c = @max(0.0, @min(fx, @as(f32, @floatFromInt(src_w - 1))));
            const x0: usize = @intFromFloat(fx_c);
            const x1 = @min(x0 + 1, src_w - 1);
            const wx = fx_c - @as(f32, @floatFromInt(x0));

            const p00 = src[y0 * src_stride + x0 * 4 ..][0..4];
            const p10 = src[y0 * src_stride + x1 * 4 ..][0..4];
            const p01 = src[y1 * src_stride + x0 * 4 ..][0..4];
            const p11 = src[y1 * src_stride + x1 * 4 ..][0..4];
            const d = dst[@as(usize, dy) * dst_stride + @as(usize, dx) * 4 ..][0..4];

            inline for (0..4) |ch| {
                const top = @as(f32, @floatFromInt(p00[ch])) * (1.0 - wx) + @as(f32, @floatFromInt(p10[ch])) * wx;
                const bot = @as(f32, @floatFromInt(p01[ch])) * (1.0 - wx) + @as(f32, @floatFromInt(p11[ch])) * wx;
                d[ch] = @intFromFloat(@max(0.0, @min(255.0, top * (1.0 - wy) + bot * wy + 0.5)));
            }
        }
    }
}

test "box-filter chain averages a checkerboard to mid-gray" {
    // 8x8 checkerboard of 0/255 pixels into 1x1: only an every-pixel
    // average lands on the midpoint; plain bilinear would sample a single
    // 2x2 region and return a corner-biased value.
    var src: [8 * 8 * 4]u8 = undefined;
    var y: usize = 0;
    while (y < 8) : (y += 1) {
        var x: usize = 0;
        while (x < 8) : (x += 1) {
            const v: u8 = if ((x + y) % 2 == 0) 255 else 0;
            const p = src[(y * 8 + x) * 4 ..][0..4];
            p.* = .{ v, v, v, 255 };
        }
    }
    var dst: [4]u8 = undefined;
    try scalePRGBA(std.testing.allocator, &src, 8, 8, &dst, 1, 1);
    // Exact midpoint modulo the per-pass rounding bias.
    try std.testing.expectApproxEqAbs(@as(f32, 128), @as(f32, @floatFromInt(dst[0])), 2);
    try std.testing.expectEqual(@as(u8, 255), dst[3]);
}

test "box-filter chain is exact for a uniform image" {
    var src: [32 * 32 * 4]u8 = undefined;
    var i: usize = 0;
    while (i < src.len) : (i += 4) {
        src[i] = 40;
        src[i + 1] = 90;
        src[i + 2] = 140;
        src[i + 3] = 200;
    }
    var dst: [5 * 5 * 4]u8 = undefined;
    try scalePRGBA(std.testing.allocator, &src, 32, 32, &dst, 5, 5);
    i = 0;
    while (i < dst.len) : (i += 4) {
        try std.testing.expectEqual(@as(u8, 40), dst[i]);
        try std.testing.expectEqual(@as(u8, 90), dst[i + 1]);
        try std.testing.expectEqual(@as(u8, 140), dst[i + 2]);
        try std.testing.expectEqual(@as(u8, 200), dst[i + 3]);
    }
}

test "bilinear identity resample copies the source" {
    // 2x2 distinct premultiplied pixels, identity scale.
    const src = [_]u8{
        255, 0,   0,   255, 0, 255, 0, 255,
        0,   0,   255, 255, 9, 8,   7, 6,
    };
    var dst: [16]u8 = undefined;
    bilinearPRGBA(&src, 2, 2, &dst, 2, 2);
    try std.testing.expectEqualSlices(u8, &src, &dst);
}

test "bilinear downscale of a uniform image stays uniform" {
    var src: [16 * 16 * 4]u8 = undefined;
    var i: usize = 0;
    while (i < src.len) : (i += 4) {
        src[i] = 100;
        src[i + 1] = 150;
        src[i + 2] = 200;
        src[i + 3] = 255;
    }
    var dst: [3 * 3 * 4]u8 = undefined;
    bilinearPRGBA(&src, 16, 16, &dst, 3, 3);
    i = 0;
    while (i < dst.len) : (i += 4) {
        try std.testing.expectEqual(@as(u8, 100), dst[i]);
        try std.testing.expectEqual(@as(u8, 150), dst[i + 1]);
        try std.testing.expectEqual(@as(u8, 200), dst[i + 2]);
        try std.testing.expectEqual(@as(u8, 255), dst[i + 3]);
    }
}
