//! Where the core-owned ext UI surfaces (cmdline, popupmenu, the message
//! panels) sit inside the main window. Wayland gives a client no say over
//! where its toplevels go, so these are drawn over the grid in the main
//! GLArea rather than as windows of their own. All values are surface px,
//! Y growing down.

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

/// The cmdline's icon box and the strip it takes before the text.
pub const cmdline_icon_size_pt: i32 = rules.cmdline_icon_size_pt;
const cmdline_icon_margin_left_pt: i32 = rules.cmdline_icon_margin_left_pt;
const cmdline_icon_strip_pt: i32 = cmdline_icon_margin_left_pt + cmdline_icon_size_pt + rules.cmdline_icon_margin_right_pt;

pub fn paddingPx(kind: Kind, scale: i32) i32 {
    return scale * switch (kind) {
        .cmdline => cmdline_padding_pt,
        .msg_show, .msg_history => msg_padding_pt,
        .popupmenu => 0,
    };
}

/// Where a surface's grid starts inside its panel: past the padding, and
/// for the cmdline its icon strip too.
pub fn contentOrigin(kind: Kind, scale: i32) [2]i32 {
    const pad = paddingPx(kind, scale);
    const icon: i32 = if (kind == .cmdline) cmdline_icon_strip_pt * scale else 0;
    return .{ pad + icon, pad };
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
    main_w_px: i32,
    main_h_px: i32,
    cell_w_px: i32,
    cell_h_px: i32,
    /// Integer surface scale for the chrome constants.
    scale: i32,
    /// What msg_show and msg_history hang from (msgTarget); the whole view
    /// when null.
    msg_target: ?rules.Rect = null,
    /// [cmdline] / [messages] copy_button: those panels reserve room for it.
    copy_cmdline: bool = false,
    copy_messages: bool = false,
    /// The confirm dialog while it shows: the cmdline answering it goes
    /// below it, as on Windows and macOS.
    confirm: ?Rect = null,
};

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

/// The rect msg_pos `mode` places message boxes against, in main-view px:
/// the cells of the window the cursor is in (.grid) when that window is on
/// the main surface, else the whole view. Wayland lets no box sit outside
/// the window, so .display is the view too, and the boxes of an external
/// window's grid are drawn here as well.
pub fn msgTarget(mode: core.config.MsgPosition, anchor: ?core.MsgAnchor, main_w_px: i32, main_h_px: i32, cell_w_px: i32, cell_h_px: i32) rules.Rect {
    const view: rules.Rect = .{ .left = 0, .top = 0, .right = main_w_px, .bottom = main_h_px };
    if (mode != .grid) return view;
    const a = anchor orelse return view;
    if (a.anchor_surface != 1) return view;
    return .{
        .left = a.start_col * cell_w_px,
        .top = a.start_row * cell_h_px,
        .right = @min(main_w_px, (a.start_col + a.cols) * cell_w_px),
        .bottom = @min(main_h_px, (a.start_row + a.rows) * cell_h_px),
    };
}

fn size(kind: Kind, s: Surface, in: Inputs) [2]i32 {
    const pad = 2 * paddingPx(kind, in.scale);
    const icon: i32 = if (kind == .cmdline) cmdline_icon_strip_pt * in.scale else 0;
    // The copy button sits beside the text, never over it.
    const copy: i32 = if (hasCopy(kind, in)) (copy_margin_left_pt + copy_size_pt + copy_margin_right_pt) * in.scale else 0;
    return .{
        @as(i32, @intCast(s.cols)) * in.cell_w_px + pad + icon + copy,
        @as(i32, @intCast(s.rows)) * in.cell_h_px + pad,
    };
}

/// The rect of every open surface, by kind; null for one that is closed or
/// cannot be placed (a cmdline completion with no cmdline).
pub fn place(surfaces: *const [4]Surface, in: Inputs) [4]?Rect {
    var out: [4]?Rect = @splat(null);
    const area: rules.Rect = .{ .left = 0, .top = 0, .right = in.main_w_px, .bottom = in.main_h_px };

    if (surfaces[@intFromEnum(Kind.cmdline)].open) {
        const wh = size(.cmdline, surfaces[@intFromEnum(Kind.cmdline)], in);
        // Centred, a third of the free height down, as a new cmdline opens on
        // Windows (centredOnWorkArea with a divisor of 3).
        const margin = cmdline_screen_margin_pt * in.scale;
        const w = @min(wh[0], @max(0, in.main_w_px - 2 * margin));
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
        }
        out[@intFromEnum(Kind.cmdline)] = r;
    }

    // A box wider than a narrow target keeps its left edge in the view.
    const msg_area = in.msg_target orelse area;
    const history = surfaces[@intFromEnum(Kind.msg_history)];
    if (history.open) {
        const wh = size(.msg_history, history, in);
        const o = rules.msgFloatTopRight(msg_area, wh[0], null, msg_margin_pt * in.scale, msg_history_gap_pt * in.scale);
        out[@intFromEnum(Kind.msg_history)] = .{ .x = @max(0, o.x), .y = o.y, .w = wh[0], .h = wh[1] };
    }
    const show = surfaces[@intFromEnum(Kind.msg_show)];
    if (show.open) {
        const wh = size(.msg_show, show, in);
        const history_bottom: ?i32 = if (out[@intFromEnum(Kind.msg_history)]) |r| r.bottom() else null;
        const o = rules.msgFloatTopRight(msg_area, wh[0], history_bottom, msg_margin_pt * in.scale, msg_history_gap_pt * in.scale);
        out[@intFromEnum(Kind.msg_show)] = .{ .x = @max(0, o.x), .y = o.y, .w = wh[0], .h = wh[1] };
    }

    const pum = surfaces[@intFromEnum(Kind.popupmenu)];
    if (pum.open) {
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
                .x = core.zonvie_core_popupmenu_left(ax, wh[0], 0, 0, in.main_w_px),
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
    const grid = msgTarget(.grid, a, 800, 600, 10, 20);
    try testing.expectEqual(rules.Rect{ .left = 400, .top = 0, .right = 800, .bottom = 560 }, grid);
    try testing.expectEqual(rules.Rect{ .left = 0, .top = 0, .right = 800, .bottom = 600 }, msgTarget(.window, a, 800, 600, 10, 20));
    var ext = a;
    ext.anchor_surface = 7;
    try testing.expectEqual(@as(i32, 0), msgTarget(.grid, ext, 800, 600, 10, 20).left);

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
