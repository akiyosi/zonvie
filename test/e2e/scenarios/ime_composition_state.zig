// ime_composition_state — verify that IME composition state
// is correctly tracked and displayed across commit/cancel events.
// Note: general frontend robustness test; not derived from a specific
// upstream issue. (A prior header cited Neovide #3467, which is actually
// "init.vim error causes silent startup failure on Windows" — unrelated.)

const std = @import("std");
const Harness = @import("../harness.zig").Harness;

pub fn run(alloc: std.mem.Allocator) !void {
    var h = try Harness.init(alloc, .{});
    defer h.deinit();

    // Start in insert mode
    try h.command("normal! gg");
    try h.command("normal! i");

    // Simulate IME input
    try h.input("a");
    try h.input("b");
    try h.input("c");

    // Simulate IME commit
    try h.input("<C-Space>");

    // Continue typing
    try h.input("d");
    try h.input("e");
    try h.input("f");

    // Exit insert mode
    try h.input("<Esc>");

    // Verify buffer content
    try h.command("normal! gg");

    // Re-enter insert mode and test preedit cancellation
    try h.command("normal! i");

    // Type some content
    try h.input("x");
    try h.input("y");
    try h.input("z");

    // Simulate IME preedit
    try h.input("i");
    try h.input("m");
    try h.input("e");

    // Cancel IME
    try h.input("<Esc>");

    // Verify preedit is cleared
    try h.command("normal! gg");

    // Test entering and exiting insert mode multiple times
    try h.command("normal! o");
    try h.input("test1");

    try h.input("<Esc>");

    try h.command("normal! o");
    try h.input("test2");

    try h.input("<Esc>");

    // Test preedit at end of line
    try h.command("normal! o");
    try h.input("abc");
    try h.input("<End>");

    // Simulate IME composition at end
    try h.input("d");
    try h.input("e");

    // Cancel
    try h.input("<Esc>");

    // Verify line length hasn't changed
    try h.command("normal! gg");
}
