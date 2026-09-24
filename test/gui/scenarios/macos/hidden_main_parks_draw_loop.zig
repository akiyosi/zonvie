// hidden_main_parks_draw_loop — a minimized main window stops asking for
// frames once the flushes that woke it are over.
//
// Every flush activates the main draw loop, from whichever surface it came.
// The hidden path of GridSurfaceRenderer.draw returned before the idle count,
// so nothing parked the loop again: a background :terminal or a statusline
// timer while main was minimized left it waking at vsync until it was shown.
// The external surface has always parked itself there.
//
// Counted on the hidden path's own trace line, after the flushes stop.
//
// macOS-only: GridSurfaceRenderer is macOS frontend code.

const std = @import("std");
const driver = @import("../../driver.zig");
const platform = driver.platform;
const Gui = driver.Gui;
const app_log = @import("../../app_log.zig");
const gui_io = @import("../../gui_io.zig");

const log_path = "tmp/gui_hidden_main_parks.log";
const hidden_marker = "[dtrace] surface=1 gate=hidden";

fn countSince(alloc: std.mem.Allocator, since_ms: f64) !usize {
    const lines = try app_log.linesSince(alloc, log_path, hidden_marker, since_ms);
    defer alloc.free(lines);
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, lines, '\n');
    while (it.next()) |line| {
        if (line.len != 0) n += 1;
    }
    return n;
}

pub fn run(alloc: std.mem.Allocator) !void {
    if (!platform.accessibilityTrusted()) {
        std.debug.print("[gui] skipped: not trusted for Accessibility, cannot minimize the main window\n", .{});
        return error.SkipZigTest;
    }

    std.Io.Dir.cwd().createDirPath(gui_io.io(), "tmp") catch {};
    std.Io.Dir.cwd().deleteFile(gui_io.io(), log_path) catch {};

    var g = try Gui.init(alloc, .{
        .app_args = &.{ "--log", log_path },
        .config_dir = "test/gui/fixtures/config",
        .app_env = &.{.{ "ZONVIE_DRAW_TRACE", "1" }},
    });
    defer g.deinit();
    g.activateApp();
    gui_io.sleepNs(800 * std.time.ns_per_ms);
    const main_b = g.mainWindowBounds() orelse return error.MainWindowNotFound;

    if (!platform.setWindowMinimizedBySize(g.app_pid, main_b.w, main_b.h, true)) {
        return error.MinimizeFailed;
    }
    gui_io.sleepNs(1500 * std.time.ns_per_ms);

    // Flushes while hidden: each one wakes the loop.
    const t_flush = try app_log.nowMs(alloc, log_path);
    var i: usize = 0;
    while (i < 6) : (i += 1) {
        var buf: [96]u8 = undefined;
        const cmd = try std.fmt.bufPrint(&buf, "setline(1, 'hidden flush {d}')", .{i});
        try g.exec(cmd);
        gui_io.sleepNs(100 * std.time.ns_per_ms);
    }
    // Gate: the flushes did reach the hidden path, or nothing was exercised.
    gui_io.sleepNs(300 * std.time.ns_per_ms);
    const woken = try countSince(alloc, t_flush);

    const t_quiet = try app_log.nowMs(alloc, log_path);
    gui_io.sleepNs(2000 * std.time.ns_per_ms);
    const quiet = try countSince(alloc, t_quiet);

    _ = platform.setWindowMinimizedBySize(g.app_pid, main_b.w, main_b.h, false);

    std.debug.print("[gui] hidden main frames: during flushes={d} in 2s after={d}\n", .{ woken, quiet });
    if (woken == 0) return error.HiddenPathNotReached;
    if (quiet > 2) return error.HiddenMainKeptDrawing;
}
