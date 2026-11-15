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
const applog = @import("app_log.zig");
const overlay_layout = @import("overlay_layout.zig");
const gl_renderer = @import("renderer/gl_renderer.zig");
const tab_strip = @import("tab_strip.zig");
const chrome = @import("chrome.zig");
const notify = @import("notify.zig");
const window_size = @import("window_size.zig");
const input = @import("input.zig");
const popup_place = @import("popup_place.zig");
const panel_popup = @import("panel_popup.zig");

const margin_pt = 10;

pub const Widgets = struct {
    /// The ext tabline strip (titlebar tabs or sidebar rows).
    strip: tab_strip.Strip = .{},
    /// The window's header, sidebar and menus.
    chrome: chrome.Chrome = .{},
    /// The minis' margins from the view's right and bottom edges, logical px.
    mini_place: [2]c_int = .{ -1, -1 },
    /// Holds the editor view and the boxes over it; the same size as the view.
    overlay: ?*anyopaque = null,
    /// The rounded editor card around `overlay` (App.island); null without one.
    card: ?*anyopaque = null,
    /// The alpha of the card's ring and ground: [window] opacity, which the
    /// view inside clears itself with. Set with `card`, before the first
    /// stylesheet, and fixed from then on.
    opacity: f32 = 1,
    /// [window] opacity, the alpha of the message boxes' fill as of the GL
    /// panels' (gl_renderer.drawOverlays). Fixed at build.
    panel_alpha: f32 = 1,
    mini_box: ?*anyopaque = null,
    minis: [4]?*anyopaque = @splat(null),
    confirm: ?*anyopaque = null,
    toast: ?*anyopaque = null,
    /// Copy buttons over the cmdline, msg_show and msg_history panels, by
    /// overlay_layout.Kind; null for the popupmenu.
    copy: [4]?*anyopaque = @splat(null),
    /// The surface whose view holds the minis' box, the toast and (while
    /// they are not in panel popups) each copy button: the one msg_pos puts
    /// them on (rehost).
    mini_host: i64 = 1,
    toast_host: i64 = 1,
    copy_host: [4]i64 = @splat(1),
    /// A click's remaining tries while the core's grid lock is busy.
    copy_tries: u8 = 0,
    copy_grid: i64 = 0,
    /// A start that takes a while (a devcontainer), until the first frame.
    progress: ?*anyopaque = null,
    /// The IME composition, drawn over the cursor cell ([input]
    /// ime_preedit_mode = "overlay", or outside insert mode).
    preedit: ?*anyopaque = null,
    css: ?*anyopaque = null,
    /// The colors the stylesheet was last built from; 0xffffffff until then.
    css_fg: u32 = 0xffffffff,
    css_bg: u32 = 0xffffffff,
    css_font_px: u32 = 0,
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

/// Builds the window content around `area`: a box holding the tab strip
/// (above, or beside it as a [tabline] sidebar) and an overlay whose child is
/// the editor widget. `frames`, when the render thread draws, is the picture
/// showing its frames, layered over `area` and under the message widgets.
/// Returns the box.
pub fn build(app: *App, area: *anyopaque, frames: ?*anyopaque) *anyopaque {
    const w = &app.widgets;
    const overlay = gtk.gtk_overlay_new().?;
    gtk.gtk_widget_set_vexpand(overlay, 1);
    gtk.gtk_widget_set_hexpand(overlay, 1);
    gtk.gtk_overlay_set_child(overlay, area);
    w.overlay = overlay;
    w.panel_alpha = std.math.clamp(app.window_cfg.opacity, 0, 1);
    input.attachPanelHover(&app.pointer, overlay);
    if (frames) |f| gtk.gtk_overlay_add_overlay(overlay, f);
    // The editor card: the overlay inside a styled box (.zonvie-card), whose
    // ground is a shadow the holder clips to its own rect. A ground painted
    // under the card would show through a translucent one (applyCss).
    var content: *anyopaque = overlay;
    if (app.island()) {
        const card = gtk.gtk_box_new(gtk.GTK_ORIENTATION_HORIZONTAL, 0).?;
        gtk.gtk_widget_add_css_class(card, "zonvie-card");
        gtk.gtk_box_append(card, overlay);
        const holder = gtk.gtk_box_new(gtk.GTK_ORIENTATION_HORIZONTAL, 0).?;
        gtk.gtk_widget_set_overflow(holder, gtk.GTK_OVERFLOW_HIDDEN);
        gtk.gtk_widget_set_vexpand(holder, 1);
        gtk.gtk_box_append(holder, card);
        w.card = card;
        w.opacity = std.math.clamp(app.window_cfg.opacity, 0, 1);
        content = holder;
    }
    const root = chrome.build(app, content);

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

    const confirm = label(&.{ "zonvie-panel", "zonvie-confirm", "zonvie-confirm-prompt" });
    gtk.gtk_widget_set_halign(confirm, gtk.GTK_ALIGN_CENTER);
    // Its top is placeMessages' (overlay_layout.confirmTop).
    gtk.gtk_widget_set_valign(confirm, gtk.GTK_ALIGN_START);
    w.confirm = confirm;
    gtk.gtk_overlay_add_overlay(overlay, confirm);

    const toast = label(&.{ "zonvie-panel", "zonvie-toast" });
    gtk.gtk_widget_set_halign(toast, gtk.GTK_ALIGN_END);
    gtk.gtk_widget_set_valign(toast, gtk.GTK_ALIGN_START);
    gtk.gtk_widget_set_margin_end(toast, m);
    gtk.gtk_widget_set_margin_top(toast, m);
    w.toast = toast;
    gtk.gtk_overlay_add_overlay(overlay, toast);

    for ([_]overlay_layout.Kind{ .cmdline, .msg_show, .msg_history }) |kind| {
        const b = gtk.gtk_button_new_with_label(copy_glyph).?;
        gtk.gtk_widget_add_css_class(b, "zonvie-copy");
        // macOS's tooltip.
        gtk.gtk_widget_set_tooltip_text(b, "Copy contents");
        gtk.gtk_widget_set_focusable(b, 0);
        gtk.gtk_widget_set_halign(b, gtk.GTK_ALIGN_START);
        gtk.gtk_widget_set_valign(b, gtk.GTK_ALIGN_START);
        gtk.gtk_widget_set_visible(b, 0);
        _ = gtk.g_signal_connect(b, "clicked", @ptrCast(&onCopyClicked), @ptrFromInt(@as(usize, @intFromEnum(kind)) + 1));
        w.copy[@intFromEnum(kind)] = b;
        gtk.gtk_overlay_add_overlay(overlay, b);
    }

    const progress = label(&.{ "zonvie-panel", "zonvie-confirm" });
    gtk.gtk_widget_set_halign(progress, gtk.GTK_ALIGN_CENTER);
    gtk.gtk_widget_set_valign(progress, gtk.GTK_ALIGN_CENTER);
    w.progress = progress;
    gtk.gtk_overlay_add_overlay(overlay, progress);

    const preedit = newPreeditLabel().?;
    w.preedit = preedit;
    gtk.gtk_overlay_add_overlay(overlay, preedit);

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
    /// The editor font's size in logical px; 0 before the first font.
    font_px: u32,
};

fn idleRefresh(data: ?*anyopaque) callconv(.c) c_int {
    const app: *App = @ptrCast(@alignCast(data.?));
    app.ui_idle_queued.store(false, .release);
    // Large (the confirm and toast buffers); kept off the stack.
    const snap = &app.ui_snapshot;
    app.mu.lockUncancelable(clock.io());
    snap.* = .{ .ui = app.ui, .fg = app.default_fg, .bg = app.default_bg, .font_px = @intFromFloat(@round(app.preedit_px)) };
    // Announced once: the snapshot carries them out.
    app.ui.done_count = 0;
    app.ui.notice_pending = false;
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
    applyCss(w, snap.fg, snap.bg, snap.font_px);
    if (w.css_bg != 0xffffffff) window_size.chromeReady(app);
    const buf = &app.ui_text_scratch;
    for (snap.ui.minis, 0..) |m, i| setText(w.minis[i], m.text(), buf);
    setText(w.confirm, snap.ui.confirm.text(), buf);
    var toast_buf: [5 * 1025 + 3 * 257]u8 = undefined;
    setText(w.toast, snap.ui.toastText(&toast_buf), buf);
    if (w.toast) |t| {
        setToneClass(t, snap.ui.toastTone());
        // timeout 0 stays (errors). The timer belongs to the stack.
        if (snap.ui.toast_count != 0 and snap.ui.toast_timeout_ms != 0 and app.toast_timer_seq != snap.ui.toast_seq) {
            app.toast_timer_seq = snap.ui.toast_seq;
            _ = gtk.g_timeout_add(snap.ui.toast_timeout_ms, &onToastTimeout, app);
        }
    }
    if (snap.ui.minis[@intFromEnum(ui_state.Mini.message)].len != 0 and snap.ui.mini_timeout_ms != 0 and app.mini_timer_seq != snap.ui.mini_seq) {
        app.mini_timer_seq = snap.ui.mini_seq;
        _ = gtk.g_timeout_add(snap.ui.mini_timeout_ms, &onMiniTimeout, app);
    }
    applyTabline(app, &snap.ui);
    placeMessages(app);
    if (snap.ui.done_count != 0) notifyCompletions(app, snap.ui.done[0..snap.ui.done_count]);
    if (snap.ui.notice_pending) notify.send(app, .none, "Neovim", snap.ui.notice.text());
}

/// The OS notification for agent completions ([tabline] agent_notification),
/// sent always: the agent runs in this app's own terminal, so focus says
/// nothing about whether the user saw it.
fn notifyCompletions(app: *App, done: []const ui_state.Completion) void {
    var buf: [320]u8 = undefined;
    const msg = ui_state.completionMessage(buf[0 .. buf.len - 1], done);
    notify.send(app, .agent, "Zonvie", msg);
}

/// The surface whose view a widget msg_pos `mode` places goes on: the
/// external window overlay_layout.msgSurface names while its view exists,
/// else the main view.
fn widgetSurface(app: *App, mode: core.config.MsgPosition) i64 {
    app.mu.lockUncancelable(clock.io());
    const id = gl_renderer.msgSurface(app, mode);
    app.mu.unlock(clock.io());
    return if (id != 1 and panel_popup.hostView(app, id) != null) id else 1;
}

/// Moves overlay child `widget` onto surface `to`'s view and records it in
/// `host`. Pre: `widget` is a child overlay of surface host.*'s view, or
/// that surface's view is gone (ext_window.close: it is still the widget's
/// parent). Post: host.* == to unless `to`'s view is gone.
fn rehost(app: *App, widget: *anyopaque, host: *i64, to: i64) void {
    if (host.* == to) return;
    const view = (panel_popup.hostView(app, to) orelse return).view;
    // The parent holds the widget's only reference.
    _ = gtk.g_object_ref(widget);
    defer gtk.g_object_unref(widget);
    if (gtk.gtk_widget_get_parent(widget)) |from| gtk.gtk_overlay_remove_overlay(from, widget);
    gtk.gtk_overlay_add_overlay(view, widget);
    host.* = to;
}

/// Surface `surface_id` is about to close: the widgets over its view go
/// back to the main view, as the panel popups do. Pre: GTK main thread,
/// before the external window is destroyed.
pub fn surfaceClosing(app: *App, surface_id: i64) void {
    const w = &app.widgets;
    if (w.mini_box) |b| if (w.mini_host == surface_id) rehost(app, b, &w.mini_host, 1);
    if (w.toast) |t| if (w.toast_host == surface_id) rehost(app, t, &w.toast_host, 1);
    for (w.copy, &w.copy_host) |btn, *host| {
        if (btn) |b| if (host.* == surface_id) rehost(app, b, host, 1);
    }
}

/// Surface `host`'s view size, device px; 0 x 0 for none.
fn viewSizePx(app: *App, host: i64) [2]i32 {
    app.mu.lockUncancelable(clock.io());
    defer app.mu.unlock(clock.io());
    const s = panel_popup.hostSizePx(app, host);
    return .{ @intCast(s[0]), @intCast(s[1]) };
}

/// Hangs the toast from the top-right of msg_pos.ext_float's target and the
/// minis from the bottom-right of msg_pos.mini's (overlay_layout.msgTargetOn),
/// as macOS and Windows place them: over the external window msg_pos puts
/// them on (overlay_layout.msgSurface), as the message panels are. Rerun
/// after each flush: the cursor's window moves the targets. GTK main thread.
pub fn placeMessages(app: *App) void {
    const w = &app.widgets;
    // A resize reaches here through the flush it causes.
    tab_strip.sizeTabs(app);
    const view = w.overlay orelse return;
    const view_w = gtk.gtk_widget_get_width(view);
    const view_h = gtk.gtk_widget_get_height(view);
    if (view_w <= 0 or view_h <= 0) return;
    app.mu.lockUncancelable(clock.io());
    const anchor = app.msg_anchor;
    const pos = app.msg_pos;
    const scale: i32 = @max(1, @as(i32, @intFromFloat(app.scale)));
    const cw: i32 = @intCast(app.cell_w_px);
    const ch: i32 = @intCast(app.cell_h_px);
    app.mu.unlock(clock.io());
    const vw = view_w * scale;
    const vh = view_h * scale;
    const m: c_int = margin_pt;
    // A monospace advance is about 0.6 of the font size: the widths below,
    // in logical px, become the labels' character limits.
    const char_px: f32 = 0.6 * @as(f32, @floatFromInt(if (w.css_font_px == 0) 13 else @max(12, w.css_font_px)));
    if (w.toast) |t| {
        rehost(app, t, &w.toast_host, widgetSurface(app, pos.ext_float));
        const host = w.toast_host;
        const size = if (host == 1) [2]i32{ vw, vh } else viewSizePx(app, host);
        const r = overlay_layout.msgTargetOn(host, pos.ext_float, anchor, size[0], size[1], cw, ch);
        gtk.gtk_widget_set_margin_top(t, @divTrunc(r.top, scale) + m);
        gtk.gtk_widget_set_margin_end(t, @divTrunc(size[0] - r.right, scale) + m);
        // macOS and Windows: at most 0.8 of the target and 600 wide.
        const max_px = @min(0.8 * @as(f32, @floatFromInt(@divTrunc(r.right - r.left, scale))), 600) - 24;
        gtk.gtk_label_set_max_width_chars(t, @intFromFloat(@max(1, max_px / char_px)));
    }
    var confirm_rect: ?overlay_layout.Rect = null;
    if (w.confirm) |c| {
        // At most the view less 40, and 800.
        const max_px = @as(f32, @floatFromInt(@min(view_w - 40, 800))) - 24;
        gtk.gtk_label_set_max_width_chars(c, @intFromFloat(@max(1, max_px / char_px)));
        if (gtk.gtk_widget_get_visible(c) != 0) {
            // Centred across the view (halign), at its natural size.
            var nat: gtk.GtkRequisition = .{};
            gtk.gtk_widget_get_preferred_size(c, null, &nat);
            const top = overlay_layout.confirmTop(view_h, nat.height, @divTrunc(ch, scale), app.ext_cmdline);
            gtk.gtk_widget_set_margin_top(c, top);
            confirm_rect = .{
                .x = @divTrunc(view_w - nat.width, 2) * scale,
                .y = top * scale,
                .w = nat.width * scale,
                .h = nat.height * scale,
            };
        }
    }
    app.mu.lockUncancelable(clock.io());
    const moved = !std.meta.eql(app.confirm_rect, confirm_rect);
    app.confirm_rect = confirm_rect;
    app.mu.unlock(clock.io());
    if (moved) app.queueRenderAll();
    if (w.mini_box) |b| {
        rehost(app, b, &w.mini_host, widgetSurface(app, pos.mini));
        const host = w.mini_host;
        const size = if (host == 1) [2]i32{ vw, vh } else viewSizePx(app, host);
        const r = overlay_layout.msgTargetOn(host, pos.mini, anchor, size[0], size[1], cw, ch);
        const place: [2]c_int = .{ @divTrunc(size[0] - r.right, scale) + m, @divTrunc(size[1] - r.bottom, scale) + m };
        gtk.gtk_widget_set_margin_end(b, place[0]);
        gtk.gtk_widget_set_margin_bottom(b, place[1]);
        // What the GUI harness reads the minis' corner from, on a change.
        if (!std.mem.eql(c_int, &place, &w.mini_place)) {
            w.mini_place = place;
            applog.appLog("[mini_pos] end={d} bottom={d}\n", .{ place[0], place[1] });
        }
    }
}

/// By zonvie_core_msg_kind_tone: error, warn, prompt, search.
const tone_classes = [_][*:0]const u8{ "tone-error", "tone-warn", "tone-prompt", "tone-search" };

fn setToneClass(widget: *anyopaque, tone: u8) void {
    for (tone_classes) |c| gtk.gtk_widget_remove_css_class(widget, c);
    if (tone >= 1 and tone <= tone_classes.len) gtk.gtk_widget_add_css_class(widget, tone_classes[tone - 1]);
}

/// Hides the toast that set this timer, unless a newer one replaced it.
fn onToastTimeout(data: ?*anyopaque) callconv(.c) c_int {
    const app: *App = @ptrCast(@alignCast(data.?));
    app.mu.lockUncancelable(clock.io());
    const current = app.ui.toast_seq == app.toast_timer_seq;
    if (current) app.ui.toast_count = 0;
    app.mu.unlock(clock.io());
    if (current) queueRefresh(app);
    return 0;
}

/// Hides the mini-routed message that set this timer, unless a newer one
/// replaced it.
fn onMiniTimeout(data: ?*anyopaque) callconv(.c) c_int {
    const app: *App = @ptrCast(@alignCast(data.?));
    app.mu.lockUncancelable(clock.io());
    const current = app.ui.mini_seq == app.mini_timer_seq;
    if (current) app.ui.minis[@intFromEnum(ui_state.Mini.message)].clear();
    app.mu.unlock(clock.io());
    if (current) queueRefresh(app);
    return 0;
}

fn rgbOf(c: [3]f32) u32 {
    const ch = struct {
        fn f(v: f32) u32 {
            return @intFromFloat(@round(std.math.clamp(v, 0, 1) * 255));
        }
    }.f;
    return (ch(c[0]) << 16) | (ch(c[1]) << 8) | ch(c[2]);
}

fn splitRgb(c: u32) [3]f32 {
    return .{
        @as(f32, @floatFromInt((c >> 16) & 0xff)) / 255.0,
        @as(f32, @floatFromInt((c >> 8) & 0xff)) / 255.0,
        @as(f32, @floatFromInt(c & 0xff)) / 255.0,
    };
}

/// Where the first titlebar tab starts on an editor card's ground: past the
/// card's corner.
const tab_strip_inset_pt = core.frontend_rules.island_margin_pt + core.frontend_rules.island_radius_pt;

/// `rgba(r, g, b, a)` for the stylesheet.
fn cssRgba(out: *[40]u8, c: [3]f32, a: f32) []const u8 {
    const v = rgbOf(c);
    return std.fmt.bufPrint(out, "rgba({d},{d},{d},{d:.3})", .{ (v >> 16) & 0xff, (v >> 8) & 0xff, v & 0xff, a }) catch "transparent";
}

fn applyCss(w: *Widgets, fg: u32, bg: u32, font_px: u32) void {
    if (w.css_fg == fg and w.css_bg == bg and w.css_font_px == font_px) return;
    const css = w.css orelse return;
    w.css_fg = fg;
    w.css_bg = bg;
    w.css_font_px = font_px;
    // The panels' text at the editor font's size, the minis smaller: the
    // sizes macOS and Windows give them (toast ~ the cell, minis 0.75 of it).
    const panel_px: u32 = if (font_px == 0) 13 else @max(12, font_px);
    const mini_px: u32 = if (font_px == 0) 11 else @max(11, font_px * 3 / 4);
    const b = splitRgb(bg);
    const p = core.frontend_rules.panelBg(b[0], b[1], b[2]);
    const rules = core.frontend_rules;
    // With an editor card the sidebar is the card's ground.
    const ground: ?[3]f32 = if (w.card != null) rules.oklabLightnessShifted(b, .island_ground) else null;
    const sb = rules.sidebarPalette(splitRgb(fg), b, ground);
    var buf: [8192]u8 = undefined;
    var fills: [2][40]u8 = undefined;
    // Tone colours as macOS's message panels (ZonvieCore.swift): the text
    // and, where it has one, the border.
    // The strip's buttons drop the theme's look, hover included, so the
    // close and new-tab buttons get their own hover wash, as macOS fills
    // them.
    const text = std.fmt.bufPrintZ(&buf,
        \\.zonvie-panel {{ background-color: {s}; color: #{x:0>6}; font-family: monospace;
        \\  font-size: {d}px; padding: 12px; border-radius: 6px; border: 1px solid alpha(#{x:0>6}, 0.25); }}
        \\.zonvie-panel.zonvie-mini {{ background-color: {s}; font-size: {d}px; padding: 0 8px;
        \\  border: none; border-radius: 0; }}
        \\.zonvie-confirm-prompt {{ min-height: 200px; color: #99ccff; border-color: #4d99ff; }}
        \\.zonvie-toast {{ min-width: 100px; }}
        \\.zonvie-panel.tone-error {{ border-color: #ff4d4d; color: #ff6666; }}
        \\.zonvie-panel.tone-warn {{ border-color: #ffcc4d; color: #ffd966; }}
        \\.zonvie-panel.tone-prompt {{ border-color: #4d99ff; color: #99ccff; }}
        \\.zonvie-panel.tone-search {{ color: #99ff99; }}
        \\window.zonvie-translucent {{ background: transparent; }}
        \\window.zonvie-blur, popover.zonvie-blur {{ backdrop-filter: blur(20px); }}
        \\.zonvie-preedit {{ background-color: #{x:0>6}; color: #{x:0>6}; padding: 0; }}
        \\.zonvie-tabbar button {{ background: none; color: inherit; border-radius: 0; border: none;
        \\  box-shadow: none; padding: 4px 14px; min-height: 0; }}
        \\.zonvie-tab-name {{ padding: 4px 6px 4px 14px; }}
        \\.zonvie-tabbar button.zonvie-tab-close {{ padding: 4px 8px; margin: 2px 4px 0 0; opacity: 0; }}
        \\.zonvie-tab.current button.zonvie-tab-close, .zonvie-tab:hover button.zonvie-tab-close {{ opacity: 0.8; }}
        \\.zonvie-tabbar button.zonvie-tab-close:hover {{ opacity: 1; }}
        \\.zonvie-tabbar button.zonvie-tab-close:hover, .zonvie-tabbar > button:hover {{
        \\  background-color: alpha(currentColor, 0.3); border-radius: 6px; }}
        \\.zonvie-tabbar:not(.sidebar) .zonvie-tab {{ opacity: 0.7; border-radius: 8px 8px 0 0; }}
        \\.zonvie-tabbar:not(.sidebar) .zonvie-tab.current {{ opacity: 1; background-color: alpha(currentColor, 0.12); }}
        \\.zonvie-tabbar:not(.sidebar) .zonvie-tab:hover {{ background-color: alpha(currentColor, 0.08); }}
        \\.zonvie-tabbar .zonvie-tab.dragging {{ opacity: 0.35; }}
        \\.zonvie-drop-line {{ background-color: #{x:0>6}; }}
        \\.zonvie-tab-floating {{ background-color: #{x:0>6}; color: #{x:0>6}; border-radius: 6px; padding: 4px 14px;
        \\  opacity: 0.9; box-shadow: 0 2px 6px rgba(0,0,0,0.35); }}
        \\.zonvie-tabbar.sidebar, .zonvie-sidebar {{ background-color: #{x:0>6}; color: #{x:0>6}; }}
        \\.zonvie-tabbar.sidebar .zonvie-tab {{ min-height: 28px; border-left: 3px solid transparent;
        \\  border-bottom: 1px solid #{x:0>6}; }}
        \\.zonvie-tabbar.sidebar .zonvie-tab:hover {{ background-color: #{x:0>6}; }}
        \\.zonvie-tabbar.sidebar .zonvie-tab.current {{ background-color: #{x:0>6}; color: #{x:0>6};
        \\  border-left-color: #{x:0>6}; }}
        \\.zonvie-tabbar.sidebar .zonvie-tab-name {{ padding: 4px 6px 4px 12px; }}
        \\.zonvie-tabbar.sidebar > button {{ padding: 6px 12px; }}
        \\.zonvie-sidebar-handle {{ box-shadow: inset -1px 0 #{x:0>6}; }}
        \\.zonvie-sidebar.ground .zonvie-sidebar-handle {{ box-shadow: none; }}
        \\.zonvie-agent {{ margin-left: 8px; }}
        \\headerbar.zonvie-header {{ min-height: 0; padding-top: 0; padding-bottom: 0; }}
        \\.zonvie-tab-header > menubutton, .zonvie-tab-header > windowcontrols {{ margin: 2px 4px; }}
        \\.zonvie-band > box > menubutton {{ margin: 0 2px; }}
        \\.zonvie-header.editor-bg {{ background: #{x:0>6}; color: #{x:0>6}; box-shadow: none; border: none; }}
        \\.zonvie-sidebar-rail, .zonvie-menubar {{ padding: 2px; }}
        \\.zonvie-sidebar-rail > button, .zonvie-sidebar-rail > menubutton {{ margin: 2px 0; }}
        \\.zonvie-hover-controls {{ opacity: 0; transition: opacity 150ms; padding: 2px 4px; }}
        \\.zonvie-hover-controls.revealed {{ opacity: 1; }}
        \\.zonvie-drag-bar {{ background-color: alpha(#{x:0>6}, 0.12); }}
        \\button.zonvie-copy {{ min-width: 0; min-height: 0; padding: 0; background: none; border: none;
        \\  box-shadow: none; color: alpha(#{x:0>6}, 0.6); font-size: 12px; }}
        \\button.zonvie-copy:hover {{ color: #{x:0>6}; }}
    , .{
        cssRgba(&fills[0], p, w.panel_alpha), fg, panel_px, fg, cssRgba(&fills[1], b, w.panel_alpha), mini_px, bg, fg,
        rgbOf(sb.indicator), rgbOf(p), fg,
        rgbOf(sb.bg), rgbOf(sb.text), rgbOf(sb.separator), rgbOf(sb.hover), rgbOf(sb.selected), fg, rgbOf(sb.indicator),
        rgbOf(sb.separator),
        bg, fg,
        fg,
        fg, fg,
    }) catch return;
    if (ground) |g| {
        // The card paints nothing under the view, which clears itself at
        // the same alpha: its padding is a border in the bg, and the card's
        // one-pixel edge an outline around that, taken from the margin. The
        // ground is a shadow spread past the holder's corners, which lie
        // sqrt(2) * (margin + radius) from the corner arcs' centres.
        // The tab strip sits on the ground with no line of its own (the
        // theme borders a .sidebar), the current tab in the card's bg and
        // joined to its top edge, clear of the card's corner.
        var c: [3][40]u8 = undefined;
        const card_margin_pt = rules.island_margin_pt;
        const card_radius_pt = rules.island_radius_pt;
        const ground_css = cssRgba(&c[0], g, w.opacity);
        const bg_css = cssRgba(&c[1], b, w.opacity);
        _ = std.fmt.bufPrintZ(buf[text.len..],
            \\.zonvie-card {{ margin: {d}px; border: {d}px solid {s}; outline: 1px solid {s};
            \\  border-radius: {d}px; box-shadow: 0 0 0 {d}px {s}; }}
            \\.zonvie-card.under-tabs {{ margin-top: 1px; }}
            \\.zonvie-tabbar.ground, .zonvie-header.ground, .zonvie-sidebar.ground, .zonvie-sidebar-rail.ground {{ background: {s}; border: none; box-shadow: none; }}
            \\.zonvie-header.ground {{ color: #{x:0>6}; }}
            \\.zonvie-tabbar.ground:not(.sidebar) {{ color: #{x:0>6}; padding-left: {d}px; }}
            \\.zonvie-tabbar.ground:not(.sidebar) .zonvie-tab {{ border-radius: 8px 8px 0 0; }}
            \\.zonvie-tabbar.ground:not(.sidebar) .zonvie-tab.current {{ background-color: {s}; }}
        , .{
            card_margin_pt + 1, rules.island_padding_pt - 1,   bg_css,     cssRgba(&c[2], rules.islandBorder(b), w.opacity),
            card_radius_pt - 1, 2 * (card_margin_pt + card_radius_pt),   ground_css,
            ground_css,    fg, fg,                        tab_strip_inset_pt,
            bg_css,
        }) catch return;
    }
    gtk.gtk_css_provider_load_from_string(css, text.ptr);
}

const copy_glyph = "\u{29c9}";
const copied_glyph = "\u{2713}";
const copied_ms = 800;
const copy_retry_ms = 16;
const copy_tries = 10;

/// Puts each copy button on its panel's trailing edge, where the renderer
/// left room for it, and hides those whose panel is closed. A panel popup
/// holds its own button (panel_popup.zig), placed in the popup; otherwise
/// the button is over the view of the surface its panel is on (the
/// cmdline's the main view, the messages' msg_pos.ext_float's). After every
/// flush: panels open, close and resize there. GTK main thread.
pub fn placeCopyButtons(app: *App) void {
    const w = &app.widgets;
    const msg_host = widgetSurface(app, app.msg_pos.ext_float);
    for (w.copy, 0..) |btn, i| {
        const b = btn orelse continue;
        const kind: overlay_layout.Kind = @enumFromInt(i);
        const host: i64 = if (kind == .cmdline) 1 else msg_host;
        app.mu.lockUncancelable(clock.io());
        const popups = app.panel_popups;
        const scale: i32 = @max(1, @as(i32, @intFromFloat(app.scale)));
        const size = panel_popup.hostSizePx(app, host);
        const box: ?overlay_layout.Rect = blk: {
            if (size[0] == 0 or size[1] == 0) break :blk null;
            const in = gl_renderer.overlayInputs(app, host, size[0], size[1]);
            const r = overlay_layout.place(&app.overlays, in)[i] orelse break :blk null;
            break :blk overlay_layout.copyButtonRect(kind, if (popups) popup_place.frame(r, scale).inner else r, in);
        };
        app.mu.unlock(clock.io());
        // In a panel popup the button travels with the popup.
        if (!popups) rehost(app, b, &w.copy_host[i], host);
        const r = box orelse {
            gtk.gtk_widget_set_visible(b, 0);
            continue;
        };
        gtk.gtk_widget_set_margin_start(b, @divTrunc(r.x, scale));
        gtk.gtk_widget_set_margin_top(b, @divTrunc(r.y, scale));
        gtk.gtk_widget_set_size_request(b, @divTrunc(r.w, scale), @divTrunc(r.h, scale));
        gtk.gtk_widget_set_visible(b, 1);
    }
}

fn onCopyClicked(btn: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    _ = btn;
    const app = the_app orelse return;
    const kind: overlay_layout.Kind = @enumFromInt(@intFromPtr(data) - 1);
    app.widgets.copy_grid = overlay_layout.gridId(kind);
    app.widgets.copy_tries = copy_tries;
    _ = copyAttempt(app);
}

/// The panel's text, as the core's grid holds it, onto the clipboard. A busy
/// grid lock retries a few times (the macOS and Windows rule); the button
/// shows a check only for a copy that happened. GTK main thread.
fn copyAttempt(data: ?*anyopaque) callconv(.c) c_int {
    const app: *App = if (data) |d| @ptrCast(@alignCast(d)) else (the_app orelse return 0);
    const w = &app.widgets;
    const cp = app.corep orelse return 0;
    var stack: [4096]u8 = undefined;
    var heap: ?[]u8 = null;
    defer if (heap) |h| app.alloc.free(h);
    var needed = core.zonvie_core_try_get_grid_text(cp, w.copy_grid, &stack, stack.len - 1);
    var buf: []u8 = &stack;
    if (needed > 0 and @as(usize, @intCast(needed)) > stack.len - 1) {
        heap = app.alloc.alloc(u8, @as(usize, @intCast(needed)) + 1) catch return 0;
        buf = heap.?;
        needed = core.zonvie_core_try_get_grid_text(cp, w.copy_grid, buf.ptr, buf.len - 1);
    }
    if (needed < 0) {
        if (w.copy_tries > 0) {
            w.copy_tries -= 1;
            _ = gtk.g_timeout_add(copy_retry_ms, &copyAttempt, app);
        }
        return 0;
    }
    if (needed == 0) return 0;
    const n: usize = @min(@as(usize, @intCast(needed)), buf.len - 1);
    buf[n] = 0;
    const view = w.overlay orelse return 0;
    const clipboard = gtk.gtk_widget_get_clipboard(view) orelse return 0;
    gtk.gdk_clipboard_set_text(clipboard, @ptrCast(buf.ptr));
    const kind = overlay_layout.kindOf(w.copy_grid) orelse return 0;
    if (w.copy[@intFromEnum(kind)]) |b| {
        gtk.gtk_button_set_label(b, copied_glyph);
        _ = gtk.g_timeout_add(copied_ms, &onCopiedRevert, b);
    }
    return 0;
}

fn onCopiedRevert(data: ?*anyopaque) callconv(.c) c_int {
    gtk.gtk_button_set_label(data.?, copy_glyph);
    return 0;
}

/// The start's progress over the window; hidden once Neovim's first layout
/// is committed (hideProgress). GTK main thread.
pub fn showProgress(app: *App, text: [:0]const u8) void {
    const l = app.widgets.progress orelse return;
    // Before Neovim's first colours: the panel styles exist only once a
    // stylesheet is built, and the theme's text is unreadable on the black
    // view.
    app.mu.lockUncancelable(clock.io());
    const fg = app.default_fg;
    const bg = app.default_bg;
    const font_px: u32 = @intFromFloat(@round(app.preedit_px));
    app.mu.unlock(clock.io());
    applyCss(&app.widgets, fg, bg, font_px);
    gtk.gtk_label_set_text(l, text.ptr);
    gtk.gtk_widget_set_visible(l, 1);
}

pub fn hideProgress(app: *App) void {
    const l = app.widgets.progress orelse return;
    if (gtk.gtk_widget_get_visible(l) != 0) gtk.gtk_widget_set_visible(l, 0);
}

/// Shows `text` (null-terminated) in preedit label `label` with the IME's
/// Pango `attrs` (its underlines and the converting clause) in the editor
/// font, or hides it for an empty one. GTK main thread.
/// A font the composition label draws in: family and logical px.
pub const PreeditFont = struct {
    family: [128]u8 = undefined,
    family_len: usize = 0,
    /// 0: no font.
    px: f32 = 0,

    /// `family` (cut to 128 bytes) at `pixel_size` device px on a `scale`
    /// display. Pre: scale > 0.
    pub fn of(family: []const u8, pixel_size: u32, scale: f32) PreeditFont {
        std.debug.assert(scale > 0);
        var f: PreeditFont = .{ .family_len = @min(family.len, 128), .px = @as(f32, @floatFromInt(pixel_size)) / scale };
        @memcpy(f.family[0..f.family_len], family[0..f.family_len]);
        return f;
    }
};

/// The slot font a composition is drawn in: the cursor grid's own font
/// (`font_id`, 0 for none) while its slot is loaded, as macOS and Windows
/// take the cursor cell's face; null for the editor font.
pub fn preeditSlot(slots: []const PreeditFont, font_id: u32) ?*const PreeditFont {
    if (font_id == 0 or font_id >= slots.len) return null;
    const f = &slots[font_id];
    return if (f.px > 0) f else null;
}

test "a composition takes the cursor grid's loaded slot font, else the editor font" {
    var slots: [4]PreeditFont = @splat(.{});
    slots[2] = PreeditFont.of("Mono", 40, 2);
    try std.testing.expectEqual(@as(f32, 20), preeditSlot(&slots, 2).?.px);
    try std.testing.expectEqualStrings("Mono", preeditSlot(&slots, 2).?.family[0..4]);
    try std.testing.expect(preeditSlot(&slots, 0) == null);
    try std.testing.expect(preeditSlot(&slots, 1) == null);
    try std.testing.expect(preeditSlot(&slots, 9) == null);
}

pub fn showPreedit(app: *App, label_widget: ?*anyopaque, text: [:0]const u8, attrs: ?*anyopaque, at: ?gtk.GdkRectangle) void {
    const l = label_widget orelse return;
    if (text.len == 0) {
        gtk.gtk_widget_set_visible(l, 0);
        return;
    }
    var family: [129]u8 = undefined;
    app.mu.lockUncancelable(clock.io());
    const font_id: u32 = if (app.surface.gridFont(app.surface.committedCursor().grid_id)) |g| g.font_id else 0;
    const slot = preeditSlot(&app.slot_preedit, font_id);
    const n = if (slot) |f| f.family_len else app.preedit_family_len;
    @memcpy(family[0..n], if (slot) |f| f.family[0..n] else app.preedit_family[0..n]);
    const px = if (slot) |f| f.px else app.preedit_px;
    app.mu.unlock(clock.io());
    family[n] = 0;
    // Font first, so the IME's own attributes still apply over it.
    const list = (if (attrs) |a| gtk.pango_attr_list_copy(a) else gtk.pango_attr_list_new()) orelse return;
    defer gtk.pango_attr_list_unref(list);
    if (n != 0) {
        if (gtk.pango_attr_family_new(@ptrCast(&family))) |f| gtk.pango_attr_list_insert_before(list, f);
    }
    if (px > 0) {
        if (gtk.pango_attr_size_new_absolute(@intFromFloat(px * @as(f32, @floatFromInt(gtk.PANGO_SCALE))))) |s| gtk.pango_attr_list_insert_before(list, s);
    }
    gtk.gtk_label_set_text(l, text.ptr);
    gtk.gtk_label_set_attributes(l, list);
    placePreedit(l, at);
    gtk.gtk_widget_set_visible(l, 1);
}

/// Moves preedit label `l` to the cursor cell `at` (logical px of its
/// window's view). GTK main thread.
pub fn placePreedit(l: *anyopaque, at: ?gtk.GdkRectangle) void {
    const r = at orelse return;
    gtk.gtk_widget_set_margin_start(l, @max(0, r.x));
    gtk.gtk_widget_set_margin_top(l, @max(0, r.y));
}

pub fn preeditShown(l: *anyopaque) bool {
    return gtk.gtk_widget_get_visible(l) != 0;
}

/// A preedit label for an external window's view, as build makes the main
/// window's.
pub fn newPreeditLabel() ?*anyopaque {
    const preedit = gtk.gtk_label_new(null) orelse return null;
    gtk.gtk_widget_add_css_class(preedit, "zonvie-preedit");
    gtk.gtk_widget_set_halign(preedit, gtk.GTK_ALIGN_START);
    gtk.gtk_widget_set_valign(preedit, gtk.GTK_ALIGN_START);
    gtk.gtk_widget_set_can_target(preedit, 0);
    gtk.gtk_widget_set_visible(preedit, 0);
    return preedit;
}

fn applyTabline(app: *App, ui: *const ui_state.UiState) void {
    tab_strip.apply(app, ui);
    chrome.applyTabMenu(app, ui);
    // Titlebar tabs sit on the card's top edge.
    if (app.widgets.card) |card| {
        if (ui.tabline_visible and !app.widgets.strip.sidebar and app.widgets.strip.root != null)
            gtk.gtk_widget_add_css_class(card, "under-tabs")
        else
            gtk.gtk_widget_remove_css_class(card, "under-tabs");
    }
}

/// Set once in main before the window exists; tab buttons carry only their
/// index as signal data.
pub var the_app: ?*App = null;
