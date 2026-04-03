// flush.zig — Flush pipeline, ext_* UI notification subsystems.
// Extracted from nvim_core.zig. Free functions take *Core as first parameter.

const std = @import("std");
const c_api = @import("c_api.zig");
const grid_mod = @import("grid.zig");
const highlight = @import("highlight.zig");
const Highlights = highlight.Highlights;
const ResolvedAttrWithStyles = highlight.ResolvedAttrWithStyles;
const redraw = @import("redraw_handler.zig");
const config = @import("config.zig");
const rpc = @import("rpc_encode.zig");
const Logger = @import("log.zig").Logger;
const nvim_core = @import("nvim_core.zig");
const Core = nvim_core.Core;
const vertexgen = @import("vertexgen.zig");
const block_elements = @import("block_elements.zig");

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
/// overlap the same cell (matching composite_cells overwrite semantics).
pub const FloatOverlayMap = std.AutoHashMapUnmanaged(FloatOverlayKey, ?[]const u32);

pub const GridEntry = struct {
    grid_id: i64,
    zindex: i64,
    compindex: i64,
    order: u64,
};

// Pre-computed subgrid info for row-mode compose optimization.
// Caches win_pos/sub_grids lookups to avoid per-row hash map access.
pub const MAX_CACHED_SUBGRIDS = 32;
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

    fn matchesCsg(self: SubgridSnapshot, csg: CachedSubgrid) bool {
        return self.grid_id == csg.grid_id and
            self.row_start == csg.row_start and self.row_end == csg.row_end and
            self.col_start == csg.col_start and self.sg_cols == csg.sg_cols and
            self.margin_top == csg.margin_top and self.margin_bottom == csg.margin_bottom;
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
};

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
    scalars: std.ArrayListUnmanaged(u32) = .{},
    fg_rgbs: std.ArrayListUnmanaged(u32) = .{},
    bg_rgbs: std.ArrayListUnmanaged(u32) = .{},
    sp_rgbs: std.ArrayListUnmanaged(u32) = .{},
    grid_ids: std.ArrayListUnmanaged(i64) = .{},
    style_flags_arr: std.ArrayListUnmanaged(u8) = .{},
    overline_arr: std.ArrayListUnmanaged(u8) = .{},
    glow_arr: std.ArrayListUnmanaged(u8) = .{},
    /// Per-cell base decoration flags (e.g. DECO_SCROLLABLE).
    /// Pre-populated by the caller before generateRowVertices so the
    /// unified 5-pass pipeline does not need scroll-flag computation.
    deco_base_flags: std.ArrayListUnmanaged(u32) = .{},

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

    /// Write a single cell at index i, including deco base flags.
    pub inline fn setWithDeco(self: *RenderCells, i: usize, scalar: u32, fg: u32, bg: u32, sp: u32, gid: i64, flags: u8, overline: u8, deco: u32) void {
        self.scalars.items[i] = scalar;
        self.fg_rgbs.items[i] = fg;
        self.bg_rgbs.items[i] = bg;
        self.sp_rgbs.items[i] = sp;
        self.grid_ids.items[i] = gid;
        self.style_flags_arr.items[i] = flags;
        self.overline_arr.items[i] = overline;
        self.deco_base_flags.items[i] = deco;
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
///   - full width (left == 0, right == target_cols)
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
    // so out-of-range would cause an out-of-bounds access.
    const scroll_row_start = ps.top + ps.win_pos_row;
    const scroll_row_end = ps.bot + ps.win_pos_row;
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
    var count: u32 = 0;
    for (cached_subgrids) |csg| {
        if (count >= MAX_CACHED_SUBGRIDS) break;
        core.prev_subgrid_snapshots[count] = .{
            .grid_id = csg.grid_id,
            .row_start = csg.row_start,
            .row_end = csg.row_end,
            .col_start = csg.col_start,
            .sg_cols = csg.sg_cols,
            .margin_top = csg.margin_top,
            .margin_bottom = csg.margin_bottom,
        };
        count += 1;
    }
    core.prev_subgrid_snapshot_count = count;
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
    core: *const Core,
    cached_subgrids: []const CachedSubgrid,
    region_top: u32,
    region_bot: u32,
    out: []u32,
    existing_regen: []const u32,
) u32 {
    var count: u32 = 0;
    const prev = core.prev_subgrid_snapshots[0..core.prev_subgrid_snapshot_count];

    // Detect removed or moved grids: iterate previous snapshots.
    for (prev) |ps| {
        var found_same = false;
        for (cached_subgrids) |csg| {
            if (ps.matchesCsg(csg)) {
                found_same = true;
                break;
            }
        }
        if (!found_same) {
            count = addRowRange(ps.row_start, ps.row_end, region_top, region_bot, out, count, existing_regen);
            if (count >= out.len) return count;
        }
    }

    // Detect added or moved grids: iterate current subgrids.
    for (cached_subgrids) |csg| {
        var found_same = false;
        for (prev) |ps| {
            if (ps.matchesCsg(csg))
            {
                found_same = true;
                break;
            }
        }
        if (!found_same) {
            count = addRowRange(csg.row_start, csg.row_end, region_top, region_bot, out, count, existing_regen);
            if (count >= out.len) return count;
        }
    }

    return count;
}

/// Helper: add rows from [start, end) that fall within [region_top, region_bot)
/// to out[], skipping duplicates against both out[0..count] and existing_regen.
fn addRowRange(
    start: u32,
    end: u32,
    region_top: u32,
    region_bot: u32,
    out: []u32,
    initial_count: u32,
    existing_regen: []const u32,
) u32 {
    var count = initial_count;
    const clamped_start = @max(start, region_top);
    const clamped_end = @min(end, region_bot);
    var r = clamped_start;
    while (r < clamped_end) : (r += 1) {
        if (count >= out.len) return count;
        var dup = false;
        for (out[0..count]) |existing| {
            if (existing == r) {
                dup = true;
                break;
            }
        }
        if (!dup) {
            for (existing_regen) |er| {
                if (er == r) {
                    dup = true;
                    break;
                }
            }
        }
        if (!dup) {
            out[count] = r;
            count += 1;
        }
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

/// Perform scroll cache shift + y-adjust + validity check.
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
) ScrollCacheShiftResult {
    if (core.scroll_cache_rows != total_rows) {
        return .{ .fast_path_ok = false, .cached_emit_count = 0, .empty_emit_count = 0 };
    }

    // Shift cache entries within scroll region.
    // For shift > 1, multiple rows scroll off and multiple rows become vacant.
    if (scroll_rows_raw > 0) {
        const shift: usize = @intCast(scroll_rows_raw);
        if (shift > total_rows or shift > scroll_bot - scroll_top) {
            return .{ .fast_path_ok = false, .cached_emit_count = 0, .empty_emit_count = 0 };
        }
        // Save scrolled-off row buffers for reuse at vacated positions
        var saved_bufs: [64]std.ArrayListUnmanaged(c_api.Vertex) = undefined;
        if (shift > saved_bufs.len) {
            return .{ .fast_path_ok = false, .cached_emit_count = 0, .empty_emit_count = 0 };
        }
        for (0..shift) |s| {
            saved_bufs[s] = core.scroll_cache.items[scroll_top + s];
        }
        // Shift: row[i] <- row[i + shift], adjust y
        var i: usize = scroll_top;
        while (i + shift < scroll_bot) : (i += 1) {
            core.scroll_cache.items[i] = core.scroll_cache.items[i + shift];
            for (core.scroll_cache.items[i].items) |*v| {
                v.position[1] += delta_y;
            }
            if (core.scroll_cache_valid.isSet(i + shift)) {
                core.scroll_cache_valid.set(i);
            } else {
                core.scroll_cache_valid.unset(i);
            }
        }
        // Vacated rows at region bottom: reuse saved buffers, mark invalid
        for (0..shift) |s| {
            saved_bufs[s].clearRetainingCapacity();
            core.scroll_cache.items[scroll_bot - shift + s] = saved_bufs[s];
            core.scroll_cache_valid.unset(scroll_bot - shift + s);
        }
    } else if (scroll_rows_raw < 0) {
        const shift: usize = @intCast(-scroll_rows_raw);
        if (shift > total_rows or shift > scroll_bot - scroll_top) {
            return .{ .fast_path_ok = false, .cached_emit_count = 0, .empty_emit_count = 0 };
        }
        // Save scrolled-off row buffers for reuse at vacated positions
        var saved_bufs: [64]std.ArrayListUnmanaged(c_api.Vertex) = undefined;
        if (shift > saved_bufs.len) {
            return .{ .fast_path_ok = false, .cached_emit_count = 0, .empty_emit_count = 0 };
        }
        for (0..shift) |s| {
            saved_bufs[s] = core.scroll_cache.items[scroll_bot - 1 - s];
        }
        // Shift: row[i] <- row[i - shift], adjust y
        var i: usize = scroll_bot - 1;
        while (i >= scroll_top + shift) : (i -= 1) {
            core.scroll_cache.items[i] = core.scroll_cache.items[i - shift];
            for (core.scroll_cache.items[i].items) |*v| {
                v.position[1] += delta_y;
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
            saved_bufs[s].clearRetainingCapacity();
            core.scroll_cache.items[scroll_top + s] = saved_bufs[s];
            core.scroll_cache_valid.unset(scroll_top + s);
        }
    }

    // Mark regen rows as invalid
    for (regen_rows) |rr| {
        if (rr < total_rows) {
            core.scroll_cache_valid.unset(rr);
        }
    }

    // Check all non-regen rows have valid cache
    var all_valid = true;
    var cached_emit_count: u32 = 0;
    var empty_emit_count: u32 = 0;
    for (0..total_rows) |ri| {
        var is_regen = false;
        for (regen_rows) |rr| {
            if (rr == @as(u32, @intCast(ri))) {
                is_regen = true;
                break;
            }
        }
        if (is_regen) continue;

        if (!core.scroll_cache_valid.isSet(ri)) {
            all_valid = false;
            break;
        }
        cached_emit_count += 1;
        if (core.scroll_cache.items[ri].items.len == 0) {
            empty_emit_count += 1;
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
        x0: f32, y0: f32, x1: f32, y1: f32,
        col: [4]f32,
        vw: f32, vh: f32,
        grid_id: i64,
        base_deco_flags: u32,
    ) !void {
        const pts = ndc4(x0, y0, x1, y1, vw, vh);
        const p0 = pts[0]; const p1 = pts[1]; const p2 = pts[2]; const p3 = pts[3];

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
        x0: f32, y0: f32, x1: f32, y1: f32,
        col: [4]f32,
        vw: f32, vh: f32,
        grid_id: i64,
        base_deco_flags: u32,
    ) void {
        const pts = ndc4(x0, y0, x1, y1, vw, vh);
        const p0 = pts[0]; const p1 = pts[1]; const p2 = pts[2]; const p3 = pts[3];

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
        x0: f32, y0: f32, x1: f32, y1: f32,
        uv0: [2]f32, uv1: [2]f32, uv2: [2]f32, uv3: [2]f32,
        col: [4]f32,
        vw: f32, vh: f32,
        grid_id: i64,
        base_deco_flags: u32,
    ) void {
        const pts = ndc4(x0, y0, x1, y1, vw, vh);
        const p0 = pts[0]; const p1 = pts[1]; const p2 = pts[2]; const p3 = pts[3];

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
        x0: f32, y0: f32, x1: f32, y1: f32,
        col: [4]f32,
        vw: f32, vh: f32,
        grid_id: i64,
        deco_flags: u32,
        deco_phase: f32,
    ) !void {
        const pts = ndc4(x0, y0, x1, y1, vw, vh);
        const p0 = pts[0]; const p1 = pts[1]; const p2 = pts[2]; const p3 = pts[3];

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
        x0: f32, y0: f32, x1: f32, y1: f32,
        col: [4]f32,
        vw: f32, vh: f32,
        grid_id: i64,
        deco_flags: u32,
        deco_phase: f32,
    ) void {
        const pts = ndc4(x0, y0, x1, y1, vw, vh);
        const p0 = pts[0]; const p1 = pts[1]; const p2 = pts[2]; const p3 = pts[3];

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
};

/// Stats returned from generateRowVertices for performance tracking.
pub const RowGenStats = struct {
    had_glyph_miss: bool = false,
    shape_cache_hits: u32 = 0,
    shape_cache_misses: u32 = 0,
    ascii_fast_path_runs: u32 = 0,
    shape_us: i64 = 0, // total microseconds spent in shape_text_run callback
    shape_calls: u32 = 0, // number of shape_text_run callback invocations
};

/// Unified 5-pass row vertex generation shared by global grid (row_mode) and
/// external grid paths.  Caller must pre-populate `core.row_cells` (including
/// `deco_base_flags`) before calling.  Returns stats including glyph miss flag.
pub fn generateRowVertices(
    core: *Core,
    p: RowGenParams,
    out: *std.ArrayListUnmanaged(c_api.Vertex),
) !RowGenStats {
    const rc = &core.row_cells;
    const r = p.row;
    const cols = p.cols;
    const cellW = p.cell_w;
    const cellH = p.cell_h;
    const topPad = p.top_pad;
    const vw = p.vw;
    const vh = p.vh;
    var stats = RowGenStats{};
    const log_enabled = core.log.cb != null;

    // ── Pass 1: Background (run-length by bgRGB + grid_id) ──────────
    {
        var c: u32 = 0;
        while (c < cols) {
            const run_bg = rc.bg_rgbs.items[@intCast(c)];
            const run_grid_id = rc.grid_ids.items[@intCast(c)];
            const run_start = c;

            const end: u32 = @intCast(@min(
                simdFindRunEndU32(rc.bg_rgbs.items, @intCast(c), @intCast(cols), run_bg),
                simdFindRunEndI64(rc.grid_ids.items, @intCast(c), @intCast(cols), run_grid_id),
            ));

            const x0: f32 = @as(f32, @floatFromInt(run_start)) * cellW;
            const x1: f32 = @as(f32, @floatFromInt(end)) * cellW;
            const y0: f32 = @as(f32, @floatFromInt(r)) * cellH;
            const y1: f32 = y0 + cellH;

            const bg_alpha: f32 = if (run_bg == p.default_bg)
                (if (p.blur_enabled) (if (p.is_cmdline) 0.0 else 0.5) else p.background_opacity)
            else
                1.0;
            const scroll_flag = rc.deco_base_flags.items[@intCast(c)];
            try VH.pushSolidQuad(out, core.alloc, x0, y0, x1, y1, VH.rgba(run_bg, bg_alpha), vw, vh, run_grid_id, scroll_flag);
            c = end;
        }
    }

    // ── Pass 2: Under-decorations (underline, underdouble, undercurl, underdotted, underdashed) ──
    {
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

            const run_end: u32 = @intCast(@min(
                simdFindRunEndU8(rc.style_flags_arr.items, @intCast(c + 1), @intCast(cols), run_flags),
                @min(
                    simdFindRunEndU32(rc.sp_rgbs.items, @intCast(c + 1), @intCast(cols), run_sp),
                    simdFindRunEndI64(rc.grid_ids.items, @intCast(c + 1), @intCast(cols), run_grid_id),
                ),
            ));

            const deco_color = if (run_sp != highlight.Highlights.SP_NOT_SET) VH.rgb(run_sp) else VH.rgb(run_fg);
            const deco_scroll_flag: u32 = rc.deco_base_flags.items[@intCast(c)];

            const x0: f32 = @as(f32, @floatFromInt(run_start)) * cellW;
            const x1: f32 = @as(f32, @floatFromInt(run_end)) * cellW;
            const row_y: f32 = @as(f32, @floatFromInt(r)) * cellH;

            if (run_flags & STYLE_UNDERLINE != 0) {
                const uy0 = row_y + cellH - 2.0;
                const uy1 = uy0 + 1.0;
                try VH.pushDecoQuad(out, core.alloc, x0, uy0, x1, uy1, deco_color, vw, vh, run_grid_id, c_api.DECO_UNDERLINE | deco_scroll_flag, 0);
            }

            if (run_flags & STYLE_UNDERDOUBLE != 0) {
                const uy0_1 = row_y + cellH - 6.0;
                const uy1_1 = uy0_1 + 1.0;
                const uy0_2 = row_y + cellH - 2.0;
                const uy1_2 = uy0_2 + 1.0;
                try VH.pushDecoQuad(out, core.alloc, x0, uy0_1, x1, uy1_1, deco_color, vw, vh, run_grid_id, c_api.DECO_UNDERLINE | deco_scroll_flag, 0);
                try VH.pushDecoQuad(out, core.alloc, x0, uy0_2, x1, uy1_2, deco_color, vw, vh, run_grid_id, c_api.DECO_UNDERLINE | deco_scroll_flag, 0);
            }

            if (run_flags & STYLE_UNDERCURL != 0) {
                const uy0 = row_y + cellH - 4.0;
                const uy1 = row_y + cellH;
                const phase: f32 = @floatFromInt(run_start);
                try VH.pushDecoQuad(out, core.alloc, x0, uy0, x1, uy1, deco_color, vw, vh, run_grid_id, c_api.DECO_UNDERCURL | deco_scroll_flag, phase);
            }

            if (run_flags & STYLE_UNDERDOTTED != 0) {
                const uy0 = row_y + cellH - 2.0;
                const uy1 = uy0 + 1.0;
                try VH.pushDecoQuad(out, core.alloc, x0, uy0, x1, uy1, deco_color, vw, vh, run_grid_id, c_api.DECO_UNDERDOTTED | deco_scroll_flag, 0);
            }

            if (run_flags & STYLE_UNDERDASHED != 0) {
                const uy0 = row_y + cellH - 2.0;
                const uy1 = uy0 + 1.0;
                try VH.pushDecoQuad(out, core.alloc, x0, uy0, x1, uy1, deco_color, vw, vh, run_grid_id, c_api.DECO_UNDERDASHED | deco_scroll_flag, 0);
            }

            c = run_end;
        }
    }

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
    const GLYPH_CACHE_NON_ASCII_SIZE = core.glyph_cache_non_ascii_size;
    const glyph_cache_id = core.glyph_cache_by_id;
    const glyph_keys_id = core.glyph_keys_by_id;

    if (has_shaping or ensure_base != null or ensure_styled != null or core.isPhase2Atlas()) {
        // Pre-allocate vertex capacity for entire row (worst case: 1 glyph quad per column)
        try out.ensureUnusedCapacity(core.alloc, cols * 6);
        var c: u32 = 0;
        while (c < cols) {
            const run_fg = rc.fg_rgbs.items[@intCast(c)];
            const run_bg = rc.bg_rgbs.items[@intCast(c)];
            const run_grid_id = rc.grid_ids.items[@intCast(c)];
            const run_start = c;

            const base_end_attr = @min(
                simdFindRunEndU32(rc.fg_rgbs.items, @intCast(c), @intCast(cols), run_fg),
                @min(
                    simdFindRunEndU32(rc.bg_rgbs.items, @intCast(c), @intCast(cols), run_bg),
                    simdFindRunEndI64(rc.grid_ids.items, @intCast(c), @intCast(cols), run_grid_id),
                ),
            );
            // When shaping is active, also split by bold/italic style so each
            // sub-run selects the correct font variant for HarfBuzz shaping.
            const shaping_style_mask: u8 = STYLE_BOLD | STYLE_ITALIC;
            const run_style_bi: u8 = rc.style_flags_arr.items[@intCast(c)] & shaping_style_mask;
            const base_end: usize = if (has_shaping)
                @min(base_end_attr, findStyleMaskEnd(rc.style_flags_arr.items, @intCast(c), base_end_attr, shaping_style_mask, run_style_bi))
            else
                base_end_attr;
            const run_glow: u8 = if (p.glow_enabled) rc.glow_arr.items[@intCast(c)] else 0;
            const end: u32 = @intCast(if (p.glow_enabled)
                @min(base_end, simdFindRunEndU8(rc.glow_arr.items, @intCast(c), @intCast(cols), run_glow))
            else
                base_end);
            const has_ink = simdHasInkInRange(rc.scalars.items, @intCast(c), @intCast(end));

            if (has_ink) {
                const baseX = @as(f32, @floatFromInt(run_start)) * cellW;
                const baseY = @as(f32, @floatFromInt(r)) * cellH + topPad;
                const fg = VH.rgb(run_fg);
                const glyph_scroll_flag: u32 = rc.deco_base_flags.items[@intCast(c)];
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
                    core.shaping_scalars.ensureTotalCapacity(core.alloc, run_len) catch {
                        c = end;
                        continue;
                    };
                    core.shaping_col_widths.ensureTotalCapacity(core.alloc, run_len) catch {
                        c = end;
                        continue;
                    };
                    core.shaping_src_cols.ensureTotalCapacity(core.alloc, run_len) catch {
                        c = end;
                        continue;
                    };
                    // SIMD fast path: if no wide chars (no zero scalars), bulk copy
                    if (simdAllNonZero(rc.scalars.items, @intCast(run_start), @intCast(end))) {
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
                            const col_w: u32 = if (si + 1 < end and rc.scalars.items[@intCast(si + 1)] == 0) 2 else 1;
                            core.shaping_col_widths.appendAssumeCapacity(col_w);
                            core.shaping_src_cols.appendAssumeCapacity(si);
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

                    if (core.loadAsciiTables()) {
                        const is_ascii_safe = ascii_chk: {
                            const scalars = core.shaping_scalars.items[0..scalar_count];
                            if (!simdAllAsciiPrintable(scalars, scalar_count)) break :ascii_chk false;
                            if (scalar_count == 1) break :ascii_chk true;
                            const trigs = &core.ascii_lig_triggers[style_index];
                            for (scalars) |s| {
                                if (trigs[@intCast(s)] != 0) break :ascii_chk false;
                            }
                            break :ascii_chk true;
                        };
                        if (is_ascii_safe) {
                            bufs.ensureCapacity(core.alloc, scalar_count) catch {
                                c = end;
                                continue;
                            };
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
                                bufs.ensureCapacity(core.alloc, final_glyph_count) catch {
                                    c = end;
                                    continue;
                                };
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
                        bufs.ensureCapacity(core.alloc, scalar_count) catch {
                            c = end;
                            continue;
                        };
                        bufs.setLen(scalar_count);

                        const t_shape_start: i128 = if (log_enabled) std.time.nanoTimestamp() else 0;
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
                            const t_shape_end = std.time.nanoTimestamp();
                            stats.shape_us += @intCast(@divTrunc(@max(0, t_shape_end - t_shape_start), 1000));
                            stats.shape_calls += 1;
                        }

                        if (glyph_count == 0) {
                            c = end;
                            continue;
                        }

                        final_glyph_count = glyph_count;
                        if (glyph_count > scalar_count) {
                            bufs.ensureCapacity(core.alloc, glyph_count) catch {
                                c = end;
                                continue;
                            };
                            bufs.setLen(glyph_count);
                            {
                                const t_shape2_start: i128 = if (log_enabled) std.time.nanoTimestamp() else 0;
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
                                    const t_shape2_end = std.time.nanoTimestamp();
                                    stats.shape_us += @intCast(@divTrunc(@max(0, t_shape2_end - t_shape2_start), 1000));
                                    stats.shape_calls += 1;
                                }
                            }
                            if (final_glyph_count == 0) {
                                c = end;
                                continue;
                            }
                        }

                        // Store in cache if result fits
                        if (final_glyph_count <= nvim_core.SHAPE_CACHE_MAX_GLYPHS) {
                            if (core.shape_cache) |sc_cache| {
                                var sc_store_way: usize = 0;
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

                    // Iterate shaped glyphs — ensure capacity for .notdef expansion
                    out.ensureUnusedCapacity(core.alloc, (final_glyph_count + scalar_count) * 6) catch {
                        c = end;
                        continue;
                    };
                    var penX: f32 = baseX;

                    // Dump shaping results for ligature debugging.
                    // Log when shaping was used (not ASCII fast path) — covers both
                    // calt (glyph count == scalar count, IDs differ) and liga (count differs).
                    if (log_enabled and final_glyph_count > 0 and !used_ascii_fast_path) {
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
                        const this_cluster = bufs.clusters.items[gi];
                        const next_cluster = if (gi + 1 < final_glyph_count) bufs.clusters.items[gi + 1] else @as(u32, @intCast(scalar_count));

                        if (gid == 0) {
                            // .notdef glyph — per-scalar fallback
                            var ci: u32 = this_cluster;
                            while (ci < next_cluster) : (ci += 1) {
                                const fb_scalar = core.shaping_scalars.items[@intCast(ci)];
                                const fb_col_w = core.shaping_col_widths.items[@intCast(ci)];
                                if (fb_scalar == 32) {
                                    penX += @as(f32, @floatFromInt(fb_col_w)) * cellW;
                                    continue;
                                }
                                if (block_elements.isBlockElement(fb_scalar)) {
                                    const blk_w = @as(f32, @floatFromInt(fb_col_w)) * cellW;
                                    const blk_geo = block_elements.getBlockGeometry(fb_scalar);
                                    if (blk_geo.count > 0) {
                                        const blk_y0 = @as(f32, @floatFromInt(r)) * cellH;
                                        out.ensureUnusedCapacity(core.alloc, @as(usize, blk_geo.count) * 6) catch {
                                            penX += blk_w;
                                            continue;
                                        };
                                        for (blk_geo.rects[0..blk_geo.count]) |rect| {
                                            VH.pushSolidQuadAssumeCapacity(out, penX + rect.x0 * blk_w, blk_y0 + rect.y0 * cellH, penX + rect.x1 * blk_w, blk_y0 + rect.y1 * cellH, fg, vw, vh, run_grid_id, glyph_scroll_flag);
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
                                    setEmojiClusterFromOverflow(core, rc, r, fb_src_col, fb_scalar);
                                }
                                defer core.emoji_cluster_len = 0;

                                if (core.ensureGlyphPhase2(fb_scalar, c_style)) |fb_ge| {
                                    if (fb_ge.bbox_size_px[0] > 0 and fb_ge.bbox_size_px[1] > 0) {
                                        const fb_baselineY: f32 = baseY + fb_ge.ascent_px;
                                        const fb_gx0: f32 = penX + fb_ge.bbox_origin_px[0];
                                        const fb_gx1: f32 = fb_gx0 + fb_ge.bbox_size_px[0];
                                        const fb_gy0: f32 = fb_baselineY - (fb_ge.bbox_origin_px[1] + fb_ge.bbox_size_px[1]);
                                        const fb_gy1: f32 = fb_gy0 + fb_ge.bbox_size_px[1];

                                        const fb_uv0: [2]f32 = .{ fb_ge.uv_min[0], fb_ge.uv_min[1] };
                                        const fb_uv1: [2]f32 = .{ fb_ge.uv_max[0], fb_ge.uv_min[1] };
                                        const fb_uv2: [2]f32 = .{ fb_ge.uv_min[0], fb_ge.uv_max[1] };
                                        const fb_uv3: [2]f32 = .{ fb_ge.uv_max[0], fb_ge.uv_max[1] };

                                        const fb_glyph_deco: u32 = glyph_scroll_flag | (if (run_has_glow) c_api.DECO_GLOW else 0) | (if (fb_ge.bytes_per_pixel >= 4) c_api.DECO_COLOR_EMOJI else 0);
                                        VH.pushGlyphQuadAssumeCapacity(out, fb_gx0, fb_gy0, fb_gx1, fb_gy1, fb_uv0, fb_uv1, fb_uv2, fb_uv3, fg, vw, vh, run_grid_id, fb_glyph_deco);
                                    }
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
                                    out.ensureUnusedCapacity(core.alloc, @as(usize, blk_geo.count) * 6) catch {
                                        penX += blk_w;
                                        continue;
                                    };
                                    for (blk_geo.rects[0..blk_geo.count]) |rect| {
                                        VH.pushSolidQuadAssumeCapacity(out, penX + rect.x0 * blk_w, blk_y0 + rect.y0 * cellH, penX + rect.x1 * blk_w, blk_y0 + rect.y1 * cellH, fg, vw, vh, run_grid_id, glyph_scroll_flag);
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
                                const hash_idx = @as(usize, hash_val % GLYPH_CACHE_NON_ASCII_SIZE);
                                if (glyph_keys_id.?[hash_idx] == key) {
                                    ge = glyph_cache_id.?[hash_idx];
                                    break :gid_blk true;
                                }
                                if (core.ensureGlyphByID(gid, c_style)) |entry| {
                                    ge = entry;
                                    glyph_cache_id.?[hash_idx] = entry;
                                    glyph_keys_id.?[hash_idx] = key;
                                    break :gid_blk true;
                                }
                                break :gid_blk false;
                            }
                            if (core.ensureGlyphByID(gid, c_style)) |entry| {
                                ge = entry;
                                break :gid_blk true;
                            }
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

                                const fb_cached = if (glyph_cache_non_ascii != null and glyph_keys_non_ascii != null and GLYPH_CACHE_NON_ASCII_SIZE > 0 and next_cluster == this_cluster + 1) blk: {
                                    const fb_idx = @as(usize, fb_hash % GLYPH_CACHE_NON_ASCII_SIZE);
                                    if (glyph_keys_non_ascii.?[fb_idx] == fb_key) {
                                        ge = glyph_cache_non_ascii.?[fb_idx];
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
                                        if (glyph_cache_non_ascii != null and glyph_keys_non_ascii != null and GLYPH_CACHE_NON_ASCII_SIZE > 0 and next_cluster == this_cluster + 1) {
                                            const fb_idx = @as(usize, fb_hash % GLYPH_CACHE_NON_ASCII_SIZE);
                                            glyph_cache_non_ascii.?[fb_idx] = fb_ge;
                                            glyph_keys_non_ascii.?[fb_idx] = fb_key;
                                        }
                                    }
                                }
                            }
                        }

                        // Multi-scalar non-emoji fallback: if glyph-by-ID failed for a
                        // ligature cluster, render each scalar individually to prevent
                        // invisible glyphs where the ligature should appear.
                        if (!glyph_ok and next_cluster > this_cluster + 1 and !cluster_is_emoji) {
                            var mci: u32 = this_cluster;
                            while (mci < next_cluster) : (mci += 1) {
                                const mc_scalar = core.shaping_scalars.items[@intCast(mci)];
                                const mc_col_w = core.shaping_col_widths.items[@intCast(mci)];
                                if (mc_scalar == 32 or mc_scalar == 0) {
                                    penX += @as(f32, @floatFromInt(mc_col_w)) * cellW;
                                    continue;
                                }
                                if (core.ensureGlyphPhase2(mc_scalar, c_style)) |mc_ge| {
                                    if (mc_ge.bbox_size_px[0] > 0 and mc_ge.bbox_size_px[1] > 0) {
                                        const mc_baselineY: f32 = baseY + mc_ge.ascent_px;
                                        const mc_gx0: f32 = penX + mc_ge.bbox_origin_px[0];
                                        const mc_gx1: f32 = mc_gx0 + mc_ge.bbox_size_px[0];
                                        const mc_gy0: f32 = mc_baselineY - (mc_ge.bbox_origin_px[1] + mc_ge.bbox_size_px[1]);
                                        const mc_gy1: f32 = mc_gy0 + mc_ge.bbox_size_px[1];
                                        const mc_uv0: [2]f32 = .{ mc_ge.uv_min[0], mc_ge.uv_min[1] };
                                        const mc_uv1: [2]f32 = .{ mc_ge.uv_max[0], mc_ge.uv_min[1] };
                                        const mc_uv2: [2]f32 = .{ mc_ge.uv_min[0], mc_ge.uv_max[1] };
                                        const mc_uv3: [2]f32 = .{ mc_ge.uv_max[0], mc_ge.uv_max[1] };
                                        const mc_deco: u32 = glyph_scroll_flag | (if (run_has_glow) c_api.DECO_GLOW else 0) | (if (mc_ge.bytes_per_pixel >= 4) c_api.DECO_COLOR_EMOJI else 0);
                                        VH.pushGlyphQuadAssumeCapacity(out, mc_gx0, mc_gy0, mc_gx1, mc_gy1, mc_uv0, mc_uv1, mc_uv2, mc_uv3, fg, vw, vh, run_grid_id, mc_deco);
                                    }
                                }
                                penX += @as(f32, @floatFromInt(mc_col_w)) * cellW;
                            }
                            continue;
                        }

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

                            if (log_enabled and !used_ascii_fast_path) {
                                core.log.write("[glyph_quad] gi={d} gid={d} penX={d:.1} gx0={d:.1} gx1={d:.1} bbox_w={d:.1} bbox_ox={d:.1} x_off={d:.1} cellW={d:.1}\n", .{
                                    gi, gid, penX, gx0, gx1, ge.bbox_size_px[0], ge.bbox_origin_px[0], x_off_px, cellW,
                                });
                            }

                            // Record quad for potential retroactive suppression by later glyphs
                            const vert_start = out.items.len;
                            const glyph_deco: u32 = glyph_scroll_flag | (if (run_has_glow) c_api.DECO_GLOW else 0) | (if (ge.bytes_per_pixel >= 4) c_api.DECO_COLOR_EMOJI else 0);
                            VH.pushGlyphQuadAssumeCapacity(out, gx0, gy0, gx1, gy1, uv0, uv1, uv2, uv3, fg, vw, vh, run_grid_id, glyph_deco);

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
                        if (scalar == 32) {
                            penX += cellW;
                            continue;
                        }
                        if (block_elements.isBlockElement(scalar)) {
                            const blk_geo = block_elements.getBlockGeometry(scalar);
                            if (blk_geo.count > 0) {
                                const blk_y0 = @as(f32, @floatFromInt(r)) * cellH;
                                out.ensureUnusedCapacity(core.alloc, @as(usize, blk_geo.count) * 6) catch {
                                    penX += cellW;
                                    continue;
                                };
                                for (blk_geo.rects[0..blk_geo.count]) |rect| {
                                    VH.pushSolidQuadAssumeCapacity(out, penX + rect.x0 * cellW, blk_y0 + rect.y0 * cellH, penX + rect.x1 * cellW, blk_y0 + rect.y1 * cellH, VH.rgb(run_fg), vw, vh, run_grid_id, glyph_scroll_flag);
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
                            if (scalar < 128 and glyph_cache_ascii != null and glyph_valid_ascii != null) {
                                const cache_key: usize = scalar * 4 + style_index;
                                if (cache_key < GLYPH_CACHE_ASCII_SIZE) {
                                    if (glyph_valid_ascii.?[cache_key]) {
                                        ge = glyph_cache_ascii.?[cache_key];
                                        break :blk true;
                                    }
                                    const ok = if (core.isPhase2Atlas()) cb: {
                                        const cs: u32 = @as(u32, if (cell_style_flags & STYLE_BOLD != 0) c_api.STYLE_BOLD else 0) |
                                            @as(u32, if (cell_style_flags & STYLE_ITALIC != 0) c_api.STYLE_ITALIC else 0);
                                        if (core.ensureGlyphPhase2(scalar, cs)) |entry| {
                                            ge = entry;
                                            break :cb true;
                                        }
                                        break :cb false;
                                    } else if (style_mask != 0 and ensure_styled != null) cb: {
                                        const cs: u32 = @as(u32, if (cell_style_flags & STYLE_BOLD != 0) c_api.STYLE_BOLD else 0) |
                                            @as(u32, if (cell_style_flags & STYLE_ITALIC != 0) c_api.STYLE_ITALIC else 0);
                                        break :cb ensure_styled.?(core.ctx, scalar, cs, &ge) != 0;
                                    } else if (ensure_base) |ensure| cb: {
                                        break :cb ensure(core.ctx, scalar, &ge) != 0;
                                    } else false;
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
                                const hash_idx = @as(usize, hash_val % GLYPH_CACHE_NON_ASCII_SIZE);
                                if (glyph_keys_non_ascii.?[hash_idx] == key) {
                                    ge = glyph_cache_non_ascii.?[hash_idx];
                                    break :blk true;
                                }
                                const ok = if (core.isPhase2Atlas()) cb: {
                                    const cs: u32 = @as(u32, if (cell_style_flags & STYLE_BOLD != 0) c_api.STYLE_BOLD else 0) |
                                        @as(u32, if (cell_style_flags & STYLE_ITALIC != 0) c_api.STYLE_ITALIC else 0);
                                    if (core.ensureGlyphPhase2(scalar, cs)) |entry| {
                                        ge = entry;
                                        break :cb true;
                                    }
                                    break :cb false;
                                } else if (style_mask != 0 and ensure_styled != null) cb: {
                                    const cs: u32 = @as(u32, if (cell_style_flags & STYLE_BOLD != 0) c_api.STYLE_BOLD else 0) |
                                        @as(u32, if (cell_style_flags & STYLE_ITALIC != 0) c_api.STYLE_ITALIC else 0);
                                    break :cb ensure_styled.?(core.ctx, scalar, cs, &ge) != 0;
                                } else if (ensure_base) |ensure| cb: {
                                    break :cb ensure(core.ctx, scalar, &ge) != 0;
                                } else false;
                                if (ok) {
                                    glyph_cache_non_ascii.?[hash_idx] = ge;
                                    glyph_keys_non_ascii.?[hash_idx] = key;
                                }
                                break :blk ok;
                            }
                            const ok = if (core.isPhase2Atlas()) cb: {
                                const cs: u32 = @as(u32, if (cell_style_flags & STYLE_BOLD != 0) c_api.STYLE_BOLD else 0) |
                                    @as(u32, if (cell_style_flags & STYLE_ITALIC != 0) c_api.STYLE_ITALIC else 0);
                                if (core.ensureGlyphPhase2(scalar, cs)) |entry| {
                                    ge = entry;
                                    break :cb true;
                                }
                                break :cb false;
                            } else if (style_mask != 0 and ensure_styled != null) cb: {
                                const cs: u32 = @as(u32, if (cell_style_flags & STYLE_BOLD != 0) c_api.STYLE_BOLD else 0) |
                                    @as(u32, if (cell_style_flags & STYLE_ITALIC != 0) c_api.STYLE_ITALIC else 0);
                                break :cb ensure_styled.?(core.ctx, scalar, cs, &ge) != 0;
                            } else if (ensure_base) |ensure| cb: {
                                break :cb ensure(core.ctx, scalar, &ge) != 0;
                            } else false;
                            break :blk ok;
                        };
                        if (!glyph_ok) {
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
                            VH.pushGlyphQuadAssumeCapacity(out, gx0, gy0, gx1, gy1, uv0, uv1, uv2, uv3, fg, vw, vh, run_grid_id, pc_glyph_deco);
                        }

                        penX += cellW;
                    }
                } // end else (per-cell fallback)
            }

            c = end;
        }
    }

    // ── Pass 4: Strikethrough ───────────────────────────────────────
    {
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

            const run_end: u32 = @intCast(@min(
                simdFindRunEndU8(rc.style_flags_arr.items, @intCast(c + 1), @intCast(cols), run_flags),
                @min(
                    simdFindRunEndU32(rc.sp_rgbs.items, @intCast(c + 1), @intCast(cols), run_sp),
                    simdFindRunEndI64(rc.grid_ids.items, @intCast(c + 1), @intCast(cols), run_grid_id),
                ),
            ));

            const deco_color = if (run_sp != highlight.Highlights.SP_NOT_SET) VH.rgb(run_sp) else VH.rgb(run_fg);
            const strike_scroll_flag: u32 = rc.deco_base_flags.items[@intCast(c)];
            const x0: f32 = @as(f32, @floatFromInt(run_start)) * cellW;
            const x1: f32 = @as(f32, @floatFromInt(run_end)) * cellW;
            const row_y: f32 = @as(f32, @floatFromInt(r)) * cellH;

            const sy0 = row_y + cellH * 0.5 - 0.5;
            const sy1 = sy0 + 1.0;
            try VH.pushDecoQuad(out, core.alloc, x0, sy0, x1, sy1, deco_color, vw, vh, run_grid_id, c_api.DECO_STRIKETHROUGH | strike_scroll_flag, 0);

            c = run_end;
        }
    }

    // ── Pass 5: Overline ────────────────────────────────────────────
    {
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

            var run_end: u32 = c + 1;
            while (run_end < cols) : (run_end += 1) {
                if (rc.overline_arr.items[@intCast(run_end)] == 0) break;
                if (rc.sp_rgbs.items[@intCast(run_end)] != run_sp) break;
                if (rc.grid_ids.items[@intCast(run_end)] != run_grid_id) break;
                if (run_sp == highlight.Highlights.SP_NOT_SET and
                    rc.fg_rgbs.items[@intCast(run_end)] != run_fg) break;
            }

            const deco_color = if (run_sp != highlight.Highlights.SP_NOT_SET) VH.rgb(run_sp) else VH.rgb(run_fg);
            const ol_scroll_flag: u32 = rc.deco_base_flags.items[@intCast(c)];
            const x0: f32 = @as(f32, @floatFromInt(run_start)) * cellW;
            const x1: f32 = @as(f32, @floatFromInt(run_end)) * cellW;
            const row_y: f32 = @as(f32, @floatFromInt(r)) * cellH;

            const oy0 = row_y;
            const oy1 = oy0 + 1.0;
            try VH.pushDecoQuad(out, core.alloc, x0, oy0, x1, oy1, deco_color, vw, vh, run_grid_id, c_api.DECO_OVERLINE | ol_scroll_flag, 0);

            c = run_end;
        }
    }

    return stats;
}

pub const FlushCtx = struct {
    core: *Core,

    pub fn onFlush(ctx: *FlushCtx, rows: u32, cols: u32) !void {
        const n_cells: usize = @as(usize, rows) * @as(usize, cols);
        if (n_cells == 0) return;

        // === PERF LOG: flush開始 ===
        const perf_enabled = ctx.core.log.cb != null;
        var t_flush_start: i128 = 0;
        if (perf_enabled) {
            t_flush_start = std.time.nanoTimestamp();
        }
        defer {
            if (perf_enabled) {
                const t_flush_end = std.time.nanoTimestamp();
                const flush_us: i64 = @intCast(@divTrunc(@max(0, t_flush_end - t_flush_start), 1000));
                ctx.core.log.write("[perf] flush_total rows={d} cols={d} us={d}\n", .{ rows, cols, flush_us });
            }
        }

        ctx.core.missing_glyph_log_count = 0;

        // Cache glow state once per flush — these don't change while grid_mu is held.
        const glow_enabled = ctx.core.glow_enabled.load(.acquire);
        const glow_all = ctx.core.glow_all;
        const glow_hl_ids = if (ctx.core.glow_hl_ids) |*m| m else null;

        // Notify frontend about scrolled grids BEFORE vertex generation.
        // This allows Swift to clear pixel offsets before new vertices are rendered,
        // preventing double-shift glitches in split windows.
        const scrolled_count = ctx.core.grid.scrolled_grid_count;
        // Snapshot scrolled grid IDs before clearScrolledGrids() zeroes the array
        var scrolled_ids_snapshot: [16]i64 = undefined;
        if (scrolled_count > 0) {
            @memcpy(scrolled_ids_snapshot[0..scrolled_count], ctx.core.grid.scrolled_grid_ids[0..scrolled_count]);
        }
        if (perf_enabled and scrolled_count > 0) {
            ctx.core.log.write("[scroll_debug] flush_begin scrolled_grids={d} content_rev={d} dirty_all={any}\n", .{
                scrolled_count, ctx.core.grid.content_rev, ctx.core.grid.dirty_all,
            });
        }
        // Reset flush_aborted BEFORE calling on_flush_begin
        // (the callback may set it via zonvie_core_abort_flush)
        ctx.core.flush_aborted = false;

        // Notify frontend: flush begins (for triple buffer write-set preparation)
        if (ctx.core.cb.on_flush_begin) |cb| {
            cb(ctx.core.ctx);
        }
        // Ensure on_flush_end is called on all exit paths (atomic commit point)
        defer {
            if (ctx.core.cb.on_flush_end) |cb| {
                cb(ctx.core.ctx);
            }
        }
        // Generate external grid vertices inside the flush bracket (LIFO: runs
        // before on_flush_end). This ensures the frontend receives vertex data
        // before commitFlush, preventing draw() from rendering remapped slots
        // with stale vertex content.
        defer {
            if (!ctx.core.flush_aborted) {
                sendExternalGridVertices(ctx.core, false);
            }
        }

        // If frontend aborted, skip all vertex/atlas work.
        // Grid scroll events are NOT dispatched or cleared — they are preserved
        // for the retry flush so smooth-scroll offsets stay in sync with vertices.
        if (ctx.core.flush_aborted) return;

        // Dispatch grid_scroll events AFTER abort check so they are preserved on retry.
        if (ctx.core.cb.on_grid_scroll) |cb| {
            for (ctx.core.grid.scrolled_grid_ids[0..scrolled_count]) |grid_id| {
                cb(ctx.core.ctx, grid_id);
            }
        }

        // Dispatch per-grid row scroll notifications for external grids.
        // Fires at the same dispatch point as on_grid_scroll (after abort check).
        // Skipped when multiple scrolls occurred in the same batch (fast path ineligible).
        // Also skipped when float windows are anchored to the grid, because the core
        // composites float content into the grid's row vertices — GPU-blitting old pixels
        // would shift stale overlay content to wrong positions.
        // last_scroll_op is cleared later by sg.clearDirty(), not here.
        if (ctx.core.cb.on_grid_row_scroll) |scroll_cb| {
            for (ctx.core.grid.scrolled_grid_ids[0..scrolled_count]) |grid_id| {
                if (grid_id < 2) continue;
                if (ctx.core.grid.sub_grids.getPtr(grid_id)) |sg| {
                    if (sg.scroll_fast_path_blocked) continue;

                    // Check for float windows anchored to this grid
                    var has_float_overlay = false;
                    var wp_it = ctx.core.grid.win_pos.iterator();
                    while (wp_it.next()) |wp_entry| {
                        if (wp_entry.value_ptr.anchor_grid == grid_id) {
                            has_float_overlay = true;
                            break;
                        }
                    }
                    if (has_float_overlay) continue;

                    if (sg.last_scroll_op) |op| {
                        // Clamp scroll region to viewport dimensions.
                        // External grids may have sg.rows > viewport_rows due to
                        // margin rows (e.g. winbar). The frontend's texture and blit
                        // only cover viewport_rows, so unclamped parameters would cause
                        // out-of-bounds blit reads and wrong vacated rows.
                        const ext_target = ctx.core.grid.external_grid_target_sizes.get(grid_id);
                        const vp_rows = if (ext_target) |t| t.rows else sg.rows;
                        const vp_cols = if (ext_target) |t| t.cols else sg.cols;
                        const clamped_bot = @min(op.bot, vp_rows);
                        if (clamped_bot > op.top) {
                            scroll_cb(ctx.core.ctx, grid_id,
                                op.top, clamped_bot, op.left, op.right,
                                op.rows, vp_rows, vp_cols);
                        }
                    }
                }
            }
        }

        ctx.core.grid.clearScrolledGrids();

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
        if (ctx.core.cb.on_vertices_partial != null) {
            const pf_opt = ctx.core.cb.on_vertices_partial;

            // Decide what needs rebuilding/sending.
            const need_main: bool = (ctx.core.grid.content_rev != ctx.core.last_sent_content_rev);
            const need_cursor: bool = (ctx.core.grid.cursor_rev != ctx.core.last_sent_cursor_rev);

            // If nothing changed, avoid doing any work.
            if (!need_main and !need_cursor) {
                ctx.core.grid.clearDirty();
                ctx.core.grid.clearScrollState();
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

            const lineSpacePx: u32 = ctx.core.linespace_px;
            const topPadPx: u32 = lineSpacePx / 2;
            const topPad: f32 = @floatFromInt(topPadPx);

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
                    x0: f32, y0: f32, x1: f32, y1: f32,
                    col: [4]f32,
                    vw: f32, vh: f32,
                    grid_id: i64,
                    base_deco_flags: u32,
                ) !void {
                    const pts = ndc4(x0, y0, x1, y1, vw, vh);
                    const p0 = pts[0]; const p1 = pts[1]; const p2 = pts[2]; const p3 = pts[3];

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
                    x0: f32, y0: f32, x1: f32, y1: f32,
                    col: [4]f32,
                    vw: f32, vh: f32,
                    grid_id: i64,
                    base_deco_flags: u32,
                ) void {
                    const pts = ndc4(x0, y0, x1, y1, vw, vh);
                    const p0 = pts[0]; const p1 = pts[1]; const p2 = pts[2]; const p3 = pts[3];

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
                    x0: f32, y0: f32, x1: f32, y1: f32,
                    uv0: [2]f32, uv1: [2]f32, uv2: [2]f32, uv3: [2]f32,
                    col: [4]f32,
                    vw: f32, vh: f32,
                    grid_id: i64,
                    base_deco_flags: u32,
                ) !void {
                    try out.ensureUnusedCapacity(alloc, 6);
                    pushGlyphQuadAssumeCapacity(out, x0, y0, x1, y1, uv0, uv1, uv2, uv3, col, vw, vh, grid_id, base_deco_flags);
                }

                /// Same as pushGlyphQuad but caller guarantees capacity.
                fn pushGlyphQuadAssumeCapacity(
                    out: *std.ArrayListUnmanaged(c_api.Vertex),
                    x0: f32, y0: f32, x1: f32, y1: f32,
                    uv0: [2]f32, uv1: [2]f32, uv2: [2]f32, uv3: [2]f32,
                    col: [4]f32,
                    vw: f32, vh: f32,
                    grid_id: i64,
                    base_deco_flags: u32,
                ) void {
                    const pts = ndc4(x0, y0, x1, y1, vw, vh);
                    const p0 = pts[0]; const p1 = pts[1]; const p2 = pts[2]; const p3 = pts[3];

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
                    x0: f32, y0: f32, x1: f32, y1: f32,
                    col: [4]f32,
                    vw: f32, vh: f32,
                    grid_id: i64,
                    deco_flags: u32,
                    deco_phase: f32,
                ) !void {
                    const pts = ndc4(x0, y0, x1, y1, vw, vh);
                    const p0 = pts[0]; const p1 = pts[1]; const p2 = pts[2]; const p3 = pts[3];

                    // UV coordinates for decorations:
                    // - UV.x = -1 (sentinel for solid/decoration)
                    // - UV.y = local Y position within quad (0.0 at top, 1.0 at bottom)
                    // This allows the shader to know the fragment's position within the quad
                    const uv_top: [2]f32 = .{ -1.0, 0.0 };    // y0 vertices (top)
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

                /// Compute DECO_SCROLLABLE flag for a cell at global grid row `r` with the given grid_id.
                /// For grid_id=1, uses the pre-computed main_scrollable flag.
                /// For sub-grids, checks the sub-grid's own viewport margins.
                fn computeScrollFlag(
                    r: u32,
                    run_grid_id: i64,
                    main_scrollable: u32,
                    cached_sgs: []const CachedSubgrid,
                ) u32 {
                    if (run_grid_id == 1) return main_scrollable;
                    for (cached_sgs) |csg| {
                        if (csg.grid_id == run_grid_id) {
                            const internal_row = r -| csg.row_start;
                            if (internal_row >= csg.margin_top and internal_row < csg.sg_rows -| csg.margin_bottom)
                                return c_api.DECO_SCROLLABLE;
                            return 0;
                        }
                    }
                    return c_api.DECO_SCROLLABLE; // Unknown grid: default scrollable
                }
            };

            var sent_main_by_rows: bool = false;

            // Pre-compute subgrid info — declared outside need_main so the
            // snapshot is accessible for saveSubgridSnapshots in all exit paths.
            var cached_subgrids: [MAX_CACHED_SUBGRIDS]CachedSubgrid = undefined;
            var cached_subgrid_count: usize = 0;

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

                    // Sort back-to-front: smaller first, larger last (insertion sort)
                    {
                        var j: usize = 1;
                        while (j < ctx.core.grid_entries.items.len) : (j += 1) {
                            const key = ctx.core.grid_entries.items[j];
                            var k: usize = j;
                            while (k > 0) {
                                const prev = ctx.core.grid_entries.items[k - 1];

                                const less =
                                    (key.zindex < prev.zindex) or
                                    (key.zindex == prev.zindex and key.compindex < prev.compindex) or
                                    (key.zindex == prev.zindex and key.compindex == prev.compindex and key.order < prev.order) or
                                    (key.zindex == prev.zindex and key.compindex == prev.compindex and key.order == prev.order and key.grid_id < prev.grid_id);

                                if (!less) break;

                                ctx.core.grid_entries.items[k] = prev;
                                k -= 1;
                            }
                            ctx.core.grid_entries.items[k] = key;
                        }
                    }
                }

                // Pre-compute subgrid info (shared by row-mode and non-row-mode paths).
                // Caches win_pos/sub_grids lookups and viewport margins to avoid
                // per-row hash map access during vertex generation.
                for (ctx.core.grid_entries.items) |ent| {
                    if (cached_subgrid_count >= MAX_CACHED_SUBGRIDS) break;
                    const subgrid_id = ent.grid_id;
                    const pos = ctx.core.grid.win_pos.get(subgrid_id) orelse continue;
                    const sg = ctx.core.grid.sub_grids.get(subgrid_id) orelse continue;

                    // Skip float windows anchored to external grids
                    if (pos.anchor_grid != 1 and ctx.core.grid.external_grids.contains(pos.anchor_grid)) continue;

                    const sg_margins = ctx.core.grid.getViewportMargins(subgrid_id);
                    cached_subgrids[cached_subgrid_count] = .{
                        .grid_id = subgrid_id,
                        .row_start = pos.row,
                        .row_end = pos.row + sg.rows,
                        .col_start = pos.col,
                        .sg_cols = sg.cols,
                        .sg_rows = sg.rows,
                        .cells = sg.cells.ptr,
                        .margin_top = sg_margins.top,
                        .margin_bottom = sg_margins.bottom,
                    };
                    cached_subgrid_count += 1;
                }

                // -------------------------------------------------
                // Row callback mode: send only dirty rows (global grid)
                // -------------------------------------------------

                const use_row_mode = (ctx.core.cb.on_vertices_row != null);
                if (use_row_mode) {
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
                        t_rows_start_ns = std.time.nanoTimestamp();
                    }

                    // Scroll-aware flush diagnostics: log scroll state and fast-path eligibility
                    if (log_enabled and scrolled_count > 0) {
                        const cached_sg_count = ctx.core.grid_entries.items.len;
                        ctx.core.log.write(
                            "[scroll_debug] flush_row_mode dirty_rows={d} rebuild_all={any} scrolled_count={d} scrolled_grid_ids[0]={d} subgrid_count={d} cursor_row={d} cursor_col={d}\n",
                            .{ log_dirty_rows, rebuild_all, scrolled_count, scrolled_ids_snapshot[0], cached_sg_count, ctx.core.grid.cursor_row, ctx.core.grid.cursor_col },
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

                    // Initialize dynamic caches if not already done
                    var t_prep_hl_init_start: i128 = 0;
                    if (log_enabled) t_prep_hl_init_start = std.time.nanoTimestamp();
                    ctx.core.initHlCache() catch {
                        ctx.core.log.write("[flush] Failed to initialize hl cache\n", .{});
                    };
                    if (log_enabled) {
                        const t_prep_hl_init_end = std.time.nanoTimestamp();
                        perf_row_prep_hl_init_us = @intCast(@divTrunc(@max(0, t_prep_hl_init_end - t_prep_hl_init_start), 1000));
                    }
                    var t_prep_glyph_init_start: i128 = 0;
                    if (log_enabled) t_prep_glyph_init_start = std.time.nanoTimestamp();
                    ctx.core.initGlyphCache() catch {
                        ctx.core.log.write("[flush] Failed to initialize glyph cache\n", .{});
                    };
                    if (log_enabled) {
                        const t_prep_glyph_init_end = std.time.nanoTimestamp();
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
                    if (log_enabled) t_prep_scroll_ensure_start = std.time.nanoTimestamp();
                    ctx.core.ensureScrollCache(rows) catch {};
                    if (log_enabled) {
                        const t_prep_scroll_ensure_end = std.time.nanoTimestamp();
                        perf_row_prep_scroll_ensure_us = @intCast(@divTrunc(@max(0, t_prep_scroll_ensure_end - t_prep_scroll_ensure_start), 1000));
                    }

                    var saw_atlas_reset: bool = false;
                    var atlas_retried: bool = false;
                    var atlas_retry_aborted: bool = false;
                    var used_scroll_fast_path: bool = false;

                    retry_loop: while (true) {
                        // On retry: force all rows (stale UVs in non-dirty rows too)
                        const effective_rebuild_all = rebuild_all or atlas_retried;
                        if (atlas_retried) {
                            // Reset all per-pass mutable state for clean retry
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
                            perf_row_max_total_us = 0;
                            perf_row_max_total_idx = 0;
                            perf_row_max_cb_us = 0;
                            perf_row_max_cb_idx = 0;
                            if (log_enabled) {
                                log_dirty_rows = rows; // Retry processes all rows
                                t_rows_start_ns = std.time.nanoTimestamp();
                            }
                            // hl_valid does NOT need reset: hl data is atlas-independent
                            // glyph caches already cleared by resetGlyphCacheFlags() inside resetCoreAtlas()
                        }

                    // Scroll-aware fast path eligibility check
                    var t_prep_fast_path_check_start: i128 = 0;
                    if (log_enabled) t_prep_fast_path_check_start = std.time.nanoTimestamp();
                    const scroll_check = checkScrollFastPath(
                        &ctx.core.grid,
                        effective_rebuild_all,
                        atlas_retried,
                        @intCast(scrolled_count),
                        cached_subgrids[0..cached_subgrid_count],
                    );
                    if (log_enabled) {
                        const t_prep_fast_path_check_end = std.time.nanoTimestamp();
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
                    var regen_rows: [32]u32 = undefined; // 8 touched + cursor + non-scroll dirty rows
                    var regen_count: u32 = 0;
                    var use_scroll_fast_path = scroll_check.eligible and !atlas_retried;

                    if (use_scroll_fast_path) {
                        var t_prep_regen_build_start: i128 = 0;
                        if (log_enabled) t_prep_regen_build_start = std.time.nanoTimestamp();
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
                            const t_prep_regen_build_end = std.time.nanoTimestamp();
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
                                    if (rr == dr) { found = true; break; }
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
                                    cached_subgrids[0..cached_subgrid_count],
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
                        var cached_empty_rows: u32 = 0;

                        if (cache_ready) {
                            // position[1] is NDC: ndc_y = 1.0 - (y_px / dh) * 2.0
                            // delta_ndc_y = scroll_rows * cellH / dh * 2.0
                            const delta_y: f32 = @as(f32, @floatFromInt(scroll_op.rows)) * cellH / dh * 2.0;
                            const scroll_top: usize = @intCast(scroll_op.top + scroll_op.win_pos_row);
                            const scroll_bot: usize = @intCast(scroll_op.bot + scroll_op.win_pos_row);

                            var t_prep_shift_start: i128 = 0;
                            if (log_enabled) t_prep_shift_start = std.time.nanoTimestamp();
                            const shift_result = shiftScrollCacheAndValidate(
                                ctx.core,
                                scroll_top,
                                scroll_bot,
                                scroll_op.rows,
                                delta_y,
                                rows,
                                regen_rows[0..regen_count],
                            );
                            if (log_enabled) {
                                const t_prep_shift_end = std.time.nanoTimestamp();
                                perf_row_prep_shift_us = @intCast(@divTrunc(@max(0, t_prep_shift_end - t_prep_shift_start), 1000));
                            }
                            cached_empty_rows = shift_result.empty_emit_count;

                            if (!shift_result.fast_path_ok) {
                                use_scroll_fast_path = false;
                                if (log_enabled) {
                                    ctx.core.log.write("[scroll_debug] fast_path cancelled: non-regen rows have invalid cache\n", .{});
                                }
                            }
                        }

                        // Record final fast path decision for perf logging
                        used_scroll_fast_path = use_scroll_fast_path and cache_ready;

                        // Frontends that support main-row scroll shifting can update their
                        // row storage in one callback and avoid per-row cached emission.
                        if (used_scroll_fast_path) {
                            if (cached_empty_rows == 0) {
                                if (ctx.core.cb.on_main_row_scroll) |scroll_cb| {
                                    scroll_cb(
                                        ctx.core.ctx,
                                        scroll_op.top + scroll_op.win_pos_row,
                                        scroll_op.bot + scroll_op.win_pos_row,
                                        scroll_op.left,
                                        scroll_op.right,
                                        scroll_op.rows,
                                        rows,
                                        cols,
                                    );
                                } else {
                                    var t_cached_emit_scan_start: i128 = 0;
                                    if (log_enabled) t_cached_emit_scan_start = std.time.nanoTimestamp();
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
                                            if (log_enabled) t_cached_emit_cb_start = std.time.nanoTimestamp();
                                            row_cb(ctx.core.ctx, 1, row_idx, 1, ptr, cached.items.len, 1, rows, cols);
                                            if (log_enabled) {
                                                const t_cached_emit_cb_end = std.time.nanoTimestamp();
                                                perf_cached_emit_cb_sum_us += @intCast(@divTrunc(@max(0, t_cached_emit_cb_end - t_cached_emit_cb_start), 1000));
                                            }
                                        }
                                    }
                                    if (log_enabled) {
                                        const t_cached_emit_scan_end = std.time.nanoTimestamp();
                                        perf_cached_emit_scan_us = @intCast(@divTrunc(@max(0, t_cached_emit_scan_end - t_cached_emit_scan_start), 1000));
                                    }
                                }
                            } else {
                                var t_cached_emit_scan_start: i128 = 0;
                                if (log_enabled) t_cached_emit_scan_start = std.time.nanoTimestamp();
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
                                        if (log_enabled) t_cached_emit_cb_start = std.time.nanoTimestamp();
                                        row_cb(ctx.core.ctx, 1, row_idx, 1, ptr, cached.items.len, 1, rows, cols);
                                        if (log_enabled) {
                                            const t_cached_emit_cb_end = std.time.nanoTimestamp();
                                            perf_cached_emit_cb_sum_us += @intCast(@divTrunc(@max(0, t_cached_emit_cb_end - t_cached_emit_cb_start), 1000));
                                        }
                                    }
                                }
                                if (log_enabled) {
                                    const t_cached_emit_scan_end = std.time.nanoTimestamp();
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
                        if (use_scroll_fast_path) {
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

                        // Compute scrollable flag for this row: content rows get DECO_SCROLLABLE, margin rows (tabline/statusline) do not
                        const main_scrollable: u32 = if (r >= main_margins.top and r < rows -| main_margins.bottom) c_api.DECO_SCROLLABLE else 0;

                        var out = &ctx.core.row_verts;
                        out.clearRetainingCapacity();
                        var row_compose_us: i64 = 0;

                        // Row-mode timing for composition measurement
                        var t_row_compose_start: i128 = 0;
                        if (log_enabled) {
                            t_row_compose_start = std.time.nanoTimestamp();
                        }

                        // Compose this row only (avoid full-screen tmp)
                        // SIMD-optimized: batch process consecutive cells with same hl_id
                        {
                            const row_start: usize = @as(usize, r) * @as(usize, cols);
                            const grid_cells = ctx.core.grid.cells;
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

                            // Overlay sub-grids using pre-cached info (avoids per-row hash map lookups)
                            for (cached_subgrids[0..cached_subgrid_count]) |csg| {
                                // Fast row range check using cached bounds
                                if (r < csg.row_start or r >= csg.row_end) continue;
                                const r2: u32 = r - csg.row_start;

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
                                    if (glow_enabled) {
                                        row_cells.glow_arr.items[@intCast(tc)] = if (glow_all) 1 else if (glow_hl_ids) |ids| (if (ids.contains(cell.hl)) @as(u8, 1) else 0) else 0;
                                    }
                                }
                            }
                        }

                        // Populate deco_base_flags via computeScrollFlag
                        for (0..cols) |ci| {
                            const gid = row_cells.grid_ids.items[ci];
                            row_cells.deco_base_flags.items[ci] = Helpers.computeScrollFlag(r, gid, main_scrollable, cached_subgrids[0..cached_subgrid_count]);
                        }

                        // Row-mode timing
                        var t_row_compose_end: i128 = 0;
                        var t_row_gen_start: i128 = 0;
                        if (log_enabled) {
                            t_row_compose_end = std.time.nanoTimestamp();
                            t_row_gen_start = t_row_compose_end;
                        }

                        // Unified 5-pass vertex generation.
                        // On error (e.g. buffer allocation failure), skip this row
                        // so partial vertices are not cached or sent to the frontend.
                        // markAllDirty at the end of the flush ensures a retry.
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
                        }, out) catch {
                            out.clearRetainingCapacity();
                            had_glyph_miss = true;
                            continue;
                        };
                        had_glyph_miss = had_glyph_miss or row_gen_stats.had_glyph_miss;
                        perf_shape_cache_hits += row_gen_stats.shape_cache_hits;
                        perf_shape_cache_misses += row_gen_stats.shape_cache_misses;
                        perf_ascii_fast_path += row_gen_stats.ascii_fast_path_runs;
                        // Log row timing for performance measurement
                        if (log_enabled) {
                            const t_row_gen_end = std.time.nanoTimestamp();
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
                            ctx.core.log.write(
                                "[perf] row_mode row={d} cols={d} compose_us={d} gen_us={d} shape_us={d} shape_calls={d} sc_hit={d} sc_miss={d} ascii={d} total_us={d}\n",
                                .{ r, cols, row_compose_us, gen_us, row_gen_stats.shape_us, row_gen_stats.shape_calls, row_gen_stats.shape_cache_hits, row_gen_stats.shape_cache_misses, row_gen_stats.ascii_fast_path_runs, total_us },
                            );
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
                            // Already retried: clear all previously-sent rows (they carry
                            // stale UVs) then abort. Send vert_count=0 for every row so
                            // frontends replace stale vertex data with empty buffers.
                            // markAllDirty (after the loop) ensures the next flush
                            // regenerates everything against the fresh atlas.
                            atlas_retry_aborted = true;
                            if (log_enabled) {
                                ctx.core.log.write(
                                    "[scroll_debug] atlas_reset_during_flush at row={d} on retry: clearing all rows and aborting\n",
                                    .{r},
                                );
                            }
                            for (0..rows) |clear_row| {
                                row_cb(ctx.core.ctx, 1, @intCast(clear_row), 1, null, 0, 1, rows, cols);
                            }
                            break;
                        }

                        var t_row_post_misc_before_cache_store: i128 = 0;
                        var t_row_cache_store_end: i128 = 0;
                        if (log_enabled) {
                            t_row_post_misc_before_cache_store = std.time.nanoTimestamp();
                        }

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
                            t_row_cache_store_end = std.time.nanoTimestamp();
                            t_row_before_cb = t_row_cache_store_end;
                        }

                        // Contract: row_count == 1, grid_id == 1 for main window
                        row_cb(ctx.core.ctx, 1, r, 1, out.items.ptr, out.items.len, 1, rows, cols); // grid_id=1 (main), flags=1 (ZONVIE_VERT_UPDATE_MAIN)

                        if (log_enabled) {
                            const t_row_after_cb = std.time.nanoTimestamp();
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
                            ctx.core.log.write(
                                "[perf] row_mode_post row={d} cache_store_us={d} row_cb_us={d} post_misc_us={d}\n",
                                .{ r, cache_store_us, row_cb_us, post_misc_us },
                            );
                        }
                    }
                    break; // Normal exit from retry_loop
                    }

                    // Snapshot overlay coverage for next flush's diff detection.
                    saveSubgridSnapshots(ctx.core, cached_subgrids[0..cached_subgrid_count]);

                    ctx.core.grid.clearDirty();
                    ctx.core.grid.clearScrollState();
                    if (had_glyph_miss or saw_atlas_reset) {
                        ctx.core.grid.markAllDirty();
                        // Atlas reset invalidates cached UVs in scroll cache — but only
                        // when the retry was aborted (partial/stale data) or no retry ran.
                        // When the retry succeeded, all rows were regenerated with the
                        // fresh atlas, so scroll cache entries are already valid.
                        // Invalidating here would undo that work and force a full
                        // regeneration on the next scroll flush (~65-80ms for CJK).
                        if (saw_atlas_reset) {
                            if (!atlas_retried or atlas_retry_aborted) {
                                ctx.core.invalidateScrollCache();
                            }
                            var sg_it = ctx.core.grid.sub_grids.valueIterator();
                            while (sg_it.next()) |sg| {
                                sg.dirty = true;
                            }
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
                    ctx.core.last_sent_content_rev = ctx.core.grid.content_rev;
                    if (log_enabled) {
                        const t_rows_done_ns: i128 = std.time.nanoTimestamp();
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

                    // 1) draw global grid(1) with RLE batching + hl_cache
                    const grid_cells = ctx.core.grid.cells;
                    var row_i: u32 = 0;
                    while (row_i < rows) : (row_i += 1) {
                        const row_start: usize = @as(usize, row_i) * @as(usize, cols);
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

                        // Skip float windows anchored to external grids (they belong to that external window)
                        if (pos.anchor_grid != 1 and ctx.core.grid.external_grids.contains(pos.anchor_grid)) continue;

                        var r2: u32 = 0;
                        while (r2 < sg.rows) : (r2 += 1) {
                            const tr = pos.row + r2;
                            if (tr >= rows) break;

                            const sg_row_start: usize = @as(usize, r2) * @as(usize, sg.cols);
                            const dst_row_start: usize = @as(usize, tr) * @as(usize, cols);
                            var c2: u32 = 0;

                            while (c2 < sg.cols) {
                                const tc = pos.col + c2;
                                if (tc >= cols) break;

                                const first_cell = sg.cells[sg_row_start + @as(usize, c2)];
                                const run_hl = first_cell.hl;

                                // Find run of consecutive subgrid cells with same hl_id
                                var run_end: u32 = c2 + 1;
                                while (run_end < sg.cols and pos.col + run_end < cols) : (run_end += 1) {
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
                                    const ti = pos.col + i;
                                    if (ti >= cols) break;

                                    const src_cell = sg.cells[sg_row_start + @as(usize, i)];
                                    tmp.set(dst_row_start + @as(usize, ti), src_cell.cp, fg, bg, sp, subgrid_id, flags, ol);
                                }

                                c2 = run_end;
                            }
                        }
                    }
                }



                if (!sent_main_by_rows) {

                    // Estimate capacity: rows*cols*12 vertices (BG + glyph) + glow
                    const est_cells: usize = @as(usize, rows) * @as(usize, cols);
                    _ = main.ensureTotalCapacity(ctx.core.alloc, est_cells * 12) catch {};

                    // Get viewport margins for scrollable row detection (non-row-mode path)
                    const nr_main_margins = ctx.core.grid.getViewportMargins(1);

                    // 1) Background: run-length by bgRGB and grid_id per row
                    var r: u32 = 0;

                    while (r < rows) : (r += 1) {
                        const nr_main_scrollable: u32 = if (r >= nr_main_margins.top and r < rows -| nr_main_margins.bottom) c_api.DECO_SCROLLABLE else 0;
                        const row_start: usize = @as(usize, r) * @as(usize, cols);

                        var c: u32 = 0;
                        while (c < cols) {
                            const run_bg = tmp.bg_rgbs.items[row_start + @as(usize, c)];
                            const run_grid_id = tmp.grid_ids.items[row_start + @as(usize, c)];
                            const run_start = c;

                            const end: u32 = @intCast(@min(
                                simdFindRunEndU32(tmp.bg_rgbs.items[row_start..], @intCast(c), @intCast(cols), run_bg),
                                simdFindRunEndI64(tmp.grid_ids.items[row_start..], @intCast(c), @intCast(cols), run_grid_id),
                            ));

                            const x0: f32 = @as(f32, @floatFromInt(run_start)) * cellW;
                            const x1: f32 = @as(f32, @floatFromInt(end)) * cellW;
                            const y0: f32 = @as(f32, @floatFromInt(r)) * cellH;
                            const y1: f32 = y0 + cellH;

                            // Use transparency for default background (blur or background_opacity)
                            const bg_alpha: f32 = if (run_bg == ctx.core.hl.default_bg)
                                (if (ctx.core.blur_enabled) 0.0 else ctx.core.background_opacity)
                            else
                                1.0;
                            const nr_scroll_flag: u32 = Helpers.computeScrollFlag(r, run_grid_id, nr_main_scrollable, cached_subgrids[0..cached_subgrid_count]);
                            try Helpers.pushSolidQuad(main, ctx.core.alloc, x0, y0, x1, y1, Helpers.rgba(run_bg, bg_alpha), dw, dh, run_grid_id, nr_scroll_flag);
                            c = end;
                        }
                    }

                    // Timing for performance measurement (only when logging enabled)
                    const perf_log_enabled = ctx.core.log.cb != null;
                    var t_under_deco_start: i128 = 0;
                    if (perf_log_enabled) {
                        t_under_deco_start = std.time.nanoTimestamp();
                    }

                    // 2) Under-decorations: underline, underdouble, undercurl, underdotted, underdashed (drawn BEHIND glyphs)
                    {
                        var r2: u32 = 0;
                        while (r2 < rows) : (r2 += 1) {
                            const row_start: usize = @as(usize, r2) * @as(usize, cols);
                            const nr_r2_scrollable: u32 = if (r2 >= nr_main_margins.top and r2 < rows -| nr_main_margins.bottom) c_api.DECO_SCROLLABLE else 0;

                            var c: u32 = 0;
                            while (c < cols) {
                                const cell_sf = tmp.style_flags_arr.items[row_start + @as(usize, c)];
                                // Check for any under-decoration (not strikethrough)
                                const under_mask = STYLE_UNDERLINE | STYLE_UNDERDOUBLE | STYLE_UNDERCURL | STYLE_UNDERDOTTED | STYLE_UNDERDASHED;
                                if (cell_sf & under_mask == 0) {
                                    c += 1;
                                    continue;
                                }

                                // Find run of cells with same decoration style
                                const run_start = c;
                                const run_flags = cell_sf;
                                const run_sp = tmp.sp_rgbs.items[row_start + @as(usize, c)];
                                const run_fg = tmp.fg_rgbs.items[row_start + @as(usize, c)];
                                const run_grid_id = tmp.grid_ids.items[row_start + @as(usize, c)];

                                const run_end: u32 = @intCast(@min(
                                    simdFindRunEndU8(tmp.style_flags_arr.items[row_start..], @intCast(c + 1), @intCast(cols), run_flags),
                                    @min(
                                        simdFindRunEndU32(tmp.sp_rgbs.items[row_start..], @intCast(c + 1), @intCast(cols), run_sp),
                                        simdFindRunEndI64(tmp.grid_ids.items[row_start..], @intCast(c + 1), @intCast(cols), run_grid_id),
                                    ),
                                ));

                                // Use special color if set, otherwise foreground
                                const deco_color = if (run_sp != highlight.Highlights.SP_NOT_SET) Helpers.rgb(run_sp) else Helpers.rgb(run_fg);
                                const nr_deco_scroll: u32 = Helpers.computeScrollFlag(r2, run_grid_id, nr_r2_scrollable, cached_subgrids[0..cached_subgrid_count]);

                                const x0: f32 = @as(f32, @floatFromInt(run_start)) * cellW;
                                const x1: f32 = @as(f32, @floatFromInt(run_end)) * cellW;
                                const row_y: f32 = @as(f32, @floatFromInt(r2)) * cellH;

                                // Underline: 1px line at bottom of cell
                                if (run_flags & STYLE_UNDERLINE != 0) {
                                    const y0 = row_y + cellH - 2.0;
                                    const y1 = y0 + 1.0;
                                    try Helpers.pushDecoQuad(main, ctx.core.alloc, x0, y0, x1, y1, deco_color, dw, dh, run_grid_id, c_api.DECO_UNDERLINE | nr_deco_scroll, 0);
                                }

                                // Underdouble: 2 lines at bottom with clear gap
                                if (run_flags & STYLE_UNDERDOUBLE != 0) {
                                    // First line: 6px from bottom
                                    const y0_1 = row_y + cellH - 6.0;
                                    const y1_1 = y0_1 + 1.0;
                                    // Second line: 2px from bottom (4px gap between lines)
                                    const y0_2 = row_y + cellH - 2.0;
                                    const y1_2 = y0_2 + 1.0;
                                    try Helpers.pushDecoQuad(main, ctx.core.alloc, x0, y0_1, x1, y1_1, deco_color, dw, dh, run_grid_id, c_api.DECO_UNDERLINE | nr_deco_scroll, 0);
                                    try Helpers.pushDecoQuad(main, ctx.core.alloc, x0, y0_2, x1, y1_2, deco_color, dw, dh, run_grid_id, c_api.DECO_UNDERLINE | nr_deco_scroll, 0);
                                }

                                // Undercurl: wavy line (shader-based)
                                if (run_flags & STYLE_UNDERCURL != 0) {
                                    const y0 = row_y + cellH - 4.0;
                                    const y1 = row_y + cellH;
                                    const phase: f32 = @floatFromInt(run_start);
                                    try Helpers.pushDecoQuad(main, ctx.core.alloc, x0, y0, x1, y1, deco_color, dw, dh, run_grid_id, c_api.DECO_UNDERCURL | nr_deco_scroll, phase);
                                }

                                // Underdotted: dotted line (shader-based)
                                if (run_flags & STYLE_UNDERDOTTED != 0) {
                                    const y0 = row_y + cellH - 2.0;
                                    const y1 = y0 + 1.0;
                                    try Helpers.pushDecoQuad(main, ctx.core.alloc, x0, y0, x1, y1, deco_color, dw, dh, run_grid_id, c_api.DECO_UNDERDOTTED | nr_deco_scroll, 0);
                                }

                                // Underdashed: dashed line (shader-based)
                                if (run_flags & STYLE_UNDERDASHED != 0) {
                                    const y0 = row_y + cellH - 2.0;
                                    const y1 = y0 + 1.0;
                                    try Helpers.pushDecoQuad(main, ctx.core.alloc, x0, y0, x1, y1, deco_color, dw, dh, run_grid_id, c_api.DECO_UNDERDASHED | nr_deco_scroll, 0);
                                }

                                c = run_end;
                            }
                        }
                    }

                    var t_under_deco_end: i128 = 0;
                    var t_glyph_start: i128 = 0;
                    if (perf_log_enabled) {
                        t_under_deco_end = std.time.nanoTimestamp();
                        t_glyph_start = t_under_deco_end;
                    }

                    // 3) Glyphs: run-length by (fg,bg,grid_id) and skip "all spaces"
                    const ensure_base_full = ctx.core.cb.on_atlas_ensure_glyph;
                    const ensure_styled_full = ctx.core.cb.on_atlas_ensure_glyph_styled;
                    if (ctx.core.isPhase2Atlas() or ensure_base_full != null or ensure_styled_full != null) {
                        r = 0;
                        while (r < rows) : (r += 1) {
                            const row_start: usize = @as(usize, r) * @as(usize, cols);
                            const nr_glyph_scrollable: u32 = if (r >= nr_main_margins.top and r < rows -| nr_main_margins.bottom) c_api.DECO_SCROLLABLE else 0;

                            var c: u32 = 0;
                            while (c < cols) {
                                const run_fg = tmp.fg_rgbs.items[row_start + @as(usize, c)];
                                const run_bg = tmp.bg_rgbs.items[row_start + @as(usize, c)];
                                const run_grid_id = tmp.grid_ids.items[row_start + @as(usize, c)];
                                const run_start = c;

                                const run_glow_nr: u8 = if (glow_enabled) tmp.glow_arr.items[row_start + @as(usize, c)] else 0;
                                const base_end_nr = @min(
                                    simdFindRunEndU32(tmp.fg_rgbs.items[row_start..], @intCast(c), @intCast(cols), run_fg),
                                    @min(
                                        simdFindRunEndU32(tmp.bg_rgbs.items[row_start..], @intCast(c), @intCast(cols), run_bg),
                                        simdFindRunEndI64(tmp.grid_ids.items[row_start..], @intCast(c), @intCast(cols), run_grid_id),
                                    ),
                                );
                                const end: u32 = @intCast(if (glow_enabled)
                                    @min(base_end_nr, simdFindRunEndU8(tmp.glow_arr.items[row_start..], @intCast(c), @intCast(cols), run_glow_nr))
                                else
                                    base_end_nr);
                                const has_ink = simdHasInkInRange(tmp.scalars.items[row_start..], @intCast(c), @intCast(end));

                                if (has_ink) {
                                    const baseX = @as(f32, @floatFromInt(run_start)) * cellW;
                                    const baseY = @as(f32, @floatFromInt(r)) * cellH + topPad;

                                    var penX: f32 = baseX;
                                    const fg = Helpers.rgb(run_fg);
                                    const nr_run_has_glow = run_glow_nr != 0;

                                    var col_i: u32 = run_start;
                                    while (col_i < end) : (col_i += 1) {
                                        const cell_scalar = tmp.scalars.items[row_start + @as(usize, col_i)];
                                        const cell_style_flags = tmp.style_flags_arr.items[row_start + @as(usize, col_i)];
                                        const scalar: u32 = if (cell_scalar == 0) 32 else cell_scalar;
                                        if (scalar == 32) {
                                            penX += cellW;
                                            continue;
                                        }
                                        // Block element: geometric rendering (no atlas)
                                        if (block_elements.isBlockElement(scalar)) {
                                            const blk_geo = block_elements.getBlockGeometry(scalar);
                                            if (blk_geo.count > 0) {
                                                const blk_y0 = @as(f32, @floatFromInt(r)) * cellH;
                                                const nr_blk_scroll: u32 = Helpers.computeScrollFlag(r, run_grid_id, nr_glyph_scrollable, cached_subgrids[0..cached_subgrid_count]);
                                                main.ensureUnusedCapacity(ctx.core.alloc, @as(usize, blk_geo.count) * 6) catch {
                                                    penX += cellW;
                                                    continue;
                                                };
                                                for (blk_geo.rects[0..blk_geo.count]) |rect| {
                                                    Helpers.pushSolidQuadAssumeCapacity(main, penX + rect.x0 * cellW, blk_y0 + rect.y0 * cellH, penX + rect.x1 * cellW, blk_y0 + rect.y1 * cellH, fg, dw, dh, run_grid_id, nr_blk_scroll);
                                                }
                                            }
                                            penX += cellW;
                                            continue;
                                        }

                                        var ge: c_api.GlyphEntry = undefined;
                                        // Use styled callback for bold/italic if available
                                        const style_mask = cell_style_flags & (STYLE_BOLD | STYLE_ITALIC);
                                        const glyph_ok = blk: {
                                            if (ctx.core.isPhase2Atlas()) {
                                                const c_style: u32 = @as(u32, if (cell_style_flags & STYLE_BOLD != 0) c_api.STYLE_BOLD else 0) |
                                                    @as(u32, if (cell_style_flags & STYLE_ITALIC != 0) c_api.STYLE_ITALIC else 0);
                                                if (ctx.core.ensureGlyphPhase2(scalar, c_style)) |entry| {
                                                    ge = entry;
                                                    break :blk true;
                                                }
                                                break :blk false;
                                            } else if (style_mask != 0 and ensure_styled_full != null) {
                                                const c_style: u32 = @as(u32, if (cell_style_flags & STYLE_BOLD != 0) c_api.STYLE_BOLD else 0) |
                                                    @as(u32, if (cell_style_flags & STYLE_ITALIC != 0) c_api.STYLE_ITALIC else 0);
                                                break :blk ensure_styled_full.?(ctx.core.ctx, scalar, c_style, &ge) != 0;
                                            } else if (ensure_base_full) |ensure| {
                                                break :blk ensure(ctx.core.ctx, scalar, &ge) != 0;
                                            } else {
                                                break :blk false;
                                            }
                                        };
                                        if (!glyph_ok) {
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
                                            const nr_glyph_scroll: u32 = Helpers.computeScrollFlag(r, run_grid_id, nr_glyph_scrollable, cached_subgrids[0..cached_subgrid_count]);
                                            const nr_glyph_deco: u32 = nr_glyph_scroll | (if (nr_run_has_glow) c_api.DECO_GLOW else 0) | (if (ge.bytes_per_pixel >= 4) c_api.DECO_COLOR_EMOJI else 0);
                                            try Helpers.pushGlyphQuad(main, ctx.core.alloc, gx0, gy0, gx1, gy1, uv0, uv1, uv2, uv3, fg, dw, dh, run_grid_id, nr_glyph_deco);
                                        }

                                        // Monospace cell model: advance by cellW
                                        penX += cellW;
                                    }
                                }

                                c = end;
                            }
                        }
                    }

                    var t_glyph_end: i128 = 0;
                    var t_strike_start: i128 = 0;
                    if (perf_log_enabled) {
                        t_glyph_end = std.time.nanoTimestamp();
                        t_strike_start = t_glyph_end;
                    }

                    // 4) Strikethrough: drawn ON TOP of glyphs
                    {
                        var r2: u32 = 0;
                        while (r2 < rows) : (r2 += 1) {
                            const row_start: usize = @as(usize, r2) * @as(usize, cols);
                            const nr_strike_scrollable: u32 = if (r2 >= nr_main_margins.top and r2 < rows -| nr_main_margins.bottom) c_api.DECO_SCROLLABLE else 0;

                            var c: u32 = 0;
                            while (c < cols) {
                                const cell_sf2 = tmp.style_flags_arr.items[row_start + @as(usize, c)];
                                // Only handle strikethrough here
                                if (cell_sf2 & STYLE_STRIKETHROUGH == 0) {
                                    c += 1;
                                    continue;
                                }

                                // Find run of cells with same strikethrough style
                                const run_start = c;
                                const run_sp = tmp.sp_rgbs.items[row_start + @as(usize, c)];
                                const run_fg = tmp.fg_rgbs.items[row_start + @as(usize, c)];
                                const run_grid_id = tmp.grid_ids.items[row_start + @as(usize, c)];

                                const run_end: u32 = @intCast(@min(
                                    simdFindFirstBitUnset(tmp.style_flags_arr.items[row_start..], @intCast(c + 1), @intCast(cols), STYLE_STRIKETHROUGH),
                                    @min(
                                        simdFindRunEndU32(tmp.sp_rgbs.items[row_start..], @intCast(c + 1), @intCast(cols), run_sp),
                                        simdFindRunEndI64(tmp.grid_ids.items[row_start..], @intCast(c + 1), @intCast(cols), run_grid_id),
                                    ),
                                ));

                                // Use special color if set, otherwise foreground
                                const deco_color = if (run_sp != highlight.Highlights.SP_NOT_SET) Helpers.rgb(run_sp) else Helpers.rgb(run_fg);
                                const nr_strike_scroll: u32 = Helpers.computeScrollFlag(r2, run_grid_id, nr_strike_scrollable, cached_subgrids[0..cached_subgrid_count]);

                                const x0: f32 = @as(f32, @floatFromInt(run_start)) * cellW;
                                const x1: f32 = @as(f32, @floatFromInt(run_end)) * cellW;
                                const row_y: f32 = @as(f32, @floatFromInt(r2)) * cellH;

                                // Strikethrough: line through middle
                                const y0 = row_y + cellH * 0.5 - 0.5;
                                const y1 = y0 + 1.0;
                                try Helpers.pushDecoQuad(main, ctx.core.alloc, x0, y0, x1, y1, deco_color, dw, dh, run_grid_id, c_api.DECO_STRIKETHROUGH | nr_strike_scroll, 0);

                                c = run_end;
                            }

                            // 5) Overline (line at top of cell)
                            {
                                var c2_ol: u32 = 0;
                                while (c2_ol < cols) {
                                    if (tmp.overline_arr.items[row_start + @as(usize, c2_ol)] == 0) {
                                        c2_ol += 1;
                                        continue;
                                    }

                                    const run_start = c2_ol;
                                    const run_sp = tmp.sp_rgbs.items[row_start + @as(usize, c2_ol)];
                                    const run_fg = tmp.fg_rgbs.items[row_start + @as(usize, c2_ol)];
                                    const run_grid_id = tmp.grid_ids.items[row_start + @as(usize, c2_ol)];

                                    var run_end: u32 = c2_ol + 1;
                                    while (run_end < cols) : (run_end += 1) {
                                        if (tmp.overline_arr.items[row_start + @as(usize, run_end)] == 0) break;
                                        if (tmp.sp_rgbs.items[row_start + @as(usize, run_end)] != run_sp) break;
                                        if (tmp.grid_ids.items[row_start + @as(usize, run_end)] != run_grid_id) break;
                                        if (run_sp == highlight.Highlights.SP_NOT_SET and
                                            tmp.fg_rgbs.items[row_start + @as(usize, run_end)] != run_fg) break;
                                    }

                                    const deco_color = if (run_sp != highlight.Highlights.SP_NOT_SET) Helpers.rgb(run_sp) else Helpers.rgb(run_fg);
                                    const nr_ol_scroll: u32 = Helpers.computeScrollFlag(r2, run_grid_id, nr_strike_scrollable, cached_subgrids[0..cached_subgrid_count]);

                                    const x0: f32 = @as(f32, @floatFromInt(run_start)) * cellW;
                                    const x1: f32 = @as(f32, @floatFromInt(run_end)) * cellW;
                                    const row_y: f32 = @as(f32, @floatFromInt(r2)) * cellH;

                                    const y0 = row_y;
                                    const y1 = y0 + 1.0;
                                    try Helpers.pushDecoQuad(main, ctx.core.alloc, x0, y0, x1, y1, deco_color, dw, dh, run_grid_id, c_api.DECO_OVERLINE | nr_ol_scroll, 0);

                                    c2_ol = run_end;
                                }
                            }
                        }
                    }

                    // Log timing for performance measurement
                    if (perf_log_enabled) {
                        const t_strike_end = std.time.nanoTimestamp();
                        const under_deco_ns: i128 = t_under_deco_end - t_under_deco_start;
                        const glyph_ns: i128 = t_glyph_end - t_glyph_start;
                        const strike_ns: i128 = t_strike_end - t_strike_start;
                        const total_ns: i128 = t_strike_end - t_under_deco_start;
                        ctx.core.log.write(
                            "[perf] full_redraw rows={d} cols={d} under_deco_ns={d} glyph_ns={d} strike_ns={d} total_ns={d}\n",
                            .{ rows, cols, under_deco_ns, glyph_ns, strike_ns, total_ns },
                        );
                    }

                    // Mark main as sent (content revision)
                    ctx.core.last_sent_content_rev = ctx.core.grid.content_rev;

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
                const cursor_embedded_in_main = (cursor_grid == 1) or ctx.core.grid.win_pos.contains(cursor_grid);

                if (cursor_embedded_in_main) {
                    _ = cursor.ensureTotalCapacity(ctx.core.alloc, 64) catch {};
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
                            const p0 = pts[0]; const p1 = pts[1]; const p2 = pts[2]; const p3 = pts[3];
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
                                    if (cursor.ensureUnusedCapacity(ctx.core.alloc, @as(usize, blk_geo.count) * 6)) {
                                        const cursor_fg_col = Helpers.rgb(cursor_out.fgRGB);
                                        for (blk_geo.rects[0..blk_geo.count]) |rect| {
                                            Helpers.pushSolidQuadAssumeCapacity(cursor, x0 + rect.x0 * cursor_width, y0 + rect.y0 * cellH, x0 + rect.x1 * cursor_width, y0 + rect.y1 * cellH, cursor_fg_col, dw, dh, cursor_grid_id, c_api.DECO_SCROLLABLE);
                                        }
                                    } else |_| {}
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
                                    if (ctx.core.ensureGlyphPhase2(cursor_cp, cursor_c_style)) |entry| {
                                        ge = entry;
                                        glyph_ok = true;
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
                                        gx0, gy0, gx1, gy1,
                                        uv0, uv1, uv2, uv3,
                                        fg,
                                        dw, dh,
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
                    sg.dirty = true;
                }
                ctx.core.atlas_reset_during_flush = false;
                return;
            }

            // ----------------------------
            // Send vertices: partial if possible, else legacy full callback
            // ----------------------------
            if (pf_opt) |pf| {
                var flags: u32 = 0;
            
                // If main was already sent by rows, do NOT send main here.
                const send_main_here = need_main and !sent_main_by_rows;
            
                if (send_main_here) flags |= 1; // ZONVIE_VERT_UPDATE_MAIN
                if (need_cursor)    flags |= 2; // ZONVIE_VERT_UPDATE_CURSOR
            
                const main_ptr_opt: ?[*]const c_api.Vertex = if (send_main_here) main.items.ptr else null;
                const cur_ptr_opt: ?[*]const c_api.Vertex  = if (need_cursor) cursor.items.ptr else null;
            
                pf(
                    ctx.core.ctx,
                    main_ptr_opt, if (send_main_here) main.items.len else 0,
                    cur_ptr_opt,  if (need_cursor) cursor.items.len else 0,
                    flags,
                );
                if (need_cursor) {
                    ctx.core.last_sent_cursor_rev = ctx.core.grid.cursor_rev;
                }
                // Only update snapshot when main was rebuilt (subgrid info is current).
                // cursor-only flushes leave cached_subgrid_count == 0.
                if (need_main) saveSubgridSnapshots(ctx.core, cached_subgrids[0..cached_subgrid_count]);
                ctx.core.grid.clearDirty();
                ctx.core.grid.clearScrollState();
                return;
            }

            // If main was sent via row callback, do not call legacy full callback.
            if (sent_main_by_rows) return;

            if (need_main) saveSubgridSnapshots(ctx.core, cached_subgrids[0..cached_subgrid_count]);
            ctx.core.grid.clearDirty();
            ctx.core.grid.clearScrollState();
            return;

        }

    }

    pub fn onGuifont(ctx: *FlushCtx, font: []const u8) !void {
        // Invalidate caches BEFORE emitting callback: the callback may
        // trigger vertex generation (e.g., Windows' updateLayoutToCore
        // calls sendExternalGridVertices when cell dimensions change).
        // Clearing first ensures those vertices use fresh cache lookups.
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
        ctx.core.grid.markAllDirty();
        var sg_it = ctx.core.grid.sub_grids.valueIterator();
        while (sg_it.next()) |sg| {
            sg.dirty = true;
        }

        ctx.core.emitGuiFont(font);
    }

    pub fn onLinespace(ctx: *FlushCtx, px: i32) !void {
        // Store in core and notify frontend.
        const clamped: i32 = if (px < 0) 0 else px;
        ctx.core.linespace_px = @as(u32, @intCast(clamped));
        ctx.core.emitLineSpace(clamped);
    }

    pub fn onSetTitle(ctx: *FlushCtx, title: []const u8) !void {
        ctx.core.emitSetTitle(title);
    }

    pub fn onDefaultColors(ctx: *FlushCtx, fg: u32, bg: u32) !void {
        ctx.core.emitDefaultColors(fg, bg);
    }
};

pub fn notifyExternalWindowChanges(self: *Core) bool {
    var new_grids_added = false;

    // Find closed external windows (were known, but no longer in grid.external_grids)
    var closed_grids: std.ArrayListUnmanaged(i64) = .{};
    defer closed_grids.deinit(self.alloc);

    var known_it = self.known_external_grids.keyIterator();
    while (known_it.next()) |grid_id_ptr| {
        const grid_id = grid_id_ptr.*;
        if (!self.grid.external_grids.contains(grid_id)) {
            closed_grids.append(self.alloc, grid_id) catch continue;
        }
    }

    // Notify closed external windows
    if (self.cb.on_external_window_close) |cb| {
        for (closed_grids.items) |grid_id| {
            cb(self.ctx, grid_id);
        }
    }

    // Remove closed grids from known set
    for (closed_grids.items) |grid_id| {
        _ = self.known_external_grids.remove(grid_id);
    }

    // Find new external windows (in grid.external_grids but not in known)
    var ext_it = self.grid.external_grids.iterator();
    while (ext_it.next()) |entry| {
        const grid_id = entry.key_ptr.*;
        const info = entry.value_ptr.*;

        if (!self.known_external_grids.contains(grid_id)) {
            // New external grid - get dimensions from sub_grids
            var rows: u32 = 0;
            var cols: u32 = 0;
            if (self.grid.sub_grids.get(grid_id)) |sg| {
                rows = sg.rows;
                cols = sg.cols;
            }

            // Skip 0x0 grids - wait until grid_resize provides valid dimensions
            if (rows == 0 or cols == 0) continue;

            // For ext_windows grids awaiting initial resize response from Neovim,
            // defer window creation until the grid has a reasonable size.
            // Neovim may send an intermediate small grid_resize (e.g. rows=1)
            // before the actual resize, and creating the window at that size
            // produces a tiny window.
            if (self.grid.pending_ext_window_grids.contains(grid_id)) {
                if (rows < 2 or cols < 2) {
                    // Grid is still at intermediate tiny size - wait
                    continue;
                }
                // Grid has reasonable dimensions, proceed with window creation
                _ = self.grid.pending_ext_window_grids.remove(grid_id);
            }

            // Notify frontend with position info
            if (self.cb.on_external_window) |cb| {
                cb(self.ctx, grid_id, info.win, rows, cols, info.start_row, info.start_col);
            }

            // Add to known set
            self.known_external_grids.put(self.alloc, grid_id, {}) catch continue;
            new_grids_added = true;
        }
    }

    return new_grids_added;
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

    // Cache glow state once — doesn't change while grid_mu is held.
    const ext_glow_enabled = self.glow_enabled.load(.acquire);
    const ext_glow_all = self.glow_all;
    const ext_glow_hl_ids = if (self.glow_hl_ids) |*m| m else null;

    // Check if cursor changed (position or grid) - do this first, before early returns
    const cursor_grid = self.grid.cursor_grid;
    const cursor_rev = self.grid.cursor_rev;
    const cursor_changed = (cursor_rev != self.last_ext_cursor_rev);
    const cursor_grid_changed = (cursor_grid != self.last_ext_cursor_grid);

    self.log.write("[sendExternalGridVertices] cursor_grid={d} cursor_rev={d} last_grid={d} last_rev={d} changed={} grid_changed={}\n", .{
        cursor_grid, cursor_rev, self.last_ext_cursor_grid, self.last_ext_cursor_rev, cursor_changed, cursor_grid_changed,
    });

    // Only update last cursor grid if we have external grids to process.
    // Otherwise we consume the cursor state before the grid window is created.
    // Always update cursor rev to prevent stale changed=true accumulation.
    const has_external_grids = self.known_external_grids.count() > 0;
    defer {
        if (has_external_grids) {
            self.last_ext_cursor_grid = cursor_grid;
        }
        self.last_ext_cursor_rev = cursor_rev;
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

    // Reuse row_verts buffer for external grid vertices (per-row)
    var ext_verts = &self.row_verts;

    const cellW: f32 = @floatFromInt(self.cell_w_px);
    const cellH: f32 = @floatFromInt(self.cell_h_px);

    const lineSpacePx: u32 = self.linespace_px;
    const topPadPx: u32 = lineSpacePx / 2;
    const topPad: f32 = @floatFromInt(topPadPx);

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
            x0: f32, y0: f32, x1: f32, y1: f32,
            col: [4]f32,
            vw: f32, vh: f32,
            grid_id: i64,
            base_deco_flags: u32,
        ) void {
            const pts = ndc4(x0, y0, x1, y1, vw, vh);
            const p0 = pts[0]; const p1 = pts[1]; const p2 = pts[2]; const p3 = pts[3];

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

    // Iterate over all known external grids
    var ext_it = self.known_external_grids.keyIterator();
    while (ext_it.next()) |grid_id_ptr| {
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
        const cursor_on_this_grid = (cursor_grid == grid_id);
        const cursor_was_on_this_grid = (self.last_ext_cursor_grid == grid_id);
        const cursor_affected = cursor_grid_changed and (cursor_on_this_grid or cursor_was_on_this_grid);
        const cursor_moved_within = cursor_changed and cursor_on_this_grid and !cursor_grid_changed;

        // Check if this grid needs forced redraw because cursor left closed cmdline
        const force_redraw_this = need_force_redraw_last and (grid_id == self.last_ext_cursor_grid);

        self.log.write("[ext_cursor_check] grid_id={d} dirty={} cursor_on={} cursor_was={} affected={} moved_within={} force={} force_closed={} cursor_grid={d} last_grid={d} rev={d} last_rev={d}\n", .{
            grid_id, sg.dirty, cursor_on_this_grid, cursor_was_on_this_grid, cursor_affected, cursor_moved_within, force_render, force_redraw_this,
            cursor_grid, self.last_ext_cursor_grid, cursor_rev, self.last_ext_cursor_rev,
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

        // Pre-allocate capacity: 6 verts/cell for bg + 6 verts/cell for glyphs + 6 for cursor
        const n_cells = @as(usize, sg.rows) * @as(usize, sg.cols);
        const est_verts = n_cells * 12 + 6;
        ext_verts.ensureTotalCapacity(self.alloc, est_verts) catch {
            self.log.write("[ext_grid] WARN: failed to pre-allocate {d} vertices\n", .{est_verts});
            continue; // Skip this grid if we can't allocate
        };

        // Create composite cell array - copy external grid cells and overlay float windows
        // This approach ensures float windows completely overwrite (not blend with) the underlying cells
        const composite_cells = self.alloc.alloc(grid_mod.Cell, n_cells) catch {
            self.log.write("[ext_grid] WARN: failed to allocate composite cells for {d} cells\n", .{n_cells});
            continue;
        };
        defer self.alloc.free(composite_cells);

        // Float overlay overflow: reuse persistent map (cleared each ext grid).
        self.flush_float_overlay_buf.clearRetainingCapacity();

        // Copy external grid cells to composite array
        if (sg.cells.len >= n_cells) {
            @memcpy(composite_cells[0..n_cells], sg.cells[0..n_cells]);
        } else {
            // Fill with defaults if source is smaller
            for (composite_cells) |*c| {
                c.* = .{ .cp = ' ', .hl = 0 };
            }
            @memcpy(composite_cells[0..sg.cells.len], sg.cells);
        }

        // Overlay float windows anchored to this external grid into composite_cells
        const ext_info = self.grid.external_grids.get(grid_id);
        self.log.write("[ext_overlay_debug] grid_id={d} ext_info_exists={} win_pos_count={d}\n", .{
            grid_id, ext_info != null, self.grid.win_pos.count(),
        });

        var overlay_cell_count: u32 = 0;
        if (ext_info) |info| {
            self.log.write("[ext_overlay_debug] ext grid {d}: start_row={d} start_col={d}\n", .{
                grid_id, info.start_row, info.start_col,
            });
            if (info.start_row >= 0 and info.start_col >= 0) {
                const ext_start_row: i32 = info.start_row;
                const ext_start_col: i32 = info.start_col;

                // Scan win_pos for float windows anchored to this external grid
                var win_it = self.grid.win_pos.iterator();
                while (win_it.next()) |entry| {
                    const float_grid_id = entry.key_ptr.*;
                    const float_pos = entry.value_ptr.*;

                    self.log.write("[ext_overlay_debug] checking win_pos: float_grid={d} anchor={d} pos=({d},{d}) (target ext={d})\n", .{
                        float_grid_id, float_pos.anchor_grid, float_pos.row, float_pos.col, grid_id,
                    });

                    // Check if this float window is anchored to our external grid
                    if (float_pos.anchor_grid != grid_id) continue;

                    // Get the float window's sub_grid
                    const float_sg = self.grid.sub_grids.get(float_grid_id) orelse {
                        self.log.write("[ext_overlay_debug] WARN: float grid {d} has no sub_grid!\n", .{float_grid_id});
                        continue;
                    };

                    // Calculate float window position relative to this external grid
                    const float_row_in_ext: i32 = @as(i32, @intCast(float_pos.row)) - ext_start_row;
                    const float_col_in_ext: i32 = @as(i32, @intCast(float_pos.col)) - ext_start_col;

                    self.log.write("[ext_overlay_cells] FOUND anchored float: grid={d} size=({d}x{d}) rel_pos=({d},{d}) cells_len={d}\n", .{
                        float_grid_id, float_sg.rows, float_sg.cols, float_row_in_ext, float_col_in_ext, float_sg.cells.len,
                    });

                    // Sample first few cells from float_sg for debugging
                    if (float_sg.cells.len > 0) {
                        const sample_count = @min(float_sg.cells.len, 5);
                        for (0..sample_count) |i| {
                            const c = float_sg.cells[i];
                            self.log.write("[ext_overlay_cells] float_sg.cells[{d}]: cp=0x{x} hl={d}\n", .{ i, c.cp, c.hl });
                        }
                    }

                    // Copy float window cells into composite array (overwriting underlying cells)
                    for (0..float_sg.rows) |fr_idx| {
                        const fr: u32 = @intCast(fr_idx);
                        const target_row = float_row_in_ext + @as(i32, @intCast(fr));
                        if (target_row < 0 or target_row >= @as(i32, @intCast(sg.rows))) continue;

                        for (0..float_sg.cols) |fc_idx| {
                            const fc: u32 = @intCast(fc_idx);
                            const target_col = float_col_in_ext + @as(i32, @intCast(fc));
                            if (target_col < 0 or target_col >= @as(i32, @intCast(sg.cols))) continue;

                            const float_cell_idx: usize = @as(usize, fr) * @as(usize, float_sg.cols) + @as(usize, fc);
                            if (float_cell_idx >= float_sg.cells.len) continue;

                            const target_idx: usize = @as(usize, @intCast(target_row)) * @as(usize, sg.cols) + @as(usize, @intCast(target_col));
                            if (target_idx >= n_cells) continue;

                            // Overwrite composite cell with float window cell
                            composite_cells[target_idx] = float_sg.cells[float_cell_idx];

                            // Record float overlay for emoji lookup during row composition.
                            // Always record (even without overflow) so the float shadows
                            // any base grid overflow at this position. put() overwrites
                            // so the last float wins (matching composite_cells semantics).
                            self.flush_float_overlay_buf.put(self.alloc, .{
                                .row = @intCast(target_row),
                                .col = @intCast(target_col),
                            }, self.grid.getOverflow(float_grid_id, fr, fc)) catch {};

                            overlay_cell_count += 1;
                        }
                    }

                    self.log.write("[ext_overlay_cells] Copied {d} cells from float grid {d}\n", .{ overlay_cell_count, float_grid_id });
                }
            }
        }

        self.log.write("[ext_overlay_summary] grid_id={d} total_overlay_cells={d}\n", .{ grid_id, overlay_cell_count });

        // Sample composite_cells after overlay for debugging
        if (overlay_cell_count > 0) {
            // Log a few cells from the overlay region
            const sample_row: usize = 0;
            for (0..@min(sg.cols, 10)) |c| {
                const idx = sample_row * @as(usize, sg.cols) + c;
                if (idx < n_cells) {
                    const cell = composite_cells[idx];
                    self.log.write("[ext_overlay_result] composite[row=0,col={d}]: cp=0x{x} hl={d}\n", .{ c, cell.cp, cell.hl });
                }
            }
        }

        // Row-based vertex generation: process each row independently
        // This matches the main window's row-based approach for better partial updates
        const ext_margins = self.grid.getViewportMargins(grid_id);

        const cursor_row: ?u32 = if (self.grid.cursor_grid == grid_id and self.grid.cursor_valid and self.grid.cursor_visible)
            self.grid.cursor_row
        else
            null;
        const cursor_col = self.grid.cursor_col;
        const is_cmdline = grid_id == grid_mod.CMDLINE_GRID_ID;

        var ext_saw_atlas_reset: bool = false;
        var ext_retried: bool = false;
        var ext_had_row_error: bool = false;

        // Determine external grid scroll fast path eligibility (before retry loop).
        // When eligible, we skip non-dirty rows even when sg.dirty is set,
        // because scroll() now only marks vacated rows dirty.
        const ext_scroll_fast_path: bool = blk: {
            if (force_render or need_full_redraw) break :blk false;
            const op = sg.last_scroll_op orelse break :blk false;
            if (sg.scroll_fast_path_blocked) break :blk false;
            const abs_rows: u32 = @intCast(@abs(op.rows));
            if (abs_rows != 1) break :blk false;
            if (op.cols != 0) break :blk false;
            const region_height: u32 = op.bot -| op.top;
            if (region_height <= 1) break :blk false;
            if (op.left != 0 or op.right != sg.cols) break :blk false;
            if (op.bot > sg.rows) break :blk false;
            break :blk true;
        };

        // When a scroll happened but the fast path is not usable (multiple
        // scrolls in one batch, or scroll delta > 1), the frontend won't
        // receive on_grid_row_scroll (no row slot remap) and GPU scroll
        // copy is disabled for external grids. All shifted rows need full
        // vertex regeneration — dirty_rows only covers vacated rows.
        const ext_scroll_needs_full_regen: bool =
            !ext_scroll_fast_path and (sg.scroll_fast_path_blocked or
            (if (sg.last_scroll_op) |op| @abs(op.rows) > 1 else false));

        // Cursor is rendered as a separate layer (after row loop), NOT inline
        // in row vertices. This eliminates cursor ghost artifacts during GPU
        // scroll copy. No prev_cursor_row tracking needed for row regeneration.

        // Build regen_rows set for scroll fast path (mirrors global grid approach).
        // Pre-compute which rows need regeneration: dirty_rows only (no cursor rows).
        var regen_rows: [12]u32 = undefined;
        var regen_count: u32 = 0;
        var use_ext_scroll_fast_path = ext_scroll_fast_path;

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
                    if (rr == vacated) { found = true; break; }
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
            }
            const ext_effective_rebuild = ext_retried;

        // Iterate only up to viewport_rows (not sg.rows).
        // Rows beyond viewport_rows are outside the NDC viewport and
        // produce clipped vertices. Matching the vertex loop to the
        // viewport ensures the frontend receives data only for drawable
        // rows — the same invariant the main window always satisfies.
        for (0..viewport_rows) |row_idx| {
            const row: u32 = @intCast(row_idx);

            // Compute scrollable flag for this row in the external grid
            const ext_scrollable: u32 = if (row >= ext_margins.top and row < sg.rows -| ext_margins.bottom) c_api.DECO_SCROLLABLE else 0;

            // Row skip logic — mirrors global grid approach:
            // Fast path: only compose rows in regen set (dirty + cursor rows).
            // Fallback: check dirty_rows bitmap.
            // When scroll happened but fast path is ineligible, regenerate all
            // rows because the frontend has no GPU blit or row slot remap to
            // shift the non-vacated rows visually.
            if (use_ext_scroll_fast_path and !ext_retried) {
                var in_regen = false;
                for (regen_rows[0..regen_count]) |rr| {
                    if (rr == row) { in_regen = true; break; }
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
                continue;
            };

            // Compose RenderCells for this row (resolve hl -> fg/bg/sp/style_flags)
            self.row_cells.clearRetainingCapacity();
            self.row_cells.ensureTotalCapacity(self.alloc, sg.cols) catch {
                ext_had_row_error = true;
                continue;
            };
            self.row_cells.setLen(sg.cols);

            // Set float overlay context (used by getOverflowForCell for O(1) lookup)
            self.flush_float_overlay = &self.flush_float_overlay_buf;

            const row_start: usize = @as(usize, row) * @as(usize, sg.cols);
            for (0..sg.cols) |c| {
                const cell_idx = row_start + c;
                if (cell_idx >= n_cells) {
                    self.row_cells.set(c, ' ', default_bg, default_bg, highlight.Highlights.SP_NOT_SET, grid_id, 0, 0);
                    if (ext_glow_enabled) self.row_cells.glow_arr.items[c] = 0;
                    continue;
                }
                const cell = composite_cells[cell_idx];
                const attr = cache.getAttr(&self.hl, cell.hl);
                self.row_cells.set(c, cell.cp, attr.fg, attr.bg, attr.sp, grid_id, packStyleFlags(attr), @intFromBool(attr.overline));
                if (ext_glow_enabled) {
                    self.row_cells.glow_arr.items[c] = if (ext_glow_all) 1 else if (ext_glow_hl_ids) |ids| (if (ids.contains(cell.hl)) @as(u8, 1) else 0) else 0;
                }
            }

            // Populate deco_base_flags: uniform ext_scrollable for external grids
            @memset(self.row_cells.deco_base_flags.items[0..sg.cols], ext_scrollable);

            // Unified 5-pass vertex generation
            _ = generateRowVertices(self, .{
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
            }, ext_verts) catch {
                ext_verts.clearRetainingCapacity();
                ext_had_row_error = true;
                continue;
            };
            // Cursor rendering moved to separate layer (after row loop)

            // CHECK: atlas reset happened during glyph processing for this row.
            // Already-sent rows have stale UVs → need to restart or abort.
            if (self.atlas_reset_during_flush) {
                ext_saw_atlas_reset = true;
                ext_saw_atlas_reset_any = true;
                self.atlas_reset_during_flush = false; // Clear for retry
                if (!ext_retried) {
                    ext_retried = true;
                    use_ext_scroll_fast_path = false; // Retry needs full redraw
                    continue :ext_retry; // Restart this grid's row loop from row 0
                }
                // 2nd reset: clear all sent rows (match global grid behavior)
                for (0..viewport_rows) |clear_ri| {
                    row_cb(self.ctx, grid_id, @intCast(clear_ri), 1, null, 0, 1, viewport_rows, viewport_cols);
                }
                break; // Abort remaining rows
            }

            // Send this row's vertices
            // Pass viewport dimensions (target size) instead of sg dimensions so that
            // the frontend's scroll offset calculation matches the NDC viewport used here.
            if (ext_verts.items.len > 0) {
                row_cb(self.ctx, grid_id, row, 1, ext_verts.items.ptr, ext_verts.items.len, 1, viewport_rows, viewport_cols);
            }
        }
        // Clear float overlay context pointer (buffer is persistent, cleared next ext grid)
        self.flush_float_overlay = null;
        break :ext_retry; // Normal exit from retry loop
        }

        // --- Cursor layer: send cursor vertices as separate on_vertices_row with CURSOR flag ---
        // This keeps cursor independent of row buffers, so GPU scroll copy
        // cannot create cursor ghosts.
        if (cursor_row) |cur_row| {
            if (cur_row < sg.rows and cursor_col < sg.cols) {
                ext_verts.clearRetainingCapacity();
                // Estimate: 6 cursor bg + 6 cursor text + block element quads
                ext_verts.ensureTotalCapacity(self.alloc, 48) catch {};

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
                const ctl = c_pts[0]; const ctr = c_pts[1]; const cbl = c_pts[2]; const cbr = c_pts[3];

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
                                    if (ext_verts.ensureUnusedCapacity(self.alloc, @as(usize, eblk_geo.count) * 6)) {
                                        for (eblk_geo.rects[0..eblk_geo.count]) |rect| {
                                            Helpers.pushSolidQuadAssumeCapacity(ext_verts, cx0 + rect.x0 * cursor_width, cy0 + rect.y0 * cellH, cx0 + rect.x1 * cursor_width, cy0 + rect.y1 * cellH, eblk_fg_col, grid_w, grid_h, grid_id, c_api.DECO_CURSOR | c_api.DECO_SCROLLABLE);
                                        }
                                    } else |_| {}
                                }
                            } else {
                                var glyph_entry: c_api.GlyphEntry = undefined;
                                var glyph_ok: c_int = -1;

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
                                    if (self.ensureGlyphPhase2(cursor_cell.cp, ext_cursor_c_style)) |entry| {
                                        glyph_entry = entry;
                                        glyph_ok = 1;
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
                                    const gtl = cg_pts[0]; const gtr = cg_pts[1]; const gbl = cg_pts[2]; const gbr = cg_pts[3];

                                    ext_verts.appendAssumeCapacity(.{ .position = gtl, .texCoord = .{ uv_x0, uv_y0 }, .color = text_col, .grid_id = grid_id, .deco_flags = c_api.DECO_CURSOR | c_api.DECO_SCROLLABLE, .deco_phase = 0 });
                                    ext_verts.appendAssumeCapacity(.{ .position = gtr, .texCoord = .{ uv_x1, uv_y0 }, .color = text_col, .grid_id = grid_id, .deco_flags = c_api.DECO_CURSOR | c_api.DECO_SCROLLABLE, .deco_phase = 0 });
                                    ext_verts.appendAssumeCapacity(.{ .position = gbl, .texCoord = .{ uv_x0, uv_y1 }, .color = text_col, .grid_id = grid_id, .deco_flags = c_api.DECO_CURSOR | c_api.DECO_SCROLLABLE, .deco_phase = 0 });
                                    ext_verts.appendAssumeCapacity(.{ .position = gtr, .texCoord = .{ uv_x1, uv_y0 }, .color = text_col, .grid_id = grid_id, .deco_flags = c_api.DECO_CURSOR | c_api.DECO_SCROLLABLE, .deco_phase = 0 });
                                    ext_verts.appendAssumeCapacity(.{ .position = gbr, .texCoord = .{ uv_x1, uv_y1 }, .color = text_col, .grid_id = grid_id, .deco_flags = c_api.DECO_CURSOR | c_api.DECO_SCROLLABLE, .deco_phase = 0 });
                                    ext_verts.appendAssumeCapacity(.{ .position = gbl, .texCoord = .{ uv_x0, uv_y1 }, .color = text_col, .grid_id = grid_id, .deco_flags = c_api.DECO_CURSOR | c_api.DECO_SCROLLABLE, .deco_phase = 0 });
                                }
                            }
                        }
                    }
                }

                // Send cursor vertices as separate layer (flags = CURSOR)
                row_cb(self.ctx, grid_id, cur_row, 1, ext_verts.items.ptr, ext_verts.items.len, c_api.VERT_UPDATE_CURSOR, viewport_rows, viewport_cols);
                self.log.write("[ext_cursor_layer] grid_id={d} cursor_row={d} cursor_col={d} cursor_verts={d}\n", .{ grid_id, cur_row, cursor_col, ext_verts.items.len });
            }
        } else if (cursor_was_on_this_grid and !cursor_on_this_grid) {
            // Cursor left this grid: send empty cursor to clear previous cursor
            row_cb(self.ctx, grid_id, 0, 1, null, 0, c_api.VERT_UPDATE_CURSOR, viewport_rows, viewport_cols);
            self.log.write("[ext_cursor_layer] grid_id={d} cursor_left, clearing cursor\n", .{grid_id});
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

        // Clear dirty flags after sending (both dirty and dirty_rows)
        sg.clearDirty();
        // If a row failed (allocation error), re-mark the grid dirty
        // so the failed rows get regenerated on the next flush.
        if (ext_had_row_error) {
            sg.dirty = true;
        }
        // If atlas was reset during this grid's rendering, re-mark dirty
        // so it gets re-rendered with correct UVs next flush.
        if (ext_saw_atlas_reset) {
            sg.dirty = true;
        }
    }

    // After ALL grids processed: if any atlas reset occurred,
    // already-sent grids also have stale UVs → mark ALL sub_grids dirty
    if (ext_saw_atlas_reset_any) {
        var sg_it = self.grid.sub_grids.valueIterator();
        while (sg_it.next()) |sg_val| {
            sg_val.dirty = true;
        }
    }
}

/// Wrapper for sendExternalGridVerticesFiltered - updates all grids.
pub fn sendExternalGridVertices(self: *Core, force_render: bool) void {
    sendExternalGridVerticesFiltered(self, force_render, null);
}

/// Check for cmdline state changes and create/update/close external float window via Neovim API.
/// The cmdline is rendered by Neovim in an external float window.
pub fn notifyCmdlineChanges(self: *Core) void {
    if (!self.grid.cmdline_dirty) return;
    if (!self.ext_cmdline_enabled) return;
    defer self.grid.clearCmdlineDirty();

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
        sendCmdlineBlockShow(self, any_visible, visible_level);
        return;
    }

    if (any_visible) {
        const state = self.grid.cmdline_states.getPtr(visible_level) orelse return;
        const cmdline_grid_id = grid_mod.CMDLINE_GRID_ID;

        // Record command content for split view label
        // (record every update, the final content before hide is the executed command)
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
            self.last_cmd_start_time = std.time.nanoTimestamp();
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

        // Grid width: start at global grid width, expand up to screen width, then scroll
        const min_width: u32 = if (self.grid.cols > 0) self.grid.cols else 80;
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
            return;
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
                const pre_col = grid_col;
                if (!writer.writeCell(pc.first_cp, state.prompt_hl_id)) break;
                const written = grid_col > pre_col;
                if (pc.display_width >= 2) {
                    if (!writer.writeCell(0, state.prompt_hl_id)) break;
                }
                if (pc.extras_len > 0 and written) {
                    self.grid.putOverflow(cmdline_grid_id, 0, pre_col, pc.extras[0..pc.extras_len]);
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
                const pre_grid_col = grid_col;
                if (!writer.writeCell(cluster.first_cp, chunk.hl_id)) break;
                const cell_was_written = grid_col > pre_grid_col;

                // Continuation cell only for double-width characters
                if (cluster.display_width >= 2) {
                    if (!writer.writeCell(0, chunk.hl_id)) break;
                }

                // Store extras in overflow map only if the cell was actually
                // written to the grid (not scrolled off the left edge).
                if (cluster.extras_len > 0 and cell_was_written) {
                    self.grid.putOverflow(cmdline_grid_id, 0, pre_grid_col, cluster.extras[0..cluster.extras_len]);
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
                const pre_col = grid_col;
                if (!writer.writeCell(sc.first_cp, 0)) break;
                const written = grid_col > pre_col;
                if (sc.display_width >= 2) {
                    if (!writer.writeCell(0, 0)) break;
                }
                if (sc.extras_len > 0 and written) {
                    self.grid.putOverflow(cmdline_grid_id, 0, pre_col, sc.extras[0..sc.extras_len]);
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
            return;
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
    } else if (!block_visible) {
        // No cmdline visible and no block visible - close the external float window
        sendCmdlineHide(self);
    }
}

/// Handle cmdline_block mode (multi-line input).
/// Shows all block lines + current cmdline line in a multi-row grid.
pub fn sendCmdlineBlockShow(self: *Core, current_line_visible: bool, visible_level: u32) void {
    const cmdline_grid_id = grid_mod.CMDLINE_GRID_ID;
    const block_lines = self.grid.cmdline_block.lines.items;
    const block_line_count: u32 = @intCast(block_lines.len);

    // Calculate total rows and max width
    // Minimum width = global grid width; frontend constrains to screen width
    const min_width: u32 = if (self.grid.cols > 0) self.grid.cols else 40;
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
        return;
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
                    if (col >= max_width) { byte_i = cluster.end_byte; break; }
                    self.grid.putCellGrid(cmdline_grid_id, row, col, '@' + cluster.first_cp, chunk.hl_id);
                    col += 1;
                } else if (cluster.first_cp == 0x7F) {
                    self.grid.putCellGrid(cmdline_grid_id, row, col, '^', chunk.hl_id);
                    col += 1;
                    if (col >= max_width) { byte_i = cluster.end_byte; break; }
                    self.grid.putCellGrid(cmdline_grid_id, row, col, '?', chunk.hl_id);
                    col += 1;
                } else {
                    self.grid.putCellGrid(cmdline_grid_id, row, col, cluster.first_cp, chunk.hl_id);
                    if (cluster.extras_len > 0) {
                        self.grid.putOverflow(cmdline_grid_id, row, col, cluster.extras[0..cluster.extras_len]);
                    }
                    col += 1;
                    if (cluster.display_width >= 2) {
                        if (col >= max_width) { byte_i = cluster.end_byte; break; }
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
                    self.grid.putCellGrid(cmdline_grid_id, block_line_count, col, pc.first_cp, state.prompt_hl_id);
                    if (pc.extras_len > 0) {
                        self.grid.putOverflow(cmdline_grid_id, block_line_count, col, pc.extras[0..pc.extras_len]);
                    }
                    col += 1;
                    if (pc.display_width >= 2) {
                        if (col >= max_width) { pbyte_i = pc.end_byte; break; }
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
                        if (col >= max_width) { byte_i = cluster.end_byte; break; }
                        self.grid.putCellGrid(cmdline_grid_id, block_line_count, col, '@' + cluster.first_cp, chunk.hl_id);
                        col += 1;
                    } else if (cluster.first_cp == 0x7F) {
                        self.grid.putCellGrid(cmdline_grid_id, block_line_count, col, '^', chunk.hl_id);
                        col += 1;
                        if (col >= max_width) { byte_i = cluster.end_byte; break; }
                        self.grid.putCellGrid(cmdline_grid_id, block_line_count, col, '?', chunk.hl_id);
                        col += 1;
                    } else {
                        self.grid.putCellGrid(cmdline_grid_id, block_line_count, col, cluster.first_cp, chunk.hl_id);
                        if (cluster.extras_len > 0) {
                            self.grid.putOverflow(cmdline_grid_id, block_line_count, col, cluster.extras[0..cluster.extras_len]);
                        }
                        col += 1;
                        if (cluster.display_width >= 2) {
                            if (col >= max_width) { byte_i = cluster.end_byte; break; }
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
                        self.grid.putCellGrid(cmdline_grid_id, block_line_count, col, sc.first_cp, 0);
                        if (sc.extras_len > 0) {
                            self.grid.putOverflow(cmdline_grid_id, block_line_count, col, sc.extras[0..sc.extras_len]);
                        }
                        col += 1;
                        if (sc.display_width >= 2) {
                            if (col >= max_width) { sbyte_i = sc.end_byte; break; }
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
        return;
    };

    // Set cursor position (on the last row - current cmdline line)
    self.grid.cursor_grid = cmdline_grid_id;
    self.grid.cursor_row = if (current_line_visible) block_line_count else block_line_count -| 1;
    self.grid.cursor_col = cursor_col;
    self.grid.cursor_valid = true;

    self.log.write("[cmdline_block] show: rows={d} cols={d} cursor_row={d} cursor_col={d}\n", .{ total_rows, max_width, self.grid.cursor_row, cursor_col });
}

/// Hide cmdline external window by removing from external grids
pub fn sendCmdlineHide(self: *Core) void {
    const cmdline_grid_id = grid_mod.CMDLINE_GRID_ID;

    // Remove from external grids.
    // Note: Don't call on_external_window_close here - it will be called by
    // notifyExternalWindowChanges() which detects the grid was removed from
    // external_grids but still exists in known_external_grids.
    _ = self.grid.external_grids.fetchRemove(cmdline_grid_id);

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
    defer self.grid.clearPopupmenuChanged();

    // Verbose logging disabled for performance
    // self.log.write("[popupmenu] notifyPopupmenuChanges visible={} items={d}\n", .{
    //     self.grid.popupmenu.visible,
    //     self.grid.popupmenu.items.items.len,
    // });

    if (self.grid.popupmenu.visible) {
        sendPopupmenuShow(self);
    } else {
        sendPopupmenuHide(self);
    }
}

/// Notify frontend of tabline changes.
pub fn notifyTablineChanges(self: *Core) void {
    if (!self.grid.tabline_state.dirty) return;
    if (!self.ext_tabline_enabled) return;
    defer self.grid.clearTablineDirty();

    const state = &self.grid.tabline_state;

    if (state.visible and state.tabs.items.len > 0) {
        self.log.write("[tabline] notify: curtab={d} tabs={d} visible={any}\n", .{ state.current_tab, state.tabs.items.len, state.visible });

        // Build C-compatible tab array
        var c_tabs = std.ArrayListUnmanaged(c_api.TabEntry){};
        defer c_tabs.deinit(self.alloc);

        for (state.tabs.items) |tab| {
            c_tabs.append(self.alloc, .{
                .tab_handle = tab.tab_handle,
                .name = tab.name.ptr,
                .name_len = tab.name.len,
            }) catch continue;
        }

        // Build C-compatible buffer array
        var c_buffers = std.ArrayListUnmanaged(c_api.BufferEntry){};
        defer c_buffers.deinit(self.alloc);

        for (state.buffers.items) |buf| {
            c_buffers.append(self.alloc, .{
                .buffer_handle = buf.buffer_handle,
                .name = buf.name.ptr,
                .name_len = buf.name.len,
            }) catch continue;
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
}

/// Show popupmenu as external window by creating a grid.
pub fn sendPopupmenuShow(self: *Core) void {
    const pum_grid_id = grid_mod.POPUPMENU_GRID_ID;
    const items = self.grid.popupmenu.items.items;
    const selected = self.grid.popupmenu.selected;
    const anchor_row = self.grid.popupmenu.row;
    const anchor_col = self.grid.popupmenu.col;
    const anchor_grid = self.grid.popupmenu.grid_id;

    if (items.len == 0) return;

    self.log.write("[popupmenu] show: anchor_grid={d} anchor_row={d} anchor_col={d} items={d}\n", .{ anchor_grid, anchor_row, anchor_col, items.len });

    // Calculate dimensions
    var max_width: u32 = 10;
    for (items) |item| {
        const item_width = countDisplayWidth(item.word);
        if (item_width > max_width) max_width = item_width;
    }
    // Limit height to reasonable number
    const max_height: u32 = 15;
    const height: u32 = @intCast(@min(items.len, max_height));
    const width: u32 = max_width + 2; // +2 for padding

    // Calculate scroll offset to keep selected item visible
    const selected_u: usize = if (selected >= 0) @intCast(selected) else 0;
    var scroll_offset: usize = 0;
    if (selected_u >= height) {
        // Selected item is below visible range, scroll to show it at bottom
        scroll_offset = selected_u - height + 1;
    }
    const display_start = scroll_offset;
    const display_end = @min(scroll_offset + height, items.len);

    // Create or resize popupmenu grid
    self.grid.resizeGrid(pum_grid_id, height, width) catch |e| {
        self.log.write("[popupmenu] resizeGrid failed: {any}\n", .{e});
        return;
    };
    self.grid.clearGrid(pum_grid_id);

    // Write items to grid (with scroll offset)
    for (items[display_start..display_end], 0..) |item, row_idx| {
        const row: u32 = @intCast(row_idx);
        const item_idx = display_start + row_idx;
        // Use different hl_id for selected item (PmenuSel vs Pmenu)
        // Note: selected = -1 means no selection, so only compare when selected >= 0
        const is_selected = (selected >= 0) and (item_idx == selected_u);
        const hl_id: u32 = if (is_selected) 1 else 0; // TODO: proper highlight

        // Write item.word to grid with padding
        var col: u32 = 1; // Start with 1 cell padding
        var iter = std.unicode.Utf8View.initUnchecked(item.word).iterator();
        while (iter.nextCodepoint()) |cp| {
            if (col >= width - 1) break; // Leave 1 cell padding at end
            self.grid.putCellGrid(pum_grid_id, row, col, cp, hl_id);
            col += 1;
            // Handle wide characters
            if (isWideChar(cp)) {
                if (col >= width - 1) break;
                self.grid.putCellGrid(pum_grid_id, row, col, 0, hl_id);
                col += 1;
            }
        }
    }

    // Register as external grid with position.
    // popupmenu_show reports the anchor cell directly. The frontend decides
    // whether to place the popupmenu below that row or flip it above.
    const is_cmdline_completion = (anchor_grid < 0 or anchor_grid == -1);
    const start_row: i32 = if (is_cmdline_completion)
        -1 // Special marker for cmdline completion (Swift will position above cmdline)
    else
        anchor_row;
    const start_col: i32 = anchor_col;

    self.grid.external_grids.put(self.alloc, pum_grid_id, .{
        .win = anchor_grid, // Store anchor grid ID for positioning
        .start_row = start_row,
        .start_col = start_col,
    }) catch |e| {
        self.log.write("[popupmenu] external_grids.put failed: {any}\n", .{e});
        return;
    };

    // Verbose logging disabled for performance
    // self.log.write("[popupmenu] show: size={d}x{d} pos=({d},{d})\n", .{width, height, start_row, start_col});
}

/// Hide popupmenu by removing from external grids.
pub fn sendPopupmenuHide(self: *Core) void {
    const pum_grid_id = grid_mod.POPUPMENU_GRID_ID;

    // Remove from external grids.
    // Note: Don't call on_external_window_close here - it will be called by
    // notifyExternalWindowChanges() which detects the grid was removed from
    // external_grids but still exists in known_external_grids.
    _ = self.grid.external_grids.fetchRemove(pum_grid_id);

    self.log.write("[popupmenu] hide\n", .{});
}

// --- ext_messages support ---

/// Check if msg_show throttle timeout has expired and process pending messages.
/// Called from frontend tick (zonvie_core_tick_msg_throttle) to ensure messages are
/// properly accumulated across multiple flush events before display (noice.nvim-style).
/// This must NOT be called from onFlush, as Neovim may send multiple msg_show events
/// across separate flush batches (e.g., list_cmd then shell_out for "!ls").
pub fn checkMsgShowThrottleTimeout(self: *Core) void {
    if (!self.ext_messages_enabled) return;

    const pending_since = self.msg_show_pending_since orelse return;
    const now = std.time.nanoTimestamp();
    const elapsed = now - pending_since;

    if (elapsed >= self.msg_show_throttle_ns) {
        self.log.write("[msg] throttle timeout: {d}ms elapsed >= {d}ms, processing\n", .{
            @divTrunc(elapsed, std.time.ns_per_ms),
            @divTrunc(self.msg_show_throttle_ns, std.time.ns_per_ms),
        });
        sendMsgShow(self);
        self.grid.message_state.pending_count = 0;
        self.grid.message_state.msg_dirty = false;
        self.msg_show_pending_since = null;
    }
}

/// Check if auto-hide timeout has expired for msg_show/msg_history grids.
/// Called from frontend tick (same as throttle timeout).
/// IMPORTANT: Caller must hold grid_mu (via c_api tick entry point).
pub fn checkMsgAutoHideTimeout(self: *Core) void {
    if (!self.ext_messages_enabled) return;
    const now = std.time.nanoTimestamp();

    // msg_show (grid -102) auto-hide
    if (self.msg_show_auto_hide_at) |hide_at| {
        if (now >= hide_at) {
            self.msg_show_auto_hide_at = null;
            self.log.write("[msg] auto-hide: msg_show timeout expired\n", .{});
            self.grid.message_state.clearMessages(self.grid.alloc);
            hideMsgShow(self);
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
            self.msg_history_auto_hide_at = null;
            self.log.write("[msg] auto-hide: msg_history timeout expired\n", .{});
            hideMsgHistory(self);
            self.grid.msg_history_state.clear(self.grid.alloc);
            // Same guard: only notify if it was actually tracked
            if (self.known_external_grids.remove(grid_mod.MSG_HISTORY_GRID_ID)) {
                if (self.cb.on_external_window_close) |cb| {
                    cb(self.ctx, grid_mod.MSG_HISTORY_GRID_ID);
                }
            }
        }
    }
}

/// Handle message changes - notify frontend via callbacks.
/// Uses throttle for msg_show (like noice.nvim) to accumulate messages before deciding view.
pub fn notifyMessageChanges(self: *Core) void {
    if (!self.ext_messages_enabled) return;

    const msg_dirty = self.grid.message_state.msg_dirty;
    const confirm_dirty = self.grid.message_state.confirm_dirty;
    const showmode_dirty = self.grid.message_state.showmode_dirty;
    const showcmd_dirty = self.grid.message_state.showcmd_dirty;
    const ruler_dirty = self.grid.message_state.ruler_dirty;
    const history_dirty = self.grid.msg_history_state.dirty;

    // Also check if there's a pending throttle timeout to handle
    const has_pending_throttle = self.msg_show_pending_since != null;

    if (!msg_dirty and !confirm_dirty and !showmode_dirty and !showcmd_dirty and !ruler_dirty and !history_dirty and !has_pending_throttle) return;

    // Note: We don't use defer for clearMessageDirty anymore because msg_dirty
    // should only be cleared after throttle period expires
    defer self.grid.clearMsgHistoryDirty();

    // Guard: at most one on_msg_clear per flush cycle
    var sent_msg_clear = false;

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
            hideMsgShow(self);
            self.msg_show_pending_since = null;
            self.msg_show_auto_hide_at = null;
            if (self.cb.on_msg_clear) |cb| {
                cb(self.ctx);
            }
            sent_msg_clear = true;
        }

        const messages = self.grid.message_state.messages.items;
        if (messages.len == 0) {
            if (!cleared_in_batch) {
                // Pure empty (not from same-batch clear which was already handled above)
                hideMsgShow(self);
                self.msg_show_pending_since = null;
                self.msg_show_auto_hide_at = null;
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
                    self.msg_show_pending_since = std.time.nanoTimestamp();
                }
            } else {
                // Other messages (including list_cmd): display immediately
                sendMsgShow(self);
                self.msg_show_pending_since = null;
            }
        }
    }

    self.grid.message_state.msg_dirty = false;
    self.grid.message_state.confirm_dirty = false;
    self.grid.message_state.showmode_dirty = false;
    self.grid.message_state.showcmd_dirty = false;
    self.grid.message_state.ruler_dirty = false;

    // Handle showmode/showcmd/ruler changes only when their respective dirty flag is set
    if (showmode_dirty) {
        sendMsgShowmode(self);
    }
    if (showcmd_dirty) {
        sendMsgShowcmd(self);
    }
    if (ruler_dirty) {
        sendMsgRuler(self);
    }

    // Handle msg_history_show
    if (history_dirty) {
        sendMsgHistoryShow(self);
    }
}

/// Send msg_show as external grid (like popupmenu pattern).
/// Confirm dialogs are sent via callback (special case for cmdline mode).
pub fn sendMsgShow(self: *Core) void {
    const msg_grid_id = grid_mod.MESSAGE_GRID_ID;
    const messages = self.grid.message_state.messages.items;

    if (messages.len == 0) {
        // Full state reset (scroll, cache, grid -102) then explicit on_msg_clear
        hideMsgShow(self);
        self.msg_show_auto_hide_at = null;
        self.log.write("[msg] sendMsgShow: hide (empty)\n", .{});
        if (self.cb.on_msg_clear) |cb| {
            cb(self.ctx);
        }
        return;
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

    // Route each message individually and track which views are needed
    var has_ext_float = false;
    var has_split = false;
    var split_auto_dismiss = false;
    var max_ext_float_timeout: f32 = 0;

    for (messages) |msg| {
        const chunks = msg.content.items;
        const route_result = self.msg_config.routeMessage(.msg_show, msg.kind, total_line_count);

        self.log.write("[msg] sendMsgShow: kind={s} lines={d} routed to view={s} timeout={d:.1}\n", .{
            msg.kind,
            total_line_count,
            @tagName(route_result.view),
            route_result.timeout,
        });

        switch (route_result.view) {
            .none => {
                // Don't show this message
            },
            .mini => {
                // Send to frontend callback for mini view display
                self.log.write("[msg] sendMsgShow: view=mini, sending to callback\n", .{});
                sendMsgShowCallback(self, msg, chunks, route_result.view, route_result.timeout);
            },
            .confirm => {
                // return_prompt routes here via config.zig hardcoding.
                // confirm/confirm_sub are in confirm_msg (Step 5), not here.
                // Send via callback regardless (safety for return_prompt + fallback).
                self.log.write("[msg] sendMsgShow: view=confirm, sending to callback\n", .{});
                sendMsgShowCallback(self, msg, chunks, route_result.view, 0);
            },
            .notification => {
                // Send to frontend callback for OS notification display (no timeout)
                self.log.write("[msg] sendMsgShow: view=notification, sending to callback\n", .{});
                sendMsgShowCallback(self, msg, chunks, route_result.view, 0);
            },
            .ext_float => {
                has_ext_float = true;
                if (route_result.timeout > max_ext_float_timeout)
                    max_ext_float_timeout = route_result.timeout;
            },
            .split => {
                has_split = true;
                if (route_result.auto_dismiss) split_auto_dismiss = true;
            },
        }
    }

    // Handle ext_float view (renders all ext_float-routed messages together)
    if (has_ext_float) {
        self.log.write("[msg] sendMsgShow: view=ext_float, rendering message grid\n", .{});
        buildMsgLineCache(self);
        self.msg_scroll_offset = 0;
        renderMsgGridFromCache(self, 0);

        // Set auto-hide timeout (timeout=0 means no auto-hide, e.g. errors)
        if (max_ext_float_timeout > 0) {
            const timeout_ns: i128 = @intFromFloat(
                max_ext_float_timeout * @as(f32, @floatFromInt(std.time.ns_per_s)),
            );
            self.msg_show_auto_hide_at = std.time.nanoTimestamp() + timeout_ns;
        } else {
            self.msg_show_auto_hide_at = null;
        }
    }

    // Handle split view (renders all split-routed messages together)
    if (has_split) {
        self.log.write("[msg] sendMsgShow: view=split (auto_dismiss={}), creating split window\n", .{split_auto_dismiss});

        // auto_dismiss: send <CR> to clear any pending prompt (e.g. return_prompt)
        if (split_auto_dismiss) {
            self.requestInput("<CR>") catch {};
        }

        // Clear any pending prompt windows on frontend
        if (self.cb.on_msg_clear) |cb| {
            cb(self.ctx);
        }

        // Build content string from split-routed messages only
        var content_buf: [8192]u8 = undefined;
        var content_len: usize = 0;
        var split_line_count: u32 = 0;
        for (messages) |m| {
            // Only include messages that route to split
            const route_result = self.msg_config.routeMessage(.msg_show, m.kind, total_line_count);
            if (route_result.view != .split) continue;

            for (m.content.items) |chunk| {
                const copy_len = @min(chunk.text.len, content_buf.len - content_len);
                @memcpy(content_buf[content_len..][0..copy_len], chunk.text[0..copy_len]);
                content_len += copy_len;
                if (content_len >= content_buf.len) break;
                // Count lines
                for (chunk.text[0..copy_len]) |ch| {
                    if (ch == '\n') split_line_count += 1;
                }
            }
            // Add newline between messages
            if (content_len < content_buf.len - 1) {
                content_buf[content_len] = '\n';
                content_len += 1;
                split_line_count += 1;
            }
        }
        self.createMessageSplit(content_buf[0..content_len], split_line_count, true, true, null) catch |e| {
            self.log.write("[msg] createMessageSplit failed: {any}\n", .{e});
        };
    }

    // If no ext_float messages, remove the message grid
    if (!has_ext_float) {
        _ = self.grid.external_grids.fetchRemove(msg_grid_id);
        self.msg_show_auto_hide_at = null; // prevent stale timer
    }
}

/// Build line cache from current messages (called once when messages change).
/// Only includes messages that route to ext_float view.
pub fn buildMsgLineCache(self: *Core) void {
    const messages = self.grid.message_state.messages.items;

    // Clear existing cache
    self.msg_line_cache.clearRetainingCapacity();
    self.msg_cache_valid = false;
    self.msg_total_lines = 0;
    self.msg_cached_max_width = 10;

    if (messages.len == 0) return;

    var max_width: u32 = 10;

    for (messages) |m| {
        // Only include messages that route to ext_float
        const route_result = self.msg_config.routeMessage(.msg_show, m.kind, 1);
        if (route_result.view != .ext_float) continue;
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
                    if (current_line.len > 0 or self.msg_line_cache.items.len > 0) {
                        current_line.display_width = @intCast(countDisplayWidth(current_line.data[0..current_line.len]));
                        if (current_line.display_width > max_width) max_width = current_line.display_width;
                        self.msg_line_cache.append(self.alloc, current_line) catch break;
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
        if (current_line.len > 0 or self.msg_line_cache.items.len == 0) {
            current_line.display_width = @intCast(countDisplayWidth(current_line.data[0..current_line.len]));
            if (current_line.display_width > max_width) max_width = current_line.display_width;
            self.msg_line_cache.append(self.alloc, current_line) catch {};
        }
    }

    self.msg_total_lines = @intCast(self.msg_line_cache.items.len);
    self.msg_cached_max_width = max_width;
    self.msg_cache_valid = true;

    self.log.write("[msg] buildMsgLineCache: {d} lines cached, max_width={d}\n", .{
        self.msg_line_cache.items.len,
        max_width,
    });
}

/// Render msg_show grid from cache (fast path for scrolling).
pub fn renderMsgGridFromCache(self: *Core, scroll_offset: u32) void {
    const msg_grid_id = grid_mod.MESSAGE_GRID_ID;
    const lines = self.msg_line_cache.items;

    if (lines.len == 0) return;

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
        return;
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
    self.grid.external_grids.put(self.alloc, msg_grid_id, .{
        .win = 1, // Global grid
        .start_row = -2, // Special marker: position at top-right
        .start_col = -2,
    }) catch |e| {
        self.log.write("[msg] external_grids.put failed: {any}\n", .{e});
        return;
    };
}

/// Handle scroll event for msg_show grid (Zonvie's own grid).
/// Updates scroll offset and re-renders grid content.
pub fn handleMsgGridScroll(self: *Core, direction: []const u8) void {
    // Check if message grid is active
    if (!self.grid.external_grids.contains(grid_mod.MESSAGE_GRID_ID)) {
        self.log.write("[msg] handleMsgGridScroll: grid not active\n", .{});
        return;
    }

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
        const now = std.time.nanoTimestamp();
        const throttle_ns: i128 = 16 * std.time.ns_per_ms;
        const elapsed = now - self.msg_scroll_last_send;

        if (elapsed >= throttle_ns) {
            self.log.write("[msg] handleMsgGridScroll: {s} offset {d} (send)\n", .{ direction, new_offset });
            renderMsgGridFromCache(self, new_offset);
            sendExternalGridVerticesFiltered(self, true, grid_mod.MESSAGE_GRID_ID);
            self.msg_scroll_last_send = now;
            self.msg_scroll_pending = false;
        } else {
            // Mark pending - will be processed on next throttle window or flush
            self.msg_scroll_pending = true;
        }
    }
}

/// Process pending scroll update (called from flush or timer).
pub fn processPendingMsgScroll(self: *Core) void {
    if (!self.msg_scroll_pending) return;
    if (!self.grid.external_grids.contains(grid_mod.MESSAGE_GRID_ID)) return;

    self.log.write("[msg] processPendingMsgScroll: offset {d}\n", .{self.msg_scroll_offset});
    renderMsgGridFromCache(self, self.msg_scroll_offset);
    sendExternalGridVerticesFiltered(self, true, grid_mod.MESSAGE_GRID_ID);
    self.msg_scroll_last_send = std.time.nanoTimestamp();
    self.msg_scroll_pending = false;
}

/// Hide msg_show external grid.
pub fn hideMsgShow(self: *Core) void {
    const msg_grid_id = grid_mod.MESSAGE_GRID_ID;
    _ = self.grid.external_grids.fetchRemove(msg_grid_id);
    // Reset scroll state and invalidate cache
    self.msg_scroll_offset = 0;
    self.msg_total_lines = 0;
    self.msg_cached_max_width = 0;
    self.msg_cache_valid = false;
    self.msg_line_cache.clearRetainingCapacity();
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
        0, 0, 0, // replace_last, history, append
        cm.id,
        0, // timeout_ms
    );
}

/// Send msg_show callback to frontend (helper for short messages or fallback).
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

    // Convert timeout from seconds to milliseconds
    const timeout_ms: u32 = if (timeout_sec > 0) @intFromFloat(timeout_sec * 1000.0) else 0;

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

    // Hide msg_show external grid
    hideMsgShow(self);
    self.msg_show_auto_hide_at = null;

    // Hide msg_history external grid
    hideMsgHistory(self);
    self.msg_history_auto_hide_at = null;

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

/// Send msg_showmode callback to frontend.
pub fn sendMsgShowmode(self: *Core) void {
    const chunks = self.grid.message_state.showmode_content.items;

    // Route message using config
    const route_result = self.msg_config.routeMessage(.msg_showmode, "", 1);
    self.log.write("[msg] sendMsgShowmode chunks={d} routed to view={s}\n", .{ chunks.len, @tagName(route_result.view) });

    if (route_result.view == .none) return; // Don't show anything

    const cb = self.cb.on_msg_showmode orelse return;

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

/// Send msg_showcmd callback to frontend.
pub fn sendMsgShowcmd(self: *Core) void {
    const chunks = self.grid.message_state.showcmd_content.items;

    // Route message using config
    const route_result = self.msg_config.routeMessage(.msg_showcmd, "", 1);
    self.log.write("[msg] sendMsgShowcmd chunks={d} routed to view={s}\n", .{ chunks.len, @tagName(route_result.view) });

    if (route_result.view == .none) return; // Don't show anything

    const cb = self.cb.on_msg_showcmd orelse return;

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

/// Send msg_ruler callback to frontend.
pub fn sendMsgRuler(self: *Core) void {
    const chunks = self.grid.message_state.ruler_content.items;

    // Route message using config
    const route_result = self.msg_config.routeMessage(.msg_ruler, "", 1);
    self.log.write("[msg] sendMsgRuler chunks={d} routed to view={s}\n", .{ chunks.len, @tagName(route_result.view) });

    if (route_result.view == .none) return; // Don't show anything

    const cb = self.cb.on_msg_ruler orelse return;

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

/// Show msg_history as external grid (like popupmenu pattern).
pub fn sendMsgHistoryShow(self: *Core) void {
    const history_grid_id = grid_mod.MSG_HISTORY_GRID_ID;
    const entries = self.grid.msg_history_state.entries.items;

    if (entries.len == 0) {
        // No entries - hide the history window if visible
        _ = self.grid.external_grids.fetchRemove(history_grid_id);
        self.msg_history_auto_hide_at = null;
        self.log.write("[msg_history] hide (empty)\n", .{});
        return;
    }

    // Route message using config (use entry count as line count)
    const route_result = self.msg_config.routeMessage(.msg_history_show, "", @intCast(entries.len));
    self.log.write("[msg_history] entries={d} routed to view={s}\n", .{ entries.len, @tagName(route_result.view) });

    // Handle based on routing result
    switch (route_result.view) {
        .none => {
            // Don't show anything
            _ = self.grid.external_grids.fetchRemove(history_grid_id);
            self.msg_history_auto_hide_at = null;
            self.log.write("[msg_history] view=none, hiding\n", .{});
            return;
        },
        .mini => {
            // Mini view: send all entries combined to frontend callback
            self.msg_history_auto_hide_at = null;
            self.log.write("[msg_history] view=mini, sending {d} entries to callback\n", .{entries.len});
            sendMsgHistoryCallbackAll(self, entries, route_result.view);
            return;
        },
        .notification => {
            // Notification view: send all entries combined to frontend callback for OS notification
            self.msg_history_auto_hide_at = null;
            self.log.write("[msg_history] view=notification, sending {d} entries to callback\n", .{entries.len});
            sendMsgHistoryCallbackAll(self, entries, route_result.view);
            return;
        },
        .split => {
            // Split view: create Neovim split window
            self.msg_history_auto_hide_at = null;
            self.log.write("[msg_history] view=split (auto_dismiss={}), creating split window\n", .{route_result.auto_dismiss});

            // auto_dismiss: send <CR> to clear any pending prompt (e.g. return_prompt)
            // This allows split view to display without user pressing Enter
            if (route_result.auto_dismiss) {
                self.requestInput("<CR>") catch {};
            }

            // Clear any pending prompt windows on frontend
            if (self.cb.on_msg_clear) |cb| {
                cb(self.ctx);
            }

            // Build content string from all entries
            var content_buf: [8192]u8 = undefined;
            var content_len: usize = 0;
            for (entries) |entry| {
                for (entry.content.items) |chunk| {
                    const copy_len = @min(chunk.text.len, content_buf.len - content_len);
                    @memcpy(content_buf[content_len..][0..copy_len], chunk.text[0..copy_len]);
                    content_len += copy_len;
                    if (content_len >= content_buf.len) break;
                }
                // Add newline between entries
                if (content_len < content_buf.len - 1) {
                    content_buf[content_len] = '\n';
                    content_len += 1;
                }
            }
            self.createMessageSplit(content_buf[0..content_len], @intCast(entries.len), true, true, null) catch |e| {
                self.log.write("[msg_history] createMessageSplit failed: {any}\n", .{e});
            };
            return;
        },
        else => {
            // Continue to external grid rendering below (ext_float, confirm)
        },
    }

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

    if (line_count == 0) return;

    // Calculate grid dimensions
    const max_height: u32 = 20;
    const height: u32 = @intCast(@min(line_count, max_height));
    const width: u32 = @min(max_width + 2, 80); // +2 for padding, max 80

    self.log.write("[msg_history] show: entries={d} size={d}x{d}\n", .{ entries.len, width, height });

    // Create or resize grid
    self.grid.resizeGrid(history_grid_id, height, width) catch |e| {
        self.log.write("[msg_history] resizeGrid failed: {any}\n", .{e});
        return;
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
    self.grid.external_grids.put(self.alloc, history_grid_id, .{
        .win = 1, // Global grid
        .start_row = -2, // Special marker: position like msg_show (top-right)
        .start_col = -2,
    }) catch |e| {
        self.log.write("[msg_history] external_grids.put failed: {any}\n", .{e});
        return;
    };

    // Set auto-hide timeout (timeout=0 means no auto-hide)
    if (route_result.timeout > 0) {
        const timeout_ns: i128 = @intFromFloat(
            route_result.timeout * @as(f32, @floatFromInt(std.time.ns_per_s)),
        );
        self.msg_history_auto_hide_at = std.time.nanoTimestamp() + timeout_ns;
    } else {
        self.msg_history_auto_hide_at = null;
    }
}

/// Hide msg_history external grid.
pub fn hideMsgHistory(self: *Core) void {
    const history_grid_id = grid_mod.MSG_HISTORY_GRID_ID;
    _ = self.grid.external_grids.fetchRemove(history_grid_id);
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
        if (map.contains(key)) return map.get(key).?;
    }

    // Fall back to persistent overflow map (no float overlay at this cell)
    if (core.grid.cell_overflow.count() == 0) return null;
    const gid = rc.grid_ids.items[@intCast(comp_col)];
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
pub fn cellIsEmojiCluster(core: *Core, rc: *const RenderCells, comp_row: u32, comp_col: u32) bool {
    const extras = getOverflowForCell(core, rc, comp_row, comp_col) orelse return false;
    for (extras) |extra| {
        if (extra == 0xFE0F or extra == 0x200D or (extra >= 0x1F3FB and extra <= 0x1F3FF)) return true;
    }
    return false;
}

/// Build a cache key for a cell's full cluster (base scalar + overflow extras + style).
/// Overflow extras are folded into the key so different ZWJ sequences with the same
/// first scalar (e.g., 👩‍💻 vs 👩‍🔬) get distinct cache entries.
pub fn clusterCacheKey(first_scalar: u32, style_index: u32, overflow: ?[]const u32) u64 {
    // Start with base key: scalar + style
    var key: u64 = (@as(u64, first_scalar) << 2) | @as(u64, style_index);
    // Fold in overflow codepoints
    if (overflow) |extras| {
        for (extras) |cp| {
            // FNV-1a-like mixing into upper bits
            key ^= @as(u64, cp) *% 0x517cc1b727220a95;
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

/// Populate core.emoji_cluster_buf from a cell's base scalar + overflow extras.
fn setEmojiClusterFromOverflow(core: *Core, rc: *const RenderCells, comp_row: u32, comp_col: u32, base_scalar: u32) void {
    core.emoji_cluster_buf[0] = base_scalar;
    var len: u8 = 1;
    if (getOverflowForCell(core, rc, comp_row, comp_col)) |extras| {
        for (extras) |extra| {
            if (len < core.emoji_cluster_buf.len) {
                core.emoji_cluster_buf[len] = extra;
                len += 1;
            }
        }
    }
    core.emoji_cluster_len = len;
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
        .first_cp = 0, .codepoint_count = 0, .display_width = 0,
        .end_byte = start, .extras = undefined, .extras_len = 0,
    };
    const first_cp = std.unicode.utf8Decode(first_slice) catch return .{
        .first_cp = 0xFFFD, .codepoint_count = 1, .display_width = 1,
        .end_byte = it.i, .extras = undefined, .extras_len = 0,
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
            (cp2 >= 0xE0020 and cp2 <= 0xE007F));
        const after_zwj = prev_cp == 0x200D;

        if (is_cluster_ext or after_zwj) {
            if (extras_len < extras.len) {
                extras[extras_len] = cp2;
                extras_len += 1;
            }
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
