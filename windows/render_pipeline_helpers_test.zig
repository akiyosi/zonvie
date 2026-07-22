const std = @import("std");
const helpers = @import("render_pipeline_helpers.zig");

test "retry delay doubles and saturates" {
    try std.testing.expectEqual(@as(u32, 32), helpers.nextBackoffDelayMs(16, 2000));
    try std.testing.expectEqual(@as(u32, 2000), helpers.nextBackoffDelayMs(1024, 2000));
    try std.testing.expectEqual(@as(u32, 2000), helpers.nextBackoffDelayMs(2000, 2000));
    try std.testing.expectEqual(@as(u32, 2000), helpers.nextBackoffDelayMs(std.math.maxInt(u32), 2000));
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
