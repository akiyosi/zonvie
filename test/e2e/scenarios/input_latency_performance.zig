// input_latency_performance — a keystroke drives the core flush pipeline
// promptly (at least one flush, and not a runaway loop).
// Note: the headless harness runs no vertex generation, so this is a
// flush-pipeline smoke check — NOT the wall-clock latency / per-frame-cost
// measurement of Neovide #2602 (that needs the GUI driver with real rendering).

const std = @import("std");
const Harness = @import("../harness.zig").Harness;

pub fn run(alloc: std.mem.Allocator) !void {
    var h = try Harness.init(alloc, .{});
    defer h.deinit();

    // Establish baseline: send one keystroke and measure response time.
    // In a headless harness, we can't measure real wall-clock latency,
    // but we can measure flush count changes (number of render cycles).

    // Enter insert mode first — a bare "a" in normal mode is the append
    // command and inserts no text. Measure the single-keystroke render below.
    try h.input("i");
    try h.waitMode("insert", h.opts.timeout_ms);
    const initial_flush = h.flush_seq.load(.seq_cst);

    // Send a single key and wait for it to render.
    try h.input("a");

    // Wait for the keystroke to appear in the grid.
    const g = h.winGrid();
    try h.waitRowText(g, 0, "a", h.opts.timeout_ms);

    // The flush should occur within a reasonable number of iterations.
    // With a 20ms granule per condvar wait in the harness, "reasonable" is
    // roughly < 2 flushes (i.e., within ~40ms wall time, well above 16.7ms
    // but practical for CI). This test mainly ensures no deadlock or catastrophic stall.
    const final_flush = h.flush_seq.load(.seq_cst);
    const flushes_elapsed = final_flush -% initial_flush;
    try std.testing.expect(flushes_elapsed > 0); // At least one flush happened.
    try std.testing.expect(flushes_elapsed <= 5); // Not stuck in a loop (very generous).
}
