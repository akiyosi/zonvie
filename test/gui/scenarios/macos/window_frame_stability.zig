// window_frame_stability — regression test for 44705f8: with ext_tabline
// enabled the main window shrank a few rows of height on EVERY launch
// (default-guifont snap chained into user-guifont snap, compounded through
// the autosaved frame) until it hit the minimum size.
//
// The scenario runs with an isolated HOME (fresh NSUserDefaults / frame
// autosave), triggers a guifont metrics change like a real config does,
// then relaunches the app against the SAME nvim (guifont persists) and
// asserts the main window frame reproduces within tolerance.

const std = @import("std");
const driver = @import("../../driver.zig");
const platform = driver.platform;
const Gui = driver.Gui;

const home_dir = "tmp/gui_home_frame";
const settle_polls = 6; // bounds unchanged for 6 * 250 ms = stable
const tol_px = 10.0; // the bug lost whole rows (>= ~30 px) per launch

/// Poll until the main-window bounds stop changing, then return them.
fn waitStableBounds(g: *Gui) !platform.Bounds {
    var timer = std.time.Timer.start() catch unreachable;
    var last: ?platform.Bounds = null;
    var same: u32 = 0;
    while (true) {
        if (timer.read() / std.time.ns_per_ms >= 20_000) return error.Timeout;
        std.Thread.sleep(250 * std.time.ns_per_ms);
        const b = platform.mainWindowBoundsForPid(g.app_pid) orelse continue;
        if (last) |l| {
            if (l.x == b.x and l.y == b.y and l.w == b.w and l.h == b.h) {
                same += 1;
                if (same >= settle_polls) return b;
            } else {
                same = 0;
            }
        }
        last = b;
    }
}

pub fn run(alloc: std.mem.Allocator) !void {
    // Fresh defaults: no saved frame from previous runs (or the user).
    std.fs.cwd().deleteTree(home_dir) catch {};
    std.fs.cwd().makePath(home_dir) catch {};

    var g = try Gui.init(alloc, .{
        .app_args = &.{ "--exttabline", "--log", "tmp/gui_app.log" },
        .home_dir = home_dir,
    });
    defer g.deinit();

    // Trigger a cell-metrics change after the initial layout, like a user
    // guifont arriving after the built-in default (the bug's trigger).
    const out = try g.remoteExpr("execute('set guifont=Menlo:h13')");
    alloc.free(out);
    const b1 = try waitStableBounds(g);

    // Relaunch: nvim keeps 'guifont', the isolated defaults keep the
    // autosaved frame. The window must come back at the same size.
    try g.relaunchApp();
    const b2 = try waitStableBounds(g);

    if (@abs(b1.w - b2.w) > tol_px or @abs(b1.h - b2.h) > tol_px) {
        std.debug.print(
            "[gui] window frame drifted across relaunch: {d:.0}x{d:.0} -> {d:.0}x{d:.0}\n",
            .{ b1.w, b1.h, b2.w, b2.h },
        );
        return error.WindowFrameDrift;
    }
}
