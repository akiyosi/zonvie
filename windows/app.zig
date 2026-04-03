// app.zig — Central application state and type definitions.
//
// All types that appear as App fields, and all cross-cutting constants,
// are defined here to avoid circular imports between sub-modules.

const std = @import("std");
const core = @import("zonvie_core");
pub const d3d11 = @import("renderer/d3d11_renderer.zig");
pub const dwrite_d2d = @import("renderer/dwrite_d2d_renderer.zig");
pub const c = @import("win32.zig").c;
pub const applog = @import("app_log.zig");
const builtin = @import("builtin");
pub const config_mod = @import("config.zig");

// Re-export core types used across modules
pub const Vertex = core.Vertex;
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
// Custom window messages (WM_APP + N)
// =========================================================================

pub const WM_APP_ATLAS_ENSURE_GLYPH: c.UINT = c.WM_APP + 1;
pub const WM_APP_CREATE_EXTERNAL_WINDOW: c.UINT = c.WM_APP + 2;
pub const WM_APP_CURSOR_GRID_CHANGED: c.UINT = c.WM_APP + 3;
pub const WM_APP_CLOSE_EXTERNAL_WINDOW: c.UINT = c.WM_APP + 4;
pub const WM_APP_DEFERRED_INIT: c.UINT = c.WM_APP + 5;
pub const WM_APP_UPDATE_IME_POSITION: c.UINT = c.WM_APP + 6;
pub const WM_APP_MSG_SHOW: c.UINT = c.WM_APP + 7;
pub const WM_APP_MSG_CLEAR: c.UINT = c.WM_APP + 8;
pub const WM_APP_MINI_UPDATE: c.UINT = c.WM_APP + 9;
pub const WM_APP_CLIPBOARD_GET: c.UINT = c.WM_APP + 10;
pub const WM_APP_CLIPBOARD_SET: c.UINT = c.WM_APP + 11;
pub const WM_APP_SSH_AUTH_PROMPT: c.UINT = c.WM_APP + 12;
pub const WM_APP_UPDATE_SCROLLBAR: c.UINT = c.WM_APP + 13;
pub const WM_APP_UPDATE_EXT_FLOAT_POS: c.UINT = c.WM_APP + 14;
pub const WM_APP_TRAY: c.UINT = c.WM_APP + 15;
pub const WM_APP_UPDATE_CURSOR_BLINK: c.UINT = c.WM_APP + 16;
pub const WM_APP_IME_OFF: c.UINT = c.WM_APP + 17;
pub const WM_APP_TABLINE_INVALIDATE: c.UINT = c.WM_APP + 18;
pub const WM_APP_QUIT_REQUESTED: c.UINT = c.WM_APP + 19;
pub const WM_APP_QUIT_TIMEOUT: c.UINT = c.WM_APP + 20;
pub const WM_APP_RESIZE_POPUPMENU: c.UINT = c.WM_APP + 21;
pub const WM_APP_UPDATE_CMDLINE_COLORS: c.UINT = c.WM_APP + 22;
pub const WM_APP_SET_TITLE: c.UINT = c.WM_APP + 23;
pub const WM_APP_DEFERRED_WIN_POS: c.UINT = c.WM_APP + 24;

// =========================================================================
// Timer IDs and timing constants
// =========================================================================

/// Timer ID for message window auto-hide
pub const TIMER_MSG_AUTOHIDE: c.UINT_PTR = 1;
/// Timer ID for mini window auto-hide
pub const TIMER_MINI_AUTOHIDE: c.UINT_PTR = 10;
/// Message auto-hide timeout in milliseconds (4 seconds)
pub const MSG_AUTOHIDE_TIMEOUT: c.UINT = 4000;
/// Timer ID for devcontainer polling
pub const TIMER_DEVCONTAINER_POLL: c.UINT_PTR = 2;
/// Devcontainer poll interval in milliseconds (500ms)
pub const DEVCONTAINER_POLL_INTERVAL: c.UINT = 500;
/// Timer ID for scrollbar auto-hide
pub const TIMER_SCROLLBAR_AUTOHIDE: c.UINT_PTR = 3;
/// Timer ID for scrollbar fade animation
pub const TIMER_SCROLLBAR_FADE: c.UINT_PTR = 4;
/// Timer ID for scrollbar track repeat (continuous page scroll when holding)
pub const TIMER_SCROLLBAR_REPEAT: c.UINT_PTR = 5;
/// Timer ID for cursor blink
pub const TIMER_CURSOR_BLINK: c.UINT_PTR = 6;
/// Timer ID for quit request timeout
pub const TIMER_QUIT_TIMEOUT: c.UINT_PTR = 7;
/// Timer ID for coalescing float/mini repositioning during window drag
pub const TIMER_REPOSITION_FLOATS: c.UINT_PTR = 8;
/// Quit timeout in milliseconds (5 seconds)
pub const QUIT_TIMEOUT_MS: c.UINT = 5000;
/// Scrollbar fade animation interval (16ms ~= 60fps)
pub const SCROLLBAR_FADE_INTERVAL: c.UINT = 16;
/// Scrollbar repeat interval (ms) for continuous page scroll
pub const SCROLLBAR_REPEAT_DELAY: c.UINT = 400; // Initial delay before repeat
pub const SCROLLBAR_REPEAT_INTERVAL: c.UINT = 100; // Interval during repeat
/// Custom scrollbar constants (logical pixels, multiply by dpi_scale for device pixels)
pub const SCROLLBAR_WIDTH: f32 = 12.0;
pub const SCROLLBAR_MARGIN: f32 = 2.0;
pub const SCROLLBAR_MIN_KNOB_HEIGHT: f32 = 20.0;
pub const SCROLLBAR_CORNER_RADIUS: f32 = 4.0;

/// DPI-scaled scrollbar dimensions
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
// Cmdline / message styling constants
// =========================================================================

// --- Cmdline window styling constants (matching macOS) ---
pub const CMDLINE_PADDING: u32 = 12; // Padding around content (pixels)
pub const CMDLINE_ICON_SIZE: u32 = 18; // Icon size (pixels)
pub const CMDLINE_ICON_MARGIN_LEFT: u32 = 2; // Left margin for icon (pixels)
pub const CMDLINE_ICON_MARGIN_RIGHT: u32 = 4; // Right margin for icon (pixels)
pub const CMDLINE_BORDER_WIDTH: u32 = 1; // Border width (pixels)
pub const CMDLINE_CORNER_RADIUS: f32 = 8.0; // Corner radius for rounded rect
pub const CMDLINE_SCREEN_MARGIN: u32 = 40; // Margin from screen edges (matching macOS cmdlineScreenMargin)

// --- Msg_show window styling constants ---
pub const MSG_PADDING: u32 = 8; // Padding around content (pixels)

// =========================================================================
// Scrollbar throttle
// =========================================================================

pub const SCROLLBAR_THROTTLE_MS: i64 = 32; // ~30fps for smooth but not excessive updates

// =========================================================================
// Global variables
// =========================================================================

// Global exit code for Nvy-style exit (returned from main instead of ExitProcess)
pub var g_exit_code: std.atomic.Value(u8) = std.atomic.Value(u8).init(0);

// --- Startup timing globals ---
pub var g_startup_freq: c.LARGE_INTEGER = undefined;
pub var g_startup_t0: c.LARGE_INTEGER = undefined;

// =========================================================================
// Type definitions
// =========================================================================

/// Pending external window creation request
pub const PendingExternalWindow = struct {
    grid_id: i64,
    win: i64,
    rows: u32,
    cols: u32,
    start_row: i32, // -1 if no position info (cmdline, etc.)
    start_col: i32,
};

/// CPU-side surface state shared between external windows and pending
/// external vertices. Holds vertex storage, grid dimensions, dirty
/// tracking, and cursor row info. GPU resources (VBs, scratch buffers)
/// remain on the owning window struct.
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

    /// Free CPU-side allocations only. GPU resources (VBs) are owned by the
    /// window struct and must be released separately.
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

/// One frame's worth of CPU-side vertex data (global grid or external window).
/// Three of these rotate inside TripleBufferedSurface.
/// Row data is accessed via row_map → SlotPool indirection (COW shared slots).
pub const VertexSet = struct {
    row_map: std.ArrayListUnmanaged(RowMapping) = .{}, // logical row → physical slot index
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

    /// Release all slots in this set's row_map via pool, then clear the map.
    pub fn releaseAllSlots(self: *VertexSet, alloc: std.mem.Allocator, pool: *SlotPool) void {
        for (self.row_map.items) |*m| {
            if (m.slot != SLOT_NONE) {
                pool.release(alloc, m.slot);
                m.slot = SLOT_NONE;
            }
        }
    }

    /// Recompute total vertex count by summing slot verts.
    pub fn recomputeVertCount(self: *const VertexSet, pool: *const SlotPool) usize {
        var total: usize = 0;
        for (self.row_map.items) |m| {
            if (m.slot != SLOT_NONE) {
                total += pool.slots.items[m.slot].verts.items.len;
            }
        }
        return total;
    }

    /// Free VertexSet-owned arrays. Slot memory is owned by SlotPool.
    /// Caller must releaseAllSlots before calling this.
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
    /// Scroll state bundled with this committed set (consumed atomically).
    scroll_rect: ?c.RECT = null,
    scroll_dy_px: i32 = 0,
    vb_shift: i32 = 0,
};

/// Triple-buffered surface: lock-free vertex handoff from core thread to UI thread.
///
/// Protocol:
///  - Core thread calls beginFlush/commitFlush around vertex generation.
///  - UI thread calls acquireForPaint/releaseFromPaint around WM_PAINT.
///  - rotation_mu protects index rotation and dirty state (short critical sections only).
///  - Vertex data in the write set is accessed lock-free by the core thread during flush.
///  - Vertex data in the committed set is accessed lock-free by the UI thread during paint.
pub const TripleBufferedSurface = struct {
    pub const SET_COUNT = 3;
    sets: [SET_COUNT]VertexSet = .{ .{}, .{}, .{} },
    pool: SlotPool = .{}, // Shared slot pool across all sets

    // --- rotation_mu protects these fields ---
    rotation_mu: std.Thread.Mutex = .{},
    write_index: u8 = 0,
    committed_index: u8 = 1,
    flush_source_index: u8 = 1,
    is_in_flush: bool = false,
    commit_rev: u64 = 0,

    // Per-set UI read refcount (rotation_mu protected).
    // Re-entrant WM_PAINT: DXGIs Present/ResizeBuffers can pump messages,
    // causing same-thread re-entrant WM_PAINT. A simple bool would break
    // when the inner paint releases the outer paints protection.
    ui_read_refcount: [SET_COUNT]u32 = .{ 0, 0, 0 },

    // Dirty state accumulation (rotation_mu protected, WM_PAINT clears).
    pending_dirty: std.DynamicBitSetUnmanaged = .{},
    pending_paint_full: bool = true,

    // Flush-local dirty state (core thread only, no lock needed).
    flush_dirty: std.DynamicBitSetUnmanaged = .{},
    flush_paint_full: bool = false,

    // Flush-local scroll state (core thread only, no lock needed).
    // Accumulated by onMainRowScroll / onGridRowScroll during a single flush.
    flush_scroll_rect: ?c.RECT = null,
    flush_scroll_dy_px: i32 = 0,
    flush_vb_shift: i32 = 0,

    // Pending scroll state (rotation_mu protected).
    // Merged from flush_scroll_* at commitFlush, consumed at acquireForPaint.
    pending_scroll_rect: ?c.RECT = null,
    pending_scroll_dy_px: i32 = 0,
    pending_vb_shift: i32 = 0,

    // Paint-time dirty snapshot (rotation_mu protected, persistent, no per-paint alloc).
    paint_dirty_snapshot: std.DynamicBitSetUnmanaged = .{},
    paint_nesting: u32 = 0,

    /// Check if a free set exists (read-only, short lock).
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

    /// Begin a flush cycle. Picks a free write set and shallow-copies slot
    /// mappings from committed (COW — ~130 bytes for 65 rows instead of ~620KB).
    /// Returns false on alloc failure or no free set (caller should abort flush).
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

        // Shallow copy from flush_source to write set.
        if (!self.shallowCopyVertexSet(alloc, wi, ci)) return false;

        // Clear flush-local dirty state.
        if (self.flush_dirty.bit_length > 0) {
            self.flush_dirty.unsetAll();
        }
        self.flush_paint_full = false;

        // Clear flush-local scroll state.
        self.flush_scroll_rect = null;
        self.flush_scroll_dy_px = 0;
        self.flush_vb_shift = 0;

        self.is_in_flush = true;
        return true;
    }

    /// Cancel a flush (reset is_in_flush without committing).
    pub fn cancelFlush(self: *TripleBufferedSurface) void {
        self.is_in_flush = false;
    }

    /// Commit the write set as the new committed set.
    pub fn commitFlush(self: *TripleBufferedSurface, alloc: std.mem.Allocator) void {
        if (!self.is_in_flush) return;

        self.rotation_mu.lock();
        defer self.rotation_mu.unlock();

        // Merge flush_dirty into pending_dirty.
        if (self.flush_dirty.bit_length > 0) {
            if (self.pending_dirty.bit_length != self.flush_dirty.bit_length) {
                // Resize pending_dirty to match flush_dirty.
                self.pending_dirty.resize(alloc, self.flush_dirty.bit_length, false) catch {
                    self.pending_paint_full = true;
                    self.flush_dirty.unsetAll();
                    self.committed_index = self.write_index;
                    self.commit_rev +%= 1;
                    self.is_in_flush = false;
                    return;
                };
                // Resize paint_dirty_snapshot if no paint is active.
                if (self.paint_nesting == 0) {
                    self.paint_dirty_snapshot.resize(alloc, self.flush_dirty.bit_length, false) catch {
                        self.pending_paint_full = true;
                    };
                }
                // else: deferred to next acquireForPaint when nesting=0
            }

            // Bitwise OR merge: pending_dirty |= flush_dirty
            if (self.pending_dirty.bit_length == self.flush_dirty.bit_length) {
                self.mergeDirtyBits();
            } else {
                // Length mismatch after resize attempt — fall back to full paint.
                self.pending_paint_full = true;
            }
        }

        if (self.flush_paint_full) {
            self.pending_paint_full = true;
        }

        // Merge flush scroll state into pending scroll (same region = accumulate, different = invalidate).
        if (self.flush_scroll_rect) |flush_rect| {
            if (self.pending_scroll_rect) |pending_rect| {
                if (pending_rect.left == flush_rect.left and pending_rect.right == flush_rect.right and
                    pending_rect.top == flush_rect.top and pending_rect.bottom == flush_rect.bottom)
                {
                    self.pending_scroll_dy_px += self.flush_scroll_dy_px;
                    self.pending_vb_shift += self.flush_vb_shift;
                } else {
                    // Different scroll region: invalidate optimization, fall back to full paint.
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

    /// Get the current write set (core thread, during flush only).
    pub fn writeSet(self: *TripleBufferedSurface) *VertexSet {
        return &self.sets[self.write_index];
    }

    /// Acquire the committed set for painting. Returns snapshot info.
    /// Caller must call releaseFromPaint when done.
    pub fn acquireForPaint(self: *TripleBufferedSurface) PaintSnapshot {
        self.rotation_mu.lock();
        defer self.rotation_mu.unlock();

        const ci = self.committed_index;
        self.ui_read_refcount[ci] += 1;

        var paint_full: bool = false;

        if (self.paint_nesting == 0) {
            // Outermost paint: snapshot dirty state.
            if (self.paint_dirty_snapshot.bit_length != self.pending_dirty.bit_length) {
                // Size mismatch — fall back to full paint, clear pending.
                self.pending_paint_full = true;
                self.pending_dirty.unsetAll();
            } else if (self.pending_dirty.bit_length > 0) {
                // Copy pending_dirty → paint_dirty_snapshot (memcpy of backing words).
                self.copyDirtySnapshot();
                self.pending_dirty.unsetAll();
            }
            paint_full = self.pending_paint_full;
            self.pending_paint_full = false;
        }
        // Re-entrant paint: do not overwrite snapshot. paint_full=false → inner paint is no-op.

        // Consume pending scroll state atomically with committed index.
        var scroll_rect: ?c.RECT = null;
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

    /// Release the committed set after painting. Returns true if
    /// InvalidateRect is needed (pending dirty accumulated during paint).
    pub fn releaseFromPaint(self: *TripleBufferedSurface, index: u8) bool {
        self.rotation_mu.lock();
        defer self.rotation_mu.unlock();
        self.ui_read_refcount[index] -= 1;
        self.paint_nesting -= 1;
        // When nesting returns to 0, check if new dirty state accumulated.
        const needs_reinvalidate = (self.paint_nesting == 0) and
            (self.pending_dirty.count() > 0 or self.pending_paint_full);
        return needs_reinvalidate;
    }

    // --- Internal helpers ---

    /// Compute the number of mask words for a given bit_length.
    fn numMasks(bit_length: usize) usize {
        return (bit_length + (@bitSizeOf(usize) - 1)) / @bitSizeOf(usize);
    }

    /// Shallow-copy slot mappings from src set to dst set (COW).
    /// Only copies the u16 row_map array + retains slots. ~130 bytes for 65 rows.
    /// Returns false on alloc failure.
    fn shallowCopyVertexSet(self: *TripleBufferedSurface, alloc: std.mem.Allocator, dst_idx: u8, src_idx: u8) bool {
        const dst = &self.sets[dst_idx];
        const src = &self.sets[src_idx];

        // Release dst's old slot references first.
        dst.releaseAllSlots(alloc, &self.pool);

        // Copy scalar fields (no alloc).
        dst.row_mode = src.row_mode;
        dst.rows = src.rows;
        dst.cols = src.cols;
        dst.last_cursor_row = src.last_cursor_row;

        // Shallow copy row_map (u16 array).
        const src_len = src.row_map.items.len;
        dst.row_map.resize(alloc, src_len) catch return false;
        @memcpy(dst.row_map.items[0..src_len], src.row_map.items[0..src_len]);

        // Retain all slot references for dst.
        for (dst.row_map.items) |m| {
            self.pool.retain(m.slot);
        }

        // Cursor verts: always full copy (small, ~6-12 verts).
        dst.cursor_verts.clearRetainingCapacity();
        dst.cursor_verts.appendSlice(alloc, src.cursor_verts.items) catch return false;

        // Flat verts: always full copy (non-row-mode only).
        dst.flat_verts.clearRetainingCapacity();
        dst.flat_verts.appendSlice(alloc, src.flat_verts.items) catch return false;

        return true;
    }

    /// COW detach: prepare a slot for exclusive write access.
    /// If ref_count > 1, allocate a new slot and release the old one.
    /// Returns a pointer to the exclusively-owned RowSlot, or null on OOM.
    pub fn cowDetachRow(self: *TripleBufferedSurface, alloc: std.mem.Allocator, row: u32) ?*RowSlot {
        const vs = self.writeSet();
        if (row >= vs.row_map.items.len) return null;
        const mapping = &vs.row_map.items[row];
        const old_slot = mapping.slot;

        if (old_slot == SLOT_NONE) {
            // New slot needed.
            const new_idx = self.pool.acquireSlot(alloc) orelse return null;
            mapping.slot = new_idx;
            self.pool.retain(new_idx);
            return &self.pool.slots.items[new_idx];
        }

        if (self.pool.slots.items[old_slot].ref_count > 1) {
            // COW: allocate new slot, release old.
            const new_idx = self.pool.acquireSlot(alloc) orelse return null;
            self.pool.release(alloc, old_slot);
            mapping.slot = new_idx;
            self.pool.retain(new_idx);
            return &self.pool.slots.items[new_idx];
        }

        // Exclusive ownership — write in place.
        return &self.pool.slots.items[old_slot];
    }

    /// OR-merge flush_dirty into pending_dirty (same bit_length assumed).
    fn mergeDirtyBits(self: *TripleBufferedSurface) void {
        const pd_n = numMasks(self.pending_dirty.bit_length);
        const fd_n = numMasks(self.flush_dirty.bit_length);
        if (pd_n == 0 or fd_n == 0) return;
        const len = @min(pd_n, fd_n);
        for (0..len) |i| {
            self.pending_dirty.masks[i] |= self.flush_dirty.masks[i];
        }
    }

    /// Copy pending_dirty bits to paint_dirty_snapshot (same bit_length assumed).
    fn copyDirtySnapshot(self: *TripleBufferedSurface) void {
        const dst_n = numMasks(self.paint_dirty_snapshot.bit_length);
        const src_n = numMasks(self.pending_dirty.bit_length);
        if (dst_n == 0 or src_n == 0) return;
        const len = @min(dst_n, src_n);
        for (0..len) |i| {
            self.paint_dirty_snapshot.masks[i] = self.pending_dirty.masks[i];
        }
        // Clear any trailing words in dst.
        if (dst_n > len) {
            for (len..dst_n) |i| {
                self.paint_dirty_snapshot.masks[i] = 0;
            }
        }
    }

    /// Free all resources.
    pub fn deinit(self: *TripleBufferedSurface, alloc: std.mem.Allocator) void {
        // Release all slot references from each set.
        for (&self.sets) |*set| {
            set.releaseAllSlots(alloc, &self.pool);
            set.deinitCpu(alloc);
        }
        // Free slot pool (vertex memory lives in slots).
        self.pool.deinit(alloc);
        self.pending_dirty.deinit(alloc);
        self.flush_dirty.deinit(alloc);
        self.paint_dirty_snapshot.deinit(alloc);
    }
};

/// Pending vertices for an external window that hasn't been created yet.
/// Uses SurfaceState (legacy RowVerts) since TBS is not set up until window creation.
pub const PendingExternalVertices = struct {
    grid_id: i64,
    surface: SurfaceState,

    pub fn deinit(self: *PendingExternalVertices, alloc: std.mem.Allocator) void {
        for (self.surface.row_verts.items) |*rv| {
            if (rv.vb) |vb| _ = vb.lpVtbl.*.Release.?(vb);
        }
        self.surface.deinitCpuState(alloc);
    }
};

/// Tray icon for balloon notifications (OS notification view type)
pub const TrayIcon = struct {
    nid: c.NOTIFYICONDATAW,
    added: bool = false,

    pub fn init(hwnd: c.HWND) TrayIcon {
        var nid: c.NOTIFYICONDATAW = std.mem.zeroes(c.NOTIFYICONDATAW);
        nid.cbSize = @sizeOf(c.NOTIFYICONDATAW);
        nid.hWnd = hwnd;
        nid.uID = 1;
        nid.uFlags = c.NIF_ICON | c.NIF_TIP | c.NIF_MESSAGE;
        nid.uCallbackMessage = WM_APP_TRAY;
        // IDI_APPLICATION = 32512 (0x7F00) - use direct value as MAKEINTRESOURCE macro doesn't translate
        nid.hIcon = c.LoadIconW(null, @ptrFromInt(32512));
        // Set tip text "Zonvie"
        const tip = [_]u16{ 'Z', 'o', 'n', 'v', 'i', 'e', 0 };
        @memcpy(nid.szTip[0..tip.len], &tip);
        return .{ .nid = nid };
    }

    pub fn add(self: *TrayIcon) void {
        if (!self.added) {
            _ = c.Shell_NotifyIconW(c.NIM_ADD, &self.nid);
            self.added = true;
            if (applog.isEnabled()) applog.appLog("[tray] added tray icon\n", .{});
        }
    }

    pub fn remove(self: *TrayIcon) void {
        if (self.added) {
            _ = c.Shell_NotifyIconW(c.NIM_DELETE, &self.nid);
            self.added = false;
            if (applog.isEnabled()) applog.appLog("[tray] removed tray icon\n", .{});
        }
    }

    pub fn showBalloon(self: *TrayIcon, title: []const u8, msg_text: []const u8) void {
        if (!self.added) return;

        self.nid.uFlags = c.NIF_INFO;
        self.nid.dwInfoFlags = c.NIIF_INFO;

        // Copy title to szInfoTitle (max 63 chars + null)
        var title_buf: [64]u16 = undefined;
        const title_len = @min(title.len, 63);
        for (0..title_len) |i| {
            title_buf[i] = title[i];
        }
        title_buf[title_len] = 0;
        @memcpy(self.nid.szInfoTitle[0 .. title_len + 1], title_buf[0 .. title_len + 1]);

        // Copy msg to szInfo (max 255 chars + null)
        var msg_buf: [256]u16 = undefined;
        const msg_len = @min(msg_text.len, 255);
        for (0..msg_len) |i| {
            msg_buf[i] = msg_text[i];
        }
        msg_buf[msg_len] = 0;
        @memcpy(self.nid.szInfo[0 .. msg_len + 1], msg_buf[0 .. msg_len + 1]);

        _ = c.Shell_NotifyIconW(c.NIM_MODIFY, &self.nid);
        if (applog.isEnabled()) applog.appLog("[tray] showBalloon: title='{s}' msg='{s}'\n", .{ title, msg_text });
    }
};

/// Pending message request for ext_messages
pub const PendingMessageRequest = struct {
    text: [8192]u8 = undefined, // Large buffer for long messages (E325 can be 1100+ bytes)
    text_len: usize = 0,
    kind: [32]u8 = undefined,
    kind_len: usize = 0,
    hl_id: u32 = 0, // Primary highlight ID
    replace_last: u32 = 0, // 1 = replace last message
    append: u32 = 0, // 1 = append to last message
    view_type: zonvie_msg_view_type = .ext_float, // Routing result
    timeout: f32 = 4.0, // Timeout in seconds
};

/// Stored message for display stack (keeps track of multiple messages)
pub const DisplayMessage = struct {
    text: [8192]u8 = undefined,
    text_len: usize = 0,
    kind: [32]u8 = undefined,
    kind_len: usize = 0,
    hl_id: u32 = 0,
    view_type: zonvie_msg_view_type = .ext_float,
    timeout: f32 = 4.0,
};

/// Mini window type identifier (for routing)
pub const MiniWindowId = enum(u2) {
    showmode = 0,
    showcmd = 1,
    ruler = 2,
};

/// Mini window state (one per type)
pub const MiniWindowState = struct {
    hwnd: ?c.HWND = null,
    text: [256]u8 = undefined,
    text_len: usize = 0,
};

/// Ext-float window state for ext_messages (uses GDI for simplicity)
pub const MessageWindow = struct {
    hwnd: c.HWND,
    text: [8192]u8 = undefined, // Large buffer for long messages (E325 can be 1100+ bytes)
    text_len: usize = 0,
    kind: [32]u8 = undefined,
    kind_len: usize = 0,
    hl_id: u32 = 0,
    line_count: u32 = 1,
    is_long_mode: bool = false,
    // Saved size/mode for return_prompt (preserve confirm dialog layout)
    saved_width: c_int = 0,
    saved_height: c_int = 0,
    saved_is_long_mode: bool = false,

    pub fn deinit(self: *MessageWindow) void {
        _ = c.DestroyWindow(self.hwnd);
    }

    /// Get text color based on message kind
    pub fn getTextColor(self: *const MessageWindow) c.COLORREF {
        const kind_str = self.kind[0..self.kind_len];
        if (std.mem.eql(u8, kind_str, "emsg") or
            std.mem.eql(u8, kind_str, "echoerr") or
            std.mem.eql(u8, kind_str, "lua_error") or
            std.mem.eql(u8, kind_str, "rpc_error"))
        {
            return c.RGB(255, 102, 102); // Red for errors
        } else if (std.mem.eql(u8, kind_str, "wmsg")) {
            return c.RGB(255, 217, 102); // Yellow for warnings
        } else if (std.mem.eql(u8, kind_str, "confirm") or
            std.mem.eql(u8, kind_str, "confirm_sub") or
            std.mem.eql(u8, kind_str, "return_prompt"))
        {
            return c.RGB(153, 204, 255); // Light blue for prompts
        } else if (std.mem.eql(u8, kind_str, "search_count")) {
            return c.RGB(153, 255, 153); // Light green for search count
        }
        return c.RGB(220, 220, 220); // Default light gray
    }
};

/// Tabline display style
pub const TablineStyle = enum { titlebar, sidebar };

/// Tab entry for ext_tabline
pub const TabEntry = struct {
    handle: i64,
    name: [256]u8 = undefined,
    name_len: usize = 0,
};

/// Tabline state for ext_tabline (Chrome-style tabs in titlebar area)
pub const TablineState = struct {
    tabs: [32]TabEntry = undefined, // Max 32 tabs
    tab_count: usize = 0,
    current_tab: i64 = 0,
    visible: bool = false,
    hovered_tab: ?usize = null,
    hovered_close: ?usize = null,
    hovered_window_btn: ?u8 = null, // 0=min, 1=max, 2=close
    hovered_new_tab_btn: bool = false,
    hwnd: ?c.HWND = null, // Child window for tabline

    // Pending invalidate flag: if tabline_update arrives before hwnd is created,
    // we need to trigger InvalidateRect after hwnd creation
    pending_invalidate: bool = false,

    // Drag state for tab reordering
    dragging_tab: ?usize = null, // Index of tab being dragged
    drag_start_x: c_int = 0, // Mouse X when drag started
    drag_offset_x: c_int = 0, // Offset from tab left edge to mouse
    drag_current_x: c_int = 0, // Current mouse X during drag
    drop_target_index: ?usize = null, // Where the tab would be dropped
    drag_start_y: c_int = 0, // Mouse Y when drag started (sidebar)
    drag_current_y: c_int = 0, // Current mouse Y during drag (sidebar)

    // External drag state (for tab externalization)
    is_external_drag: bool = false,
    drag_preview_hwnd: ?c.HWND = null,

    // Close button pressed state (for proper click handling)
    close_button_pressed: ?usize = null, // Tab index of pressed close button

    // New tab button pressed state (for proper click handling)
    new_tab_button_pressed: bool = false,

    // Window button pressed state (for proper click handling on min/max/close)
    pressed_window_btn: ?u8 = null, // 0=min, 1=max, 2=close

    // Tab bar constants
    pub const TAB_BAR_HEIGHT: c_int = 32;
    pub const TAB_MIN_WIDTH: c_int = 100;
    pub const TAB_MAX_WIDTH: c_int = 200;
    pub const TAB_PADDING: c_int = 8;
    pub const TAB_CLOSE_SIZE: c_int = 14;
    pub const WINDOW_CONTROLS_WIDTH: c_int = 0; // Windows has controls on the right (no left offset needed)
    pub const DRAG_THRESHOLD: c_int = 5; // Pixels to move before starting drag
    pub const EXTERNAL_DRAG_THRESHOLD: c_int = 50; // Pixels outside window to trigger external drag

    // Window control buttons (right side)
    pub const WINDOW_BTN_WIDTH: c_int = 46; // Each button width
    pub const WINDOW_BTN_COUNT: c_int = 3; // Min, Max, Close
    pub const WINDOW_BTNS_TOTAL: c_int = WINDOW_BTN_WIDTH * WINDOW_BTN_COUNT; // 138px total

    // Sidebar mode constants
    pub const SIDEBAR_ROW_HEIGHT: c_int = 28;
    pub const SIDEBAR_PADDING: c_int = 12;
    pub const SIDEBAR_CLOSE_SIZE: c_int = 14;
    pub const SIDEBAR_NEW_TAB_HEIGHT: c_int = 32;
    pub const SIDEBAR_SEPARATOR_WIDTH: c_int = 1;
    pub const SIDEBAR_INDICATOR_WIDTH: c_int = 3;

    pub fn clear(self: *TablineState) void {
        self.tab_count = 0;
        self.current_tab = 0;
        self.visible = false;
    }

    pub fn cancelDrag(self: *TablineState) void {
        self.dragging_tab = null;
        self.drop_target_index = null;
        self.is_external_drag = false;
        self.close_button_pressed = null;
        self.new_tab_button_pressed = false;
        self.pressed_window_btn = null;
        // Also clear hover states
        self.hovered_tab = null;
        self.hovered_close = null;
        self.hovered_window_btn = null;
        self.hovered_new_tab_btn = false;
        // Note: drag_preview_hwnd destruction handled separately by destroyDragPreviewWindow()
    }
};

/// CPU-side per-row vertex data. GPU VBs are stored separately in RowVB
/// (owned by the UI thread) so that the core thread can write vertices
/// without touching GPU resources.
pub const RowVertsCPU = struct {
    verts: std.ArrayListUnmanaged(Vertex) = .{},

    // CPU-side generation increments when verts are replaced by onVerticesRow().
    gen: u64 = 0,

    // Logical row index that vertices were generated for. Used to compute viewport
    // Y translation at draw time when a row moves due to grid_scroll without
    // vertex regeneration (same pattern as macOS rowSlotSourceRows).
    origin_row: u32 = 0,
};

/// GPU-side per-row vertex buffer (D3D11). Owned exclusively by the UI thread.
pub const RowVB = struct {
    vb: ?*c.ID3D11Buffer = null,
    vb_bytes: usize = 0,
    // Slot identity + version for upload detection (replaces uploaded_gen).
    // Upload is needed when uploaded_slot != mapping.slot or uploaded_ver != slot.ver.
    uploaded_slot: u16 = SLOT_NONE,
    uploaded_ver: u64 = 0,
};

// =========================================================================
// Slot-based COW types (slot remapping + reference sharing)
// =========================================================================

/// Sentinel value for "no slot assigned".
pub const SLOT_NONE: u16 = std.math.maxInt(u16);

/// Physical row slot. Ref-counted vertex buffer shared across VertexSets.
pub const RowSlot = struct {
    verts: std.ArrayListUnmanaged(Vertex) = .{},
    ref_count: u16 = 0, // 0=unused, 1=exclusive, 2+=shared
    origin_row: u32 = 0, // Logical row at vertex generation time (viewport Y translation)
    ver: u64 = 0, // Content version (incremented on each write)
};

/// Logical-to-physical row mapping (one per logical row per VertexSet).
pub const RowMapping = struct {
    slot: u16 = SLOT_NONE,
};

/// Pool of physical row slots shared across all VertexSets in a TBS.
pub const SlotPool = struct {
    slots: std.ArrayListUnmanaged(RowSlot) = .{},
    free_list: std.ArrayListUnmanaged(u16) = .{},

    /// Acquire an unused slot. Returns null on OOM.
    pub fn acquireSlot(self: *SlotPool, alloc: std.mem.Allocator) ?u16 {
        if (self.free_list.items.len > 0) {
            return self.free_list.pop();
        }
        // Grow pool by one slot.
        const idx: u16 = @intCast(self.slots.items.len);
        self.slots.append(alloc, .{}) catch return null;
        return idx;
    }

    /// Increment ref_count for a slot.
    pub fn retain(self: *SlotPool, idx: u16) void {
        if (idx == SLOT_NONE) return;
        self.slots.items[idx].ref_count += 1;
    }

    /// Decrement ref_count. If it reaches 0, return slot to free_list.
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

/// Legacy combined struct for backward compatibility during migration.
/// Contains both CPU vertex data and GPU VB resources.
pub const RowVerts = struct {
    verts: std.ArrayListUnmanaged(Vertex) = .{},

    // Row-local GPU VB (D3D11). Kept in App so WM_PAINT can bind per row.
    vb: ?*c.ID3D11Buffer = null,
    vb_bytes: usize = 0,

    // CPU-side generation increments when verts are replaced by onVerticesRow().
    gen: u64 = 0,
    // Last uploaded generation to vb.
    uploaded_gen: u64 = 0,

    // Logical row index that vertices were generated for. Used to compute viewport
    // Y translation at draw time when a row moves due to grid_scroll without
    // vertex regeneration (same pattern as macOS rowSlotSourceRows).
    origin_row: u32 = 0,
};

pub const PaintRowRange = struct {
    start: usize,
    count: usize,
};

/// External window state for win_external_pos grids
pub const ExternalWindow = struct {
    hwnd: c.HWND,
    win_id: i64 = 0, // Neovim window handle
    renderer: d3d11.Renderer,

    // Shared CPU-side surface state (vertices, grid dims, dirty tracking).
    surface: SurfaceState = .{},

    // Triple-buffered surface for lock-free vertex handoff (core → UI thread).
    tbs: TripleBufferedSurface = .{},

    // GPU vertex buffers (not in SurfaceState — ownership/deinit stays here).
    vb: ?*c.ID3D11Buffer = null,
    vb_bytes: usize = 0,
    vert_count: usize = 0,
    needs_redraw: bool = false,
    needs_renderer_resize: bool = false, // Deferred renderer resize (to avoid deadlock)
    needs_window_resize: bool = false, // Deferred window resize (to avoid deadlock with WM_SIZE)
    pending_window_w: c_int = 0, // Pending window width for deferred resize
    pending_window_h: c_int = 0, // Pending window height for deferred resize
    atlas_version: u64 = 0, // Last atlas version uploaded to this window's D3D context
    atlas_upload_cursor: u64 = 0, // Per-window cursor into renderer's pending_uploads queue
    scroll_accum: i16 = 0, // Accumulated vertical scroll delta for high-resolution scrolling
    h_scroll_accum: i16 = 0, // Accumulated horizontal scroll delta
    cached_bg_color: ?[3]f32 = null, // Cached background color for cmdline (persists across redraws)
    cursor_blink_state: bool = true, // Cursor blink state (true = visible)
    flat_draw_scratch: std.ArrayListUnmanaged(Vertex) = .{}, // Scratch buffer for flat-mode drawing (cursor filter + scrollbar)

    // Per-window GPU vertex buffers for cursor and scrollbar overlays (row-mode rendering).
    cursor_vb: ?*c.ID3D11Buffer = null,
    cursor_vb_bytes: usize = 0,
    // Per-row GPU vertex buffers (TBS: uploaded from committed set row_verts).
    row_vbs: std.ArrayListUnmanaged(RowVB) = .{},
    scrollbar_vb: ?*c.ID3D11Buffer = null,
    scrollbar_vb_bytes: usize = 0,

    // When true, suppress tryResizeGrid in WM_SIZE handler (programmatic resize from grid_resize).
    suppress_resize_callback: bool = false,

    // Close state - set when window is scheduled for closing (don't paint or access renderer)
    is_pending_close: bool = false,

    // Paint reference count - prevents freeing while paint is in progress
    // DXGI operations can pump Win32 messages, so close could be triggered during paint.
    // This counter ensures ext_win isn't freed until all paint operations complete.
    paint_ref_count: u32 = 0,

    // Scroll state is now bundled in TBS (flush_scroll_* → pending_scroll_* → PaintSnapshot).
    // See TripleBufferedSurface.
    last_painted_cursor_row: ?u32 = null,

    // Scrollbar state for external windows
    scrollbar_visible: bool = false,
    scrollbar_alpha: f32 = 0.0,
    scrollbar_target_alpha: f32 = 0.0,
    scrollbar_dragging: bool = false,
    scrollbar_drag_start_y: i32 = 0,
    scrollbar_drag_start_topline: i64 = 0,
    scrollbar_repeat_timer: usize = 0,
    scrollbar_repeat_dir: i8 = 0,
    scrollbar_pending_line: i64 = -1,
    scrollbar_pending_use_bottom: bool = false,
    scrollbar_hover: bool = false,
    scrollbar_last_update: i64 = 0, // Timestamp for throttling

    // Scratch buffer for vertex copy during paint (avoids per-frame alloc).
    // Per-window to prevent re-entrancy corruption when DXGI Present pumps messages.
    paint_scratch: std.ArrayListUnmanaged(Vertex) = .{},
    paint_row_ranges: std.ArrayListUnmanaged(PaintRowRange) = .{},

    pub fn recomputeVertCount(self: *ExternalWindow) void {
        self.vert_count = self.surface.recomputeVertCount();
    }

    pub fn deinit(self: *ExternalWindow, alloc: std.mem.Allocator) void {
        // Clear user data first to prevent WndProc from accessing App during destruction
        _ = c.SetWindowLongPtrW(self.hwnd, c.GWLP_USERDATA, 0);

        // Destroy window first (this will process WM_DESTROY etc.)
        _ = c.DestroyWindow(self.hwnd);

        // Now safe to release D3D resources
        self.paint_scratch.deinit(alloc);
        self.paint_row_ranges.deinit(alloc);
        self.flat_draw_scratch.deinit(alloc);
        // Release GPU VBs from row_verts before deinitCpuState frees the list.
        for (self.surface.row_verts.items) |*rv| {
            if (rv.vb) |vb| _ = vb.lpVtbl.*.Release.?(vb);
        }
        self.surface.deinitCpuState(alloc);
        // Release GPU VBs from TBS row_vbs.
        for (self.row_vbs.items) |*rvb| {
            if (rvb.vb) |vb| _ = vb.lpVtbl.*.Release.?(vb);
        }
        self.row_vbs.deinit(alloc);
        self.tbs.deinit(alloc); // Handles slot release + pool deinit
        if (self.vb) |vb| {
            _ = vb.lpVtbl.*.Release.?(vb);
        }
        if (self.cursor_vb) |vb| {
            _ = vb.lpVtbl.*.Release.?(vb);
        }
        if (self.scrollbar_vb) |vb| {
            _ = vb.lpVtbl.*.Release.?(vb);
        }
        self.renderer.deinit();
    }
};

// =========================================================================
// Shared surface helpers (used by both main window and external windows)
// =========================================================================

/// Build a sorted, deduplicated list of row indices to draw.
///
/// When `force_full` is true, enumerates all rows in [0, total_rows).
/// Otherwise uses the provided `dirty_row_keys`.
/// All indices are clamped to [0, max_valid_row) and deduplicated.
pub fn computeRowsToDraw(
    alloc: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(u32),
    force_full: bool,
    dirty_row_keys: []const u32,
    total_rows: u32,
    max_valid_row: u32,
) void {
    out.clearRetainingCapacity();

    const cap = if (force_full) total_rows else @as(u32, @intCast(dirty_row_keys.len));
    out.ensureTotalCapacity(alloc, cap) catch {};

    if (force_full) {
        var r: u32 = 0;
        const n: u32 = @min(total_rows, max_valid_row);
        while (r < n) : (r += 1) {
            out.append(alloc, r) catch break;
        }
        return; // Already in order, no duplicates possible.
    }

    // Dirty-row path: filter to valid range, then sort + dedup.
    for (dirty_row_keys) |k| {
        if (k < max_valid_row) {
            out.append(alloc, k) catch break;
        }
    }

    if (out.items.len <= 1) return;

    std.sort.pdq(u32, out.items, {}, comptime std.sort.asc(u32));

    // Deduplicate in-place.
    var w: usize = 1;
    var i: usize = 1;
    while (i < out.items.len) : (i += 1) {
        if (out.items[i] != out.items[w - 1]) {
            out.items[w] = out.items[i];
            w += 1;
        }
    }
    out.items.len = w;
}

pub fn snapshotSurfaceVerts(
    alloc: std.mem.Allocator,
    scratch: *std.ArrayListUnmanaged(Vertex),
    row_mode: bool,
    row_verts: []const RowVerts,
    flat_verts: []const Vertex,
    vert_count: usize,
) bool {
    scratch.clearRetainingCapacity();
    scratch.ensureTotalCapacity(alloc, vert_count) catch return false;

    if (row_mode) {
        for (row_verts) |rv| {
            if (rv.verts.items.len == 0) continue;
            scratch.appendSliceAssumeCapacity(rv.verts.items);
        }
    } else {
        scratch.appendSliceAssumeCapacity(flat_verts[0..vert_count]);
    }
    return true;
}

pub fn snapshotSurfaceRows(
    alloc: std.mem.Allocator,
    scratch: *std.ArrayListUnmanaged(Vertex),
    row_ranges: *std.ArrayListUnmanaged(PaintRowRange),
    row_mode: bool,
    row_verts: []const RowVerts,
    flat_verts: []const Vertex,
    vert_count: usize,
) bool {
    scratch.clearRetainingCapacity();
    row_ranges.clearRetainingCapacity();
    scratch.ensureTotalCapacity(alloc, vert_count) catch return false;

    if (row_mode) {
        row_ranges.ensureTotalCapacity(alloc, row_verts.len) catch return false;
        var start: usize = 0;
        for (row_verts) |rv| {
            const count = rv.verts.items.len;
            if (count == 0) continue;
            scratch.appendSliceAssumeCapacity(rv.verts.items);
            row_ranges.appendAssumeCapacity(.{ .start = start, .count = count });
            start += count;
        }
    } else {
        scratch.appendSliceAssumeCapacity(flat_verts[0..vert_count]);
    }
    return true;
}

pub fn ensureRowVBReady(
    g: *d3d11.Renderer,
    rv: *RowVerts,
    src: []const Vertex,
) !bool {
    if (src.len == 0) return false;

    if (rv.uploaded_gen != rv.gen or rv.vb == null or rv.vb_bytes < src.len * @sizeOf(Vertex)) {
        const need_bytes = src.len * @sizeOf(Vertex);
        try g.ensureExternalVertexBuffer(&rv.vb, &rv.vb_bytes, need_bytes);
        try g.uploadVertsToVB(rv.vb.?, src);
        rv.uploaded_gen = rv.gen;
        return true;
    }

    return false;
}

/// Upload slot vertex data to a separate RowVB, comparing slot identity + version.
/// Used by TBS-based paint path where CPU verts and GPU VBs are separate arrays.
pub fn ensureRowVBReadyFromSlot(
    g: *d3d11.Renderer,
    vb: *RowVB,
    mapping: RowMapping,
    pool: *const SlotPool,
) !bool {
    if (mapping.slot == SLOT_NONE) return false;
    const slot = &pool.slots.items[mapping.slot];
    const src = slot.verts.items;
    if (src.len == 0) return false;

    if (vb.uploaded_slot != mapping.slot or vb.uploaded_ver != slot.ver or vb.vb == null or vb.vb_bytes < src.len * @sizeOf(Vertex)) {
        const need_bytes = src.len * @sizeOf(Vertex);
        try g.ensureExternalVertexBuffer(&vb.vb, &vb.vb_bytes, need_bytes);
        try g.uploadVertsToVB(vb.vb.?, src);
        vb.uploaded_slot = mapping.slot;
        vb.uploaded_ver = slot.ver;
        return true;
    }

    return false;
}

/// Shift the row_vbs array to match a scroll delta.
/// After scroll up by N (delta > 0): row_vbs[i] = row_vbs[i+N], vacated tail entries reset.
/// After scroll down by N (delta < 0): row_vbs[i] = row_vbs[i-N], vacated head entries reset.
/// This keeps uploaded_slot aligned with row_map so VBs don't need re-upload for shifted rows.
pub fn shiftRowVBs(row_vbs: []RowVB, delta: i32, row_start: u32, row_end: u32) void {
    if (delta == 0) return;
    const start: usize = @intCast(row_start);
    const end: usize = @min(@as(usize, @intCast(row_end)), row_vbs.len);
    if (start >= end) return;
    const region = row_vbs[start..end];
    const abs_delta: usize = @intCast(if (delta < 0) -delta else delta);
    if (abs_delta >= region.len) {
        // Entire region shifted out: reset all.
        for (region) |*vb| {
            vb.uploaded_slot = SLOT_NONE;
            vb.uploaded_ver = 0;
        }
        return;
    }

    if (delta > 0) {
        // Scroll up: row_vbs[start] gets row_vbs[start + abs_delta], etc.
        // Save VBs that scroll off (at the top of the region).
        var saved: [64]RowVB = undefined;
        for (0..abs_delta) |s| {
            saved[s] = region[s];
        }
        var i: usize = 0;
        while (i + abs_delta < region.len) : (i += 1) {
            region[i] = region[i + abs_delta];
        }
        // Vacated tail entries: reuse saved VBs (keep GPU buffer, reset upload state).
        for (0..abs_delta) |s| {
            region[region.len - abs_delta + s] = saved[s];
            region[region.len - abs_delta + s].uploaded_slot = SLOT_NONE;
            region[region.len - abs_delta + s].uploaded_ver = 0;
        }
    } else {
        // Scroll down: row_vbs[end-1] gets row_vbs[end-1-abs_delta], etc.
        var saved: [64]RowVB = undefined;
        for (0..abs_delta) |s| {
            saved[s] = region[region.len - 1 - s];
        }
        var i: usize = region.len;
        while (i > abs_delta) {
            i -= 1;
            region[i] = region[i - abs_delta];
        }
        // Vacated head entries: reuse saved VBs.
        for (0..abs_delta) |s| {
            region[start + s] = saved[s];
            region[start + s].uploaded_slot = SLOT_NONE;
            region[start + s].uploaded_ver = 0;
        }
    }
}

/// Scroll state consumed by paint. Returned by consumeScrollState / applyScrollShift.
pub const ScrollShiftResult = struct {
    /// The scroll region rect (in back_tex coords). null if no scroll was applied.
    scroll_rect: ?c.RECT = null,
};

/// Apply scroll pixel shift to back_tex, shift row_vbs, and add cursor ghost
/// rows to rows_to_draw.  Shared between main window and external windows.
///
/// Parameters:
///   g:                   Renderer owning back_tex
///   alloc:               Allocator for rows_to_draw appends
///   row_vbs:             GPU VB tracking array to shift
///   rows_to_draw:        Dirty row list (modified: cursor ghost rows appended)
///   scroll_rect:         Scroll region in row-relative pixels (`.right` = 0 means "fill with renderer width")
///   scroll_dy_px:        Pixel shift amount (negative = content moves up, positive = down)
///   vb_shift_rows:       Row-unit shift for row_vbs (same sign convention as grid_scroll rows_delta)
///   last_cursor_row_ptr: Pointer to last painted cursor row tracker (read + cleared)
///   row_h_px:            Row height in pixels
///   effective_rows:      Total valid row count
///   y_offset:            Content Y offset in back_tex pixels (e.g. tabbar height). 0 for ext windows.
pub fn applyScrollShift(
    g: *d3d11.Renderer,
    alloc: std.mem.Allocator,
    row_vbs: []RowVB,
    rows_to_draw: *std.ArrayListUnmanaged(u32),
    scroll_rect: c.RECT,
    scroll_dy_px: i32,
    vb_shift_rows: i32,
    last_cursor_row_ptr: *?u32,
    row_h_px: i32,
    effective_rows: u32,
    y_offset: i32,
) ScrollShiftResult {
    if (scroll_dy_px == 0) return .{};

    // 1. Shift row_vbs to keep VB upload state aligned with row_map.
    if (vb_shift_rows != 0) {
        shiftRowVBs(row_vbs, vb_shift_rows, 0, @intCast(row_vbs.len));
    }

    // 2. Cursor ghost erasure: add previous cursor row (shifted + original) to rows_to_draw.
    if (last_cursor_row_ptr.*) |prev_cr| {
        if (row_h_px > 0) {
            const scroll_rows: i32 = @divTrunc(scroll_dy_px, row_h_px);
            const shifted_row: i32 = @as(i32, @intCast(prev_cr)) + scroll_rows;
            if (shifted_row >= 0 and shifted_row < @as(i32, @intCast(effective_rows))) {
                const sr_u32: u32 = @intCast(shifted_row);
                appendRowSorted(alloc, rows_to_draw, sr_u32);
            }
            if (prev_cr < effective_rows) {
                appendRowSorted(alloc, rows_to_draw, prev_cr);
            }
        }
    }
    last_cursor_row_ptr.* = null;

    // 3. Fill in scroll rect and apply pixel shift on back_tex.
    var filled = scroll_rect;
    if (filled.right == 0) {
        filled.right = @intCast(g.width);
    }
    filled.top += y_offset;
    filled.bottom += y_offset;

    g.scrollBackTex(filled, scroll_dy_px);

    // 4. When multiple scroll flushes accumulate before a paint, the back buffer
    //    shift leaves gap rows with stale pixels.  The per-flush dirty bitmap
    //    only covers each flush's own vacated rows, but the accumulated shift
    //    exposes abs(vb_shift_rows) rows that scrollBackTex could not fill from
    //    valid source pixels.  Add those gap rows to rows_to_draw so they are
    //    redrawn from the current slot data.
    if (row_h_px > 0) {
        const abs_shift: u32 = @intCast(if (vb_shift_rows < 0) -vb_shift_rows else vb_shift_rows);
        if (abs_shift > 1) {
            const region_top_row: u32 = @intCast(@divTrunc(filled.top - y_offset, row_h_px));
            const region_bot_row: u32 = @intCast(@divTrunc(filled.bottom - y_offset, row_h_px));
            const region_height: u32 = region_bot_row - region_top_row;

            if (abs_shift >= region_height) {
                // Accumulated shift covers the entire scroll region; scrollBackTex
                // early-returned without copying anything.  Redraw every row in
                // the region instead of computing a gap.
                mergeContiguousRows(alloc, rows_to_draw, region_top_row, @min(region_bot_row, effective_rows));
            } else if (vb_shift_rows > 0) {
                // Scroll up (j-key): gap rows at bottom of scroll region.
                // Gap rows form a contiguous range; merge them into the sorted
                // rows_to_draw list in one pass to avoid repeated O(n) scans in
                // appendRowSorted.
                const gap_start: u32 = region_bot_row - abs_shift;
                const gap_end: u32 = @min(region_bot_row, effective_rows);
                mergeContiguousRows(alloc, rows_to_draw, gap_start, gap_end);
            } else {
                // Scroll down (k-key): gap rows at top of scroll region.
                const gap_end: u32 = @min(region_top_row + abs_shift, effective_rows);
                mergeContiguousRows(alloc, rows_to_draw, region_top_row, gap_end);
            }
        }
    }

    if (applog.isEnabled()) {
        applog.appLog(
            "[perf] applyScrollShift dy={d} vb_shift={d} rect=({d},{d},{d},{d})\n",
            .{ scroll_dy_px, vb_shift_rows, filled.left, filled.top, filled.right, filled.bottom },
        );
    }

    return .{ .scroll_rect = filled };
}

/// Insert a row into a sorted rows_to_draw list if not already present.
fn appendRowSorted(alloc: std.mem.Allocator, list: *std.ArrayListUnmanaged(u32), row: u32) void {
    for (list.items) |r| {
        if (r == row) return;
    }
    list.append(alloc, row) catch return;
    std.sort.insertion(u32, list.items, {}, std.sort.asc(u32));
}

/// Merge a contiguous range [start, end) into a sorted rows_to_draw list,
/// skipping rows already present.  Avoids per-row insertion sort by
/// appending new rows and re-sorting once.
fn mergeContiguousRows(alloc: std.mem.Allocator, list: *std.ArrayListUnmanaged(u32), start: u32, end: u32) void {
    if (start >= end) return;
    var added: u32 = 0;
    var r: u32 = start;
    while (r < end) : (r += 1) {
        var found = false;
        for (list.items) |existing| {
            if (existing == r) {
                found = true;
                break;
            }
        }
        if (!found) {
            list.append(alloc, r) catch return;
            added += 1;
        }
    }
    if (added > 0) {
        std.sort.insertion(u32, list.items, {}, std.sort.asc(u32));
    }
}

/// Draw rows from slot-based row_map with separate RowVB GPU buffers.
/// This is the TBS-equivalent of drawSurfaceRowsVB.
pub fn drawSurfaceRowsVBFromSlots(
    g: *d3d11.Renderer,
    row_map: []const RowMapping,
    pool: *const SlotPool,
    row_vbs: []RowVB,
    rows_to_draw: ?[]const u32,
    ctx_ptr: ?*c.ID3D11DeviceContext,
    rs_set_sc_fn: ?RSSetScissorRectsFn,
    rs_set_vp_fn: ?RSSetViewportsFn,
    base_vp: BaseViewport,
    x_offset: i32,
    y_offset: i32,
    content_right: i32,
    row_h_px: i32,
    log_enabled: bool,
    metrics: *SurfaceRowDrawMetrics,
) void {
    const row_count: usize = if (rows_to_draw) |rows| rows.len else row_map.len;
    var vp_dirty = false;
    var i: usize = 0;
    while (i < row_count) : (i += 1) {
        const row: u32 = if (rows_to_draw) |rows| rows[i] else @intCast(i);
        if (row >= row_map.len or row >= row_vbs.len) {
            metrics.skipped_empty += 1;
            continue;
        }

        const mapping = row_map[@intCast(row)];
        if (mapping.slot == SLOT_NONE) {
            metrics.skipped_empty += 1;
            if (metrics.first_empty_row == null) {
                metrics.first_empty_row = row;
            }
            continue;
        }

        const slot = &pool.slots.items[mapping.slot];
        const src = slot.verts.items;
        if (src.len == 0) {
            metrics.skipped_empty += 1;
            if (metrics.first_empty_row == null) {
                metrics.first_empty_row = row;
            }
            continue;
        }

        const vb = &row_vbs[@intCast(row)];
        if (vb.uploaded_slot != mapping.slot or vb.uploaded_ver != slot.ver or vb.vb == null or vb.vb_bytes < src.len * @sizeOf(Vertex)) {
            const need_bytes = src.len * @sizeOf(Vertex);
            const t_upload_start = if (log_enabled) std.time.nanoTimestamp() else 0;
            _ = ensureRowVBReadyFromSlot(g, vb, mapping, pool) catch {
                metrics.skipped_empty += 1;
                continue;
            };
            if (log_enabled) {
                metrics.vb_upload_ns += std.time.nanoTimestamp() - t_upload_start;
            }
            metrics.vb_upload_rows += 1;
            metrics.vb_upload_rows_bytes += @as(u64, @intCast(need_bytes));
        }

        if (ctx_ptr != null and rs_set_sc_fn != null and row_h_px > 0) {
            const top = y_offset + @as(i32, @intCast(row)) * row_h_px;
            const bottom = top + row_h_px;
            var sc: c.D3D11_RECT = .{
                .left = x_offset,
                .top = top,
                .right = content_right,
                .bottom = bottom,
            };
            rs_set_sc_fn.?(ctx_ptr, 1, &sc);

            if (rs_set_vp_fn) |vp_fn| {
                const origin_i32: i32 = @intCast(slot.origin_row);
                const row_i32: i32 = @intCast(row);
                const row_delta = row_i32 - origin_i32;
                if (row_delta != 0) {
                    const delta_px: f32 = @floatFromInt(row_delta * row_h_px);
                    var vp: c.D3D11_VIEWPORT = .{
                        .TopLeftX = base_vp.x,
                        .TopLeftY = base_vp.y + delta_px,
                        .Width = base_vp.w,
                        .Height = base_vp.h,
                        .MinDepth = 0,
                        .MaxDepth = 1,
                    };
                    vp_fn(ctx_ptr, 1, &vp);
                    vp_dirty = true;
                } else if (vp_dirty) {
                    var vp: c.D3D11_VIEWPORT = .{
                        .TopLeftX = base_vp.x,
                        .TopLeftY = base_vp.y,
                        .Width = base_vp.w,
                        .Height = base_vp.h,
                        .MinDepth = 0,
                        .MaxDepth = 1,
                    };
                    vp_fn(ctx_ptr, 1, &vp);
                    vp_dirty = false;
                }
            }
        }

        const t_draw_start = if (log_enabled) std.time.nanoTimestamp() else 0;
        g.drawVB(vb.vb.?, src.len) catch {
            metrics.skipped_empty += 1;
            continue;
        };
        if (log_enabled) {
            metrics.draw_vb_ns += std.time.nanoTimestamp() - t_draw_start;
        }
        metrics.drawn_rows += 1;
    }

    // Restore base viewport if modified.
    if (vp_dirty) {
        if (rs_set_vp_fn) |vp_fn| {
            var vp: c.D3D11_VIEWPORT = .{
                .TopLeftX = base_vp.x,
                .TopLeftY = base_vp.y,
                .Width = base_vp.w,
                .Height = base_vp.h,
                .MinDepth = 0,
                .MaxDepth = 1,
            };
            vp_fn(ctx_ptr, 1, &vp);
        }
    }
}

/// Shared row-mode rendering with TBS (slot-based COW + separate RowVB array).
/// Same as drawRowModeSetupAndRows but uses slot indirection for zero-copy beginFlush.
/// Does NOT hold app_mu during VB upload (lock-free via TBS refcount).
pub fn drawRowModeSetupAndRowsFromSlots(
    g: *d3d11.Renderer,
    alloc: std.mem.Allocator,
    row_map: []const RowMapping,
    pool: *const SlotPool,
    row_vbs: []RowVB,
    rows_to_draw: []const u32,
    bloom_verts: *std.ArrayListUnmanaged(Vertex),
    params: RowModeDrawParams,
) !RowModeDrawResult {
    const log_enabled = applog.isEnabled();

    // 1. drawEx: bind RTV, clear if needed, set viewport to content_height.
    try g.drawEx(
        &[_]Vertex{},
        &[_]Vertex{},
        null,
        .{
            .present = false,
            .preserve_on_null_dirty = params.preserve_back,
            .content_height = params.content_height,
            .content_width = params.content_width,
            .content_y_offset = params.content_y_offset,
            .content_x_offset = params.content_x_offset,
            .sidebar_right_width = params.sidebar_right_width,
            .tabbar_bg_color = params.tabbar_bg_color,
        },
    );

    // 2. Get D3D context and function pointers.
    var result = RowModeDrawResult{};
    var rs_set_vp_fn: ?RSSetViewportsFn = null;
    if (g.ctx) |ctx_val| {
        result.ctx_ptr = ctx_val;
        result.rs_set_sc_fn = ctx_val.*.lpVtbl.*.RSSetScissorRects;
        rs_set_vp_fn = ctx_val.*.lpVtbl.*.RSSetViewports;
    }

    const vp_x_offset = params.content_x_offset orelse 0;
    const vp_y_offset = params.content_y_offset orelse 0;
    const sidebar_r_w = params.sidebar_right_width orelse 0;
    const base_w = params.content_width orelse g.width;
    const vp_width = if (base_w > vp_x_offset + sidebar_r_w) base_w - vp_x_offset - sidebar_r_w else 1;
    const base_vp = BaseViewport{
        .x = @floatFromInt(vp_x_offset),
        .y = @floatFromInt(vp_y_offset),
        .w = @floatFromInt(vp_width),
        .h = @floatFromInt(params.content_height),
    };

    // 3. Draw row VBs (no app_mu needed — TBS refcount protects data).
    if (!params.use_row_scissor) {
        if (log_enabled) applog.appLog("[row-mode] full scissor (no per-row)\n", .{});
        if (result.rs_set_sc_fn) |f| {
            var sc_full: c.D3D11_RECT = .{
                .left = params.x_offset,
                .top = params.y_offset,
                .right = params.content_right,
                .bottom = @intCast(g.height),
            };
            f(result.ctx_ptr, 1, &sc_full);
        }
    }

    drawSurfaceRowsVBFromSlots(
        g,
        row_map,
        pool,
        row_vbs,
        rows_to_draw,
        if (params.use_row_scissor) result.ctx_ptr else null,
        if (params.use_row_scissor) result.rs_set_sc_fn else null,
        if (params.use_row_scissor) rs_set_vp_fn else null,
        base_vp,
        params.x_offset,
        params.y_offset,
        params.content_right,
        params.row_h_px,
        log_enabled,
        &result.metrics,
    );

    // Collect all row verts for bloom extract.
    if (params.glow_enabled) {
        const vp_h: f32 = base_vp.h;
        for (row_map, 0..) |m, row_index| {
            if (m.slot == SLOT_NONE) continue;
            const slot = &pool.slots.items[m.slot];
            if (slot.verts.items.len == 0) continue;
            const origin_i32: i32 = @intCast(slot.origin_row);
            const row_i32: i32 = @intCast(row_index);
            const row_delta = row_i32 - origin_i32;
            if (row_delta == 0) {
                bloom_verts.appendSlice(alloc, slot.verts.items) catch {};
            } else {
                const delta_px: f32 = @floatFromInt(row_delta * params.row_h_px);
                const ndc_shift: f32 = -2.0 * delta_px / vp_h;
                const base_len = bloom_verts.items.len;
                bloom_verts.appendSlice(alloc, slot.verts.items) catch continue;
                for (bloom_verts.items[base_len..]) |*v| {
                    v.position[1] += ndc_shift;
                }
            }
        }
    }

    return result;
}

/// Flush pending atlas uploads to a D3D renderer.
/// Both main window WM_PAINT and external window paintExternalWindow
/// call this inside their respective gpu.lockContext() scopes.
/// Returns the new upload cursor value.
pub fn flushAtlasUploads(
    atlas: *dwrite_d2d.Renderer,
    gpu: *d3d11.Renderer,
    upload_cursor: u64,
    need_full_upload: bool,
) u64 {
    if (need_full_upload) {
        atlas.uploadFullAtlasToD3D(gpu);
    }
    return atlas.flushPendingAtlasUploadsSinceToD3D(gpu, upload_cursor);
}

/// Snap client height to cell grid boundaries (at least 1 row).
/// Used by both main window and external window to compute D3D11 viewport
/// content_height that matches core's NDC vertex generation.
pub fn snappedContentHeight(client_h: u32, cell_total_h_px: u32, y_offset: u32) u32 {
    const safe_cell_h: u32 = @max(1, cell_total_h_px);
    const drawable_h: u32 = if (client_h > y_offset) client_h - y_offset else 0;
    const snapped: u32 = (drawable_h / safe_cell_h) * safe_cell_h;
    return @max(snapped, safe_cell_h);
}

/// Draw external surface in flat (non-row) mode using gpu.draw().
/// Filters out cursor vertices when cursor_visible=false.
/// Appends scrollbar_verts if non-empty.
/// Uses caller-provided scratch buffer to avoid per-paint heap allocation.
/// IMPORTANT: scratch must NOT alias verts (e.g. do not pass paint_scratch
/// if verts points into paint_scratch.items).
pub fn drawExternalSurfaceFlat(
    gpu: *d3d11.Renderer,
    scratch: *std.ArrayListUnmanaged(Vertex),
    alloc: std.mem.Allocator,
    verts: []const Vertex,
    vert_count: usize,
    cursor_visible: bool,
    scrollbar_verts: []const Vertex,
    glow_enabled: bool,
    glow_intensity: f32,
) !void {
    const draw_opts: d3d11.Renderer.DrawOpts = .{
        .present = false, // Caller (paintExternalWindow) handles present via presentOnlyFromBack
        .glow_enabled = glow_enabled,
        .glow_intensity = glow_intensity,
    };

    const needs_filter = !cursor_visible;
    const needs_scrollbar = scrollbar_verts.len > 0;

    if (!needs_filter and !needs_scrollbar) {
        try gpu.drawEx(verts[0..vert_count], &[_]Vertex{}, null, draw_opts);
        return;
    }

    scratch.clearRetainingCapacity();
    scratch.ensureTotalCapacity(alloc, vert_count + scrollbar_verts.len) catch {
        try gpu.drawEx(verts[0..vert_count], &[_]Vertex{}, null, draw_opts);
        return;
    };

    if (needs_filter) {
        for (verts[0..vert_count]) |v| {
            if ((v.deco_flags & DECO_CURSOR) == 0) {
                scratch.appendAssumeCapacity(v);
            }
        }
    } else {
        scratch.appendSliceAssumeCapacity(verts[0..vert_count]);
    }

    if (needs_scrollbar) {
        scratch.appendSliceAssumeCapacity(scrollbar_verts);
    }

    try gpu.drawEx(scratch.items, &[_]Vertex{}, null, draw_opts);
}

/// Parameters for shared row-mode draw sequence (drawEx setup + drawSurfaceRowsVB + bloom collect).
/// Used by both main window WM_PAINT and external window paint path.
pub const RowModeDrawParams = struct {
    content_height: u32,
    row_h_px: i32,
    x_offset: i32 = 0,
    y_offset: i32 = 0,
    content_right: i32,
    preserve_back: bool,
    use_row_scissor: bool = true,
    glow_enabled: bool = false,
    // DrawEx viewport options (null = use full renderer dimensions)
    content_width: ?u32 = null,
    content_y_offset: ?u32 = null,
    content_x_offset: ?u32 = null,
    sidebar_right_width: ?u32 = null,
    tabbar_bg_color: ?[4]f32 = null,

    /// Compute bloom viewport from these params.
    pub fn bloomViewport(self: RowModeDrawParams, renderer_width: u32) struct { x: u32, y: u32, w: u32, h: u32 } {
        const vp_x: u32 = if (self.content_x_offset) |off| off else 0;
        const vp_y: u32 = if (self.content_y_offset) |off| off else 0;
        const sidebar_r: u32 = self.sidebar_right_width orelse 0;
        const base_w: u32 = self.content_width orelse renderer_width;
        const vp_w: u32 = if (base_w > vp_x + sidebar_r) base_w - vp_x - sidebar_r else 1;
        return .{ .x = vp_x, .y = vp_y, .w = vp_w, .h = self.content_height };
    }
};

pub const RSSetScissorRectsFn = *const fn (?*c.ID3D11DeviceContext, c.UINT, [*c]const c.D3D11_RECT) callconv(.c) void;

pub const RowModeDrawResult = struct {
    ctx_ptr: ?*c.ID3D11DeviceContext = null,
    rs_set_sc_fn: ?RSSetScissorRectsFn = null,
    metrics: SurfaceRowDrawMetrics = .{},
};

/// Shared row-mode rendering: drawEx setup → drawSurfaceRowsVB → bloom verts collection.
/// Caller must hold gpu.lockContext(). app_mu is locked internally during row VB draw.
/// row_verts_list is accessed under app_mu to avoid use-after-free from concurrent reallocation.
/// If params.glow_enabled, bloom_verts is populated with all row vertices (under lock).
/// Caller is responsible for cursor overlay, scrollbar overlay, bloom post-process, and present.
pub fn drawRowModeSetupAndRows(
    g: *d3d11.Renderer,
    alloc: std.mem.Allocator,
    app_mu: *std.Thread.Mutex,
    row_verts_list: *std.ArrayListUnmanaged(RowVerts),
    rows_to_draw: []const u32,
    bloom_verts: *std.ArrayListUnmanaged(Vertex),
    params: RowModeDrawParams,
) !RowModeDrawResult {
    const log_enabled = applog.isEnabled();

    // 1. drawEx: bind RTV, clear if needed, set viewport to content_height.
    try g.drawEx(
        &[_]Vertex{},
        &[_]Vertex{},
        null,
        .{
            .present = false,
            .preserve_on_null_dirty = params.preserve_back,
            .content_height = params.content_height,
            .content_width = params.content_width,
            .content_y_offset = params.content_y_offset,
            .content_x_offset = params.content_x_offset,
            .sidebar_right_width = params.sidebar_right_width,
            .tabbar_bg_color = params.tabbar_bg_color,
        },
    );

    // 2. Get D3D context, RSSetScissorRects and RSSetViewports function pointers.
    var result = RowModeDrawResult{};
    var rs_set_vp_fn: ?RSSetViewportsFn = null;
    if (g.ctx) |ctx_val| {
        result.ctx_ptr = ctx_val;
        result.rs_set_sc_fn = ctx_val.*.lpVtbl.*.RSSetScissorRects;
        rs_set_vp_fn = ctx_val.*.lpVtbl.*.RSSetViewports;
    }

    // Compute base viewport matching what drawEx set (for per-row viewport Y translation).
    const vp_x_offset = params.content_x_offset orelse 0;
    const vp_y_offset = params.content_y_offset orelse 0;
    const sidebar_r_w = params.sidebar_right_width orelse 0;
    const base_w = params.content_width orelse g.width;
    const vp_width = if (base_w > vp_x_offset + sidebar_r_w) base_w - vp_x_offset - sidebar_r_w else 1;
    const base_vp = BaseViewport{
        .x = @floatFromInt(vp_x_offset),
        .y = @floatFromInt(vp_y_offset),
        .w = @floatFromInt(vp_width),
        .h = @floatFromInt(params.content_height),
    };

    // 3. Lock, read row_verts slice, draw row VBs, collect bloom verts, unlock.
    {
        app_mu.lock();
        defer app_mu.unlock();

        const row_verts = row_verts_list.items;

        // When per-row scissor is disabled (e.g. seed mode), set a full-content scissor
        // to prevent drawing outside the content area.
        if (!params.use_row_scissor) {
            if (log_enabled) applog.appLog("[row-mode] full scissor (no per-row)\n", .{});
            if (result.rs_set_sc_fn) |f| {
                var sc_full: c.D3D11_RECT = .{
                    .left = params.x_offset,
                    .top = params.y_offset,
                    .right = params.content_right,
                    .bottom = @intCast(g.height),
                };
                f(result.ctx_ptr, 1, &sc_full);
            }
        }

        drawSurfaceRowsVB(
            g,
            row_verts,
            rows_to_draw,
            if (params.use_row_scissor) result.ctx_ptr else null,
            if (params.use_row_scissor) result.rs_set_sc_fn else null,
            if (params.use_row_scissor) rs_set_vp_fn else null,
            base_vp,
            params.x_offset,
            params.y_offset,
            params.content_right,
            params.row_h_px,
            log_enabled,
            &result.metrics,
        );

        // Collect all row verts for bloom extract (under lock).
        // When scroll reuse is active, origin_row may differ from the draw row.
        // drawSurfaceRowsVB compensates via viewport Y offset, but bloom renders
        // with a fixed viewport, so we must adjust NDC Y coordinates here.
        if (params.glow_enabled) {
            const vp_h: f32 = base_vp.h;
            for (row_verts, 0..) |*rv, row_index| {
                if (rv.verts.items.len == 0) continue;
                const origin_i32: i32 = @intCast(rv.origin_row);
                const row_i32: i32 = @intCast(row_index);
                const row_delta = row_i32 - origin_i32;
                if (row_delta == 0) {
                    bloom_verts.appendSlice(alloc, rv.verts.items) catch {};
                } else {
                    // Shift NDC Y to match the viewport offset applied at draw time.
                    // Viewport TopLeftY += delta_px moves content DOWN on screen.
                    // Equivalent NDC adjustment: Y -= 2 * delta_px / viewport_height.
                    const delta_px: f32 = @floatFromInt(row_delta * params.row_h_px);
                    const ndc_shift: f32 = -2.0 * delta_px / vp_h;
                    const base_len = bloom_verts.items.len;
                    bloom_verts.appendSlice(alloc, rv.verts.items) catch continue;
                    for (bloom_verts.items[base_len..]) |*v| {
                        v.position[1] += ndc_shift;
                    }
                }
            }
        }
    }

    return result;
}

pub const SurfaceRowDrawMetrics = struct {
    drawn_rows: u32 = 0,
    skipped_empty: u32 = 0,
    first_empty_row: ?u32 = null,
    vb_upload_rows: u32 = 0,
    vb_upload_rows_bytes: u64 = 0,
    vb_upload_ns: i128 = 0,
    draw_vb_ns: i128 = 0,
};

pub const RSSetViewportsFn = *const fn (?*c.ID3D11DeviceContext, c.UINT, [*c]const c.D3D11_VIEWPORT) callconv(.c) void;

/// Base viewport state for per-row viewport Y translation.
/// When origin_row != current draw row, the viewport TopLeftY is offset to
/// reuse the existing VB without re-uploading (same pattern as macOS shader translation).
pub const BaseViewport = struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,
};

pub fn drawSurfaceRowsVB(
    g: *d3d11.Renderer,
    row_verts: []RowVerts,
    rows_to_draw: ?[]const u32,
    ctx_ptr: ?*c.ID3D11DeviceContext,
    rs_set_sc_fn: ?RSSetScissorRectsFn,
    rs_set_vp_fn: ?RSSetViewportsFn,
    base_vp: BaseViewport,
    x_offset: i32,
    y_offset: i32,
    content_right: i32,
    row_h_px: i32,
    log_enabled: bool,
    metrics: *SurfaceRowDrawMetrics,
) void {
    const row_count: usize = if (rows_to_draw) |rows| rows.len else row_verts.len;
    var vp_dirty = false; // Track whether viewport was modified from base
    var i: usize = 0;
    while (i < row_count) : (i += 1) {
        const row: u32 = if (rows_to_draw) |rows| rows[i] else @intCast(i);
        if (row >= row_verts.len) {
            metrics.skipped_empty += 1;
            continue;
        }

        const rv = &row_verts[@intCast(row)];
        const src = rv.verts.items;
        if (src.len == 0) {
            metrics.skipped_empty += 1;
            if (metrics.first_empty_row == null) {
                metrics.first_empty_row = row;
            }
            continue;
        }

        if (rv.uploaded_gen != rv.gen or rv.vb == null or rv.vb_bytes < src.len * @sizeOf(Vertex)) {
            const need_bytes = src.len * @sizeOf(Vertex);
            const t_upload_start = if (log_enabled) std.time.nanoTimestamp() else 0;
            _ = ensureRowVBReady(g, rv, src) catch {
                metrics.skipped_empty += 1;
                continue;
            };
            if (log_enabled) {
                metrics.vb_upload_ns += std.time.nanoTimestamp() - t_upload_start;
            }
            metrics.vb_upload_rows += 1;
            metrics.vb_upload_rows_bytes += @as(u64, @intCast(need_bytes));
        }

        if (ctx_ptr != null and rs_set_sc_fn != null and row_h_px > 0) {
            const top = y_offset + @as(i32, @intCast(row)) * row_h_px;
            const bottom = top + row_h_px;
            var sc: c.D3D11_RECT = .{
                .left = x_offset,
                .top = top,
                .right = content_right,
                .bottom = bottom,
            };
            rs_set_sc_fn.?(ctx_ptr, 1, &sc);

            // Viewport Y translation: reuse VB from a different row position.
            // origin_row records where the vertices were generated. If it differs
            // from the current draw row, offset the viewport to compensate.
            // Sign: row > origin_row means vertex was generated for a higher row
            // (smaller Y in screen coords), so shift viewport UP (negative delta).
            // D3D11 viewport: TopLeftY + delta moves rendered pixels DOWN when delta > 0.
            // macOS equivalent: translationY = (sourceRow - logicalRow) * cellH / vpH * 2.0
            if (rs_set_vp_fn) |vp_fn| {
                const origin_i32: i32 = @intCast(rv.origin_row);
                const row_i32: i32 = @intCast(row);
                const row_delta = row_i32 - origin_i32;
                if (row_delta != 0) {
                    const delta_px: f32 = @floatFromInt(row_delta * row_h_px);
                    var vp: c.D3D11_VIEWPORT = .{
                        .TopLeftX = base_vp.x,
                        .TopLeftY = base_vp.y + delta_px,
                        .Width = base_vp.w,
                        .Height = base_vp.h,
                        .MinDepth = 0,
                        .MaxDepth = 1,
                    };
                    vp_fn(ctx_ptr, 1, &vp);
                    vp_dirty = true;
                } else if (vp_dirty) {
                    // Restore base viewport.
                    var vp: c.D3D11_VIEWPORT = .{
                        .TopLeftX = base_vp.x,
                        .TopLeftY = base_vp.y,
                        .Width = base_vp.w,
                        .Height = base_vp.h,
                        .MinDepth = 0,
                        .MaxDepth = 1,
                    };
                    vp_fn(ctx_ptr, 1, &vp);
                    vp_dirty = false;
                }
            }
        }

        const t_draw_start = if (log_enabled) std.time.nanoTimestamp() else 0;
        g.drawVB(rv.vb.?, src.len) catch {
            metrics.skipped_empty += 1;
            continue;
        };
        if (log_enabled) {
            metrics.draw_vb_ns += std.time.nanoTimestamp() - t_draw_start;
        }
        metrics.drawn_rows += 1;
    }

    // Restore base viewport if it was modified during the last row.
    if (vp_dirty) {
        if (rs_set_vp_fn) |vp_fn| {
            var vp: c.D3D11_VIEWPORT = .{
                .TopLeftX = base_vp.x,
                .TopLeftY = base_vp.y,
                .Width = base_vp.w,
                .Height = base_vp.h,
                .MinDepth = 0,
                .MaxDepth = 1,
            };
            vp_fn(ctx_ptr, 1, &vp);
        }
    }
}

/// Shared cursor overlay: upload cursor VB, draw cursor (blink on) or redraw row (blink off).
/// Used by both main window and external window paint paths after row VB drawing.
/// Updates last_painted_cursor_row for scroll ghost erasure tracking.
pub const CursorOverlayParams = struct {
    cursor_verts: []const Vertex,
    cursor_row: ?u32,
    cursor_vb: *?*c.ID3D11Buffer,
    cursor_vb_bytes: *usize,
    row_vbs: []RowVB,
    row_map: []const RowMapping,
    pool: *const SlotPool,
    blink_visible: bool,
    x_offset: i32 = 0,
    y_offset: i32 = 0,
    content_right: i32,
    content_height: u32,
    row_h_px: i32,
    ctx_ptr: ?*c.ID3D11DeviceContext,
    rs_set_sc_fn: ?RSSetScissorRectsFn,
    last_painted_cursor_row: *?u32,
};

pub fn drawCursorOverlay(g: *d3d11.Renderer, p: CursorOverlayParams) void {
    const log_enabled = applog.isEnabled();

    if (p.cursor_verts.len == 0) {
        // No cursor verts — clear tracking.
        p.last_painted_cursor_row.* = null;
        if (log_enabled) applog.appLog("[cursor-overlay] no cursor verts\n", .{});
        return;
    }

    if (p.row_h_px <= 0) return;

    // 1. Upload cursor verts to VB.
    const need_bytes: usize = p.cursor_verts.len * @sizeOf(Vertex);
    g.ensureExternalVertexBuffer(p.cursor_vb, p.cursor_vb_bytes, need_bytes) catch return;
    const vb = p.cursor_vb.* orelse return;
    g.uploadVertsToVB(vb, p.cursor_verts) catch return;

    // 2. Resolve cursor row: use explicit value or compute from vertex NDC positions.
    const cursor_row: u32 = p.cursor_row orelse blk: {
        // Compute from cursor vertex center Y (NDC → pixel → row).
        var min_y: f32 = p.cursor_verts[0].position[1];
        var max_y: f32 = min_y;
        for (p.cursor_verts[1..]) |v| {
            if (v.position[1] < min_y) min_y = v.position[1];
            if (v.position[1] > max_y) max_y = v.position[1];
        }
        const center_ndc_y = (min_y + max_y) * 0.5;
        const h_f: f32 = @floatFromInt(p.content_height);
        const pixel_y: f32 = (1.0 - center_ndc_y) * 0.5 * h_f;
        const row_i: i32 = @intFromFloat(@floor(pixel_y / @as(f32, @floatFromInt(p.row_h_px))));
        if (row_i < 0) break :blk 0;
        break :blk @intCast(row_i);
    };

    // 3. Set scissor to cursor row.
    if (p.rs_set_sc_fn) |f| {
        const top_px: i32 = p.y_offset + @as(i32, @intCast(cursor_row)) * p.row_h_px;
        const bottom_px: i32 = top_px + p.row_h_px;
        var sc: c.D3D11_RECT = .{
            .left = p.x_offset,
            .top = top_px,
            .right = p.content_right,
            .bottom = bottom_px,
        };
        f(p.ctx_ptr, 1, &sc);
    }

    // 4. Blink on: draw cursor VB. Blink off: redraw row VB to erase cursor.
    if (p.blink_visible) {
        if (log_enabled) applog.appLog("[cursor-overlay] draw cursor row={d} verts={d}\n", .{ cursor_row, p.cursor_verts.len });
        g.drawVB(vb, p.cursor_verts.len) catch {};
    } else {
        if (log_enabled) applog.appLog("[cursor-overlay] blink off, redraw row={d}\n", .{cursor_row});
        if (cursor_row < p.row_vbs.len and cursor_row < p.row_map.len) {
            const rvb = &p.row_vbs[cursor_row];
            const mapping = p.row_map[cursor_row];
            const slot_verts_len: usize = if (mapping.slot != SLOT_NONE) p.pool.slots.items[mapping.slot].verts.items.len else 0;
            if (rvb.vb) |row_vb| {
                if (slot_verts_len > 0) {
                    g.drawVB(row_vb, slot_verts_len) catch {};
                }
            }
        }
    }

    // 5. Update tracking for scroll ghost erasure.
    if (p.blink_visible) {
        p.last_painted_cursor_row.* = cursor_row;
    } else {
        p.last_painted_cursor_row.* = null;
    }
}

/// Draw scrollbar overlay into the current render target.
/// Uploads scrollbar vertices to a dedicated VB and draws them at full viewport.
/// Used by both main window and external window paint paths after row/flat drawing.
pub fn drawScrollbarOverlay(
    g: *d3d11.Renderer,
    vb_ptr: *?*c.ID3D11Buffer,
    vb_bytes_ptr: *usize,
    scrollbar_verts: []const Vertex,
) void {
    if (scrollbar_verts.len == 0) return;
    g.setFullViewport();
    const need_bytes = scrollbar_verts.len * @sizeOf(Vertex);
    g.ensureExternalVertexBuffer(vb_ptr, vb_bytes_ptr, need_bytes) catch return;
    const vb = vb_ptr.* orelse return;
    g.uploadVertsToVB(vb, scrollbar_verts) catch return;
    g.drawVB(vb, scrollbar_verts.len) catch {};
}

/// Draw bloom/glow post-process overlay.
/// Applies neon glow effect using the provided bloom and cursor vertices.
/// Caller decides which cursor verts to pass (e.g. empty slice when cursor is blink-hidden).
pub fn drawBloomOverlay(
    g: *d3d11.Renderer,
    bloom_verts: []const Vertex,
    cursor_verts: []const Vertex,
    glow_intensity: f32,
    draw_params: RowModeDrawParams,
) void {
    if (bloom_verts.len == 0) return;
    const bvp = draw_params.bloomViewport(g.width);
    g.drawBloomFromVerts(bloom_verts, cursor_verts, glow_intensity, bvp.x, bvp.y, bvp.w, bvp.h);
}

/// Pending glyph entry for deferred atlas population
/// (used when glyph is requested before atlas is ready)
pub const PendingGlyph = struct {
    scalar: u32,
    style_flags: u32, // 0 for unstyled
};

/// Scrollbar geometry result type
pub const ScrollbarGeometry = struct {
    track_left: f32,
    track_top: f32,
    track_right: f32,
    track_bottom: f32,
    knob_top: f32,
    knob_bottom: f32,
    is_scrollable: bool,
};

// =========================================================================
// App — central application state
// =========================================================================

pub const App = struct {
    // Deferred SetWindowPos operations (avoids cross-thread WM_SIZE deadlock)
    pub const MAX_DEFERRED_WIN_OPS = 32;
    pub const DeferredWinOp = struct {
        hwnd: c.HWND,
        x: c_int,
        y: c_int,
        w: c_int,
        h: c_int,
        flags: c.UINT,
    };

    alloc: std.mem.Allocator,

    // Configuration loaded from config.toml
    config: config_mod.Config = .{},

    mu: std.Thread.Mutex = .{},

    hwnd: ?c.HWND = null,
    content_hwnd: ?c.HWND = null, // Child window for D3D11 rendering (when ext_tabline enabled)
    corep: ?*zonvie_core = null,

    ui_thread_id: u32 = 0,

    // Atlas builder (DirectWrite + CPU atlas, metrics)
    atlas: ?dwrite_d2d.Renderer = null,

    // GPU renderer (D3D11)
    renderer: ?d3d11.Renderer = null,

    // External windows (grid_id -> ExternalWindow)
    external_windows: std.AutoHashMapUnmanaged(i64, ExternalWindow) = .{},

    // Pending external window creation requests (for UI thread processing)
    pending_external_windows: std.ArrayListUnmanaged(PendingExternalWindow) = .{},

    // Pending position for next external window (set by tab externalization)
    pending_external_window_position: ?struct { x: c_int, y: c_int } = null,
    pending_external_window_position_time: i64 = 0, // Timestamp when position was set (for timeout)

    // Saved positions for external windows (restored on tab switch back)
    saved_external_window_positions: std.AutoHashMapUnmanaged(i64, struct { x: c_int, y: c_int }) = .{},

    // Pending vertices for external windows that haven't been created yet
    pending_external_verts: std.ArrayListUnmanaged(PendingExternalVertices) = .{},

    // ext_messages window state
    message_window: ?MessageWindow = null,
    pending_messages: std.ArrayListUnmanaged(PendingMessageRequest) = .{},
    display_messages: std.ArrayListUnmanaged(DisplayMessage) = .{}, // Stack of visible messages

    // ext_tabline state
    tabline_state: TablineState = .{},

    // Mini view state (showmode/showcmd/ruler)
    mini_windows: [3]MiniWindowState = .{ .{}, .{}, .{} },
    last_mouse_grid_id: i64 = 1,

    owned_by_hwnd: bool = false, //

    // Flag to track if Neovim has exited (to avoid requestQuit after exit)
    // Atomic to avoid data race between onExit (RPC thread) and WM_CLOSE (UI thread)
    neovim_exited: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    // Flag to track if we're waiting for quit response (to handle timeout)
    quit_pending: bool = false,
    // Flag to ignore delayed quit responses after timeout fired
    quit_timeout_fired: bool = false,

    // Main surface vertex state (shared structure with external windows).
    // paint_full=false: main window uses explicit dirty tracking; external windows default to true.
    surface: SurfaceState = .{ .paint_full = false },

    // Triple-buffered surface for lock-free vertex handoff (core → UI thread).
    tbs: TripleBufferedSurface = .{},
    // GPU row vertex buffers (UI thread owned, corresponds to TBS committed set row_map slots).
    row_vbs: std.ArrayListUnmanaged(RowVB) = .{},
    // DXGI scroll state is now bundled in TBS (flush_scroll_* → pending_scroll_* → PaintSnapshot).
    // See TripleBufferedSurface.flush_scroll_rect / pending_scroll_rect / PaintSnapshot.scroll_rect.
    // Last cursor rectangle in client pixels (derived from cursor_verts).
    last_cursor_rect_px: ?c.RECT = null,
    // Row index where cursor was last painted into back_tex.
    // Used by scrollBackTex to erase cursor ghost before shifting.
    last_painted_cursor_row: ?u32 = null,

    // Scratch buffer for WM_PAINT(row): per-row vertex copy.
    // Reused to avoid per-paint alloc/free.
    row_tmp_verts: std.ArrayListUnmanaged(Vertex) = .{},

    // WM_PAINT(row) persistent buffers (avoid per-frame alloc/free)
    wm_paint_rows_to_draw: std.ArrayListUnmanaged(u32) = .{},
    wm_paint_present_rects: std.ArrayListUnmanaged(c.RECT) = .{},

    // Cursor overlay VB for row-mode (avoid extra g.drawEx per paint).
    cursor_vb: ?*c.ID3D11Buffer = null,
    cursor_vb_bytes: usize = 0,

    cursor: ?Cursor = null,

    row_mode_max_row_end: u32 = 0,

    // ---- NEW: self-managed damage queue (avoid OS update region dependency) ----
    paint_rects: std.ArrayListUnmanaged(c.RECT) = .{},

    // Set by vertex callbacks when dirty state changes during a flush.
    // Checked and cleared by onFlushEnd to decide whether to InvalidateRect.
    // Skips InvalidateRect for flushes with no visual changes (e.g. msg_showcmd-only).
    flush_needs_invalidate: bool = false,

    // Scrollbar update coalescing: set by on_flush_end (core thread), cleared by WM_APP_UPDATE_SCROLLBAR (UI thread).
    scrollbar_update_pending: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    // DWrite rasterization perf counters (accumulated during flush, reported by onFlushEnd)
    rasterize_call_count: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    rasterize_total_ns: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    rasterize_max_ns: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    // ---- NEW: cursor VB upload generation (row-mode overlay) ----
    cursor_gen: u64 = 0,
    cursor_uploaded_gen: u64 = 0,
    // Cursor overlay mode: back buffer kept cursor-free, cursor drawn in present step.
    cursor_overlay_active: bool = false,

    // --- IME state ---
    ime_composing: bool = false,
    ime_composition_str: std.ArrayListUnmanaged(u16) = .{}, // UTF-16 composition string
    ime_composition_utf8: std.ArrayListUnmanaged(u8) = .{}, // UTF-8 for display
    ime_clause_info: std.ArrayListUnmanaged(u32) = .{}, // clause boundaries
    ime_cursor_pos: u32 = 0, // cursor position in composition
    ime_target_start: u32 = 0, // start of target clause (thick underline)
    ime_target_end: u32 = 0, // end of target clause
    ime_overlay_hwnd: ?c.HWND = null, // Layered window for preedit overlay

    // When row-mode starts (or after resize), we must seed the persistent back buffer once.
    // Otherwise the first present may clear to black and only the dirty row gets drawn.
    need_full_seed: std.atomic.Value(bool) = std.atomic.Value(bool).init(true),
    // After atlas reset, external window paints may consume shared pending_uploads.
    // This flag ensures the main window uploads the full atlas to cover any missed regions.
    atlas_full_upload_needed: bool = false,
    // Main window cursor into renderer's pending_uploads queue (since-based upload).
    atlas_upload_cursor: u64 = 0,
    // Row-mode seed tracking: require a full set of rows before presenting.
    seed_pending: bool = true,
    seed_clear_pending: bool = true,
    row_valid: std.DynamicBitSetUnmanaged = .{},
    row_valid_count: u32 = 0,
    row_layout_gen: u64 = 0,

    linespace_px: u32 = 0,

    // DPI scaling factor (e.g. 1.0 at 96 DPI, 2.0 at 192 DPI)
    dpi_scale: f32 = 1.0,

    // cell metrics used for layout->core_update_layout_px
    cell_w_px: u32 = 9,
    cell_h_px: u32 = 18,

    // Timestamp of last WM_SIZE (ns since epoch).
    last_resize_ns: i128 = 0,

    // Mouse button tracking for drag events
    // 0 = none, 1 = left, 2 = right, 3 = middle, 4 = x1, 5 = x2
    mouse_button_held: u8 = 0,

    // Track last cursor grid to detect transitions from external windows
    last_cursor_grid: i64 = 1,
    // Tick count when cursor left an external window (used to suppress main window activation briefly)
    last_ext_window_exit_tick: i64 = 0,

    // Cursor blink state
    cursor_blink_state: bool = true, // true = visible, false = hidden
    cursor_blink_timer: c.UINT_PTR = 0, // Timer ID for blink
    cursor_blink_phase: u8 = 0, // 0 = not blinking, 1 = blinking
    cursor_blink_wait_ms: u32 = 0,
    cursor_blink_on_ms: u32 = 0,
    cursor_blink_off_ms: u32 = 0,

    // Scroll accumulators for high-resolution scrolling
    scroll_accum: i16 = 0,
    h_scroll_accum: i16 = 0,

    // Scrollbar state (custom D3D11 overlay scrollbar)
    scrollbar_visible: bool = false,
    scrollbar_hide_timer: c.UINT_PTR = 0,
    scrollbar_alpha: f32 = 0.0, // Current alpha (for fade animation)
    scrollbar_target_alpha: f32 = 0.0, // Target alpha
    scrollbar_dragging: bool = false, // Currently dragging knob
    scrollbar_drag_start_y: i32 = 0, // Mouse Y at drag start
    scrollbar_drag_start_topline: i64 = 0, // topline at drag start
    scrollbar_hover: bool = false, // Mouse hovering over scrollbar area
    cursor_is_hand: bool = false, // URL hover: hand cursor
    url_cache_grid: i64 = 0,
    url_cache_row: i32 = 0,
    url_cache_col: i32 = 0,
    scrollbar_repeat_dir: i8 = 0, // -1 = page up, 1 = page down, 0 = none
    scrollbar_repeat_timer: c.UINT_PTR = 0, // Timer for repeat scroll
    scrollbar_last_scroll_time: i64 = 0, // Last scroll time in ms (for throttling)
    scrollbar_pending_line: i64 = -1, // Pending scroll line (throttled)
    scrollbar_pending_use_bottom: bool = false, // Pending scroll uses bottom alignment
    last_viewport_topline: i64 = -1,
    last_viewport_line_count: i64 = -1,
    last_viewport_botline: i64 = -1,
    // Scrollbar vertex buffer
    scrollbar_vb: ?*c.ID3D11Buffer = null,
    scrollbar_vb_bytes: usize = 0,

    // ext_cmdline: current firstc character (':', '/', '?', etc.)
    cmdline_firstc: u8 = 0,

    // Cached cmdline UI colors (updated when highlights change, avoids core calls during paint)
    // Border uses Search highlight bg, icon uses Comment highlight fg
    cmdline_border_color: [3]f32 = .{ 1.0, 1.0, 0.0 }, // default yellow
    cmdline_icon_color: [3]f32 = .{ 0.5, 0.5, 0.5 }, // default gray

    // ext_cmdline enabled flag (set from --extcmdline command line arg)
    ext_cmdline_enabled: bool = false,

    // ext_cmdline: saved position for next cmdline window (null = use default center)
    // This enables dragging the cmdline window and remembering its position
    cmdline_saved_x: ?c_int = null,
    cmdline_saved_y: ?c_int = null,

    // ext_messages enabled flag (set from --extmessages command line arg)
    ext_messages_enabled: bool = false,

    // ext_tabline enabled flag (set from --exttabline command line arg)
    ext_tabline_enabled: bool = false,
    tabline_style: TablineStyle = .titlebar,
    sidebar_position_right: bool = false, // false = left, true = right
    sidebar_width_px: u32 = 200,

    // Colorscheme default colors (0x00RRGGBB, or 0xFFFFFFFF = not set)
    colorscheme_bg: u32 = 0xFFFFFFFF,
    colorscheme_fg: u32 = 0xFFFFFFFF,

    // Pending title for deferred SetWindowTextW (avoids cross-thread SendMessage deadlock)
    pending_title: [512]u16 = undefined,
    pending_title_len: usize = 0,

    // Deferred SetWindowPos operations (avoids cross-thread WM_SIZE deadlock)
    deferred_win_ops: [MAX_DEFERRED_WIN_OPS]DeferredWinOp = undefined,
    deferred_win_ops_count: usize = 0,

    // ext_windows enabled flag (set from --extwindows command line arg or config)
    ext_windows_enabled: bool = false,

    // WSL mode flags (set from --wsl command line arg or config)
    wsl_mode: bool = false,
    wsl_distro: ?[]const u8 = null,

    // SSH mode flags (set from --ssh command line arg or config)
    ssh_mode: bool = false,
    ssh_host: ?[]const u8 = null,
    ssh_port: ?u16 = null,
    ssh_identity: ?[]const u8 = null,
    ssh_password: ?[]const u8 = null, // Password from dialog (freed after use)

    // Devcontainer mode flags (set from --devcontainer command line arg)
    devcontainer_mode: bool = false,
    devcontainer_workspace: ?[]const u8 = null,
    devcontainer_config: ?[]const u8 = null,
    devcontainer_rebuild: bool = false,
    devcontainer_up_pending: bool = false, // Waiting for devcontainer up to complete
    devcontainer_nvim_started: bool = false, // Nvim started in devcontainer mode

    // Extra arguments to pass to nvim (not recognized as zonvie arguments)
    nvim_extra_args: std.ArrayListUnmanaged([]const u8) = .{},

    // CLI --nvim override (points into args allocation, no ownership)
    cli_nvim_path: ?[]const u8 = null,

    // Startup timing: first WM_PAINT with nvim content
    first_paint_logged: bool = false,

    // Clipboard request state (for cross-thread clipboard operations)
    clipboard_event: c.HANDLE = null, // Manual-reset event for sync
    clipboard_buf: [64 * 1024]u8 = undefined,
    clipboard_len: usize = 0,
    clipboard_result: c_int = 0,
    clipboard_set_data: ?[*]const u8 = null,
    clipboard_set_len: usize = 0,

    // SSH auth prompt state (owned copy - core frees original after callback)
    ssh_prompt_owned: ?[]u8 = null,

    // Pending glyphs queue: glyphs requested before atlas was ready
    // (for parallel nvim spawn + renderer init)
    pending_glyphs: std.ArrayListUnmanaged(PendingGlyph) = .{},

    // Cached visible grids for non-blocking UI queries (UI thread only).
    // Updated on successful tryLock; stale data used when grid_mu is contended.
    cached_visible_grids: [16]GridInfo = undefined,
    cached_visible_grids_count: usize = 0,

    // Tray icon for OS notification (balloon notification)
    tray_icon: ?TrayIcon = null,

    /// Maximum row buffer count to prevent unbounded memory growth
    pub const max_row_buffers: u32 = 1000;

    pub fn ensureRowStorage(self: *App, row: u32) void {
        // Enforce maximum row limit
        if (row >= max_row_buffers) {
            if (applog.isEnabled()) applog.appLog("[win] row {d} exceeds max_row_buffers ({d})\n", .{ row, max_row_buffers });
            return;
        }

        const need: usize = @intCast(row + 1);
        if (self.surface.row_verts.items.len >= need) return;

        // grow row_verts to (row+1)
        const old_len = self.surface.row_verts.items.len;
        self.surface.row_verts.resize(self.alloc, need) catch return;

        // init new slots
        var i: usize = old_len;
        while (i < need) : (i += 1) {
            self.surface.row_verts.items[i] = .{};
        }
    }

    /// Shrink row_verts if significantly oversized (> 2x needed)
    pub fn maybeShrinkRowStorage(self: *App, needed_rows: u32) void {
        if (needed_rows == 0) return;
        const needed: usize = @intCast(needed_rows);
        // Only shrink if array is more than 2x the needed size
        if (self.surface.row_verts.items.len > needed * 2) {
            // Free excess RowVerts' inner arrays
            for (self.surface.row_verts.items[needed..]) |*rv| {
                rv.verts.deinit(self.alloc);
            }
            self.surface.row_verts.shrinkRetainingCapacity(needed);
            if (applog.isEnabled()) applog.appLog("[win] shrunk row_verts from {d} to {d}\n", .{ self.surface.row_verts.items.len + (self.surface.row_verts.items.len - needed), needed });
        }
    }

    /// Non-blocking visible grids query with cache fallback (UI thread only).
    /// Attempts tryLock on grid_mu; on success updates cached_visible_grids.
    /// On failure returns the previously cached data.
    pub fn getVisibleGridsCached(self: *App, corep: *zonvie_core) struct { grids: [16]GridInfo, count: usize } {
        var buf: [16]GridInfo = undefined;
        const result = zonvie_core_try_get_visible_grids(corep, &buf, 16);
        if (result >= 0) {
            const count: usize = @intCast(result);
            @memcpy(self.cached_visible_grids[0..count], buf[0..count]);
            self.cached_visible_grids_count = count;
            return .{ .grids = self.cached_visible_grids, .count = count };
        }
        // tryLock failed — return stale cache
        return .{ .grids = self.cached_visible_grids, .count = self.cached_visible_grids_count };
    }

    /// Get target rectangle for ext-float (msg_show/msg_history) positioning
    /// based on config.messages.msg_pos.ext_float setting
    pub fn getExtFloatTargetRect(self: *App) c.RECT {
        const pos_mode = self.config.messages.msg_pos.ext_float;

        switch (pos_mode) {
            .display => {
                // Display-based: use entire screen
                const screen_w = c.GetSystemMetrics(c.SM_CXSCREEN);
                const screen_h = c.GetSystemMetrics(c.SM_CYSCREEN);
                return c.RECT{ .left = 0, .top = 0, .right = screen_w, .bottom = screen_h };
            },
            .window => {
                // Window-based: use the window where cursor is
                const cursor_grid = self.last_cursor_grid;

                // Check if cursor is in an external window
                if (self.external_windows.get(cursor_grid)) |ext_win| {
                    var rect: c.RECT = undefined;
                    if (c.GetWindowRect(ext_win.hwnd, &rect) != 0) {
                        return rect;
                    }
                }

                // Default to main window
                if (self.hwnd) |main_hwnd| {
                    var rect: c.RECT = undefined;
                    if (c.GetClientRect(main_hwnd, &rect) != 0) {
                        // Convert client rect to screen coordinates
                        var pt: c.POINT = .{ .x = rect.left, .y = rect.top };
                        _ = c.ClientToScreen(main_hwnd, &pt);
                        const width = rect.right - rect.left;
                        const height = rect.bottom - rect.top;
                        // When using DWM custom titlebar, client area extends into titlebar.
                        // Offset top to position below the custom titlebar area.
                        const titlebar_offset: c_int = if (self.ext_tabline_enabled and self.tabline_style == .titlebar and self.content_hwnd == null)
                            self.scalePx(TablineState.TAB_BAR_HEIGHT)
                        else
                            0;
                        return c.RECT{
                            .left = pt.x,
                            .top = pt.y + titlebar_offset,
                            .right = pt.x + width,
                            .bottom = pt.y + height,
                        };
                    }
                }

                // Fallback to screen
                const screen_w = c.GetSystemMetrics(c.SM_CXSCREEN);
                const screen_h = c.GetSystemMetrics(c.SM_CYSCREEN);
                return c.RECT{ .left = 0, .top = 0, .right = screen_w, .bottom = screen_h };
            },
            .grid => {
                // Grid-based: use cursor grid's bounds
                // Note: For ext-float, we use window bounds (same as .window mode)
                // because calling zonvie_core_get_visible_grids here would cause deadlock
                // when called from onExternalVertices with mutex locked.
                // Mini windows use a different code path that handles grid bounds properly.
                const cursor_grid = self.last_cursor_grid;

                // Check if cursor is in an external window
                if (self.external_windows.get(cursor_grid)) |ext_win| {
                    var rect: c.RECT = undefined;
                    if (c.GetWindowRect(ext_win.hwnd, &rect) != 0) {
                        return rect;
                    }
                }

                // For global grid, use main window client area
                if (self.hwnd) |main_hwnd| {
                    var rect: c.RECT = undefined;
                    if (c.GetClientRect(main_hwnd, &rect) != 0) {
                        var pt: c.POINT = .{ .x = rect.left, .y = rect.top };
                        _ = c.ClientToScreen(main_hwnd, &pt);
                        const width = rect.right - rect.left;
                        const height = rect.bottom - rect.top;
                        // When using DWM custom titlebar, client area extends into titlebar.
                        // Offset top to position below the custom titlebar area.
                        const titlebar_offset: c_int = if (self.ext_tabline_enabled and self.tabline_style == .titlebar and self.content_hwnd == null)
                            self.scalePx(TablineState.TAB_BAR_HEIGHT)
                        else
                            0;
                        return c.RECT{
                            .left = pt.x,
                            .top = pt.y + titlebar_offset,
                            .right = pt.x + width,
                            .bottom = pt.y + height,
                        };
                    }
                }

                // Fallback to screen
                const screen_w = c.GetSystemMetrics(c.SM_CXSCREEN);
                const screen_h = c.GetSystemMetrics(c.SM_CYSCREEN);
                return c.RECT{ .left = 0, .top = 0, .right = screen_w, .bottom = screen_h };
            },
        }
    }

    /// Scale a pixel value by the current DPI factor.
    pub fn scalePx(self: *const App, base_px: c_int) c_int {
        return @intFromFloat(@round(@as(f32, @floatFromInt(base_px)) * self.dpi_scale));
    }

    pub fn deinit(self: *App) void {
        // Main surface: release GPU VBs from row_verts, then CPU state
        for (self.surface.row_verts.items) |*rv| {
            if (rv.vb) |p| {
                const rel = p.*.lpVtbl.*.Release orelse null;
                if (rel) |f| _ = f(p);
            }
        }
        self.surface.deinitCpuState(self.alloc);

        // Triple-buffered surface cleanup (handles slot release + pool deinit)
        self.tbs.deinit(self.alloc);
        // Release GPU VBs for TBS row_vbs
        for (self.row_vbs.items) |*vb| {
            if (vb.vb) |p| {
                const rel = p.*.lpVtbl.*.Release orelse null;
                if (rel) |f| _ = f(p);
            }
        }
        self.row_vbs.deinit(self.alloc);

        // WM_PAINT(row) scratch
        self.row_tmp_verts.deinit(self.alloc);
        self.wm_paint_rows_to_draw.deinit(self.alloc);
        self.wm_paint_present_rects.deinit(self.alloc);
        self.row_valid.deinit(self.alloc);

        // Release cursor VB (row-mode overlay)
        if (self.cursor_vb) |p| {
            const rel = p.*.lpVtbl.*.Release orelse null;
            if (rel) |f| _ = f(p);
            self.cursor_vb = null;
            self.cursor_vb_bytes = 0;
        }

        // Release scrollbar VB (main window)
        if (self.scrollbar_vb) |vb| {
            _ = vb.lpVtbl.*.Release.?(vb);
            self.scrollbar_vb = null;
        }

        // Free remaining ArrayListUnmanaged backing buffers
        self.paint_rects.deinit(self.alloc);
        self.nvim_extra_args.deinit(self.alloc);
        self.pending_glyphs.deinit(self.alloc);

        // IME state cleanup
        self.ime_composition_str.deinit(self.alloc);
        self.ime_composition_utf8.deinit(self.alloc);
        self.ime_clause_info.deinit(self.alloc);

        // External windows cleanup
        var ext_it = self.external_windows.iterator();
        while (ext_it.next()) |entry| {
            entry.value_ptr.deinit(self.alloc);
        }
        self.external_windows.deinit(self.alloc);
        self.pending_external_windows.deinit(self.alloc);
        for (self.pending_external_verts.items) |*pv| {
            pv.deinit(self.alloc);
        }
        self.pending_external_verts.deinit(self.alloc);
        self.saved_external_window_positions.deinit(self.alloc);
        self.pending_messages.deinit(self.alloc);
        self.display_messages.deinit(self.alloc);

        if (self.renderer) |*r| r.deinit();
        self.renderer = null;

        if (self.atlas) |*a| a.deinit();
        self.atlas = null;

        if (self.corep) |p| zonvie_core_destroy(p);
        self.corep = null;

        // Clipboard event cleanup
        if (self.clipboard_event != null) {
            _ = c.CloseHandle(self.clipboard_event);
            self.clipboard_event = null;
        }

        // SSH cleanup
        if (self.ssh_prompt_owned) |buf| {
            self.alloc.free(buf);
            self.ssh_prompt_owned = null;
        }
        if (self.ssh_password) |password| {
            // Clear password from memory
            @memset(@constCast(password), 0);
            self.alloc.free(password);
            self.ssh_password = null;
        }
    }
};

// =========================================================================
// App window data helpers
// =========================================================================

pub fn getApp(hwnd: c.HWND) ?*App {
    const ptr = c.GetWindowLongPtrW(hwnd, c.GWLP_USERDATA);
    if (ptr == 0) return null;
    return @ptrFromInt(@as(usize, @bitCast(ptr)));
}

pub fn setApp(hwnd: c.HWND, app_ptr: *App) void {
    _ = c.SetWindowLongPtrW(hwnd, c.GWLP_USERDATA, @bitCast(@intFromPtr(app_ptr)));
}

// =========================================================================
// Render helpers (shared by main.zig and external_windows.zig)
// =========================================================================

/// Adjust brightness for cmdline background visibility (same as macOS).
/// Dark colors become slightly lighter (+0.05), light colors become slightly darker (-0.05).
/// Uses RGB to HSB conversion.
pub fn adjustBrightnessForCmdline(r: f32, g: f32, b: f32) [3]f32 {
    // Convert RGB to HSB (same as HSV)
    const max_c = @max(r, @max(g, b));
    const min_c = @min(r, @min(g, b));
    const delta = max_c - min_c;

    // Brightness (V in HSV)
    var brightness = max_c;

    // Saturation
    var saturation: f32 = 0.0;
    if (max_c > 0) {
        saturation = delta / max_c;
    }

    // Hue (not needed for adjustment but kept for completeness)
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

    // Adjust brightness: if dark (b < 0.5), lighten; if light, darken
    if (brightness < 0.5) {
        brightness = @min(brightness + 0.05, 1.0);
    } else {
        brightness = @max(brightness - 0.05, 0.0);
    }

    // Convert HSB back to RGB
    if (saturation == 0) {
        return .{ brightness, brightness, brightness };
    }

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
    verts: []core.Vertex,
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
        .{ x, y }, .{ x + w, y }, .{ x + w, y - h }, // Triangle 1
        .{ x, y }, .{ x + w, y - h }, .{ x, y - h }, // Triangle 2
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

/// Add search icon (magnifying glass) vertices using SDF
/// Icon area: top-left (x, y), bottom-right (x+w, y-h)
/// Returns 12 vertices (2 quads: circle + handle, rendered via shader SDF)
pub fn addSearchIconVerts(
    verts: []core.Vertex,
    start_idx: usize,
    x: f32,
    y: f32,
    w: f32,
    h: f32,
    color: [4]f32,
    grid_id: i64,
) usize {
    // Same margin percentage for both axes -> visually square on screen
    const margin = 0.15;
    const safe_x = x + w * margin;
    const safe_y = y - h * margin;
    const safe_w = w * (1.0 - 2.0 * margin);
    const safe_h = h * (1.0 - 2.0 * margin);

    var idx = start_idx;

    // Circle quad (6 vertices) - rendered via shader SDF
    // uv.x = -2.0 (ICON_CIRCLE), uv.y = local_x, deco_phase = local_y
    const circle_tex_x: f32 = -2.0;
    const quad_positions = [_][2]f32{
        .{ safe_x, safe_y }, // top-left
        .{ safe_x + safe_w, safe_y }, // top-right
        .{ safe_x, safe_y - safe_h }, // bottom-left
        .{ safe_x + safe_w, safe_y }, // top-right
        .{ safe_x + safe_w, safe_y - safe_h }, // bottom-right
        .{ safe_x, safe_y - safe_h }, // bottom-left
    };
    const local_uvs = [_][2]f32{
        .{ 0.0, 0.0 }, // top-left
        .{ 1.0, 0.0 }, // top-right
        .{ 0.0, 1.0 }, // bottom-left
        .{ 1.0, 0.0 }, // top-right
        .{ 1.0, 1.0 }, // bottom-right
        .{ 0.0, 1.0 }, // bottom-left
    };

    for (quad_positions, local_uvs) |pos, luv| {
        verts[idx] = .{
            .position = pos,
            .texCoord = .{ circle_tex_x, luv[0] }, // uv.y = local_x
            .color = color,
            .grid_id = grid_id,
            .deco_flags = 0,
            .deco_phase = luv[1], // local_y
        };
        idx += 1;
    }

    // Handle quad (6 vertices) - rendered via shader SDF
    // uv.x = -4.0 (ICON_HANDLE), uv.y = local_x, deco_phase = local_y
    const handle_tex_x: f32 = -4.0;

    for (quad_positions, local_uvs) |pos, luv| {
        verts[idx] = .{
            .position = pos,
            .texCoord = .{ handle_tex_x, luv[0] },
            .color = color,
            .grid_id = grid_id,
            .deco_flags = 0,
            .deco_phase = luv[1],
        };
        idx += 1;
    }

    return idx;
}

/// Add chevron right icon (>) vertices using SDF
/// Icon area: top-left (x, y), bottom-right (x+w, y-h)
/// Returns 6 vertices (1 quad, rendered via shader SDF)
pub fn addChevronIconVerts(
    verts: []core.Vertex,
    start_idx: usize,
    x: f32,
    y: f32,
    w: f32,
    h: f32,
    color: [4]f32,
    grid_id: i64,
) usize {
    // Same margin percentage for both axes -> visually square on screen
    const margin = 0.18;
    const safe_x = x + w * margin;
    const safe_y = y - h * margin;
    const safe_w = w * (1.0 - 2.0 * margin);
    const safe_h = h * (1.0 - 2.0 * margin);

    var idx = start_idx;

    // Chevron quad (6 vertices) - rendered via shader SDF
    // uv.x = -3.0 (ICON_CHEVRON), uv.y = local_x, deco_phase = local_y
    const chevron_tex_x: f32 = -3.0;
    const positions = [_][2]f32{
        .{ safe_x, safe_y }, // top-left
        .{ safe_x + safe_w, safe_y }, // top-right
        .{ safe_x, safe_y - safe_h }, // bottom-left
        .{ safe_x + safe_w, safe_y }, // top-right
        .{ safe_x + safe_w, safe_y - safe_h }, // bottom-right
        .{ safe_x, safe_y - safe_h }, // bottom-left
    };
    const local_uvs = [_][2]f32{
        .{ 0.0, 0.0 }, // top-left
        .{ 1.0, 0.0 }, // top-right
        .{ 0.0, 1.0 }, // bottom-left
        .{ 1.0, 0.0 }, // top-right
        .{ 1.0, 1.0 }, // bottom-right
        .{ 0.0, 1.0 }, // bottom-left
    };

    for (positions, local_uvs) |pos, luv| {
        verts[idx] = .{
            .position = pos,
            .texCoord = .{ chevron_tex_x, luv[0] }, // uv.y = local_x
            .color = color,
            .grid_id = grid_id,
            .deco_flags = 0,
            .deco_phase = luv[1], // local_y
        };
        idx += 1;
    }

    return idx;
}

// =========================================================================
// Layout helpers (shared by main.zig and callbacks.zig)
// =========================================================================

/// Get effective content width (subtracts scrollbar width in "always" mode)
pub fn getEffectiveContentWidth(app: *App, client_width: u32) u32 {
    if (app.config.scrollbar.enabled and app.config.scrollbar.isAlways()) {
        const scrollbar_reserved: u32 = @intFromFloat(scrollbarReservedWidth(app.dpi_scale));
        if (client_width > scrollbar_reserved) {
            return client_width - scrollbar_reserved;
        }
    }
    return client_width;
}

pub fn updateLayoutToCore(hwnd: c.HWND, app: *App) void {
    if (app.corep == null) return;

    var rc: c.RECT = undefined;
    // When content_hwnd exists, use its client rect (already excludes tabbar area)
    const target_hwnd = if (app.content_hwnd) |ch| ch else hwnd;
    _ = c.GetClientRect(target_hwnd, &rc);

    const client_w: u32 = @intCast(@max(1, rc.right - rc.left));
    const client_h: u32 = @intCast(@max(1, rc.bottom - rc.top));

    // Subtract sidebar width for sidebar mode
    const sidebar_w: u32 = if (app.ext_tabline_enabled and app.tabline_style == .sidebar)
        @intCast(app.scalePx(@as(c_int, @intCast(app.sidebar_width_px))))
    else
        0;

    // In "always" mode, reserve space for scrollbar
    const w_after_scrollbar = getEffectiveContentWidth(app, client_w);
    const w = if (w_after_scrollbar > sidebar_w) w_after_scrollbar - sidebar_w else 1;

    // For DWM custom titlebar without content_hwnd: client area includes titlebar,
    // so subtract tabbar height to get the actual content area for Neovim.
    // When using content_hwnd, it already has the correct size (excludes tabbar).
    const tabbar_height: u32 = if (app.ext_tabline_enabled and app.tabline_style == .titlebar and app.content_hwnd == null)
        @intCast(app.scalePx(TablineState.TAB_BAR_HEIGHT))
    else
        0;
    const h = if (client_h > tabbar_height) client_h - tabbar_height else 1;

    const cw: u32 = @max(1, app.cell_w_px);
    const ch: u32 = @max(1, app.cell_h_px + app.linespace_px);

    if (applog.isEnabled()) applog.appLog(
        "[win] updateLayoutToCore px=({d},{d}) cell=({d},{d})\n",
        .{ w, h, cw, ch },
    );
    core.zonvie_core_update_layout_px(app.corep, w, h, cw, ch);

    // Override screen_cols with monitor work area minus margin (matching macOS).
    // updateLayoutPxLocked sets screen_cols = drawable_cols, but for cmdline
    // max width we want the screen-based value with margin subtracted.
    if (app.hwnd) |main_hwnd| {
        const monitor = c.MonitorFromWindow(main_hwnd, c.MONITOR_DEFAULTTONEAREST);
        if (monitor) |mon| {
            var mi: c.MONITORINFO = std.mem.zeroes(c.MONITORINFO);
            mi.cbSize = @sizeOf(c.MONITORINFO);
            if (c.GetMonitorInfoW(mon, &mi) != 0) {
                const work_w: u32 = @intCast(@max(1, mi.rcWork.right - mi.rcWork.left));
                const overhead: u32 = CMDLINE_PADDING * 2 + CMDLINE_ICON_MARGIN_LEFT + CMDLINE_ICON_SIZE + CMDLINE_ICON_MARGIN_RIGHT + CMDLINE_SCREEN_MARGIN;
                const available_w: u32 = if (work_w > overhead) work_w - overhead else 1;
                const screen_cols: u32 = @max(40, available_w / cw);
                core.zonvie_core_set_screen_cols(app.corep, screen_cols);
            }
        }
    }
}

pub fn rowHeightPxFromClient(hwnd: c.HWND, rows: u32, fallback: u32) u32 {
    // Always use the fallback (cell_h + linespace) as the authoritative row height.
    // The division-based calculation (client_h / rows) is unreliable when Neovim's
    // row count doesn't match the frontend's expected row count (e.g., during
    // linespace changes where rows haven't been synchronized yet).
    _ = hwnd;
    _ = rows;
    return fallback;
}

pub fn updateRowsColsFromClientForce(hwnd: c.HWND, app: *App) void {
    var rc: c.RECT = undefined;
    // When content_hwnd exists, use its client rect (already excludes tabbar area)
    const target_hwnd = if (app.content_hwnd) |ch| ch else hwnd;
    _ = c.GetClientRect(target_hwnd, &rc);

    const client_w: u32 = @intCast(@max(1, rc.right - rc.left));
    const client_h: u32 = @intCast(@max(1, rc.bottom - rc.top));

    // Subtract sidebar width for sidebar mode
    const sidebar_w: u32 = if (app.ext_tabline_enabled and app.tabline_style == .sidebar)
        @intCast(app.scalePx(@as(c_int, @intCast(app.sidebar_width_px))))
    else
        0;

    // In "always" mode, use effective content width
    const w_after_scrollbar = getEffectiveContentWidth(app, client_w);
    const w = if (w_after_scrollbar > sidebar_w) w_after_scrollbar - sidebar_w else 1;

    // Subtract tabbar height when ext_tabline is enabled but content_hwnd doesn't exist
    // When using content_hwnd, it already has the correct size (excludes tabbar).
    const tabbar_height: u32 = if (app.ext_tabline_enabled and app.tabline_style == .titlebar and app.content_hwnd == null)
        @intCast(app.scalePx(TablineState.TAB_BAR_HEIGHT))
    else
        0;
    const h = if (client_h > tabbar_height) client_h - tabbar_height else 1;

    const cw: u32 = @max(1, app.cell_w_px);
    const ch: u32 = @max(1, app.cell_h_px + app.linespace_px);

    const rows: u32 = @intCast(@max(1, h / ch));
    const cols: u32 = @intCast(@max(1, w / cw));

    if (rows != app.surface.rows or cols != app.surface.cols) {
        app.surface.rows = rows;
        app.surface.cols = cols;
        app.seed_pending = true;
        app.seed_clear_pending = true;
        app.row_valid_count = 0;
        app.row_mode_max_row_end = 0;
        app.row_layout_gen +%= 1;
        if (rows != 0) {
            app.row_valid.resize(app.alloc, @intCast(rows), false) catch {};
            app.row_valid.unsetAll();
        } else if (app.row_valid.bit_length != 0) {
            app.row_valid.unsetAll();
        }
        // Clear old row vertex data to prevent ghost rendering from stale vertices.
        for (app.surface.row_verts.items) |*rv| {
            rv.verts.clearRetainingCapacity();
            rv.gen +%= 1;
        }
        if (applog.isEnabled()) applog.appLog(
            "[win] bootstrap rows/cols from client rows={d} cols={d} cell={d}x{d} client={d}x{d} row_mode_max_row_end=0\n",
            .{ rows, cols, cw, ch, w, h },
        );
    }
}
