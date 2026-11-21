//! Where a panel's popup surface goes (panel_popup.zig): the popup around a
//! panel placed by overlay_layout, the positioner anchor that puts it there,
//! and the panel's rect back from where the compositor put the popup. Pure.
//! `_px` are view device px, `_pt` view logical px; y grows down.

const std = @import("std");
const overlay_layout = @import("overlay_layout.zig");
const Rect = overlay_layout.Rect;
const Kind = overlay_layout.Kind;

/// Device px a popup leaves around its panel: the border ring and the
/// shadow rings gl_renderer.drawPanel draws outside the panel's rect.
/// Pre: scale >= 1.
pub fn marginPx(scale: i32) i32 {
    std.debug.assert(scale >= 1);
    const shadow: i32 = @intFromFloat(@ceil(overlay_layout.shadow_spread_pt * @as(f32, @floatFromInt(scale))));
    return scale + shadow;
}

pub const Frame = struct {
    /// The popup's top-left against the view.
    origin_pt: [2]i32,
    /// The popup's size.
    size_pt: [2]i32,
    /// The panel inside the popup, device px from its top-left.
    inner: Rect,
};

/// The popup that holds panel `r` (view px) at integer `scale`: on whole
/// logical px, as a surface is placed.
/// Pre: scale >= 1, r.w >= 0, r.h >= 0.
/// Post: `inner` has r's size, lies at least marginPx(scale) inside every
/// edge of the popup's size_pt * scale, and origin_pt * scale + inner's
/// corner is r's corner.
pub fn frame(r: Rect, scale: i32) Frame {
    std.debug.assert(scale >= 1 and r.w >= 0 and r.h >= 0);
    const m = marginPx(scale);
    const ox = @divFloor(r.x - m, scale);
    const oy = @divFloor(r.y - m, scale);
    const ix = r.x - ox * scale;
    const iy = r.y - oy * scale;
    return .{
        .origin_pt = .{ ox, oy },
        .size_pt = .{ divCeil(ix + r.w + m, scale), divCeil(iy + r.h + m, scale) },
        .inner = .{ .x = ix, .y = iy, .w = r.w, .h = r.h },
    };
}

fn divCeil(a: i32, b: i32) i32 {
    return -@divFloor(-a, b);
}

/// Panel `f.inner` in the view, for a popup the compositor put at
/// `origin_pt` (which slides it onto the output, so it may differ from
/// f.origin_pt).
pub fn panelRect(f: Frame, origin_pt: [2]i32, scale: i32) Rect {
    return .{ .x = origin_pt[0] * scale + f.inner.x, .y = origin_pt[1] * scale + f.inner.y, .w = f.inner.w, .h = f.inner.h };
}

/// An xdg_positioner placement (wl/window.c zwl_popup_open): the popup's
/// top-left goes `offset` from the bottom-left corner of the 1x1 rect at
/// `point`.
pub const Anchor = struct { point: [2]i32, offset: [2]i32 };

/// The anchor that puts a popup's top-left at `origin_pt`. xdg_positioner
/// wants the anchor rect inside the parent, so the point is kept in the view
/// and the offset carries the rest: a popup may start left of, above or past
/// the window.
/// Pre: view_w_pt >= 1, view_h_pt >= 1.
/// Post: point inside the view; point + (0, 1) + offset == origin_pt.
pub fn anchor(origin_pt: [2]i32, view_w_pt: i32, view_h_pt: i32) Anchor {
    std.debug.assert(view_w_pt >= 1 and view_h_pt >= 1);
    const px = std.math.clamp(origin_pt[0], 0, view_w_pt - 1);
    const py = std.math.clamp(origin_pt[1], 0, view_h_pt - 1);
    return .{ .point = .{ px, py }, .offset = .{ origin_pt[0] - px, origin_pt[1] - (py + 1) } };
}

/// The panel rects a pointer hit-tests: a popup's pointer (`own`) only its
/// own panel's; the main view's none while the panels are popups, which
/// take the pointer over them themselves, and all of them otherwise.
pub fn hitRects(rects: [4]?Rect, popups: bool, own: ?Kind) [4]?Rect {
    var out: [4]?Rect = @splat(null);
    if (own) |k| {
        out[@intFromEnum(k)] = rects[@intFromEnum(k)];
        return out;
    }
    return if (popups) out else rects;
}

const testing = std.testing;

test "a popup frames its panel with room for the shadow, on whole logical px" {
    const r: Rect = .{ .x = 101, .y = 51, .w = 400, .h = 44 };
    const f = frame(r, 2);
    const m = marginPx(2);
    try testing.expectEqual(@as(i32, 18), m);
    try testing.expect(f.inner.x >= m and f.inner.y >= m);
    try testing.expect(f.inner.x + f.inner.w + m <= f.size_pt[0] * 2);
    try testing.expect(f.inner.y + f.inner.h + m <= f.size_pt[1] * 2);
    try testing.expectEqual(r, panelRect(f, f.origin_pt, 2));
    // Left of and above the view.
    const g = frame(.{ .x = -128, .y = -3, .w = 1056, .h = 44 }, 1);
    try testing.expectEqual([2]i32{ -137, -12 }, g.origin_pt);
    try testing.expectEqual(@as(i32, 9), g.inner.x);
    // Slid by the compositor: the panel moves with the popup.
    try testing.expectEqual(@as(i32, 9), panelRect(g, .{ 0, -12 }, 1).x);
}

test "the anchor stays in the view and the offset reaches the popup's corner" {
    const in = anchor(.{ 40, 30 }, 800, 600);
    try testing.expectEqual([2]i32{ 40, 30 }, in.point);
    try testing.expectEqual([2]i32{ 0, -1 }, in.offset);
    const out = anchor(.{ -137, 700 }, 800, 600);
    try testing.expectEqual([2]i32{ 0, 599 }, out.point);
    try testing.expectEqual([2]i32{ -137, 700 }, .{ out.point[0] + out.offset[0], out.point[1] + 1 + out.offset[1] });
}

test "a popup's pointer hits only its panel, the main view none while they are popups" {
    const a: Rect = .{ .x = 0, .y = 0, .w = 10, .h = 10 };
    const rects: [4]?Rect = .{ a, a, a, a };
    const own = hitRects(rects, true, .msg_show);
    for (own, 0..) |r, i| try testing.expectEqual(i == @intFromEnum(Kind.msg_show), r != null);
    for (hitRects(rects, true, null)) |r| try testing.expect(r == null);
    for (hitRects(rects, false, null)) |r| try testing.expect(r != null);
}


/// The surface whose view panel `kind`'s popup hangs from: the cmdline the
/// one the keyboard is on (a compositor may not show a popup of a window
/// without the keyboard), the popupmenu the surface its completion is in
/// (overlay_layout.popupSurface), the message panels msg_pos's
/// (overlay_layout.msgSurface).
pub fn hostSurface(kind: Kind, cmdline_surface: i64, pum_surface: i64, msg_surface: i64) i64 {
    return switch (kind) {
        .cmdline => cmdline_surface,
        .popupmenu => pum_surface,
        .msg_show, .msg_history => msg_surface,
    };
}

test "each panel's popup hangs from the surface that panel is placed on" {
    try std.testing.expectEqual(@as(i64, 1003), hostSurface(.cmdline, 1003, 1005, 1007));
    try std.testing.expectEqual(@as(i64, 1005), hostSurface(.popupmenu, 1003, 1005, 1007));
    try std.testing.expectEqual(@as(i64, 1007), hostSurface(.msg_show, 1003, 1005, 1007));
    try std.testing.expectEqual(@as(i64, 1007), hostSurface(.msg_history, 1003, 1005, 1007));
    try std.testing.expectEqual(@as(i64, 1), hostSurface(.popupmenu, 1, 1, 1));
}

/// Whether panel `kind`'s popup stays shown while the app is inactive. The
/// cmdline does, so that a file dragged from another app (which activates
/// that app) can be dropped on it, as macOS (hidesOnDeactivate = false) and
/// Windows keep it; the other panels are taken off until the app is active.
pub fn shownWhileInactive(kind: Kind) bool {
    return kind == .cmdline;
}

test "only the cmdline popup stays shown while the app is inactive" {
    try std.testing.expect(shownWhileInactive(.cmdline));
    try std.testing.expect(!shownWhileInactive(.popupmenu));
    try std.testing.expect(!shownWhileInactive(.msg_show));
    try std.testing.expect(!shownWhileInactive(.msg_history));
}

/// Whether a file drop on panel `panel`'s popup (null: an editor view)
/// inserts its paths whatever the mode (frontend_rules.dropInsertsPath's
/// `force`): on the cmdline, as Windows registers its cmdline window's drop
/// target; the other panels take a drop as the editor does.
pub fn dropForcesInsert(panel: ?Kind) bool {
    return if (panel) |k| k == .cmdline else false;
}

test "a drop on the cmdline popup always inserts, elsewhere it follows the mode" {
    try std.testing.expect(dropForcesInsert(.cmdline));
    try std.testing.expect(!dropForcesInsert(.popupmenu));
    try std.testing.expect(!dropForcesInsert(.msg_show));
    try std.testing.expect(!dropForcesInsert(null));
}
