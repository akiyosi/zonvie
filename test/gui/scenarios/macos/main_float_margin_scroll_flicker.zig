// main_float_margin_scroll_flicker — a bordered float COMPOSITED INTO THE
// MAIN WINDOW must keep its margin rows still during trackpad pixel-scroll.
//
// This is the only configuration that gives the main window a real BOTTOM
// margin row: a main-grid window's winbar makes only a top margin, but a
// float with border="single" carries border rows on both edges
// (marginTop = 2 with a winbar, marginBottom = 1). Scrolling inside the
// float exercises GridSurfaceRenderer's grid_scroll retention capture
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
const margin_scroll = @import("margin_scroll.zig");

const log_path = "tmp/gui_main_float_margin_flicker.log";
const scroll_marker = "[renderer] scroll offset:";

const settle_cycles = 240;
const step_px: f64 = -2;
const nudge_steps: u32 = 1;
const margin_hit_threshold: usize = 3;

const float_rows = 18;
const float_cols = 56;

/// Capture rows of the float's margin bands, from the app's own log line.
/// grid bottom NDC = bot - marginBottom*cellNDC (bot is the CONTENT bottom,
/// marginBottom rows of border sit below it).
fn marginBand(alloc: std.mem.Allocator, capture_h: usize, since_ms: f64) !margin_scroll.Bands {
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
        .top_start = @intFromFloat(@round(chrome + (1.0 - grid_top) / 2.0 * vp_h)),
        .top_end = @intFromFloat(@round(chrome + (1.0 - top) / 2.0 * vp_h)),
        .bot_start = @intFromFloat(@round(chrome + (1.0 - bot) / 2.0 * vp_h)),
        .bot_end = @intFromFloat(@round(chrome + (1.0 - grid_bottom) / 2.0 * vp_h)),
    };
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
    band: margin_scroll.Bands,
    phase: Phase,
) !void {
    var known: ?margin_scroll.Bands = band;
    const s = try margin_scroll.sampleSettle(alloc, g.app_pid, window, base, phase.nudge_px, nudge_steps, settle_cycles, &known, margin_scroll.known_bands);

    std.debug.print(
        "[gui] {s} glide margin bands changed: top={d} bottom={d} of {d}; body {d}/{d}\n",
        .{ phase.label, s.top, s.bottom, s.shots, s.body, s.shots },
    );
    if (s.shots < 20) return error.TooFewCaptures;
    if (s.body == 0) {
        std.debug.print("[gui] scrolling content never changed — captures were not live\n", .{});
        return error.CaptureNotLive;
    }
    if (s.top > 0 or s.bottom > 0) {
        std.debug.print(
            "[gui] a margin row changed during the {s} glide — margin rows do not scroll and must hold still\n",
            .{phase.label},
        );
        return error.MarginRowChanged;
    }

    // Hard scroll and release: the shrink-gated coverage check on the
    // settle, plus a uniformity probe of the band region the offset opens.
    const t0 = try app_log.nowMs(alloc, log_path);
    const probe = margin_scroll.hardScrollBlankBand(alloc, g.app_pid, window, phase.hard_px, phase.blank_start, phase.blank_end);
    std.debug.print(
        "[gui] {s} frames with a blank scroll band: {d}/{d}\n",
        .{ phase.label, probe.blank, probe.shots },
    );
    if (probe.shots < 10) return error.TooFewCaptures;
    if (probe.blank > 0) return error.ScrollBandBlank;

    const cov = try margin_scroll.shrinkCoverageSince(alloc, log_path, scroll_marker, t0);
    std.debug.print(
        "[gui] {s} shrinking-offset frames with an uncovered scroll band: {d}/{d}\n",
        .{ phase.label, cov.uncovered, cov.frames },
    );
    if (cov.frames < 3) return error.TooFewSettleFrames;
    if (cov.uncovered >= margin_hit_threshold) return error.ScrollBandUncovered;
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
    //
    // Centred on the editor rather than placed at a fixed cell: the gesture
    // lands on the window's centre, and the window is whatever frame the
    // app restored from the last session — on a 192x46-cell frame a float
    // at row 1 ended 30 rows above the pointer, so the nudge scrolled the
    // base grid (no margin rows) and the scenario failed before measuring.
    try g.exec(
        "luaeval('(function() local b = vim.api.nvim_create_buf(false, true) " ++
            "local lines = {} for i = 1, 400 do lines[i] = string.rep(\"line \" .. i .. \" \", 6) end " ++
            "vim.api.nvim_buf_set_lines(b, 0, -1, true, lines) " ++
            "local w = " ++ std.fmt.comptimePrint("{d}", .{float_cols}) ++
            " local h = " ++ std.fmt.comptimePrint("{d}", .{float_rows}) ++ " " ++
            "_G.e2e_float = vim.api.nvim_open_win(b, true, " ++
            "{relative=\"editor\", row=math.max(1, math.floor((vim.o.lines - h) / 2)), " ++
            "col=math.max(2, math.floor((vim.o.columns - w) / 2)), width=w, height=h, border=\"single\", " ++
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

    const wins = driver.snapshotWindows(g.app_pid);
    var main_win: ?platform.MainWindow = null;
    for (wins.slice()) |w| {
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
    var band: ?margin_scroll.Bands = null;
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
        .{ b.top_start, b.top_end, b.bot_start, b.bot_end },
    );
    // Wait out the arming nudge's settle, then re-take the rest reference:
    // the nudge scrolled the float, so the original capture's CONTENT is
    // stale — but margins must match it anyway; using a fresh base keeps
    // the body-liveness control meaningful.
    gui_io.sleepNs(700 * std.time.ns_per_ms);
    base.deinit(alloc);
    base = try capture.captureWindow(alloc, window.number);

    const cell = if (b.top_end > b.top_start) (b.top_end - b.top_start) / 2 else 0;
    if (cell == 0) return error.ScrollOffsetUnparsable;

    // Downward: rows leave the TOP, the band opens under the top margin.
    try runPhase(alloc, g, window, base, b, .{
        .label = "down",
        .nudge_px = step_px,
        .hard_px = -12,
        .blank_start = b.top_end,
        .blank_end = b.top_end + cell * 2,
    });
    gui_io.sleepNs(500 * std.time.ns_per_ms);
    // Upward: rows leave the BOTTOM, the band presses on the bottom border.
    try runPhase(alloc, g, window, base, b, .{
        .label = "up",
        .nudge_px = -step_px,
        .hard_px = 12,
        .blank_start = b.bot_start - cell * 2,
        .blank_end = b.bot_start,
    });

    const topline_after = try g.evalInt("luaeval('vim.api.nvim_win_call(_G.e2e_float, function() return vim.fn.line(\"w0\") end)')");
    std.debug.print("[gui] float topline before={d} after={d}\n", .{ topline_before, topline_after });
}
