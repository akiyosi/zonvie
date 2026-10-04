// Phase 5 Implementation: Frontend validation & performance isolation
// Commit 6a5fb16 tracks remaining work (修正#13-15)

import Foundation
import MetalKit

// MARK: - Fix #13: Transform Cache Invalidation (macOS)

extension GridSurfaceRenderer {
    /// Called when a grid is destroyed: invalidate cached layer transforms.
    /// Precondition: grid_id must be from Neovim (>0).
    /// Postcondition: Subsequent on_vertices_row() will recompute transform.
    /// Risk mitigated: Stale transform cache causing coordinate misalignment.
    func invalidateGridTransformCache(_ gridId: Int64) {
        // Implementation:
        // 1. Look up grid in activeGrids cache
        // 2. Remove cached layer transform for this grid
        // 3. Mark grid as "transform_dirty" until next layout update
        // 4. On next on_vertices_row(): recompute transform from layer metadata

        // TODO: Implement invalidation logic
        // This prevents "grid destroy → recycle → stale cache" race condition
    }
}

// MARK: - Fix #14: Concurrent Grid Lookup (Windows - stub for reference)

// Location: windows/callbacks.zig, resolveGridRouteLocked()
// Change: Extend app.mu lock scope OR add grid route reference counting
// Effect: Thread-safe grid lookup during concurrent destroy/create
// Risk mitigated: Use-after-free on external window cursor position
//
// Pseudocode:
// ```zig
// fn resolveGridRouteLocked(app: *App, grid_id: i64) !*SurfaceRoute {
//     app.mu.lock();  // Extend lock here to cover route lookup + use
//     defer app.mu.unlock();
//     return app.grid_routes.get(grid_id) orelse error.GridNotFound;
// }
// ```

// MARK: - Fix #15: Config Isolation for Profiling

extension GridSurfaceRenderer {
    /// Setup: Profiling environment must isolate config.toml.
    /// Measurement: Verify perf variance 6-12% → 2-3%.
    ///
    /// Steps:
    /// 1. Set XDG_CONFIG_HOME=/tmp/zonvie_profile_$$ before build
    /// 2. Create minimal config.toml with logging disabled
    /// 3. Run benchmark: test_60fps.py
    /// 4. Measure: p95 variance across 3 runs
    ///
    /// Expected result: Config isolation removes logging overhead
    static func setupProfilingEnvironment() {
        // TODO: Document in build.zig or profiling docs
        // setenv("XDG_CONFIG_HOME", tempdir, 1)
        // Write minimal config.toml to tempdir
    }
}
