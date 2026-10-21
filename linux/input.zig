//! GTK event controllers → core input APIs. GTK main thread only. Every
//! send here enqueues an RPC write; only set/clear_preedit take grid_mu.

const std = @import("std");
const core = @import("zonvie_core");
const clock = core.clock;
const App = @import("app.zig").App;
const gtk = @import("gtk_bindings.zig");
const keymap = @import("keymap.zig");
const transform = @import("transform.zig");

fn appFrom(data: ?*anyopaque) *App {
    return @ptrCast(@alignCast(data.?));
}

pub fn attach(app: *App, area: *anyopaque) void {
    const im = gtk.gtk_im_multicontext_new() orelse return;
    app.im_context = im;
    gtk.gtk_im_context_set_client_widget(im, area);
    _ = gtk.g_signal_connect(im, "commit", @ptrCast(&onImCommit), app);
    _ = gtk.g_signal_connect(im, "preedit-changed", @ptrCast(&onPreeditChanged), app);
    _ = gtk.g_signal_connect(im, "preedit-end", @ptrCast(&onPreeditEnd), app);

    if (gtk.gtk_event_controller_key_new()) |key| {
        // The controller runs gtk_im_context_filter_keypress itself and
        // emits key-pressed only for keys the IME did not consume.
        gtk.gtk_event_controller_key_set_im_context(key, im);
        _ = gtk.g_signal_connect(key, "key-pressed", @ptrCast(&onKeyPressed), app);
        gtk.gtk_widget_add_controller(area, key);
    }
    if (gtk.gtk_event_controller_focus_new()) |focus| {
        _ = gtk.g_signal_connect(focus, "enter", @ptrCast(&onFocusIn), app);
        _ = gtk.g_signal_connect(focus, "leave", @ptrCast(&onFocusOut), app);
        gtk.gtk_widget_add_controller(area, focus);
    }
    if (gtk.gtk_gesture_click_new()) |click| {
        gtk.gtk_gesture_single_set_button(click, 0);
        _ = gtk.g_signal_connect(click, "pressed", @ptrCast(&onPressed), app);
        _ = gtk.g_signal_connect(click, "released", @ptrCast(&onReleased), app);
        gtk.gtk_widget_add_controller(area, click);
    }
    if (gtk.gtk_event_controller_motion_new()) |motion| {
        _ = gtk.g_signal_connect(motion, "motion", @ptrCast(&onMotion), app);
        gtk.gtk_widget_add_controller(area, motion);
    }
    if (gtk.gtk_event_controller_scroll_new(gtk.GTK_EVENT_CONTROLLER_SCROLL_BOTH_AXES | gtk.GTK_EVENT_CONTROLLER_SCROLL_DISCRETE)) |scroll| {
        _ = gtk.g_signal_connect(scroll, "scroll", @ptrCast(&onScroll), app);
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
    const cp = app.corep orelse return 0;
    if (keymap.swallowDuringPreedit(app.preedit_active, keyval)) return 1;
    const code = keymap.coreKeycode(keyval);
    const mods = keymap.coreMods(state);
    var buf: [4]u8 = undefined;
    var n: usize = 0;
    const cp_u = gtk.gdk_keyval_to_unicode(keyval);
    if (cp_u != 0) n = std.unicode.utf8Encode(@intCast(cp_u), &buf) catch 0;
    // A bare modifier or dead key: nothing the core can format.
    if (code == 0 and n == 0) return 0;
    core.zonvie_core_send_key_event(cp, code, mods, &buf, @intCast(n), &buf, @intCast(n));
    return 1;
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
    }
    if (t.len != 0) core.zonvie_core_send_input(cp, t.ptr, t.len);
}

fn onPreeditChanged(im: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const app = appFrom(data);
    const cp = app.corep orelse return;
    var str: ?[*:0]u8 = null;
    gtk.gtk_im_context_get_preedit_string(im.?, &str, null, null);
    defer gtk.g_free(str);
    const t: []const u8 = if (str) |s| std.mem.span(s) else "";
    if (t.len == 0) {
        if (app.preedit_active) core.zonvie_core_clear_preedit(cp);
        app.preedit_active = false;
        return;
    }
    app.preedit_active = true;
    // No target clause: GTK reports it only through Pango attributes.
    _ = core.zonvie_core_set_preedit(cp, t.ptr, t.len, 0, 0);
}

fn onPreeditEnd(im: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    _ = im;
    const app = appFrom(data);
    if (!app.preedit_active) return;
    app.preedit_active = false;
    if (app.corep) |cp| core.zonvie_core_clear_preedit(cp);
}

fn onFocusIn(ctrl: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    _ = ctrl;
    if (appFrom(data).im_context) |im| gtk.gtk_im_context_focus_in(im);
}

fn onFocusOut(ctrl: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    _ = ctrl;
    if (appFrom(data).im_context) |im| gtk.gtk_im_context_focus_out(im);
}

/// Places the IME candidate window at the committed cursor, in logical px.
pub fn updateImeCursor(app: *App) void {
    const im = app.im_context orelse return;
    var rect: gtk.GdkRectangle = undefined;
    {
        app.mu.lockUncancelable(clock.io());
        defer app.mu.unlock(clock.io());
        const cur = app.surface.committedCursor();
        if (cur.verts.len == 0) return;
        const layer = for (app.surface.committedLayers()) |l| {
            if (l.grid_id == cur.grid_id) break l;
        } else return;
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
    gtk.gtk_im_context_set_cursor_location(im, &rect);
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

fn resolve(app: *App, cp: *core.zonvie_core, x: f64, y: f64, require_scrollable: c_int) ?Cell {
    const c = surfaceCell(app, x, y) orelse return null;
    refreshGrids(app, cp);
    var hit: core.zonvie_pointer_hit = undefined;
    if (core.zonvie_core_resolve_pointer_grid(&app.pointer_grids, app.pointer_grids_len, 1, c.row, c.col, require_scrollable, &hit) != 0) {
        return .{ .grid_id = hit.grid_id, .row = hit.row, .col = hit.col };
    }
    return .{ .grid_id = 1, .row = @max(0, c.row), .col = @max(0, c.col) };
}

/// Rebases a surface position into the grid the press chose, so a drag that
/// leaves a float keeps addressing it.
fn inPressGrid(app: *App, x: f64, y: f64) ?Cell {
    const c = surfaceCell(app, x, y) orelse return null;
    for (app.pointer_grids[0..app.pointer_grids_len]) |g| {
        if (g.grid_id != app.press_grid_id or app.press_grid_id == 1) continue;
        return .{ .grid_id = g.grid_id, .row = c.row - g.start_row, .col = c.col - g.start_col };
    }
    return .{ .grid_id = 1, .row = @max(0, c.row), .col = @max(0, c.col) };
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
    const app = appFrom(data);
    const cp = app.corep orelse return;
    const name = buttonName(gtk.gtk_gesture_single_get_current_button(gesture.?)) orelse return;
    const c = resolve(app, cp, x, y, 0) orelse return;
    var mods: [8]u8 = undefined;
    const m = keymap.mouseModString(gtk.gtk_event_controller_get_current_event_state(gesture.?), &mods);
    app.held_button = name;
    app.press_grid_id = c.grid_id;
    app.drag_row = c.row;
    app.drag_col = c.col;
    core.zonvie_core_send_mouse_input(cp, name, "press", m.ptr, c.grid_id, c.row, c.col);
}

fn onReleased(gesture: ?*anyopaque, n_press: c_int, x: f64, y: f64, data: ?*anyopaque) callconv(.c) void {
    _ = n_press;
    const app = appFrom(data);
    const cp = app.corep orelse return;
    const name = app.held_button orelse return;
    app.held_button = null;
    const c = inPressGrid(app, x, y) orelse return;
    var mods: [8]u8 = undefined;
    const m = keymap.mouseModString(gtk.gtk_event_controller_get_current_event_state(gesture.?), &mods);
    core.zonvie_core_send_mouse_input(cp, name, "release", m.ptr, c.grid_id, c.row, c.col);
}

fn onMotion(ctrl: ?*anyopaque, x: f64, y: f64, data: ?*anyopaque) callconv(.c) void {
    const app = appFrom(data);
    app.pointer_x = x;
    app.pointer_y = y;
    const name = app.held_button orelse return;
    const cp = app.corep orelse return;
    const c = inPressGrid(app, x, y) orelse return;
    if (c.row == app.drag_row and c.col == app.drag_col) return;
    app.drag_row = c.row;
    app.drag_col = c.col;
    var mods: [8]u8 = undefined;
    const m = keymap.mouseModString(gtk.gtk_event_controller_get_current_event_state(ctrl.?), &mods);
    core.zonvie_core_send_mouse_input(cp, name, "drag", m.ptr, c.grid_id, c.row, c.col);
}

fn onScroll(ctrl: ?*anyopaque, dx: f64, dy: f64, data: ?*anyopaque) callconv(.c) c_int {
    const app = appFrom(data);
    const cp = app.corep orelse return 0;
    var mods: [8]u8 = undefined;
    const m = keymap.mouseModString(gtk.gtk_event_controller_get_current_event_state(ctrl.?), &mods);
    if (dy != 0) {
        // Vertical only: a float showing all its lines lets the wheel through.
        const c = resolve(app, cp, app.pointer_x, app.pointer_y, 1) orelse return 1;
        const dir: [*:0]const u8 = if (dy > 0) "down" else "up";
        sendSteps(cp, c, dir, m.ptr, dy);
    }
    if (dx != 0) {
        const c = resolve(app, cp, app.pointer_x, app.pointer_y, 0) orelse return 1;
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
