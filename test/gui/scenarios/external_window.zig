// external_window — GUI-level external FLOAT window lifecycle.
//
// `nvim_open_win({external=true})` needs an attached UI with multigrid
// support — which Zonvie always claims — NOT the ext_windows attach option
// (that one externalizes regular splits and targets a patched nvim).
// Works with stock nvim once the real frontend is attached.
//
// Asserts what a human verifies by eye: creating an external float makes
// a REAL second OS window appear; closing it makes the window disappear.

const std = @import("std");
const Gui = @import("../driver.zig").Gui;

pub fn run(alloc: std.mem.Allocator) !void {
    var g = try Gui.init(alloc, .{ .app_args = &.{ "--log", "tmp/gui_app.log" } });
    defer g.deinit();

    const base = g.windowCount();
    try std.testing.expect(base >= 1);

    // Open an external float: a real OS window must appear.
    const out = try g.remoteExpr(
        "luaeval('(function() _G.e2e_win = vim.api.nvim_open_win(" ++
            "vim.api.nvim_create_buf(false, true), true, " ++
            "{external=true, width=30, height=10}) return 1 end)()')",
    );
    alloc.free(out);
    try g.waitWindowCount(base + 1, 10_000);

    // Close it: the OS window must disappear.
    const out2 = try g.remoteExpr(
        "luaeval('(function() vim.api.nvim_win_close(_G.e2e_win, true) return 1 end)()')",
    );
    alloc.free(out2);
    try g.waitWindowCount(base, 10_000);
}
