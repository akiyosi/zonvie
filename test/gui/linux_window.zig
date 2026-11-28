// linux_window.zig — observe the app's windows on Linux. Counterpart to
// macos_window.zig and windows_window.zig.
//
// Wayland gives a client no view of other clients' windows, so this asks the
// compositor over its IPC: Hyprland's (`hyprctl -j clients`), the session
// these tests run under locally, or sway's (`swaymsg -t get_tree`), which CI
// runs headless. `available` is false under any other session, and the
// runner skips.
//
// A window's `number` grows with every window the compositor maps
// (Hyprland's stableId, sway's container id), so the app's main window is
// the one with the smallest. Bounds are logical px, as both report them.
//
// Test-only code: heap allocation is fine here.

const std = @import("std");
const gui_io = @import("gui_io.zig");
const linux_pointer = @import("linux_pointer.zig");

pub const Bounds = struct { x: f64, y: f64, w: f64, h: f64 };
pub const MainWindow = struct { number: u32, bounds: Bounds };

const Compositor = enum { hyprland, sway };

fn compositor() ?Compositor {
    if (std.c.getenv("HYPRLAND_INSTANCE_SIGNATURE") != null) return .hyprland;
    if (std.c.getenv("SWAYSOCK") != null) return .sway;
    return null;
}

/// Whether a compositor this driver can ask is reachable.
pub fn available() bool {
    return compositor() != null;
}

const Client = struct {
    pid: i64,
    number: u32,
    /// Lower is more recently focused.
    focus_rank: i64,
    bounds: Bounds,
    title_buf: [256]u8 = undefined,
    title_len: usize = 0,

    fn title(c: *const Client) []const u8 {
        return c.title_buf[0..c.title_len];
    }

    fn setTitle(c: *Client, t: []const u8) void {
        c.title_len = @min(t.len, c.title_buf.len);
        @memcpy(c.title_buf[0..c.title_len], t[0..c.title_len]);
    }
};

fn runJson(alloc: std.mem.Allocator, argv: []const []const u8) ?std.json.Parsed(std.json.Value) {
    const result = std.process.run(alloc, gui_io.io(), .{ .argv = argv }) catch return null;
    defer alloc.free(result.stdout);
    defer alloc.free(result.stderr);
    return std.json.parseFromSlice(std.json.Value, alloc, result.stdout, .{ .allocate = .alloc_always }) catch null;
}

fn int(v: ?std.json.Value) ?i64 {
    return switch (v orelse return null) {
        .integer => |i| i,
        .float => |f| @intFromFloat(f),
        else => null,
    };
}

/// Every mapped, visible client, or those of `pid` when given, unordered.
/// Empty when the IPC cannot be reached.
fn clients(alloc: std.mem.Allocator, pid: ?i32, out: []Client) usize {
    return switch (compositor() orelse return 0) {
        .hyprland => hyprClients(alloc, pid, out),
        .sway => swayClients(alloc, pid, out),
    };
}

fn hyprClients(alloc: std.mem.Allocator, pid: ?i32, out: []Client) usize {
    const parsed = runJson(alloc, &.{ "hyprctl", "-j", "clients" }) orelse return 0;
    defer parsed.deinit();
    if (parsed.value != .array) return 0;
    var n: usize = 0;
    for (parsed.value.array.items) |c| {
        if (n == out.len) break;
        if (c != .object) continue;
        const o = c.object;
        const cpid = int(o.get("pid")) orelse continue;
        if (pid) |p| if (cpid != p) continue;
        if (!(o.get("mapped") orelse continue).bool) continue;
        if ((o.get("hidden") orelse continue).bool) continue;
        const at = (o.get("at") orelse continue).array.items;
        const size = (o.get("size") orelse continue).array.items;
        const sid_str = (o.get("stableId") orelse continue).string;
        out[n] = .{
            .pid = cpid,
            .number = std.fmt.parseInt(u32, sid_str, 16) catch continue,
            .focus_rank = int(o.get("focusHistoryID")) orelse continue,
            .bounds = .{
                .x = @floatFromInt(at[0].integer),
                .y = @floatFromInt(at[1].integer),
                .w = @floatFromInt(size[0].integer),
                .h = @floatFromInt(size[1].integer),
            },
        };
        if (o.get("title")) |t| if (t == .string) out[n].setTitle(t.string);
        n += 1;
    }
    return n;
}

const SwayWalk = struct {
    pid: ?i32,
    out: []Client,
    n: usize = 0,
    /// Order of the walk: it follows every container's `focus` list, most
    /// recently focused child first, so a view met earlier was focused later.
    rank: i64 = 0,

    fn visit(w: *SwayWalk, node: std.json.Value) void {
        if (node != .object) return;
        const o = node.object;
        if (int(o.get("pid"))) |cpid| {
            w.view(o, cpid);
            return;
        }
        // Children in focus order, then any the focus list does not name.
        var seen: [64]i64 = undefined;
        var n_seen: usize = 0;
        if (o.get("focus")) |f| if (f == .array) for (f.array.items) |id_v| {
            const id = int(id_v) orelse continue;
            if (w.visitChildWithId(o, id) and n_seen < seen.len) {
                seen[n_seen] = id;
                n_seen += 1;
            }
        };
        for ([_][]const u8{ "nodes", "floating_nodes" }) |key| {
            const kids = o.get(key) orelse continue;
            if (kids != .array) continue;
            for (kids.array.items) |k| {
                const kid = int(if (k == .object) k.object.get("id") else null) orelse continue;
                if (std.mem.indexOfScalar(i64, seen[0..n_seen], kid) != null) continue;
                w.visit(k);
            }
        }
    }

    fn visitChildWithId(w: *SwayWalk, o: std.json.ObjectMap, id: i64) bool {
        for ([_][]const u8{ "nodes", "floating_nodes" }) |key| {
            const kids = o.get(key) orelse continue;
            if (kids != .array) continue;
            for (kids.array.items) |k| {
                if (k != .object) continue;
                if (int(k.object.get("id")) != id) continue;
                w.visit(k);
                return true;
            }
        }
        return false;
    }

    fn view(w: *SwayWalk, o: std.json.ObjectMap, cpid: i64) void {
        defer w.rank += 1;
        if (w.n == w.out.len) return;
        if (w.pid) |p| if (cpid != p) return;
        if (o.get("visible")) |v| if (v == .bool and !v.bool) return;
        const rect = (o.get("rect") orelse return).object;
        const win = (o.get("window_rect") orelse return).object;
        // `window_rect` is the surface inside the container, relative to it:
        // what Hyprland's at/size is, without border or title bar.
        w.out[w.n] = .{
            .pid = cpid,
            .number = @intCast(int(o.get("id")) orelse return),
            .focus_rank = w.rank,
            .bounds = .{
                .x = @floatFromInt((int(rect.get("x")) orelse return) + (int(win.get("x")) orelse 0)),
                .y = @floatFromInt((int(rect.get("y")) orelse return) + (int(win.get("y")) orelse 0)),
                .w = @floatFromInt(int(win.get("width")) orelse return),
                .h = @floatFromInt(int(win.get("height")) orelse return),
            },
        };
        if (o.get("name")) |t| if (t == .string) w.out[w.n].setTitle(t.string);
        w.n += 1;
    }
};

fn swayClients(alloc: std.mem.Allocator, pid: ?i32, out: []Client) usize {
    const parsed = runJson(alloc, &.{ "swaymsg", "-r", "-t", "get_tree" }) orelse return 0;
    defer parsed.deinit();
    var w: SwayWalk = .{ .pid = pid, .out = out };
    w.visit(parsed.value);
    return w.n;
}

fn byFocus(_: void, a: Client, b: Client) bool {
    return a.focus_rank < b.focus_rank;
}

pub fn windowCountForPid(pid: i32) u32 {
    var buf: [32]Client = undefined;
    return @intCast(clients(std.heap.page_allocator, pid, &buf));
}

/// The app's windows, most recently focused first: the nearest a tiling
/// compositor has to a stacking order.
pub fn windowsForPid(pid: i32, out: []MainWindow) usize {
    var buf: [32]Client = undefined;
    const n = clients(std.heap.page_allocator, pid, &buf);
    std.mem.sort(Client, buf[0..n], {}, byFocus);
    const m = @min(n, out.len);
    for (buf[0..m], out[0..m]) |c, *o| o.* = .{ .number = c.number, .bounds = c.bounds };
    return m;
}

pub fn mainWindowForPid(pid: i32) ?MainWindow {
    var buf: [32]Client = undefined;
    const n = clients(std.heap.page_allocator, pid, &buf);
    if (n == 0) return null;
    var main = buf[0];
    for (buf[1..n]) |c| {
        if (c.number < main.number) main = c;
    }
    return .{ .number = main.number, .bounds = main.bounds };
}

pub fn mainWindowBoundsForPid(pid: i32) ?Bounds {
    return (mainWindowForPid(pid) orelse return null).bounds;
}

/// The bounds of window `number` of any client, or null once it is gone.
pub fn boundsOf(number: u32) ?Bounds {
    var buf: [64]Client = undefined;
    const n = clients(std.heap.page_allocator, null, &buf);
    for (buf[0..n]) |c| if (c.number == number) return c.bounds;
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

/// Ask an app launched with ZONVIE_TEST_FULL_REDRAW=1 to draw its main
/// window whole on the next frame (linux/main.zig onTestFullRedraw).
pub fn forceFullRedraw(pid: i32) void {
    std.posix.kill(pid, std.posix.SIG.USR2) catch {};
}

pub fn dumpWindowsForPid(pid: i32) void {
    var buf: [32]Client = undefined;
    const n = clients(std.heap.page_allocator, pid, &buf);
    std.debug.print("[gui] windows of pid {d}: {d}\n", .{ pid, n });
    for (buf[0..n]) |c| std.debug.print("[gui]   number={x} focus={d} at=({d:.0},{d:.0}) size={d:.0}x{d:.0}\n", .{ c.number, c.focus_rank, c.bounds.x, c.bounds.y, c.bounds.w, c.bounds.h });
}

/// The output layout's extent in logical px: what a virtual pointer's
/// absolute positions are relative to.
fn layoutExtent() ?[2]u32 {
    const alloc = std.heap.page_allocator;
    const comp = compositor() orelse return null;
    const parsed = switch (comp) {
        .hyprland => runJson(alloc, &.{ "hyprctl", "-j", "monitors" }),
        .sway => runJson(alloc, &.{ "swaymsg", "-r", "-t", "get_outputs" }),
    } orelse return null;
    defer parsed.deinit();
    if (parsed.value != .array) return null;
    var w: f64 = 0;
    var h: f64 = 0;
    for (parsed.value.array.items) |m| {
        if (m != .object) continue;
        const o = m.object;
        switch (comp) {
            .hyprland => {
                const scale = switch (o.get("scale") orelse continue) {
                    .float => |f| f,
                    .integer => |i| @as(f64, @floatFromInt(i)),
                    else => continue,
                };
                const x: f64 = @floatFromInt(int(o.get("x")) orelse continue);
                const y: f64 = @floatFromInt(int(o.get("y")) orelse continue);
                const mw: f64 = @floatFromInt(int(o.get("width")) orelse continue);
                const mh: f64 = @floatFromInt(int(o.get("height")) orelse continue);
                w = @max(w, x + mw / scale);
                h = @max(h, y + mh / scale);
            },
            // sway's output rect is already in layout (logical) px.
            .sway => {
                const r = (o.get("rect") orelse continue).object;
                const x: f64 = @floatFromInt(int(r.get("x")) orelse continue);
                const y: f64 = @floatFromInt(int(r.get("y")) orelse continue);
                w = @max(w, x + @as(f64, @floatFromInt(int(r.get("width")) orelse continue)));
                h = @max(h, y + @as(f64, @floatFromInt(int(r.get("height")) orelse continue)));
            },
        }
    }
    if (w <= 0 or h <= 0) return null;
    return .{ @intFromFloat(@round(w)), @intFromFloat(@round(h)) };
}

/// A virtual pointer over the whole output layout, or null when the
/// compositor offers none (the scenario then skips).
pub fn pointer() ?linux_pointer.Pointer {
    const e = layoutExtent() orelse return null;
    return linux_pointer.open(e[0], e[1]);
}

/// The bounds of the first mapped window of `pid` whose title contains
/// `needle` (a dialog the app opened), or null.
pub fn windowWithTitle(pid: i32, needle: []const u8) ?Bounds {
    var buf: [32]Client = undefined;
    const n = clients(std.heap.page_allocator, pid, &buf);
    for (buf[0..n]) |*c| if (std.mem.indexOf(u8, c.title(), needle) != null) return c.bounds;
    return null;
}

/// `notches` wheel notches at layout point (x, y): positive scrolls up,
/// negative down, the Win32 convention windows_window.sendWheel takes. The
/// window under the point gets them, as a real wheel's do.
pub fn sendWheel(pid: i32, notches: i32, x: i32, y: i32) bool {
    _ = pid;
    var p = pointer() orelse return false;
    defer p.deinit();
    p.moveTo(@floatFromInt(x), @floatFromInt(y));
    gui_io.sleepNs(150 * std.time.ns_per_ms);
    p.moveTo(@floatFromInt(x + 1), @floatFromInt(y));
    gui_io.sleepNs(150 * std.time.ns_per_ms);
    p.wheel(-notches);
    return true;
}
