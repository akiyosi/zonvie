// visual/per_grid_font_margin — a window in its own font covers its whole
// frame in its own background, margin included.
//
// A font whose cells do not divide the window's frame leaves a margin right
// of the last column and below the last row. That margin is part of the
// window: it must look like the cells next to it, not like the editor's
// `Normal` behind it.
//
// The oracle is colour geometry. Each window gets a background far from the
// others, and the bounding box of that colour is measured:
//   - a float in `font_view` is drawn as its logical rows and columns in its
//     own cells, so its box must be the extent the core published for it
//     (logged as `per-grid font: publish`), not the box of an identical float
//     without a font;
//   - a split resized into its own font must fill the same height as its
//     neighbour without one, and the width its frame gives it.
//
// The split is resized into its font, so its margin is less than one font
// cell and may be narrower than `slack_px` or zero; that check is a
// regression guard that cannot see such a margin.

const std = @import("std");
const driver = @import("../../driver.zig");
const capture = driver.capture;
const fixture = @import("fixture.zig");
const gui_io = @import("../../gui_io.zig");
const app_log = @import("../../app_log.zig");

const log_path = "tmp/gui_per_grid_font_margin.log";

const normal_bg = [3]u8{ 0x20, 0x60, 0xa0 };
const font_float_bg = [3]u8{ 0xa0, 0x20, 0x60 };
const plain_float_bg = [3]u8{ 0x20, 0xa0, 0x60 };
const font_split_bg = [3]u8{ 0xa0, 0xa0, 0x20 };
const plain_split_bg = [3]u8{ 0x60, 0x20, 0xa0 };

/// A channel may differ by this much (colour-space conversion in the capture).
const tolerance: i32 = 24;
/// Two boxes that should coincide may differ by this many pixels: edge
/// antialiasing and a frame rounded to whole device pixels.
const slack_px: i64 = 3;

const Box = struct {
    x0: i64 = std.math.maxInt(i64),
    y0: i64 = std.math.maxInt(i64),
    x1: i64 = -1,
    y1: i64 = -1,

    fn w(b: Box) i64 {
        return if (b.x1 < b.x0) 0 else b.x1 - b.x0 + 1;
    }
    fn h(b: Box) i64 {
        return if (b.y1 < b.y0) 0 else b.y1 - b.y0 + 1;
    }
};

fn near(img: capture.Image, i: usize, rgb: [3]u8) bool {
    for (0..3) |ch| {
        if (@abs(@as(i32, img.rgba[i + ch]) - @as(i32, rgb[ch])) > tolerance) return false;
    }
    return true;
}

/// Bounding box of every pixel within `tolerance` of `rgb`.
fn colorBox(img: capture.Image, rgb: [3]u8) Box {
    var b = Box{};
    var y: u32 = 0;
    while (y < img.h) : (y += 1) {
        var x: u32 = 0;
        while (x < img.w) : (x += 1) {
            if (!near(img, (@as(usize, y) * img.w + x) * 4, rgb)) continue;
            b.x0 = @min(b.x0, x);
            b.y0 = @min(b.y0, y);
            b.x1 = @max(b.x1, x);
            b.y1 = @max(b.y1, y);
        }
    }
    return b;
}

fn printBox(label: []const u8, b: Box) void {
    std.debug.print("[gui] per_grid_font_margin: {s} box {d}x{d} at ({d},{d})\n", .{ label, b.w(), b.h(), b.x0, b.y0 });
}

pub fn run(alloc: std.mem.Allocator) !void {
    std.Io.Dir.cwd().createDirPath(gui_io.io(), "tmp") catch {};
    std.Io.Dir.cwd().deleteFile(gui_io.io(), log_path) catch {};

    var g = try fixture.openWithLogAndConfig(alloc, log_path, "test/gui/fixtures/config_hosted_opaque");
    defer g.deinit();
    g.activateApp();

    try g.exec("execute('set laststatus=0 noruler noshowcmd showtabline=0 nowrap noswapfile nonumber fillchars=eob:\\ ,vert:\\ ')");
    try g.exec("execute('highlight Normal guibg=#2060a0 guifg=#2060a0')");
    try g.exec("execute('highlight WinSeparator guibg=#000000 guifg=#000000')");
    try g.exec("execute('highlight ZFontFloat guibg=#a02060 guifg=#a02060')");
    try g.exec("execute('highlight ZPlainFloat guibg=#20a060 guifg=#20a060')");
    try g.exec("execute('highlight ZFontSplit guibg=#a0a020 guifg=#a0a020')");
    try g.exec("execute('highlight ZPlainSplit guibg=#6020a0 guifg=#6020a0')");

    // Two splits, one to get a font and one to compare it against; then two
    // identical floats over them, the first to get a font. A new float copies
    // 'winhighlight' from the current window, whose Normal override would
    // then win over NormalFloat, so each float is given its own.
    try g.exec(
        \\luaeval('(function() vim.cmd("vsplit") _G.z_left = vim.api.nvim_get_current_win() vim.cmd("wincmd l") _G.z_right = vim.api.nvim_get_current_win() vim.wo[_G.z_left].winhighlight = "Normal:ZFontSplit" vim.wo[_G.z_right].winhighlight = "Normal:ZPlainSplit" local function f(col, hl) local b = vim.api.nvim_create_buf(false, true) vim.api.nvim_buf_set_lines(b, 0, -1, false, {"", "", "", "", "", ""}) local w = vim.api.nvim_open_win(b, false, {relative="editor", row=2, col=col, width=20, height=6, style="minimal"}) vim.wo[w].winhighlight = hl return w end _G.z_ffloat = f(2, "NormalFloat:ZFontFloat") _G.z_pfloat = f(30, "NormalFloat:ZPlainFloat") return 1 end)()')
    );
    const left_cols = try g.evalInt("luaeval('vim.api.nvim_win_get_width(_G.z_left)')");
    const right_cols = try g.evalInt("luaeval('vim.api.nvim_win_get_width(_G.z_right)')");

    const font_mark = try app_log.lineMark(alloc, log_path);
    try g.exec("luaeval('(function() zonvie.set_window_font(_G.z_ffloat, { scale = 0.5 }) zonvie.set_window_font(_G.z_left, { scale = 0.6 }) return 1 end)()')");
    // The split is resized in its own cells once the font is loaded; the
    // float's font was asked for first, so it is in by then too. The resize
    // only shows in the app log: `nvim_ui_try_resize_grid` changes a split's
    // view size, not the width `nvim_win_get_width` reports.
    const font_grid = try waitFontSplitResized(alloc, font_mark, left_cols);
    std.debug.print("[gui] per_grid_font_margin: font split {d}x{d} cells (was {d} cols wide)\n", .{ font_grid.rows, font_grid.cols, left_cols });

    var img = try g.captureStable(null, 8000);
    defer img.deinit(alloc);
    capture.writeImage(alloc, "tmp/per_grid_font_margin" ++ capture.image_ext, img) catch {};

    const ffloat = colorBox(img, font_float_bg);
    const pfloat = colorBox(img, plain_float_bg);
    const fsplit = colorBox(img, font_split_bg);
    const psplit = colorBox(img, plain_split_bg);
    printBox("font float", ffloat);
    printBox("plain float", pfloat);
    printBox("font split", fsplit);
    printBox("plain split", psplit);
    if (pfloat.w() == 0 or psplit.w() == 0 or ffloat.w() == 0 or fsplit.w() == 0) return error.WindowNotFound;

    var failed = false;
    const extent = try floatExtent(alloc, font_mark);
    std.debug.print("[gui] per_grid_font_margin: font float extent {d}x{d}px, box {d}x{d}px\n", .{ extent.w, extent.h, ffloat.w(), ffloat.h() });
    if (@abs(ffloat.w() - extent.w) > slack_px or @abs(ffloat.h() - extent.h) > slack_px) {
        std.debug.print("[gui] the font float's background does not fill its extent\n", .{});
        failed = true;
    }
    // Control: a half-scale font must actually shrink the float, or the
    // check above compares the plain float with itself.
    if (extent.w * 3 > pfloat.w() * 2) {
        std.debug.print("[gui] the font float's extent is not smaller than the plain float's box\n", .{});
        failed = true;
    }
    // The split's frame: the plain split's height, and the width the vsplit
    // gave it in global cells. Its box must reach the frame; a margin
    // narrower than slack_px is invisible here (see the header).
    const want_w = @divTrunc(psplit.w() * left_cols, right_cols);
    std.debug.print("[gui] per_grid_font_margin: font split frame {d}x{d}px, box {d}x{d}px\n", .{ want_w, psplit.h(), fsplit.w(), fsplit.h() });
    if (fsplit.h() < psplit.h() - slack_px) {
        std.debug.print("[gui] the font split's background does not reach the bottom of its frame\n", .{});
        failed = true;
    }
    if (fsplit.w() < want_w - slack_px) {
        std.debug.print("[gui] the font split's background does not reach the right of its frame\n", .{});
        failed = true;
    }
    if (failed) return error.FontMarginNotWindowBackground;
}

const Extent = struct { w: i64, h: i64 };

/// The last extent the core published for a font_view grid since `after_line`.
fn floatExtent(alloc: std.mem.Allocator, after_line: usize) !Extent {
    const lines = try app_log.linesAfter(alloc, log_path, "per-grid font: publish grid=", after_line);
    defer alloc.free(lines);
    var found: ?Extent = null;
    var it = std.mem.splitScalar(u8, lines, '\n');
    while (it.next()) |line| {
        if (std.mem.indexOf(u8, line, " mode=font_view ") == null) continue;
        const w = app_log.field(line, "extent_w") orelse continue;
        const h = app_log.field(line, "extent_h") orelse continue;
        found = .{ .w = @intFromFloat(w), .h = @intFromFloat(h) };
    }
    return found orelse error.FontFloatExtentNotLogged;
}

const GridSize = struct { rows: i64, cols: i64 };

/// Size of the font split once the app resized a grid other than the root
/// to a column count other than the one the vsplit gave it; the float is
/// never resized.
fn waitFontSplitResized(alloc: std.mem.Allocator, after_line: usize, split_cols: i64) !GridSize {
    var tries: u32 = 0;
    while (tries < 100) : (tries += 1) {
        const lines = try app_log.linesAfter(alloc, log_path, "grid_resize grid=", after_line);
        defer alloc.free(lines);
        var it = std.mem.splitScalar(u8, lines, '\n');
        while (it.next()) |line| {
            const grid = app_log.field(line, "grid") orelse continue;
            const cols = app_log.field(line, "cols") orelse continue;
            const rows = app_log.field(line, "rows") orelse continue;
            if (grid == 1 or @as(i64, @intFromFloat(cols)) == split_cols) continue;
            return .{ .rows = @intFromFloat(rows), .cols = @intFromFloat(cols) };
        }
        gui_io.sleepNs(100 * std.time.ns_per_ms);
    }
    return error.FontSplitNeverResized;
}
