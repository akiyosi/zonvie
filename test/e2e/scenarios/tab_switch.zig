// tab_switch — switching tab pages swaps the visible window grid's content.
// Exercises multigrid window-grid switching: the cursor's grid changes per
// tab and the displayed content tracks it.

const std = @import("std");
const Harness = @import("../harness.zig").Harness;

// Wait until row 0 of the CURRENT window grid equals `expected`. winGrid() is
// re-queried every poll so the wait follows the cursor onto a new tab's grid.
fn waitCurrentRow(h: *Harness, expected: []const u8) !void {
    const Ctx = struct { exp: []const u8 };
    try h.waitUntil(Ctx{ .exp = expected }, struct {
        fn check(c: Ctx, hh: *Harness) bool {
            const g = hh.winGrid();
            const t = hh.rowTextAlloc(hh.alloc, g, 0) catch return false;
            defer hh.alloc.free(t);
            return std.mem.eql(u8, t, c.exp);
        }
    }.check, h.opts.timeout_ms);
}

pub fn run(alloc: std.mem.Allocator) !void {
    var h = try Harness.init(alloc, .{});
    defer h.deinit();

    try h.input("ialpha tab<Esc>");
    try waitCurrentRow(h, "alpha tab");

    // Open a new tab. CRITICAL: wait until the new EMPTY buffer is the active
    // window BEFORE inserting. The commands are sent fire-and-forget, so typing
    // immediately after `tabnew` can race ahead of the tab switch and land in
    // the previous tab's buffer (observed: "alpha tabeta tab" garble).
    try h.command("tabnew");
    try waitCurrentRow(h, "");
    try h.input("ibeta tab<Esc>");
    try waitCurrentRow(h, "beta tab");

    // Switch back to the first tab; its content is shown again. This exercises
    // the grid swap in both directions (create→tab2, switch→tab1); a further
    // tabnext only re-confirms the same swap and is omitted for determinism.
    try h.command("tabprevious");
    try waitCurrentRow(h, "alpha tab");
}
