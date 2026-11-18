// cmdline_popup_pointer — the ext cmdline is a popup surface of its own
// (linux/panel_popup.zig): a drag moves it and the next cmdline opens where
// it was left. Through the compositor's virtual pointer.
//
// Linux-only: linux/panel_popup.zig and linux/pointer.zig's panel drag.

const std = @import("std");
const driver = @import("../../driver.zig");
const platform = driver.platform;
const Gui = driver.Gui;
const app_log = @import("../../app_log.zig");
const gui_io = @import("../../gui_io.zig");

const log_path = "tmp/gui_cmdline_popup_pointer.log";

/// The last logged cmdline placement since `after`, on the screen in
/// logical px.
const Panel = struct { x: f64, y: f64, w: f64, h: f64 };

fn lastCmdline(alloc: std.mem.Allocator, b: platform.Bounds, after: usize) !Panel {
    const v = try app_log.viewInsets(alloc, log_path);
    const lines = try app_log.linesAfter(alloc, log_path, "[overlay] cmdline", after);
    defer alloc.free(lines);
    var it = std.mem.splitBackwardsScalar(u8, std.mem.trimEnd(u8, lines, "\n"), '\n');
    const line = it.next() orelse return error.NoCmdlinePanel;
    const f = struct {
        fn get(l: []const u8, k: []const u8) !f64 {
            return app_log.field(l, k) orelse error.NoCmdlinePanel;
        }
    };
    return .{
        .x = b.x + v.left + try f.get(line, "x") / v.scale,
        .y = b.y + v.top + try f.get(line, "y") / v.scale,
        .w = try f.get(line, "w") / v.scale,
        .h = try f.get(line, "h") / v.scale,
    };
}

pub fn run(alloc: std.mem.Allocator) !void {
    var ptr = platform.pointer() orelse {
        std.debug.print("[gui] skipped: no virtual pointer on this compositor\n", .{});
        return error.SkipZigTest;
    };
    defer ptr.deinit();

    std.Io.Dir.cwd().createDirPath(gui_io.io(), "tmp") catch {};
    std.Io.Dir.cwd().deleteFile(gui_io.io(), log_path) catch {};
    var g = try Gui.init(alloc, .{
        .app_args = &.{ "--extcmdline", "--log", log_path },
        .config_dir = "test/gui/fixtures/config_render_trace",
    });
    defer g.deinit();
    try app_log.waitFramesAfter(alloc, log_path, 1, 1, 0, 10_000);
    const b = g.mainWindowBounds() orelse return error.MainWindowNotFound;

    var mark = try app_log.lineMark(alloc, log_path);
    try g.remoteSend(":");
    try app_log.waitAfter(alloc, log_path, "[overlay] cmdline", mark, 5_000);
    const p = try lastCmdline(alloc, b, mark);

    // From the left part of the panel, clear of the copy button; straight
    // down, so the compositor has no reason to slide it.
    const from: [2]f64 = .{ p.x + p.w / 4, p.y + p.h / 2 };
    mark = try app_log.lineMark(alloc, log_path);
    // In 1-pt steps, as a real pointer moves: a popup's position is the
    // compositor's to apply, and the event in flight when it does may be
    // placed against the other one (panel_popup.zig onAfterPaint) -- an
    // error of one motion step, which coarse steps would magnify.
    ptr.drag(from, .{ from[0], from[1] + 120 }, 120);
    gui_io.sleepNs(300 * std.time.ns_per_ms);
    const moved = try lastCmdline(alloc, b, mark);
    std.debug.print("[gui] cmdline at ({d},{d}) -> ({d},{d})\n", .{ p.x, p.y, moved.x, moved.y });
    if (@abs(moved.x - p.x) > 2 or @abs(moved.y - (p.y + 120)) > 2) return error.CmdlineDidNotFollowDrag;

    try g.remoteSend("<Esc>");
    gui_io.sleepNs(200 * std.time.ns_per_ms);
    mark = try app_log.lineMark(alloc, log_path);
    try g.remoteSend(":");
    try app_log.waitAfter(alloc, log_path, "[overlay] cmdline", mark, 5_000);
    const again = try lastCmdline(alloc, b, mark);
    std.debug.print("[gui] reopened at ({d},{d})\n", .{ again.x, again.y });
    if (@abs(again.y - moved.y) > 2) return error.CmdlinePositionNotRemembered;
    try g.remoteSend("<Esc>");
}
