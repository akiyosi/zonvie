// linespace_geometry_persist — verify linespace is stored in core.
//
// Bug: onLinespace callback does not save linespace_px
// Fix: store clamped px value in core.linespace_px

const std = @import("std");
const Harness = @import("../harness.zig").Harness;

pub fn run(alloc: std.mem.Allocator) !void {
    var h = try Harness.init(alloc, .{ .rows = 24, .cols = 80 });
    defer h.deinit();

    // Wait for initial setup.
    try h.waitRowText(h.winGrid(), 0, "", h.opts.timeout_ms);

    // Verify initial linespace is 0 (default).
    h.core.grid_mu.lock();
    const initial_linespace = h.core.linespace_px;
    h.core.grid_mu.unlock();

    if (initial_linespace != 0) {
        std.debug.print("[e2e] linespace_geometry_persist: initial linespace should be 0, got {d}\n", .{initial_linespace});
        return error.InitialLinespaceNotZero;
    }

    // Set linespace via command.
    try h.command("set linespace=10");

    // Wait for callback to process.
    try h.waitRowText(h.winGrid(), 0, "", h.opts.timeout_ms);

    // Verify linespace_px was updated in core.
    h.core.grid_mu.lock();
    const after_linespace = h.core.linespace_px;
    h.core.grid_mu.unlock();

    if (after_linespace != 10) {
        std.debug.print("[e2e] linespace_geometry_persist: linespace not saved: expected 10 got {d}\n", .{after_linespace});
        return error.LinespaceNotPersisted;
    }
}
