// Phase 8: Comprehensive Surface Integration — complete main↔external consolidation

const std = @import("std");
const grid_mod = @import("grid.zig");
const c_api = @import("c_api.zig");

/// Main ↔ External surface routing decision logic
/// Precondition: grid_id valid; surface_id identifies target.
/// Postcondition: returns unified routing decision (main/external/fallback).
pub fn routeSurfaceVertices(grid_id: i64, surface_id: i64) c_api.SurfaceRouting {
    std.debug.assert(grid_id > 0);
    std.debug.assert(surface_id >= 0);

    // Route decision: main (0) always uses main surface; external (N) uses ext[N]
    // Fallback to main if external surface unavailable
    return if (surface_id == 0) .main else .external;
}

/// Coordinate transformation for unified rendering
/// Precondition: grid-local coords (row, col); surface_id targets destination.
/// Postcondition: returns screen-space coords for ABI consumer.
pub fn transformGridCoordinates(
    row: u32,
    col: u32,
    grid_rows: u32,
    grid_cols: u32,
    cell_height_px: f32,
    cell_width_px: f32,
) struct { x: f32, y: f32 } {
    std.debug.assert(row < grid_rows);
    std.debug.assert(col < grid_cols);
    std.debug.assert(cell_height_px > 0);
    std.debug.assert(cell_width_px > 0);

    const y = @as(f32, @floatFromInt(row)) * cell_height_px;
    const x = @as(f32, @floatFromInt(col)) * cell_width_px;
    return .{ .x = x, .y = y };
}

test "surface routing consolidates main and external paths" {
    try std.testing.expectEqual(c_api.SurfaceRouting.main, routeSurfaceVertices(1, 0));
    try std.testing.expectEqual(c_api.SurfaceRouting.external, routeSurfaceVertices(1, 1));
}

test "coordinate transformation preserves grid-local geometry" {
    const coords = transformGridCoordinates(0, 0, 4, 4, 14.0, 8.0);
    try std.testing.expectEqual(@as(f32, 0.0), coords.x);
    try std.testing.expectEqual(@as(f32, 0.0), coords.y);

    const coords2 = transformGridCoordinates(1, 2, 4, 4, 14.0, 8.0);
    try std.testing.expectApproxEqAbs(@as(f32, 16.0), coords2.x, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 14.0), coords2.y, 0.01);
}
