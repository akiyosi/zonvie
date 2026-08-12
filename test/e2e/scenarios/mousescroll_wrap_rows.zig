// mousescroll_wrap_rows — 'mousescroll' counts buffer lines, grid_scroll counts
// screen rows, and on a 'wrap'ped buffer the two disagree by however many rows
// a line occupies.
//
// The trackpad lookahead books a wheel event as 'ver' rows of travel and used
// to cancel that booking against the rows grid_scroll reported, so a wrapped
// buffer credited it several times over and drove the offset past zero. This
// pins the disagreement down so the frontend's clamp has a measured premise.

const std = @import("std");
const Harness = @import("../harness.zig").Harness;

/// `200Gzt` puts line 200 at the top; topline is 0-based.
const PARK_TOP: u32 = 199;
const VER: u32 = 3;
/// The harness grid is 80x24 and each line's body is cols*3 + cols/2 characters
/// plus a short number prefix, so every line occupies exactly four screen rows.
const ROWS_PER_LINE: i64 = 4;

pub fn run(alloc: std.mem.Allocator) !void {
    var h = try Harness.init(alloc, .{});
    defer h.deinit();

    const g = h.winGrid();
    const size = h.subGridSize(g) orelse return error.GridNotFound;
    const line_len = @as(usize, size.cols) * 3 + size.cols / 2;

    const line = try alloc.alloc(u8, line_len);
    defer alloc.free(line);
    @memset(line, 'x');

    try h.command("set mouse=a wrap nosmoothscroll");
    var buf: [64]u8 = undefined;
    try h.command(try std.fmt.bufPrint(&buf, "set mousescroll=ver:{d},hor:6", .{VER}));

    var i: usize = 0;
    while (i < 400) : (i += 1) {
        const cmd = try std.fmt.allocPrint(alloc, "call setline({d}, '{d} {s}')", .{ i + 1, i + 1, line });
        defer alloc.free(cmd);
        try h.command(cmd);
    }

    try h.command("normal! 200Gzt");
    try waitTopline(h, g, PARK_TOP);
    if (h.getViewportTop(g) != PARK_TOP) return error.ParkFailed;
    _ = h.takeUncoveredScrollRows(g);
    _ = h.grid_scrolls.swap(0, .seq_cst);
    _ = h.grid_scroll_rows.swap(0, .seq_cst);

    h.wheel(g, "down");
    try waitTopline(h, g, PARK_TOP + VER);
    const notifications = h.grid_scrolls.load(.seq_cst);

    const seen = h.getViewportTopAndDelta(g);
    const lines_moved = seen.top - PARK_TOP;
    const rows_moved = seen.delta;
    if (lines_moved != VER) {
        std.debug.print(
            "[e2e] mousescroll_wrap_rows: one wheel event moved {d} buffer lines, expected {d}\n",
            .{ lines_moved, VER },
        );
        return error.WheelDistanceMismatch;
    }
    // The point of the scenario: the report is exactly ROWS_PER_LINE times the
    // booking. Asserting only "more than the booking" would still pass if the
    // units were half-reconciled somewhere.
    if (rows_moved != @as(i64, VER) * ROWS_PER_LINE) {
        std.debug.print(
            "[e2e] mousescroll_wrap_rows: {d} screen rows for {d} booked, expected {d}\n",
            .{ rows_moved, VER, @as(i64, VER) * ROWS_PER_LINE },
        );
        return error.RowsPerLineMismatch;
    }
    // How the movement is delivered decides whether the frontend can ever see
    // an arrival with its booking already exhausted: one notification for the
    // whole event can be clamped against the booking, but a second arrival for
    // the same gesture finds nothing left to clamp against.
    if (notifications != 1) {
        std.debug.print(
            "[e2e] mousescroll_wrap_rows: one wheel event produced {d} notifications\n",
            .{notifications},
        );
        return error.UnexpectedNotificationCount;
    }

    // Two events sent back to back, the way the lookahead sends them.
    try h.command("normal! 200Gzt");
    try waitTopline(h, g, PARK_TOP);
    _ = h.grid_scrolls.swap(0, .seq_cst);
    _ = h.grid_scroll_rows.swap(0, .seq_cst);
    h.wheel(g, "down");
    h.wheel(g, "down");
    // Waited on the reports, not on topline: the viewport is updated during
    // redraw while the notification is dispatched in the flush that follows, so
    // topline reaching its target does not mean the counters have caught up.
    const want_burst = 2 * @as(i64, VER) * ROWS_PER_LINE;
    const Ctx = struct { want: i64 };
    h.waitUntil(Ctx{ .want = want_burst }, struct {
        fn check(c: Ctx, hh: *Harness) bool {
            return hh.grid_scroll_rows.load(.seq_cst) >= c.want;
        }
    }.check, h.opts.timeout_ms) catch {};
    if (h.getViewportTop(g) != PARK_TOP + 2 * VER) return error.SecondWheelDidNotLand;
    const burst_notifications = h.grid_scrolls.load(.seq_cst);
    const burst_rows = h.grid_scroll_rows.load(.seq_cst);
    if (burst_rows != want_burst) {
        std.debug.print(
            "[e2e] mousescroll_wrap_rows: two wheel events moved {d} screen rows, expected {d}\n",
            .{ burst_rows, want_burst },
        );
        return error.BurstRowsMismatch;
    }

    std.debug.print(
        "[e2e] mousescroll_wrap_rows: one wheel event books {d} rows and moves {d} screen rows " ++
            "in {d} notification(s); two back to back arrive as {d} notification(s) totalling {d} rows\n",
        .{ VER, rows_moved, notifications, burst_notifications, burst_rows },
    );
}

fn waitTopline(h: *Harness, g: i64, want: u32) !void {
    const Ctx = struct { g: i64, want: u32 };
    h.waitUntil(Ctx{ .g = g, .want = want }, struct {
        fn check(c: Ctx, hh: *Harness) bool {
            return hh.getViewportTop(c.g) == c.want;
        }
    }.check, h.opts.timeout_ms) catch {};
}
