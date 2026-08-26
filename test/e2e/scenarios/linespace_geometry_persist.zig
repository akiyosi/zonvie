// linespace_geometry_persist — verify linespace is stored in core.
//
// Bug 1: onLinespace callback does not save linespace_px.
// Bug 2: negative values (legal per Neovim's 'linespace' docs, for fonts that
// leave too much room between lines) were clamped to 0 in the option_set
// parser, so the setting silently never reached the core or the frontends.

const std = @import("std");
const Harness = @import("../harness.zig").Harness;
const zc = @import("zonvie_core");

pub fn run(alloc: std.mem.Allocator) !void {
    var h = try Harness.init(alloc, .{ .rows = 24, .cols = 80 });
    defer h.deinit();

    // Wait for initial setup.
    try h.waitRowText(h.winGrid(), 0, "", h.opts.timeout_ms);

    // Verify initial linespace is 0 (default).
    h.core.grid_mu.lockUncancelable(zc.clock.io());
    const initial_linespace = h.core.linespace_px;
    h.core.grid_mu.unlock(zc.clock.io());

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
            hh.core.grid_mu.lockUncancelable(zc.clock.io());
            defer hh.core.grid_mu.unlock(zc.clock.io());
            return hh.core.linespace_px == 10;
        }
    }.check, h.opts.timeout_ms) catch {
        h.core.grid_mu.lockUncancelable(zc.clock.io());
        const got = h.core.linespace_px;
        h.core.grid_mu.unlock(zc.clock.io());
        std.debug.print("[e2e] linespace_geometry_persist: linespace not saved: expected 10 got {d}\n", .{got});
        return error.LinespaceNotPersisted;
    };

    // A negative value must arrive unclamped: this pins the full wire path
    // (option_set parse -> onLinespace -> core field) that used to zero it.
    try h.command("set linespace=-5");

    h.waitUntil({}, struct {
        fn check(_: void, hh: *Harness) bool {
            hh.core.grid_mu.lockUncancelable(zc.clock.io());
            defer hh.core.grid_mu.unlock(zc.clock.io());
            return hh.core.linespace_px == -5;
        }
    }.check, h.opts.timeout_ms) catch {
        h.core.grid_mu.lockUncancelable(zc.clock.io());
        const got = h.core.linespace_px;
        h.core.grid_mu.unlock(zc.clock.io());
        std.debug.print("[e2e] linespace_geometry_persist: negative linespace clamped: expected -5 got {d}\n", .{got});
        return error.NegativeLinespaceClamped;
    };
}
