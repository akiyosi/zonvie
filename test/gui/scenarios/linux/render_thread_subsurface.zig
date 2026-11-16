// render_thread_subsurface — with --renderer=thread on Wayland the render
// thread commits its frames to a subsurface of its own below the window:
// the editor shows the frame the thread drew, a later frame replaces it,
// and when the sidebar slides away the frames follow the editor into the
// space it leaves. Every buffer was one the compositor takes (a refused
// one would have sent the frames back through GTK).
//
// Linux-only: linux/render_thread.zig and linux/wl_dmabuf.c. Skipped where
// the thread draws no subsurface (X11, no buffer the compositor imports).
// The toggle click needs the band's start free of window buttons, as in
// sidebar_toggle_corner.

const std = @import("std");
const driver = @import("../../driver.zig");
const Gui = driver.Gui;
const app_log = @import("../../app_log.zig");
const gui_io = @import("../../gui_io.zig");
const btn_left = @import("../../linux_pointer.zig").btn_left;

const log_path = "tmp/gui_render_thread_subsurface.log";

/// The sidebar toggle in the band's corner, logical px from the window's
/// top-left (sidebar_toggle_corner).
const toggle_x = 16;
const toggle_y = 16;
/// chrome.slide_ms plus room for the frames to settle.
const slide_wait_ms = 900;
/// A point in the sidebar while it is open (it is 200 px wide), well
/// inside the editor once it has gone; logical px.
const probe_x = 100;
const probe_y = 300;

/// Exact but for rounding: the sidebar's ground is the editor's background
/// shifted in lightness, a few steps off it.
fn near(got: [3]u8, want: [3]u8) bool {
    for (got, want) |a, b| if (@abs(@as(i32, a) - b) > 4) return false;
    return true;
}

/// The window's pixel at logical (`x`, `y`) once the frame showing Normal's
/// background `colour` is on screen.
fn pixelAfter(g: *Gui, comptime colour: []const u8, x: u32, y: u32) ![3]u8 {
    const mark = try app_log.lineMark(g.alloc, log_path);
    try g.exec("execute('hi Normal guibg=" ++ colour ++ " | redraw!')");
    try app_log.waitFramesAfter(g.alloc, log_path, 1, 1, mark, 10_000);
    var img = try g.captureStable(null, 5_000);
    defer img.deinit(g.alloc);
    const b = g.mainWindowBounds() orelse return error.MainWindowNotFound;
    const scale: f64 = @as(f64, @floatFromInt(img.w)) / b.w;
    const px: usize = @intFromFloat(@as(f64, @floatFromInt(x)) * scale);
    const py: usize = @intFromFloat(@as(f64, @floatFromInt(y)) * scale);
    const i = (py * img.w + px) * 4;
    const got: [3]u8 = .{ img.rgba[i], img.rgba[i + 1], img.rgba[i + 2] };
    std.debug.print("[gui] {s} at {d},{d}: {d},{d},{d}\n", .{ colour, x, y, got[0], got[1], got[2] });
    return got;
}

pub fn run(alloc: std.mem.Allocator) !void {
    var ptr = driver.platform.pointer() orelse {
        std.debug.print("[gui] skipped: no virtual pointer on this compositor\n", .{});
        return error.SkipZigTest;
    };
    defer ptr.deinit();
    std.Io.Dir.cwd().createDirPath(gui_io.io(), "tmp") catch {};
    std.Io.Dir.cwd().deleteFile(gui_io.io(), log_path) catch {};
    var g = try Gui.init(alloc, .{
        .app_args = &.{ "--renderer=thread", "--log", log_path },
        .config_dir = "test/gui/fixtures/config_sidebar_cards",
    });
    defer g.deinit();
    g.activateApp();
    try app_log.waitFramesAfter(alloc, log_path, 1, 1, 0, 10_000);
    if (!try app_log.contains(alloc, log_path, "[render_thread] subsurface attached")) {
        std.debug.print("[gui] skipped: the render thread has no subsurface here\n", .{});
        return error.SkipZigTest;
    }
    try g.exec("execute('set guicursor=a:block-blinkon0')");
    gui_io.sleepNs(400 * std.time.ns_per_ms);

    // The editor's middle, right of the sidebar.
    const b = g.mainWindowBounds() orelse return error.MainWindowNotFound;
    const mid_x: u32 = @intFromFloat(200 + (b.w - 200) / 2);
    const mid_y: u32 = @intFromFloat(b.h / 2);
    if (!near(try pixelAfter(g, "#c00000", mid_x, mid_y), .{ 0xc0, 0, 0 })) return error.FrameNotOnScreen;
    if (!near(try pixelAfter(g, "#00a000", mid_x, mid_y), .{ 0, 0xa0, 0 })) return error.LaterFrameNotOnScreen;
    // The sidebar, on its ground: GTK's, not a frame's.
    if (near(try pixelAfter(g, "#00a000", probe_x, probe_y), .{ 0, 0xa0, 0 })) return error.FramesOverSidebar;

    ptr.click(b.x + toggle_x, b.y + toggle_y, btn_left);
    gui_io.sleepNs(slide_wait_ms * std.time.ns_per_ms);
    if (!near(try pixelAfter(g, "#0000c0", probe_x, probe_y), .{ 0, 0, 0xc0 })) return error.FramesDidNotFollowEditor;

    if (try app_log.contains(alloc, log_path, "cannot take a buffer")) return error.BufferRefused;
}
