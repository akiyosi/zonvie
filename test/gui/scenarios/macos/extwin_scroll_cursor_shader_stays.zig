// extwin_scroll_cursor_shader_stays — while an EXTERNAL window eases a
// scroll, the cursor shader must stay on the cursor, not flick back to where
// the cursor would be without the ease.
//
// Reported symptom: with a cursor shader loaded, scrolling an external window
// fires the effect at the wrong place on every frame of the ease.
//
// Cause: the shader's cursor rect is one shared value, and each surface folds
// ITS frame's displacement into it. The external surface did that correctly.
// The main surface folded in its own displacement of the cursor's grid — zero,
// because that grid is not one it draws — every frame, with no check that the
// cursor was its to displace. Two surfaces answered "where is the cursor on
// the glass" for one cursor, one with the ease and one without, and the rect
// alternated between them.
//
// Measured on [shader_cursor], the value the shader receives. A rect that
// alternates reverses direction every frame; an eased rect moves one way and
// reverses at most once per key, when the next row step re-seeds it. The
// count of reversals is the exposure, so one run decides it.
//
// macOS-only: the shader cursor plumbing lives in the macOS frontend.

const std = @import("std");
const driver = @import("../../driver.zig");
const platform = driver.platform;
const Gui = driver.Gui;
const app_log = @import("../../app_log.zig");
const gui_io = @import("../../gui_io.zig");

const log_path = "tmp/gui_extwin_scroll_cursor_shader.log";
const cursor_marker = "[shader_cursor]";
const scroll_marker = "[ExternalGridView] scroll offset:";

const grid_rows = 20;
const grid_cols = 60;
const scroll_keys = 6;
/// Long enough for each ease to run out before the next key.
const key_gap_ms = 300;
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

const Motion = struct {
    /// Rect lines seen (the app logs one per change).
    samples: usize,
    /// Steps where the rect's y moved DOWN the glass. <C-e> moves content up,
    /// and the ease only ever decays toward the row's final position, so an
    /// eased rect's y never increases. A raw rect published with no
    /// displacement lands a whole row early and the next eased frame moves
    /// it back down: one such step per raw frame.
    flick_backs: usize,
};

fn measureMotion(alloc: std.mem.Allocator, since_ms: f64) !Motion {
    const blob = try app_log.linesSince(alloc, log_path, cursor_marker, since_ms);
    defer alloc.free(blob);
    var samples: usize = 0;
    var flick_backs: usize = 0;
    var prev_y: ?f64 = null;
    var it = std.mem.splitScalar(u8, blob, '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        const y = app_log.field(line, "y") orelse continue;
        samples += 1;
        if (prev_y) |py| {
            // One pixel of slack for the rect's own rounding.
            if (y > py + 1.0) flick_backs += 1;
        }
        prev_y = y;
    }
    return .{ .samples = samples, .flick_backs = flick_backs };
}

/// Cell height in drawable pixels, from the offset line's own NDC terms, and
/// how many eased frames the run produced.
fn measureEase(alloc: std.mem.Allocator, since_ms: f64) !struct { frames: usize, cell_px: f64 } {
    const blob = try app_log.linesSince(alloc, log_path, scroll_marker, since_ms);
    defer alloc.free(blob);
    var frames: usize = 0;
    var cell: f64 = 0;
    var it = std.mem.splitScalar(u8, blob, '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        const offset = app_log.field(line, "offsetPx") orelse continue;
        if (@abs(offset) <= 0) continue;
        frames += 1;
        if (cell == 0) {
            const cell_ndc = app_log.field(line, "cellNDC") orelse 0;
            const vp_h = app_log.field(line, "vpH") orelse 0;
            if (cell_ndc > 0 and vp_h > 0) cell = cell_ndc * vp_h / 2.0;
        }
    }
    return .{ .frames = frames, .cell_px = cell };
}

pub fn run(alloc: std.mem.Allocator) !void {
    std.Io.Dir.cwd().createDirPath(gui_io.io(), "tmp") catch {};
    std.Io.Dir.cwd().deleteFile(gui_io.io(), log_path) catch {};

    var g = try Gui.init(alloc, .{
        .app_args = &.{ "--log", log_path },
        .config_dir = "test/gui/fixtures/config_cursor_shader",
    });
    defer g.deinit();
    g.activateApp();

    var before_buf: [max_windows]platform.MainWindow = undefined;
    const before = before_buf[0..platform.windowsForPid(g.app_pid, &before_buf)];

    // The cursor sits mid-buffer, so <C-e> scrolls the view while the cursor
    // keeps its line: the rect moves one row per key and the ease holds it.
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
    _ = try waitNewWindow(g.app_pid, before, 150);
    gui_io.sleepNs(800 * std.time.ns_per_ms);

    const t0 = try app_log.nowMs(alloc, log_path);
    const topline_before = try g.evalInt("line('w0')");

    var sent: usize = 0;
    while (sent < scroll_keys) : (sent += 1) {
        try g.remoteSend("<C-e>");
        gui_io.sleepNs(key_gap_ms * std.time.ns_per_ms);
    }
    gui_io.sleepNs(400 * std.time.ns_per_ms);

    const topline_after = try g.evalInt("line('w0')");
    if (topline_after == topline_before) {
        std.debug.print("[gui] the external window never scrolled; nothing to measure\n", .{});
        return error.ExternalWindowDidNotScroll;
    }

    const ease = try measureEase(alloc, t0);
    if (ease.frames == 0 or ease.cell_px <= 0) {
        std.debug.print("[gui] no eased frame was logged; the ease itself is not running\n", .{});
        return error.ExternalWindowScrollNotEased;
    }

    const motion = try measureMotion(alloc, t0);
    std.debug.print(
        "[gui] extwin cursor shader during ease: samples={d} flick_backs={d} eased_frames={d} cell={d:.1}px\n",
        .{ motion.samples, motion.flick_backs, ease.frames, ease.cell_px },
    );
    // Without samples there was no eased cursor rect to flick, and the
    // assertion below would pass on silence.
    if (motion.samples < scroll_keys * 2) {
        std.debug.print("[gui] only {d} cursor rect(s) logged for {d} keys\n", .{ motion.samples, scroll_keys });
        return error.CursorRectNotPublished;
    }
    // Measured as exposure: every raw frame is one, and the fixed build has
    // none. On the unfixed build it was one per key with a static shader and
    // would be one per frame with an animating one.
    if (motion.flick_backs != 0) {
        std.debug.print(
            "[gui] the shader cursor flicked back {d} time(s) over {d} keys: a surface that does " ++
                "not draw the cursor's grid is folding its own (zero) displacement into the rect.\n",
            .{ motion.flick_backs, scroll_keys },
        );
        return error.CursorShaderFlicksBack;
    }
}
