//! The main window's chrome, by `[window] titlebar_style` and the tabline's
//! placement (core.config.Config.TitlebarLayout): a header bar holding the
//! title or the titlebar tabs, a self-drawn title band, or no caption at all
//! with the window buttons revealed over the top band; the sidebar with its
//! toggle, slide and width drag; the app menu (New Session, About, Quit) and,
//! for `[tabline] style = "menu"`, the Tabs menu. GTK main thread only.

const std = @import("std");
const core = @import("zonvie_core");
const rules = core.frontend_rules;
const Config = core.config.Config;
const App = @import("app.zig").App;
const gtk = @import("gtk_bindings.zig");
const ui_state = @import("ui_state.zig");
const tab_strip = @import("tab_strip.zig");
const about = @import("about.zig");
const input = @import("input.zig");

/// What sits where the desktop's titlebar would.
pub const Header = enum {
    /// A GtkHeaderBar: the desktop's look, holding the title (or the
    /// titlebar tabs), the sidebar toggle and the menus.
    header_bar,
    /// No caption: the editor reaches the window top; the window buttons
    /// show while the pointer is in the top band, a drag bar after it rests
    /// there.
    captionless,
    /// A band above the editor with the title in the editor's colours; a
    /// sidebar still reaches the window top.
    title_band,
};

/// The header's colours.
pub const Tint = enum { theme, ground, editor_bg };

pub const Plan = struct {
    header: Header,
    /// The header holds the tab strip.
    tabs_in_header: bool,
    tint: Tint,
};

/// The chrome `layout` yields, as the table on Config.TitlebarLayout says.
/// Titlebar tabs take the caption's place on the card's ground, or in the
/// editor's bg without a card.
pub fn plan(layout: Config.TitlebarLayout) Plan {
    if (layout.tabline == .titlebar) return .{
        .header = .header_bar,
        .tabs_in_header = true,
        .tint = if (layout.island()) .ground else .editor_bg,
    };
    if (layout.captionless()) return .{ .header = .captionless, .tabs_in_header = false, .tint = .editor_bg };
    if (layout.titleBand()) return .{ .header = .title_band, .tabs_in_header = false, .tint = .ground };
    return .{ .header = .header_bar, .tabs_in_header = false, .tint = .theme };
}

test "the chrome follows the titlebar layout table" {
    const P = Config.TablinePlacement;
    const S = Config.TitlebarStyle;
    const at = struct {
        fn f(s: S, t: P) Plan {
            return plan(.{ .style = s, .tabline = t });
        }
    }.f;
    try std.testing.expectEqual(Plan{ .header = .header_bar, .tabs_in_header = true, .tint = .ground }, at(.native, .titlebar));
    try std.testing.expectEqual(Plan{ .header = .header_bar, .tabs_in_header = true, .tint = .editor_bg }, at(.hidden, .titlebar));
    try std.testing.expectEqual(Plan{ .header = .header_bar, .tabs_in_header = true, .tint = .ground }, at(.unified, .titlebar));
    try std.testing.expectEqual(Plan{ .header = .header_bar, .tabs_in_header = false, .tint = .theme }, at(.native, .sidebar));
    try std.testing.expectEqual(Header.captionless, at(.hidden, .sidebar).header);
    try std.testing.expectEqual(Header.captionless, at(.hidden, .other).header);
    try std.testing.expectEqual(Header.title_band, at(.unified, .sidebar).header);
    try std.testing.expectEqual(Header.title_band, at(.unified, .other).header);
    try std.testing.expectEqual(Header.header_bar, at(.native, .other).header);
}

/// The top band of a captionless window, logical px: where the window
/// buttons reveal and the drag bar shows.
pub const band_pt = 32;
/// The sidebar's slide, as macOS's 0.4 s.
pub const slide_ms = 400;

pub const Chrome = struct {
    plan: Plan = .{ .header = .header_bar, .tabs_in_header = false, .tint = .theme },
    /// The header bar or the title band; null without one.
    header: ?*anyopaque = null,
    /// Holds the sidebar, sliding it in and out.
    revealer: ?*anyopaque = null,
    /// The sidebar's strip and width handle; its width request is the
    /// sidebar width.
    sidebar_box: ?*anyopaque = null,
    sidebar_w: c_int = 200,
    /// The width a handle drag started from, and the pointer's x then in the
    /// window's surface (which does not move as the handle does).
    drag_from_w: c_int = 0,
    drag_from_x: f64 = 0,
    sidebar_right: bool = false,
    /// Captionless: the revealed window buttons, and the drag bar.
    hover: Hover = .{},
    /// [tabline] style = "menu": the Tabs menu's tab section and its action.
    tab_section: ?*anyopaque = null,
    select_tab: ?*anyopaque = null,
    /// tabMenuKey of what the Tabs menu shows; null before its first fill.
    tab_menu_key: ?u64 = null,
};

fn layoutOf(app: *const App) Config.TitlebarLayout {
    const tabline: Config.TablinePlacement = if (!app.ext_tabline)
        .other
    else if (std.mem.eql(u8, app.tabline_cfg.style, "sidebar"))
        .sidebar
    else if (std.mem.eql(u8, app.tabline_cfg.style, "titlebar"))
        .titlebar
    else
        .other;
    return .{ .style = app.window_cfg.titlebar_style, .tabline = tabline };
}

/// The tabs are a menu, not a strip ([tabline] style = "menu").
pub fn menuStyle(app: *const App) bool {
    return app.ext_tabline and std.mem.eql(u8, app.tabline_cfg.style, "menu");
}

/// Builds the chrome around `content` (the editor, in its card or not) on
/// `app.window`, and returns the window's child. Builds the tab strip.
pub fn build(app: *App, content: *anyopaque) *anyopaque {
    const c = &app.widgets.chrome;
    const win = app.window.?;
    const layout = layoutOf(app);
    c.plan = plan(layout);
    const window_overlay = gtk.gtk_overlay_new().?;

    const strip: ?*anyopaque = switch (layout.tabline) {
        .titlebar => tab_strip.build(app, false, window_overlay),
        .sidebar => tab_strip.build(app, true, window_overlay),
        .other => null,
    };
    // On an editor card's ground, the strip and the sidebar take its colour.
    if (app.widgets.card != null) if (strip) |s| gtk.gtk_widget_add_css_class(s, "ground");
    installActions(app, win);
    // Ahead of the quit handler, which stops the close: the size is
    // remembered whether or not Neovim lets the window go.
    _ = gtk.g_signal_connect(win, "close-request", @ptrCast(&onCloseSaveSize), app);

    // The column: a title band over the editor.
    const column = gtk.gtk_box_new(gtk.GTK_ORIENTATION_VERTICAL, 0).?;
    gtk.gtk_widget_set_hexpand(column, 1);
    switch (c.plan.header) {
        .header_bar => if (c.plan.tabs_in_header) {
            // The tabs from the window's left edge, the menus and window
            // buttons after them: a header bar would centre them.
            const bar = gtk.gtk_box_new(gtk.GTK_ORIENTATION_HORIZONTAL, 0).?;
            gtk.gtk_widget_add_css_class(bar, "zonvie-header");
            gtk.gtk_widget_add_css_class(bar, "zonvie-tab-header");
            tintClass(bar, c.plan.tint);
            if (gtk.gtk_window_controls_new(gtk.GTK_PACK_START)) |wc| gtk.gtk_box_append(bar, wc);
            const s = strip.?;
            gtk.gtk_widget_set_hexpand(s, 1);
            gtk.gtk_box_append(bar, s);
            packMenus(app, bar, gtk.gtk_box_append);
            if (gtk.gtk_window_controls_new(gtk.GTK_PACK_END)) |wc| gtk.gtk_box_append(bar, wc);
            const handle = gtk.gtk_window_handle_new().?;
            gtk.gtk_window_handle_set_child(handle, bar);
            gtk.gtk_window_set_titlebar(win, handle);
            c.header = bar;
        } else {
            const hb = gtk.gtk_header_bar_new().?;
            gtk.gtk_widget_add_css_class(hb, "zonvie-header");
            tintClass(hb, c.plan.tint);
            if (layout.tabline == .sidebar) gtk.gtk_header_bar_pack_start(hb, sidebarToggle(app));
            packMenus(app, hb, gtk.gtk_header_bar_pack_end);
            gtk.gtk_window_set_titlebar(win, hb);
            c.header = hb;
        },
        .title_band => {
            setNoTitlebar(win);
            const start = gtk.gtk_box_new(gtk.GTK_ORIENTATION_HORIZONTAL, 0).?;
            if (layout.tabline == .sidebar) gtk.gtk_box_append(start, sidebarToggle(app));
            const end = gtk.gtk_box_new(gtk.GTK_ORIENTATION_HORIZONTAL, 0).?;
            packMenus(app, end, gtk.gtk_box_append);
            const band = titleBand(win, c.plan.tint, start, end);
            gtk.gtk_box_append(column, band.handle);
            c.header = band.band;
        },
        .captionless => {
            setNoTitlebar(win);
            buildHoverChrome(app, window_overlay, layout.tabline == .sidebar);
        },
    }
    gtk.gtk_box_append(column, content);

    var root: *anyopaque = column;
    if (layout.tabline == .sidebar) {
        root = gtk.gtk_box_new(gtk.GTK_ORIENTATION_HORIZONTAL, 0).?;
        const side = buildSidebar(app, strip.?);
        if (c.sidebar_right) {
            gtk.gtk_box_append(root, column);
            gtk.gtk_box_append(root, side);
        } else {
            gtk.gtk_box_append(root, side);
            gtk.gtk_box_append(root, column);
        }
    }
    // macOS's floor, 400 x 300; a sidebar adds its own width.
    gtk.gtk_widget_set_size_request(column, 400, 300);
    gtk.gtk_overlay_set_child(window_overlay, root);
    return window_overlay;
}

fn onCloseSaveSize(win: ?*anyopaque, data: ?*anyopaque) callconv(.c) c_int {
    _ = win;
    @import("window_size.zig").save(@ptrCast(@alignCast(data.?)));
    return 0;
}

fn tintClass(w: *anyopaque, tint: Tint) void {
    switch (tint) {
        .theme => {},
        .ground => gtk.gtk_widget_add_css_class(w, "ground"),
        .editor_bg => gtk.gtk_widget_add_css_class(w, "editor-bg"),
    }
}

/// No titlebar, the window still the desktop's to resize: a titlebar widget
/// that is never shown.
fn setNoTitlebar(win: *anyopaque) void {
    const none = gtk.gtk_box_new(gtk.GTK_ORIENTATION_HORIZONTAL, 0).?;
    gtk.gtk_widget_set_visible(none, 0);
    gtk.gtk_window_set_titlebar(win, none);
}

// =========================================================================
// Sidebar: toggle, slide, width drag
// =========================================================================

fn buildSidebar(app: *App, strip: *anyopaque) *anyopaque {
    const c = &app.widgets.chrome;
    c.sidebar_right = std.mem.eql(u8, app.tabline_cfg.sidebar_position, "right");
    c.sidebar_w = @intCast(std.math.clamp(app.tabline_cfg.sidebar_width, 100, 500));
    const box = gtk.gtk_box_new(gtk.GTK_ORIENTATION_HORIZONTAL, 0).?;
    gtk.gtk_widget_add_css_class(box, "zonvie-sidebar");
    if (app.widgets.card != null) gtk.gtk_widget_add_css_class(box, "ground");
    gtk.gtk_widget_set_hexpand(strip, 1);
    gtk.gtk_widget_set_vexpand(strip, 1);
    gtk.gtk_widget_set_size_request(box, c.sidebar_w, -1);
    // Set, so the tab names' hexpand does not widen it past that.
    gtk.gtk_widget_set_hexpand(box, 0);
    const handle = gtk.gtk_box_new(gtk.GTK_ORIENTATION_VERTICAL, 0).?;
    gtk.gtk_widget_add_css_class(handle, "zonvie-sidebar-handle");
    gtk.gtk_widget_set_size_request(handle, 5, -1);
    gtk.gtk_widget_set_cursor_from_name(handle, "col-resize");
    if (gtk.gtk_gesture_drag_new()) |drag| {
        _ = gtk.g_signal_connect(drag, "drag-begin", @ptrCast(&onHandleBegin), app);
        _ = gtk.g_signal_connect(drag, "drag-update", @ptrCast(&onHandleUpdate), app);
        gtk.gtk_widget_add_controller(handle, drag);
    }
    // Beside a title band the sidebar reaches the window top: its top is
    // the band's continuation, and drags the window as the band does.
    var column = strip;
    if (c.plan.header == .title_band) {
        column = gtk.gtk_box_new(gtk.GTK_ORIENTATION_VERTICAL, 0).?;
        gtk.gtk_widget_set_hexpand(column, 1);
        const top = gtk.gtk_window_handle_new().?;
        gtk.gtk_window_handle_set_child(top, gtk.gtk_box_new(gtk.GTK_ORIENTATION_HORIZONTAL, 0).?);
        gtk.gtk_widget_set_size_request(top, -1, band_pt);
        gtk.gtk_box_append(column, top);
        gtk.gtk_box_append(column, strip);
    }
    // The handle on the edge facing the editor.
    if (c.sidebar_right) {
        gtk.gtk_box_append(box, handle);
        gtk.gtk_box_append(box, column);
    } else {
        gtk.gtk_box_append(box, column);
        gtk.gtk_box_append(box, handle);
    }
    const rev = gtk.gtk_revealer_new().?;
    gtk.gtk_revealer_set_transition_type(rev, if (c.sidebar_right) gtk.GTK_REVEALER_TRANSITION_TYPE_SLIDE_LEFT else gtk.GTK_REVEALER_TRANSITION_TYPE_SLIDE_RIGHT);
    gtk.gtk_revealer_set_transition_duration(rev, slide_ms);
    gtk.gtk_revealer_set_child(rev, box);
    gtk.gtk_revealer_set_reveal_child(rev, 1);
    c.revealer = rev;
    c.sidebar_box = box;
    return rev;
}

fn sidebarToggle(app: *App) *anyopaque {
    const b = gtk.gtk_button_new_from_icon_name("sidebar-show-symbolic").?;
    gtk.gtk_widget_add_css_class(b, "zonvie-sidebar-toggle");
    gtk.gtk_widget_set_focusable(b, 0);
    gtk.gtk_widget_set_tooltip_text(b, "Toggle Sidebar");
    _ = gtk.g_signal_connect(b, "clicked", @ptrCast(&onToggle), app);
    return b;
}

/// Slides the sidebar out, or back in; the editor takes the width, the grid
/// following every frame of the slide.
pub fn toggleSidebar(app: *App) void {
    const rev = app.widgets.chrome.revealer orelse return;
    gtk.gtk_revealer_set_reveal_child(rev, @intFromBool(gtk.gtk_revealer_get_reveal_child(rev) == 0));
    if (app.gl_area) |a| _ = gtk.gtk_widget_grab_focus(a);
}

fn onToggle(btn: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    _ = btn;
    toggleSidebar(@ptrCast(@alignCast(data.?)));
}

/// The pointer's x in the window's surface, from the event being handled.
fn surfaceX(gesture: *anyopaque) ?f64 {
    const ev = gtk.gtk_event_controller_get_current_event(gesture) orelse return null;
    var x: f64 = 0;
    var y: f64 = 0;
    if (gtk.gdk_event_get_position(ev, &x, &y) == 0) return null;
    return x;
}

fn onHandleBegin(gesture: ?*anyopaque, x: f64, y: f64, data: ?*anyopaque) callconv(.c) void {
    _ = x;
    _ = y;
    const app: *App = @ptrCast(@alignCast(data.?));
    const c = &app.widgets.chrome;
    c.drag_from_w = c.sidebar_w;
    c.drag_from_x = surfaceX(gesture.?) orelse 0;
    _ = gtk.gtk_gesture_set_state(gesture.?, gtk.GTK_EVENT_SEQUENCE_CLAIMED);
}

/// The sidebar width for a handle drag from `from_x` to `now_x` (the
/// window's coordinates) that began at `from_w`: the pointer's whole travel,
/// toward the editor widening it. The gesture's own offsets are relative to
/// the handle, which moves with the width, and would count half of it.
pub fn dragSidebarWidth(from_w: c_int, from_x: f64, now_x: f64, right: bool, win_w: c_int) c_int {
    const dx = now_x - from_x;
    const delta: c_int = @intFromFloat(@round(if (right) -dx else dx));
    return @intCast(rules.clampSidebarWidth(from_w + delta, win_w));
}

test "the sidebar follows the pointer's whole travel, within its bounds" {
    try std.testing.expectEqual(@as(c_int, 260), dragSidebarWidth(200, 300, 360, false, 1000));
    try std.testing.expectEqual(@as(c_int, 260), dragSidebarWidth(200, 700, 640, true, 1000));
    try std.testing.expectEqual(@as(c_int, 120), dragSidebarWidth(200, 300, 100, false, 1000));
    try std.testing.expectEqual(@as(c_int, 500), dragSidebarWidth(200, 300, 900, false, 1000));
}

/// Session-only, as on macOS and Windows: within 120 and half the window.
fn onHandleUpdate(gesture: ?*anyopaque, dx: f64, dy: f64, data: ?*anyopaque) callconv(.c) void {
    _ = dx;
    _ = dy;
    const app: *App = @ptrCast(@alignCast(data.?));
    const c = &app.widgets.chrome;
    const box = c.sidebar_box orelse return;
    const win_w = gtk.gtk_widget_get_width(app.window orelse return);
    const now_x = surfaceX(gesture.?) orelse return;
    const w = dragSidebarWidth(c.drag_from_w, c.drag_from_x, now_x, c.sidebar_right, win_w);
    if (w == c.sidebar_w) return;
    c.sidebar_w = w;
    gtk.gtk_widget_set_size_request(box, w, -1);
}

// =========================================================================
// Captionless: window buttons over the top band, and the drag bar
// =========================================================================

/// One captionless window's top band: its buttons, revealed while the
/// pointer is in the band, and its drag bar, revealed after a rest there
/// (frontend_rules.DragBar). The main window and every external window
/// have one each.
pub const Hover = struct {
    controls: ?*anyopaque = null,
    drag_bar: ?*anyopaque = null,
    state: rules.DragBar = .{},
    timer: c_uint = 0,
    shown: bool = false,
    /// The window's editor pointer: a held press (a selection drag) never
    /// reveals the bar.
    pointer: ?*const input.Pointer = null,
};

/// The band's drag bar and buttons over `window_overlay`, `controls` holding
/// whatever the window adds before its window buttons. Pre: `h` outlives
/// the window.
fn buildHover(h: *Hover, window_overlay: *anyopaque, controls: *anyopaque, pointer: *const input.Pointer) void {
    h.pointer = pointer;
    // The drag bar: the window handle across the band, shown after a rest.
    const bar = gtk.gtk_window_handle_new().?;
    const fill = gtk.gtk_box_new(gtk.GTK_ORIENTATION_HORIZONTAL, 0).?;
    gtk.gtk_widget_add_css_class(fill, "zonvie-drag-bar");
    gtk.gtk_window_handle_set_child(bar, fill);
    gtk.gtk_widget_set_valign(bar, gtk.GTK_ALIGN_START);
    gtk.gtk_widget_set_size_request(bar, -1, band_pt);
    gtk.gtk_widget_set_visible(bar, 0);
    gtk.gtk_overlay_add_overlay(window_overlay, bar);
    h.drag_bar = bar;

    gtk.gtk_widget_add_css_class(controls, "zonvie-hover-controls");
    gtk.gtk_widget_set_halign(controls, gtk.GTK_ALIGN_END);
    gtk.gtk_widget_set_valign(controls, gtk.GTK_ALIGN_START);
    if (gtk.gtk_window_controls_new(gtk.GTK_PACK_START)) |wc| gtk.gtk_box_append(controls, wc);
    if (gtk.gtk_window_controls_new(gtk.GTK_PACK_END)) |wc| gtk.gtk_box_append(controls, wc);
    gtk.gtk_overlay_add_overlay(window_overlay, controls);
    h.controls = controls;
    showControls(h, false);

    // Watches the whole window without taking anything from the editor.
    if (gtk.gtk_event_controller_motion_new()) |m| {
        gtk.gtk_event_controller_set_propagation_phase(m, gtk.GTK_PHASE_CAPTURE);
        _ = gtk.g_signal_connect(m, "motion", @ptrCast(&onWindowMotion), h);
        _ = gtk.g_signal_connect(m, "leave", @ptrCast(&onWindowLeave), h);
        gtk.gtk_widget_add_controller(window_overlay, m);
    }
}

fn buildHoverChrome(app: *App, window_overlay: *anyopaque, has_sidebar: bool) void {
    const controls = gtk.gtk_box_new(gtk.GTK_ORIENTATION_HORIZONTAL, 0).?;
    if (has_sidebar) gtk.gtk_box_append(controls, sidebarToggle(app));
    packMenus(app, controls, gtk.gtk_box_append);
    buildHover(&app.widgets.chrome.hover, window_overlay, controls, &app.pointer);
}

/// Faded out, the buttons take no clicks either.
fn showControls(h: *Hover, on: bool) void {
    const w = h.controls orelse return;
    h.shown = on;
    if (on) gtk.gtk_widget_add_css_class(w, "revealed") else gtk.gtk_widget_remove_css_class(w, "revealed");
    gtk.gtk_widget_set_can_target(w, @intFromBool(on));
}

fn nowMs() u64 {
    return @intCast(@divTrunc(core.clock.nowNs(), std.time.ns_per_ms));
}

fn barAllowed(h: *const Hover) bool {
    const p = h.pointer orelse return true;
    return p.claim.held_mask == 0;
}

fn onWindowMotion(ctrl: ?*anyopaque, x: f64, y: f64, data: ?*anyopaque) callconv(.c) void {
    const h: *Hover = @ptrCast(@alignCast(data.?));
    const widget = gtk.gtk_event_controller_get_widget(ctrl.?).?;
    const in_band = rules.inCaptionBand(band_pt, gtk.gtk_widget_get_width(widget), @intFromFloat(x), @intFromFloat(y));
    var on_button = false;
    if (h.controls) |c| {
        var r: gtk.GrapheneRect = .{};
        if (gtk.gtk_widget_compute_bounds(c, widget, &r) != 0)
            on_button = x >= r.x and x < r.x + r.w and y >= r.y and y < r.y + r.h;
    }
    const want = in_band or on_button;
    if (want != h.shown) showControls(h, want);
    stepDragBar(h, h.state.onPointer(in_band, on_button, barAllowed(h), nowMs()));
}

fn onWindowLeave(ctrl: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    _ = ctrl;
    const h: *Hover = @ptrCast(@alignCast(data.?));
    showControls(h, false);
    stepDragBar(h, h.state.onPointer(false, false, false, nowMs()));
}

fn onDragBarTimer(data: ?*anyopaque) callconv(.c) c_int {
    const h: *Hover = @ptrCast(@alignCast(data.?));
    h.timer = 0;
    // The pointer has not left the band, or a leave would have killed us.
    stepDragBar(h, h.state.onTimer(true, barAllowed(h), nowMs()));
    return 0;
}

fn stepDragBar(h: *Hover, step: rules.DragBar.Step) void {
    switch (step.timer) {
        .keep => {},
        .set => {
            if (h.timer != 0) _ = gtk.g_source_remove(h.timer);
            h.timer = gtk.g_timeout_add(rules.DragBar.reveal_ms, &onDragBarTimer, h);
        },
        .kill => if (h.timer != 0) {
            _ = gtk.g_source_remove(h.timer);
            h.timer = 0;
        },
    }
    const changed = h.state.revealed != step.next.revealed;
    h.state = step.next;
    if (changed) if (h.drag_bar) |b| gtk.gtk_widget_set_visible(b, @intFromBool(step.next.revealed));
}

/// Stops `h`'s reveal timer: its window is going. Pre: GTK main thread.
pub fn releaseHover(h: *Hover) void {
    if (h.timer != 0) _ = gtk.g_source_remove(h.timer);
    h.timer = 0;
}

/// A self-drawn title band: the window buttons at both ends, `start` and
/// `end` inside them, the window's title in the middle; all inside a window
/// handle, which drags, maximizes on double-click and opens the window menu.
fn titleBand(win: *anyopaque, tint: Tint, start: ?*anyopaque, end: ?*anyopaque) struct { handle: *anyopaque, band: *anyopaque } {
    const band = gtk.gtk_center_box_new().?;
    gtk.gtk_widget_add_css_class(band, "zonvie-header");
    gtk.gtk_widget_add_css_class(band, "zonvie-band");
    tintClass(band, tint);
    gtk.gtk_widget_set_size_request(band, -1, band_pt);
    const start_box = gtk.gtk_box_new(gtk.GTK_ORIENTATION_HORIZONTAL, 0).?;
    if (gtk.gtk_window_controls_new(gtk.GTK_PACK_START)) |wc| gtk.gtk_box_append(start_box, wc);
    if (start) |w| gtk.gtk_box_append(start_box, w);
    gtk.gtk_center_box_set_start_widget(band, start_box);
    const title = gtk.gtk_label_new(null).?;
    gtk.gtk_widget_add_css_class(title, "zonvie-title");
    gtk.gtk_label_set_ellipsize(title, gtk.PANGO_ELLIPSIZE_END);
    _ = gtk.g_object_bind_property(win, "title", title, "label", gtk.G_BINDING_SYNC_CREATE);
    gtk.gtk_center_box_set_center_widget(band, title);
    const end_box = gtk.gtk_box_new(gtk.GTK_ORIENTATION_HORIZONTAL, 0).?;
    if (end) |w| gtk.gtk_box_append(end_box, w);
    if (gtk.gtk_window_controls_new(gtk.GTK_PACK_END)) |wc| gtk.gtk_box_append(end_box, wc);
    gtk.gtk_center_box_set_end_widget(band, end_box);
    const handle = gtk.gtk_window_handle_new().?;
    gtk.gtk_window_handle_set_child(handle, band);
    return .{ .handle = handle, .band = band };
}

// =========================================================================
// External windows
// =========================================================================

/// An external window's chrome by `[window] titlebar_style`, as macOS and
/// Windows give theirs (TitlebarLayout with no tabline): the desktop's
/// titlebar, no caption with the buttons over the band, or a title band.
/// Returns the window's child: `content`, or a column with the band over it.
/// Pre: `content` is an overlay (the hover chrome goes over it); `h` lives
/// as long as the window.
pub fn decorateExternal(app: *App, win: *anyopaque, content: *anyopaque, pointer: *const input.Pointer, h: *Hover) *anyopaque {
    const p = plan(.{ .style = app.window_cfg.titlebar_style, .tabline = .other });
    switch (p.header) {
        .header_bar => return content,
        .captionless => {
            setNoTitlebar(win);
            buildHover(h, content, gtk.gtk_box_new(gtk.GTK_ORIENTATION_HORIZONTAL, 0).?, pointer);
            return content;
        },
        .title_band => {
            setNoTitlebar(win);
            const column = gtk.gtk_box_new(gtk.GTK_ORIENTATION_VERTICAL, 0).?;
            gtk.gtk_box_append(column, titleBand(win, .ground, null, null).handle);
            gtk.gtk_widget_set_vexpand(content, 1);
            gtk.gtk_box_append(column, content);
            return column;
        },
    }
}

// =========================================================================
// Menus
// =========================================================================

const PackFn = *const fn (*anyopaque, *anyopaque) callconv(.c) void;

/// The app menu, and the Tabs menu for [tabline] style = "menu".
fn packMenus(app: *App, into: *anyopaque, pack: PackFn) void {
    const c = &app.widgets.chrome;
    const main_menu = gtk.g_menu_new().?;
    gtk.g_menu_append(main_menu, "New Session", "zonvie.new-session");
    gtk.g_menu_append(main_menu, "About zonvie", "zonvie.about");
    gtk.g_menu_append(main_menu, "Quit", "zonvie.quit");
    const mb = gtk.gtk_menu_button_new().?;
    gtk.gtk_menu_button_set_icon_name(mb, "open-menu-symbolic");
    gtk.gtk_menu_button_set_menu_model(mb, main_menu);
    gtk.gtk_widget_set_focusable(mb, 0);
    gtk.g_object_unref(main_menu);
    pack(into, mb);
    if (!menuStyle(app)) return;
    const tabs_menu = gtk.g_menu_new().?;
    const actions = gtk.g_menu_new().?;
    gtk.g_menu_append(actions, "New Tab", "zonvie.new-tab");
    gtk.g_menu_append(actions, "Close Tab", "zonvie.close-tab");
    gtk.g_menu_append_section(tabs_menu, null, actions);
    gtk.g_object_unref(actions);
    const section = gtk.g_menu_new().?;
    gtk.g_menu_append_section(tabs_menu, null, section);
    c.tab_section = section;
    const tb = gtk.gtk_menu_button_new().?;
    gtk.gtk_menu_button_set_label(tb, "Tabs");
    gtk.gtk_menu_button_set_menu_model(tb, tabs_menu);
    gtk.gtk_widget_set_focusable(tb, 0);
    gtk.g_object_unref(tabs_menu);
    pack(into, tb);
}

fn installActions(app: *App, win: *anyopaque) void {
    const group = gtk.g_simple_action_group_new().?;
    const plain = [_]struct { name: [*:0]const u8, f: *const anyopaque }{
        .{ .name = "new-session", .f = @ptrCast(&onNewSession) },
        .{ .name = "about", .f = @ptrCast(&onAbout) },
        .{ .name = "quit", .f = @ptrCast(&onQuit) },
        .{ .name = "new-tab", .f = @ptrCast(&onMenuNewTab) },
        .{ .name = "close-tab", .f = @ptrCast(&onMenuCloseTab) },
    };
    for (plain) |p| {
        const a = gtk.g_simple_action_new(p.name, null).?;
        _ = gtk.g_signal_connect(a, "activate", p.f, app);
        gtk.g_action_map_add_action(group, a);
        gtk.g_object_unref(a);
    }
    // A radio: the state is the current tab's 1-based number.
    const sel = gtk.g_simple_action_new_stateful("select-tab", gtk.g_variant_type_new("i"), gtk.g_variant_new_int32(0)).?;
    _ = gtk.g_signal_connect(sel, "activate", @ptrCast(&onSelectTab), app);
    gtk.g_action_map_add_action(group, sel);
    app.widgets.chrome.select_tab = sel;
    gtk.gtk_widget_insert_action_group(win, "zonvie", group);
    gtk.g_object_unref(group);
}

/// The tabs the Tabs menu lists: none while Neovim hides its tabline.
pub fn tabMenuTabs(ui: *const ui_state.UiState) []const ui_state.Tab {
    return if (ui.tabline_visible) ui.tabs[0..ui.tab_count] else &.{};
}

/// Identifies what the Tabs menu shows (its tabs' handles and names, and
/// the current tab), so it is rebuilt only when that changes: a UI refresh
/// for a message or toast must not clear a menu that may be open.
pub fn tabMenuKey(ui: *const ui_state.UiState) u64 {
    var h = std.hash.Wyhash.init(0);
    const tabs = tabMenuTabs(ui);
    h.update(std.mem.asBytes(&tabs.len));
    for (tabs) |*t| {
        h.update(std.mem.asBytes(&t.handle));
        h.update(std.mem.asBytes(&t.name.text().len));
        h.update(t.name.text());
    }
    const cur: i64 = if (tabs.len != 0) ui.curtab else 0;
    h.update(std.mem.asBytes(&cur));
    return h.final();
}

test "the Tabs menu changes with its tabs, not with other UI state" {
    // Large (every tab's label): on the heap.
    const ui = try std.testing.allocator.create(ui_state.UiState);
    defer std.testing.allocator.destroy(ui);
    ui.* = .{};
    ui.tabline_visible = true;
    ui.tab_count = 2;
    ui.tabs[0].handle = 1;
    ui.tabs[0].name.append("a.txt");
    ui.tabs[1].handle = 2;
    ui.curtab = 1;
    const k = tabMenuKey(ui);
    ui.toast_count = 1;
    try std.testing.expectEqual(k, tabMenuKey(ui));
    ui.curtab = 2;
    try std.testing.expect(tabMenuKey(ui) != k);
    ui.curtab = 1;
    ui.tabs[1].name.append("b");
    try std.testing.expect(tabMenuKey(ui) != k);
    // Hidden: no tab items, whatever the list held.
    ui.tabline_visible = false;
    try std.testing.expectEqual(@as(usize, 0), tabMenuTabs(ui).len);
    const hidden = tabMenuKey(ui);
    ui.tab_count = 1;
    try std.testing.expectEqual(hidden, tabMenuKey(ui));
}

/// The Tabs menu's tab items, one per tab, the current one checked.
pub fn applyTabMenu(app: *App, ui: *const ui_state.UiState) void {
    const c = &app.widgets.chrome;
    const section = c.tab_section orelse return;
    const key = tabMenuKey(ui);
    if (c.tab_menu_key == key) return;
    c.tab_menu_key = key;
    gtk.g_menu_remove_all(section);
    var cur: i32 = 0;
    for (tabMenuTabs(ui), 0..) |*t, i| {
        var buf: [130]u8 = undefined;
        const name = if (t.name.len == 0) "[No Name]" else t.name.text();
        const z = std.fmt.bufPrintZ(&buf, "{s}", .{name}) catch continue;
        const item = gtk.g_menu_item_new(z.ptr, null) orelse continue;
        gtk.g_menu_item_set_action_and_target_value(item, "zonvie.select-tab", gtk.g_variant_new_int32(@intCast(i + 1)));
        gtk.g_menu_append_item(section, item);
        gtk.g_object_unref(item);
        if (t.handle == ui.curtab) cur = @intCast(i + 1);
    }
    if (c.select_tab) |a| gtk.g_simple_action_set_state(a, gtk.g_variant_new_int32(cur));
}

/// A frontend shortcut (keymap.appShortcut): what its menu item does.
pub fn runShortcut(app: *App, sc: @import("keymap.zig").AppShortcut) void {
    switch (sc) {
        .new_session => input.openNewSession(),
        .quit => onQuit(null, null, app),
        .new_tab => command(app, "tabnew"),
        .close_tab => command(app, "tabclose"),
        .select_tab => |n| {
            var buf: [32]u8 = undefined;
            command(app, std.fmt.bufPrint(&buf, "{d}tabnext", .{n}) catch return);
        },
    }
}

fn command(app: *App, cmd: []const u8) void {
    const cp = app.corep orelse return;
    core.zonvie_core_send_command(cp, cmd.ptr, cmd.len);
}

fn onNewSession(action: ?*anyopaque, param: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    _ = action;
    _ = param;
    _ = data;
    input.openNewSession();
}

fn onAbout(action: ?*anyopaque, param: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    _ = action;
    _ = param;
    about.show(@ptrCast(@alignCast(data.?)));
}

/// A real close, Neovim deciding as for the close button: never the hide
/// that [server] close_to_tray makes of a close, as the tray's Quit.
fn onQuit(action: ?*anyopaque, param: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    _ = action;
    _ = param;
    const app: *App = @ptrCast(@alignCast(data.?));
    app.tray.quit_requested = true;
    if (app.window) |w| gtk.gtk_window_close(w);
}

fn onMenuNewTab(action: ?*anyopaque, param: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    _ = action;
    _ = param;
    command(@ptrCast(@alignCast(data.?)), "tabnew");
}

fn onMenuCloseTab(action: ?*anyopaque, param: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    _ = action;
    _ = param;
    command(@ptrCast(@alignCast(data.?)), "tabclose");
}

fn onSelectTab(action: ?*anyopaque, param: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    _ = action;
    const n = gtk.g_variant_get_int32(param orelse return);
    var buf: [32]u8 = undefined;
    command(@ptrCast(@alignCast(data.?)), std.fmt.bufPrint(&buf, "{d}tabnext", .{n}) catch return);
}
