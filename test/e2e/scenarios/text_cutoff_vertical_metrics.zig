// text_cutoff_vertical_metrics — verify that text is not clipped vertically
// and that font metrics (cell height, linespace) are calculated correctly.
// Exercises: guifont, linespace, cell size, vertexgen metrics.

const std = @import("std");
const Harness = @import("../harness.zig").Harness;

pub fn run(alloc: std.mem.Allocator) !void {
    var h = try Harness.init(alloc, .{});
    defer h.deinit();

    const g = h.winGrid();

    // Set a large linespace to increase cell height and potential clipping risk.
    try h.command("set linespace=20");

    // Insert multiple lines of text with visible characters.
    try h.input("i");
    var i: u32 = 0;
    while (i < 5) : (i += 1) {
        const text = try std.fmt.allocPrint(alloc, "row{d}TEXT", .{i});
        defer alloc.free(text);
        try h.input(text);
        try h.input("<CR>");
    }
    try h.input("<Esc>");

    // Wait for all rows to be visible with correct text.
    i = 0;
    while (i < 5) : (i += 1) {
        const expected = try std.fmt.allocPrint(alloc, "row{d}TEXT", .{i});
        defer alloc.free(expected);
        try h.waitRowText(g, i, expected, h.opts.timeout_ms);
    }

    // Verify each row's cells are populated (not clipped to 0 or partial state).
    // If metrics are miscalculated, cells may be empty or contain only partial text.
    i = 0;
    while (i < 5) : (i += 1) {
        const text = try h.rowTextAlloc(alloc, g, i);
        defer alloc.free(text);

        // Verify text is not empty.
        try std.testing.expect(text.len > 0);

        // Verify text contains expected pattern (row{i}TEXT).
        const expected = try std.fmt.allocPrint(alloc, "row{d}TEXT", .{i});
        defer alloc.free(expected);
        try std.testing.expect(std.mem.eql(u8, text, expected));
    }

    // Verify that cells have non-zero codepoints (not clipped/missing).
    i = 0;
    while (i < 5) : (i += 1) {
        var j: u32 = 0;
        while (j < 8) : (j += 1) {
            const c = h.cellAt(g, i, j);
            // Cells should have valid codepoints (not 0 = unset/continuation).
            try std.testing.expect(c.cp != 0);
        }
    }
}
