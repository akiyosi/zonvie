// Phase 8: ABI Consumer Integration — macOS/Windows surface consolidation

const std = @import("std");
const c_api = @import("c_api.zig");
const phase8 = @import("phase8_comprehensive.zig");

/// Submit unified vertex buffer to ABI consumer (macOS Metal / Windows D3D11)
/// Precondition: vertex buffer populated with grid-local coordinates.
/// Postcondition: consumer receives surface routing + coordinate data.
pub fn submitUnifiedVertexBuffer(
    callbacks: *c_api.zonvie_callbacks,
    surface_id: i64,
    vertices: []const c_api.Vertex,
) c_api.SubmitResult {
    std.debug.assert(callbacks != null);
    std.debug.assert(vertices.len >= 0);
    std.debug.assert(surface_id >= 0);

    // Route to correct ABI consumer callback
    const routing = phase8.routeSurfaceVertices(1, surface_id);  // grid_id=1 (main)

    return switch (routing) {
        .main => callbacks.on_vertices(.main, vertices),
        .external => callbacks.on_vertices(.external, vertices),
    };
}

/// Integrate both macOS and Windows rendering paths through unified ABI
pub const SubmitResult = struct {
    success: bool,
    bytes_submitted: usize,
};

test "abi integration routes main surface correctly" {
    // Surface 0 (main) routes to main ABI path
    const routing = phase8.routeSurfaceVertices(1, 0);
    try std.testing.expectEqual(@as(c_api.SurfaceRouting, .main), routing);
}

test "abi integration routes external surface correctly" {
    // Surface 1+ (external) routes to external ABI path
    const routing = phase8.routeSurfaceVertices(1, 1);
    try std.testing.expectEqual(@as(c_api.SurfaceRouting, .external), routing);
}
