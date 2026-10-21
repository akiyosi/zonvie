//! Float peel: which hosted float hides the cursor, and how far it is curled
//! back to show what lies under the cursor.
//!
//! The curl is a flat fold. `corner` is the float corner nearest the cursor,
//! `dir` the unit vector from it toward the cursor, and every float pixel `p`
//! with `dot(p - corner, dir) < fold_px` is folded over the fold line, so the
//! anchor shows through there. `fold_px` eases toward a target that clears the
//! cursor cell by `margin_cells`, both when peeling and when restoring.
//! The corner follows the cursor across either of the float's midpoints: the
//! float is restored, then peeled again from the other corner.
//!
//! A click on the peeled float (or its flap) restores it and keeps it down
//! while the cursor stays under it; the click itself still goes to the float.
//!
//! Pure: no core pointer, no lock. Frontends call `frame` once per frame with
//! the surface's layer list and the cursor, then draw from the result.

const std = @import("std");
const c_api = @import("c_api.zig");
const scroll_ease = @import("scroll_ease.zig");
const cursor_rect = @import("cursor_rect.zig");

const Layer = c_api.Layer;

/// How far past the cursor cell the fold goes, in cell heights.
pub const margin_cells: f32 = 1.0;

/// Layout must match `zonvie_float_peel` in include/zonvie_frontend.h.
pub const Peel = extern struct {
    /// Grid being curled (peeling or restoring), 0 when none.
    grid_id: i64 = 0,
    corner_x_px: f32 = 0,
    corner_y_px: f32 = 0,
    dir_x: f32 = 0,
    dir_y: f32 = 0,
    target_px: f32 = 0,
    /// Non-zero after a click on the peeled float: held restored until the
    /// cursor leaves it.
    dismissed: u32 = 0,
    /// Eases `fold_px - target_px` to zero.
    spring: scroll_ease.Spring = .{},
    /// Surface rows the last drawn curl covered; empty when equal.
    last_top_px: i32 = 0,
    last_bottom_px: i32 = 0,

    pub fn foldPx(self: *const Peel) f32 {
        return @max(0, self.target_px + @as(f32, @floatCast(self.spring.offset_px)));
    }

    /// Whether the frontend must keep drawing frames.
    pub fn moving(self: *const Peel) bool {
        return self.spring.moving();
    }

    /// Start over on `grid_id`, keeping what the last frame drew.
    fn reset(self: *Peel, grid_id: i64) void {
        self.* = .{ .grid_id = grid_id, .last_top_px = self.last_top_px, .last_bottom_px = self.last_bottom_px };
    }

    /// Move the target while keeping the current fold where it is.
    fn retarget(self: *Peel, target_px: f32) void {
        self.spring.offset_px += self.target_px - target_px;
        self.target_px = target_px;
    }
};

pub const Rect = struct { x0: f32, y0: f32, x1: f32, y1: f32 };

fn layerRect(l: Layer, cell_w: f32, cell_h: f32) Rect {
    const x0: f32 = @floatFromInt(l.x_px);
    const y0: f32 = @floatFromInt(l.y_px);
    return .{
        .x0 = x0,
        .y0 = y0,
        .x1 = x0 + @as(f32, @floatFromInt(l.cols)) * cell_w,
        .y1 = y0 + @as(f32, @floatFromInt(l.rows)) * cell_h,
    };
}

const Target = struct { grid_id: i64, float: Rect };

/// The float's rect grown to hold its flap: each corner on the folded side,
/// mirrored across the fold line. The flap is the mirror of a convex polygon
/// whose other vertices lie on the line, so these bound it.
pub fn bounds(p: *const Peel, float: Rect) Rect {
    var r = float;
    const fold = p.foldPx();
    inline for (.{ .{ float.x0, float.y0 }, .{ float.x1, float.y0 }, .{ float.x0, float.y1 }, .{ float.x1, float.y1 } }) |c| {
        const s = dot(c[0], c[1], p);
        if (s < fold) {
            const mx = c[0] + 2 * (fold - s) * p.dir_x;
            const my = c[1] + 2 * (fold - s) * p.dir_y;
            r.x0 = @min(r.x0, mx);
            r.y0 = @min(r.y0, my);
            r.x1 = @max(r.x1, mx);
            r.y1 = @max(r.y1, my);
        }
    }
    return r;
}

fn contains(r: Rect, x: f32, y: f32) bool {
    return x >= r.x0 and x < r.x1 and y >= r.y0 and y < r.y1;
}

/// The corner the cursor peels from: the float corner on the cursor's side
/// of both midpoints.
fn corner(float: Rect, cursor: Rect) [2]f32 {
    const cx = (cursor.x0 + cursor.x1) / 2;
    const cy = (cursor.y0 + cursor.y1) / 2;
    return .{
        if (cx - float.x0 <= float.x1 - cx) float.x0 else float.x1,
        if (cy - float.y0 <= float.y1 - cy) float.y0 else float.y1,
    };
}

/// The topmost float painted above the cursor's own layer whose rect holds
/// the cursor cell's centre.
fn select(layers: []const Layer, cursor: Rect, cursor_layer: usize, cell_w: f32, cell_h: f32) ?Target {
    const cx = (cursor.x0 + cursor.x1) / 2;
    const cy = (cursor.y0 + cursor.y1) / 2;
    var i = layers.len;
    while (i > cursor_layer + 1) {
        i -= 1;
        const l = layers[i];
        if (l.flags & c_api.LAYER_FLOAT == 0) continue;
        const r = layerRect(l, cell_w, cell_h);
        if (contains(r, cx, cy)) return .{ .grid_id = l.grid_id, .float = r };
    }
    return null;
}

fn dot(px: f32, py: f32, p: *const Peel) f32 {
    return (px - p.corner_x_px) * p.dir_x + (py - p.corner_y_px) * p.dir_y;
}

/// Aim `p.dir` at the cursor from `p.corner` and return the fold distance
/// that clears the cursor cell, capped where the whole float is folded.
fn aim(p: *Peel, float: Rect, cursor: Rect, margin_px: f32) f32 {
    const dx = (cursor.x0 + cursor.x1) / 2 - p.corner_x_px;
    const dy = (cursor.y0 + cursor.y1) / 2 - p.corner_y_px;
    const len = @sqrt(dx * dx + dy * dy);
    p.dir_x = dx / len;
    p.dir_y = dy / len;
    var need: f32 = 0;
    var full: f32 = 0;
    inline for (.{ .{ cursor.x0, cursor.y0 }, .{ cursor.x1, cursor.y0 }, .{ cursor.x0, cursor.y1 }, .{ cursor.x1, cursor.y1 } }) |c| need = @max(need, dot(c[0], c[1], p));
    inline for (.{ .{ float.x0, float.y0 }, .{ float.x1, float.y0 }, .{ float.x0, float.y1 }, .{ float.x1, float.y1 } }) |c| full = @max(full, dot(c[0], c[1], p));
    return @min(need + margin_px, full);
}

fn startOn(p: *Peel, t: Target, cursor: Rect, margin_px: f32) void {
    p.reset(t.grid_id);
    const c = corner(t.float, cursor);
    p.corner_x_px = c[0];
    p.corner_y_px = c[1];
    p.target_px = aim(p, t.float, cursor, margin_px);
    // Start folded by nothing and ease out to the target.
    p.spring.offset_px = -p.target_px;
}

/// Advance `p` to `now_ns` for one surface. `cursor` is the cursor's box in
/// surface px, null when the cursor is not on this surface; `cursor_grid` is
/// the grid that owns it. `click` is a mouse press this frame, in surface px.
/// Returns whether the peel is still animating.
pub fn update(
    p: *Peel,
    layers: []const Layer,
    cursor_grid: i64,
    cursor_box: ?cursor_rect.Rect,
    click: ?[2]f32,
    cell_w_px: u32,
    cell_h_px: u32,
    now_ns: i64,
) bool {
    const cw: f32 = @floatFromInt(@max(cell_w_px, 1));
    const ch: f32 = @floatFromInt(@max(cell_h_px, 1));
    const margin_px = margin_cells * ch;
    p.spring.tick(now_ns);

    var cursor: Rect = undefined;
    var want: ?Target = null;
    if (cursor_box) |b| {
        cursor = .{ .x0 = b.left, .y0 = b.top, .x1 = b.right, .y1 = b.bottom };
        for (layers, 0..) |l, i| {
            if (l.grid_id != cursor_grid) continue;
            want = select(layers, cursor, i, cw, ch);
            break;
        }
    }

    // The curled float closed or left the surface: nothing to restore.
    var cur: ?Rect = null;
    for (layers) |l| {
        if (p.grid_id != 0 and l.grid_id == p.grid_id) cur = layerRect(l, cw, ch);
    }
    if (cur) |r| {
        if (click) |c| {
            if (contains(bounds(p, r), c[0], c[1])) p.dismissed = 1;
        }
    } else p.reset(0);

    if (want) |w| {
        if (w.grid_id == p.grid_id) {
            if (p.dismissed != 0) {
                p.retarget(0);
            } else if (!std.meta.eql(corner(w.float, cursor), [2]f32{ p.corner_x_px, p.corner_y_px })) {
                // The cursor crossed a midpoint: restore, then peel from
                // the other corner.
                if (p.foldPx() < 0.5) startOn(p, w, cursor, margin_px) else p.retarget(0);
            } else {
                p.retarget(aim(p, w.float, cursor, margin_px));
            }
        } else if (p.grid_id == 0 or p.foldPx() < 0.5) {
            startOn(p, w, cursor, margin_px);
        } else {
            // Another float hides the cursor: restore this one first.
            p.retarget(0);
        }
    } else if (p.grid_id != 0) {
        p.dismissed = 0;
        p.retarget(0);
    }

    if (p.grid_id != 0 and p.dismissed == 0 and p.target_px == 0 and !p.moving()) p.reset(0);
    return p.moving();
}

/// What a frontend draws this frame. Layout must match
/// `zonvie_float_peel_frame` in include/zonvie_frontend.h.
pub const Frame = extern struct {
    /// Float to curl, 0 for none: drawn by the peel pass instead of in place.
    grid_id: i64 = 0,
    float_px: cursor_rect.Rect = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 },
    /// `float_px` grown to hold the flap: the curl pass's scissor.
    bounds_px: cursor_rect.Rect = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 },
    corner_x_px: f32 = 0,
    corner_y_px: f32 = 0,
    dir_x: f32 = 0,
    dir_y: f32 = 0,
    fold_px: f32 = 0,
    /// Surface rows every layer redraws under the curl, empty when equal:
    /// the curl is blended into the retained back buffer, so these rows hold
    /// the last frame's. They include the last curl's on the frame it moves.
    redraw_top_px: i32 = 0,
    redraw_bottom_px: i32 = 0,
    /// The curl differs from the last frame's: draw a frame even without
    /// other damage.
    changed: bool = false,
    /// Still animating: schedule another frame.
    moving: bool = false,
};

/// `update`, then what to draw: the curled float's rect and bounds, and the
/// rows to redraw. `layers[i]` origins are surface px; a float spans
/// `cols * cell_w_px` by `rows * cell_h_px`.
pub fn frame(
    p: *Peel,
    layers: []const Layer,
    cursor_grid: i64,
    cursor_box: ?cursor_rect.Rect,
    click: ?[2]f32,
    cell_w_px: u32,
    cell_h_px: u32,
    now_ns: i64,
) Frame {
    const was_grid = p.grid_id;
    const prev_fold = p.foldPx();
    var f: Frame = .{ .moving = update(p, layers, cursor_grid, cursor_box, click, cell_w_px, cell_h_px, now_ns) };
    f.changed = f.moving or was_grid != p.grid_id or prev_fold != p.foldPx();

    var top: i32 = 0;
    var bottom: i32 = 0;
    if (p.grid_id != 0) {
        for (layers) |l| {
            if (l.grid_id != p.grid_id) continue;
            const r = layerRect(l, @floatFromInt(@max(cell_w_px, 1)), @floatFromInt(@max(cell_h_px, 1)));
            const b = bounds(p, r);
            f.grid_id = p.grid_id;
            f.float_px = .{ .left = r.x0, .top = r.y0, .right = r.x1, .bottom = r.y1 };
            f.bounds_px = .{ .left = b.x0, .top = b.y0, .right = b.x1, .bottom = b.y1 };
            f.corner_x_px = p.corner_x_px;
            f.corner_y_px = p.corner_y_px;
            f.dir_x = p.dir_x;
            f.dir_y = p.dir_y;
            f.fold_px = p.foldPx();
            top = @intFromFloat(@floor(b.y0));
            bottom = @intFromFloat(@ceil(b.y1));
            break;
        }
    }
    f.redraw_top_px = top;
    f.redraw_bottom_px = bottom;
    if (p.last_bottom_px > p.last_top_px and (f.changed or f.grid_id == 0)) {
        if (bottom > top) {
            f.redraw_top_px = @min(top, p.last_top_px);
            f.redraw_bottom_px = @max(bottom, p.last_bottom_px);
        } else {
            f.redraw_top_px = p.last_top_px;
            f.redraw_bottom_px = p.last_bottom_px;
        }
        f.changed = true;
    }
    p.last_top_px = top;
    p.last_bottom_px = bottom;
    return f;
}

// ---------------------------------------------------------------- tests

const testing = std.testing;
const test_cw = 10;
const test_ch = 20;

fn root(rows: u32, cols: u32) Layer {
    return .{ .grid_id = 2, .anchor_grid = 1, .x_px = 0, .y_px = 0, .rows = rows, .cols = cols, .z = 0, .flags = c_api.LAYER_MOUSE_ENABLED };
}

fn floatLayer(id: i64, row: i32, col: i32, rows: u32, cols: u32, z: i32) Layer {
    return .{ .grid_id = id, .anchor_grid = 2, .x_px = col * test_cw, .y_px = row * test_ch, .rows = rows, .cols = cols, .z = z, .flags = c_api.LAYER_FLOAT };
}

/// The box of cell (row, col) of `grid` placed at `layers`, in surface px.
fn cellBox(layers: []const Layer, grid: i64, row: i32, col: i32) ?cursor_rect.Rect {
    for (layers) |l| {
        if (l.grid_id != grid) continue;
        const x: f32 = @floatFromInt(l.x_px + col * test_cw);
        const y: f32 = @floatFromInt(l.y_px + row * test_ch);
        return .{ .left = x, .top = y, .right = x + test_cw, .bottom = y + test_ch };
    }
    return null;
}

fn step(p: *Peel, layers: []const Layer, grid: i64, row: i32, col: i32, t: i64) bool {
    return update(p, layers, grid, cellBox(layers, grid, row, col), null, test_cw, test_ch, t);
}

/// Tick until the spring settles, returning the number of 16 ms frames.
fn settle(p: *Peel, layers: []const Layer, grid: i64, row: i32, col: i32, t0: i64) usize {
    var n: usize = 0;
    var t = t0;
    while (step(p, layers, grid, row, col, t)) : (n += 1) {
        t += 16 * std.time.ns_per_ms;
        if (n > 1000) break;
    }
    return n;
}

test "a float over the cursor peels from its nearest corner past the cursor cell" {
    const layers = [_]Layer{ root(40, 80), floatLayer(5, 10, 20, 10, 30, 1) };
    var p: Peel = .{};
    // Cursor at row 11, col 22: just inside the float's top-left.
    try testing.expect(step(&p, &layers, 2, 11, 22, 1));
    try testing.expectEqual(@as(i64, 5), p.grid_id);
    try testing.expectEqual(@as(f32, 200), p.corner_x_px);
    try testing.expectEqual(@as(f32, 200), p.corner_y_px);
    try testing.expectEqual(@as(f32, 0), p.foldPx());
    _ = settle(&p, &layers, 2, 11, 22, 2);
    // The cell's far corner (230, 240) projects past the fold minus margin.
    const far = dot(230, 240, &p);
    try testing.expect(p.foldPx() >= far + margin_cells * test_ch - 1);
}

test "no peel when the cursor is outside every float, or inside the float itself" {
    const layers = [_]Layer{ root(40, 80), floatLayer(5, 10, 20, 10, 30, 1) };
    var p: Peel = .{};
    try testing.expect(!step(&p, &layers, 2, 0, 0, 1));
    try testing.expectEqual(@as(i64, 0), p.grid_id);
    try testing.expect(!step(&p, &layers, 5, 1, 1, 2));
    try testing.expectEqual(@as(i64, 0), p.grid_id);
}

test "a split is never peeled, only a float" {
    var split = floatLayer(5, 10, 20, 10, 30, 1);
    split.flags = c_api.LAYER_MOUSE_ENABLED;
    const layers = [_]Layer{ root(40, 80), split };
    var p: Peel = .{};
    try testing.expect(!step(&p, &layers, 2, 11, 22, 1));
    try testing.expectEqual(@as(i64, 0), p.grid_id);
}

test "the topmost of two stacked floats is the one peeled" {
    const layers = [_]Layer{ root(40, 80), floatLayer(5, 10, 20, 10, 30, 1), floatLayer(6, 8, 18, 6, 10, 2) };
    var p: Peel = .{};
    _ = step(&p, &layers, 2, 11, 22, 1);
    try testing.expectEqual(@as(i64, 6), p.grid_id);
}

test "a cursor in a float peels only the floats painted above it" {
    const layers = [_]Layer{ root(40, 80), floatLayer(5, 10, 20, 10, 30, 1), floatLayer(6, 8, 18, 6, 10, 2) };
    var p: Peel = .{};
    // Grid 5's cell (1, 2) is surface (11, 22), under grid 6.
    _ = step(&p, &layers, 5, 1, 2, 1);
    try testing.expectEqual(@as(i64, 6), p.grid_id);
    // Grid 6's own cursor has nothing above it.
    var q: Peel = .{};
    _ = step(&q, &layers, 6, 1, 1, 1);
    try testing.expectEqual(@as(i64, 0), q.grid_id);
}

test "leaving the float restores it with an animation, then clears" {
    const layers = [_]Layer{ root(40, 80), floatLayer(5, 10, 20, 10, 30, 1) };
    var p: Peel = .{};
    _ = settle(&p, &layers, 2, 11, 22, 1);
    const peeled = p.foldPx();
    try testing.expect(peeled > 0);
    try testing.expect(step(&p, &layers, 2, 0, 0, 2_000_000_000));
    try testing.expectEqual(@as(i64, 5), p.grid_id);
    // The first tick after rest integrates nothing (scroll_ease.Spring).
    try testing.expect(step(&p, &layers, 2, 0, 0, 2_016_000_000));
    try testing.expect(step(&p, &layers, 2, 0, 0, 2_032_000_000));
    try testing.expect(p.foldPx() < peeled);
    _ = settle(&p, &layers, 2, 0, 0, 2_048_000_000);
    try testing.expectEqual(@as(i64, 0), p.grid_id);
    try testing.expectEqual(@as(f32, 0), p.foldPx());
}

test "a deeper cursor lifts the float further, without a jump" {
    const layers = [_]Layer{ root(40, 80), floatLayer(5, 10, 20, 10, 30, 1) };
    var p: Peel = .{};
    _ = settle(&p, &layers, 2, 11, 22, 1);
    const shallow = p.foldPx();
    _ = step(&p, &layers, 2, 13, 26, 2_000_000_000);
    try testing.expect(p.target_px > shallow);
    try testing.expect(@abs(p.foldPx() - shallow) < 0.01);
    _ = settle(&p, &layers, 2, 13, 26, 2_016_000_000);
    try testing.expect(p.foldPx() > shallow);
}

test "switching floats restores the first before peeling the second" {
    const layers = [_]Layer{ root(40, 80), floatLayer(5, 10, 20, 10, 30, 1), floatLayer(6, 30, 0, 5, 10, 2) };
    var p: Peel = .{};
    _ = settle(&p, &layers, 2, 11, 22, 1);
    _ = step(&p, &layers, 2, 31, 1, 2_000_000_000);
    try testing.expectEqual(@as(i64, 5), p.grid_id);
    try testing.expectEqual(@as(f32, 0), p.target_px);
    _ = settle(&p, &layers, 2, 31, 1, 2_016_000_000);
    try testing.expectEqual(@as(i64, 6), p.grid_id);
    try testing.expect(p.foldPx() > 0);
}

test "a closed float drops the peel at once" {
    const two = [_]Layer{ root(40, 80), floatLayer(5, 10, 20, 10, 30, 1) };
    const one = [_]Layer{root(40, 80)};
    var p: Peel = .{};
    _ = settle(&p, &two, 2, 11, 22, 1);
    try testing.expect(!step(&p, &one, 2, 11, 22, 2_000_000_000));
    try testing.expectEqual(@as(i64, 0), p.grid_id);
}

test "a cursor that leaves the surface restores the peel" {
    const layers = [_]Layer{ root(40, 80), floatLayer(5, 10, 20, 10, 30, 1) };
    var p: Peel = .{};
    _ = settle(&p, &layers, 2, 11, 22, 1);
    try testing.expect(update(&p, &layers, 2, null, null, test_cw, test_ch, 2_000_000_000));
    try testing.expectEqual(@as(f32, 0), p.target_px);
}

test "the flap's bounds reach past the float" {
    const layers = [_]Layer{ root(40, 80), floatLayer(5, 10, 20, 10, 30, 1) };
    var p: Peel = .{};
    _ = settle(&p, &layers, 2, 11, 22, 1);
    const b = bounds(&p, layerRect(layers[1], test_cw, test_ch));
    // Peeled from the top-left corner: that corner's mirror bounds the flap.
    const fold = p.foldPx();
    const mx = 200 + 2 * fold * p.dir_x;
    const my = 200 + 2 * fold * p.dir_y;
    try testing.expect(b.x1 >= mx - 0.01 and b.y1 >= my - 0.01);
    try testing.expectEqual(@as(f32, 200), b.x0);
    try testing.expectEqual(@as(f32, 200), b.y0);
}

test "a flap folded past the float's edge widens the bounds" {
    // A one-row float peeled from its top-left toward a cursor two cells in:
    // the bottom-left corner mirrors below the float.
    const layers = [_]Layer{ root(40, 80), floatLayer(5, 10, 20, 1, 30, 1) };
    var p: Peel = .{};
    _ = settle(&p, &layers, 2, 10, 22, 1);
    const b = bounds(&p, layerRect(layers[1], test_cw, test_ch));
    try testing.expect(b.y1 > 220);
}

test "crossing the float's midpoint restores, then peels from the other side" {
    const layers = [_]Layer{ root(40, 80), floatLayer(5, 10, 20, 10, 30, 1) };
    var p: Peel = .{};
    _ = settle(&p, &layers, 2, 11, 22, 1);
    try testing.expectEqual(@as(f32, 200), p.corner_x_px);
    // Col 40 is past the midpoint of cols 20..50.
    _ = step(&p, &layers, 2, 11, 40, 2_000_000_000);
    try testing.expectEqual(@as(f32, 200), p.corner_x_px);
    try testing.expectEqual(@as(f32, 0), p.target_px);
    _ = settle(&p, &layers, 2, 11, 40, 2_016_000_000);
    try testing.expectEqual(@as(i64, 5), p.grid_id);
    try testing.expectEqual(@as(f32, 500), p.corner_x_px);
    try testing.expect(p.foldPx() > 0);
}

test "a click on the peeled float restores it until the cursor leaves" {
    const layers = [_]Layer{ root(40, 80), floatLayer(5, 10, 20, 10, 30, 1) };
    var p: Peel = .{};
    _ = settle(&p, &layers, 2, 11, 22, 1);
    // A click outside it changes nothing.
    _ = update(&p, &layers, 2, cellBox(&layers, 2, 11, 22), .{ 5, 5 }, test_cw, test_ch, 2_000_000_000);
    try testing.expectEqual(@as(u32, 0), p.dismissed);
    _ = update(&p, &layers, 2, cellBox(&layers, 2, 11, 22), .{ 400, 300 }, test_cw, test_ch, 2_016_000_000);
    try testing.expectEqual(@as(u32, 1), p.dismissed);
    try testing.expectEqual(@as(f32, 0), p.target_px);
    // Still under the float: it stays down, and is kept, not cleared.
    _ = settle(&p, &layers, 2, 11, 23, 2_032_000_000);
    try testing.expectEqual(@as(i64, 5), p.grid_id);
    try testing.expectEqual(@as(f32, 0), p.foldPx());
    // Leaving clears the hold; coming back peels again.
    _ = settle(&p, &layers, 2, 0, 0, 4_000_000_000);
    try testing.expectEqual(@as(i64, 0), p.grid_id);
    _ = settle(&p, &layers, 2, 11, 22, 6_000_000_000);
    try testing.expect(p.foldPx() > 0);
}

test "crossing the float's vertical midpoint switches to a bottom corner" {
    const layers = [_]Layer{ root(40, 80), floatLayer(5, 10, 20, 10, 30, 1) };
    var p: Peel = .{};
    _ = settle(&p, &layers, 2, 11, 22, 1);
    try testing.expectEqual(@as(f32, 200), p.corner_y_px);
    // Row 18 is past the midpoint of rows 10..20.
    _ = step(&p, &layers, 2, 18, 22, 2_000_000_000);
    try testing.expectEqual(@as(f32, 0), p.target_px);
    _ = settle(&p, &layers, 2, 18, 22, 2_016_000_000);
    try testing.expectEqual(@as(f32, 200), p.corner_x_px);
    try testing.expectEqual(@as(f32, 400), p.corner_y_px);
    try testing.expect(p.foldPx() > 0);
}

test "a frame redraws the curl's rows, and the last curl's on the frame it ends" {
    const two = [_]Layer{ root(40, 80), floatLayer(5, 10, 20, 10, 30, 1) };
    const one = [_]Layer{root(40, 80)};
    var p: Peel = .{};
    var t: i64 = 1;
    var f = frame(&p, &two, 2, cellBox(&two, 2, 11, 22), null, test_cw, test_ch, t);
    while (f.moving) : (t += 16 * std.time.ns_per_ms) f = frame(&p, &two, 2, cellBox(&two, 2, 11, 22), null, test_cw, test_ch, t);
    try testing.expectEqual(@as(i64, 5), f.grid_id);
    try testing.expectEqual(@as(i32, 200), f.redraw_top_px);
    try testing.expect(f.redraw_bottom_px >= 400);
    // At rest the rows are still owed, but no frame is.
    f = frame(&p, &two, 2, cellBox(&two, 2, 11, 22), null, test_cw, test_ch, t + 1);
    try testing.expect(!f.changed);
    try testing.expect(f.redraw_bottom_px > f.redraw_top_px);
    const last_bottom = f.redraw_bottom_px;
    // Closed: nothing to curl, but the rows it covered are redrawn once.
    f = frame(&p, &one, 2, cellBox(&one, 2, 11, 22), null, test_cw, test_ch, t + 2);
    try testing.expectEqual(@as(i64, 0), f.grid_id);
    try testing.expect(f.changed);
    try testing.expectEqual(@as(i32, 200), f.redraw_top_px);
    try testing.expectEqual(last_bottom, f.redraw_bottom_px);
    f = frame(&p, &one, 2, cellBox(&one, 2, 11, 22), null, test_cw, test_ch, t + 3);
    try testing.expect(!f.changed);
    try testing.expectEqual(f.redraw_top_px, f.redraw_bottom_px);
}
