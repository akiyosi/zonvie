// cursorline — 'cursorline' highlights the whole cursor row. Asserts the
// cursor row's cells resolve to a different bg than other rows, and that the
// highlight follows the cursor when it moves.

const std = @import("std");
const Harness = @import("../harness.zig").Harness;

fn rowBgDiffers(h: *Harness, g: i64, hot_row: u32, cold_row: u32) bool {
    return h.hlAt(g, hot_row, 0).bg != h.hlAt(g, cold_row, 0).bg;
}

pub fn run(alloc: std.mem.Allocator) !void {
    var h = try Harness.init(alloc, .{});
    defer h.deinit();

    try h.command("set cursorline");
    try h.input("iline one<CR>line two<CR>line three<Esc>");
    const g = h.winGrid();
    try h.waitRowText(g, 2, "line three", h.opts.timeout_ms);

    // Cursor on row 0: row 0 highlighted, row 1 not.
    try h.input("gg0");
    const Ctx = struct { g: i64, hot: u32, cold: u32 };
    h.waitUntil(Ctx{ .g = g, .hot = 0, .cold = 1 }, struct {
        fn check(c: Ctx, hh: *Harness) bool {
            return rowBgDiffers(hh, c.g, c.hot, c.cold);
        }
    }.check, h.opts.timeout_ms) catch return error.CursorlineNotApplied;

    // Move cursor to row 2: the highlight follows (row 2 hot, row 0 cold).
    try h.input("2j");
    h.waitUntil(Ctx{ .g = g, .hot = 2, .cold = 0 }, struct {
        fn check(c: Ctx, hh: *Harness) bool {
            return rowBgDiffers(hh, c.g, c.hot, c.cold);
        }
    }.check, h.opts.timeout_ms) catch return error.CursorlineDidNotFollow;
}
