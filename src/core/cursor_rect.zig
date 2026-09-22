//! The cursor's rectangle on a surface, from the grid-local vertices the core
//! emits for it.
//!
//! Both frontends had this written out, and the Windows main driver twice in
//! one function (an integer rectangle for present damage and a float one for
//! the shader uniform). Two answers is one too many: the damage rectangle and
//! the shader rectangle describe the same cursor, so they come from the same
//! bounds and differ only by the inflation the damage consumer needs.
//!
//! Stateless. A frontend passes the vertices, the origin that places the
//! cursor's grid on the surface (a layer's origin plus any viewport offset),
//! and gets pixels back.

const std = @import("std");

/// Bounds in surface pixels, y down, edges exclusive on the right and bottom.
pub const Rect = extern struct {
    left: f32,
    top: f32,
    right: f32,
    bottom: f32,

    pub fn width(self: Rect) f32 {
        return self.right - self.left;
    }

    pub fn height(self: Rect) f32 {
        return self.bottom - self.top;
    }
};

/// The whole pixels a `Rect` touches, clipped to a surface.
pub const IntRect = extern struct {
    left: i32,
    top: i32,
    right: i32,
    bottom: i32,
};

/// The bounding box of the cursor's vertices, translated by `origin`. Null
/// for no vertices. `V` is any vertex type with `position: [2]f32`, so the
/// core's and a test's vertex layouts both serve.
pub fn bounds(comptime V: type, verts: []const V, origin_x: f32, origin_y: f32) ?Rect {
    if (verts.len == 0) return null;
    var min_x = verts[0].position[0];
    var max_x = min_x;
    var min_y = verts[0].position[1];
    var max_y = min_y;
    for (verts[1..]) |v| {
        if (v.position[0] < min_x) min_x = v.position[0];
        if (v.position[0] > max_x) max_x = v.position[0];
        if (v.position[1] < min_y) min_y = v.position[1];
        if (v.position[1] > max_y) max_y = v.position[1];
    }
    return .{
        .left = origin_x + min_x,
        .top = origin_y + min_y,
        .right = origin_x + max_x,
        .bottom = origin_y + max_y,
    };
}

/// Inflate to whole pixels (floor the near edges, ceil the far ones) and clip
/// to a `clip_w` by `clip_h` surface. Null when nothing is left inside it: a
/// damage consumer must not be handed an empty rectangle, which some presenters
/// read as "everything".
pub fn inflateClip(r: Rect, clip_w: i32, clip_h: i32) ?IntRect {
    var l: i32 = @intFromFloat(@floor(r.left));
    var t: i32 = @intFromFloat(@floor(r.top));
    var rt: i32 = @intFromFloat(@ceil(r.right));
    var b: i32 = @intFromFloat(@ceil(r.bottom));
    if (l < 0) l = 0;
    if (t < 0) t = 0;
    if (rt > clip_w) rt = clip_w;
    if (b > clip_h) b = clip_h;
    if (rt <= l or b <= t) return null;
    return .{ .left = l, .top = t, .right = rt, .bottom = b };
}

const TestVertex = struct { position: [2]f32 };

fn quad(x0: f32, y0: f32, x1: f32, y1: f32) [6]TestVertex {
    return .{
        .{ .position = .{ x0, y0 } }, .{ .position = .{ x1, y0 } }, .{ .position = .{ x1, y1 } },
        .{ .position = .{ x0, y0 } }, .{ .position = .{ x1, y1 } }, .{ .position = .{ x0, y1 } },
    };
}

test "bounds are the vertex box moved to the grid's origin" {
    const q = quad(8.5, 16, 17.5, 32);
    const r = bounds(TestVertex, &q, 100, 50).?;
    try std.testing.expectEqual(@as(f32, 108.5), r.left);
    try std.testing.expectEqual(@as(f32, 66), r.top);
    try std.testing.expectEqual(@as(f32, 117.5), r.right);
    try std.testing.expectEqual(@as(f32, 82), r.bottom);
    try std.testing.expectEqual(@as(f32, 9), r.width());
    try std.testing.expectEqual(@as(f32, 16), r.height());
}

test "no vertices is no rectangle" {
    const none: []const TestVertex = &.{};
    try std.testing.expect(bounds(TestVertex, none, 0, 0) == null);
}

test "inflation covers every touched pixel and clips to the surface" {
    const r = Rect{ .left = 108.5, .top = 66, .right = 117.5, .bottom = 82 };
    const i = inflateClip(r, 1000, 1000).?;
    try std.testing.expectEqual(@as(i32, 108), i.left);
    try std.testing.expectEqual(@as(i32, 66), i.top);
    try std.testing.expectEqual(@as(i32, 118), i.right);
    try std.testing.expectEqual(@as(i32, 82), i.bottom);
    // Partly outside: clipped, not dropped.
    const c = inflateClip(r, 112, 70).?;
    try std.testing.expectEqual(@as(i32, 112), c.right);
    try std.testing.expectEqual(@as(i32, 70), c.bottom);
}

test "a rectangle wholly outside the surface is dropped, not emptied" {
    const r = Rect{ .left = 108.5, .top = 66, .right = 117.5, .bottom = 82 };
    try std.testing.expect(inflateClip(r, 100, 60) == null);
    try std.testing.expect(inflateClip(r, 108, 1000) == null);
    // Negative origin is clamped to the surface's edge.
    const n = Rect{ .left = -3, .top = -2, .right = 4, .bottom = 5 };
    const i = inflateClip(n, 10, 10).?;
    try std.testing.expectEqual(@as(i32, 0), i.left);
    try std.testing.expectEqual(@as(i32, 0), i.top);
}
