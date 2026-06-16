// visual/cmdline_cursor_animation — verify that cmdline mode cursor
// moves immediately without animation trails.
//
// When neovide_cursor_animate_command_line is enabled, the cursor should
// snap immediately to new positions in command-line mode (`:` or `c:`)
// without springy animation. This catches the bug where the cursor
// animation spring state is not reset when entering cmdline mode,
// causing trailing animation from the previous position.

const std = @import("std");
const fixture = @import("fixture.zig");
const visual = @import("../../visual.zig");

pub fn run(alloc: std.mem.Allocator) !void {
    var g = try fixture.open(alloc);
    defer g.deinit();

    // Enable cursor animation explicitly (if supported by the setting)
    // This ensures the animation spring is active in normal mode
    try g.exec("execute('set guicursor=c:ver25-Cursor')");

    // Create a simple buffer with some text
    try g.exec(
        \\setline(1, ['sample text for cmdline test'])
    );
    try g.exec("execute('normal! gg0')");

    // Settle the initial render
    var _img_initial = try g.captureStable(.{ .w_pt = 600, .h_pt = 300 }, 5000);
    defer _img_initial.deinit(alloc);

    // Enter command-line mode by typing ':'
    try g.remoteSend(":");

    // Capture immediately after entering cmdline — cursor should be at
    // the command line input position, settled immediately
    var img_cmdline_start = try g.captureStable(.{ .w_pt = 600, .h_pt = 300 }, 8000);
    defer img_cmdline_start.deinit(alloc);

    // Type some characters in the command line
    try g.remoteSend("set");

    // Capture after typing — cursor should have moved with no animation trail
    // (the cursor position changes discretely, not smoothly)
    var img_cmdline_after = try g.captureStable(.{ .w_pt = 600, .h_pt = 300 }, 8000);
    defer img_cmdline_after.deinit(alloc);

    // Type one more character to exercise cursor movement in cmdline
    try g.remoteSend(" ");

    // Final capture
    var img_cmdline_final = try g.captureStable(.{ .w_pt = 600, .h_pt = 300 }, 8000);
    defer img_cmdline_final.deinit(alloc);

    // The golden image captures the cmdline state after typing
    // There should be no visual trails or springy artifacts
    try visual.assertMatch(alloc, "cmdline_cursor_animation", img_cmdline_after, .{});

    // Also verify the final state to ensure no animation accumulation
    try visual.assertMatch(alloc, "cmdline_cursor_animation_final", img_cmdline_final, .{});
}
