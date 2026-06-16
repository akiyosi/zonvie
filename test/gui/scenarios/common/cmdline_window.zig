// cmdline_window — GUI-level ext_cmdline overlay window lifecycle.
//
// With --extcmdline, Zonvie renders the cmdline as a separate overlay OS
// window. Pressing ':' must make that window appear on screen; leaving
// cmdline mode with <Esc> must make it disappear. Works with stock nvim
// (ext_cmdline is a standard UI option).
//
// This asserts what a human verifies by eye: a real window appearing and
// disappearing in response to a keystroke, rendered by the real frontend.

const std = @import("std");
const Gui = @import("../../driver.zig").Gui;

pub fn run(alloc: std.mem.Allocator) !void {
    var g = try Gui.init(alloc, .{ .app_args = &.{ "--extcmdline", "--log", "tmp/gui_app.log" } });
    defer g.deinit();

    const base = g.windowCount();
    try std.testing.expect(base >= 1);

    // Enter cmdline mode: the external cmdline overlay window must appear.
    try g.remoteSend(":");
    try g.waitWindowCount(base + 1, 10_000);

    // Leave cmdline mode: the overlay window must disappear.
    try g.remoteSend("<Esc>");
    try g.waitWindowCount(base, 10_000);
}
