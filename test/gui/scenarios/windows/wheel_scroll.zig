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

/// Strip ANSI/VT escape sequences and control bytes in place, returning the
/// cleaned length. On Windows `nvim --server --remote-expr` wraps its output
/// in TUI control codes (ESC 7, ESC[?47h, ESC[H, ESC[J, ...); the actual
/// value is plain text in between. Without this, a digit scan grabs the '7'
/// of the leading "ESC 7" (DECSC) instead of the real value.
fn stripEscapes(buf: []u8) usize {
    var i: usize = 0;
    var n: usize = 0;
    while (i < buf.len) {
        const c = buf[i];
        if (c == 0x1b) { // ESC
            i += 1;
            if (i >= buf.len) break;
            const k = buf[i];
            if (k == '[') { // CSI: params then a final byte 0x40..0x7e
                i += 1;
                while (i < buf.len and !(buf[i] >= 0x40 and buf[i] <= 0x7e)) i += 1;
                if (i < buf.len) i += 1; // consume final byte
            } else if (k == ']') { // OSC: until BEL or ESC
                i += 1;
                while (i < buf.len and buf[i] != 0x07 and buf[i] != 0x1b) i += 1;
                if (i < buf.len and buf[i] == 0x07) i += 1;
            } else { // two-byte escape (ESC 7, ESC =, ...)
                i += 1;
            }
        } else if (c < 0x20) { // other control bytes (CR, LF, NUL, ...)
            i += 1;
        } else {
            buf[n] = c;
            n += 1;
            i += 1;
        }
    }
    return n;
}

/// Extract the first integer (optional '-' then digits) from a byte slice.
fn extractInt(out: []const u8) ?i64 {
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
    if (start) |s| return std.fmt.parseInt(i64, out[s..end], 10) catch null;
    return null;
}

/// Evaluate a remote-expr and parse its result as an integer, stripping the
/// TUI escape sequences that Windows nvim injects into the output.
fn evalInt(g: *Gui, expr: []const u8) !i64 {
    const out = try g.remoteExpr(expr);
    defer g.alloc.free(out);
    const clean = stripEscapes(out);
    return extractInt(out[0..clean]) orelse {
        std.debug.print("[gui] {s} returned no integer after strip; raw ({d} bytes)\n", .{ expr, out.len });
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
