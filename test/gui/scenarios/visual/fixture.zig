// Shared setup for visual scenarios: launch the app against a fresh nvim
// with the determinism controls every pixel comparison needs (steady
// non-blinking cursor, fixed monospace font). Each scenario then sets up
// its rendering state, captures, and compares.

const std = @import("std");
const builtin = @import("builtin");
const gui_io = @import("../../gui_io.zig");
const driver = @import("../../driver.zig");
const Gui = driver.Gui;

// A monospace font that exists on the host OS, so cell metrics / glyph
// rasterization are stable within the environment.
pub const guifont = switch (builtin.os.tag) {
    .windows => "Consolas:h13",
    else => "Menlo:h13",
};

/// Skip the calling test unless this host can capture another process's
/// window. Every scenario that captures must call this (open() does it for
/// you): without it, a host lacking permission reports a hard failure from
/// deep inside captureStable instead of an honest skip.
///
/// Capturing needs Screen Recording permission on macOS (System Settings >
/// Privacy & Security > Screen Recording), granted to the terminal app that
/// spawns the test, not to the test binary.
pub fn requireScreenAccess() !void {
    if (!driver.capture.hasScreenAccess()) {
        std.debug.print("[gui] skipped: screen capture unavailable on this host\n", .{});
        return error.SkipZigTest;
    }
}

/// The app log a scenario gets when it does not ask for one of its own.
pub const default_log_path = "tmp/gui_app.log";

/// Launch the app ready for visual capture, or skip when screen capture is
/// unavailable. Caller owns the returned Gui (defer g.deinit()).
pub fn open(alloc: std.mem.Allocator) !*Gui {
    return openWithLog(alloc, default_log_path);
}

/// open(), with the app's `--log` pointed at `log_path`.
///
/// A scenario whose oracle READS that log needs its own path: the app opens
/// the file for append and stamps every line with its own start-relative
/// clock, so a log shared with other scenarios carries earlier processes'
/// lines at overlapping timestamps and any count taken from it spans more
/// than the run being measured.
pub fn openWithLog(alloc: std.mem.Allocator, log_path: []const u8) !*Gui {
    try requireScreenAccess();
    var g = try Gui.init(alloc, .{ .app_args = &.{ "--log", log_path } });
    errdefer g.deinit();
    // Pin the window to a fixed screen position so subpixel (ClearType)
    // rendering is identical run-to-run; the OS otherwise places the window
    // at varying positions, the top cross-run visual-flake source.
    driver.platform.pinWindow(g.app_pid, 80, 80);
    try g.exec("execute('set guicursor+=a:blinkon0')");
    try g.exec("execute('set guifont=" ++ guifont ++ "')");
    try waitStableGrid(g);
    return g;
}

/// Wait until the editor grid stops resizing.
///
/// Setting `guifont` above makes the app recompute cell metrics and push a
/// new grid size to nvim asynchronously. A scenario that lays windows out
/// before that lands captures a different geometry from run to run —
/// `:vsplit` halves the CURRENT width, so the divider ends up in a different
/// column depending on whether the resize won the race. captureStable cannot
/// save it: by then the split has already happened and the image is stable,
/// just stable at the wrong geometry.
fn waitStableGrid(g: *Gui) !void {
    const settle_polls = 3;
    var timer = gui_io.Timer.start();
    var last: i64 = -1;
    var same: u32 = 0;
    while (true) {
        if (timer.read() / std.time.ns_per_ms >= 15_000) return error.Timeout;
        const cols = g.evalInt("&columns") catch {
            gui_io.sleepNs(150 * std.time.ns_per_ms);
            continue;
        };
        if (cols == last) {
            same += 1;
            if (same >= settle_polls) return;
        } else {
            same = 0;
        }
        last = cols;
        gui_io.sleepNs(150 * std.time.ns_per_ms);
    }
}
