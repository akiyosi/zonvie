// wheel_scroll — regression test for 7b37537 (Windows): one physical wheel
// notch must map to exactly one Neovim wheel event. Before the fix the
// accumulator fired at WHEEL_DELTA/3, so a single notch sent 3 events and
// 'mousescroll' (3) scrolled 9 lines per notch instead of 3.
//
// This is the one Windows-specific fix in the recent batch that is testable
// without a pixel/screenshot layer: it lives in the frontend's real input
// path. We synthesize a WM_MOUSEWHEEL to the main window (so the actual
// wheel handler runs) and read the resulting viewport top line back from
// the shared nvim. The other Windows fixes in that batch (preedit z-order,
// tabline glyph clipping, externalized-split stale cursor, window icon,
// float double-cursor) are pixel/z-order regressions that need the
// not-yet-built screenshot layer.
//
// Windows-only; gated by the runner. Compile-verified from macOS but needs
// a real Windows run to confirm the wheel routing / coordinate handling.

const std = @import("std");
const driver = @import("../../driver.zig");
const platform = driver.platform;
const Gui = driver.Gui;

fn topLine(g: *Gui) !i64 {
    const out = try g.remoteExpr("line('w0')");
    defer g.alloc.free(out);
    const trimmed = std.mem.trim(u8, out, " \t\r\n");
    return std.fmt.parseInt(i64, trimmed, 10);
}

pub fn run(alloc: std.mem.Allocator) !void {
    var g = try Gui.init(alloc, .{});
    defer g.deinit();

    // Deterministic scroll amount: 3 lines per wheel event.
    {
        const o = try g.remoteExpr("execute('set mousescroll=ver:3')");
        alloc.free(o);
    }
    // A long buffer, parked at the top.
    {
        const o = try g.remoteExpr("setline(1, map(range(1, 200), 'string(v:val)'))");
        alloc.free(o);
    }
    {
        const o = try g.remoteExpr("execute('normal! gg')");
        alloc.free(o);
    }

    // Let the view settle at the top.
    var settle: u32 = 0;
    while (settle < 20) : (settle += 1) {
        if ((try topLine(g)) == 1) break;
        std.Thread.sleep(50 * std.time.ns_per_ms);
    }
    try std.testing.expectEqual(@as(i64, 1), try topLine(g));

    // Aim the wheel at the center of the main window (screen coords).
    const b = platform.mainWindowBoundsForPid(g.app_pid) orelse return error.NoMainWindow;
    const cx: i32 = @intFromFloat(b.x + b.w / 2);
    const cy: i32 = @intFromFloat(b.y + b.h / 2);

    // One notch down. Win32 convention: negative delta scrolls down.
    if (!platform.sendWheel(g.app_pid, -1, cx, cy)) return error.WheelSendFailed;

    // Wait for the viewport to move, then read how far.
    var moved: i64 = 0;
    var waited: u32 = 0;
    while (waited < 40) : (waited += 1) {
        moved = (try topLine(g)) - 1;
        if (moved > 0) break;
        std.Thread.sleep(50 * std.time.ns_per_ms);
    }

    // The fix: 1 notch -> 1 event -> mousescroll(3) lines. The regression
    // sent 3 events -> 9 lines. A tolerant upper bound cleanly separates
    // the two while allowing minor viewport rounding.
    if (moved <= 0) {
        std.debug.print("[gui] wheel notch produced no scroll (top still {d})\n", .{moved + 1});
        return error.WheelNoScroll;
    }
    if (moved > 5) {
        std.debug.print(
            "[gui] one wheel notch scrolled {d} lines (expected ~3; >5 indicates the 9-line regression)\n",
            .{moved},
        );
        return error.WheelOverScroll;
    }
}
