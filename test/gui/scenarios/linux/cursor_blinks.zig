// cursor_blinks — guicursor's blink cadence reaches the Linux frontend: a
// blinking mode toggles the cursor, and `blinkon0` stops it with the cursor
// shown. Counted on the blink timer's own log line.
//
// Linux-only: the timer and its log line are linux/blink.zig's.

const std = @import("std");
const driver = @import("../../driver.zig");
const Gui = driver.Gui;
const app_log = @import("../../app_log.zig");
const gui_io = @import("../../gui_io.zig");

const log_path = "tmp/gui_cursor_blinks.log";
const toggle_marker = "[blink] toggled to ";

pub fn run(alloc: std.mem.Allocator) !void {
    std.Io.Dir.cwd().createDirPath(gui_io.io(), "tmp") catch {};
    std.Io.Dir.cwd().deleteFile(gui_io.io(), log_path) catch {};

    var g = try Gui.init(alloc, .{
        .app_args = &.{ "--log", log_path },
        .config_dir = "test/gui/fixtures/config_render_trace",
    });
    defer g.deinit();
    g.activateApp();
    try app_log.waitFramesAfter(alloc, log_path, 1, 1, 0, 10_000);

    try g.exec("execute('set guicursor=a:block-blinkwait100-blinkon200-blinkoff200')");
    const t_blink = try app_log.nowMs(alloc, log_path);
    gui_io.sleepNs(1500 * std.time.ns_per_ms);
    const toggles = try app_log.countLinesSince(alloc, log_path, toggle_marker, t_blink);

    try g.exec("execute('set guicursor=a:block-blinkon0')");
    gui_io.sleepNs(300 * std.time.ns_per_ms);
    const t_steady = try app_log.nowMs(alloc, log_path);
    gui_io.sleepNs(1000 * std.time.ns_per_ms);
    const after = try app_log.countLinesSince(alloc, log_path, toggle_marker, t_steady);
    const last = try app_log.lastLineSince(alloc, log_path, toggle_marker, t_blink);
    defer if (last) |l| alloc.free(l);

    std.debug.print("[gui] blink toggles blinking={d} after blinkon0={d}\n", .{ toggles, after });
    if (toggles < 4) return error.CursorDidNotBlink;
    if (after != 0) return error.BlinkDidNotStop;
    const l = last orelse return error.CursorDidNotBlink;
    if (std.mem.indexOf(u8, l, "toggled to true") == null) return error.StoppedWithCursorHidden;
}
