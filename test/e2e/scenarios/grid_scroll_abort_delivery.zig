// grid_scroll_abort_delivery — a grid_scroll notification is consumed the
// moment it is dispatched, and an abort after that point does not bring it
// back.
//
// This is the contract the macOS renderer's retained scroll rows depend on.
// The rows are captured from the on_grid_scroll callback and staged for the
// open flush; if that flush then aborts, the staged rows are discarded — and
// since the notification was already consumed, no later flush re-offers it.
// The renderer therefore has to replay the capture itself. This scenario pins
// down the half of that reasoning the core owns.

const std = @import("std");
const Harness = @import("../harness.zig").Harness;

pub fn run(alloc: std.mem.Allocator) !void {
    var h = try Harness.init(alloc, .{});
    defer h.deinit();

    try h.command("call setline(1, map(range(1, 400), 'string(v:val)'))");
    const g = h.winGrid();
    try h.command("normal! 200Gzt");
    try waitTopline(h, g, 199);

    // A scroll that completes normally: exactly one notification.
    _ = h.grid_scrolls.swap(0, .seq_cst);
    _ = h.grid_scroll_rows.swap(0, .seq_cst);
    try scrollAndSettle(h, g, 199 + 3);
    const normal_count = h.grid_scrolls.load(.seq_cst);
    const normal_rows = h.grid_scroll_rows.load(.seq_cst);
    if (normal_count != 1 or normal_rows != 3) {
        std.debug.print(
            "[e2e] grid_scroll_abort_delivery: normal scroll delivered {d} notifications totalling {d} rows, expected 1 and 3\n",
            .{ normal_count, normal_rows },
        );
        return error.UnexpectedNormalDelivery;
    }

    // Now abort the flush from inside the callback, then drive several more
    // flushes. The aborted scroll must not be re-offered.
    _ = h.grid_scrolls.swap(0, .seq_cst);
    _ = h.grid_scroll_rows.swap(0, .seq_cst);
    _ = h.flush_aborts.swap(0, .seq_cst);
    h.abort_flush_on_grid_scroll.store(true, .seq_cst);
    try scrollAndSettle(h, g, 199 + 6);

    var i: usize = 0;
    while (i < 5) : (i += 1) {
        // Any content change forces another flush without scrolling. Waited on
        // one at a time: an edit and its undo can land in the same redraw batch,
        // so asking for two flushes per pair is not guaranteed.
        //
        // Propagated, not swallowed: if these produced no flush at all, then
        // "the scroll was not re-offered" would hold for the wrong reason.
        try h.command("normal! ix\u{1b}");
        try waitFlushes(h, 1);
        try h.command("undo");
        try waitFlushes(h, 1);
    }

    // Without this the assertion below is also what a flush that never aborted
    // produces, so the scenario would pass whether or not the abort landed.
    if (h.flush_aborts.load(.seq_cst) == 0) {
        std.debug.print(
            "[e2e] grid_scroll_abort_delivery: no flush actually aborted; the arm did nothing\n",
            .{},
        );
        return error.AbortDidNotLand;
    }

    const aborted_count = h.grid_scrolls.load(.seq_cst);
    const aborted_rows = h.grid_scroll_rows.load(.seq_cst);
    if (aborted_count != 1 or aborted_rows != 3) {
        std.debug.print(
            "[e2e] grid_scroll_abort_delivery: after an abort the scroll was reported {d} times totalling {d} rows, expected 1 and 3\n",
            .{ aborted_count, aborted_rows },
        );
        return error.ScrollRedelivered;
    }

    std.debug.print(
        "[e2e] grid_scroll_abort_delivery: an abort after dispatch does not re-offer the scroll\n",
        .{},
    );
}

fn scrollAndSettle(h: *Harness, g: i64, want_top: u32) !void {
    h.wheel(g, "down");
    try waitTopline(h, g, want_top);
    if (h.getViewportTop(g) != want_top) {
        std.debug.print(
            "[e2e] grid_scroll_abort_delivery: topline {d}, expected {d}\n",
            .{ h.getViewportTop(g), want_top },
        );
        return error.ScrollDidNotLand;
    }
}

fn waitFlushes(h: *Harness, count: u64) !void {
    const Ctx = struct { target: u64 };
    try h.waitUntil(
        Ctx{ .target = h.flush_seq.load(.seq_cst) + count },
        struct {
            fn check(c: Ctx, hh: *Harness) bool {
                return hh.flush_seq.load(.seq_cst) >= c.target;
            }
        }.check,
        h.opts.timeout_ms,
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
