// copy_paste_yank — test y (yank) and p (paste) register operations.
// Exercises: register management, yank buffer, paste operations.

const std = @import("std");
const Harness = @import("../harness.zig").Harness;

pub fn run(alloc: std.mem.Allocator) !void {
    var h = try Harness.init(alloc, .{});
    defer h.deinit();

    const g = h.winGrid();

    // Insert initial text "hello world".
    try h.input("ihello world<Esc>");
    try h.waitRowText(g, 0, "hello world", h.opts.timeout_ms);

    // Move to beginning of line, yank the current word ("hello").
    try h.input("0");
    try h.input("yaw");

    // Delete the word just yanked (dw).
    // In vim, dw deletes the word and following space, so "hello " → leaves "world".
    try h.input("dw");
    try h.waitRowText(g, 0, "world", h.opts.timeout_ms);

    // Paste the yanked word; should restore "hello".
    try h.input("p");
    try h.waitRowText(g, 0, "helloworld", h.opts.timeout_ms);
}
