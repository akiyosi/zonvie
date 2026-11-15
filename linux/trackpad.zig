//! Touchpad scrolling: GTK's kinetic scroll controller in surface px →
//! pixel_scroll.zig's model on the grid's ease (grid_ease.zig). The content
//! follows the fingers by a sub-cell offset, keeps going under momentum after
//! a flick, and stretches then springs back at a buffer edge. GTK main thread
//! only. Mouse wheels never come here (input.zig onScroll).

const std = @import("std");
const core = @import("zonvie_core");
const clock = core.clock;
const gtk = @import("gtk_bindings.zig");
const applog = @import("app_log.zig");
const input = @import("input.zig");
const pixel_scroll = @import("pixel_scroll.zig");

/// One GLArea's touchpad gesture, from scroll-begin through its momentum.
pub const State = struct {
    /// The grid the gesture's vertical travel addresses, chosen at its first
    /// step and kept to its end, as macOS's ScrollTargetLock.
    target: ?input.Cell = null,
    /// The target takes the travel as a pixel offset; otherwise whole wheel
    /// events from `v_acc`.
    pixel: bool = false,
    /// Fractional wheel events gathered from travel that is not pixel-scrolled.
    v_acc: f64 = 0,
    h_acc: f64 = 0,
    /// Fractional steps of a high-resolution wheel (input.zig onScroll).
    wheel_x: f64 = 0,
    wheel_y: f64 = 0,
    /// Momentum after a flick, in device px/s, positive moving the content
    /// down; its tick callback id and the previous frame's time.
    momentum_px_s: f64 = 0,
    /// The horizontal momentum, device px/s, positive scrolling right.
    momentum_x_px_s: f64 = 0,
    momentum_tick: c_uint = 0,
    last_frame_us: i64 = 0,
    /// The grid whose window lends its 'smoothscroll' to the gesture; 0 none.
    borrowed_grid: i64 = 0,
    /// The modifiers of the last step, sent with the momentum's events.
    mods: [5]u8 = .{ 0, 0, 0, 0, 0 },
    end_queued: bool = false,
    /// When the last vertical step arrived, and the timer that ends a
    /// gesture whose end never comes (X11 reports no scroll stop).
    last_step_ns: i64 = 0,
    watchdog: c_uint = 0,
};

/// A gesture with no step for this long, and no momentum, has ended.
const idle_end_ns: i64 = 500 * std.time.ns_per_ms;

pub fn onBegin(ctrl: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    _ = ctrl;
    const p: *input.Pointer = @ptrCast(@alignCast(data.?));
    // A new gesture may address another grid: the old one lets go.
    finish(p);
}

/// Fingers lifted. A flick follows with decelerate in the same dispatch;
/// without one the gesture ends once the dispatch is over.
pub fn onEnd(ctrl: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    _ = ctrl;
    const p: *input.Pointer = @ptrCast(@alignCast(data.?));
    applog.appLog("[trackpad] end\n", .{});
    if (p.scroll.end_queued) return;
    p.scroll.end_queued = true;
    _ = gtk.g_idle_add(&idleEnd, p);
}

fn idleEnd(data: ?*anyopaque) callconv(.c) c_int {
    const p: *input.Pointer = @ptrCast(@alignCast(data.?));
    p.scroll.end_queued = false;
    if (p.scroll.momentum_tick == 0) finish(p);
    return 0;
}

/// A flick: vertical momentum for a pixel-scrolled target, horizontal
/// momentum as further wheel events on any grid.
pub fn onDecelerate(ctrl: ?*anyopaque, vel_x: f64, vel_y: f64, data: ?*anyopaque) callconv(.c) void {
    _ = ctrl;
    const p: *input.Pointer = @ptrCast(@alignCast(data.?));
    applog.appLog("[trackpad] decelerate vx={d:.0} vy={d:.0} pixel={}\n", .{ vel_x, vel_y, p.scroll.pixel });
    const scale: f64 = p.app.scale;
    const v = -vel_y * scale;
    const vx = vel_x * scale;
    const vertical_on = p.scroll.pixel and p.scroll.target != null and @abs(v) >= pixel_scroll.momentum_stop_px_s;
    const horizontal_on = @abs(vx) >= pixel_scroll.momentum_stop_px_s;
    if (!vertical_on and !horizontal_on) return;
    const area = p.area orelse return;
    p.scroll.momentum_px_s = if (vertical_on) v else 0;
    p.scroll.momentum_x_px_s = if (horizontal_on) vx else 0;
    p.scroll.last_frame_us = 0;
    if (p.scroll.momentum_tick == 0) p.scroll.momentum_tick = gtk.gtk_widget_add_tick_callback(area, &onMomentumTick, p, null);
}

fn onMomentumTick(widget: ?*anyopaque, frame_clock: ?*anyopaque, data: ?*anyopaque) callconv(.c) c_int {
    _ = widget;
    const p: *input.Pointer = @ptrCast(@alignCast(data.?));
    const now_us = gtk.gdk_frame_clock_get_frame_time(frame_clock.?);
    const dt_s: f64 = if (p.scroll.last_frame_us == 0) 1.0 / 60.0 else @as(f64, @floatFromInt(now_us - p.scroll.last_frame_us)) / std.time.us_per_s;
    p.scroll.last_frame_us = now_us;
    const cp = p.app.corep orelse return stopMomentum(p);
    if (p.scroll.momentum_px_s != 0) {
        const step = pixel_scroll.momentumStep(p.scroll.momentum_px_s, dt_s);
        const at_edge = vertical(p, cp, step.delta_px, @ptrCast(&p.scroll.mods));
        // Like the native rubber band, momentum reaching an edge is
        // swallowed and the bounce starts at once.
        p.scroll.momentum_px_s = if (at_edge) 0 else step.velocity_px_s;
    }
    if (p.scroll.momentum_x_px_s != 0) {
        const step = pixel_scroll.momentumStep(p.scroll.momentum_x_px_s, dt_s);
        p.scroll.momentum_x_px_s = step.velocity_px_s;
        horizontal(p, cp, step.delta_px, 0, @ptrCast(&p.scroll.mods));
    }
    if (p.scroll.momentum_px_s != 0 or p.scroll.momentum_x_px_s != 0) return 1;
    p.scroll.momentum_tick = 0;
    finish(p);
    return 0;
}

fn stopMomentum(p: *input.Pointer) c_int {
    p.scroll.momentum_tick = 0;
    p.scroll.momentum_px_s = 0;
    p.scroll.momentum_x_px_s = 0;
    finish(p);
    return 0;
}

/// One touchpad step of (dx, dy) logical px, GTK's sign (positive scrolls
/// toward the end, moving the content up / left).
pub fn scroll(p: *input.Pointer, cp: *core.zonvie_core, dx: f64, dy: f64, mods: [*:0]const u8) void {
    const len = std.mem.len(mods);
    @memset(&p.scroll.mods, 0);
    @memcpy(p.scroll.mods[0..@min(len, p.scroll.mods.len - 1)], mods[0..@min(len, p.scroll.mods.len - 1)]);
    const s: f64 = p.app.scale;
    if (dy != 0) _ = vertical(p, cp, -dy * s, mods);
    if (dx != 0) horizontal(p, cp, dx * s, dy * s, mods);
}

/// Vertical travel of `delta_px` device px, positive moving the content
/// down. Returns whether it pushed into a known buffer edge.
fn vertical(p: *input.Pointer, cp: *core.zonvie_core, delta_px: f64, mods: [*:0]const u8) bool {
    const app = p.app;
    const ver: i32 = @intCast(@min(core.zonvie_core_get_mousescroll_ver(cp), 32));
    // 'mousescroll' ver:0 turns wheel scrolling off in Neovim.
    if (ver == 0 or delta_px == 0) return false;
    const t = p.scroll.target orelse blk: {
        // A float showing all its lines lets the travel through.
        const c = input.resolve(p, cp, p.x, p.y, 1) orelse return false;
        p.scroll.target = c;
        p.scroll.pixel = pixelScrolls(cp, c.grid_id);
        if (p.scroll.watchdog == 0) p.scroll.watchdog = gtk.g_timeout_add(100, &watchdog, p);
        break :blk c;
    };
    p.scroll.last_step_ns = @intCast(clock.nowNs());
    app.mu.lockUncancelable(clock.io());
    const row_h = app.cell_h_px;
    app.mu.unlock(clock.io());
    if (row_h == 0) return false;
    if (!p.scroll.pixel) {
        // Whole events, one per 'mousescroll' rows travelled.
        const n = pixel_scroll.takeSteps(&p.scroll.v_acc, delta_px / (@as(f64, @floatFromInt(row_h)) * @as(f64, @floatFromInt(ver))));
        send(cp, t, if (n > 0) "up" else "down", mods, @abs(n));
        return false;
    }
    const region = scrollRegion(p, t.grid_id) orelse return false;
    const dir: i8 = if (delta_px > 0) 1 else -1;
    var vp: core.ViewportInfo = undefined;
    const edge_now: ?bool = if (core.zonvie_core_try_get_viewport(cp, t.grid_id, &vp) == 1)
        pixel_scroll.edgeFromViewport(vp.topline, vp.line_count, dir)
    else
        null;
    const r = blk: {
        app.mu.lockUncancelable(clock.io());
        defer app.mu.unlock(clock.io());
        const ease = app.surface.gridEase(t.grid_id) orelse return false;
        break :blk ease.pan(delta_px, region[0], region[1], row_h, ver, edge_now, @intCast(clock.nowNs()));
    };
    if (p.scroll.borrowed_grid == 0 and core.zonvie_core_set_gesture_smooth_scroll(cp, t.grid_id, true) == 1)
        p.scroll.borrowed_grid = t.grid_id;
    send(cp, t, if (r.events > 0) "down" else "up", mods, @abs(r.events));
    app.queueRenderAll();
    return r.at_edge;
}

/// Whether `grid_id` follows the fingers by pixels: a Neovim window grid
/// (not the root grid, not the UI the core draws), and not a terminal
/// running a full-screen program (cursor hidden), whose scrolls are its own.
fn pixelScrolls(cp: *core.zonvie_core, grid_id: i64) bool {
    if (grid_id <= 1) return false;
    var mode: [32]u8 = undefined;
    var visible: bool = true;
    if (core.zonvie_core_try_get_mode_state(cp, &mode, mode.len, &visible) == 1) {
        const name = std.mem.sliceTo(&mode, 0);
        if (std.mem.eql(u8, name, "terminal") and !visible) return false;
    }
    return true;
}

/// The rows of `grid_id` a scroll moves: inside its viewport margins
/// (a winbar stays put), as the grid's last hit-test list reports them.
fn scrollRegion(p: *input.Pointer, grid_id: i64) ?[2]u32 {
    const app = p.app;
    for (app.pointer_grids[0..app.pointer_grids_len]) |g| {
        if (g.grid_id != grid_id) continue;
        const top: u32 = @intCast(@max(0, g.margin_top));
        const bottom: i32 = g.rows - @max(0, g.margin_bottom);
        if (bottom <= @as(i32, @intCast(top))) return null;
        return .{ top, @intCast(bottom) };
    }
    return null;
}

/// A horizontal swipe: one event per 'mousescroll' hor columns travelled,
/// sideways jitter of a vertical swipe ignored.
fn horizontal(p: *input.Pointer, cp: *core.zonvie_core, dx_px: f64, dy_px: f64, mods: [*:0]const u8) void {
    const app = p.app;
    const hor = core.zonvie_core_get_mousescroll_hor(cp);
    app.mu.lockUncancelable(clock.io());
    const cell_w = app.cell_w_px;
    app.mu.unlock(clock.io());
    const step_px: f64 = @floatFromInt(cell_w * @min(hor, 64));
    const n = pixel_scroll.horizontalSteps(&p.scroll.h_acc, dx_px, dy_px, step_px);
    if (n == 0) return;
    const c = input.resolve(p, cp, p.x, p.y, 0) orelse return;
    send(cp, c, if (n > 0) "right" else "left", mods, @abs(n));
}

fn send(cp: *core.zonvie_core, c: input.Cell, dir: [*:0]const u8, mods: [*:0]const u8, n: u32) void {
    var i: u32 = 0;
    while (i < @min(n, 16)) : (i += 1) core.zonvie_core_send_mouse_scroll(cp, c.grid_id, c.row, c.col, dir, mods);
}

/// The gesture is over: momentum stops, the target's offset springs back
/// (its edge bounce), and its window gets its 'smoothscroll' back.
pub fn finish(p: *input.Pointer) void {
    const app = p.app;
    if (p.scroll.momentum_tick != 0) {
        if (p.area) |a| gtk.gtk_widget_remove_tick_callback(a, p.scroll.momentum_tick);
        p.scroll.momentum_tick = 0;
    }
    p.scroll.momentum_px_s = 0;
    p.scroll.momentum_x_px_s = 0;
    if (p.scroll.watchdog != 0) {
        _ = gtk.g_source_remove(p.scroll.watchdog);
        p.scroll.watchdog = 0;
    }
    if (p.scroll.target) |t| {
        if (p.scroll.pixel) {
            {
                app.mu.lockUncancelable(clock.io());
                defer app.mu.unlock(clock.io());
                if (app.surface.gridEase(t.grid_id)) |e| e.release();
            }
            // The frame drawn now sees the spring moving and keeps frames
            // coming (gl_renderer.startEaseTick).
            app.queueRenderAll();
        }
    }
    restoreSmoothScroll(p);
    p.scroll.target = null;
    p.scroll.pixel = false;
    p.scroll.v_acc = 0;
    p.scroll.h_acc = 0;
}

/// Hands the borrowed 'smoothscroll' back; a busy core is retried shortly,
/// since a restore that never arrives leaves the option changed.
fn restoreSmoothScroll(p: *input.Pointer) void {
    if (p.scroll.borrowed_grid == 0) return;
    const cp = p.app.corep orelse {
        p.scroll.borrowed_grid = 0;
        return;
    };
    if (core.zonvie_core_set_gesture_smooth_scroll(cp, p.scroll.borrowed_grid, false) == 1) {
        p.scroll.borrowed_grid = 0;
        return;
    }
    _ = gtk.g_timeout_add(20, &retryRestore, p);
}

fn retryRestore(data: ?*anyopaque) callconv(.c) c_int {
    const p: *input.Pointer = @ptrCast(@alignCast(data.?));
    // A new gesture over the same grid uses the borrow; it hands it back.
    if (p.scroll.target) |t| if (t.grid_id == p.scroll.borrowed_grid) return 0;
    restoreSmoothScroll(p);
    return 0;
}

fn watchdog(data: ?*anyopaque) callconv(.c) c_int {
    const p: *input.Pointer = @ptrCast(@alignCast(data.?));
    if (p.scroll.momentum_tick != 0 or clock.nowNs() - p.scroll.last_step_ns < idle_end_ns) return 1;
    // finish must not remove the source returning here.
    p.scroll.watchdog = 0;
    finish(p);
    return 0;
}
