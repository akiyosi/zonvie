// guifont_init_order — verify guifont callback order and no crash.
//
// Bug: emitGuiFont() before resetCoreAtlas() → null atlas_packer crash
// Fix: resetCoreAtlas() must come BEFORE emitGuiFont()

const std = @import("std");
const Harness = @import("../harness.zig").Harness;

pub fn run(alloc: std.mem.Allocator) !void {
    var h = try Harness.init(alloc, .{});
    defer h.deinit();

    // Wait for initial setup.
    try h.waitRowText(h.winGrid(), 0, "", h.opts.timeout_ms);

    // Change guifont at runtime to trigger the callback sequence.
    // If the order is wrong (emitGuiFont before resetCoreAtlas),
    // the frontend callback may try to use atlas_packer which is null.
    try h.command("set guifont=Monospace:h14");

    // This should complete without crash. If we reach here, callback ordering
    // was correct and atlas was reset before the callback fired.
    try h.waitRowText(h.winGrid(), 0, "", h.opts.timeout_ms);

    // Verify core is still functional.
    h.core.grid_mu.lock();
    const rows = h.core.grid.rows;
    h.core.grid_mu.unlock();

    if (rows == 0) {
        return error.GridBroken;
    }
}
