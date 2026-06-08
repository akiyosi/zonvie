// ime_preedit_extmark — regression test for 629615d: extmark-based inline
// preedit display. Core.setPreedit must place the composition text as an
// inline virt_text extmark at the cursor in insert/replace mode (returns
// true → frontend hides its overlay), render it in the grid, remove it on
// clearPreedit, and fall back to frontend-overlay mode (returns false)
// outside insert/replace.
//
// The setPreedit return value is also the core-side contract behind
// 60e3081 (Windows: hide the preedit overlay while the inline extmark is
// active): true tells the frontend to suppress its own overlay window so
// the two don't both draw. We assert that contract here; the frontend's
// actual overlay-window hiding is a pixel/z-order effect that needs the
// not-yet-built screenshot layer to observe directly.

const std = @import("std");
const Harness = @import("../harness.zig").Harness;

pub fn run(alloc: std.mem.Allocator) !void {
    var h = try Harness.init(alloc, .{});
    defer h.deinit();

    // Enable extmark preedit mode (config.toml: ime.preedit_mode = "extmark").
    h.core.msg_config.ime.preedit_mode = .extmark;

    // Outside insert mode the frontend must draw the overlay itself.
    try h.waitMode("normal", h.opts.timeout_ms);
    try std.testing.expect(!h.core.setPreedit("x", 0, 0));

    // In insert mode the preedit is placed as an inline extmark.
    try h.input("i");
    try h.waitMode("insert", h.opts.timeout_ms);
    try std.testing.expect(h.core.setPreedit("あいう", 0, 0));

    // The virt_text extmark renders in the window grid at the cursor.
    const g = h.winGrid();
    try h.waitRowText(g, 0, "あいう", h.opts.timeout_ms);

    // Composition committed/cancelled: the extmark must disappear.
    h.core.clearPreedit();
    try h.waitRowText(g, 0, "", h.opts.timeout_ms);
}
