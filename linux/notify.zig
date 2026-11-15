//! OS notifications through the desktop's notification server
//! (org.freedesktop.Notifications), with a sound as macOS's notifications
//! play one: GNotification has no sound, the server's `sound-name` hint does.
//! Without a server on the session bus, GNotification delivers it silently
//! (a portal, a sandbox). GTK main thread only.

const std = @import("std");
const App = @import("app.zig").App;
const gtk = @import("gtk_bindings.zig");
const applog = @import("app_log.zig");

extern "c" fn g_variant_new_parsed(format: [*:0]const u8, ...) ?*anyopaque;
extern "c" fn g_variant_get_child(value: *anyopaque, index: usize, format_string: [*:0]const u8, ...) void;
extern "c" fn g_variant_get_child_value(value: *anyopaque, index: usize) *anyopaque;
extern "c" fn g_application_get_dbus_connection(app: *anyopaque) ?*anyopaque;

/// The freedesktop sound theme's name for a new message.
pub const sound_name = "message-new-instant";

/// A notification slot: a later notification in the same slot replaces the
/// earlier one (the server's replaces_id), as GNotification ids do.
pub const Slot = enum { none, agent };

pub const State = struct {
    /// The server's id of the last notification per slot; 0 for none.
    ids: [std.meta.fields(Slot).len]u32 = @splat(0),
    /// The server did not answer once: GNotification from then on.
    unavailable: bool = false,
    /// Whether the server reads the body as markup (GetCapabilities'
    /// "body-markup"); asked once, before the first Notify.
    body_markup: Caps = .unknown,

    pub const Caps = enum { unknown, markup, plain };
};

/// `src` as the body of a server that reads markup: the spec's subset
/// treats `&`, `<` and `>` as syntax, so they become entities and the text
/// shows as written. Pre: `dst.len >= 5 * src.len + 1`. The result is NUL-
/// terminated in `dst`.
pub fn escapeMarkup(dst: []u8, src: []const u8) [:0]const u8 {
    std.debug.assert(dst.len >= 5 * src.len + 1);
    var n: usize = 0;
    for (src) |ch| {
        const rep: []const u8 = switch (ch) {
            '&' => "&amp;",
            '<' => "&lt;",
            '>' => "&gt;",
            else => &.{ch},
        };
        @memcpy(dst[n..][0..rep.len], rep);
        n += rep.len;
    }
    dst[n] = 0;
    return dst[0..n :0];
}

test "a markup body escapes the spec's syntax characters" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("a &lt;b&gt; &amp;&amp; c", escapeMarkup(&buf, "a <b> && c"));
    try std.testing.expectEqualStrings("plain", escapeMarkup(&buf, "plain"));
}

/// Whether GetCapabilities' list names body markup.
pub fn hasBodyMarkup(caps: []const []const u8) bool {
    for (caps) |c| if (std.mem.eql(u8, c, "body-markup")) return true;
    return false;
}

test "body markup is read from the capability list" {
    try std.testing.expect(hasBodyMarkup(&.{ "actions", "body", "body-markup" }));
    try std.testing.expect(!hasBodyMarkup(&.{ "body", "body-hyperlinks" }));
}

/// The replaces_id a notification in `slot` sends: the last id the server
/// gave that slot, never for `.none`.
pub fn replacesId(state: *const State, slot: Slot) u32 {
    return if (slot == .none) 0 else state.ids[@intFromEnum(slot)];
}

test "only a named slot replaces its previous notification" {
    var s: State = .{};
    s.ids[@intFromEnum(Slot.agent)] = 7;
    try std.testing.expectEqual(@as(u32, 7), replacesId(&s, .agent));
    try std.testing.expectEqual(@as(u32, 0), replacesId(&s, .none));
}

/// One call in flight, owning its text for the GNotification fallback.
const Pending = struct {
    app: *App,
    slot: Slot,
    title: [129]u8 = undefined,
    body: [1025]u8 = undefined,
};

/// The session bus connection GApplication registered on; owned by it, so
/// nothing blocks or is unreffed here. Null when it has none.
fn connection(app: *App) ?*anyopaque {
    if (app.notify.unavailable) return null;
    return g_application_get_dbus_connection(app.gtk_app orelse return null);
}

/// Shows `title` / `body` (cut to 1024 bytes). Pre: GTK main thread.
pub fn send(app: *App, slot: Slot, title: [*:0]const u8, body: []const u8) void {
    var z: [1025]u8 = undefined;
    const n = copyZ(&z, body);
    const c = connection(app) orelse return fallback(app, slot, title, @ptrCast(&z));
    const p = app.alloc.create(Pending) catch return;
    p.* = .{ .app = app, .slot = slot };
    _ = copyZ(&p.title, std.mem.span(title));
    _ = copyZ(&p.body, z[0..n]);
    if (app.notify.body_markup != .unknown) return notify(c, p);
    // The first notification asks how the body is read, then goes out.
    gtk.g_dbus_connection_call(c, "org.freedesktop.Notifications", "/org/freedesktop/Notifications", "org.freedesktop.Notifications", "GetCapabilities", null, null, 0, 5000, null, &onCapabilities, p);
}

fn onCapabilities(source: ?*anyopaque, result: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const p: *Pending = @ptrCast(@alignCast(data.?));
    var err: ?*anyopaque = null;
    var markup = false;
    if (gtk.g_dbus_connection_call_finish(source.?, result, &err)) |reply| {
        defer gtk.g_variant_unref(reply);
        const list = g_variant_get_child_value(reply, 0);
        defer gtk.g_variant_unref(list);
        var names: [32][]const u8 = undefined;
        const count = @min(gtk.g_variant_n_children(list), names.len);
        for (names[0..count], 0..) |*name, i| {
            var s: [*:0]const u8 = "";
            g_variant_get_child(list, i, "&s", &s);
            name.* = std.mem.span(s);
        }
        markup = hasBodyMarkup(names[0..count]);
    } else if (err) |e| gtk.g_error_free(e);
    // A server that did not answer gets the Notify anyway; its failure
    // falls back to GNotification there.
    if (p.app.notify.body_markup == .unknown) p.app.notify.body_markup = if (markup) .markup else .plain;
    notify(source.?, p);
}

/// Sends `p` through `c`; takes ownership of `p`.
fn notify(c: *anyopaque, p: *Pending) void {
    const app = p.app;
    var escaped: [5 * 1024 + 1]u8 = undefined;
    const body: [*:0]const u8 = if (app.notify.body_markup == .markup) escapeMarkup(&escaped, std.mem.sliceTo(&p.body, 0)).ptr else @ptrCast(&p.body);
    const params = g_variant_new_parsed(
        "('zonvie', %u, %s, %s, %s, @as [], {'sound-name': <%s>, 'desktop-entry': <%s>}, -1)",
        replacesId(&app.notify, p.slot),
        @as([*:0]const u8, "io.github.akiyosi.zonvie"),
        @as([*:0]const u8, @ptrCast(&p.title)),
        body,
        @as([*:0]const u8, sound_name),
        @as([*:0]const u8, "io.github.akiyosi.zonvie"),
    ) orelse {
        defer app.alloc.destroy(p);
        return fallback(app, p.slot, @ptrCast(&p.title), @ptrCast(&p.body));
    };
    gtk.g_dbus_connection_call(c, "org.freedesktop.Notifications", "/org/freedesktop/Notifications", "org.freedesktop.Notifications", "Notify", params, null, 0, 5000, null, &onNotified, p);
}

fn copyZ(dst: []u8, src: []const u8) usize {
    const n = @min(src.len, dst.len - 1);
    @memcpy(dst[0..n], src[0..n]);
    dst[n] = 0;
    return n;
}

fn onNotified(source: ?*anyopaque, result: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const p: *Pending = @ptrCast(@alignCast(data.?));
    const app = p.app;
    const slot = p.slot;
    defer app.alloc.destroy(p);
    var err: ?*anyopaque = null;
    const reply = gtk.g_dbus_connection_call_finish(source.?, result, &err) orelse {
        if (err) |e| gtk.g_error_free(e);
        applog.appLog("[notify] no notification server; using GNotification\n", .{});
        app.notify.unavailable = true;
        return fallback(app, slot, @ptrCast(&p.title), @ptrCast(&p.body));
    };
    defer gtk.g_variant_unref(reply);
    var id: u32 = 0;
    g_variant_get_child(reply, 0, "u", &id);
    if (slot != .none) app.notify.ids[@intFromEnum(slot)] = id;
}

fn fallback(app: *App, slot: Slot, title: [*:0]const u8, body: [*:0]const u8) void {
    const gapp = app.gtk_app orelse return;
    const note = gtk.g_notification_new(title) orelse return;
    defer gtk.g_object_unref(note);
    gtk.g_notification_set_body(note, body);
    gtk.g_application_send_notification(gapp, if (slot == .agent) "agent" else null, note);
}
