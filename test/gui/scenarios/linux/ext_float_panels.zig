// ext_float_panels — a completion popupmenu in an external float (a stock
// Neovim's nvim_open_win external=true) is a popup of that external window,
// drawn there under its cursor; closing the external window hands the popup
// back to the main view and the app keeps running.
//
// Linux-only: linux/panel_popup.zig hostSurface / reparent / surfaceClosing.

const std = @import("std");
const driver = @import("../../driver.zig");
const app_log = @import("../../app_log.zig");
const gui_io = @import("../../gui_io.zig");

const log_path = "tmp/gui_ext_float_panels.log";

pub fn run(alloc: std.mem.Allocator) !void {
    std.Io.Dir.cwd().createDirPath(gui_io.io(), "tmp") catch {};
    std.Io.Dir.cwd().deleteFile(gui_io.io(), log_path) catch {};
    var g = try driver.Gui.init(alloc, .{
        .app_args = &.{ "--extpopup", "--log", log_path },
        .config_dir = "test/gui/fixtures/config",
    });
    defer g.deinit();
    g.activateApp();
    try app_log.waitFramesAfter(alloc, log_path, 1, 1, 0, 10_000);

    var mark = try app_log.lineMark(alloc, log_path);
    try g.exec("luaeval('vim.api.nvim_open_win(0, true, {external=true, width=60, height=12})')");
    try app_log.waitAfter(alloc, log_path, "[external_window] open", mark, 5_000);
    gui_io.sleepNs(500 * std.time.ns_per_ms);

    mark = try app_log.lineMark(alloc, log_path);
    try g.exec("execute('call setline(1, [\"alpha\", \"alphabet\", \"alpine\", \"\"]) | normal! G')");
    try g.exec("feedkeys(\"Aal\\<C-n>\", \"t\")");
    // Moved onto the external window's surface, then drawn by its popup.
    try app_log.waitAfter(alloc, log_path, "[panel_popup] popupmenu now on surface", mark, 5_000);
    try app_log.waitAfter(alloc, log_path, "[overlay] popupmenu", mark, 5_000);
    const pum = try g.evalInt("pumvisible()");

    // Closing the external window returns the popup to the main view.
    mark = try app_log.lineMark(alloc, log_path);
    try g.exec("feedkeys(\"\\<Esc>\", \"t\")");
    gui_io.sleepNs(300 * std.time.ns_per_ms);
    try g.exec("execute('close')");
    try app_log.waitAfter(alloc, log_path, "[panel_popup] popupmenu now on surface 1", mark, 5_000);
    const alive = try g.evalInt("1");
    std.debug.print("[gui] ext float panels: pumvisible={d}, alive after close={d}\n", .{ pum, alive });
    if (pum != 1) return error.PopupmenuNotShown;
}
