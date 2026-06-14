// grid_resize_artifact — resizing a split window updates its grid dimensions
// and preserves buffer content (no stale cells / lost text).
// Note: general frontend robustness test; not derived from a specific
// upstream issue. (A prior header cited Goneovim #582, which is actually
// "text invisible while composing with IME (CorvusSKK)" — unrelated.)

const std = @import("std");
const Harness = @import("../harness.zig").Harness;

pub fn run(alloc: std.mem.Allocator) !void {
    var h = try Harness.init(alloc, .{});
    defer h.deinit();

    // Put known content in the buffer. The window grid is a sub-grid (>= 2)
    // under ext_multigrid; grid 1 is the global grid and is NOT in sub_grids,
    // so query the cursor's grid via winGrid().
    try h.input("iline one<Esc>");
    const g0 = h.winGrid();
    try h.waitRowText(g0, 0, "line one", h.opts.timeout_ms);

    const initial = h.subGridSize(g0) orelse return error.WindowGridNotFound;
    try std.testing.expect(initial.rows > 0 and initial.cols > 0);

    // A horizontal split shrinks the focused window's grid height. Re-query
    // winGrid() inside the predicate: cursor_grid can update a beat after the
    // split command, so capturing it eagerly may read the pre-split grid.
    try h.command("split");
    {
        const Ctx = struct { max: u32 };
        try h.waitUntil(Ctx{ .max = initial.rows }, struct {
            fn check(c: Ctx, hh: *Harness) bool {
                const s = hh.subGridSize(hh.winGrid()) orelse return false;
                return s.rows < c.max;
            }
        }.check, h.opts.timeout_ms);
    }
    const g1 = h.winGrid();
    const after_split = h.subGridSize(g1) orelse return error.WindowGridNotFound;

    // Growing the window must increase its grid height again.
    try h.command("resize +3");
    {
        const Ctx = struct { g: i64, base: u32 };
        try h.waitUntil(Ctx{ .g = g1, .base = after_split.rows }, struct {
            fn check(c: Ctx, hh: *Harness) bool {
                const s = hh.subGridSize(c.g) orelse return false;
                return s.rows > c.base;
            }
        }.check, h.opts.timeout_ms);
    }

    // Buffer content is still intact in the focused window after resizing.
    try h.waitRowText(g1, 0, "line one", h.opts.timeout_ms);
}
