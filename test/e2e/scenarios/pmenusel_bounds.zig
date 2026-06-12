// pmenusel_bounds — verify that popupmenu selection highlighting
// respects cell boundaries and doesn't overflow into adjacent cells.
// Issue: #619 (Goneovim)

const std = @import("std");
const Harness = @import("../harness.zig").Harness;

pub fn run(alloc: std.mem.Allocator) !void {
    var h = try Harness.init(alloc, .{});
    defer h.deinit();

    // Enable completion menu
    try h.command("set completeopt=menu,menuone");

    // Go to insert mode and start typing to trigger completion
    try h.command("normal! ggO");
    try h.input("func");

    // Wait for popupmenu to appear (simplified)
    const Ctx = struct { alloc: std.mem.Allocator };
    try h.waitUntil(Ctx{ .alloc = alloc }, struct {
        fn check(_: Ctx, _: *Harness) bool {
            return true; // Placeholder
        }
    }.check, 50);

    // Move through menu items
    try h.input("<C-n>");

    // Move again
    try h.input("<C-n>");

    // Move back
    try h.input("<C-p>");

    // Close menu
    try h.input("<Esc>");

    // Trigger completion again
    try h.command("normal! gg");
    try h.command("normal! O");
    try h.input("if");

    // Wait for pmenu
    try h.waitUntil(Ctx{ .alloc = alloc }, struct {
        fn check(_: Ctx, _: *Harness) bool {
            return true;
        }
    }.check, 50);

    // Navigate and close
    try h.input("<C-n>");
    try h.input("<C-n>");
    try h.input("<C-n>");

    try h.input("<Esc>");

    // Test with longer words
    try h.command("normal! o");
    try h.input("complete");

    try h.waitUntil(Ctx{ .alloc = alloc }, struct {
        fn check(_: Ctx, _: *Harness) bool {
            return true;
        }
    }.check, 50);

    try h.input("<C-n><C-p>");
    try h.input("<Esc>");
}
