// visual/extwin_main_resize_matches_full — the main window shrunk by an
// external window opening must show a frame of its new size.
//
// Reported by hand: with `nvim -u NONE`'s intro screen, <C-w>v<C-w>ge left
// the main window squashed until a key was pressed. The compositor tiled the
// main window smaller as the external window mapped; the frame drawn for the
// new size went into a back buffer EGL had taken at the old size (a resize
// applies to buffers taken after it), the compositor scaled that buffer to
// the window, and the frame after it planned nothing to draw: the intro
// screen changes no row. The oracle is a whole frame of the same state
// (ZONVIE_TEST_FULL_REDRAW): the window on screen must match it.

const std = @import("std");
const fixture = @import("fixture.zig");
const visual = @import("../../visual.zig");
const app_log = @import("../../app_log.zig");
const driver = @import("../../driver.zig");
const gui_io = @import("../../gui_io.zig");

const log_path = "tmp/gui_extwin_main_resize_matches_full.log";
const full_frame_marker = "[trace] event=full_frame_done";

pub fn run(alloc: std.mem.Allocator) !void {
    try fixture.requireScreenAccess();
    std.Io.Dir.cwd().deleteFile(gui_io.io(), log_path) catch {};
    var g = try fixture.openWithLogConfigAndEnv(alloc, log_path, "test/gui/fixtures/config", &.{
        .{ "ZONVIE_TEST_FULL_REDRAW", "1" },
    });
    defer g.deinit();
    try app_log.waitFramesAfter(alloc, log_path, 1, 2, 0, 10_000);
    gui_io.sleepNs(500 * std.time.ns_per_ms);

    // A split made external, on the intro screen, as by hand.
    const before = driver.snapshotWindows(g.app_pid);
    try g.remoteSend("<C-w>v<C-w>ge");
    _ = try driver.waitNewWindow(g.app_pid, before.slice(), 100);
    // The tiling compositor's resize and its animation, then nothing else.
    gui_io.sleepNs(1500 * std.time.ns_per_ms);
    var shown = try driver.capture.captureMainWindow(alloc, g.app_pid, null);
    defer shown.deinit(alloc);
    driver.capture.writeImage(alloc, "tmp/extwin_main_resize_shown" ++ driver.capture.image_ext, shown) catch {};

    const forced = try app_log.nowMs(alloc, log_path);
    driver.platform.forceFullRedraw(g.app_pid);
    try app_log.waitForSince(alloc, log_path, full_frame_marker, forced, 5000);
    gui_io.sleepNs(300 * std.time.ns_per_ms);
    var full = try driver.capture.captureMainWindow(alloc, g.app_pid, null);
    defer full.deinit(alloc);
    driver.capture.writeImage(alloc, "tmp/extwin_main_resize_full" ++ driver.capture.image_ext, full) catch {};

    try visual.assertRegionUnchanged(alloc, "extwin_main_resize_matches_full", shown, full, .{}, .{
        .tol_per_channel = 2,
        .max_diff_ratio = 0.001,
    });
}
