//! A window's per-grid font, as a function of what kind of window it is.
//!
//! Neovim treats a split, an in-window float and an external window
//! differently when a UI asks for a size, and every per-grid font decision
//! (where the frame comes from, what a request counts, how the size is given
//! back, what a grid_resize means) follows from that difference. The kind is
//! switched on here and nowhere else; the core reads state, calls these, and
//! carries out what they return.

const std = @import("std");
const font_slots = @import("font_slots.zig");

pub const FontMode = enum { resize, font_view, scale_view };

/// win_pos' width/height (a split's frame), a grid size, or a request, in cells.
pub const WinFrame = struct { rows: u32, cols: u32 };

/// One window's per-grid font (font_slots.zig). Cell sizes are the slot's;
/// frame cells are global cells; extent_* is the pixel box the frontend
/// clips the layer to.
pub const GridFont = struct {
    win_id: i64,
    font_id: u32,
    mode: FontMode,
    cell_w_px: u32,
    cell_h_px: u32,
    frame_rows: u32,
    frame_cols: u32,
    /// The last try_resize_grid this font sent or adopted; null before one.
    req: ?WinFrame = null,
    extent_w_px: u32 = 0,
    extent_h_px: u32 = 0,
    /// An OS resize's request is out and unanswered: the next grid_resize
    /// answers it, whatever size Neovim settled on.
    os_answer_pending: bool = false,
};

pub const WindowKind = enum {
    split,
    /// Never resized: try_resize_grid on a float rewrites its config
    /// (nvim ui.c:769-773), which plugins would observe.
    float,
    /// Held by Neovim as a float (winfloat.c win_config_float): a request is
    /// its whole grid. Its frame is its OS window, which no layout moves.
    external,

    /// The mode a window applies its font in, or null when it has none.
    /// zonvie_* wins over neovide_font_scale, which only floats honour.
    pub fn fontMode(k: WindowKind, has_zonvie: bool, has_neovide_scale: bool) ?FontMode {
        if (has_zonvie) return if (k == .float) .font_view else .resize;
        if (has_neovide_scale and k == .float) return .scale_view;
        return null;
    }
};

pub const PlanIn = struct {
    kind: WindowKind,
    mode: FontMode,
    win_id: i64,
    font_id: u32,
    cell_w_px: u32,
    cell_h_px: u32,
    /// The global cell; both at least 1.
    global_w_px: u32,
    global_h_px: u32,
    /// The grid's font before this one, same window.
    prev: ?GridFont,
    /// The grid's current size.
    logical: WinFrame,
    /// win_pos' frame; a split's only.
    win_frame: ?WinFrame,
    /// Winbar and other margin rows of the grid.
    margin_rows: u32,
};

pub const Plan = struct {
    font: GridFont,
    /// try_resize_grid to send, or null.
    request: ?WinFrame,
    /// Neovim keeps a split's request until a 0x0 clears it (ui.c:775-778),
    /// so the core records it for clearRequest's `held`.
    hold_request: bool,
};

/// The font a window gets, and the request that makes its grid fill its frame.
pub fn plan(in: PlanIn) Plan {
    std.debug.assert(in.global_w_px > 0 and in.global_h_px > 0);
    std.debug.assert(in.cell_w_px > 0 and in.cell_h_px > 0);
    std.debug.assert(in.mode != .resize or in.kind != .float);
    const gw = in.global_w_px;
    const gh = in.global_h_px;
    var gf: GridFont = .{
        .win_id = in.win_id,
        .font_id = in.font_id,
        .mode = in.mode,
        .cell_w_px = in.cell_w_px,
        .cell_h_px = in.cell_h_px,
        .frame_rows = 0,
        .frame_cols = 0,
    };
    var request: ?WinFrame = null;
    switch (in.mode) {
        .resize => {
            const prev_resize: ?GridFont = if (in.prev) |p| (if (p.mode == .resize) p else null) else null;
            // A split's frame comes from win_pos. An external window keeps
            // the frame it had when the font was applied; the first time,
            // that is its current grid size.
            const frame: WinFrame = switch (in.kind) {
                .split => in.win_frame orelse in.logical,
                .external => if (prev_resize) |p| .{ .rows = p.frame_rows, .cols = p.frame_cols } else in.logical,
                .float => unreachable,
            };
            gf.frame_rows = frame.rows;
            gf.frame_cols = frame.cols;
            gf.extent_w_px = frame.cols * gw;
            gf.extent_h_px = frame.rows * gh;
            gf.req = if (prev_resize) |p| p.req else null;
            // A split's request is its view height (window.c
            // win_set_inner_size); the grid adds the winbar, which the frame
            // already counts. An external window's is the whole grid. Width
            // has no such rows to leave.
            const leave: u32 = if (in.kind == .split) in.margin_rows else 0;
            const want: WinFrame = .{
                .rows = @max(1, font_slots.requestedCells(frame.rows, gh, gf.cell_h_px, max_grid_rows) -| leave),
                .cols = font_slots.requestedCells(frame.cols, gw, gf.cell_w_px, max_grid_cols),
            };
            // An external window's request in an unchanged font is the OS
            // window's own. Its frame is that request rounded up to global
            // cells, so recomputing the request or extent from the frame
            // would differ from the window it has.
            if (in.kind == .external and gf.req != null and
                prev_resize.?.cell_w_px == gf.cell_w_px and prev_resize.?.cell_h_px == gf.cell_h_px)
            {
                gf.extent_w_px = prev_resize.?.extent_w_px;
                gf.extent_h_px = prev_resize.?.extent_h_px;
                gf.os_answer_pending = prev_resize.?.os_answer_pending;
            } else if (gf.req == null or !std.meta.eql(gf.req.?, want)) {
                gf.req = want;
                request = want;
            }
        },
        // Neovim's rows and columns, every one drawn in the grid's own cell:
        // the border Neovim writes into the outer cells stays whole, and the
        // float's footprint on the global lattice follows the font.
        .font_view, .scale_view => {
            gf.frame_rows = font_slots.footprintCells(in.logical.rows, gf.cell_h_px, gh);
            gf.frame_cols = font_slots.footprintCells(in.logical.cols, gf.cell_w_px, gw);
            gf.extent_w_px = in.logical.cols * gf.cell_w_px;
            gf.extent_h_px = in.logical.rows * gf.cell_h_px;
        },
    }
    return .{ .font = gf, .request = request, .hold_request = in.mode == .resize and in.kind == .split };
}

/// Whether the frontend must be told: the font, its cell or its extent moved.
pub fn differs(prev: ?GridFont, gf: GridFont) bool {
    const p = prev orelse return true;
    return p.font_id != gf.font_id or p.cell_w_px != gf.cell_w_px or p.cell_h_px != gf.cell_h_px or
        p.extent_w_px != gf.extent_w_px or p.extent_h_px != gf.extent_h_px;
}

/// The request that gives a window its size back when its font is cleared,
/// or null. 0x0 clears a split's request (ui.c:775-778); it is sent only to a
/// split, since on a float it means a 1x1 config. `held`: Neovim still holds
/// a request this split made under an earlier font. An external window is
/// re-requested in global cells for its frame.
pub fn clearRequest(kind: WindowKind, prev: ?GridFont, held: bool) ?WinFrame {
    const resized = if (prev) |p| p.mode == .resize else false;
    return switch (kind) {
        .split => if (held or resized) .{ .rows = 0, .cols = 0 } else null,
        .external => if (resized) .{ .rows = prev.?.frame_rows, .cols = prev.?.frame_cols } else null,
        .float => null,
    };
}

pub const ResizeMeaning = enum {
    /// Nothing for the font to do.
    none,
    /// The answer to an OS resize, whatever size Neovim settled on.
    os_answer,
    /// Neovim gave a split another size than asked (its layout changed
    /// under it): the frame moved, read the font again.
    requery,
    /// Neovim resized an external window on its own (:resize in it): its
    /// grid becomes its frame.
    adopt,
};

/// What a grid_resize to `size` means for a resize-mode font. `margin_rows`
/// counts only while Neovim holds a split request (its grid is the request
/// plus the winbar, ui.c:775).
pub fn resizeMeaning(kind: WindowKind, gf: GridFont, size: WinFrame, margin_rows: u32) ResizeMeaning {
    if (gf.mode != .resize) return .none;
    const req = gf.req orelse return .none;
    return switch (kind) {
        // A float holding a resize font is a split Neovim just turned into
        // one; the re-read that follows clears it.
        .split, .float => if (req.rows + margin_rows != size.rows or req.cols != size.cols) .requery else .none,
        .external => if (gf.os_answer_pending) .os_answer else if (!std.meta.eql(req, size)) .adopt else .none,
    };
}

/// Take `size` (an OS window's request, or Neovim's own resize) as an
/// external font grid's request, frame and extent. True when the extent moved.
pub fn adoptSize(gf: *GridFont, size: WinFrame, global_w_px: u32, global_h_px: u32) bool {
    gf.req = size;
    gf.frame_rows = font_slots.footprintCells(size.rows, gf.cell_h_px, @max(1, global_h_px));
    gf.frame_cols = font_slots.footprintCells(size.cols, gf.cell_w_px, @max(1, global_w_px));
    const ext_w = size.cols * gf.cell_w_px;
    const ext_h = size.rows * gf.cell_h_px;
    if (ext_w == gf.extent_w_px and ext_h == gf.extent_h_px) return false;
    gf.extent_w_px = ext_w;
    gf.extent_h_px = ext_h;
    return true;
}

const max_grid_rows = @import("grid.zig").MAX_GRID_ROWS;
const max_grid_cols = @import("grid.zig").MAX_GRID_COLS;

// ── tests ────────────────────────────────────────────────────────────────

const testing = std.testing;

fn in0(kind: WindowKind, mode: FontMode) PlanIn {
    return .{
        .kind = kind,
        .mode = mode,
        .win_id = 1000,
        .font_id = 1,
        .cell_w_px = 5,
        .cell_h_px = 10,
        .global_w_px = 10,
        .global_h_px = 20,
        .prev = null,
        .logical = .{ .rows = 10, .cols = 40 },
        .win_frame = .{ .rows = 10, .cols = 40 },
        .margin_rows = 0,
    };
}

test "the font mode follows the window kind" {
    try testing.expectEqual(FontMode.resize, WindowKind.split.fontMode(true, true).?);
    try testing.expectEqual(FontMode.resize, WindowKind.external.fontMode(true, false).?);
    try testing.expectEqual(FontMode.font_view, WindowKind.float.fontMode(true, true).?);
    try testing.expectEqual(FontMode.scale_view, WindowKind.float.fontMode(false, true).?);
    try testing.expect(WindowKind.split.fontMode(false, true) == null);
    try testing.expect(WindowKind.float.fontMode(false, false) == null);
}

test "a split requests the cells that fill its win_pos frame, less its winbar" {
    var in = in0(.split, .resize);
    in.margin_rows = 1;
    const p = plan(in);
    try testing.expectEqual(WinFrame{ .rows = 19, .cols = 80 }, p.request.?);
    try testing.expectEqual(@as(u32, 400), p.font.extent_w_px);
    try testing.expectEqual(@as(u32, 200), p.font.extent_h_px);
    // The same request is not sent twice.
    in.prev = p.font;
    try testing.expect(plan(in).request == null);
}

test "only a resize-mode split leaves Neovim holding its request" {
    try testing.expect(plan(in0(.split, .resize)).hold_request);
    try testing.expect(!plan(in0(.external, .resize)).hold_request);
    try testing.expect(!plan(in0(.float, .font_view)).hold_request);
    try testing.expect(!plan(in0(.float, .scale_view)).hold_request);
}

test "an external window counts its whole grid and keeps its OS request in the same font" {
    var in = in0(.external, .resize);
    in.margin_rows = 1;
    in.win_frame = null;
    const first = plan(in);
    try testing.expectEqual(WinFrame{ .rows = 20, .cols = 80 }, first.request.?);
    var prev = first.font;
    _ = adoptSize(&prev, .{ .rows = 39, .cols = 101 }, 10, 20);
    prev.os_answer_pending = true;
    in.prev = prev;
    const again = plan(in);
    try testing.expect(again.request == null);
    try testing.expectEqual(@as(u32, 390), again.font.extent_h_px);
    try testing.expectEqual(prev.req.?, again.font.req.?);
    // Still waiting for the OS request's answer.
    try testing.expect(again.font.os_answer_pending);
}

test "a view mode never requests and draws every logical cell in its own font" {
    // Neovim's 10x40 in 5x10 px cells: 200x100 px, a footprint of 5x20 global cells.
    for ([_]FontMode{ .font_view, .scale_view }) |mode| {
        const p = plan(in0(.float, mode));
        try testing.expect(p.request == null);
        try testing.expectEqual(@as(u32, 200), p.font.extent_w_px);
        try testing.expectEqual(@as(u32, 100), p.font.extent_h_px);
        try testing.expectEqual(@as(u32, 20), p.font.frame_cols);
        try testing.expectEqual(@as(u32, 5), p.font.frame_rows);
    }
}

test "clearing gives a split 0x0, an external window its frame, and a float nothing" {
    const p = plan(in0(.split, .resize)).font;
    try testing.expectEqual(WinFrame{ .rows = 0, .cols = 0 }, clearRequest(.split, p, false).?);
    try testing.expectEqual(WinFrame{ .rows = 0, .cols = 0 }, clearRequest(.split, null, true).?);
    try testing.expect(clearRequest(.split, null, false) == null);
    try testing.expectEqual(WinFrame{ .rows = 10, .cols = 40 }, clearRequest(.external, p, false).?);
    try testing.expect(clearRequest(.float, p, true) == null);
}

test "a grid_resize is an answer, a frame change or an adoption by kind" {
    var gf = plan(in0(.split, .resize)).font; // req 20x80
    try testing.expectEqual(ResizeMeaning.none, resizeMeaning(.split, gf, .{ .rows = 20, .cols = 80 }, 0));
    try testing.expectEqual(ResizeMeaning.none, resizeMeaning(.split, gf, .{ .rows = 21, .cols = 80 }, 1));
    try testing.expectEqual(ResizeMeaning.requery, resizeMeaning(.split, gf, .{ .rows = 18, .cols = 80 }, 0));
    try testing.expectEqual(ResizeMeaning.adopt, resizeMeaning(.external, gf, .{ .rows = 30, .cols = 80 }, 0));
    gf.os_answer_pending = true;
    try testing.expectEqual(ResizeMeaning.os_answer, resizeMeaning(.external, gf, .{ .rows = 30, .cols = 80 }, 0));
    gf.req = null;
    try testing.expectEqual(ResizeMeaning.none, resizeMeaning(.split, gf, .{ .rows = 1, .cols = 1 }, 0));
}
