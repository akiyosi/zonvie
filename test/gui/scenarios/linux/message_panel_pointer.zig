// message_panel_pointer — the ext UI panels drawn in the main view own the
// pointer over them: hovering a message tells the core (its auto-hide
// holds), the wheel and a click over it never reach the buffer under it, a
// drag moves it, and msg_show's close badge dismisses it. Through the
// compositor's virtual pointer.
//
// Linux-only: linux/input.zig's panel hit test (overlay_layout.place).

const std = @import("std");
const driver = @import("../../driver.zig");
const platform = driver.platform;
const Gui = driver.Gui;
const app_log = @import("../../app_log.zig");
const gui_io = @import("../../gui_io.zig");
const btn_left = @import("../../linux_pointer.zig").btn_left;

const log_path = "tmp/gui_message_panel_pointer.log";

/// A msg_show placement from the log: surface px as logged, and where it is
/// on the screen in logical px.
const Panel = struct { dev_x: f64, dev_y: f64, x: f64, y: f64, w: f64, h: f64 };

fn lastPanel(alloc: std.mem.Allocator, b: platform.Bounds, after: usize) !Panel {
    const v = try app_log.viewInsets(alloc, log_path);
    const scale = v.scale;
    const lines = try app_log.linesAfter(alloc, log_path, "[overlay] msg_show", after);
    defer alloc.free(lines);
    var it = std.mem.splitBackwardsScalar(u8, std.mem.trimEnd(u8, lines, "\n"), '\n');
    const line = it.next() orelse return error.NoMsgShowPanel;
    const x = app_log.field(line, "x") orelse return error.NoMsgShowPanel;
    const y = app_log.field(line, "y") orelse return error.NoMsgShowPanel;
    const w = app_log.field(line, "w") orelse return error.NoMsgShowPanel;
    const h = app_log.field(line, "h") orelse return error.NoMsgShowPanel;
    return .{ .dev_x = x, .dev_y = y, .x = b.x + v.left + x / scale, .y = b.y + v.top + y / scale, .w = w / scale, .h = h / scale };
}

fn expr(g: *Gui, alloc: std.mem.Allocator, e: []const u8, want: []const u8) !bool {
    const got = try g.remoteExpr(e);
    defer alloc.free(got);
    std.debug.print("[gui] {s} = {s}\n", .{ e, std.mem.trim(u8, got, " \n") });
    return std.mem.eql(u8, std.mem.trim(u8, got, " \n"), want);
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
        .app_args = &.{ "--extmessages", "--log", log_path },
        .config_dir = "test/gui/fixtures/config_render_trace",
    });
    defer g.deinit();
    g.activateApp();
    try app_log.waitFramesAfter(alloc, log_path, 1, 1, 0, 10_000);
    const b = g.mainWindowBounds() orelse return error.MainWindowNotFound;

    try g.exec("execute('call setline(1, range(1, 300))')");
    // A plain message: its 4 s auto-hide is held while the pointer stays on
    // it, which the steps below rely on.
    var mark = try app_log.lineMark(alloc, log_path);
    try g.exec("nvim_echo([['panel pointer test message']], v:true, {})");
    try app_log.waitAfter(alloc, log_path, "[overlay] msg_show", mark, 5_000);
    const p = try lastPanel(alloc, b, mark);
    const mid: [2]f64 = .{ p.x + p.w / 2, p.y + p.h / 2 };

    mark = try app_log.lineMark(alloc, log_path);
    ptr.moveTo(mid[0], mid[1]);
    gui_io.sleepNs(100 * std.time.ns_per_ms);
    ptr.moveTo(mid[0] + 2, mid[1]);
    try app_log.waitAfter(alloc, log_path, "[msg_hover] surface=1 grid=-102", mark, 3_000);

    ptr.wheel(3);
    gui_io.sleepNs(400 * std.time.ns_per_ms);
    if (!try expr(g, alloc, "line('w0')", "1")) return error.WheelFellThroughPanel;

    ptr.click(mid[0], mid[1], btn_left);
    gui_io.sleepNs(300 * std.time.ns_per_ms);
    if (!try expr(g, alloc, "line('.')", "1")) return error.ClickFellThroughPanel;

    mark = try app_log.lineMark(alloc, log_path);
    // Straight down: the panel may span nearly the whole view's width.
    // In 1-pt steps, as a real pointer moves (see cmdline_popup_pointer.zig).
    ptr.drag(mid, .{ mid[0], mid[1] + 80 }, 80);
    gui_io.sleepNs(300 * std.time.ns_per_ms);
    const moved = try lastPanel(alloc, b, mark);
    std.debug.print("[gui] msg_show at ({d},{d}) -> ({d},{d})\n", .{ p.x, p.y, moved.x, moved.y });
    if (@abs(moved.x - p.x) > 2 or @abs(moved.y - (p.y + 80)) > 2) return error.PanelDidNotFollowDrag;

    // The close badge, 2 pt in from the moved panel's top-left, 13 pt square.
    const badge: [2]f64 = .{ moved.x + 2 + 6, moved.y + 2 + 6 };
    mark = try app_log.lineMark(alloc, log_path);
    ptr.moveTo(badge[0] + 1, badge[1]);
    gui_io.sleepNs(100 * std.time.ns_per_ms);
    ptr.click(badge[0], badge[1], btn_left);
    try app_log.waitAfter(alloc, log_path, "external window close grid=-102", mark, 3_000);
}
