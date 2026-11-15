//! GTK event controllers → core input APIs. GTK main thread only. Every
//! send here enqueues an RPC write; only set/clear_preedit take grid_mu.

const std = @import("std");
const core = @import("zonvie_core");
const clock = core.clock;
const rules = core.frontend_rules;
const App = @import("app.zig").App;
const gtk = @import("gtk_bindings.zig");
const keymap = @import("keymap.zig");
const chrome = @import("chrome.zig");
const transform = @import("transform.zig");
const layer_geom = @import("layer_geom.zig");
const ui_widgets = @import("ui_widgets.zig");
const scrollbar = @import("scrollbar.zig");
const core_timers = @import("core_timers.zig");
const askpass = @import("askpass.zig");
const cli = @import("cli.zig");
const overlay_layout = @import("overlay_layout.zig");
const gl_renderer = @import("renderer/gl_renderer.zig");
const preedit_target = @import("preedit_target.zig");
const applog = @import("app_log.zig");
const trackpad = @import("trackpad.zig");
const pixel_scroll = @import("pixel_scroll.zig");
const panel_popup = @import("panel_popup.zig");
const popup_place = @import("popup_place.zig");

/// One GLArea's input: the surface its pointer addresses, its IME context
/// and the press it is tracking. The main window's lives in App; each
/// external window owns one.
pub const Pointer = struct {
    app: *App,
    /// 1 for the main window, else the external window's root grid.
    surface_id: i64 = 1,
    /// A panel popup's pointer (panel_popup.zig): surface 1's panel of this
    /// kind only, its positions mapped onto the main view.
    panel: ?overlay_layout.Kind = null,
    im_context: ?*anyopaque = null,
    /// Logical widget px of the last pointer motion; the wheel has no position.
    x: f64 = 0,
    y: f64 = 0,
    /// The buttons held since a press sent to Neovim, and the grid the
    /// claiming press chose.
    claim: rules.PressClaim = .{},
    press_grid_id: i64 = 1,
    drag_row: i32 = -1,
    drag_col: i32 = -1,
    /// The scrollbar took the held press; Neovim never saw it.
    bar_held: bool = false,
    /// The GLArea, for its pointer shape.
    area: ?*anyopaque = null,
    /// An external window's preedit label (the main window's is
    /// App.widgets.preedit).
    preedit_label: ?*anyopaque = null,
    /// The pointer shows the hand: the cell under it holds a URL.
    url_hand: bool = false,
    /// A left press on an ext UI panel, which Neovim never sees.
    panel_press: ?PanelPress = null,
    /// The message grid (-102 / -103) the pointer rests on, 0 for none.
    msg_hover: i64 = 0,
    /// Logical px of the pointer over the overlay panelHover watches (a
    /// popup's: its own area), null while it is elsewhere. Read again after
    /// every flush (refreshPanelHover): a panel opens, moves or closes under
    /// a pointer that sends no motion.
    hover_at: ?[2]f64 = null,
    /// The touchpad gesture and the wheel's fractional steps.
    scroll: trackpad.State = .{},
    /// Latched when a file drag enters: its drop would insert the paths.
    /// The mode cannot change while the drag is held, and motion fires on
    /// every move, so it is not re-read there.
    drag_inserts_path: bool = false,
};

/// A left press held on a panel: on msg_show's close badge (a click
/// dismisses it on release over the badge), or dragging the cmdline or
/// msg_show.
pub const PanelPress = struct {
    kind: overlay_layout.Kind,
    badge: bool,
    /// Logical widget px of the press.
    x: f64,
    y: f64,
    /// The panel at the press, surface px.
    rect: overlay_layout.Rect,
    /// Past the threshold: the panel follows the pointer.
    moved: bool = false,
};

/// Logical px a press must travel before it moves a panel, so a click
/// leaves it (and msg_show's anchor) alone.
const panel_drag_threshold = 3.0;

fn ptrFrom(data: ?*anyopaque) *Pointer {
    return @ptrCast(@alignCast(data.?));
}

fn appFrom(data: ?*anyopaque) *App {
    return ptrFrom(data).app;
}

pub fn attach(p: *Pointer, area: *anyopaque) void {
    p.area = area;
    const im = gtk.gtk_im_multicontext_new() orelse return;
    p.im_context = im;
    gtk.gtk_im_context_set_client_widget(im, area);
    _ = gtk.g_signal_connect(im, "commit", @ptrCast(&onImCommit), p);
    _ = gtk.g_signal_connect(im, "preedit-changed", @ptrCast(&onPreeditChanged), p);
    _ = gtk.g_signal_connect(im, "preedit-end", @ptrCast(&onPreeditEnd), p);

    if (gtk.gtk_event_controller_key_new()) |key| {
        // The controller runs gtk_im_context_filter_keypress itself and
        // emits key-pressed only for keys the IME did not consume.
        gtk.gtk_event_controller_key_set_im_context(key, im);
        _ = gtk.g_signal_connect(key, "key-pressed", @ptrCast(&onKeyPressed), p);
        gtk.gtk_widget_add_controller(area, key);
    }
    if (gtk.gtk_event_controller_focus_new()) |focus| {
        _ = gtk.g_signal_connect(focus, "enter", @ptrCast(&onFocusIn), p);
        _ = gtk.g_signal_connect(focus, "leave", @ptrCast(&onFocusOut), p);
        gtk.gtk_widget_add_controller(area, focus);
    }
    if (gtk.gtk_gesture_click_new()) |click| {
        gtk.gtk_gesture_single_set_button(click, 0);
        _ = gtk.g_signal_connect(click, "pressed", @ptrCast(&onPressed), p);
        _ = gtk.g_signal_connect(click, "released", @ptrCast(&onReleased), p);
        gtk.gtk_widget_add_controller(area, click);
    }
    addDropTarget(p, area);
    if (gtk.gtk_event_controller_motion_new()) |motion| {
        _ = gtk.g_signal_connect(motion, "motion", @ptrCast(&onMotion), p);
        _ = gtk.g_signal_connect(motion, "leave", @ptrCast(&onLeave), p);
        gtk.gtk_widget_add_controller(area, motion);
    }
    // Not DISCRETE: a touchpad's surface px drive trackpad.zig, and a
    // wheel's steps are gathered into whole ones in onScroll.
    if (gtk.gtk_event_controller_scroll_new(gtk.GTK_EVENT_CONTROLLER_SCROLL_BOTH_AXES | gtk.GTK_EVENT_CONTROLLER_SCROLL_KINETIC)) |scroll| {
        _ = gtk.g_signal_connect(scroll, "scroll", @ptrCast(&onScroll), p);
        _ = gtk.g_signal_connect(scroll, "scroll-begin", @ptrCast(&trackpad.onBegin), p);
        _ = gtk.g_signal_connect(scroll, "scroll-end", @ptrCast(&trackpad.onEnd), p);
        _ = gtk.g_signal_connect(scroll, "decelerate", @ptrCast(&trackpad.onDecelerate), p);
        gtk.gtk_widget_add_controller(area, scroll);
    }
}

// =========================================================================
// Keyboard and IME
// =========================================================================

fn onKeyPressed(ctrl: ?*anyopaque, keyval: c_uint, keycode: c_uint, state: c_uint, data: ?*anyopaque) callconv(.c) c_int {
    const p = ptrFrom(data);
    const app = p.app;
    // The keyval with no modifier held, in the event's layout.
    const base_kv = baseKeyval(p, ctrl.?, keycode) orelse keyval;
    if (keymap.appShortcut(base_kv, state, chrome.menuStyle(app))) |sc| {
        chrome.runShortcut(app, sc);
        return 1;
    }
    const cp = app.corep orelse return 0;
    if (keymap.swallowDuringPreedit(app.preedit_active, keyval)) return 1;
    const code = keymap.coreKeycode(keyval);
    const mods = keymap.coreMods(state);
    var buf: [4]u8 = undefined;
    var n: usize = 0;
    const cp_u = keymap.swapColonSemicolon(gtk.gdk_keyval_to_unicode(keyval), app.input_cfg.swap_colon_semicolon);
    if (cp_u != 0) n = std.unicode.utf8Encode(@intCast(cp_u), &buf) catch 0;
    // A bare modifier or dead key: nothing the core can format.
    if (code == 0 and n == 0) return 0;
    // A modified key names its unshifted key (<C-S-2>, not <C-S-@>), as
    // Windows' ToUnicodeEx with the modifiers cleared does.
    var ign: [4]u8 = undefined;
    var ign_n: usize = n;
    @memcpy(ign[0..n], buf[0..n]);
    if (mods & (core.MOD_CTRL | core.MOD_ALT | core.MOD_SUPER) != 0) {
        const base_u = gtk.gdk_keyval_to_unicode(base_kv);
        if (base_u != 0) ign_n = std.unicode.utf8Encode(@intCast(base_u), &ign) catch ign_n;
    }
    core.zonvie_core_send_key_event(cp, code, mods, &buf, @intCast(n), &ign, @intCast(ign_n));
    return 1;
}

/// The keyval `keycode` has with no modifier held, in the event's layout.
fn baseKeyval(p: *Pointer, ctrl: *anyopaque, keycode: c_uint) ?c_uint {
    const event = gtk.gtk_event_controller_get_current_event(ctrl) orelse return null;
    const display = gtk.gtk_widget_get_display(p.area orelse return null) orelse return null;
    var keyval: c_uint = 0;
    if (gtk.gdk_display_translate_key(display, keycode, 0, @intCast(gtk.gdk_key_event_get_layout(event)), &keyval, null, null, null) == 0) return null;
    return keyval;
}

/// New Session: another zonvie process showing the connection dialog, as
/// macOS opens a window with it. Its own process, so it has its own nvim,
/// GTK app and single-instance opt-out (`--dialog` never forwards).
pub fn openNewSession() void {
    var exe: [std.fs.max_path_bytes:0]u8 = undefined;
    const n = std.c.readlink("/proc/self/exe", &exe, exe.len - 1);
    if (n <= 0) return;
    exe[@intCast(n)] = 0;
    const argv = [_:null]?[*:0]const u8{ &exe, "--dialog" };
    // An SSH session pointed this process's environment at zonvie as askpass
    // (cli.setAskpassEnv); the new session must start as zonvie, not as a
    // prompt, and its own ssh children must not call zonvie without the mode.
    var envp = gtk.g_get_environ();
    for (cli.newSessionUnsetEnv(std.c.getenv(askpass.env_mode) != null)) |name| envp = gtk.g_environ_unsetenv(envp, name.ptr);
    defer gtk.g_strfreev(envp);
    // GLib reaps the child itself (no DO_NOT_REAP_CHILD) and gives it
    // /dev/null for stdin, so it never detaches from a terminal again.
    if (gtk.g_spawn_async(null, &argv, envp, 0, &newSessionSetup, null, null, null) == 0)
        std.log.warn("new session: cannot start {s}", .{exe[0..@intCast(n)]});
}

/// In the child before exec: its own session, so closing the terminal this
/// process may run in does not take it down.
fn newSessionSetup(_: ?*anyopaque) callconv(.c) void {
    _ = std.c.setsid();
}

fn onImCommit(im: ?*anyopaque, text: ?[*:0]const u8, data: ?*anyopaque) callconv(.c) void {
    _ = im;
    const app = appFrom(data);
    const cp = app.corep orelse return;
    const t = std.mem.span(text orelse return);
    // Plain typing also arrives here; only a real composition owns an extmark.
    if (app.preedit_active) {
        setComposing(app, false);
        core.zonvie_core_clear_preedit(cp);
        hidePreedit(ptrFrom(data));
    } else if (t.len == 1) {
        // A single character with no composition before it is a keypress:
        // the one place [input] swap_colon_semicolon applies.
        const ch: u8 = @intCast(keymap.swapColonSemicolon(t[0], app.input_cfg.swap_colon_semicolon));
        core.zonvie_core_send_input(cp, &[_]u8{ch}, 1);
        return;
    }
    if (t.len != 0) core.zonvie_core_send_input(cp, t.ptr, t.len);
}

fn onPreeditChanged(im: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const p = ptrFrom(data);
    const app = p.app;
    const cp = app.corep orelse return;
    var str: ?[*:0]u8 = null;
    var attrs: ?*anyopaque = null;
    gtk.gtk_im_context_get_preedit_string(im.?, &str, &attrs, null);
    defer gtk.g_free(str);
    defer gtk.pango_attr_list_unref(attrs);
    const t: [:0]const u8 = if (str) |s| std.mem.span(s) else "";
    if (t.len == 0) {
        if (app.preedit_active) core.zonvie_core_clear_preedit(cp);
        setComposing(app, false);
        hidePreedit(p);
        return;
    }
    setComposing(app, true);
    // The clause being converted, as the IME's Pango attributes mark it; the
    // overlay label draws those attributes as they are.
    const clause = preedit_target.fromPango(attrs, t.len);
    const inline_shown = core.zonvie_core_set_preedit(cp, t.ptr, t.len, clause[0], clause[1]) != 0;
    const target = preeditTarget(p, cursorRect(p));
    hidePreeditExcept(p, target.label);
    ui_widgets.showPreedit(app, target.label, if (inline_shown) "" else t, attrs, target.at);
}

/// The label this window's composition shows in when the core does not
/// draw it inline.
fn preeditLabel(p: *const Pointer) ?*anyopaque {
    return if (p.surface_id == 1) p.app.widgets.preedit else p.preedit_label;
}

/// The label for a composition at the cursor `at` (logical px of `p`'s
/// window), and `at` in that label's overlay: the cmdline popup's while
/// the cursor is in it, since the main view's label would sit under the
/// popup, else the window's own.
fn preeditTarget(p: *const Pointer, at: ?gtk.GdkRectangle) struct { label: ?*anyopaque, at: ?gtk.GdkRectangle } {
    if (p.surface_id == 1) {
        if (at) |r| if (panel_popup.cmdlinePreedit(p.app, r)) |c| return .{ .label = c.label, .at = c.at };
    }
    return .{ .label = preeditLabel(p), .at = at };
}

/// Hides every composition label of `p`'s window but `keep`.
fn hidePreeditExcept(p: *Pointer, keep: ?*anyopaque) void {
    const popup: ?*anyopaque = if (p.surface_id == 1) panel_popup.cmdlinePreeditLabel(p.app) else null;
    for ([_]?*anyopaque{ preeditLabel(p), popup }) |l| {
        if (l != null and l != keep) ui_widgets.showPreedit(p.app, l, "", null, null);
    }
}

fn hidePreedit(p: *Pointer) void {
    hidePreeditExcept(p, null);
}

fn onPreeditEnd(im: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    _ = im;
    const app = appFrom(data);
    hidePreedit(ptrFrom(data));
    if (!app.preedit_active) return;
    setComposing(app, false);
    if (app.corep) |cp| core.zonvie_core_clear_preedit(cp);
}

/// A composition starts or ends. The cmdline panel hides its cursor while
/// one is under way (overlay_layout.panelCursorShown), so a change redraws.
fn setComposing(app: *App, on: bool) void {
    if (app.preedit_active == on) return;
    app.preedit_active = on;
    app.ime_composing.store(on, .release);
    app.queueRenderAll();
}

fn onFocusIn(ctrl: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    _ = ctrl;
    if (ptrFrom(data).im_context) |im| gtk.gtk_im_context_focus_in(im);
}

fn onFocusOut(ctrl: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    _ = ctrl;
    if (ptrFrom(data).im_context) |im| gtk.gtk_im_context_focus_out(im);
}

/// Places the IME candidate window, and the preedit label when it is up, at
/// the committed cursor, on whichever window draws it: the main window (its
/// grids and the ext cmdline panel) or an external one.
pub fn updateImeCursor(app: *App) void {
    placeIme(&app.pointer);
    var it = app.ext_windows.valueIterator();
    while (it.next()) |w| placeIme(&w.*.pointer);
}

fn placeIme(p: *Pointer) void {
    const im = p.im_context orelse return;
    const rect = cursorRect(p) orelse return;
    gtk.gtk_im_context_set_cursor_location(im, &rect);
    const target = preeditTarget(p, rect);
    const label = target.label orelse return;
    if (ui_widgets.preeditShown(label)) ui_widgets.placePreedit(label, target.at);
}

/// `p`'s surface size in device px, as its frames are drawn. GTK main
/// thread (ext_windows); caller holds App.mu.
fn surfaceSizePx(p: *const Pointer) ?[2]u32 {
    const app = p.app;
    if (p.surface_id == 1) return .{ app.drawable_w_px, app.drawable_h_px };
    const w = app.ext_windows.get(p.surface_id) orelse return null;
    return .{ w.gl.w_px, w.gl.h_px };
}

/// The panels drawn on `p`'s surface and what placed them. Caller holds
/// App.mu.
fn surfacePanels(p: *const Pointer) ?struct { rects: [4]?overlay_layout.Rect, in: overlay_layout.Inputs } {
    const app = p.app;
    const sz = surfaceSizePx(p) orelse return null;
    if (sz[0] == 0 or app.cell_w_px == 0 or app.cell_h_px == 0) return null;
    const in = gl_renderer.overlayInputs(app, p.surface_id, sz[0], sz[1]);
    var rects = overlay_layout.place(&app.overlays, in);
    // A popup's panel is where the compositor put the popup; none while it
    // is hidden. On any surface: a panel hangs from the surface it is placed
    // on (panel_popup.hostSurface).
    if (app.panel_popups) {
        for (&rects, 0..) |*r, i| {
            if (r.* != null) r.* = panel_popup.panelRect(app, @enumFromInt(i), in.scale);
        }
    }
    return .{ .rects = rects, .in = in };
}

/// Where the cursor grid's layer sits on `p`'s surface, surface px: a layer
/// of the surface, or a grid drawn in an ext UI panel there (the cmdline),
/// past the panel's chrome. Null when the surface does not draw the grid.
/// Caller holds App.mu.
fn cursorLayerOrigin(p: *const Pointer, grid_id: i64) ?[2]i32 {
    const app = p.app;
    if (overlay_layout.kindOf(grid_id)) |kind| {
        const panels = surfacePanels(p) orelse return null;
        const in = panels.in;
        const r = panels.rects[@intFromEnum(kind)] orelse return null;
        const layer = for (app.surface.committedSurfaceLayers(grid_id)) |l| {
            if (l.grid_id == grid_id) break l;
        } else return null;
        const o = overlay_layout.contentOrigin(kind, in.scale);
        return .{ r.x + o[0] + layer.x_px, r.y + o[1] + layer.y_px };
    }
    const layer = for (app.surface.committedSurfaceLayers(p.surface_id)) |l| {
        if (l.grid_id == grid_id) break l;
    } else return null;
    return .{ layer.x_px, layer.y_px };
}

/// The committed cursor on `p`'s window, in its logical px; null when it is
/// elsewhere.
fn cursorRect(p: *const Pointer) ?gtk.GdkRectangle {
    const app = p.app;
    var rect: gtk.GdkRectangle = undefined;
    {
        app.mu.lockUncancelable(clock.io());
        defer app.mu.unlock(clock.io());
        const cur = app.surface.committedCursor();
        if (cur.verts.len == 0) return null;
        const origin = cursorLayerOrigin(p, cur.grid_id) orelse return null;
        var x0: f32 = std.math.floatMax(f32);
        var y0: f32 = std.math.floatMax(f32);
        var x1: f32 = -std.math.floatMax(f32);
        var y1: f32 = -std.math.floatMax(f32);
        for (cur.verts) |v| {
            x0 = @min(x0, v.position[0]);
            y0 = @min(y0, v.position[1]);
            x1 = @max(x1, v.position[0]);
            y1 = @max(y1, v.position[1]);
        }
        const s = app.scale;
        const lx: f32 = @floatFromInt(origin[0]);
        const ly: f32 = @floatFromInt(origin[1]);
        rect = .{
            .x = @intFromFloat((x0 + lx) / s),
            .y = @intFromFloat((y0 + ly) / s),
            .width = @intFromFloat(@max(1.0, (x1 - x0) / s)),
            .height = @intFromFloat(@max(1.0, (y1 - y0) / s)),
        };
    }
    return rect;
}

// =========================================================================
// Ext UI panels (overlay_layout): drawn over the main surface, never a
// target of Neovim's mouse
// =========================================================================

/// A main-window position on a panel, surface px, with what placed it.
const PanelHit = struct {
    kind: overlay_layout.Kind,
    rect: overlay_layout.Rect,
    in: overlay_layout.Inputs,
    x_px: i32,
    y_px: i32,

    fn onBadge(self: PanelHit) bool {
        const b = overlay_layout.closeBadgeRect(self.kind, self.rect, self.in.scale) orelse return false;
        return overlay_layout.contains(b, self.x_px, self.y_px);
    }

    /// The panel grid's cell under the position.
    fn cell(self: PanelHit) Cell {
        const rc = overlay_layout.panelCell(self.kind, self.rect, self.x_px, self.y_px, self.in);
        return .{ .grid_id = overlay_layout.gridId(self.kind), .row = rc[0], .col = rc[1] };
    }
};

/// The panel at logical widget px (x, y) of `p`'s window (a popup's: of
/// its host surface's view), by the layout its frames are drawn with; null
/// elsewhere.
fn panelAt(p: *const Pointer, x: f64, y: f64) ?PanelHit {
    const app = p.app;
    app.mu.lockUncancelable(clock.io());
    defer app.mu.unlock(clock.io());
    const panels = surfacePanels(p) orelse return null;
    const rects = popup_place.hitRects(panels.rects, app.panel_popups, p.panel);
    const xp: i32 = @intFromFloat(@floor(x * app.scale));
    const yp: i32 = @intFromFloat(@floor(y * app.scale));
    const kind = overlay_layout.hit(&rects, xp, yp) orelse return null;
    return .{ .kind = kind, .rect = rects[@intFromEnum(kind)].?, .in = panels.in, .x_px = xp, .y_px = yp };
}

/// A press on a panel. Every button is swallowed: the core refuses buttons
/// on its own grids (pointer_target.buttonReachesNeovim), and neither macOS
/// nor Windows selects a popupmenu item on a click. A left press with no
/// editor button held may close msg_show by its badge or drag the cmdline or
/// msg_show.
fn pressPanel(p: *Pointer, h: PanelHit, button: c_uint, x: f64, y: f64) void {
    if (button != 1 or p.claim.held_mask != 0 or p.panel_press != null) return;
    const badge = h.onBadge();
    if (!badge and h.kind != .cmdline and h.kind != .msg_show) return;
    p.panel_press = .{ .kind = h.kind, .badge = badge, .x = x, .y = y, .rect = h.rect };
}

/// The left button let go of a panel press: a badge click dismisses
/// msg_show when it ends on the badge too.
fn releasePanel(p: *Pointer, pp: PanelPress, x: f64, y: f64) void {
    if (!pp.badge) return;
    const h = panelAt(p, x, y) orelse return;
    if (h.kind != .msg_show or !h.onBadge()) return;
    const cp = p.app.corep orelse return;
    core.zonvie_core_dismiss_msg_show(cp);
    core_timers.scheduleMsg(p.app);
}

/// Moves the dragged panel with the pointer once it is past the threshold.
/// The first real move pins msg_show until it closes
/// (MsgShowChrome.dragEnded), as Windows' WM_MOVING does; the cmdline keeps
/// its spot for the session.
fn dragPanel(p: *Pointer, pp: *PanelPress, x: f64, y: f64) void {
    const dx = x - pp.x;
    const dy = y - pp.y;
    if (!pp.moved and @abs(dx) < panel_drag_threshold and @abs(dy) < panel_drag_threshold) return;
    pp.moved = true;
    const app = p.app;
    {
        app.mu.lockUncancelable(clock.io());
        defer app.mu.unlock(clock.io());
        var r = pp.rect;
        r.x += @intFromFloat(@round(dx * app.scale));
        r.y += @intFromFloat(@round(dy * app.scale));
        switch (pp.kind) {
            .cmdline => app.cmdline_user = r,
            .msg_show => {
                app.msg_show_user = .{ r.x, r.y };
                app.msg_chrome.dragEnded(true);
            },
            .popupmenu, .msg_history => unreachable,
        }
    }
    app.queueRenderAll();
    // A popup's panel moves by moving the popup.
    panel_popup.update(app);
    ui_widgets.placeCopyButtons(app);
}

/// The pointer over `p`'s view (logical px of the overlay holding its
/// GLArea, the GLArea's too), or gone when null: the message panel it rests
/// on stops its auto-hide countdown (zonvie_core_set_msg_hover) and msg_show
/// shows its close badge. Watched on the overlay rather than the GLArea, so
/// the copy button over a panel still counts as the panel.
fn panelHover(p: *Pointer, at: ?[2]f64) void {
    const app = p.app;
    const h: ?PanelHit = if (at) |pt| panelAt(p, pt[0], pt[1]) else null;
    const grid: i64 = if (h) |v| switch (v.kind) {
        .msg_show, .msg_history => overlay_layout.gridId(v.kind),
        else => 0,
    } else 0;
    const on_show = if (h) |v| v.kind == .msg_show else false;
    const on_badge = if (h) |v| v.onBadge() else false;
    app.mu.lockUncancelable(clock.io());
    const badge_changed = app.msg_chrome.pointer(on_show, on_badge);
    app.mu.unlock(clock.io());
    if (badge_changed) app.queueRenderAll();
    if (grid == p.msg_hover) return;
    const cp = app.corep orelse return;
    if (p.msg_hover != 0) core.zonvie_core_set_msg_hover(cp, p.msg_hover, 0);
    if (grid != 0) core.zonvie_core_set_msg_hover(cp, grid, 1);
    p.msg_hover = grid;
    // What the GUI harness reads the hover from.
    applog.appLog("[msg_hover] surface={d} grid={d}\n", .{ p.surface_id, grid });
    // Both transitions move the earliest deadline (zonvie_core.h).
    core_timers.scheduleMsg(app);
}

fn onPanelMotion(ctrl: ?*anyopaque, x: f64, y: f64, data: ?*anyopaque) callconv(.c) void {
    _ = ctrl;
    const p = ptrFrom(data);
    p.hover_at = .{ x, y };
    panelHover(p, .{ x, y });
}

fn onPanelLeave(ctrl: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    _ = ctrl;
    panelLeft(ptrFrom(data));
}

/// The pointer is off `p`'s view, or the view (a panel popup) was hidden
/// under it, which GTK need not report as a leave.
pub fn panelLeft(p: *Pointer) void {
    p.hover_at = null;
    panelHover(p, null);
}

/// Every pointer's panel hover, again where it rests: a flush can open a
/// message under a still pointer (Windows seeds the hover as it creates a
/// message window) or close the one it held. GTK main thread.
pub fn refreshPanelHover(app: *App) void {
    rehover(&app.pointer);
    var it = app.ext_windows.valueIterator();
    while (it.next()) |w| rehover(&w.*.pointer);
    for (app.popups) |slot| if (slot) |pp| rehover(&pp.pointer);
}

fn rehover(p: *Pointer) void {
    const at = p.hover_at orelse return;
    panelHover(p, if (p.panel != null) popupToView(p, at[0], at[1]) else at);
}

/// Watches the pointer over `overlay`, `p`'s view and the widgets over it,
/// for panelHover.
pub fn attachPanelHover(p: *Pointer, overlay: *anyopaque) void {
    const motion = gtk.gtk_event_controller_motion_new() orelse return;
    // Enter too: a pointer that rests where the view appears sends no motion.
    _ = gtk.g_signal_connect(motion, "enter", @ptrCast(&onPanelMotion), p);
    _ = gtk.g_signal_connect(motion, "motion", @ptrCast(&onPanelMotion), p);
    _ = gtk.g_signal_connect(motion, "leave", @ptrCast(&onPanelLeave), p);
    gtk.gtk_widget_add_controller(overlay, motion);
}

// A panel popup (panel_popup.zig): its pointer sees only its own panel, at
// main-view positions, so the panel code above serves it as it serves the
// main view. Nothing here reaches Neovim's mouse: a press, wheel or hover
// on the popup's shadow margin is swallowed.

/// Logical px of the popup's area (x, y) on the main view. The origin is
/// read per event, so a popup dragged under a still pointer keeps the
/// pointer's view position.
fn popupToView(p: *const Pointer, x: f64, y: f64) [2]f64 {
    const o = panel_popup.viewOrigin(p.app, p.panel.?) orelse return .{ x, y };
    return .{ x + o[0], y + o[1] };
}

/// Watches popup `p`'s `area` and the `overlay` holding it and its copy
/// button. Pre: p.panel != null, p.surface_id == 1.
pub fn attachPopup(p: *Pointer, area: *anyopaque, overlay: *anyopaque) void {
    std.debug.assert(p.panel != null and p.surface_id == 1);
    p.area = area;
    if (gtk.gtk_gesture_click_new()) |click| {
        gtk.gtk_gesture_single_set_button(click, 0);
        _ = gtk.g_signal_connect(click, "pressed", @ptrCast(&onPopupPressed), p);
        _ = gtk.g_signal_connect(click, "released", @ptrCast(&onPopupReleased), p);
        gtk.gtk_widget_add_controller(area, click);
    }
    if (gtk.gtk_event_controller_motion_new()) |motion| {
        _ = gtk.g_signal_connect(motion, "motion", @ptrCast(&onPopupMotion), p);
        gtk.gtk_widget_add_controller(area, motion);
    }
    if (gtk.gtk_event_controller_scroll_new(gtk.GTK_EVENT_CONTROLLER_SCROLL_BOTH_AXES)) |scroll| {
        _ = gtk.g_signal_connect(scroll, "scroll", @ptrCast(&onPopupScroll), p);
        gtk.gtk_widget_add_controller(area, scroll);
    }
    // The popover is not inside the editor view's widget tree, so the
    // view's drop target never sees a drop on it.
    addDropTarget(p, area);
    if (gtk.gtk_event_controller_motion_new()) |motion| {
        // Enter too: a popup shown under a resting pointer gets no motion.
        _ = gtk.g_signal_connect(motion, "enter", @ptrCast(&onPopupHover), p);
        _ = gtk.g_signal_connect(motion, "motion", @ptrCast(&onPopupHover), p);
        _ = gtk.g_signal_connect(motion, "leave", @ptrCast(&onPanelLeave), p);
        gtk.gtk_widget_add_controller(overlay, motion);
    }
}

fn onPopupPressed(gesture: ?*anyopaque, n_press: c_int, x: f64, y: f64, data: ?*anyopaque) callconv(.c) void {
    _ = n_press;
    const p = ptrFrom(data);
    const v = popupToView(p, x, y);
    const h = panelAt(p, v[0], v[1]) orelse return;
    pressPanel(p, h, gtk.gtk_gesture_single_get_current_button(gesture.?), v[0], v[1]);
}

fn onPopupReleased(gesture: ?*anyopaque, n_press: c_int, x: f64, y: f64, data: ?*anyopaque) callconv(.c) void {
    _ = n_press;
    const p = ptrFrom(data);
    if (gtk.gtk_gesture_single_get_current_button(gesture.?) != 1) return;
    const pp = p.panel_press orelse return;
    p.panel_press = null;
    const v = popupToView(p, x, y);
    releasePanel(p, pp, v[0], v[1]);
}

fn onPopupMotion(ctrl: ?*anyopaque, x: f64, y: f64, data: ?*anyopaque) callconv(.c) void {
    _ = ctrl;
    const p = ptrFrom(data);
    const v = popupToView(p, x, y);
    p.x = v[0];
    p.y = v[1];
    if (p.panel_press) |*pp| {
        if (!pp.badge) dragPanel(p, pp, v[0], v[1]);
    }
}

/// The wheel on the panel, as onScroll takes it there; off it, nothing.
fn onPopupScroll(ctrl: ?*anyopaque, dx: f64, dy: f64, data: ?*anyopaque) callconv(.c) c_int {
    const p = ptrFrom(data);
    if (panelAt(p, p.x, p.y) == null) return 1;
    return onScroll(ctrl, dx, dy, data);
}

fn onPopupHover(ctrl: ?*anyopaque, x: f64, y: f64, data: ?*anyopaque) callconv(.c) void {
    _ = ctrl;
    const p = ptrFrom(data);
    p.hover_at = .{ x, y };
    panelHover(p, popupToView(p, x, y));
}

// =========================================================================
// Mouse and wheel
// =========================================================================

pub const Cell = struct { grid_id: i64, row: i32, col: i32 };

fn refreshGrids(app: *App, cp: *core.zonvie_core) void {
    var total: usize = 0;
    const n = core.zonvie_core_try_get_visible_grids_complete(cp, &app.pointer_grids, app.pointer_grids.len, &total);
    if (n >= 0) app.pointer_grids_len = @intCast(n);
}

/// Surface cell under logical widget px (x, y).
fn surfaceCell(app: *App, x: f64, y: f64) ?@TypeOf(transform.pxToCell(0, 0, 1, 1)) {
    app.mu.lockUncancelable(clock.io());
    const cw = app.cell_w_px;
    const ch = app.cell_h_px;
    const s: f64 = app.scale;
    app.mu.unlock(clock.io());
    if (cw == 0 or ch == 0) return null;
    return transform.pxToCell(x * s, y * s, cw, ch);
}

/// The cell logical widget px (x, y) names in `grid_id`, by the core's rule:
/// where the grid's committed layer sits and the sub-row ease the last frame
/// drew it with. Null when the surface has no layer for the grid.
fn gridCell(p: *Pointer, grid_id: i64, x: f64, y: f64) ?Cell {
    const app = p.app;
    // The ext UI grids are overlays this frontend places, not layers.
    if (grid_id <= 0) return null;
    var geom: core.pointer_target.GridGeometry = undefined;
    var local: [2]f32 = undefined;
    var ease_px: f32 = 0;
    {
        app.mu.lockUncancelable(clock.io());
        defer app.mu.unlock(clock.io());
        if (app.cell_w_px == 0 or app.cell_h_px == 0) return null;
        const layer = for (app.surface.committedSurfaceLayers(p.surface_id)) |l| {
            if (l.grid_id == grid_id) break l;
        } else return null;
        const s: f64 = app.scale;
        local = .{
            @floatCast(x * s - @as(f64, @floatFromInt(layer.x_px))),
            @floatCast(y * s - @as(f64, @floatFromInt(layer.y_px))),
        };
        // The grid's own cell and box when it is drawn in its own font, as
        // the painter places it (windows/input.zig gridCellAt).
        const g = layer_geom.Geom.of(layer, app.surface.gridFont(grid_id), app.cell_w_px, app.cell_h_px);
        geom = .{
            .cell_w_px = g.cell_w_px,
            .cell_h_px = g.row_h_px,
            .extent_w_px = g.widthPx(),
            .extent_h_px = g.heightPx(),
            .rows = @intCast(layer.rows),
            .cols = @intCast(layer.cols),
        };
        if (app.surface.gridEase(grid_id)) |e| {
            if (e.easing) ease_px = e.offset_px;
        }
    }
    for (app.pointer_grids[0..app.pointer_grids_len]) |g| {
        if (g.grid_id != grid_id) continue;
        geom.margin_top = g.margin_top;
        geom.margin_bottom = g.margin_bottom;
        break;
    }
    const hit = core.pointer_target.cellInGridEased(local[0], local[1], ease_px, geom);
    return .{ .grid_id = grid_id, .row = hit.row, .col = hit.col };
}

/// The surface's own root grid takes a position no grid claims. Only a drag
/// keeps a cell above or left of its first: Neovim scrolls a drag selection
/// by how far past the edge it is, and "row 0" would stop that scroll.
fn rootCell(p: *Pointer, x: f64, y: f64, allow_negative: bool) ?Cell {
    const c = gridCell(p, p.surface_id, x, y) orelse blk: {
        const sc = surfaceCell(p.app, x, y) orelse return null;
        break :blk Cell{ .grid_id = p.surface_id, .row = sc.row, .col = sc.col };
    };
    if (allow_negative) return c;
    return .{ .grid_id = p.surface_id, .row = @max(0, c.row), .col = @max(0, c.col) };
}

/// On a miss the surface's own root grid takes the position.
pub fn resolve(p: *Pointer, cp: *core.zonvie_core, x: f64, y: f64, require_scrollable: c_int) ?Cell {
    const app = p.app;
    const c = surfaceCell(app, x, y) orelse return null;
    refreshGrids(app, cp);
    var hit: core.zonvie_pointer_hit = undefined;
    if (core.zonvie_core_resolve_pointer_grid(&app.pointer_grids, app.pointer_grids_len, p.surface_id, c.row, c.col, require_scrollable, &hit) != 0) {
        if (hit.grid_id == p.surface_id) return rootCell(p, x, y, false);
        return gridCell(p, hit.grid_id, x, y) orelse .{ .grid_id = hit.grid_id, .row = hit.row, .col = hit.col };
    }
    return rootCell(p, x, y, false);
}

/// Rebases a surface position into the grid the press chose, so a drag that
/// leaves a float keeps addressing it.
fn inPressGrid(p: *Pointer, x: f64, y: f64, allow_negative: bool) ?Cell {
    if (p.press_grid_id != p.surface_id) {
        if (gridCell(p, p.press_grid_id, x, y)) |c| return c;
    }
    return rootCell(p, x, y, allow_negative);
}

/// GTK's button number as PressClaim's (zonvie_core.h) and Neovim's name.
const Button = struct { claim: u8, name: [*:0]const u8 };

fn buttonOf(button: c_uint) ?Button {
    return switch (button) {
        1 => .{ .claim = 1, .name = "left" },
        2 => .{ .claim = 3, .name = "middle" },
        3 => .{ .claim = 2, .name = "right" },
        8 => .{ .claim = 4, .name = "x1" },
        9 => .{ .claim = 5, .name = "x2" },
        else => null,
    };
}

fn claimName(claim: u8) ?[*:0]const u8 {
    return switch (claim) {
        1 => "left",
        2 => "right",
        3 => "middle",
        4 => "x1",
        5 => "x2",
        else => null,
    };
}

fn onPressed(gesture: ?*anyopaque, n_press: c_int, x: f64, y: f64, data: ?*anyopaque) callconv(.c) void {
    _ = n_press;
    const p = ptrFrom(data);
    const cp = p.app.corep orelse return;
    const button = gtk.gtk_gesture_single_get_current_button(gesture.?);
    // The panels draw over the scrollbar and the grids.
    if (panelAt(p, x, y)) |h| return pressPanel(p, h, button, x, y);
    if (button == 1 and p.claim.held_mask == 0 and scrollbar.press(p.app, p.surface_id, x, y)) {
        p.bar_held = true;
        return;
    }
    const b = buttonOf(button) orelse return;
    const c = resolve(p, cp, x, y, 0) orelse return;
    var mods: [5]u8 = undefined;
    const m = keymap.mouseModString(gtk.gtk_event_controller_get_current_event_state(gesture.?), &mods);
    if (p.claim.press(b.claim)) {
        p.press_grid_id = c.grid_id;
        p.drag_row = c.row;
        p.drag_col = c.col;
    }
    core.zonvie_core_send_mouse_input(cp, b.name, "press", m.ptr, c.grid_id, c.row, c.col);
}

fn onReleased(gesture: ?*anyopaque, n_press: c_int, x: f64, y: f64, data: ?*anyopaque) callconv(.c) void {
    _ = n_press;
    const p = ptrFrom(data);
    if (p.bar_held) {
        p.bar_held = false;
        _ = scrollbar.release(p.app, p.surface_id);
        return;
    }
    const button = gtk.gtk_gesture_single_get_current_button(gesture.?);
    if (button == 1) {
        if (p.panel_press) |pp| {
            p.panel_press = null;
            return releasePanel(p, pp, x, y);
        }
    }
    const cp = p.app.corep orelse return;
    const b = buttonOf(button) orelse return;
    // Every sent press gets its release, to the claim's grid.
    if (!p.claim.release(b.claim).send) return;
    const c = inPressGrid(p, x, y, false) orelse return;
    var mods: [5]u8 = undefined;
    const m = keymap.mouseModString(gtk.gtk_event_controller_get_current_event_state(gesture.?), &mods);
    core.zonvie_core_send_mouse_input(cp, b.name, "release", m.ptr, c.grid_id, c.row, c.col);
}

fn onMotion(ctrl: ?*anyopaque, x: f64, y: f64, data: ?*anyopaque) callconv(.c) void {
    const p = ptrFrom(data);
    p.x = x;
    p.y = y;
    if (p.panel_press) |*pp| {
        if (!pp.badge) dragPanel(p, pp, x, y);
        return;
    }
    if (scrollbar.motion(p.app, p.surface_id, x, y)) return showUrlHand(p, false);
    const cp = p.app.corep orelse return;
    const name = claimName(p.claim.owner) orelse return updateUrlHand(p, cp, x, y);
    const c = inPressGrid(p, x, y, true) orelse return;
    if (c.row == p.drag_row and c.col == p.drag_col) return;
    p.drag_row = c.row;
    p.drag_col = c.col;
    var mods: [5]u8 = undefined;
    const m = keymap.mouseModString(gtk.gtk_event_controller_get_current_event_state(ctrl.?), &mods);
    core.zonvie_core_send_mouse_input(cp, name, "drag", m.ptr, c.grid_id, c.row, c.col);
}

/// File drops on `widget`, for `p`'s surface or panel.
fn addDropTarget(p: *Pointer, widget: *anyopaque) void {
    const drop = gtk.gtk_drop_target_new(gtk.gdk_file_list_get_type(), gtk.GDK_ACTION_COPY | gtk.GDK_ACTION_LINK) orelse return;
    _ = gtk.g_signal_connect(drop, "drop", @ptrCast(&onDrop), p);
    _ = gtk.g_signal_connect(drop, "enter", @ptrCast(&onDragEnter), p);
    _ = gtk.g_signal_connect(drop, "motion", @ptrCast(&onDragMotion), p);
    gtk.gtk_widget_add_controller(widget, drop);
}

/// Files dropped on a surface or a panel: their paths typed into the command
/// line while it is up or when dropped on the cmdline panel itself,
/// `:drop`ped otherwise (frontend_rules.dropInsertsPath; on a view the
/// cmdline counts as drawn in that window, never one of its own, since a
/// drop on its popup lands on the popup's own target).
fn onDrop(target: ?*anyopaque, value: ?*const anyopaque, x: f64, y: f64, data: ?*anyopaque) callconv(.c) c_int {
    _ = target;
    _ = x;
    _ = y;
    const p = ptrFrom(data);
    const app = p.app;
    const cp = app.corep orelse return 0;
    const list = gtk.g_value_get_boxed(value orelse return 0) orelse return 0;
    const files = gtk.gdk_file_list_get_files(list);
    defer gtk.g_slist_free(files);

    var arena = std.heap.ArenaAllocator.init(app.alloc);
    defer arena.deinit();
    const a = arena.allocator();
    var paths: std.ArrayListUnmanaged([]const u8) = .empty;
    var node = files;
    while (node) |n| : (node = n.next) {
        const path = gtk.g_file_get_path(n.data orelse continue) orelse continue;
        defer gtk.g_free(path);
        paths.append(a, a.dupe(u8, std.mem.span(path)) catch return 0) catch return 0;
    }
    if (paths.items.len == 0) return 0;

    const mode = std.mem.span(core.zonvie_core_get_current_mode(cp));
    if (core.frontend_rules.dropInsertsPath(mode, false, popup_place.dropForcesInsert(p.panel))) {
        var line: std.ArrayListUnmanaged(u8) = .empty;
        for (paths.items) |path| {
            const buf = a.alloc(u8, 2 * path.len + 1) catch return 0;
            const esc = core.frontend_rules.escapePathForCmdline(buf, path, false) orelse continue;
            if (line.items.len != 0) line.append(a, ' ') catch return 0;
            line.appendSlice(a, esc) catch return 0;
        }
        if (line.items.len != 0) core.zonvie_core_send_input(cp, line.items.ptr, @intCast(line.items.len));
        return 1;
    }
    // Unescaped: the server escapes each with its own fnameescape().
    const ptrs = a.alloc([*]const u8, paths.items.len) catch return 0;
    const lens = a.alloc(usize, paths.items.len) catch return 0;
    for (paths.items, ptrs, lens) |path, *pp, *l| {
        pp.* = path.ptr;
        l.* = path.len;
    }
    core.zonvie_core_drop_paths(cp, ptrs.ptr, lens.ptr, paths.items.len, 0);
    return 1;
}

/// A file drag arrives: whether its drop would insert the paths, read
/// without blocking (a busy core keeps the last answer).
fn onDragEnter(target: ?*anyopaque, x: f64, y: f64, data: ?*anyopaque) callconv(.c) c_uint {
    const p = ptrFrom(data);
    if (p.app.corep) |cp| {
        var mode: [32]u8 = undefined;
        var visible: bool = true;
        if (core.zonvie_core_try_get_mode_state(cp, &mode, mode.len, &visible) == 1)
            p.drag_inserts_path = core.frontend_rules.dropInsertsPath(std.mem.sliceTo(&mode, 0), false, popup_place.dropForcesInsert(p.panel));
    }
    return onDragMotion(target, x, y, data);
}

/// The drag's badge predicts the drop: link while it inserts paths into
/// the command line, copy while it opens the files.
fn onDragMotion(target: ?*anyopaque, x: f64, y: f64, data: ?*anyopaque) callconv(.c) c_uint {
    _ = x;
    _ = y;
    const p = ptrFrom(data);
    const drop = gtk.gtk_drop_target_get_current_drop(target.?) orelse return 0;
    const offered = gtk.gdk_drop_get_actions(drop);
    return switch (core.frontend_rules.dropFeedback(p.drag_inserts_path, offered & gtk.GDK_ACTION_COPY != 0, offered & gtk.GDK_ACTION_LINK != 0)) {
        .none => 0,
        .copy => gtk.GDK_ACTION_COPY,
        .link => gtk.GDK_ACTION_LINK,
    };
}

/// The hand over a cell whose highlight carries a URL, as a click there
/// would name it. A busy core (-1) keeps the last answer.
fn updateUrlHand(p: *Pointer, cp: *core.zonvie_core, x: f64, y: f64) void {
    if (panelAt(p, x, y) != null) return showUrlHand(p, false);
    const c = resolve(p, cp, x, y, 0) orelse return showUrlHand(p, false);
    const has = core.zonvie_core_try_cell_has_url(cp, c.grid_id, c.row, c.col);
    if (has >= 0) showUrlHand(p, has == 1);
}

fn showUrlHand(p: *Pointer, on: bool) void {
    if (p.url_hand == on) return;
    p.url_hand = on;
    const area = p.area orelse return;
    gtk.gtk_widget_set_cursor_from_name(area, if (on) "pointer" else null);
}

fn onLeave(ctrl: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    _ = ctrl;
    const p = ptrFrom(data);
    scrollbar.leave(p.app, p.surface_id);
    showUrlHand(p, false);
}

fn onScroll(ctrl: ?*anyopaque, dx: f64, dy: f64, data: ?*anyopaque) callconv(.c) c_int {
    const p = ptrFrom(data);
    const cp = p.app.corep orelse return 0;
    var mods: [5]u8 = undefined;
    const m = keymap.mouseModString(gtk.gtk_event_controller_get_current_event_state(ctrl.?), &mods);
    const touchpad = gtk.gtk_event_controller_scroll_get_unit(ctrl.?) == gtk.GDK_SCROLL_UNIT_SURFACE;
    if (panelAt(p, p.x, p.y)) |h| {
        // The panel's own grid: the core scrolls a message panel itself and
        // drops the wheel on the cmdline and popupmenu
        // (pointer_target.wheelReachesNeovim), so it never reaches the
        // buffer under them. A touchpad's pixels count a step a line.
        const k: f64 = if (touchpad) 1.0 / panel_step_px else 1.0;
        const py = pixel_scroll.takeSteps(&p.scroll.wheel_y, dy * k);
        const px = pixel_scroll.takeSteps(&p.scroll.wheel_x, dx * k);
        const c = h.cell();
        if (py != 0) sendSteps(cp, c, if (py > 0) "down" else "up", m.ptr, @floatFromInt(py));
        if (px != 0) sendSteps(cp, c, if (px > 0) "right" else "left", m.ptr, @floatFromInt(px));
        core_timers.scheduleMsg(p.app);
        return 1;
    }
    if (touchpad) {
        trackpad.scroll(p, cp, dx, dy, m.ptr);
        core_timers.scheduleMsg(p.app);
        return 1;
    }
    // A high-resolution wheel reports fractions of a step.
    const sy: f64 = @floatFromInt(pixel_scroll.takeSteps(&p.scroll.wheel_y, dy));
    const sx: f64 = @floatFromInt(pixel_scroll.takeSteps(&p.scroll.wheel_x, dx));
    if (sy != 0) {
        // Vertical only: a float showing all its lines lets the wheel through.
        const c = resolve(p, cp, p.x, p.y, 1) orelse return 1;
        const dir: [*:0]const u8 = if (sy > 0) "down" else "up";
        sendSteps(cp, c, dir, m.ptr, sy);
    }
    if (sx != 0) {
        const c = resolve(p, cp, p.x, p.y, 0) orelse return 1;
        const dir: [*:0]const u8 = if (sx > 0) "right" else "left";
        sendSteps(cp, c, dir, m.ptr, sx);
    }
    // A scroll of a message float can be throttled into a message deadline.
    core_timers.scheduleMsg(p.app);
    return 1;
}

/// Touchpad px per wheel step over a message panel: about a text line.
const panel_step_px = 20.0;

/// One event per discrete wheel step.
fn sendSteps(cp: *core.zonvie_core, c: Cell, dir: [*:0]const u8, mods: [*:0]const u8, delta: f64) void {
    const steps: u32 = @intFromFloat(@min(16.0, @max(1.0, @round(@abs(delta)))));
    var i: u32 = 0;
    while (i < steps) : (i += 1) core.zonvie_core_send_mouse_scroll(cp, c.grid_id, c.row, c.col, dir, mods);
}
