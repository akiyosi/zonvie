// mousescroll_ver — pin down what the 'ver' component of 'mousescroll' means,
// because the frontend's sub-cell scrolling books a wheel event as that many
// rows of travel and the docs described 'ver:0' wrongly.
//
// Three claims, all measured rather than assumed:
//   * the injected reporter publishes the option's value, and refreshes on
//     OptionSet
//   * a wheel event scrolls exactly 'ver' buffer lines
//   * 'ver:0' DISABLES mouse scrolling — it is not a page-relative setting

const std = @import("std");
const builtin = @import("builtin");
const Harness = @import("../harness.zig").Harness;

/// `200Gzt` puts line 200 at the top; topline is 0-based.
const PARK_TOP: u32 = 199;

pub fn run(alloc: std.mem.Allocator) !void {
    // setupMouseScrollReporter is compiled out off macOS, so mousescrollVer()
    // would just return its seeded default and the checks would be vacuous.
    if (comptime builtin.os.tag != .macos) return;

    var h = try Harness.init(alloc, .{});
    defer h.deinit();

    try h.command("set mouse=a");
    try h.command("call setline(1, map(range(1, 400), 'string(v:val)'))");
    const g = h.winGrid();

    try expectVer(h, 3); // Neovim's default

    try checkWheelMoves(h, g, 3);
    try setVer(h, 5);
    try checkWheelMoves(h, g, 5);
    try setVer(h, 1);
    try checkWheelMoves(h, g, 1);

    // 'ver:0': the reporter publishes 0 and Neovim ignores the event entirely.
    try setVer(h, 0);
    const parked = try park(h, g);
    h.wheel(g, "down");
    h.wheel(g, "down");
    // Nothing will arrive, so there is no scroll to synchronise on. The wheel
    // events and this command travel the same RPC channel in order, so once a
    // redraw for the command has been flushed the wheels have been processed.
    // The edit lands on the parked top line, so it forces a flush without
    // moving the view the assertion is about.
    const before_flushes = h.flush_seq.load(.seq_cst);
    try h.command("normal! ix\u{1b}");
    try h.command("undo");
    const Flushed = struct { from: u64 };
    try h.waitUntil(Flushed{ .from = before_flushes }, struct {
        fn check(c: Flushed, hh: *Harness) bool {
            return hh.flush_seq.load(.seq_cst) > c.from + 1;
        }
    }.check, h.opts.timeout_ms);
    if (h.getViewportTop(g) != parked) {
        std.debug.print(
            "[e2e] mousescroll_ver: 'ver:0' moved the view {d} lines; it should disable mouse scrolling\n",
            .{h.getViewportTop(g) - parked},
        );
        return error.VerZeroScrolled;
    }

    std.debug.print(
        "[e2e] mousescroll_ver: one wheel event scrolls 'ver' buffer lines; 'ver:0' disables scrolling\n",
        .{},
    );
}

fn setVer(h: *Harness, ver: u32) !void {
    var buf: [64]u8 = undefined;
    try h.command(try std.fmt.bufPrint(&buf, "set mousescroll=ver:{d},hor:6", .{ver}));
    try expectVer(h, ver);
}

/// The reporter answers on an OptionSet autocmd, so the value lands a moment
/// after the command returns.
fn expectVer(h: *Harness, want: u32) !void {
    const Ctx = struct { want: u32 };
    h.waitUntil(Ctx{ .want = want }, struct {
        fn check(c: Ctx, hh: *Harness) bool {
            return hh.mousescrollVer() == c.want;
        }
    }.check, h.opts.timeout_ms) catch {};
    if (h.mousescrollVer() != want) {
        std.debug.print(
            "[e2e] mousescroll_ver: reporter published {d}, expected {d}\n",
            .{ h.mousescrollVer(), want },
        );
        return error.VerMismatch;
    }
}

/// Park the view at a known line mid-buffer. Scrolling from the top of the
/// buffer is not stable: with the cursor on line 1 the wheel moves the view and
/// the next redraw pulls it back to keep the cursor visible. Mid-buffer there
/// are lines below to scroll onto, so Neovim moves the cursor down with the
/// view instead and the position holds.
fn park(h: *Harness, g: i64) !u32 {
    // zt pins topline to the cursor's line, so the parked position is an exact
    // number to wait for — waiting on a range would be satisfied instantly by
    // the previous check's leftover position.
    try h.command("normal! 200Gzt");
    try waitTopline(h, g, PARK_TOP);
    const top = h.getViewportTop(g);
    if (top != PARK_TOP) {
        std.debug.print(
            "[e2e] mousescroll_ver: parked at topline {d}, expected {d}\n",
            .{ top, PARK_TOP },
        );
        return error.ParkFailed;
    }
    return top;
}

/// One wheel event must move the view by exactly `ver` buffer lines.
fn checkWheelMoves(h: *Harness, g: i64, ver: u32) !void {
    const before = try park(h, g);
    h.wheel(g, "down");
    try waitTopline(h, g, before + ver);
    const moved = h.getViewportTop(g) - before;
    if (moved != ver) {
        std.debug.print(
            "[e2e] mousescroll_ver: ver={d} moved the view {d} lines\n",
            .{ ver, moved },
        );
        return error.WheelDistanceMismatch;
    }
}

fn waitTopline(h: *Harness, g: i64, want: u32) !void {
    const Ctx = struct { g: i64, want: u32 };
    h.waitUntil(Ctx{ .g = g, .want = want }, struct {
        fn check(c: Ctx, hh: *Harness) bool {
            return hh.getViewportTop(c.g) == c.want;
        }
    }.check, h.opts.timeout_ms) catch {};
}
