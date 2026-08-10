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
    _ = h.grid_scroll_rows.swap(0, .seq_cst);
    var step: usize = 0;
    while (step < 8) : (step += 1) try scrollOneRow(h);

    // The last keystroke's win_viewport can still be in flight, so wait for the
    // reports rather than reading once.
    const Acc = struct {};
    h.waitUntil(Acc{}, struct {
        fn check(_: Acc, hh: *Harness) bool {
            return hh.grid_scroll_rows.load(.seq_cst) >= 8;
        }
    }.check, h.opts.timeout_ms) catch {};

    const reported = h.grid_scroll_rows.load(.seq_cst);
    if (reported != 8) {
        std.debug.print(
            "[e2e] smoothscroll_viewport_delta: 8 screen rows moved, {d} reported\n",
            .{reported},
        );
        return error.ReportedRowsMismatch;
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
    // and would otherwise be read as this scroll's. Wait for these to be
    // reported too, or they land after the counter is reset and inflate the
    // measurement that follows.
    _ = h.grid_scroll_rows.swap(0, .seq_cst);
    step = 0;
    while (step < 4) : (step += 1) try scrollOneRow(h);
    const Settle = struct {};
    h.waitUntil(Settle{}, struct {
        fn check(_: Settle, hh: *Harness) bool {
            return hh.grid_scroll_rows.load(.seq_cst) >= 4;
        }
    }.check, h.opts.timeout_ms) catch {};
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
    // Here grid_scroll describes the movement itself, and the total must come
    // out the same way: whatever the mix of shifted and repainted rows, the
    // frontend is told the whole distance exactly once.
    _ = h.grid_scroll_rows.swap(0, .seq_cst);
    step = 0;
    while (step < 8) : (step += 1) try scrollOneRow(h);
    const want_rows = 8 * wrapped_rows_per_line;
    const Ctx = struct { want: i64 };
    h.waitUntil(Ctx{ .want = want_rows }, struct {
        fn check(c: Ctx, hh: *Harness) bool {
            return hh.grid_scroll_rows.load(.seq_cst) >= c.want;
        }
    }.check, h.opts.timeout_ms) catch {};
    const control_rows = h.grid_scroll_rows.load(.seq_cst);
    if (control_rows != want_rows) {
        std.debug.print(
            "[e2e] smoothscroll_viewport_delta: {d} buffer lines span {d} screen rows, {d} reported\n",
            .{ 8, want_rows, control_rows },
        );
        return error.ReportedRowsMismatch;
    }

    std.debug.print(
        "[e2e] smoothscroll_viewport_delta: 1 buffer line spans {d} screen rows; " ++
            "8 <C-e> reported {d} rows under smoothscroll (topline advanced {d}) " ++
            "and {d} without it\n",
        .{ wrapped_rows_per_line, reported, top_advance, control_rows },
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
