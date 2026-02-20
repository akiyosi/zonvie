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
pub const zonvie_core_load_config = core.zonvie_core_load_config;
pub const zonvie_core_route_message = core.zonvie_core_route_message;
pub const zonvie_core_request_quit = core.zonvie_core_request_quit;
pub const zonvie_core_quit_confirmed = core.zonvie_core_quit_confirmed;
pub const zonvie_core_send_stdin_data = core.zonvie_core_send_stdin_data;
pub const zonvie_core_send_command = core.zonvie_core_send_command;
pub const zonvie_core_set_background_opacity = core.zonvie_core_set_background_opacity;

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

/// Pending vertices for an external window that hasn't been created yet
pub const PendingExternalVertices = struct {
    grid_id: i64,
    verts: std.ArrayListUnmanaged(Vertex) = .{},
    rows: u32,
    cols: u32,

    pub fn deinit(self: *PendingExternalVertices, alloc: std.mem.Allocator) void {
        self.verts.deinit(alloc);
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
            applog.appLog("[tray] added tray icon\n", .{});
        }
    }

    pub fn remove(self: *TrayIcon) void {
        if (self.added) {
            _ = c.Shell_NotifyIconW(c.NIM_DELETE, &self.nid);
            self.added = false;
            applog.appLog("[tray] removed tray icon\n", .{});
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
        @memcpy(self.nid.szInfoTitle[0..title_len + 1], title_buf[0..title_len + 1]);

        // Copy msg to szInfo (max 255 chars + null)
        var msg_buf: [256]u16 = undefined;
        const msg_len = @min(msg_text.len, 255);
        for (0..msg_len) |i| {
            msg_buf[i] = msg_text[i];
        }
        msg_buf[msg_len] = 0;
        @memcpy(self.nid.szInfo[0..msg_len + 1], msg_buf[0..msg_len + 1]);

        _ = c.Shell_NotifyIconW(c.NIM_MODIFY, &self.nid);
        applog.appLog("[tray] showBalloon: title='{s}' msg='{s}'\n", .{ title, msg_text });
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

pub const RowVerts = struct {
    verts: std.ArrayListUnmanaged(Vertex) = .{},

    // Row-local GPU VB (D3D11). Kept in App so WM_PAINT can bind per row.
    vb: ?*c.ID3D11Buffer = null,
    vb_bytes: usize = 0,

    // CPU-side generation increments when verts are replaced by onVerticesRow().
    gen: u64 = 0,
    // Last uploaded generation to vb.
    uploaded_gen: u64 = 0,
};

/// External window state for win_external_pos grids
pub const ExternalWindow = struct {
    hwnd: c.HWND,
    win_id: i64 = 0, // Neovim window handle
    renderer: d3d11.Renderer,
    verts: std.ArrayListUnmanaged(Vertex) = .{},
    vb: ?*c.ID3D11Buffer = null,
    vb_bytes: usize = 0,
    vert_count: usize = 0,
    rows: u32 = 0,
    cols: u32 = 0,
    needs_redraw: bool = false,
    needs_renderer_resize: bool = false, // Deferred renderer resize (to avoid deadlock)
    needs_window_resize: bool = false, // Deferred window resize (to avoid deadlock with WM_SIZE)
    pending_window_w: c_int = 0, // Pending window width for deferred resize
    pending_window_h: c_int = 0, // Pending window height for deferred resize
    atlas_version: u64 = 0, // Last atlas version uploaded to this window's D3D context
    scroll_accum: i16 = 0, // Accumulated vertical scroll delta for high-resolution scrolling
    h_scroll_accum: i16 = 0, // Accumulated horizontal scroll delta
    cached_bg_color: ?[3]f32 = null, // Cached background color for cmdline (persists across redraws)
    cursor_blink_state: bool = true, // Cursor blink state (true = visible)

    // When true, suppress tryResizeGrid in WM_SIZE handler (programmatic resize from grid_resize).
    suppress_resize_callback: bool = false,

    // Close state - set when window is scheduled for closing (don't paint or access renderer)
    is_pending_close: bool = false,

    // Paint reference count - prevents freeing while paint is in progress
    // DXGI operations can pump Win32 messages, so close could be triggered during paint.
    // This counter ensures ext_win isn't freed until all paint operations complete.
    paint_ref_count: u32 = 0,

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

    pub fn deinit(self: *ExternalWindow, alloc: std.mem.Allocator) void {
        // Clear user data first to prevent WndProc from accessing App during destruction
        _ = c.SetWindowLongPtrW(self.hwnd, c.GWLP_USERDATA, 0);

        // Destroy window first (this will process WM_DESTROY etc.)
        _ = c.DestroyWindow(self.hwnd);

        // Now safe to release D3D resources
        self.paint_scratch.deinit(alloc);
        self.verts.deinit(alloc);
        if (self.vb) |vb| {
            _ = vb.lpVtbl.*.Release.?(vb);
        }
        self.renderer.deinit();
    }
};

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

    // Latest plan snapshot (copied from callback; valid beyond callback)
    bg_spans: std.ArrayListUnmanaged(BgSpan) = .{},

    // IMPORTANT:
    // Keep the exact C-compatible layout for renderer: core.TextRun (scalars is a pointer).
    text_runs: std.ArrayListUnmanaged(TextRun) = .{},

    // Vertices path (match macOS)
    main_verts: std.ArrayListUnmanaged(Vertex) = .{},
    cursor_verts: std.ArrayListUnmanaged(Vertex) = .{},
    // Last cursor rectangle in client pixels (derived from cursor_verts).
    last_cursor_rect_px: ?c.RECT = null,

    // Row-mode vertex storage (like macOS rowVertexBuffers/Counts)
    row_verts: std.ArrayListUnmanaged(RowVerts) = .{},

    // Scratch buffer for WM_PAINT(row): per-row vertex copy.
    // Reused to avoid per-paint alloc/free.
    row_tmp_verts: std.ArrayListUnmanaged(Vertex) = .{},

    // WM_PAINT(row) persistent buffers (avoid per-frame alloc/free)
    wm_paint_rows_to_draw: std.ArrayListUnmanaged(u32) = .{},
    wm_paint_present_rects: std.ArrayListUnmanaged(c.RECT) = .{},

    // Cursor overlay VB for row-mode (avoid extra g.drawEx per paint).
    cursor_vb: ?*c.ID3D11Buffer = null,
    cursor_vb_bytes: usize = 0,

    // Owned scalar buffers corresponding to each text run (same order as text_runs).
    text_run_scalars: std.ArrayListUnmanaged([]u32) = .{},

    cursor: ?Cursor = null,

    dirty_rows: std.AutoHashMapUnmanaged(u32, void) = .{},
    row_mode: bool = false,
    row_mode_max_row_end: u32 = 0,

    // ---- NEW: self-managed damage queue (avoid OS update region dependency) ----
    paint_rects: std.ArrayListUnmanaged(c.RECT) = .{},
    paint_full: bool = false,

    // Scrollbar update coalescing: set by on_flush_end (core thread), cleared by WM_APP_UPDATE_SCROLLBAR (UI thread).
    scrollbar_update_pending: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

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
    // Row-mode seed tracking: require a full set of rows before presenting.
    seed_pending: bool = true,
    seed_clear_pending: bool = true,
    row_valid: std.DynamicBitSetUnmanaged = .{},
    row_valid_count: u32 = 0,
    row_layout_gen: u64 = 0,

    rows: u32 = 0,
    cols: u32 = 0,

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
        if (self.row_verts.items.len >= need) return;

        // grow row_verts to (row+1)
        const old_len = self.row_verts.items.len;
        self.row_verts.resize(self.alloc, need) catch return;

        // init new slots
        var i: usize = old_len;
        while (i < need) : (i += 1) {
            self.row_verts.items[i] = .{};
        }
    }

    /// Shrink row_verts if significantly oversized (> 2x needed)
    pub fn maybeShrinkRowStorage(self: *App, needed_rows: u32) void {
        if (needed_rows == 0) return;
        const needed: usize = @intCast(needed_rows);
        // Only shrink if array is more than 2x the needed size
        if (self.row_verts.items.len > needed * 2) {
            // Free excess RowVerts' inner arrays
            for (self.row_verts.items[needed..]) |*rv| {
                rv.verts.deinit(self.alloc);
            }
            self.row_verts.shrinkRetainingCapacity(needed);
            if (applog.isEnabled()) applog.appLog("[win] shrunk row_verts from {d} to {d}\n", .{ self.row_verts.items.len + (self.row_verts.items.len - needed), needed });
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

                // For main grid, use main window client area
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
        // Free owned text-run scalar buffers first
        for (self.text_run_scalars.items) |buf| {
            self.alloc.free(buf);
        }
        self.text_run_scalars.deinit(self.alloc);

        // Then drop the C-layout run array itself
        self.text_runs.deinit(self.alloc);

        // Bg spans
        self.bg_spans.deinit(self.alloc);

        self.main_verts.deinit(self.alloc);
        self.cursor_verts.deinit(self.alloc);

        // Row-mode vertex storage
        for (self.row_verts.items) |*rv| {
            // Release per-row VB if any
            if (rv.vb) |p| {
                const rel = p.*.lpVtbl.*.Release orelse null;
                if (rel) |f| _ = f(p);
                rv.vb = null;
                rv.vb_bytes = 0;
            }

            rv.verts.deinit(self.alloc);
        }
        self.row_verts.deinit(self.alloc);

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

        self.dirty_rows.deinit(self.alloc);

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
        .{ safe_x, safe_y },                   // top-left
        .{ safe_x + safe_w, safe_y },          // top-right
        .{ safe_x, safe_y - safe_h },          // bottom-left
        .{ safe_x + safe_w, safe_y },          // top-right
        .{ safe_x + safe_w, safe_y - safe_h }, // bottom-right
        .{ safe_x, safe_y - safe_h },          // bottom-left
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
        .{ safe_x, safe_y },                   // top-left
        .{ safe_x + safe_w, safe_y },          // top-right
        .{ safe_x, safe_y - safe_h },          // bottom-left
        .{ safe_x + safe_w, safe_y },          // top-right
        .{ safe_x + safe_w, safe_y - safe_h }, // bottom-right
        .{ safe_x, safe_y - safe_h },          // bottom-left
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

    applog.appLog(
        "[win] updateLayoutToCore px=({d},{d}) cell=({d},{d})\n",
        .{ w, h, cw, ch },
    );
    core.zonvie_core_update_layout_px(app.corep, w, h, cw, ch);

    // Note: screen_cols is now set automatically inside updateLayoutPxLocked
    // to avoid deadlock issues when called from within redraw callbacks.
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

    if (rows != app.rows or cols != app.cols) {
        app.rows = rows;
        app.cols = cols;
        app.seed_pending = true;
        app.seed_clear_pending = true;
        app.row_valid_count = 0;
        app.row_layout_gen +%= 1;
        if (rows != 0) {
            app.row_valid.resize(app.alloc, @intCast(rows), false) catch {};
            app.row_valid.unsetAll();
        } else if (app.row_valid.bit_length != 0) {
            app.row_valid.unsetAll();
        }
        // Clear old row vertex data to prevent ghost rendering from stale vertices.
        for (app.row_verts.items) |*rv| {
            rv.verts.clearRetainingCapacity();
            rv.gen +%= 1;
        }
        applog.appLog(
            "[win] bootstrap rows/cols from client rows={d} cols={d} cell={d}x{d} client={d}x{d}\n",
            .{ rows, cols, cw, ch, w, h },
        );
    }
}
