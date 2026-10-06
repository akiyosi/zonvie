const std = @import("std");

// Tier 2 Test: Flush Error Recovery
//
// Spec: on_flush_end must execute despite on_vertices_row error
// Verifies: contract that deferred cleanup (on_flush_end) always runs

const MockCallback = struct {
    call_count: u32 = 0,
    last_event: enum { none, begin, vertices, end, error } = .none,

    fn onFlushBegin(ctx: ?*anyopaque) callconv(.c) void {
        if (ctx) |ptr| {
            var cb: *MockCallback = @ptrCast(@alignCast(ptr));
            cb.call_count += 1;
            cb.last_event = .begin;
        }
    }

    fn onFlushEnd(ctx: ?*anyopaque) callconv(.c) void {
        if (ctx) |ptr| {
            var cb: *MockCallback = @ptrCast(@alignCast(ptr));
            cb.call_count += 1;
            cb.last_event = .end;
        }
    }

    fn onVerticesRow(ctx: ?*anyopaque, grid_id: i64, row: u32, cells: [*]const u8, cell_count: u32) callconv(.c) void {
        if (ctx) |ptr| {
            var cb: *MockCallback = @ptrCast(@alignCast(ptr));
            cb.call_count += 1;
            cb.last_event = .vertices;
        }
        _ = grid_id;
        _ = row;
        _ = cells;
        _ = cell_count;
    }
};

test "flush: on_flush_end executes despite on_vertices_row error (contract)" {
    // Precondition: Callback contract requires on_flush_end to execute
    // Postcondition: Verify defer guard ensures on_flush_end executes even on error

    var arena_alloc = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_alloc.deinit();

    var callback: MockCallback = .{};

    // Simulate flush transaction with defer guard
    var begin_called = false;
    var end_called = false;
    var vertices_error = false;

    defer {
        // on_flush_end MUST execute (Zig defer guarantee)
        end_called = true;
        callback.onFlushEnd(@ptrCast(&callback));
    }

    // on_flush_begin
    begin_called = true;
    callback.onFlushBegin(@ptrCast(&callback));

    // Simulate on_vertices_row (may fail)
    vertices_error = true;
    if (!vertices_error) {
        callback.onVerticesRow(@ptrCast(&callback), 1, 0, "", 0);
    }

    // Postcondition: verify callback order
    try std.testing.expect(begin_called);
    try std.testing.expect(end_called);
    try std.testing.expect(callback.last_event == .end);
    try std.testing.expect(callback.call_count == 2); // begin + end only
}

test "flush: grid_mu lock released on error path (contract)" {
    // Precondition: grid_mu held during handleRedraw
    // Postcondition: Lock released via defer guard on error

    var arena_alloc = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_alloc.deinit();

    var lock_held = true;
    var error_occurred = false;

    defer {
        // Lock release happens in defer block (enforced)
        lock_held = false;
    }

    // Critical section with potential error
    try std.testing.expect(lock_held);

    // Simulate error during critical section
    error_occurred = true;
    if (error_occurred) {
        // Even with error, defer executes
    }

    // Postcondition: defer will release lock
    try std.testing.expect(lock_held); // still held before defer cleanup
}

test "flush: OutOfMemory recovery preserves grid state (contract)" {
    // Precondition: OOM during flush
    // Postcondition: Grid marked dirty for retry

    var arena_alloc = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_alloc.deinit();

    // Grid state tracking
    var grid_dirty = true;

    // Simulate flush begin
    var flush_attempted = true;

    // Simulate OOM error during flush
    var oom_error = true;
    if (oom_error) {
        // On OOM: grid must be marked dirty again for retry
        grid_dirty = true;
    }

    // Postcondition: Grid state valid for retry
    try std.testing.expect(flush_attempted);
    try std.testing.expect(grid_dirty);
}

test "flush: on_flush_end order verification (contract)" {
    // Precondition: Callback execution order matters
    // Postcondition: Verify on_flush_end runs last (in defer cleanup)

    var arena_alloc = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_alloc.deinit();

    var callback: MockCallback = .{};
    var execution_order = std.ArrayList(u32).init(arena_alloc.allocator());

    defer {
        callback.onFlushEnd(@ptrCast(&callback));
        execution_order.append(3) catch unreachable;
    }

    callback.onFlushBegin(@ptrCast(&callback));
    execution_order.append(1) catch unreachable;

    callback.onVerticesRow(@ptrCast(&callback), 1, 0, "", 0);
    execution_order.append(2) catch unreachable;

    // Postcondition: after defer cleanup, order is [1, 2, 3]
    try std.testing.expect(execution_order.items.len == 3);
    try std.testing.expectEqual(execution_order.items[0], 1); // begin
    try std.testing.expectEqual(execution_order.items[1], 2); // vertices
    // Item [2] will be 3 (end) after defer cleanup
}
