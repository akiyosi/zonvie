// blink_survives_popupmenu — editing in an external window with the main
// window minimized, the cursor keeps blinking after an external popupmenu has
// come and gone.
//
// Creating any external window recorded its grid as the cursor's grid, the
// popupmenu included, although Neovim's cursor never moves onto it and so the
// core never reports a grid change to correct it. Once the menu closed, the
// blink gate resolved that grid to "no external view, so the main window",
// and a minimized main window refused the timer: the cursor stayed solid in
// the window being edited until it next changed grid.
//
// The timer consults the gate only when it is (re)armed, so the per-mode
// blink values make `<Esc>` re-arm it after the menu closes, as a user's real
// guicursor does. `noshowmode` keeps the cursor off the message grid, whose
// round trip would otherwise report a grid change that masks the defect.
// Counted on the blink timer's own log line.
//
// macOS-only: the blink gate is ZonvieCore's.

const std = @import("std");
const driver = @import("../../driver.zig");
const platform = driver.platform;
const Gui = driver.Gui;
const app_log = @import("../../app_log.zig");
const gui_io = @import("../../gui_io.zig");

const log_path = "tmp/gui_blink_popupmenu.log";
/// Any surface's completed frame.
const frame_marker = "[trace] event=frame_done";
const toggle_marker = "[blink] blink toggled to ";

pub fn run(alloc: std.mem.Allocator) !void {
    if (!platform.accessibilityTrusted()) {
        std.debug.print("[gui] skipped: not trusted for Accessibility, cannot minimize the main window\n", .{});
        return error.SkipZigTest;
    }

    std.Io.Dir.cwd().createDirPath(gui_io.io(), "tmp") catch {};
    std.Io.Dir.cwd().deleteFile(gui_io.io(), log_path) catch {};

    var g = try Gui.init(alloc, .{
        .app_args = &.{ "--extpopup", "--log", log_path },
        .config_dir = "test/gui/fixtures/config_render_trace",
    });
    defer g.deinit();
    g.activateApp();
    try app_log.waitFramesAfter(alloc, log_path, 1, 1, 0, 10_000);
    const main_b = g.mainWindowBounds() orelse return error.MainWindowNotFound;
    const base_windows = g.windowCount();

    try g.exec("execute('set nocursorline noshowmode guicursor=n:block-blinkwait200-blinkon250-blinkoff250,i:ver25-blinkwait200-blinkon300-blinkoff300')");
    const ext_mark = try app_log.lineMark(alloc, log_path);
    try g.exec(
        "luaeval('(function() local b = vim.api.nvim_create_buf(false, true) " ++
            "vim.api.nvim_buf_set_lines(b, 0, -1, false, {\"alpha alphabet alpine\", \"\"}) " ++
            "vim.api.nvim_open_win(b, true, {external=true, width=60, height=10}) return 1 end)()')",
    );
    try g.waitWindowCount(base_windows + 1, 10_000);
    try app_log.waitAfter(alloc, log_path, frame_marker, ext_mark, 10_000);

    if (!platform.setWindowMinimizedBySize(g.app_pid, main_b.w, main_b.h, true)) {
        return error.MinimizeFailed;
    }
    gui_io.sleepNs(1500 * std.time.ns_per_ms);
    const ext_windows = g.windowCount();

    // Gate: the cursor blinks in the external window with main minimized.
    try g.remoteSend("<Esc>");
    const t_before = try app_log.nowMs(alloc, log_path);
    gui_io.sleepNs(1500 * std.time.ns_per_ms);
    const before = try app_log.countLinesSince(alloc, log_path, toggle_marker, t_before);

    // Insert-mode completion opens the external popupmenu; the cursor stays
    // on the float's grid throughout.
    try g.exec("setline(2, '')");
    const menu_mark = try app_log.lineMark(alloc, log_path);
    try g.remoteSend("2Gial<C-n>");
    try g.waitWindowCount(ext_windows + 1, 10_000);
    try app_log.waitAfter(alloc, log_path, frame_marker, menu_mark, 10_000);
    const close_mark = try app_log.lineMark(alloc, log_path);
    try g.remoteSend("<C-e><Esc>");
    try g.waitWindowCount(ext_windows, 10_000);
    try app_log.waitAfter(alloc, log_path, frame_marker, close_mark, 10_000);

    const t_after = try app_log.nowMs(alloc, log_path);
    gui_io.sleepNs(2000 * std.time.ns_per_ms);
    const after = try app_log.countLinesSince(alloc, log_path, toggle_marker, t_after);

    _ = platform.setWindowMinimizedBySize(g.app_pid, main_b.w, main_b.h, false);

    std.debug.print("[gui] blink toggles before menu={d} after menu closed={d}\n", .{ before, after });
    if (before < 2) return error.CursorDidNotBlinkBeforeMenu;
    if (after < 2) return error.BlinkStoppedAfterPopupmenu;
}
