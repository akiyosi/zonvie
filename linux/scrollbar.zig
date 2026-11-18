//! The overlay scrollbar ([scrollbar]): one per surface, at its right edge,
//! showing the viewport of the grid the core names for it. The rules are the
//! core's (zonvie_core_try_scrollbar_grid, _scrollbar_metrics,
//! _scrollbar_drag_target); this file keeps the fade, the timers, the hit
//! test and the drag, after windows/ui/scrollbar.zig. main thread, but
//! for `alpha`, which the renderer reads under App.mu, and commitViews.

const std = @import("std");
const core = @import("zonvie_core");
const clock = core.clock;
const App = @import("app.zig").App;
const glib = @import("glib.zig");
const applog = @import("app_log.zig");

/// Logical px, as windows/app.zig's SCROLLBAR_*.
const width_pt: f32 = 12;
const margin_pt: f32 = 2;
const min_knob_pt: f32 = 20;
const fade_interval_ms = 16;
const fade_step: f32 = 0.15;
const repeat_delay_ms = 400;
const repeat_interval_ms = 100;
const drag_throttle_ns = 32 * std.time.ns_per_ms;

pub const Viewport = @import("surface_store.zig").ScrollView;

/// Device px the "column" layout takes off a surface's right edge for the
/// strip the track sits in (windows/app.zig scrollbarReservedWidth); 0 when
/// the bar overlays the grid or is disabled.
pub fn columnStripPx(cfg: core.config.Config.ScrollbarConfig, scale: f32) u32 {
    if (!cfg.isColumn()) return 0;
    return @intFromFloat(@round((width_pt + 2 * margin_pt) * scale));
}

/// The width a surface of `w_px` gives its grid: less the column strip,
/// leaving the grid at least one px.
pub fn gridWidthPx(cfg: core.config.Config.ScrollbarConfig, w_px: u32, scale: f32) u32 {
    const strip = columnStripPx(cfg, scale);
    return if (w_px > strip) w_px - strip else @min(w_px, 1);
}

pub const Grid = struct { rows: u32, cols: u32 };

/// The grid a surface of `w_px` x `h_px` holds at a cell of `cell_w_px` x
/// `cell_h_px`: whole cells of what the column strip leaves, at least one
/// each way. Pre: both cell sizes are non-zero.
pub fn gridFor(cfg: core.config.Config.ScrollbarConfig, w_px: u32, h_px: u32, cell_w_px: u32, cell_h_px: u32, scale: f32) Grid {
    return .{ .rows = @max(1, h_px / cell_h_px), .cols = @max(1, gridWidthPx(cfg, w_px, scale) / cell_w_px) };
}

pub const State = struct {
    /// The committed view (SurfaceStore.scrollView) `update` last saw: what
    /// the pointer is tested against. Written under App.mu.
    vp: ?Viewport = null,
    /// Under App.mu: the renderer reads it.
    alpha: f32 = 0,

    target_alpha: f32 = 0,
    /// The grid the core last named; kept while it has no viewport.
    grid: i64 = 0,
    hover: bool = false,
    dragging: bool = false,
    /// Where on the knob the press landed, px from its top.
    drag_grab_px: f32 = 0,
    pending_line: i64 = -1,
    pending_use_bottom: bool = false,
    last_send_ns: i128 = 0,
    repeat_dir: i8 = 0,
    fade_timer: c_uint = 0,
    hide_timer: c_uint = 0,
    repeat_timer: c_uint = 0,
    drag_timer: c_uint = 0,
    tag: Tag = undefined,
};

pub const Geometry = struct {
    track_left: f32,
    track_top: f32,
    track_right: f32,
    track_bottom: f32,
    knob_top: f32,
    knob_bottom: f32,
    scrollable: bool,
};

/// The track at the right edge of a `w_px` x `h_px` surface and the knob in
/// it, in px.
pub fn geometry(vp: Viewport, w_px: f32, h_px: f32, scale: f32) Geometry {
    var m: core.zonvie_scrollbar_metrics = undefined;
    core.zonvie_core_scrollbar_metrics(vp.topline, vp.botline, vp.line_count, &m);
    const margin = margin_pt * scale;
    var g: Geometry = .{
        .track_left = w_px - width_pt * scale - margin,
        .track_right = w_px - margin,
        .track_top = margin,
        .track_bottom = h_px - margin,
        .knob_top = margin,
        .knob_bottom = h_px - margin,
        .scrollable = false,
    };
    const track_h = g.track_bottom - g.track_top;
    if (m.is_scrollable == 0 or track_h <= 0) return g;
    // The minimum knob is this frontend's chrome; the clamped position keeps
    // it in the track past EOF.
    const knob_h = @max(min_knob_pt * scale, track_h * @as(f32, @floatCast(m.knob_proportion)));
    g.knob_top = g.track_top + (track_h - knob_h) * @as(f32, @floatCast(m.scroll_position));
    g.knob_bottom = g.knob_top + knob_h;
    g.scrollable = true;
    return g;
}

pub const Hit = enum { none, knob, track_above, track_below };

pub fn hitTest(g: Geometry, x: f32, y: f32) Hit {
    if (!g.scrollable) return .none;
    if (x < g.track_left or x > g.track_right or y < g.track_top or y > g.track_bottom) return .none;
    if (y >= g.knob_top and y <= g.knob_bottom) return .knob;
    return if (y < g.knob_top) .track_above else .track_below;
}

/// Track and knob colours at the bar's current alpha, as Windows draws them.
pub fn colors(app: *const App, alpha: f32) struct { track: [4]f32, knob: [4]f32 } {
    const cfg = app.scrollbar_cfg;
    const a = alpha * cfg.opacity;
    const track_a: f32 = if (cfg.isAlways()) 1 else a * 0.5;
    return .{ .track = .{ 0.2, 0.2, 0.2, track_a }, .knob = .{ 0.7, 0.7, 0.7, a } };
}

/// The view the renderer draws surface `id`'s bar for, null for none.
/// Caller holds App.mu.
pub fn drawn(app: *const App, st: *const State, id: i64) ?Viewport {
    if (!app.scrollbar_cfg.enabled or st.alpha <= 0.001) return null;
    return app.surface.scrollView(id);
}

// =========================================================================
// Surfaces
// =========================================================================

const Surface = struct { st: *State, id: i64 };

/// Only the main surface exists: external windows are not built yet.
fn surface(app: *App, id: i64) ?Surface {
    if (id != 1) return null;
    return .{ .st = &app.scrollbar, .id = 1 };
}

/// The surface's geometry from its last viewport, in px.
fn surfaceGeometry(app: *App, sf: Surface) ?Geometry {
    app.mu.lockUncancelable(clock.io());
    const vp = sf.st.vp;
    const scale = app.scale;
    const w_px: f32 = @floatFromInt(app.drawable_w_px);
    const h_px: f32 = @floatFromInt(app.drawable_h_px);
    app.mu.unlock(clock.io());
    const v = vp orelse return null;
    return geometry(v, w_px, h_px, scale);
}

// =========================================================================
// Viewport updates
// =========================================================================

/// At a commit, on the core thread inside the flush (the core's grid lock
/// and App.mu held): each surface's bar takes the viewport the commit's rows
/// are of, so the frame that draws them draws the knob there too.
pub fn commitViews(app: *App) void {
    if (!app.scrollbar_cfg.enabled) return;
    const cp = app.corep orelse return;
    app.surface.main.scroll_view = viewLocked(cp, 1);
    var it = app.surface.others.iterator();
    while (it.next()) |kv| kv.value_ptr.*.scroll_view = viewLocked(cp, kv.key_ptr.*);
}

fn viewLocked(cp: *core.zonvie_core, id: i64) ?Viewport {
    const grid = core.zonvie_core_scrollbar_grid_locked(cp, id);
    var info: core.ViewportInfo = undefined;
    if (core.zonvie_core_get_viewport_locked(cp, grid, &info) != 1) return null;
    return .{ .grid = grid, .topline = info.topline, .botline = info.botline, .line_count = info.line_count };
}

/// After every committed flush: each surface's bar shows or hides for the
/// view the commit gave it. The commit's own frame draws the knob.
pub fn update(app: *App) void {
    if (!app.scrollbar_cfg.enabled or app.corep == null) return;
    updateSurface(app, 1);
    var it = app.ext_windows.keyIterator();
    while (it.next()) |id| updateSurface(app, id.*);
}

fn updateSurface(app: *App, id: i64) void {
    const sf = surface(app, id) orelse return;
    app.mu.lockUncancelable(clock.io());
    const vp = app.surface.scrollView(id);
    const prev = sf.st.vp;
    sf.st.vp = vp;
    app.mu.unlock(clock.io());
    const v = vp orelse return;
    sf.st.grid = v.grid;
    if (prev) |p| if (std.meta.eql(p, v)) return;

    var m: core.zonvie_scrollbar_metrics = undefined;
    core.zonvie_core_scrollbar_metrics(v.topline, v.botline, v.line_count, &m);
    const cfg = app.scrollbar_cfg;
    if (m.is_scrollable == 0 and !cfg.isAlways()) return hide(app, sf);
    if (cfg.isScroll() or cfg.isAlways()) show(app, sf);
}

// =========================================================================
// Fade
// =========================================================================

fn show(app: *App, sf: Surface) void {
    const st = sf.st;
    st.target_alpha = 1;
    armFade(app, sf);
    if (st.hide_timer != 0) {
        _ = glib.g_source_remove(st.hide_timer);
        st.hide_timer = 0;
    }
    const cfg = app.scrollbar_cfg;
    if (cfg.isScroll() and !cfg.isAlways()) {
        st.hide_timer = glib.g_timeout_add(@intFromFloat(cfg.delay * 1000), &onHideTimer, surfaceTag(app, sf.id));
    }
}

fn hide(app: *App, sf: Surface) void {
    if (app.scrollbar_cfg.isAlways() or sf.st.dragging) return;
    sf.st.target_alpha = 0;
    armFade(app, sf);
}

/// What a timer carries. It lives in the State, which outlives every timer
/// it arms: an external window cancels them before it frees its State.
const Tag = struct { app: *App, id: i64 };

fn surfaceTag(app: *App, id: i64) *Tag {
    const st = surface(app, id).?.st;
    st.tag = .{ .app = app, .id = id };
    return &st.tag;
}

fn armFade(app: *App, sf: Surface) void {
    if (sf.st.fade_timer != 0 or sf.st.alpha == sf.st.target_alpha) return;
    sf.st.fade_timer = glib.g_timeout_add(fade_interval_ms, &onFade, surfaceTag(app, sf.id));
}

fn onFade(data: ?*anyopaque) callconv(.c) c_int {
    const tag: *Tag = @ptrCast(@alignCast(data.?));
    const app = tag.app;
    const sf = surface(app, tag.id) orelse return 0;
    const st = sf.st;
    app.mu.lockUncancelable(clock.io());
    if (st.alpha < st.target_alpha) st.alpha = @min(st.target_alpha, st.alpha + fade_step) else st.alpha = @max(st.target_alpha, st.alpha - fade_step);
    const done = @abs(st.alpha - st.target_alpha) < 0.01;
    if (done) st.alpha = st.target_alpha;
    app.mu.unlock(clock.io());
    app.queueRenderAll();
    if (!done) {
        st.fade_timer = glib.g_timeout_add(fade_interval_ms, &onFade, surfaceTag(app, sf.id));
    } else st.fade_timer = 0;
    return 0;
}

fn onHideTimer(data: ?*anyopaque) callconv(.c) c_int {
    const tag: *Tag = @ptrCast(@alignCast(data.?));
    const sf = surface(tag.app, tag.id) orelse return 0;
    sf.st.hide_timer = 0;
    hide(tag.app, sf);
    return 0;
}

// =========================================================================
// Pointer
// =========================================================================

/// A press at logical (x, y) on surface `id`. True when the bar took it.
pub fn press(app: *App, id: i64, x: f64, y: f64) bool {
    if (!app.scrollbar_cfg.enabled) return false;
    const sf = surface(app, id) orelse return false;
    if (sf.st.alpha <= 0.001 and !app.scrollbar_cfg.isAlways()) return false;
    const g = surfaceGeometry(app, sf) orelse return false;
    const px = toPx(app, x, y);
    const hit = hitTest(g, px[0], px[1]);
    applog.appLog("[scrollbar] press surface={d} hit={s}\n", .{ id, @tagName(hit) });
    switch (hit) {
        .none => return false,
        .knob => {
            sf.st.dragging = true;
            sf.st.drag_grab_px = px[1] - g.knob_top;
        },
        .track_above, .track_below => {
            const dir: i8 = if (hit == .track_above) -1 else 1;
            pageScroll(app, sf, dir);
            sf.st.repeat_dir = dir;
            sf.st.repeat_timer = glib.g_timeout_add(repeat_delay_ms, &onRepeat, surfaceTag(app, id));
        },
    }
    show(app, sf);
    return true;
}

fn toPx(app: *App, x: f64, y: f64) [2]f32 {
    app.mu.lockUncancelable(clock.io());
    const s = app.scale;
    app.mu.unlock(clock.io());
    return .{ @as(f32, @floatCast(x)) * s, @as(f32, @floatCast(y)) * s };
}

fn pageScroll(app: *App, sf: Surface, dir: i8) void {
    const cp = app.corep orelse return;
    core.zonvie_core_page_scroll(cp, if (sf.st.grid != 0) sf.st.grid else sf.id, dir > 0);
}

fn onRepeat(data: ?*anyopaque) callconv(.c) c_int {
    const tag: *Tag = @ptrCast(@alignCast(data.?));
    const sf = surface(tag.app, tag.id) orelse return 0;
    if (sf.st.repeat_dir == 0) {
        sf.st.repeat_timer = 0;
        return 0;
    }
    pageScroll(tag.app, sf, sf.st.repeat_dir);
    sf.st.repeat_timer = glib.g_timeout_add(repeat_interval_ms, &onRepeat, surfaceTag(tag.app, tag.id));
    return 0;
}

/// Pointer motion at logical (x, y). True when a knob drag consumed it.
pub fn motion(app: *App, id: i64, x: f64, y: f64) bool {
    if (!app.scrollbar_cfg.enabled) return false;
    const sf = surface(app, id) orelse return false;
    const px = toPx(app, x, y);
    if (!sf.st.dragging) {
        hover(app, sf, px);
        return false;
    }
    const g = surfaceGeometry(app, sf) orelse return true;
    const vp = sf.st.vp orelse return true;
    const knob_travel = (g.track_bottom - g.track_top) - (g.knob_bottom - g.knob_top);
    if (!g.scrollable or knob_travel <= 0) return true;
    const ratio = std.math.clamp((px[1] - g.track_top - sf.st.drag_grab_px) / knob_travel, 0, 1);
    var drag: core.zonvie_scrollbar_drag_target = undefined;
    core.zonvie_core_scrollbar_drag_target(ratio, vp.topline, vp.botline, vp.line_count, &drag);
    sf.st.pending_line = drag.line;
    sf.st.pending_use_bottom = drag.use_bottom != 0;
    const now = clock.nowNs();
    const wait_ns = drag_throttle_ns - (now - sf.st.last_send_ns);
    if (wait_ns > 0) {
        // A trailing send, so a pause mid-drag lands where the knob is.
        if (sf.st.drag_timer == 0) sf.st.drag_timer = glib.g_timeout_add(@intCast(@divTrunc(wait_ns, std.time.ns_per_ms) + 1), &onDragFlush, surfaceTag(app, id));
        return true;
    }
    flushDrag(app, sf);
    return true;
}

fn flushDrag(app: *App, sf: Surface) void {
    if (sf.st.pending_line < 0) return;
    const cp = app.corep orelse return;
    core.zonvie_core_scroll_to_line(cp, if (sf.st.grid != 0) sf.st.grid else sf.id, sf.st.pending_line, sf.st.pending_use_bottom);
    sf.st.last_send_ns = clock.nowNs();
    sf.st.pending_line = -1;
}

fn onDragFlush(data: ?*anyopaque) callconv(.c) c_int {
    const tag: *Tag = @ptrCast(@alignCast(data.?));
    const sf = surface(tag.app, tag.id) orelse return 0;
    sf.st.drag_timer = 0;
    if (sf.st.dragging) flushDrag(tag.app, sf);
    return 0;
}

/// The press the bar took is released. True when it was the bar's.
pub fn release(app: *App, id: i64) bool {
    const sf = surface(app, id) orelse return false;
    const st = sf.st;
    const was = st.dragging or st.repeat_dir != 0;
    if (st.dragging) {
        flushDrag(app, sf);
        st.dragging = false;
        // An auto-hide that fired mid-drag was skipped; re-arm it.
        if (app.scrollbar_cfg.isScroll()) show(app, sf);
    }
    st.repeat_dir = 0;
    if (st.repeat_timer != 0) {
        _ = glib.g_source_remove(st.repeat_timer);
        st.repeat_timer = 0;
    }
    return was;
}

/// Hover mode: shown while the pointer is over the track.
fn hover(app: *App, sf: Surface, px: [2]f32) void {
    const cfg = app.scrollbar_cfg;
    if (!cfg.isHover()) return;
    const g = surfaceGeometry(app, sf) orelse return;
    const in_track = hitTest(g, px[0], px[1]) != .none;
    if (in_track and !sf.st.hover) {
        sf.st.hover = true;
        show(app, sf);
    } else if (in_track and cfg.isScroll()) {
        show(app, sf);
    } else if (!in_track and sf.st.hover) {
        leave(app, sf.id);
    }
}

/// The pointer left the surface.
pub fn leave(app: *App, id: i64) void {
    const sf = surface(app, id) orelse return;
    if (!sf.st.hover) return;
    sf.st.hover = false;
    const cfg = app.scrollbar_cfg;
    if (!cfg.isAlways() and !cfg.isScroll()) hide(app, sf);
}

/// An external window closes: its timers must not outlive it.
pub fn cancelTimers(st: *State) void {
    for ([_]*c_uint{ &st.fade_timer, &st.hide_timer, &st.repeat_timer, &st.drag_timer }) |t| {
        if (t.* != 0) _ = glib.g_source_remove(t.*);
        t.* = 0;
    }
}

const testing = std.testing;

test "the knob spans the visible share of the track and stays in it past EOF" {
    const g = geometry(.{ .topline = 0, .botline = 50, .line_count = 100 }, 800, 604, 1);
    try testing.expect(g.scrollable);
    try testing.expectEqual(@as(f32, 800 - 12 - 2), g.track_left);
    try testing.expectEqual(@as(f32, 2), g.knob_top);
    try testing.expectEqual(@as(f32, 2 + 300), g.knob_bottom);
    const past = geometry(.{ .topline = 99, .botline = 100, .line_count = 100 }, 800, 604, 1);
    try testing.expect(past.knob_bottom <= past.track_bottom);
    try testing.expect(!geometry(.{ .topline = 0, .botline = 10, .line_count = 10 }, 800, 600, 1).scrollable);
}

test "a press finds the knob or the track either side of it" {
    const g = geometry(.{ .topline = 25, .botline = 50, .line_count = 100 }, 800, 604, 1);
    try testing.expectEqual(Hit.knob, hitTest(g, 790, (g.knob_top + g.knob_bottom) / 2));
    try testing.expectEqual(Hit.track_above, hitTest(g, 790, g.knob_top - 5));
    try testing.expectEqual(Hit.track_below, hitTest(g, 790, g.knob_bottom + 5));
    try testing.expectEqual(Hit.none, hitTest(g, 400, 300));
}

test "the column layout takes the track's strip off the grid, the overlay nothing" {
    var cfg: core.config.Config.ScrollbarConfig = .{ .enabled = true, .layout = .column };
    // (12 + 2 * 2) pt at scale 2.
    try std.testing.expectEqual(@as(u32, 32), columnStripPx(cfg, 2));
    try std.testing.expectEqual(@as(u32, 768), gridWidthPx(cfg, 800, 2));
    try std.testing.expectEqual(@as(u32, 1), gridWidthPx(cfg, 20, 2));
    cfg.layout = .overlay;
    try std.testing.expectEqual(@as(u32, 800), gridWidthPx(cfg, 800, 2));
    cfg = .{ .enabled = false, .layout = .column };
    try std.testing.expectEqual(@as(u32, 0), columnStripPx(cfg, 2));
}

test "a surface's grid is whole cells of what the strip leaves, at least one" {
    var cfg: core.config.Config.ScrollbarConfig = .{ .enabled = true, .layout = .column };
    // 800 px less the 32 px strip is 768 px: 76 cells of 10, 21 rows of 19.
    try std.testing.expectEqual(Grid{ .rows = 21, .cols = 76 }, gridFor(cfg, 800, 400, 10, 19, 2));
    try std.testing.expectEqual(Grid{ .rows = 1, .cols = 1 }, gridFor(cfg, 20, 5, 10, 19, 2));
    cfg.layout = .overlay;
    try std.testing.expectEqual(Grid{ .rows = 21, .cols = 80 }, gridFor(cfg, 800, 400, 10, 19, 2));
}
