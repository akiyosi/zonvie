// visual/shader_covers_all_grids — a custom post-process shader must see the
// whole main surface, and its cursor uniform must follow the cursor into any
// grid.
//
// Per-grid rendering draws each window grid as its own layer and submits its
// vertices in grid-local pixels. The custom shader chain replaces the
// back-buffer blit, so coverage is structurally uniform; the cursor uniform
// is not, because it is derived from those raw cursor vertices and the
// shader reads it in screen space. Without the layer origin added, a cursor
// shader keeps drawing over the top-left window no matter which split holds
// the cursor.
//
// The probe shader marks both: a magenta diagonal stripe over every pixel it
// processed, and a green vertical band at iCurrentCursor.x.

const std = @import("std");
const driver = @import("../../driver.zig");
const Gui = driver.Gui;
const gui_io = @import("../../gui_io.zig");
const app_log = @import("../../app_log.zig");

const log_path = "tmp/gui_shader_probe.log";

/// Full-window capture, not a fixed crop: the cursor band can land anywhere
/// across the window's width, and a crop narrower than the window would put
/// the right split's band outside the image and read as "not rendered".
const crop: ?driver.capture.Crop = null;

/// Minimum green pixels before the cursor-band check means anything. A run
/// that rendered no band at all would otherwise report a centroid of zero
/// and pass the left-phase assertion for the wrong reason.
const min_band_px: usize = 200;

fn stripeFraction(img: driver.capture.Image, x0: usize, x1: usize, y0: usize, y1: usize) f64 {
    var hits: usize = 0;
    var total: usize = 0;
    var y = y0;
    while (y < y1) : (y += 1) {
        var x = x0;
        while (x < x1) : (x += 1) {
            const i = (y * img.w + x) * 4;
            const r: u16 = img.rgba[i];
            const g: u16 = img.rgba[i + 1];
            const b: u16 = img.rgba[i + 2];
            total += 1;
            if (r > g + 40 and b > g + 40) hits += 1;
        }
    }
    if (total == 0) return 0;
    return @as(f64, @floatFromInt(hits)) / @as(f64, @floatFromInt(total));
}

/// Mean x of the green cursor band, plus how many pixels it was measured from.
fn bandCentroidX(img: driver.capture.Image, y0: usize, y1: usize) struct { x: f64, n: usize } {
    var sum: f64 = 0;
    var n: usize = 0;
    var y = y0;
    while (y < y1) : (y += 1) {
        var x: usize = 0;
        while (x < img.w) : (x += 1) {
            const i = (y * img.w + x) * 4;
            const r: u16 = img.rgba[i];
            const g: u16 = img.rgba[i + 1];
            const b: u16 = img.rgba[i + 2];
            if (g > r + 40 and g > b + 40) {
                sum += @floatFromInt(x);
                n += 1;
            }
        }
    }
    return .{ .x = if (n == 0) 0 else sum / @as(f64, @floatFromInt(n)), .n = n };
}

/// Where the band must land, in capture pixels, for the window holding the
/// cursor: its first screen column times the cell width. This makes both
/// phases exact rather than "somewhere in the correct half" — a cursor
/// pinned to the top-left window produces a left-half band all by itself,
/// and an origin error of a few cells, or one that used the anchor grid
/// instead of the layer, stays inside the half it belongs to.
fn expectedBandX(g: *Gui, cell_w: f64) !f64 {
    const win_col = try g.evalInt("win_screenpos(0)[1]");
    return @as(f64, @floatFromInt(win_col - 1)) * cell_w;
}

pub fn run(alloc: std.mem.Allocator) !void {
    // A log left by a previous run holds that run's [resizeExternalWindows]
    // line, and the cellW read below does not filter by timestamp — a stale
    // cell width would silently become this run's expectation.
    std.Io.Dir.cwd().createDirPath(gui_io.io(), "tmp") catch {};
    std.Io.Dir.cwd().deleteFile(gui_io.io(), log_path) catch {};

    var g = try Gui.init(alloc, .{
        .app_args = &.{ "--log", log_path },
        .config_dir = "test/gui/fixtures/config_cursor_shader",
    });
    defer g.deinit();
    g.activateApp();

    try g.exec("execute('set laststatus=0 noruler noshowcmd nowrap')");
    try g.exec(
        \\setline(1, map(range(1, 200), {_, i -> printf('%3d %s', i, repeat(nr2char(65 + i % 26), 40))}))
    );
    try g.exec("execute('vsplit')");
    try g.exec("execute('wincmd =')");
    try g.exec("execute('wincmd h')");
    gui_io.sleepNs(800 * std.time.ns_per_ms);

    var left_img = try g.captureStable(crop, 8000);
    defer left_img.deinit(alloc);

    const w: usize = left_img.w;
    const h: usize = left_img.h;
    const y0 = h / 6;
    const y1 = h - h / 6;

    // Coverage: sample each split by column band, away from the seam and the
    // window edge so padding cannot dominate either side.
    const left_cov = stripeFraction(left_img, w / 12, w * 5 / 12, y0, y1);
    const right_cov = stripeFraction(left_img, w * 7 / 12, w * 11 / 12, y0, y1);
    std.debug.print(
        "[gui] shader stripe coverage: left={d:.4} right={d:.4} (capture {d}x{d})\n",
        .{ left_cov, right_cov, w, h },
    );
    // The stripe covers half the surface by construction, so a side the
    // shader reached lands near 0.5 and a side it did not lands near 0.
    if (left_cov < 0.2 or right_cov < 0.2) {
        std.debug.print("[gui] a split did not receive the shader\n", .{});
        return error.ShaderCoverageMissing;
    }

    // The cell width the app is actually laying out with, which turns a
    // window's screen column into the x the band must land on.
    const cell_w = blk: {
        const line = (try app_log.lastLineSince(alloc, log_path, "[resizeExternalWindows]", 0)) orelse
            return error.CellMetricsUnknown;
        defer alloc.free(line);
        break :blk app_log.field(line, "cellW") orelse return error.CellMetricsUnknown;
    };

    const left_band = bandCentroidX(left_img, y0, y1);
    const left_expected_x = try expectedBandX(g, cell_w);
    std.debug.print(
        "[gui] cursor band with cursor in LEFT split: x={d:.1} px={d}; expected {d:.1} (cell {d:.1}px)\n",
        .{ left_band.x, left_band.n, left_expected_x, cell_w },
    );
    if (left_band.n < min_band_px) return error.CursorBandNotRendered;
    if (@abs(left_band.x - left_expected_x) > cell_w) {
        std.debug.print("[gui] cursor band is not in the split holding the cursor\n", .{});
        return error.CursorUniformMisplaced;
    }

    // Move the cursor into the OTHER split. Its grid is drawn as a layer at a
    // non-zero origin, which is the case the grid-local vertices do not carry.
    try g.exec("execute('wincmd l')");
    gui_io.sleepNs(600 * std.time.ns_per_ms);

    var right_img = try g.captureStable(crop, 8000);
    defer right_img.deinit(alloc);

    const right_band = bandCentroidX(right_img, y0, y1);

    const expected_x = try expectedBandX(g, cell_w);
    std.debug.print(
        "[gui] cursor band with cursor in RIGHT split: x={d:.1} px={d}; expected {d:.1} (cell {d:.1}px)\n",
        .{ right_band.x, right_band.n, expected_x, cell_w },
    );
    if (right_band.n < min_band_px) return error.CursorBandNotRendered;
    if (@abs(right_band.x - expected_x) > cell_w) {
        std.debug.print("[gui] the cursor uniform is not where the cursor is\n", .{});
        return error.CursorUniformMisplaced;
    }
}
