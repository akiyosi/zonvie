//! `[window] blur`: the compositor blurs what lies behind each window, through
//! ext-background-effect-v1. GTK from 4.23.3 owns that protocol for every
//! surface and sets its blur region from CSS `backdrop-filter`, so there the
//! window only takes a class; an older GTK leaves it to linux/wl_blur.c. A
//! compositor without the protocol, or an X11 session, leaves the window
//! translucent only, its blur then the compositor's own rules. GTK main
//! thread only.

const std = @import("std");
const App = @import("app.zig").App;
const gtk = @import("gtk_bindings.zig");
const applog = @import("app_log.zig");

extern "c" fn zonvie_wl_blur_init(display: *anyopaque) c_int;
extern "c" fn zonvie_wl_blur_surface(surface: *anyopaque, compositor: *anyopaque) ?*anyopaque;
extern "c" fn zonvie_wl_blur_release(effect: ?*anyopaque) void;
extern "c" fn gdk_wayland_display_get_type() usize;
extern "c" fn gdk_wayland_display_get_wl_display(display: *anyopaque) ?*anyopaque;
extern "c" fn gdk_wayland_display_get_wl_compositor(display: *anyopaque) ?*anyopaque;
extern "c" fn gdk_wayland_surface_get_wl_surface(surface: *anyopaque) ?*anyopaque;
extern "c" fn g_type_check_instance_is_a(instance: *anyopaque, iface_type: usize) c_int;

extern "c" fn gtk_get_major_version() c_uint;
extern "c" fn gtk_get_minor_version() c_uint;
extern "c" fn gtk_get_micro_version() c_uint;

/// GTK binds ext-background-effect-v1 itself from 4.23.3: a second effect
/// object for its surface is a protocol error that ends the connection.
pub fn gtkOwnsBlur(major: c_uint, minor: c_uint, micro: c_uint) bool {
    if (major != 4) return major > 4;
    if (minor != 23) return minor > 23;
    return micro >= 3;
}

test "GTK owns the blur protocol from 4.23.3" {
    try std.testing.expect(gtkOwnsBlur(4, 24, 1));
    try std.testing.expect(gtkOwnsBlur(4, 23, 3));
    try std.testing.expect(!gtkOwnsBlur(4, 23, 2));
    try std.testing.expect(!gtkOwnsBlur(4, 22, 9));
    try std.testing.expect(gtkOwnsBlur(5, 0, 0));
}

/// Asks for blur behind `window` while it is mapped.
/// Pre: `[window] blur` is on.
pub fn watch(app: *App, window: *anyopaque) void {
    std.debug.assert(app.window_cfg.blur);
    if (gtkOwnsBlur(gtk_get_major_version(), gtk_get_minor_version(), gtk_get_micro_version())) {
        // ui_widgets' stylesheet gives it a backdrop-filter, which GTK
        // turns into the window's blur region.
        gtk.gtk_widget_add_css_class(window, "zonvie-blur");
        return;
    }
    _ = gtk.g_signal_connect(window, "map", @ptrCast(&onMap), null);
    _ = gtk.g_signal_connect(window, "unmap", @ptrCast(&onUnmap), null);
}

/// The effect object of each window, by the window, as GObject data.
const key = "zonvie-blur-effect";

fn onMap(window: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    _ = data;
    const win = window.?;
    const display = gtk.gtk_widget_get_display(win) orelse return;
    if (g_type_check_instance_is_a(display, gdk_wayland_display_get_type()) == 0) return;
    const wl_display = gdk_wayland_display_get_wl_display(display) orelse return;
    if (zonvie_wl_blur_init(wl_display) == 0) {
        applog.appLog("[blur] compositor has no ext-background-effect blur\n", .{});
        return;
    }
    const surface = gtk.gtk_native_get_surface(win) orelse return;
    const wl_surface = gdk_wayland_surface_get_wl_surface(surface) orelse return;
    const compositor = gdk_wayland_display_get_wl_compositor(display) orelse return;
    const effect = zonvie_wl_blur_surface(wl_surface, compositor) orelse return;
    gtk.g_object_set_data(win, key, effect);
    // The region takes effect with the next commit.
    gtk.gtk_widget_queue_draw(win);
    applog.appLog("[blur] ext-background-effect blur region set\n", .{});
}

fn onUnmap(window: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    _ = data;
    const win = window.?;
    zonvie_wl_blur_release(gtk.g_object_get_data(win, key));
    gtk.g_object_set_data(win, key, null);
}
