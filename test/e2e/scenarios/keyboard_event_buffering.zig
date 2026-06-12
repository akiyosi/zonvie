// keyboard_event_buffering — High-frequency keyboard input doesn't drop events.
// Neovide #3385: Rapid keyboard input could overflow the event queue, dropping keystrokes.
// Exercises: input buffering, event queue handling under load.

const std = @import("std");
const Harness = @import("../harness.zig").Harness;

pub fn run(alloc: std.mem.Allocator) !void {
    var h = try Harness.init(alloc, .{});
    defer h.deinit();

    // Simulate rapid keyboard input: type 100 characters in sequence.
    // This stresses the input event queue to near capacity.
    // Build input string: "abcdefghijklmnopqrstuvwxyz" repeated several times.
    const char_sets = "abcdefghijklmnopqrstuvwxyz";
    var input_buf: [400]u8 = undefined;
    var input_pos: usize = 0;
    var repetition: usize = 0;
    while (repetition < 4) : (repetition += 1) {
        for (char_sets) |c| {
            input_buf[input_pos] = c;
            input_pos += 1;
        }
    }
    input_buf[input_pos] = 0;
    var cmd_buf: [512]u8 = undefined;
    const cmd = try std.fmt.bufPrint(&cmd_buf, "i{s}<Esc>", .{input_buf[0..input_pos]});

    try h.input(cmd);
    const g = h.winGrid();
    const expected = input_buf[0..input_pos];
    try h.waitRowText(g, 0, expected, h.opts.timeout_ms);

    // Verify grid cursor advanced to the end (no dropped characters).
    const cursor = h.cursor();
    // Cursor should be on the last character.
    try std.testing.expectEqual(@as(u32, 0), cursor.row);
    try std.testing.expect(cursor.col > 0);
}
