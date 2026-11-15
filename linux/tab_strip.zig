//! The ext tabline strip: titlebar tabs along the top, or rows down a
//! sidebar. Each tab shows its agent indicator in a fixed cell, its name
//! (the basename) or its 'guitablabel' lines in the chunks' styles, and a
//! close button. A drag reorders, with a drop line, a floating tab and a
//! ghost at the origin; dragged out of the strip it tears the tab off into
//! an external window. GTK main thread only.

const std = @import("std");
const core = @import("zonvie_core");
const rules = core.frontend_rules;
const App = @import("app.zig").App;
const gtk = @import("gtk_bindings.zig");
const ui_state = @import("ui_state.zig");
const applog = @import("app_log.zig");
const x11_place = @import("x11_place.zig");

pub const Strip = struct {
    /// The strip's outer box: the scroller holding the tabs, then "+".
    root: ?*anyopaque = null,
    /// The scrolled viewport over `tabs`; the strip's on-screen extent.
    scroller: ?*anyopaque = null,
    /// One box per tab.
    tabs: ?*anyopaque = null,
    /// Over `tabs`: the drop line and the floating tab of a drag.
    drag_overlay: ?*anyopaque = null,
    drop_line: ?*anyopaque = null,
    floating: ?*anyopaque = null,
    /// The tear-off preview, an overlay of the window's content
    /// (`window_overlay`): Wayland gives a client no global pointer
    /// position, so it follows the pointer only over this window.
    preview: ?*anyopaque = null,
    window_overlay: ?*anyopaque = null,
    /// [tabline] style = "sidebar": the strip runs down one side.
    sidebar: bool = false,
    /// Sidebar rows show their 'guitablabel' lines ([tabline] cards);
    /// titlebar tabs always do.
    cards: bool = true,
    /// Advances the working agents' spinners while any runs.
    spinner_timer: c_uint = 0,
    spinner_frame: u32 = 0,
    /// The tabline the strip was last built from.
    tab_count: usize = 0,
    tab_handles: [ui_state.tab_cap]i64 = @splat(0),
    curtab: i64 = 0,
    /// The width sizeTabs last gave each titlebar tab, logical px.
    tab_w: c_int = 0,
    drag: Drag = .{},
};

/// A press on the strip and what it has become.
pub const Drag = struct {
    /// The tab pressed, by index; null when the press missed every tab.
    from: ?u32 = null,
    /// The press, in `tabs` coordinates.
    start: [2]f64 = .{ 0, 0 },
    mode: DragMode = .pending,
};

pub const DragMode = enum { pending, reorder, tear_off };

/// Logical px a press must travel before it is a drag, not a click.
pub const drag_threshold = 8;
/// How far past the strip a dragged tab tears off, logical px (macOS's 50pt).
pub const tear_off_px = 50;

/// What a drag at `pos` (the strip's coordinates, `size` its extent) is,
/// `moved` from the press. A tear-off opens the tab's window as an external
/// float (frontend_rules.externalizeTabCommand), which any Neovim with
/// ext_multigrid gives, as on Windows: no ext_windows needed.
pub fn dragMode(pos: [2]f64, size: [2]f64, moved: [2]f64) DragMode {
    const t: f64 = tear_off_px;
    const outside = pos[0] < -t or pos[1] < -t or pos[0] > size[0] + t or pos[1] > size[1] + t;
    if (outside) return .tear_off;
    if (@max(@abs(moved[0]), @abs(moved[1])) < drag_threshold) return .pending;
    return .reorder;
}

test "a drag reorders past the threshold and tears off past the strip" {
    const size = [2]f64{ 400, 30 };
    try std.testing.expectEqual(DragMode.pending, dragMode(.{ 10, 10 }, size, .{ 4, 3 }));
    try std.testing.expectEqual(DragMode.reorder, dragMode(.{ 30, 10 }, size, .{ 20, 0 }));
    try std.testing.expectEqual(DragMode.reorder, dragMode(.{ 30, 79 }, size, .{ 0, 69 }));
    try std.testing.expectEqual(DragMode.tear_off, dragMode(.{ 30, 81 }, size, .{ 0, 71 }));
    try std.testing.expectEqual(DragMode.tear_off, dragMode(.{ -51, 10 }, size, .{ -60, 0 }));
}

/// The insertion index for a drop at `pos` along the strip: the first tab
/// whose centre is past it, else past the last (frontend_rules.tabDropIndex
/// for tabs of any length).
pub fn dropIndexAt(pos: f64, centres: []const f64) u32 {
    for (centres, 0..) |c, i| if (pos < c) return @intCast(i);
    return @intCast(centres.len);
}

test "the drop index is the first centre past the pointer" {
    const c = [_]f64{ 50, 150, 300 };
    try std.testing.expectEqual(@as(u32, 0), dropIndexAt(49, &c));
    try std.testing.expectEqual(@as(u32, 1), dropIndexAt(50, &c));
    try std.testing.expectEqual(@as(u32, 3), dropIndexAt(301, &c));
    try std.testing.expectEqual(@as(u32, 0), dropIndexAt(0, &.{}));
}

/// Where the drop line sits for insertion index `idx`: the start of tab
/// `idx`, or the end of the last tab.
pub fn dropLinePos(idx: u32, starts: []const f64, ends: []const f64) f64 {
    std.debug.assert(starts.len == ends.len);
    if (starts.len == 0) return 0;
    if (idx < starts.len) return starts[idx];
    return ends[ends.len - 1];
}

test "the drop line sits at the insertion boundary" {
    const s = [_]f64{ 0, 100, 200 };
    const e = [_]f64{ 100, 200, 260 };
    try std.testing.expectEqual(@as(f64, 100), dropLinePos(1, &s, &e));
    try std.testing.expectEqual(@as(f64, 260), dropLinePos(3, &s, &e));
}

/// Builds the strip (hidden until a tabline shows) for a titlebar or a
/// sidebar. `window_overlay` takes the tear-off preview.
pub fn build(app: *App, sidebar: bool, window_overlay: *anyopaque) *anyopaque {
    const s = &app.widgets.strip;
    s.sidebar = sidebar;
    s.cards = app.tabline_cfg.cards;
    s.window_overlay = window_overlay;
    const along: c_int = if (sidebar) gtk.GTK_ORIENTATION_VERTICAL else gtk.GTK_ORIENTATION_HORIZONTAL;
    const root = gtk.gtk_box_new(along, 0).?;
    gtk.gtk_widget_add_css_class(root, "zonvie-tabbar");
    if (sidebar) gtk.gtk_widget_add_css_class(root, "sidebar");
    gtk.gtk_widget_set_visible(root, 0);

    // Titlebar tabs share the width equally (sizeTabs); sidebar rows are as
    // tall as their labels. More than fit scroll.
    const tabs = gtk.gtk_box_new(along, 0).?;
    gtk.gtk_box_set_homogeneous(tabs, @intFromBool(!sidebar));
    const ov = gtk.gtk_overlay_new().?;
    gtk.gtk_overlay_set_child(ov, tabs);
    const line = gtk.gtk_box_new(gtk.GTK_ORIENTATION_HORIZONTAL, 0).?;
    gtk.gtk_widget_add_css_class(line, "zonvie-drop-line");
    gtk.gtk_widget_set_can_target(line, 0);
    gtk.gtk_widget_set_halign(line, gtk.GTK_ALIGN_START);
    gtk.gtk_widget_set_valign(line, gtk.GTK_ALIGN_START);
    if (sidebar) gtk.gtk_widget_set_size_request(line, -1, 2) else gtk.gtk_widget_set_size_request(line, 2, -1);
    if (sidebar) gtk.gtk_widget_set_halign(line, gtk.GTK_ALIGN_FILL) else gtk.gtk_widget_set_valign(line, gtk.GTK_ALIGN_FILL);
    gtk.gtk_widget_set_visible(line, 0);
    gtk.gtk_overlay_add_overlay(ov, line);
    const floating = gtk.gtk_label_new(null).?;
    gtk.gtk_widget_add_css_class(floating, "zonvie-tab-floating");
    gtk.gtk_widget_set_can_target(floating, 0);
    gtk.gtk_widget_set_halign(floating, gtk.GTK_ALIGN_START);
    gtk.gtk_widget_set_valign(floating, gtk.GTK_ALIGN_START);
    gtk.gtk_label_set_ellipsize(floating, gtk.PANGO_ELLIPSIZE_END);
    gtk.gtk_widget_set_visible(floating, 0);
    gtk.gtk_overlay_add_overlay(ov, floating);

    const scroller = gtk.gtk_scrolled_window_new().?;
    gtk.gtk_scrolled_window_set_policy(scroller, if (sidebar) gtk.GTK_POLICY_NEVER else gtk.GTK_POLICY_EXTERNAL, if (sidebar) gtk.GTK_POLICY_AUTOMATIC else gtk.GTK_POLICY_NEVER);
    // At its tabs' natural size while they fit, scrolling only past that.
    gtk.gtk_scrolled_window_set_propagate_natural_height(scroller, 1);
    gtk.gtk_scrolled_window_set_propagate_natural_width(scroller, 1);
    gtk.gtk_scrolled_window_set_child(scroller, ov);
    if (sidebar) gtk.gtk_widget_set_vexpand(scroller, 0) else gtk.gtk_widget_set_hexpand(scroller, 0);
    gtk.gtk_box_append(root, scroller);

    const plus = gtk.gtk_button_new_with_label(if (sidebar) "+  New Tab" else "+").?;
    gtk.gtk_widget_add_css_class(plus, "zonvie-new-tab");
    gtk.gtk_widget_set_focusable(plus, 0);
    if (sidebar) if (gtk.gtk_button_get_child(plus)) |l| gtk.gtk_label_set_xalign(l, 0);
    _ = gtk.g_signal_connect(plus, "clicked", @ptrCast(&onNewTab), app);
    gtk.gtk_box_append(root, plus);

    if (gtk.gtk_gesture_drag_new()) |drag| {
        _ = gtk.g_signal_connect(drag, "drag-begin", @ptrCast(&onDragBegin), app);
        _ = gtk.g_signal_connect(drag, "drag-update", @ptrCast(&onDragUpdate), app);
        _ = gtk.g_signal_connect(drag, "drag-end", @ptrCast(&onDragEnd), app);
        gtk.gtk_widget_add_controller(tabs, drag);
    }

    const preview = gtk.gtk_label_new(null).?;
    gtk.gtk_widget_add_css_class(preview, "zonvie-tab-floating");
    gtk.gtk_widget_add_css_class(preview, "zonvie-tear-preview");
    gtk.gtk_widget_set_can_target(preview, 0);
    gtk.gtk_widget_set_halign(preview, gtk.GTK_ALIGN_START);
    gtk.gtk_widget_set_valign(preview, gtk.GTK_ALIGN_START);
    gtk.gtk_widget_set_size_request(preview, 150, 30);
    gtk.gtk_label_set_ellipsize(preview, gtk.PANGO_ELLIPSIZE_END);
    gtk.gtk_widget_set_visible(preview, 0);
    gtk.gtk_overlay_add_overlay(window_overlay, preview);

    s.* = .{
        .root = root,
        .scroller = scroller,
        .tabs = tabs,
        .drag_overlay = ov,
        .drop_line = line,
        .floating = floating,
        .preview = preview,
        .window_overlay = window_overlay,
        .sidebar = sidebar,
        .cards = s.cards,
    };
    return root;
}

/// Rebuilds the tabs when the list or the current tab changed, else updates
/// labels and indicators in place.
pub fn apply(app: *App, ui: *const ui_state.UiState) void {
    const s = &app.widgets.strip;
    const root = s.root orelse return;
    const tabs = s.tabs orelse return;
    gtk.gtk_widget_set_visible(root, @intFromBool(ui.tabline_visible));
    var same = s.tab_count == ui.tab_count and s.curtab == ui.curtab;
    if (same) {
        for (ui.tabs[0..ui.tab_count], s.tab_handles[0..ui.tab_count]) |t, h| {
            if (t.handle != h) same = false;
        }
    }
    if (!same) {
        // A drag addresses tabs by index: a new list ends it.
        endDrag(s);
        while (gtk.gtk_widget_get_first_child(tabs)) |c| gtk.gtk_box_remove(tabs, c);
        s.tab_count = ui.tab_count;
        s.curtab = ui.curtab;
        for (ui.tabs[0..ui.tab_count], 0..) |t, i| {
            s.tab_handles[i] = t.handle;
            gtk.gtk_box_append(tabs, newTab(app, t.handle == ui.curtab, i) orelse continue);
        }
        s.tab_w = 0;
        sizeTabs(app);
    }
    var child = gtk.gtk_widget_get_first_child(tabs);
    for (ui.tabs[0..ui.tab_count]) |*t| {
        const tab = child orelse break;
        child = gtk.gtk_widget_get_next_sibling(tab);
        const ind = gtk.gtk_widget_get_first_child(tab) orelse continue;
        const name = gtk.gtk_widget_get_next_sibling(ind) orelse continue;
        setLabel(name, t, !s.sidebar or s.cards);
    }
    applyIndicators(app, ui);
}

/// Children: the indicator, the name, the close button.
fn newTab(app: *App, current: bool, index: usize) ?*anyopaque {
    const s = &app.widgets.strip;
    const tab = gtk.gtk_box_new(gtk.GTK_ORIENTATION_HORIZONTAL, 0) orelse return null;
    gtk.gtk_widget_add_css_class(tab, "zonvie-tab");
    if (current) gtk.gtk_widget_add_css_class(tab, "current");
    const ind = gtk.gtk_label_new(null) orelse return null;
    gtk.gtk_widget_add_css_class(ind, "zonvie-agent");
    // A fixed cell: the spinner's glyphs differ in width, and the name
    // must not shift between its frames.
    gtk.gtk_label_set_width_chars(ind, 2);
    gtk.gtk_label_set_xalign(ind, 0.5);
    gtk.gtk_widget_set_visible(ind, 0);
    gtk.gtk_box_append(tab, ind);
    const name = gtk.gtk_label_new(null) orelse return null;
    gtk.gtk_widget_add_css_class(name, "zonvie-tab-name");
    gtk.gtk_label_set_xalign(name, if (s.sidebar) 0 else 0.5);
    gtk.gtk_label_set_ellipsize(name, gtk.PANGO_ELLIPSIZE_END);
    // A long name must not widen the tab past its share (sizeTabs).
    gtk.gtk_label_set_max_width_chars(name, 1);
    gtk.gtk_widget_set_hexpand(name, 1);
    gtk.gtk_box_append(tab, name);
    const close = gtk.gtk_button_new_with_label("\u{00d7}") orelse return null;
    gtk.gtk_widget_add_css_class(close, "zonvie-tab-close");
    gtk.gtk_widget_set_focusable(close, 0);
    gtk.gtk_widget_set_valign(close, gtk.GTK_ALIGN_START);
    // Signal data is the 1-based tab number: the strip is rebuilt whenever
    // the list changes, so it never outlives its tab.
    _ = gtk.g_signal_connect(close, "clicked", @ptrCast(&onTabClose), @ptrFromInt(index + 1));
    gtk.gtk_box_append(tab, close);
    if (gtk.gtk_gesture_click_new()) |click| {
        gtk.gtk_gesture_single_set_button(click, 1);
        // A sidebar row selects on press, a titlebar tab on release, as on
        // macOS and Windows.
        _ = gtk.g_signal_connect(click, if (s.sidebar) "pressed" else "released", @ptrCast(&onTabClick), @ptrFromInt(index + 1));
        gtk.gtk_widget_add_controller(tab, click);
    }
    return tab;
}

/// The name label's text: the 'guitablabel' lines when the label came with
/// chunks and `lines` allows them, else the basename.
fn setLabel(l: *anyopaque, t: *const ui_state.Tab, lines: bool) void {
    var text: [ui_state.label_text_cap + 1]u8 = undefined;
    if (!lines or t.label.line_count == 0) {
        const name = if (t.name.len == 0) "[No Name]" else t.name.text();
        @memcpy(text[0..name.len], name);
        text[name.len] = 0;
        gtk.gtk_label_set_text(l, @ptrCast(&text));
        gtk.gtk_label_set_attributes(l, null);
        return;
    }
    var spans: [core.tab_label.TabLabel.MAX_RUNS]ui_state.LabelSpan = undefined;
    const ll = ui_state.labelLines(&t.label, text[0 .. text.len - 1], &spans);
    text[ll.text.len] = 0;
    const list = gtk.pango_attr_list_new() orelse return;
    defer gtk.pango_attr_list_unref(list);
    // Lines past the first a step smaller, as the other frontends draw them.
    if (std.mem.indexOfScalar(u8, ll.text, '\n')) |nl| {
        if (gtk.pango_attr_scale_new(0.9)) |a| insert(list, a, @intCast(nl + 1), @intCast(ll.text.len));
    }
    const hl = core.highlight;
    for (ll.spans) |sp| {
        if (sp.flags & hl.TAB_CHUNK_HAS_FG != 0) {
            const r: u16 = @intCast(((sp.fg_rgb >> 16) & 0xff) * 257);
            const g: u16 = @intCast(((sp.fg_rgb >> 8) & 0xff) * 257);
            const b: u16 = @intCast((sp.fg_rgb & 0xff) * 257);
            if (gtk.pango_attr_foreground_new(r, g, b)) |a| insert(list, a, sp.start, sp.end);
        }
        if (sp.flags & hl.TAB_CHUNK_BOLD != 0) if (gtk.pango_attr_weight_new(gtk.PANGO_WEIGHT_BOLD)) |a| insert(list, a, sp.start, sp.end);
        if (sp.flags & hl.TAB_CHUNK_ITALIC != 0) if (gtk.pango_attr_style_new(gtk.PANGO_STYLE_ITALIC)) |a| insert(list, a, sp.start, sp.end);
        if (sp.flags & hl.TAB_CHUNK_UNDERLINE != 0) if (gtk.pango_attr_underline_new(gtk.PANGO_UNDERLINE_SINGLE)) |a| insert(list, a, sp.start, sp.end);
        if (sp.flags & hl.TAB_CHUNK_STRIKETHROUGH != 0) if (gtk.pango_attr_strikethrough_new(1)) |a| insert(list, a, sp.start, sp.end);
    }
    gtk.gtk_label_set_text(l, @ptrCast(&text));
    gtk.gtk_label_set_attributes(l, list);
}

fn insert(list: *anyopaque, attr: *gtk.PangoAttribute, start: u32, end: u32) void {
    attr.start_index = start;
    attr.end_index = end;
    gtk.pango_attr_list_insert(list, attr);
}

/// A titlebar tab's width: the strip shared out within the shared bounds.
/// Rerun when the strip's width may have changed.
pub fn sizeTabs(app: *App) void {
    const s = &app.widgets.strip;
    if (s.sidebar or s.tab_count == 0) return;
    const root = s.root orelse return;
    const tabs = s.tabs orelse return;
    const plus_w: c_int = 40;
    const avail = gtk.gtk_widget_get_width(root) - plus_w;
    const tw: c_int = rules.titlebarTabWidth(avail, @intCast(s.tab_count), rules.tab_min_width_pt, rules.tab_max_width_pt);
    if (tw == s.tab_w) return;
    s.tab_w = tw;
    var child = gtk.gtk_widget_get_first_child(tabs);
    while (child) |c| : (child = gtk.gtk_widget_get_next_sibling(c)) gtk.gtk_widget_set_size_request(c, tw, -1);
}

const claude_frames = [_][:0]const u8{ "·", "✢", "✳", "✶", "✻", "✽" };
const braille_frames = [_][:0]const u8{ "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" };
const spinner_interval_ms = 120;

/// The per-tab indicator for an agent state: 🤖 done, ⏸ waiting for input,
/// a spinner while working, as Windows draws them.
pub fn indicatorGlyph(state: u8, frame: u32) [:0]const u8 {
    return switch (state) {
        1 => "\u{1f916}",
        2 => claude_frames[frame % claude_frames.len],
        3 => braille_frames[frame % braille_frames.len],
        4 => "\u{23f8}",
        else => "",
    };
}

/// Sets every tab's indicator from `ui`, and runs the spinner timer while
/// some agent works.
fn applyIndicators(app: *App, ui: *const ui_state.UiState) void {
    const s = &app.widgets.strip;
    if (!app.tabline_cfg.agent_indicator) return;
    var child = if (s.tabs) |t| gtk.gtk_widget_get_first_child(t) else null;
    for (ui.tabs[0..ui.tab_count]) |t| {
        const tab = child orelse break;
        child = gtk.gtk_widget_get_next_sibling(tab);
        const ind = gtk.gtk_widget_get_first_child(tab) orelse continue;
        const glyph = indicatorGlyph(ui.agentState(t.handle), s.spinner_frame);
        gtk.gtk_label_set_text(ind, glyph.ptr);
        gtk.gtk_widget_set_visible(ind, @intFromBool(glyph.len != 0));
    }
    const working = ui.anyWorking();
    if (working and s.spinner_timer == 0) {
        s.spinner_timer = gtk.g_timeout_add(spinner_interval_ms, &onSpinner, app);
    } else if (!working and s.spinner_timer != 0) {
        _ = gtk.g_source_remove(s.spinner_timer);
        s.spinner_timer = 0;
    }
}

fn onSpinner(data: ?*anyopaque) callconv(.c) c_int {
    const app: *App = @ptrCast(@alignCast(data.?));
    app.widgets.strip.spinner_frame +%= 1;
    applyIndicators(app, &app.ui_snapshot.ui);
    // applyIndicators keeps the timer while anything works.
    return @intFromBool(app.widgets.strip.spinner_timer != 0);
}

// =========================================================================
// Commands
// =========================================================================

fn sendCommand(app: *App, cmd: []const u8) void {
    const cp = app.corep orelse return;
    core.zonvie_core_send_command(cp, cmd.ptr, cmd.len);
    if (app.gl_area) |a| _ = gtk.gtk_widget_grab_focus(a);
}

fn theApp() ?*App {
    return @import("ui_widgets.zig").the_app;
}

fn onTabClick(gesture: ?*anyopaque, n_press: c_int, x: f64, y: f64, data: ?*anyopaque) callconv(.c) void {
    _ = n_press;
    const app = theApp() orelse return;
    // The close button's own click: it closes, it does not select.
    if (gtk.gtk_event_controller_get_widget(gesture.?)) |tab| {
        if (gtk.gtk_widget_pick(tab, x, y, 0)) |hit| {
            if (gtk.gtk_widget_has_css_class(hit, "zonvie-tab-close") != 0 or
                (gtk.gtk_widget_get_parent(hit) != null and gtk.gtk_widget_has_css_class(gtk.gtk_widget_get_parent(hit).?, "zonvie-tab-close") != 0)) return;
        }
    }
    var buf: [32]u8 = undefined;
    sendCommand(app, std.fmt.bufPrint(&buf, "{d}tabnext", .{@intFromPtr(data)}) catch return);
}

fn onTabClose(btn: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    _ = btn;
    const app = theApp() orelse return;
    var buf: [32]u8 = undefined;
    sendCommand(app, std.fmt.bufPrint(&buf, "{d}tabclose", .{@intFromPtr(data)}) catch return);
}

fn onNewTab(btn: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    _ = btn;
    sendCommand(@ptrCast(@alignCast(data.?)), "tabnew");
}

// =========================================================================
// Drag: reorder and tear-off
// =========================================================================

/// The tabs' extents along the strip, in `tabs` coordinates; at most
/// tab_cap of them.
const Extents = struct {
    starts: [ui_state.tab_cap]f64 = undefined,
    ends: [ui_state.tab_cap]f64 = undefined,
    centres: [ui_state.tab_cap]f64 = undefined,
    n: usize = 0,
};

fn extents(s: *const Strip) Extents {
    var e: Extents = .{};
    const tabs = s.tabs orelse return e;
    var child = gtk.gtk_widget_get_first_child(tabs);
    while (child) |c| : (child = gtk.gtk_widget_get_next_sibling(c)) {
        if (e.n == e.starts.len) break;
        var r: gtk.GrapheneRect = .{};
        if (gtk.gtk_widget_compute_bounds(c, tabs, &r) == 0) continue;
        const start: f64 = if (s.sidebar) r.y else r.x;
        const len: f64 = if (s.sidebar) r.h else r.w;
        e.starts[e.n] = start;
        e.ends[e.n] = start + len;
        e.centres[e.n] = start + len / 2;
        e.n += 1;
    }
    return e;
}

fn tabAt(s: *const Strip, pos: f64) ?u32 {
    const e = extents(s);
    for (0..e.n) |i| if (pos >= e.starts[i] and pos < e.ends[i]) return @intCast(i);
    return null;
}

fn onDragBegin(gesture: ?*anyopaque, x: f64, y: f64, data: ?*anyopaque) callconv(.c) void {
    _ = gesture;
    const app: *App = @ptrCast(@alignCast(data.?));
    const s = &app.widgets.strip;
    s.drag = .{ .start = .{ x, y }, .from = tabAt(s, if (s.sidebar) y else x) };
}

/// The pointer, in the scroller's (the visible strip's) coordinates.
fn inViewport(s: *const Strip, x: f64, y: f64) [2]f64 {
    const tabs = s.tabs orelse return .{ x, y };
    const scroller = s.scroller orelse return .{ x, y };
    var r: gtk.GrapheneRect = .{};
    if (gtk.gtk_widget_compute_bounds(tabs, scroller, &r) == 0) return .{ x, y };
    return .{ x + r.x, y + r.y };
}

fn onDragUpdate(gesture: ?*anyopaque, dx: f64, dy: f64, data: ?*anyopaque) callconv(.c) void {
    const app: *App = @ptrCast(@alignCast(data.?));
    const s = &app.widgets.strip;
    const from = s.drag.from orelse return;
    const x = s.drag.start[0] + dx;
    const y = s.drag.start[1] + dy;
    const scroller = s.scroller orelse return;
    const size = [2]f64{ @floatFromInt(gtk.gtk_widget_get_width(scroller)), @floatFromInt(gtk.gtk_widget_get_height(scroller)) };
    const mode = dragMode(inViewport(s, x, y), size, .{ dx, dy });
    if (mode == .pending) return;
    // Claimed: the window handle around a titlebar strip must not move
    // the window, and the tab's click must not select on release.
    if (s.drag.mode == .pending) _ = gtk.gtk_gesture_set_state(gesture.?, gtk.GTK_EVENT_SEQUENCE_CLAIMED);
    s.drag.mode = mode;
    const tab = nthTab(s, from);
    if (tab) |t| gtk.gtk_widget_add_css_class(t, "dragging");
    switch (mode) {
        .pending => {},
        .reorder => {
            if (s.preview) |p| gtk.gtk_widget_set_visible(p, 0);
            showReorder(s, from, x, y);
        },
        .tear_off => {
            if (s.drop_line) |l| gtk.gtk_widget_set_visible(l, 0);
            if (s.floating) |f| gtk.gtk_widget_set_visible(f, 0);
            showPreview(app, from, x, y);
        },
    }
}

fn nthTab(s: *const Strip, idx: u32) ?*anyopaque {
    var child = if (s.tabs) |t| gtk.gtk_widget_get_first_child(t) else null;
    var i: u32 = 0;
    while (child) |c| : (child = gtk.gtk_widget_get_next_sibling(c)) {
        if (i == idx) return c;
        i += 1;
    }
    return null;
}

fn tabText(s: *const Strip, idx: u32) [*:0]const u8 {
    const tab = nthTab(s, idx) orelse return "";
    const ind = gtk.gtk_widget_get_first_child(tab) orelse return "";
    const name = gtk.gtk_widget_get_next_sibling(ind) orelse return "";
    return gtk.gtk_label_get_text(name);
}

/// The drop line at the insertion boundary and the dragged tab floating
/// under the pointer along the strip.
fn showReorder(s: *Strip, from: u32, x: f64, y: f64) void {
    const e = extents(s);
    if (e.n == 0) return;
    const pos = if (s.sidebar) y else x;
    const idx = dropIndexAt(pos, e.centres[0..e.n]);
    const line_pos: c_int = @intFromFloat(@max(0, dropLinePos(idx, e.starts[0..e.n], e.ends[0..e.n]) - 1));
    if (s.drop_line) |l| {
        if (s.sidebar) gtk.gtk_widget_set_margin_top(l, line_pos) else gtk.gtk_widget_set_margin_start(l, line_pos);
        gtk.gtk_widget_set_visible(l, 1);
    }
    if (s.floating) |f| {
        const len = e.ends[from] - e.starts[from];
        gtk.gtk_label_set_text(f, tabText(s, from));
        const start: c_int = @intFromFloat(@max(0, pos - len / 2));
        if (s.sidebar) {
            gtk.gtk_widget_set_margin_top(f, start);
            gtk.gtk_widget_set_size_request(f, -1, @intFromFloat(len));
        } else {
            gtk.gtk_widget_set_margin_start(f, start);
            gtk.gtk_widget_set_size_request(f, @intFromFloat(len), -1);
        }
        gtk.gtk_widget_set_visible(f, 1);
    }
}

/// The tear-off preview at the pointer, over the window's content.
fn showPreview(app: *App, from: u32, x: f64, y: f64) void {
    const s = &app.widgets.strip;
    const p = s.preview orelse return;
    const tabs = s.tabs orelse return;
    const wo = s.window_overlay orelse return;
    var r: gtk.GrapheneRect = .{};
    if (gtk.gtk_widget_compute_bounds(tabs, wo, &r) == 0) return;
    gtk.gtk_label_set_text(p, tabText(s, from));
    gtk.gtk_widget_set_margin_start(p, @intFromFloat(@max(0, r.x + x - 75)));
    gtk.gtk_widget_set_margin_top(p, @intFromFloat(@max(0, r.y + y - 15)));
    gtk.gtk_widget_set_visible(p, 1);
}

fn endDrag(s: *Strip) void {
    if (s.drag.from) |from| if (nthTab(s, from)) |t| gtk.gtk_widget_remove_css_class(t, "dragging");
    if (s.drop_line) |l| gtk.gtk_widget_set_visible(l, 0);
    if (s.floating) |f| gtk.gtk_widget_set_visible(f, 0);
    if (s.preview) |p| gtk.gtk_widget_set_visible(p, 0);
    s.drag = .{};
}

fn onDragEnd(gesture: ?*anyopaque, dx: f64, dy: f64, data: ?*anyopaque) callconv(.c) void {
    const app: *App = @ptrCast(@alignCast(data.?));
    const s = &app.widgets.strip;
    const from = s.drag.from;
    const mode = s.drag.mode;
    const end = [2]f64{ s.drag.start[0] + dx, s.drag.start[1] + dy };
    const pos = (if (s.sidebar) end[1] else end[0]);
    const e = extents(s);
    endDrag(s);
    const f = from orelse return;
    const cp = app.corep orelse return;
    switch (mode) {
        .pending => {},
        // Selects the dragged tab and moves it in one command; nothing for a
        // drop onto its own slot.
        .reorder => _ = core.zonvie_core_tab_move(cp, f, dropIndexAt(pos, e.centres[0..e.n]), @intCast(s.tab_count)),
        // Under X11 the new external window opens at the drop point, which
        // its open takes (ext_window); on Wayland, where no client places a
        // toplevel, it opens where the compositor puts it.
        .tear_off => {
            if (app.window) |win| if (gtk.gtk_event_controller_get_widget(gesture.?)) |w| {
                if (x11_place.widgetPoint(win, w, end[0], end[1])) |p| {
                    app.ext_placement.setPending(p[0], p[1], @intCast(@divTrunc(core.clock.nowNs(), std.time.ns_per_ms)));
                }
            };
            if (applog.isEnabled()) applog.appLog("[tabline] tear off tab {d}\n", .{f});
            core.zonvie_core_externalize_tab(cp, f);
        },
    }
}
