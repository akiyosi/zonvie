// scrollbar_pointer — the Linux scrollbar answers a real pointer: dragging
// the knob to the bottom scrolls the window there, and a press on the track
// above it pages back up. Driven through the compositor's virtual pointer.
//
// Linux-only: linux/scrollbar.zig's input path.

const std = @import("std");
const driver = @import("../../driver.zig");
const platform = driver.platform;
const Gui = driver.Gui;
const app_log = @import("../../app_log.zig");
const gui_io = @import("../../gui_io.zig");

const log_path = "tmp/gui_scrollbar_pointer.log";

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
        .config_dir = "test/gui/fixtures/config_scrollbar_always",
    });
    defer g.deinit();
    g.activateApp();
    try app_log.waitFramesAfter(alloc, log_path, 1, 1, 0, 10_000);

    try g.exec("execute('enew | call setline(1, map(range(1, 400), \"v:val\"))')");
    try g.exec("execute('normal! gg')");
    gui_io.sleepNs(500 * std.time.ns_per_ms);
    const b = g.mainWindowBounds() orelse return error.MainWindowNotFound;

    // The editor view sits inside the card's margin and padding
    // (frontend_rules.island_margin_pt + island_padding_pt), logical px.
    const card = 12;
    // The track's centre line, 2 + 6 logical px in from the view's right edge.
    const x = b.x + b.w - card - 8;
    // At line 1 the knob starts at the top of the track.
    ptr.drag(.{ x, b.y + card + 12 }, .{ x, b.y + b.h - card - 4 }, 12);
    gui_io.sleepNs(600 * std.time.ns_per_ms);
    const bottom = try g.evalInt("line('w0')");

    // The knob is at the bottom now: a press near the top is on the track
    // above it, which pages up.
    ptr.click(x, b.y + card + 20, @import("../../linux_pointer.zig").btn_left);
    gui_io.sleepNs(600 * std.time.ns_per_ms);
    const paged = try g.evalInt("line('w0')");

    std.debug.print("[gui] w0 after drag={d} after track press={d}\n", .{ bottom, paged });
    if (bottom < 300) return error.KnobDragDidNotScroll;
    if (paged >= bottom) return error.TrackPressDidNotPage;
}
