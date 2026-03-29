// app.zig — Central application state and type definitions for Linux frontend.
//
// All types that appear as App fields, and all cross-cutting constants,
// are defined here to avoid circular imports between sub-modules.

const std = @import("std");
const core = @import("zonvie_core");
pub const gtk_mod = @import("gtk_bindings.zig");
pub const gl = @import("gl.zig");
pub const applog = @import("app_log.zig");
const builtin = @import("builtin");
pub const config_mod = @import("config.zig");

// Re-export core types used across modules
pub const Vertex = core.Vertex;
pub const BgSpan = core.BgSpan;
pub const TextRun = core.TextRun;
pub const Cursor = core.Cursor;
pub const GlyphEntry = core.GlyphEntry;
pub const GlyphBitmap = core.GlyphBitmap;
pub const MsgChunk = core.MsgChunk;
pub const zonvie_msg_view_type = core.zonvie_msg_view_type;
pub const ViewportInfo = core.ViewportInfo;
pub const zonvie_core = core.zonvie_core;
pub const zonvie_callbacks = core.zonvie_callbacks;

// Re-export core functions used across modules
pub const zonvie_core_create = core.zonvie_core_create;
pub const zonvie_core_destroy = core.zonvie_core_destroy;
pub const zonvie_core_start = core.zonvie_core_start;
pub const zonvie_core_stop = core.zonvie_core_stop;
pub const zonvie_core_send_input = core.zonvie_core_send_input;
pub const zonvie_core_send_key_event = core.zonvie_core_send_key_event;
pub const zonvie_core_resize = core.zonvie_core_resize;
pub const zonvie_core_try_resize_grid = core.zonvie_core_try_resize_grid;
pub const zonvie_core_get_viewport = core.zonvie_core_get_viewport;
pub const zonvie_core_get_visible_grids = core.zonvie_core_get_visible_grids;
pub const zonvie_core_try_get_visible_grids = core.zonvie_core_try_get_visible_grids;
pub const zonvie_core_get_cursor_position = core.zonvie_core_get_cursor_position;
pub const zonvie_core_get_win_id = core.zonvie_core_get_win_id;
pub const zonvie_core_get_current_mode = core.zonvie_core_get_current_mode;
pub const zonvie_core_is_cursor_visible = core.zonvie_core_is_cursor_visible;
pub const zonvie_core_get_cursor_blink = core.zonvie_core_get_cursor_blink;
pub const zonvie_core_send_mouse_scroll = core.zonvie_core_send_mouse_scroll;
pub const zonvie_core_scroll_to_line = core.zonvie_core_scroll_to_line;
pub const zonvie_core_page_scroll = core.zonvie_core_page_scroll;
pub const zonvie_core_process_pending_msg_scroll = core.zonvie_core_process_pending_msg_scroll;
pub const zonvie_core_send_mouse_input = core.zonvie_core_send_mouse_input;
pub const zonvie_core_update_layout_px = core.zonvie_core_update_layout_px;
pub const zonvie_core_set_screen_cols = core.zonvie_core_set_screen_cols;
pub const zonvie_core_get_hl_by_name = core.zonvie_core_get_hl_by_name;
pub const zonvie_core_set_log_enabled = core.zonvie_core_set_log_enabled;
pub const zonvie_core_set_ext_cmdline = core.zonvie_core_set_ext_cmdline;
pub const zonvie_core_set_ext_popupmenu = core.zonvie_core_set_ext_popupmenu;
pub const zonvie_core_set_ext_messages = core.zonvie_core_set_ext_messages;
pub const zonvie_core_set_ext_tabline = core.zonvie_core_set_ext_tabline;
pub const zonvie_core_tick_msg_throttle = core.zonvie_core_tick_msg_throttle;
pub const zonvie_core_set_blur_enabled = core.zonvie_core_set_blur_enabled;
pub const zonvie_core_set_inherit_cwd = core.zonvie_core_set_inherit_cwd;
pub const zonvie_core_set_glyph_cache_size = core.zonvie_core_set_glyph_cache_size;
pub const zonvie_core_set_atlas_size = core.zonvie_core_set_atlas_size;
pub const zonvie_core_load_config = core.zonvie_core_load_config;
pub const zonvie_core_route_message = core.zonvie_core_route_message;
pub const zonvie_core_request_quit = core.zonvie_core_request_quit;
pub const zonvie_core_quit_confirmed = core.zonvie_core_quit_confirmed;
pub const zonvie_core_send_stdin_data = core.zonvie_core_send_stdin_data;
pub const zonvie_core_send_command = core.zonvie_core_send_command;
pub const zonvie_core_set_background_opacity = core.zonvie_core_set_background_opacity;
pub const zonvie_core_perf_now_ns = core.zonvie_core_perf_now_ns;
pub const zonvie_core_note_input_trace = core.zonvie_core_note_input_trace;
pub const zonvie_core_abort_flush = core.zonvie_core_abort_flush;

// Re-export additional core types used by sub-modules
pub const Callbacks = core.Callbacks;
pub const VERT_UPDATE_MAIN = core.VERT_UPDATE_MAIN;
pub const VERT_UPDATE_CURSOR = core.VERT_UPDATE_CURSOR;
pub const DECO_CURSOR = core.DECO_CURSOR;
pub const CmdlineChunk = core.CmdlineChunk;
pub const BufferEntry = core.BufferEntry;
pub const GridInfo = core.GridInfo;
pub const MsgHistoryEntry = core.MsgHistoryEntry;
pub const zonvie_msg_event = core.zonvie_msg_event;

// =========================================================================
// Scrollbar constants (logical pixels, multiply by dpi_scale for device pixels)
// =========================================================================

pub const SCROLLBAR_WIDTH: f32 = 12.0;
pub const SCROLLBAR_MARGIN: f32 = 2.0;
pub const SCROLLBAR_MIN_KNOB_HEIGHT: f32 = 20.0;
pub const SCROLLBAR_CORNER_RADIUS: f32 = 4.0;
pub const SCROLLBAR_THROTTLE_MS: i64 = 32;

pub fn scrollbarWidth(dpi_scale: f32) f32 {
    return SCROLLBAR_WIDTH * dpi_scale;
}
pub fn scrollbarMargin(dpi_scale: f32) f32 {
    return SCROLLBAR_MARGIN * dpi_scale;
}
pub fn scrollbarMinKnobHeight(dpi_scale: f32) f32 {
    return SCROLLBAR_MIN_KNOB_HEIGHT * dpi_scale;
}
pub fn scrollbarCornerRadius(dpi_scale: f32) f32 {
    return SCROLLBAR_CORNER_RADIUS * dpi_scale;
}
pub fn scrollbarReservedWidth(dpi_scale: f32) f32 {
    return scrollbarWidth(dpi_scale) + scrollbarMargin(dpi_scale) * 2;
}

// =========================================================================
// Grid ID constants
// =========================================================================

/// Reserved grid ID for ext_cmdline (same as grid.zig CMDLINE_GRID_ID)
pub const CMDLINE_GRID_ID: i64 = -100;
/// Reserved grid ID for ext_popupmenu (same as grid.zig POPUPMENU_GRID_ID)
pub const POPUPMENU_GRID_ID: i64 = -101;
/// Reserved grid ID for ext_messages
pub const MESSAGE_GRID_ID: i64 = -102;
/// Reserved grid ID for msg_history (same as grid.zig MSG_HISTORY_GRID_ID)
pub const MSG_HISTORY_GRID_ID: i64 = -103;

// =========================================================================
// Cmdline / message styling constants (matching macOS / Windows)
// =========================================================================

pub const CMDLINE_PADDING: u32 = 12;
pub const CMDLINE_ICON_SIZE: u32 = 18;
pub const CMDLINE_ICON_MARGIN_LEFT: u32 = 2;
pub const CMDLINE_ICON_MARGIN_RIGHT: u32 = 4;
pub const CMDLINE_BORDER_WIDTH: u32 = 1;
pub const CMDLINE_CORNER_RADIUS: f32 = 8.0;
pub const MSG_PADDING: u32 = 8;

// =========================================================================
// Message display types
// =========================================================================

pub const MiniWindowId = enum(u8) {
    showmode = 0,
    showcmd = 1,
    ruler = 2,
};

pub const MiniWindow = struct {
    text: [256]u8 = undefined,
    text_len: usize = 0,
};


// =========================================================================
// Tabline style
// =========================================================================

pub const TablineStyle = enum {
    titlebar,
    sidebar,
    menu,
};

// =========================================================================
// Global variables
// =========================================================================

// Global exit code (returned from main)
pub var g_exit_code: std.atomic.Value(u8) = std.atomic.Value(u8).init(0);

// Global app pointer for GTK signal handlers that can't carry user_data
pub var g_app: ?*App = null;

// =========================================================================
// Type definitions
// =========================================================================

/// Pending atlas operation, queued from core thread and flushed on GL thread.
pub const PendingAtlasOp = union(enum) {
    create: struct { w: u32, h: u32 },
    upload: struct {
        dest_x: u32,
        dest_y: u32,
        width: u32,
        height: u32,
        pixels: []u8, // owned copy, freed after upload
        bpp: u32,
        pitch: i32,
    },
};

/// Pending external window creation request
pub const PendingExternalWindow = struct {
    grid_id: i64,
    win: i64,
    rows: u32,
    cols: u32,
    start_row: i32,
    start_col: i32,
};

/// Rect struct (replaces Win32 RECT)
pub const Rect = struct {
    left: i32 = 0,
    top: i32 = 0,
    right: i32 = 0,
    bottom: i32 = 0,
};

/// CPU-side surface state shared between external windows and pending
/// external vertices. Holds vertex storage, grid dimensions, dirty
/// tracking, and cursor row info.
pub const SurfaceState = struct {
    verts: std.ArrayListUnmanaged(Vertex) = .{},
    row_verts: std.ArrayListUnmanaged(RowVerts) = .{},
    cursor_verts: std.ArrayListUnmanaged(Vertex) = .{},
    row_mode: bool = false,
    dirty_rows: std.AutoHashMapUnmanaged(u32, void) = .{},
    paint_full: bool = true,
    rows: u32 = 0,
    cols: u32 = 0,
    last_cursor_row: ?u32 = null,

    pub fn ensureRowStorage(self: *SurfaceState, alloc: std.mem.Allocator, row: u32) void {
        const need: usize = @intCast(row + 1);
        if (self.row_verts.items.len >= need) return;
        const old_len = self.row_verts.items.len;
        self.row_verts.resize(alloc, need) catch return;
        var i = old_len;
        while (i < need) : (i += 1) {
            self.row_verts.items[i] = .{};
        }
    }

    pub fn clearExtraRows(self: *SurfaceState, needed_rows: u32) void {
        const start: usize = @intCast(needed_rows);
        if (start >= self.row_verts.items.len) return;
        for (self.row_verts.items[start..]) |*rv| {
            rv.verts.clearRetainingCapacity();
        }
    }

    pub fn recomputeVertCount(self: *const SurfaceState) usize {
        var total: usize = 0;
        for (self.row_verts.items) |rv| {
            total += rv.verts.items.len;
        }
        return total;
    }

    /// Free CPU-side allocations only.
    pub fn deinitCpuState(self: *SurfaceState, alloc: std.mem.Allocator) void {
        self.cursor_verts.deinit(alloc);
        self.dirty_rows.deinit(alloc);
        self.verts.deinit(alloc);
        for (self.row_verts.items) |*rv| {
            rv.verts.deinit(alloc);
        }
        self.row_verts.deinit(alloc);
    }
};

// =========================================================================
// Triple-buffered surface types
// =========================================================================

/// Sentinel value for "no slot assigned".
pub const SLOT_NONE: u16 = std.math.maxInt(u16);

/// Physical row slot. Ref-counted vertex buffer shared across VertexSets.
pub const RowSlot = struct {
    verts: std.ArrayListUnmanaged(Vertex) = .{},
    ref_count: u16 = 0,
    origin_row: u32 = 0,
    ver: u64 = 0,
};

/// Logical-to-physical row mapping (one per logical row per VertexSet).
pub const RowMapping = struct {
    slot: u16 = SLOT_NONE,
};

/// Pool of physical row slots shared across all VertexSets in a TBS.
pub const SlotPool = struct {
    slots: std.ArrayListUnmanaged(RowSlot) = .{},
    free_list: std.ArrayListUnmanaged(u16) = .{},

    pub fn acquireSlot(self: *SlotPool, alloc: std.mem.Allocator) ?u16 {
        if (self.free_list.items.len > 0) {
            return self.free_list.pop();
        }
        const idx: u16 = @intCast(self.slots.items.len);
        self.slots.append(alloc, .{}) catch return null;
        return idx;
    }

    pub fn retain(self: *SlotPool, idx: u16) void {
        if (idx == SLOT_NONE) return;
        self.slots.items[idx].ref_count += 1;
    }

    pub fn release(self: *SlotPool, alloc: std.mem.Allocator, idx: u16) void {
        if (idx == SLOT_NONE) return;
        const slot = &self.slots.items[idx];
        if (slot.ref_count > 0) {
            slot.ref_count -= 1;
        }
        if (slot.ref_count == 0) {
            self.free_list.append(alloc, idx) catch {};
        }
    }

    pub fn deinit(self: *SlotPool, alloc: std.mem.Allocator) void {
        for (self.slots.items) |*s| {
            s.verts.deinit(alloc);
        }
        self.slots.deinit(alloc);
        self.free_list.deinit(alloc);
    }
};

/// One frame's worth of CPU-side vertex data.
/// Three of these rotate inside TripleBufferedSurface.
pub const VertexSet = struct {
    row_map: std.ArrayListUnmanaged(RowMapping) = .{},
    cursor_verts: std.ArrayListUnmanaged(Vertex) = .{},
    flat_verts: std.ArrayListUnmanaged(Vertex) = .{},
    row_mode: bool = false,
    rows: u32 = 0,
    cols: u32 = 0,
    last_cursor_row: ?u32 = null,

    pub fn ensureRowStorage(self: *VertexSet, alloc: std.mem.Allocator, row: u32) void {
        const need: usize = @intCast(row + 1);
        if (self.row_map.items.len >= need) return;
        const old_len = self.row_map.items.len;
        self.row_map.resize(alloc, need) catch return;
        var i = old_len;
        while (i < need) : (i += 1) {
            self.row_map.items[i] = .{};
        }
    }

    pub fn releaseAllSlots(self: *VertexSet, alloc: std.mem.Allocator, pool: *SlotPool) void {
        for (self.row_map.items) |*m| {
            if (m.slot != SLOT_NONE) {
                pool.release(alloc, m.slot);
                m.slot = SLOT_NONE;
            }
        }
    }

    pub fn recomputeVertCount(self: *const VertexSet, pool: *const SlotPool) usize {
        var total: usize = 0;
        for (self.row_map.items) |m| {
            if (m.slot != SLOT_NONE) {
                total += pool.slots.items[m.slot].verts.items.len;
            }
        }
        return total;
    }

    pub fn deinitCpu(self: *VertexSet, alloc: std.mem.Allocator) void {
        self.cursor_verts.deinit(alloc);
        self.flat_verts.deinit(alloc);
        self.row_map.deinit(alloc);
    }
};

/// Snapshot returned by acquireForPaint.
pub const PaintSnapshot = struct {
    committed_index: u8,
    paint_full: bool,
    scroll_rect: ?Rect = null,
    scroll_dy_px: i32 = 0,
    vb_shift: i32 = 0,
};

/// Triple-buffered surface: lock-free vertex handoff from core thread to UI thread.
pub const TripleBufferedSurface = struct {
    pub const SET_COUNT = 3;
    sets: [SET_COUNT]VertexSet = .{ .{}, .{}, .{} },
    pool: SlotPool = .{},

    rotation_mu: std.Thread.Mutex = .{},
    write_index: u8 = 0,
    committed_index: u8 = 1,
    flush_source_index: u8 = 1,
    is_in_flush: bool = false,
    commit_rev: u64 = 0,

    ui_read_refcount: [SET_COUNT]u32 = .{ 0, 0, 0 },

    pending_dirty: std.DynamicBitSetUnmanaged = .{},
    pending_paint_full: bool = true,

    flush_dirty: std.DynamicBitSetUnmanaged = .{},
    flush_paint_full: bool = false,

    flush_scroll_rect: ?Rect = null,
    flush_scroll_dy_px: i32 = 0,
    flush_vb_shift: i32 = 0,

    pending_scroll_rect: ?Rect = null,
    pending_scroll_dy_px: i32 = 0,
    pending_vb_shift: i32 = 0,

    paint_dirty_snapshot: std.DynamicBitSetUnmanaged = .{},
    paint_nesting: u32 = 0,

    pub fn hasFreeSet(self: *TripleBufferedSurface) bool {
        self.rotation_mu.lock();
        defer self.rotation_mu.unlock();
        const ci = self.committed_index;
        for (0..SET_COUNT) |i| {
            const idx: u8 = @intCast(i);
            if (idx != ci and self.ui_read_refcount[i] == 0) return true;
        }
        return false;
    }

    pub fn beginFlush(self: *TripleBufferedSurface, alloc: std.mem.Allocator) bool {
        var picked: ?u8 = null;
        var ci: u8 = undefined;

        {
            self.rotation_mu.lock();
            defer self.rotation_mu.unlock();
            ci = self.committed_index;
            for (0..SET_COUNT) |i| {
                const idx: u8 = @intCast(i);
                if (idx != ci and self.ui_read_refcount[i] == 0) {
                    picked = idx;
                    break;
                }
            }
            if (picked == null) return false;
            self.write_index = picked.?;
            self.flush_source_index = ci;
        }

        const wi = picked.?;
        if (!self.shallowCopyVertexSet(alloc, wi, ci)) return false;

        if (self.flush_dirty.bit_length > 0) {
            self.flush_dirty.unsetAll();
        }
        self.flush_paint_full = false;
        self.flush_scroll_rect = null;
        self.flush_scroll_dy_px = 0;
        self.flush_vb_shift = 0;

        self.is_in_flush = true;
        return true;
    }

    pub fn cancelFlush(self: *TripleBufferedSurface) void {
        self.is_in_flush = false;
    }

    pub fn commitFlush(self: *TripleBufferedSurface, alloc: std.mem.Allocator) void {
        if (!self.is_in_flush) return;

        self.rotation_mu.lock();
        defer self.rotation_mu.unlock();

        if (self.flush_dirty.bit_length > 0) {
            if (self.pending_dirty.bit_length != self.flush_dirty.bit_length) {
                self.pending_dirty.resize(alloc, self.flush_dirty.bit_length, false) catch {
                    self.pending_paint_full = true;
                    self.flush_dirty.unsetAll();
                    self.committed_index = self.write_index;
                    self.commit_rev +%= 1;
                    self.is_in_flush = false;
                    return;
                };
                if (self.paint_nesting == 0) {
                    self.paint_dirty_snapshot.resize(alloc, self.flush_dirty.bit_length, false) catch {
                        self.pending_paint_full = true;
                    };
                }
            }

            if (self.pending_dirty.bit_length == self.flush_dirty.bit_length) {
                self.mergeDirtyBits();
            } else {
                self.pending_paint_full = true;
            }
        }

        if (self.flush_paint_full) {
            self.pending_paint_full = true;
        }

        // Merge flush scroll state into pending scroll
        if (self.flush_scroll_rect) |flush_rect| {
            if (self.pending_scroll_rect) |pending_rect| {
                if (pending_rect.left == flush_rect.left and pending_rect.right == flush_rect.right and
                    pending_rect.top == flush_rect.top and pending_rect.bottom == flush_rect.bottom)
                {
                    self.pending_scroll_dy_px += self.flush_scroll_dy_px;
                    self.pending_vb_shift += self.flush_vb_shift;
                } else {
                    self.pending_scroll_rect = null;
                    self.pending_scroll_dy_px = 0;
                    self.pending_vb_shift = 0;
                    self.pending_paint_full = true;
                }
            } else {
                self.pending_scroll_rect = flush_rect;
                self.pending_scroll_dy_px = self.flush_scroll_dy_px;
                self.pending_vb_shift = self.flush_vb_shift;
            }
        }

        self.committed_index = self.write_index;
        self.commit_rev +%= 1;
        self.is_in_flush = false;
    }

    pub fn writeSet(self: *TripleBufferedSurface) *VertexSet {
        return &self.sets[self.write_index];
    }

    pub fn acquireForPaint(self: *TripleBufferedSurface) PaintSnapshot {
        self.rotation_mu.lock();
        defer self.rotation_mu.unlock();

        const ci = self.committed_index;
        self.ui_read_refcount[ci] += 1;

        var paint_full: bool = false;

        if (self.paint_nesting == 0) {
            if (self.paint_dirty_snapshot.bit_length != self.pending_dirty.bit_length) {
                self.pending_paint_full = true;
                self.pending_dirty.unsetAll();
            } else if (self.pending_dirty.bit_length > 0) {
                self.copyDirtySnapshot();
                self.pending_dirty.unsetAll();
            }
            paint_full = self.pending_paint_full;
            self.pending_paint_full = false;
        }

        var scroll_rect: ?Rect = null;
        var scroll_dy_px: i32 = 0;
        var vb_shift: i32 = 0;
        if (self.paint_nesting == 0) {
            scroll_rect = self.pending_scroll_rect;
            scroll_dy_px = self.pending_scroll_dy_px;
            vb_shift = self.pending_vb_shift;
            self.pending_scroll_rect = null;
            self.pending_scroll_dy_px = 0;
            self.pending_vb_shift = 0;
        }

        self.paint_nesting += 1;
        return .{
            .committed_index = ci,
            .paint_full = paint_full,
            .scroll_rect = scroll_rect,
            .scroll_dy_px = scroll_dy_px,
            .vb_shift = vb_shift,
        };
    }

    pub fn releaseFromPaint(self: *TripleBufferedSurface, index: u8) bool {
        self.rotation_mu.lock();
        defer self.rotation_mu.unlock();
        self.ui_read_refcount[index] -= 1;
        self.paint_nesting -= 1;
        const needs_reinvalidate = (self.paint_nesting == 0) and
            (self.pending_dirty.count() > 0 or self.pending_paint_full);
        return needs_reinvalidate;
    }

    // --- Internal helpers ---

    fn numMasks(bit_length: usize) usize {
        return (bit_length + (@bitSizeOf(usize) - 1)) / @bitSizeOf(usize);
    }

    fn shallowCopyVertexSet(self: *TripleBufferedSurface, alloc: std.mem.Allocator, dst_idx: u8, src_idx: u8) bool {
        const dst = &self.sets[dst_idx];
        const src = &self.sets[src_idx];

        dst.releaseAllSlots(alloc, &self.pool);

        dst.row_mode = src.row_mode;
        dst.rows = src.rows;
        dst.cols = src.cols;
        dst.last_cursor_row = src.last_cursor_row;

        const src_len = src.row_map.items.len;
        dst.row_map.resize(alloc, src_len) catch return false;
        @memcpy(dst.row_map.items[0..src_len], src.row_map.items[0..src_len]);

        for (dst.row_map.items) |m| {
            self.pool.retain(m.slot);
        }

        dst.cursor_verts.clearRetainingCapacity();
        dst.cursor_verts.appendSlice(alloc, src.cursor_verts.items) catch return false;

        dst.flat_verts.clearRetainingCapacity();
        dst.flat_verts.appendSlice(alloc, src.flat_verts.items) catch return false;

        return true;
    }

    pub fn cowDetachRow(self: *TripleBufferedSurface, alloc: std.mem.Allocator, row: u32) ?*RowSlot {
        const vs = self.writeSet();
        if (row >= vs.row_map.items.len) return null;
        const mapping = &vs.row_map.items[row];
        const old_slot = mapping.slot;

        if (old_slot == SLOT_NONE) {
            const new_idx = self.pool.acquireSlot(alloc) orelse return null;
            mapping.slot = new_idx;
            self.pool.retain(new_idx);
            return &self.pool.slots.items[new_idx];
        }

        if (self.pool.slots.items[old_slot].ref_count > 1) {
            const new_idx = self.pool.acquireSlot(alloc) orelse return null;
            self.pool.release(alloc, old_slot);
            mapping.slot = new_idx;
            self.pool.retain(new_idx);
            return &self.pool.slots.items[new_idx];
        }

        return &self.pool.slots.items[old_slot];
    }

    fn mergeDirtyBits(self: *TripleBufferedSurface) void {
        const pd_n = numMasks(self.pending_dirty.bit_length);
        const fd_n = numMasks(self.flush_dirty.bit_length);
        if (pd_n == 0 or fd_n == 0) return;
        const len = @min(pd_n, fd_n);
        for (0..len) |i| {
            self.pending_dirty.masks[i] |= self.flush_dirty.masks[i];
        }
    }

    fn copyDirtySnapshot(self: *TripleBufferedSurface) void {
        const dst_n = numMasks(self.paint_dirty_snapshot.bit_length);
        const src_n = numMasks(self.pending_dirty.bit_length);
        if (dst_n == 0 or src_n == 0) return;
        const len = @min(dst_n, src_n);
        for (0..len) |i| {
            self.paint_dirty_snapshot.masks[i] = self.pending_dirty.masks[i];
        }
        if (dst_n > len) {
            for (len..dst_n) |i| {
                self.paint_dirty_snapshot.masks[i] = 0;
            }
        }
    }

    pub fn deinit(self: *TripleBufferedSurface, alloc: std.mem.Allocator) void {
        for (&self.sets) |*set| {
            set.releaseAllSlots(alloc, &self.pool);
            set.deinitCpu(alloc);
        }
        self.pool.deinit(alloc);
        self.pending_dirty.deinit(alloc);
        self.flush_dirty.deinit(alloc);
        self.paint_dirty_snapshot.deinit(alloc);
    }
};

/// Pending vertices for an external window that hasn't been created yet.
pub const PendingExternalVertices = struct {
    grid_id: i64,
    surface: SurfaceState,

    pub fn deinit(self: *PendingExternalVertices, alloc: std.mem.Allocator) void {
        self.surface.deinitCpuState(alloc);
    }
};

/// Legacy combined struct for backward compatibility.
pub const RowVerts = struct {
    verts: std.ArrayListUnmanaged(Vertex) = .{},

    // GL VBO handle (owned by renderer, set to 0 when not created)
    gl_vbo: u32 = 0,
    vbo_bytes: usize = 0,

    gen: u64 = 0,
    uploaded_gen: u64 = 0,
    origin_row: u32 = 0,
};

/// GPU-side per-row vertex buffer (OpenGL). Owned exclusively by the UI thread.
pub const RowVB = struct {
    gl_vbo: u32 = 0,
    vbo_bytes: usize = 0,
    uploaded_slot: u16 = SLOT_NONE,
    uploaded_ver: u64 = 0,
};

/// External window state for ext_windows grids
pub const ExternalWindow = struct {
    // GTK handles stored as opaque pointers (resolved via zig-gobject at use site)
    gtk_window: ?*anyopaque = null,
    gl_area_ext: ?*anyopaque = null,
    win_id: i64 = 0,

    surface: SurfaceState = .{},
    tbs: TripleBufferedSurface = .{},
    row_vbs: std.ArrayListUnmanaged(RowVB) = .{},

    needs_redraw: bool = false,
    rows: u32 = 0,
    cols: u32 = 0,
    start_row: i32 = 0,
    start_col: i32 = 0,

    pub fn deinit(self: *ExternalWindow, alloc: std.mem.Allocator) void {
        for (self.row_vbs.items) |*rvb| {
            if (rvb.gl_vbo != 0) {
                gl.glDeleteBuffers(1, &rvb.gl_vbo);
                rvb.gl_vbo = 0;
            }
        }
        self.row_vbs.deinit(alloc);
        self.tbs.deinit(alloc);
        self.surface.deinitCpuState(alloc);
    }
};

// =========================================================================
// App struct — Central application state
// =========================================================================

pub const App = struct {
    alloc: std.mem.Allocator,
    config: config_mod.Config = .{},
    mu: std.Thread.Mutex = .{},

    // GTK handles (stored as opaque pointers, cast to zig-gobject types at use site)
    gtk_app: ?*anyopaque = null,
    main_window: ?*anyopaque = null,
    gl_area: ?*anyopaque = null,
    im_context: ?*anyopaque = null,
    tab_bar_box: ?*anyopaque = null,
    mini_label: ?*anyopaque = null,
    preedit_label: ?*anyopaque = null,
    preedit_overlay: ?*anyopaque = null, // GtkOverlay parent (for positioning)

    // Core
    corep: ?*zonvie_core = null,

    // Rendering state
    surface: SurfaceState = .{},
    tbs: TripleBufferedSurface = .{},
    row_vbs: std.ArrayListUnmanaged(RowVB) = .{},
    row_valid: std.DynamicBitSetUnmanaged = .{},
    row_valid_count: u32 = 0,
    flush_needs_invalidate: bool = false,

    // External windows
    external_windows: std.AutoHashMapUnmanaged(i64, ExternalWindow) = .{},
    pending_external_windows: std.ArrayListUnmanaged(PendingExternalWindow) = .{},
    pending_external_verts: std.ArrayListUnmanaged(PendingExternalVertices) = .{},

    // ext_cmdline state
    cmdline_firstc: u8 = 0,
    cmdline_visible: bool = false,
    cmdline_border_color: [3]f32 = .{ 1.0, 1.0, 0.0 }, // default yellow (Search bg)
    cmdline_icon_color: [3]f32 = .{ 0.5, 0.5, 0.5 }, // default gray (Comment fg)

    // ext_messages state
    mini_windows: [3]MiniWindow = [_]MiniWindow{.{}} ** 3,
    msg_hide_timer: c_uint = 0,

    // ext_tabline state
    tabline: @import("ui/tabbar.zig").TablineState = .{},

    // ext_popupmenu state
    popupmenu_visible: bool = false,
    popupmenu_anchor_row: i32 = 0,
    popupmenu_anchor_col: i32 = 0,
    popupmenu_anchor_grid: i64 = 1,

    // UI extensions
    ext_cmdline_enabled: bool = false,
    ext_messages_enabled: bool = false,
    ext_tabline_enabled: bool = false,
    ext_popup_enabled: bool = false,
    ext_windows_enabled: bool = false,
    tabline_style: TablineStyle = .titlebar,
    sidebar_position_right: bool = false,
    sidebar_width_px: u32 = 200,

    // Grid metrics
    cell_w_px: u32 = 9,
    cell_h_px: u32 = 18,
    linespace_px: u32 = 0,
    dpi_scale: f32 = 1.0,
    drawable_w_px: u32 = 0,
    drawable_h_px: u32 = 0,

    // Default colors
    default_fg: u32 = 0x00FFFFFF,
    default_bg: u32 = 0x00000000,

    // Cursor
    cursor: ?Cursor = null,
    last_painted_cursor_row: ?u32 = null,
    cursor_blink_state: bool = true,
    cursor_blink_timer: c_uint = 0,
    cursor_blink_phase: u8 = 0, // 0 = wait, 1 = blink cycle
    cursor_blink_wait_ms: u32 = 0,
    cursor_blink_on_ms: u32 = 0,
    cursor_blink_off_ms: u32 = 0,

    // Scrollbar
    scrollbar: @import("ui/scrollbar.zig").ScrollbarState = .{},
    scrollbar_last_scroll_time: i64 = 0,

    // SSH / remote
    ssh_mode: bool = false,
    ssh_host: ?[]const u8 = null,
    ssh_port: ?u16 = null,
    ssh_identity: ?[]const u8 = null,
    ssh_password: ?[]const u8 = null,

    // Devcontainer
    devcontainer_mode: bool = false,
    devcontainer_workspace: ?[]const u8 = null,
    devcontainer_config: ?[]const u8 = null,
    devcontainer_rebuild: bool = false,

    // Extra nvim args
    nvim_extra_args: std.ArrayListUnmanaged([]const u8) = .{},
    cli_nvim_path: ?[]const u8 = null,

    // Deferred GL resize flag (set from onResize, processed in render with GL context current)
    gl_needs_resize: bool = false,
    // CSS provider for dynamic background color updates
    css_provider: ?*anyopaque = null,
    // Last drawable dimensions at the time of a successful flush commit.
    // Used to keep rendering with old viewport during resize until new flush arrives.
    last_flush_w: u32 = 0,
    last_flush_h: u32 = 0,

    // Pending atlas operations (queued from core thread, flushed on GL thread)
    pending_atlas_ops: std.ArrayListUnmanaged(PendingAtlasOp) = .{},
    atlas_mu: std.Thread.Mutex = .{},

    // GL state
    gl_program_main: u32 = 0,
    gl_program_bg: u32 = 0,
    gl_program_glow_extract: u32 = 0,
    gl_program_kawase_down: u32 = 0,
    gl_program_kawase_up: u32 = 0,
    gl_program_glow_composite: u32 = 0,
    gl_vao: u32 = 0,
    gl_atlas_texture: u32 = 0,
    atlas_w: u32 = 0,
    atlas_h: u32 = 0,

    // Glow FBOs
    glow_extract_fbo: u32 = 0,
    glow_extract_tex: u32 = 0,
    glow_mip_fbo: [3]u32 = .{ 0, 0, 0 },
    glow_mip_tex: [3]u32 = .{ 0, 0, 0 },

    // Font metrics (26.6 fixed-point, cached at font load time)
    font_ascent_26_6: i32 = 0,
    font_descent_26_6: i32 = 0,

    // FreeType/HarfBuzz font handle (opaque C pointer from zonvie_hbft.h)
    ft_hb_font: ?*anyopaque = null,
    ft_hb_font_bold: ?*anyopaque = null,
    ft_hb_font_italic: ?*anyopaque = null,
    ft_hb_font_bold_italic: ?*anyopaque = null,

    // Rasterization perf counters (atomics for cross-thread access)
    rasterize_call_count: std.atomic.Value(u64) = .init(0),
    rasterize_total_ns: std.atomic.Value(u64) = .init(0),
    rasterize_max_ns: std.atomic.Value(u64) = .init(0),

    // Window title (set from core thread, applied on GTK main thread)
    pending_title: [512]u8 = undefined,
    pending_title_len: usize = 0,

    // Clipboard (async GTK ↔ sync core bridge)
    clipboard_mu: std.Thread.Mutex = .{},
    clipboard_cond: std.Thread.Condition = .{},
    clipboard_buf: [65536]u8 = undefined,
    clipboard_len: usize = 0,
    clipboard_result: c_int = 0,
    clipboard_ready: bool = false,
    clipboard_set_data: ?[*]const u8 = null,
    clipboard_set_len: usize = 0,

    /// Scale a logical pixel value by DPI scale factor
    pub fn scalePx(self: *const App, v: u32) i32 {
        return @intFromFloat(@as(f32, @floatFromInt(v)) * self.dpi_scale);
    }
};

// =========================================================================
// Cmdline helper functions (matching Windows frontend)
// =========================================================================

/// Adjust brightness for cmdline background: darken if light, lighten if dark.
pub fn adjustBrightnessForCmdline(r: f32, g: f32, b: f32) [3]f32 {
    const max_c = @max(r, @max(g, b));
    const min_c = @min(r, @min(g, b));
    const delta = max_c - min_c;

    var brightness = max_c;
    var saturation: f32 = 0.0;
    if (max_c > 0) saturation = delta / max_c;

    var hue: f32 = 0.0;
    if (delta > 0) {
        if (max_c == r) {
            hue = (g - b) / delta;
            if (hue < 0) hue += 6.0;
        } else if (max_c == g) {
            hue = 2.0 + (b - r) / delta;
        } else {
            hue = 4.0 + (r - g) / delta;
        }
        hue /= 6.0;
    }

    if (brightness < 0.5) {
        brightness = @min(brightness + 0.05, 1.0);
    } else {
        brightness = @max(brightness - 0.05, 0.0);
    }

    if (saturation == 0) return .{ brightness, brightness, brightness };

    const h_sector = hue * 6.0;
    const sector = @as(u32, @intFromFloat(h_sector)) % 6;
    const f = h_sector - @as(f32, @floatFromInt(sector));
    const p = brightness * (1.0 - saturation);
    const q = brightness * (1.0 - saturation * f);
    const t = brightness * (1.0 - saturation * (1.0 - f));

    return switch (sector) {
        0 => .{ brightness, t, p },
        1 => .{ q, brightness, p },
        2 => .{ p, brightness, t },
        3 => .{ p, q, brightness },
        4 => .{ t, p, brightness },
        else => .{ brightness, p, q },
    };
}

/// Add rectangle vertices (2 triangles = 6 vertices)
pub fn addRectVerts(
    verts: []Vertex,
    start_idx: usize,
    x: f32,
    y: f32,
    w: f32,
    h: f32,
    color: [4]f32,
    tex: [2]f32,
    grid_id: i64,
) usize {
    const positions = [_][2]f32{
        .{ x, y }, .{ x + w, y }, .{ x + w, y - h },
        .{ x, y }, .{ x + w, y - h }, .{ x, y - h },
    };

    var idx = start_idx;
    for (positions) |pos| {
        verts[idx] = .{
            .position = pos,
            .texCoord = tex,
            .color = color,
            .grid_id = grid_id,
            .deco_flags = 0,
            .deco_phase = 0,
        };
        idx += 1;
    }
    return idx;
}

/// Add search icon (magnifying glass) vertices using SDF (12 vertices)
pub fn addSearchIconVerts(
    verts: []Vertex,
    start_idx: usize,
    x: f32,
    y: f32,
    w: f32,
    h: f32,
    color: [4]f32,
    grid_id: i64,
) usize {
    const margin = 0.15;
    const safe_x = x + w * margin;
    const safe_y = y - h * margin;
    const safe_w = w * (1.0 - 2.0 * margin);
    const safe_h = h * (1.0 - 2.0 * margin);

    var idx = start_idx;

    const quad_positions = [_][2]f32{
        .{ safe_x, safe_y },
        .{ safe_x + safe_w, safe_y },
        .{ safe_x, safe_y - safe_h },
        .{ safe_x + safe_w, safe_y },
        .{ safe_x + safe_w, safe_y - safe_h },
        .{ safe_x, safe_y - safe_h },
    };
    const local_uvs = [_][2]f32{
        .{ 0.0, 0.0 },
        .{ 1.0, 0.0 },
        .{ 0.0, 1.0 },
        .{ 1.0, 0.0 },
        .{ 1.0, 1.0 },
        .{ 0.0, 1.0 },
    };

    // Circle quad (uv.x = -2.0)
    for (quad_positions, local_uvs) |pos, luv| {
        verts[idx] = .{
            .position = pos,
            .texCoord = .{ -2.0, luv[0] },
            .color = color,
            .grid_id = grid_id,
            .deco_flags = 0,
            .deco_phase = luv[1],
        };
        idx += 1;
    }

    // Handle quad (uv.x = -4.0)
    for (quad_positions, local_uvs) |pos, luv| {
        verts[idx] = .{
            .position = pos,
            .texCoord = .{ -4.0, luv[0] },
            .color = color,
            .grid_id = grid_id,
            .deco_flags = 0,
            .deco_phase = luv[1],
        };
        idx += 1;
    }

    return idx;
}

/// Add chevron right icon (>) vertices using SDF (6 vertices)
pub fn addChevronIconVerts(
    verts: []Vertex,
    start_idx: usize,
    x: f32,
    y: f32,
    w: f32,
    h: f32,
    color: [4]f32,
    grid_id: i64,
) usize {
    const margin = 0.18;
    const safe_x = x + w * margin;
    const safe_y = y - h * margin;
    const safe_w = w * (1.0 - 2.0 * margin);
    const safe_h = h * (1.0 - 2.0 * margin);

    var idx = start_idx;

    const positions = [_][2]f32{
        .{ safe_x, safe_y },
        .{ safe_x + safe_w, safe_y },
        .{ safe_x, safe_y - safe_h },
        .{ safe_x + safe_w, safe_y },
        .{ safe_x + safe_w, safe_y - safe_h },
        .{ safe_x, safe_y - safe_h },
    };
    const local_uvs = [_][2]f32{
        .{ 0.0, 0.0 },
        .{ 1.0, 0.0 },
        .{ 0.0, 1.0 },
        .{ 1.0, 0.0 },
        .{ 1.0, 1.0 },
        .{ 0.0, 1.0 },
    };

    for (positions, local_uvs) |pos, luv| {
        verts[idx] = .{
            .position = pos,
            .texCoord = .{ -3.0, luv[0] },
            .color = color,
            .grid_id = grid_id,
            .deco_flags = 0,
            .deco_phase = luv[1],
        };
        idx += 1;
    }

    return idx;
}
