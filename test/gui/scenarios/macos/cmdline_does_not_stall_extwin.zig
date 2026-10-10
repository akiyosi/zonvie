// cmdline_does_not_stall_extwin — opening the external cmdline must not hold
// the frames of an external window it does not cover.
//
// A surface marked occlusion-suspect skips its frames for 100 ms. Each ':'
// moves the cursor onto the cmdline grid and cursor_grid_changed marks the
// other external surfaces; only a window the cmdline covers entirely may be
// marked, or an animating external window freezes for 100 ms on every ':'.
//
// Which branch of cursor_grid_changed a ':' takes depends on timing: on the
// development machine every press found the cmdline window registered (0 of
// 20 took the not-yet-registered branch), where the survey reported the
// unconditional mark. The assertion is on the marks themselves
// ([occlusion_suspect] surface <grid>), so it holds whichever branch runs.
// With the registered branch made unconditional it fails (20 of 20 marked);
// with the unregistered branch made unconditional it cannot, since that
// branch did not run.
//
// macOS-only: the occlusion gate and ExternalGridView are macOS frontend code.

const std = @import("std");
const driver = @import("../../driver.zig");
const Gui = driver.Gui;
const app_log = @import("../../app_log.zig");
const gui_io = @import("../../gui_io.zig");

const log_path = "tmp/gui_cmdline_extwin_stall.log";
const presses = 10;

pub fn run(alloc: std.mem.Allocator) !void {
    std.Io.Dir.cwd().createDirPath(gui_io.io(), "tmp") catch {};
    std.Io.Dir.cwd().deleteFile(gui_io.io(), log_path) catch {};

    var g = try Gui.init(alloc, .{
        .app_args = &.{ "--extcmdline", "--log", log_path },
        .config_dir = "test/gui/fixtures/config_render_trace",
    });
    defer g.deinit();
    g.activateApp();

    const base_windows = g.windowCount();
    const ext_mark = try app_log.lineMark(alloc, log_path);
    try g.exec(
        "luaeval('(function() local b = vim.api.nvim_create_buf(false, true) " ++
            "vim.api.nvim_buf_set_lines(b, 0, -1, false, {\"external\"}) " ++
            "vim.api.nvim_open_win(b, false, {external=true, width=60, height=20}) return 1 end)()')",
    );
    try g.waitWindowCount(base_windows + 1, 10_000);
    const ext_grid = try app_log.externalWindowGrid(alloc, log_path, 0);
    try app_log.waitFramesAfter(alloc, log_path, ext_grid, 1, ext_mark, 10_000);

    const t0 = try app_log.nowMs(alloc, log_path);
    var i: usize = 0;
    while (i < presses) : (i += 1) {
        try g.remoteSend(":");
        gui_io.sleepNs(600 * std.time.ns_per_ms);
        try g.remoteSend("<Esc>");
        gui_io.sleepNs(400 * std.time.ns_per_ms);
    }

    var marker_buf: [64]u8 = undefined;
    const marker = try std.fmt.bufPrint(&marker_buf, "[occlusion_suspect] surface {d}", .{ext_grid});
    const marks = try app_log.countLinesSince(alloc, log_path, marker, t0);
    const onto_cmdline = try app_log.countLinesSince(alloc, log_path, "[cursor_grid_changed] gridId=-100", t0);
    const unregistered = try app_log.countLinesSince(alloc, log_path, "not yet registered; skip main activation", t0);
    std.debug.print(
        "[gui] cmdline vs extwin: {d} ':' presses, cursor onto the cmdline {d} time(s) ({d} unregistered), surface {d} marked {d} time(s)\n",
        .{ presses, onto_cmdline, unregistered, ext_grid, marks },
    );

    // Gate: the presses did move the cursor onto the cmdline grid; without
    // that, zero marks would mean nothing.
    if (onto_cmdline == 0) return error.CursorNeverReachedCmdline;
    if (marks != 0) {
        std.debug.print("[gui] the external window was held back {d} time(s) by a cmdline that does not cover it\n", .{marks});
        return error.CmdlineStalledExternalWindow;
    }
}
