// Shared setup for visual scenarios: launch the app against a fresh nvim
// with the determinism controls every pixel comparison needs (steady
// non-blinking cursor, fixed monospace font). Each scenario then sets up
// its rendering state, captures, and compares.

const std = @import("std");
const builtin = @import("builtin");
const driver = @import("../../driver.zig");
const Gui = driver.Gui;

// A monospace font that exists on the host OS, so cell metrics / glyph
// rasterization are stable within the environment.
pub const guifont = switch (builtin.os.tag) {
    .windows => "Consolas:h13",
    else => "Menlo:h13",
};

/// Run a remote-expr for its side effect, discarding the result.
pub fn exec(g: *Gui, expr: []const u8) !void {
    const o = try g.remoteExpr(expr);
    g.alloc.free(o);
}

/// Launch the app ready for visual capture, or skip when screen capture is
/// unavailable. Caller owns the returned Gui (defer g.deinit()).
pub fn open(alloc: std.mem.Allocator) !*Gui {
    // Capturing another process's window needs Screen Recording permission
    // on macOS (System Settings > Privacy & Security > Screen Recording).
    if (!driver.capture.hasScreenAccess()) {
        std.debug.print("[gui] skipped: screen capture unavailable on this host\n", .{});
        return error.SkipZigTest;
    }
    var g = try Gui.init(alloc, .{ .app_args = &.{ "--log", "tmp/gui_app.log" } });
    errdefer g.deinit();
    // Pin the window to a fixed screen position so subpixel (ClearType)
    // rendering is identical run-to-run; the OS otherwise places the window
    // at varying positions, the top cross-run visual-flake source.
    driver.platform.pinWindow(g.app_pid, 80, 80);
    try exec(g, "execute('set guicursor+=a:blinkon0')");
    try exec(g, "execute('set guifont=" ++ guifont ++ "')");
    return g;
}
