const std = @import("std");
const helpers = @import("render_pipeline_helpers.zig");

test "retry delay doubles and saturates" {
    try std.testing.expectEqual(@as(u32, 32), helpers.nextBackoffDelayMs(16, 2000));
    try std.testing.expectEqual(@as(u32, 2000), helpers.nextBackoffDelayMs(1024, 2000));
    try std.testing.expectEqual(@as(u32, 2000), helpers.nextBackoffDelayMs(2000, 2000));
    try std.testing.expectEqual(@as(u32, 2000), helpers.nextBackoffDelayMs(std.math.maxInt(u32), 2000));
}

test "device-loss recovery retries indefinitely with bounded backoff" {
    const expected = [_]u32{ 1000, 1000, 2000, 4000, 8000, 16_000, 30_000, 30_000 };
    for (expected, 0..) |delay_ms, failed_attempts| {
        try std.testing.expectEqual(
            delay_ms,
            helpers.deviceLostRetryDelayMs(@intCast(failed_attempts)),
        );
    }
    try std.testing.expectEqual(
        helpers.device_lost_retry_max_ms,
        helpers.deviceLostRetryDelayMs(std.math.maxInt(u32)),
    );
}

test "device-loss recovery warning is one-shot and does not stop retries" {
    try std.testing.expect(!helpers.shouldWarnDeviceLostRecovery(3, false));
    try std.testing.expect(helpers.shouldWarnDeviceLostRecovery(4, false));
    try std.testing.expect(!helpers.shouldWarnDeviceLostRecovery(5, true));
}

test "GPU buffer growth is geometric and bounded" {
    const max_bytes: usize = 64 * 1024 * 1024;
    try std.testing.expectEqual(@as(usize, 4096), helpers.geometricBufferCapacity(0, 1, max_bytes).?);
    try std.testing.expectEqual(@as(usize, 4096), helpers.geometricBufferCapacity(4096, 4096, max_bytes).?);
    try std.testing.expectEqual(@as(usize, 8192), helpers.geometricBufferCapacity(4096, 4097, max_bytes).?);
    try std.testing.expectEqual(max_bytes, helpers.geometricBufferCapacity(max_bytes / 2, max_bytes, max_bytes).?);
    try std.testing.expect(helpers.geometricBufferCapacity(max_bytes, max_bytes + 1, max_bytes) == null);

    var capacity: usize = 0;
    var growth_count: usize = 0;
    for (1..100_001) |need_bytes| {
        const next = helpers.geometricBufferCapacity(capacity, need_bytes, max_bytes).?;
        if (next != capacity) growth_count += 1;
        capacity = next;
    }
    try std.testing.expect(growth_count <= 6);
}

test "RowVB physical budget charges replacement peak across surfaces" {
    const mib: usize = 1024 * 1024;
    try std.testing.expect(helpers.rowVBPhysicalGrowthFits(
        400 * mib,
        0,
        120 * mib,
        64 * mib,
        helpers.row_vb_surface_budget_bytes,
        helpers.row_vb_process_budget_bytes,
    ));
    try std.testing.expect(!helpers.rowVBPhysicalGrowthFits(
        480 * mib,
        0,
        120 * mib,
        64 * mib,
        helpers.row_vb_surface_budget_bytes,
        helpers.row_vb_process_budget_bytes,
    ));
    try std.testing.expect(!helpers.rowVBPhysicalGrowthFits(
        200 * mib,
        0,
        224 * mib,
        64 * mib,
        helpers.row_vb_surface_budget_bytes,
        helpers.row_vb_process_budget_bytes,
    ));
    try std.testing.expect(!helpers.rowVBPhysicalGrowthFits(
        400 * mib,
        64 * mib,
        120 * mib,
        64 * mib,
        helpers.row_vb_surface_budget_bytes,
        helpers.row_vb_process_budget_bytes,
    ));
}

test "RowVB physical budget reservation commits rolls back and releases" {
    const mib: usize = 1024 * 1024;
    var budget = helpers.RowVBPhysicalBudget{};
    var main_surface_bytes: usize = 0;
    var external_surface_bytes: usize = 0;
    const third_surface_bytes: usize = 0;

    var initial = try budget.reserveGrowth(main_surface_bytes, 0, 128 * mib);
    try std.testing.expectEqual(@as(usize, 128 * mib), budget.reserved_bytes);
    budget.commit(&main_surface_bytes, &initial);
    try std.testing.expectEqual(@as(usize, 128 * mib), budget.retained_bytes);
    try std.testing.expectEqual(@as(usize, 128 * mib), main_surface_bytes);

    var external = try budget.reserveGrowth(external_surface_bytes, 0, 256 * mib);
    budget.commit(&external_surface_bytes, &external);
    try std.testing.expectEqual(@as(usize, 384 * mib), budget.retained_bytes);

    try std.testing.expectError(
        error.RowVBPhysicalBudgetExceeded,
        budget.reserveGrowth(third_surface_bytes, 0, 129 * mib),
    );
    try std.testing.expectEqual(@as(usize, 0), budget.reserved_bytes);

    var replacement = try budget.reserveGrowth(main_surface_bytes, 64 * mib, 128 * mib);
    budget.cancel(&replacement);
    try std.testing.expectEqual(@as(usize, 384 * mib), budget.retained_bytes);
    try std.testing.expectEqual(@as(usize, 0), budget.reserved_bytes);

    replacement = try budget.reserveGrowth(main_surface_bytes, 64 * mib, 128 * mib);
    budget.commit(&main_surface_bytes, &replacement);
    try std.testing.expectEqual(@as(usize, 448 * mib), budget.retained_bytes);
    try std.testing.expectEqual(@as(usize, 192 * mib), main_surface_bytes);

    budget.release(&main_surface_bytes, 192 * mib);
    budget.release(&external_surface_bytes, 256 * mib);
    try std.testing.expectEqual(@as(usize, 0), budget.retained_bytes);
    try std.testing.expectEqual(@as(usize, 0), main_surface_bytes);
}

test "scrollbar underlay failure clears validity and retries the same geometry" {
    var state = helpers.ScrollbarUnderlayState{};
    try std.testing.expect(state.geometryChanged(12, 480));

    state.captured(12, 480);
    try std.testing.expect(state.valid);
    try std.testing.expect(!state.geometryChanged(12, 480));

    state.resourceFailed();
    try std.testing.expect(!state.valid);
    try std.testing.expect(state.geometryChanged(12, 480));

    state.captured(12, 480);
    state.restored();
    try std.testing.expect(!state.valid);
    try std.testing.expect(!state.geometryChanged(12, 480));
}

test "resize and deferred retry service pin App lifetime" {
    try std.testing.expect(!(helpers.ActiveOperationFlags{}).any());
    try std.testing.expect((helpers.ActiveOperationFlags{ .main_resize = true }).any());
    try std.testing.expect((helpers.ActiveOperationFlags{ .main_dpi_change = true }).any());
    try std.testing.expect((helpers.ActiveOperationFlags{ .deferred_service = true }).any());
    try std.testing.expect((helpers.ActiveOperationFlags{ .paint = true }).any());
}

test "flush retry epochs preserve a failure after success" {
    try std.testing.expect(helpers.retryEpochPending(1, 0));
    try std.testing.expect(helpers.retryEpochWasCovered(1, 1));
    try std.testing.expect(!helpers.retryEpochPending(1, 1));
    // A later failure is not erased by the preceding success and must receive
    // a newly-based deadline.
    try std.testing.expect(helpers.retryEpochPending(2, 1));
    try std.testing.expect(!helpers.retryEpochWasCovered(2, 1));
    try std.testing.expect(helpers.retryEpochNeedsArm(2, 1, 1));
    try std.testing.expect(!helpers.retryEpochNeedsArm(1, 0, 1));

    // Model the old lost-wake interleaving: the UI observed epoch 1, then a
    // producer published epoch 2 before the UI completed its old-success
    // path. Pending state comes only from epochs, so no UI-side flag clear can
    // erase epoch 2.
    var failure_epoch = std.atomic.Value(u64).init(1);
    const stale_ui_snapshot = failure_epoch.load(.acquire);
    try std.testing.expectEqual(@as(u64, 1), stale_ui_snapshot);
    _ = failure_epoch.fetchAdd(1, .acq_rel);
    try std.testing.expect(helpers.retryEpochNeedsArm(failure_epoch.load(.acquire), 1, 1));
}

test "paint retry exponentially backs off and suppresses duplicate generations" {
    var retry = helpers.PaintRetryState{};
    const first = retry.fail().?;
    try std.testing.expectEqual(@as(u32, 16), first.delay_ms);
    try std.testing.expect(retry.fail() == null);
    try std.testing.expect(retry.timerFired(first.generation));
    const second = retry.fail().?;
    try std.testing.expectEqual(@as(u32, 32), second.delay_ms);
    try std.testing.expect(retry.timerFired(second.generation));

    var delay: u32 = 0;
    for (0..16) |_| {
        const ticket = retry.fail().?;
        delay = ticket.delay_ms;
        try std.testing.expect(retry.timerFired(ticket.generation));
    }
    try std.testing.expectEqual(helpers.PaintRetryState.max_delay_ms, delay);
    try std.testing.expect(!retry.succeeded());
    try std.testing.expectEqual(@as(u32, 16), retry.fail().?.delay_ms);
}

test "paint retry remains bounded when every timer mechanism fails" {
    var retry = helpers.PaintRetryState{};
    _ = retry.fail();
    try std.testing.expect(!retry.shouldInvalidateAfterRelease(true));
    // The scheduling site owns exactly one fallback invalidation. The paint
    // release path must not duplicate it.
    try std.testing.expect(retry.timerArmFailed(retry.generation));
    try std.testing.expect(!retry.shouldInvalidateAfterRelease(true));
    const second = retry.fail().?;
    try std.testing.expectEqual(@as(u32, 32), second.delay_ms);
    // Total delayed-timer failure does not turn the one-shot fallback into an
    // immediate WM_PAINT loop. Pending paint remains for a natural wake.
    try std.testing.expect(!retry.timerArmFailed(second.generation));
    try std.testing.expect(!retry.shouldInvalidateAfterRelease(true));
}

test "armed paint retry is not bypassed by paint release" {
    var retry = helpers.PaintRetryState{};
    _ = retry.fail();
    try std.testing.expect(!retry.shouldInvalidateAfterRelease(true));
    try std.testing.expect(retry.timerFired(retry.generation));
    try std.testing.expect(retry.shouldInvalidateAfterRelease(true));
    try std.testing.expect(!retry.shouldInvalidateAfterRelease(false));
}

test "stale paint retry callback cannot consume a newer generation" {
    var retry = helpers.PaintRetryState{};
    const old = retry.fail().?;
    try std.testing.expect(retry.succeeded());

    const current = retry.fail().?;
    try std.testing.expect(old.generation != current.generation);
    try std.testing.expect(!retry.timerFired(old.generation));
    try std.testing.expect(retry.timer_armed);
    try std.testing.expect(retry.timerFired(current.generation));
}

test "natural paint releases an armed retry after message delivery failure" {
    var retry = helpers.PaintRetryState{};
    const failed_delivery = retry.fail().?;
    retry.paintStarted();
    try std.testing.expect(!retry.timer_armed);

    const current = retry.fail().?;
    try std.testing.expect(!retry.timerFired(failed_delivery.generation));
    try std.testing.expect(retry.timer_armed);
    try std.testing.expect(retry.timerFired(current.generation));
}

test "atlas upload policy bounds calls by rect count or dirty area" {
    const AtlasRect = struct { left: u32, top: u32, right: u32, bottom: u32 };
    const small = [_]AtlasRect{
        .{ .left = 0, .top = 0, .right = 8, .bottom = 8 },
        .{ .left = 16, .top = 16, .right = 24, .bottom = 24 },
    };
    try std.testing.expect(!helpers.shouldUseFullAtlasUpload(&small, 64, 64));

    const large = [_]AtlasRect{.{ .left = 0, .top = 0, .right = 32, .bottom = 32 }};
    try std.testing.expect(helpers.shouldUseFullAtlasUpload(&large, 64, 64));

    const many = [_]AtlasRect{.{ .left = 0, .top = 0, .right = 1, .bottom = 1 }} ** helpers.atlas_full_upload_rect_threshold;
    try std.testing.expect(helpers.shouldUseFullAtlasUpload(&many, 4096, 4096));
}

const Rect = struct {
    left: i32,
    top: i32,
    right: i32,
    bottom: i32,
};

fn checkSparseRowSyncStorageAllocationFailure(alloc: std.mem.Allocator) !void {
    var storage: helpers.SparseRowSyncStorage = .{};
    defer storage.deinit(alloc);

    storage.prepare(alloc, 65) catch |err| {
        try std.testing.expect(!storage.isReady(65));
        return err;
    };
    try std.testing.expect(storage.isReady(65));
}

test "sparse row sync storage reports every partial allocation failure as unready" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        checkSparseRowSyncStorageAllocationFailure,
        .{},
    );
}

test "sparse row sync storage recovers on the same object after every partial failure" {
    const row_count = 65;
    const allocation_count = count: {
        var probe = std.testing.FailingAllocator.init(std.testing.allocator, .{});
        const alloc = probe.allocator();
        var storage: helpers.SparseRowSyncStorage = .{};
        defer storage.deinit(alloc);
        try storage.prepare(alloc, row_count);
        break :count probe.alloc_index;
    };

    for (0..allocation_count) |fail_index| {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{
            .fail_index = fail_index,
        });
        const alloc = failing.allocator();
        var storage: helpers.SparseRowSyncStorage = .{};
        defer storage.deinit(alloc);

        try std.testing.expectError(error.OutOfMemory, storage.prepare(alloc, row_count));
        try std.testing.expect(!storage.isReady(row_count));
        for (storage.row_sync_full) |needs_full| try std.testing.expect(needs_full);

        // The production retry reuses the same partially-grown storage and
        // allocator. Disable the one injected failure and require every
        // remaining allocation plus row registration to complete.
        failing.fail_index = std.math.maxInt(usize);
        try storage.prepare(alloc, row_count);
        try std.testing.expect(storage.isReady(row_count));
        for (0..row_count) |row| {
            storage.flush_mapping_rows.appendAssumeCapacity(@intCast(row));
            storage.flush_mapping_dirty.set(row);
            storage.flush_dirty_rows.appendAssumeCapacity(@intCast(row));
            storage.flush_dirty.set(row);
        }
        try std.testing.expectEqual(row_count, storage.flush_mapping_rows.items.len);
        try std.testing.expectEqual(row_count, storage.flush_dirty_rows.items.len);
    }
}

test "sparse row sync storage recovers after only flush dirty was grown" {
    var storage: helpers.SparseRowSyncStorage = .{};
    defer storage.deinit(std.testing.allocator);

    const row_count = 65;
    try storage.flush_dirty.resize(std.testing.allocator, row_count, false);

    var no_memory: [0]u8 = .{};
    var fba = std.heap.FixedBufferAllocator.init(&no_memory);
    try std.testing.expectError(error.OutOfMemory, storage.prepare(fba.allocator(), row_count));
    try std.testing.expectEqual(row_count, storage.flush_dirty.bit_length);
    try std.testing.expect(!storage.isReady(row_count));

    try storage.prepare(std.testing.allocator, row_count);
    try std.testing.expect(storage.isReady(row_count));
}

test "sparse row sync storage keeps high-water sparse bitsets and stale rows on shrink" {
    var storage: helpers.SparseRowSyncStorage = .{};
    defer storage.deinit(std.testing.allocator);

    try storage.prepare(std.testing.allocator, 128);
    storage.row_sync_stale[0].set(100);
    storage.row_sync_rows[0].appendAssumeCapacity(100);

    try storage.prepare(std.testing.allocator, 32);
    try std.testing.expectEqual(@as(usize, 128), storage.prepared_rows);
    try std.testing.expectEqual(@as(usize, 32), storage.flush_dirty.bit_length);
    try std.testing.expectEqual(@as(usize, 128), storage.flush_mapping_dirty.bit_length);
    for (0..helpers.SparseRowSyncStorage.set_count) |i| {
        try std.testing.expectEqual(@as(usize, 128), storage.row_sync_stale[i].bit_length);
    }
    try std.testing.expect(storage.row_sync_stale[0].isSet(100));
    try std.testing.expectEqualSlices(u32, &.{100}, storage.row_sync_rows[0].items);
}

test "sparse row sync storage keeps registration allocation-free across shrink and grow" {
    var storage: helpers.SparseRowSyncStorage = .{};
    defer storage.deinit(std.testing.allocator);

    const high_rows = 128;
    const low_rows = 32;
    try storage.prepare(std.testing.allocator, high_rows);
    const high_capacity = storage.flush_dirty_rows.capacity;
    for (0..high_rows) |row| try std.testing.expect(storage.markFlushDirtyRow(row));
    try std.testing.expectEqual(high_rows, storage.flush_dirty_rows.items.len);

    try storage.prepare(std.testing.allocator, low_rows);
    try std.testing.expectEqual(low_rows, storage.flush_dirty_rows.items.len);
    for (storage.flush_dirty_rows.items) |row| try std.testing.expect(row < low_rows);

    try storage.prepare(std.testing.allocator, high_rows);
    for (0..high_rows) |row| try std.testing.expect(storage.markFlushDirtyRow(row));
    try std.testing.expectEqual(high_rows, storage.flush_dirty_rows.items.len);
    try std.testing.expectEqual(high_capacity, storage.flush_dirty_rows.capacity);
}

test "sparse row sync deduplicates rows and catches up across three rotations" {
    const Model = helpers.SparseRowSyncModel(8);
    var model = Model{};

    const first = model.begin().?;
    model.maps[first][3] = 11;
    model.commit(first, &.{ 3, 3 }, false);
    const second = model.begin().?;
    try std.testing.expectEqual(@as(u16, 11), model.maps[second][3]);
    model.maps[second][5] = 22;
    model.commit(second, &.{5}, false);
    const third = model.begin().?;
    try std.testing.expectEqual(@as(u16, 11), model.maps[third][3]);
    try std.testing.expectEqual(@as(u16, 22), model.maps[third][5]);
}

test "sparse row sync accumulates while reader holds a set" {
    const Model = helpers.SparseRowSyncModel(8);
    var model = Model{};
    model.reader[0] = true;

    const first = model.begin().?;
    model.maps[first][1] = 7;
    model.commit(first, &.{1}, false);
    const second = model.begin().?;
    model.maps[second][6] = 9;
    model.commit(second, &.{6}, false);

    try std.testing.expect(model.stale[0].isSet(1));
    try std.testing.expect(model.stale[0].isSet(6));
    model.reader[0] = false;
    const clean_spare: u8 = @intCast(3 - model.committed);
    model.reader[clean_spare] = true;
    const caught_up = model.begin().?;
    try std.testing.expectEqual(@as(u8, 0), caught_up);
    try std.testing.expectEqual(@as(u16, 7), model.maps[0][1]);
    try std.testing.expectEqual(@as(u16, 9), model.maps[0][6]);
}

test "sparse row sync abort and structural barrier force complete catch-up" {
    const Model = helpers.SparseRowSyncModel(8);
    var model = Model{};

    const aborted = model.begin().?;
    model.maps[aborted][2] = 99;
    model.abort(aborted);
    try std.testing.expect(model.full[aborted]);
    const other_spare: u8 = if (aborted == 1) 2 else 1;
    model.reader[other_spare] = true;
    const retry = model.begin().?;
    try std.testing.expectEqual(aborted, retry);
    try std.testing.expectEqual(@as(u16, 0), model.maps[retry][2]);

    model.maps[retry][4] = 42;
    model.commit(retry, &.{4}, true);
    for (0..3) |i| {
        if (i != retry and i != other_spare) try std.testing.expectEqual(@as(u16, 42), model.maps[i][4]);
    }
    try std.testing.expect(model.full[other_spare]);
    const clean_spare: u8 = @intCast(3 - retry - other_spare);
    model.reader[clean_spare] = true;
    model.reader[other_spare] = false;
    const barrier_catch_up = model.begin().?;
    try std.testing.expectEqual(other_spare, barrier_catch_up);
    try std.testing.expectEqual(@as(u16, 42), model.maps[barrier_catch_up][4]);
}

test "atlas reset admission never waits for an active paint" {
    var reset_active = std.atomic.Value(bool).init(false);
    var paint_active = std.atomic.Value(bool).init(false);
    var shutting_down = std.atomic.Value(bool).init(false);

    try std.testing.expect(helpers.tryBeginAtlasPaint(&reset_active, &paint_active));
    try std.testing.expectEqual(
        helpers.AtlasResetAdmission.busy,
        helpers.tryBeginAtlasReset(&reset_active, &paint_active, &shutting_down),
    );
    try std.testing.expect(!reset_active.load(.acquire));

    helpers.endAtlasPaint(&paint_active);
    try std.testing.expectEqual(
        helpers.AtlasResetAdmission.acquired,
        helpers.tryBeginAtlasReset(&reset_active, &paint_active, &shutting_down),
    );
    try std.testing.expect(reset_active.load(.acquire));
    try std.testing.expect(!helpers.tryBeginAtlasPaint(&reset_active, &paint_active));
}

test "atlas reset admission refuses shutdown" {
    var reset_active = std.atomic.Value(bool).init(false);
    var paint_active = std.atomic.Value(bool).init(false);
    var shutting_down = std.atomic.Value(bool).init(true);

    try std.testing.expectEqual(
        helpers.AtlasResetAdmission.shutting_down,
        helpers.tryBeginAtlasReset(&reset_active, &paint_active, &shutting_down),
    );
    try std.testing.expect(!reset_active.load(.acquire));
}

test "sorted row merge deduplicates an overlapping contiguous range" {
    var rows: std.ArrayListUnmanaged(u32) = .empty;
    defer rows.deinit(std.testing.allocator);
    var scratch: std.ArrayListUnmanaged(u32) = .empty;
    defer scratch.deinit(std.testing.allocator);
    try rows.appendSlice(std.testing.allocator, &.{ 1, 3, 4, 8 });

    try std.testing.expect(helpers.mergeSortedRowsWithRange(
        std.testing.allocator,
        &rows,
        &scratch,
        2,
        7,
    ));
    try std.testing.expectEqualSlices(u32, &.{ 1, 2, 3, 4, 5, 6, 8 }, rows.items);
}

test "sorted row merge handles disjoint ranges on either side" {
    var rows: std.ArrayListUnmanaged(u32) = .empty;
    defer rows.deinit(std.testing.allocator);
    var scratch: std.ArrayListUnmanaged(u32) = .empty;
    defer scratch.deinit(std.testing.allocator);
    try rows.appendSlice(std.testing.allocator, &.{ 4, 5 });

    try std.testing.expect(helpers.mergeSortedRowsWithRange(std.testing.allocator, &rows, &scratch, 0, 2));
    try std.testing.expectEqualSlices(u32, &.{ 0, 1, 4, 5 }, rows.items);
    try std.testing.expect(helpers.mergeSortedRowsWithRange(std.testing.allocator, &rows, &scratch, 7, 9));
    try std.testing.expectEqualSlices(u32, &.{ 0, 1, 4, 5, 7, 8 }, rows.items);
}

test "sorted row merge leaves input intact on allocation failure" {
    var rows: std.ArrayListUnmanaged(u32) = .empty;
    defer rows.deinit(std.testing.allocator);
    try rows.appendSlice(std.testing.allocator, &.{ 1, 3 });
    var scratch: std.ArrayListUnmanaged(u32) = .empty;
    var no_memory: [0]u8 = .{};
    var fba = std.heap.FixedBufferAllocator.init(&no_memory);

    try std.testing.expect(!helpers.mergeSortedRowsWithRange(fba.allocator(), &rows, &scratch, 0, 5));
    try std.testing.expectEqualSlices(u32, &.{ 1, 3 }, rows.items);
}

test "single sorted row insertion reports OOM without consuming scroll damage" {
    var storage: [2 * @sizeOf(u32)]u8 align(@alignOf(u32)) = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&storage);
    var rows: std.ArrayListUnmanaged(u32) = .empty;
    defer rows.deinit(fba.allocator());
    try rows.ensureTotalCapacityPrecise(fba.allocator(), 2);
    rows.appendSliceAssumeCapacity(&.{ 1, 3 });

    try std.testing.expect(!helpers.insertSortedRow(fba.allocator(), &rows, 2));
    try std.testing.expectEqualSlices(u32, &.{ 1, 3 }, rows.items);

    var success_rows: std.ArrayListUnmanaged(u32) = .empty;
    defer success_rows.deinit(std.testing.allocator);
    try success_rows.appendSlice(std.testing.allocator, &.{ 1, 3 });
    try std.testing.expect(helpers.insertSortedRow(std.testing.allocator, &success_rows, 2));
    try std.testing.expectEqualSlices(u32, &.{ 1, 2, 3 }, success_rows.items);
    try std.testing.expect(helpers.insertSortedRow(std.testing.allocator, &success_rows, 2));
    try std.testing.expectEqualSlices(u32, &.{ 1, 2, 3 }, success_rows.items);
}

test "cursor replacement dirties old and new rows" {
    var storage: [2]usize = undefined;
    try std.testing.expectEqualSlices(
        usize,
        &.{ 3, 8 },
        helpers.cursorDirtyRows(3, 8, 10, &storage),
    );
    try std.testing.expectEqualSlices(
        usize,
        &.{3},
        helpers.cursorDirtyRows(3, null, 10, &storage),
    );
    try std.testing.expectEqualSlices(
        usize,
        &.{3},
        helpers.cursorDirtyRows(3, 3, 10, &storage),
    );
    try std.testing.expectEqual(@as(usize, 0), helpers.cursorDirtyRows(12, null, 10, &storage).len);
}

test "slot backing retires once a layout shrink leaves it oversized" {
    // 80 columns of ordinary content, so the peak this layout produced is a
    // typical row: its own slots keep their backing, slack included.
    const peak: usize = 80 * 12;
    try std.testing.expect(!helpers.shouldRetireSlotBacking(0, peak));
    try std.testing.expect(!helpers.shouldRetireSlotBacking(peak, peak));
    try std.testing.expect(!helpers.shouldRetireSlotBacking(peak * 2, peak));
    try std.testing.expect(helpers.shouldRetireSlotBacking(peak * 2 + 1, peak));
    // A 340-column slot released after the shrink — what this exists to retire.
    try std.testing.expect(helpers.shouldRetireSlotBacking(340 * 12, peak));
}

test "a dense row keeps its backing across slot rotation" {
    // A row's vertex count has no per-cell bound: an unmerged background, a
    // two-quad block glyph and an underdouble already reach 30 verts/cell.
    // Measuring the layout rather than assuming 12/cell is what keeps this slot
    // off the retirement path -- were it retired, applySparseRowSync would
    // release it every flush and the next write would reallocate it.
    const dense_peak: usize = 200 * 30;
    try std.testing.expect(!helpers.shouldRetireSlotBacking(dense_peak, dense_peak));
    // Even the headroom an ArrayList grow left behind stays.
    try std.testing.expect(!helpers.shouldRetireSlotBacking(dense_peak * 2, dense_peak));
    // The same capacity would have been retired by a 12-verts/cell guess.
    try std.testing.expect(helpers.shouldRetireSlotBacking(dense_peak, 200 * 12));
}

test "slot backing is retained until the layout has produced a row" {
    // layout_peak_verts is 0 before the first write and after every width
    // change. Retiring then would free backing on nothing but a guess.
    try std.testing.expect(!helpers.shouldRetireSlotBacking(0, 0));
    try std.testing.expect(!helpers.shouldRetireSlotBacking(4096, 0));
    try std.testing.expect(!helpers.shouldRetireSlotBacking(std.math.maxInt(usize), 0));
}

test "damage compaction merges row spans and contained cursor damage" {
    var rects = [_]Rect{
        .{ .left = 40, .top = 12, .right = 50, .bottom = 18 },
        .{ .left = 0, .top = 20, .right = 100, .bottom = 30 },
        .{ .left = 0, .top = 0, .right = 100, .bottom = 10 },
        .{ .left = 0, .top = 10, .right = 100, .bottom = 20 },
    };

    const len = helpers.compactDamageRects(Rect, &rects);
    try std.testing.expectEqual(@as(usize, 1), len);
    try std.testing.expectEqual(Rect{ .left = 0, .top = 0, .right = 100, .bottom = 30 }, rects[0]);
}

test "damage compaction preserves disjoint rectangles" {
    var rects = [_]Rect{
        .{ .left = 20, .top = 20, .right = 30, .bottom = 30 },
        .{ .left = 0, .top = 0, .right = 10, .bottom = 10 },
    };

    const len = helpers.compactDamageRects(Rect, &rects);
    try std.testing.expectEqual(@as(usize, 2), len);
    try std.testing.expectEqual(Rect{ .left = 0, .top = 0, .right = 10, .bottom = 10 }, rects[0]);
    try std.testing.expectEqual(Rect{ .left = 20, .top = 20, .right = 30, .bottom = 30 }, rects[1]);
}

// ---------------------------------------------------------------------------
// DWrite cluster-map inversion
//
// include/zonvie_core.h states the contract: out_clusters[i] is the index of
// the FIRST input scalar that produced glyph i. The macOS bridge satisfies it
// by forwarding HarfBuzz's cluster values directly; these cases pin the same
// contract for the DWrite side, which has to invert the map itself.
// ---------------------------------------------------------------------------

fn expectInversion(
    cluster_map: []const u16,
    scalar_idx: []const u32,
    glyph_count: usize,
    expected: []const u32,
) !void {
    var out: [8]u32 = @splat(0);
    helpers.invertClusterMap(cluster_map, scalar_idx, glyph_count, &out);
    try std.testing.expectEqualSlices(u32, expected, out[0..glyph_count]);
}

test "cluster inversion: one glyph per scalar" {
    try expectInversion(
        &.{ 0, 1, 2, 3 },
        &.{ 0, 1, 2, 3 },
        4,
        &.{ 0, 1, 2, 3 },
    );
}

test "cluster inversion: one scalar producing several glyphs" {
    // A single position whose cluster covers two glyphs: both name that scalar.
    try expectInversion(&.{0}, &.{0}, 2, &.{ 0, 0 });
}

test "cluster inversion: a surrogate pair is one scalar" {
    // Both UTF-16 units carry the same scalar index, so the cluster's first and
    // last position resolve identically. This case is immune by construction.
    try expectInversion(&.{ 0, 0 }, &.{ 0, 0 }, 1, &.{0});
}

test "cluster inversion: many scalars to one glyph at the start of a run" {
    // Positions 0-1 fold into glyph 0. The contract names scalar 0, not 1.
    try expectInversion(
        &.{ 0, 0, 1, 2 },
        &.{ 0, 1, 2, 3 },
        3,
        &.{ 0, 2, 3 },
    );
}

test "cluster inversion: many scalars to one glyph mid-run" {
    // Positions 1-2 fold into glyph 1. This is the case shapeClustersValid
    // cannot catch: [0,2,3] starts at zero and is monotonic, so a wrong answer
    // here reaches vertex generation instead of falling back safely.
    try expectInversion(
        &.{ 0, 1, 1, 2 },
        &.{ 0, 1, 2, 3 },
        3,
        &.{ 0, 1, 3 },
    );
}

test "cluster inversion: a variation-selector emoji mid-run" {
    // "a" followed by U+26A0 U+FE0F shaped as one glyph. Naming the last scalar
    // makes the cluster look single-scalar and hands the rasterizer the
    // invisible selector as the cluster's base.
    try expectInversion(
        &.{ 0, 1, 1 },
        &.{ 0, 1, 2 },
        2,
        &.{ 0, 1 },
    );
}

// --- Row-scroll blit plan -------------------------------------------------
// Ported from macos/Tests/RowScrollBlitPlanTests.swift: one row height, one
// texture, so each case reads as rows.

const row_h_px: i32 = 20;
const tex_rows: i32 = 44;
const tex_w_px: i32 = 800;

fn plan(row_start: u32, row_end: u32, rows_delta: i32, rows_in_tex: i32) ?helpers.RowScrollBlitPlan {
    return helpers.RowScrollBlitPlan.make(
        row_start,
        row_end,
        rows_delta,
        0,
        0,
        tex_w_px,
        tex_w_px,
        rows_in_tex * row_h_px,
        row_h_px,
    );
}

test "row scroll down reads from below and vacates the bottom" {
    const p = plan(0, 44, 3, tex_rows).?;
    try std.testing.expectEqual(@as(i32, 3 * row_h_px), p.src_y_px);
    try std.testing.expectEqual(@as(i32, 0), p.dst_y_px);
    try std.testing.expectEqual(@as(i32, 41 * row_h_px), p.copy_h_px);
    try std.testing.expectEqual(tex_w_px, p.copy_w_px);
    try std.testing.expectEqual(@as(i32, 41 * row_h_px), p.clear_top_px);
    try std.testing.expectEqual(@as(i32, 44 * row_h_px), p.clear_bottom_px);
    try std.testing.expectEqual(@as(u32, 44), p.clamped_row_end);
    try std.testing.expectEqual(@as(u32, 38), p.dirty_row_start);
    try std.testing.expectEqual(@as(u32, 44), p.dirty_row_end);
}

test "row scroll up is the mirror image" {
    const p = plan(0, 44, -3, tex_rows).?;
    try std.testing.expectEqual(@as(i32, 0), p.src_y_px);
    try std.testing.expectEqual(@as(i32, 3 * row_h_px), p.dst_y_px);
    try std.testing.expectEqual(@as(i32, 41 * row_h_px), p.copy_h_px);
    try std.testing.expectEqual(@as(i32, 0), p.clear_top_px);
    try std.testing.expectEqual(@as(i32, 3 * row_h_px), p.clear_bottom_px);
    try std.testing.expectEqual(@as(u32, 0), p.dirty_row_start);
    try std.testing.expectEqual(@as(u32, 6), p.dirty_row_end);
}

test "a region that does not start at row 0 keeps its dirty rows inside" {
    const p = plan(10, 30, 2, tex_rows).?;
    try std.testing.expectEqual(@as(i32, 12 * row_h_px), p.src_y_px);
    try std.testing.expectEqual(@as(i32, 10 * row_h_px), p.dst_y_px);
    try std.testing.expectEqual(@as(i32, 18 * row_h_px), p.copy_h_px);
    try std.testing.expectEqual(@as(u32, 26), p.dirty_row_start);
    try std.testing.expectEqual(@as(u32, 30), p.dirty_row_end);

    // The expansion never reaches above the region start.
    const small = plan(10, 13, 2, tex_rows).?;
    try std.testing.expectEqual(@as(u32, 10), small.dirty_row_start);
    try std.testing.expectEqual(@as(u32, 13), small.dirty_row_end);
}

test "the texture clamp stops the copy, the band and the dirty rows together" {
    const p = plan(0, 45, 1, tex_rows).?;
    try std.testing.expectEqual(@as(u32, 44), p.clamped_row_end);
    try std.testing.expectEqual(@as(i32, 43 * row_h_px), p.copy_h_px);
    try std.testing.expectEqual(@as(i32, 44 * row_h_px), p.clear_bottom_px);
    try std.testing.expectEqual(@as(u32, 42), p.dirty_row_start);
    try std.testing.expectEqual(@as(u32, 44), p.dirty_row_end);

    const far = plan(0, 50, 2, tex_rows).?;
    try std.testing.expectEqual(@as(u32, 40), far.dirty_row_start);
    try std.testing.expectEqual(@as(u32, 44), far.dirty_row_end);
    try std.testing.expectEqual(@as(i32, 42 * row_h_px), far.clear_top_px);
}

test "geometries that produce no blit plan" {
    try std.testing.expect(plan(0, 44, 0, tex_rows) == null);
    try std.testing.expect(plan(0, 10, 10, tex_rows) == null);
    try std.testing.expect(plan(0, 10, 12, tex_rows) == null);
    try std.testing.expect(plan(44, 50, 1, tex_rows) == null);
    try std.testing.expect(plan(0, 44, 1, 0) == null);
    try std.testing.expect(helpers.RowScrollBlitPlan.make(
        0,
        44,
        1,
        0,
        0,
        0,
        tex_w_px,
        44 * row_h_px,
        row_h_px,
    ) == null);
    try std.testing.expect(helpers.RowScrollBlitPlan.make(
        0,
        44,
        1,
        0,
        0,
        tex_w_px,
        tex_w_px,
        44 * row_h_px,
        0,
    ) == null);
}

test "the copy width is bounded by the texture" {
    const narrow = helpers.RowScrollBlitPlan.make(
        0,
        44,
        1,
        0,
        0,
        800,
        500,
        44 * row_h_px,
        row_h_px,
    ).?;
    try std.testing.expectEqual(@as(i32, 500), narrow.copy_w_px);
}

test "blit plan invariants hold over every small geometry" {
    var planned: usize = 0;
    var rows_in_tex: i32 = 0;
    while (rows_in_tex <= 12) : (rows_in_tex += 1) {
        var row_start: u32 = 0;
        while (row_start <= 12) : (row_start += 1) {
            var row_end: u32 = 0;
            while (row_end <= 16) : (row_end += 1) {
                var rows_delta: i32 = -8;
                while (rows_delta <= 8) : (rows_delta += 1) {
                    const p = plan(row_start, row_end, rows_delta, rows_in_tex) orelse continue;
                    planned += 1;
                    const tex_h_px = rows_in_tex * row_h_px;
                    try std.testing.expect(p.src_y_px >= 0 and p.dst_y_px >= 0);
                    try std.testing.expect(p.copy_h_px > 0);
                    try std.testing.expect(p.src_y_px + p.copy_h_px <= tex_h_px);
                    try std.testing.expect(p.dst_y_px + p.copy_h_px <= tex_h_px);
                    try std.testing.expect(p.clear_bottom_px <= tex_h_px);
                    try std.testing.expect(p.clear_top_px < p.clear_bottom_px);
                    try std.testing.expect(p.clamped_row_end <= @as(u32, @intCast(rows_in_tex)));
                    try std.testing.expect(p.clamped_row_end <= row_end);
                    const vacated_first: u32 = @intCast(@divTrunc(p.clear_top_px, row_h_px));
                    const vacated_end: u32 = @intCast(@divTrunc(p.clear_bottom_px, row_h_px));
                    try std.testing.expect(p.dirty_row_start <= vacated_first);
                    try std.testing.expect(vacated_end <= p.dirty_row_end);
                    try std.testing.expect(p.dirty_row_start >= row_start);
                    try std.testing.expect(p.dirty_row_end <= p.clamped_row_end);
                }
            }
        }
    }
    try std.testing.expect(planned > 100);
}

test "without a blit the whole region is stale, still clamped to the texture" {
    try std.testing.expectEqual(
        [2]u32{ 0, 44 },
        helpers.dirtyRowsWithoutBlit(0, 45, 0, 44 * row_h_px, row_h_px).?,
    );
    try std.testing.expectEqual(
        [2]u32{ 10, 30 },
        helpers.dirtyRowsWithoutBlit(10, 30, 0, 44 * row_h_px, row_h_px).?,
    );
    try std.testing.expect(helpers.dirtyRowsWithoutBlit(44, 50, 0, 44 * row_h_px, row_h_px) == null);
    try std.testing.expect(helpers.dirtyRowsWithoutBlit(0, 10, 0, 44 * row_h_px, 0) == null);
}

test "a layer origin moves the pixels but not the row numbering" {
    const origin_y_px: i32 = 5 * row_h_px;
    const origin_x_px: i32 = 400;
    const base = plan(0, 20, 3, tex_rows).?;
    const p = helpers.RowScrollBlitPlan.make(
        0,
        20,
        3,
        origin_x_px,
        origin_y_px,
        400,
        tex_w_px,
        tex_rows * row_h_px,
        row_h_px,
    ).?;
    try std.testing.expectEqual(base.src_y_px + origin_y_px, p.src_y_px);
    try std.testing.expectEqual(base.dst_y_px + origin_y_px, p.dst_y_px);
    try std.testing.expectEqual(base.clear_top_px + origin_y_px, p.clear_top_px);
    try std.testing.expectEqual(base.clear_bottom_px + origin_y_px, p.clear_bottom_px);
    try std.testing.expectEqual(base.dirty_row_start, p.dirty_row_start);
    try std.testing.expectEqual(base.dirty_row_end, p.dirty_row_end);
    try std.testing.expectEqual(origin_x_px, p.origin_x_px);
    try std.testing.expectEqual(@as(i32, 400), p.copy_w_px);

    const band = p.localClearBand();
    try std.testing.expectEqual(base.clear_top_px, band.top_px);
    try std.testing.expectEqual(base.clear_bottom_px, band.bottom_px);

    // The rewritten pixels stay inside the layer's own rectangle.
    const r = p.blitRectPx();
    try std.testing.expectEqual(origin_x_px, r.left);
    try std.testing.expectEqual(origin_x_px + 400, r.right);
    try std.testing.expectEqual(origin_y_px, r.top);
    try std.testing.expectEqual(origin_y_px + 20 * row_h_px, r.bottom);
}

test "a narrow layer copies its own width, clamped by the texture's right edge" {
    const inside = helpers.RowScrollBlitPlan.make(
        0,
        44,
        1,
        0,
        0,
        300,
        800,
        tex_rows * row_h_px,
        row_h_px,
    ).?;
    try std.testing.expectEqual(@as(i32, 300), inside.copy_w_px);

    const offset = helpers.RowScrollBlitPlan.make(
        0,
        44,
        1,
        600,
        0,
        300,
        800,
        tex_rows * row_h_px,
        row_h_px,
    ).?;
    try std.testing.expectEqual(@as(i32, 200), offset.copy_w_px);
}

test "a layer below the texture has nothing to blit and nothing to redraw" {
    try std.testing.expect(helpers.RowScrollBlitPlan.make(
        0,
        20,
        2,
        0,
        50 * row_h_px,
        tex_w_px,
        tex_w_px,
        tex_rows * row_h_px,
        row_h_px,
    ) == null);
    try std.testing.expect(helpers.dirtyRowsWithoutBlit(
        0,
        20,
        50 * row_h_px,
        tex_rows * row_h_px,
        row_h_px,
    ) == null);
}

test "a layer whose rows run off the bottom clamps the blit and the fallback alike" {
    const origin_y_px: i32 = 30 * row_h_px;
    const tex_h_px: i32 = tex_rows * row_h_px;
    const p = helpers.RowScrollBlitPlan.make(
        0,
        20,
        2,
        0,
        origin_y_px,
        tex_w_px,
        tex_w_px,
        tex_h_px,
        row_h_px,
    ).?;
    try std.testing.expectEqual(@as(u32, 14), p.clamped_row_end);
    try std.testing.expectEqual(@as(u32, 10), p.dirty_row_start);
    try std.testing.expectEqual(@as(u32, 14), p.dirty_row_end);
    try std.testing.expect(p.src_y_px + p.copy_h_px <= tex_h_px);
    try std.testing.expect(p.dst_y_px + p.copy_h_px <= tex_h_px);
    try std.testing.expectEqual(tex_h_px, p.clear_bottom_px);
    try std.testing.expectEqual(
        [2]u32{ 0, 14 },
        helpers.dirtyRowsWithoutBlit(0, 20, origin_y_px, tex_h_px, row_h_px).?,
    );
}

/// A layer at y=100 scrolled down by 3: the blit rewrites rows 0..20 of it,
/// pixels 100..500.
fn overBlitBase() helpers.RowScrollBlitPlan {
    return helpers.RowScrollBlitPlan.make(
        0,
        20,
        3,
        0,
        100,
        400,
        tex_w_px,
        tex_rows * row_h_px,
        row_h_px,
    ).?;
}

test "a float over the blit marks its own rows, the rows under it and their source" {
    const p = overBlitBase();
    const r = p.blitRectPx();
    try std.testing.expectEqual(@as(i32, 0), r.left);
    try std.testing.expectEqual(@as(i32, 100), r.top);
    try std.testing.expectEqual(@as(i32, 400), r.right);
    try std.testing.expectEqual(@as(i32, 500), r.bottom);

    // A float at y=210, 4 rows tall, x=100..200: straddles the band.
    const got = helpers.rowsOverBlit(p, 3, 100, 210, 4, 10, 10, row_h_px).?;
    try std.testing.expectEqual([2]u32{ 0, 3 }, got.above.?);
    try std.testing.expectEqual([2]u32{ 5, 9 }, got.under.?);
    // Shifted back by the delta, never forward.
    try std.testing.expectEqual([2]u32{ 2, 6 }, got.shifted.?);
}

test "rows over a blit clamp to the covering layer and to the scroll region" {
    const p = overBlitBase();

    // Starts above the blit rectangle: the covering layer's first marked row
    // is the one the rectangle's top edge lands in, not its own row 0.
    const high = helpers.rowsOverBlit(p, 3, 0, 60, 4, 40, 10, row_h_px).?;
    try std.testing.expectEqual([2]u32{ 2, 3 }, high.above.?);

    // Taller than the rectangle: both ranges stop at the region's last row.
    const tall = helpers.rowsOverBlit(p, 3, 0, 100, 30, 40, 10, row_h_px).?;
    try std.testing.expectEqual([2]u32{ 0, 19 }, tall.above.?);
    try std.testing.expectEqual([2]u32{ 0, 19 }, tall.under.?);
    try std.testing.expectEqual([2]u32{ 0, 16 }, tall.shifted.?);
}

test "a float that misses the blit rectangle marks nothing" {
    const p = overBlitBase();
    // Entirely to the right of the copy.
    try std.testing.expect(helpers.rowsOverBlit(p, 3, 400, 210, 4, 10, 10, row_h_px) == null);
    // Entirely below it.
    try std.testing.expect(helpers.rowsOverBlit(p, 3, 100, 500, 4, 10, 10, row_h_px) == null);
    // Empty covering layer.
    try std.testing.expect(helpers.rowsOverBlit(p, 3, 100, 210, 0, 10, 10, row_h_px) == null);
}

test "a root dirty band marks the layer rows it overpaints" {
    // Cell-aligned: one root row lands on exactly one layer row.
    try std.testing.expectEqual([2]u32{ 5, 5 }, helpers.bandLayerRows(200, 220, 100, 10, row_h_px).?);
    // Off the cell grid: the same band straddles two.
    try std.testing.expectEqual([2]u32{ 4, 5 }, helpers.bandLayerRows(200, 220, 110, 10, row_h_px).?);
    // Overlapping the layer's top edge from above.
    try std.testing.expectEqual([2]u32{ 0, 0 }, helpers.bandLayerRows(90, 110, 100, 10, row_h_px).?);
    // Entirely above the layer.
    try std.testing.expect(helpers.bandLayerRows(0, 20, 100, 10, row_h_px) == null);
    // Entirely below it.
    try std.testing.expect(helpers.bandLayerRows(400, 420, 100, 2, row_h_px) == null);
}

test "layer scrolls in one flush accumulate per region and saturate" {
    const first: helpers.LayerScroll =
        .{ .row_start = 2, .row_end = 20, .rows_delta = 3, .total_rows = 20, .total_cols = 80 };
    switch (helpers.mergeLayerScroll(null, first)) {
        .accumulate => |m| try std.testing.expectEqual(first, m),
        .conflict => return error.TestUnexpectedResult,
    }

    var second = first;
    second.rows_delta = -5;
    second.total_cols = 90;
    switch (helpers.mergeLayerScroll(first, second)) {
        .accumulate => |m| {
            try std.testing.expectEqual(@as(i32, -2), m.rows_delta);
            try std.testing.expectEqual(@as(u32, 90), m.total_cols);
        },
        .conflict => return error.TestUnexpectedResult,
    }

    var huge = first;
    huge.rows_delta = 1_000_000;
    switch (helpers.mergeLayerScroll(huge, huge)) {
        .accumulate => |m| try std.testing.expectEqual(@as(i32, 1_000_000), m.rows_delta),
        .conflict => return error.TestUnexpectedResult,
    }
    huge.rows_delta = -1_000_000;
    switch (helpers.mergeLayerScroll(huge, huge)) {
        .accumulate => |m| try std.testing.expectEqual(@as(i32, -1_000_000), m.rows_delta),
        .conflict => return error.TestUnexpectedResult,
    }
    try std.testing.expectEqual(@as(i32, 1_000_000), helpers.clampRowsDelta(std.math.maxInt(i32)));
    try std.testing.expectEqual(@as(i32, -1_000_000), helpers.clampRowsDelta(std.math.minInt(i32)));
}

test "layer scrolls of different regions report both regions" {
    const first: helpers.LayerScroll =
        .{ .row_start = 2, .row_end = 20, .rows_delta = 3, .total_rows = 20, .total_cols = 80 };
    var other = first;
    other.row_start = 5;
    other.rows_delta = -1;
    switch (helpers.mergeLayerScroll(first, other)) {
        .accumulate => return error.TestUnexpectedResult,
        .conflict => |m| {
            try std.testing.expectEqual(first, m.old);
            try std.testing.expectEqual(other, m.new);
        },
    }

    var shorter = first;
    shorter.row_end = 19;
    switch (helpers.mergeLayerScroll(first, shorter)) {
        .accumulate => return error.TestUnexpectedResult,
        .conflict => |m| try std.testing.expectEqual(shorter, m.new),
    }
}

test "blit rectangle stays inside the layer it scrolls" {
    const cell_w_px: i32 = 9;
    const tex_w: i32 = 1600;
    const tex_h: i32 = 900;
    const origins = [_][2]i32{ .{ 0, 0 }, .{ 90, 40 }, .{ 720, 300 }, .{ 1200, 860 } };
    const deltas = [_]i32{ -7, -3, -1, 1, 3, 7 };
    const cols: u32 = 40;
    const rows: u32 = 24;

    for (origins) |o| {
        for (deltas) |d| {
            var row_start: u32 = 0;
            while (row_start < 6) : (row_start += 1) {
                const p = helpers.RowScrollBlitPlan.make(
                    row_start,
                    rows,
                    d,
                    o[0],
                    o[1],
                    @as(i32, @intCast(cols)) * cell_w_px,
                    tex_w,
                    tex_h,
                    row_h_px,
                ) orelse continue;
                const r = p.blitRectPx();
                try std.testing.expect(r.left >= o[0]);
                try std.testing.expect(r.right <= o[0] + @as(i32, @intCast(cols)) * cell_w_px);
                try std.testing.expect(r.right <= tex_w);
                try std.testing.expect(r.top >= o[1] + @as(i32, @intCast(row_start)) * row_h_px);
                try std.testing.expect(r.bottom <= o[1] + @as(i32, @intCast(p.clamped_row_end)) * row_h_px);
                try std.testing.expect(r.bottom <= tex_h);
                try std.testing.expect(r.bottom > r.top and r.right > r.left);
            }
        }
    }
}

test "accepted blit rectangles only refuse layers that share pixels" {
    const accepted: helpers.BlitRectPx = .{ .left = 100, .top = 200, .right = 400, .bottom = 500 };
    // Touching edges are outside a half-open rectangle.
    try std.testing.expect(!helpers.blitRectsIntersect(
        .{ .left = 400, .top = 200, .right = 700, .bottom = 500 },
        accepted,
    ));
    try std.testing.expect(!helpers.blitRectsIntersect(
        .{ .left = 100, .top = 500, .right = 400, .bottom = 800 },
        accepted,
    ));
    try std.testing.expect(!helpers.blitRectsIntersect(
        .{ .left = 0, .top = 200, .right = 100, .bottom = 500 },
        accepted,
    ));
    try std.testing.expect(!helpers.blitRectsIntersect(
        .{ .left = 100, .top = 0, .right = 400, .bottom = 200 },
        accepted,
    ));
    // One pixel of overlap is an overlap, in either argument order.
    const nudged: helpers.BlitRectPx = .{ .left = 399, .top = 499, .right = 700, .bottom = 800 };
    try std.testing.expect(helpers.blitRectsIntersect(nudged, accepted));
    try std.testing.expect(helpers.blitRectsIntersect(accepted, nudged));
    // Contained on both axes.
    try std.testing.expect(helpers.blitRectsIntersect(
        .{ .left = 150, .top = 250, .right = 200, .bottom = 300 },
        accepted,
    ));
}

fn bitsFrom(alloc: std.mem.Allocator, len: usize, set: []const usize) !std.DynamicBitSetUnmanaged {
    var bits = try std.DynamicBitSetUnmanaged.initEmpty(alloc, len);
    for (set) |i| bits.set(i);
    return bits;
}

fn expectBits(bits: *const std.DynamicBitSetUnmanaged, expected: []const usize) !void {
    var i: usize = 0;
    while (i < bits.bit_length) : (i += 1) {
        const want = std.mem.indexOfScalar(usize, expected, i) != null;
        if (bits.isSet(i) != want) {
            std.debug.print("bit {d}: got {}, want {}\n", .{ i, bits.isSet(i), want });
            return error.TestUnexpectedResult;
        }
    }
}

test "a row bit follows its rows up a scroll region" {
    const alloc = std.testing.allocator;
    // grid_line marked row 5, then a second grid_scroll(+3) landed in the same
    // flush: the vertices are at row 2 now, so the bit has to be.
    var bits = try bitsFrom(alloc, 10, &.{5});
    defer bits.deinit(alloc);
    helpers.shiftRowBits(&bits, 0, 10, 3);
    try expectBits(&bits, &.{ 2, 7, 8, 9 });
}

test "a row bit follows its rows down a scroll region" {
    const alloc = std.testing.allocator;
    var bits = try bitsFrom(alloc, 10, &.{2});
    defer bits.deinit(alloc);
    helpers.shiftRowBits(&bits, 0, 10, -3);
    try expectBits(&bits, &.{ 0, 1, 2, 5 });
}

test "row bits outside the scroll region stay where they are" {
    const alloc = std.testing.allocator;
    var bits = try bitsFrom(alloc, 12, &.{ 1, 8, 11 });
    defer bits.deinit(alloc);
    helpers.shiftRowBits(&bits, 4, 10, 2);
    // 8 -> 6; the region vacated [8,10); 1 and 11 are untouched.
    try expectBits(&bits, &.{ 1, 6, 8, 9, 11 });
}

test "a shift the row storage refuses leaves the row bits alone" {
    const alloc = std.testing.allocator;
    var bits = try bitsFrom(alloc, 10, &.{5});
    defer bits.deinit(alloc);
    // Same guards shiftRows applies before it touches rows_buf.
    helpers.shiftRowBits(&bits, 0, 10, 0);
    try expectBits(&bits, &.{5});
    helpers.shiftRowBits(&bits, 10, 4, 3);
    try expectBits(&bits, &.{5});
    helpers.shiftRowBits(&bits, 0, 10, 10);
    try expectBits(&bits, &.{5});
    helpers.shiftRowBits(&bits, 0, 11, 3);
    try expectBits(&bits, &.{5});
}

test "two shifts in one flush compose" {
    const alloc = std.testing.allocator;
    var bits = try bitsFrom(alloc, 10, &.{6});
    defer bits.deinit(alloc);
    helpers.shiftRowBits(&bits, 0, 10, 2);
    // 6 -> 4, vacated [8,10).
    try expectBits(&bits, &.{ 4, 8, 9 });
    helpers.shiftRowBits(&bits, 0, 10, 2);
    // 4 -> 2, 8 -> 6, 9 -> 7, vacated [8,10) again.
    try expectBits(&bits, &.{ 2, 6, 7, 8, 9 });
}
