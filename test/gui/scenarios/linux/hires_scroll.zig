// hires_scroll — fractional scroll events (smooth axis values from the
// compositor's virtual pointer, which GTK reports as fractions of a wheel
// step) gather into whole steps that scroll the buffer, and a scroll past the
// top leaves line 1 in place. A compositor that forwards the finger source
// (Hyprland's virtual pointer does not) makes these touchpad events instead,
// which linux/trackpad.zig pixel-scrolls; its model is unit-tested in
// linux/pixel_scroll.zig.
//
// Linux-only: linux/input.zig onScroll and linux/pixel_scroll.zig takeSteps.

const std = @import("std");
const driver = @import("../../driver.zig");
const platform = driver.platform;
const app_log = @import("../../app_log.zig");
const gui_io = @import("../../gui_io.zig");

const log_path = "tmp/gui_hires_scroll.log";

pub fn run(alloc: std.mem.Allocator) !void {
    var ptr = platform.pointer() orelse {
        std.debug.print("[gui] skipped: no virtual pointer on this compositor\n", .{});
        return error.SkipZigTest;
    };
    defer ptr.deinit();

    std.Io.Dir.cwd().createDirPath(gui_io.io(), "tmp") catch {};
    std.Io.Dir.cwd().deleteFile(gui_io.io(), log_path) catch {};
    var g = try driver.Gui.init(alloc, .{
        .app_args = &.{ "--log", log_path },
        .config_dir = "test/gui/fixtures/config",
    });
    defer g.deinit();
    g.activateApp();
    try app_log.waitFramesAfter(alloc, log_path, 1, 1, 0, 10_000);

    try g.exec("execute('enew | call setline(1, map(range(1, 600), \"v:val\"))')");
    try g.exec("execute('normal! gg')");
    gui_io.sleepNs(500 * std.time.ns_per_ms);
    const b = g.mainWindowBounds() orelse return error.MainWindowNotFound;
    const v = try app_log.viewInsets(alloc, log_path);
    ptr.moveTo(b.x + v.left + (b.w - v.left - v.right) / 2, b.y + v.top + (b.h - v.top - v.bottom) / 2);
    gui_io.sleepNs(150 * std.time.ns_per_ms);

    // Small fractional steps: none scrolls alone, together they do.
    ptr.swipe(300, 30, 16);
    gui_io.sleepNs(800 * std.time.ns_per_ms);
    const after = try g.evalInt("line('w0')");

    // Back to the top and past it: line 1 stays the top line.
    try g.exec("execute('normal! gg')");
    gui_io.sleepNs(300 * std.time.ns_per_ms);
    ptr.swipe(-400, 20, 16);
    gui_io.sleepNs(1000 * std.time.ns_per_ms);
    const past_top = try g.evalInt("line('w0')");

    std.debug.print("[gui] hires scroll: w0 1->{d}, past top={d}\n", .{ after, past_top });
    if (after <= 1) return error.FractionalStepsDidNotScroll;
    if (past_top != 1) return error.ScrollPastTopMoved;
}
