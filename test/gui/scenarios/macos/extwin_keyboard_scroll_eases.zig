// extwin_keyboard_scroll_eases — a single-row scroll in an EXTERNAL window
// has to animate, the way the same scroll does in the main window.
//
// The sub-row ease is what makes a one-row scroll glide instead of jump: the
// step seeds a pixel offset of about one cell and the frames after it decay
// that offset to zero. Both ends of that used to belong to the main surface
// alone — the seed was staged by MetalTerminalRenderer and spent by the main
// view's onPreDraw — so a grid living in its own window produced no seed and
// had no tick to spend one, and its content jumped a whole row. The seed now
// rides ScrollRetention (which every surface steps through) and the tick runs
// from the shared scroll service every surface calls.
//
// Driven by <C-e>, not the trackpad: a gesture owns the offset through the
// finger and never reaches the ease, so a gesture-driven scroll would pass on
// the broken build too.
//
// Observed through the offset the app feeds its shader rather than through
// pixels. A one-row glide and a one-row jump have the SAME endpoints, so a
// before/after pixel diff cannot tell them apart; what separates them is
// whether intermediate offsets exist at all, and whether they decay.
//
// macOS-only: the external-window smooth-scroll path is macOS frontend.

const std = @import("std");
const driver = @import("../../driver.zig");
const platform = driver.platform;
const Gui = driver.Gui;
const app_log = @import("../../app_log.zig");
const gui_io = @import("../../gui_io.zig");

const log_path = "tmp/gui_extwin_scroll_ease.log";
const scroll_marker = "[ExternalGridView] scroll offset:";

const grid_rows = 20;
const grid_cols = 60;
/// Each <C-e> is one row, which is exactly the step that seeds an ease.
const scroll_keys = 6;
/// Long enough for the decay to run out between keys (it eases to epsilon in
/// ~250ms), so each key contributes its own run of frames rather than
/// re-seeding one that is still going.
const key_gap_ms = 300;

/// Frames of ease the whole run must produce. One offset line proves only
/// that a seed landed; the animation is the frames after it.
const min_offset_frames = 3;

const max_windows = 16;

fn waitNewWindow(pid: i32, before: []const platform.MainWindow, min_side: f64) !platform.MainWindow {
    var timer = gui_io.Timer.start();
    while (true) {
        var buf: [max_windows]platform.MainWindow = undefined;
        const now = buf[0..platform.windowsForPid(pid, &buf)];
        outer: for (now) |w| {
            for (before) |b| {
                if (b.number == w.number) continue :outer;
            }
            if (w.bounds.w < min_side or w.bounds.h < min_side) continue;
            return w;
        }
        if (timer.read() / std.time.ns_per_ms >= 10_000) {
            platform.dumpWindowsForPid(pid);
            return error.ExternalWindowNotFound;
        }
        gui_io.sleepNs(100 * std.time.ns_per_ms);
    }
}

/// A burst of keys arriving faster than one ease settles. The offsets they
/// seed have to STACK: the row a key scrolls is compensated whether or not the
/// previous row has finished easing, so a re-seed must land while the offset
/// from the last one is still large. Without that the picture jumps a row per
/// key and only the last one animates.
const burst_keys = 5;
const burst_gap_ms = 60;
/// The offset a re-seed interrupted, above which it counts as landing on a
/// live ease. Only reported, not asserted: with the default decay an ease
/// settles in ~100ms while a --remote-send round trip takes 30-50ms, so how
/// much is left when the next key arrives is a race. What IS invariant is that
/// every row scrolled gets a compensation, which is the assertion below.
const mid_ease_fraction: f64 = 0.25;

const Ease = struct {
    frames: usize,
    peak_px: f64,
    /// Cell height derived from the same line the offset came from, so the
    /// peak is compared against this window's real row height.
    cell_px: f64,
    /// True when some line after the peak carried a strictly smaller offset —
    /// the decay. Without it a seed could sit at one value and be replaced,
    /// which is a jump with extra steps.
    decayed: bool,
};

/// How many times the offset jumped back up, and how many of those happened
/// while the previous ease was still visibly in flight.
fn countReseeds(alloc: std.mem.Allocator, since_ms: f64, cell_px: f64) !struct { total: usize, mid_ease: usize } {
    const blob = try app_log.linesSince(alloc, log_path, scroll_marker, since_ms);
    defer alloc.free(blob);
    var total: usize = 0;
    var mid: usize = 0;
    var prev: f64 = 0;
    var it = std.mem.splitScalar(u8, blob, '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        const offset = app_log.field(line, "offsetPx") orelse continue;
        const mag = @abs(offset);
        // Half a pixel of slack: the decay produces tiny non-monotonic steps
        // when two surfaces tick in the same frame.
        if (mag > prev + 0.5) {
            total += 1;
            if (prev > cell_px * mid_ease_fraction) mid += 1;
        }
        prev = mag;
    }
    return .{ .total = total, .mid_ease = mid };
}

fn measureEase(alloc: std.mem.Allocator, since_ms: f64) !Ease {
    const blob = try app_log.linesSince(alloc, log_path, scroll_marker, since_ms);
    defer alloc.free(blob);

    var frames: usize = 0;
    var peak: f64 = 0;
    var cell: f64 = 0;
    var decayed = false;
    var seen_peak = false;

    var it = std.mem.splitScalar(u8, blob, '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        const offset = app_log.field(line, "offsetPx") orelse continue;
        const mag = @abs(offset);
        if (mag <= 0) continue;
        frames += 1;
        if (cell == 0) {
            // cellNDC = cellH * 2 / vpH
            const cell_ndc = app_log.field(line, "cellNDC") orelse 0;
            const vp_h = app_log.field(line, "vpH") orelse 0;
            if (cell_ndc > 0 and vp_h > 0) cell = cell_ndc * vp_h / 2.0;
        }
        if (mag > peak) {
            peak = mag;
            seen_peak = true;
        } else if (seen_peak and mag < peak) {
            decayed = true;
        }
    }
    return .{ .frames = frames, .peak_px = peak, .cell_px = cell, .decayed = decayed };
}

pub fn run(alloc: std.mem.Allocator) !void {
    std.Io.Dir.cwd().createDirPath(gui_io.io(), "tmp") catch {};
    std.Io.Dir.cwd().deleteFile(gui_io.io(), log_path) catch {};

    var g = try Gui.init(alloc, .{ .app_args = &.{ "--log", log_path } });
    defer g.deinit();

    var before_buf: [max_windows]platform.MainWindow = undefined;
    const before = before_buf[0..platform.windowsForPid(g.app_pid, &before_buf)];

    // Enough lines to scroll through without reaching the buffer end, which
    // would block the scroll and hand the offset to the edge bounce instead
    // of the ease.
    try g.exec(
        "luaeval('(function() local b = vim.api.nvim_create_buf(false, true) " ++
            "local lines = {} for i = 1, 400 do lines[i] = string.rep(\"line \" .. i .. \" \", 6) end " ++
            "vim.api.nvim_buf_set_lines(b, 0, -1, true, lines) " ++
            "_G.e2e_extwin = vim.api.nvim_open_win(b, true, " ++
            "{external=true, width=" ++ std.fmt.comptimePrint("{d}", .{grid_cols}) ++
            ", height=" ++ std.fmt.comptimePrint("{d}", .{grid_rows}) ++ "}) " ++
            "vim.api.nvim_win_set_cursor(_G.e2e_extwin, {200, 0}) " ++
            "return 1 end)()')",
    );
    const extwin = try waitNewWindow(g.app_pid, before, 150);
    // Let the window settle so the first key is not racing its first frames.
    gui_io.sleepNs(800 * std.time.ns_per_ms);

    const t0 = try app_log.nowMs(alloc, log_path);
    const topline_before = try g.evalInt("line('w0')");

    var sent: usize = 0;
    while (sent < scroll_keys) : (sent += 1) {
        // <C-e>: scroll the view down exactly one line, cursor along with it.
        try g.remoteSend("<C-e>");
        gui_io.sleepNs(key_gap_ms * std.time.ns_per_ms);
    }

    // Before reading anything about the animation, prove the scroll happened
    // at all: with no movement every assertion below would be measuring an
    // idle window and would "pass" the moment it was inverted.
    const topline_after = try g.evalInt("line('w0')");
    std.debug.print(
        "[gui] extwin topline before={d} after={d}\n",
        .{ topline_before, topline_after },
    );
    if (topline_after == topline_before) {
        std.debug.print(
            "[gui] the external window never scrolled, so this run says nothing " ++
                "about whether a scroll is animated.\n",
            .{},
        );
        return error.ExternalWindowDidNotScroll;
    }

    const ease = try measureEase(alloc, t0);
    std.debug.print(
        "[gui] extwin ease: frames={d} peak={d:.1}px cell={d:.1}px decayed={}\n",
        .{ ease.frames, ease.peak_px, ease.cell_px, ease.decayed },
    );

    if (ease.frames == 0) {
        std.debug.print(
            "[gui] the external window fed its shader no scroll offset at all: " ++
                "a one-row scroll there is not animated.\n",
            .{},
        );
        return error.ExternalWindowScrollNotEased;
    }
    if (ease.frames < min_offset_frames) {
        std.debug.print(
            "[gui] only {d} eased frame(s); an animation needs at least {d}.\n",
            .{ ease.frames, min_offset_frames },
        );
        return error.ExternalWindowEaseTooShort;
    }
    if (ease.cell_px <= 0) {
        std.debug.print("[gui] could not derive the cell height from the offset log\n", .{});
        return error.CellHeightUnparsable;
    }
    // The floor is deliberately far below the one cell a row step seeds. The
    // offset is only logged on frames that DREW, so the first sample already
    // carries a few frames of decay and the peak depends on when the draw
    // clock happened to land: 15.9px and 12.0px on two runs with a 33px cell.
    // A fifth of a row is still an order of magnitude above the sub-pixel
    // epsilon the ease settles at, so it rejects a stray offset being read as
    // an animation without measuring sampling luck.
    if (ease.peak_px < ease.cell_px * 0.2) {
        std.debug.print(
            "[gui] peak offset {d:.1}px is far below one row ({d:.1}px): " ++
                "this is not a row step easing.\n",
            .{ ease.peak_px, ease.cell_px },
        );
        return error.ExternalWindowEaseTooSmall;
    }
    // Phase 2: keys faster than the ease settles, AFTER a trackpad gesture.
    //
    // The gesture is what arms this window's scrollable span, and nothing ever
    // disarms it (see armScrollRetention's own note), so every keyboard scroll
    // from here on takes the branch where the grid_scroll hand-over looks
    // usable. Without this nudge the burst only exercises the unarmed branch
    // and the armed one — the state a user is in the moment they touch the
    // trackpad once — goes untested.
    if (platform.scrollBegin(g.app_pid, extwin)) {
        var nudge: usize = 0;
        while (nudge < 3) : (nudge += 1) {
            platform.scrollStep(-2);
            gui_io.sleepNs(16 * std.time.ns_per_ms);
        }
        platform.scrollEnd();
        // Let the gesture's own compensation finish so the burst below is
        // measured against a settled offset, not the finger's.
        gui_io.sleepNs(900 * std.time.ns_per_ms);
    } else {
        std.debug.print("[gui] could not drive a trackpad gesture; the armed branch is untested\n", .{});
        return error.SkipZigTest;
    }

    const burst_t0 = try app_log.nowMs(alloc, log_path);
    const burst_topline_before = try g.evalInt("line('w0')");
    // Sent one at a time. Delivered together Neovim coalesces them into a
    // single multi-row grid_scroll, which is a different event shape and not
    // the repeated single-row step this is about.
    var burst_sent: usize = 0;
    while (burst_sent < burst_keys) : (burst_sent += 1) {
        try g.remoteSend("<C-e>");
        gui_io.sleepNs(burst_gap_ms * std.time.ns_per_ms);
    }
    gui_io.sleepNs(500 * std.time.ns_per_ms);
    const burst_topline_after = try g.evalInt("line('w0')");
    if (burst_topline_after == burst_topline_before) {
        std.debug.print("[gui] the burst did not scroll the window\n", .{});
        return error.ExternalWindowDidNotScroll;
    }
    const reseeds = try countReseeds(alloc, burst_t0, ease.cell_px);
    std.debug.print(
        "[gui] extwin burst: topline {d} -> {d}, re-seeds={d} of which mid-ease={d}\n",
        .{ burst_topline_before, burst_topline_after, reseeds.total, reseeds.mid_ease },
    );
    // One compensation per row scrolled. A key that arrives while the previous
    // ease is still running used to produce none: the grid_scroll gate fired on
    // the offset that ease was holding, handed the distance to a capture that
    // had no span to use, and the row moved uncompensated — so the count came
    // up short of the keys.
    const rows_scrolled: usize = @intCast(burst_topline_after - burst_topline_before);
    if (reseeds.total < rows_scrolled) {
        std.debug.print(
            "[gui] {d} row(s) scrolled but only {d} compensated: a key struck during " ++
                "an ease scrolls a row with nothing to ease it, so it jumps.\n",
            .{ rows_scrolled, reseeds.total },
        );
        return error.ExternalWindowBurstNotEased;
    }

    if (!ease.decayed) {
        std.debug.print(
            "[gui] the offset never decreased: the offset was replaced, not eased.\n",
            .{},
        );
        return error.ExternalWindowEaseDoesNotDecay;
    }
}
