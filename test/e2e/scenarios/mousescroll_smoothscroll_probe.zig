// Probe: with 'smoothscroll' on a wrapped buffer, does one wheel event move
// 'ver' BUFFER lines (the unit mismatch survives) or 'ver' SCREEN rows (it
// disappears)? Decides whether turning 'smoothscroll' on for the duration of a
// trackpad gesture would fix the wrapped-line jump.

const std = @import("std");
const Harness = @import("../harness.zig").Harness;

const VER: u32 = 3;

pub fn run(alloc: std.mem.Allocator) !void {
    var h = try Harness.init(alloc, .{});
    defer h.deinit();

    const g = h.winGrid();
    const size = h.subGridSize(g) orelse return error.GridNotFound;
    const line_len = @as(usize, size.cols) * 3 + size.cols / 2;
    const line = try alloc.alloc(u8, line_len);
    defer alloc.free(line);
    @memset(line, 'x');

    try h.command("set mouse=a wrap");
    var buf: [64]u8 = undefined;
    try h.command(try std.fmt.bufPrint(&buf, "set mousescroll=ver:{d},hor:6", .{VER}));

    var i: usize = 0;
    while (i < 200) : (i += 1) {
        const cmd = try std.fmt.allocPrint(alloc, "call setline({d}, '{d} {s}')", .{ i + 1, i + 1, line });
        defer alloc.free(cmd);
        try h.command(cmd);
    }

    try report(h, g, "nosmoothscroll");
    try report(h, g, "smoothscroll");
}

fn report(h: *Harness, g: i64, mode: []const u8) !void {
    var buf: [64]u8 = undefined;
    try h.command(try std.fmt.bufPrint(&buf, "set {s}", .{mode}));
    try h.command("normal! 100Gzt");
    try settle(h);
    const before = h.getViewportTop(g);
    _ = h.grid_scrolls.swap(0, .seq_cst);
    _ = h.grid_scroll_rows.swap(0, .seq_cst);
    _ = h.takeUncoveredScrollRows(g);

    h.wheel(g, "down");
    try settle(h);

    std.debug.print(
        "[probe:{s}] topline {d}->{d} (buffer lines {d}); grid_scroll x{d} totalling {d} rows; uncovered {d}\n",
        .{
            mode,
            before,
            h.getViewportTop(g),
            @as(i64, h.getViewportTop(g)) - @as(i64, before),
            h.grid_scrolls.load(.seq_cst),
            h.grid_scroll_rows.load(.seq_cst),
            h.takeUncoveredScrollRows(g),
        },
    );
}

/// No single event to key on across both modes, so wait for the flush stream to
/// go quiet instead.
fn settle(h: *Harness) !void {
    var last: u64 = 0;
    var stable: usize = 0;
    while (stable < 5) {
        const now = h.flush_seq.load(.seq_cst);
        if (now == last) stable += 1 else stable = 0;
        last = now;
        const Ctx = struct { target: u64 };
        h.waitUntil(Ctx{ .target = now + 1 }, struct {
            fn check(c: Ctx, hh: *Harness) bool {
                return hh.flush_seq.load(.seq_cst) >= c.target;
            }
        }.check, 60) catch {};
    }
}
