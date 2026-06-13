// scrollbar_first_line — Viewport calculation must not depend on cursor_row.
//
// Tests the contract: viewport bounds (top_line, bottom_line) are computed from
// the buffer size and scroll offset, NOT from cursor position. A regression would
// cause viewport to jump when the cursor moves to line 1 with scrolloff set.

const std = @import("std");
const Harness = @import("../harness.zig").Harness;

pub fn run(alloc: std.mem.Allocator) !void {
    var h = try Harness.init(alloc, .{});
    defer h.deinit();

    const g = h.winGrid();

    // Create a 100-line buffer using ex command (simpler).
    var buf = try std.ArrayList(u8).initCapacity(alloc, 256);
    defer buf.deinit(alloc);

    try buf.appendSlice(alloc, "call setline(1, [");
    var line: u32 = 1;
    while (line <= 100) : (line += 1) {
        if (line > 1) try buf.appendSlice(alloc, ", ");
        try std.fmt.format(buf.writer(alloc), "'line {d}'", .{line});
    }
    try buf.appendSlice(alloc, "])");

    try h.command(buf.items);
    try h.waitRowText(g, 0, "line 1", h.opts.timeout_ms);

    // Set scrolloff=5 (5 lines of context around cursor).
    try h.command("set scrolloff=5");

    // Initial cursor at line 1; viewport should be stable.
    try h.waitCursor(0, 0, h.opts.timeout_ms);
    const initial_viewport = h.getViewportTop(g);

    // Verify viewport is reasonable (between 0 and buffer size).
    if (initial_viewport > 100) {
        std.debug.print(
            "[e2e] scrollbar_first_line: initial viewport top={d} is invalid\n",
            .{initial_viewport},
        );
        return error.TestFailed;
    }

    // Move cursor down to line 20, then back to line 1. `waitCursor` reports
    // GRID-relative coordinates, and with scrolloff=5 jumping to buffer line 20
    // scrolls the viewport (line 20 + context exceeds the 24-row grid), so the
    // cursor's grid row is NOT 19. Sync on the viewport having scrolled instead
    // of asserting a grid cursor row.
    try h.input("20G");
    {
        const Vp = struct { g: i64, base: u32 };
        try h.waitUntil(Vp{ .g = g, .base = initial_viewport }, struct {
            fn check(c: Vp, hh: *Harness) bool {
                return hh.getViewportTop(c.g) != c.base;
            }
        }.check, h.opts.timeout_ms);
    }

    try h.input("gg");
    try h.waitCursor(0, 0, h.opts.timeout_ms);

    // Viewport should return to the same position (independent of cursor movement).
    const final_viewport = h.getViewportTop(g);
    if (initial_viewport != final_viewport) {
        std.debug.print(
            "[e2e] scrollbar_first_line: viewport mismatch at line 1 initial={d} final={d}\n",
            .{ initial_viewport, final_viewport },
        );
        return error.TestFailed;
    }
}
