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

    // Wait for the linespace option_set event to propagate into the core.
    // Waiting on an already-empty row would return immediately, before the
    // event is processed — a race that read the stale value of 0.
    h.waitUntil({}, struct {
        fn check(_: void, hh: *Harness) bool {
            hh.core.grid_mu.lock();
            defer hh.core.grid_mu.unlock();
            return hh.core.linespace_px == 10;
        }
    }.check, h.opts.timeout_ms) catch {
        h.core.grid_mu.lock();
        const got = h.core.linespace_px;
        h.core.grid_mu.unlock();
        std.debug.print("[e2e] linespace_geometry_persist: linespace not saved: expected 10 got {d}\n", .{got});
        return error.LinespaceNotPersisted;
    };
}
