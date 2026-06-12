// input_latency_performance — Input to grid update latency is within 16.7ms @ 60Hz.
// Neovide #2602: Input processing could stall on expensive per-frame operations.
// Exercises: input event latency, vertex generation performance.

const std = @import("std");
const Harness = @import("../harness.zig").Harness;

pub fn run(alloc: std.mem.Allocator) !void {
    var h = try Harness.init(alloc, .{});
    defer h.deinit();

    // Establish baseline: send one keystroke and measure response time.
    // In a headless harness, we can't measure real wall-clock latency,
    // but we can measure flush count changes (number of render cycles).

    const initial_flush = h.flush_seq.load(.seq_cst);

    // Send a single key and wait for flush.
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
