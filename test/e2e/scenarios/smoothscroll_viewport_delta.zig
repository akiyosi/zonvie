// smoothscroll_viewport_delta — a 'smoothscroll' window reports its movement
// only through win_viewport, so the trackpad lookahead has no grid_scroll to
// cancel its held pixel offset against. The core folds win_viewport's
// scroll_delta (which counts screen rows) against the rows grid_scroll
// described and leaves the remainder for the frontend to consume.
//
// Long wrapped lines separate the two units: under 'smoothscroll' one <C-e>
// advances a single screen row while topline only moves once per wrapped line.

const std = @import("std");
const Harness = @import("../harness.zig").Harness;

pub fn run(alloc: std.mem.Allocator) !void {
    var h = try Harness.init(alloc, .{});
    defer h.deinit();

    const g = h.winGrid();
    const size = h.subGridSize(g) orelse return error.GridNotFound;
    // Each buffer line wraps over several screen rows.
    const line_len = @as(usize, size.cols) * 3 + size.cols / 2;

    const line = try alloc.alloc(u8, line_len);
    defer alloc.free(line);
    @memset(line, 'x');

    try h.command("set wrap smoothscroll");
    var i: usize = 0;
    while (i < 40) : (i += 1) {
        const cmd = try std.fmt.allocPrint(alloc, "call setline({d}, '{d} {s}')", .{ i + 1, i + 1, line });
        defer alloc.free(cmd);
        try h.command(cmd);
    }
    try h.command("normal! gg");
    try h.waitUntil({}, struct {
        fn check(_: void, hh: *Harness) bool {
            return hh.cellAt(hh.winGrid(), 0, 0).cp == '1';
        }
    }.check, h.opts.timeout_ms);
    _ = h.takeUncoveredScrollRows(g);

    // 'smoothscroll': no grid_scroll, so every screen row the view moves is
    // left uncovered. topline lags because one buffer line spans several rows.
    const top_before = h.getViewportTop(g);
    var uncovered_total: i64 = 0;
    var step: usize = 0;
    while (step < 8) : (step += 1) try scrollOneRow(h);

    // A win_viewport can still be in flight when the last keystroke's redraw
    // lands, so drain until the rows show up rather than reading once.
    const Acc = struct { g: i64, total: *i64 };
    h.waitUntil(Acc{ .g = g, .total = &uncovered_total }, struct {
        fn check(c: Acc, hh: *Harness) bool {
            c.total.* += hh.takeUncoveredScrollRows(c.g);
            return c.total.* >= 8;
        }
    }.check, h.opts.timeout_ms) catch {};

    if (uncovered_total != 8) {
        std.debug.print(
            "[e2e] smoothscroll_viewport_delta: expected 8 uncovered rows, got {d}\n",
            .{uncovered_total},
        );
        return error.UncoveredRowsMismatch;
    }
    const top_advance = h.getViewportTop(g) - top_before;
    if (top_advance >= 8) {
        std.debug.print(
            "[e2e] smoothscroll_viewport_delta: topline advanced {d} for 8 screen rows — lines are not wrapping\n",
            .{top_advance},
        );
        return error.NotWrapping;
    }

    // Control: without 'smoothscroll' grid_scroll describes the same movement,
    // so nothing is left over and the frontend keeps its existing behaviour.
    try h.command("set nosmoothscroll");
    try h.command("normal! gg");
    // Settle the mode switch: the gg jump's own win_viewport is still in flight
    // and would otherwise be read as this scroll's.
    step = 0;
    while (step < 4) : (step += 1) try scrollOneRow(h);
    // Here one <C-e> moves a whole buffer line, so scroll_delta reports the
    // number of screen rows that line occupies. Wait for topline to advance
    // first, or the value still belongs to the preceding gg.
    try waitToplineAdvance(h, g, 0);
    const wrapped_rows_per_line = h.getViewportScrollDelta(g);
    if (wrapped_rows_per_line < 2) {
        std.debug.print(
            "[e2e] smoothscroll_viewport_delta: content is not wrapping — one buffer line spans {d} screen row(s)\n",
            .{wrapped_rows_per_line},
        );
        return error.NotWrapping;
    }
    _ = h.takeUncoveredScrollRows(g);

    step = 0;
    while (step < 8) : (step += 1) {
        try scrollOneRow(h);
        const uncovered = h.takeUncoveredScrollRows(g);
        if (uncovered != 0) {
            std.debug.print(
                "[e2e] smoothscroll_viewport_delta: grid_scroll should cover the movement, {d} rows left over\n",
                .{uncovered},
            );
            return error.UnexpectedUncoveredRows;
        }
    }

    std.debug.print(
        "[e2e] smoothscroll_viewport_delta: 1 buffer line spans {d} screen rows; " ++
            "smoothscroll left {d} rows uncovered over 8 <C-e> (topline advanced {d}), " ++
            "nosmoothscroll left 0\n",
        .{ wrapped_rows_per_line, uncovered_total, top_advance },
    );
}

fn waitToplineAdvance(h: *Harness, g: i64, from: u32) !void {
    const Ctx = struct { g: i64, from: u32 };
    try h.waitUntil(Ctx{ .g = g, .from = from }, struct {
        fn check(c: Ctx, hh: *Harness) bool {
            return hh.getViewportTop(c.g) > c.from;
        }
    }.check, h.opts.timeout_ms);
}

fn scrollOneRow(h: *Harness) !void {
    const before_rev = h.contentRev();
    try h.input("\x05"); // <C-e>
    const Ctx = struct { rev: u64 };
    try h.waitUntil(Ctx{ .rev = before_rev }, struct {
        fn check(c: Ctx, hh: *Harness) bool {
            return hh.contentRev() > c.rev;
        }
    }.check, h.opts.timeout_ms);
}
