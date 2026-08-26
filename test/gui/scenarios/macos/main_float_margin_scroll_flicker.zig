// main_float_margin_scroll_flicker — a bordered float COMPOSITED INTO THE
// MAIN WINDOW must keep its margin rows still during trackpad pixel-scroll.
//
// This is the only configuration that gives the main window a real BOTTOM
// margin row: a main-grid window's winbar makes only a top margin, but a
// float with border="single" carries border rows on both edges
// (marginTop = 2 with a winbar, marginBottom = 1). Scrolling inside the
// float exercises MetalTerminalRenderer's grid_scroll retention capture
// (captureOneRetainedRow) — the composited-float path, distinct from both
// the external-window path and the main fast path.
//
// Both directions are driven: rows leave through the TOP on a downward
// scroll and through the BOTTOM on an upward one, and each side's margin
// band is asserted against the same rest-state reference.
//
// The float's band is derived from the [renderer] scroll offset log line
// for the float's grid (gridTop / top / bot / marginBottom / cellNDC /
// vpH), so the float's position inside the composite cannot skew it.
//
// macOS-only.

const std = @import("std");
const driver = @import("../../driver.zig");
const platform = driver.platform;
const capture = driver.capture;
const Gui = driver.Gui;
const app_log = @import("../../app_log.zig");
const gui_io = @import("../../gui_io.zig");

const log_path = "tmp/gui_main_float_margin_flicker.log";
const scroll_marker = "[renderer] scroll offset:";

const settle_cycles = 240;
const step_px: f64 = -2;
const nudge_steps: u32 = 1;
const scrollbar_exclude_px: u32 = 48;
const margin_hit_threshold: usize = 3;
const max_windows = 16;

const float_rows = 18;
const float_cols = 56;

/// Capture rows of the float's margin bands, from the app's own log line.
/// grid bottom NDC = bot - marginBottom*cellNDC (bot is the CONTENT bottom,
/// marginBottom rows of border sit below it).
const MarginBand = struct { start: usize, end: usize, bottom_start: usize, bottom_end: usize };

fn marginBand(alloc: std.mem.Allocator, capture_h: usize, since_ms: f64) !MarginBand {
    const line = (try app_log.lastLineSince(alloc, log_path, scroll_marker, since_ms)) orelse
        return error.NoScrollOffsetLogged;
    defer alloc.free(line);
    const vp_h = app_log.field(line, "vpH") orelse return error.ScrollOffsetUnparsable;
    const grid_top = app_log.field(line, "gridTop") orelse return error.ScrollOffsetUnparsable;
    const top = app_log.field(line, "top") orelse return error.ScrollOffsetUnparsable;
    const bot = app_log.field(line, "bot") orelse return error.ScrollOffsetUnparsable;
    const cell_ndc = app_log.field(line, "cellNDC") orelse return error.ScrollOffsetUnparsable;
    const margin_top = app_log.field(line, "marginTop") orelse return error.ScrollOffsetUnparsable;
    const margin_bottom = app_log.field(line, "marginBottom") orelse return error.ScrollOffsetUnparsable;
    if (margin_top < 1 or margin_bottom < 1) return error.NoMarginRow;
    if (vp_h <= 0 or cell_ndc <= 0) return error.ScrollOffsetUnparsable;
    // Chrome must come from the REAL drawable height, not vpH: vpH is the
    // grid-snapped height (rows * cellH) the NDC space is built on, while
    // the drawable keeps the window's sub-cell remainder (e.g. 826 vs 825).
    // Subtracting vpH put every band one pixel low, and the first content
    // pixel row then landed inside the top band — a zero-tolerance check
    // fails on legitimate scrolling from that alone.
    const dline = (try app_log.lastLineSince(alloc, log_path, "[perf] copy_opportunity", since_ms)) orelse
        return error.NoDrawDebugLogged;
    defer alloc.free(dline);
    const drawable_h = app_log.field(dline, "drawable_h_px") orelse return error.DrawDebugUnparsable;
    const chrome = @as(f64, @floatFromInt(capture_h)) - drawable_h;
    if (chrome < 0) return error.CaptureSmallerThanDrawable;
    const grid_bottom = bot - margin_bottom * cell_ndc;
    // Round, don't truncate: the logged NDC values carry float fuzz
    // (-0.59999996 for -0.6), and truncation pulls a boundary one pixel
    // into the content side.
    return .{
        .start = @intFromFloat(@round(chrome + (1.0 - grid_top) / 2.0 * vp_h)),
        .end = @intFromFloat(@round(chrome + (1.0 - top) / 2.0 * vp_h)),
        .bottom_start = @intFromFloat(@round(chrome + (1.0 - bot) / 2.0 * vp_h)),
        .bottom_end = @intFromFloat(@round(chrome + (1.0 - grid_bottom) / 2.0 * vp_h)),
    };
}

fn bandIsUniform(img: capture.Image, start: usize, end: usize, width: u32) bool {
    if (end <= start or end > img.h or width == 0) return false;
    const stride = @as(usize, img.w) * 4;
    const first = img.rgba[start * stride ..][0..4].*;
    var row = start;
    while (row < end) : (row += 1) {
        const off = row * stride;
        var x: usize = 0;
        while (x < width) : (x += 1) {
            if (!std.mem.eql(u8, img.rgba[off + x * 4 .. off + x * 4 + 4], &first)) return false;
        }
    }
    return true;
}

fn bandsEqual(a: capture.Image, b: capture.Image, start: usize, end: usize, width: u32) bool {
    if (end <= start or end > a.h or end > b.h or a.w != b.w or width == 0) return true;
    const stride = @as(usize, a.w) * 4;
    const bytes = @as(usize, width) * 4;
    var row = start;
    while (row < end) : (row += 1) {
        const off = row * stride;
        if (!std.mem.eql(u8, a.rgba[off .. off + bytes], b.rgba[off .. off + bytes])) return false;
    }
    return true;
}

const Phase = struct {
    label: []const u8,
    /// Sign of the wheel deltas: negative scrolls the buffer downward
    /// (rows leave the TOP), positive upward (rows leave the BOTTOM).
    nudge_px: f64,
    hard_px: f64,
    /// Capture rows of the band the hard scroll opens (probed for
    /// uniformity): just inside the margin the rows press against.
    blank_start: usize,
    blank_end: usize,
};

fn runPhase(
    alloc: std.mem.Allocator,
    g: *Gui,
    window: platform.MainWindow,
    base: capture.Image,
    band: MarginBand,
    phase: Phase,
) !void {
    var top_hits: usize = 0;
    var bottom_hits: usize = 0;
    var body_diffs: usize = 0;
    var shots: usize = 0;

    if (!platform.scrollBegin(g.app_pid, window)) return error.ScrollRefused;
    var n: u32 = 0;
    while (n < nudge_steps) : (n += 1) {
        platform.scrollStep(phase.nudge_px);
        gui_io.sleepNs(16 * std.time.ns_per_ms);
    }
    platform.scrollEnd();

    var c: u32 = 0;
    while (c < settle_cycles) : (c += 1) {
        var shot = capture.captureWindow(alloc, window.number) catch continue;
        shots += 1;
        defer shot.deinit(alloc);
        if (shot.w != base.w or shot.h != base.h) continue;
        const cw = if (shot.w > scrollbar_exclude_px) shot.w - scrollbar_exclude_px else shot.w;
        if (!bandsEqual(shot, base, band.start, band.end, cw)) top_hits += 1;
        if (!bandsEqual(shot, base, band.bottom_start, band.bottom_end, cw)) bottom_hits += 1;
        const stride = @as(usize, shot.w) * 4;
        const mid = (shot.h / 2) * stride;
        const cmp = @as(usize, cw) * 4;
        if (!std.mem.eql(u8, shot.rgba[mid .. mid + cmp], base.rgba[mid .. mid + cmp])) body_diffs += 1;

        if (c % 20 == 19) {
            gui_io.sleepNs(400 * std.time.ns_per_ms);
            if (platform.scrollBegin(g.app_pid, window)) {
                var n2: u32 = 0;
                while (n2 < nudge_steps) : (n2 += 1) {
                    platform.scrollStep(phase.nudge_px);
                    gui_io.sleepNs(16 * std.time.ns_per_ms);
                }
                platform.scrollEnd();
            }
        }
    }

    std.debug.print(
        "[gui] {s} glide margin bands changed: top={d} bottom={d} of {d}; body {d}/{d}\n",
        .{ phase.label, top_hits, bottom_hits, shots, body_diffs, shots },
    );
    if (shots < 20) return error.TooFewCaptures;
    if (body_diffs == 0) {
        std.debug.print("[gui] scrolling content never changed — captures were not live\n", .{});
        return error.CaptureNotLive;
    }
    if (top_hits > 0 or bottom_hits > 0) {
        std.debug.print(
            "[gui] a margin row changed during the {s} glide — margin rows do not scroll and must hold still\n",
            .{phase.label},
        );
        return error.MarginRowChanged;
    }

    // Hard scroll and release: the shrink-gated coverage check on the
    // settle, plus a uniformity probe of the band region the offset opens.
    var blank_band: usize = 0;
    var band_shots: usize = 0;
    const t0 = try app_log.nowMs(alloc, log_path);
    if (platform.scrollBegin(g.app_pid, window)) {
        var k: u32 = 0;
        while (k < 12) : (k += 1) {
            platform.scrollStep(phase.hard_px);
            gui_io.sleepNs(16 * std.time.ns_per_ms);
        }
        platform.scrollEnd();
        while (k < 40) : (k += 1) {
            var shot = capture.captureWindow(alloc, window.number) catch continue;
            defer shot.deinit(alloc);
            band_shots += 1;
            const cw = if (shot.w > scrollbar_exclude_px) shot.w - scrollbar_exclude_px else shot.w;
            if (bandIsUniform(shot, phase.blank_start, phase.blank_end, cw)) blank_band += 1;
            gui_io.sleepNs(16 * std.time.ns_per_ms);
        }
    }
    std.debug.print(
        "[gui] {s} frames with a blank scroll band: {d}/{d}\n",
        .{ phase.label, blank_band, band_shots },
    );
    if (band_shots < 10) return error.TooFewCaptures;
    if (blank_band > 0) return error.ScrollBandBlank;

    const lines = try app_log.linesSince(alloc, log_path, scroll_marker, t0);
    defer alloc.free(lines);
    var uncovered: usize = 0;
    var offset_frames: usize = 0;
    var prev_ndc: ?f64 = null;
    var it = std.mem.splitScalar(u8, lines, '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        const ndc = app_log.field(line, "ndc") orelse continue;
        const cell_ndc = app_log.field(line, "cellNDC") orelse continue;
        const retained = app_log.field(line, "retained") orelse continue;
        defer prev_ndc = ndc;
        if (cell_ndc <= 0) continue;
        const shrinking = if (prev_ndc) |p| @abs(ndc) < @abs(p) else false;
        if (!shrinking) continue;
        // Same rounding as ScrollRetention.coversBand.
        const band_rows = std.math.ceil(@abs(ndc) / cell_ndc - 0.001);
        if (band_rows < 1) continue;
        offset_frames += 1;
        if (retained < band_rows) uncovered += 1;
    }
    std.debug.print(
        "[gui] {s} shrinking-offset frames with an uncovered scroll band: {d}/{d}\n",
        .{ phase.label, uncovered, offset_frames },
    );
    if (offset_frames < 3) return error.TooFewSettleFrames;
    if (uncovered >= margin_hit_threshold) return error.ScrollBandUncovered;
}

pub fn run(alloc: std.mem.Allocator) !void {
    if (!platform.accessibilityTrusted()) {
        std.debug.print(
            "[gui] skipped: not trusted for Accessibility, so scroll gestures cannot target the window.\n",
            .{},
        );
        return error.SkipZigTest;
    }

    std.Io.Dir.cwd().createDirPath(gui_io.io(), "tmp") catch {};
    std.Io.Dir.cwd().deleteFile(gui_io.io(), log_path) catch {};

    var g = try Gui.init(alloc, .{
        .app_args = &.{ "--log", log_path },
        .config_dir = "test/gui/fixtures/config_static_shader",
    });
    defer g.deinit();
    g.activateApp();

    // A bordered, winbar-carrying float composited into the MAIN window
    // (relative='editor', NOT external). Focused, so the wheel over the
    // window center scrolls it. Cursor deep enough to scroll both ways.
    try g.exec(
        "luaeval('(function() local b = vim.api.nvim_create_buf(false, true) " ++
            "local lines = {} for i = 1, 400 do lines[i] = string.rep(\"line \" .. i .. \" \", 6) end " ++
            "vim.api.nvim_buf_set_lines(b, 0, -1, true, lines) " ++
            "_G.e2e_float = vim.api.nvim_open_win(b, true, " ++
            "{relative=\"editor\", row=1, col=2, width=" ++ std.fmt.comptimePrint("{d}", .{float_cols}) ++
            ", height=" ++ std.fmt.comptimePrint("{d}", .{float_rows}) ++ ", border=\"single\", " ++
            // A footer bakes text into the BOTTOM border row (nvim 0.10+),
            // giving the bottom margin row glyphs the way the winbar gives
            // the top one — a corruption there moves many more pixels than
            // a bare border line would.
            "footer=\"FOOTERBAR\", footer_pos=\"left\"}) " ++
            "vim.api.nvim_set_option_value(\"winbar\", \"WINBAR\", {win=_G.e2e_float}) " ++
            "vim.api.nvim_win_set_cursor(_G.e2e_float, {40, 0}) " ++
            "return 1 end)()')",
    );
    gui_io.sleepNs(600 * std.time.ns_per_ms);

    var win_buf: [max_windows]platform.MainWindow = undefined;
    const wins = win_buf[0..platform.windowsForPid(g.app_pid, &win_buf)];
    var main_win: ?platform.MainWindow = null;
    for (wins) |w| {
        if (w.bounds.w >= 150 and w.bounds.h >= 150) {
            main_win = w;
            break;
        }
    }
    const window = main_win orelse return error.MainWindowNotFound;

    const t0 = try app_log.nowMs(alloc, log_path);

    var base = try capture.captureWindow(alloc, window.number);
    defer base.deinit(alloc);
    const capture_h = base.h;

    const topline_before = try g.evalInt("luaeval('vim.api.nvim_win_call(_G.e2e_float, function() return vim.fn.line(\"w0\") end)')");

    // The band is derived from the float grid's own scroll-offset line, so
    // a nudge has to run first to make the app log one.
    if (!platform.scrollBegin(g.app_pid, window)) return error.ScrollRefused;
    platform.scrollStep(step_px);
    gui_io.sleepNs(16 * std.time.ns_per_ms);
    platform.scrollEnd();
    var band: ?MarginBand = null;
    var tries: u32 = 0;
    while (tries < 50) : (tries += 1) {
        if (marginBand(alloc, capture_h, t0)) |b| {
            band = b;
            break;
        } else |_| {}
        gui_io.sleepNs(100 * std.time.ns_per_ms);
    }
    const b = band orelse return error.NoScrollOffsetLogged;
    std.debug.print(
        "[gui] float margin bands {d}..{d} and {d}..{d}\n",
        .{ b.start, b.end, b.bottom_start, b.bottom_end },
    );
    // Wait out the arming nudge's settle, then re-take the rest reference:
    // the nudge scrolled the float, so the original capture's CONTENT is
    // stale — but margins must match it anyway; using a fresh base keeps
    // the body-liveness control meaningful.
    gui_io.sleepNs(700 * std.time.ns_per_ms);
    base.deinit(alloc);
    base = try capture.captureWindow(alloc, window.number);

    const cell = if (b.end > b.start) (b.end - b.start) / 2 else 0;
    if (cell == 0) return error.ScrollOffsetUnparsable;

    // Downward: rows leave the TOP, the band opens under the top margin.
    try runPhase(alloc, g, window, base, b, .{
        .label = "down",
        .nudge_px = step_px,
        .hard_px = -12,
        .blank_start = b.end,
        .blank_end = b.end + cell * 2,
    });
    gui_io.sleepNs(500 * std.time.ns_per_ms);
    // Upward: rows leave the BOTTOM, the band presses on the bottom border.
    try runPhase(alloc, g, window, base, b, .{
        .label = "up",
        .nudge_px = -step_px,
        .hard_px = 12,
        .blank_start = b.bottom_start - cell * 2,
        .blank_end = b.bottom_start,
    });

    const topline_after = try g.evalInt("luaeval('vim.api.nvim_win_call(_G.e2e_float, function() return vim.fn.line(\"w0\") end)')");
    std.debug.print("[gui] float topline before={d} after={d}\n", .{ topline_before, topline_after });
}
