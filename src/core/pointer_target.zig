//! Which grid a pointer names, for every frontend.
//!
//! Both frontends were deciding this themselves, and the two answers drifted.
//! macOS walked the grid list and had to be told separately which grids an
//! external surface hosts — without that it hit-tested a float drawn in
//! another window, and a wheel event on the main window scrolled it.
//! Windows walked its layer list, which excluded those for free,
//! but in exchange its main-window branch applied neither the mouse flag nor
//! the scrollability rule. Each frontend had part of the rule.
//!
//! The rule is here, once. The enumeration is NOT: "which grids are visible"
//! already has one answer in `nvim_core.getVisibleGridsSnapshotLocked`, and a
//! second walk of `win_pos` would be the same mistake one level down. A caller
//! passes the grids it already has, with the three facts the rule needs that
//! `zonvie_grid_info` does not carry.

const std = @import("std");

/// The shape the rule reads. `zonvie_grid_info` carries these fields; the
/// function is generic over the type so the tests can declare their own and
/// the export can pass the core's array with no copy.
///
/// `placed_by_surface` is which surface composites this grid — the main window
/// is 1, an external window is its own grid id. A grid placed by a surface
/// other than the one being asked about reports its position in THAT surface's
/// space, so reading those numbers as the asking surface's own invents a
/// region shaped like the grid, wherever the numbers happen to land.
pub const Candidate = struct {
    grid_id: i64,
    /// Only says whether this is a float, for `require_scrollable`.
    zindex: i64,
    /// The grid's z in its surface's published layer list: the one answer to
    /// "which of these is drawn on top".
    layer_z: i64,
    start_row: i32,
    start_col: i32,
    rows: i32,
    cols: i32,
    /// The grid's own rows, the unit `margin_*` and `line_count` are in.
    /// `rows` is its footprint on the surface when it has its own font.
    grid_rows: i32,
    margin_top: i32,
    margin_bottom: i32,
    /// Buffer lines this grid holds, or 0 when the viewport has not been
    /// reported. Only `require_scrollable` reads it.
    line_count: i64,
    /// 1 when this grid is a window of its own, reported at (0,0).
    is_external: u8,
    placed_by_surface: i64,
    /// win_float_pos' mouse_enabled. Always 1 for a root or a split.
    mouse_enabled: u8,
};

pub const Hit = extern struct {
    grid_id: i64,
    row: i32,
    col: i32,
};

/// Whether a float can scroll its own content: it holds more buffer lines than
/// its content area shows. A float that already shows every line is
/// transparent to a wheel event, which then reaches whatever is drawn under it.
/// Counted in the grid's own rows: a grid in its own font covers `rows`
/// surface cells but shows `grid_rows` of its lines.
pub fn capturesScroll(c: anytype) bool {
    const content_rows: i64 = @max(0, @as(i64, c.grid_rows) - @as(i64, c.margin_top) - @as(i64, c.margin_bottom));
    return c.line_count > content_rows;
}

/// Whether a button press, release or drag addressed to `grid_id` may reach
/// Neovim. The ids the core reserves for its own surfaces (cmdline,
/// popupmenu, messages) are negative and name no Neovim window: forwarded,
/// Neovim resolves the position against the screen instead, so a click on a
/// message moved the cursor in the buffer behind it and a middle click pasted
/// there. Windows refused these in its frontend and macOS sent them; the core
/// refuses them now for both. Wheel events ask wheelReachesNeovim.
pub fn buttonReachesNeovim(grid_id: i64) bool {
    return grid_id >= 0;
}

/// The wheel's version of buttonReachesNeovim, asked after the message grid
/// has taken its own scroll. -1 is the cursor-grid sentinel the core resolves.
/// A wheel over the popupmenu or the history panel, forwarded, scrolled
/// whichever window sat at that position on the screen.
pub fn wheelReachesNeovim(grid_id: i64) bool {
    return grid_id >= 0 or grid_id == -1;
}

/// The grid at (`row`, `col`) of `surface_id`, in that grid's own cells.
///
/// `require_scrollable` is the wheel's extra rule and a click's is false: a
/// non-scrollable float does not capture scroll, and skipping it lets the loop
/// keep looking rather than stop, so a scrollable grid directly beneath one
/// still takes the event.
///
/// Returns null when nothing matches; the caller then keeps its own surface's
/// grid and the unshifted position, which is what both frontends already did.
/// An external surface's own root (is_external = 1) is never returned: it is
/// that fallback.
pub fn resolve(
    comptime Grid: type,
    grids: []const Grid,
    surface_id: i64,
    row: i32,
    col: i32,
    require_scrollable: bool,
) ?Hit {
    var best: ?Grid = null;
    for (grids) |g| {
        // A window of its own is not a region of this one.
        if (g.is_external != 0) continue;
        // Nor is a grid some other surface composites.
        if (g.placed_by_surface != surface_id) continue;
        // A float that refuses the mouse is not a target and does not shadow
        // one: Neovim looks the window up by handle, rejects it, and returns
        // without re-resolving (mouse.c's mouse_find_grid_win, then
        // mouse_find_win_inner's `else if (*gridp > 1) return NULL`), so naming
        // it swallows the event instead of letting it reach what is underneath.
        if (g.mouse_enabled == 0) continue;
        if (row < g.start_row or row >= g.start_row + g.rows) continue;
        if (col < g.start_col or col >= g.start_col + g.cols) continue;
        if (require_scrollable and g.zindex > 0 and !capturesScroll(g)) continue;
        // Front-most wins, by the order the surface published. A grid not
        // published yet carries 0, the root's z, so grid_id decides between it
        // and the container grid.
        const dominated = if (best) |b| drawnInFrontOf(g, b) else true;
        if (dominated) best = g;
    }
    const b = best orelse return null;
    return .{ .grid_id = b.grid_id, .row = row - b.start_row, .col = col - b.start_col };
}

/// NaN maps to 0; other values clamp to +-2^24 cells so the i32 conversion cannot trap.
fn floorCell(v: f32) i32 {
    if (std.math.isNan(v)) return 0;
    return @intFromFloat(@floor(std.math.clamp(v, -16777216.0, 16777216.0)));
}

/// What a grid is, as far as a pixel inside it is concerned. The layer it is
/// drawn on is `extent_*_px` large; the grid itself is `rows` x `cols` of
/// `cell_*_px` cells, which may not fill the layer (a grid in a smaller font
/// than the frame it sits in). `rows`/`cols` 0 = unknown: the layer decides.
pub const GridGeometry = struct {
    cell_w_px: u32,
    cell_h_px: u32,
    extent_w_px: u32,
    extent_h_px: u32,
    rows: i32 = 0,
    cols: i32 = 0,
    margin_top: i32 = 0,
    margin_bottom: i32 = 0,
};

/// The cell a layer-local pixel names in `g`, when the grid is drawn
/// `scroll_offset_px` further down than its rows say (a sub-row scroll ease).
///
/// Only the scrolling band -- the rows between the margins -- moves with the
/// ease, so the offset is undone only when both the drawn row and the row it
/// came from lie inside it; a winbar or a status line is hit where it is.
/// A point inside the layer past the last cell (the leftover margin) names
/// that cell. A point outside the layer keeps its row and column, negative
/// or past the end, so a drag off the grid keeps its meaning to Neovim.
pub fn cellInGridEased(local_x_px: f32, local_y_px: f32, scroll_offset_px: f32, g: GridGeometry) Hit {
    var hit = cellInGrid(local_x_px, local_y_px, g.cell_w_px, g.cell_h_px, g.extent_w_px, g.extent_h_px);
    if (g.cell_h_px == 0) return hit;
    const layer_rows: i32 = @intCast(@max(1, g.extent_h_px / g.cell_h_px));
    const rows = if (g.rows > 0) g.rows else layer_rows;
    if (@abs(scroll_offset_px) > 0.001) {
        const from = cellInGrid(local_x_px, local_y_px - scroll_offset_px, g.cell_w_px, g.cell_h_px, g.extent_w_px, g.extent_h_px);
        const band_top = g.margin_top;
        const band_end = rows - g.margin_bottom;
        if (hit.row >= band_top and hit.row < band_end and from.row >= band_top and from.row < band_end) hit.row = from.row;
    }
    if (g.rows > 0 and insideLayer(local_y_px, g.extent_h_px)) hit.row = @min(hit.row, g.rows - 1);
    if (g.cols > 0 and insideLayer(local_x_px, g.extent_w_px)) hit.col = @min(hit.col, g.cols - 1);
    return hit;
}

fn insideLayer(px: f32, extent_px: u32) bool {
    return px < @as(f32, @floatFromInt(extent_px));
}

/// The cell `local_*_px` names in a grid of `cell_*_px` cells whose layer is
/// `extent_*_px` large. Inside the layer, past the last whole cell clamps to
/// it; outside it (negative, or past the layer) the row and column keep going.
pub fn cellInGrid(local_x_px: f32, local_y_px: f32, cell_w_px: u32, cell_h_px: u32, extent_w_px: u32, extent_h_px: u32) Hit {
    if (cell_w_px == 0 or cell_h_px == 0) return .{ .grid_id = 0, .row = 0, .col = 0 };
    const rows: i32 = @intCast(@max(1, extent_h_px / cell_h_px));
    const cols: i32 = @intCast(@max(1, extent_w_px / cell_w_px));
    const r = floorCell(local_y_px / @as(f32, @floatFromInt(cell_h_px)));
    const c = floorCell(local_x_px / @as(f32, @floatFromInt(cell_w_px)));
    return .{
        .grid_id = 0,
        .row = if (insideLayer(local_y_px, extent_h_px)) @min(r, rows - 1) else r,
        .col = if (insideLayer(local_x_px, extent_w_px)) @min(c, cols - 1) else c,
    };
}

// ── tests ────────────────────────────────────────────────────────────────

/// Whether `a` is drawn in front of `b`, by the published layer order.
fn drawnInFrontOf(a: anytype, b: anytype) bool {
    if (a.layer_z != b.layer_z) return a.layer_z > b.layer_z;
    return a.grid_id > b.grid_id;
}

const testing = std.testing;

fn win(grid_id: i64, start_row: i32, start_col: i32, rows: i32, cols: i32) Candidate {
    return .{
        .grid_id = grid_id,
        .zindex = 0,
        .layer_z = 0,
        .start_row = start_row,
        .start_col = start_col,
        .rows = rows,
        .cols = cols,
        .grid_rows = rows,
        .margin_top = 0,
        .margin_bottom = 0,
        .line_count = 10_000,
        .is_external = 0,
        .placed_by_surface = 1,
        .mouse_enabled = 1,
    };
}

fn float(grid_id: i64, start_row: i32, start_col: i32, rows: i32, cols: i32, lines: i64) Candidate {
    var c = win(grid_id, start_row, start_col, rows, cols);
    c.zindex = 50;
    c.layer_z = grid_id;
    c.line_count = lines;
    return c;
}

test "a point in a window names it, in that window's own cells" {
    const grids = [_]Candidate{ win(1, 0, 0, 40, 100), win(2, 10, 20, 10, 30) };
    const hit = resolve(Candidate, &grids, 1, 15, 25, false).?;
    try testing.expectEqual(@as(i64, 2), hit.grid_id);
    try testing.expectEqual(@as(i32, 5), hit.row);
    try testing.expectEqual(@as(i32, 5), hit.col);
}

test "a float over a window wins, because it is drawn on top" {
    const grids = [_]Candidate{ win(1, 0, 0, 40, 100), float(5, 10, 20, 10, 30, 400) };
    try testing.expectEqual(@as(i64, 5), resolve(Candidate, &grids, 1, 15, 25, false).?.grid_id);
}

test "the container grid loses to an actual window at the same zindex" {
    const grids = [_]Candidate{ win(1, 0, 0, 40, 100), win(2, 0, 0, 40, 100) };
    try testing.expectEqual(@as(i64, 2), resolve(Candidate, &grids, 1, 5, 5, false).?.grid_id);
}

test "the row and column just past a window's end are outside it" {
    // Grid 2 covers rows 10..19 and columns 20..49.
    const grids = [_]Candidate{ win(1, 0, 0, 40, 100), win(2, 10, 20, 10, 30) };
    try testing.expectEqual(@as(i64, 1), resolve(Candidate, &grids, 1, 20, 25, false).?.grid_id);
    try testing.expectEqual(@as(i64, 1), resolve(Candidate, &grids, 1, 15, 50, false).?.grid_id);
    try testing.expectEqual(@as(i64, 2), resolve(Candidate, &grids, 1, 19, 49, false).?.grid_id);
}

test "a float that refuses the mouse is skipped, and does not shadow what is under it" {
    var f = float(5, 10, 20, 10, 30, 400);
    f.mouse_enabled = 0;
    const grids = [_]Candidate{ win(1, 0, 0, 40, 100), f };
    try testing.expectEqual(@as(i64, 1), resolve(Candidate, &grids, 1, 15, 25, false).?.grid_id);
}

test "an external grid is a window of its own and is never a region of this one" {
    var e = win(4, 0, 0, 40, 100);
    e.is_external = 1;
    e.placed_by_surface = 4;
    const grids = [_]Candidate{ win(1, 0, 0, 40, 100), e };
    try testing.expectEqual(@as(i64, 1), resolve(Candidate, &grids, 1, 5, 5, false).?.grid_id);
}

test "a float another surface hosts is not hit-testable here, whatever its numbers say" {
    // The phantom: grid 5 sits at rows 10..20 of surface 4, and the main
    // window read those as its own.
    var hosted = float(5, 10, 20, 10, 30, 400);
    hosted.placed_by_surface = 4;
    const grids = [_]Candidate{ win(1, 0, 0, 40, 100), hosted };
    try testing.expectEqual(@as(i64, 1), resolve(Candidate, &grids, 1, 15, 25, false).?.grid_id);
    // …and the surface that DOES host it resolves it normally.
    var root4 = win(4, 0, 0, 40, 100);
    root4.placed_by_surface = 4;
    const own = [_]Candidate{ root4, hosted };
    try testing.expectEqual(@as(i64, 5), resolve(Candidate, &own, 4, 15, 25, false).?.grid_id);
}

test "an external surface's own root resolves to null and is left to the caller" {
    // nvim_core builds external roots with is_external = 1 and
    // placed_by_surface = their own id.
    var root4 = win(4, 0, 0, 40, 100);
    root4.placed_by_surface = 4;
    root4.is_external = 1;
    const grids = [_]Candidate{root4};
    try testing.expect(resolve(Candidate, &grids, 4, 5, 5, false) == null);
}

test "a float showing all of its content lets a wheel event through" {
    const grids = [_]Candidate{ win(1, 0, 0, 40, 100), float(5, 10, 20, 10, 30, 10) };
    try testing.expectEqual(@as(i64, 5), resolve(Candidate, &grids, 1, 15, 25, false).?.grid_id);
    try testing.expectEqual(@as(i64, 1), resolve(Candidate, &grids, 1, 15, 25, true).?.grid_id);
}

test "a scrollable float under a non-scrollable one still takes the wheel" {
    const over = float(6, 10, 20, 10, 30, 10);
    // Published over 5 (float() takes the grid id as its z).
    const grids = [_]Candidate{
        win(1, 0, 0, 40, 100),
        float(5, 10, 20, 10, 30, 400),
        over,
    };
    // 6 is drawn over 5 but shows everything; 5 is the one that scrolls.
    try testing.expectEqual(@as(i64, 6), resolve(Candidate, &grids, 1, 15, 25, false).?.grid_id);
    try testing.expectEqual(@as(i64, 5), resolve(Candidate, &grids, 1, 15, 25, true).?.grid_id);
}

test "a float's margins are not content, so a bordered float needs one line more to scroll" {
    var f = float(5, 10, 20, 10, 30, 8);
    f.margin_top = 1;
    f.margin_bottom = 1;
    // Eight content rows, eight lines: it fits.
    try testing.expect(!capturesScroll(f));
    f.line_count = 9;
    try testing.expect(capturesScroll(f));
}

test "a scaled float's scrollability counts its own rows, not its footprint" {
    // 20 rows at half height cover 10 surface rows; 2 margin rows leave 18
    // content rows, so 15 lines all fit.
    var f = float(5, 10, 20, 10, 30, 15);
    f.grid_rows = 20;
    f.margin_top = 1;
    f.margin_bottom = 1;
    try testing.expect(!capturesScroll(f));
    f.line_count = 19;
    try testing.expect(capturesScroll(f));
}

test "a button reaches Neovim for its own grids and never for a surface the core reserved" {
    const grid_mod = @import("grid.zig");
    try std.testing.expect(buttonReachesNeovim(0));
    try std.testing.expect(buttonReachesNeovim(1));
    try std.testing.expect(buttonReachesNeovim(1000));
    for ([_]i64{ grid_mod.CMDLINE_GRID_ID, grid_mod.POPUPMENU_GRID_ID, grid_mod.MESSAGE_GRID_ID, grid_mod.MSG_HISTORY_GRID_ID }) |id| {
        try std.testing.expect(!buttonReachesNeovim(id));
    }
}

test "a wheel reaches Neovim for its own grids and the cursor sentinel only" {
    const grid_mod = @import("grid.zig");
    try std.testing.expect(wheelReachesNeovim(-1));
    try std.testing.expect(wheelReachesNeovim(1));
    try std.testing.expect(wheelReachesNeovim(1000));
    for ([_]i64{ grid_mod.CMDLINE_GRID_ID, grid_mod.POPUPMENU_GRID_ID, grid_mod.MSG_HISTORY_GRID_ID }) |id| {
        try std.testing.expect(!wheelReachesNeovim(id));
    }
}

test "a point outside every grid resolves to nothing" {
    const grids = [_]Candidate{win(2, 10, 20, 10, 30)};
    try testing.expect(resolve(Candidate, &grids, 1, 0, 0, false) == null);
}

test "an empty grid list resolves to nothing" {
    try testing.expect(resolve(Candidate, &.{}, 1, 5, 5, false) == null);
}

test "a pixel in a per-grid font names that font's cell, and the margin clamps" {
    // 6x12 cells in a 100x50 px frame: 16 cols, 4 rows fit; 4 px and 2 px margins.
    const in = cellInGrid(13.0, 25.0, 6, 12, 100, 50);
    try testing.expectEqual(@as(i32, 2), in.row);
    try testing.expectEqual(@as(i32, 2), in.col);
    const margin = cellInGrid(99.0, 49.0, 6, 12, 100, 50);
    try testing.expectEqual(@as(i32, 3), margin.row);
    try testing.expectEqual(@as(i32, 15), margin.col);
    // A drag above/left of the grid keeps its sign for Neovim's drag rules.
    const drag = cellInGrid(-7.0, -1.0, 6, 12, 100, 50);
    try testing.expectEqual(@as(i32, -1), drag.row);
    try testing.expectEqual(@as(i32, -2), drag.col);
    // A zero cell never divides.
    const zero = cellInGrid(5.0, 5.0, 0, 0, 100, 50);
    try testing.expectEqual(@as(i32, 0), zero.row);
}

test "a non-finite or huge pixel coordinate clamps instead of trapping" {
    const nan = std.math.nan(f32);
    const inf = std.math.inf(f32);
    const a = cellInGrid(nan, nan, 6, 12, 100, 50);
    try testing.expectEqual(@as(i32, 0), a.row);
    try testing.expectEqual(@as(i32, 0), a.col);
    // Past the layer the coordinate keeps going, bounded by floorCell.
    const b = cellInGrid(inf, inf, 6, 12, 100, 50);
    try testing.expectEqual(@as(i32, 16777216), b.row);
    try testing.expectEqual(@as(i32, 16777216), b.col);
    const c = cellInGrid(-inf, -1.0e30, 6, 12, 100, 50);
    try testing.expect(c.row < 0 and c.col < 0);
}

test "a grid smaller than its layer clamps to its own last cell, not the layer's" {
    // 6x12 cells on a 100x50 px layer (16x4 fit), but the grid is 3x10.
    const g: GridGeometry = .{ .cell_w_px = 6, .cell_h_px = 12, .extent_w_px = 100, .extent_h_px = 50, .rows = 3, .cols = 10 };
    const margin = cellInGridEased(99.0, 49.0, 0, g);
    try testing.expectEqual(@as(i32, 2), margin.row);
    try testing.expectEqual(@as(i32, 9), margin.col);
    // Unknown size: the layer decides, as cellInGrid.
    const layer = cellInGridEased(99.0, 49.0, 0, .{ .cell_w_px = 6, .cell_h_px = 12, .extent_w_px = 100, .extent_h_px = 50 });
    try testing.expectEqual(@as(i32, 3), layer.row);
    try testing.expectEqual(@as(i32, 15), layer.col);
    // A drag above the grid stays negative.
    try testing.expectEqual(@as(i32, -1), cellInGridEased(5.0, -1.0, 0, g).row);
}

test "an ease is undone inside the scrolling band only" {
    // 10 rows of 12 px, a 1-row winbar on top and a 1-row status line below;
    // the content is drawn 7 px down.
    const g: GridGeometry = .{ .cell_w_px = 6, .cell_h_px = 12, .extent_w_px = 60, .extent_h_px = 120, .rows = 10, .cols = 10, .margin_top = 1, .margin_bottom = 1 };
    // y=50 is drawn row 4; it came from (50-7)/12 = row 3.
    try testing.expectEqual(@as(i32, 3), cellInGridEased(0, 50.0, 7.0, g).row);
    // y=5 is the winbar: it does not move.
    try testing.expectEqual(@as(i32, 0), cellInGridEased(0, 5.0, 7.0, g).row);
    // y=12 is drawn row 1 (band), but it came from row 0 (winbar): stays 1.
    try testing.expectEqual(@as(i32, 1), cellInGridEased(0, 12.0, 7.0, g).row);
    // y=110 is the status line: it does not move.
    try testing.expectEqual(@as(i32, 9), cellInGridEased(0, 110.0, 7.0, g).row);
    // No ease: the drawn row.
    try testing.expectEqual(@as(i32, 4), cellInGridEased(0, 50.0, 0.0, g).row);
}

test "a grid on the global font: the ease band rule the frontends carried" {
    // 10 rows of 20 px; `decorated` has a winbar on top and a border row at
    // the bottom (rows 1..8 scroll), `plain` scrolls every row.
    const decorated: GridGeometry = .{ .cell_w_px = 20, .cell_h_px = 20, .extent_w_px = 200, .extent_h_px = 200, .rows = 10, .cols = 10, .margin_top = 1, .margin_bottom = 1 };
    const plain: GridGeometry = .{ .cell_w_px = 20, .cell_h_px = 20, .extent_w_px = 200, .extent_h_px = 200, .rows = 10, .cols = 10 };
    // A content pixel, eased: undone, because the shader moved that pixel.
    try testing.expectEqual(@as(i32, 1), cellInGridEased(0, 50, 20, decorated).row);
    try testing.expectEqual(@as(i32, 2), cellInGridEased(0, 50, 0, decorated).row);
    // The margins did not move: a pixel on them keeps its drawn row.
    try testing.expectEqual(@as(i32, 0), cellInGridEased(0, 10, -20, decorated).row);
    try testing.expectEqual(@as(i32, 9), cellInGridEased(0, 190, 20, decorated).row);
    // An adjustment that would land on a margin is refused.
    try testing.expectEqual(@as(i32, 1), cellInGridEased(0, 30, 20, decorated).row);
    try testing.expectEqual(@as(i32, 8), cellInGridEased(0, 170, -20, decorated).row);
    // Without margins every row scrolls.
    try testing.expectEqual(@as(i32, 1), cellInGridEased(0, 10, -20, plain).row);
    // A sub-pixel offset is not an ease.
    try testing.expectEqual(@as(i32, 2), cellInGridEased(0, 50, 0.0005, plain).row);
    // A zero cell cannot name a row and must not divide.
    try testing.expectEqual(@as(i32, 0), cellInGridEased(0, 50, 20, .{ .cell_w_px = 0, .cell_h_px = 0, .extent_w_px = 0, .extent_h_px = 0 }).row);
    // A drag a fraction of a cell above the grid is row -1 (floored), which
    // starts Neovim's drag autoscroll; below the layer it keeps going too.
    try testing.expectEqual(@as(i32, -1), cellInGridEased(0, -5, 0, plain).row);
    try testing.expectEqual(@as(i32, 12), cellInGridEased(0, 250, 0, plain).row);
    try testing.expectEqual(@as(i32, 9), cellInGridEased(0, 199.5, 0, plain).row);
}
