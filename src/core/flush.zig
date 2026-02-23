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

pub const GridEntry = struct {
    grid_id: i64,
    zindex: i64,
    compindex: i64,
    order: u64,
};

// Pre-computed subgrid info for row-mode compose optimization.
// Caches win_pos/sub_grids lookups to avoid per-row hash map access.
pub const MAX_CACHED_SUBGRIDS = 32;
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

    pub fn ensureTotalCapacity(self: *RenderCells, alloc: std.mem.Allocator, n: usize) !void {
        try self.scalars.ensureTotalCapacity(alloc, n);
        try self.fg_rgbs.ensureTotalCapacity(alloc, n);
        try self.bg_rgbs.ensureTotalCapacity(alloc, n);
        try self.sp_rgbs.ensureTotalCapacity(alloc, n);
        try self.grid_ids.ensureTotalCapacity(alloc, n);
        try self.style_flags_arr.ensureTotalCapacity(alloc, n);
    }

    pub fn setLen(self: *RenderCells, n: usize) void {
        self.scalars.items.len = n;
        self.fg_rgbs.items.len = n;
        self.bg_rgbs.items.len = n;
        self.sp_rgbs.items.len = n;
        self.grid_ids.items.len = n;
        self.style_flags_arr.items.len = n;
    }

    pub fn clearRetainingCapacity(self: *RenderCells) void {
        self.scalars.clearRetainingCapacity();
        self.fg_rgbs.clearRetainingCapacity();
        self.bg_rgbs.clearRetainingCapacity();
        self.sp_rgbs.clearRetainingCapacity();
        self.grid_ids.clearRetainingCapacity();
        self.style_flags_arr.clearRetainingCapacity();
    }

    pub fn deinit(self: *RenderCells, alloc: std.mem.Allocator) void {
        self.scalars.deinit(alloc);
        self.fg_rgbs.deinit(alloc);
        self.bg_rgbs.deinit(alloc);
        self.sp_rgbs.deinit(alloc);
        self.grid_ids.deinit(alloc);
        self.style_flags_arr.deinit(alloc);
    }

    /// Write a single cell at index i.
    pub inline fn set(self: *RenderCells, i: usize, scalar: u32, fg: u32, bg: u32, sp: u32, gid: i64, flags: u8) void {
        self.scalars.items[i] = scalar;
        self.fg_rgbs.items[i] = fg;
        self.bg_rgbs.items[i] = bg;
        self.sp_rgbs.items[i] = sp;
        self.grid_ids.items[i] = gid;
        self.style_flags_arr.items[i] = flags;
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
    len: u8 = 0,
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

        // Notify frontend about scrolled grids BEFORE vertex generation.
        // This allows Swift to clear pixel offsets before new vertices are rendered,
        // preventing double-shift glitches in split windows.
        const scrolled_count = ctx.core.grid.scrolled_grid_count;
        if (perf_enabled and scrolled_count > 0) {
            ctx.core.log.write("[scroll_debug] flush_begin scrolled_grids={d} content_rev={d} dirty_all={any}\n", .{
                scrolled_count, ctx.core.grid.content_rev, ctx.core.grid.dirty_all,
            });
        }
        if (ctx.core.cb.on_grid_scroll) |cb| {
            for (ctx.core.grid.scrolled_grid_ids[0..scrolled_count]) |grid_id| {
                cb(ctx.core.ctx, grid_id);
            }
        }
        ctx.core.grid.clearScrolledGrids();

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

        // Check msg_show throttle timeout for external commands
        ctx.core.checkMsgShowThrottleTimeout();

        // Process cmdline changes BEFORE generating vertices
        // This ensures cursor position is restored before vertex generation
        notifyCmdlineChanges(ctx.core);

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
        // Prefer partial updates when available.
        if (ctx.core.cb.on_vertices_partial != null or ctx.core.cb.on_vertices != null) {
            const pf_opt = ctx.core.cb.on_vertices_partial;
            const vf_opt = ctx.core.cb.on_vertices;

            // Decide what needs rebuilding/sending.
            const need_main: bool = (ctx.core.grid.content_rev != ctx.core.last_sent_content_rev);
            const need_cursor: bool = (ctx.core.grid.cursor_rev != ctx.core.last_sent_cursor_rev);

            // If nothing changed, avoid doing any work.
            if (!need_main and !need_cursor) return;

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

                /// Compute DECO_SCROLLABLE flag for a cell at main grid row `r` with the given grid_id.
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
                var cached_subgrids: [MAX_CACHED_SUBGRIDS]CachedSubgrid = undefined;
                var cached_subgrid_count: usize = 0;
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
                // Row callback mode: send only dirty rows (main grid)
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

                    // Initialize dynamic caches if not already done
                    ctx.core.initHlCache() catch {
                        ctx.core.log.write("[flush] Failed to initialize hl cache\n", .{});
                    };
                    ctx.core.initGlyphCache() catch {
                        ctx.core.log.write("[flush] Failed to initialize glyph cache\n", .{});
                    };

                    // HL cache: direct-index for O(1) lookup
                    // Uses heap-allocated buffers from NvimCore (sized by hl_cache_size config)
                    const hl_cache: []highlight.ResolvedAttrWithStyles = ctx.core.hl_cache_buf orelse &.{};
                    const hl_valid: []bool = ctx.core.hl_valid_buf orelse &.{};
                    const hl_cache_limit: u32 = @intCast(hl_valid.len);
                    @memset(hl_valid, false);

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
                    // Glyph cache is persistent across flushes.
                    // It is only reset on font changes (see onGuifont).
                    // NOTE: Do NOT call resetGlyphCacheFlags() here. With Phase 2
                    // (core-managed atlas), clearing the cache every flush causes
                    // every glyph to be re-rasterized every frame, filling the atlas
                    // and triggering constant atlas resets.

                    // Get dynamic cache references (fallback to empty if not initialized)
                    const glyph_cache_ascii = ctx.core.glyph_cache_ascii;
                    const glyph_valid_ascii = ctx.core.glyph_valid_ascii;
                    const glyph_cache_non_ascii = ctx.core.glyph_cache_non_ascii;
                    const glyph_keys_non_ascii = ctx.core.glyph_keys_non_ascii;
                    const GLYPH_CACHE_ASCII_SIZE = ctx.core.glyph_cache_ascii_size;
                    const GLYPH_CACHE_NON_ASCII_SIZE = ctx.core.glyph_cache_non_ascii_size;

                    // Get viewport margins for scrollable row detection
                    const main_margins = ctx.core.grid.getViewportMargins(1);

                    var saw_atlas_reset: bool = false;
                    var atlas_retried: bool = false;

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
                            if (log_enabled) {
                                log_dirty_rows = rows; // Retry processes all rows
                                t_rows_start_ns = std.time.nanoTimestamp();
                            }
                            // hl_valid does NOT need reset: hl data is atlas-independent
                            // glyph caches already cleared by resetGlyphCacheFlags() inside resetCoreAtlas()
                        }

                    var r: u32 = 0;
                    while (r < rows) : (r += 1) {
                        if (!effective_rebuild_all) {
                            if (!ctx.core.grid.dirty_rows.isSet(@as(usize, r))) continue;
                        }

                        // Compute scrollable flag for this row: content rows get DECO_SCROLLABLE, margin rows (tabline/statusline) do not
                        const main_scrollable: u32 = if (r >= main_margins.top and r < rows -| main_margins.bottom) c_api.DECO_SCROLLABLE else 0;

                        var out = &ctx.core.row_verts;
                        out.clearRetainingCapacity();

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
                                    row_cells.set(@intCast(tc), cell.cp, a2.fg, a2.bg, a2.sp, csg.grid_id, a2.style_flags);
                                }
                            }
                        }

                        // Row-mode timing for background measurement
                        var t_row_compose_end: i128 = 0;
                        var t_row_bg_start: i128 = 0;
                        if (log_enabled) {
                            t_row_compose_end = std.time.nanoTimestamp();
                            t_row_bg_start = t_row_compose_end;
                        }

                        // 1) Background: run-length by bgRGB and grid_id for this row
                        {
                            var c: u32 = 0;
                            while (c < cols) {
                                const run_bg = row_cells.bg_rgbs.items[@intCast(c)];
                                const run_grid_id = row_cells.grid_ids.items[@intCast(c)];
                                const run_start = c;

                                const end: u32 = @intCast(@min(
                                    simdFindRunEndU32(row_cells.bg_rgbs.items, @intCast(c), @intCast(cols), run_bg),
                                    simdFindRunEndI64(row_cells.grid_ids.items, @intCast(c), @intCast(cols), run_grid_id),
                                ));

                                const x0: f32 = @as(f32, @floatFromInt(run_start)) * cellW;
                                const x1: f32 = @as(f32, @floatFromInt(end)) * cellW;
                                const y0: f32 = @as(f32, @floatFromInt(r)) * cellH;
                                const y1: f32 = y0 + cellH;

                                // Use semi-transparent alpha for default background (blur/transparency)
                                const bg_alpha: f32 = if (run_bg == ctx.core.hl.default_bg)
                                    (if (ctx.core.blur_enabled) 0.5 else ctx.core.background_opacity)
                                else
                                    1.0;
                                const scroll_flag: u32 = Helpers.computeScrollFlag(r, run_grid_id, main_scrollable, cached_subgrids[0..cached_subgrid_count]);
                                try Helpers.pushSolidQuad(out, ctx.core.alloc, x0, y0, x1, y1, Helpers.rgba(run_bg, bg_alpha), dw, dh, run_grid_id, scroll_flag);
                                c = end;
                            }
                        }

                        // Row-mode timing for performance measurement
                        var t_row_bg_end: i128 = 0;
                        var t_row_under_deco_start: i128 = 0;
                        if (log_enabled) {
                            t_row_bg_end = std.time.nanoTimestamp();
                            t_row_under_deco_start = t_row_bg_end;
                        }

                        // 2) Under-decorations (drawn behind glyphs): underline, underdouble, undercurl, underdotted, underdashed
                        {
                            var c: u32 = 0;
                            while (c < cols) {
                                const cell_style_flags = row_cells.style_flags_arr.items[@intCast(c)];
                                const under_deco_mask = STYLE_UNDERLINE | STYLE_UNDERDOUBLE | STYLE_UNDERCURL | STYLE_UNDERDOTTED | STYLE_UNDERDASHED;
                                if (cell_style_flags & under_deco_mask == 0) {
                                    c += 1;
                                    continue;
                                }

                                // Find run of cells with same decoration style
                                const run_start = c;
                                const run_flags = cell_style_flags;
                                const run_sp = row_cells.sp_rgbs.items[@intCast(c)];
                                const run_fg = row_cells.fg_rgbs.items[@intCast(c)];
                                const run_grid_id = row_cells.grid_ids.items[@intCast(c)];

                                const run_end: u32 = @intCast(@min(
                                    simdFindRunEndU8(row_cells.style_flags_arr.items, @intCast(c + 1), @intCast(cols), run_flags),
                                    @min(
                                        simdFindRunEndU32(row_cells.sp_rgbs.items, @intCast(c + 1), @intCast(cols), run_sp),
                                        simdFindRunEndI64(row_cells.grid_ids.items, @intCast(c + 1), @intCast(cols), run_grid_id),
                                    ),
                                ));

                                // Use special color if set, otherwise foreground
                                const deco_color = if (run_sp != highlight.Highlights.SP_NOT_SET) Helpers.rgb(run_sp) else Helpers.rgb(run_fg);
                                const deco_scroll_flag: u32 = Helpers.computeScrollFlag(r, run_grid_id, main_scrollable, cached_subgrids[0..cached_subgrid_count]);

                                const x0: f32 = @as(f32, @floatFromInt(run_start)) * cellW;
                                const x1: f32 = @as(f32, @floatFromInt(run_end)) * cellW;
                                const row_y: f32 = @as(f32, @floatFromInt(r)) * cellH;

                                // Underline: 1px line at bottom of cell
                                if (run_flags & STYLE_UNDERLINE != 0) {
                                    const y0 = row_y + cellH - 2.0;
                                    const y1 = y0 + 1.0;
                                    try Helpers.pushDecoQuad(out, ctx.core.alloc, x0, y0, x1, y1, deco_color, dw, dh, run_grid_id, c_api.DECO_UNDERLINE | deco_scroll_flag, 0);
                                }

                                // Underdouble: 2 lines at bottom with clear gap
                                if (run_flags & STYLE_UNDERDOUBLE != 0) {
                                    const y0_1 = row_y + cellH - 6.0;
                                    const y1_1 = y0_1 + 1.0;
                                    const y0_2 = row_y + cellH - 2.0;
                                    const y1_2 = y0_2 + 1.0;
                                    try Helpers.pushDecoQuad(out, ctx.core.alloc, x0, y0_1, x1, y1_1, deco_color, dw, dh, run_grid_id, c_api.DECO_UNDERLINE | deco_scroll_flag, 0);
                                    try Helpers.pushDecoQuad(out, ctx.core.alloc, x0, y0_2, x1, y1_2, deco_color, dw, dh, run_grid_id, c_api.DECO_UNDERLINE | deco_scroll_flag, 0);
                                }

                                // Undercurl: wavy line (shader-based)
                                if (run_flags & STYLE_UNDERCURL != 0) {
                                    const y0 = row_y + cellH - 4.0;
                                    const y1 = row_y + cellH;
                                    const phase: f32 = @floatFromInt(run_start);
                                    try Helpers.pushDecoQuad(out, ctx.core.alloc, x0, y0, x1, y1, deco_color, dw, dh, run_grid_id, c_api.DECO_UNDERCURL | deco_scroll_flag, phase);
                                }

                                // Underdotted: dotted line (shader-based)
                                if (run_flags & STYLE_UNDERDOTTED != 0) {
                                    const y0 = row_y + cellH - 2.0;
                                    const y1 = y0 + 1.0;
                                    try Helpers.pushDecoQuad(out, ctx.core.alloc, x0, y0, x1, y1, deco_color, dw, dh, run_grid_id, c_api.DECO_UNDERDOTTED | deco_scroll_flag, 0);
                                }

                                // Underdashed: dashed line (shader-based)
                                if (run_flags & STYLE_UNDERDASHED != 0) {
                                    const y0 = row_y + cellH - 2.0;
                                    const y1 = y0 + 1.0;
                                    try Helpers.pushDecoQuad(out, ctx.core.alloc, x0, y0, x1, y1, deco_color, dw, dh, run_grid_id, c_api.DECO_UNDERDASHED | deco_scroll_flag, 0);
                                }

                                c = run_end;
                            }
                        }

                        var t_row_under_deco_end: i128 = 0;
                        var t_row_glyph_start: i128 = 0;
                        if (log_enabled) {
                            t_row_under_deco_end = std.time.nanoTimestamp();
                            t_row_glyph_start = t_row_under_deco_end;
                        }

                        // 3) Glyphs: same as main path, but only this row
                        const ensure_base = ctx.core.cb.on_atlas_ensure_glyph;
                        const ensure_styled = ctx.core.cb.on_atlas_ensure_glyph_styled;
                        const shape_text_run = ctx.core.cb.on_shape_text_run;
                        const has_shaping = shape_text_run != null and ctx.core.isPhase2Atlas() and ctx.core.cb.on_rasterize_glyph_by_id != null;
                        if (has_shaping or ensure_base != null or ensure_styled != null or ctx.core.isPhase2Atlas()) {
                            // Pre-allocate vertex capacity for entire row's glyphs
                            // (worst case: 1 glyph per column × 6 vertices per quad)
                            try out.ensureUnusedCapacity(ctx.core.alloc, cols * 6);
                            var c: u32 = 0;
                            while (c < cols) {
                                const run_fg = row_cells.fg_rgbs.items[@intCast(c)];
                                const run_bg = row_cells.bg_rgbs.items[@intCast(c)];
                                const run_grid_id = row_cells.grid_ids.items[@intCast(c)];
                                const run_start = c;

                                const end: u32 = @intCast(@min(
                                    simdFindRunEndU32(row_cells.fg_rgbs.items, @intCast(c), @intCast(cols), run_fg),
                                    @min(
                                        simdFindRunEndU32(row_cells.bg_rgbs.items, @intCast(c), @intCast(cols), run_bg),
                                        simdFindRunEndI64(row_cells.grid_ids.items, @intCast(c), @intCast(cols), run_grid_id),
                                    ),
                                ));
                                const has_ink = simdHasInkInRange(row_cells.scalars.items, @intCast(c), @intCast(end));

                                if (has_ink) {
                                    const baseX = @as(f32, @floatFromInt(run_start)) * cellW;
                                    const baseY = @as(f32, @floatFromInt(r)) * cellH + topPad;
                                    const fg = Helpers.rgb(run_fg);
                                    const glyph_scroll_flag: u32 = Helpers.computeScrollFlag(r, run_grid_id, main_scrollable, cached_subgrids[0..cached_subgrid_count]);

                                    if (has_shaping) {
                                        // --- Text-run shaping path (Phase B: ligatures) ---
                                        // 1) Collect scalars for this HL run
                                        const run_len = end - run_start;
                                        // Determine style flags from first cell in run (uniform within HL run)
                                        const first_style = row_cells.style_flags_arr.items[@intCast(run_start)];
                                        const c_style: u32 = @as(u32, if (first_style & STYLE_BOLD != 0) c_api.STYLE_BOLD else 0) |
                                            @as(u32, if (first_style & STYLE_ITALIC != 0) c_api.STYLE_ITALIC else 0);
                                        const style_index: u32 = @as(u32, if (first_style & STYLE_BOLD != 0) @as(u32, 1) else 0) +
                                            @as(u32, if (first_style & STYLE_ITALIC != 0) @as(u32, 2) else 0);

                                        // Collect scalars (skip wide char continuations) and track column widths
                                        ctx.core.shaping_scalars.clearRetainingCapacity();
                                        ctx.core.shaping_col_widths.clearRetainingCapacity();
                                        ctx.core.shaping_scalars.ensureTotalCapacity(ctx.core.alloc, run_len) catch {
                                            c = end;
                                            continue;
                                        };
                                        ctx.core.shaping_col_widths.ensureTotalCapacity(ctx.core.alloc, run_len) catch {
                                            c = end;
                                            continue;
                                        };
                                        // SIMD fast path: if no wide chars (no zero scalars), bulk copy
                                        if (simdAllNonZero(row_cells.scalars.items, @intCast(run_start), @intCast(end))) {
                                            @memcpy(ctx.core.shaping_scalars.items.ptr[0..run_len], row_cells.scalars.items[@intCast(run_start)..@intCast(end)]);
                                            ctx.core.shaping_scalars.items.len = run_len;
                                            @memset(ctx.core.shaping_col_widths.items.ptr[0..run_len], 1);
                                            ctx.core.shaping_col_widths.items.len = run_len;
                                        } else {
                                            var si: u32 = run_start;
                                            while (si < end) : (si += 1) {
                                                const s = row_cells.scalars.items[@intCast(si)];
                                                if (s == 0) {
                                                    continue;
                                                }
                                                ctx.core.shaping_scalars.appendAssumeCapacity(s);
                                                const col_w: u32 = if (si + 1 < end and row_cells.scalars.items[@intCast(si + 1)] == 0) 2 else 1;
                                                ctx.core.shaping_col_widths.appendAssumeCapacity(col_w);
                                            }
                                        }

                                        const scalar_count = ctx.core.shaping_scalars.items.len;
                                        if (scalar_count == 0) {
                                            c = end;
                                            continue;
                                        }

                                        // 2) ASCII fast path: skip HarfBuzz for runs with only
                                        //    printable ASCII characters. Single-char runs always
                                        //    use fast path (ligatures need ≥2 chars, calt needs
                                        //    context). Multi-char runs skip triggers.
                                        //    Note: uses per-codepoint advances (no GPOS pair kerning),
                                        //    which is correct for monospace terminal fonts.
                                        const bufs = &ctx.core.shaping_bufs;
                                        var final_glyph_count: usize = 0;
                                        var used_ascii_fast_path = false;

                                        if (ctx.core.loadAsciiTables()) {
                                            const is_ascii_safe = ascii_chk: {
                                                const scalars = ctx.core.shaping_scalars.items[0..scalar_count];
                                                // SIMD range check: all in [0x20, 0x7E]
                                                if (!simdAllAsciiPrintable(scalars, scalar_count)) break :ascii_chk false;
                                                // Single-char runs: always safe (no context for calt/liga)
                                                if (scalar_count == 1) break :ascii_chk true;
                                                // Multi-char: check ligature triggers
                                                const trigs = &ctx.core.ascii_lig_triggers[style_index];
                                                for (scalars) |s| {
                                                    if (trigs[@intCast(s)] != 0) break :ascii_chk false;
                                                }
                                                break :ascii_chk true;
                                            };
                                            if (is_ascii_safe) {
                                                bufs.ensureCapacity(ctx.core.alloc, scalar_count) catch {
                                                    c = end;
                                                    continue;
                                                };
                                                bufs.setLen(scalar_count);
                                                const gids = &ctx.core.ascii_glyph_ids[style_index];
                                                const xadvs = &ctx.core.ascii_x_advances[style_index];
                                                // Batch zero-fill x_off and y_off (compiles to SIMD memset)
                                                @memset(bufs.x_off.items[0..scalar_count], 0);
                                                @memset(bufs.y_off.items[0..scalar_count], 0);
                                                // Sequential cluster fill (SIMD 4-wide)
                                                simdFillSequential(bufs.clusters.items.ptr, scalar_count);
                                                // Table lookups (gather - must be scalar)
                                                for (0..scalar_count) |i| {
                                                    const s: usize = @intCast(ctx.core.shaping_scalars.items[i]);
                                                    bufs.glyph_ids.items[i] = gids[s];
                                                    bufs.x_adv.items[i] = xadvs[s];
                                                }
                                                final_glyph_count = scalar_count;
                                                used_ascii_fast_path = true;
                                                perf_ascii_fast_path += 1;
                                            }
                                        }

                                        if (!used_ascii_fast_path) {
                                        // Shape cache lookup / callback
                                        const sc_hash1 = nvim_core.shapeCacheHash(ctx.core.shaping_scalars.items[0..scalar_count], c_style);
                                        const sc_hash2 = nvim_core.shapeCacheHash2(ctx.core.shaping_scalars.items[0..scalar_count], c_style);
                                        const sc_set_base = (sc_hash1 & (@as(u64, ctx.core.shape_cache_sets) - 1)) * nvim_core.SHAPE_CACHE_WAYS;
                                        const sc_font_gen = ctx.core.font_generation;

                                        var sc_cache_hit = false;

                                        // Check both ways of the set
                                        if (ctx.core.shape_cache) |sc_cache| {
                                            for (0..nvim_core.SHAPE_CACHE_WAYS) |sc_way| {
                                                const sc_entry = &sc_cache[sc_set_base + sc_way];
                                                if (sc_entry.key_hash == sc_hash1 and
                                                    sc_entry.key_hash2 == sc_hash2 and
                                                    sc_entry.font_gen == sc_font_gen and
                                                    sc_entry.scalar_count == @as(u32, @intCast(scalar_count)) and
                                                    sc_entry.glyph_count > 0 and
                                                    sc_entry.glyph_count <= nvim_core.SHAPE_CACHE_MAX_GLYPHS)
                                                {
                                                    // Cache hit
                                                    final_glyph_count = sc_entry.glyph_count;
                                                    bufs.ensureCapacity(ctx.core.alloc, final_glyph_count) catch {
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
                                                    perf_shape_cache_hits += 1;
                                                    break;
                                                }
                                            }
                                        }

                                        if (!sc_cache_hit) {
                                            // Cache miss: call shape callback
                                            perf_shape_cache_misses += 1;
                                            bufs.ensureCapacity(ctx.core.alloc, scalar_count) catch {
                                                c = end;
                                                continue;
                                            };
                                            bufs.setLen(scalar_count);

                                            const glyph_count = shape_text_run.?(
                                                ctx.core.ctx,
                                                ctx.core.shaping_scalars.items.ptr,
                                                scalar_count,
                                                c_style,
                                                bufs.glyph_ids.items.ptr,
                                                bufs.clusters.items.ptr,
                                                bufs.x_adv.items.ptr,
                                                bufs.x_off.items.ptr,
                                                bufs.y_off.items.ptr,
                                                scalar_count,
                                            );

                                            if (glyph_count == 0) {
                                                c = end;
                                                continue;
                                            }

                                            final_glyph_count = glyph_count;
                                            if (glyph_count > scalar_count) {
                                                bufs.ensureCapacity(ctx.core.alloc, glyph_count) catch {
                                                    c = end;
                                                    continue;
                                                };
                                                bufs.setLen(glyph_count);
                                                final_glyph_count = shape_text_run.?(
                                                    ctx.core.ctx,
                                                    ctx.core.shaping_scalars.items.ptr,
                                                    scalar_count,
                                                    c_style,
                                                    bufs.glyph_ids.items.ptr,
                                                    bufs.clusters.items.ptr,
                                                    bufs.x_adv.items.ptr,
                                                    bufs.x_off.items.ptr,
                                                    bufs.y_off.items.ptr,
                                                    glyph_count,
                                                );
                                                if (final_glyph_count == 0) {
                                                    c = end;
                                                    continue;
                                                }
                                            }

                                            // Store in cache if result fits
                                            if (final_glyph_count <= nvim_core.SHAPE_CACHE_MAX_GLYPHS) {
                                                if (ctx.core.shape_cache) |sc_cache| {
                                                    // Prefer empty slot, else overwrite way 0
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

                                        // 3) Iterate shaped glyphs
                                        // Ensure capacity for this run's glyphs. The per-row cols*6
                                        // pre-allocation covers typical cases, but shaping expansion
                                        // (glyph_count > scalar_count) or .notdef fallback can exceed it.
                                        // Worst case: non-.notdef → 1 quad/glyph (final_glyph_count),
                                        // .notdef → 1 quad/scalar in cluster (up to scalar_count total).
                                        out.ensureUnusedCapacity(ctx.core.alloc, (final_glyph_count + scalar_count) * 6) catch {
                                            c = end;
                                            continue;
                                        };
                                        var penX: f32 = baseX;
                                        const glyph_cache_id = ctx.core.glyph_cache_by_id;
                                        const glyph_keys_id = ctx.core.glyph_keys_by_id;

                                        var gi: usize = 0;
                                        while (gi < final_glyph_count) : (gi += 1) {
                                            const gid = bufs.glyph_ids.items[gi];
                                            // Cluster-based pen advance using column widths
                                            const this_cluster = bufs.clusters.items[gi];
                                            const next_cluster = if (gi + 1 < final_glyph_count) bufs.clusters.items[gi + 1] else @as(u32, @intCast(scalar_count));

                                            if (gid == 0) {
                                                // .notdef glyph — fall back to per-scalar path (has CoreText font fallback)
                                                var ci: u32 = this_cluster;
                                                while (ci < next_cluster) : (ci += 1) {
                                                    const fb_scalar = ctx.core.shaping_scalars.items[@intCast(ci)];
                                                    const fb_col_w = ctx.core.shaping_col_widths.items[@intCast(ci)];
                                                    if (fb_scalar == 32) {
                                                        penX += @as(f32, @floatFromInt(fb_col_w)) * cellW;
                                                        continue;
                                                    }
                                                    // Block element: geometric rendering (no atlas)
                                                    if (block_elements.isBlockElement(fb_scalar)) {
                                                        const blk_w = @as(f32, @floatFromInt(fb_col_w)) * cellW;
                                                        const blk_geo = block_elements.getBlockGeometry(fb_scalar);
                                                        if (blk_geo.count > 0) {
                                                            const blk_y0 = @as(f32, @floatFromInt(r)) * cellH;
                                                            out.ensureUnusedCapacity(ctx.core.alloc, @as(usize, blk_geo.count) * 6) catch {
                                                                penX += blk_w;
                                                                continue;
                                                            };
                                                            for (blk_geo.rects[0..blk_geo.count]) |rect| {
                                                                Helpers.pushSolidQuadAssumeCapacity(out, penX + rect.x0 * blk_w, blk_y0 + rect.y0 * cellH, penX + rect.x1 * blk_w, blk_y0 + rect.y1 * cellH, fg, dw, dh, run_grid_id, glyph_scroll_flag);
                                                            }
                                                        }
                                                        penX += blk_w;
                                                        continue;
                                                    }
                                                    if (ctx.core.ensureGlyphPhase2(fb_scalar, c_style)) |fb_ge| {
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

                                                            Helpers.pushGlyphQuadAssumeCapacity(out, fb_gx0, fb_gy0, fb_gx1, fb_gy1, fb_uv0, fb_uv1, fb_uv2, fb_uv3, fg, dw, dh, run_grid_id, glyph_scroll_flag);
                                                        }
                                                    }
                                                    penX += @as(f32, @floatFromInt(fb_col_w)) * cellW;
                                                }
                                                continue;
                                            }

                                            // Skip space glyphs: no bitmap, just advance pen
                                            if (next_cluster == this_cluster + 1) {
                                                const sp_scalar = ctx.core.shaping_scalars.items[@intCast(this_cluster)];
                                                if (sp_scalar == 0x20) {
                                                    penX += @as(f32, @floatFromInt(ctx.core.shaping_col_widths.items[@intCast(this_cluster)])) * cellW;
                                                    continue;
                                                }
                                                // Block element: geometric rendering (no atlas)
                                                if (block_elements.isBlockElement(sp_scalar)) {
                                                    const blk_cols = ctx.core.shaping_col_widths.items[@intCast(this_cluster)];
                                                    const blk_w = @as(f32, @floatFromInt(blk_cols)) * cellW;
                                                    const blk_geo = block_elements.getBlockGeometry(sp_scalar);
                                                    if (blk_geo.count > 0) {
                                                        const blk_y0 = @as(f32, @floatFromInt(r)) * cellH;
                                                        out.ensureUnusedCapacity(ctx.core.alloc, @as(usize, blk_geo.count) * 6) catch {
                                                            penX += blk_w;
                                                            continue;
                                                        };
                                                        for (blk_geo.rects[0..blk_geo.count]) |rect| {
                                                            Helpers.pushSolidQuadAssumeCapacity(out, penX + rect.x0 * blk_w, blk_y0 + rect.y0 * cellH, penX + rect.x1 * blk_w, blk_y0 + rect.y1 * cellH, fg, dw, dh, run_grid_id, glyph_scroll_flag);
                                                        }
                                                    }
                                                    penX += blk_w;
                                                    continue;
                                                }
                                            }

                                            // Glyph-ID cache lookup
                                            var ge: c_api.GlyphEntry = undefined;
                                            const glyph_ok = gid_blk: {
                                                if (glyph_cache_id != null and glyph_keys_id != null and GLYPH_CACHE_NON_ASCII_SIZE > 0) {
                                                    const key = (@as(u64, gid) << 2) | @as(u64, style_index);
                                                    const hash_val = (gid *% 2654435761) ^ style_index;
                                                    const hash_idx = @as(usize, hash_val % GLYPH_CACHE_NON_ASCII_SIZE);
                                                    if (glyph_keys_id.?[hash_idx] == key) {
                                                        ge = glyph_cache_id.?[hash_idx];
                                                        break :gid_blk true;
                                                    }
                                                    // Cache miss: rasterize by glyph ID
                                                    if (ctx.core.ensureGlyphByID(gid, c_style)) |entry| {
                                                        ge = entry;
                                                        glyph_cache_id.?[hash_idx] = entry;
                                                        glyph_keys_id.?[hash_idx] = key;
                                                        break :gid_blk true;
                                                    }
                                                    break :gid_blk false;
                                                }
                                                // No cache: rasterize directly
                                                if (ctx.core.ensureGlyphByID(gid, c_style)) |entry| {
                                                    ge = entry;
                                                    break :gid_blk true;
                                                }
                                                break :gid_blk false;
                                            };

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

                                                Helpers.pushGlyphQuadAssumeCapacity(out, gx0, gy0, gx1, gy1, uv0, uv1, uv2, uv3, fg, dw, dh, run_grid_id, glyph_scroll_flag);
                                            }

                                            // Advance pen using column widths (correct for wide chars)
                                            {
                                                const cl_span = next_cluster - this_cluster;
                                                const cluster_cols: u32 = if (cl_span == 1)
                                                    ctx.core.shaping_col_widths.items[@intCast(this_cluster)]
                                                else blk: {
                                                    var sum: u32 = 0;
                                                    var cwi: u32 = this_cluster;
                                                    while (cwi < next_cluster) : (cwi += 1) {
                                                        sum += ctx.core.shaping_col_widths.items[@intCast(cwi)];
                                                    }
                                                    break :blk sum;
                                                };
                                                penX += @as(f32, @floatFromInt(cluster_cols)) * cellW;
                                            }
                                        }
                                    } else {
                                        // --- Existing per-cell glyph path (fallback) ---
                                        var penX: f32 = baseX;

                                    var col_i: u32 = run_start;
                                    while (col_i < end) : (col_i += 1) {
                                        const cell_scalar = row_cells.scalars.items[@intCast(col_i)];
                                        const cell_style_flags = row_cells.style_flags_arr.items[@intCast(col_i)];
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
                                                out.ensureUnusedCapacity(ctx.core.alloc, @as(usize, blk_geo.count) * 6) catch {
                                                    penX += cellW;
                                                    continue;
                                                };
                                                for (blk_geo.rects[0..blk_geo.count]) |rect| {
                                                    Helpers.pushSolidQuadAssumeCapacity(out, penX + rect.x0 * cellW, blk_y0 + rect.y0 * cellH, penX + rect.x1 * cellW, blk_y0 + rect.y1 * cellH, Helpers.rgb(run_fg), dw, dh, run_grid_id, glyph_scroll_flag);
                                                }
                                            }
                                            penX += cellW;
                                            continue;
                                        }

                                        var ge: c_api.GlyphEntry = undefined;
                                        // Use styled callback for bold/italic if available
                                        const style_mask = cell_style_flags & (STYLE_BOLD | STYLE_ITALIC);
                                        // Compute style index: 0=none, 1=bold, 2=italic, 3=bold+italic
                                        const style_index: u32 = @as(u32, if (cell_style_flags & STYLE_BOLD != 0) @as(u32, 1) else 0) +
                                            @as(u32, if (cell_style_flags & STYLE_ITALIC != 0) @as(u32, 2) else 0);
                                        // GlyphEntry cache lookup for ASCII characters (using dynamic cache)
                                        const glyph_ok = blk: {
                                            // Check dynamic cache for ASCII (0-127)
                                            if (scalar < 128 and glyph_cache_ascii != null and glyph_valid_ascii != null) {
                                                const cache_key: usize = scalar * 4 + style_index;
                                                if (cache_key < GLYPH_CACHE_ASCII_SIZE) {
                                                    if (glyph_valid_ascii.?[cache_key]) {
                                                        perf_glyph_ascii_hits += 1;
                                                        ge = glyph_cache_ascii.?[cache_key];
                                                        break :blk true;
                                                    }
                                                    // Cache miss: call callback
                                                    perf_glyph_ascii_misses += 1;
                                                    const ok = if (ctx.core.isPhase2Atlas()) cb: {
                                                        const c_style: u32 = @as(u32, if (cell_style_flags & STYLE_BOLD != 0) c_api.STYLE_BOLD else 0) |
                                                            @as(u32, if (cell_style_flags & STYLE_ITALIC != 0) c_api.STYLE_ITALIC else 0);
                                                        if (ctx.core.ensureGlyphPhase2(scalar, c_style)) |entry| {
                                                            ge = entry;
                                                            break :cb true;
                                                        }
                                                        break :cb false;
                                                    } else if (style_mask != 0 and ensure_styled != null) cb: {
                                                        const c_style: u32 = @as(u32, if (cell_style_flags & STYLE_BOLD != 0) c_api.STYLE_BOLD else 0) |
                                                            @as(u32, if (cell_style_flags & STYLE_ITALIC != 0) c_api.STYLE_ITALIC else 0);
                                                        break :cb ensure_styled.?(ctx.core.ctx, scalar, c_style, &ge) != 0;
                                                    } else if (ensure_base) |ensure| cb: {
                                                        break :cb ensure(ctx.core.ctx, scalar, &ge) != 0;
                                                    } else false;
                                                    if (ok) {
                                                        glyph_cache_ascii.?[cache_key] = ge;
                                                        glyph_valid_ascii.?[cache_key] = true;
                                                    }
                                                    break :blk ok;
                                                }
                                            }
                                            // Non-ASCII or cache not initialized: use hash table cache
                                            if (glyph_cache_non_ascii != null and glyph_keys_non_ascii != null and GLYPH_CACHE_NON_ASCII_SIZE > 0) {
                                                const key = (@as(u64, scalar) << 2) | @as(u64, style_index);
                                                // FNV-1a inspired hash
                                                const hash_val = (scalar *% 2654435761) ^ style_index;
                                                const hash_idx = @as(usize, hash_val % GLYPH_CACHE_NON_ASCII_SIZE);
                                                if (glyph_keys_non_ascii.?[hash_idx] == key) {
                                                    perf_glyph_nonascii_hits += 1;
                                                    ge = glyph_cache_non_ascii.?[hash_idx];
                                                    break :blk true;
                                                }
                                                // Cache miss: call callback
                                                perf_glyph_nonascii_misses += 1;
                                                const ok = if (ctx.core.isPhase2Atlas()) cb: {
                                                    const c_style: u32 = @as(u32, if (cell_style_flags & STYLE_BOLD != 0) c_api.STYLE_BOLD else 0) |
                                                        @as(u32, if (cell_style_flags & STYLE_ITALIC != 0) c_api.STYLE_ITALIC else 0);
                                                    if (ctx.core.ensureGlyphPhase2(scalar, c_style)) |entry| {
                                                        ge = entry;
                                                        break :cb true;
                                                    }
                                                    break :cb false;
                                                } else if (style_mask != 0 and ensure_styled != null) cb: {
                                                    const c_style: u32 = @as(u32, if (cell_style_flags & STYLE_BOLD != 0) c_api.STYLE_BOLD else 0) |
                                                        @as(u32, if (cell_style_flags & STYLE_ITALIC != 0) c_api.STYLE_ITALIC else 0);
                                                    break :cb ensure_styled.?(ctx.core.ctx, scalar, c_style, &ge) != 0;
                                                } else if (ensure_base) |ensure| cb: {
                                                    break :cb ensure(ctx.core.ctx, scalar, &ge) != 0;
                                                } else false;
                                                if (ok) {
                                                    glyph_cache_non_ascii.?[hash_idx] = ge;
                                                    glyph_keys_non_ascii.?[hash_idx] = key;
                                                }
                                                break :blk ok;
                                            }
                                            // No cache available: call callback directly
                                            const ok = if (ctx.core.isPhase2Atlas()) cb: {
                                                const c_style: u32 = @as(u32, if (cell_style_flags & STYLE_BOLD != 0) c_api.STYLE_BOLD else 0) |
                                                    @as(u32, if (cell_style_flags & STYLE_ITALIC != 0) c_api.STYLE_ITALIC else 0);
                                                if (ctx.core.ensureGlyphPhase2(scalar, c_style)) |entry| {
                                                    ge = entry;
                                                    break :cb true;
                                                }
                                                break :cb false;
                                            } else if (style_mask != 0 and ensure_styled != null) cb: {
                                                const c_style: u32 = @as(u32, if (cell_style_flags & STYLE_BOLD != 0) c_api.STYLE_BOLD else 0) |
                                                    @as(u32, if (cell_style_flags & STYLE_ITALIC != 0) c_api.STYLE_ITALIC else 0);
                                                break :cb ensure_styled.?(ctx.core.ctx, scalar, c_style, &ge) != 0;
                                            } else if (ensure_base) |ensure| cb: {
                                                break :cb ensure(ctx.core.ctx, scalar, &ge) != 0;
                                            } else false;
                                            break :blk ok;
                                        };
                                        if (!glyph_ok) {
                                            had_glyph_miss = true;
                                            if (ctx.core.missing_glyph_log_count < 16) {
                                                ctx.core.log.write(
                                                    "glyph_missing row={d} col={d} scalar=0x{x}\n",
                                                    .{ r, col_i, scalar },
                                                );
                                                ctx.core.missing_glyph_log_count += 1;
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
                                            Helpers.pushGlyphQuadAssumeCapacity(out, gx0, gy0, gx1, gy1, uv0, uv1, uv2, uv3, fg, dw, dh, run_grid_id, glyph_scroll_flag);
                                        }

                                        penX += cellW;
                                    }
                                    } // end else (per-cell fallback)
                                }

                                c = end;
                            }
                        }

                        var t_row_glyph_end: i128 = 0;
                        var t_row_strike_start: i128 = 0;
                        if (log_enabled) {
                            t_row_glyph_end = std.time.nanoTimestamp();
                            t_row_strike_start = t_row_glyph_end;
                        }

                        // 4) Strikethrough (drawn on top of glyphs)
                        {
                            var c: u32 = 0;
                            while (c < cols) {
                                const c_style_flags = row_cells.style_flags_arr.items[@intCast(c)];
                                if (c_style_flags & STYLE_STRIKETHROUGH == 0) {
                                    c += 1;
                                    continue;
                                }

                                const run_start = c;
                                const run_flags = c_style_flags;
                                const run_sp = row_cells.sp_rgbs.items[@intCast(c)];
                                const run_fg = row_cells.fg_rgbs.items[@intCast(c)];
                                const run_grid_id = row_cells.grid_ids.items[@intCast(c)];

                                const run_end: u32 = @intCast(@min(
                                    simdFindRunEndU8(row_cells.style_flags_arr.items, @intCast(c + 1), @intCast(cols), run_flags),
                                    @min(
                                        simdFindRunEndU32(row_cells.sp_rgbs.items, @intCast(c + 1), @intCast(cols), run_sp),
                                        simdFindRunEndI64(row_cells.grid_ids.items, @intCast(c + 1), @intCast(cols), run_grid_id),
                                    ),
                                ));

                                const deco_color = if (run_sp != highlight.Highlights.SP_NOT_SET) Helpers.rgb(run_sp) else Helpers.rgb(run_fg);
                                const strike_scroll_flag: u32 = Helpers.computeScrollFlag(r, run_grid_id, main_scrollable, cached_subgrids[0..cached_subgrid_count]);
                                const x0: f32 = @as(f32, @floatFromInt(run_start)) * cellW;
                                const x1: f32 = @as(f32, @floatFromInt(run_end)) * cellW;
                                const row_y: f32 = @as(f32, @floatFromInt(r)) * cellH;

                                const y0 = row_y + cellH * 0.5 - 0.5;
                                const y1 = y0 + 1.0;
                                try Helpers.pushDecoQuad(out, ctx.core.alloc, x0, y0, x1, y1, deco_color, dw, dh, run_grid_id, c_api.DECO_STRIKETHROUGH | strike_scroll_flag, 0);

                                c = run_end;
                            }
                        }

                        // Log row timing for performance measurement
                        if (log_enabled) {
                            const t_row_strike_end = std.time.nanoTimestamp();
                            const compose_us: i64 = @intCast(@divTrunc(@max(0, t_row_compose_end - t_row_compose_start), 1000));
                            const bg_us: i64 = @intCast(@divTrunc(@max(0, t_row_bg_end - t_row_bg_start), 1000));
                            const under_deco_us: i64 = @intCast(@divTrunc(@max(0, t_row_under_deco_end - t_row_under_deco_start), 1000));
                            const glyph_us: i64 = @intCast(@divTrunc(@max(0, t_row_glyph_end - t_row_glyph_start), 1000));
                            const strike_us: i64 = @intCast(@divTrunc(@max(0, t_row_strike_end - t_row_strike_start), 1000));
                            const total_us: i64 = @intCast(@divTrunc(@max(0, t_row_strike_end - t_row_compose_start), 1000));
                            ctx.core.log.write(
                                "[perf] row_mode row={d} cols={d} compose_us={d} bg_us={d} under_deco_us={d} glyph_us={d} strike_us={d} total_us={d}\n",
                                .{ r, cols, compose_us, bg_us, under_deco_us, glyph_us, strike_us, total_us },
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
                            // Already retried: abort remaining rows.
                            // saw_atlas_reset=true ensures markAllDirty at end → next flush fixes.
                            if (log_enabled) {
                                ctx.core.log.write(
                                    "[scroll_debug] atlas_reset_during_flush at row={d} on retry: aborting\n",
                                    .{r},
                                );
                            }
                            break;
                        }

                        // Contract: row_count == 1, grid_id == 1 for main window
                        row_cb(ctx.core.ctx, 1, r, 1, out.items.ptr, out.items.len, 1, rows, cols); // grid_id=1 (main), flags=1 (ZONVIE_VERT_UPDATE_MAIN)
                    }
                    break; // Normal exit from retry_loop
                    }

                    ctx.core.grid.clearDirty();
                    if (had_glyph_miss or saw_atlas_reset) {
                        ctx.core.grid.markAllDirty();
                        // Also mark external grids dirty (atlas reset invalidates their UVs too)
                        if (saw_atlas_reset) {
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
                            "[perf] row_mode_compose rows={d} cols={d} dirty_rows={d} subgrids={d} us={d}\n",
                            .{ rows, cols, log_dirty_rows, ctx.core.grid_entries.items.len, dur_us },
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

                    // 1) draw main grid(1) with RLE batching + hl_cache
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

                                var i: u32 = c2;
                                while (i < run_end) : (i += 1) {
                                    const ti = pos.col + i;
                                    if (ti >= cols) break;

                                    const src_cell = sg.cells[sg_row_start + @as(usize, i)];
                                    tmp.set(dst_row_start + @as(usize, ti), src_cell.cp, fg, bg, sp, subgrid_id, flags);
                                }

                                c2 = run_end;
                            }
                        }
                    }
                }



                if (!sent_main_by_rows) {

                    // Estimate capacity: rows*cols*12 vertices (BG + glyph)
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

                                const end: u32 = @intCast(@min(
                                    simdFindRunEndU32(tmp.fg_rgbs.items[row_start..], @intCast(c), @intCast(cols), run_fg),
                                    @min(
                                        simdFindRunEndU32(tmp.bg_rgbs.items[row_start..], @intCast(c), @intCast(cols), run_bg),
                                        simdFindRunEndI64(tmp.grid_ids.items[row_start..], @intCast(c), @intCast(cols), run_grid_id),
                                    ),
                                ));
                                const has_ink = simdHasInkInRange(tmp.scalars.items[row_start..], @intCast(c), @intCast(end));

                                if (has_ink) {
                                    const baseX = @as(f32, @floatFromInt(run_start)) * cellW;
                                    const baseY = @as(f32, @floatFromInt(r)) * cellH + topPad;

                                    var penX: f32 = baseX;
                                    const fg = Helpers.rgb(run_fg);

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
                                            try Helpers.pushGlyphQuad(main, ctx.core.alloc, gx0, gy0, gx1, gy1, uv0, uv1, uv2, uv3, fg, dw, dh, run_grid_id, nr_glyph_scroll);
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

                // Skip cursor generation if cursor is NOT on main grid and NOT embedded in main grid
                // Embedded grids (win_pos) have their cursor drawn on main grid via coordinate transform
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
                                    // Calculate glyph position (same as main grid rendering)
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
                                        c_api.DECO_SCROLLABLE, // cursor is always in content area
                                    );
                                }
                            }
                            } // end else (non-block-element cursor glyph)
                        }
                    }
                }

                // Mark cursor as sent
                ctx.core.last_sent_cursor_rev = ctx.core.grid.cursor_rev;
            }

            // If atlas was reset during vertex generation, mark grid dirty
            // for re-render next flush (current frame may have stale UVs
            // for vertices generated before the reset).
            if (ctx.core.atlas_reset_during_flush) {
                ctx.core.grid.markAllDirty();
                ctx.core.atlas_reset_during_flush = false;
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
                return;
            }

            // If main was sent via row callback, do not call legacy full callback.
            if (sent_main_by_rows) return;

            // Legacy path: must always provide BOTH buffers to avoid frontend clearing main on cursor-only updates.
            if (vf_opt) |vf| {
                vf(
                    ctx.core.ctx,
                    main.items.ptr, main.items.len,
                    cursor.items.ptr, cursor.items.len,
                );
                return;
            }

            // No callback (shouldn't happen because we gated above), but keep safe:
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

        // Mark ALL grids dirty so row-mode vertex generation re-renders
        // every row with the new font/atlas. Without this, the main grid
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
        cursor_grid != 1; // cursor_grid != main grid
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

    // Get glyph cache references
    const glyph_cache_ascii = self.glyph_cache_ascii;
    const glyph_valid_ascii = self.glyph_valid_ascii;
    const glyph_cache_non_ascii = self.glyph_cache_non_ascii;
    const glyph_keys_non_ascii = self.glyph_keys_non_ascii;
    const GLYPH_CACHE_ASCII_SIZE = self.glyph_cache_ascii_size;
    const GLYPH_CACHE_NON_ASCII_SIZE = self.glyph_cache_non_ascii_size;

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

        // Check if we need full redraw or can use dirty_rows
        const need_full_redraw = force_render or force_redraw_this or cursor_affected or cursor_moved_within;

        // NDC viewport: use target dimensions which are kept in sync with grid_resize.
        // This ensures NDC always matches the actual grid data dimensions.
        const target = self.grid.external_grid_target_sizes.get(grid_id);
        const viewport_cols = if (target) |t| t.cols else sg.cols;
        const viewport_rows = if (target) |t| t.rows else sg.rows;
        const grid_w: f32 = @as(f32, @floatFromInt(viewport_cols)) * cellW;
        const grid_h: f32 = @as(f32, @floatFromInt(viewport_rows)) * cellH;

        // Debug: count non-space cells
        var non_space_count: u32 = 0;
        var glyph_success_count: u32 = 0;
        var glyph_fail_count: u32 = 0;
        var sample_cps: [10]u32 = .{0} ** 10;
        var sample_idx: usize = 0;

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

        const solid_uv: [2]f32 = .{ -1.0, -1.0 };

        // Create composite cell array - copy external grid cells and overlay float windows
        // This approach ensures float windows completely overwrite (not blend with) the underlying cells
        const composite_cells = self.alloc.alloc(grid_mod.Cell, n_cells) catch {
            self.log.write("[ext_grid] WARN: failed to allocate composite cells for {d} cells\n", .{n_cells});
            continue;
        };
        defer self.alloc.free(composite_cells);

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

        ext_retry: while (true) {
            if (ext_retried) {
                // Reset per-pass state for clean retry
                non_space_count = 0;
                glyph_success_count = 0;
                glyph_fail_count = 0;
                sample_idx = 0;
                cache.reset(); // Resets perf counters + hl_valid (hl_valid reset is harmless)
            }
            const ext_effective_rebuild = ext_retried;

        for (0..sg.rows) |row_idx| {
            const row: u32 = @intCast(row_idx);

            // Compute scrollable flag for this row in the external grid
            const ext_scrollable: u32 = if (row >= ext_margins.top and row < sg.rows -| ext_margins.bottom) c_api.DECO_SCROLLABLE else 0;

            // Skip clean rows unless full redraw needed or cursor is on this row
            const is_cursor_row = if (cursor_row) |cr| cr == row else false;
            if (!need_full_redraw and !ext_effective_rebuild and !is_cursor_row) {
                // Check dirty_rows bitmap (also respect dirty flag which is set on resize/clear)
                // When dirty=true (after resize), all rows should be redrawn
                if (!sg.dirty and sg.dirty_rows.bit_length > row and !sg.dirty_rows.isSet(@as(usize, row))) {
                    continue; // Row is clean, skip it
                }
            }

            const row_y: f32 = @as(f32, @floatFromInt(row)) * cellH;

            // Clear buffer for this row
            ext_verts.clearRetainingCapacity();

            // Estimate capacity for this row: 6 bg + 6 glyph + 6 deco per cell + 12 cursor
            const row_est = @as(usize, sg.cols) * 18 + 12;
            ext_verts.ensureTotalCapacity(self.alloc, row_est) catch continue;

            // Compose RenderCells for this row (resolve hl -> fg/bg/sp/style_flags)
            self.row_cells.clearRetainingCapacity();
            self.row_cells.ensureTotalCapacity(self.alloc, sg.cols) catch continue;
            self.row_cells.setLen(sg.cols);

            const row_start: usize = @as(usize, row) * @as(usize, sg.cols);
            for (0..sg.cols) |c| {
                const cell_idx = row_start + c;
                if (cell_idx >= n_cells) {
                    self.row_cells.set(c, ' ', default_bg, default_bg, highlight.Highlights.SP_NOT_SET, grid_id, 0);
                    continue;
                }
                const cell = composite_cells[cell_idx];
                const attr = cache.getAttr(&self.hl, cell.hl);
                self.row_cells.set(c, cell.cp, attr.fg, attr.bg, attr.sp, grid_id, packStyleFlags(attr));
            }

            // Pass 1: Background (run-length optimized)
            {
                var c: u32 = 0;
                while (c < sg.cols) {
                    const run_bg = self.row_cells.bg_rgbs.items[c];
                    const run_start = c;

                    const end: u32 = @intCast(simdFindRunEndU32(self.row_cells.bg_rgbs.items, @intCast(c), @intCast(sg.cols), run_bg));

                    const x0: f32 = @as(f32, @floatFromInt(run_start)) * cellW;
                    const x1: f32 = @as(f32, @floatFromInt(end)) * cellW;
                    const y0: f32 = row_y;
                    const y1: f32 = row_y + cellH;

                    const bg_alpha: f32 = if (run_bg == default_bg)
                        (if (self.blur_enabled) (if (is_cmdline) 0.0 else 0.5) else self.background_opacity)
                    else
                        1.0;
                    const bg_col = Helpers.rgba(run_bg, bg_alpha);

                    const bg_pts = Helpers.ndc4(x0, y0, x1, y1, grid_w, grid_h);
                    const tl = bg_pts[0]; const tr = bg_pts[1]; const bl = bg_pts[2]; const br = bg_pts[3];

                    ext_verts.appendAssumeCapacity(.{ .position = tl, .texCoord = solid_uv, .color = bg_col, .grid_id = grid_id, .deco_flags = ext_scrollable, .deco_phase = 0 });
                    ext_verts.appendAssumeCapacity(.{ .position = tr, .texCoord = solid_uv, .color = bg_col, .grid_id = grid_id, .deco_flags = ext_scrollable, .deco_phase = 0 });
                    ext_verts.appendAssumeCapacity(.{ .position = bl, .texCoord = solid_uv, .color = bg_col, .grid_id = grid_id, .deco_flags = ext_scrollable, .deco_phase = 0 });
                    ext_verts.appendAssumeCapacity(.{ .position = tr, .texCoord = solid_uv, .color = bg_col, .grid_id = grid_id, .deco_flags = ext_scrollable, .deco_phase = 0 });
                    ext_verts.appendAssumeCapacity(.{ .position = br, .texCoord = solid_uv, .color = bg_col, .grid_id = grid_id, .deco_flags = ext_scrollable, .deco_phase = 0 });
                    ext_verts.appendAssumeCapacity(.{ .position = bl, .texCoord = solid_uv, .color = bg_col, .grid_id = grid_id, .deco_flags = ext_scrollable, .deco_phase = 0 });

                    c = end;
                }
            }

            // Pass 2: Under-decorations (underline, undercurl, etc.)
            {
                const under_deco_mask: u8 = STYLE_UNDERLINE | STYLE_UNDERDOUBLE | STYLE_UNDERCURL | STYLE_UNDERDOTTED | STYLE_UNDERDASHED;
                var c: u32 = 0;
                while (c < sg.cols) {
                    const ext_cell_sf = self.row_cells.style_flags_arr.items[c];
                    if (ext_cell_sf & under_deco_mask == 0) {
                        c += 1;
                        continue;
                    }

                    const run_start = c;
                    const run_flags = ext_cell_sf;
                    const run_sp = self.row_cells.sp_rgbs.items[c];
                    const run_fg = self.row_cells.fg_rgbs.items[c];

                    const run_end: u32 = @intCast(@min(
                        simdFindRunEndU8(self.row_cells.style_flags_arr.items, @intCast(c + 1), @intCast(sg.cols), run_flags),
                        simdFindRunEndU32(self.row_cells.sp_rgbs.items, @intCast(c + 1), @intCast(sg.cols), run_sp),
                    ));

                    const deco_color = if (run_sp != highlight.Highlights.SP_NOT_SET) Helpers.rgb(run_sp) else Helpers.rgb(run_fg);
                    const x0: f32 = @as(f32, @floatFromInt(run_start)) * cellW;
                    const x1: f32 = @as(f32, @floatFromInt(run_end)) * cellW;

                    // Underline
                    if (run_flags & STYLE_UNDERLINE != 0) {
                        const uy0 = row_y + cellH - 2.0;
                        const uy1 = uy0 + 1.0;
                        const ul_pts = Helpers.ndc4(x0, uy0, x1, uy1, grid_w, grid_h);
                        const utl = ul_pts[0]; const utr = ul_pts[1]; const ubl = ul_pts[2]; const ubr = ul_pts[3];
                        ext_verts.appendAssumeCapacity(.{ .position = utl, .texCoord = solid_uv, .color = deco_color, .grid_id = grid_id, .deco_flags = c_api.DECO_UNDERLINE | ext_scrollable, .deco_phase = 0 });
                        ext_verts.appendAssumeCapacity(.{ .position = utr, .texCoord = solid_uv, .color = deco_color, .grid_id = grid_id, .deco_flags = c_api.DECO_UNDERLINE | ext_scrollable, .deco_phase = 0 });
                        ext_verts.appendAssumeCapacity(.{ .position = ubl, .texCoord = solid_uv, .color = deco_color, .grid_id = grid_id, .deco_flags = c_api.DECO_UNDERLINE | ext_scrollable, .deco_phase = 0 });
                        ext_verts.appendAssumeCapacity(.{ .position = utr, .texCoord = solid_uv, .color = deco_color, .grid_id = grid_id, .deco_flags = c_api.DECO_UNDERLINE | ext_scrollable, .deco_phase = 0 });
                        ext_verts.appendAssumeCapacity(.{ .position = ubr, .texCoord = solid_uv, .color = deco_color, .grid_id = grid_id, .deco_flags = c_api.DECO_UNDERLINE | ext_scrollable, .deco_phase = 0 });
                        ext_verts.appendAssumeCapacity(.{ .position = ubl, .texCoord = solid_uv, .color = deco_color, .grid_id = grid_id, .deco_flags = c_api.DECO_UNDERLINE | ext_scrollable, .deco_phase = 0 });
                    }

                    // Underdouble
                    if (run_flags & STYLE_UNDERDOUBLE != 0) {
                        const uy0_1 = row_y + cellH - 6.0;
                        const uy1_1 = uy0_1 + 1.0;
                        const uy0_2 = row_y + cellH - 2.0;
                        const uy1_2 = uy0_2 + 1.0;
                        // First line
                        const ud1_pts = Helpers.ndc4(x0, uy0_1, x1, uy1_1, grid_w, grid_h);
                        var utl = ud1_pts[0]; var utr = ud1_pts[1]; var ubl = ud1_pts[2]; var ubr = ud1_pts[3];
                        ext_verts.appendAssumeCapacity(.{ .position = utl, .texCoord = solid_uv, .color = deco_color, .grid_id = grid_id, .deco_flags = c_api.DECO_UNDERLINE | ext_scrollable, .deco_phase = 0 });
                        ext_verts.appendAssumeCapacity(.{ .position = utr, .texCoord = solid_uv, .color = deco_color, .grid_id = grid_id, .deco_flags = c_api.DECO_UNDERLINE | ext_scrollable, .deco_phase = 0 });
                        ext_verts.appendAssumeCapacity(.{ .position = ubl, .texCoord = solid_uv, .color = deco_color, .grid_id = grid_id, .deco_flags = c_api.DECO_UNDERLINE | ext_scrollable, .deco_phase = 0 });
                        ext_verts.appendAssumeCapacity(.{ .position = utr, .texCoord = solid_uv, .color = deco_color, .grid_id = grid_id, .deco_flags = c_api.DECO_UNDERLINE | ext_scrollable, .deco_phase = 0 });
                        ext_verts.appendAssumeCapacity(.{ .position = ubr, .texCoord = solid_uv, .color = deco_color, .grid_id = grid_id, .deco_flags = c_api.DECO_UNDERLINE | ext_scrollable, .deco_phase = 0 });
                        ext_verts.appendAssumeCapacity(.{ .position = ubl, .texCoord = solid_uv, .color = deco_color, .grid_id = grid_id, .deco_flags = c_api.DECO_UNDERLINE | ext_scrollable, .deco_phase = 0 });
                        // Second line
                        const ud2_pts = Helpers.ndc4(x0, uy0_2, x1, uy1_2, grid_w, grid_h);
                        utl = ud2_pts[0]; utr = ud2_pts[1]; ubl = ud2_pts[2]; ubr = ud2_pts[3];
                        ext_verts.appendAssumeCapacity(.{ .position = utl, .texCoord = solid_uv, .color = deco_color, .grid_id = grid_id, .deco_flags = c_api.DECO_UNDERLINE | ext_scrollable, .deco_phase = 0 });
                        ext_verts.appendAssumeCapacity(.{ .position = utr, .texCoord = solid_uv, .color = deco_color, .grid_id = grid_id, .deco_flags = c_api.DECO_UNDERLINE | ext_scrollable, .deco_phase = 0 });
                        ext_verts.appendAssumeCapacity(.{ .position = ubl, .texCoord = solid_uv, .color = deco_color, .grid_id = grid_id, .deco_flags = c_api.DECO_UNDERLINE | ext_scrollable, .deco_phase = 0 });
                        ext_verts.appendAssumeCapacity(.{ .position = utr, .texCoord = solid_uv, .color = deco_color, .grid_id = grid_id, .deco_flags = c_api.DECO_UNDERLINE | ext_scrollable, .deco_phase = 0 });
                        ext_verts.appendAssumeCapacity(.{ .position = ubr, .texCoord = solid_uv, .color = deco_color, .grid_id = grid_id, .deco_flags = c_api.DECO_UNDERLINE | ext_scrollable, .deco_phase = 0 });
                        ext_verts.appendAssumeCapacity(.{ .position = ubl, .texCoord = solid_uv, .color = deco_color, .grid_id = grid_id, .deco_flags = c_api.DECO_UNDERLINE | ext_scrollable, .deco_phase = 0 });
                    }

                    // Undercurl
                    if (run_flags & STYLE_UNDERCURL != 0) {
                        const uy0 = row_y + cellH - 4.0;
                        const uy1 = row_y + cellH;
                        const phase: f32 = @floatFromInt(run_start);
                        const uc_pts = Helpers.ndc4(x0, uy0, x1, uy1, grid_w, grid_h);
                        const utl = uc_pts[0]; const utr = uc_pts[1]; const ubl = uc_pts[2]; const ubr = uc_pts[3];
                        ext_verts.appendAssumeCapacity(.{ .position = utl, .texCoord = solid_uv, .color = deco_color, .grid_id = grid_id, .deco_flags = c_api.DECO_UNDERCURL | ext_scrollable, .deco_phase = phase });
                        ext_verts.appendAssumeCapacity(.{ .position = utr, .texCoord = solid_uv, .color = deco_color, .grid_id = grid_id, .deco_flags = c_api.DECO_UNDERCURL | ext_scrollable, .deco_phase = phase });
                        ext_verts.appendAssumeCapacity(.{ .position = ubl, .texCoord = solid_uv, .color = deco_color, .grid_id = grid_id, .deco_flags = c_api.DECO_UNDERCURL | ext_scrollable, .deco_phase = phase });
                        ext_verts.appendAssumeCapacity(.{ .position = utr, .texCoord = solid_uv, .color = deco_color, .grid_id = grid_id, .deco_flags = c_api.DECO_UNDERCURL | ext_scrollable, .deco_phase = phase });
                        ext_verts.appendAssumeCapacity(.{ .position = ubr, .texCoord = solid_uv, .color = deco_color, .grid_id = grid_id, .deco_flags = c_api.DECO_UNDERCURL | ext_scrollable, .deco_phase = phase });
                        ext_verts.appendAssumeCapacity(.{ .position = ubl, .texCoord = solid_uv, .color = deco_color, .grid_id = grid_id, .deco_flags = c_api.DECO_UNDERCURL | ext_scrollable, .deco_phase = phase });
                    }

                    // Underdotted
                    if (run_flags & STYLE_UNDERDOTTED != 0) {
                        const uy0 = row_y + cellH - 2.0;
                        const uy1 = uy0 + 1.0;
                        const udt_pts = Helpers.ndc4(x0, uy0, x1, uy1, grid_w, grid_h);
                        const utl = udt_pts[0]; const utr = udt_pts[1]; const ubl = udt_pts[2]; const ubr = udt_pts[3];
                        ext_verts.appendAssumeCapacity(.{ .position = utl, .texCoord = solid_uv, .color = deco_color, .grid_id = grid_id, .deco_flags = c_api.DECO_UNDERDOTTED | ext_scrollable, .deco_phase = 0 });
                        ext_verts.appendAssumeCapacity(.{ .position = utr, .texCoord = solid_uv, .color = deco_color, .grid_id = grid_id, .deco_flags = c_api.DECO_UNDERDOTTED | ext_scrollable, .deco_phase = 0 });
                        ext_verts.appendAssumeCapacity(.{ .position = ubl, .texCoord = solid_uv, .color = deco_color, .grid_id = grid_id, .deco_flags = c_api.DECO_UNDERDOTTED | ext_scrollable, .deco_phase = 0 });
                        ext_verts.appendAssumeCapacity(.{ .position = utr, .texCoord = solid_uv, .color = deco_color, .grid_id = grid_id, .deco_flags = c_api.DECO_UNDERDOTTED | ext_scrollable, .deco_phase = 0 });
                        ext_verts.appendAssumeCapacity(.{ .position = ubr, .texCoord = solid_uv, .color = deco_color, .grid_id = grid_id, .deco_flags = c_api.DECO_UNDERDOTTED | ext_scrollable, .deco_phase = 0 });
                        ext_verts.appendAssumeCapacity(.{ .position = ubl, .texCoord = solid_uv, .color = deco_color, .grid_id = grid_id, .deco_flags = c_api.DECO_UNDERDOTTED | ext_scrollable, .deco_phase = 0 });
                    }

                    // Underdashed
                    if (run_flags & STYLE_UNDERDASHED != 0) {
                        const uy0 = row_y + cellH - 2.0;
                        const uy1 = uy0 + 1.0;
                        const uda_pts = Helpers.ndc4(x0, uy0, x1, uy1, grid_w, grid_h);
                        const utl = uda_pts[0]; const utr = uda_pts[1]; const ubl = uda_pts[2]; const ubr = uda_pts[3];
                        ext_verts.appendAssumeCapacity(.{ .position = utl, .texCoord = solid_uv, .color = deco_color, .grid_id = grid_id, .deco_flags = c_api.DECO_UNDERDASHED | ext_scrollable, .deco_phase = 0 });
                        ext_verts.appendAssumeCapacity(.{ .position = utr, .texCoord = solid_uv, .color = deco_color, .grid_id = grid_id, .deco_flags = c_api.DECO_UNDERDASHED | ext_scrollable, .deco_phase = 0 });
                        ext_verts.appendAssumeCapacity(.{ .position = ubl, .texCoord = solid_uv, .color = deco_color, .grid_id = grid_id, .deco_flags = c_api.DECO_UNDERDASHED | ext_scrollable, .deco_phase = 0 });
                        ext_verts.appendAssumeCapacity(.{ .position = utr, .texCoord = solid_uv, .color = deco_color, .grid_id = grid_id, .deco_flags = c_api.DECO_UNDERDASHED | ext_scrollable, .deco_phase = 0 });
                        ext_verts.appendAssumeCapacity(.{ .position = ubr, .texCoord = solid_uv, .color = deco_color, .grid_id = grid_id, .deco_flags = c_api.DECO_UNDERDASHED | ext_scrollable, .deco_phase = 0 });
                        ext_verts.appendAssumeCapacity(.{ .position = ubl, .texCoord = solid_uv, .color = deco_color, .grid_id = grid_id, .deco_flags = c_api.DECO_UNDERDASHED | ext_scrollable, .deco_phase = 0 });
                    }

                    c = run_end;
                }
            }

            // Pass 3: Glyphs (with glyph_cache)
            const ensure_base = self.cb.on_atlas_ensure_glyph;
            const ensure_styled = self.cb.on_atlas_ensure_glyph_styled;
            const ext_shape_text_run = self.cb.on_shape_text_run;
            const ext_has_shaping = ext_shape_text_run != null and self.isPhase2Atlas() and self.cb.on_rasterize_glyph_by_id != null;

            if (ext_has_shaping) {
                // --- Text-run shaping path for external grids ---
                // Process by HL runs (same fg + style) to enable ligature shaping
                var ec: u32 = 0;
                while (ec < sg.cols) {
                    const run_fg_ext = self.row_cells.fg_rgbs.items[ec];
                    const run_sf_ext = self.row_cells.style_flags_arr.items[ec];
                    const run_start_ext = ec;

                    // Find end of HL run (same fg + style flags)
                    var run_end_ext = ec + 1;
                    while (run_end_ext < sg.cols) : (run_end_ext += 1) {
                        if (self.row_cells.fg_rgbs.items[run_end_ext] != run_fg_ext or
                            self.row_cells.style_flags_arr.items[run_end_ext] != run_sf_ext) break;
                    }

                    // Check if run has any ink
                    var has_ink_ext = false;
                    for (run_start_ext..run_end_ext) |ci| {
                        const sc = self.row_cells.scalars.items[ci];
                        if (sc != 0 and sc != 32 and sc != ' ') {
                            has_ink_ext = true;
                            break;
                        }
                    }

                    if (has_ink_ext) {
                        const c_style_ext: u32 = @as(u32, if (run_sf_ext & STYLE_BOLD != 0) c_api.STYLE_BOLD else 0) |
                            @as(u32, if (run_sf_ext & STYLE_ITALIC != 0) c_api.STYLE_ITALIC else 0);
                        const style_index_ext: u32 = @as(u32, if (run_sf_ext & STYLE_BOLD != 0) @as(u32, 1) else 0) +
                            @as(u32, if (run_sf_ext & STYLE_ITALIC != 0) @as(u32, 2) else 0);

                        // Collect scalars and track column widths
                        self.shaping_scalars.clearRetainingCapacity();
                        self.shaping_col_widths.clearRetainingCapacity();
                        const run_len_ext = run_end_ext - run_start_ext;
                        self.shaping_scalars.ensureTotalCapacity(self.alloc, run_len_ext) catch {
                            ec = run_end_ext;
                            continue;
                        };
                        self.shaping_col_widths.ensureTotalCapacity(self.alloc, run_len_ext) catch {
                            ec = run_end_ext;
                            continue;
                        };
                        // SIMD fast path: if no wide chars (no zero scalars), bulk copy
                        if (simdAllNonZero(self.row_cells.scalars.items, run_start_ext, run_end_ext)) {
                            @memcpy(self.shaping_scalars.items.ptr[0..run_len_ext], self.row_cells.scalars.items[run_start_ext..run_end_ext]);
                            self.shaping_scalars.items.len = run_len_ext;
                            @memset(self.shaping_col_widths.items.ptr[0..run_len_ext], 1);
                            self.shaping_col_widths.items.len = run_len_ext;
                        } else {
                            for (run_start_ext..run_end_ext) |ci| {
                                const sc = self.row_cells.scalars.items[ci];
                                if (sc == 0) continue;
                                self.shaping_scalars.appendAssumeCapacity(sc);
                                const ext_col_w: u32 = if (ci + 1 < run_end_ext and self.row_cells.scalars.items[ci + 1] == 0) 2 else 1;
                                self.shaping_col_widths.appendAssumeCapacity(ext_col_w);
                            }
                        }

                        const ext_scalar_count = self.shaping_scalars.items.len;
                        if (ext_scalar_count == 0) {
                            ec = run_end_ext;
                            continue;
                        }

                        // ASCII fast path for external grids
                        // Single-char runs always safe; multi-char skips triggers.
                        const ext_bufs = &self.shaping_bufs;
                        var final_ext_glyph_count: usize = 0;
                        var used_ext_ascii_fast_path = false;

                        if (self.loadAsciiTables()) {
                            const ext_ascii_ok = ext_ascii_chk: {
                                const ext_scalars = self.shaping_scalars.items[0..ext_scalar_count];
                                // SIMD range check: all in [0x20, 0x7E]
                                if (!simdAllAsciiPrintable(ext_scalars, ext_scalar_count)) break :ext_ascii_chk false;
                                if (ext_scalar_count == 1) break :ext_ascii_chk true;
                                const ext_trigs = &self.ascii_lig_triggers[style_index_ext];
                                for (ext_scalars) |s| {
                                    if (ext_trigs[@intCast(s)] != 0) break :ext_ascii_chk false;
                                }
                                break :ext_ascii_chk true;
                            };
                            if (ext_ascii_ok) {
                                ext_bufs.ensureCapacity(self.alloc, ext_scalar_count) catch {
                                    ec = run_end_ext;
                                    continue;
                                };
                                ext_bufs.setLen(ext_scalar_count);
                                const ext_gids = &self.ascii_glyph_ids[style_index_ext];
                                const ext_xadvs = &self.ascii_x_advances[style_index_ext];
                                // Batch zero-fill x_off and y_off (compiles to SIMD memset)
                                @memset(ext_bufs.x_off.items[0..ext_scalar_count], 0);
                                @memset(ext_bufs.y_off.items[0..ext_scalar_count], 0);
                                // Sequential cluster fill (SIMD 4-wide)
                                simdFillSequential(ext_bufs.clusters.items.ptr, ext_scalar_count);
                                // Table lookups (gather - must be scalar)
                                for (0..ext_scalar_count) |i| {
                                    const s: usize = @intCast(self.shaping_scalars.items[i]);
                                    ext_bufs.glyph_ids.items[i] = ext_gids[s];
                                    ext_bufs.x_adv.items[i] = ext_xadvs[s];
                                }
                                final_ext_glyph_count = ext_scalar_count;
                                used_ext_ascii_fast_path = true;
                            }
                        }

                        if (!used_ext_ascii_fast_path) {
                        // Shape cache lookup / callback
                        const ext_sc_hash1 = nvim_core.shapeCacheHash(self.shaping_scalars.items[0..ext_scalar_count], c_style_ext);
                        const ext_sc_hash2 = nvim_core.shapeCacheHash2(self.shaping_scalars.items[0..ext_scalar_count], c_style_ext);
                        const ext_sc_set_base = (ext_sc_hash1 & (@as(u64, self.shape_cache_sets) - 1)) * nvim_core.SHAPE_CACHE_WAYS;
                        const ext_sc_font_gen = self.font_generation;

                        var ext_sc_cache_hit = false;

                        // Check both ways of the set
                        if (self.shape_cache) |ext_sc_cache| {
                            for (0..nvim_core.SHAPE_CACHE_WAYS) |ext_sc_way| {
                                const ext_sc_entry = &ext_sc_cache[ext_sc_set_base + ext_sc_way];
                                if (ext_sc_entry.key_hash == ext_sc_hash1 and
                                    ext_sc_entry.key_hash2 == ext_sc_hash2 and
                                    ext_sc_entry.font_gen == ext_sc_font_gen and
                                    ext_sc_entry.scalar_count == @as(u32, @intCast(ext_scalar_count)) and
                                    ext_sc_entry.glyph_count > 0 and
                                    ext_sc_entry.glyph_count <= nvim_core.SHAPE_CACHE_MAX_GLYPHS)
                                {
                                    final_ext_glyph_count = ext_sc_entry.glyph_count;
                                    ext_bufs.ensureCapacity(self.alloc, final_ext_glyph_count) catch {
                                        ec = run_end_ext;
                                        continue;
                                    };
                                    ext_bufs.setLen(final_ext_glyph_count);
                                    @memcpy(ext_bufs.glyph_ids.items[0..final_ext_glyph_count], ext_sc_entry.glyph_ids[0..final_ext_glyph_count]);
                                    @memcpy(ext_bufs.clusters.items[0..final_ext_glyph_count], ext_sc_entry.clusters[0..final_ext_glyph_count]);
                                    @memcpy(ext_bufs.x_adv.items[0..final_ext_glyph_count], ext_sc_entry.x_adv[0..final_ext_glyph_count]);
                                    @memcpy(ext_bufs.x_off.items[0..final_ext_glyph_count], ext_sc_entry.x_off[0..final_ext_glyph_count]);
                                    @memcpy(ext_bufs.y_off.items[0..final_ext_glyph_count], ext_sc_entry.y_off[0..final_ext_glyph_count]);
                                    ext_sc_cache_hit = true;
                                    break;
                                }
                            }
                        }

                        if (!ext_sc_cache_hit) {
                            ext_bufs.ensureCapacity(self.alloc, ext_scalar_count) catch {
                                ec = run_end_ext;
                                continue;
                            };
                            ext_bufs.setLen(ext_scalar_count);

                            const ext_glyph_count = ext_shape_text_run.?(
                                self.ctx,
                                self.shaping_scalars.items.ptr,
                                ext_scalar_count,
                                c_style_ext,
                                ext_bufs.glyph_ids.items.ptr,
                                ext_bufs.clusters.items.ptr,
                                ext_bufs.x_adv.items.ptr,
                                ext_bufs.x_off.items.ptr,
                                ext_bufs.y_off.items.ptr,
                                ext_scalar_count,
                            );

                            if (ext_glyph_count == 0) {
                                ec = run_end_ext;
                                continue;
                            }

                            final_ext_glyph_count = ext_glyph_count;
                            if (ext_glyph_count > ext_scalar_count) {
                                ext_bufs.ensureCapacity(self.alloc, ext_glyph_count) catch {
                                    ec = run_end_ext;
                                    continue;
                                };
                                ext_bufs.setLen(ext_glyph_count);
                                final_ext_glyph_count = ext_shape_text_run.?(
                                    self.ctx,
                                    self.shaping_scalars.items.ptr,
                                    ext_scalar_count,
                                    c_style_ext,
                                    ext_bufs.glyph_ids.items.ptr,
                                    ext_bufs.clusters.items.ptr,
                                    ext_bufs.x_adv.items.ptr,
                                    ext_bufs.x_off.items.ptr,
                                    ext_bufs.y_off.items.ptr,
                                    ext_glyph_count,
                                );
                                if (final_ext_glyph_count == 0) {
                                    ec = run_end_ext;
                                    continue;
                                }
                            }

                            // Store in cache if result fits
                            if (final_ext_glyph_count <= nvim_core.SHAPE_CACHE_MAX_GLYPHS) {
                                if (self.shape_cache) |ext_sc_cache| {
                                    var ext_sc_store_way: usize = 0;
                                    for (0..nvim_core.SHAPE_CACHE_WAYS) |ext_sc_way| {
                                        if (ext_sc_cache[ext_sc_set_base + ext_sc_way].key_hash == 0) {
                                            ext_sc_store_way = ext_sc_way;
                                            break;
                                        }
                                    }
                                    const ext_sc_store = &ext_sc_cache[ext_sc_set_base + ext_sc_store_way];
                                    ext_sc_store.key_hash = ext_sc_hash1;
                                    ext_sc_store.key_hash2 = ext_sc_hash2;
                                    ext_sc_store.font_gen = ext_sc_font_gen;
                                    ext_sc_store.scalar_count = @intCast(ext_scalar_count);
                                    ext_sc_store.glyph_count = @intCast(final_ext_glyph_count);
                                    @memcpy(ext_sc_store.glyph_ids[0..final_ext_glyph_count], ext_bufs.glyph_ids.items[0..final_ext_glyph_count]);
                                    @memcpy(ext_sc_store.clusters[0..final_ext_glyph_count], ext_bufs.clusters.items[0..final_ext_glyph_count]);
                                    @memcpy(ext_sc_store.x_adv[0..final_ext_glyph_count], ext_bufs.x_adv.items[0..final_ext_glyph_count]);
                                    @memcpy(ext_sc_store.x_off[0..final_ext_glyph_count], ext_bufs.x_off.items[0..final_ext_glyph_count]);
                                    @memcpy(ext_sc_store.y_off[0..final_ext_glyph_count], ext_bufs.y_off.items[0..final_ext_glyph_count]);
                                }
                            }
                        }
                        } // end !used_ext_ascii_fast_path

                        if (final_ext_glyph_count > 0) {
                            // Ensure capacity: .notdef (gid==0) expands 1 glyph to
                            // up to cluster_span quads. Worst case total across all
                            // glyphs = final_ext_glyph_count + ext_scalar_count.
                            ext_verts.ensureUnusedCapacity(self.alloc, (final_ext_glyph_count + ext_scalar_count) * 6) catch {
                                ec = run_end_ext;
                                continue;
                            };
                            var ext_penX: f32 = @as(f32, @floatFromInt(run_start_ext)) * cellW;
                            const ext_fg_col = Helpers.rgb(run_fg_ext);
                            const ext_glyph_cache_id = self.glyph_cache_by_id;
                            const ext_glyph_keys_id = self.glyph_keys_by_id;

                            var egi: usize = 0;
                            while (egi < final_ext_glyph_count) : (egi += 1) {
                                const egid = ext_bufs.glyph_ids.items[egi];
                                const this_cl = ext_bufs.clusters.items[egi];
                                const next_cl = if (egi + 1 < final_ext_glyph_count) ext_bufs.clusters.items[egi + 1] else @as(u32, @intCast(ext_scalar_count));

                                if (egid == 0) {
                                    // .notdef glyph — fall back to per-scalar path (has CoreText font fallback)
                                    var eci: u32 = this_cl;
                                    while (eci < next_cl) : (eci += 1) {
                                        const efb_scalar = self.shaping_scalars.items[@intCast(eci)];
                                        const efb_col_w = self.shaping_col_widths.items[@intCast(eci)];
                                        if (efb_scalar == 32) {
                                            ext_penX += @as(f32, @floatFromInt(efb_col_w)) * cellW;
                                            continue;
                                        }
                                        // Block element: geometric rendering (no atlas)
                                        if (block_elements.isBlockElement(efb_scalar)) {
                                            const eblk_w = @as(f32, @floatFromInt(efb_col_w)) * cellW;
                                            const eblk_geo = block_elements.getBlockGeometry(efb_scalar);
                                            if (eblk_geo.count > 0) {
                                                ext_verts.ensureUnusedCapacity(self.alloc, @as(usize, eblk_geo.count) * 6) catch {
                                                    ext_penX += eblk_w;
                                                    continue;
                                                };
                                                for (eblk_geo.rects[0..eblk_geo.count]) |rect| {
                                                    Helpers.pushSolidQuadAssumeCapacity(ext_verts, ext_penX + rect.x0 * eblk_w, row_y + rect.y0 * cellH, ext_penX + rect.x1 * eblk_w, row_y + rect.y1 * cellH, ext_fg_col, grid_w, grid_h, grid_id, ext_scrollable);
                                                }
                                            }
                                            ext_penX += eblk_w;
                                            continue;
                                        }
                                        if (self.ensureGlyphPhase2(efb_scalar, c_style_ext)) |efb_ge| {
                                            if (efb_ge.bbox_size_px[0] > 0 and efb_ge.bbox_size_px[1] > 0) {
                                                glyph_success_count += 1;
                                                const efb_baseY = row_y + topPad;
                                                const efb_baselineY = efb_baseY + efb_ge.ascent_px;

                                                const efb_gx0 = ext_penX + efb_ge.bbox_origin_px[0];
                                                const efb_gx1 = efb_gx0 + efb_ge.bbox_size_px[0];
                                                const efb_gy0 = efb_baselineY - (efb_ge.bbox_origin_px[1] + efb_ge.bbox_size_px[1]);
                                                const efb_gy1 = efb_gy0 + efb_ge.bbox_size_px[1];

                                                const efb_pts = Helpers.ndc4(efb_gx0, efb_gy0, efb_gx1, efb_gy1, grid_w, grid_h);
                                                const efb_tl = efb_pts[0]; const efb_tr = efb_pts[1]; const efb_bl = efb_pts[2]; const efb_br = efb_pts[3];

                                                ext_verts.appendAssumeCapacity(.{ .position = efb_tl, .texCoord = .{ efb_ge.uv_min[0], efb_ge.uv_min[1] }, .color = ext_fg_col, .grid_id = grid_id, .deco_flags = ext_scrollable, .deco_phase = 0 });
                                                ext_verts.appendAssumeCapacity(.{ .position = efb_tr, .texCoord = .{ efb_ge.uv_max[0], efb_ge.uv_min[1] }, .color = ext_fg_col, .grid_id = grid_id, .deco_flags = ext_scrollable, .deco_phase = 0 });
                                                ext_verts.appendAssumeCapacity(.{ .position = efb_bl, .texCoord = .{ efb_ge.uv_min[0], efb_ge.uv_max[1] }, .color = ext_fg_col, .grid_id = grid_id, .deco_flags = ext_scrollable, .deco_phase = 0 });
                                                ext_verts.appendAssumeCapacity(.{ .position = efb_tr, .texCoord = .{ efb_ge.uv_max[0], efb_ge.uv_min[1] }, .color = ext_fg_col, .grid_id = grid_id, .deco_flags = ext_scrollable, .deco_phase = 0 });
                                                ext_verts.appendAssumeCapacity(.{ .position = efb_br, .texCoord = .{ efb_ge.uv_max[0], efb_ge.uv_max[1] }, .color = ext_fg_col, .grid_id = grid_id, .deco_flags = ext_scrollable, .deco_phase = 0 });
                                                ext_verts.appendAssumeCapacity(.{ .position = efb_bl, .texCoord = .{ efb_ge.uv_min[0], efb_ge.uv_max[1] }, .color = ext_fg_col, .grid_id = grid_id, .deco_flags = ext_scrollable, .deco_phase = 0 });
                                            }
                                        } else {
                                            glyph_fail_count += 1;
                                        }
                                        ext_penX += @as(f32, @floatFromInt(efb_col_w)) * cellW;
                                    }
                                    continue;
                                }

                                // Skip space glyphs: no bitmap, just advance pen
                                if (next_cl == this_cl + 1) {
                                    const esp_scalar = self.shaping_scalars.items[@intCast(this_cl)];
                                    if (esp_scalar == 0x20) {
                                        ext_penX += @as(f32, @floatFromInt(self.shaping_col_widths.items[@intCast(this_cl)])) * cellW;
                                        continue;
                                    }
                                    // Block element: geometric rendering (no atlas)
                                    if (block_elements.isBlockElement(esp_scalar)) {
                                        const eblk_cols = self.shaping_col_widths.items[@intCast(this_cl)];
                                        const eblk_w = @as(f32, @floatFromInt(eblk_cols)) * cellW;
                                        const eblk_geo = block_elements.getBlockGeometry(esp_scalar);
                                        if (eblk_geo.count > 0) {
                                            ext_verts.ensureUnusedCapacity(self.alloc, @as(usize, eblk_geo.count) * 6) catch {
                                                ext_penX += eblk_w;
                                                continue;
                                            };
                                            for (eblk_geo.rects[0..eblk_geo.count]) |rect| {
                                                Helpers.pushSolidQuadAssumeCapacity(ext_verts, ext_penX + rect.x0 * eblk_w, row_y + rect.y0 * cellH, ext_penX + rect.x1 * eblk_w, row_y + rect.y1 * cellH, ext_fg_col, grid_w, grid_h, grid_id, ext_scrollable);
                                            }
                                        }
                                        ext_penX += eblk_w;
                                        continue;
                                    }
                                }

                                // Glyph-ID cache lookup
                                var ext_ge: c_api.GlyphEntry = undefined;
                                const ext_glyph_ok = ext_gid_blk: {
                                    if (ext_glyph_cache_id != null and ext_glyph_keys_id != null and GLYPH_CACHE_NON_ASCII_SIZE > 0) {
                                        const ext_key = (@as(u64, egid) << 2) | @as(u64, style_index_ext);
                                        const ext_hash_val = (egid *% 2654435761) ^ style_index_ext;
                                        const ext_hash_idx = @as(usize, ext_hash_val % GLYPH_CACHE_NON_ASCII_SIZE);
                                        if (ext_glyph_keys_id.?[ext_hash_idx] == ext_key) {
                                            ext_ge = ext_glyph_cache_id.?[ext_hash_idx];
                                            break :ext_gid_blk true;
                                        }
                                        if (self.ensureGlyphByID(egid, c_style_ext)) |entry| {
                                            ext_ge = entry;
                                            ext_glyph_cache_id.?[ext_hash_idx] = entry;
                                            ext_glyph_keys_id.?[ext_hash_idx] = ext_key;
                                            break :ext_gid_blk true;
                                        }
                                        break :ext_gid_blk false;
                                    }
                                    if (self.ensureGlyphByID(egid, c_style_ext)) |entry| {
                                        ext_ge = entry;
                                        break :ext_gid_blk true;
                                    }
                                    break :ext_gid_blk false;
                                };

                                if (ext_glyph_ok and ext_ge.bbox_size_px[0] > 0 and ext_ge.bbox_size_px[1] > 0) {
                                    glyph_success_count += 1;
                                    const ext_x_off_px = vertexgen.fixed26_6ToPx(ext_bufs.x_off.items[egi]);
                                    const ext_y_off_px = vertexgen.fixed26_6ToPx(ext_bufs.y_off.items[egi]);
                                    const ext_baseY = row_y + topPad;
                                    const ext_baselineY = ext_baseY + ext_ge.ascent_px;

                                    const egx0 = ext_penX + ext_ge.bbox_origin_px[0] + ext_x_off_px;
                                    const egx1 = egx0 + ext_ge.bbox_size_px[0];
                                    const egy0 = (ext_baselineY + ext_y_off_px) - (ext_ge.bbox_origin_px[1] + ext_ge.bbox_size_px[1]);
                                    const egy1 = egy0 + ext_ge.bbox_size_px[1];

                                    const eg_pts = Helpers.ndc4(egx0, egy0, egx1, egy1, grid_w, grid_h);
                                    const egtl = eg_pts[0]; const egtr = eg_pts[1]; const egbl = eg_pts[2]; const egbr = eg_pts[3];

                                    ext_verts.appendAssumeCapacity(.{ .position = egtl, .texCoord = .{ ext_ge.uv_min[0], ext_ge.uv_min[1] }, .color = ext_fg_col, .grid_id = grid_id, .deco_flags = ext_scrollable, .deco_phase = 0 });
                                    ext_verts.appendAssumeCapacity(.{ .position = egtr, .texCoord = .{ ext_ge.uv_max[0], ext_ge.uv_min[1] }, .color = ext_fg_col, .grid_id = grid_id, .deco_flags = ext_scrollable, .deco_phase = 0 });
                                    ext_verts.appendAssumeCapacity(.{ .position = egbl, .texCoord = .{ ext_ge.uv_min[0], ext_ge.uv_max[1] }, .color = ext_fg_col, .grid_id = grid_id, .deco_flags = ext_scrollable, .deco_phase = 0 });
                                    ext_verts.appendAssumeCapacity(.{ .position = egtr, .texCoord = .{ ext_ge.uv_max[0], ext_ge.uv_min[1] }, .color = ext_fg_col, .grid_id = grid_id, .deco_flags = ext_scrollable, .deco_phase = 0 });
                                    ext_verts.appendAssumeCapacity(.{ .position = egbr, .texCoord = .{ ext_ge.uv_max[0], ext_ge.uv_max[1] }, .color = ext_fg_col, .grid_id = grid_id, .deco_flags = ext_scrollable, .deco_phase = 0 });
                                    ext_verts.appendAssumeCapacity(.{ .position = egbl, .texCoord = .{ ext_ge.uv_min[0], ext_ge.uv_max[1] }, .color = ext_fg_col, .grid_id = grid_id, .deco_flags = ext_scrollable, .deco_phase = 0 });
                                } else if (!ext_glyph_ok) {
                                    glyph_fail_count += 1;
                                }

                                // Advance pen using column widths (correct for wide chars)
                                {
                                    const ext_cl_span = next_cl - this_cl;
                                    const ext_cluster_cols: u32 = if (ext_cl_span == 1)
                                        self.shaping_col_widths.items[@intCast(this_cl)]
                                    else blk: {
                                        var sum: u32 = 0;
                                        var ecwi: u32 = this_cl;
                                        while (ecwi < next_cl) : (ecwi += 1) {
                                            sum += self.shaping_col_widths.items[@intCast(ecwi)];
                                        }
                                        break :blk sum;
                                    };
                                    ext_penX += @as(f32, @floatFromInt(ext_cluster_cols)) * cellW;
                                }
                            }
                        }
                    }

                    ec = run_end_ext;
                }
            } else {
            // --- Existing per-cell glyph path (fallback) ---
            for (0..sg.cols) |col_idx| {
                const col: u32 = @intCast(col_idx);
                const cell_sc = self.row_cells.scalars.items[col];
                const cell_sf = self.row_cells.style_flags_arr.items[col];
                const scalar: u32 = if (cell_sc == 0) 32 else cell_sc;

                if (scalar == ' ' or scalar == 32) continue;

                // Block element: geometric rendering (no atlas)
                if (block_elements.isBlockElement(scalar)) {
                    const eblk_x0: f32 = @as(f32, @floatFromInt(col)) * cellW;
                    const eblk_geo = block_elements.getBlockGeometry(scalar);
                    if (eblk_geo.count > 0) {
                        const eblk_col = Helpers.rgb(self.row_cells.fg_rgbs.items[col]);
                        ext_verts.ensureUnusedCapacity(self.alloc, @as(usize, eblk_geo.count) * 6) catch continue;
                        for (eblk_geo.rects[0..eblk_geo.count]) |rect| {
                            Helpers.pushSolidQuadAssumeCapacity(ext_verts, eblk_x0 + rect.x0 * cellW, row_y + rect.y0 * cellH, eblk_x0 + rect.x1 * cellW, row_y + rect.y1 * cellH, eblk_col, grid_w, grid_h, grid_id, ext_scrollable);
                        }
                    }
                    continue;
                }

                if (sample_idx < 10) {
                    sample_cps[sample_idx] = scalar;
                    sample_idx += 1;
                }
                non_space_count += 1;

                const x0: f32 = @as(f32, @floatFromInt(col)) * cellW;
                const style_mask: u32 = @as(u32, cell_sf & (STYLE_BOLD | STYLE_ITALIC));
                const style_index: u32 = @as(u32, if (cell_sf & STYLE_BOLD != 0) @as(u32, 1) else 0) +
                    @as(u32, if (cell_sf & STYLE_ITALIC != 0) @as(u32, 2) else 0);

                var ge: c_api.GlyphEntry = undefined;

                // Glyph cache lookup (same logic as row_mode)
                const glyph_ok = blk: {
                    // Check ASCII cache (scalar < 128)
                    if (scalar < 128 and glyph_cache_ascii != null and glyph_valid_ascii != null) {
                        const cache_key: usize = scalar * 4 + style_index;
                        if (cache_key < GLYPH_CACHE_ASCII_SIZE) {
                            if (glyph_valid_ascii.?[cache_key]) {
                                cache.perf_glyph_ascii_hits += 1;
                                ge = glyph_cache_ascii.?[cache_key];
                                break :blk true;
                            }
                            // Cache miss: call callback
                            cache.perf_glyph_ascii_misses += 1;
                            const ok = if (self.isPhase2Atlas()) cb: {
                                const c_style: u32 = @as(u32, if (cell_sf & STYLE_BOLD != 0) c_api.STYLE_BOLD else 0) |
                                    @as(u32, if (cell_sf & STYLE_ITALIC != 0) c_api.STYLE_ITALIC else 0);
                                if (self.ensureGlyphPhase2(scalar, c_style)) |entry| {
                                    ge = entry;
                                    break :cb true;
                                }
                                break :cb false;
                            } else if (style_mask != 0 and ensure_styled != null) cb: {
                                const c_style: u32 = @as(u32, if (cell_sf & STYLE_BOLD != 0) c_api.STYLE_BOLD else 0) |
                                    @as(u32, if (cell_sf & STYLE_ITALIC != 0) c_api.STYLE_ITALIC else 0);
                                break :cb ensure_styled.?(self.ctx, scalar, c_style, &ge) != 0;
                            } else if (ensure_base) |ensure| cb: {
                                break :cb ensure(self.ctx, scalar, &ge) != 0;
                            } else false;
                            if (ok) {
                                glyph_cache_ascii.?[cache_key] = ge;
                                glyph_valid_ascii.?[cache_key] = true;
                            }
                            break :blk ok;
                        }
                    }
                    // Non-ASCII: use hash table cache
                    if (glyph_cache_non_ascii != null and glyph_keys_non_ascii != null and GLYPH_CACHE_NON_ASCII_SIZE > 0) {
                        const key = (@as(u64, scalar) << 2) | @as(u64, style_index);
                        const hash_val = (scalar *% 2654435761) ^ style_index;
                        const hash_idx = @as(usize, hash_val % GLYPH_CACHE_NON_ASCII_SIZE);
                        if (glyph_keys_non_ascii.?[hash_idx] == key) {
                            cache.perf_glyph_nonascii_hits += 1;
                            ge = glyph_cache_non_ascii.?[hash_idx];
                            break :blk true;
                        }
                        // Cache miss: call callback
                        cache.perf_glyph_nonascii_misses += 1;
                        const ok = if (self.isPhase2Atlas()) cb: {
                            const c_style: u32 = @as(u32, if (cell_sf & STYLE_BOLD != 0) c_api.STYLE_BOLD else 0) |
                                @as(u32, if (cell_sf & STYLE_ITALIC != 0) c_api.STYLE_ITALIC else 0);
                            if (self.ensureGlyphPhase2(scalar, c_style)) |entry| {
                                ge = entry;
                                break :cb true;
                            }
                            break :cb false;
                        } else if (style_mask != 0 and ensure_styled != null) cb: {
                            const c_style: u32 = @as(u32, if (cell_sf & STYLE_BOLD != 0) c_api.STYLE_BOLD else 0) |
                                @as(u32, if (cell_sf & STYLE_ITALIC != 0) c_api.STYLE_ITALIC else 0);
                            break :cb ensure_styled.?(self.ctx, scalar, c_style, &ge) != 0;
                        } else if (ensure_base) |ensure| cb: {
                            break :cb ensure(self.ctx, scalar, &ge) != 0;
                        } else false;
                        if (ok) {
                            glyph_cache_non_ascii.?[hash_idx] = ge;
                            glyph_keys_non_ascii.?[hash_idx] = key;
                        }
                        break :blk ok;
                    }
                    // No cache: call callback directly
                    const ok = if (self.isPhase2Atlas()) cb: {
                        const c_style: u32 = @as(u32, if (cell_sf & STYLE_BOLD != 0) c_api.STYLE_BOLD else 0) |
                            @as(u32, if (cell_sf & STYLE_ITALIC != 0) c_api.STYLE_ITALIC else 0);
                        if (self.ensureGlyphPhase2(scalar, c_style)) |entry| {
                            ge = entry;
                            break :cb true;
                        }
                        break :cb false;
                    } else if (style_mask != 0 and ensure_styled != null) cb: {
                        const c_style: u32 = @as(u32, if (cell_sf & STYLE_BOLD != 0) c_api.STYLE_BOLD else 0) |
                            @as(u32, if (cell_sf & STYLE_ITALIC != 0) c_api.STYLE_ITALIC else 0);
                        break :cb ensure_styled.?(self.ctx, scalar, c_style, &ge) != 0;
                    } else if (ensure_base) |ensure| cb: {
                        break :cb ensure(self.ctx, scalar, &ge) != 0;
                    } else false;
                    break :blk ok;
                };

                if (glyph_ok) {
                    glyph_success_count += 1;
                    const glyph_col = Helpers.rgb(self.row_cells.fg_rgbs.items[col]);

                    const baseY = row_y + topPad;
                    const baselineY = baseY + ge.ascent_px;
                    const gx0 = x0 + ge.bbox_origin_px[0];
                    const gx1 = gx0 + ge.bbox_size_px[0];
                    const gy0 = baselineY - (ge.bbox_origin_px[1] + ge.bbox_size_px[1]);
                    const gy1 = gy0 + ge.bbox_size_px[1];

                    const g_pts = Helpers.ndc4(gx0, gy0, gx1, gy1, grid_w, grid_h);
                    const gtl = g_pts[0]; const gtr = g_pts[1]; const gbl = g_pts[2]; const gbr = g_pts[3];

                    const uv_x0 = ge.uv_min[0];
                    const uv_y0 = ge.uv_min[1];
                    const uv_x1 = ge.uv_max[0];
                    const uv_y1 = ge.uv_max[1];

                    ext_verts.appendAssumeCapacity(.{ .position = gtl, .texCoord = .{ uv_x0, uv_y0 }, .color = glyph_col, .grid_id = grid_id, .deco_flags = ext_scrollable, .deco_phase = 0 });
                    ext_verts.appendAssumeCapacity(.{ .position = gtr, .texCoord = .{ uv_x1, uv_y0 }, .color = glyph_col, .grid_id = grid_id, .deco_flags = ext_scrollable, .deco_phase = 0 });
                    ext_verts.appendAssumeCapacity(.{ .position = gbl, .texCoord = .{ uv_x0, uv_y1 }, .color = glyph_col, .grid_id = grid_id, .deco_flags = ext_scrollable, .deco_phase = 0 });
                    ext_verts.appendAssumeCapacity(.{ .position = gtr, .texCoord = .{ uv_x1, uv_y0 }, .color = glyph_col, .grid_id = grid_id, .deco_flags = ext_scrollable, .deco_phase = 0 });
                    ext_verts.appendAssumeCapacity(.{ .position = gbr, .texCoord = .{ uv_x1, uv_y1 }, .color = glyph_col, .grid_id = grid_id, .deco_flags = ext_scrollable, .deco_phase = 0 });
                    ext_verts.appendAssumeCapacity(.{ .position = gbl, .texCoord = .{ uv_x0, uv_y1 }, .color = glyph_col, .grid_id = grid_id, .deco_flags = ext_scrollable, .deco_phase = 0 });
                } else {
                    glyph_fail_count += 1;
                }
            }
            } // end else (per-cell fallback)

            // Pass 4: Strikethrough
            {
                var c: u32 = 0;
                while (c < sg.cols) {
                    const st_sf = self.row_cells.style_flags_arr.items[c];
                    if (st_sf & STYLE_STRIKETHROUGH == 0) {
                        c += 1;
                        continue;
                    }

                    const run_start = c;
                    const run_flags = st_sf;
                    const run_sp = self.row_cells.sp_rgbs.items[c];
                    const run_fg = self.row_cells.fg_rgbs.items[c];

                    const run_end: u32 = @intCast(@min(
                        simdFindRunEndU8(self.row_cells.style_flags_arr.items, @intCast(c + 1), @intCast(sg.cols), run_flags),
                        simdFindRunEndU32(self.row_cells.sp_rgbs.items, @intCast(c + 1), @intCast(sg.cols), run_sp),
                    ));

                    const deco_color = if (run_sp != highlight.Highlights.SP_NOT_SET) Helpers.rgb(run_sp) else Helpers.rgb(run_fg);
                    const x0: f32 = @as(f32, @floatFromInt(run_start)) * cellW;
                    const x1: f32 = @as(f32, @floatFromInt(run_end)) * cellW;
                    const sy0 = row_y + cellH * 0.5 - 0.5;
                    const sy1 = sy0 + 1.0;

                    const s_pts = Helpers.ndc4(x0, sy0, x1, sy1, grid_w, grid_h);
                    const stl = s_pts[0]; const str = s_pts[1]; const sbl = s_pts[2]; const sbr = s_pts[3];

                    ext_verts.appendAssumeCapacity(.{ .position = stl, .texCoord = solid_uv, .color = deco_color, .grid_id = grid_id, .deco_flags = c_api.DECO_STRIKETHROUGH | ext_scrollable, .deco_phase = 0 });
                    ext_verts.appendAssumeCapacity(.{ .position = str, .texCoord = solid_uv, .color = deco_color, .grid_id = grid_id, .deco_flags = c_api.DECO_STRIKETHROUGH | ext_scrollable, .deco_phase = 0 });
                    ext_verts.appendAssumeCapacity(.{ .position = sbl, .texCoord = solid_uv, .color = deco_color, .grid_id = grid_id, .deco_flags = c_api.DECO_STRIKETHROUGH | ext_scrollable, .deco_phase = 0 });
                    ext_verts.appendAssumeCapacity(.{ .position = str, .texCoord = solid_uv, .color = deco_color, .grid_id = grid_id, .deco_flags = c_api.DECO_STRIKETHROUGH | ext_scrollable, .deco_phase = 0 });
                    ext_verts.appendAssumeCapacity(.{ .position = sbr, .texCoord = solid_uv, .color = deco_color, .grid_id = grid_id, .deco_flags = c_api.DECO_STRIKETHROUGH | ext_scrollable, .deco_phase = 0 });
                    ext_verts.appendAssumeCapacity(.{ .position = sbl, .texCoord = solid_uv, .color = deco_color, .grid_id = grid_id, .deco_flags = c_api.DECO_STRIKETHROUGH | ext_scrollable, .deco_phase = 0 });

                    c = run_end;
                }
            }

            // Cursor rendering if cursor is on this row
            if (cursor_row) |cur_row| {
                if (cur_row == row and cursor_col < sg.cols) {
                    const cx0 = @as(f32, @floatFromInt(cursor_col)) * cellW;
                    const cy0 = row_y;

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

                    // Resolve cursor colors (same as main grid)
                    const cursor_bg: u32 = if (self.grid.cursor_attr_id != 0)
                        self.hl.get(self.grid.cursor_attr_id).bg
                    else
                        self.hl.default_fg; // attr_id == 0: swap default colors (per Nvim spec)
                    const cursor_color = Helpers.rgb(cursor_bg);

                    const c_pts = Helpers.ndc4(crx0, cry0, crx1, cry1, grid_w, grid_h);
                    const ctl = c_pts[0]; const ctr = c_pts[1]; const cbl = c_pts[2]; const cbr = c_pts[3];

                    ext_verts.appendAssumeCapacity(.{ .position = ctl, .texCoord = solid_uv, .color = cursor_color, .grid_id = grid_id, .deco_flags = c_api.DECO_CURSOR | c_api.DECO_SCROLLABLE, .deco_phase = 0 });
                    ext_verts.appendAssumeCapacity(.{ .position = ctr, .texCoord = solid_uv, .color = cursor_color, .grid_id = grid_id, .deco_flags = c_api.DECO_CURSOR | c_api.DECO_SCROLLABLE, .deco_phase = 0 });
                    ext_verts.appendAssumeCapacity(.{ .position = cbl, .texCoord = solid_uv, .color = cursor_color, .grid_id = grid_id, .deco_flags = c_api.DECO_CURSOR | c_api.DECO_SCROLLABLE, .deco_phase = 0 });
                    ext_verts.appendAssumeCapacity(.{ .position = ctr, .texCoord = solid_uv, .color = cursor_color, .grid_id = grid_id, .deco_flags = c_api.DECO_CURSOR | c_api.DECO_SCROLLABLE, .deco_phase = 0 });
                    ext_verts.appendAssumeCapacity(.{ .position = cbr, .texCoord = solid_uv, .color = cursor_color, .grid_id = grid_id, .deco_flags = c_api.DECO_CURSOR | c_api.DECO_SCROLLABLE, .deco_phase = 0 });
                    ext_verts.appendAssumeCapacity(.{ .position = cbl, .texCoord = solid_uv, .color = cursor_color, .grid_id = grid_id, .deco_flags = c_api.DECO_CURSOR | c_api.DECO_SCROLLABLE, .deco_phase = 0 });

                    // Cursor text for block cursor
                    if (self.grid.cursor_shape == .block) {
                        const cell_idx: usize = @as(usize, cur_row) * @as(usize, sg.cols) + @as(usize, cursor_col);
                        if (cell_idx < sg.cells.len) {
                            const cursor_cell = sg.cells[cell_idx];
                            if (cursor_cell.cp != 0 and cursor_cell.cp != ' ') {
                                // Block element under cursor: geometric rendering
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
                                                Helpers.pushSolidQuadAssumeCapacity(ext_verts, cx0 + rect.x0 * cursor_width, cy0 + rect.y0 * cellH, cx0 + rect.x1 * cursor_width, cy0 + rect.y1 * cellH, eblk_fg_col, grid_w, grid_h, grid_id, c_api.DECO_SCROLLABLE);
                                            }
                                        } else |_| {}
                                    }
                                } else {
                                var glyph_entry: c_api.GlyphEntry = undefined;
                                var glyph_ok: c_int = -1;

                                // Resolve style_flags for the cell under the cursor
                                const ext_cursor_resolved = self.hl.getWithStyles(cursor_cell.hl);
                                const ext_cursor_style = ext_cursor_resolved.style_flags & (STYLE_BOLD | STYLE_ITALIC);
                                const ext_cursor_c_style: u32 =
                                    @as(u32, if (ext_cursor_resolved.style_flags & STYLE_BOLD != 0) c_api.STYLE_BOLD else 0) |
                                    @as(u32, if (ext_cursor_resolved.style_flags & STYLE_ITALIC != 0) c_api.STYLE_ITALIC else 0);

                                // Matches main rendering path: Phase 2 → styled → base
                                if (self.isPhase2Atlas()) {
                                    if (self.ensureGlyphPhase2(cursor_cell.cp, ext_cursor_c_style)) |entry| {
                                        glyph_entry = entry;
                                        glyph_ok = 1;
                                    }
                                } else if (ext_cursor_style != 0 and self.cb.on_atlas_ensure_glyph_styled != null) {
                                    if (self.cb.on_atlas_ensure_glyph_styled) |styled_fn| {
                                        glyph_ok = styled_fn(self.ctx, cursor_cell.cp, ext_cursor_c_style, &glyph_entry);
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
                                        self.hl.default_bg; // attr_id == 0: swap default colors (per Nvim spec)
                                    const text_col = Helpers.rgb(cursor_fg);

                                    const cg_pts = Helpers.ndc4(gx0, gy0, gx1, gy1, grid_w, grid_h);
                                    const gtl = cg_pts[0]; const gtr = cg_pts[1]; const gbl = cg_pts[2]; const gbr = cg_pts[3];

                                    ext_verts.appendAssumeCapacity(.{ .position = gtl, .texCoord = .{ uv_x0, uv_y0 }, .color = text_col, .grid_id = grid_id, .deco_flags = c_api.DECO_SCROLLABLE, .deco_phase = 0 });
                                    ext_verts.appendAssumeCapacity(.{ .position = gtr, .texCoord = .{ uv_x1, uv_y0 }, .color = text_col, .grid_id = grid_id, .deco_flags = c_api.DECO_SCROLLABLE, .deco_phase = 0 });
                                    ext_verts.appendAssumeCapacity(.{ .position = gbl, .texCoord = .{ uv_x0, uv_y1 }, .color = text_col, .grid_id = grid_id, .deco_flags = c_api.DECO_SCROLLABLE, .deco_phase = 0 });
                                    ext_verts.appendAssumeCapacity(.{ .position = gtr, .texCoord = .{ uv_x1, uv_y0 }, .color = text_col, .grid_id = grid_id, .deco_flags = c_api.DECO_SCROLLABLE, .deco_phase = 0 });
                                    ext_verts.appendAssumeCapacity(.{ .position = gbr, .texCoord = .{ uv_x1, uv_y1 }, .color = text_col, .grid_id = grid_id, .deco_flags = c_api.DECO_SCROLLABLE, .deco_phase = 0 });
                                    ext_verts.appendAssumeCapacity(.{ .position = gbl, .texCoord = .{ uv_x0, uv_y1 }, .color = text_col, .grid_id = grid_id, .deco_flags = c_api.DECO_SCROLLABLE, .deco_phase = 0 });
                                }
                                } // end else (non-block-element ext cursor glyph)
                            }
                        }
                    }
                }
            }

            // CHECK: atlas reset happened during glyph processing for this row.
            // Already-sent rows have stale UVs → need to restart or abort.
            if (self.atlas_reset_during_flush) {
                ext_saw_atlas_reset = true;
                ext_saw_atlas_reset_any = true;
                self.atlas_reset_during_flush = false; // Clear for retry
                if (!ext_retried) {
                    ext_retried = true;
                    continue :ext_retry; // Restart this grid's row loop from row 0
                }
                break; // Abort remaining rows (2nd reset in same grid)
            }

            // Send this row's vertices
            // Pass viewport dimensions (target size) instead of sg dimensions so that
            // the frontend's scroll offset calculation matches the NDC viewport used here.
            if (ext_verts.items.len > 0) {
                row_cb(self.ctx, grid_id, row, 1, ext_verts.items.ptr, ext_verts.items.len, 1, viewport_rows, viewport_cols);
            }
        }
        break :ext_retry; // Normal exit from retry loop
        }

        // Debug log glyph statistics
        self.log.write("[ext_grid_row] grid_id={d} rows={d} cols={d} non_space={d} glyph_ok={d} glyph_fail={d}\n", .{
            grid_id, sg.rows, sg.cols, non_space_count, glyph_success_count, glyph_fail_count,
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

        // Grid width: start at main grid width, expand up to screen width, then scroll
        const min_width: u32 = if (self.grid.cols > 0) self.grid.cols else 80;
        const max_width: u32 = if (self.grid.screen_cols > 0) self.grid.screen_cols else min_width;
        const content_width: u32 = display_width + 1; // +1 for cursor
        const width: u32 = @min(@max(content_width, min_width), max_width);

        // Calculate scroll offset: if content exceeds width, scroll to show cursor (end)
        // We want cursor position (+ 1 for cursor cell) to be visible at the right edge
        const total_width: u32 = display_width + 1; // +1 for cursor at end
        const scroll_offset: u32 = if (total_width > width) total_width - width else 0;

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

        // prompt - use prompt_hl_id
        if (state.prompt.len > 0) {
            var piter = std.unicode.Utf8View.initUnchecked(state.prompt).iterator();
            while (piter.nextCodepoint()) |cp| {
                if (!writer.writeCell(cp, state.prompt_hl_id)) break;
                // Add continuation cell for wide characters
                if (isWideChar(cp)) {
                    if (!writer.writeCell(0, state.prompt_hl_id)) break;
                }
            }
        }

        // indent (spaces) - use hl_id 0
        var indent_i: u32 = 0;
        while (indent_i < state.indent) : (indent_i += 1) {
            if (!writer.writeCell(' ', 0)) break;
        }

        // content chunks - use each chunk's hl_id, with caret notation for control chars
        for (state.content.items) |chunk| {
            var citer = std.unicode.Utf8View.initUnchecked(chunk.text).iterator();
            while (citer.nextCodepoint()) |cp| {
                if (cp < 0x20) {
                    // Control character: display as ^X with chunk's hl_id
                    if (!writer.writeCell('^', chunk.hl_id)) break;
                    const ctrl_char: u32 = '@' + cp;
                    if (!writer.writeCell(ctrl_char, chunk.hl_id)) break;
                } else if (cp == 0x7F) {
                    // DEL character: display as ^?
                    if (!writer.writeCell('^', chunk.hl_id)) break;
                    if (!writer.writeCell('?', chunk.hl_id)) break;
                } else {
                    if (!writer.writeCell(cp, chunk.hl_id)) break;
                    // Add continuation cell for wide characters
                    if (isWideChar(cp)) {
                        if (!writer.writeCell(0, chunk.hl_id)) break;
                    }
                }
            }
        }

        // special_char (shown at cursor position after Ctrl-V etc.)
        if (!has_control_chars and special.len > 0) {
            var siter = std.unicode.Utf8View.initUnchecked(special).iterator();
            while (siter.nextCodepoint()) |cp| {
                if (!writer.writeCell(cp, 0)) break;
                // Add continuation cell for wide characters
                if (isWideChar(cp)) {
                    if (!writer.writeCell(0, 0)) break;
                }
            }
        }

        // Cursor position: firstc + prompt + indent + display_pos - scroll_offset
        var cursor_col: u32 = 0;
        if (state.firstc != 0) cursor_col += 1;
        cursor_col += countDisplayWidth(state.prompt);
        cursor_col += state.indent;
        // Calculate display position by counting through content
        var pos_remaining: u32 = state.pos;
        outer: for (state.content.items) |chunk| {
            var piter = std.unicode.Utf8View.initUnchecked(chunk.text).iterator();
            while (piter.nextCodepoint()) |cp| {
                if (pos_remaining == 0) break :outer;
                pos_remaining -= 1;
                if (cp < 0x20 or cp == 0x7F) {
                    cursor_col += 2; // ^X notation
                } else if (isWideChar(cp)) {
                    cursor_col += 2; // Wide character
                } else {
                    cursor_col += 1;
                }
            }
        }
        // Adjust cursor position for scroll offset
        cursor_col = if (cursor_col >= scroll_offset) cursor_col - scroll_offset else 0;

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
    // Minimum width = main grid width; frontend constrains to screen width
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
            if (state.firstc != 0) cursor_col += 1;
            cursor_col += countDisplayWidth(state.prompt);
            cursor_col += state.indent;
            // Calculate display position by counting through content
            var pos_remaining: u32 = state.pos;
            outer: for (state.content.items) |chunk| {
                var piter = std.unicode.Utf8View.initUnchecked(chunk.text).iterator();
                while (piter.nextCodepoint()) |cp| {
                    if (pos_remaining == 0) break :outer;
                    pos_remaining -= 1;
                    if (cp < 0x20 or cp == 0x7F) {
                        cursor_col += 2; // ^X notation
                    } else if (isWideChar(cp)) {
                        cursor_col += 2; // Wide character
                    } else {
                        cursor_col += 1;
                    }
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

    // Write block lines to grid (with caret notation for control characters)
    for (block_lines, 0..) |line, row_idx| {
        var col: u32 = 0;
        for (line.items) |chunk| {
            var iter = std.unicode.Utf8View.initUnchecked(chunk.text).iterator();
            while (iter.nextCodepoint()) |cp| {
                if (col >= max_width) break;
                if (cp < 0x20) {
                    // Control character: display as ^X (caret notation)
                    self.grid.putCellGrid(cmdline_grid_id, @intCast(row_idx), col, '^', chunk.hl_id);
                    col += 1;
                    if (col >= max_width) break;
                    const ctrl_char: u32 = '@' + cp;
                    self.grid.putCellGrid(cmdline_grid_id, @intCast(row_idx), col, ctrl_char, chunk.hl_id);
                    col += 1;
                } else if (cp == 0x7F) {
                    // DEL character: display as ^?
                    self.grid.putCellGrid(cmdline_grid_id, @intCast(row_idx), col, '^', chunk.hl_id);
                    col += 1;
                    if (col >= max_width) break;
                    self.grid.putCellGrid(cmdline_grid_id, @intCast(row_idx), col, '?', chunk.hl_id);
                    col += 1;
                } else {
                    self.grid.putCellGrid(cmdline_grid_id, @intCast(row_idx), col, cp, chunk.hl_id);
                    col += 1;
                    // Add continuation cell for wide characters
                    if (isWideChar(cp)) {
                        if (col >= max_width) break;
                        self.grid.putCellGrid(cmdline_grid_id, @intCast(row_idx), col, 0, chunk.hl_id);
                        col += 1;
                    }
                }
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

            // prompt - use prompt_hl_id
            if (state.prompt.len > 0) {
                var piter = std.unicode.Utf8View.initUnchecked(state.prompt).iterator();
                while (piter.nextCodepoint()) |cp| {
                    if (col >= max_width) break;
                    self.grid.putCellGrid(cmdline_grid_id, block_line_count, col, cp, state.prompt_hl_id);
                    col += 1;
                    // Add continuation cell for wide characters
                    if (isWideChar(cp)) {
                        if (col >= max_width) break;
                        self.grid.putCellGrid(cmdline_grid_id, block_line_count, col, 0, state.prompt_hl_id);
                        col += 1;
                    }
                }
            }

            // indent (spaces) - use hl_id 0
            var indent_i: u32 = 0;
            while (indent_i < state.indent and col < max_width) : (indent_i += 1) {
                self.grid.putCellGrid(cmdline_grid_id, block_line_count, col, ' ', 0);
                col += 1;
            }

            // content chunks - use each chunk's hl_id
            for (state.content.items) |chunk| {
                var citer = std.unicode.Utf8View.initUnchecked(chunk.text).iterator();
                while (citer.nextCodepoint()) |cp| {
                    if (col >= max_width) break;
                    if (cp < 0x20) {
                        // Control character: display as ^X with chunk's hl_id
                        self.grid.putCellGrid(cmdline_grid_id, block_line_count, col, '^', chunk.hl_id);
                        col += 1;
                        if (col >= max_width) break;
                        const ctrl_char: u32 = '@' + cp;
                        self.grid.putCellGrid(cmdline_grid_id, block_line_count, col, ctrl_char, chunk.hl_id);
                        col += 1;
                    } else if (cp == 0x7F) {
                        // DEL character: display as ^?
                        self.grid.putCellGrid(cmdline_grid_id, block_line_count, col, '^', chunk.hl_id);
                        col += 1;
                        if (col >= max_width) break;
                        self.grid.putCellGrid(cmdline_grid_id, block_line_count, col, '?', chunk.hl_id);
                        col += 1;
                    } else {
                        self.grid.putCellGrid(cmdline_grid_id, block_line_count, col, cp, chunk.hl_id);
                        col += 1;
                        // Add continuation cell for wide characters
                        if (isWideChar(cp)) {
                            if (col >= max_width) break;
                            self.grid.putCellGrid(cmdline_grid_id, block_line_count, col, 0, chunk.hl_id);
                            col += 1;
                        }
                    }
                }
            }

            // special_char (shown at cursor position after Ctrl-V etc.)
            if (!current_has_control_chars) {
                const special = state.getSpecialChar();
                if (special.len > 0) {
                    var siter = std.unicode.Utf8View.initUnchecked(special).iterator();
                    while (siter.nextCodepoint()) |cp| {
                        if (col >= max_width) break;
                        self.grid.putCellGrid(cmdline_grid_id, block_line_count, col, cp, 0);
                        col += 1;
                        // Add continuation cell for wide characters
                        if (isWideChar(cp)) {
                            if (col >= max_width) break;
                            self.grid.putCellGrid(cmdline_grid_id, block_line_count, col, 0, 0);
                            col += 1;
                        }
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

    // Register as external grid with position
    // For cmdline completion (grid_id < 0 or -1), use special positioning
    // For buffer completion, position 2 rows below anchor (1 for cursor line, 1 for spacing)
    const is_cmdline_completion = (anchor_grid < 0 or anchor_grid == -1);
    const start_row: i32 = if (is_cmdline_completion)
        -1 // Special marker for cmdline completion (Swift will position above cmdline)
    else
        anchor_row + 2; // 2 rows below: 1 for current line, 1 for spacing
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

/// Handle message changes - notify frontend via callbacks.
/// Uses throttle for msg_show (like noice.nvim) to accumulate messages before deciding view.
pub fn notifyMessageChanges(self: *Core) void {
    if (!self.ext_messages_enabled) return;

    const msg_dirty = self.grid.message_state.msg_dirty;
    const showmode_dirty = self.grid.message_state.showmode_dirty;
    const showcmd_dirty = self.grid.message_state.showcmd_dirty;
    const ruler_dirty = self.grid.message_state.ruler_dirty;
    const history_dirty = self.grid.msg_history_state.dirty;

    // Also check if there's a pending throttle timeout to handle
    const has_pending_throttle = self.msg_show_pending_since != null;

    if (!msg_dirty and !showmode_dirty and !showcmd_dirty and !ruler_dirty and !history_dirty and !has_pending_throttle) return;

    // Note: We don't use defer for clearMessageDirty anymore because msg_dirty
    // should only be cleared after throttle period expires
    defer self.grid.clearMsgHistoryDirty();

    // Handle msg_show/msg_clear changes
    // Use throttle only for external command output (list_cmd, shell_out, shell_err)
    // to accumulate messages before deciding split view vs message window.
    // When return_prompt arrives, we must act immediately (like noice.nvim).
    if (msg_dirty) {
        const messages = self.grid.message_state.messages.items;
        if (messages.len == 0) {
            // msg_clear: hide immediately
            hideMsgShow(self);
            self.msg_show_pending_since = null;
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
        // No messages - hide the message window and notify frontend (for confirm/prompt windows)
        _ = self.grid.external_grids.fetchRemove(msg_grid_id);
        self.log.write("[msg] sendMsgShow: hide (empty)\n", .{});
        // Call on_msg_clear to hide any native prompt windows (confirm dialogs)
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
                // Send to frontend callback for confirm view display (no timeout)
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
                    // Copy text before newline
                    const copy_len = @min(pos, current_line.data.len - current_line.len);
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
        .win = 1, // Main grid
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
    // Call on_msg_clear to hide any native prompt windows (confirm dialogs)
    if (self.cb.on_msg_clear) |cb| {
        cb(self.ctx);
    }
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

    // Hide msg_history external grid
    hideMsgHistory(self);

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
            self.log.write("[msg_history] view=none, hiding\n", .{});
            return;
        },
        .mini => {
            // Mini view: send all entries combined to frontend callback
            self.log.write("[msg_history] view=mini, sending {d} entries to callback\n", .{entries.len});
            sendMsgHistoryCallbackAll(self, entries, route_result.view);
            return;
        },
        .notification => {
            // Notification view: send all entries combined to frontend callback for OS notification
            self.log.write("[msg_history] view=notification, sending {d} entries to callback\n", .{entries.len});
            sendMsgHistoryCallbackAll(self, entries, route_result.view);
            return;
        },
        .split => {
            // Split view: create Neovim split window
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
        .win = 1, // Main grid
        .start_row = -2, // Special marker: position like msg_show (top-right)
        .start_col = -2,
    }) catch |e| {
        self.log.write("[msg_history] external_grids.put failed: {any}\n", .{e});
        return;
    };
}

/// Hide msg_history external grid.
pub fn hideMsgHistory(self: *Core) void {
    const history_grid_id = grid_mod.MSG_HISTORY_GRID_ID;
    _ = self.grid.external_grids.fetchRemove(history_grid_id);
    self.log.write("[msg_history] hide\n", .{});
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
pub fn countDisplayWidth(s: []const u8) u32 {
    var count: u32 = 0;
    var iter = std.unicode.Utf8View.initUnchecked(s).iterator();
    while (iter.nextCodepoint()) |cp| {
        if (cp < 0x20 or cp == 0x7F) {
            count += 2; // ^X notation takes 2 columns
        } else if (isWideChar(cp)) {
            count += 2; // Wide character takes 2 columns
        } else {
            count += 1;
        }
    }
    return count;
}
