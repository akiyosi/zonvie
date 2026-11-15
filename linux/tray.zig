//! `[server] close_to_tray`: a StatusNotifierItem (the freedesktop tray
//! protocol panels such as KDE, waybar and GNOME's AppIndicator extension
//! host) with an "Open Zonvie" / "Quit" menu (com.canonical.dbusmenu), the
//! Windows tray icon's counterpart. GIO's GDBus only. GTK main thread.

const std = @import("std");
const App = @import("app.zig").App;
const gtk = @import("gtk_bindings.zig");
const applog = @import("app_log.zig");

const item_path = "/StatusNotifierItem";
const menu_path = "/MenuBar";
const menu_open: i32 = 1;
const menu_quit: i32 = 2;

const introspection =
    \\<node>
    \\ <interface name="org.kde.StatusNotifierItem">
    \\  <property name="Category" type="s" access="read"/>
    \\  <property name="Id" type="s" access="read"/>
    \\  <property name="Title" type="s" access="read"/>
    \\  <property name="Status" type="s" access="read"/>
    \\  <property name="IconName" type="s" access="read"/>
    \\  <property name="IconPixmap" type="a(iiay)" access="read"/>
    \\  <property name="ItemIsMenu" type="b" access="read"/>
    \\  <property name="Menu" type="o" access="read"/>
    \\  <method name="Activate"><arg name="x" type="i" direction="in"/><arg name="y" type="i" direction="in"/></method>
    \\  <method name="SecondaryActivate"><arg name="x" type="i" direction="in"/><arg name="y" type="i" direction="in"/></method>
    \\  <method name="ContextMenu"><arg name="x" type="i" direction="in"/><arg name="y" type="i" direction="in"/></method>
    \\  <method name="Scroll"><arg name="delta" type="i" direction="in"/><arg name="orientation" type="s" direction="in"/></method>
    \\ </interface>
    \\ <interface name="com.canonical.dbusmenu">
    \\  <property name="Version" type="u" access="read"/>
    \\  <property name="TextDirection" type="s" access="read"/>
    \\  <property name="Status" type="s" access="read"/>
    \\  <property name="IconThemePath" type="as" access="read"/>
    \\  <method name="GetLayout">
    \\   <arg type="i" name="parentId" direction="in"/><arg type="i" name="recursionDepth" direction="in"/>
    \\   <arg type="as" name="propertyNames" direction="in"/>
    \\   <arg type="u" name="revision" direction="out"/><arg type="(ia{sv}av)" name="layout" direction="out"/>
    \\  </method>
    \\  <method name="GetGroupProperties">
    \\   <arg type="ai" name="ids" direction="in"/><arg type="as" name="propertyNames" direction="in"/>
    \\   <arg type="a(ia{sv})" name="properties" direction="out"/>
    \\  </method>
    \\  <method name="GetProperty">
    \\   <arg type="i" name="id" direction="in"/><arg type="s" name="name" direction="in"/><arg type="v" name="value" direction="out"/>
    \\  </method>
    \\  <method name="Event">
    \\   <arg type="i" name="id" direction="in"/><arg type="s" name="eventId" direction="in"/>
    \\   <arg type="v" name="data" direction="in"/><arg type="u" name="timestamp" direction="in"/>
    \\  </method>
    \\  <method name="EventGroup">
    \\   <arg type="a(isvu)" name="events" direction="in"/><arg type="ai" name="idErrors" direction="out"/>
    \\  </method>
    \\  <method name="AboutToShow"><arg type="i" name="id" direction="in"/><arg type="b" name="needUpdate" direction="out"/></method>
    \\  <method name="AboutToShowGroup">
    \\   <arg type="ai" name="ids" direction="in"/><arg type="ai" name="updatesNeeded" direction="out"/><arg type="ai" name="idErrors" direction="out"/>
    \\  </method>
    \\  <signal name="LayoutUpdated"><arg type="u" name="revision"/><arg type="i" name="parent"/></signal>
    \\ </interface>
    \\</node>
;

/// The tray's state; lives in the App.
pub const Tray = struct {
    conn: ?*anyopaque = null,
    /// The icon, built once (a(iiay)), owned.
    pixmap: ?*anyopaque = null,
    /// The icon theme has the app's icon (an `--install`ed desktop entry):
    /// IconName names it. Without it IconName is empty, so the host draws
    /// IconPixmap instead of its missing-icon placeholder.
    icon_installed: bool = false,
    /// The tray's Quit asked for a real close: the next close-request quits
    /// instead of hiding (consumed there, as Windows' tray_quit_requested).
    quit_requested: bool = false,
};

const GDBusInterfaceVTable = extern struct {
    method_call: ?*const fn (?*anyopaque, ?[*:0]const u8, ?[*:0]const u8, ?[*:0]const u8, [*:0]const u8, ?*anyopaque, *anyopaque, ?*anyopaque) callconv(.c) void,
    get_property: ?*const fn (?*anyopaque, ?[*:0]const u8, ?[*:0]const u8, ?[*:0]const u8, [*:0]const u8, ?*anyopaque, ?*anyopaque) callconv(.c) ?*anyopaque,
    set_property: ?*anyopaque = null,
    padding: [8]?*anyopaque = @splat(null),
};

extern "c" fn g_bus_get_sync(bus_type: c_int, cancellable: ?*anyopaque, err: ?*?*anyopaque) ?*anyopaque;
extern "c" fn g_dbus_node_info_new_for_xml(xml: [*:0]const u8, err: ?*?*anyopaque) ?*anyopaque;
extern "c" fn g_dbus_node_info_lookup_interface(info: *anyopaque, name: [*:0]const u8) ?*anyopaque;
extern "c" fn g_dbus_node_info_unref(info: *anyopaque) void;
extern "c" fn g_dbus_connection_register_object(conn: *anyopaque, path: [*:0]const u8, iface: *anyopaque, vtable: *const GDBusInterfaceVTable, user_data: ?*anyopaque, free: ?*anyopaque, err: ?*?*anyopaque) c_uint;
extern "c" fn g_dbus_connection_call_sync(conn: *anyopaque, bus_name: ?[*:0]const u8, path: [*:0]const u8, iface: [*:0]const u8, method: [*:0]const u8, params: ?*anyopaque, reply_type: ?*const anyopaque, flags: c_uint, timeout_ms: c_int, cancellable: ?*anyopaque, err: ?*?*anyopaque) ?*anyopaque;
extern "c" fn g_dbus_method_invocation_return_value(invocation: *anyopaque, params: ?*anyopaque) void;
extern "c" fn g_variant_new(format: [*:0]const u8, ...) ?*anyopaque;
extern "c" fn g_variant_new_parsed(format: [*:0]const u8, ...) ?*anyopaque;
extern "c" fn g_variant_get(v: *anyopaque, format: [*:0]const u8, ...) void;
extern "c" fn g_variant_new_fixed_array(elem_type: [*:0]const u8, elements: ?*const anyopaque, n: usize, elem_size: usize) ?*anyopaque;
extern "c" fn g_variant_new_array(child_type: ?[*:0]const u8, children: [*]const ?*anyopaque, n: usize) ?*anyopaque;
extern "c" fn g_variant_ref_sink(v: *anyopaque) *anyopaque;
extern "c" fn g_variant_ref(v: *anyopaque) *anyopaque;
extern "c" fn g_variant_unref(v: *anyopaque) void;
extern "c" fn g_variant_get_int32(v: *anyopaque) i32;
extern "c" fn g_variant_get_child_value(v: *anyopaque, index: usize) *anyopaque;
extern "c" fn g_variant_get_string(v: *anyopaque, len: ?*usize) [*:0]const u8;
extern "c" fn g_variant_n_children(v: *anyopaque) usize;
extern "c" fn g_bytes_new_static(data: [*]const u8, size: usize) ?*anyopaque;
extern "c" fn g_bytes_unref(bytes: *anyopaque) void;
extern "c" fn gdk_texture_new_from_bytes(bytes: *anyopaque, err: ?*?*anyopaque) ?*anyopaque;
extern "c" fn gdk_texture_get_width(t: *anyopaque) c_int;
extern "c" fn gdk_texture_get_height(t: *anyopaque) c_int;
extern "c" fn gdk_texture_download(t: *anyopaque, data: [*]u8, stride: usize) void;
extern "c" fn gtk_window_close(window: *anyopaque) void;

const icon_png = @embedFile("zonvie-256.png");

/// The theme name of the app's icon (cli.app_id).
const icon_id = "io.github.akiyosi.zonvie";

/// IconName as published: the theme name only when a theme has the icon. A
/// host given a name it cannot find draws a placeholder rather than falling
/// back to IconPixmap.
pub fn iconNameProperty(installed: bool) [:0]const u8 {
    return if (installed) icon_id else "";
}

test "the icon is named only when a theme has it" {
    try std.testing.expectEqualStrings(icon_id, iconNameProperty(true));
    try std.testing.expectEqualStrings("", iconNameProperty(false));
}
const icon_px = 256;

/// Converts gdk_texture_download's pixels (GDK_MEMORY_DEFAULT: B, G, R, A
/// bytes, premultiplied) in place to the tray's ARGB32 in network byte
/// order, straight alpha. `px.len` must be a multiple of 4.
pub fn toNetworkArgb(px: []u8) void {
    std.debug.assert(px.len % 4 == 0);
    var i: usize = 0;
    while (i < px.len) : (i += 4) {
        const b = px[i];
        const g = px[i + 1];
        const r = px[i + 2];
        const a = px[i + 3];
        const un = struct {
            fn f(c: u8, alpha: u8) u8 {
                if (alpha == 0) return 0;
                return @intCast(@min(255, (@as(u32, c) * 255 + alpha / 2) / alpha));
            }
        }.f;
        px[i] = a;
        px[i + 1] = un(r, a);
        px[i + 2] = un(g, a);
        px[i + 3] = un(b, a);
    }
}

test "tray pixels are ARGB in network order with straight alpha" {
    var px = [_]u8{ 0x10, 0x20, 0x30, 0xff, 0x40, 0x40, 0x40, 0x80, 1, 2, 3, 0 };
    toNetworkArgb(&px);
    try std.testing.expectEqualSlices(u8, &.{ 0xff, 0x30, 0x20, 0x10, 0x80, 0x80, 0x80, 0x80, 0, 0, 0, 0 }, &px);
}

fn buildPixmap() ?*anyopaque {
    const bytes = g_bytes_new_static(icon_png.ptr, icon_png.len) orelse return null;
    defer g_bytes_unref(bytes);
    const tex = gdk_texture_new_from_bytes(bytes, null) orelse return null;
    defer gtk.g_object_unref(tex);
    if (gdk_texture_get_width(tex) != icon_px or gdk_texture_get_height(tex) != icon_px) return null;
    var px: [icon_px * icon_px * 4]u8 = undefined;
    gdk_texture_download(tex, &px, icon_px * 4);
    toNetworkArgb(&px);
    const data = g_variant_new_fixed_array("y", &px, px.len, 1) orelse return null;
    const entry = g_variant_new("(ii@ay)", @as(c_int, icon_px), @as(c_int, icon_px), data) orelse return null;
    const arr = g_variant_new_array(null, &.{entry}, 1) orelse return null;
    return g_variant_ref_sink(arr);
}

/// Registers the tray item with the session's StatusNotifierWatcher.
/// Returns false, leaving nothing registered that a later call depends on,
/// when there is no session bus or no watcher (no tray host): closing then
/// quits, as Windows does when its icon cannot be added.
pub fn init(app: *App) bool {
    const conn = g_bus_get_sync(2, null, null) orelse return false;
    const info = g_dbus_node_info_new_for_xml(introspection, null) orelse return false;
    defer g_dbus_node_info_unref(info);
    const vt = struct {
        const v: GDBusInterfaceVTable = .{ .method_call = &onMethod, .get_property = &onGetProperty };
    };
    if (g_dbus_connection_register_object(conn, item_path, g_dbus_node_info_lookup_interface(info, "org.kde.StatusNotifierItem").?, &vt.v, app, null, null) == 0) return false;
    if (g_dbus_connection_register_object(conn, menu_path, g_dbus_node_info_lookup_interface(info, "com.canonical.dbusmenu").?, &vt.v, app, null, null) == 0) return false;

    var name_buf: [64]u8 = undefined;
    const name = std.fmt.bufPrintZ(&name_buf, "org.kde.StatusNotifierItem-{d}-1", .{std.c.getpid()}) catch unreachable;
    // DBUS_NAME_FLAG_DO_NOT_QUEUE (4).
    if (g_dbus_connection_call_sync(conn, "org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "RequestName", g_variant_new("(su)", name.ptr, @as(c_uint, 4)), null, 0, 1000, null, null)) |r| g_variant_unref(r) else return false;
    var err: ?*anyopaque = null;
    const reply = g_dbus_connection_call_sync(conn, "org.kde.StatusNotifierWatcher", "/StatusNotifierWatcher", "org.kde.StatusNotifierWatcher", "RegisterStatusNotifierItem", g_variant_new("(s)", name.ptr), null, 0, 1000, null, &err);
    if (reply) |r| g_variant_unref(r) else {
        const msg: [*:0]const u8 = if (err) |e| (@as(*gtk.GError, @ptrCast(@alignCast(e))).message orelse "") else "";
        applog.appLog("[linux] tray: no StatusNotifierWatcher ({s}); close_to_tray off\n", .{msg});
        if (err) |e| gtk.g_error_free(e);
        return false;
    }
    app.tray.conn = conn;
    app.tray.pixmap = buildPixmap();
    if (gtk.gdk_display_get_default()) |d| {
        if (gtk.gtk_icon_theme_get_for_display(d)) |theme| app.tray.icon_installed = gtk.gtk_icon_theme_has_icon(theme, icon_id) != 0;
    }
    applog.appLog("[linux] tray: registered {s}\n", .{name});
    return true;
}

fn appFrom(data: ?*anyopaque) *App {
    return @ptrCast(@alignCast(data.?));
}

fn childInt(v: *anyopaque, i: usize) i32 {
    const c = g_variant_get_child_value(v, i);
    defer g_variant_unref(c);
    return g_variant_get_int32(c);
}

fn eql(a: [*:0]const u8, b: []const u8) bool {
    return std.mem.eql(u8, std.mem.span(a), b);
}

/// Brings the window back from the tray.
fn show(app: *App) void {
    if (app.window) |w| gtk.gtk_window_present(w);
}

fn activate(app: *App, id: i32) void {
    if (id == menu_open) return show(app);
    if (id != menu_quit) return;
    // A real close, through the usual quit path (unsaved buffers asked).
    app.tray.quit_requested = true;
    show(app);
    if (app.window) |w| gtk_window_close(w);
}

const layout_root =
    "(0, {'children-display': <'submenu'>}, [" ++
    "<(1, {'label': <'Open Zonvie'>}, @av [])>, " ++
    "<(2, {'label': <'Quit'>}, @av [])>])";

fn onMethod(conn: ?*anyopaque, sender: ?[*:0]const u8, path: ?[*:0]const u8, iface: ?[*:0]const u8, method: [*:0]const u8, params: ?*anyopaque, inv: *anyopaque, data: ?*anyopaque) callconv(.c) void {
    _ = conn;
    _ = sender;
    _ = path;
    _ = iface;
    const app = appFrom(data);
    const reply: ?*anyopaque = if (eql(method, "Activate") or eql(method, "SecondaryActivate")) blk: {
        show(app);
        break :blk null;
    } else if (eql(method, "ContextMenu") or eql(method, "Scroll"))
        null
    else if (eql(method, "GetLayout"))
        g_variant_new_parsed("(@u 1, " ++ layout_root ++ ")")
    else if (eql(method, "GetGroupProperties"))
        g_variant_new_parsed("([(1, {'label': <'Open Zonvie'>}), (2, {'label': <'Quit'>})],)")
    else if (eql(method, "GetProperty"))
        g_variant_new_parsed("(<''>,)")
    else if (eql(method, "Event")) blk: {
        const id = childInt(params.?, 0);
        const ev = g_variant_get_child_value(params.?, 1);
        defer g_variant_unref(ev);
        if (eql(g_variant_get_string(ev, null), "clicked")) activate(app, id);
        break :blk null;
    } else if (eql(method, "EventGroup")) blk: {
        const events = g_variant_get_child_value(params.?, 0);
        defer g_variant_unref(events);
        for (0..g_variant_n_children(events)) |i| {
            const e = g_variant_get_child_value(events, i);
            defer g_variant_unref(e);
            const ev = g_variant_get_child_value(e, 1);
            defer g_variant_unref(ev);
            if (eql(g_variant_get_string(ev, null), "clicked")) activate(app, childInt(e, 0));
        }
        break :blk g_variant_new_parsed("(@ai [],)");
    } else if (eql(method, "AboutToShow"))
        g_variant_new_parsed("(false,)")
    else if (eql(method, "AboutToShowGroup"))
        g_variant_new_parsed("(@ai [], @ai [])")
    else
        null;
    g_dbus_method_invocation_return_value(inv, reply);
}

fn onGetProperty(conn: ?*anyopaque, sender: ?[*:0]const u8, path: ?[*:0]const u8, iface: ?[*:0]const u8, prop: [*:0]const u8, err: ?*anyopaque, data: ?*anyopaque) callconv(.c) ?*anyopaque {
    _ = conn;
    _ = sender;
    _ = err;
    const app = appFrom(data);
    const menu = std.mem.eql(u8, std.mem.span(path.?), menu_path);
    _ = iface;
    if (menu) {
        if (eql(prop, "Version")) return g_variant_new("u", @as(c_uint, 3));
        if (eql(prop, "TextDirection")) return g_variant_new("s", "ltr".ptr);
        if (eql(prop, "Status")) return g_variant_new("s", "normal".ptr);
        return g_variant_new_parsed("@as []");
    }
    if (eql(prop, "Category")) return g_variant_new("s", "ApplicationStatus".ptr);
    if (eql(prop, "Id")) return g_variant_new("s", "zonvie".ptr);
    if (eql(prop, "Title")) return g_variant_new("s", "Zonvie".ptr);
    if (eql(prop, "Status")) return g_variant_new("s", "Active".ptr);
    if (eql(prop, "IconName")) return g_variant_new("s", iconNameProperty(app.tray.icon_installed).ptr);
    if (eql(prop, "ItemIsMenu")) return g_variant_new("b", @as(c_int, 0));
    if (eql(prop, "Menu")) return g_variant_new("o", menu_path.ptr);
    // IconPixmap.
    if (app.tray.pixmap) |p| return g_variant_ref(p);
    return g_variant_new_parsed("@a(iiay) []");
}
