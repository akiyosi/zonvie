// macos_option_key_meta — verify that the Option key (macOS Alt equivalent)
// is correctly interpreted as the Meta modifier, enabling Meta-key bindings.
// Exercises: macOS input translation, modifier handling, key mapping.
// Platform: macOS only.

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

    // Set up a Meta+x mapping (in macOS terms, Option+x).
    try h.command("imap <M-x> META_KEY_FIRED");

    // Enter insert mode and press Meta+X (Option+X on macOS).
    try h.input("i");
    try h.input("<M-x>");
    try h.input("<Esc>");

    // Wait for "META_KEY_FIRED" to appear in the grid.
    // This confirms Option was converted to Meta and the binding fired.
    try h.waitRowText(g, 0, "META_KEY_FIRED", h.opts.timeout_ms);

    // Verify the exact text in the grid.
    const text = try h.rowTextAlloc(alloc, g, 0);
    defer alloc.free(text);
    try std.testing.expect(std.mem.eql(u8, text, "META_KEY_FIRED"));
}
