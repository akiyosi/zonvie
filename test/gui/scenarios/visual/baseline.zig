// visual/baseline — first scenario of the screenshot layer (Phase 2).
//
// Renders a fixed, deterministic buffer in the real frontend, captures the
// main window's actual pixels, and compares them to a per-OS golden. This
// is the visual-correctness pillar: it catches rendering regressions
// (glyph shaping, colors, layout) that the logical-grid and window-count
// layers cannot see.
//
// Determinism controls (without them pixel diffing is hopelessly flaky):
//   - steady (non-blinking) cursor, parked at a known cell
//   - fixed guifont so cell metrics / glyph rasterization are stable
//   - fixed buffer content
// The capture itself waits for two identical consecutive frames.
//
// Runs wherever driver.capture is supported (macOS today; Windows once the
// WIC capture path is built). On first run (or with ZONVIE_GUI_UPDATE_GOLDEN)
// the golden is created and the test passes.

const std = @import("std");
const driver = @import("../../driver.zig");
const visual = @import("../../visual.zig");
const Gui = driver.Gui;

fn exec(g: *Gui, expr: []const u8) !void {
    const o = try g.remoteExpr(expr);
    g.alloc.free(o);
}

pub fn run(alloc: std.mem.Allocator) !void {
    // Capturing another process's window needs Screen Recording permission
    // (System Settings > Privacy & Security > Screen Recording → grant it to
    // the terminal/host, then restart it). Skip cleanly when absent.
    if (!driver.capture.hasScreenAccess()) {
        std.debug.print("[gui] skipped: Screen Recording permission not granted to the host process\n", .{});
        return error.SkipZigTest;
    }

    var g = try Gui.init(alloc, .{ .app_args = &.{ "--log", "tmp/gui_app.log" } });
    defer g.deinit();

    // Steady cursor + fixed font for stable, repeatable pixels.
    try exec(g, "execute('set guicursor+=a:blinkon0')");
    try exec(g, "execute('set guifont=Menlo:h13')");
    // A fixed pattern: text, digits, and box-drawing glyphs.
    try exec(g,
        \\setline(1, ['Zonvie visual baseline', 'abcdefg 0123456789', '┌──────┐', '│ box  │', '└──────┘'])
    );
    try exec(g, "execute('normal! gg0')");

    // Fixed top-left crop: deterministic dimensions regardless of total
    // window-height jitter (text renders from the top-left).
    var img = try g.captureStable(.{ .w_pt = 600, .h_pt = 300 }, 8000);
    defer img.deinit(alloc);

    try visual.assertMatch(alloc, "baseline", img, .{});
}
