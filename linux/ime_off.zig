//! Switching the input method off ([input] ime_disable_on_activate,
//! ime_disable_on_modechange, on_ime_off), as Windows closes the IME with
//! ImmSetOpenStatus. Wayland has no call for it, so the IM framework is asked
//! over D-Bus: Fcitx5 deactivates the focused input context
//! (org.fcitx.Fcitx.Controller1.Deactivate); IBus has no off state since
//! 1.5, so its global engine becomes the first keyboard-layout ("xkb:")
//! engine among the active ones, which is what its own "off" means. The
//! caller resets the composition first, which is all that happens when
//! neither framework answers. Main thread only.

const std = @import("std");
const glib = @import("glib.zig");

/// Turns the input method off.
pub fn off() void {
    const bus = glib.g_bus_get_sync(glib.G_BUS_TYPE_SESSION, null, null) orelse return ibusOff();
    defer glib.g_object_unref(bus);
    glib.g_dbus_connection_call(bus, "org.fcitx.Fcitx5", "/controller", "org.fcitx.Fcitx.Controller1", "Deactivate", null, null, 0, call_timeout_ms, null, &onFcitxDone, null);
}

const call_timeout_ms = 500;

fn onFcitxDone(source: ?*anyopaque, res: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    _ = data;
    var err: ?*anyopaque = null;
    const reply = glib.g_dbus_connection_call_finish(source.?, res, &err);
    if (reply) |r| return glib.g_variant_unref(r);
    if (err) |e| glib.g_error_free(e);
    // No Fcitx5 on the session bus.
    ibusOff();
}

/// IBus's own bus, kept once connected; dropped when a call on it fails so
/// a restarted daemon is found again.
var ibus_conn: ?*anyopaque = null;

fn ibusOff() void {
    const conn = ibus_conn orelse connectIbus() orelse return;
    ibus_conn = conn;
    glib.g_dbus_connection_call(conn, "org.freedesktop.IBus", "/org/freedesktop/IBus", "org.freedesktop.IBus", "ListActiveEngines", null, null, 0, call_timeout_ms, null, &onIbusEngines, null);
}

fn dropIbus(err: ?*anyopaque) void {
    if (err) |e| glib.g_error_free(e);
    if (ibus_conn) |c| glib.g_object_unref(c);
    ibus_conn = null;
}

fn onIbusEngines(source: ?*anyopaque, res: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    _ = data;
    var err: ?*anyopaque = null;
    const reply = glib.g_dbus_connection_call_finish(source.?, res, &err) orelse return dropIbus(err);
    defer glib.g_variant_unref(reply);
    // (av): each an IBusEngineDesc serialized as (s a{sv} name ...).
    const list = glib.g_variant_get_child_value(reply, 0) orelse return;
    defer glib.g_variant_unref(list);
    var i: usize = 0;
    const n = glib.g_variant_n_children(list);
    while (i < n) : (i += 1) {
        const boxed = glib.g_variant_get_child_value(list, i) orelse continue;
        defer glib.g_variant_unref(boxed);
        const desc = glib.g_variant_get_variant(boxed) orelse continue;
        defer glib.g_variant_unref(desc);
        if (glib.g_variant_get_type_string(desc)[0] != '(' or glib.g_variant_n_children(desc) < 3) continue;
        const name_v = glib.g_variant_get_child_value(desc, 2) orelse continue;
        defer glib.g_variant_unref(name_v);
        if (!std.mem.eql(u8, std.mem.span(glib.g_variant_get_type_string(name_v)), "s")) continue;
        const name = glib.g_variant_get_string(name_v, null) orelse continue;
        if (!isLayoutEngine(std.mem.span(name))) continue;
        const args = glib.g_variant_new_tuple(&[_]*anyopaque{glib.g_variant_new_string(name).?}, 1);
        glib.g_dbus_connection_call(source.?, "org.freedesktop.IBus", "/org/freedesktop/IBus", "org.freedesktop.IBus", "SetGlobalEngine", args, null, 0, call_timeout_ms, null, &onIbusSet, null);
        return;
    }
}

fn onIbusSet(source: ?*anyopaque, res: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    _ = data;
    var err: ?*anyopaque = null;
    const reply = glib.g_dbus_connection_call_finish(source.?, res, &err) orelse return dropIbus(err);
    glib.g_variant_unref(reply);
}

/// An IBus engine that types the keyboard layout as it is: IBus's "off".
pub fn isLayoutEngine(name: []const u8) bool {
    return std.mem.startsWith(u8, name, "xkb:");
}

/// IBUS_ADDRESS, else the address the daemon wrote for this display under
/// $XDG_CONFIG_HOME/ibus/bus. Null when there is none or it does not answer.
fn connectIbus() ?*anyopaque {
    var buf: [512]u8 = undefined;
    const addr: [:0]const u8 = if (glib.g_getenv("IBUS_ADDRESS")) |a|
        (std.fmt.bufPrintZ(&buf, "{s}", .{std.mem.span(a)}) catch return null)
    else
        busFileAddress(&buf) orelse return null;
    var err: ?*anyopaque = null;
    const conn = glib.g_dbus_connection_new_for_address_sync(addr.ptr, glib.G_DBUS_CONNECTION_FLAGS_AUTHENTICATION_CLIENT | glib.G_DBUS_CONNECTION_FLAGS_MESSAGE_BUS_CONNECTION, null, null, &err);
    if (err) |e| glib.g_error_free(e);
    return conn;
}

fn span(s: ?[*:0]const u8) ?[]const u8 {
    return if (s) |v| std.mem.span(v) else null;
}

fn busFileAddress(out: []u8) ?[:0]const u8 {
    const id_c = machineId() orelse return null;
    defer glib.g_free(id_c);
    const id = std.mem.trim(u8, std.mem.span(id_c), " \t\r\n");
    var dir_buf: [1024]u8 = undefined;
    const dir_path = std.fmt.bufPrintZ(&dir_buf, "{s}/ibus/bus", .{std.mem.span(glib.g_get_user_config_dir())}) catch return null;
    const dir = glib.g_dir_open(dir_path.ptr, 0, null) orelse return null;
    defer glib.g_dir_close(dir);
    var names: [16][]const u8 = undefined;
    var n: usize = 0;
    // The names live until g_dir_close.
    while (glib.g_dir_read_name(dir)) |name| {
        if (n == names.len) break;
        names[n] = std.mem.span(name);
        n += 1;
    }
    const name = pickBusFile(names[0..n], id, span(glib.g_getenv("WAYLAND_DISPLAY")), span(glib.g_getenv("DISPLAY"))) orelse return null;
    var path_buf: [1280]u8 = undefined;
    const path = std.fmt.bufPrintZ(&path_buf, "{s}/{s}", .{ dir_path, name }) catch return null;
    var text: ?[*:0]u8 = null;
    var len: usize = 0;
    if (glib.g_file_get_contents(path.ptr, &text, &len, null) == 0) return null;
    defer glib.g_free(text);
    const addr = busAddress(text.?[0..len]) orelse return null;
    return std.fmt.bufPrintZ(out, "{s}", .{addr}) catch null;
}

fn machineId() ?[*:0]u8 {
    for ([_][*:0]const u8{ "/etc/machine-id", "/var/lib/dbus/machine-id" }) |path| {
        var text: ?[*:0]u8 = null;
        var len: usize = 0;
        if (glib.g_file_get_contents(path, &text, &len, null) != 0) return text;
    }
    return null;
}

/// The bus file IBus wrote for this session among `names`: `<machine id>-`
/// followed by its display, which IBus spells from WAYLAND_DISPLAY or
/// DISPLAY in ways that differ across versions; else the only file for
/// this machine. Pure.
pub fn pickBusFile(names: []const []const u8, machine_id: []const u8, wayland: ?[]const u8, x11: ?[]const u8) ?[]const u8 {
    var only: ?[]const u8 = null;
    var count: usize = 0;
    var by_x11: ?[]const u8 = null;
    for (names) |name| {
        if (!std.mem.startsWith(u8, name, machine_id) or name.len <= machine_id.len or name[machine_id.len] != '-') continue;
        count += 1;
        only = name;
        const rest = name[machine_id.len + 1 ..];
        // The Wayland display wins: IBus prefers it when both are set.
        if (wayland) |w| {
            if (w.len != 0 and std.mem.indexOf(u8, rest, w) != null) return name;
        }
        if (x11) |d| {
            // ":1" or ":1.0" is "unix-1".
            const colon = std.mem.indexOfScalar(u8, d, ':') orelse continue;
            const num = d[colon + 1 ..];
            const dot = std.mem.indexOfScalar(u8, num, '.') orelse num.len;
            if (by_x11 == null and std.mem.endsWith(u8, rest, num[0..dot]) and rest.len > dot and rest[rest.len - dot - 1] == '-') by_x11 = name;
        }
    }
    if (by_x11) |n| return n;
    return if (count == 1) only else null;
}

/// IBUS_ADDRESS=... from a bus file's lines. Pure.
pub fn busAddress(text: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const key = "IBUS_ADDRESS=";
        if (std.mem.startsWith(u8, line, key)) {
            const v = std.mem.trim(u8, line[key.len..], " \r");
            if (v.len != 0) return v;
        }
    }
    return null;
}

const testing = std.testing;

test "the bus file IBus wrote for this display is the one picked" {
    const id = "0123abcd";
    const names = [_][]const u8{ "0123abcd-unix-0", "0123abcd-unix-wayland-1", "ffff-unix-1" };
    try testing.expectEqualStrings("0123abcd-unix-wayland-1", pickBusFile(&names, id, "wayland-1", ":0").?);
    try testing.expectEqualStrings("0123abcd-unix-0", pickBusFile(&names, id, null, ":0.0").?);
    try testing.expect(pickBusFile(&names, id, null, ":5") == null);
    try testing.expectEqualStrings("0123abcd-unix-0", pickBusFile(names[0..1], id, null, null).?);
    try testing.expect(pickBusFile(names[2..], id, null, ":1") == null);
}

test "the address is read from its line, and only xkb engines are layouts" {
    try testing.expectEqualStrings("unix:abstract=/tmp/x,guid=1", busAddress("# comment\nIBUS_ADDRESS=unix:abstract=/tmp/x,guid=1\nIBUS_DAEMON_PID=7\n").?);
    try testing.expect(busAddress("IBUS_DAEMON_PID=7\n") == null);
    try testing.expect(isLayoutEngine("xkb:us::eng"));
    try testing.expect(!isLayoutEngine("mozc-jp"));
}
