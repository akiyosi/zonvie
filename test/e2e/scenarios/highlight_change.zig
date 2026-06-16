// highlight_change — :hi Normal updates default colors; a text cell
// resolves to them through the highlight map.
// Exercises: default_colors_set, hl_attr_define resolution.

const std = @import("std");
const Harness = @import("../harness.zig").Harness;

pub fn run(alloc: std.mem.Allocator) !void {
    var h = try Harness.init(alloc, .{});
    defer h.deinit();

    try h.command("hi Normal guifg=#445566 guibg=#112233");

    // Changing Normal triggers default_colors_set; hl id 0 resolves to it.
    try h.waitUntil({}, struct {
        fn check(_: void, hh: *Harness) bool {
            const a = hh.hlOf(0);
            return a.fg == 0x445566 and a.bg == 0x112233;
        }
    }.check, h.opts.timeout_ms);

    // A plain text cell written after the change resolves to the new colors.
    try h.input("ix<Esc>");
    const g = h.winGrid();
    try h.waitRowText(g, 0, "x", h.opts.timeout_ms);
    const a = h.hlAt(g, 0, 0);
    try std.testing.expectEqual(@as(u32, 0x445566), a.fg);
    try std.testing.expectEqual(@as(u32, 0x112233), a.bg);
}
