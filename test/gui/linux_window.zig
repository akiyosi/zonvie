// linux_window.zig — observe the app's windows on Linux. Counterpart to
// macos_window.zig and windows_window.zig.
//
// Wayland gives a client no view of other clients' windows, so this asks the
// compositor: Hyprland's IPC (`hyprctl -j clients`), the session these tests
// run under. `available` is false elsewhere, and the runner skips.
//
// A window's `number` is Hyprland's stableId, which increases with every
// window the compositor maps, so the app's main window is the one with the
// smallest. Bounds are logical px, as Hyprland reports them.
//
// Test-only code: heap allocation is fine here.

const std = @import("std");
const gui_io = @import("gui_io.zig");

pub const Bounds = struct { x: f64, y: f64, w: f64, h: f64 };
pub const MainWindow = struct { number: u32, bounds: Bounds };

/// Whether a Hyprland session is reachable.
pub fn available() bool {
    return std.c.getenv("HYPRLAND_INSTANCE_SIGNATURE") != null;
}

const Client = struct {
    pid: i64,
    stable_id: u32,
    /// Lower is more recently focused: Hyprland's focusHistoryID.
    focus_rank: i64,
    bounds: Bounds,
};

/// Every mapped, unhidden client of `pid`, unordered. Empty when the IPC
/// cannot be reached.
fn clients(alloc: std.mem.Allocator, pid: i32, out: []Client) usize {
    const result = std.process.run(alloc, gui_io.io(), .{
        .argv = &.{ "hyprctl", "-j", "clients" },
    }) catch return 0;
    defer alloc.free(result.stdout);
    defer alloc.free(result.stderr);
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, result.stdout, .{}) catch return 0;
    defer parsed.deinit();
    if (parsed.value != .array) return 0;
    var n: usize = 0;
    for (parsed.value.array.items) |c| {
        if (n == out.len) break;
        if (c != .object) continue;
        const o = c.object;
        const cpid = (o.get("pid") orelse continue).integer;
        if (cpid != pid) continue;
        if (!(o.get("mapped") orelse continue).bool) continue;
        if ((o.get("hidden") orelse continue).bool) continue;
        const at = (o.get("at") orelse continue).array.items;
        const size = (o.get("size") orelse continue).array.items;
        const sid_str = (o.get("stableId") orelse continue).string;
        out[n] = .{
            .pid = cpid,
            .stable_id = std.fmt.parseInt(u32, sid_str, 16) catch continue,
            .focus_rank = (o.get("focusHistoryID") orelse continue).integer,
            .bounds = .{
                .x = @floatFromInt(at[0].integer),
                .y = @floatFromInt(at[1].integer),
                .w = @floatFromInt(size[0].integer),
                .h = @floatFromInt(size[1].integer),
            },
        };
        n += 1;
    }
    return n;
}

fn byFocus(_: void, a: Client, b: Client) bool {
    return a.focus_rank < b.focus_rank;
}

pub fn windowCountForPid(pid: i32) u32 {
    var buf: [32]Client = undefined;
    return @intCast(clients(std.heap.page_allocator, pid, &buf));
}

/// The app's windows, most recently focused first: the nearest Hyprland
/// has to a stacking order.
pub fn windowsForPid(pid: i32, out: []MainWindow) usize {
    var buf: [32]Client = undefined;
    const n = clients(std.heap.page_allocator, pid, &buf);
    std.mem.sort(Client, buf[0..n], {}, byFocus);
    const m = @min(n, out.len);
    for (buf[0..m], out[0..m]) |c, *o| o.* = .{ .number = c.stable_id, .bounds = c.bounds };
    return m;
}

pub fn mainWindowForPid(pid: i32) ?MainWindow {
    var buf: [32]Client = undefined;
    const n = clients(std.heap.page_allocator, pid, &buf);
    if (n == 0) return null;
    var main = buf[0];
    for (buf[1..n]) |c| {
        if (c.stable_id < main.stable_id) main = c;
    }
    return .{ .number = main.stable_id, .bounds = main.bounds };
}

pub fn mainWindowBoundsForPid(pid: i32) ?Bounds {
    return (mainWindowForPid(pid) orelse return null).bounds;
}

/// The bounds of window `number` of any client, or null once it is gone.
pub fn boundsOf(number: u32) ?Bounds {
    const alloc = std.heap.page_allocator;
    const result = std.process.run(alloc, gui_io.io(), .{ .argv = &.{ "hyprctl", "-j", "clients" } }) catch return null;
    defer alloc.free(result.stdout);
    defer alloc.free(result.stderr);
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, result.stdout, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .array) return null;
    for (parsed.value.array.items) |c| {
        if (c != .object) continue;
        const o = c.object;
        const sid = std.fmt.parseInt(u32, (o.get("stableId") orelse continue).string, 16) catch continue;
        if (sid != number) continue;
        const at = o.get("at").?.array.items;
        const size = o.get("size").?.array.items;
        return .{
            .x = @floatFromInt(at[0].integer),
            .y = @floatFromInt(at[1].integer),
            .w = @floatFromInt(size[0].integer),
            .h = @floatFromInt(size[1].integer),
        };
    }
    return null;
}

/// The compositor places windows (tiled or not) and gives a client no say;
/// nothing to pin. Captures are of the window's own region, so its origin
/// does not change the pixels.
pub fn pinWindow(pid: i32, x: i32, y: i32) void {
    _ = pid;
    _ = x;
    _ = y;
}

/// The Linux renderer draws every committed row each frame, so there is no
/// partial-redraw state to reset.
pub fn forceFullRedraw(pid: i32) void {
    _ = pid;
}

pub fn dumpWindowsForPid(pid: i32) void {
    var buf: [32]Client = undefined;
    const n = clients(std.heap.page_allocator, pid, &buf);
    std.debug.print("[gui] windows of pid {d}: {d}\n", .{ pid, n });
    for (buf[0..n]) |c| std.debug.print("[gui]   stableId={x} focus={d} at=({d:.0},{d:.0}) size={d:.0}x{d:.0}\n", .{ c.stable_id, c.focus_rank, c.bounds.x, c.bounds.y, c.bounds.w, c.bounds.h });
}
