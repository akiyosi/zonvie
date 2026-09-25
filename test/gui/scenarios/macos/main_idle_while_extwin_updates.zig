// main_idle_while_extwin_updates — a flush that changes only an external
// window must not make the MAIN window draw.
//
// The core opens the main surface's bracket on every flush, and the main
// commit bumped its revision whether or not the bracket carried anything. A
// new revision with no dirty row, layer work or cursor is a frame the main
// surface cannot skip (`noMainWorkFrame` needs `!hasNewCommit`), so every
// update to an external window paid a main pass. The external surface's own
// contentless bracket has never bumped.
//
// Each update also brings a glyph never drawn before, so the shared atlas is
// swapped in those flushes: a swap is not work the main surface landed either.
//
// Driven with the cursor parked in the MAIN window, so no flush carries a
// cursor change: a moving cursor gives the main surface a cursor-only commit,
// which it already skips, and would hide the defect. The external window
// shows a second buffer that is rewritten line by line.
//
// Measured on the idle gate's trace: a main frame drawn for a new commit with
// nothing else in it is the exposure, counted directly.
//
// Then the cursor does move, each time in the same call as an external update,
// so the main surface gets a cursor-only commit followed by a contentless one
// before it draws. The contentless bracket used to overwrite the cursor-only
// verdict, and the frame ran the whole main pass. Counted as cursor-only
// frames drawn less the main passes they logged skipping.
//
// macOS-only: GridSurfaceRenderer is macOS frontend code.

const std = @import("std");
const driver = @import("../../driver.zig");
const platform = driver.platform;
const Gui = driver.Gui;
const app_log = @import("../../app_log.zig");
const gui_io = @import("../../gui_io.zig");

const log_path = "tmp/gui_main_idle_extwin.log";
const updates = 12;
const max_windows = 16;

fn waitNewWindow(pid: i32, before: []const platform.MainWindow) !void {
    var timer = gui_io.Timer.start();
    while (true) {
        var buf: [max_windows]platform.MainWindow = undefined;
        const now = buf[0..platform.windowsForPid(pid, &buf)];
        if (now.len > before.len) return;
        if (timer.read() / std.time.ns_per_ms >= 10_000) return error.ExternalWindowNotFound;
        gui_io.sleepNs(100 * std.time.ns_per_ms);
    }
}

/// Main frames drawn only because a commit landed.
fn emptyCommitFrames(alloc: std.mem.Allocator, since_ms: f64) !usize {
    const lines = try app_log.linesSince(alloc, log_path, "[dtrace] surface=1 gate=idle", since_ms);
    defer alloc.free(lines);
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, lines, '\n');
    while (it.next()) |line| {
        const empty = std.mem.indexOf(u8, line, "newCommit=1 cursor=0 dirty=0 rect=0 layerWork=0 scroll=0 scrollOff=0 smooth=0 shaderCur=0 blink=0 sizeChg=0 anim=0 -> draw") != null;
        if (empty) n += 1;
    }
    return n;
}

/// Cursor-only main frames that still ran the main pass: every one that drew,
/// less the ones that logged skipping it.
fn cursorOnlyMainPasses(alloc: std.mem.Allocator, since_ms: f64) !usize {
    const frames = try app_log.linesSince(alloc, log_path, "[dtrace] surface=1 gate=idle", since_ms);
    defer alloc.free(frames);
    var drawn: usize = 0;
    var it = std.mem.splitScalar(u8, frames, '\n');
    while (it.next()) |line| {
        const cursor_only = std.mem.indexOf(u8, line, "newCommit=1") != null and
            std.mem.indexOf(u8, line, "dirty=0 rect=0 layerWork=0 scroll=0 scrollOff=0 smooth=0 shaderCur=1 blink=0 sizeChg=0 anim=0 -> draw") != null;
        if (cursor_only) drawn += 1;
    }
    const skips = try app_log.linesSince(alloc, log_path, "[draw] skipMainPass=true", since_ms);
    defer alloc.free(skips);
    var skipped: usize = 0;
    var sit = std.mem.splitScalar(u8, skips, '\n');
    while (sit.next()) |line| {
        if (line.len != 0) skipped += 1;
    }
    std.debug.print("[gui] cursor-only main frames: {d}; main passes skipped: {d}\n", .{ drawn, skipped });
    if (drawn == 0) return error.NoCursorOnlyFrame;
    return drawn -| skipped;
}

/// Frames any external surface drew.
fn externalDraws(alloc: std.mem.Allocator, since_ms: f64) !usize {
    const lines = try app_log.linesSince(alloc, log_path, "gate=idle", since_ms);
    defer alloc.free(lines);
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, lines, '\n');
    while (it.next()) |line| {
        if (std.mem.indexOf(u8, line, "surface=1 ") != null) continue;
        if (std.mem.indexOf(u8, line, "-> draw") != null) n += 1;
    }
    return n;
}

pub fn run(alloc: std.mem.Allocator) !void {
    std.Io.Dir.cwd().createDirPath(gui_io.io(), "tmp") catch {};
    std.Io.Dir.cwd().deleteFile(gui_io.io(), log_path) catch {};

    var g = try Gui.init(alloc, .{
        .app_args = &.{ "--log", log_path },
        .config_dir = "test/gui/fixtures/config",
        .app_env = &.{.{ "ZONVIE_DRAW_TRACE", "1" }},
    });
    defer g.deinit();

    try g.exec("execute('set nocursorline noruler noshowcmd laststatus=0 guicursor+=a:blinkon0')");

    var before_buf: [max_windows]platform.MainWindow = undefined;
    const before = before_buf[0..platform.windowsForPid(g.app_pid, &before_buf)];
    // A second buffer in an external window; focus stays in the main window.
    try g.exec(
        "luaeval('(function() _G.z_buf = vim.api.nvim_create_buf(false, true) " ++
            "vim.api.nvim_open_win(_G.z_buf, false, {external=true, width=40, height=12}) return 1 end)()')",
    );
    try waitNewWindow(g.app_pid, before);
    gui_io.sleepNs(1500 * std.time.ns_per_ms);

    const t0 = try app_log.nowMs(alloc, log_path);
    var i: usize = 0;
    while (i < updates) : (i += 1) {
        // A glyph no surface has drawn yet, every time: the external window
        // rasterizes it and the shared atlas is swapped, which says nothing
        // about the main window's pixels.
        var buf: [200]u8 = undefined;
        const cmd = try std.fmt.bufPrint(
            &buf,
            "luaeval('vim.api.nvim_buf_set_lines(_G.z_buf, 0, 1, false, {{\"update {d} \" .. vim.fn.nr2char({d})}})')",
            .{ i, 0x4E00 + i * 7 },
        );
        try g.exec(cmd);
        gui_io.sleepNs(120 * std.time.ns_per_ms);
    }
    gui_io.sleepNs(400 * std.time.ns_per_ms);

    const empty = try emptyCommitFrames(alloc, t0);
    const ext_draws = try externalDraws(alloc, t0);
    std.debug.print(
        "[gui] main frames drawn for an empty commit: {d}; external frames drawn: {d}\n",
        .{ empty, ext_draws },
    );
    // Gate: the external window has to have drawn the updates, or nothing was
    // exercised.
    if (ext_draws == 0) return error.ExternalWindowDidNotDraw;
    if (empty != 0) return error.MainDrewForExternalOnlyFlush;

    try g.exec("setline(1, 'ab')");
    gui_io.sleepNs(400 * std.time.ns_per_ms);
    const t1 = try app_log.nowMs(alloc, log_path);
    i = 0;
    while (i < updates) : (i += 1) {
        var buf: [300]u8 = undefined;
        const cmd = try std.fmt.bufPrint(
            &buf,
            "luaeval('(function() vim.api.nvim_win_set_cursor(0, {{1, {d}}}) vim.api.nvim__redraw({{cursor=true, flush=true}}) " ++
                "vim.api.nvim_buf_set_lines(_G.z_buf, 0, 1, false, {{\"moved {d}\"}}) return 1 end)()')",
            .{ i % 2, i },
        );
        try g.exec(cmd);
        gui_io.sleepNs(120 * std.time.ns_per_ms);
    }
    gui_io.sleepNs(400 * std.time.ns_per_ms);

    const passes = try cursorOnlyMainPasses(alloc, t1);
    std.debug.print("[gui] cursor-only main frames that ran the main pass: {d}\n", .{passes});
    if (passes != 0) return error.MainPassForCursorOnlyFrame;
}
