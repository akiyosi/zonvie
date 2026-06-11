// macos_alt_key_mapping — verify that Alt key presses are correctly mapped
// to the Meta modifier and transmitted to nvim, firing Alt-key mappings.
// Exercises: input handler, modifier detection, macro firing.
// Platform: macOS only (Alt = Option key).

const std = @import("std");
const builtin = @import("builtin");
const Harness = @import("../harness.zig").Harness;

pub fn run(alloc: std.mem.Allocator) !void {
    // Skip on non-macOS platforms.
    if (builtin.target.os.tag != .macos) {
        return;
    }

    var h = try Harness.init(alloc, .{});
    defer h.deinit();

    const g = h.winGrid();

    // Set up an Alt+A mapping to insert a test marker.
    try h.command("imap <M-a> ALT_MAPPED");

    // Enter insert mode and press Alt+A.
    try h.input("i");
    try h.input("<M-a>");
    try h.input("<Esc>");

    // Wait for "ALT_MAPPED" to appear in the grid.
    // This proves the Alt key was correctly recognized and the mapping fired.
    try h.waitRowText(g, 0, "ALT_MAPPED", h.opts.timeout_ms);

    // Verify content in the grid cell-by-cell.
    const text = try h.rowTextAlloc(alloc, g, 0);
    defer alloc.free(text);
    try std.testing.expect(std.mem.eql(u8, text, "ALT_MAPPED"));
}
