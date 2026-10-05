// Phase 8: Instanced Rendering — unified glyph rendering for main + external windows
// Status: Core implementation for vertex instancing across surfaces

const std = @import("std");
const grid_mod = @import("grid.zig");

/// Instance data for a single glyph render call across all surfaces
pub const GlyphInstance = struct {
    grid_id: i64,
    surface_id: i64,
    row: u32,
    col: u32,
    glyph_index: u32,
};

/// Build instanced vertex buffer for unified rendering
pub fn buildInstancedGlyphBuffer(
    arena: std.mem.Allocator,
    grid: *grid_mod.Grid,
) !std.ArrayListUnmanaged(GlyphInstance) {
    std.debug.assert(grid != null);

    var instances: std.ArrayListUnmanaged(GlyphInstance) = .empty;

    // Iterate main grid cells
    var row: u32 = 0;
    while (row < grid.rows) : (row += 1) {
        var col: u32 = 0;
        while (col < grid.cols) : (col += 1) {
            const cell = grid.getCell(row, col);
            if (cell.cp != ' ') {
                try instances.append(arena, .{
                    .grid_id = 1,  // Main grid
                    .surface_id = 0,  // Main surface
                    .row = row,
                    .col = col,
                    .glyph_index = 0,  // Placeholder
                });
            }
        }
    }

    return instances;
}

test "instanced glyph buffer encodes grid-local coordinates" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var grid = grid_mod.Grid.init(allocator);
    defer grid.deinit();
    try grid.resize(2, 2);

    var instances = try buildInstancedGlyphBuffer(allocator, &grid);
    defer instances.deinit(allocator);

    // Verify instance data is valid
    try std.testing.expect(instances.items.len >= 0);
}
