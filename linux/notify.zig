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
};

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

/// Shows `title` / `body` (cut to 1024 bytes). Pre: GTK main thread.
pub fn send(app: *App, slot: Slot, title: [*:0]const u8, body: []const u8) void {
    var z: [1025]u8 = undefined;
    const n = @min(body.len, z.len - 1);
    @memcpy(z[0..n], body[0..n]);
    z[n] = 0;
    const conn = if (app.notify.unavailable) null else gtk.g_bus_get_sync(gtk.G_BUS_TYPE_SESSION, null, null);
    const c = conn orelse return fallback(app, slot, title, @ptrCast(&z));
    const params = g_variant_new_parsed(
        "('zonvie', %u, %s, %s, %s, @as [], {'sound-name': <%s>, 'desktop-entry': <%s>}, -1)",
        replacesId(&app.notify, slot),
        @as([*:0]const u8, "io.github.akiyosi.zonvie"),
        title,
        @as([*:0]const u8, @ptrCast(&z)),
        @as([*:0]const u8, sound_name),
        @as([*:0]const u8, "io.github.akiyosi.zonvie"),
    ) orelse return fallback(app, slot, title, @ptrCast(&z));
    const p = app.alloc.create(Pending) catch {
        gtk.g_variant_unref(gtk.g_variant_ref_sink(params));
        return;
    };
    p.* = .{ .app = app, .slot = slot };
    _ = copyZ(&p.title, std.mem.span(title));
    _ = copyZ(&p.body, z[0..n]);
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
