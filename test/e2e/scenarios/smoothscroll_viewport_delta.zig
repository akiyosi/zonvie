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
    // reports to stop rather than reading once.
    waitReportsQuiet(h);

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
    step = 0;
    while (step < 4) : (step += 1) try scrollOneRow(h);
    waitReportsQuiet(h);
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
    const control_baseline = h.grid_scroll_rows.load(.seq_cst);
    step = 0;
    while (step < 8) : (step += 1) try scrollOneRow(h);
    waitReportsQuiet(h);
    const want_rows = 8 * wrapped_rows_per_line;
    const control_rows = h.grid_scroll_rows.load(.seq_cst) - control_baseline;
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

/// Wait until the reports stop arriving. Waiting for a THRESHOLD does not work
/// here: one <C-e> over wrapped lines reports several rows, so a "at least N
/// rows" wait is satisfied by the first of N scrolls and the rest land later —
/// after the next phase has taken its baseline, inflating it.
fn waitReportsQuiet(h: *Harness) void {
    var last: i64 = -1;
    var stable: usize = 0;
    while (stable < 4) {
        const now = h.grid_scroll_rows.load(.seq_cst);
        if (now == last) stable += 1 else stable = 0;
        last = now;
        const Ctx = struct { from: u64 };
        h.waitUntil(Ctx{ .from = h.flush_seq.load(.seq_cst) }, struct {
            fn check(c: Ctx, hh: *Harness) bool {
                return hh.flush_seq.load(.seq_cst) > c.from;
            }
        }.check, 50) catch {};
    }
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
