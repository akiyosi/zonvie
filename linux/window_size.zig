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

/// What the state file holds: the size, logical px.
pub const Saved = struct { size: [2]c_int };

/// "W H". Null for a malformed size or one below the window's floor. What
/// follows the size is ignored: an older build wrote a position there.
pub fn parseState(text: []const u8) ?Saved {
    var it = std.mem.tokenizeAny(u8, text, " \t\r\n");
    const w = std.fmt.parseInt(c_int, it.next() orelse return null, 10) catch return null;
    const h = std.fmt.parseInt(c_int, it.next() orelse return null, 10) catch return null;
    if (w < 200 or h < 150 or w > 16384 or h > 16384) return null;
    return .{ .size = .{ w, h } };
}

/// The file's text for `s`, read back by parseState.
pub fn formatState(buf: []u8, s: Saved) ?[]const u8 {
    return std.fmt.bufPrint(buf, "{d} {d}\n", .{ s.size[0], s.size[1] }) catch null;
}

test "a remembered size is two numbers within bounds" {
    try std.testing.expectEqual([2]c_int{ 1000, 700 }, parseState("1000 700\n").?.size);
    try std.testing.expect(parseState("1000") == null);
    try std.testing.expect(parseState("10 700") == null);
    try std.testing.expect(parseState("a b") == null);
    // A position an older build wrote after the size.
    try std.testing.expectEqual([2]c_int{ 1000, 700 }, parseState("1000 700 -1200 40\n").?.size);
}

test "the state text reads back as written" {
    var buf: [48]u8 = undefined;
    const text = formatState(&buf, .{ .size = .{ 1000, 700 } }).?;
    try std.testing.expectEqualStrings("1000 700\n", text);
    try std.testing.expectEqual([2]c_int{ 1000, 700 }, parseState(text).?.size);
}

/// `px` device px at buffer scale `old`, as device px at scale `new`: the same
/// length on the glass, rounded down to a whole px. Pre: `old >= 1`,
/// `new >= 1`.
pub fn rescaledPx(px: u32, old: i32, new: i32) u32 {
    std.debug.assert(old >= 1 and new >= 1);
    return @intCast(@as(u64, px) * @as(u64, @intCast(new)) / @as(u64, @intCast(old)));
}

test "a length keeps its place on the glass across a scale change" {
    try std.testing.expectEqual(@as(u32, 1800), rescaledPx(900, 1, 2));
    try std.testing.expectEqual(@as(u32, 900), rescaledPx(1800, 2, 1));
    try std.testing.expectEqual(@as(u32, 450), rescaledPx(901, 2, 1));
    try std.testing.expectEqual(@as(u32, 1351), rescaledPx(901, 2, 3));
    try std.testing.expectEqual(@as(u32, 0), rescaledPx(0, 1, 2));
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
