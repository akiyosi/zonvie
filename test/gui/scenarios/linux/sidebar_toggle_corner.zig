// sidebar_toggle_corner — with titlebar_style = "unified" the title band
// spans the window and the sidebar's toggle sits in its corner, beside the
// window buttons (as macOS's titlebar holds it): one click slides the
// sidebar away, and a second click on the same spot brings it back, the
// toggle not having moved with the sidebar.
//
// Linux-only: linux/chrome.zig's title band. The click lands on the band's
// first button: the window buttons are drawn at the band's end.

const std = @import("std");
const driver = @import("../../driver.zig");
const platform = driver.platform;
const Gui = driver.Gui;
const app_log = @import("../../app_log.zig");
const gui_io = @import("../../gui_io.zig");
const btn_left = @import("../../linux_pointer.zig").btn_left;

const log_path = "tmp/gui_sidebar_toggle_corner.log";

/// The toggle's centre from the window's top-left, logical px: inside the
/// first button of a band chrome.band_pt (32) high.
const toggle_x = 16;
const toggle_y = 16;
/// chrome.slide_ms plus room for the grid to settle.
const slide_wait_ms = 900;

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
        .config_dir = "test/gui/fixtures/config_sidebar_cards",
    });
    defer g.deinit();
    g.activateApp();
    try app_log.waitFramesAfter(alloc, log_path, 1, 1, 0, 10_000);
    gui_io.sleepNs(400 * std.time.ns_per_ms);

    const b = g.mainWindowBounds() orelse return error.MainWindowNotFound;
    const open = try app_log.viewInsets(alloc, log_path);

    ptr.click(b.x + toggle_x, b.y + toggle_y, btn_left);
    gui_io.sleepNs(slide_wait_ms * std.time.ns_per_ms);
    const closed = try app_log.viewInsets(alloc, log_path);

    ptr.click(b.x + toggle_x, b.y + toggle_y, btn_left);
    gui_io.sleepNs(slide_wait_ms * std.time.ns_per_ms);
    const reopened = try app_log.viewInsets(alloc, log_path);

    std.debug.print("[gui] view left: open={d} closed={d} reopened={d}; top: open={d} closed={d}\n", .{ open.left, closed.left, reopened.left, open.top, closed.top });
    // The fixture's sidebar is 200 px wide.
    if (open.left < 200) return error.SidebarNotOpenAtStart;
    if (closed.left > open.left - 150) return error.ToggleDidNotCloseSidebar;
    if (@abs(reopened.left - open.left) > 1) return error.ToggleDidNotReopenSidebar;
    // The band stays over the editor while the sidebar is away.
    if (@abs(closed.top - open.top) > 1) return error.BandMovedWithSidebar;
}
