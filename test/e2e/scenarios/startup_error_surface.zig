// startup_error_surface — verify nvim startup completes and grid initializes.
//
// Bug scenario: if flush callback (onFlushEnd) is not called, waitRowText
// will timeout because condvar is never signaled.
// Fix: ensure on_flush_end callback is registered and fires.

const std = @import("std");
const Harness = @import("../harness.zig").Harness;

pub fn run(alloc: std.mem.Allocator) !void {
    // Test that nvim startup reaches first flush and callback fires.
    // The harness registers an on_flush_end callback that signals condvar.
    // If the callback is not registered, this test will timeout.
    var h = try Harness.init(alloc, .{});
    defer h.deinit();

    const g = h.winGrid();
    // Wait for initial grid to be populated via flush callback.
    // Verifies that callbacks are registered and flush-end fires.
    try h.waitRowText(g, 0, "", h.opts.timeout_ms);

    // Verify grid is actually initialized.
    h.core.grid_mu.lock();
    const rows = h.core.grid.rows;
    h.core.grid_mu.unlock();

    if (rows == 0) {
        return error.GridNotInitialized;
    }
}
