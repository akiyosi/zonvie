//! Which bands of a surface a partial frame redraws.
//!
//! The pixels a frame owes are spans of surface rows: the rows a layer
//! changed, a whole layer that moved or has to redraw, the rows an accepted
//! row-scroll copy left stale. Every frontend turns them into the same bands:
//! adjacent spans join, and each run grows by one row above and below,
//! because glyph ink is not clamped to its row (vertexgen clamps box drawing
//! only) and a run redrawn under a tighter clip would differ from a full
//! redraw at its edges. Each band is then repainted whole: every layer that
//! meets it, back to front, draws its rows that meet the band widened by one
//! more row, clipped to the band. Within a band that is exactly what a full
//! redraw produces for ink that crosses at most one row boundary.
//!
//! Bands span the whole surface width. A band therefore stands for every
//! layer under it, which is what lets the frontends drop their own
//! propagation (a lower layer's repaint erasing an upper one's pixels).

const std = @import("std");

pub const Band = extern struct { top_px: i32, bottom_px: i32 };

/// Surfaces taller than this are redrawn as one band. 16384 px covers an 8K
/// display at 2x, and the bitmap stays 2 KiB on the stack.
pub const max_height_px: i32 = 16384;

/// Fold `spans` into the bands a frame redraws, written to `out`. Returns the
/// band count. Spans are clamped to [0, surface_h_px). When `out` is too
/// small, the last band absorbs the rest: a superset, never a lost row.
pub fn bands(spans: []const Band, row_h_px: i32, surface_h_px: i32, out: []Band) usize {
    if (out.len == 0 or surface_h_px <= 0) return 0;
    if (surface_h_px > max_height_px or row_h_px <= 0) {
        for (spans) |s| {
            if (@min(s.bottom_px, surface_h_px) > @max(s.top_px, 0)) {
                out[0] = .{ .top_px = 0, .bottom_px = surface_h_px };
                return 1;
            }
        }
        return 0;
    }

    const words = comptime @as(usize, @intCast(max_height_px)) / 64;
    var marked: [words]u64 = @splat(0);
    const h: usize = @intCast(surface_h_px);
    for (spans) |s| {
        // Widened by one row each way here, so runs closer than two rows
        // merge into one band rather than overlapping.
        const top = std.math.clamp(@as(i64, s.top_px) - row_h_px, 0, @as(i64, @intCast(h)));
        const bottom = std.math.clamp(@as(i64, s.bottom_px) + row_h_px, 0, @as(i64, @intCast(h)));
        if (s.bottom_px <= s.top_px or bottom <= top) continue;
        setRange(&marked, @intCast(top), @intCast(bottom));
    }

    // Bands closer than three rows join, so no row of any layer, wherever it
    // starts, reaches two bands through layerRowsForBand's extra row: a
    // frontend clips each row to the one band it belongs to.
    const join_gap_px: usize = @intCast(@as(i64, row_h_px) * 3);
    var n: usize = 0;
    var px: usize = 0;
    while (px < h) {
        if (!isSet(&marked, px)) {
            px += 1;
            continue;
        }
        const start = px;
        while (px < h and isSet(&marked, px)) px += 1;
        if (n > 0 and start - @as(usize, @intCast(out[n - 1].bottom_px)) < join_gap_px) {
            out[n - 1].bottom_px = @intCast(px);
        } else if (n == out.len) {
            out[n - 1].bottom_px = @intCast(px);
        } else {
            out[n] = .{ .top_px = @intCast(start), .bottom_px = @intCast(px) };
            n += 1;
        }
    }
    // Disjoint, ascending, non-empty and on the surface.
    std.debug.assert(n <= out.len);
    for (out[0..n], 0..) |b, i| {
        std.debug.assert(b.top_px < b.bottom_px);
        std.debug.assert(b.bottom_px <= surface_h_px);
        if (i > 0) std.debug.assert(out[i - 1].bottom_px < b.top_px);
    }
    return n;
}

/// The band `row` of a layer belongs to: the one layerRowsForBand would name
/// it for. Null when it reaches none.
pub fn bandForLayerRow(band_list: []const Band, origin_y_px: i32, row: u32, row_h_px: i32) ?Band {
    if (row_h_px <= 0) return null;
    const top = @as(i64, origin_y_px) + @as(i64, row) * row_h_px;
    for (band_list) |b| {
        if (top < @as(i64, b.bottom_px) + row_h_px and top + row_h_px > @as(i64, b.top_px) - row_h_px) return b;
    }
    return null;
}

/// The rows of a layer one band repaints: those meeting the band widened by a
/// row each way, so ink a row outside it spills in is drawn too. Inclusive;
/// null when none. The caller clips to the band.
pub fn layerRowsForBand(band: Band, origin_y_px: i32, layer_rows: u32, row_h_px: i32) ?[2]u32 {
    if (row_h_px <= 0 or layer_rows == 0) return null;
    const h: i64 = row_h_px;
    const oy: i64 = origin_y_px;
    const top = @as(i64, band.top_px) - h;
    const bottom = @as(i64, band.bottom_px) + h;
    if (bottom <= oy) return null;
    const first = @max(0, @divFloor(top - oy, h));
    const last = @min(@as(i64, layer_rows) - 1, @divFloor(bottom - 1 - oy, h));
    if (last < first) return null;
    std.debug.assert(first >= 0);
    std.debug.assert(last < layer_rows);
    return .{ @intCast(first), @intCast(last) };
}

fn setRange(bits: []u64, start: usize, end: usize) void {
    var i = start;
    while (i < end) : (i += 1) bits[i / 64] |= @as(u64, 1) << @intCast(i % 64);
}

fn isSet(bits: []const u64, i: usize) bool {
    return bits[i / 64] & (@as(u64, 1) << @intCast(i % 64)) != 0;
}

test "one dirty row becomes a band one row taller on each side" {
    var out: [4]Band = undefined;
    const n = bands(&.{.{ .top_px = 40, .bottom_px = 50 }}, 10, 200, &out);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqual(Band{ .top_px = 30, .bottom_px = 60 }, out[0]);
}

test "runs two rows apart merge, three rows apart do not" {
    var out: [4]Band = undefined;
    // Rows 2 and 4: widened they touch at row 3.
    var n = bands(&.{ .{ .top_px = 20, .bottom_px = 30 }, .{ .top_px = 40, .bottom_px = 50 } }, 10, 200, &out);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqual(Band{ .top_px = 10, .bottom_px = 60 }, out[0]);
    // Rows 2 and 5: rows 1-3 and 4-6 are adjacent and therefore one run too.
    n = bands(&.{ .{ .top_px = 20, .bottom_px = 30 }, .{ .top_px = 50, .bottom_px = 60 } }, 10, 200, &out);
    try std.testing.expectEqual(@as(usize, 1), n);
}

test "bands less than three rows apart join, three rows apart do not" {
    var out: [4]Band = undefined;
    // Rows 2 and 6: rows 1-3 and 5-7, a one-row gap, join.
    var n = bands(&.{ .{ .top_px = 20, .bottom_px = 30 }, .{ .top_px = 60, .bottom_px = 70 } }, 10, 200, &out);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqual(Band{ .top_px = 10, .bottom_px = 80 }, out[0]);
    // A second span at 69 px: widened, 10..40 and 59..89, a 19 px gap, join.
    n = bands(&.{ .{ .top_px = 20, .bottom_px = 30 }, .{ .top_px = 69, .bottom_px = 79 } }, 10, 200, &out);
    try std.testing.expectEqual(@as(usize, 1), n);
    // Rows 2 and 8: rows 1-3 and 7-9, a three-row gap, stay apart.
    n = bands(&.{ .{ .top_px = 20, .bottom_px = 30 }, .{ .top_px = 80, .bottom_px = 90 } }, 10, 200, &out);
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqual(Band{ .top_px = 10, .bottom_px = 40 }, out[0]);
    try std.testing.expectEqual(Band{ .top_px = 70, .bottom_px = 100 }, out[1]);
}

test "no layer row reaches two bands" {
    // The property the join gap exists for, over every row offset.
    var out: [8]Band = undefined;
    const n = bands(&.{ .{ .top_px = 20, .bottom_px = 30 }, .{ .top_px = 80, .bottom_px = 90 } }, 10, 200, &out);
    try std.testing.expectEqual(@as(usize, 2), n);
    var origin: i32 = -10;
    while (origin < 10) : (origin += 1) {
        var row: u32 = 0;
        while (row < 25) : (row += 1) {
            var hits: u32 = 0;
            for (out[0..n]) |b| {
                const rows = layerRowsForBand(b, origin, 25, 10) orelse continue;
                if (row >= rows[0] and row <= rows[1]) hits += 1;
            }
            try std.testing.expect(hits <= 1);
            if (hits == 1) try std.testing.expect(bandForLayerRow(out[0..n], origin, row, 10) != null);
        }
    }
}

test "bands are clamped to the surface" {
    var out: [4]Band = undefined;
    const n = bands(&.{ .{ .top_px = -5, .bottom_px = 5 }, .{ .top_px = 195, .bottom_px = 400 } }, 10, 200, &out);
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqual(Band{ .top_px = 0, .bottom_px = 15 }, out[0]);
    try std.testing.expectEqual(Band{ .top_px = 185, .bottom_px = 200 }, out[1]);
}

test "an empty span and a span off the surface owe nothing" {
    var out: [4]Band = undefined;
    try std.testing.expectEqual(@as(usize, 0), bands(&.{ .{ .top_px = 30, .bottom_px = 30 }, .{ .top_px = 300, .bottom_px = 400 } }, 10, 200, &out));
}

test "a full output list keeps every damaged pixel in its last band" {
    var out: [1]Band = undefined;
    const n = bands(&.{ .{ .top_px = 20, .bottom_px = 30 }, .{ .top_px = 100, .bottom_px = 110 } }, 10, 200, &out);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqual(Band{ .top_px = 10, .bottom_px = 120 }, out[0]);
}

test "a row taller than the surface yields one whole-surface band" {
    var out: [4]Band = undefined;
    var n = bands(&.{ .{ .top_px = 20, .bottom_px = 30 }, .{ .top_px = 150, .bottom_px = 160 } }, 300, 200, &out);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqual(Band{ .top_px = 0, .bottom_px = 200 }, out[0]);
    // The widening and join-gap arithmetic must not overflow i32.
    n = bands(&.{.{ .top_px = 20, .bottom_px = 30 }}, std.math.maxInt(i32), 200, &out);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqual(Band{ .top_px = 0, .bottom_px = 200 }, out[0]);
}

test "a surface past the bitmap is redrawn whole" {
    var out: [4]Band = undefined;
    const n = bands(&.{.{ .top_px = 20, .bottom_px = 30 }}, 10, max_height_px + 1, &out);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqual(Band{ .top_px = 0, .bottom_px = max_height_px + 1 }, out[0]);
}

test "a band repaints the layer rows one row past its edges" {
    // Layer at y=25, rows 10 px: row 0 is 25..35, row 1 35..45, ...
    // Band 50..60, widened to 40..70: rows 1 (35..45) to 4 (65..75).
    try std.testing.expectEqual([2]u32{ 1, 4 }, layerRowsForBand(.{ .top_px = 50, .bottom_px = 60 }, 25, 10, 10).?);
    // Above the layer: widened 0..20 misses a layer starting at 25.
    try std.testing.expect(layerRowsForBand(.{ .top_px = 5, .bottom_px = 10 }, 25, 10, 10) == null);
    // A band reaching the layer's first row from above starts at row 0.
    try std.testing.expectEqual([2]u32{ 0, 0 }, layerRowsForBand(.{ .top_px = 10, .bottom_px = 20 }, 25, 10, 10).?);
    // Clamped to the layer's last row.
    // Widened to 100..310: row 7 (95..105) reaches into it.
    try std.testing.expectEqual([2]u32{ 7, 9 }, layerRowsForBand(.{ .top_px = 110, .bottom_px = 300 }, 25, 10, 10).?);
}
