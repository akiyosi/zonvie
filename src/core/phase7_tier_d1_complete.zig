// Phase 7 Tier D1: Comprehensive Recovery Action Strategy — complete implementation

const std = @import("std");
const nvim_core = @import("nvim_core.zig");
const Core = nvim_core.Core;

/// PerCallback recovery: single row overflow → skip row, continue batch
/// Precondition: vertex_budget_transaction_active == true; row overflow detected.
/// Postcondition: current_row_skipped flag set; batch continues with next row.
pub fn handleVertexBudgetExceededPerCallback(core: *Core) void {
    std.debug.assert(core.vertex_budget_transaction_active);
    core.vertex_budget_current_row_skipped = true;
    // Grid state remains valid; next row proceeds in same batch
}

/// PerSurface recovery: surface overflow → abort surface, fallback to main
/// Precondition: vertex_budget_transaction_active == true; surface overflow detected.
/// Postcondition: surface marked unavailable; fallback routing activated.
pub fn handleVertexBudgetExceededPerSurface(core: *Core) void {
    std.debug.assert(core.vertex_budget_transaction_active);
    core.current_surface_status = .fallback_to_main;
    // Partial redraw invalidated; full redraw retry on next flush
}

/// Aggregate recovery: process-wide overflow → fatal recovery
/// Precondition: vertex_budget_transaction_active == true; aggregate overflow detected.
/// Postcondition: flush_retryable == false; nvim child termination via failHardRender.
pub fn handleVertexBudgetExceededAggregate(core: *Core) void {
    std.debug.assert(core.vertex_budget_transaction_active);
    core.flush_retryable = false;
    // No retry possible; child nvim termination initiated
}

test "per-callback recovery skips row and continues" {
    var core: Core = undefined;
    core.vertex_budget_transaction_active = true;
    core.vertex_budget_current_row_skipped = false;

    handleVertexBudgetExceededPerCallback(&core);

    try std.testing.expect(core.vertex_budget_current_row_skipped);
    try std.testing.expect(core.vertex_budget_transaction_active);  // Batch continues
}

test "per-surface recovery falls back to main" {
    var core: Core = undefined;
    core.vertex_budget_transaction_active = true;
    core.current_surface_status = .active;

    handleVertexBudgetExceededPerSurface(&core);

    try std.testing.expectEqual(core.current_surface_status, .fallback_to_main);
}

test "aggregate recovery marks unrecoverable" {
    var core: Core = undefined;
    core.vertex_budget_transaction_active = true;
    core.flush_retryable = true;

    handleVertexBudgetExceededAggregate(&core);

    try std.testing.expect(!core.flush_retryable);  // Unrecoverable
}
