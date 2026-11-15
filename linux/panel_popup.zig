//! The ext UI panels (cmdline, popupmenu, msg_show, msg_history) as popup
//! surfaces of their own, on the main view or on the external window a panel
//! is anchored in (popup_place.hostSurface), as macOS and Windows make
//! them borderless windows: each a GtkPopover (no arrow, no autohide, so no
//! grab and no keyboard focus) parented to the editor view and holding a
//! GtkGLArea that draws the panel (gl_renderer.renderPanel). Wayland places
//! no toplevel where a client asks, so a popup is the closest equivalent: it
//! is positioned against the view (gtk_popover_set_pointing_to and
//! gtk_popover_set_offset, popup_place.anchor), moves with the window by
//! itself, and may reach past it as far as the compositor's constraint
//! adjustment allows (it slides a popup back onto the output).
//!
//! While the panels are popups (App.panel_popups) the main view draws none
//! of them; a GL context that cannot be made turns this off and they are
//! drawn inside the main view again. GTK main thread only.

const std = @import("std");
const core = @import("zonvie_core");
const clock = core.clock;
const App = @import("app.zig").App;
const gtk = @import("gtk_bindings.zig");
const gl_renderer = @import("renderer/gl_renderer.zig");
const overlay_layout = @import("overlay_layout.zig");
const popup_place = @import("popup_place.zig");
const input = @import("input.zig");
const ui_widgets = @import("ui_widgets.zig");
const blur = @import("blur.zig");
const applog = @import("app_log.zig");
const Kind = overlay_layout.Kind;

pub const Popup = struct {
    app: *App,
    kind: Kind,
    popover: *anyopaque,
    /// Holds the GLArea, and the panel's copy button and (for the cmdline)
    /// preedit label over it.
    overlay: *anyopaque,
    area: *anyopaque,
    gl: gl_renderer.Target = .{},
    /// The pointer over the popup: its host surface's panels, this one only.
    pointer: input.Pointer,
    /// The surface (1, or an external window's grid) whose view the popover
    /// is parented to.
    host: i64 = 1,
    /// The cmdline's IME composition label; null on the other panels.
    preedit_label: ?*anyopaque = null,
    /// The placement last applied, which the render signal draws by.
    frame: popup_place.Frame = .{ .origin_pt = .{ 0, 0 }, .size_pt = .{ 1, 1 }, .inner = .{ .x = 0, .y = 0, .w = 0, .h = 0 } },
    /// The view size `frame` was anchored in.
    view_pt: [2]i32 = .{ 0, 0 },
    shown: bool = false,
    /// Where the popup is on its parent surface as of its last committed
    /// frame; null until one is committed since it was shown. GDK takes a
    /// new position at the compositor's configure, but pointer events keep
    /// the old one until the frame that acknowledges it is committed, so a
    /// popup dragged under the pointer reads its position here.
    committed_pos: ?[2]c_int = null,
    /// A position committed but not yet in effect for pointer events, and
    /// the one an in-flight wl_display.sync makes effective when it answers
    /// (Wayland only; see onAfterPaint).
    pending_pos: ?[2]c_int = null,
    sync_pos: ?[2]c_int = null,
    /// The frame clock watched for those commits and the handler on it.
    clock: ?*anyopaque = null,
    clock_handler: c_ulong = 0,
};

fn popupFrom(data: ?*anyopaque) *Popup {
    return @ptrCast(@alignCast(data.?));
}

/// The popover and its contents draw nothing of their own: the GLArea
/// paints the panel, its shadow included, on a transparent surface.
const css =
    \\popover.zonvie-panel-popup, popover.zonvie-panel-popup > contents {
    \\  background: none; border: none; box-shadow: none; outline: none;
    \\  padding: 0; margin: 0; border-radius: 0; min-width: 0; min-height: 0;
    \\}
;

/// Makes the four popups over the editor view and moves the copy buttons
/// into theirs. Call once, after ui_widgets.build. Without the view nothing
/// is made and the panels stay in the main view.
pub fn init(app: *App) void {
    const view = app.widgets.overlay orelse return;
    if (gtk.gtk_css_provider_new()) |provider| {
        gtk.gtk_css_provider_load_from_string(provider, css);
        if (gtk.gtk_widget_get_display(view)) |d| gtk.gtk_style_context_add_provider_for_display(d, provider, gtk.GTK_STYLE_PROVIDER_PRIORITY_APPLICATION);
    }
    for (0..app.popups.len) |i| {
        app.popups[i] = create(app, view, @enumFromInt(i)) orelse {
            destroyAll(app);
            return;
        };
    }
    app.mu.lockUncancelable(clock.io());
    app.panel_popups = true;
    app.mu.unlock(clock.io());
    moveCopyButtons(app, true);
}

fn create(app: *App, view: *anyopaque, kind: Kind) ?*Popup {
    const pop = gtk.gtk_popover_new() orelse return null;
    const overlay = gtk.gtk_overlay_new() orelse return null;
    const area = gtk.gtk_gl_area_new() orelse return null;
    const p = app.alloc.create(Popup) catch return null;
    p.* = .{ .app = app, .kind = kind, .popover = pop, .overlay = overlay, .area = area, .pointer = .{ .app = app, .panel = kind } };
    gtk.gtk_widget_add_css_class(pop, "zonvie-panel-popup");
    gtk.gtk_popover_set_has_arrow(pop, 0);
    gtk.gtk_popover_set_autohide(pop, 0);
    // The popup's top-left at the anchor's bottom-left (popup_place.Anchor).
    gtk.gtk_popover_set_position(pop, gtk.GTK_POS_BOTTOM);
    gtk.gtk_widget_set_halign(pop, gtk.GTK_ALIGN_START);
    gtk.gtk_gl_area_set_required_version(area, 3, 3);
    gtk.gtk_gl_area_set_has_depth_buffer(area, 0);
    gtk.gtk_gl_area_set_allowed_apis(area, gtk.GDK_GL_API_GL);
    // Keys stay with the editor view.
    gtk.gtk_widget_set_focusable(area, 0);
    _ = gtk.g_signal_connect(area, "realize", @ptrCast(&onRealize), p);
    _ = gtk.g_signal_connect(area, "unrealize", @ptrCast(&onUnrealize), p);
    _ = gtk.g_signal_connect(area, "render", @ptrCast(&onRender), p);
    _ = gtk.g_signal_connect(area, "resize", @ptrCast(&onResize), p);
    _ = gtk.g_signal_connect(pop, "realize", @ptrCast(&onPopoverRealize), p);
    _ = gtk.g_signal_connect(pop, "unrealize", @ptrCast(&onPopoverUnrealize), p);
    gtk.gtk_overlay_set_child(overlay, area);
    input.attachPopup(&p.pointer, area, overlay);
    if (kind == .cmdline) {
        if (ui_widgets.newPreeditLabel()) |label| {
            p.preedit_label = label;
            gtk.gtk_overlay_add_overlay(overlay, label);
        }
    }
    gtk.gtk_popover_set_child(pop, overlay);
    gtk.gtk_widget_set_parent(pop, view);
    // The popup surface is blurred behind as a whole, its shadow margin
    // included, as the toplevels are (blur.zig).
    if (app.window_cfg.blur) blur.watch(app, pop);
    return p;
}

fn destroyAll(app: *App) void {
    for (&app.popups) |*slot| {
        const p = slot.* orelse continue;
        gtk.gtk_widget_unparent(p.popover);
        p.gl.deinit(app.alloc);
        app.alloc.destroy(p);
        slot.* = null;
    }
}

/// Popups exist: a sync answered after deinit touches none.
var alive = true;

/// At shutdown, once the window (and the popovers with it) is gone.
pub fn deinit(app: *App) void {
    alive = false;
    for (&app.popups) |*slot| {
        const p = slot.* orelse continue;
        p.gl.deinit(app.alloc);
        app.alloc.destroy(p);
        slot.* = null;
    }
}

/// The copy buttons in the popups' overlays (`into`), or back over the view.
fn moveCopyButtons(app: *App, into: bool) void {
    const view = app.widgets.overlay orelse return;
    for (app.widgets.copy, 0..) |btn, i| {
        const b = btn orelse continue;
        const p = app.popups[i] orelse continue;
        _ = gtk.g_object_ref(b);
        defer gtk.g_object_unref(b);
        gtk.gtk_overlay_remove_overlay(if (into) view else p.overlay, b);
        gtk.gtk_overlay_add_overlay(if (into) p.overlay else view, b);
    }
}

/// Shows, moves, resizes or hides every popup by the panels' layout on the
/// main view, and redraws the shown ones. While the app is inactive only the
/// panels popup_place.shownWhileInactive keeps stay shown, as macOS and
/// Windows take the others off the top level then. After every flush, a
/// panel drag, a view resize and an activation change.
pub fn update(app: *App) void {
    if (!app.panel_popups) return;
    var scale: i32 = 1;
    var hosts: [4]i64 = @splat(1);
    {
        app.mu.lockUncancelable(clock.io());
        defer app.mu.unlock(clock.io());
        scale = @max(1, @as(i32, @intFromFloat(app.scale)));
        const in = gl_renderer.overlayInputs(app, 1, @max(1, app.drawable_w_px), @max(1, app.drawable_h_px));
        for (&hosts, 0..) |*h, i| h.* = popup_place.hostSurface(@enumFromInt(i), in.pum_surface, in.msg_surface);
    }
    for (app.popups, 0..) |slot, i| {
        // A popup's realize just fell back.
        if (!app.panel_popups) return;
        const p = slot orelse continue;
        const host = hostView(app, hosts[i]) orelse {
            hide(p);
            continue;
        };
        if (p.host != hosts[i]) reparent(p, hosts[i], host.view);
        const vw = gtk.gtk_widget_get_width(host.view);
        const vh = gtk.gtk_widget_get_height(host.view);
        const r: ?overlay_layout.Rect = blk: {
            if (vw <= 0 or vh <= 0) break :blk null;
            app.mu.lockUncancelable(clock.io());
            defer app.mu.unlock(clock.io());
            const size = hostSizePx(app, p.host);
            if (size[0] == 0 or size[1] == 0 or app.cell_w_px == 0 or app.cell_h_px == 0) break :blk null;
            const rects = overlay_layout.place(&app.overlays, gl_renderer.overlayInputs(app, p.host, size[0], size[1]));
            // A panel whose grid has no rows yet draws nothing.
            if (app.surface.committedSurfaceLayers(overlay_layout.gridId(p.kind)).len == 0) break :blk null;
            break :blk rects[@intFromEnum(p.kind)];
        };
        const rect = r orelse {
            hide(p);
            continue;
        };
        if (!app.app_active and !popup_place.shownWhileInactive(p.kind)) {
            hide(p);
            continue;
        }
        place(p, popup_place.frame(rect, scale), vw, vh);
    }
}

/// A surface's editor view and the toplevel holding it; null for an
/// external window not (or no longer) open. Takes no lock: callers may hold
/// App.mu (input.panelAt does, through panelRect).
pub const Host = struct { view: *anyopaque, window: *anyopaque };

pub fn hostView(app: *App, surface_id: i64) ?Host {
    if (surface_id == 1) return .{ .view = app.widgets.overlay orelse return null, .window = app.window orelse return null };
    const w = app.ext_windows.get(surface_id) orelse return null;
    // The external window's child: an overlay over its GLArea.
    const area = w.area orelse return null;
    return .{ .view = gtk.gtk_widget_get_parent(area) orelse return null, .window = w.window orelse return null };
}

/// Surface `surface_id`'s view size, device px; 0 x 0 for none. Caller
/// holds App.mu.
pub fn hostSizePx(app: *const App, surface_id: i64) [2]u32 {
    if (surface_id == 1) return .{ app.drawable_w_px, app.drawable_h_px };
    const w = app.ext_windows.get(surface_id) orelse return .{ 0, 0 };
    return .{ w.gl.w_px, w.gl.h_px };
}

/// Surface `surface_id` is about to close: its popups go back to the main
/// view first, since a popover dies with the window it is parented in.
/// Pre: GTK main thread, before the external window is destroyed.
pub fn surfaceClosing(app: *App, surface_id: i64) void {
    std.debug.assert(surface_id != 1);
    const main = app.widgets.overlay orelse return;
    for (app.popups) |slot| {
        const p = slot orelse continue;
        if (p.host == surface_id) reparent(p, 1, main);
    }
}

/// Moves popup `p` onto surface `host`'s view. Its GL context is made again
/// there (onRealize), and its pointer addresses that surface's panels.
fn reparent(p: *Popup, host: i64, view: *anyopaque) void {
    hide(p);
    // The parent holds the popover's only reference: held across the move,
    // or unparenting finalizes it.
    _ = gtk.g_object_ref(p.popover);
    defer gtk.g_object_unref(p.popover);
    gtk.gtk_widget_unparent(p.popover);
    gtk.gtk_widget_set_parent(p.popover, view);
    p.host = host;
    p.pointer.surface_id = host;
    p.frame = .{ .origin_pt = .{ 0, 0 }, .size_pt = .{ 1, 1 }, .inner = .{ .x = 0, .y = 0, .w = 0, .h = 0 } };
    p.view_pt = .{ 0, 0 };
    applog.appLog("[panel_popup] {s} now on surface {d}\n", .{ @tagName(p.kind), host });
}

fn place(p: *Popup, f: popup_place.Frame, view_w_pt: i32, view_h_pt: i32) void {
    // Most flushes leave a shown panel where it is: only its contents change.
    if (p.shown and std.meta.eql(p.frame, f) and p.view_pt[0] == view_w_pt and p.view_pt[1] == view_h_pt) {
        gtk.gtk_gl_area_queue_render(p.area);
        return;
    }
    p.frame = f;
    p.view_pt = .{ view_w_pt, view_h_pt };
    gtk.gtk_widget_set_size_request(p.area, f.size_pt[0], f.size_pt[1]);
    const a = popup_place.anchor(f.origin_pt, view_w_pt, view_h_pt);
    const point: gtk.GdkRectangle = .{ .x = a.point[0], .y = a.point[1], .width = 1, .height = 1 };
    gtk.gtk_popover_set_pointing_to(p.popover, &point);
    gtk.gtk_popover_set_offset(p.popover, a.offset[0], a.offset[1]);
    if (p.shown) {
        gtk.gtk_popover_present(p.popover);
    } else {
        p.shown = true;
        // Realizes the GLArea the first time, which may fall back.
        gtk.gtk_popover_popup(p.popover);
        if (!p.app.panel_popups) return hide(p);
        applog.appLog("[panel_popup] show {s}\n", .{@tagName(p.kind)});
    }
    gtk.gtk_gl_area_queue_render(p.area);
}

fn hide(p: *Popup) void {
    if (!p.shown) return;
    p.shown = false;
    p.committed_pos = null;
    p.pending_pos = null;
    gtk.gtk_popover_popdown(p.popover);
    input.panelLeft(&p.pointer);
    applog.appLog("[panel_popup] hide {s}\n", .{@tagName(p.kind)});
}

/// Redraws the shown popups.
pub fn queueRender(app: *App) void {
    for (app.popups) |slot| {
        const p = slot orelse continue;
        if (p.shown) gtk.gtk_gl_area_queue_render(p.area);
    }
}

/// Logical px from popup `kind`'s area to the view, where the compositor
/// put it; the placement asked for until it is mapped. Null while hidden.
pub fn viewOrigin(app: *App, kind: Kind) ?[2]f64 {
    const p = app.popups[@intFromEnum(kind)] orelse return null;
    if (!p.shown) return null;
    const asked: [2]f64 = .{ @floatFromInt(p.frame.origin_pt[0]), @floatFromInt(p.frame.origin_pt[1]) };
    if (gtk.gtk_widget_get_mapped(p.popover) == 0) return asked;
    const pos = p.committed_pos orelse return asked;
    const host = hostView(app, p.host) orelse return asked;
    const win = host.window;
    const view = host.view;
    var area_in: gtk.GrapheneRect = .{};
    var view_in: gtk.GrapheneRect = .{};
    if (gtk.gtk_widget_compute_bounds(p.area, p.popover, &area_in) == 0) return asked;
    if (gtk.gtk_widget_compute_bounds(view, win, &view_in) == 0) return asked;
    var pop_t: [2]f64 = .{ 0, 0 };
    var win_t: [2]f64 = .{ 0, 0 };
    gtk.gtk_native_get_surface_transform(p.popover, &pop_t[0], &pop_t[1]);
    gtk.gtk_native_get_surface_transform(win, &win_t[0], &win_t[1]);
    return popup_place.viewOrigin(
        .{ @floatFromInt(pos[0]), @floatFromInt(pos[1]) },
        .{ pop_t[0] + area_in.x, pop_t[1] + area_in.y },
        .{ win_t[0] + view_in.x, win_t[1] + view_in.y },
    );
}

/// Panel `kind` on the view, device px, where its shown popup really is.
/// Null while hidden or not a popup.
pub fn panelRect(app: *App, kind: Kind, scale: i32) ?overlay_layout.Rect {
    const o = viewOrigin(app, kind) orelse return null;
    const p = app.popups[@intFromEnum(kind)].?;
    return popup_place.panelRect(p.frame, .{ @intFromFloat(@round(o[0])), @intFromFloat(@round(o[1])) }, scale);
}

/// The cmdline popup's preedit label and `at` (view logical px) in its
/// coordinates, when the cmdline is a shown popup holding that point.
pub fn cmdlinePreedit(app: *App, at: gtk.GdkRectangle) ?struct { label: *anyopaque, at: gtk.GdkRectangle } {
    const p = app.popups[@intFromEnum(Kind.cmdline)] orelse return null;
    const label = p.preedit_label orelse return null;
    const o = viewOrigin(app, .cmdline) orelse return null;
    const x = at.x - @as(c_int, @intFromFloat(@round(o[0])));
    const y = at.y - @as(c_int, @intFromFloat(@round(o[1])));
    if (x < 0 or y < 0 or x >= p.frame.size_pt[0] or y >= p.frame.size_pt[1]) return null;
    return .{ .label = label, .at = .{ .x = x, .y = y, .width = at.width, .height = at.height } };
}

/// The cmdline popup's preedit label, if any.
pub fn cmdlinePreeditLabel(app: *App) ?*anyopaque {
    const p = app.popups[@intFromEnum(Kind.cmdline)] orelse return null;
    return p.preedit_label;
}

/// The width of the output the main window is on, device px, for the
/// cmdline's width budget (callbacks.cmdlineCols), as Windows takes its
/// monitor's work area. Kept as it was while the window is unmapped.
pub fn noteMonitor(app: *App) void {
    const win = app.window orelse return;
    const surface = gtk.gtk_native_get_surface(win) orelse return;
    const display = gtk.gtk_widget_get_display(win) orelse return;
    const monitor = gtk.gdk_display_get_monitor_at_surface(display, surface) orelse return;
    var g: gtk.GdkRectangle = undefined;
    gtk.gdk_monitor_get_geometry(monitor, &g);
    app.mu.lockUncancelable(clock.io());
    defer app.mu.unlock(clock.io());
    app.monitor_w_px = @intCast(@max(0, g.width) * @as(c_int, @intFromFloat(app.scale)));
}

/// The panels go back into the main view: this popup's GL context could not
/// be made.
fn fallBack(app: *App) void {
    if (!app.panel_popups) return;
    applog.appLog("[panel_popup] GL unavailable; panels drawn in the main view\n", .{});
    for (app.popups) |slot| if (slot) |p| hide(p);
    app.mu.lockUncancelable(clock.io());
    app.panel_popups = false;
    app.mu.unlock(clock.io());
    moveCopyButtons(app, false);
    ui_widgets.placeCopyButtons(app);
    app.queueRenderAll();
}

/// Watches the popup surface's frame clock for committed frames.
fn onPopoverRealize(widget: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const p = popupFrom(data);
    const surface = gtk.gtk_native_get_surface(widget.?) orelse return;
    const clock_ = gtk.gdk_surface_get_frame_clock(surface) orelse return;
    p.clock = clock_;
    p.clock_handler = gtk.g_signal_connect(clock_, "after-paint", @ptrCast(&onAfterPaint), p);
}

fn onPopoverUnrealize(widget: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    _ = widget;
    const p = popupFrom(data);
    if (p.clock) |c| gtk.g_signal_handler_disconnect(c, p.clock_handler);
    p.clock = null;
    p.committed_pos = null;
    p.pending_pos = null;
}

extern "c" fn zonvie_wl_sync(display: *anyopaque, done: *const fn (?*anyopaque) callconv(.c) void, data: ?*anyopaque) c_int;
extern "c" fn gdk_wayland_display_get_type() usize;
extern "c" fn gdk_wayland_display_get_wl_display(display: *anyopaque) ?*anyopaque;
extern "c" fn g_type_check_instance_is_a(instance: *anyopaque, iface_type: usize) c_int;

/// After GDK's own after-paint, which commits the frame acknowledging the
/// last configure. On Wayland the new position is not yet what pointer
/// events are relative to: events the compositor sent before it handled
/// the commit still arrive, relative to the old one, and taking them at the
/// new one put a dragged panel a drag step too far. A wl_display.sync sent
/// now answers after every such event; its answer switches the position
/// (onSynced). Elsewhere the commit is the switch. A compositor that applies
/// the move later than the commit (Hyprland, at its next render) still
/// leaves one event in flight that no client can place: a dragged panel may
/// end one motion event's distance off, a pixel or two for a real pointer.
fn onAfterPaint(frame_clock: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    _ = frame_clock;
    const p = popupFrom(data);
    if (!p.shown or gtk.gtk_widget_get_mapped(p.popover) == 0) return;
    const surface = gtk.gtk_native_get_surface(p.popover) orelse return;
    const pos: [2]c_int = .{ gtk.gdk_popup_get_position_x(surface), gtk.gdk_popup_get_position_y(surface) };
    const latest = p.pending_pos orelse p.committed_pos;
    const moved = if (latest) |old| old[0] != pos[0] or old[1] != pos[1] else true;
    if (!moved) return;
    // Nothing was relative to a position before the first.
    if (p.committed_pos == null or !waitForSync(p, pos)) {
        p.committed_pos = pos;
        p.pending_pos = null;
    }
    // Once more where it now is, for the [overlay] line's position: the
    // frame just committed was drawn before the move took effect.
    if (applog.isEnabled()) gtk.gtk_gl_area_queue_render(p.area);
}

/// Defers `pos` to a sync's answer; false when the display is not Wayland
/// or no sync could be sent. One sync in flight per popup: a later position
/// waits for it and gets its own.
fn waitForSync(p: *Popup, pos: [2]c_int) bool {
    p.pending_pos = pos;
    if (p.sync_pos != null) return true;
    const display = gtk.gtk_widget_get_display(p.popover) orelse return false;
    if (g_type_check_instance_is_a(display, gdk_wayland_display_get_type()) == 0) return false;
    const wl = gdk_wayland_display_get_wl_display(display) orelse return false;
    p.sync_pos = pos;
    if (zonvie_wl_sync(wl, &onSynced, p) == 0) {
        p.sync_pos = null;
        return false;
    }
    return true;
}

fn onSynced(data: ?*anyopaque) callconv(.c) void {
    if (!alive) return;
    const p = popupFrom(data);
    const done = p.sync_pos orelse return;
    p.sync_pos = null;
    // Hidden meanwhile: its position starts over at the next show.
    if (!p.shown) return;
    p.committed_pos = done;
    const pending = p.pending_pos orelse return;
    if (pending[0] == done[0] and pending[1] == done[1]) {
        p.pending_pos = null;
        return;
    }
    // A later commit landed after this sync was sent: it needs its own.
    if (!waitForSync(p, pending)) {
        p.committed_pos = pending;
        p.pending_pos = null;
    }
}

fn onRealize(widget: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const p = popupFrom(data);
    gtk.gtk_gl_area_make_current(widget.?);
    if (gtk.gtk_gl_area_get_error(widget.?) != null or !gl_renderer.realize(&p.gl)) return fallBack(p.app);
}

fn onUnrealize(widget: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    gtk.gtk_gl_area_make_current(widget.?);
    gl_renderer.unrealize(&popupFrom(data).gl);
}

fn onRender(area: ?*anyopaque, context: ?*anyopaque, data: ?*anyopaque) callconv(.c) c_int {
    _ = area;
    _ = context;
    const p = popupFrom(data);
    const app = p.app;
    const scale: i32 = @max(1, @as(i32, @intFromFloat(app.scale)));
    const view = panelRect(app, p.kind, scale) orelse p.frame.inner;
    gl_renderer.renderPanel(app, &p.gl, p.kind, p.frame.inner, view);
    return 1;
}

/// `w_px`/`h_px` are device px.
fn onResize(area: ?*anyopaque, w_px: c_int, h_px: c_int, data: ?*anyopaque) callconv(.c) void {
    _ = area;
    const p = popupFrom(data);
    if (w_px <= 0 or h_px <= 0) return;
    p.gl.w_px = @intCast(w_px);
    p.gl.h_px = @intCast(h_px);
}
