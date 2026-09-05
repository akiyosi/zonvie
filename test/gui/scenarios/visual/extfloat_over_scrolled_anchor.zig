// visual/extfloat_over_scrolled_anchor — a float anchored to an EXTERNAL
// window must show the same screen a direct jump to the same view shows.
//
// Per-grid rendering made every float on the MAIN surface its own layer, so
// the core dropped the row-shift fast path's old "a subgrid overlaps the
// scroll region" veto. A float anchored to an EXTERNAL grid did not move with
// it: `collectMainLayerEntries` still skips a float whose anchor is external,
// and it is composited into the anchor's own rows instead. The external fast
// path's own veto for that case — `ext_has_float_overlay`, which refused the
// shift whenever the anchor carried any float — went with the rest and has no
// replacement.
//
// The shape that leaves open: the anchor's rows carry the float's pixels, so a
// shift drags the float's content along with the text under it while the core
// resends only the band the shift vacated, and nothing puts the float back.
//
// Measured: it does NOT happen. Neovim re-announces a float over a window that
// scrolled, and `setWinFloatPos` dirties the anchor's covered rows for an
// external anchor, so the float's rows are in the regen set of every shifted
// frame (9-12 of 20 rows for a 3-row scroll under a 6-row float, against 3
// vacated rows). This scenario pins that, since nothing on the fast path
// arranges it — the repaint is a side effect of an unrelated redraw event.
//
// The oracle is relational — scrolling in small steps and jumping to the same
// topline must agree — so it needs no golden and is immune to per-host
// font/DPI drift. A jump moves further than half the region, which the fast
// path refuses, so it repaints every row from scratch and cannot carry a drag.
// Sabotaged by aiming the jump 3 rows off, it reports 0.2719 against a 0.0002
// threshold and the heatmap prints the float's own rectangle, so the float's
// pixels are inside what the comparison sees.
//
// macOS-only: it enumerates the app's OS windows to find the external one and
// captures that window rather than the main one.

const std = @import("std");
const driver = @import("../../driver.zig");
const platform = driver.platform;
const capture = driver.capture;
const fixture = @import("fixture.zig");
const visual = @import("../../visual.zig");
const gui_io = @import("../../gui_io.zig");
const app_log = @import("../../app_log.zig");

/// This scenario's own log. The counts below are only an oracle while every
/// line they read came from this run's app process, and the suite's shared
/// tmp/gui_app.log carries other runs' lines at overlapping timestamps.
const log_path = "tmp/gui_extfloat_over_scrolled_anchor.log";

/// The core's per-external-grid row report. Its `scroll_fast_path=` field is
/// the only place that says whether the shift path — the one this scenario
/// exists for — ran at all.
const ext_row_marker = "[ext_grid_row] grid_id=";
const ext_fast_path_marker = "scroll_fast_path=true";

/// Scroll steps, each `3<C-e>`. Twelve rows in total: twice the height of the
/// six-row float below, so a drag has room to move the whole float off its
/// own rows.
///
/// Deliberately NOT `<C-d>`: the fast path refuses a shift past half the
/// region, so a bigger step would regenerate everything and the path this
/// scenario exists for would never run.
const steps: usize = 4;

/// Frames the app is given to settle each scroll step. Sends that coalesce
/// into one flush produce one shift for several steps, which would make the
/// count gate below unreachable for reasons unrelated to the shift.
const step_settle_ms = 300;

/// Width of the scrollbar overlay strip on the right, excluded from every
/// comparison: it is an overlay whose presence depends on how recently the
/// grid scrolled, not on whether the rows underneath are correct.
const scrollbar_exclude_px: f64 = 48;

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
            return error.ExternalWindowNotFound;
        }
        gui_io.sleepNs(100 * std.time.ns_per_ms);
    }
}

/// captureStable for a window that is not the app's main one: retry until two
/// consecutive captures are pixel-identical, so a frame caught mid-present is
/// never what a comparison sees.
fn captureWindowStable(alloc: std.mem.Allocator, window_number: u32, timeout_ms: u64) !capture.Image {
    var timer = gui_io.Timer.start();
    var prev: ?capture.Image = null;
    defer if (prev) |*p| p.deinit(alloc);
    while (true) {
        gui_io.sleepNs(150 * std.time.ns_per_ms);
        const cur = capture.captureWindow(alloc, window_number) catch |e| {
            if (timer.read() / std.time.ns_per_ms >= timeout_ms) return e;
            continue;
        };
        if (prev) |*p| {
            if (p.w == cur.w and p.h == cur.h and std.mem.eql(u8, p.rgba, cur.rgba)) {
                p.deinit(alloc);
                prev = null;
                return cur;
            }
            p.deinit(alloc);
            prev = null;
        }
        prev = cur;
        if (timer.read() / std.time.ns_per_ms >= timeout_ms) {
            const out = prev.?;
            prev = null;
            return out; // last capture even if not fully settled
        }
    }
}

/// The window minus the scrollbar strip. Derived from the capture rather than
/// hardcoded as a fraction, so it excludes the same pixels at any window size.
fn bodyRegion(img: capture.Image) visual.Region {
    const w: f64 = @floatFromInt(img.w);
    if (w <= scrollbar_exclude_px) return .{};
    return .{ .x1 = (w - scrollbar_exclude_px) / w };
}

const FastPath = struct { frames: usize = 0, max_regen: f64 = 0 };

/// Frames since `since_ms` in which an external grid published a row shift
/// instead of regenerating its viewport, and the largest number of rows any
/// of them resent.
fn fastPathFrames(alloc: std.mem.Allocator, since_ms: f64) !FastPath {
    const lines = try app_log.linesSince(alloc, log_path, ext_row_marker, since_ms);
    defer alloc.free(lines);

    var out: FastPath = .{};
    var it = std.mem.splitScalar(u8, lines, '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        if (std.mem.indexOf(u8, line, ext_fast_path_marker) == null) continue;
        out.frames += 1;
        const regen = app_log.field(line, "regen_count") orelse continue;
        if (regen > out.max_regen) out.max_regen = regen;
    }
    return out;
}

pub fn run(alloc: std.mem.Allocator) !void {
    // A host without screen capture must skip honestly rather than fail from
    // deep inside a capture call.
    try fixture.requireScreenAccess();
    // A file left by a crashed earlier run would still be appended to, and its
    // lines would be counted alongside this run's.
    std.Io.Dir.cwd().createDirPath(gui_io.io(), "tmp") catch {};
    std.Io.Dir.cwd().deleteFile(gui_io.io(), log_path) catch {};

    var g = try fixture.openWithLog(alloc, log_path);
    defer g.deinit();
    g.activateApp();

    // Nothing outside the text area may react to the cursor, or the
    // comparison would fail for reasons unrelated to the scroll pipeline.
    try g.exec("execute('set laststatus=0 noruler noshowcmd showtabline=0 scrolloff=0 nowrap noswapfile')");
    // A blinking cursor alone produces a false diff between two captures.
    try g.exec("execute('set guicursor=a:block-blinkon0')");

    var before_buf: [max_windows]platform.MainWindow = undefined;
    const before_windows = before_buf[0..platform.windowsForPid(g.app_pid, &before_buf)];

    // The external window, with a buffer whose every line differs across the
    // full width: a screen made of similar lines would survive a bad shift
    // unchanged and make this blind to the very artifact it exists to catch.
    try g.exec(
        \\luaeval('(function() local b = vim.api.nvim_create_buf(false, true) local l = {} for i = 1, 400 do l[i] = string.format("%3d %s", i, string.rep(string.char(65 + i % 26), 56)) end vim.api.nvim_buf_set_lines(b, 0, -1, false, l) _G.z_ext = vim.api.nvim_open_win(b, true, {relative="editor", row=1, col=1, width=60, height=20}) return 1 end)()')
    );
    // Opened as an editor float and externalized afterwards, NOT with
    // `{external=true}` straight away, and the placement has to reach the core
    // in between. `setWinExternalPos` takes the grid's screen position from
    // `win_pos`, and a window that was never composited has no entry there: its
    // ExternalGridInfo keeps start_row = -1, at which point
    // `buildExternalFloatRowIndex` returns early and `dirtyCompositedRow` bails
    // out, so a float anchored to that window is never composited into it and
    // never reaches the screen at all. This scenario needs an anchor that does
    // composite; the other configuration is a separate defect.
    gui_io.sleepNs(600 * std.time.ns_per_ms);
    try g.exec(
        \\luaeval('(function() vim.api.nvim_win_set_config(_G.z_ext, {external=true, width=60, height=20}) return 1 end)()')
    );
    const ext_win = try waitNewWindow(g.app_pid, before_windows, 150);
    try g.exec("execute('normal! 100Gzt0')");

    var without_float = try captureWindowStable(alloc, ext_win.number, 8000);
    defer without_float.deinit(alloc);

    // A float anchored to the EXTERNAL window. style="minimal" keeps the
    // oracle about the float's content rather than border geometry, and
    // enter=false leaves the anchor current so the scroll below lands on it.
    try g.exec(
        \\luaeval('(function() local b = vim.api.nvim_create_buf(false, true) local l = {} for i = 1, 6 do l[i] = "FLOAT" .. i .. " " .. string.rep(string.char(64 + i), 17) end vim.api.nvim_buf_set_lines(b, 0, -1, false, l) _G.z_float = vim.api.nvim_open_win(b, false, {relative="win", win=_G.z_ext, row=6, col=4, width=24, height=6, style="minimal"}) return 1 end)()')
    );
    gui_io.sleepNs(600 * std.time.ns_per_ms);

    // The premise: this float is composited into the anchor's rows, not given
    // an OS window of its own. If the frontend ever draws it separately there
    // are no float pixels for a shift to drag, and everything below is void.
    const window_count = platform.windowsForPid(g.app_pid, &before_buf);
    if (window_count != before_windows.len + 1) {
        std.debug.print(
            "[gui] the anchored float took an OS window of its own ({d} windows, expected {d}); it is not composited\n",
            .{ window_count, before_windows.len + 1 },
        );
        return error.FloatNotComposited;
    }

    // Ask Neovim where the float actually landed rather than assuming: if it
    // were clamped outside the anchor's rows, or off the scroll region, the
    // comparison would be about something else entirely.
    const f_row = try g.evalInt("luaeval('vim.api.nvim_win_get_config(_G.z_float).row')");
    const f_height = try g.evalInt("luaeval('vim.api.nvim_win_get_height(_G.z_float)')");
    const a_height = try g.evalInt("luaeval('vim.api.nvim_win_get_height(_G.z_ext)')");
    if (f_row <= 0 or f_row + f_height >= a_height) {
        std.debug.print(
            "[gui] the float (rows {d}..{d}) does not sit strictly inside the anchor's {d} rows\n",
            .{ f_row, f_row + f_height, a_height },
        );
        return error.FloatNotOverAnchor;
    }

    var with_float = try captureWindowStable(alloc, ext_win.number, 8000);
    defer with_float.deinit(alloc);
    if (with_float.w != without_float.w or with_float.h != without_float.h) {
        return error.ExternalWindowResized;
    }
    const region = bodyRegion(with_float);

    // Without this, a build that never drew the float into the anchor's
    // pixels would pass trivially — there would be nothing for a shift to
    // drag and nothing for the jump to restore.
    const float_paint = visual.regionDiffRatio(without_float, with_float, region, 6);
    if (float_paint <= 0.002) {
        std.debug.print(
            "[gui] opening the float changed {d:.4} of the external window; it never reached the screen\n",
            .{float_paint},
        );
        return error.FloatNotOnScreen;
    }

    // Warm-up, then back where it started. A commit that places a surface at a
    // rectangle it did not have before drops its staged shift, so a scroll
    // issued while the layout is still settling produces no shift at all.
    // Spending one scroll outside the measured window keeps that out of the
    // gate below.
    try g.remoteSend("3<C-e>");
    gui_io.sleepNs(step_settle_ms * std.time.ns_per_ms);
    try g.remoteSend("3<C-y>");
    gui_io.sleepNs(step_settle_ms * std.time.ns_per_ms);

    var start = try captureWindowStable(alloc, ext_win.number, 8000);
    defer start.deinit(alloc);

    const t_scroll = try app_log.nowMs(alloc, log_path);
    var i: usize = 0;
    while (i < steps) : (i += 1) {
        try g.remoteSend("3<C-e>");
        gui_io.sleepNs(step_settle_ms * std.time.ns_per_ms);
    }
    var incremental = try captureWindowStable(alloc, ext_win.number, 8000);
    defer incremental.deinit(alloc);

    // The comparison at the end passes just as well when the anchor
    // regenerates every row: same screen, different path, and the defect this
    // exists for lives only on the shift path. Require that the shift ran.
    const fast = try fastPathFrames(alloc, t_scroll);
    std.debug.print(
        "[gui] extfloat_over_scrolled_anchor: {d} shifted frames (max regen_count {d:.0}) over {d} steps; float painted {d:.4}\n",
        .{ fast.frames, fast.max_regen, steps, float_paint },
    );
    if (fast.frames < steps) {
        std.debug.print(
            "[gui] the external grid's row-shift fast path did not run; this comparison would guard nothing\n",
            .{},
        );
        return error.RowShiftDidNotRun;
    }

    // Guard against a vacuous pass: if the scrolling never rendered, the
    // comparison below would hold trivially.
    const moved = visual.regionDiffRatio(start, incremental, region, 6);
    if (moved <= 0.0002) {
        std.debug.print(
            "[gui] {d} scroll steps did not change the external window ({d:.4}) — test would be vacuous\n",
            .{ steps, moved },
        );
        return error.ScrollDidNotRender;
    }

    // Ask Neovim where the incremental scrolling actually landed rather than
    // assuming, so the comparison below can never fail for arithmetic reasons.
    const topline = try g.evalInt("line('w0')");
    std.debug.print(
        "[gui] extfloat_over_scrolled_anchor: topline={d} scroll moved {d:.4} of the window\n",
        .{ topline, moved },
    );

    // The same view reached by a jump. Both hops move further than half the
    // region, which the fast path refuses, so every row is regenerated from
    // scratch and the float is composited back into all of them.
    try g.exec("execute('normal! 1Gzt0')");
    var settled = try captureWindowStable(alloc, ext_win.number, 8000);
    settled.deinit(alloc);
    var jump_buf: [64]u8 = undefined;
    const jump_cmd = try std.fmt.bufPrint(&jump_buf, "execute('normal! {d}Gzt0')", .{topline});
    try g.exec(jump_cmd);
    var jumped = try captureWindowStable(alloc, ext_win.number, 8000);
    defer jumped.deinit(alloc);

    try visual.assertRegionUnchanged(
        alloc,
        "extfloat_over_scrolled_anchor",
        jumped,
        incremental,
        region,
        .{},
    );
}
