const std = @import("std");

pub fn nextBackoffDelayMs(current_ms: u32, max_ms: u32) u32 {
    return @min(current_ms *| 2, max_ms);
}

pub const device_lost_retry_initial_ms: u32 = 1000;
pub const device_lost_retry_max_ms: u32 = 30_000;
pub const device_lost_warning_after_attempts: u32 = 3;

/// Recovery continues for the lifetime of the window, but retries become
/// infrequent enough that a permanently unavailable adapter cannot spin the
/// UI thread. `failed_attempts == 0` covers deferrals before device creation.
pub fn deviceLostRetryDelayMs(failed_attempts: u32) u32 {
    const exponent: u5 = @intCast(@min(failed_attempts -| 1, 5));
    return @min(device_lost_retry_initial_ms << exponent, device_lost_retry_max_ms);
}

pub fn shouldWarnDeviceLostRecovery(failed_attempts: u32, warning_shown: bool) bool {
    return !warning_shown and failed_attempts > device_lost_warning_after_attempts;
}

/// Choose a bounded geometric capacity for persistent GPU buffers. The
/// caller creates the replacement before releasing the old resource, so a
/// failed grow leaves the last usable buffer intact.
pub fn geometricBufferCapacity(current_bytes: usize, need_bytes: usize, max_bytes: usize) ?usize {
    if (need_bytes > max_bytes) return null;
    if (need_bytes <= current_bytes) return current_bytes;

    var capacity = @max(current_bytes, @min(max_bytes, 4096));
    while (capacity < need_bytes) {
        capacity = @min(max_bytes, capacity *| 2);
        if (capacity < need_bytes and capacity == max_bytes) return null;
    }
    return capacity;
}

pub const row_vb_surface_budget_bytes: usize = 256 * 1024 * 1024;
pub const row_vb_process_budget_bytes: usize = 512 * 1024 * 1024;

/// Check the physical peak while a replacement D3D buffer is created. The
/// old buffer remains live until CreateBuffer succeeds, so `new_bytes` is
/// charged in full in addition to all retained and pending storage.
pub fn rowVBPhysicalGrowthFits(
    process_retained_bytes: usize,
    process_reserved_bytes: usize,
    surface_retained_bytes: usize,
    new_bytes: usize,
    surface_limit_bytes: usize,
    process_limit_bytes: usize,
) bool {
    const surface_peak = std.math.add(usize, surface_retained_bytes, new_bytes) catch return false;
    const process_with_reservations = std.math.add(
        usize,
        process_retained_bytes,
        process_reserved_bytes,
    ) catch return false;
    const process_peak = std.math.add(usize, process_with_reservations, new_bytes) catch return false;
    return surface_peak <= surface_limit_bytes and process_peak <= process_limit_bytes;
}

pub const RowVBPhysicalBudget = struct {
    retained_bytes: usize = 0,
    reserved_bytes: usize = 0,

    pub const Reservation = struct {
        old_bytes: usize,
        new_bytes: usize,
        active: bool = true,
    };

    pub fn reserveGrowth(
        self: *RowVBPhysicalBudget,
        surface_retained_bytes: usize,
        old_bytes: usize,
        new_bytes: usize,
    ) !Reservation {
        if (!rowVBPhysicalGrowthFits(
            self.retained_bytes,
            self.reserved_bytes,
            surface_retained_bytes,
            new_bytes,
            row_vb_surface_budget_bytes,
            row_vb_process_budget_bytes,
        )) return error.RowVBPhysicalBudgetExceeded;
        self.reserved_bytes = std.math.add(
            usize,
            self.reserved_bytes,
            new_bytes,
        ) catch return error.RowVBPhysicalBudgetExceeded;
        return .{ .old_bytes = old_bytes, .new_bytes = new_bytes };
    }

    pub fn cancel(self: *RowVBPhysicalBudget, reservation: *Reservation) void {
        if (!reservation.active) return;
        self.reserved_bytes -|= reservation.new_bytes;
        reservation.active = false;
    }

    pub fn commit(
        self: *RowVBPhysicalBudget,
        surface_retained_bytes: *usize,
        reservation: *Reservation,
    ) void {
        if (!reservation.active) return;
        self.reserved_bytes -|= reservation.new_bytes;
        self.retained_bytes -|= reservation.old_bytes;
        surface_retained_bytes.* -|= reservation.old_bytes;
        self.retained_bytes +|= reservation.new_bytes;
        surface_retained_bytes.* +|= reservation.new_bytes;
        reservation.active = false;
    }

    pub fn release(self: *RowVBPhysicalBudget, surface_retained_bytes: *usize, bytes: usize) void {
        self.retained_bytes -|= bytes;
        surface_retained_bytes.* -|= bytes;
    }
};

/// Resource-independent ownership state for the retained scrollbar underlay.
/// D3D resource failures reset the geometry as well as validity so the next
/// paint retries allocation even when the track rectangle is unchanged.
pub const ScrollbarUnderlayState = struct {
    width: u32 = 0,
    height: u32 = 0,
    valid: bool = false,

    pub fn geometryChanged(self: ScrollbarUnderlayState, width: u32, height: u32) bool {
        return self.width != width or self.height != height;
    }

    pub fn captured(self: *ScrollbarUnderlayState, width: u32, height: u32) void {
        self.width = width;
        self.height = height;
        self.valid = true;
    }

    pub fn restored(self: *ScrollbarUnderlayState) void {
        self.valid = false;
    }

    pub fn resourceFailed(self: *ScrollbarUnderlayState) void {
        self.* = .{};
    }
};

pub fn retryEpochPending(failure_epoch: u64, success_epoch: u64) bool {
    return failure_epoch > success_epoch;
}

pub fn retryEpochWasCovered(armed_failure_epoch: u64, success_epoch: u64) bool {
    return armed_failure_epoch != 0 and armed_failure_epoch <= success_epoch;
}

pub fn retryEpochNeedsArm(failure_epoch: u64, success_epoch: u64, consumed_failure_epoch: u64) bool {
    return failure_epoch > success_epoch and failure_epoch > consumed_failure_epoch;
}

/// Lifetime pins for Win32 operations whose underlying API may pump messages.
/// Keeping the predicate platform-independent makes it testable without a
/// live D3D device while App remains the owner of the concrete flags.
pub const ActiveOperationFlags = struct {
    paint: bool = false,
    shader_present: bool = false,
    glow_prepare: bool = false,
    device_recovery: bool = false,
    external_create: bool = false,
    main_resize: bool = false,
    main_dpi_change: bool = false,
    deferred_service: bool = false,

    pub fn any(self: ActiveOperationFlags) bool {
        return self.paint or
            self.shader_present or
            self.glow_prepare or
            self.device_recovery or
            self.external_create or
            self.main_resize or
            self.main_dpi_change or
            self.deferred_service;
    }
};

/// One-shot exponential backoff for WM_PAINT failures. `fail` suppresses
/// duplicate scheduling until the armed wake fires. A successful paint resets
/// the backoff but preserves the monotonic generation used to reject stale
/// timer-queue callbacks.
pub const PaintRetryState = struct {
    pub const Ticket = struct {
        delay_ms: u32,
        generation: u32,
    };

    consecutive_failures: u8 = 0,
    timer_armed: bool = false,
    fallback_wake_issued: bool = false,
    generation: u32 = 0,

    pub const base_delay_ms: u32 = 16;
    pub const max_delay_ms: u32 = 2000;

    pub fn fail(self: *PaintRetryState) ?Ticket {
        if (self.timer_armed) return null;
        const shift: u5 = @intCast(@min(self.consecutive_failures, 7));
        const delay = @min(max_delay_ms, base_delay_ms << shift);
        self.consecutive_failures +|= 1;
        self.generation +%= 1;
        if (self.generation == 0) self.generation = 1;
        self.timer_armed = true;
        return .{ .delay_ms = delay, .generation = self.generation };
    }

    pub fn timerFired(self: *PaintRetryState, generation: u32) bool {
        if (!self.timer_armed or self.generation != generation) return false;
        self.timer_armed = false;
        self.fallback_wake_issued = false;
        return true;
    }

    /// Any WM_PAINT is a valid wake for the currently armed generation. This
    /// also releases the state when a timer-queue worker could only invalidate
    /// the HWND after its private-message delivery attempts failed.
    pub fn paintStarted(self: *PaintRetryState) void {
        _ = self.timerFired(self.generation);
    }

    /// Returns whether a delayed wake had still been pending.
    pub fn succeeded(self: *PaintRetryState) bool {
        const was_armed = self.timer_armed;
        self.consecutive_failures = 0;
        self.timer_armed = false;
        self.fallback_wake_issued = false;
        return was_armed;
    }

    /// Returns true for the first failure after the delayed timer mechanism
    /// was exhausted. The caller issues one immediate fallback invalidation;
    /// subsequent total timer failures stay pending until a natural paint
    /// event instead of recreating an unbounded WM_PAINT loop.
    pub fn timerArmFailed(self: *PaintRetryState, generation: u32) bool {
        if (!self.timer_armed or self.generation != generation) return false;
        self.timer_armed = false;
        if (self.fallback_wake_issued) return false;
        self.fallback_wake_issued = true;
        return true;
    }

    /// Dirty state accumulated during paint normally needs an immediate
    /// InvalidateRect. A failed paint with an armed retry wake must defer it,
    /// or releaseFromPaint defeats the backoff. If timer-queue creation failed,
    /// timerArmFailed makes this return true so the invalidation is the
    /// guaranteed one-shot fallback wake. Once that fallback was issued, the
    /// release path must not issue another invalidation for the same failure
    /// generation or permanent timer exhaustion would spin WM_PAINT.
    pub fn shouldInvalidateAfterRelease(self: *const PaintRetryState, needs_reinvalidate: bool) bool {
        return needs_reinvalidate and !self.timer_armed and !self.fallback_wake_issued;
    }
};

pub const atlas_full_upload_rect_threshold: usize = 64;
pub const atlas_full_upload_area_divisor: u64 = 4;

/// Decide when a per-consumer dirty-rect replay should collapse to one full
/// atlas upload. Rect may be any type with left/top/right/bottom integer fields.
pub fn shouldUseFullAtlasUpload(rects: anytype, atlas_w: u32, atlas_h: u32) bool {
    if (rects.len >= atlas_full_upload_rect_threshold) return true;
    const atlas_area = @as(u64, atlas_w) * @as(u64, atlas_h);
    if (atlas_area == 0) return false;

    var dirty_area: u64 = 0;
    for (rects) |r| {
        const w = r.right -| r.left;
        const h = r.bottom -| r.top;
        dirty_area +|= @as(u64, w) * @as(u64, h);
        if (dirty_area >= @max(1, atlas_area / atlas_full_upload_area_divisor)) return true;
    }
    return false;
}

/// Persistent allocation storage for the production three-set sparse row-map
/// publication protocol. A failed grow may leave individual allocations with
/// larger capacities, but isReady() remains false until every member can cover
/// row_count. Callers must check readiness before mutating row mappings.
pub const SparseRowSyncStorage = struct {
    pub const set_count = 3;

    flush_dirty: std.DynamicBitSetUnmanaged = .{},
    flush_dirty_rows: std.ArrayListUnmanaged(u32) = .empty,
    flush_mapping_dirty: std.DynamicBitSetUnmanaged = .{},
    flush_mapping_rows: std.ArrayListUnmanaged(u32) = .empty,
    row_sync_stale: [set_count]std.DynamicBitSetUnmanaged = .{ .{}, .{}, .{} },
    row_sync_rows: [set_count]std.ArrayListUnmanaged(u32) = .{ .empty, .empty, .empty },
    row_sync_full: [set_count]bool = .{ false, false, false },
    prepared_rows: usize = 0,

    /// Grow every list and bitset used to record a row before a scroll mutates
    /// retained surface or row-map state. Existing allocations are retained so
    /// a later retry can complete a partially successful grow.
    pub fn prepare(
        self: *SparseRowSyncStorage,
        alloc: std.mem.Allocator,
        row_count: usize,
    ) std.mem.Allocator.Error!void {
        // flush_dirty represents the current logical grid and is consumed by
        // paint, so keep its length exact. The sparse carry-forward bitsets
        // below remain grow-only because they may still describe spare sets
        // from the previous, larger committed layout.
        if (self.isReady(row_count)) return;

        const previous_prepared_rows = self.prepared_rows;
        self.prepared_rows = 0;
        errdefer self.invalidateAll();

        const old_flush_dirty_rows = self.flush_dirty.bit_length;
        if (old_flush_dirty_rows != row_count) {
            try self.flush_dirty.resize(alloc, row_count, false);
            if (row_count < old_flush_dirty_rows) {
                self.retainFlushDirtyRowsBelow(row_count);
            }
        }
        try self.flush_dirty_rows.ensureTotalCapacity(alloc, row_count);
        try self.flush_mapping_rows.ensureTotalCapacity(alloc, row_count);
        if (self.flush_mapping_dirty.bit_length < row_count) {
            try self.flush_mapping_dirty.resize(alloc, row_count, false);
        }
        for (0..set_count) |i| {
            try self.row_sync_rows[i].ensureTotalCapacity(alloc, row_count);
            if (self.row_sync_stale[i].bit_length < row_count) {
                try self.row_sync_stale[i].resize(alloc, row_count, false);
            }
        }
        self.prepared_rows = @max(previous_prepared_rows, row_count);
    }

    /// True only when all storage required by a row_count-sized mutation is
    /// ready. Sparse carry-forward bitsets may remain larger after a grid
    /// shrinks; the flush-local dirty bitset must match the current grid.
    pub fn isReady(self: *const SparseRowSyncStorage, row_count: usize) bool {
        if (self.prepared_rows < row_count or
            self.flush_dirty.bit_length != row_count or
            self.flush_dirty_rows.items.len > row_count or
            self.flush_dirty_rows.capacity < row_count or
            self.flush_mapping_dirty.bit_length < row_count or
            self.flush_mapping_rows.capacity < row_count)
        {
            return false;
        }
        for (0..set_count) |i| {
            if (self.row_sync_stale[i].bit_length < row_count or
                self.row_sync_rows[i].capacity < row_count)
            {
                return false;
            }
        }
        return true;
    }

    /// Register a flush-local visual row after prepare(). No allocation is
    /// permitted here because scroll callers use this after mutating retained
    /// row mappings and surfaces.
    pub fn markFlushDirtyRow(self: *SparseRowSyncStorage, row: usize) bool {
        const row_count = self.flush_dirty.bit_length;
        if (row >= row_count or !self.isReady(row_count)) return false;
        if (!self.flush_dirty.isSet(row)) {
            if (self.flush_dirty_rows.items.len == self.flush_dirty_rows.capacity) return false;
            self.flush_dirty_rows.appendAssumeCapacity(@intCast(row));
            self.flush_dirty.set(row);
        }
        return true;
    }

    /// Register a flush-local row-map change after prepare().
    pub fn markFlushMappingRow(self: *SparseRowSyncStorage, row: usize) bool {
        const row_count = self.flush_dirty.bit_length;
        if (row >= row_count or !self.isReady(row_count)) return false;
        if (!self.flush_mapping_dirty.isSet(row)) {
            if (self.flush_mapping_rows.items.len == self.flush_mapping_rows.capacity) return false;
            self.flush_mapping_rows.appendAssumeCapacity(@intCast(row));
            self.flush_mapping_dirty.set(row);
        }
        return true;
    }

    pub fn clearFlushDirty(self: *SparseRowSyncStorage) void {
        clearSparseRows(&self.flush_dirty, &self.flush_dirty_rows);
    }

    pub fn clearFlushMapping(self: *SparseRowSyncStorage) void {
        clearSparseRows(&self.flush_mapping_dirty, &self.flush_mapping_rows);
    }

    pub fn clearSetStale(self: *SparseRowSyncStorage, set_index: usize) void {
        std.debug.assert(set_index < set_count);
        clearSparseRows(&self.row_sync_stale[set_index], &self.row_sync_rows[set_index]);
    }

    /// Discard all sparse indices after an allocation failure. The retained
    /// capacities are intentionally preserved for a subsequent retry.
    pub fn invalidateAll(self: *SparseRowSyncStorage) void {
        self.prepared_rows = 0;
        self.flush_dirty_rows.clearRetainingCapacity();
        if (self.flush_dirty.bit_length > 0) self.flush_dirty.unsetAll();
        self.flush_mapping_rows.clearRetainingCapacity();
        if (self.flush_mapping_dirty.bit_length > 0) self.flush_mapping_dirty.unsetAll();
        for (0..set_count) |i| {
            self.row_sync_full[i] = true;
            self.row_sync_rows[i].clearRetainingCapacity();
            if (self.row_sync_stale[i].bit_length > 0) self.row_sync_stale[i].unsetAll();
        }
    }

    pub fn deinit(self: *SparseRowSyncStorage, alloc: std.mem.Allocator) void {
        self.flush_dirty.deinit(alloc);
        self.flush_dirty_rows.deinit(alloc);
        self.flush_mapping_dirty.deinit(alloc);
        self.flush_mapping_rows.deinit(alloc);
        for (0..set_count) |i| {
            self.row_sync_stale[i].deinit(alloc);
            self.row_sync_rows[i].deinit(alloc);
        }
        self.* = .{};
    }

    fn clearSparseRows(
        bits: *std.DynamicBitSetUnmanaged,
        rows: *std.ArrayListUnmanaged(u32),
    ) void {
        for (rows.items) |row| {
            if (row < bits.bit_length) bits.unset(row);
        }
        rows.clearRetainingCapacity();
    }

    fn retainFlushDirtyRowsBelow(self: *SparseRowSyncStorage, row_count: usize) void {
        var write_index: usize = 0;
        for (self.flush_dirty_rows.items) |row| {
            if (row >= row_count) continue;
            self.flush_dirty_rows.items[write_index] = row;
            write_index += 1;
        }
        self.flush_dirty_rows.items.len = write_index;
    }
};

/// Allocation-free reference model for the three-set sparse row-map
/// publication protocol. Production stores the same state in dynamic bitsets
/// and persistent row lists; this compact model lets host tests exercise the
/// rotation/reader/barrier invariants without importing Win32 types.
pub fn SparseRowSyncModel(comptime row_count: usize) type {
    return struct {
        const Self = @This();
        const Set = std.StaticBitSet(row_count);

        committed: u8 = 0,
        maps: [3][row_count]u16 = [_][row_count]u16{[_]u16{0} ** row_count} ** 3,
        stale: [3]Set = .{ Set.initEmpty(), Set.initEmpty(), Set.initEmpty() },
        full: [3]bool = .{ false, false, false },
        reader: [3]bool = .{ false, false, false },

        pub fn begin(self: *Self) ?u8 {
            var best: ?u8 = null;
            var best_cost: usize = std.math.maxInt(usize);
            for (0..3) |i| {
                if (i == self.committed or self.reader[i]) continue;
                const cost = if (self.full[i]) std.math.maxInt(usize) else self.stale[i].count();
                if (best == null or cost < best_cost) {
                    best = @intCast(i);
                    best_cost = cost;
                }
            }
            const write = best orelse return null;
            self.catchUp(write);
            return write;
        }

        pub fn commit(self: *Self, write: u8, changed_rows: []const usize, barrier: bool) void {
            self.stale[write] = Set.initEmpty();
            self.full[write] = false;
            for (0..3) |i| {
                if (i == write) continue;
                if (barrier) {
                    self.full[i] = true;
                    self.stale[i] = Set.initEmpty();
                } else if (!self.full[i]) {
                    for (changed_rows) |row| self.stale[i].set(row);
                }
                if (!self.reader[i]) self.copyChanged(@intCast(i), write);
            }
            self.committed = write;
        }

        pub fn abort(self: *Self, write: u8) void {
            self.full[write] = true;
            self.stale[write] = Set.initEmpty();
        }

        fn catchUp(self: *Self, dst: u8) void {
            self.copyChanged(dst, self.committed);
        }

        fn copyChanged(self: *Self, dst: u8, src: u8) void {
            if (self.full[dst]) {
                self.maps[dst] = self.maps[src];
            } else {
                var it = self.stale[dst].iterator(.{});
                while (it.next()) |row| self.maps[dst][row] = self.maps[src][row];
            }
            self.stale[dst] = Set.initEmpty();
            self.full[dst] = false;
        }
    };
}

pub const AtlasResetAdmission = enum {
    acquired,
    busy,
    shutting_down,
};

/// Close atlas-paint admission only when no paint is already inside the
/// reader transaction. A busy reader must never make the core callback wait:
/// the caller aborts the flush and retries after the UI thread leaves Present.
pub fn tryBeginAtlasReset(
    reset_active: *std.atomic.Value(bool),
    paint_active: *std.atomic.Value(bool),
    shutting_down: *std.atomic.Value(bool),
) AtlasResetAdmission {
    if (shutting_down.load(.acquire)) return .shutting_down;

    // These two flags implement a Dekker-style admission handshake with
    // tryBeginAtlasPaint. They must share the seq_cst total order: ordinary
    // release/acquire on different atomics permits both sides to read the old
    // false value and enter simultaneously on weakly ordered CPUs.
    reset_active.store(true, .seq_cst);
    if (paint_active.load(.seq_cst)) {
        reset_active.store(false, .seq_cst);
        return .busy;
    }

    // Teardown may start after the first check. Do not let a late core
    // callback leave paint admission closed after shutdown has begun.
    if (shutting_down.load(.acquire)) {
        reset_active.store(false, .seq_cst);
        return .shutting_down;
    }
    return .acquired;
}

/// Acquire the UI paint side of the atlas admission handshake. The second
/// reset check closes the race where reset admission starts after the first
/// check but before the paint flag is published.
pub fn tryBeginAtlasPaint(
    reset_active: *std.atomic.Value(bool),
    paint_active: *std.atomic.Value(bool),
) bool {
    if (reset_active.load(.seq_cst)) return false;
    if (paint_active.cmpxchgStrong(false, true, .seq_cst, .seq_cst) != null) return false;
    if (reset_active.load(.seq_cst)) {
        paint_active.store(false, .seq_cst);
        return false;
    }
    return true;
}

pub fn endAtlasPaint(paint_active: *std.atomic.Value(bool)) void {
    paint_active.store(false, .seq_cst);
}

/// Merge a sorted, deduplicated row list with the contiguous range
/// [start, end). The result is written into persistent caller-owned scratch
/// and swapped into `rows`, so steady-state paints allocate nothing.
///
/// On allocation failure `rows` is left unchanged. Paint callers must then
/// skip publishing the partially-updated back buffer and request a full retry.
pub fn mergeSortedRowsWithRange(
    alloc: std.mem.Allocator,
    rows: *std.ArrayListUnmanaged(u32),
    scratch: *std.ArrayListUnmanaged(u32),
    start: u32,
    end: u32,
) bool {
    if (start >= end) return true;

    // Count the exact union first. Reserving rows.len + range.len needlessly
    // doubles capacity when the range is already present (the normal scroll
    // case: vacated rows were marked dirty by the core).
    var union_len: usize = 0;
    var row_i: usize = 0;
    var range_row = start;
    while (row_i < rows.items.len and range_row < end) {
        const existing = rows.items[row_i];
        if (existing < range_row) {
            row_i += 1;
        } else if (existing > range_row) {
            range_row += 1;
        } else {
            row_i += 1;
            range_row += 1;
        }
        union_len += 1;
    }
    union_len += rows.items.len - row_i;
    union_len += @as(usize, end - range_row);

    scratch.clearRetainingCapacity();
    scratch.ensureTotalCapacity(alloc, union_len) catch return false;

    row_i = 0;
    range_row = start;
    while (row_i < rows.items.len and range_row < end) {
        const existing = rows.items[row_i];
        if (existing < range_row) {
            scratch.appendAssumeCapacity(existing);
            row_i += 1;
        } else if (existing > range_row) {
            scratch.appendAssumeCapacity(range_row);
            range_row += 1;
        } else {
            scratch.appendAssumeCapacity(existing);
            row_i += 1;
            range_row += 1;
        }
    }
    scratch.appendSliceAssumeCapacity(rows.items[row_i..]);
    while (range_row < end) : (range_row += 1) {
        scratch.appendAssumeCapacity(range_row);
    }

    std.mem.swap(std.ArrayListUnmanaged(u32), rows, scratch);
    scratch.clearRetainingCapacity();
    return true;
}

/// Insert one row into a sorted, deduplicated list. The list is unchanged on
/// allocation failure so the caller can abort the partial paint transaction.
pub fn insertSortedRow(
    alloc: std.mem.Allocator,
    rows: *std.ArrayListUnmanaged(u32),
    row: u32,
) bool {
    for (rows.items) |existing| {
        if (existing == row) return true;
    }
    rows.append(alloc, row) catch return false;
    std.sort.insertion(u32, rows.items, {}, std.sort.asc(u32));
    return true;
}

/// Return the in-bounds logical rows that must be redrawn when replacing a
/// cursor overlay. The old row erases the previously presented cursor; the
/// new row restores content before the replacement overlay is drawn.
pub fn cursorDirtyRows(
    old_row: ?u32,
    new_row: ?u32,
    row_count: usize,
    storage: *[2]usize,
) []const usize {
    var len: usize = 0;
    if (old_row) |row| {
        const index: usize = @intCast(row);
        if (index < row_count) {
            storage[len] = index;
            len += 1;
        }
    }
    if (new_row) |row| {
        const index: usize = @intCast(row);
        if (index < row_count and (len == 0 or storage[0] != index)) {
            storage[len] = index;
            len += 1;
        }
    }
    return storage[0..len];
}

/// Decide whether a just-freed row slot's vertex backing should be released
/// rather than kept for reuse. `layout_peak_verts` is the largest row payload
/// the current layout has produced, or 0 before it has produced one, in which
/// case the backing is always retained — there is nothing to judge it against
/// yet, and guessing would retire backing the layout is about to ask for.
///
/// The 2x threshold mirrors maybeShrinkRowStorage. Because the floor is a
/// measurement of this layout rather than a per-cell estimate, a row denser
/// than any constant would predict still sits under its own threshold and
/// keeps its backing, so rotating slots through release never churns.
pub fn shouldRetireSlotBacking(capacity: usize, layout_peak_verts: usize) bool {
    if (layout_peak_verts == 0) return false;
    return capacity > layout_peak_verts * 2;
}

/// Sort rectangles in place, then merge overlapping or edge-adjacent entries.
/// The merge may enlarge damage to a bounding rectangle, but never drops
/// damaged pixels. This keeps the paint path allocation-free and O(n log n).
pub fn compactDamageRects(comptime Rect: type, rects: []Rect) usize {
    if (rects.len < 2) return rects.len;

    std.sort.pdq(Rect, rects, {}, struct {
        fn lessThan(_: void, a: Rect, b: Rect) bool {
            if (a.top != b.top) return a.top < b.top;
            if (a.left != b.left) return a.left < b.left;
            if (a.bottom != b.bottom) return a.bottom > b.bottom;
            return a.right > b.right;
        }
    }.lessThan);

    var out_len: usize = 0;
    var merged = rects[0];
    for (rects[1..]) |rect| {
        const overlaps_or_touches =
            rect.left <= merged.right and rect.right >= merged.left and
            rect.top <= merged.bottom and rect.bottom >= merged.top;
        if (overlaps_or_touches) {
            merged.left = @min(merged.left, rect.left);
            merged.top = @min(merged.top, rect.top);
            merged.right = @max(merged.right, rect.right);
            merged.bottom = @max(merged.bottom, rect.bottom);
        } else {
            rects[out_len] = merged;
            out_len += 1;
            merged = rect;
        }
    }
    rects[out_len] = merged;
    return out_len + 1;
}

/// Invert DWrite's cluster map into the core's shaping-callback contract.
///
/// DWrite gives `cluster_map[text_pos] = first glyph index for that position`.
/// `include/zonvie_core.h` requires the opposite direction, and specifically
/// the FIRST source scalar of the cluster that produced each glyph (HarfBuzz
/// convention, which the macOS bridge forwards directly).
///
/// Text positions sharing a `cluster_map` value form one cluster, and glyph
/// `gi` belongs to the last cluster whose first glyph index is <= `gi`.
pub fn invertClusterMap(
    cluster_map: []const u16,
    utf16_to_scalar_idx: []const u32,
    glyph_count: usize,
    out_clusters: []u32,
) void {
    if (cluster_map.len == 0) return;
    const utf16_len = cluster_map.len;
    var char_ptr: usize = 0;
    var gi: usize = 0;
    while (gi < glyph_count and gi < out_clusters.len) : (gi += 1) {
        while (char_ptr + 1 < utf16_len and cluster_map[char_ptr + 1] <= @as(u16, @intCast(gi))) {
            char_ptr += 1;
        }
        // char_ptr is the LAST position of the covering cluster. Walk back to
        // its first: for a many-to-one cluster the two differ, and naming the
        // last scalar both shifts placement by the cluster's width and hands
        // the by-scalar fallback the wrong character.
        var first = char_ptr;
        while (first > 0 and cluster_map[first - 1] == cluster_map[char_ptr]) first -= 1;
        out_clusters[gi] = utf16_to_scalar_idx[first];
    }
}
