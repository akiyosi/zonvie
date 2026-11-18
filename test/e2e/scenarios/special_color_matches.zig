// special_color_matches — each underline style keeps its own guisp.
//
// Five groups differing only in style and special colour are applied to
// five lines with matchaddpos; every cell must resolve to its own group's
// special colour, not the foreground. Exercises: hl_attr_define with
// `special`, attribute ids composed from a match over Normal.

const std = @import("std");
const Harness = @import("../harness.zig").Harness;

const Case = struct { group: []const u8, style: []const u8, sp: u32 };

const cases = [_]Case{
    .{ .group = "Curl", .style = "undercurl", .sp = 0xff5555 },
    .{ .group = "Ul", .style = "underline", .sp = 0x55ff55 },
    .{ .group = "Dbl", .style = "underdouble", .sp = 0x5555ff },
    .{ .group = "Dot", .style = "underdotted", .sp = 0xffff55 },
    .{ .group = "Dash", .style = "underdashed", .sp = 0xff55ff },
};

pub fn run(alloc: std.mem.Allocator) !void {
    var h = try Harness.init(alloc, .{});
    defer h.deinit();

    try h.command("hi Normal guifg=#d0d0d0 guibg=#1e1e2e");
    var buf: [128]u8 = undefined;
    for (cases) |c| {
        try h.command(try std.fmt.bufPrint(&buf, "hi {s} gui={s} guisp=#{x:0>6}", .{ c.group, c.style, c.sp }));
    }
    try h.command("call setline(1, ['curl', 'ul', 'dbl', 'dot', 'dash'])");
    for (cases, 1..) |c, line| {
        try h.command(try std.fmt.bufPrint(&buf, "call matchaddpos('{s}', [{d}])", .{ c.group, line }));
    }

    const g = h.winGrid();
    try h.waitRowText(g, 4, "dash", h.opts.timeout_ms);
    // The last match lands in a later redraw than the text.
    const Ctx = struct { g: i64 };
    try h.waitUntil(Ctx{ .g = g }, struct {
        fn check(ctx: Ctx, hh: *Harness) bool {
            return hh.hlAt(ctx.g, 4, 0).sp == cases[4].sp;
        }
    }.check, h.opts.timeout_ms);

    for (cases, 0..) |c, row| {
        const a = h.hlAt(g, @intCast(row), 0);
        if (a.sp != c.sp) {
            std.debug.print("[e2e] special_color_matches: row {d} ({s}) sp=0x{x:0>6}, want 0x{x:0>6}\n", .{ row, c.group, a.sp, c.sp });
            return error.WrongSpecialColor;
        }
    }
}
