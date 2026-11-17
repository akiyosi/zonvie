// native_titlebar_fallback — titlebar_style = "native" on a desktop that
// draws no titlebar (Hyprland) takes "hidden"'s chrome: no rail and no card,
// the editor at the window top. A pointer resting in the top band reveals
// the drag bar, the window buttons and the sidebar toggle together after
// DragBar.reveal_ms, as on macOS and Windows: top right, or top left with a
// right sidebar so they stay clear of it. Before that the toggle's spot
// takes no click; after it the toggle closes the sidebar.
//
// Linux-only: linux/chrome.zig effectiveStyle and its captionless reveal. Skipped
// where the desktop draws a titlebar, which keeps "native".

const std = @import("std");
const driver = @import("../../driver.zig");
const platform = driver.platform;
const Gui = driver.Gui;
const app_log = @import("../../app_log.zig");
const gui_io = @import("../../gui_io.zig");
const pointer_mod = @import("../../linux_pointer.zig");
const btn_left = pointer_mod.btn_left;
/// src/core/frontend_rules.zig DragBar.reveal_ms, macOS and Windows alike.
const reveal_ms = 2000;

const log_path = "tmp/gui_native_titlebar_fallback.log";
/// The toggle's centre, logical px from the window edge the buttons sit
/// at: past the close and menu buttons, in a band chrome.band_pt high.
const toggle_from_edge = 105;
const toggle_y = 18;
const sidebar_w = 200;

const Case = struct { config_dir: []const u8, right: bool };

pub fn run(alloc: std.mem.Allocator) !void {
    const desktop = if (std.c.getenv("XDG_CURRENT_DESKTOP")) |v| std.mem.span(v) else "";
    if (std.mem.indexOf(u8, desktop, "Hyprland") == null) {
        std.debug.print("[gui] skipped: the desktop may draw a titlebar\n", .{});
        return error.SkipZigTest;
    }
    var ptr = platform.pointer() orelse {
        std.debug.print("[gui] skipped: no virtual pointer on this compositor\n", .{});
        return error.SkipZigTest;
    };
    defer ptr.deinit();
    for ([_]Case{
        .{ .config_dir = "test/gui/fixtures/config_native_sidebar", .right = false },
        .{ .config_dir = "test/gui/fixtures/config_native_sidebar_right", .right = true },
    }) |case| try runCase(alloc, &ptr, case);
}

fn runCase(alloc: std.mem.Allocator, ptr: *pointer_mod.Pointer, case: Case) !void {
    std.Io.Dir.cwd().createDirPath(gui_io.io(), "tmp") catch {};
    std.Io.Dir.cwd().deleteFile(gui_io.io(), log_path) catch {};
    var g = try Gui.init(alloc, .{
        .app_args = &.{ "--log", log_path },
        .config_dir = case.config_dir,
    });
    defer g.deinit();
    g.activateApp();
    try app_log.waitFramesAfter(alloc, log_path, 1, 1, 0, 10_000);
    gui_io.sleepNs(400 * std.time.ns_per_ms);

    const b = g.mainWindowBounds() orelse return error.MainWindowNotFound;
    const view = try app_log.viewInsets(alloc, log_path);

    const toggle_x = if (case.right) b.x + toggle_from_edge else b.x + b.w - toggle_from_edge;
    // Below the band, then onto the toggle's spot. A click there before the
    // rest finds no button (and, held, cancels the rest).
    ptr.moveTo(toggle_x, b.y + 60);
    gui_io.sleepNs(200 * std.time.ns_per_ms);
    ptr.click(toggle_x, b.y + toggle_y, btn_left);
    gui_io.sleepNs(900 * std.time.ns_per_ms);
    const early = try app_log.viewInsets(alloc, log_path);

    // Out of the band, which ends the rest the click began, and back in:
    // the buttons come with the bar.
    ptr.moveTo(toggle_x, b.y + 60);
    gui_io.sleepNs(200 * std.time.ns_per_ms);
    const since = try app_log.nowMs(alloc, log_path);
    const timer = gui_io.Timer.start();
    ptr.moveTo(toggle_x, b.y + toggle_y);
    try app_log.waitForSince(alloc, log_path, "[drag_bar] revealed=true", since, reveal_ms + 2000);
    const rest_ms = timer.read() / std.time.ns_per_ms;
    gui_io.sleepNs(300 * std.time.ns_per_ms); // the 150 ms fade-in
    ptr.click(toggle_x, b.y + toggle_y, btn_left);
    gui_io.sleepNs(900 * std.time.ns_per_ms);
    const closed = try app_log.viewInsets(alloc, log_path);

    const side_open = if (case.right) view.right else view.left;
    const side_early = if (case.right) early.right else early.left;
    const side_closed = if (case.right) closed.right else closed.left;
    std.debug.print("[gui] {s} sidebar: view left={d} right={d} top={d}; early click side={d}; bar and buttons after {d} ms; after the toggle side={d}\n", .{ if (case.right) "right" else "left", view.left, view.right, view.top, side_early, rest_ms, side_closed });
    // No band or card margin above the editor, the sidebar alone beside it.
    if (view.top > 1) return error.EditorNotAtWindowTop;
    if (side_open < sidebar_w or side_open > sidebar_w + 10) return error.SidebarRailOrCardPresent;
    if (@abs(side_early - side_open) > 1) return error.HiddenToggleTookClick;
    if (rest_ms + 100 < reveal_ms or rest_ms > reveal_ms + 600) return error.DragBarDelayNotRevealMs;
    if (side_closed > 10) return error.RevealedToggleDidNotClose;
}
