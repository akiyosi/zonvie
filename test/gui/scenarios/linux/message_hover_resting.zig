// message_hover_resting — a message panel that opens under a pointer that
// does not move holds its auto-hide (the hover is read again after every
// flush and on a popup's enter, as Windows seeds it when it creates a
// message window), and the hover is let go when the panel closes under that
// pointer. Through the compositor's virtual pointer.
//
// Linux-only: linux/pointer.zig refreshPanelHover / panelLeft.

const std = @import("std");
const driver = @import("../../driver.zig");
const platform = driver.platform;
const Gui = driver.Gui;
const app_log = @import("../../app_log.zig");
const gui_io = @import("../../gui_io.zig");

const log_path = "tmp/gui_message_hover_resting.log";

pub fn run(alloc: std.mem.Allocator) !void {
    var ptr = platform.pointer() orelse {
        std.debug.print("[gui] skipped: no virtual pointer on this compositor\n", .{});
        return error.SkipZigTest;
    };
    defer ptr.deinit();

    std.Io.Dir.cwd().createDirPath(gui_io.io(), "tmp") catch {};
    std.Io.Dir.cwd().deleteFile(gui_io.io(), log_path) catch {};
    var g = try Gui.init(alloc, .{
        .app_args = &.{ "--extmessages", "--log", log_path },
        .config_dir = "test/gui/fixtures/config_render_trace",
    });
    defer g.deinit();
    g.activateApp();
    try app_log.waitFramesAfter(alloc, log_path, 1, 1, 0, 10_000);
    const b = g.mainWindowBounds() orelse return error.MainWindowNotFound;
    const v = try app_log.viewInsets(alloc, log_path);

    // Off the panel's corner first, so the message below opens without the
    // pointer on it.
    ptr.moveTo(b.x + b.w / 2, b.y + b.h / 2);
    gui_io.sleepNs(200 * std.time.ns_per_ms);

    // The panel hangs 10 px in from the editor view's top-right corner;
    // a point 20 px inside that corner of it lies on any one-line message.
    const on_panel: [2]f64 = .{ b.x + b.w - v.right - 10 - 20, b.y + v.top + 10 + 12 };
    ptr.moveTo(on_panel[0], on_panel[1]);
    gui_io.sleepNs(300 * std.time.ns_per_ms);

    var mark = try app_log.lineMark(alloc, log_path);
    try g.exec("nvim_echo([['a message opening under a resting pointer']], v:true, {})");
    try app_log.waitAfter(alloc, log_path, "[overlay] msg_show", mark, 5_000);
    // No pointer motion from here on.
    try app_log.waitAfter(alloc, log_path, "[msg_hover] surface=1 grid=-102", mark, 3_000);
    std.debug.print("[gui] hover taken under a resting pointer\n", .{});

    // Past the 4 s auto-hide: the hover holds it.
    gui_io.sleepNs(5_000 * std.time.ns_per_ms);
    const closed = try app_log.linesAfter(alloc, log_path, "external window close grid=-102", mark);
    defer alloc.free(closed);
    if (closed.len != 0) return error.AutoHideNotHeld;

    // Closed under the resting pointer: the hover must go with it.
    mark = try app_log.lineMark(alloc, log_path);
    try g.exec("nvim_command('mode')");
    try app_log.waitAfter(alloc, log_path, "external window close grid=-102", mark, 3_000);
    try app_log.waitAfter(alloc, log_path, "[msg_hover] surface=1 grid=0", mark, 3_000);
    std.debug.print("[gui] hover let go as the panel closed\n", .{});
}
