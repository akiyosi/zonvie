//! GTK widgets for the frontend-drawn ext UI (ui_state.zig): mini labels
//! stacked bottom-right, a centred confirm box and a top-right toast over
//! the GLArea, and an ext_tabline strip above it. GTK main thread only. None
//! of them take focus or pointer input, so keys stay with the GLArea.

const std = @import("std");
const core = @import("zonvie_core");
const clock = core.clock;
const App = @import("app.zig").App;
const gtk = @import("gtk_bindings.zig");
const ui_state = @import("ui_state.zig");

const margin_pt = 10;

pub const Widgets = struct {
    tabbar: ?*anyopaque = null,
    mini_box: ?*anyopaque = null,
    minis: [4]?*anyopaque = @splat(null),
    confirm: ?*anyopaque = null,
    toast: ?*anyopaque = null,
    css: ?*anyopaque = null,
    /// The colors the stylesheet was last built from; 0xffffffff until then.
    css_fg: u32 = 0xffffffff,
    css_bg: u32 = 0xffffffff,
    /// The tabline the strip was last built from.
    tab_count: usize = 0,
    tab_handles: [ui_state.tab_cap]i64 = @splat(0),
    curtab: i64 = 0,
};

fn label(classes: []const [*:0]const u8) *anyopaque {
    const l = gtk.gtk_label_new(null).?;
    for (classes) |c| gtk.gtk_widget_add_css_class(l, c);
    gtk.gtk_label_set_wrap(l, 1);
    gtk.gtk_label_set_xalign(l, 0);
    gtk.gtk_widget_set_can_target(l, 0);
    gtk.gtk_widget_set_visible(l, 0);
    return l;
}

/// Builds the window content around `area`: a vertical box holding the tab
/// strip and an overlay whose child is the GLArea. Returns the box.
pub fn build(app: *App, area: *anyopaque) *anyopaque {
    const w = &app.widgets;
    const root = gtk.gtk_box_new(gtk.GTK_ORIENTATION_VERTICAL, 0).?;
    const tabbar = gtk.gtk_box_new(gtk.GTK_ORIENTATION_HORIZONTAL, 0).?;
    gtk.gtk_widget_add_css_class(tabbar, "zonvie-tabbar");
    gtk.gtk_widget_set_visible(tabbar, 0);
    w.tabbar = tabbar;
    gtk.gtk_box_append(root, tabbar);

    const overlay = gtk.gtk_overlay_new().?;
    gtk.gtk_widget_set_vexpand(overlay, 1);
    gtk.gtk_overlay_set_child(overlay, area);
    gtk.gtk_box_append(root, overlay);

    const m: c_int = margin_pt;
    const mini_box = gtk.gtk_box_new(gtk.GTK_ORIENTATION_VERTICAL, 4).?;
    gtk.gtk_widget_set_halign(mini_box, gtk.GTK_ALIGN_END);
    gtk.gtk_widget_set_valign(mini_box, gtk.GTK_ALIGN_END);
    gtk.gtk_widget_set_margin_end(mini_box, m);
    gtk.gtk_widget_set_margin_bottom(mini_box, m);
    gtk.gtk_widget_set_can_target(mini_box, 0);
    // Top to bottom: a message above the statuses, as the minis stack upward.
    for ([_]ui_state.Mini{ .message, .showcmd, .showmode, .ruler }) |which| {
        const l = label(&.{ "zonvie-panel", "zonvie-mini" });
        gtk.gtk_widget_set_halign(l, gtk.GTK_ALIGN_END);
        w.minis[@intFromEnum(which)] = l;
        gtk.gtk_box_append(mini_box, l);
    }
    w.mini_box = mini_box;
    gtk.gtk_overlay_add_overlay(overlay, mini_box);

    const confirm = label(&.{ "zonvie-panel", "zonvie-confirm" });
    gtk.gtk_widget_set_halign(confirm, gtk.GTK_ALIGN_CENTER);
    gtk.gtk_widget_set_valign(confirm, gtk.GTK_ALIGN_CENTER);
    w.confirm = confirm;
    gtk.gtk_overlay_add_overlay(overlay, confirm);

    const toast = label(&.{"zonvie-panel"});
    gtk.gtk_widget_set_halign(toast, gtk.GTK_ALIGN_END);
    gtk.gtk_widget_set_valign(toast, gtk.GTK_ALIGN_START);
    gtk.gtk_widget_set_margin_end(toast, m);
    gtk.gtk_widget_set_margin_top(toast, m);
    w.toast = toast;
    gtk.gtk_overlay_add_overlay(overlay, toast);

    if (gtk.gtk_css_provider_new()) |css| {
        w.css = css;
        if (gtk.gtk_widget_get_display(root)) |d| gtk.gtk_style_context_add_provider_for_display(d, css, gtk.GTK_STYLE_PROVIDER_PRIORITY_APPLICATION);
    }
    return root;
}

/// Callable from any thread; at most one refresh is outstanding.
pub fn queueRefresh(app: *App) void {
    if (app.ui_idle_queued.swap(true, .acq_rel)) return;
    _ = gtk.g_idle_add(&idleRefresh, app);
}

/// A snapshot taken under App.mu, so GTK runs with the lock released.
const Snapshot = struct {
    ui: ui_state.UiState,
    fg: u32,
    bg: u32,
};

fn idleRefresh(data: ?*anyopaque) callconv(.c) c_int {
    const app: *App = @ptrCast(@alignCast(data.?));
    app.ui_idle_queued.store(false, .release);
    // Large (the confirm and toast buffers); kept off the stack.
    const snap = &app.ui_snapshot;
    app.mu.lockUncancelable(clock.io());
    snap.* = .{ .ui = app.ui, .fg = app.default_fg, .bg = app.default_bg };
    app.mu.unlock(clock.io());
    apply(app, snap);
    return 0;
}

pub const SnapshotStorage = Snapshot;

fn setText(l: ?*anyopaque, text: []const u8, buf: []u8) void {
    const w = l orelse return;
    if (text.len == 0) {
        gtk.gtk_widget_set_visible(w, 0);
        return;
    }
    const n = @min(text.len, buf.len - 1);
    @memcpy(buf[0..n], text[0..n]);
    buf[n] = 0;
    gtk.gtk_label_set_text(w, @ptrCast(buf.ptr));
    gtk.gtk_widget_set_visible(w, 1);
}

fn apply(app: *App, snap: *const Snapshot) void {
    const w = &app.widgets;
    applyCss(w, snap.fg, snap.bg);
    const buf = &app.ui_text_scratch;
    for (snap.ui.minis, 0..) |m, i| setText(w.minis[i], m.text(), buf);
    setText(w.confirm, snap.ui.confirm.text(), buf);
    setText(w.toast, snap.ui.toast.text(), buf);
    if (w.toast) |t| {
        setToneClass(t, snap.ui.toast_tone);
        if (snap.ui.toast.len != 0 and snap.ui.toast_timeout_ms != 0 and app.toast_timer_seq != snap.ui.toast_seq) {
            app.toast_timer_seq = snap.ui.toast_seq;
            _ = gtk.g_timeout_add(snap.ui.toast_timeout_ms, &onToastTimeout, app);
        }
    }
    applyTabline(app, &snap.ui);
}

const tone_classes = [_][*:0]const u8{ "tone-error", "tone-warn" };

fn setToneClass(widget: *anyopaque, tone: u8) void {
    for (tone_classes) |c| gtk.gtk_widget_remove_css_class(widget, c);
    switch (tone) {
        1 => gtk.gtk_widget_add_css_class(widget, tone_classes[0]),
        2 => gtk.gtk_widget_add_css_class(widget, tone_classes[1]),
        else => {},
    }
}

/// Hides the toast that set this timer, unless a newer one replaced it.
fn onToastTimeout(data: ?*anyopaque) callconv(.c) c_int {
    const app: *App = @ptrCast(@alignCast(data.?));
    app.mu.lockUncancelable(clock.io());
    const current = app.ui.toast_seq == app.toast_timer_seq;
    if (current) app.ui.toast.clear();
    app.mu.unlock(clock.io());
    if (current) queueRefresh(app);
    return 0;
}

fn applyCss(w: *Widgets, fg: u32, bg: u32) void {
    if (w.css_fg == fg and w.css_bg == bg) return;
    const css = w.css orelse return;
    w.css_fg = fg;
    w.css_bg = bg;
    const b: [3]f32 = .{
        @as(f32, @floatFromInt((bg >> 16) & 0xff)) / 255.0,
        @as(f32, @floatFromInt((bg >> 8) & 0xff)) / 255.0,
        @as(f32, @floatFromInt(bg & 0xff)) / 255.0,
    };
    const p = core.frontend_rules.panelBg(b[0], b[1], b[2]);
    const panel: u32 = (@as(u32, @intFromFloat(p[0] * 255)) << 16) | (@as(u32, @intFromFloat(p[1] * 255)) << 8) | @as(u32, @intFromFloat(p[2] * 255));
    var buf: [1536]u8 = undefined;
    const text = std.fmt.bufPrintZ(&buf,
        \\.zonvie-panel {{ background-color: #{x:0>6}; color: #{x:0>6}; font-family: monospace;
        \\  padding: 6px 10px; border-radius: 6px; border: 1px solid alpha(#{x:0>6}, 0.25); }}
        \\.zonvie-confirm {{ padding: 12px 16px; }}
        \\.zonvie-panel.tone-error {{ border-color: #e06c75; color: #e06c75; }}
        \\.zonvie-panel.tone-warn {{ border-color: #e5c07b; }}
        \\.zonvie-tabbar {{ background-color: #{x:0>6}; }}
        \\.zonvie-tabbar button {{ background: none; color: alpha(#{x:0>6}, 0.6); border-radius: 0;
        \\  border: none; padding: 4px 14px; font-family: monospace; }}
        \\.zonvie-tabbar button.current {{ background-color: #{x:0>6}; color: #{x:0>6}; }}
    , .{ panel, fg, fg, panel, fg, bg, fg }) catch return;
    gtk.gtk_css_provider_load_from_string(css, text.ptr);
}

const TabClick = struct { app: *App, index: u32 };

fn applyTabline(app: *App, ui: *const ui_state.UiState) void {
    const w = &app.widgets;
    const bar = w.tabbar orelse return;
    gtk.gtk_widget_set_visible(bar, @intFromBool(ui.tabline_visible));
    var same = w.tab_count == ui.tab_count and w.curtab == ui.curtab;
    if (same) {
        for (ui.tabs[0..ui.tab_count], w.tab_handles[0..ui.tab_count]) |t, h| {
            if (t.handle != h) same = false;
        }
    }
    // Names are not compared: a rename rebuilds on the next change, and a
    // tabline update without one is the common case worth skipping.
    if (same and ui.tab_count != 0) {
        var child = gtk.gtk_widget_get_first_child(bar);
        for (ui.tabs[0..ui.tab_count]) |t| {
            const btn = child orelse break;
            setButtonLabel(app, btn, t.name.text());
            child = gtk.gtk_widget_get_next_sibling(btn);
        }
        return;
    }
    while (gtk.gtk_widget_get_first_child(bar)) |c| gtk.gtk_box_remove(bar, c);
    w.tab_count = ui.tab_count;
    w.curtab = ui.curtab;
    for (ui.tabs[0..ui.tab_count], 0..) |t, i| {
        w.tab_handles[i] = t.handle;
        const btn = gtk.gtk_button_new_with_label("") orelse continue;
        setButtonLabel(app, btn, t.name.text());
        gtk.gtk_widget_set_focusable(btn, 0);
        if (t.handle == ui.curtab) gtk.gtk_widget_add_css_class(btn, "current");
        _ = gtk.g_signal_connect(btn, "clicked", @ptrCast(&onTabClicked), @ptrFromInt(i + 1));
        gtk.gtk_box_append(bar, btn);
    }
}

fn setButtonLabel(app: *App, btn: *anyopaque, name: []const u8) void {
    const buf = &app.ui_text_scratch;
    const text = if (name.len == 0) "[No Name]" else name;
    const n = @min(text.len, 255);
    @memcpy(buf[0..n], text[0..n]);
    buf[n] = 0;
    gtk.gtk_button_set_label(btn, @ptrCast(buf.ptr));
}

/// `data` is the tab's 1-based index; the app is the process-wide one.
fn onTabClicked(btn: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    _ = btn;
    const app = the_app orelse return;
    const cp = app.corep orelse return;
    var buf: [32]u8 = undefined;
    const cmd = std.fmt.bufPrint(&buf, "{d}tabnext", .{@intFromPtr(data)}) catch return;
    core.zonvie_core_send_command(cp, cmd.ptr, cmd.len);
    if (app.gl_area) |a| _ = gtk.gtk_widget_grab_focus(a);
}

/// Set once in main before the window exists; tab buttons carry only their
/// index as signal data.
pub var the_app: ?*App = null;
