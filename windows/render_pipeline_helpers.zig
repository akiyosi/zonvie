const std = @import("std");
const core = @import("zonvie_core");

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

/// Copy-button grid-text reads per click while the core's try-lock is busy
/// (macOS copyDecoratedGridContent: attemptsLeft 5, 20 ms apart).
pub const copy_text_max_attempts: u8 = 5;
pub const copy_text_retry_interval_ms: u32 = 20;

/// Consume the attempt that just hit a busy lock. True: arm another read
/// copy_text_retry_interval_ms later. False: give up (the click is dropped).
pub fn copyTextRetryAfterBusy(attempts_left: *u8) bool {
    if (attempts_left.* <= 1) {
        attempts_left.* = 0;
        return false;
    }
    attempts_left.* -= 1;
    return true;
}

/// OpenClipboard attempts for a `\"+y`/`\"+p` or the copy button: the OS
/// clipboard is briefly held open by another process (clipboard managers,
/// rdpclip) far more often than our own internal locks contend. Retried
/// synchronously on the UI thread via Sleep, off any render path.
pub const clipboard_open_max_attempts: u8 = 5;
pub const clipboard_open_retry_interval_ms: u32 = 10;

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

/// Drop the queued atlas upload rects before `consumed_seq`, the cursor of a
/// consumer that has uploaded them. `base_seq` is the sequence of `list[0]`;
/// the head (`base_seq + list.len`) is unchanged, and capacity is kept so the
/// queue stops allocating once it reaches its working size. A cursor past the
/// head would mean rects were uploaded that were never queued.
pub fn releaseConsumedAtlasUploads(comptime T: type, list: *std.ArrayListUnmanaged(T), base_seq: *u64, consumed_seq: u64) void {
    std.debug.assert(consumed_seq <= base_seq.* + list.items.len);
    if (consumed_seq <= base_seq.*) return;
    const n: usize = @intCast(@min(consumed_seq - base_seq.*, list.items.len));
    std.mem.copyForwards(T, list.items[0 .. list.items.len - n], list.items[n..]);
    list.shrinkRetainingCapacity(list.items.len - n);
    base_seq.* += n;
}

/// Where the frontend places the grid an on_vertices_row callback names.
pub const RowGridRoute = enum { main_root, main_layer, external_root, external_layer, unplaced };

/// Whether a cursor-only update (CURSOR set, MAIN clear) is the main surface's
/// cursor: grid 1's, or a grid the main surface places as a layer. Any other
/// grid's cursor goes to the external path.
pub fn mainSurfaceTakesCursor(grid_id: i64, route: RowGridRoute) bool {
    if (grid_id == 1) return true;
    return switch (route) {
        .main_root, .main_layer => true,
        .external_root, .external_layer, .unplaced => false,
    };
}

/// zonvie_core.h: "clearing a different grid must not clear the current
/// owner's cursor". An empty cursor set from a grid that does not own the
/// surface's one cursor is ignored.
pub fn ignoresCursorClear(vert_count: usize, owner_grid_id: i64, grid_id: i64) bool {
    return vert_count == 0 and owner_grid_id != grid_id;
}

pub const ExternalRowInputs = struct {
    /// VERT_UPDATE_MAIN.
    main: bool,
    /// VERT_UPDATE_CURSOR.
    cursor: bool,
    route: RowGridRoute,
    /// A live, non-closing window can take the update now (no pending
    /// capture of this grid exists). Unused for a layer row.
    live_window: bool,
};

pub const ExternalRowDisposition = enum {
    /// Neither MAIN nor CURSOR: existing row contents are retained.
    retain_rows,
    /// Stored in the layer of the surface that places the grid.
    layer_row,
    live_cursor,
    live_row,
    /// Captured for a window that does not exist yet (or replaces a closing one).
    pending_cursor,
    pending_row,
};

/// Disposition of an on_vertices_row callback for a grid other than 1 that the
/// main surface's cursor path did not take. Cursor updates never become layer
/// rows: rows and cursor are independent layers, and only MAIN replaces a row.
pub fn externalRowDisposition(in: ExternalRowInputs) ExternalRowDisposition {
    if (!in.main and !in.cursor) return .retain_rows;
    if (!in.cursor) switch (in.route) {
        .main_root, .main_layer, .external_layer => return .layer_row,
        .external_root, .unplaced => {},
    };
    if (in.live_window) return if (in.cursor) .live_cursor else .live_row;
    return if (in.cursor) .pending_cursor else .pending_row;
}

pub const MainRowInputs = struct {
    /// VERT_UPDATE_MAIN.
    main: bool,
    row_start: u32,
    row_count: u32,
    vert_count: usize,
    total_rows: u32,
    total_cols: u32,
};

pub const MainRowDisposition = enum {
    /// MAIN clear: existing row contents are retained.
    retain_rows,
    /// The zero-cell transition: no row content survives.
    layout_only,
    /// A row the authoritative total_rows does not contain.
    out_of_range,
    single_row,
    /// No per-row vertex boundaries: keep rows and re-seed.
    multi_row,
    /// No row payload; only the layout is applied.
    no_row,
};

/// Disposition of a grid-1 on_vertices_row callback (after the cursor-only
/// route), from the zonvie_core.h on_vertices_row contract.
pub fn mainRowDisposition(in: MainRowInputs) MainRowDisposition {
    if (!in.main) return .retain_rows;
    if (in.row_count == 0 and in.vert_count == 0 and (in.total_rows == 0 or in.total_cols == 0)) return .layout_only;
    if (in.total_rows != 0 and in.row_start >= in.total_rows) return .out_of_range;
    return switch (in.row_count) {
        0 => .no_row,
        1 => .single_row,
        else => .multi_row,
    };
}

/// Damage not yet copied from a persistent back buffer into each rotating
/// swapchain buffer. A buffer is either `full` or holds `count` rects, no two
/// of which overlap or touch; overflowing `max_rects` promotes it to full.
/// Fixed storage: queueing never allocates.
pub fn BackDamageQueue(comptime Rect: type, comptime buffers: usize, comptime max_rects: usize) type {
    comptime std.debug.assert(max_rects <= std.math.maxInt(u8));
    return struct {
        const Self = @This();
        const Coord = @FieldType(Rect, "left");

        full: [buffers]bool = [_]bool{true} ** buffers,
        count: [buffers]u8 = [_]u8{0} ** buffers,
        rects: [buffers][max_rects]Rect = undefined,

        /// Mark the first `n` buffers (at most `buffers`) for a full copy.
        pub fn markFull(self: *Self, n: usize) void {
            for (0..@min(n, buffers)) |i| {
                self.full[i] = true;
                self.count[i] = 0;
            }
        }

        /// `rect` clipped to [0,width)x[0,height), or null when empty.
        pub fn clampRect(rect: Rect, width: u32, height: u32) ?Rect {
            var r = rect;
            r.left = @max(0, r.left);
            r.top = @max(0, r.top);
            r.right = @min(@as(Coord, @intCast(width)), r.right);
            r.bottom = @min(@as(Coord, @intCast(height)), r.bottom);
            return if (r.right > r.left and r.bottom > r.top) r else null;
        }

        fn append(self: *Self, index: usize, rect: Rect) void {
            if (self.full[index]) return;

            var merged = rect;
            var count: usize = self.count[index];
            var i: usize = 0;
            while (i < count) {
                const old = self.rects[index][i];
                if (merged.left <= old.right and merged.right >= old.left and
                    merged.top <= old.bottom and merged.bottom >= old.top)
                {
                    merged = .{
                        .left = @min(old.left, merged.left),
                        .top = @min(old.top, merged.top),
                        .right = @max(old.right, merged.right),
                        .bottom = @max(old.bottom, merged.bottom),
                    };
                    count -= 1;
                    self.rects[index][i] = self.rects[index][count];
                    // The grown rect may now touch one already passed.
                    i = 0;
                    continue;
                }
                i += 1;
            }

            if (count == max_rects) {
                self.full[index] = true;
                self.count[index] = 0;
                return;
            }
            self.rects[index][count] = merged;
            self.count[index] = @intCast(count + 1);
        }

        /// Queue a present's damage on the first `buffer_count` buffers. A rect
        /// that clamps to nothing makes every one of them full.
        pub fn queue(self: *Self, rects: []const Rect, full: bool, buffer_count: usize, width: u32, height: u32) void {
            if (full) return self.markFull(buffer_count);
            for (rects) |raw| {
                const rect = clampRect(raw, width, height) orelse return self.markFull(buffer_count);
                for (0..@min(buffer_count, buffers)) |i| self.append(i, rect);
            }
        }

        pub fn pending(self: *const Self, index: usize) []const Rect {
            return self.rects[index][0..self.count[index]];
        }

        /// Buffer `index` now matches the back buffer.
        pub fn clear(self: *Self, index: usize) void {
            self.full[index] = false;
            self.count[index] = 0;
        }
    };
}

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

/// Which atlas generation a surface's texture last received in full. The
/// atlas bumps its generation (under its own `mu`) on every reset and on every
/// upload it could not queue, so a surface owes a full upload exactly when the
/// generation moved since its last one. The main driver kept a flag set from
/// three threads instead and the external driver compared with `<`, which
/// wraps: `!=` is the answer both give now. `null` owes a full upload
/// unconditionally — a surface that has never uploaded, a failed upload, a
/// fresh device.
pub const AtlasUploadLedger = struct {
    uploaded_generation: ?u64 = null,

    pub fn needsFull(self: AtlasUploadLedger, current_generation: u64) bool {
        return self.uploaded_generation != current_generation;
    }

    pub fn fullUploaded(self: *AtlasUploadLedger, generation: u64) void {
        self.uploaded_generation = generation;
    }

    pub fn forceFull(self: *AtlasUploadLedger) void {
        self.uploaded_generation = null;
    }
};

/// A paint that uploaded glyphs but redrew no root row leaves those glyphs
/// invisible until an unrelated repaint: rows drawn before the upload sampled
/// an atlas region that was still empty. Such a paint asks for a full one.
/// The two drivers asked this differently — main of its root rows, the
/// external driver of whether anything at all was presented, which missed a
/// frame whose only damage was a layer.
pub fn atlasUploadOwesFullPaint(atlas_uploaded: bool, drew_root_rows: bool) bool {
    return atlas_uploaded and !drew_root_rows;
}

/// Claim the two root rows a cursor move touches — where the previous cursor
/// was baked into the back texture and where this one lands — so they are
/// repainted from the root's own vertices, which is what removes the previous
/// cursor. Only for a cursor on the root: a layer's cursor rows are that
/// grid's, and its layer repaints whole. Rows past `row_limit` are skipped.
/// Both drivers collected the same pair.
pub fn insertCursorEraseRows(
    alloc: std.mem.Allocator,
    rows: *std.ArrayListUnmanaged(u32),
    erase_rows: [2]?u32,
    row_limit: u32,
    cursor_on_root: bool,
) void {
    if (!cursor_on_root) return;
    for (erase_rows) |maybe_row| {
        const r = maybe_row orelse continue;
        if (r >= row_limit) continue;
        _ = insertSortedRow(alloc, rows, r);
    }
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

/// Where a window's SURFACE begins inside its client area -- grid 1's cell
/// (0,0). Only the main window draws chrome inside its own client rect, so the
/// offset is zero for every other window, which is why an external window can
/// hand client pixels to a layer test unchanged and the main window cannot.
///
/// Pure and host-testable because getting it wrong is silent: a hit test that
/// applies it twice, or not at all, moves every click by a fixed number of
/// cells and nothing fails until someone notices the cursor landing in the
/// wrong place. Both callers in `input.zig` fill this from `App`.
pub const SurfaceOriginInputs = struct {
    is_main_window: bool,
    ext_tabline_enabled: bool = false,
    style_is_sidebar: bool = false,
    style_is_titlebar: bool = false,
    sidebar_on_right: bool = false,
    /// Already DPI-scaled.
    sidebar_width_px: i32 = 0,
    /// Already DPI-scaled.
    tab_bar_height_px: i32 = 0,
};

pub const SurfaceOrigin = struct { x: i32 = 0, y: i32 = 0 };

pub fn surfaceOriginPx(in: SurfaceOriginInputs) SurfaceOrigin {
    if (!in.is_main_window) return .{};
    return .{
        // A sidebar on the RIGHT takes no leading columns, so it shifts
        // nothing: the surface still starts at the client origin.
        .x = if (in.ext_tabline_enabled and in.style_is_sidebar and !in.sidebar_on_right)
            in.sidebar_width_px
        else
            0,
        .y = if (in.ext_tabline_enabled and in.style_is_titlebar)
            in.tab_bar_height_px
        else
            0,
    };
}

/// Width of the content viewport drawEx binds at x_offset. `base_w` is a right
/// edge measured from x=0 (the client width, less an "always" scrollbar).
pub fn contentViewportWidthPx(base_w: u32, x_offset: u32, sidebar_right_w: u32) u32 {
    return if (base_w > x_offset + sidebar_right_w) base_w - x_offset - sidebar_right_w else 1;
}

/// drawEx's scissor for a content viewport at (x, y) of size w x h: `dirty`
/// (viewport-relative) translated to render-target space and clamped to the
/// viewport's right/bottom edges and the target's origin, or the whole viewport.
pub fn contentScissor(comptime Rect: type, x: u32, y: u32, w: u32, h: u32, dirty: ?Rect) Rect {
    const Coord = @FieldType(Rect, "left");
    const x_i: Coord = @intCast(x);
    const y_i: Coord = @intCast(y);
    const right: Coord = @intCast(x + w);
    const bottom: Coord = @intCast(y + h);
    return if (dirty) |r| .{
        .left = @max(0, x_i + r.left),
        .top = @max(0, y_i + r.top),
        .right = @min(x_i + r.right, right),
        .bottom = @min(y_i + r.bottom, bottom),
    } else .{ .left = x_i, .top = y_i, .right = right, .bottom = bottom };
}

/// Right edge of the main paint's row scissors: the viewport's right edge.
pub fn mainContentRightPx(content_width: ?u32, client_w: u32, x_offset: u32, sidebar_right_w: u32) i32 {
    return @intCast(x_offset + contentViewportWidthPx(content_width orelse client_w, x_offset, sidebar_right_w));
}

pub const MainWindowSnap = struct {
    outer_w: i32,
    outer_h: i32,
    snapped_content_w: u32,
    snapped_content_h: u32,
};

/// The main window's new outer size for WM_APP_SNAP_MAIN_WINDOW: snap the
/// *desired* content size (0 falls back to the live `content_w`/`content_h`,
/// i.e. before the first WM_SIZE) to a cell multiple, then apply the chrome
/// delta already present between `outer_w`/`outer_h` and the live content.
/// Snapping the desired size rather than the live content is what lets the
/// window grow back after it shrank on a font-size change (see the caller in
/// windows/window.zig). Returns null when there is nothing to do: a
/// degenerate cell size, a content area smaller than one cell, or the window
/// already holding the snapped size.
pub fn snapMainWindowOuterSize(
    outer_w: i32,
    outer_h: i32,
    content_w: u32,
    content_h: u32,
    desired_content_w: u32,
    desired_content_h: u32,
    cell_w: u32,
    cell_h: u32,
) ?MainWindowSnap {
    if (cell_w == 0 or cell_h == 0) return null;
    if (content_w < cell_w or content_h < cell_h) return null;

    const base_w: u32 = if (desired_content_w != 0) desired_content_w else content_w;
    const base_h: u32 = if (desired_content_h != 0) desired_content_h else content_h;

    const snapped_w = core.zonvie_core_snap_terminal_px(base_w, cell_w);
    const snapped_h = core.zonvie_core_snap_terminal_px(base_h, cell_h);
    if (snapped_w == 0 or snapped_h == 0) return null;
    if (snapped_w == content_w and snapped_h == content_h) return null;

    const delta_w: i32 = @as(i32, @intCast(content_w)) - @as(i32, @intCast(snapped_w));
    const delta_h: i32 = @as(i32, @intCast(content_h)) - @as(i32, @intCast(snapped_h));
    return .{
        .outer_w = outer_w - delta_w,
        .outer_h = outer_h - delta_h,
        .snapped_content_w = snapped_w,
        .snapped_content_h = snapped_h,
    };
}

pub const PaintPolicyInputs = struct {
    /// The surface's own "repaint everything" request.
    force_full: bool,
    cursor_grid_changed: bool,
    glow_enabled: bool,
    opacity: f32,
    /// Whether `back_tex` still holds a usable previous frame. The main driver
    /// tracks this per app; an external window has no equivalent yet and
    /// passes true, which is what its previous `!force_full_rows` meant.
    back_tex_valid: bool,
};

pub const PaintPolicy = struct {
    force_full_rows: bool,
    preserve_back: bool,
};

/// The cursor vertices a frame draws: all of them while the blink phase shows
/// the cursor, none while it hides it. The main driver's flat path answered
/// this inline and the decorated external path did not ask, so an ext-cmdline
/// cursor never blinked.
pub fn cursorVertsForFrame(comptime V: type, cursor: []const V, blink_visible: bool) []const V {
    return if (blink_visible) cursor else &.{};
}

pub fn paintPolicy(in: PaintPolicyInputs) PaintPolicy {
    const force_full_rows =
        in.force_full or
        in.cursor_grid_changed or
        in.glow_enabled or
        (in.opacity < 1.0);
    return .{
        .force_full_rows = force_full_rows,
        // Keeping the previous frame is only safe when nothing forces a full
        // redraw AND that frame is still there. A frame this returns false for
        // redraws every row anyway, so clearing costs nothing it needs.
        .preserve_back = !force_full_rows and in.back_tex_valid,
    };
}

/// The main driver's seed state. Only the main surface has one (the core seeds
/// grid 1 alone), so an external window passes none.
pub const SeedPresentFacts = struct {
    pending: bool,
    clear: bool,
    back_tex_valid: bool,
    rows_mismatch: bool,
    row_valid_count: usize,
};

pub const PresentGateInputs = struct {
    /// The row layout this paint snapshotted is still current.
    layout_ok: bool = true,
    /// The committed set's metrics generation is still current.
    metrics_ok: bool = true,
    /// Rows, layers or the cursor overlay never reached back_tex.
    frame_incomplete: bool = false,
    force_full_rows: bool,
    preserve_back: bool,
    rows: usize,
    rows_to_draw: usize,
    skipped_empty: u32,
    custom_shader: bool = false,
    present_rects: usize,
    present_rects_overflowed: bool = false,
    seed: ?SeedPresentFacts = null,
    /// Main's chrome is redrawn from hover state that yields no damage rect,
    /// so an empty damage list there still presents the whole surface.
    empty_damage_presents_all: bool = false,
};

pub const PresentVerdict = enum {
    /// Must not present; the caller's failure path requeues a full paint.
    refuse,
    /// Nothing changed on screen; not a failure.
    skip,
    present,
};

pub const PresentGate = struct {
    verdict: PresentVerdict,
    /// Mark every rotating swapchain buffer damaged.
    full: bool,
    /// back_tex after a successful present.
    back_tex_valid: bool,
};

/// Whether and how a paint presents, for both paint drivers. The seed and
/// row-count rules are the main surface's; with no seed this is the external
/// driver's gate.
pub fn presentGate(in: PresentGateInputs) PresentGate {
    const full = in.force_full_rows or
        in.present_rects_overflowed or
        in.custom_shader or
        if (in.seed) |s| s.clear or (s.pending and !s.back_tex_valid and !s.rows_mismatch) else false;
    const rendered_complete_frame = in.rows != 0 and
        in.skipped_empty == 0 and
        in.rows_to_draw == in.rows;
    const back_tex_valid = if (in.seed) |s|
        (s.back_tex_valid and in.preserve_back) or rendered_complete_frame
    else
        true;
    const verdict: PresentVerdict = if (!in.layout_ok or !in.metrics_ok or in.frame_incomplete)
        .refuse
    else if (in.seed) |s|
        (if (seedAllowsPresent(in, s)) .present else .refuse)
    else if (!full and in.present_rects == 0 and !in.empty_damage_presents_all)
        .skip
    else
        .present;
    return .{ .verdict = verdict, .full = full, .back_tex_valid = back_tex_valid };
}

fn seedAllowsPresent(in: PresentGateInputs, s: SeedPresentFacts) bool {
    // A cleared back buffer must reach every swapchain buffer, or the gutter
    // keeps stale pixels.
    if (s.clear) return true;
    if (s.pending and !in.preserve_back) return true;
    // Never present until the core has provided a stable row count.
    if (in.rows == 0) return false;
    const drew_every_row = in.skipped_empty == 0 and in.rows_to_draw == in.rows;
    if (s.pending) {
        if (s.rows_mismatch) return in.rows_to_draw != 0 and in.skipped_empty == 0;
        // A valid back_tex sources the rows not yet re-validated.
        if (s.back_tex_valid) return true;
        // No back_tex yet: the first present must cover every row.
        return s.row_valid_count == in.rows and drew_every_row;
    }
    return !in.force_full_rows or drew_every_row;
}

/// Where `grid_id`'s layer sits in its surface, in surface pixels: zero for
/// the surface's root, the layer's origin for a grid it hosts, zero when the
/// grid is not placed there. The cursor overlay, its damage rect and the IME
/// all place against this; they carried five copies of the loop with two
/// different keys.
pub fn layerOriginPx(comptime Layer: type, layers: []const Layer, grid_id: i64, root_grid_id: i64) [2]i32 {
    if (grid_id == root_grid_id) return .{ 0, 0 };
    for (layers) |l| {
        if (l.grid_id == grid_id) return .{ l.x_px, l.y_px };
    }
    return .{ 0, 0 };
}

/// Where one non-root layer sits for its present damage, in client pixels.
pub const LayerPresentGeom = struct {
    left_px: i32,
    top_px: i32,
    width_px: i32,
    row_h_px: i32,
    /// The layout's row count: the extent of a whole-layer rect.
    rows: u32,
    /// Rows the layer draw visits (stored rows within the layout).
    row_limit: usize,
    clip_right: i32,
    clip_bottom: i32,
};

/// Append the present damage of the rows a layer's plan draws: the whole
/// layer for `draw_all`, else one rect per run of `draw_rows` and
/// `cursor_rows`, plus the GPU copy's rect. Every rect is clipped to the
/// client; empty ones are dropped.
pub fn appendLayerDrawRects(
    comptime Rect: type,
    alloc: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(Rect),
    geom: LayerPresentGeom,
    draw_all: bool,
    draw_rows: *const std.DynamicBitSetUnmanaged,
    cursor_rows: [2]?u32,
    blit: ?BlitRectPx,
) error{OutOfMemory}!void {
    const l: i32 = @max(0, geom.left_px);
    const right: i32 = @min(geom.clip_right, l + geom.width_px);
    if (draw_all) {
        const t: i32 = @max(0, geom.top_px);
        const b: i32 = @min(geom.clip_bottom, t + @as(i32, @intCast(geom.rows)) * geom.row_h_px);
        try appendClipped(Rect, alloc, out, .{ .left = l, .top = t, .right = right, .bottom = b });
        return;
    }
    var run_start: ?usize = null;
    var r: usize = 0;
    while (r <= geom.row_limit) : (r += 1) {
        const marked = r < geom.row_limit and
            ((r < draw_rows.bit_length and draw_rows.isSet(r)) or
                std.mem.indexOfScalar(?u32, &cursor_rows, @intCast(r)) != null);
        if (marked) {
            if (run_start == null) run_start = r;
            continue;
        }
        const s = run_start orelse continue;
        run_start = null;
        const band_top = geom.top_px + @as(i32, @intCast(s)) * geom.row_h_px;
        const band_bottom = geom.top_px + @as(i32, @intCast(r)) * geom.row_h_px;
        try appendClipped(Rect, alloc, out, .{
            .left = l,
            .top = @max(0, band_top),
            .right = right,
            .bottom = @min(geom.clip_bottom, band_bottom),
        });
    }
    if (blit) |br| try appendClipped(Rect, alloc, out, .{
        .left = @max(0, br.left),
        .top = @max(0, br.top),
        .right = @min(geom.clip_right, br.right),
        .bottom = @min(geom.clip_bottom, br.bottom),
    });
}

fn appendClipped(comptime Rect: type, alloc: std.mem.Allocator, out: *std.ArrayListUnmanaged(Rect), rc: Rect) error{OutOfMemory}!void {
    if (rc.right <= rc.left or rc.bottom <= rc.top) return;
    try out.append(alloc, rc);
}

/// The scissor of the cursor overlay's row: the cursor's row across its own
/// layer, or across the content when the cursor is on the root
/// (`layer_w_px` null). The blink-off erase clears the whole scissor, so a
/// wider one wipes a vertical-split neighbour's row.
pub fn cursorRowScissor(
    comptime Rect: type,
    x_offset: i32,
    y_offset: i32,
    content_right: i32,
    layer_x_px: i32,
    layer_y_px: i32,
    layer_w_px: ?i32,
    row: u32,
    row_h_px: i32,
) Rect {
    const top = y_offset + layer_y_px + @as(i32, @intCast(row)) * row_h_px;
    const w = layer_w_px orelse return .{ .left = x_offset, .top = top, .right = content_right, .bottom = top + row_h_px };
    return .{
        .left = @max(x_offset, x_offset + layer_x_px),
        .top = top,
        .right = @min(content_right, x_offset + layer_x_px + w),
        .bottom = top + row_h_px,
    };
}

/// The grid whose Neovim window a move INTO the main window lands on: the
/// top-left split the main window still shows. Grid 2 is only that window
/// until it is externalized. Same rule as macOS `mainWindowTargetWinId`.
pub fn mainMoveTargetGrid(comptime Grid: type, grids: []const Grid) i64 {
    var best: ?Grid = null;
    for (grids) |g| {
        if (g.grid_id <= 1 or g.zindex > 0 or g.placed_by_surface != 1) continue;
        if (best) |b| {
            if (g.start_row > b.start_row or (g.start_row == b.start_row and g.start_col >= b.start_col)) continue;
        }
        best = g;
    }
    return if (best) |b| b.grid_id else 2;
}

/// One full-width rect per run of adjacent dirty rows, written into `out` and
/// counted. `rows` is sorted and deduplicated, so there are never more runs
/// than rows: a caller that reserved `rows.len` slots cannot run short, which
/// is what lets both paint drivers share this without a fallible append.
pub fn rowSpanRects(
    comptime Rect: type,
    rows: []const u32,
    y_offset: i32,
    right: i32,
    row_h: i32,
    out: []Rect,
) usize {
    if (rows.len == 0) return 0;
    std.debug.assert(out.len >= rows.len);
    var n: usize = 0;
    var start = rows[0];
    var end = start + 1;
    for (rows[1..]) |r| {
        if (r == end) {
            end += 1;
            continue;
        }
        out[n] = spanRect(Rect, start, end, y_offset, right, row_h);
        n += 1;
        start = r;
        end = r + 1;
    }
    out[n] = spanRect(Rect, start, end, y_offset, right, row_h);
    return n + 1;
}

fn spanRect(comptime Rect: type, start: u32, end: u32, y_offset: i32, right: i32, row_h: i32) Rect {
    return .{
        .left = 0,
        .top = y_offset + @as(i32, @intCast(start)) * row_h,
        .right = right,
        .bottom = y_offset + @as(i32, @intCast(end)) * row_h,
    };
}

/// Clamp present rectangles to the render target and drop the ones that clamp
/// away to nothing, returning the surviving length.
///
/// Both paint drivers build their present list from grid rows, cursor damage
/// and chrome bands, any of which can extend past the target after a resize
/// the other side has not seen yet. Order is not preserved: an emptied slot is
/// filled from the end, which is what keeps this a single pass.
pub fn clampPresentRects(comptime Rect: type, rects: []Rect, max_right: i32, max_bottom: i32) usize {
    var len = rects.len;
    var i: usize = 0;
    while (i < len) {
        var r = rects[i];
        if (r.left < 0) r.left = 0;
        if (r.top < 0) r.top = 0;
        if (r.right > max_right) r.right = max_right;
        if (r.bottom > max_bottom) r.bottom = max_bottom;
        if (r.right <= r.left or r.bottom <= r.top) {
            rects[i] = rects[len - 1];
            len -= 1;
            continue;
        }
        rects[i] = r;
        i += 1;
    }
    return len;
}

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

/// Length of the next shaping chunk of `scalars`, at most `max_len`. A run
/// that does not fit is cut just after its last space inside the limit, so
/// no ligature or cluster spans the cut; with no space it is cut at the limit.
pub fn shapeChunkLen(scalars: []const u32, max_len: usize) usize {
    if (scalars.len <= max_len) return scalars.len;
    var i = max_len;
    while (i > 0) : (i -= 1) {
        if (scalars[i - 1] == ' ') return i;
    }
    return max_len;
}

/// The row-scroll blit arithmetic lives in the core now
/// (`src/core/row_scroll.zig`), so both frontends get the same answer to the
/// same geometry. Aliased under the name the paint code already uses.
pub const RowScrollBlitPlan = core.row_scroll.Plan;

/// Every pixel the blit rewrites: the copy plus the band it vacated. The
/// z-aware float scroll mask compares against it; the core computes it inside
/// `overBlitRows` for the same reason.
pub const BlitRectPx = core.row_scroll.Rect;

/// Half-open on all four edges, so rectangles that only touch do not
/// intersect: a layer abutting an accepted blit shares none of its pixels.
pub fn blitRectsIntersect(a: BlitRectPx, b: BlitRectPx) bool {
    return a.left < b.right and b.left < a.right and a.top < b.bottom and b.top < a.bottom;
}

/// The ROOT rows a layer's pixels can occupy after the root's own scroll copy
/// moved them, as a half-open [from, to) clamped to `surface_rows`.
///
/// The copy shifts every pixel of its region, the layer composited into it
/// included, but the root only redraws the band the scroll vacated — so the
/// rows the layer was dragged onto keep a strip of it that nothing else owns.
/// Those rows have to be repainted from the root.
///
/// The span reaches `shift_rows` in BOTH directions instead of following the
/// sign of the shift. It costs one extra band height, and a sign taken the
/// wrong way would leave exactly the ghost this exists to remove.
///
/// Null when the layer has no rows or nothing of the span is on the surface.
pub fn rootRowsLayerScrollReached(
    origin_y_px: i32,
    layer_rows: u32,
    shift_rows: u32,
    row_h_px: i32,
    surface_rows: u32,
) ?[2]u32 {
    if (row_h_px <= 0 or layer_rows == 0 or surface_rows == 0) return null;
    const h: i64 = row_h_px;
    const band_top: i64 = @divFloor(@as(i64, origin_y_px), h);
    const band_bottom: i64 = band_top + @as(i64, layer_rows);
    const reach: i64 = @as(i64, shift_rows);
    const from: i64 = @max(0, band_top - reach);
    const to: i64 = @min(@as(i64, surface_rows), band_bottom + reach);
    if (to <= from) return null;
    return .{ @intCast(from), @intCast(to) };
}

/// One layer grid's pending row scroll, accumulated across a flush.
pub const LayerScroll = struct {
    row_start: u32,
    row_end: u32,
    rows_delta: i32,
    total_rows: u32,
    total_cols: u32,

    /// This driver does not track the columns a shift covers, so the whole
    /// grid width is what the core is told. `mergeStaged` compares rows only,
    /// which is what every caller of it decides on.
    fn toStaged(self: LayerScroll) core.row_scroll.Staged {
        return .{
            .row_start = @intCast(self.row_start),
            .row_end = @intCast(self.row_end),
            .col_start = 0,
            .col_end = @intCast(self.total_cols),
            .rows_delta = self.rows_delta,
            .total_rows = @intCast(self.total_rows),
            .total_cols = @intCast(self.total_cols),
        };
    }

    fn fromStaged(s: core.row_scroll.Staged) LayerScroll {
        return .{
            .row_start = @intCast(@max(0, s.row_start)),
            .row_end = @intCast(@max(0, s.row_end)),
            .rows_delta = s.rows_delta,
            .total_rows = @intCast(@max(0, s.total_rows)),
            .total_cols = @intCast(@max(0, s.total_cols)),
        };
    }
};

pub const LayerScrollMerge = union(enum) {
    accumulate: LayerScroll,
    /// Two different regions in one flush. This driver blits neither and hands
    /// both back for the caller to dirty.
    ///
    /// The core's rule keeps the incoming one as a valid blit and returns only
    /// the displaced region — see `row_scroll.mergeStaged`, which names all
    /// three answers that were found asking this. The arithmetic below is the
    /// core's; only this policy is the driver's, and it stays until hardware
    /// can say whether the cheaper answer holds here.
    conflict: struct { old: LayerScroll, new: LayerScroll },
};

pub fn mergeLayerScroll(existing: ?LayerScroll, incoming: LayerScroll) LayerScrollMerge {
    const staged_existing: ?core.row_scroll.Staged =
        if (existing) |e| e.toStaged() else null;
    const merged = core.row_scroll.mergeStaged(staged_existing, incoming.toStaged());
    if (merged.superseded) |old| {
        return .{ .conflict = .{ .old = LayerScroll.fromStaged(old), .new = incoming } };
    }
    // `superseded` is also null for a displaced region that was empty, which
    // moved nothing and so owes no repaint — the core drops it and this driver
    // has nothing to dirty either.
    return .{ .accumulate = LayerScroll.fromStaged(merged.staged) };
}

/// Bound a scroll-delta accumulator well below the integer extremes, which
/// later abs() calls would trap on. The core's, so the two frontends clamp
/// identically.
pub const clampRowsDelta = core.row_scroll.clampRowsDelta;

fn swapRowBits(bits: *std.DynamicBitSetUnmanaged, a: usize, b: usize) void {
    const av = bits.isSet(a);
    const bv = bits.isSet(b);
    if (av == bv) return;
    bits.setValue(a, bv);
    bits.setValue(b, av);
}

/// Carry a row bitset through a scroll region's shift, so a bit recorded
/// before the shift still names the row its vertices ended up on. The swap
/// chain mirrors the one that moves the row storage: `rows_delta > 0` means
/// content moves up, so what was bit `r + shift` becomes bit `r`.
///
/// The vacated band is set, not cleared: those rows lost their vertices and
/// have to be repainted whatever the caller does next. A caller that also
/// marks the band (Windows `mergeShift`) then only repeats itself.
pub fn shiftRowBits(
    bits: *std.DynamicBitSetUnmanaged,
    row_start: u32,
    row_end: u32,
    rows_delta: i32,
) void {
    if (checkShift(row_start, row_end, rows_delta, bits.bit_length) != .fits) return;
    const shift: u32 = @intCast(@abs(rows_delta));

    if (rows_delta > 0) {
        var r: u32 = row_start;
        while (r + shift < row_end) : (r += 1) swapRowBits(bits, r, r + shift);
        bits.setRangeValue(.{ .start = row_end - shift, .end = row_end }, true);
    } else {
        var r: u32 = row_end;
        while (r > row_start + shift) {
            r -= 1;
            swapRowBits(bits, r, r - shift);
        }
        bits.setRangeValue(.{ .start = row_start, .end = row_start + shift }, true);
    }
}

pub const RowBand = struct { start: usize, end: usize };

pub const ShiftCheck = enum { noop, fits, invalid };

/// Classify a row shift of `[row_start, row_end)` by `rows_delta` over storage
/// of `len` rows: nothing to move, a shift that leaves surviving rows, or one
/// that overruns the storage or covers the whole region.
pub fn checkShift(row_start: u32, row_end: u32, rows_delta: i32, len: usize) ShiftCheck {
    if (rows_delta == 0 or row_end <= row_start) return .noop;
    if (row_end > len or @abs(rows_delta) >= row_end - row_start) return .invalid;
    return .fits;
}

/// Move the surviving entries of a scroll region `items[row_start..row_end]`
/// by `rows_delta` (`> 0`: content moves up, as on_grid_row_scroll) and
/// return the vacated band, which now holds the entries scrolled off: a
/// rotation never drops or duplicates one, so each caller resets the band its
/// own way and keeps whatever it owns. A shift covering the region vacates
/// all of it and moves nothing.
pub fn rotateRegion(comptime T: type, items: []T, row_start: usize, row_end: usize, rows_delta: i32) RowBand {
    std.debug.assert(row_start <= row_end and row_end <= items.len);
    const region = items[row_start..row_end];
    const shift: usize = @abs(rows_delta);
    if (shift >= region.len) return .{ .start = row_start, .end = row_end };
    if (rows_delta > 0) {
        std.mem.rotate(T, region, shift);
        return .{ .start = row_end - shift, .end = row_end };
    }
    std.mem.rotate(T, region, region.len - shift);
    return .{ .start = row_start, .end = row_start + shift };
}

pub const copyUtf8Truncated = core.frontend_rules.copyUtf8Truncated;
pub const mini_max_lines = core.frontend_rules.mini_max_lines;
pub const clampMiniContent = core.frontend_rules.clampMiniContent;

pub const utf8TruncLen = core.frontend_rules.utf8PrefixLen;

/// The longest valid UTF-8 prefix of `s` that converts to at most
/// `max_utf16` UTF-16 units. utf8ToUtf16Le rejects invalid input and does not
/// bound its destination.
pub fn utf8ValidPrefix(s: []const u8, max_utf16: usize) []const u8 {
    var i: usize = 0;
    var units: usize = 0;
    while (i < s.len) {
        const n = std.unicode.utf8ByteSequenceLength(s[i]) catch break;
        if (n > s.len - i) break;
        _ = std.unicode.utf8Decode(s[i..][0..n]) catch break;
        const w: usize = if (n == 4) 2 else 1;
        if (units + w > max_utf16) break;
        units += w;
        i += n;
    }
    return s[0..i];
}

/// Where one KEY=VALUE line of wide text starts its key and its value. Both
/// are NUL-terminated in the buffer by the call.
pub const EnvAssignment = struct { key: usize, value: usize };

/// The next KEY=VALUE line of `buf[0..len]` at or after `pos.*`, cut in place:
/// the line is trimmed of spaces, tabs and CRs, its first '=' and the unit
/// after the value become NULs, so neither side has a length limit. A line
/// with no '=' or an empty key is skipped. `buf` needs one unit past `len`.
pub fn nextEnvAssignment(buf: []u16, len: usize, pos: *usize) ?EnvAssignment {
    std.debug.assert(len < buf.len);
    const blank = [_]u16{ ' ', '\t', '\r' };
    while (pos.* < len) {
        const end = std.mem.indexOfScalarPos(u16, buf[0..len], pos.*, '\n') orelse len;
        var start = pos.*;
        var stop = end;
        pos.* = end + 1;
        while (start < stop and std.mem.indexOfScalar(u16, &blank, buf[start]) != null) start += 1;
        while (stop > start and std.mem.indexOfScalar(u16, &blank, buf[stop - 1]) != null) stop -= 1;
        const eq = std.mem.indexOfScalarPos(u16, buf[0..stop], start, '=') orelse continue;
        if (eq == start) continue;
        buf[eq] = 0;
        buf[stop] = 0;
        return .{ .key = start, .value = eq + 1 };
    }
    return null;
}
