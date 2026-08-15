// extfloat_resize_shader_stall — with a custom shader animating, the app
// must keep drawing every vsync after an external float window has been
// resized AND moved.
//
// Field report (tmp/macos.log vs tmp/macos-shader-wait.log, two runs that
// differ only by whether the external float was manipulated): afterwards
// the app stopped drawing for ~1010ms at a time, four times in five
// seconds, and queued key events were delivered up to 900ms late.
//
// Root cause, measured by this scenario: resizing and moving the float
// leaves it fully covered by the main window, which stops being
// composited; ExternalGridView.draw then blocked the MAIN thread in
// `view.currentDrawable` for the layer's full timeout — 993ms and 1002ms
// in [perf] ext_acquire_drawable — once per frame it attempted. Only an
// animating shader makes it attempt frames at all while invisible, which
// is why the freeze needed a shader to show up.
//
// Both halves are load-bearing and neither reproduces alone:
//   - the RESIZE is a real corner drag with mouse events. Resizing via
//     nvim_win_set_config reaches the same geometry through the app's own
//     suppressed setFrame and never runs the window→grid→window round trip.
//   - the MOVE is what ends with the float behind the main window.
//
// macOS-only: the animated-shader draw loop and the external-float window
// plumbing this exercises live in the macOS frontend.

const std = @import("std");
const driver = @import("../../driver.zig");
const platform = driver.platform;
const Gui = driver.Gui;
const app_log = @import("../../app_log.zig");
const gui_io = @import("../../gui_io.zig");

const log_path = "tmp/gui_shader_stall.log";

/// At 60Hz the expected gap is ~16.7ms. The observed regression is ~1010ms.
/// 250ms leaves room for Debug-build hiccups while staying far below it.
const max_gap_ms: f64 = 250;

/// How long each measurement window idles. Long enough that a ~1s stall
/// cannot hide between the last driver command and the end of the window.
const observe_ms: u64 = 3000;

/// Resize steps, matching the ~26 windowDidResize ticks a real edge drag
/// produced in the field report.
const resize_steps: u32 = 26;

const max_windows = 16;

fn measure(alloc: std.mem.Allocator, since_ms: f64, label: []const u8) !app_log.Cadence {
    gui_io.sleepNs(observe_ms * std.time.ns_per_ms);
    const c = try app_log.cadence(alloc, log_path, app_log.main_draw_marker, since_ms);
    c.report(label);
    return c;
}

/// The app window that is NOT in `before` and is at least
/// `min_side` points on both axes — the external float that just opened.
/// The size floor skips the small decorated overlays (tabline strip, mini
/// message popups) the ext UI options also bring on screen.
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

/// Poll until the external float shows up as a real OS window.
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

pub fn run(alloc: std.mem.Allocator) !void {
    if (!platform.accessibilityTrusted()) {
        std.debug.print(
            "[gui] skipped: this test binary is not trusted for Accessibility, so it " ++
                "cannot resize the app's window from the outside. Grant it under " ++
                "System Settings > Privacy & Security > Accessibility and rerun.\n",
            .{},
        );
        return error.SkipZigTest;
    }

    std.Io.Dir.cwd().createDirPath(gui_io.io(), "tmp") catch {};
    std.Io.Dir.cwd().deleteFile(gui_io.io(), log_path) catch {};

    // Same UI extensions the field session had attached: they add the
    // decorated overlay windows (mini message / cmdline) that share the
    // frontend's draw loop with the main view and the float.
    var g = try Gui.init(alloc, .{
        .app_args = &.{ "--extcmdline", "--extmessages", "--exttabline", "--log", log_path },
        .config_dir = "test/gui/fixtures/config_animated_shader",
    });
    defer g.deinit();

    // Fail loudly if the fixture shader did not load: without it the
    // renderer never enters the every-vsync mode and every gap below
    // would be a meaningless zero.
    try app_log.waitFor(alloc, log_path, app_log.animated_shader_marker, 15_000);

    // The field session was the active application throughout. Match it:
    // key-window state changes which windows AppKit keeps live.
    g.activateApp();
    gui_io.sleepNs(500 * std.time.ns_per_ms);

    // Baseline: the animated shader alone must hold 60fps. This also
    // proves the measurement can see a healthy loop, so a later failure
    // is about the resize and not about the harness.
    const t0 = try app_log.nowMs(alloc, log_path);
    const base = try measure(alloc, t0, "baseline (no float)");
    try std.testing.expect(base.samples > 60);
    if (base.max_gap_ms >= max_gap_ms) {
        std.debug.print("[gui] baseline already stalls — measurement is not trustworthy\n", .{});
        return error.BaselineStalled;
    }

    // Open an external float at the size the field report used.
    var before_buf: [max_windows]platform.MainWindow = undefined;
    const before = before_buf[0..platform.windowsForPid(g.app_pid, &before_buf)];
    try g.exec(
        "luaeval('(function() _G.e2e_main = vim.api.nvim_get_current_win() " ++
            "_G.e2e_float = vim.api.nvim_open_win(vim.api.nvim_create_buf(false, true), true, " ++
            "{external=true, width=60, height=29}) return 1 end)()')",
    );
    // Let the float settle at its opening size before measuring it.
    const opened = try waitNewWindow(g.app_pid, before, 200);
    gui_io.sleepNs(500 * std.time.ns_per_ms);

    // Park it near the top-left. The float opens wherever Neovim's
    // win_pos puts it, which on a 800pt-tall display leaves its bottom
    // edge — and with it the resize corner — off screen and ungrabbable.
    if (!platform.moveWindowBySize(g.app_pid, opened.bounds.w, opened.bounds.h, 40, 40)) {
        return error.MoveFailed;
    }
    gui_io.sleepNs(300 * std.time.ns_per_ms);
    const float_win = try waitNewWindow(g.app_pid, before, 200);
    const float_b = float_win.bounds;

    // Hand key status to the float's own NSWindow and back, the way the
    // field session did before the resize. Opening the float does not do
    // this on its own: onCursorGridChanged only activates a window on an
    // actual grid CHANGE, and the float opens with the cursor already on
    // its grid.
    try g.exec("luaeval('(function() vim.api.nvim_set_current_win(_G.e2e_main) return 1 end)()')");
    gui_io.sleepNs(300 * std.time.ns_per_ms);
    try g.exec("luaeval('(function() vim.api.nvim_set_current_win(_G.e2e_float) return 1 end)()')");
    gui_io.sleepNs(300 * std.time.ns_per_ms);

    // Drag its bottom-right corner in: 29 rows -> ~6, the shrink from the
    // field report. Real mouse events, so the view enters inLiveResize and
    // AppKit runs its resize tracking loop.
    const to_h = float_b.h * 6.0 / 29.0;
    const to_w = float_b.w * 47.0 / 60.0;
    // AppKit only tracks a drag for the ACTIVE application.
    g.activateApp();
    gui_io.sleepNs(300 * std.time.ns_per_ms);
    std.debug.print(
        "[gui] drag-resize float: ({d:.0}x{d:.0}) at ({d:.0},{d:.0}) -> ({d:.0}x{d:.0})\n",
        .{ float_b.w, float_b.h, float_b.x, float_b.y, to_w, to_h },
    );
    const t_drag = try app_log.nowMs(alloc, log_path);
    if (!platform.dragResizeWindowByMouse(g.app_pid, float_win, to_w, to_h, resize_steps)) return error.DragRefused;

    // Everything after this must use the size the float ACTUALLY settled at,
    // not the size the drag asked for: the frontend snaps external windows to
    // whole cells, and AX looks windows up by size.
    const resized = try waitNewWindow(g.app_pid, before, 50);
    std.debug.print("[gui] float after drag: ({d:.0}x{d:.0})\n", .{ resized.bounds.w, resized.bounds.h });

    // Without this the test is hollow: it would idle for three seconds and
    // pass while never having exercised the external-resize path at all.
    // Time-filtered, because float creation also logs a windowDidResize; and
    // it is the "resize gridId=" line that matters, since that one is only
    // reached once the round trip decides the grid really changed shape
    // (ZonvieCore.windowDidResize returns early otherwise).
    if (!try app_log.containsSince(alloc, log_path, "[external_window] resize gridId=", t_drag)) {
        return error.ResizeNotObserved;
    }

    // …and then move it around. The stall depends on the float's size AND
    // position, and this is the half that matters: the walk ends with the
    // float over the main window, and activating the main grid below orders
    // it in front, leaving the float fully covered.
    //
    // The waypoints are derived from the main window's own bounds rather
    // than hardcoded: on a multi-display setup fixed screen coordinates walk
    // the float onto the primary display, where the main window may not be,
    // and it would never end up covered.
    const main_b = g.mainWindowBounds() orelse return error.MainWindowNotFound;
    {
        var i: u32 = 0;
        while (i < 6) : (i += 1) {
            const t = @as(f64, @floatFromInt(i)) / 5.0;
            const x = main_b.x + (main_b.w - resized.bounds.w) * 0.5 * t;
            const y = main_b.y + (main_b.h - resized.bounds.h) * 0.5 * t;
            if (!platform.moveWindowBySize(g.app_pid, resized.bounds.w, resized.bounds.h, x, y)) {
                return error.MoveFailed;
            }
            gui_io.sleepNs(200 * std.time.ns_per_ms);
        }
    }

    // Move the cursor back to the main grid: this is what orders the main
    // window in front of the float and covers it, and in the field report
    // the stalls started right after this transition.
    const t_occlude = try app_log.nowMs(alloc, log_path);
    try g.exec("luaeval('(function() vim.api.nvim_set_current_win(_G.e2e_main) return 1 end)()')");

    // Leave a pending <C-w> the way the field session did: showcmd puts
    // "^W" in the mini message view and Neovim then sits idle waiting for
    // the second key, which is exactly the window the stalls fell into.
    try g.remoteSend("<C-w>");

    const t1 = try app_log.nowMs(alloc, log_path);
    const after = try measure(alloc, t1, "after float resize + move");

    // The whole point of the resize+move is to leave the float invisible, and
    // nothing above proves it happened: without this, a run where the float
    // stayed uncovered passes green while testing nothing. [ext_draw_skip] is
    // the app saying it took the guard — which also means a build without the
    // guard is what fails here, not a build that merely got lucky.
    // Anchored at t_occlude, not t1: the float goes invisible the moment the
    // main window is ordered in front, and the ext view then parks its loop
    // and stops logging — so by t1 the evidence is already in the past.
    if (!try app_log.containsSince(alloc, log_path, "[ext_draw_skip]", t_occlude)) {
        return error.FloatNeverOccluded;
    }
    // 3000ms at 60Hz is ~180 frames. A floor of 120 still leaves 50% margin
    // while catching a regression that halves the rate without ever exceeding
    // the gap threshold.
    try std.testing.expect(after.samples > 120);
    if (after.max_gap_ms >= max_gap_ms) {
        std.debug.print(
            "[gui] animated shader stalled {d:.0}ms after the external float was resized and moved\n",
            .{after.max_gap_ms},
        );
        return error.ShaderDrawStalled;
    }

    // The other way a window stops being composited: minimize it. The
    // visibility guard must park the loop rather than block on a drawable,
    // and restoring must bring the animation back rather than leave the
    // window parked on its stale last frame.
    if (!platform.setWindowMinimizedBySize(g.app_pid, main_b.w, main_b.h, true)) {
        return error.MinimizeFailed;
    }
    gui_io.sleepNs(1500 * std.time.ns_per_ms);
    if (!platform.setWindowMinimizedBySize(g.app_pid, main_b.w, main_b.h, false)) {
        return error.RestoreFailed;
    }
    g.activateApp();
    // Give AppKit the deminiaturize animation before the clock starts.
    gui_io.sleepNs(1500 * std.time.ns_per_ms);

    const t2 = try app_log.nowMs(alloc, log_path);
    const restored = try measure(alloc, t2, "after minimize/restore");
    if (restored.samples <= 120 or restored.max_gap_ms >= max_gap_ms) {
        std.debug.print(
            "[gui] animated shader did not resume after restore: draws={d} max_gap={d:.0}ms\n",
            .{ restored.samples, restored.max_gap_ms },
        );
        return error.ShaderDrawDidNotResume;
    }
}
