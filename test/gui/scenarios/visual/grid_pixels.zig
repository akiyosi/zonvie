// grid_pixels.zig — locate the editor grid inside a window capture, and find
// the vertical rules drawn on it.
//
// Shared by the two scenarios that check grid 1's own chrome (the split
// divider and the statuslines): both have to say where a given grid row or
// cell column lands in capture pixels, and one of them has to tell a window
// separator apart from text. Neither can take that from a logged cell metric,
// because the only one the app emits is macOS-specific.

const std = @import("std");
const driver = @import("../../driver.zig");

/// Perceptually crude but sufficient: the frontend paints text and chrome in
/// grey on grey, so a plain channel mean separates ink from background.
pub fn luma(img: driver.capture.Image, x: u32, y: u32) u8 {
    const o = (@as(usize, y) * @as(usize, img.w) + @as(usize, x)) * 4;
    const sum = @as(u32, img.rgba[o]) + @as(u32, img.rgba[o + 1]) + @as(u32, img.rgba[o + 2]);
    return @intCast(sum / 3);
}

pub fn isInk(img: driver.capture.Image, x: u32, y: u32, bg: u8) bool {
    const l = luma(img, x, y);
    const d = if (l > bg) l - bg else bg - l;
    return d > 24;
}

/// The luminance that dominates the rectangle [x0, x1) x [y0, y1). Over the
/// whole capture that is the window background; over a single row it is
/// whatever highlight fills that row, which is how a statusline bar is told
/// apart from a row of text.
pub fn modalLuma(img: driver.capture.Image, x0: u32, x1: u32, y0: u32, y1: u32) u8 {
    var hist = [_]u32{0} ** 256;
    var y: u32 = y0;
    while (y < y1) : (y += 1) {
        var x = x0;
        while (x < x1) : (x += 1) hist[luma(img, x, y)] += 1;
    }
    var bg: u8 = 0;
    var best: u32 = 0;
    for (hist, 0..) |n, i| {
        if (n > best) {
            best = n;
            bg = @intCast(i);
        }
    }
    return bg;
}

/// The capture's first row that is mostly background — the top of the grid,
/// below whatever window chrome (title bar) the capture includes. A row of
/// text is mostly background between its glyphs; a title bar is not.
pub fn firstContentRow(img: driver.capture.Image, bg: u8) u32 {
    var y: u32 = 0;
    while (y < img.h) : (y += 1) {
        var bg_px: u32 = 0;
        var x: u32 = 0;
        while (x < img.w) : (x += 1) {
            if (!isInk(img, x, y, bg)) bg_px += 1;
        }
        if (bg_px * 10 > img.w * 4) return y;
    }
    return 0;
}

/// Longest unbroken vertical run of ink at column `x`, from `y0` down.
pub fn longestRun(img: driver.capture.Image, x: u32, y0: u32, bg: u8) u32 {
    var best: u32 = 0;
    var current: u32 = 0;
    var y = y0;
    while (y < img.h) : (y += 1) {
        if (isInk(img, x, y, bg)) {
            current += 1;
            if (current > best) best = current;
        } else {
            current = 0;
        }
    }
    return best;
}

/// Count the cell columns inside [x0_px, x1_px) that carry a vertical rule,
/// and print where they are and how long each one is.
///
/// A rule is an unbroken vertical run of ink at least one and a half rows
/// long. Text cannot reach that: a glyph's ink stops inside its own cell, and
/// as long as consecutive lines do not repeat the same character the next
/// row's ink is somewhere else. A window separator, drawn from cell edge to
/// cell edge, runs unbroken through every row it covers.
pub fn countVerticalRules(
    label: []const u8,
    img: driver.capture.Image,
    x0_px: u32,
    x1_px: u32,
    cell_w_px: f64,
    cell_h_px: f64,
) u32 {
    const bg = modalLuma(img, x0_px, x1_px, 0, img.h);
    // The title bar is a solid block of non-background pixels and would read
    // as a rule in every column, so the scan starts at the grid's first row.
    const y0 = firstContentRow(img, bg);
    const min_run_px: u32 = @intFromFloat(1.5 * cell_h_px);

    std.debug.print(
        "[gui] {s}: vertical rules (bg luma {d}, scan y{d}.. min run {d}px):",
        .{ label, bg, y0, min_run_px },
    );
    var found: u32 = 0;
    // Cell by cell, so a rule spread over several subpixel columns is
    // reported once, at the length of its longest one.
    var cell: u32 = @intFromFloat(@as(f64, @floatFromInt(x0_px)) / cell_w_px);
    const last_cell: u32 = @intFromFloat(@as(f64, @floatFromInt(x1_px - 1)) / cell_w_px);
    while (cell <= last_cell) : (cell += 1) {
        const cx0: u32 = @intFromFloat(@as(f64, @floatFromInt(cell)) * cell_w_px);
        const cx1: u32 = @min(img.w, @as(u32, @intFromFloat(@as(f64, @floatFromInt(cell + 1)) * cell_w_px)));
        var longest: u32 = 0;
        var x = cx0;
        while (x < cx1) : (x += 1) longest = @max(longest, longestRun(img, x, y0, bg));
        if (longest < min_run_px) continue;
        found += 1;
        std.debug.print(" col{d}(run={d}px)", .{ cell, longest });
    }
    if (found == 0) std.debug.print(" none", .{});
    std.debug.print("\n", .{});
    return found;
}
