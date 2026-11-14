const std = @import("std");
const core = @import("zonvie_core");
const testing = std.testing;

pub const LayerXform = extern struct { scale: [2]f32, offset: [2]f32 };

/// Maps grid-local px to clip space for a layer placed at (x_px, y_px) on the surface.
pub fn layerXform(layer: core.Layer, cell_w_px: u32, cell_h_px: u32, surface_w_px: u32, surface_h_px: u32) LayerXform {
    _ = cell_w_px;
    _ = cell_h_px;
    const w: f32 = @floatFromInt(surface_w_px);
    const h: f32 = @floatFromInt(surface_h_px);
    const x: f32 = @floatFromInt(layer.x_px);
    const y: f32 = @floatFromInt(layer.y_px);
    return .{
        .scale = .{ 2.0 / w, -2.0 / h },
        .offset = .{ -1.0 + 2.0 * x / w, 1.0 - 2.0 * y / h },
    };
}

/// Floor division, so px left of or above the grid yields a negative cell.
pub fn pxToCell(x_px: f64, y_px: f64, cell_w_px: u32, cell_h_px: u32) struct { row: i32, col: i32 } {
    return .{
        .row = @intFromFloat(@floor(y_px / @as(f64, @floatFromInt(cell_h_px)))),
        .col = @intFromFloat(@floor(x_px / @as(f64, @floatFromInt(cell_w_px)))),
    };
}

test "root layer maps grid corners to clip corners" {
    const l = core.Layer{ .grid_id = 1, .anchor_grid = 1, .x_px = 0, .y_px = 0, .rows = 10, .cols = 20, .z = 0, .flags = 0 };
    const t = layerXform(l, 8, 16, 160, 160);
    try testing.expectApproxEqAbs(@as(f32, -1), 0 * t.scale[0] + t.offset[0], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 1), 160 * t.scale[0] + t.offset[0], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, -1), 160 * t.scale[1] + t.offset[1], 1e-6);
}

test "offset layer origin lands at its surface pixel" {
    const l = core.Layer{ .grid_id = 2, .anchor_grid = 1, .x_px = 40, .y_px = 80, .rows = 2, .cols = 2, .z = 1, .flags = 0 };
    const t = layerXform(l, 8, 16, 160, 160);
    try testing.expectApproxEqAbs(@as(f32, -0.5), t.offset[0], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.0), t.offset[1], 1e-6);
}

test "pxToCell floors and keeps negative px negative" {
    const c = pxToCell(15.9, 31.9, 8, 16);
    try testing.expectEqual(@as(i32, 1), c.row);
    try testing.expectEqual(@as(i32, 1), c.col);
    const n = pxToCell(-0.5, -0.5, 8, 16);
    try testing.expectEqual(@as(i32, -1), n.row);
    try testing.expectEqual(@as(i32, -1), n.col);
}
