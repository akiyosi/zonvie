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
