// flush.zig — Flush pipeline, ext_* UI notification subsystems.
// Extracted from nvim_core.zig. Free functions take *Core as first parameter.

const std = @import("std");
const clock = @import("clock.zig");
const c_api = @import("c_api.zig");
const grid_mod = @import("grid.zig");
const highlight = @import("highlight.zig");
const Highlights = highlight.Highlights;
const ResolvedAttrWithStyles = highlight.ResolvedAttrWithStyles;
const redraw = @import("redraw_handler.zig");
const config = @import("config.zig");
const msg_view = @import("msg_view.zig");
const rpc = @import("rpc_encode.zig");
const Logger = @import("log.zig").Logger;
const nvim_core = @import("nvim_core.zig");
const Core = nvim_core.Core;
const vertexgen = @import("vertexgen.zig");
const block_elements = @import("block_elements.zig");
const shelf_packer = @import("shelf_packer.zig");

// Emoji cluster context: set before ensureGlyphPhase2 so the frontend
// emoji_cluster_buf / emoji_cluster_len are now per-instance fields on Core
// (nvim_core.zig) so that the public ABI zonvie_core_get_emoji_cluster() is
// instance-safe. Accessed via core.emoji_cluster_buf / core.emoji_cluster_len.

/// Key for float overlay overflow map during ext grid composition.
pub const FloatOverlayKey = packed struct { row: u32, col: u32 };

/// Float overlay overflow map for ext grid composition.
/// Maps (row, col) → optional extras. null extras means "float occupies this cell
/// but has no overflow" (shadows the base grid's overflow).
/// Using a HashMap gives O(1) lookup and last-write-wins when multiple floats
/// overlap the same cell (matching row-cell overlay semantics).
pub const FloatOverlayMap = std.AutoHashMapUnmanaged(FloatOverlayKey, ?[]const u32);

pub const GridEntry = struct {
    grid_id: i64,
    zindex: i64,
    compindex: i64,
    order: u64,
};

pub const ExternalFloatAnchorEntry = struct {
    anchor_grid_id: i64,
    entry: GridEntry,

    fn lessThan(_: void, a: ExternalFloatAnchorEntry, b: ExternalFloatAnchorEntry) bool {
        if (a.anchor_grid_id != b.anchor_grid_id) return a.anchor_grid_id < b.anchor_grid_id;
        if (a.entry.zindex != b.entry.zindex) return a.entry.zindex < b.entry.zindex;
        if (a.entry.compindex != b.entry.compindex) return a.entry.compindex < b.entry.compindex;
        if (a.entry.order != b.entry.order) return a.entry.order < b.entry.order;
        return a.entry.grid_id < b.entry.grid_id;
    }
};

// Pre-computed subgrid info for row-mode compose optimization.
// Caches win_pos/sub_grids lookups to avoid per-row hash map access.
/// Lightweight snapshot of a composited subgrid's identity and row range.
/// Stored across flushes to detect layout changes (move/add/remove) that
/// invalidate cached row vertices inside the scroll region.
pub const SubgridSnapshot = struct {
    grid_id: i64,
    row_start: u32,
    row_end: u32,
    col_start: u32,
    sg_cols: u32,
    margin_top: u32,
    margin_bottom: u32,
    margin_left: u32,
    margin_right: u32,

    fn lessThanGridId(_: void, a: SubgridSnapshot, b: SubgridSnapshot) bool {
        return a.grid_id < b.grid_id;
    }
};

pub const CachedSubgrid = struct {
    grid_id: i64,
    row_start: u32, // pos.row
    row_end: u32, // pos.row + sg.rows (exclusive)
    col_start: u32, // pos.col
    sg_cols: u32,
    sg_rows: u32,
    cells: [*]const grid_mod.Cell, // pointer to subgrid cells
    margin_top: u32, // viewport margin rows at top (not scrollable)
    margin_bottom: u32, // viewport margin rows at bottom (not scrollable)
    margin_left: u32 = 0, // viewport margin columns at left (not scrollable)
    margin_right: u32 = 0, // viewport margin columns at right (not scrollable)
};

pub const MainSubgridRowLayout = struct {
    grid_id: i64,
    row_start: u32,
    row_end: u32,
};

// Keep the persistent materialized row index bounded. Layouts whose total
// row coverage exceeds this limit are rejected: falling back to scanning all
// subgrids for every dirty row makes CPU time unbounded under grid_mu.
const MAX_MAIN_SUBGRID_ROW_INDEX_BYTES: usize = grid_mod.MAX_MAIN_SUBGRID_ROW_INDEX_BYTES;
const MAX_VERTEX_BYTES_PER_SURFACE: usize = 256 * 1024 * 1024;
const MAX_VERTEX_BYTES_AGGREGATE: usize = 512 * 1024 * 1024;
// A row callback maps to one frontend MTLBuffer on macOS. Keep the core's
// callback payload limit aligned with that consumer, then bound retained
// logical surface and process-wide output independently. Counts are charged
// from generated output, not from a per-cell estimate: blank grids remain
// cheap while overflow clusters are accounted at their actual glyph count.
//
// These are deliberately generous rather than tight budgets: exceeding any of
// them sets flush_retryable = false, which routes through failHardRender to
// requestChildTermination() and kills the nvim child with its unsaved
// buffers. Normal content stays in the low single-digit MB range even under
// extreme display setups; the ceiling only guards pathological per-cell
// decoration counts (heavily stacked combining characters).
//
// These bound the CORE's own accounting only. They are matched against the
// frontends' single-buffer ceilings (surfaceMaxVertexBufferCapacity in
// macos/Sources/Rendering/MetalTypes.swift, max_buffer_bytes in
// windows/renderer/d3d11_renderer.zig, both 256 MiB) so that a row the core
// accepts is never rejected by a frontend purely on per-buffer size.
//
// That is NOT a claim that a row the core accepts always allocates. Each
// frontend also has an AGGREGATE physical budget that binds first and is
// legitimately lower: Windows row_vb_surface_budget_bytes (256 MiB, checked as
// retained + new in windows/render_pipeline_helpers.zig), and on macOS
// surfaceMaxProvisionedRowBytes spread over three sets x two private slots,
// which works out near 42 MiB per row. Treat the values here as the
// nvim-killing backstop, not as a promise of frontend capacity.
const MAX_VERTEX_BYTES_PER_CALLBACK: usize = 256 * 1024 * 1024;
const MAX_VERTICES_PER_CALLBACK: usize = MAX_VERTEX_BYTES_PER_CALLBACK / @sizeOf(c_api.Vertex);
const MAX_VERTICES_PER_SURFACE: usize = MAX_VERTEX_BYTES_PER_SURFACE / @sizeOf(c_api.Vertex);
const MAX_VERTICES_AGGREGATE: usize = MAX_VERTEX_BYTES_AGGREGATE / @sizeOf(c_api.Vertex);

fn vertexBudgetExceeded(core: *Core) error{VertexBudgetExceeded} {
    core.flush_retryable = false;
    return error.VertexBudgetExceeded;
}

fn ensureRowVertexCapacity(
    core: *Core,
    out: *std.ArrayListUnmanaged(c_api.Vertex),
    max_vertices: usize,
    additional_vertices: usize,
) !void {
    const needed = std.math.add(usize, out.items.len, additional_vertices) catch
        return vertexBudgetExceeded(core);
    if (needed > max_vertices) return vertexBudgetExceeded(core);
    if (needed <= out.capacity) return;

    // ArrayList's normal geometric growth may retain capacity beyond the
    // callback byte limit. Grow geometrically here, but clamp the precise
    // allocation itself to the remaining fixed budget.
    const geometric = std.math.add(usize, out.capacity, out.capacity / 2 + 8) catch max_vertices;
    const target = @min(max_vertices, @max(needed, geometric));
    try out.ensureTotalCapacityPrecise(core.alloc, target);
}

fn ensureRowQuadCapacity(
    core: *Core,
    out: *std.ArrayListUnmanaged(c_api.Vertex),
    max_vertices: usize,
    quad_count: usize,
) !void {
    const additional = std.math.mul(usize, quad_count, 6) catch
        return vertexBudgetExceeded(core);
    try ensureRowVertexCapacity(core, out, max_vertices, additional);
}

fn syncVertexBudgetAggregate(core: *Core, enforce_limits: bool) !void {
    const aggregate = std.math.add(
        usize,
        core.main_surface_vertex_count,
        core.grid.subgrid_surface_vertex_count,
    ) catch return vertexBudgetExceeded(core);
    if (enforce_limits and
        (core.main_surface_vertex_count > MAX_VERTICES_PER_SURFACE or
            aggregate > MAX_VERTICES_AGGREGATE))
    {
        return vertexBudgetExceeded(core);
    }
    core.flush_vertex_count_aggregate = aggregate;
}

fn beginVertexBudgetTransaction(core: *Core) !void {
    if (core.vertex_budget_transaction_active) return vertexBudgetExceeded(core);
    try syncVertexBudgetAggregate(core, true);
    core.vertex_budget_main_touched = false;
    core.vertex_budget_touched_grid_head = null;
    core.vertex_budget_transaction_active = true;
}

fn validateCompletedVertexBudget(core: *Core) !void {
    try syncVertexBudgetAggregate(core, true);
    if (core.vertex_budget_main_touched and
        core.main_surface_vertex_count > MAX_VERTICES_PER_SURFACE)
    {
        return vertexBudgetExceeded(core);
    }
    var grid_id = core.vertex_budget_touched_grid_head;
    while (grid_id) |current_grid_id| {
        const sg = core.grid.sub_grids.get(current_grid_id) orelse
            return vertexBudgetExceeded(core);
        if (sg.surface_vertex_count > MAX_VERTICES_PER_SURFACE) {
            return vertexBudgetExceeded(core);
        }
        grid_id = sg.vertex_budget_touched_next;
    }
    if (core.flush_vertex_count_aggregate > MAX_VERTICES_AGGREGATE) {
        return vertexBudgetExceeded(core);
    }
}

fn touchSubgridVertexBudget(core: *Core, grid_id: i64, sg: *grid_mod.GridBuf) void {
    if (sg.vertex_budget_touched) return;
    sg.vertex_budget_touched = true;
    sg.vertex_budget_touched_next = core.vertex_budget_touched_grid_head;
    core.vertex_budget_touched_grid_head = grid_id;
}

fn clearTouchedVertexBudgetSurfaces(core: *Core) void {
    core.vertex_budget_main_touched = false;
    var grid_id = core.vertex_budget_touched_grid_head;
    while (grid_id) |current_grid_id| {
        const sg = core.grid.sub_grids.getPtr(current_grid_id) orelse {
            // Grid mutation is serialized by grid_mu, but make invariant
            // failure cleanup total rather than leaving stale active links.
            var sg_it = core.grid.sub_grids.valueIterator();
            while (sg_it.next()) |remaining| {
                remaining.vertex_budget_touched = false;
                remaining.vertex_budget_touched_next = null;
            }
            core.vertex_budget_touched_grid_head = null;
            return;
        };
        const next = sg.vertex_budget_touched_next;
        sg.vertex_budget_touched = false;
        sg.vertex_budget_touched_next = null;
        grid_id = next;
    }
    core.vertex_budget_touched_grid_head = null;
}

/// Snapshot the main row ledger so a frontend rejection can put the accounting
/// back exactly as the still-committed frame left it. Returns false when the
/// snapshot could not be taken, in which case the caller must fall back to the
/// invalidate-everything recovery.
fn snapshotMainVertexRowLedger(core: *Core) bool {
    core.flush_row_ledger_snapshot_valid = false;
    if (!core.main_vertex_row_ledger_valid) return false;
    const counts = core.main_vertex_row_counts.items;
    core.flush_row_counts_snapshot.ensureTotalCapacity(core.alloc, counts.len) catch return false;
    core.flush_row_counts_snapshot.items.len = counts.len;
    @memcpy(core.flush_row_counts_snapshot.items, counts);
    core.flush_main_vertex_count_snapshot = core.main_surface_vertex_count;
    core.flush_row_ledger_snapshot_valid = true;
    return true;
}

fn restoreMainVertexRowLedger(core: *Core) bool {
    if (!core.flush_row_ledger_snapshot_valid) return false;
    const saved = core.flush_row_counts_snapshot.items;
    if (saved.len != core.main_vertex_row_counts.items.len) return false;
    @memcpy(core.main_vertex_row_counts.items, saved);
    core.main_surface_vertex_count = core.flush_main_vertex_count_snapshot;
    core.main_vertex_row_ledger_valid = true;
    return true;
}

fn finishVertexBudgetTransaction(core: *Core, commit: bool) void {
    finishVertexBudgetTransactionRestoring(core, commit, false);
}

/// `restore_main_ledger` marks the abort as a frontend publication refusal
/// (no free buffer set, atlas back-sync still in flight) rather than damaged
/// state: the committed frame is intact, so the main surface keeps its exact
/// accounting and only the rows this attempt consumed are owed again.
fn finishVertexBudgetTransactionRestoring(core: *Core, commit: bool, restore_main_ledger: bool) void {
    if (!core.vertex_budget_transaction_active) return;
    // scroll_cache mirrors the displayed frame only while publications are
    // being accepted; a refusal leaves it describing a frame that never
    // reached the screen. Atlas reclamation reads it, so it has to know.
    if (commit) core.display_mirror_stale = false;
    clearTouchedVertexBudgetSurfaces(core);
    if (!commit and restore_main_ledger and restoreMainVertexRowLedger(core)) {
        core.display_mirror_stale = true;
        // Sub-grid surfaces keep the conservative recovery: this core holds no
        // vertex mirror of what their frontend surfaces retained.
        var sg_it = core.grid.sub_grids.valueIterator();
        while (sg_it.next()) |sg| {
            sg.surface_vertex_count = 0;
            sg.vertex_row_ledger_valid = false;
            sg.markAllDirty();
        }
        core.grid.subgrid_surface_vertex_count = 0;
        core.force_ext_cursor_recheck = true;
        core.flush_vertex_count_aggregate = core.main_surface_vertex_count;
        core.vertex_budget_transaction_active = false;
        return;
    }
    if (!commit) {
        // Row ledgers are accounting metadata, not rendered content. Mutate
        // them in place on the hot path so a one-row flush does O(1) ledger
        // work and retains no full-size transaction copy. An aborted frontend
        // transaction already forces every surface dirty; invalidate the
        // metadata here so that the forced full retry reconstructs exact
        // counts lazily. No row-sized work is done on a backpressure abort.
        core.main_surface_vertex_count = 0;
        core.main_vertex_row_ledger_valid = false;
        var sg_it = core.grid.sub_grids.valueIterator();
        while (sg_it.next()) |sg| {
            sg.surface_vertex_count = 0;
            sg.vertex_row_ledger_valid = false;
            sg.markAllDirty();
        }
        core.grid.markAllDirty();
        core.grid.subgrid_surface_vertex_count = 0;
        core.force_ext_cursor_recheck = true;
        core.flush_vertex_count_aggregate = 0;
    }
    core.vertex_budget_transaction_active = false;
}

fn prepareMainVertexRowLedgerForWrite(core: *Core) void {
    if (core.main_vertex_row_ledger_valid) return;
    core.flush_vertex_count_aggregate -|= core.main_surface_vertex_count;
    @memset(core.main_vertex_row_counts.items, 0);
    core.main_surface_vertex_count = 0;
    core.main_vertex_row_ledger_valid = true;
}

fn prepareSubgridVertexRowLedgerForWrite(core: *Core, sg: *grid_mod.GridBuf) void {
    if (sg.vertex_row_ledger_valid) return;
    core.flush_vertex_count_aggregate -|= sg.surface_vertex_count;
    core.grid.subgrid_surface_vertex_count -|= sg.surface_vertex_count;
    @memset(sg.vertex_row_counts, 0);
    sg.surface_vertex_count = 0;
    sg.vertex_row_ledger_valid = true;
}

fn replaceSurfaceRowVertexCount(
    core: *Core,
    surface_count: *usize,
    row_counts: []usize,
    row: usize,
    new_count: usize,
) !void {
    if (row_counts.len == 0 and new_count == 0) {
        surface_count.* = 0;
        return;
    }
    if (row >= row_counts.len or new_count > MAX_VERTICES_PER_CALLBACK) {
        return vertexBudgetExceeded(core);
    }
    const old_count = row_counts[row];
    const without_old = surface_count.* -| old_count;
    const new_surface = std.math.add(usize, without_old, new_count) catch
        return vertexBudgetExceeded(core);
    const aggregate_without_old = core.flush_vertex_count_aggregate -| old_count;
    const new_aggregate = std.math.add(usize, aggregate_without_old, new_count) catch
        return vertexBudgetExceeded(core);
    row_counts[row] = new_count;
    surface_count.* = new_surface;
    core.flush_vertex_count_aggregate = new_aggregate;
}

fn replaceMainSurfaceRowVertexCount(core: *Core, row: usize, new_count: usize) !void {
    try syncVertexBudgetAggregate(core, false);
    core.vertex_budget_main_touched = true;
    prepareMainVertexRowLedgerForWrite(core);
    try replaceSurfaceRowVertexCount(
        core,
        &core.main_surface_vertex_count,
        core.main_vertex_row_counts.items,
        row,
        new_count,
    );
}

fn replaceSubgridSurfaceRowVertexCount(core: *Core, grid_id: i64, sg: *grid_mod.GridBuf, row: usize, new_count: usize) !void {
    try syncVertexBudgetAggregate(core, false);
    touchSubgridVertexBudget(core, grid_id, sg);
    prepareSubgridVertexRowLedgerForWrite(core, sg);
    const old_surface_count = sg.surface_vertex_count;
    try replaceSurfaceRowVertexCount(
        core,
        &sg.surface_vertex_count,
        sg.vertex_row_counts,
        row,
        new_count,
    );
    core.grid.subgrid_surface_vertex_count -|= old_surface_count;
    core.grid.subgrid_surface_vertex_count = std.math.add(
        usize,
        core.grid.subgrid_surface_vertex_count,
        sg.surface_vertex_count,
    ) catch return vertexBudgetExceeded(core);
}

fn replaceMainFlatVertexCount(core: *Core, new_count: usize) !void {
    if (new_count > MAX_VERTICES_PER_CALLBACK or new_count > MAX_VERTICES_PER_SURFACE) {
        return vertexBudgetExceeded(core);
    }
    try syncVertexBudgetAggregate(core, false);
    core.vertex_budget_main_touched = true;
    const aggregate_without_main = core.flush_vertex_count_aggregate -| core.main_surface_vertex_count;
    const new_aggregate = std.math.add(usize, aggregate_without_main, new_count) catch
        return vertexBudgetExceeded(core);
    core.main_surface_vertex_count = new_count;
    core.flush_vertex_count_aggregate = new_aggregate;
}
// All persistent external-float composition scratch shares one aggregate
// 8 MiB budget. Fixed partitions keep the guarantee local and deterministic:
// no build order or previous high-water capacity can borrow from another
// buffer and push the simultaneous retained total over the cap.
const MAX_EXTERNAL_FLOAT_PERSISTENT_SCRATCH_BYTES: usize = 8 * 1024 * 1024;
const MAX_EXTERNAL_FLOAT_ANCHOR_SCRATCH_BYTES: usize = 3 * 1024 * 1024;
const MAX_EXTERNAL_FLOAT_ENTRY_SCRATCH_BYTES: usize = 2 * 1024 * 1024;
const MAX_EXTERNAL_FLOAT_ROW_INDEX_BYTES: usize = MAX_EXTERNAL_FLOAT_PERSISTENT_SCRATCH_BYTES -
    MAX_EXTERNAL_FLOAT_ANCHOR_SCRATCH_BYTES -
    MAX_EXTERNAL_FLOAT_ENTRY_SCRATCH_BYTES;

comptime {
    std.debug.assert(
        grid_mod.MAX_WINDOW_PLACEMENTS * @sizeOf(ExternalFloatAnchorEntry) <=
            MAX_EXTERNAL_FLOAT_ANCHOR_SCRATCH_BYTES,
    );
    std.debug.assert(
        grid_mod.MAX_WINDOW_PLACEMENTS * @sizeOf(GridEntry) <=
            MAX_EXTERNAL_FLOAT_ENTRY_SCRATCH_BYTES,
    );
}

fn mainSubgridRowIndexStorageByteSize(offsets: usize, write_offsets: usize, refs: usize, layouts: usize) ?usize {
    const usize_count_with_writes = std.math.add(usize, offsets, write_offsets) catch return null;
    const usize_count = std.math.add(usize, usize_count_with_writes, refs) catch return null;
    const usize_bytes = std.math.mul(usize, usize_count, @sizeOf(usize)) catch return null;
    const layout_bytes = std.math.mul(usize, layouts, @sizeOf(MainSubgridRowLayout)) catch return null;
    return std.math.add(usize, usize_bytes, layout_bytes) catch null;
}

fn mainSubgridRowIndexByteSize(rows: usize, refs: usize, layouts: usize) ?usize {
    const offset_count = std.math.add(usize, rows, 1) catch return null;
    return mainSubgridRowIndexStorageByteSize(offset_count, rows, refs, layouts);
}

fn clearMainSubgridRowIndexStorage(core: *Core) void {
    core.main_subgrid_row_offsets.deinit(core.alloc);
    core.main_subgrid_row_offsets = .empty;
    core.main_subgrid_row_write_offsets.deinit(core.alloc);
    core.main_subgrid_row_write_offsets = .empty;
    core.main_subgrid_row_indices.deinit(core.alloc);
    core.main_subgrid_row_indices = .empty;
    core.main_subgrid_row_layout.deinit(core.alloc);
    core.main_subgrid_row_layout = .empty;
    core.main_subgrid_row_index_valid = false;
    core.main_subgrid_row_index_generation = 0;
    core.main_subgrid_row_index_cached_len = 0;
}

fn preflightMainSubgridRowIndex(core: *Core, rows: u32) !void {
    if (core.cb.on_vertices_row == null) return;
    if (core.main_subgrid_row_index_valid and
        core.main_subgrid_row_index_rows == rows and
        core.main_subgrid_row_index_generation == core.grid.layout_generation)
    {
        return;
    }
    const row_count: usize = rows;
    const ref_count = core.grid.main_row_index_ref_count;
    const layout_count = core.grid.main_row_index_layout_count;
    const needed = core.grid.currentMainRowIndexByteSize() orelse {
        core.flush_retryable = false;
        return error.LayoutTooComplex;
    };
    if (needed > MAX_MAIN_SUBGRID_ROW_INDEX_BYTES) {
        core.flush_retryable = false;
        return error.LayoutTooComplex;
    }
    const offset_count = std.math.add(usize, row_count, 1) catch {
        core.flush_retryable = false;
        return error.LayoutTooComplex;
    };
    const retained = mainSubgridRowIndexStorageByteSize(
        @max(core.main_subgrid_row_offsets.capacity, offset_count),
        @max(core.main_subgrid_row_write_offsets.capacity, row_count),
        @max(core.main_subgrid_row_indices.capacity, ref_count),
        @max(core.main_subgrid_row_layout.capacity, layout_count),
    ) orelse {
        core.flush_retryable = false;
        return error.LayoutTooComplex;
    };
    if (retained > MAX_MAIN_SUBGRID_ROW_INDEX_BYTES) {
        // The current layout fits. Drop incompatible high-water allocations
        // from an older layout instead of treating retained capacity as live
        // protocol complexity.
        clearMainSubgridRowIndexStorage(core);
    }
}

/// Build persistent per-row buckets in layer order. An exact layout snapshot
/// lets content-only flushes reuse the buckets, so dirty-row composition is
/// O(G + C) instead of O(D * G + C). Layouts exceeding max_bytes fail rather
/// than falling back to an unbounded dirty-row-by-subgrid scan.
fn ensureMainSubgridRowIndexWithLimit(core: *Core, cached: []const CachedSubgrid, rows: u32, max_bytes: usize) !bool {
    const row_count: usize = rows;
    if (core.main_subgrid_row_index_valid and
        core.main_subgrid_row_index_rows == rows and
        core.main_subgrid_row_layout.items.len <= cached.len)
    {
        if (mainSubgridRowIndexStorageByteSize(
            core.main_subgrid_row_offsets.capacity,
            core.main_subgrid_row_write_offsets.capacity,
            core.main_subgrid_row_indices.capacity,
            core.main_subgrid_row_layout.capacity,
        )) |index_bytes| {
            if (index_bytes <= max_bytes) {
                var matches = true;
                var old_index: usize = 0;
                for (cached) |csg| {
                    const start: usize = @min(@as(usize, csg.row_start), row_count);
                    const end: usize = @min(@as(usize, csg.row_end), row_count);
                    if (csg.sg_cols == 0 or csg.sg_rows == 0 or start >= end) continue;
                    if (old_index >= core.main_subgrid_row_layout.items.len) {
                        matches = false;
                        break;
                    }
                    const old = core.main_subgrid_row_layout.items[old_index];
                    if (csg.grid_id != old.grid_id or csg.row_start != old.row_start or csg.row_end != old.row_end) {
                        matches = false;
                        break;
                    }
                    old_index += 1;
                }
                if (old_index != core.main_subgrid_row_layout.items.len) matches = false;
                if (matches) return true;
            }
        }
    }

    core.main_subgrid_row_index_valid = false;

    var ref_count: usize = 0;
    var layout_count: usize = 0;
    for (cached) |csg| {
        const start: usize = @min(@as(usize, csg.row_start), row_count);
        const end: usize = @min(@as(usize, csg.row_end), row_count);
        if (csg.sg_cols == 0 or csg.sg_rows == 0 or start >= end) continue;
        layout_count += 1;
        const coverage = end - start;
        ref_count = std.math.add(usize, ref_count, coverage) catch return error.LayoutTooComplex;
    }
    const index_bytes = mainSubgridRowIndexByteSize(row_count, ref_count, layout_count) orelse return error.LayoutTooComplex;
    if (index_bytes > max_bytes) return error.LayoutTooComplex;
    const offset_count = std.math.add(usize, row_count, 1) catch return error.LayoutTooComplex;
    const retained_bytes = mainSubgridRowIndexStorageByteSize(
        @max(core.main_subgrid_row_offsets.capacity, offset_count),
        @max(core.main_subgrid_row_write_offsets.capacity, row_count),
        @max(core.main_subgrid_row_indices.capacity, ref_count),
        @max(core.main_subgrid_row_layout.capacity, layout_count),
    ) orelse return error.LayoutTooComplex;
    if (retained_bytes > max_bytes) clearMainSubgridRowIndexStorage(core);

    try core.main_subgrid_row_offsets.ensureTotalCapacityPrecise(core.alloc, offset_count);
    core.main_subgrid_row_offsets.items.len = offset_count;
    @memset(core.main_subgrid_row_offsets.items, 0);

    for (cached) |csg| {
        const start: usize = @min(@as(usize, csg.row_start), row_count);
        const end: usize = @min(@as(usize, csg.row_end), row_count);
        if (csg.sg_cols == 0 or csg.sg_rows == 0 or start >= end) continue;
        for (start..end) |row| core.main_subgrid_row_offsets.items[row + 1] += 1;
    }
    for (1..core.main_subgrid_row_offsets.items.len) |i| {
        core.main_subgrid_row_offsets.items[i] += core.main_subgrid_row_offsets.items[i - 1];
    }

    std.debug.assert(ref_count == core.main_subgrid_row_offsets.items[row_count]);
    try core.main_subgrid_row_indices.ensureTotalCapacityPrecise(core.alloc, ref_count);
    core.main_subgrid_row_indices.items.len = ref_count;
    try core.main_subgrid_row_write_offsets.ensureTotalCapacityPrecise(core.alloc, row_count);
    core.main_subgrid_row_write_offsets.items.len = row_count;
    @memcpy(
        core.main_subgrid_row_write_offsets.items,
        core.main_subgrid_row_offsets.items[0..row_count],
    );

    // cached is already sorted back-to-front, so inserting each entry into
    // every covered row preserves composition order without per-row sorting.
    for (cached, 0..) |csg, csg_index| {
        const start: usize = @min(@as(usize, csg.row_start), row_count);
        const end: usize = @min(@as(usize, csg.row_end), row_count);
        if (csg.sg_cols == 0 or csg.sg_rows == 0 or start >= end) continue;
        for (start..end) |row| {
            const dst = core.main_subgrid_row_write_offsets.items[row];
            core.main_subgrid_row_indices.items[dst] = csg_index;
            core.main_subgrid_row_write_offsets.items[row] = dst + 1;
        }
    }

    try core.main_subgrid_row_layout.ensureTotalCapacityPrecise(core.alloc, layout_count);
    core.main_subgrid_row_layout.items.len = 0;
    for (cached) |csg| {
        const start: usize = @min(@as(usize, csg.row_start), row_count);
        const end: usize = @min(@as(usize, csg.row_end), row_count);
        if (csg.sg_cols == 0 or csg.sg_rows == 0 or start >= end) continue;
        core.main_subgrid_row_layout.appendAssumeCapacity(.{
            .grid_id = csg.grid_id,
            .row_start = csg.row_start,
            .row_end = csg.row_end,
        });
    }
    core.main_subgrid_row_index_rows = rows;
    core.main_subgrid_row_index_cached_len = cached.len;
    core.main_subgrid_row_index_valid = true;
    return true;
}

fn ensureMainSubgridRowIndex(core: *Core, cached: []const CachedSubgrid, rows: u32) !bool {
    if (core.main_subgrid_row_index_valid and
        core.main_subgrid_row_index_rows == rows and
        core.main_subgrid_row_index_cached_len == cached.len and
        core.main_subgrid_row_index_generation == core.grid.layout_generation)
    {
        return true;
    }
    // Deliberate: this also disables the structural fast path inside
    // ensureMainSubgridRowIndexWithLimit. That path compares layout entries only
    // and skips zero-coverage ones, so it cannot see a cached_subgrids length
    // change — the very shift the cached_len key above exists to catch. Enabling
    // it would need the same key, so it stays off rather than half-guarded.
    core.main_subgrid_row_index_valid = false;
    const built = try ensureMainSubgridRowIndexWithLimit(
        core,
        cached,
        rows,
        MAX_MAIN_SUBGRID_ROW_INDEX_BYTES,
    );
    if (built) core.main_subgrid_row_index_generation = core.grid.layout_generation;
    return built;
}

fn viewportCellScrollable(
    row: u32,
    col: u32,
    rows: u32,
    cols: u32,
    margins: grid_mod.ViewportMargins,
) bool {
    return row >= margins.top and row < rows -| margins.bottom and
        col >= margins.left and col < cols -| margins.right;
}

fn setViewportRowDecoFlags(
    flags: []u32,
    row: u32,
    rows: u32,
    cols: u32,
    margins: grid_mod.ViewportMargins,
) void {
    @memset(flags, 0);
    if (row < margins.top or row >= rows -| margins.bottom) return;
    const start: usize = @intCast(@min(margins.left, cols));
    const end: usize = @intCast(cols -| margins.right);
    if (start < end) @memset(flags[start..end], c_api.DECO_SCROLLABLE);
}

// Style flags for RenderCell (bit positions)
pub const STYLE_BOLD: u8 = 1 << 0;
pub const STYLE_ITALIC: u8 = 1 << 1;
pub const STYLE_STRIKETHROUGH: u8 = 1 << 2;
pub const STYLE_UNDERLINE: u8 = 1 << 3;
pub const STYLE_UNDERCURL: u8 = 1 << 4;
pub const STYLE_UNDERDOUBLE: u8 = 1 << 5;
pub const STYLE_UNDERDOTTED: u8 = 1 << 6;
pub const STYLE_UNDERDASHED: u8 = 1 << 7;

/// SoA (Struct of Arrays) cell buffer for cache-efficient RLE scanning.
/// Each field is a separate contiguous array, improving cache utilization
/// when scans only access 1-2 fields (e.g., bgRGB-only for background RLE).
pub const RenderCells = struct {
    scalars: std.ArrayListUnmanaged(u32) = .empty,
    fg_rgbs: std.ArrayListUnmanaged(u32) = .empty,
    bg_rgbs: std.ArrayListUnmanaged(u32) = .empty,
    sp_rgbs: std.ArrayListUnmanaged(u32) = .empty,
    grid_ids: std.ArrayListUnmanaged(i64) = .empty,
    style_flags_arr: std.ArrayListUnmanaged(u8) = .empty,
    overline_arr: std.ArrayListUnmanaged(u8) = .empty,
    glow_arr: std.ArrayListUnmanaged(u8) = .empty,
    /// Per-cell base decoration flags (e.g. DECO_SCROLLABLE).
    /// Pre-populated by the caller before generateRowVertices so the
    /// unified 5-pass pipeline does not need scroll-flag computation.
    deco_base_flags: std.ArrayListUnmanaged(u32) = .empty,

    pub fn ensureTotalCapacity(self: *RenderCells, alloc: std.mem.Allocator, n: usize) !void {
        try self.scalars.ensureTotalCapacity(alloc, n);
        try self.fg_rgbs.ensureTotalCapacity(alloc, n);
        try self.bg_rgbs.ensureTotalCapacity(alloc, n);
        try self.sp_rgbs.ensureTotalCapacity(alloc, n);
        try self.grid_ids.ensureTotalCapacity(alloc, n);
        try self.style_flags_arr.ensureTotalCapacity(alloc, n);
        try self.overline_arr.ensureTotalCapacity(alloc, n);
        try self.glow_arr.ensureTotalCapacity(alloc, n);
        try self.deco_base_flags.ensureTotalCapacity(alloc, n);
    }

    pub fn setLen(self: *RenderCells, n: usize) void {
        self.scalars.items.len = n;
        self.fg_rgbs.items.len = n;
        self.bg_rgbs.items.len = n;
        self.sp_rgbs.items.len = n;
        self.grid_ids.items.len = n;
        self.style_flags_arr.items.len = n;
        self.overline_arr.items.len = n;
        self.glow_arr.items.len = n;
        self.deco_base_flags.items.len = n;
    }

    pub fn clearRetainingCapacity(self: *RenderCells) void {
        self.scalars.clearRetainingCapacity();
        self.fg_rgbs.clearRetainingCapacity();
        self.bg_rgbs.clearRetainingCapacity();
        self.sp_rgbs.clearRetainingCapacity();
        self.grid_ids.clearRetainingCapacity();
        self.style_flags_arr.clearRetainingCapacity();
        self.overline_arr.clearRetainingCapacity();
        self.glow_arr.clearRetainingCapacity();
        self.deco_base_flags.clearRetainingCapacity();
    }

    pub fn deinit(self: *RenderCells, alloc: std.mem.Allocator) void {
        self.scalars.deinit(alloc);
        self.fg_rgbs.deinit(alloc);
        self.bg_rgbs.deinit(alloc);
        self.sp_rgbs.deinit(alloc);
        self.grid_ids.deinit(alloc);
        self.style_flags_arr.deinit(alloc);
        self.overline_arr.deinit(alloc);
        self.glow_arr.deinit(alloc);
        self.deco_base_flags.deinit(alloc);
    }

    /// Write a single cell at index i.
    pub inline fn set(self: *RenderCells, i: usize, scalar: u32, fg: u32, bg: u32, sp: u32, gid: i64, flags: u8, overline: u8) void {
        self.scalars.items[i] = scalar;
        self.fg_rgbs.items[i] = fg;
        self.bg_rgbs.items[i] = bg;
        self.sp_rgbs.items[i] = sp;
        self.grid_ids.items[i] = gid;
        self.style_flags_arr.items[i] = flags;
        self.overline_arr.items[i] = overline;
    }
};

/// Pack style flags from ResolvedAttrWithStyles into u8.
pub fn packStyleFlags(a: ResolvedAttrWithStyles) u8 {
    var flags: u8 = 0;
    if (a.bold) flags |= STYLE_BOLD;
    if (a.italic) flags |= STYLE_ITALIC;
    if (a.strikethrough) flags |= STYLE_STRIKETHROUGH;
    if (a.underline) flags |= STYLE_UNDERLINE;
    if (a.undercurl) flags |= STYLE_UNDERCURL;
    if (a.underdouble) flags |= STYLE_UNDERDOUBLE;
    if (a.underdotted) flags |= STYLE_UNDERDOTTED;
    if (a.underdashed) flags |= STYLE_UNDERDASHED;
    return flags;
}

// --- SIMD-accelerated RLE scan helpers ---
// These use Zig @Vector intrinsics for batch comparison of contiguous SoA arrays.
// Each returns the first index >= start where the value differs from target (or limit).

/// Scan u32 array for end of run (4-wide SIMD with scalar tail).
pub inline fn simdFindRunEndU32(items: []const u32, start: usize, limit: usize, target: u32) usize {
    var i = start;
    const V = @Vector(4, u32);
    const t: V = @splat(target);
    while (i + 4 <= limit) {
        const chunk: V = items[i..][0..4].*;
        if (@reduce(.And, chunk == t)) {
            i += 4;
        } else {
            // Scalar scan within the 4-wide chunk to find exact mismatch
            inline for (0..4) |k| {
                if (items[i + k] != target) return i + k;
            }
            unreachable;
        }
    }
    while (i < limit) : (i += 1) {
        if (items[i] != target) return i;
    }
    return i;
}

/// Scan i64 array for end of run (2-wide SIMD with scalar tail).
pub inline fn simdFindRunEndI64(items: []const i64, start: usize, limit: usize, target: i64) usize {
    var i = start;
    const V = @Vector(2, i64);
    const t: V = @splat(target);
    while (i + 2 <= limit) {
        const chunk: V = items[i..][0..2].*;
        if (@reduce(.And, chunk == t)) {
            i += 2;
        } else {
            // Scalar scan within the 2-wide chunk
            if (items[i] != target) return i;
            return i + 1;
        }
    }
    if (i < limit and items[i] == target) i += 1;
    return i;
}

/// Scan u8 array for end of run (16-wide SIMD with scalar tail).
pub inline fn simdFindRunEndU8(items: []const u8, start: usize, limit: usize, target: u8) usize {
    var i = start;
    const V = @Vector(16, u8);
    const t: V = @splat(target);
    while (i + 16 <= limit) {
        const chunk: V = items[i..][0..16].*;
        if (@reduce(.And, chunk == t)) {
            i += 16;
        } else {
            // Scalar scan within the 16-wide chunk to find exact mismatch
            inline for (0..16) |k| {
                if (items[i + k] != target) return i + k;
            }
            unreachable;
        }
    }
    while (i < limit) : (i += 1) {
        if (items[i] != target) return i;
    }
    return i;
}

/// Find end of run where (items[i] & mask) == val.
/// Used to split glyph runs by bold/italic style so each sub-run is shaped
/// with the correct font variant, preventing ligature rendering corruption.
pub inline fn findStyleMaskEnd(items: []const u8, start: usize, limit: usize, mask: u8, val: u8) usize {
    var i = start + 1;
    while (i < limit) : (i += 1) {
        if ((items[i] & mask) != val) return i;
    }
    return limit;
}

/// Find first index where a bit is NOT set: (items[i] & mask) == 0.
/// Used for strikethrough run scans that check a specific bit rather than exact equality.
pub inline fn simdFindFirstBitUnset(items: []const u8, start: usize, limit: usize, mask: u8) usize {
    var i = start;
    const V = @Vector(16, u8);
    const m: V = @splat(mask);
    const zeros: V = @splat(0);
    while (i + 16 <= limit) {
        const chunk: V = items[i..][0..16].*;
        const masked = chunk & m;
        if (!@reduce(.Or, masked == zeros)) {
            // All 16 have the bit set, continue
            i += 16;
        } else {
            // Scalar scan within chunk to find exact position
            inline for (0..16) |k| {
                if (items[i + k] & mask == 0) return i + k;
            }
            unreachable;
        }
    }
    while (i < limit) : (i += 1) {
        if (items[i] & mask == 0) return i;
    }
    return i;
}

/// Fused run-end scan over up to 6 SoA attribute arrays in a single pass.
/// Returns the first index in [start, limit) where ANY of the enabled arrays
/// differs from its target. Equivalent to:
///     min(
///       simdFindRunEndU32(fg, ..., fg_t),
///       simdFindRunEndU32(bg, ..., bg_t),
///       simdFindRunEndI64(grid, ..., grid_t),
///       simdFindRunEndU32(deco, ..., deco_t),
///       has_style ? findStyleMaskEnd(style, ..., style_mask, style_val) : limit,
///       has_glow  ? simdFindRunEndU8(glow, ..., glow_t)                  : limit,
///     )
/// but reads each cache line once instead of 4–6 separate passes.
///
/// Stride is 8 cells per outer iteration. `inline fn` lets the compiler
/// constant-propagate `has_style` and `has_glow` at the call site, eliminating
/// the disabled branches from the hot loop.
pub inline fn simdFindRunEndMulti(
    start: usize,
    limit: usize,
    fg: []const u32,
    fg_t: u32,
    bg: []const u32,
    bg_t: u32,
    grid: []const i64,
    grid_t: i64,
    deco: []const u32,
    deco_t: u32,
    style: []const u8,
    style_mask: u8,
    style_val: u8,
    has_style: bool,
    glow: []const u8,
    glow_t: u8,
    has_glow: bool,
) usize {
    const N = 8;
    var i = start;
    const fg_tv: @Vector(N, u32) = @splat(fg_t);
    const bg_tv: @Vector(N, u32) = @splat(bg_t);
    const grid_tv: @Vector(N, i64) = @splat(grid_t);
    const deco_tv: @Vector(N, u32) = @splat(deco_t);
    const style_mv: @Vector(N, u8) = @splat(style_mask);
    const style_vv: @Vector(N, u8) = @splat(style_val);
    const glow_tv: @Vector(N, u8) = @splat(glow_t);

    while (i + N <= limit) {
        const fg_c: @Vector(N, u32) = fg[i..][0..N].*;
        const bg_c: @Vector(N, u32) = bg[i..][0..N].*;
        const grid_c: @Vector(N, i64) = grid[i..][0..N].*;
        const deco_c: @Vector(N, u32) = deco[i..][0..N].*;
        var match: @Vector(N, bool) = (fg_c == fg_tv);
        match = @select(bool, match, bg_c == bg_tv, match);
        match = @select(bool, match, grid_c == grid_tv, match);
        match = @select(bool, match, deco_c == deco_tv, match);
        if (has_style) {
            const s_c: @Vector(N, u8) = style[i..][0..N].*;
            match = @select(bool, match, (s_c & style_mv) == style_vv, match);
        }
        if (has_glow) {
            const g_c: @Vector(N, u8) = glow[i..][0..N].*;
            match = @select(bool, match, g_c == glow_tv, match);
        }
        if (@reduce(.And, match)) {
            i += N;
        } else {
            // Scalar scan within this chunk to find the exact mismatch index.
            inline for (0..N) |k| {
                if (!match[k]) return i + k;
            }
            unreachable;
        }
    }

    // Scalar tail.
    while (i < limit) : (i += 1) {
        if (fg[i] != fg_t) return i;
        if (bg[i] != bg_t) return i;
        if (grid[i] != grid_t) return i;
        if (deco[i] != deco_t) return i;
        if (has_style and (style[i] & style_mask) != style_val) return i;
        if (has_glow and glow[i] != glow_t) return i;
    }
    return i;
}

/// Check if any u32 in [start..end) is non-space (not 0 and not 32).
/// Returns true if there is "ink" content to render.
pub inline fn simdHasInkInRange(scalars: []const u32, start: usize, end: usize) bool {
    var i = start;
    const V = @Vector(4, u32);
    const v_zeros: V = @splat(@as(u32, 0));
    const v_spaces: V = @splat(@as(u32, 32));
    while (i + 4 <= end) {
        const chunk: V = scalars[i..][0..4].*;
        // Normalize: replace 0 with 32 (zero codepoint means space)
        const normalized = @select(u32, chunk == v_zeros, v_spaces, chunk);
        if (!@reduce(.And, normalized == v_spaces)) return true;
        i += 4;
    }
    while (i < end) : (i += 1) {
        const s: u32 = if (scalars[i] == 0) 32 else scalars[i];
        if (s != 32) return true;
    }
    return false;
}

/// SIMD check: are ALL u32 values in [0x20, 0x7E] (printable ASCII)?
/// Uses unsigned wrapping subtract for single-comparison range check.
pub inline fn simdAllAsciiPrintable(scalars: []const u32, count: usize) bool {
    const V = @Vector(4, u32);
    const lo: V = @splat(@as(u32, 0x20));
    const range: V = @splat(@as(u32, 0x5E)); // 0x7E - 0x20
    var i: usize = 0;
    while (i + 4 <= count) {
        const chunk: V = scalars[i..][0..4].*;
        if (!@reduce(.And, chunk -% lo <= range)) return false;
        i += 4;
    }
    while (i < count) : (i += 1) {
        if (scalars[i] -% 0x20 > 0x5E) return false;
    }
    return true;
}

/// SIMD check: are ALL u32 values non-zero in [start..end)?
/// Used to detect absence of wide char continuations for bulk copy.
pub inline fn simdAllNonZero(scalars: []const u32, start: usize, end: usize) bool {
    const V = @Vector(4, u32);
    const zeros: V = @splat(@as(u32, 0));
    var i = start;
    while (i + 4 <= end) {
        const chunk: V = scalars[i..][0..4].*;
        if (@reduce(.Or, chunk == zeros)) return false;
        i += 4;
    }
    while (i < end) : (i += 1) {
        if (scalars[i] == 0) return false;
    }
    return true;
}

/// SIMD fill with sequential u32 values (0, 1, 2, 3, ...).
pub inline fn simdFillSequential(out: [*]u32, count: usize) void {
    const V = @Vector(4, u32);
    const step: V = @splat(@as(u32, 4));
    var base: V = .{ 0, 1, 2, 3 };
    var i: usize = 0;
    while (i + 4 <= count) {
        @as(*[4]u32, @ptrCast(out + i)).* = base;
        base += step;
        i += 4;
    }
    while (i < count) : (i += 1) {
        out[i] = @intCast(i);
    }
}

/// SIMD fill with sequential u32 values starting from `start` (start, start+1, start+2, ...).
pub inline fn simdFillSequentialFrom(out: [*]u32, count: usize, start: u32) void {
    const V = @Vector(4, u32);
    const step: V = @splat(@as(u32, 4));
    var base: V = .{ start, start + 1, start + 2, start + 3 };
    var i: usize = 0;
    while (i + 4 <= count) {
        @as(*[4]u32, @ptrCast(out + i)).* = base;
        base += step;
        i += 4;
    }
    while (i < count) : (i += 1) {
        out[i] = start + @as(u32, @intCast(i));
    }
}

/// SIMD extract cp fields from Cell array (stride-2 u32 extraction).
/// Cell = struct { cp: u32, hl: u32 } → extracts every other u32.
pub inline fn simdExtractCp(cells: [*]const grid_mod.Cell, out: [*]u32, count: usize) void {
    const raw: [*]const u32 = @ptrCast(cells);
    var i: usize = 0;
    while (i + 4 <= count) {
        const v: @Vector(8, u32) = @as(*const [8]u32, @ptrCast(raw + i * 2)).*;
        const cps: @Vector(4, u32) = @shuffle(u32, v, undefined, [4]i32{ 0, 2, 4, 6 });
        @as(*[4]u32, @ptrCast(out + i)).* = cps;
        i += 4;
    }
    while (i < count) : (i += 1) {
        out[i] = raw[i * 2];
    }
}

/// Cached line data for msg_show scrolling optimization.
pub const MsgCachedLine = struct {
    data: [256]u8 = undefined,
    len: u16 = 0,
    display_width: u16 = 0,
};

/// Cache for highlight and glyph lookups during vertex generation.
/// Shared across all rows in a single flush to maximize cache hits.
/// Cache for highlight and glyph lookups during vertex generation.
/// hl_cache_buf / hl_valid_buf are heap-allocated by NvimCore and passed as slices
/// to avoid large fixed-size arrays on the stack.
pub const FlushCache = struct {
    // Slices into heap-allocated buffers owned by NvimCore
    hl_cache_buf: []ResolvedAttrWithStyles,
    hl_valid_buf: []bool,

    // Performance counters
    perf_hl_cache_hits: u32 = 0,
    perf_hl_cache_misses: u32 = 0,
    perf_glyph_ascii_hits: u32 = 0,
    perf_glyph_ascii_misses: u32 = 0,
    perf_glyph_nonascii_hits: u32 = 0,
    perf_glyph_nonascii_misses: u32 = 0,

    /// Get resolved attribute with caching.
    pub fn getAttr(self: *FlushCache, hl: *Highlights, hl_id: u32) ResolvedAttrWithStyles {
        if (hl_id < self.hl_valid_buf.len) {
            if (self.hl_valid_buf[hl_id]) {
                self.perf_hl_cache_hits += 1;
                return self.hl_cache_buf[hl_id];
            }
            self.perf_hl_cache_misses += 1;
            const resolved = hl.getWithStyles(hl_id);
            self.hl_cache_buf[hl_id] = resolved;
            self.hl_valid_buf[hl_id] = true;
            return resolved;
        }
        // Fallback for hl_id >= cache size
        self.perf_hl_cache_misses += 1;
        return hl.getWithStyles(hl_id);
    }

    /// Reset cache for a new flush (clear valid flags and counters).
    pub fn reset(self: *FlushCache) void {
        @memset(self.hl_valid_buf, false);
        self.perf_hl_cache_hits = 0;
        self.perf_hl_cache_misses = 0;
        self.perf_glyph_ascii_hits = 0;
        self.perf_glyph_ascii_misses = 0;
        self.perf_glyph_nonascii_hits = 0;
        self.perf_glyph_nonascii_misses = 0;
    }
};

// ---------------------------------------------------------------
// Scroll-aware flush: fast path eligibility
// ---------------------------------------------------------------

pub const ScrollFallbackReason = enum(u8) {
    eligible = 0,
    no_pending_scroll,
    blocked_batch, // multiple grid_scroll events in one batch
    multi_row_scroll, // |rows| > 1
    horizontal_scroll, // cols != 0
    partial_width, // left != 0 or right != target_cols
    not_full_region, // top/bot don't cover scrollable region
    rebuild_all_set, // resize/guifont/dirty_all forced full rebuild
    atlas_retried, // atlas reset caused retry
    multi_scroll_batch, // scrolled_count > 1
    no_subgrid, // grid_id != 1 but not in sub_grids (shouldn't happen)
    subgrid_overlaps_scroll, // a non-scrolling subgrid overlaps the scroll region
};

pub const ScrollFastPathResult = struct {
    eligible: bool,
    reason: ScrollFallbackReason,
    scroll_op: ?grid_mod.ScrollOp,
};

/// Determine whether the current flush can use the scroll-optimized fast path.
///
/// Requirements:
///   - scrolled_count == 1 (single scroll in batch)
///   - grid_id >= 2 (multigrid content grid, not base grid)
///   - abs(rows) <= region_height/2 (not too many vacated rows)
///   - cols == 0 (no horizontal scroll)
///   - scrolling CachedSubgrid still matches pending-scroll geometry
///   - scrolling grid covers the full main width at column zero
///   - full local width (left == 0, right == target_cols)
///   - bot <= target_rows (valid region bounds)
///   - no rebuild_all, no atlas retry
///   - no non-scrolling subgrid overlaps the scroll region
///
pub fn checkScrollFastPath(
    grid: *const grid_mod.Grid,
    rebuild_all: bool,
    atlas_retried_flag: bool,
    scrolled_count: u8,
    cached_subgrids: []const CachedSubgrid,
) ScrollFastPathResult {
    const no = ScrollFastPathResult{ .eligible = false, .scroll_op = null, .reason = .no_pending_scroll };

    const ps = grid.pending_scroll orelse
        return no;

    if (grid.scroll_fast_path_blocked)
        return .{ .eligible = false, .reason = .blocked_batch, .scroll_op = ps };
    if (scrolled_count != 1)
        return .{ .eligible = false, .reason = .multi_scroll_batch, .scroll_op = ps };
    // grid_id == 1 is the base grid and has different composition rules.
    if (ps.grid_id < 2)
        return .{ .eligible = false, .reason = .no_subgrid, .scroll_op = ps };
    const scrolling_subgrid = blk: {
        for (cached_subgrids) |csg| {
            if (csg.grid_id == ps.grid_id) break :blk csg;
        }
        break :blk null;
    } orelse return .{ .eligible = false, .reason = .no_subgrid, .scroll_op = ps };
    // pending_scroll is recorded before later win_pos/resize events in the
    // same redraw batch. Reusing row caches after that geometry changed would
    // shift a different main-grid region than the one represented by ps.
    if (scrolling_subgrid.row_start != ps.win_pos_row or
        scrolling_subgrid.sg_rows != ps.target_rows or
        scrolling_subgrid.sg_cols != ps.target_cols)
    {
        return .{ .eligible = false, .reason = .no_subgrid, .scroll_op = ps };
    }
    // The frontend callback shifts whole main-surface row buffers. A local
    // full-width scroll in a narrower or offset split cannot use that contract:
    // content outside the split must remain stationary.
    if (scrolling_subgrid.col_start != 0 or scrolling_subgrid.sg_cols != grid.cols)
        return .{ .eligible = false, .reason = .partial_width, .scroll_op = ps };
    const region_height: u32 = ps.bot -| ps.top;
    const abs_rows: u32 = blk: {
        if (ps.rows == std.math.minInt(i32)) break :blk region_height;
        break :blk @intCast(if (ps.rows < 0) -ps.rows else ps.rows);
    };
    // Allow accumulated multi-row scroll (up to half the region height).
    // Beyond that, too many vacated rows make fast path less beneficial.
    if (abs_rows == 0 or abs_rows > region_height / 2 or region_height <= 1)
        return .{ .eligible = false, .reason = .multi_row_scroll, .scroll_op = ps };
    if (ps.cols != 0)
        return .{ .eligible = false, .reason = .horizontal_scroll, .scroll_op = ps };
    if (ps.left != 0 or ps.right != ps.target_cols)
        return .{ .eligible = false, .reason = .partial_width, .scroll_op = ps };
    if (ps.bot > ps.target_rows)
        return .{ .eligible = false, .reason = .not_full_region, .scroll_op = ps };
    if (rebuild_all)
        return .{ .eligible = false, .reason = .rebuild_all_set, .scroll_op = ps };
    if (atlas_retried_flag)
        return .{ .eligible = false, .reason = .atlas_retried, .scroll_op = ps };

    // Verify scroll region in global grid coordinates stays within bounds.
    // shiftScrollCacheAndValidate indexes scroll_cache with these values,
    // so out-of-range would cause an out-of-bounds access. Saturating: a
    // hostile/malformed win_pos_row near maxInt(u32) must not
    // overflow-panic (Safe builds) or wrap into a bogus in-range value
    // (ReleaseFast) — a saturated value simply fails the bounds check below.
    const scroll_row_start = ps.top +| ps.win_pos_row;
    const scroll_row_end = ps.bot +| ps.win_pos_row;
    if (scroll_row_end > grid.rows)
        return .{ .eligible = false, .reason = .not_full_region, .scroll_op = ps };

    // Check that no non-scrolling subgrid overlaps the scroll region.
    // Cached row vertices bake in subgrid overlay content; if a non-scrolling
    // subgrid overlaps the scroll region, cache shifting would move its
    // content to wrong rows.
    for (cached_subgrids) |csg| {
        if (csg.grid_id == ps.grid_id) continue; // the scrolling grid itself is fine
        // Check row overlap between [csg.row_start, csg.row_end) and [scroll_row_start, scroll_row_end)
        if (csg.row_start < scroll_row_end and csg.row_end > scroll_row_start)
            return .{ .eligible = false, .reason = .subgrid_overlaps_scroll, .scroll_op = ps };
    }

    return .{ .eligible = true, .reason = .eligible, .scroll_op = ps };
}

/// Save current subgrid layout into prev_subgrid_snapshots.
/// Called after successful vertex emission so the next flush can detect
/// layout changes (move/add/remove).
/// Must receive the same cached_subgrids slice that was used for vertex
/// generation so the snapshot and the comparison target are identical sets.
fn saveSubgridSnapshots(core: *Core, cached_subgrids: []const CachedSubgrid) void {
    core.prev_subgrid_snapshots.clearRetainingCapacity();
    core.prev_subgrid_snapshots.ensureTotalCapacity(core.alloc, cached_subgrids.len) catch {
        // Empty snapshot is the conservative fallback: the next flush's diff
        // treats every current subgrid as newly added and regenerates the
        // affected rows (or falls back from the scroll fast path).
        return;
    };
    for (cached_subgrids) |csg| {
        core.prev_subgrid_snapshots.appendAssumeCapacity(.{
            .grid_id = csg.grid_id,
            .row_start = csg.row_start,
            .row_end = csg.row_end,
            .col_start = csg.col_start,
            .sg_cols = csg.sg_cols,
            .margin_top = csg.margin_top,
            .margin_bottom = csg.margin_bottom,
            .margin_left = csg.margin_left,
            .margin_right = csg.margin_right,
        });
    }
    std.sort.block(SubgridSnapshot, core.prev_subgrid_snapshots.items, {}, SubgridSnapshot.lessThanGridId);
}

/// Collect rows affected by subgrid layout changes between previous and
/// current flush. Returns rows that need regeneration because a subgrid
/// moved away from or into those rows, making the cached vertices stale.
/// Only rows inside [region_top, region_bot) are collected (scroll region);
/// rows outside are handled by dirty_rows in the caller.
///
/// Returns the number of rows written to `out`. If the return value equals
/// `out.len`, the buffer may have overflowed — the caller must treat this
/// as "too many diff rows" and fall back from the fast path.
fn collectSubgridDiffRows(
    core: *Core,
    cached_subgrids: []const CachedSubgrid,
    region_top: u32,
    region_bot: u32,
    out: []u32,
    existing_regen: []const u32,
) u32 {
    var count: u32 = 0;
    const prev = core.prev_subgrid_snapshots.items;

    // Normalize the current layout by grid id in persistent scratch. Sorting
    // costs O(G log G), then a merge with the already-sorted committed
    // snapshot detects additions/removals/moves in O(G). Capacity is retained,
    // so the steady-state scroll hot path does not allocate.
    core.subgrid_diff_current.clearRetainingCapacity();
    core.subgrid_diff_current.ensureTotalCapacity(core.alloc, cached_subgrids.len) catch return @intCast(out.len);
    for (cached_subgrids) |csg| {
        core.subgrid_diff_current.appendAssumeCapacity(.{
            .grid_id = csg.grid_id,
            .row_start = csg.row_start,
            .row_end = csg.row_end,
            .col_start = csg.col_start,
            .sg_cols = csg.sg_cols,
            .margin_top = csg.margin_top,
            .margin_bottom = csg.margin_bottom,
            .margin_left = csg.margin_left,
            .margin_right = csg.margin_right,
        });
    }
    std.sort.block(SubgridSnapshot, core.subgrid_diff_current.items, {}, SubgridSnapshot.lessThanGridId);
    const current = core.subgrid_diff_current.items;

    const mark_len: usize = @intCast(region_bot);
    const old_mark_len = core.subgrid_diff_row_marks.items.len;
    core.subgrid_diff_row_marks.resize(core.alloc, mark_len) catch return @intCast(out.len);
    if (mark_len > old_mark_len) {
        @memset(core.subgrid_diff_row_marks.items[old_mark_len..mark_len], 0);
    }
    core.subgrid_diff_row_generation +%= 1;
    if (core.subgrid_diff_row_generation == 0) {
        @memset(core.subgrid_diff_row_marks.items, 0);
        core.subgrid_diff_row_generation = 1;
    }
    const generation = core.subgrid_diff_row_generation;
    for (existing_regen) |row| {
        if (row < core.subgrid_diff_row_marks.items.len) {
            core.subgrid_diff_row_marks.items[row] = generation;
        }
    }

    var prev_i: usize = 0;
    var current_i: usize = 0;
    while (prev_i < prev.len or current_i < current.len) {
        if (prev_i < prev.len and current_i < current.len and prev[prev_i].grid_id == current[current_i].grid_id) {
            if (!std.meta.eql(prev[prev_i], current[current_i])) {
                count = addMarkedRowRange(core, prev[prev_i].row_start, prev[prev_i].row_end, region_top, region_bot, out, count, generation);
                if (count >= out.len) return count;
                count = addMarkedRowRange(core, current[current_i].row_start, current[current_i].row_end, region_top, region_bot, out, count, generation);
                if (count >= out.len) return count;
            }
            prev_i += 1;
            current_i += 1;
        } else if (current_i >= current.len or
            (prev_i < prev.len and prev[prev_i].grid_id < current[current_i].grid_id))
        {
            count = addMarkedRowRange(core, prev[prev_i].row_start, prev[prev_i].row_end, region_top, region_bot, out, count, generation);
            if (count >= out.len) return count;
            prev_i += 1;
        } else {
            count = addMarkedRowRange(core, current[current_i].row_start, current[current_i].row_end, region_top, region_bot, out, count, generation);
            if (count >= out.len) return count;
            current_i += 1;
        }
    }

    return count;
}

/// Helper: add rows from [start, end) that fall within [region_top, region_bot)
/// to out[], using generation marks for O(1) duplicate suppression.
fn addMarkedRowRange(
    core: *Core,
    start: u32,
    end: u32,
    region_top: u32,
    region_bot: u32,
    out: []u32,
    initial_count: u32,
    generation: u32,
) u32 {
    var count = initial_count;
    const clamped_start = @max(start, region_top);
    const clamped_end = @min(end, region_bot);
    var r = clamped_start;
    while (r < clamped_end) : (r += 1) {
        if (count >= out.len) return count;
        const row_index: usize = @intCast(r);
        if (core.subgrid_diff_row_marks.items[row_index] == generation) continue;
        core.subgrid_diff_row_marks.items[row_index] = generation;
        out[count] = r;
        count += 1;
    }
    return count;
}

/// Result of scroll cache shift + validity check.
pub const ScrollCacheShiftResult = struct {
    /// True if all non-regen rows have valid cache after shift.
    fast_path_ok: bool,
    /// Number of cached rows that would be emitted (valid, non-regen).
    cached_emit_count: u32,
    /// Number of cached rows with vert_count == 0 (empty row emission).
    empty_emit_count: u32,
};

/// Perform scroll cache shift + optional y-adjust + validity check.
/// Extracted from onFlush for testability.
///
/// Operates directly on core.scroll_cache / scroll_cache_valid.
/// After return, cache entries are shifted and y-adjusted.
/// Caller decides whether to emit or fall back based on result.
pub fn shiftScrollCacheAndValidate(
    core: *Core,
    scroll_top: usize,
    scroll_bot: usize,
    scroll_rows_raw: i32,
    delta_y: f32,
    total_rows: u32,
    regen_rows: []const u32,
    adjust_vertices: bool,
) ScrollCacheShiftResult {
    if (core.scroll_cache_rows != total_rows) {
        return .{ .fast_path_ok = false, .cached_emit_count = 0, .empty_emit_count = 0 };
    }
    if (core.main_vertex_row_counts.items.len < total_rows) {
        return .{ .fast_path_ok = false, .cached_emit_count = 0, .empty_emit_count = 0 };
    }
    if (!core.main_vertex_row_ledger_valid) {
        return .{ .fast_path_ok = false, .cached_emit_count = 0, .empty_emit_count = 0 };
    }
    const row_counts = core.main_vertex_row_counts.items;

    // Shift cache entries within scroll region.
    // For shift > 1, multiple rows scroll off and multiple rows become vacant.
    if (scroll_rows_raw > 0) {
        const shift: usize = @intCast(scroll_rows_raw);
        if (shift > total_rows or shift > scroll_bot - scroll_top) {
            return .{ .fast_path_ok = false, .cached_emit_count = 0, .empty_emit_count = 0 };
        }
        // Save scrolled-off row buffers for reuse at vacated positions
        var saved_bufs: [64]std.ArrayListUnmanaged(c_api.Vertex) = undefined;
        var saved_counts: [64]usize = undefined;
        if (shift > saved_bufs.len) {
            return .{ .fast_path_ok = false, .cached_emit_count = 0, .empty_emit_count = 0 };
        }
        for (0..shift) |s| {
            saved_bufs[s] = core.scroll_cache.items[scroll_top + s];
            saved_counts[s] = row_counts[scroll_top + s];
        }
        // Shift: row[i] <- row[i + shift], adjust y
        var i: usize = scroll_top;
        while (i + shift < scroll_bot) : (i += 1) {
            core.scroll_cache.items[i] = core.scroll_cache.items[i + shift];
            row_counts[i] = row_counts[i + shift];
            if (adjust_vertices) {
                for (core.scroll_cache.items[i].items) |*v| {
                    v.position[1] += delta_y;
                }
            }
            if (core.scroll_cache_valid.isSet(i + shift)) {
                core.scroll_cache_valid.set(i);
            } else {
                core.scroll_cache_valid.unset(i);
            }
        }
        // Vacated rows at region bottom: reuse saved buffers, mark invalid
        for (0..shift) |s| {
            core.captureRetainedShadow(saved_bufs[s].items);
            saved_bufs[s].clearRetainingCapacity();
            core.scroll_cache.items[scroll_bot - shift + s] = saved_bufs[s];
            row_counts[scroll_bot - shift + s] = 0;
            core.main_surface_vertex_count -|= saved_counts[s];
            core.flush_vertex_count_aggregate -|= saved_counts[s];
            core.scroll_cache_valid.unset(scroll_bot - shift + s);
        }
    } else if (scroll_rows_raw < 0) {
        const shift: usize = @intCast(-scroll_rows_raw);
        if (shift > total_rows or shift > scroll_bot - scroll_top) {
            return .{ .fast_path_ok = false, .cached_emit_count = 0, .empty_emit_count = 0 };
        }
        // Save scrolled-off row buffers for reuse at vacated positions
        var saved_bufs: [64]std.ArrayListUnmanaged(c_api.Vertex) = undefined;
        var saved_counts: [64]usize = undefined;
        if (shift > saved_bufs.len) {
            return .{ .fast_path_ok = false, .cached_emit_count = 0, .empty_emit_count = 0 };
        }
        for (0..shift) |s| {
            saved_bufs[s] = core.scroll_cache.items[scroll_bot - 1 - s];
            saved_counts[s] = row_counts[scroll_bot - 1 - s];
        }
        // Shift: row[i] <- row[i - shift], adjust y
        var i: usize = scroll_bot - 1;
        while (i >= scroll_top + shift) : (i -= 1) {
            core.scroll_cache.items[i] = core.scroll_cache.items[i - shift];
            row_counts[i] = row_counts[i - shift];
            if (adjust_vertices) {
                for (core.scroll_cache.items[i].items) |*v| {
                    v.position[1] += delta_y;
                }
            }
            if (core.scroll_cache_valid.isSet(i - shift)) {
                core.scroll_cache_valid.set(i);
            } else {
                core.scroll_cache_valid.unset(i);
            }
            if (i == scroll_top + shift) break;
        }
        // Vacated rows at region top: reuse saved buffers, mark invalid
        for (0..shift) |s| {
            core.captureRetainedShadow(saved_bufs[s].items);
            saved_bufs[s].clearRetainingCapacity();
            core.scroll_cache.items[scroll_top + s] = saved_bufs[s];
            row_counts[scroll_top + s] = 0;
            core.main_surface_vertex_count -|= saved_counts[s];
            core.flush_vertex_count_aggregate -|= saved_counts[s];
            core.scroll_cache_valid.unset(scroll_top + s);
        }
    }

    // Mark regen rows as invalid
    for (regen_rows) |rr| {
        if (rr < total_rows) {
            core.scroll_cache_valid.unset(rr);
        }
    }

    // Check all non-regen rows have valid cache.
    // regen_rows were unset in scroll_cache_valid above, so any row reported
    // as valid here is by construction not a regen row — count it directly.
    // Only invalid rows need a regen_rows membership check to distinguish an
    // expected miss (regen) from a genuine cache miss (fast-path fail).
    var all_valid = true;
    var cached_emit_count: u32 = 0;
    var empty_emit_count: u32 = 0;
    for (0..total_rows) |ri| {
        if (core.scroll_cache_valid.isSet(ri)) {
            cached_emit_count += 1;
            if (core.scroll_cache.items[ri].items.len == 0) {
                empty_emit_count += 1;
            }
            continue;
        }

        var is_regen = false;
        for (regen_rows) |rr| {
            if (rr == @as(u32, @intCast(ri))) {
                is_regen = true;
                break;
            }
        }
        if (!is_regen) {
            all_valid = false;
            break;
        }
    }

    return .{
        .fast_path_ok = all_valid,
        .cached_emit_count = cached_emit_count,
        .empty_emit_count = empty_emit_count,
    };
}

// ---------------------------------------------------------------------------
// VertexHelpers: shared vertex generation utilities for both global grid and
// external grid pipelines.  Extracted to file level so the 5-pass row
// generation function can be shared.
// ---------------------------------------------------------------------------
pub const VH = struct {
    inline fn ndc(x: f32, y: f32, vw: f32, vh: f32) [2]f32 {
        const nx = (x / vw) * 2.0 - 1.0;
        const ny = 1.0 - (y / vh) * 2.0;
        return .{ nx, ny };
    }

    /// Batch NDC transform for 4 quad corners (TL, TR, BL, BR).
    inline fn ndc4(x0: f32, y0: f32, x1: f32, y1: f32, vw: f32, vh: f32) [4][2]f32 {
        const V4 = @Vector(4, f32);
        const xs = V4{ x0, x1, x0, x1 };
        const ys = V4{ y0, y0, y1, y1 };
        const nxs = xs / @as(V4, @splat(vw)) * @as(V4, @splat(2.0)) - @as(V4, @splat(1.0));
        const nys = @as(V4, @splat(1.0)) - ys / @as(V4, @splat(vh)) * @as(V4, @splat(2.0));
        return .{
            .{ nxs[0], nys[0] },
            .{ nxs[1], nys[1] },
            .{ nxs[2], nys[2] },
            .{ nxs[3], nys[3] },
        };
    }

    /// SIMD-accelerated RGB→float4 conversion.
    inline fn rgb(v: u32) [4]f32 {
        return rgba(v, 1.0);
    }

    /// SIMD-accelerated RGBA→float4 conversion.
    inline fn rgba(v: u32, alpha: f32) [4]f32 {
        const V4u32 = @Vector(4, u32);
        const V4f32 = @Vector(4, f32);
        const vv: V4u32 = @splat(v);
        const channels = (vv >> V4u32{ 16, 8, 0, 0 }) & @as(V4u32, @splat(0xFF));
        const floats = @as(V4f32, @floatFromInt(channels)) * @as(V4f32, @splat(1.0 / 255.0));
        var arr: [4]f32 = floats;
        arr[3] = alpha;
        return arr;
    }

    const solid_uv: [2]f32 = .{ -1.0, -1.0 };

    fn pushSolidQuad(
        out: *std.ArrayListUnmanaged(c_api.Vertex),
        alloc: std.mem.Allocator,
        x0: f32,
        y0: f32,
        x1: f32,
        y1: f32,
        col: [4]f32,
        vw: f32,
        vh: f32,
        grid_id: i64,
        base_deco_flags: u32,
    ) !void {
        const pts = ndc4(x0, y0, x1, y1, vw, vh);
        const p0 = pts[0];
        const p1 = pts[1];
        const p2 = pts[2];
        const p3 = pts[3];

        try out.ensureUnusedCapacity(alloc, 6);
        const v = out.addManyAsSliceAssumeCapacity(6);

        v[0] = .{ .position = p0, .texCoord = solid_uv, .color = col, .grid_id = grid_id, .deco_flags = base_deco_flags, .deco_phase = 0 };
        v[1] = .{ .position = p2, .texCoord = solid_uv, .color = col, .grid_id = grid_id, .deco_flags = base_deco_flags, .deco_phase = 0 };
        v[2] = .{ .position = p1, .texCoord = solid_uv, .color = col, .grid_id = grid_id, .deco_flags = base_deco_flags, .deco_phase = 0 };

        v[3] = .{ .position = p1, .texCoord = solid_uv, .color = col, .grid_id = grid_id, .deco_flags = base_deco_flags, .deco_phase = 0 };
        v[4] = .{ .position = p2, .texCoord = solid_uv, .color = col, .grid_id = grid_id, .deco_flags = base_deco_flags, .deco_phase = 0 };
        v[5] = .{ .position = p3, .texCoord = solid_uv, .color = col, .grid_id = grid_id, .deco_flags = base_deco_flags, .deco_phase = 0 };
    }

    /// Same as pushSolidQuad but caller guarantees capacity (6 vertices).
    fn pushSolidQuadAssumeCapacity(
        out: *std.ArrayListUnmanaged(c_api.Vertex),
        x0: f32,
        y0: f32,
        x1: f32,
        y1: f32,
        col: [4]f32,
        vw: f32,
        vh: f32,
        grid_id: i64,
        base_deco_flags: u32,
    ) void {
        const pts = ndc4(x0, y0, x1, y1, vw, vh);
        const p0 = pts[0];
        const p1 = pts[1];
        const p2 = pts[2];
        const p3 = pts[3];

        const v = out.addManyAsSliceAssumeCapacity(6);

        v[0] = .{ .position = p0, .texCoord = solid_uv, .color = col, .grid_id = grid_id, .deco_flags = base_deco_flags, .deco_phase = 0 };
        v[1] = .{ .position = p2, .texCoord = solid_uv, .color = col, .grid_id = grid_id, .deco_flags = base_deco_flags, .deco_phase = 0 };
        v[2] = .{ .position = p1, .texCoord = solid_uv, .color = col, .grid_id = grid_id, .deco_flags = base_deco_flags, .deco_phase = 0 };

        v[3] = .{ .position = p1, .texCoord = solid_uv, .color = col, .grid_id = grid_id, .deco_flags = base_deco_flags, .deco_phase = 0 };
        v[4] = .{ .position = p2, .texCoord = solid_uv, .color = col, .grid_id = grid_id, .deco_flags = base_deco_flags, .deco_phase = 0 };
        v[5] = .{ .position = p3, .texCoord = solid_uv, .color = col, .grid_id = grid_id, .deco_flags = base_deco_flags, .deco_phase = 0 };
    }

    fn pushGlyphQuadAssumeCapacity(
        out: *std.ArrayListUnmanaged(c_api.Vertex),
        x0: f32,
        y0: f32,
        x1: f32,
        y1: f32,
        uv0: [2]f32,
        uv1: [2]f32,
        uv2: [2]f32,
        uv3: [2]f32,
        col: [4]f32,
        vw: f32,
        vh: f32,
        grid_id: i64,
        base_deco_flags: u32,
    ) void {
        const pts = ndc4(x0, y0, x1, y1, vw, vh);
        const p0 = pts[0];
        const p1 = pts[1];
        const p2 = pts[2];
        const p3 = pts[3];

        const v = out.addManyAsSliceAssumeCapacity(6);

        v[0] = .{ .position = p0, .texCoord = uv0, .color = col, .grid_id = grid_id, .deco_flags = base_deco_flags, .deco_phase = 0 };
        v[1] = .{ .position = p2, .texCoord = uv2, .color = col, .grid_id = grid_id, .deco_flags = base_deco_flags, .deco_phase = 0 };
        v[2] = .{ .position = p1, .texCoord = uv1, .color = col, .grid_id = grid_id, .deco_flags = base_deco_flags, .deco_phase = 0 };

        v[3] = .{ .position = p1, .texCoord = uv1, .color = col, .grid_id = grid_id, .deco_flags = base_deco_flags, .deco_phase = 0 };
        v[4] = .{ .position = p2, .texCoord = uv2, .color = col, .grid_id = grid_id, .deco_flags = base_deco_flags, .deco_phase = 0 };
        v[5] = .{ .position = p3, .texCoord = uv3, .color = col, .grid_id = grid_id, .deco_flags = base_deco_flags, .deco_phase = 0 };
    }

    fn pushDecoQuad(
        out: *std.ArrayListUnmanaged(c_api.Vertex),
        alloc: std.mem.Allocator,
        x0: f32,
        y0: f32,
        x1: f32,
        y1: f32,
        col: [4]f32,
        vw: f32,
        vh: f32,
        grid_id: i64,
        deco_flags: u32,
        deco_phase: f32,
    ) !void {
        const pts = ndc4(x0, y0, x1, y1, vw, vh);
        const p0 = pts[0];
        const p1 = pts[1];
        const p2 = pts[2];
        const p3 = pts[3];

        // UV coordinates for decorations:
        // - UV.x = -1 (sentinel for solid/decoration)
        // - UV.y = local Y position within quad (0.0 at top, 1.0 at bottom)
        const uv_top: [2]f32 = .{ -1.0, 0.0 };
        const uv_bottom: [2]f32 = .{ -1.0, 1.0 };

        try out.ensureUnusedCapacity(alloc, 6);
        const v = out.addManyAsSliceAssumeCapacity(6);

        v[0] = .{ .position = p0, .texCoord = uv_top, .color = col, .grid_id = grid_id, .deco_flags = deco_flags, .deco_phase = deco_phase };
        v[1] = .{ .position = p2, .texCoord = uv_bottom, .color = col, .grid_id = grid_id, .deco_flags = deco_flags, .deco_phase = deco_phase };
        v[2] = .{ .position = p1, .texCoord = uv_top, .color = col, .grid_id = grid_id, .deco_flags = deco_flags, .deco_phase = deco_phase };

        v[3] = .{ .position = p1, .texCoord = uv_top, .color = col, .grid_id = grid_id, .deco_flags = deco_flags, .deco_phase = deco_phase };
        v[4] = .{ .position = p2, .texCoord = uv_bottom, .color = col, .grid_id = grid_id, .deco_flags = deco_flags, .deco_phase = deco_phase };
        v[5] = .{ .position = p3, .texCoord = uv_bottom, .color = col, .grid_id = grid_id, .deco_flags = deco_flags, .deco_phase = deco_phase };
    }

    fn pushDecoQuadAssumeCapacity(
        out: *std.ArrayListUnmanaged(c_api.Vertex),
        x0: f32,
        y0: f32,
        x1: f32,
        y1: f32,
        col: [4]f32,
        vw: f32,
        vh: f32,
        grid_id: i64,
        deco_flags: u32,
        deco_phase: f32,
    ) void {
        const pts = ndc4(x0, y0, x1, y1, vw, vh);
        const p0 = pts[0];
        const p1 = pts[1];
        const p2 = pts[2];
        const p3 = pts[3];

        const uv_top: [2]f32 = .{ -1.0, 0.0 };
        const uv_bottom: [2]f32 = .{ -1.0, 1.0 };

        const v = out.addManyAsSliceAssumeCapacity(6);

        v[0] = .{ .position = p0, .texCoord = uv_top, .color = col, .grid_id = grid_id, .deco_flags = deco_flags, .deco_phase = deco_phase };
        v[1] = .{ .position = p2, .texCoord = uv_bottom, .color = col, .grid_id = grid_id, .deco_flags = deco_flags, .deco_phase = deco_phase };
        v[2] = .{ .position = p1, .texCoord = uv_top, .color = col, .grid_id = grid_id, .deco_flags = deco_flags, .deco_phase = deco_phase };

        v[3] = .{ .position = p1, .texCoord = uv_top, .color = col, .grid_id = grid_id, .deco_flags = deco_flags, .deco_phase = deco_phase };
        v[4] = .{ .position = p2, .texCoord = uv_bottom, .color = col, .grid_id = grid_id, .deco_flags = deco_flags, .deco_phase = deco_phase };
        v[5] = .{ .position = p3, .texCoord = uv_bottom, .color = col, .grid_id = grid_id, .deco_flags = deco_flags, .deco_phase = deco_phase };
    }
};

/// Parameters for the unified 5-pass row vertex generation.
pub const RowGenParams = struct {
    row: u32,
    cols: u32,
    vw: f32,
    vh: f32,
    cell_w: f32,
    cell_h: f32,
    top_pad: f32,
    default_bg: u32,
    blur_enabled: bool,
    background_opacity: f32,
    is_cmdline: bool,
    glow_enabled: bool,
    max_vertices: usize = MAX_VERTICES_PER_CALLBACK,
};

/// Stats returned from generateRowVertices for performance tracking.
pub const RowGenStats = struct {
    had_glyph_miss: bool = false,
    // Vertex counts relative to the output length on entry, after each of the
    // five passes. Partial-only submission uses these boundaries to preserve
    // global layer order across rows without duplicating vertex generation.
    pass_ends: [5]usize = .{0} ** 5,
    shape_cache_hits: u32 = 0,
    shape_cache_misses: u32 = 0,
    ascii_fast_path_runs: u32 = 0,
    shape_us: i64 = 0, // total microseconds spent in shape_text_run callback
    shape_calls: u32 = 0, // number of shape_text_run callback invocations
    // Per-pass wall time (ns). Set only when `core.log.cb != null`; otherwise 0.
    // Pass 3 (glyph) includes shape_us — subtract for glyph-emit-only.
    bg_ns: i64 = 0,
    under_ns: i64 = 0,
    glyph_ns: i64 = 0,
    strike_ns: i64 = 0,
    overline_ns: i64 = 0,
    // Pass 3 sub-instrumentation. cache_lookup_ns is derivable as
    // glyph_ns - shape_us*1000 - atlas_ensure_ns - quad_emit_ns.
    atlas_ensure_ns: i64 = 0, // ensureGlyphPhase2 / ensureGlyphByID / ensure_styled / ensure_base
    quad_emit_ns: i64 = 0, // pushGlyphQuadAssumeCapacity
};

fn ensureShapingScratch(core: *Core, run_len: usize) !void {
    try core.shaping_scalars.ensureTotalCapacity(core.alloc, run_len);
    try core.shaping_col_widths.ensureTotalCapacity(core.alloc, run_len);
    try core.shaping_src_cols.ensureTotalCapacity(core.alloc, run_len);
}

/// Convert a failed shape callback into the existing per-scalar fallback path.
/// gid=0 deliberately selects the .notdef branch below, which resolves every
/// scalar through ensureGlyphPhase2 while preserving wide-cell column widths.
fn setShapingScalarFallback(bufs: *vertexgen.ShapingBuffers, col_widths: []const u32) usize {
    var glyph_count: usize = 0;
    for (col_widths, 0..) |width, scalar_index| {
        // Overflow scalars belong to the preceding cell and have zero width.
        // Emit one fallback cluster per base cell so combining tails remain in
        // that cluster rather than becoming independent grid cells.
        if (width == 0) continue;
        bufs.glyph_ids.items[glyph_count] = 0;
        bufs.clusters.items[glyph_count] = @intCast(scalar_index);
        bufs.x_adv.items[glyph_count] = 0;
        bufs.x_off.items[glyph_count] = 0;
        bufs.y_off.items[glyph_count] = 0;
        glyph_count += 1;
    }
    bufs.setLen(glyph_count);
    return glyph_count;
}

fn shapeClustersValid(clusters: []const u32, glyph_count: usize, scalar_count: usize) bool {
    if (glyph_count == 0 or scalar_count == 0) return false;
    if (clusters[0] != 0) return false;

    var previous: u32 = 0;
    for (clusters[0..glyph_count], 0..) |cluster, i| {
        if (cluster >= scalar_count) return false;
        if (i != 0 and cluster < previous) return false;
        previous = cluster;
    }
    return true;
}

/// Unified 5-pass row vertex generation shared by global grid (row_mode) and
/// external grid paths.  Caller must pre-populate `core.row_cells` (including
/// `deco_base_flags`) before calling.  Returns stats including glyph miss flag.
pub fn generateRowVertices(
    core: *Core,
    p: RowGenParams,
    out: *std.ArrayListUnmanaged(c_api.Vertex),
) !RowGenStats {
    // Publish the buffer to the mid-flush atlas collection for as long as this
    // row is being composed; see Core.inflight_row_verts.
    core.inflight_row_verts = out;
    defer core.inflight_row_verts = null;

    const rc = &core.row_cells;
    const out_start = out.items.len;
    const r = p.row;
    const cols = p.cols;
    const cellW = p.cell_w;
    const cellH = p.cell_h;
    const topPad = p.top_pad;
    const vw = p.vw;
    const vh = p.vh;
    var stats = RowGenStats{};
    const log_enabled = core.log.cb != null;
    // Sub-glyph timing costs two clock reads per emitted quad — thousands per
    // full redraw — and only ever feeds the verbose-tier breakdown, so it is
    // gated separately from the per-row pass timers above.
    const log_glyph_timing = log_enabled and core.log.verbose;
    if (out_start > p.max_vertices) return vertexBudgetExceeded(core);
    // Pass 3 sub-timing accumulators. Copied into stats before return.
    var atlas_ensure_ns_acc: i64 = 0;
    var quad_emit_ns_acc: i64 = 0;

    // ── Pass 1: Background (run-length by bgRGB + grid_id) ──────────
    {
        const t_bg_start: i128 = if (log_enabled) clock.nowNs() else 0;
        var c: u32 = 0;
        while (c < cols) {
            const run_bg = rc.bg_rgbs.items[@intCast(c)];
            const run_grid_id = rc.grid_ids.items[@intCast(c)];
            const run_deco = rc.deco_base_flags.items[@intCast(c)];
            const run_start = c;

            const end: u32 = @intCast(@min(
                simdFindRunEndU32(rc.bg_rgbs.items, @intCast(c), @intCast(cols), run_bg),
                @min(
                    simdFindRunEndI64(rc.grid_ids.items, @intCast(c), @intCast(cols), run_grid_id),
                    simdFindRunEndU32(rc.deco_base_flags.items, @intCast(c), @intCast(cols), run_deco),
                ),
            ));

            const x0: f32 = @as(f32, @floatFromInt(run_start)) * cellW;
            const x1: f32 = @as(f32, @floatFromInt(end)) * cellW;
            const y0: f32 = @as(f32, @floatFromInt(r)) * cellH;
            const y1: f32 = y0 + cellH;

            const bg_alpha: f32 = if (run_bg == p.default_bg)
                (if (p.blur_enabled) (if (p.is_cmdline) 0.0 else 0.5) else p.background_opacity)
            else
                1.0;
            try ensureRowQuadCapacity(core, out, p.max_vertices, 1);
            try VH.pushSolidQuad(out, core.alloc, x0, y0, x1, y1, VH.rgba(run_bg, bg_alpha), vw, vh, run_grid_id, run_deco);
            c = end;
        }
        if (log_enabled) stats.bg_ns = @intCast(@max(0, clock.nowNs() - t_bg_start));
    }
    stats.pass_ends[0] = out.items.len - out_start;

    // ── Pass 2: Under-decorations (underline, underdouble, undercurl, underdotted, underdashed) ──
    {
        const t_under_start: i128 = if (log_enabled) clock.nowNs() else 0;
        var c: u32 = 0;
        while (c < cols) {
            const cell_style_flags = rc.style_flags_arr.items[@intCast(c)];
            const under_deco_mask = STYLE_UNDERLINE | STYLE_UNDERDOUBLE | STYLE_UNDERCURL | STYLE_UNDERDOTTED | STYLE_UNDERDASHED;
            if (cell_style_flags & under_deco_mask == 0) {
                c += 1;
                continue;
            }

            const run_start = c;
            const run_flags = cell_style_flags;
            const run_sp = rc.sp_rgbs.items[@intCast(c)];
            const run_fg = rc.fg_rgbs.items[@intCast(c)];
            const run_grid_id = rc.grid_ids.items[@intCast(c)];
            const run_deco = rc.deco_base_flags.items[@intCast(c)];

            // fg must also match when sp is unset (deco_color falls back to fg in
            // that case); when sp IS set, fg is irrelevant to the run so don't
            // constrain on it (avoids splitting runs unnecessarily).
            const fg_run_end: u32 = if (run_sp == highlight.Highlights.SP_NOT_SET)
                @intCast(simdFindRunEndU32(rc.fg_rgbs.items, @intCast(c + 1), @intCast(cols), run_fg))
            else
                cols;

            const run_end: u32 = @intCast(@min(
                simdFindRunEndU8(rc.style_flags_arr.items, @intCast(c + 1), @intCast(cols), run_flags),
                @min(
                    simdFindRunEndU32(rc.sp_rgbs.items, @intCast(c + 1), @intCast(cols), run_sp),
                    @min(
                        simdFindRunEndI64(rc.grid_ids.items, @intCast(c + 1), @intCast(cols), run_grid_id),
                        @min(
                            simdFindRunEndU32(rc.deco_base_flags.items, @intCast(c + 1), @intCast(cols), run_deco),
                            fg_run_end,
                        ),
                    ),
                ),
            ));

            const deco_color = if (run_sp != highlight.Highlights.SP_NOT_SET) VH.rgb(run_sp) else VH.rgb(run_fg);
            const deco_scroll_flag: u32 = run_deco;

            const x0: f32 = @as(f32, @floatFromInt(run_start)) * cellW;
            const x1: f32 = @as(f32, @floatFromInt(run_end)) * cellW;
            const row_y: f32 = @as(f32, @floatFromInt(r)) * cellH;

            if (run_flags & STYLE_UNDERLINE != 0) {
                const uy0 = row_y + cellH - 2.0;
                const uy1 = uy0 + 1.0;
                try ensureRowQuadCapacity(core, out, p.max_vertices, 1);
                try VH.pushDecoQuad(out, core.alloc, x0, uy0, x1, uy1, deco_color, vw, vh, run_grid_id, c_api.DECO_UNDERLINE | deco_scroll_flag, 0);
            }

            if (run_flags & STYLE_UNDERDOUBLE != 0) {
                const uy0_1 = row_y + cellH - 6.0;
                const uy1_1 = uy0_1 + 1.0;
                const uy0_2 = row_y + cellH - 2.0;
                const uy1_2 = uy0_2 + 1.0;
                try ensureRowQuadCapacity(core, out, p.max_vertices, 2);
                try VH.pushDecoQuad(out, core.alloc, x0, uy0_1, x1, uy1_1, deco_color, vw, vh, run_grid_id, c_api.DECO_UNDERLINE | deco_scroll_flag, 0);
                try VH.pushDecoQuad(out, core.alloc, x0, uy0_2, x1, uy1_2, deco_color, vw, vh, run_grid_id, c_api.DECO_UNDERLINE | deco_scroll_flag, 0);
            }

            if (run_flags & STYLE_UNDERCURL != 0) {
                const uy0 = row_y + cellH - 4.0;
                const uy1 = row_y + cellH;
                const phase: f32 = @floatFromInt(run_start);
                try ensureRowQuadCapacity(core, out, p.max_vertices, 1);
                try VH.pushDecoQuad(out, core.alloc, x0, uy0, x1, uy1, deco_color, vw, vh, run_grid_id, c_api.DECO_UNDERCURL | deco_scroll_flag, phase);
            }

            if (run_flags & STYLE_UNDERDOTTED != 0) {
                const uy0 = row_y + cellH - 2.0;
                const uy1 = uy0 + 1.0;
                try ensureRowQuadCapacity(core, out, p.max_vertices, 1);
                try VH.pushDecoQuad(out, core.alloc, x0, uy0, x1, uy1, deco_color, vw, vh, run_grid_id, c_api.DECO_UNDERDOTTED | deco_scroll_flag, 0);
            }

            if (run_flags & STYLE_UNDERDASHED != 0) {
                const uy0 = row_y + cellH - 2.0;
                const uy1 = uy0 + 1.0;
                try ensureRowQuadCapacity(core, out, p.max_vertices, 1);
                try VH.pushDecoQuad(out, core.alloc, x0, uy0, x1, uy1, deco_color, vw, vh, run_grid_id, c_api.DECO_UNDERDASHED | deco_scroll_flag, 0);
            }

            c = run_end;
        }
        if (log_enabled) stats.under_ns = @intCast(@max(0, clock.nowNs() - t_under_start));
    }
    stats.pass_ends[1] = out.items.len - out_start;

    // ── Pass 3: Glyphs ──────────────────────────────────────────────
    const ensure_base = core.cb.on_atlas_ensure_glyph;
    const ensure_styled = core.cb.on_atlas_ensure_glyph_styled;
    const shape_text_run = core.cb.on_shape_text_run;
    const has_shaping = shape_text_run != null and core.isPhase2Atlas() and core.cb.on_rasterize_glyph_by_id != null;

    // Local aliases for glyph caches
    const glyph_cache_ascii = core.glyph_cache_ascii;
    const glyph_valid_ascii = core.glyph_valid_ascii;
    const glyph_cache_non_ascii = core.glyph_cache_non_ascii;
    const glyph_keys_non_ascii = core.glyph_keys_non_ascii;
    const GLYPH_CACHE_ASCII_SIZE = core.glyph_cache_ascii_size;
    // Hash modulus = physical array length, NOT core.glyph_cache_non_ascii_size. The
    // size field can drift from the allocated arrays (e.g. a concurrent setGlyphCacheSize
    // bumps the field before the arrays are reallocated); hashing with the larger field
    // would then index past the end of these caches (out-of-bounds panic). Both cache
    // families (non_ascii + by_id) are allocated together at the same length, so either
    // array's len is the correct, always-in-bounds modulus.
    const GLYPH_CACHE_NON_ASCII_SIZE: u32 = if (core.glyph_keys_non_ascii) |k|
        @intCast(k.len)
    else if (core.glyph_keys_by_id) |k|
        @intCast(k.len)
    else
        0;
    const glyph_cache_id = core.glyph_cache_by_id;
    const glyph_keys_id = core.glyph_keys_by_id;

    const t_glyph_start: i128 = if (log_enabled) clock.nowNs() else 0;
    if (has_shaping or ensure_base != null or ensure_styled != null or core.isPhase2Atlas()) {
        var c: u32 = 0;
        while (c < cols) {
            const run_fg = rc.fg_rgbs.items[@intCast(c)];
            const run_bg = rc.bg_rgbs.items[@intCast(c)];
            const run_grid_id = rc.grid_ids.items[@intCast(c)];
            const run_deco = rc.deco_base_flags.items[@intCast(c)];
            const run_start = c;

            // Fused run-end: single SIMD pass over fg/bg/grid + optional
            // style-mask (when shaping splits by bold/italic) + optional glow.
            // Replaces 3–5 separate simdFindRunEnd*+findStyleMaskEnd calls.
            const shaping_style_mask: u8 = STYLE_BOLD | STYLE_ITALIC;
            const run_style_bi: u8 = rc.style_flags_arr.items[@intCast(c)] & shaping_style_mask;
            const run_glow: u8 = if (p.glow_enabled) rc.glow_arr.items[@intCast(c)] else 0;
            const end: u32 = @intCast(simdFindRunEndMulti(
                @intCast(c),
                @intCast(cols),
                rc.fg_rgbs.items,
                run_fg,
                rc.bg_rgbs.items,
                run_bg,
                rc.grid_ids.items,
                run_grid_id,
                rc.deco_base_flags.items,
                run_deco,
                rc.style_flags_arr.items,
                shaping_style_mask,
                run_style_bi,
                has_shaping,
                rc.glow_arr.items,
                run_glow,
                p.glow_enabled,
            ));
            const may_have_overflow = core.grid.overflowCountForGrid(run_grid_id) != 0 or core.flush_float_overlay != null;
            var has_ink = simdHasInkInRange(rc.scalars.items, @intCast(c), @intCast(end));
            if (!has_ink and may_have_overflow) {
                var ink_col: u32 = run_start;
                while (ink_col < end) : (ink_col += 1) {
                    if (getOverflowForCell(core, rc, r, ink_col)) |extras| {
                        if (extras.len != 0) {
                            has_ink = true;
                            break;
                        }
                    }
                }
            }

            if (has_ink) {
                const baseX = @as(f32, @floatFromInt(run_start)) * cellW;
                const baseY = @as(f32, @floatFromInt(r)) * cellH + topPad;
                const fg = VH.rgb(run_fg);
                const glyph_scroll_flag: u32 = run_deco;
                const run_has_glow = run_glow != 0;

                if (has_shaping) {
                    // --- Text-run shaping path ---
                    const run_len = end - run_start;
                    const first_style = rc.style_flags_arr.items[@intCast(run_start)];
                    const c_style: u32 = @as(u32, if (first_style & STYLE_BOLD != 0) c_api.STYLE_BOLD else 0) |
                        @as(u32, if (first_style & STYLE_ITALIC != 0) c_api.STYLE_ITALIC else 0);
                    const style_index: u32 = @as(u32, if (first_style & STYLE_BOLD != 0) @as(u32, 1) else 0) +
                        @as(u32, if (first_style & STYLE_ITALIC != 0) @as(u32, 2) else 0);

                    // Collect scalars (skip wide char continuations) and track column widths.
                    // Also track the composited column for each scalar so we can look up
                    // cell overflow (e.g., VS16) during vertex generation.
                    core.shaping_scalars.clearRetainingCapacity();
                    core.shaping_col_widths.clearRetainingCapacity();
                    core.shaping_src_cols.clearRetainingCapacity();
                    var shaping_scalar_capacity: usize = run_len;
                    if (may_have_overflow) {
                        const persistent_clusters = core.grid.overflowCountForGrid(run_grid_id);
                        const overlay_cells = if (core.flush_float_overlay) |overlay| overlay.count() else 0;
                        const possible_clusters = @min(run_len, persistent_clusters +| overlay_cells);
                        shaping_scalar_capacity +|= possible_clusters *| 15;
                    }
                    try ensureShapingScratch(core, shaping_scalar_capacity);
                    // SIMD fast path: no continuation cells and no cluster
                    // tails. A zero immediately after this style/color run is
                    // still the wide continuation of its final scalar, so the
                    // row-aware collector below must assign that scalar width 2.
                    const run_ends_at_wide_continuation = end < cols and
                        rc.scalars.items[@intCast(end)] == 0;
                    if (!may_have_overflow and !run_ends_at_wide_continuation and
                        simdAllNonZero(rc.scalars.items, @intCast(run_start), @intCast(end)))
                    {
                        @memcpy(core.shaping_scalars.items.ptr[0..run_len], rc.scalars.items[@intCast(run_start)..@intCast(end)]);
                        core.shaping_scalars.items.len = run_len;
                        @memset(core.shaping_col_widths.items.ptr[0..run_len], 1);
                        core.shaping_col_widths.items.len = run_len;
                        // src_cols: sequential from run_start
                        simdFillSequentialFrom(core.shaping_src_cols.items.ptr, run_len, run_start);
                        core.shaping_src_cols.items.len = run_len;
                    } else {
                        var si: u32 = run_start;
                        while (si < end) : (si += 1) {
                            const s = rc.scalars.items[@intCast(si)];
                            if (s == 0) {
                                continue;
                            }
                            core.shaping_scalars.appendAssumeCapacity(s);
                            // A continuation can begin a different style/color
                            // run. Cell width is row geometry, so inspect the
                            // complete row rather than truncating at this run.
                            const col_w: u32 = if (si + 1 < cols and rc.scalars.items[@intCast(si + 1)] == 0) 2 else 1;
                            core.shaping_col_widths.appendAssumeCapacity(col_w);
                            core.shaping_src_cols.appendAssumeCapacity(si);
                            if (may_have_overflow) {
                                if (getOverflowForCell(core, rc, r, si)) |extras| {
                                    for (extras) |extra| {
                                        core.shaping_scalars.appendAssumeCapacity(extra);
                                        core.shaping_col_widths.appendAssumeCapacity(0);
                                        core.shaping_src_cols.appendAssumeCapacity(si);
                                    }
                                }
                            }
                        }
                    }

                    const scalar_count = core.shaping_scalars.items.len;
                    if (scalar_count == 0) {
                        c = end;
                        continue;
                    }

                    // ASCII fast path: skip HarfBuzz for printable ASCII runs
                    const bufs = &core.shaping_bufs;
                    var final_glyph_count: usize = 0;
                    var used_ascii_fast_path = false;
                    var shape_callback_fallback = false;

                    const ascii_tables_loaded = core.loadAsciiTables();
                    if (core.flush_aborted) return error.FlushAborted;
                    if (ascii_tables_loaded) {
                        const is_ascii_safe = ascii_chk: {
                            const scalars = core.shaping_scalars.items[0..scalar_count];
                            if (!simdAllAsciiPrintable(scalars, scalar_count)) break :ascii_chk false;
                            // ascii_lig_triggers now covers single-glyph
                            // substitution features (zero / ssXX / cvXX / locl /
                            // ccmp / smcp etc.) in addition to multi-glyph
                            // ligatures. A scalar_count==1 run can still be
                            // affected by zero=1 swapping '0' with slashed-zero,
                            // for example. The trigger table must be consulted
                            // for every run regardless of length.
                            const trigs = &core.ascii_lig_triggers[style_index];
                            for (scalars) |s| {
                                if (trigs[@intCast(s)] != 0) break :ascii_chk false;
                            }
                            break :ascii_chk true;
                        };
                        if (is_ascii_safe) {
                            try bufs.ensureCapacity(core.alloc, scalar_count);
                            bufs.setLen(scalar_count);
                            const gids = &core.ascii_glyph_ids[style_index];
                            const xadvs = &core.ascii_x_advances[style_index];
                            @memset(bufs.x_off.items[0..scalar_count], 0);
                            @memset(bufs.y_off.items[0..scalar_count], 0);
                            simdFillSequential(bufs.clusters.items.ptr, scalar_count);
                            for (0..scalar_count) |i| {
                                const s: usize = @intCast(core.shaping_scalars.items[i]);
                                bufs.glyph_ids.items[i] = gids[s];
                                bufs.x_adv.items[i] = xadvs[s];
                            }
                            final_glyph_count = scalar_count;
                            used_ascii_fast_path = true;
                            stats.ascii_fast_path_runs += 1;
                        }
                    }

                    if (!used_ascii_fast_path) {
                        // Shape cache lookup / callback
                        const sc_hash1 = nvim_core.shapeCacheHash(core.shaping_scalars.items[0..scalar_count], c_style);
                        const sc_hash2 = nvim_core.shapeCacheHash2(core.shaping_scalars.items[0..scalar_count], c_style);
                        const sc_set_base = (sc_hash1 & (@as(u64, core.shape_cache_sets) - 1)) * nvim_core.SHAPE_CACHE_WAYS;
                        const sc_font_gen = core.font_generation;

                        var sc_cache_hit = false;

                        if (core.shape_cache) |sc_cache| {
                            for (0..nvim_core.SHAPE_CACHE_WAYS) |sc_way| {
                                const sc_entry = &sc_cache[sc_set_base + sc_way];
                                if (sc_entry.key_hash == sc_hash1 and
                                    sc_entry.key_hash2 == sc_hash2 and
                                    sc_entry.font_gen == sc_font_gen and
                                    sc_entry.scalar_count == @as(u32, @intCast(scalar_count)) and
                                    sc_entry.glyph_count > 0 and
                                    sc_entry.glyph_count <= nvim_core.SHAPE_CACHE_MAX_GLYPHS)
                                {
                                    final_glyph_count = sc_entry.glyph_count;
                                    try bufs.ensureCapacity(core.alloc, final_glyph_count);
                                    bufs.setLen(final_glyph_count);
                                    @memcpy(bufs.glyph_ids.items[0..final_glyph_count], sc_entry.glyph_ids[0..final_glyph_count]);
                                    @memcpy(bufs.clusters.items[0..final_glyph_count], sc_entry.clusters[0..final_glyph_count]);
                                    @memcpy(bufs.x_adv.items[0..final_glyph_count], sc_entry.x_adv[0..final_glyph_count]);
                                    @memcpy(bufs.x_off.items[0..final_glyph_count], sc_entry.x_off[0..final_glyph_count]);
                                    @memcpy(bufs.y_off.items[0..final_glyph_count], sc_entry.y_off[0..final_glyph_count]);
                                    sc_cache_hit = true;
                                    stats.shape_cache_hits += 1;
                                    break;
                                }
                            }
                        }

                        if (!sc_cache_hit) {
                            stats.shape_cache_misses += 1;
                            try bufs.ensureCapacity(core.alloc, scalar_count);
                            bufs.setLen(scalar_count);

                            const t_shape_start: i128 = if (log_enabled) clock.nowNs() else 0;
                            const glyph_count = shape_text_run.?(
                                core.ctx,
                                core.shaping_scalars.items.ptr,
                                scalar_count,
                                c_style,
                                bufs.glyph_ids.items.ptr,
                                bufs.clusters.items.ptr,
                                bufs.x_adv.items.ptr,
                                bufs.x_off.items.ptr,
                                bufs.y_off.items.ptr,
                                scalar_count,
                            );
                            if (log_enabled) {
                                const t_shape_end = clock.nowNs();
                                stats.shape_us += @intCast(@divTrunc(@max(0, t_shape_end - t_shape_start), 1000));
                                stats.shape_calls += 1;
                            }
                            if (core.flush_aborted) return error.FlushAborted;

                            if (glyph_count == 0) {
                                final_glyph_count = setShapingScalarFallback(bufs, core.shaping_col_widths.items[0..scalar_count]);
                                shape_callback_fallback = true;
                            } else if (glyph_count > scalar_count) {
                                final_glyph_count = glyph_count;
                                try bufs.ensureCapacity(core.alloc, glyph_count);
                                bufs.setLen(glyph_count);
                                {
                                    const t_shape2_start: i128 = if (log_enabled) clock.nowNs() else 0;
                                    final_glyph_count = shape_text_run.?(
                                        core.ctx,
                                        core.shaping_scalars.items.ptr,
                                        scalar_count,
                                        c_style,
                                        bufs.glyph_ids.items.ptr,
                                        bufs.clusters.items.ptr,
                                        bufs.x_adv.items.ptr,
                                        bufs.x_off.items.ptr,
                                        bufs.y_off.items.ptr,
                                        glyph_count,
                                    );
                                    if (log_enabled) {
                                        const t_shape2_end = clock.nowNs();
                                        stats.shape_us += @intCast(@divTrunc(@max(0, t_shape2_end - t_shape2_start), 1000));
                                        stats.shape_calls += 1;
                                    }
                                }
                                if (core.flush_aborted) return error.FlushAborted;
                                if (final_glyph_count == 0) {
                                    final_glyph_count = setShapingScalarFallback(bufs, core.shaping_col_widths.items[0..scalar_count]);
                                    shape_callback_fallback = true;
                                } else if (final_glyph_count > glyph_count) {
                                    // The second call was given the exact capacity
                                    // it requested. Truncation would publish
                                    // malformed clusters and hide a contract bug.
                                    return error.ShapeCallbackInvalidCount;
                                }
                            } else {
                                final_glyph_count = glyph_count;
                            }

                            if (!shape_callback_fallback and
                                !shapeClustersValid(bufs.clusters.items, final_glyph_count, scalar_count))
                            {
                                final_glyph_count = setShapingScalarFallback(bufs, core.shaping_col_widths.items[0..scalar_count]);
                                shape_callback_fallback = true;
                            }

                            if (shape_callback_fallback) core.perf_shape_fallback_runs +%= 1;

                            // Store in cache if result fits
                            if (!shape_callback_fallback and final_glyph_count <= nvim_core.SHAPE_CACHE_MAX_GLYPHS) {
                                if (core.shape_cache) |sc_cache| {
                                    // Victim selection when the set is full: derive
                                    // the way from the key hash instead of always
                                    // evicting way 0 — a fixed victim degrades the
                                    // N-way set to direct-mapped under conflict
                                    // (ways 1..N-1 pinned with stale entries).
                                    var sc_store_way: usize = @intCast(sc_hash1 % nvim_core.SHAPE_CACHE_WAYS);
                                    for (0..nvim_core.SHAPE_CACHE_WAYS) |sc_way| {
                                        if (sc_cache[sc_set_base + sc_way].key_hash == 0) {
                                            sc_store_way = sc_way;
                                            break;
                                        }
                                    }
                                    const sc_store = &sc_cache[sc_set_base + sc_store_way];
                                    sc_store.key_hash = sc_hash1;
                                    sc_store.key_hash2 = sc_hash2;
                                    sc_store.font_gen = sc_font_gen;
                                    sc_store.scalar_count = @intCast(scalar_count);
                                    sc_store.glyph_count = @intCast(final_glyph_count);
                                    @memcpy(sc_store.glyph_ids[0..final_glyph_count], bufs.glyph_ids.items[0..final_glyph_count]);
                                    @memcpy(sc_store.clusters[0..final_glyph_count], bufs.clusters.items[0..final_glyph_count]);
                                    @memcpy(sc_store.x_adv[0..final_glyph_count], bufs.x_adv.items[0..final_glyph_count]);
                                    @memcpy(sc_store.x_off[0..final_glyph_count], bufs.x_off.items[0..final_glyph_count]);
                                    @memcpy(sc_store.y_off[0..final_glyph_count], bufs.y_off.items[0..final_glyph_count]);
                                }
                            }
                        }
                    } // end !used_ascii_fast_path

                    var penX: f32 = baseX;

                    // ── ASCII fast emit path ───────────────────────────────────
                    // When the shaping fast path was taken, the run is guaranteed
                    // to be pure ASCII (0x20..0x7E) with no ligature triggers.
                    // That eliminates entire categories of work from the regular
                    // emit loop:
                    //   • cluster grouping (1 cluster == 1 scalar == 1 glyph)
                    //   • emoji detection (no ASCII codepoints are emoji)
                    //   • wide-char handling (ASCII is always single-width)
                    //   • retroactive suppression (no calt → no overhanging glyphs)
                    //   • x_off/y_off math (always zero for fast path)
                    // and lets us use the direct-indexed glyph_cache_ascii (keyed
                    // by scalar*4+style_index) instead of the hashed
                    // glyph_cache_id (keyed by hash(gid, style)).
                    //
                    // Requires: glyph_cache_ascii sized >= 512 (default 512 covers
                    // 128 codepoints × 4 styles). For smaller caches we fall back
                    // to the existing emit loop, which preserves correctness.
                    if (used_ascii_fast_path and glyph_cache_ascii != null and glyph_valid_ascii != null and GLYPH_CACHE_ASCII_SIZE >= 512) {
                        const ge_cache = glyph_cache_ascii.?;
                        const ge_valid = glyph_valid_ascii.?;
                        var gi: u32 = 0;
                        while (gi < final_glyph_count) : (gi += 1) {
                            const cluster_idx: u32 = @intCast(bufs.clusters.items[gi]);
                            const scalar: u32 = core.shaping_scalars.items[cluster_idx];
                            // Cell-based pen advance. Raw HarfBuzz x_adv would be
                            // the font's actual advance (e.g. 7.6 px for Menlo at
                            // size 14) which the renderer ceils to cellW (8 px) in
                            // its grid layout. Accumulating raw advance over many
                            // glyphs would drift content off the cell grid by
                            // ~0.5 px / glyph and shift later cells onto wrong
                            // columns. shaping_col_widths is set to 1 for every
                            // ASCII scalar by the fast-path setup, so a single
                            // cellW step per glyph is exactly correct.
                            const cell_advance: f32 = cellW;

                            // Skip space (very hot in tig — most cells are space)
                            if (scalar == 0x20) {
                                penX += cell_advance;
                                continue;
                            }

                            // Direct index lookup; bounds-safe because guarded
                            // by GLYPH_CACHE_ASCII_SIZE >= 512 above (max key
                            // for ASCII printable + style_index <= 127*4+3 = 511).
                            const cache_key: usize = @as(usize, scalar) * 4 + @as(usize, style_index);
                            var ge: c_api.GlyphEntry = undefined;
                            if (ge_valid[cache_key]) {
                                ge = ge_cache[cache_key];
                            } else {
                                const t_ens: i128 = if (log_glyph_timing) clock.nowNs() else 0;
                                const ge_opt = core.ensureGlyphPhase2(scalar, c_style);
                                if (log_glyph_timing) atlas_ensure_ns_acc += @intCast(@max(0, clock.nowNs() - t_ens));
                                if (ge_opt) |entry| {
                                    ge = entry;
                                    ge_cache[cache_key] = entry;
                                    ge_valid[cache_key] = true;
                                } else {
                                    if (core.flush_aborted) return error.FlushAborted;
                                    stats.had_glyph_miss = true;
                                    if (core.missing_glyph_log_count < 16) {
                                        core.log.write(
                                            "glyph_missing(ascii_fast) row={d} scalar=0x{x}\n",
                                            .{ r, scalar },
                                        );
                                        core.missing_glyph_log_count += 1;
                                    }
                                    penX += cell_advance;
                                    continue;
                                }
                            }

                            // Emit quad. x_off/y_off are 0 for ASCII fast path,
                            // so positioning collapses to bbox-relative only.
                            if (ge.bbox_size_px[0] > 0 and ge.bbox_size_px[1] > 0) {
                                const baselineY: f32 = baseY + ge.ascent_px;
                                const gx0: f32 = penX + ge.bbox_origin_px[0];
                                const gx1: f32 = gx0 + ge.bbox_size_px[0];
                                const gy0: f32 = baselineY - (ge.bbox_origin_px[1] + ge.bbox_size_px[1]);
                                const gy1: f32 = gy0 + ge.bbox_size_px[1];
                                const uv0: [2]f32 = .{ ge.uv_min[0], ge.uv_min[1] };
                                const uv1: [2]f32 = .{ ge.uv_max[0], ge.uv_min[1] };
                                const uv2: [2]f32 = .{ ge.uv_min[0], ge.uv_max[1] };
                                const uv3: [2]f32 = .{ ge.uv_max[0], ge.uv_max[1] };
                                // ASCII is never emoji and the fast path is never
                                // entered for color emoji bitmaps, so DECO_COLOR_EMOJI
                                // is unconditionally off.
                                const deco: u32 = glyph_scroll_flag | (if (run_has_glow) c_api.DECO_GLOW else 0);
                                const t_emit: i128 = if (log_glyph_timing) clock.nowNs() else 0;
                                try ensureRowQuadCapacity(core, out, p.max_vertices, 1);
                                VH.pushGlyphQuadAssumeCapacity(out, gx0, gy0, gx1, gy1, uv0, uv1, uv2, uv3, fg, vw, vh, run_grid_id, deco);
                                if (log_glyph_timing) quad_emit_ns_acc += @intCast(@max(0, clock.nowNs() - t_emit));
                            }

                            penX += cell_advance;
                        }

                        // Atlas reset can happen inside ensureGlyphPhase2 above; the
                        // outer retry loop relies on atlas_reset_during_flush which
                        // we did not touch. Advance the column cursor manually since
                        // we are bypassing the rest of the has_shaping emit body.
                        c = end;
                        continue;
                    }

                    // Dump shaping results for ligature debugging.
                    // Log when shaping was used (not ASCII fast path) — covers both
                    // calt (glyph count == scalar count, IDs differ) and liga (count differs).
                    // Hot-path: gated by core.log.verbose to avoid Foundation alloc churn
                    // (~thousands of calls/sec dominates RSS noise during steady editing).
                    if (log_enabled and core.log.verbose and final_glyph_count > 0 and !used_ascii_fast_path) {
                        core.log.write("[shape_dump] scalars={d} glyphs={d} run=[{d}..{d}) style={d}\n", .{ scalar_count, final_glyph_count, run_start, end, c_style });
                        for (0..@min(final_glyph_count, 16)) |dgi| {
                            core.log.write("[shape_dump]   g[{d}] gid={d} cluster={d} x_adv={d} x_off={d}\n", .{
                                dgi,
                                bufs.glyph_ids.items[dgi],
                                bufs.clusters.items[dgi],
                                bufs.x_adv.items[dgi],
                                bufs.x_off.items[dgi],
                            });
                        }
                        for (0..@min(scalar_count, 16)) |dsi| {
                            core.log.write("[shape_dump]   s[{d}] scalar=0x{x} col_w={d}\n", .{
                                dsi,
                                core.shaping_scalars.items[dsi],
                                core.shaping_col_widths.items[dsi],
                            });
                        }
                    }

                    // Retroactive suppression for calt "last glyph draws all".
                    //
                    // After resolving each glyph in the render loop, we record its
                    // quad position. When a later glyph extends backward by >= 0.75
                    // cellW, we zero out already-emitted quads for preceding glyphs
                    // that: (a) have a DIFFERENT glyph ID (placeholder vs covering),
                    //       (b) fit within their own cell (not intentional overhang).
                    //
                    // This uses the ACTUAL glyph entries from the render loop (not a
                    // separate pre-scan), so atlas state is always correct.
                    const RecentQuad = struct {
                        vert_start: usize,
                        gx0: f32,
                        gx1: f32,
                        penX: f32,
                        cell_adv: f32,
                        gid: u32,
                    };
                    // Circular buffer: only the last RECENT_CAP entries matter
                    // (suppression looks back at most ceil(backward/cellW) ≈ 1-3 cells).
                    const RECENT_CAP = 8;
                    var recent_quads: [RECENT_CAP]RecentQuad = undefined;
                    var recent_quad_total: usize = 0; // total quads ever written (wraps index)

                    var gi: usize = 0;
                    while (gi < final_glyph_count) : (gi += 1) {
                        const gid = bufs.glyph_ids.items[gi];
                        // Callback clusters were validated before cache storage.
                        const scalar_count_u32: u32 = @intCast(scalar_count);
                        const this_cluster = bufs.clusters.items[gi];
                        const next_cluster = if (gi + 1 < final_glyph_count) bufs.clusters.items[gi + 1] else scalar_count_u32;

                        if (gid == 0) {
                            // .notdef glyph — per-scalar fallback
                            var ci: u32 = this_cluster;
                            var fallback_base_x = penX;
                            // src_col of the emoji cluster whose base scalar has
                            // already been composed in this cluster, or null.
                            // Set once the base is processed, whether or not it
                            // produced a quad — a tail must not re-compose either
                            // way.
                            var composed_emoji_src_col: ?u32 = null;
                            while (ci < next_cluster) : (ci += 1) {
                                const fb_scalar = core.shaping_scalars.items[@intCast(ci)];
                                const fb_col_w = core.shaping_col_widths.items[@intCast(ci)];
                                if (fb_col_w != 0) fallback_base_x = penX;
                                if (fb_scalar == 32) {
                                    penX += @as(f32, @floatFromInt(fb_col_w)) * cellW;
                                    continue;
                                }
                                if (block_elements.isBlockElement(fb_scalar)) {
                                    const blk_w = @as(f32, @floatFromInt(fb_col_w)) * cellW;
                                    const blk_geo = block_elements.getBlockGeometry(fb_scalar);
                                    if (blk_geo.count > 0) {
                                        const blk_y0 = @as(f32, @floatFromInt(r)) * cellH;
                                        try ensureRowQuadCapacity(core, out, p.max_vertices, blk_geo.count);
                                        for (blk_geo.rects[0..blk_geo.count]) |rect| {
                                            VH.pushSolidQuadAssumeCapacity(out, penX + rect.x0 * blk_w, blk_y0 + rect.y0 * cellH, penX + rect.x1 * blk_w, blk_y0 + rect.y1 * cellH, fg, vw, vh, run_grid_id, c_api.DECO_SOLID_GLYPH | glyph_scroll_flag);
                                        }
                                    }
                                    penX += blk_w;
                                    continue;
                                }
                                // Set emoji cluster context for .notdef emoji scalars
                                // so the frontend rasterizer can use color emoji path.
                                const fb_src_col = core.shaping_src_cols.items[@intCast(ci)];
                                const fb_is_emoji = isEmojiPresentation(fb_scalar) or cellIsEmojiCluster(core, rc, r, fb_src_col);
                                if (fb_is_emoji) {
                                    // Continuation scalars of an emoji cluster (ZWJ,
                                    // VS16, the trailing symbols of a ZWJ sequence)
                                    // are appended with col_width 0 and the base
                                    // cell's src_col. The base scalar already composed
                                    // and drew the whole cluster, and fallback_base_x
                                    // does not advance for zero-width scalars, so
                                    // re-composing from a tail would rebuild a bogus
                                    // cluster and draw it over the real one.
                                    if (fb_col_w == 0) {
                                        if (composed_emoji_src_col) |base_col| {
                                            if (base_col == fb_src_col) continue;
                                        }
                                    }
                                    setEmojiClusterFromOverflow(core, rc, r, fb_src_col, fb_scalar);
                                    composed_emoji_src_col = fb_src_col;
                                }
                                defer core.emoji_cluster_len = 0;

                                // Cache this scalar like the single-cluster
                                // fallback below does. A script the primary
                                // font does not cover (CJK in a Latin font)
                                // shapes to .notdef for EVERY cell, so without
                                // this every occurrence of every glyph was
                                // rasterized again on every regeneration —
                                // a full-viewport pass cost thousands of
                                // rasterizations that the atlas already held.
                                //
                                // Emoji are cached on the same key, which is
                                // sound because the key already names
                                // everything the bitmap depends on. The
                                // rasterizer receives either fb_scalar alone or
                                // the cluster buildEmojiCluster assembles from
                                // (fb_scalar, fb_extras); which of the two is
                                // chosen is fb_is_emoji, and that is
                                // isEmojiPresentation(fb_scalar) or
                                // extrasMarkEmojiCluster(fb_extras). Both
                                // branches, and the choice between them, are
                                // therefore functions of the same values the
                                // key folds in — equal keys cannot name
                                // different pictures. Pinned by the cluster-key
                                // and rasterizer-input tests at the end of this
                                // file, and on the glass by the test/gui
                                // scenario visual/emoji_cluster_cache.
                                const fb_extras = getOverflowForCell(core, rc, r, fb_src_col);
                                const fb_cache_key = clusterCacheKey(fb_scalar, style_index, fb_extras);
                                const fb_cache_hash = clusterCacheHash(fb_scalar, style_index, fb_extras);
                                const fb_cacheable = glyph_cache_non_ascii != null and
                                    glyph_keys_non_ascii != null and
                                    GLYPH_CACHE_NON_ASCII_SIZE > 0;
                                var fb_ge_opt: ?c_api.GlyphEntry = null;
                                if (fb_cacheable) {
                                    const probe = nvim_core.glyphCacheProbe(glyph_keys_non_ascii.?, fb_cache_key, fb_cache_hash);
                                    if (probe.hit) |hit_idx| fb_ge_opt = glyph_cache_non_ascii.?[hit_idx];
                                }
                                const fb_t_ens: i128 = if (log_glyph_timing) clock.nowNs() else 0;
                                if (fb_ge_opt == null) {
                                    fb_ge_opt = core.ensureGlyphPhase2(fb_scalar, c_style);
                                    if (fb_cacheable) {
                                        if (fb_ge_opt) |entry| {
                                            const probe = nvim_core.glyphCacheProbe(glyph_keys_non_ascii.?, fb_cache_key, fb_cache_hash);
                                            glyph_cache_non_ascii.?[probe.insert] = entry;
                                            glyph_keys_non_ascii.?[probe.insert] = fb_cache_key;
                                        }
                                    }
                                }
                                if (log_glyph_timing) atlas_ensure_ns_acc += @intCast(@max(0, clock.nowNs() - fb_t_ens));
                                if (fb_ge_opt) |fb_ge| {
                                    if (fb_ge.bbox_size_px[0] > 0 and fb_ge.bbox_size_px[1] > 0) {
                                        const fb_baselineY: f32 = baseY + fb_ge.ascent_px;
                                        const fb_gx0: f32 = fallback_base_x + fb_ge.bbox_origin_px[0];
                                        const fb_gx1: f32 = fb_gx0 + fb_ge.bbox_size_px[0];
                                        const fb_gy0: f32 = fb_baselineY - (fb_ge.bbox_origin_px[1] + fb_ge.bbox_size_px[1]);
                                        const fb_gy1: f32 = fb_gy0 + fb_ge.bbox_size_px[1];

                                        const fb_uv0: [2]f32 = .{ fb_ge.uv_min[0], fb_ge.uv_min[1] };
                                        const fb_uv1: [2]f32 = .{ fb_ge.uv_max[0], fb_ge.uv_min[1] };
                                        const fb_uv2: [2]f32 = .{ fb_ge.uv_min[0], fb_ge.uv_max[1] };
                                        const fb_uv3: [2]f32 = .{ fb_ge.uv_max[0], fb_ge.uv_max[1] };

                                        const fb_glyph_deco: u32 = glyph_scroll_flag | (if (run_has_glow) c_api.DECO_GLOW else 0) | (if (fb_ge.bytes_per_pixel >= 4) c_api.DECO_COLOR_EMOJI else 0);
                                        const fb_t_emit: i128 = if (log_glyph_timing) clock.nowNs() else 0;
                                        try ensureRowQuadCapacity(core, out, p.max_vertices, 1);
                                        VH.pushGlyphQuadAssumeCapacity(out, fb_gx0, fb_gy0, fb_gx1, fb_gy1, fb_uv0, fb_uv1, fb_uv2, fb_uv3, fg, vw, vh, run_grid_id, fb_glyph_deco);
                                        if (log_glyph_timing) quad_emit_ns_acc += @intCast(@max(0, clock.nowNs() - fb_t_emit));
                                    }
                                } else {
                                    if (core.flush_aborted) return error.FlushAborted;
                                    stats.had_glyph_miss = true;
                                }
                                penX += @as(f32, @floatFromInt(fb_col_w)) * cellW;
                            }
                            continue;
                        }

                        // Skip space glyphs
                        if (next_cluster == this_cluster + 1) {
                            const sp_scalar = core.shaping_scalars.items[@intCast(this_cluster)];
                            if (sp_scalar == 0x20) {
                                penX += @as(f32, @floatFromInt(core.shaping_col_widths.items[@intCast(this_cluster)])) * cellW;
                                continue;
                            }
                            if (block_elements.isBlockElement(sp_scalar)) {
                                const blk_cols = core.shaping_col_widths.items[@intCast(this_cluster)];
                                const blk_w = @as(f32, @floatFromInt(blk_cols)) * cellW;
                                const blk_geo = block_elements.getBlockGeometry(sp_scalar);
                                if (blk_geo.count > 0) {
                                    const blk_y0 = @as(f32, @floatFromInt(r)) * cellH;
                                    try ensureRowQuadCapacity(core, out, p.max_vertices, blk_geo.count);
                                    for (blk_geo.rects[0..blk_geo.count]) |rect| {
                                        VH.pushSolidQuadAssumeCapacity(out, penX + rect.x0 * blk_w, blk_y0 + rect.y0 * cellH, penX + rect.x1 * blk_w, blk_y0 + rect.y1 * cellH, fg, vw, vh, run_grid_id, c_api.DECO_SOLID_GLYPH | glyph_scroll_flag);
                                    }
                                }
                                penX += blk_w;
                                continue;
                            }
                        }

                        // Glyph-ID cache lookup.
                        // Skip glyph-by-ID for .notdef (gid==0) and emoji codepoints.
                        // Emoji should go through per-scalar fallback (ensureGlyphPhase2)
                        // so the frontend can render with system color emoji
                        // (D2D + Segoe UI Emoji on Windows, CoreGraphics on macOS).
                        var ge: c_api.GlyphEntry = undefined;
                        const first_scalar: u32 = core.shaping_scalars.items[@intCast(this_cluster)];
                        // Check if this cell has VS16 in its overflow map (e.g., ⚠️ = U+26A0 + U+FE0F)
                        const src_col = core.shaping_src_cols.items[@intCast(this_cluster)];
                        const cell_is_emoji_cluster = cellIsEmojiCluster(core, rc, r, src_col);
                        const cluster_is_emoji = isEmojiPresentation(first_scalar) or cell_is_emoji_cluster;
                        var glyph_ok = gid_blk: {
                            if (gid == 0 or cluster_is_emoji) {
                                break :gid_blk false;
                            }
                            if (glyph_cache_id != null and glyph_keys_id != null and GLYPH_CACHE_NON_ASCII_SIZE > 0) {
                                const key = (@as(u64, gid) << 2) | @as(u64, style_index);
                                const hash_val = (gid *% 2654435761) ^ style_index;
                                const probe = nvim_core.glyphCacheProbe(glyph_keys_id.?, key, hash_val);
                                if (probe.hit) |hit_idx| {
                                    ge = glyph_cache_id.?[hit_idx];
                                    break :gid_blk true;
                                }
                                const t_ens_gid1: i128 = if (log_glyph_timing) clock.nowNs() else 0;
                                const ent1_opt = core.ensureGlyphByID(gid, c_style);
                                if (log_glyph_timing) atlas_ensure_ns_acc += @intCast(@max(0, clock.nowNs() - t_ens_gid1));
                                if (ent1_opt) |entry| {
                                    ge = entry;
                                    glyph_cache_id.?[probe.insert] = entry;
                                    glyph_keys_id.?[probe.insert] = key;
                                    break :gid_blk true;
                                }
                                if (core.flush_aborted) return error.FlushAborted;
                                break :gid_blk false;
                            }
                            const t_ens_gid2: i128 = if (log_glyph_timing) clock.nowNs() else 0;
                            const ent2_opt = core.ensureGlyphByID(gid, c_style);
                            if (log_glyph_timing) atlas_ensure_ns_acc += @intCast(@max(0, clock.nowNs() - t_ens_gid2));
                            if (ent2_opt) |entry| {
                                ge = entry;
                                break :gid_blk true;
                            }
                            if (core.flush_aborted) return error.FlushAborted;
                            break :gid_blk false;
                        };

                        // If glyph-by-ID failed or produced an empty bitmap, try per-scalar fallback.
                        // For single-scalar clusters: always try fallback (handles .notdef, missing glyphs).
                        // For multi-scalar clusters: try fallback if cluster is emoji
                        // (ZWJ sequences, flag sequences, VS16 emoji need color emoji rendering).
                        // Store full cluster scalars so the frontend rasterizer can render
                        // the complete emoji sequence (not just the first scalar).
                        const glyph_empty = glyph_ok and (ge.bbox_size_px[0] <= 0 or ge.bbox_size_px[1] <= 0);
                        if ((!glyph_ok or glyph_empty) and (next_cluster == this_cluster + 1 or cluster_is_emoji)) {
                            if (first_scalar != 0 and first_scalar != 0x20) {
                                // Build cache key that includes the full cluster content
                                // (base scalar + overflow extras) so different emoji clusters
                                // with the same first scalar (e.g., 👩‍💻 vs 👩‍🔬) get distinct entries.
                                const overflow_extras = getOverflowForCell(core, rc, r, src_col);
                                const fb_key = clusterCacheKey(first_scalar, style_index, overflow_extras);
                                const fb_hash = clusterCacheHash(first_scalar, style_index, overflow_extras);

                                // No single-scalar restriction: the key folds in
                                // the cell's overflow extras, which is exactly
                                // what buildEmojiCluster hands the rasterizer
                                // below, so a multi-scalar cluster keys as
                                // precisely as a single-scalar one.
                                const fb_cached = if (glyph_cache_non_ascii != null and glyph_keys_non_ascii != null and GLYPH_CACHE_NON_ASCII_SIZE > 0) blk: {
                                    const probe = nvim_core.glyphCacheProbe(glyph_keys_non_ascii.?, fb_key, fb_hash);
                                    if (probe.hit) |hit_idx| {
                                        ge = glyph_cache_non_ascii.?[hit_idx];
                                        break :blk true;
                                    }
                                    break :blk false;
                                } else false;

                                if (fb_cached) {
                                    glyph_ok = true;
                                } else {
                                    // Set cluster context for emoji so the frontend rasterizer
                                    // uses color emoji path. Uses overflow map for VS16 sequences.
                                    if (cluster_is_emoji) {
                                        setEmojiClusterFromOverflow(core, rc, r, src_col, first_scalar);
                                    }
                                    defer core.emoji_cluster_len = 0;

                                    if (core.ensureGlyphPhase2(first_scalar, c_style)) |fb_ge| {
                                        ge = fb_ge;
                                        glyph_ok = true;
                                        // Store in non-ASCII cache for subsequent rows
                                        if (glyph_cache_non_ascii != null and glyph_keys_non_ascii != null and GLYPH_CACHE_NON_ASCII_SIZE > 0) {
                                            const probe = nvim_core.glyphCacheProbe(glyph_keys_non_ascii.?, fb_key, fb_hash);
                                            glyph_cache_non_ascii.?[probe.insert] = fb_ge;
                                            glyph_keys_non_ascii.?[probe.insert] = fb_key;
                                        }
                                    } else if (core.flush_aborted) {
                                        return error.FlushAborted;
                                    }
                                }
                            }
                        }

                        // Multi-scalar non-emoji fallback: if glyph-by-ID failed OR
                        // returned an empty (0x0) bitmap for a ligature cluster, render
                        // each scalar individually to prevent invisible glyphs where the
                        // ligature should appear. Checking glyph_empty too (not just
                        // !glyph_ok) matches the single-scalar/emoji branch above —
                        // without it, a ligature glyph ID that resolves but rasterizes
                        // to nothing silently renders as blank instead of falling back.
                        if ((!glyph_ok or glyph_empty) and next_cluster > this_cluster + 1 and !cluster_is_emoji) {
                            var mci: u32 = this_cluster;
                            var mc_base_x = penX;
                            while (mci < next_cluster) : (mci += 1) {
                                const mc_scalar = core.shaping_scalars.items[@intCast(mci)];
                                const mc_col_w = core.shaping_col_widths.items[@intCast(mci)];
                                // Zero-width overflow scalars (combining marks,
                                // VS selectors) belong at the preceding base
                                // cell origin even after that base advanced penX.
                                if (mc_col_w != 0) mc_base_x = penX;
                                if (mc_scalar == 32 or mc_scalar == 0) {
                                    penX += @as(f32, @floatFromInt(mc_col_w)) * cellW;
                                    continue;
                                }
                                const mc_t_ens: i128 = if (log_glyph_timing) clock.nowNs() else 0;
                                const mc_ge_opt = core.ensureGlyphPhase2(mc_scalar, c_style);
                                if (log_glyph_timing) atlas_ensure_ns_acc += @intCast(@max(0, clock.nowNs() - mc_t_ens));
                                if (mc_ge_opt) |mc_ge| {
                                    if (mc_ge.bbox_size_px[0] > 0 and mc_ge.bbox_size_px[1] > 0) {
                                        const mc_baselineY: f32 = baseY + mc_ge.ascent_px;
                                        const mc_gx0: f32 = mc_base_x + mc_ge.bbox_origin_px[0];
                                        const mc_gx1: f32 = mc_gx0 + mc_ge.bbox_size_px[0];
                                        const mc_gy0: f32 = mc_baselineY - (mc_ge.bbox_origin_px[1] + mc_ge.bbox_size_px[1]);
                                        const mc_gy1: f32 = mc_gy0 + mc_ge.bbox_size_px[1];
                                        const mc_uv0: [2]f32 = .{ mc_ge.uv_min[0], mc_ge.uv_min[1] };
                                        const mc_uv1: [2]f32 = .{ mc_ge.uv_max[0], mc_ge.uv_min[1] };
                                        const mc_uv2: [2]f32 = .{ mc_ge.uv_min[0], mc_ge.uv_max[1] };
                                        const mc_uv3: [2]f32 = .{ mc_ge.uv_max[0], mc_ge.uv_max[1] };
                                        const mc_deco: u32 = glyph_scroll_flag | (if (run_has_glow) c_api.DECO_GLOW else 0) | (if (mc_ge.bytes_per_pixel >= 4) c_api.DECO_COLOR_EMOJI else 0);
                                        const mc_t_emit: i128 = if (log_glyph_timing) clock.nowNs() else 0;
                                        try ensureRowQuadCapacity(core, out, p.max_vertices, 1);
                                        VH.pushGlyphQuadAssumeCapacity(out, mc_gx0, mc_gy0, mc_gx1, mc_gy1, mc_uv0, mc_uv1, mc_uv2, mc_uv3, fg, vw, vh, run_grid_id, mc_deco);
                                        if (log_glyph_timing) quad_emit_ns_acc += @intCast(@max(0, clock.nowNs() - mc_t_emit));
                                    }
                                } else {
                                    if (core.flush_aborted) return error.FlushAborted;
                                    stats.had_glyph_miss = true;
                                }
                                penX += @as(f32, @floatFromInt(mc_col_w)) * cellW;
                            }
                            continue;
                        }

                        if (!glyph_ok) stats.had_glyph_miss = true;

                        // Advance pen using column widths
                        const cl_span = next_cluster - this_cluster;
                        const cluster_cols: u32 = if (cl_span == 1)
                            core.shaping_col_widths.items[@intCast(this_cluster)]
                        else blk: {
                            var sum: u32 = 0;
                            var cwi: u32 = this_cluster;
                            while (cwi < next_cluster) : (cwi += 1) {
                                sum += core.shaping_col_widths.items[@intCast(cwi)];
                            }
                            break :blk sum;
                        };
                        const cell_advance: f32 = @as(f32, @floatFromInt(cluster_cols)) * cellW;

                        if (glyph_ok and ge.bbox_size_px[0] > 0 and ge.bbox_size_px[1] > 0) {
                            const x_off_px = vertexgen.fixed26_6ToPx(bufs.x_off.items[gi]);
                            const y_off_px = vertexgen.fixed26_6ToPx(bufs.y_off.items[gi]);
                            const baselineY: f32 = baseY + ge.ascent_px;

                            const gx0: f32 = penX + ge.bbox_origin_px[0] + x_off_px;
                            const gx1: f32 = gx0 + ge.bbox_size_px[0];
                            const gy0: f32 = (baselineY + y_off_px) - (ge.bbox_origin_px[1] + ge.bbox_size_px[1]);
                            const gy1: f32 = gy0 + ge.bbox_size_px[1];

                            const uv0: [2]f32 = .{ ge.uv_min[0], ge.uv_min[1] };
                            const uv1: [2]f32 = .{ ge.uv_max[0], ge.uv_min[1] };
                            const uv2: [2]f32 = .{ ge.uv_min[0], ge.uv_max[1] };
                            const uv3: [2]f32 = .{ ge.uv_max[0], ge.uv_max[1] };

                            // Retroactive suppression: if this glyph extends backward
                            // by >= 0.75*cellW, zero out preceding quads that have a
                            // DIFFERENT glyph ID and fit within their cell.
                            const backward_px = penX - gx0;
                            // Threshold 0.35: covers || (38%), <= (53%), -- (76%),
                            // == (88%), === (188%) while excluding normal overhang
                            // (all observed normal glyphs have backward <= 0).
                            const recent_count = @min(recent_quad_total, RECENT_CAP);
                            if (backward_px >= cellW * 0.35 and recent_count > 0) {
                                const back_cells = @min(
                                    recent_count,
                                    @as(usize, @intFromFloat(@ceil(backward_px / cellW))),
                                );
                                var rqi: usize = 0;
                                while (rqi < back_cells) : (rqi += 1) {
                                    // Walk backward through the circular buffer
                                    const idx = (recent_quad_total - 1 - rqi) % RECENT_CAP;
                                    const rq = recent_quads[idx];
                                    // Different gid → placeholder, not same visual form
                                    if (rq.gid == gid) continue;
                                    // Must fit in its cell (not intentional overhang)
                                    if (rq.gx0 < rq.penX - 1.0) continue;
                                    if (rq.gx1 > rq.penX + rq.cell_adv + 1.0) continue;
                                    // Covering glyph bitmap must reach this cell
                                    if (gx0 < rq.penX + rq.cell_adv and gx1 > rq.penX) {
                                        // Zero out the 6 vertices
                                        if (rq.vert_start + 6 <= out.items.len) {
                                            for (0..6) |k| {
                                                out.items[rq.vert_start + k].position = .{ 0, 0 };
                                                out.items[rq.vert_start + k].texCoord = .{ -1, -1 };
                                            }
                                        }
                                    }
                                }
                            }

                            // Hot-path: gated by core.log.verbose (per-glyph debug).
                            if (log_enabled and core.log.verbose and !used_ascii_fast_path) {
                                core.log.write("[glyph_quad] gi={d} gid={d} penX={d:.1} gx0={d:.1} gx1={d:.1} bbox_w={d:.1} bbox_ox={d:.1} x_off={d:.1} cellW={d:.1}\n", .{
                                    gi, gid, penX, gx0, gx1, ge.bbox_size_px[0], ge.bbox_origin_px[0], x_off_px, cellW,
                                });
                            }

                            // Record quad for potential retroactive suppression by later glyphs
                            const vert_start = out.items.len;
                            const glyph_deco: u32 = glyph_scroll_flag | (if (run_has_glow) c_api.DECO_GLOW else 0) | (if (ge.bytes_per_pixel >= 4) c_api.DECO_COLOR_EMOJI else 0);
                            const sg_t_emit: i128 = if (log_glyph_timing) clock.nowNs() else 0;
                            try ensureRowQuadCapacity(core, out, p.max_vertices, 1);
                            VH.pushGlyphQuadAssumeCapacity(out, gx0, gy0, gx1, gy1, uv0, uv1, uv2, uv3, fg, vw, vh, run_grid_id, glyph_deco);
                            if (log_glyph_timing) quad_emit_ns_acc += @intCast(@max(0, clock.nowNs() - sg_t_emit));

                            recent_quads[recent_quad_total % RECENT_CAP] = .{
                                .vert_start = vert_start,
                                .gx0 = gx0,
                                .gx1 = gx1,
                                .penX = penX,
                                .cell_adv = cell_advance,
                                .gid = gid,
                            };
                            recent_quad_total += 1;
                        }

                        // Advance pen
                        penX += cell_advance;
                    }
                } else {
                    // --- Per-cell glyph path (fallback when shaping unavailable) ---
                    var penX: f32 = baseX;

                    var col_i: u32 = run_start;
                    while (col_i < end) : (col_i += 1) {
                        const cell_scalar = rc.scalars.items[@intCast(col_i)];
                        const cell_style_flags = rc.style_flags_arr.items[@intCast(col_i)];
                        const scalar: u32 = if (cell_scalar == 0) 32 else cell_scalar;
                        const overflow = getOverflowForCell(core, rc, r, col_i);
                        const has_overflow = if (overflow) |extras| extras.len != 0 else false;
                        if (scalar == 32 and !has_overflow) {
                            penX += cellW;
                            continue;
                        }
                        if (!has_overflow and block_elements.isBlockElement(scalar)) {
                            // Neovim represents a double-width cell as its base
                            // scalar followed by a zero continuation. Geometry
                            // spans both cells even when the continuation starts
                            // a different style/color run; its own iteration
                            // still advances penX by the second cell below.
                            const blk_cell_w = if (col_i + 1 < cols and
                                rc.scalars.items[@intCast(col_i + 1)] == 0)
                                cellW * 2
                            else
                                cellW;
                            const blk_geo = block_elements.getBlockGeometry(scalar);
                            if (blk_geo.count > 0) {
                                const blk_y0 = @as(f32, @floatFromInt(r)) * cellH;
                                try ensureRowQuadCapacity(core, out, p.max_vertices, blk_geo.count);
                                for (blk_geo.rects[0..blk_geo.count]) |rect| {
                                    VH.pushSolidQuadAssumeCapacity(out, penX + rect.x0 * blk_cell_w, blk_y0 + rect.y0 * cellH, penX + rect.x1 * blk_cell_w, blk_y0 + rect.y1 * cellH, VH.rgb(run_fg), vw, vh, run_grid_id, c_api.DECO_SOLID_GLYPH | glyph_scroll_flag);
                                }
                            }
                            penX += cellW;
                            continue;
                        }

                        var ge: c_api.GlyphEntry = undefined;
                        const style_mask = cell_style_flags & (STYLE_BOLD | STYLE_ITALIC);
                        const style_index: u32 = @as(u32, if (cell_style_flags & STYLE_BOLD != 0) @as(u32, 1) else 0) +
                            @as(u32, if (cell_style_flags & STYLE_ITALIC != 0) @as(u32, 2) else 0);
                        const glyph_ok = blk: {
                            // Phase 2 must key and rasterize the complete cell
                            // cluster even when shaping callbacks are absent.
                            // Otherwise VS16/ZWJ variants sharing a base scalar
                            // alias in the scalar-only cache.
                            if (core.isPhase2Atlas()) {
                                const cs: u32 = @as(u32, if (cell_style_flags & STYLE_BOLD != 0) c_api.STYLE_BOLD else 0) |
                                    @as(u32, if (cell_style_flags & STYLE_ITALIC != 0) c_api.STYLE_ITALIC else 0);
                                defer core.emoji_cluster_len = 0;
                                if (try ensureCachedPhase2Glyph(core, scalar, cs, overflow)) |entry| {
                                    ge = entry;
                                    break :blk true;
                                }
                                break :blk false;
                            }
                            if (scalar < 128 and glyph_cache_ascii != null and glyph_valid_ascii != null) {
                                const cache_key: usize = scalar * 4 + style_index;
                                if (cache_key < GLYPH_CACHE_ASCII_SIZE) {
                                    if (glyph_valid_ascii.?[cache_key]) {
                                        ge = glyph_cache_ascii.?[cache_key];
                                        break :blk true;
                                    }
                                    const a_t_ens: i128 = if (log_glyph_timing) clock.nowNs() else 0;
                                    const ok = if (style_mask != 0 and ensure_styled != null) cb: {
                                        const cs: u32 = @as(u32, if (cell_style_flags & STYLE_BOLD != 0) c_api.STYLE_BOLD else 0) |
                                            @as(u32, if (cell_style_flags & STYLE_ITALIC != 0) c_api.STYLE_ITALIC else 0);
                                        break :cb ensure_styled.?(core.ctx, scalar, cs, &ge) != 0;
                                    } else if (ensure_base) |ensure| cb: {
                                        break :cb ensure(core.ctx, scalar, &ge) != 0;
                                    } else false;
                                    if (log_glyph_timing) atlas_ensure_ns_acc += @intCast(@max(0, clock.nowNs() - a_t_ens));
                                    if (ok) {
                                        glyph_cache_ascii.?[cache_key] = ge;
                                        glyph_valid_ascii.?[cache_key] = true;
                                    }
                                    break :blk ok;
                                }
                            }
                            if (glyph_cache_non_ascii != null and glyph_keys_non_ascii != null and GLYPH_CACHE_NON_ASCII_SIZE > 0) {
                                const key = (@as(u64, scalar) << 2) | @as(u64, style_index);
                                const hash_val = (scalar *% 2654435761) ^ style_index;
                                const probe = nvim_core.glyphCacheProbe(glyph_keys_non_ascii.?, key, hash_val);
                                if (probe.hit) |hit_idx| {
                                    ge = glyph_cache_non_ascii.?[hit_idx];
                                    break :blk true;
                                }
                                const na_t_ens: i128 = if (log_glyph_timing) clock.nowNs() else 0;
                                const ok = if (style_mask != 0 and ensure_styled != null) cb: {
                                    const cs: u32 = @as(u32, if (cell_style_flags & STYLE_BOLD != 0) c_api.STYLE_BOLD else 0) |
                                        @as(u32, if (cell_style_flags & STYLE_ITALIC != 0) c_api.STYLE_ITALIC else 0);
                                    break :cb ensure_styled.?(core.ctx, scalar, cs, &ge) != 0;
                                } else if (ensure_base) |ensure| cb: {
                                    break :cb ensure(core.ctx, scalar, &ge) != 0;
                                } else false;
                                if (log_glyph_timing) atlas_ensure_ns_acc += @intCast(@max(0, clock.nowNs() - na_t_ens));
                                if (ok) {
                                    glyph_cache_non_ascii.?[probe.insert] = ge;
                                    glyph_keys_non_ascii.?[probe.insert] = key;
                                }
                                break :blk ok;
                            }
                            const lf_t_ens: i128 = if (log_glyph_timing) clock.nowNs() else 0;
                            const ok = if (style_mask != 0 and ensure_styled != null) cb: {
                                const cs: u32 = @as(u32, if (cell_style_flags & STYLE_BOLD != 0) c_api.STYLE_BOLD else 0) |
                                    @as(u32, if (cell_style_flags & STYLE_ITALIC != 0) c_api.STYLE_ITALIC else 0);
                                break :cb ensure_styled.?(core.ctx, scalar, cs, &ge) != 0;
                            } else if (ensure_base) |ensure| cb: {
                                break :cb ensure(core.ctx, scalar, &ge) != 0;
                            } else false;
                            if (log_glyph_timing) atlas_ensure_ns_acc += @intCast(@max(0, clock.nowNs() - lf_t_ens));
                            break :blk ok;
                        };
                        if (!glyph_ok) {
                            if (core.flush_aborted) return error.FlushAborted;
                            stats.had_glyph_miss = true;
                            if (core.missing_glyph_log_count < 16) {
                                core.log.write(
                                    "glyph_missing row={d} col={d} scalar=0x{x}\n",
                                    .{ r, col_i, scalar },
                                );
                                core.missing_glyph_log_count += 1;
                            }
                            penX += cellW;
                            continue;
                        }

                        const baselineY: f32 = baseY + ge.ascent_px;
                        const gx0: f32 = penX + ge.bbox_origin_px[0];
                        const gx1: f32 = gx0 + ge.bbox_size_px[0];
                        const gy0: f32 = (baselineY) - (ge.bbox_origin_px[1] + ge.bbox_size_px[1]);
                        const gy1: f32 = gy0 + ge.bbox_size_px[1];

                        const uv0: [2]f32 = .{ ge.uv_min[0], ge.uv_min[1] };
                        const uv1: [2]f32 = .{ ge.uv_max[0], ge.uv_min[1] };
                        const uv2: [2]f32 = .{ ge.uv_min[0], ge.uv_max[1] };
                        const uv3: [2]f32 = .{ ge.uv_max[0], ge.uv_max[1] };

                        if (ge.bbox_size_px[0] > 0 and ge.bbox_size_px[1] > 0) {
                            const pc_glyph_deco: u32 = glyph_scroll_flag | (if (run_has_glow) c_api.DECO_GLOW else 0) | (if (ge.bytes_per_pixel >= 4) c_api.DECO_COLOR_EMOJI else 0);
                            const pc_t_emit: i128 = if (log_glyph_timing) clock.nowNs() else 0;
                            try ensureRowQuadCapacity(core, out, p.max_vertices, 1);
                            VH.pushGlyphQuadAssumeCapacity(out, gx0, gy0, gx1, gy1, uv0, uv1, uv2, uv3, fg, vw, vh, run_grid_id, pc_glyph_deco);
                            if (log_glyph_timing) quad_emit_ns_acc += @intCast(@max(0, clock.nowNs() - pc_t_emit));
                        }

                        penX += cellW;
                    }
                } // end else (per-cell fallback)
            }

            c = end;
        }
    }
    if (log_enabled) stats.glyph_ns = @intCast(@max(0, clock.nowNs() - t_glyph_start));
    stats.pass_ends[2] = out.items.len - out_start;

    // ── Pass 4: Strikethrough ───────────────────────────────────────
    {
        const t_strike_start: i128 = if (log_enabled) clock.nowNs() else 0;
        var c: u32 = 0;
        while (c < cols) {
            const c_style_flags = rc.style_flags_arr.items[@intCast(c)];
            if (c_style_flags & STYLE_STRIKETHROUGH == 0) {
                c += 1;
                continue;
            }

            const run_start = c;
            const run_flags = c_style_flags;
            const run_sp = rc.sp_rgbs.items[@intCast(c)];
            const run_fg = rc.fg_rgbs.items[@intCast(c)];
            const run_grid_id = rc.grid_ids.items[@intCast(c)];
            const run_deco = rc.deco_base_flags.items[@intCast(c)];

            const fg_run_end: u32 = if (run_sp == highlight.Highlights.SP_NOT_SET)
                @intCast(simdFindRunEndU32(rc.fg_rgbs.items, @intCast(c + 1), @intCast(cols), run_fg))
            else
                cols;

            const run_end: u32 = @intCast(@min(
                simdFindRunEndU8(rc.style_flags_arr.items, @intCast(c + 1), @intCast(cols), run_flags),
                @min(
                    simdFindRunEndU32(rc.sp_rgbs.items, @intCast(c + 1), @intCast(cols), run_sp),
                    @min(
                        simdFindRunEndI64(rc.grid_ids.items, @intCast(c + 1), @intCast(cols), run_grid_id),
                        @min(
                            simdFindRunEndU32(rc.deco_base_flags.items, @intCast(c + 1), @intCast(cols), run_deco),
                            fg_run_end,
                        ),
                    ),
                ),
            ));

            const deco_color = if (run_sp != highlight.Highlights.SP_NOT_SET) VH.rgb(run_sp) else VH.rgb(run_fg);
            const strike_scroll_flag: u32 = run_deco;
            const x0: f32 = @as(f32, @floatFromInt(run_start)) * cellW;
            const x1: f32 = @as(f32, @floatFromInt(run_end)) * cellW;
            const row_y: f32 = @as(f32, @floatFromInt(r)) * cellH;

            const sy0 = row_y + cellH * 0.5 - 0.5;
            const sy1 = sy0 + 1.0;
            try ensureRowQuadCapacity(core, out, p.max_vertices, 1);
            try VH.pushDecoQuad(out, core.alloc, x0, sy0, x1, sy1, deco_color, vw, vh, run_grid_id, c_api.DECO_STRIKETHROUGH | strike_scroll_flag, 0);

            c = run_end;
        }
        if (log_enabled) stats.strike_ns = @intCast(@max(0, clock.nowNs() - t_strike_start));
    }
    stats.pass_ends[3] = out.items.len - out_start;

    // ── Pass 5: Overline ────────────────────────────────────────────
    {
        const t_overline_start: i128 = if (log_enabled) clock.nowNs() else 0;
        var c: u32 = 0;
        while (c < cols) {
            if (rc.overline_arr.items[@intCast(c)] == 0) {
                c += 1;
                continue;
            }

            const run_start = c;
            const run_sp = rc.sp_rgbs.items[@intCast(c)];
            const run_fg = rc.fg_rgbs.items[@intCast(c)];
            const run_grid_id = rc.grid_ids.items[@intCast(c)];
            const run_deco = rc.deco_base_flags.items[@intCast(c)];

            var run_end: u32 = c + 1;
            while (run_end < cols) : (run_end += 1) {
                if (rc.overline_arr.items[@intCast(run_end)] == 0) break;
                if (rc.sp_rgbs.items[@intCast(run_end)] != run_sp) break;
                if (rc.grid_ids.items[@intCast(run_end)] != run_grid_id) break;
                if (rc.deco_base_flags.items[@intCast(run_end)] != run_deco) break;
                if (run_sp == highlight.Highlights.SP_NOT_SET and
                    rc.fg_rgbs.items[@intCast(run_end)] != run_fg) break;
            }

            const deco_color = if (run_sp != highlight.Highlights.SP_NOT_SET) VH.rgb(run_sp) else VH.rgb(run_fg);
            const ol_scroll_flag: u32 = run_deco;
            const x0: f32 = @as(f32, @floatFromInt(run_start)) * cellW;
            const x1: f32 = @as(f32, @floatFromInt(run_end)) * cellW;
            const row_y: f32 = @as(f32, @floatFromInt(r)) * cellH;

            const oy0 = row_y;
            const oy1 = oy0 + 1.0;
            try ensureRowQuadCapacity(core, out, p.max_vertices, 1);
            try VH.pushDecoQuad(out, core.alloc, x0, oy0, x1, oy1, deco_color, vw, vh, run_grid_id, c_api.DECO_OVERLINE | ol_scroll_flag, 0);

            c = run_end;
        }
        if (log_enabled) stats.overline_ns = @intCast(@max(0, clock.nowNs() - t_overline_start));
    }
    stats.pass_ends[4] = out.items.len - out_start;

    if (log_enabled) {
        stats.atlas_ensure_ns = atlas_ensure_ns_acc;
        stats.quad_emit_ns = quad_emit_ns_acc;
    }
    return stats;
}

const GridRowScrollCallback = *const fn (
    ctx: ?*anyopaque,
    grid_id: i64,
    row_start: u32,
    row_end: u32,
    col_start: u32,
    col_end: u32,
    rows_delta: i32,
    total_rows: u32,
    total_cols: u32,
) callconv(.c) void;

const ExternalScrollFastPathRegion = struct {
    row_start: u32,
    row_end: u32,
    col_start: u32,
    col_end: u32,
};

fn externalFloatAnchorEntries(
    entries: []const ExternalFloatAnchorEntry,
    anchor_grid_id: i64,
) []const ExternalFloatAnchorEntry {
    var lo: usize = 0;
    var hi: usize = entries.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (entries[mid].anchor_grid_id < anchor_grid_id) lo = mid + 1 else hi = mid;
    }
    const start = lo;
    hi = entries.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (entries[mid].anchor_grid_id <= anchor_grid_id) lo = mid + 1 else hi = mid;
    }
    return entries[start..lo];
}

fn externalScrollFastPathRegion(
    op: grid_mod.ScrollDelta,
    grid_rows: u32,
    grid_cols: u32,
    viewport_rows: u32,
    viewport_cols: u32,
) ?ExternalScrollFastPathRegion {
    // The callback ABI carries only a vertical delta. Reject horizontal,
    // multi-row, and hostile geometry instead of asking frontends to infer
    // whether the core omitted reusable rows.
    if ((op.rows != 1 and op.rows != -1) or op.cols != 0) return null;
    if (viewport_rows == 0 or viewport_cols == 0) return null;
    if (viewport_rows > grid_rows or viewport_cols > grid_cols) return null;
    if (op.top >= op.bot or op.bot > grid_rows) return null;
    if (op.left >= op.right or op.right > grid_cols) return null;

    const row_end = @min(op.bot, viewport_rows);
    if (row_end <= op.top or row_end - op.top <= 1) return null;
    const col_start = @min(op.left, viewport_cols);
    const col_end = @min(op.right, viewport_cols);
    if (col_start != 0 or col_end != viewport_cols) return null;

    return .{
        .row_start = op.top,
        .row_end = row_end,
        .col_start = col_start,
        .col_end = col_end,
    };
}

fn dispatchGridRowScroll(
    core: *Core,
    scroll_cb: GridRowScrollCallback,
    grid_id: i64,
    anchor_entries: []const ExternalFloatAnchorEntry,
) bool {
    if (grid_id < 2) return false;
    if (!core.grid.external_grids.contains(grid_id)) return false;
    // The frontend cannot remap retained row slots until the external window
    // open callback has seeded a committed surface. Keep dispatch eligibility
    // identical to sendExternalGridVertices' generation-side fast path.
    if (!core.known_external_grids.contains(grid_id)) return false;
    const sg = core.grid.sub_grids.getPtr(grid_id) orelse return false;
    if (sg.scroll_fast_path_blocked) return false;

    // A float composited into this external grid cannot be pixel-shifted with
    // the base rows because its old overlay pixels would move too.
    if (externalFloatAnchorEntries(anchor_entries, grid_id).len != 0) return false;

    const op = sg.last_scroll_op orelse return false;
    const ext_target = core.grid.external_grid_target_sizes.get(grid_id);
    const vp_rows = if (ext_target) |t| t.rows else sg.rows;
    const vp_cols = if (ext_target) |t| t.cols else sg.cols;
    const region = externalScrollFastPathRegion(op, sg.rows, sg.cols, vp_rows, vp_cols) orelse return false;
    scroll_cb(core.ctx, grid_id, region.row_start, region.row_end, region.col_start, region.col_end, op.rows, vp_rows, vp_cols);
    return true;
}

pub const FlushCtx = struct {
    core: *Core,

    pub fn onFlush(ctx: *FlushCtx, rows: u32, cols: u32) !void {
        const n_cells: usize = @as(usize, rows) * @as(usize, cols);
        ctx.core.flush_retryable = true;
        try preflightMainSubgridRowIndex(ctx.core, rows);
        try beginVertexBudgetTransaction(ctx.core);
        const last_sent_content_rev_before = ctx.core.last_sent_content_rev;
        const last_sent_cursor_rev_before = ctx.core.last_sent_cursor_rev;
        // Remember what this attempt is about to consume. A frontend that
        // later refuses to publish owes exactly this much on the retry, not a
        // full-viewport resend (see the abort branch below).
        var dirty_snapshot_valid = true;
        ctx.core.grid.snapshotDirty(ctx.core.alloc, &ctx.core.flush_dirty_snapshot) catch {
            dirty_snapshot_valid = false;
        };
        if (!snapshotMainVertexRowLedger(ctx.core)) dirty_snapshot_valid = false;

        // === PERF LOG: flush開始 ===
        const perf_enabled = ctx.core.log.cb != null;
        var t_flush_start: i128 = 0;
        if (perf_enabled) {
            t_flush_start = clock.nowNs();
            // Reset per-flush atlas/callback aggregation counters. The
            // packAndUpload / ensureGlyphPhase2 paths add into these as glyphs
            // miss; the defer below dumps the totals as a single [perf] line.
            ctx.core.perf_rasterize_ns_total = 0;
            ctx.core.perf_upload_ns_total = 0;
            ctx.core.perf_pack_ns_total = 0;
            ctx.core.perf_rasterize_calls = 0;
            ctx.core.perf_upload_calls = 0;
            ctx.core.perf_atlas_create_calls = 0;
            ctx.core.perf_atlas_create_ns_total = 0;
            ctx.core.perf_atlas_total_ns_total = 0;
            ctx.core.perf_atlas_total_calls = 0;
        }
        defer {
            if (perf_enabled) {
                const t_flush_end = clock.nowNs();
                const flush_us: i64 = @intCast(@divTrunc(@max(0, t_flush_end - t_flush_start), 1000));
                ctx.core.log.write("[perf] flush_total rows={d} cols={d} us={d}\n", .{ rows, cols, flush_us });
                // Per-flush atlas aggregate. Always emitted (even when zero) so
                // a downstream analyzer can pair it 1:1 with flush_total.
                // full_reset_count is cumulative (not reset above) so it can
                // be diffed across flushes to see how often the atlas-full
                // path (packAndUploadBitmap's shelf packer running out of
                // room) actually fires in real usage.
                ctx.core.log.write(
                    "[perf] atlas raster_calls={d} raster_ns={d} upload_calls={d} upload_ns={d} pack_ns={d} create_calls={d} create_ns={d} total_calls={d} total_ns={d} full_reset_count={d} shape_fallback_runs={d}\n",
                    .{
                        ctx.core.perf_rasterize_calls,       ctx.core.perf_rasterize_ns_total,
                        ctx.core.perf_upload_calls,          ctx.core.perf_upload_ns_total,
                        ctx.core.perf_pack_ns_total,         ctx.core.perf_atlas_create_calls,
                        ctx.core.perf_atlas_create_ns_total, ctx.core.perf_atlas_total_calls,
                        ctx.core.perf_atlas_total_ns_total,  ctx.core.perf_atlas_full_reset_count,
                        ctx.core.perf_shape_fallback_runs,
                    },
                );
                // Cumulative (never reset) grid_mu tryLock contention for the
                // 6 UI-thread call sites converted from blocking to tryLock+
                // cache. attempts/busy let a downstream analyzer compute a
                // contention rate since app start; loaded atomically since
                // these are written from the UI thread, including on the
                // busy branch where grid_mu itself is NOT held.
                ctx.core.log.write(
                    "[perf] grid_lock_contention mode_state_attempts={d} mode_state_busy={d} cursor_pos_attempts={d} cursor_pos_busy={d} msg_timeout_attempts={d} msg_timeout_busy={d} input_trace_attempts={d} input_trace_busy={d} cursor_blink_attempts={d} cursor_blink_busy={d} viewport_attempts={d} viewport_busy={d} layout_attempts={d} layout_busy={d}\n",
                    .{
                        ctx.core.perf_lock_mode_state.attempts.load(.monotonic),
                        ctx.core.perf_lock_mode_state.busy.load(.monotonic),
                        ctx.core.perf_lock_cursor_pos.attempts.load(.monotonic),
                        ctx.core.perf_lock_cursor_pos.busy.load(.monotonic),
                        ctx.core.perf_lock_msg_timeout.attempts.load(.monotonic),
                        ctx.core.perf_lock_msg_timeout.busy.load(.monotonic),
                        ctx.core.perf_lock_input_trace.attempts.load(.monotonic),
                        ctx.core.perf_lock_input_trace.busy.load(.monotonic),
                        ctx.core.perf_lock_cursor_blink.attempts.load(.monotonic),
                        ctx.core.perf_lock_cursor_blink.busy.load(.monotonic),
                        ctx.core.perf_lock_viewport.attempts.load(.monotonic),
                        ctx.core.perf_lock_viewport.busy.load(.monotonic),
                        ctx.core.perf_lock_layout.attempts.load(.monotonic),
                        ctx.core.perf_lock_layout.busy.load(.monotonic),
                    },
                );
            }
        }

        ctx.core.missing_glyph_log_count = 0;
        ctx.core.atlas_full_resets_this_flush = 0;

        // Snapshot dirty bookkeeping at flush entry. Compares against
        // grid_line_stats from the redraw_batch to tell apart:
        //  - grid_scroll batches: dirty=few, fast path drives flush
        //  - grid_line bursts (tig/less/lazygit): dirty=all, fast path bypassed
        // dirty_all=1 means a full-screen rebuild is forced regardless of
        // dirty_rows bits (resize / guifont / atlas reset).
        if (perf_enabled) {
            var dirty_count: u32 = 0;
            var dr_iter = ctx.core.grid.dirty_rows.iterator(.{});
            while (dr_iter.next()) |_| dirty_count += 1;
            ctx.core.log.write(
                "[perf] flush_dirty rows={d} dirty_rows={d} dirty_all={d} content_rev={d}\n",
                .{ rows, dirty_count, @intFromBool(ctx.core.grid.dirty_all), ctx.core.grid.content_rev },
            );
        }

        // Cache glow state once per flush — these don't change while grid_mu is held.
        const glow_enabled = ctx.core.glow_enabled.load(.acquire);
        const glow_all = ctx.core.glow_all;
        const glow_hl_ids = if (ctx.core.glow_hl_ids) |*m| m else null;

        // Notify frontend about scrolled grids BEFORE vertex generation.
        // This allows Swift to clear pixel offsets before new vertices are rendered,
        // preventing double-shift glitches in split windows.
        const scrolled_count = ctx.core.grid.scrolled_grid_count;
        const scrolled_overflow = ctx.core.grid.scrolled_grid_overflow;
        if (perf_enabled and (scrolled_count > 0 or scrolled_overflow)) {
            ctx.core.log.write("[scroll_debug] flush_begin scrolled_grids={d} overflow={any} content_rev={d} dirty_all={any}\n", .{
                scrolled_count, scrolled_overflow, ctx.core.grid.content_rev, ctx.core.grid.dirty_all,
            });
        }
        // Reset flush_aborted BEFORE calling on_flush_begin
        // (the callback may set it via zonvie_core_abort_flush)
        ctx.core.flush_aborted = false;
        ctx.core.flush_retryable = true;
        ctx.core.flush_atlas_corrupted = false;

        // Notify frontend: flush begins (for triple buffer write-set preparation)
        if (ctx.core.cb.on_flush_begin) |cb| {
            const t_cb_begin: i128 = if (perf_enabled) clock.nowNs() else 0;
            cb(ctx.core.ctx);
            if (perf_enabled) {
                const cb_us: i64 = @intCast(@divTrunc(@max(0, clock.nowNs() - t_cb_begin), 1000));
                ctx.core.log.write("[perf] cb_flush_begin us={d} aborted={any}\n", .{ cb_us, ctx.core.flush_aborted });
            }
        }
        const aborted_at_flush_begin = ctx.core.flush_aborted;
        // Reclaim atlas space while scroll_cache still describes the frame the
        // frontend is showing, and before this flush packs anything of its own.
        if (!aborted_at_flush_begin) ctx.core.collectAtlasGarbageIfNeeded();
        // pre_row "blackhole" bracket start. Surfaces the untimed gap between
        // cb_flush_begin and the row loop entry: scrolled-grid dispatch,
        // deferred-scroll dispatch, msg_show throttle check, notifyCmdlineChanges,
        // notifyPopupmenuChanges, cursor resolve. Closed inside the row_mode
        // branch where t_rows_start_ns is established (search "pre_row_us").
        const t_pre_row_start: i128 = if (perf_enabled) clock.nowNs() else 0;
        // Commit scroll provenance only after every deferred external-grid
        // callback and on_flush_end accepted the transaction. Registration
        // order is intentional: this defer runs after the two defers below.
        defer {
            ctx.core.ext_float_anchor_index_valid = false;
            const vertex_budget_committed = !ctx.core.flush_aborted and !ctx.core.flush_atlas_corrupted;
            // on_flush_begin runs before any core vertex/atlas mutation. Its
            // backpressure rejection leaves the existing accounting valid,
            // so closing this untouched budget transaction must not invalidate
            // every row ledger and force a full resend.
            // A frontend publication refusal keeps the committed frame intact,
            // so both the begin rejection and a late on_flush_end refusal can
            // hold their accounting instead of invalidating every row ledger.
            // A hard failure (atlas corruption, budget violation) still takes
            // the full-invalidation path.
            const frontend_refused_publication = ctx.core.flush_aborted and
                !ctx.core.flush_atlas_corrupted and
                ctx.core.flush_retryable and
                dirty_snapshot_valid;
            finishVertexBudgetTransactionRestoring(
                ctx.core,
                vertex_budget_committed or aborted_at_flush_begin,
                frontend_refused_publication,
            );
            if (vertex_budget_committed) {
                ctx.core.finishAtlasMaintenance();
                ctx.core.grid.clearScrolledGrids();
                ctx.core.grid.clearScrollState();
                var sg_it = ctx.core.grid.sub_grids.valueIterator();
                while (sg_it.next()) |sg| sg.clearScrollState();
            } else {
                // This is a transaction-local edge, not persistent atlas
                // state. A callback abort can return before the normal reset
                // checks consume it.
                ctx.core.atlas_reset_during_flush = false;
                if (!aborted_at_flush_begin) {
                    // on_flush_end itself may reject the transaction after main
                    // and external generation already cleared dirty flags.
                    // Restore what this attempt consumed. The frontend keeps
                    // its previously committed frame on screen when it refuses
                    // to publish, so every other row is still correct there —
                    // resending all of them turned a routine backpressure
                    // rejection (atlas back-sync in flight) into a whole
                    // viewport re-shape and re-rasterization. Only a failed
                    // snapshot falls back to the unconditional full resend.
                    // Successfully invoked on_grid_scroll IDs are consumed at
                    // the call site; any unvisited IDs remain in the compact
                    // prefix/per-grid bits for retry.
                    if (dirty_snapshot_valid) {
                        ctx.core.grid.restoreDirty(&ctx.core.flush_dirty_snapshot);
                    } else {
                        ctx.core.grid.markAllDirty();
                    }
                    var sg_it = ctx.core.grid.sub_grids.valueIterator();
                    while (sg_it.next()) |sg| sg.markAllDirty();
                    ctx.core.last_sent_content_rev = last_sent_content_rev_before;
                    ctx.core.last_sent_cursor_rev = last_sent_cursor_rev_before;
                    ctx.core.force_ext_cursor_recheck = true;
                }
                // A due maintenance reprobe may already have invalidated its
                // negative entries before a later consumer rejected the flush.
                // Re-arm the shared one-shot timer so idle Neovim cannot leave
                // those now-uncached visible cells waiting forever.
                if ((ctx.core.atlas_negative_recovery_armed and ctx.core.atlas_negative_retry_at == null) or
                    (ctx.core.transient_glyph_recovery_armed and ctx.core.transient_glyph_retry_at == null))
                {
                    const retry_at = scheduleMsgRetryDeadline(ctx.core, clock.nowNs());
                    ctx.core.rearmAtlasMaintenanceAfterAbort(retry_at);
                }
                if (!aborted_at_flush_begin) {
                    ctx.core.grid.clearScrollState();
                    var sg_it = ctx.core.grid.sub_grids.valueIterator();
                    while (sg_it.next()) |sg| sg.clearScrollState();
                }
            }
        }

        // Ensure on_flush_end is called on all exit paths (atomic commit point)
        defer {
            if (ctx.core.cb.on_flush_end) |cb| {
                const t_cb_end: i128 = if (perf_enabled) clock.nowNs() else 0;
                cb(ctx.core.ctx);
                if (perf_enabled) {
                    const cb_us: i64 = @intCast(@divTrunc(@max(0, clock.nowNs() - t_cb_end), 1000));
                    ctx.core.log.write("[perf] cb_flush_end us={d}\n", .{cb_us});
                }
            }
        }
        // Generate external grid vertices inside the flush bracket (LIFO: runs
        // before on_flush_end). This ensures the frontend receives vertex data
        // before commitFlush, preventing draw() from rendering remapped slots
        // with stale vertex content.
        defer {
            if (!ctx.core.flush_aborted and !ctx.core.flush_atlas_corrupted) {
                const t_ext: i128 = if (perf_enabled) clock.nowNs() else 0;
                sendExternalGridVertices(ctx.core, false);
                if (perf_enabled) {
                    const ext_us: i64 = @intCast(@divTrunc(@max(0, clock.nowNs() - t_ext), 1000));
                    ctx.core.log.write("[perf] send_external_grids us={d} known={d}\n", .{ ext_us, ctx.core.known_external_grids.count() });
                }
                // Complete external-window lifecycle notification before
                // on_flush_end commits the frontend transaction. This is
                // required for timer/retry-driven flushes, which have no
                // redraw-batch post-processing phase, and lets an allocation
                // failure here cancel/retry the same transaction.
                if (!ctx.core.flush_aborted and !ctx.core.flush_atlas_corrupted) {
                    _ = notifyExternalWindowChanges(ctx.core);
                }
                // sendExternalGridVertices can itself call
                // zonvie_core_abort_flush (e.g. Windows external row-buffer
                // OOM), AFTER the main grid already ran clearDirty() /
                // saveSubgridSnapshots() earlier in this function on the
                // assumption of a successful commit. But the frontend's
                // on_flush_end abort handling cancels ALL brackets for this
                // flush, main included — so an abort discovered only here
                // would otherwise drop the main-grid update permanently
                // (core thinks it already sent it; frontend never commits
                // it). Force a full resend next flush to recover.
                if (ctx.core.flush_aborted) {
                    ctx.core.grid.markAllDirty();
                    var sg_it = ctx.core.grid.sub_grids.valueIterator();
                    while (sg_it.next()) |sg| {
                        sg.markAllDirty();
                    }
                    ctx.core.force_ext_cursor_recheck = true;
                    // last_sent_cursor_rev was already synced to the current
                    // cursor_rev earlier in this same onFlush() call (the
                    // on_vertices_partial fast path above), before this
                    // late-discovered abort was known. The cancelled
                    // bracket includes the main cursor too, so force a
                    // mismatch (wrapping, matching cursor_rev's own +%=
                    // idiom) so the next flush's need_cursor check resends
                    // it instead of assuming it was already delivered.
                    ctx.core.last_sent_cursor_rev -%= 1;
                }
            }
            // This defer runs before on_flush_end. Validate the completed
            // completed main+external state only after every row was generated,
            // so moving vertices between rows cannot fail on a mixed old/new
            // intermediate ledger. A failure cancels the frontend bracket and
            // the final transaction defer above invalidates its accounting.
            if (!ctx.core.flush_aborted and !ctx.core.flush_atlas_corrupted) {
                validateCompletedVertexBudget(ctx.core) catch |err| {
                    ctx.core.flush_aborted = true;
                    ctx.core.failHardRender(err);
                };
            }
        }

        // A composition step below (vertex buffer growth, glyph push, etc.)
        // can fail with an internal Zig error (OOM) rather than an explicit
        // frontend-signaled zonvie_core_abort_flush() call. Without this,
        // such an error would propagate straight out of onFlush and be
        // silently swallowed by callers (`catch {}` / logged and dropped),
        // while the on_flush_end/sendExternalGridVertices defers above still
        // run as if nothing happened — frontends would commit whatever
        // partial write-set was composed before the failure as a complete,
        // successful frame. Registered AFTER those two defers so it runs
        // FIRST during unwind (LIFO), setting flush_aborted before they see
        // it — sendExternalGridVertices's defer already skips on
        // flush_aborted, and zonvie_core_flush_was_aborted() lets both
        // frontends' on_flush_end handlers detect this and cancel their
        // bracket instead of committing.
        errdefer ctx.core.flush_aborted = true;

        // If frontend aborted, skip all vertex/atlas work.
        // Grid scroll events are NOT dispatched or cleared — they are preserved
        // for the retry flush so smooth-scroll offsets stay in sync with vertices.
        if (ctx.core.flush_aborted) {
            // The message timeout checks below are unreachable when beginFlush
            // rejects the transaction. Move every elapsed deadline onto one
            // bounded retry deadline so the frontend timer does not immediately
            // drive another full flush under sustained backpressure/OOM.
            const now = clock.nowNs();
            var throttle_due = false;
            if (ctx.core.msg_show_pending_since) |pending_since| {
                throttle_due = now - pending_since >= ctx.core.msg_show_throttle_ns;
                const retry_due = if (ctx.core.msg_show_retry_at) |retry_at| now >= retry_at else true;
                throttle_due = throttle_due and retry_due;
            }
            const show_hide_due = if (ctx.core.msg_show_auto_hide_at) |hide_at| now >= hide_at else false;
            const history_hide_due = if (ctx.core.msg_history_auto_hide_at) |hide_at| now >= hide_at else false;
            const atlas_retry_due = if (ctx.core.atlas_negative_retry_at) |retry_at| now >= retry_at else false;
            const transient_retry_due = if (ctx.core.transient_glyph_retry_at) |retry_at| now >= retry_at else false;
            // Included since a history dispatch failure now always arms this,
            // making an elapsed deadline common: left out, it alone keeps
            // nextMsgTimeoutNs at zero and the frontend spins a 0ms timer.
            const history_retry_due = if (ctx.core.msg_history_retry_at) |retry_at| now >= retry_at else false;
            if (throttle_due or show_hide_due or history_hide_due or atlas_retry_due or
                transient_retry_due or history_retry_due)
            {
                const retry_at = scheduleMsgRetryDeadline(ctx.core, now);
                if (throttle_due) ctx.core.msg_show_retry_at = retry_at;
                if (show_hide_due) ctx.core.msg_show_auto_hide_at = retry_at;
                if (history_hide_due) ctx.core.msg_history_auto_hide_at = retry_at;
                if (atlas_retry_due) ctx.core.atlas_negative_retry_at = retry_at;
                if (transient_retry_due) ctx.core.transient_glyph_retry_at = retry_at;
                if (history_retry_due) ctx.core.msg_history_retry_at = retry_at;
            }
            return;
        }

        // Capacity-negative glyphs are retried selectively only after the
        // frontend accepted the flush bracket. This invalidates cached blank
        // entries but does not recreate the atlas; an actually-visible miss
        // takes the bounded reactive reset path during generation.
        _ = ctx.core.prepareAtlasMaintenance();

        // Dispatch grid_scroll events AFTER abort check so they are preserved on retry.
        if (ctx.core.cb.on_grid_scroll) |cb| {
            if (scrolled_overflow) {
                if (ctx.core.grid.main_scroll_notify_pending) {
                    cb(ctx.core.ctx, 1, ctx.core.grid.main_scroll_notify_rows);
                    ctx.core.grid.consumeScrolledGridNotification(1);
                }
                if (!ctx.core.flush_aborted) {
                    var sg_it = ctx.core.grid.sub_grids.iterator();
                    while (sg_it.next()) |entry| {
                        if (entry.value_ptr.scroll_notify_pending) {
                            const grid_id = entry.key_ptr.*;
                            cb(ctx.core.ctx, grid_id, entry.value_ptr.scroll_notify_rows);
                            ctx.core.grid.consumeScrolledGridNotification(grid_id);
                            if (ctx.core.flush_aborted) break;
                        }
                    }
                }
            } else {
                while (ctx.core.grid.scrolled_grid_count != 0) {
                    const grid_id = ctx.core.grid.scrolled_grid_ids[0];
                    cb(ctx.core.ctx, grid_id, ctx.core.grid.scrolledGridNotifyRows(grid_id));
                    ctx.core.grid.consumeScrolledGridNotification(grid_id);
                    if (ctx.core.flush_aborted) break;
                }
            }
            // The loops above break on abort; without the same check here a
            // bracket that has already given up would still hand over a
            // distance and clear the accumulator that proves it is owed.
            if (ctx.core.flush_aborted) return;

            // Movement win_viewport reported that no grid_scroll described.
            // Under 'smoothscroll' Neovim repaints instead of shifting rows, so
            // this is the only report that the content moved — and a frontend
            // holding a sub-cell offset has to give back that distance and
            // retain the rows that left, exactly as for a real scroll. Same
            // dispatch point and the same consume-after-delivery rule, so an
            // abort preserves it for the retry.
            var vp_it = ctx.core.grid.viewport.iterator();
            while (vp_it.next()) |entry| {
                const uncovered = entry.value_ptr.uncovered_scroll_rows;
                // A batch grid_scroll already described is fully accounted for;
                // the viewport's own figure for it is redundant and, past a
                // screen, approximate.
                if (entry.value_ptr.scroll_covered) {
                    entry.value_ptr.scroll_covered = false;
                    entry.value_ptr.uncovered_scroll_rows = 0;
                    continue;
                }
                if (uncovered == 0) continue;
                const clamped: i32 = @intCast(@max(-1_000_000, @min(1_000_000, uncovered)));
                cb(ctx.core.ctx, entry.key_ptr.*, clamped);
                entry.value_ptr.uncovered_scroll_rows = 0;
                if (ctx.core.flush_aborted) break;
            }
        }
        if (ctx.core.flush_aborted) return;

        // Dispatch per-grid row scroll notifications for external grids.
        // Fires at the same dispatch point as on_grid_scroll (after abort check).
        // Skipped when multiple scrolls occurred in the same batch (fast path ineligible).
        // Also skipped when float windows are anchored to the grid, because the core
        // composites float content into the grid's row vertices — GPU-blitting old pixels
        // would shift stale overlay content to wrong positions.
        // last_scroll_op is committed by the transaction-final defer, not here.
        if (ctx.core.cb.on_grid_row_scroll) |scroll_cb| {
            var has_pending_external_scroll = false;
            var pending_it = ctx.core.grid.sub_grids.iterator();
            while (pending_it.next()) |entry| {
                if (entry.value_ptr.row_scroll_notify_pending and
                    ctx.core.grid.external_grids.contains(entry.key_ptr.*))
                {
                    has_pending_external_scroll = true;
                    break;
                }
            }
            if (has_pending_external_scroll) try buildExternalFloatAnchorIndex(ctx.core);

            var sg_it = ctx.core.grid.sub_grids.iterator();
            while (sg_it.next()) |entry| {
                if (entry.value_ptr.row_scroll_notify_pending) {
                    _ = dispatchGridRowScroll(
                        ctx.core,
                        scroll_cb,
                        entry.key_ptr.*,
                        ctx.core.ext_float_anchor_entries.items,
                    );
                    entry.value_ptr.row_scroll_notify_pending = false;
                    if (ctx.core.flush_aborted) break;
                }
            }
        }
        if (ctx.core.flush_aborted) return;

        // Check msg_show throttle timeout for external commands
        ctx.core.checkMsgShowThrottleTimeout();

        // Process cmdline changes BEFORE generating vertices.
        // This ensures cursor position is restored before vertex generation.
        notifyCmdlineChanges(ctx.core);

        // Process popupmenu changes inside the flush bracket so ext-popupmenu
        // vertices are generated from the current selection state in the same
        // flush. If this runs after redraw.handleRedraw returns, the popupmenu
        // grid lags one flush behind cmdline_show updates.
        notifyPopupmenuChanges(ctx.core);

        // Process message changes inside the flush bracket so msg_show
        // (ext_float) grid is registered in external_grids and gets vertices
        // generated by sendExternalGridVertices (the LIFO-deferred call below)
        // in the same flush. If this runs only after handleRedraw returns
        // (rpc_session.zig), the newly created msg grid misses vertex generation
        // for one flush and the frontend's first WM_PAINT shows a blank window
        // until the next user event triggers another flush.
        notifyMessageChanges(ctx.core);
        if (ctx.core.flush_aborted) return;

        // A zero-cell main grid has no rows to generate, but its layout still
        // has to cross the transaction boundary. Publish it through the
        // existing row ABI as a layout-only MAIN update, followed by the
        // independent empty cursor layer. Dirty/revision state is consumed
        // only after both callbacks accept the bracket.
        if (n_cells == 0) {
            const need_main =
                ctx.core.grid.content_rev != ctx.core.last_sent_content_rev or
                ctx.core.grid.dirty_all or
                ctx.core.main_surface_vertex_count != 0;
            const need_cursor =
                ctx.core.grid.cursor_rev != ctx.core.last_sent_cursor_rev or need_main;

            if (ctx.core.cb.on_vertices_row) |row_cb| {
                if (need_main) {
                    row_cb(
                        ctx.core.ctx,
                        1,
                        0,
                        0,
                        null,
                        0,
                        c_api.VERT_UPDATE_MAIN,
                        rows,
                        cols,
                    );
                    if (ctx.core.flush_aborted) return;
                }
                if (need_cursor) {
                    row_cb(
                        ctx.core.ctx,
                        1,
                        0,
                        0,
                        null,
                        0,
                        c_api.VERT_UPDATE_CURSOR,
                        rows,
                        cols,
                    );
                    if (ctx.core.flush_aborted) return;
                }
                if (need_main) {
                    ctx.core.invalidateScrollCache();
                    ctx.core.last_sent_content_rev = ctx.core.grid.content_rev;
                    ctx.core.grid.clearDirty();
                }
                if (need_cursor) {
                    ctx.core.last_sent_cursor_rev = ctx.core.grid.cursor_rev;
                }
            }
            return;
        }

        var cursor_out: c_api.Cursor = .{
            .enabled = 0,
            .row = 0,
            .col = 0,
            .shape = .block,
            .cell_percentage = 100,
            .fgRGB = 0,
            .bgRGB = 0,
            .blink_wait_ms = 0,
            .blink_on_ms = 0,
            .blink_off_ms = 0,
        };

        // NOTE: cursor row/col are relative to cursor_grid.
        // Convert them to screen(grid 1) coordinates using win_pos,
        // because we already flattened sub-grids into tmp[] in screen space.
        if (ctx.core.grid.cursor_valid and ctx.core.grid.cursor_visible) {
            var cr: i64 = @as(i64, ctx.core.grid.cursor_row);
            var cc: i64 = @as(i64, ctx.core.grid.cursor_col);

            if (ctx.core.grid.cursor_grid != 1) {
                if (ctx.core.grid.win_pos.get(ctx.core.grid.cursor_grid)) |p| {
                    cr += @as(i64, p.row);
                    cc += @as(i64, p.col);
                } else {
                    cr = -1;
                    cc = -1;
                }
            }

            if (cr >= 0 and cc >= 0 and cr < @as(i64, rows) and cc < @as(i64, cols)) {
                const row: u32 = @intCast(cr);
                const col: u32 = @intCast(cc);

                cursor_out.enabled = 1;
                cursor_out.row = row;
                cursor_out.col = col;
                cursor_out.shape = switch (ctx.core.grid.cursor_shape) {
                    .block => .block,
                    .vertical => .vertical,
                    .horizontal => .horizontal,
                };
                cursor_out.cell_percentage = ctx.core.grid.cursor_cell_percentage;

                // Set blink parameters
                cursor_out.blink_wait_ms = ctx.core.grid.cursor_blink_wait_ms;
                cursor_out.blink_on_ms = ctx.core.grid.cursor_blink_on_ms;
                cursor_out.blink_off_ms = ctx.core.grid.cursor_blink_off_ms;

                // Resolve cursor colors
                if (ctx.core.grid.cursor_attr_id != 0) {
                    const attr = ctx.core.hl.get(ctx.core.grid.cursor_attr_id);
                    cursor_out.fgRGB = attr.fg;
                    cursor_out.bgRGB = attr.bg;
                } else {
                    // attr_id == 0: swap default colors (per Nvim spec)
                    cursor_out.fgRGB = ctx.core.hl.default_bg;
                    cursor_out.bgRGB = ctx.core.hl.default_fg;
                }

                // Debug log: cursor_out values
                if (ctx.core.log.cb != null) {
                    ctx.core.log.write("cursor_out: shape={d} cell_pct={d} blink=({d},{d},{d}) row={d} col={d}\n", .{
                        @intFromEnum(cursor_out.shape),
                        cursor_out.cell_percentage,
                        cursor_out.blink_wait_ms,
                        cursor_out.blink_on_ms,
                        cursor_out.blink_off_ms,
                        cursor_out.row,
                        cursor_out.col,
                    });
                }
            }
        }

        // --- fast path: build vertices directly (skip bg_spans/text_runs/scalars_buf) ---
        if (ctx.core.cb.on_vertices_partial != null or ctx.core.cb.on_vertices_row != null) {
            const pf_opt = ctx.core.cb.on_vertices_partial;

            // Decide what needs rebuilding/sending.
            // dirty_all must force a rebuild even when content_rev is already
            // synced: the atlas-reset/glyph-miss recovery paths call
            // markAllDirty() AFTER last_sent_content_rev was synced for this
            // flush (row-mode retry exit, and the non-row-mode unsent-return
            // above the partial send). Without this OR, the early return
            // below would clearDirty() the pending recovery and the screen
            // would stay stale/blank until the next real content change.
            const need_main: bool = (ctx.core.grid.content_rev != ctx.core.last_sent_content_rev) or ctx.core.grid.dirty_all;
            const need_cursor: bool = (ctx.core.grid.cursor_rev != ctx.core.last_sent_cursor_rev);
            var cursor_retry_required = false;

            // If nothing changed, avoid doing any work.
            if (!need_main and !need_cursor) {
                ctx.core.grid.clearDirty();
                return;
            }

            var main = &ctx.core.main_verts;
            var cursor = &ctx.core.cursor_verts;

            const cellW: f32 = @floatFromInt(ctx.core.cell_w_px);
            const cellH: f32 = @floatFromInt(ctx.core.cell_h_px);

            // NDC viewport: use grid-based dimensions (cols * cellW, rows * cellH)
            // instead of raw drawable dimensions. This prevents sub-cell stretching
            // when the drawable changes by less than one cell (the Metal viewport
            // on the frontend is set to match these exact pixel dimensions).
            const grid_cols = @max(@as(u32, 1), ctx.core.drawable_w_px / ctx.core.cell_w_px);
            const grid_rows = @max(@as(u32, 1), ctx.core.drawable_h_px / ctx.core.cell_h_px);
            const dw: f32 = @as(f32, @floatFromInt(grid_cols)) * cellW;
            const dh: f32 = @as(f32, @floatFromInt(grid_rows)) * cellH;

            const topPad: f32 = @floatFromInt(rowTopPadPx(ctx.core.linespace_px));

            const Helpers = struct {
                fn ndc(x: f32, y: f32, vw: f32, vh: f32) [2]f32 {
                    const nx = (x / vw) * 2.0 - 1.0;
                    const ny = 1.0 - (y / vh) * 2.0;
                    return .{ nx, ny };
                }

                /// Batch NDC transform for 4 quad corners (TL, TR, BL, BR).
                inline fn ndc4(x0: f32, y0: f32, x1: f32, y1: f32, vw: f32, vh: f32) [4][2]f32 {
                    const V4 = @Vector(4, f32);
                    const xs = V4{ x0, x1, x0, x1 };
                    const ys = V4{ y0, y0, y1, y1 };
                    const nxs = xs / @as(V4, @splat(vw)) * @as(V4, @splat(2.0)) - @as(V4, @splat(1.0));
                    const nys = @as(V4, @splat(1.0)) - ys / @as(V4, @splat(vh)) * @as(V4, @splat(2.0));
                    return .{
                        .{ nxs[0], nys[0] },
                        .{ nxs[1], nys[1] },
                        .{ nxs[2], nys[2] },
                        .{ nxs[3], nys[3] },
                    };
                }

                /// SIMD-accelerated RGB→float4 conversion.
                inline fn rgb(v: u32) [4]f32 {
                    return rgba(v, 1.0);
                }

                /// SIMD-accelerated RGBA→float4 conversion.
                inline fn rgba(v: u32, alpha: f32) [4]f32 {
                    const V4u32 = @Vector(4, u32);
                    const V4f32 = @Vector(4, f32);
                    const vv: V4u32 = @splat(v);
                    const channels = (vv >> V4u32{ 16, 8, 0, 0 }) & @as(V4u32, @splat(0xFF));
                    const floats = @as(V4f32, @floatFromInt(channels)) * @as(V4f32, @splat(1.0 / 255.0));
                    var arr: [4]f32 = floats;
                    arr[3] = alpha;
                    return arr;
                }

                const solid_uv: [2]f32 = .{ -1.0, -1.0 };

                fn pushSolidQuad(
                    out: *std.ArrayListUnmanaged(c_api.Vertex),
                    alloc: std.mem.Allocator,
                    x0: f32,
                    y0: f32,
                    x1: f32,
                    y1: f32,
                    col: [4]f32,
                    vw: f32,
                    vh: f32,
                    grid_id: i64,
                    base_deco_flags: u32,
                ) !void {
                    const pts = ndc4(x0, y0, x1, y1, vw, vh);
                    const p0 = pts[0];
                    const p1 = pts[1];
                    const p2 = pts[2];
                    const p3 = pts[3];

                    try out.ensureUnusedCapacity(alloc, 6);
                    const v = out.addManyAsSliceAssumeCapacity(6);

                    v[0] = .{ .position = p0, .texCoord = solid_uv, .color = col, .grid_id = grid_id, .deco_flags = base_deco_flags, .deco_phase = 0 };
                    v[1] = .{ .position = p2, .texCoord = solid_uv, .color = col, .grid_id = grid_id, .deco_flags = base_deco_flags, .deco_phase = 0 };
                    v[2] = .{ .position = p1, .texCoord = solid_uv, .color = col, .grid_id = grid_id, .deco_flags = base_deco_flags, .deco_phase = 0 };

                    v[3] = .{ .position = p1, .texCoord = solid_uv, .color = col, .grid_id = grid_id, .deco_flags = base_deco_flags, .deco_phase = 0 };
                    v[4] = .{ .position = p2, .texCoord = solid_uv, .color = col, .grid_id = grid_id, .deco_flags = base_deco_flags, .deco_phase = 0 };
                    v[5] = .{ .position = p3, .texCoord = solid_uv, .color = col, .grid_id = grid_id, .deco_flags = base_deco_flags, .deco_phase = 0 };
                }

                /// Same as pushSolidQuad but caller guarantees capacity (6 vertices).
                fn pushSolidQuadAssumeCapacity(
                    out: *std.ArrayListUnmanaged(c_api.Vertex),
                    x0: f32,
                    y0: f32,
                    x1: f32,
                    y1: f32,
                    col: [4]f32,
                    vw: f32,
                    vh: f32,
                    grid_id: i64,
                    base_deco_flags: u32,
                ) void {
                    const pts = ndc4(x0, y0, x1, y1, vw, vh);
                    const p0 = pts[0];
                    const p1 = pts[1];
                    const p2 = pts[2];
                    const p3 = pts[3];

                    const v = out.addManyAsSliceAssumeCapacity(6);

                    v[0] = .{ .position = p0, .texCoord = solid_uv, .color = col, .grid_id = grid_id, .deco_flags = base_deco_flags, .deco_phase = 0 };
                    v[1] = .{ .position = p2, .texCoord = solid_uv, .color = col, .grid_id = grid_id, .deco_flags = base_deco_flags, .deco_phase = 0 };
                    v[2] = .{ .position = p1, .texCoord = solid_uv, .color = col, .grid_id = grid_id, .deco_flags = base_deco_flags, .deco_phase = 0 };

                    v[3] = .{ .position = p1, .texCoord = solid_uv, .color = col, .grid_id = grid_id, .deco_flags = base_deco_flags, .deco_phase = 0 };
                    v[4] = .{ .position = p2, .texCoord = solid_uv, .color = col, .grid_id = grid_id, .deco_flags = base_deco_flags, .deco_phase = 0 };
                    v[5] = .{ .position = p3, .texCoord = solid_uv, .color = col, .grid_id = grid_id, .deco_flags = base_deco_flags, .deco_phase = 0 };
                }

                fn pushGlyphQuad(
                    out: *std.ArrayListUnmanaged(c_api.Vertex),
                    alloc: std.mem.Allocator,
                    x0: f32,
                    y0: f32,
                    x1: f32,
                    y1: f32,
                    uv0: [2]f32,
                    uv1: [2]f32,
                    uv2: [2]f32,
                    uv3: [2]f32,
                    col: [4]f32,
                    vw: f32,
                    vh: f32,
                    grid_id: i64,
                    base_deco_flags: u32,
                ) !void {
                    try out.ensureUnusedCapacity(alloc, 6);
                    pushGlyphQuadAssumeCapacity(out, x0, y0, x1, y1, uv0, uv1, uv2, uv3, col, vw, vh, grid_id, base_deco_flags);
                }

                /// Same as pushGlyphQuad but caller guarantees capacity.
                fn pushGlyphQuadAssumeCapacity(
                    out: *std.ArrayListUnmanaged(c_api.Vertex),
                    x0: f32,
                    y0: f32,
                    x1: f32,
                    y1: f32,
                    uv0: [2]f32,
                    uv1: [2]f32,
                    uv2: [2]f32,
                    uv3: [2]f32,
                    col: [4]f32,
                    vw: f32,
                    vh: f32,
                    grid_id: i64,
                    base_deco_flags: u32,
                ) void {
                    const pts = ndc4(x0, y0, x1, y1, vw, vh);
                    const p0 = pts[0];
                    const p1 = pts[1];
                    const p2 = pts[2];
                    const p3 = pts[3];

                    const v = out.addManyAsSliceAssumeCapacity(6);

                    v[0] = .{ .position = p0, .texCoord = uv0, .color = col, .grid_id = grid_id, .deco_flags = base_deco_flags, .deco_phase = 0 };
                    v[1] = .{ .position = p2, .texCoord = uv2, .color = col, .grid_id = grid_id, .deco_flags = base_deco_flags, .deco_phase = 0 };
                    v[2] = .{ .position = p1, .texCoord = uv1, .color = col, .grid_id = grid_id, .deco_flags = base_deco_flags, .deco_phase = 0 };

                    v[3] = .{ .position = p1, .texCoord = uv1, .color = col, .grid_id = grid_id, .deco_flags = base_deco_flags, .deco_phase = 0 };
                    v[4] = .{ .position = p2, .texCoord = uv2, .color = col, .grid_id = grid_id, .deco_flags = base_deco_flags, .deco_phase = 0 };
                    v[5] = .{ .position = p3, .texCoord = uv3, .color = col, .grid_id = grid_id, .deco_flags = base_deco_flags, .deco_phase = 0 };
                }

                fn pushDecoQuad(
                    out: *std.ArrayListUnmanaged(c_api.Vertex),
                    alloc: std.mem.Allocator,
                    x0: f32,
                    y0: f32,
                    x1: f32,
                    y1: f32,
                    col: [4]f32,
                    vw: f32,
                    vh: f32,
                    grid_id: i64,
                    deco_flags: u32,
                    deco_phase: f32,
                ) !void {
                    const pts = ndc4(x0, y0, x1, y1, vw, vh);
                    const p0 = pts[0];
                    const p1 = pts[1];
                    const p2 = pts[2];
                    const p3 = pts[3];

                    // UV coordinates for decorations:
                    // - UV.x = -1 (sentinel for solid/decoration)
                    // - UV.y = local Y position within quad (0.0 at top, 1.0 at bottom)
                    // This allows the shader to know the fragment's position within the quad
                    const uv_top: [2]f32 = .{ -1.0, 0.0 }; // y0 vertices (top)
                    const uv_bottom: [2]f32 = .{ -1.0, 1.0 }; // y1 vertices (bottom)

                    try out.ensureUnusedCapacity(alloc, 6);
                    const v = out.addManyAsSliceAssumeCapacity(6);

                    // Triangle 1: p0 (top-left), p2 (bottom-left), p1 (top-right)
                    v[0] = .{ .position = p0, .texCoord = uv_top, .color = col, .grid_id = grid_id, .deco_flags = deco_flags, .deco_phase = deco_phase };
                    v[1] = .{ .position = p2, .texCoord = uv_bottom, .color = col, .grid_id = grid_id, .deco_flags = deco_flags, .deco_phase = deco_phase };
                    v[2] = .{ .position = p1, .texCoord = uv_top, .color = col, .grid_id = grid_id, .deco_flags = deco_flags, .deco_phase = deco_phase };

                    // Triangle 2: p1 (top-right), p2 (bottom-left), p3 (bottom-right)
                    v[3] = .{ .position = p1, .texCoord = uv_top, .color = col, .grid_id = grid_id, .deco_flags = deco_flags, .deco_phase = deco_phase };
                    v[4] = .{ .position = p2, .texCoord = uv_bottom, .color = col, .grid_id = grid_id, .deco_flags = deco_flags, .deco_phase = deco_phase };
                    v[5] = .{ .position = p3, .texCoord = uv_bottom, .color = col, .grid_id = grid_id, .deco_flags = deco_flags, .deco_phase = deco_phase };
                }
            };

            var sent_main_by_rows: bool = false;
            var main_retry_required: bool = false;

            // Pre-compute subgrid info — declared outside need_main so the
            // snapshot is accessible for saveSubgridSnapshots in all exit paths.
            // Backed by a persistent Core-owned buffer (no fixed cap): row-mode
            // composition draws ONLY from this set, so truncating it would
            // silently drop the topmost floats in layouts with many grids.
            var cached_subgrids: []const CachedSubgrid = &.{};

            // ----------------------------
            // Rebuild MAIN only when needed
            // ----------------------------
            if (need_main) {
                main.clearRetainingCapacity();
                var tmp: *RenderCells = undefined;

                // Collect visible grids using persistent buffer (zero-allocation hot path)
                ctx.core.grid_entries.clearRetainingCapacity();
                const est_count = ctx.core.grid.win_pos.count();
                if (est_count != 0) {
                    try ctx.core.grid_entries.ensureTotalCapacity(ctx.core.alloc, est_count);

                    var itp = ctx.core.grid.win_pos.iterator();
                    while (itp.next()) |e| {
                        const grid_id = e.key_ptr.*;
                        // Only sub grids
                        if (grid_id == 1) continue;
                        // An external float is composited here via win_pos but is
                        // ALSO rendered in its own top-level window. Compositing it
                        // into the main grid double-draws its content (and its
                        // cursor cell) behind the float window. Its own window is
                        // the sole renderer, so skip it here.
                        if (ctx.core.grid.external_grids.contains(grid_id)) continue;

                        const layer = ctx.core.grid.win_layer.get(grid_id) orelse @as(@import("grid.zig").WinLayer, .{
                            .zindex = 0,
                            .compindex = 0,
                            .order = 0,
                        });
                        ctx.core.grid_entries.appendAssumeCapacity(.{
                            .grid_id = grid_id,
                            .zindex = layer.zindex,
                            .compindex = layer.compindex,
                            .order = layer.order,
                        });
                    }

                    // Sort back-to-front: smaller first, larger last.
                    // std.sort.block is O(n log n) — insertion sort here was
                    // O(n^2), a frame-time spike under grid_mu (blocking
                    // try_get_* callers) for layouts with many floats/splits.
                    std.sort.block(GridEntry, ctx.core.grid_entries.items, {}, struct {
                        fn lessThan(_: void, a: GridEntry, b: GridEntry) bool {
                            if (a.zindex != b.zindex) return a.zindex < b.zindex;
                            if (a.compindex != b.compindex) return a.compindex < b.compindex;
                            if (a.order != b.order) return a.order < b.order;
                            return a.grid_id < b.grid_id;
                        }
                    }.lessThan);
                }

                // Pre-compute subgrid info (shared by row-mode and non-row-mode paths).
                // Caches win_pos/sub_grids lookups and viewport margins to avoid
                // per-row hash map access during vertex generation.
                ctx.core.cached_subgrids_buf.clearRetainingCapacity();
                try ctx.core.cached_subgrids_buf.ensureTotalCapacity(ctx.core.alloc, ctx.core.grid_entries.items.len);
                for (ctx.core.grid_entries.items) |ent| {
                    const subgrid_id = ent.grid_id;
                    const pos = ctx.core.grid.win_pos.get(subgrid_id) orelse continue;
                    const sg = ctx.core.grid.sub_grids.get(subgrid_id) orelse continue;
                    if (sg.rows == 0 or sg.cols == 0) continue;

                    // Skip float windows anchored to external grids
                    if (pos.anchor_grid != 1 and ctx.core.grid.external_grids.contains(pos.anchor_grid)) continue;

                    const sg_margins = ctx.core.grid.getViewportMargins(subgrid_id);
                    ctx.core.cached_subgrids_buf.appendAssumeCapacity(.{
                        .grid_id = subgrid_id,
                        .row_start = pos.row,
                        // Saturating: a hostile win_pos row near maxInt(u32)
                        // must not overflow-panic the flush.
                        .row_end = pos.row +| sg.rows,
                        .col_start = pos.col,
                        .sg_cols = sg.cols,
                        .sg_rows = sg.rows,
                        .cells = sg.cells.ptr,
                        .margin_top = sg_margins.top,
                        .margin_bottom = sg_margins.bottom,
                        .margin_left = sg_margins.left,
                        .margin_right = sg_margins.right,
                    });
                }
                cached_subgrids = ctx.core.cached_subgrids_buf.items;

                // -------------------------------------------------
                // Row callback mode: send only dirty rows (global grid)
                // -------------------------------------------------

                const use_row_mode = (ctx.core.cb.on_vertices_row != null);
                if (use_row_mode) {
                    _ = try ensureMainSubgridRowIndex(
                        ctx.core,
                        cached_subgrids,
                        rows,
                    );
                    const row_cb = ctx.core.cb.on_vertices_row.?;
                    sent_main_by_rows = true;

                    const rebuild_all = ctx.core.grid.dirty_all;
                    var had_glyph_miss: bool = false;
                    const row_cells = &ctx.core.row_cells;
                    if (cols != 0) {
                        try row_cells.ensureTotalCapacity(ctx.core.alloc, cols);
                        row_cells.setLen(cols);
                    }

                    var log_dirty_rows: u32 = 0;
                    const log_enabled = ctx.core.log.cb != null;
                    var t_rows_start_ns: i128 = 0;
                    if (log_enabled) {
                        if (rebuild_all) {
                            log_dirty_rows = rows;
                        } else {
                            log_dirty_rows = 0;
                            var rr: u32 = 0;
                            while (rr < rows) : (rr += 1) {
                                if (ctx.core.grid.dirty_rows.isSet(@as(usize, rr))) {
                                    log_dirty_rows += 1;
                                }
                            }
                        }
                        t_rows_start_ns = clock.nowNs();
                        // Close pre_row "blackhole" bracket (started after cb_flush_begin).
                        const pre_row_us: i64 = @intCast(@divTrunc(@max(0, t_rows_start_ns - t_pre_row_start), 1000));
                        ctx.core.log.write("[perf] pre_row us={d} dirty_rows={d}\n", .{ pre_row_us, log_dirty_rows });
                    }

                    // Scroll-aware flush diagnostics: log scroll state and fast-path eligibility
                    if (log_enabled and scrolled_count > 0) {
                        const cached_sg_count = ctx.core.grid_entries.items.len;
                        ctx.core.log.write(
                            "[scroll_debug] flush_row_mode dirty_rows={d} rebuild_all={any} scrolled_count={d} scrolled_grid_ids[0]={d} subgrid_count={d} cursor_row={d} cursor_col={d}\n",
                            .{ log_dirty_rows, rebuild_all, scrolled_count, ctx.core.grid.scrolled_grid_ids[0], cached_sg_count, ctx.core.grid.cursor_row, ctx.core.grid.cursor_col },
                        );
                        if (ctx.core.grid.pending_scroll) |ps| {
                            ctx.core.log.write(
                                "[scroll_debug] pending_scroll grid={d} top={d} bot={d} left={d} right={d} rows={d} cols={d} target={d}x{d} win_pos_row={d} prev_cursor_row={any}\n",
                                .{ ps.grid_id, ps.top, ps.bot, ps.left, ps.right, ps.rows, ps.cols, ps.target_rows, ps.target_cols, ps.win_pos_row, ctx.core.grid.prev_cursor_row },
                            );
                            const tc = ctx.core.grid.scroll_touched_count;
                            if (tc > 0) {
                                const touched = ctx.core.grid.scroll_touched_rows[0..tc];
                                if (tc >= 4) {
                                    ctx.core.log.write("[scroll_debug] touched_rows count={d} rows=[{d},{d},{d},{d},...]\n", .{ tc, touched[0], touched[1], touched[2], touched[3] });
                                } else if (tc == 3) {
                                    ctx.core.log.write("[scroll_debug] touched_rows count={d} rows=[{d},{d},{d}]\n", .{ tc, touched[0], touched[1], touched[2] });
                                } else if (tc == 2) {
                                    ctx.core.log.write("[scroll_debug] touched_rows count={d} rows=[{d},{d}]\n", .{ tc, touched[0], touched[1] });
                                } else {
                                    ctx.core.log.write("[scroll_debug] touched_rows count={d} rows=[{d}]\n", .{ tc, touched[0] });
                                }
                            } else {
                                ctx.core.log.write("[scroll_debug] touched_rows count=0\n", .{});
                            }
                        }
                    }

                    // Performance counters for cache statistics
                    var perf_hl_cache_hits: u32 = 0;
                    var perf_hl_cache_misses: u32 = 0;
                    var perf_glyph_ascii_hits: u32 = 0;
                    var perf_glyph_ascii_misses: u32 = 0;
                    var perf_glyph_nonascii_hits: u32 = 0;
                    var perf_glyph_nonascii_misses: u32 = 0;
                    var perf_shape_cache_hits: u32 = 0;
                    var perf_shape_cache_misses: u32 = 0;
                    var perf_ascii_fast_path: u32 = 0;
                    var perf_row_prep_hl_init_us: i64 = 0;
                    var perf_row_prep_glyph_init_us: i64 = 0;
                    var perf_row_prep_scroll_ensure_us: i64 = 0;
                    var perf_row_prep_fast_path_check_us: i64 = 0;
                    var perf_row_prep_regen_build_us: i64 = 0;
                    var perf_row_prep_shift_us: i64 = 0;
                    var perf_cached_emit_rows: u32 = 0;
                    var perf_cached_emit_empty_rows: u32 = 0;
                    var perf_cached_emit_cb_sum_us: i64 = 0;
                    var perf_cached_emit_scan_us: i64 = 0;
                    var perf_row_compose_sum_us: i64 = 0;
                    var perf_row_total_sum_us: i64 = 0;
                    var perf_row_cache_store_sum_us: i64 = 0;
                    var perf_row_cb_sum_us: i64 = 0;
                    var perf_row_post_misc_sum_us: i64 = 0;
                    var perf_row_count: u32 = 0;
                    var perf_row_max_total_us: i64 = 0;
                    var perf_row_max_total_idx: u32 = 0;
                    var perf_row_max_cb_us: i64 = 0;
                    var perf_row_max_cb_idx: u32 = 0;
                    // Per-flush sums of generateRowVertices per-pass times (ns).
                    // Dumped in row_mode_pass_breakdown alongside row_mode_breakdown.
                    var perf_row_pass_bg_sum_ns: i64 = 0;
                    var perf_row_pass_under_sum_ns: i64 = 0;
                    var perf_row_pass_glyph_sum_ns: i64 = 0;
                    var perf_row_pass_strike_sum_ns: i64 = 0;
                    var perf_row_pass_overline_sum_ns: i64 = 0;
                    var perf_row_pass_glyph_max_ns: i64 = 0;
                    var perf_row_pass_glyph_max_idx: u32 = 0;
                    var perf_row_atlas_ensure_sum_ns: i64 = 0;
                    var perf_row_quad_emit_sum_ns: i64 = 0;

                    // Initialize dynamic caches if not already done
                    var t_prep_hl_init_start: i128 = 0;
                    if (log_enabled) t_prep_hl_init_start = clock.nowNs();
                    ctx.core.initHlCache() catch {
                        ctx.core.log.write("[flush] Failed to initialize hl cache\n", .{});
                    };
                    if (log_enabled) {
                        const t_prep_hl_init_end = clock.nowNs();
                        perf_row_prep_hl_init_us = @intCast(@divTrunc(@max(0, t_prep_hl_init_end - t_prep_hl_init_start), 1000));
                    }
                    var t_prep_glyph_init_start: i128 = 0;
                    if (log_enabled) t_prep_glyph_init_start = clock.nowNs();
                    ctx.core.initGlyphCache() catch {
                        ctx.core.log.write("[flush] Failed to initialize glyph cache\n", .{});
                    };
                    if (log_enabled) {
                        const t_prep_glyph_init_end = clock.nowNs();
                        perf_row_prep_glyph_init_us = @intCast(@divTrunc(@max(0, t_prep_glyph_init_end - t_prep_glyph_init_start), 1000));
                    }

                    // HL cache: direct-index for O(1) lookup
                    // Uses heap-allocated buffers from NvimCore (sized by hl_cache_size config)
                    const hl_cache: []highlight.ResolvedAttrWithStyles = ctx.core.hl_cache_buf orelse &.{};
                    const hl_valid: []bool = ctx.core.hl_valid_buf orelse &.{};
                    const hl_cache_limit: u32 = @intCast(hl_valid.len);
                    @memset(hl_valid, false);
                    // Glyph cache is persistent across flushes.
                    // It is only reset on font changes (see onGuifont).
                    // NOTE: Do NOT call resetGlyphCacheFlags() here. With Phase 2
                    // (core-managed atlas), clearing the cache every flush causes
                    // every glyph to be re-rasterized every frame, filling the atlas
                    // and triggering constant atlas resets.

                    // Get viewport margins for scrollable row detection
                    const main_margins = ctx.core.grid.getViewportMargins(1);

                    // Ensure scroll cache is sized for row-mode flush.
                    // This prepares the cache so fallback path can populate it
                    // for future fast-path reuse.
                    var t_prep_scroll_ensure_start: i128 = 0;
                    if (log_enabled) t_prep_scroll_ensure_start = clock.nowNs();
                    try ctx.core.ensureScrollCache(rows);
                    if (log_enabled) {
                        const t_prep_scroll_ensure_end = clock.nowNs();
                        perf_row_prep_scroll_ensure_us = @intCast(@divTrunc(@max(0, t_prep_scroll_ensure_end - t_prep_scroll_ensure_start), 1000));
                    }

                    var saw_atlas_reset: bool = false;
                    var atlas_retried: bool = false;
                    var used_scroll_fast_path: bool = false;

                    // Dirty-row composition uses persistent per-row buckets.
                    // Content-only flushes validate the layout in O(G), then
                    // visit only subgrids intersecting each dirty row.
                    retry_loop: while (true) {
                        // On retry: force all rows (stale UVs in non-dirty rows too)
                        const effective_rebuild_all = rebuild_all or atlas_retried;
                        if (atlas_retried) {
                            // Reset all per-pass mutable state for clean retry.
                            // used_scroll_fast_path gates the row loop below; the
                            // retry regenerates every row, so a stale true from the
                            // pre-reset pass would filter every row against an empty
                            // regen set and compose nothing. Matches the external-grid
                            // retry, which clears use_ext_scroll_fast_path the same way.
                            used_scroll_fast_path = false;
                            had_glyph_miss = false;
                            perf_hl_cache_hits = 0;
                            perf_hl_cache_misses = 0;
                            perf_glyph_ascii_hits = 0;
                            perf_glyph_ascii_misses = 0;
                            perf_glyph_nonascii_hits = 0;
                            perf_glyph_nonascii_misses = 0;
                            perf_shape_cache_hits = 0;
                            perf_shape_cache_misses = 0;
                            perf_ascii_fast_path = 0;
                            perf_row_prep_hl_init_us = 0;
                            perf_row_prep_glyph_init_us = 0;
                            perf_row_prep_scroll_ensure_us = 0;
                            perf_row_prep_fast_path_check_us = 0;
                            perf_row_prep_regen_build_us = 0;
                            perf_row_prep_shift_us = 0;
                            perf_cached_emit_rows = 0;
                            perf_cached_emit_empty_rows = 0;
                            perf_cached_emit_cb_sum_us = 0;
                            perf_cached_emit_scan_us = 0;
                            perf_row_compose_sum_us = 0;
                            perf_row_total_sum_us = 0;
                            perf_row_cache_store_sum_us = 0;
                            perf_row_cb_sum_us = 0;
                            perf_row_post_misc_sum_us = 0;
                            perf_row_count = 0;
                            perf_row_pass_bg_sum_ns = 0;
                            perf_row_pass_under_sum_ns = 0;
                            perf_row_pass_glyph_sum_ns = 0;
                            perf_row_pass_strike_sum_ns = 0;
                            perf_row_pass_overline_sum_ns = 0;
                            perf_row_pass_glyph_max_ns = 0;
                            perf_row_pass_glyph_max_idx = 0;
                            perf_row_atlas_ensure_sum_ns = 0;
                            perf_row_quad_emit_sum_ns = 0;
                            perf_row_max_total_us = 0;
                            perf_row_max_total_idx = 0;
                            perf_row_max_cb_us = 0;
                            perf_row_max_cb_idx = 0;
                            if (log_enabled) {
                                log_dirty_rows = rows; // Retry processes all rows
                                t_rows_start_ns = clock.nowNs();
                            }
                            // hl_valid does NOT need reset: hl data is atlas-independent
                            // glyph caches already cleared by resetGlyphCacheFlags() inside resetCoreAtlas()
                        }

                        // Scroll-aware fast path eligibility check
                        var t_prep_fast_path_check_start: i128 = 0;
                        if (log_enabled) t_prep_fast_path_check_start = clock.nowNs();
                        const scroll_check = checkScrollFastPath(
                            &ctx.core.grid,
                            effective_rebuild_all,
                            atlas_retried,
                            @intCast(scrolled_count),
                            cached_subgrids,
                        );
                        if (log_enabled) {
                            const t_prep_fast_path_check_end = clock.nowNs();
                            perf_row_prep_fast_path_check_us = @intCast(@divTrunc(@max(0, t_prep_fast_path_check_end - t_prep_fast_path_check_start), 1000));
                        }
                        if (log_enabled and scrolled_count > 0) {
                            ctx.core.log.write(
                                "[scroll_debug] fast_path eligible={any} reason={d} touched={d}\n",
                                .{ scroll_check.eligible, @intFromEnum(scroll_check.reason), ctx.core.grid.scroll_touched_count },
                            );
                        }

                        // Build the set of rows to compose this pass.
                        // Fast path: only touched_rows + prev_cursor_row (frontend retains other rows).
                        // Fallback: all dirty rows (existing behavior).
                        // regen_rows must hold every scroll_touched_rows entry plus the
                        // 2 bounds-checked cursor-row appends (prev/current cursor row).
                        // The dirty-rows-outside-scroll-region and subgrid-diff-rows
                        // appends below are separately bounds-checked at push time and
                        // safely disable the fast path on overflow instead of writing
                        // past the end, so only the touched-rows + cursor margin needs
                        // a compile-time guarantee here.
                        comptime {
                            if (grid_mod.Grid.SCROLL_TOUCHED_ROWS_CAP + 2 > 48) {
                                @compileError("regen_rows[48] no longer has enough margin for " ++
                                    "Grid.SCROLL_TOUCHED_ROWS_CAP + 2 cursor rows -- resize " ++
                                    "regen_rows in flush.zig to match");
                            }
                        }
                        var regen_rows: [48]u32 = undefined; // SCROLL_TOUCHED_ROWS_CAP touched + cursor + non-scroll dirty rows
                        var regen_count: u32 = 0;
                        var use_scroll_fast_path = scroll_check.eligible and !atlas_retried;

                        if (use_scroll_fast_path) {
                            var t_prep_regen_build_start: i128 = 0;
                            if (log_enabled) t_prep_regen_build_start = clock.nowNs();
                            // Add all touched rows (from grid_line after scroll)
                            const tc = ctx.core.grid.scroll_touched_count;
                            for (ctx.core.grid.scroll_touched_rows[0..tc]) |tr| {
                                if (tr < rows) {
                                    regen_rows[regen_count] = tr;
                                    regen_count += 1;
                                }
                            }
                            const scroll_op = scroll_check.scroll_op.?;
                            const scroll_grid_id = scroll_op.grid_id;
                            const cursor_rows = [_]?u32{
                                ctx.core.grid.prevCursorMainRowAfterScroll(scroll_op),
                                ctx.core.grid.currentCursorMainRow(scroll_grid_id),
                            };
                            for (cursor_rows) |maybe_row| {
                                if (maybe_row) |cursor_row| {
                                    if (cursor_row < rows) {
                                        var found = false;
                                        for (regen_rows[0..regen_count]) |existing| {
                                            if (existing == cursor_row) {
                                                found = true;
                                                break;
                                            }
                                        }
                                        if (!found and regen_count < regen_rows.len) {
                                            regen_rows[regen_count] = cursor_row;
                                            regen_count += 1;
                                        }
                                    }
                                }
                            }
                            if (log_enabled) {
                                const t_prep_regen_build_end = clock.nowNs();
                                perf_row_prep_regen_build_us = @intCast(@divTrunc(@max(0, t_prep_regen_build_end - t_prep_regen_build_start), 1000));
                            }

                            // Expand regen_rows with rows that need regeneration
                            // beyond the scroll-touched + cursor set.
                            //
                            // Two sources:
                            // (A) Dirty rows OUTSIDE the scroll region.
                            //     Events like win_float_pos, win_pos, win_hide mark
                            //     dirty_rows but do not call recordScrollTouchedRow.
                            //     scrollGrid's markDirtyRect covers the entire scroll
                            //     region, so we skip in-region dirty rows (handled by
                            //     cache shift).
                            //
                            // (B) Subgrid layout changes INSIDE the scroll region.
                            //     If any composited subgrid moved, appeared, or
                            //     disappeared since the last flush, the cached vertices
                            //     for affected rows are stale. Detected by comparing
                            //     current cached_subgrids against prev_subgrid_snapshots.
                            //
                            // Must run BEFORE shiftScrollCacheAndValidate so the
                            // cache shift correctly invalidates these rows.
                            if (!effective_rebuild_all) {
                                const scroll_region_top: u32 = scroll_op.top + scroll_op.win_pos_row;
                                const scroll_region_bot: u32 = scroll_op.bot + scroll_op.win_pos_row;

                                // (A) Dirty rows outside the scroll region.
                                var dr: u32 = 0;
                                while (dr < rows) : (dr += 1) {
                                    if (dr >= scroll_region_top and dr < scroll_region_bot) continue;
                                    if (!ctx.core.grid.dirty_rows.isSet(@as(usize, dr))) continue;
                                    var found = false;
                                    for (regen_rows[0..regen_count]) |rr| {
                                        if (rr == dr) {
                                            found = true;
                                            break;
                                        }
                                    }
                                    if (!found) {
                                        if (regen_count >= regen_rows.len) {
                                            use_scroll_fast_path = false;
                                            break;
                                        }
                                        regen_rows[regen_count] = dr;
                                        regen_count += 1;
                                    }
                                }

                                // (B) Subgrid layout diff inside scroll region.
                                if (use_scroll_fast_path) {
                                    var diff_buf: [32]u32 = undefined;
                                    const diff_count = collectSubgridDiffRows(
                                        ctx.core,
                                        cached_subgrids,
                                        scroll_region_top,
                                        scroll_region_bot,
                                        &diff_buf,
                                        regen_rows[0..regen_count],
                                    );
                                    // diff_count == diff_buf.len means the buffer
                                    // may have overflowed — fall back to full regen.
                                    if (diff_count >= diff_buf.len) {
                                        use_scroll_fast_path = false;
                                    }
                                    if (use_scroll_fast_path) {
                                        for (diff_buf[0..diff_count]) |row| {
                                            if (regen_count >= regen_rows.len) {
                                                use_scroll_fast_path = false;
                                                break;
                                            }
                                            regen_rows[regen_count] = row;
                                            regen_count += 1;
                                        }
                                    }
                                }
                            }

                            // --- Scroll cache: shift + y-adjust + validity check ---
                            const cache_ready = ctx.core.scroll_cache_rows == rows;

                            if (cache_ready) {
                                // position[1] is NDC: ndc_y = 1.0 - (y_px / dh) * 2.0
                                // delta_ndc_y = scroll_rows * cellH / dh * 2.0
                                const delta_y: f32 = @as(f32, @floatFromInt(scroll_op.rows)) * cellH / dh * 2.0;
                                const scroll_top: usize = @intCast(scroll_op.top + scroll_op.win_pos_row);
                                const scroll_bot: usize = @intCast(scroll_op.bot + scroll_op.win_pos_row);

                                var t_prep_shift_start: i128 = 0;
                                if (log_enabled) t_prep_shift_start = clock.nowNs();
                                const shift_result = shiftScrollCacheAndValidate(
                                    ctx.core,
                                    scroll_top,
                                    scroll_bot,
                                    scroll_op.rows,
                                    delta_y,
                                    rows,
                                    regen_rows[0..regen_count],
                                    ctx.core.cb.on_main_row_scroll == null,
                                );
                                if (log_enabled) {
                                    const t_prep_shift_end = clock.nowNs();
                                    perf_row_prep_shift_us = @intCast(@divTrunc(@max(0, t_prep_shift_end - t_prep_shift_start), 1000));
                                }
                                if (!shift_result.fast_path_ok) {
                                    use_scroll_fast_path = false;
                                    if (log_enabled) {
                                        ctx.core.log.write("[scroll_debug] fast_path cancelled: non-regen rows have invalid cache\n", .{});
                                    }
                                }
                            }

                            // Record final fast path decision for perf logging
                            used_scroll_fast_path = use_scroll_fast_path and cache_ready;
                            if (use_scroll_fast_path and !cache_ready) {
                            }

                            // Frontends that support main-row scroll shifting can update their
                            // row storage in one callback and avoid per-row cached emission.
                            if (used_scroll_fast_path) {
                                if (ctx.core.cb.on_main_row_scroll) |scroll_cb| {
                                    // The frontend shifts row slots and seeds
                                    // vacated rows, including empty cached rows.
                                    // Cached vertex positions therefore stay in
                                    // their original row-local coordinates.
                                    scroll_cb(
                                        ctx.core.ctx,
                                        scroll_op.top + scroll_op.win_pos_row,
                                        scroll_op.bot + scroll_op.win_pos_row,
                                        0,
                                        cols,
                                        scroll_op.rows,
                                        rows,
                                        cols,
                                    );
                                } else {
                                    var t_cached_emit_scan_start: i128 = 0;
                                    if (log_enabled) t_cached_emit_scan_start = clock.nowNs();
                                    for (0..rows) |ri| {
                                        const row_idx: u32 = @intCast(ri);
                                        // Skip regen rows (will be composed below)
                                        var is_regen = false;
                                        for (regen_rows[0..regen_count]) |rr| {
                                            if (rr == row_idx) {
                                                is_regen = true;
                                                break;
                                            }
                                        }
                                        if (is_regen) continue;

                                        if (ctx.core.scroll_cache_valid.isSet(ri)) {
                                            const cached = &ctx.core.scroll_cache.items[ri];
                                            if (log_enabled) {
                                                perf_cached_emit_rows += 1;
                                                if (cached.items.len == 0) perf_cached_emit_empty_rows += 1;
                                            }
                                            // Always emit, even when len==0 (empty/bg-only row).
                                            // Frontend retains previous content for rows with no callback,
                                            // so we must send empty updates to clear stale content.
                                            // len==0: pass null pointer with count 0.
                                            // Frontend must handle vert_count==0 as "clear row".
                                            const ptr: ?[*]const c_api.Vertex = if (cached.items.len > 0) cached.items.ptr else null;
                                            var t_cached_emit_cb_start: i128 = 0;
                                            if (log_enabled) t_cached_emit_cb_start = clock.nowNs();
                                            row_cb(ctx.core.ctx, 1, row_idx, 1, ptr, cached.items.len, 1, rows, cols);
                                            if (log_enabled) {
                                                const t_cached_emit_cb_end = clock.nowNs();
                                                perf_cached_emit_cb_sum_us += @intCast(@divTrunc(@max(0, t_cached_emit_cb_end - t_cached_emit_cb_start), 1000));
                                            }
                                        }
                                    }
                                    if (log_enabled) {
                                        const t_cached_emit_scan_end = clock.nowNs();
                                        perf_cached_emit_scan_us = @intCast(@divTrunc(@max(0, t_cached_emit_scan_end - t_cached_emit_scan_start), 1000));
                                    }
                                }
                            }

                            if (log_enabled) {
                                ctx.core.log.write(
                                    "[scroll_debug] fast_path regen_count={d}/{d} cache_ready={any}\n",
                                    .{ regen_count, rows, cache_ready },
                                );
                                log_dirty_rows = regen_count;
                            }
                        }

                        var r: u32 = 0;
                        while (r < rows) : (r += 1) {
                            if (used_scroll_fast_path) {
                                // Fast path: only compose rows in regen set
                                var in_regen = false;
                                for (regen_rows[0..regen_count]) |rr| {
                                    if (rr == r) {
                                        in_regen = true;
                                        break;
                                    }
                                }
                                if (!in_regen) continue;
                            } else if (!effective_rebuild_all) {
                                if (!ctx.core.grid.dirty_rows.isSet(@as(usize, r))) continue;
                            }

                            // A prior row_cb call this loop may have called
                            // zonvie_core_abort_flush (e.g. Windows row-buffer
                            // OOM). Stop emitting further rows into a frontend
                            // that already told us it cannot accept this flush —
                            // composing and sending them would be discarded work
                            // (the frontend cancels its whole bracket on abort).
                            if (ctx.core.flush_aborted) break;

                            var out = &ctx.core.row_verts;
                            out.clearRetainingCapacity();
                            var row_compose_us: i64 = 0;

                            // Row-mode timing for composition measurement
                            var t_row_compose_start: i128 = 0;
                            if (log_enabled) {
                                t_row_compose_start = clock.nowNs();
                            }

                            // Compose this row only (avoid full-screen tmp)
                            // SIMD-optimized: batch process consecutive cells with same hl_id
                            {
                                const row_start: usize = @as(usize, r) * @as(usize, cols);
                                const grid_cells = ctx.core.grid.cells;
                                setViewportRowDecoFlags(
                                    row_cells.deco_base_flags.items[0..cols],
                                    r,
                                    rows,
                                    cols,
                                    main_margins,
                                );
                                var c: u32 = 0;

                                while (c < cols) {
                                    const first_cell = grid_cells[row_start + @as(usize, c)];
                                    const run_hl = first_cell.hl;

                                    // Find run of consecutive cells with same hl_id
                                    // This reduces hl_cache lookups from O(cols) to O(unique_hl_ids)
                                    var run_end: u32 = c + 1;
                                    while (run_end < cols) : (run_end += 1) {
                                        if (grid_cells[row_start + @as(usize, run_end)].hl != run_hl) break;
                                    }

                                    // Get resolved attributes once for the entire run
                                    const a = blk: {
                                        if (run_hl < hl_cache_limit) {
                                            if (hl_valid[run_hl]) {
                                                perf_hl_cache_hits += 1;
                                                break :blk hl_cache[run_hl];
                                            }
                                            perf_hl_cache_misses += 1;
                                            const resolved = ctx.core.hl.getWithStyles(run_hl);
                                            hl_cache[run_hl] = resolved;
                                            hl_valid[run_hl] = true;
                                            break :blk resolved;
                                        }
                                        // Fallback for hl_id >= hl_cache_limit
                                        perf_hl_cache_misses += 1;
                                        break :blk ctx.core.hl.getWithStyles(run_hl);
                                    };

                                    // Batch write all cells in the run with same fg/bg/sp/style_flags
                                    // Only scalar differs per cell
                                    const fg = a.fg;
                                    const bg = a.bg;
                                    const sp = a.sp;
                                    const flags = a.style_flags;

                                    // Batch fill constant fields with @memset (compiles to SIMD)
                                    const rs: usize = @intCast(c);
                                    const re: usize = @intCast(run_end);
                                    @memset(row_cells.fg_rgbs.items[rs..re], fg);
                                    @memset(row_cells.bg_rgbs.items[rs..re], bg);
                                    @memset(row_cells.sp_rgbs.items[rs..re], sp);
                                    @memset(row_cells.grid_ids.items[rs..re], 1);
                                    @memset(row_cells.style_flags_arr.items[rs..re], flags);
                                    @memset(row_cells.overline_arr.items[rs..re], @intFromBool(a.overline));
                                    if (glow_enabled) {
                                        const has_glow: u8 = if (glow_all) 1 else if (glow_hl_ids) |ids| (if (ids.contains(run_hl)) @as(u8, 1) else 0) else 0;
                                        @memset(row_cells.glow_arr.items[rs..re], has_glow);
                                    }
                                    // Only scalars (codepoints) differ per cell
                                    // SIMD stride-2 extraction: Cell{cp,hl} → cp only
                                    simdExtractCp(grid_cells.ptr + row_start + rs, row_cells.scalars.items.ptr + rs, re - rs);

                                    c = run_end;
                                }

                                // Overlay sub-grids using pre-cached info (avoids per-row hash map lookups).
                                // Write each overlay's scroll flag while its CachedSubgrid is already
                                // in hand; a later per-cell lookup would rescan all grids and turn
                                // many-float composition into O(dirty_rows * cols * grids).
                                const bucket_start = ctx.core.main_subgrid_row_offsets.items[@intCast(r)];
                                const bucket_end = ctx.core.main_subgrid_row_offsets.items[@as(usize, @intCast(r)) + 1];
                                var bucket_pos = bucket_start;
                                while (bucket_pos < bucket_end) : (bucket_pos += 1) {
                                    const csg_index = ctx.core.main_subgrid_row_indices.items[bucket_pos];
                                    const csg = cached_subgrids[csg_index];
                                    if (r < csg.row_start or r >= csg.row_end) continue;
                                    const r2: u32 = r - csg.row_start;
                                    const subgrid_margins = grid_mod.ViewportMargins{
                                        .top = csg.margin_top,
                                        .bottom = csg.margin_bottom,
                                        .left = csg.margin_left,
                                        .right = csg.margin_right,
                                    };

                                    var c2: u32 = 0;
                                    while (c2 < csg.sg_cols) : (c2 += 1) {
                                        const tc = csg.col_start + c2;
                                        if (tc >= cols) break;

                                        const src_i: usize = @as(usize, r2) * @as(usize, csg.sg_cols) + @as(usize, c2);
                                        const cell = csg.cells[src_i];
                                        // Use HL cache with direct index for O(1) access
                                        const a2 = blk2: {
                                            if (cell.hl < hl_cache_limit) {
                                                if (hl_valid[cell.hl]) {
                                                    perf_hl_cache_hits += 1;
                                                    break :blk2 hl_cache[cell.hl];
                                                }
                                                perf_hl_cache_misses += 1;
                                                const resolved = ctx.core.hl.getWithStyles(cell.hl);
                                                hl_cache[cell.hl] = resolved;
                                                hl_valid[cell.hl] = true;
                                                break :blk2 resolved;
                                            }
                                            // Fallback for hl_id >= hl_cache_limit
                                            perf_hl_cache_misses += 1;
                                            break :blk2 ctx.core.hl.getWithStyles(cell.hl);
                                        };
                                        row_cells.set(@intCast(tc), cell.cp, a2.fg, a2.bg, a2.sp, csg.grid_id, a2.style_flags, @intFromBool(a2.overline));
                                        row_cells.deco_base_flags.items[@intCast(tc)] = if (viewportCellScrollable(
                                            r2,
                                            c2,
                                            csg.sg_rows,
                                            csg.sg_cols,
                                            subgrid_margins,
                                        )) c_api.DECO_SCROLLABLE else 0;
                                        if (glow_enabled) {
                                            row_cells.glow_arr.items[@intCast(tc)] = if (glow_all) 1 else if (glow_hl_ids) |ids| (if (ids.contains(cell.hl)) @as(u8, 1) else 0) else 0;
                                        }
                                    }
                                }
                            }

                            // Row-mode timing
                            var t_row_compose_end: i128 = 0;
                            var t_row_gen_start: i128 = 0;
                            if (log_enabled) {
                                t_row_compose_end = clock.nowNs();
                                t_row_gen_start = t_row_compose_end;
                            }

                            // Unified 5-pass vertex generation.
                            // On error (e.g. buffer allocation failure), skip this row
                            // so partial vertices are not cached or sent to the frontend.
                            // markAllDirty at the end of the flush ensures a retry, but
                            // that alone only makes the CONTENT eligible for regeneration
                            // next flush — it does not stop this flush's write-set (with
                            // this row silently missing/stale) from being committed as a
                            // successful frame. Setting flush_aborted makes
                            // zonvie_core_flush_was_aborted() tell both frontends to
                            // cancel this bracket instead, and stops the loop (see the
                            // flush_aborted check at the top of it) rather than composing
                            // further rows into a flush that's being discarded anyway.
                            const row_gen_stats = generateRowVertices(ctx.core, .{
                                .row = r,
                                .cols = cols,
                                .vw = dw,
                                .vh = dh,
                                .cell_w = cellW,
                                .cell_h = cellH,
                                .top_pad = topPad,
                                .default_bg = ctx.core.hl.default_bg,
                                .blur_enabled = ctx.core.blur_enabled,
                                .background_opacity = ctx.core.background_opacity,
                                .is_cmdline = false,
                                .glow_enabled = glow_enabled,
                            }, out) catch |err| {
                                out.clearRetainingCapacity();
                                had_glyph_miss = true;
                                ctx.core.flush_aborted = true;
                                if (Core.isHardRenderFailure(err)) ctx.core.failHardRender(err);
                                break;
                            };
                            had_glyph_miss = had_glyph_miss or row_gen_stats.had_glyph_miss;
                            perf_shape_cache_hits += row_gen_stats.shape_cache_hits;
                            perf_shape_cache_misses += row_gen_stats.shape_cache_misses;
                            perf_ascii_fast_path += row_gen_stats.ascii_fast_path_runs;
                            // Log row timing for performance measurement
                            if (log_enabled) {
                                const t_row_gen_end = clock.nowNs();
                                row_compose_us = @intCast(@divTrunc(@max(0, t_row_compose_end - t_row_compose_start), 1000));
                                const gen_us: i64 = @intCast(@divTrunc(@max(0, t_row_gen_end - t_row_gen_start), 1000));
                                const total_us: i64 = @intCast(@divTrunc(@max(0, t_row_gen_end - t_row_compose_start), 1000));
                                perf_row_compose_sum_us += row_compose_us;
                                perf_row_total_sum_us += total_us;
                                perf_row_count += 1;
                                if (total_us > perf_row_max_total_us) {
                                    perf_row_max_total_us = total_us;
                                    perf_row_max_total_idx = r;
                                }
                                // Accumulate per-pass times. Pass 3 (glyph) max-row tracked
                                // separately to surface the row most expensive in the dominant pass.
                                perf_row_pass_bg_sum_ns += row_gen_stats.bg_ns;
                                perf_row_pass_under_sum_ns += row_gen_stats.under_ns;
                                perf_row_pass_glyph_sum_ns += row_gen_stats.glyph_ns;
                                perf_row_pass_strike_sum_ns += row_gen_stats.strike_ns;
                                perf_row_pass_overline_sum_ns += row_gen_stats.overline_ns;
                                perf_row_atlas_ensure_sum_ns += row_gen_stats.atlas_ensure_ns;
                                perf_row_quad_emit_sum_ns += row_gen_stats.quad_emit_ns;
                                if (row_gen_stats.glyph_ns > perf_row_pass_glyph_max_ns) {
                                    perf_row_pass_glyph_max_ns = row_gen_stats.glyph_ns;
                                    perf_row_pass_glyph_max_idx = r;
                                }
                                // Per-row line: verbose tier only. Formatting + I/O for
                                // 2 lines x N rows per flush measurably perturbs the
                                // pipeline (~1-2ms/flush); the per-flush aggregates
                                // (row_mode_compose / row_mode_breakdown) stay in the
                                // normal tier and are built from the sums above.
                                if (ctx.core.log.verbose) {
                                    ctx.core.log.write(
                                        "[perf] row_mode row={d} cols={d} compose_us={d} gen_us={d} shape_us={d} shape_calls={d} sc_hit={d} sc_miss={d} ascii={d} total_us={d} bg_ns={d} under_ns={d} glyph_ns={d} strike_ns={d} overline_ns={d} ensure_ns={d} quad_ns={d}\n",
                                        .{ r, cols, row_compose_us, gen_us, row_gen_stats.shape_us, row_gen_stats.shape_calls, row_gen_stats.shape_cache_hits, row_gen_stats.shape_cache_misses, row_gen_stats.ascii_fast_path_runs, total_us, row_gen_stats.bg_ns, row_gen_stats.under_ns, row_gen_stats.glyph_ns, row_gen_stats.strike_ns, row_gen_stats.overline_ns, row_gen_stats.atlas_ensure_ns, row_gen_stats.quad_emit_ns },
                                    );
                                }
                            }

                            // Anomaly detection: warn if row has non-space cells but 0 glyph vertices
                            // (could indicate atlas/cache corruption causing all glyphs to fail)
                            if (log_enabled and scrolled_count > 0 and out.items.len == 0) {
                                // Check if this row actually has visible content
                                var has_visible: bool = false;
                                for (0..cols) |idx| {
                                    const sc = row_cells.scalars.items[idx];
                                    if (sc != 0 and sc != 32) {
                                        has_visible = true;
                                        break;
                                    }
                                }
                                if (has_visible) {
                                    ctx.core.log.write("[scroll_debug] ANOMALY row={d} has_visible_content=true vert_count=0\n", .{r});
                                }
                            }

                            // CHECK: atlas reset happened during glyph processing for this row.
                            // Already-sent rows have stale UVs → need to restart or abort.
                            if (ctx.core.atlas_reset_during_flush) {
                                saw_atlas_reset = true;
                                ctx.core.atlas_reset_during_flush = false; // Clear before retry

                                if (!atlas_retried) {
                                    // First occurrence: restart loop from row 0 with all rows
                                    atlas_retried = true;
                                    if (log_enabled) {
                                        ctx.core.log.write(
                                            "[scroll_debug] atlas_reset_during_flush at row={d}: restarting row loop\n",
                                            .{r},
                                        );
                                    }
                                    continue :retry_loop;
                                }
                                // A second reset invalidates rows already sent
                                // by the retry. Publishing empty replacements
                                // would commit a full-screen blank frame. Match
                                // the external-grid path: cancel this bracket
                                // and regenerate every layer next flush.
                                if (log_enabled) {
                                    ctx.core.log.write(
                                        "[scroll_debug] atlas_reset_during_flush at row={d} on retry: cancelling flush\n",
                                        .{r},
                                    );
                                }
                                ctx.core.flush_atlas_corrupted = true;
                                ctx.core.grid.markAllDirty();
                                ctx.core.invalidateScrollCache();
                                var reset_sg_it = ctx.core.grid.sub_grids.valueIterator();
                                while (reset_sg_it.next()) |sg| {
                                    sg.markAllDirty();
                                }
                                ctx.core.grid.cursor_rev +%= 1;
                                return;
                            }

                            var t_row_post_misc_before_cache_store: i128 = 0;
                            var t_row_cache_store_end: i128 = 0;
                            if (log_enabled) {
                                t_row_post_misc_before_cache_store = clock.nowNs();
                            }

                            // Charge the exact generated row before either
                            // retaining a scroll-cache copy or invoking the
                            // frontend. Overflow clusters therefore count all
                            // emitted glyphs, while blank cells are not charged
                            // for geometry they did not produce.
                            try replaceMainSurfaceRowVertexCount(ctx.core, r, out.items.len);

                            // Store composed vertices in scroll cache for future reuse
                            if (r < ctx.core.scroll_cache_rows) {
                                var cached_row = &ctx.core.scroll_cache.items[r];
                                if (cached_row.ensureTotalCapacity(ctx.core.alloc, out.items.len)) |_| {
                                    cached_row.clearRetainingCapacity();
                                    cached_row.appendSliceAssumeCapacity(out.items);
                                    ctx.core.scroll_cache_valid.set(r);
                                } else |_| {
                                    ctx.core.scroll_cache_valid.unset(r);
                                }
                            }

                            var t_row_before_cb: i128 = 0;
                            if (log_enabled) {
                                t_row_cache_store_end = clock.nowNs();
                                t_row_before_cb = t_row_cache_store_end;
                            }

                            // Contract: row_count == 1, grid_id == 1 for main window
                            row_cb(ctx.core.ctx, 1, r, 1, out.items.ptr, out.items.len, 1, rows, cols); // grid_id=1 (main), flags=1 (ZONVIE_VERT_UPDATE_MAIN)

                            if (log_enabled) {
                                const t_row_after_cb = clock.nowNs();
                                const cache_store_us: i64 = @intCast(@divTrunc(@max(0, t_row_cache_store_end - t_row_post_misc_before_cache_store), 1000));
                                const row_cb_us: i64 = @intCast(@divTrunc(@max(0, t_row_after_cb - t_row_before_cb), 1000));
                                const total_us: i64 = @intCast(@divTrunc(@max(0, t_row_after_cb - t_row_compose_start), 1000));
                                const known_total_us = row_compose_us + cache_store_us + row_cb_us;
                                const post_misc_us: i64 = @max(0, total_us - known_total_us);
                                perf_row_cache_store_sum_us += cache_store_us;
                                perf_row_cb_sum_us += row_cb_us;
                                perf_row_post_misc_sum_us += post_misc_us;
                                if (row_cb_us > perf_row_max_cb_us) {
                                    perf_row_max_cb_us = row_cb_us;
                                    perf_row_max_cb_idx = r;
                                }
                                // Per-row line: verbose tier only (see row_mode above).
                                if (ctx.core.log.verbose) {
                                    ctx.core.log.write(
                                        "[perf] row_mode_post row={d} cache_store_us={d} row_cb_us={d} post_misc_us={d}\n",
                                        .{ r, cache_store_us, row_cb_us, post_misc_us },
                                    );
                                }
                            }
                        }
                        break; // Normal exit from retry_loop
                    }

                    // Snapshot overlay coverage for next flush's diff detection.
                    saveSubgridSnapshots(ctx.core, cached_subgrids);

                    // A row_cb call in the loop above may have aborted this
                    // flush (e.g. Windows row-buffer OOM). The frontend
                    // cancels its whole triple-buffer bracket on abort — none
                    // of what was composed above actually reached the
                    // screen. clearDirty() here would erase the record that
                    // this content still needs sending, and syncing
                    // last_sent_content_rev below would make need_main false
                    // on the next flush attempt — together these would make
                    // zonvie_core_retry_flush's has_pending check see nothing
                    // pending, permanently losing this content until an
                    // unrelated future edit happens to touch the same rows.
                    if (!ctx.core.flush_aborted) ctx.core.grid.clearDirty();
                    if (had_glyph_miss or saw_atlas_reset) {
                        main_retry_required = true;
                        ctx.core.grid.markAllDirty();
                        // Atlas reset invalidates cached UVs in scroll cache — but only
                        // when the retry was aborted (partial/stale data) or no retry ran.
                        // When the retry succeeded, all rows were regenerated with the
                        // fresh atlas, so scroll cache entries are already valid.
                        // Invalidating here would undo that work and force a full
                        // regeneration on the next scroll flush (~65-80ms for CJK).
                        if (saw_atlas_reset) {
                            if (!atlas_retried) {
                                ctx.core.invalidateScrollCache();
                            }
                            var sg_it = ctx.core.grid.sub_grids.valueIterator();
                            while (sg_it.next()) |sg| {
                                sg.markAllDirty();
                            }
                            // The cursor is a separate vertex consumer gated
                            // on cursor_rev alone (main and external both) —
                            // an atlas reset invalidates its cached UVs too,
                            // but dirtying grid/sub_grid content above never
                            // touches this counter.
                            ctx.core.grid.cursor_rev +%= 1;
                        }
                        if (log_enabled) {
                            ctx.core.log.write("[scroll_debug] markAllDirty: glyph_miss={any} saw_atlas_reset={any} scrolled={d}\n", .{
                                had_glyph_miss, saw_atlas_reset, scrolled_count,
                            });
                        }
                    }
                    // Clear unconditionally so sendExternalGridVertices sees clean state
                    // (sub_grids already marked dirty above if needed)
                    ctx.core.atlas_reset_during_flush = false;
                    // Skip on abort — see the clearDirty() guard above. Syncing
                    // this would make the next flush's need_main check (and
                    // zonvie_core_retry_flush's has_pending check) see no
                    // pending main content, even though nothing was actually
                    // committed this attempt.
                    if (!ctx.core.flush_aborted) ctx.core.last_sent_content_rev = ctx.core.grid.content_rev;
                    if (log_enabled) {
                        const t_rows_done_ns: i128 = clock.nowNs();
                        const dur_us: i64 = @intCast(@divTrunc(@max(0, t_rows_done_ns - t_rows_start_ns), 1000));
                        ctx.core.log.write(
                            "[perf] row_mode_compose rows={d} cols={d} dirty_rows={d} subgrids={d} us={d} scroll_fast_path={any}\n",
                            .{ rows, cols, log_dirty_rows, ctx.core.grid_entries.items.len, dur_us, used_scroll_fast_path },
                        );
                        ctx.core.log.write(
                            "[perf] row_mode_breakdown rows={d} compose_sum_us={d} cache_store_sum_us={d} row_cb_sum_us={d} post_misc_sum_us={d} total_sum_us={d} max_total_row={d} max_total_us={d} max_cb_row={d} max_cb_us={d}\n",
                            .{
                                perf_row_count,
                                perf_row_compose_sum_us,
                                perf_row_cache_store_sum_us,
                                perf_row_cb_sum_us,
                                perf_row_post_misc_sum_us,
                                perf_row_total_sum_us,
                                perf_row_max_total_idx,
                                perf_row_max_total_us,
                                perf_row_max_cb_idx,
                                perf_row_max_cb_us,
                            },
                        );
                        // generateRowVertices per-pass aggregate. Pass 3 (glyph) sum
                        // includes shape callback time; subtract row_mode shape sum to
                        // isolate glyph-emit cost. max_glyph_row pinpoints worst row.
                        // ensure_sum_ns and quad_emit_sum_ns sub-divide glyph_sum_ns;
                        // residual (glyph - shape*1000 - ensure - quad) ≈ cache lookup.
                        // Those two cost two clock reads per emitted quad, so they are
                        // only measured in the verbose tier and report -1 otherwise.
                        ctx.core.log.write(
                            "[perf] row_mode_pass_breakdown rows={d} bg_sum_ns={d} under_sum_ns={d} glyph_sum_ns={d} strike_sum_ns={d} overline_sum_ns={d} max_glyph_row={d} max_glyph_ns={d} ensure_sum_ns={d} quad_emit_sum_ns={d}\n",
                            .{
                                perf_row_count,
                                perf_row_pass_bg_sum_ns,
                                perf_row_pass_under_sum_ns,
                                perf_row_pass_glyph_sum_ns,
                                perf_row_pass_strike_sum_ns,
                                perf_row_pass_overline_sum_ns,
                                perf_row_pass_glyph_max_idx,
                                perf_row_pass_glyph_max_ns,
                                if (ctx.core.log.verbose) perf_row_atlas_ensure_sum_ns else -1,
                                if (ctx.core.log.verbose) perf_row_quad_emit_sum_ns else -1,
                            },
                        );
                        ctx.core.log.write(
                            "[perf] row_mode_prep hl_init_us={d} glyph_init_us={d} scroll_ensure_us={d} fast_path_check_us={d} regen_build_us={d} shift_us={d}\n",
                            .{
                                perf_row_prep_hl_init_us,
                                perf_row_prep_glyph_init_us,
                                perf_row_prep_scroll_ensure_us,
                                perf_row_prep_fast_path_check_us,
                                perf_row_prep_regen_build_us,
                                perf_row_prep_shift_us,
                            },
                        );
                        ctx.core.log.write(
                            "[perf] row_mode_cached_emit rows={d} empty_rows={d} scan_us={d} row_cb_sum_us={d}\n",
                            .{
                                perf_cached_emit_rows,
                                perf_cached_emit_empty_rows,
                                perf_cached_emit_scan_us,
                                perf_cached_emit_cb_sum_us,
                            },
                        );
                        // Cache statistics: helps tune cache sizes and identify bottlenecks
                        ctx.core.log.write(
                            "[perf] hl_cache hits={d} misses={d}\n",
                            .{ perf_hl_cache_hits, perf_hl_cache_misses },
                        );
                        ctx.core.log.write(
                            "[perf] glyph_cache ascii_hits={d} ascii_misses={d} nonascii_hits={d} nonascii_misses={d}\n",
                            .{ perf_glyph_ascii_hits, perf_glyph_ascii_misses, perf_glyph_nonascii_hits, perf_glyph_nonascii_misses },
                        );
                        ctx.core.log.write(
                            "[perf] shape_cache hits={d} misses={d} size={d} ascii_fast={d}\n",
                            .{ perf_shape_cache_hits, perf_shape_cache_misses, ctx.core.shape_cache_sets * @as(u32, nvim_core.SHAPE_CACHE_WAYS), perf_ascii_fast_path },
                        );
                    }
                } else {
                    const n_cells2: usize = @as(usize, rows) * @as(usize, cols);

                    // Use persistent buffer (zero-allocation hot path)
                    try ctx.core.tmp_cells.ensureTotalCapacity(ctx.core.alloc, n_cells2);
                    ctx.core.tmp_cells.clearRetainingCapacity();
                    ctx.core.tmp_cells.setLen(n_cells2);
                    tmp = &ctx.core.tmp_cells;

                    // Initialize hl_cache for non-row-mode (same as row-mode path)
                    ctx.core.initHlCache() catch {
                        ctx.core.log.write("[flush] Failed to initialize hl cache (non-row-mode)\n", .{});
                    };
                    const nr_hl_cache: []highlight.ResolvedAttrWithStyles = ctx.core.hl_cache_buf orelse &.{};
                    const nr_hl_valid: []bool = ctx.core.hl_valid_buf orelse &.{};
                    const nr_hl_cache_limit: u32 = @intCast(nr_hl_valid.len);
                    @memset(nr_hl_valid, false);
                    const nr_main_margins = ctx.core.grid.getViewportMargins(1);
                    @memset(tmp.deco_base_flags.items, 0);

                    // 1) draw global grid(1) with RLE batching + hl_cache
                    const grid_cells = ctx.core.grid.cells;
                    var row_i: u32 = 0;
                    while (row_i < rows) : (row_i += 1) {
                        const row_start: usize = @as(usize, row_i) * @as(usize, cols);
                        setViewportRowDecoFlags(
                            tmp.deco_base_flags.items[row_start .. row_start + cols],
                            row_i,
                            rows,
                            cols,
                            nr_main_margins,
                        );
                        var c: u32 = 0;

                        while (c < cols) {
                            const first_cell = grid_cells[row_start + @as(usize, c)];
                            const run_hl = first_cell.hl;

                            // Find run of consecutive cells with same hl_id
                            var run_end: u32 = c + 1;
                            while (run_end < cols) : (run_end += 1) {
                                if (grid_cells[row_start + @as(usize, run_end)].hl != run_hl) break;
                            }

                            // Get resolved attributes with cache
                            const a = blk: {
                                if (run_hl < nr_hl_cache_limit) {
                                    if (nr_hl_valid[run_hl]) {
                                        break :blk nr_hl_cache[run_hl];
                                    }
                                    const resolved = ctx.core.hl.getWithStyles(run_hl);
                                    nr_hl_cache[run_hl] = resolved;
                                    nr_hl_valid[run_hl] = true;
                                    break :blk resolved;
                                }
                                break :blk ctx.core.hl.getWithStyles(run_hl);
                            };

                            const fg = a.fg;
                            const bg = a.bg;
                            const sp = a.sp;
                            const flags = a.style_flags;

                            // Batch fill constant fields with @memset
                            const fill_start: usize = row_start + @as(usize, c);
                            const fill_end: usize = row_start + @as(usize, run_end);
                            @memset(tmp.fg_rgbs.items[fill_start..fill_end], fg);
                            @memset(tmp.bg_rgbs.items[fill_start..fill_end], bg);
                            @memset(tmp.sp_rgbs.items[fill_start..fill_end], sp);
                            @memset(tmp.grid_ids.items[fill_start..fill_end], 1);
                            @memset(tmp.style_flags_arr.items[fill_start..fill_end], flags);
                            @memset(tmp.overline_arr.items[fill_start..fill_end], @intFromBool(a.overline));
                            if (glow_enabled) {
                                const has_glow_nr: u8 = if (glow_all) 1 else if (glow_hl_ids) |ids| (if (ids.contains(run_hl)) @as(u8, 1) else 0) else 0;
                                @memset(tmp.glow_arr.items[fill_start..fill_end], has_glow_nr);
                            }
                            for (fill_start..fill_end) |i| {
                                tmp.scalars.items[i] = grid_cells[i].cp;
                            }

                            c = run_end;
                        }
                    }

                    // Then overlay subgrids (with hl_cache)
                    for (ctx.core.grid_entries.items) |ent| {
                        const subgrid_id = ent.grid_id;
                        const pos = ctx.core.grid.win_pos.get(subgrid_id) orelse continue;
                        const sg = ctx.core.grid.sub_grids.get(subgrid_id) orelse continue;
                        const sg_margins = ctx.core.grid.getViewportMargins(subgrid_id);

                        // Skip float windows anchored to external grids (they belong to that external window)
                        if (pos.anchor_grid != 1 and ctx.core.grid.external_grids.contains(pos.anchor_grid)) continue;

                        var r2: u32 = 0;
                        while (r2 < sg.rows) : (r2 += 1) {
                            // Saturating: hostile win_pos rows must not
                            // overflow-panic (saturated value fails the bound
                            // check below and breaks out).
                            const tr = pos.row +| r2;
                            if (tr >= rows) break;

                            const sg_row_start: usize = @as(usize, r2) * @as(usize, sg.cols);
                            const dst_row_start: usize = @as(usize, tr) * @as(usize, cols);
                            var c2: u32 = 0;

                            while (c2 < sg.cols) {
                                const tc = pos.col +| c2;
                                if (tc >= cols) break;

                                const first_cell = sg.cells[sg_row_start + @as(usize, c2)];
                                const run_hl = first_cell.hl;

                                // Find run of consecutive subgrid cells with same hl_id
                                var run_end: u32 = c2 + 1;
                                while (run_end < sg.cols and pos.col +| run_end < cols) : (run_end += 1) {
                                    if (sg.cells[sg_row_start + @as(usize, run_end)].hl != run_hl) break;
                                }

                                // Get resolved attributes with cache
                                const a = blk: {
                                    if (run_hl < nr_hl_cache_limit) {
                                        if (nr_hl_valid[run_hl]) {
                                            break :blk nr_hl_cache[run_hl];
                                        }
                                        const resolved = ctx.core.hl.getWithStyles(run_hl);
                                        nr_hl_cache[run_hl] = resolved;
                                        nr_hl_valid[run_hl] = true;
                                        break :blk resolved;
                                    }
                                    break :blk ctx.core.hl.getWithStyles(run_hl);
                                };

                                const fg = a.fg;
                                const bg = a.bg;
                                const sp = a.sp;
                                const flags = a.style_flags;
                                const ol: u8 = @intFromBool(a.overline);

                                var i: u32 = c2;
                                while (i < run_end) : (i += 1) {
                                    const ti = pos.col +| i;
                                    if (ti >= cols) break;

                                    const src_cell = sg.cells[sg_row_start + @as(usize, i)];
                                    const dst_index = dst_row_start + @as(usize, ti);
                                    tmp.set(dst_index, src_cell.cp, fg, bg, sp, subgrid_id, flags, ol);
                                    tmp.deco_base_flags.items[dst_index] = if (viewportCellScrollable(
                                        r2,
                                        i,
                                        sg.rows,
                                        sg.cols,
                                        sg_margins,
                                    )) c_api.DECO_SCROLLABLE else 0;
                                    if (glow_enabled) {
                                        tmp.glow_arr.items[dst_index] = if (glow_all) 1 else if (glow_hl_ids) |ids| (if (ids.contains(run_hl)) @as(u8, 1) else 0) else 0;
                                    }
                                }

                                c2 = run_end;
                            }
                        }
                    }
                }

                if (!sent_main_by_rows) {
                    // Partial-only ABI consumers use the same five-pass row
                    // generator as row-mode consumers. Keeping one generator
                    // preserves shaping, full-cluster overflow keys, decoration
                    // ordering, and atlas transaction semantics in both modes.
                    const row_cells = &ctx.core.row_cells;
                    const row_len: usize = @intCast(cols);
                    try row_cells.ensureTotalCapacity(ctx.core.alloc, row_len);
                    row_cells.setLen(row_len);

                    const perf_log_enabled = ctx.core.log.cb != null;
                    const t_full_start: i128 = if (perf_log_enabled) clock.nowNs() else 0;
                    for (&ctx.core.partial_layer_verts) |*layer| layer.clearRetainingCapacity();
                    const row_scratch = &ctx.core.row_verts;
                    var had_glyph_miss = false;
                    var generated_vertex_count: usize = 0;
                    var r: u32 = 0;
                    while (r < rows) : (r += 1) {
                        const row_start: usize = @as(usize, r) * row_len;
                        const row_end = row_start + row_len;

                        @memcpy(row_cells.scalars.items, tmp.scalars.items[row_start..row_end]);
                        @memcpy(row_cells.fg_rgbs.items, tmp.fg_rgbs.items[row_start..row_end]);
                        @memcpy(row_cells.bg_rgbs.items, tmp.bg_rgbs.items[row_start..row_end]);
                        @memcpy(row_cells.sp_rgbs.items, tmp.sp_rgbs.items[row_start..row_end]);
                        @memcpy(row_cells.grid_ids.items, tmp.grid_ids.items[row_start..row_end]);
                        @memcpy(row_cells.style_flags_arr.items, tmp.style_flags_arr.items[row_start..row_end]);
                        @memcpy(row_cells.overline_arr.items, tmp.overline_arr.items[row_start..row_end]);
                        @memcpy(row_cells.deco_base_flags.items, tmp.deco_base_flags.items[row_start..row_end]);
                        if (glow_enabled) {
                            @memcpy(row_cells.glow_arr.items, tmp.glow_arr.items[row_start..row_end]);
                        } else {
                            @memset(row_cells.glow_arr.items, 0);
                        }

                        row_scratch.clearRetainingCapacity();
                        const row_stats = generateRowVertices(ctx.core, .{
                            .row = r,
                            .cols = cols,
                            .vw = dw,
                            .vh = dh,
                            .cell_w = cellW,
                            .cell_h = cellH,
                            .top_pad = topPad,
                            .default_bg = ctx.core.hl.default_bg,
                            .blur_enabled = ctx.core.blur_enabled,
                            .background_opacity = ctx.core.background_opacity,
                            .is_cmdline = false,
                            .glow_enabled = glow_enabled,
                            .max_vertices = MAX_VERTICES_PER_CALLBACK - generated_vertex_count,
                        }, row_scratch) catch |err| {
                            main.clearRetainingCapacity();
                            ctx.core.flush_aborted = true;
                            if (Core.isHardRenderFailure(err)) ctx.core.failHardRender(err);
                            return;
                        };
                        had_glyph_miss = had_glyph_miss or row_stats.had_glyph_miss;
                        generated_vertex_count = std.math.add(
                            usize,
                            generated_vertex_count,
                            row_scratch.items.len,
                        ) catch return vertexBudgetExceeded(ctx.core);
                        if (row_scratch.items.len > MAX_VERTICES_PER_CALLBACK or
                            generated_vertex_count > MAX_VERTICES_PER_CALLBACK)
                        {
                            return vertexBudgetExceeded(ctx.core);
                        }

                        // Keep backgrounds for every row before any glyph or
                        // decoration layer. Appending a complete five-pass row
                        // at once lets the next row's background overpaint a
                        // glyph that extends beyond its cell bounds.
                        try main.appendSlice(ctx.core.alloc, row_scratch.items[0..row_stats.pass_ends[0]]);
                        for (&ctx.core.partial_layer_verts, 0..) |*layer, layer_index| {
                            const layer_start = row_stats.pass_ends[layer_index];
                            const layer_end = row_stats.pass_ends[layer_index + 1];
                            try layer.appendSlice(ctx.core.alloc, row_scratch.items[layer_start..layer_end]);
                        }
                    }
                    for (&ctx.core.partial_layer_verts) |*layer| {
                        try main.appendSlice(ctx.core.alloc, layer.items);
                    }
                    try replaceMainFlatVertexCount(ctx.core, main.items.len);

                    if (had_glyph_miss) {
                        main_retry_required = true;
                        ctx.core.grid.markAllDirty();
                    }
                    if (!ctx.core.flush_aborted) {
                        ctx.core.last_sent_content_rev = ctx.core.grid.content_rev;
                    }
                    if (perf_log_enabled) {
                        const total_ns: i128 = clock.nowNs() - t_full_start;
                        ctx.core.log.write(
                            "[perf] full_redraw_shared rows={d} cols={d} total_ns={d}\n",
                            .{ rows, cols, total_ns },
                        );
                    }
                }
            }

            // ----------------------------
            // Rebuild CURSOR only when needed
            // ----------------------------
            if (need_cursor) {
                cursor.clearRetainingCapacity();

                // Skip cursor generation if cursor is NOT on global grid and NOT embedded in global grid
                // Embedded grids (win_pos) have their cursor drawn on global grid via coordinate transform
                // External/special grids (external_grids, cmdline, etc.) render their own cursor
                const cursor_grid = ctx.core.grid.cursor_grid;
                // A float that is also an external (separate-window) grid is
                // composited into the main grid via win_pos AND rendered in its
                // own window. Its window draws the real, shape-aware cursor, so
                // the main grid must NOT also embed one — otherwise a second,
                // stale block cursor is drawn at the float's anchor and never
                // tracks the mode (block / vertical / horizontal) change.
                const cursor_embedded_in_main = (cursor_grid == 1) or
                    (ctx.core.grid.win_pos.contains(cursor_grid) and
                        !ctx.core.grid.external_grids.contains(cursor_grid));

                if (cursor_embedded_in_main) {
                    try cursor.ensureTotalCapacity(ctx.core.alloc, 64);
                }

                if (cursor_embedded_in_main and cursor_out.enabled != 0) {
                    const cur_row = cursor_out.row;
                    const cur_col = cursor_out.col;
                    if (cur_row < rows and cur_col < cols) {
                        const x0 = @as(f32, @floatFromInt(cur_col)) * cellW;
                        const y0 = @as(f32, @floatFromInt(cur_row)) * cellH;

                        const pct_u32 = @max(@as(u32, 1), @min(cursor_out.cell_percentage, 100));
                        const pct: f32 = @floatFromInt(pct_u32);

                        const tW = cellW * pct / 100.0;
                        const tH = cellH * pct / 100.0;

                        // Get the cell at cursor position (grid-relative coordinates)
                        const cursor_grid_id = ctx.core.grid.cursor_grid;
                        const grid_cursor_row = ctx.core.grid.cursor_row;
                        const grid_cursor_col = ctx.core.grid.cursor_col;
                        const cursor_cell = ctx.core.grid.getCellGrid(cursor_grid_id, grid_cursor_row, grid_cursor_col);
                        const cursor_cp = cursor_cell.cp;

                        // Check if this is a double-width character
                        // Next cell having cp == 0 indicates a continuation cell for wide char
                        var is_double_width = false;
                        if (cursor_grid_id == 1) {
                            if (grid_cursor_col + 1 < ctx.core.grid.cols) {
                                const next_cell = ctx.core.grid.getCell(grid_cursor_row, grid_cursor_col + 1);
                                if (next_cell.cp == 0) {
                                    is_double_width = true;
                                }
                            }
                        } else {
                            if (ctx.core.grid.sub_grids.getPtr(cursor_grid_id)) |sg| {
                                if (grid_cursor_col + 1 < sg.cols) {
                                    const next_idx: usize = @as(usize, grid_cursor_row) * @as(usize, sg.cols) + @as(usize, grid_cursor_col + 1);
                                    if (next_idx < sg.cells.len and sg.cells[next_idx].cp == 0) {
                                        is_double_width = true;
                                    }
                                }
                            }
                        }

                        const cursor_width: f32 = if (is_double_width) cellW * 2 else cellW;

                        const rx0: f32 = x0;
                        var ry0: f32 = y0;
                        var rx1: f32 = x0 + cursor_width;
                        const ry1: f32 = y0 + cellH;

                        switch (@intFromEnum(cursor_out.shape)) {
                            1 => { // vertical
                                rx1 = x0 + tW;
                            },
                            2 => { // horizontal
                                ry0 = y0 + (cellH - tH);
                            },
                            else => { // block
                                // full cell (or double-width)
                            },
                        }

                        // Push cursor background quad with DECO_CURSOR flag
                        // (so shader treats it as decoration, not background with transparency)
                        {
                            const pts = Helpers.ndc4(rx0, ry0, rx1, ry1, dw, dh);
                            const p0 = pts[0];
                            const p1 = pts[1];
                            const p2 = pts[2];
                            const p3 = pts[3];
                            const col = Helpers.rgb(cursor_out.bgRGB);
                            const solid_uv = Helpers.solid_uv;

                            try cursor.ensureUnusedCapacity(ctx.core.alloc, 6);
                            cursor.appendAssumeCapacity(.{ .position = p0, .texCoord = solid_uv, .color = col, .grid_id = cursor_grid_id, .deco_flags = c_api.DECO_CURSOR | c_api.DECO_SCROLLABLE, .deco_phase = 0 });
                            cursor.appendAssumeCapacity(.{ .position = p2, .texCoord = solid_uv, .color = col, .grid_id = cursor_grid_id, .deco_flags = c_api.DECO_CURSOR | c_api.DECO_SCROLLABLE, .deco_phase = 0 });
                            cursor.appendAssumeCapacity(.{ .position = p1, .texCoord = solid_uv, .color = col, .grid_id = cursor_grid_id, .deco_flags = c_api.DECO_CURSOR | c_api.DECO_SCROLLABLE, .deco_phase = 0 });
                            cursor.appendAssumeCapacity(.{ .position = p1, .texCoord = solid_uv, .color = col, .grid_id = cursor_grid_id, .deco_flags = c_api.DECO_CURSOR | c_api.DECO_SCROLLABLE, .deco_phase = 0 });
                            cursor.appendAssumeCapacity(.{ .position = p2, .texCoord = solid_uv, .color = col, .grid_id = cursor_grid_id, .deco_flags = c_api.DECO_CURSOR | c_api.DECO_SCROLLABLE, .deco_phase = 0 });
                            cursor.appendAssumeCapacity(.{ .position = p3, .texCoord = solid_uv, .color = col, .grid_id = cursor_grid_id, .deco_flags = c_api.DECO_CURSOR | c_api.DECO_SCROLLABLE, .deco_phase = 0 });
                        }

                        // Render cursor text (character under cursor) with inverted color
                        // Only for block cursor and non-space characters
                        if (@intFromEnum(cursor_out.shape) == 0 and cursor_cp != 0 and cursor_cp != ' ') {
                            // Block element under cursor: geometric rendering
                            if (block_elements.isBlockElement(cursor_cp)) {
                                const blk_geo = block_elements.getBlockGeometry(cursor_cp);
                                if (blk_geo.count > 0) {
                                    try cursor.ensureUnusedCapacity(ctx.core.alloc, @as(usize, blk_geo.count) * 6);
                                    const cursor_fg_col = Helpers.rgb(cursor_out.fgRGB);
                                    for (blk_geo.rects[0..blk_geo.count]) |rect| {
                                        // DECO_CURSOR for the same reason the cursor background
                                        // quad above carries it: without it these rects are plain
                                        // solid quads, and the shader fades plain solids to
                                        // `backgroundAlpha` once blur is on. The box behind the
                                        // glyph would stay opaque while the glyph itself went
                                        // translucent. The external-grid path already sets it.
                                        Helpers.pushSolidQuadAssumeCapacity(cursor, x0 + rect.x0 * cursor_width, y0 + rect.y0 * cellH, x0 + rect.x1 * cursor_width, y0 + rect.y1 * cellH, cursor_fg_col, dw, dh, cursor_grid_id, c_api.DECO_CURSOR | c_api.DECO_SCROLLABLE);
                                    }
                                }
                            } else {
                                const ensure_base = ctx.core.cb.on_atlas_ensure_glyph;
                                const ensure_styled = ctx.core.cb.on_atlas_ensure_glyph_styled;

                                if (ctx.core.isPhase2Atlas() or ensure_base != null or ensure_styled != null) {
                                    var ge: c_api.GlyphEntry = undefined;
                                    var glyph_ok = false;

                                    // Resolve style_flags for the cell under the cursor
                                    const cursor_style: u8 = ctx.core.hl.getWithStyles(cursor_cell.hl).style_flags;
                                    const cursor_style_mask = cursor_style & (STYLE_BOLD | STYLE_ITALIC);
                                    const cursor_c_style: u32 =
                                        @as(u32, if (cursor_style & STYLE_BOLD != 0) c_api.STYLE_BOLD else 0) |
                                        @as(u32, if (cursor_style & STYLE_ITALIC != 0) c_api.STYLE_ITALIC else 0);

                                    // Set emoji cluster context for cursor cell if its overflow
                                    // contains emoji-significant codepoints (VS16, ZWJ, skin tone).
                                    if (ctx.core.grid.getOverflow(cursor_grid_id, grid_cursor_row, grid_cursor_col)) |extras| {
                                        const is_emoji = isEmojiPresentation(cursor_cp) or for (extras) |e| {
                                            if (e == 0xFE0F or e == 0x200D or (e >= 0x1F3FB and e <= 0x1F3FF)) break true;
                                        } else false;
                                        if (is_emoji) {
                                            ctx.core.emoji_cluster_buf[0] = cursor_cp;
                                            const elen = @min(extras.len, ctx.core.emoji_cluster_buf.len - 1);
                                            for (0..elen) |ei| {
                                                ctx.core.emoji_cluster_buf[1 + ei] = extras[ei];
                                            }
                                            ctx.core.emoji_cluster_len = @intCast(1 + elen);
                                        }
                                    }
                                    defer ctx.core.emoji_cluster_len = 0;

                                    // Get glyph entry from atlas using actual style
                                    if (ctx.core.isPhase2Atlas()) {
                                        const overflow = ctx.core.grid.getOverflow(cursor_grid_id, grid_cursor_row, grid_cursor_col);
                                        if (try ensureCachedPhase2Glyph(ctx.core, cursor_cp, cursor_c_style, overflow)) |entry| {
                                            ge = entry;
                                            glyph_ok = true;
                                        } else if (ctx.core.flush_aborted) {
                                            return;
                                        } else {
                                            // Do not consume cursor_rev on a transient
                                            // rasterizer miss. The next flush retries the
                                            // same stationary cursor without cancelling
                                            // the current transaction.
                                            cursor_retry_required = true;
                                        }
                                    } else if (cursor_style_mask != 0 and ensure_styled != null) {
                                        if (ensure_styled) |styled_fn| {
                                            glyph_ok = styled_fn(ctx.core.ctx, cursor_cp, cursor_c_style, &ge) != 0;
                                        }
                                    } else if (ensure_base) |base_fn| {
                                        glyph_ok = base_fn(ctx.core.ctx, cursor_cp, &ge) != 0;
                                    }

                                    if (glyph_ok and ge.bbox_size_px[0] > 0 and ge.bbox_size_px[1] > 0) {
                                        // Calculate glyph position (same as global grid rendering)
                                        // Use topPad from outer scope
                                        const cursorBaseY: f32 = y0 + topPad;
                                        const baselineY: f32 = cursorBaseY + ge.ascent_px;

                                        const gx0: f32 = x0 + ge.bbox_origin_px[0];
                                        const gx1: f32 = gx0 + ge.bbox_size_px[0];
                                        const gy0: f32 = baselineY - (ge.bbox_origin_px[1] + ge.bbox_size_px[1]);
                                        const gy1: f32 = gy0 + ge.bbox_size_px[1];

                                        // UV coordinates from atlas
                                        const uv0 = [2]f32{ ge.uv_min[0], ge.uv_min[1] };
                                        const uv1 = [2]f32{ ge.uv_max[0], ge.uv_min[1] };
                                        const uv2 = [2]f32{ ge.uv_min[0], ge.uv_max[1] };
                                        const uv3 = [2]f32{ ge.uv_max[0], ge.uv_max[1] };

                                        // Use cursor foreground color (inverted)
                                        const fg = Helpers.rgb(cursor_out.fgRGB);

                                        try Helpers.pushGlyphQuad(
                                            cursor,
                                            ctx.core.alloc,
                                            gx0,
                                            gy0,
                                            gx1,
                                            gy1,
                                            uv0,
                                            uv1,
                                            uv2,
                                            uv3,
                                            fg,
                                            dw,
                                            dh,
                                            cursor_grid_id, // cursor belongs to its actual grid
                                            c_api.DECO_SCROLLABLE | (if (ge.bytes_per_pixel >= 4) c_api.DECO_COLOR_EMOJI else 0), // cursor is always in content area
                                        );
                                    }
                                }
                            } // end else (non-block-element cursor glyph)
                        }
                    }
                }
            }

            // If atlas was reset during vertex generation, do NOT submit this flush.
            // Vertices emitted before the reset carry stale UVs and would sample
            // unrelated atlas contents for one frame. Preserve dirty state so the
            // next flush regenerates everything against the fresh atlas.
            if (ctx.core.atlas_reset_during_flush) {
                ctx.core.grid.markAllDirty();
                ctx.core.invalidateScrollCache();
                var sg_it = ctx.core.grid.sub_grids.valueIterator();
                while (sg_it.next()) |sg| {
                    sg.markAllDirty();
                }
                ctx.core.atlas_reset_during_flush = false;
                // Row callbacks may already have published vertices whose UVs
                // refer to the atlas generation that the cursor ensure just
                // replaced. Dirtying repairs the next flush only; cancel this
                // transaction so the stale rows are never committed once.
                ctx.core.flush_atlas_corrupted = true;
                return;
            }

            // ----------------------------
            // Send vertices via on_vertices_partial when registered. A
            // row-only consumer receives main content above and the cursor as
            // a dedicated row callback below.
            // ----------------------------
            if (pf_opt) |pf| {
                var flags: u32 = 0;

                // If main was already sent by rows, do NOT send main here.
                const send_main_here = need_main and !sent_main_by_rows;

                if (send_main_here) flags |= 1; // ZONVIE_VERT_UPDATE_MAIN
                if (need_cursor) flags |= 2; // ZONVIE_VERT_UPDATE_CURSOR

                const main_ptr_opt: ?[*]const c_api.Vertex = if (send_main_here) main.items.ptr else null;
                const cur_ptr_opt: ?[*]const c_api.Vertex = if (need_cursor) cursor.items.ptr else null;

                const t_pf: i128 = if (perf_enabled) clock.nowNs() else 0;
                const main_n_for_log: usize = if (send_main_here) main.items.len else 0;
                const cur_n_for_log: usize = if (need_cursor) cursor.items.len else 0;
                pf(
                    ctx.core.ctx,
                    main_ptr_opt,
                    main_n_for_log,
                    cur_ptr_opt,
                    cur_n_for_log,
                    flags,
                );
                if (perf_enabled) {
                    const pf_us: i64 = @intCast(@divTrunc(@max(0, clock.nowNs() - t_pf), 1000));
                    ctx.core.log.write(
                        "[perf] cb_vertices_partial us={d} main_n={d} cursor_n={d} flags=0x{x}\n",
                        .{ pf_us, main_n_for_log, cur_n_for_log, flags },
                    );
                }
                // Only update snapshot when main was rebuilt (subgrid info is current).
                // cursor-only flushes leave cached_subgrids empty.
                if (need_main) saveSubgridSnapshots(ctx.core, cached_subgrids);
                // A vertex callback may have reported failure mid-flush
                // (zonvie_core_abort_flush from a frontend OOM path). Keep
                // dirty and scroll state so the complete cancelled bracket is
                // replayed on retry. last_sent_cursor_rev must also
                // stay unsynced on abort: the frontend cancelled its whole
                // bracket, so the cursor vertices passed to pf() above were
                // never actually committed. Syncing the revision here would
                // make the next flush's need_cursor check see nothing
                // pending and skip resending them.
                if (ctx.core.flush_aborted) {
                    return;
                }
                if (need_cursor and !cursor_retry_required) {
                    ctx.core.last_sent_cursor_rev = ctx.core.grid.cursor_rev;
                }
                if (!main_retry_required) ctx.core.grid.clearDirty();
                return;
            }

            // Row-only ABI consumer. Main rows were sent individually above;
            // use the same callback's CURSOR flag for the separate cursor
            // layer, including an empty slice when the cursor left grid 1.
            const row_cb = ctx.core.cb.on_vertices_row.?;
            if (need_cursor) {
                const cursor_ptr: ?[*]const c_api.Vertex = if (cursor.items.len != 0) cursor.items.ptr else null;
                row_cb(
                    ctx.core.ctx,
                    1,
                    cursor_out.row,
                    1,
                    cursor_ptr,
                    cursor.items.len,
                    c_api.VERT_UPDATE_CURSOR,
                    rows,
                    cols,
                );
                if (ctx.core.flush_aborted) return;
                if (!cursor_retry_required) {
                    ctx.core.last_sent_cursor_rev = ctx.core.grid.cursor_rev;
                }
            }
            if (need_main and !sent_main_by_rows) saveSubgridSnapshots(ctx.core, cached_subgrids);
            if (!main_retry_required) ctx.core.grid.clearDirty();
            return;
        }
    }

    pub fn onGuifont(ctx: *FlushCtx, font: []const u8) !void {
        // "*" is a picker request (`:set guifont=*`), not a real font change.
        // Skip cache/atlas invalidation and dirtying: the frontend only opens
        // a font dialog and later writes back a concrete "Name:hN" via
        // nvim_set_option_value, which arrives as a normal guifont option_set
        // and goes through the full path below. Resetting here would cause a
        // pointless re-render flash just to show the dialog.
        if (std.mem.eql(u8, font, "*")) {
            ctx.core.emitGuiFont(font);
            return;
        }

        // Invalidate caches BEFORE emitting callback: the callback may
        // trigger vertex generation (e.g., Windows' updateLayoutToCore
        // calls sendExternalGridVertices when cell dimensions change).
        // Clearing first ensures those vertices use fresh cache lookups.
        ctx.core.resetAtlasMaintenanceBackoff();
        ctx.core.resetGlyphCacheFlags();
        ctx.core.resetShapeCache();
        if (ctx.core.isPhase2Atlas()) {
            ctx.core.resetCoreAtlas();
        }
        // Scroll cache uses atlas UVs; invalidate on font/atlas change.
        ctx.core.invalidateScrollCache();

        // Mark ALL grids dirty so row-mode vertex generation re-renders
        // every row with the new font/atlas. Without this, the global grid
        // keeps old vertices referencing the now-empty atlas → blank screen
        // until Neovim resends content after nvim_ui_try_resize.
        // sg.dirty alone is not enough for sub_grids: the per-row emit path
        // checks dirty_rows to pick which rows to regenerate, so with no
        // bits set every row is skipped and dirty gets cleared at flush end
        // with nothing ever resent — markAllDirty() sets both. The cursor
        // is a separate vertex consumer gated on cursor_rev alone (main and
        // external both), which this font change also invalidates but
        // neither grid/sub_grid dirtying touches.
        ctx.core.grid.markAllDirty();
        var sg_it = ctx.core.grid.sub_grids.valueIterator();
        while (sg_it.next()) |sg| {
            sg.markAllDirty();
        }
        ctx.core.grid.cursor_rev +%= 1;

        ctx.core.emitGuiFont(font);
    }

    pub fn onLinespace(ctx: *FlushCtx, px: i32) !void {
        // Store in core and notify frontend. Negative values are Neovim's way
        // of tightening rows under a font that reserves too much room between
        // lines; the frontend keeps the resulting row height positive.
        ctx.core.linespace_px = px;
        ctx.core.emitLineSpace(px);
    }

    pub fn onSetTitle(ctx: *FlushCtx, title: []const u8) !void {
        ctx.core.emitSetTitle(title);
    }

    pub fn onDefaultColors(ctx: *FlushCtx, fg: u32, bg: u32) !void {
        // Vertex colors are baked at generation time, including highlight
        // entries whose fg/bg/sp inherit these defaults. Invalidate every
        // resolved-color consumer before the frontend callback can re-enter
        // layout/vertex generation.
        ctx.core.reinitHlCache();
        ctx.core.invalidateScrollCache();
        ctx.core.grid.markAllDirty();
        var sg_it = ctx.core.grid.sub_grids.valueIterator();
        while (sg_it.next()) |sg| sg.markAllDirty();
        ctx.core.grid.cursor_rev +%= 1;
        ctx.core.emitDefaultColors(fg, bg);
    }

    pub fn onRestart(ctx: *FlushCtx, listen_addr: []const u8) !void {
        try ctx.core.handleRestartEvent(listen_addr);
    }

    pub fn onConnect(ctx: *FlushCtx, server_addr: []const u8) !void {
        try ctx.core.handleConnectEvent(server_addr);
    }
};

pub fn notifyExternalWindowChanges(self: *Core) bool {
    var new_grids_added = false;

    // Never emit window lifecycle callbacks for a flush whose frontend
    // transaction was cancelled. The retry flush will regenerate vertices and
    // retry these notifications before its own commit.
    if (self.flush_aborted) return false;

    // Removal marks the current slot as a tombstone without rehashing or
    // relocating entries, so advancing the iterator then removeByPtr is safe
    // and visits every known grid once (O(G), rather than rescanning from the
    // beginning after each close).
    var known_it = self.known_external_grids.iterator();
    while (known_it.next()) |entry| {
        const grid_id = entry.key_ptr.*;
        if (!self.grid.external_grids.contains(grid_id)) {
            if (self.cb.on_external_window_close) |cb| cb(self.ctx, grid_id);
            if (self.flush_aborted) return new_grids_added;
            self.known_external_grids.removeByPtr(entry.key_ptr);
        }
    }

    // Find new or changed external windows
    var ext_it = self.grid.external_grids.iterator();
    while (ext_it.next()) |entry| {
        const grid_id = entry.key_ptr.*;
        const info = entry.value_ptr.*;

        // Get dimensions from sub_grids
        var rows: u32 = 0;
        var cols: u32 = 0;
        if (self.grid.sub_grids.get(grid_id)) |sg| {
            rows = sg.rows;
            cols = sg.cols;
        }

        // Skip 0x0 grids - wait until grid_resize provides valid dimensions
        if (rows == 0 or cols == 0) continue;

        const is_new = !self.known_external_grids.contains(grid_id);

        // Check if position or size changed for existing grids (e.g. popupmenu
        // re-show with different anchor after popupmenu_select).
        var pos_changed = false;
        if (!is_new) {
            if (self.known_external_grids.get(grid_id)) |prev| {
                if (prev.win != info.win or prev.start_row != info.start_row or prev.start_col != info.start_col or
                    prev.rows != rows or prev.cols != cols)
                {
                    pos_changed = true;
                }
            }
        }

        if (!is_new and !pos_changed) continue;

        if (is_new) {
            // For ext_windows grids awaiting initial resize response from Neovim,
            // defer window creation until the grid has a reasonable size.
            if (self.grid.pending_ext_window_grids.contains(grid_id)) {
                if (rows < 2 or cols < 2) continue;
                _ = self.grid.pending_ext_window_grids.remove(grid_id);
            }

            // Reserve the known-map entry before invoking the frontend. This
            // makes OOM a clean pre-callback abort instead of opening a window
            // and then failing to record it, which would otherwise cause
            // duplicate opens and lost closes on later retries.
            self.known_external_grids.ensureUnusedCapacity(self.alloc, 1) catch {
                self.flush_aborted = true;
                return new_grids_added;
            };
        }

        // Notify frontend with position info
        if (self.cb.on_external_window) |cb| {
            cb(self.ctx, grid_id, info.win, rows, cols, info.start_row, info.start_col);
        }
        // A lifecycle callback may abort the enclosing frontend transaction
        // (Windows does this when queueing or PostMessageW fails). Do not leak
        // later window-create side effects from a transaction that every
        // frontend will cancel in on_flush_end; the retry flush will revisit
        // this grid and every undispatched grid.
        if (self.flush_aborted) return new_grids_added;

        // Add/update the known set only after the callback completed without
        // aborting. New entries use the capacity reserved above; changed
        // entries update in place and cannot allocate.
        const known_info: nvim_core.KnownExtGridInfo = .{
            .win = info.win,
            .start_row = info.start_row,
            .start_col = info.start_col,
            .rows = rows,
            .cols = cols,
        };
        if (is_new) {
            self.known_external_grids.putAssumeCapacityNoClobber(grid_id, known_info);
            new_grids_added = true;
        } else if (self.known_external_grids.getPtr(grid_id)) |known| {
            known.* = known_info;
        }
    }

    return new_grids_added;
}

fn externalCursorVisibleOnGrid(grid: *const grid_mod.Grid, grid_id: i64) bool {
    return grid.cursor_grid == grid_id and grid.cursor_valid and grid.cursor_visible;
}

/// Pixels of the row's line spacing that sit above the text, the rest going
/// below. Neovim allows 'linespace' to be negative to pull lines together when
/// a font reserves more room for ascent and descent than the text needs, so
/// this is signed and the row is then shorter than the font's own cell.
fn rowTopPadPx(linespace_px: i32) i32 {
    return @divTrunc(linespace_px, 2);
}

fn externalCursorGlyphDecoFlags(bytes_per_pixel: u32) u32 {
    return c_api.DECO_CURSOR | c_api.DECO_SCROLLABLE |
        (if (bytes_per_pixel == 4) c_api.DECO_COLOR_EMOJI else 0);
}

const ExternalFloatRowRange = struct {
    start: usize,
    end: usize,
};

fn externalFloatVisibleRowRange(
    core: *const Core,
    float_grid_id: i64,
    ext_start_row: i64,
    ext_start_col: i64,
    viewport_rows: u32,
    viewport_cols: u32,
) ?ExternalFloatRowRange {
    const pos = core.grid.win_pos.get(float_grid_id) orelse return null;
    const sg = core.grid.sub_grids.get(float_grid_id) orelse return null;
    if (sg.rows == 0 or sg.cols == 0) return null;

    const row0 = @as(i64, pos.row) - ext_start_row;
    const row1 = row0 + @as(i64, sg.rows);
    const col0 = @as(i64, pos.col) - ext_start_col;
    const col1 = col0 + @as(i64, sg.cols);
    if (row1 <= 0 or row0 >= @as(i64, viewport_rows) or
        col1 <= 0 or col0 >= @as(i64, viewport_cols)) return null;

    return .{
        .start = @intCast(@max(@as(i64, 0), row0)),
        .end = @intCast(@min(@as(i64, viewport_rows), row1)),
    };
}

/// Build one flush-local index of every float anchored to an external grid.
/// The win_pos map is scanned once; per-anchor users then binary-search a
/// contiguous, already layer-sorted slice instead of rescanning the map.
fn releaseOversizedExternalFloatScratch(
    comptime T: type,
    list: *std.ArrayListUnmanaged(T),
    alloc: std.mem.Allocator,
    max_bytes: usize,
) void {
    const max_entries = max_bytes / @sizeOf(T);
    if (list.capacity <= max_entries) return;
    list.deinit(alloc);
    list.* = .empty;
}

fn buildExternalFloatAnchorIndexWithLimit(core: *Core, max_bytes: usize) !void {
    core.ext_float_anchor_entries.clearRetainingCapacity();
    releaseOversizedExternalFloatScratch(
        ExternalFloatAnchorEntry,
        &core.ext_float_anchor_entries,
        core.alloc,
        max_bytes,
    );
    core.ext_float_anchor_index_valid = false;

    const max_entries = max_bytes / @sizeOf(ExternalFloatAnchorEntry);
    var anchor_entry_count: usize = 0;
    var count_it = core.grid.win_pos.iterator();
    while (count_it.next()) |entry| {
        if (!core.grid.external_grids.contains(entry.value_ptr.anchor_grid)) continue;
        if (anchor_entry_count >= max_entries) return error.TooManyWindowPlacements;
        anchor_entry_count += 1;
    }
    try core.ext_float_anchor_entries.ensureTotalCapacityPrecise(core.alloc, anchor_entry_count);

    var win_it = core.grid.win_pos.iterator();
    while (win_it.next()) |entry| {
        const anchor_grid_id = entry.value_ptr.anchor_grid;
        if (!core.grid.external_grids.contains(anchor_grid_id)) continue;
        const layer = core.grid.win_layer.get(entry.key_ptr.*) orelse grid_mod.WinLayer{};
        core.ext_float_anchor_entries.appendAssumeCapacity(.{
            .anchor_grid_id = anchor_grid_id,
            .entry = .{
                .grid_id = entry.key_ptr.*,
                .zindex = layer.zindex,
                .compindex = layer.compindex,
                .order = layer.order,
            },
        });
    }
    std.sort.block(
        ExternalFloatAnchorEntry,
        core.ext_float_anchor_entries.items,
        {},
        ExternalFloatAnchorEntry.lessThan,
    );
    core.ext_float_anchor_index_valid = true;
}

fn buildExternalFloatAnchorIndex(core: *Core) !void {
    return buildExternalFloatAnchorIndexWithLimit(
        core,
        MAX_EXTERNAL_FLOAT_ANCHOR_SCRATCH_BYTES,
    );
}

/// Build a sorted, per-row index for floats visible in one external grid.
/// The flattened row buckets preserve the global layer order because entries
/// are inserted into every covered row in sorted order.
fn externalFloatRowIndexStorageByteSize(offsets: usize, write_offsets: usize, refs: usize) ?usize {
    const row_usizes = std.math.add(usize, offsets, write_offsets) catch return null;
    const total_usizes = std.math.add(usize, row_usizes, refs) catch return null;
    return std.math.mul(usize, total_usizes, @sizeOf(usize)) catch null;
}

fn externalFloatPersistentScratchCapacityByteSize(core: *const Core) ?usize {
    const anchor_bytes = std.math.mul(
        usize,
        core.ext_float_anchor_entries.capacity,
        @sizeOf(ExternalFloatAnchorEntry),
    ) catch return null;
    const entry_bytes = std.math.mul(
        usize,
        core.ext_float_entries.capacity,
        @sizeOf(GridEntry),
    ) catch return null;
    const row_index_bytes = externalFloatRowIndexStorageByteSize(
        core.ext_float_row_offsets.capacity,
        core.ext_float_row_write_offsets.capacity,
        core.ext_float_row_entry_indices.capacity,
    ) orelse return null;
    const entry_and_anchor = std.math.add(usize, anchor_bytes, entry_bytes) catch return null;
    return std.math.add(usize, entry_and_anchor, row_index_bytes) catch null;
}

fn externalFloatRowIndexByteSize(rows: usize, refs: usize) ?usize {
    const offset_count = std.math.add(usize, rows, 1) catch return null;
    return externalFloatRowIndexStorageByteSize(offset_count, rows, refs);
}

fn clearExternalFloatRowIndexStorage(core: *Core) void {
    core.ext_float_row_offsets.deinit(core.alloc);
    core.ext_float_row_offsets = .empty;
    core.ext_float_row_write_offsets.deinit(core.alloc);
    core.ext_float_row_write_offsets = .empty;
    core.ext_float_row_entry_indices.deinit(core.alloc);
    core.ext_float_row_entry_indices = .empty;
}

fn releaseOversizedExternalFloatRowIndex(core: *Core, max_bytes: usize) void {
    const retained_bytes = externalFloatRowIndexStorageByteSize(
        core.ext_float_row_offsets.capacity,
        core.ext_float_row_write_offsets.capacity,
        core.ext_float_row_entry_indices.capacity,
    ) orelse max_bytes +| 1;
    if (retained_bytes <= max_bytes) return;
    clearExternalFloatRowIndexStorage(core);
}

fn buildExternalFloatRowIndexWithLimits(
    core: *Core,
    anchor_entries: []const ExternalFloatAnchorEntry,
    ext_info: ?grid_mod.ExternalGridInfo,
    viewport_rows: u32,
    viewport_cols: u32,
    max_index_bytes: usize,
    max_entry_bytes: usize,
) !u64 {
    core.ext_float_index_generation +%= 1;
    const generation = core.ext_float_index_generation;

    core.ext_float_entries.clearRetainingCapacity();
    releaseOversizedExternalFloatScratch(
        GridEntry,
        &core.ext_float_entries,
        core.alloc,
        max_entry_bytes,
    );
    core.ext_float_row_offsets.clearRetainingCapacity();
    core.ext_float_row_write_offsets.clearRetainingCapacity();
    core.ext_float_row_entry_indices.clearRetainingCapacity();
    core.ext_float_row_index_valid = false;
    releaseOversizedExternalFloatRowIndex(core, max_index_bytes);

    const row_count: usize = viewport_rows;

    const info = ext_info orelse return generation;
    if (info.start_row < 0 or info.start_col < 0) return generation;
    const ext_start_row: i64 = info.start_row;
    const ext_start_col: i64 = info.start_col;

    // anchor_entries is already in global layer order for this anchor. Count
    // visible entries before allocating so invisible/missing/zero-cell floats
    // do not contribute to the persistent high-water capacity.
    const max_visible_entries = max_entry_bytes / @sizeOf(GridEntry);
    var visible_entry_count: usize = 0;
    for (anchor_entries) |anchor_entry| {
        if (externalFloatVisibleRowRange(
            core,
            anchor_entry.entry.grid_id,
            ext_start_row,
            ext_start_col,
            viewport_rows,
            viewport_cols,
        ) == null) continue;
        if (visible_entry_count >= max_visible_entries) return error.TooManyWindowPlacements;
        visible_entry_count += 1;
    }
    try core.ext_float_entries.ensureTotalCapacityPrecise(core.alloc, visible_entry_count);
    for (anchor_entries) |anchor_entry| {
        if (externalFloatVisibleRowRange(
            core,
            anchor_entry.entry.grid_id,
            ext_start_row,
            ext_start_col,
            viewport_rows,
            viewport_cols,
        ) == null) continue;
        core.ext_float_entries.appendAssumeCapacity(anchor_entry.entry);
    }

    var ref_count: usize = 0;
    for (core.ext_float_entries.items) |entry| {
        const range = externalFloatVisibleRowRange(
            core,
            entry.grid_id,
            ext_start_row,
            ext_start_col,
            viewport_rows,
            viewport_cols,
        ) orelse continue;
        ref_count = std.math.add(usize, ref_count, range.end - range.start) catch {
            releaseOversizedExternalFloatRowIndex(core, max_index_bytes);
            return error.LayoutTooComplex;
        };
    }

    const required_bytes = externalFloatRowIndexByteSize(row_count, ref_count) orelse {
        releaseOversizedExternalFloatRowIndex(core, max_index_bytes);
        return error.LayoutTooComplex;
    };
    if (required_bytes > max_index_bytes) {
        releaseOversizedExternalFloatRowIndex(core, max_index_bytes);
        return error.LayoutTooComplex;
    }
    releaseOversizedExternalFloatRowIndex(core, max_index_bytes);

    const offset_count = row_count + 1;
    const projected_retained_bytes = externalFloatRowIndexStorageByteSize(
        @max(core.ext_float_row_offsets.capacity, offset_count),
        @max(core.ext_float_row_write_offsets.capacity, row_count),
        @max(core.ext_float_row_entry_indices.capacity, ref_count),
    ) orelse max_index_bytes +| 1;
    if (projected_retained_bytes > max_index_bytes) {
        clearExternalFloatRowIndexStorage(core);
    }
    try core.ext_float_row_offsets.ensureTotalCapacityPrecise(core.alloc, offset_count);
    core.ext_float_row_offsets.items.len = offset_count;
    @memset(core.ext_float_row_offsets.items, 0);

    // Count references per visible row, then convert counts to offsets.
    for (core.ext_float_entries.items) |entry| {
        const range = externalFloatVisibleRowRange(
            core,
            entry.grid_id,
            ext_start_row,
            ext_start_col,
            viewport_rows,
            viewport_cols,
        ) orelse continue;
        for (range.start..range.end) |row| {
            core.ext_float_row_offsets.items[row + 1] += 1;
        }
    }
    for (1..core.ext_float_row_offsets.items.len) |i| {
        core.ext_float_row_offsets.items[i] += core.ext_float_row_offsets.items[i - 1];
    }

    std.debug.assert(ref_count == core.ext_float_row_offsets.items[row_count]);
    try core.ext_float_row_entry_indices.ensureTotalCapacityPrecise(core.alloc, ref_count);
    core.ext_float_row_entry_indices.items.len = ref_count;
    try core.ext_float_row_write_offsets.ensureTotalCapacityPrecise(core.alloc, row_count);
    core.ext_float_row_write_offsets.items.len = row_count;
    @memcpy(
        core.ext_float_row_write_offsets.items,
        core.ext_float_row_offsets.items[0..row_count],
    );

    // Filling in global sorted order keeps every row bucket sorted without a
    // second per-row sort.
    for (core.ext_float_entries.items, 0..) |entry, entry_index| {
        const range = externalFloatVisibleRowRange(
            core,
            entry.grid_id,
            ext_start_row,
            ext_start_col,
            viewport_rows,
            viewport_cols,
        ) orelse continue;
        for (range.start..range.end) |row| {
            const dst = core.ext_float_row_write_offsets.items[row];
            core.ext_float_row_entry_indices.items[dst] = entry_index;
            core.ext_float_row_write_offsets.items[row] = dst + 1;
        }
    }

    core.ext_float_row_index_valid = true;
    return generation;
}

fn buildExternalFloatRowIndexWithLimit(
    core: *Core,
    anchor_entries: []const ExternalFloatAnchorEntry,
    ext_info: ?grid_mod.ExternalGridInfo,
    viewport_rows: u32,
    viewport_cols: u32,
    max_index_bytes: usize,
) !u64 {
    return buildExternalFloatRowIndexWithLimits(
        core,
        anchor_entries,
        ext_info,
        viewport_rows,
        viewport_cols,
        max_index_bytes,
        MAX_EXTERNAL_FLOAT_ENTRY_SCRATCH_BYTES,
    );
}

fn buildExternalFloatRowIndex(
    core: *Core,
    anchor_entries: []const ExternalFloatAnchorEntry,
    ext_info: ?grid_mod.ExternalGridInfo,
    viewport_rows: u32,
    viewport_cols: u32,
) !u64 {
    return buildExternalFloatRowIndexWithLimits(
        core,
        anchor_entries,
        ext_info,
        viewport_rows,
        viewport_cols,
        MAX_EXTERNAL_FLOAT_ROW_INDEX_BYTES,
        MAX_EXTERNAL_FLOAT_ENTRY_SCRATCH_BYTES,
    );
}

/// Generate and send vertices for all external grids.
/// force_render: if true, render all grids regardless of dirty/cursor flags (used when new grids added)
/// Generate and send vertices for external grids.
/// force_render: if true, render regardless of dirty flags
/// only_grid_id: if non-null, only update this specific grid (for scroll optimization)
///
/// WARNING: This function invokes frontend callbacks (on_vertices_row,
/// on_cursor_grid_changed) while grid_mu is held. Frontend callbacks
/// MUST NOT call zonvie_core_get_* APIs (which acquire grid_mu), as
/// this would cause deadlock. Use PostMessage (Windows) or
/// DispatchQueue.main.async (macOS) to defer any work that requires
/// grid state access.
pub fn sendExternalGridVerticesFiltered(self: *Core, force_render: bool, only_grid_id: ?i64) void {
    self.log.write("[sendExternalGridVertices] called, known_external_grids.count={d} force={} only_grid={?d}\n", .{ self.known_external_grids.count(), force_render, only_grid_id });

    // Standalone callers own the flush-local anchor index they build. onFlush
    // may have built it earlier for row-scroll dispatch; in that case its
    // transaction-final defer invalidates it after this function returns.
    var owns_anchor_index = false;
    defer {
        if (owns_anchor_index) self.ext_float_anchor_index_valid = false;
    }

    // The overlay map is visible only while generateRowVertices consumes one
    // fully-composed row. In particular, frontend row callbacks run with this
    // cleared so a re-entrant external-grid flush cannot observe stale row
    // state from the outer invocation.
    self.flush_float_overlay = null;
    defer self.flush_float_overlay = null;

    // Cache glow state once — doesn't change while grid_mu is held.
    const ext_glow_enabled = self.glow_enabled.load(.acquire);
    const ext_glow_all = self.glow_all;
    const ext_glow_hl_ids = if (self.glow_hl_ids) |*m| m else null;

    // Check if cursor changed (position or grid) - do this first, before early returns
    const cursor_grid = self.grid.cursor_grid;
    const cursor_rev = self.grid.cursor_rev;
    const cursor_changed = (cursor_rev != self.last_ext_cursor_rev);
    const cursor_grid_changed = (cursor_grid != self.last_ext_cursor_grid);
    var ext_cursor_retry_required = false;

    self.log.write("[sendExternalGridVertices] cursor_grid={d} cursor_rev={d} last_grid={d} last_rev={d} changed={} grid_changed={}\n", .{
        cursor_grid, cursor_rev, self.last_ext_cursor_grid, self.last_ext_cursor_rev, cursor_changed, cursor_grid_changed,
    });

    // Only update last cursor grid if we have external grids to process.
    // Otherwise we consume the cursor state before the grid window is created.
    // Always update cursor rev to prevent stale changed=true accumulation.
    const has_external_grids = self.known_external_grids.count() > 0;
    // Hold off consuming the cursor grid while the cursor sits on an external
    // grid whose host window has not been created yet (in external_grids but
    // not yet known_external_grids). Consuming it here lets grid_changed go
    // false on the next flush, so the cursor layer is never re-emitted into
    // the freshly created grid view and the cursor stays invisible until the
    // next keystroke. This happens when another external window is already
    // open (e.g. opening ext_cmdline from a focused float): has_external_grids
    // is already true, so the old broad gate did not protect this case.
    const cursor_grid_pending = self.grid.external_grids.contains(cursor_grid) and
        !self.known_external_grids.contains(cursor_grid);
    defer {
        // A per-grid callback below (e.g. Windows external row-buffer OOM)
        // may call zonvie_core_abort_flush mid-loop. The frontend cancels
        // this whole bracket on abort, so the external cursor update just
        // computed above was never actually committed — skip syncing these
        // so cursor_changed/cursor_grid_changed still read true on the next
        // call and the cancelled update gets resent instead of silently
        // dropped.
        if (!self.flush_aborted and !ext_cursor_retry_required) {
            if (has_external_grids and !cursor_grid_pending) {
                self.last_ext_cursor_grid = cursor_grid;
            }
            self.last_ext_cursor_rev = cursor_rev;
            // Only a full scan (only_grid_id == null, i.e. every external
            // grid was actually re-checked) may consume this. A filtered,
            // single-grid call (e.g. scroll-optimization's only_grid_id)
            // can run before the real retry and would otherwise clear the
            // flag having re-checked only ONE grid, silently skipping the
            // rest — the exact case this flag exists to cover.
            if (only_grid_id == null) {
                self.force_ext_cursor_recheck = false;
            }
        }
    }

    // Check if cursor is on a non-existent external grid (e.g., closed cmdline)
    // In this case, we need to force redraw the grid that previously had cursor
    const cursor_on_closed_grid = !self.known_external_grids.contains(cursor_grid) and
        cursor_grid != 1; // cursor_grid != global grid
    const need_force_redraw_last = cursor_on_closed_grid and
        self.known_external_grids.contains(self.last_ext_cursor_grid);

    if (need_force_redraw_last) {
        self.log.write("[sendExternalGridVertices] cursor on closed grid, forcing redraw of last_grid={d}\n", .{self.last_ext_cursor_grid});
    }

    // Notify frontend when cursor grid changes (for window activation).
    // Only fire when external grids exist — window activation is only relevant
    // for external grid windows. Without external grids, cursor_grid_changed
    // comparison against stale last_ext_cursor_grid produces false positives.
    if (cursor_grid_changed and has_external_grids) {
        if (self.cb.on_cursor_grid_changed) |cursor_cb| {
            cursor_cb(self.ctx, cursor_grid);
        }
    }

    // Early return if no row-based vertices callback
    const row_cb = self.cb.on_vertices_row orelse return;
    const owns_vertex_budget_transaction = !self.vertex_budget_transaction_active;
    if (owns_vertex_budget_transaction) {
        beginVertexBudgetTransaction(self) catch |err| {
            self.flush_aborted = true;
            self.failHardRender(err);
            return;
        };
    }
    defer if (owns_vertex_budget_transaction) {
        var commit = !self.flush_aborted and !self.flush_atlas_corrupted;
        if (commit) {
            validateCompletedVertexBudget(self) catch |err| {
                self.flush_aborted = true;
                self.failHardRender(err);
                commit = false;
            };
        }
        finishVertexBudgetTransaction(self, commit);
    };

    // Reuse row_verts buffer for external grid vertices (per-row)
    var ext_verts = &self.row_verts;

    const cellW: f32 = @floatFromInt(self.cell_w_px);
    const cellH: f32 = @floatFromInt(self.cell_h_px);

    const topPad: f32 = @floatFromInt(rowTopPadPx(self.linespace_px));

    const Helpers = struct {
        fn ndc(x: f32, y: f32, vw: f32, vh: f32) [2]f32 {
            const nx = (x / vw) * 2.0 - 1.0;
            const ny = 1.0 - (y / vh) * 2.0;
            return .{ nx, ny };
        }

        /// Batch NDC transform for 4 quad corners (TL, TR, BL, BR).
        inline fn ndc4(x0: f32, y0: f32, x1: f32, y1: f32, vw: f32, vh: f32) [4][2]f32 {
            const V4 = @Vector(4, f32);
            const xs = V4{ x0, x1, x0, x1 };
            const ys = V4{ y0, y0, y1, y1 };
            const nxs = xs / @as(V4, @splat(vw)) * @as(V4, @splat(2.0)) - @as(V4, @splat(1.0));
            const nys = @as(V4, @splat(1.0)) - ys / @as(V4, @splat(vh)) * @as(V4, @splat(2.0));
            return .{
                .{ nxs[0], nys[0] },
                .{ nxs[1], nys[1] },
                .{ nxs[2], nys[2] },
                .{ nxs[3], nys[3] },
            };
        }

        inline fn rgb(v: u32) [4]f32 {
            return rgba(v, 1.0);
        }

        inline fn rgba(v: u32, alpha: f32) [4]f32 {
            const V4u32 = @Vector(4, u32);
            const V4f32 = @Vector(4, f32);
            const vv: V4u32 = @splat(v);
            const channels = (vv >> V4u32{ 16, 8, 0, 0 }) & @as(V4u32, @splat(0xFF));
            const floats = @as(V4f32, @floatFromInt(channels)) * @as(V4f32, @splat(1.0 / 255.0));
            var arr: [4]f32 = floats;
            arr[3] = alpha;
            return arr;
        }

        const solid_uv: [2]f32 = .{ -1.0, -1.0 };

        /// Emit a solid-color quad (caller guarantees 6 vertices of capacity).
        fn pushSolidQuadAssumeCapacity(
            out: *std.ArrayListUnmanaged(c_api.Vertex),
            x0: f32,
            y0: f32,
            x1: f32,
            y1: f32,
            col: [4]f32,
            vw: f32,
            vh: f32,
            grid_id: i64,
            base_deco_flags: u32,
        ) void {
            const pts = ndc4(x0, y0, x1, y1, vw, vh);
            const p0 = pts[0];
            const p1 = pts[1];
            const p2 = pts[2];
            const p3 = pts[3];

            const v = out.addManyAsSliceAssumeCapacity(6);

            v[0] = .{ .position = p0, .texCoord = solid_uv, .color = col, .grid_id = grid_id, .deco_flags = base_deco_flags, .deco_phase = 0 };
            v[1] = .{ .position = p2, .texCoord = solid_uv, .color = col, .grid_id = grid_id, .deco_flags = base_deco_flags, .deco_phase = 0 };
            v[2] = .{ .position = p1, .texCoord = solid_uv, .color = col, .grid_id = grid_id, .deco_flags = base_deco_flags, .deco_phase = 0 };

            v[3] = .{ .position = p1, .texCoord = solid_uv, .color = col, .grid_id = grid_id, .deco_flags = base_deco_flags, .deco_phase = 0 };
            v[4] = .{ .position = p2, .texCoord = solid_uv, .color = col, .grid_id = grid_id, .deco_flags = base_deco_flags, .deco_phase = 0 };
            v[5] = .{ .position = p3, .texCoord = solid_uv, .color = col, .grid_id = grid_id, .deco_flags = base_deco_flags, .deco_phase = 0 };
        }
    };

    // Default background for blur transparency
    const default_bg = self.hl.default_bg;

    // Initialize dynamic caches (same as row_mode)
    self.initHlCache() catch {
        self.log.write("[ext_grid] Failed to initialize hl cache\n", .{});
    };
    self.initGlyphCache() catch {
        self.log.write("[ext_grid] Failed to initialize glyph cache\n", .{});
    };

    // Initialize FlushCache for hl_cache optimization (uses heap buffers from NvimCore)
    var cache = FlushCache{
        .hl_cache_buf = self.hl_cache_buf orelse &.{},
        .hl_valid_buf = self.hl_valid_buf orelse &.{},
    };
    // Glyph cache is persistent across flushes (same as row_mode path).

    // Track atlas reset across all external grids.
    // If any grid triggers a reset, already-sent grids also have stale UVs.
    var ext_saw_atlas_reset_any: bool = false;

    // Iterate over all external grids (not just known_external_grids).
    // This ensures newly added grids (e.g., popupmenu from sendPopupmenuShow)
    // get vertices generated inside the flush bracket, even before
    // notifyExternalWindowChanges adds them to known_external_grids.
    var ext_it = self.grid.external_grids.keyIterator();
    while (ext_it.next()) |grid_id_ptr| {
        // A prior grid this loop may have aborted the flush (allocation
        // failure). The frontend cancels its whole bracket on abort, so
        // composing further grids would be discarded work — matches the
        // equivalent check in the main row-mode loop.
        if (self.flush_aborted) break;

        const grid_id = grid_id_ptr.*;

        // Filter by specific grid if requested (for scroll optimization)
        if (only_grid_id) |target_id| {
            if (grid_id != target_id) continue;
        }

        const sg = self.grid.sub_grids.getPtr(grid_id) orelse continue;

        // Need update if:
        // 1. Grid content is dirty, OR
        // 2. Cursor moved to/from this grid (grid changed), OR
        // 3. Cursor moved within this grid (cursor changed while on this grid)
        const cursor_on_this_grid = externalCursorVisibleOnGrid(&self.grid, grid_id);
        const cursor_was_on_this_grid = (self.last_ext_cursor_grid == grid_id);
        // force_ext_cursor_recheck (force resend): re-check EVERY external
        // grid's cursor state once, since a prior failed flush may have
        // left last_ext_cursor_grid naming the wrong (or right, but
        // unconfirmed) grid — see its doc comment.
        const cursor_affected = (cursor_changed and (cursor_on_this_grid or cursor_was_on_this_grid)) or
            self.force_ext_cursor_recheck;
        const cursor_moved_within = cursor_changed and cursor_on_this_grid and !cursor_grid_changed;

        // Check if this grid needs forced redraw because cursor left closed cmdline
        const force_redraw_this = need_force_redraw_last and (grid_id == self.last_ext_cursor_grid);

        self.log.write("[ext_cursor_check] grid_id={d} dirty={} cursor_on={} cursor_was={} affected={} moved_within={} force={} force_closed={} cursor_grid={d} last_grid={d} rev={d} last_rev={d}\n", .{
            grid_id,     sg.dirty,                  cursor_on_this_grid, cursor_was_on_this_grid,  cursor_affected, cursor_moved_within, force_render, force_redraw_this,
            cursor_grid, self.last_ext_cursor_grid, cursor_rev,          self.last_ext_cursor_rev,
        });

        // Skip if no update needed (unless force_render is set or forced due to closed grid)
        if (!force_render and !force_redraw_this and !sg.dirty and !cursor_affected and !cursor_moved_within) continue;

        // Reset hl_cache for this grid
        cache.reset();

        // Full redraw only for forced operations, not cursor-only changes.
        // Cursor rows are handled via regen_rows (fast path) or dirty_rows marking below.
        const need_full_redraw = force_render or force_redraw_this;

        // NDC viewport: use target dimensions which are kept in sync with grid_resize.
        // This ensures NDC always matches the actual grid data dimensions.
        const target = self.grid.external_grid_target_sizes.get(grid_id);
        const viewport_cols = if (target) |t| t.cols else sg.cols;
        const viewport_rows = if (target) |t| t.rows else sg.rows;
        const grid_w: f32 = @as(f32, @floatFromInt(viewport_cols)) * cellW;
        const grid_h: f32 = @as(f32, @floatFromInt(viewport_rows)) * cellH;
        const cursor_row: ?u32 = if (externalCursorVisibleOnGrid(&self.grid, grid_id))
            self.grid.cursor_row
        else
            null;
        const cursor_col = self.grid.cursor_col;
        var ext_saw_atlas_reset: bool = false;
        var ext_had_row_error: bool = false;
        var ext_had_glyph_miss: bool = false;
        var regen_count: u32 = 0;
        var use_ext_scroll_fast_path = false;

        // Debug: count non-space cells
        // (glyph statistics now tracked inside generateRowVertices; retained
        //  as zero stubs for debug logging compatibility)

        ext_verts.clearRetainingCapacity();

        // Debug: log grid cell array info
        self.log.write("[ext_grid_debug] grid_id={d} sg.rows={d} sg.cols={d} sg.cells.len={d}\n", .{
            grid_id, sg.rows, sg.cols, sg.cells.len,
        });

        // Two-pass vertex generation (same as main window):
        // Pass 1: All backgrounds first
        // Pass 2: All glyphs on top
        // This prevents glyphs that extend beyond cell bounds from being clipped by adjacent backgrounds.

        // Cursor-only changes must not allocate/scan an entire external grid.
        // The row pipeline below is needed only when content itself is dirty.
        if (sg.dirty or need_full_redraw) {
            const ext_info = self.grid.external_grids.get(grid_id);

            if (!self.ext_float_anchor_index_valid) {
                buildExternalFloatAnchorIndex(self) catch |err| {
                    ext_had_row_error = true;
                    self.flush_aborted = true;
                    if (Core.isHardRenderFailure(err)) {
                        self.flush_retryable = false;
                        self.failHardRender(err);
                    }
                    continue;
                };
                owns_anchor_index = true;
            }
            const anchor_entries = externalFloatAnchorEntries(
                self.ext_float_anchor_entries.items,
                grid_id,
            );

            // Build float layer order and visible-row buckets once for this
            // anchor grid. A callback can re-enter external flushing and reuse
            // the scratch; the row loop below detects that by generation and
            // rebuilds only on the rare re-entrant path.
            var ext_float_index_generation = buildExternalFloatRowIndex(
                self,
                anchor_entries,
                ext_info,
                viewport_rows,
                sg.cols,
            ) catch |err| {
                ext_had_row_error = true;
                self.flush_aborted = true;
                if (Core.isHardRenderFailure(err)) {
                    self.flush_retryable = false;
                    self.failHardRender(err);
                }
                continue;
            };

            // Row-based vertex generation: process each row independently
            // This matches the main window's row-based approach for better partial updates
            const ext_margins = self.grid.getViewportMargins(grid_id);

            const is_cmdline = grid_id == grid_mod.CMDLINE_GRID_ID;

            var ext_retried: bool = false;

            // Float windows anchored to this grid suppress on_grid_row_scroll in
            // onFlush (GPU-blitting old pixels would shift stale overlay content),
            // so the frontend performs no blit or row slot remap. The fast path
            // must be ineligible and all shifted rows fully regenerated.
            const ext_has_float_overlay = anchor_entries.len != 0;

            // Determine external grid scroll fast path eligibility (before retry loop).
            // When eligible, we skip non-dirty rows even when sg.dirty is set,
            // because scroll() now only marks vacated rows dirty.
            const ext_scroll_fast_path: bool = blk: {
                if (force_render or need_full_redraw) break :blk false;
                // Without this callback the consumer has no way to shift its
                // retained row slots. Regenerate the whole viewport instead
                // of sending only the vacated band.
                if (self.cb.on_grid_row_scroll == null) break :blk false;
                // A newly/re-opened external grid has no frontend seed until
                // its lifecycle callback is committed. Regenerate all rows
                // instead of asking a not-yet-existing surface to shift them.
                if (!self.known_external_grids.contains(grid_id)) break :blk false;
                const op = sg.last_scroll_op orelse break :blk false;
                if (sg.scroll_fast_path_blocked) break :blk false;
                if (ext_has_float_overlay) break :blk false;
                _ = externalScrollFastPathRegion(
                    op,
                    sg.rows,
                    sg.cols,
                    viewport_rows,
                    viewport_cols,
                ) orelse break :blk false;
                break :blk true;
            };

            // When a scroll happened but the fast path is not usable (multiple
            // scrolls in one batch, scroll delta > 1, partial-width region,
            // or float overlay suppressed the row scroll callback), the
            // frontend won't receive on_grid_row_scroll (no row slot remap) and
            // GPU scroll copy is disabled for external grids. All shifted rows
            // need full vertex regeneration — dirty_rows only covers vacated
            // rows. Any last_scroll_op the fast path rejected (not just the
            // multi-scroll/float/abs(rows)>1 cases previously enumerated here)
            // falls into this same "frontend can't shift it visually" bucket —
            // e.g. a partial-width, abs(rows)==1 scroll, which ext_scroll_fast_path
            // rejects (left/right != full width) but this condition used to miss,
            // leaving the moved region's stale pre-scroll content on the GPU
            // forever (only the vacated band was ever marked dirty).
            const ext_scroll_needs_full_regen: bool =
                !ext_scroll_fast_path and sg.last_scroll_op != null;

            // Cursor is rendered as a separate layer (after row loop), NOT inline
            // in row vertices. This eliminates cursor ghost artifacts during GPU
            // scroll copy. No prev_cursor_row tracking needed for row regeneration.

            // Build regen_rows set for scroll fast path (mirrors global grid approach).
            // Pre-compute which rows need regeneration: dirty_rows only (no cursor rows).
            var regen_rows: [12]u32 = undefined;
            use_ext_scroll_fast_path = ext_scroll_fast_path;

            if (ext_scroll_fast_path) {
                // Add all dirty rows within viewport bounds.
                // Rows beyond viewport_rows are invisible (outside NDC viewport)
                // and should not be included in the regen set.
                for (0..viewport_rows) |ri| {
                    const r: u32 = @intCast(ri);
                    if (sg.dirty_rows.bit_length > r and sg.dirty_rows.isSet(ri)) {
                        if (regen_count < regen_rows.len) {
                            regen_rows[regen_count] = r;
                            regen_count += 1;
                        } else {
                            // Too many dirty rows for fast path — fall back
                            use_ext_scroll_fast_path = false;
                            break;
                        }
                    }
                }
                // When viewport_rows < sg.rows (margin rows present), the Neovim
                // dirty bitmap marks the out-of-bounds vacated row (e.g. row 44
                // for sg.rows=45, viewport_rows=44). The frontend scroll callback
                // receives the clamped region, so its vacated row is within the
                // viewport. Add the clamped vacated row to regen if not already
                // present. Without this, the vacated row gets no vertex data and
                // renders blank after the GPU scroll blit.
                if (use_ext_scroll_fast_path and viewport_rows < sg.rows) {
                    const op = sg.last_scroll_op.?;
                    const clamped_bot = @min(op.bot, viewport_rows);
                    const vacated: u32 = if (op.rows > 0) clamped_bot -| 1 else op.top;
                    var found = false;
                    for (regen_rows[0..regen_count]) |rr| {
                        if (rr == vacated) {
                            found = true;
                            break;
                        }
                    }
                    if (!found) {
                        if (regen_count < regen_rows.len) {
                            regen_rows[regen_count] = vacated;
                            regen_count += 1;
                        } else {
                            use_ext_scroll_fast_path = false;
                        }
                    }
                }
            }

            ext_retry: while (true) {
                if (ext_retried) {
                    // Reset per-pass state for clean retry
                    cache.reset(); // Resets perf counters + hl_valid (hl_valid reset is harmless)
                    ext_had_row_error = false;
                    ext_had_glyph_miss = false;
                }
                const ext_effective_rebuild = ext_retried;

                // Iterate only up to viewport_rows (not sg.rows).
                // Rows beyond viewport_rows are outside the NDC viewport and
                // produce clipped vertices. Matching the vertex loop to the
                // viewport ensures the frontend receives data only for drawable
                // rows — the same invariant the main window always satisfies.
                for (0..viewport_rows) |row_idx| {
                    // A prior row_cb call this loop may have called
                    // zonvie_core_abort_flush (e.g. Windows external row-buffer
                    // OOM). Stop composing further rows in this grid — the
                    // frontend cancels its whole bracket on abort, so continuing
                    // would be discarded work — mirrors the identical check in the
                    // main grid's row-mode loop.
                    if (self.flush_aborted) break;

                    const row: u32 = @intCast(row_idx);

                    if (self.ext_float_index_generation != ext_float_index_generation) {
                        const current_anchor_entries = externalFloatAnchorEntries(
                            self.ext_float_anchor_entries.items,
                            grid_id,
                        );
                        ext_float_index_generation = buildExternalFloatRowIndex(
                            self,
                            current_anchor_entries,
                            ext_info,
                            viewport_rows,
                            sg.cols,
                        ) catch |err| {
                            ext_had_row_error = true;
                            self.flush_aborted = true;
                            if (Core.isHardRenderFailure(err)) {
                                self.flush_retryable = false;
                                self.failHardRender(err);
                            }
                            break :ext_retry;
                        };
                    }

                    // Row skip logic — mirrors global grid approach:
                    // Fast path: only compose rows in regen set (dirty + cursor rows).
                    // Fallback: check dirty_rows bitmap.
                    // When scroll happened but fast path is ineligible, regenerate all
                    // rows because the frontend has no GPU blit or row slot remap to
                    // shift the non-vacated rows visually.
                    if (use_ext_scroll_fast_path and !ext_retried) {
                        var in_regen = false;
                        for (regen_rows[0..regen_count]) |rr| {
                            if (rr == row) {
                                in_regen = true;
                                break;
                            }
                        }
                        if (!in_regen) continue;
                    } else if (!need_full_redraw and !ext_effective_rebuild and !ext_scroll_needs_full_regen) {
                        if (sg.dirty_rows.bit_length > row and !sg.dirty_rows.isSet(@as(usize, row))) {
                            continue;
                        }
                    }

                    // Clear buffer for this row
                    ext_verts.clearRetainingCapacity();

                    // Estimate capacity for this row: 6 bg + 6 glyph + 6 deco + 6 overline + 6 glow per cell + 12 cursor
                    const row_est = @as(usize, sg.cols) * 24 + 12;
                    ext_verts.ensureTotalCapacity(self.alloc, row_est) catch {
                        ext_had_row_error = true;
                        // Whole-flush abort (see the ensureTotalCapacity/alloc
                        // catches earlier in this function) — the frontend must
                        // cancel this bracket rather than commit it with this row
                        // silently missing. Stop composing further rows for this
                        // grid; the outer grid loop's flush_aborted check stops
                        // further grids too.
                        self.flush_aborted = true;
                        break :ext_retry;
                    };

                    // Compose RenderCells for this row (resolve hl -> fg/bg/sp/style_flags)
                    self.row_cells.clearRetainingCapacity();
                    self.row_cells.ensureTotalCapacity(self.alloc, sg.cols) catch {
                        ext_had_row_error = true;
                        self.flush_aborted = true;
                        break :ext_retry;
                    };
                    self.row_cells.setLen(sg.cols);

                    // Resolve the base external-grid row directly into the
                    // row scratch. Work is proportional to the rows selected
                    // above; clean rows never copy or scan their cells.
                    const row_start: usize = @as(usize, row) * @as(usize, sg.cols);
                    for (0..sg.cols) |c| {
                        const cell_idx = row_start + c;
                        const cell: grid_mod.Cell = if (cell_idx < sg.cells.len)
                            sg.cells[cell_idx]
                        else
                            .{ .cp = ' ', .hl = 0 };
                        const attr = cache.getAttr(&self.hl, cell.hl);
                        self.row_cells.set(c, cell.cp, attr.fg, attr.bg, attr.sp, grid_id, packStyleFlags(attr), @intFromBool(attr.overline));
                        if (ext_glow_enabled) {
                            self.row_cells.glow_arr.items[c] = if (ext_glow_all) 1 else if (ext_glow_hl_ids) |ids| (if (ids.contains(cell.hl)) @as(u8, 1) else 0) else 0;
                        }
                    }
                    setViewportRowDecoFlags(
                        self.row_cells.deco_base_flags.items[0..sg.cols],
                        row,
                        sg.rows,
                        sg.cols,
                        ext_margins,
                    );

                    // Rebuild the row-local float state every time. A row
                    // callback may re-enter this function and reuse both
                    // persistent containers; the next outer row must not rely
                    // on their pre-callback contents.
                    self.flush_float_overlay_buf.clearRetainingCapacity();
                    self.flush_float_overlay_buf.ensureTotalCapacity(self.alloc, sg.cols) catch {
                        ext_had_row_error = true;
                        self.flush_aborted = true;
                        break :ext_retry;
                    };

                    if (ext_info) |info| {
                        if (info.start_row >= 0 and info.start_col >= 0) {
                            const ext_start_row: i64 = info.start_row;
                            const row_i64: i64 = row;
                            const ext_start_col: i64 = info.start_col;
                            const ext_cols_i64: i64 = sg.cols;
                            const row_usize: usize = @intCast(row);
                            std.debug.assert(self.ext_float_row_index_valid);
                            var entry_cursor: usize = self.ext_float_row_offsets.items[row_usize];
                            const entry_end: usize = self.ext_float_row_offsets.items[row_usize + 1];
                            while (entry_cursor < entry_end) : (entry_cursor += 1) {
                                const entry_index = self.ext_float_row_entry_indices.items[entry_cursor];
                                const fent = self.ext_float_entries.items[entry_index];
                                const float_pos = self.grid.win_pos.get(fent.grid_id) orelse continue;
                                const float_sg = self.grid.sub_grids.get(fent.grid_id) orelse continue;
                                const float_margins = self.grid.getViewportMargins(fent.grid_id);
                                const float_row_in_ext = @as(i64, float_pos.row) - ext_start_row;
                                const float_src_row_i64 = row_i64 - float_row_in_ext;
                                if (float_src_row_i64 < 0 or float_src_row_i64 >= @as(i64, float_sg.rows)) continue;
                                const float_src_row: u32 = @intCast(float_src_row_i64);

                                const float_col_in_ext = @as(i64, float_pos.col) - ext_start_col;
                                const target_col_start = @max(@as(i64, 0), float_col_in_ext);
                                const target_col_end = @min(ext_cols_i64, float_col_in_ext + @as(i64, float_sg.cols));
                                if (target_col_start >= target_col_end) continue;

                                var target_col_i64 = target_col_start;
                                while (target_col_i64 < target_col_end) : (target_col_i64 += 1) {
                                    const target_col: u32 = @intCast(target_col_i64);
                                    const float_src_col: u32 = @intCast(target_col_i64 - float_col_in_ext);
                                    const float_cell_idx = @as(usize, float_src_row) * @as(usize, float_sg.cols) + @as(usize, float_src_col);
                                    const cell: grid_mod.Cell = if (float_cell_idx < float_sg.cells.len)
                                        float_sg.cells[float_cell_idx]
                                    else
                                        .{ .cp = ' ', .hl = 0 };
                                    const attr = cache.getAttr(&self.hl, cell.hl);
                                    // Keep the source grid identity as a shaping
                                    // boundary: base and float text must never
                                    // form one ligature/kerning run merely
                                    // because their resolved styles match.
                                    self.row_cells.set(target_col, cell.cp, attr.fg, attr.bg, attr.sp, fent.grid_id, packStyleFlags(attr), @intFromBool(attr.overline));
                                    self.row_cells.deco_base_flags.items[target_col] = if (viewportCellScrollable(
                                        float_src_row,
                                        float_src_col,
                                        float_sg.rows,
                                        float_sg.cols,
                                        float_margins,
                                    )) c_api.DECO_SCROLLABLE else 0;
                                    if (ext_glow_enabled) {
                                        self.row_cells.glow_arr.items[target_col] = if (ext_glow_all) 1 else if (ext_glow_hl_ids) |ids| (if (ids.contains(cell.hl)) @as(u8, 1) else 0) else 0;
                                    }

                                    // Every overlaid cell gets an entry, including
                                    // null overflow, so the float always shadows
                                    // any base-grid emoji/combining overflow.
                                    self.flush_float_overlay_buf.putAssumeCapacity(
                                        .{ .row = row, .col = target_col },
                                        self.grid.getOverflow(fent.grid_id, float_src_row, float_src_col),
                                    );
                                }
                            }
                        }
                    }

                    // The map pointer is valid only for synchronous row
                    // generation. Clear it before any frontend row callback;
                    // defer also covers allocation/rasterization errors.
                    const row_gen_stats = row_gen: {
                        self.flush_float_overlay = &self.flush_float_overlay_buf;
                        defer self.flush_float_overlay = null;
                        break :row_gen generateRowVertices(self, .{
                            .row = row,
                            .cols = sg.cols,
                            .vw = grid_w,
                            .vh = grid_h,
                            .cell_w = cellW,
                            .cell_h = cellH,
                            .top_pad = topPad,
                            .default_bg = default_bg,
                            .blur_enabled = self.blur_enabled,
                            .background_opacity = self.background_opacity,
                            .is_cmdline = is_cmdline,
                            .glow_enabled = ext_glow_enabled,
                        }, ext_verts) catch |err| {
                            ext_verts.clearRetainingCapacity();
                            ext_had_row_error = true;
                            self.flush_aborted = true;
                            if (Core.isHardRenderFailure(err)) self.failHardRender(err);
                            break :ext_retry;
                        };
                    };
                    ext_had_glyph_miss = ext_had_glyph_miss or row_gen_stats.had_glyph_miss;
                    replaceSubgridSurfaceRowVertexCount(
                        self,
                        grid_id,
                        sg,
                        @intCast(row),
                        ext_verts.items.len,
                    ) catch |err| {
                        ext_had_row_error = true;
                        self.flush_aborted = true;
                        self.failHardRender(err);
                        break :ext_retry;
                    };
                    // Cursor rendering moved to separate layer (after row loop)

                    // CHECK: atlas reset happened during glyph processing for this row.
                    // Already-sent rows have stale UVs → need to restart or abort.
                    if (self.atlas_reset_during_flush) {
                        ext_saw_atlas_reset = true;
                        ext_saw_atlas_reset_any = true;
                        self.atlas_reset_during_flush = false; // Clear for retry
                        // A reset here can also invalidate glyphs the MAIN grid already
                        // used earlier in this same flush (main grid always renders
                        // before this deferred external-grid pass). Mark it so it
                        // regenerates against the fresh atlas on the next flush.
                        self.grid.markAllDirty();
                        self.invalidateScrollCache();
                        if (!ext_retried) {
                            ext_retried = true;
                            use_ext_scroll_fast_path = false; // Retry needs full redraw
                            continue :ext_retry; // Restart this grid's row loop from row 0
                        }
                        // 2nd reset: clear all sent rows (match global grid behavior)
                        for (0..viewport_rows) |clear_ri| {
                            // A clear callback can itself call zonvie_core_abort_flush
                            // (e.g. Windows COW detach failure) — stop issuing further
                            // clear callbacks into a flush that's already being
                            // discarded, matching the abort check elsewhere in this loop.
                            if (self.flush_aborted) break;
                            replaceSubgridSurfaceRowVertexCount(self, grid_id, sg, clear_ri, 0) catch |err| {
                                self.flush_aborted = true;
                                self.failHardRender(err);
                                break;
                            };
                            row_cb(self.ctx, grid_id, @intCast(clear_ri), 1, null, 0, 1, viewport_rows, viewport_cols);
                        }
                        break; // Abort remaining rows
                    }

                    // Send this row's vertices
                    // Pass viewport dimensions (target size) instead of sg dimensions so that
                    // the frontend's scroll offset calculation matches the NDC viewport used here.
                    const row_ptr = if (ext_verts.items.len == 0) null else ext_verts.items.ptr;
                    row_cb(self.ctx, grid_id, row, 1, row_ptr, ext_verts.items.len, 1, viewport_rows, viewport_cols);
                }
                break :ext_retry; // Normal exit from retry loop
            }
        }

        // --- Cursor layer: send cursor vertices as separate on_vertices_row with CURSOR flag ---
        // This keeps cursor independent of row buffers, so GPU scroll copy
        // cannot create cursor ghosts.
        // Skipped on abort (see the row-loop check above) — the frontend
        // cancels this grid's whole bracket, so sending a cursor layer for
        // it would be discarded work on top of an already-doomed flush.
        if (!self.flush_aborted) {
            if (cursor_row) |cur_row| {
                if (cur_row < sg.rows and cursor_col < sg.cols) {
                    ext_verts.clearRetainingCapacity();
                    // Estimate: 6 cursor bg + 6 cursor text + block element quads
                    ext_verts.ensureTotalCapacity(self.alloc, 48) catch {
                        self.flush_aborted = true;
                        return;
                    };

                    const cx0 = @as(f32, @floatFromInt(cursor_col)) * cellW;
                    const cy0 = @as(f32, @floatFromInt(cur_row)) * cellH;

                    var is_double_width = false;
                    if (cursor_col + 1 < sg.cols) {
                        const next_idx: usize = @as(usize, cur_row) * @as(usize, sg.cols) + @as(usize, cursor_col + 1);
                        if (next_idx < sg.cells.len and sg.cells[next_idx].cp == 0) {
                            is_double_width = true;
                        }
                    }
                    const cursor_width: f32 = if (is_double_width) cellW * 2 else cellW;

                    const pct_u32 = @max(@as(u32, 1), @min(self.grid.cursor_cell_percentage, 100));
                    const pct: f32 = @floatFromInt(pct_u32);
                    const tW = cellW * pct / 100.0;
                    const tH = cellH * pct / 100.0;

                    const crx0: f32 = cx0;
                    var cry0: f32 = cy0;
                    var crx1: f32 = cx0 + cursor_width;
                    const cry1: f32 = cy0 + cellH;

                    self.log.write("[ext_cursor] shape={s} pct={d} cursor_style_enabled={}\n", .{
                        @tagName(self.grid.cursor_shape), pct_u32, self.grid.cursor_style_enabled,
                    });

                    switch (self.grid.cursor_shape) {
                        .vertical => crx1 = cx0 + tW,
                        .horizontal => cry0 = cy0 + (cellH - tH),
                        .block => {},
                    }

                    // Cursor background quad
                    const cursor_bg: u32 = if (self.grid.cursor_attr_id != 0)
                        self.hl.get(self.grid.cursor_attr_id).bg
                    else
                        self.hl.default_fg;
                    const cursor_color = Helpers.rgb(cursor_bg);

                    const c_pts = Helpers.ndc4(crx0, cry0, crx1, cry1, grid_w, grid_h);
                    const ctl = c_pts[0];
                    const ctr = c_pts[1];
                    const cbl = c_pts[2];
                    const cbr = c_pts[3];

                    ext_verts.appendAssumeCapacity(.{ .position = ctl, .texCoord = Helpers.solid_uv, .color = cursor_color, .grid_id = grid_id, .deco_flags = c_api.DECO_CURSOR | c_api.DECO_SCROLLABLE, .deco_phase = 0 });
                    ext_verts.appendAssumeCapacity(.{ .position = ctr, .texCoord = Helpers.solid_uv, .color = cursor_color, .grid_id = grid_id, .deco_flags = c_api.DECO_CURSOR | c_api.DECO_SCROLLABLE, .deco_phase = 0 });
                    ext_verts.appendAssumeCapacity(.{ .position = cbl, .texCoord = Helpers.solid_uv, .color = cursor_color, .grid_id = grid_id, .deco_flags = c_api.DECO_CURSOR | c_api.DECO_SCROLLABLE, .deco_phase = 0 });
                    ext_verts.appendAssumeCapacity(.{ .position = ctr, .texCoord = Helpers.solid_uv, .color = cursor_color, .grid_id = grid_id, .deco_flags = c_api.DECO_CURSOR | c_api.DECO_SCROLLABLE, .deco_phase = 0 });
                    ext_verts.appendAssumeCapacity(.{ .position = cbr, .texCoord = Helpers.solid_uv, .color = cursor_color, .grid_id = grid_id, .deco_flags = c_api.DECO_CURSOR | c_api.DECO_SCROLLABLE, .deco_phase = 0 });
                    ext_verts.appendAssumeCapacity(.{ .position = cbl, .texCoord = Helpers.solid_uv, .color = cursor_color, .grid_id = grid_id, .deco_flags = c_api.DECO_CURSOR | c_api.DECO_SCROLLABLE, .deco_phase = 0 });

                    // Cursor text for block cursor
                    if (self.grid.cursor_shape == .block) {
                        const cell_idx: usize = @as(usize, cur_row) * @as(usize, sg.cols) + @as(usize, cursor_col);
                        if (cell_idx < sg.cells.len) {
                            const cursor_cell = sg.cells[cell_idx];
                            if (cursor_cell.cp != 0 and cursor_cell.cp != ' ') {
                                if (block_elements.isBlockElement(cursor_cell.cp)) {
                                    const eblk_geo = block_elements.getBlockGeometry(cursor_cell.cp);
                                    if (eblk_geo.count > 0) {
                                        const ext_cursor_fg: u32 = if (self.grid.cursor_attr_id != 0)
                                            self.hl.get(self.grid.cursor_attr_id).fg
                                        else
                                            self.hl.default_bg;
                                        const eblk_fg_col = Helpers.rgb(ext_cursor_fg);
                                        ext_verts.ensureUnusedCapacity(self.alloc, @as(usize, eblk_geo.count) * 6) catch {
                                            self.flush_aborted = true;
                                            return;
                                        };
                                        for (eblk_geo.rects[0..eblk_geo.count]) |rect| {
                                            Helpers.pushSolidQuadAssumeCapacity(ext_verts, cx0 + rect.x0 * cursor_width, cy0 + rect.y0 * cellH, cx0 + rect.x1 * cursor_width, cy0 + rect.y1 * cellH, eblk_fg_col, grid_w, grid_h, grid_id, c_api.DECO_CURSOR | c_api.DECO_SCROLLABLE);
                                        }
                                    }
                                } else {
                                    var glyph_entry: c_api.GlyphEntry = undefined;
                                    var glyph_ok: c_int = 0;

                                    const ext_cursor_resolved = self.hl.getWithStyles(cursor_cell.hl);
                                    const ext_cursor_c_style: u32 =
                                        @as(u32, if (ext_cursor_resolved.style_flags & STYLE_BOLD != 0) c_api.STYLE_BOLD else 0) |
                                        @as(u32, if (ext_cursor_resolved.style_flags & STYLE_ITALIC != 0) c_api.STYLE_ITALIC else 0);

                                    // Set emoji cluster context for ext grid cursor if emoji-significant
                                    if (self.grid.getOverflow(grid_id, cur_row, cursor_col)) |extras| {
                                        const is_emoji = isEmojiPresentation(cursor_cell.cp) or for (extras) |e| {
                                            if (e == 0xFE0F or e == 0x200D or (e >= 0x1F3FB and e <= 0x1F3FF)) break true;
                                        } else false;
                                        if (is_emoji) {
                                            self.emoji_cluster_buf[0] = cursor_cell.cp;
                                            const elen = @min(extras.len, self.emoji_cluster_buf.len - 1);
                                            for (0..elen) |ei| {
                                                self.emoji_cluster_buf[1 + ei] = extras[ei];
                                            }
                                            self.emoji_cluster_len = @intCast(1 + elen);
                                        }
                                    }
                                    defer self.emoji_cluster_len = 0;

                                    if (self.isPhase2Atlas()) {
                                        const overflow = self.grid.getOverflow(grid_id, cur_row, cursor_col);
                                        const cached_entry = ensureCachedPhase2Glyph(self, cursor_cell.cp, ext_cursor_c_style, overflow) catch blk: {
                                            self.flush_aborted = true;
                                            break :blk null;
                                        };
                                        if (cached_entry) |entry| {
                                            glyph_entry = entry;
                                            glyph_ok = 1;
                                        } else if (self.flush_aborted) {
                                            return;
                                        } else {
                                            ext_cursor_retry_required = true;
                                        }
                                    } else if (self.cb.on_atlas_ensure_glyph_styled) |styled_fn| {
                                        const ext_cursor_style = ext_cursor_resolved.style_flags & (STYLE_BOLD | STYLE_ITALIC);
                                        if (ext_cursor_style != 0) {
                                            glyph_ok = styled_fn(self.ctx, cursor_cell.cp, ext_cursor_c_style, &glyph_entry);
                                        } else if (self.cb.on_atlas_ensure_glyph) |fn_ptr| {
                                            glyph_ok = fn_ptr(self.ctx, cursor_cell.cp, &glyph_entry);
                                        }
                                    } else if (self.cb.on_atlas_ensure_glyph) |fn_ptr| {
                                        glyph_ok = fn_ptr(self.ctx, cursor_cell.cp, &glyph_entry);
                                    }

                                    // CHECK: the cursor glyph ensure above can itself trigger an
                                    // atlas reset that no later code in this function re-checks.
                                    // Handle it here instead of leaking the flag into the next
                                    // external grid's retry check or the next flush.
                                    if (self.atlas_reset_during_flush) {
                                        ext_saw_atlas_reset = true;
                                        ext_saw_atlas_reset_any = true;
                                        self.atlas_reset_during_flush = false;
                                        self.grid.markAllDirty();
                                        self.invalidateScrollCache();
                                    }

                                    if (glyph_ok != 0 and glyph_entry.bbox_size_px[0] > 0 and glyph_entry.bbox_size_px[1] > 0) {
                                        const cursorBaseY: f32 = cy0 + topPad;
                                        const baselineY: f32 = cursorBaseY + glyph_entry.ascent_px;
                                        const gx0: f32 = cx0 + glyph_entry.bbox_origin_px[0];
                                        const gx1: f32 = gx0 + glyph_entry.bbox_size_px[0];
                                        const gy0: f32 = baselineY - (glyph_entry.bbox_origin_px[1] + glyph_entry.bbox_size_px[1]);
                                        const gy1: f32 = gy0 + glyph_entry.bbox_size_px[1];

                                        const uv_x0 = glyph_entry.uv_min[0];
                                        const uv_y0 = glyph_entry.uv_min[1];
                                        const uv_x1 = glyph_entry.uv_max[0];
                                        const uv_y1 = glyph_entry.uv_max[1];

                                        const cursor_fg: u32 = if (self.grid.cursor_attr_id != 0)
                                            self.hl.get(self.grid.cursor_attr_id).fg
                                        else
                                            self.hl.default_bg;
                                        const text_col = Helpers.rgb(cursor_fg);

                                        const cg_pts = Helpers.ndc4(gx0, gy0, gx1, gy1, grid_w, grid_h);
                                        const gtl = cg_pts[0];
                                        const gtr = cg_pts[1];
                                        const gbl = cg_pts[2];
                                        const gbr = cg_pts[3];

                                        const cursor_glyph_flags = externalCursorGlyphDecoFlags(glyph_entry.bytes_per_pixel);
                                        ext_verts.appendAssumeCapacity(.{ .position = gtl, .texCoord = .{ uv_x0, uv_y0 }, .color = text_col, .grid_id = grid_id, .deco_flags = cursor_glyph_flags, .deco_phase = 0 });
                                        ext_verts.appendAssumeCapacity(.{ .position = gtr, .texCoord = .{ uv_x1, uv_y0 }, .color = text_col, .grid_id = grid_id, .deco_flags = cursor_glyph_flags, .deco_phase = 0 });
                                        ext_verts.appendAssumeCapacity(.{ .position = gbl, .texCoord = .{ uv_x0, uv_y1 }, .color = text_col, .grid_id = grid_id, .deco_flags = cursor_glyph_flags, .deco_phase = 0 });
                                        ext_verts.appendAssumeCapacity(.{ .position = gtr, .texCoord = .{ uv_x1, uv_y0 }, .color = text_col, .grid_id = grid_id, .deco_flags = cursor_glyph_flags, .deco_phase = 0 });
                                        ext_verts.appendAssumeCapacity(.{ .position = gbr, .texCoord = .{ uv_x1, uv_y1 }, .color = text_col, .grid_id = grid_id, .deco_flags = cursor_glyph_flags, .deco_phase = 0 });
                                        ext_verts.appendAssumeCapacity(.{ .position = gbl, .texCoord = .{ uv_x0, uv_y1 }, .color = text_col, .grid_id = grid_id, .deco_flags = cursor_glyph_flags, .deco_phase = 0 });
                                    }
                                }
                            }
                        }
                    }

                    if (self.flush_aborted) return;

                    // Send cursor vertices as separate layer (flags = CURSOR)
                    row_cb(self.ctx, grid_id, cur_row, 1, ext_verts.items.ptr, ext_verts.items.len, c_api.VERT_UPDATE_CURSOR, viewport_rows, viewport_cols);
                    self.log.write("[ext_cursor_layer] grid_id={d} cursor_row={d} cursor_col={d} cursor_verts={d}\n", .{ grid_id, cur_row, cursor_col, ext_verts.items.len });
                }
            } else if ((cursor_was_on_this_grid or self.force_ext_cursor_recheck) and !cursor_on_this_grid) {
                // Cursor left this grid: send empty cursor to clear previous
                // cursor. force_ext_cursor_recheck: last_ext_cursor_grid cannot
                // be trusted to still name the right grid after a prior failed
                // flush (see its doc comment) — clearing the cursor on every
                // OTHER external grid unconditionally is a harmless no-op for
                // grids that were already clean, and closes the actual gap for
                // whichever grid was NOT the one that got renamed.
                row_cb(self.ctx, grid_id, 0, 1, null, 0, c_api.VERT_UPDATE_CURSOR, viewport_rows, viewport_cols);
                self.log.write("[ext_cursor_layer] grid_id={d} cursor_left, clearing cursor\n", .{grid_id});
            }
        }

        // Debug log glyph statistics
        self.log.write("[ext_grid_row] grid_id={d} rows={d} cols={d} scroll_fast_path={} regen_count={d}\n", .{
            grid_id, sg.rows, sg.cols, use_ext_scroll_fast_path, regen_count,
        });

        // Log cache performance for this grid
        self.log.write("[ext_grid_perf] grid_id={d} hl_cache hits={d} misses={d}\n", .{
            grid_id, cache.perf_hl_cache_hits, cache.perf_hl_cache_misses,
        });
        self.log.write("[ext_grid_perf] grid_id={d} glyph_cache ascii_hits={d} ascii_misses={d} nonascii_hits={d} nonascii_misses={d}\n", .{
            grid_id, cache.perf_glyph_ascii_hits, cache.perf_glyph_ascii_misses, cache.perf_glyph_nonascii_hits, cache.perf_glyph_nonascii_misses,
        });

        // Clear dirty flags after sending (both dirty and dirty_rows).
        // Skipped on mid-flush abort (frontend OOM via
        // zonvie_core_abort_flush): keep dirty so the rows are re-sent.
        if (!self.flush_aborted) sg.clearDirtyContent();
        // If a row failed (allocation error), re-mark the grid dirty
        // so the failed rows get regenerated on the next flush.
        if (ext_had_row_error) {
            sg.markAllDirty();
        }
        // If atlas was reset during this grid's rendering, re-mark dirty
        // so it gets re-rendered with correct UVs next flush.
        if (ext_saw_atlas_reset) {
            sg.markAllDirty();
        }
        // A rasterizer miss is transient (font backend/cache publication may
        // complete before the next frame). Keep the grid dirty so the missing
        // glyph is regenerated instead of becoming permanently blank.
        if (ext_had_glyph_miss) {
            sg.markAllDirty();
        }
    }

    // After ALL grids processed: if any atlas reset occurred,
    // already-sent grids also have stale UVs → mark ALL sub_grids dirty.
    // The MAIN grid is included too: this function runs as a deferred call
    // AFTER the main row-mode loop already dispatched its vertices this
    // same flush (on_vertices_row, with UVs baked against the pre-reset
    // atlas). Those vertices are committed as-is alongside the just-reset
    // (differently-packed) atlas texture — one frame of main-grid glyph
    // corruption/blank cells that only markAllDirty (forcing a full main
    // resend next flush against the corrected atlas) can heal.
    if (ext_saw_atlas_reset_any) {
        self.grid.markAllDirty();
        self.invalidateScrollCache();
        var sg_it = self.grid.sub_grids.valueIterator();
        while (sg_it.next()) |sg_val| {
            sg_val.markAllDirty();
        }
        // The cursor is a separate vertex consumer gated on cursor_rev
        // alone (main and external both) — this atlas reset invalidates
        // its cached UVs too, but none of the dirtying above touches it.
        self.grid.cursor_rev +%= 1;
        // markAllDirty schedules a correct NEXT flush; it cannot undo THIS
        // flush's already-dispatched main vertices (pre-reset UVs). Signal
        // frontends to cancel the current commit entirely — see the field
        // doc comment (nvim_core.zig) and zonvie_core_flush_had_atlas_corruption.
        self.flush_atlas_corrupted = true;
    }
}

/// Wrapper for sendExternalGridVerticesFiltered - updates all grids.
pub fn sendExternalGridVertices(self: *Core, force_render: bool) void {
    sendExternalGridVerticesFiltered(self, force_render, null);
}

fn abortClusterUpdate(self: *Core, scope: []const u8, err: anyerror) void {
    // Synthetic grid builders run inside the frontend flush bracket. They
    // retain their source dirty flag on failure; aborting prevents the
    // partially rebuilt grid from being committed before that retry.
    self.flush_aborted = true;
    self.log.write("[{s}] overflow map update failed: {any}\n", .{ scope, err });
}

/// Check for cmdline state changes and create/update/close external float window via Neovim API.
/// The cmdline is rendered by Neovim in an external float window.
pub fn notifyCmdlineChanges(self: *Core) void {
    if (!self.grid.cmdline_dirty) return;
    if (!self.ext_cmdline_enabled) return;
    // NOTE: dirty is cleared explicitly at each success-return path below, NOT
    // via defer — on resizeGrid/setWinExternalPos failure (OOM only) we must
    // leave cmdline_dirty set so the next flush retries, per the "clear dirty
    // only after successful submission" rule.

    // Check if any cmdline is visible, find the highest level (most recent)
    var any_visible = false;
    var visible_level: u32 = 0;
    var state_it = self.grid.cmdline_states.iterator();
    while (state_it.next()) |entry| {
        if (entry.value_ptr.visible) {
            any_visible = true;
            // Use the highest level (Expression register is level 2, normal cmdline is level 1)
            if (entry.key_ptr.* > visible_level) {
                visible_level = entry.key_ptr.*;
            }
        }
    }

    const block_visible = self.grid.cmdline_block.visible;
    const block_line_count: u32 = @intCast(self.grid.cmdline_block.lines.items.len);

    // Handle cmdline_block mode (multi-line input like :lua <<EOF)
    if (block_visible and block_line_count > 0) {
        if (sendCmdlineBlockShow(self, any_visible, visible_level)) {
            self.grid.clearCmdlineDirty();
        }
        return;
    }

    if (any_visible) {
        const state = self.grid.cmdline_states.getPtr(visible_level) orelse {
            // No state for this level: nothing to show, and no future retry
            // makes this succeed for the same dirty state — clear it now.
            self.grid.clearCmdlineDirty();
            return;
        };
        const cmdline_grid_id = grid_mod.CMDLINE_GRID_ID;

        // Record command content into last_cmd_buf — currently written and
        // never read; the split-view label it was collected for was never
        // wired up (see the field declaration in nvim_core.zig).
        // (record every update, the final content before hide is the
        // executed command)
        self.last_cmd_firstc = state.firstc;
        self.last_cmd_len = 0;
        for (state.content.items) |chunk| {
            const remaining = self.last_cmd_buf.len - self.last_cmd_len;
            const copy_len = @min(chunk.text.len, remaining);
            if (copy_len > 0) {
                @memcpy(self.last_cmd_buf[self.last_cmd_len..][0..copy_len], chunk.text[0..copy_len]);
                self.last_cmd_len += copy_len;
            }
        }
        // Record start time when command is first shown
        if (self.last_cmd_start_time == null) {
            self.last_cmd_start_time = clock.nowNs();
        }

        // Notify Swift about cmdline show (for icon update etc.)
        // Note: We pass minimal info here since content requires type conversion.
        // The main purpose is to inform Swift about firstc for icon display.
        if (self.cb.on_cmdline_show) |callback| {
            var dummy_content: [1]c_api.CmdlineChunk = .{c_api.CmdlineChunk{
                .hl_id = 0,
                .text = "",
                .text_len = 0,
            }};
            callback(
                self.ctx,
                &dummy_content,
                0, // content_count = 0, so Swift won't read content
                state.pos,
                state.firstc,
                state.prompt.ptr,
                state.prompt.len,
                state.indent,
                visible_level,
                state.prompt_hl_id,
            );
        }

        // Check if content has control characters (affects special_char display)
        const has_control_chars = blk: {
            for (state.content.items) |chunk| {
                var citer = std.unicode.Utf8View.initUnchecked(chunk.text).iterator();
                while (citer.nextCodepoint()) |cp| {
                    if (cp < 0x20 or cp == 0x7F) break :blk true;
                }
            }
            break :blk false;
        };

        // Calculate display width: firstc + prompt + indent + content (with caret notation) + special_char
        var display_width: u32 = 0;
        if (state.firstc != 0) display_width += 1;
        display_width += countDisplayWidth(state.prompt);
        display_width += state.indent;
        for (state.content.items) |chunk| {
            display_width += countDisplayWidth(chunk.text);
        }
        const special = state.getSpecialChar();
        if (!has_control_chars and special.len > 0) {
            display_width += countDisplayWidth(special);
        }

        // Grid width: start at the frontend's default width (a fraction of the
        // main window, chrome already subtracted), expand up to screen width,
        // then scroll. Without a frontend default, fall back to the main grid.
        const min_width: u32 = if (self.grid.cmdline_default_cols > 0)
            self.grid.cmdline_default_cols
        else if (self.grid.cols > 0) self.grid.cols else 80;
        const max_width: u32 = if (self.grid.screen_cols > 0) self.grid.screen_cols else min_width;
        const content_width: u32 = display_width + 1; // +1 for cursor
        const width: u32 = @min(@max(content_width, min_width), max_width);

        // Calculate cursor display column (before scroll) for scroll offset calculation.
        // This duplicates the cursor_col logic below but is needed before grid writing.
        var cursor_display_col: u32 = 0;
        if (state.firstc != 0) cursor_display_col += 1;
        cursor_display_col += countDisplayWidth(state.prompt);
        cursor_display_col += state.indent;
        {
            var cdc_bytes_remaining: u32 = state.pos;
            for (state.content.items) |chunk| {
                const ctext = chunk.text;
                if (cdc_bytes_remaining == 0) break;
                if (cdc_bytes_remaining >= ctext.len) {
                    cursor_display_col += countDisplayWidth(ctext);
                    cdc_bytes_remaining -= @intCast(ctext.len);
                    continue;
                }
                var cbyte_i: usize = 0;
                while (cbyte_i < ctext.len) {
                    if (cdc_bytes_remaining == 0) break;
                    const cluster = scanEmojiCluster(ctext, cbyte_i);
                    if (cluster.codepoint_count == 0) break;
                    const cluster_bytes: u32 = @intCast(cluster.end_byte - cbyte_i);
                    if (cluster.first_cp < 0x20 or cluster.first_cp == 0x7F) {
                        cursor_display_col += 2;
                    } else {
                        cursor_display_col += cluster.display_width;
                    }
                    if (cdc_bytes_remaining >= cluster_bytes) {
                        cdc_bytes_remaining -= cluster_bytes;
                    } else {
                        cdc_bytes_remaining = 0;
                    }
                    cbyte_i = cluster.end_byte;
                }
                break;
            }
        }

        // Calculate scroll offset: keep cursor visible within the viewport.
        // Start from previous scroll offset and adjust only when cursor escapes
        // the visible range, providing smooth scrolling in both directions.
        const scroll_offset: u32 = blk: {
            var off = state.scroll_offset;
            const cursor_right_edge = cursor_display_col + 1; // +1 for cursor cell
            if (cursor_right_edge > off + width) {
                // Cursor past right edge of viewport: scroll right
                off = cursor_right_edge - width;
            } else if (cursor_display_col < off) {
                // Cursor past left edge of viewport: scroll left
                off = cursor_display_col;
            }
            // Clamp: don't scroll past end of content
            const max_off = if (display_width + 1 > width) display_width + 1 - width else 0;
            off = @min(off, max_off);
            break :blk off;
        };
        state.scroll_offset = scroll_offset;

        // Create or resize cmdline grid
        self.grid.resizeGrid(cmdline_grid_id, 1, width) catch |e| {
            self.log.write("[cmdline] resizeGrid failed: {any}\n", .{e});
            return; // cmdline_dirty stays set; retry next flush
        };
        self.grid.clearGrid(cmdline_grid_id);

        // Write to grid with proper hl_ids, accounting for scroll offset
        var logical_col: u32 = 0; // Position in the full content
        var grid_col: u32 = 0; // Position in the visible grid

        // Helper to write a cell, respecting scroll offset
        const WriterState = struct {
            grid: *grid_mod.Grid,
            grid_id: i64,
            scroll_offset: u32,
            width: u32,
            logical_col: *u32,
            grid_col: *u32,

            fn writeCell(s: @This(), cp: u32, hl_id: u32) bool {
                if (s.logical_col.* >= s.scroll_offset) {
                    if (s.grid_col.* >= s.width) return false;
                    s.grid.putCellGrid(s.grid_id, 0, s.grid_col.*, cp, hl_id);
                    s.grid_col.* += 1;
                }
                s.logical_col.* += 1;
                return true;
            }

            fn writeCluster(s: @This(), cp: u32, hl_id: u32, extras: []const u32) !bool {
                if (s.logical_col.* >= s.scroll_offset) {
                    if (s.grid_col.* >= s.width) return false;
                    try s.grid.putCellGridCluster(s.grid_id, 0, s.grid_col.*, cp, hl_id, extras);
                    s.grid_col.* += 1;
                }
                s.logical_col.* += 1;
                return true;
            }
        };

        var writer = WriterState{
            .grid = &self.grid,
            .grid_id = cmdline_grid_id,
            .scroll_offset = scroll_offset,
            .width = width,
            .logical_col = &logical_col,
            .grid_col = &grid_col,
        };

        // firstc (e.g. ':' '/' '?') - use hl_id 0 (default)
        if (state.firstc != 0) {
            if (!writer.writeCell(state.firstc, 0)) {}
        }

        // prompt - use prompt_hl_id (cluster-aware)
        if (state.prompt.len > 0) {
            var pbyte_i: usize = 0;
            while (pbyte_i < state.prompt.len) {
                const pc = scanEmojiCluster(state.prompt, pbyte_i);
                if (pc.codepoint_count == 0) break;
                const wrote_base = writer.writeCluster(
                    pc.first_cp,
                    state.prompt_hl_id,
                    pc.extras[0..pc.extras_len],
                ) catch |e| {
                    abortClusterUpdate(self, "cmdline", e);
                    return;
                };
                if (!wrote_base) break;
                if (pc.display_width >= 2) {
                    if (!writer.writeCell(0, state.prompt_hl_id)) break;
                }
                pbyte_i = pc.end_byte;
            }
        }

        // indent (spaces) - use hl_id 0
        var indent_i: u32 = 0;
        while (indent_i < state.indent) : (indent_i += 1) {
            if (!writer.writeCell(' ', 0)) break;
        }

        // content chunks - use each chunk's hl_id, with caret notation for control chars.
        // Multi-codepoint sequences (emoji ZWJ, VS16, etc.) are stored as:
        //   first codepoint → Cell.cp, extra codepoints → overflow map.
        for (state.content.items) |chunk| {
            const text = chunk.text;
            var byte_i: usize = 0;
            while (byte_i < text.len) {
                const cluster = scanEmojiCluster(text, byte_i);
                if (cluster.codepoint_count == 0) break;

                if (cluster.first_cp < 0x20) {
                    if (!writer.writeCell('^', chunk.hl_id)) break;
                    if (!writer.writeCell('@' + cluster.first_cp, chunk.hl_id)) break;
                    byte_i = cluster.end_byte;
                    continue;
                }
                if (cluster.first_cp == 0x7F) {
                    if (!writer.writeCell('^', chunk.hl_id)) break;
                    if (!writer.writeCell('?', chunk.hl_id)) break;
                    byte_i = cluster.end_byte;
                    continue;
                }

                // Write the base cell. Track whether it was actually written
                // (scrolled-off cells are skipped by writeCell).
                const wrote_base = writer.writeCluster(
                    cluster.first_cp,
                    chunk.hl_id,
                    cluster.extras[0..cluster.extras_len],
                ) catch |e| {
                    abortClusterUpdate(self, "cmdline", e);
                    return;
                };
                if (!wrote_base) break;

                // Continuation cell only for double-width characters
                if (cluster.display_width >= 2) {
                    if (!writer.writeCell(0, chunk.hl_id)) break;
                }

                byte_i = cluster.end_byte;
            }
        }

        // special_char (shown at cursor position after Ctrl-V etc.) - cluster-aware
        if (!has_control_chars and special.len > 0) {
            var sbyte_i: usize = 0;
            while (sbyte_i < special.len) {
                const sc = scanEmojiCluster(special, sbyte_i);
                if (sc.codepoint_count == 0) break;
                const wrote_base = writer.writeCluster(
                    sc.first_cp,
                    0,
                    sc.extras[0..sc.extras_len],
                ) catch |e| {
                    abortClusterUpdate(self, "cmdline", e);
                    return;
                };
                if (!wrote_base) break;
                if (sc.display_width >= 2) {
                    if (!writer.writeCell(0, 0)) break;
                }
                sbyte_i = sc.end_byte;
            }
        }

        // Cursor position in the visible grid: reuse pre-computed cursor_display_col,
        // adjusted for scroll offset.
        const cursor_col: u32 = if (cursor_display_col >= scroll_offset) cursor_display_col - scroll_offset else 0;

        // Mark as external grid
        _ = self.grid.setWinExternalPos(cmdline_grid_id, 0) catch |e| {
            self.log.write("[cmdline] setWinExternalPos failed: {any}\n", .{e});
            return; // cmdline_dirty stays set; retry next flush
        };

        // Save current cursor position before switching to cmdline (only if not already on cmdline)
        if (self.grid.cursor_grid != cmdline_grid_id) {
            self.pre_cmdline_cursor_grid = self.grid.cursor_grid;
            self.pre_cmdline_cursor_row = self.grid.cursor_row;
            self.pre_cmdline_cursor_col = self.grid.cursor_col;
            self.log.write("[cmdline] saving pre_cmdline cursor: grid={d} row={d} col={d}\n", .{
                self.pre_cmdline_cursor_grid, self.pre_cmdline_cursor_row, self.pre_cmdline_cursor_col,
            });
        }

        // Set cursor position
        self.grid.cursor_grid = cmdline_grid_id;
        self.grid.cursor_row = 0;
        self.grid.cursor_col = cursor_col;
        self.grid.cursor_valid = true;

        self.log.write("[cmdline] show: width={d} cursor={d} display_width={d}\n", .{ width, cursor_col, display_width });
        self.grid.clearCmdlineDirty();
    } else if (!block_visible) {
        // No cmdline visible and no block visible - close the external float window
        sendCmdlineHide(self);
        self.grid.clearCmdlineDirty();
    } else {
        // block_visible with zero block lines and no visible cmdline level:
        // nothing to show or hide. No retry makes this same dirty state
        // succeed, so clear it (the removed blanket defer also cleared here);
        // otherwise cmdline_dirty stays set and this scan re-runs every flush.
        self.grid.clearCmdlineDirty();
    }
}

/// Handle cmdline_block mode (multi-line input).
/// Shows all block lines + current cmdline line in a multi-row grid.
pub fn sendCmdlineBlockShow(self: *Core, current_line_visible: bool, visible_level: u32) bool {
    const cmdline_grid_id = grid_mod.CMDLINE_GRID_ID;
    const block_lines = self.grid.cmdline_block.lines.items;
    const block_line_count: u32 = @intCast(block_lines.len);

    // Calculate total rows and max width
    // Minimum width = the frontend's default cmdline width (chrome already
    // subtracted), falling back to the global grid width. Must match the
    // single-line path in notifyCmdlineChanges, or the window snaps to a
    // different width the moment a block becomes visible.
    const min_width: u32 = if (self.grid.cmdline_default_cols > 0)
        self.grid.cmdline_default_cols
    else if (self.grid.cols > 0) self.grid.cols else 40;
    var max_width: u32 = min_width;

    // Calculate width from block lines (accounting for control characters)
    for (block_lines) |line| {
        var line_width: u32 = 0;
        for (line.items) |chunk| {
            line_width += countDisplayWidth(chunk.text);
        }
        if (line_width + 1 > max_width) max_width = line_width + 1;
    }

    // Calculate current cmdline line width if visible
    var cursor_col: u32 = 0;
    var current_has_control_chars = false;
    var current_state: ?*grid_mod.CmdlineState = null;

    if (current_line_visible) {
        if (self.grid.cmdline_states.getPtr(visible_level)) |state| {
            current_state = state;

            // Check for control characters
            current_has_control_chars = blk: {
                for (state.content.items) |chunk| {
                    var citer = std.unicode.Utf8View.initUnchecked(chunk.text).iterator();
                    while (citer.nextCodepoint()) |cp| {
                        if (cp < 0x20 or cp == 0x7F) break :blk true;
                    }
                }
                break :blk false;
            };

            // Calculate display width
            var current_width: u32 = 0;
            if (state.firstc != 0) current_width += 1;
            current_width += countDisplayWidth(state.prompt);
            current_width += state.indent;
            for (state.content.items) |chunk| {
                current_width += countDisplayWidth(chunk.text);
            }
            const special = state.getSpecialChar();
            if (!current_has_control_chars and special.len > 0) {
                current_width += countDisplayWidth(special);
            }
            if (current_width + 1 > max_width) max_width = current_width + 1;

            // Cursor position: firstc + prompt + indent + display_pos
            // pos is a byte offset (same as regular cmdline).
            if (state.firstc != 0) cursor_col += 1;
            cursor_col += countDisplayWidth(state.prompt);
            cursor_col += state.indent;
            var bytes_remaining: u32 = state.pos;
            outer: for (state.content.items) |chunk| {
                const ctext = chunk.text;
                if (bytes_remaining == 0) break :outer;
                if (bytes_remaining >= ctext.len) {
                    cursor_col += countDisplayWidth(ctext);
                    bytes_remaining -= @intCast(ctext.len);
                    continue;
                }
                var cbyte_i: usize = 0;
                while (cbyte_i < ctext.len) {
                    if (bytes_remaining == 0) break :outer;
                    const cluster = scanEmojiCluster(ctext, cbyte_i);
                    if (cluster.codepoint_count == 0) break;
                    const cluster_bytes: u32 = @intCast(cluster.end_byte - cbyte_i);
                    if (cluster.first_cp < 0x20 or cluster.first_cp == 0x7F) {
                        cursor_col += 2;
                    } else {
                        cursor_col += cluster.display_width;
                    }
                    if (bytes_remaining >= cluster_bytes) {
                        bytes_remaining -= cluster_bytes;
                    } else {
                        bytes_remaining = 0;
                    }
                    cbyte_i = cluster.end_byte;
                }
            }
        }
    }

    // Frontend will constrain max_width to screen width
    const total_rows: u32 = block_line_count + (if (current_line_visible) @as(u32, 1) else @as(u32, 0));

    // Create or resize cmdline grid
    self.grid.resizeGrid(cmdline_grid_id, total_rows, max_width) catch |e| {
        self.log.write("[cmdline_block] resizeGrid failed: {any}\n", .{e});
        return false;
    };

    // Clear the grid first
    self.grid.clearGrid(cmdline_grid_id);

    // Write block lines to grid using scanEmojiCluster for multi-codepoint emoji
    for (block_lines, 0..) |line, row_idx| {
        const row: u32 = @intCast(row_idx);
        var col: u32 = 0;
        for (line.items) |chunk| {
            const text = chunk.text;
            var byte_i: usize = 0;
            while (byte_i < text.len) {
                if (col >= max_width) break;
                const cluster = scanEmojiCluster(text, byte_i);
                if (cluster.codepoint_count == 0) break;

                if (cluster.first_cp < 0x20) {
                    self.grid.putCellGrid(cmdline_grid_id, row, col, '^', chunk.hl_id);
                    col += 1;
                    if (col >= max_width) {
                        byte_i = cluster.end_byte;
                        break;
                    }
                    self.grid.putCellGrid(cmdline_grid_id, row, col, '@' + cluster.first_cp, chunk.hl_id);
                    col += 1;
                } else if (cluster.first_cp == 0x7F) {
                    self.grid.putCellGrid(cmdline_grid_id, row, col, '^', chunk.hl_id);
                    col += 1;
                    if (col >= max_width) {
                        byte_i = cluster.end_byte;
                        break;
                    }
                    self.grid.putCellGrid(cmdline_grid_id, row, col, '?', chunk.hl_id);
                    col += 1;
                } else {
                    self.grid.putCellGridCluster(
                        cmdline_grid_id,
                        row,
                        col,
                        cluster.first_cp,
                        chunk.hl_id,
                        cluster.extras[0..cluster.extras_len],
                    ) catch |e| {
                        abortClusterUpdate(self, "cmdline_block", e);
                        return false;
                    };
                    col += 1;
                    if (cluster.display_width >= 2) {
                        if (col >= max_width) {
                            byte_i = cluster.end_byte;
                            break;
                        }
                        self.grid.putCellGrid(cmdline_grid_id, row, col, 0, chunk.hl_id);
                        col += 1;
                    }
                }

                byte_i = cluster.end_byte;
            }
        }
    }

    // Write current cmdline line (last row) with proper hl_ids
    if (current_line_visible) {
        if (current_state) |state| {
            var col: u32 = 0;

            // firstc (e.g. ':' '/' '?') - use hl_id 0 (default)
            if (state.firstc != 0) {
                self.grid.putCellGrid(cmdline_grid_id, block_line_count, col, state.firstc, 0);
                col += 1;
            }

            // prompt - use prompt_hl_id (cluster-aware)
            if (state.prompt.len > 0) {
                var pbyte_i: usize = 0;
                while (pbyte_i < state.prompt.len) {
                    if (col >= max_width) break;
                    const pc = scanEmojiCluster(state.prompt, pbyte_i);
                    if (pc.codepoint_count == 0) break;
                    self.grid.putCellGridCluster(
                        cmdline_grid_id,
                        block_line_count,
                        col,
                        pc.first_cp,
                        state.prompt_hl_id,
                        pc.extras[0..pc.extras_len],
                    ) catch |e| {
                        abortClusterUpdate(self, "cmdline_block", e);
                        return false;
                    };
                    col += 1;
                    if (pc.display_width >= 2) {
                        if (col >= max_width) {
                            pbyte_i = pc.end_byte;
                            break;
                        }
                        self.grid.putCellGrid(cmdline_grid_id, block_line_count, col, 0, state.prompt_hl_id);
                        col += 1;
                    }
                    pbyte_i = pc.end_byte;
                }
            }

            // indent (spaces) - use hl_id 0
            var indent_i: u32 = 0;
            while (indent_i < state.indent and col < max_width) : (indent_i += 1) {
                self.grid.putCellGrid(cmdline_grid_id, block_line_count, col, ' ', 0);
                col += 1;
            }

            // content chunks - cluster-aware (matching regular cmdline path)
            for (state.content.items) |chunk| {
                const text = chunk.text;
                var byte_i: usize = 0;
                while (byte_i < text.len) {
                    if (col >= max_width) break;
                    const cluster = scanEmojiCluster(text, byte_i);
                    if (cluster.codepoint_count == 0) break;

                    if (cluster.first_cp < 0x20) {
                        self.grid.putCellGrid(cmdline_grid_id, block_line_count, col, '^', chunk.hl_id);
                        col += 1;
                        if (col >= max_width) {
                            byte_i = cluster.end_byte;
                            break;
                        }
                        self.grid.putCellGrid(cmdline_grid_id, block_line_count, col, '@' + cluster.first_cp, chunk.hl_id);
                        col += 1;
                    } else if (cluster.first_cp == 0x7F) {
                        self.grid.putCellGrid(cmdline_grid_id, block_line_count, col, '^', chunk.hl_id);
                        col += 1;
                        if (col >= max_width) {
                            byte_i = cluster.end_byte;
                            break;
                        }
                        self.grid.putCellGrid(cmdline_grid_id, block_line_count, col, '?', chunk.hl_id);
                        col += 1;
                    } else {
                        self.grid.putCellGridCluster(
                            cmdline_grid_id,
                            block_line_count,
                            col,
                            cluster.first_cp,
                            chunk.hl_id,
                            cluster.extras[0..cluster.extras_len],
                        ) catch |e| {
                            abortClusterUpdate(self, "cmdline_block", e);
                            return false;
                        };
                        col += 1;
                        if (cluster.display_width >= 2) {
                            if (col >= max_width) {
                                byte_i = cluster.end_byte;
                                break;
                            }
                            self.grid.putCellGrid(cmdline_grid_id, block_line_count, col, 0, chunk.hl_id);
                            col += 1;
                        }
                    }

                    byte_i = cluster.end_byte;
                }
            }

            // special_char (shown at cursor position after Ctrl-V etc.) - cluster-aware
            if (!current_has_control_chars) {
                const special = state.getSpecialChar();
                if (special.len > 0) {
                    var sbyte_i: usize = 0;
                    while (sbyte_i < special.len) {
                        if (col >= max_width) break;
                        const sc = scanEmojiCluster(special, sbyte_i);
                        if (sc.codepoint_count == 0) break;
                        self.grid.putCellGridCluster(
                            cmdline_grid_id,
                            block_line_count,
                            col,
                            sc.first_cp,
                            0,
                            sc.extras[0..sc.extras_len],
                        ) catch |e| {
                            abortClusterUpdate(self, "cmdline_block", e);
                            return false;
                        };
                        col += 1;
                        if (sc.display_width >= 2) {
                            if (col >= max_width) {
                                sbyte_i = sc.end_byte;
                                break;
                            }
                            self.grid.putCellGrid(cmdline_grid_id, block_line_count, col, 0, 0);
                            col += 1;
                        }
                        sbyte_i = sc.end_byte;
                    }
                }
            }
        }
    }

    // Mark as external grid
    _ = self.grid.setWinExternalPos(cmdline_grid_id, 0) catch |e| {
        self.log.write("[cmdline_block] setWinExternalPos failed: {any}\n", .{e});
        return false;
    };

    // Set cursor position (on the last row - current cmdline line)
    self.grid.cursor_grid = cmdline_grid_id;
    self.grid.cursor_row = if (current_line_visible) block_line_count else block_line_count -| 1;
    self.grid.cursor_col = cursor_col;
    self.grid.cursor_valid = true;

    self.log.write("[cmdline_block] show: rows={d} cols={d} cursor_row={d} cursor_col={d}\n", .{ total_rows, max_width, self.grid.cursor_row, cursor_col });
    return true;
}

/// Hide cmdline external window by removing from external grids
pub fn sendCmdlineHide(self: *Core) void {
    const cmdline_grid_id = grid_mod.CMDLINE_GRID_ID;

    // Remove from external grids.
    // Note: Don't call on_external_window_close here - it will be called by
    // notifyExternalWindowChanges() which detects the grid was removed from
    // external_grids but still exists in known_external_grids.
    _ = self.grid.removeSyntheticExternal(cmdline_grid_id) catch |err| {
        if (Core.isHardRenderFailure(err)) self.failHardRender(err);
        return;
    };

    // Fallback: restore cursor to pre-cmdline position if Neovim doesn't send grid_cursor_goto
    // (This is a workaround for possible Neovim bug where cursor position isn't updated after cmdline closes)
    if (self.grid.cursor_grid == cmdline_grid_id and self.pre_cmdline_cursor_grid != cmdline_grid_id) {
        self.log.write("[cmdline] hide: restoring cursor to pre_cmdline: grid={d} row={d} col={d}\n", .{
            self.pre_cmdline_cursor_grid, self.pre_cmdline_cursor_row, self.pre_cmdline_cursor_col,
        });
        self.grid.cursor_grid = self.pre_cmdline_cursor_grid;
        self.grid.cursor_row = self.pre_cmdline_cursor_row;
        self.grid.cursor_col = self.pre_cmdline_cursor_col;
        self.grid.cursor_rev +%= 1;
    }

    // Neovim does NOT send msg_clear after confirm dialog is answered via cmdline.
    // Dismiss confirm when cmdline hides (noice.nvim pattern: confirm lifecycle = cmdline lifecycle).
    if (self.grid.message_state.confirm_msg.active) {
        self.log.write("[cmdline] hide: dismissing confirm (cmdline lifecycle)\n", .{});
        self.grid.message_state.confirm_msg.clear();
        self.grid.message_state.confirm_dirty = true;
    }

    self.log.write("[cmdline] hide\n", .{});
}

/// Handle popupmenu changes - creates/closes external window using grid (like cmdline).
pub fn notifyPopupmenuChanges(self: *Core) void {
    if (!self.grid.popupmenu.changed) return;
    if (!self.ext_popupmenu_enabled) return;

    // Verbose logging disabled for performance
    // self.log.write("[popupmenu] notifyPopupmenuChanges visible={} items={d}\n", .{
    //     self.grid.popupmenu.visible,
    //     self.grid.popupmenu.items.items.len,
    // });

    if (self.grid.popupmenu.visible) {
        // Only clear popupmenu.changed on success (OOM only) so a failed
        // resize/registration retries on the next flush instead of silently
        // dropping the update. See CLAUDE.md: "flush must only clear dirty
        // state after successful submission."
        if (sendPopupmenuShow(self)) {
            self.grid.clearPopupmenuChanged();
        }
    } else {
        sendPopupmenuHide(self);
        self.grid.clearPopupmenuChanged();
    }
}

/// Notify frontend of tabline changes.
pub fn notifyTablineChanges(self: *Core) void {
    if (!self.grid.tabline_state.dirty) return;
    if (!self.ext_tabline_enabled) return;
    const state = &self.grid.tabline_state;

    if (state.visible and state.tabs.items.len > 0) {
        self.log.write("[tabline] notify: curtab={d} tabs={d} visible={any}\n", .{ state.current_tab, state.tabs.items.len, state.visible });

        // Build C-compatible tab array
        var c_tabs: std.ArrayListUnmanaged(c_api.TabEntry) = .empty;
        defer c_tabs.deinit(self.alloc);
        c_tabs.ensureTotalCapacity(self.alloc, state.tabs.items.len) catch return;

        for (state.tabs.items) |tab| {
            c_tabs.appendAssumeCapacity(.{
                .tab_handle = tab.tab_handle,
                .name = tab.name.ptr,
                .name_len = tab.name.len,
            });
        }

        // Build C-compatible buffer array
        var c_buffers: std.ArrayListUnmanaged(c_api.BufferEntry) = .empty;
        defer c_buffers.deinit(self.alloc);
        c_buffers.ensureTotalCapacity(self.alloc, state.buffers.items.len) catch return;

        for (state.buffers.items) |buf| {
            c_buffers.appendAssumeCapacity(.{
                .buffer_handle = buf.buffer_handle,
                .name = buf.name.ptr,
                .name_len = buf.name.len,
            });
        }

        if (self.cb.on_tabline_update) |cb| {
            cb(
                self.ctx,
                state.current_tab,
                c_tabs.items.ptr,
                c_tabs.items.len,
                state.current_buffer,
                c_buffers.items.ptr,
                c_buffers.items.len,
            );
        }
    } else {
        self.log.write("[tabline] notify: hide (visible={any} tabs={d})\n", .{ state.visible, state.tabs.items.len });
        if (self.cb.on_tabline_hide) |cb| {
            cb(self.ctx);
        }
    }
    self.grid.clearTablineDirty();
}

/// Show popupmenu as external window by creating a grid.
/// Grid content is rendered from the structured Neovim data (word, kind, menu).
/// The on_popupmenu_show callback delivers resolved Pmenu/PmenuSel colors so
/// the frontend can style the container background without inspecting vertices.
pub fn sendPopupmenuShow(self: *Core) bool {
    const pum_grid_id = grid_mod.POPUPMENU_GRID_ID;
    const items = self.grid.popupmenu.items.items;
    const selected = self.grid.popupmenu.selected;
    const anchor_row = self.grid.popupmenu.row;
    const anchor_col = self.grid.popupmenu.col;
    const anchor_grid = self.grid.popupmenu.grid_id;

    // Nothing to show: legitimate no-op, not a failure -- report success so
    // the caller clears popupmenu.changed instead of retrying indefinitely.
    if (items.len == 0) return true;

    self.log.write("[popupmenu] show: anchor_grid={d} anchor_row={d} anchor_col={d} items={d}\n", .{ anchor_grid, anchor_row, anchor_col, items.len });

    // Resolve highlight IDs for Pmenu / PmenuSel from the highlight group
    // table sent by Neovim via hl_group_set. Fall back to 0 (default attr)
    // if the group is not yet defined, in which case the popupmenu will
    // render with default colors.
    const pmenu_hl_id: u32 = self.hl.groups.get("Pmenu") orelse 0;
    const pmenu_sel_hl_id: u32 = self.hl.groups.get("PmenuSel") orelse pmenu_hl_id;

    // Resolve RGBA colors and notify the frontend via callback so it can
    // set the container background directly (no vertex color guessing).
    const pmenu_attr = self.hl.getWithStyles(pmenu_hl_id);
    const pmenu_sel_attr = self.hl.getWithStyles(pmenu_sel_hl_id);
    const colors = c_api.PopupmenuColors{
        .pmenu_bg = pmenu_attr.bg,
        .pmenu_fg = pmenu_attr.fg,
        .pmenu_sel_bg = pmenu_sel_attr.bg,
        .pmenu_sel_fg = pmenu_sel_attr.fg,
    };
    if (self.cb.on_popupmenu_show) |cb| {
        // items pointer is null: grid rendering handles display content.
        // item_count is 0 to match the null items contract.
        // The callback primarily delivers colors and anchor info.
        cb(self.ctx, null, 0, selected, anchor_row, anchor_col, anchor_grid, &colors);
    }

    // Calculate column widths: | pad | word | gap | kind | gap | menu | pad |
    var max_word_w: u32 = 0;
    var max_kind_w: u32 = 0;
    var max_menu_w: u32 = 0;
    for (items) |item| {
        const ww = countDisplayWidth(item.word);
        const kw = countDisplayWidth(item.kind);
        const mw = countDisplayWidth(item.menu);
        if (ww > max_word_w) max_word_w = ww;
        if (kw > max_kind_w) max_kind_w = kw;
        if (mw > max_menu_w) max_menu_w = mw;
    }
    if (max_word_w < 10) max_word_w = 10; // minimum word column

    // Total width: 1(pad) + word + gap? + kind? + gap? + menu? + 1(pad)
    var width: u32 = 1 + max_word_w + 1; // left pad + word + right pad
    if (max_kind_w > 0) width += 1 + max_kind_w; // gap + kind
    if (max_menu_w > 0) width += 1 + max_menu_w; // gap + menu

    // Limit height to reasonable number
    const max_height: u32 = 15;
    const height: u32 = @intCast(@min(items.len, max_height));

    // Calculate scroll offset to keep selected item visible
    const selected_u: usize = if (selected >= 0) @intCast(selected) else 0;
    var scroll_offset: usize = 0;
    if (selected_u >= height) {
        scroll_offset = selected_u - height + 1;
    }
    const display_start = scroll_offset;
    const display_end = @min(scroll_offset + height, items.len);

    // Create or resize popupmenu grid
    self.grid.resizeGrid(pum_grid_id, height, width) catch |e| {
        self.log.write("[popupmenu] resizeGrid failed: {any}\n", .{e});
        return false;
    };
    self.grid.clearGrid(pum_grid_id);

    // Write items to grid (with scroll offset)
    for (items[display_start..display_end], 0..) |item, row_idx| {
        const row: u32 = @intCast(row_idx);
        const item_idx = display_start + row_idx;
        const is_selected = (selected >= 0) and (item_idx == selected_u);
        const hl_id: u32 = if (is_selected) pmenu_sel_hl_id else pmenu_hl_id;

        // Fill entire row with spaces so bg covers all cells including padding
        {
            var fill_col: u32 = 0;
            while (fill_col < width) : (fill_col += 1) {
                self.grid.putCellGrid(pum_grid_id, row, fill_col, ' ', hl_id);
            }
        }

        // Column layout: | 1 pad | word (max_word_w) | 1 gap | kind (max_kind_w) | 1 gap | menu (max_menu_w) | 1 pad |
        var col: u32 = 1; // left padding
        col = writeUtf8ToGrid(self, pum_grid_id, row, col, item.word, width - 1, hl_id) catch |e| {
            abortClusterUpdate(self, "popupmenu", e);
            return false;
        };

        if (max_kind_w > 0) {
            col = 1 + max_word_w + 1; // jump to kind column start
            col = writeUtf8ToGrid(self, pum_grid_id, row, col, item.kind, col + max_kind_w, hl_id) catch |e| {
                abortClusterUpdate(self, "popupmenu", e);
                return false;
            };
        }

        if (max_menu_w > 0) {
            col = 1 + max_word_w + (if (max_kind_w > 0) 1 + max_kind_w else @as(u32, 0)) + 1; // jump to menu column start
            _ = writeUtf8ToGrid(self, pum_grid_id, row, col, item.menu, col + max_menu_w, hl_id) catch |e| {
                abortClusterUpdate(self, "popupmenu", e);
                return false;
            };
        }
    }

    // Register as external grid with position.
    // anchor_row/col are local to anchor_grid. Convert to global (grid 1)
    // coordinates using win_pos so the frontend can position the popup
    // relative to the terminal view without knowing about sub-grid offsets.
    const is_cmdline_completion = (anchor_grid < 0 or anchor_grid == -1);
    var start_row: i32 = undefined;
    var start_col: i32 = undefined;
    if (is_cmdline_completion) {
        start_row = -1;
        start_col = anchor_col;
    } else if (anchor_grid != 1) {
        if (self.grid.win_pos.get(anchor_grid)) |pos| {
            start_row = anchor_row +| grid_mod.saturatingI32FromU32(pos.row);
            start_col = anchor_col +| grid_mod.saturatingI32FromU32(pos.col);
        } else {
            start_row = anchor_row;
            start_col = anchor_col;
        }
    } else {
        start_row = anchor_row;
        start_col = anchor_col;
    }

    self.grid.putSyntheticExternal(pum_grid_id, .{
        .win = anchor_grid,
        .start_row = start_row,
        .start_col = start_col,
    }) catch |e| {
        self.log.write("[popupmenu] external_grids.put failed: {any}\n", .{e});
        return false;
    };

    return true;
}

/// Write a UTF-8 string to grid cells starting at (row, start_col).
/// Uses scanEmojiCluster to handle grapheme clusters (including NFD
/// combining characters like U+306F U+3099 = ば) as single display units.
/// NFD combining kana voicing marks are composed to NFC so the rasterizer
/// receives a single precomposed codepoint (e.g., U+3070 ば, not U+306F は).
/// Returns the column after the last written cell.
fn writeUtf8ToGrid(self: *Core, grid_id: i32, row: u32, start_col: u32, text: []const u8, col_limit: u32, hl_id: u32) !u32 {
    if (text.len == 0) return start_col;
    var col = start_col;
    var byte_i: usize = 0;
    while (byte_i < text.len) {
        const cluster = scanEmojiCluster(text, byte_i);
        if (cluster.codepoint_count == 0) break;
        const dw = cluster.display_width;
        // Ensure room for the full cluster width (body + placeholders)
        if (col + dw > col_limit) break;

        // Try NFC composition for NFD combining marks so the rasterizer
        // gets a single precomposed codepoint.
        const cp = if (cluster.extras_len > 0)
            composeNFC(cluster.first_cp, cluster.extras[0..cluster.extras_len])
        else
            cluster.first_cp;

        // If NFC composition consumed the extras (cp != base), no overflow
        // is needed. Otherwise publish the complete cluster transactionally.
        try self.grid.putCellGridCluster(
            grid_id,
            row,
            col,
            cp,
            hl_id,
            if (cp == cluster.first_cp) cluster.extras[0..cluster.extras_len] else &.{},
        );

        col += 1;
        // Fill remaining cells with placeholder (cp=0) for wide characters
        var p: u32 = 1;
        while (p < dw) : (p += 1) {
            self.grid.putCellGrid(grid_id, row, col, 0, hl_id);
            col += 1;
        }
        byte_i = cluster.end_byte;
    }
    return col;
}

/// Try to compose a base codepoint with combining marks into a single
/// NFC precomposed codepoint. Returns the composed codepoint if a known
/// composition exists, otherwise returns the base codepoint unchanged.
/// Currently handles:
///   - Hiragana/Katakana + U+3099 (voiced) / U+309A (semi-voiced)
///   - Latin base + U+0300-U+036F (common combining diacritical marks)
fn composeNFC(base: u32, extras: []const u32) u32 {
    if (extras.len == 0) return base;
    const mark = extras[0];

    // Hiragana voiced (゙ U+3099): か→が, き→ぎ, ... (gaps at certain positions)
    // Katakana voiced: カ→ガ, キ→ギ, ...
    if (mark == 0x3099) {
        return composeKanaVoiced(base) orelse base;
    }
    // Hiragana/Katakana semi-voiced (゚ U+309A): は→ぱ, ひ→ぴ, ...
    if (mark == 0x309A) {
        return composeKanaSemiVoiced(base) orelse base;
    }

    return base;
}

/// Compose Hiragana/Katakana base + U+3099 (dakuten) → precomposed voiced form.
fn composeKanaVoiced(base: u32) ?u32 {
    // Hiragana: U+304B(か)→U+304C(が) ... pairs at known offsets
    // The pattern: base + 1 = voiced, but only for specific ranges with gaps.
    return switch (base) {
        // Hiragana
        0x304B,
        0x304D,
        0x304F,
        0x3051,
        0x3053, // ka ki ku ke ko
        0x3055,
        0x3057,
        0x3059,
        0x305B,
        0x305D, // sa si su se so
        0x305F,
        0x3061,
        0x3064,
        0x3066,
        0x3068, // ta ti tu te to
        0x306F,
        0x3072,
        0x3075,
        0x3078,
        0x307B, // ha hi hu he ho
        // Katakana
        0x30AB,
        0x30AD,
        0x30AF,
        0x30B1,
        0x30B3, // ka ki ku ke ko
        0x30B5,
        0x30B7,
        0x30B9,
        0x30BB,
        0x30BD, // sa si su se so
        0x30BF,
        0x30C1,
        0x30C4,
        0x30C6,
        0x30C8, // ta ti tu te to
        0x30CF,
        0x30D2,
        0x30D5,
        0x30D8,
        0x30DB, // ha hi hu he ho
        => base + 1,
        0x3046 => 0x3094, // Hiragana u → vu
        0x30A6 => 0x30F4, // Katakana u → vu
        0x30EF => 0x30F7, // Katakana wa → va
        0x30F0 => 0x30F8, // Katakana wi → vi
        0x30F1 => 0x30F9, // Katakana we → ve
        0x30F2 => 0x30FA, // Katakana wo → vo
        else => null,
    };
}

/// Compose Hiragana/Katakana base + U+309A (handakuten) → precomposed semi-voiced form.
fn composeKanaSemiVoiced(base: u32) ?u32 {
    // は→ぱ = base + 2 for ha-row only
    return switch (base) {
        // Hiragana ha-row
        0x306F,
        0x3072,
        0x3075,
        0x3078,
        0x307B,
        // Katakana ha-row
        0x30CF,
        0x30D2,
        0x30D5,
        0x30D8,
        0x30DB,
        => base + 2,
        else => null,
    };
}

/// Hide popupmenu by removing from external grids.
pub fn sendPopupmenuHide(self: *Core) void {
    const pum_grid_id = grid_mod.POPUPMENU_GRID_ID;

    if (self.cb.on_popupmenu_hide) |cb| {
        cb(self.ctx);
    }

    // Remove from external grids.
    // Note: Don't call on_external_window_close here - it will be called by
    // notifyExternalWindowChanges() which detects the grid was removed from
    // external_grids but still exists in known_external_grids.
    _ = self.grid.removeSyntheticExternal(pum_grid_id) catch |err| {
        if (Core.isHardRenderFailure(err)) self.failHardRender(err);
        return;
    };

    self.log.write("[popupmenu] hide\n", .{});
}

// --- ext_messages support ---

fn scheduleMsgRetryDeadline(self: *Core, now: i128) i128 {
    const retry_delay = self.msg_show_retry_delay_ns;
    self.msg_show_retry_delay_ns = @min(retry_delay * 2, 1000 * std.time.ns_per_ms);
    self.log.write("[msg] timer retry scheduled in {d}ms\n", .{@divTrunc(retry_delay, std.time.ns_per_ms)});
    return now + retry_delay;
}

fn scheduleMsgHistoryRetryDeadline(self: *Core, now: i128) i128 {
    const retry_delay = self.msg_history_retry_delay_ns;
    self.msg_history_retry_delay_ns = @min(retry_delay * 2, 1000 * std.time.ns_per_ms);
    self.log.write("[msg_history] retry scheduled in {d}ms\n", .{@divTrunc(retry_delay, std.time.ns_per_ms)});
    return now + retry_delay;
}

/// Check if msg_show throttle timeout has expired and process pending messages.
/// Called from onFlush; the frontend timer drives an otherwise-empty onFlush when
/// Neovim is idle. The deadline still accumulates msg_show events across redraw
/// batches (e.g. list_cmd then shell_out for "!ls") before this check can fire.
pub fn checkMsgShowThrottleTimeout(self: *Core) void {
    if (!self.ext_messages_enabled) return;

    const pending_since = self.msg_show_pending_since orelse return;
    const now = clock.nowNs();
    if (self.msg_show_retry_at) |retry_at| {
        if (now < retry_at) return;
    }
    const elapsed = now - pending_since;

    if (elapsed >= self.msg_show_throttle_ns) {
        self.log.write("[msg] throttle timeout: {d}ms elapsed >= {d}ms, processing\n", .{
            @divTrunc(elapsed, std.time.ns_per_ms),
            @divTrunc(self.msg_show_throttle_ns, std.time.ns_per_ms),
        });
        if (sendMsgShow(self)) {
            self.grid.message_state.pending_count = 0;
            self.grid.message_state.msg_dirty = false;
            // This batch has been displayed, so its "a msg_clear arrived"
            // marker is spent. Its only other consumer sits inside
            // notifyMessageChanges' `if (msg_dirty)` block, which the line
            // above just made unreachable — leaving the flag set to fire a
            // spurious on_msg_clear on some later, unrelated batch. That
            // path has no confirm_msg.active guard, so the stale clear can
            // tear down a prompt window Neovim is still waiting on.
            self.grid.message_state.msg_cleared_in_batch = false;
            self.msg_show_pending_since = null;
            self.msg_show_retry_at = null;
            self.msg_show_retry_delay_ns = 16 * std.time.ns_per_ms;
        } else {
            self.msg_show_retry_at = scheduleMsgRetryDeadline(self, now);
        }
    }
}

/// Check if auto-hide timeout has expired for msg_show/msg_history grids.
/// Called from frontend tick (same as throttle timeout).
/// IMPORTANT: Caller must hold grid_mu (via c_api tick entry point).
pub fn checkMsgAutoHideTimeout(self: *Core) void {
    if (!self.ext_messages_enabled) return;
    const now = clock.nowNs();
    var hid_message = false;

    // msg_show (grid -102) auto-hide
    if (self.msg_show_auto_hide_at) |hide_at| {
        if (now >= hide_at) {
            hid_message = true;
            self.log.write("[msg] auto-hide: msg_show timeout expired\n", .{});
            self.grid.message_state.clearMessages(self.grid.alloc);
            hideChannelView(self, .show, .ext_float);
            // Remove from known_external_grids and notify close only if it was tracked.
            // This prevents spurious close notifications for grids that were never
            // registered or already closed.
            if (self.known_external_grids.remove(grid_mod.MESSAGE_GRID_ID)) {
                if (self.cb.on_external_window_close) |cb| {
                    cb(self.ctx, grid_mod.MESSAGE_GRID_ID);
                }
            }
            // Clear callback-based message windows (extFloatWindow etc),
            // but preserve promptWindow if confirm is active
            if (!self.grid.message_state.confirm_msg.active) {
                if (self.cb.on_msg_clear) |cb| {
                    cb(self.ctx);
                }
            }
        }
    }

    // msg_history (grid -103) auto-hide
    if (self.msg_history_auto_hide_at) |hide_at| {
        if (now >= hide_at) {
            hid_message = true;
            self.log.write("[msg] auto-hide: msg_history timeout expired\n", .{});
            hideChannelView(self, .history, .ext_float);
            self.grid.msg_history_state.clear(self.grid.alloc);
            // Same guard: only notify if it was actually tracked
            if (self.known_external_grids.remove(grid_mod.MSG_HISTORY_GRID_ID)) {
                if (self.cb.on_external_window_close) |cb| {
                    cb(self.ctx, grid_mod.MSG_HISTORY_GRID_ID);
                }
            }
        }
    }
    if (hid_message) self.msg_show_retry_delay_ns = 16 * std.time.ns_per_ms;
}

/// Earliest absolute deadline (nanos) among message UI and core rendering
/// maintenance work, or null if none is pending. The legacy public API name is
/// retained, but the frontend's same one-shot timer also drives atlas-negative
/// reprobes while Neovim is idle.
/// IMPORTANT: Caller must hold grid_mu.
pub fn nextMsgTimeoutNs(self: *Core) ?i128 {
    var earliest: ?i128 = null;
    const consider = struct {
        fn f(acc: *?i128, deadline: i128) void {
            if (acc.*) |cur| {
                if (deadline < cur) acc.* = deadline;
            } else {
                acc.* = deadline;
            }
        }
    }.f;

    if (self.ext_messages_enabled) {
        if (self.msg_show_pending_since) |since| {
            consider(&earliest, self.msg_show_retry_at orelse since + self.msg_show_throttle_ns);
        }
        if (self.msg_show_auto_hide_at) |hide_at| {
            consider(&earliest, hide_at);
        }
        if (self.msg_history_auto_hide_at) |hide_at| {
            consider(&earliest, hide_at);
        }
        if (self.msg_history_retry_at) |retry_at| {
            consider(&earliest, retry_at);
        }
    }
    if (self.atlas_negative_retry_at) |retry_at| {
        consider(&earliest, retry_at);
    }
    if (self.transient_glyph_retry_at) |retry_at| {
        consider(&earliest, retry_at);
    }
    return earliest;
}

/// Handle message changes - notify frontend via callbacks.
/// Uses throttle for msg_show (like noice.nvim) to accumulate messages before deciding view.
pub fn notifyMessageChanges(self: *Core) void {
    if (!self.ext_messages_enabled) return;

    const msg_dirty = self.grid.message_state.msg_dirty;
    const confirm_dirty = self.grid.message_state.confirm_dirty;
    const status_dirty = self.grid.message_state.status_dirty;
    const history_dirty = self.grid.msg_history_state.dirty;

    // Also check if there's a pending throttle timeout to handle
    const has_pending_throttle = self.msg_show_pending_since != null;

    var any_status_dirty = false;
    for (status_dirty) |d| {
        if (d) any_status_dirty = true;
    }

    if (!msg_dirty and !confirm_dirty and !any_status_dirty and !history_dirty and !has_pending_throttle) return;

    // Guard: at most one on_msg_clear per flush cycle
    var sent_msg_clear = false;
    var msg_retry_needed = false;

    // Handle confirm message changes (noice.nvim pattern: separate from regular messages)
    if (confirm_dirty) {
        if (self.grid.message_state.confirm_msg.active) {
            sendConfirmCallback(self);
        } else {
            // Confirm dismissed -> notify frontend to hide prompt window
            self.log.write("[msg] confirm dismissed -> on_msg_clear\n", .{});
            if (self.cb.on_msg_clear) |cb| {
                cb(self.ctx);
            }
            sent_msg_clear = true;
        }
    }

    // Handle msg_show/msg_clear changes
    // Use throttle only for external command output (list_cmd, shell_out, shell_err)
    // to accumulate messages before deciding split view vs message window.
    // When return_prompt arrives, we must act immediately (like noice.nvim).
    if (msg_dirty) {
        const cleared_in_batch = self.grid.message_state.msg_cleared_in_batch;
        self.grid.message_state.msg_cleared_in_batch = false;

        // If msg_clear was received in this batch, notify frontend to clear old state
        // BEFORE processing new messages. This handles msg_clear -> msg_show same-batch.
        if (cleared_in_batch and !sent_msg_clear) {
            hideChannelView(self, .show, .ext_float);
            self.msg_show_pending_since = null;
            if (self.cb.on_msg_clear) |cb| {
                cb(self.ctx);
            }
            sent_msg_clear = true;
        }

        const messages = self.grid.message_state.messages.items;
        if (messages.len == 0) {
            if (!cleared_in_batch) {
                // Pure empty (not from same-batch clear which was already handled above)
                hideChannelView(self, .show, .ext_float);
                self.msg_show_pending_since = null;
                if (!sent_msg_clear) {
                    if (self.cb.on_msg_clear) |cb| {
                        cb(self.ctx);
                    }
                    sent_msg_clear = true;
                }
            }
        } else {
            // Check message types
            var has_shell_cmd = false;
            var has_return_prompt = false;
            for (messages) |m| {
                // Only shell commands need throttle to accumulate output
                // list_cmd (:ls, :version, etc.) should display immediately
                if (std.mem.eql(u8, m.kind, "shell_out") or
                    std.mem.eql(u8, m.kind, "shell_err"))
                {
                    has_shell_cmd = true;
                }
                if (std.mem.eql(u8, m.kind, "return_prompt")) {
                    has_return_prompt = true;
                }
            }

            // Each event is processed independently.
            // auto_dismiss (CR sending) is handled inside sendMsgShow based on view type.
            if (has_shell_cmd and !has_return_prompt) {
                // Shell command without return_prompt yet: use throttle to accumulate output
                if (self.msg_show_pending_since == null) {
                    self.msg_show_pending_since = clock.nowNs();
                    self.msg_show_retry_at = null;
                    self.msg_show_retry_delay_ns = 16 * std.time.ns_per_ms;
                }
            } else {
                // Other messages (including list_cmd): display immediately,
                // unless a previous failure asked us to wait. A deadline is
                // only meaningful if something honours it: this branch used
                // to write the backoff and re-attempt on the very next flush
                // regardless, so a permanently-failing dispatch retried at
                // the flush rate while the delay it inflated was read by
                // nobody.
                const now = clock.nowNs();
                const retry_due = if (self.msg_show_retry_at) |at| now >= at else true;
                if (!retry_due) {
                    msg_retry_needed = true;
                } else if (sendMsgShow(self)) {
                    self.msg_show_pending_since = null;
                    self.msg_show_retry_at = null;
                    self.msg_show_retry_delay_ns = 16 * std.time.ns_per_ms;
                } else {
                    // Keeping msg_dirty set is not enough on its own: without
                    // a deadline, nextMsgTimeoutNs returns null and the
                    // frontend arms no timer, so the retry this failure asks
                    // for only happens if some unrelated event triggers
                    // another flush — and a prompt-blocked Neovim emits no
                    // further redraw at all. Both fields are needed: every
                    // reader of msg_show_retry_at is gated on
                    // msg_show_pending_since, so the deadline alone arms
                    // nothing.
                    msg_retry_needed = true;
                    if (self.msg_show_pending_since == null) {
                        self.msg_show_pending_since = now;
                    }
                    self.msg_show_retry_at = scheduleMsgRetryDeadline(self, now);
                }
            }
        }
    }

    self.grid.message_state.msg_dirty = msg_retry_needed;
    self.grid.message_state.confirm_dirty = false;
    self.grid.message_state.status_dirty = @splat(false);

    // Handle showmode/showcmd/ruler changes only when their respective dirty flag is set
    for (grid_mod.StatusChannel.all) |channel| {
        if (status_dirty[channel.index()]) sendMsgStatus(self, channel);
    }

    // Handle msg_history_show
    if (history_dirty) {
        const now = clock.nowNs();
        if (self.msg_history_retry_at == null or now >= self.msg_history_retry_at.?) {
            if (sendMsgHistoryShow(self)) {
                self.grid.clearMsgHistoryDirty();
                self.msg_history_retry_at = null;
                self.msg_history_retry_delay_ns = 16 * std.time.ns_per_ms;
            } else {
                // Scheduled even when the failure aborted the flush: that is
                // exactly the case with no other retry driver, and skipping
                // it left history_dirty set with nothing to act on it.
                self.msg_history_retry_at = scheduleMsgHistoryRetryDeadline(self, now);
            }
        }
    }
}

/// Answer pending press-enter prompts with `<CR>` and remove them — BEFORE
/// any dispatch step that can fail, so a retried flush cannot answer one
/// twice. (noice answers at the event layer too: ui/init.lua:122-126.)
///
/// Returns how many prompts left the array, or null when one is still
/// unanswered for a reason a retry can resolve — the caller must then abort.
///
/// A prompt leaves the array only once its `<CR>` is resolved, and the two
/// send-failure classes resolve differently:
///   * `OutOfMemory` — the allocator, or a full write queue. Transient: keep
///     the prompt, stop answering the rest of the batch, and let the caller
///     retry. Rendering stalls until it clears, which is bounded.
///   * anything else — `BrokenPipe`, i.e. the writer is gone. Permanent: no
///     retry can ever deliver the `<CR>`, and aborting every flush over it
///     would freeze the render pipeline on its last frame forever.
///
/// Defensive in practice: probing nine command surfaces under Neovim 0.12
/// with `ext_messages` attached produced no return_prompt at all, so this
/// path is currently unreachable. Kept because the guarantee should not
/// depend on that observation holding.
fn answerReturnPrompts(self: *Core) ?usize {
    const messages = &self.grid.message_state.messages;
    var consumed: usize = 0;
    var write_idx: usize = 0;
    var retry = false;
    for (0..messages.items.len) |read_idx| {
        const m = &messages.items[read_idx];
        if (!retry and config.isReturnPrompt(m.kind)) {
            if (self.requestInput("<CR>")) |_| {
                self.log.write("[msg] return_prompt: answered with <CR>\n", .{});
                consumed += 1;
                m.deinit(self.alloc);
                continue;
            } else |err| {
                if (err == error.OutOfMemory) {
                    self.log.write("[msg] return_prompt: send queue full or out of memory; keeping for retry\n", .{});
                    retry = true;
                } else {
                    self.log.write("[msg] return_prompt: transport is gone ({s}); dropping unanswered\n", .{@errorName(err)});
                    consumed += 1;
                    m.deinit(self.alloc);
                    continue;
                }
            }
        }
        if (write_idx != read_idx) messages.items[write_idx] = messages.items[read_idx];
        write_idx += 1;
    }
    messages.items.len = write_idx;
    return if (retry) null else consumed;
}

/// Send msg_show as external grid (like popupmenu pattern).
/// Confirm dialogs are sent via callback (special case for cmdline mode).
pub fn sendMsgShow(self: *Core) bool {
    // Prompts first: answered and gone before anything below can abort the
    // flush, so a retry cannot answer them twice. A side effect worth naming:
    // prompt text no longer inflates total_line_count, so height-filtered
    // routes see only real content.
    const consumed_prompts = answerReturnPrompts(self) orelse {
        // null means a prompt is still unanswered for a reason a retry can
        // resolve.
        self.flush_aborted = true;
        return false;
    };

    const messages = self.grid.message_state.messages.items;

    // Route once. Every later consumer reads this assignment instead of
    // routing again, which is what keeps them from disagreeing: the line-cache
    // pass used to re-route with a line count of 1 and could therefore drop a
    // message the main pass had assigned to ext_float. Cleared before the empty
    // check too, so an empty cycle cannot leave a stale assignment behind.
    const views = &self.msg_views;
    views.beginCycle(self.alloc, messages.len) catch {
        self.log.write("[msg] sendMsgShow: view assignment alloc failed; retrying\n", .{});
        self.flush_aborted = true;
        return false;
    };

    if (messages.len == 0) {
        if (consumed_prompts > 0) {
            // The batch held only prompts: nothing to display and nothing
            // newly cleared, so no on_msg_clear — but the empty dispatch
            // still hides a visible core-owned view. This preserves the
            // pre-removal behavior for prompt-only batches.
            return dispatchChannel(self, .show, .{ .show = messages });
        }
        // Full state reset (scroll, cache, grid -102) then explicit on_msg_clear
        hideChannelView(self, .show, .ext_float);
        self.log.write("[msg] sendMsgShow: hide (empty)\n", .{});
        if (self.cb.on_msg_clear) |cb| {
            cb(self.ctx);
        }
        return true;
    }

    // Count total lines across all messages (for min_lines/max_lines routing)
    var total_line_count: u32 = 0;
    for (messages) |m| {
        total_line_count += 1;
        for (m.content.items) |chunk| {
            for (chunk.text) |ch| {
                if (ch == '\n') total_line_count += 1;
            }
        }
    }

    for (messages, 0..) |msg, i| {
        // return_prompt never reaches this loop — answerReturnPrompts removed
        // it above — so every remaining message routes normally.
        const route_result = self.msg_config.routeMessage(.msg_show, msg.kind, total_line_count);
        views.assign(i, route_result.view, route_result.timeout, route_result.enter);

        self.log.write("[msg] sendMsgShow: kind={s} lines={d} routed to view={s} timeout={d:.1}\n", .{
            msg.kind,
            total_line_count,
            @tagName(route_result.view),
            route_result.timeout,
        });
    }

    // noice `View:display()` (view/init.lua:156-180): a view holding messages
    // is shown, an empty one that the core still owns is hidden.
    if (!dispatchChannel(self, .show, .{ .show = messages })) return false;

    // Drop the messages whose display has been handed off, so they do not pile
    // up across cycles. ext_float-routed messages stay because the grid is
    // re-rendered from the array every cycle; everything else has an owner
    // elsewhere (frontend timer, OS, Neovim) or was never shown.
    dropTransientMessages(self);
    return true;
}

/// A message channel: an event source with its own ViewSet, external grid,
/// and auto-hide slot. The two channels share every backend below — the only
/// per-channel differences are which grid ext_float renders into and whether
/// the split takes focus.
pub const MsgChannel = enum {
    /// msg_show — grid -102, msg_show_auto_hide_at.
    show,
    /// msg_history_show — grid -103, msg_history_auto_hide_at.
    history,
};

/// Content a channel dispatches this cycle, parallel to its ViewSet
/// assignment (`messages` per-index; `history` is routed as one unit at
/// index 0).
const ChannelContent = union(MsgChannel) {
    show: []const grid_mod.Message,
    history: []const grid_mod.MsgHistoryEntry,
};

fn channelViews(self: *Core, ch: MsgChannel) *msg_view.ViewSet {
    return switch (ch) {
        .show => &self.msg_views,
        .history => &self.history_views,
    };
}

fn channelAutoHideSlot(self: *Core, ch: MsgChannel) *?i128 {
    return switch (ch) {
        .show => &self.msg_show_auto_hide_at,
        .history => &self.msg_history_auto_hide_at,
    };
}

fn channelAutoHideNsSlot(self: *Core, ch: MsgChannel) *?i128 {
    return switch (ch) {
        .show => &self.msg_show_auto_hide_ns,
        .history => &self.msg_history_auto_hide_ns,
    };
}

fn channelHoverSlot(self: *Core, ch: MsgChannel) *bool {
    return switch (ch) {
        .show => &self.msg_show_hovered,
        .history => &self.msg_history_hovered,
    };
}

/// Run one display cycle for a channel: show every view holding content,
/// hide every empty view the core still owns. Returns false when the flush
/// must be retried.
fn dispatchChannel(self: *Core, ch: MsgChannel, content: ChannelContent) bool {
    const views = channelViews(self, ch);
    for (msg_view.ViewSet.dispatch_order) |view| {
        switch (views.action(view)) {
            .none => {},
            .hide => hideChannelView(self, ch, view),
            .show => {
                if (!showChannelView(self, ch, view, content)) return false;
                views.markShown(view);
            },
        }
    }
    return true;
}

/// Backend dispatch, shared by both channels. Returns false only when the
/// flush must be retried.
fn showChannelView(self: *Core, ch: MsgChannel, view: config.MsgViewType, content: ChannelContent) bool {
    const views = channelViews(self, ch);
    const state = views.state(view);
    self.log.write("[msg] channel={s} view={s}: show ({d} item(s), timeout={d:.1})\n", .{
        @tagName(ch), @tagName(view), state.count, state.timeout,
    });

    switch (view) {
        .none => {},
        // Frontend-rendered views.
        .mini, .confirm, .notification => switch (content) {
            // One callback per assigned message.
            .show => |messages| for (messages, 0..) |msg, i| {
                if (views.assignedTo(i) != view) continue;
                sendMsgShowCallback(self, msg, msg.content.items, view, state.timeout);
            },
            // History is routed as one unit; the callback combines entries.
            .history => |entries| sendMsgHistoryCallbackAll(self, entries, view),
        },
        // Core-rendered view: the channel's external grid.
        .ext_float => {
            switch (content) {
                .show => {
                    if (!buildMsgLineCache(self)) {
                        self.log.write("[msg] buildMsgLineCache failed; preserving previous cache for retry\n", .{});
                        self.flush_aborted = true;
                        return false;
                    }
                    self.msg_scroll_offset = 0;
                    if (!renderMsgGridFromCache(self, 0)) {
                        self.flush_aborted = true;
                        return false;
                    }
                },
                .history => |entries| {
                    if (!renderMsgHistoryGrid(self, entries)) return false;
                },
            }
            // timeout=0 means no auto-hide, e.g. errors.
            const timeout_ns = messageTimeoutNs(state.timeout);
            channelAutoHideNsSlot(self, ch).* = timeout_ns;
            // A message can land on a float the pointer is already resting on.
            // Arming it there would hide the view mid-read; the pointer leaving
            // starts the countdown instead.
            channelAutoHideSlot(self, ch).* = if (timeout_ns) |ns|
                (if (channelHoverSlot(self, ch).*) null else clock.nowNs() + ns)
            else
                null;
        },
        // Neovim-rendered view: content is sent back over RPC as Lua.
        .split => {
            // The buffer is a persistent Core field reused across calls, so a
            // large `:history` dump costs at most one growth rather than the
            // silent truncation a fixed stack buffer used to impose. noice
            // never truncates message content either (view/init.lua:212-223);
            // the window is bounded, not the content.
            //
            // Nothing here touches the frontend until the content is safely
            // handed to Neovim: both the assembly and the RPC send run before
            // on_msg_clear, so any failure aborts the flush for retry exactly
            // like the ext_float arm above — messages kept, frontend untouched
            // — instead of showing content with a hole in it (the old
            // `catch break`) or clearing the UI with nothing to replace it.
            const buf = &self.msg_split_buf;
            buf.clearRetainingCapacity();
            var line_count: u32 = 0;
            const ok = switch (content) {
                .show => blk: for (content.show, 0..) |m, i| {
                    if (views.assignedTo(i) != .split) continue;
                    for (m.content.items) |chunk| {
                        buf.appendSlice(self.alloc, chunk.text) catch break :blk false;
                        for (chunk.text) |ch_byte| {
                            if (ch_byte == '\n') line_count += 1;
                        }
                    }
                    buf.append(self.alloc, '\n') catch break :blk false;
                    line_count += 1;
                } else true,
                .history => blk: for (content.history) |entry| {
                    for (entry.content.items) |chunk| {
                        buf.appendSlice(self.alloc, chunk.text) catch break :blk false;
                    }
                    buf.append(self.alloc, '\n') catch break :blk false;
                    line_count += 1;
                } else true,
            };
            if (!ok) {
                self.log.write("[msg] split content assembly ran out of memory; retrying\n", .{});
                self.flush_aborted = true;
                return false;
            }

            // A payload the write queue can never accept is not a transient
            // failure: retrying re-assembles megabytes on every flush forever
            // and the send fails identically each time. Give up loudly and
            // let the messages be dropped, as they were before the dispatch
            // learned to retry. 1000 messages of up to 64 KiB each make this
            // reachable, not theoretical.
            // What the queue rejects is the ENCODED request, not this buffer:
            // the Lua program and the msgpack framing ride along, so comparing
            // the raw content against the cap leaves a window just under it
            // that still fails every time.
            const split_payload_budget = Core.MAX_WRITE_QUEUE_SIZE - Core.split_lua_buf_len;
            if (buf.items.len > split_payload_budget) {
                self.log.write("[msg] split content is {d} bytes, past the {d} the RPC write queue can carry; dropping\n", .{ buf.items.len, split_payload_budget });
                // The content is unrecoverable, but the frontend must not be
                // left drawing a window whose content this batch replaced:
                // every other exit from this arm either clears or aborts, and
                // silently keeping stale text on screen is worse than an
                // empty message area.
                if (self.cb.on_msg_clear) |cb| cb(self.ctx);
                return true;
            }

            // enter defaults per channel: routed messages must not steal the
            // cursor (noice's `split` view is `enter = false`,
            // config/views.lua:75), while `:messages` is content the user
            // asked to read, so it takes focus (:91-94). A route's `enter`
            // overrides the default in either direction.
            self.createMessageSplit(
                buf.items,
                line_count,
                state.enter orelse (ch == .history),
                messageTimeoutMs(state.timeout),
            ) catch |e| {
                // Both channels fail the dispatch. Swallowing this for .show
                // returned success, so markShown ran and dropTransientMessages
                // then freed messages that were never handed to Neovim — the
                // same data loss the assembly transaction above prevents.
                self.log.write("[msg] createMessageSplit failed: {any}\n", .{e});
                return false;
            };

            // Only now that the content is on its way to Neovim: clearing the
            // frontend's pending prompt windows any earlier would empty the
            // message UI with nothing to replace it if the steps above failed.
            if (self.cb.on_msg_clear) |cb| cb(self.ctx);
        },
    }
    return true;
}

/// THE hide funnel for a channel's view: every path that stops displaying a
/// core-owned view — cycle dispatch, auto-hide timeout, msg_clear — goes
/// through here so grid, auto-hide slot, and the ViewSet's `visible` flag
/// can never disagree. Transient views were handed off on show (see
/// msg_view.retentionOf) and only have their flag cleared.
pub fn hideChannelView(self: *Core, ch: MsgChannel, view: config.MsgViewType) void {
    self.log.write("[msg] channel={s} view={s}: hide\n", .{ @tagName(ch), @tagName(view) });
    if (view == .ext_float) {
        switch (ch) {
            .show => hideMsgShow(self),
            .history => hideMsgHistory(self),
        }
        channelAutoHideSlot(self, ch).* = null;
        channelAutoHideNsSlot(self, ch).* = null;
        // The window can close under a stationary pointer, and AppKit/Win32
        // deliver no leave event for a window that is gone. Dropping the flag
        // here keeps a stale hover from suppressing the next view's countdown.
        channelHoverSlot(self, ch).* = false;
    }
    channelViews(self, ch).markHidden(view);
}

/// Stable, single-pass removal of messages whose display was handed off.
fn dropTransientMessages(self: *Core) void {
    const messages = &self.grid.message_state.messages;
    var write_idx: usize = 0;
    for (0..messages.items.len) |read_idx| {
        const m = &messages.items[read_idx];
        const view = self.msg_views.assignedTo(read_idx);
        const is_transient = msg_view.retentionOf(view) == .transient;
        if (is_transient) {
            m.deinit(self.alloc);
        } else {
            if (write_idx != read_idx) messages.items[write_idx] = messages.items[read_idx];
            write_idx += 1;
        }
    }
    messages.items.len = write_idx;
}

/// Build line cache from current messages (called once when messages change).
/// Only includes messages that route to ext_float view.
pub fn buildMsgLineCache(self: *Core) bool {
    const messages = self.grid.message_state.messages.items;
    const build = &self.msg_line_cache_build;

    // Build transactionally so OOM never publishes a truncated cache.
    build.clearRetainingCapacity();

    if (messages.len == 0) {
        std.mem.swap(std.ArrayListUnmanaged(MsgCachedLine), &self.msg_line_cache, build);
        build.clearRetainingCapacity();
        self.msg_total_lines = 0;
        self.msg_cached_max_width = 10;
        self.msg_cache_valid = true;
        return true;
    }

    var max_width: u32 = 10;

    for (messages, 0..) |m, i| {
        // Only include messages this cycle assigned to ext_float. Re-routing
        // here would disagree with the assignment: this pass used a line count
        // of 1 while sendMsgShow uses the total, so any height-filtered route
        // could send a message to the grid and then omit it from the cache.
        if (self.msg_views.assignedTo(i) != .ext_float) continue;
        // Process all chunks, splitting on newlines
        var current_line: MsgCachedLine = .{};

        for (m.content.items) |chunk| {
            var remaining = chunk.text;
            while (remaining.len > 0) {
                const nl_pos = std.mem.indexOfScalar(u8, remaining, '\n');

                if (nl_pos) |pos| {
                    // Copy text before newline, excluding trailing \r (CRLF → LF)
                    const effective_pos = if (pos > 0 and remaining[pos - 1] == '\r') pos - 1 else pos;
                    const copy_len = @min(effective_pos, current_line.data.len - current_line.len);
                    @memcpy(current_line.data[current_line.len..][0..copy_len], remaining[0..copy_len]);
                    current_line.len += @intCast(copy_len);

                    // Finish current line (skip leading empty lines)
                    if (current_line.len > 0 or build.items.len > 0) {
                        current_line.display_width = @intCast(countDisplayWidth(current_line.data[0..current_line.len]));
                        if (current_line.display_width > max_width) max_width = current_line.display_width;
                        build.append(self.alloc, current_line) catch return false;
                    }
                    current_line = .{};
                    remaining = remaining[pos + 1 ..];
                } else {
                    // No newline - copy rest to current line
                    const copy_len = @min(remaining.len, current_line.data.len - current_line.len);
                    @memcpy(current_line.data[current_line.len..][0..copy_len], remaining[0..copy_len]);
                    current_line.len += @intCast(copy_len);
                    break;
                }
            }
        }

        // Finish last line of this message
        if (current_line.len > 0 or build.items.len == 0) {
            current_line.display_width = @intCast(countDisplayWidth(current_line.data[0..current_line.len]));
            if (current_line.display_width > max_width) max_width = current_line.display_width;
            build.append(self.alloc, current_line) catch return false;
        }
    }

    std.mem.swap(std.ArrayListUnmanaged(MsgCachedLine), &self.msg_line_cache, build);
    build.clearRetainingCapacity();
    self.msg_total_lines = @intCast(self.msg_line_cache.items.len);
    self.msg_cached_max_width = max_width;
    self.msg_cache_valid = true;

    self.log.write("[msg] buildMsgLineCache: {d} lines cached, max_width={d}\n", .{
        self.msg_line_cache.items.len,
        max_width,
    });
    return true;
}

/// Render msg_show grid from cache (fast path for scrolling).
/// Returns false on allocation failure (resizeGrid/external_grids.put) —
/// the message grid was NOT actually updated to reflect scroll_offset, so
/// callers must not advance any "this offset was rendered" bookkeeping as
/// if it had been.
pub fn renderMsgGridFromCache(self: *Core, scroll_offset: u32) bool {
    const msg_grid_id = grid_mod.MESSAGE_GRID_ID;
    const lines = self.msg_line_cache.items;

    if (lines.len == 0) return true;

    // Apply scroll offset (clamp to valid range)
    const actual_scroll: usize = @min(scroll_offset, if (lines.len > 0) lines.len - 1 else 0);

    // Calculate grid dimensions
    const max_height: u32 = @min(self.grid.rows, 256);
    const visible_lines = lines.len - actual_scroll;
    const height: u32 = @intCast(@min(visible_lines, max_height));
    const width: u32 = @min(self.msg_cached_max_width + 2, 80);

    self.log.write("[msg] renderMsgGridFromCache: lines={d} scroll={d} visible={d} size={d}x{d}\n", .{
        lines.len,
        actual_scroll,
        visible_lines,
        width,
        height,
    });

    // Create or resize grid
    self.grid.resizeGrid(msg_grid_id, height, width) catch |e| {
        self.log.write("[msg] resizeGrid failed: {any}\n", .{e});
        return false;
    };
    self.grid.clearGrid(msg_grid_id);

    // Write lines to grid from cache
    for (0..height) |row_idx| {
        const source_line_idx = actual_scroll + row_idx;
        if (source_line_idx >= lines.len) break;

        const row: u32 = @intCast(row_idx);
        const cached_line = lines[source_line_idx];
        const line = cached_line.data[0..cached_line.len];

        var col: u32 = 1; // Start with 1 cell padding
        var iter = std.unicode.Utf8View.initUnchecked(line).iterator();
        while (iter.nextCodepoint()) |cp| {
            if (col >= width - 1) break;
            self.grid.putCellGrid(msg_grid_id, row, col, cp, 0);
            col += 1;
            if (isWideChar(cp)) {
                if (col >= width - 1) break;
                self.grid.putCellGrid(msg_grid_id, row, col, 0, 0);
                col += 1;
            }
        }
    }

    // Register as external grid
    self.grid.putSyntheticExternal(msg_grid_id, .{
        .win = 1, // Global grid
        .start_row = -2, // Special marker: position at top-right
        .start_col = -2,
    }) catch |e| {
        self.log.write("[msg] external_grids.put failed: {any}\n", .{e});
        return false;
    };
    return true;
}

/// Handle scroll event for msg_show grid (Zonvie's own grid).
/// Updates scroll offset and re-renders grid content.
/// Runs the message grid's local-scroll vertex send wrapped in the same
/// on_flush_begin/on_flush_end bracket as the normal onFlush() path.
///
/// handleMsgGridScroll/processPendingMsgScroll used to call
/// sendExternalGridVerticesFiltered directly, with no on_flush_begin/
/// on_flush_end around it. Both frontends' triple-buffer write-set open/
/// commit/InvalidateRect logic lives in those callbacks (Windows: TBS
/// commit + InvalidateRect, both gated on on_flush_end; macOS:
/// beginFlush()/commitFlush(), including the atlas front-buffer swap and
/// per-ExternalGridView atlas snapshot update). Without the bracket, the
/// scroll's vertex data was composed but never actually published on
/// Windows (no commit, no repaint), and on macOS a new glyph ensured along
/// the way could leave committed vertex UVs pointing at an atlas
/// generation the frontend never swapped to.
/// Returns true if the scroll was actually committed. False means the
/// caller must NOT clear msg_scroll_pending / advance msg_scroll_last_send
/// — the scroll still needs to be retried once a full flush has resent
/// everything (see the atlas-reset branch below).
fn runMsgGridScrollFlush(self: *Core, offset: u32) bool {
    const perf_enabled = self.log.cb != null;
    const perf_start_ns = if (perf_enabled) clock.nowNs() else 0;
    var committed = false;
    defer if (perf_enabled) {
        const elapsed_us_i128 = @divTrunc(@max(0, clock.nowNs() - perf_start_ns), 1000);
        const elapsed_us: u32 = @intCast(@min(elapsed_us_i128, std.math.maxInt(u32)));
        const sample_idx: usize = @intCast(self.msg_scroll_perf_count);
        self.msg_scroll_perf_us[sample_idx] = elapsed_us;
        self.msg_scroll_perf_count += 1;
        if (!committed) self.msg_scroll_perf_aborted += 1;

        if (self.msg_scroll_perf_count == self.msg_scroll_perf_us.len) {
            var sorted = self.msg_scroll_perf_us;
            std.sort.pdq(u32, &sorted, {}, comptime std.sort.asc(u32));
            const p50 = sorted[(sorted.len * 50 - 1) / 100];
            const p95 = sorted[(sorted.len * 95 - 1) / 100];
            const p99 = sorted[(sorted.len * 99 - 1) / 100];
            self.log.write(
                "[perf] msg_scroll_transaction samples={d} p50_us={d} p95_us={d} p99_us={d} max_us={d} aborted={d} surfaces={d} msg_cells={d}\n",
                .{ sorted.len, p50, p95, p99, sorted[sorted.len - 1], self.msg_scroll_perf_aborted, self.known_external_grids.count() + 1, self.grid.rows * self.grid.cols },
            );
            self.msg_scroll_perf_count = 0;
            self.msg_scroll_perf_aborted = 0;
        }
    };

    if (!renderMsgGridFromCache(self, offset)) {
        return false;
    }

    // Publish through the standard full-flush transaction. It resets the
    // atlas-corruption state and regenerates main plus all external consumers
    // before one frontend commit, so a cancelled bracket cannot consume dirty.
    var fctx = FlushCtx{ .core = self };
    FlushCtx.onFlush(&fctx, self.grid.rows, self.grid.cols) catch |reason| {
        if (Core.isHardRenderFailure(reason)) self.failHardRender(reason);
        return false;
    };
    committed = !self.flush_aborted and !self.flush_atlas_corrupted;
    return committed;
}

/// Cancel a channel's pending auto-hide without hiding anything. Used when
/// the user starts interacting with a view — a message being read must not
/// vanish mid-read. The next show cycle re-arms the timeout as usual.
pub fn pauseChannelAutoHide(self: *Core, ch: MsgChannel) void {
    if (channelAutoHideSlot(self, ch).* != null) {
        self.log.write("[msg] channel={s}: auto-hide paused (user interaction)\n", .{@tagName(ch)});
        channelAutoHideSlot(self, ch).* = null;
    }
}

/// Restart a paused countdown at full length. Unlike the scroll pause, hover
/// has a defined end, so the pointer leaving resumes the view rather than
/// waiting for the next show cycle. Only a view the core still shows, and whose
/// timeout was non-zero, is re-armed.
fn resumeChannelAutoHide(self: *Core, ch: MsgChannel) void {
    if (!channelViews(self, ch).state(.ext_float).visible) return;
    const slot = channelAutoHideSlot(self, ch);
    if (slot.* != null) return;
    const ns = channelAutoHideNsSlot(self, ch).* orelse return;
    slot.* = clock.nowNs() + ns;
    self.log.write("[msg] channel={s}: auto-hide resumed (hover ended)\n", .{@tagName(ch)});
}

/// Frontend hover state for a channel's ext_float window. Entering stops the
/// countdown, leaving restarts it at full length.
/// IMPORTANT: Caller must hold grid_mu (via the c_api entry point).
pub fn setChannelHover(self: *Core, ch: MsgChannel, hovered: bool) void {
    const slot = channelHoverSlot(self, ch);
    if (slot.* == hovered) return;
    slot.* = hovered;
    if (hovered) pauseChannelAutoHide(self, ch) else resumeChannelAutoHide(self, ch);
}

pub fn handleMsgGridScroll(self: *Core, direction: []const u8) void {
    // Check if message grid is active
    if (!self.grid.external_grids.contains(grid_mod.MESSAGE_GRID_ID)) {
        self.log.write("[msg] handleMsgGridScroll: grid not active\n", .{});
        return;
    }

    // Scrolling the float is the ext_float equivalent of moving the cursor
    // into a split: the user is reading. Stop the auto-hide countdown even
    // when the scroll hits a boundary and the offset does not change —
    // the interaction is the signal, not the movement.
    pauseChannelAutoHide(self, .show);

    const scroll_amount: u32 = 3; // Lines per scroll event
    var new_offset = self.msg_scroll_offset;

    if (std.mem.eql(u8, direction, "down")) {
        // Scroll down (show later content)
        const max_scroll = if (self.msg_total_lines > self.grid.rows)
            self.msg_total_lines - self.grid.rows
        else
            0;
        new_offset = @min(new_offset + scroll_amount, max_scroll);
    } else if (std.mem.eql(u8, direction, "up")) {
        // Scroll up (show earlier content)
        if (new_offset >= scroll_amount) {
            new_offset -= scroll_amount;
        } else {
            new_offset = 0;
        }
    }

    if (new_offset != self.msg_scroll_offset) {
        self.msg_scroll_offset = new_offset;

        // Throttle vertex updates to ~60fps (16ms)
        const now = clock.nowNs();
        const throttle_ns: i128 = 16 * std.time.ns_per_ms;
        const elapsed = now - self.msg_scroll_last_send;

        if (elapsed >= throttle_ns) {
            self.log.write("[msg] handleMsgGridScroll: {s} offset {d} (send)\n", .{ direction, new_offset });
            if (runMsgGridScrollFlush(self, new_offset)) {
                self.msg_scroll_last_send = now;
                self.msg_scroll_pending = false;
            } else {
                // Aborted (e.g. atlas reset mid-bracket) — retry once a full
                // flush has resent everything; msg_scroll_offset already
                // holds the target so the retry picks it up automatically.
                self.msg_scroll_pending = true;
            }
        } else {
            // Mark pending - will be processed on next throttle window or flush
            self.msg_scroll_pending = true;
        }
    }
}

/// Process pending scroll update (called from flush or timer).
pub fn processPendingMsgScroll(self: *Core) void {
    if (!self.msg_scroll_pending) return;
    if (!self.grid.external_grids.contains(grid_mod.MESSAGE_GRID_ID)) {
        // There is nothing left to scroll: the view was hidden while the
        // retry was outstanding. Returning without clearing left the flag
        // set forever, and the frontends read it as "retry needed" and
        // re-armed a 50ms timer on every tick, each one taking grid_mu.
        self.msg_scroll_pending = false;
        return;
    }

    self.log.write("[msg] processPendingMsgScroll: offset {d}\n", .{self.msg_scroll_offset});
    if (runMsgGridScrollFlush(self, self.msg_scroll_offset)) {
        self.msg_scroll_last_send = clock.nowNs();
        self.msg_scroll_pending = false;
    }
    // Aborted: leave msg_scroll_pending = true so a later retry (next
    // throttle window, or the next explicit call) picks it up again.
}

/// Hide msg_show external grid.
pub fn hideMsgShow(self: *Core) void {
    const msg_grid_id = grid_mod.MESSAGE_GRID_ID;
    _ = self.grid.removeSyntheticExternal(msg_grid_id) catch |err| {
        if (Core.isHardRenderFailure(err)) self.failHardRender(err);
        return;
    };
    // Reset scroll state and invalidate cache
    self.msg_scroll_offset = 0;
    self.msg_total_lines = 0;
    self.msg_cached_max_width = 0;
    self.msg_cache_valid = false;
    self.msg_scroll_pending = false;
    self.msg_show_retry_at = null;
    self.msg_show_retry_delay_ns = 16 * std.time.ns_per_ms;
    self.msg_line_cache.clearRetainingCapacity();
    self.msg_line_cache_build.clearRetainingCapacity();
    self.log.write("[msg] hideMsgShow\n", .{});
}

/// Send confirm message to frontend via on_msg_show callback (confirm view).
/// Uses the singleton ConfirmMessage from MessageState (zero-alloc path).
fn sendConfirmCallback(self: *Core) void {
    const cb = self.cb.on_msg_show orelse return;
    const cm = &self.grid.message_state.confirm_msg;
    if (!cm.active or cm.text_len == 0) return;

    var c_chunks: [1]c_api.MsgChunk = .{.{
        .hl_id = cm.hl_id,
        .text = &cm.text,
        .text_len = cm.text_len,
    }};

    self.log.write("[msg] sendConfirmCallback: kind={s} id={d}\n", .{
        cm.kind[0..cm.kind_len], cm.id,
    });

    cb(
        self.ctx,
        c_api.zonvie_msg_view_type.confirm,
        &cm.kind,
        cm.kind_len,
        &c_chunks,
        1,
        0,
        0,
        0, // replace_last, history, append
        cm.id,
        0, // timeout_ms
    );
}

/// Send msg_show callback to frontend (helper for short messages or fallback).
fn messageTimeoutMs(timeout_sec: f32) u32 {
    if (!std.math.isFinite(timeout_sec) or timeout_sec <= 0) return 0;

    const timeout_ms = @as(f64, timeout_sec) * 1000.0;
    const max_timeout_ms: f64 = @floatFromInt(std.math.maxInt(u32));
    if (timeout_ms >= max_timeout_ms) return std.math.maxInt(u32);
    return @intFromFloat(timeout_ms);
}

fn messageTimeoutNs(timeout_sec: f32) ?i128 {
    const timeout_ms = messageTimeoutMs(timeout_sec);
    if (timeout_ms == 0) return null;
    return @as(i128, timeout_ms) * std.time.ns_per_ms;
}

pub fn sendMsgShowCallback(self: *Core, msg: anytype, chunks: anytype, view: config.MsgViewType, timeout_sec: f32) void {
    const cb = self.cb.on_msg_show orelse return;

    // Build C ABI chunk array
    var c_chunks: [256]c_api.MsgChunk = undefined;
    const chunk_count = @min(chunks.len, c_chunks.len);

    for (chunks[0..chunk_count], 0..) |chunk, i| {
        c_chunks[i] = .{
            .hl_id = chunk.hl_id,
            .text = chunk.text.ptr,
            .text_len = chunk.text.len,
        };
    }

    // Convert view type to C ABI enum
    const c_view: c_api.zonvie_msg_view_type = switch (view) {
        .mini => .mini,
        .ext_float => .ext_float,
        .confirm => .confirm,
        .split => .split,
        .none => .none,
        .notification => .notification,
    };

    // Convert timeout from seconds to milliseconds.
    const timeout_ms = messageTimeoutMs(timeout_sec);

    cb(
        self.ctx,
        c_view,
        msg.kind.ptr,
        msg.kind.len,
        &c_chunks,
        chunk_count,
        if (msg.replace_last) 1 else 0,
        if (msg.history) 1 else 0,
        if (msg.append) 1 else 0,
        msg.id,
        timeout_ms,
    );
}

/// Send config parse error to frontend via on_msg_show callback (ext_float view).
/// Called once after first redraw batch when Neovim is ready.
/// Always sets config_error_sent = true regardless of whether callback exists,
/// to avoid infinite retry when on_msg_show is not registered.
pub fn sendConfigError(self: *Core, err_msg: []const u8) void {
    self.config_error_sent = true;

    const cb = self.cb.on_msg_show orelse return;
    const kind = "emsg";
    var chunks: [1]c_api.MsgChunk = .{.{
        .hl_id = 0,
        .text = err_msg.ptr,
        .text_len = err_msg.len,
    }};
    cb(
        self.ctx,
        .ext_float,
        kind.ptr,
        kind.len,
        &chunks,
        1, // chunk_count
        0, // replace_last
        0, // history
        0, // append
        -1, // msg_id (synthetic)
        0, // timeout_ms (0 = no auto-hide)
    );
}

/// Send all msg_history entries combined to frontend callback (for mini view).
pub fn sendMsgHistoryCallbackAll(self: *Core, entries: []const grid_mod.MsgHistoryEntry, view: config.MsgViewType) void {
    const cb = self.cb.on_msg_show orelse return;

    // Build combined text from all entries
    var text_buf: [4096]u8 = undefined;
    var text_len: usize = 0;

    for (entries, 0..) |entry, entry_idx| {
        // Add newline between entries
        if (entry_idx > 0 and text_len < text_buf.len - 1) {
            text_buf[text_len] = '\n';
            text_len += 1;
        }

        for (entry.content.items) |chunk| {
            const copy_len = @min(chunk.text.len, text_buf.len - text_len);
            @memcpy(text_buf[text_len..][0..copy_len], chunk.text[0..copy_len]);
            text_len += copy_len;
            if (text_len >= text_buf.len) break;
        }
        if (text_len >= text_buf.len) break;
    }

    // Create single chunk with combined text
    var c_chunks: [1]c_api.MsgChunk = .{.{
        .hl_id = 0,
        .text = &text_buf,
        .text_len = text_len,
    }};

    // Convert view type to C ABI enum
    const c_view: c_api.zonvie_msg_view_type = switch (view) {
        .mini => .mini,
        .ext_float => .ext_float,
        .confirm => .confirm,
        .split => .split,
        .none => .none,
        .notification => .notification,
    };

    // Use special kind "_msg_history" to distinguish from regular msg_show
    const history_kind = "_msg_history";
    cb(
        self.ctx,
        c_view,
        history_kind.ptr,
        history_kind.len,
        &c_chunks,
        1, // chunk_count
        0, // replace_last
        0, // history (don't use this flag, use kind instead)
        0, // append
        0, // id
        0, // timeout_ms (no auto-hide for history)
    );
}

/// Send pending msg_show at index from snapshot (survives msg_clear).
pub fn sendPendingMsgShowAt(self: *Core, index: usize) void {
    if (index >= self.grid.message_state.pending_count) return;
    const pm = &self.grid.message_state.pending_messages[index];
    if (pm.text_len == 0) return;

    // Count lines in pending message
    var line_count: u32 = 1;
    for (pm.text[0..pm.text_len]) |ch| {
        if (ch == '\n') line_count += 1;
    }

    self.log.write("[msg] sendPendingMsgShow[{d}] kind={s} text_len={d} lines={d}\n", .{
        index,
        pm.kind[0..pm.kind_len],
        pm.text_len,
        line_count,
    });

    // Check if this is a confirm dialog
    const kind = pm.kind[0..pm.kind_len];
    const is_confirm = std.mem.eql(u8, kind, "confirm") or
        std.mem.eql(u8, kind, "confirm_sub");

    // For confirm dialogs: always send to frontend callback (GUI message window).
    // Neovim split/float windows cannot be rendered during cmdline mode,
    // but the GUI's message window is a native window that can display anytime.
    // (This is similar to how noice.nvim displays confirm dialogs in its own popup)
    if (is_confirm) {
        self.log.write("[msg] sendPendingMsgShow: confirm dialog -> send to GUI callback\n", .{});
        sendPendingMsgShowCallback(self, pm);
        return;
    }

    // Send message to frontend via callback (routing handles view selection)
    sendPendingMsgShowCallback(self, pm);
}

/// Send pending message to frontend via callback.
pub fn sendPendingMsgShowCallback(self: *Core, pm: *const grid_mod.PendingMessage) void {
    const cb = self.cb.on_msg_show orelse return;

    // Build single chunk from pending message
    var c_chunks: [1]c_api.MsgChunk = undefined;
    c_chunks[0] = .{
        .hl_id = pm.hl_id,
        .text = &pm.text,
        .text_len = pm.text_len,
    };

    // Route message to determine view type
    const kind = pm.kind[0..pm.kind_len];
    const route_result = self.msg_config.routeMessage(.msg_show, kind, 1);

    // Convert view type to C ABI enum
    const c_view: c_api.zonvie_msg_view_type = switch (route_result.view) {
        .mini => .mini,
        .ext_float => .ext_float,
        .confirm => .confirm,
        .split => .split,
        .none => .none,
        .notification => .notification,
    };

    cb(
        self.ctx,
        c_view,
        &pm.kind,
        pm.kind_len,
        &c_chunks,
        1,
        if (pm.replace_last) 1 else 0,
        if (pm.history) 1 else 0,
        if (pm.append) 1 else 0,
        pm.id,
    );
}

/// Send msg_clear callback to frontend and close any split view.
pub fn sendMsgClear(self: *Core) void {
    self.log.write("[msg] sendMsgClear\n", .{});

    // Close any existing message split window
    closeMessageSplit(self);

    // Hide both channels' external grids through the funnel so the
    // ViewSets' visible flags stay accurate.
    hideChannelView(self, .show, .ext_float);
    hideChannelView(self, .history, .ext_float);

    // Call frontend callback
    if (self.cb.on_msg_clear) |cb| {
        cb(self.ctx);
    }
}

/// Close any existing message split window via Lua.
pub fn closeMessageSplit(self: *Core) void {
    const lua_code =
        \\local state = _G._zonvie_msg_split
        \\if state and state.win and vim.api.nvim_win_is_valid(state.win) then
        \\  vim.api.nvim_win_close(state.win, true)
        \\end
        \\_G._zonvie_msg_split = nil
    ;
    self.requestExecLua(lua_code) catch |e| {
        self.log.write("[msg] closeMessageSplit failed: {any}\n", .{e});
    };
}

/// Send one status channel (showmode / showcmd / ruler) to the frontend.
/// The three differ only in which slot they read, which route they consult,
/// and which callback they reach; the rest of the send path is identical.
pub fn sendMsgStatus(self: *Core, channel: grid_mod.StatusChannel) void {
    const chunks = self.grid.message_state.status_content[channel.index()].items;

    const event: config.MsgEvent = switch (channel) {
        .showmode => .msg_showmode,
        .showcmd => .msg_showcmd,
        .ruler => .msg_ruler,
    };

    // Route message using config
    const route_result = self.msg_config.routeMessage(event, "", 1);
    self.log.write("[msg] sendMsgStatus({s}) chunks={d} routed to view={s}\n", .{ @tagName(channel), chunks.len, @tagName(route_result.view) });

    if (route_result.view == .none) return; // Don't show anything

    const cb = switch (channel) {
        .showmode => self.cb.on_msg_showmode,
        .showcmd => self.cb.on_msg_showcmd,
        .ruler => self.cb.on_msg_ruler,
    } orelse return;

    var c_chunks: [64]c_api.MsgChunk = undefined;
    const chunk_count = @min(chunks.len, c_chunks.len);

    for (chunks[0..chunk_count], 0..) |chunk, i| {
        c_chunks[i] = .{
            .hl_id = chunk.hl_id,
            .text = chunk.text.ptr,
            .text_len = chunk.text.len,
        };
    }

    // Convert view type to C ABI enum
    const c_view: c_api.zonvie_msg_view_type = switch (route_result.view) {
        .mini => .mini,
        .ext_float => .ext_float,
        .confirm => .confirm,
        .split => .split,
        .none => .none,
        .notification => .notification,
    };

    cb(self.ctx, c_view, &c_chunks, chunk_count);
}

/// Show msg_history through the channel dispatch: route the entry set once
/// as a single unit, then let the shared backends display it. Previously this
/// function was its own five-arm switch with its own auto-hide handling — the
/// second consumer the view abstraction existed for.
pub fn sendMsgHistoryShow(self: *Core) bool {
    const entries = self.grid.msg_history_state.entries.items;
    const views = &self.history_views;

    // History is routed as one unit, so the cycle has a single slot. Cleared
    // before the empty check too, so an empty cycle hides a still-visible
    // core-owned view through the same dispatch as everything else.
    views.beginCycle(self.alloc, 1) catch {
        self.log.write("[msg_history] view assignment alloc failed; retrying\n", .{});
        self.flush_aborted = true;
        return false;
    };

    if (entries.len > 0) {
        const route_result = self.msg_config.routeMessage(.msg_history_show, "", @intCast(entries.len));
        self.log.write("[msg_history] entries={d} routed to view={s}\n", .{ entries.len, @tagName(route_result.view) });
        views.assign(0, route_result.view, route_result.timeout, route_result.enter);
    } else {
        self.log.write("[msg_history] empty\n", .{});
    }

    return dispatchChannel(self, .history, .{ .history = entries });
}

/// Render history entries into the msg_history external grid (-103).
/// Returns false when the flush must be retried.
fn renderMsgHistoryGrid(self: *Core, entries: []const grid_mod.MsgHistoryEntry) bool {
    const history_grid_id = grid_mod.MSG_HISTORY_GRID_ID;

    // Build content lines from entries
    var lines: [256][256]u8 = undefined;
    var line_lens: [256]usize = undefined;
    var line_count: usize = 0;
    var max_width: u32 = 20;

    for (entries) |entry| {
        if (line_count >= lines.len) break;

        // Combine all chunks into one line
        var line_len: usize = 0;
        for (entry.content.items) |chunk| {
            const copy_len = @min(chunk.text.len, lines[line_count].len - line_len);
            @memcpy(lines[line_count][line_len..][0..copy_len], chunk.text[0..copy_len]);
            line_len += copy_len;
            if (line_len >= lines[line_count].len) break;
        }
        line_lens[line_count] = line_len;

        // Track max width
        const display_width = countDisplayWidth(lines[line_count][0..line_len]);
        if (display_width > max_width) max_width = display_width;

        line_count += 1;
    }

    if (line_count == 0) return true;

    // Calculate grid dimensions
    const max_height: u32 = 20;
    const height: u32 = @intCast(@min(line_count, max_height));
    const width: u32 = @min(max_width + 2, 80); // +2 for padding, max 80

    self.log.write("[msg_history] show: entries={d} size={d}x{d}\n", .{ entries.len, width, height });

    // Create or resize grid
    self.grid.resizeGrid(history_grid_id, height, width) catch |e| {
        self.log.write("[msg_history] resizeGrid failed: {any}\n", .{e});
        self.flush_aborted = true;
        return false;
    };
    self.grid.clearGrid(history_grid_id);

    // Write lines to grid
    for (0..height) |row_idx| {
        const row: u32 = @intCast(row_idx);
        const line = lines[row_idx][0..line_lens[row_idx]];

        var col: u32 = 1; // Start with 1 cell padding
        var iter = std.unicode.Utf8View.initUnchecked(line).iterator();
        while (iter.nextCodepoint()) |cp| {
            if (col >= width - 1) break;
            self.grid.putCellGrid(history_grid_id, row, col, cp, 0);
            col += 1;
            if (isWideChar(cp)) {
                if (col >= width - 1) break;
                self.grid.putCellGrid(history_grid_id, row, col, 0, 0);
                col += 1;
            }
        }
    }

    // Register as external grid
    // Position: use special marker -2 to indicate "msg_show position" (top-right)
    // Frontend will interpret this and position like msg_show
    self.grid.putSyntheticExternal(history_grid_id, .{
        .win = 1, // Global grid
        .start_row = -2, // Special marker: position like msg_show (top-right)
        .start_col = -2,
    }) catch |e| {
        self.log.write("[msg_history] external_grids.put failed: {any}\n", .{e});
        self.flush_aborted = true;
        return false;
    };

    // Auto-hide is owned by showChannelView; retry backoff is reset by the
    // caller on success. Nothing channel-lifecycle-related belongs here.
    return true;
}

/// Hide msg_history external grid.
pub fn hideMsgHistory(self: *Core) void {
    const history_grid_id = grid_mod.MSG_HISTORY_GRID_ID;
    _ = self.grid.removeSyntheticExternal(history_grid_id) catch |err| {
        if (Core.isHardRenderFailure(err)) self.failHardRender(err);
        return;
    };
    // Drop any pending retry, mirroring hideMsgShow. nextMsgTimeoutNs reads
    // msg_history_retry_at unconditionally, but only the history_dirty block
    // clears it — so an auto-hide that lands between a failed dispatch and
    // its retry clears the dirty flag and strands the deadline in the past,
    // and the frontend then re-arms a 0ms timer forever, each tick driving a
    // full flush under grid_mu.
    self.msg_history_retry_at = null;
    self.msg_history_retry_delay_ns = 16 * std.time.ns_per_ms;
    self.log.write("[msg_history] hide\n", .{});
}

/// Look up overflow extras for a composited column.
/// First checks the ephemeral float overlay buffer (for ext grid composites),
/// then falls back to the persistent overflow map.
pub fn getOverflowForCell(core: *Core, rc: *const RenderCells, comp_row: u32, comp_col: u32) ?[]const u32 {
    // Check ephemeral float overlay map first (set during ext grid flush).
    // A hit means a float occupies this cell: value non-null = float has overflow,
    // value null = float shadows base (no overflow). Either way, do NOT fall back.
    if (core.flush_float_overlay) |map| {
        const key = FloatOverlayKey{ .row = comp_row, .col = comp_col };
        // Single lookup instead of contains()+get(): the map's value type is
        // itself optional (null = float shadows base with no overflow), so
        // unwrapping one Optional level here yields exactly that inner value.
        if (map.get(key)) |v| return v;
    }

    // Fall back to persistent overflow map (no float overlay at this cell).
    // The grid-local count avoids a cell-key hash when only another grid owns
    // overflow clusters.
    const gid = rc.grid_ids.items[@intCast(comp_col)];
    if (core.grid.overflowCountForGrid(gid) == 0) return null;
    const src_row: u32 = if (gid == 1) comp_row else blk: {
        if (core.grid.win_pos.get(gid)) |pos| break :blk comp_row -| pos.row;
        break :blk comp_row;
    };
    const src_col: u32 = if (gid == 1) comp_col else blk: {
        if (core.grid.win_pos.get(gid)) |pos| break :blk comp_col -| pos.col;
        break :blk comp_col;
    };
    return core.grid.getOverflow(gid, src_row, src_col);
}

/// Check if a composited cell's overflow contains emoji-significant codepoints
/// (VS16 U+FE0F, ZWJ U+200D, or skin tone modifiers U+1F3FB..1F3FF).
/// Any of these indicate the cell is part of a multi-codepoint emoji cluster
/// that needs color emoji rendering.
/// Whether a cluster's tail marks it as needing color-emoji rendering.
///
/// Split out from cellIsEmojiCluster because the fallback glyph cache depends
/// on this being a function of the extras and nothing else: the extras are in
/// the cache key, so if this answer could vary for identical extras, one key
/// would name two different bitmaps. Keeping it callable on a plain slice is
/// what makes that property testable.
pub fn extrasMarkEmojiCluster(extras: []const u32) bool {
    for (extras) |extra| {
        if (extra == 0xFE0F or extra == 0x200D or (extra >= 0x1F3FB and extra <= 0x1F3FF)) return true;
    }
    return false;
}

pub fn cellIsEmojiCluster(core: *Core, rc: *const RenderCells, comp_row: u32, comp_col: u32) bool {
    const extras = getOverflowForCell(core, rc, comp_row, comp_col) orelse return false;
    return extrasMarkEmojiCluster(extras);
}

/// Build a cache key for a cell's full cluster (base scalar + overflow extras + style).
/// Overflow extras are folded into the key so different ZWJ sequences with the same
/// first scalar (e.g., 👩‍💻 vs 👩‍🔬) get distinct cache entries.
pub fn clusterCacheKey(first_scalar: u32, style_index: u32, overflow: ?[]const u32) u64 {
    // Start with base key: scalar + style
    var key: u64 = (@as(u64, first_scalar) << 2) | @as(u64, style_index);
    // Fold in overflow codepoints. Rotate between folds so the key depends
    // on extras ORDER, not just their multiset -- plain XOR-fold alone is
    // commutative, so two different-order sequences of the same codepoints
    // (genuinely different grapheme clusters, e.g. distinct combining-mark
    // orderings) would otherwise collide on an identical key.
    if (overflow) |extras| {
        for (extras) |cp| {
            // FNV-1a-like mixing into upper bits
            key ^= @as(u64, cp) *% 0x517cc1b727220a95;
            key = (key << 17) | (key >> 47);
        }
    }
    return key;
}

/// Build a cache hash index for a cell's full cluster.
fn clusterCacheHash(first_scalar: u32, style_index: u32, overflow: ?[]const u32) u32 {
    var h: u32 = (first_scalar *% 2654435761) ^ style_index;
    if (overflow) |extras| {
        for (extras) |cp| {
            h ^= cp *% 2246822519;
            h = (h << 13) | (h >> 19); // rotate
        }
    }
    return h;
}

/// Resolve a cursor scalar through the same persistent Phase 2 caches used by
/// row generation. Cursor movement must not rasterize and pack a duplicate
/// atlas entry for a glyph that is already present in the retained row set.
fn ensureCachedPhase2Glyph(
    core: *Core,
    scalar: u32,
    style_flags: u32,
    overflow: ?[]const u32,
) !?c_api.GlyphEntry {
    try core.initGlyphCache();

    const style_index: u32 =
        @as(u32, @intFromBool(style_flags & c_api.STYLE_BOLD != 0)) |
        (@as(u32, @intFromBool(style_flags & c_api.STYLE_ITALIC != 0)) << 1);
    const extras = overflow orelse &.{};
    var ascii_insert: ?usize = null;
    var non_ascii_insert: ?usize = null;
    var non_ascii_key: u64 = 0;

    if (scalar < 128 and extras.len == 0) {
        // This is the canonical scalar cache layout used by row generation and
        // ASCII preload. The former style-major index aliased unrelated glyphs.
        const cache_index = @as(usize, scalar) * 4 + @as(usize, style_index);
        if (core.glyph_cache_ascii) |cache| {
            if (core.glyph_valid_ascii) |valid| {
                if (cache_index < cache.len and cache_index < valid.len) {
                    if (valid[cache_index]) return cache[cache_index];
                    ascii_insert = cache_index;
                }
            }
        }
    }
    if (ascii_insert == null) {
        if (core.glyph_cache_non_ascii) |cache| {
            if (core.glyph_keys_non_ascii) |keys| {
                if (cache.len != 0 and cache.len == keys.len) {
                    const key = clusterCacheKey(scalar, style_index, overflow);
                    const hash = clusterCacheHash(scalar, style_index, overflow);
                    const probe = nvim_core.glyphCacheProbe(keys, key, hash);
                    if (probe.hit) |hit| return cache[hit];
                    non_ascii_insert = probe.insert;
                    non_ascii_key = key;
                }
            }
        }
    }

    var resolved: ?c_api.GlyphEntry = null;
    const use_scalar_cluster = extras.len != 0 or isEmojiPresentation(scalar);

    if (use_scalar_cluster) {
        // The scalar rasterizer consumes this side-channel for complete emoji
        // and grapheme clusters. OverflowExtras is bounded to 15 elements.
        core.emoji_cluster_buf[0] = scalar;
        for (extras, 0..) |extra, i| core.emoji_cluster_buf[i + 1] = extra;
        core.emoji_cluster_len = @intCast(1 + extras.len);
        resolved = core.ensureGlyphPhase2(scalar, style_flags);
    } else if (core.cb.on_shape_text_run) |shape| {
        if (core.cb.on_rasterize_glyph_by_id != null) {
            var glyph_ids: [8]u32 = undefined;
            var clusters: [8]u32 = undefined;
            var x_adv: [8]i32 = undefined;
            var x_off: [8]i32 = undefined;
            var y_off: [8]i32 = undefined;
            const one_scalar = [1]u32{scalar};
            const glyph_count = shape(
                core.ctx,
                &one_scalar,
                1,
                style_flags,
                &glyph_ids,
                &clusters,
                &x_adv,
                &x_off,
                &y_off,
                glyph_ids.len,
            );
            if (core.flush_aborted) return null;

            // Cursor cells cannot carry a variable-size shaped run. Reuse the
            // row glyph-ID cache only for the unambiguous single-glyph result;
            // every abnormal result safely falls back to scalar rasterization.
            if (glyph_count == 1 and glyph_ids[0] != 0 and clusters[0] == 0) {
                if (core.glyph_cache_by_id) |cache| {
                    if (core.glyph_keys_by_id) |keys| {
                        if (cache.len != 0 and cache.len == keys.len) {
                            const gid = glyph_ids[0];
                            const key = (@as(u64, gid) << 2) | @as(u64, style_index);
                            const hash = (gid *% 2654435761) ^ style_index;
                            const probe = nvim_core.glyphCacheProbe(keys, key, hash);
                            if (probe.hit) |hit| {
                                resolved = cache[hit];
                            } else if (core.ensureGlyphByID(gid, style_flags)) |entry| {
                                cache[probe.insert] = entry;
                                keys[probe.insert] = key;
                                resolved = entry;
                            } else if (core.flush_aborted) {
                                return null;
                            }
                        }
                    }
                }
                if (resolved == null) {
                    resolved = core.ensureGlyphByID(glyph_ids[0], style_flags);
                    if (core.flush_aborted) return null;
                }
                // A shaped glyph-ID may be unsupported by the selected face
                // (or intentionally empty for a color-glyph handoff). Match
                // row generation by falling back through the scalar path;
                // the by-ID blank is cached, while only a final scalar miss
                // arms bounded maintenance retries.
                if (resolved) |entry| {
                    if (entry.bbox_size_px[0] <= 0 or entry.bbox_size_px[1] <= 0) {
                        resolved = null;
                    }
                }
            }
        }
    }

    if (resolved == null) {
        resolved = core.ensureGlyphPhase2(scalar, style_flags);
        if (core.flush_aborted) return null;
    }

    const entry = resolved orelse return null;
    if (ascii_insert) |index| {
        core.glyph_cache_ascii.?[index] = entry;
        core.glyph_valid_ascii.?[index] = true;
    } else if (non_ascii_insert) |index| {
        core.glyph_cache_non_ascii.?[index] = entry;
        core.glyph_keys_non_ascii.?[index] = non_ascii_key;
    }
    return entry;
}

/// Populate core.emoji_cluster_buf from a cell's base scalar + overflow extras.
/// Lay a cluster out for the frontend rasterizer: base scalar first, then the
/// cell's overflow tail, truncated to the buffer. Returns the length written.
///
/// This is the entire input the rasterizer sees, and it is built from exactly
/// the two values the fallback cache key folds in. Extracted so that pairing
/// can be asserted directly rather than inferred from the two call sites.
pub fn buildEmojiCluster(buf: []u32, base_scalar: u32, extras: ?[]const u32) u8 {
    buf[0] = base_scalar;
    var len: u8 = 1;
    if (extras) |ex| {
        for (ex) |extra| {
            if (len < buf.len) {
                buf[len] = extra;
                len += 1;
            }
        }
    }
    return len;
}

fn setEmojiClusterFromOverflow(core: *Core, rc: *const RenderCells, comp_row: u32, comp_col: u32, base_scalar: u32) void {
    const extras = getOverflowForCell(core, rc, comp_row, comp_col);
    core.emoji_cluster_len = buildEmojiCluster(&core.emoji_cluster_buf, base_scalar, extras);
}

/// Result of scanning one emoji/grapheme cluster from a UTF-8 string.
pub const EmojiCluster = struct {
    first_cp: u32,
    /// Number of codepoints in the cluster (including the first).
    codepoint_count: u32,
    /// Display width in cells (1 or 2).
    display_width: u32,
    /// Byte offset past the end of the cluster in the source string.
    end_byte: usize,
    /// Extra codepoints (after the first). Valid up to codepoint_count - 1.
    extras: [15]u32,
    extras_len: u32,
};

/// Scan one emoji cluster starting at `start` in a UTF-8 string.
/// Recognizes VS16, ZWJ sequences, skin tone modifiers, keycap sequences,
/// regional indicator pairs, and tag sequences.
pub fn scanEmojiCluster(text: []const u8, start: usize) EmojiCluster {
    var it = std.unicode.Utf8Iterator{ .bytes = text, .i = start };
    const first_slice = it.nextCodepointSlice() orelse return .{
        .first_cp = 0,
        .codepoint_count = 0,
        .display_width = 0,
        .end_byte = start,
        .extras = undefined,
        .extras_len = 0,
    };
    const first_cp = std.unicode.utf8Decode(first_slice) catch return .{
        .first_cp = 0xFFFD,
        .codepoint_count = 1,
        .display_width = 1,
        .end_byte = it.i,
        .extras = undefined,
        .extras_len = 0,
    };

    var extras: [15]u32 = undefined;
    var extras_len: u32 = 0;
    var prev_cp: u32 = first_cp;

    var scan = it;
    while (scan.i < text.len) {
        const save_i = scan.i;
        const sl = scan.nextCodepointSlice() orelse break;
        const cp2 = std.unicode.utf8Decode(sl) catch break;

        // Regional indicators pair: only accept one more RI (flags are exactly 2 RIs).
        const ri_count: u32 = if (first_cp >= 0x1F1E6 and first_cp <= 0x1F1FF) 1 else 0;
        const cur_ri_count = ri_count + blk: {
            var c: u32 = 0;
            for (extras[0..extras_len]) |e| {
                if (e >= 0x1F1E6 and e <= 0x1F1FF) c += 1;
            }
            break :blk c;
        };
        const is_cluster_ext = (cp2 == 0xFE0F or cp2 == 0xFE0E or cp2 == 0x200D or
            cp2 == 0x20E3 or (cp2 >= 0x1F3FB and cp2 <= 0x1F3FF) or
            (cp2 >= 0x1F1E6 and cp2 <= 0x1F1FF and first_cp >= 0x1F1E6 and first_cp <= 0x1F1FF and cur_ri_count < 2) or
            (cp2 >= 0xE0020 and cp2 <= 0xE007F) or
            // Unicode combining marks (NFD decomposed characters like
            // U+306F U+3099 = ば). These must stay in the same cluster
            // as the preceding base character.
            (cp2 >= 0x0300 and cp2 <= 0x036F) or // Combining Diacritical Marks
            (cp2 >= 0x3099 and cp2 <= 0x309A) or // Combining Kana Voicing (゙ ゚)
            (cp2 >= 0x0483 and cp2 <= 0x0489) or // Combining Cyrillic
            (cp2 >= 0x0591 and cp2 <= 0x05BD) or // Combining Hebrew
            (cp2 >= 0x0610 and cp2 <= 0x061A) or // Combining Arabic
            (cp2 >= 0x064B and cp2 <= 0x065F) or // Combining Arabic (cont.)
            (cp2 >= 0x0E31 and cp2 == 0x0E31) or // Thai
            (cp2 >= 0x0E34 and cp2 <= 0x0E3A) or // Thai vowels/tone
            (cp2 >= 0x0E47 and cp2 <= 0x0E4E) or // Thai (cont.)
            (cp2 >= 0x20D0 and cp2 <= 0x20FF) or // Combining for Symbols
            (cp2 >= 0xFE20 and cp2 <= 0xFE2F));
        const after_zwj = prev_cp == 0x200D;

        if (is_cluster_ext or after_zwj) {
            if (extras_len >= extras.len) {
                // Cluster exceeds the fixed extras capacity. Stop here
                // instead of continuing to consume (and silently losing)
                // further combining marks/tags/ZWJ components: `scan.i`
                // must not advance past a codepoint that isn't recorded in
                // `extras`, or end_byte's caller skips it with no trace.
                // The un-stored codepoint stays in the stream for the next
                // scanEmojiCluster call to pick up as its own cluster.
                scan.i = save_i;
                break;
            }
            extras[extras_len] = cp2;
            extras_len += 1;
            prev_cp = cp2;
        } else {
            scan.i = save_i;
            break;
        }
    }

    const cp_count: u32 = 1 + extras_len;
    // Display width: 2 cells for emoji, matching Neovim's strwidth().
    // - Emoji_Presentation=Yes (👩, 😀) → 2
    // - East Asian Wide (CJK) → 2
    // - VS16-qualified (⚠️, #️⃣) → 2 (VS16 requests emoji presentation = wide)
    // - Plain narrow text → 1
    const has_vs16 = for (extras[0..extras_len]) |e| {
        if (e == 0xFE0F) break true;
    } else false;
    const dw: u32 = if (isWideChar(first_cp) or isEmojiPresentation(first_cp) or has_vs16) 2 else 1;

    return .{
        .first_cp = first_cp,
        .codepoint_count = cp_count,
        .display_width = dw,
        .end_byte = scan.i,
        .extras = extras,
        .extras_len = extras_len,
    };
}

pub fn countUtf8Codepoints(s: []const u8) u32 {
    var count: u32 = 0;
    var iter = std.unicode.Utf8View.initUnchecked(s).iterator();
    while (iter.nextCodepoint()) |_| {
        count += 1;
    }
    return count;
}

/// Check if a codepoint is a wide (double-width) character.
/// Based on East Asian Width (simplified version for CJK).
pub fn isWideChar(cp: u32) bool {
    // Hangul Jamo
    if (cp >= 0x1100 and cp <= 0x115F) return true;
    // CJK Radicals, Kangxi, Ideographic, Hiragana, Katakana, Bopomofo, Hangul Compat, Kanbun, etc.
    if (cp >= 0x2E80 and cp <= 0x4DBF) return true;
    // CJK Unified Ideographs
    if (cp >= 0x4E00 and cp <= 0x9FFF) return true;
    // Yi Syllables, Yi Radicals, Lisu, Vai, Hangul Syllables
    if (cp >= 0xA000 and cp <= 0xD7FF) return true;
    // CJK Compatibility Ideographs
    if (cp >= 0xF900 and cp <= 0xFAFF) return true;
    // Vertical Forms, CJK Compatibility Forms
    if (cp >= 0xFE10 and cp <= 0xFE6F) return true;
    // Halfwidth and Fullwidth Forms (fullwidth part)
    if (cp >= 0xFF00 and cp <= 0xFF60) return true;
    if (cp >= 0xFFE0 and cp <= 0xFFE6) return true;
    // CJK Unified Ideographs Extension B and beyond
    if (cp >= 0x20000 and cp <= 0x3FFFF) return true;
    return false;
}

/// Count display width accounting for control characters (^X notation) and wide characters.
/// Control characters (0x00-0x1F) and DEL (0x7F) take 2 columns.
/// Wide characters (CJK, etc.) take 2 columns.
/// Count display width of a UTF-8 string, recognizing emoji clusters.
/// Control characters (^X) take 2 columns. Emoji clusters take 2 columns.
/// Wide CJK characters take 2 columns. Everything else takes 1 column.
pub fn countDisplayWidth(s: []const u8) u32 {
    var count: u32 = 0;
    var byte_i: usize = 0;
    while (byte_i < s.len) {
        const cluster = scanEmojiCluster(s, byte_i);
        if (cluster.codepoint_count == 0) break;
        if (cluster.first_cp < 0x20 or cluster.first_cp == 0x7F) {
            count += 2; // ^X notation
        } else {
            count += cluster.display_width;
        }
        byte_i = cluster.end_byte;
    }
    return count;
}

/// Check if a cluster contains VS16 (U+FE0F, emoji presentation selector).
/// When VS16 is present, even text-default codepoints (e.g., ☀ U+2600)
/// should be rendered as color emoji.
fn clusterHasVS16(core: *Core, this_cluster: u32, next_cluster: u32) bool {
    if (next_cluster <= this_cluster + 1) return false;
    var ci: u32 = this_cluster;
    while (ci < next_cluster) : (ci += 1) {
        if (core.shaping_scalars.items[@intCast(ci)] == 0xFE0F) return true;
    }
    return false;
}
/// Check if a Unicode scalar has default emoji presentation (Emoji_Presentation=Yes).
/// Based on Unicode 15.1 emoji-data.txt. Only includes codepoints that modern
/// renderers display as color emoji without an explicit VS16 selector.
fn isEmojiPresentation(scalar: u32) bool {
    return switch (scalar) {
        // BMP: Emoji_Presentation=Yes (Unicode 15.1)
        0x231A...0x231B,
        0x23E9...0x23F3,
        0x23F8...0x23FA,
        0x25FD...0x25FE,
        0x2614...0x2615,
        0x2648...0x2653,
        0x267F,
        0x2693,
        0x26A1,
        0x26AA...0x26AB,
        0x26BD...0x26BE,
        0x26C4...0x26C5,
        0x26CE,
        0x26D4,
        0x26EA,
        0x26F2...0x26F3,
        0x26F5,
        0x26FA,
        0x26FD,
        0x2705,
        0x270A...0x270B,
        0x2728,
        0x274C,
        0x274E,
        0x2753...0x2755,
        0x2757,
        0x2795...0x2797,
        0x27A1,
        0x27B0,
        0x27BF,
        0x2934...0x2935,
        0x2B05...0x2B07,
        0x2B1B...0x2B1C,
        0x2B50,
        0x2B55,
        0x3030,
        0x303D,
        0x3297,
        0x3299,
        // SMP: Emoji_Presentation=Yes (Unicode 15.1)
        0x1F004,
        0x1F0CF,
        0x1F18E,
        0x1F191...0x1F19A,
        0x1F1E6...0x1F1FF, // regional indicators
        0x1F201,
        0x1F21A,
        0x1F22F,
        0x1F232...0x1F236,
        0x1F238...0x1F23A,
        0x1F250...0x1F251,
        0x1F300...0x1F320,
        0x1F32D...0x1F335,
        0x1F337...0x1F37C,
        0x1F37E...0x1F393,
        0x1F3A0...0x1F3CA,
        0x1F3CF...0x1F3D3,
        0x1F3E0...0x1F3F0,
        0x1F3F4,
        0x1F3F8...0x1F43E,
        0x1F440,
        0x1F442...0x1F4FC,
        0x1F4FF...0x1F53D,
        0x1F54B...0x1F54E,
        0x1F550...0x1F567,
        0x1F57A,
        0x1F595...0x1F596,
        0x1F5A4,
        0x1F5FB...0x1F64F,
        0x1F680...0x1F6C5,
        0x1F6CC,
        0x1F6D0...0x1F6D2,
        0x1F6D5...0x1F6D7,
        0x1F6DC...0x1F6DF,
        0x1F6EB...0x1F6EC,
        0x1F6F4...0x1F6FC,
        0x1F7E0...0x1F7EB,
        0x1F7F0,
        0x1F90C...0x1F93A,
        0x1F93C...0x1F945,
        0x1F947...0x1F9FF,
        0x1FA70...0x1FA7C,
        0x1FA80...0x1FA89,
        0x1FA8F...0x1FAC6,
        0x1FACE...0x1FADC,
        0x1FADF...0x1FAE9,
        0x1FAF0...0x1FAF8,
        => true,
        else => false,
    };
}

test "external cursor visibility includes validity and busy visibility" {
    var grid = grid_mod.Grid.init(std.testing.allocator);
    defer grid.deinit();

    grid.cursor_grid = 7;
    grid.cursor_valid = true;
    grid.cursor_visible = true;
    try std.testing.expect(externalCursorVisibleOnGrid(&grid, 7));

    grid.cursor_visible = false;
    try std.testing.expect(!externalCursorVisibleOnGrid(&grid, 7));
    grid.cursor_visible = true;
    grid.cursor_valid = false;
    try std.testing.expect(!externalCursorVisibleOnGrid(&grid, 7));
}

test "negative linespace splits above and below the text" {
    // Neovim's 'linespace' may be negative when a font leaves too much room
    // between lines; the shrink must reach the row, not be clamped away.
    try std.testing.expectEqual(@as(i32, 0), rowTopPadPx(0));
    try std.testing.expectEqual(@as(i32, 2), rowTopPadPx(5));
    try std.testing.expectEqual(@as(i32, 3), rowTopPadPx(6));
    // The odd pixel stays below the text in both directions, so a row keeps
    // the same text position whether it grew or shrank by the same amount.
    try std.testing.expectEqual(@as(i32, -2), rowTopPadPx(-5));
    try std.testing.expectEqual(@as(i32, -3), rowTopPadPx(-6));
}

test "external cursor color glyph retains emoji decoration" {
    const rgba_flags = externalCursorGlyphDecoFlags(4);
    try std.testing.expect((rgba_flags & c_api.DECO_CURSOR) != 0);
    try std.testing.expect((rgba_flags & c_api.DECO_SCROLLABLE) != 0);
    try std.testing.expect((rgba_flags & c_api.DECO_COLOR_EMOJI) != 0);
    try std.testing.expect((externalCursorGlyphDecoFlags(1) & c_api.DECO_COLOR_EMOJI) == 0);
}

test "flush begin abort preserves undispatched scroll state" {
    const State = struct {
        core: *Core,
        abort_begin: bool = true,
        scroll_calls: u32 = 0,

        fn onBegin(ctx: ?*anyopaque) callconv(.c) void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            if (self.abort_begin) self.core.flush_aborted = true;
        }

        fn onScroll(ctx: ?*anyopaque, grid_id: i64, rows_delta: i32) callconv(.c) void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            _ = rows_delta;
            if (grid_id == 1) self.scroll_calls += 1;
        }
    };

    var core = Core.initForTest(std.testing.allocator);
    defer core.deinitForTest();
    try core.grid.resizeGrid(1, 3, 3);
    var state = State{ .core = &core };
    core.ctx = &state;
    core.cb.on_flush_begin = State.onBegin;
    core.cb.on_grid_scroll = State.onScroll;
    core.grid.clearDirty();
    core.grid.scrollGrid(1, 0, 3, 0, 3, 1, 0);

    var flush_ctx = FlushCtx{ .core = &core };
    try flush_ctx.onFlush(3, 3);
    try std.testing.expect(core.grid.main_scroll_notify_pending);
    try std.testing.expect(core.grid.pending_scroll != null);
    try std.testing.expect(!core.grid.dirty_all);
    try std.testing.expectEqual(@as(u32, 0), state.scroll_calls);

    state.abort_begin = false;
    try flush_ctx.onFlush(3, 3);
    try std.testing.expectEqual(@as(u32, 1), state.scroll_calls);
    try std.testing.expect(!core.grid.main_scroll_notify_pending);
    try std.testing.expect(core.grid.pending_scroll == null);
}

test "zero-sized main still commits external grid transaction" {
    const State = struct {
        core: ?*Core = null,
        begin_calls: u32 = 0,
        end_calls: u32 = 0,
        main_layout_calls: u32 = 0,
        main_cursor_clears: u32 = 0,
        external_rows: u32 = 0,
        lifecycle_calls: u32 = 0,
        last_main_rows: u32 = 0,
        last_main_cols: u32 = 0,
        invalid_layout_payload: bool = false,
        abort_main_layout: bool = false,

        fn onBegin(ctx: ?*anyopaque) callconv(.c) void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            self.begin_calls += 1;
        }

        fn onEnd(ctx: ?*anyopaque) callconv(.c) void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            self.end_calls += 1;
        }

        fn onRow(
            ctx: ?*anyopaque,
            grid_id: i64,
            row_start: u32,
            row_count: u32,
            verts: ?[*]const c_api.Vertex,
            vert_count: usize,
            flags: u32,
            total_rows: u32,
            total_cols: u32,
        ) callconv(.c) void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            if (grid_id == 1 and (flags & c_api.VERT_UPDATE_MAIN) != 0) {
                self.main_layout_calls += 1;
                self.last_main_rows = total_rows;
                self.last_main_cols = total_cols;
                self.invalid_layout_payload =
                    row_start != 0 or row_count != 0 or verts != null or vert_count != 0 or
                    (total_rows != 0 and total_cols != 0);
                if (self.abort_main_layout) self.core.?.flush_aborted = true;
            }
            if (grid_id == 1 and (flags & c_api.VERT_UPDATE_CURSOR) != 0) {
                if (row_count == 0 and verts == null and vert_count == 0) {
                    self.main_cursor_clears += 1;
                }
            }
            if (grid_id == 2) {
                self.external_rows += 1;
            }
        }

        fn onExternal(
            ctx: ?*anyopaque,
            grid_id: i64,
            win: i64,
            rows: u32,
            cols: u32,
            start_row: i32,
            start_col: i32,
        ) callconv(.c) void {
            _ = win;
            _ = rows;
            _ = cols;
            _ = start_row;
            _ = start_col;
            if (grid_id == 2) {
                const self: *@This() = @ptrCast(@alignCast(ctx.?));
                self.lifecycle_calls += 1;
            }
        }
    };

    var core = Core.initForTest(std.testing.allocator);
    defer core.deinitForTest();
    defer core.known_external_grids.deinit(core.alloc);
    try core.grid.resize(0, 0);
    try core.grid.resizeGrid(2, 1, 1);
    try core.grid.putSyntheticExternal(2, .{ .win = 2, .start_row = 0, .start_col = 0 });

    var state = State{ .core = &core };
    core.ctx = &state;
    core.cb.on_flush_begin = State.onBegin;
    core.cb.on_flush_end = State.onEnd;
    core.cb.on_vertices_row = State.onRow;
    core.cb.on_external_window = State.onExternal;

    var flush_ctx = FlushCtx{ .core = &core };
    try flush_ctx.onFlush(0, 0);
    try std.testing.expectEqual(@as(u32, 1), state.begin_calls);
    try std.testing.expectEqual(@as(u32, 1), state.end_calls);
    try std.testing.expectEqual(@as(u32, 1), state.main_layout_calls);
    try std.testing.expectEqual(@as(u32, 1), state.main_cursor_clears);
    try std.testing.expect(!state.invalid_layout_payload);
    try std.testing.expectEqual(@as(u32, 1), state.external_rows);
    try std.testing.expectEqual(@as(u32, 1), state.lifecycle_calls);

    const zero_shapes = [_][2]u32{
        .{ 3, 0 },
        .{ 0, 4 },
    };
    for (zero_shapes) |shape| {
        try core.grid.resize(2, 2);
        try core.grid.resize(shape[0], shape[1]);
        try flush_ctx.onFlush(shape[0], shape[1]);
        try std.testing.expectEqual(shape[0], state.last_main_rows);
        try std.testing.expectEqual(shape[1], state.last_main_cols);
    }
    try std.testing.expectEqual(@as(u32, 3), state.main_layout_calls);
    try std.testing.expectEqual(@as(u32, 3), state.main_cursor_clears);
    try std.testing.expect(!state.invalid_layout_payload);

    // A synchronous frontend rejection must leave the layout dirty. The
    // retry publishes the same transition and only then consumes it.
    try core.grid.resize(2, 2);
    try core.grid.resize(2, 0);
    core.main_surface_vertex_count = 12;
    core.flush_vertex_count_aggregate = 12;
    state.abort_main_layout = true;
    try flush_ctx.onFlush(2, 0);
    try std.testing.expect(core.grid.dirty_all);
    // A publication refusal leaves the committed frame on screen, so the
    // accounting that described it survives instead of being invalidated.
    try std.testing.expect(core.main_vertex_row_ledger_valid);
    try std.testing.expectEqual(@as(usize, 12), core.main_surface_vertex_count);

    state.abort_main_layout = false;
    try flush_ctx.onFlush(2, 0);
    try std.testing.expect(!core.grid.dirty_all);
    try std.testing.expectEqual(core.grid.content_rev, core.last_sent_content_rev);
    try std.testing.expectEqual(@as(usize, 0), core.main_surface_vertex_count);
    try std.testing.expectEqual(@as(u32, 5), state.main_layout_calls);
    try std.testing.expectEqual(@as(u32, 4), state.main_cursor_clears);
}

test "message history allocation failure preserves dirty state for retry" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var core = Core.initForTest(failing.allocator());
    defer core.deinitForTest();
    core.ext_messages_enabled = true;
    var routes = [_]config.MsgRoute{
        .{ .filter = .{ .event = .msg_history_show }, .view = .ext_float, .opts = .{ .timeout = 0 } },
    };
    core.msg_config.messages.routes = &routes;

    var entry: grid_mod.MsgHistoryEntry = .{};
    defer entry.content.deinit(std.testing.allocator);
    try entry.content.append(std.testing.allocator, .{ .hl_id = 0, .text = "history" });
    try core.grid.setMsgHistoryShow(&.{entry}, false);

    failing.fail_index = failing.alloc_index;
    failing.resize_fail_index = failing.resize_index;
    notifyMessageChanges(&core);
    try std.testing.expect(core.grid.msg_history_state.dirty);
    try std.testing.expect(core.flush_aborted);

    // An aborted dispatch must arm a retry deadline: it is the only driver
    // left, since the abort discards the frame. Scrubbing this by hand — as
    // this test used to — hides whether the deadline was armed at all.
    try std.testing.expect(core.msg_history_retry_at != null);

    failing.fail_index = std.math.maxInt(usize);
    failing.resize_fail_index = std.math.maxInt(usize);
    core.flush_aborted = false;
    // Reach the deadline rather than deleting it, so the retry exercises the
    // real due-check.
    core.msg_history_retry_at = clock.nowNs() - 1;
    notifyMessageChanges(&core);
    try std.testing.expect(!core.grid.msg_history_state.dirty);
    try std.testing.expect(core.grid.external_grids.contains(grid_mod.MSG_HISTORY_GRID_ID));
    try std.testing.expect(core.msg_history_retry_at == null);
}

test "vertex budget does not preflight-reject a normal blank grid" {
    const State = struct {
        begin_calls: u32 = 0,
        fn onBegin(ctx: ?*anyopaque) callconv(.c) void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            self.begin_calls += 1;
        }
    };

    var core = Core.initForTest(std.testing.allocator);
    defer core.deinitForTest();
    try core.grid.resizeGrid(1, 200, 300);
    core.grid.clearDirty();
    var state = State{};
    core.ctx = &state;
    core.cb.on_flush_begin = State.onBegin;

    var flush_ctx = FlushCtx{ .core = &core };
    try flush_ctx.onFlush(200, 300);
    try std.testing.expectEqual(@as(u32, 1), state.begin_calls);
    try std.testing.expect(core.flush_retryable);
}

test "vertex budget uses actual row output and rejects an oversized callback" {
    var core = Core.initForTest(std.testing.allocator);
    defer core.deinitForTest();
    try core.main_vertex_row_counts.resize(core.alloc, 1);
    core.main_vertex_row_counts.items[0] = 0;
    try beginVertexBudgetTransaction(&core);
    defer finishVertexBudgetTransaction(&core, false);

    // More than the old 54-vertices-per-cell estimate is valid when the
    // actual row payload fits; overflow clusters are charged at this count.
    try replaceSurfaceRowVertexCount(
        &core,
        &core.main_surface_vertex_count,
        core.main_vertex_row_counts.items,
        0,
        96,
    );
    try std.testing.expectEqual(@as(usize, 96), core.main_surface_vertex_count);

    try std.testing.expectError(
        error.VertexBudgetExceeded,
        replaceSurfaceRowVertexCount(
            &core,
            &core.main_surface_vertex_count,
            core.main_vertex_row_counts.items,
            0,
            MAX_VERTICES_PER_CALLBACK + 1,
        ),
    );
    try std.testing.expect(!core.flush_retryable);
}

test "vertex budget validates completed state and invalidates metadata on abort" {
    var core = Core.initForTest(std.testing.allocator);
    defer core.deinitForTest();
    try core.ensureScrollCache(4);

    const moved_count = MAX_VERTICES_PER_SURFACE / 3;
    @memcpy(core.main_vertex_row_counts.items, &[_]usize{ 0, moved_count, moved_count, moved_count });
    core.main_surface_vertex_count = moved_count * 3;
    try beginVertexBudgetTransaction(&core);

    // Updating the destination first produces a mixed old/new total above the
    // surface cap. The completed frame is small and must remain valid.
    try replaceMainSurfaceRowVertexCount(&core, 0, moved_count);
    try replaceMainSurfaceRowVertexCount(&core, 1, 0);
    try replaceMainSurfaceRowVertexCount(&core, 2, 0);
    try replaceMainSurfaceRowVertexCount(&core, 3, 0);
    try validateCompletedVertexBudget(&core);
    try std.testing.expectEqual(moved_count, core.main_vertex_row_counts.items[0]);
    try std.testing.expectEqual(moved_count, core.main_surface_vertex_count);

    finishVertexBudgetTransaction(&core, false);
    try std.testing.expectEqual(@as(usize, 0), core.main_surface_vertex_count);
    try std.testing.expect(!core.main_vertex_row_ledger_valid);

    try beginVertexBudgetTransaction(&core);
    try replaceMainSurfaceRowVertexCount(&core, 0, moved_count);
    try replaceMainSurfaceRowVertexCount(&core, 1, 0);
    try replaceMainSurfaceRowVertexCount(&core, 2, 0);
    try replaceMainSurfaceRowVertexCount(&core, 3, 0);
    try validateCompletedVertexBudget(&core);
    finishVertexBudgetTransaction(&core, true);
    try std.testing.expectEqualSlices(usize, &.{ moved_count, 0, 0, 0 }, core.main_vertex_row_counts.items);
    try std.testing.expectEqual(moved_count, core.main_surface_vertex_count);
}

test "vertex budget permits aggregate redistribution across external surfaces" {
    var core = Core.initForTest(std.testing.allocator);
    defer core.deinitForTest();
    try core.ensureScrollCache(2);
    @memset(core.main_vertex_row_counts.items, MAX_VERTICES_PER_CALLBACK);
    core.main_surface_vertex_count = MAX_VERTICES_PER_SURFACE;

    try core.grid.resizeGrid(2, 1, 1);
    try core.grid.resizeGrid(3, 2, 1);
    try core.grid.putSyntheticExternal(2, .{ .win = 2, .start_row = 0, .start_col = 0 });
    try core.grid.putSyntheticExternal(3, .{ .win = 3, .start_row = 0, .start_col = 0 });
    const source = core.grid.sub_grids.getPtr(3).?;
    @memset(source.vertex_row_counts, MAX_VERTICES_PER_CALLBACK);
    source.surface_vertex_count = MAX_VERTICES_PER_SURFACE;
    core.grid.subgrid_surface_vertex_count = source.surface_vertex_count;

    try beginVertexBudgetTransaction(&core);
    const destination = core.grid.sub_grids.getPtr(2).?;
    try replaceSubgridSurfaceRowVertexCount(&core, 2, destination, 0, MAX_VERTICES_PER_CALLBACK);
    try replaceSubgridSurfaceRowVertexCount(&core, 3, source, 0, 0);
    try replaceSubgridSurfaceRowVertexCount(&core, 3, source, 1, 0);
    try validateCompletedVertexBudget(&core);
    finishVertexBudgetTransaction(&core, true);

    try std.testing.expectEqual(MAX_VERTICES_PER_CALLBACK, destination.surface_vertex_count);
    try std.testing.expectEqual(@as(usize, 0), source.surface_vertex_count);
    try std.testing.expectEqual(
        MAX_VERTICES_PER_SURFACE + MAX_VERTICES_PER_CALLBACK,
        core.flush_vertex_count_aggregate,
    );
}

test "external vertex aggregate follows lifecycle without layout-generation scans" {
    var core = Core.initForTest(std.testing.allocator);
    defer core.deinitForTest();

    try core.grid.resizeGrid(2, 2, 1);
    try core.grid.putSyntheticExternal(2, .{ .win = 2, .start_row = 0, .start_col = 0 });
    try beginVertexBudgetTransaction(&core);
    const surface = core.grid.sub_grids.getPtr(2).?;
    try replaceSubgridSurfaceRowVertexCount(&core, 2, surface, 0, 10);
    try replaceSubgridSurfaceRowVertexCount(&core, 2, surface, 1, 20);
    try validateCompletedVertexBudget(&core);
    finishVertexBudgetTransaction(&core, true);
    try std.testing.expectEqual(@as(usize, 30), core.grid.subgrid_surface_vertex_count);

    core.grid.scrollGrid(2, 0, 2, 0, 1, 1, 0);
    try std.testing.expectEqual(@as(usize, 20), surface.surface_vertex_count);
    try std.testing.expectEqual(@as(usize, 20), core.grid.subgrid_surface_vertex_count);

    // Layout order changes do not affect physical surface membership or
    // require an external-grid rescan at the next transaction boundary.
    core.grid.layout_generation +%= 1;
    try beginVertexBudgetTransaction(&core);
    try std.testing.expectEqual(@as(usize, 20), core.flush_vertex_count_aggregate);
    finishVertexBudgetTransaction(&core, true);

    try std.testing.expect(try core.grid.removeSyntheticExternal(2));
    try std.testing.expectEqual(@as(usize, 0), core.grid.subgrid_surface_vertex_count);
    try std.testing.expectEqual(@as(usize, 0), surface.surface_vertex_count);
    try std.testing.expect(!surface.vertex_row_ledger_valid);
}

test "deferred external pass shares the main vertex budget transaction" {
    const State = struct {
        core: *Core,
        main_rows: u32 = 0,
        external_rows: u32 = 0,
        external_saw_shared_transaction: bool = false,

        fn onRow(
            ctx: ?*anyopaque,
            grid_id: i64,
            row_start: u32,
            row_count: u32,
            verts: ?[*]const c_api.Vertex,
            vert_count: usize,
            flags: u32,
            total_rows: u32,
            total_cols: u32,
        ) callconv(.c) void {
            _ = row_start;
            _ = row_count;
            _ = verts;
            _ = vert_count;
            _ = flags;
            _ = total_rows;
            _ = total_cols;
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            if (grid_id == 1) {
                self.main_rows += 1;
            } else if (grid_id == 2) {
                self.external_rows += 1;
                self.external_saw_shared_transaction = self.core.vertex_budget_transaction_active;
            }
        }
    };

    var core = Core.initForTest(std.testing.allocator);
    defer core.deinitForTest();
    defer core.known_external_grids.deinit(core.alloc);
    try core.grid.resizeGrid(1, 1, 1);
    try core.grid.resizeGrid(2, 1, 1);
    try core.grid.putSyntheticExternal(2, .{ .win = 2, .start_row = 0, .start_col = 0 });
    try core.known_external_grids.put(core.alloc, 2, .{
        .win = 2,
        .start_row = 0,
        .start_col = 0,
        .rows = 1,
        .cols = 1,
    });
    core.drawable_w_px = 1;
    core.drawable_h_px = 1;
    core.cell_w_px = 1;
    core.cell_h_px = 1;
    core.grid.cursor_visible = false;

    var state = State{ .core = &core };
    core.ctx = &state;
    core.cb.on_vertices_row = State.onRow;

    var flush_ctx = FlushCtx{ .core = &core };
    try flush_ctx.onFlush(1, 1);

    try std.testing.expectEqual(@as(u32, 1), state.main_rows);
    try std.testing.expectEqual(@as(u32, 1), state.external_rows);
    try std.testing.expect(state.external_saw_shared_transaction);
    try std.testing.expect(!core.vertex_budget_transaction_active);
}

test "sparse vertex ledger update touches only the submitted row" {
    const row_count = 20_000;
    const untouched_count: usize = 7;
    var core = Core.initForTest(std.testing.allocator);
    defer core.deinitForTest();
    try core.ensureScrollCache(row_count);
    @memset(core.main_vertex_row_counts.items, untouched_count);
    core.main_surface_vertex_count = row_count * untouched_count;

    try beginVertexBudgetTransaction(&core);
    try replaceMainSurfaceRowVertexCount(&core, row_count / 2, 11);
    try validateCompletedVertexBudget(&core);
    finishVertexBudgetTransaction(&core, true);

    try std.testing.expectEqual(@as(usize, 11), core.main_vertex_row_counts.items[row_count / 2]);
    try std.testing.expectEqual(untouched_count, core.main_vertex_row_counts.items[0]);
    try std.testing.expectEqual(untouched_count, core.main_vertex_row_counts.items[row_count - 1]);
    try std.testing.expectEqual(row_count * untouched_count + 4, core.main_surface_vertex_count);
}

test "scroll callback abort consumes only dispatched IDs" {
    const State = struct {
        core: *Core,
        abort_scroll: bool = true,
        scroll_calls: u32 = 0,
        ids: [2]i64 = .{ 0, 0 },

        fn onScroll(ctx: ?*anyopaque, grid_id: i64, rows_delta: i32) callconv(.c) void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            _ = rows_delta;
            self.ids[self.scroll_calls] = grid_id;
            self.scroll_calls += 1;
            if (self.abort_scroll) self.core.flush_aborted = true;
        }
    };

    var core = Core.initForTest(std.testing.allocator);
    defer core.deinitForTest();
    try core.grid.resizeGrid(1, 3, 3);
    try core.grid.resizeGrid(2, 3, 3);
    var state = State{ .core = &core };
    core.ctx = &state;
    core.cb.on_grid_scroll = State.onScroll;
    core.grid.scrollGrid(1, 0, 3, 0, 3, 1, 0);
    core.grid.scrollGrid(2, 0, 3, 0, 3, 1, 0);

    var flush_ctx = FlushCtx{ .core = &core };
    try flush_ctx.onFlush(3, 3);
    try std.testing.expectEqual(@as(u32, 1), state.scroll_calls);
    try std.testing.expectEqual(@as(i64, 1), state.ids[0]);
    try std.testing.expect(!core.grid.main_scroll_notify_pending);
    try std.testing.expect(core.grid.sub_grids.get(2).?.scroll_notify_pending);
    try std.testing.expectEqual(@as(u8, 1), core.grid.scrolled_grid_count);
    try std.testing.expectEqual(@as(i64, 2), core.grid.scrolled_grid_ids[0]);

    state.abort_scroll = false;
    try flush_ctx.onFlush(3, 3);
    try std.testing.expectEqual(@as(u32, 2), state.scroll_calls);
    try std.testing.expectEqual(@as(i64, 2), state.ids[1]);
    try std.testing.expect(!core.grid.sub_grids.get(2).?.scroll_notify_pending);
}

test "flush transaction orders begin vertices end and restores state on every abort point" {
    const State = struct {
        const AbortAt = enum { none, begin, vertices, end };

        core: *Core,
        abort_at: AbortAt,
        events: [3]u8 = .{ 0, 0, 0 },
        event_count: usize = 0,

        fn push(self: *@This(), event: u8) void {
            self.events[self.event_count] = event;
            self.event_count += 1;
        }

        fn onBegin(ctx: ?*anyopaque) callconv(.c) void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            self.push('B');
            if (self.abort_at == .begin) self.core.flush_aborted = true;
        }

        fn onVertices(
            ctx: ?*anyopaque,
            main_verts: ?[*]const c_api.Vertex,
            main_count: usize,
            cursor_verts: ?[*]const c_api.Vertex,
            cursor_count: usize,
            flags: u32,
        ) callconv(.c) void {
            _ = main_verts;
            _ = main_count;
            _ = cursor_verts;
            _ = cursor_count;
            _ = flags;
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            self.push('V');
            if (self.abort_at == .vertices) self.core.flush_aborted = true;
        }

        fn onEnd(ctx: ?*anyopaque) callconv(.c) void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            self.push('E');
            if (self.abort_at == .end) self.core.flush_aborted = true;
        }
    };

    const cases = [_]State.AbortAt{ .none, .begin, .vertices, .end };
    for (cases) |abort_at| {
        var core = Core.initForTest(std.testing.allocator);
        defer core.deinitForTest();
        try core.grid.resizeGrid(1, 1, 1);
        core.grid.putCell(0, 0, 'A', 0);
        core.drawable_w_px = 1;
        core.drawable_h_px = 1;
        core.cell_w_px = 1;
        core.cell_h_px = 1;

        var state = State{ .core = &core, .abort_at = .none };
        core.ctx = &state;
        core.cb.on_flush_begin = State.onBegin;
        core.cb.on_vertices_partial = State.onVertices;
        core.cb.on_flush_end = State.onEnd;

        var flush_ctx = FlushCtx{ .core = &core };
        try flush_ctx.onFlush(1, 1);
        try std.testing.expect(!core.grid.dirty_all);
        const committed_vertex_count = core.main_surface_vertex_count;
        try std.testing.expect(committed_vertex_count > 0);

        state.abort_at = abort_at;
        state.event_count = 0;
        core.grid.putCell(0, 0, 'B', 0);
        try flush_ctx.onFlush(1, 1);

        if (abort_at == .begin) {
            try std.testing.expectEqualSlices(u8, "BE", state.events[0..state.event_count]);
        } else {
            try std.testing.expectEqualSlices(u8, "BVE", state.events[0..state.event_count]);
        }

        if (abort_at == .none) {
            try std.testing.expect(!core.flush_aborted);
            try std.testing.expect(!core.grid.dirty_all);
            try std.testing.expectEqual(core.grid.content_rev, core.last_sent_content_rev);
            try std.testing.expect(core.main_surface_vertex_count > 0);
        } else if (abort_at == .begin) {
            try std.testing.expect(core.flush_aborted);
            try std.testing.expect(!core.grid.dirty_all);
            try std.testing.expect(core.grid.dirty_rows.isSet(0));
            try std.testing.expect(core.grid.content_rev != core.last_sent_content_rev);
            try std.testing.expect(core.main_vertex_row_ledger_valid);
            try std.testing.expectEqual(committed_vertex_count, core.main_surface_vertex_count);
        } else {
            // A vertices/end rejection is a publication refusal too: the
            // frontend still shows the previously committed frame, so the
            // retry owes exactly the rows this attempt consumed and the
            // accounting describing that frame survives.
            try std.testing.expect(core.flush_aborted);
            try std.testing.expect(!core.grid.dirty_all);
            try std.testing.expect(core.grid.dirty_rows.isSet(0));
            try std.testing.expect(core.grid.content_rev != core.last_sent_content_rev or abort_at == .end);
            try std.testing.expect(core.main_vertex_row_ledger_valid);
            try std.testing.expectEqual(committed_vertex_count, core.main_surface_vertex_count);
        }
    }
}

test "external row scroll hint excludes composited grids and clamps target viewport" {
    const State = struct {
        calls: u32 = 0,
        grid_id: i64 = 0,
        row_start: u32 = 0,
        row_end: u32 = 0,
        col_start: u32 = 0,
        col_end: u32 = 0,
        rows_delta: i32 = 0,
        total_rows: u32 = 0,
        total_cols: u32 = 0,

        fn onRowScroll(
            ctx: ?*anyopaque,
            grid_id: i64,
            row_start: u32,
            row_end: u32,
            col_start: u32,
            col_end: u32,
            rows_delta: i32,
            total_rows: u32,
            total_cols: u32,
        ) callconv(.c) void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            self.calls += 1;
            self.grid_id = grid_id;
            self.row_start = row_start;
            self.row_end = row_end;
            self.col_start = col_start;
            self.col_end = col_end;
            self.rows_delta = rows_delta;
            self.total_rows = total_rows;
            self.total_cols = total_cols;
        }
    };

    var core = Core.initForTest(std.testing.allocator);
    defer core.deinitForTest();
    defer core.known_external_grids.deinit(core.alloc);
    try core.grid.resizeGrid(1, 4, 4);
    try core.grid.resizeGrid(2, 4, 4);
    try core.grid.setWinPos(2, 42, 0, 0);
    var state = State{};
    core.ctx = &state;

    core.grid.scrollGrid(2, 0, 4, 0, 4, 1, 0);
    try std.testing.expect(!dispatchGridRowScroll(&core, State.onRowScroll, 2, &.{}));
    try std.testing.expectEqual(@as(u32, 0), state.calls);

    core.grid.sub_grids.getPtr(2).?.clearScrollState();
    try std.testing.expect(try core.grid.setWinExternalPos(2, 42));
    // During a resize transition the retained GridBuf may still be wider and
    // taller than the frontend target viewport. The callback rectangle must
    // describe the visible surface so its full-width eligibility check agrees
    // with the core's external-row fast path.
    try core.grid.external_grid_target_sizes.put(core.alloc, 2, .{ .rows = 3, .cols = 2 });
    core.grid.scrollGrid(2, 0, 4, 0, 4, 1, 0);
    try std.testing.expect(!dispatchGridRowScroll(&core, State.onRowScroll, 2, &.{}));
    try std.testing.expectEqual(@as(u32, 0), state.calls);
    try core.known_external_grids.put(core.alloc, 2, .{
        .win = 42,
        .start_row = 0,
        .start_col = 0,
        .rows = 3,
        .cols = 2,
    });
    try std.testing.expect(dispatchGridRowScroll(&core, State.onRowScroll, 2, &.{}));
    try std.testing.expectEqual(@as(u32, 1), state.calls);
    try std.testing.expectEqual(@as(i64, 2), state.grid_id);
    try std.testing.expectEqual(@as(u32, 0), state.row_start);
    try std.testing.expectEqual(@as(u32, 3), state.row_end);
    try std.testing.expectEqual(@as(u32, 0), state.col_start);
    try std.testing.expectEqual(@as(u32, 2), state.col_end);
    try std.testing.expectEqual(@as(i32, 1), state.rows_delta);
    try std.testing.expectEqual(@as(u32, 3), state.total_rows);
    try std.testing.expectEqual(@as(u32, 2), state.total_cols);
}

test "external row scroll eligibility fails closed on non-representable regions" {
    const full = grid_mod.ScrollDelta{
        .top = 0,
        .bot = 4,
        .left = 0,
        .right = 4,
        .rows = 1,
        .cols = 0,
    };
    try std.testing.expectEqualDeep(
        ExternalScrollFastPathRegion{
            .row_start = 0,
            .row_end = 2,
            .col_start = 0,
            .col_end = 2,
        },
        externalScrollFastPathRegion(full, 4, 4, 2, 2).?,
    );

    var invalid = full;
    invalid.left = 1;
    try std.testing.expect(externalScrollFastPathRegion(invalid, 4, 4, 2, 2) == null);
    invalid = full;
    invalid.right = 1;
    try std.testing.expect(externalScrollFastPathRegion(invalid, 4, 4, 2, 2) == null);
    invalid = full;
    invalid.top = 1;
    try std.testing.expect(externalScrollFastPathRegion(invalid, 4, 4, 2, 2) == null);

    inline for (.{ @as(i32, 0), 2, -2, std.math.minInt(i32) }) |rows_delta| {
        invalid = full;
        invalid.rows = rows_delta;
        try std.testing.expect(externalScrollFastPathRegion(invalid, 4, 4, 2, 2) == null);
    }
    invalid = full;
    invalid.cols = 1;
    try std.testing.expect(externalScrollFastPathRegion(invalid, 4, 4, 2, 2) == null);
    try std.testing.expect(externalScrollFastPathRegion(full, 4, 4, 5, 2) == null);
    try std.testing.expect(externalScrollFastPathRegion(full, 4, 4, 2, 5) == null);
}

test "row-only vertex consumer receives main rows and cursor layer" {
    const State = struct {
        main_calls: u32 = 0,
        cursor_calls: u32 = 0,

        fn onRow(
            ctx: ?*anyopaque,
            grid_id: i64,
            row_start: u32,
            row_count: u32,
            verts: ?[*]const c_api.Vertex,
            vert_count: usize,
            flags: u32,
            total_rows: u32,
            total_cols: u32,
        ) callconv(.c) void {
            _ = row_start;
            _ = row_count;
            _ = verts;
            _ = vert_count;
            _ = total_rows;
            _ = total_cols;
            if (grid_id != 1) return;
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            if (flags & c_api.VERT_UPDATE_MAIN != 0) self.main_calls += 1;
            if (flags & c_api.VERT_UPDATE_CURSOR != 0) self.cursor_calls += 1;
        }
    };

    var core = Core.initForTest(std.testing.allocator);
    defer core.deinitForTest();
    try core.grid.resizeGrid(1, 2, 2);
    core.grid.putCell(0, 0, 'A', 0);
    core.grid.setCursor(1, 0, 0);
    core.drawable_w_px = 2;
    core.drawable_h_px = 2;
    core.cell_w_px = 1;
    core.cell_h_px = 1;
    var state = State{};
    core.ctx = &state;
    core.cb.on_vertices_row = State.onRow;
    try std.testing.expect(core.cb.on_vertices_partial == null);

    var flush_ctx = FlushCtx{ .core = &core };
    try flush_ctx.onFlush(2, 2);
    try std.testing.expect(state.main_calls >= 2);
    try std.testing.expectEqual(@as(u32, 1), state.cursor_calls);
}

test "standalone subgrid clear emits each covered retained main row" {
    const State = struct {
        seen_rows: [5]bool = .{false} ** 5,

        fn onRow(
            ctx: ?*anyopaque,
            grid_id: i64,
            row_start: u32,
            row_count: u32,
            verts: ?[*]const c_api.Vertex,
            vert_count: usize,
            flags: u32,
            total_rows: u32,
            total_cols: u32,
        ) callconv(.c) void {
            _ = verts;
            _ = vert_count;
            _ = total_rows;
            _ = total_cols;
            if (grid_id != 1 or flags & c_api.VERT_UPDATE_MAIN == 0) return;
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            var row = row_start;
            while (row < row_start + row_count and row < self.seen_rows.len) : (row += 1) {
                self.seen_rows[row] = true;
            }
        }
    };

    var core = Core.initForTest(std.testing.allocator);
    defer core.deinitForTest();
    try core.grid.resizeGrid(1, 5, 5);
    try core.grid.resizeGrid(2, 2, 2);
    try core.grid.setWinPos(2, 42, 1, 2);
    core.grid.putCellGrid(2, 0, 0, 'X', 0);
    core.grid.putCellGrid(2, 1, 0, 'Y', 0);
    core.grid.cursor_visible = false;
    core.drawable_w_px = 5;
    core.drawable_h_px = 5;
    core.cell_w_px = 1;
    core.cell_h_px = 1;
    var state = State{};
    core.ctx = &state;
    core.cb.on_vertices_row = State.onRow;
    var flush_ctx = FlushCtx{ .core = &core };

    try flush_ctx.onFlush(5, 5);
    state = .{};
    core.grid.clearGrid(2);
    try flush_ctx.onFlush(5, 5);

    try std.testing.expectEqual([5]bool{ false, true, true, false, false }, state.seen_rows);
}

test "viewport decoration flags exclude all four margins" {
    const margins = grid_mod.ViewportMargins{ .top = 1, .bottom = 1, .left = 1, .right = 1 };
    var flags: [5]u32 = undefined;

    setViewportRowDecoFlags(&flags, 0, 4, 5, margins);
    try std.testing.expectEqual([5]u32{ 0, 0, 0, 0, 0 }, flags);
    setViewportRowDecoFlags(&flags, 1, 4, 5, margins);
    try std.testing.expectEqual([5]u32{
        0,
        c_api.DECO_SCROLLABLE,
        c_api.DECO_SCROLLABLE,
        c_api.DECO_SCROLLABLE,
        0,
    }, flags);
    setViewportRowDecoFlags(&flags, 3, 4, 5, margins);
    try std.testing.expectEqual([5]u32{ 0, 0, 0, 0, 0 }, flags);
    try std.testing.expect(!viewportCellScrollable(1, 0, 4, 5, margins));
    try std.testing.expect(!viewportCellScrollable(1, 4, 4, 5, margins));
    try std.testing.expect(viewportCellScrollable(2, 2, 4, 5, margins));
}

test "row generation rejects before vertex capacity exceeds callback budget" {
    var core = Core.initForTest(std.testing.allocator);
    defer core.deinitForTest();
    try core.row_cells.ensureTotalCapacity(core.alloc, 3);
    core.row_cells.setLen(3);
    for (0..3) |col| {
        core.row_cells.set(
            col,
            ' ',
            0xFFFFFF,
            @intCast(col + 1),
            highlight.Highlights.SP_NOT_SET,
            1,
            0,
            0,
        );
        core.row_cells.deco_base_flags.items[col] = 0;
        core.row_cells.glow_arr.items[col] = 0;
    }

    var out: std.ArrayListUnmanaged(c_api.Vertex) = .empty;
    defer out.deinit(core.alloc);
    try std.testing.expectError(error.VertexBudgetExceeded, generateRowVertices(&core, .{
        .row = 0,
        .cols = 3,
        .vw = 3,
        .vh = 1,
        .cell_w = 1,
        .cell_h = 1,
        .top_pad = 0,
        .default_bg = 0,
        .blur_enabled = false,
        .background_opacity = 1,
        .is_cmdline = false,
        .glow_enabled = false,
        .max_vertices = 12,
    }, &out));
    try std.testing.expectEqual(@as(usize, 12), out.items.len);
    try std.testing.expect(out.capacity <= 12);
    try std.testing.expect(!core.flush_retryable);
}

test "row generation preserves left and right margin flags in every emitted layer" {
    const State = struct {
        fn ensure(ctx: ?*anyopaque, scalar: u32, out_entry: *c_api.GlyphEntry) callconv(.c) c_int {
            _ = ctx;
            _ = scalar;
            out_entry.* = std.mem.zeroes(c_api.GlyphEntry);
            return 0;
        }

        fn expectLayer(vertices: []const c_api.Vertex, required_deco: u32) !void {
            try std.testing.expect(vertices.len != 0);
            try std.testing.expectEqual(@as(usize, 0), vertices.len % 6);
            var quad_start: usize = 0;
            while (quad_start < vertices.len) : (quad_start += 6) {
                const quad = vertices[quad_start..][0..6];
                const flags = quad[0].deco_flags;
                for (quad[1..]) |vertex| try std.testing.expectEqual(flags, vertex.deco_flags);
                try std.testing.expectEqual(required_deco, flags & required_deco);

                var min_x = quad[0].position[0];
                var max_x = min_x;
                for (quad[1..]) |vertex| {
                    min_x = @min(min_x, vertex.position[0]);
                    max_x = @max(max_x, vertex.position[0]);
                }
                const center_x_px = ((min_x + max_x) * 0.5 + 1.0) * 2.5;
                const expected_scrollable = center_x_px >= 1.0 and center_x_px < 4.0;
                try std.testing.expectEqual(expected_scrollable, flags & c_api.DECO_SCROLLABLE != 0);
            }
        }
    };

    var core = Core.initForTest(std.testing.allocator);
    defer core.deinitForTest();
    try core.row_cells.ensureTotalCapacity(core.alloc, 5);
    core.row_cells.setLen(5);
    const style = STYLE_UNDERLINE | STYLE_STRIKETHROUGH;
    for (0..5) |col| {
        const deco: u32 = if (col >= 1 and col < 4) c_api.DECO_SCROLLABLE else 0;
        core.row_cells.set(
            col,
            0x2588,
            0xFFFFFF,
            0x010203,
            highlight.Highlights.SP_NOT_SET,
            1,
            style,
            1,
        );
        core.row_cells.deco_base_flags.items[col] = deco;
        core.row_cells.glow_arr.items[col] = 0;
    }
    core.cb.on_atlas_ensure_glyph = State.ensure;

    var out: std.ArrayListUnmanaged(c_api.Vertex) = .empty;
    defer out.deinit(core.alloc);
    const stats = try generateRowVertices(&core, .{
        .row = 0,
        .cols = 5,
        .vw = 5,
        .vh = 1,
        .cell_w = 1,
        .cell_h = 1,
        .top_pad = 0,
        .default_bg = 0,
        .blur_enabled = false,
        .background_opacity = 1,
        .is_cmdline = false,
        .glow_enabled = false,
    }, &out);

    const starts = [5]usize{
        0,
        stats.pass_ends[0],
        stats.pass_ends[1],
        stats.pass_ends[2],
        stats.pass_ends[3],
    };
    const required = [5]u32{
        0,
        c_api.DECO_UNDERLINE,
        0,
        c_api.DECO_STRIKETHROUGH,
        c_api.DECO_OVERLINE,
    };
    for (starts, stats.pass_ends, required) |start, end, deco| {
        try State.expectLayer(out.items[start..end], deco);
    }
}

test "external anchored float keeps its own viewport margin flags" {
    const State = struct {
        fixed_vertices: usize = 0,
        scrollable_vertices: usize = 0,

        fn onRow(
            ctx: ?*anyopaque,
            grid_id: i64,
            row_start: u32,
            row_count: u32,
            verts: ?[*]const c_api.Vertex,
            vert_count: usize,
            flags: u32,
            total_rows: u32,
            total_cols: u32,
        ) callconv(.c) void {
            _ = row_start;
            _ = row_count;
            _ = flags;
            _ = total_rows;
            _ = total_cols;
            if (grid_id != 2 or verts == null) return;
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            for (verts.?[0..vert_count]) |vertex| {
                if (vertex.grid_id != 3) continue;
                if (vertex.deco_flags & c_api.DECO_SCROLLABLE != 0) {
                    self.scrollable_vertices += 1;
                } else {
                    self.fixed_vertices += 1;
                }
            }
        }
    };

    var core = Core.initForTest(std.testing.allocator);
    defer core.deinitForTest();
    try core.grid.resizeGrid(2, 1, 5);
    try core.grid.putSyntheticExternal(2, .{
        .win = 42,
        .start_row = 0,
        .start_col = 0,
    });
    try core.grid.resizeGrid(3, 1, 3);
    try core.grid.setWinFloatPos(3, 43, 0, 1, 10, 0, 2);
    try core.grid.setViewportMargins(3, 0, 0, 1, 1);
    core.cell_w_px = 1;
    core.cell_h_px = 1;
    core.grid.cursor_visible = false;

    var state = State{};
    core.ctx = &state;
    core.cb.on_vertices_row = State.onRow;
    core.sendExternalGridVertices(true);

    try std.testing.expectEqual(@as(usize, 12), state.fixed_vertices);
    try std.testing.expectEqual(@as(usize, 6), state.scrollable_vertices);
}

test "margin-only change emits retained main rows" {
    const State = struct {
        main_calls: u32 = 0,

        fn onRow(
            ctx: ?*anyopaque,
            grid_id: i64,
            row_start: u32,
            row_count: u32,
            verts: ?[*]const c_api.Vertex,
            vert_count: usize,
            flags: u32,
            total_rows: u32,
            total_cols: u32,
        ) callconv(.c) void {
            _ = row_start;
            _ = verts;
            _ = vert_count;
            _ = total_rows;
            _ = total_cols;
            if (grid_id != 1 or flags & c_api.VERT_UPDATE_MAIN == 0) return;
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            self.main_calls += row_count;
        }
    };

    var core = Core.initForTest(std.testing.allocator);
    defer core.deinitForTest();
    try core.grid.resizeGrid(1, 3, 4);
    core.grid.cursor_visible = false;
    core.drawable_w_px = 4;
    core.drawable_h_px = 3;
    core.cell_w_px = 1;
    core.cell_h_px = 1;
    var state = State{};
    core.ctx = &state;
    core.cb.on_vertices_row = State.onRow;
    var flush_ctx = FlushCtx{ .core = &core };

    try flush_ctx.onFlush(3, 4);
    state = .{};
    try core.grid.setViewportMargins(1, 1, 1, 1, 1);
    try flush_ctx.onFlush(3, 4);
    try std.testing.expectEqual(@as(u32, 3), state.main_calls);
}

test "external scroll without row-shift callback regenerates every retained row" {
    const State = struct {
        row_calls: u32 = 0,
        scroll_calls: u32 = 0,
        seen_rows: [4]bool = .{false} ** 4,

        fn onRow(
            ctx: ?*anyopaque,
            grid_id: i64,
            row_start: u32,
            row_count: u32,
            verts: ?[*]const c_api.Vertex,
            vert_count: usize,
            flags: u32,
            total_rows: u32,
            total_cols: u32,
        ) callconv(.c) void {
            _ = verts;
            _ = vert_count;
            _ = total_rows;
            _ = total_cols;
            if (grid_id != 2 or flags & c_api.VERT_UPDATE_MAIN == 0) return;
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            self.row_calls += row_count;
            var row = row_start;
            while (row < row_start + row_count and row < self.seen_rows.len) : (row += 1) {
                self.seen_rows[row] = true;
            }
        }

        fn onRowScroll(
            ctx: ?*anyopaque,
            grid_id: i64,
            row_start: u32,
            row_end: u32,
            col_start: u32,
            col_end: u32,
            rows_delta: i32,
            total_rows: u32,
            total_cols: u32,
        ) callconv(.c) void {
            _ = grid_id;
            _ = row_start;
            _ = row_end;
            _ = col_start;
            _ = col_end;
            _ = rows_delta;
            _ = total_rows;
            _ = total_cols;
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            self.scroll_calls += 1;
        }
    };

    var core = Core.initForTest(std.testing.allocator);
    defer core.deinitForTest();
    defer core.known_external_grids.deinit(core.alloc);
    try core.grid.resizeGrid(1, 4, 2);
    try core.grid.resizeGrid(2, 4, 2);
    try std.testing.expect(try core.grid.setWinExternalPos(2, 42));
    try core.known_external_grids.put(core.alloc, 2, .{
        .win = 42,
        .start_row = 0,
        .start_col = 0,
        .rows = 4,
        .cols = 2,
    });
    for (0..4) |row| {
        core.grid.putCellGrid(2, @intCast(row), 0, @intCast('A' + row), 0);
    }
    core.drawable_w_px = 2;
    core.drawable_h_px = 4;
    core.cell_w_px = 1;
    core.cell_h_px = 1;
    core.grid.cursor_visible = false;

    var state = State{};
    core.ctx = &state;
    core.cb.on_vertices_row = State.onRow;
    try std.testing.expect(core.cb.on_grid_row_scroll == null);

    // Seed the retained external surface, then isolate the scroll update.
    core.sendExternalGridVertices(true);
    try std.testing.expectEqual(@as(u32, 4), state.row_calls);
    state = .{};

    core.grid.scrollGrid(2, 0, 4, 0, 2, 1, 0);
    core.sendExternalGridVertices(false);
    try std.testing.expectEqual(@as(u32, 4), state.row_calls);
    try std.testing.expectEqual([4]bool{ true, true, true, true }, state.seen_rows);

    // A float anchored to the external grid must suppress both sides of the
    // retained-row protocol even when it is outside the visible row index.
    // Otherwise generation sends only the vacated row while dispatch refuses
    // the shift callback, leaving every retained row stale.
    core.grid.sub_grids.getPtr(2).?.clearScrollState();
    try core.grid.resizeGrid(3, 1, 1);
    try core.grid.setWinFloatPos(3, 43, 100, 0, 10, 0, 2);
    core.cb.on_grid_row_scroll = State.onRowScroll;
    core.sendExternalGridVertices(true);
    state = .{};

    core.grid.sub_grids.getPtr(2).?.clearScrollState();
    core.grid.scrollGrid(2, 0, 4, 0, 2, 1, 0);
    try buildExternalFloatAnchorIndex(&core);
    const anchor_entries = externalFloatAnchorEntries(core.ext_float_anchor_entries.items, 2);
    try std.testing.expectEqual(@as(usize, 1), anchor_entries.len);
    try std.testing.expect(!dispatchGridRowScroll(&core, State.onRowScroll, 2, anchor_entries));
    core.ext_float_anchor_index_valid = false;
    core.sendExternalGridVertices(false);
    try std.testing.expectEqual(@as(u32, 0), state.scroll_calls);
    try std.testing.expectEqual(@as(u32, 4), state.row_calls);
    try std.testing.expectEqual([4]bool{ true, true, true, true }, state.seen_rows);
}

test "cursor Phase 2 glyphs reuse persistent scalar and cluster cache entries" {
    const State = struct {
        raster_calls: u32 = 0,

        fn rasterize(
            ctx: ?*anyopaque,
            scalar: u32,
            style_flags: u32,
            out_bitmap: *c_api.GlyphBitmap,
        ) callconv(.c) c_int {
            _ = scalar;
            _ = style_flags;
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            self.raster_calls += 1;
            out_bitmap.* = .{
                .pixels = null,
                .width = 1,
                .height = 1,
                .pitch = 1,
                .bearing_x = 0,
                .bearing_y = 1,
                .advance_26_6 = 64,
                .ascent_px = 1,
                .descent_px = 0,
                .bytes_per_pixel = 1,
            };
            return 1;
        }

        fn upload(
            ctx: ?*anyopaque,
            dest_x: u32,
            dest_y: u32,
            width: u32,
            height: u32,
            bitmap: *const c_api.GlyphBitmap,
        ) callconv(.c) void {
            _ = ctx;
            _ = dest_x;
            _ = dest_y;
            _ = width;
            _ = height;
            _ = bitmap;
        }

        fn create(ctx: ?*anyopaque, atlas_w: u32, atlas_h: u32) callconv(.c) void {
            _ = ctx;
            _ = atlas_w;
            _ = atlas_h;
        }
    };

    var core = Core.initForTest(std.testing.allocator);
    defer core.deinitForTest();
    var state = State{};
    core.ctx = &state;
    core.cb.on_rasterize_glyph = State.rasterize;
    core.cb.on_atlas_upload = State.upload;
    core.cb.on_atlas_create = State.create;

    try std.testing.expect(try ensureCachedPhase2Glyph(&core, 'A', 0, null) != null);
    try std.testing.expect(try ensureCachedPhase2Glyph(&core, 'A', 0, null) != null);
    try std.testing.expectEqual(@as(u32, 1), state.raster_calls);

    const cluster_a = [_]u32{ 0x200D, 0x1F4BB };
    const cluster_b = [_]u32{ 0x200D, 0x1F52C };
    try std.testing.expect(try ensureCachedPhase2Glyph(&core, 0x1F469, 0, &cluster_a) != null);
    try std.testing.expect(try ensureCachedPhase2Glyph(&core, 0x1F469, 0, &cluster_a) != null);
    try std.testing.expect(try ensureCachedPhase2Glyph(&core, 0x1F469, 0, &cluster_b) != null);
    try std.testing.expectEqual(@as(u32, 3), state.raster_calls);
}

test "cursor Phase 2 cache uses canonical ASCII slots and row glyph IDs" {
    const State = struct {
        shape_calls: u32 = 0,
        by_id_calls: u32 = 0,
        scalar_calls: u32 = 0,

        fn shape(
            ctx: ?*anyopaque,
            scalars: [*]const u32,
            scalar_count: usize,
            style_flags: u32,
            out_glyph_ids: [*]u32,
            out_clusters: [*]u32,
            out_x_advance: [*]i32,
            out_x_offset: [*]i32,
            out_y_offset: [*]i32,
            out_cap: usize,
        ) callconv(.c) usize {
            _ = style_flags;
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            self.shape_calls += 1;
            if (out_cap < 1 or scalar_count != 1) return 0;
            out_glyph_ids[0] = if (scalars[0] == 0x4E2D) 78 else 77;
            out_clusters[0] = 0;
            out_x_advance[0] = 64;
            out_x_offset[0] = 0;
            out_y_offset[0] = 0;
            return 1;
        }

        fn rasterById(
            ctx: ?*anyopaque,
            glyph_id: u32,
            style_flags: u32,
            out_bitmap: *c_api.GlyphBitmap,
        ) callconv(.c) c_int {
            _ = glyph_id;
            _ = style_flags;
            _ = out_bitmap;
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            self.by_id_calls += 1;
            return 0;
        }

        fn rasterScalar(
            ctx: ?*anyopaque,
            scalar: u32,
            style_flags: u32,
            out_bitmap: *c_api.GlyphBitmap,
        ) callconv(.c) c_int {
            _ = scalar;
            _ = style_flags;
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            self.scalar_calls += 1;
            out_bitmap.* = .{
                .pixels = null,
                .width = 1,
                .height = 1,
                .pitch = 1,
                .bearing_x = 0,
                .bearing_y = 1,
                .advance_26_6 = 64,
                .ascent_px = 1,
                .descent_px = 0,
                .bytes_per_pixel = 1,
            };
            return 1;
        }

        fn upload(
            ctx: ?*anyopaque,
            dest_x: u32,
            dest_y: u32,
            width: u32,
            height: u32,
            bitmap: *const c_api.GlyphBitmap,
        ) callconv(.c) void {
            _ = ctx;
            _ = dest_x;
            _ = dest_y;
            _ = width;
            _ = height;
            _ = bitmap;
        }

        fn create(ctx: ?*anyopaque, width: u32, height: u32) callconv(.c) void {
            _ = ctx;
            _ = width;
            _ = height;
        }
    };

    var core = Core.initForTest(std.testing.allocator);
    defer core.deinitForTest();
    try core.initGlyphCache();

    var ascii_entry = std.mem.zeroes(c_api.GlyphEntry);
    ascii_entry.bbox_size_px = .{ 11, 1 };
    const ascii_index = @as(usize, 'A') * 4 + 1;
    core.glyph_cache_ascii.?[ascii_index] = ascii_entry;
    core.glyph_valid_ascii.?[ascii_index] = true;

    // This was the old style-major slot for bold 'A'. Populate it with a
    // conflicting glyph to prove the cursor no longer aliases that layout.
    var aliased_entry = std.mem.zeroes(c_api.GlyphEntry);
    aliased_entry.bbox_size_px = .{ 22, 1 };
    const old_style_major_index = 128 + @as(usize, 'A');
    core.glyph_cache_ascii.?[old_style_major_index] = aliased_entry;
    core.glyph_valid_ascii.?[old_style_major_index] = true;

    const ascii = (try ensureCachedPhase2Glyph(&core, 'A', c_api.STYLE_BOLD, null)).?;
    try std.testing.expectEqual(@as(f32, 11), ascii.bbox_size_px[0]);

    var state = State{};
    core.ctx = &state;
    core.cb.on_shape_text_run = State.shape;
    core.cb.on_rasterize_glyph_by_id = State.rasterById;
    core.cb.on_rasterize_glyph = State.rasterScalar;
    core.cb.on_atlas_upload = State.upload;
    core.cb.on_atlas_create = State.create;

    const gid: u32 = 77;
    const style_index: u32 = 0;
    const key = (@as(u64, gid) << 2) | style_index;
    const hash = (gid *% 2654435761) ^ style_index;
    const probe = nvim_core.glyphCacheProbe(core.glyph_keys_by_id.?, key, hash);
    var shaped_entry = std.mem.zeroes(c_api.GlyphEntry);
    shaped_entry.bbox_size_px = .{ 7, 1 };
    core.glyph_cache_by_id.?[probe.insert] = shaped_entry;
    core.glyph_keys_by_id.?[probe.insert] = key;

    const first = (try ensureCachedPhase2Glyph(&core, 0x754C, 0, null)).?;
    const second = (try ensureCachedPhase2Glyph(&core, 0x754C, 0, null)).?;
    try std.testing.expectEqual(@as(f32, 7), first.bbox_size_px[0]);
    try std.testing.expectEqual(@as(f32, 7), second.bbox_size_px[0]);
    try std.testing.expectEqual(@as(u32, 1), state.shape_calls);
    try std.testing.expectEqual(@as(u32, 0), state.by_id_calls);

    // A shaped primary-face miss falls back to the scalar/font path without
    // arming a retry storm when the fallback renders successfully.
    const fallback = (try ensureCachedPhase2Glyph(&core, 0x4E2D, 0, null)).?;
    try std.testing.expectEqual(@as(f32, 1), fallback.bbox_size_px[0]);
    try std.testing.expectEqual(@as(u32, 2), state.shape_calls);
    try std.testing.expectEqual(@as(u32, 1), state.by_id_calls);
    try std.testing.expectEqual(@as(u32, 1), state.scalar_calls);
    try std.testing.expect(!core.transient_glyph_has_negative);
}

test "wide block geometry spans continuation across legacy and shaped runs" {
    const State = struct {
        ensure_calls: u32 = 0,
        shape_calls: u32 = 0,
        raster_calls: u32 = 0,

        fn ensure(ctx: ?*anyopaque, scalar: u32, out_entry: *c_api.GlyphEntry) callconv(.c) c_int {
            _ = scalar;
            out_entry.* = std.mem.zeroes(c_api.GlyphEntry);
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            self.ensure_calls += 1;
            return 0;
        }

        fn shape(
            ctx: ?*anyopaque,
            scalars: [*]const u32,
            scalar_count: usize,
            style_flags: u32,
            out_glyph_ids: [*]u32,
            out_clusters: [*]u32,
            out_x_advance: [*]i32,
            out_x_offset: [*]i32,
            out_y_offset: [*]i32,
            out_cap: usize,
        ) callconv(.c) usize {
            _ = scalars;
            _ = scalar_count;
            _ = style_flags;
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            self.shape_calls += 1;
            if (out_cap < 1) return 1;
            out_glyph_ids[0] = 42;
            out_clusters[0] = 0;
            out_x_advance[0] = 128;
            out_x_offset[0] = 0;
            out_y_offset[0] = 0;
            return 1;
        }

        fn raster(
            ctx: ?*anyopaque,
            scalar_or_glyph_id: u32,
            style_flags: u32,
            out_bitmap: *c_api.GlyphBitmap,
        ) callconv(.c) c_int {
            _ = scalar_or_glyph_id;
            _ = style_flags;
            out_bitmap.* = std.mem.zeroes(c_api.GlyphBitmap);
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            self.raster_calls += 1;
            return 0;
        }

        fn upload(
            ctx: ?*anyopaque,
            dest_x: u32,
            dest_y: u32,
            width: u32,
            height: u32,
            bitmap: *const c_api.GlyphBitmap,
        ) callconv(.c) void {
            _ = ctx;
            _ = dest_x;
            _ = dest_y;
            _ = width;
            _ = height;
            _ = bitmap;
        }

        fn create(ctx: ?*anyopaque, width: u32, height: u32) callconv(.c) void {
            _ = ctx;
            _ = width;
            _ = height;
        }
    };

    var core = Core.initForTest(std.testing.allocator);
    defer core.deinitForTest();
    try core.grid.resizeGrid(1, 1, 2);
    try core.row_cells.ensureTotalCapacity(core.alloc, 2);
    core.row_cells.setLen(2);
    core.row_cells.set(0, 0x2588, 0xFFFFFF, 0, highlight.Highlights.SP_NOT_SET, 1, 0, 0);
    // A different color deliberately splits the SIMD run. Width detection is
    // based on Neovim's continuation cell, not the current style/color run.
    core.row_cells.set(1, 0, 0x00FF00, 0, highlight.Highlights.SP_NOT_SET, 1, 0, 0);
    @memset(core.row_cells.deco_base_flags.items, 0);
    @memset(core.row_cells.glow_arr.items, 0);

    var state = State{};
    core.ctx = &state;
    core.cb.on_atlas_ensure_glyph = State.ensure;

    var out: std.ArrayListUnmanaged(c_api.Vertex) = .empty;
    defer out.deinit(core.alloc);
    const params = RowGenParams{
        .row = 0,
        .cols = 2,
        .vw = 20,
        .vh = 10,
        .cell_w = 10,
        .cell_h = 10,
        .top_pad = 0,
        .default_bg = 0,
        .blur_enabled = false,
        .background_opacity = 1,
        .is_cmdline = false,
        .glow_enabled = false,
    };

    const stats = try generateRowVertices(&core, params, &out);
    const glyphs = out.items[stats.pass_ends[1]..stats.pass_ends[2]];
    try std.testing.expectEqual(@as(usize, 6), glyphs.len);
    var min_x: f32 = std.math.inf(f32);
    var max_x: f32 = -std.math.inf(f32);
    for (glyphs) |vertex| {
        min_x = @min(min_x, vertex.position[0]);
        max_x = @max(max_x, vertex.position[0]);
    }
    try std.testing.expectApproxEqAbs(@as(f32, -1), min_x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 1), max_x, 0.001);
    try std.testing.expectEqual(@as(u32, 0), state.ensure_calls);

    // A real space is not a wide-cell continuation.
    core.row_cells.scalars.items[1] = ' ';
    out.clearRetainingCapacity();
    const narrow_stats = try generateRowVertices(&core, params, &out);
    const narrow_glyphs = out.items[narrow_stats.pass_ends[1]..narrow_stats.pass_ends[2]];
    max_x = -std.math.inf(f32);
    for (narrow_glyphs) |vertex| max_x = @max(max_x, vertex.position[0]);
    try std.testing.expectApproxEqAbs(@as(f32, 0), max_x, 0.001);
    try std.testing.expectEqual(@as(u32, 0), state.ensure_calls);

    // The shaping collector must use the same row-wide continuation rule.
    // Bold on the continuation forces a run boundary exactly between the two
    // cells; the base block still owns both columns geometrically.
    core.row_cells.scalars.items[1] = 0;
    core.row_cells.fg_rgbs.items[1] = core.row_cells.fg_rgbs.items[0];
    core.row_cells.style_flags_arr.items[1] = STYLE_BOLD;
    core.cb.on_atlas_ensure_glyph = null;
    core.cb.on_shape_text_run = State.shape;
    core.cb.on_rasterize_glyph = State.raster;
    core.cb.on_rasterize_glyph_by_id = State.raster;
    core.cb.on_atlas_upload = State.upload;
    core.cb.on_atlas_create = State.create;
    out.clearRetainingCapacity();
    const shaped_stats = try generateRowVertices(&core, params, &out);
    const shaped_glyphs = out.items[shaped_stats.pass_ends[1]..shaped_stats.pass_ends[2]];
    max_x = -std.math.inf(f32);
    for (shaped_glyphs) |vertex| max_x = @max(max_x, vertex.position[0]);
    try std.testing.expectApproxEqAbs(@as(f32, 1), max_x, 0.001);
    try std.testing.expectEqual(@as(u32, 1), state.shape_calls);
    try std.testing.expectEqual(@as(u32, 0), state.raster_calls);
}

test "shaping includes overflow tails in input and cache key" {
    const State = struct {
        const Mode = enum { valid, invalid_cluster, failed, empty_by_id };

        mode: Mode = .valid,
        shape_calls: u32 = 0,
        scalar_raster_calls: u32 = 0,
        seen_len: usize = 0,
        seen: [16]u32 = .{0} ** 16,

        fn bitmap(width: u32) c_api.GlyphBitmap {
            return .{
                .pixels = null,
                .width = width,
                .height = if (width == 0) 0 else 1,
                .pitch = @intCast(width),
                .bearing_x = 0,
                .bearing_y = 1,
                .advance_26_6 = 64,
                .ascent_px = 1,
                .descent_px = 0,
                .bytes_per_pixel = 1,
            };
        }

        fn shape(
            ctx: ?*anyopaque,
            scalars: [*]const u32,
            scalar_count: usize,
            style_flags: u32,
            out_glyph_ids: [*]u32,
            out_clusters: [*]u32,
            out_x_advance: [*]i32,
            out_x_offset: [*]i32,
            out_y_offset: [*]i32,
            out_cap: usize,
        ) callconv(.c) usize {
            _ = style_flags;
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            self.shape_calls += 1;
            self.seen_len = @min(scalar_count, self.seen.len);
            @memcpy(self.seen[0..self.seen_len], scalars[0..self.seen_len]);
            if (self.mode == .failed) return 0;
            if (out_cap < 1) return 1;
            out_glyph_ids[0] = 42;
            out_clusters[0] = if (self.mode == .invalid_cluster) 1 else 0;
            out_x_advance[0] = 64;
            out_x_offset[0] = 0;
            out_y_offset[0] = 0;
            return 1;
        }

        fn rasterById(
            ctx: ?*anyopaque,
            glyph_id: u32,
            style_flags: u32,
            out_bitmap: *c_api.GlyphBitmap,
        ) callconv(.c) c_int {
            _ = glyph_id;
            _ = style_flags;
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            out_bitmap.* = bitmap(if (self.mode == .empty_by_id) 0 else 1);
            return 1;
        }

        fn rasterScalar(
            ctx: ?*anyopaque,
            scalar: u32,
            style_flags: u32,
            out_bitmap: *c_api.GlyphBitmap,
        ) callconv(.c) c_int {
            _ = style_flags;
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            self.scalar_raster_calls += 1;
            out_bitmap.* = bitmap(if (scalar == ' ') 0 else 1);
            return 1;
        }

        fn upload(
            ctx: ?*anyopaque,
            dest_x: u32,
            dest_y: u32,
            width: u32,
            height: u32,
            glyph_bitmap: *const c_api.GlyphBitmap,
        ) callconv(.c) void {
            _ = ctx;
            _ = dest_x;
            _ = dest_y;
            _ = width;
            _ = height;
            _ = glyph_bitmap;
        }

        fn create(ctx: ?*anyopaque, width: u32, height: u32) callconv(.c) void {
            _ = ctx;
            _ = width;
            _ = height;
        }
    };

    var core = Core.initForTest(std.testing.allocator);
    defer core.deinitForTest();
    try core.grid.resizeGrid(1, 1, 1);
    try core.row_cells.ensureTotalCapacity(core.alloc, 1);
    core.row_cells.setLen(1);
    core.row_cells.set(0, 'e', 0xFFFFFF, 0, highlight.Highlights.SP_NOT_SET, 1, 0, 0);
    core.row_cells.deco_base_flags.items[0] = c_api.DECO_SCROLLABLE;
    core.row_cells.glow_arr.items[0] = 0;
    try core.initGlyphCache();

    var state = State{};
    core.ctx = &state;
    core.cb.on_shape_text_run = State.shape;
    core.cb.on_rasterize_glyph_by_id = State.rasterById;
    core.cb.on_rasterize_glyph = State.rasterScalar;
    core.cb.on_atlas_upload = State.upload;
    core.cb.on_atlas_create = State.create;

    var out: std.ArrayListUnmanaged(c_api.Vertex) = .empty;
    defer out.deinit(core.alloc);
    const params = RowGenParams{
        .row = 0,
        .cols = 1,
        .vw = 1,
        .vh = 1,
        .cell_w = 1,
        .cell_h = 1,
        .top_pad = 0,
        .default_bg = 0,
        .blur_enabled = false,
        .background_opacity = 1,
        .is_cmdline = false,
        .glow_enabled = false,
    };

    const acute = [_]u32{0x0301};
    try core.grid.putCellGridCluster(1, 0, 0, 'e', 0, &acute);
    _ = try generateRowVertices(&core, params, &out);
    try std.testing.expectEqual(@as(usize, 2), state.seen_len);
    try std.testing.expectEqual(@as(u32, 'e'), state.seen[0]);
    try std.testing.expectEqual(@as(u32, 0x0301), state.seen[1]);
    try std.testing.expectEqual(@as(u32, 1), state.shape_calls);

    out.clearRetainingCapacity();
    _ = try generateRowVertices(&core, params, &out);
    try std.testing.expectEqual(@as(u32, 1), state.shape_calls);

    const grave = [_]u32{0x0300};
    try core.grid.putCellGridCluster(1, 0, 0, 'e', 0, &grave);
    out.clearRetainingCapacity();
    _ = try generateRowVertices(&core, params, &out);
    try std.testing.expectEqual(@as(u32, 2), state.shape_calls);
    try std.testing.expectEqual(@as(u32, 0x0300), state.seen[1]);

    // Malformed clusters are not cached and use the safe per-scalar path.
    core.resetShapeCache();
    state.mode = .invalid_cluster;
    const scalar_calls_before = state.scalar_raster_calls;
    out.clearRetainingCapacity();
    _ = try generateRowVertices(&core, params, &out);
    try std.testing.expect(state.scalar_raster_calls >= scalar_calls_before + 2);
    out.clearRetainingCapacity();
    _ = try generateRowVertices(&core, params, &out);
    try std.testing.expectEqual(@as(u32, 4), state.shape_calls);

    // A callback failure with a space base still draws its combining tail at
    // the base cell origin, not one cell to the right after space advance.
    core.resetShapeCache();
    state.mode = .failed;
    core.row_cells.scalars.items[0] = ' ';
    try core.grid.putCellGridCluster(1, 0, 0, ' ', 0, &acute);
    out.clearRetainingCapacity();
    _ = try generateRowVertices(&core, params, &out);
    try std.testing.expect(out.items.len >= 12);
    try std.testing.expectApproxEqAbs(@as(f32, -1), out.items[out.items.len - 6].position[0], 0.001);

    // The real shaped glyph may also resolve to an empty bitmap. Its
    // multi-scalar fallback must apply the same base anchor rule as .notdef.
    core.resetShapeCache();
    core.resetGlyphCacheFlags();
    state.mode = .empty_by_id;
    out.clearRetainingCapacity();
    _ = try generateRowVertices(&core, params, &out);
    try std.testing.expect(out.items.len >= 12);
    try std.testing.expectApproxEqAbs(@as(f32, -1), out.items[out.items.len - 6].position[0], 0.001);
}

test "partial-only Phase 2 preserves overflow clusters with and without shaping" {
    const State = struct {
        core: *Core,
        partial_calls: u32 = 0,
        scalar_calls: u32 = 0,
        shape_calls: u32 = 0,
        scalar_extras: [2]u32 = .{ 0, 0 },
        shaped_len: usize = 0,
        shaped_scalars: [4]u32 = .{ 0, 0, 0, 0 },
        background_after_glyph: bool = false,

        fn bitmap() c_api.GlyphBitmap {
            return .{
                .pixels = null,
                .width = 1,
                .height = 1,
                .pitch = 1,
                .bearing_x = 0,
                .bearing_y = 1,
                .advance_26_6 = 64,
                .ascent_px = 1,
                .descent_px = 0,
                .bytes_per_pixel = 1,
            };
        }

        fn partial(
            ctx: ?*anyopaque,
            main_verts: ?[*]const c_api.Vertex,
            main_count: usize,
            cursor_verts: ?[*]const c_api.Vertex,
            cursor_count: usize,
            flags: u32,
        ) callconv(.c) void {
            _ = cursor_verts;
            _ = cursor_count;
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            self.partial_calls += 1;
            if (flags & c_api.VERT_UPDATE_MAIN != 0) {
                if (main_verts) |verts| {
                    var saw_glyph = false;
                    for (verts[0..main_count]) |vertex| {
                        if (vertex.texCoord[0] >= 0) {
                            saw_glyph = true;
                        } else if (saw_glyph and vertex.texCoord[0] == -1 and vertex.texCoord[1] == -1) {
                            self.background_after_glyph = true;
                        }
                    }
                }
            }
        }

        fn rasterScalar(
            ctx: ?*anyopaque,
            scalar: u32,
            style_flags: u32,
            out_bitmap: *c_api.GlyphBitmap,
        ) callconv(.c) c_int {
            _ = scalar;
            _ = style_flags;
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            if (self.scalar_calls < self.scalar_extras.len and self.core.emoji_cluster_len > 1) {
                self.scalar_extras[self.scalar_calls] = self.core.emoji_cluster_buf[1];
            }
            self.scalar_calls += 1;
            out_bitmap.* = bitmap();
            return 1;
        }

        fn shape(
            ctx: ?*anyopaque,
            scalars: [*]const u32,
            scalar_count: usize,
            style_flags: u32,
            out_glyph_ids: [*]u32,
            out_clusters: [*]u32,
            out_x_advance: [*]i32,
            out_x_offset: [*]i32,
            out_y_offset: [*]i32,
            out_cap: usize,
        ) callconv(.c) usize {
            _ = style_flags;
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            self.shape_calls += 1;
            self.shaped_len = @min(scalar_count, self.shaped_scalars.len);
            @memcpy(self.shaped_scalars[0..self.shaped_len], scalars[0..self.shaped_len]);
            if (out_cap < 1) return 1;
            out_glyph_ids[0] = 77;
            out_clusters[0] = 0;
            out_x_advance[0] = 64;
            out_x_offset[0] = 0;
            out_y_offset[0] = 0;
            return 1;
        }

        fn rasterById(
            ctx: ?*anyopaque,
            glyph_id: u32,
            style_flags: u32,
            out_bitmap: *c_api.GlyphBitmap,
        ) callconv(.c) c_int {
            _ = ctx;
            _ = glyph_id;
            _ = style_flags;
            out_bitmap.* = bitmap();
            return 1;
        }

        fn upload(
            ctx: ?*anyopaque,
            dest_x: u32,
            dest_y: u32,
            width: u32,
            height: u32,
            glyph_bitmap: *const c_api.GlyphBitmap,
        ) callconv(.c) void {
            _ = ctx;
            _ = dest_x;
            _ = dest_y;
            _ = width;
            _ = height;
            _ = glyph_bitmap;
        }

        fn create(ctx: ?*anyopaque, width: u32, height: u32) callconv(.c) void {
            _ = ctx;
            _ = width;
            _ = height;
        }
    };

    var core = Core.initForTest(std.testing.allocator);
    defer core.deinitForTest();
    try core.grid.resizeGrid(1, 2, 1);
    core.drawable_w_px = 1;
    core.drawable_h_px = 2;
    core.cell_w_px = 1;
    core.cell_h_px = 1;
    core.grid.cursor_visible = false;

    var state = State{ .core = &core };
    core.ctx = &state;
    core.cb.on_vertices_partial = State.partial;
    core.cb.on_rasterize_glyph = State.rasterScalar;
    core.cb.on_atlas_upload = State.upload;
    core.cb.on_atlas_create = State.create;

    var flush_ctx = FlushCtx{ .core = &core };
    try core.grid.putCellGridCluster(1, 0, 0, 'A', 0, &.{0xFE0F});
    try flush_ctx.onFlush(2, 1);
    try std.testing.expectEqual(@as(u32, 1), state.scalar_calls);
    try std.testing.expectEqual(@as(u32, 0xFE0F), state.scalar_extras[0]);

    // Same base scalar, different tail: this must miss the full-cluster key
    // instead of reusing the VS16 glyph cached by the preceding flush.
    try core.grid.putCellGridCluster(1, 0, 0, 'A', 0, &.{0x0301});
    try flush_ctx.onFlush(2, 1);
    try std.testing.expectEqual(@as(u32, 2), state.scalar_calls);
    try std.testing.expectEqual(@as(u32, 0x0301), state.scalar_extras[1]);
    try std.testing.expectEqual(@as(u8, 0), core.emoji_cluster_len);

    // Register shaping on the same partial-only consumer. The shared row
    // generator must include the overflow tail in the shaping input.
    core.resetGlyphCacheFlags();
    core.resetShapeCache();
    core.ascii_tables_valid = true;
    core.cb.on_shape_text_run = State.shape;
    core.cb.on_rasterize_glyph_by_id = State.rasterById;
    try core.grid.putCellGridCluster(1, 0, 0, 'e', 0, &.{0x0301});
    try flush_ctx.onFlush(2, 1);
    try std.testing.expectEqual(@as(u32, 1), state.shape_calls);
    try std.testing.expectEqual(@as(usize, 2), state.shaped_len);
    try std.testing.expectEqualSlices(u32, &.{ 'e', 0x0301 }, state.shaped_scalars[0..2]);
    try std.testing.expectEqual(@as(u32, 3), state.partial_calls);
    try std.testing.expect(!state.background_after_glyph);
}

test "cursor atlas reset cancels current flush before partial commit" {
    const State = struct {
        partial_calls: u32 = 0,

        fn partial(
            ctx: ?*anyopaque,
            main_verts: ?[*]const c_api.Vertex,
            main_count: usize,
            cursor_verts: ?[*]const c_api.Vertex,
            cursor_count: usize,
            flags: u32,
        ) callconv(.c) void {
            _ = main_verts;
            _ = main_count;
            _ = cursor_verts;
            _ = cursor_count;
            _ = flags;
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            self.partial_calls += 1;
        }

        fn rasterize(
            ctx: ?*anyopaque,
            scalar: u32,
            style_flags: u32,
            out_bitmap: *c_api.GlyphBitmap,
        ) callconv(.c) c_int {
            _ = ctx;
            _ = scalar;
            _ = style_flags;
            out_bitmap.* = .{
                .pixels = null,
                .width = 1,
                .height = 1,
                .pitch = 1,
                .bearing_x = 0,
                .bearing_y = 1,
                .advance_26_6 = 64,
                .ascent_px = 1,
                .descent_px = 0,
                .bytes_per_pixel = 1,
            };
            return 1;
        }

        fn upload(
            ctx: ?*anyopaque,
            dest_x: u32,
            dest_y: u32,
            width: u32,
            height: u32,
            bitmap: *const c_api.GlyphBitmap,
        ) callconv(.c) void {
            _ = ctx;
            _ = dest_x;
            _ = dest_y;
            _ = width;
            _ = height;
            _ = bitmap;
        }

        fn create(ctx: ?*anyopaque, atlas_w: u32, atlas_h: u32) callconv(.c) void {
            _ = ctx;
            _ = atlas_w;
            _ = atlas_h;
        }
    };

    var core = Core.initForTest(std.testing.allocator);
    defer core.deinitForTest();
    try core.grid.resizeGrid(1, 1, 1);
    core.grid.putCell(0, 0, 'A', 0);
    core.grid.setCursor(1, 0, 0);
    core.drawable_w_px = 1;
    core.drawable_h_px = 1;
    core.cell_w_px = 1;
    core.cell_h_px = 1;
    core.last_sent_content_rev = core.grid.content_rev;
    core.grid.clearDirty();
    core.last_sent_cursor_rev = core.grid.cursor_rev -% 1;
    core.atlas_w = config.atlas_size_max;
    core.atlas_h = config.atlas_size_max;
    core.atlas_packer = shelf_packer.ShelfPacker.init(core.atlas_w, core.atlas_h);
    core.atlas_packer.?.next_y = config.atlas_size_max;
    core.atlas_initialized = true;
    var state = State{};
    core.ctx = &state;
    core.cb.on_vertices_partial = State.partial;
    core.cb.on_rasterize_glyph = State.rasterize;
    core.cb.on_atlas_upload = State.upload;
    core.cb.on_atlas_create = State.create;

    var flush_ctx = FlushCtx{ .core = &core };
    try flush_ctx.onFlush(1, 1);
    try std.testing.expect(core.flush_atlas_corrupted);
    try std.testing.expect(core.grid.dirty_all);
    try std.testing.expectEqual(@as(u32, 0), state.partial_calls);
}

test "second row-mode atlas reset cancels instead of committing empty rows" {
    const State = struct {
        core: *Core,
        row_calls: u32 = 0,
        empty_main_calls: u32 = 0,
        create_calls: u32 = 0,
        upload_calls: u32 = 0,
        committed_flushes: u32 = 0,
        cancelled_flushes: u32 = 0,

        fn onRow(
            ctx: ?*anyopaque,
            grid_id: i64,
            row_start: u32,
            row_count: u32,
            verts: ?[*]const c_api.Vertex,
            vert_count: usize,
            flags: u32,
            total_rows: u32,
            total_cols: u32,
        ) callconv(.c) void {
            _ = grid_id;
            _ = row_start;
            _ = row_count;
            _ = verts;
            _ = total_rows;
            _ = total_cols;
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            if (flags & c_api.VERT_UPDATE_MAIN != 0) {
                self.row_calls += 1;
                if (vert_count == 0) self.empty_main_calls += 1;
            }
        }

        fn onEnd(ctx: ?*anyopaque) callconv(.c) void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            if (self.core.flush_aborted or self.core.flush_atlas_corrupted) {
                self.cancelled_flushes += 1;
            } else {
                self.committed_flushes += 1;
            }
        }

        fn rasterize(
            ctx: ?*anyopaque,
            scalar: u32,
            style_flags: u32,
            out_bitmap: *c_api.GlyphBitmap,
        ) callconv(.c) c_int {
            _ = ctx;
            _ = scalar;
            _ = style_flags;
            out_bitmap.* = .{
                .pixels = null,
                .width = 1,
                .height = 1,
                .pitch = 1,
                .bearing_x = 0,
                .bearing_y = 1,
                .advance_26_6 = 64,
                .ascent_px = 1,
                .descent_px = 0,
                .bytes_per_pixel = 1,
            };
            return 1;
        }

        fn upload(
            ctx: ?*anyopaque,
            dest_x: u32,
            dest_y: u32,
            width: u32,
            height: u32,
            bitmap: *const c_api.GlyphBitmap,
        ) callconv(.c) void {
            _ = dest_x;
            _ = dest_y;
            _ = width;
            _ = height;
            _ = bitmap;
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            self.upload_calls += 1;
            // Force the next uncached glyph to observe a full packer. The
            // first upload follows 2048→4096 growth; the second glyph is
            // reached only after the row loop restarts at the new generation.
            if (self.upload_calls == 1) {
                self.core.atlas_packer.?.next_x = self.core.atlas_w;
                self.core.atlas_packer.?.next_y = self.core.atlas_h;
                self.core.atlas_packer.?.row_h = 0;
            }
        }

        fn create(ctx: ?*anyopaque, atlas_w: u32, atlas_h: u32) callconv(.c) void {
            _ = atlas_w;
            _ = atlas_h;
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            self.create_calls += 1;
        }
    };

    var core = Core.initForTest(std.testing.allocator);
    defer core.deinitForTest();
    try core.grid.resizeGrid(1, 2, 1);
    core.grid.putCell(0, 0, 'A', 0);
    core.grid.putCell(1, 0, 'B', 0);
    core.grid.cursor_visible = false;
    core.drawable_w_px = 1;
    core.drawable_h_px = 2;
    core.cell_w_px = 1;
    core.cell_h_px = 1;
    core.atlas_w = config.atlas_size_default;
    core.atlas_h = config.atlas_size_default;
    core.atlas_packer = shelf_packer.ShelfPacker.init(core.atlas_w, core.atlas_h);
    core.atlas_packer.?.next_x = core.atlas_w;
    core.atlas_packer.?.next_y = core.atlas_h;
    core.atlas_initialized = true;

    var state = State{ .core = &core };
    core.ctx = &state;
    core.cb.on_flush_end = State.onEnd;
    core.cb.on_vertices_row = State.onRow;
    core.cb.on_rasterize_glyph = State.rasterize;
    core.cb.on_atlas_upload = State.upload;
    core.cb.on_atlas_create = State.create;

    var flush_ctx = FlushCtx{ .core = &core };
    try flush_ctx.onFlush(2, 1);

    try std.testing.expect(core.flush_atlas_corrupted);
    try std.testing.expect(core.grid.dirty_all);
    try std.testing.expectEqual(@as(u32, 0), state.committed_flushes);
    try std.testing.expectEqual(@as(u32, 1), state.cancelled_flushes);
    try std.testing.expectEqual(@as(u32, 0), state.empty_main_calls);
    try std.testing.expectEqual(@as(u32, 1), state.row_calls);
    try std.testing.expectEqual(@as(u32, 2), state.create_calls);
    try std.testing.expectEqual(@as(u32, 2), state.upload_calls);
}

test "atlas reset on a scroll fast path flush still resends every row" {
    const ROWS: u32 = 8;
    const COLS: u32 = 2;

    const State = struct {
        reset_seen: bool = false,
        rows_after_reset: [ROWS]bool = @splat(false),
        committed_flushes: u32 = 0,
        cancelled_flushes: u32 = 0,
        scroll_calls: u32 = 0,
        core: *Core,

        fn onRow(
            ctx: ?*anyopaque,
            grid_id: i64,
            row_start: u32,
            row_count: u32,
            verts: ?[*]const c_api.Vertex,
            vert_count: usize,
            flags: u32,
            total_rows: u32,
            total_cols: u32,
        ) callconv(.c) void {
            _ = grid_id;
            _ = row_count;
            _ = verts;
            _ = vert_count;
            _ = total_rows;
            _ = total_cols;
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            if (flags & c_api.VERT_UPDATE_MAIN == 0) return;
            if (self.reset_seen and row_start < ROWS) {
                self.rows_after_reset[row_start] = true;
            }
        }

        fn onEnd(ctx: ?*anyopaque) callconv(.c) void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            if (self.core.flush_aborted or self.core.flush_atlas_corrupted) {
                self.cancelled_flushes += 1;
            } else {
                self.committed_flushes += 1;
            }
        }

        fn rasterize(
            ctx: ?*anyopaque,
            scalar: u32,
            style_flags: u32,
            out_bitmap: *c_api.GlyphBitmap,
        ) callconv(.c) c_int {
            _ = ctx;
            _ = scalar;
            _ = style_flags;
            out_bitmap.* = .{
                .pixels = null,
                .width = 1,
                .height = 1,
                .pitch = 1,
                .bearing_x = 0,
                .bearing_y = 1,
                .advance_26_6 = 64,
                .ascent_px = 1,
                .descent_px = 0,
                .bytes_per_pixel = 1,
            };
            return 1;
        }

        fn upload(
            ctx: ?*anyopaque,
            dest_x: u32,
            dest_y: u32,
            width: u32,
            height: u32,
            bitmap: *const c_api.GlyphBitmap,
        ) callconv(.c) void {
            _ = ctx;
            _ = dest_x;
            _ = dest_y;
            _ = width;
            _ = height;
            _ = bitmap;
        }

        fn create(ctx: ?*anyopaque, atlas_w: u32, atlas_h: u32) callconv(.c) void {
            _ = atlas_w;
            _ = atlas_h;
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            self.reset_seen = true;
        }

        fn onMainRowScroll(
            ctx: ?*anyopaque,
            row_start: u32,
            row_end: u32,
            col_start: u32,
            col_end: u32,
            rows_delta: i32,
            total_rows: u32,
            total_cols: u32,
        ) callconv(.c) void {
            _ = row_start;
            _ = row_end;
            _ = col_start;
            _ = col_end;
            _ = rows_delta;
            _ = total_rows;
            _ = total_cols;
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            self.scroll_calls += 1;
        }
    };

    // The fast path has two publication branches: frontends that implement
    // on_main_row_scroll let the frontend shift its own row slots (macOS),
    // the rest replay the shifted cache row by row (Windows). Both set
    // used_scroll_fast_path at the same site, so both must survive the retry.
    for ([_]bool{ false, true }) |use_scroll_cb| {
        var core = Core.initForTest(std.testing.allocator);
        defer core.deinitForTest();
        try core.grid.resizeGrid(1, ROWS, COLS);
        try core.grid.resizeGrid(2, ROWS, COLS);
        try core.grid.setWinPos(2, 100, 0, 0);
        core.grid.cursor_visible = false;
        core.drawable_w_px = COLS;
        core.drawable_h_px = ROWS;
        core.cell_w_px = 1;
        core.cell_h_px = 1;
        core.atlas_w = config.atlas_size_default;
        core.atlas_h = config.atlas_size_default;
        core.atlas_packer = shelf_packer.ShelfPacker.init(core.atlas_w, core.atlas_h);
        core.atlas_initialized = true;

        for (0..ROWS) |r| {
            for (0..COLS) |c| {
                core.grid.putCellGrid(2, @intCast(r), @intCast(c), 'A', 0);
            }
        }

        var state = State{ .core = &core };
        core.ctx = &state;
        core.cb.on_flush_end = State.onEnd;
        core.cb.on_vertices_row = State.onRow;
        core.cb.on_rasterize_glyph = State.rasterize;
        core.cb.on_atlas_upload = State.upload;
        core.cb.on_atlas_create = State.create;
        if (use_scroll_cb) core.cb.on_main_row_scroll = State.onMainRowScroll;

        // Warm the scroll cache and the row ledger, then settle dirty_all so
        // the next flush is eligible for the scroll fast path.
        var flush_ctx = FlushCtx{ .core = &core };
        try flush_ctx.onFlush(ROWS, COLS);
        try flush_ctx.onFlush(ROWS, COLS);
        try std.testing.expect(!core.grid.dirty_all);

        // Arm: the next uncached glyph finds a full packer and resets the
        // atlas mid-composition, which restarts the row loop.
        core.atlas_packer.?.next_x = core.atlas_w;
        core.atlas_packer.?.next_y = core.atlas_h;
        core.atlas_packer.?.row_h = 0;

        state.committed_flushes = 0;
        state.cancelled_flushes = 0;
        state.scroll_calls = 0;

        core.grid.scrollGrid(2, 0, ROWS, 0, COLS, 1, 0);
        core.grid.putCellGrid(2, ROWS - 1, 0, 'Z', 0);
        core.grid.putCellGrid(2, ROWS - 1, 1, 'Z', 0);
        try flush_ctx.onFlush(ROWS, COLS);

        // The fast path must actually have been taken, on the branch this
        // iteration is exercising — otherwise the retry is never reached and
        // the assertion below would pass vacuously.
        try std.testing.expectEqual(
            @as(u32, if (use_scroll_cb) 1 else 0),
            state.scroll_calls,
        );

        // The reset must have fired, and the frame must not have been
        // cancelled — this is the single-reset path that commits.
        try std.testing.expect(state.reset_seen);
        try std.testing.expect(!core.flush_atlas_corrupted);
        try std.testing.expect(!core.flush_aborted);
        try std.testing.expectEqual(@as(u32, 1), state.committed_flushes);
        try std.testing.expectEqual(@as(u32, 0), state.cancelled_flushes);

        // Every row sent before the reset carries stale UVs, so the retry owes
        // the frontend a fresh copy of all of them. A stale fast-path flag
        // would filter the retry against an empty regen set and send nothing.
        for (state.rows_after_reset, 0..) |sent, r| {
            if (!sent) {
                std.debug.print(
                    "row {d} was never resent after the atlas reset (scroll_cb={any})\n",
                    .{ r, use_scroll_cb },
                );
                return error.RowNotResentAfterAtlasReset;
            }
        }
    }
}

test "atlas create abort does not leak reset edge into next flush" {
    const State = struct {
        core: *Core,
        abort_create: bool = true,
        create_calls: u32 = 0,
        upload_calls: u32 = 0,
        partial_calls: u32 = 0,

        fn partial(
            ctx: ?*anyopaque,
            main_verts: ?[*]const c_api.Vertex,
            main_count: usize,
            cursor_verts: ?[*]const c_api.Vertex,
            cursor_count: usize,
            flags: u32,
        ) callconv(.c) void {
            _ = main_verts;
            _ = main_count;
            _ = cursor_verts;
            _ = cursor_count;
            _ = flags;
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            self.partial_calls += 1;
        }

        fn rasterize(
            ctx: ?*anyopaque,
            scalar: u32,
            style_flags: u32,
            out_bitmap: *c_api.GlyphBitmap,
        ) callconv(.c) c_int {
            _ = ctx;
            _ = scalar;
            _ = style_flags;
            out_bitmap.* = .{
                .pixels = null,
                .width = 1,
                .height = 1,
                .pitch = 1,
                .bearing_x = 0,
                .bearing_y = 1,
                .advance_26_6 = 64,
                .ascent_px = 1,
                .descent_px = 0,
                .bytes_per_pixel = 1,
            };
            return 1;
        }

        fn upload(
            ctx: ?*anyopaque,
            dest_x: u32,
            dest_y: u32,
            width: u32,
            height: u32,
            bitmap: *const c_api.GlyphBitmap,
        ) callconv(.c) void {
            _ = dest_x;
            _ = dest_y;
            _ = width;
            _ = height;
            _ = bitmap;
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            self.upload_calls += 1;
        }

        fn create(ctx: ?*anyopaque, atlas_w: u32, atlas_h: u32) callconv(.c) void {
            _ = atlas_w;
            _ = atlas_h;
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            self.create_calls += 1;
            if (self.abort_create) self.core.flush_aborted = true;
        }
    };

    var core = Core.initForTest(std.testing.allocator);
    defer core.deinitForTest();
    try core.grid.resizeGrid(1, 1, 1);
    core.grid.putCell(0, 0, 'A', 0);
    core.grid.cursor_visible = false;
    core.drawable_w_px = 1;
    core.drawable_h_px = 1;
    core.cell_w_px = 1;
    core.cell_h_px = 1;
    core.atlas_w = config.atlas_size_max;
    core.atlas_h = config.atlas_size_max;
    core.atlas_packer = shelf_packer.ShelfPacker.init(core.atlas_w, core.atlas_h);
    core.atlas_packer.?.next_y = config.atlas_size_max;
    core.atlas_initialized = true;

    var state = State{ .core = &core };
    core.ctx = &state;
    core.cb.on_vertices_partial = State.partial;
    core.cb.on_rasterize_glyph = State.rasterize;
    core.cb.on_atlas_upload = State.upload;
    core.cb.on_atlas_create = State.create;

    var flush_ctx = FlushCtx{ .core = &core };
    try flush_ctx.onFlush(1, 1);
    try std.testing.expect(core.flush_aborted);
    try std.testing.expect(!core.atlas_reset_during_flush);
    try std.testing.expectEqual(@as(u32, 1), state.create_calls);
    try std.testing.expectEqual(@as(u32, 0), state.upload_calls);
    try std.testing.expectEqual(@as(u32, 0), state.partial_calls);

    state.abort_create = false;
    try flush_ctx.onFlush(1, 1);
    try std.testing.expect(!core.flush_aborted);
    try std.testing.expect(!core.flush_atlas_corrupted);
    try std.testing.expect(!core.atlas_reset_during_flush);
    try std.testing.expect(!core.grid.dirty_all);
    try std.testing.expectEqual(@as(u32, 2), state.create_calls);
    try std.testing.expectEqual(@as(u32, 1), state.upload_calls);
    try std.testing.expectEqual(@as(u32, 1), state.partial_calls);
}

fn checkShapingScratchAllocationFailure(alloc: std.mem.Allocator) !void {
    var core = Core.initForTest(alloc);
    defer core.deinitForTest();
    try ensureShapingScratch(&core, 64);
}

test "shaping scratch allocation failures propagate" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        checkShapingScratchAllocationFailure,
        .{},
    );
}

test "flush begin abort does not arm atlas capacity recovery" {
    const State = struct {
        core: *Core,

        fn onBegin(ctx: ?*anyopaque) callconv(.c) void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            self.core.flush_aborted = true;
        }
    };

    var core = Core.initForTest(std.testing.allocator);
    defer core.deinitForTest();
    try core.grid.resizeGrid(1, 1, 1);
    try core.initGlyphCache();
    core.glyph_cache_ascii.?['x'] = std.mem.zeroes(c_api.GlyphEntry);
    core.glyph_valid_ascii.?['x'] = true;
    core.atlas_has_capacity_negative = true;
    core.atlas_negative_retry_grid_rev = core.grid.glyph_working_set_rev;
    core.grid.glyph_working_set_rev +%= 1;
    var state = State{ .core = &core };
    core.ctx = &state;
    core.cb.on_flush_begin = State.onBegin;

    var flush_ctx = FlushCtx{ .core = &core };
    try flush_ctx.onFlush(1, 1);
    try std.testing.expect(core.glyph_valid_ascii.?['x']);
    try std.testing.expect(!core.atlas_negative_recovery_armed);
    try std.testing.expect(core.atlas_negative_retry_at == null);
}

test "external float row index sorts once and buckets visible intersections" {
    var core = Core.initForTest(std.testing.allocator);
    defer core.deinitForTest();

    try core.grid.resizeGrid(10, 4, 5);
    try core.grid.putSyntheticExternal(10, .{ .win = 10, .start_row = 10, .start_col = 20 });
    try core.grid.resizeGrid(20, 2, 2);
    try core.grid.resizeGrid(21, 2, 2);
    try core.grid.setWinFloatPos(20, 20, 10, 20, 20, 0, 10);
    try core.grid.setWinFloatPos(21, 21, 11, 21, 10, 0, 10);

    try buildExternalFloatAnchorIndex(&core);
    const anchor_entries = externalFloatAnchorEntries(core.ext_float_anchor_entries.items, 10);
    const generation = try buildExternalFloatRowIndex(
        &core,
        anchor_entries,
        core.grid.external_grids.get(10),
        4,
        5,
    );
    try std.testing.expectEqual(generation, core.ext_float_index_generation);
    try std.testing.expectEqualSlices(i64, &.{ 21, 20 }, &.{
        core.ext_float_entries.items[0].grid_id,
        core.ext_float_entries.items[1].grid_id,
    });

    const offsets = core.ext_float_row_offsets.items;
    try std.testing.expectEqualSlices(usize, &.{ 0, 1, 3, 4, 4 }, offsets);
    try std.testing.expectEqualSlices(usize, &.{ 1, 0, 1, 0 }, core.ext_float_row_entry_indices.items);
    try std.testing.expect(
        externalFloatPersistentScratchCapacityByteSize(&core).? <=
            MAX_EXTERNAL_FLOAT_PERSISTENT_SCRATCH_BYTES,
    );

    try std.testing.expectError(
        error.LayoutTooComplex,
        buildExternalFloatRowIndexWithLimit(
            &core,
            anchor_entries,
            core.grid.external_grids.get(10),
            4,
            5,
            1,
        ),
    );
    try std.testing.expect(!core.ext_float_row_index_valid);
    try std.testing.expectEqual(@as(usize, 0), core.ext_float_row_offsets.capacity);
    try std.testing.expectEqual(@as(usize, 0), core.ext_float_row_entry_indices.capacity);
}

test "external float persistent scratch partitions share one 8 MiB cap" {
    try std.testing.expectEqual(
        MAX_EXTERNAL_FLOAT_PERSISTENT_SCRATCH_BYTES,
        MAX_EXTERNAL_FLOAT_ANCHOR_SCRATCH_BYTES +
            MAX_EXTERNAL_FLOAT_ENTRY_SCRATCH_BYTES +
            MAX_EXTERNAL_FLOAT_ROW_INDEX_BYTES,
    );
    try std.testing.expect(
        grid_mod.MAX_WINDOW_PLACEMENTS * @sizeOf(ExternalFloatAnchorEntry) <=
            MAX_EXTERNAL_FLOAT_ANCHOR_SCRATCH_BYTES,
    );
    try std.testing.expect(
        grid_mod.MAX_WINDOW_PLACEMENTS * @sizeOf(GridEntry) <=
            MAX_EXTERNAL_FLOAT_ENTRY_SCRATCH_BYTES,
    );
}

test "main subgrid row index preserves layer order and updates on layout change" {
    var core = Core.initForTest(std.testing.allocator);
    defer core.deinitForTest();

    var cells = [_]grid_mod.Cell{.{ .cp = 'x', .hl = 0 }};
    var cached = [_]CachedSubgrid{
        .{ .grid_id = 10, .row_start = 0, .row_end = 2, .col_start = 0, .sg_cols = 1, .sg_rows = 2, .cells = cells[0..].ptr, .margin_top = 0, .margin_bottom = 0 },
        .{ .grid_id = 11, .row_start = 1, .row_end = 3, .col_start = 0, .sg_cols = 1, .sg_rows = 2, .cells = cells[0..].ptr, .margin_top = 0, .margin_bottom = 0 },
        .{ .grid_id = 12, .row_start = 1, .row_end = 2, .col_start = 0, .sg_cols = 1, .sg_rows = 1, .cells = cells[0..].ptr, .margin_top = 0, .margin_bottom = 0 },
    };
    try std.testing.expect(try ensureMainSubgridRowIndex(&core, &cached, 4));
    try std.testing.expectEqualSlices(usize, &.{ 0, 1, 4, 5, 5 }, core.main_subgrid_row_offsets.items);
    try std.testing.expectEqualSlices(usize, &.{ 0, 0, 1, 2, 1 }, core.main_subgrid_row_indices.items);

    const retained_capacity = core.main_subgrid_row_indices.capacity;
    try std.testing.expect(try ensureMainSubgridRowIndex(&core, &cached, 4));
    try std.testing.expectEqual(retained_capacity, core.main_subgrid_row_indices.capacity);

    cached[2].row_start = 3;
    cached[2].row_end = 4;
    core.grid.layout_generation += 1;
    try std.testing.expect(try ensureMainSubgridRowIndex(&core, &cached, 4));
    try std.testing.expectEqualSlices(usize, &.{ 0, 1, 3, 4, 5 }, core.main_subgrid_row_offsets.items);
    try std.testing.expectEqualSlices(usize, &.{ 0, 0, 1, 1, 2 }, core.main_subgrid_row_indices.items);

    // Five row references exceed this test budget. The layout is rejected;
    // there is no O(rows * subgrids) fallback.
    const four_ref_budget = mainSubgridRowIndexByteSize(4, 4, cached.len).?;
    try std.testing.expectError(
        error.LayoutTooComplex,
        ensureMainSubgridRowIndexWithLimit(&core, &cached, 4, four_ref_budget),
    );
    try std.testing.expect(!core.main_subgrid_row_index_valid);

    // Zero-area grids do not consume row references or layout snapshots.
    var layout_core = Core.initForTest(std.testing.allocator);
    defer layout_core.deinitForTest();
    var zero_height = cached;
    for (&zero_height) |*csg| csg.row_end = csg.row_start;
    const two_layout_budget = mainSubgridRowIndexByteSize(4, 0, 2).?;
    try std.testing.expect(try ensureMainSubgridRowIndexWithLimit(&layout_core, &zero_height, 4, two_layout_budget));
    try std.testing.expectEqual(@as(usize, 0), layout_core.main_subgrid_row_layout.items.len);
    try std.testing.expect(layout_core.main_subgrid_row_index_valid);

    // A previous layout's independent high-water capacities must not reject
    // a currently bounded layout. Rebuild the storage at the current shape.
    var high_water_core = Core.initForTest(std.testing.allocator);
    defer high_water_core.deinitForTest();
    try high_water_core.main_subgrid_row_offsets.ensureTotalCapacityPrecise(high_water_core.alloc, 64);
    try high_water_core.main_subgrid_row_write_offsets.ensureTotalCapacityPrecise(high_water_core.alloc, 64);
    try high_water_core.main_subgrid_row_indices.ensureTotalCapacityPrecise(high_water_core.alloc, 64);
    try high_water_core.main_subgrid_row_layout.ensureTotalCapacityPrecise(high_water_core.alloc, 64);
    const current_budget = mainSubgridRowIndexByteSize(4, 2, 1).?;
    try std.testing.expect(try ensureMainSubgridRowIndexWithLimit(
        &high_water_core,
        cached[0..1],
        4,
        current_budget,
    ));
    try std.testing.expect(
        mainSubgridRowIndexStorageByteSize(
            high_water_core.main_subgrid_row_offsets.capacity,
            high_water_core.main_subgrid_row_write_offsets.capacity,
            high_water_core.main_subgrid_row_indices.capacity,
            high_water_core.main_subgrid_row_layout.capacity,
        ).? <= current_budget,
    );
}

test "subgrid layout diff merges by id and reuses linear row marks" {
    var core = Core.initForTest(std.testing.allocator);
    defer core.deinitForTest();

    var cell = [_]grid_mod.Cell{.{ .cp = ' ', .hl = 0 }};
    var cached: [64]CachedSubgrid = undefined;
    for (&cached, 0..) |*csg, index| {
        // Reverse IDs prove comparison does not depend on layer order.
        csg.* = .{
            .grid_id = @intCast(cached.len - index),
            .row_start = @intCast(index * 2),
            .row_end = @intCast(index * 2 + 1),
            .col_start = 0,
            .sg_cols = 1,
            .sg_rows = 1,
            .cells = cell[0..].ptr,
            .margin_top = 0,
            .margin_bottom = 0,
        };
    }
    saveSubgridSnapshots(&core, &cached);

    var out: [32]u32 = undefined;
    try std.testing.expectEqual(
        @as(u32, 0),
        collectSubgridDiffRows(&core, &cached, 0, 128, &out, &.{}),
    );
    const current_capacity = core.subgrid_diff_current.capacity;
    const mark_capacity = core.subgrid_diff_row_marks.capacity;

    const moved_old_row = cached[10].row_start;
    cached[10].row_start = 100;
    cached[10].row_end = 101;
    const count = collectSubgridDiffRows(
        &core,
        &cached,
        0,
        128,
        &out,
        &.{moved_old_row},
    );
    try std.testing.expectEqual(@as(u32, 1), count);
    try std.testing.expectEqual(@as(u32, 100), out[0]);
    try std.testing.expectEqual(current_capacity, core.subgrid_diff_current.capacity);
    try std.testing.expectEqual(mark_capacity, core.subgrid_diff_row_marks.capacity);
}

test "external float anchor index groups many anchors after one map scan" {
    var core = Core.initForTest(std.testing.allocator);
    defer core.deinitForTest();

    const anchor_count = 64;
    for (0..anchor_count) |i| {
        const anchor_id: i64 = @intCast(100 + i);
        const float_id: i64 = @intCast(1000 + i);
        try core.grid.resizeGrid(anchor_id, 2, 2);
        try core.grid.putSyntheticExternal(anchor_id, .{
            .win = anchor_id,
            .start_row = @intCast(i * 2),
            .start_col = 0,
        });
        try core.grid.resizeGrid(float_id, 1, 1);
        try core.grid.setWinFloatPos(float_id, float_id, @intCast(i * 2), 0, @intCast(i), 0, anchor_id);
    }

    try buildExternalFloatAnchorIndex(&core);
    const retained_capacity = core.ext_float_anchor_entries.capacity;
    try std.testing.expectEqual(@as(usize, anchor_count), core.ext_float_anchor_entries.items.len);
    for (0..anchor_count) |i| {
        const anchor_id: i64 = @intCast(100 + i);
        const entries = externalFloatAnchorEntries(core.ext_float_anchor_entries.items, anchor_id);
        try std.testing.expectEqual(@as(usize, 1), entries.len);
        try std.testing.expectEqual(@as(i64, @intCast(1000 + i)), entries[0].entry.grid_id);
    }

    // Rebuilding the same layout reuses the persistent allocation.
    core.ext_float_anchor_index_valid = false;
    try buildExternalFloatAnchorIndex(&core);
    try std.testing.expectEqual(retained_capacity, core.ext_float_anchor_entries.capacity);
}

test "external float anchor scratch reserves only matching placements" {
    var core = Core.initForTest(std.testing.allocator);
    defer core.deinitForTest();

    try core.grid.resizeGrid(1, 1, 1);
    for (0..128) |i| {
        const grid_id: i64 = @intCast(1_000 + i);
        try core.grid.setWinPos(grid_id, 0, 0, 0);
    }
    try core.grid.resizeGrid(5000, 1, 1);
    try core.grid.putSyntheticExternal(5000, .{ .win = 5000, .start_row = 0, .start_col = 0 });
    try core.grid.setWinFloatPos(5001, 0, 0, 0, 10, 0, 5000);

    try buildExternalFloatAnchorIndex(&core);
    try std.testing.expectEqual(@as(usize, 129), core.grid.win_pos.count());
    try std.testing.expectEqual(@as(usize, 1), core.ext_float_anchor_entries.items.len);
    try std.testing.expectEqual(@as(usize, 1), core.ext_float_anchor_entries.capacity);
}

test "external float visible scratch excludes invisible entries and releases hostile capacity" {
    var core = Core.initForTest(std.testing.allocator);
    defer core.deinitForTest();

    try core.grid.resizeGrid(10, 4, 5);
    try core.grid.putSyntheticExternal(10, .{ .win = 10, .start_row = 0, .start_col = 0 });
    try core.grid.resizeGrid(20, 1, 1);
    try core.grid.setWinFloatPos(20, 20, 0, 0, 100, 0, 10);
    for (0..32) |i| {
        const float_id: i64 = @intCast(100 + i);
        try core.grid.resizeGrid(float_id, 1, 1);
        try core.grid.setWinFloatPos(float_id, float_id, @intCast(100 + i), 0, @intCast(i), 0, 10);
    }

    try buildExternalFloatAnchorIndex(&core);
    const anchor_entries = externalFloatAnchorEntries(core.ext_float_anchor_entries.items, 10);
    _ = try buildExternalFloatRowIndex(&core, anchor_entries, core.grid.external_grids.get(10), 4, 5);
    try std.testing.expectEqual(@as(usize, 1), core.ext_float_entries.items.len);
    try std.testing.expectEqual(@as(usize, 1), core.ext_float_entries.capacity);
    try std.testing.expectEqual(@as(i64, 20), core.ext_float_entries.items[0].grid_id);

    // A prior hostile high-water capacity is dropped before a later bounded
    // build, rather than surviving clearRetainingCapacity indefinitely.
    try core.ext_float_entries.ensureTotalCapacityPrecise(core.alloc, 64);
    _ = try buildExternalFloatRowIndexWithLimits(
        &core,
        &.{},
        core.grid.external_grids.get(10),
        4,
        5,
        MAX_EXTERNAL_FLOAT_ROW_INDEX_BYTES,
        @sizeOf(GridEntry),
    );
    try std.testing.expectEqual(@as(usize, 0), core.ext_float_entries.capacity);

    try std.testing.expectError(
        error.TooManyWindowPlacements,
        buildExternalFloatAnchorIndexWithLimit(&core, @sizeOf(ExternalFloatAnchorEntry)),
    );
    try std.testing.expectEqual(@as(usize, 0), core.ext_float_anchor_entries.capacity);
}

test "external close detection visits known grids once and removes in place" {
    const Recorder = struct {
        fn close(ctx: ?*anyopaque, grid_id: i64) callconv(.c) void {
            const ids: *std.ArrayListUnmanaged(i64) = @ptrCast(@alignCast(ctx.?));
            ids.append(std.testing.allocator, grid_id) catch unreachable;
        }
    };

    var core = Core.initForTest(std.testing.allocator);
    defer core.deinitForTest();
    defer core.known_external_grids.deinit(core.alloc);
    var closed: std.ArrayListUnmanaged(i64) = .empty;
    defer closed.deinit(std.testing.allocator);
    core.ctx = &closed;
    core.cb.on_external_window_close = Recorder.close;

    try core.known_external_grids.put(core.alloc, 10, .{ .win = 10, .start_row = 0, .start_col = 0, .rows = 2, .cols = 2 });
    try core.known_external_grids.put(core.alloc, 11, .{ .win = 11, .start_row = 0, .start_col = 0, .rows = 2, .cols = 2 });
    try core.grid.external_grids.put(core.alloc, 11, .{ .win = 11, .start_row = 0, .start_col = 0 });

    _ = notifyExternalWindowChanges(&core);
    try std.testing.expectEqualSlices(i64, &.{10}, closed.items);
    try std.testing.expect(!core.known_external_grids.contains(10));
    try std.testing.expect(core.known_external_grids.contains(11));
}

test "external open abort stops later lifecycle callbacks until retry" {
    const State = struct {
        core: *Core,
        calls: u32 = 0,
        abort_first: bool = true,

        fn open(
            ctx: ?*anyopaque,
            grid_id: i64,
            win: i64,
            rows: u32,
            cols: u32,
            start_row: i32,
            start_col: i32,
        ) callconv(.c) void {
            _ = grid_id;
            _ = win;
            _ = rows;
            _ = cols;
            _ = start_row;
            _ = start_col;
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            self.calls += 1;
            if (self.abort_first and self.calls == 1) self.core.flush_aborted = true;
        }
    };

    var core = Core.initForTest(std.testing.allocator);
    defer core.deinitForTest();
    defer core.known_external_grids.deinit(core.alloc);
    try core.grid.resizeGrid(10, 2, 2);
    try core.grid.resizeGrid(11, 2, 2);
    try core.grid.putSyntheticExternal(10, .{ .win = 10, .start_row = 0, .start_col = 0 });
    try core.grid.putSyntheticExternal(11, .{ .win = 11, .start_row = 2, .start_col = 0 });

    var state = State{ .core = &core };
    core.ctx = &state;
    core.cb.on_external_window = State.open;

    _ = notifyExternalWindowChanges(&core);
    try std.testing.expect(core.flush_aborted);
    try std.testing.expectEqual(@as(u32, 1), state.calls);
    try std.testing.expectEqual(@as(usize, 0), core.known_external_grids.count());

    core.flush_aborted = false;
    state.abort_first = false;
    _ = notifyExternalWindowChanges(&core);
    try std.testing.expect(!core.flush_aborted);
    try std.testing.expectEqual(@as(u32, 3), state.calls);
    try std.testing.expectEqual(@as(usize, 2), core.known_external_grids.count());
}

test "transient message compaction is stable" {
    var core = Core.initForTest(std.testing.allocator);
    defer core.deinitForTest();

    const kinds = [_][]const u8{ "search_count", "echo", "search_count", "emsg" };
    for (kinds, 1..) |kind, id| {
        const owned_kind = try core.alloc.dupe(u8, kind);
        errdefer core.alloc.free(owned_kind);
        try core.grid.message_state.messages.append(core.alloc, .{
            .id = @intCast(id),
            .kind = owned_kind,
        });
    }

    // Compaction now reads the cycle's view assignment rather than re-routing.
    const items = core.grid.message_state.messages.items;
    try core.msg_views.beginCycle(core.alloc, items.len);
    for (items, 0..) |m, i| {
        const r = core.msg_config.routeMessage(.msg_show, m.kind, 1);
        core.msg_views.assign(i, r.view, r.timeout, r.enter);
    }

    dropTransientMessages(&core);
    try std.testing.expectEqual(@as(usize, 2), core.grid.message_state.messages.items.len);
    try std.testing.expectEqual(@as(i64, 2), core.grid.message_state.messages.items[0].id);
    try std.testing.expectEqual(@as(i64, 4), core.grid.message_state.messages.items[1].id);
}

/// Append a msg_show message with one chunk. Caller keeps ownership through
/// the core's message_state, which frees both on teardown.
fn appendTestMessage(core: *Core, id: i64, kind: []const u8, text: []const u8) !void {
    const owned_kind = try core.alloc.dupe(u8, kind);
    errdefer core.alloc.free(owned_kind);
    const owned_text = try core.alloc.dupe(u8, text);
    errdefer core.alloc.free(owned_text);
    var msg: grid_mod.Message = .{ .id = id, .kind = owned_kind };
    try msg.content.append(core.alloc, .{ .hl_id = 0, .text = owned_text });
    try core.grid.message_state.messages.append(core.alloc, msg);
    core.grid.message_state.msg_dirty = true;
}

test "a height-filtered ext_float route reaches the line cache" {
    // Regression: buildMsgLineCache re-routed with a line count of 1 while
    // sendMsgShow routes with the total, so a route filtered on height sent
    // the message to the grid and then omitted it from the cache — the view
    // appeared empty. Both now read the one assignment made per cycle.
    var core = Core.initForTest(std.testing.allocator);
    defer core.deinitForTest();
    core.ext_messages_enabled = true;

    var routes = [_]config.MsgRoute{
        .{ .filter = .{ .event = .msg_show, .min_height = 3 }, .view = .ext_float },
        .{ .filter = .{ .event = .msg_show }, .view = .mini },
    };
    core.msg_config.messages.routes = &routes;

    // Three lines, so the total line count clears min_height while the
    // per-message count of 1 would not.
    try appendTestMessage(&core, 1, "echo", "alpha\nbeta\ngamma");

    _ = sendMsgShow(&core);

    try std.testing.expectEqual(config.MsgViewType.ext_float, core.msg_views.assignedTo(0));
    try std.testing.expect(core.msg_line_cache.items.len > 0);
    try std.testing.expect(core.msg_total_lines > 0);
}

test "a dead transport drops the prompt instead of freezing the pipeline" {
    // Test cores have no writer thread, so requestInput always fails with
    // BrokenPipe — a PERMANENT failure. Retrying cannot deliver the `<CR>`
    // to a transport that is gone, and aborting the flush over it would
    // abort every later flush too, freezing the whole render pipeline on its
    // last frame (onFlush returns before all vertex work when flush_aborted
    // is set). So the prompt is dropped and the cycle completes normally.
    var core = Core.initForTest(std.testing.allocator);
    defer core.deinitForTest();
    core.ext_messages_enabled = true;

    try appendTestMessage(&core, 1, "return_prompt", "Press ENTER");

    try std.testing.expect(sendMsgShow(&core));
    try std.testing.expect(!core.flush_aborted);
    try std.testing.expectEqual(@as(usize, 0), core.grid.message_state.messages.items.len);
}

test "a prompt-only batch hides the view without clearing the frontend" {
    // The two arms of the empty-batch branch differ in exactly one
    // observable: both hide a visible core-owned view, but only the
    // pure-empty arm fires on_msg_clear — a prompt-only batch displayed
    // nothing and cleared nothing, so the frontend must not be told
    // otherwise. Asserting both arms through an on_msg_clear probe is what
    // discriminates the two mutations that used to escape: deleting the
    // prompt-only arm (a prompt-only batch would then fire a clear) and
    // widening its gate to >= 0 (a pure-empty batch would then stop firing
    // one).
    //
    // The staging is a unit-level approximation: in production a visible
    // ext_float cannot coexist with a prompt-only array (only msg_clear
    // empties it, and notifyMessageChanges' cleared_in_batch branch hides
    // and clears BEFORE sendMsgShow runs). The clear-count observable still
    // maps to real symptoms — the escaped mutations fire a duplicate or
    // spurious on_msg_clear on reachable batches. Here the prompt is
    // consumed via the drop path (this core has no transport); the answered
    // path is pinned separately by "an answered prompt counts as consumed",
    // which arms the in-process transport seam.
    var core = Core.initForTest(std.testing.allocator);
    defer core.deinitForTest();
    core.ext_messages_enabled = true;

    var clear_calls: usize = 0;
    const Probe = struct {
        var calls: *usize = undefined;
        fn onClear(_: ?*anyopaque) callconv(.c) void {
            calls.* += 1;
        }
    };
    Probe.calls = &clear_calls;
    core.cb.on_msg_clear = Probe.onClear;

    // A visible ext_float view to give both arms something to hide.
    try appendTestMessage(&core, 1, "echo", "visible");
    try std.testing.expect(sendMsgShow(&core));
    try std.testing.expect(core.msg_views.state(.ext_float).visible);

    // Prompt-only batch: the dead transport drops the prompt (test cores
    // have no writer thread), leaving zero messages with consumed > 0.
    core.grid.message_state.clearMessages(core.alloc);
    try appendTestMessage(&core, 2, "return_prompt", "Press ENTER");
    clear_calls = 0;
    try std.testing.expect(sendMsgShow(&core));
    try std.testing.expect(!core.msg_views.state(.ext_float).visible);
    try std.testing.expectEqual(@as(usize, 0), clear_calls);

    // A pure-empty batch takes the other arm: same hide, plus the clear.
    try appendTestMessage(&core, 3, "echo", "visible again");
    try std.testing.expect(sendMsgShow(&core));
    try std.testing.expect(core.msg_views.state(.ext_float).visible);
    core.grid.message_state.clearMessages(core.alloc);
    clear_calls = 0;
    try std.testing.expect(sendMsgShow(&core));
    try std.testing.expect(!core.msg_views.state(.ext_float).visible);
    try std.testing.expectEqual(@as(usize, 1), clear_calls);
}

/// Arm the in-process transport seam: with any thread handle in
/// `writer_thread`, `sendRawClassified` takes the enqueue path and the full
/// encoded request lands in `core.write_queue` without a live transport. The
/// thread is joined before the handle is stored — nothing ever joins or
/// detaches it again, it only satisfies the null check.
///
/// A test that arms this must NOT call `stop()` or session teardown: those
/// paths join `writer_thread`, and joining an already-joined handle is UB.
/// `deinitForTest` is safe — it never touches the field.
fn armTestTransport(core: *Core) !void {
    const Dummy = struct {
        fn run() void {}
    };
    var t = try std.Thread.spawn(.{}, Dummy.run, .{});
    t.join();
    core.writer_thread = t;
}

test "the resolved enter value reaches the generated program" {
    // `state.enter orelse (ch == .history)` is decided in the split arm and
    // its only downstream trace is the `local enter = ...` literal in the
    // enqueued Lua. The transport seam makes that observable at unit level,
    // so the dispatch-site mutations (ignore the option, flip a default) are
    // killed here and not only by e2e cursor movement.
    //
    // The substring match assumes the template binds `local enter` exactly
    // once and that no message content in this test contains that literal
    // (content rides in the same encoded request). Both are under this
    // test's control; keep them true if either changes.
    var core = Core.initForTest(std.testing.allocator);
    defer core.deinitForTest();
    try armTestTransport(&core);
    defer core.writer_thread = null;

    // Show channel, enter unset: the channel default is false.
    try appendTestMessage(&core, 1, "echo", "content");
    const messages = core.grid.message_state.messages.items;
    try core.msg_views.beginCycle(core.alloc, messages.len);
    core.msg_views.assign(0, .split, 0, null);
    var mark: usize = core.write_queue.items.len;
    try std.testing.expect(showChannelView(&core, .show, .split, .{ .show = messages }));
    try std.testing.expect(std.mem.indexOf(u8, core.write_queue.items[mark..], "local enter = false") != null);

    // Show channel, route says true: the override wins.
    try core.msg_views.beginCycle(core.alloc, messages.len);
    core.msg_views.assign(0, .split, 0, true);
    mark = core.write_queue.items.len;
    try std.testing.expect(showChannelView(&core, .show, .split, .{ .show = messages }));
    try std.testing.expect(std.mem.indexOf(u8, core.write_queue.items[mark..], "local enter = true") != null);

    // History channel, enter unset: the channel default is true.
    var entry: grid_mod.MsgHistoryEntry = .{};
    defer entry.content.deinit(std.testing.allocator);
    try entry.content.append(std.testing.allocator, .{ .hl_id = 0, .text = "h" });
    try core.history_views.beginCycle(core.alloc, 1);
    core.history_views.assign(0, .split, 0, null);
    mark = core.write_queue.items.len;
    try std.testing.expect(showChannelView(&core, .history, .split, .{ .history = &.{entry} }));
    try std.testing.expect(std.mem.indexOf(u8, core.write_queue.items[mark..], "local enter = true") != null);

    // History channel, route says false: the override wins here too.
    try core.history_views.beginCycle(core.alloc, 1);
    core.history_views.assign(0, .split, 0, false);
    mark = core.write_queue.items.len;
    try std.testing.expect(showChannelView(&core, .history, .split, .{ .history = &.{entry} }));
    try std.testing.expect(std.mem.indexOf(u8, core.write_queue.items[mark..], "local enter = false") != null);
}

test "an answered prompt counts as consumed" {
    // The transport seam lets requestInput SUCCEED, so this drives the
    // answered arm of answerReturnPrompts — previously reachable only via
    // the drop arm, which left the answered `consumed += 1` unverifiable:
    // removing it survived the whole suite. Observables: the `<CR>` really
    // was enqueued, the prompt left the array, and the prompt-only dispatch
    // took the no-clear arm (consumed > 0), which is exactly what a missing
    // increment would flip.
    var core = Core.initForTest(std.testing.allocator);
    defer core.deinitForTest();
    core.ext_messages_enabled = true;
    try armTestTransport(&core);
    defer core.writer_thread = null;

    var clear_calls: usize = 0;
    const Probe = struct {
        var calls: *usize = undefined;
        fn onClear(_: ?*anyopaque) callconv(.c) void {
            calls.* += 1;
        }
    };
    Probe.calls = &clear_calls;
    core.cb.on_msg_clear = Probe.onClear;

    try appendTestMessage(&core, 1, "return_prompt", "Press ENTER");
    const mark = core.write_queue.items.len;

    try std.testing.expect(sendMsgShow(&core));
    try std.testing.expect(std.mem.indexOf(u8, core.write_queue.items[mark..], "nvim_input") != null);
    try std.testing.expect(std.mem.indexOf(u8, core.write_queue.items[mark..], "<CR>") != null);
    try std.testing.expectEqual(@as(usize, 0), core.grid.message_state.messages.items.len);
    try std.testing.expectEqual(@as(usize, 0), clear_calls);
}

test "an out-of-memory answer keeps the prompt for retry" {
    // The other half of the split: OutOfMemory is transient, so the prompt
    // must survive to be answered by a later attempt rather than being
    // silently dropped while Neovim still blocks on hit-enter. It must also
    // not be rendered on the way through.
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var core = Core.initForTest(failing.allocator());
    defer core.deinitForTest();
    core.ext_messages_enabled = true;

    try appendTestMessage(&core, 1, "echo", "content");
    try appendTestMessage(&core, 2, "return_prompt", "Press ENTER");

    failing.fail_index = failing.alloc_index;
    failing.resize_fail_index = failing.resize_index;
    try std.testing.expect(!sendMsgShow(&core));
    try std.testing.expect(core.flush_aborted);
    try std.testing.expectEqual(@as(usize, 2), core.grid.message_state.messages.items.len);
    try std.testing.expect(config.isReturnPrompt(core.grid.message_state.messages.items[1].kind));
    try std.testing.expectEqual(@as(usize, 0), core.msg_line_cache.items.len);
}

test "an emptied core-owned view is hidden exactly once" {
    var core = Core.initForTest(std.testing.allocator);
    defer core.deinitForTest();
    core.ext_messages_enabled = true;

    try appendTestMessage(&core, 1, "echo", "visible");
    _ = sendMsgShow(&core);
    try std.testing.expectEqual(config.MsgViewType.ext_float, core.msg_views.assignedTo(0));
    try std.testing.expect(core.msg_views.state(.ext_float).visible);

    // Next cycle with nothing routed there: the view hides and stays hidden.
    core.grid.message_state.clearMessages(core.alloc);
    _ = sendMsgShow(&core);
    try std.testing.expect(!core.msg_views.state(.ext_float).visible);
    try std.testing.expectEqual(msg_view.Action.none, core.msg_views.action(.ext_float));
}

test "history dispatches through its own view set and hides on empty" {
    // msg_history_show used to be a five-arm switch outside the view
    // abstraction; this pins that it now runs the same show/hide lifecycle,
    // including hiding a still-visible grid when the history is cleared.
    var core = Core.initForTest(std.testing.allocator);
    defer core.deinitForTest();
    core.ext_messages_enabled = true;

    var routes = [_]config.MsgRoute{
        .{ .filter = .{ .event = .msg_history_show }, .view = .ext_float, .opts = .{ .timeout = 0 } },
    };
    core.msg_config.messages.routes = &routes;

    var entry: grid_mod.MsgHistoryEntry = .{};
    defer entry.content.deinit(std.testing.allocator);
    try entry.content.append(std.testing.allocator, .{ .hl_id = 0, .text = "history" });
    try core.grid.setMsgHistoryShow(&.{entry}, false);

    try std.testing.expect(sendMsgHistoryShow(&core));
    try std.testing.expect(core.history_views.state(.ext_float).visible);
    try std.testing.expect(core.grid.external_grids.contains(grid_mod.MSG_HISTORY_GRID_ID));

    // Clearing the history hides the grid through the same dispatch.
    core.grid.msg_history_state.clear(core.grid.alloc);
    try std.testing.expect(sendMsgHistoryShow(&core));
    try std.testing.expect(!core.history_views.state(.ext_float).visible);
    try std.testing.expect(!core.grid.external_grids.contains(grid_mod.MSG_HISTORY_GRID_ID));
}

test "auto-hide expiry clears the visible flag through the hide funnel" {
    // Out-of-band hides (auto-hide timeout, msg_clear) used to bypass the
    // ViewSet, leaving `visible` stale so the next empty cycle issued a
    // spurious hide. Every hide path now goes through hideChannelView.
    var core = Core.initForTest(std.testing.allocator);
    defer core.deinitForTest();
    core.ext_messages_enabled = true;

    try appendTestMessage(&core, 1, "echo", "visible");
    _ = sendMsgShow(&core);
    try std.testing.expect(core.msg_views.state(.ext_float).visible);

    // Force the deadline into the past and fire the timeout path.
    core.msg_show_auto_hide_at = clock.nowNs() - 1;
    checkMsgAutoHideTimeout(&core);

    try std.testing.expect(!core.msg_views.state(.ext_float).visible);
    try std.testing.expect(core.msg_show_auto_hide_at == null);
    // The next empty cycle has nothing to hide — no spurious action.
    try core.msg_views.beginCycle(core.alloc, 0);
    try std.testing.expectEqual(msg_view.Action.none, core.msg_views.action(.ext_float));
}

test "scrolling the message float pauses its auto-hide" {
    // The ext_float grid is synthetic — the Neovim cursor cannot enter it —
    // so scrolling is its "cursor moved in" equivalent: the user is reading,
    // and the countdown must stop. Pause is not hide: the float stays.
    var core = Core.initForTest(std.testing.allocator);
    defer core.deinitForTest();
    core.ext_messages_enabled = true;

    // Catch-all default routes echo to ext_float with the 4s view default.
    try appendTestMessage(&core, 1, "echo", "readable");
    _ = sendMsgShow(&core);
    // Direct sendMsgShow bypasses notifyMessageChanges, which is what clears
    // msg_dirty in production. Clear it here, or the flush bracket inside the
    // scroll would legitimately re-show and re-arm the timeout.
    core.grid.message_state.msg_dirty = false;
    try std.testing.expect(core.msg_show_auto_hide_at != null);

    handleMsgGridScroll(&core, "down");

    try std.testing.expect(core.msg_show_auto_hide_at == null);
    try std.testing.expect(core.msg_views.state(.ext_float).visible);
    try std.testing.expect(core.grid.external_grids.contains(grid_mod.MESSAGE_GRID_ID));
}

test "hovering the message float pauses its auto-hide" {
    // Same reasoning as the scroll pause: the pointer resting on the float is
    // the user reading it, or reaching for the copy button. The countdown must
    // stop, and the float must stay visible.
    var core = Core.initForTest(std.testing.allocator);
    defer core.deinitForTest();
    core.ext_messages_enabled = true;

    try appendTestMessage(&core, 1, "echo", "readable");
    _ = sendMsgShow(&core);
    try std.testing.expect(core.msg_show_auto_hide_at != null);

    setChannelHover(&core, .show, true);

    try std.testing.expect(core.msg_show_auto_hide_at == null);
    try std.testing.expect(core.msg_views.state(.ext_float).visible);
}

test "leaving the message float re-arms the full timeout" {
    // Unlike the scroll pause, hover is a state with a defined end: the pointer
    // leaving restarts the countdown at full length rather than waiting for the
    // next show cycle.
    var core = Core.initForTest(std.testing.allocator);
    defer core.deinitForTest();
    core.ext_messages_enabled = true;

    try appendTestMessage(&core, 1, "echo", "readable");
    _ = sendMsgShow(&core);
    const armed_at = core.msg_show_auto_hide_at.?;

    setChannelHover(&core, .show, true);
    setChannelHover(&core, .show, false);

    // Full length, not the remainder: the resumed deadline is no earlier than
    // the original one.
    const resumed_at = core.msg_show_auto_hide_at orelse return error.NotReArmed;
    try std.testing.expect(resumed_at >= armed_at);
}

test "a message shown while hovered does not arm its auto-hide" {
    // A new message can land on a float the pointer is already over. Arming it
    // would hide the float mid-read, which is exactly what hover prevents.
    var core = Core.initForTest(std.testing.allocator);
    defer core.deinitForTest();
    core.ext_messages_enabled = true;

    try appendTestMessage(&core, 1, "echo", "first");
    _ = sendMsgShow(&core);
    setChannelHover(&core, .show, true);

    try appendTestMessage(&core, 2, "echo", "second");
    _ = sendMsgShow(&core);

    try std.testing.expect(core.msg_show_auto_hide_at == null);
    try std.testing.expect(core.msg_views.state(.ext_float).visible);
}

test "leaving a hidden message float does not resurrect its deadline" {
    // The window can close under a stationary pointer (msg_clear, auto-hide),
    // and the frontend's exit event arrives afterwards. Resume must not re-arm
    // a view the core no longer shows, or nextMsgTimeoutNs would wake forever.
    var core = Core.initForTest(std.testing.allocator);
    defer core.deinitForTest();
    core.ext_messages_enabled = true;

    try appendTestMessage(&core, 1, "echo", "readable");
    _ = sendMsgShow(&core);
    setChannelHover(&core, .show, true);

    core.grid.message_state.clearMessages(core.grid.alloc);
    hideChannelView(&core, .show, .ext_float);

    setChannelHover(&core, .show, false);

    try std.testing.expect(core.msg_show_auto_hide_at == null);
}

test "a zero-timeout message stays un-armed across a hover cycle" {
    // timeout=0 means "no auto-hide" (errors). Resume must respect that rather
    // than inventing a countdown for a message that should persist.
    var core = Core.initForTest(std.testing.allocator);
    defer core.deinitForTest();
    core.ext_messages_enabled = true;

    try appendTestMessage(&core, 1, "echo", "sticky");
    _ = sendMsgShow(&core);
    // Emulate a route whose view timeout is 0 by clearing what the show armed.
    core.msg_show_auto_hide_at = null;
    core.msg_show_auto_hide_ns = null;

    setChannelHover(&core, .show, true);
    setChannelHover(&core, .show, false);

    try std.testing.expect(core.msg_show_auto_hide_at == null);
}

test "hiding the history grid drops its retry deadline" {
    // nextMsgTimeoutNs reads msg_history_retry_at unconditionally, but only
    // the history_dirty block clears it. An auto-hide landing between a
    // failed dispatch and its retry clears the dirty flag, so without this
    // the deadline stays stranded in the past and the frontend re-arms a 0ms
    // timer forever, each tick driving a full flush under grid_mu.
    var core = Core.initForTest(std.testing.allocator);
    defer core.deinitForTest();
    core.ext_messages_enabled = true;

    core.msg_history_retry_at = clock.nowNs() - std.time.ns_per_s;
    core.msg_history_retry_delay_ns = 512 * std.time.ns_per_ms;
    try std.testing.expect(nextMsgTimeoutNs(&core) != null);

    hideMsgHistory(&core);

    try std.testing.expect(core.msg_history_retry_at == null);
    try std.testing.expectEqual(@as(i128, 16 * std.time.ns_per_ms), core.msg_history_retry_delay_ns);
    try std.testing.expect(nextMsgTimeoutNs(&core) == null);
}

test "a failed message dispatch arms a retry the frontend can see" {
    // The whole abort-and-retry design rests on the frontend arming a timer
    // from nextMsgTimeoutNs. Setting msg_show_retry_at alone did not do that:
    // every reader of it is gated on msg_show_pending_since, so the deadline
    // was written and never read, and a prompt-blocked Neovim emits no
    // further redraw to drive a retry any other way.
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var core = Core.initForTest(failing.allocator());
    defer core.deinitForTest();
    core.ext_messages_enabled = true;

    try appendTestMessage(&core, 1, "echo", "content");
    core.grid.message_state.msg_dirty = true;
    try std.testing.expect(nextMsgTimeoutNs(&core) == null);

    // Fail the dispatch: beginCycle's allocation is the first thing to go.
    failing.fail_index = failing.alloc_index;
    failing.resize_fail_index = failing.resize_index;
    notifyMessageChanges(&core);

    try std.testing.expect(core.grid.message_state.msg_dirty);
    try std.testing.expect(nextMsgTimeoutNs(&core) != null);
}

// The message subsystem's deadline bookkeeping produced three separate
// defects of one shape: a field armed on one path and cleared only on
// another, so a state nobody enumerated left the frontend re-arming a timer
// forever. These pin the paths that produced them. They were first written
// against a scratch copy with the fixes reverted, where each one fails.

test "an auto-hide that clears history dirty also drops its retry deadline" {
    // The real route into the stranded state: a history dispatch failed
    // (deadline armed, dirty kept), then the auto-hide fired first and
    // cleared dirty — making the only other clear site unreachable. This
    // goes through checkMsgAutoHideTimeout rather than calling the hide
    // directly, so it covers the ordering inside hideChannelView too.
    var core = Core.initForTest(std.testing.allocator);
    defer core.deinitForTest();
    core.ext_messages_enabled = true;

    core.msg_history_retry_at = clock.nowNs() - std.time.ns_per_s;
    core.msg_history_retry_delay_ns = 512 * std.time.ns_per_ms;
    core.grid.msg_history_state.dirty = true;
    core.msg_history_auto_hide_at = clock.nowNs() - std.time.ns_per_ms;

    checkMsgAutoHideTimeout(&core);

    try std.testing.expect(!core.grid.msg_history_state.dirty);
    try std.testing.expect(core.msg_history_retry_at == null);
    try std.testing.expectEqual(@as(i128, 16 * std.time.ns_per_ms), core.msg_history_retry_delay_ns);
    try std.testing.expect(nextMsgTimeoutNs(&core) == null);
}

test "no tick path can re-produce an elapsed history deadline" {
    // The consequence the previous test guards against is a frontend timer
    // armed at zero forever, so assert the property the frontend actually
    // reads, repeatedly, across every entry point a tick drives.
    var core = Core.initForTest(std.testing.allocator);
    defer core.deinitForTest();
    core.ext_messages_enabled = true;

    core.msg_history_retry_at = clock.nowNs() - std.time.ns_per_s;
    core.grid.msg_history_state.dirty = true;
    core.msg_history_auto_hide_at = clock.nowNs() - std.time.ns_per_ms;
    checkMsgAutoHideTimeout(&core);

    var i: usize = 0;
    while (i < 5) : (i += 1) {
        notifyMessageChanges(&core);
        checkMsgShowThrottleTimeout(&core);
        checkMsgAutoHideTimeout(&core);
        try std.testing.expect(nextMsgTimeoutNs(&core) == null);
    }
}

test "a session reset drops the history retry deadline" {
    var core = Core.initForTest(std.testing.allocator);
    defer core.deinitForTest();
    core.ext_messages_enabled = true;
    core.msg_history_retry_at = clock.nowNs() - std.time.ns_per_s;
    core.grid.msg_history_state.dirty = true;

    core.resetRedrawProtocolState();

    try std.testing.expect(!core.grid.msg_history_state.dirty);
    try std.testing.expect(core.msg_history_retry_at == null);
}

/// Drives a flush that the frontend rejects at the bracket, which is the only
/// way to reach onFlush's abort-path deadline coalescer.
const AbortProbe = struct {
    var target: ?*Core = null;
    fn onBegin(_: ?*anyopaque) callconv(.c) void {
        if (target) |c| c.flush_aborted = true;
    }
};

test "an aborted flush pushes a due history deadline into the future" {
    // Without history in the coalescer, an abort left msg_history_retry_at
    // elapsed and nextMsgTimeoutNs reported zero, so the frontend re-armed a
    // 0ms timer and drove a full flush per tick under grid_mu.
    var core = Core.initForTest(std.testing.allocator);
    defer core.deinitForTest();
    core.ext_messages_enabled = true;
    AbortProbe.target = &core;
    defer AbortProbe.target = null;
    core.cb.on_flush_begin = AbortProbe.onBegin;

    core.msg_history_retry_at = clock.nowNs() - std.time.ns_per_s;
    core.grid.msg_history_state.dirty = true;

    var ctx = FlushCtx{ .core = &core };
    try ctx.onFlush(1, 1);

    try std.testing.expect(core.flush_aborted);
    try std.testing.expect(core.msg_history_retry_at.? > clock.nowNs());
    try std.testing.expect(nextMsgTimeoutNs(&core).? > clock.nowNs());
}

test "the abort coalescer moves only the deadlines that were due" {
    // It folds several unrelated deadlines onto one value; adding history to
    // that set must not disturb the others, and must not touch a deadline
    // that has not elapsed.
    var core = Core.initForTest(std.testing.allocator);
    defer core.deinitForTest();
    core.ext_messages_enabled = true;
    AbortProbe.target = &core;
    defer AbortProbe.target = null;
    core.cb.on_flush_begin = AbortProbe.onBegin;

    const now = clock.nowNs();
    const future = now + 10 * std.time.ns_per_s;
    core.msg_history_retry_at = now - 1;
    core.atlas_negative_retry_at = now - 1;
    core.msg_history_auto_hide_at = now - 1;
    core.msg_show_auto_hide_at = future;
    core.transient_glyph_retry_at = future;

    var ctx = FlushCtx{ .core = &core };
    try ctx.onFlush(1, 1);

    const at = core.msg_history_retry_at.?;
    try std.testing.expectEqual(at, core.atlas_negative_retry_at.?);
    try std.testing.expectEqual(at, core.msg_history_auto_hide_at.?);
    try std.testing.expect(at > clock.nowNs());
    try std.testing.expectEqual(future, core.msg_show_auto_hide_at.?);
    try std.testing.expectEqual(future, core.transient_glyph_retry_at.?);
}

test "a message arriving during a retry backoff is delayed, not lost" {
    // The gate that suppresses re-attempts must not swallow work: the
    // message has to survive the wait and be displayed once the deadline
    // passes, with the retry state cleared behind it.
    var core = Core.initForTest(std.testing.allocator);
    defer core.deinitForTest();
    core.ext_messages_enabled = true;

    // .split with no writer thread: the dispatch always fails, which is how
    // the backoff gets armed without an allocator fault.
    var split_routes = [_]config.MsgRoute{
        .{ .filter = .{ .event = .msg_show }, .view = .split },
    };
    core.msg_config.messages.routes = &split_routes;
    try appendTestMessage(&core, 1, "echo", "first");
    notifyMessageChanges(&core);
    try std.testing.expect(core.msg_show_retry_at != null);

    try appendTestMessage(&core, 2, "echo", "second");
    notifyMessageChanges(&core);
    try std.testing.expectEqual(@as(usize, 2), core.grid.message_state.messages.items.len);
    try std.testing.expect(core.grid.message_state.msg_dirty);
    try std.testing.expect(nextMsgTimeoutNs(&core) != null);

    // Deadline reached, and a view that can actually succeed.
    var shown: usize = 0;
    const ShowProbe = struct {
        var count: *usize = undefined;
        fn onShow(
            _: ?*anyopaque,
            _: c_api.zonvie_msg_view_type,
            _: [*]const u8,
            _: usize,
            _: [*]const c_api.MsgChunk,
            _: usize,
            _: c_int,
            _: c_int,
            _: c_int,
            _: i64,
            _: u32,
        ) callconv(.c) void {
            count.* += 1;
        }
    };
    ShowProbe.count = &shown;
    core.cb.on_msg_show = ShowProbe.onShow;
    var mini_routes = [_]config.MsgRoute{
        .{ .filter = .{ .event = .msg_show }, .view = .mini },
    };
    core.msg_config.messages.routes = &mini_routes;
    core.msg_show_retry_at = clock.nowNs() - 1;

    notifyMessageChanges(&core);
    try std.testing.expect(shown > 0);
    try std.testing.expect(!core.grid.message_state.msg_dirty);
    try std.testing.expect(core.msg_show_retry_at == null);
    try std.testing.expectEqual(@as(i128, 16 * std.time.ns_per_ms), core.msg_show_retry_delay_ns);
}

test "the split payload budget drops only what the write queue cannot carry" {
    // The give-up branch is the one place in the split arm that neither sends
    // nor aborts: it frees the messages and returns success. An error in
    // either direction is silent — too low and legitimate `:messages` output
    // vanishes, too high and the payload fails on every retry forever. Both
    // sides of the boundary are pinned here.
    //
    // Test cores have no writer thread, so a payload that clears the budget
    // reaches `createMessageSplit` and fails there with BrokenPipe. That is
    // the discriminator: over budget returns true (dropped without sending),
    // under budget returns false (a send was attempted).
    const budget = Core.MAX_WRITE_QUEUE_SIZE - Core.split_lua_buf_len;

    var clear_calls: usize = 0;
    const Probe = struct {
        var calls: *usize = undefined;
        fn onClear(_: ?*anyopaque) callconv(.c) void {
            calls.* += 1;
        }
    };
    Probe.calls = &clear_calls;

    // Over budget: dropped, no send, and the frontend is left alone.
    {
        var core = Core.initForTest(std.testing.allocator);
        defer core.deinitForTest();
        core.cb.on_msg_clear = Probe.onClear;

        const filler = try std.testing.allocator.alloc(u8, budget + 1);
        defer std.testing.allocator.free(filler);
        @memset(filler, 'x');
        try appendTestMessage(&core, 1, "echo", filler);
        const messages = core.grid.message_state.messages.items;
        try core.msg_views.beginCycle(core.alloc, messages.len);
        core.msg_views.assign(0, .split, 0, null);

        try std.testing.expect(showChannelView(&core, .show, .split, .{ .show = messages }));
        try std.testing.expect(!core.flush_aborted);
        // The content is gone, so the frontend must not keep drawing what
        // this batch was meant to replace.
        try std.testing.expectEqual(@as(usize, 1), clear_calls);
    }

    // One byte under: the send is attempted. It fails only because the test
    // core has no transport, which is what makes the attempt observable.
    clear_calls = 0;
    {
        var core = Core.initForTest(std.testing.allocator);
        defer core.deinitForTest();
        core.cb.on_msg_clear = Probe.onClear;

        // The assembled buffer gains one newline per message.
        const filler = try std.testing.allocator.alloc(u8, budget - 1);
        defer std.testing.allocator.free(filler);
        @memset(filler, 'x');
        try appendTestMessage(&core, 1, "echo", filler);
        const messages = core.grid.message_state.messages.items;
        try core.msg_views.beginCycle(core.alloc, messages.len);
        core.msg_views.assign(0, .split, 0, null);

        try std.testing.expect(!showChannelView(&core, .show, .split, .{ .show = messages }));
        try std.testing.expectEqual(@as(usize, 0), clear_calls);
    }
}

test "a pending retry deadline suppresses the next immediate attempt" {
    // The deadline is only worth arming if something honours it: without the
    // gate a permanently-failing dispatch re-attempts on every flush while
    // doubling a delay nobody reads. The backoff itself is the observable —
    // an attempt that fails doubles it, a suppressed attempt leaves it alone.
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var core = Core.initForTest(failing.allocator());
    defer core.deinitForTest();
    core.ext_messages_enabled = true;

    try appendTestMessage(&core, 1, "echo", "content");

    failing.fail_index = failing.alloc_index;
    failing.resize_fail_index = failing.resize_index;
    notifyMessageChanges(&core);
    try std.testing.expect(core.grid.message_state.msg_dirty);
    const armed = core.msg_show_retry_at orelse return error.RetryDeadlineNotArmed;
    const delay_after_failure = core.msg_show_retry_delay_ns;
    try std.testing.expect(delay_after_failure > 16 * std.time.ns_per_ms);

    // Healthy allocator, deadline still in the future: no attempt is made,
    // so the backoff does not move and the deadline is not consumed.
    failing.fail_index = std.math.maxInt(usize);
    failing.resize_fail_index = std.math.maxInt(usize);
    core.flush_aborted = false;
    notifyMessageChanges(&core);
    try std.testing.expect(core.grid.message_state.msg_dirty);
    try std.testing.expectEqual(delay_after_failure, core.msg_show_retry_delay_ns);
    try std.testing.expectEqual(@as(?i128, armed), core.msg_show_retry_at);

    // Once due, the attempt runs and succeeds, clearing the retry state.
    core.msg_show_retry_at = clock.nowNs() - 1;
    notifyMessageChanges(&core);
    try std.testing.expect(!core.grid.message_state.msg_dirty);
    try std.testing.expect(core.msg_show_retry_at == null);
    try std.testing.expectEqual(@as(i128, 16 * std.time.ns_per_ms), core.msg_show_retry_delay_ns);
}

test "an OOM during split assembly retries instead of showing partial content" {
    // The split arm used to `catch break` per message and show whatever had
    // landed — content with its middle missing, unrecoverably, because the
    // originals are dropped after dispatch. It now behaves like the
    // ext_float arm: abort the flush, keep the messages, retry. Assembly
    // also runs before on_msg_clear, so a failed attempt leaves the
    // frontend's message UI untouched rather than cleared with nothing to
    // replace it.
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var core = Core.initForTest(failing.allocator());
    defer core.deinitForTest();

    var clear_calls: usize = 0;
    const Probe = struct {
        var calls: *usize = undefined;
        fn onClear(_: ?*anyopaque) callconv(.c) void {
            calls.* += 1;
        }
    };
    Probe.calls = &clear_calls;
    core.cb.on_msg_clear = Probe.onClear;

    try appendTestMessage(&core, 1, "echo", "one");
    try appendTestMessage(&core, 2, "echo", "x" ** 4096);
    const messages = core.grid.message_state.messages.items;

    try core.msg_views.beginCycle(core.alloc, messages.len);
    core.msg_views.assign(0, .split, 0, null);
    core.msg_views.assign(1, .split, 0, null);

    try core.msg_split_buf.ensureTotalCapacity(core.alloc, 64);
    failing.fail_index = failing.alloc_index;
    failing.resize_fail_index = failing.resize_index;

    try std.testing.expect(!showChannelView(&core, .show, .split, .{ .show = messages }));
    try std.testing.expect(core.flush_aborted);
    // on_msg_clear must not have fired: the frontend's message UI stays as it
    // was rather than being emptied with nothing to replace it.
    try std.testing.expectEqual(@as(usize, 0), clear_calls);
}

test "message timeout conversion rejects invalid values and saturates" {
    try std.testing.expectEqual(@as(u32, 4000), messageTimeoutMs(4.0));
    try std.testing.expectEqual(@as(u32, 0), messageTimeoutMs(0));
    try std.testing.expectEqual(@as(u32, 0), messageTimeoutMs(-1));
    try std.testing.expectEqual(@as(u32, 0), messageTimeoutMs(std.math.nan(f32)));
    try std.testing.expectEqual(@as(u32, 0), messageTimeoutMs(std.math.inf(f32)));
    try std.testing.expectEqual(std.math.maxInt(u32), messageTimeoutMs(1.0e30));
    try std.testing.expectEqual(@as(?i128, 4 * std.time.ns_per_s), messageTimeoutNs(4.0));
    try std.testing.expectEqual(@as(?i128, null), messageTimeoutNs(std.math.nan(f32)));
}

// ---------------------------------------------------------------------------
// Emoji cluster caching: equal keys must name equal pictures
//
// The fallback glyph cache stores a rasterized cluster under
// clusterCacheKey(base_scalar, style_index, overflow_extras), while the
// rasterizer is handed whatever buildEmojiCluster assembles. Caching is only
// sound if the second is a function of the first, so these pin the chain:
//
//   key  ⇒ (base_scalar, style, extras)      -- cluster key tests
//        ⇒ emoji-vs-plain branch              -- extrasMarkEmojiCluster
//        ⇒ exact scalars handed to rasterize  -- buildEmojiCluster
//        ⇒ bitmap
//
// A key coarser than the bitmap renders one emoji as another, and nothing
// below the glass notices: the hit is a hit and the vertices are well-formed.
// The test/gui scenario visual/emoji_cluster_cache checks the same property on
// real pixels; these check it where no screen — and no screen-recording
// permission — is required, which is the only place a build host can.
// ---------------------------------------------------------------------------

const ZWJ: u32 = 0x200D;
const VS16: u32 = 0xFE0F;
const WOMAN: u32 = 0x1F469;
const LAPTOP: u32 = 0x1F4BB;
const MICROSCOPE: u32 = 0x1F52C;
const HEART: u32 = 0x2764;
const WARNING: u32 = 0x26A0;

test "cluster key separates a bare base from the same base with a ZWJ tail" {
    // 👩 vs 👩‍💻: a key built from the base scalar alone collapses these.
    try std.testing.expect(clusterCacheKey(WOMAN, 0, null) !=
        clusterCacheKey(WOMAN, 0, &.{ ZWJ, LAPTOP }));
}

test "cluster key separates two ZWJ sequences sharing base and joiner" {
    // 👩‍💻 vs 👩‍🔬 — the pair flush.zig's own key comment names.
    try std.testing.expect(clusterCacheKey(WOMAN, 0, &.{ ZWJ, LAPTOP }) !=
        clusterCacheKey(WOMAN, 0, &.{ ZWJ, MICROSCOPE }));
}

test "cluster key separates text and emoji presentation of one scalar" {
    // ❤ vs ❤️ differ only by a variation selector carried in the overflow map.
    const text = clusterCacheKey(HEART, 0, null);
    try std.testing.expect(text != clusterCacheKey(HEART, 0, &.{VS16}));
    // An empty tail must agree with no tail: both mean the rasterizer receives
    // the base scalar alone, so they must not occupy separate entries.
    try std.testing.expectEqual(text, clusterCacheKey(HEART, 0, &.{}));
}

test "cluster key depends on tail order, not just the multiset" {
    // Distinct grapheme clusters can share codepoints in a different order; a
    // commutative fold would hand them one bitmap.
    try std.testing.expect(clusterCacheKey(WOMAN, 0, &.{ ZWJ, LAPTOP, ZWJ, MICROSCOPE }) !=
        clusterCacheKey(WOMAN, 0, &.{ ZWJ, MICROSCOPE, ZWJ, LAPTOP }));
}

test "cluster key separates styles and bases" {
    try std.testing.expect(clusterCacheKey(WARNING, 0, &.{VS16}) !=
        clusterCacheKey(HEART, 0, &.{VS16}));
    try std.testing.expect(clusterCacheKey(WARNING, 0, &.{VS16}) !=
        clusterCacheKey(WARNING, 1, &.{VS16}));
}

test "cluster hash tracks the key across the same distinctions" {
    // The hash only picks the probe slot, so a collision costs a miss rather
    // than a wrong glyph — but a hash ignoring the tail would send every
    // sequence sharing a base to one slot and evict them in a loop.
    try std.testing.expect(clusterCacheHash(WOMAN, 0, &.{ ZWJ, LAPTOP }) !=
        clusterCacheHash(WOMAN, 0, &.{ ZWJ, MICROSCOPE }));
    try std.testing.expect(clusterCacheHash(HEART, 0, null) !=
        clusterCacheHash(HEART, 0, &.{VS16}));
}

test "the emoji branch is decided by the tail alone" {
    // Same extras must give the same answer no matter which cell they came
    // from — the key carries the extras but not the cell.
    try std.testing.expect(extrasMarkEmojiCluster(&.{VS16}));
    try std.testing.expect(extrasMarkEmojiCluster(&.{ ZWJ, LAPTOP }));
    try std.testing.expect(extrasMarkEmojiCluster(&.{0x1F3FB})); // skin tone
    try std.testing.expect(!extrasMarkEmojiCluster(&.{}));
    try std.testing.expect(!extrasMarkEmojiCluster(&.{0x0301})); // combining acute
    const tail = [_]u32{ ZWJ, MICROSCOPE };
    try std.testing.expectEqual(extrasMarkEmojiCluster(&tail), extrasMarkEmojiCluster(&tail));
}

test "the cluster handed to the rasterizer is base scalar then tail" {
    var buf: [16]u32 = undefined;
    const len = buildEmojiCluster(&buf, WOMAN, &.{ ZWJ, LAPTOP });
    try std.testing.expectEqual(@as(u8, 3), len);
    try std.testing.expectEqualSlices(u32, &.{ WOMAN, ZWJ, LAPTOP }, buf[0..len]);

    const bare = buildEmojiCluster(&buf, HEART, null);
    try std.testing.expectEqual(@as(u8, 1), bare);
    try std.testing.expectEqualSlices(u32, &.{HEART}, buf[0..bare]);

    // An empty tail must be indistinguishable from no tail, matching the key.
    try std.testing.expectEqual(bare, buildEmojiCluster(&buf, HEART, &.{}));
}

test "clusters that key differently are handed different scalars" {
    // Carried one step past the key tests: distinct keys must also mean
    // distinct rasterizer input. A key finer than the picture merely wastes
    // entries; a key coarser than it is the defect this guards.
    const cases = [_]struct { base: u32, extras: ?[]const u32 }{
        .{ .base = WOMAN, .extras = null },
        .{ .base = WOMAN, .extras = &.{ ZWJ, LAPTOP } },
        .{ .base = WOMAN, .extras = &.{ ZWJ, MICROSCOPE } },
        .{ .base = HEART, .extras = null },
        .{ .base = HEART, .extras = &.{VS16} },
    };
    var buf_a: [16]u32 = undefined;
    var buf_b: [16]u32 = undefined;
    for (cases, 0..) |a, i| {
        for (cases, 0..) |b, j| {
            if (i == j) continue;
            try std.testing.expect(clusterCacheKey(a.base, 0, a.extras) !=
                clusterCacheKey(b.base, 0, b.extras));
            const la = buildEmojiCluster(&buf_a, a.base, a.extras);
            const lb = buildEmojiCluster(&buf_b, b.base, b.extras);
            try std.testing.expect(!std.mem.eql(u32, buf_a[0..la], buf_b[0..lb]));
        }
    }
}

test "a tail longer than the cluster buffer truncates instead of overrunning" {
    var buf: [4]u32 = undefined;
    const long = [_]u32{ ZWJ, LAPTOP, ZWJ, MICROSCOPE, ZWJ, HEART };
    const len = buildEmojiCluster(&buf, WOMAN, &long);
    try std.testing.expectEqual(@as(u8, 4), len);
    try std.testing.expectEqualSlices(u32, &.{ WOMAN, ZWJ, LAPTOP, ZWJ }, buf[0..len]);
}

test "a block element in normal text is marked as foreground, not background" {
    // U+2588 FULL BLOCK is filled geometrically rather than rasterized, so it
    // reaches the frontend as a solid quad. Without a flag saying it is text,
    // the shader takes it for a background cell and fades it to the window's
    // background alpha under blur, while the glyphs beside it stay opaque.
    const State = struct {
        solid_glyph_quads: u32 = 0,
        unflagged_solid_quads: u32 = 0,

        // The glyph pass only runs when the frontend offers some way to
        // resolve a glyph. Block elements never reach it, but the gate is
        // upstream of them.
        fn ensure(
            ctx: ?*anyopaque,
            scalar: u32,
            out_entry: ?*c_api.GlyphEntry,
        ) callconv(.c) c_int {
            _ = ctx;
            _ = scalar;
            _ = out_entry;
            return 0;
        }

        fn onVertices(
            ctx: ?*anyopaque,
            main_verts: ?[*]const c_api.Vertex,
            main_count: usize,
            cursor_verts: ?[*]const c_api.Vertex,
            cursor_count: usize,
            flags: u32,
        ) callconv(.c) void {
            _ = cursor_verts;
            _ = cursor_count;
            _ = flags;
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            const verts = main_verts orelse return;
            for (verts[0..main_count]) |v| {
                // texCoord.x < 0 marks a solid quad; an atlas glyph carries a UV.
                if (v.texCoord[0] >= 0) continue;
                if ((v.deco_flags & c_api.DECO_SOLID_GLYPH) != 0) {
                    self.solid_glyph_quads += 1;
                } else {
                    self.unflagged_solid_quads += 1;
                }
            }
        }
    };

    var core = Core.initForTest(std.testing.allocator);
    defer core.deinitForTest();
    try core.grid.resizeGrid(1, 1, 2);
    core.grid.putCell(0, 0, 0x2588, 0); // FULL BLOCK
    core.grid.putCell(0, 1, ' ', 0); // plain background cell, for contrast
    core.drawable_w_px = 2;
    core.drawable_h_px = 1;
    core.cell_w_px = 1;
    core.cell_h_px = 1;

    var state = State{};
    core.ctx = &state;
    core.cb.on_atlas_ensure_glyph = State.ensure;
    core.cb.on_vertices_partial = State.onVertices;

    var flush_ctx = FlushCtx{ .core = &core };
    try flush_ctx.onFlush(1, 2);

    // The block element produced solid quads and every one of them is flagged.
    try std.testing.expect(state.solid_glyph_quads > 0);
    // The blank cell's background quad must NOT be flagged, or the frontend
    // would stop fading real backgrounds under a translucent window.
    try std.testing.expect(state.unflagged_solid_quads > 0);
}

test "each status channel reaches its own route and its own callback" {
    // The three senders used to be three separately-named functions, so
    // crossing a channel's route or callback meant visibly editing the wrong
    // one. Merging them turned that into two hand-written switch tables, and
    // a swap there is silent -- the ruler would render as the mode indicator.
    // Give each channel a distinct route and a distinct callback so a crossed
    // mapping shows up as the wrong callback firing, or none at all.
    const State = struct {
        showmode_calls: u32 = 0,
        showcmd_calls: u32 = 0,
        ruler_calls: u32 = 0,
        showmode_view: c_api.zonvie_msg_view_type = .none,
        showcmd_view: c_api.zonvie_msg_view_type = .none,

        fn onShowmode(ctx: ?*anyopaque, view: c_api.zonvie_msg_view_type, chunks: [*]const c_api.MsgChunk, count: usize) callconv(.c) void {
            _ = chunks;
            _ = count;
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            self.showmode_calls += 1;
            self.showmode_view = view;
        }
        fn onShowcmd(ctx: ?*anyopaque, view: c_api.zonvie_msg_view_type, chunks: [*]const c_api.MsgChunk, count: usize) callconv(.c) void {
            _ = chunks;
            _ = count;
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            self.showcmd_calls += 1;
            self.showcmd_view = view;
        }
        fn onRuler(ctx: ?*anyopaque, view: c_api.zonvie_msg_view_type, chunks: [*]const c_api.MsgChunk, count: usize) callconv(.c) void {
            _ = view;
            _ = chunks;
            _ = count;
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            self.ruler_calls += 1;
        }
    };

    var core = Core.initForTest(std.testing.allocator);
    defer core.deinitForTest();
    core.ext_messages_enabled = true;

    // Distinct per-event routing: showmode -> mini, showcmd -> ext_float,
    // ruler -> none (suppressed). Crossing the MsgEvent mapping therefore
    // changes which view a callback reports, or suppresses the wrong channel.
    var routes = [_]config.MsgRoute{
        .{ .filter = .{ .event = .msg_showmode }, .view = .mini, .opts = .{ .timeout = 0 } },
        .{ .filter = .{ .event = .msg_showcmd }, .view = .ext_float, .opts = .{ .timeout = 0 } },
        .{ .filter = .{ .event = .msg_ruler }, .view = .none, .opts = .{ .timeout = 0 } },
    };
    core.msg_config.messages.routes = &routes;

    var state = State{};
    core.ctx = &state;
    core.cb.on_msg_showmode = State.onShowmode;
    core.cb.on_msg_showcmd = State.onShowcmd;
    core.cb.on_msg_ruler = State.onRuler;

    try core.grid.setMsgStatus(.showmode, &.{.{ .hl_id = 0, .text = "-- INSERT --" }});
    try core.grid.setMsgStatus(.showcmd, &.{.{ .hl_id = 0, .text = "3d" }});
    try core.grid.setMsgStatus(.ruler, &.{.{ .hl_id = 0, .text = "1,1" }});
    notifyMessageChanges(&core);

    // Each channel used its OWN route: showmode was shown as mini, showcmd as
    // ext_float, and ruler was suppressed before reaching its callback.
    try std.testing.expectEqual(@as(u32, 1), state.showmode_calls);
    try std.testing.expectEqual(c_api.zonvie_msg_view_type.mini, state.showmode_view);
    try std.testing.expectEqual(@as(u32, 1), state.showcmd_calls);
    try std.testing.expectEqual(c_api.zonvie_msg_view_type.ext_float, state.showcmd_view);
    try std.testing.expectEqual(@as(u32, 0), state.ruler_calls);

    // A channel with nothing dirty must not be sent again on the next flush.
    notifyMessageChanges(&core);
    try std.testing.expectEqual(@as(u32, 1), state.showmode_calls);
    try std.testing.expectEqual(@as(u32, 1), state.showcmd_calls);
}
