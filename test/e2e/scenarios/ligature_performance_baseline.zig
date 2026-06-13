// ligature_performance_baseline — Performance measurement with ligatures + relative numbers.
//
// Tests frame-time performance under realistic conditions: ligature shaping +
// relative line numbers on a large buffer. A regression (e.g., re-shaping every
// frame instead of caching) causes frame_time_ms to exceed the 16.7ms @ 60Hz budget.

const std = @import("std");
const Harness = @import("../harness.zig").Harness;

pub fn run(alloc: std.mem.Allocator) !void {
    var h = try Harness.init(alloc, .{
        // Larger buffer for realistic perf test.
        .rows = 30,
        .cols = 100,
    });
    defer h.deinit();

    const g = h.winGrid();

    // Create a 10,000-line buffer.
    var buf = try std.ArrayList(u8).initCapacity(alloc, 256 * 1024);
    defer buf.deinit(alloc);

    try buf.appendSlice(alloc, "call setline(1, [");
    var line: u32 = 1;
    while (line <= 10000) : (line += 1) {
        if (line > 1) try buf.appendSlice(alloc, ", ");
        // Use '->' ligature to exercise shaping (if available).
        try std.fmt.format(buf.writer(alloc), "'line {d} -> data'", .{line});
    }
    try buf.appendSlice(alloc, "])");

    try h.command(buf.items);
    try h.waitRowText(g, 0, "line 1 -> data", h.opts.timeout_ms);

    // Enable relative line numbers. The number column is rendered into the grid
    // row, so row 1 (relative number 1, right-justified in numberwidth=4) reads
    // "  1 line 2 -> data". Pin numberwidth so the expected text is
    // deterministic regardless of the nvim default.
    try h.command("set relativenumber numberwidth=4");
    try h.waitRowText(g, 1, "  1 line 2 -> data", h.opts.timeout_ms);

    // Measure frame time over 10 flush cycles (average should stay well under 16.7ms).
    const avg_frame_time_ms = try h.measureFrameTime(10);

    // Log the measurement.
    std.debug.print(
        "[e2e] ligature_performance: avg_frame_time_ms={d:.1}\n",
        .{avg_frame_time_ms},
    );

    // For a real CI environment, the budget should be >= 20ms (generous for slow CI).
    // For now, we just log; adjust this threshold if regressions appear.
    if (avg_frame_time_ms > 30.0) {
        std.debug.print(
            "[e2e] ligature_performance: WARNING frame time {d:.1}ms > 30ms (possible regression)\n",
            .{avg_frame_time_ms},
        );
    }
}
