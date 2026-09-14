// visual/extwin_continuous_j_scroll_matches_jump — holding `j` past the bottom
// of an EXTERNAL window must leave the same screen as jumping to where it
// ended up, exactly as it does in the main window.
//
// A scrolled surface does not repaint the rows the scroll only moved: the
// frontend blits those pixels and the core sends vertices for the vacated band
// alone. That trade only holds while the marks naming rows still name the rows
// they were made for. A mark made before a shift, and consumed after it, points
// at a row whose vertices moved somewhere else — and with the blit accepted,
// the row they moved TO is never repainted and keeps what the copy dragged in.
//
// The main surface shifts both of its mark sets with the rows
// (MetalTerminalRenderer's applyLayerRowScroll and commitFlush). The external
// surface's root path called the same remap and shifted neither: the commit
// that introduced the main-side shift says in its own message that the
// external caller "is not audited".
//
// Driven the way the main-window scenario drives it — continuous `j` against a
// direct jump — because the invariant is relational and needs no golden. What
// differs here is the window: the capture is of the external window, not the
// app's main one.
//
// What this DOES guard, proven by probe: the redraw set the accepted blit
// leaves behind. Emptying it turns this red with a quarter of the window
// wrong, in the banding the copy produces.
//
// What it does NOT guard: the mark shift itself. That needs marks made in one
// flush to survive into the next with no draw in between, and the driver sends
// one key per RPC round trip, so a frame lands between every pair. Removing
// both shifts leaves this green. The rule they implement is pinned instead by
// ScrollRetentionTests' verifyOnlyCarriedMarksAreShiftedAtCommit, where the
// ordering is stated rather than raced for.
//
// macOS-only: it drives the macOS external-window surface. The Windows
// external path carries its dirty bits through shiftRowBits already.

const std = @import("std");
const driver = @import("../../driver.zig");
const platform = driver.platform;
const capture = driver.capture;
const fixture = @import("fixture.zig");
const visual = @import("../../visual.zig");
const gui_io = @import("../../gui_io.zig");
const app_log = @import("../../app_log.zig");

const log_path = "tmp/gui_extwin_j_scroll.log";
const max_windows = 16;

/// Rows to walk past the bottom. Enough that a mark left one row behind shows
/// as a band rather than a single stray line.
const steps: usize = 14;

const ext_rows: i64 = 18;
const ext_cols: i64 = 60;

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

/// The window minus the scrollbar strip on its right edge, which fades on its
/// own clock and would register as a difference the scroll did not cause.
fn bodyRegion(img: capture.Image) visual.Region {
    const w: f64 = @floatFromInt(img.w);
    const strip_px: f64 = 24;
    return .{ .x1 = @max(0.0, (w - strip_px) / w) };
}

/// How many row-shift hints this window's root actually accepted. The hint is
/// logged before the guards, so the line alone is not proof; require the two
/// the log carries (a live bracket, a non-zero delta) — the remaining guard is
/// full width, which a root window scroll always is.
fn appliedShifts(alloc: std.mem.Allocator, since_ms: f64) !usize {
    const blob = try app_log.linesSince(alloc, log_path, "[ext_applyRowScroll]", since_ms);
    defer alloc.free(blob);
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, blob, '\n');
    while (it.next()) |line| {
        if (std.mem.indexOf(u8, line, "isInFlush=true") == null) continue;
        const delta = app_log.field(line, "rowsDelta") orelse continue;
        if (delta == 0) continue;
        n += 1;
    }
    return n;
}

pub fn run(alloc: std.mem.Allocator) !void {
    try fixture.requireScreenAccess();
    std.Io.Dir.cwd().createDirPath(gui_io.io(), "tmp") catch {};
    std.Io.Dir.cwd().deleteFile(gui_io.io(), log_path) catch {};

    // Smooth scroll off. Its ease sets `smoothScrolling`, which is one of the
    // conditions the GPU scroll copy fails closed on: with it on, an external
    // window answers every scroll by redrawing all of its rows, and the blit
    // plus the marks that have to survive it never run at all. Verified by
    // probe: with the ease on, emptying the blit's redraw set changed nothing
    // on screen.
    var g = try fixture.openWithLogConfigAndEnv(
        alloc,
        log_path,
        "test/gui/fixtures/config",
        &.{.{ "ZONVIE_SMOOTH_SCROLL", "0" }},
    );
    defer g.deinit();

    try g.exec("execute('set laststatus=0 noruler noshowcmd scrolloff=0 nowrap cursorline')");
    // Every line differs across the full width: a screen of identical lines
    // would survive a misplaced row unchanged.
    try g.exec(
        \\setline(1, map(range(1, 400), {_, i -> printf('%3d %s', i, repeat(nr2char(65 + i % 26), 60))}))
    );

    var before_buf: [max_windows]platform.MainWindow = undefined;
    const before = before_buf[0..platform.windowsForPid(g.app_pid, &before_buf)];

    var cmd_buf: [256]u8 = undefined;
    const open_cmd = try std.fmt.bufPrint(
        &cmd_buf,
        "luaeval('(function() _G.z_ext = vim.api.nvim_open_win(0, true, {{external=true, width={d}, height={d}}}) return 1 end)()')",
        .{ ext_cols, ext_rows },
    );
    try g.exec(open_cmd);
    const ext_win = try waitNewWindow(g.app_pid, before, 100);
    gui_io.sleepNs(800 * std.time.ns_per_ms);

    // Start with the cursor on the last visible row, so every `j` scrolls.
    try g.exec("execute('normal! 100GztL')");
    var start = try captureWindowStable(alloc, ext_win.number, 8000);
    defer start.deinit(alloc);

    const topline_before = try g.evalInt("line('w0')");
    const t_scroll = try app_log.nowMs(alloc, log_path);

    // One key per send: each is its own flush, which is what lets a flush
    // carrying only a cursorline move be followed by one carrying a scroll
    // before any draw runs.
    var i: usize = 0;
    while (i < steps) : (i += 1) {
        try g.remoteSend("j");
    }

    var scrolled = try captureWindowStable(alloc, ext_win.number, 8000);
    defer scrolled.deinit(alloc);
    if (scrolled.w != start.w or scrolled.h != start.h) return error.ExternalWindowResized;

    // A refused hint regenerates every row and reaches the same screen, so the
    // pixel comparison alone cannot tell whether the shift path ran at all.
    const shifts = try appliedShifts(alloc, t_scroll);
    const min_shifts: usize = steps / 2;
    std.debug.print(
        "[gui] extwin_continuous_j_scroll: root row-shift hints applied {d} (need {d})\n",
        .{ shifts, min_shifts },
    );
    if (shifts < min_shifts) {
        std.debug.print("[gui] the external window's scroll fast path did not run; this comparison would guard nothing\n", .{});
        return error.ScrollFastPathDidNotRun;
    }

    const topline_after = try g.evalInt("line('w0')");
    const cursor_after = try g.evalInt("line('.')");
    std.debug.print(
        "[gui] extwin_continuous_j_scroll: topline {d} -> {d}, cursor {d}\n",
        .{ topline_before, topline_after, cursor_after },
    );
    if (topline_after <= topline_before) {
        std.debug.print("[gui] the external window did not scroll — test would be vacuous\n", .{});
        return error.ScrollDidNotRender;
    }
    const region = bodyRegion(scrolled);
    const moved = visual.regionDiffRatio(start, scrolled, region, 6);
    if (moved <= 0.0002) {
        std.debug.print(
            "[gui] the external window's pixels did not change ({d:.4}) — test would be vacuous\n",
            .{moved},
        );
        return error.ScrollDidNotRender;
    }

    // The same view reached by a repaint, which cannot carry a shift error.
    // Land somewhere else first so the jump is not a no-op that leaves the
    // scrolled screen in place.
    try g.exec("execute('normal! 1Gzt0')");
    var settled = try captureWindowStable(alloc, ext_win.number, 8000);
    settled.deinit(alloc);

    var jump_buf: [96]u8 = undefined;
    const jump = try std.fmt.bufPrint(
        &jump_buf,
        "execute('normal! {d}Gzt{d}G')",
        .{ topline_after, cursor_after },
    );
    try g.exec(jump);
    var jumped = try captureWindowStable(alloc, ext_win.number, 8000);
    defer jumped.deinit(alloc);
    if (jumped.w != scrolled.w or jumped.h != scrolled.h) return error.ExternalWindowResized;

    try visual.assertRegionUnchanged(
        alloc,
        "extwin_continuous_j_scroll",
        jumped,
        scrolled,
        region,
        .{},
    );
}
