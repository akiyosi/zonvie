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

const log_path = "tmp/gui_main_margin_flicker.log";
const scroll_marker = "[renderer] scroll offset:";

const settle_cycles = 240;
/// See extfloat_margin_scroll_flicker: a single tiny delta, released below
/// Neovim's booked scroll unit so the settle animation runs the offset out.
const step_px: f64 = -2;
const nudge_steps: u32 = 1;
const scrollbar_exclude_px: u32 = 48;
/// Threshold for the log-side coverage check only; the pixel margin check
/// is zero-tolerance.
const margin_hit_threshold: usize = 3;
const max_windows = 16;

/// Capture rows the margin occupies, derived from the app's own log line.
/// The fragment NDC space maps pixel y to 1 - y*(2/vpH), so pixel of an
/// NDC value is (1 - ndc)/2 * vpH; capture rows are chrome + that.
const MarginBand = struct { start: usize, end: usize, bottom_start: usize, drawable_end: usize };

fn marginBand(alloc: std.mem.Allocator, capture_h: usize, since_ms: f64) !MarginBand {
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
    const chrome = @as(f64, @floatFromInt(capture_h)) - vp_h;
    if (chrome < 0) return error.CaptureSmallerThanDrawable;
    const grid_top_px = chrome + (1.0 - grid_top) / 2.0 * vp_h;
    const content_top_px = chrome + (1.0 - top) / 2.0 * vp_h;
    const content_bot_px = chrome + (1.0 - bot) / 2.0 * vp_h;
    return .{
        .start = @intFromFloat(grid_top_px),
        .end = @intFromFloat(content_top_px),
        .bottom_start = @intFromFloat(content_bot_px),
        .drawable_end = capture_h,
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

    var base: ?capture.Image = null;
    defer if (base) |*b| b.deinit(alloc);
    var shots: usize = 0;
    var body_diffs: usize = 0;
    var top_hits: usize = 0;
    var bottom_hits: usize = 0;
    var band_known = false;
    var band_top_start: usize = 0;
    var band_top_end: usize = 0;
    var band_bot_start: usize = 0;
    var band_bot_end: usize = 0;
    var capture_h: usize = 0;

    // Rest reference BEFORE the gesture opens — same reasoning as the
    // float scenario: margin rows do not scroll, so their pixels at rest
    // are the truth for the whole glide, and an in-gesture reference would
    // hide a corruption that persists across the gesture.
    base = try capture.captureWindow(alloc, window.number);
    capture_h = base.?.h;

    const topline_before = try g.evalInt("luaeval('vim.fn.line(\"w0\")')");

    if (!platform.scrollBegin(g.app_pid, window)) return error.ScrollRefused;
    var nudge: u32 = 0;
    while (nudge < nudge_steps) : (nudge += 1) {
        platform.scrollStep(step_px);
        gui_io.sleepNs(16 * std.time.ns_per_ms);
    }
    platform.scrollEnd();

    var cycle: u32 = 0;
    while (cycle < settle_cycles) : (cycle += 1) {
        var shot = capture.captureWindow(alloc, window.number) catch continue;
        shots += 1;
        if (!band_known) {
            if (marginBand(alloc, capture_h, t0)) |b| {
                band_top_start = b.start;
                band_top_end = b.end;
                band_bot_start = b.bottom_start;
                band_bot_end = b.drawable_end;
                band_known = true;
            } else |_| {}
        }
        defer shot.deinit(alloc);
        const b = base.?;
        if (shot.w != b.w or shot.h != b.h) continue;
        const compare_w = if (shot.w > scrollbar_exclude_px) shot.w - scrollbar_exclude_px else shot.w;
        if (band_known) {
            if (!bandsEqual(shot, b, band_top_start, band_top_end, compare_w)) top_hits += 1;
            if (!bandsEqual(shot, b, band_bot_start, band_bot_end, compare_w)) bottom_hits += 1;
        }
        const stride = @as(usize, shot.w) * 4;
        const mid = (shot.h / 2) * stride;
        const cmp = @as(usize, compare_w) * 4;
        if (!std.mem.eql(u8, shot.rgba[mid .. mid + cmp], b.rgba[mid .. mid + cmp])) body_diffs += 1;

        if (cycle % 20 == 19) {
            gui_io.sleepNs(400 * std.time.ns_per_ms);
            if (platform.scrollBegin(g.app_pid, window)) {
                var n2: u32 = 0;
                while (n2 < nudge_steps) : (n2 += 1) {
                    platform.scrollStep(step_px);
                    gui_io.sleepNs(16 * std.time.ns_per_ms);
                }
                platform.scrollEnd();
            }
        }
    }

    if (shots < 20) return error.TooFewCaptures;
    std.debug.print(
        "[gui] margin bands {d}..{d} and {d}..{d}; changed: top={d} bottom={d} of {d}; body {d}/{d}\n",
        .{ band_top_start, band_top_end, band_bot_start, band_bot_end, top_hits, bottom_hits, shots, body_diffs, shots },
    );
    if (!band_known) return error.NoScrollOffsetLogged;
    // Liveness control, ENFORCED: if the scrolling content never differed
    // from the rest reference, the captures were not observing live frames
    // and the margin result means nothing.
    if (body_diffs == 0) {
        std.debug.print("[gui] scrolling content never changed — captures were not live\n", .{});
        return error.CaptureNotLive;
    }

    const topline_after = try g.evalInt("luaeval('vim.fn.line(\"w0\")')");
    std.debug.print("[gui] Neovim topline before={d} after={d}\n", .{ topline_before, topline_after });

    // Second phase: a hard scroll and release, then the log-side band
    // coverage check on SHRINKING-offset frames — same rationale and same
    // arithmetic as the float scenario (see there for why growing-offset
    // frames are excluded and why the pixel probe alone is too blunt).
    {
        var blank_band: usize = 0;
        var band_shots: usize = 0;
        const phase2_t0 = try app_log.nowMs(alloc, log_path);
        if (platform.scrollBegin(g.app_pid, window)) {
            var k: u32 = 0;
            while (k < 12) : (k += 1) {
                platform.scrollStep(-12);
                gui_io.sleepNs(16 * std.time.ns_per_ms);
            }
            platform.scrollEnd();
            while (k < 40) : (k += 1) {
                var shot = capture.captureWindow(alloc, window.number) catch continue;
                defer shot.deinit(alloc);
                band_shots += 1;
                const cw = if (shot.w > scrollbar_exclude_px) shot.w - scrollbar_exclude_px else shot.w;
                const cell = band_top_end - band_top_start;
                if (cell > 0 and bandIsUniform(shot, band_top_end, band_top_end + cell * 2, cw)) blank_band += 1;
                gui_io.sleepNs(16 * std.time.ns_per_ms);
            }
        }
        std.debug.print("[gui] frames with a blank scroll band: {d}/{d}\n", .{ blank_band, band_shots });
        if (band_shots < 10) return error.TooFewCaptures;
        if (blank_band > 0) return error.ScrollBandBlank;

        const lines = try app_log.linesSince(alloc, log_path, scroll_marker, phase2_t0);
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
            "[gui] shrinking-offset frames with an uncovered scroll band: {d}/{d}\n",
            .{ uncovered, offset_frames },
        );
        if (offset_frames < 3) return error.TooFewSettleFrames;
        if (uncovered >= margin_hit_threshold) {
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
        var up_top: usize = 0;
        var up_bottom: usize = 0;
        var up_body: usize = 0;
        var up_shots: usize = 0;
        if (!platform.scrollBegin(g.app_pid, window)) return error.ScrollRefused;
        var n: u32 = 0;
        while (n < nudge_steps) : (n += 1) {
            platform.scrollStep(-step_px);
            gui_io.sleepNs(16 * std.time.ns_per_ms);
        }
        platform.scrollEnd();
        var c: u32 = 0;
        while (c < settle_cycles) : (c += 1) {
            var shot = capture.captureWindow(alloc, window.number) catch continue;
            up_shots += 1;
            defer shot.deinit(alloc);
            const b = base.?;
            if (shot.w != b.w or shot.h != b.h) continue;
            const cw = if (shot.w > scrollbar_exclude_px) shot.w - scrollbar_exclude_px else shot.w;
            if (!bandsEqual(shot, b, band_top_start, band_top_end, cw)) up_top += 1;
            if (!bandsEqual(shot, b, band_bot_start, band_bot_end, cw)) up_bottom += 1;
            const stride = @as(usize, shot.w) * 4;
            const mid = (shot.h / 2) * stride;
            const cmp = @as(usize, cw) * 4;
            if (!std.mem.eql(u8, shot.rgba[mid .. mid + cmp], b.rgba[mid .. mid + cmp])) up_body += 1;
            if (c % 20 == 19) {
                gui_io.sleepNs(400 * std.time.ns_per_ms);
                if (platform.scrollBegin(g.app_pid, window)) {
                    var n2: u32 = 0;
                    while (n2 < nudge_steps) : (n2 += 1) {
                        platform.scrollStep(-step_px);
                        gui_io.sleepNs(16 * std.time.ns_per_ms);
                    }
                    platform.scrollEnd();
                }
            }
        }
        std.debug.print(
            "[gui] up-glide margin bands changed: top={d} bottom={d} of {d}; body {d}/{d}\n",
            .{ up_top, up_bottom, up_shots, up_body, up_shots },
        );
        if (up_shots < 20) return error.TooFewCaptures;
        if (up_body == 0) {
            std.debug.print("[gui] scrolling content never changed during the upward glide — captures were not live\n", .{});
            return error.CaptureNotLive;
        }
        if (up_top > 0 or up_bottom > 0) {
            std.debug.print(
                "[gui] a margin row changed during the upward glide — margin rows do not scroll and must hold still\n",
                .{},
            );
            return error.MarginRowChanged;
        }

        // Hard upward scroll and release, with the shrink-gated coverage
        // check on the settle — same rule as the downward phase.
        var blank_band: usize = 0;
        var band_shots: usize = 0;
        const up_t0 = try app_log.nowMs(alloc, log_path);
        if (platform.scrollBegin(g.app_pid, window)) {
            var k: u32 = 0;
            while (k < 12) : (k += 1) {
                platform.scrollStep(12);
                gui_io.sleepNs(16 * std.time.ns_per_ms);
            }
            platform.scrollEnd();
            while (k < 40) : (k += 1) {
                var shot = capture.captureWindow(alloc, window.number) catch continue;
                defer shot.deinit(alloc);
                band_shots += 1;
                const cw = if (shot.w > scrollbar_exclude_px) shot.w - scrollbar_exclude_px else shot.w;
                const cell = band_top_end - band_top_start;
                if (cell > 0 and band_bot_start > cell * 2 and
                    bandIsUniform(shot, band_bot_start - cell * 2, band_bot_start, cw)) blank_band += 1;
                gui_io.sleepNs(16 * std.time.ns_per_ms);
            }
        }
        std.debug.print("[gui] up frames with a blank scroll band: {d}/{d}\n", .{ blank_band, band_shots });
        if (band_shots < 10) return error.TooFewCaptures;
        if (blank_band > 0) return error.ScrollBandBlank;

        const up_lines = try app_log.linesSince(alloc, log_path, scroll_marker, up_t0);
        defer alloc.free(up_lines);
        var up_uncovered: usize = 0;
        var up_offset_frames: usize = 0;
        var up_prev_ndc: ?f64 = null;
        var up_it = std.mem.splitScalar(u8, up_lines, '\n');
        while (up_it.next()) |line| {
            if (line.len == 0) continue;
            const ndc = app_log.field(line, "ndc") orelse continue;
            const cell_ndc = app_log.field(line, "cellNDC") orelse continue;
            const retained = app_log.field(line, "retained") orelse continue;
            defer up_prev_ndc = ndc;
            if (cell_ndc <= 0) continue;
            const shrinking = if (up_prev_ndc) |p| @abs(ndc) < @abs(p) else false;
            if (!shrinking) continue;
            // Same rounding as ScrollRetention.coversBand.
            const band_rows = std.math.ceil(@abs(ndc) / cell_ndc - 0.001);
            if (band_rows < 1) continue;
            up_offset_frames += 1;
            if (retained < band_rows) up_uncovered += 1;
        }
        std.debug.print(
            "[gui] up shrinking-offset frames with an uncovered scroll band: {d}/{d}\n",
            .{ up_uncovered, up_offset_frames },
        );
        if (up_offset_frames < 3) return error.TooFewSettleFrames;
        if (up_uncovered >= margin_hit_threshold) return error.ScrollBandUncovered;
    }

    if (top_hits > 0 or bottom_hits > 0) {
        std.debug.print(
            "[gui] a margin row changed during the glide — margin rows do not scroll and must hold still\n",
            .{},
        );
        return error.MarginRowChanged;
    }
}
