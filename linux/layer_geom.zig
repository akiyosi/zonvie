//! A layer's pixel geometry: the surface's cell, or the grid's own font
//! (on_grid_font) when it has one. Pure; the painter, the pointer and the
//! row store all size a grid from here, so they agree on where a row is.

const std = @import("std");
const core = @import("zonvie_core");

/// A grid's own font as on_grid_font reports it, published at commit.
pub const GridFont = struct {
    font_id: u32,
    cell_w_px: u32,
    /// Row height, 'linespace' included.
    cell_h_px: u32,
    /// The pixel box the core clips the layer to and frames it by, margin
    /// included; 0 only for a grid with no rows or columns.
    extent_w_px: u32,
    extent_h_px: u32,
};

pub const Geom = struct {
    cell_w_px: u32,
    row_h_px: u32,
    rows: u32,
    cols: u32,
    /// Set for a grid in its own font: the layer is clipped to it, and its
    /// last row reaches its bottom (the core draws the bottom margin with
    /// that row).
    extent: ?[2]u32 = null,

    /// Pre: `font`, when given, has non-zero cells (the core never sends a
    /// zero cell with a non-zero font_id).
    pub fn of(layer: core.Layer, font: ?GridFont, surface_cell_w_px: u32, surface_row_h_px: u32) Geom {
        if (font) |f| {
            std.debug.assert(f.cell_w_px != 0 and f.cell_h_px != 0);
            return .{ .cell_w_px = f.cell_w_px, .row_h_px = f.cell_h_px, .rows = layer.rows, .cols = layer.cols, .extent = .{ f.extent_w_px, f.extent_h_px } };
        }
        return .{ .cell_w_px = surface_cell_w_px, .row_h_px = surface_row_h_px, .rows = layer.rows, .cols = layer.cols };
    }

    pub fn widthPx(self: Geom) u32 {
        return if (self.extent) |e| e[0] else self.cols * self.cell_w_px;
    }

    pub fn heightPx(self: Geom) u32 {
        return if (self.extent) |e| e[1] else self.rows * self.row_h_px;
    }

    /// Rows [start, end) as a layer-local band [top, bottom), within the
    /// layer's box.
    pub fn rowsBandPx(self: Geom, start: u32, end: u32) [2]u32 {
        var top = start * self.row_h_px;
        var bottom = end * self.row_h_px;
        if (self.extent) |e| {
            if (end >= self.rows) bottom = e[1];
            top = @min(top, e[1]);
            bottom = @min(bottom, e[1]);
        }
        return .{ top, @max(top, bottom) };
    }
};

/// The anchor whose smooth scroll `layer` moves bodily with, or null: a
/// buffer-tracking float (ZONVIE_LAYER_FOLLOWS_SCROLL) not scrolled in its
/// own right, anchored to a window that is not itself a float (macOS
/// surfaceFloatFollowsAnchorScroll). `layers` is the surface's list.
pub fn scrollAnchor(layer: core.Layer, scrolled_in_own_right: bool, layers: []const core.Layer) ?core.Layer {
    if (layer.flags & core.LAYER_FOLLOWS_SCROLL == 0 or scrolled_in_own_right) return null;
    if (layer.anchor_grid == layer.grid_id) return null;
    for (layers) |a| {
        if (a.grid_id != layer.anchor_grid) continue;
        return if (a.flags & core.LAYER_FLOAT == 0) a else null;
    }
    return null;
}

const testing = std.testing;

/// Height, in px of the root grid at integer-or-not `scale`, across which
/// window separators fade in: a captionless window's top band (`band_pt`),
/// which lies over the grid since its editor reaches the window top, as
/// Windows fades them (sidebar_caption.separatorFadePx). 0 with a caption
/// or title band, below which the grid starts.
pub fn separatorFadePx(captionless: bool, band_pt: i32, scale: f32) f32 {
    return if (captionless) @as(f32, @floatFromInt(band_pt)) * scale else 0;
}

test "separators fade across a captionless band only" {
    try std.testing.expectEqual(@as(f32, 64), separatorFadePx(true, 32, 2));
    try std.testing.expectEqual(@as(f32, 0), separatorFadePx(false, 32, 2));
}

test "a buffer-tracking float follows the window it is anchored to" {
    const win: core.Layer = .{ .grid_id = 2, .anchor_grid = 1, .x_px = 0, .y_px = 0, .rows = 10, .cols = 10, .z = 1, .flags = core.LAYER_MOUSE_ENABLED };
    var float: core.Layer = .{ .grid_id = 5, .anchor_grid = 2, .x_px = 0, .y_px = 0, .rows = 2, .cols = 4, .z = 2, .flags = core.LAYER_FLOAT | core.LAYER_FOLLOWS_SCROLL };
    const layers = [_]core.Layer{ win, float };
    try testing.expectEqual(@as(i64, 2), scrollAnchor(float, false, &layers).?.grid_id);
    // Scrolled itself, it keeps its own offset.
    try testing.expect(scrollAnchor(float, true, &layers) == null);
    // A fixed float stays put.
    float.flags = core.LAYER_FLOAT;
    try testing.expect(scrollAnchor(float, false, &layers) == null);
}

test "a float anchored to a float does not follow" {
    const outer: core.Layer = .{ .grid_id = 4, .anchor_grid = 1, .x_px = 0, .y_px = 0, .rows = 5, .cols = 5, .z = 2, .flags = core.LAYER_FLOAT };
    const inner: core.Layer = .{ .grid_id = 6, .anchor_grid = 4, .x_px = 0, .y_px = 0, .rows = 1, .cols = 1, .z = 3, .flags = core.LAYER_FLOAT | core.LAYER_FOLLOWS_SCROLL };
    try testing.expect(scrollAnchor(inner, false, &.{ outer, inner }) == null);
}

fn testLayer(rows: u32, cols: u32) core.Layer {
    return .{ .grid_id = 2, .anchor_grid = 1, .x_px = 0, .y_px = 0, .rows = rows, .cols = cols, .z = 1, .flags = 0 };
}

test "a grid on the surface's font fills rows x cell" {
    const g = Geom.of(testLayer(3, 4), null, 8, 16);
    try testing.expectEqual(@as(u32, 32), g.widthPx());
    try testing.expectEqual(@as(u32, 48), g.heightPx());
    try testing.expectEqual([2]u32{ 16, 48 }, g.rowsBandPx(1, 3));
    try testing.expect(g.extent == null);
}

test "a grid in its own font uses its cell and is boxed by its extent" {
    const f: GridFont = .{ .font_id = 1, .cell_w_px = 12, .cell_h_px = 20, .extent_w_px = 50, .extent_h_px = 70 };
    const g = Geom.of(testLayer(3, 4), f, 8, 16);
    try testing.expectEqual(@as(u32, 50), g.widthPx());
    try testing.expectEqual(@as(u32, 70), g.heightPx());
    // The last row reaches the extent's bottom margin.
    try testing.expectEqual([2]u32{ 20, 70 }, g.rowsBandPx(1, 3));
    try testing.expectEqual([2]u32{ 0, 40 }, g.rowsBandPx(0, 2));
}

test "a band below a shrunk extent is empty, never inverted" {
    const f: GridFont = .{ .font_id = 1, .cell_w_px = 12, .cell_h_px = 20, .extent_w_px = 50, .extent_h_px = 30 };
    const g = Geom.of(testLayer(5, 4), f, 8, 16);
    try testing.expectEqual([2]u32{ 30, 30 }, g.rowsBandPx(2, 4));
}
