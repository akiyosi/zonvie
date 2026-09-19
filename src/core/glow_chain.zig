//! The geometry of the Dual Kawase bloom chain, answered once for both
//! frontends: how large each scratch texture is, and which one every pass
//! reads and writes.
//!
//! The chain works at half the surface's resolution and halves again at each
//! of three levels, down and then back up. Nothing in that is
//! platform-specific -- it was written twice, in `MetalTypes.swift` and
//! `d3d11_renderer.zig`, as two spellings of the same integer arithmetic.
//!
//! The light itself never appears here. What the passes *do* is the shaders'
//! business; this only says where they run.

const std = @import("std");

pub const mip_count = 3;

/// A pass's source or destination. `extract` is the half-resolution texture
/// the glow is extracted into and, after the chain has run, composited from;
/// `mip` indexes the progressively smaller scratch textures.
///
/// Crossing the C ABI as an i32 keeps this a plain struct: -1 is `extract`,
/// 0..mip_count-1 a mip. A tagged union would need a layout the header cannot
/// state.
pub const extract_target: i32 = -1;

pub const Pass = extern struct {
    src: i32,
    dst: i32,
    dst_w_px: u32,
    dst_h_px: u32,
};

/// Layout must match `zonvie_glow_chain` in include/zonvie_core.h.
pub const Chain = extern struct {
    half_w_px: u32,
    half_h_px: u32,
    mip_w_px: [mip_count]u32,
    mip_h_px: [mip_count]u32,
    down: [mip_count]Pass,
    up: [mip_count]Pass,
};

comptime {
    if (@sizeOf(Pass) != 4 * 4) @compileError("zonvie_glow_pass layout drifted from the header");
    if (@sizeOf(Chain) != (2 + 3 + 3) * 4 + 2 * mip_count * @sizeOf(Pass))
        @compileError("zonvie_glow_chain layout drifted from the header");
}

/// Every extent is floored at one pixel. A surface narrow enough for a level
/// to round to zero still has to produce a texture the passes can bind, and a
/// zero extent is not one.
pub fn plan(surface_w_px: u32, surface_h_px: u32) Chain {
    const half_w = @max(1, surface_w_px / 2);
    const half_h = @max(1, surface_h_px / 2);

    var mip_w: [mip_count]u32 = undefined;
    var mip_h: [mip_count]u32 = undefined;
    var w = half_w;
    var h = half_h;
    for (0..mip_count) |i| {
        w = @max(1, w / 2);
        h = @max(1, h / 2);
        mip_w[i] = w;
        mip_h[i] = h;
    }

    var down: [mip_count]Pass = undefined;
    for (0..mip_count) |i| {
        const level: i32 = @intCast(i);
        down[i] = .{
            .src = if (i == 0) extract_target else level - 1,
            .dst = level,
            .dst_w_px = mip_w[i],
            .dst_h_px = mip_h[i],
        };
    }

    // Back up the same ladder, ending in the extract texture the composite
    // samples. Each pass reads the level it is leaving and writes the one
    // below it.
    var up: [mip_count]Pass = undefined;
    for (0..mip_count) |i| {
        const level = mip_count - 1 - i;
        const level_i32: i32 = @intCast(level);
        up[i] = .{
            .src = level_i32,
            .dst = if (level == 0) extract_target else level_i32 - 1,
            .dst_w_px = if (level == 0) half_w else mip_w[level - 1],
            .dst_h_px = if (level == 0) half_h else mip_h[level - 1],
        };
    }

    return .{
        .half_w_px = half_w,
        .half_h_px = half_h,
        .mip_w_px = mip_w,
        .mip_h_px = mip_h,
        .down = down,
        .up = up,
    };
}

// ---------------------------------------------------------------------------

const testing = std.testing;

test "the chain halves the surface and then each level" {
    const c = plan(1254, 724);
    try testing.expectEqual(@as(u32, 627), c.half_w_px);
    try testing.expectEqual(@as(u32, 362), c.half_h_px);
    try testing.expectEqual([mip_count]u32{ 313, 156, 78 }, c.mip_w_px);
    try testing.expectEqual([mip_count]u32{ 181, 90, 45 }, c.mip_h_px);
}

test "downsample reads the extract texture first, then the level above" {
    const c = plan(1254, 724);
    try testing.expectEqual(extract_target, c.down[0].src);
    try testing.expectEqual(@as(i32, 0), c.down[0].dst);
    try testing.expectEqual(@as(i32, 0), c.down[1].src);
    try testing.expectEqual(@as(i32, 1), c.down[1].dst);
    try testing.expectEqual(@as(i32, 1), c.down[2].src);
    try testing.expectEqual(@as(i32, 2), c.down[2].dst);
    // Each destination is the level's own size.
    for (0..mip_count) |i| {
        try testing.expectEqual(c.mip_w_px[i], c.down[i].dst_w_px);
        try testing.expectEqual(c.mip_h_px[i], c.down[i].dst_h_px);
    }
}

test "upsample walks back down the ladder and ends in the extract texture" {
    const c = plan(1254, 724);
    try testing.expectEqual(@as(i32, 2), c.up[0].src);
    try testing.expectEqual(@as(i32, 1), c.up[0].dst);
    try testing.expectEqual(@as(i32, 1), c.up[1].src);
    try testing.expectEqual(@as(i32, 0), c.up[1].dst);
    try testing.expectEqual(@as(i32, 0), c.up[2].src);
    try testing.expectEqual(extract_target, c.up[2].dst);
    // The last pass restores the half-resolution extent the composite samples.
    try testing.expectEqual(c.half_w_px, c.up[2].dst_w_px);
    try testing.expectEqual(c.half_h_px, c.up[2].dst_h_px);
}

test "a surface too small for a level still yields bindable extents" {
    const c = plan(1, 1);
    try testing.expectEqual(@as(u32, 1), c.half_w_px);
    try testing.expectEqual(@as(u32, 1), c.half_h_px);
    for (0..mip_count) |i| {
        try testing.expect(c.mip_w_px[i] >= 1);
        try testing.expect(c.mip_h_px[i] >= 1);
        try testing.expect(c.down[i].dst_w_px >= 1);
        try testing.expect(c.up[i].dst_w_px >= 1);
    }
    const zero = plan(0, 0);
    try testing.expectEqual(@as(u32, 1), zero.half_w_px);
    try testing.expectEqual(@as(u32, 1), zero.half_h_px);
}

test "the chain agrees with the arithmetic each frontend used to carry" {
    // macOS halved a CGSize then each mip; Windows divided the half extent by
    // 2, 4 and 8. Both, over every surface size that produces a distinct
    // ladder.
    var sw: u32 = 0;
    while (sw <= 4096) : (sw += 1) {
        const c = plan(sw, sw);
        const hw = @max(1, sw / 2);
        try testing.expectEqual(hw, c.half_w_px);
        // Windows' spelling.
        try testing.expectEqual(@max(1, hw / 2), c.mip_w_px[0]);
        try testing.expectEqual(@max(1, hw / 4), c.mip_w_px[1]);
        try testing.expectEqual(@max(1, hw / 8), c.mip_w_px[2]);
        // macOS' spelling: repeated halving with the same floor.
        var mw = @max(1, hw / 2);
        for (0..mip_count) |i| {
            try testing.expectEqual(mw, c.mip_w_px[i]);
            mw = @max(1, mw / 2);
        }
    }
}
