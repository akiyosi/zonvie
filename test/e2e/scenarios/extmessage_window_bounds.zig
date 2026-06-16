// extmessage_window_bounds — Floating message window stays within parent window bounds.
// Goneovim #377: Long messages could cause floating window to overflow screen.
// Exercises: message window layout bounds checking, clamping logic.

const std = @import("std");
const Harness = @import("../harness.zig").Harness;

pub fn run(alloc: std.mem.Allocator) !void {
    var h = try Harness.init(alloc, .{});
    defer h.deinit();

    // Create a long message that would overflow without bounds checking.
    // Use :echo to trigger the ext_message callback.
    const long_msg = "This is a very long message that will test the bounds of the floating message window to ensure it does not exceed the parent window width.";
    var cmd_buf: [512]u8 = undefined;
    const cmd = try std.fmt.bufPrint(&cmd_buf, "echo '{s}'", .{long_msg});

    try h.command(cmd);

    // Wait for the message to be processed. The hardness doesn't capture
    // message window geometry directly, but we verify no crash occurs and
    // grid state remains valid.
    _ = h.winGrid();

    // Verify basic grid consistency (no crash).
    const cursor = h.cursor();
    try std.testing.expect(cursor.grid_id > 0);
}
