//! Where the core-owned ext UI surfaces (cmdline, popupmenu, the message
//! panels) sit against the main window's view. Wayland gives a client no
//! say over where its toplevels go, so a panel is either a popup surface
//! parented to the view (panel_popup.zig, `Inputs.free`), which may reach
//! past the window, or, as the fallback, drawn over the grid in the main
//! GLArea and kept inside it. All values are view surface px, Y growing
//! down; a free panel may have negative or out-of-view coordinates.

const std = @import("std");
const core = @import("zonvie_core");
const rules = core.frontend_rules;
const grid_mod = core.grid_mod;

pub const Kind = enum(u2) { cmdline, popupmenu, msg_show, msg_history };

/// Back-to-front: the popupmenu draws over the cmdline it completes.
pub const draw_order = [_]Kind{ .msg_history, .msg_show, .cmdline, .popupmenu };

pub fn kindOf(grid_id: i64) ?Kind {
    return switch (grid_id) {
        grid_mod.CMDLINE_GRID_ID => .cmdline,
        grid_mod.POPUPMENU_GRID_ID => .popupmenu,
        grid_mod.MESSAGE_GRID_ID => .msg_show,
        grid_mod.MSG_HISTORY_GRID_ID => .msg_history,
        else => null,
    };
}

pub fn gridId(kind: Kind) i64 {
    return switch (kind) {
        .cmdline => grid_mod.CMDLINE_GRID_ID,
        .popupmenu => grid_mod.POPUPMENU_GRID_ID,
        .msg_show => grid_mod.MESSAGE_GRID_ID,
        .msg_history => grid_mod.MSG_HISTORY_GRID_ID,
    };
}

/// What on_external_window last said about one surface.
pub const Surface = struct {
    open: bool = false,
    win: i64 = 0,
    rows: u32 = 0,
    cols: u32 = 0,
    start_row: i32 = -1,
    start_col: i32 = -1,
};

pub const Rect = struct {
    x: i32,
    y: i32,
    w: i32,
    h: i32,

    fn bottom(self: Rect) i32 {
        return self.y + self.h;
    }
};

/// Unscaled chrome.
pub const cmdline_padding_pt: i32 = rules.cmdline_padding_pt;
pub const msg_padding_pt: i32 = rules.msg_padding_pt;
pub const cmdline_screen_margin_pt: i32 = rules.cmdline_screen_margin_pt;
const msg_margin_pt: i32 = 10;
const msg_history_gap_pt: i32 = 4;
const cmdline_popup_gap_pt: i32 = 4;

/// Every panel's corner radius: macOS's decorated windows'
/// (specialWindowCornerRadius). Windows draws square corners.
pub const panel_radius_pt: f32 = 4;
const corner_segments = 6;
pub const outline_points = 4 * (corner_segments + 1);

/// The outline of panel `r` grown by `outset` px on every side, its corners
/// arcs of radius `radius + outset`, clockwise from the top-left arc (y
/// down). A convex polygon, so a fan from its centre fills it.
/// Pre: radius >= 0, outset >= 0.
pub fn panelOutline(r: Rect, outset: f32, radius: f32) [outline_points][2]f32 {
    std.debug.assert(radius >= 0 and outset >= 0);
    const x0 = @as(f32, @floatFromInt(r.x)) - outset;
    const y0 = @as(f32, @floatFromInt(r.y)) - outset;
    const x1 = @as(f32, @floatFromInt(r.x + r.w)) + outset;
    const y1 = @as(f32, @floatFromInt(r.bottom())) + outset;
    const rad = @min(radius + outset, @min(x1 - x0, y1 - y0) / 2);
    // Corner centres and the angle each arc starts at.
    const corners = [4][3]f32{
        .{ x0 + rad, y0 + rad, std.math.pi },
        .{ x1 - rad, y0 + rad, 1.5 * std.math.pi },
        .{ x1 - rad, y1 - rad, 0 },
        .{ x0 + rad, y1 - rad, 0.5 * std.math.pi },
    };
    var out: [outline_points][2]f32 = undefined;
    for (corners, 0..) |c, ci| {
        for (0..corner_segments + 1) |i| {
            const a = c[2] + @as(f32, @floatFromInt(i)) / corner_segments * 0.5 * std.math.pi;
            out[ci * (corner_segments + 1) + i] = .{ c[0] + rad * @cos(a), c[1] + rad * @sin(a) };
        }
    }
    return out;
}

/// A panel's drop shadow, as macOS's floating panels cast one: rings outside
/// the panel's outline, fading outward, so nothing is drawn under the panel
/// and a translucent one shows no shadow through it.
pub const shadow_rings = 4;
pub const ShadowRing = struct { inner_px: f32, outer_px: f32, alpha: f32 };

/// Ring `i` (0 nearest the panel) of a shadow `spread_pt` wide at `scale`,
/// with `alpha` at the panel's edge falling to 0 quadratically.
/// Pre: i < shadow_rings, scale > 0.
pub fn shadowRing(i: usize, spread_pt: f32, scale: f32, alpha: f32) ShadowRing {
    std.debug.assert(i < shadow_rings and scale > 0);
    const step = spread_pt * scale / shadow_rings;
    const fi: f32 = @floatFromInt(i);
    const fade = 1.0 - fi / shadow_rings;
    return .{ .inner_px = fi * step, .outer_px = (fi + 1) * step, .alpha = alpha * fade * fade };
}

test "shadow rings tile the spread and fade outward" {
    var prev_outer: f32 = 0;
    var prev_alpha: f32 = 1;
    for (0..shadow_rings) |i| {
        const r = shadowRing(i, 8, 2, 0.3);
        try std.testing.expectEqual(prev_outer, r.inner_px);
        try std.testing.expect(r.alpha < prev_alpha);
        prev_outer = r.outer_px;
        prev_alpha = r.alpha;
    }
    try std.testing.expectEqual(@as(f32, 16), prev_outer);
    try std.testing.expectEqual(@as(f32, 0.3), shadowRing(0, 8, 2, 0.3).alpha);
}

/// How far a panel's shadow reaches past it, logical px, and its alpha at
/// the panel's edge.
pub const shadow_spread_pt: f32 = 8;
pub const shadow_alpha: f32 = 0.28;

/// The cmdline's icon box and the strip it takes before the text.
pub const cmdline_icon_size_pt: i32 = rules.cmdline_icon_size_pt;
const cmdline_icon_margin_left_pt: i32 = rules.cmdline_icon_margin_left_pt;
const cmdline_icon_strip_pt: i32 = cmdline_icon_margin_left_pt + cmdline_icon_size_pt + rules.cmdline_icon_margin_right_pt;

/// Leading width msg_show reserves so its close badge clears the text
/// (rules.msgCloseBadgeReservePx); zero on the other panels.
pub fn badgeReservePx(kind: Kind, scale: i32) i32 {
    if (kind != .msg_show) return 0;
    return @intFromFloat(rules.msgCloseBadgeReservePx(@floatFromInt(scale)));
}

pub fn paddingPx(kind: Kind, scale: i32) i32 {
    return scale * switch (kind) {
        .cmdline => cmdline_padding_pt,
        .msg_show, .msg_history => msg_padding_pt,
        .popupmenu => 0,
    };
}

/// Where a surface's grid starts inside its panel: past the padding, for
/// the cmdline its icon strip too, and for msg_show its close badge.
pub fn contentOrigin(kind: Kind, scale: i32) [2]i32 {
    const pad = paddingPx(kind, scale);
    const icon: i32 = if (kind == .cmdline) cmdline_icon_strip_pt * scale else 0;
    return .{ pad + icon + badgeReservePx(kind, scale), pad };
}

/// msg_show's close badge inside panel `r` (rules.msgCloseBadgeRect): its
/// top-left corner. Null on another panel or one too small for it.
pub fn closeBadgeRect(kind: Kind, r: Rect, scale: i32) ?Rect {
    if (kind != .msg_show) return null;
    const b = rules.msgCloseBadgeRect(@floatFromInt(r.w), @floatFromInt(r.h), @floatFromInt(scale)) orelse return null;
    return .{
        .x = r.x + @as(i32, @intFromFloat(b.left)),
        .y = r.y + @as(i32, @intFromFloat(b.top)),
        .w = @intFromFloat(b.right - b.left),
        .h = @intFromFloat(b.bottom - b.top),
    };
}

pub fn contains(r: Rect, x: i32, y: i32) bool {
    return x >= r.x and x < r.x + r.w and y >= r.y and y < r.bottom();
}

/// The topmost panel at surface px (x, y): draw_order read front to back.
pub fn hit(rects: *const [4]?Rect, x: i32, y: i32) ?Kind {
    var i: usize = draw_order.len;
    while (i > 0) {
        i -= 1;
        const kind = draw_order[i];
        const r = rects[@intFromEnum(kind)] orelse continue;
        if (contains(r, x, y)) return kind;
    }
    return null;
}

/// The cell of `kind`'s grid at surface px (x, y) in its panel `r`, kept
/// at or past the first: a position on the padding names the nearest edge
/// cell, as Windows clamps a wheel on the chrome.
/// Pre: cell sizes > 0.
pub fn panelCell(kind: Kind, r: Rect, x: i32, y: i32, in: Inputs) [2]i32 {
    std.debug.assert(in.cell_w_px > 0 and in.cell_h_px > 0);
    const o = contentOrigin(kind, in.scale);
    return .{
        @max(0, @divFloor(y - r.y - o[1], in.cell_h_px)),
        @max(0, @divFloor(x - r.x - o[0], in.cell_w_px)),
    };
}

/// The cmdline icon's box inside panel `r`, vertically centred.
pub fn cmdlineIconRect(r: Rect, scale: i32) Rect {
    const box = cmdline_icon_size_pt * scale;
    return .{ .x = r.x + paddingPx(.cmdline, scale) + cmdline_icon_margin_left_pt * scale, .y = r.y + @divTrunc(r.h - box, 2), .w = box, .h = box };
}

/// Everything beside the cmdline grid across its panel, for the core's
/// width budget (cmdlineCols): padding, icon strip and copy button.
pub fn cmdlineChromePx(scale: i32, copy: bool) i32 {
    const copy_w: i32 = if (copy) copy_margin_left_pt + copy_size_pt + copy_margin_right_pt else 0;
    return scale * (2 * cmdline_padding_pt + cmdline_icon_strip_pt + copy_w);
}

pub const Inputs = struct {
    /// The surface being laid out (1, the main view, or an external
    /// window's root grid) and its size.
    surface_id: i64 = 1,
    main_w_px: i32,
    main_h_px: i32,
    cell_w_px: i32,
    cell_h_px: i32,
    /// Integer surface scale for the chrome constants.
    scale: i32,
    /// What msg_show and msg_history hang from (msgTargetOn); the whole view
    /// when null.
    msg_target: ?rules.Rect = null,
    /// The surfaces the popupmenu and the message panels draw on
    /// (popupSurface, msgSurface); a panel shows only on its own.
    pum_surface: i64 = 1,
    msg_surface: i64 = 1,
    /// [cmdline] / [messages] copy_button: those panels reserve room for it.
    copy_cmdline: bool = false,
    copy_messages: bool = false,
    /// The confirm dialog while it shows: the cmdline answering it goes
    /// below it, as on Windows and macOS.
    confirm: ?Rect = null,
    /// The cmdline panel where the user last dropped it this session; later
    /// cmdlines keep its centre (rules.cmdlineOrigin), as Windows reopens
    /// one at its saved origin. Null: the default slot.
    cmdline_user: ?Rect = null,
    /// msg_show's top-left while the user keeps it where they dragged it
    /// (MsgShowChrome.user_placed); null while it follows its anchor.
    msg_show_user: ?[2]i32 = null,
    /// The panels are popup surfaces of their own (panel_popup.zig), as
    /// macOS and Windows make them windows: the cmdline is not narrowed to
    /// the view, a dragged cmdline or msg_show is not pulled back into it,
    /// and a cmdline completion follows the cmdline's text column wherever
    /// it is. The compositor keeps the popups on the output.
    free: bool = false,
};

/// What a free panel may occupy, view px: far past any output.
const free_reach: rules.Rect = .{ .left = -(1 << 20), .top = -(1 << 20), .right = 1 << 20, .bottom = 1 << 20 };

/// The copy button's box and gaps.
pub const copy_size_pt: i32 = rules.copy_button_size_pt;
const copy_margin_left_pt: i32 = rules.copy_button_margin_left_pt;
const copy_margin_right_pt: i32 = rules.copy_button_margin_right_pt;

fn hasCopy(kind: Kind, in: Inputs) bool {
    return switch (kind) {
        .cmdline => in.copy_cmdline,
        .msg_show, .msg_history => in.copy_messages,
        .popupmenu => false,
    };
}

/// The copy button inside panel `r`, surface px: at its trailing edge,
/// centred on the one-row cmdline and near the top of a message.
pub fn copyButtonRect(kind: Kind, r: Rect, in: Inputs) ?Rect {
    if (!hasCopy(kind, in)) return null;
    const box = copy_size_pt * in.scale;
    const right = copy_margin_right_pt * in.scale;
    if (r.w <= box + right or r.h < box) return null;
    const centred = @divTrunc(r.h - box, 2);
    return .{
        .x = r.x + r.w - box - right,
        .y = r.y + if (kind == .cmdline) centred else @min(right, centred),
        .w = box,
        .h = box,
    };
}

/// The rect msg_pos `mode` places message boxes against on surface
/// `surface_id`, `main_w_px` x `main_h_px`: the anchor's cells (.grid) when
/// they are on that surface, else the whole of it. Wayland lets no box sit
/// outside the window, so .display is the main view.
pub fn msgTargetOn(surface_id: i64, mode: core.config.MsgPosition, anchor: ?core.MsgAnchor, main_w_px: i32, main_h_px: i32, cell_w_px: i32, cell_h_px: i32) rules.Rect {
    const view: rules.Rect = .{ .left = 0, .top = 0, .right = main_w_px, .bottom = main_h_px };
    if (mode != .grid) return view;
    const a = anchor orelse return view;
    if (a.anchor_surface != surface_id) return view;
    return .{
        .left = a.start_col * cell_w_px,
        .top = a.start_row * cell_h_px,
        .right = @min(main_w_px, (a.start_col + a.cols) * cell_w_px),
        .bottom = @min(main_h_px, (a.start_row + a.rows) * cell_h_px),
    };
}

/// The surface msg_pos `mode` hangs the message panels on: the external
/// window the cursor's window (.window) or the anchor's cells (.grid) are
/// on, as Windows and macOS place them over that window, when
/// `isOpen(ctx, id)` says this frontend has it open; else the main view.
pub fn msgSurface(mode: core.config.MsgPosition, anchor: ?core.MsgAnchor, ctx: anytype, comptime isOpen: fn (@TypeOf(ctx), i64) bool) i64 {
    const a = anchor orelse return 1;
    const id = switch (mode) {
        .display => return 1,
        .window => a.cursor_surface,
        .grid => a.anchor_surface,
    };
    return if (id != 1 and isOpen(ctx, id)) id else 1;
}

/// The surface the popupmenu draws on: the external window its `win` names
/// when that is open (a completion in that window), else the main view.
pub fn popupSurface(pum: Surface, ctx: anytype, comptime isOpen: fn (@TypeOf(ctx), i64) bool) i64 {
    return if (pum.win > 1 and isOpen(ctx, pum.win)) pum.win else 1;
}

/// Whether panel `kind` draws the editor cursor it holds: not the cmdline
/// while an IME composition is under way, whose preedit stands at the
/// cursor, as Windows hides it.
pub fn panelCursorShown(kind: Kind, composing: bool) bool {
    return !(kind == .cmdline and composing);
}

test "the cmdline hides its cursor during a composition, other panels do not" {
    try testing.expect(!panelCursorShown(.cmdline, true));
    try testing.expect(panelCursorShown(.cmdline, false));
    try testing.expect(panelCursorShown(.popupmenu, true));
    try testing.expect(panelCursorShown(.msg_show, true));
}

/// The confirm dialog's top in a view `view_h` high, for a box `box_h` high
/// (logical px): centred, or without ext_cmdline centred in the space above
/// Neovim's own cmdline row (`row_h` and 8 more) and at least 10 down, so
/// the answer being typed stays visible, as Windows places it.
pub fn confirmTop(view_h: i32, box_h: i32, row_h: i32, ext_cmdline: bool) i32 {
    if (ext_cmdline) return @max(0, @divTrunc(view_h - box_h, 2));
    return @max(10, @divTrunc(view_h - row_h - 8 - box_h, 2));
}

fn size(kind: Kind, s: Surface, in: Inputs) [2]i32 {
    const pad = 2 * paddingPx(kind, in.scale);
    const icon: i32 = if (kind == .cmdline) cmdline_icon_strip_pt * in.scale else 0;
    // The copy button sits beside the text, never over it.
    const copy: i32 = if (hasCopy(kind, in)) (copy_margin_left_pt + copy_size_pt + copy_margin_right_pt) * in.scale else 0;
    return .{
        @as(i32, @intCast(s.cols)) * in.cell_w_px + pad + icon + copy + badgeReservePx(kind, in.scale),
        @as(i32, @intCast(s.rows)) * in.cell_h_px + pad,
    };
}

/// The rect of every open surface, by kind; null for one that is closed or
/// cannot be placed (a cmdline completion with no cmdline).
pub fn place(surfaces: *const [4]Surface, in: Inputs) [4]?Rect {
    var out: [4]?Rect = @splat(null);
    const area: rules.Rect = .{ .left = 0, .top = 0, .right = in.main_w_px, .bottom = in.main_h_px };
    // Where a moved or growing panel is kept.
    const reach = if (in.free) free_reach else area;

    // The cmdline is always the main view's.
    if (in.surface_id == 1 and surfaces[@intFromEnum(Kind.cmdline)].open) {
        const wh = size(.cmdline, surfaces[@intFromEnum(Kind.cmdline)], in);
        // Centred, a third of the free height down, as a new cmdline opens on
        // Windows (centredOnWorkArea with a divisor of 3).
        const margin = cmdline_screen_margin_pt * in.scale;
        // In the view less its margin; a free one only by the core's width
        // budget (callbacks.cmdlineCols), which the output bounds.
        const w = if (in.free) wh[0] else @min(wh[0], @max(0, in.main_w_px - 2 * margin));
        var r: Rect = .{
            .x = @divTrunc(in.main_w_px - w, 2),
            .y = @max(0, @divTrunc(in.main_h_px - wh[1], 3)),
            .w = w,
            .h = wh[1],
        };
        if (in.confirm) |c| {
            // 4 below it and centred on it, kept in the view.
            r.x = std.math.clamp(c.x + @divTrunc(c.w - w, 2), 0, @max(0, in.main_w_px - w));
            r.y = std.math.clamp(c.bottom() + cmdline_popup_gap_pt * in.scale, 0, @max(0, in.main_h_px - wh[1]));
        } else if (in.cmdline_user) |u| {
            const o = rules.cmdlineOrigin(.{ .left = u.x, .top = u.y, .right = u.x + u.w, .bottom = u.bottom() }, w, wh[1], reach);
            r.x = o.x;
            r.y = o.y;
        }
        out[@intFromEnum(Kind.cmdline)] = r;
    }

    // A box wider than a narrow target keeps its left edge in the view.
    const msg_area = in.msg_target orelse area;
    const msgs_here = in.msg_surface == in.surface_id;
    const history = surfaces[@intFromEnum(Kind.msg_history)];
    if (msgs_here and history.open) {
        const wh = size(.msg_history, history, in);
        const o = rules.msgFloatTopRight(msg_area, wh[0], null, msg_margin_pt * in.scale, msg_history_gap_pt * in.scale);
        out[@intFromEnum(Kind.msg_history)] = .{ .x = @max(0, o.x), .y = o.y, .w = wh[0], .h = wh[1] };
    }
    const show = surfaces[@intFromEnum(Kind.msg_show)];
    if (msgs_here and show.open) {
        const wh = size(.msg_show, show, in);
        const history_bottom: ?i32 = if (out[@intFromEnum(Kind.msg_history)]) |r| r.bottom() else null;
        var r: Rect = .{ .x = 0, .y = 0, .w = wh[0], .h = wh[1] };
        if (in.msg_show_user) |u| {
            // Pinned where the user left it, kept in the view (or the
            // reach) as it grows.
            core.zonvie_core_clamp_window_origin(u[0], u[1], wh[0], wh[1], reach.left, reach.top, reach.right, reach.bottom, &r.x, &r.y);
        } else {
            const o = rules.msgFloatTopRight(msg_area, wh[0], history_bottom, msg_margin_pt * in.scale, msg_history_gap_pt * in.scale);
            r.x = @max(0, o.x);
            r.y = o.y;
        }
        out[@intFromEnum(Kind.msg_show)] = r;
    }

    const pum = surfaces[@intFromEnum(Kind.popupmenu)];
    if (pum.open and in.pum_surface == in.surface_id) {
        const wh = size(.popupmenu, pum, in);
        if (pum.start_row >= 0 and pum.start_col >= 0) {
            // A buffer completion: the anchor cell on the main grid, with no
            // text inset, as Windows places it.
            const ax = pum.start_col * in.cell_w_px;
            const ay = pum.start_row * in.cell_h_px;
            out[@intFromEnum(Kind.popupmenu)] = .{
                .x = core.zonvie_core_popupmenu_left(ax, wh[0], 0, 0, in.main_w_px),
                .y = core.zonvie_core_popupmenu_top(ay, in.cell_h_px, wh[1], in.main_h_px, 0),
                .w = wh[0],
                .h = wh[1],
            };
        } else if (out[@intFromEnum(Kind.cmdline)]) |cmd| {
            // Cmdline completion: under the cmdline's text column.
            const ax = cmd.x + contentOrigin(.cmdline, in.scale)[0] + @max(0, pum.start_col) * in.cell_w_px;
            out[@intFromEnum(Kind.popupmenu)] = .{
                .x = core.zonvie_core_popupmenu_left(ax, wh[0], 0, reach.left, reach.right),
                .y = core.zonvie_core_cmdline_popupmenu_top(cmd.y, cmd.bottom(), wh[1], cmdline_popup_gap_pt * in.scale, 0),
                .w = wh[0],
                .h = wh[1],
            };
        }
    }
    return out;
}

const testing = std.testing;

const in1: Inputs = .{ .main_w_px = 800, .main_h_px = 600, .cell_w_px = 10, .cell_h_px = 20, .scale = 1 };

fn open(rows: u32, cols: u32, start_row: i32, start_col: i32) Surface {
    return .{ .open = true, .rows = rows, .cols = cols, .start_row = start_row, .start_col = start_col };
}

test "the cmdline is centred a third of the way down" {
    var s: [4]Surface = @splat(.{});
    s[@intFromEnum(Kind.cmdline)] = open(1, 40, -1, -1);
    const r = place(&s, in1)[@intFromEnum(Kind.cmdline)].?;
    try testing.expectEqual(@as(i32, 456), r.w);
    try testing.expectEqual(@as(i32, 172), r.x);
    try testing.expectEqual(@as(i32, 44), r.h);
    try testing.expectEqual(@as(i32, 185), r.y);
}

test "the cmdline answering a confirm sits 4 below it" {
    var s: [4]Surface = @splat(.{});
    s[@intFromEnum(Kind.cmdline)] = open(1, 40, -1, -1);
    var in = in1;
    in.confirm = .{ .x = 300, .y = 200, .w = 200, .h = 100 };
    const r = place(&s, in)[@intFromEnum(Kind.cmdline)].?;
    try testing.expectEqual(@as(i32, 304), r.y);
    try testing.expectEqual(@as(i32, 400), r.x + @divTrunc(r.w, 2));
}

test "a buffer popupmenu opens below its anchor and flips above near the bottom" {
    var s: [4]Surface = @splat(.{});
    s[@intFromEnum(Kind.popupmenu)] = open(5, 20, 3, 4);
    const below = place(&s, in1)[@intFromEnum(Kind.popupmenu)].?;
    try testing.expectEqual(@as(i32, 40), below.x);
    try testing.expectEqual(@as(i32, 80), below.y);
    s[@intFromEnum(Kind.popupmenu)] = open(5, 20, 28, 4);
    const above = place(&s, in1)[@intFromEnum(Kind.popupmenu)].?;
    try testing.expectEqual(@as(i32, 460), above.y);
}

test "a cmdline completion needs the cmdline and sits beside it" {
    var s: [4]Surface = @splat(.{});
    s[@intFromEnum(Kind.popupmenu)] = open(3, 10, -1, 2);
    try testing.expect(place(&s, in1)[@intFromEnum(Kind.popupmenu)] == null);
    s[@intFromEnum(Kind.cmdline)] = open(1, 40, -1, -1);
    const out = place(&s, in1);
    const cmd = out[@intFromEnum(Kind.cmdline)].?;
    const pum = out[@intFromEnum(Kind.popupmenu)].?;
    try testing.expect(pum.y + pum.h <= cmd.y or pum.y >= cmd.y + cmd.h);
    // Under the cmdline's text: past its padding and icon strip.
    try testing.expectEqual(cmd.x + 12 + 32 + 2 * 10, pum.x);
    try testing.expectEqual(@as(i32, 12 * 2 + 32 + 30), cmdlineChromePx(1, true));
}

test "msg_show stacks below msg_history at the top-right" {
    var s: [4]Surface = @splat(.{});
    s[@intFromEnum(Kind.msg_history)] = open(4, 30, -2, -2);
    s[@intFromEnum(Kind.msg_show)] = open(1, 20, -2, -2);
    const out = place(&s, in1);
    const h = out[@intFromEnum(Kind.msg_history)].?;
    const m = out[@intFromEnum(Kind.msg_show)].?;
    try testing.expectEqual(@as(i32, 800 - 10), h.x + h.w);
    try testing.expect(m.y >= h.y + h.h);
}

test "msg_pos grid hangs messages from the cursor's window, the rest from the view" {
    const a: core.MsgAnchor = .{ .cursor_surface = 1, .anchor_surface = 1, .anchor_grid = 4, .start_row = 0, .start_col = 40, .rows = 28, .cols = 40 };
    const grid = msgTargetOn(1, .grid, a, 800, 600, 10, 20);
    try testing.expectEqual(rules.Rect{ .left = 400, .top = 0, .right = 800, .bottom = 560 }, grid);
    try testing.expectEqual(rules.Rect{ .left = 0, .top = 0, .right = 800, .bottom = 600 }, msgTargetOn(1, .window, a, 800, 600, 10, 20));
    var ext = a;
    ext.anchor_surface = 7;
    try testing.expectEqual(@as(i32, 0), msgTargetOn(1, .grid, ext, 800, 600, 10, 20).left);

    var s: [4]Surface = @splat(.{});
    s[@intFromEnum(Kind.msg_show)] = open(1, 20, -2, -2);
    var in = in1;
    in.msg_target = .{ .left = 0, .top = 0, .right = 390, .bottom = 600 };
    const m = place(&s, in)[@intFromEnum(Kind.msg_show)].?;
    try testing.expectEqual(@as(i32, 390 - 10), m.x + m.w);
}

test "a copy button widens its panel and sits at the trailing edge" {
    var s: [4]Surface = @splat(.{});
    s[@intFromEnum(Kind.msg_show)] = open(3, 20, -2, -2);
    const plain = place(&s, in1)[@intFromEnum(Kind.msg_show)].?;
    try testing.expect(copyButtonRect(.msg_show, plain, in1) == null);
    var in = in1;
    in.copy_messages = true;
    const r = place(&s, in)[@intFromEnum(Kind.msg_show)].?;
    try testing.expectEqual(plain.w + 30, r.w);
    const b = copyButtonRect(.msg_show, r, in).?;
    try testing.expectEqual(r.x + r.w - 8, b.x + b.w);
    try testing.expectEqual(r.y + 8, b.y);
}

test "the topmost panel takes a point, and its cell skips the chrome" {
    var s: [4]Surface = @splat(.{});
    s[@intFromEnum(Kind.cmdline)] = open(1, 40, -1, -1);
    s[@intFromEnum(Kind.popupmenu)] = open(3, 10, -1, 0);
    const rects = place(&s, in1);
    const cmd = rects[@intFromEnum(Kind.cmdline)].?;
    const pum = rects[@intFromEnum(Kind.popupmenu)].?;
    try testing.expectEqual(Kind.cmdline, hit(&rects, cmd.x + 1, cmd.y + 1).?);
    try testing.expectEqual(Kind.popupmenu, hit(&rects, pum.x + 1, pum.y + 1).?);
    try testing.expect(hit(&rects, 0, 0) == null);
    const o = contentOrigin(.cmdline, 1);
    try testing.expectEqual([2]i32{ 0, 3 }, panelCell(.cmdline, cmd, cmd.x + o[0] + 35, cmd.y + o[1] + 5, in1));
    // On the padding: the first cell, never a negative one.
    try testing.expectEqual([2]i32{ 0, 0 }, panelCell(.cmdline, cmd, cmd.x, cmd.y, in1));
}

test "msg_show reserves its close badge's room and the badge sits top-left" {
    var s: [4]Surface = @splat(.{});
    s[@intFromEnum(Kind.msg_show)] = open(2, 20, -2, -2);
    s[@intFromEnum(Kind.msg_history)] = open(2, 20, -2, -2);
    const out = place(&s, in1);
    const m = out[@intFromEnum(Kind.msg_show)].?;
    const h = out[@intFromEnum(Kind.msg_history)].?;
    try testing.expectEqual(h.w + 10, m.w);
    try testing.expectEqual(msg_padding_pt + 10, contentOrigin(.msg_show, 1)[0]);
    const b = closeBadgeRect(.msg_show, m, 1).?;
    try testing.expectEqual(m.x + 2, b.x);
    try testing.expectEqual(m.y + 2, b.y);
    try testing.expectEqual(@as(i32, 13), b.w);
    try testing.expect(closeBadgeRect(.msg_history, h, 1) == null);
}

test "a dragged cmdline keeps its centre and a pinned msg_show its corner" {
    var s: [4]Surface = @splat(.{});
    s[@intFromEnum(Kind.cmdline)] = open(1, 20, -1, -1);
    s[@intFromEnum(Kind.msg_show)] = open(1, 20, -2, -2);
    var in = in1;
    in.cmdline_user = .{ .x = 50, .y = 400, .w = 200, .h = 44 };
    in.msg_show_user = .{ 20, 30 };
    const out = place(&s, in);
    const cmd = out[@intFromEnum(Kind.cmdline)].?;
    try testing.expectEqual(@as(i32, 150), cmd.x + @divTrunc(cmd.w, 2));
    try testing.expectEqual(@as(i32, 400), cmd.y);
    const m = out[@intFromEnum(Kind.msg_show)].?;
    try testing.expectEqual(@as(i32, 20), m.x);
    try testing.expectEqual(@as(i32, 30), m.y);
    // Off the view: pulled back inside it.
    in.msg_show_user = .{ 790, 590 };
    const back = place(&s, in)[@intFromEnum(Kind.msg_show)].?;
    try testing.expectEqual(@as(i32, 800), back.x + back.w);
    try testing.expectEqual(@as(i32, 600), back.y + back.h);
    // A confirm wins over the remembered spot, as on Windows.
    in.confirm = .{ .x = 300, .y = 200, .w = 200, .h = 100 };
    try testing.expectEqual(@as(i32, 304), place(&s, in)[@intFromEnum(Kind.cmdline)].?.y);
}

test "free panels reach past the view: a wide cmdline, its completion, a dragged msg_show" {
    var s: [4]Surface = @splat(.{});
    // 1000 px of cells and 56 of chrome: wider than the 800 px view.
    s[@intFromEnum(Kind.cmdline)] = open(1, 100, -1, -1);
    s[@intFromEnum(Kind.popupmenu)] = open(3, 10, -1, 0);
    s[@intFromEnum(Kind.msg_show)] = open(1, 20, -2, -2);
    var in = in1;
    in.free = true;
    in.msg_show_user = .{ 790, 590 };
    const out = place(&s, in);
    const cmd = out[@intFromEnum(Kind.cmdline)].?;
    try testing.expectEqual(@as(i32, 1056), cmd.w);
    try testing.expectEqual(@as(i32, -128), cmd.x);
    try testing.expectEqual(cmd.x + contentOrigin(.cmdline, 1)[0], out[@intFromEnum(Kind.popupmenu)].?.x);
    try testing.expectEqual(@as(i32, 790), out[@intFromEnum(Kind.msg_show)].?.x);
    try testing.expectEqual(@as(i32, 590), out[@intFromEnum(Kind.msg_show)].?.y);
    // In the view: narrowed to it less the margin, and pulled back.
    in.free = false;
    const kept = place(&s, in);
    try testing.expectEqual(@as(i32, 800 - 2 * cmdline_screen_margin_pt), kept[@intFromEnum(Kind.cmdline)].?.w);
    try testing.expect(kept[@intFromEnum(Kind.msg_show)].?.x < 790);
}

test "a popupmenu or message panel anchored in an open external window draws there" {
    const Open = struct {
        fn f(ext: i64, id: i64) bool {
            return id == ext;
        }
    };
    var pum = open(5, 20, 3, 4);
    pum.win = 7;
    try testing.expectEqual(@as(i64, 7), popupSurface(pum, @as(i64, 7), Open.f));
    // Not open here (or anchored on the main view): the main view.
    try testing.expectEqual(@as(i64, 1), popupSurface(pum, @as(i64, 9), Open.f));
    const a: core.MsgAnchor = .{ .cursor_surface = 7, .anchor_surface = 7, .anchor_grid = 7, .start_row = 1, .start_col = 2, .rows = 10, .cols = 30 };
    try testing.expectEqual(@as(i64, 7), msgSurface(.window, a, @as(i64, 7), Open.f));
    try testing.expectEqual(@as(i64, 7), msgSurface(.grid, a, @as(i64, 7), Open.f));
    try testing.expectEqual(@as(i64, 1), msgSurface(.display, a, @as(i64, 7), Open.f));
    try testing.expectEqual(@as(i64, 1), msgSurface(.grid, a, @as(i64, 9), Open.f));
    // The anchor's cells are its own surface's.
    try testing.expectEqual(rules.Rect{ .left = 20, .top = 20, .right = 320, .bottom = 220 }, msgTargetOn(7, .grid, a, 400, 300, 10, 20));

    var s: [4]Surface = @splat(.{});
    s[@intFromEnum(Kind.popupmenu)] = pum;
    s[@intFromEnum(Kind.cmdline)] = open(1, 20, -1, -1);
    var main = in1;
    main.pum_surface = 7;
    const on_main = place(&s, main);
    try testing.expect(on_main[@intFromEnum(Kind.popupmenu)] == null);
    var ext = main;
    ext.surface_id = 7;
    const on_ext = place(&s, ext);
    try testing.expectEqual(@as(i32, 40), on_ext[@intFromEnum(Kind.popupmenu)].?.x);
    // The cmdline stays in the main view.
    try testing.expect(on_ext[@intFromEnum(Kind.cmdline)] == null);
}

test "the confirm dialog clears the built-in cmdline row" {
    try testing.expectEqual(@as(i32, 200), confirmTop(600, 200, 20, true));
    try testing.expectEqual(@as(i32, 186), confirmTop(600, 200, 20, false));
    // Taller than the room: kept 10 down.
    try testing.expectEqual(@as(i32, 10), confirmTop(200, 200, 20, false));
}

test "a panel's outline keeps to its rect and rounds its corners" {
    const r: Rect = .{ .x = 10, .y = 20, .w = 100, .h = 40 };
    const o = panelOutline(r, 0, 4);
    for (o) |pt| {
        try testing.expect(pt[0] >= 10 - 0.001 and pt[0] <= 110 + 0.001);
        try testing.expect(pt[1] >= 20 - 0.001 and pt[1] <= 60 + 0.001);
    }
    // The first arc starts on the left edge, 4 below the top, and the
    // corner itself is cut.
    try testing.expectApproxEqAbs(@as(f32, 10), o[0][0], 0.001);
    try testing.expectApproxEqAbs(@as(f32, 24), o[0][1], 0.001);
    // Grown by a border: 1 out on every side.
    const g = panelOutline(r, 1, 4);
    try testing.expectApproxEqAbs(@as(f32, 9), g[0][0], 0.001);
}
