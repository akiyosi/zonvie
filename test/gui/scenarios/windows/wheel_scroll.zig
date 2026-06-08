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
    // Robustly extract the integer: scan for an optional '-' then digits,
    // tolerating stray whitespace / CR / BOM that `--remote-expr` output
    // can carry on Windows. On no digits, dump the raw bytes for diagnosis.
    var start: ?usize = null;
    var end: usize = 0;
    for (out, 0..) |c, i| {
        const is_digit = c >= '0' and c <= '9';
        if (start == null and (is_digit or (c == '-' and i + 1 < out.len and out[i + 1] >= '0' and out[i + 1] <= '9'))) {
            start = i;
            end = i + 1;
        } else if (start != null and is_digit) {
            end = i + 1;
        } else if (start != null) {
            break;
        }
    }
    if (start) |s| return std.fmt.parseInt(i64, out[s..end], 10);
    std.debug.print("[gui] line('w0') returned no integer; raw ({d} bytes): \"{s}\"\n", .{ out.len, out });
    return error.NonNumericViewport;
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

    // Diagnostic: dump raw remote-expr output for a set of probes so the
    // actual values/format are visible on the connected nvim. Remove once
    // the wheel path is confirmed on real Windows.
    const probes = [_][]const u8{
        "string(1+1)",
        "string(line('$'))",
        "string(line('w0'))",
        "string(line('w$'))",
        "string(winheight(0))",
        "getline(1)",
        "string(mode())",
    };
    for (probes) |p| {
        const o = g.remoteExpr(p) catch |e| {
            std.debug.print("[gui] probe {s} => error {s}\n", .{ p, @errorName(e) });
            continue;
        };
        defer g.alloc.free(o);
        std.debug.print("[gui] probe {s} => ({d} bytes) text=\"{s}\" hex=", .{ p, o.len, o });
        for (o, 0..) |byte, idx| {
            if (idx >= 16) {
                std.debug.print("..", .{});
                break;
            }
            std.debug.print("{x:0>2} ", .{byte});
        }
        std.debug.print("\n", .{});
    }

    const last = blk: {
        const o = try g.remoteExpr("line('$')");
        defer g.alloc.free(o);
        break :blk std.fmt.parseInt(i64, std.mem.trim(u8, o, " \t\r\n"), 10) catch -1;
    };
    const base = try topLine(g);
    if (last != 200 or base < 1 or base > 10) {
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
