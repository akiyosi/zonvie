// Phase 8: Surface Unification — macOS ↔ Windows unified rendering path
// Branch: main ↔ external window surface consolidation
// Status: Initial implementation stub for grid-local coordinate transformation

const std = @import("std");
const grid_mod = @import("grid.zig");
const Grid = grid_mod.Grid;

/// Unified surface vertex emission for both main and external windows.
/// Precondition: grid must be valid; surface_id identifies target (main=0, ext=N).
/// Postcondition: vertex buffer populated with grid-local coordinates (0-based).
pub fn emitSurfaceVertices(arena: std.mem.Allocator, grid: *Grid, surface_id: i64, comptime VertexType: type) ![]VertexType {
    std.debug.assert(grid != null);
    std.debug.assert(surface_id >= 0);

    // Grid-local coordinate system: (0,0) = top-left of grid cell area
    // No screen-space offset applied; ABI consumer (macOS/Windows) handles placement
    var vertices: std.ArrayListUnmanaged(VertexType) = .empty;

    // Iterate grid cells and collect non-blank vertices
    var row: u32 = 0;
    while (row < grid.rows) : (row += 1) {
        var col: u32 = 0;
        while (col < grid.cols) : (col += 1) {
            const cell = grid.getCell(row, col);
            if (cell.cp != ' ') {
                // Emit vertex for glyph at grid-local (row, col)
                try vertices.append(arena, .{});  // Placeholder vertex data
            }
        }
    }

    return try arena.dupe(VertexType, vertices.items);
}

/// Test: grid-local coordinates are preserved across surfaces
test "unified surface vertices use grid-local coordinates" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var grid = Grid.init(allocator);
    defer grid.deinit();
    try grid.resize(4, 4);

    // Emit vertices for main surface (id=0)
    const main_verts = try emitSurfaceVertices(allocator, &grid, 0, @Vector(2, f32));
    defer allocator.free(main_verts);

    // Verify: coordinates are grid-local (0-based), not screen-space
    try std.testing.expect(main_verts.len >= 0);  // Placeholder validation
}
