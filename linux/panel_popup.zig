//! The ext UI panels (cmdline, popupmenu, msg_show, msg_history) as popup
//! surfaces of their own, on the main window or on the external window a
//! panel is anchored in (popup_place.hostSurface), as macOS and Windows make
//! them borderless windows. Wayland places no toplevel where a client asks,
//! so an xdg_popup without a grab is the closest equivalent: it is
//! positioned against its parent, moves with it, takes no keyboard focus,
//! and may reach past the window as far as the compositor lets it (it
//! slides a popup back onto the output).
//!
//! While the panels are popups (App.panel_popups) no view draws them. A
//! popup that cannot be made turns this off and they are drawn inside their
//! window again. The pointer over a popup is handled as the pointer over
//! the place in its host's view the panel was laid out at (toHost), so the
//! panels' hit-testing is the layout's whether they are popups or not.
//! Main thread only.

const std = @import("std");
const core = @import("zonvie_core");
const clock = core.clock;
const App = @import("app.zig").App;
const gl_renderer = @import("renderer/gl_renderer.zig");
const overlay_layout = @import("overlay_layout.zig");
const popup_place = @import("popup_place.zig");
const applog = @import("app_log.zig");
const Kind = overlay_layout.Kind;

extern "c" fn zwl_popup_open(id: i64, parent_id: i64, x: i32, y: i32, w: i32, h: i32, anchor_x: i32, anchor_y: i32, scale: i32) c_int;
extern "c" fn zwl_ext_close(id: i64) void;
extern "c" fn zwl_ext_make_current(id: i64) c_int;
extern "c" fn zwl_ext_swap(id: i64) c_int;
extern "c" fn zwl_ext_request_frame(id: i64) void;
extern "c" fn zwl_ext_frame_pending(id: i64) c_int;
extern "c" fn zwl_dispatch_pending() c_int;
extern "c" fn zwl_flush() c_int;

pub const Popup = struct {
    kind: Kind,
    gl: gl_renderer.Target = .{},
    realized: bool = false,
    /// The surface (1, or an external window's grid) it is a popup of.
    host: i64 = 1,
    /// The placement it was opened with, which it is drawn by.
    frame: popup_place.Frame = .{ .origin_pt = .{ 0, 0 }, .size_pt = .{ 1, 1 }, .inner = .{ .x = 0, .y = 0, .w = 0, .h = 0 } },
    /// The panel on its host's view, device px.
    rect: overlay_layout.Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    /// Its host view's origin in the host window, logical px, as opened.
    view_at_pt: [2]i32 = .{ 0, 0 },
    scale: i32 = 1,
    /// The surface exists.
    shown: bool = false,
    /// It was configured, so a buffer may be attached.
    configured: bool = false,
    dirty: bool = false,
};

/// A popup's id among wl/window.c's windows: negative, so never a grid's.
fn idOf(kind: Kind) i64 {
    return -(@as(i64, @intFromEnum(kind)) + 1);
}

pub fn kindOfId(id: i64) ?Kind {
    if (id >= 0 or id < -4) return null;
    return @enumFromInt(@as(u8, @intCast(-id - 1)));
}

/// The panels become popups. Call once the window exists.
pub fn init(app: *App) void {
    for (&app.popups, 0..) |*p, i| p.* = .{ .kind = @enumFromInt(i) };
    app.mu.lockUncancelable(clock.io());
    app.panel_popups = true;
    app.mu.unlock(clock.io());
}

/// At shutdown, with the windows still there.
pub fn deinit(app: *App) void {
    for (&app.popups) |*p| {
        hide(app, p);
        p.gl.deinit(app.alloc);
    }
}

/// Surface `surface_id`'s view: its size (device px) and origin in its
/// window (logical px). Null for an external window not open. Caller holds
/// App.mu.
fn hostView(app: *const App, surface_id: i64) ?struct { size: [2]u32, at_pt: [2]i32 } {
    if (surface_id == 1) {
        const s: i32 = @max(1, @as(i32, @intFromFloat(app.scale)));
        return .{ .size = .{ app.drawable_w_px, app.drawable_h_px }, .at_pt = .{ @divTrunc(app.view_x_px, s), @divTrunc(app.view_y_px, s) } };
    }
    const w = app.ext_windows.get(surface_id) orelse return null;
    if (!w.configured) return null;
    return .{ .size = .{ w.w_px, w.h_px }, .at_pt = .{ 0, 0 } };
}

/// Shows, moves, resizes or hides every popup by the panels' layout, and
/// redraws the shown ones. While the app is inactive only the panels
/// popup_place.shownWhileInactive keeps stay shown. After every flush, a
/// panel drag, a view resize and an activation change.
pub fn update(app: *App) void {
    if (!app.panel_popups) return;
    for (&app.popups) |*p| {
        if (!app.panel_popups) return;
        const Want = struct { host: i64, frame: popup_place.Frame, rect: overlay_layout.Rect, at_pt: [2]i32, view_pt: [2]i32, scale: i32 };
        const want: ?Want = blk: {
            app.mu.lockUncancelable(clock.io());
            defer app.mu.unlock(clock.io());
            if (app.cell_w_px == 0 or app.cell_h_px == 0) break :blk null;
            const scale: i32 = @max(1, @as(i32, @intFromFloat(app.scale)));
            const main_in = gl_renderer.overlayInputs(app, 1, @max(1, app.drawable_w_px), @max(1, app.drawable_h_px));
            const host = popup_place.hostSurface(p.kind, main_in.cmdline_surface, main_in.pum_surface, main_in.msg_surface);
            const hv = hostView(app, host) orelse break :blk null;
            if (hv.size[0] == 0 or hv.size[1] == 0) break :blk null;
            // A panel whose grid has no rows yet draws nothing.
            if (app.surface.committedSurfaceLayers(overlay_layout.gridId(p.kind)).len == 0) break :blk null;
            if (!app.app_active and !popup_place.shownWhileInactive(p.kind)) break :blk null;
            const rects = overlay_layout.place(&app.overlays, gl_renderer.overlayInputs(app, host, hv.size[0], hv.size[1]));
            const r = rects[@intFromEnum(p.kind)] orelse break :blk null;
            break :blk .{
                .host = host,
                .frame = popup_place.frame(r, scale),
                .rect = r,
                .at_pt = hv.at_pt,
                .view_pt = .{ @max(1, @divTrunc(@as(i32, @intCast(hv.size[0])), scale)), @max(1, @divTrunc(@as(i32, @intCast(hv.size[1])), scale)) },
                .scale = scale,
            };
        };
        const wnt = want orelse {
            hide(app, p);
            continue;
        };
        // Most flushes leave a shown panel where it is: only its contents
        // change.
        if (p.shown and p.host == wnt.host and std.meta.eql(p.frame, wnt.frame) and std.meta.eql(p.view_at_pt, wnt.at_pt) and p.scale == wnt.scale) {
            p.rect = wnt.rect;
            render(app, p);
            continue;
        }
        // xdg_popup (v2) has no way to move one: it is made anew.
        hide(app, p);
        p.host = wnt.host;
        p.frame = wnt.frame;
        p.rect = wnt.rect;
        p.view_at_pt = wnt.at_pt;
        p.scale = wnt.scale;
        const a = popup_place.anchor(wnt.frame.origin_pt, wnt.view_pt[0], wnt.view_pt[1]);
        const rc = zwl_popup_open(
            idOf(p.kind),
            if (wnt.host == 1) 0 else wnt.host,
            wnt.at_pt[0] + wnt.frame.origin_pt[0],
            wnt.at_pt[1] + wnt.frame.origin_pt[1],
            wnt.frame.size_pt[0],
            wnt.frame.size_pt[1],
            wnt.at_pt[0] + a.point[0],
            wnt.at_pt[1] + a.point[1],
            wnt.scale,
        );
        if (rc != 0) return fallBack(app);
        p.shown = true;
        applog.appLog("[panel_popup] show {s} on surface {d}\n", .{ @tagName(p.kind), p.host });
    }
}

fn hide(app: *App, p: *Popup) void {
    if (!p.shown) return;
    p.shown = false;
    p.configured = false;
    p.dirty = false;
    if (p.realized and zwl_ext_make_current(idOf(p.kind)) == 0) {
        gl_renderer.unrealize(&p.gl);
        p.realized = false;
    }
    // Leaves the main window's surface current.
    zwl_ext_close(idOf(p.kind));
    _ = app;
    applog.appLog("[panel_popup] hide {s}\n", .{@tagName(p.kind)});
}

/// Draws popup `p` now, or at the frame callback of the frame before.
fn render(app: *App, p: *Popup) void {
    if (!p.shown or !p.configured) return;
    if (zwl_ext_frame_pending(idOf(p.kind)) != 0) {
        p.dirty = true;
        return;
    }
    draw(app, p);
}

fn draw(app: *App, p: *Popup) void {
    const id = idOf(p.kind);
    {
        if (zwl_ext_make_current(id) != 0) return;
        defer _ = zwl_ext_make_current(0);
        if (!p.realized) {
            if (!gl_renderer.realize(&p.gl)) return fallBack(app);
            p.realized = true;
        }
        p.dirty = false;
        p.gl.w_px = @intCast(p.frame.size_pt[0] * p.scale);
        p.gl.h_px = @intCast(p.frame.size_pt[1] * p.scale);
        p.gl.ox_px = 0;
        p.gl.oy_px = 0;
        p.gl.fb_w_px = p.gl.w_px;
        p.gl.fb_h_px = p.gl.h_px;
        gl_renderer.renderPanel(app, &p.gl, p.kind, p.frame.inner, p.rect);
        // The main window's UI layer where the popup covers it: the panel's
        // copy button and the IME's composition are drawn there.
        if (p.host == 1) gl_renderer.drawUiShifted(app, &p.gl, (p.view_at_pt[0] + p.frame.origin_pt[0]) * p.scale, (p.view_at_pt[1] + p.frame.origin_pt[1]) * p.scale);
        zwl_ext_request_frame(id);
        _ = zwl_ext_swap(id);
    }
    // Dispatched with the main window's surface current again: a handler
    // may draw the main window (ext_window.draw).
    _ = zwl_dispatch_pending();
    _ = zwl_flush();
}

/// Redraws the shown popups (a blink, an eased frame).
pub fn queueRender(app: *App) void {
    if (!app.panel_popups) return;
    for (&app.popups) |*p| render(app, p);
}

/// wl/window.c: popup `kind` was configured.
pub fn onConfigure(app: *App, kind: Kind) void {
    const p = &app.popups[@intFromEnum(kind)];
    if (!p.shown) return;
    p.configured = true;
    draw(app, p);
}

/// wl/window.c: the compositor dismissed popup `kind`. The next update
/// makes it again if its panel is still open.
pub fn onDismissed(app: *App, kind: Kind) void {
    hide(app, &app.popups[@intFromEnum(kind)]);
}

pub fn onFrame(app: *App, kind: Kind) void {
    const p = &app.popups[@intFromEnum(kind)];
    if (p.dirty) draw(app, p);
}

/// Surface `surface_id` is about to close: its popups go first, since a
/// popup dies with its parent.
pub fn surfaceClosing(app: *App, surface_id: i64) void {
    if (!app.panel_popups) return;
    for (&app.popups) |*p| {
        if (p.host == surface_id) hide(app, p);
    }
}

/// A point of popup `kind` (logical px from its top-left) as its host and
/// the point of the host's window the panel was laid out at there.
pub fn toHost(app: *App, kind: Kind, x: f64, y: f64) struct { host: i64, x: f64, y: f64 } {
    const p = &app.popups[@intFromEnum(kind)];
    return .{
        .host = p.host,
        .x = x + @as(f64, @floatFromInt(p.view_at_pt[0] + p.frame.origin_pt[0])),
        .y = y + @as(f64, @floatFromInt(p.view_at_pt[1] + p.frame.origin_pt[1])),
    };
}

/// The main window is about to be unmapped (the tray): its popups go.
pub fn hideAll(app: *App) void {
    if (!app.panel_popups) return;
    for (&app.popups) |*p| hide(app, p);
}

/// The panels go back into their windows: a popup could not be made.
fn fallBack(app: *App) void {
    if (!app.panel_popups) return;
    applog.appLog("[panel_popup] unavailable; panels drawn in their windows\n", .{});
    for (&app.popups) |*p| hide(app, p);
    app.mu.lockUncancelable(clock.io());
    app.panel_popups = false;
    app.mu.unlock(clock.io());
    app.queueRenderAll();
}

test "a popup's id is negative and names its panel back" {
    inline for (.{ Kind.cmdline, Kind.popupmenu, Kind.msg_show, Kind.msg_history }) |k| {
        try std.testing.expect(idOf(k) < 0);
        try std.testing.expectEqual(@as(?Kind, k), kindOfId(idOf(k)));
    }
    // Grid ids (external windows) and the main window are no popup.
    try std.testing.expectEqual(@as(?Kind, null), kindOfId(0));
    try std.testing.expectEqual(@as(?Kind, null), kindOfId(4));
    try std.testing.expectEqual(@as(?Kind, null), kindOfId(-5));
}
