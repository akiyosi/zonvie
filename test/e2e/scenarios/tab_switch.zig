// tab_switch — switching tab pages swaps the visible window grid's content.
// Exercises multigrid window-grid switching: the cursor's grid changes per
// tab and the displayed content tracks it.

const std = @import("std");
const Harness = @import("../harness.zig").Harness;

pub fn run(alloc: std.mem.Allocator) !void {
    var h = try Harness.init(alloc, .{});
    defer h.deinit();

    try h.input("ialpha tab<Esc>");
    try h.waitRowText(h.winGrid(), 0, "alpha tab", h.opts.timeout_ms);

    // New tab with distinct content.
    try h.command("tabnew");
    try h.input("ibeta tab<Esc>");
    try h.waitRowText(h.winGrid(), 0, "beta tab", h.opts.timeout_ms);

    // Back to the first tab: its content is shown again.
    try h.command("tabprevious");
    try h.waitRowText(h.winGrid(), 0, "alpha tab", h.opts.timeout_ms);

    // Forward again.
    try h.command("tabnext");
    try h.waitRowText(h.winGrid(), 0, "beta tab", h.opts.timeout_ms);
}
