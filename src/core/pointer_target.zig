//! Which grid a pointer names, for every frontend.
//!
//! Both frontends were deciding this themselves, and the two answers drifted.
//! macOS walked the grid list and had to be told separately which grids an
//! external surface hosts — without that it hit-tested a float drawn in
//! another window, and a wheel event on the main window scrolled it
//! (`b7708e0`). Windows walked its layer list, which excluded those for free,
//! but in exchange its main-window branch applied neither the mouse flag nor
//! the scrollability rule (`ef287bf`). Each frontend had part of the rule.
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
    zindex: i64,
    /// Neovim's composition index, and the core's own tie-breaker after it.
    /// Together with zindex and grid_id these are the order the core sorts a
    /// surface's layers by, back to front — the one answer to "which of these
    /// is drawn on top".
    compindex: i64,
    draw_order: u64,
    start_row: i32,
    start_col: i32,
    rows: i32,
    cols: i32,
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
pub fn capturesScroll(c: anytype) bool {
    const content_rows: i64 = @max(0, @as(i64, c.rows) - @as(i64, c.margin_top) - @as(i64, c.margin_bottom));
    return c.line_count > content_rows;
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
        // Front-most wins, by the key the core sorts a surface's layers with.
        // A plain split carries zeros for all three of zindex, compindex and
        // draw_order, so grid_id decides between it and the container grid — which
        // is the special case one frontend had written out as `grid_id > 1`,
        // and the other did not have at all.
        const dominated = if (best) |b| drawnInFrontOf(g, b) else true;
        if (dominated) best = g;
    }
    const b = best orelse return null;
    return .{ .grid_id = b.grid_id, .row = row - b.start_row, .col = col - b.start_col };
}

// ── tests ────────────────────────────────────────────────────────────────

/// Whether `a` is drawn in front of `b`, by the core's layer sort key
/// (flush.collectSurfaceLayerEntries).
fn drawnInFrontOf(a: anytype, b: anytype) bool {
    if (a.zindex != b.zindex) return a.zindex > b.zindex;
    if (a.compindex != b.compindex) return a.compindex > b.compindex;
    if (a.draw_order != b.draw_order) return a.draw_order > b.draw_order;
    return a.grid_id > b.grid_id;
}

const testing = std.testing;

fn win(grid_id: i64, start_row: i32, start_col: i32, rows: i32, cols: i32) Candidate {
    return .{
        .grid_id = grid_id,
        .zindex = 0,
        .compindex = 0,
        .draw_order = 0,
        .start_row = start_row,
        .start_col = start_col,
        .rows = rows,
        .cols = cols,
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

test "a float showing all of its content lets a wheel event through" {
    const grids = [_]Candidate{ win(1, 0, 0, 40, 100), float(5, 10, 20, 10, 30, 10) };
    try testing.expectEqual(@as(i64, 5), resolve(Candidate, &grids, 1, 15, 25, false).?.grid_id);
    try testing.expectEqual(@as(i64, 1), resolve(Candidate, &grids, 1, 15, 25, true).?.grid_id);
}

test "a scrollable float under a non-scrollable one still takes the wheel" {
    var over = float(6, 10, 20, 10, 30, 10);
    over.draw_order = 1; // drawn after 5, so in front of it
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

test "a point outside every grid resolves to nothing" {
    const grids = [_]Candidate{win(2, 10, 20, 10, 30)};
    try testing.expect(resolve(Candidate, &grids, 1, 0, 0, false) == null);
}

test "an empty grid list resolves to nothing" {
    try testing.expect(resolve(Candidate, &.{}, 1, 5, 5, false) == null);
}
