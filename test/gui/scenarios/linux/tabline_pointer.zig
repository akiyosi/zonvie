// tabline_pointer — the Linux ext_tabline strip answers a real pointer: a
// click selects a tab, its × closes it, + opens one, and dragging the first
// tab past the last moves it there. Driven through the compositor's
// virtual pointer.
//
// Linux-only: linux/ui_widgets.zig's tab strip.

const std = @import("std");
const driver = @import("../../driver.zig");
const platform = driver.platform;
const Gui = driver.Gui;
const app_log = @import("../../app_log.zig");
const gui_io = @import("../../gui_io.zig");
const btn_left = @import("../../linux_pointer.zig").btn_left;

const log_path = "tmp/gui_tabline_pointer.log";

/// The new-tab button's width and the strip's height, logical px, near
/// enough for a click: the tabs share what is left of the width equally.
const plus_w = 34;
const strip_mid_y = 14;

pub fn run(alloc: std.mem.Allocator) !void {
    var ptr = platform.pointer() orelse {
        std.debug.print("[gui] skipped: no virtual pointer on this compositor\n", .{});
        return error.SkipZigTest;
    };
    defer ptr.deinit();

    std.Io.Dir.cwd().createDirPath(gui_io.io(), "tmp") catch {};
    std.Io.Dir.cwd().deleteFile(gui_io.io(), log_path) catch {};
    var g = try Gui.init(alloc, .{
        .app_args = &.{ "--log", log_path },
        .config_dir = "test/gui/fixtures/config_tabline",
    });
    defer g.deinit();
    g.activateApp();
    try app_log.waitFramesAfter(alloc, log_path, 1, 1, 0, 10_000);

    try g.exec("execute('silent! tabonly | enew | file one | tabnew | file two | tabnew | file three | 1tabnext')");
    gui_io.sleepNs(600 * std.time.ns_per_ms);
    const b = g.mainWindowBounds() orelse return error.MainWindowNotFound;
    const tab_w = (b.w - plus_w) / 3;
    const y = b.y + strip_mid_y;

    // A click on the second tab's name selects it.
    ptr.click(b.x + tab_w * 1.4, y, btn_left);
    gui_io.sleepNs(400 * std.time.ns_per_ms);
    const selected = try g.evalInt("tabpagenr()");

    // The third tab's close button, at its trailing edge.
    ptr.click(b.x + tab_w * 3 - 12, y, btn_left);
    gui_io.sleepNs(400 * std.time.ns_per_ms);
    const after_close = try g.evalInt("tabpagenr('$')");

    // +, past the last tab.
    ptr.click(b.x + b.w - plus_w / 2, y, btn_left);
    gui_io.sleepNs(400 * std.time.ns_per_ms);
    const after_new = try g.evalInt("tabpagenr('$')");

    // Three tabs again: drag the first ("one") past the last.
    const tab_w3 = (b.w - plus_w) / 3;
    ptr.drag(.{ b.x + tab_w3 * 0.4, y }, .{ b.x + tab_w3 * 2.9, y }, 10);
    gui_io.sleepNs(500 * std.time.ns_per_ms);
    const last_is_one = try g.evalInt("bufname(tabpagebuflist(tabpagenr('$'))[0]) ==# 'one'");

    std.debug.print("[gui] selected={d} after close={d} after new={d} one is last={d}\n", .{ selected, after_close, after_new, last_is_one });
    if (selected != 2) return error.TabClickDidNotSelect;
    if (after_close != 2) return error.CloseButtonDidNotClose;
    if (after_new != 3) return error.NewTabButtonDidNotOpen;
    if (last_is_one != 1) return error.TabDragDidNotMove;
}
