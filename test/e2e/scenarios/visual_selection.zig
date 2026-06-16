// visual_selection — linewise Visual mode highlights the selected line.
// Asserts the mode change and that the selected row resolves to a different
// bg than an unselected row.

const std = @import("std");
const Harness = @import("../harness.zig").Harness;

pub fn run(alloc: std.mem.Allocator) !void {
    var h = try Harness.init(alloc, .{});
    defer h.deinit();

    try h.input("iselect me<CR>leave me<Esc>");
    const g = h.winGrid();
    try h.waitRowText(g, 1, "leave me", h.opts.timeout_ms);

    // Linewise-select row 0.
    try h.input("gg0V");
    try h.waitMode("visual", h.opts.timeout_ms);

    // Compare a mid-line cell (col 2), NOT column 0: in linewise Visual the
    // cursor sits at column 0, and the cell under the cursor keeps the default
    // hl (the cursor is a separate overlay), so only the non-cursor cells of
    // the line carry the Visual highlight.
    const Ctx = struct { g: i64 };
    h.waitUntil(Ctx{ .g = g }, struct {
        fn check(c: Ctx, hh: *Harness) bool {
            // Row 0 selected (Visual bg), row 1 not.
            return hh.hlAt(c.g, 0, 2).bg != hh.hlAt(c.g, 1, 2).bg;
        }
    }.check, h.opts.timeout_ms) catch return error.SelectionNotHighlighted;

    // Leaving Visual mode clears the selection highlight.
    try h.input("<Esc>");
    try h.waitMode("normal", h.opts.timeout_ms);
}
