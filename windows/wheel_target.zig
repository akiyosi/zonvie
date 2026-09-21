// wheel_target.zig — which grid a wheel event names, for either surface.
//
// The press path has answered this against the surface's own LAYER list since
// `5e7e9cb` (input.resolveMouseTarget). The wheel did not: the external
// window's branch grew its own copy of the loop, and the MAIN window's branch
// hit-tested `getVisibleGridsCached()` directly. Reading the grid list rather
// than the layer list costs the main window three rules the layer list carries
// for free —
//
//   * an EXTERNAL grid is a window of its own, reported at (0,0), and is not
//     in the main surface's layers;
//   * neither is a float an external window HOSTS, which is not itself
//     external but reports startRow/startCol in that surface's space, so the
//     main window read them as its own — a phantom region shaped like the
//     float, sitting wherever those numbers landed;
//   * a layer without ZONVIE_LAYER_MOUSE_ENABLED must be skipped, because
//     Neovim rejects an event addressed to such a window without re-resolving
//     and naming it swallows the event instead of letting it through.
//
// — and one rule that is the wheel's own: a float showing all of its content
// does not capture scroll, which falls through to whatever is drawn under it.
//
// Generic over the layer type so it can be exercised without Win32: the
// production caller passes `app.SurfaceLayer`, the test its own struct with
// the same three fields this reads.

const std = @import("std");

pub const Target = struct { grid_id: i64, x_px: i32, y_px: i32 };

/// The layer a wheel event at (`x_px`, `y_px`) belongs to, in surface-local
/// pixels, and that point expressed relative to it.
///
/// `layers[0]` is the surface's own root and is never a candidate; the rest are
/// back to front, so the LAST one covering the point wins, which is the z-order
/// the surface drew them in.
///
/// `scrollable_grid_ids` are the grids that can scroll their own content. A
/// float absent from it is transparent here: the loop keeps looking rather than
/// stopping, so a scrollable grid directly beneath one still takes the event.
pub fn resolve(
    comptime Layer: type,
    layers: []const Layer,
    root_grid_id: i64,
    x_px: i32,
    y_px: i32,
    cell_w: u32,
    row_h: u32,
    scrollable_grid_ids: []const i64,
) Target {
    var target = Target{ .grid_id = root_grid_id, .x_px = x_px, .y_px = y_px };
    if (cell_w == 0 or row_h == 0 or layers.len <= 1) return target;
    const cw: i32 = @intCast(cell_w);
    const rh: i32 = @intCast(row_h);
    for (layers[1..]) |layer| {
        if (!layer.mouse_enabled) continue;
        const w: i32 = @as(i32, @intCast(layer.cols)) * cw;
        const h: i32 = @as(i32, @intCast(layer.rows)) * rh;
        if (x_px < layer.x_px or x_px >= layer.x_px + w) continue;
        if (y_px < layer.y_px or y_px >= layer.y_px + h) continue;
        if (!capturesScroll(scrollable_grid_ids, layer.grid_id)) continue;
        target = .{
            .grid_id = layer.grid_id,
            .x_px = x_px - layer.x_px,
            .y_px = y_px - layer.y_px,
        };
    }
    return target;
}

fn capturesScroll(scrollable_grid_ids: []const i64, grid_id: i64) bool {
    for (scrollable_grid_ids) |id| {
        if (id == grid_id) return true;
    }
    return false;
}

/// The grids whose buffer has more lines than their content area shows — a
/// float that already shows every line does not capture scroll, the same rule
/// the macOS resolution applies (MetalTerminalView.isFloatLogicallyScrollable).
/// A grid the cached snapshot does not carry is simply absent from the answer,
/// so a layer whose viewport has not been reported yet shadows nothing.
///
/// Into caller-owned storage so the input path allocates nothing. Grids past the
/// buffer's end are dropped rather than growing it: the answer only has to
/// hold the floats a surface composites, and a wheel event that misses one
/// falls through to the window under it rather than going to the wrong grid.
pub fn collectScrollableGridIds(
    comptime Grid: type,
    grids: []const Grid,
    out: []i64,
) []i64 {
    var n: usize = 0;
    for (grids) |g| {
        if (n == out.len) break;
        const content_rows: i64 = @max(
            0,
            @as(i64, g.rows) - @as(i64, g.margin_top) - @as(i64, g.margin_bottom),
        );
        if (g.line_count > content_rows) {
            out[n] = g.grid_id;
            n += 1;
        }
    }
    return out[0..n];
}
