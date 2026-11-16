//! The window's size from one run to the next: a state file with the size
//! the toplevel had when it was last free to choose it. main.zig reads it
//! for the size a compositor leaves to the client, and writes it on exit.

const std = @import("std");
const core = @import("zonvie_core");
const clock = core.clock;
const applog = @import("app_log.zig");

/// `$XDG_STATE_HOME/zonvie/window` (else `~/.local/state/zonvie/window`).
fn statePath(buf: []u8) ?[:0]const u8 {
    if (std.c.getenv("XDG_STATE_HOME")) |d| return std.fmt.bufPrintZ(buf, "{s}/zonvie/window", .{std.mem.span(d)}) catch null;
    const home = std.c.getenv("HOME") orelse return null;
    return std.fmt.bufPrintZ(buf, "{s}/.local/state/zonvie/window", .{std.mem.span(home)}) catch null;
}

/// What the state file holds: the size, logical px. A position after it is
/// read and kept for files an X11 build wrote; nothing here sets one.
pub const Saved = struct {
    size: [2]c_int,
    pos: ?[2]i32 = null,
};

/// "W H" or "W H X Y". Null for a malformed size or one below the window's
/// floor; a malformed or absent position leaves `pos` null.
pub fn parseState(text: []const u8) ?Saved {
    var it = std.mem.tokenizeAny(u8, text, " \t\r\n");
    const w = std.fmt.parseInt(c_int, it.next() orelse return null, 10) catch return null;
    const h = std.fmt.parseInt(c_int, it.next() orelse return null, 10) catch return null;
    if (w < 200 or h < 150 or w > 16384 or h > 16384) return null;
    var s: Saved = .{ .size = .{ w, h } };
    const xs = it.next() orelse return s;
    const ys = it.next() orelse return s;
    const x = std.fmt.parseInt(i32, xs, 10) catch return s;
    const y = std.fmt.parseInt(i32, ys, 10) catch return s;
    if (@abs(x) > 1 << 20 or @abs(y) > 1 << 20) return s;
    s.pos = .{ x, y };
    return s;
}

/// The file's text for `s`, read back by parseState.
pub fn formatState(buf: []u8, s: Saved) ?[]const u8 {
    if (s.pos) |p| return std.fmt.bufPrint(buf, "{d} {d} {d} {d}\n", .{ s.size[0], s.size[1], p[0], p[1] }) catch null;
    return std.fmt.bufPrint(buf, "{d} {d}\n", .{ s.size[0], s.size[1] }) catch null;
}

test "a remembered size is two numbers within bounds" {
    try std.testing.expectEqual([2]c_int{ 1000, 700 }, parseState("1000 700\n").?.size);
    try std.testing.expect(parseState("1000 700\n").?.pos == null);
    try std.testing.expect(parseState("1000") == null);
    try std.testing.expect(parseState("10 700") == null);
    try std.testing.expect(parseState("a b") == null);
}

test "a remembered position follows the size and may be negative" {
    const s = parseState("1000 700 -1200 40\n").?;
    try std.testing.expectEqual([2]c_int{ 1000, 700 }, s.size);
    try std.testing.expectEqual([2]i32{ -1200, 40 }, s.pos.?);
    // A broken position keeps the size.
    try std.testing.expect(parseState("1000 700 5").?.pos == null);
    try std.testing.expect(parseState("1000 700 x 5").?.pos == null);
    try std.testing.expect(parseState("1000 700 99999999 5").?.pos == null);
}

test "the state text reads back as written" {
    var buf: [48]u8 = undefined;
    const with_pos: Saved = .{ .size = .{ 1000, 700 }, .pos = .{ 30, -4 } };
    try std.testing.expectEqualStrings("1000 700 30 -4\n", formatState(&buf, with_pos).?);
    try std.testing.expectEqual(with_pos.pos.?, parseState(formatState(&buf, with_pos).?).?.pos.?);
    try std.testing.expectEqualStrings("1000 700\n", formatState(&buf, .{ .size = .{ 1000, 700 } }).?);
}

/// What the last run closed with.
pub fn restored() ?Saved {
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const path = statePath(&pbuf) orelse return null;
    var buf: [64]u8 = undefined;
    const io = clock.io();
    const f = std.Io.Dir.openFileAbsolute(io, path, .{}) catch return null;
    defer f.close(io);
    var r = f.reader(io, &.{});
    const n = r.interface.readSliceShort(&buf) catch return null;
    return parseState(buf[0..n]);
}

/// Writes the state file. Names no toolkit: the Wayland backend calls it
/// with its toplevel's size.
pub fn store(s: Saved) void {
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const path = statePath(&pbuf) orelse return;
    const io = clock.io();
    if (std.fs.path.dirname(path)) |dir| std.Io.Dir.cwd().createDirPath(io, dir) catch return;
    const f = std.Io.Dir.createFileAbsolute(io, path, .{}) catch return;
    defer f.close(io);
    var buf: [48]u8 = undefined;
    const text = formatState(&buf, s) orelse return;
    f.writeStreamingAll(io, text) catch {};
    applog.appLog("[window_state] saved {s}", .{text});
}
