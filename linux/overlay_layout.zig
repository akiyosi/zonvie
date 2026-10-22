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

/// Unscaled chrome, as windows/app.zig's CMDLINE_* and MSG_* constants.
pub const cmdline_padding_pt: i32 = 12;
pub const msg_padding_pt: i32 = 8;
pub const cmdline_screen_margin_pt: i32 = 40;
const msg_margin_pt: i32 = 10;
const msg_history_gap_pt: i32 = 4;
const cmdline_popup_gap_pt: i32 = 4;

pub fn paddingPx(kind: Kind, scale: i32) i32 {
    return scale * switch (kind) {
        .cmdline => cmdline_padding_pt,
        .msg_show, .msg_history => msg_padding_pt,
        .popupmenu => 0,
    };
}

pub const Inputs = struct {
    main_w_px: i32,
    main_h_px: i32,
    cell_w_px: i32,
    cell_h_px: i32,
    /// Integer surface scale for the chrome constants.
    scale: i32,
};

fn size(kind: Kind, s: Surface, in: Inputs) [2]i32 {
    const pad = 2 * paddingPx(kind, in.scale);
    return .{
        @as(i32, @intCast(s.cols)) * in.cell_w_px + pad,
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
        out[@intFromEnum(Kind.cmdline)] = .{
            .x = @divTrunc(in.main_w_px - w, 2),
            .y = @max(0, @divTrunc(in.main_h_px - wh[1], 3)),
            .w = w,
            .h = wh[1],
        };
    }

    const history = surfaces[@intFromEnum(Kind.msg_history)];
    if (history.open) {
        const wh = size(.msg_history, history, in);
        const o = rules.msgFloatTopRight(area, wh[0], null, msg_margin_pt * in.scale, msg_history_gap_pt * in.scale);
        out[@intFromEnum(Kind.msg_history)] = .{ .x = o.x, .y = o.y, .w = wh[0], .h = wh[1] };
    }
    const show = surfaces[@intFromEnum(Kind.msg_show)];
    if (show.open) {
        const wh = size(.msg_show, show, in);
        const history_bottom: ?i32 = if (out[@intFromEnum(Kind.msg_history)]) |r| r.bottom() else null;
        const o = rules.msgFloatTopRight(area, wh[0], history_bottom, msg_margin_pt * in.scale, msg_history_gap_pt * in.scale);
        out[@intFromEnum(Kind.msg_show)] = .{ .x = o.x, .y = o.y, .w = wh[0], .h = wh[1] };
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
            const ax = cmd.x + paddingPx(.cmdline, in.scale) + @max(0, pum.start_col) * in.cell_w_px;
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
    try testing.expectEqual(@as(i32, 424), r.w);
    try testing.expectEqual(@as(i32, 188), r.x);
    try testing.expectEqual(@as(i32, 44), r.h);
    try testing.expectEqual(@as(i32, 185), r.y);
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
