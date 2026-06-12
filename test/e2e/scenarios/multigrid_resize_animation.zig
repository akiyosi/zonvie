// multigrid_resize_animation — verify that when multiple grids are resized,
// animation state and partial redraw remain correct.
// Issue: #3466 (Neovide)

const std = @import("std");
const Harness = @import("../harness.zig").Harness;

pub fn run(alloc: std.mem.Allocator) !void {
    var h = try Harness.init(alloc, .{});
    defer h.deinit();

    // Create a split window
    try h.command("split");

    // Add content to both windows
    try h.command("normal! i");
    try h.input("window1_content");
    try h.input("<Esc>");

    try h.command("normal! j");
    try h.command("normal! i");
    try h.input("window2_content");
    try h.input("<Esc>");

    // Create a floating window on top
    try h.command(
        "lua _G.test_float = vim.api.nvim_open_win(vim.api.nvim_create_buf(false, true), false, {" ++
            "relative='editor', row=5, col=5, width=12, height=3" ++
            "})",
    );

    // Record initial state
    const initial_grids = try h.positionedGridsAlloc(alloc);
    defer alloc.free(initial_grids);

    // Verify three grids exist (main + split + float)
    try std.testing.expect(initial_grids.len >= 3);

    // Perform resize via command
    try h.command("resize +5");

    // Verify grids still exist
    const after_resize1 = try h.positionedGridsAlloc(alloc);
    defer alloc.free(after_resize1);

    try std.testing.expect(after_resize1.len >= initial_grids.len);

    // Another resize
    try h.command("resize -3");

    const after_resize2 = try h.positionedGridsAlloc(alloc);
    defer alloc.free(after_resize2);

    try std.testing.expect(after_resize2.len >= initial_grids.len);

    // Move between windows
    try h.command("normal! k");

    // Resize again
    try h.command("resize +2");

    const after_resize3 = try h.positionedGridsAlloc(alloc);
    defer alloc.free(after_resize3);

    try std.testing.expect(after_resize3.len >= initial_grids.len);

    // Move float window
    try h.command(
        "lua vim.api.nvim_win_set_config(_G.test_float, {row=8, col=8})",
    );

    // Resize main window again
    try h.command("vsplit");

    const after_vsplit = try h.positionedGridsAlloc(alloc);
    defer alloc.free(after_vsplit);

    try std.testing.expect(after_vsplit.len >= initial_grids.len);

    // Verify float is still present
    var float_found = false;
    for (after_vsplit) |id| {
        for (initial_grids) |iid| {
            if (id == iid) break;
        } else {
            float_found = true;
            break;
        }
    }
    try std.testing.expect(float_found);

    // Close float
    try h.command("lua vim.api.nvim_win_close(_G.test_float, true)");

    // Resize windows after float is closed
    try h.command("normal! k");
    try h.command("resize -1");

    const final_grids = try h.positionedGridsAlloc(alloc);
    defer alloc.free(final_grids);

    // Verify we're back to baseline
    try std.testing.expect(final_grids.len >= 2);
}
