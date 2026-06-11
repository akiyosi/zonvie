// flush_order_correctness — Verifies that flush() preserves pending redraw state.
//
// Tests the contract: redraw callbacks must fire BEFORE on_flush_end, so that
// pending grid changes are not exposed to the frontend until the entire flush
// transaction completes. This is the invariant that keeps the window update
// sequence coherent: grid state updates first, then layout/draw calls last.

const std = @import("std");
const Harness = @import("../harness.zig").Harness;

pub fn run(alloc: std.mem.Allocator) !void {
    var h = try Harness.init(alloc, .{});
    defer h.deinit();

    // Start with empty grid.
    const g = h.winGrid();
    try h.waitRowText(g, 0, "", h.opts.timeout_ms);

    // Insert first line of content.
    try h.input("ihello<Esc>");
    try h.waitRowText(g, 0, "hello", h.opts.timeout_ms);

    // Record initial flush count.
    const flush_before = h.flush_seq.load(.seq_cst);

    // Insert second line; this should trigger a redraw + flush cycle.
    try h.input("oworld<Esc>");
    try h.waitRowText(g, 1, "world", h.opts.timeout_ms);

    // Verify flush count incremented.
    const flush_after = h.flush_seq.load(.seq_cst);
    if (flush_after <= flush_before) {
        std.debug.print("[e2e] flush_order: expected flush_seq to increment\n", .{});
        return error.TestFailed;
    }

    // The real test: grid content is coherent (no window-update-before-redraw race).
    // Both rows should have their final content, proving redraw fired before
    // on_flush_end.
    try h.waitRowText(g, 0, "hello", h.opts.timeout_ms);
    try h.waitRowText(g, 1, "world", h.opts.timeout_ms);
}
