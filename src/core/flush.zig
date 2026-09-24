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

pub const GridEntry = struct {
    grid_id: i64,
    zindex: i64,
    compindex: i64,
    order: u64,
};

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
        core.grid.main_buf.surface_vertex_count,
        core.grid.subgrid_surface_vertex_count,
    ) catch return vertexBudgetExceeded(core);
    if (enforce_limits and
        (core.grid.main_buf.surface_vertex_count > MAX_VERTICES_PER_SURFACE or
            aggregate > MAX_VERTICES_AGGREGATE))
    {
        return vertexBudgetExceeded(core);
    }
    core.flush_vertex_count_aggregate = aggregate;
}

fn beginVertexBudgetTransaction(core: *Core) !void {
    if (core.vertex_budget_transaction_active) return vertexBudgetExceeded(core);
    try syncVertexBudgetAggregate(core, true);
    core.grid.main_buf.vertex_budget_touched = false;
    // The intrusive touched list is rebuilt from the head, so a sub-grid whose
    // flag survived a torn-down transaction would never be re-linked and would
    // escape the per-surface limit. Clearing main's flag defensively and not
    // theirs was the asymmetry; `GridBuf.resize` nulling `vertex_budget_touched_next`
    // mid-transaction is the path that can leave one set.
    var sg_it = core.grid.sub_grids.valueIterator();
    while (sg_it.next()) |sg| {
        sg.vertex_budget_touched = false;
        sg.vertex_budget_touched_next = null;
    }
    core.vertex_budget_touched_grid_head = null;
    core.vertex_budget_transaction_active = true;
}

fn validateCompletedVertexBudget(core: *Core) !void {
    try syncVertexBudgetAggregate(core, true);
    if (core.grid.main_buf.vertex_budget_touched and
        core.grid.main_buf.surface_vertex_count > MAX_VERTICES_PER_SURFACE)
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

fn touchGridVertexBudget(core: *Core, grid_id: i64, buf: *grid_mod.GridBuf) void {
    if (buf.vertex_budget_touched) return;
    buf.vertex_budget_touched = true;
    if (grid_id == 1) return;
    buf.vertex_budget_touched_next = core.vertex_budget_touched_grid_head;
    core.vertex_budget_touched_grid_head = grid_id;
}

fn clearTouchedVertexBudgetSurfaces(core: *Core) void {
    core.grid.main_buf.vertex_budget_touched = false;
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
fn snapshotVertexRowLedgers(core: *Core) bool {
    core.flush_row_ledger_snapshot_valid = false;
    if (!core.grid.main_buf.vertex_row_ledger_valid) return false;
    const counts = core.grid.main_buf.vertex_row_counts;
    core.flush_row_counts_snapshot.ensureTotalCapacity(core.alloc, counts.len) catch return false;
    core.flush_row_counts_snapshot.items.len = counts.len;
    @memcpy(core.flush_row_counts_snapshot.items, counts);
    core.flush_main_vertex_count_snapshot = core.grid.main_buf.surface_vertex_count;

    // Retire last attempt's entries before recording this one's.
    var stale = core.flush_subgrid_ledgers.valueIterator();
    while (stale.next()) |entry| entry.live = false;

    var sg_it = core.grid.sub_grids.iterator();
    while (sg_it.next()) |e| {
        const buf = e.value_ptr;
        // One unaccounted surface makes the whole restore unsound, so fall back
        // to the invalidate-everything recovery exactly as main does.
        if (!buf.vertex_row_ledger_valid) return false;
        const gop = core.flush_subgrid_ledgers.getOrPut(core.alloc, e.key_ptr.*) catch return false;
        if (!gop.found_existing) gop.value_ptr.* = .{};
        const saved = gop.value_ptr;
        saved.counts.ensureTotalCapacity(core.alloc, buf.vertex_row_counts.len) catch return false;
        saved.counts.items.len = buf.vertex_row_counts.len;
        @memcpy(saved.counts.items, buf.vertex_row_counts);
        saved.surface_vertex_count = buf.surface_vertex_count;
        saved.live = true;
    }
    core.flush_subgrid_aggregate_snapshot = core.grid.subgrid_surface_vertex_count;
    core.flush_row_ledger_snapshot_valid = true;
    return true;
}

fn restoreVertexRowLedgers(core: *Core) bool {
    if (!core.flush_row_ledger_snapshot_valid) return false;
    const saved = core.flush_row_counts_snapshot.items;
    if (saved.len != core.grid.main_buf.vertex_row_counts.len) return false;
    // Check every surface before mutating any: a half-applied restore would
    // leave some grids accounted against the committed frame and others not,
    // which is worse than the conservative full invalidation.
    var check = core.flush_subgrid_ledgers.iterator();
    while (check.next()) |e| {
        if (!e.value_ptr.live) continue;
        const buf = core.grid.sub_grids.getPtr(e.key_ptr.*) orelse return false;
        if (buf.vertex_row_counts.len != e.value_ptr.counts.items.len) return false;
    }

    @memcpy(core.grid.main_buf.vertex_row_counts, saved);
    core.grid.main_buf.surface_vertex_count = core.flush_main_vertex_count_snapshot;
    core.grid.main_buf.vertex_row_ledger_valid = true;

    var it = core.flush_subgrid_ledgers.iterator();
    while (it.next()) |e| {
        if (!e.value_ptr.live) continue;
        const buf = core.grid.sub_grids.getPtr(e.key_ptr.*).?;
        @memcpy(buf.vertex_row_counts, e.value_ptr.counts.items);
        buf.surface_vertex_count = e.value_ptr.surface_vertex_count;
        buf.vertex_row_ledger_valid = true;
    }
    core.grid.subgrid_surface_vertex_count = core.flush_subgrid_aggregate_snapshot;
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
    // A refusal leaves the glyph mirrors describing a frame that never reached
    // the screen, and atlas reclamation reads them.
    if (commit) core.display_mirror_stale = false;
    clearTouchedVertexBudgetSurfaces(core);
    if (!commit and restore_main_ledger and restoreVertexRowLedgers(core)) {
        core.display_mirror_stale = true;
        // Every surface keeps its exact accounting now, sub-grids included.
        // They used to be zeroed and re-marked whole here because the ledger
        // was only ever mirrored for the main grid — and under ext_multigrid
        // that is the container, not the content, so one routine backpressure
        // refusal reshaped every split and float.
        core.force_ext_cursor_recheck = true;
        core.flush_vertex_count_aggregate =
            core.grid.main_buf.surface_vertex_count + core.grid.subgrid_surface_vertex_count;
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
        core.grid.main_buf.surface_vertex_count = 0;
        core.grid.main_buf.vertex_row_ledger_valid = false;
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

/// Reset one grid's row ledger before it is written again. Only a sub-grid
/// adjusts subgrid_surface_vertex_count; grid 1 is not counted there.
fn prepareVertexRowLedgerForWrite(core: *Core, grid_id: i64, buf: *grid_mod.GridBuf) void {
    if (buf.vertex_row_ledger_valid) return;
    core.flush_vertex_count_aggregate -|= buf.surface_vertex_count;
    if (grid_id != 1) core.grid.subgrid_surface_vertex_count -|= buf.surface_vertex_count;
    @memset(buf.vertex_row_counts, 0);
    buf.surface_vertex_count = 0;
    buf.vertex_row_ledger_valid = true;
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

/// Publish `new_count` as grid `grid_id`'s vertex count for `row`, replacing
/// whatever that row previously contributed. Grid 1 and every sub-grid share
/// this path; only a sub-grid participates in subgrid_surface_vertex_count.
fn replaceGridSurfaceRowVertexCount(
    core: *Core,
    grid_id: i64,
    buf: *grid_mod.GridBuf,
    row: usize,
    new_count: usize,
) !void {
    try syncVertexBudgetAggregate(core, false);
    touchGridVertexBudget(core, grid_id, buf);
    prepareVertexRowLedgerForWrite(core, grid_id, buf);
    const old_surface_count = buf.surface_vertex_count;
    try replaceSurfaceRowVertexCount(
        core,
        &buf.surface_vertex_count,
        buf.vertex_row_counts,
        row,
        new_count,
    );
    if (grid_id == 1) return;
    core.grid.subgrid_surface_vertex_count -|= old_surface_count;
    core.grid.subgrid_surface_vertex_count = std.math.add(
        usize,
        core.grid.subgrid_surface_vertex_count,
        buf.surface_vertex_count,
    ) catch return vertexBudgetExceeded(core);
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

// Style flags for RenderCell (bit positions). Declared in highlight.zig,
// which is where getWithStyles packs them; re-exported here because every
// existing call site says flush.STYLE_*.
pub const STYLE_BOLD = highlight.STYLE_BOLD;
pub const STYLE_ITALIC = highlight.STYLE_ITALIC;
pub const STYLE_STRIKETHROUGH = highlight.STYLE_STRIKETHROUGH;
pub const STYLE_UNDERLINE = highlight.STYLE_UNDERLINE;
pub const STYLE_UNDERCURL = highlight.STYLE_UNDERCURL;
pub const STYLE_UNDERDOUBLE = highlight.STYLE_UNDERDOUBLE;
pub const STYLE_UNDERDOTTED = highlight.STYLE_UNDERDOTTED;
pub const STYLE_UNDERDASHED = highlight.STYLE_UNDERDASHED;

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

/// Fused run-end scan over up to 6 SoA attribute arrays in a single pass.
/// Returns the first index in [start, limit) where ANY of the enabled arrays
/// differs from its target. Equivalent to:
///     min(
///       simdFindRunEndU32(fg, ..., fg_t),
///       simdFindRunEndU32(bg, ..., bg_t),
///       simdFindRunEndI64(grid, ..., grid_t),
///       simdFindRunEndU32(deco, ..., deco_t),
///       has_style ? (first i where (style[i] & style_mask) != style_val)  : limit,
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

/// Resolve one hl id through the per-flush memo array, filling it on a miss.
///
/// Written once and called from every composition path. The array is indexed
/// directly by hl id, so ids at or past its length fall back to a live lookup
/// and are not memoized -- that fallback is the reason the bound is checked
/// here rather than by the caller.
///
/// `inline` because this sits inside per-cell and per-run loops on the flush
/// path; the comptime `count` branch folds away where the caller does not
/// keep hit/miss statistics.
inline fn resolveHlCached(
    core: *Core,
    hl_id: u32,
    hl_cache: []highlight.ResolvedAttrWithStyles,
    hl_valid: []bool,
    hl_cache_limit: u32,
    comptime count: bool,
    hits: *u32,
    misses: *u32,
) highlight.ResolvedAttrWithStyles {
    if (hl_id < hl_cache_limit) {
        if (hl_valid[hl_id]) {
            if (count) hits.* += 1;
            return hl_cache[hl_id];
        }
        if (count) misses.* += 1;
        const resolved = core.hl.getWithStyles(hl_id);
        hl_cache[hl_id] = resolved;
        hl_valid[hl_id] = true;
        return resolved;
    }
    // Beyond the memo array: resolve live, every time.
    if (count) misses.* += 1;
    return core.hl.getWithStyles(hl_id);
}

/// Whether one cell glows: everything glows in `glow_all` mode, otherwise
/// only the highlights in the resolved set do.
///
/// Three places make this decision: the main-grid run composition, the external
/// grid's own rows, and the floats composited onto it. Callers keep their own
/// snapshot of the two glow fields and their own `glow_enabled` guard; only the
/// decision is shared.
///
/// `inline` matters only in Debug. Measured with `nm` on a ReleaseFast
/// build: this, `resolveHlCached`, and the plain-`fn`
/// `viewportCellScrollable` in the same per-cell position all emit zero
/// symbols, so the optimizer inlines them alike. In Debug the plain `fn`
/// emits a symbol and these do not. Keep the keyword for the Debug-build
/// per-cell paths, not on a claim about shipped code.
inline fn cellGlow(glow_all: bool, glow_hl_ids: ?*std.AutoHashMap(u32, void), hl: u32) u8 {
    if (glow_all) return 1;
    const ids = glow_hl_ids orelse return 0;
    return @intFromBool(ids.contains(hl));
}

/// Compose one grid row into `dst`, run-length batched by hl_id.
/// `row_start` is the row's first cell index in `grid_cells`; `dst` is a
/// row-local buffer filled from 0.
///
/// `grid_cells` and `grid_id` are arguments because every surface composes the
/// same way. This was written against `core.grid.main_buf` alone, so under
/// ext_multigrid the run-batched SIMD path ran over the empty container while
/// every split, float and external window went cell by cell.
///
/// A row shorter than `cols` is tolerated the way the per-cell path did it:
/// the missing tail composes as blanks at hl 0.
///
/// `inline` on purpose: this is per-row on the flush path, and inlining lets
/// the slice bases and the comptime `count_hl_cache` branch fold away.
inline fn composeRowRuns(
    core: *Core,
    dst: *RenderCells,
    grid_cells: []const grid_mod.Cell,
    grid_id: i64,
    row_start: usize,
    cols: u32,
    hl_cache: []highlight.ResolvedAttrWithStyles,
    hl_valid: []bool,
    hl_cache_limit: u32,
    glow_enabled: bool,
    glow_all: bool,
    glow_hl_ids: ?*std.AutoHashMap(u32, void),
    comptime count_hl_cache: bool,
    hl_hits: *u32,
    hl_misses: *u32,
) void {
    // Cells this row actually has. Anything past it is blank at hl 0, which is
    // what the per-cell composer substituted.
    const present: u32 = if (row_start >= grid_cells.len)
        0
    else
        @intCast(@min(@as(usize, cols), grid_cells.len - row_start));

    var c: u32 = 0;
    while (c < cols) {
        const run_hl: u32 = if (c < present) grid_cells[row_start + @as(usize, c)].hl else 0;

        // Find run of consecutive cells with same hl_id.
        // This reduces hl_cache lookups from O(cols) to O(unique_hl_ids).
        var run_end: u32 = c + 1;
        while (run_end < cols) : (run_end += 1) {
            const next_hl: u32 = if (run_end < present) grid_cells[row_start + @as(usize, run_end)].hl else 0;
            if (next_hl != run_hl) break;
        }

        // Get resolved attributes once for the entire run
        const a = resolveHlCached(core, run_hl, hl_cache, hl_valid, hl_cache_limit, count_hl_cache, hl_hits, hl_misses);

        // Batch write all cells in the run with same fg/bg/sp/style_flags.
        // Only the scalar differs per cell.
        const ds: usize = @as(usize, c);
        const de: usize = @as(usize, run_end);
        @memset(dst.fg_rgbs.items[ds..de], a.fg);
        @memset(dst.bg_rgbs.items[ds..de], a.bg);
        @memset(dst.sp_rgbs.items[ds..de], a.sp);
        @memset(dst.grid_ids.items[ds..de], grid_id);
        @memset(dst.style_flags_arr.items[ds..de], a.style_flags);
        @memset(dst.overline_arr.items[ds..de], @intFromBool(a.overline));
        if (glow_enabled) {
            const has_glow: u8 = cellGlow(glow_all, glow_hl_ids, run_hl);
            @memset(dst.glow_arr.items[ds..de], has_glow);
            if (has_glow == 0 and !glow_all and run_hl != 0) core.noteGlowMiss(run_hl);
        }
        // SIMD stride-2 extraction: Cell{cp,hl} -> cp only, for the part of the
        // run the grid actually has; the rest is the blank the per-cell path
        // substituted.
        const run_present: u32 = if (c >= present) 0 else @min(run_end, present) - c;
        if (run_present != 0) {
            simdExtractCp(
                grid_cells.ptr + row_start + @as(usize, c),
                dst.scalars.items.ptr + ds,
                @as(usize, run_present),
            );
        }
        if (run_present != run_end - c) {
            @memset(dst.scalars.items[ds + @as(usize, run_present) .. de], ' ');
        }

        c = run_end;
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
    /// Zero the per-grid counters only. `hl_id` is a Neovim-global id and the
    /// resolved attribute does not depend on which grid asked, so the validity
    /// bits survive: they are reset once per flush, as the main pass resets
    /// them once for itself.
    pub fn resetCounters(self: *FlushCache) void {
        self.perf_hl_cache_hits = 0;
        self.perf_hl_cache_misses = 0;
        self.perf_glyph_ascii_hits = 0;
        self.perf_glyph_ascii_misses = 0;
        self.perf_glyph_nonascii_hits = 0;
        self.perf_glyph_nonascii_misses = 0;
    }

    pub fn reset(self: *FlushCache) void {
        @memset(self.hl_valid_buf, false);
        self.resetCounters();
    }
};

// ---------------------------------------------------------------
// Scroll-aware flush: fast path eligibility
// ---------------------------------------------------------------

// ---------------------------------------------------------------------------
// VertexHelpers: shared vertex generation utilities for both global grid and
// external grid pipelines.  Extracted to file level so the 5-pass row
// generation function can be shared.
// ---------------------------------------------------------------------------
pub const VH = struct {
    /// Quad corners in grid-local pixels: TL, TR, BL, BR. The frontend applies
    /// the layer transform, so the core never needs the surface extent here.
    inline fn quadPx(x0: f32, y0: f32, x1: f32, y1: f32) [4][2]f32 {
        return .{
            .{ x0, y0 },
            .{ x1, y0 },
            .{ x0, y1 },
            .{ x1, y1 },
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
        grid_id: i64,
        base_deco_flags: u32,
    ) !void {
        const pts = quadPx(x0, y0, x1, y1);
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
        grid_id: i64,
        base_deco_flags: u32,
    ) void {
        const pts = quadPx(x0, y0, x1, y1);
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
        grid_id: i64,
        base_deco_flags: u32,
    ) void {
        const pts = quadPx(x0, y0, x1, y1);
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
        grid_id: i64,
        deco_flags: u32,
        deco_phase: f32,
    ) !void {
        const pts = quadPx(x0, y0, x1, y1);
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
        grid_id: i64,
        deco_flags: u32,
        deco_phase: f32,
    ) void {
        const pts = quadPx(x0, y0, x1, y1);
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
/// Quad emission primitives in grid-local pixels, shared by the main-surface
/// flush and the external grid path. The frontend applies the layer
/// transform, so nothing here knows which surface it is building for.
const Helpers = struct {
    /// Quad corners in grid-local pixels: TL, TR, BL, BR. The
    /// frontend applies the layer transform.
    inline fn quadPx(x0: f32, y0: f32, x1: f32, y1: f32) [4][2]f32 {
        return .{
            .{ x0, y0 },
            .{ x1, y0 },
            .{ x0, y1 },
            .{ x1, y1 },
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
        grid_id: i64,
        base_deco_flags: u32,
    ) !void {
        const pts = quadPx(x0, y0, x1, y1);
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
        grid_id: i64,
        base_deco_flags: u32,
    ) void {
        const pts = quadPx(x0, y0, x1, y1);
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
        grid_id: i64,
        base_deco_flags: u32,
    ) !void {
        try out.ensureUnusedCapacity(alloc, 6);
        pushGlyphQuadAssumeCapacity(out, x0, y0, x1, y1, uv0, uv1, uv2, uv3, col, grid_id, base_deco_flags);
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
        grid_id: i64,
        base_deco_flags: u32,
    ) void {
        const pts = quadPx(x0, y0, x1, y1);
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
        grid_id: i64,
        deco_flags: u32,
        deco_phase: f32,
    ) !void {
        const pts = quadPx(x0, y0, x1, y1);
        const p0 = pts[0];
        const p1 = pts[1];
        const p2 = pts[2];
        const p3 = pts[3];

        // Decoration UV: x = -1 sentinel, y = local position within
        // the quad (0.0 top, 1.0 bottom) for the shader.
        const uv_top: [2]f32 = .{ -1.0, 0.0 }; // y0 vertices (top)
        const uv_bottom: [2]f32 = .{ -1.0, 1.0 }; // y1 vertices (bottom)

        try out.ensureUnusedCapacity(alloc, 6);
        const v = out.addManyAsSliceAssumeCapacity(6);

        v[0] = .{ .position = p0, .texCoord = uv_top, .color = col, .grid_id = grid_id, .deco_flags = deco_flags, .deco_phase = deco_phase };
        v[1] = .{ .position = p2, .texCoord = uv_bottom, .color = col, .grid_id = grid_id, .deco_flags = deco_flags, .deco_phase = deco_phase };
        v[2] = .{ .position = p1, .texCoord = uv_top, .color = col, .grid_id = grid_id, .deco_flags = deco_flags, .deco_phase = deco_phase };

        v[3] = .{ .position = p1, .texCoord = uv_top, .color = col, .grid_id = grid_id, .deco_flags = deco_flags, .deco_phase = deco_phase };
        v[4] = .{ .position = p2, .texCoord = uv_bottom, .color = col, .grid_id = grid_id, .deco_flags = deco_flags, .deco_phase = deco_phase };
        v[5] = .{ .position = p3, .texCoord = uv_bottom, .color = col, .grid_id = grid_id, .deco_flags = deco_flags, .deco_phase = deco_phase };
    }
};

pub const RowGenParams = struct {
    row: u32,
    cols: u32,
    cell_w: f32,
    cell_h: f32,
    top_pad: f32,
    default_bg: u32,
    blur_enabled: bool,
    background_opacity: f32,
    is_cmdline: bool,
    glow_enabled: bool,
    /// Skip runs whose background is the surface default. Set for the ROOT
    /// grid of a surface that draws other grids as layers: each layer paints
    /// that background itself, and a second premultiplied `over` compounds
    /// alpha under blur.
    skip_default_bg: bool = false,
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

    // clusters[0] is 0 (checked above) and previous starts at 0, so the
    // monotonicity test is already vacuous on the first glyph -- it needs no
    // index guard, and without one the loop needs no index.
    var previous: u32 = 0;
    for (clusters[0..glyph_count]) |cluster| {
        if (cluster >= scalar_count) return false;
        if (cluster < previous) return false;
        previous = cluster;
    }
    return true;
}

/// One grid's rows as a row pass reads them. The root grid and every other
/// grid composed, generated, charged and sent each row through two copies of
/// the same steps; the helpers below are the one copy. What differs between the
/// two passes stays with each caller: which rows are owed, the atlas-reset
/// policy (the root retries once, the rest cancel), and the per-step timing
/// the root reports.
const GridRowSource = struct {
    grid_id: i64,
    buf: *grid_mod.GridBuf,
    /// The rows the frontend is told the grid has.
    rows: u32,
    cols: u32,
    margins: grid_mod.ViewportMargins,
    is_cmdline: bool,
    /// See RowGenParams.skip_default_bg.
    skip_default_bg: bool,
};

const RowComposeTables = struct {
    hl_cache: []highlight.ResolvedAttrWithStyles,
    hl_valid: []bool,
    glow_enabled: bool,
    glow_all: bool,
    glow_hl_ids: ?*std.AutoHashMap(u32, void),
};

/// Compose `row` of `src` into core.row_cells, viewport margin flags included.
/// core.row_cells must already hold `src.cols` cells.
inline fn composeGridRow(
    core: *Core,
    src: GridRowSource,
    row: u32,
    tables: RowComposeTables,
    hl_hits: *u32,
    hl_misses: *u32,
) void {
    setViewportRowDecoFlags(core.row_cells.deco_base_flags.items[0..src.cols], row, src.rows, src.cols, src.margins);
    composeRowRuns(
        core,
        &core.row_cells,
        src.buf.cells,
        src.grid_id,
        @as(usize, row) * @as(usize, src.cols),
        src.cols,
        tables.hl_cache,
        tables.hl_valid,
        @intCast(tables.hl_valid.len),
        tables.glow_enabled,
        tables.glow_all,
        tables.glow_hl_ids,
        true,
        hl_hits,
        hl_misses,
    );
}

/// Generate the vertices of the row composeGridRow left in core.row_cells.
fn generateGridRow(
    core: *Core,
    src: GridRowSource,
    row: u32,
    glow_enabled: bool,
    out: *std.ArrayListUnmanaged(c_api.Vertex),
) !RowGenStats {
    return generateRowVertices(core, .{
        .row = row,
        .cols = src.cols,
        .cell_w = @floatFromInt(core.cell_w_px),
        .cell_h = @floatFromInt(core.cell_h_px),
        .top_pad = @floatFromInt(rowTopPadPx(core.linespace_px)),
        .default_bg = core.hl.default_bg,
        .blur_enabled = core.blur_enabled,
        .background_opacity = core.background_opacity,
        .is_cmdline = src.is_cmdline,
        .glow_enabled = glow_enabled,
        .skip_default_bg = src.skip_default_bg,
    }, out);
}

/// Charge a generated row to its surface's vertex ledger and mirror its glyph
/// UVs for atlas reclamation, before the frontend sees it.
fn chargeGridRow(core: *Core, src: GridRowSource, row: u32, verts: []const c_api.Vertex) !void {
    try replaceGridSurfaceRowVertexCount(core, src.grid_id, src.buf, row, verts.len);
    core.recordGlyphMirrorRow(src.grid_id, row, src.rows, verts);
}

/// Send a charged row as the grid's main content (ZONVIE_VERT_UPDATE_MAIN).
/// The pointer is never NULL, even for an empty row: NULL with row_count 0 is
/// the layout-only signal, and the Windows root path unwraps it.
fn sendGridRow(core: *Core, row_cb: anytype, src: GridRowSource, row: u32, verts: []const c_api.Vertex) void {
    traceRender(core, "event=row_send grid={d} row={d} vertices={d} rows={d} cols={d}\n", .{ src.grid_id, row, verts.len, src.rows, src.cols });
    row_cb(core.ctx, src.grid_id, row, 1, verts.ptr, verts.len, c_api.VERT_UPDATE_MAIN, src.rows, src.cols);
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

            const is_default_bg = run_bg == p.default_bg;
            if (is_default_bg and p.skip_default_bg) {
                c = end;
                continue;
            }
            const bg_alpha: f32 = if (is_default_bg)
                (if (p.blur_enabled) (if (p.is_cmdline) 0.0 else 0.5) else p.background_opacity)
            else
                1.0;
            try ensureRowQuadCapacity(core, out, p.max_vertices, 1);
            try VH.pushSolidQuad(out, core.alloc, x0, y0, x1, y1, VH.rgba(run_bg, bg_alpha), run_grid_id, run_deco);
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
                try VH.pushDecoQuad(out, core.alloc, x0, uy0, x1, uy1, deco_color, run_grid_id, c_api.DECO_UNDERLINE | deco_scroll_flag, 0);
            }

            if (run_flags & STYLE_UNDERDOUBLE != 0) {
                const uy0_1 = row_y + cellH - 6.0;
                const uy1_1 = uy0_1 + 1.0;
                const uy0_2 = row_y + cellH - 2.0;
                const uy1_2 = uy0_2 + 1.0;
                try ensureRowQuadCapacity(core, out, p.max_vertices, 2);
                try VH.pushDecoQuad(out, core.alloc, x0, uy0_1, x1, uy1_1, deco_color, run_grid_id, c_api.DECO_UNDERLINE | deco_scroll_flag, 0);
                try VH.pushDecoQuad(out, core.alloc, x0, uy0_2, x1, uy1_2, deco_color, run_grid_id, c_api.DECO_UNDERLINE | deco_scroll_flag, 0);
            }

            if (run_flags & STYLE_UNDERCURL != 0) {
                const uy0 = row_y + cellH - 4.0;
                const uy1 = row_y + cellH;
                const phase: f32 = @floatFromInt(run_start);
                try ensureRowQuadCapacity(core, out, p.max_vertices, 1);
                try VH.pushDecoQuad(out, core.alloc, x0, uy0, x1, uy1, deco_color, run_grid_id, c_api.DECO_UNDERCURL | deco_scroll_flag, phase);
            }

            if (run_flags & STYLE_UNDERDOTTED != 0) {
                const uy0 = row_y + cellH - 2.0;
                const uy1 = uy0 + 1.0;
                try ensureRowQuadCapacity(core, out, p.max_vertices, 1);
                try VH.pushDecoQuad(out, core.alloc, x0, uy0, x1, uy1, deco_color, run_grid_id, c_api.DECO_UNDERDOTTED | deco_scroll_flag, 0);
            }

            if (run_flags & STYLE_UNDERDASHED != 0) {
                const uy0 = row_y + cellH - 2.0;
                const uy1 = uy0 + 1.0;
                try ensureRowQuadCapacity(core, out, p.max_vertices, 1);
                try VH.pushDecoQuad(out, core.alloc, x0, uy0, x1, uy1, deco_color, run_grid_id, c_api.DECO_UNDERDASHED | deco_scroll_flag, 0);
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
            // Replaces 3–5 separate per-attribute run-end scans.
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
            const may_have_overflow = core.grid.overflowCountForGrid(run_grid_id) != 0;
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
                // The cell rows a row-scissored draw keeps; topPad is inside it.
                const row_top = @as(f32, @floatFromInt(r)) * cellH;
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
                        const possible_clusters = @min(run_len, core.grid.overflowCountForGrid(run_grid_id));
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
                                VH.pushGlyphQuadAssumeCapacity(out, gx0, gy0, gx1, gy1, uv0, uv1, uv2, uv3, fg, run_grid_id, deco);
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
                                            VH.pushSolidQuadAssumeCapacity(out, penX + rect.x0 * blk_w, blk_y0 + rect.y0 * cellH, penX + rect.x1 * blk_w, blk_y0 + rect.y1 * cellH, fg, run_grid_id, c_api.DECO_SOLID_GLYPH | glyph_scroll_flag);
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
                                        const fb_raw_gy0: f32 = fb_baselineY - (fb_ge.bbox_origin_px[1] + fb_ge.bbox_size_px[1]);
                                        const fb_span = vertexgen.trimBoxDrawingSpanY(
                                            fb_scalar,
                                            .{ .y0 = fb_raw_gy0, .y1 = fb_raw_gy0 + fb_ge.bbox_size_px[1], .v0 = fb_ge.uv_min[1], .v1 = fb_ge.uv_max[1] },
                                            row_top,
                                            row_top + cellH,
                                        );
                                        const fb_gy0: f32 = fb_span.y0;
                                        const fb_gy1: f32 = fb_span.y1;

                                        const fb_uv0: [2]f32 = .{ fb_ge.uv_min[0], fb_span.v0 };
                                        const fb_uv1: [2]f32 = .{ fb_ge.uv_max[0], fb_span.v0 };
                                        const fb_uv2: [2]f32 = .{ fb_ge.uv_min[0], fb_span.v1 };
                                        const fb_uv3: [2]f32 = .{ fb_ge.uv_max[0], fb_span.v1 };

                                        const fb_glyph_deco: u32 = glyph_scroll_flag | (if (run_has_glow) c_api.DECO_GLOW else 0) | (if (fb_ge.bytes_per_pixel >= 4) c_api.DECO_COLOR_EMOJI else 0);
                                        const fb_t_emit: i128 = if (log_glyph_timing) clock.nowNs() else 0;
                                        try ensureRowQuadCapacity(core, out, p.max_vertices, 1);
                                        VH.pushGlyphQuadAssumeCapacity(out, fb_gx0, fb_gy0, fb_gx1, fb_gy1, fb_uv0, fb_uv1, fb_uv2, fb_uv3, fg, run_grid_id, fb_glyph_deco);
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
                                        VH.pushSolidQuadAssumeCapacity(out, penX + rect.x0 * blk_w, blk_y0 + rect.y0 * cellH, penX + rect.x1 * blk_w, blk_y0 + rect.y1 * cellH, fg, run_grid_id, c_api.DECO_SOLID_GLYPH | glyph_scroll_flag);
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
                                        const mc_raw_gy0: f32 = mc_baselineY - (mc_ge.bbox_origin_px[1] + mc_ge.bbox_size_px[1]);
                                        const mc_span = vertexgen.trimBoxDrawingSpanY(
                                            mc_scalar,
                                            .{ .y0 = mc_raw_gy0, .y1 = mc_raw_gy0 + mc_ge.bbox_size_px[1], .v0 = mc_ge.uv_min[1], .v1 = mc_ge.uv_max[1] },
                                            row_top,
                                            row_top + cellH,
                                        );
                                        const mc_gy0: f32 = mc_span.y0;
                                        const mc_gy1: f32 = mc_span.y1;
                                        const mc_uv0: [2]f32 = .{ mc_ge.uv_min[0], mc_span.v0 };
                                        const mc_uv1: [2]f32 = .{ mc_ge.uv_max[0], mc_span.v0 };
                                        const mc_uv2: [2]f32 = .{ mc_ge.uv_min[0], mc_span.v1 };
                                        const mc_uv3: [2]f32 = .{ mc_ge.uv_max[0], mc_span.v1 };
                                        const mc_deco: u32 = glyph_scroll_flag | (if (run_has_glow) c_api.DECO_GLOW else 0) | (if (mc_ge.bytes_per_pixel >= 4) c_api.DECO_COLOR_EMOJI else 0);
                                        const mc_t_emit: i128 = if (log_glyph_timing) clock.nowNs() else 0;
                                        try ensureRowQuadCapacity(core, out, p.max_vertices, 1);
                                        VH.pushGlyphQuadAssumeCapacity(out, mc_gx0, mc_gy0, mc_gx1, mc_gy1, mc_uv0, mc_uv1, mc_uv2, mc_uv3, fg, run_grid_id, mc_deco);
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
                            const raw_gy0: f32 = (baselineY + y_off_px) - (ge.bbox_origin_px[1] + ge.bbox_size_px[1]);
                            const span = vertexgen.trimBoxDrawingSpanY(
                                if (next_cluster == this_cluster + 1) first_scalar else 0,
                                .{ .y0 = raw_gy0, .y1 = raw_gy0 + ge.bbox_size_px[1], .v0 = ge.uv_min[1], .v1 = ge.uv_max[1] },
                                row_top,
                                row_top + cellH,
                            );
                            const gy0: f32 = span.y0;
                            const gy1: f32 = span.y1;

                            const uv0: [2]f32 = .{ ge.uv_min[0], span.v0 };
                            const uv1: [2]f32 = .{ ge.uv_max[0], span.v0 };
                            const uv2: [2]f32 = .{ ge.uv_min[0], span.v1 };
                            const uv3: [2]f32 = .{ ge.uv_max[0], span.v1 };

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
                            VH.pushGlyphQuadAssumeCapacity(out, gx0, gy0, gx1, gy1, uv0, uv1, uv2, uv3, fg, run_grid_id, glyph_deco);
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
                                    VH.pushSolidQuadAssumeCapacity(out, penX + rect.x0 * blk_cell_w, blk_y0 + rect.y0 * cellH, penX + rect.x1 * blk_cell_w, blk_y0 + rect.y1 * cellH, VH.rgb(run_fg), run_grid_id, c_api.DECO_SOLID_GLYPH | glyph_scroll_flag);
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
                        const raw_gy0: f32 = (baselineY) - (ge.bbox_origin_px[1] + ge.bbox_size_px[1]);
                        const span = vertexgen.trimBoxDrawingSpanY(
                            scalar,
                            .{ .y0 = raw_gy0, .y1 = raw_gy0 + ge.bbox_size_px[1], .v0 = ge.uv_min[1], .v1 = ge.uv_max[1] },
                            row_top,
                            row_top + cellH,
                        );
                        const gy0: f32 = span.y0;
                        const gy1: f32 = span.y1;

                        const uv0: [2]f32 = .{ ge.uv_min[0], span.v0 };
                        const uv1: [2]f32 = .{ ge.uv_max[0], span.v0 };
                        const uv2: [2]f32 = .{ ge.uv_min[0], span.v1 };
                        const uv3: [2]f32 = .{ ge.uv_max[0], span.v1 };

                        if (ge.bbox_size_px[0] > 0 and ge.bbox_size_px[1] > 0) {
                            const pc_glyph_deco: u32 = glyph_scroll_flag | (if (run_has_glow) c_api.DECO_GLOW else 0) | (if (ge.bytes_per_pixel >= 4) c_api.DECO_COLOR_EMOJI else 0);
                            const pc_t_emit: i128 = if (log_glyph_timing) clock.nowNs() else 0;
                            try ensureRowQuadCapacity(core, out, p.max_vertices, 1);
                            VH.pushGlyphQuadAssumeCapacity(out, gx0, gy0, gx1, gy1, uv0, uv1, uv2, uv3, fg, run_grid_id, pc_glyph_deco);
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
            try VH.pushDecoQuad(out, core.alloc, x0, sy0, x1, sy1, deco_color, run_grid_id, c_api.DECO_STRIKETHROUGH | strike_scroll_flag, 0);

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
            try VH.pushDecoQuad(out, core.alloc, x0, oy0, x1, oy1, deco_color, run_grid_id, c_api.DECO_OVERLINE | ol_scroll_flag, 0);

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

/// Whether one grid's pending scroll can be published as a row shift rather
/// than a regeneration of the whole scrolled band. Every condition here is
/// internal to the grid: composition also required full surface width and no
/// overlapping grid, because one surface row buffer held several grids' cells.
/// Each grid owns its rows now, so a split, a float, the content under a
/// float, and a scrollbind group are all eligible.
fn gridScrollFastPathRegion(
    op: grid_mod.ScrollDelta,
    grid_rows: u32,
    grid_cols: u32,
    viewport_rows: u32,
    viewport_cols: u32,
) ?ExternalScrollFastPathRegion {
    // The callback ABI carries only a vertical delta.
    if (op.cols != 0 or op.rows == 0) return null;
    if (viewport_rows == 0 or viewport_cols == 0) return null;
    if (viewport_rows > grid_rows or viewport_cols > grid_cols) return null;
    if (op.top >= op.bot or op.bot > grid_rows) return null;
    if (op.left >= op.right or op.right > grid_cols) return null;

    const row_end = @min(op.bot, viewport_rows);
    if (row_end <= op.top or row_end - op.top <= 1) return null;
    const col_start = @min(op.left, viewport_cols);
    const col_end = @min(op.right, viewport_cols);
    // Full local width: outside columns would otherwise hold shifted content.
    if (col_start != 0 or col_end != viewport_cols) return null;

    // Beyond half the region, the vacated rows outnumber what the shift saves.
    const region_height = row_end - op.top;
    const abs_rows: u32 = if (op.rows == std.math.minInt(i32))
        region_height
    else
        @intCast(@abs(op.rows));
    if (abs_rows == 0 or abs_rows > region_height / 2) return null;

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
) bool {
    if (grid_id < 2) return false;
    const surface_id = placedSurfaceForGrid(&core.grid, grid_id) orelse return false;
    // An external grid has no frontend surface to remap into until its open
    // callback has seeded one; a layer of the main surface always has one.
    if (core.grid.external_grids.contains(grid_id) and
        !core.known_external_grids.contains(grid_id)) return false;
    // Nor has a layer drawn ON such a grid. notifyExternalWindowChanges
    // withholds the open for a pending grid still under 2 rows or columns, and
    // publishSurfaceLayouts withholds its layout to match; a shift sent for
    // something placed on that surface reaches a frontend with no storage for
    // it, and both answer by failing the whole flush until the resize lands.
    if (surface_id != 1 and !core.known_external_grids.contains(surface_id)) return false;
    const sg = core.grid.sub_grids.getPtr(grid_id) orelse return false;
    if (sg.scroll_fast_path_blocked) return false;

    const op = sg.last_scroll_op orelse return false;
    const region = gridScrollFastPathRegion(op, sg.rows, sg.cols, sg.rows, sg.cols) orelse return false;
    // The frontend keeps the surviving rows and is sent only the vacated ones,
    // so the mirror has to move with them.
    core.shiftGlyphMirror(grid_id, region.row_start, region.row_end, op.rows);
    traceRender(core, "event=row_shift_send grid={d} start={d} end={d} delta={d}\n", .{ grid_id, region.row_start, region.row_end, op.rows });
    scroll_cb(core.ctx, grid_id, region.row_start, region.row_end, region.col_start, region.col_end, op.rows, sg.rows, sg.cols);
    sg.row_shift_sent = true;
    return true;
}

pub const FlushCtx = struct {
    core: *Core,

    pub fn onFlush(ctx: *FlushCtx, rows: u32, cols: u32) !void {
        const n_cells: usize = @as(usize, rows) * @as(usize, cols);
        ctx.core.flush_retryable = true;
        try beginVertexBudgetTransaction(ctx.core);
        // Before the dirty snapshot, so an aborted attempt still owes them.
        regenerateRootsWhoseDefaultBgRuleFlipped(ctx.core);
        const last_sent_content_rev_before = ctx.core.last_sent_content_rev;
        const last_sent_cursor_rev_before = ctx.core.last_sent_cursor_rev;
        // Remember what this attempt is about to consume. A frontend that
        // later refuses to publish owes exactly this much on the retry, not a
        // full-viewport resend (see the abort branch below).
        var dirty_snapshot_valid = true;
        ctx.core.grid.snapshotDirty(ctx.core.alloc, &ctx.core.flush_dirty_snapshot) catch {
            dirty_snapshot_valid = false;
        };
        if (!snapshotVertexRowLedgers(ctx.core)) dirty_snapshot_valid = false;

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
            var dr_iter = ctx.core.grid.main_buf.dirty_rows.iterator(.{});
            while (dr_iter.next()) |_| dirty_count += 1;
            ctx.core.log.write(
                "[perf] flush_dirty rows={d} dirty_rows={d} dirty_all={d} content_rev={d}\n",
                .{ rows, dirty_count, @intFromBool(ctx.core.grid.main_buf.dirty_all), ctx.core.grid.content_rev },
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
                scrolled_count, scrolled_overflow, ctx.core.grid.content_rev, ctx.core.grid.main_buf.dirty_all,
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
        traceRender(ctx.core, "event=begin aborted={}\n", .{aborted_at_flush_begin});
        // Reclaim atlas space while the glyph mirrors still describe the frame
        // the frontend is showing, and before this flush packs anything of its own.
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
            // A reset still pending here was never consumed by a check: an
            // abort returned first (the cursor glyph lookup's `.aborted`).
            // Rows committed earlier point into the replaced atlas, so this is
            // corruption, not a refusal that may keep the committed frame.
            if (ctx.core.atlas_reset_during_flush) {
                ctx.core.invalidateMirroredFrameState();
                ctx.core.flush_atlas_corrupted = true;
            }
            const vertex_budget_committed = !ctx.core.flush_aborted and !ctx.core.flush_atlas_corrupted;
            traceRender(ctx.core, "event=end outcome={s} retryable={} destroyed_pending={d} metadata_bytes={d} metadata_limit_bytes={d}\n", .{ if (vertex_budget_committed) "commit" else "abort", ctx.core.flush_retryable, ctx.core.grid.destroyed_pending.items.len, ctx.core.layout_budget.live_bytes.load(.monotonic), c_api.render_layout.Budget.limit_bytes });
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
            // A begin rejection keeps the budget (nothing was consumed) but
            // publishes nothing, so the mirrors are as stale as they were.
            const mirror_stale_before = ctx.core.display_mirror_stale;
            finishVertexBudgetTransactionRestoring(
                ctx.core,
                vertex_budget_committed or aborted_at_flush_begin,
                frontend_refused_publication,
            );
            if (aborted_at_flush_begin) ctx.core.display_mirror_stale = mirror_stale_before;
            if (vertex_budget_committed) {
                for (ctx.core.grid.destroyed_pending.items) |grid_id| {
                    traceRender(ctx.core, "event=destroy_release grid={d}\n", .{grid_id});
                    ctx.core.removeGlyphMirror(grid_id);
                }
                ctx.core.grid.destroyed_pending.clearRetainingCapacity();
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
                    // The snapshot covers the sub-grids too, so each of them
                    // owes exactly the rows this attempt consumed. Only a
                    // failed snapshot falls back to the full resend.
                    if (dirty_snapshot_valid) {
                        ctx.core.grid.restoreDirty(&ctx.core.flush_dirty_snapshot);
                    } else {
                        ctx.core.grid.markEverySurfaceDirty();
                    }
                    ctx.core.last_sent_content_rev = last_sent_content_rev_before;
                    ctx.core.last_sent_cursor_rev = last_sent_cursor_rev_before;
                    ctx.core.force_ext_cursor_recheck = true;
                    // notifySurfaceLayouts runs before on_flush_end, so a late
                    // abort cancels the transaction that carried the layout
                    // while its signature is already recorded. Drop the
                    // signatures so the retry republishes them.
                    var layout_it = ctx.core.last_surface_layout.valueIterator();
                    while (layout_it.next()) |layout| layout.valid = false;
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
                    while (sg_it.next()) |sg| {
                        // The restored dirty set names only the rows the
                        // scroll vacated, and the frontend dropped the shift
                        // with the bracket. Without the op the retry can send
                        // neither, so it sends every row.
                        if (sg.last_scroll_op != null) sg.markAllDirty();
                        sg.clearScrollState();
                    }
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
                // Surface lifecycle and placement first: a frontend routes a
                // grid's rows by which surface places it, and a timer/retry
                // flush has no redraw-batch phase to do it in. An allocation
                // failure here also cancels and retries the same transaction.
                _ = notifyExternalWindowChanges(ctx.core);
                notifySurfaceLayouts(ctx.core);

                const t_ext: i128 = if (perf_enabled) clock.nowNs() else 0;
                if (!ctx.core.flush_aborted and !ctx.core.flush_atlas_corrupted) {
                    sendExternalGridVertices(ctx.core, false);
                }
                if (perf_enabled) {
                    const ext_us: i64 = @intCast(@divTrunc(@max(0, clock.nowNs() - t_ext), 1000));
                    ctx.core.log.write("[perf] send_external_grids us={d} known={d}\n", .{ ext_us, ctx.core.known_external_grids.count() });
                }
                // An abort raised here is restored by the outer defer's dirty
                // snapshot; a markAllDirty() would outlive that restore.
            }
            // Runs before on_flush_end: validate the completed main+external
            // state only after every row was generated, so moving vertices
            // between rows cannot fail on a mixed old/new intermediate ledger.
            if (!ctx.core.flush_aborted and !ctx.core.flush_atlas_corrupted) {
                validateCompletedVertexBudget(ctx.core) catch |err| {
                    ctx.core.flush_aborted = true;
                    ctx.core.failHardRender(err);
                };
            }
        }

        // A composition step below (vertex buffer growth, glyph push, etc.)
        // can fail with an internal Zig error (OOM) rather than an explicit
        // frontend-signaled zonvie_core_abort_flush() call. Such an error
        // propagates straight out of onFlush and is swallowed by callers
        // (`catch {}` / logged and dropped) while the two defers above still
        // run — frontends would commit a partial write-set as a complete
        // frame. Registered AFTER those defers so it runs FIRST during unwind
        // (LIFO), setting flush_aborted before they see it.
        errdefer ctx.core.flush_aborted = true;

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

        // Row shifts are grid-local. Resolve their destination before any
        // callback can route a moved grid using the previous surface's layout.
        //
        // The SECOND publish of this flush: `notifySurfaceLayouts` already ran
        // one, for its own ordering (a surface must exist on the frontend
        // before its layout arrives). Neither is redundant — they answer
        // different "before what" questions — and a frontend stages layers and
        // promotes them at commit, so publishing twice is idempotent. Removing
        // either one breaks the ordering the other does not cover.
        _ = notifyExternalWindowChanges(ctx.core);
        publishSurfaceLayouts(ctx.core);
        if (ctx.core.flush_aborted) return;

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
        // There is no float-anchor exclusion: eligibility is decided entirely by
        // the grid's own scroll state and gridScrollFastPathRegion.
        // last_scroll_op is committed by the transaction-final defer, not here.
        if (ctx.core.cb.on_grid_row_scroll) |scroll_cb| {
            var sg_it = ctx.core.grid.sub_grids.iterator();
            while (sg_it.next()) |entry| {
                if (entry.value_ptr.row_scroll_notify_pending) {
                    _ = dispatchGridRowScroll(ctx.core, scroll_cb, entry.key_ptr.*);
                    entry.value_ptr.row_scroll_notify_pending = false;
                    if (ctx.core.flush_aborted) break;
                }
            }
        }
        if (ctx.core.flush_aborted) return;

        ctx.core.checkMsgShowThrottleTimeout();

        // Before vertex generation, so the cursor position is restored first.
        notifyCmdlineChanges(ctx.core);

        // Inside the flush bracket so ext-popupmenu vertices come from the
        // current selection in the same flush; run after redraw.handleRedraw
        // returns, the popupmenu grid lags one flush behind cmdline_show.
        notifyPopupmenuChanges(ctx.core);

        // Inside the flush bracket so the msg_show (ext_float) grid is
        // registered in external_grids and gets vertices from
        // sendExternalGridVertices (the LIFO-deferred call below) in the same
        // flush; run only after handleRedraw returns (rpc_session.zig), the new
        // msg grid shows a blank window until the next user event.
        notifyMessageChanges(ctx.core);
        if (ctx.core.flush_aborted) return;

        // A zero-cell main grid has no rows, but its layout still has to cross
        // the transaction boundary: publish a layout-only MAIN update through
        // the row ABI plus the independent empty cursor layer, consuming
        // dirty/revision state only after both callbacks accept the bracket.
        if (n_cells == 0) {
            const need_main =
                ctx.core.grid.content_rev != ctx.core.last_sent_content_rev or
                ctx.core.grid.main_buf.dirty_all or
                ctx.core.grid.main_buf.surface_vertex_count != 0;
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
                    ctx.core.invalidateMirroredFrameState();
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

        // Cursor row/col are relative to cursor_grid; win_pos converts them to
        // grid 1 coordinates.
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

                cursor_out.blink_wait_ms = ctx.core.grid.cursor_blink_wait_ms;
                cursor_out.blink_on_ms = ctx.core.grid.cursor_blink_on_ms;
                cursor_out.blink_off_ms = ctx.core.grid.cursor_blink_off_ms;

                if (ctx.core.grid.cursor_attr_id != 0) {
                    const attr = ctx.core.hl.get(ctx.core.grid.cursor_attr_id);
                    cursor_out.fgRGB = attr.fg;
                    cursor_out.bgRGB = attr.bg;
                } else {
                    // attr_id == 0: swap default colors (per Nvim spec)
                    cursor_out.fgRGB = ctx.core.hl.default_bg;
                    cursor_out.bgRGB = ctx.core.hl.default_fg;
                }

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

        if (ctx.core.cb.on_vertices_row != null) {

            // dirty_all must force a rebuild even when content_rev is already
            // synced: the atlas-reset/glyph-miss recovery paths call
            // markAllDirty() AFTER last_sent_content_rev was synced for this
            // flush. Without this OR, the early return below would clearDirty()
            // the pending recovery and the screen would stay stale.
            const need_main: bool = (ctx.core.grid.content_rev != ctx.core.last_sent_content_rev) or ctx.core.grid.main_buf.dirty_all;
            const need_cursor: bool = (ctx.core.grid.cursor_rev != ctx.core.last_sent_cursor_rev);
            var cursor_retry_required = false;

            // If nothing changed, avoid doing any work.
            if (!need_main and !need_cursor) {
                ctx.core.grid.clearDirty();
                return;
            }

            var cursor = &ctx.core.cursor_verts;

            const cellW: f32 = @floatFromInt(ctx.core.cell_w_px);
            const cellH: f32 = @floatFromInt(ctx.core.cell_h_px);

            const topPad: f32 = @floatFromInt(rowTopPadPx(ctx.core.linespace_px));


            var sent_main_by_rows: bool = false;
            var main_retry_required: bool = false;

            if (need_main) {
                {
                    const row_cb = ctx.core.cb.on_vertices_row.?;
                    sent_main_by_rows = true;

                    const rebuild_all = ctx.core.grid.main_buf.dirty_all;
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
                                if (ctx.core.grid.main_buf.dirty_rows.isSet(@as(usize, rr))) {
                                    log_dirty_rows += 1;
                                }
                            }
                        }
                        t_rows_start_ns = clock.nowNs();
                        // Close pre_row "blackhole" bracket (started after cb_flush_begin).
                        const pre_row_us: i64 = @intCast(@divTrunc(@max(0, t_rows_start_ns - t_pre_row_start), 1000));
                        ctx.core.log.write("[perf] pre_row us={d} dirty_rows={d}\n", .{ pre_row_us, log_dirty_rows });
                    }

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

                    // Direct-index O(1) lookup into NvimCore-owned buffers
                    // (sized by the hl_cache_size config).
                    const hl_cache: []highlight.ResolvedAttrWithStyles = ctx.core.hl_cache_buf orelse &.{};
                    const hl_valid: []bool = ctx.core.hl_valid_buf orelse &.{};
                    @memset(hl_valid, false);
                    // The glyph cache is persistent across flushes and reset only
                    // on font change (onGuifont). Do NOT call
                    // resetGlyphCacheFlags() here: with the core-managed atlas
                    // that re-rasterizes every glyph every frame and triggers
                    // constant atlas resets.

                    // Get viewport margins for scrollable row detection
                    const main_margins = ctx.core.grid.getViewportMargins(1);
                    const main_src = GridRowSource{
                        .grid_id = 1,
                        .buf = ctx.core.grid.bufFor(1).?,
                        .rows = rows,
                        .cols = cols,
                        .margins = main_margins,
                        .is_cmdline = false,
                        // The root grid is a container once its windows draw as
                        // layers: every layer paints the same default
                        // background, and a second premultiplied `over`
                        // compounds alpha (0.5 -> 0.75 -> 0.875), which stopped
                        // the Windows main window being translucent enough for
                        // blur to show. BLUR ONLY: without blur the frontends
                        // force backgrounds opaque and apply window opacity at
                        // the layer level, so nothing compounds and dropping the
                        // run only thins the surface and leaves the gaps between
                        // layers unpainted. Settled once this flush, before any
                        // row, by regenerateRootsWhoseDefaultBgRuleFlipped.
                        .skip_default_bg = ctx.core.grid.main_buf.skip_default_bg_last,
                    };
                    const main_tables = RowComposeTables{
                        .hl_cache = hl_cache,
                        .hl_valid = hl_valid,
                        .glow_enabled = glow_enabled,
                        .glow_all = glow_all,
                        .glow_hl_ids = glow_hl_ids,
                    };

                    var saw_atlas_reset: bool = false;
                    var atlas_retried: bool = false;

                    retry_loop: while (true) {
                        // On retry: force all rows (stale UVs in non-dirty rows too)
                        const effective_rebuild_all = rebuild_all or atlas_retried;
                        if (atlas_retried) {
                            // Reset all per-pass mutable state for a clean retry.
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

                        // Grid 1 owns only its own rows, and under ext_multigrid
                        // Neovim scrolls the window grids, not grid 1: each
                        // publishes its own shift through on_grid_row_scroll, so
                        // the main surface has no scroll fast path of its own and
                        // every row it owes is a dirty row.
                        var r: u32 = 0;
                        while (r < rows) : (r += 1) {
                            if (!effective_rebuild_all and
                                !ctx.core.grid.main_buf.isRowDirty(r)) continue;

                            // A prior row_cb in this loop may have called
                            // zonvie_core_abort_flush (e.g. Windows row-buffer
                            // OOM); the frontend cancels its whole bracket on
                            // abort, so further rows would be discarded work.
                            if (ctx.core.flush_aborted) break;

                            var out = &ctx.core.row_verts;
                            out.clearRetainingCapacity();
                            var row_compose_us: i64 = 0;

                            var t_row_compose_start: i128 = 0;
                            if (log_enabled) {
                                t_row_compose_start = clock.nowNs();
                            }

                            composeGridRow(ctx.core, main_src, r, main_tables, &perf_hl_cache_hits, &perf_hl_cache_misses);

                            var t_row_compose_end: i128 = 0;
                            var t_row_gen_start: i128 = 0;
                            if (log_enabled) {
                                t_row_compose_end = clock.nowNs();
                                t_row_gen_start = t_row_compose_end;
                            }

                            // On error (e.g. buffer allocation failure), skip this
                            // row so partial vertices are not cached or sent.
                            // markAllDirty alone would only make the CONTENT
                            // eligible next flush; it would not stop this flush's
                            // write-set, with this row missing, from committing as
                            // a successful frame. flush_aborted is what makes both
                            // frontends cancel the bracket instead.
                            const row_gen_stats = generateGridRow(ctx.core, main_src, r, glow_enabled, out) catch |err| {
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
                                // Pass 3 (glyph) tracks its own max row: it dominates.
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

                            // Non-space cells with zero vertices suggests atlas/cache corruption.
                            if (log_enabled and scrolled_count > 0 and out.items.len == 0) {
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

                            // An atlas reset during this row leaves the rows already sent with stale UVs.
                            if (ctx.core.atlas_reset_during_flush) {
                                saw_atlas_reset = true;
                                ctx.core.atlas_reset_during_flush = false; // Clear before retry

                                if (!atlas_retried) {
                                    atlas_retried = true;
                                    if (log_enabled) {
                                        ctx.core.log.write(
                                            "[scroll_debug] atlas_reset_during_flush at row={d}: restarting row loop\n",
                                            .{r},
                                        );
                                    }
                                    continue :retry_loop;
                                }
                                // A second reset invalidates rows already sent by
                                // the retry; publishing empty replacements would
                                // commit a full-screen blank frame. Cancel this
                                // bracket and regenerate every layer next flush.
                                if (log_enabled) {
                                    ctx.core.log.write(
                                        "[scroll_debug] atlas_reset_during_flush at row={d} on retry: cancelling flush\n",
                                        .{r},
                                    );
                                }
                                ctx.core.flush_atlas_corrupted = true;
                                ctx.core.grid.markEverySurfaceDirty();
                                ctx.core.invalidateMirroredFrameState();
                                ctx.core.grid.cursor_rev +%= 1;
                                return;
                            }

                            var t_row_post_misc_before_cache_store: i128 = 0;
                            var t_row_cache_store_end: i128 = 0;
                            if (log_enabled) {
                                t_row_post_misc_before_cache_store = clock.nowNs();
                            }

                            // Charge the exact generated row before invoking the
                            // frontend: overflow clusters then count all emitted
                            // glyphs, and blank cells are charged nothing.
                            try chargeGridRow(ctx.core, main_src, r, out.items);

                            var t_row_before_cb: i128 = 0;
                            if (log_enabled) {
                                t_row_cache_store_end = clock.nowNs();
                                t_row_before_cb = t_row_cache_store_end;
                            }

                            sendGridRow(ctx.core, row_cb, main_src, r, out.items);

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

                    // A row_cb in the loop above may have aborted this flush
                    // (e.g. Windows row-buffer OOM), and the frontend cancels
                    // its whole triple-buffer bracket — nothing composed above
                    // reached the screen. clearDirty() here plus the
                    // last_sent_content_rev sync below would leave
                    // zonvie_core_retry_flush's has_pending check seeing nothing
                    // pending, losing this content until an unrelated later edit
                    // happens to touch the same rows.
                    if (!ctx.core.flush_aborted) ctx.core.grid.clearDirty();
                    if (had_glyph_miss or saw_atlas_reset) {
                        main_retry_required = true;
                        // Not after a retry that survived the reset: it rebuilt
                        // every root row against the new atlas, and marking them
                        // again only regenerated them all a second time.
                        if (had_glyph_miss) ctx.core.grid.markAllDirty();
                        // A reset always retried (a second one cancels the
                        // flush above), and the retry regenerated every row
                        // with the fresh atlas, so its mirrored UVs are valid;
                        // invalidating them would force a full regeneration on
                        // the next scroll flush (~65-80ms for CJK).
                        if (saw_atlas_reset) {
                            var sg_it = ctx.core.grid.sub_grids.valueIterator();
                            while (sg_it.next()) |sg| {
                                sg.markAllDirty();
                            }
                            // The cursor is a separate vertex consumer gated on
                            // cursor_rev alone, and dirtying content above never
                            // touches that counter.
                            ctx.core.grid.cursor_rev +%= 1;
                        }
                        if (log_enabled) {
                            ctx.core.log.write("[scroll_debug] markAllDirty: glyph_miss={any} saw_atlas_reset={any} scrolled={d}\n", .{
                                had_glyph_miss, saw_atlas_reset, scrolled_count,
                            });
                        }
                    }
                    // Clear unconditionally so sendExternalGridVertices sees clean state.
                    ctx.core.atlas_reset_during_flush = false;
                    // Skip on abort — see the clearDirty() guard above.
                    if (!ctx.core.flush_aborted) ctx.core.last_sent_content_rev = ctx.core.grid.content_rev;
                    if (log_enabled) {
                        const t_rows_done_ns: i128 = clock.nowNs();
                        const dur_us: i64 = @intCast(@divTrunc(@max(0, t_rows_done_ns - t_rows_start_ns), 1000));
                        ctx.core.log.write(
                            "[perf] row_mode_compose rows={d} cols={d} dirty_rows={d} subgrids={d} us={d}\n",
                            .{ rows, cols, log_dirty_rows, ctx.core.grid_entries.items.len, dur_us },
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
                        // glyph_sum_ns includes shape callback time; subtract the
                        // row_mode shape sum to isolate glyph-emit cost.
                        // ensure_sum_ns and quad_emit_sum_ns sub-divide it, and
                        // the residual (glyph - shape*1000 - ensure - quad) is
                        // roughly cache lookup. Those two cost two clock reads per
                        // quad, so they are verbose-tier only and report -1 otherwise.
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
                            "[perf] row_mode_prep hl_init_us={d} glyph_init_us={d} fast_path_check_us={d} regen_build_us={d} shift_us={d}\n",
                            .{
                                perf_row_prep_hl_init_us,
                                perf_row_prep_glyph_init_us,
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
                }
            }

            if (need_cursor) {
                cursor.clearRetainingCapacity();

                const cursor_grid = ctx.core.grid.cursor_grid;
                // Every grid is its own layer, so the cursor is emitted on the
                // grid it is actually on.
                const cursor_embedded_in_main = (cursor_grid == 1);

                if (cursor_embedded_in_main) {
                    try cursor.ensureTotalCapacity(ctx.core.alloc, 64);
                }

                if (cursor_embedded_in_main and cursor_out.enabled != 0) {
                    const cur_row = cursor_out.row;
                    const cur_col = cursor_out.col;
                    if (cur_row < rows and cur_col < cols) {
                        const x0 = @as(f32, @floatFromInt(cur_col)) * cellW;
                        const y0 = @as(f32, @floatFromInt(cur_row)) * cellH;

                        const cursor_grid_id = ctx.core.grid.cursor_grid;
                        const grid_cursor_row = ctx.core.grid.cursor_row;
                        const grid_cursor_col = ctx.core.grid.cursor_col;
                        const cursor_cell = ctx.core.grid.getCellGrid(cursor_grid_id, grid_cursor_row, grid_cursor_col);

                        // A next cell with cp == 0 is a wide char's continuation cell.
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

                        switch (try emitCursorQuads(ctx.core, cursor, .{
                            .grid_id = cursor_grid_id,
                            .row = grid_cursor_row,
                            .col = grid_cursor_col,
                            .x0 = x0,
                            .y0 = y0,
                            .cell_w = cellW,
                            .cell_h = cellH,
                            .top_pad = topPad,
                            .width = cursor_width,
                            .shape = @intCast(@intFromEnum(cursor_out.shape)),
                            .pct = cursor_out.cell_percentage,
                            .bg_rgb = cursor_out.bgRGB,
                            .fg_rgb = cursor_out.fgRGB,
                            .cell = cursor_cell,
                        })) {
                            .ok => {},
                            // Do not consume cursor_rev on a transient
                            // rasterizer miss: the next flush retries the
                            // same cursor without cancelling this transaction.
                            .retry => cursor_retry_required = true,
                            .aborted => return,
                        }
                    }
                }
            }

            // Vertices emitted before an atlas reset carry stale UVs and would
            // sample unrelated contents for one frame. Preserve dirty state so
            // the next flush regenerates against the fresh atlas.
            if (ctx.core.atlas_reset_during_flush) {
                ctx.core.grid.markEverySurfaceDirty();
                ctx.core.invalidateMirroredFrameState();
                ctx.core.atlas_reset_during_flush = false;
                // Dirtying repairs the next flush only; cancel this transaction
                // so the rows already published against the replaced atlas
                // generation are never committed. Set here, not left to the
                // outer defer: on_flush_end reads it and runs before that.
                ctx.core.flush_atlas_corrupted = true;
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
            if (!main_retry_required) ctx.core.grid.clearDirty();
            return;
        }
    }

    pub fn onGuifont(ctx: *FlushCtx, font: []const u8) !void {
        // "*" is a picker request (`:set guifont=*`), not a real font change:
        // the frontend only opens a dialog and later writes back a concrete
        // "Name:hN" that arrives as a normal guifont option_set. Resetting here
        // would flash a pointless re-render just to show the dialog.
        if (std.mem.eql(u8, font, "*")) {
            ctx.core.emitGuiFont(font);
            return;
        }

        // Invalidate caches BEFORE emitting the callback: a frontend may answer
        // it with a layout update that generates vertices, which must use
        // fresh cache lookups.
        ctx.core.resetAtlasMaintenanceBackoff();
        ctx.core.resetGlyphCacheFlags();
        ctx.core.resetShapeCache();
        if (ctx.core.isPhase2Atlas()) {
            ctx.core.resetCoreAtlas();
        }
        // The mirrored frame holds atlas UVs; invalidate on font/atlas change.
        ctx.core.invalidateMirroredFrameState();

        // Mark ALL grids dirty so every row re-renders with the new font/atlas;
        // otherwise old vertices keep referencing the now-empty atlas until
        // Neovim resends content. sg.dirty alone is not enough for sub_grids:
        // the per-row emit path picks rows from dirty_rows, so with no bits set
        // every row is skipped — markAllDirty() sets both. The cursor is a
        // separate consumer gated on cursor_rev, which no grid dirtying touches.
        ctx.core.grid.markEverySurfaceDirty();
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
        ctx.core.invalidateMirroredFrameState();
        ctx.core.grid.markEverySurfaceDirty();
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

/// What was last published for one surface, so a layout is re-sent only when it
/// actually changed. Holding the layers themselves makes the comparison exact
/// rather than a hash that could suppress a needed update.
pub const SurfaceLayoutSig = struct {
    layers: c_api.render_layout.List(c_api.Layer) = .{},
    valid: bool = false,
    surface_rows: u32 = 0,
    surface_cols: u32 = 0,

    fn matches(self: *const SurfaceLayoutSig, layers: []const c_api.Layer, rows: u32, cols: u32) bool {
        if (!self.valid or self.layers.len != layers.len) return false;
        if (self.surface_rows != rows or self.surface_cols != cols) return false;
        // Layer has no equality operator; every field is compared.
        for (self.layers.slice(), layers) |a, b| {
            if (a.grid_id != b.grid_id or
                a.anchor_grid != b.anchor_grid or
                a.x_px != b.x_px or
                a.y_px != b.y_px or
                a.rows != b.rows or
                a.cols != b.cols or
                a.z != b.z or
                a.flags != b.flags) return false;
        }
        return true;
    }
};

pub fn releaseSurfaceLayouts(self: *Core) void {
    var it = self.last_surface_layout.valueIterator();
    while (it.next()) |layout| layout.layers.deinit();
}

/// Frontends stamp these core-thread records with their callback flush ID.
fn traceRender(self: *Core, comptime fmt: []const u8, args: anytype) void {
    if (!self.log.verbose or self.log.cb == null or self.log.perf_only or self.log.scroll_only) return;
    self.log.write("[render_trace] side=core budget_transaction={} " ++ fmt, .{self.vertex_budget_transaction_active} ++ args);
}

fn failSurfaceLayout(self: *Core, err: anyerror) void {
    traceRender(self, "event=layout_failed reason={s} metadata_bytes={d}\n", .{ @errorName(err), self.layout_budget.live_bytes.load(.monotonic) });
    self.flush_aborted = true;
    if (Core.isHardRenderFailure(err)) {
        self.flush_retryable = false;
        self.failHardRender(err);
    }
}

/// Resolve through anchors without guessing a main-window placement for an
/// unresolved or cyclic chain. No allocation on redraw/flush paths.
pub fn surfaceForGrid(grid: *const grid_mod.Grid, grid_id: i64) ?i64 {
    return grid.surfaceForGrid(grid_id);
}

/// Resolving an anchor id does not imply that its surface has a root layout.
pub fn placedSurfaceForGrid(grid: *const grid_mod.Grid, grid_id: i64) ?i64 {
    const surface = surfaceForGrid(grid, grid_id) orelse return null;
    _ = grid.bufForConst(surface) orelse return null;
    return surface;
}

fn collectSurfaceLayerEntries(self: *Core, surface_id: i64) []const GridEntry {
    self.grid_entries.clearRetainingCapacity();
    var it = self.grid.win_pos.iterator();
    while (it.next()) |e| {
        const grid_id = e.key_ptr.*;
        if (grid_id == 1) continue;
        // An external grid is its own surface, never a layer of another.
        if (self.grid.external_grids.contains(grid_id)) continue;
        if (placedSurfaceForGrid(&self.grid, grid_id) != surface_id) continue;
        const sg = self.grid.sub_grids.get(grid_id) orelse continue;
        if (sg.rows == 0 or sg.cols == 0) continue;

        const layer = self.grid.win_layer.get(grid_id) orelse grid_mod.WinLayer{
            .zindex = 0,
            .compindex = 0,
            .order = 0,
        };
        self.grid_entries.append(self.alloc, &self.layout_budget, .{
            .grid_id = grid_id,
            .zindex = layer.zindex,
            .compindex = layer.compindex,
            .order = layer.order,
        }) catch |err| {
            failSurfaceLayout(self, err);
            return &.{};
        };
    }

    // Back-to-front: smaller first. Same z order the composited overlay used.
    std.sort.block(GridEntry, self.grid_entries.items, {}, struct {
        fn lessThan(_: void, a: GridEntry, b: GridEntry) bool {
            if (a.zindex != b.zindex) return a.zindex < b.zindex;
            if (a.compindex != b.compindex) return a.compindex < b.compindex;
            if (a.order != b.order) return a.order < b.order;
            return a.grid_id < b.grid_id;
        }
    }.lessThan);

    return self.grid_entries.items;
}

/// Collect one surface's layers, back-to-front, into `core.layout_scratch`.
/// `win_pos` positions are already global grid coordinates, so a main-surface
/// layer's origin is its cell position scaled by the cell size; on an external
/// surface the root grid's own global position is subtracted.
fn collectSurfaceLayers(self: *Core, surface_id: i64) []const c_api.Layer {
    self.layout_scratch.clearRetainingCapacity();
    const root = self.grid.bufFor(surface_id) orelse return &.{};
    const cell_w: i64 = @intCast(@max(1, self.cell_w_px));
    const cell_h: i64 = @intCast(@max(1, self.cell_h_px));

    self.layout_scratch.append(self.alloc, &self.layout_budget, .{
        .grid_id = surface_id,
        .anchor_grid = surface_id,
        .x_px = 0,
        .y_px = 0,
        .rows = root.rows,
        .cols = root.cols,
        .z = 0,
        // The header promises MOUSE_ENABLED is always set for the root, and
        // every hit test is about to start relying on that: a main-window one
        // written as a uniform loop over all layers would otherwise skip
        // layers[0] and leave the root grid unclickable. Today's consumers all
        // iterate layers[1..], so this changes nothing for them.
        .flags = c_api.LAYER_MOUSE_ENABLED,
    }) catch |err| {
        failSurfaceLayout(self, err);
        return &.{};
    };

    // Origin of the surface root in global grid cells. Grid 1 is the origin;
    // an external grid carries its own global position.
    var root_row: i64 = 0;
    var root_col: i64 = 0;
    if (surface_id != 1) {
        const ext = self.grid.external_grids.get(surface_id) orelse return self.layout_scratch.items;
        root_row = grid_mod.externalCompositeOriginRow(ext);
        root_col = grid_mod.externalCompositeOriginCol(ext);
    }

    const entries = collectSurfaceLayerEntries(self, surface_id);

    for (entries) |ent| {
        const pos = self.grid.win_pos.get(ent.grid_id) orelse continue;
        const sg = self.grid.sub_grids.get(ent.grid_id) orelse continue;
        const dx: i64 = (@as(i64, pos.col) - root_col) * cell_w;
        const dy: i64 = (@as(i64, pos.row) - root_row) * cell_h;
        self.layout_scratch.append(self.alloc, &self.layout_budget, .{
            .grid_id = ent.grid_id,
            .anchor_grid = pos.anchor_grid,
            .x_px = std.math.cast(i32, dx) orelse continue,
            .y_px = std.math.cast(i32, dy) orelse continue,
            .rows = sg.rows,
            .cols = sg.cols,
            .z = @intCast(self.layout_scratch.items.len),
            .flags = (if (pos.follows_scroll) c_api.LAYER_FOLLOWS_SCROLL else 0) |
                (if (pos.mouse_enabled) c_api.LAYER_MOUSE_ENABLED else 0),
        }) catch |err| {
            failSurfaceLayout(self, err);
            return &.{};
        };
    }

    return self.layout_scratch.items;
}

/// Whether `surface_id` places any grid as a layer on top of its own root.
///
/// The surface is an argument because an external grid is a surface root too,
/// and can host floats exactly as the main window does. Asking this only about
/// surface 1 meant an external root kept painting the default background under
/// its layers, which is the compounded-alpha defect the main-side flag exists
/// to prevent.
fn surfaceHasLayers(self: *Core, surface_id: i64) bool {
    var it = self.grid.win_pos.iterator();
    while (it.next()) |e| {
        const grid_id = e.key_ptr.*;
        if (grid_id == 1) continue;
        if (self.grid.external_grids.contains(grid_id)) continue;
        if (placedSurfaceForGrid(&self.grid, grid_id) != surface_id) continue;
        const sg = self.grid.sub_grids.get(grid_id) orelse continue;
        if (sg.rows == 0 or sg.cols == 0) continue;
        return true;
    }
    return false;
}

/// Under blur a surface root drops its default-background runs while it
/// hosts a layer (the `skip_default_bg` row parameter), so the surface gaining
/// its first layer or losing its last one changes every root row, not only
/// the band a layer covers. Answered here, once per flush for every surface
/// root, by comparing with what the root's rows were last generated under.
/// It was hand-written in three grid mutators for the main surface only, and
/// an external window never regenerated: rows generated before and after the
/// flip disagreed about the default-background quads.
fn regenerateRootsWhoseDefaultBgRuleFlipped(self: *Core) void {
    const main_skip = self.blur_enabled and surfaceHasLayers(self, 1);
    if (main_skip != self.grid.main_buf.skip_default_bg_last) {
        self.grid.main_buf.skip_default_bg_last = main_skip;
        self.grid.markAllDirty();
        // The main pass is gated on content_rev; a flip nothing else bumped
        // it for (blur switched on) would otherwise leave the rows unsent.
        self.grid.content_rev +%= 1;
    }
    var it = self.grid.external_grids.keyIterator();
    while (it.next()) |id| {
        const sg = self.grid.sub_grids.getPtr(id.*) orelse continue;
        const skip = self.blur_enabled and surfaceHasLayers(self, id.*);
        if (skip != sg.skip_default_bg_last) {
            sg.skip_default_bg_last = skip;
            sg.markAllDirty();
        }
    }
}

/// Fill `core.emit_grid_ids` with every grid that emits its own rows: the
/// external grids plus the composited grids the main surface places as layers.
/// Grid 1 is emitted by the main row loop and is deliberately absent.
fn collectEmitGrids(self: *Core) void {
    self.emit_grid_ids.clearRetainingCapacity();
    var ext_it = self.grid.external_grids.keyIterator();
    while (ext_it.next()) |grid_id_ptr| {
        self.emit_grid_ids.append(self.alloc, &self.layout_budget, grid_id_ptr.*) catch |err| {
            failSurfaceLayout(self, err);
            return;
        };
    }
    var it = self.grid.win_pos.keyIterator();
    while (it.next()) |id| {
        if (id.* == 1 or self.grid.external_grids.contains(id.*)) continue;
        if (placedSurfaceForGrid(&self.grid, id.*) == null) continue;
        const sg = self.grid.sub_grids.get(id.*) orelse continue;
        if (sg.rows == 0 or sg.cols == 0) continue;
        self.emit_grid_ids.append(self.alloc, &self.layout_budget, id.*) catch |err| {
            failSurfaceLayout(self, err);
            return;
        };
    }
}

/// Publish one surface's layer list when it changed. Returns false when the
/// flush was cancelled mid-callback.
fn emitSurfaceLayout(self: *Core, surface_id: i64) bool {
    const cb = self.cb.on_surface_layout orelse return true;
    const root = self.grid.bufFor(surface_id) orelse return true;
    const rows = root.rows;
    const cols = root.cols;

    const layers = collectSurfaceLayers(self, surface_id);
    if (self.flush_aborted) return false;
    if (layers.len == 0) return true;
    if (self.last_surface_layout.getPtr(surface_id)) |prev| {
        if (prev.matches(layers, rows, cols)) return true;
    }

    const entry = self.last_surface_layout.getOrPut(self.alloc, surface_id) catch |err| {
        failSurfaceLayout(self, err);
        return false;
    };
    if (!entry.found_existing) entry.value_ptr.* = .{};
    const sig = entry.value_ptr;
    // A destination owns its row storage independently. Placement alone is
    // insufficient when a grid (including an anchored descendant) migrates
    // to another surface without a grid_line event.
    for (layers) |layer| {
        if (layer.grid_id == surface_id) continue;
        var already_hosted = false;
        if (sig.valid) {
            for (sig.layers.slice()) |old| {
                if (old.grid_id == layer.grid_id) {
                    already_hosted = true;
                    break;
                }
            }
        }
        if (!already_hosted) {
            if (self.grid.sub_grids.getPtr(layer.grid_id)) |sg| {
                sg.markAllDirty();
                // There are no surviving destination row slots to rotate.
                sg.scroll_fast_path_blocked = true;
            }
        }
    }
    sig.valid = false;
    sig.layers.resize(self.alloc, &self.layout_budget, layers.len) catch |err| {
        failSurfaceLayout(self, err);
        return false;
    };
    @memcpy(sig.layers.items[0..layers.len], layers);
    sig.surface_rows = rows;
    sig.surface_cols = cols;

    traceRender(self, "event=layout_stage surface={d} layers={d} rows={d} cols={d} metadata_bytes={d}\n", .{ surface_id, layers.len, rows, cols, self.layout_budget.live_bytes.load(.monotonic) });
    if (self.log.verbose and self.log.cb != null and !self.log.perf_only and !self.log.scroll_only) {
        for (layers) |layer| traceRender(self, "event=placement surface={d} grid={d} anchor={d} x_px={d} y_px={d} rows={d} cols={d} z={d} flags={d}\n", .{ surface_id, layer.grid_id, layer.anchor_grid, layer.x_px, layer.y_px, layer.rows, layer.cols, layer.z, layer.flags });
    }
    cb(self.ctx, surface_id, layers.ptr, layers.len, rows, cols);
    if (self.flush_aborted) return false;
    sig.valid = true;
    return true;
}

/// Publish every live surface's layer list, then drain the destroyed-grid
/// queue. Runs inside the flush bracket after external-window lifecycle, so a
/// surface always exists on the frontend before its layout arrives.
///
/// A flush publishes layouts TWICE: once here, and once again before row-shift
/// dispatch, which needs a moved grid's destination resolved before any
/// callback routes it. See that site for why neither is redundant.
pub fn notifySurfaceLayouts(self: *Core) void {
    publishSurfaceLayouts(self);
    if (self.flush_aborted) return;

    if (self.grid.destroyed_pending.items.len != 0) {
        if (self.cb.on_grid_destroy) |cb| {
            for (self.grid.destroyed_pending.items) |grid_id| {
                traceRender(self, "event=destroy_stage grid={d}\n", .{grid_id});
                cb(self.ctx, grid_id);
                if (self.flush_aborted) return;
            }
        }
        // A late on_flush_end rejection must retry destruction along with
        // the layout. Keep mirrors alive until the old frame is replaced.
        if (!self.vertex_budget_transaction_active) {
            for (self.grid.destroyed_pending.items) |grid_id| self.removeGlyphMirror(grid_id);
            self.grid.destroyed_pending.clearRetainingCapacity();
        }
    }
}

fn publishSurfaceLayouts(self: *Core) void {
    if (self.flush_aborted) return;

    // Before the layers are read: this batch's scroll, if it had one, is the
    // evidence for which floats track the buffer. It is still pending here --
    // clearScrolledGrids runs at transaction end, after this.
    self.grid.settleFloatScrollFollowing();

    if (self.cb.on_surface_layout != null) {
        if (!emitSurfaceLayout(self, 1)) return;
        var ext_it = self.grid.external_grids.keyIterator();
        while (ext_it.next()) |grid_id| {
            // notifyExternalWindowChanges withholds on_external_window for a
            // grid still awaiting its initial resize, so no frontend surface
            // exists to receive a layout: both abort the flush for an
            // unregistered surface, and the retry re-emits the same layout.
            if (self.grid.pending_ext_window_grids.contains(grid_id.*)) continue;
            if (!emitSurfaceLayout(self, grid_id.*)) return;
        }
        // Surfaces that no longer exist cannot be re-sent stale signatures.
        var sig_it = self.last_surface_layout.iterator();
        while (sig_it.next()) |entry| {
            const id = entry.key_ptr.*;
            if (id == 1 or self.grid.external_grids.contains(id)) continue;
            entry.value_ptr.layers.deinit();
            self.last_surface_layout.removeByPtr(entry.key_ptr);
        }
    }
}

pub fn notifyExternalWindowChanges(self: *Core) bool {
    var new_grids_added = false;

    // Never emit window lifecycle callbacks for a flush whose frontend
    // transaction was cancelled; the retry flush repeats them before its commit.
    if (self.flush_aborted) return false;

    // Removal marks the slot as a tombstone without rehashing or relocating
    // entries, so advancing the iterator then removeByPtr is safe and visits
    // every known grid once.
    var known_it = self.known_external_grids.iterator();
    while (known_it.next()) |entry| {
        const grid_id = entry.key_ptr.*;
        if (!self.grid.external_grids.contains(grid_id)) {
            if (self.cb.on_external_window_close) |cb| cb(self.ctx, grid_id);
            if (self.flush_aborted) return new_grids_added;
            self.known_external_grids.removeByPtr(entry.key_ptr);
        }
    }

    var ext_it = self.grid.external_grids.iterator();
    while (ext_it.next()) |entry| {
        const grid_id = entry.key_ptr.*;
        const info = entry.value_ptr.*;

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

            // Reserve the known-map entry before invoking the frontend, so OOM
            // is a clean pre-callback abort rather than an opened window that
            // was never recorded (duplicate opens, lost closes on retry).
            self.known_external_grids.ensureUnusedCapacity(self.alloc, 1) catch {
                self.flush_aborted = true;
                return new_grids_added;
            };
        }

        if (self.cb.on_external_window) |cb| {
            cb(self.ctx, grid_id, info.win, rows, cols, info.start_row, info.start_col);
        }
        // A lifecycle callback may abort the enclosing frontend transaction
        // (Windows does this when queueing or PostMessageW fails), which every
        // frontend cancels in on_flush_end; the retry flush revisits this grid
        // and every undispatched one.
        if (self.flush_aborted) return new_grids_added;

        // Add/update the known set only after the callback completed without
        // aborting. New entries use the capacity reserved above; changed ones
        // update in place and cannot allocate.
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

/// Pixels of the row's line spacing that sit above the text, the rest below.
/// Neovim allows a negative 'linespace' to pull lines together, so this is
/// signed and the row is then shorter than the font's own cell.
fn rowTopPadPx(linespace_px: i32) i32 {
    return @divTrunc(linespace_px, 2);
}

/// Deco flags for a cursor glyph. The same set on every surface: the emoji test
/// is `>= 4` as it is at every other row-path site (`== 4` here was the only
/// exception, and `bytes_per_pixel` is documented as 1, 3 or 4).
/// One cursor cell to emit: where it is, what shape and colours it takes, and
/// the cell under it. Grid-local pixels.
pub const CursorCellQuads = struct {
    grid_id: i64,
    row: u32,
    col: u32,
    x0: f32,
    y0: f32,
    cell_w: f32,
    cell_h: f32,
    top_pad: f32,
    /// One cell, or two for a double-width character.
    width: f32,
    /// 0 block, 1 vertical, 2 horizontal (grid.CursorShape and c_api order).
    shape: u8,
    /// cell_percentage, clamped to 1..100 here.
    pct: u32,
    bg_rgb: u32,
    fg_rgb: u32,
    cell: grid_mod.Cell,
};

pub const CursorEmitResult = enum {
    ok,
    /// A transient glyph miss: do not consume the cursor revision, retry.
    retry,
    /// The core aborted the flush while ensuring the glyph.
    aborted,
};

/// The cursor's box and, for a block cursor, the inverted character under
/// it. The main surface and the external pass each carried a copy of this;
/// they differed only in where the colours and shape were read from and in
/// how an error is reported, which stay with the callers. A box-drawing
/// character is trimmed to the cell exactly as row generation trims it.
pub fn emitCursorQuads(core: *Core, out: *std.ArrayListUnmanaged(c_api.Vertex), q: CursorCellQuads) !CursorEmitResult {
    const pct: f32 = @floatFromInt(@max(@as(u32, 1), @min(q.pct, 100)));
    var rx1: f32 = q.x0 + q.width;
    var ry0: f32 = q.y0;
    const ry1: f32 = q.y0 + q.cell_h;
    switch (q.shape) {
        // A bar is a fraction of ONE cell's width, double-width or not.
        1 => rx1 = q.x0 + q.cell_w * pct / 100.0,
        2 => ry0 = q.y0 + (q.cell_h - q.cell_h * pct / 100.0),
        else => {},
    }

    // DECO_CURSOR so the shader treats it as decoration, not a background
    // subject to transparency.
    try out.ensureUnusedCapacity(core.alloc, 6);
    Helpers.pushSolidQuadAssumeCapacity(out, q.x0, ry0, rx1, ry1, Helpers.rgb(q.bg_rgb), q.grid_id, c_api.DECO_CURSOR | c_api.DECO_SCROLLABLE);

    // The character under a block cursor, in inverted colour.
    const cp = q.cell.cp;
    if (q.shape != 0 or cp == 0 or cp == ' ') return .ok;

    if (block_elements.isBlockElement(cp)) {
        const blk_geo = block_elements.getBlockGeometry(cp);
        if (blk_geo.count == 0) return .ok;
        try out.ensureUnusedCapacity(core.alloc, @as(usize, blk_geo.count) * 6);
        const fg_col = Helpers.rgb(q.fg_rgb);
        for (blk_geo.rects[0..blk_geo.count]) |rect| {
            // DECO_CURSOR for the same reason the box carries it: the shader
            // fades plain solids to `backgroundAlpha` once blur is on, so the
            // box behind the glyph would stay opaque while the glyph itself
            // went translucent.
            Helpers.pushSolidQuadAssumeCapacity(out, q.x0 + rect.x0 * q.width, q.y0 + rect.y0 * q.cell_h, q.x0 + rect.x1 * q.width, q.y0 + rect.y1 * q.cell_h, fg_col, q.grid_id, c_api.DECO_CURSOR | c_api.DECO_SCROLLABLE);
        }
        return .ok;
    }

    const ensure_base = core.cb.on_atlas_ensure_glyph;
    const ensure_styled = core.cb.on_atlas_ensure_glyph_styled;
    if (!core.isPhase2Atlas() and ensure_base == null and ensure_styled == null) return .ok;

    const style: u8 = core.hl.getWithStyles(q.cell.hl).style_flags;
    const style_mask = style & (STYLE_BOLD | STYLE_ITALIC);
    const c_style: u32 =
        @as(u32, if (style & STYLE_BOLD != 0) c_api.STYLE_BOLD else 0) |
        @as(u32, if (style & STYLE_ITALIC != 0) c_api.STYLE_ITALIC else 0);

    // Emoji cluster context when the cell's overflow carries emoji-significant
    // codepoints (VS16, ZWJ, skin tone).
    const overflow = core.grid.getOverflow(q.grid_id, q.row, q.col);
    if (overflow) |extras| {
        const is_emoji = isEmojiPresentation(cp) or for (extras) |e| {
            if (e == 0xFE0F or e == 0x200D or (e >= 0x1F3FB and e <= 0x1F3FF)) break true;
        } else false;
        if (is_emoji) {
            core.emoji_cluster_buf[0] = cp;
            const elen = @min(extras.len, core.emoji_cluster_buf.len - 1);
            for (0..elen) |ei| core.emoji_cluster_buf[1 + ei] = extras[ei];
            core.emoji_cluster_len = @intCast(1 + elen);
        }
    }
    defer core.emoji_cluster_len = 0;

    var ge: c_api.GlyphEntry = undefined;
    var glyph_ok = false;
    if (core.isPhase2Atlas()) {
        if (try ensureCachedPhase2Glyph(core, cp, c_style, overflow)) |entry| {
            ge = entry;
            glyph_ok = true;
        } else if (core.flush_aborted) {
            return .aborted;
        } else {
            return .retry;
        }
    } else if (style_mask != 0 and ensure_styled != null) {
        glyph_ok = ensure_styled.?(core.ctx, cp, c_style, &ge) != 0;
    } else if (ensure_base) |base_fn| {
        glyph_ok = base_fn(core.ctx, cp, &ge) != 0;
    }
    if (!glyph_ok or ge.bbox_size_px[0] <= 0 or ge.bbox_size_px[1] <= 0) return .ok;

    const baseline_y: f32 = q.y0 + q.top_pad + ge.ascent_px;
    const gx0: f32 = q.x0 + ge.bbox_origin_px[0];
    const gx1: f32 = gx0 + ge.bbox_size_px[0];
    const raw_gy0: f32 = baseline_y - (ge.bbox_origin_px[1] + ge.bbox_size_px[1]);
    const span = vertexgen.trimBoxDrawingSpanY(
        cp,
        .{ .y0 = raw_gy0, .y1 = raw_gy0 + ge.bbox_size_px[1], .v0 = ge.uv_min[1], .v1 = ge.uv_max[1] },
        q.y0,
        q.y0 + q.cell_h,
    );
    try out.ensureUnusedCapacity(core.alloc, 6);
    VH.pushGlyphQuadAssumeCapacity(
        out,
        gx0,
        span.y0,
        gx1,
        span.y1,
        .{ ge.uv_min[0], span.v0 },
        .{ ge.uv_max[0], span.v0 },
        .{ ge.uv_min[0], span.v1 },
        .{ ge.uv_max[0], span.v1 },
        Helpers.rgb(q.fg_rgb),
        q.grid_id,
        cursorGlyphDecoFlags(ge.bytes_per_pixel),
    );
    return .ok;
}

fn cursorGlyphDecoFlags(bytes_per_pixel: u32) u32 {
    return c_api.DECO_CURSOR | c_api.DECO_SCROLLABLE |
        (if (bytes_per_pixel >= 4) c_api.DECO_COLOR_EMOJI else 0);
}

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
    // A grid composited as a LAYER has no host window, so external windows are
    // the wrong thing to wait for: with none of them, last_ext_cursor_grid
    // stayed 1 while a float owned the cursor, and the owning grid never got
    // the empty CURSOR set that hiding the cursor (busy_start) needs. Its
    // vertices come from emit_grid_ids below, which is built from sub_grids,
    // so a cursor sitting on one is safe to consume here.
    const cursor_grid_is_emitted = cursor_grid == 1 or self.grid.sub_grids.contains(cursor_grid);
    // Hold off consuming the cursor grid while the cursor sits on an external
    // grid whose host window is not created yet (in external_grids but not yet
    // known_external_grids). Consuming it lets grid_changed go false on the next
    // flush, so the cursor layer is never re-emitted into the freshly created
    // view and stays invisible until the next keystroke. has_external_grids can
    // already be true here (opening ext_cmdline from a focused float), so that
    // broader gate does not cover this case.
    const cursor_grid_pending = self.grid.external_grids.contains(cursor_grid) and
        !self.known_external_grids.contains(cursor_grid);
    defer {
        // A per-grid callback below (e.g. Windows external row-buffer OOM) may
        // call zonvie_core_abort_flush mid-loop, and the frontend cancels the
        // whole bracket — skip syncing so cursor_changed/cursor_grid_changed
        // still read true next call and the cancelled update is resent.
        if (!self.flush_aborted and !ext_cursor_retry_required) {
            if ((has_external_grids or cursor_grid_is_emitted) and !cursor_grid_pending) {
                self.last_ext_cursor_grid = cursor_grid;
            }
            self.last_ext_cursor_rev = cursor_rev;
            // Only a full scan (only_grid_id == null) may consume this. A
            // filtered, single-grid call can run before the real retry and
            // would otherwise clear the flag having re-checked only ONE grid,
            // silently skipping the rest.
            if (only_grid_id == null) {
                self.force_ext_cursor_recheck = false;
            }
        }
    }

    // Cursor on a CLOSED grid (e.g. the cmdline going away): force-redraw
    // whichever grid previously held it.
    //
    // "Closed" has to mean no surface places the grid any more. The test used
    // to be `not an external root`, which is also true of every split the main
    // window places and of every float this very window hosts — so an ordinary
    // cursor move out of an external window regenerated that window's every
    // row. The grid the cursor left is already told to clear by the empty
    // cursor set the loop below sends it, so nothing but a genuinely departed
    // grid needs more than that.
    const cursor_on_closed_grid = cursor_grid != 1 and
        placedSurfaceForGrid(&self.grid, cursor_grid) == null;
    const need_force_redraw_last = cursor_on_closed_grid and
        self.known_external_grids.contains(self.last_ext_cursor_grid);

    if (need_force_redraw_last) {
        self.log.write("[sendExternalGridVertices] cursor on closed grid, forcing redraw of last_grid={d}\n", .{self.last_ext_cursor_grid});
    }

    // Window activation only matters for external grid windows, and without
    // them cursor_grid_changed compares against a stale last_ext_cursor_grid
    // and produces false positives.
    if (cursor_grid_changed and has_external_grids) {
        if (self.cb.on_cursor_grid_changed) |cursor_cb| {
            cursor_cb(self.ctx, cursor_grid);
        }
    }

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



    self.initHlCache() catch {
        self.log.write("[ext_grid] Failed to initialize hl cache\n", .{});
    };
    self.initGlyphCache() catch {
        self.log.write("[ext_grid] Failed to initialize glyph cache\n", .{});
    };

    var cache = FlushCache{
        .hl_cache_buf = self.hl_cache_buf orelse &.{},
        .hl_valid_buf = self.hl_valid_buf orelse &.{},
    };
    // Once for this pass, not once per grid. The validity bits are indexed by
    // Neovim's global hl_id, so a resolution one grid paid for is good for
    // every other grid in the same flush; clearing them per grid both memset
    // the whole table (up to the configured hl_cache_size) N times and threw
    // away every cross-grid hit. The main pass already clears them once for
    // itself, on the same reasoning.
    cache.reset();
    // Glyph cache is persistent across flushes (same as row_mode path).

    // If any grid triggers an atlas reset, already-sent grids have stale UVs.
    var ext_saw_atlas_reset_any: bool = false;

    // Every grid other than grid 1 is emitted here, in its own grid-local pixel
    // space: external grids as their own surface's root, composited grids as a
    // layer of the surface that places them. The set is built from
    // external_grids rather than known_external_grids, so a newly added grid
    // (e.g. a popupmenu) still gets vertices inside this flush bracket.
    collectEmitGrids(self);
    for (self.emit_grid_ids.items) |grid_id_value| {
        const grid_id_ptr = &grid_id_value;
        // A prior grid in this loop may have aborted the flush; the frontend
        // cancels the whole bracket, so composing more would be discarded work.
        if (self.flush_aborted) break;

        const grid_id = grid_id_ptr.*;

        if (only_grid_id) |target_id| {
            if (grid_id != target_id) continue;
        }

        const sg = self.grid.sub_grids.getPtr(grid_id) orelse continue;

        const cursor_on_this_grid = externalCursorVisibleOnGrid(&self.grid, grid_id);
        const cursor_was_on_this_grid = (self.last_ext_cursor_grid == grid_id);
        // force_ext_cursor_recheck re-checks EVERY external grid's cursor state
        // once, since a prior failed flush may have left last_ext_cursor_grid
        // naming the wrong (or right, but unconfirmed) grid.
        const cursor_affected = (cursor_changed and (cursor_on_this_grid or cursor_was_on_this_grid)) or
            self.force_ext_cursor_recheck;
        const cursor_moved_within = cursor_changed and cursor_on_this_grid and !cursor_grid_changed;

        // Check if this grid needs forced redraw because cursor left closed cmdline
        const force_redraw_this = need_force_redraw_last and (grid_id == self.last_ext_cursor_grid);

        self.log.write("[ext_cursor_check] grid_id={d} dirty={} cursor_on={} cursor_was={} affected={} moved_within={} force={} force_closed={} cursor_grid={d} last_grid={d} rev={d} last_rev={d}\n", .{
            grid_id,     sg.dirty,                  cursor_on_this_grid, cursor_was_on_this_grid,  cursor_affected, cursor_moved_within, force_render, force_redraw_this,
            cursor_grid, self.last_ext_cursor_grid, cursor_rev,          self.last_ext_cursor_rev,
        });

        if (!force_render and !force_redraw_this and !sg.dirty and !cursor_affected and !cursor_moved_within) continue;

        // Counters only: the hl validity table is this whole pass's, cleared above.
        cache.resetCounters();

        // Full redraw only for forced operations, not cursor-only changes.
        // Cursor rows are handled via dirty_rows marking below.
        const need_full_redraw = force_render or force_redraw_this;

        const viewport_cols = sg.cols;
        const viewport_rows = sg.rows;
        const cursor_row: ?u32 = if (externalCursorVisibleOnGrid(&self.grid, grid_id))
            self.grid.cursor_row
        else
            null;
        const cursor_col = self.grid.cursor_col;
        var ext_saw_atlas_reset: bool = false;
        var ext_had_row_error: bool = false;
        var ext_had_glyph_miss: bool = false;
        // Rows this pass regenerated, for the [ext_grid_row] report.
        var regen_count: u32 = 0;

        ext_verts.clearRetainingCapacity();

        self.log.write("[ext_grid_debug] grid_id={d} sg.rows={d} sg.cols={d} sg.cells.len={d}\n", .{
            grid_id, sg.rows, sg.cols, sg.cells.len,
        });

        // Cursor-only changes must not allocate/scan an entire external grid.
        // The row pipeline below is needed only when content itself is dirty.
        if (sg.dirty or need_full_redraw) {
            const ext_margins = self.grid.getViewportMargins(grid_id);

            const is_cmdline = grid_id == grid_mod.CMDLINE_GRID_ID;
            // An external grid is a surface root and can host floats, so it owes
            // the same rule the main root does: once a layer paints the default
            // background over it, painting it here too compounds the alpha under
            // blur. Settled for every root at the start of the flush
            // (regenerateRootsWhoseDefaultBgRuleFlipped); a layer's own flag
            // is never set, which is its answer.
            const surface_skips_default_bg = sg.skip_default_bg_last;

            // A scroll the frontend was sent a row shift for (see
            // dispatchGridRowScroll) needs only the rows it vacated; scroll()
            // marks exactly those dirty. Any other scroll left the frontend's
            // rows where they were, so every row is regenerated — a rejected
            // fast path (several scrolls in a batch, a delta past half the
            // region, a partial width) and a shift never dispatched alike.
            // This pass used to re-derive the dispatch's conditions instead of
            // asking whether it ran, and the two could disagree.
            const ext_scroll_needs_full_regen: bool =
                sg.last_scroll_op != null and !sg.row_shift_sent;

            // The cursor is a separate layer emitted after the row loop, never
            // inline in row vertices, which is what stops it ghosting across a
            // scroll copy.

            // Viewport dimensions, not sg's, so the frontend's scroll offset
            // calculation matches the rows emitted here.
            const ext_src = GridRowSource{
                .grid_id = grid_id,
                .buf = sg,
                .rows = viewport_rows,
                .cols = viewport_cols,
                .margins = ext_margins,
                .is_cmdline = is_cmdline,
                .skip_default_bg = surface_skips_default_bg,
            };
            const ext_tables = RowComposeTables{
                .hl_cache = cache.hl_cache_buf,
                .hl_valid = cache.hl_valid_buf,
                .glow_enabled = ext_glow_enabled,
                .glow_all = ext_glow_all,
                .glow_hl_ids = ext_glow_hl_ids,
            };
            // Row scratch for this grid, once: its width is the grid's.
            self.row_cells.clearRetainingCapacity();
            self.row_cells.ensureTotalCapacity(self.alloc, sg.cols) catch {
                self.flush_aborted = true;
                break;
            };
            self.row_cells.setLen(sg.cols);

            // Only up to viewport_rows, not sg.rows: rows beyond it are not
            // drawable, so the frontend must not receive vertices for them.
            for (0..viewport_rows) |row_idx| {
                // A prior row_cb in this loop may have called
                // zonvie_core_abort_flush (e.g. Windows external row-buffer
                // OOM); the frontend cancels the whole bracket, so further
                // rows would be discarded work.
                if (self.flush_aborted) break;

                const row: u32 = @intCast(row_idx);

                // Fast path: compose only the rows in the regen set.
                // Otherwise use the dirty_rows bitmap, except after a scroll
                // the fast path rejected: the frontend cannot shift rows
                // itself, so every row must be regenerated.
                if (!need_full_redraw and !ext_scroll_needs_full_regen) {
                    // dirty_all dominates; otherwise a row the bitset does
                    // not cover is regenerated, never skipped.
                    if (!sg.dirty_all and
                        sg.dirty_rows.bit_length > row and
                        !sg.dirty_rows.isSet(@as(usize, row)))
                    {
                        continue;
                    }
                }
                regen_count += 1;

                ext_verts.clearRetainingCapacity();

                // Estimate capacity for this row: 6 bg + 6 glyph + 6 deco + 6 overline + 6 glow per cell + 12 cursor
                const row_est = @as(usize, sg.cols) * 24 + 12;
                ext_verts.ensureTotalCapacity(self.alloc, row_est) catch {
                    ext_had_row_error = true;
                    // The frontend must cancel this bracket rather than
                    // commit it with this row silently missing; the outer
                    // grid loop's flush_aborted check stops the rest.
                    self.flush_aborted = true;
                    break;
                };

                composeGridRow(self, ext_src, row, ext_tables, &cache.perf_hl_cache_hits, &cache.perf_hl_cache_misses);
                const row_gen_stats = generateGridRow(self, ext_src, row, ext_glow_enabled, ext_verts) catch |err| {
                    ext_verts.clearRetainingCapacity();
                    ext_had_row_error = true;
                    self.flush_aborted = true;
                    if (Core.isHardRenderFailure(err)) self.failHardRender(err);
                    break;
                };
                ext_had_glyph_miss = ext_had_glyph_miss or row_gen_stats.had_glyph_miss;
                // An atlas reset during this row leaves the rows already sent with stale UVs.
                if (self.atlas_reset_during_flush) {
                    ext_saw_atlas_reset = true;
                    ext_saw_atlas_reset_any = true;
                    self.atlas_reset_during_flush = false;
                    // A reset here also invalidates glyphs the MAIN grid
                    // used earlier in this flush (it always renders before
                    // this deferred external-grid pass), so the end of the
                    // pass cancels the whole commit. Nothing sent from here
                    // on would survive it: stop, rather than restart this
                    // grid's rows or clear them to empty as this did.
                    self.grid.markAllDirty();
                    self.invalidateMirroredFrameState();
                    break;
                }

                // Charged after the reset check, as the root is: a row the
                // cancelled commit discards owes the ledger nothing.
                chargeGridRow(self, ext_src, row, ext_verts.items) catch |err| {
                    ext_had_row_error = true;
                    self.flush_aborted = true;
                    self.failHardRender(err);
                    break;
                };
                sendGridRow(self, row_cb, ext_src, row, ext_verts.items);
            }
        }

        // Cursor layer: a separate on_vertices_row with the CURSOR flag, which
        // keeps the cursor out of the row buffers so a GPU scroll copy cannot
        // ghost it. Skipped on abort, and after an atlas reset that cancels
        // the commit — either way it would be discarded work.
        if (!self.flush_aborted and !ext_saw_atlas_reset_any) {
            if (cursor_row) |cur_row| {
                if (cur_row < sg.rows and cursor_col < sg.cols) {
                    ext_verts.clearRetainingCapacity();
                    // Estimate: 6 cursor bg + 6 cursor text + block element quads
                    ext_verts.ensureTotalCapacity(self.alloc, 48) catch {
                        self.flush_aborted = true;
                        return;
                    };

                    var is_double_width = false;
                    if (cursor_col + 1 < sg.cols) {
                        const next_idx: usize = @as(usize, cur_row) * @as(usize, sg.cols) + @as(usize, cursor_col + 1);
                        if (next_idx < sg.cells.len and sg.cells[next_idx].cp == 0) {
                            is_double_width = true;
                        }
                    }
                    const cell_idx: usize = @as(usize, cur_row) * @as(usize, sg.cols) + @as(usize, cursor_col);
                    const cursor_cell: grid_mod.Cell = if (cell_idx < sg.cells.len) sg.cells[cell_idx] else .{ .cp = 0, .hl = 0 };
                    const attr = if (self.grid.cursor_attr_id != 0) self.hl.get(self.grid.cursor_attr_id) else null;

                    self.log.write("[ext_cursor] shape={s} pct={d} cursor_style_enabled={}\n", .{
                        @tagName(self.grid.cursor_shape), @max(@as(u32, 1), @min(self.grid.cursor_cell_percentage, 100)), self.grid.cursor_style_enabled,
                    });

                    const emitted = emitCursorQuads(self, ext_verts, .{
                        .grid_id = grid_id,
                        .row = cur_row,
                        .col = cursor_col,
                        .x0 = @as(f32, @floatFromInt(cursor_col)) * cellW,
                        .y0 = @as(f32, @floatFromInt(cur_row)) * cellH,
                        .cell_w = cellW,
                        .cell_h = cellH,
                        .top_pad = topPad,
                        .width = if (is_double_width) cellW * 2 else cellW,
                        .shape = @intFromEnum(self.grid.cursor_shape),
                        .pct = self.grid.cursor_cell_percentage,
                        .bg_rgb = if (attr) |a| a.bg else self.hl.default_fg,
                        .fg_rgb = if (attr) |a| a.fg else self.hl.default_bg,
                        .cell = cursor_cell,
                    }) catch blk: {
                        self.flush_aborted = true;
                        break :blk CursorEmitResult.aborted;
                    };
                    switch (emitted) {
                        .ok => {},
                        .retry => ext_cursor_retry_required = true,
                        .aborted => return,
                    }

                    // The cursor glyph ensure above can trigger an atlas reset
                    // no later code re-checks; handle it here rather than leak
                    // the flag to the next grid.
                    if (self.atlas_reset_during_flush) {
                        ext_saw_atlas_reset = true;
                        ext_saw_atlas_reset_any = true;
                        self.atlas_reset_during_flush = false;
                        self.grid.markAllDirty();
                        self.invalidateMirroredFrameState();
                    }

                    if (self.flush_aborted) return;

                    // The frontend keeps drawing this cursor from its own copy
                    // for as long as the cursor does not move, so the atlas
                    // collector has to see its glyph across later flushes. A
                    // cursor-only glyph (a styled variant, or the standalone
                    // glyph a ligature cell resolves to under the block) sits
                    // in a shelf the row mirror never recorded. cursor_verts is
                    // the buffer the collector already scans, and the main path
                    // leaves it empty whenever the cursor is not on grid 1.
                    self.cursor_verts.clearRetainingCapacity();
                    self.cursor_verts.appendSlice(self.alloc, ext_verts.items) catch {
                        self.flush_aborted = true;
                        return;
                    };

                    traceRender(self, "event=cursor_send grid={d} row={d} vertices={d}\n", .{ grid_id, cur_row, ext_verts.items.len });
                    row_cb(self.ctx, grid_id, cur_row, 1, ext_verts.items.ptr, ext_verts.items.len, c_api.VERT_UPDATE_CURSOR, viewport_rows, viewport_cols);
                    self.log.write("[ext_cursor_layer] grid_id={d} cursor_row={d} cursor_col={d} cursor_verts={d}\n", .{ grid_id, cur_row, cursor_col, ext_verts.items.len });
                } else {
                    // Outside a grid that shrank under it: Neovim moves the
                    // cursor in a later batch, and until then the one this grid
                    // drew must go, as the main surface's does.
                    traceRender(self, "event=cursor_send grid={d} row=0 vertices=0\n", .{grid_id});
                    row_cb(self.ctx, grid_id, 0, 1, null, 0, c_api.VERT_UPDATE_CURSOR, viewport_rows, viewport_cols);
                }
            } else if ((cursor_was_on_this_grid or self.force_ext_cursor_recheck) and !cursor_on_this_grid) {
                // Cursor left this grid: send an empty cursor to clear the
                // previous one. Under force_ext_cursor_recheck,
                // last_ext_cursor_grid cannot be trusted after a prior failed
                // flush, so clearing every OTHER external grid is a harmless
                // no-op for clean grids and closes the gap for the misnamed one.
                traceRender(self, "event=cursor_send grid={d} row=0 vertices=0\n", .{grid_id});
                row_cb(self.ctx, grid_id, 0, 1, null, 0, c_api.VERT_UPDATE_CURSOR, viewport_rows, viewport_cols);
                self.log.write("[ext_cursor_layer] grid_id={d} cursor_left, clearing cursor\n", .{grid_id});
            }
        }

        // scroll_fast_path: the frontend got this scroll as a row shift and
        // was sent only the rows below, instead of the whole viewport.
        self.log.write("[ext_grid_row] grid_id={d} rows={d} cols={d} scroll_fast_path={} regen_count={d}\n", .{
            grid_id, sg.rows, sg.cols, sg.last_scroll_op != null and sg.row_shift_sent, regen_count,
        });

        self.log.write("[ext_grid_perf] grid_id={d} hl_cache hits={d} misses={d}\n", .{
            grid_id, cache.perf_hl_cache_hits, cache.perf_hl_cache_misses,
        });
        self.log.write("[ext_grid_perf] grid_id={d} glyph_cache ascii_hits={d} ascii_misses={d} nonascii_hits={d} nonascii_misses={d}\n", .{
            grid_id, cache.perf_glyph_ascii_hits, cache.perf_glyph_ascii_misses, cache.perf_glyph_nonascii_hits, cache.perf_glyph_nonascii_misses,
        });

        // Skipped on mid-flush abort: keep dirty so the rows are re-sent.
        if (!self.flush_aborted) sg.clearDirtyContent();
        // Re-mark dirty so the failed rows regenerate next flush.
        if (ext_had_row_error) {
            sg.markAllDirty();
        }
        // Re-mark dirty so the grid re-renders with correct UVs next flush.
        if (ext_saw_atlas_reset) {
            sg.markAllDirty();
        }
        // A rasterizer miss is transient (font backend/cache publication may
        // complete before the next frame), so keep the grid dirty rather than
        // let the missing glyph become permanently blank.
        if (ext_had_glyph_miss) {
            sg.markAllDirty();
        }
        // The commit is cancelled below; the remaining grids stay dirty.
        if (ext_saw_atlas_reset_any) break;
    }

    // If any atlas reset occurred, every already-sent grid has stale UVs. The
    // MAIN grid is included: this function runs as a deferred call AFTER the
    // main row loop already dispatched its vertices this same flush, with UVs
    // baked against the pre-reset atlas.
    if (ext_saw_atlas_reset_any) {
        self.grid.markEverySurfaceDirty();
        self.invalidateMirroredFrameState();
        // The cursor is a separate vertex consumer gated on cursor_rev alone,
        // which none of the dirtying above touches.
        self.grid.cursor_rev +%= 1;
        // markAllDirty schedules a correct NEXT flush; it cannot undo THIS
        // flush's already-dispatched main vertices, so signal frontends to
        // cancel the current commit entirely.
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
    // dirty is cleared explicitly at each success-return path below, NOT via
    // defer: on resizeGrid/setWinExternalPos failure cmdline_dirty must stay
    // set, per the "clear dirty only after successful submission" rule.

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

        // last_cmd_buf is written and never read; the split-view label it was
        // collected for was never wired up (see nvim_core.zig). Every update is
        // recorded, so the final content before hide is the executed command.
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
        if (self.last_cmd_start_time == null) {
            self.last_cmd_start_time = clock.nowNs();
        }

        // Minimal info only: the point is to hand the frontend firstc for its
        // icon display, and the content would need type conversion.
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
pub const PopupmenuAnchorPlacement = struct { win: i64, row: i32, col: i32 };

/// Where to publish a buffer-completion popup's anchor: `win` is the window
/// the frontends position from, and (row, col) the anchor cell inside it.
/// Both frontends read (row, col) against the external window `win` names
/// when there is one, and against the main window's grid otherwise.
///
/// So an anchor an external window shows — its root, or a float it hosts —
/// is published local to that window, with the window's root id. A detached
/// split (<C-w>ge) keeps its old main-grid position as its origin, and adding
/// that origin put the popup that far away from the cell; a float the window
/// hosts was published under its own id, found no window, and was placed
/// against the main window. win_pos holds floats anchored into an external
/// window in global units, the same space externalCompositeOriginRow undoes
/// for damage.
pub fn popupmenuAnchorPlacement(g: *const grid_mod.Grid, anchor_grid: i64, anchor_row: i32, anchor_col: i32) PopupmenuAnchorPlacement {
    if (anchor_grid == 1 or g.external_grids.contains(anchor_grid)) {
        return .{ .win = anchor_grid, .row = anchor_row, .col = anchor_col };
    }
    const pos = g.win_pos.get(anchor_grid) orelse return .{ .win = anchor_grid, .row = anchor_row, .col = anchor_col };
    const row = anchor_row +| grid_mod.saturatingI32FromU32(pos.row);
    const col = anchor_col +| grid_mod.saturatingI32FromU32(pos.col);
    const surface = g.surfaceForGrid(anchor_grid) orelse return .{ .win = anchor_grid, .row = row, .col = col };
    if (g.external_grids.get(surface)) |ext| {
        return .{
            .win = surface,
            .row = row -| grid_mod.externalCompositeOriginRow(ext),
            .col = col -| grid_mod.externalCompositeOriginCol(ext),
        };
    }
    return .{ .win = anchor_grid, .row = row, .col = col };
}

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

    // Register as external grid with position: in the coordinates of the
    // window that shows the anchor (see popupmenuAnchorPlacement). Cmdline
    // completion is placed by the frontend from the cmdline window instead.
    const is_cmdline_completion = anchor_grid < 0;
    const placement: PopupmenuAnchorPlacement = if (is_cmdline_completion)
        .{ .win = anchor_grid, .row = -1, .col = anchor_col }
    else
        popupmenuAnchorPlacement(&self.grid, anchor_grid, anchor_row, anchor_col);

    self.grid.putSyntheticExternal(pum_grid_id, .{
        .win = placement.win,
        .start_row = placement.row,
        .start_col = placement.col,
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

/// Widest a message panel may grow, in cells.
const msg_panel_max_width: u32 = 80;

/// start_row/start_col both carry this value on a message panel's external
/// grid entry. No frontend compares against it — both dispatch on the grid
/// id — so its only functional effect is being negative, which routes the
/// grid through the "no main-grid composite" guards.
const msg_panel_top_right: i32 = -2;

/// One padding column on each side of the content, then the cap. A content
/// width of 0 yields a 2-column panel: both padding columns, no content
/// column, since the write loop stops before the right one.
fn msgPanelWidth(content_width: u32) u32 {
    return @min(content_width + 2, msg_panel_max_width);
}

/// Size a message panel's grid and blank it. The clear is not optional:
/// resizeGrid preserves the overlapping region, so a re-render at an
/// unchanged shape would otherwise inherit the previous content's tail.
fn beginMsgPanelGrid(self: *Core, grid_id: i64, height: u32, width: u32) !void {
    try self.grid.resizeGrid(grid_id, height, width);
    self.grid.clearGrid(grid_id);
}

/// Write one line of a message panel, starting after the left padding column
/// and stopping before the right one. A wide codepoint takes two cells, the
/// second written as cp 0; when only one cell is left the body is still
/// written and the placeholder is dropped, so the glyph overhangs the right
/// padding column.
fn writeMsgPanelRow(self: *Core, grid_id: i64, row: u32, line: []const u8, width: u32) void {
    var col: u32 = 1; // Start with 1 cell padding
    var iter = std.unicode.Utf8View.initUnchecked(line).iterator();
    while (iter.nextCodepoint()) |cp| {
        if (col >= width - 1) break;
        self.grid.putCellGrid(grid_id, row, col, cp, 0);
        col += 1;
        if (isWideChar(cp)) {
            if (col >= width - 1) break;
            self.grid.putCellGrid(grid_id, row, col, 0, 0);
            col += 1;
        }
    }
}

/// Register a message panel as an external grid at the top-right sentinel
/// position. Callers own the failure policy: whether the flush is aborted
/// differs between the panels.
fn registerMsgPanelExternal(self: *Core, grid_id: i64) !void {
    try self.grid.putSyntheticExternal(grid_id, .{
        .win = 1, // Global grid
        .start_row = msg_panel_top_right,
        .start_col = msg_panel_top_right,
    });
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
    const width: u32 = msgPanelWidth(self.msg_cached_max_width);

    self.log.write("[msg] renderMsgGridFromCache: lines={d} scroll={d} visible={d} size={d}x{d}\n", .{
        lines.len,
        actual_scroll,
        visible_lines,
        width,
        height,
    });

    // Create or resize grid
    beginMsgPanelGrid(self, msg_grid_id, height, width) catch |e| {
        self.log.write("[msg] resizeGrid failed: {any}\n", .{e});
        return false;
    };

    // Write lines to grid from cache
    for (0..height) |row_idx| {
        const source_line_idx = actual_scroll + row_idx;
        if (source_line_idx >= lines.len) break;

        const cached_line = lines[source_line_idx];
        writeMsgPanelRow(self, msg_grid_id, @intCast(row_idx), cached_line.data[0..cached_line.len], width);
    }

    // Register as external grid
    registerMsgPanelExternal(self, msg_grid_id) catch |e| {
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
    const c_view = c_api.msgViewTypeToC(view);

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
    const c_view = c_api.msgViewTypeToC(view);

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
    const c_view = c_api.msgViewTypeToC(route_result.view);

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
    const c_view = c_api.msgViewTypeToC(route_result.view);

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
    const width: u32 = msgPanelWidth(max_width);

    self.log.write("[msg_history] show: entries={d} size={d}x{d}\n", .{ entries.len, width, height });

    // Create or resize grid
    beginMsgPanelGrid(self, history_grid_id, height, width) catch |e| {
        self.log.write("[msg_history] resizeGrid failed: {any}\n", .{e});
        self.flush_aborted = true;
        return false;
    };

    // Write lines to grid
    for (0..height) |row_idx| {
        writeMsgPanelRow(self, history_grid_id, @intCast(row_idx), lines[row_idx][0..line_lens[row_idx]], width);
    }

    // Register as external grid, positioned like msg_show.
    registerMsgPanelExternal(self, history_grid_id) catch |e| {
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

/// Look up overflow extras for a cell of the row being generated.
///
/// `row`/`col` are the row's own coordinates, which are grid-local: the
/// grids that are not grid 1 compose their rows in their own space, and
/// cell_overflow is keyed the same way.
pub fn getOverflowForCell(core: *Core, rc: *const RenderCells, row: u32, col: u32) ?[]const u32 {
    // The grid-local count avoids a cell-key hash when only another grid owns
    // overflow clusters.
    const gid = rc.grid_ids.items[@intCast(col)];
    if (core.grid.overflowCountForGrid(gid) == 0) return null;
    return core.grid.getOverflow(gid, row, col);
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
    const rgba_flags = cursorGlyphDecoFlags(4);
    try std.testing.expect((rgba_flags & c_api.DECO_CURSOR) != 0);
    try std.testing.expect((rgba_flags & c_api.DECO_SCROLLABLE) != 0);
    try std.testing.expect((rgba_flags & c_api.DECO_COLOR_EMOJI) != 0);
    try std.testing.expect((cursorGlyphDecoFlags(1) & c_api.DECO_COLOR_EMOJI) == 0);
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
    try std.testing.expect(!core.grid.main_buf.dirty_all);
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
    core.grid.main_buf.surface_vertex_count = 12;
    core.flush_vertex_count_aggregate = 12;
    state.abort_main_layout = true;
    try flush_ctx.onFlush(2, 0);
    try std.testing.expect(core.grid.main_buf.dirty_all);
    // A publication refusal leaves the committed frame on screen, so the
    // accounting that described it survives instead of being invalidated.
    try std.testing.expect(core.grid.main_buf.vertex_row_ledger_valid);
    try std.testing.expectEqual(@as(usize, 12), core.grid.main_buf.surface_vertex_count);

    state.abort_main_layout = false;
    try flush_ctx.onFlush(2, 0);
    try std.testing.expect(!core.grid.main_buf.dirty_all);
    try std.testing.expectEqual(core.grid.content_rev, core.last_sent_content_rev);
    try std.testing.expectEqual(@as(usize, 0), core.grid.main_buf.surface_vertex_count);
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
    // Grid.resize allocates the main row ledger; one row is enough here.
    try core.grid.resize(1, 80);
    core.grid.main_buf.vertex_row_counts[0] = 0;
    try beginVertexBudgetTransaction(&core);
    defer finishVertexBudgetTransaction(&core, false);

    // More than the old 54-vertices-per-cell estimate is valid when the
    // actual row payload fits; overflow clusters are charged at this count.
    try replaceSurfaceRowVertexCount(
        &core,
        &core.grid.main_buf.surface_vertex_count,
        core.grid.main_buf.vertex_row_counts,
        0,
        96,
    );
    try std.testing.expectEqual(@as(usize, 96), core.grid.main_buf.surface_vertex_count);

    try std.testing.expectError(
        error.VertexBudgetExceeded,
        replaceSurfaceRowVertexCount(
            &core,
            &core.grid.main_buf.surface_vertex_count,
            core.grid.main_buf.vertex_row_counts,
            0,
            MAX_VERTICES_PER_CALLBACK + 1,
        ),
    );
    try std.testing.expect(!core.flush_retryable);
}

test "vertex budget validates completed state and invalidates metadata on abort" {
    var core = Core.initForTest(std.testing.allocator);
    defer core.deinitForTest();
    // Grid.resize allocates the main row ledger.
    try core.grid.resize(4, 80);

    const moved_count = MAX_VERTICES_PER_SURFACE / 3;
    @memcpy(core.grid.main_buf.vertex_row_counts, &[_]usize{ 0, moved_count, moved_count, moved_count });
    core.grid.main_buf.surface_vertex_count = moved_count * 3;
    try beginVertexBudgetTransaction(&core);

    // Updating the destination first produces a mixed old/new total above the
    // surface cap. The completed frame is small and must remain valid.
    try replaceGridSurfaceRowVertexCount(&core, 1, core.grid.bufFor(1).?, 0, moved_count);
    try replaceGridSurfaceRowVertexCount(&core, 1, core.grid.bufFor(1).?, 1, 0);
    try replaceGridSurfaceRowVertexCount(&core, 1, core.grid.bufFor(1).?, 2, 0);
    try replaceGridSurfaceRowVertexCount(&core, 1, core.grid.bufFor(1).?, 3, 0);
    try validateCompletedVertexBudget(&core);
    try std.testing.expectEqual(moved_count, core.grid.main_buf.vertex_row_counts[0]);
    try std.testing.expectEqual(moved_count, core.grid.main_buf.surface_vertex_count);

    finishVertexBudgetTransaction(&core, false);
    try std.testing.expectEqual(@as(usize, 0), core.grid.main_buf.surface_vertex_count);
    try std.testing.expect(!core.grid.main_buf.vertex_row_ledger_valid);

    try beginVertexBudgetTransaction(&core);
    try replaceGridSurfaceRowVertexCount(&core, 1, core.grid.bufFor(1).?, 0, moved_count);
    try replaceGridSurfaceRowVertexCount(&core, 1, core.grid.bufFor(1).?, 1, 0);
    try replaceGridSurfaceRowVertexCount(&core, 1, core.grid.bufFor(1).?, 2, 0);
    try replaceGridSurfaceRowVertexCount(&core, 1, core.grid.bufFor(1).?, 3, 0);
    try validateCompletedVertexBudget(&core);
    finishVertexBudgetTransaction(&core, true);
    try std.testing.expectEqualSlices(usize, &.{ moved_count, 0, 0, 0 }, core.grid.main_buf.vertex_row_counts);
    try std.testing.expectEqual(moved_count, core.grid.main_buf.surface_vertex_count);
}

test "vertex budget permits aggregate redistribution across external surfaces" {
    var core = Core.initForTest(std.testing.allocator);
    defer core.deinitForTest();
    try core.grid.resize(2, 80);
    @memset(core.grid.main_buf.vertex_row_counts, MAX_VERTICES_PER_CALLBACK);
    core.grid.main_buf.surface_vertex_count = MAX_VERTICES_PER_SURFACE;

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
    try replaceGridSurfaceRowVertexCount(&core, 2, destination, 0, MAX_VERTICES_PER_CALLBACK);
    try replaceGridSurfaceRowVertexCount(&core, 3, source, 0, 0);
    try replaceGridSurfaceRowVertexCount(&core, 3, source, 1, 0);
    try validateCompletedVertexBudget(&core);
    finishVertexBudgetTransaction(&core, true);

    try std.testing.expectEqual(MAX_VERTICES_PER_CALLBACK, destination.surface_vertex_count);
    try std.testing.expectEqual(@as(usize, 0), source.surface_vertex_count);
    try std.testing.expectEqual(
        MAX_VERTICES_PER_SURFACE + MAX_VERTICES_PER_CALLBACK,
        core.flush_vertex_count_aggregate,
    );
}

test "external vertex aggregate follows lifecycle without layout-order scans" {
    var core = Core.initForTest(std.testing.allocator);
    defer core.deinitForTest();

    try core.grid.resizeGrid(2, 2, 1);
    try core.grid.putSyntheticExternal(2, .{ .win = 2, .start_row = 0, .start_col = 0 });
    try beginVertexBudgetTransaction(&core);
    const surface = core.grid.sub_grids.getPtr(2).?;
    try replaceGridSurfaceRowVertexCount(&core, 2, surface, 0, 10);
    try replaceGridSurfaceRowVertexCount(&core, 2, surface, 1, 20);
    try validateCompletedVertexBudget(&core);
    finishVertexBudgetTransaction(&core, true);
    try std.testing.expectEqual(@as(usize, 30), core.grid.subgrid_surface_vertex_count);

    core.grid.scrollGrid(2, 0, 2, 0, 1, 1, 0);
    try std.testing.expectEqual(@as(usize, 20), surface.surface_vertex_count);
    try std.testing.expectEqual(@as(usize, 20), core.grid.subgrid_surface_vertex_count);

    // Layout order changes do not affect physical surface membership or
    // require an external-grid rescan at the next transaction boundary.
    core.grid.layer_order_counter +%= 1;
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
    // One column keeps the cell allocation small; only the ledger length,
    // which follows rows, matters to this test.
    try core.grid.resize(row_count, 1);
    @memset(core.grid.main_buf.vertex_row_counts, untouched_count);
    core.grid.main_buf.surface_vertex_count = row_count * untouched_count;

    try beginVertexBudgetTransaction(&core);
    try replaceGridSurfaceRowVertexCount(&core, 1, core.grid.bufFor(1).?, row_count / 2, 11);
    try validateCompletedVertexBudget(&core);
    finishVertexBudgetTransaction(&core, true);

    try std.testing.expectEqual(@as(usize, 11), core.grid.main_buf.vertex_row_counts[row_count / 2]);
    try std.testing.expectEqual(untouched_count, core.grid.main_buf.vertex_row_counts[0]);
    try std.testing.expectEqual(untouched_count, core.grid.main_buf.vertex_row_counts[row_count - 1]);
    try std.testing.expectEqual(row_count * untouched_count + 4, core.grid.main_buf.surface_vertex_count);
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
        events: [16]u8 = @splat(0),
        event_count: usize = 0,

        fn push(self: *@This(), event: u8) void {
            if (self.event_count >= self.events.len) return;
            self.events[self.event_count] = event;
            self.event_count += 1;
        }

        /// Collapse runs of the same event: the row path emits one 'V' per row
        /// plus one for the cursor layer, and this test pins ordering, not count.
        fn collapsed(self: *const @This(), out: *[16]u8) []const u8 {
            var n: usize = 0;
            for (self.events[0..self.event_count]) |e| {
                if (n != 0 and out[n - 1] == e) continue;
                out[n] = e;
                n += 1;
            }
            return out[0..n];
        }

        fn onBegin(ctx: ?*anyopaque) callconv(.c) void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            self.push('B');
            if (self.abort_at == .begin) self.core.flush_aborted = true;
        }

        fn onVertices(
            ctx: ?*anyopaque,
            grid_id: i64,
            row_start: u32,
            row_count: u32,
            main_verts: ?[*]const c_api.Vertex,
            main_count: usize,
            flags: u32,
            total_rows: u32,
            total_cols: u32,
        ) callconv(.c) void {
            _ = grid_id;
            _ = row_start;
            _ = row_count;
            _ = total_rows;
            _ = total_cols;
            const cursor_verts: ?[*]const c_api.Vertex = null;
            const cursor_count: usize = 0;
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
        core.cb.on_vertices_row = State.onVertices;
        core.cb.on_flush_end = State.onEnd;

        var flush_ctx = FlushCtx{ .core = &core };
        try flush_ctx.onFlush(1, 1);
        try std.testing.expect(!core.grid.main_buf.dirty_all);
        const committed_vertex_count = core.grid.main_buf.surface_vertex_count;
        try std.testing.expect(committed_vertex_count > 0);

        state.abort_at = abort_at;
        state.event_count = 0;
        core.grid.putCell(0, 0, 'B', 0);
        try flush_ctx.onFlush(1, 1);

        var collapse_buf: [16]u8 = undefined;
        const seen = state.collapsed(&collapse_buf);
        if (abort_at == .begin) {
            try std.testing.expectEqualSlices(u8, "BE", seen);
        } else {
            try std.testing.expectEqualSlices(u8, "BVE", seen);
        }

        if (abort_at == .none) {
            try std.testing.expect(!core.flush_aborted);
            try std.testing.expect(!core.grid.main_buf.dirty_all);
            try std.testing.expectEqual(core.grid.content_rev, core.last_sent_content_rev);
            try std.testing.expect(core.grid.main_buf.surface_vertex_count > 0);
        } else if (abort_at == .begin) {
            try std.testing.expect(core.flush_aborted);
            try std.testing.expect(!core.grid.main_buf.dirty_all);
            try std.testing.expect(core.grid.main_buf.dirty_rows.isSet(0));
            try std.testing.expect(core.grid.content_rev != core.last_sent_content_rev);
            try std.testing.expect(core.grid.main_buf.vertex_row_ledger_valid);
            try std.testing.expectEqual(committed_vertex_count, core.grid.main_buf.surface_vertex_count);
        } else {
            // A vertices/end rejection is a publication refusal too: the
            // frontend still shows the previously committed frame, so the
            // retry owes exactly the rows this attempt consumed and the
            // accounting describing that frame survives.
            try std.testing.expect(core.flush_aborted);
            try std.testing.expect(!core.grid.main_buf.dirty_all);
            try std.testing.expect(core.grid.main_buf.dirty_rows.isSet(0));
            try std.testing.expect(core.grid.content_rev != core.last_sent_content_rev or abort_at == .end);
            try std.testing.expect(core.grid.main_buf.vertex_row_ledger_valid);
            try std.testing.expectEqual(committed_vertex_count, core.grid.main_buf.surface_vertex_count);
        }
    }
}

test "row scroll hint covers composited grids and waits for the external seed" {
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
    try core.grid.resizeGrid(1, 4, 4);
    try core.grid.resizeGrid(2, 4, 4);
    try core.grid.setWinPos(2, 42, 0, 0);
    var state = State{};
    core.ctx = &state;

    // A grid the main surface places as a layer owns its rows, so the hint
    // applies to it too — the case composition had to exclude.
    core.grid.scrollGrid(2, 0, 4, 0, 4, 1, 0);
    try std.testing.expect(dispatchGridRowScroll(&core, State.onRowScroll, 2));
    try std.testing.expectEqual(@as(u32, 1), state.calls);
    try std.testing.expectEqual(@as(i64, 2), state.grid_id);
    state = .{};

    core.grid.sub_grids.getPtr(2).?.clearScrollState();
    try std.testing.expect(try core.grid.setWinExternalPos(2, 42));
    // An external grid has no frontend surface to remap until its open
    // callback has seeded one, so the hint must stay silent until then.
    core.grid.scrollGrid(2, 0, 4, 0, 4, 1, 0);
    try std.testing.expect(!dispatchGridRowScroll(&core, State.onRowScroll, 2));
    try std.testing.expectEqual(@as(u32, 0), state.calls);
    try core.known_external_grids.put(core.alloc, 2, .{
        .win = 42,
        .start_row = 0,
        .start_col = 0,
        .rows = 4,
        .cols = 4,
    });
    try std.testing.expect(dispatchGridRowScroll(&core, State.onRowScroll, 2));
    try std.testing.expectEqual(@as(u32, 1), state.calls);
    try std.testing.expectEqual(@as(i64, 2), state.grid_id);
    // The callback rectangle describes the grid's own surface, so its
    // full-width eligibility check agrees with the external-row fast path.
    try std.testing.expectEqual(@as(u32, 0), state.row_start);
    try std.testing.expectEqual(@as(u32, 4), state.row_end);
    try std.testing.expectEqual(@as(u32, 0), state.col_start);
    try std.testing.expectEqual(@as(u32, 4), state.col_end);
    try std.testing.expectEqual(@as(i32, 1), state.rows_delta);
    try std.testing.expectEqual(@as(u32, 4), state.total_rows);
    try std.testing.expectEqual(@as(u32, 4), state.total_cols);
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
        gridScrollFastPathRegion(full, 4, 4, 2, 2).?,
    );

    var invalid = full;
    invalid.left = 1;
    try std.testing.expect(gridScrollFastPathRegion(invalid, 4, 4, 2, 2) == null);
    invalid = full;
    invalid.right = 1;
    try std.testing.expect(gridScrollFastPathRegion(invalid, 4, 4, 2, 2) == null);
    invalid = full;
    invalid.top = 1;
    try std.testing.expect(gridScrollFastPathRegion(invalid, 4, 4, 2, 2) == null);

    inline for (.{ @as(i32, 0), 2, -2, std.math.minInt(i32) }) |rows_delta| {
        invalid = full;
        invalid.rows = rows_delta;
        try std.testing.expect(gridScrollFastPathRegion(invalid, 4, 4, 2, 2) == null);
    }
    invalid = full;
    invalid.cols = 1;
    try std.testing.expect(gridScrollFastPathRegion(invalid, 4, 4, 2, 2) == null);
    try std.testing.expect(gridScrollFastPathRegion(full, 4, 4, 5, 2) == null);
    try std.testing.expect(gridScrollFastPathRegion(full, 4, 4, 2, 5) == null);
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
                // Positions are already grid-local pixels.
                const center_x_px = (min_x + max_x) * 0.5;
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
            if (grid_id != 3 or verts == null) return;
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
    try core.grid.setWinFloatPos(3, 43, 0, 1, 10, 0, 2, true);
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

    // A float over the external grid no longer blocks the hint: eligibility is
    // decided by the grid's own scroll state alone. That exclusion is exactly
    // what composition forced and what per-grid rows removed.
    core.grid.sub_grids.getPtr(2).?.clearScrollState();
    try core.grid.resizeGrid(3, 1, 1);
    try core.grid.setWinFloatPos(3, 43, 100, 0, 10, 0, 2, true);
    core.cb.on_grid_row_scroll = State.onRowScroll;
    core.sendExternalGridVertices(true);
    state = .{};

    core.grid.sub_grids.getPtr(2).?.clearScrollState();
    core.grid.scrollGrid(2, 0, 4, 0, 2, 1, 0);
    try std.testing.expect(dispatchGridRowScroll(&core, State.onRowScroll, 2));
    try std.testing.expectEqual(@as(u32, 1), state.scroll_calls);
}

test "an external scroll whose shift was never sent regenerates every row" {
    const State = struct {
        row_calls: u32 = 0,
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
            _ = vert_count;
            _ = flags;
            _ = total_rows;
            _ = total_cols;
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            self.row_calls += 1;
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
            _ = ctx;
            _ = grid_id;
            _ = row_start;
            _ = row_end;
            _ = col_start;
            _ = col_end;
            _ = rows_delta;
            _ = total_rows;
            _ = total_cols;
        }
    };

    var core = Core.initForTest(std.testing.allocator);
    defer core.deinitForTest();
    try core.grid.resizeGrid(1, 4, 2);
    try core.grid.resizeGrid(2, 4, 2);
    try std.testing.expect(try core.grid.setWinExternalPos(2, 42));
    try core.known_external_grids.put(core.alloc, 2, .{ .win = 42, .start_row = 0, .start_col = 0, .rows = 4, .cols = 2 });
    for (0..4) |row| core.grid.putCellGrid(2, @intCast(row), 0, @intCast('A' + row), 0);
    core.drawable_w_px = 2;
    core.drawable_h_px = 4;
    core.cell_w_px = 1;
    core.cell_h_px = 1;
    core.grid.cursor_visible = false;

    var state = State{};
    core.ctx = &state;
    core.cb.on_vertices_row = State.onRow;
    core.cb.on_grid_row_scroll = State.onRowScroll;
    core.sendExternalGridVertices(true);
    state = .{};

    // A scroll the frontend was never told about (no dispatchGridRowScroll):
    // its retained rows are where they were, so sending only the vacated row
    // would leave the rest a row out. The pass decided eligibility by
    // re-deriving the dispatch's conditions, not by whether it ran.
    core.grid.scrollGrid(2, 0, 4, 0, 2, 1, 0);
    core.sendExternalGridVertices(false);
    try std.testing.expectEqual(@as(u32, 4), state.row_calls);
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
    try std.testing.expectApproxEqAbs(@as(f32, 0), min_x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 20), max_x, 0.001);
    try std.testing.expectEqual(@as(u32, 0), state.ensure_calls);

    // A real space is not a wide-cell continuation.
    core.row_cells.scalars.items[1] = ' ';
    out.clearRetainingCapacity();
    const narrow_stats = try generateRowVertices(&core, params, &out);
    const narrow_glyphs = out.items[narrow_stats.pass_ends[1]..narrow_stats.pass_ends[2]];
    max_x = -std.math.inf(f32);
    for (narrow_glyphs) |vertex| max_x = @max(max_x, vertex.position[0]);
    try std.testing.expectApproxEqAbs(@as(f32, 10), max_x, 0.001);
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
    try std.testing.expectApproxEqAbs(@as(f32, 20), max_x, 0.001);
    try std.testing.expectEqual(@as(u32, 1), state.shape_calls);
    try std.testing.expectEqual(@as(u32, 0), state.raster_calls);
}

test "box drawing glyph quads are trimmed to their cell rows" {
    // Menlo's │ at 13pt is 33px of ink in a 30px cell: 1px above the row and
    // 2px below. Rows drawn one scissored cell at a time clip that away; a
    // full redraw did not, and on a root without background quads the two
    // rows' overhangs blended twice at every join. Trimming the quad itself
    // makes every draw path agree.
    const State = struct {
        entry: c_api.GlyphEntry,

        fn ensure(ctx: ?*anyopaque, scalar: u32, out_entry: *c_api.GlyphEntry) callconv(.c) c_int {
            _ = scalar;
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            out_entry.* = self.entry;
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
            _ = ctx;
            _ = scalars;
            _ = scalar_count;
            _ = style_flags;
            if (out_cap < 1) return 1;
            out_glyph_ids[0] = 42;
            out_clusters[0] = 0;
            out_x_advance[0] = 640;
            out_x_offset[0] = 0;
            out_y_offset[0] = 0;
            return 1;
        }

        // The shaped path needs a phase-2 atlas; the glyph is already cached,
        // so none of these is reached.
        fn raster(ctx: ?*anyopaque, id: u32, style_flags: u32, out_bitmap: *c_api.GlyphBitmap) callconv(.c) c_int {
            _ = ctx;
            _ = id;
            _ = style_flags;
            out_bitmap.* = std.mem.zeroes(c_api.GlyphBitmap);
            return 0;
        }

        fn upload(ctx: ?*anyopaque, dest_x: u32, dest_y: u32, width: u32, height: u32, bitmap: *const c_api.GlyphBitmap) callconv(.c) void {
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

        /// The glyph pass's vertical extent and texture v range.
        fn glyphSpan(vertices: []const c_api.Vertex) [4]f32 {
            var span = [4]f32{ std.math.inf(f32), -std.math.inf(f32), std.math.inf(f32), -std.math.inf(f32) };
            for (vertices) |vertex| {
                span[0] = @min(span[0], vertex.position[1]);
                span[1] = @max(span[1], vertex.position[1]);
                span[2] = @min(span[2], vertex.texCoord[1]);
                span[3] = @max(span[3], vertex.texCoord[1]);
            }
            return span;
        }
    };

    // Row 1 of 10px cells spans y 10..20. The glyph spans 9..22 with v
    // running 0.1 per pixel from 0 at its top, so the cell's share is
    // v 0.1..1.1.
    var entry = std.mem.zeroes(c_api.GlyphEntry);
    entry.uv_min = .{ 0, 0 };
    entry.uv_max = .{ 0.1, 1.3 };
    entry.bbox_origin_px = .{ 4, -4 };
    entry.bbox_size_px = .{ 2, 13 };
    entry.ascent_px = 8;
    var state = State{ .entry = entry };

    var core = Core.initForTest(std.testing.allocator);
    defer core.deinitForTest();
    try core.initGlyphCache();
    try core.grid.resizeGrid(1, 2, 1);
    try core.row_cells.ensureTotalCapacity(core.alloc, 1);
    core.row_cells.setLen(1);
    @memset(core.row_cells.deco_base_flags.items, 0);
    @memset(core.row_cells.glow_arr.items, 0);
    core.ctx = &state;

    var out: std.ArrayListUnmanaged(c_api.Vertex) = .empty;
    defer out.deinit(core.alloc);
    const params = RowGenParams{
        .row = 1,
        .cols = 1,
        .cell_w = 10,
        .cell_h = 10,
        .top_pad = 0,
        .default_bg = 0,
        .blur_enabled = false,
        .background_opacity = 1,
        .is_cmdline = false,
        .glow_enabled = false,
    };

    // Shaped path, as both frontends run it: the glyph comes from the
    // by-id cache.
    core.cb.on_shape_text_run = State.shape;
    core.cb.on_rasterize_glyph_by_id = State.raster;
    core.cb.on_rasterize_glyph = State.raster;
    core.cb.on_atlas_upload = State.upload;
    core.cb.on_atlas_create = State.create;
    const gid: u32 = 42;
    const key = (@as(u64, gid) << 2);
    const hash = gid *% 2654435761;
    const probe = nvim_core.glyphCacheProbe(core.glyph_keys_by_id.?, key, hash);
    core.glyph_cache_by_id.?[probe.insert] = entry;
    core.glyph_keys_by_id.?[probe.insert] = key;

    for ([_]bool{ true, false }) |shaped| {
        if (!shaped) {
            // The per-cell path, taken without shaping or a phase-2 atlas.
            core.cb.on_shape_text_run = null;
            core.cb.on_rasterize_glyph_by_id = null;
            core.cb.on_rasterize_glyph = null;
            core.cb.on_atlas_upload = null;
            core.cb.on_atlas_create = null;
            core.cb.on_atlas_ensure_glyph = State.ensure;
        }

        core.row_cells.set(0, 0x2502, 0xFFFFFF, 0, highlight.Highlights.SP_NOT_SET, 1, 0, 0);
        out.clearRetainingCapacity();
        const box_stats = try generateRowVertices(&core, params, &out);
        const box = State.glyphSpan(out.items[box_stats.pass_ends[1]..box_stats.pass_ends[2]]);
        try std.testing.expectApproxEqAbs(@as(f32, 10), box[0], 0.001);
        try std.testing.expectApproxEqAbs(@as(f32, 20), box[1], 0.001);
        try std.testing.expectApproxEqAbs(@as(f32, 0.1), box[2], 0.001);
        try std.testing.expectApproxEqAbs(@as(f32, 1.1), box[3], 0.001);

        // Only box drawing: any other glyph keeps the ink it overhangs with.
        core.row_cells.set(0, 0x2190, 0xFFFFFF, 0, highlight.Highlights.SP_NOT_SET, 1, 0, 0);
        out.clearRetainingCapacity();
        const arrow_stats = try generateRowVertices(&core, params, &out);
        const arrow = State.glyphSpan(out.items[arrow_stats.pass_ends[1]..arrow_stats.pass_ends[2]]);
        try std.testing.expectApproxEqAbs(@as(f32, 9), arrow[0], 0.001);
        try std.testing.expectApproxEqAbs(@as(f32, 22), arrow[1], 0.001);
    }
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
    try std.testing.expectApproxEqAbs(@as(f32, 0), out.items[out.items.len - 6].position[0], 0.001);

    // The real shaped glyph may also resolve to an empty bitmap. Its
    // multi-scalar fallback must apply the same base anchor rule as .notdef.
    core.resetShapeCache();
    core.resetGlyphCacheFlags();
    state.mode = .empty_by_id;
    out.clearRetainingCapacity();
    _ = try generateRowVertices(&core, params, &out);
    try std.testing.expect(out.items.len >= 12);
    try std.testing.expectApproxEqAbs(@as(f32, 0), out.items[out.items.len - 6].position[0], 0.001);
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
            grid_id: i64,
            row_start: u32,
            row_count: u32,
            main_verts: ?[*]const c_api.Vertex,
            main_count: usize,
            flags: u32,
            total_rows: u32,
            total_cols: u32,
        ) callconv(.c) void {
            _ = grid_id;
            _ = row_start;
            _ = row_count;
            _ = total_rows;
            _ = total_cols;
            const cursor_verts: ?[*]const c_api.Vertex = null;
            const cursor_count: usize = 0;
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
    core.cb.on_vertices_row = State.partial;
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
    // One vertex callback per row per flush, across the three flushes above.
    try std.testing.expectEqual(@as(u32, 7), state.partial_calls);
    try std.testing.expect(!state.background_after_glyph);
}

test "cursor atlas reset cancels current flush before partial commit" {
    const State = struct {
        partial_calls: u32 = 0,

        fn partial(
            ctx: ?*anyopaque,
            grid_id: i64,
            row_start: u32,
            row_count: u32,
            main_verts: ?[*]const c_api.Vertex,
            main_count: usize,
            flags: u32,
            total_rows: u32,
            total_cols: u32,
        ) callconv(.c) void {
            _ = grid_id;
            _ = row_start;
            _ = row_count;
            _ = total_rows;
            _ = total_cols;
            const cursor_verts: ?[*]const c_api.Vertex = null;
            const cursor_count: usize = 0;
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
    core.cb.on_vertices_row = State.partial;
    core.cb.on_rasterize_glyph = State.rasterize;
    core.cb.on_atlas_upload = State.upload;
    core.cb.on_atlas_create = State.create;

    var flush_ctx = FlushCtx{ .core = &core };
    try flush_ctx.onFlush(1, 1);
    try std.testing.expect(core.flush_atlas_corrupted);
    try std.testing.expect(core.grid.main_buf.dirty_all);
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
    try std.testing.expect(core.grid.main_buf.dirty_all);
    try std.testing.expectEqual(@as(u32, 0), state.committed_flushes);
    try std.testing.expectEqual(@as(u32, 1), state.cancelled_flushes);
    try std.testing.expectEqual(@as(u32, 0), state.empty_main_calls);
    try std.testing.expectEqual(@as(u32, 1), state.row_calls);
    try std.testing.expectEqual(@as(u32, 2), state.create_calls);
    try std.testing.expectEqual(@as(u32, 2), state.upload_calls);
}

test "a row-mode atlas reset the retry survives leaves the root clean" {
    // The retry regenerates every root row against the new atlas, so the root
    // owes nothing afterwards. It was still marked all-dirty, which made the
    // next flush regenerate every root row a second time.
    const State = struct {
        core: *Core,
        committed_flushes: u32 = 0,

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
            _ = ctx;
            _ = grid_id;
            _ = row_start;
            _ = row_count;
            _ = verts;
            _ = vert_count;
            _ = flags;
            _ = total_rows;
            _ = total_cols;
        }

        fn onEnd(ctx: ?*anyopaque) callconv(.c) void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            if (!self.core.flush_aborted and !self.core.flush_atlas_corrupted) self.committed_flushes += 1;
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
    // Full: the first glyph grows the atlas, which resets it mid-loop once.
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

    try std.testing.expectEqual(@as(u32, 1), state.committed_flushes);
    try std.testing.expect(!core.grid.main_buf.dirty_all);
}

test "an atlas reset in the external pass stops sending rows the cancelled commit discards" {
    const State = struct {
        core: *Core,
        ext_rows: u32 = 0,
        ext_empty_rows: u32 = 0,
        upload_calls: u32 = 0,

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
            _ = total_rows;
            _ = total_cols;
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            if (grid_id != 2 or flags & c_api.VERT_UPDATE_MAIN == 0) return;
            self.ext_rows += 1;
            if (vert_count == 0) self.ext_empty_rows += 1;
        }

        fn rasterize(ctx: ?*anyopaque, scalar: u32, style_flags: u32, out_bitmap: *c_api.GlyphBitmap) callconv(.c) c_int {
            _ = ctx;
            _ = scalar;
            _ = style_flags;
            out_bitmap.* = .{ .pixels = null, .width = 1, .height = 1, .pitch = 1, .bearing_x = 0, .bearing_y = 1, .advance_26_6 = 64, .ascent_px = 1, .descent_px = 0, .bytes_per_pixel = 1 };
            return 1;
        }

        fn upload(ctx: ?*anyopaque, dest_x: u32, dest_y: u32, width: u32, height: u32, bitmap: *const c_api.GlyphBitmap) callconv(.c) void {
            _ = dest_x;
            _ = dest_y;
            _ = width;
            _ = height;
            _ = bitmap;
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            self.upload_calls += 1;
            // Full again after the first glyph, so a retry would reset twice.
            if (self.upload_calls == 1) {
                self.core.atlas_packer.?.next_x = self.core.atlas_w;
                self.core.atlas_packer.?.next_y = self.core.atlas_h;
                self.core.atlas_packer.?.row_h = 0;
            }
        }

        fn create(ctx: ?*anyopaque, atlas_w: u32, atlas_h: u32) callconv(.c) void {
            _ = ctx;
            _ = atlas_w;
            _ = atlas_h;
        }
    };

    var core = Core.initForTest(std.testing.allocator);
    defer core.deinitForTest();
    try core.grid.resizeGrid(1, 2, 1);
    try core.grid.resizeGrid(2, 2, 1);
    try std.testing.expect(try core.grid.setWinExternalPos(2, 42));
    try core.known_external_grids.put(core.alloc, 2, .{ .win = 42, .start_row = 0, .start_col = 0, .rows = 2, .cols = 1 });
    core.grid.putCellGrid(2, 0, 0, 'A', 0);
    core.grid.putCellGrid(2, 1, 0, 'B', 0);
    core.grid.cursor_visible = false;
    core.drawable_w_px = 1;
    core.drawable_h_px = 2;
    core.cell_w_px = 1;
    core.cell_h_px = 1;
    core.atlas_w = config.atlas_size_default;
    core.atlas_h = config.atlas_size_default;
    core.atlas_packer = shelf_packer.ShelfPacker.init(core.atlas_w, core.atlas_h);
    // Full from the start: the external grid's first glyph resets the atlas.
    core.atlas_packer.?.next_x = core.atlas_w;
    core.atlas_packer.?.next_y = core.atlas_h;
    core.atlas_initialized = true;

    var state = State{ .core = &core };
    core.ctx = &state;
    core.cb.on_vertices_row = State.onRow;
    core.cb.on_rasterize_glyph = State.rasterize;
    core.cb.on_atlas_upload = State.upload;
    core.cb.on_atlas_create = State.create;

    core.sendExternalGridVertices(true);

    // The commit is cancelled either way; everything the grid sends after the
    // reset — a restarted row loop, rows cleared to empty — is discarded.
    try std.testing.expect(core.flush_atlas_corrupted);
    try std.testing.expectEqual(@as(u32, 0), state.ext_empty_rows);
    try std.testing.expectEqual(@as(u32, 0), state.ext_rows);
    try std.testing.expect(core.grid.sub_grids.get(2).?.dirty_all);
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

    // Both branches: a frontend that implements on_grid_row_scroll shifts its
    // own row slots, and one that does not must survive the retry just the same.
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
        if (use_scroll_cb) core.cb.on_grid_row_scroll = State.onMainRowScroll;

        // Warm the glyph mirror and the row ledger, then settle dirty_all so
        // the next flush is eligible for the scroll fast path.
        var flush_ctx = FlushCtx{ .core = &core };
        try flush_ctx.onFlush(ROWS, COLS);
        try flush_ctx.onFlush(ROWS, COLS);
        try std.testing.expect(!core.grid.main_buf.dirty_all);

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

        // The scroll must have gone through the row-shift hint on the branch
        // that registers it, otherwise the retry is never reached and the
        // assertion below would pass vacuously.
        if (use_scroll_cb) try std.testing.expect(state.scroll_calls >= 1);

        // The reset must have fired. Grid 2 is its own layer now, so the
        // reset lands in that grid's own emission, which cancels the bracket
        // rather than retrying inside the main row loop.
        try std.testing.expect(state.reset_seen);

        // Whichever way the reset was handled, no row may be left carrying the
        // pre-reset atlas's UVs: either this flush resent them all, or the
        // flush was cancelled and the next one does.
        state.rows_after_reset = @splat(false);
        try flush_ctx.onFlush(ROWS, COLS);
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
            grid_id: i64,
            row_start: u32,
            row_count: u32,
            main_verts: ?[*]const c_api.Vertex,
            main_count: usize,
            flags: u32,
            total_rows: u32,
            total_cols: u32,
        ) callconv(.c) void {
            _ = grid_id;
            _ = row_start;
            _ = row_count;
            _ = total_rows;
            _ = total_cols;
            const cursor_verts: ?[*]const c_api.Vertex = null;
            const cursor_count: usize = 0;
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
    core.cb.on_vertices_row = State.partial;
    core.cb.on_rasterize_glyph = State.rasterize;
    core.cb.on_atlas_upload = State.upload;
    core.cb.on_atlas_create = State.create;

    var flush_ctx = FlushCtx{ .core = &core };
    try flush_ctx.onFlush(1, 1);
    try std.testing.expect(core.flush_aborted);
    try std.testing.expect(!core.atlas_reset_during_flush);
    try std.testing.expectEqual(@as(u32, 1), state.create_calls);
    try std.testing.expectEqual(@as(u32, 0), state.upload_calls);
    // Rows publish incrementally, so the row before the abort was already
    // handed over; the aborted bracket is what stops it being committed.
    try std.testing.expectEqual(@as(u32, 1), state.partial_calls);

    state.abort_create = false;
    try flush_ctx.onFlush(1, 1);
    try std.testing.expect(!core.flush_aborted);
    try std.testing.expect(!core.flush_atlas_corrupted);
    try std.testing.expect(!core.atlas_reset_during_flush);
    try std.testing.expect(!core.grid.main_buf.dirty_all);
    try std.testing.expectEqual(@as(u32, 2), state.create_calls);
    try std.testing.expectEqual(@as(u32, 1), state.upload_calls);
    // The aborted flush's one row plus this flush's row and cursor layer.
    try std.testing.expectEqual(@as(u32, 3), state.partial_calls);
}

test "atlas reset in the cursor glyph lookup followed by an abort is not a frontend refusal" {
    const State = struct {
        core: *Core,
        abort_create: bool = false,

        fn partial(ctx: ?*anyopaque, grid_id: i64, row_start: u32, row_count: u32, main_verts: ?[*]const c_api.Vertex, main_count: usize, flags: u32, total_rows: u32, total_cols: u32) callconv(.c) void {
            _ = .{ ctx, grid_id, row_start, row_count, main_verts, main_count, flags, total_rows, total_cols };
        }

        fn rasterize(ctx: ?*anyopaque, scalar: u32, style_flags: u32, out_bitmap: *c_api.GlyphBitmap) callconv(.c) c_int {
            _ = .{ ctx, scalar, style_flags };
            out_bitmap.* = .{ .pixels = null, .width = 1, .height = 1, .pitch = 1, .bearing_x = 0, .bearing_y = 1, .advance_26_6 = 64, .ascent_px = 1, .descent_px = 0, .bytes_per_pixel = 1 };
            return 1;
        }

        fn upload(ctx: ?*anyopaque, dest_x: u32, dest_y: u32, width: u32, height: u32, bitmap: *const c_api.GlyphBitmap) callconv(.c) void {
            _ = .{ ctx, dest_x, dest_y, width, height, bitmap };
        }

        fn create(ctx: ?*anyopaque, atlas_w: u32, atlas_h: u32) callconv(.c) void {
            _ = .{ atlas_w, atlas_h };
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            if (self.abort_create) self.core.flush_aborted = true;
        }
    };

    var core = Core.initForTest(std.testing.allocator);
    defer core.deinitForTest();
    try core.grid.resizeGrid(1, 1, 1);
    core.grid.putCell(0, 0, 'A', 0);
    core.grid.cursor_valid = true;
    core.grid.cursor_visible = true;
    core.drawable_w_px = 1;
    core.drawable_h_px = 1;
    core.cell_w_px = 1;
    core.cell_h_px = 1;
    core.atlas_w = config.atlas_size_max;
    core.atlas_h = config.atlas_size_max;
    core.atlas_packer = shelf_packer.ShelfPacker.init(core.atlas_w, core.atlas_h);
    core.atlas_initialized = true;

    var state = State{ .core = &core };
    core.ctx = &state;
    core.cb.on_vertices_row = State.partial;
    core.cb.on_rasterize_glyph = State.rasterize;
    core.cb.on_atlas_upload = State.upload;
    core.cb.on_atlas_create = State.create;

    var flush_ctx = FlushCtx{ .core = &core };
    try flush_ctx.onFlush(1, 1);
    try std.testing.expect(!core.flush_aborted);
    try std.testing.expect(!core.grid.main_buf.dirty_all);

    // Only the cursor is owed, and its glyph is not cached: the lookup
    // resets the full atlas, and the frontend refuses the new atlas. Every
    // row committed earlier now points into the replaced atlas.
    core.grid.main_buf.cells[0].cp = 'B';
    core.grid.cursor_rev +%= 1;
    core.atlas_packer.?.next_y = config.atlas_size_max;
    state.abort_create = true;
    try flush_ctx.onFlush(1, 1);
    try std.testing.expect(core.flush_aborted);
    try std.testing.expect(core.flush_atlas_corrupted);
    try std.testing.expect(core.grid.main_buf.dirty_all);
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

test "external close detection visits known grids once and removes in place" {
    const Recorder = struct {
        fn close(ctx: ?*anyopaque, grid_id: i64) callconv(.c) void {
            const ids: *std.ArrayListUnmanaged(i64) = @ptrCast(@alignCast(ctx.?));
            ids.append(std.testing.allocator, grid_id) catch unreachable;
        }
    };

    var core = Core.initForTest(std.testing.allocator);
    defer core.deinitForTest();
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
            grid_id: i64,
            row_start: u32,
            row_count: u32,
            main_verts: ?[*]const c_api.Vertex,
            main_count: usize,
            flags: u32,
            total_rows: u32,
            total_cols: u32,
        ) callconv(.c) void {
            _ = grid_id;
            _ = row_start;
            _ = row_count;
            _ = total_rows;
            _ = total_cols;
            const cursor_verts: ?[*]const c_api.Vertex = null;
            const cursor_count: usize = 0;
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
    core.cb.on_vertices_row = State.onVertices;

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

test "the internal and ABI message view enums agree name for name and value for value" {
    // The conversions between these two enums are written as identity
    // switches, which is only correct because the two agree by NAME and by
    // VALUE. Both pin 0..5 explicitly and include/zonvie_core.h pins the same
    // six, so renumbering either side would silently put a different integer
    // on the wire while every identity switch still compiled.
    inline for (@typeInfo(config.MsgViewType).@"enum".fields) |field| {
        const abi = @field(c_api.zonvie_msg_view_type, field.name);
        try std.testing.expectEqual(@as(c_int, field.value), @intFromEnum(abi));
    }

    // Comparing the two enums only against each other would pass if both were
    // renumbered together, or if a variant were added to both -- and either
    // change silently breaks include/zonvie_core.h, the third copy of this
    // numbering, which no test reads. Pin the wire values as literals so that
    // adding or renumbering a view has to come here and say so.
    const wire = [_]struct { name: []const u8, value: c_int }{
        .{ .name = "mini", .value = 0 },
        .{ .name = "ext_float", .value = 1 },
        .{ .name = "confirm", .value = 2 },
        .{ .name = "split", .value = 3 },
        .{ .name = "none", .value = 4 },
        .{ .name = "notification", .value = 5 },
    };
    inline for (wire) |w| {
        try std.testing.expectEqual(w.value, @intFromEnum(@field(c_api.zonvie_msg_view_type, w.name)));
        try std.testing.expectEqual(
            @as(u8, @intCast(w.value)),
            @intFromEnum(@field(config.MsgViewType, w.name)),
        );
    }
    try std.testing.expectEqual(wire.len, @typeInfo(config.MsgViewType).@"enum".fields.len);
    try std.testing.expectEqual(wire.len, @typeInfo(c_api.zonvie_msg_view_type).@"enum".fields.len);
}

test "every routed view reaches the msg_show callback as the matching ABI view" {
    // Drives the msg_show conversion once per view type. A swapped or dropped
    // arm shows up as the wrong ABI view arriving at the callback, which a
    // single-view test could not see.
    const State = struct {
        calls: u32 = 0,
        view: c_api.zonvie_msg_view_type = .none,

        fn onMsgShow(
            ctx: ?*anyopaque,
            view: c_api.zonvie_msg_view_type,
            kind: [*]const u8,
            kind_len: usize,
            chunks: [*]const c_api.MsgChunk,
            chunk_count: usize,
            replace_last: c_int,
            history: c_int,
            append: c_int,
            msg_id: i64,
            timeout_ms: u32,
        ) callconv(.c) void {
            _ = kind;
            _ = kind_len;
            _ = chunks;
            _ = chunk_count;
            _ = replace_last;
            _ = history;
            _ = append;
            _ = msg_id;
            _ = timeout_ms;
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            self.calls += 1;
            self.view = view;
        }
    };

    // Only the frontend-rendered views reach this callback (showChannelView
    // routes .ext_float to the core's own external grid and .split back over
    // RPC, and suppresses .none). The other three are checked by their
    // absence, which also pins that this conversion is not on their path.
    const cases = [_]struct { view: config.MsgViewType, expect_call: bool }{
        .{ .view = .mini, .expect_call = true },
        .{ .view = .confirm, .expect_call = true },
        .{ .view = .notification, .expect_call = true },
        .{ .view = .ext_float, .expect_call = false },
        .{ .view = .split, .expect_call = false },
        .{ .view = .none, .expect_call = false },
    };

    for (cases) |case| {
        var core = Core.initForTest(std.testing.allocator);
        defer core.deinitForTest();
        core.ext_messages_enabled = true;

        var routes = [_]config.MsgRoute{
            .{ .filter = .{ .event = .msg_show }, .view = case.view, .opts = .{ .timeout = 0 } },
        };
        core.msg_config.messages.routes = &routes;

        var state = State{};
        core.ctx = &state;
        core.cb.on_msg_show = State.onMsgShow;

        try appendTestMessage(&core, 1, "echo", "hello");
        _ = sendMsgShow(&core);

        if (case.expect_call) {
            try std.testing.expectEqual(@as(u32, 1), state.calls);
            try std.testing.expectEqualStrings(@tagName(case.view), @tagName(state.view));
        } else {
            try std.testing.expectEqual(@as(u32, 0), state.calls);
        }
    }
}

test "composeRowRuns writes one row's attributes, scalars and glow" {
    // The flush-level tests reach this body only through whatever the row
    // path happens to emit, so a fault inside it can hide behind them. This
    // drives the body directly.
    var core = Core.initForTest(std.testing.allocator);
    defer core.deinitForTest();

    // Distinct attributes per hl id, or every run would produce identical
    // bytes and the assertions below could not tell the runs apart.
    core.hl.setDefaults(0x111111, 0x222222, null);
    try core.hl.define(7, 0xAA0000, 0xBB0000, 0xCC0000, false, 0, .{ .bold = true }, false);
    try core.hl.define(9, 0x00AA00, 0x00BB00, null, false, 0, .{}, false);

    // Row of 12: a run of 6 (exercises simdExtractCp's 4-wide body plus its
    // tail), then 4, then 2. hl 7 recurs so the cache hit path runs too.
    const cols: u32 = 12;
    try core.grid.resize(1, cols);
    const text = "AAAAAABBBBCC";
    const hls = [_]u32{ 7, 7, 7, 7, 7, 7, 9, 9, 9, 9, 7, 7 };
    for (text, hls, 0..) |ch, hl, c| core.grid.putCell(0, @intCast(c), ch, hl);

    try core.initHlCache();
    const hl_cache: []highlight.ResolvedAttrWithStyles = core.hl_cache_buf orelse &.{};
    const hl_valid: []bool = core.hl_valid_buf orelse &.{};
    @memset(hl_valid, false);

    var dst: RenderCells = .{};
    defer dst.deinit(core.alloc);
    try dst.ensureTotalCapacity(core.alloc, cols);
    dst.setLen(cols);

    var hits: u32 = 0;
    var misses: u32 = 0;
    composeRowRuns(
        &core,
        &dst,
        core.grid.main_buf.cells,
        1,
        0,
        cols,
        hl_cache,
        hl_valid,
        @intCast(hl_valid.len),
        false,
        false,
        null,
        true,
        &hits,
        &misses,
    );

    const a7 = core.hl.getWithStyles(7);
    const a9 = core.hl.getWithStyles(9);
    for (0..cols) |i| {
        const expected = if (hls[i] == 7) a7 else a9;
        try std.testing.expectEqual(expected.fg, dst.fg_rgbs.items[i]);
        try std.testing.expectEqual(expected.bg, dst.bg_rgbs.items[i]);
        try std.testing.expectEqual(expected.sp, dst.sp_rgbs.items[i]);
        try std.testing.expectEqual(expected.style_flags, dst.style_flags_arr.items[i]);
        try std.testing.expectEqual(@as(i64, 1), dst.grid_ids.items[i]);
        // Every cell's codepoint must survive the stride-2 extraction.
        try std.testing.expectEqual(@as(u32, text[i]), dst.scalars.items[i]);
    }
    // The two hl ids really do differ, or the loop above proves nothing.
    try std.testing.expect(a7.fg != a9.fg and a7.bg != a9.bg);

    // Three runs: first is a miss, the 6 cells after it hit, hl 9 misses,
    // then hl 7 recurs as a hit. Counted only because count_hl_cache is true.
    try std.testing.expectEqual(@as(u32, 2), misses);
    try std.testing.expectEqual(@as(u32, 1), hits);

    // Glow is opt-in: left alone when disabled, filled when enabled.
    @memset(dst.glow_arr.items[0..cols], 0);
    composeRowRuns(&core, &dst, core.grid.main_buf.cells, 1, 0, cols, hl_cache, hl_valid, @intCast(hl_valid.len), true, true, null, false, &hits, &misses);
    for (0..cols) |i| try std.testing.expectEqual(@as(u8, 1), dst.glow_arr.items[i]);

    // The other glow branch: with glow_all off, only the runs whose hl is in
    // the set light up. hl 7 is in, hl 9 is out, so the answer must differ
    // per run rather than being uniform either way.
    var ids = std.AutoHashMap(u32, void).init(core.alloc);
    defer ids.deinit();
    try ids.put(7, {});
    @memset(dst.glow_arr.items[0..cols], 0xFF);
    composeRowRuns(&core, &dst, core.grid.main_buf.cells, 1, 0, cols, hl_cache, hl_valid, @intCast(hl_valid.len), true, false, &ids, false, &hits, &misses);
    for (0..cols) |i| {
        const expected: u8 = if (hls[i] == 7) 1 else 0;
        try std.testing.expectEqual(expected, dst.glow_arr.items[i]);
    }
}

/// Glyph callbacks that produce a 1x1 opaque glyph for anything asked for.
/// Enough to make the vertex generator emit glyph vertices, which is where
/// DECO_GLOW lands — background quads never carry it.
const StubGlyphCallbacks = struct {
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

    fn install(core: *Core) void {
        core.cb.on_rasterize_glyph = rasterize;
        core.cb.on_atlas_upload = upload;
        core.cb.on_atlas_create = create;
    }
};

/// Foreground colours of the two highlights the glow tests use, as they
/// arrive in a vertex. Distinct so a glyph vertex identifies which cell it
/// came from without decoding its position.
const glow_in_set_fg: u32 = 0xFF0000;
const glow_out_of_set_fg: u32 = 0x00FF00;
const glow_in_set_color = [4]f32{ 1, 0, 0, 1 };
const glow_out_of_set_color = [4]f32{ 0, 1, 0, 1 };

/// Tallies one grid's glyph vertices by which cell they belong to AND whether
/// they carry DECO_GLOW. Counting only "some glowed, some did not" would be
/// symmetric under inversion, so a flipped decision or a swapped destination
/// index would pass; keeping the two cells apart is what makes those fail.
const GlowCounter = struct {
    target_grid: i64,
    in_set_glow: usize = 0,
    in_set_plain: usize = 0,
    out_of_set_glow: usize = 0,
    out_of_set_plain: usize = 0,

    fn count(self: *@This(), verts: ?[*]const c_api.Vertex, vert_count: usize) void {
        const v = verts orelse return;
        for (v[0..vert_count]) |vertex| {
            if (vertex.grid_id != self.target_grid) continue;
            // Background quads use the solid UV slot and never carry glow;
            // counting them would drown the signal.
            if (std.meta.eql(vertex.texCoord, VH.solid_uv)) continue;
            const glowing = vertex.deco_flags & c_api.DECO_GLOW != 0;
            if (std.meta.eql(vertex.color, glow_in_set_color)) {
                if (glowing) self.in_set_glow += 1 else self.in_set_plain += 1;
            } else if (std.meta.eql(vertex.color, glow_out_of_set_color)) {
                if (glowing) self.out_of_set_glow += 1 else self.out_of_set_plain += 1;
            }
        }
    }

    /// With `glow_all` off only the cell whose highlight is in the set glows;
    /// with it on both do. Either way both cells must have been seen, or the
    /// fixture stopped emitting one of them and the rest proves nothing.
    fn expect(self: @This(), glow_all: bool) !void {
        try std.testing.expect(self.in_set_glow > 0);
        try std.testing.expectEqual(@as(usize, 0), self.in_set_plain);
        if (glow_all) {
            try std.testing.expect(self.out_of_set_glow > 0);
            try std.testing.expectEqual(@as(usize, 0), self.out_of_set_plain);
        } else {
            try std.testing.expect(self.out_of_set_plain > 0);
            try std.testing.expectEqual(@as(usize, 0), self.out_of_set_glow);
        }
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
        _ = grid_id;
        _ = row_start;
        _ = row_count;
        _ = flags;
        _ = total_rows;
        _ = total_cols;
        const self: *@This() = @ptrCast(@alignCast(ctx.?));
        self.count(verts, vert_count);
    }
};

/// Define the two glow-test highlights and arm glow. hl 42 is in the set,
/// hl 7 is not; `glow_all` overrides the set and lights both.
fn armGlowForTest(core: *Core, glow_all: bool) !void {
    try core.hl.define(42, glow_in_set_fg, 0, null, false, 0, .{}, false);
    try core.hl.define(7, glow_out_of_set_fg, 0, null, false, 0, .{}, false);
    var ids = std.AutoHashMap(u32, void).init(core.alloc);
    errdefer ids.deinit();
    try ids.put(42, {});
    core.glow_hl_ids = ids;
    core.glow_all = glow_all;
    core.glow_enabled.store(true, .release);
}

test "a main-grid subgrid overlay glows per cell" {
    // The subgrid overlay decides glow per cell, separately from the main-grid
    // run path. Require the decision to follow the cell's own highlight rather
    // than being uniform.
    const Runner = struct {
        fn run(alloc: std.mem.Allocator, glow_all: bool) !GlowCounter {
            var core = Core.initForTest(alloc);
            defer core.deinitForTest();
            try core.grid.resize(1, 4);
            for (0..4) |c| core.grid.putCell(0, @intCast(c), '.', 0);

            // A two-cell window over the main grid: one cell's highlight is in
            // the glow set, the other's is not.
            try core.grid.resizeGrid(2, 1, 2);
            try core.grid.setWinPos(2, 40, 0, 0);
            core.grid.putCellGrid(2, 0, 0, 'G', 42);
            core.grid.putCellGrid(2, 0, 1, 'N', 7);

            core.grid.cursor_visible = false;
            core.drawable_w_px = 4;
            core.drawable_h_px = 1;
            core.cell_w_px = 1;
            core.cell_h_px = 1;
            try armGlowForTest(&core, glow_all);

            var counter = GlowCounter{ .target_grid = 2 };
            core.ctx = &counter;
            core.cb.on_vertices_row = GlowCounter.onRow;
            StubGlyphCallbacks.install(&core);

            var flush_ctx = FlushCtx{ .core = &core };
            try flush_ctx.onFlush(1, 4);
            return counter;
        }
    };

    const alloc = std.testing.allocator;
    for ([_]bool{ false, true }) |glow_all| {
        const counter = try Runner.run(alloc, glow_all);
        try counter.expect(glow_all);
    }
}

test "an external grid and its anchored float glow per cell" {
    // The external-grid path carries its own copy of the decision, once for
    // the grid's own rows and once for a float composited onto it.
    const Runner = struct {
        fn run(alloc: std.mem.Allocator, target: i64, glow_all: bool) !GlowCounter {
            var core = Core.initForTest(alloc);
            defer core.deinitForTest();

            // Four columns so the float can sit beside the grid's own cells
            // rather than covering them.
            try core.grid.resizeGrid(2, 1, 4);
            try core.grid.putSyntheticExternal(2, .{ .win = 42, .start_row = 0, .start_col = 0 });
            core.grid.putCellGrid(2, 0, 0, 'G', 42);
            core.grid.putCellGrid(2, 0, 1, 'N', 7);

            // A float anchored on the external grid, same split.
            try core.grid.resizeGrid(3, 1, 2);
            try core.grid.setWinFloatPos(3, 43, 0, 2, 10, 0, 2, true);
            core.grid.putCellGrid(3, 0, 0, 'G', 42);
            core.grid.putCellGrid(3, 0, 1, 'N', 7);

            core.grid.cursor_visible = false;
            core.cell_w_px = 1;
            core.cell_h_px = 1;
            try armGlowForTest(&core, glow_all);

            var counter = GlowCounter{ .target_grid = target };
            core.ctx = &counter;
            core.cb.on_vertices_row = GlowCounter.onRow;
            StubGlyphCallbacks.install(&core);

            core.sendExternalGridVertices(true);
            return counter;
        }
    };

    const alloc = std.testing.allocator;
    // grid 2 is the external grid's own rows; grid 3 is the float overlay.
    for ([_]i64{ 2, 3 }) |target| {
        for ([_]bool{ false, true }) |glow_all| {
            const counter = try Runner.run(alloc, target, glow_all);
            try counter.expect(glow_all);
        }
    }
}

test "resolveHlCached memoizes below the limit and resolves live above it" {
    // This memo block used to be written out at four call sites, and two of
    // them had already drifted: only the row-mode pair counted hits and
    // misses. With one body the counters are a caller's choice rather than
    // something a copy can forget, so pin both halves of that choice.
    var core = Core.initForTest(std.testing.allocator);
    defer core.deinitForTest();
    core.hl.setDefaults(0x111111, 0x222222, null);
    try core.hl.define(3, 0xAB0000, 0xCD0000, null, false, 0, .{}, false);

    var cache: [4]highlight.ResolvedAttrWithStyles = undefined;
    var valid = [_]bool{false} ** 4;
    const limit: u32 = 4;
    var hits: u32 = 0;
    var misses: u32 = 0;

    // First touch is a miss and fills the slot.
    const first = resolveHlCached(&core, 3, &cache, &valid, limit, true, &hits, &misses);
    try std.testing.expectEqual(@as(u32, 0xAB0000), first.fg);
    try std.testing.expect(valid[3]);
    try std.testing.expectEqual(@as(u32, 1), misses);
    try std.testing.expectEqual(@as(u32, 0), hits);

    // Second touch is served from the slot. Poison the live table first, so a
    // hit is provably reading the memo rather than resolving again.
    try core.hl.define(3, 0xFFFFFF, 0xFFFFFF, null, false, 0, .{}, false);
    const second = resolveHlCached(&core, 3, &cache, &valid, limit, true, &hits, &misses);
    try std.testing.expectEqual(@as(u32, 0xAB0000), second.fg);
    try std.testing.expectEqual(@as(u32, 1), hits);
    try std.testing.expectEqual(@as(u32, 1), misses);

    // Exactly at the limit is the off-by-one that would index one past the
    // end of both arrays. It must take the live path, not the memo path.
    try core.hl.define(limit, 0x00CC00, 0x00DD00, null, false, 0, .{}, false);
    const at_limit = resolveHlCached(&core, limit, &cache, &valid, limit, true, &hits, &misses);
    try std.testing.expectEqual(@as(u32, 0x00CC00), at_limit.fg);
    // A memoized id would have been recorded; this one must not be, so a
    // second call resolves live again rather than reporting a hit.
    const hits_before = hits;
    try core.hl.define(limit, 0x00EE00, 0x00FF00, null, false, 0, .{}, false);
    const at_limit_again = resolveHlCached(&core, limit, &cache, &valid, limit, true, &hits, &misses);
    try std.testing.expectEqual(@as(u32, 0x00EE00), at_limit_again.fg);
    try std.testing.expectEqual(hits_before, hits);

    // Well past the limit: resolve live every time, never index the arrays.
    try core.hl.define(9, 0x0000EE, 0x0000FF, null, false, 0, .{}, false);
    const beyond = resolveHlCached(&core, 9, &cache, &valid, limit, true, &hits, &misses);
    try std.testing.expectEqual(@as(u32, 0x0000EE), beyond.fg);
    try std.testing.expectEqual(@as(u32, 4), misses);
    _ = resolveHlCached(&core, 9, &cache, &valid, limit, true, &hits, &misses);
    try std.testing.expectEqual(@as(u32, 5), misses);
    try std.testing.expectEqual(@as(u32, 1), hits);

    // count = false gives the same answers with no statistics. Reuse a fresh
    // memo so the miss path runs again.
    var valid2 = [_]bool{false} ** 4;
    var unused_hits: u32 = 0;
    var unused_misses: u32 = 0;
    const uncounted = resolveHlCached(&core, 3, &cache, &valid2, limit, false, &unused_hits, &unused_misses);
    try std.testing.expectEqual(@as(u32, 0xFFFFFF), uncounted.fg);
    _ = resolveHlCached(&core, 3, &cache, &valid2, limit, false, &unused_hits, &unused_misses);
    try std.testing.expectEqual(@as(u32, 0), unused_hits);
    try std.testing.expectEqual(@as(u32, 0), unused_misses);
}

/// Recover the emitted corner order of a six-vertex solid quad.
///
/// Returns the index each vertex takes in the quad's four distinct corners,
/// ordered TL, TR, BL, BR. The expected pattern is 0,2,1,1,2,3 -- TL, BL, TR,
/// TR, BL, BR -- which is what every pushSolidQuad body emits. Comparing the
/// pattern rather than raw NDC keeps the assertion independent of cell
/// geometry and line spacing.
fn solidQuadCornerPattern(verts: []const c_api.Vertex) [6]u8 {
    var xs: [2]f32 = .{ verts[0].position[0], verts[0].position[0] };
    var ys: [2]f32 = .{ verts[0].position[1], verts[0].position[1] };
    for (verts) |v| {
        xs[0] = @min(xs[0], v.position[0]);
        xs[1] = @max(xs[1], v.position[0]);
        ys[0] = @min(ys[0], v.position[1]);
        ys[1] = @max(ys[1], v.position[1]);
    }
    var out: [6]u8 = undefined;
    for (verts, 0..) |v, i| {
        // Positions are grid-local pixels with y down, so the larger y is the
        // bottom edge.
        const right: u8 = if (v.position[0] == xs[1]) 1 else 0;
        const bottom: u8 = if (v.position[1] == ys[1]) 1 else 0;
        out[i] = bottom * 2 + right;
    }
    return out;
}

test "the main-grid cursor background is emitted in the shared corner order" {
    // The cursor background was the one solid quad still hand-expanded into
    // six appends, at two sites, and the two had drifted apart. Drive the real
    // main-grid cursor path and pin the order it emits.
    const State = struct {
        cursor: [6]c_api.Vertex = undefined,
        count: usize = 0,

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
            _ = total_rows;
            _ = total_cols;
            if (grid_id != 1 or flags & c_api.VERT_UPDATE_CURSOR == 0) return;
            const v = verts orelse return;
            if (vert_count < 6) return;
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            // The background quad is the first push after the buffer is cleared.
            @memcpy(&self.cursor, v[0..6]);
            self.count = vert_count;
        }
    };

    var core = Core.initForTest(std.testing.allocator);
    defer core.deinitForTest();
    try core.grid.resizeGrid(1, 2, 2);
    core.grid.putCell(0, 0, 'A', 0);
    core.grid.setCursor(1, 0, 0);
    // Deliberately non-square, with a non-square cell: a transposed x/y or
    // width/height argument would preserve the corner ordering and silently
    // move the quad, so the fixture has to be able to tell them apart.
    core.drawable_w_px = 8;
    core.drawable_h_px = 4;
    core.cell_w_px = 4;
    core.cell_h_px = 2;
    var state = State{};
    core.ctx = &state;
    core.cb.on_vertices_row = State.onRow;

    var flush_ctx = FlushCtx{ .core = &core };
    try flush_ctx.onFlush(2, 2);
    try std.testing.expect(state.count >= 6);

    // TL, BL, TR, TR, BL, BR -- the order every pushSolidQuad body emits.
    try std.testing.expectEqualSlices(u8, &.{ 0, 2, 1, 1, 2, 3 }, &solidQuadCornerPattern(&state.cursor));
    // The pattern is blind to placement, so pin the geometry too: a
    // transposed x/y or width/height argument keeps the ordering and moves
    // the quad. Cursor at cell (0,0) with a 4x2 cell, in grid-local pixels.
    try std.testing.expectEqual([2]f32{ 0, 0 }, state.cursor[0].position);
    try std.testing.expectEqual([2]f32{ 4, 2 }, state.cursor[5].position);
    for (state.cursor) |v| {
        try std.testing.expectEqual(VH.solid_uv, v.texCoord);
        try std.testing.expectEqual(c_api.DECO_CURSOR | c_api.DECO_SCROLLABLE, v.deco_flags);
        try std.testing.expectEqual(@as(f32, 0), v.deco_phase);
        try std.testing.expectEqual(state.cursor[0].color, v.color);
    }
}

test "the external-grid cursor background uses the same corner order" {
    // This is the site whose hand-expansion had drifted: it emitted the same
    // two triangles wound the other way. Both backends disable culling, so
    // nothing rendered differently and nothing caught it -- the defect was
    // that the two sites disagreed at all.
    const State = struct {
        cursor: [6]c_api.Vertex = undefined,
        count: usize = 0,

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
            _ = total_rows;
            _ = total_cols;
            if (grid_id != 2 or flags & c_api.VERT_UPDATE_CURSOR == 0) return;
            const v = verts orelse return;
            if (vert_count < 6) return;
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            @memcpy(&self.cursor, v[0..6]);
            self.count = vert_count;
        }
    };

    var core = Core.initForTest(std.testing.allocator);
    defer core.deinitForTest();
    try core.grid.resizeGrid(2, 2, 2);
    core.grid.putCell(0, 0, 'B', 0);
    try core.grid.putSyntheticExternal(2, .{ .win = 2, .start_row = 0, .start_col = 0 });
    core.grid.setCursor(2, 0, 0);
    // Non-square cell, as in the main-grid test: the corner pattern alone
    // cannot tell a transposed width/height argument from the right one.
    core.cell_w_px = 4;
    core.cell_h_px = 2;
    var state = State{};
    core.ctx = &state;
    core.cb.on_vertices_row = State.onRow;

    core.sendExternalGridVertices(true);
    try std.testing.expect(state.count >= 6);

    try std.testing.expectEqualSlices(u8, &.{ 0, 2, 1, 1, 2, 3 }, &solidQuadCornerPattern(&state.cursor));
    try std.testing.expectEqual([2]f32{ 0, 0 }, state.cursor[0].position);
    try std.testing.expectEqual([2]f32{ 4, 2 }, state.cursor[5].position);
    for (state.cursor) |v| {
        try std.testing.expectEqual(VH.solid_uv, v.texCoord);
        try std.testing.expectEqual(c_api.DECO_CURSOR | c_api.DECO_SCROLLABLE, v.deco_flags);
        try std.testing.expectEqual(@as(f32, 0), v.deco_phase);
        try std.testing.expectEqual(state.cursor[0].color, v.color);
    }
}

test "the external-grid cursor glyph uses the same corner order as every other quad" {
    // The cursor background at this site was routed through pushSolidQuad
    // in "refactor(core): route both cursor backgrounds through pushSolidQuad",
    // but the glyph quad directly below it stayed hand-expanded and kept
    // the old winding: TL, TR, BL, TR, BR, BL against everything else's
    // TL, BL, TR, TR, BL, BR. Both backends disable culling -- Windows sets
    // D3D11_CULL_NONE explicitly (d3d11_renderer.zig) and Metal defaults to
    // none -- so nothing rendered differently, which is why it survived. The
    // defect is that one quad in the tree disagrees with the rest.
    const State = struct {
        verts: [12]c_api.Vertex = undefined,
        count: usize = 0,

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
            _ = total_rows;
            _ = total_cols;
            if (grid_id != 2 or flags & c_api.VERT_UPDATE_CURSOR == 0) return;
            const v = verts orelse return;
            if (vert_count < 12) return;
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            @memcpy(&self.verts, v[0..12]);
            self.count = vert_count;
        }
    };

    var core = Core.initForTest(std.testing.allocator);
    defer core.deinitForTest();
    try core.grid.resizeGrid(2, 2, 2);
    // The cell under the cursor must be in grid 2, not the main grid, or there
    // is no glyph to draw and only the background quad is emitted.
    core.grid.putCellGrid(2, 0, 0, 'B', 0);
    try core.grid.putSyntheticExternal(2, .{ .win = 2, .start_row = 0, .start_col = 0 });
    core.grid.setCursor(2, 0, 0);
    core.cell_w_px = 4;
    core.cell_h_px = 2;

    var state = State{};
    core.ctx = &state;
    core.cb.on_vertices_row = State.onRow;
    // The glyph quad is only emitted once a glyph entry exists for the cell.
    StubGlyphCallbacks.install(&core);

    core.sendExternalGridVertices(true);

    // Background quad first, then the glyph quad on top of it.
    try std.testing.expect(state.count >= 12);
    const background = state.verts[0..6];
    const glyph = state.verts[6..12];
    try std.testing.expectEqualSlices(u8, &.{ 0, 2, 1, 1, 2, 3 }, &solidQuadCornerPattern(background));
    try std.testing.expectEqualSlices(u8, &.{ 0, 2, 1, 1, 2, 3 }, &solidQuadCornerPattern(glyph));

    // The two really are different quads, or the assertion above proved
    // nothing about the glyph: the background carries the solid UV slot and
    // the glyph does not.
    try std.testing.expectEqual(VH.solid_uv, background[0].texCoord);
    try std.testing.expect(!std.meta.eql(VH.solid_uv, glyph[0].texCoord));
}

test "VH's two solid-quad variants emit the same corner order" {
    // The file carries three copies of this helper -- VH and one per
    // vertex-generating function -- but the other two are function-local and
    // unreachable from a test. They are covered instead by the two cursor
    // tests above, which drive the real paths. This one pins VH's own pair.
    const alloc = std.testing.allocator;
    var out: std.ArrayListUnmanaged(c_api.Vertex) = .empty;
    defer out.deinit(alloc);
    try out.ensureTotalCapacity(alloc, 12);

    try VH.pushSolidQuad(&out, alloc, 0, 0, 4, 2, .{ 1, 0, 0, 1 }, 1, c_api.DECO_CURSOR);
    VH.pushSolidQuadAssumeCapacity(&out, 0, 0, 4, 2, .{ 1, 0, 0, 1 }, 1, c_api.DECO_CURSOR);
    try std.testing.expectEqual(@as(usize, 12), out.items.len);

    for (0..6) |i| {
        try std.testing.expectEqual(out.items[i], out.items[i + 6]);
    }
    try std.testing.expectEqualSlices(u8, &.{ 0, 2, 1, 1, 2, 3 }, &solidQuadCornerPattern(out.items[0..6]));

    // The pattern is deliberately blind to placement, so pin the geometry too:
    // a transposed x/y argument keeps the ordering and moves the quad. Positions
    // are grid-local pixels with y down, so (0,0)-(4,2) is TL to BR.
    try std.testing.expectEqual([2]f32{ 0, 0 }, out.items[0].position);
    try std.testing.expectEqual([2]f32{ 4, 2 }, out.items[5].position);

    // In grid-local pixels (y down) the first triangle is wound clockwise; the
    // frontend's layer transform negates y, restoring the counter-clockwise NDC
    // winding. Computed from the EMITTED vertices, so it tests what was pushed.
    const a = out.items[0].position;
    const b = out.items[1].position;
    const c = out.items[2].position;
    const cross = (b[0] - a[0]) * (c[1] - b[1]) - (b[1] - a[1]) * (c[0] - b[0]);
    try std.testing.expect(cross < 0);

    for (out.items) |v| {
        try std.testing.expectEqual([4]f32{ 1, 0, 0, 1 }, v.color);
        try std.testing.expectEqual(VH.solid_uv, v.texCoord);
        try std.testing.expectEqual(@as(i64, 1), v.grid_id);
        try std.testing.expectEqual(c_api.DECO_CURSOR, v.deco_flags);
        try std.testing.expectEqual(@as(f32, 0), v.deco_phase);
    }
}

/// Append one line to the msg_show line cache, as buildMsgLineCache would.
fn seedMsgCacheLine(core: *Core, text: []const u8) !void {
    var cached: MsgCachedLine = .{};
    @memcpy(cached.data[0..text.len], text);
    cached.len = @intCast(text.len);
    cached.display_width = @intCast(countDisplayWidth(text));
    try core.msg_line_cache.append(core.alloc, cached);
}

/// One history entry holding a single chunk. The caller owns the entry and
/// must deinit it with the same allocator.
fn makeTestHistoryEntry(core: *Core, text: []const u8) !grid_mod.MsgHistoryEntry {
    var entry: grid_mod.MsgHistoryEntry = .{};
    const owned = try core.alloc.dupe(u8, text);
    errdefer core.alloc.free(owned);
    try entry.content.append(core.alloc, .{ .hl_id = 0, .text = owned });
    return entry;
}

fn panelCols(core: *Core, grid_id: i64) u32 {
    return core.grid.sub_grids.get(grid_id).?.cols;
}

fn panelRows(core: *Core, grid_id: i64) u32 {
    return core.grid.sub_grids.get(grid_id).?.rows;
}

test "both message panels lay out text with one padding column and double-cell wide chars" {
    // Both panels write the same way: column 0 is padding, content starts at
    // column 1, and a wide codepoint consumes two cells so what follows it is
    // pushed one column further right. clearGrid fills with ' ', so the
    // placeholder's cp 0 is distinguishable from an untouched cell.
    var core = Core.initForTest(std.testing.allocator);
    defer core.deinitForTest();
    try core.grid.resize(24, 80);

    const mgid = grid_mod.MESSAGE_GRID_ID;
    try seedMsgCacheLine(&core, "aあb");
    core.msg_cached_max_width = 4;
    try std.testing.expect(renderMsgGridFromCache(&core, 0));

    try std.testing.expectEqual(@as(u32, 6), panelCols(&core, mgid));
    try std.testing.expectEqual(@as(u32, ' '), core.grid.getCellGrid(mgid, 0, 0).cp);
    try std.testing.expectEqual(@as(u32, 'a'), core.grid.getCellGrid(mgid, 0, 1).cp);
    try std.testing.expectEqual(@as(u32, 0x3042), core.grid.getCellGrid(mgid, 0, 2).cp);
    try std.testing.expectEqual(@as(u32, 0), core.grid.getCellGrid(mgid, 0, 3).cp);
    try std.testing.expectEqual(@as(u32, 'b'), core.grid.getCellGrid(mgid, 0, 4).cp);
    try std.testing.expectEqual(@as(u32, ' '), core.grid.getCellGrid(mgid, 0, 5).cp);
    // Both the body and the placeholder are written with hl 0.
    try std.testing.expectEqual(@as(u32, 0), core.grid.getCellGrid(mgid, 0, 2).hl);
    try std.testing.expectEqual(@as(u32, 0), core.grid.getCellGrid(mgid, 0, 3).hl);

    // The history panel writes the identical layout. Its width differs only
    // because its content-width floor is 20 rather than the cached max.
    const hgid = grid_mod.MSG_HISTORY_GRID_ID;
    var entries = [_]grid_mod.MsgHistoryEntry{try makeTestHistoryEntry(&core, "aあb")};
    defer for (&entries) |*e| e.deinit(core.alloc);
    try std.testing.expect(renderMsgHistoryGrid(&core, &entries));

    try std.testing.expectEqual(@as(u32, 22), panelCols(&core, hgid));
    try std.testing.expectEqual(@as(u32, ' '), core.grid.getCellGrid(hgid, 0, 0).cp);
    try std.testing.expectEqual(@as(u32, 'a'), core.grid.getCellGrid(hgid, 0, 1).cp);
    try std.testing.expectEqual(@as(u32, 0x3042), core.grid.getCellGrid(hgid, 0, 2).cp);
    try std.testing.expectEqual(@as(u32, 0), core.grid.getCellGrid(hgid, 0, 3).cp);
    try std.testing.expectEqual(@as(u32, 'b'), core.grid.getCellGrid(hgid, 0, 4).cp);
    try std.testing.expectEqual(@as(u32, 0), core.grid.getCellGrid(hgid, 0, 2).hl);
    try std.testing.expectEqual(@as(u32, 0), core.grid.getCellGrid(hgid, 0, 3).hl);
}

test "both message panels write each line to its own row" {
    // Every other fixture here is single-row, which would let a shared
    // per-line helper drop its row argument and collapse the whole panel
    // onto row 0.
    var core = Core.initForTest(std.testing.allocator);
    defer core.deinitForTest();
    try core.grid.resize(24, 80);

    const mgid = grid_mod.MESSAGE_GRID_ID;
    try seedMsgCacheLine(&core, "ab");
    try seedMsgCacheLine(&core, "cd");
    core.msg_cached_max_width = 2;
    try std.testing.expect(renderMsgGridFromCache(&core, 0));

    try std.testing.expectEqual(@as(u32, 2), panelRows(&core, mgid));
    try std.testing.expectEqual(@as(u32, 'a'), core.grid.getCellGrid(mgid, 0, 1).cp);
    try std.testing.expectEqual(@as(u32, 'c'), core.grid.getCellGrid(mgid, 1, 1).cp);
    try std.testing.expectEqual(@as(u32, 'd'), core.grid.getCellGrid(mgid, 1, 2).cp);

    const hgid = grid_mod.MSG_HISTORY_GRID_ID;
    var entries = [_]grid_mod.MsgHistoryEntry{
        try makeTestHistoryEntry(&core, "ab"),
        try makeTestHistoryEntry(&core, "cd"),
    };
    defer for (&entries) |*e| e.deinit(core.alloc);
    try std.testing.expect(renderMsgHistoryGrid(&core, &entries));

    try std.testing.expectEqual(@as(u32, 2), panelRows(&core, hgid));
    try std.testing.expectEqual(@as(u32, 'a'), core.grid.getCellGrid(hgid, 0, 1).cp);
    try std.testing.expectEqual(@as(u32, 'c'), core.grid.getCellGrid(hgid, 1, 1).cp);
    try std.testing.expectEqual(@as(u32, 'd'), core.grid.getCellGrid(hgid, 1, 2).cp);
}

test "a message panel re-render clears what the previous render left behind" {
    // resizeGrid keeps the overlapping region when the shape does not change,
    // so the clear after it is what stops a shorter line from inheriting the
    // tail of a longer one.
    var core = Core.initForTest(std.testing.allocator);
    defer core.deinitForTest();
    try core.grid.resize(24, 80);

    const mgid = grid_mod.MESSAGE_GRID_ID;
    core.msg_cached_max_width = 4;
    try seedMsgCacheLine(&core, "abcd");
    try std.testing.expect(renderMsgGridFromCache(&core, 0));
    try std.testing.expectEqual(@as(u32, 'd'), core.grid.getCellGrid(mgid, 0, 4).cp);

    // Same width, so the grid is not reshaped and nothing is memset for us.
    core.msg_line_cache.clearRetainingCapacity();
    try seedMsgCacheLine(&core, "a");
    try std.testing.expect(renderMsgGridFromCache(&core, 0));

    try std.testing.expectEqual(@as(u32, 6), panelCols(&core, mgid));
    try std.testing.expectEqual(@as(u32, 'a'), core.grid.getCellGrid(mgid, 0, 1).cp);
    for (2..5) |col| {
        try std.testing.expectEqual(@as(u32, ' '), core.grid.getCellGrid(mgid, 0, @intCast(col)).cp);
    }

    // The history panel's width is derived from its content, so both renders
    // are kept under its floor of 20 to hold the shape constant.
    const hgid = grid_mod.MSG_HISTORY_GRID_ID;
    var long_entries = [_]grid_mod.MsgHistoryEntry{try makeTestHistoryEntry(&core, "abcd")};
    defer for (&long_entries) |*e| e.deinit(core.alloc);
    try std.testing.expect(renderMsgHistoryGrid(&core, &long_entries));
    try std.testing.expectEqual(@as(u32, 'd'), core.grid.getCellGrid(hgid, 0, 4).cp);

    var short_entries = [_]grid_mod.MsgHistoryEntry{try makeTestHistoryEntry(&core, "a")};
    defer for (&short_entries) |*e| e.deinit(core.alloc);
    try std.testing.expect(renderMsgHistoryGrid(&core, &short_entries));

    try std.testing.expectEqual(@as(u32, 22), panelCols(&core, hgid));
    try std.testing.expectEqual(@as(u32, 'a'), core.grid.getCellGrid(hgid, 0, 1).cp);
    for (2..5) |col| {
        try std.testing.expectEqual(@as(u32, ' '), core.grid.getCellGrid(hgid, 0, @intCast(col)).cp);
    }
}

test "only the history panel aborts the flush when registration fails" {
    // The two panels share the registration call but not its failure policy:
    // history marks the flush aborted, msg leaves that to its callers. A
    // shared registration helper must not unify the two.
    var core = Core.initForTest(std.testing.allocator);
    defer core.deinitForTest();
    try core.grid.resize(24, 80);

    // Saturate the placement budget so putSyntheticExternal fails for any new
    // grid id, without depending on allocation-failure injection.
    var filler_id: i64 = 1000;
    while (core.grid.external_grids.count() < grid_mod.MAX_WINDOW_PLACEMENTS) : (filler_id += 1) {
        try core.grid.external_grids.put(core.alloc, filler_id, .{ .win = 1, .start_row = 0, .start_col = 0 });
    }

    try seedMsgCacheLine(&core, "hello");
    core.msg_cached_max_width = 5;
    const mgid = grid_mod.MESSAGE_GRID_ID;
    try std.testing.expect(!renderMsgGridFromCache(&core, 0));
    try std.testing.expect(!core.flush_aborted);
    // The grid was resized and written before the failure, so what failed is
    // the registration and nothing earlier.
    try std.testing.expectEqual(@as(u32, 7), panelCols(&core, mgid));
    try std.testing.expect(core.grid.external_grids.get(mgid) == null);

    var entries = [_]grid_mod.MsgHistoryEntry{try makeTestHistoryEntry(&core, "hello")};
    defer for (&entries) |*e| e.deinit(core.alloc);
    try std.testing.expect(!renderMsgHistoryGrid(&core, &entries));
    try std.testing.expect(core.flush_aborted);
    try std.testing.expect(core.grid.external_grids.get(grid_mod.MSG_HISTORY_GRID_ID) == null);
}

test "a wide char on the last usable column writes its body without the placeholder" {
    // The inner guard breaks after the body cell, so the wide glyph overhangs
    // the right padding column with no cell reserved for its second half, and
    // everything after it is dropped.
    var core = Core.initForTest(std.testing.allocator);
    defer core.deinitForTest();
    try core.grid.resize(24, 80);

    const mgid = grid_mod.MESSAGE_GRID_ID;
    try seedMsgCacheLine(&core, "aaaあz");
    core.msg_cached_max_width = 4;
    try std.testing.expect(renderMsgGridFromCache(&core, 0));

    try std.testing.expectEqual(@as(u32, 6), panelCols(&core, mgid));
    try std.testing.expectEqual(@as(u32, 0x3042), core.grid.getCellGrid(mgid, 0, 4).cp);
    // Still the cleared space: no placeholder was written for the second half.
    try std.testing.expectEqual(@as(u32, ' '), core.grid.getCellGrid(mgid, 0, 5).cp);
    // 'z' never fits, on any column.
    for (0..6) |col| {
        try std.testing.expect(core.grid.getCellGrid(mgid, 0, @intCast(col)).cp != 'z');
    }

    // Same edge on the history panel, reachable only at the 80-column cap:
    // 77 narrow columns, then a wide char whose body lands on the last usable
    // column. This is the guard that distinguishes the current loop from
    // writeUtf8ToGrid, which would drop the whole cluster instead.
    const hgid = grid_mod.MSG_HISTORY_GRID_ID;
    var long_line: [81]u8 = undefined;
    @memset(long_line[0..77], 'a');
    @memcpy(long_line[77..80], "あ");
    long_line[80] = 'z';
    var entries = [_]grid_mod.MsgHistoryEntry{try makeTestHistoryEntry(&core, &long_line)};
    defer for (&entries) |*e| e.deinit(core.alloc);
    try std.testing.expect(renderMsgHistoryGrid(&core, &entries));

    try std.testing.expectEqual(@as(u32, 80), panelCols(&core, hgid));
    try std.testing.expectEqual(@as(u32, 0x3042), core.grid.getCellGrid(hgid, 0, 78).cp);
    try std.testing.expectEqual(@as(u32, ' '), core.grid.getCellGrid(hgid, 0, 79).cp);
    for (0..80) |col| {
        try std.testing.expect(core.grid.getCellGrid(hgid, 0, @intCast(col)).cp != 'z');
    }
}

test "both message panels stop writing at the last usable column" {
    // The right padding column is never written. Each panel is filled to its
    // own edge, since their widths are derived differently, and the trailing
    // 'z' must be dropped in both.
    var core = Core.initForTest(std.testing.allocator);
    defer core.deinitForTest();
    try core.grid.resize(24, 80);

    const mgid = grid_mod.MESSAGE_GRID_ID;
    try seedMsgCacheLine(&core, "abcdz");
    core.msg_cached_max_width = 4;
    try std.testing.expect(renderMsgGridFromCache(&core, 0));

    try std.testing.expectEqual(@as(u32, 6), panelCols(&core, mgid));
    try std.testing.expectEqual(@as(u32, 'd'), core.grid.getCellGrid(mgid, 0, 4).cp);
    try std.testing.expectEqual(@as(u32, ' '), core.grid.getCellGrid(mgid, 0, 5).cp);

    // The history panel's floor is 20, so its edge is only reachable at the
    // 80-column cap: 78 columns of content, then one codepoint too many.
    const hgid = grid_mod.MSG_HISTORY_GRID_ID;
    var long_line: [79]u8 = undefined;
    @memset(long_line[0..78], 'a');
    long_line[78] = 'z';
    var entries = [_]grid_mod.MsgHistoryEntry{try makeTestHistoryEntry(&core, &long_line)};
    defer for (&entries) |*e| e.deinit(core.alloc);
    try std.testing.expect(renderMsgHistoryGrid(&core, &entries));

    try std.testing.expectEqual(@as(u32, 80), panelCols(&core, hgid));
    try std.testing.expectEqual(@as(u32, 'a'), core.grid.getCellGrid(hgid, 0, 78).cp);
    try std.testing.expectEqual(@as(u32, ' '), core.grid.getCellGrid(hgid, 0, 79).cp);
}

test "the message panel width adds a padding column per side and caps at 80" {
    // width is content + 2, capped at 80. A content width of 0 is not
    // reachable through buildMsgLineCache, which floors the cached width at
    // 10; it is set directly here to pin the formula's lower bound, which a
    // shared helper could otherwise clamp differently.
    var core = Core.initForTest(std.testing.allocator);
    defer core.deinitForTest();
    try core.grid.resize(24, 80);

    const mgid = grid_mod.MESSAGE_GRID_ID;
    try seedMsgCacheLine(&core, "");
    core.msg_cached_max_width = 0;
    try std.testing.expect(renderMsgGridFromCache(&core, 0));
    try std.testing.expectEqual(@as(u32, 2), panelCols(&core, mgid));

    core.msg_cached_max_width = 200;
    try std.testing.expect(renderMsgGridFromCache(&core, 0));
    try std.testing.expectEqual(@as(u32, 80), panelCols(&core, mgid));
}

test "both message panels register with the top-right placement sentinel" {
    // -2 in both position fields is what the core registers a message panel
    // with. The frontends select top-right placement by grid id rather than
    // by this value, but they do rely on it being negative.
    var core = Core.initForTest(std.testing.allocator);
    defer core.deinitForTest();
    try core.grid.resize(24, 80);

    try seedMsgCacheLine(&core, "hello");
    core.msg_cached_max_width = 5;
    try std.testing.expect(renderMsgGridFromCache(&core, 0));

    var entries = [_]grid_mod.MsgHistoryEntry{try makeTestHistoryEntry(&core, "hello")};
    defer for (&entries) |*e| e.deinit(core.alloc);
    try std.testing.expect(renderMsgHistoryGrid(&core, &entries));

    for ([_]i64{ grid_mod.MESSAGE_GRID_ID, grid_mod.MSG_HISTORY_GRID_ID }) |gid| {
        const info = core.grid.external_grids.get(gid).?;
        try std.testing.expectEqual(@as(i64, 1), info.win);
        try std.testing.expectEqual(@as(i32, -2), info.start_row);
        try std.testing.expectEqual(@as(i32, -2), info.start_col);
    }
}

test "replaceGridSurfaceRowVertexCount keeps grid 1 and a sub-grid on one ledger path" {
    var core = Core.initForTest(std.testing.allocator);
    defer core.deinitForTest();
    try core.grid.resize(2, 4);
    try core.grid.resizeGrid(2, 2, 4);

    try beginVertexBudgetTransaction(&core);
    defer finishVertexBudgetTransaction(&core, true);

    const main = core.grid.bufFor(1).?;
    try replaceGridSurfaceRowVertexCount(&core, 1, main, 0, 12);
    try std.testing.expectEqual(@as(usize, 12), main.surface_vertex_count);
    try std.testing.expectEqual(@as(usize, 12), main.vertex_row_counts[0]);
    try std.testing.expectEqual(@as(usize, 12), core.flush_vertex_count_aggregate);
    // Grid 1 is not a standalone sub-grid surface.
    try std.testing.expectEqual(@as(usize, 0), core.grid.subgrid_surface_vertex_count);

    const sub = core.grid.bufFor(2).?;
    try replaceGridSurfaceRowVertexCount(&core, 2, sub, 1, 30);
    try std.testing.expectEqual(@as(usize, 30), sub.surface_vertex_count);
    try std.testing.expectEqual(@as(usize, 30), core.grid.subgrid_surface_vertex_count);
    try std.testing.expectEqual(@as(usize, 42), core.flush_vertex_count_aggregate);

    // Replacing a row's count swaps its contribution, it does not add to it.
    try replaceGridSurfaceRowVertexCount(&core, 1, main, 0, 4);
    try std.testing.expectEqual(@as(usize, 4), main.surface_vertex_count);
    try std.testing.expectEqual(@as(usize, 34), core.flush_vertex_count_aggregate);
    try std.testing.expectEqual(@as(usize, 30), core.grid.subgrid_surface_vertex_count);

    // Grid 1 is never threaded onto the touched list: that list is resolved
    // through sub_grids, which does not contain it.
    try std.testing.expect(main.vertex_budget_touched);
    var head = core.vertex_budget_touched_grid_head;
    while (head) |id| {
        try std.testing.expect(id != 1);
        head = core.grid.sub_grids.getPtr(id).?.vertex_budget_touched_next;
    }
    try validateCompletedVertexBudget(&core);
}

test "render trace is verbose-only and preserves abort destruction retry ordering" {
    const State = struct {
        core: *Core,
        reject: bool = true,
        bytes: [32768]u8 = undefined,
        len: usize = 0,
        fn onLog(ctx: ?*anyopaque, ptr: [*]const u8, len: usize) callconv(.c) void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            const message = ptr[0..len];
            if (!std.mem.startsWith(u8, message, "[render_trace]")) return;
            const count = @min(len, self.bytes.len - self.len);
            @memcpy(self.bytes[self.len..][0..count], message[0..count]);
            self.len += count;
        }
        fn onEnd(ctx: ?*anyopaque) callconv(.c) void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            if (self.reject) self.core.flush_aborted = true;
        }
        fn onDestroy(_: ?*anyopaque, _: i64) callconv(.c) void {}
    };
    var core = Core.initForTest(std.testing.allocator);
    defer core.deinitForTest();
    var state = State{ .core = &core };
    core.log.cb = State.onLog;
    core.log.ctx = &state;
    traceRender(&core, "event=probe\n", .{});
    try std.testing.expectEqual(@as(usize, 0), state.len);
    core.log.verbose = true;
    core.log.perf_only = true;
    traceRender(&core, "event=probe\n", .{});
    core.log.perf_only = false;
    core.log.scroll_only = true;
    traceRender(&core, "event=probe\n", .{});
    try std.testing.expectEqual(@as(usize, 0), state.len);
    core.log.scroll_only = false;
    core.ctx = &state;
    core.cb.on_flush_end = State.onEnd;
    core.cb.on_grid_destroy = State.onDestroy;
    try core.grid.resize(2, 3);
    try core.grid.resizeGrid(2, 1, 1);
    try core.grid.destroyGrid(2);
    var ctx = FlushCtx{ .core = &core };
    try ctx.onFlush(2, 3);
    const aborted = state.bytes[0..state.len];
    try std.testing.expect(std.mem.indexOf(u8, aborted, "event=destroy_stage grid=2") != null);
    try std.testing.expect(std.mem.indexOf(u8, aborted, "outcome=abort") != null);
    try std.testing.expect(std.mem.indexOf(u8, aborted, "event=destroy_release") == null);
    state.len = 0;
    state.reject = false;
    try ctx.onFlush(2, 3);
    const committed = state.bytes[0..state.len];
    const stage = std.mem.indexOf(u8, committed, "event=destroy_stage grid=2").?;
    const end = std.mem.indexOf(u8, committed, "outcome=commit").?;
    const release = std.mem.indexOf(u8, committed, "event=destroy_release grid=2").?;
    try std.testing.expect(stage < end and end < release);
    try std.testing.expect(std.mem.indexOf(u8, committed, "metadata_limit_bytes=8388608") != null);
}

test "surface layout publishes one root layer per surface and only when it changes" {
    const State = struct {
        calls: u32 = 0,
        last_surface: i64 = 0,
        last_count: usize = 0,
        last_layer: c_api.Layer = undefined,
        destroyed: [8]i64 = undefined,
        destroyed_count: usize = 0,

        fn onLayout(
            ctx: ?*anyopaque,
            surface_id: i64,
            layers: [*]const c_api.Layer,
            count: usize,
            surface_rows: u32,
            surface_cols: u32,
        ) callconv(.c) void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            self.calls += 1;
            self.last_surface = surface_id;
            self.last_count = count;
            if (count != 0) self.last_layer = layers[0];
            std.debug.assert(surface_rows == layers[0].rows);
            std.debug.assert(surface_cols == layers[0].cols);
        }

        fn onDestroy(ctx: ?*anyopaque, grid_id: i64) callconv(.c) void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            if (self.destroyed_count < self.destroyed.len) {
                self.destroyed[self.destroyed_count] = grid_id;
                self.destroyed_count += 1;
            }
        }
    };

    var core = Core.initForTest(std.testing.allocator);
    defer core.deinitForTest();
    try core.grid.resize(4, 8);

    var state = State{};
    core.ctx = &state;
    core.cb.on_surface_layout = State.onLayout;
    core.cb.on_grid_destroy = State.onDestroy;

    // The main surface publishes its root grid at the surface origin.
    notifySurfaceLayouts(&core);
    try std.testing.expectEqual(@as(u32, 1), state.calls);
    try std.testing.expectEqual(@as(i64, 1), state.last_surface);
    try std.testing.expectEqual(@as(usize, 1), state.last_count);
    try std.testing.expectEqual(@as(i64, 1), state.last_layer.grid_id);
    try std.testing.expectEqual(@as(i64, 1), state.last_layer.anchor_grid);
    try std.testing.expectEqual(@as(i32, 0), state.last_layer.x_px);
    try std.testing.expectEqual(@as(i32, 0), state.last_layer.y_px);
    try std.testing.expectEqual(@as(i32, 0), state.last_layer.z);
    try std.testing.expectEqual(@as(u32, 4), state.last_layer.rows);
    try std.testing.expectEqual(@as(u32, 8), state.last_layer.cols);

    // An unchanged layout is not republished.
    notifySurfaceLayouts(&core);
    try std.testing.expectEqual(@as(u32, 1), state.calls);

    // A root resize is a change.
    try core.grid.resize(5, 8);
    notifySurfaceLayouts(&core);
    try std.testing.expectEqual(@as(u32, 2), state.calls);
    try std.testing.expectEqual(@as(u32, 5), state.last_layer.rows);

    // An external grid becomes its own surface with its own root layer.
    try core.grid.resizeGrid(2, 3, 6);
    try std.testing.expect(try core.grid.setWinExternalPos(2, 42));
    notifySurfaceLayouts(&core);
    try std.testing.expectEqual(@as(u32, 3), state.calls);
    try std.testing.expectEqual(@as(i64, 2), state.last_surface);
    try std.testing.expectEqual(@as(i64, 2), state.last_layer.grid_id);
    try std.testing.expectEqual(@as(u32, 3), state.last_layer.rows);
    try std.testing.expectEqual(@as(u32, 6), state.last_layer.cols);

    // Destroying it drains into on_grid_destroy exactly once.
    try core.grid.destroyGrid(2);
    notifySurfaceLayouts(&core);
    try std.testing.expectEqual(@as(usize, 1), state.destroyed_count);
    try std.testing.expectEqual(@as(i64, 2), state.destroyed[0]);
    notifySurfaceLayouts(&core);
    try std.testing.expectEqual(@as(usize, 1), state.destroyed_count);
}

test "a surface layout waits for the external window that receives it" {
    const State = struct {
        layouts: u32 = 0,
        opens: u32 = 0,
        saw_layout_for_2: bool = false,

        fn onLayout(
            ctx: ?*anyopaque,
            surface_id: i64,
            layers: [*]const c_api.Layer,
            count: usize,
            surface_rows: u32,
            surface_cols: u32,
        ) callconv(.c) void {
            _ = layers;
            _ = count;
            _ = surface_rows;
            _ = surface_cols;
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            self.layouts += 1;
            if (surface_id == 2) self.saw_layout_for_2 = true;
        }

        fn onOpen(
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
            self.opens += 1;
        }
    };

    var core = Core.initForTest(std.testing.allocator);
    defer core.deinitForTest();
    try core.grid.resize(4, 8);

    var state = State{};
    core.ctx = &state;
    core.cb.on_surface_layout = State.onLayout;
    core.cb.on_external_window = State.onOpen;

    // Neovim proposed a one-row window, so the core asked for a usable size
    // and parked the grid until that resize lands.
    try core.grid.resizeGrid(2, 1, 6);
    try std.testing.expect(try core.grid.setWinExternalPos(2, 42));
    try core.grid.pending_ext_window_grids.put(core.alloc, 2, .{ .grid_id = 2, .width = 6, .height = 4 });

    _ = notifyExternalWindowChanges(&core);
    notifySurfaceLayouts(&core);
    // Only the main surface: a layout for a surface the frontend has never
    // been told to create aborts the flush there and retries forever.
    try std.testing.expectEqual(@as(u32, 0), state.opens);
    try std.testing.expectEqual(@as(u32, 1), state.layouts);
    try std.testing.expect(!state.saw_layout_for_2);

    // The requested resize lands: the open goes out first, then the layout.
    try core.grid.resizeGrid(2, 4, 6);
    _ = notifyExternalWindowChanges(&core);
    try std.testing.expectEqual(@as(u32, 1), state.opens);
    notifySurfaceLayouts(&core);
    try std.testing.expect(state.saw_layout_for_2);
}

test "an external row rejection owes the main grid only the rows it consumed" {
    const ROWS: u32 = 4;
    const COLS: u32 = 4;
    const State = struct {
        core: *Core,
        reject_external: bool = false,
        external_rows: u32 = 0,

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
            if (grid_id == 1) return;
            self.external_rows += 1;
            // The external surface runs out of row storage after the main
            // grid already published and cleared its dirty rows.
            if (self.reject_external) self.core.flush_aborted = true;
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
    try core.grid.resizeGrid(1, ROWS, COLS);
    try core.grid.resizeGrid(2, ROWS, COLS);
    try std.testing.expect(try core.grid.setWinExternalPos(2, 42));
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
        for (0..COLS) |cc| {
            core.grid.putCell(@intCast(r), @intCast(cc), 'A', 0);
            core.grid.putCellGrid(2, @intCast(r), @intCast(cc), 'A', 0);
        }
    }

    var state = State{ .core = &core };
    core.ctx = &state;
    core.cb.on_vertices_row = State.onRow;
    core.cb.on_rasterize_glyph = State.rasterize;
    core.cb.on_atlas_upload = State.upload;
    core.cb.on_atlas_create = State.create;

    // Settle dirty_all so the next attempt owes a single row, not the viewport.
    var flush_ctx = FlushCtx{ .core = &core };
    try flush_ctx.onFlush(ROWS, COLS);
    try flush_ctx.onFlush(ROWS, COLS);
    try std.testing.expect(!core.grid.main_buf.dirty_all);

    core.grid.putCell(1, 0, 'B', 0);
    try std.testing.expect(core.grid.main_buf.dirty_rows.isSet(1));
    // Give the external surface something to publish, so the rejection lands
    // after the main rows were consumed rather than never firing.
    core.grid.putCellGrid(2, 1, 0, 'B', 0);

    state.reject_external = true;
    state.external_rows = 0;
    try flush_ctx.onFlush(ROWS, COLS);
    // Without this the flush committed and the assertions below would pass
    // for the wrong reason.
    try std.testing.expect(state.external_rows != 0);

    // The frontend keeps its committed frame, so the retry owes row 1 only.
    try std.testing.expect(!core.grid.main_buf.dirty_all);
    try std.testing.expect(core.grid.main_buf.dirty_rows.isSet(1));
    try std.testing.expect(!core.grid.main_buf.dirty_rows.isSet(0));
    try std.testing.expect(!core.grid.main_buf.dirty_rows.isSet(2));
    try std.testing.expect(!core.grid.main_buf.dirty_rows.isSet(3));
}

test "a destroyed grid retains its glyph mirror and retries destruction until flush commit" {
    const State = struct {
        core: *Core,
        destroyed: [4]i64 = @splat(0),
        destroyed_count: usize = 0,
        mirror_live_at_destroy: bool = false,
        reject: bool = true,

        fn onFlushEnd(ctx: ?*anyopaque) callconv(.c) void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            if (self.reject) self.core.flush_aborted = true;
        }

        fn onDestroy(ctx: ?*anyopaque, grid_id: i64) callconv(.c) void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            if (self.core.glyph_mirror.contains(grid_id)) self.mirror_live_at_destroy = true;
            if (self.destroyed_count < self.destroyed.len) {
                self.destroyed[self.destroyed_count] = grid_id;
                self.destroyed_count += 1;
            }
        }
    };

    var core = Core.initForTest(std.testing.allocator);
    defer core.deinitForTest();
    try core.grid.resize(10, 20);
    try core.grid.resizeGrid(2, 10, 20);
    try core.grid.setWinPos(2, 101, 0, 0);

    var state = State{ .core = &core };
    core.ctx = &state;
    core.cb.on_grid_destroy = State.onDestroy;

    // One row the grid is showing, recorded the way a generated row records it.
    core.cb.on_flush_end = State.onFlushEnd;
    const verts = [_]c_api.Vertex{.{
        .position = .{ 0, 0 },
        .texCoord = .{ 0.5, 0.25 },
        .color = .{ 0, 0, 0, 0 },
        .grid_id = 2,
        .deco_flags = 0,
        .deco_phase = 0,
    }};
    core.recordGlyphMirrorRow(2, 0, 10, &verts);
    try std.testing.expect(core.glyph_mirror.contains(2));

    try core.grid.destroyGrid(2);
    var flush_ctx = FlushCtx{ .core = &core };
    try flush_ctx.onFlush(10, 20);

    try std.testing.expectEqual(@as(usize, 1), state.destroyed_count);
    try std.testing.expectEqual(@as(i64, 2), state.destroyed[0]);
    try std.testing.expect(state.mirror_live_at_destroy);
    try std.testing.expect(core.glyph_mirror.contains(2));
    try std.testing.expectEqual(@as(usize, 1), core.grid.destroyed_pending.items.len);

    state.reject = false;
    try flush_ctx.onFlush(10, 20);
    try std.testing.expectEqual(@as(usize, 2), state.destroyed_count);
    try std.testing.expectEqual(@as(i64, 2), state.destroyed[1]);
    try std.testing.expect(!core.glyph_mirror.contains(2));
    try std.testing.expectEqual(@as(usize, 0), core.grid.destroyed_pending.items.len);
    try flush_ctx.onFlush(10, 20);
    try std.testing.expectEqual(@as(usize, 2), state.destroyed_count);
}

test "an aborted flush owes the surface layout again" {
    const State = struct {
        core: *Core = undefined,
        calls: u32 = 0,
        abort_on_call: u32 = 1,

        fn onLayout(
            ctx: ?*anyopaque,
            surface_id: i64,
            layers: [*]const c_api.Layer,
            count: usize,
            surface_rows: u32,
            surface_cols: u32,
        ) callconv(.c) void {
            _ = surface_id;
            _ = layers;
            _ = count;
            _ = surface_rows;
            _ = surface_cols;
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            self.calls += 1;
            if (self.calls == self.abort_on_call) self.core.flush_aborted = true;
        }
    };

    var core = Core.initForTest(std.testing.allocator);
    defer core.deinitForTest();
    try core.grid.resize(4, 8);

    var state = State{ .core = &core };
    core.ctx = &state;
    core.cb.on_surface_layout = State.onLayout;

    notifySurfaceLayouts(&core);
    try std.testing.expectEqual(@as(u32, 1), state.calls);
    try std.testing.expect(core.flush_aborted);

    // The signature was not recorded, so the retry republishes the same layout.
    core.flush_aborted = false;
    notifySurfaceLayouts(&core);
    try std.testing.expectEqual(@as(u32, 2), state.calls);
}

test "an abort after the layout callback owes the surface layout again" {
    const State = struct {
        core: *Core = undefined,
        layout_calls: u32 = 0,
        flush_ends: u32 = 0,

        fn onLayout(
            ctx: ?*anyopaque,
            surface_id: i64,
            layers: [*]const c_api.Layer,
            count: usize,
            surface_rows: u32,
            surface_cols: u32,
        ) callconv(.c) void {
            _ = surface_id;
            _ = layers;
            _ = count;
            _ = surface_rows;
            _ = surface_cols;
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            self.layout_calls += 1;
        }

        // The frontend rejects the bracket only after notifySurfaceLayouts
        // already published and recorded the layout.
        fn onFlushEnd(ctx: ?*anyopaque) callconv(.c) void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            self.flush_ends += 1;
            if (self.flush_ends == 1) self.core.flush_aborted = true;
        }
    };

    var core = Core.initForTest(std.testing.allocator);
    defer core.deinitForTest();
    try core.grid.resize(4, 8);

    var state = State{ .core = &core };
    core.ctx = &state;
    core.cb.on_surface_layout = State.onLayout;
    core.cb.on_flush_end = State.onFlushEnd;

    var flush_ctx = FlushCtx{ .core = &core };
    try flush_ctx.onFlush(4, 8);
    try std.testing.expectEqual(@as(u32, 1), state.layout_calls);

    // The cancelled transaction carried that layout, so the retry owes it.
    try flush_ctx.onFlush(4, 8);
    try std.testing.expectEqual(@as(u32, 2), state.layout_calls);
}

test "surface layout retains all grids beyond the former 64 layer limit" {
    const State = struct {
        count: usize = 0,
        first: i64 = 0,
        last: i64 = 0,
        fn onLayout(ctx: ?*anyopaque, _: i64, layers: [*]const c_api.Layer, count: usize, _: u32, _: u32) callconv(.c) void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            self.count = count;
            self.first = layers[1].grid_id;
            self.last = layers[count - 1].grid_id;
        }
    };
    var core = Core.initForTest(std.testing.allocator);
    defer core.deinitForTest();
    try core.grid.resize(10, 20);
    var state = State{};
    core.ctx = &state;
    core.cb.on_surface_layout = State.onLayout;
    for (2..129) |id| {
        const gid: i64 = @intCast(id);
        try core.grid.resizeGrid(gid, 1, 1);
        try core.grid.setWinFloatPos(gid, gid + 100, 0, 0, @intCast(id), 0, 1, true);
        if (id == 63 or id == 64 or id == 65 or id == 128) {
            notifySurfaceLayouts(&core);
            try std.testing.expect(!core.flush_aborted);
            try std.testing.expectEqual(id, state.count);
            try std.testing.expectEqual(@as(i64, 2), state.first);
            try std.testing.expectEqual(gid, state.last);
        }
    }
}

test "an external surface publishes its root and anchored float layers" {
    const State = struct {
        seen_ext: bool = false,
        count: usize = 0,
        root: c_api.Layer = undefined,
        child: c_api.Layer = undefined,

        fn onLayout(
            ctx: ?*anyopaque,
            surface_id: i64,
            layers: [*]const c_api.Layer,
            count: usize,
            surface_rows: u32,
            surface_cols: u32,
        ) callconv(.c) void {
            _ = surface_rows;
            _ = surface_cols;
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            if (surface_id == 1) return;
            self.seen_ext = true;
            self.count = count;
            self.root = layers[0];
            if (count > 1) self.child = layers[1];
        }
    };

    var core = Core.initForTest(std.testing.allocator);
    defer core.deinitForTest();
    core.cell_w_px = 10;
    core.cell_h_px = 20;
    try core.grid.resize(10, 40);

    var state = State{};
    core.ctx = &state;
    core.cb.on_surface_layout = State.onLayout;

    try core.grid.resizeGrid(2, 5, 20);
    try std.testing.expect(try core.grid.setWinExternalPosAt(2, 42, 4, 8));
    // Float content is independent of its external anchor's row contents.
    try core.grid.resizeGrid(3, 2, 4);
    try core.grid.setWinFloatPos(3, 43, 6, 11, 50, 0, 2, true);

    notifySurfaceLayouts(&core);
    try std.testing.expect(state.seen_ext);
    try std.testing.expectEqual(@as(usize, 2), state.count);
    try std.testing.expectEqual(@as(i64, 2), state.root.grid_id);
    try std.testing.expectEqual(@as(i32, 0), state.root.x_px);
    try std.testing.expectEqual(@as(i32, 0), state.root.y_px);
    try std.testing.expectEqual(@as(u32, 5), state.root.rows);
    try std.testing.expectEqual(@as(u32, 20), state.root.cols);
    try std.testing.expectEqual(@as(i64, 3), state.child.grid_id);
    try std.testing.expectEqual(@as(i64, 2), state.child.anchor_grid);
    try std.testing.expectEqual(@as(i32, 30), state.child.x_px);
    try std.testing.expectEqual(@as(i32, 40), state.child.y_px);
    try std.testing.expectEqual(@as(u32, 2), state.child.rows);
    try std.testing.expectEqual(@as(u32, 4), state.child.cols);
}

test "surface ownership follows nested anchors and rejects unresolved or cyclic chains" {
    var core = Core.initForTest(std.testing.allocator);
    defer core.deinitForTest();
    try core.grid.resize(10, 40);
    try core.grid.resizeGrid(2, 5, 20);
    try std.testing.expect(try core.grid.setWinExternalPos(2, 42));
    try core.grid.resizeGrid(3, 2, 4);
    try core.grid.setWinFloatPos(3, 43, 1, 2, 50, 0, 2, true);
    try core.grid.resizeGrid(4, 1, 2);
    try core.grid.setWinFloatPos(4, 44, 2, 3, 60, 0, 3, true);
    try std.testing.expectEqual(@as(?i64, 2), surfaceForGrid(&core.grid, 4));
    const layers = collectSurfaceLayers(&core, 2);
    try std.testing.expectEqual(@as(usize, 3), layers.len);
    // A born-external root has no global origin; its sentinel is not a
    // coordinate to subtract from the nested float's resolved position.
    try std.testing.expectEqual(@as(i64, 4), layers[2].grid_id);
    try std.testing.expectEqual(@as(i32, 3), layers[2].x_px);
    try std.testing.expectEqual(@as(i32, 2), layers[2].y_px);

    core.grid.win_pos.getPtr(3).?.anchor_grid = 99;
    try std.testing.expectEqual(@as(?i64, null), surfaceForGrid(&core.grid, 4));
    core.grid.win_pos.getPtr(3).?.anchor_grid = 4;
    try std.testing.expectEqual(@as(?i64, null), surfaceForGrid(&core.grid, 4));
    core.grid.win_pos.getPtr(3).?.anchor_grid = 1;
    try std.testing.expectEqual(@as(?i64, 1), surfaceForGrid(&core.grid, 4));
}

test "surface migration resends unchanged nested grids but same-surface movement does not" {
    const Sink = struct {
        fn layout(_: ?*anyopaque, _: i64, _: [*]const c_api.Layer, _: usize, _: u32, _: u32) callconv(.c) void {}
    };
    var core = Core.initForTest(std.testing.allocator);
    defer core.deinitForTest();
    core.cb.on_surface_layout = Sink.layout;
    core.cell_w_px = 10;
    core.cell_h_px = 20;
    try core.grid.resize(20, 40);
    try core.grid.resizeGrid(2, 20, 40);
    _ = try core.grid.setWinExternalPos(2, 20);
    try core.grid.resizeGrid(3, 4, 8);
    try core.grid.resizeGrid(4, 4, 8);
    try core.grid.setWinFloatPos(3, 30, 1, 1, 50, 0, 1, true);
    try core.grid.setWinFloatPos(4, 40, 2, 2, 60, 0, 3, true);
    notifySurfaceLayouts(&core);
    core.grid.sub_grids.getPtr(3).?.clearDirty();
    core.grid.sub_grids.getPtr(4).?.clearDirty();

    try core.grid.setWinFloatPos(3, 30, 3, 1, 50, 0, 1, true);
    notifySurfaceLayouts(&core);
    try std.testing.expect(!core.grid.sub_grids.getPtr(3).?.dirty);
    try std.testing.expect(!core.grid.sub_grids.getPtr(4).?.dirty);

    try core.grid.setWinFloatPos(3, 30, 3, 1, 50, 0, 2, true);
    notifySurfaceLayouts(&core);
    for ([_]i64{ 3, 4 }) |id| {
        const sg = core.grid.sub_grids.getPtr(id).?;
        try std.testing.expect(sg.dirty_all);
        try std.testing.expect(sg.scroll_fast_path_blocked);
        try std.testing.expectEqual(@as(?i64, 2), core.grid.surfaceForGrid(id));
    }
}

test "a float waits for its surface root layout without dirtying an unresolved main surface" {
    var core = Core.initForTest(std.testing.allocator);
    defer core.deinitForTest();
    try core.grid.resize(20, 40);
    try core.grid.resizeGrid(3, 4, 8);
    try core.grid.setWinFloatPos(3, 30, 1, 1, 50, 0, 99, true);
    core.grid.main_buf.clearDirty();
    const revision = core.grid.content_rev;
    core.grid.noteGridLine(3, 1);
    try std.testing.expectEqual(revision, core.grid.content_rev);
    try std.testing.expect(!core.grid.main_buf.dirty);

    // Registration is allowed to precede grid_resize. Child rows must not
    // escape merely because the anchor now resolves to an external id.
    _ = try core.grid.setWinExternalPos(99, 99);
    collectEmitGrids(&core);
    try std.testing.expect(std.mem.indexOfScalar(i64, core.emit_grid_ids.items, 3) == null);
    try std.testing.expectEqual(@as(usize, 0), collectSurfaceLayers(&core, 99).len);
    try core.grid.resizeGrid(99, 20, 40);
    collectEmitGrids(&core);
    try std.testing.expect(std.mem.indexOfScalar(i64, core.emit_grid_ids.items, 3) != null);
    try std.testing.expectEqual(@as(usize, 2), collectSurfaceLayers(&core, 99).len);

    try core.grid.resizeGrid(4, 2, 4);
    try core.grid.setWinFloatPos(4, 40, 2, 2, 60, 0, 3, true);
    core.grid.sub_grids.getPtr(3).?.clearDirty();
    core.grid.noteGridLine(4, 2);
    try std.testing.expect(!core.grid.sub_grids.getPtr(3).?.dirty);
}

test "surface layout places splits and floats as ordered layers" {
    const State = struct {
        surface: i64 = 0,
        count: usize = 0,
        layers: [8]c_api.Layer = undefined,

        fn onLayout(
            ctx: ?*anyopaque,
            surface_id: i64,
            layers: [*]const c_api.Layer,
            count: usize,
            surface_rows: u32,
            surface_cols: u32,
        ) callconv(.c) void {
            _ = surface_rows;
            _ = surface_cols;
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            self.surface = surface_id;
            self.count = @min(count, self.layers.len);
            for (0..self.count) |i| self.layers[i] = layers[i];
        }
    };

    var core = Core.initForTest(std.testing.allocator);
    defer core.deinitForTest();
    core.cell_w_px = 10;
    core.cell_h_px = 20;
    try core.grid.resize(10, 40);

    var state = State{};
    core.ctx = &state;
    core.cb.on_surface_layout = State.onLayout;

    // A split at cell (2, 5) and a float above it at cell (1, 3).
    try core.grid.resizeGrid(2, 4, 20);
    try core.grid.setWinPos(2, 100, 2, 5);
    try core.grid.resizeGrid(3, 2, 6);
    try core.grid.setWinFloatPos(3, 101, 1, 3, 50, 0, 1, true);

    notifySurfaceLayouts(&core);
    try std.testing.expectEqual(@as(i64, 1), state.surface);
    try std.testing.expectEqual(@as(usize, 3), state.count);

    // layers[0] is always the surface's root grid at the origin.
    try std.testing.expectEqual(@as(i64, 1), state.layers[0].grid_id);
    try std.testing.expectEqual(@as(i32, 0), state.layers[0].x_px);
    try std.testing.expectEqual(@as(i32, 0), state.layers[0].y_px);

    // The split's origin is its cell position scaled by the cell size.
    try std.testing.expectEqual(@as(i64, 2), state.layers[1].grid_id);
    try std.testing.expectEqual(@as(i32, 50), state.layers[1].x_px);
    try std.testing.expectEqual(@as(i32, 40), state.layers[1].y_px);
    try std.testing.expectEqual(@as(u32, 4), state.layers[1].rows);
    try std.testing.expectEqual(@as(u32, 20), state.layers[1].cols);

    // The float has the higher zindex, so it sorts last: nearest the viewer.
    try std.testing.expectEqual(@as(i64, 3), state.layers[2].grid_id);
    try std.testing.expectEqual(@as(i32, 30), state.layers[2].x_px);
    try std.testing.expectEqual(@as(i32, 20), state.layers[2].y_px);
    try std.testing.expectEqual(@as(i32, 2), state.layers[2].z);

    // Hiding the float drops its layer.
    try core.grid.hideWin(3);
    notifySurfaceLayouts(&core);
    try std.testing.expectEqual(@as(usize, 2), state.count);
    try std.testing.expectEqual(@as(i64, 2), state.layers[1].grid_id);
}

test "the scroll fast path applies to a vertical split, a float, and both at once" {
    const State = struct {
        calls: u32 = 0,
        last_grid: i64 = 0,

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
            _ = row_start;
            _ = row_end;
            _ = col_start;
            _ = col_end;
            _ = rows_delta;
            _ = total_rows;
            _ = total_cols;
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            self.calls += 1;
            self.last_grid = grid_id;
        }
    };

    var core = Core.initForTest(std.testing.allocator);
    defer core.deinitForTest();
    try core.grid.resize(10, 40);
    var state = State{};
    core.ctx = &state;

    // Two vertical splits: neither spans the surface width. Composition rejected
    // these outright (ScrollFallbackReason.partial_width); each owns its rows now.
    try core.grid.resizeGrid(2, 10, 20);
    try core.grid.setWinPos(2, 101, 0, 0);
    try core.grid.resizeGrid(3, 10, 20);
    try core.grid.setWinPos(3, 102, 0, 20);

    core.grid.scrollGrid(2, 0, 10, 0, 20, 1, 0);
    try std.testing.expect(dispatchGridRowScroll(&core, State.onRowScroll, 2));
    try std.testing.expectEqual(@as(i64, 2), state.last_grid);

    // Scrollbind: the other split scrolls in the same batch and is eligible too.
    core.grid.scrollGrid(3, 0, 10, 0, 20, 1, 0);
    try std.testing.expect(dispatchGridRowScroll(&core, State.onRowScroll, 3));
    try std.testing.expectEqual(@as(u32, 2), state.calls);
    try std.testing.expectEqual(@as(i64, 3), state.last_grid);

    // A float over the left split: it is drawn as its own layer on top, so
    // shifting the split's rows cannot move the float's pixels.
    core.grid.sub_grids.getPtr(2).?.clearScrollState();
    try core.grid.resizeGrid(4, 3, 8);
    try core.grid.setWinFloatPos(4, 103, 2, 2, 50, 0, 1, true);
    core.grid.scrollGrid(2, 0, 10, 0, 20, 1, 0);
    try std.testing.expect(dispatchGridRowScroll(&core, State.onRowScroll, 2));
    try std.testing.expectEqual(@as(u32, 3), state.calls);

    // The float itself scrolls through the same path.
    core.grid.scrollGrid(4, 0, 3, 0, 8, 1, 0);
    try std.testing.expect(dispatchGridRowScroll(&core, State.onRowScroll, 4));
    try std.testing.expectEqual(@as(i64, 4), state.last_grid);

    // Grid-internal limits still hold: a partial-width scroll and one that
    // vacates more than half the region are both refused.
    core.grid.sub_grids.getPtr(3).?.clearScrollState();
    core.grid.scrollGrid(3, 0, 10, 0, 10, 1, 0);
    try std.testing.expect(!dispatchGridRowScroll(&core, State.onRowScroll, 3));

    core.grid.sub_grids.getPtr(3).?.clearScrollState();
    core.grid.scrollGrid(3, 0, 10, 0, 20, 8, 0);
    try std.testing.expect(!dispatchGridRowScroll(&core, State.onRowScroll, 3));
}

test "a row shift waits for the external window that hosts the scrolling float" {
    const State = struct {
        calls: u32 = 0,
        last_grid: i64 = 0,

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
            _ = row_start;
            _ = row_end;
            _ = col_start;
            _ = col_end;
            _ = rows_delta;
            _ = total_rows;
            _ = total_cols;
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            self.calls += 1;
            self.last_grid = grid_id;
        }
    };

    var core = Core.initForTest(std.testing.allocator);
    defer core.deinitForTest();
    try core.grid.resize(10, 40);
    var state = State{};
    core.ctx = &state;

    // An external window Neovim proposed too small: the open is withheld until
    // the resize the core asked for lands, so the frontend has no surface yet.
    try core.grid.resizeGrid(2, 10, 20);
    try std.testing.expect(try core.grid.setWinExternalPos(2, 42));
    try core.grid.pending_ext_window_grids.put(core.alloc, 2, .{ .grid_id = 2, .width = 20, .height = 10 });

    // A float that surface hosts.
    try core.grid.resizeGrid(3, 6, 10);
    try core.grid.setWinFloatPos(3, 43, 1, 1, 50, 0, 2, true);

    // Neither the withheld host nor anything it places may shift: the frontend
    // has no storage for that surface and answers a shift by failing the flush.
    core.grid.scrollGrid(2, 0, 10, 0, 20, 1, 0);
    try std.testing.expect(!dispatchGridRowScroll(&core, State.onRowScroll, 2));
    core.grid.scrollGrid(3, 0, 6, 0, 10, 1, 0);
    try std.testing.expect(!dispatchGridRowScroll(&core, State.onRowScroll, 3));
    try std.testing.expectEqual(@as(u32, 0), state.calls);

    // The open lands, and the float becomes eligible with its host.
    _ = core.grid.pending_ext_window_grids.remove(2);
    try core.known_external_grids.put(core.alloc, 2, .{
        .win = 42,
        .start_row = 0,
        .start_col = 0,
        .rows = 10,
        .cols = 20,
    });
    core.grid.sub_grids.getPtr(3).?.clearScrollState();
    core.grid.scrollGrid(3, 0, 6, 0, 10, 1, 0);
    try std.testing.expect(dispatchGridRowScroll(&core, State.onRowScroll, 3));
    try std.testing.expectEqual(@as(u32, 1), state.calls);
    try std.testing.expectEqual(@as(i64, 3), state.last_grid);
}

test "a vertical split's scroll publishes a shift instead of regenerating the band" {
    const State = struct {
        scroll_calls: u32 = 0,
        scrolled_grid: i64 = 0,
        rows_emitted: u32 = 0,
        root_rows_emitted: u32 = 0,

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
            if (flags & c_api.VERT_UPDATE_MAIN == 0) return;
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            if (grid_id == 1) {
                self.root_rows_emitted += 1;
                return;
            }
            if (grid_id != 2) return;
            self.rows_emitted += 1;
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
            _ = row_start;
            _ = row_end;
            _ = col_start;
            _ = col_end;
            _ = rows_delta;
            _ = total_rows;
            _ = total_cols;
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            self.scroll_calls += 1;
            self.scrolled_grid = grid_id;
        }
    };

    var core = Core.initForTest(std.testing.allocator);
    defer core.deinitForTest();
    core.cell_w_px = 1;
    core.cell_h_px = 1;
    core.drawable_w_px = 40;
    core.drawable_h_px = 10;
    try core.grid.resize(10, 40);
    core.grid.cursor_visible = false;

    // Two vertical splits, so neither spans the surface width. This is the
    // layout composition rejected outright.
    try core.grid.resizeGrid(2, 10, 20);
    try core.grid.setWinPos(2, 101, 0, 0);
    try core.grid.resizeGrid(3, 10, 20);
    try core.grid.setWinPos(3, 102, 0, 20);
    for (0..10) |r| {
        core.grid.putCellGrid(2, @intCast(r), 0, 'A' + @as(u32, @intCast(r)), 0);
        core.grid.putCellGrid(3, @intCast(r), 0, 'a' + @as(u32, @intCast(r)), 0);
    }

    var state = State{};
    core.ctx = &state;
    core.cb.on_vertices_row = State.onRow;
    core.cb.on_grid_row_scroll = State.onRowScroll;

    var flush_ctx = FlushCtx{ .core = &core };
    try flush_ctx.onFlush(10, 40);
    state = .{};

    // One line off the top of the left split. Nothing else is written: a cell
    // write dirties the root row under it on purpose (a layer that clears or
    // closes needs grid 1 to repaint underneath), which would mask what this
    // asserts about the scroll itself.
    core.grid.scrollGrid(2, 0, 10, 0, 20, 1, 0);
    try flush_ctx.onFlush(10, 40);

    try std.testing.expectEqual(@as(u32, 1), state.scroll_calls);
    try std.testing.expectEqual(@as(i64, 2), state.scrolled_grid);
    // Only the vacated row is regenerated; the other nine are carried by the
    // shift. Both bounds: a run that emitted nothing would also satisfy
    // "<= 2", so require that the vacated row did arrive.
    try std.testing.expect(state.rows_emitted >= 1);
    try std.testing.expect(state.rows_emitted <= 2);
    // The split owns its rows: grid 1's cells under it did not change, so the
    // root must not be regenerated and resent for a scroll inside a window.
    try std.testing.expectEqual(@as(u32, 0), state.root_rows_emitted);
}

test "scrollbound splits and a centred float all shift in one batch and resend only the vacated band" {
    // RowShiftSink below keeps one aggregate tally and hard-codes grid 2, which
    // cannot say whether each of three grids shifted. This sink is keyed by
    // grid instead; it stays local so the four setUpRowShiftCore tests keep
    // reading the aggregate fields they were written against.
    const State = struct {
        const Tally = struct {
            scroll_calls: u32 = 0,
            last_rows_delta: i32 = 0,
            rows_emitted: u32 = 0,
        };

        left: Tally = .{},
        right: Tally = .{},
        float: Tally = .{},
        root_rows_emitted: u32 = 0,

        fn tallyFor(self: *@This(), grid_id: i64) ?*Tally {
            return switch (grid_id) {
                2 => &self.left,
                3 => &self.right,
                4 => &self.float,
                else => null,
            };
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
            _ = row_start;
            _ = row_count;
            _ = verts;
            _ = vert_count;
            _ = total_rows;
            _ = total_cols;
            if (flags & c_api.VERT_UPDATE_MAIN == 0) return;
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            if (grid_id == 1) {
                self.root_rows_emitted += 1;
                return;
            }
            const tally = self.tallyFor(grid_id) orelse return;
            tally.rows_emitted += 1;
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
            _ = row_start;
            _ = row_end;
            _ = col_start;
            _ = col_end;
            _ = total_rows;
            _ = total_cols;
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            const tally = self.tallyFor(grid_id) orelse return;
            tally.scroll_calls += 1;
            tally.last_rows_delta = rows_delta;
        }
    };

    var core = Core.initForTest(std.testing.allocator);
    defer core.deinitForTest();
    core.cell_w_px = 1;
    core.cell_h_px = 1;
    core.drawable_w_px = 60;
    core.drawable_h_px = 12;
    try core.grid.resize(12, 60);
    core.grid.cursor_visible = false;

    // Two vertical splits side by side, plus a float centred over the boundary
    // so it covers columns of both. Every window is its own grid, so neither
    // the neighbour split nor the float on top can be disturbed by a shift.
    try core.grid.resizeGrid(2, 12, 30);
    try core.grid.setWinPos(2, 101, 0, 0);
    try core.grid.resizeGrid(3, 12, 30);
    try core.grid.setWinPos(3, 102, 0, 30);
    try core.grid.resizeGrid(4, 8, 20);
    try core.grid.setWinFloatPos(4, 103, 2, 20, 50, 0, 1, true);
    for (0..12) |r| {
        core.grid.putCellGrid(2, @intCast(r), 0, 'A' + @as(u32, @intCast(r)), 0);
        core.grid.putCellGrid(3, @intCast(r), 0, 'a' + @as(u32, @intCast(r)), 0);
    }
    for (0..8) |r| {
        core.grid.putCellGrid(4, @intCast(r), 0, '0' + @as(u32, @intCast(r)), 0);
    }

    var state = State{};
    core.ctx = &state;
    core.cb.on_vertices_row = State.onRow;
    core.cb.on_grid_row_scroll = State.onRowScroll;

    var flush_ctx = FlushCtx{ .core = &core };
    try flush_ctx.onFlush(12, 60);
    state = .{};

    // A <C-d>-sized step, not a single line: three rows leave each region at
    // once. Both splits scroll together (scrollbind) and the float scrolls its
    // own content, all in one batch. Three is within half of every region
    // (12/2 and 8/2), which is where gridScrollFastPathRegion stops shifting.
    const shift_rows: i32 = 3;
    core.grid.scrollGrid(2, 0, 12, 0, 30, shift_rows, 0);
    core.grid.scrollGrid(3, 0, 12, 0, 30, shift_rows, 0);
    core.grid.scrollGrid(4, 0, 8, 0, 20, shift_rows, 0);
    try flush_ctx.onFlush(12, 60);

    // GridBuf.scroll marks exactly the vacated band dirty for an upward scroll
    // (`markDirtyRect(bot - shift, bot)`, grid.zig:1073), so each grid owes
    // `shift_rows` rows and no more, whatever its region height is: rows 9..11
    // of each split and rows 5..7 of the float.
    const expected_rows: u32 = 3;
    for ([_]*const State.Tally{ &state.left, &state.right, &state.float }) |tally| {
        try std.testing.expectEqual(@as(u32, 1), tally.scroll_calls);
        try std.testing.expectEqual(shift_rows, tally.last_rows_delta);
        try std.testing.expectEqual(expected_rows, tally.rows_emitted);
    }

    // Each window owns its rows, so grid 1's cells under all three are
    // untouched and the root must not be regenerated for any of these scrolls.
    try std.testing.expectEqual(@as(u32, 0), state.root_rows_emitted);
}

/// Sink for the row-shift hint tests below: counts one window grid's MAIN
/// rows and every hint, remembering the last hint's delta and last row sent.
const RowShiftSink = struct {
    scroll_calls: u32 = 0,
    scrolled_grid: i64 = 0,
    last_rows_delta: i32 = 0,
    rows_emitted: u32 = 0,
    last_row_start: u32 = 0,

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
        _ = row_count;
        _ = verts;
        _ = vert_count;
        _ = total_rows;
        _ = total_cols;
        if (grid_id != 2 or flags & c_api.VERT_UPDATE_MAIN == 0) return;
        const self: *@This() = @ptrCast(@alignCast(ctx.?));
        self.rows_emitted += 1;
        self.last_row_start = row_start;
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
        _ = row_start;
        _ = row_end;
        _ = col_start;
        _ = col_end;
        _ = total_rows;
        _ = total_cols;
        const self: *@This() = @ptrCast(@alignCast(ctx.?));
        self.scroll_calls += 1;
        self.scrolled_grid = grid_id;
        self.last_rows_delta = rows_delta;
    }
};

/// One 10x20 window grid (id 2) at the surface origin, one glyph per row,
/// flushed once so the next flush is incremental. Caller owns `core`.
fn setUpRowShiftCore(core: *Core, state: *RowShiftSink) !void {
    core.cell_w_px = 1;
    core.cell_h_px = 1;
    core.drawable_w_px = 20;
    core.drawable_h_px = 10;
    try core.grid.resize(10, 20);
    core.grid.cursor_visible = false;
    try core.grid.resizeGrid(2, 10, 20);
    try core.grid.setWinPos(2, 101, 0, 0);
    for (0..10) |r| {
        core.grid.putCellGrid(2, @intCast(r), 0, 'A' + @as(u32, @intCast(r)), 0);
    }
    core.ctx = state;
    core.cb.on_vertices_row = RowShiftSink.onRow;
    core.cb.on_grid_row_scroll = RowShiftSink.onRowScroll;
    var flush_ctx = FlushCtx{ .core = core };
    try flush_ctx.onFlush(10, 20);
    state.* = .{};
}

test "the root grid stops painting the default background once windows are layers" {
    // Under blur every default-background run carries alpha 0.5 and the
    // frontends composite with a premultiplied `over`. The root grid painting
    // the same background beneath each layer therefore compounds alpha
    // (0.5 -> 0.75 -> 0.875) and the window stops being translucent.
    const State = struct {
        root_bg_quads: u32 = 0,
        layer_bg_quads: u32 = 0,

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
            _ = total_rows;
            _ = total_cols;
            if (flags & c_api.VERT_UPDATE_MAIN == 0) return;
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            const vp = verts orelse return;
            // A solid quad carries the (-1,-1) texCoord sentinel; count one
            // per quad rather than per vertex.
            var i: usize = 0;
            while (i < vert_count) : (i += 6) {
                if (vp[i].texCoord[0] >= 0) continue;
                if (grid_id == 1) self.root_bg_quads += 1 else self.layer_bg_quads += 1;
            }
        }
    };

    var state = State{};
    var core = Core.initForTest(std.testing.allocator);
    defer core.deinitForTest();
    core.cell_w_px = 1;
    core.cell_h_px = 1;
    core.drawable_w_px = 20;
    core.drawable_h_px = 4;
    core.blur_enabled = true;
    try core.grid.resize(4, 20);
    core.grid.cursor_visible = false;
    core.ctx = &state;
    core.cb.on_vertices_row = State.onRow;

    var flush_ctx = FlushCtx{ .core = &core };

    // No windows placed yet: the root is the only thing on the surface and
    // must paint its own background.
    try flush_ctx.onFlush(4, 20);
    try std.testing.expect(state.root_bg_quads > 0);

    // Place a window grid. It draws as its own layer and paints the same
    // default background, so the root must stop.
    state = .{};
    try core.grid.resizeGrid(2, 4, 20);
    try core.grid.setWinPos(2, 101, 0, 0);
    core.grid.markAllDirty();
    try flush_ctx.onFlush(4, 20);
    try std.testing.expect(state.layer_bg_quads > 0);
    try std.testing.expectEqual(@as(u32, 0), state.root_bg_quads);

    // Without blur nothing compounds: the frontends force backgrounds opaque
    // and apply window opacity themselves. Dropping the root's run there only
    // makes the surface thinner and leaves the gaps between layers unpainted,
    // which is what it did to a blur=false, opacity=0.8 macOS window.
    state = .{};
    core.blur_enabled = false;
    core.background_opacity = 0.8;
    core.grid.markAllDirty();
    try flush_ctx.onFlush(4, 20);
    try std.testing.expect(state.root_bg_quads > 0);
}

test "two different-region scrolls of one grid in a batch refuse the shift" {
    var state = RowShiftSink{};
    var core = Core.initForTest(std.testing.allocator);
    defer core.deinitForTest();
    try setUpRowShiftCore(&core, &state);

    // One shift cannot describe two regions, so the hint is refused and the
    // whole grid is regenerated instead.
    core.grid.scrollGrid(2, 0, 10, 0, 20, 1, 0);
    core.grid.scrollGrid(2, 2, 8, 0, 20, 1, 0);
    var flush_ctx = FlushCtx{ .core = &core };
    try flush_ctx.onFlush(10, 20);

    try std.testing.expectEqual(@as(u32, 0), state.scroll_calls);
    try std.testing.expectEqual(@as(u32, 10), state.rows_emitted);
}

test "same-region scrolls in one batch reach the frontend as one summed shift" {
    var state = RowShiftSink{};
    var core = Core.initForTest(std.testing.allocator);
    defer core.deinitForTest();
    try setUpRowShiftCore(&core, &state);

    core.grid.scrollGrid(2, 0, 10, 0, 20, 1, 0);
    core.grid.scrollGrid(2, 0, 10, 0, 20, 1, 0);
    var flush_ctx = FlushCtx{ .core = &core };
    try flush_ctx.onFlush(10, 20);

    try std.testing.expectEqual(@as(u32, 1), state.scroll_calls);
    try std.testing.expectEqual(@as(i64, 2), state.scrolled_grid);
    try std.testing.expectEqual(@as(i32, 2), state.last_rows_delta);
    try std.testing.expectEqual(@as(u32, 2), state.rows_emitted);
}

test "a downward scroll publishes a negative shift and refills the top row" {
    var state = RowShiftSink{};
    var core = Core.initForTest(std.testing.allocator);
    defer core.deinitForTest();
    try setUpRowShiftCore(&core, &state);

    core.grid.scrollGrid(2, 0, 10, 0, 20, -1, 0);
    var flush_ctx = FlushCtx{ .core = &core };
    try flush_ctx.onFlush(10, 20);

    try std.testing.expectEqual(@as(u32, 1), state.scroll_calls);
    try std.testing.expectEqual(@as(i32, -1), state.last_rows_delta);
    try std.testing.expectEqual(@as(u32, 1), state.rows_emitted);
    try std.testing.expectEqual(@as(u32, 0), state.last_row_start);
}

test "a publication refused after a row shift was sent regenerates the whole grid" {
    // The frontend cancels the whole bracket when it refuses at on_flush_end,
    // the shift included. The retry must not send only the vacated row as if
    // the frontend had kept the shifted rows.
    const Refuse = struct {
        var core: ?*Core = null;
        fn onEnd(ctx: ?*anyopaque) callconv(.c) void {
            _ = ctx;
            if (core) |c| c.flush_aborted = true;
        }
    };
    var state = RowShiftSink{};
    var core = Core.initForTest(std.testing.allocator);
    defer core.deinitForTest();
    try setUpRowShiftCore(&core, &state);

    core.grid.scrollGrid(2, 0, 10, 0, 20, 1, 0);
    core.cb.on_flush_end = Refuse.onEnd;
    Refuse.core = &core;
    defer Refuse.core = null;
    var flush_ctx = FlushCtx{ .core = &core };
    try flush_ctx.onFlush(10, 20);
    try std.testing.expectEqual(@as(u32, 1), state.scroll_calls);

    Refuse.core = null;
    state = .{};
    try flush_ctx.onFlush(10, 20);
    const resent_shift = state.scroll_calls == 1 and state.rows_emitted == 1;
    const regenerated = state.scroll_calls == 0 and state.rows_emitted == 10;
    try std.testing.expect(resent_shift or regenerated);
}

test "a cursor left outside a shrunk layer clears the one it drew" {
    // Shrinking a grid does not move Neovim's cursor or bump its revision.
    // The main surface sends an empty cursor set for an out-of-bounds cursor;
    // the layer path sent nothing, and the frontend kept the old block.
    const State = struct {
        empty_cursor_sends: u32 = 0,
        drawn_cursor_sends: u32 = 0,

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
            _ = total_rows;
            _ = total_cols;
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            if (grid_id != 2 or (flags & c_api.VERT_UPDATE_CURSOR) == 0) return;
            if (vert_count == 0) self.empty_cursor_sends += 1 else self.drawn_cursor_sends += 1;
        }
    };

    var state = State{};
    var core = Core.initForTest(std.testing.allocator);
    defer core.deinitForTest();
    core.cell_w_px = 1;
    core.cell_h_px = 1;
    core.drawable_w_px = 20;
    core.drawable_h_px = 10;
    try core.grid.resize(10, 20);
    try core.grid.resizeGrid(2, 10, 20);
    try core.grid.setWinPos(2, 101, 0, 0);
    core.grid.cursor_visible = true;
    core.grid.cursor_valid = true;
    core.grid.cursor_shape = .block;
    core.grid.cursor_grid = 2;
    core.grid.cursor_row = 8;
    core.grid.cursor_col = 0;
    core.grid.cursor_rev +%= 1;
    core.ctx = &state;
    core.cb.on_vertices_row = State.onRow;
    var flush_ctx = FlushCtx{ .core = &core };
    try flush_ctx.onFlush(10, 20);
    try std.testing.expect(state.drawn_cursor_sends > 0);

    state = .{};
    try core.grid.resizeGrid(2, 4, 20);
    try flush_ctx.onFlush(10, 20);
    try std.testing.expectEqual(@as(u32, 1), state.empty_cursor_sends);
    try std.testing.expectEqual(@as(u32, 0), state.drawn_cursor_sends);
}

test "a flush rejected at begin keeps the mirrors marked stale" {
    // A late refusal leaves the glyph mirrors describing a frame that never
    // reached the screen. A begin rejection publishes nothing either, so it
    // must not declare them current: the next collector would free glyphs
    // only the frame still on screen draws.
    const Refuse = struct {
        var core: ?*Core = null;
        var at_end = false;
        var at_begin = false;
        fn onBegin(ctx: ?*anyopaque) callconv(.c) void {
            _ = ctx;
            if (at_begin) if (core) |c| {
                c.flush_aborted = true;
            };
        }
        fn onEnd(ctx: ?*anyopaque) callconv(.c) void {
            _ = ctx;
            if (at_end) if (core) |c| {
                c.flush_aborted = true;
            };
        }
    };
    var state = RowShiftSink{};
    var core = Core.initForTest(std.testing.allocator);
    defer core.deinitForTest();
    try setUpRowShiftCore(&core, &state);
    core.cb.on_flush_begin = Refuse.onBegin;
    core.cb.on_flush_end = Refuse.onEnd;
    Refuse.core = &core;
    defer Refuse.core = null;
    var flush_ctx = FlushCtx{ .core = &core };

    core.grid.putCellGrid(2, 0, 1, 'x', 0);
    Refuse.at_end = true;
    try flush_ctx.onFlush(10, 20);
    Refuse.at_end = false;
    try std.testing.expect(core.display_mirror_stale);

    Refuse.at_begin = true;
    try flush_ctx.onFlush(10, 20);
    Refuse.at_begin = false;
    try std.testing.expect(core.display_mirror_stale);

    try flush_ctx.onFlush(10, 20);
    try std.testing.expect(!core.display_mirror_stale);
}

test "same-region scrolls in a batch reach on_grid_scroll as one signed summed delta" {
    const State = struct {
        calls: u32 = 0,
        main_calls: u32 = 0,
        main_delta: i32 = 0,
        sub_calls: u32 = 0,
        sub_delta: i32 = 0,

        fn onScroll(ctx: ?*anyopaque, grid_id: i64, rows_delta: i32) callconv(.c) void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            self.calls += 1;
            if (grid_id == 1) {
                self.main_calls += 1;
                self.main_delta = rows_delta;
            } else if (grid_id == 2) {
                self.sub_calls += 1;
                self.sub_delta = rows_delta;
            }
        }
    };

    var core = Core.initForTest(std.testing.allocator);
    defer core.deinitForTest();
    try core.grid.resize(10, 20);
    try core.grid.resizeGrid(2, 10, 20);
    try core.grid.setWinPos(2, 101, 0, 0);

    var state = State{};
    core.ctx = &state;
    core.cb.on_grid_scroll = State.onScroll;

    // Several scrolls of one grid in one batch produce one notification. A
    // frontend holding a sub-cell offset has to give back exactly the distance
    // the content travelled, so the deltas must net out signed rather than
    // count events or keep only the last one.
    core.grid.scrollGrid(2, 0, 10, 0, 20, 3, 0);
    core.grid.scrollGrid(2, 0, 10, 0, 20, -1, 0);
    core.grid.scrollGrid(1, 0, 10, 0, 20, 2, 0);
    core.grid.scrollGrid(1, 0, 10, 0, 20, -1, 0);

    var flush_ctx = FlushCtx{ .core = &core };
    try flush_ctx.onFlush(10, 20);

    try std.testing.expectEqual(@as(u32, 2), state.calls);
    try std.testing.expectEqual(@as(u32, 1), state.sub_calls);
    try std.testing.expectEqual(@as(i32, 2), state.sub_delta);
    try std.testing.expectEqual(@as(u32, 1), state.main_calls);
    try std.testing.expectEqual(@as(i32, 1), state.main_delta);
}

test "an overflowing same-region accumulation fails closed instead of shifting" {
    var state = RowShiftSink{};
    var core = Core.initForTest(std.testing.allocator);
    defer core.deinitForTest();
    try setUpRowShiftCore(&core, &state);

    core.grid.scrollGrid(2, 0, 10, 0, 20, 1, 0);
    // Each event's distance is clamped to the region height, but a batch
    // accumulates without a bound, so seed the accumulator where one more
    // event no longer fits an i32. The sum is what the frontend would shift
    // by: a wrapped one would move the rows the wrong way.
    core.grid.sub_grids.getPtr(2).?.last_scroll_op.?.rows = std.math.maxInt(i32) - 1;
    core.grid.scrollGrid(2, 0, 10, 0, 20, 2, 0);
    try std.testing.expect(core.grid.sub_grids.get(2).?.scroll_fast_path_blocked);

    var flush_ctx = FlushCtx{ .core = &core };
    try flush_ctx.onFlush(10, 20);

    // No shift hint, and the whole grid is regenerated instead.
    try std.testing.expectEqual(@as(u32, 0), state.scroll_calls);
    try std.testing.expectEqual(@as(u32, 10), state.rows_emitted);
}

test "busy_start clears the cursor on the grid that owns it" {
    // busy_start hides the cursor without moving it. The grid that owns the
    // cursor has to receive the empty CURSOR set: a frontend merging grid
    // cursors into one overlay tracks the owning grid and ignores a clear
    // naming a different one (zonvie_core.h, on_vertices_row CURSOR contract),
    // so nothing else can take the cursor off the screen.
    const State = struct {
        shown: u32 = 0,
        cleared: u32 = 0,
        root_cleared: u32 = 0,

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
            _ = total_rows;
            _ = total_cols;
            if (flags & c_api.VERT_UPDATE_CURSOR == 0) return;
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            if (grid_id == 1) {
                if (vert_count == 0) self.root_cleared += 1;
                return;
            }
            if (grid_id != 2) return;
            if (vert_count == 0) self.cleared += 1 else self.shown += 1;
        }
    };

    var core = Core.initForTest(std.testing.allocator);
    defer core.deinitForTest();
    core.cell_w_px = 4;
    core.cell_h_px = 2;
    core.drawable_w_px = 8;
    core.drawable_h_px = 4;
    try core.grid.resize(2, 2);
    try core.grid.resizeGrid(2, 2, 2);
    try core.grid.setWinPos(2, 101, 0, 0);
    core.grid.putCellGrid(2, 0, 0, 'B', 0);
    core.grid.setCursor(2, 0, 0);

    var state = State{};
    core.ctx = &state;
    core.cb.on_vertices_row = State.onRow;
    StubGlyphCallbacks.install(&core);

    // The whole flush, the way a real one runs.
    var flush_ctx = FlushCtx{ .core = &core };
    try flush_ctx.onFlush(2, 2);
    try std.testing.expect(state.shown >= 1);
    try std.testing.expectEqual(@as(u32, 0), state.cleared);

    // Exactly what redraw_handler does for busy_start.
    core.grid.cursor_visible = false;
    core.grid.cursor_rev +%= 1;

    try flush_ctx.onFlush(2, 2);

    // Control: the flush did run its cursor handling, and it did produce a
    // clear -- addressed to grid 1, which owns nothing here. Without this a
    // flush that emitted no cursor callback at all would look the same.
    try std.testing.expect(state.root_cleared >= 1);
    try std.testing.expect(!core.grid.cursor_visible);

    try std.testing.expect(state.cleared >= 1);
}

test "a layer's cursor glyph is mirrored into cursor_verts for the atlas collector" {
    const State = struct {
        cursor_uv_y: f32 = 0,
        cursor_sends: u32 = 0,

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
            _ = total_rows;
            _ = total_cols;
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            if (grid_id != 2 or (flags & c_api.VERT_UPDATE_CURSOR) == 0) return;
            self.cursor_sends += 1;
            const slice = (verts orelse return)[0..vert_count];
            for (slice) |v| {
                if (v.texCoord[1] > 0) self.cursor_uv_y = v.texCoord[1];
            }
        }

        fn onEnsureGlyph(
            ctx: ?*anyopaque,
            cp: u32,
            out: ?*c_api.GlyphEntry,
        ) callconv(.c) c_int {
            _ = ctx;
            _ = cp;
            const e = out orelse return 0;
            e.* = std.mem.zeroes(c_api.GlyphEntry);
            e.bbox_size_px = .{ 6, 10 };
            e.ascent_px = 8;
            e.uv_min = .{ 0.25, 0.5 };
            e.uv_max = .{ 0.5, 0.75 };
            e.bytes_per_pixel = 1;
            return 1;
        }
    };

    var core = Core.initForTest(std.testing.allocator);
    defer core.deinitForTest();
    core.cell_w_px = 8;
    core.cell_h_px = 16;
    try core.grid.resize(4, 8);
    try core.grid.resizeGrid(2, 2, 4);
    try core.grid.setWinPos(2, 101, 1, 1);

    // A layer cell under a block cursor, whose glyph the row mirror does not
    // necessarily cover: the collector has to learn it from cursor_verts.
    const sg = core.grid.sub_grids.getPtr(2).?;
    sg.cells[0].cp = 'A';
    core.grid.cursor_grid = 2;
    core.grid.cursor_row = 0;
    core.grid.cursor_col = 0;
    core.grid.cursor_valid = true;
    core.grid.cursor_visible = true;
    core.grid.cursor_shape = .block;

    var state = State{};
    core.ctx = &state;
    core.cb.on_vertices_row = State.onRow;
    core.cb.on_atlas_ensure_glyph = State.onEnsureGlyph;

    sendExternalGridVertices(&core, true);

    try std.testing.expectEqual(@as(u32, 1), state.cursor_sends);
    // The glyph really made it into the dispatched cursor payload.
    try std.testing.expectEqual(@as(f32, 0.75), state.cursor_uv_y);
    // And the collector's own view of the cursor layer carries it.
    var mirrored_uv_y: f32 = 0;
    for (core.cursor_verts.items) |v| {
        if (v.texCoord[1] > 0) mirrored_uv_y = v.texCoord[1];
    }
    try std.testing.expectEqual(state.cursor_uv_y, mirrored_uv_y);
}

test "a layer's combining tail is read at the cell that owns it, not at the window's screen position" {
    const State = struct {
        shape_calls: u32 = 0,
        seen_len: usize = 0,
        seen: [16]u32 = .{0} ** 16,

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
            if (out_cap < 1) return 1;
            out_glyph_ids[0] = 42;
            out_clusters[0] = 0;
            out_x_advance[0] = 64;
            out_x_offset[0] = 0;
            out_y_offset[0] = 0;
            return 1;
        }

        fn rasterById(_: ?*anyopaque, _: u32, _: u32, out: *c_api.GlyphBitmap) callconv(.c) c_int {
            out.* = bitmap();
            return 1;
        }

        fn rasterScalar(_: ?*anyopaque, _: u32, _: u32, out: *c_api.GlyphBitmap) callconv(.c) c_int {
            out.* = bitmap();
            return 1;
        }

        fn upload(_: ?*anyopaque, _: u32, _: u32, _: u32, _: u32, _: *const c_api.GlyphBitmap) callconv(.c) void {}
        fn create(_: ?*anyopaque, _: u32, _: u32) callconv(.c) void {}
        fn onRow(_: ?*anyopaque, _: i64, _: u32, _: u32, _: ?[*]const c_api.Vertex, _: usize, _: u32, _: u32, _: u32) callconv(.c) void {}
    };

    var core = Core.initForTest(std.testing.allocator);
    defer core.deinitForTest();
    core.cell_w_px = 8;
    core.cell_h_px = 16;
    try core.grid.resize(10, 20);
    try core.grid.resizeGrid(2, 4, 8);
    // Both offsets non-zero: the old screen-position subtraction moved the
    // lookup in each axis independently.
    try core.grid.setWinPos(2, 101, 3, 5);

    const acute = [_]u32{0x0301};
    try core.grid.putCellGridCluster(2, 1, 1, 'e', 0, &acute);

    var state = State{};
    core.ctx = &state;
    core.cb.on_vertices_row = State.onRow;
    core.cb.on_shape_text_run = State.shape;
    core.cb.on_rasterize_glyph_by_id = State.rasterById;
    core.cb.on_rasterize_glyph = State.rasterScalar;
    core.cb.on_atlas_upload = State.upload;
    core.cb.on_atlas_create = State.create;
    try core.initGlyphCache();

    sendExternalGridVertices(&core, true);

    // Only the row holding the cluster has ink, so it is the only shaped run.
    try std.testing.expectEqual(@as(u32, 1), state.shape_calls);
    // The accent sits right after its own base cell, and nowhere else: a
    // shifted lookup either drops it or hands it to the cell at col + 5.
    try std.testing.expectEqualSlices(
        u32,
        &.{ ' ', 'e', 0x0301, ' ', ' ', ' ', ' ', ' ', ' ' },
        state.seen[0..state.seen_len],
    );
}

test "a rejected flush owes each sub-grid only the rows it consumed" {
    const ROWS: u32 = 8;
    const COLS: u32 = 4;
    const State = struct {
        core: *Core,
        reject: bool = false,
        rows_seen: u32 = 0,

        fn onRow(ctx: ?*anyopaque, grid_id: i64, row_start: u32, row_count: u32, verts: ?[*]const c_api.Vertex, vert_count: usize, flags: u32, total_rows: u32, total_cols: u32) callconv(.c) void {
            _ = grid_id;
            _ = row_start;
            _ = row_count;
            _ = verts;
            _ = vert_count;
            _ = flags;
            _ = total_rows;
            _ = total_cols;
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            self.rows_seen += 1;
            if (self.reject) self.core.flush_aborted = true;
        }
        fn rasterize(ctx: ?*anyopaque, scalar: u32, style_flags: u32, out_bitmap: *c_api.GlyphBitmap) callconv(.c) c_int {
            _ = ctx;
            _ = scalar;
            _ = style_flags;
            out_bitmap.* = .{ .pixels = null, .width = 1, .height = 1, .pitch = 1, .bearing_x = 0, .bearing_y = 0, .advance_26_6 = 64, .ascent_px = 1, .descent_px = 0, .bytes_per_pixel = 1 };
            return 1;
        }
        fn upload(ctx: ?*anyopaque, dx: u32, dy: u32, w: u32, h: u32, b: *const c_api.GlyphBitmap) callconv(.c) void {
            _ = ctx;
            _ = dx;
            _ = dy;
            _ = w;
            _ = h;
            _ = b;
        }
        fn create(ctx: ?*anyopaque, aw: u32, ah: u32) callconv(.c) void {
            _ = ctx;
            _ = aw;
            _ = ah;
        }
    };

    var core = Core.initForTest(std.testing.allocator);
    defer core.deinitForTest();
    // Two splits, as ext_multigrid draws them: the sub-grids hold the content
    // and grid 1 is only their container.
    try core.grid.resizeGrid(1, ROWS, COLS * 2);
    try core.grid.resizeGrid(2, ROWS, COLS);
    try core.grid.setWinPos(2, 102, 0, 0);
    try core.grid.resizeGrid(3, ROWS, COLS);
    try core.grid.setWinPos(3, 103, 0, COLS);
    core.grid.cursor_visible = false;
    core.drawable_w_px = COLS * 2;
    core.drawable_h_px = ROWS;
    core.cell_w_px = 1;
    core.cell_h_px = 1;
    core.atlas_w = config.atlas_size_default;
    core.atlas_h = config.atlas_size_default;
    core.atlas_packer = shelf_packer.ShelfPacker.init(core.atlas_w, core.atlas_h);
    core.atlas_initialized = true;
    for (2..4) |gid| {
        for (0..ROWS) |r| for (0..COLS) |cc| core.grid.putCellGrid(@intCast(gid), @intCast(r), @intCast(cc), 'A', 0);
    }

    var state = State{ .core = &core };
    core.ctx = &state;
    core.cb.on_vertices_row = State.onRow;
    core.cb.on_rasterize_glyph = State.rasterize;
    core.cb.on_atlas_upload = State.upload;
    core.cb.on_atlas_create = State.create;

    // Settle, so the next attempt owes single rows rather than the viewport.
    var flush_ctx = FlushCtx{ .core = &core };
    try flush_ctx.onFlush(ROWS, COLS * 2);
    try flush_ctx.onFlush(ROWS, COLS * 2);
    try std.testing.expect(!core.grid.sub_grids.getPtr(2).?.dirty_all);
    try std.testing.expect(!core.grid.sub_grids.getPtr(3).?.dirty_all);

    // One window changes one row; the frontend then declines to publish.
    core.grid.putCellGrid(2, 5, 0, 'B', 0);
    state.reject = true;
    state.rows_seen = 0;
    flush_ctx.onFlush(ROWS, COLS * 2) catch {};
    // Vacuity gate: the rejection must have landed on a real emission.
    try std.testing.expect(state.rows_seen != 0);

    const sg2 = core.grid.sub_grids.getPtr(2).?;
    const sg3 = core.grid.sub_grids.getPtr(3).?;
    try std.testing.expect(!sg2.dirty_all);
    try std.testing.expect(!sg3.dirty_all);
    try std.testing.expect(sg2.dirty_rows.isSet(5));
    // The untouched split owes nothing: a refusal leaves its committed frame on
    // screen, so resending it was pure waste.
    var owed3: u32 = 0;
    var it3 = sg3.dirty_rows.iterator(.{});
    while (it3.next()) |_| owed3 += 1;
    try std.testing.expectEqual(@as(u32, 0), owed3);
}

test "an external root stops painting the default background once it hosts a float" {
    // The external twin of the main-root rule above. An external grid is a
    // surface root and can host floats, so under blur the same compounded
    // alpha (0.5 -> 0.75) appears if it keeps painting the background beneath
    // them. This was main-only, because the flag asked about surface 1.
    const State = struct {
        ext_root_bg_quads: u32 = 0,
        float_bg_quads: u32 = 0,

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
            _ = total_rows;
            _ = total_cols;
            if (flags & c_api.VERT_UPDATE_MAIN == 0) return;
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            const vp = verts orelse return;
            var i: usize = 0;
            while (i < vert_count) : (i += 6) {
                if (vp[i].texCoord[0] >= 0) continue;
                if (grid_id == 2) self.ext_root_bg_quads += 1 else if (grid_id == 3) {
                    self.float_bg_quads += 1;
                }
            }
        }
    };

    var state = State{};
    var core = Core.initForTest(std.testing.allocator);
    defer core.deinitForTest();
    core.cell_w_px = 1;
    core.cell_h_px = 1;
    core.drawable_w_px = 20;
    core.drawable_h_px = 4;
    core.blur_enabled = true;
    try core.grid.resize(4, 20);
    core.grid.cursor_visible = false;
    core.ctx = &state;
    core.cb.on_vertices_row = State.onRow;

    // An external window with nothing on it: it is the only thing on its own
    // surface and must paint its own background.
    try core.grid.resizeGrid(2, 4, 20);
    try std.testing.expect(try core.grid.setWinExternalPos(2, 42));
    try core.known_external_grids.put(core.alloc, 2, .{
        .win = 42,
        .start_row = 0,
        .start_col = 0,
        .rows = 4,
        .cols = 20,
    });
    var flush_ctx = FlushCtx{ .core = &core };
    try flush_ctx.onFlush(4, 20);
    try std.testing.expect(state.ext_root_bg_quads > 0);

    // A float anchored onto that external window draws as its own layer and
    // paints the same background, so the external root must stop.
    state = .{};
    try core.grid.resizeGrid(3, 2, 10);
    try core.grid.setWinFloatPos(3, 43, 1, 1, 50, 0, 2, true);
    core.grid.markAllDirty();
    core.grid.sub_grids.getPtr(2).?.markAllDirty();
    core.grid.sub_grids.getPtr(3).?.markAllDirty();
    try flush_ctx.onFlush(4, 20);
    try std.testing.expect(state.float_bg_quads > 0);
    try std.testing.expectEqual(@as(u32, 0), state.ext_root_bg_quads);

    // Without blur nothing compounds, so the root paints again.
    state = .{};
    core.blur_enabled = false;
    core.background_opacity = 0.8;
    core.grid.markAllDirty();
    core.grid.sub_grids.getPtr(2).?.markAllDirty();
    core.grid.sub_grids.getPtr(3).?.markAllDirty();
    try flush_ctx.onFlush(4, 20);
    try std.testing.expect(state.ext_root_bg_quads > 0);
}

test "a cursor leaving an external window for a live grid does not regenerate it" {
    const ROWS: u32 = 6;
    const COLS: u32 = 8;
    const State = struct {
        ext_content_rows: u32 = 0,
        ext_cursor_clears: u32 = 0,

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
            _ = total_rows;
            _ = total_cols;
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            if (grid_id != 2) return;
            if (flags & c_api.VERT_UPDATE_CURSOR != 0) {
                if (vert_count == 0) self.ext_cursor_clears += 1;
                return;
            }
            self.ext_content_rows += 1;
        }
        fn rasterize(ctx: ?*anyopaque, scalar: u32, style_flags: u32, out_bitmap: *c_api.GlyphBitmap) callconv(.c) c_int {
            _ = ctx;
            _ = scalar;
            _ = style_flags;
            out_bitmap.* = .{ .pixels = null, .width = 1, .height = 1, .pitch = 1, .bearing_x = 0, .bearing_y = 0, .advance_26_6 = 64, .ascent_px = 1, .descent_px = 0, .bytes_per_pixel = 1 };
            return 1;
        }
        fn upload(ctx: ?*anyopaque, dx: u32, dy: u32, w: u32, h: u32, b: *const c_api.GlyphBitmap) callconv(.c) void {
            _ = ctx;
            _ = dx;
            _ = dy;
            _ = w;
            _ = h;
            _ = b;
        }
        fn create(ctx: ?*anyopaque, aw: u32, ah: u32) callconv(.c) void {
            _ = ctx;
            _ = aw;
            _ = ah;
        }
    };

    var core = Core.initForTest(std.testing.allocator);
    defer core.deinitForTest();
    try core.grid.resizeGrid(1, ROWS, COLS);
    // grid 2: an external window. grid 3: a split the MAIN window places, which
    // is a perfectly live grid and simply not an external root.
    try core.grid.resizeGrid(2, ROWS, COLS);
    try std.testing.expect(try core.grid.setWinExternalPos(2, 42));
    try core.known_external_grids.put(core.alloc, 2, .{
        .win = 42,
        .start_row = 0,
        .start_col = 0,
        .rows = ROWS,
        .cols = COLS,
    });
    try core.grid.resizeGrid(3, ROWS, COLS);
    try core.grid.setWinPos(3, 103, 0, 0);
    core.drawable_w_px = COLS;
    core.drawable_h_px = ROWS;
    core.cell_w_px = 1;
    core.cell_h_px = 1;
    core.atlas_w = config.atlas_size_default;
    core.atlas_h = config.atlas_size_default;
    core.atlas_packer = shelf_packer.ShelfPacker.init(core.atlas_w, core.atlas_h);
    core.atlas_initialized = true;
    for (0..ROWS) |r| for (0..COLS) |cc| core.grid.putCellGrid(2, @intCast(r), @intCast(cc), 'A', 0);

    var state = State{};
    core.ctx = &state;
    core.cb.on_vertices_row = State.onRow;
    core.cb.on_rasterize_glyph = State.rasterize;
    core.cb.on_atlas_upload = State.upload;
    core.cb.on_atlas_create = State.create;

    // Settle with the cursor in the external window.
    core.grid.cursor_visible = true;
    core.grid.cursor_grid = 2;
    core.grid.cursor_row = 1;
    core.grid.cursor_col = 1;
    core.grid.cursor_valid = true;
    core.grid.cursor_rev +%= 1;
    var flush_ctx = FlushCtx{ .core = &core };
    try flush_ctx.onFlush(ROWS, COLS);
    try flush_ctx.onFlush(ROWS, COLS);

    // Move the cursor to the main-surface split. The external window owes its
    // cursor clear and nothing else — regenerating its rows was the defect.
    state = .{};
    core.grid.cursor_grid = 3;
    core.grid.cursor_row = 2;
    core.grid.cursor_col = 2;
    core.grid.cursor_rev +%= 1;
    try flush_ctx.onFlush(ROWS, COLS);
    try std.testing.expectEqual(@as(u32, 1), state.ext_cursor_clears);
    try std.testing.expectEqual(@as(u32, 0), state.ext_content_rows);
}

test "composeRowRuns composes any grid's cells, and blanks a short row's tail" {
    // The composer was written against main_buf and hardcoded grid id 1. Both
    // are arguments now, so this drives it with a SUB-GRID's cells — the shape
    // every window has under ext_multigrid — and with a row that runs past the
    // end of the buffer, which the per-cell composer it replaced answered by
    // substituting a blank at hl 0.
    var core = Core.initForTest(std.testing.allocator);
    defer core.deinitForTest();
    core.hl.setDefaults(0x111111, 0x222222, null);
    try core.hl.define(5, 0xAA0000, 0xBB0000, 0xCC0000, false, 0, .{ .bold = true }, false);

    const cols: u32 = 8;
    try core.grid.resize(4, 40);
    try core.grid.resizeGrid(2, 2, cols);
    for (0..2) |r| {
        for (0..cols) |c| core.grid.putCellGrid(2, @intCast(r), @intCast(c), 'Z', 5);
    }

    try core.initHlCache();
    const hl_cache: []highlight.ResolvedAttrWithStyles = core.hl_cache_buf orelse &.{};
    const hl_valid: []bool = core.hl_valid_buf orelse &.{};
    @memset(hl_valid, false);

    var dst: RenderCells = .{};
    defer dst.deinit(core.alloc);
    try dst.ensureTotalCapacity(core.alloc, cols);
    dst.setLen(cols);

    var hits: u32 = 0;
    var misses: u32 = 0;
    const sg = core.grid.sub_grids.getPtr(2).?;
    composeRowRuns(&core, &dst, sg.cells, 2, 0, cols, hl_cache, hl_valid, @intCast(hl_valid.len), false, false, null, false, &hits, &misses);

    const a5 = core.hl.getWithStyles(5);
    for (0..cols) |c| {
        try std.testing.expectEqual(@as(u32, 'Z'), dst.scalars.items[c]);
        try std.testing.expectEqual(a5.fg, dst.fg_rgbs.items[c]);
        try std.testing.expectEqual(a5.bg, dst.bg_rgbs.items[c]);
        // The grid id is the surface's, not a hardcoded 1.
        try std.testing.expectEqual(@as(i64, 2), dst.grid_ids.items[c]);
    }

    // A row whose cells run past the end of the buffer: the tail composes as a
    // blank at hl 0, exactly as the per-cell path substituted.
    @memset(hl_valid, false);
    const short_start: usize = sg.cells.len - 3;
    composeRowRuns(&core, &dst, sg.cells, 2, short_start, cols, hl_cache, hl_valid, @intCast(hl_valid.len), false, false, null, false, &hits, &misses);
    const a0 = core.hl.getWithStyles(0);
    for (0..3) |c| {
        try std.testing.expectEqual(@as(u32, 'Z'), dst.scalars.items[c]);
    }
    for (3..cols) |c| {
        try std.testing.expectEqual(@as(u32, ' '), dst.scalars.items[c]);
        try std.testing.expectEqual(a0.fg, dst.fg_rgbs.items[c]);
        try std.testing.expectEqual(a0.bg, dst.bg_rgbs.items[c]);
        try std.testing.expectEqual(@as(i64, 2), dst.grid_ids.items[c]);
    }
}

test "popupmenu anchor is published in the coordinates of the window that shows it" {
    var core = Core.initForTest(std.testing.allocator);
    defer core.deinitForTest();
    const g = &core.grid;

    // A split detached with <C-w>ge keeps its old main-grid position as its
    // origin (10, 20). Both frontends place the popup from the external
    // window's own top-left, so the anchor must stay local to it.
    try g.external_grids.put(g.alloc, 5, .{ .win = 1005, .start_row = 10, .start_col = 20 });
    var p = popupmenuAnchorPlacement(g, 5, 3, 4);
    try std.testing.expectEqual(@as(i64, 5), p.win);
    try std.testing.expectEqual(@as(i32, 3), p.row);
    try std.testing.expectEqual(@as(i32, 4), p.col);

    // Born external (no position): local as well.
    try g.external_grids.put(g.alloc, 6, .{ .win = 1006, .start_row = -1, .start_col = -1 });
    p = popupmenuAnchorPlacement(g, 6, 3, 4);
    try std.testing.expectEqual(@as(i64, 6), p.win);
    try std.testing.expectEqual(@as(i32, 3), p.row);

    // A float the detached window hosts: win_pos holds it in global units
    // (origin + local 6, 8). The popup goes to the HOST window, at the
    // float's place inside it.
    try g.win_pos.put(g.alloc, 7, .{ .row = 16, .col = 28, .anchor_grid = 5 });
    p = popupmenuAnchorPlacement(g, 7, 1, 2);
    try std.testing.expectEqual(@as(i64, 5), p.win);
    try std.testing.expectEqual(@as(i32, 7), p.row);
    try std.testing.expectEqual(@as(i32, 10), p.col);

    // A split on the main window: global coordinates, as before.
    try g.win_pos.put(g.alloc, 2, .{ .row = 2, .col = 0, .anchor_grid = 1 });
    p = popupmenuAnchorPlacement(g, 2, 3, 4);
    try std.testing.expectEqual(@as(i64, 2), p.win);
    try std.testing.expectEqual(@as(i32, 5), p.row);
    try std.testing.expectEqual(@as(i32, 4), p.col);
}

test "a surface root regenerates every row when it gains or loses its layers under blur" {
    const State = struct {
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
            var row = row_start;
            while (row < row_start + row_count and row < self.seen_rows.len) : (row += 1) {
                self.seen_rows[row] = true;
            }
        }
    };

    var core = Core.initForTest(std.testing.allocator);
    defer core.deinitForTest();
    // Under blur a surface root drops its default-background runs while it
    // hosts a layer, so that answer changing changes every root row, not just
    // the band the layer covers.
    core.blur_enabled = true;
    try core.grid.resizeGrid(1, 4, 4);
    try core.grid.resizeGrid(2, 4, 4);
    try std.testing.expect(try core.grid.setWinExternalPos(2, 42));
    core.grid.cursor_visible = false;
    core.drawable_w_px = 4;
    core.drawable_h_px = 4;
    core.cell_w_px = 1;
    core.cell_h_px = 1;
    var state = State{};
    core.ctx = &state;
    core.cb.on_vertices_row = State.onRow;
    var flush_ctx = FlushCtx{ .core = &core };
    try flush_ctx.onFlush(4, 4);
    try flush_ctx.onFlush(4, 4);

    // The external window's first float: one row, on row 0.
    try core.grid.resizeGrid(3, 1, 2);
    try core.grid.setWinFloatPos(3, 43, 0, 0, 50, 1, 2, true);
    state = .{};
    try flush_ctx.onFlush(4, 4);
    try std.testing.expectEqual([4]bool{ true, true, true, true }, state.seen_rows);

    // And back: hiding the last float flips it again.
    state = .{};
    try flush_ctx.onFlush(4, 4);
    try core.grid.hideWin(3);
    state = .{};
    try flush_ctx.onFlush(4, 4);
    try std.testing.expectEqual([4]bool{ true, true, true, true }, state.seen_rows);
}

test "the main surface regenerates every row when its last layer is hidden under blur" {
    const State = struct {
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
    core.blur_enabled = true;
    try core.grid.resizeGrid(1, 4, 4);
    try core.grid.resizeGrid(2, 1, 4);
    try core.grid.setWinPos(2, 42, 0, 0);
    core.grid.cursor_visible = false;
    core.drawable_w_px = 4;
    core.drawable_h_px = 4;
    core.cell_w_px = 1;
    core.cell_h_px = 1;
    var state = State{};
    core.ctx = &state;
    core.cb.on_vertices_row = State.onRow;
    var flush_ctx = FlushCtx{ .core = &core };
    try flush_ctx.onFlush(4, 4);
    try flush_ctx.onFlush(4, 4);

    // hideWin only marks the band the window covered (row 0); the rule for
    // the other rows flips with it.
    try core.grid.hideWin(2);
    state = .{};
    try flush_ctx.onFlush(4, 4);
    try std.testing.expectEqual([4]bool{ true, true, true, true }, state.seen_rows);
}

test "the cursor's glyph quads come from one emitter and trim box drawing to the cell" {
    const State = struct {
        entry: c_api.GlyphEntry,
        fn ensure(ctx: ?*anyopaque, scalar: u32, out_entry: *c_api.GlyphEntry) callconv(.c) c_int {
            _ = scalar;
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            out_entry.* = self.entry;
            return 1;
        }
    };
    // Same overshooting glyph as the row test: 9..22 against a 10..20 cell.
    var entry = std.mem.zeroes(c_api.GlyphEntry);
    entry.uv_min = .{ 0, 0 };
    entry.uv_max = .{ 0.1, 1.3 };
    entry.bbox_origin_px = .{ 4, -4 };
    entry.bbox_size_px = .{ 2, 13 };
    entry.ascent_px = 8;
    var state = State{ .entry = entry };

    var core = Core.initForTest(std.testing.allocator);
    defer core.deinitForTest();
    core.ctx = &state;
    core.cb.on_atlas_ensure_glyph = State.ensure;

    var out: std.ArrayListUnmanaged(c_api.Vertex) = .empty;
    defer out.deinit(core.alloc);

    const Span = struct {
        fn ofGlyph(verts: []const c_api.Vertex) [2]f32 {
            // The glyph quad is the last six vertices (after the cursor box).
            var lo: f32 = std.math.inf(f32);
            var hi: f32 = -std.math.inf(f32);
            for (verts[verts.len - 6 ..]) |v| {
                lo = @min(lo, v.position[1]);
                hi = @max(hi, v.position[1]);
            }
            return .{ lo, hi };
        }
    };

    var q = CursorCellQuads{
        .grid_id = 2,
        .row = 1,
        .col = 0,
        .x0 = 0,
        .y0 = 10,
        .cell_w = 10,
        .cell_h = 10,
        .top_pad = 0,
        .width = 10,
        .shape = 0,
        .pct = 100,
        .bg_rgb = 0xFFFFFF,
        .fg_rgb = 0x000000,
        .cell = .{ .cp = 0x2502, .hl = 0 },
    };
    try std.testing.expectEqual(CursorEmitResult.ok, try emitCursorQuads(&core, &out, q));
    // Cursor box, then the inverted glyph.
    try std.testing.expectEqual(@as(usize, 12), out.items.len);
    var span = Span.ofGlyph(out.items);
    try std.testing.expectApproxEqAbs(@as(f32, 10), span[0], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 20), span[1], 0.001);

    out.clearRetainingCapacity();
    q.cell.cp = 0x2190;
    try std.testing.expectEqual(CursorEmitResult.ok, try emitCursorQuads(&core, &out, q));
    span = Span.ofGlyph(out.items);
    try std.testing.expectApproxEqAbs(@as(f32, 9), span[0], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 22), span[1], 0.001);
}
