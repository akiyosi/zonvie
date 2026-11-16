//! The Linux frontend: Zonvie on a bare Wayland xdg_toplevel, with no
//! toolkit. The window, its EGL surface, the keyboard and pointer, the
//! selections and the input method are wl/window.c; this file drives it and
//! the core. What is not built yet is listed by unbuilt.zig. There is no X11
//! backend.
//!
//! One thread runs a GLib main loop (GLib alone): the modules that face the
//! core queue their main-thread work with g_idle_add and g_timeout_add, and
//! the Wayland socket is one more source of that loop.

const std = @import("std");
const core = @import("zonvie_core");
const clock = core.clock;
const App = @import("app.zig").App;
const applog = @import("app_log.zig");
const callbacks = @import("callbacks.zig");
const cli = @import("cli.zig");
const config_mod = @import("config.zig");
const gl_renderer = @import("renderer/gl_renderer.zig");
const keymap = @import("keymap.zig");
const core_timers = @import("core_timers.zig");
const ime_off_dbus = @import("ime_off.zig");
const trackpad = @import("trackpad.zig");
const pointer_rules = @import("pointer.zig");
const scrollbar = @import("scrollbar.zig");
const lifecycle = @import("lifecycle.zig");
const window_state = @import("window_size.zig");
const crash = @import("crash.zig");

/// A panic's report goes to the log and, without a terminal, a crash file.
pub const panic = std.debug.FullPanic(crash.onPanic);

const app_id = "io.github.akiyosi.zonvie";
const default_w_logical = 1000;
const default_h_logical = 700;

// wl/window.h
const Listener = extern struct {
    configure: ?*const fn (?*anyopaque, i32, i32) callconv(.c) void,
    close: ?*const fn (?*anyopaque) callconv(.c) void,
    focus: ?*const fn (?*anyopaque, c_int) callconv(.c) void,
    key: ?*const fn (?*anyopaque, u32, u32, u32, u32, u32, u32, c_int, c_int) callconv(.c) void,
    frame: ?*const fn (?*anyopaque) callconv(.c) void,
    pointer_motion: ?*const fn (?*anyopaque, f64, f64) callconv(.c) void,
    pointer_leave: ?*const fn (?*anyopaque) callconv(.c) void,
    pointer_button: ?*const fn (?*anyopaque, u32, c_int, u32) callconv(.c) void,
    pointer_axis: ?*const fn (?*anyopaque, f64, f64, i32, i32, u32) callconv(.c) void,
    ime_preedit: ?*const fn (?*anyopaque, [*:0]const u8, i32, i32) callconv(.c) void,
    ime_commit: ?*const fn (?*anyopaque, [*:0]const u8) callconv(.c) void,
    keys_reset: ?*const fn (?*anyopaque) callconv(.c) void,
    drop: ?*const fn (?*anyopaque, [*]const u8, usize) callconv(.c) void,
};
extern "c" fn zwl_open(l: *const Listener, data: ?*anyopaque) c_int;
extern "c" fn zwl_fd() c_int;
extern "c" fn zwl_scale() c_int;
extern "c" fn zwl_window(app_id: [*:0]const u8, title: [*:0]const u8) c_int;
extern "c" fn zwl_set_title(title: [*:0]const u8) void;
extern "c" fn zwl_placed() c_int;
extern "c" fn zwl_blur() void;
extern "c" fn zwl_set_buffer_scale(scale: i32) void;
extern "c" fn zwl_request_frame() void;
extern "c" fn zwl_frame_pending() c_int;
extern "c" fn zwl_repeat_info(rate: *i32, delay: *i32) void;
extern "c" fn zwl_mods() u32;
extern "c" fn zwl_cursor(shape: c_int) void;
extern "c" fn zwl_ime_cursor(x: i32, y: i32, w: i32, h: i32) void;
extern "c" fn zwl_ime_reset() void;
extern "c" fn zwl_selection_set(primary: c_int, text: [*]const u8, len: usize) c_int;
extern "c" fn zwl_selection_get(primary: c_int, out_len: *usize) ?[*]u8;
extern "c" fn zwl_egl_init(w_px: i32, h_px: i32) c_int;
extern "c" fn zwl_egl_resize(w_px: i32, h_px: i32) void;
extern "c" fn zwl_swap() c_int;
extern "c" fn zwl_dispatch() c_int;
extern "c" fn zwl_dispatch_pending() c_int;
extern "c" fn zwl_flush() c_int;

// GLib's loop.
const GSourceFunc = *const fn (?*anyopaque) callconv(.c) c_int;
extern "c" fn g_main_loop_new(context: ?*anyopaque, is_running: c_int) ?*anyopaque;
extern "c" fn g_main_loop_run(loop: *anyopaque) void;
extern "c" fn g_main_loop_quit(loop: *anyopaque) void;
extern "c" fn g_unix_fd_add(fd: c_int, condition: c_uint, func: *const fn (c_int, c_uint, ?*anyopaque) callconv(.c) c_int, data: ?*anyopaque) c_uint;
extern "c" fn g_timeout_add(interval: c_uint, func: GSourceFunc, data: ?*anyopaque) c_uint;
extern "c" fn g_source_remove(tag: c_uint) c_int;
const G_IO_IN: c_uint = 1;

/// The window's side of the App: main thread only.
const Window = struct {
    app: *App,
    loop: *anyopaque,
    scale: i32,
    /// The size a configure that leaves it to the client gets: the last
    /// run's, else the default. Logical px.
    free_w: i32 = default_w_logical,
    free_h: i32 = default_h_logical,
    /// The toplevel's size as last configured, logical px.
    w_logical: i32 = 0,
    h_logical: i32 = 0,
    /// A configure arrived, so a buffer may be attached.
    configured: bool = false,
    /// A change waits for the frame callback of the frame before it.
    dirty: bool = false,
    /// The first buffer was attached: the window is on screen.
    shown: bool = false,
    /// When the first configure came; the first buffer waits from then.
    configured_ns: i128 = 0,
    layout_ready_sent: bool = false,
    layout_retry_queued: bool = false,
    repeat_timer: c_uint = 0,
    repeat_key: u32 = 0,
    repeat: Key = undefined,
};

const Key = struct { sym: u32, base_sym: u32, utf32: u32, base_utf32: u32, mods: u32 };

var window: Window = undefined;

fn lock(app: *App) void {
    app.mu.lockUncancelable(clock.io());
}

fn unlock(app: *App) void {
    app.mu.unlock(clock.io());
}

// =========================================================================
// Frames
// =========================================================================

/// Draws the committed state now, or when the frame before it has been
/// shown. main thread. ui.zig's queueRenderMain.
pub fn queueRender(app: *App) void {
    if (!window.configured) return;
    if (!window.shown and !firstFrameReady(app)) return;
    if (zwl_frame_pending() != 0) {
        window.dirty = true;
        return;
    }
    draw();
}

/// How long the window stays unmapped for Neovim's first screen.
const first_frame_wait_ms = 250;

/// The first buffer maps the window. It waits for Neovim's screen at the
/// window's own grid, so the window appears with its content instead of
/// empty and then again laid out for another size; a Neovim that takes
/// longer gets an empty window after `first_frame_wait_ms`.
fn firstFrameReady(app: *App) bool {
    if (clock.nowNs() - window.configured_ns >= first_frame_wait_ms * std.time.ns_per_ms) return true;
    lock(app);
    defer unlock(app);
    if (app.cell_w_px == 0 or app.cell_h_px == 0) return false;
    const rows = @max(1, app.drawable_h_px / app.cell_h_px);
    const cols = @max(1, scrollbar.gridWidthPx(app.scrollbar_cfg, app.drawable_w_px, app.scale) / app.cell_w_px);
    for (app.surface.committedLayers()) |l| {
        if (l.grid_id == 1) return l.rows == rows and l.cols == cols;
    }
    return false;
}

fn onFirstFrameTimeout(_: ?*anyopaque) callconv(.c) c_int {
    if (!window.shown) queueRender(window.app);
    return 0;
}

fn draw() void {
    window.dirty = false;
    window.shown = true;
    if (applog.isEnabled()) applog.appLog("[wl] draw\n", .{});
    gl_renderer.render(window.app);
    zwl_request_frame();
    _ = zwl_swap();
    pump();
}

/// EGL reads the socket too (its own roundtrips, a swap), and what it reads
/// for this queue then waits there with the socket no longer readable:
/// dispatched here, after every call that may have done so.
fn pump() void {
    _ = zwl_dispatch_pending();
    _ = zwl_flush();
}

/// A grid eases or a shader animates: the frame after this one is drawn
/// too. Called from inside the draw. ui.zig's keepFrames.
pub fn keepFrames(app: *App) void {
    _ = app;
    window.dirty = true;
}

fn onFrame(_: ?*anyopaque) callconv(.c) void {
    if (window.dirty) draw();
}

// =========================================================================
// Size
// =========================================================================

const layout_retry_ms = 2;

fn retryLayout(_: ?*anyopaque) callconv(.c) c_int {
    window.layout_retry_queued = false;
    pushLayout(window.app);
    return 0;
}

fn pushLayout(app: *App) void {
    const cp = app.corep orelse return;
    lock(app);
    const w = app.drawable_w_px;
    const h = app.drawable_h_px;
    const cw = app.cell_w_px;
    const ch = app.cell_h_px;
    const scale = app.scale;
    unlock(app);
    if (w == 0 or h == 0 or cw == 0 or ch == 0) return;
    const cols = callbacks.cmdlineCols(app, w, cw);
    const grid_w = scrollbar.gridWidthPx(app.scrollbar_cfg, w, scale);
    // The core holds its grid lock through a flush: asked again shortly.
    if (!core.zonvie_core_try_update_layout_px(cp, grid_w, h, cw, ch, cols.screen_cols, cols.default_cols)) {
        if (!window.layout_retry_queued) {
            window.layout_retry_queued = true;
            _ = g_timeout_add(layout_retry_ms, &retryLayout, null);
        }
        return;
    }
    if (!window.layout_ready_sent) {
        window.layout_ready_sent = true;
        core.zonvie_core_notify_layout_ready(cp, @max(1, h / ch), @max(1, grid_w / cw));
    }
}

fn onConfigure(_: ?*anyopaque, w_logical: i32, h_logical: i32) callconv(.c) void {
    const app = window.app;
    window.w_logical = if (w_logical > 0) w_logical else window.free_w;
    window.h_logical = if (h_logical > 0) h_logical else window.free_h;
    const w_px: u32 = @intCast(window.w_logical * window.scale);
    const h_px: u32 = @intCast(window.h_logical * window.scale);
    lock(app);
    const changed = app.drawable_w_px != w_px or app.drawable_h_px != h_px;
    app.drawable_w_px = w_px;
    app.drawable_h_px = h_px;
    unlock(app);
    const first = !window.configured;
    window.configured = true;
    if (first) {
        window.configured_ns = clock.nowNs();
        _ = g_timeout_add(first_frame_wait_ms, &onFirstFrameTimeout, null);
    }
    if (changed) {
        zwl_egl_resize(@intCast(w_px), @intCast(h_px));
        pushLayout(app);
        callbacks.awaitResizeAnswer(app);
    }
    if (!changed and !first) return;
    // A new size is drawn at once, not at the frame callback of the frame
    // before it: that frame has the old size, and the compositor waits for
    // this one.
    if (window.shown) draw() else queueRender(app);
}

/// The compositor's close: Neovim's own `:confirm qa`, which asks in its
/// command line when a buffer is unsaved and otherwise exits, ending the loop
/// through on_exit. No Neovim (it never started, or is gone): just the loop.
fn onClose(_: ?*anyopaque) callconv(.c) void {
    const cp = window.app.corep orelse return g_main_loop_quit(window.loop);
    const cmd = "confirm qa";
    core.zonvie_core_send_command(cp, cmd, cmd.len);
}

/// ui.zig's session.applyTitle.
pub fn setTitle(app: *App, title: []const u8) void {
    var buf: [384]u8 = undefined;
    zwl_set_title(lifecycle.sessionTitle(&buf, title, app.session_name).ptr);
    _ = zwl_flush();
}

// =========================================================================
// Keys
// =========================================================================

fn sendKey(k: Key) void {
    const app = window.app;
    const cp = app.corep orelse return;
    if (keymap.swallowDuringPreedit(app.preedit_active, k.sym)) return;
    const code = keymap.coreKeycode(k.sym);
    const mods = keymap.coreMods(k.mods);
    var buf: [4]u8 = undefined;
    var n: usize = 0;
    const cp_u = keymap.swapColonSemicolon(k.utf32, app.input_cfg.swap_colon_semicolon);
    if (cp_u != 0) n = std.unicode.utf8Encode(@intCast(cp_u), &buf) catch 0;
    // A bare modifier or dead key: nothing the core can format.
    if (code == 0 and n == 0) return;
    // A modified key names its unshifted key (<C-S-2>, not <C-S-@>).
    var ign: [4]u8 = undefined;
    var ign_n: usize = n;
    @memcpy(ign[0..n], buf[0..n]);
    if (mods & (core.MOD_CTRL | core.MOD_ALT | core.MOD_SUPER) != 0 and k.base_utf32 != 0) {
        ign_n = std.unicode.utf8Encode(@intCast(k.base_utf32), &ign) catch ign_n;
    }
    core.zonvie_core_send_key_event(cp, code, mods, &buf, @intCast(n), &ign, @intCast(ign_n));
}

fn stopRepeat() void {
    if (window.repeat_timer != 0) _ = g_source_remove(window.repeat_timer);
    window.repeat_timer = 0;
}

fn onRepeat(_: ?*anyopaque) callconv(.c) c_int {
    sendKey(window.repeat);
    return 1;
}

fn onRepeatDelay(_: ?*anyopaque) callconv(.c) c_int {
    var rate: i32 = 0;
    var delay: i32 = 0;
    zwl_repeat_info(&rate, &delay);
    sendKey(window.repeat);
    window.repeat_timer = if (rate > 0) g_timeout_add(@intCast(@divTrunc(1000, rate)), &onRepeat, null) else 0;
    return 0;
}

fn onKey(_: ?*anyopaque, key: u32, sym: u32, base_sym: u32, utf32: u32, base_utf32: u32, mods: u32, pressed: c_int, repeats: c_int) callconv(.c) void {
    if (pressed == 0) {
        if (key == window.repeat_key) stopRepeat();
        return;
    }
    const k: Key = .{ .sym = sym, .base_sym = base_sym, .utf32 = utf32, .base_utf32 = base_utf32, .mods = mods };
    sendKey(k);
    stopRepeat();
    if (repeats == 0) return;
    var rate: i32 = 0;
    var delay: i32 = 0;
    zwl_repeat_info(&rate, &delay);
    if (rate <= 0) return;
    window.repeat_key = key;
    window.repeat = k;
    window.repeat_timer = g_timeout_add(@intCast(@max(1, delay)), &onRepeatDelay, null);
}

fn onKeysReset(_: ?*anyopaque) callconv(.c) void {
    stopRepeat();
}

fn onFocus(_: ?*anyopaque, focused: c_int) callconv(.c) void {
    if (focused == 0) stopRepeat();
    if (window.app.corep) |cp| core.zonvie_core_set_focus(cp, focused != 0);
}

// =========================================================================
// Input method
// =========================================================================

/// A composition starts or ends.
fn setComposing(app: *App, on: bool) void {
    if (app.preedit_active == on) return;
    app.preedit_active = on;
    app.ime_composing.store(on, .release);
    app.queueRenderAll();
}

/// The composition as the input method has it now. In insert and replace
/// mode the core shows it in the buffer, at the cursor; elsewhere (the
/// command line) nothing draws it yet.
fn onImePreedit(_: ?*anyopaque, text: [*:0]const u8, begin: i32, end: i32) callconv(.c) void {
    const app = window.app;
    const cp = app.corep orelse return;
    const t = std.mem.span(text);
    // The input method has the keyboard: a key held before it took over
    // sends no release here.
    if (t.len != 0) stopRepeat();
    if (t.len == 0) {
        if (app.preedit_active) core.zonvie_core_clear_preedit(cp);
        setComposing(app, false);
        return;
    }
    setComposing(app, true);
    // text-input-v3 carries the cursor's range, which input methods set to
    // the clause being converted.
    const clause: [2]usize = if (begin >= 0 and end > begin and end <= t.len) .{ @intCast(begin), @intCast(end) } else .{ 0, 0 };
    _ = core.zonvie_core_set_preedit(cp, t.ptr, t.len, clause[0], clause[1]);
}

fn onImeCommit(_: ?*anyopaque, text: [*:0]const u8) callconv(.c) void {
    const app = window.app;
    const cp = app.corep orelse return;
    const t = std.mem.span(text);
    if (app.preedit_active) {
        setComposing(app, false);
        core.zonvie_core_clear_preedit(cp);
    }
    if (t.len == 0) return;
    core.zonvie_core_send_input(cp, t.ptr, t.len);
}

/// Switches the input method off ([input] ime_disable_on_modechange and the
/// like): the composition is dropped, then the IM framework is asked over
/// D-Bus (ime_off.zig). main thread. unbuilt.zig's ime_off.off.
pub fn imeOff() void {
    const app = window.app;
    if (app.preedit_active) {
        if (app.corep) |cp| core.zonvie_core_clear_preedit(cp);
        setComposing(app, false);
    }
    zwl_ime_reset();
    ime_off_dbus.off();
}

/// Tells the input method where the text cursor is, after a frame's state
/// was committed. main thread. ui.zig's input.updateImeCursor.
pub fn updateImeCursor(app: *App) void {
    lock(app);
    defer unlock(app);
    const cur = app.surface.committedCursor();
    if (cur.verts.len == 0) return;
    const layer = for (app.surface.committedSurfaceLayers(1)) |l| {
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
    zwl_ime_cursor(
        @intFromFloat((x0 + @as(f32, @floatFromInt(layer.x_px))) / s),
        @intFromFloat((y0 + @as(f32, @floatFromInt(layer.y_px))) / s),
        @intFromFloat(@max(1.0, (x1 - x0) / s)),
        @intFromFloat(@max(1.0, (y1 - y0) / s)),
    );
}

// =========================================================================
// Selections
// =========================================================================

/// The clipboard's text, or the primary selection's; null when it holds
/// none. The caller frees it with std.c.free. main thread. ui.zig's
/// selectionGet.
pub fn selectionGet(primary: bool) ?[]u8 {
    var len: usize = 0;
    const p = zwl_selection_get(@intFromBool(primary), &len) orelse return null;
    return p[0..len];
}

/// main thread. ui.zig's selectionSet.
pub fn selectionSet(primary: bool, text: []const u8) bool {
    return zwl_selection_set(@intFromBool(primary), text.ptr, text.len) == 0;
}

// =========================================================================
// Pointer
// =========================================================================

/// A Linux button code as PressClaim's number (zonvie_core.h) and Neovim's name.
const Button = struct { claim: u8, name: [*:0]const u8 };

fn buttonOf(code: u32) ?Button {
    return switch (code) {
        0x110 => .{ .claim = 1, .name = "left" },
        0x111 => .{ .claim = 2, .name = "right" },
        0x112 => .{ .claim = 3, .name = "middle" },
        0x113 => .{ .claim = 4, .name = "x1" },
        0x114 => .{ .claim = 5, .name = "x2" },
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

fn onPointerMotion(_: ?*anyopaque, x: f64, y: f64) callconv(.c) void {
    const app = window.app;
    const p = &app.pointer;
    p.x = x;
    p.y = y;
    if (scrollbar.motion(app, 1, x, y)) return showUrlHand(p, false);
    const cp = app.corep orelse return;
    const name = claimName(p.claim.owner) orelse return updateUrlHand(p, cp, x, y);
    const c = pointer_rules.inPressGrid(p, x, y, true) orelse return;
    if (c.row == p.drag_row and c.col == p.drag_col) return;
    p.drag_row = c.row;
    p.drag_col = c.col;
    var mods: [5]u8 = undefined;
    const m = keymap.mouseModString(zwl_mods(), &mods);
    core.zonvie_core_send_mouse_input(cp, name, "drag", m.ptr, c.grid_id, c.row, c.col);
}

fn onPointerLeave(_: ?*anyopaque) callconv(.c) void {
    const app = window.app;
    scrollbar.leave(app, 1);
    showUrlHand(&app.pointer, false);
}

/// The hand over a cell whose highlight carries a URL, as a click there
/// would name it. A busy core (-1) keeps the last answer.
fn updateUrlHand(p: *pointer_rules.Pointer, cp: *core.zonvie_core, x: f64, y: f64) void {
    const c = pointer_rules.resolve(p, cp, x, y, 0) orelse return showUrlHand(p, false);
    const has = core.zonvie_core_try_cell_has_url(cp, c.grid_id, c.row, c.col);
    if (has >= 0) showUrlHand(p, has == 1);
}

fn showUrlHand(p: *pointer_rules.Pointer, on: bool) void {
    if (p.url_hand == on) return;
    p.url_hand = on;
    zwl_cursor(@intFromBool(on));
    _ = zwl_flush();
}

fn onPointerButton(_: ?*anyopaque, code: u32, pressed: c_int, mods_mask: u32) callconv(.c) void {
    const app = window.app;
    const p = &app.pointer;
    const cp = app.corep orelse return;
    // The scrollbar takes a left press on it; Neovim never sees that one.
    if (code == 0x110) {
        if (pressed != 0 and p.claim.held_mask == 0 and scrollbar.press(app, 1, p.x, p.y)) {
            p.bar_held = true;
            return;
        }
        if (pressed == 0 and p.bar_held) {
            p.bar_held = false;
            _ = scrollbar.release(app, 1);
            return;
        }
    }
    const b = buttonOf(code) orelse return;
    var mods: [5]u8 = undefined;
    const m = keymap.mouseModString(mods_mask, &mods);
    if (pressed != 0) {
        const c = pointer_rules.resolve(p, cp, p.x, p.y, 0) orelse return;
        if (p.claim.press(b.claim)) {
            p.press_grid_id = c.grid_id;
            p.drag_row = c.row;
            p.drag_col = c.col;
        }
        core.zonvie_core_send_mouse_input(cp, b.name, "press", m.ptr, c.grid_id, c.row, c.col);
        return;
    }
    // Every sent press gets its release, to the claim's grid.
    if (!p.claim.release(b.claim).send) return;
    const c = pointer_rules.inPressGrid(p, p.x, p.y, false) orelse return;
    core.zonvie_core_send_mouse_input(cp, b.name, "release", m.ptr, c.grid_id, c.row, c.col);
}

/// One event per wheel step.
fn sendSteps(cp: *core.zonvie_core, c: pointer_rules.Cell, dir: [*:0]const u8, mods: [*:0]const u8, steps: i32) void {
    var i: u32 = 0;
    while (i < @min(16, @abs(steps))) : (i += 1) core.zonvie_core_send_mouse_scroll(cp, c.grid_id, c.row, c.col, dir, mods);
}

fn onPointerAxis(_: ?*anyopaque, dx: f64, dy: f64, steps_x: i32, steps_y: i32, mods_mask: u32) callconv(.c) void {
    const app = window.app;
    const p = &app.pointer;
    const cp = app.corep orelse return;
    var mods: [5]u8 = undefined;
    const m = keymap.mouseModString(mods_mask, &mods);
    const sx = steps_x;
    const sy = steps_y;
    if (sx == 0 and sy == 0) {
        // A touchpad: its travel moves the text by the pixel (trackpad.zig).
        trackpad.scroll(p, cp, dx, dy, m.ptr);
        core_timers.scheduleMsg(app);
        return;
    }
    if (sy != 0) {
        // Vertical only: a float showing all its lines lets the wheel through.
        const c = pointer_rules.resolve(p, cp, p.x, p.y, 1) orelse return;
        sendSteps(cp, c, if (sy > 0) "down" else "up", m.ptr, sy);
    }
    if (sx != 0) {
        const c = pointer_rules.resolve(p, cp, p.x, p.y, 0) orelse return;
        sendSteps(cp, c, if (sx > 0) "right" else "left", m.ptr, sx);
    }
    // A scroll of a message float can be throttled into a message deadline.
    core_timers.scheduleMsg(app);
}

// =========================================================================
// File drops
// =========================================================================

/// One line of a text/uri-list as a path: a file:// URI, percent-decoded.
/// Null for a comment, another scheme, or a line that does not fit `buf`.
fn uriPath(buf: []u8, line: []const u8) ?[]const u8 {
    const prefix = "file://";
    if (!std.mem.startsWith(u8, line, prefix)) return null;
    // file://host/path: the path starts at the first slash after the host.
    const rest = line[prefix.len..];
    const start = std.mem.indexOfScalar(u8, rest, '/') orelse return null;
    var n: usize = 0;
    var i: usize = start;
    while (i < rest.len) : (i += 1) {
        if (n == buf.len) return null;
        if (rest[i] == '%' and i + 2 < rest.len) {
            if (std.fmt.parseInt(u8, rest[i + 1 .. i + 3], 16)) |byte| {
                buf[n] = byte;
                n += 1;
                i += 2;
                continue;
            } else |_| {}
        }
        buf[n] = rest[i];
        n += 1;
    }
    return buf[0..n];
}

/// Dropped files open in Neovim, or in the command line and a terminal go in
/// as their escaped paths.
fn onDrop(_: ?*anyopaque, uri_list: [*]const u8, len: usize) callconv(.c) void {
    const app = window.app;
    const cp = app.corep orelse return;
    var arena = std.heap.ArenaAllocator.init(app.alloc);
    defer arena.deinit();
    const a = arena.allocator();
    var paths: std.ArrayListUnmanaged([]const u8) = .empty;
    var lines = std.mem.tokenizeAny(u8, uri_list[0..len], "\r\n");
    while (lines.next()) |line| {
        const buf = a.alloc(u8, line.len) catch return;
        const path = uriPath(buf, line) orelse continue;
        paths.append(a, path) catch return;
    }
    if (paths.items.len == 0) return;

    const mode = std.mem.span(core.zonvie_core_get_current_mode(cp));
    if (core.frontend_rules.dropInsertsPath(mode, false, false)) {
        var line: std.ArrayListUnmanaged(u8) = .empty;
        for (paths.items) |path| {
            const buf = a.alloc(u8, 2 * path.len + 1) catch return;
            const esc = core.frontend_rules.escapePathForCmdline(buf, path, false) orelse continue;
            if (line.items.len != 0) line.append(a, ' ') catch return;
            line.appendSlice(a, esc) catch return;
        }
        if (line.items.len != 0) core.zonvie_core_send_input(cp, line.items.ptr, @intCast(line.items.len));
        return;
    }
    // Unescaped: the server escapes each with its own fnameescape().
    const ptrs = a.alloc([*]const u8, paths.items.len) catch return;
    const lens = a.alloc(usize, paths.items.len) catch return;
    for (paths.items, ptrs, lens) |path, *pp, *l| {
        pp.* = path.ptr;
        l.* = path.len;
    }
    core.zonvie_core_drop_paths(cp, ptrs.ptr, lens.ptr, paths.items.len, 0);
}

const listener: Listener = .{
    .configure = &onConfigure,
    .close = &onClose,
    .focus = &onFocus,
    .key = &onKey,
    .frame = &onFrame,
    .pointer_motion = &onPointerMotion,
    .pointer_leave = &onPointerLeave,
    .pointer_button = &onPointerButton,
    .pointer_axis = &onPointerAxis,
    .ime_preedit = &onImePreedit,
    .ime_commit = &onImeCommit,
    .keys_reset = &onKeysReset,
    .drop = &onDrop,
};

fn onWayland(_: c_int, _: c_uint, _: ?*anyopaque) callconv(.c) c_int {
    if (zwl_dispatch() < 0) g_main_loop_quit(window.loop);
    _ = zwl_flush();
    return 1;
}

/// Ends the loop: Neovim exited. main thread. ui.zig's quit.
pub fn quit(app: *App) void {
    _ = app;
    g_main_loop_quit(window.loop);
}

// =========================================================================
// Entry point
// =========================================================================

/// A wrong option: on stderr, where a terminal start shows it.
fn optionError(msg: []const u8) u8 {
    std.debug.print("{s}\n", .{msg});
    return 1;
}

fn appendArg(list: *std.ArrayListUnmanaged(u8), alloc: std.mem.Allocator, arg: []const u8) ?u8 {
    cli.appendSpawnArg(list, alloc, arg) catch |e| {
        if (e != error.Unquotable) return 1;
        std.debug.print("zonvie: this argument cannot be passed to nvim (a space together with both quote kinds, or a trailing backslash): {s}\n", .{arg});
        return 1;
    };
    return null;
}

/// `devcontainer up`, waited for: the container must exist before Neovim is
/// started in it. Its output goes to this process's stderr.
fn devcontainerUp(argv: [*:null]const ?[*:0]const u8) bool {
    const pid = fork();
    if (pid < 0) return false;
    if (pid == 0) {
        _ = execvp(argv[0].?, argv);
        _exit(127);
    }
    var status: c_int = 0;
    while (waitpid(pid, &status, 0) < 0) {}
    return status == 0;
}

extern "c" fn fork() c_int;
extern "c" fn execvp(file: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) c_int;
extern "c" fn waitpid(pid: c_int, status: *c_int, options: c_int) c_int;
extern "c" fn _exit(code: c_int) noreturn;

pub fn main(init: std.process.Init.Minimal) u8 {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();
    var args_arena = std.heap.ArenaAllocator.init(alloc);
    defer args_arena.deinit();
    const aa = args_arena.allocator();
    const args = init.args.toSlice(aa) catch return 1;

    if (cli.hasFlag(args, "--help") or cli.hasFlag(args, "-h")) {
        cli.printHelp();
        return 0;
    }
    if (cli.hasFlag(args, "--version")) {
        cli.printVersion();
        return 0;
    }
    const nofork = cli.hasFlag(args, "--nofork");
    // Attaching to a server never forks: its failures must reach the shell's
    // exit code. Nor does a launch with no terminal to leave. Before any
    // thread exists.
    const connects = cli.hasPrefix(args, "--connect-nvim") or cli.hasPrefix(args, "--remote-ui");
    if (!nofork and !connects and std.c.isatty(0) != 0 and cli.detach()) return 0;

    clock.init();
    if (cli.hasFlag(args, "--install")) return cli.install(alloc);
    // First launch: the default config and the desktop entry. An existing
    // desktop entry is kept.
    if (config_mod.getConfigFilePath(alloc)) |p| alloc.free(p) else |_| cli.installFirstLaunch(alloc);
    // A launcher start has no shell behind it: take the login shell's
    // environment (PATH for LSPs and the like).
    if (std.c.getenv("TERM") == null) cli.importLoginShellEnv(alloc);
    _ = cli.setenv("CLAUDE_CODE_NATIVE_CURSOR", "1", 1);

    var config = config_mod.load(alloc);
    defer config.deinit();

    // Not taken: --dialog (there is no connection dialog), --extwindows and
    // --exttabline (unbuilt.zig), --renderer= (one renderer).
    const config_nvim = cli.nvimPath(config.neovim.path);
    var nvim_path: []const u8 = if (config_nvim.path.len > 0) config_nvim.path else "nvim";
    var cli_nvim_path: ?[]const u8 = null;
    var log_path: ?[]const u8 = null;
    var ext_cmdline = config.cmdline.external;
    var ext_popupmenu = config.popup.external;
    var ext_messages = config.messages.external;
    var connect_addr: ?[]const u8 = null;
    var ssh: ?cli.Ssh = if (config.neovim.ssh) if (config.neovim.ssh_host) |h| cli.Ssh{ .host = h, .port = config.neovim.ssh_port, .identity = config.neovim.ssh_identity } else null else null;
    var ssh_identity: ?[]const u8 = config.neovim.ssh_identity;
    var devcontainer: ?cli.Devcontainer = null;
    var devcontainer_config: ?[]const u8 = null;
    var devcontainer_rebuild = false;
    var extra: std.ArrayListUnmanaged([]const u8) = .empty;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        const next: ?[]const u8 = if (i + 1 < args.len) args[i + 1] else null;
        if (std.mem.eql(u8, arg, "--")) {
            // Everything after is nvim's own command line.
            var scan: core.frontend_rules.NvimArgScan = .{};
            for (args[i + 1 ..]) |a| {
                extra.append(aa, if (scan.isFile(a)) cli.absolutePath(aa, a) catch return 1 else a) catch return 1;
            }
            break;
        } else if (std.mem.eql(u8, arg, "--nvim") and next != null) {
            i += 1;
            cli_nvim_path = args[i];
        } else if (std.mem.startsWith(u8, arg, "--nvim=")) {
            cli_nvim_path = arg["--nvim=".len..];
        } else if (std.mem.startsWith(u8, arg, "--ssh=")) {
            const t = core.frontend_rules.sshTarget(arg["--ssh=".len..]);
            ssh = .{ .host = t.host, .port = t.port };
        } else if (std.mem.eql(u8, arg, "--ssh")) {
            if (core.frontend_rules.cliNextIsValue(next)) {
                i += 1;
                const t = core.frontend_rules.sshTarget(args[i]);
                ssh = .{ .host = t.host, .port = t.port };
            }
        } else if (std.mem.startsWith(u8, arg, "--ssh-identity=")) {
            ssh_identity = arg["--ssh-identity=".len..];
        } else if (std.mem.eql(u8, arg, "--ssh-identity")) {
            if (core.frontend_rules.cliNextIsValue(next)) {
                i += 1;
                ssh_identity = args[i];
            }
        } else if (std.mem.startsWith(u8, arg, "--devcontainer=")) {
            devcontainer = .{ .workspace = arg["--devcontainer=".len..] };
        } else if (std.mem.eql(u8, arg, "--devcontainer")) {
            if (core.frontend_rules.cliNextIsValue(next)) {
                i += 1;
                devcontainer = .{ .workspace = args[i] };
            }
        } else if (std.mem.startsWith(u8, arg, "--devcontainer-config=")) {
            devcontainer_config = arg["--devcontainer-config=".len..];
        } else if (std.mem.eql(u8, arg, "--devcontainer-config")) {
            if (core.frontend_rules.cliNextIsValue(next)) {
                i += 1;
                devcontainer_config = args[i];
            }
        } else if (std.mem.eql(u8, arg, "--devcontainer-rebuild")) {
            devcontainer_rebuild = true;
        } else if (std.mem.eql(u8, arg, "--extcmdline")) {
            ext_cmdline = true;
        } else if (std.mem.eql(u8, arg, "--extpopup") or std.mem.eql(u8, arg, "--extpopupmenu")) {
            ext_popupmenu = true;
        } else if (std.mem.eql(u8, arg, "--extmessages")) {
            ext_messages = true;
        } else if (std.mem.startsWith(u8, arg, "--connect-nvim=")) {
            connect_addr = arg["--connect-nvim=".len..];
        } else if (std.mem.startsWith(u8, arg, "--remote-ui=")) {
            connect_addr = arg["--remote-ui=".len..];
        } else if (std.mem.eql(u8, arg, "--connect-nvim") or std.mem.eql(u8, arg, "--remote-ui")) {
            // Bare, it is still this option: never nvim's argument.
            connect_addr = if (next != null) blk: {
                i += 1;
                break :blk args[i];
            } else "";
        } else if (std.mem.eql(u8, arg, "--log") and next != null) {
            i += 1;
            log_path = args[i];
        } else if (std.mem.eql(u8, arg, "--nofork") or std.mem.eql(u8, arg, "--install")) {
            // Handled above.
        } else {
            extra.append(aa, cli.absoluteFileArg(aa, args[i - 1], arg, false) catch return 1) catch return 1;
        }
    }
    applog.setVerbose(config.log.verbose and !config.log.perf_only and !config.log.scroll_only);
    applog.setFilters(config.log.perf_only, config.log.scroll_only);
    // --log wins over [log]; [log] enabled without a path logs to stderr.
    if (log_path) |p| {
        applog.setEnabled(true);
        applog.setLogPath(p);
    } else if (config.log.enabled) {
        applog.setEnabled(true);
        applog.setLogPath(config.log.path);
    }
    defer applog.deinit();

    if (cli_nvim_path) |raw| {
        const p = cli.nvimPath(raw);
        cli_nvim_path = if (p.path.len != 0) p.path else null;
        if (cli_nvim_path) |v| nvim_path = v;
    }
    if (connect_addr) |a| if (a.len == 0) {
        return optionError("zonvie: --connect-nvim / --remote-ui requires a non-empty address (e.g. /tmp/nvim.sock or 127.0.0.1:6789).");
    };
    if (@as(u8, @intFromBool(ssh != null)) + @intFromBool(connect_addr != null) + @intFromBool(devcontainer != null) > 1) {
        return optionError("--connect-nvim, --ssh (or [neovim] ssh in config.toml) and --devcontainer are mutually exclusive. Remove the conflicting option and retry.");
    }

    // --ssh: nvim runs on the host, and --nvim names the remote executable;
    // local file arguments do not apply there. No password dialog exists
    // here, so the host must take a key or an agent.
    var dc_up_argv: ?[*:null]const ?[*:0]const u8 = null;
    const nvim_cmd: [:0]const u8 = if (ssh) |s| blk: {
        var target = s;
        target.identity = ssh_identity;
        break :blk cli.sshCommand(aa, target, cli_nvim_path orelse "nvim") catch return 1;
    } else if (devcontainer) |d| blk: {
        const target: cli.Devcontainer = .{
            .workspace = cli.expandTilde(aa, d.workspace) catch return 1,
            .config = if (devcontainer_config) |c| cli.expandTilde(aa, c) catch return 1 else null,
            .rebuild = devcontainer_rebuild,
        };
        if (devcontainer_rebuild) dc_up_argv = cli.devcontainerUpArgv(aa, target, cli.nvimConfigDir(aa) catch return 1) catch return 1;
        break :blk cli.devcontainerCommand(aa, target) catch return 1;
    } else blk: {
        var cmd: std.ArrayListUnmanaged(u8) = .empty;
        if (appendArg(&cmd, aa, nvim_path)) |rc| return rc;
        // An empty argument has no token; the tokenizer always dropped it.
        for (extra.items) |a| if (a.len != 0) if (appendArg(&cmd, aa, a)) |rc| return rc;
        break :blk aa.dupeZ(u8, cmd.items) catch return 1;
    };
    const start_kind: lifecycle.StartKind = if (ssh != null) .ssh else if (connect_addr != null) .connect else if (devcontainer != null) .devcontainer else .local;
    var name_buf: [256]u8 = undefined;
    const session_name = aa.dupe(u8, lifecycle.defaultSessionName(&name_buf, start_kind, if (ssh) |s| s.host else if (devcontainer) |d| d.workspace else "")) catch "";

    const app = alloc.create(App) catch return 1;
    defer alloc.destroy(app);
    app.* = .{
        .alloc = alloc,
        .large_jump = config.scroll.large_jump_behavior,
        .font_cfg = config.font,
        .msg_pos = config.messages.msg_pos,
        .input_cfg = config.input,
        .window_cfg = config.window,
        .scrollbar_cfg = config.scrollbar,
        .tabline_cfg = config.tabline,
        .ext_cmdline = ext_cmdline,
        .copy_cmdline = config.cmdline.copy_button,
        .copy_messages = config.messages.copy_button,
        .log_perf_only = config.log.perf_only,
        .log_scroll_only = config.log.scroll_only,
        .shader_paths = if (config.shaders.enabled) config.shaders.paths else &.{},
        .shader_preserve_alpha = config.shaders.preserve_alpha,
        .shader_epoch_ns = clock.nowNs(),
        .cell_age = core.cell_age_store.Stores.init(alloc),
        .session_name = session_name,
        .start_kind = start_kind,
    };
    defer app.deinit();
    app.pointer = .{ .app = app };

    if (zwl_open(&listener, null) != 0) {
        std.debug.print("zonvie: no Wayland compositor\n", .{});
        return 1;
    }
    const scale = zwl_scale();
    const loop = g_main_loop_new(null, 0) orelse return 1;
    window = .{ .app = app, .loop = loop, .scale = scale };
    if (window_state.restored()) |s| {
        window.free_w = s.size[0];
        window.free_h = s.size[1];
    }
    app.scale = @floatFromInt(scale);

    if (dc_up_argv) |argv| if (!devcontainerUp(argv)) {
        std.debug.print("zonvie: devcontainer up failed\n", .{});
        return 1;
    };

    // The core and Neovim first: Neovim loads while the window and its GL
    // context come up. The outputs' scale is known since zwl_open, so the
    // faces are loaded once, at the size they are drawn at.
    callbacks.ensureFont(app);
    var cb = callbacks.makeCallbacks();
    app.corep = core.zonvie_core_create(&cb, @sizeOf(core.Callbacks), app);
    const cp = app.corep orelse return 1;
    if (config_mod.getConfigFilePath(alloc)) |path| {
        defer alloc.free(path);
        if (alloc.dupeZ(u8, path)) |z| {
            defer alloc.free(z);
            _ = core.zonvie_core_load_config(cp, z.ptr);
        } else |_| {}
    } else |_| {}
    core.zonvie_core_set_log_enabled(cp, @intFromBool(applog.isEnabled()));
    if (applog.isVerbose()) core.zonvie_core_set_log_verbose(cp, 1);
    if (app.log_perf_only) core.zonvie_core_set_log_perf_only(cp, 1);
    if (app.log_scroll_only) core.zonvie_core_set_log_scroll_only(cp, 1);
    core.zonvie_core_set_background_opacity(cp, app.window_cfg.opacity);
    core.zonvie_core_set_blur_enabled(cp, @intFromBool(app.window_cfg.blur));
    // Started from a shell that waits (--nofork), Neovim keeps the directory
    // its arguments are relative to.
    if (nofork) core.zonvie_core_set_inherit_cwd(cp, 1);
    if (ext_cmdline) core.zonvie_core_set_ext_cmdline(cp, 1);
    if (ext_popupmenu) core.zonvie_core_set_ext_popupmenu(cp, 1);
    if (ext_messages) core.zonvie_core_set_ext_messages(cp, 1);
    const w_px: u32 = @intCast(window.free_w * scale);
    const h_px: u32 = @intCast(window.free_h * scale);
    const rows: u32 = if (app.cell_h_px != 0) @max(1, h_px / app.cell_h_px) else 24;
    const cols: u32 = if (app.cell_w_px != 0) @max(1, w_px / app.cell_w_px) else 80;
    const rc = if (connect_addr) |addr|
        core.zonvie_core_start_connect(cp, addr.ptr, addr.len, rows, cols)
    else
        core.zonvie_core_start(cp, nvim_cmd.ptr, rows, cols);
    if (rc != 0) {
        std.debug.print("zonvie: {s} (rc={d})\n", .{ cli.startFailureReason(rc), rc });
        return 1;
    }
    // Neovim is attached to at the start size; the first configure corrects it.
    app.drawable_w_px = w_px;
    app.drawable_h_px = h_px;
    pushLayout(app);

    if (zwl_window(app_id, "zonvie") != 0) return 1;
    zwl_set_buffer_scale(scale);
    if (app.window_cfg.blur) zwl_blur();
    if (zwl_egl_init(@intCast(w_px), @intCast(h_px)) != 0) {
        std.debug.print("zonvie: no OpenGL 3.3 context\n", .{});
        return 1;
    }
    if (!gl_renderer.realize(&app.gl)) return 1;

    _ = g_unix_fd_add(zwl_fd(), G_IO_IN, &onWayland, null);
    pump();
    g_main_loop_run(loop);
    // The size for the next run, unless the compositor chose it (a tile, a
    // maximized or fullscreen window): that one keeps the last free size.
    if (window.shown and zwl_placed() == 0 and window.w_logical > 0 and window.h_logical > 0) {
        window_state.store(.{ .size = .{ window.w_logical, window.h_logical } });
    }
    return 0;
}
