// search_highlight — 'hlsearch' applies the Search highlight to matched
// cells. Exercises hl-id resolution into per-cell attributes (the path that
// turns a grid_line hl id into fg/bg), which the bare highlight_change
// scenario does not cover in a rendered context.

const std = @import("std");
const Harness = @import("../harness.zig").Harness;

pub fn run(alloc: std.mem.Allocator) !void {
    var h = try Harness.init(alloc, .{});
    defer h.deinit();

    try h.command("set hlsearch");
    try h.input("ifoo bar foo<Esc>");
    const g = h.winGrid();
    try h.waitRowText(g, 0, "foo bar foo", h.opts.timeout_ms);

    // Search; the second "foo" (col 8) becomes a Search match, "bar" (col 4)
    // stays unhighlighted. Assert the matched cell's bg differs.
    try h.input("gg0/foo<CR>");
    const Ctx = struct { g: i64 };
    h.waitUntil(Ctx{ .g = g }, struct {
        fn check(c: Ctx, hh: *Harness) bool {
            return hh.hlAt(c.g, 0, 8).bg != hh.hlAt(c.g, 0, 4).bg;
        }
    }.check, h.opts.timeout_ms) catch {
        std.debug.print(
            "[e2e] search_highlight: matched bg {x} == unmatched bg {x}\n",
            .{ h.hlAt(g, 0, 8).bg, h.hlAt(g, 0, 4).bg },
        );
        return error.SearchNotHighlighted;
    };
}
