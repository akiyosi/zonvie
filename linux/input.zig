//! GTK event controllers → core input APIs. GTK main thread only. Every
//! send here enqueues an RPC write; only set/clear_preedit take grid_mu.

const std = @import("std");
const core = @import("zonvie_core");
const clock = core.clock;
const App = @import("app.zig").App;
const gtk = @import("gtk_bindings.zig");
const keymap = @import("keymap.zig");
const transform = @import("transform.zig");
const ui_widgets = @import("ui_widgets.zig");
const scrollbar = @import("scrollbar.zig");
const askpass = @import("askpass.zig");

/// One GLArea's input: the surface its pointer addresses, its IME context
/// and the press it is tracking. The main window's lives in App; each
/// external window owns one.
pub const Pointer = struct {
    app: *App,
    /// 1 for the main window, else the external window's root grid.
    surface_id: i64 = 1,
    im_context: ?*anyopaque = null,
    /// Logical widget px of the last pointer motion; the wheel has no position.
    x: f64 = 0,
    y: f64 = 0,
    /// Button held since a press, and the grid that press chose.
    held_button: ?[*:0]const u8 = null,
    press_grid_id: i64 = 1,
    drag_row: i32 = -1,
    drag_col: i32 = -1,
    /// The scrollbar took the held press; Neovim never saw it.
    bar_held: bool = false,
};

fn ptrFrom(data: ?*anyopaque) *Pointer {
    return @ptrCast(@alignCast(data.?));
}

fn appFrom(data: ?*anyopaque) *App {
    return ptrFrom(data).app;
}

pub fn attach(p: *Pointer, area: *anyopaque) void {
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
    if (gtk.gtk_drop_target_new(gtk.gdk_file_list_get_type(), gtk.GDK_ACTION_COPY)) |drop| {
        _ = gtk.g_signal_connect(drop, "drop", @ptrCast(&onDrop), p);
        gtk.gtk_widget_add_controller(area, drop);
    }
    if (gtk.gtk_event_controller_motion_new()) |motion| {
        _ = gtk.g_signal_connect(motion, "motion", @ptrCast(&onMotion), p);
        _ = gtk.g_signal_connect(motion, "leave", @ptrCast(&onLeave), p);
        gtk.gtk_widget_add_controller(area, motion);
    }
    if (gtk.gtk_event_controller_scroll_new(gtk.GTK_EVENT_CONTROLLER_SCROLL_BOTH_AXES | gtk.GTK_EVENT_CONTROLLER_SCROLL_DISCRETE)) |scroll| {
        _ = gtk.g_signal_connect(scroll, "scroll", @ptrCast(&onScroll), p);
        gtk.gtk_widget_add_controller(area, scroll);
    }
}

// =========================================================================
// Keyboard and IME
// =========================================================================

fn onKeyPressed(ctrl: ?*anyopaque, keyval: c_uint, keycode: c_uint, state: c_uint, data: ?*anyopaque) callconv(.c) c_int {
    _ = ctrl;
    _ = keycode;
    const app = appFrom(data);
    if (keymap.isNewSession(keyval, state)) {
        openNewSession();
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
    core.zonvie_core_send_key_event(cp, code, mods, &buf, @intCast(n), &buf, @intCast(n));
    return 1;
}

/// New Session: another zonvie process showing the connection dialog, as
/// macOS opens a window with it. Its own process, so it has its own nvim,
/// GTK app and single-instance opt-out (`--dialog` never forwards).
fn openNewSession() void {
    var exe: [std.fs.max_path_bytes:0]u8 = undefined;
    const n = std.c.readlink("/proc/self/exe", &exe, exe.len - 1);
    if (n <= 0) return;
    exe[@intCast(n)] = 0;
    const argv = [_:null]?[*:0]const u8{ &exe, "--dialog" };
    // An SSH session marked this process's environment for its askpass
    // children; the new session must start as zonvie, not as a prompt.
    const envp = gtk.g_environ_unsetenv(gtk.g_get_environ(), askpass.env_mode);
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
        app.preedit_active = false;
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
        app.preedit_active = false;
        hidePreedit(p);
        return;
    }
    app.preedit_active = true;
    // No target clause: GTK reports it only through Pango attributes, which
    // the overlay label draws as they are.
    const inline_shown = core.zonvie_core_set_preedit(cp, t.ptr, t.len, 0, 0) != 0;
    // The overlay is the main window's: an external window's composition
    // shows only inline.
    if (p.surface_id != 1) return;
    ui_widgets.showPreedit(app, if (inline_shown) "" else t, attrs, cursorRect(app));
}

fn hidePreedit(p: *Pointer) void {
    if (p.surface_id == 1) ui_widgets.showPreedit(p.app, "", null, null);
}

fn onPreeditEnd(im: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    _ = im;
    const app = appFrom(data);
    hidePreedit(ptrFrom(data));
    if (!app.preedit_active) return;
    app.preedit_active = false;
    if (app.corep) |cp| core.zonvie_core_clear_preedit(cp);
}

fn onFocusIn(ctrl: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    _ = ctrl;
    if (ptrFrom(data).im_context) |im| gtk.gtk_im_context_focus_in(im);
}

fn onFocusOut(ctrl: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    _ = ctrl;
    if (ptrFrom(data).im_context) |im| gtk.gtk_im_context_focus_out(im);
}

/// Places the main window's IME candidate window, and the preedit label when
/// it is up, at the committed cursor.
pub fn updateImeCursor(app: *App) void {
    const im = app.pointer.im_context orelse return;
    const rect = cursorRect(app) orelse return;
    gtk.gtk_im_context_set_cursor_location(im, &rect);
    if (ui_widgets.preeditShown(app)) ui_widgets.placePreedit(app, rect);
}

/// The committed cursor on the main surface, in logical px; null when it is
/// elsewhere.
fn cursorRect(app: *App) ?gtk.GdkRectangle {
    var rect: gtk.GdkRectangle = undefined;
    {
        app.mu.lockUncancelable(clock.io());
        defer app.mu.unlock(clock.io());
        const cur = app.surface.committedCursor();
        if (cur.verts.len == 0) return null;
        const layer = for (app.surface.committedLayers()) |l| {
            if (l.grid_id == cur.grid_id) break l;
        } else return null;
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
        const lx: f32 = @floatFromInt(layer.x_px);
        const ly: f32 = @floatFromInt(layer.y_px);
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
// Mouse and wheel
// =========================================================================

const Cell = struct { grid_id: i64, row: i32, col: i32 };

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

/// On a miss the surface's own root grid takes the position.
fn resolve(p: *Pointer, cp: *core.zonvie_core, x: f64, y: f64, require_scrollable: c_int) ?Cell {
    const app = p.app;
    const c = surfaceCell(app, x, y) orelse return null;
    refreshGrids(app, cp);
    var hit: core.zonvie_pointer_hit = undefined;
    if (core.zonvie_core_resolve_pointer_grid(&app.pointer_grids, app.pointer_grids_len, p.surface_id, c.row, c.col, require_scrollable, &hit) != 0) {
        return .{ .grid_id = hit.grid_id, .row = hit.row, .col = hit.col };
    }
    return .{ .grid_id = p.surface_id, .row = @max(0, c.row), .col = @max(0, c.col) };
}

/// Rebases a surface position into the grid the press chose, so a drag that
/// leaves a float keeps addressing it.
fn inPressGrid(p: *Pointer, x: f64, y: f64) ?Cell {
    const app = p.app;
    const c = surfaceCell(app, x, y) orelse return null;
    for (app.pointer_grids[0..app.pointer_grids_len]) |g| {
        if (g.grid_id != p.press_grid_id or p.press_grid_id == p.surface_id) continue;
        return .{ .grid_id = g.grid_id, .row = c.row - g.start_row, .col = c.col - g.start_col };
    }
    return .{ .grid_id = p.surface_id, .row = @max(0, c.row), .col = @max(0, c.col) };
}

fn buttonName(button: c_uint) ?[*:0]const u8 {
    return switch (button) {
        1 => "left",
        2 => "middle",
        3 => "right",
        8 => "x1",
        9 => "x2",
        else => null,
    };
}

fn onPressed(gesture: ?*anyopaque, n_press: c_int, x: f64, y: f64, data: ?*anyopaque) callconv(.c) void {
    _ = n_press;
    const p = ptrFrom(data);
    const cp = p.app.corep orelse return;
    const button = gtk.gtk_gesture_single_get_current_button(gesture.?);
    if (button == 1 and p.held_button == null and scrollbar.press(p.app, p.surface_id, x, y)) {
        p.bar_held = true;
        return;
    }
    const name = buttonName(button) orelse return;
    const c = resolve(p, cp, x, y, 0) orelse return;
    var mods: [8]u8 = undefined;
    const m = keymap.mouseModString(gtk.gtk_event_controller_get_current_event_state(gesture.?), &mods);
    p.held_button = name;
    p.press_grid_id = c.grid_id;
    p.drag_row = c.row;
    p.drag_col = c.col;
    core.zonvie_core_send_mouse_input(cp, name, "press", m.ptr, c.grid_id, c.row, c.col);
}

fn onReleased(gesture: ?*anyopaque, n_press: c_int, x: f64, y: f64, data: ?*anyopaque) callconv(.c) void {
    _ = n_press;
    const p = ptrFrom(data);
    if (p.bar_held) {
        p.bar_held = false;
        _ = scrollbar.release(p.app, p.surface_id);
        return;
    }
    const cp = p.app.corep orelse return;
    const name = p.held_button orelse return;
    p.held_button = null;
    const c = inPressGrid(p, x, y) orelse return;
    var mods: [8]u8 = undefined;
    const m = keymap.mouseModString(gtk.gtk_event_controller_get_current_event_state(gesture.?), &mods);
    core.zonvie_core_send_mouse_input(cp, name, "release", m.ptr, c.grid_id, c.row, c.col);
}

fn onMotion(ctrl: ?*anyopaque, x: f64, y: f64, data: ?*anyopaque) callconv(.c) void {
    const p = ptrFrom(data);
    p.x = x;
    p.y = y;
    if (scrollbar.motion(p.app, p.surface_id, x, y)) return;
    const name = p.held_button orelse return;
    const cp = p.app.corep orelse return;
    const c = inPressGrid(p, x, y) orelse return;
    if (c.row == p.drag_row and c.col == p.drag_col) return;
    p.drag_row = c.row;
    p.drag_col = c.col;
    var mods: [8]u8 = undefined;
    const m = keymap.mouseModString(gtk.gtk_event_controller_get_current_event_state(ctrl.?), &mods);
    core.zonvie_core_send_mouse_input(cp, name, "drag", m.ptr, c.grid_id, c.row, c.col);
}

/// Files dropped on a surface: their paths typed into the command line while
/// it is up, `:drop`ped otherwise (frontend_rules.dropInsertsPath; the
/// cmdline is drawn in this window, never one of its own).
fn onDrop(target: ?*anyopaque, value: ?*const anyopaque, x: f64, y: f64, data: ?*anyopaque) callconv(.c) c_int {
    _ = target;
    _ = x;
    _ = y;
    const app = appFrom(data);
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
    if (core.frontend_rules.dropInsertsPath(mode, false, false)) {
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

fn onLeave(ctrl: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    _ = ctrl;
    const p = ptrFrom(data);
    scrollbar.leave(p.app, p.surface_id);
}

fn onScroll(ctrl: ?*anyopaque, dx: f64, dy: f64, data: ?*anyopaque) callconv(.c) c_int {
    const p = ptrFrom(data);
    const cp = p.app.corep orelse return 0;
    var mods: [8]u8 = undefined;
    const m = keymap.mouseModString(gtk.gtk_event_controller_get_current_event_state(ctrl.?), &mods);
    if (dy != 0) {
        // Vertical only: a float showing all its lines lets the wheel through.
        const c = resolve(p, cp, p.x, p.y, 1) orelse return 1;
        const dir: [*:0]const u8 = if (dy > 0) "down" else "up";
        sendSteps(cp, c, dir, m.ptr, dy);
    }
    if (dx != 0) {
        const c = resolve(p, cp, p.x, p.y, 0) orelse return 1;
        const dir: [*:0]const u8 = if (dx > 0) "right" else "left";
        sendSteps(cp, c, dir, m.ptr, dx);
    }
    return 1;
}

/// One event per discrete wheel step.
fn sendSteps(cp: *core.zonvie_core, c: Cell, dir: [*:0]const u8, mods: [*:0]const u8, delta: f64) void {
    const steps: u32 = @intFromFloat(@min(16.0, @max(1.0, @round(@abs(delta)))));
    var i: u32 = 0;
    while (i < steps) : (i += 1) core.zonvie_core_send_mouse_scroll(cp, c.grid_id, c.row, c.col, dir, mods);
}
