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

const query_file = "tmp/wheel_query.txt";

/// Evaluate `expr` on the server and return it as an integer.
///
/// Windows `nvim --server --remote-expr` writes a whole TUI frame (alt
/// screen + cursor moves) to stdout, so parsing stdout is hopeless there.
/// Instead have the SERVER write the value to a file via writefile() (a
/// side effect, like --remote-send, which is unaffected by the client's
/// TUI output) and read that file. Server and driver share the cwd
/// (repo root), so a relative path resolves to the same file.
fn evalInt(g: *Gui, expr: []const u8) !i64 {
    std.fs.cwd().deleteFile(query_file) catch {};
    const wexpr = try std.fmt.allocPrint(g.alloc, "writefile([string({s})], '{s}')", .{ expr, query_file });
    defer g.alloc.free(wexpr);
    const out = try g.remoteExpr(wexpr); // stdout discarded (TUI noise on Windows)
    g.alloc.free(out);

    const data = try std.fs.cwd().readFileAlloc(g.alloc, query_file, 4096);
    defer g.alloc.free(data);
    const trimmed = std.mem.trim(u8, data, " \t\r\n");
    return std.fmt.parseInt(i64, trimmed, 10) catch {
        std.debug.print("[gui] {s} wrote non-integer: \"{s}\"\n", .{ expr, trimmed });
        return error.NonNumericResult;
    };
}

fn topLine(g: *Gui) !i64 {
    return evalInt(g, "line('w0')");
}

pub fn run(alloc: std.mem.Allocator) !void {
    var g = try Gui.init(alloc, .{});
    defer g.deinit();

    // Deterministic scroll amount: 3 lines per wheel event.
    {
        const o = try g.remoteExpr("execute('set mousescroll=ver:3')");
        alloc.free(o);
    }
    // A long buffer (replace any existing content), parked at the top.
    {
        const o = try g.remoteExpr("execute('silent! %delete _')");
        alloc.free(o);
    }
    {
        const o = try g.remoteExpr("setline(1, map(range(1, 200), 'string(v:val)'))");
        alloc.free(o);
    }
    {
        const o = try g.remoteExpr("execute('normal! gg')");
        alloc.free(o);
    }

    const last = try evalInt(g, "line('$')");
    const base = try topLine(g);
    if (last != 200 or base < 1 or base > 20) {
        std.debug.print("[gui] wheel_scroll unexpected state: line('$')={d} top={d} (expected $=200, top near 1)\n", .{ last, base });
        return error.UnexpectedBufferState;
    }

    // Aim the wheel at the center of the main window (screen coords).
    const b = platform.mainWindowBoundsForPid(g.app_pid) orelse return error.NoMainWindow;
    const cx: i32 = @intFromFloat(b.x + b.w / 2);
    const cy: i32 = @intFromFloat(b.y + b.h / 2);

    // One notch down. Win32 convention: negative delta scrolls down.
    if (!platform.sendWheel(g.app_pid, -1, cx, cy)) return error.WheelSendFailed;

    // Wait for the viewport to move, then read how far (from the measured
    // baseline, not an assumed top-of-1).
    var moved: i64 = 0;
    var waited: u32 = 0;
    while (waited < 40) : (waited += 1) {
        moved = (try topLine(g)) - base;
        if (moved > 0) break;
        std.Thread.sleep(50 * std.time.ns_per_ms);
    }

    // The fix: 1 notch -> 1 event -> mousescroll(3) lines. The regression
    // sent 3 events -> 9 lines. A tolerant upper bound cleanly separates
    // the two while allowing minor viewport rounding.
    if (moved <= 0) {
        std.debug.print("[gui] wheel notch produced no scroll (top still {d})\n", .{base});
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
