// msg_ext_float_width_shrink — probe: does the ext_float message grid shrink
// back after a long message, or does the previous width persist?
//
// The macOS frontend right-aligns the float as
// `x = targetFrame.maxX - containerWidth - 10`
// (ZonvieCore.swift:6693), where containerWidth is derived entirely from the
// `cols` the core reports. So a stale `cols` is the only way a previous long
// message's geometry can survive into the next short one.
//
// Ordered signals: each width sample is taken only after the grid text proves
// the corresponding message is the one being displayed.

const std = @import("std");
const zc = @import("zonvie_core");
const Harness = @import("../harness.zig").Harness;

const msg_grid: i64 = -102;

// timeout = 0: the float never auto-hides, so both samples are observable.
var routes = [_]zc.config.MsgRoute{
    .{ .filter = .{ .event = .msg_show }, .view = .ext_float, .opts = .{ .timeout = 0 } },
};

fn gridHas(h: *Harness, needle: []const u8) bool {
    const size = h.subGridSize(msg_grid) orelse return false;
    var row: u32 = 0;
    while (row < size.rows) : (row += 1) {
        const text = h.rowTextAlloc(h.alloc, msg_grid, row) catch continue;
        defer h.alloc.free(text);
        if (std.mem.indexOf(u8, text, needle) != null) return true;
    }
    return false;
}

fn dumpGrid(h: *Harness, label: []const u8) void {
    const size = h.subGridSize(msg_grid) orelse {
        std.debug.print("[probe] {s}: no msg grid\n", .{label});
        return;
    };
    std.debug.print("[probe] {s}: {d}x{d}\n", .{ label, size.rows, size.cols });
    var row: u32 = 0;
    while (row < size.rows) : (row += 1) {
        const text = h.rowTextAlloc(h.alloc, msg_grid, row) catch continue;
        defer h.alloc.free(text);
        std.debug.print("[probe]   row{d} |{s}|\n", .{ row, text });
    }
}

pub fn run(alloc: std.mem.Allocator) !void {
    var h = try Harness.init(alloc, .{ .ext_messages = true, .msg_routes = &routes });
    defer h.deinit();

    // ── A long message sets the widest the float ever gets ─────────────
    try h.command("echo 'LONGMARK aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'");
    try h.waitUntil({}, struct {
        fn check(_: void, hh: *Harness) bool {
            return gridHas(hh, "LONGMARK") and hh.isExternalGrid(msg_grid);
        }
    }.check, h.opts.timeout_ms);
    const wide = h.subGridSize(msg_grid) orelse return error.NoMsgGrid;
    dumpGrid(h, "after long");

    // ── A short message must bring the float back down ─────────────────
    try h.command("echo 'SHORT'");
    try h.waitUntil({}, struct {
        fn check(_: void, hh: *Harness) bool {
            return gridHas(hh, "SHORT") and hh.isExternalGrid(msg_grid);
        }
    }.check, h.opts.timeout_ms);
    const narrow = h.subGridSize(msg_grid) orelse return error.NoMsgGrid;
    dumpGrid(h, "after short");

    // Only meaningful if the long message is genuinely gone: while both are
    // displayed the wide grid is correct, not stale.
    if (gridHas(h, "LONGMARK")) {
        std.debug.print("[probe] long message still displayed; width is legitimately wide\n", .{});
        return;
    }

    if (narrow.cols >= wide.cols) {
        std.debug.print(
            "[e2e] msg_ext_float_width_shrink: grid stayed {d} cols wide for a short message (long was {d})\n",
            .{ narrow.cols, wide.cols },
        );
        return error.MsgGridWidthDidNotShrink;
    }
}
