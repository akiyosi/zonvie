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

const margin_pt = 10;

pub const Widgets = struct {
    /// The tab strip: `tabs`, then the new-tab button.
    tabbar: ?*anyopaque = null,
    /// One box per tab, equal sizes, so a drag's drop index is the core's
    /// tabDropIndex over them.
    tabs: ?*anyopaque = null,
    /// [tabline] style = "sidebar": the strip runs down one side.
    sidebar: bool = false,
    /// The minis' margins from the view's right and bottom edges, logical px.
    mini_place: [2]c_int = .{ -1, -1 },
    /// Advances the working agents' spinners while any runs.
    spinner_timer: c_uint = 0,
    spinner_frame: u32 = 0,
    /// The tab a drag started on, and where.
    drag_from: ?u32 = null,
    drag_start: [2]f64 = .{ 0, 0 },
    /// Holds the editor view and the boxes over it; the same size as the view.
    overlay: ?*anyopaque = null,
    mini_box: ?*anyopaque = null,
    minis: [4]?*anyopaque = @splat(null),
    confirm: ?*anyopaque = null,
    toast: ?*anyopaque = null,
    /// Copy buttons over the cmdline, msg_show and msg_history panels, by
    /// overlay_layout.Kind; null for the popupmenu.
    copy: [4]?*anyopaque = @splat(null),
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
    /// The tabline the strip was last built from.
    tab_count: usize = 0,
    /// The width sizeTabs last gave each titlebar tab, logical px.
    tab_w: c_int = 0,
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

/// Builds the window content around `area`: a box holding the tab strip
/// (above, or beside it as a [tabline] sidebar) and an overlay whose child is
/// the editor widget. `frames`, when the render thread draws, is the picture
/// showing its frames, layered over `area` and under the message widgets.
/// Returns the box.
pub fn build(app: *App, area: *anyopaque, frames: ?*anyopaque) *anyopaque {
    const w = &app.widgets;
    const cfg = app.tabline_cfg;
    w.sidebar = std.mem.eql(u8, cfg.style, "sidebar");
    const along: c_int = if (w.sidebar) gtk.GTK_ORIENTATION_VERTICAL else gtk.GTK_ORIENTATION_HORIZONTAL;
    const root = gtk.gtk_box_new(if (w.sidebar) gtk.GTK_ORIENTATION_HORIZONTAL else gtk.GTK_ORIENTATION_VERTICAL, 0).?;

    const tabbar = gtk.gtk_box_new(along, 0).?;
    gtk.gtk_widget_add_css_class(tabbar, "zonvie-tabbar");
    if (w.sidebar) gtk.gtk_widget_add_css_class(tabbar, "sidebar");
    gtk.gtk_widget_set_visible(tabbar, 0);
    if (w.sidebar) {
        gtk.gtk_widget_set_size_request(tabbar, @intCast(std.math.clamp(cfg.sidebar_width, 100, 500)), -1);
        // Set, so the tab names' hexpand does not widen it past that.
        gtk.gtk_widget_set_hexpand(tabbar, 0);
    }
    // Equal tabs (dropIndex divides the strip evenly): 100..200 wide along
    // a titlebar (sizeTabs), fixed-height rows down a sidebar, packed from
    // the start with "+" right after them, as macOS and Windows lay them.
    const tabs = gtk.gtk_box_new(along, 0).?;
    gtk.gtk_box_set_homogeneous(tabs, 1);
    // Set, or the names' hexpand would propagate and stretch the tabs.
    gtk.gtk_widget_set_hexpand(tabs, 0);
    gtk.gtk_box_append(tabbar, tabs);
    const plus = gtk.gtk_button_new_with_label("+").?;
    gtk.gtk_widget_set_focusable(plus, 0);
    _ = gtk.g_signal_connect(plus, "clicked", @ptrCast(&onNewTab), null);
    gtk.gtk_box_append(tabbar, plus);
    if (gtk.gtk_gesture_drag_new()) |drag| {
        _ = gtk.g_signal_connect(drag, "drag-begin", @ptrCast(&onTabDragBegin), app);
        _ = gtk.g_signal_connect(drag, "drag-end", @ptrCast(&onTabDragEnd), app);
        gtk.gtk_widget_add_controller(tabs, drag);
    }
    w.tabbar = tabbar;
    w.tabs = tabs;

    const overlay = gtk.gtk_overlay_new().?;
    gtk.gtk_widget_set_vexpand(overlay, 1);
    gtk.gtk_widget_set_hexpand(overlay, 1);
    gtk.gtk_overlay_set_child(overlay, area);
    w.overlay = overlay;
    if (frames) |f| gtk.gtk_overlay_add_overlay(overlay, f);
    const right = w.sidebar and std.mem.eql(u8, cfg.sidebar_position, "right");
    if (!right) gtk.gtk_box_append(root, tabbar);
    gtk.gtk_box_append(root, overlay);
    if (right) gtk.gtk_box_append(root, tabbar);

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
    gtk.gtk_widget_set_valign(confirm, gtk.GTK_ALIGN_CENTER);
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

    const preedit = gtk.gtk_label_new(null).?;
    gtk.gtk_widget_add_css_class(preedit, "zonvie-preedit");
    gtk.gtk_widget_set_halign(preedit, gtk.GTK_ALIGN_START);
    gtk.gtk_widget_set_valign(preedit, gtk.GTK_ALIGN_START);
    gtk.gtk_widget_set_can_target(preedit, 0);
    gtk.gtk_widget_set_visible(preedit, 0);
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
    if (snap.ui.notice_pending) sendNotification(app, null, "Neovim", snap.ui.notice.text());
}

/// One OS notification through the desktop's notification service. A null
/// `id` makes each its own entry, as macOS posts each message; an id
/// replaces the last one sent with it.
fn sendNotification(app: *App, id: ?[*:0]const u8, title: [*:0]const u8, body: []const u8) void {
    const gapp = app.gtk_app orelse return;
    var z: [1025]u8 = undefined;
    const n = @min(body.len, z.len - 1);
    @memcpy(z[0..n], body[0..n]);
    z[n] = 0;
    const note = gtk.g_notification_new(title) orelse return;
    defer gtk.g_object_unref(note);
    gtk.g_notification_set_body(note, @ptrCast(&z));
    gtk.g_application_send_notification(gapp, id, note);
}

/// The OS notification for agent completions ([tabline] agent_notification),
/// sent always: the agent runs in this app's own terminal, so focus says
/// nothing about whether the user saw it.
fn notifyCompletions(app: *App, done: []const ui_state.Completion) void {
    var buf: [320]u8 = undefined;
    const msg = ui_state.completionMessage(buf[0 .. buf.len - 1], done);
    sendNotification(app, "agent", "Zonvie", msg);
}

const claude_frames = [_][:0]const u8{ "·", "✢", "✳", "✶", "✻", "✽" };
const braille_frames = [_][:0]const u8{ "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" };
const spinner_interval_ms = 120;

/// The per-tab indicator for an agent state: 🤖 done, ⏸ waiting for input,
/// a spinner while working, as Windows draws them.
fn indicatorGlyph(state: u8, frame: u32) [:0]const u8 {
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
    const w = &app.widgets;
    if (!app.tabline_cfg.agent_indicator) return;
    var child = if (w.tabs) |t| gtk.gtk_widget_get_first_child(t) else null;
    for (ui.tabs[0..ui.tab_count]) |t| {
        const tab = child orelse break;
        child = gtk.gtk_widget_get_next_sibling(tab);
        const ind = gtk.gtk_widget_get_first_child(tab) orelse continue;
        const glyph = indicatorGlyph(ui.agentState(t.handle), w.spinner_frame);
        gtk.gtk_label_set_text(ind, glyph.ptr);
        gtk.gtk_widget_set_visible(ind, @intFromBool(glyph.len != 0));
    }
    const working = ui.anyWorking();
    if (working and w.spinner_timer == 0) {
        w.spinner_timer = gtk.g_timeout_add(spinner_interval_ms, &onSpinner, app);
    } else if (!working and w.spinner_timer != 0) {
        _ = gtk.g_source_remove(w.spinner_timer);
        w.spinner_timer = 0;
    }
}

fn onSpinner(data: ?*anyopaque) callconv(.c) c_int {
    const app: *App = @ptrCast(@alignCast(data.?));
    app.widgets.spinner_frame +%= 1;
    applyIndicators(app, &app.ui_snapshot.ui);
    // applyIndicators keeps the timer while anything works.
    return @intFromBool(app.widgets.spinner_timer != 0);
}

/// Hangs the toast from the top-right of msg_pos.ext_float's target and the
/// minis from the bottom-right of msg_pos.mini's (overlay_layout.msgTarget),
/// as macOS and Windows place them. Rerun after each flush: the cursor's
/// window moves the targets. GTK main thread.
pub fn placeMessages(app: *App) void {
    const w = &app.widgets;
    // A resize reaches here through the flush it causes.
    sizeTabs(app);
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
        const r = overlay_layout.msgTarget(pos.ext_float, anchor, vw, vh, cw, ch);
        gtk.gtk_widget_set_margin_top(t, @divTrunc(r.top, scale) + m);
        gtk.gtk_widget_set_margin_end(t, @divTrunc(vw - r.right, scale) + m);
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
            // Centred in the view (halign/valign), at its natural size.
            var nat: gtk.GtkRequisition = .{};
            gtk.gtk_widget_get_preferred_size(c, null, &nat);
            confirm_rect = .{
                .x = @divTrunc(view_w - nat.width, 2) * scale,
                .y = @divTrunc(view_h - nat.height, 2) * scale,
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
        const r = overlay_layout.msgTarget(pos.mini, anchor, vw, vh, cw, ch);
        const place: [2]c_int = .{ @divTrunc(vw - r.right, scale) + m, @divTrunc(vh - r.bottom, scale) + m };
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
    const panel = rgbOf(p);
    const sb = core.frontend_rules.sidebarPalette(splitRgb(fg), b, null);
    var buf: [4096]u8 = undefined;
    // Tone colours as macOS's message panels (ZonvieCore.swift): the text
    // and, where it has one, the border.
    const text = std.fmt.bufPrintZ(&buf,
        \\.zonvie-panel {{ background-color: #{x:0>6}; color: #{x:0>6}; font-family: monospace;
        \\  font-size: {d}px; padding: 12px; border-radius: 6px; border: 1px solid alpha(#{x:0>6}, 0.25); }}
        \\.zonvie-panel.zonvie-mini {{ background-color: #{x:0>6}; font-size: {d}px; padding: 0 8px;
        \\  border: none; border-radius: 0; }}
        \\.zonvie-confirm-prompt {{ min-height: 200px; color: #99ccff; border-color: #4d99ff; }}
        \\.zonvie-toast {{ min-width: 100px; }}
        \\.zonvie-panel.tone-error {{ border-color: #ff4d4d; color: #ff6666; }}
        \\.zonvie-panel.tone-warn {{ border-color: #ffcc4d; color: #ffd966; }}
        \\.zonvie-panel.tone-prompt {{ border-color: #4d99ff; color: #99ccff; }}
        \\.zonvie-panel.tone-search {{ color: #99ff99; }}
        \\window.zonvie-translucent {{ background: transparent; }}
        \\.zonvie-preedit {{ background-color: #{x:0>6}; color: #{x:0>6}; padding: 0; }}
        \\.zonvie-tabbar button {{ background: none; color: inherit; border-radius: 0; border: none;
        \\  box-shadow: none; padding: 4px 14px; }}
        \\.zonvie-tabbar button.zonvie-tab-close {{ padding: 4px 8px; opacity: 0; }}
        \\.zonvie-tab.current button.zonvie-tab-close, .zonvie-tab:hover button.zonvie-tab-close {{ opacity: 0.8; }}
        \\.zonvie-tabbar:not(.sidebar) .zonvie-tab {{ opacity: 0.7; }}
        \\.zonvie-tabbar:not(.sidebar) .zonvie-tab.current {{ opacity: 1; background-color: alpha(currentColor, 0.12); }}
        \\.zonvie-tabbar:not(.sidebar) .zonvie-tab:hover {{ background-color: alpha(currentColor, 0.08); }}
        \\.zonvie-tabbar.sidebar {{ background-color: #{x:0>6}; color: #{x:0>6}; }}
        \\.zonvie-tabbar.sidebar .zonvie-tab {{ min-height: 28px; border-left: 3px solid transparent;
        \\  border-bottom: 1px solid #{x:0>6}; }}
        \\.zonvie-tabbar.sidebar .zonvie-tab:hover {{ background-color: #{x:0>6}; }}
        \\.zonvie-tabbar.sidebar .zonvie-tab.current {{ background-color: #{x:0>6}; color: #{x:0>6};
        \\  border-left-color: #{x:0>6}; }}
        \\.zonvie-tabbar.sidebar button {{ padding: 4px 12px; }}
        \\.zonvie-agent {{ margin-left: 8px; }}
        \\button.zonvie-copy {{ min-width: 0; min-height: 0; padding: 0; background: none; border: none;
        \\  box-shadow: none; color: alpha(#{x:0>6}, 0.6); font-size: 12px; }}
        \\button.zonvie-copy:hover {{ color: #{x:0>6}; }}
    , .{ panel, fg, panel_px, fg, bg, mini_px, bg, fg, rgbOf(sb.bg), rgbOf(sb.text), rgbOf(sb.separator), rgbOf(sb.hover), rgbOf(sb.selected), fg, rgbOf(sb.indicator), fg, fg }) catch return;
    gtk.gtk_css_provider_load_from_string(css, text.ptr);
}

const copy_glyph = "\u{29c9}";
const copied_glyph = "\u{2713}";
const copied_ms = 800;
const copy_retry_ms = 16;
const copy_tries = 10;

/// Puts each copy button on its panel's trailing edge, where the renderer
/// left room for it, and hides those whose panel is closed. After every
/// flush: panels open, close and resize there. GTK main thread.
pub fn placeCopyButtons(app: *App) void {
    const w = &app.widgets;
    const view = w.overlay orelse return;
    const vw = gtk.gtk_widget_get_width(view);
    const vh = gtk.gtk_widget_get_height(view);
    if (vw <= 0 or vh <= 0) return;
    app.mu.lockUncancelable(clock.io());
    const scale: i32 = @max(1, @as(i32, @intFromFloat(app.scale)));
    const in = gl_renderer.overlayInputs(app, @intCast(vw * scale), @intCast(vh * scale));
    const rects = overlay_layout.place(&app.overlays, in);
    app.mu.unlock(clock.io());
    for (w.copy, 0..) |btn, i| {
        const b = btn orelse continue;
        const kind: overlay_layout.Kind = @enumFromInt(i);
        const box = if (rects[i]) |r| overlay_layout.copyButtonRect(kind, r, in) else null;
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

/// Shows `text` (null-terminated) with the IME's Pango `attrs` (its
/// underlines and the converting clause) in the editor font, or hides the
/// label for an empty one. GTK main thread.
pub fn showPreedit(app: *App, text: [:0]const u8, attrs: ?*anyopaque, at: ?gtk.GdkRectangle) void {
    const l = app.widgets.preedit orelse return;
    if (text.len == 0) {
        gtk.gtk_widget_set_visible(l, 0);
        return;
    }
    var family: [129]u8 = undefined;
    app.mu.lockUncancelable(clock.io());
    const n = app.preedit_family_len;
    @memcpy(family[0..n], app.preedit_family[0..n]);
    const px = app.preedit_px;
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
    placePreedit(app, at);
    gtk.gtk_widget_set_visible(l, 1);
}

/// Moves the preedit label to the cursor cell `at` (logical px), when it is
/// up. GTK main thread.
pub fn placePreedit(app: *App, at: ?gtk.GdkRectangle) void {
    const l = app.widgets.preedit orelse return;
    const r = at orelse return;
    gtk.gtk_widget_set_margin_start(l, @max(0, r.x));
    gtk.gtk_widget_set_margin_top(l, @max(0, r.y));
}

pub fn preeditShown(app: *const App) bool {
    const l = app.widgets.preedit orelse return false;
    return gtk.gtk_widget_get_visible(l) != 0;
}

fn applyTabline(app: *App, ui: *const ui_state.UiState) void {
    const w = &app.widgets;
    const bar = w.tabbar orelse return;
    const tabs = w.tabs orelse return;
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
        var child = gtk.gtk_widget_get_first_child(tabs);
        for (ui.tabs[0..ui.tab_count]) |t| {
            const tab = child orelse break;
            // Children: indicator, name, close.
            const ind = gtk.gtk_widget_get_first_child(tab);
            if (ind) |i| if (gtk.gtk_widget_get_next_sibling(i)) |name_btn| setButtonLabel(app, name_btn, t.name.text());
            child = gtk.gtk_widget_get_next_sibling(tab);
        }
        applyIndicators(app, ui);
        return;
    }
    while (gtk.gtk_widget_get_first_child(tabs)) |c| gtk.gtk_box_remove(tabs, c);
    w.tab_count = ui.tab_count;
    w.curtab = ui.curtab;
    for (ui.tabs[0..ui.tab_count], 0..) |t, i| {
        w.tab_handles[i] = t.handle;
        const tab = gtk.gtk_box_new(gtk.GTK_ORIENTATION_HORIZONTAL, 0) orelse continue;
        gtk.gtk_widget_add_css_class(tab, "zonvie-tab");
        if (t.handle == ui.curtab) gtk.gtk_widget_add_css_class(tab, "current");
        const ind = gtk.gtk_label_new(null) orelse continue;
        gtk.gtk_widget_add_css_class(ind, "zonvie-agent");
        gtk.gtk_widget_set_visible(ind, 0);
        gtk.gtk_box_append(tab, ind);
        // Signal data is the 1-based tab number: the strip is rebuilt
        // whenever the list changes, so it never outlives its tab.
        const name_btn = gtk.gtk_button_new_with_label("") orelse continue;
        setButtonLabel(app, name_btn, t.name.text());
        if (gtk.gtk_button_get_child(name_btn)) |l| gtk.gtk_label_set_ellipsize(l, gtk.PANGO_ELLIPSIZE_END);
        gtk.gtk_widget_set_focusable(name_btn, 0);
        gtk.gtk_widget_set_hexpand(name_btn, 1);
        _ = gtk.g_signal_connect(name_btn, "clicked", @ptrCast(&onTabClicked), @ptrFromInt(i + 1));
        gtk.gtk_box_append(tab, name_btn);
        const close = gtk.gtk_button_new_with_label("\u{00d7}") orelse continue;
        gtk.gtk_widget_add_css_class(close, "zonvie-tab-close");
        gtk.gtk_widget_set_focusable(close, 0);
        _ = gtk.g_signal_connect(close, "clicked", @ptrCast(&onTabClose), @ptrFromInt(i + 1));
        gtk.gtk_box_append(tab, close);
        gtk.gtk_box_append(tabs, tab);
    }
    w.tab_w = 0;
    sizeTabs(app);
    applyIndicators(app, ui);
}

/// A titlebar tab's width: the strip shared out within the shared bounds.
/// Rerun when the strip's width may have changed.
fn sizeTabs(app: *App) void {
    const w = &app.widgets;
    if (w.sidebar or w.tab_count == 0) return;
    const bar = w.tabbar orelse return;
    const tabs = w.tabs orelse return;
    const plus_w: c_int = 40;
    const avail = gtk.gtk_widget_get_width(bar) - plus_w;
    const rules = core.frontend_rules;
    const tw: c_int = rules.titlebarTabWidth(avail, @intCast(w.tab_count), rules.tab_min_width_pt, rules.tab_max_width_pt);
    if (tw == w.tab_w) return;
    w.tab_w = tw;
    var child = gtk.gtk_widget_get_first_child(tabs);
    while (child) |c| : (child = gtk.gtk_widget_get_next_sibling(c)) gtk.gtk_widget_set_size_request(c, tw, -1);
}

fn setButtonLabel(app: *App, btn: *anyopaque, name: []const u8) void {
    const buf = &app.ui_text_scratch;
    const text = if (name.len == 0) "[No Name]" else name;
    const n = @min(text.len, 255);
    @memcpy(buf[0..n], text[0..n]);
    buf[n] = 0;
    gtk.gtk_button_set_label(btn, @ptrCast(buf.ptr));
}

fn sendCommand(cmd: []const u8) void {
    const app = the_app orelse return;
    const cp = app.corep orelse return;
    core.zonvie_core_send_command(cp, cmd.ptr, cmd.len);
    if (app.gl_area) |a| _ = gtk.gtk_widget_grab_focus(a);
}

fn onTabClicked(btn: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    _ = btn;
    var buf: [32]u8 = undefined;
    sendCommand(std.fmt.bufPrint(&buf, "{d}tabnext", .{@intFromPtr(data)}) catch return);
}

fn onTabClose(btn: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    _ = btn;
    var buf: [32]u8 = undefined;
    sendCommand(std.fmt.bufPrint(&buf, "{d}tabclose", .{@intFromPtr(data)}) catch return);
}

fn onNewTab(btn: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    _ = btn;
    _ = data;
    sendCommand("tabnew");
}

/// Logical px a press must travel before it is a drag, not a click.
const drag_threshold = 8;

/// The tab under `pos` along the strip, by the core's rule.
fn dropIndex(w: *const Widgets, pos: f64) u32 {
    const tabs = w.tabs orelse return 0;
    const count: u32 = @intCast(w.tab_count);
    if (count == 0) return 0;
    const len: f64 = @floatFromInt(if (w.sidebar) gtk.gtk_widget_get_height(tabs) else gtk.gtk_widget_get_width(tabs));
    const stride = len / @as(f64, @floatFromInt(count));
    return core.frontend_rules.tabDropIndex(pos, count, 0, stride, stride);
}

fn onTabDragBegin(gesture: ?*anyopaque, x: f64, y: f64, data: ?*anyopaque) callconv(.c) void {
    _ = gesture;
    const app: *App = @ptrCast(@alignCast(data.?));
    const w = &app.widgets;
    w.drag_start = .{ x, y };
    const pos = if (w.sidebar) y else x;
    // The tab containing the press.
    const count: u32 = @intCast(w.tab_count);
    const len: f64 = @floatFromInt(if (w.sidebar) gtk.gtk_widget_get_height(w.tabs.?) else gtk.gtk_widget_get_width(w.tabs.?));
    const stride = if (count == 0) 0 else len / @as(f64, @floatFromInt(count));
    const under: u32 = if (stride > 0) @intFromFloat(@floor(pos / stride)) else 0;
    w.drag_from = if (under < count) under else null;
}

fn onTabDragEnd(gesture: ?*anyopaque, dx: f64, dy: f64, data: ?*anyopaque) callconv(.c) void {
    _ = gesture;
    const app: *App = @ptrCast(@alignCast(data.?));
    const w = &app.widgets;
    const from = w.drag_from orelse return;
    w.drag_from = null;
    const moved = if (w.sidebar) dy else dx;
    if (@abs(moved) < drag_threshold) return;
    const pos = (if (w.sidebar) w.drag_start[1] else w.drag_start[0]) + moved;
    const cp = app.corep orelse return;
    // Selects the dragged tab and moves it in one command; nothing for a
    // drop onto its own slot.
    _ = core.zonvie_core_tab_move(cp, from, dropIndex(w, pos), @intCast(w.tab_count));
}

/// Set once in main before the window exists; tab buttons carry only their
/// index as signal data.
pub var the_app: ?*App = null;
