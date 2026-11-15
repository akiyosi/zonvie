//! Placing toplevels where macOS and Windows place theirs: the main window
//! at its last position, external windows at the cell Neovim names or a
//! tab's drop point, and `wincmd` rearranging them. Only GDK's X11 backend
//! allows it, through Xlib on the toplevel's X window (GTK4 has no
//! gtk_window_move); Wayland lets no client position a toplevel or read its
//! position, so every entry point here does nothing there and the
//! compositor keeps placing windows. GTK main thread only: the Display is
//! GDK's.
//!
//! Coordinates are X11 root px. A window's rect here is what the user sees:
//! the window manager's frame (_NET_FRAME_EXTENTS) included, GTK's
//! client-side shadow (_GTK_FRAME_EXTENTS) left out.

const std = @import("std");
const gtk = @import("gtk_bindings.zig");
const applog = @import("app_log.zig");

pub const Rect = struct { x: i32, y: i32, w: i32, h: i32 };

/// Left, right, top, bottom margins, px (the order both properties use).
pub const Extents = struct { l: i32 = 0, r: i32 = 0, t: i32 = 0, b: i32 = 0 };

/// The visible rect of an X window whose client area is `client`.
pub fn visibleRect(client: Rect, wm: Extents, csd: Extents) Rect {
    return .{
        .x = client.x - wm.l + csd.l,
        .y = client.y - wm.t + csd.t,
        .w = client.w + wm.l + wm.r - csd.l - csd.r,
        .h = client.h + wm.t + wm.b - csd.t - csd.b,
    };
}

/// XMoveResizeWindow's arguments that show visible rect `v`: (x, y) is the
/// frame's origin, where NorthWest gravity puts the frame's top-left, and
/// (w, h) the client size. Inverse of visibleRect.
pub fn configureFor(v: Rect, wm: Extents, csd: Extents) Rect {
    return .{
        .x = v.x - csd.l,
        .y = v.y - csd.t,
        .w = v.w - wm.l - wm.r + csd.l + csd.r,
        .h = v.h - wm.t - wm.b + csd.t + csd.b,
    };
}

test "a visible rect round-trips through the configure arguments" {
    const client = Rect{ .x = 120, .y = 80, .w = 800, .h = 600 };
    const wm = Extents{ .l = 2, .r = 2, .t = 30, .b = 2 };
    const v = visibleRect(client, wm, .{});
    try std.testing.expectEqual(Rect{ .x = 118, .y = 50, .w = 804, .h = 632 }, v);
    const cfg = configureFor(v, wm, .{});
    // The frame's origin, and the client size it had.
    try std.testing.expectEqual(Rect{ .x = 118, .y = 50, .w = 800, .h = 600 }, cfg);
}

test "a client-side shadow is not part of the visible rect" {
    const client = Rect{ .x = 100, .y = 100, .w = 840, .h = 640 };
    const csd = Extents{ .l = 20, .r = 20, .t = 15, .b = 25 };
    const v = visibleRect(client, .{}, csd);
    try std.testing.expectEqual(Rect{ .x = 120, .y = 115, .w = 800, .h = 600 }, v);
    try std.testing.expectEqual(client, configureFor(v, .{}, csd));
}

/// Where a window `w_px` wide goes for a tab dropped at `drop`: its top edge
/// at the point, centred on it, as Windows places it.
pub fn dropOrigin(drop: [2]f64, w_px: i32) [2]i32 {
    return .{ @as(i32, @intFromFloat(@round(drop[0]))) - @divTrunc(w_px, 2), @intFromFloat(@round(drop[1])) };
}

test "a drop point centres the window's top edge on it" {
    try std.testing.expectEqual([2]i32{ 600, 300 }, dropOrigin(.{ 1000.4, 299.6 }, 800));
}

/// Where an external window `w_px` wide opens, root px, as macOS and
/// Windows choose: a tab's drop point beats the global cell (row, col)
/// on_external_window names, which sits that many cells from `view`, the
/// main grid's top-left. Null (the window manager's choice) for neither,
/// or a cell of -1 (no position).
pub fn extOrigin(drop: ?[2]f64, row: i32, col: i32, view: ?[2]f64, cell_w_px: u32, cell_h_px: u32, w_px: i32) ?[2]i32 {
    if (drop) |d| return dropOrigin(d, w_px);
    if (row < 0 or col < 0) return null;
    const v = view orelse return null;
    return .{
        @as(i32, @intFromFloat(@round(v[0]))) + col * @as(i32, @intCast(cell_w_px)),
        @as(i32, @intFromFloat(@round(v[1]))) + row * @as(i32, @intCast(cell_h_px)),
    };
}

test "an external window opens at its drop point, else at its cell" {
    const view = [2]f64{ 100, 200 };
    try std.testing.expectEqual([2]i32{ 600, 300 }, extOrigin(.{ 1000, 300 }, 3, 4, view, 10, 20, 800).?);
    try std.testing.expectEqual([2]i32{ 140, 260 }, extOrigin(null, 3, 4, view, 10, 20, 800).?);
    try std.testing.expect(extOrigin(null, -1, -1, view, 10, 20, 800) == null);
    try std.testing.expect(extOrigin(null, 3, 4, null, 10, 20, 800) == null);
}

/// Whether (x, y) lies on one of `monitors`: a remembered position from a
/// monitor no longer attached is not restored off screen.
pub fn onAnyMonitor(x: i32, y: i32, monitors: []const Rect) bool {
    for (monitors) |m| {
        if (x >= m.x and y >= m.y and x < m.x + m.w and y < m.y + m.h) return true;
    }
    return false;
}

test "a position is restored only onto an attached monitor" {
    const mons = [_]Rect{ .{ .x = 0, .y = 0, .w = 1920, .h = 1080 }, .{ .x = 1920, .y = 0, .w = 1280, .h = 1024 } };
    try std.testing.expect(onAnyMonitor(2000, 500, &mons));
    try std.testing.expect(!onAnyMonitor(3300, 500, &mons));
    try std.testing.expect(!onAnyMonitor(-10, 0, &mons));
}

// =========================================================================
// Xlib shell
// =========================================================================

const Display = opaque {};
const XWindow = c_ulong;
const Atom = c_ulong;
const xa_cardinal: Atom = 6;

extern "c" fn XTranslateCoordinates(dpy: *Display, src: XWindow, dst: XWindow, src_x: c_int, src_y: c_int, dst_x: *c_int, dst_y: *c_int, child: *XWindow) c_int;
extern "c" fn XGetGeometry(dpy: *Display, d: XWindow, root: *XWindow, x: *c_int, y: *c_int, w: *c_uint, h: *c_uint, border: *c_uint, depth: *c_uint) c_int;
extern "c" fn XMoveWindow(dpy: *Display, w: XWindow, x: c_int, y: c_int) c_int;
extern "c" fn XMoveResizeWindow(dpy: *Display, w: XWindow, x: c_int, y: c_int, width: c_uint, height: c_uint) c_int;
extern "c" fn XInternAtom(dpy: *Display, name: [*:0]const u8, only_if_exists: c_int) Atom;
extern "c" fn XGetWindowProperty(dpy: *Display, w: XWindow, property: Atom, long_offset: c_long, long_length: c_long, delete: c_int, req_type: Atom, actual_type: *Atom, actual_format: *c_int, nitems: *c_ulong, bytes_after: *c_ulong, prop: *?[*]u8) c_int;
extern "c" fn XFree(data: ?*anyopaque) c_int;
extern "c" fn XFlush(dpy: *Display) c_int;

extern "c" fn gdk_x11_display_get_type() usize;
extern "c" fn gdk_x11_display_get_xdisplay(display: *anyopaque) ?*Display;
extern "c" fn gdk_x11_surface_get_xid(surface: *anyopaque) XWindow;
extern "c" fn gdk_surface_get_scale_factor(surface: *anyopaque) c_int;
extern "c" fn gtk_native_get_surface_transform(native: *anyopaque, x: *f64, y: *f64) void;
extern "c" fn g_type_check_instance_is_a(instance: *anyopaque, iface_type: usize) c_int;
extern "c" fn gdk_display_get_monitors(display: *anyopaque) ?*anyopaque;
extern "c" fn g_list_model_get_n_items(list: *anyopaque) c_uint;
extern "c" fn g_list_model_get_item(list: *anyopaque, position: c_uint) ?*anyopaque;
extern "c" fn gdk_monitor_get_geometry(monitor: *anyopaque, geometry: *GdkRectangle) void;
extern "c" fn g_object_unref(object: *anyopaque) void;

const GdkRectangle = extern struct { x: c_int = 0, y: c_int = 0, width: c_int = 0, height: c_int = 0 };

/// GDK's X display, or null under any other backend (Wayland).
fn xdisplay() ?*Display {
    const display = gtk.gdk_display_get_default() orelse return null;
    if (g_type_check_instance_is_a(display, gdk_x11_display_get_type()) == 0) return null;
    return gdk_x11_display_get_xdisplay(display);
}

/// The session is X11: windows can be placed. False on Wayland.
pub fn active() bool {
    return xdisplay() != null;
}

const Target = struct { dpy: *Display, xid: XWindow, scale: i32 };

/// `win`'s X window, once realized. Null on Wayland.
fn target(win: *anyopaque) ?Target {
    const dpy = xdisplay() orelse return null;
    const surface = gtk.gtk_native_get_surface(win) orelse return null;
    const xid = gdk_x11_surface_get_xid(surface);
    if (xid == 0) return null;
    return .{ .dpy = dpy, .xid = xid, .scale = @max(1, gdk_surface_get_scale_factor(surface)) };
}

fn extents(t: Target, name: [*:0]const u8) Extents {
    const atom = XInternAtom(t.dpy, name, 1);
    if (atom == 0) return .{};
    var actual_type: Atom = 0;
    var format: c_int = 0;
    var n: c_ulong = 0;
    var after: c_ulong = 0;
    var data: ?[*]u8 = null;
    if (XGetWindowProperty(t.dpy, t.xid, atom, 0, 4, 0, xa_cardinal, &actual_type, &format, &n, &after, &data) != 0) return .{};
    defer _ = XFree(data);
    const bytes = data orelse return .{};
    if (actual_type != xa_cardinal or format != 32 or n < 4) return .{};
    // Format 32 comes back as C longs.
    const v: [*]align(1) const c_long = @ptrCast(bytes);
    return .{ .l = @intCast(v[0]), .r = @intCast(v[1]), .t = @intCast(v[2]), .b = @intCast(v[3]) };
}

fn clientRect(t: Target) ?Rect {
    var root: XWindow = 0;
    var x: c_int = 0;
    var y: c_int = 0;
    var w: c_uint = 0;
    var h: c_uint = 0;
    var border: c_uint = 0;
    var depth: c_uint = 0;
    if (XGetGeometry(t.dpy, t.xid, &root, &x, &y, &w, &h, &border, &depth) == 0) return null;
    var child: XWindow = 0;
    if (XTranslateCoordinates(t.dpy, t.xid, root, 0, 0, &x, &y, &child) == 0) return null;
    return .{ .x = x, .y = y, .w = @intCast(w), .h = @intCast(h) };
}

/// `win`'s visible rect, root px. Null on Wayland or before realize.
pub fn frame(win: *anyopaque) ?Rect {
    const t = target(win) orelse return null;
    const c = clientRect(t) orelse return null;
    return visibleRect(c, extents(t, "_NET_FRAME_EXTENTS"), extents(t, "_GTK_FRAME_EXTENTS"));
}

/// Shows `win` with its visible rect at `v`, root px; `keep_size` moves it
/// only. Nothing on Wayland. The window manager may still refuse (a
/// tiling one owns the geometry).
pub fn place(win: *anyopaque, v: Rect, keep_size: bool) void {
    const t = target(win) orelse return;
    const cfg = configureFor(v, extents(t, "_NET_FRAME_EXTENTS"), extents(t, "_GTK_FRAME_EXTENTS"));
    if (keep_size or cfg.w <= 0 or cfg.h <= 0) {
        _ = XMoveWindow(t.dpy, t.xid, cfg.x, cfg.y);
    } else {
        _ = XMoveResizeWindow(t.dpy, t.xid, cfg.x, cfg.y, @intCast(cfg.w), @intCast(cfg.h));
    }
    _ = XFlush(t.dpy);
}

/// Root px of `widget`'s top-left, a descendant of toplevel `win`, offset
/// by (dx, dy) logical px.
pub fn widgetPoint(win: *anyopaque, widget: *anyopaque, dx: f64, dy: f64) ?[2]f64 {
    const t = target(win) orelse return null;
    const c = clientRect(t) orelse return null;
    var b: gtk.GrapheneRect = .{};
    if (gtk.gtk_widget_compute_bounds(widget, win, &b) == 0) return null;
    // The X window is the surface, which may hold a shadow around `win`.
    var sx: f64 = 0;
    var sy: f64 = 0;
    gtk_native_get_surface_transform(win, &sx, &sy);
    const s: f64 = @floatFromInt(t.scale);
    return .{
        @as(f64, @floatFromInt(c.x)) + (sx + b.x + dx) * s,
        @as(f64, @floatFromInt(c.y)) + (sy + b.y + dy) * s,
    };
}

/// `win`'s px per logical px; 1 on Wayland.
pub fn scale(win: *anyopaque) i32 {
    const t = target(win) orelse return 1;
    return t.scale;
}

/// Whether root point (x, y) lies on an attached monitor. True on Wayland,
/// where nothing is placed anyway.
pub fn onScreen(x: i32, y: i32, scale_px: i32) bool {
    const display = gtk.gdk_display_get_default() orelse return true;
    const list = gdk_display_get_monitors(display) orelse return true;
    var mons: [16]Rect = undefined;
    var n: usize = 0;
    const count = g_list_model_get_n_items(list);
    var i: c_uint = 0;
    while (i < count and n < mons.len) : (i += 1) {
        const m = g_list_model_get_item(list, i) orelse continue;
        defer g_object_unref(m);
        var g: GdkRectangle = .{};
        gdk_monitor_get_geometry(m, &g);
        // GDK reports monitors in logical px.
        mons[n] = .{ .x = g.x * scale_px, .y = g.y * scale_px, .w = g.width * scale_px, .h = g.height * scale_px };
        n += 1;
    }
    if (n == 0) return true;
    return onAnyMonitor(x, y, mons[0..n]);
}

/// Shows toplevel `win`, not yet mapped, with its visible top-left at
/// `slot.*` (root px): once when realized and again on its first map, as a
/// window manager places a new toplevel itself on map unless it honours the
/// earlier request. A point off every attached monitor is dropped. `slot`
/// outlives that first map, which clears it; a later map is the user's
/// window coming back where they left it. Nothing on Wayland.
pub fn placeWhenShown(win: *anyopaque, slot: *?[2]i32) void {
    // Both run after GTK's own handler, which creates or maps the X window.
    _ = gtk.g_signal_connect(win, "realize", @ptrCast(&onRealizePlace), slot);
    _ = gtk.g_signal_connect(win, "map", @ptrCast(&onMapPlace), slot);
}

fn onRealizePlace(win: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const slot: *?[2]i32 = @ptrCast(@alignCast(data.?));
    const pos = slot.* orelse return;
    moveShown(win.?, pos);
}

fn onMapPlace(win: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const slot: *?[2]i32 = @ptrCast(@alignCast(data.?));
    const pos = slot.* orelse return;
    slot.* = null;
    moveShown(win.?, pos);
}

fn moveShown(win: *anyopaque, pos: [2]i32) void {
    if (!onScreen(pos[0], pos[1], scale(win))) return;
    place(win, .{ .x = pos[0], .y = pos[1], .w = 0, .h = 0 }, true);
    if (frame(win)) |f| applog.appLog("[x11_place] place at ({d},{d}) now ({d},{d}) {d}x{d}\n", .{ pos[0], pos[1], f.x, f.y, f.w, f.h });
}
