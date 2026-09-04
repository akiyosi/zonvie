// extfloat_margin_scroll_flicker — an external window's margin rows must
// hold still during a trackpad pixel-scroll.
//
// Reported symptom: with a winbar (marginTop = 1) in an external float,
// the margin row flickers while smooth-scrolling with the trackpad. The
// main window does not.
//
// Measured by sampling the float WHILE the gesture is open and finding
// the topmost row that differs from the first in-gesture frame. Content
// rows scroll and must differ; anything at or above the margin boundary
// is the bug. Two details are load-bearing:
//
//   - The gesture has to stay OPEN across the captures. Posting complete
//     began/changed/ended gestures and sampling between them only ever
//     sees settled frames, and reports no flicker at all.
//   - The margin band is derived from the app's own vpH / marginTop and
//     the capture height, not hardcoded. The float's title bar is 64px of
//     the capture on this machine; measuring "the top rows" measures the
//     title bar, which is static, and again reports no flicker.
//
// A body-band control runs alongside: if the scrolling content does NOT
// differ between frames, the capture is not observing live frames and the
// margin result means nothing, so the scenario fails instead of passing.
//
// macOS-only: the external-window smooth-scroll path is macOS frontend.

const std = @import("std");
const driver = @import("../../driver.zig");
const platform = driver.platform;
const capture = driver.capture;
const Gui = driver.Gui;
const app_log = @import("../../app_log.zig");
const gui_io = @import("../../gui_io.zig");

const log_path = "tmp/gui_margin_flicker.log";
const scroll_marker = "[ExternalGridView] scroll offset:";
const draw_marker = "[ext_draw_debug]";
/// The app reports a margin row that USED to carry geometry and then
/// failed to resolve. That row is not emitted, and this surface clears
/// every frame, so it shows the clear colour — it vanishes. A row that is
/// always empty is excluded app-side, so this cannot fire on a border row
/// that is painted by the clear by design.
const lost_marker = "[ext_margin_row_lost]";

// Deliberately NOT asserted on: whether a margin row resolves to vertices
// at all.
// The core legitimately submits a margin row with zero vertices (see the
// `count > 0` guard in writeSurfaceRow) — such a row is painted by the
// background clear, not by geometry, so "no vertices" is its normal state
// and says nothing about whether it is visible.

const grid_rows = 20;
const grid_cols = 60;
const scroll_steps = 400;
/// Frames sampled across repeated nudge-and-release settles.
const settle_cycles = 240;
/// Negative dy is the direction the report describes. Two steps is a
/// deliberately small nudge: the whole point is to release BELOW Neovim's
/// scroll unit so no grid_scroll is emitted and the offset merely eases
/// back, which is the path the margin row is disturbed on.
/// A single tiny delta. The app books a whole wheel event's worth of
/// compensation from any scroll input, so anything larger pushes Neovim
/// over its scroll threshold and the run leaves the settle path.
const step_px: f64 = -2;
const nudge_steps: u32 = 1;

/// Width of the scrollbar overlay strip on the right, excluded from every
/// comparison.
const scrollbar_exclude_px: u32 = 48;

/// How many independent frames must show a margin row moving before it is
/// called a flicker. One is not enough: a capture taken mid-present can
/// tear, and a torn frame differs in rows nothing actually drew.
const margin_hit_threshold: usize = 3;

const max_windows = 16;

fn newWindow(pid: i32, before: []const platform.MainWindow, min_side: f64) ?platform.MainWindow {
    var buf: [max_windows]platform.MainWindow = undefined;
    const now = buf[0..platform.windowsForPid(pid, &buf)];
    outer: for (now) |w| {
        for (before) |b| {
            if (b.number == w.number) continue :outer;
        }
        if (w.bounds.w < min_side or w.bounds.h < min_side) continue;
        return w;
    }
    return null;
}

fn waitNewWindow(pid: i32, before: []const platform.MainWindow, min_side: f64) !platform.MainWindow {
    var timer = gui_io.Timer.start();
    while (true) {
        if (newWindow(pid, before, min_side)) |w| return w;
        if (timer.read() / std.time.ns_per_ms >= 10_000) {
            platform.dumpWindowsForPid(pid);
            return error.FloatWindowNotFound;
        }
        gui_io.sleepNs(100 * std.time.ns_per_ms);
    }
}

/// Rows of the capture the margin occupies, derived from what the app
/// reports rather than assumed: the grid is the bottom `vpH` pixels of the
/// capture (the rest is window chrome), and the margin is `marginTop`
/// cells from the grid's top edge.
const MarginBand = struct { start: usize, end: usize, bottom_start: usize, grid_end: usize, drawable_end: usize };

fn marginBand(alloc: std.mem.Allocator, capture_h: usize, since_ms: f64) !MarginBand {
    const line = (try app_log.lastLineSince(alloc, log_path, scroll_marker, since_ms)) orelse
        return error.NoScrollOffsetLogged;
    defer alloc.free(line);
    const vp_h = app_log.field(line, "vpH") orelse return error.ScrollOffsetUnparsable;
    const cell_ndc = app_log.field(line, "cellNDC") orelse return error.ScrollOffsetUnparsable;
    const margin_top = app_log.field(line, "marginTop") orelse return error.ScrollOffsetUnparsable;
    const margin_bottom = app_log.field(line, "marginBottom") orelse return error.ScrollOffsetUnparsable;
    if (margin_top < 1 or margin_bottom < 1) return error.NoMarginRow;
    // cellNDC = cellH * 2 / vpH
    const cell_h = cell_ndc * vp_h / 2.0;
    if (cell_h <= 0 or vp_h <= 0) return error.ScrollOffsetUnparsable;

    // The capture covers the whole window, the Metal view only its content
    // area, and the grid is snapped to whole rows inside that. Deriving the
    // title-bar height by subtracting vpH assumes the grid is bottom-aligned
    // — it is not, and a window whose height is not a whole number of cells
    // then reports a margin band a full strip too low.
    const dline = (try app_log.lastLineSince(alloc, log_path, draw_marker, since_ms)) orelse
        return error.NoDrawDebugLogged;
    defer alloc.free(dline);
    const drawable_h = app_log.field(dline, "drawableH") orelse return error.DrawDebugUnparsable;
    const vp_origin_y = app_log.field(dline, "vpOriginY") orelse return error.DrawDebugUnparsable;
    const chrome = @as(f64, @floatFromInt(capture_h)) - drawable_h;
    if (chrome < 0) return error.CaptureSmallerThanDrawable;
    const grid_top = chrome + vp_origin_y * 2.0;
    return .{
        .start = @intFromFloat(grid_top),
        .end = @intFromFloat(grid_top + margin_top * cell_h),
        .bottom_start = @intFromFloat(grid_top + vp_h - margin_bottom * cell_h),
        .grid_end = @intFromFloat(grid_top + vp_h),
        .drawable_end = @intFromFloat(chrome + drawable_h),
    };
}

/// True when every pixel in rows [start, end) up to `width` is the same
/// colour — what a region looks like when nothing was drawn into it.
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

/// True when rows [start, end) are pixel-identical between the two images
/// up to `width` (the scrollbar strip is excluded by the caller).
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
            "[gui] skipped: not trusted for Accessibility, so the float cannot be placed. " ++
                "Grant this binary under System Settings > Privacy & Security > Accessibility.\n",
            .{},
        );
        return error.SkipZigTest;
    }

    std.Io.Dir.cwd().createDirPath(gui_io.io(), "tmp") catch {};
    std.Io.Dir.cwd().deleteFile(gui_io.io(), log_path) catch {};

    // The reported window runs an animated custom shader (the field log has
    // "Loaded 1/1 custom shaders ... anyNeedsAnimation=true"). That matters
    // structurally, not just cosmetically: when a custom shader is
    // configured it REPLACES the back-buffer blit to the drawable, so the
    // path that puts pixels on screen is a different one entirely.
    var g = try Gui.init(alloc, .{
        .app_args = &.{ "--log", log_path },
        .config_dir = "test/gui/fixtures/config_static_shader",
    });
    defer g.deinit();
    g.activateApp();

    var before_buf: [max_windows]platform.MainWindow = undefined;
    const before = before_buf[0..platform.windowsForPid(g.app_pid, &before_buf)];

    // External float with a winbar (marginTop = 1) and enough lines to
    // scroll through without hitting the buffer end mid-gesture.
    try g.exec(
        "luaeval('(function() local b = vim.api.nvim_create_buf(false, true) " ++
            "local lines = {} for i = 1, 400 do lines[i] = string.rep(\"line \" .. i .. \" \", 6) end " ++
            "vim.api.nvim_buf_set_lines(b, 0, -1, true, lines) " ++
            "_G.e2e_float = vim.api.nvim_open_win(b, true, " ++
            "{external=true, width=" ++ std.fmt.comptimePrint("{d}", .{grid_cols}) ++
            ", height=" ++ std.fmt.comptimePrint("{d}", .{grid_rows}) ++ ", border=\"single\", " ++
            // A footer bakes text into the BOTTOM border row (nvim 0.10+),
            // giving the bottom margin row glyphs the way the winbar gives
            // the top one — a corruption there moves many more pixels than
            // a bare border line would.
            "footer=\"FOOTERBAR\", footer_pos=\"left\"}) " ++
            "vim.api.nvim_set_option_value(\"winbar\", \"WINBAR\", {win=_G.e2e_float}) " ++
            "vim.api.nvim_win_set_cursor(_G.e2e_float, {40, 0}) " ++
            "return 1 end)()')",
    );
    const opened = try waitNewWindow(g.app_pid, before, 150);
    if (!platform.moveWindowBySize(g.app_pid, opened.bounds.w, opened.bounds.h, 60, 60)) {
        return error.MoveFailed;
    }
    gui_io.sleepNs(600 * std.time.ns_per_ms);
    // Leave the window at a height that is NOT a whole number of cells, the
    // way a user drag-resize does. The grid snaps to whole rows, so the
    // remainder is a strip the grid never covers — a structure the main
    // window does not have, since its grid fills its view.
    const parked = try waitNewWindow(g.app_pid, before, 150);
    if (!platform.setWindowSizeBySize(
        g.app_pid,
        parked.bounds.w,
        parked.bounds.h,
        parked.bounds.w,
        parked.bounds.h + 15,
    )) return error.ResizeFailed;
    gui_io.sleepNs(700 * std.time.ns_per_ms);
    const float_win = try waitNewWindow(g.app_pid, before, 150);

    const t0 = try app_log.nowMs(alloc, log_path);

    var base: ?capture.Image = null;
    defer if (base) |*b| b.deinit(alloc);
    var shots: usize = 0;
    var body_diffs: usize = 0;
    var top_blank: usize = 0;
    var bottom_blank: usize = 0;
    var band_known = false;
    var band_top_start: usize = 0;
    var band_top_end: usize = 0;
    var band_bot_start: usize = 0;
    var band_bot_end: usize = 0;
    // Per-frame extremes. A single frame is not enough to call it: a
    // capture taken while the compositor is mid-present can tear, and a
    // torn frame differs in rows nothing actually drew. The margin has to
    // move in several independent frames.
    var capture_h: usize = 0;

    // Drive INTO the top edge and hold there. Scrolling in the middle of a
    // buffer always has content to move and rows to retain; at the edge
    // there is nothing above line 1, so the band the offset opens cannot be
    // covered by a retained row and only the edge-row background stretch
    // fills it. The margin rows sit right against that band. The harness
    // previously started at line 200 of 400 and never reached this state at
    // all — the one condition the report names ("scroll up to the limit and
    // hold at maximum shift") was the one it could not produce.
    // Reference taken at REST, before the gesture opens — not from the
    // first in-gesture frame. Margin rows do not scroll, so their pixels at
    // rest are the truth to compare against for the whole glide. Using an
    // in-gesture frame makes the check differential, and a differential
    // check cannot see a row that is wrong for the ENTIRE gesture: the
    // reference would capture the broken state and every later frame would
    // match it. Holding at the edge under maximum shift produces exactly
    // that sustained shape.
    base = try capture.captureWindow(alloc, float_win.number);
    capture_h = base.?.h;

    // The reported operation: pixel-scroll by LESS than one Neovim scroll
    // unit, then lift. No grid_scroll is emitted for a sub-row shift, so
    // nothing scrolls in the buffer — the sub-cell offset simply eases back
    // to zero, and it is that settle animation the margin row is disturbed
    // during. Momentum deltas large enough to accumulate whole rows take a
    // different path entirely, which is all this harness used to exercise.
    const topline_before = try g.evalInt("luaeval('vim.api.nvim_win_call(_G.e2e_float, function() return vim.fn.line(\"w0\") end)')");

    if (!platform.scrollBegin(g.app_pid, float_win)) return error.ScrollRefused;
    var nudge: u32 = 0;
    while (nudge < nudge_steps) : (nudge += 1) {
        platform.scrollStep(step_px);
        gui_io.sleepNs(16 * std.time.ns_per_ms);
    }
    // Lift with no momentum: the offset has nowhere to go but back.
    platform.scrollEnd();

    // Sample the settle. It is short, so sample hard and repeat the whole
    // nudge-and-release cycle to cover many of them.
    var cycle: u32 = 0;
    while (cycle < settle_cycles) : (cycle += 1) {
        var shot = capture.captureWindow(alloc, float_win.number) catch continue;
        shots += 1;
        if (!band_known) {
            if (marginBand(alloc, capture_h, t0)) |b| {
                band_top_start = b.start;
                band_top_end = b.end;
                band_bot_start = b.bottom_start;
                band_bot_end = b.grid_end;
                band_known = true;
            } else |_| {}
        }
        defer shot.deinit(alloc);
        const b = base.?;
        if (shot.w != b.w or shot.h != b.h) continue;
        const compare_w = if (shot.w > scrollbar_exclude_px) shot.w - scrollbar_exclude_px else shot.w;
        if (band_known) {
            if (!bandsEqual(shot, b, band_top_start, band_top_end, compare_w)) top_blank += 1;
            if (!bandsEqual(shot, b, band_bot_start, band_bot_end, compare_w)) bottom_blank += 1;
        }
        const stride = @as(usize, shot.w) * 4;
        const mid = (shot.h / 2) * stride;
        const cmp = @as(usize, compare_w) * 4;
        if (!std.mem.eql(u8, shot.rgba[mid .. mid + cmp], b.rgba[mid .. mid + cmp])) body_diffs += 1;

        // Next nudge only after the previous settle has fully run down.
        // Overlapping them accumulates offset past a whole row, which emits
        // a grid_scroll and puts the run on the scrolling path instead of
        // the settle path this scenario exists to exercise.
        if (cycle % 20 == 19) {
            gui_io.sleepNs(400 * std.time.ns_per_ms);
            if (platform.scrollBegin(g.app_pid, float_win)) {
                var n2: u32 = 0;
                while (n2 < nudge_steps) : (n2 += 1) {
                    platform.scrollStep(step_px);
                    gui_io.sleepNs(16 * std.time.ns_per_ms);
                }
                platform.scrollEnd();
            }
        }
    }

    if (shots < 10) return error.TooFewCaptures;
    std.debug.print(
        "[gui] margin bands {d}..{d} and {d}..{d}; changed: top={d} bottom={d} of {d}; body {d}/{d}\n",
        .{ band_top_start, band_top_end, band_bot_start, band_bot_end, top_blank, bottom_blank, shots, body_diffs, shots },
    );
    if (!band_known) return error.NoScrollOffsetLogged;
    if (shots < 20) return error.TooFewCaptures;
    // Liveness control, ENFORCED (the header's promise): if the scrolling
    // content never differed from the rest reference, the captures were not
    // observing live frames and every band result above is vacuous.
    if (body_diffs == 0) {
        std.debug.print("[gui] scrolling content never changed — captures were not live\n", .{});
        return error.CaptureNotLive;
    }

    // Note on what "below Neovim's scroll unit" means here: the frontend
    // books a whole 'mousescroll' unit from any gesture and then works the
    // sub-cell offset down, so Neovim always scrolls — even a synthetic 2px
    // nudge moves it three lines. The reported condition is therefore about
    // releasing while that booked shift is still UNCONSUMED, leaving the
    // settle animation to play out the remainder. That is what a short
    // nudge-and-release produces.
    const topline_after = try g.evalInt("luaeval('vim.api.nvim_win_call(_G.e2e_float, function() return vim.fn.line(\"w0\") end)')");
    std.debug.print("[gui] Neovim topline before={d} after={d}\n", .{ topline_before, topline_after });

    // Second phase: a real scroll, large enough that Neovim moves whole
    // rows. The band the offset opens must be filled with the content that
    // left — that is what the retained rows are for. If it is blank, rows
    // that should have slid into view have gone missing, which is the
    // regression a naive "drop the retained rows" fix produces. Asserted
    // because fixing the margin overdraw without this check silently trades
    // one artefact for a worse one.
    {
        var blank_band: usize = 0;
        var band_shots: usize = 0;
        const phase2_t0 = try app_log.nowMs(alloc, log_path);
        if (platform.scrollBegin(g.app_pid, float_win)) {
            // Scroll hard, then LET GO and keep watching. While the fingers
            // are down new commits arrive every frame and the retained rows
            // are republished constantly, so any expiry rule survives that
            // stretch — the band only goes empty once the commits stop and
            // the animation is still running it out. Sampling only the
            // fingers-down part is what let two wrong expiry rules pass.
            var k: u32 = 0;
            while (k < 12) : (k += 1) {
                platform.scrollStep(-12);
                gui_io.sleepNs(16 * std.time.ns_per_ms);
            }
            platform.scrollEnd();
            while (k < 40) : (k += 1) {
                var shot = capture.captureWindow(alloc, float_win.number) catch continue;
                defer shot.deinit(alloc);
                band_shots += 1;
                const cw = if (shot.w > scrollbar_exclude_px) shot.w - scrollbar_exclude_px else shot.w;
                // The two content rows just inside the top margin: the band
                // opens here, and retained rows are what fill it.
                const cell = (band_top_end - band_top_start) / 2;
                if (bandIsUniform(shot, band_top_end, band_top_end + cell * 2, cw)) blank_band += 1;
                gui_io.sleepNs(16 * std.time.ns_per_ms);
            }
        }
        std.debug.print("[gui] frames with a blank scroll band: {d}/{d}\n", .{ blank_band, band_shots });
        if (band_shots < 10) return error.TooFewCaptures;
        if (blank_band > 0) {
            std.debug.print(
                "[gui] the band opened by the scroll was empty — content that should have slid into " ++
                    "view is missing\n",
                .{},
            );
            return error.ScrollBandBlank;
        }

        // Log-side band coverage across the whole hard scroll. The pixel
        // probe above is structurally blunt here: the offset is consumed at
        // ~a cell per frame so the band outlives the last commit by only a
        // few frames, captures are slower than that, and the band region
        // includes the float's border column, so a stretched band is not
        // pixel-uniform anyway. Verified by intervention: an unconditional
        // clearPublished() in updateScrollShaderOffset left the pixel probe
        // at 0/28. The app's own per-frame report is the observation point
        // instead.
        //
        // Only frames whose offset is SHRINKING count. While the offset is
        // being consumed, the band holds rows that already left the grid,
        // and fewer retained rows than the band is exactly the state a wrong
        // expiry rule produces once commits stop republishing them. A frame
        // where the offset just GREW is the wheel's lookahead booking — the
        // content has not moved yet, no row has left, and the edge stretch
        // legitimately covers the band until the grid_scroll lands — so
        // counting those would fail correct code.
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
                "[gui] retained rows expired while the offset still held their band open — the band " ++
                    "shows the edge stretch instead of the content that left\n",
                .{},
            );
            return error.ScrollBandUncovered;
        }
    }

    // Fourth phase: the same gestures UPWARD. Rows then leave through the
    // BOTTOM edge, retained rows target the bottom margin row, and the band
    // the offset opens presses against it — the side the downward phases
    // never exercise. The whole-row capture bug corrupted this edge the
    // same way (a "│" over the bottom border corner), so both margins are
    // asserted against the same rest reference. The buffer sits ~100 lines
    // deep after the downward phases, so there is room to scroll back up
    // without hitting line 1 mid-gesture.
    {
        gui_io.sleepNs(500 * std.time.ns_per_ms);
        var up_top: usize = 0;
        var up_bottom: usize = 0;
        var up_body: usize = 0;
        var up_shots: usize = 0;
        if (!platform.scrollBegin(g.app_pid, float_win)) return error.ScrollRefused;
        var n: u32 = 0;
        while (n < nudge_steps) : (n += 1) {
            platform.scrollStep(-step_px);
            gui_io.sleepNs(16 * std.time.ns_per_ms);
        }
        platform.scrollEnd();
        var c: u32 = 0;
        while (c < settle_cycles) : (c += 1) {
            var shot = capture.captureWindow(alloc, float_win.number) catch continue;
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
                if (platform.scrollBegin(g.app_pid, float_win)) {
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

        // Hard upward scroll and release: the band opens against the BOTTOM
        // margin. The two content rows just above it are where the retained
        // rows land, and the same shrink-gated coverage rule applies.
        var blank_band: usize = 0;
        var band_shots: usize = 0;
        const up_t0 = try app_log.nowMs(alloc, log_path);
        if (platform.scrollBegin(g.app_pid, float_win)) {
            var k: u32 = 0;
            while (k < 12) : (k += 1) {
                platform.scrollStep(12);
                gui_io.sleepNs(16 * std.time.ns_per_ms);
            }
            platform.scrollEnd();
            while (k < 40) : (k += 1) {
                var shot = capture.captureWindow(alloc, float_win.number) catch continue;
                defer shot.deinit(alloc);
                band_shots += 1;
                const cw = if (shot.w > scrollbar_exclude_px) shot.w - scrollbar_exclude_px else shot.w;
                const cell = (band_top_end - band_top_start) / 2;
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

    if (top_blank > 0 or bottom_blank > 0) {
        std.debug.print(
            "[gui] a margin row changed during the glide — margin rows do not scroll and must hold still\n",
            .{},
        );
        return error.MarginRowChanged;
    }

    {
        const lines = try app_log.linesSince(alloc, log_path, lost_marker, t0);
        defer alloc.free(lines);
        var n: usize = 0;
        var it = std.mem.splitScalar(u8, lines, '\n');
        while (it.next()) |line| {
            if (line.len > 0) n += 1;
        }
        std.debug.print("[gui] frames where a populated margin row was lost: {d}\n", .{n});
        if (n > 0) {
            std.debug.print(
                "[gui] a margin row that normally carries geometry was not emitted — with a clearing " ++
                    "surface that row shows the clear colour, i.e. it vanishes\n",
                .{},
            );
            return error.MarginRowLost;
        }
    }

    {
        const lines = try app_log.linesSince(alloc, log_path, "[ext_shader_size_mismatch]", t0);
        defer alloc.free(lines);
        var n: usize = 0;
        var it = std.mem.splitScalar(u8, lines, '\n');
        while (it.next()) |line| {
            if (line.len > 0) n += 1;
        }
        std.debug.print("[gui] shader passes with mismatched input/output size: {d}\n", .{n});
        if (n > 0) {
            std.debug.print(
                "[gui] the custom shader pass rescales the surface — a full-screen quad maps input to " ++
                    "output 1:1, so differing sizes shift every row off its true position\n",
                .{},
            );
            return error.ShaderPassRescales;
        }
    }
}
