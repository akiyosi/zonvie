//! The pointer over a surface: the cell a position names, the grid a held
//! press keeps addressing, and the state a gesture carries. No window system
//! here: main.zig feeds it the positions and buttons it gets.

const std = @import("std");
const core = @import("zonvie_core");
const clock = core.clock;
const rules = core.frontend_rules;
const App = @import("app.zig").App;
const transform = @import("transform.zig");
const layer_geom = @import("layer_geom.zig");
const overlay_layout = @import("overlay_layout.zig");
const trackpad = @import("trackpad.zig");
const gl_renderer = @import("renderer/gl_renderer.zig");
const core_timers = @import("core_timers.zig");
const applog = @import("app_log.zig");

/// One window's pointer: the surface it addresses and the press it is
/// tracking. The main window's lives in App.
pub const Pointer = struct {
    app: *App,
    /// 1 for the main window.
    surface_id: i64 = 1,
    /// Logical widget px of the last pointer motion; the wheel has no position.
    x: f64 = 0,
    y: f64 = 0,
    /// The buttons held since a press sent to Neovim, and the grid the
    /// claiming press chose.
    claim: rules.PressClaim = .{},
    press_grid_id: i64 = 1,
    drag_row: i32 = -1,
    drag_col: i32 = -1,
    /// The scrollbar took the held press; Neovim never saw it.
    bar_held: bool = false,
    /// The pointer shows the hand: the cell under it holds a URL.
    url_hand: bool = false,
    /// A left press on an ext UI panel, which Neovim never sees.
    panel_press: ?PanelPress = null,
    /// The message grid (-102 / -103) the pointer rests on, 0 for none.
    msg_hover: i64 = 0,
    /// Logical px of the pointer over the overlay panelHover watches (a
    /// popup's: its own area), null while it is elsewhere. Read again after
    /// every flush (refreshPanelHover): a panel opens, moves or closes under
    /// a pointer that sends no motion.
    hover_at: ?[2]f64 = null,
    /// The touchpad gesture and the wheel's fractional steps.
    scroll: trackpad.State = .{},
    /// Latched when a file drag enters: its drop would insert the paths.
    /// The mode cannot change while the drag is held, and motion fires on
    /// every move, so it is not re-read there.
    drag_inserts_path: bool = false,
};

/// A left press held on a panel: on msg_show's close badge (a click
/// dismisses it on release over the badge), or dragging the cmdline or
/// msg_show.
pub const PanelPress = struct {
    kind: overlay_layout.Kind,
    badge: bool,
    /// Logical widget px of the press.
    x: f64,
    y: f64,
    /// The panel at the press, surface px.
    rect: overlay_layout.Rect,
    /// Past the threshold: the panel follows the pointer.
    moved: bool = false,
};

pub const Cell = struct { grid_id: i64, row: i32, col: i32 };

fn refreshGrids(app: *App, cp: *core.zonvie_core) void {
    var total: usize = 0;
    const n = core.zonvie_core_try_get_visible_grids_complete(cp, &app.pointer_grids, app.pointer_grids.len, &total);
    if (n >= 0) app.pointer_grids_len = @intCast(n);
}

/// Surface cell under logical widget px (x, y).
fn surfaceCell(app: *App, x: f64, y: f64) ?@TypeOf(transform.pxToCell(0, 0, 1, 1)) {
    app.mu.lockUncancelable(clock.io());
    const cw = app.cell_w_px;
    const ch = app.cell_h_px;
    const s: f64 = app.scale;
    app.mu.unlock(clock.io());
    if (cw == 0 or ch == 0) return null;
    return transform.pxToCell(x * s, y * s, cw, ch);
}

/// The cell logical widget px (x, y) names in `grid_id`, by the core's rule:
/// where the grid's committed layer sits and the sub-row ease the last frame
/// drew it with. Null when the surface has no layer for the grid.
fn gridCell(p: *Pointer, grid_id: i64, x: f64, y: f64) ?Cell {
    const app = p.app;
    // The ext UI grids are overlays this frontend places, not layers.
    if (grid_id <= 0) return null;
    var geom: core.pointer_target.GridGeometry = undefined;
    var local: [2]f32 = undefined;
    var ease_px: f32 = 0;
    {
        app.mu.lockUncancelable(clock.io());
        defer app.mu.unlock(clock.io());
        if (app.cell_w_px == 0 or app.cell_h_px == 0) return null;
        const layer = for (app.surface.committedSurfaceLayers(p.surface_id)) |l| {
            if (l.grid_id == grid_id) break l;
        } else return null;
        const s: f64 = app.scale;
        local = .{
            @floatCast(x * s - @as(f64, @floatFromInt(layer.x_px))),
            @floatCast(y * s - @as(f64, @floatFromInt(layer.y_px))),
        };
        // The grid's own cell and box when it is drawn in its own font, as
        // the painter places it (windows/input.zig gridCellAt).
        const g = layer_geom.Geom.of(layer, app.surface.gridFont(grid_id), app.cell_w_px, app.cell_h_px);
        geom = .{
            .cell_w_px = g.cell_w_px,
            .cell_h_px = g.row_h_px,
            .extent_w_px = g.widthPx(),
            .extent_h_px = g.heightPx(),
            .rows = @intCast(layer.rows),
            .cols = @intCast(layer.cols),
        };
        if (app.surface.gridEase(grid_id)) |e| {
            if (e.easing) ease_px = e.offset_px;
        }
    }
    for (app.pointer_grids[0..app.pointer_grids_len]) |g| {
        if (g.grid_id != grid_id) continue;
        geom.margin_top = g.margin_top;
        geom.margin_bottom = g.margin_bottom;
        break;
    }
    const hit = core.pointer_target.cellInGridEased(local[0], local[1], ease_px, geom);
    return .{ .grid_id = grid_id, .row = hit.row, .col = hit.col };
}

/// The surface's own root grid takes a position no grid claims. Only a drag
/// keeps a cell above or left of its first: Neovim scrolls a drag selection
/// by how far past the edge it is, and "row 0" would stop that scroll.
fn rootCell(p: *Pointer, x: f64, y: f64, allow_negative: bool) ?Cell {
    const c = gridCell(p, p.surface_id, x, y) orelse blk: {
        const sc = surfaceCell(p.app, x, y) orelse return null;
        break :blk Cell{ .grid_id = p.surface_id, .row = sc.row, .col = sc.col };
    };
    if (allow_negative) return c;
    return .{ .grid_id = p.surface_id, .row = @max(0, c.row), .col = @max(0, c.col) };
}

/// On a miss the surface's own root grid takes the position.
pub fn resolve(p: *Pointer, cp: *core.zonvie_core, x: f64, y: f64, require_scrollable: c_int) ?Cell {
    const app = p.app;
    const c = surfaceCell(app, x, y) orelse return null;
    refreshGrids(app, cp);
    var hit: core.zonvie_pointer_hit = undefined;
    if (core.zonvie_core_resolve_pointer_grid(&app.pointer_grids, app.pointer_grids_len, p.surface_id, c.row, c.col, require_scrollable, &hit) != 0) {
        if (hit.grid_id == p.surface_id) return rootCell(p, x, y, false);
        return gridCell(p, hit.grid_id, x, y) orelse .{ .grid_id = hit.grid_id, .row = hit.row, .col = hit.col };
    }
    return rootCell(p, x, y, false);
}

/// Rebases a surface position into the grid the press chose, so a drag that
/// leaves a float keeps addressing it.
pub fn inPressGrid(p: *Pointer, x: f64, y: f64, allow_negative: bool) ?Cell {
    if (p.press_grid_id != p.surface_id) {
        if (gridCell(p, p.press_grid_id, x, y)) |c| return c;
    }
    return rootCell(p, x, y, allow_negative);
}

// =========================================================================
// The ext UI panels drawn in the view
// =========================================================================

const panel_drag_threshold = 3.0;

/// The panels drawn on the view and what placed them. Caller holds App.mu.
fn surfacePanels(p: *const Pointer) ?struct { rects: [4]?overlay_layout.Rect, in: overlay_layout.Inputs } {
    const app = p.app;
    if (app.drawable_w_px == 0 or app.cell_w_px == 0 or app.cell_h_px == 0) return null;
    const in = gl_renderer.overlayInputs(app, p.surface_id, app.drawable_w_px, app.drawable_h_px);
    return .{ .rects = overlay_layout.place(&app.overlays, in), .in = in };
}

/// A main-window position on a panel, surface px, with what placed it.
pub const PanelHit = struct {
    kind: overlay_layout.Kind,
    rect: overlay_layout.Rect,
    in: overlay_layout.Inputs,
    x_px: i32,
    y_px: i32,

    pub fn onBadge(self: PanelHit) bool {
        const b = overlay_layout.closeBadgeRect(self.kind, self.rect, self.in.scale) orelse return false;
        return overlay_layout.contains(b, self.x_px, self.y_px);
    }

    /// The panel grid's cell under the position.
    pub fn cell(self: PanelHit) Cell {
        const rc = overlay_layout.panelCell(self.kind, self.rect, self.x_px, self.y_px, self.in);
        return .{ .grid_id = overlay_layout.gridId(self.kind), .row = rc[0], .col = rc[1] };
    }
};

/// The panel at logical px (x, y) of the view, by the layout its frames are
/// drawn with; null elsewhere.
pub fn panelAt(p: *const Pointer, x: f64, y: f64) ?PanelHit {
    const app = p.app;
    app.mu.lockUncancelable(clock.io());
    defer app.mu.unlock(clock.io());
    const panels = surfacePanels(p) orelse return null;
    const rects = panels.rects;
    const xp: i32 = @intFromFloat(@floor(x * app.scale));
    const yp: i32 = @intFromFloat(@floor(y * app.scale));
    const kind = overlay_layout.hit(&rects, xp, yp) orelse return null;
    return .{ .kind = kind, .rect = rects[@intFromEnum(kind)].?, .in = panels.in, .x_px = xp, .y_px = yp };
}

/// A press on a panel. Every button is swallowed: the core refuses buttons
/// on its own grids (pointer_target.buttonReachesNeovim), and neither macOS
/// nor Windows selects a popupmenu item on a click. A left press with no
/// editor button held may close msg_show by its badge or drag the cmdline or
/// msg_show.
pub fn pressPanel(p: *Pointer, h: PanelHit, left: bool, x: f64, y: f64) void {
    if (!left or p.claim.held_mask != 0 or p.panel_press != null) return;
    const badge = h.onBadge();
    if (!badge and h.kind != .cmdline and h.kind != .msg_show) return;
    p.panel_press = .{ .kind = h.kind, .badge = badge, .x = x, .y = y, .rect = h.rect };
}

/// The left button let go of a panel press: a badge click dismisses
/// msg_show when it ends on the badge too.
pub fn releasePanel(p: *Pointer, pp: PanelPress, x: f64, y: f64) void {
    if (!pp.badge) return;
    const h = panelAt(p, x, y) orelse return;
    if (h.kind != .msg_show or !h.onBadge()) return;
    const cp = p.app.corep orelse return;
    core.zonvie_core_dismiss_msg_show(cp);
    core_timers.scheduleMsg(p.app);
}

/// Moves the dragged panel with the pointer once it is past the threshold.
/// The first real move pins msg_show until it closes
/// (MsgShowChrome.dragEnded), as Windows' WM_MOVING does; the cmdline keeps
/// its spot for the session.
pub fn dragPanel(p: *Pointer, pp: *PanelPress, x: f64, y: f64) void {
    const dx = x - pp.x;
    const dy = y - pp.y;
    if (!pp.moved and @abs(dx) < panel_drag_threshold and @abs(dy) < panel_drag_threshold) return;
    pp.moved = true;
    const app = p.app;
    {
        app.mu.lockUncancelable(clock.io());
        defer app.mu.unlock(clock.io());
        var r = pp.rect;
        r.x += @intFromFloat(@round(dx * app.scale));
        r.y += @intFromFloat(@round(dy * app.scale));
        switch (pp.kind) {
            .cmdline => app.cmdline_user = r,
            .msg_show => {
                app.msg_show_user = .{ r.x, r.y };
                app.msg_chrome.dragEnded(true);
            },
            .popupmenu, .msg_history => unreachable,
        }
    }
    app.queueRenderAll();
    // The copy button travels with its panel, and so does its popup.
    @import("shell.zig").rebuild(app, true);
    @import("panel_popup.zig").update(app);
}

/// The pointer over the view (logical px), or gone when null: the message
/// panel it rests on stops its auto-hide countdown
/// (zonvie_core_set_msg_hover) and msg_show shows its close badge.
pub fn panelHover(p: *Pointer, at: ?[2]f64) void {
    const app = p.app;
    const h: ?PanelHit = if (at) |pt| panelAt(p, pt[0], pt[1]) else null;
    const grid: i64 = if (h) |v| switch (v.kind) {
        .msg_show, .msg_history => overlay_layout.gridId(v.kind),
        else => 0,
    } else 0;
    const on_show = if (h) |v| v.kind == .msg_show else false;
    const on_badge = if (h) |v| v.onBadge() else false;
    app.mu.lockUncancelable(clock.io());
    const badge_changed = app.msg_chrome.pointer(on_show, on_badge);
    app.mu.unlock(clock.io());
    if (badge_changed) app.queueRenderAll();
    if (grid == p.msg_hover) return;
    const cp = app.corep orelse return;
    if (p.msg_hover != 0) core.zonvie_core_set_msg_hover(cp, p.msg_hover, 0);
    if (grid != 0) core.zonvie_core_set_msg_hover(cp, grid, 1);
    p.msg_hover = grid;
    // What the GUI harness reads the hover from.
    applog.appLog("[msg_hover] surface={d} grid={d}\n", .{ p.surface_id, grid });
    // Both transitions move the earliest deadline (zonvie_core.h).
    core_timers.scheduleMsg(app);
}

/// The pointer is off the view.
pub fn panelLeft(p: *Pointer) void {
    p.hover_at = null;
    panelHover(p, null);
}

/// The panel hover again where the pointer rests: a flush can open a message
/// under a still pointer or close the one it held. Main thread.
pub fn refreshPanelHover(app: *App) void {
    const p = &app.pointer;
    const at = p.hover_at orelse return;
    panelHover(p, at);
}
