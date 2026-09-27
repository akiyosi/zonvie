// main_margin_scroll_flicker — the MAIN window's margin rows must hold
// still during a trackpad pixel-scroll.
//
// Companion to extfloat_margin_scroll_flicker: the external-float bug
// (retained scroll rows carrying non-scrollable margin-column cells that
// escape the offset shift and the content clip) was structurally possible
// on the main window's row-scroll fast path too — it whole-row-copied and
// was safe only because the rows it can reach today happen to hold only
// scrollable cells. Both capture paths now share the DECO_SCROLLABLE
// filter (copyRetainedScrollableRow); this scenario pins the main-window
// behavior the same way the float scenario pins the external one.
//
// A winbar ('winbar' on the current window) provides marginTop = 1. The
// main window has no bottom margin row; 'laststatus'=0 and 'noruler' make
// the region BELOW the scrolled content (cmdline row) static, so it is
// asserted as the bottom band instead.
//
// The margin band is derived from the app's own [renderer] scroll offset
// log line (gridTop / top / bot / cellNDC / vpH), so tabline presence or
// the window's position inside the composite cannot skew it.
//
// macOS-only: drives the macOS frontend's smooth-scroll path.

const std = @import("std");
const driver = @import("../../driver.zig");
const platform = driver.platform;
const capture = driver.capture;
const Gui = driver.Gui;
const app_log = @import("../../app_log.zig");
const gui_io = @import("../../gui_io.zig");
const margin_scroll = @import("margin_scroll.zig");

const log_path = "tmp/gui_main_margin_flicker.log";
const scroll_marker = "[renderer] scroll offset:";

const settle_cycles = 240;
/// See extfloat_margin_scroll_flicker: a single tiny delta, released below
/// Neovim's booked scroll unit so the settle animation runs the offset out.
const step_px: f64 = -2;
const nudge_steps: u32 = 1;
/// Threshold for the log-side coverage check only; the pixel margin check
/// is zero-tolerance.
const margin_hit_threshold: usize = 3;

/// Capture rows the margin occupies, derived from the app's own log line.
/// The fragment NDC space maps pixel y to 1 - y*(2/vpH), so pixel of an
/// NDC value is (1 - ndc)/2 * vpH; capture rows are chrome + that. The
/// bottom band is everything below the scrolled content.
fn marginBand(alloc: std.mem.Allocator, capture_h: usize, since_ms: f64) !margin_scroll.Bands {
    const line = (try app_log.lastLineSince(alloc, log_path, scroll_marker, since_ms)) orelse
        return error.NoScrollOffsetLogged;
    defer alloc.free(line);
    const vp_h = app_log.field(line, "vpH") orelse return error.ScrollOffsetUnparsable;
    const grid_top = app_log.field(line, "gridTop") orelse return error.ScrollOffsetUnparsable;
    const top = app_log.field(line, "top") orelse return error.ScrollOffsetUnparsable;
    const bot = app_log.field(line, "bot") orelse return error.ScrollOffsetUnparsable;
    const margin_top = app_log.field(line, "marginTop") orelse return error.ScrollOffsetUnparsable;
    if (margin_top < 1) return error.NoMarginRow;
    if (vp_h <= 0) return error.ScrollOffsetUnparsable;
    // Chrome must come from the REAL drawable height, not vpH: vpH is the
    // grid-snapped height (rows * cellH) the NDC space is built on, while
    // the drawable keeps the window's sub-cell remainder. Subtracting vpH
    // put every band low by that remainder, and the first content pixel
    // rows then landed inside the top band, where legitimate scrolling read
    // as a margin row moving. The window is whatever frame the app restored
    // from the last session, so whether the remainder is zero changes from
    // run to run — which is what made this look flaky. Same correction the
    // float scenario carries.
    const dline = (try app_log.lastLineSince(alloc, log_path, "[perf] copy_opportunity", since_ms)) orelse
        return error.NoDrawDebugLogged;
    defer alloc.free(dline);
    const drawable_h = app_log.field(dline, "drawable_h_px") orelse return error.DrawDebugUnparsable;
    const chrome = @as(f64, @floatFromInt(capture_h)) - drawable_h;
    if (chrome < 0) return error.CaptureSmallerThanDrawable;
    // Round, don't truncate: the logged NDC values carry float fuzz, and
    // truncation pulls a boundary one pixel into the content side.
    return .{
        .top_start = @intFromFloat(@round(chrome + (1.0 - grid_top) / 2.0 * vp_h)),
        .top_end = @intFromFloat(@round(chrome + (1.0 - top) / 2.0 * vp_h)),
        .bot_start = @intFromFloat(@round(chrome + (1.0 - bot) / 2.0 * vp_h)),
        .bot_end = capture_h,
    };
}

pub fn run(alloc: std.mem.Allocator) !void {
    if (!platform.accessibilityTrusted()) {
        std.debug.print(
            "[gui] skipped: not trusted for Accessibility, so scroll gestures cannot target the window. " ++
                "Grant this binary under System Settings > Privacy & Security > Accessibility.\n",
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

    // Winbar gives marginTop = 1. laststatus=0 + noruler keep everything
    // below the scrolled content static (a ruler repaints with the topline,
    // which would fail the bottom-band check for a legitimate reason).
    try g.exec(
        "luaeval('(function() local lines = {} " ++
            "for i = 1, 400 do lines[i] = string.rep(\"line \" .. i .. \" \", 6) end " ++
            "vim.api.nvim_buf_set_lines(0, 0, -1, true, lines) " ++
            "vim.o.laststatus = 0 vim.o.ruler = false " ++
            "vim.api.nvim_set_option_value(\"winbar\", \"WINBAR\", {win=0}) " ++
            "vim.api.nvim_win_set_cursor(0, {40, 0}) " ++
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

    // Rest reference BEFORE the gesture opens — same reasoning as the
    // float scenario: margin rows do not scroll, so their pixels at rest
    // are the truth for the whole glide, and an in-gesture reference would
    // hide a corruption that persists across the gesture.
    var base = try capture.captureWindow(alloc, window.number);
    defer base.deinit(alloc);

    const topline_before = try g.evalInt("luaeval('vim.fn.line(\"w0\")')");

    var bands: ?margin_scroll.Bands = null;
    const down = try margin_scroll.sampleSettle(
        alloc,
        g.app_pid,
        window,
        base,
        step_px,
        nudge_steps,
        settle_cycles,
        &bands,
        margin_scroll.LogBands(marginBand){ .alloc = alloc, .capture_h = base.h, .since_ms = t0 },
    );

    if (down.shots < 20) return error.TooFewCaptures;
    const band = bands orelse margin_scroll.Bands{ .top_start = 0, .top_end = 0, .bot_start = 0, .bot_end = 0 };
    std.debug.print(
        "[gui] margin bands {d}..{d} and {d}..{d}; changed: top={d} bottom={d} of {d}; body {d}/{d}\n",
        .{ band.top_start, band.top_end, band.bot_start, band.bot_end, down.top, down.bottom, down.shots, down.body, down.shots },
    );
    if (bands == null) return error.NoScrollOffsetLogged;
    // Liveness control, ENFORCED: if the scrolling content never differed
    // from the rest reference, the captures were not observing live frames
    // and the margin result means nothing.
    if (down.body == 0) {
        std.debug.print("[gui] scrolling content never changed — captures were not live\n", .{});
        return error.CaptureNotLive;
    }

    const topline_after = try g.evalInt("luaeval('vim.fn.line(\"w0\")')");
    std.debug.print("[gui] Neovim topline before={d} after={d}\n", .{ topline_before, topline_after });

    // Second phase: a hard scroll and release, then the log-side band
    // coverage check on SHRINKING-offset frames — same rationale and same
    // arithmetic as the float scenario (see there for why growing-offset
    // frames are excluded and why the pixel probe alone is too blunt).
    // The margin band is one cell (the winbar); the probe covers the two
    // content rows just inside it.
    const cell = band.top_end - band.top_start;
    {
        const phase2_t0 = try app_log.nowMs(alloc, log_path);
        const probe = margin_scroll.hardScrollBlankBand(alloc, g.app_pid, window, -12, band.top_end, band.top_end + cell * 2);
        std.debug.print("[gui] frames with a blank scroll band: {d}/{d}\n", .{ probe.blank, probe.shots });
        if (probe.shots < 10) return error.TooFewCaptures;
        if (probe.blank > 0) return error.ScrollBandBlank;

        const cov = try margin_scroll.shrinkCoverageSince(alloc, log_path, scroll_marker, phase2_t0);
        std.debug.print(
            "[gui] shrinking-offset frames with an uncovered scroll band: {d}/{d}\n",
            .{ cov.uncovered, cov.frames },
        );
        if (cov.frames < 3) return error.TooFewSettleFrames;
        if (cov.uncovered >= margin_hit_threshold) {
            std.debug.print(
                "[gui] retained rows expired while the offset still held their band open\n",
                .{},
            );
            return error.ScrollBandUncovered;
        }
    }

    // Third phase: the same gestures UPWARD. Rows then leave through the
    // BOTTOM edge and the retained rows target the rows just above the
    // static region below the content (cmdline row, sub-cell leftover
    // strip) — the side the downward phases never exercise. The buffer
    // sits ~100 lines deep after them, so there is room to scroll back up.
    {
        gui_io.sleepNs(500 * std.time.ns_per_ms);
        const up = try margin_scroll.sampleSettle(alloc, g.app_pid, window, base, -step_px, nudge_steps, settle_cycles, &bands, margin_scroll.known_bands);
        std.debug.print(
            "[gui] up-glide margin bands changed: top={d} bottom={d} of {d}; body {d}/{d}\n",
            .{ up.top, up.bottom, up.shots, up.body, up.shots },
        );
        if (up.shots < 20) return error.TooFewCaptures;
        if (up.body == 0) {
            std.debug.print("[gui] scrolling content never changed during the upward glide — captures were not live\n", .{});
            return error.CaptureNotLive;
        }
        if (up.top > 0 or up.bottom > 0) {
            std.debug.print(
                "[gui] a margin row changed during the upward glide — margin rows do not scroll and must hold still\n",
                .{},
            );
            return error.MarginRowChanged;
        }

        // Hard upward scroll and release, with the shrink-gated coverage
        // check on the settle — same rule as the downward phase.
        const up_t0 = try app_log.nowMs(alloc, log_path);
        const up_blank_start = if (band.bot_start > cell * 2) band.bot_start - cell * 2 else band.bot_start;
        const probe = margin_scroll.hardScrollBlankBand(alloc, g.app_pid, window, 12, up_blank_start, band.bot_start);
        std.debug.print("[gui] up frames with a blank scroll band: {d}/{d}\n", .{ probe.blank, probe.shots });
        if (probe.shots < 10) return error.TooFewCaptures;
        if (probe.blank > 0) return error.ScrollBandBlank;

        const cov = try margin_scroll.shrinkCoverageSince(alloc, log_path, scroll_marker, up_t0);
        std.debug.print(
            "[gui] up shrinking-offset frames with an uncovered scroll band: {d}/{d}\n",
            .{ cov.uncovered, cov.frames },
        );
        if (cov.frames < 3) return error.TooFewSettleFrames;
        if (cov.uncovered >= margin_hit_threshold) return error.ScrollBandUncovered;
    }

    if (down.top > 0 or down.bottom > 0) {
        std.debug.print(
            "[gui] a margin row changed during the glide — margin rows do not scroll and must hold still\n",
            .{},
        );
        return error.MarginRowChanged;
    }
}
