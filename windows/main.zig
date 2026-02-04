const std = @import("std");
const core = @import("zonvie_core");
const dwrite_d2d = @import("dwrite_d2d_renderer.zig");
const d3d11 = @import("d3d11_renderer.zig");
const c = @import("win32.zig").c;
const applog = @import("app_log.zig");
const builtin = @import("builtin");
const config_mod = @import("config.zig");

// Global exit code for Nvy-style exit (returned from main instead of ExitProcess)
var g_exit_code: std.atomic.Value(u8) = std.atomic.Value(u8).init(0);

pub const std_options = std.Options{
    .log_level = .debug,
    .enable_segfault_handler = true,
};

/// Custom panic handler for debug builds that prints stack traces.
/// In release builds, falls back to std default behavior.
pub fn panic(
    msg: []const u8,
    error_return_trace: ?*std.builtin.StackTrace,
    ret_addr: ?usize,
) noreturn {
    @branchHint(.cold);

    // In release builds, just use the default behavior
    if (builtin.mode != .Debug) {
        std.debug.defaultPanic(msg, ret_addr);
    }

    // Print panic message using std.debug.print (unbuffered to stderr)
    std.debug.print("\n=== ZONVIE PANIC (Debug Build) ===\n", .{});
    std.debug.print("Panic: {s}\n", .{msg});

    // Also log to app log if enabled
    if (applog.isEnabled()) {
        applog.appLog("\n=== ZONVIE PANIC (Debug Build) ===\n", .{});
        applog.appLog("Panic: {s}\n", .{msg});
    }

    // Print error return trace if available
    if (error_return_trace) |trace| {
        std.debug.print("\nError return trace:\n", .{});
        if (applog.isEnabled()) {
            applog.appLog("\nError return trace:\n", .{});
        }
        printStackTraceAddresses(trace);
    }

    // Print stack trace from current location
    std.debug.print("\nStack trace:\n", .{});
    if (applog.isEnabled()) {
        applog.appLog("\nStack trace:\n", .{});
    }
    var it = std.debug.StackIterator.init(ret_addr orelse @returnAddress(), @frameAddress());
    var addr_buf: [32]usize = undefined;
    var addr_count: usize = 0;

    // Collect addresses
    while (addr_count < addr_buf.len) {
        if (it.next()) |addr| {
            addr_buf[addr_count] = addr;
            addr_count += 1;
        } else break;
    }

    // Print addresses
    for (addr_buf[0..addr_count]) |addr| {
        std.debug.print("  0x{x:0>16}\n", .{addr});
        if (applog.isEnabled()) {
            applog.appLog("  0x{x:0>16}\n", .{addr});
        }
    }

    std.debug.print("\n=== END PANIC ===\n", .{});
    if (applog.isEnabled()) {
        applog.appLog("\n=== END PANIC ===\n", .{});
    }

    // Show message box so user can see the error on Windows
    const wide_title = comptime blk: {
        const title = "Zonvie Panic (Debug)";
        var buf: [title.len + 1]u16 = undefined;
        for (title, 0..) |ch, i| buf[i] = ch;
        buf[title.len] = 0;
        break :blk buf;
    };
    const wide_msg = comptime blk: {
        const m = "A panic occurred. Check stderr/log for stack trace.";
        var buf: [m.len + 1]u16 = undefined;
        for (m, 0..) |ch, i| buf[i] = ch;
        buf[m.len] = 0;
        break :blk buf;
    };
    _ = c.MessageBoxW(null, &wide_msg, &wide_title, c.MB_OK | c.MB_ICONERROR);

    std.process.abort();
}

fn printStackTraceAddresses(trace: *std.builtin.StackTrace) void {
    for (trace.instruction_addresses[0..@min(trace.index, trace.instruction_addresses.len)]) |addr| {
        std.debug.print("  0x{x:0>16}\n", .{addr});
        if (applog.isEnabled()) {
            applog.appLog("  0x{x:0>16}\n", .{addr});
        }
    }
}

const WM_APP_ATLAS_ENSURE_GLYPH: c.UINT = c.WM_APP + 1;
const WM_APP_CREATE_EXTERNAL_WINDOW: c.UINT = c.WM_APP + 2;
const WM_APP_CURSOR_GRID_CHANGED: c.UINT = c.WM_APP + 3;
const WM_APP_CLOSE_EXTERNAL_WINDOW: c.UINT = c.WM_APP + 4;
const WM_APP_DEFERRED_INIT: c.UINT = c.WM_APP + 5;
const WM_APP_UPDATE_IME_POSITION: c.UINT = c.WM_APP + 6;
const WM_APP_MSG_SHOW: c.UINT = c.WM_APP + 7;
const WM_APP_MSG_CLEAR: c.UINT = c.WM_APP + 8;
const WM_APP_MINI_UPDATE: c.UINT = c.WM_APP + 9;
const WM_APP_CLIPBOARD_GET: c.UINT = c.WM_APP + 10;
const WM_APP_CLIPBOARD_SET: c.UINT = c.WM_APP + 11;
const WM_APP_SSH_AUTH_PROMPT: c.UINT = c.WM_APP + 12;
const WM_APP_UPDATE_SCROLLBAR: c.UINT = c.WM_APP + 13;
const WM_APP_UPDATE_EXT_FLOAT_POS: c.UINT = c.WM_APP + 14;
const WM_APP_TRAY: c.UINT = c.WM_APP + 15;
const WM_APP_UPDATE_CURSOR_BLINK: c.UINT = c.WM_APP + 16;
const WM_APP_IME_OFF: c.UINT = c.WM_APP + 17;
const WM_APP_TABLINE_INVALIDATE: c.UINT = c.WM_APP + 18;
const WM_APP_QUIT_REQUESTED: c.UINT = c.WM_APP + 19;
const WM_APP_QUIT_TIMEOUT: c.UINT = c.WM_APP + 20;

/// Timer ID for message window auto-hide
const TIMER_MSG_AUTOHIDE: c.UINT_PTR = 1;
/// Timer ID for mini window auto-hide
const TIMER_MINI_AUTOHIDE: c.UINT_PTR = 10;
/// Message auto-hide timeout in milliseconds (4 seconds)
const MSG_AUTOHIDE_TIMEOUT: c.UINT = 4000;
/// Timer ID for devcontainer polling
const TIMER_DEVCONTAINER_POLL: c.UINT_PTR = 2;
/// Devcontainer poll interval in milliseconds (500ms)
const DEVCONTAINER_POLL_INTERVAL: c.UINT = 500;
/// Timer ID for scrollbar auto-hide
const TIMER_SCROLLBAR_AUTOHIDE: c.UINT_PTR = 3;
/// Timer ID for scrollbar fade animation
const TIMER_SCROLLBAR_FADE: c.UINT_PTR = 4;
/// Timer ID for scrollbar track repeat (continuous page scroll when holding)
const TIMER_SCROLLBAR_REPEAT: c.UINT_PTR = 5;
/// Timer ID for cursor blink
const TIMER_CURSOR_BLINK: c.UINT_PTR = 6;
/// Timer ID for quit request timeout
const TIMER_QUIT_TIMEOUT: c.UINT_PTR = 7;
/// Quit timeout in milliseconds (5 seconds)
const QUIT_TIMEOUT_MS: c.UINT = 5000;
/// Scrollbar fade animation interval (16ms ~= 60fps)
const SCROLLBAR_FADE_INTERVAL: c.UINT = 16;
/// Scrollbar repeat interval (ms) for continuous page scroll
const SCROLLBAR_REPEAT_DELAY: c.UINT = 400; // Initial delay before repeat
const SCROLLBAR_REPEAT_INTERVAL: c.UINT = 100; // Interval during repeat
/// Custom scrollbar constants
const SCROLLBAR_WIDTH: f32 = 12.0; // Width in pixels
const SCROLLBAR_MARGIN: f32 = 2.0; // Margin from edge
const SCROLLBAR_MIN_KNOB_HEIGHT: f32 = 20.0; // Minimum knob height
const SCROLLBAR_CORNER_RADIUS: f32 = 4.0; // Corner radius (cosmetic, not implemented yet)
/// Reserved grid ID for ext_cmdline (same as grid.zig CMDLINE_GRID_ID)
const CMDLINE_GRID_ID: i64 = -100;
/// Reserved grid ID for ext_popupmenu (same as grid.zig POPUPMENU_GRID_ID)
const POPUPMENU_GRID_ID: i64 = -101;
/// Reserved grid ID for ext_messages
const MESSAGE_GRID_ID: i64 = -102;
/// Reserved grid ID for msg_history (same as grid.zig MSG_HISTORY_GRID_ID)
const MSG_HISTORY_GRID_ID: i64 = -103;

// --- Cmdline window styling constants (matching macOS) ---
const CMDLINE_PADDING: u32 = 12; // Padding around content (pixels)
const CMDLINE_ICON_SIZE: u32 = 18; // Icon size (pixels)
const CMDLINE_ICON_MARGIN_LEFT: u32 = 2; // Left margin for icon (pixels)
const CMDLINE_ICON_MARGIN_RIGHT: u32 = 4; // Right margin for icon (pixels)
const CMDLINE_BORDER_WIDTH: u32 = 1; // Border width (pixels)
const CMDLINE_CORNER_RADIUS: f32 = 8.0; // Corner radius for rounded rect

// --- Msg_show window styling constants ---
const MSG_PADDING: u32 = 8; // Padding around content (pixels)

/// Pending external window creation request
const PendingExternalWindow = struct {
    grid_id: i64,
    win: i64,
    rows: u32,
    cols: u32,
    start_row: i32, // -1 if no position info (cmdline, etc.)
    start_col: i32,
};

/// Pending vertices for an external window that hasn't been created yet
const PendingExternalVertices = struct {
    grid_id: i64,
    verts: std.ArrayListUnmanaged(core.Vertex) = .{},
    rows: u32,
    cols: u32,

    fn deinit(self: *PendingExternalVertices, alloc: std.mem.Allocator) void {
        self.verts.deinit(alloc);
    }
};

/// Tray icon for balloon notifications (OS notification view type)
const TrayIcon = struct {
    nid: c.NOTIFYICONDATAW,
    added: bool = false,

    fn init(hwnd: c.HWND) TrayIcon {
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

    fn add(self: *TrayIcon) void {
        if (!self.added) {
            _ = c.Shell_NotifyIconW(c.NIM_ADD, &self.nid);
            self.added = true;
            applog.appLog("[tray] added tray icon\n", .{});
        }
    }

    fn remove(self: *TrayIcon) void {
        if (self.added) {
            _ = c.Shell_NotifyIconW(c.NIM_DELETE, &self.nid);
            self.added = false;
            applog.appLog("[tray] removed tray icon\n", .{});
        }
    }

    fn showBalloon(self: *TrayIcon, title: []const u8, msg_text: []const u8) void {
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
const PendingMessageRequest = struct {
    text: [8192]u8 = undefined,  // Large buffer for long messages (E325 can be 1100+ bytes)
    text_len: usize = 0,
    kind: [32]u8 = undefined,
    kind_len: usize = 0,
    hl_id: u32 = 0,  // Primary highlight ID
    replace_last: u32 = 0,  // 1 = replace last message
    append: u32 = 0,  // 1 = append to last message
    view_type: core.zonvie_msg_view_type = .ext_float,  // Routing result
    timeout: f32 = 4.0,  // Timeout in seconds
};

/// Stored message for display stack (keeps track of multiple messages)
const DisplayMessage = struct {
    text: [8192]u8 = undefined,
    text_len: usize = 0,
    kind: [32]u8 = undefined,
    kind_len: usize = 0,
    hl_id: u32 = 0,
    view_type: core.zonvie_msg_view_type = .ext_float,
    timeout: f32 = 4.0,
};

/// Mini window type identifier (for routing)
const MiniWindowId = enum(u2) {
    showmode = 0,
    showcmd = 1,
    ruler = 2,
};

/// Mini window state (one per type)
const MiniWindowState = struct {
    hwnd: ?c.HWND = null,
    text: [256]u8 = undefined,
    text_len: usize = 0,
};

/// Ext-float window state for ext_messages (uses GDI for simplicity)
const MessageWindow = struct {
    hwnd: c.HWND,
    text: [8192]u8 = undefined,  // Large buffer for long messages (E325 can be 1100+ bytes)
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

    fn deinit(self: *MessageWindow) void {
        _ = c.DestroyWindow(self.hwnd);
    }

    /// Get text color based on message kind
    fn getTextColor(self: *const MessageWindow) c.COLORREF {
        const kind_str = self.kind[0..self.kind_len];
        if (std.mem.eql(u8, kind_str, "emsg") or
            std.mem.eql(u8, kind_str, "echoerr") or
            std.mem.eql(u8, kind_str, "lua_error") or
            std.mem.eql(u8, kind_str, "rpc_error"))
        {
            return c.RGB(255, 102, 102);  // Red for errors
        } else if (std.mem.eql(u8, kind_str, "wmsg")) {
            return c.RGB(255, 217, 102);  // Yellow for warnings
        } else if (std.mem.eql(u8, kind_str, "confirm") or
            std.mem.eql(u8, kind_str, "confirm_sub") or
            std.mem.eql(u8, kind_str, "return_prompt"))
        {
            return c.RGB(153, 204, 255);  // Light blue for prompts
        } else if (std.mem.eql(u8, kind_str, "search_count")) {
            return c.RGB(153, 255, 153);  // Light green for search count
        }
        return c.RGB(220, 220, 220);  // Default light gray
    }
};

/// Tab entry for ext_tabline
const TabEntry = struct {
    handle: i64,
    name: [256]u8 = undefined,
    name_len: usize = 0,
};

/// Tabline state for ext_tabline (Chrome-style tabs in titlebar area)
const TablineState = struct {
    tabs: [32]TabEntry = undefined,  // Max 32 tabs
    tab_count: usize = 0,
    current_tab: i64 = 0,
    visible: bool = false,
    hovered_tab: ?usize = null,
    hovered_close: ?usize = null,
    hovered_window_btn: ?u8 = null,  // 0=min, 1=max, 2=close
    hovered_new_tab_btn: bool = false,
    hwnd: ?c.HWND = null,  // Child window for tabline

    // Pending invalidate flag: if tabline_update arrives before hwnd is created,
    // we need to trigger InvalidateRect after hwnd creation
    pending_invalidate: bool = false,

    // Drag state for tab reordering
    dragging_tab: ?usize = null,      // Index of tab being dragged
    drag_start_x: c_int = 0,          // Mouse X when drag started
    drag_offset_x: c_int = 0,         // Offset from tab left edge to mouse
    drag_current_x: c_int = 0,        // Current mouse X during drag
    drop_target_index: ?usize = null, // Where the tab would be dropped

    // External drag state (for tab externalization)
    is_external_drag: bool = false,
    drag_preview_hwnd: ?c.HWND = null,

    // Close button pressed state (for proper click handling)
    close_button_pressed: ?usize = null,  // Tab index of pressed close button

    // New tab button pressed state (for proper click handling)
    new_tab_button_pressed: bool = false,

    // Window button pressed state (for proper click handling on min/max/close)
    pressed_window_btn: ?u8 = null,  // 0=min, 1=max, 2=close

    // Tab bar constants
    const TAB_BAR_HEIGHT: c_int = 32;
    const TAB_MIN_WIDTH: c_int = 100;
    const TAB_MAX_WIDTH: c_int = 200;
    const TAB_PADDING: c_int = 8;
    const TAB_CLOSE_SIZE: c_int = 14;
    const WINDOW_CONTROLS_WIDTH: c_int = 0;  // Windows has controls on the right (no left offset needed)
    const DRAG_THRESHOLD: c_int = 5;  // Pixels to move before starting drag
    const EXTERNAL_DRAG_THRESHOLD: c_int = 50;  // Pixels outside window to trigger external drag

    // Window control buttons (right side)
    const WINDOW_BTN_WIDTH: c_int = 46;      // Each button width
    const WINDOW_BTN_COUNT: c_int = 3;       // Min, Max, Close
    const WINDOW_BTNS_TOTAL: c_int = WINDOW_BTN_WIDTH * WINDOW_BTN_COUNT;  // 138px total

    fn clear(self: *TablineState) void {
        self.tab_count = 0;
        self.current_tab = 0;
        self.visible = false;
    }

    fn cancelDrag(self: *TablineState) void {
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

// --- HSV color adjustment helpers for cmdline background ---
// --- add near the top (e.g. after WM_APP_ATLAS_ENSURE_GLYPH const) ---

// --- SSH Password Dialog state ---
var ssh_dlg_password: [256]u8 = undefined;
var ssh_dlg_password_len: usize = 0;
var ssh_dlg_result: bool = false;
var ssh_dlg_edit_hwnd: c.HWND = null;
var ssh_dlg_ok_hwnd: c.HWND = null;
var ssh_dlg_cancel_hwnd: c.HWND = null;

var log_atlas_ensure_calls: u64 = 0;
var log_atlas_ensure_suspicious: u64 = 0;
var log_atlas_ensure_last_report_ns: i128 = 0;
var log_atlas_zero_bbox_count: u32 = 0;
var log_row_no_glyphs_count: u32 = 0;
var log_row_bad_uv_count: u32 = 0;

// --- Startup timing globals ---
var g_startup_freq: c.LARGE_INTEGER = undefined;
var g_startup_t0: c.LARGE_INTEGER = undefined;

const RowVerts = struct {
    verts: std.ArrayListUnmanaged(core.Vertex) = .{},

    // Row-local GPU VB (D3D11). Kept in App so WM_PAINT can bind per row.
    vb: ?*c.ID3D11Buffer = null,
    vb_bytes: usize = 0,

    // CPU-side generation increments when verts are replaced by onVerticesRow().
    gen: u64 = 0,
    // Last uploaded generation to vb.
    uploaded_gen: u64 = 0,
};

/// External window state for win_external_pos grids
const ExternalWindow = struct {
    hwnd: c.HWND,
    renderer: d3d11.Renderer,
    verts: std.ArrayListUnmanaged(core.Vertex) = .{},
    vb: ?*c.ID3D11Buffer = null,
    vb_bytes: usize = 0,
    vert_count: usize = 0,
    rows: u32 = 0,
    cols: u32 = 0,
    needs_redraw: bool = false,
    needs_renderer_resize: bool = false, // Deferred renderer resize (to avoid deadlock)
    atlas_version: u64 = 0, // Last atlas version uploaded to this window's D3D context
    scroll_accum: i16 = 0, // Accumulated scroll delta for high-resolution scrolling
    cached_bg_color: ?[3]f32 = null, // Cached background color for cmdline (persists across redraws)
    cursor_blink_state: bool = true, // Cursor blink state (true = visible)

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

    fn deinit(self: *ExternalWindow, alloc: std.mem.Allocator) void {
        // Clear user data first to prevent WndProc from accessing App during destruction
        _ = c.SetWindowLongPtrW(self.hwnd, c.GWLP_USERDATA, 0);

        // Destroy window first (this will process WM_DESTROY etc.)
        _ = c.DestroyWindow(self.hwnd);

        // Now safe to release D3D resources
        self.verts.deinit(alloc);
        if (self.vb) |vb| {
            _ = vb.lpVtbl.*.Release.?(vb);
        }
        self.renderer.deinit();
    }
};

/// Pending glyph entry for deferred atlas population
/// (used when glyph is requested before atlas is ready)
const PendingGlyph = struct {
    scalar: u32,
    style_flags: u32, // 0 for unstyled
};

const App = struct {
    alloc: std.mem.Allocator,

    // Configuration loaded from config.toml
    config: config_mod.Config = .{},

    mu: std.Thread.Mutex = .{},

    hwnd: ?c.HWND = null,
    content_hwnd: ?c.HWND = null,  // Child window for D3D11 rendering (when ext_tabline enabled)
    corep: ?*core.zonvie_core = null,

    ui_thread_id: u32 = 0,

    // Atlas builder (DirectWrite + CPU atlas, metrics)
    atlas: ?dwrite_d2d.Renderer = null,

    // GPU renderer (D3D11)
    renderer: ?d3d11.Renderer = null,

    // External windows (grid_id -> ExternalWindow)
    external_windows: std.AutoHashMapUnmanaged(i64, ExternalWindow) = .{},

    // Pending external window creation requests (for UI thread processing)
    pending_external_windows: std.ArrayListUnmanaged(PendingExternalWindow) = .{},

    // Pending external window close requests (for UI thread processing)
    // Stores ExternalWindow structs that need to be destroyed on UI thread
    pending_close_windows: std.ArrayListUnmanaged(ExternalWindow) = .{},

    // Pending position for next external window (set by tab externalization)
    pending_external_window_position: ?struct { x: c_int, y: c_int } = null,
    pending_external_window_position_time: i64 = 0,  // Timestamp when position was set (for timeout)

    // Pending vertices for external windows that haven't been created yet
    pending_external_verts: std.ArrayListUnmanaged(PendingExternalVertices) = .{},

    // ext_messages window state
    message_window: ?MessageWindow = null,
    pending_messages: std.ArrayListUnmanaged(PendingMessageRequest) = .{},
    display_messages: std.ArrayListUnmanaged(DisplayMessage) = .{},  // Stack of visible messages

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
    bg_spans: std.ArrayListUnmanaged(core.BgSpan) = .{},

    // IMPORTANT:
    // Keep the exact C-compatible layout for renderer: core.TextRun (scalars is a pointer).
    text_runs: std.ArrayListUnmanaged(core.TextRun) = .{},

    // Vertices path (match macOS)
    main_verts: std.ArrayListUnmanaged(core.Vertex) = .{},
    cursor_verts: std.ArrayListUnmanaged(core.Vertex) = .{},
    // Last cursor rectangle in client pixels (derived from cursor_verts).
    last_cursor_rect_px: ?c.RECT = null,

    // Row-mode vertex storage (like macOS rowVertexBuffers/Counts)
    row_verts: std.ArrayListUnmanaged(RowVerts) = .{},

    // Scratch buffer for WM_PAINT(row): per-row vertex copy.
    // Reused to avoid per-paint alloc/free.
    row_tmp_verts: std.ArrayListUnmanaged(core.Vertex) = .{},

    // WM_PAINT(row) persistent buffers (avoid per-frame alloc/free)
    wm_paint_rows_to_draw: std.ArrayListUnmanaged(u32) = .{},
    wm_paint_present_rects: std.ArrayListUnmanaged(c.RECT) = .{},

    // Cursor overlay VB for row-mode (avoid extra g.drawEx per paint).
    cursor_vb: ?*c.ID3D11Buffer = null,
    cursor_vb_bytes: usize = 0,

    // Owned scalar buffers corresponding to each text run (same order as text_runs).
    text_run_scalars: std.ArrayListUnmanaged([]u32) = .{},

    cursor: ?core.Cursor = null,

    dirty_rows: std.AutoHashMapUnmanaged(u32, void) = .{},
    row_mode: bool = false,
    row_mode_max_row_end: u32 = 0,

    // ---- NEW: self-managed damage queue (avoid OS update region dependency) ----
    paint_rects: std.ArrayListUnmanaged(c.RECT) = .{},
    paint_full: bool = false,

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
    // Row-mode seed tracking: require a full set of rows before presenting.
    seed_pending: bool = true,
    seed_clear_pending: bool = true,
    row_valid: std.DynamicBitSetUnmanaged = .{},
    row_valid_count: u32 = 0,
    row_layout_gen: u64 = 0,

    rows: u32 = 0,
    cols: u32 = 0,

    linespace_px: u32 = 0,

    // cell metrics used for layout->core_update_layout_px
    cell_w_px: u32 = 9,
    cell_h_px: u32 = 18,

    // Timestamp of last WM_SIZE (ns since epoch).
    last_resize_ns: i128 = 0,

    // Mouse button tracking for drag events
    // 0 = none, 1 = left, 2 = right, 3 = middle
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

    // Scroll accumulator for high-resolution scrolling
    scroll_accum: i16 = 0,

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

    // WSL mode flags (set from --wsl command line arg or config)
    wsl_mode: bool = false,
    wsl_distro: ?[]const u8 = null,

    // SSH mode flags (set from --ssh command line arg or config)
    ssh_mode: bool = false,
    ssh_host: ?[]const u8 = null,
    ssh_port: ?u16 = null,
    ssh_identity: ?[]const u8 = null,
    ssh_password: ?[]const u8 = null,          // Password from dialog (freed after use)

    // Devcontainer mode flags (set from --devcontainer command line arg)
    devcontainer_mode: bool = false,
    devcontainer_workspace: ?[]const u8 = null,
    devcontainer_config: ?[]const u8 = null,
    devcontainer_rebuild: bool = false,
    devcontainer_up_pending: bool = false,  // Waiting for devcontainer up to complete
    devcontainer_nvim_started: bool = false,  // Nvim started in devcontainer mode

    // Extra arguments to pass to nvim (not recognized as zonvie arguments)
    nvim_extra_args: std.ArrayListUnmanaged([]const u8) = .{},

    // Startup timing: first WM_PAINT with nvim content
    first_paint_logged: bool = false,

    // Clipboard request state (for cross-thread clipboard operations)
    clipboard_event: c.HANDLE = null,  // Manual-reset event for sync
    clipboard_buf: [64 * 1024]u8 = undefined,
    clipboard_len: usize = 0,
    clipboard_result: c_int = 0,
    clipboard_set_data: ?[*]const u8 = null,
    clipboard_set_len: usize = 0,

    // SSH auth prompt state
    ssh_prompt_ptr: ?[*]const u8 = null,
    ssh_prompt_len: usize = 0,

    // Pending glyphs queue: glyphs requested before atlas was ready
    // (for parallel nvim spawn + renderer init)
    pending_glyphs: std.ArrayListUnmanaged(PendingGlyph) = .{},

    // Tray icon for OS notification (balloon notification)
    tray_icon: ?TrayIcon = null,

    /// Maximum row buffer count to prevent unbounded memory growth
    const max_row_buffers: u32 = 1000;

    fn ensureRowStorage(self: *App, row: u32) void {
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
    fn maybeShrinkRowStorage(self: *App, needed_rows: u32) void {
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
                        return c.RECT{
                            .left = pt.x,
                            .top = pt.y,
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
                        return c.RECT{
                            .left = pt.x,
                            .top = pt.y,
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
        for (self.pending_close_windows.items) |*pcw| {
            pcw.deinit(self.alloc);
        }
        self.pending_close_windows.deinit(self.alloc);
        for (self.pending_external_verts.items) |*pv| {
            pv.deinit(self.alloc);
        }
        self.pending_external_verts.deinit(self.alloc);

        if (self.renderer) |*r| r.deinit();
        self.renderer = null;

        if (self.atlas) |*a| a.deinit();
        self.atlas = null;

        if (self.corep) |p| core.zonvie_core_destroy(p);
        self.corep = null;

        // Clipboard event cleanup
        if (self.clipboard_event != null) {
            _ = c.CloseHandle(self.clipboard_event);
            self.clipboard_event = null;
        }

        // SSH cleanup
        if (self.ssh_password) |password| {
            // Clear password from memory
            @memset(@constCast(password), 0);
            self.alloc.free(password);
            self.ssh_password = null;
        }
    }
};

fn getApp(hwnd: c.HWND) ?*App {
    const v = c.GetWindowLongPtrW(hwnd, c.GWLP_USERDATA);
    if (v == 0) {
        return null;
    }

    const p: *App = @ptrFromInt(@as(usize, @bitCast(v)));
    return p;
}


fn setApp(hwnd: c.HWND, app: *App) void {
    _ = c.SetWindowLongPtrW(hwnd, c.GWLP_USERDATA, @as(c.LONG_PTR, @intCast(@intFromPtr(app))));
}

fn rectFromCursorVerts(hwnd: c.HWND, verts: []const core.Vertex) ?c.RECT {
    if (verts.len == 0) return null;

    var client: c.RECT = undefined;
    _ = c.GetClientRect(hwnd, &client);

    const w_f: f32 = @floatFromInt(@max(1, client.right - client.left));
    const h_f: f32 = @floatFromInt(@max(1, client.bottom - client.top));

    var minx: f32 = verts[0].position[0];
    var maxx: f32 = verts[0].position[0];
    var miny: f32 = verts[0].position[1];
    var maxy: f32 = verts[0].position[1];

    for (verts) |v| {
        const x = v.position[0];
        const y = v.position[1];
        if (x < minx) minx = x;
        if (x > maxx) maxx = x;
        if (y < miny) miny = y;
        if (y > maxy) maxy = y;
    }

    // NDC -> pixel
    // x_px = (x_ndc + 1) * 0.5 * w
    // y_px = (1 - y_ndc) * 0.5 * h   (y-down)
    const l_f = (minx + 1.0) * 0.5 * w_f;
    const r_f = (maxx + 1.0) * 0.5 * w_f;
    const t_f = (1.0 - maxy) * 0.5 * h_f;
    const b_f = (1.0 - miny) * 0.5 * h_f;

    var l: i32 = @intFromFloat(@floor(l_f));
    var r: i32 = @intFromFloat(@ceil(r_f));
    var t: i32 = @intFromFloat(@floor(t_f));
    var b: i32 = @intFromFloat(@ceil(b_f));

    // clamp
    if (l < 0) l = 0;
    if (t < 0) t = 0;
    if (r > client.right) r = client.right;
    if (b > client.bottom) b = client.bottom;

    if (r <= l or b <= t) return null;

    return .{ .left = l, .top = t, .right = r, .bottom = b };
}

fn rectFromVerts(hwnd: c.HWND, verts: []const core.Vertex) ?c.RECT {
    if (verts.len == 0) return null;

    var client: c.RECT = undefined;
    _ = c.GetClientRect(hwnd, &client);

    const w_f: f32 = @floatFromInt(@max(1, client.right - client.left));
    const h_f: f32 = @floatFromInt(@max(1, client.bottom - client.top));

    var minx: f32 = verts[0].position[0];
    var maxx: f32 = verts[0].position[0];
    var miny: f32 = verts[0].position[1];
    var maxy: f32 = verts[0].position[1];

    for (verts) |v| {
        const x = v.position[0];
        const y = v.position[1];
        if (x < minx) minx = x;
        if (x > maxx) maxx = x;
        if (y < miny) miny = y;
        if (y > maxy) maxy = y;
    }

    // NDC -> pixel
    const l_f = (minx + 1.0) * 0.5 * w_f;
    const r_f = (maxx + 1.0) * 0.5 * w_f;
    const t_f = (1.0 - maxy) * 0.5 * h_f;
    const b_f = (1.0 - miny) * 0.5 * h_f;

    var l: i32 = @intFromFloat(@floor(l_f));
    var r: i32 = @intFromFloat(@ceil(r_f));
    var t: i32 = @intFromFloat(@floor(t_f));
    var b: i32 = @intFromFloat(@ceil(b_f));

    // clamp
    if (l < 0) l = 0;
    if (t < 0) t = 0;
    if (r > client.right) r = client.right;
    if (b > client.bottom) b = client.bottom;

    if (r <= l or b <= t) return null;

    return .{ .left = l, .top = t, .right = r, .bottom = b };
}

fn markDirtyRowsByRect(app: *App, rc: c.RECT) void {
    const row_h: u32 = @max(1, app.cell_h_px + app.linespace_px);

    // When ext_tabline is enabled (and content_hwnd is not used), the rect coordinates
    // are in hwnd (main window) coordinate system which includes the tabbar.
    // We need to subtract the tabbar height to get the correct row number.
    const y_offset: i32 = if (app.ext_tabline_enabled and app.content_hwnd == null)
        @intCast(TablineState.TAB_BAR_HEIGHT)
    else
        0;

    const top_u: u32 = @intCast(@max(0, rc.top - y_offset));
    const bot_u: u32 = @intCast(@max(0, rc.bottom - y_offset));

    var r0: u32 = top_u / row_h;
    var r1: u32 = (bot_u + (row_h - 1)) / row_h; // ceil

    // Clamp to current grid rows to avoid out-of-bounds (e.g. r == rows).
    const max_rows: u32 = app.rows;
    if (max_rows != 0) {
        if (r0 > max_rows) r0 = max_rows;
        if (r1 > max_rows) r1 = max_rows;
    }

    var r: u32 = r0;
    while (r < r1) : (r += 1) {
        _ = app.dirty_rows.put(app.alloc, r, {}) catch {};
    }
}

fn appendRowsFromUpdateRegion(
    hwnd: c.HWND,
    app: *App,
    rows_to_draw: *std.ArrayListUnmanaged(u32),
    row_verts_len: u32,
) void {
    const log_enabled = applog.isEnabled();
    const log_t0_ns: i128 = if (log_enabled) std.time.nanoTimestamp() else 0;

    // Pre-allocate capacity for worst case (all rows dirty)
    rows_to_draw.ensureTotalCapacity(app.alloc, row_verts_len) catch {};

    var log_rect_area_sum: u64 = 0;
    var log_rows_appended: u32 = 0;

    // Create an empty region to receive the update region.
    const hrgn = c.CreateRectRgn(0, 0, 0, 0) orelse return;
    defer _ = c.DeleteObject(hrgn);

    // Populate hrgn with the window's update region (do not erase).
    const rgn_type: c.INT = c.GetUpdateRgn(hwnd, hrgn, c.FALSE);
    if (rgn_type == c.ERROR) return;

    const need_bytes: c.DWORD = c.GetRegionData(hrgn, 0, null);
    if (need_bytes == 0) return;

    if (log_enabled) {
        applog.appLog("[win] updateRgn need_bytes={d} rgn_type={d}\n", .{ need_bytes, rgn_type });
    }

    // RGNDATA needs alignment; use alignedAlloc.
    const alignment: std.mem.Alignment =
        @enumFromInt(@ctz(@as(usize, @alignOf(c.RGNDATA))));

    const buf = app.alloc.alignedAlloc(u8, alignment, need_bytes) catch return;
    defer app.alloc.free(buf);

    const rgndata: *c.RGNDATA = @ptrCast(@alignCast(buf.ptr));
    const got_bytes: c.DWORD = c.GetRegionData(hrgn, need_bytes, rgndata);
    if (got_bytes == 0) return;

    const row_h_px0: i32 = @intCast(@as(i32, @intCast(app.cell_h_px + app.linespace_px)));

    // RECT array starts at rgndata.Buffer (flexible array).
    const rects_ptr_u8: [*]u8 = @ptrCast(&rgndata.Buffer);
    const rects_ptr: [*]c.RECT = @ptrCast(@alignCast(rects_ptr_u8));

    const n: usize = @intCast(rgndata.rdh.nCount);

    var i: usize = 0;
    while (i < n) : (i += 1) {
        const dr = rects_ptr[i];

        const top_px: i32 = @max(0, dr.top);
        const bottom_px: i32 = @max(0, dr.bottom);

        // area accumulation (clamp negatives)
        const w_i32: i32 = dr.right - dr.left;
        const h_i32: i32 = dr.bottom - dr.top;
        if (w_i32 > 0 and h_i32 > 0) {
            log_rect_area_sum += @as(u64, @intCast(w_i32)) * @as(u64, @intCast(h_i32));
        }

        // [top_row, bottom_row)
        const top_row_i32: i32 = @divTrunc(top_px, row_h_px0);
        const bottom_row_i32: i32 = @divTrunc(bottom_px + (row_h_px0 - 1), row_h_px0);

        const top_row: u32 = @intCast(@max(0, top_row_i32));
        const bottom_row: u32 = @intCast(@min(@as(i32, @intCast(row_verts_len)), bottom_row_i32));

        var rr: u32 = top_row;
        while (rr < bottom_row) : (rr += 1) {
            rows_to_draw.appendAssumeCapacity(rr);
            log_rows_appended += 1;
        }
    }

    if (log_enabled) {
        const log_t1_ns: i128 = std.time.nanoTimestamp();
        const log_dur_us: u64 = @intCast(@max(@as(i128, 0), log_t1_ns - log_t0_ns) / 1_000);
        applog.appLog(
            "[win] updateRgn rects={d} rows_appended={d} area_px={d} dur_us={d} got_bytes={d}\n",
            .{ n, log_rows_appended, log_rect_area_sum, log_dur_us, got_bytes },
        );
    }
}

fn unionRect(a: c.RECT, b: c.RECT) c.RECT {
    return .{
        .left = if (a.left < b.left) a.left else b.left,
        .top = if (a.top < b.top) a.top else b.top,
        .right = if (a.right > b.right) a.right else b.right,
        .bottom = if (a.bottom > b.bottom) a.bottom else b.bottom,
    };
}

fn onVertices(
    ctx: ?*anyopaque,
    main_ptr: [*]const core.Vertex,
    main_count: usize,
    cursor_ptr: [*]const core.Vertex,
    cursor_count: usize,
) callconv(.c) void {
        const app: *App = @ptrCast(@alignCast(ctx.?));
        app.mu.lock();
        defer app.mu.unlock();

    app.main_verts.clearRetainingCapacity();
    app.cursor_verts.clearRetainingCapacity();

    // Pre-allocate capacity to avoid allocation failures
    app.main_verts.ensureTotalCapacity(app.alloc, main_count) catch {};
    app.cursor_verts.ensureTotalCapacity(app.alloc, cursor_count) catch {};

    app.main_verts.appendSliceAssumeCapacity(main_ptr[0..main_count]);
    app.cursor_verts.appendSliceAssumeCapacity(cursor_ptr[0..cursor_count]);

    if (app.row_mode) {
        app.row_mode = false;
    }

    if (app.hwnd) |hwnd| {
        _ = c.InvalidateRect(hwnd, null, c.FALSE);
        app.paint_full = true;
        app.paint_rects.clearRetainingCapacity();
    }
}

fn onVerticesPartial(
    ctx: ?*anyopaque,
    main_ptr: ?[*]const core.Vertex,
    main_count: usize,
    cursor_ptr: ?[*]const core.Vertex,
    cursor_count: usize,
    flags: u32,
) callconv(.c) void {
    const app: *App = @ptrCast(@alignCast(ctx.?));

    if (applog.isEnabled()) applog.appLog(
        "[win] onVerticesPartial flags=0x{x} main_count={d} cursor_count={d}\n",
        .{ flags, main_count, cursor_count },
    );

    app.mu.lock();

    var row_mode = app.row_mode;

    // Track whether we already invalidated something specific.
    var did_invalidate: bool = false;
    // Track if cursor was updated (for blink update after unlock)
    var cursor_updated: bool = false;

    // Flags specification: keep the side that is not updated
    if ((flags & core.VERT_UPDATE_MAIN) != 0) {
        if (row_mode) {
            app.row_mode = false;
            row_mode = false;
        }
        // Note: We don't set content_rows_dirty here.
        // For non-row-mode, full repaints are triggered anyway.
        // For row-mode, WM_PAINT determines if it's cursor-only.

        app.main_verts.clearRetainingCapacity();
        if (main_ptr != null and main_count != 0) {
            app.main_verts.ensureTotalCapacity(app.alloc, main_count) catch {};
            app.main_verts.appendSliceAssumeCapacity(main_ptr.?[0..main_count]);
        }

        // Non-row-mode: main update implies screen update; invalidate whole client.
        // Row-mode: main_verts is not used for drawing; do not force full invalidate here.
        if (!row_mode) {
            if (app.hwnd) |hwnd| {
                _ = c.InvalidateRect(hwnd, null, c.FALSE);
                did_invalidate = true;
                app.paint_full = true;
                app.paint_rects.clearRetainingCapacity();
            }
        }
    }

    if ((flags & core.VERT_UPDATE_CURSOR) != 0) {
        // compute old rect before overwriting cursor_verts
        const old_rc = app.last_cursor_rect_px;

        app.cursor_verts.clearRetainingCapacity();
        if (cursor_ptr != null and cursor_count != 0) {
            const slice = cursor_ptr.?[0..cursor_count];

            // Log cursor vertex data for debugging
            if (applog.isEnabled() and slice.len >= 1) {
                const v0 = slice[0];
                applog.appLog(
                    "[win] onVerticesPartial cursor v0: pos=({d:.2},{d:.2}) col=({d:.3},{d:.3},{d:.3},{d:.3})\n",
                    .{ v0.position[0], v0.position[1], v0.color[0], v0.color[1], v0.color[2], v0.color[3] },
                );
            }
            app.cursor_verts.ensureTotalCapacity(app.alloc, cursor_count) catch {};
            app.cursor_verts.appendSliceAssumeCapacity(slice);

            if (app.hwnd) |hwnd| {
                // Use content_hwnd for cursor rect calculation when ext_tabline is enabled
                const rect_hwnd = if (app.content_hwnd) |ch| ch else hwnd;
                const new_rc = rectFromCursorVerts(rect_hwnd, slice);
                app.last_cursor_rect_px = new_rc;

                // Row-mode: cursor move should only invalidate cursor rects.
                if (row_mode) {
                    if (!app.cursor_overlay_active) {
                        app.cursor_overlay_active = true;
                        app.need_full_seed.store(true, .seq_cst);
                        _ = c.InvalidateRect(hwnd, null, c.FALSE);
                        app.paint_full = true;
                        app.paint_rects.clearRetainingCapacity();
                    }
                    if (old_rc) |r0| {
                        _ = c.InvalidateRect(hwnd, &r0, c.FALSE);
                        did_invalidate = true;
                    
                        // NEW: record exact damage rect we requested
                        app.paint_rects.append(app.alloc, r0) catch {};
                    }
                    if (new_rc) |r1| {
                        _ = c.InvalidateRect(hwnd, &r1, c.FALSE);
                        did_invalidate = true;
                    
                        // NEW: record exact damage rect we requested
                        app.paint_rects.append(app.alloc, r1) catch {};
                    }
                    if (old_rc) |r0| {
                        markDirtyRowsByRect(app, r0);
                    }
                    if (new_rc) |r1| {
                        markDirtyRowsByRect(app, r1);
                    }

                } else {
                    // Non-row-mode: still try to invalidate only cursor union instead of full screen.
                    if (old_rc != null and new_rc != null) {
                        var u = unionRect(old_rc.?, new_rc.?);
                        _ = c.InvalidateRect(hwnd, &u, c.FALSE);
                        did_invalidate = true;
                    } else if (old_rc) |r0| {
                        _ = c.InvalidateRect(hwnd, &r0, c.FALSE);
                        did_invalidate = true;
                    } else if (new_rc) |r1| {
                        _ = c.InvalidateRect(hwnd, &r1, c.FALSE);
                        did_invalidate = true;
                    }
                }
            }
        } else {
            // no cursor verts -> clear last rect
            app.last_cursor_rect_px = null;

            // If cursor disappeared, invalidate old cursor rect only (if any).
            if (app.hwnd) |hwnd| {
                if (old_rc) |r0| {
                    _ = c.InvalidateRect(hwnd, &r0, c.FALSE);
                    did_invalidate = true;
                }
            }
            if (row_mode) {
                if (old_rc) |r0| {
                    markDirtyRowsByRect(app, r0);
                }
            }
        }

        // NEW: cursor verts updated => bump generation
        app.cursor_gen +%= 1;
        cursor_updated = true;
    }

    // If nothing was invalidated (should be rare):
    // - Non-row-mode: request a repaint (fallback to full client).
    // - Row-mode: DO NOT full-invalidate here; row updates come via onVerticesRow and
    //   cursor updates via onVerticesPartial(cursor). A full invalidate here defeats dirty-rect rendering.
    if (!did_invalidate) {
        if (!row_mode) {
            if (app.hwnd) |hwnd| {
                _ = c.InvalidateRect(hwnd, null, c.FALSE);
                app.paint_full = true;
                app.paint_rects.clearRetainingCapacity();
            }
        }
    }

    // Get hwnd before unlock
    const hwnd_for_blink = app.hwnd;

    app.mu.unlock();

    // Post message to update cursor blinking (avoid deadlock by doing it on UI thread)
    if (cursor_updated) {
        if (hwnd_for_blink) |hwnd| {
            _ = c.PostMessageW(hwnd, WM_APP_UPDATE_CURSOR_BLINK, 0, 0);
        }
    }
}

fn onRenderPlan(
    ctx: ?*anyopaque,
    bg_spans: ?[*]const core.BgSpan,
    bg_span_count: usize,
    text_runs: ?[*]const core.TextRun,
    text_run_count: usize,
    rows: u32,
    cols: u32,
    cursor_ptr: ?*const core.Cursor,
) callconv(.c) void {
    _ = bg_spans;
    _ = bg_span_count;
    _ = text_runs;
    _ = text_run_count;

    const app: *App = @ptrCast(@alignCast(ctx.?));

    // Read cursor outside lock (cursor_ptr is valid for duration of callback)
    var new_cursor: ?core.Cursor = null;
    if (cursor_ptr) |p| new_cursor = p.*;

    // Keep the latest grid size for bounds checks / clamping.
    // Use single lock region to prevent race conditions.
    app.mu.lock();
    defer app.mu.unlock();

    if (rows != app.rows or cols != app.cols) {
        app.rows = rows;
        app.cols = cols;
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
        // Each RowVerts entry's verts array is cleared; GPU VBs will be re-uploaded.
        for (app.row_verts.items) |*rv| {
            rv.verts.clearRetainingCapacity();
            rv.gen +%= 1; // Invalidate any cached GPU upload
        }
    } else {
        app.rows = rows;
        app.cols = cols;
    }

    // NOTE: cursor_ptr may be null => treat as disabled/none
    app.cursor = new_cursor;

    if (applog.isEnabled()) applog.appLog("[win] on_render_plan rows={d} cols={d}\n", .{ rows, cols });
}

fn onVerticesRow(
    ctx: ?*anyopaque,
    grid_id: i64,
    row_start: u32,
    row_count: u32,
    verts_ptr: ?[*]const core.Vertex,
    vert_count: usize,
    flags: u32,
    total_rows: u32,
    total_cols: u32,
) callconv(.c) void {
    const app: *App = @ptrCast(@alignCast(ctx.?));
    app.mu.lock();
    defer app.mu.unlock();

    if (applog.isEnabled()) {
        var cur_enabled: u32 = 0;
        var cur_row: u32 = 0;
        var cur_col: u32 = 0;
        if (app.cursor) |cur| {
            cur_enabled = cur.enabled;
            cur_row = cur.row;
            cur_col = cur.col;
        }
        if (applog.isEnabled()) applog.appLog(
            "[win] on_vertices_row row_start={d} row_count={d} vert_count={d} flags=0x{x} cursor_en={d} cursor_row={d} cursor_col={d} rows={d} row_valid={d} row_verts_len={d}\n",
            .{
                row_start,
                row_count,
                vert_count,
                flags,
                cur_enabled,
                cur_row,
                cur_col,
                app.rows,
                app.row_valid_count,
                app.row_verts.items.len,
            },
        );
    }
    if (row_count != 1 and applog.isEnabled()) {
        applog.appLog(
            "[win] on_vertices_row WARN row_count={d} row_start={d} vert_count={d}\n",
            .{ row_count, row_start, vert_count },
        );
    }
    if (applog.isEnabled() and verts_ptr != null and vert_count != 0) {
        const verts = verts_ptr.?[0..vert_count];
        var glyph_verts: u32 = 0;
        var bad_uv: u32 = 0;
        var bad_pos: u32 = 0;
        var i: usize = 0;
        while (i < verts.len) : (i += 1) {
            const v = verts[i];
            const u = v.texCoord[0];
            const v2 = v.texCoord[1];
            if (!(u == -1.0 and v2 == -1.0)) {
                glyph_verts += 1;
                if (!std.math.isFinite(u) or !std.math.isFinite(v2)) {
                    bad_uv += 1;
                } else if (u < 0.0 or u > 1.0 or v2 < 0.0 or v2 > 1.0) {
                    bad_uv += 1;
                }
            }
            if (!std.math.isFinite(v.position[0]) or !std.math.isFinite(v.position[1])) {
                bad_pos += 1;
            }
        }
        if (glyph_verts == 0 and vert_count >= 12 and log_row_no_glyphs_count < 16) {
            applog.appLog(
                "[win] on_vertices_row WARN no_glyphs row_start={d} vert_count={d}\n",
                .{ row_start, vert_count },
            );
            log_row_no_glyphs_count += 1;
        }
        if ((bad_uv != 0 or bad_pos != 0) and log_row_bad_uv_count < 16) {
            applog.appLog(
                "[win] on_vertices_row WARN bad_verts row_start={d} vert_count={d} bad_uv={d} bad_pos={d}\n",
                .{ row_start, vert_count, bad_uv, bad_pos },
            );
            log_row_bad_uv_count += 1;
        }
        // Log first few vertex details for diagnostic (only for rows with glyphs)
        if (glyph_verts > 0 and row_start <= 2) {
            const log_count = @min(verts.len, 6);
            var vi: usize = 0;
            while (vi < log_count) : (vi += 1) {
                const v = verts[vi];
                applog.appLog(
                    "[win] on_vertices_row row={d} v[{d}] pos=({d:.2},{d:.2}) uv=({d:.4},{d:.4}) col=({d:.3},{d:.3},{d:.3},{d:.3})\n",
                    .{
                        row_start, vi,
                        v.position[0], v.position[1],
                        v.texCoord[0], v.texCoord[1],
                        v.color[0], v.color[1], v.color[2], v.color[3],
                    },
                );
            }
            // Also log first few GLYPH vertices (UV != -1,-1)
            var glyph_logged: u32 = 0;
            var gi: usize = 0;
            while (gi < verts.len and glyph_logged < 3) : (gi += 1) {
                const v = verts[gi];
                if (!(v.texCoord[0] == -1.0 and v.texCoord[1] == -1.0)) {
                    applog.appLog(
                        "[win] on_vertices_row row={d} GLYPH v[{d}] pos=({d:.2},{d:.2}) uv=({d:.4},{d:.4}) col=({d:.3},{d:.3},{d:.3},{d:.3})\n",
                        .{
                            row_start, gi,
                            v.position[0], v.position[1],
                            v.texCoord[0], v.texCoord[1],
                            v.color[0], v.color[1], v.color[2], v.color[3],
                        },
                    );
                    glyph_logged += 1;
                }
            }
        }
    }

    // Handle external grids (grid_id != 1) separately
    // External grids use their own vertex storage (ext_win.verts or pending_external_verts)
    if (grid_id != 1) {
        if (applog.isEnabled()) applog.appLog(
            "[win] on_vertices_row external grid_id={d} row_start={d} vert_count={d} total_rows={d} total_cols={d}\n",
            .{ grid_id, row_start, vert_count, total_rows, total_cols },
        );

        // Try to find existing external window for this grid
        if (app.external_windows.getPtr(grid_id)) |ext_win| {
            // Window exists - store vertices
            // Clear verts when row 0 is received (start of new frame)
            if (row_start == 0) {
                ext_win.verts.clearRetainingCapacity();
                ext_win.vert_count = 0;
            }

            // Append this row's vertices
            if (verts_ptr != null and vert_count != 0) {
                ext_win.verts.ensureTotalCapacity(app.alloc, ext_win.verts.items.len + vert_count) catch return;
                ext_win.verts.appendSliceAssumeCapacity(verts_ptr.?[0..vert_count]);
                ext_win.vert_count = ext_win.verts.items.len;
            }
            ext_win.rows = total_rows;
            ext_win.cols = total_cols;
            ext_win.needs_redraw = true;

            // Invalidate window to trigger repaint
            _ = c.InvalidateRect(ext_win.hwnd, null, 0);

            if (applog.isEnabled()) applog.appLog(
                "[win] on_vertices_row external grid_id={d} updated ext_win vert_count={d}\n",
                .{ grid_id, ext_win.vert_count },
            );
        } else {
            // Window doesn't exist yet - store in pending_external_verts
            // Find or create pending entry for this grid_id
            var found_idx: ?usize = null;
            for (app.pending_external_verts.items, 0..) |*pv, i| {
                if (pv.grid_id == grid_id) {
                    found_idx = i;
                    break;
                }
            }

            if (found_idx) |idx| {
                // Update existing pending entry
                const pv = &app.pending_external_verts.items[idx];
                // Clear when row 0 is received
                if (row_start == 0) {
                    pv.verts.clearRetainingCapacity();
                }
                if (verts_ptr != null and vert_count != 0) {
                    pv.verts.ensureTotalCapacity(app.alloc, pv.verts.items.len + vert_count) catch return;
                    pv.verts.appendSliceAssumeCapacity(verts_ptr.?[0..vert_count]);
                }
                pv.rows = total_rows;
                pv.cols = total_cols;
            } else {
                // Create new pending entry
                var new_pv = PendingExternalVertices{
                    .grid_id = grid_id,
                    .rows = total_rows,
                    .cols = total_cols,
                };
                if (verts_ptr != null and vert_count != 0) {
                    new_pv.verts.ensureTotalCapacity(app.alloc, vert_count) catch return;
                    new_pv.verts.appendSliceAssumeCapacity(verts_ptr.?[0..vert_count]);
                }
                app.pending_external_verts.append(app.alloc, new_pv) catch return;
            }

            if (applog.isEnabled()) applog.appLog(
                "[win] on_vertices_row external grid_id={d} stored in pending_external_verts\n",
                .{grid_id},
            );
        }
        return; // Don't process as main grid
    }

    const end_row_hint: u32 = row_start + row_count;
    if (end_row_hint > app.row_mode_max_row_end) {
        app.row_mode_max_row_end = end_row_hint;
        if (applog.isEnabled()) applog.appLog(
            "[win] on_vertices_row max_row_end={d} rows={d} row_verts_len={d}\n",
            .{ app.row_mode_max_row_end, app.rows, app.row_verts.items.len },
        );
    }

    // Update app.rows based on total_rows from core (handles both growth and shrink)
    if (total_rows != app.rows) {
        const old_rows = app.rows;
        app.rows = total_rows;
        app.cols = total_cols;
        app.seed_pending = true;
        app.seed_clear_pending = true;
        app.row_valid_count = 0;
        app.row_layout_gen +%= 1;
        if (total_rows != 0) {
            app.row_valid.resize(app.alloc, @intCast(total_rows), false) catch {};
            app.row_valid.unsetAll();
        } else if (app.row_valid.bit_length != 0) {
            app.row_valid.unsetAll();
        }
        // Clear old row vertex data to prevent ghost rendering from stale vertices.
        for (app.row_verts.items) |*rv| {
            rv.verts.clearRetainingCapacity();
            rv.gen +%= 1;
        }
        // Shrink row_verts if significantly oversized
        app.maybeShrinkRowStorage(total_rows);
        if (applog.isEnabled()) applog.appLog(
            "[win] on_vertices_row resize old={d} new={d} row_valid={d}\n",
            .{ old_rows, total_rows, app.row_valid_count },
        );
    }

    // Row callback is meaningful only when MAIN is updated.
    // If MAIN isn't updated, do NOT mark dirty rows nor invalidate;
    // otherwise cursor-only operations can accidentally explode dirty_rows.
    if ((flags & core.VERT_UPDATE_MAIN) == 0) {
        return;
    }

    // Note: We don't set content_rows_dirty here anymore.
    // The WM_PAINT handler will determine if it's cursor-only by checking
    // if all dirty rows are covered by cursor rects from paint_rects_snapshot.

    // Mark row-mode and remember which rows are dirty.
    // When we enter row-mode for the first time, request a one-time full seed.
    if (!app.row_mode) {
        app.row_mode = true;
        app.need_full_seed.store(true, .seq_cst);
        app.seed_pending = true;
        app.seed_clear_pending = true;
        app.row_valid_count = 0;
        if (app.rows != 0) {
            app.row_valid.resize(app.alloc, @intCast(app.rows), false) catch {};
            app.row_valid.unsetAll();
        }
    } else {
        app.row_mode = true;
    }

    // Mark rows dirty (now gated by MAIN flag).
    // Clamp to [0, app.rows) to avoid index==rows.
    const max_rows: u32 = app.rows;
    
    if (max_rows != 0 and row_start >= max_rows) {
        return;
    }
    
    const end_row_unclamped: u32 = row_start + row_count;
    const end_row: u32 = if (max_rows != 0 and end_row_unclamped > max_rows) max_rows else end_row_unclamped;
    
    var r: u32 = row_start;
    while (r < end_row) : (r += 1) {
        _ = app.dirty_rows.put(app.alloc, r, {}) catch {};
    }

    
    if (row_count != 0) {
        const row: u32 = row_start;
    
        // Extra safety: if rows is known, do not store beyond it.
        if (max_rows != 0 and row >= max_rows) {
            return;
        }
    
        app.ensureRowStorage(row);

        // Verify row storage was allocated (may fail if row >= max_row_buffers)
        if (row >= app.row_verts.items.len) return;

        var rv = &app.row_verts.items[@intCast(row)];
        rv.verts.clearRetainingCapacity();
    
        if (verts_ptr != null and vert_count != 0) {
            rv.verts.appendSlice(app.alloc, verts_ptr.?[0..vert_count]) catch {};
        }
    
        rv.gen +%= 1;
    }


    if (app.rows != 0) {
        r = row_start;
        while (r < end_row) : (r += 1) {
            const idx: usize = @intCast(r);
            if (idx < app.row_valid.bit_length and !app.row_valid.isSet(idx)) {
                app.row_valid.set(idx);
                app.row_valid_count += 1;
            }
        }
        if (app.row_valid_count == app.rows) {
            if (applog.isEnabled()) applog.appLog("[win] on_vertices_row seed_ready rows={d}\n", .{ app.rows });
        }
    }

    if (app.hwnd) |hwnd| {
        // Invalidate only the affected row rectangle in pixels.
        const fallback_row_h: u32 = app.cell_h_px + app.linespace_px;
        const row_h_px_u32 = rowHeightPxFromClient(hwnd, app.rows, fallback_row_h);
        const row_h_px: i32 = @intCast(@as(i32, @intCast(row_h_px_u32)));

        var rc: c.RECT = .{
            .left = 0,
            .top = @intCast(@as(i32, @intCast(row_start)) * row_h_px),
            .right = 0, // will be set to client.right below
            .bottom = @intCast(@as(i32, @intCast(row_start + row_count)) * row_h_px),
        };
        var client: c.RECT = undefined;
        _ = c.GetClientRect(hwnd, &client);
        rc.right = client.right;

        _ = c.InvalidateRect(hwnd, &rc, c.FALSE);

        // Update scrollbar via PostMessage to avoid deadlock
        _ = c.PostMessageW(hwnd, WM_APP_UPDATE_SCROLLBAR, 0, 0);
    }
}

fn onAtlasEnsureGlyph(ctx: ?*anyopaque, scalar: u32, out_entry: *core.GlyphEntry) callconv(.c) c_int {
    const ctxp = ctx orelse return 0;
    const ctx_bits: usize = @intFromPtr(ctxp);
    if (ctx_bits % @alignOf(App) != 0) {
        if (applog.isEnabled()) applog.appLog("onAtlasEnsureGlyph: MISALIGNED ctx=0x{x} align={d} scalar=0x{x}", .{ ctx_bits, @alignOf(App), scalar });
        return 0;
    }
    const app: *App = @ptrFromInt(ctx_bits);

    // ---- aggregate stats (very low overhead) ----
    log_atlas_ensure_calls += 1;
    if (scalar > 0x10FFFF) {
        log_atlas_ensure_suspicious += 1;
    }

    if (applog.isEnabled()) {
        const now_ns: i128 = std.time.nanoTimestamp();
        if (log_atlas_ensure_last_report_ns == 0) log_atlas_ensure_last_report_ns = now_ns;

        // report once per second
        if (now_ns - log_atlas_ensure_last_report_ns >= @as(i128, 1_000_000_000)) {
            applog.appLog(
                "[atlas] ensureGlyph calls/s={d} suspicious/s={d}\n",
                .{ log_atlas_ensure_calls, log_atlas_ensure_suspicious },
            );
            log_atlas_ensure_calls = 0;
            log_atlas_ensure_suspicious = 0;
            log_atlas_ensure_last_report_ns = now_ns;
        }
    }

    if (app.atlas) |*a| {
        const e = a.atlasEnsureGlyphEntry(scalar) catch |err| {
            if (applog.isEnabled()) applog.appLog("atlasEnsureGlyph: atlasEnsureGlyphEntry ERROR scalar=0x{x} err={any}", .{ scalar, err });
            return 0;
        };
        if (applog.isEnabled() and log_atlas_zero_bbox_count < 16 and scalar != 0 and scalar != 32) {
            if (e.bbox_size_px[0] <= 0 or e.bbox_size_px[1] <= 0) {
                applog.appLog(
                    "[atlas] ensureGlyph zero_bbox scalar=0x{x} bbox=({d:.3},{d:.3}) uv=({d:.4},{d:.4})-({d:.4},{d:.4}) adv={d:.3} asc={d:.3} desc={d:.3}\n",
                    .{
                        scalar,
                        e.bbox_size_px[0],
                        e.bbox_size_px[1],
                        e.uv_min[0],
                        e.uv_min[1],
                        e.uv_max[0],
                        e.uv_max[1],
                        e.advance_px,
                        e.ascent_px,
                        e.descent_px,
                    },
                );
                log_atlas_zero_bbox_count += 1;
            } else if (e.uv_max[0] <= e.uv_min[0] or e.uv_max[1] <= e.uv_min[1]) {
                applog.appLog(
                    "[atlas] ensureGlyph invalid_uv scalar=0x{x} uv=({d:.4},{d:.4})-({d:.4},{d:.4}) bbox=({d:.3},{d:.3})\n",
                    .{
                        scalar,
                        e.uv_min[0],
                        e.uv_min[1],
                        e.uv_max[0],
                        e.uv_max[1],
                        e.bbox_size_px[0],
                        e.bbox_size_px[1],
                    },
                );
                log_atlas_zero_bbox_count += 1;
            }
        }
        out_entry.* = e;
        return 1;
    } else {
        // Atlas not ready yet - queue for later processing
        app.mu.lock();
        defer app.mu.unlock();
        app.pending_glyphs.append(app.alloc, .{ .scalar = scalar, .style_flags = 0 }) catch {};
        return 0;
    }
}

// Track styled glyph stats
var log_styled_glyph_calls: u64 = 0;
var log_styled_glyph_ok: u64 = 0;
var log_styled_glyph_fail: u64 = 0;
var log_styled_glyph_last_report_ns: i128 = 0;

fn onAtlasEnsureGlyphStyled(ctx: ?*anyopaque, scalar: u32, style_flags: u32, out_entry: *core.GlyphEntry) callconv(.c) c_int {
    const ctxp = ctx orelse return 0;
    const ctx_bits: usize = @intFromPtr(ctxp);
    if (ctx_bits % @alignOf(App) != 0) {
        if (applog.isEnabled()) applog.appLog("onAtlasEnsureGlyphStyled: MISALIGNED ctx=0x{x} align={d} scalar=0x{x} style=0x{x}", .{ ctx_bits, @alignOf(App), scalar, style_flags });
        return 0;
    }
    const app: *App = @ptrFromInt(ctx_bits);

    log_styled_glyph_calls += 1;

    if (app.atlas) |*a| {
        const e = a.atlasEnsureGlyphEntryStyled(scalar, style_flags) catch |err| {
            log_styled_glyph_fail += 1;
            if (applog.isEnabled()) applog.appLog("atlasEnsureGlyphStyled: ERROR scalar=0x{x} style=0x{x} err={any}", .{ scalar, style_flags, err });
            return 0;
        };
        log_styled_glyph_ok += 1;

        // Report stats once per second
        if (applog.isEnabled()) {
            const now_ns: i128 = std.time.nanoTimestamp();
            if (log_styled_glyph_last_report_ns == 0) log_styled_glyph_last_report_ns = now_ns;
            if (now_ns - log_styled_glyph_last_report_ns >= @as(i128, 1_000_000_000)) {
                applog.appLog("[styled] calls/s={d} ok/s={d} fail/s={d}\n", .{ log_styled_glyph_calls, log_styled_glyph_ok, log_styled_glyph_fail });
                log_styled_glyph_calls = 0;
                log_styled_glyph_ok = 0;
                log_styled_glyph_fail = 0;
                log_styled_glyph_last_report_ns = now_ns;
            }
        }

        out_entry.* = e;
        return 1;
    } else {
        // Atlas not ready yet - queue for later processing
        app.mu.lock();
        defer app.mu.unlock();
        app.pending_glyphs.append(app.alloc, .{ .scalar = scalar, .style_flags = style_flags }) catch {};
        return 0;
    }
}

fn onLog(ctx: ?*anyopaque, bytes: [*c]const u8, len: usize) callconv(.c) void {
    _ = ctx;
    if (!applog.isEnabled()) return;
    if (bytes == null or len == 0) return;

    const s: []const u8 = @as([*]const u8, @ptrCast(bytes))[0..len];
    // Prefix is optional; keep empty for now.
    applog.appLogBytes("", s);
}

fn onGuiFont(ctx: ?*anyopaque, bytes: ?[*]const u8, len: usize) callconv(.c) void {
    const app: *App = @ptrCast(@alignCast(ctx.?));

    const default_font_name = "Consolas";
    const default_font_pt: f32 = 14.0;

    var name: []const u8 = default_font_name;
    var pt: f32 = default_font_pt;

    if (bytes != null and len != 0) {
        const s = bytes.?[0..len];
        if (std.mem.indexOfScalar(u8, s, '\t')) |tab| {
            name = s[0..tab];
            const size_str = s[tab + 1 ..];
            pt = std.fmt.parseFloat(f32, size_str) catch default_font_pt;
        } else {
            // No tab => treat as invalid; fallback.
            if (applog.isEnabled()) applog.appLog("onGuiFont: invalid payload (no tab), fallback to default", .{});
        }
    } else {
        if (applog.isEnabled()) applog.appLog("onGuiFont: empty payload, fallback to default", .{});
    }

    app.mu.lock();

    if (app.atlas) |*a| {
        var applied_name: []const u8 = name;
        var applied_pt: f32 = pt;

        const try_primary = a.setFontUtf8(name, pt);
        if (try_primary) |_| {} else |e| {
            if (applog.isEnabled()) applog.appLog("onGuiFont: setFontUtf8 failed name='{s}' pt={d}: {any}", .{ name, pt, e });

            const fallback_name = "Consolas";
            const fallback_pt: f32 = pt;

            const try_fb = a.setFontUtf8(fallback_name, fallback_pt);
            if (try_fb) |_| {
                applied_name = fallback_name;
                applied_pt = fallback_pt;
                if (applog.isEnabled()) applog.appLog("onGuiFont: fallback applied name='{s}' pt={d}", .{ applied_name, applied_pt });
            } else |e2| {
                if (applog.isEnabled()) applog.appLog("onGuiFont: fallback setFontUtf8 failed name='{s}' pt={d}: {any}", .{ fallback_name, fallback_pt, e2 });
            }
        }

        app.cell_w_px = a.cellW();
        app.cell_h_px = a.cellH();
        if (applog.isEnabled()) applog.appLog("onGuiFont: applied name='{s}' pt={d} cell=({d},{d})", .{ applied_name, applied_pt, app.cell_w_px, app.cell_h_px });
    } else {
        if (applog.isEnabled()) applog.appLog("onGuiFont: atlas is null", .{});
    }

    const hwnd = app.hwnd;
    if (hwnd) |h| {
        updateRowsColsFromClientForce(h, app);
    }
    app.mu.unlock();

    if (hwnd) |h| {
        updateLayoutToCore(h, app);
        _ = c.InvalidateRect(h, null, 0);
        app.mu.lock();
        app.paint_full = true;
        app.paint_rects.clearRetainingCapacity();
        // Trigger full seed to clear back buffer and sync all swapchain buffers.
        // This ensures gutter areas (outside the new grid) are properly cleared.
        app.need_full_seed.store(true, .seq_cst);
        app.seed_pending = true;
        app.seed_clear_pending = true;
        app.mu.unlock();
    }
}

fn onLineSpace(ctx: ?*anyopaque, linespace_px: i32) callconv(.c) void {
    const app: *App = @ptrCast(@alignCast(ctx.?));

    const v: u32 = if (linespace_px <= 0) 0 else @intCast(linespace_px);

    if (applog.isEnabled()) applog.appLog(
        "[win] onLineSpace: linespace_px={d} v={d} cell_h_px={d} -> row_h={d}\n",
        .{ linespace_px, v, app.cell_h_px, app.cell_h_px + v },
    );

    app.mu.lock();
    app.linespace_px = v;
    const hwnd = app.hwnd;
    if (hwnd) |h| {
        updateRowsColsFromClientForce(h, app);
    }
    app.mu.unlock();

    if (hwnd) |h| {
        updateLayoutToCore(h, app);
        _ = c.InvalidateRect(h, null, 0);
        app.mu.lock();
        app.paint_full = true;
        app.paint_rects.clearRetainingCapacity();
        // Trigger full seed to clear back buffer and sync all swapchain buffers.
        // This ensures gutter areas (outside the new grid) are properly cleared.
        app.need_full_seed.store(true, .seq_cst);
        app.seed_pending = true;
        app.seed_clear_pending = true;
        app.mu.unlock();
    }
}

fn onExit(ctx: ?*anyopaque, exit_code: i32) callconv(.c) void {
    const app: *App = @ptrCast(@alignCast(ctx.?));
    if (applog.isEnabled()) applog.appLog("[win] on_exit: code={d}\n", .{exit_code});
    // Mark Neovim as exited (to skip requestQuit in WM_CLOSE)
    app.neovim_exited.store(true, .release);
    // Store exit code globally (Nvy style - returned from main instead of ExitProcess)
    g_exit_code.store(@intCast(@as(u32, @bitCast(exit_code)) & 0xFF), .seq_cst);
    if (app.hwnd) |hwnd| {
        _ = c.PostMessageW(hwnd, c.WM_CLOSE, 0, 0);
    }
}

fn onIMEOff(ctx: ?*anyopaque) callconv(.c) void {
    const app: *App = @ptrCast(@alignCast(ctx.?));
    if (app.hwnd) |hwnd| {
        // Post message to main thread (IME APIs must be called from the window's thread)
        _ = c.PostMessageW(hwnd, WM_APP_IME_OFF, 0, 0);
    }
}

fn onQuitRequested(ctx: ?*anyopaque, has_unsaved: c_int) callconv(.c) void {
    const app: *App = @ptrCast(@alignCast(ctx.?));
    if (applog.isEnabled()) applog.appLog("[win] onQuitRequested: has_unsaved={d}\n", .{has_unsaved});

    // Post message to main thread to avoid blocking RPC thread
    if (app.hwnd) |hwnd| {
        _ = c.PostMessageW(hwnd, WM_APP_QUIT_REQUESTED, @intCast(has_unsaved), 0);
    }
}

fn onSetTitle(ctx: ?*anyopaque, title_ptr: ?[*]const u8, title_len: usize) callconv(.c) void {
    const app: *App = @ptrCast(@alignCast(ctx.?));

    if (applog.isEnabled()) applog.appLog("[win] onSetTitle: len={d}\n", .{title_len});

    if (title_ptr == null or title_len == 0) return;

    const title = title_ptr.?[0..title_len];
    if (applog.isEnabled()) applog.appLog("[win] onSetTitle: {s}\n", .{title});

    if (app.hwnd) |hwnd| {
        // Convert UTF-8 to UTF-16 for Windows API
        var wide_buf: [512]u16 = undefined;
        const wide_len = std.unicode.utf8ToUtf16Le(&wide_buf, title) catch return;
        if (wide_len >= wide_buf.len) return;
        wide_buf[wide_len] = 0; // null terminate
        _ = c.SetWindowTextW(hwnd, &wide_buf);
    }
}

// --- ext_cmdline callbacks ---

fn onCmdlineShow(
    ctx: ?*anyopaque,
    _: ?[*]const core.CmdlineChunk, // content
    _: usize, // content_count
    _: u32, // pos
    firstc: u8,
    _: ?[*]const u8, // prompt
    _: usize, // prompt_len
    _: u32, // indent
    _: u32, // level
    _: u32, // prompt_hl_id
) callconv(.c) void {
    const app: *App = @ptrCast(@alignCast(ctx.?));
    if (applog.isEnabled()) applog.appLog("[win] on_cmdline_show: firstc={c}({d})\n", .{ firstc, firstc });

    app.mu.lock();
    app.cmdline_firstc = firstc;
    app.mu.unlock();
}

fn onCmdlineHide(ctx: ?*anyopaque, _: u32) callconv(.c) void {
    const app: *App = @ptrCast(@alignCast(ctx.?));
    if (applog.isEnabled()) applog.appLog("[win] on_cmdline_hide\n", .{});

    app.mu.lock();
    app.cmdline_firstc = 0;
    app.mu.unlock();
}

// ext_tabline child window
const tabline_class_name: [:0]const u16 = std.unicode.utf8ToUtf16LeStringLiteral("ZonvieTablineClass");
var tabline_class_registered: bool = false;

fn registerTablineWindowClass() bool {
    if (tabline_class_registered) return true;

    var wc: c.WNDCLASSEXW = std.mem.zeroes(c.WNDCLASSEXW);
    wc.cbSize = @sizeOf(c.WNDCLASSEXW);
    wc.style = c.CS_HREDRAW | c.CS_VREDRAW;
    wc.lpfnWndProc = tablineWndProc;
    wc.hInstance = c.GetModuleHandleW(null);
    wc.hCursor = c.LoadCursorW(null, @ptrFromInt(32512)); // IDC_ARROW
    wc.hbrBackground = null;
    wc.lpszClassName = @ptrCast(tabline_class_name.ptr);

    if (c.RegisterClassExW(&wc) == 0) {
        if (applog.isEnabled()) applog.appLog("[win] Failed to register tabline window class\n", .{});
        return false;
    }

    tabline_class_registered = true;
    if (applog.isEnabled()) applog.appLog("[win] Tabline window class registered\n", .{});
    return true;
}

fn createTablineWindow(parent_hwnd: c.HWND, app: *App) ?c.HWND {
    if (!registerTablineWindowClass()) return null;

    var parent_rect: c.RECT = undefined;
    _ = c.GetClientRect(parent_hwnd, &parent_rect);

    const hwnd = c.CreateWindowExW(
        0,
        @ptrCast(tabline_class_name.ptr),
        null,
        c.WS_CHILD | c.WS_VISIBLE | c.WS_CLIPSIBLINGS,
        0,
        0,
        parent_rect.right,
        TablineState.TAB_BAR_HEIGHT,
        parent_hwnd,
        null,
        c.GetModuleHandleW(null),
        @ptrCast(app),
    );

    if (hwnd == null) {
        if (applog.isEnabled()) applog.appLog("[win] Failed to create tabline window\n", .{});
        return null;
    }

    // Ensure tabline is on top of content window (in Z-order)
    _ = c.SetWindowPos(hwnd, c.HWND_TOP, 0, 0, 0, 0, c.SWP_NOMOVE | c.SWP_NOSIZE);

    return hwnd;
}

fn tablineWndProc(hwnd: c.HWND, msg: c.UINT, wParam: c.WPARAM, lParam: c.LPARAM) callconv(.winapi) c.LRESULT {
    switch (msg) {
        c.WM_NCHITTEST => {
            // Hit test for tabline child window:
            // - Return HTTRANSPARENT for empty areas (passes hit test to parent window for dragging)
            // - Return HTCLIENT for interactive areas (tabs, +button, window buttons)
            const v = c.GetWindowLongPtrW(hwnd, c.GWLP_USERDATA);
            if (v != 0) {
                const app: *App = @ptrFromInt(@as(usize, @bitCast(v)));

                // Get cursor position in screen coordinates
                const screen_x = @as(i16, @truncate(lParam & 0xFFFF));
                const screen_y = @as(i16, @truncate((lParam >> 16) & 0xFFFF));

                // Convert to client coordinates
                var pt: c.POINT = .{ .x = screen_x, .y = screen_y };
                _ = c.ScreenToClient(hwnd, &pt);
                const x = pt.x;
                const y = pt.y;

                // Get client rect
                var rect: c.RECT = undefined;
                _ = c.GetClientRect(hwnd, &rect);
                const client_width = rect.right - rect.left;

                // Check window control buttons (right side) - handle in this window
                const btn_start_x = client_width - TablineState.WINDOW_BTNS_TOTAL;
                if (x >= btn_start_x) {
                    return c.HTCLIENT;
                }

                // Check tabs and + button area
                app.mu.lock();
                const tab_count = app.tabline_state.tab_count;
                app.mu.unlock();

                if (tab_count > 0) {
                    // Calculate tab dimensions (same as handleTablineMouseDown)
                    const available_width = client_width - TablineState.WINDOW_CONTROLS_WIDTH - 40 - TablineState.WINDOW_BTNS_TOTAL;
                    const count_i32: i32 = @intCast(tab_count);
                    const ideal_width = @divTrunc(available_width, count_i32);
                    const tab_width = @min(TablineState.TAB_MAX_WIDTH, @max(TablineState.TAB_MIN_WIDTH, ideal_width));

                    // Check if on a tab
                    var tab_x: i32 = TablineState.WINDOW_CONTROLS_WIDTH;
                    for (0..tab_count) |_| {
                        if (x >= tab_x and x < tab_x + tab_width and y >= 0 and y < TablineState.TAB_BAR_HEIGHT) {
                            return c.HTCLIENT;
                        }
                        tab_x += tab_width + 1;
                    }

                    // Check + button (after last tab)
                    const plus_x = tab_x + 8;
                    const plus_size: i32 = 24;
                    if (x >= plus_x and x < plus_x + plus_size) {
                        return c.HTCLIENT;
                    }
                }

                // Empty area - pass to parent window for caption dragging
                return c.HTTRANSPARENT;
            }
            return c.HTTRANSPARENT;
        },
        c.WM_CREATE => {
            const cs: *c.CREATESTRUCTW = @ptrFromInt(@as(usize, @bitCast(lParam)));
            _ = c.SetWindowLongPtrW(hwnd, c.GWLP_USERDATA, @bitCast(@intFromPtr(cs.lpCreateParams)));
            return 0;
        },
        c.WM_PAINT => {
            const v = c.GetWindowLongPtrW(hwnd, c.GWLP_USERDATA);
            if (v != 0) {
                const app: *App = @ptrFromInt(@as(usize, @bitCast(v)));

                // Use GetDC instead of BeginPaint to avoid clip region issues
                // BeginPaint was returning NULLREGION clip, causing drawing to be invisible
                const hdc = c.GetDC(hwnd);
                if (hdc != null) {
                    var rect: c.RECT = undefined;
                    _ = c.GetClientRect(hwnd, &rect);
                    drawTablineContent(app, hdc, rect.right);
                    _ = c.ReleaseDC(hwnd, hdc);
                }

                // Still need to validate the region to stop WM_PAINT messages
                var ps: c.PAINTSTRUCT = undefined;
                _ = c.BeginPaint(hwnd, &ps);
                _ = c.EndPaint(hwnd, &ps);
            } else {
                // Validate region even without app
                var ps: c.PAINTSTRUCT = undefined;
                _ = c.BeginPaint(hwnd, &ps);
                _ = c.EndPaint(hwnd, &ps);
            }
            return 0;
        },
        c.WM_LBUTTONDOWN => {
            const v = c.GetWindowLongPtrW(hwnd, c.GWLP_USERDATA);
            if (v != 0) {
                const app: *App = @ptrFromInt(@as(usize, @bitCast(v)));
                const x: i16 = @bitCast(@as(u16, @truncate(@as(usize, @bitCast(lParam)))));
                const y: i16 = @bitCast(@as(u16, @truncate(@as(usize, @bitCast(lParam)) >> 16)));
                // Start potential drag - record position and capture mouse
                handleTablineMouseDown(app, hwnd, @as(c_int, x), @as(c_int, y));
            }
            return 0;
        },
        c.WM_LBUTTONUP => {
            const v = c.GetWindowLongPtrW(hwnd, c.GWLP_USERDATA);
            if (v != 0) {
                const app: *App = @ptrFromInt(@as(usize, @bitCast(v)));
                const x: i16 = @bitCast(@as(u16, @truncate(@as(usize, @bitCast(lParam)))));
                const y: i16 = @bitCast(@as(u16, @truncate(@as(usize, @bitCast(lParam)) >> 16)));
                handleTablineMouseUp(app, hwnd, @as(c_int, x), @as(c_int, y));
            }
            return 0;
        },
        c.WM_MOUSEMOVE => {
            const v = c.GetWindowLongPtrW(hwnd, c.GWLP_USERDATA);
            if (v != 0) {
                const app: *App = @ptrFromInt(@as(usize, @bitCast(v)));
                const x: i16 = @bitCast(@as(u16, @truncate(@as(usize, @bitCast(lParam)))));
                const y: i16 = @bitCast(@as(u16, @truncate(@as(usize, @bitCast(lParam)) >> 16)));
                handleTablineMouseMoveInChild(app, hwnd, @as(c_int, x), @as(c_int, y));
            }
            return 0;
        },
        c.WM_CAPTURECHANGED => {
            // Mouse capture lost - cancel any drag or button press
            const v = c.GetWindowLongPtrW(hwnd, c.GWLP_USERDATA);
            if (v != 0) {
                const app: *App = @ptrFromInt(@as(usize, @bitCast(v)));
                applog.appLog("[tabline] WM_CAPTURECHANGED: dragging_tab={?} is_external_drag={} close_button_pressed={?} new_tab_button_pressed={} pressed_window_btn={?}\n", .{ app.tabline_state.dragging_tab, app.tabline_state.is_external_drag, app.tabline_state.close_button_pressed, app.tabline_state.new_tab_button_pressed, app.tabline_state.pressed_window_btn });
                if (app.tabline_state.dragging_tab != null or app.tabline_state.close_button_pressed != null or app.tabline_state.new_tab_button_pressed or app.tabline_state.pressed_window_btn != null) {
                    applog.appLog("[tabline] WM_CAPTURECHANGED: cancelling drag/button!\n", .{});
                    destroyDragPreviewWindow(app);
                    app.tabline_state.cancelDrag();
                    _ = c.InvalidateRect(hwnd, null, 0);
                }
            }
            return 0;
        },
        c.WM_MOUSELEAVE => {
            const v = c.GetWindowLongPtrW(hwnd, c.GWLP_USERDATA);
            if (v != 0) {
                const app: *App = @ptrFromInt(@as(usize, @bitCast(v)));
                // Don't clear hover if dragging
                if (app.tabline_state.dragging_tab == null) {
                    if (app.tabline_state.hovered_tab != null or
                        app.tabline_state.hovered_close != null or
                        app.tabline_state.hovered_window_btn != null or
                        app.tabline_state.hovered_new_tab_btn)
                    {
                        app.tabline_state.hovered_tab = null;
                        app.tabline_state.hovered_close = null;
                        app.tabline_state.hovered_window_btn = null;
                        app.tabline_state.hovered_new_tab_btn = false;
                        _ = c.InvalidateRect(hwnd, null, 0);
                    }
                }
            }
            return 0;
        },
        else => return c.DefWindowProcW(hwnd, msg, wParam, lParam),
    }
}

// Content child window for D3D11 rendering (when ext_tabline enabled)
const content_class_name: [:0]const u16 = std.unicode.utf8ToUtf16LeStringLiteral("ZonvieContentClass");
var content_class_registered: bool = false;

fn registerContentWindowClass() bool {
    if (content_class_registered) return true;

    var wc: c.WNDCLASSEXW = std.mem.zeroes(c.WNDCLASSEXW);
    wc.cbSize = @sizeOf(c.WNDCLASSEXW);
    wc.style = c.CS_HREDRAW | c.CS_VREDRAW;
    wc.lpfnWndProc = contentWndProc;
    wc.hInstance = c.GetModuleHandleW(null);
    wc.hCursor = c.LoadCursorW(null, @ptrFromInt(32512)); // IDC_ARROW
    wc.hbrBackground = null;
    wc.lpszClassName = @ptrCast(content_class_name.ptr);

    if (c.RegisterClassExW(&wc) == 0) {
        if (applog.isEnabled()) applog.appLog("[win] Failed to register content window class\n", .{});
        return false;
    }

    content_class_registered = true;
    if (applog.isEnabled()) applog.appLog("[win] Content window class registered\n", .{});
    return true;
}

fn createContentWindow(parent_hwnd: c.HWND, app: *App) ?c.HWND {
    if (!registerContentWindowClass()) return null;

    var parent_rect: c.RECT = undefined;
    _ = c.GetClientRect(parent_hwnd, &parent_rect);

    const tabbar_height = TablineState.TAB_BAR_HEIGHT;
    const hwnd = c.CreateWindowExW(
        0,
        @ptrCast(content_class_name.ptr),
        null,
        c.WS_CHILD | c.WS_VISIBLE | c.WS_CLIPSIBLINGS,
        0,
        tabbar_height,
        parent_rect.right,
        @max(1, parent_rect.bottom - tabbar_height),
        parent_hwnd,
        null,
        c.GetModuleHandleW(null),
        @ptrCast(app),
    );

    if (hwnd == null) {
        if (applog.isEnabled()) applog.appLog("[win] Failed to create content window\n", .{});
        return null;
    }

    if (applog.isEnabled()) applog.appLog("[win] Content child window created\n", .{});
    return hwnd;
}

fn contentWndProc(hwnd: c.HWND, msg: c.UINT, wParam: c.WPARAM, lParam: c.LPARAM) callconv(.winapi) c.LRESULT {
    switch (msg) {
        c.WM_CREATE => {
            const cs: *c.CREATESTRUCTW = @ptrFromInt(@as(usize, @bitCast(lParam)));
            _ = c.SetWindowLongPtrW(hwnd, c.GWLP_USERDATA, @bitCast(@intFromPtr(cs.lpCreateParams)));
            return 0;
        },
        c.WM_PAINT => {
            // D3D11 rendering is triggered from main window's WM_PAINT.
            // This child window just needs to validate its region to prevent
            // continuous WM_PAINT messages.
            var ps: c.PAINTSTRUCT = undefined;
            _ = c.BeginPaint(hwnd, &ps);
            _ = c.EndPaint(hwnd, &ps);
            return 0;
        },
        // Forward mouse/keyboard events to parent window
        c.WM_LBUTTONDOWN, c.WM_LBUTTONUP, c.WM_RBUTTONDOWN, c.WM_RBUTTONUP,
        c.WM_MBUTTONDOWN, c.WM_MBUTTONUP, c.WM_MOUSEMOVE, c.WM_MOUSEWHEEL,
        c.WM_KEYDOWN, c.WM_KEYUP, c.WM_SYSKEYDOWN, c.WM_SYSKEYUP, c.WM_CHAR => {
            const v = c.GetWindowLongPtrW(hwnd, c.GWLP_USERDATA);
            if (v != 0) {
                const app: *App = @ptrFromInt(@as(usize, @bitCast(v)));
                if (app.hwnd) |main_hwnd| {
                    return c.SendMessageW(main_hwnd, msg, wParam, lParam);
                }
            }
            return c.DefWindowProcW(hwnd, msg, wParam, lParam);
        },
        c.WM_SETFOCUS => {
            // Keep focus on parent
            const v = c.GetWindowLongPtrW(hwnd, c.GWLP_USERDATA);
            if (v != 0) {
                const app: *App = @ptrFromInt(@as(usize, @bitCast(v)));
                if (app.hwnd) |main_hwnd| {
                    _ = c.SetFocus(main_hwnd);
                }
            }
            return 0;
        },
        else => return c.DefWindowProcW(hwnd, msg, wParam, lParam),
    }
}

fn handleTablineMouseMoveInChild(app: *App, hwnd: c.HWND, x: c_int, y: c_int) void {
    // Track mouse leave
    var tme: c.TRACKMOUSEEVENT = .{
        .cbSize = @sizeOf(c.TRACKMOUSEEVENT),
        .dwFlags = c.TME_LEAVE,
        .hwndTrack = hwnd,
        .dwHoverTime = 0,
    };
    _ = c.TrackMouseEvent(&tme);

    var rect: c.RECT = undefined;
    _ = c.GetClientRect(hwnd, &rect);
    const client_width = rect.right;

    // Handle dragging
    if (app.tabline_state.dragging_tab) |drag_idx| {
        app.tabline_state.drag_current_x = x;

        // Check if mouse is outside main window bounds (for external drag)
        var is_outside_window = false;
        if (app.hwnd) |main_hwnd| {
            var window_rect: c.RECT = undefined;
            if (c.GetWindowRect(main_hwnd, &window_rect) != 0) {
                // Convert client coords to screen coords
                var screen_pt: c.POINT = .{ .x = x, .y = y };
                _ = c.ClientToScreen(hwnd, &screen_pt);

                // Expand window rect by threshold
                const threshold = TablineState.EXTERNAL_DRAG_THRESHOLD;
                const expanded_left = window_rect.left - threshold;
                const expanded_top = window_rect.top - threshold;
                const expanded_right = window_rect.right + threshold;
                const expanded_bottom = window_rect.bottom + threshold;

                is_outside_window = (screen_pt.x < expanded_left or screen_pt.x > expanded_right or
                    screen_pt.y < expanded_top or screen_pt.y > expanded_bottom);

                if (is_outside_window and !app.tabline_state.is_external_drag) {
                    // Entering external drag mode
                    app.tabline_state.is_external_drag = true;
                    applog.appLog("[tabline] entering external drag mode for tab {d}\n", .{drag_idx});
                    createDragPreviewWindow(app, drag_idx, screen_pt.x, screen_pt.y);
                } else if (!is_outside_window and app.tabline_state.is_external_drag) {
                    // Returning to normal drag mode
                    app.tabline_state.is_external_drag = false;
                    applog.appLog("[tabline] returning to normal drag mode\n", .{});
                    destroyDragPreviewWindow(app);
                }

                if (app.tabline_state.is_external_drag) {
                    // Update preview window position
                    updateDragPreviewPosition(app, screen_pt.x, screen_pt.y);
                }
            }
        }

        // Normal in-window drag: calculate drop target
        if (!app.tabline_state.is_external_drag) {
            const available_width = client_width - TablineState.WINDOW_CONTROLS_WIDTH - 40 - TablineState.WINDOW_BTNS_TOTAL;
            const tab_count: c_int = @intCast(app.tabline_state.tab_count);
            if (tab_count > 0) {
                const ideal_width = @divTrunc(available_width, tab_count);
                const tab_width = @min(TablineState.TAB_MAX_WIDTH, @max(TablineState.TAB_MIN_WIDTH, ideal_width));

                // Find which slot the mouse is over
                var target_idx: usize = 0;
                var tab_x: c_int = TablineState.WINDOW_CONTROLS_WIDTH;
                for (0..app.tabline_state.tab_count) |i| {
                    const tab_center = tab_x + @divTrunc(tab_width, 2);
                    if (x < tab_center) {
                        target_idx = i;
                        break;
                    }
                    target_idx = i + 1;
                    tab_x += tab_width + 1;
                }
                // Clamp to valid range
                if (target_idx > app.tabline_state.tab_count) {
                    target_idx = app.tabline_state.tab_count;
                }
                app.tabline_state.drop_target_index = target_idx;
            }
        }

        // Clear hover states during drag
        app.tabline_state.hovered_tab = null;
        app.tabline_state.hovered_close = null;
        app.tabline_state.hovered_window_btn = null;
        app.tabline_state.hovered_new_tab_btn = false;

        _ = c.InvalidateRect(hwnd, null, 0);
        return;
    }

    // Handle close button pressed state - track if mouse leaves the button
    if (app.tabline_state.close_button_pressed) |pressed_tab_idx| {
        const available_width = client_width - TablineState.WINDOW_CONTROLS_WIDTH - 40 - TablineState.WINDOW_BTNS_TOTAL;
        const tab_count: c_int = @intCast(app.tabline_state.tab_count);
        if (tab_count > 0 and pressed_tab_idx < app.tabline_state.tab_count) {
            const ideal_width = @divTrunc(available_width, tab_count);
            const tab_width = @min(TablineState.TAB_MAX_WIDTH, @max(TablineState.TAB_MIN_WIDTH, ideal_width));

            const tab_x: c_int = TablineState.WINDOW_CONTROLS_WIDTH + @as(c_int, @intCast(pressed_tab_idx)) * (tab_width + 1);
            const close_x = tab_x + tab_width - TablineState.TAB_CLOSE_SIZE - 6;
            const close_y = @divTrunc(TablineState.TAB_BAR_HEIGHT - TablineState.TAB_CLOSE_SIZE, 2);

            const is_still_over_close = (x >= close_x and x < close_x + TablineState.TAB_CLOSE_SIZE and
                y >= close_y and y < close_y + TablineState.TAB_CLOSE_SIZE);

            if (!is_still_over_close) {
                // Mouse left the close button - cancel the press
                applog.appLog("[tabline] mouseMove: close button cancelled (mouse left)\n", .{});
                app.tabline_state.close_button_pressed = null;
                _ = c.ReleaseCapture();
                _ = c.InvalidateRect(hwnd, null, 0);
            }
        }
        // Clear hover states since we're in button-pressed mode
        app.tabline_state.hovered_tab = null;
        app.tabline_state.hovered_close = null;
        app.tabline_state.hovered_window_btn = null;
        app.tabline_state.hovered_new_tab_btn = false;
        return;
    }

    // Handle new tab button pressed state - track if mouse leaves the button
    if (app.tabline_state.new_tab_button_pressed) {
        const available_width = client_width - TablineState.WINDOW_CONTROLS_WIDTH - 40 - TablineState.WINDOW_BTNS_TOTAL;
        const tab_count: c_int = @intCast(app.tabline_state.tab_count);
        if (tab_count > 0) {
            const ideal_width = @divTrunc(available_width, tab_count);
            const tab_width = @min(TablineState.TAB_MAX_WIDTH, @max(TablineState.TAB_MIN_WIDTH, ideal_width));
            const plus_x = TablineState.WINDOW_CONTROLS_WIDTH + tab_count * (tab_width + 1) + 8;

            const is_still_over_plus = (x >= plus_x and x < plus_x + 20 and y >= 8 and y < 8 + 20);

            if (!is_still_over_plus) {
                // Mouse left the + button - cancel the press
                applog.appLog("[tabline] mouseMove: new tab button cancelled (mouse left)\n", .{});
                app.tabline_state.new_tab_button_pressed = false;
                app.tabline_state.hovered_new_tab_btn = false;
                _ = c.ReleaseCapture();
                _ = c.InvalidateRect(hwnd, null, 0);
            }
        }
        return;
    }

    // Handle window button pressed state - track if mouse leaves the button
    if (app.tabline_state.pressed_window_btn) |pressed_btn| {
        const btn_start_x = client_width - TablineState.WINDOW_BTNS_TOTAL;
        const btn_x = btn_start_x + @as(c_int, pressed_btn) * TablineState.WINDOW_BTN_WIDTH;
        const is_still_over_btn = (x >= btn_x and x < btn_x + TablineState.WINDOW_BTN_WIDTH and
            y >= 0 and y < TablineState.TAB_BAR_HEIGHT);

        if (!is_still_over_btn) {
            // Mouse left the window button - cancel the press
            applog.appLog("[tabline] mouseMove: window button {d} cancelled (mouse left)\n", .{pressed_btn});
            app.tabline_state.pressed_window_btn = null;
            _ = c.ReleaseCapture();
            _ = c.InvalidateRect(hwnd, null, 0);
        }
        return;
    }

    var new_hovered_tab: ?usize = null;
    var new_hovered_close: ?usize = null;
    var new_hovered_window_btn: ?u8 = null;

    // Check window control buttons first (they're on the right)
    const btn_start_x = client_width - TablineState.WINDOW_BTNS_TOTAL;
    if (x >= btn_start_x and y >= 0 and y < TablineState.TAB_BAR_HEIGHT) {
        const btn_idx = @divTrunc(x - btn_start_x, TablineState.WINDOW_BTN_WIDTH);
        if (btn_idx >= 0 and btn_idx < 3) {
            new_hovered_window_btn = @intCast(btn_idx);
        }
    } else {
        // Check tabs
        const available_width = client_width - TablineState.WINDOW_CONTROLS_WIDTH - 40 - TablineState.WINDOW_BTNS_TOTAL;
        const tab_count: c_int = @intCast(app.tabline_state.tab_count);
        if (tab_count > 0) {
            const ideal_width = @divTrunc(available_width, tab_count);
            const tab_width = @min(TablineState.TAB_MAX_WIDTH, @max(TablineState.TAB_MIN_WIDTH, ideal_width));

            var tab_x: c_int = TablineState.WINDOW_CONTROLS_WIDTH;
            for (0..app.tabline_state.tab_count) |i| {
                if (x >= tab_x and x < tab_x + tab_width) {
                    new_hovered_tab = i;

                    // Check close button
                    const close_x = tab_x + tab_width - TablineState.TAB_CLOSE_SIZE - 6;
                    const close_y = @divTrunc(TablineState.TAB_BAR_HEIGHT - TablineState.TAB_CLOSE_SIZE, 2);
                    if (x >= close_x and x < close_x + TablineState.TAB_CLOSE_SIZE and
                        y >= close_y and y < close_y + TablineState.TAB_CLOSE_SIZE)
                    {
                        new_hovered_close = i;
                    }
                    break;
                }
                tab_x += tab_width + 1;
            }
        }
    }

    // Check + button hover
    var new_hovered_new_tab_btn: bool = false;
    {
        const available_width_for_plus = client_width - TablineState.WINDOW_CONTROLS_WIDTH - 40 - TablineState.WINDOW_BTNS_TOTAL;
        const tab_count_for_plus: c_int = @intCast(app.tabline_state.tab_count);
        if (tab_count_for_plus > 0) {
            const ideal_width_for_plus = @divTrunc(available_width_for_plus, tab_count_for_plus);
            const tab_width_for_plus = @min(TablineState.TAB_MAX_WIDTH, @max(TablineState.TAB_MIN_WIDTH, ideal_width_for_plus));
            const plus_x = TablineState.WINDOW_CONTROLS_WIDTH + tab_count_for_plus * (tab_width_for_plus + 1) + 8;

            if (x >= plus_x and x < plus_x + 20 and y >= 8 and y < 8 + 20) {
                new_hovered_new_tab_btn = true;
            }
        }
    }

    if (new_hovered_tab != app.tabline_state.hovered_tab or
        new_hovered_close != app.tabline_state.hovered_close or
        new_hovered_window_btn != app.tabline_state.hovered_window_btn or
        new_hovered_new_tab_btn != app.tabline_state.hovered_new_tab_btn)
    {
        app.tabline_state.hovered_tab = new_hovered_tab;
        app.tabline_state.hovered_close = new_hovered_close;
        app.tabline_state.hovered_window_btn = new_hovered_window_btn;
        app.tabline_state.hovered_new_tab_btn = new_hovered_new_tab_btn;
        _ = c.InvalidateRect(hwnd, null, 0);
    }
}

/// Handle mouse down on tabline - start potential drag
fn handleTablineMouseDown(app: *App, hwnd: c.HWND, x: c_int, y: c_int) void {
    applog.appLog("[tabline] mouseDown: x={d} y={d}\n", .{ x, y });

    var rect: c.RECT = undefined;
    _ = c.GetClientRect(hwnd, &rect);
    const client_width = rect.right;

    // Check window control buttons first
    const btn_start_x = client_width - TablineState.WINDOW_BTNS_TOTAL;
    if (x >= btn_start_x and y >= 0 and y < TablineState.TAB_BAR_HEIGHT) {
        // Window button area - record pressed state, action on mouseUp
        const btn_idx = @divTrunc(x - btn_start_x, TablineState.WINDOW_BTN_WIDTH);
        if (btn_idx >= 0 and btn_idx < 3) {
            applog.appLog("[tabline] mouseDown: window button {d} pressed\n", .{btn_idx});
            app.tabline_state.pressed_window_btn = @intCast(btn_idx);
            _ = c.SetCapture(hwnd);
            _ = c.InvalidateRect(hwnd, null, 0);
        }
        return;
    }

    // Check close button on tabs
    const available_width = client_width - TablineState.WINDOW_CONTROLS_WIDTH - 40 - TablineState.WINDOW_BTNS_TOTAL;
    const tab_count: c_int = @intCast(app.tabline_state.tab_count);
    if (tab_count > 0) {
        const ideal_width = @divTrunc(available_width, tab_count);
        const tab_width = @min(TablineState.TAB_MAX_WIDTH, @max(TablineState.TAB_MIN_WIDTH, ideal_width));

        applog.appLog("[tabline] mouseDown: tab_count={d} tab_width={d}\n", .{ tab_count, tab_width });

        var tab_x: c_int = TablineState.WINDOW_CONTROLS_WIDTH;
        for (0..app.tabline_state.tab_count) |i| {
            if (x >= tab_x and x < tab_x + tab_width) {
                // Check if on close button
                const close_x = tab_x + tab_width - TablineState.TAB_CLOSE_SIZE - 6;
                const close_y = @divTrunc(TablineState.TAB_BAR_HEIGHT - TablineState.TAB_CLOSE_SIZE, 2);
                if (x >= close_x and x < close_x + TablineState.TAB_CLOSE_SIZE and
                    y >= close_y and y < close_y + TablineState.TAB_CLOSE_SIZE)
                {
                    // Close button - record pressed state, action on mouseUp
                    applog.appLog("[tabline] mouseDown: close button pressed on tab {d}\n", .{i});
                    app.tabline_state.close_button_pressed = i;
                    _ = c.SetCapture(hwnd);  // Capture to get mouseUp even if mouse leaves
                    _ = c.InvalidateRect(hwnd, null, 0);  // Redraw for pressed state
                    return;
                }

                // Start potential drag - first select this tab
                applog.appLog("[tabline] mouseDown: starting drag on tab {d}\n", .{i});
                app.tabline_state.drag_start_x = x;
                app.tabline_state.drag_offset_x = x - tab_x;
                app.tabline_state.drag_current_x = x;
                app.tabline_state.dragging_tab = i;
                app.tabline_state.drop_target_index = i;

                // Select the tab being dragged so :tabmove works on it
                if (app.corep) |corep| {
                    var cmd_buf: [16]u8 = undefined;
                    const cmd = std.fmt.bufPrint(&cmd_buf, "\x1b{d}gt", .{i + 1}) catch return;
                    core.zonvie_core_send_input(corep, cmd.ptr, cmd.len);
                }

                _ = c.SetCapture(hwnd);
                return;
            }
            tab_x += tab_width + 1;
        }
    }

    // Check + button
    const available_width_for_plus = client_width - TablineState.WINDOW_CONTROLS_WIDTH - 40 - TablineState.WINDOW_BTNS_TOTAL;
    const tab_count_for_plus: c_int = @intCast(app.tabline_state.tab_count);
    if (tab_count_for_plus > 0) {
        const ideal_width_for_plus = @divTrunc(available_width_for_plus, tab_count_for_plus);
        const tab_width_for_plus = @min(TablineState.TAB_MAX_WIDTH, @max(TablineState.TAB_MIN_WIDTH, ideal_width_for_plus));
        const plus_x = TablineState.WINDOW_CONTROLS_WIDTH + tab_count_for_plus * (tab_width_for_plus + 1) + 8;

        if (x >= plus_x and x < plus_x + 20) {
            // New tab button pressed - record state, action on mouseUp
            applog.appLog("[tabline] mouseDown: new tab button pressed\n", .{});
            app.tabline_state.new_tab_button_pressed = true;
            _ = c.SetCapture(hwnd);
            return;
        }
    }

    // Empty area - no action needed on mouseDown
}

/// Handle mouse up on tabline - finish drag or handle click
fn handleTablineMouseUp(app: *App, hwnd: c.HWND, x: c_int, y: c_int) void {
    applog.appLog("[tabline] mouseUp: x={d} y={d} dragging_tab={?} is_external_drag={} close_button_pressed={?}\n", .{ x, y, app.tabline_state.dragging_tab, app.tabline_state.is_external_drag, app.tabline_state.close_button_pressed });

    // Handle close button release first (before ReleaseCapture)
    // Note: If mouse moved away from close button, close_button_pressed was already
    // cleared in handleTablineMouseMoveInChild. So if we get here with close_button_pressed
    // still set, the mouse is still over the button and we should execute the close action.
    if (app.tabline_state.close_button_pressed) |pressed_tab_idx| {
        app.tabline_state.close_button_pressed = null;
        _ = c.ReleaseCapture();

        // Execute close action - mouse was still over button (otherwise mouseMove would have cancelled)
        applog.appLog("[tabline] mouseUp: close button released on tab {d}, closing\n", .{pressed_tab_idx});
        if (pressed_tab_idx < app.tabline_state.tab_count) {
            if (app.corep) |corep| {
                var cmd_buf: [32]u8 = undefined;
                const cmd = std.fmt.bufPrint(&cmd_buf, "{d}tabclose", .{pressed_tab_idx + 1}) catch return;
                core.zonvie_core_send_command(corep, cmd.ptr, cmd.len);
            }
        }
        _ = c.InvalidateRect(hwnd, null, 0);
        return;
    }

    // Handle new tab button release
    // Note: If mouse moved away, new_tab_button_pressed was already cleared in handleTablineMouseMoveInChild
    if (app.tabline_state.new_tab_button_pressed) {
        app.tabline_state.new_tab_button_pressed = false;
        _ = c.ReleaseCapture();

        // Execute new tab action
        applog.appLog("[tabline] mouseUp: new tab button released, creating new tab\n", .{});
        if (app.corep) |corep| {
            const cmd = "tabnew";
            core.zonvie_core_send_command(corep, cmd.ptr, cmd.len);
        }
        _ = c.InvalidateRect(hwnd, null, 0);
        return;
    }

    // Handle window button release (min/max/close)
    // Note: If mouse moved away, pressed_window_btn was already cleared in handleTablineMouseMoveInChild
    if (app.tabline_state.pressed_window_btn) |pressed_btn| {
        app.tabline_state.pressed_window_btn = null;
        _ = c.ReleaseCapture();

        // Execute window button action
        applog.appLog("[tabline] mouseUp: window button {d} released, executing action\n", .{pressed_btn});
        const main_hwnd = app.hwnd orelse return;
        if (pressed_btn == 0) {
            // Minimize
            _ = c.ShowWindow(main_hwnd, c.SW_MINIMIZE);
        } else if (pressed_btn == 1) {
            // Maximize / Restore
            if (c.IsZoomed(main_hwnd) != 0) {
                _ = c.ShowWindow(main_hwnd, c.SW_RESTORE);
            } else {
                _ = c.ShowWindow(main_hwnd, c.SW_MAXIMIZE);
            }
        } else if (pressed_btn == 2) {
            // Close
            _ = c.PostMessageW(main_hwnd, c.WM_CLOSE, 0, 0);
        }
        _ = c.InvalidateRect(hwnd, null, 0);
        return;
    }

    // Save drag state before ReleaseCapture, which triggers WM_CAPTURECHANGED synchronously
    const drag_idx_opt = app.tabline_state.dragging_tab;
    const drop_target_opt = app.tabline_state.drop_target_index;
    const drag_start = app.tabline_state.drag_start_x;
    const was_external_drag = app.tabline_state.is_external_drag;

    // Clear drag state and release capture
    app.tabline_state.cancelDrag();
    destroyDragPreviewWindow(app);
    _ = c.ReleaseCapture();

    if (drag_idx_opt) |drag_idx| {
        // Handle external drag: externalize the tab
        if (was_external_drag) {
            // Get screen position for external window placement
            var screen_pt: c.POINT = .{ .x = x, .y = y };
            _ = c.ClientToScreen(hwnd, &screen_pt);

            applog.appLog("[tabline] mouseUp: externalizing tab {d} at screen ({d},{d})\n", .{ drag_idx, screen_pt.x, screen_pt.y });
            externalizeTab(app, drag_idx, screen_pt.x, screen_pt.y);
            _ = c.InvalidateRect(hwnd, null, 0);
            return;
        }

        const moved_distance = if (x > drag_start)
            x - drag_start
        else
            drag_start - x;

        applog.appLog("[tabline] mouseUp: drag_idx={d} moved_distance={d} threshold={d}\n", .{ drag_idx, moved_distance, TablineState.DRAG_THRESHOLD });

        if (moved_distance < TablineState.DRAG_THRESHOLD) {
            // Didn't move enough - treat as click (select tab)
            // Tab was already selected on mouseDown, nothing more to do
        } else if (drop_target_opt) |target_idx| {
            // Actually moved - reorder tab
            const from_idx = drag_idx;
            const to_idx = target_idx;

            applog.appLog("[tabline] mouseUp: from_idx={d} to_idx={d} tab_count={d}\n", .{ from_idx, to_idx, app.tabline_state.tab_count });

            // Only move if target is different
            if (to_idx != from_idx and to_idx != from_idx + 1) {
                // First, select the tab we're dragging (if not already selected)
                // Then use :tabmove to reorder
                // :tabmove N moves current tab to position after tab N (1-based in the result)
                // :tabmove 0 moves to the beginning
                // :tabmove $ or large number moves to end

                // Calculate the target position for :tabmove
                // :tabmove N moves current tab to after tab N (1-based)
                // :tabmove 0 moves to the beginning
                // Match macOS implementation exactly
                var new_pos: i32 = 0;
                if (to_idx == 0) {
                    new_pos = 0;  // Move to first position
                } else if (to_idx >= app.tabline_state.tab_count) {
                    // Move to end
                    new_pos = @intCast(app.tabline_state.tab_count);
                } else {
                    // Middle position: to_idx - 1 (works for both directions)
                    new_pos = @intCast(to_idx - 1);
                }

                applog.appLog("[tabline] mouseUp: calculated new_pos={d}\n", .{new_pos});

                if (app.corep) |corep| {
                    // Tab was already selected on mouseDown, just send :tabmove
                    // Use nvim_command API so command doesn't show in cmdline
                    var cmd_buf: [32]u8 = undefined;
                    const cmd = std.fmt.bufPrint(&cmd_buf, "tabmove {d}", .{new_pos}) catch {
                        _ = c.InvalidateRect(hwnd, null, 0);
                        return;
                    };
                    applog.appLog("[tabline] mouseUp: sending cmd len={d}\n", .{cmd.len});
                    core.zonvie_core_send_command(corep, cmd.ptr, cmd.len);
                }
            } else {
                applog.appLog("[tabline] mouseUp: no move needed (same position)\n", .{});
            }
        }
        _ = c.InvalidateRect(hwnd, null, 0);
    }
    // Note: No else branch needed here. Close buttons and window buttons are
    // handled on mouseDown. Tab selection is also done on mouseDown when
    // starting a drag. Calling handleTablineClick here would cause double-action.
}

// ---- Tab Externalization Functions ----

/// Create a floating preview window when dragging tab outside main window
fn createDragPreviewWindow(app: *App, tab_idx: usize, screen_x: c_int, screen_y: c_int) void {
    if (app.tabline_state.drag_preview_hwnd != null) return;
    if (tab_idx >= app.tabline_state.tab_count) return;

    // Ensure window class is registered
    if (!ensureDragPreviewClassRegistered()) return;

    const preview_w: c_int = 150;
    const preview_h: c_int = 30;

    // Create borderless popup window
    const dwExStyle: c.DWORD = c.WS_EX_TOPMOST | c.WS_EX_TOOLWINDOW | c.WS_EX_NOACTIVATE;
    const dwStyle: c.DWORD = c.WS_POPUP;

    const pos_x = screen_x - @divTrunc(preview_w, 2);
    const pos_y = screen_y - @divTrunc(preview_h, 2);

    const preview_hwnd = c.CreateWindowExW(
        dwExStyle,
        @ptrCast(drag_preview_class_name.ptr),
        null,
        dwStyle,
        pos_x,
        pos_y,
        preview_w,
        preview_h,
        null,
        null,
        c.GetModuleHandleW(null),
        null,
    );

    if (preview_hwnd == null) {
        applog.appLog("[tabline] failed to create drag preview window\n", .{});
        return;
    }

    // Store app pointer for WM_PAINT
    _ = c.SetWindowLongPtrW(preview_hwnd, c.GWLP_USERDATA, @bitCast(@intFromPtr(app)));

    app.tabline_state.drag_preview_hwnd = preview_hwnd;
    _ = c.ShowWindow(preview_hwnd, c.SW_SHOWNOACTIVATE);
    applog.appLog("[tabline] created drag preview window at ({d},{d})\n", .{ pos_x, pos_y });
}

/// Update the position of the drag preview window
fn updateDragPreviewPosition(app: *App, screen_x: c_int, screen_y: c_int) void {
    if (app.tabline_state.drag_preview_hwnd) |preview_hwnd| {
        const preview_w: c_int = 150;
        const preview_h: c_int = 30;
        const pos_x = screen_x - @divTrunc(preview_w, 2);
        const pos_y = screen_y - @divTrunc(preview_h, 2);
        _ = c.SetWindowPos(preview_hwnd, null, pos_x, pos_y, 0, 0, c.SWP_NOSIZE | c.SWP_NOZORDER | c.SWP_NOACTIVATE);
    }
}

/// Destroy the drag preview window
fn destroyDragPreviewWindow(app: *App) void {
    if (app.tabline_state.drag_preview_hwnd) |preview_hwnd| {
        _ = c.DestroyWindow(preview_hwnd);
        app.tabline_state.drag_preview_hwnd = null;
        applog.appLog("[tabline] destroyed drag preview window\n", .{});
    }
}

/// Externalize a tab by creating an external Neovim window
fn externalizeTab(app: *App, tab_idx: usize, screen_x: c_int, screen_y: c_int) void {
    applog.appLog("[tabline] externalizeTab: tab_idx={d} screen=({d},{d})\n", .{ tab_idx, screen_x, screen_y });

    if (app.corep == null) {
        applog.appLog("[tabline] externalizeTab: corep is null\n", .{});
        return;
    }
    const corep = app.corep.?;

    if (tab_idx >= app.tabline_state.tab_count) {
        applog.appLog("[tabline] externalizeTab: tab_idx out of range\n", .{});
        return;
    }

    // Set pending position for the new external window (with timestamp for timeout)
    app.pending_external_window_position = .{ .x = screen_x, .y = screen_y };
    app.pending_external_window_position_time = std.time.milliTimestamp();

    // Execute single Lua script that does both tab switch and externalization atomically.
    // This avoids race condition between nvim_input (tab switch) and nvim_command (Lua).
    // Use zonvie_core_send_command (nvim_command RPC) so it doesn't show in cmdline.
    // The Lua script:
    // 1. Switch to the target tab
    // 2. Check if tab has multiple windows (split) - abort if so
    // 3. Get current window dimensions
    // 4. Create new split with empty buffer (so main window isn't empty)
    // 5. Externalize the original window
    const tab_number = tab_idx + 1;
    var lua_buf: [512]u8 = undefined;
    const lua_script = std.fmt.bufPrint(&lua_buf, "lua vim.cmd('{d}tabnext'); local tp=vim.api.nvim_get_current_tabpage(); local ws=vim.api.nvim_tabpage_list_wins(tp); if #ws>1 then vim.notify('Cannot externalize: split window',vim.log.levels.WARN); return end; local w=ws[1]; local W=vim.api.nvim_win_get_width(w); local H=vim.api.nvim_win_get_height(w); vim.cmd('vnew'); vim.api.nvim_win_set_config(w,{{external=true,width=W,height=H}}); vim.api.nvim_set_current_win(w)", .{tab_number}) catch {
        applog.appLog("[tabline] externalizeTab: failed to format Lua script\n", .{});
        return;
    };
    applog.appLog("[tabline] externalizeTab: sending Lua script via command\n", .{});
    core.zonvie_core_send_command(corep, lua_script.ptr, lua_script.len);
}

// Drag preview window class
const drag_preview_class_name: [:0]const u16 = std.unicode.utf8ToUtf16LeStringLiteral("ZonvieDragPreviewClass");
var drag_preview_class_registered: bool = false;

fn ensureDragPreviewClassRegistered() bool {
    if (drag_preview_class_registered) return true;

    var wc: c.WNDCLASSEXW = std.mem.zeroes(c.WNDCLASSEXW);
    wc.cbSize = @sizeOf(c.WNDCLASSEXW);
    wc.lpfnWndProc = dragPreviewWndProc;
    wc.hInstance = c.GetModuleHandleW(null);
    wc.hCursor = c.LoadCursorW(null, @ptrFromInt(32512)); // IDC_ARROW
    wc.hbrBackground = null;
    wc.lpszClassName = @ptrCast(drag_preview_class_name.ptr);

    if (c.RegisterClassExW(&wc) == 0) {
        applog.appLog("[win] Failed to register drag preview window class\n", .{});
        return false;
    }

    drag_preview_class_registered = true;
    return true;
}

fn dragPreviewWndProc(hwnd: c.HWND, msg: c.UINT, wParam: c.WPARAM, lParam: c.LPARAM) callconv(.winapi) c.LRESULT {
    switch (msg) {
        c.WM_PAINT => {
            var ps: c.PAINTSTRUCT = undefined;
            const hdc = c.BeginPaint(hwnd, &ps);
            if (hdc != null) {
                var rect: c.RECT = undefined;
                _ = c.GetClientRect(hwnd, &rect);

                // Fill with light background
                const bg_brush = c.CreateSolidBrush(c.RGB(240, 240, 240));
                _ = c.FillRect(hdc, &rect, bg_brush);
                _ = c.DeleteObject(bg_brush);

                // Draw border
                const border_brush = c.CreateSolidBrush(c.RGB(180, 180, 180));
                _ = c.FrameRect(hdc, &rect, border_brush);
                _ = c.DeleteObject(border_brush);

                // Draw tab name
                const app_ptr = c.GetWindowLongPtrW(hwnd, c.GWLP_USERDATA);
                if (app_ptr != 0) {
                    const app: *App = @ptrFromInt(@as(usize, @bitCast(app_ptr)));
                    if (app.tabline_state.dragging_tab) |drag_idx| {
                        if (drag_idx < app.tabline_state.tab_count) {
                            const tab = &app.tabline_state.tabs[drag_idx];
                            if (tab.name_len > 0) {
                                // Get just the filename
                                var display_name: []const u8 = tab.name[0..tab.name_len];
                                var last_sep: usize = 0;
                                for (display_name, 0..) |ch, i| {
                                    if (ch == '/' or ch == '\\') {
                                        last_sep = i + 1;
                                    }
                                }
                                if (last_sep < display_name.len) {
                                    display_name = display_name[last_sep..];
                                }

                                // Draw text
                                var text_rect = rect;
                                text_rect.left += 10;
                                text_rect.right -= 10;
                                _ = c.SetBkMode(hdc, c.TRANSPARENT);
                                _ = c.SetTextColor(hdc, c.RGB(0, 0, 0));

                                // Convert UTF-8 to UTF-16
                                var wide_buf: [128]u16 = undefined;
                                const wide_len = std.unicode.utf8ToUtf16Le(&wide_buf, display_name) catch 0;
                                if (wide_len > 0) {
                                    _ = c.DrawTextW(hdc, &wide_buf, @intCast(wide_len), &text_rect, c.DT_SINGLELINE | c.DT_VCENTER | c.DT_CENTER | c.DT_END_ELLIPSIS);
                                }
                            } else {
                                // No name
                                const no_name = [_]u16{ '[', 'N', 'o', ' ', 'N', 'a', 'm', 'e', ']', 0 };
                                var text_rect = rect;
                                text_rect.left += 10;
                                text_rect.right -= 10;
                                _ = c.SetBkMode(hdc, c.TRANSPARENT);
                                _ = c.SetTextColor(hdc, c.RGB(128, 128, 128));
                                _ = c.DrawTextW(hdc, &no_name, 9, &text_rect, c.DT_SINGLELINE | c.DT_VCENTER | c.DT_CENTER);
                            }
                        }
                    }
                }

                _ = c.EndPaint(hwnd, &ps);
            }
            return 0;
        },
        else => return c.DefWindowProcW(hwnd, msg, wParam, lParam),
    }
}

/// Render tabline to D3D11 texture via offscreen GDI bitmap.
/// This avoids DWM composition issues by keeping GDI rendering offscreen
/// and only using D3D11 for final display.
fn renderTablineToD3D(app: *App, width: u32, height: u32) void {
    if (app.renderer == null) return;
    if (app.tabline_state.tab_count == 0) return;
    if (width == 0 or height == 0) return;

    // Create memory DC and DIB section
    const screen_dc = c.GetDC(null);
    if (screen_dc == null) return;
    defer _ = c.ReleaseDC(null, screen_dc);

    const mem_dc = c.CreateCompatibleDC(screen_dc);
    if (mem_dc == null) return;
    defer _ = c.DeleteDC(mem_dc);

    // Create DIB section (32-bit BGRA)
    var bmi: c.BITMAPINFO = std.mem.zeroes(c.BITMAPINFO);
    bmi.bmiHeader.biSize = @sizeOf(c.BITMAPINFOHEADER);
    bmi.bmiHeader.biWidth = @intCast(width);
    bmi.bmiHeader.biHeight = -@as(c.LONG, @intCast(height)); // Top-down
    bmi.bmiHeader.biPlanes = 1;
    bmi.bmiHeader.biBitCount = 32;
    bmi.bmiHeader.biCompression = c.BI_RGB;

    var pixels_ptr: ?*anyopaque = null;
    const dib = c.CreateDIBSection(mem_dc, &bmi, c.DIB_RGB_COLORS, &pixels_ptr, null, 0);
    if (dib == null or pixels_ptr == null) return;
    defer _ = c.DeleteObject(dib);

    const old_bmp = c.SelectObject(mem_dc, dib);
    defer _ = c.SelectObject(mem_dc, old_bmp);

    // Draw tabline to the memory DC
    drawTablineContent(app, mem_dc, @intCast(width));

    // GDI doesn't set alpha channel, so we need to set it to 255 (opaque)
    const pixels: [*]u8 = @ptrCast(pixels_ptr);
    const pixel_count = width * height;
    var i: u32 = 0;
    while (i < pixel_count) : (i += 1) {
        pixels[i * 4 + 3] = 255; // Set alpha to opaque
    }

    // Update D3D11 texture
    const pixel_data = pixels[0 .. width * height * 4];
    if (app.renderer) |*g| {
        g.updateTablineTexture(width, height, pixel_data) catch |e| {
            applog.appLog("[tabline] updateTablineTexture failed: {any}\n", .{e});
        };
    }
}

/// Draw tabline content (called from offscreen DC or child window WM_PAINT)
fn drawTablineContent(app: *App, hdc: c.HDC, client_width: c_int) void {
    if (app.tabline_state.tab_count == 0) {
        return;
    }

    const bar_height = TablineState.TAB_BAR_HEIGHT;
    const is_dragging = app.tabline_state.dragging_tab != null;

    // Background
    const bg_brush = c.CreateSolidBrush(c.RGB(240, 240, 240));
    defer _ = c.DeleteObject(bg_brush);
    var bar_rect = c.RECT{
        .left = 0,
        .top = 0,
        .right = client_width,
        .bottom = bar_height,
    };
    _ = c.FillRect(hdc, &bar_rect, bg_brush);

    // Calculate tab width
    const available_width = client_width - TablineState.WINDOW_CONTROLS_WIDTH - 40 - TablineState.WINDOW_BTNS_TOTAL;
    const tab_count: c_int = @intCast(app.tabline_state.tab_count);
    const ideal_width = @divTrunc(available_width, tab_count);
    const tab_width = @min(TablineState.TAB_MAX_WIDTH, @max(TablineState.TAB_MIN_WIDTH, ideal_width));

    // Brushes
    const selected_brush = c.CreateSolidBrush(c.RGB(255, 255, 255));
    const hover_brush = c.CreateSolidBrush(c.RGB(230, 230, 230));
    const normal_brush = c.CreateSolidBrush(c.RGB(220, 220, 220));
    const dragging_brush = c.CreateSolidBrush(c.RGB(200, 220, 255));  // Light blue for dragging tab
    defer {
        _ = c.DeleteObject(selected_brush);
        _ = c.DeleteObject(hover_brush);
        _ = c.DeleteObject(normal_brush);
        _ = c.DeleteObject(dragging_brush);
    }

    // Font
    const font = c.CreateFontW(
        -12, 0, 0, 0, c.FW_NORMAL, 0, 0, 0,
        c.DEFAULT_CHARSET, c.OUT_DEFAULT_PRECIS, c.CLIP_DEFAULT_PRECIS,
        c.CLEARTYPE_QUALITY, c.DEFAULT_PITCH | c.FF_DONTCARE, null,
    );
    defer _ = c.DeleteObject(font);
    const old_font = c.SelectObject(hdc, font);
    defer _ = c.SelectObject(hdc, old_font);

    _ = c.SetBkMode(hdc, c.TRANSPARENT);

    // Check if mouse has moved beyond drag threshold (for visual feedback)
    const is_actually_dragging = if (is_dragging) blk: {
        const moved_distance = if (app.tabline_state.drag_current_x > app.tabline_state.drag_start_x)
            app.tabline_state.drag_current_x - app.tabline_state.drag_start_x
        else
            app.tabline_state.drag_start_x - app.tabline_state.drag_current_x;
        break :blk moved_distance >= TablineState.DRAG_THRESHOLD;
    } else false;

    var x: c_int = TablineState.WINDOW_CONTROLS_WIDTH;

    // First pass: draw all tabs (with placeholder for dragged tab)
    for (0..app.tabline_state.tab_count) |i| {
        const tab = &app.tabline_state.tabs[i];
        const is_selected = tab.handle == app.tabline_state.current_tab;
        const is_hovered = app.tabline_state.hovered_tab == i;
        const is_being_dragged = is_actually_dragging and app.tabline_state.dragging_tab == i;

        var tab_rect = c.RECT{
            .left = x + 1,
            .top = 4,
            .right = x + tab_width - 1,
            .bottom = bar_height,
        };

        // If this tab is being dragged (moved beyond threshold), draw a placeholder (dimmed)
        if (is_being_dragged) {
            // Draw dimmed placeholder
            const placeholder_brush = c.CreateSolidBrush(c.RGB(200, 200, 200));
            _ = c.FillRect(hdc, &tab_rect, placeholder_brush);
            _ = c.DeleteObject(placeholder_brush);
            x += tab_width + 1;
            continue;
        }

        // Background
        const brush = if (is_selected) selected_brush else if (is_hovered) hover_brush else normal_brush;
        _ = c.FillRect(hdc, &tab_rect, brush);

        // Tab name
        _ = c.SetTextColor(hdc, if (is_selected) c.RGB(0, 0, 0) else c.RGB(80, 80, 80));

        var text_rect = c.RECT{
            .left = x + TablineState.TAB_PADDING,
            .top = 4,
            .right = x + tab_width - TablineState.TAB_PADDING - TablineState.TAB_CLOSE_SIZE - 4,
            .bottom = bar_height,
        };

        // Convert name to display
        var display_name: [256]u8 = undefined;
        var display_len: usize = 0;

        if (tab.name_len > 0) {
            // Find last path separator
            var last_sep: usize = 0;
            for (0..tab.name_len) |j| {
                if (tab.name[j] == '/' or tab.name[j] == '\\') {
                    last_sep = j + 1;
                }
            }
            display_len = tab.name_len - last_sep;
            @memcpy(display_name[0..display_len], tab.name[last_sep..tab.name_len]);
        } else {
            const no_name = "[No Name]";
            display_len = no_name.len;
            @memcpy(display_name[0..display_len], no_name);
        }

        // Convert to wide string
        var wide_buf: [256]u16 = undefined;
        const wide_len = std.unicode.utf8ToUtf16Le(&wide_buf, display_name[0..display_len]) catch 0;

        _ = c.DrawTextW(hdc, &wide_buf, @intCast(wide_len), &text_rect, c.DT_LEFT | c.DT_VCENTER | c.DT_SINGLELINE | c.DT_END_ELLIPSIS);

        // Close button (X) - show on selected or hovered tabs
        if (is_selected or is_hovered) {
            const close_x = x + tab_width - TablineState.TAB_CLOSE_SIZE - 6;
            const close_y = @divTrunc(bar_height - TablineState.TAB_CLOSE_SIZE, 2);

            // Highlight if close button hovered
            if (app.tabline_state.hovered_close == i) {
                const highlight_brush = c.CreateSolidBrush(c.RGB(200, 200, 200));
                var close_rect = c.RECT{
                    .left = close_x,
                    .top = close_y,
                    .right = close_x + TablineState.TAB_CLOSE_SIZE,
                    .bottom = close_y + TablineState.TAB_CLOSE_SIZE,
                };
                _ = c.FillRect(hdc, &close_rect, highlight_brush);
                _ = c.DeleteObject(highlight_brush);
            }

            // Draw X
            const pen = c.CreatePen(c.PS_SOLID, 1, c.RGB(100, 100, 100));
            const old_pen = c.SelectObject(hdc, pen);
            const inset: c_int = 3;
            _ = c.MoveToEx(hdc, close_x + inset, close_y + inset, null);
            _ = c.LineTo(hdc, close_x + TablineState.TAB_CLOSE_SIZE - inset, close_y + TablineState.TAB_CLOSE_SIZE - inset);
            _ = c.MoveToEx(hdc, close_x + TablineState.TAB_CLOSE_SIZE - inset, close_y + inset, null);
            _ = c.LineTo(hdc, close_x + inset, close_y + TablineState.TAB_CLOSE_SIZE - inset);
            _ = c.SelectObject(hdc, old_pen);
            _ = c.DeleteObject(pen);
        }

        x += tab_width + 1;
    }

    // Draw new tab button (+)
    const plus_x = x + 8;
    const plus_y = @divTrunc(bar_height - 20, 2);
    const plus_size: c_int = 20;
    {
        // Draw hover background (circular) if hovered
        if (app.tabline_state.hovered_new_tab_btn) {
            const plus_hover_brush = c.CreateSolidBrush(c.RGB(200, 200, 200));
            _ = c.SelectObject(hdc, plus_hover_brush);
            const null_pen = c.GetStockObject(c.NULL_PEN);
            const old_pen_hover = c.SelectObject(hdc, null_pen);
            _ = c.Ellipse(hdc, plus_x, plus_y, plus_x + plus_size, plus_y + plus_size);
            _ = c.SelectObject(hdc, old_pen_hover);
            _ = c.DeleteObject(plus_hover_brush);
        }

        // Draw + icon
        const pen = c.CreatePen(c.PS_SOLID, 2, c.RGB(100, 100, 100));
        const old_pen = c.SelectObject(hdc, pen);
        const icon_inset: c_int = 5;
        _ = c.MoveToEx(hdc, plus_x + @divTrunc(plus_size, 2), plus_y + icon_inset, null);
        _ = c.LineTo(hdc, plus_x + @divTrunc(plus_size, 2), plus_y + plus_size - icon_inset);
        _ = c.MoveToEx(hdc, plus_x + icon_inset, plus_y + @divTrunc(plus_size, 2), null);
        _ = c.LineTo(hdc, plus_x + plus_size - icon_inset, plus_y + @divTrunc(plus_size, 2));
        _ = c.SelectObject(hdc, old_pen);
        _ = c.DeleteObject(pen);
    }

    // Draw window control buttons (min, max, close) on the right
    const btn_w = TablineState.WINDOW_BTN_WIDTH;
    const btn_start_x = client_width - TablineState.WINDOW_BTNS_TOTAL;

    // Check hover states
    const hovered_btn = app.tabline_state.hovered_window_btn;

    // Minimize button
    {
        const btn_x = btn_start_x;
        var btn_rect = c.RECT{ .left = btn_x, .top = 0, .right = btn_x + btn_w, .bottom = bar_height };

        // Hover highlight
        if (hovered_btn == 0) {
            const min_hover_brush = c.CreateSolidBrush(c.RGB(230, 230, 230));
            _ = c.FillRect(hdc, &btn_rect, min_hover_brush);
            _ = c.DeleteObject(min_hover_brush);
        }

        // Draw minimize icon (horizontal line)
        const min_icon_pen = c.CreatePen(c.PS_SOLID, 1, c.RGB(50, 50, 50));
        const old_min_icon_pen = c.SelectObject(hdc, min_icon_pen);
        const icon_y = @divTrunc(bar_height, 2);
        _ = c.MoveToEx(hdc, btn_x + 18, icon_y, null);
        _ = c.LineTo(hdc, btn_x + 28, icon_y);
        _ = c.SelectObject(hdc, old_min_icon_pen);
        _ = c.DeleteObject(min_icon_pen);
    }

    // Maximize button
    {
        const btn_x = btn_start_x + btn_w;
        var btn_rect = c.RECT{ .left = btn_x, .top = 0, .right = btn_x + btn_w, .bottom = bar_height };

        // Hover highlight
        if (hovered_btn == 1) {
            const max_hover_brush = c.CreateSolidBrush(c.RGB(230, 230, 230));
            _ = c.FillRect(hdc, &btn_rect, max_hover_brush);
            _ = c.DeleteObject(max_hover_brush);
        }

        // Draw maximize icon (rectangle)
        const max_icon_pen = c.CreatePen(c.PS_SOLID, 1, c.RGB(50, 50, 50));
        const old_max_icon_pen = c.SelectObject(hdc, max_icon_pen);
        const max_null_brush = c.GetStockObject(c.NULL_BRUSH);
        const old_max_brush = c.SelectObject(hdc, max_null_brush);
        const max_icon_top = @divTrunc(bar_height - 10, 2);
        _ = c.Rectangle(hdc, btn_x + 18, max_icon_top, btn_x + 28, max_icon_top + 10);
        _ = c.SelectObject(hdc, old_max_brush);
        _ = c.SelectObject(hdc, old_max_icon_pen);
        _ = c.DeleteObject(max_icon_pen);
    }

    // Close button
    {
        const btn_x = btn_start_x + btn_w * 2;
        var btn_rect = c.RECT{ .left = btn_x, .top = 0, .right = btn_x + btn_w, .bottom = bar_height };

        // Red hover highlight for close button
        if (hovered_btn == 2) {
            const close_hover_brush = c.CreateSolidBrush(c.RGB(232, 17, 35));  // Red
            _ = c.FillRect(hdc, &btn_rect, close_hover_brush);
            _ = c.DeleteObject(close_hover_brush);
        }

        // Draw X icon
        const close_icon_color = if (hovered_btn == 2) c.RGB(255, 255, 255) else c.RGB(50, 50, 50);
        const close_icon_pen = c.CreatePen(c.PS_SOLID, 1, close_icon_color);
        const old_close_icon_pen = c.SelectObject(hdc, close_icon_pen);
        const close_icon_top = @divTrunc(bar_height - 10, 2);
        _ = c.MoveToEx(hdc, btn_x + 18, close_icon_top, null);
        _ = c.LineTo(hdc, btn_x + 28, close_icon_top + 10);
        _ = c.MoveToEx(hdc, btn_x + 28, close_icon_top, null);
        _ = c.LineTo(hdc, btn_x + 18, close_icon_top + 10);
        _ = c.SelectObject(hdc, old_close_icon_pen);
        _ = c.DeleteObject(close_icon_pen);
    }

    // Draw drop indicator and floating tab only when actually dragging (moved beyond threshold)
    if (is_actually_dragging) {
        if (app.tabline_state.drop_target_index) |target_idx| {
            const drag_idx = app.tabline_state.dragging_tab orelse 0;
            // Only show indicator if target is different from current position
            if (target_idx != drag_idx and target_idx != drag_idx + 1) {
                const indicator_x: c_int = TablineState.WINDOW_CONTROLS_WIDTH + @as(c_int, @intCast(target_idx)) * (tab_width + 1);
                const indicator_pen = c.CreatePen(c.PS_SOLID, 2, c.RGB(0, 120, 215));  // Blue indicator
                const old_indicator_pen = c.SelectObject(hdc, indicator_pen);
                _ = c.MoveToEx(hdc, indicator_x, 2, null);
                _ = c.LineTo(hdc, indicator_x, bar_height - 2);
                _ = c.SelectObject(hdc, old_indicator_pen);
                _ = c.DeleteObject(indicator_pen);
            }
        }

        // Draw floating tab at cursor position
        if (app.tabline_state.dragging_tab) |drag_idx| {
            const tab = &app.tabline_state.tabs[drag_idx];

            // Calculate floating tab position - centered on cursor
            const float_x = app.tabline_state.drag_current_x - app.tabline_state.drag_offset_x;
            var float_rect = c.RECT{
                .left = float_x + 1,
                .top = 4,
                .right = float_x + tab_width - 1,
                .bottom = bar_height,
            };

            // Draw floating tab with blue tint (semi-transparent effect via color)
            const float_brush = c.CreateSolidBrush(c.RGB(200, 220, 255));  // Light blue
            _ = c.FillRect(hdc, &float_rect, float_brush);
            _ = c.DeleteObject(float_brush);

            // Draw border for floating tab
            const border_pen = c.CreatePen(c.PS_SOLID, 1, c.RGB(0, 120, 215));
            const old_border_pen = c.SelectObject(hdc, border_pen);
            const float_null_brush = c.GetStockObject(c.NULL_BRUSH);
            const old_float_brush = c.SelectObject(hdc, float_null_brush);
            _ = c.Rectangle(hdc, float_rect.left, float_rect.top, float_rect.right, float_rect.bottom);
            _ = c.SelectObject(hdc, old_float_brush);
            _ = c.SelectObject(hdc, old_border_pen);
            _ = c.DeleteObject(border_pen);

            // Draw tab name on floating tab
            _ = c.SetTextColor(hdc, c.RGB(0, 0, 0));
            var float_text_rect = c.RECT{
                .left = float_x + TablineState.TAB_PADDING,
                .top = 4,
                .right = float_x + tab_width - TablineState.TAB_PADDING,
                .bottom = bar_height,
            };

            // Convert name to display
            var float_display_name: [256]u8 = undefined;
            var float_display_len: usize = 0;

            if (tab.name_len > 0) {
                var last_sep: usize = 0;
                for (0..tab.name_len) |j| {
                    if (tab.name[j] == '/' or tab.name[j] == '\\') {
                        last_sep = j + 1;
                    }
                }
                float_display_len = tab.name_len - last_sep;
                @memcpy(float_display_name[0..float_display_len], tab.name[last_sep..tab.name_len]);
            } else {
                const no_name = "[No Name]";
                float_display_len = no_name.len;
                @memcpy(float_display_name[0..float_display_len], no_name);
            }

            var float_wide_buf: [256]u16 = undefined;
            const float_wide_len = std.unicode.utf8ToUtf16Le(&float_wide_buf, float_display_name[0..float_display_len]) catch 0;
            _ = c.DrawTextW(hdc, &float_wide_buf, @intCast(float_wide_len), &float_text_rect, c.DT_LEFT | c.DT_VCENTER | c.DT_SINGLELINE | c.DT_END_ELLIPSIS);
        }
    }
}

// ext_tabline callbacks

fn onTablineUpdate(
    ctx: ?*anyopaque,
    curtab: i64,
    tabs: ?[*]const core.TabEntry,
    tab_count: usize,
    _: i64, // curbuf
    _: ?[*]const core.BufferEntry, // buffers
    _: usize, // buffer_count
) callconv(.c) void {
    const app: *App = @ptrCast(@alignCast(ctx.?));

    {
        app.mu.lock();
        defer app.mu.unlock();

        app.tabline_state.clear();
        app.tabline_state.current_tab = curtab;
        app.tabline_state.visible = tab_count > 0;

        if (tabs) |t| {
            const count = @min(tab_count, 32);  // Max 32 tabs
            for (0..count) |i| {
                app.tabline_state.tabs[i].handle = t[i].tab_handle;
                const name_len = @min(t[i].name_len, 255);
                if (name_len > 0) {
                    @memcpy(app.tabline_state.tabs[i].name[0..name_len], t[i].name[0..name_len]);
                }
                app.tabline_state.tabs[i].name_len = name_len;
            }
            app.tabline_state.tab_count = count;
        }
    }

    // Request repaint via PostMessage to UI thread
    // Tabline is now drawn on parent window, so invalidate parent
    if (app.hwnd) |main_hwnd| {
        _ = c.PostMessageW(main_hwnd, WM_APP_TABLINE_INVALIDATE, 0, 0);
    }
}

fn onTablineHide(ctx: ?*anyopaque) callconv(.c) void {
    const app: *App = @ptrCast(@alignCast(ctx.?));
    if (applog.isEnabled()) applog.appLog("[win] on_tabline_hide\n", .{});

    app.mu.lock();
    app.tabline_state.visible = false;
    app.mu.unlock();

    // Hide child window
    if (app.tabline_state.hwnd) |tabline_hwnd| {
        _ = c.ShowWindow(tabline_hwnd, c.SW_HIDE);
    }
}

/// Draw tabline bar using GDI
fn drawTabline(app: *App, hdc: c.HDC, client_width: c_int) void {
    if (!app.ext_tabline_enabled or !app.tabline_state.visible) return;
    if (app.tabline_state.tab_count == 0) return;

    applog.appLog("[win] drawTabline: tab_count={d} current_tab={d} width={d}\n", .{
        app.tabline_state.tab_count,
        app.tabline_state.current_tab,
        client_width,
    });

    const bar_height = TablineState.TAB_BAR_HEIGHT;

    // Background
    const bg_brush = c.CreateSolidBrush(c.RGB(240, 240, 240));
    defer _ = c.DeleteObject(bg_brush);
    var bar_rect = c.RECT{
        .left = 0,
        .top = 0,
        .right = client_width,
        .bottom = bar_height,
    };
    _ = c.FillRect(hdc, &bar_rect, bg_brush);

    // Calculate tab width
    const available_width = client_width - TablineState.WINDOW_CONTROLS_WIDTH - 40 - TablineState.WINDOW_BTNS_TOTAL;  // 40 for new tab button
    const tab_count: c_int = @intCast(app.tabline_state.tab_count);
    const ideal_width = @divTrunc(available_width, tab_count);
    const tab_width = @min(TablineState.TAB_MAX_WIDTH, @max(TablineState.TAB_MIN_WIDTH, ideal_width));

    // Brushes
    const selected_brush = c.CreateSolidBrush(c.RGB(255, 255, 255));
    const hover_brush = c.CreateSolidBrush(c.RGB(230, 230, 230));
    const normal_brush = c.CreateSolidBrush(c.RGB(220, 220, 220));
    defer {
        _ = c.DeleteObject(selected_brush);
        _ = c.DeleteObject(hover_brush);
        _ = c.DeleteObject(normal_brush);
    }

    // Font
    const font = c.CreateFontW(
        -12, 0, 0, 0, c.FW_NORMAL, 0, 0, 0,
        c.DEFAULT_CHARSET, c.OUT_DEFAULT_PRECIS, c.CLIP_DEFAULT_PRECIS,
        c.CLEARTYPE_QUALITY, c.DEFAULT_PITCH | c.FF_DONTCARE, null,
    );
    defer _ = c.DeleteObject(font);
    const old_font = c.SelectObject(hdc, font);
    defer _ = c.SelectObject(hdc, old_font);

    _ = c.SetBkMode(hdc, c.TRANSPARENT);

    var x: c_int = TablineState.WINDOW_CONTROLS_WIDTH;

    for (0..app.tabline_state.tab_count) |i| {
        const tab = &app.tabline_state.tabs[i];
        const is_selected = tab.handle == app.tabline_state.current_tab;
        const is_hovered = app.tabline_state.hovered_tab == i;

        var tab_rect = c.RECT{
            .left = x + 1,
            .top = 4,
            .right = x + tab_width - 1,
            .bottom = bar_height,
        };

        // Background
        const brush = if (is_selected) selected_brush else if (is_hovered) hover_brush else normal_brush;
        _ = c.FillRect(hdc, &tab_rect, brush);

        // Tab name
        _ = c.SetTextColor(hdc, if (is_selected) c.RGB(0, 0, 0) else c.RGB(80, 80, 80));

        var text_rect = c.RECT{
            .left = x + TablineState.TAB_PADDING,
            .top = 4,
            .right = x + tab_width - TablineState.TAB_PADDING - TablineState.TAB_CLOSE_SIZE - 4,
            .bottom = bar_height,
        };

        // Convert name to display
        var display_name: [256]u8 = undefined;
        var display_len: usize = 0;

        if (tab.name_len > 0) {
            // Find last path separator
            var last_sep: usize = 0;
            for (0..tab.name_len) |j| {
                if (tab.name[j] == '/' or tab.name[j] == '\\') {
                    last_sep = j + 1;
                }
            }
            display_len = tab.name_len - last_sep;
            @memcpy(display_name[0..display_len], tab.name[last_sep..tab.name_len]);
        } else {
            const no_name = "[No Name]";
            display_len = no_name.len;
            @memcpy(display_name[0..display_len], no_name);
        }

        // Convert to wide string
        var wide_buf: [256]u16 = undefined;
        const wide_len = std.unicode.utf8ToUtf16Le(&wide_buf, display_name[0..display_len]) catch 0;

        _ = c.DrawTextW(hdc, &wide_buf, @intCast(wide_len), &text_rect, c.DT_LEFT | c.DT_VCENTER | c.DT_SINGLELINE | c.DT_END_ELLIPSIS);

        // Close button (X) - show on selected or hovered tabs
        if (is_selected or is_hovered) {
            const close_x = x + tab_width - TablineState.TAB_CLOSE_SIZE - 6;
            const close_y = @divTrunc(bar_height - TablineState.TAB_CLOSE_SIZE, 2);
            const is_close_hovered = app.tabline_state.hovered_close == i;

            if (is_close_hovered) {
                const close_bg = c.CreateSolidBrush(c.RGB(200, 200, 200));
                var close_rect = c.RECT{
                    .left = close_x,
                    .top = close_y,
                    .right = close_x + TablineState.TAB_CLOSE_SIZE,
                    .bottom = close_y + TablineState.TAB_CLOSE_SIZE,
                };
                _ = c.FillRect(hdc, &close_rect, close_bg);
                _ = c.DeleteObject(close_bg);
            }

            // Draw X
            const pen = c.CreatePen(c.PS_SOLID, 1, if (is_close_hovered) c.RGB(0, 0, 0) else c.RGB(100, 100, 100));
            const old_pen = c.SelectObject(hdc, pen);
            const inset: c_int = 3;
            _ = c.MoveToEx(hdc, close_x + inset, close_y + inset, null);
            _ = c.LineTo(hdc, close_x + TablineState.TAB_CLOSE_SIZE - inset, close_y + TablineState.TAB_CLOSE_SIZE - inset);
            _ = c.MoveToEx(hdc, close_x + TablineState.TAB_CLOSE_SIZE - inset, close_y + inset, null);
            _ = c.LineTo(hdc, close_x + inset, close_y + TablineState.TAB_CLOSE_SIZE - inset);
            _ = c.SelectObject(hdc, old_pen);
            _ = c.DeleteObject(pen);
        }

        x += tab_width + 1;
    }

    // Draw + button
    const plus_x = x + 8;
    const plus_y = @divTrunc(bar_height - 16, 2);
    const plus_pen = c.CreatePen(c.PS_SOLID, 2, c.RGB(100, 100, 100));
    const old_pen = c.SelectObject(hdc, plus_pen);
    _ = c.MoveToEx(hdc, plus_x + 8, plus_y, null);
    _ = c.LineTo(hdc, plus_x + 8, plus_y + 16);
    _ = c.MoveToEx(hdc, plus_x, plus_y + 8, null);
    _ = c.LineTo(hdc, plus_x + 16, plus_y + 8);
    _ = c.SelectObject(hdc, old_pen);
    _ = c.DeleteObject(plus_pen);
}

/// Handle tabline mouse click
fn handleTablineClick(app: *App, x: c_int, y: c_int) bool {
    if (!app.ext_tabline_enabled or !app.tabline_state.visible) return false;
    if (y >= TablineState.TAB_BAR_HEIGHT) return false;  // Below tab bar

    // Get client width
    var rect: c.RECT = undefined;
    const main_hwnd = app.hwnd orelse return false;
    _ = c.GetClientRect(main_hwnd, &rect);
    const client_width = rect.right;

    // Check window control buttons first (right side)
    const btn_start_x = client_width - TablineState.WINDOW_BTNS_TOTAL;
    if (x >= btn_start_x) {
        const btn_idx = @divTrunc(x - btn_start_x, TablineState.WINDOW_BTN_WIDTH);
        if (btn_idx == 0) {
            // Minimize
            _ = c.ShowWindow(main_hwnd, c.SW_MINIMIZE);
            return true;
        } else if (btn_idx == 1) {
            // Maximize/Restore
            if (c.IsZoomed(main_hwnd) != 0) {
                _ = c.ShowWindow(main_hwnd, c.SW_RESTORE);
            } else {
                _ = c.ShowWindow(main_hwnd, c.SW_MAXIMIZE);
            }
            return true;
        } else if (btn_idx == 2) {
            // Close
            _ = c.PostMessageW(main_hwnd, c.WM_CLOSE, 0, 0);
            return true;
        }
    }

    // Calculate tab width
    const available_width = client_width - TablineState.WINDOW_CONTROLS_WIDTH - 40 - TablineState.WINDOW_BTNS_TOTAL;
    const tab_count: c_int = @intCast(app.tabline_state.tab_count);
    if (tab_count == 0) return false;
    const ideal_width = @divTrunc(available_width, tab_count);
    const tab_width = @min(TablineState.TAB_MAX_WIDTH, @max(TablineState.TAB_MIN_WIDTH, ideal_width));

    // Check + button
    const plus_x = TablineState.WINDOW_CONTROLS_WIDTH + tab_count * (tab_width + 1) + 8;
    if (x >= plus_x and x < plus_x + 20) {
        // New tab - use nvim_command API to avoid showing in cmdline
        if (app.corep) |corep| {
            const cmd = "tabnew";
            core.zonvie_core_send_command(corep, cmd.ptr, cmd.len);
        }
        // Force immediate repaint
        _ = c.InvalidateRect(main_hwnd, null, 0);
        _ = c.UpdateWindow(main_hwnd);
        return true;
    }

    // Check tabs
    var tab_x: c_int = TablineState.WINDOW_CONTROLS_WIDTH;
    for (0..app.tabline_state.tab_count) |i| {
        if (x >= tab_x and x < tab_x + tab_width) {
            // Check close button
            const close_x = tab_x + tab_width - TablineState.TAB_CLOSE_SIZE - 6;
            const close_y = @divTrunc(TablineState.TAB_BAR_HEIGHT - TablineState.TAB_CLOSE_SIZE, 2);

            if (x >= close_x and x < close_x + TablineState.TAB_CLOSE_SIZE and
                y >= close_y and y < close_y + TablineState.TAB_CLOSE_SIZE)
            {
                // Close this tab - use nvim_command API to avoid showing in cmdline
                if (app.corep) |corep| {
                    var cmd_buf: [48]u8 = undefined;
                    const cmd = std.fmt.bufPrint(&cmd_buf, "{d}tabclose", .{i + 1}) catch return true;
                    core.zonvie_core_send_command(corep, cmd.ptr, cmd.len);
                }
                // Force immediate repaint
                _ = c.InvalidateRect(main_hwnd, null, 0);
                _ = c.UpdateWindow(main_hwnd);
                return true;
            }

            // Select this tab - use Ngt (go to tab N) which doesn't show cmdline
            if (app.corep) |corep| {
                var cmd_buf: [16]u8 = undefined;
                const cmd = std.fmt.bufPrint(&cmd_buf, "\x1b{d}gt", .{i + 1}) catch return true;
                core.zonvie_core_send_input(corep, cmd.ptr, cmd.len);
            }
            // Force immediate repaint
            _ = c.InvalidateRect(main_hwnd, null, 0);
            _ = c.UpdateWindow(main_hwnd);
            return true;
        }
        tab_x += tab_width + 1;
    }

    return false;
}

/// Handle tabline mouse move (for hover)
fn handleTablineMouseMove(app: *App, x: c_int, y: c_int) void {
    if (!app.ext_tabline_enabled or !app.tabline_state.visible) return;

    var new_hovered_tab: ?usize = null;
    var new_hovered_close: ?usize = null;

    if (y < TablineState.TAB_BAR_HEIGHT) {
        var rect: c.RECT = undefined;
        if (app.hwnd) |hwnd| {
            _ = c.GetClientRect(hwnd, &rect);
        } else {
            return;
        }
        const client_width = rect.right;

        const available_width = client_width - TablineState.WINDOW_CONTROLS_WIDTH - 40 - TablineState.WINDOW_BTNS_TOTAL;
        const tab_count: c_int = @intCast(app.tabline_state.tab_count);
        if (tab_count > 0) {
            const ideal_width = @divTrunc(available_width, tab_count);
            const tab_width = @min(TablineState.TAB_MAX_WIDTH, @max(TablineState.TAB_MIN_WIDTH, ideal_width));

            var tab_x: c_int = TablineState.WINDOW_CONTROLS_WIDTH;
            for (0..app.tabline_state.tab_count) |i| {
                if (x >= tab_x and x < tab_x + tab_width) {
                    new_hovered_tab = i;

                    // Check close button
                    const close_x = tab_x + tab_width - TablineState.TAB_CLOSE_SIZE - 6;
                    const close_y = @divTrunc(TablineState.TAB_BAR_HEIGHT - TablineState.TAB_CLOSE_SIZE, 2);
                    if (x >= close_x and x < close_x + TablineState.TAB_CLOSE_SIZE and
                        y >= close_y and y < close_y + TablineState.TAB_CLOSE_SIZE)
                    {
                        new_hovered_close = i;
                    }
                    break;
                }
                tab_x += tab_width + 1;
            }
        }
    }

    if (new_hovered_tab != app.tabline_state.hovered_tab or
        new_hovered_close != app.tabline_state.hovered_close)
    {
        app.tabline_state.hovered_tab = new_hovered_tab;
        app.tabline_state.hovered_close = new_hovered_close;
        if (app.hwnd) |hwnd| {
            var tab_rect = c.RECT{
                .left = 0,
                .top = 0,
                .right = 0,
                .bottom = TablineState.TAB_BAR_HEIGHT,
            };
            _ = c.GetClientRect(hwnd, &tab_rect);
            tab_rect.bottom = TablineState.TAB_BAR_HEIGHT;
            _ = c.InvalidateRect(hwnd, &tab_rect, 0);
        }
    }
}

// ext_messages callbacks
fn onMsgShow(
    ctx: ?*anyopaque,
    view: core.zonvie_msg_view_type,
    kind: [*]const u8,
    kind_len: usize,
    chunks: [*]const core.MsgChunk,
    chunk_count: usize,
    replace_last: c_int,
    history: c_int,
    append: c_int,
    msg_id: i64,
    timeout_ms: u32,
) callconv(.c) void {
    const app: *App = @ptrCast(@alignCast(ctx.?));
    const kind_str = kind[0..kind_len];

    // Build message text and get primary hl_id from first chunk
    var msg_text: [2048]u8 = undefined;
    var msg_len: usize = 0;
    var primary_hl_id: u32 = 0;
    for (chunks[0..chunk_count]) |chunk| {
        if (primary_hl_id == 0) primary_hl_id = chunk.hl_id;
        const text = chunk.text[0..chunk.text_len];
        const copy_len = @min(text.len, msg_text.len - msg_len);
        @memcpy(msg_text[msg_len..][0..copy_len], text[0..copy_len]);
        msg_len += copy_len;
        if (msg_len >= msg_text.len) break;
    }

    // Convert timeout from milliseconds to seconds
    const timeout_sec: f32 = @as(f32, @floatFromInt(timeout_ms)) / 1000.0;

    if (applog.isEnabled()) applog.appLog("[win] on_msg_show: kind={s} chunks={d} replace_last={d} history={d} append={d} msg_id={d} text=\"{s}\" view={d} timeout_ms={d}\n", .{
        kind_str, chunk_count, replace_last, history, append, msg_id, msg_text[0..msg_len], @intFromEnum(view), timeout_ms,
    });

    // Skip if routed to 'none'
    if (view == .none) {
        return;
    }

    // Queue message for UI thread processing
    app.mu.lock();
    defer app.mu.unlock();

    var req = PendingMessageRequest{};
    @memcpy(req.text[0..msg_len], msg_text[0..msg_len]);
    req.text_len = msg_len;
    const kind_copy_len = @min(kind_len, req.kind.len);
    @memcpy(req.kind[0..kind_copy_len], kind[0..kind_copy_len]);
    req.kind_len = kind_copy_len;
    req.hl_id = primary_hl_id;
    req.replace_last = @intCast(@as(u32, if (replace_last != 0) 1 else 0));
    req.append = @intCast(@as(u32, if (append != 0) 1 else 0));
    req.view_type = view;
    req.timeout = timeout_sec;

    app.pending_messages.append(app.alloc, req) catch |e| {
        if (applog.isEnabled()) applog.appLog("[win] failed to queue message: {any}\n", .{e});
        return;
    };

    // Post message to UI thread
    if (app.hwnd) |main_hwnd| {
        _ = c.PostMessageW(main_hwnd, WM_APP_MSG_SHOW, 0, 0);
    }
}

fn onMsgClear(ctx: ?*anyopaque) callconv(.c) void {
    const app: *App = @ptrCast(@alignCast(ctx.?));
    if (applog.isEnabled()) applog.appLog("[win] on_msg_clear\n", .{});

    // Post message to UI thread to hide window
    if (app.hwnd) |main_hwnd| {
        _ = c.PostMessageW(main_hwnd, WM_APP_MSG_CLEAR, 0, 0);
    }
}

fn onMsgShowmode(ctx: ?*anyopaque, view: core.zonvie_msg_view_type, chunks: [*]const core.MsgChunk, chunk_count: usize) callconv(.c) void {
    const app: *App = @ptrCast(@alignCast(ctx.?));
    handleMsgMiniOrExtFloat(app, view, .msg_showmode, .showmode, "showmode", chunks, chunk_count);
}

fn onMsgShowcmd(ctx: ?*anyopaque, view: core.zonvie_msg_view_type, chunks: [*]const core.MsgChunk, chunk_count: usize) callconv(.c) void {
    const app: *App = @ptrCast(@alignCast(ctx.?));
    handleMsgMiniOrExtFloat(app, view, .msg_showcmd, .showcmd, "showcmd", chunks, chunk_count);
}

fn onMsgRuler(ctx: ?*anyopaque, view: core.zonvie_msg_view_type, chunks: [*]const core.MsgChunk, chunk_count: usize) callconv(.c) void {
    const app: *App = @ptrCast(@alignCast(ctx.?));
    handleMsgMiniOrExtFloat(app, view, .msg_ruler, .ruler, "ruler", chunks, chunk_count);
}

/// Common handler for showmode/showcmd/ruler that can route to mini or ext_float
fn handleMsgMiniOrExtFloat(
    app: *App,
    view: core.zonvie_msg_view_type,
    event: core.zonvie_msg_event,
    mini_id: MiniWindowId,
    kind_str: []const u8,
    chunks: [*]const core.MsgChunk,
    chunk_count: usize,
) void {
    // Build text from chunks
    var text_buf: [256]u8 = undefined;
    var text_len: usize = 0;
    for (chunks[0..chunk_count]) |chunk| {
        const text = chunk.text[0..chunk.text_len];
        const copy_len = @min(text.len, text_buf.len - text_len);
        @memcpy(text_buf[text_len..][0..copy_len], text[0..copy_len]);
        text_len += copy_len;
        if (text_len >= text_buf.len) break;
    }

    // Get timeout from config
    const route_result = core.zonvie_core_route_message(app.corep, event, null, 1);

    if (applog.isEnabled()) applog.appLog("[win] on_msg_{s}: chunks={d} text=\"{s}\" view={d} timeout={d:.1}\n", .{ kind_str, chunk_count, text_buf[0..text_len], @intFromEnum(view), route_result.timeout });

    // Route based on view type
    switch (view) {
        .none => {
            // Don't show anything
            return;
        },
        .mini => {
            // Update mini window
            const idx = @intFromEnum(mini_id);
            app.mu.lock();
            @memcpy(app.mini_windows[idx].text[0..text_len], text_buf[0..text_len]);
            app.mini_windows[idx].text_len = text_len;
            app.mu.unlock();

            if (app.hwnd) |main_hwnd| {
                _ = c.PostMessageW(main_hwnd, WM_APP_MINI_UPDATE, @as(c.WPARAM, idx), 0);
            }
        },
        .ext_float => {
            // Queue message for ext_float display
            app.mu.lock();
            defer app.mu.unlock();

            var req = PendingMessageRequest{};
            @memcpy(req.text[0..text_len], text_buf[0..text_len]);
            req.text_len = text_len;
            const kind_copy_len = @min(kind_str.len, req.kind.len);
            @memcpy(req.kind[0..kind_copy_len], kind_str[0..kind_copy_len]);
            req.kind_len = kind_copy_len;
            req.hl_id = 0;
            req.replace_last = 0;
            req.append = 0;
            req.view_type = .ext_float;
            req.timeout = route_result.timeout;

            app.pending_messages.append(app.alloc, req) catch |e| {
                if (applog.isEnabled()) applog.appLog("[win] failed to queue message: {any}\n", .{e});
                return;
            };

            if (app.hwnd) |main_hwnd| {
                _ = c.PostMessageW(main_hwnd, WM_APP_MSG_SHOW, 0, 0);
            }
        },
        .notification => {
            // Show OS notification via balloon
            const text = text_buf[0..text_len];
            if (app.tray_icon) |*tray| {
                tray.showBalloon("Neovim", text);
            }
        },
        else => {
            // Fallback to mini for other views (confirm, split)
            const idx = @intFromEnum(mini_id);
            app.mu.lock();
            @memcpy(app.mini_windows[idx].text[0..text_len], text_buf[0..text_len]);
            app.mini_windows[idx].text_len = text_len;
            app.mu.unlock();

            if (app.hwnd) |main_hwnd| {
                _ = c.PostMessageW(main_hwnd, WM_APP_MINI_UPDATE, @as(c.WPARAM, idx), 0);
            }
        },
    }
}

/// Update mini window text directly (for UI thread usage)
fn updateMiniText(app: *App, id: MiniWindowId, text: []const u8) void {
    const idx = @intFromEnum(id);
    const copy_len = @min(text.len, app.mini_windows[idx].text.len);
    @memcpy(app.mini_windows[idx].text[0..copy_len], text[0..copy_len]);
    app.mini_windows[idx].text_len = copy_len;
}

/// Common handler for mini window updates from callbacks
fn updateMiniFromCallback(app: *App, id: MiniWindowId, chunks: [*]const core.MsgChunk, chunk_count: usize) void {
    const idx = @intFromEnum(id);

    // Build text from chunks
    var text_buf: [256]u8 = undefined;
    var text_len: usize = 0;
    for (chunks[0..chunk_count]) |chunk| {
        const text = chunk.text[0..chunk.text_len];
        const copy_len = @min(text.len, text_buf.len - text_len);
        @memcpy(text_buf[text_len..][0..copy_len], text[0..copy_len]);
        text_len += copy_len;
        if (text_len >= text_buf.len) break;
    }
    if (applog.isEnabled()) applog.appLog("[win] on_msg_{s}: chunks={d} text=\"{s}\"\n", .{ @tagName(id), chunk_count, text_buf[0..text_len] });

    // Update state and post to UI thread
    app.mu.lock();
    @memcpy(app.mini_windows[idx].text[0..text_len], text_buf[0..text_len]);
    app.mini_windows[idx].text_len = text_len;
    app.mu.unlock();

    if (app.hwnd) |main_hwnd| {
        _ = c.PostMessageW(main_hwnd, WM_APP_MINI_UPDATE, @as(c.WPARAM, idx), 0);
    }
}

fn onMsgHistoryShow(
    ctx: ?*anyopaque,
    entries: ?[*]const core.MsgHistoryEntry,
    entry_count: usize,
    prev_cmd: c_int,
) callconv(.c) void {
    const app: *App = @ptrCast(@alignCast(ctx orelse return));

    if (entries == null or entry_count == 0) {
        if (applog.isEnabled()) applog.appLog("[win] on_msg_history_show: empty entries\n", .{});
        return;
    }

    // Build combined content from all entries
    var content_buf: [16384]u8 = undefined;
    var content_len: usize = 0;

    for (0..entry_count) |i| {
        const entry = entries.?[i];
        if (entry.chunk_count > 0) {
            for (0..entry.chunk_count) |j| {
                const chunk = entry.chunks[j];
                if (chunk.text_len > 0) {
                    const text = chunk.text[0..chunk.text_len];
                    const copy_len = @min(text.len, content_buf.len - content_len);
                    @memcpy(content_buf[content_len..][0..copy_len], text[0..copy_len]);
                    content_len += copy_len;
                }
            }
            // Add newline between entries
            if (content_len < content_buf.len - 1) {
                content_buf[content_len] = '\n';
                content_len += 1;
            }
        }
    }

    if (applog.isEnabled()) applog.appLog("[win] on_msg_history_show: entries={d} prev_cmd={d} content_len={d}\n", .{ entry_count, prev_cmd, content_len });

    // Queue for UI thread display - reuse message system for split view
    app.mu.lock();
    defer app.mu.unlock();

    var req = PendingMessageRequest{};
    const copy_len = @min(content_len, req.text.len);
    @memcpy(req.text[0..copy_len], content_buf[0..copy_len]);
    req.text_len = copy_len;
    req.kind_len = 0; // No specific kind for history
    req.hl_id = 0;
    req.replace_last = 0;
    req.append = 0;

    app.pending_messages.append(app.alloc, req) catch |e| {
        if (applog.isEnabled()) applog.appLog("[win] failed to queue history message: {any}\n", .{e});
        return;
    };

    // Post message to UI thread
    if (app.hwnd) |main_hwnd| {
        _ = c.PostMessageW(main_hwnd, WM_APP_MSG_SHOW, 0, 0);
    }
}

// --- Clipboard callbacks ---

fn onClipboardGet(
    ctx: ?*anyopaque,
    register: [*]const u8,
    out_buf: [*]u8,
    out_len: *usize,
    max_len: usize,
) callconv(.c) c_int {
    _ = register;

    if (applog.isEnabled()) applog.appLog("[win] clipboard_get: called\n", .{});

    const app: *App = if (ctx) |ctxp| @ptrCast(@alignCast(ctxp)) else {
        out_len.* = 0;
        return 1;
    };

    const hwnd = app.hwnd orelse {
        out_len.* = 0;
        return 1;
    };

    // Create event if not exists (manual-reset, initially non-signaled)
    if (app.clipboard_event == null) {
        app.clipboard_event = c.CreateEventW(null, c.TRUE, c.FALSE, null);
        if (app.clipboard_event == null) {
            if (applog.isEnabled()) applog.appLog("[win] clipboard_get: CreateEventW failed\n", .{});
            out_len.* = 0;
            return 1;
        }
    }

    // Reset event
    _ = c.ResetEvent(app.clipboard_event);

    // Post message to UI thread
    if (c.PostMessageW(hwnd, WM_APP_CLIPBOARD_GET, 0, 0) == 0) {
        if (applog.isEnabled()) applog.appLog("[win] clipboard_get: PostMessageW failed\n", .{});
        out_len.* = 0;
        return 1;
    }

    // Wait for UI thread to complete (timeout: 5 seconds)
    const wait_result = c.WaitForSingleObject(app.clipboard_event, 5000);
    if (wait_result != c.WAIT_OBJECT_0) {
        if (applog.isEnabled()) applog.appLog("[win] clipboard_get: WaitForSingleObject failed or timeout\n", .{});
        out_len.* = 0;
        return 1;
    }

    // Copy result
    const copy_len = @min(app.clipboard_len, max_len);
    if (copy_len > 0) {
        @memcpy(out_buf[0..copy_len], app.clipboard_buf[0..copy_len]);
    }
    out_len.* = copy_len;

    if (applog.isEnabled()) applog.appLog("[win] clipboard_get: len={d}\n", .{copy_len});
    return app.clipboard_result;
}

fn onClipboardSet(
    ctx: ?*anyopaque,
    register: [*]const u8,
    data: [*]const u8,
    len: usize,
) callconv(.c) c_int {
    _ = register;

    if (applog.isEnabled()) applog.appLog("[win] clipboard_set: called len={d}\n", .{len});

    if (len == 0) return 1;

    const app: *App = if (ctx) |ctxp| @ptrCast(@alignCast(ctxp)) else return 0;

    const hwnd = app.hwnd orelse return 0;

    // Create event if not exists
    if (app.clipboard_event == null) {
        app.clipboard_event = c.CreateEventW(null, c.TRUE, c.FALSE, null);
        if (app.clipboard_event == null) {
            if (applog.isEnabled()) applog.appLog("[win] clipboard_set: CreateEventW failed\n", .{});
            return 0;
        }
    }

    // Reset event
    _ = c.ResetEvent(app.clipboard_event);

    // Store data pointer and length for UI thread
    app.clipboard_set_data = data;
    app.clipboard_set_len = len;

    // Post message to UI thread
    if (c.PostMessageW(hwnd, WM_APP_CLIPBOARD_SET, 0, 0) == 0) {
        if (applog.isEnabled()) applog.appLog("[win] clipboard_set: PostMessageW failed\n", .{});
        return 0;
    }

    // Wait for UI thread to complete (timeout: 5 seconds)
    const wait_result = c.WaitForSingleObject(app.clipboard_event, 5000);
    if (wait_result != c.WAIT_OBJECT_0) {
        if (applog.isEnabled()) applog.appLog("[win] clipboard_set: WaitForSingleObject failed or timeout\n", .{});
        return 0;
    }

    if (applog.isEnabled()) applog.appLog("[win] clipboard_set: result={d}\n", .{app.clipboard_result});
    return app.clipboard_result;
}

/// SSH authentication prompt callback
/// Called when SSH mode detects a password prompt
fn onSSHAuthPrompt(
    ctx: ?*anyopaque,
    prompt: [*]const u8,
    prompt_len: usize,
) callconv(.c) void {
    if (applog.isEnabled()) applog.appLog("[win] ssh_auth_prompt: called len={d}\n", .{prompt_len});

    const app: *App = if (ctx) |ctxp| @ptrCast(@alignCast(ctxp)) else return;

    // Post message to UI thread to show password dialog
    const hwnd = app.hwnd orelse return;
    // Store prompt temporarily (prompt_len bytes)
    app.ssh_prompt_ptr = prompt;
    app.ssh_prompt_len = prompt_len;

    if (c.PostMessageW(hwnd, WM_APP_SSH_AUTH_PROMPT, 0, 0) == 0) {
        if (applog.isEnabled()) applog.appLog("[win] ssh_auth_prompt: PostMessageW failed\n", .{});
    }
}

/// Handle SSH auth prompt on UI thread
fn handleSSHAuthPromptOnUIThread(app: *App) void {
    // Check if we have pre-entered password from initial dialog
    if (app.ssh_password) |password| {
        if (applog.isEnabled()) applog.appLog("[win] ssh_auth_prompt_ui: using pre-entered password ({d} chars)\n", .{password.len});

        // Send pre-entered password + newline to stdin
        if (app.corep != null) {
            core.zonvie_core_send_stdin_data(app.corep, password.ptr, @intCast(password.len));
            // Send newline to confirm password
            core.zonvie_core_send_stdin_data(app.corep, "\n", 1);
        }

        // Clear password after use (security)
        @memset(@constCast(password), 0);
        app.alloc.free(password);
        app.ssh_password = null;
        return;
    }

    // No pre-entered password, show dialog
    if (applog.isEnabled()) applog.appLog("[win] ssh_auth_prompt_ui: showing dialog\n", .{});

    // Allocate console for password input (if not already allocated)
    _ = c.AllocConsole();

    // Get console handles
    const hConsoleOut = c.GetStdHandle(c.STD_OUTPUT_HANDLE);
    const hConsoleIn = c.GetStdHandle(c.STD_INPUT_HANDLE);

    if (hConsoleOut == c.INVALID_HANDLE_VALUE or hConsoleIn == c.INVALID_HANDLE_VALUE) {
        if (applog.isEnabled()) applog.appLog("[win] ssh_auth_prompt_ui: failed to get console handles\n", .{});
        return;
    }

    // Write prompt to console
    var written: c.DWORD = 0;
    if (app.ssh_prompt_ptr != null and app.ssh_prompt_len > 0) {
        _ = c.WriteConsoleA(hConsoleOut, app.ssh_prompt_ptr, @intCast(app.ssh_prompt_len), &written, null);
        _ = c.WriteConsoleA(hConsoleOut, " ", 1, &written, null);
    }

    // Disable echo for password input
    var console_mode: c.DWORD = 0;
    _ = c.GetConsoleMode(hConsoleIn, &console_mode);
    _ = c.SetConsoleMode(hConsoleIn, console_mode & ~@as(c.DWORD, c.ENABLE_ECHO_INPUT));

    // Read password
    var password_buf: [256]u8 = undefined;
    var read: c.DWORD = 0;
    _ = c.ReadConsoleA(hConsoleIn, &password_buf, 255, &read, null);

    // Restore console mode
    _ = c.SetConsoleMode(hConsoleIn, console_mode);

    // Write newline after password entry
    _ = c.WriteConsoleA(hConsoleOut, "\r\n", 2, &written, null);

    if (applog.isEnabled()) applog.appLog("[win] ssh_auth_prompt_ui: password entered, read={d} bytes\n", .{read});

    // Send password to stdin via core
    if (read > 0 and app.corep != null) {
        core.zonvie_core_send_stdin_data(app.corep, &password_buf, @intCast(read));
    }

    // Hide console after password entry
    _ = c.FreeConsole();
}

/// Window procedure for SSH password dialog
fn sshPasswordDlgProc(hwnd: c.HWND, msg: c.UINT, wParam: c.WPARAM, lParam: c.LPARAM) callconv(.winapi) c.LRESULT {
    switch (msg) {
        c.WM_COMMAND => {
            // Check which button was clicked
            // For button clicks, lParam contains the button HWND
            const lp_value: usize = @bitCast(lParam);
            const notification = (wParam >> 16) & 0xFFFF;

            // BN_CLICKED = 0
            if (notification == 0 and lp_value != 0) {
                // Compare as usize values to avoid alignment issues
                const ok_value: usize = if (ssh_dlg_ok_hwnd) |h| @intFromPtr(h) else 0;
                const cancel_value: usize = if (ssh_dlg_cancel_hwnd) |h| @intFromPtr(h) else 0;

                if (lp_value == ok_value and ok_value != 0) {
                    // OK button clicked - get password
                    if (ssh_dlg_edit_hwnd != null) {
                        const len = c.GetWindowTextA(ssh_dlg_edit_hwnd, &ssh_dlg_password, ssh_dlg_password.len);
                        ssh_dlg_password_len = if (len > 0) @intCast(len) else 0;
                    }
                    ssh_dlg_result = true;
                    _ = c.DestroyWindow(hwnd);
                    return 0;
                } else if (lp_value == cancel_value and cancel_value != 0) {
                    // Cancel button clicked
                    ssh_dlg_result = false;
                    _ = c.DestroyWindow(hwnd);
                    return 0;
                }
            }
        },
        c.WM_CLOSE => {
            ssh_dlg_result = false;
            _ = c.DestroyWindow(hwnd);
            return 0;
        },
        c.WM_DESTROY => {
            c.PostQuitMessage(0);
            return 0;
        },
        else => {},
    }
    return c.DefWindowProcW(hwnd, msg, wParam, lParam);
}

/// Show SSH password dialog using Windows CredUI API
/// This uses the system-provided credential dialog which doesn't interfere with spawn()
/// Returns the password (caller must free) or null if cancelled
fn showSSHPasswordDialog(alloc: std.mem.Allocator, host: []const u8) ?[]const u8 {
    if (applog.isEnabled()) applog.appLog("[win] showSSHPasswordDialog (CredUI): host={s}\n", .{host});

    // CredUI flags
    const CREDUI_FLAGS_GENERIC_CREDENTIALS: c.DWORD = 0x00040000;
    const CREDUI_FLAGS_ALWAYS_SHOW_UI: c.DWORD = 0x00000080;
    const CREDUI_FLAGS_DO_NOT_PERSIST: c.DWORD = 0x00000002;

    // Convert host to UTF-16 for target name
    var target_name: [256]u16 = undefined;
    var target_len: usize = 0;
    for (host) |ch| {
        if (target_len < target_name.len - 1) {
            target_name[target_len] = ch;
            target_len += 1;
        }
    }
    target_name[target_len] = 0;

    // Message text
    const msg_text = std.unicode.utf8ToUtf16LeStringLiteral("Enter credentials for SSH connection");
    const caption = std.unicode.utf8ToUtf16LeStringLiteral("SSH Authentication - Zonvie");

    // Setup CREDUI_INFO structure
    var cred_info: c.CREDUI_INFOW = std.mem.zeroes(c.CREDUI_INFOW);
    cred_info.cbSize = @sizeOf(c.CREDUI_INFOW);
    cred_info.hwndParent = null;
    cred_info.pszMessageText = msg_text;
    cred_info.pszCaptionText = caption;
    cred_info.hbmBanner = null;

    // Buffers for username and password
    var username: [256]u16 = undefined;
    var password: [256]u16 = undefined;
    @memset(&username, 0);
    @memset(&password, 0);

    // Pre-fill username from host if it contains user@host format
    var username_len: usize = 0;
    var found_at = false;
    for (host) |ch| {
        if (ch == '@') {
            found_at = true;
            break;
        }
        if (username_len < username.len - 1) {
            username[username_len] = ch;
            username_len += 1;
        }
    }
    if (!found_at) {
        // No user@ prefix, clear username
        @memset(&username, 0);
    }

    var save: c.BOOL = 0; // Don't save credentials

    // Call CredUIPromptForCredentialsW
    const result = c.CredUIPromptForCredentialsW(
        &cred_info,
        &target_name,
        null, // pContext
        0, // dwAuthError
        &username,
        username.len,
        &password,
        password.len,
        &save,
        CREDUI_FLAGS_GENERIC_CREDENTIALS | CREDUI_FLAGS_ALWAYS_SHOW_UI | CREDUI_FLAGS_DO_NOT_PERSIST,
    );

    if (result != 0) {
        // Cancelled or error
        if (applog.isEnabled()) applog.appLog("[win] showSSHPasswordDialog (CredUI): cancelled or error, result={d}\n", .{result});
        @memset(&password, 0);
        return null;
    }

    // Convert password from UTF-16 to UTF-8
    var password_len: usize = 0;
    while (password_len < password.len and password[password_len] != 0) {
        password_len += 1;
    }

    if (password_len == 0) {
        if (applog.isEnabled()) applog.appLog("[win] showSSHPasswordDialog (CredUI): empty password\n", .{});
        return null;
    }

    // Convert UTF-16 to UTF-8
    var utf8_buf: [512]u8 = undefined;
    var utf8_len: usize = 0;
    for (password[0..password_len]) |wch| {
        if (wch < 128) {
            if (utf8_len < utf8_buf.len) {
                utf8_buf[utf8_len] = @intCast(wch);
                utf8_len += 1;
            }
        } else if (wch < 0x800) {
            if (utf8_len + 1 < utf8_buf.len) {
                utf8_buf[utf8_len] = @intCast(0xC0 | (wch >> 6));
                utf8_buf[utf8_len + 1] = @intCast(0x80 | (wch & 0x3F));
                utf8_len += 2;
            }
        } else {
            if (utf8_len + 2 < utf8_buf.len) {
                utf8_buf[utf8_len] = @intCast(0xE0 | (wch >> 12));
                utf8_buf[utf8_len + 1] = @intCast(0x80 | ((wch >> 6) & 0x3F));
                utf8_buf[utf8_len + 2] = @intCast(0x80 | (wch & 0x3F));
                utf8_len += 3;
            }
        }
    }

    // Clear password buffer for security
    @memset(&password, 0);

    // Allocate and return password
    const result_password = alloc.dupe(u8, utf8_buf[0..utf8_len]) catch {
        @memset(&utf8_buf, 0);
        return null;
    };
    @memset(&utf8_buf, 0);

    if (applog.isEnabled()) applog.appLog("[win] showSSHPasswordDialog (CredUI): password entered ({d} chars)\n", .{result_password.len});
    return result_password;
}

// Global state for password dialog
var g_password_dialog_result: bool = false;
var g_password_dialog_hwnd_edit: ?c.HWND = null;
var g_password_dialog_output: ?*[256]u16 = null;

/// Simple password input dialog without username field
fn showPasswordInputDialog(prompt: *const [256]u16, password_out: *[256]u16) bool {
    const class_name = std.unicode.utf8ToUtf16LeStringLiteral("ZonviePasswordDialog");

    // Register window class
    var wc: c.WNDCLASSEXW = std.mem.zeroes(c.WNDCLASSEXW);
    wc.cbSize = @sizeOf(c.WNDCLASSEXW);
    wc.lpfnWndProc = passwordDialogProc;
    wc.hInstance = c.GetModuleHandleW(null);
    wc.hCursor = c.LoadCursorW(null, @ptrFromInt(32512)); // IDC_ARROW
    wc.hbrBackground = @ptrFromInt(@as(usize, 16)); // COLOR_BTNFACE + 1
    wc.lpszClassName = class_name;
    _ = c.RegisterClassExW(&wc);

    // Store output pointer
    g_password_dialog_output = password_out;
    g_password_dialog_result = false;

    // Create dialog window (centered on screen)
    const screen_w = c.GetSystemMetrics(c.SM_CXSCREEN);
    const screen_h = c.GetSystemMetrics(c.SM_CYSCREEN);
    const dlg_w: i32 = 420;
    const dlg_h: i32 = 180;
    const dlg_x = @divTrunc(screen_w - dlg_w, 2);
    const dlg_y = @divTrunc(screen_h - dlg_h, 2);

    const hwnd = c.CreateWindowExW(
        c.WS_EX_DLGMODALFRAME | c.WS_EX_TOPMOST,
        class_name,
        std.unicode.utf8ToUtf16LeStringLiteral("SSH Authentication"),
        c.WS_POPUP | c.WS_CAPTION | c.WS_SYSMENU,
        dlg_x,
        dlg_y,
        dlg_w,
        dlg_h,
        null,
        null,
        c.GetModuleHandleW(null),
        null,
    );

    if (hwnd == null) return false;

    // Create prompt label
    _ = c.CreateWindowExW(
        0,
        std.unicode.utf8ToUtf16LeStringLiteral("STATIC"),
        prompt,
        c.WS_CHILD | c.WS_VISIBLE,
        20,
        15,
        360,
        40,
        hwnd,
        null,
        c.GetModuleHandleW(null),
        null,
    );

    // Create password edit field
    g_password_dialog_hwnd_edit = c.CreateWindowExW(
        c.WS_EX_CLIENTEDGE,
        std.unicode.utf8ToUtf16LeStringLiteral("EDIT"),
        std.unicode.utf8ToUtf16LeStringLiteral(""),
        c.WS_CHILD | c.WS_VISIBLE | c.WS_TABSTOP | c.ES_PASSWORD | c.ES_AUTOHSCROLL,
        20,
        55,
        360,
        25,
        hwnd,
        null,
        c.GetModuleHandleW(null),
        null,
    );

    // Create OK button
    const ok_btn = c.CreateWindowExW(
        0,
        std.unicode.utf8ToUtf16LeStringLiteral("BUTTON"),
        std.unicode.utf8ToUtf16LeStringLiteral("OK"),
        c.WS_CHILD | c.WS_VISIBLE | c.WS_TABSTOP | c.BS_DEFPUSHBUTTON,
        200,
        95,
        80,
        30,
        hwnd,
        null,
        c.GetModuleHandleW(null),
        null,
    );
    if (ok_btn) |btn| {
        _ = c.SetWindowLongPtrW(btn, c.GWLP_ID, 1); // ID = 1 for OK
    }

    // Create Cancel button
    const cancel_btn = c.CreateWindowExW(
        0,
        std.unicode.utf8ToUtf16LeStringLiteral("BUTTON"),
        std.unicode.utf8ToUtf16LeStringLiteral("Cancel"),
        c.WS_CHILD | c.WS_VISIBLE | c.WS_TABSTOP,
        300,
        95,
        80,
        30,
        hwnd,
        null,
        c.GetModuleHandleW(null),
        null,
    );
    if (cancel_btn) |btn| {
        _ = c.SetWindowLongPtrW(btn, c.GWLP_ID, 2); // ID = 2 for Cancel
    }

    // Set focus to password field
    if (g_password_dialog_hwnd_edit) |edit_hwnd| {
        _ = c.SetFocus(edit_hwnd);
    }

    // Show window
    _ = c.ShowWindow(hwnd, c.SW_SHOW);
    _ = c.UpdateWindow(hwnd);

    // Message loop
    var msg: c.MSG = undefined;
    while (c.GetMessageW(&msg, null, 0, 0) > 0) {
        if (c.IsDialogMessageW(hwnd, &msg) == 0) {
            _ = c.TranslateMessage(&msg);
            _ = c.DispatchMessageW(&msg);
        }
        // Check if dialog was closed
        if (c.IsWindow(hwnd) == 0) break;
    }

    // Cleanup
    _ = c.UnregisterClassW(class_name, c.GetModuleHandleW(null));
    g_password_dialog_hwnd_edit = null;
    g_password_dialog_output = null;

    return g_password_dialog_result;
}

fn passwordDialogProc(hwnd: c.HWND, msg: c.UINT, wParam: c.WPARAM, lParam: c.LPARAM) callconv(.winapi) c.LRESULT {
    switch (msg) {
        c.WM_COMMAND => {
            const id = wParam & 0xFFFF;
            if (id == 1) {
                // OK button clicked
                if (g_password_dialog_hwnd_edit) |edit_hwnd| {
                    if (g_password_dialog_output) |output| {
                        _ = c.GetWindowTextW(edit_hwnd, output, 256);
                        g_password_dialog_result = true;
                    }
                }
                _ = c.DestroyWindow(hwnd);
                return 0;
            } else if (id == 2) {
                // Cancel button clicked
                g_password_dialog_result = false;
                _ = c.DestroyWindow(hwnd);
                return 0;
            }
        },
        c.WM_CLOSE => {
            g_password_dialog_result = false;
            _ = c.DestroyWindow(hwnd);
            return 0;
        },
        c.WM_DESTROY => {
            c.PostQuitMessage(0);
            return 0;
        },
        else => {},
    }
    return c.DefWindowProcW(hwnd, msg, wParam, lParam);
}

// ============================================================
// Devcontainer Progress Dialog
// ============================================================

var g_devcontainer_dialog_hwnd: ?c.HWND = null;
var g_devcontainer_label_hwnd: ?c.HWND = null;
var g_devcontainer_up_done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);
var g_devcontainer_up_success: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

fn showDevcontainerProgressDialog(label_text: [*:0]const u16) void {
    const class_name = std.unicode.utf8ToUtf16LeStringLiteral("ZonvieDevcontainerProgress");

    // Register window class
    var wc: c.WNDCLASSEXW = std.mem.zeroes(c.WNDCLASSEXW);
    wc.cbSize = @sizeOf(c.WNDCLASSEXW);
    wc.lpfnWndProc = devcontainerDialogProc;
    wc.hInstance = c.GetModuleHandleW(null);
    wc.hCursor = c.LoadCursorW(null, @ptrFromInt(32512)); // IDC_ARROW
    wc.hbrBackground = @ptrFromInt(@as(usize, 16)); // COLOR_BTNFACE + 1
    wc.lpszClassName = class_name;
    _ = c.RegisterClassExW(&wc);

    // Create dialog window (centered on screen)
    const screen_w = c.GetSystemMetrics(c.SM_CXSCREEN);
    const screen_h = c.GetSystemMetrics(c.SM_CYSCREEN);
    const dlg_w: i32 = 300;
    const dlg_h: i32 = 80;
    const dlg_x = @divTrunc(screen_w - dlg_w, 2);
    const dlg_y = @divTrunc(screen_h - dlg_h, 2);

    const hwnd = c.CreateWindowExW(
        c.WS_EX_DLGMODALFRAME | c.WS_EX_TOPMOST,
        class_name,
        std.unicode.utf8ToUtf16LeStringLiteral("Devcontainer"),
        c.WS_POPUP | c.WS_CAPTION,
        dlg_x,
        dlg_y,
        dlg_w,
        dlg_h,
        null,
        null,
        c.GetModuleHandleW(null),
        null,
    );

    if (hwnd == null) return;
    g_devcontainer_dialog_hwnd = hwnd;

    // Create label
    g_devcontainer_label_hwnd = c.CreateWindowExW(
        0,
        std.unicode.utf8ToUtf16LeStringLiteral("STATIC"),
        label_text,
        c.WS_CHILD | c.WS_VISIBLE | c.SS_CENTER,
        20,
        20,
        260,
        25,
        hwnd,
        null,
        c.GetModuleHandleW(null),
        null,
    );

    // Show window
    _ = c.ShowWindow(hwnd, c.SW_SHOW);
    _ = c.UpdateWindow(hwnd);

    if (applog.isEnabled()) applog.appLog("[win] devcontainer progress dialog shown\n", .{});
}

fn updateDevcontainerProgressLabel(label_text: [*:0]const u16) void {
    if (g_devcontainer_label_hwnd) |label_hwnd| {
        _ = c.SetWindowTextW(label_hwnd, label_text);
    }
}

fn hideDevcontainerProgressDialog() void {
    if (g_devcontainer_dialog_hwnd) |hwnd| {
        _ = c.DestroyWindow(hwnd);
        g_devcontainer_dialog_hwnd = null;
        g_devcontainer_label_hwnd = null;
        if (applog.isEnabled()) applog.appLog("[win] devcontainer progress dialog hidden\n", .{});
    }
}

fn devcontainerDialogProc(hwnd: c.HWND, msg: c.UINT, wParam: c.WPARAM, lParam: c.LPARAM) callconv(.winapi) c.LRESULT {
    switch (msg) {
        c.WM_DESTROY => {
            g_devcontainer_dialog_hwnd = null;
            g_devcontainer_label_hwnd = null;
            return 0;
        },
        else => {},
    }
    return c.DefWindowProcW(hwnd, msg, wParam, lParam);
}

/// Check if Docker is running by executing `docker info`
fn isDockerRunning() bool {
    var si: c.STARTUPINFOA = std.mem.zeroes(c.STARTUPINFOA);
    si.cb = @sizeOf(c.STARTUPINFOA);
    si.dwFlags = c.STARTF_USESHOWWINDOW;
    si.wShowWindow = c.SW_HIDE;

    var pi: c.PROCESS_INFORMATION = std.mem.zeroes(c.PROCESS_INFORMATION);

    var cmd_buf: [256]u8 = undefined;
    @memcpy(cmd_buf[0..21], "cmd /c docker info >nul 2>&1"[0..21]);
    cmd_buf[21] = 0;

    const create_result = c.CreateProcessA(
        null,
        &cmd_buf,
        null,
        null,
        0,
        c.CREATE_NO_WINDOW,
        null,
        null,
        &si,
        &pi,
    );

    if (create_result == 0) {
        return false;
    }

    _ = c.WaitForSingleObject(pi.hProcess, 10000); // 10 second timeout

    var exit_code: c.DWORD = 1;
    _ = c.GetExitCodeProcess(pi.hProcess, &exit_code);

    _ = c.CloseHandle(pi.hProcess);
    _ = c.CloseHandle(pi.hThread);

    return exit_code == 0;
}

/// Start Docker Desktop
fn startDockerDesktop() bool {
    if (applog.isEnabled()) applog.appLog("[win] Starting Docker Desktop...\n", .{});

    var si: c.STARTUPINFOA = std.mem.zeroes(c.STARTUPINFOA);
    si.cb = @sizeOf(c.STARTUPINFOA);

    var pi: c.PROCESS_INFORMATION = std.mem.zeroes(c.PROCESS_INFORMATION);

    // Try common Docker Desktop paths
    const docker_paths = [_][]const u8{
        "C:\\Program Files\\Docker\\Docker\\Docker Desktop.exe",
        "C:\\Program Files (x86)\\Docker\\Docker\\Docker Desktop.exe",
    };

    for (docker_paths) |path| {
        var path_buf: [512]u8 = undefined;
        @memcpy(path_buf[0..path.len], path);
        path_buf[path.len] = 0;

        const create_result = c.CreateProcessA(
            &path_buf,
            null,
            null,
            null,
            0,
            0,
            null,
            null,
            &si,
            &pi,
        );

        if (create_result != 0) {
            _ = c.CloseHandle(pi.hProcess);
            _ = c.CloseHandle(pi.hThread);
            if (applog.isEnabled()) applog.appLog("[win] Docker Desktop started from: {s}\n", .{path});
            return true;
        }
    }

    if (applog.isEnabled()) applog.appLog("[win] Failed to start Docker Desktop\n", .{});
    return false;
}

/// Ensure Docker is running, start if needed
fn ensureDockerRunning() bool {
    if (isDockerRunning()) {
        if (applog.isEnabled()) applog.appLog("[win] Docker is already running\n", .{});
        return true;
    }

    // Update progress label
    updateDevcontainerProgressLabel(std.unicode.utf8ToUtf16LeStringLiteral("Starting Docker..."));

    if (!startDockerDesktop()) {
        return false;
    }

    // Wait for Docker to be ready (up to 60 seconds)
    const max_wait_seconds: u32 = 60;
    var i: u32 = 0;
    while (i < max_wait_seconds) : (i += 1) {
        c.Sleep(1000); // Sleep 1 second
        if (isDockerRunning()) {
            if (applog.isEnabled()) applog.appLog("[win] Docker started successfully after {d} seconds\n", .{i + 1});
            return true;
        }
    }

    if (applog.isEnabled()) applog.appLog("[win] Docker failed to start within {d} seconds\n", .{max_wait_seconds});
    return false;
}

/// Run devcontainer up in background thread
fn runDevcontainerUpThread(workspace: []const u8, config_path: ?[]const u8, alloc: std.mem.Allocator) void {
    if (applog.isEnabled()) applog.appLog("[win] devcontainer up thread started\n", .{});

    // Ensure Docker is running first
    if (!ensureDockerRunning()) {
        if (applog.isEnabled()) applog.appLog("[win] Docker is not running and failed to start\n", .{});
        g_devcontainer_up_success.store(false, .seq_cst);
        g_devcontainer_up_done.store(true, .seq_cst);
        return;
    }

    // Update progress label to "Building..."
    updateDevcontainerProgressLabel(std.unicode.utf8ToUtf16LeStringLiteral("Building devcontainer..."));

    // Get user profile directory for nvim config path
    var local_app_data: [512]u8 = undefined;
    const local_app_data_len = c.GetEnvironmentVariableA("LOCALAPPDATA", &local_app_data, 512);
    const nvim_config_path = if (local_app_data_len > 0)
        local_app_data[0..local_app_data_len]
    else
        "C:\\Users\\Default\\AppData\\Local";

    // Build command: devcontainer up with features and mount
    var cmd_buf: [4096]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&cmd_buf);
    const writer = fbs.writer();

    writer.writeAll("cmd /c \"devcontainer up --workspace-folder \"\"") catch {};
    writer.writeAll(workspace) catch {};
    writer.writeAll("\"\"") catch {};
    if (config_path) |cfg| {
        writer.writeAll(" --config \"\"") catch {};
        writer.writeAll(cfg) catch {};
        writer.writeAll("\"\"") catch {};
    }
    writer.writeAll(" --additional-features \"{\"\"ghcr.io/duduribeiro/devcontainer-features/neovim:1\"\":{}}\"") catch {};
    writer.writeAll(" --mount type=bind,source=") catch {};
    writer.writeAll(nvim_config_path) catch {};
    writer.writeAll("\\nvim,target=/nvim-config/nvim") catch {};
    writer.writeAll(" --remove-existing-container\"") catch {};

    const cmd_slice = cmd_buf[0..fbs.pos];
    if (applog.isEnabled()) applog.appLog("[win] devcontainer up command: {s}\n", .{cmd_slice});

    // Convert to null-terminated for CreateProcess
    const cmd_z = alloc.dupeZ(u8, cmd_slice) catch {
        g_devcontainer_up_success.store(false, .seq_cst);
        g_devcontainer_up_done.store(true, .seq_cst);
        return;
    };
    defer alloc.free(cmd_z);

    // Run command via CreateProcess
    var si: c.STARTUPINFOA = std.mem.zeroes(c.STARTUPINFOA);
    si.cb = @sizeOf(c.STARTUPINFOA);
    si.dwFlags = c.STARTF_USESHOWWINDOW;
    si.wShowWindow = c.SW_HIDE;

    var pi: c.PROCESS_INFORMATION = std.mem.zeroes(c.PROCESS_INFORMATION);

    const create_result = c.CreateProcessA(
        null,
        cmd_z.ptr,
        null,
        null,
        0,
        c.CREATE_NO_WINDOW,
        null,
        null,
        &si,
        &pi,
    );

    if (create_result == 0) {
        if (applog.isEnabled()) applog.appLog("[win] devcontainer up CreateProcess failed\n", .{});
        g_devcontainer_up_success.store(false, .seq_cst);
        g_devcontainer_up_done.store(true, .seq_cst);
        return;
    }

    // Wait for process to complete
    _ = c.WaitForSingleObject(pi.hProcess, c.INFINITE);

    var exit_code: c.DWORD = 0;
    _ = c.GetExitCodeProcess(pi.hProcess, &exit_code);

    _ = c.CloseHandle(pi.hProcess);
    _ = c.CloseHandle(pi.hThread);

    if (applog.isEnabled()) applog.appLog("[win] devcontainer up completed with exit code: {d}\n", .{exit_code});

    g_devcontainer_up_success.store(exit_code == 0, .seq_cst);
    g_devcontainer_up_done.store(true, .seq_cst);
}

/// Handle clipboard get on UI thread (called via WM_APP_CLIPBOARD_GET)
fn handleClipboardGetOnUIThread(app: *App) void {
    app.clipboard_len = 0;
    app.clipboard_result = 1; // Success (empty)

    const hwnd = app.hwnd orelse null;

    // Open clipboard
    if (c.OpenClipboard(hwnd) == 0) {
        if (applog.isEnabled()) applog.appLog("[win] clipboard_get_ui: OpenClipboard failed\n", .{});
        _ = c.SetEvent(app.clipboard_event);
        return;
    }
    defer _ = c.CloseClipboard();

    // Get CF_UNICODETEXT data
    const hdata = c.GetClipboardData(c.CF_UNICODETEXT);
    if (hdata == null) {
        // Empty clipboard
        _ = c.SetEvent(app.clipboard_event);
        return;
    }

    const ptr = c.GlobalLock(hdata);
    if (ptr == null) {
        _ = c.SetEvent(app.clipboard_event);
        return;
    }
    defer _ = c.GlobalUnlock(hdata);

    // Convert UTF-16 to UTF-8
    const wide_ptr: [*:0]const u16 = @ptrCast(@alignCast(ptr));
    const utf8_len = c.WideCharToMultiByte(
        c.CP_UTF8,
        0,
        wide_ptr,
        -1,
        null,
        0,
        null,
        null,
    );

    if (utf8_len <= 0) {
        _ = c.SetEvent(app.clipboard_event);
        return;
    }

    const copy_len: usize = @min(@as(usize, @intCast(utf8_len - 1)), app.clipboard_buf.len);
    if (copy_len > 0) {
        _ = c.WideCharToMultiByte(
            c.CP_UTF8,
            0,
            wide_ptr,
            -1,
            @ptrCast(&app.clipboard_buf),
            @intCast(app.clipboard_buf.len),
            null,
            null,
        );
    }

    app.clipboard_len = copy_len;
    if (applog.isEnabled()) applog.appLog("[win] clipboard_get_ui: len={d}\n", .{copy_len});

    // Signal completion
    _ = c.SetEvent(app.clipboard_event);
}

/// Handle clipboard set on UI thread (called via WM_APP_CLIPBOARD_SET)
fn handleClipboardSetOnUIThread(app: *App) void {
    app.clipboard_result = 0; // Failure by default

    const data = app.clipboard_set_data orelse {
        _ = c.SetEvent(app.clipboard_event);
        return;
    };
    const len = app.clipboard_set_len;

    if (len == 0) {
        app.clipboard_result = 1;
        _ = c.SetEvent(app.clipboard_event);
        return;
    }

    // Convert UTF-8 to UTF-16
    const wide_len = c.MultiByteToWideChar(
        c.CP_UTF8,
        0,
        @ptrCast(data),
        @intCast(len),
        null,
        0,
    );

    if (wide_len <= 0) {
        if (applog.isEnabled()) applog.appLog("[win] clipboard_set_ui: UTF-8 to UTF-16 conversion failed\n", .{});
        _ = c.SetEvent(app.clipboard_event);
        return;
    }

    const hwnd = app.hwnd orelse null;

    // Open clipboard
    if (c.OpenClipboard(hwnd) == 0) {
        if (applog.isEnabled()) applog.appLog("[win] clipboard_set_ui: OpenClipboard failed\n", .{});
        _ = c.SetEvent(app.clipboard_event);
        return;
    }
    defer _ = c.CloseClipboard();

    _ = c.EmptyClipboard();

    // Allocate global memory for UTF-16 data (+1 for null terminator)
    const byte_size: usize = (@as(usize, @intCast(wide_len)) + 1) * 2;
    const hglobal = c.GlobalAlloc(c.GMEM_MOVEABLE, byte_size);
    if (hglobal == null) {
        if (applog.isEnabled()) applog.appLog("[win] clipboard_set_ui: GlobalAlloc failed\n", .{});
        _ = c.SetEvent(app.clipboard_event);
        return;
    }

    const dest_ptr = c.GlobalLock(hglobal);
    if (dest_ptr == null) {
        _ = c.GlobalFree(hglobal);
        _ = c.SetEvent(app.clipboard_event);
        return;
    }

    // Convert and copy
    _ = c.MultiByteToWideChar(
        c.CP_UTF8,
        0,
        @ptrCast(data),
        @intCast(len),
        @ptrCast(@alignCast(dest_ptr)),
        wide_len,
    );

    // Null terminate
    const wide_dest: [*]u16 = @ptrCast(@alignCast(dest_ptr));
    wide_dest[@intCast(wide_len)] = 0;

    _ = c.GlobalUnlock(hglobal);

    // Set clipboard data
    if (c.SetClipboardData(c.CF_UNICODETEXT, hglobal) == null) {
        _ = c.GlobalFree(hglobal);
        if (applog.isEnabled()) applog.appLog("[win] clipboard_set_ui: SetClipboardData failed\n", .{});
        _ = c.SetEvent(app.clipboard_event);
        return;
    }

    if (applog.isEnabled()) applog.appLog("[win] clipboard_set_ui: success len={d}\n", .{len});
    app.clipboard_result = 1;
    _ = c.SetEvent(app.clipboard_event);
}

/// Show or update ext-float window (msg_show) on UI thread
/// Note: Long messages (5+ lines) are now handled by Zig core via Neovim split window.
/// This function only handles short messages for external window display.
/// Exception: confirm dialogs are always shown here since Neovim split/float can't render during cmdline mode.
fn showMessageWindowOnUIThread(app: *App, msg: DisplayMessage) void {
    if (applog.isEnabled()) applog.appLog("[win] showMessageWindowOnUIThread: text_len={d} kind={s}\n", .{ msg.text_len, msg.kind[0..msg.kind_len] });

    // Build combined content from display_messages stack
    var combined_text: [16384]u8 = undefined;
    var combined_len: usize = 0;
    for (app.display_messages.items) |dm| {
        if (combined_len > 0 and combined_len < combined_text.len - 1) {
            combined_text[combined_len] = '\n';
            combined_len += 1;
        }
        const copy_len = @min(dm.text_len, combined_text.len - combined_len);
        @memcpy(combined_text[combined_len..][0..copy_len], dm.text[0..copy_len]);
        combined_len += copy_len;
    }

    // Count lines for display calculation
    var line_count: u32 = 1;
    for (combined_text[0..combined_len]) |ch| {
        if (ch == '\n') line_count += 1;
    }

    // Determine message type
    const kind_str = msg.kind[0..msg.kind_len];
    const is_confirm = std.mem.eql(u8, kind_str, "confirm") or
        std.mem.eql(u8, kind_str, "confirm_sub");
    const is_prompt = is_confirm or std.mem.eql(u8, kind_str, "return_prompt");

    // External window with auto-hide
    const cell_h = app.cell_h_px;
    const padding: c_int = 16;

    // Get app window position and size (position relative to app window, not screen)
    var app_rect: c.RECT = undefined;
    const main_hwnd = app.hwnd orelse return;
    _ = c.GetWindowRect(main_hwnd, &app_rect);
    const app_width = app_rect.right - app_rect.left;
    const app_height = app_rect.bottom - app_rect.top;

    // Calculate window size based on message type
    var window_width: c_int = undefined;
    var window_height: c_int = undefined;
    const line_height: c_int = @intCast(cell_h + 4);

    if (is_confirm) {
        // For confirm dialogs (like E325), use larger fixed width and calculate height
        // based on line count. The text will be word-wrapped.
        window_width = @min(800, app_width - 40);  // Up to 800px or app width - 40
        // Height: line_count * line_height + padding, but at least 200px for readability
        const calc_height: c_int = @intCast(@as(u32, @intCast(line_height)) * line_count + @as(u32, @intCast(padding * 2)));
        window_height = @max(200, @min(calc_height, app_height - 100));
        if (applog.isEnabled()) applog.appLog("[win] confirm dialog: line_count={d} calc_height={d} window_height={d}\n", .{ line_count, calc_height, window_height });
    } else {
        // For regular messages, use text-based width calculation
        const text_len_int: c_int = @intCast(combined_len);
        const estimated_width: c_int = @intCast(@as(u32, @intCast(text_len_int)) * (cell_h / 2) + @as(u32, @intCast(padding * 2)));
        window_width = @max(100, @min(estimated_width, 600));
        window_height = @intCast(@as(u32, @intCast(line_height)) * line_count + @as(u32, @intCast(padding * 2)));
    }

    // Position based on message type (relative to app window)
    var window_x: c_int = undefined;
    var window_y: c_int = undefined;
    if (is_confirm) {
        // Center horizontally in app window
        window_x = app_rect.left + @divTrunc(app_width - window_width, 2);

        // Vertical position: center but avoid cmdline row
        if (app.ext_cmdline_enabled) {
            // ext-cmdline=true: center in app window, ext-cmdline will be brought to front separately
            window_y = app_rect.top + @divTrunc(app_height - window_height, 2);
        } else {
            // ext-cmdline=false: position above the cmdline row (last row)
            // Leave space for cmdline at bottom (1 row + some margin)
            const cmdline_reserve: c_int = @intCast(cell_h + 8);
            const available_height = app_height - cmdline_reserve;
            window_y = app_rect.top + @divTrunc(available_height - window_height, 2);
            // Ensure it doesn't go above app window
            if (window_y < app_rect.top + 10) {
                window_y = app_rect.top + 10;
            }
        }
        if (applog.isEnabled()) applog.appLog("[win] confirm dialog position: x={d} y={d} ext_cmdline={}\n", .{ window_x, window_y, app.ext_cmdline_enabled });
    } else if (is_prompt) {
        // Bottom center for other prompts (relative to app window)
        window_x = app_rect.left + @divTrunc(app_width - window_width, 2);
        window_y = app_rect.bottom - window_height - 40;
    } else {
        // Top-right for regular messages (screen coordinates like msg_history/macOS)
        const screen_w = c.GetSystemMetrics(c.SM_CXSCREEN);
        window_x = screen_w - window_width - 10;
        window_y = 10;
    }

    // Check if this is a return_prompt (preserve layout from confirm dialog)
    const is_return_prompt = std.mem.eql(u8, kind_str, "return_prompt");

    if (app.message_window) |*msg_win| {
        // Update existing window
        const copy_len = @min(combined_len, msg_win.text.len);
        @memcpy(msg_win.text[0..copy_len], combined_text[0..copy_len]);
        msg_win.text_len = copy_len;
        @memcpy(msg_win.kind[0..msg.kind_len], msg.kind[0..msg.kind_len]);
        msg_win.kind_len = msg.kind_len;
        msg_win.hl_id = msg.hl_id;
        msg_win.line_count = line_count;

        // For return_prompt, preserve the layout from the previous confirm dialog
        if (is_return_prompt and msg_win.saved_width > 0) {
            // Keep the saved is_long_mode and don't resize the window
            msg_win.is_long_mode = msg_win.saved_is_long_mode;
            // Just redraw without resizing
            _ = c.InvalidateRect(msg_win.hwnd, null, c.TRUE);
            _ = c.ShowWindow(msg_win.hwnd, c.SW_SHOWNOACTIVATE);
            if (applog.isEnabled()) applog.appLog("[win] return_prompt: preserving layout (saved_width={d})\n", .{msg_win.saved_width});
            return;
        }

        // Use long mode (word wrap) for confirm dialogs or multi-line messages
        msg_win.is_long_mode = is_confirm or line_count > 1;

        // Resize and reposition window
        _ = c.SetWindowPos(
            msg_win.hwnd,
            null,
            window_x,
            window_y,
            window_width,
            window_height,
            c.SWP_NOZORDER | c.SWP_NOACTIVATE,
        );

        // Save layout for return_prompt if this is a confirm dialog
        if (is_confirm) {
            msg_win.saved_width = window_width;
            msg_win.saved_height = window_height;
            msg_win.saved_is_long_mode = msg_win.is_long_mode;
        }

        // Redraw the window
        _ = c.InvalidateRect(msg_win.hwnd, null, c.TRUE);
        _ = c.ShowWindow(msg_win.hwnd, c.SW_SHOWNOACTIVATE);

        // Note: z-order adjustment is handled in createExternalWindowOnUIThread
        return;
    }

    // Ensure external window class is registered
    if (!ensureExternalWindowClassRegistered()) {
        if (applog.isEnabled()) applog.appLog("[win] message window class registration failed\n", .{});
        return;
    }

    // Create window
    const msg_hwnd = c.CreateWindowExW(
        c.WS_EX_TOPMOST | c.WS_EX_TOOLWINDOW | c.WS_EX_NOACTIVATE,
        @ptrCast(external_window_class_name.ptr),
        @ptrCast(&[_:0]u16{ 'M', 'e', 's', 's', 'a', 'g', 'e', 0 }),
        c.WS_POPUP,
        window_x,
        window_y,
        window_width,
        window_height,
        null,
        null,
        c.GetModuleHandleW(null),
        null,
    );

    if (msg_hwnd == null) {
        if (applog.isEnabled()) applog.appLog("[win] CreateWindowExW failed for message window\n", .{});
        return;
    }

    // Store window state
    var msg_win = MessageWindow{
        .hwnd = msg_hwnd.?,
        .line_count = line_count,
        // Use long mode (word wrap) for confirm dialogs or multi-line messages
        .is_long_mode = is_confirm or line_count > 1,
        // Save layout for return_prompt if this is a confirm dialog
        .saved_width = if (is_confirm) window_width else 0,
        .saved_height = if (is_confirm) window_height else 0,
        .saved_is_long_mode = is_confirm or line_count > 1,
    };
    const copy_len = @min(combined_len, msg_win.text.len);
    @memcpy(msg_win.text[0..copy_len], combined_text[0..copy_len]);
    msg_win.text_len = copy_len;
    @memcpy(msg_win.kind[0..msg.kind_len], msg.kind[0..msg.kind_len]);
    msg_win.kind_len = msg.kind_len;
    msg_win.hl_id = msg.hl_id;
    app.message_window = msg_win;

    // Set userdata so ExternalWndProc can find App
    _ = c.SetWindowLongPtrW(msg_hwnd, c.GWLP_USERDATA, @bitCast(@intFromPtr(app)));

    // Show window
    _ = c.ShowWindow(msg_hwnd, c.SW_SHOWNOACTIVATE);
    _ = c.InvalidateRect(msg_hwnd, null, c.TRUE);

    if (applog.isEnabled()) applog.appLog("[win] message window created: lines={d}\n", .{line_count});

    // Note: For confirm dialogs, z-order adjustment is handled when cmdline window is created
    // (in createExternalWindowOnUIThread). This avoids timing issues where cmdline might be
    // destroyed immediately after message window creation.
}

/// Hide and destroy message window
fn hideMessageWindow(app: *App) void {
    if (app.message_window) |*msg_win| {
        if (applog.isEnabled()) applog.appLog("[win] hiding message window\n", .{});
        msg_win.deinit();
        app.message_window = null;
    }
    // Clear display messages stack
    app.display_messages.clearRetainingCapacity();
}

/// Update ext-float (msg_show/msg_history) window positions
/// Called asynchronously via WM_APP_UPDATE_EXT_FLOAT_POS to avoid deadlock
fn updateExtFloatPositions(app: *App) void {
    const main_hwnd = app.hwnd orelse return;

    // Get data while mutex is locked
    app.mu.lock();
    const cell_w = app.cell_w_px;
    const cell_h = app.cell_h_px;
    const linespace = app.linespace_px;
    const cursor_grid = app.last_cursor_grid;
    const pos_mode = app.config.messages.msg_pos.ext_float;
    const cursor_ext_hwnd: ?c.HWND = if (app.external_windows.get(cursor_grid)) |ew| ew.hwnd else null;
    const msg_show_entry = app.external_windows.getPtr(MESSAGE_GRID_ID);
    const msg_history_entry = app.external_windows.getPtr(MSG_HISTORY_GRID_ID);
    const corep = app.corep;

    // Copy window info
    const msg_show_hwnd: ?c.HWND = if (msg_show_entry) |e| e.hwnd else null;
    const msg_show_rows: u32 = if (msg_show_entry) |e| e.rows else 0;
    const msg_show_cols: u32 = if (msg_show_entry) |e| e.cols else 0;
    const msg_history_hwnd: ?c.HWND = if (msg_history_entry) |e| e.hwnd else null;
    const msg_history_rows: u32 = if (msg_history_entry) |e| e.rows else 0;
    const msg_history_cols: u32 = if (msg_history_entry) |e| e.cols else 0;
    app.mu.unlock();

    // Calculate target rect based on position mode (mutex unlocked, safe to call core functions)
    var target_rect: c.RECT = undefined;
    switch (pos_mode) {
        .display => {
            target_rect = .{
                .left = 0,
                .top = 0,
                .right = c.GetSystemMetrics(c.SM_CXSCREEN),
                .bottom = c.GetSystemMetrics(c.SM_CYSCREEN),
            };
        },
        .window => {
            // Window-based: use cursor's window
            if (cursor_ext_hwnd) |hwnd| {
                if (c.GetWindowRect(hwnd, &target_rect) == 0) {
                    target_rect = .{ .left = 0, .top = 0, .right = c.GetSystemMetrics(c.SM_CXSCREEN), .bottom = c.GetSystemMetrics(c.SM_CYSCREEN) };
                }
            } else {
                var client_rect: c.RECT = undefined;
                if (c.GetClientRect(main_hwnd, &client_rect) != 0) {
                    var pt: c.POINT = .{ .x = 0, .y = 0 };
                    _ = c.ClientToScreen(main_hwnd, &pt);
                    target_rect = .{
                        .left = pt.x,
                        .top = pt.y,
                        .right = pt.x + client_rect.right,
                        .bottom = pt.y + client_rect.bottom,
                    };
                } else {
                    target_rect = .{ .left = 0, .top = 0, .right = c.GetSystemMetrics(c.SM_CXSCREEN), .bottom = c.GetSystemMetrics(c.SM_CYSCREEN) };
                }
            }
        },
        .grid => {
            // Grid-based: use cursor grid's bounds
            if (cursor_ext_hwnd) |hwnd| {
                // Cursor is in external window
                if (c.GetWindowRect(hwnd, &target_rect) == 0) {
                    target_rect = .{ .left = 0, .top = 0, .right = c.GetSystemMetrics(c.SM_CXSCREEN), .bottom = c.GetSystemMetrics(c.SM_CYSCREEN) };
                }
            } else {
                // Get grid bounds from core (safe now, outside of callback)
                var client_rect: c.RECT = undefined;
                _ = c.GetClientRect(main_hwnd, &client_rect);

                var client_origin: c.POINT = .{ .x = 0, .y = 0 };
                _ = c.ClientToScreen(main_hwnd, &client_origin);

                var grid_right_px: c_int = client_rect.right;
                var grid_bottom_px: c_int = client_rect.bottom;

                if (corep) |cp| {
                    var grids: [16]core.GridInfo = undefined;
                    const count = core.zonvie_core_get_visible_grids(cp, &grids, 16);
                    if (count > 0) {
                        for (grids[0..count]) |grid| {
                            if (grid.grid_id == cursor_grid) {
                                const end_col: u32 = @intCast(@max(0, grid.start_col + @as(i32, @intCast(grid.cols))));
                                const end_row: u32 = @intCast(@max(0, grid.start_row + @as(i32, @intCast(grid.rows))));
                                grid_right_px = @intCast(end_col * cell_w);
                                grid_bottom_px = @intCast(end_row * (cell_h + linespace));
                                break;
                            }
                        }
                    }
                }

                target_rect = .{
                    .left = client_origin.x,
                    .top = client_origin.y,
                    .right = client_origin.x + grid_right_px,
                    .bottom = client_origin.y + grid_bottom_px,
                };
            }
        },
    }

    // Update msg_history position first (if exists)
    var history_bottom: c_int = target_rect.top + 10;
    if (msg_history_hwnd) |hwnd| {
        const content_w: c_int = @intCast(msg_history_cols * cell_w);
        const content_h: c_int = @intCast(msg_history_rows * cell_h);
        const client_w: c_int = content_w + @as(c_int, @intCast(MSG_PADDING * 2));
        const client_h: c_int = content_h + @as(c_int, @intCast(MSG_PADDING * 2));

        var rect: c.RECT = .{ .left = 0, .top = 0, .right = client_w, .bottom = client_h };
        _ = c.AdjustWindowRectEx(&rect, c.WS_POPUP, 0, c.WS_EX_TOPMOST);
        const window_w: c_int = rect.right - rect.left;
        const window_h: c_int = rect.bottom - rect.top;

        const pos_x = target_rect.right - window_w - 10;
        const pos_y: c_int = target_rect.top + 10;
        history_bottom = pos_y + window_h;

        _ = c.SetWindowPos(hwnd, null, pos_x, pos_y, window_w, window_h, c.SWP_NOACTIVATE | c.SWP_NOZORDER);
        _ = c.InvalidateRect(hwnd, null, 0);
        if (applog.isEnabled()) applog.appLog("[win] updateExtFloatPositions: msg_history at ({d},{d}) size=({d},{d})\n", .{ pos_x, pos_y, window_w, window_h });
    }

    // Update msg_show position (if exists)
    if (msg_show_hwnd) |hwnd| {
        const content_w: c_int = @intCast(msg_show_cols * cell_w);
        const content_h: c_int = @intCast(msg_show_rows * cell_h);
        const client_w: c_int = content_w + @as(c_int, @intCast(MSG_PADDING * 2));
        const client_h: c_int = content_h + @as(c_int, @intCast(MSG_PADDING * 2));

        var rect: c.RECT = .{ .left = 0, .top = 0, .right = client_w, .bottom = client_h };
        _ = c.AdjustWindowRectEx(&rect, c.WS_POPUP, 0, c.WS_EX_TOPMOST);
        const window_w: c_int = rect.right - rect.left;
        const window_h: c_int = rect.bottom - rect.top;

        const pos_x = target_rect.right - window_w - 10;
        // If msg_history exists, position below it; otherwise at top
        const pos_y: c_int = if (msg_history_hwnd != null) history_bottom + 4 else target_rect.top + 10;

        _ = c.SetWindowPos(hwnd, null, pos_x, pos_y, window_w, window_h, c.SWP_NOACTIVATE | c.SWP_NOZORDER);
        _ = c.InvalidateRect(hwnd, null, 0);
        if (applog.isEnabled()) applog.appLog("[win] updateExtFloatPositions: msg_show at ({d},{d}) size=({d},{d})\n", .{ pos_x, pos_y, window_w, window_h });
    }
}

/// Update or create mini windows (showmode / showcmd / ruler)
fn updateMiniWindows(app: *App) void {
    const main_hwnd = app.hwnd orelse return;

    // Get cell dimensions and config
    app.mu.lock();
    const cell_w = app.cell_w_px;
    const cell_h = app.cell_h_px;
    const linespace = app.linespace_px;
    const mini_pos_mode = app.config.messages.msg_pos.mini;
    const cursor_grid = app.last_cursor_grid;
    app.mu.unlock();

    const window_height: c_int = @intCast(cell_h); // Exactly 1 cell height (no margin)

    // Calculate target rect based on position mode
    var anchor_x: c_int = 0;
    var anchor_y: c_int = 0;

    switch (mini_pos_mode) {
        .display => {
            // Display-based: bottom-right of screen
            anchor_x = c.GetSystemMetrics(c.SM_CXSCREEN);
            anchor_y = c.GetSystemMetrics(c.SM_CYSCREEN);
        },
        .window => {
            // Window-based: check if cursor is in external window
            app.mu.lock();
            const ext_win = app.external_windows.get(cursor_grid);
            app.mu.unlock();

            if (ext_win) |ew| {
                var rect: c.RECT = undefined;
                if (c.GetWindowRect(ew.hwnd, &rect) != 0) {
                    anchor_x = rect.right;
                    anchor_y = rect.bottom;
                } else {
                    // Fallback to main window
                    var client_rect: c.RECT = undefined;
                    _ = c.GetClientRect(main_hwnd, &client_rect);
                    var pt: c.POINT = .{ .x = client_rect.right, .y = client_rect.bottom };
                    _ = c.ClientToScreen(main_hwnd, &pt);
                    anchor_x = pt.x;
                    anchor_y = pt.y;
                }
            } else {
                // Main window
                var client_rect: c.RECT = undefined;
                _ = c.GetClientRect(main_hwnd, &client_rect);
                var pt: c.POINT = .{ .x = client_rect.right, .y = client_rect.bottom };
                _ = c.ClientToScreen(main_hwnd, &pt);
                anchor_x = pt.x;
                anchor_y = pt.y;
            }
        },
        .grid => {
            // Grid-based: use cursor grid's bounds
            var client_rect: c.RECT = undefined;
            _ = c.GetClientRect(main_hwnd, &client_rect);

            var client_origin: c.POINT = .{ .x = 0, .y = 0 };
            _ = c.ClientToScreen(main_hwnd, &client_origin);

            var grid_right_px: c_int = client_rect.right;
            var grid_bottom_px: c_int = client_rect.bottom;

            // Check if cursor is in external window first
            app.mu.lock();
            const ext_win = app.external_windows.get(cursor_grid);
            app.mu.unlock();

            if (ext_win) |ew| {
                var rect: c.RECT = undefined;
                if (c.GetWindowRect(ew.hwnd, &rect) != 0) {
                    anchor_x = rect.right;
                    anchor_y = rect.bottom;
                } else {
                    anchor_x = client_origin.x + grid_right_px;
                    anchor_y = client_origin.y + grid_bottom_px;
                }
            } else {
                // Try to get grid bounds from core
                if (app.corep) |corep| {
                    var grids: [16]core.GridInfo = undefined;
                    const count = core.zonvie_core_get_visible_grids(corep, &grids, 16);
                    if (count > 0) {
                        for (grids[0..count]) |grid| {
                            if (grid.grid_id == cursor_grid) {
                                const end_col: u32 = @intCast(@max(0, grid.start_col + @as(i32, @intCast(grid.cols))));
                                const end_row: u32 = @intCast(@max(0, grid.start_row + @as(i32, @intCast(grid.rows))));
                                grid_right_px = @intCast(end_col * cell_w);
                                grid_bottom_px = @intCast(end_row * (cell_h + linespace));
                                break;
                            }
                        }
                    }
                }
                anchor_x = client_origin.x + grid_right_px;
                anchor_y = client_origin.y + grid_bottom_px;
            }
        },
    }

    // Count visible minis and build stack order
    var stack_index: usize = 0;
    for (0..3) |idx| {
        app.mu.lock();
        const text_len = app.mini_windows[idx].text_len;
        var text_buf: [256]u8 = undefined;
        if (text_len > 0) {
            @memcpy(text_buf[0..text_len], app.mini_windows[idx].text[0..text_len]);
        }
        app.mu.unlock();

        if (text_len == 0) {
            // Hide this mini window
            if (app.mini_windows[idx].hwnd) |mini_hwnd| {
                _ = c.DestroyWindow(mini_hwnd);
                app.mini_windows[idx].hwnd = null;
            }
            continue;
        }

        if (applog.isEnabled()) applog.appLog("[win] updateMiniWindows: idx={d} text=\"{s}\"\n", .{ idx, text_buf[0..text_len] });

        // Calculate width based on text (approximate: 8px per char + padding)
        const text_width: c_int = @intCast(text_len * 8 + 16);
        const window_width: c_int = @max(50, text_width);

        // Position: right edge of target area, stacking upward from bottom
        const window_x = anchor_x - window_width;
        const window_y = anchor_y - window_height - @as(c_int, @intCast(stack_index)) * window_height;

        if (app.mini_windows[idx].hwnd) |mini_hwnd| {
            // Update existing window position and size
            _ = c.SetWindowPos(mini_hwnd, null, window_x, window_y, window_width, window_height, c.SWP_NOZORDER | c.SWP_NOACTIVATE);
            _ = c.InvalidateRect(mini_hwnd, null, c.TRUE);
        } else {
            // Create new mini window
            if (!ensureExternalWindowClassRegistered()) continue;

            const use_transparency = app.config.window.opacity < 1.0;
            const base_style: c.DWORD = c.WS_EX_TOPMOST | c.WS_EX_TOOLWINDOW | c.WS_EX_NOACTIVATE;
            const dwExStyle: c.DWORD = if (use_transparency) base_style | c.WS_EX_LAYERED else base_style;

            const mini_hwnd = c.CreateWindowExW(
                dwExStyle,
                @ptrCast(external_window_class_name.ptr),
                @ptrCast(&[_:0]u16{ 'M', 'i', 'n', 'i', 0 }),
                c.WS_POPUP,
                window_x,
                window_y,
                window_width,
                window_height,
                null,
                null,
                c.GetModuleHandleW(null),
                null,
            );

            if (mini_hwnd == null) {
                if (applog.isEnabled()) applog.appLog("[win] CreateWindowExW failed for mini window\n", .{});
                continue;
            }

            app.mini_windows[idx].hwnd = mini_hwnd;
            _ = c.SetWindowLongPtrW(mini_hwnd, c.GWLP_USERDATA, @bitCast(@intFromPtr(app)));

            if (use_transparency) {
                const opacity_u8: u8 = @intFromFloat(app.config.window.opacity * 255.0);
                _ = c.SetLayeredWindowAttributes(mini_hwnd, 0, opacity_u8, c.LWA_ALPHA);
            }

            _ = c.ShowWindow(mini_hwnd, c.SW_SHOWNOACTIVATE);
            _ = c.InvalidateRect(mini_hwnd, null, c.TRUE);

            if (applog.isEnabled()) applog.appLog("[win] mini window created for idx={d}\n", .{idx});
        }

        stack_index += 1;
    }
}

fn onExternalWindow(ctx: ?*anyopaque, grid_id: i64, win: i64, rows: u32, cols: u32, start_row: i32, start_col: i32) callconv(.c) void {
    const app: *App = @ptrCast(@alignCast(ctx.?));
    if (applog.isEnabled()) applog.appLog("[win] on_external_window: grid_id={d} win={d} rows={d} cols={d} pos=({d},{d})\n", .{ grid_id, win, rows, cols, start_row, start_col });

    app.mu.lock();
    defer app.mu.unlock();

    // Check if already exists
    if (app.external_windows.get(grid_id) != null) {
        if (applog.isEnabled()) applog.appLog("[win] external window already exists for grid_id={d}\n", .{grid_id});
        return;
    }

    // Queue the request for UI thread processing
    app.pending_external_windows.append(app.alloc, .{
        .grid_id = grid_id,
        .win = win,
        .rows = rows,
        .cols = cols,
        .start_row = start_row,
        .start_col = start_col,
    }) catch |e| {
        if (applog.isEnabled()) applog.appLog("[win] failed to queue external window request: {any}\n", .{e});
        return;
    };

    // Post message to UI thread to create the window
    if (app.hwnd) |main_hwnd| {
        _ = c.PostMessageW(main_hwnd, WM_APP_CREATE_EXTERNAL_WINDOW, 0, 0);
    }
}

/// Actually create external window (must be called on UI thread)
fn createExternalWindowOnUIThread(app: *App, req: PendingExternalWindow) void {
    if (applog.isEnabled()) applog.appLog("[win] createExternalWindowOnUIThread: grid_id={d} rows={d} cols={d}\n", .{ req.grid_id, req.rows, req.cols });

    // Ensure external window class is registered
    if (!ensureExternalWindowClassRegistered()) {
        if (applog.isEnabled()) applog.appLog("[win] external window class registration failed\n", .{});
        return;
    }

    // Get cell dimensions from main atlas
    const cell_w: u32 = app.cell_w_px;
    const cell_h: u32 = app.cell_h_px;
    const content_w: c_int = @intCast(req.cols * cell_w);
    const content_h: c_int = @intCast(req.rows * cell_h);

    // Check if this is a special window (cmdline, popupmenu, msg_show, msg_history)
    const is_cmdline = (req.grid_id == CMDLINE_GRID_ID);
    const is_popupmenu = (req.grid_id == POPUPMENU_GRID_ID);
    const is_msg_show = (req.grid_id == MESSAGE_GRID_ID);
    const is_msg_history = (req.grid_id == MSG_HISTORY_GRID_ID);

    // For cmdline: add margin and icon area
    // Total width = icon_margin_left + icon_size + icon_margin_right + content + padding*2
    const cmdline_icon_total_width: u32 = if (is_cmdline) CMDLINE_ICON_MARGIN_LEFT + CMDLINE_ICON_SIZE + CMDLINE_ICON_MARGIN_RIGHT else 0;
    const cmdline_total_padding: u32 = if (is_cmdline) CMDLINE_PADDING * 2 else 0;

    // For msg_show/msg_history: add margin around content
    const msg_total_padding: u32 = if (is_msg_show or is_msg_history) MSG_PADDING * 2 else 0;

    const client_w: c_int = content_w + @as(c_int, @intCast(cmdline_icon_total_width + cmdline_total_padding + msg_total_padding));
    const client_h: c_int = content_h + @as(c_int, @intCast(cmdline_total_padding + msg_total_padding));

    // Window style: borderless popup for cmdline, popupmenu, and msg_history, normal for others
    // Note: WS_VISIBLE is NOT included - we use ShowWindow(SW_SHOWNA) to show without activating
    const is_special_window = is_cmdline or is_popupmenu or is_msg_show or is_msg_history;
    const dwStyle: c.DWORD = if (is_special_window) c.WS_POPUP else c.WS_OVERLAPPEDWINDOW;
    // Add WS_EX_NOREDIRECTIONBITMAP for transparency mode
    const use_transparency = app.config.window.opacity < 1.0;
    const dwExStyle: c.DWORD = (if (is_special_window) @as(c.DWORD, @intCast(c.WS_EX_TOPMOST)) else @as(c.DWORD, 0)) |
        (if (use_transparency) @as(c.DWORD, @intCast(c.WS_EX_NOREDIRECTIONBITMAP)) else @as(c.DWORD, 0));

    var rect: c.RECT = .{
        .left = 0,
        .top = 0,
        .right = client_w,
        .bottom = client_h,
    };
    _ = c.AdjustWindowRectEx(&rect, dwStyle, 0, dwExStyle);
    const window_w: c_int = rect.right - rect.left;
    const window_h: c_int = rect.bottom - rect.top;

    if (applog.isEnabled()) applog.appLog("[win] external window: content=({d},{d}) client=({d},{d}) window=({d},{d}) is_cmdline={}\n", .{ content_w, content_h, client_w, client_h, window_w, window_h, is_cmdline });

    // Calculate window position
    var pos_x: c_int = c.CW_USEDEFAULT;
    var pos_y: c_int = c.CW_USEDEFAULT;

    // Tab externalization: use pending position if set (only for regular external windows, not special windows)
    // Also check timeout (500ms) to prevent stale position from affecting unrelated windows.
    const pending_timeout_ms: i64 = 500;
    const now_ms = std.time.milliTimestamp();
    const pending_age_ms = now_ms - app.pending_external_window_position_time;
    if (!is_special_window and app.pending_external_window_position != null and pending_age_ms < pending_timeout_ms) {
        const pos = app.pending_external_window_position.?;
        // Position so the window is centered horizontally on cursor, below cursor
        pos_x = pos.x - @divTrunc(window_w, 2);
        pos_y = pos.y;
        app.pending_external_window_position = null;  // Clear after use
        if (applog.isEnabled()) applog.appLog("[win] external window positioned from pending position: ({d},{d}) age={d}ms\n", .{ pos_x, pos_y, pending_age_ms });
    } else if (app.pending_external_window_position != null and pending_age_ms >= pending_timeout_ms) {
        // Pending position expired, clear it
        if (applog.isEnabled()) applog.appLog("[win] clearing stale pending_external_window_position (age={d}ms)\n", .{pending_age_ms});
        app.pending_external_window_position = null;
    }

    if (pos_x != c.CW_USEDEFAULT) {
        // Position already set from pending position, skip other positioning logic
    } else if (req.start_row >= 0 and req.start_col >= 0) {
        // Check if anchor window (req.win) is an external window
        // Copy hwnd while holding lock to avoid use-after-free
        app.mu.lock();
        const anchor_hwnd: ?c.HWND = if (req.win > 0) blk: {
            if (app.external_windows.get(req.win)) |ew| {
                break :blk ew.hwnd;
            }
            break :blk null;
        } else null;
        app.mu.unlock();

        if (anchor_hwnd) |ahwnd| {
            // Position relative to anchor external window
            var anchor_rect: c.RECT = undefined;
            if (c.GetWindowRect(ahwnd, &anchor_rect) != 0) {
                var client_pt: c.POINT = .{ .x = 0, .y = 0 };
                _ = c.ClientToScreen(ahwnd, &client_pt);

                const px_x: c_int = @intCast(@as(i32, @intCast(req.start_col)) * @as(i32, @intCast(cell_w)));
                const px_y: c_int = @intCast(@as(i32, @intCast(req.start_row)) * @as(i32, @intCast(cell_h)));

                pos_x = client_pt.x + px_x;
                // For popupmenu: position 1 row above the anchor position
                pos_y = client_pt.y + px_y - if (is_popupmenu) @as(c_int, @intCast(cell_h)) else 0;
                if (applog.isEnabled()) applog.appLog("[win] external window position from anchor ext_win={d}: ({d},{d}) cell=({d},{d})\n", .{ req.win, pos_x, pos_y, req.start_col, req.start_row });
            }
        } else if (app.hwnd) |main_hwnd| {
            // Position relative to main window using win_pos
            var main_rect: c.RECT = undefined;
            if (c.GetWindowRect(main_hwnd, &main_rect) != 0) {
                // Get main window client area origin
                var client_pt: c.POINT = .{ .x = 0, .y = 0 };
                _ = c.ClientToScreen(main_hwnd, &client_pt);

                // Calculate position in pixels from cell coordinates
                const px_x: c_int = @intCast(@as(i32, @intCast(req.start_col)) * @as(i32, @intCast(cell_w)));
                const px_y: c_int = @intCast(@as(i32, @intCast(req.start_row)) * @as(i32, @intCast(cell_h)));

                pos_x = client_pt.x + px_x;
                // For popupmenu: position 1 row above the anchor position
                pos_y = client_pt.y + px_y - if (is_popupmenu) @as(c_int, @intCast(cell_h)) else 0;
                if (applog.isEnabled()) applog.appLog("[win] external window position from win_pos: ({d},{d}) cell=({d},{d})\n", .{ pos_x, pos_y, req.start_col, req.start_row });
            }
        }
    } else if (is_cmdline) {
        // Position cmdline window
        // If message window is visible (confirm dialog), position directly below it
        app.mu.lock();
        const msg_win = app.message_window;
        app.mu.unlock();

        if (msg_win) |mw| {
            var msg_rect: c.RECT = undefined;
            if (c.GetWindowRect(mw.hwnd, &msg_rect) != 0) {
                // Position directly below message window, centered horizontally
                const msg_width = msg_rect.right - msg_rect.left;
                pos_x = msg_rect.left + @divTrunc(msg_width - window_w, 2);
                pos_y = msg_rect.bottom + 4; // 4px gap below message window
                if (applog.isEnabled()) applog.appLog("[win] cmdline window below message: ({d},{d})\n", .{ pos_x, pos_y });
            } else {
                // Fallback: center on screen
                const screen_w = c.GetSystemMetrics(c.SM_CXSCREEN);
                const screen_h = c.GetSystemMetrics(c.SM_CYSCREEN);
                pos_x = @divTrunc(screen_w - window_w, 2);
                pos_y = @divTrunc(screen_h - window_h, 3);
                if (applog.isEnabled()) applog.appLog("[win] cmdline window position (fallback): ({d},{d})\n", .{ pos_x, pos_y });
            }
        } else {
            // No message window: use saved position if available, otherwise center on screen
            app.mu.lock();
            const saved_x = app.cmdline_saved_x;
            const saved_y = app.cmdline_saved_y;
            app.mu.unlock();

            if (saved_x != null and saved_y != null) {
                // Use saved position, but ensure window stays on screen
                const screen_w = c.GetSystemMetrics(c.SM_CXSCREEN);
                const screen_h = c.GetSystemMetrics(c.SM_CYSCREEN);
                pos_x = @max(0, @min(saved_x.?, screen_w - window_w));
                pos_y = @max(0, @min(saved_y.?, screen_h - window_h));
                if (applog.isEnabled()) applog.appLog("[win] cmdline window using saved position: ({d},{d})\n", .{ pos_x, pos_y });
            } else {
                // Default: center on screen
                const screen_w = c.GetSystemMetrics(c.SM_CXSCREEN);
                const screen_h = c.GetSystemMetrics(c.SM_CYSCREEN);
                pos_x = @divTrunc(screen_w - window_w, 2);
                pos_y = @divTrunc(screen_h - window_h, 3); // Slightly above center (1/3 from top)
                if (applog.isEnabled()) applog.appLog("[win] cmdline window position (default): ({d},{d}) screen=({d},{d})\n", .{ pos_x, pos_y, screen_w, screen_h });
            }
        }
    } else if (is_popupmenu and req.start_row == -1) {
        // Popupmenu for cmdline completion: position above cmdline window
        app.mu.lock();
        const cmdline_win = app.external_windows.get(CMDLINE_GRID_ID);
        app.mu.unlock();

        if (cmdline_win) |cw| {
            var cmdline_rect: c.RECT = undefined;
            if (c.GetWindowRect(cw.hwnd, &cmdline_rect) != 0) {
                // Position above cmdline window with small gap
                pos_x = cmdline_rect.left + @as(c_int, @intCast(req.start_col)) * @as(c_int, @intCast(cell_w));
                pos_y = cmdline_rect.top - window_h - 4; // 4px gap
                if (applog.isEnabled()) applog.appLog("[win] popupmenu above cmdline: ({d},{d})\n", .{ pos_x, pos_y });
            }
        } else {
            // Fallback: center on screen
            const screen_w = c.GetSystemMetrics(c.SM_CXSCREEN);
            const screen_h = c.GetSystemMetrics(c.SM_CYSCREEN);
            pos_x = @divTrunc(screen_w - window_w, 2);
            pos_y = @divTrunc(screen_h - window_h, 2);
            if (applog.isEnabled()) applog.appLog("[win] popupmenu fallback center: ({d},{d})\n", .{ pos_x, pos_y });
        }
    } else if (is_msg_history) {
        // Message history: position at top-right based on config
        app.mu.lock();
        const target_rect = app.getExtFloatTargetRect();
        app.mu.unlock();
        pos_x = target_rect.right - window_w - 10;
        pos_y = target_rect.top + 10; // 10px from top
        if (applog.isEnabled()) applog.appLog("[win] msg_history at top-right: ({d},{d})\n", .{ pos_x, pos_y });
    } else if (is_msg_show) {
        // Message show (e.g. "Press ENTER..."): position below msg_history if visible, otherwise at top-right
        app.mu.lock();
        const msg_history_win = app.external_windows.get(MSG_HISTORY_GRID_ID);
        const target_rect = app.getExtFloatTargetRect();
        app.mu.unlock();

        if (msg_history_win) |hw| {
            // Position below msg_history window
            var history_rect: c.RECT = undefined;
            if (c.GetWindowRect(hw.hwnd, &history_rect) != 0) {
                pos_x = target_rect.right - window_w - 10;
                pos_y = history_rect.bottom + 4; // 4px gap below history window
                if (applog.isEnabled()) applog.appLog("[win] msg_show below msg_history: ({d},{d})\n", .{ pos_x, pos_y });
            } else {
                // Fallback: top-right
                pos_x = target_rect.right - window_w - 10;
                pos_y = target_rect.top + 10;
                if (applog.isEnabled()) applog.appLog("[win] msg_show at top-right (fallback): ({d},{d})\n", .{ pos_x, pos_y });
            }
        } else {
            // No msg_history: position at top-right
            pos_x = target_rect.right - window_w - 10;
            pos_y = target_rect.top + 10;
            if (applog.isEnabled()) applog.appLog("[win] msg_show at top-right: ({d},{d})\n", .{ pos_x, pos_y });
        }
    }

    // Create window using external window class
    const title_buf: [:0]const u16 = std.unicode.utf8ToUtf16LeStringLiteral("External Grid");

    const hwnd = c.CreateWindowExW(
        dwExStyle,
        @ptrCast(external_window_class_name.ptr),
        @ptrCast(title_buf.ptr),
        dwStyle, // No WS_VISIBLE - show with SW_SHOWNA to avoid activation
        pos_x,
        pos_y,
        window_w,
        window_h,
        null,
        null,
        c.GetModuleHandleW(null),
        null,
    );

    if (hwnd == null) {
        if (applog.isEnabled()) applog.appLog("[win] CreateWindowExW failed for external grid\n", .{});
        return;
    }

    // Show window without activating (SW_SHOWNA = 8)
    _ = c.ShowWindow(hwnd, 8);

    // Initialize D3D11 renderer for external window (with transparency if enabled)
    const renderer = d3d11.Renderer.init(app.alloc, hwnd, app.config.window.opacity) catch |e| {
        if (applog.isEnabled()) applog.appLog("[win] d3d11.Renderer.init failed for external window: {any}\n", .{e});
        _ = c.DestroyWindow(hwnd);
        return;
    };

    app.mu.lock();
    defer app.mu.unlock();

    // Store external window
    const ext_window = ExternalWindow{
        .hwnd = hwnd.?,
        .renderer = renderer,
        .rows = req.rows,
        .cols = req.cols,
    };

    app.external_windows.put(app.alloc, req.grid_id, ext_window) catch |e| {
        if (applog.isEnabled()) applog.appLog("[win] failed to store external window: {any}\n", .{e});
        var tmp_renderer = renderer;
        tmp_renderer.deinit();
        _ = c.DestroyWindow(hwnd);
        return;
    };

    // If msg_history window was just created/shown, reposition msg_show window below it
    if (is_msg_history) {
        if (app.external_windows.get(MESSAGE_GRID_ID)) |msg_win| {
            var history_rect: c.RECT = undefined;
            var msg_rect: c.RECT = undefined;
            if (c.GetWindowRect(hwnd, &history_rect) != 0 and c.GetWindowRect(msg_win.hwnd, &msg_rect) != 0) {
                const msg_width = msg_rect.right - msg_rect.left;
                const target_rect = app.getExtFloatTargetRect();
                const new_x = target_rect.right - msg_width - 10;
                const new_y = history_rect.bottom + 4;
                _ = c.SetWindowPos(msg_win.hwnd, null, new_x, new_y, 0, 0, c.SWP_NOSIZE | c.SWP_NOZORDER | c.SWP_NOACTIVATE);
                if (applog.isEnabled()) applog.appLog("[win] repositioned msg_show below msg_history: ({d},{d})\n", .{ new_x, new_y });
            }
        }
    }

    // Set last_cursor_grid to this grid
    app.last_cursor_grid = req.grid_id;

    // Set App pointer as user data for WndProc access
    setApp(hwnd.?, app);

    // Check for pending vertices and apply them
    var pending_idx: ?usize = null;
    for (app.pending_external_verts.items, 0..) |*pv, i| {
        if (pv.grid_id == req.grid_id) {
            pending_idx = i;
            break;
        }
    }

    if (pending_idx) |idx| {
        const pv = &app.pending_external_verts.items[idx];
        if (applog.isEnabled()) applog.appLog("[win] applying pending vertices for grid_id={d}: vert_count={d}\n", .{ req.grid_id, pv.verts.items.len });

        if (app.external_windows.getPtr(req.grid_id)) |ext_win| {
            // Copy vertices from pending to window
            ext_win.verts.clearRetainingCapacity();
            ext_win.verts.ensureTotalCapacity(app.alloc, pv.verts.items.len) catch {};
            ext_win.verts.appendSliceAssumeCapacity(pv.verts.items);
            ext_win.vert_count = pv.verts.items.len;
            ext_win.rows = pv.rows;
            ext_win.cols = pv.cols;
            ext_win.needs_redraw = true;

            // Trigger redraw
            _ = c.InvalidateRect(ext_win.hwnd, null, 0);
        }

        // Remove pending entry (free its verts and swap-remove from list)
        pv.deinit(app.alloc);
        _ = app.pending_external_verts.swapRemove(idx);
    }

    if (applog.isEnabled()) applog.appLog("[win] created external window hwnd={*} for grid_id={d}\n", .{ hwnd, req.grid_id });

    // For cmdline window: if there's a confirm/prompt dialog visible, put message BELOW cmdline
    // This is needed because confirm dialog is shown before cmdline window is created
    if (is_cmdline) {
        if (app.message_window) |msg_win| {
            const msg_kind = msg_win.kind[0..msg_win.kind_len];
            const is_confirm_visible = std.mem.eql(u8, msg_kind, "confirm") or
                std.mem.eql(u8, msg_kind, "confirm_sub") or
                std.mem.eql(u8, msg_kind, "return_prompt");
            if (is_confirm_visible) {
                // SetWindowPos with cmdline as hwndInsertAfter puts message BELOW cmdline
                _ = c.SetWindowPos(
                    msg_win.hwnd,
                    hwnd, // cmdline hwnd
                    0,
                    0,
                    0,
                    0,
                    c.SWP_NOMOVE | c.SWP_NOSIZE | c.SWP_NOACTIVATE,
                );
                if (applog.isEnabled()) applog.appLog("[win] put message window below cmdline (cmdline created)\n", .{});
            }
        }
    }

    // Activate this external window
    _ = c.SetForegroundWindow(hwnd);
}

fn onExternalWindowClose(ctx: ?*anyopaque, grid_id: i64) callconv(.c) void {
    const app: *App = @ptrCast(@alignCast(ctx.?));
    if (applog.isEnabled()) applog.appLog("[win] on_external_window_close: grid_id={d}\n", .{grid_id});

    // Remove from external_windows immediately to allow new window creation
    // Move to pending_close_windows for UI thread to destroy
    app.mu.lock();
    const main_hwnd = app.hwnd;
    if (app.external_windows.fetchRemove(grid_id)) |entry| {
        app.pending_close_windows.append(app.alloc, entry.value) catch {
            if (applog.isEnabled()) applog.appLog("[win] failed to queue close request for grid_id={d}\n", .{grid_id});
        };
    }
    app.mu.unlock();

    // Post message to UI thread to process pending close windows
    // (DestroyWindow must be called from the thread that created the window)
    if (main_hwnd) |hwnd| {
        _ = c.PostMessageW(hwnd, WM_APP_CLOSE_EXTERNAL_WINDOW, @bitCast(grid_id), 0);
    }
}

/// Actually close external window (must be called on UI thread)
/// Processes pending_close_windows queue
fn closeExternalWindowOnUIThread(app: *App, grid_id: i64) void {
    if (applog.isEnabled()) applog.appLog("[win] closeExternalWindowOnUIThread: grid_id={d}\n", .{grid_id});

    // Process all pending close windows
    app.mu.lock();
    while (app.pending_close_windows.items.len > 0) {
        var ext_win = app.pending_close_windows.items[app.pending_close_windows.items.len - 1];
        app.pending_close_windows.items.len -= 1;
        app.mu.unlock();

        // Check if IME overlay was parented to this external window
        // If so, destroy it and reset the handle so main window can create a new one
        app.mu.lock();
        if (app.ime_overlay_hwnd) |overlay| {
            const parent = c.GetParent(overlay);
            if (parent == ext_win.hwnd) {
                _ = c.DestroyWindow(overlay);
                app.ime_overlay_hwnd = null;
                if (applog.isEnabled()) applog.appLog("[win] destroyed IME overlay parented to external window\n", .{});
            }
        }
        app.mu.unlock();

        // deinit handles DestroyWindow and resource cleanup
        ext_win.deinit(app.alloc);
        if (applog.isEnabled()) applog.appLog("[win] destroyed external window hwnd={*}\n", .{ext_win.hwnd});

        app.mu.lock();
    }
    app.mu.unlock();

    // Note: We intentionally do NOT remove pending_external_verts here because
    // the pending verts might belong to a new window with the same grid_id that
    // was created after the close event was queued but before this handler ran.
}

fn onExternalVertices(ctx: ?*anyopaque, grid_id: i64, verts: ?[*]const core.Vertex, vert_count: usize, rows: u32, cols: u32) callconv(.c) void {
    const app: *App = @ptrCast(@alignCast(ctx.?));
    if (applog.isEnabled()) applog.appLog("[win] on_external_vertices: grid_id={d} vert_count={d} rows={d} cols={d}\n", .{ grid_id, vert_count, rows, cols });

    if (verts == null or vert_count == 0) return;

    app.mu.lock();
    defer app.mu.unlock();

    if (app.external_windows.getPtr(grid_id)) |ext_win| {
        // Check if size changed (for cmdline window resize)
        const size_changed = (ext_win.rows != rows or ext_win.cols != cols);

        // Window exists, copy vertices to it
        ext_win.verts.clearRetainingCapacity();
        ext_win.verts.ensureTotalCapacity(app.alloc, vert_count) catch return;
        ext_win.verts.appendSliceAssumeCapacity(verts.?[0..vert_count]);
        ext_win.vert_count = vert_count;
        ext_win.rows = rows;
        ext_win.cols = cols;
        ext_win.needs_redraw = true;

        // Note: Background color adjustment for cmdline is done in paintExternalWindow
        // to ensure both the full-window background quad and grid vertices use the same color.

        // Resize cmdline window if size changed (keep center position)
        if (grid_id == CMDLINE_GRID_ID and size_changed) {
            const cell_w = app.cell_w_px;
            const cell_h = app.cell_h_px;
            const content_w: c_int = @intCast(cols * cell_w);
            const content_h: c_int = @intCast(rows * cell_h);

            // Add margin and icon area for cmdline
            const cmdline_icon_total_width: u32 = CMDLINE_ICON_MARGIN_LEFT + CMDLINE_ICON_SIZE + CMDLINE_ICON_MARGIN_RIGHT;
            const cmdline_total_padding: u32 = CMDLINE_PADDING * 2;
            const client_w: c_int = content_w + @as(c_int, @intCast(cmdline_icon_total_width + cmdline_total_padding));
            const client_h: c_int = content_h + @as(c_int, @intCast(cmdline_total_padding));

            // Calculate window size (WS_POPUP has no decorations, so client = window)
            var rect: c.RECT = .{ .left = 0, .top = 0, .right = client_w, .bottom = client_h };
            _ = c.AdjustWindowRectEx(&rect, c.WS_POPUP, 0, c.WS_EX_TOPMOST);
            const window_w: c_int = rect.right - rect.left;
            const window_h: c_int = rect.bottom - rect.top;

            // Get current window rect to preserve center position
            var current_rect: c.RECT = undefined;
            _ = c.GetWindowRect(ext_win.hwnd, &current_rect);
            const old_center_x = @divTrunc(current_rect.left + current_rect.right, 2);
            const old_center_y = @divTrunc(current_rect.top + current_rect.bottom, 2);

            // Calculate new position to keep center
            const pos_x = old_center_x - @divTrunc(window_w, 2);
            const pos_y = old_center_y - @divTrunc(window_h, 2);

            if (applog.isEnabled()) applog.appLog("[win] cmdline resize: content=({d},{d}) window=({d},{d}) at ({d},{d})\n", .{ content_w, content_h, window_w, window_h, pos_x, pos_y });

            // Resize window while keeping center position
            _ = c.SetWindowPos(
                ext_win.hwnd,
                null,
                pos_x,
                pos_y,
                window_w,
                window_h,
                c.SWP_NOACTIVATE | c.SWP_NOZORDER,
            );

            // Resize D3D11 swapchain (gets size from window)
            ext_win.renderer.resize() catch |e| {
                if (applog.isEnabled()) applog.appLog("[win] cmdline renderer resize failed: {any}\n", .{e});
            };
        }

        // Resize popupmenu window if size changed (keep top-left position)
        if (grid_id == POPUPMENU_GRID_ID and size_changed) {
            const cell_w = app.cell_w_px;
            const cell_h = app.cell_h_px;
            const content_w: c_int = @intCast(cols * cell_w);
            const content_h: c_int = @intCast(rows * cell_h);

            // Calculate window size (WS_POPUP has no decorations, so client = window)
            var rect: c.RECT = .{ .left = 0, .top = 0, .right = content_w, .bottom = content_h };
            _ = c.AdjustWindowRectEx(&rect, c.WS_POPUP, 0, c.WS_EX_TOPMOST);
            const window_w: c_int = rect.right - rect.left;
            const window_h: c_int = rect.bottom - rect.top;

            // Get current window rect to preserve top-left position
            var current_rect: c.RECT = undefined;
            _ = c.GetWindowRect(ext_win.hwnd, &current_rect);
            const pos_x = current_rect.left;
            const pos_y = current_rect.top;

            if (applog.isEnabled()) applog.appLog("[win] popupmenu resize: content=({d},{d}) window=({d},{d}) at ({d},{d})\n", .{ content_w, content_h, window_w, window_h, pos_x, pos_y });

            // Resize window while keeping top-left position
            _ = c.SetWindowPos(
                ext_win.hwnd,
                null,
                pos_x,
                pos_y,
                window_w,
                window_h,
                c.SWP_NOACTIVATE | c.SWP_NOZORDER,
            );

            // Resize D3D11 swapchain (gets size from window)
            ext_win.renderer.resize() catch |e| {
                if (applog.isEnabled()) applog.appLog("[win] popupmenu renderer resize failed: {any}\n", .{e});
            };
        }

        // Update msg_show/msg_history window position and size
        // Note: Position update is done asynchronously via WM_APP_UPDATE_EXT_FLOAT_POS
        // to avoid deadlock when calling zonvie_core_get_visible_grids from callbacks
        if (grid_id == MESSAGE_GRID_ID or grid_id == MSG_HISTORY_GRID_ID) {
            // Mark renderer resize if needed
            if (size_changed) {
                ext_win.needs_renderer_resize = true;
            }

            // Post message to update position asynchronously (outside of callback context)
            if (app.hwnd) |main_hwnd| {
                _ = c.PostMessageW(main_hwnd, WM_APP_UPDATE_EXT_FLOAT_POS, 0, 0);
            }
        }

        // Trigger redraw
        _ = c.InvalidateRect(ext_win.hwnd, null, 0);
    } else {
        // Window doesn't exist yet - store vertices as pending
        if (applog.isEnabled()) applog.appLog("[win] storing pending vertices for grid_id={d}\n", .{grid_id});

        // Find or create pending entry for this grid_id
        var found_idx: ?usize = null;
        for (app.pending_external_verts.items, 0..) |*pv, i| {
            if (pv.grid_id == grid_id) {
                found_idx = i;
                break;
            }
        }

        if (found_idx) |idx| {
            // Update existing pending entry
            const pv = &app.pending_external_verts.items[idx];
            pv.verts.clearRetainingCapacity();
            pv.verts.ensureTotalCapacity(app.alloc, vert_count) catch return;
            pv.verts.appendSliceAssumeCapacity(verts.?[0..vert_count]);
            pv.rows = rows;
            pv.cols = cols;
        } else {
            // Create new pending entry
            var new_pv = PendingExternalVertices{
                .grid_id = grid_id,
                .rows = rows,
                .cols = cols,
            };
            new_pv.verts.ensureTotalCapacity(app.alloc, vert_count) catch return;
            new_pv.verts.appendSliceAssumeCapacity(verts.?[0..vert_count]);
            app.pending_external_verts.append(app.alloc, new_pv) catch return;
        }
    }
}

fn onCursorGridChanged(ctx: ?*anyopaque, grid_id: i64) callconv(.c) void {
    const app: *App = @ptrCast(@alignCast(ctx.?));
    if (applog.isEnabled()) applog.appLog("[win] on_cursor_grid_changed: grid_id={d}\n", .{grid_id});

    // Post message to UI thread to handle window activation
    if (app.hwnd) |main_hwnd| {
        _ = c.PostMessageW(main_hwnd, WM_APP_CURSOR_GRID_CHANGED, @bitCast(grid_id), 0);
    }
}

// External window class name
const external_window_class_name: [:0]const u16 = std.unicode.utf8ToUtf16LeStringLiteral("ZonvieExternalWin");
var external_window_class_registered: bool = false;

/// Register the external window class (call once before creating external windows)
fn ensureExternalWindowClassRegistered() bool {
    if (external_window_class_registered) return true;

    var wc: c.WNDCLASSEXW = std.mem.zeroes(c.WNDCLASSEXW);
    wc.cbSize = @sizeOf(c.WNDCLASSEXW);
    wc.style = c.CS_HREDRAW | c.CS_VREDRAW;
    wc.lpfnWndProc = ExternalWndProc;
    wc.hInstance = c.GetModuleHandleW(null);
    wc.hCursor = c.LoadCursorW(null, @ptrFromInt(32512)); // IDC_ARROW
    wc.hbrBackground = null;
    wc.lpszClassName = @ptrCast(external_window_class_name.ptr);

    if (c.RegisterClassExW(&wc) == 0) {
        if (applog.isEnabled()) applog.appLog("[win] Failed to register external window class\n", .{});
        return false;
    }

    external_window_class_registered = true;
    if (applog.isEnabled()) applog.appLog("[win] Registered external window class\n", .{});
    return true;
}

/// Shared scroll wheel handling for main and external windows
fn handleMouseWheel(
    hwnd: c.HWND,
    wParam: c.WPARAM,
    lParam: c.LPARAM,
    app: *App,
    grid_id: i64,
    scroll_accum: *i16,
) void {
    // Extract scroll delta from high word of wParam
    const delta: i16 = @bitCast(@as(u16, @truncate(wParam >> 16)));
    if (delta == 0) return;

    // Use a smaller threshold for better trackpad support.
    // Standard WHEEL_DELTA is 120, but trackpads send smaller deltas.
    // Using 40 (WHEEL_DELTA/3) provides good responsiveness for both
    // trackpads and regular mice.
    const SCROLL_THRESHOLD: i16 = 40;

    // Get mouse position (in screen coordinates)
    const x_screen: i16 = @bitCast(@as(u16, @truncate(@as(usize, @bitCast(lParam)))));
    const y_screen: i16 = @bitCast(@as(u16, @truncate(@as(usize, @bitCast(lParam)) >> 16)));

    // Convert to client coordinates
    var pt: c.POINT = .{ .x = x_screen, .y = y_screen };
    _ = c.ScreenToClient(hwnd, &pt);

    // Get cell dimensions
    app.mu.lock();
    const cell_w = app.cell_w_px;
    const cell_h = app.cell_h_px;
    const linespace = app.linespace_px;
    const corep = app.corep;
    app.mu.unlock();

    // Calculate cell position (include linespace in row height)
    const row_h = cell_h + linespace;
    const col: i32 = if (cell_w > 0) @divTrunc(pt.x, @as(c.LONG, @intCast(cell_w))) else 0;
    // When ext_tabline is enabled on main window, subtract tabbar height to get content-relative Y coordinate.
    // External windows (floating windows) don't have a tabbar, so only apply offset for main window.
    const is_main_window = if (app.hwnd) |main_hwnd| hwnd == main_hwnd else false;
    const content_y: c.LONG = if (is_main_window and app.ext_tabline_enabled and app.content_hwnd == null)
        pt.y - @as(c.LONG, TablineState.TAB_BAR_HEIGHT)
    else
        pt.y;
    const row: i32 = if (row_h > 0) @divTrunc(@max(0, content_y), @as(c.LONG, @intCast(row_h))) else 0;

    // Accumulate scroll delta
    scroll_accum.* += delta;

    // Determine scroll direction
    // Positive delta = scroll up (wheel away from user)
    // Negative delta = scroll down (wheel toward user)
    const direction: [*:0]const u8 = if (scroll_accum.* > 0) "up" else "down";

    // Send scroll events for each threshold accumulated
    while (scroll_accum.* >= SCROLL_THRESHOLD or scroll_accum.* <= -SCROLL_THRESHOLD) {
        core.zonvie_core_send_mouse_scroll(corep, grid_id, row, col, direction);
        if (scroll_accum.* > 0) {
            scroll_accum.* -= SCROLL_THRESHOLD;
        } else {
            scroll_accum.* += SCROLL_THRESHOLD;
        }
    }
}

/// Get scrollbar geometry (returns knob rect and track rect in client pixels)
fn getScrollbarGeometry(app: *App, client_width: i32, client_height: i32) struct {
    track_left: f32,
    track_top: f32,
    track_right: f32,
    track_bottom: f32,
    knob_top: f32,
    knob_bottom: f32,
    is_scrollable: bool,
} {
    const corep = app.corep;
    if (corep == null) return .{
        .track_left = 0,
        .track_top = 0,
        .track_right = 0,
        .track_bottom = 0,
        .knob_top = 0,
        .knob_bottom = 0,
        .is_scrollable = false,
    };

    var vp: core.ViewportInfo = undefined;
    if (core.zonvie_core_get_viewport(corep, -1, &vp) == 0) return .{
        .track_left = 0,
        .track_top = 0,
        .track_right = 0,
        .track_bottom = 0,
        .knob_top = 0,
        .knob_bottom = 0,
        .is_scrollable = false,
    };

    const visible_lines = vp.botline - vp.topline;
    const is_scrollable = vp.line_count > visible_lines and visible_lines > 0;

    const cw: f32 = @floatFromInt(client_width);
    const ch: f32 = @floatFromInt(client_height);

    // When ext_tabline is enabled, scrollbar should start below the tabbar
    const tabbar_offset: f32 = if (app.ext_tabline_enabled and app.content_hwnd == null)
        @floatFromInt(TablineState.TAB_BAR_HEIGHT)
    else
        0;

    // Track position (right edge)
    const track_left = cw - SCROLLBAR_WIDTH - SCROLLBAR_MARGIN;
    const track_right = cw - SCROLLBAR_MARGIN;
    const track_top = SCROLLBAR_MARGIN + tabbar_offset;
    const track_bottom = ch - SCROLLBAR_MARGIN;
    const track_height = track_bottom - track_top;

    if (!is_scrollable or track_height <= 0) {
        return .{
            .track_left = track_left,
            .track_top = track_top,
            .track_right = track_right,
            .track_bottom = track_bottom,
            .knob_top = track_top,
            .knob_bottom = track_bottom,
            .is_scrollable = false,
        };
    }

    // Knob size proportional to visible portion
    const visible_f: f32 = @floatFromInt(visible_lines);
    const total_f: f32 = @floatFromInt(@max(1, vp.line_count));
    const knob_proportion = @min(1.0, visible_f / total_f);
    var knob_height = track_height * knob_proportion;
    knob_height = @max(SCROLLBAR_MIN_KNOB_HEIGHT, knob_height);

    // Knob position
    const scroll_range = total_f - visible_f;
    const scroll_pos: f32 = if (scroll_range > 0) @as(f32, @floatFromInt(vp.topline)) / scroll_range else 0;
    const knob_travel = track_height - knob_height;
    const knob_top = track_top + knob_travel * scroll_pos;
    const knob_bottom = knob_top + knob_height;

    return .{
        .track_left = track_left,
        .track_top = track_top,
        .track_right = track_right,
        .track_bottom = track_bottom,
        .knob_top = knob_top,
        .knob_bottom = knob_bottom,
        .is_scrollable = true,
    };
}

/// Scrollbar geometry result type
const ScrollbarGeometry = struct {
    track_left: f32,
    track_top: f32,
    track_right: f32,
    track_bottom: f32,
    knob_top: f32,
    knob_bottom: f32,
    is_scrollable: bool,
};

/// Get scrollbar geometry for external window (no tabbar offset)
fn getScrollbarGeometryForExternal(app: *App, grid_id: i64, client_width: i32, client_height: i32) ScrollbarGeometry {
    const corep = app.corep;
    if (corep == null) return .{
        .track_left = 0,
        .track_top = 0,
        .track_right = 0,
        .track_bottom = 0,
        .knob_top = 0,
        .knob_bottom = 0,
        .is_scrollable = false,
    };

    var vp: core.ViewportInfo = undefined;
    if (core.zonvie_core_get_viewport(corep, grid_id, &vp) == 0) return .{
        .track_left = 0,
        .track_top = 0,
        .track_right = 0,
        .track_bottom = 0,
        .knob_top = 0,
        .knob_bottom = 0,
        .is_scrollable = false,
    };

    const visible_lines = vp.botline - vp.topline;
    const is_scrollable = vp.line_count > visible_lines and visible_lines > 0;

    const cw: f32 = @floatFromInt(client_width);
    const ch: f32 = @floatFromInt(client_height);

    // Track position (right edge) - no tabbar offset for external windows
    const track_left = cw - SCROLLBAR_WIDTH - SCROLLBAR_MARGIN;
    const track_right = cw - SCROLLBAR_MARGIN;
    const track_top = SCROLLBAR_MARGIN;
    const track_bottom = ch - SCROLLBAR_MARGIN;
    const track_height = track_bottom - track_top;

    if (!is_scrollable or track_height <= 0) {
        return .{
            .track_left = track_left,
            .track_top = track_top,
            .track_right = track_right,
            .track_bottom = track_bottom,
            .knob_top = track_top,
            .knob_bottom = track_bottom,
            .is_scrollable = false,
        };
    }

    // Knob size proportional to visible portion
    const visible_f: f32 = @floatFromInt(visible_lines);
    const total_f: f32 = @floatFromInt(@max(1, vp.line_count));
    const knob_proportion = @min(1.0, visible_f / total_f);
    var knob_height = track_height * knob_proportion;
    knob_height = @max(SCROLLBAR_MIN_KNOB_HEIGHT, knob_height);

    // Knob position
    const scroll_range = total_f - visible_f;
    const scroll_pos: f32 = if (scroll_range > 0) @as(f32, @floatFromInt(vp.topline)) / scroll_range else 0;
    const knob_travel = track_height - knob_height;
    const knob_top = track_top + knob_travel * scroll_pos;
    const knob_bottom = knob_top + knob_height;

    return .{
        .track_left = track_left,
        .track_top = track_top,
        .track_right = track_right,
        .track_bottom = track_bottom,
        .knob_top = knob_top,
        .knob_bottom = knob_bottom,
        .is_scrollable = true,
    };
}

/// Generate scrollbar vertices for external window
fn generateScrollbarVerticesForExternal(
    app: *App,
    ext_win: *ExternalWindow,
    grid_id: i64,
    client_width: i32,
    client_height: i32,
    out_verts: *[12]core.Vertex,
) usize {
    if (!app.config.scrollbar.enabled) return 0;
    if (ext_win.scrollbar_alpha <= 0.001) return 0;

    const geom = getScrollbarGeometryForExternal(app, grid_id, client_width, client_height);
    if (!geom.is_scrollable and !app.config.scrollbar.isAlways()) return 0;

    const cw: f32 = @floatFromInt(client_width);
    const ch: f32 = @floatFromInt(client_height);

    // Convert to NDC (-1..1)
    const to_ndc_x = struct {
        fn f(px: f32, w: f32) f32 {
            return (px / w) * 2.0 - 1.0;
        }
    }.f;
    const to_ndc_y = struct {
        fn f(py: f32, h: f32) f32 {
            return 1.0 - (py / h) * 2.0; // Y flipped
        }
    }.f;

    const alpha = ext_win.scrollbar_alpha * app.config.scrollbar.opacity;

    // Track color
    const is_always_mode = app.config.scrollbar.isAlways();
    const track_alpha: f32 = if (is_always_mode) 1.0 else alpha * 0.5;
    const track_color = [4]f32{ 0.2, 0.2, 0.2, track_alpha };
    // Knob color
    const knob_color = [4]f32{ 0.7, 0.7, 0.7, alpha };

    // Track quad (background) - 6 vertices
    const tl = to_ndc_x(geom.track_left, cw);
    const tr = to_ndc_x(geom.track_right, cw);
    const tt = to_ndc_y(geom.track_top, ch);
    const tb = to_ndc_y(geom.track_bottom, ch);

    // Track Triangle 1
    out_verts[0] = .{ .position = .{ tl, tt }, .texCoord = .{ -1.0, 0 }, .color = track_color, .grid_id = 1, .deco_flags = 0, .deco_phase = 0 };
    out_verts[1] = .{ .position = .{ tr, tt }, .texCoord = .{ -1.0, 0 }, .color = track_color, .grid_id = 1, .deco_flags = 0, .deco_phase = 0 };
    out_verts[2] = .{ .position = .{ tl, tb }, .texCoord = .{ -1.0, 0 }, .color = track_color, .grid_id = 1, .deco_flags = 0, .deco_phase = 0 };

    // Track Triangle 2
    out_verts[3] = .{ .position = .{ tr, tt }, .texCoord = .{ -1.0, 0 }, .color = track_color, .grid_id = 1, .deco_flags = 0, .deco_phase = 0 };
    out_verts[4] = .{ .position = .{ tr, tb }, .texCoord = .{ -1.0, 0 }, .color = track_color, .grid_id = 1, .deco_flags = 0, .deco_phase = 0 };
    out_verts[5] = .{ .position = .{ tl, tb }, .texCoord = .{ -1.0, 0 }, .color = track_color, .grid_id = 1, .deco_flags = 0, .deco_phase = 0 };

    // Knob quad - 6 vertices
    const kl = to_ndc_x(geom.track_left + 1, cw); // Inset by 1px
    const kr = to_ndc_x(geom.track_right - 1, cw);
    const kt = to_ndc_y(geom.knob_top, ch);
    const kb = to_ndc_y(geom.knob_bottom, ch);

    // Knob Triangle 1
    out_verts[6] = .{ .position = .{ kl, kt }, .texCoord = .{ -1.0, 0 }, .color = knob_color, .grid_id = 1, .deco_flags = 0, .deco_phase = 0 };
    out_verts[7] = .{ .position = .{ kr, kt }, .texCoord = .{ -1.0, 0 }, .color = knob_color, .grid_id = 1, .deco_flags = 0, .deco_phase = 0 };
    out_verts[8] = .{ .position = .{ kl, kb }, .texCoord = .{ -1.0, 0 }, .color = knob_color, .grid_id = 1, .deco_flags = 0, .deco_phase = 0 };

    // Knob Triangle 2
    out_verts[9] = .{ .position = .{ kr, kt }, .texCoord = .{ -1.0, 0 }, .color = knob_color, .grid_id = 1, .deco_flags = 0, .deco_phase = 0 };
    out_verts[10] = .{ .position = .{ kr, kb }, .texCoord = .{ -1.0, 0 }, .color = knob_color, .grid_id = 1, .deco_flags = 0, .deco_phase = 0 };
    out_verts[11] = .{ .position = .{ kl, kb }, .texCoord = .{ -1.0, 0 }, .color = knob_color, .grid_id = 1, .deco_flags = 0, .deco_phase = 0 };

    return 12;
}

/// Hit test scrollbar area for external window
fn scrollbarHitTestForExternal(
    app: *App,
    grid_id: i64,
    client_width: i32,
    client_height: i32,
    mouse_x: i32,
    mouse_y: i32,
) enum { none, knob, track_above, track_below } {
    if (!app.config.scrollbar.enabled) return .none;

    const geom = getScrollbarGeometryForExternal(app, grid_id, client_width, client_height);
    if (!geom.is_scrollable) return .none;

    const mx: f32 = @floatFromInt(mouse_x);
    const my: f32 = @floatFromInt(mouse_y);

    // Check if in track area horizontally
    if (mx < geom.track_left or mx > geom.track_right) return .none;

    // Check vertical position
    if (my < geom.track_top or my > geom.track_bottom) return .none;

    if (my >= geom.knob_top and my <= geom.knob_bottom) {
        return .knob;
    } else if (my < geom.knob_top) {
        return .track_above;
    } else {
        return .track_below;
    }
}

/// Show scrollbar for external window
fn showScrollbarForExternal(hwnd: c.HWND, ext_win: *ExternalWindow) void {
    ext_win.scrollbar_visible = true;
    ext_win.scrollbar_target_alpha = 1.0;

    // Start fade animation if not already at target
    if (ext_win.scrollbar_alpha < 1.0) {
        _ = c.SetTimer(hwnd, TIMER_SCROLLBAR_FADE, SCROLLBAR_FADE_INTERVAL, null);
    }
}

/// Hide scrollbar for external window
fn hideScrollbarForExternal(hwnd: c.HWND, app: *App, ext_win: *ExternalWindow) void {
    if (app.config.scrollbar.isAlways()) return; // Never hide in always mode
    if (ext_win.scrollbar_dragging) return; // Don't hide while dragging

    ext_win.scrollbar_target_alpha = 0.0;

    // Start fade animation if not already at target
    if (ext_win.scrollbar_alpha > 0.0) {
        _ = c.SetTimer(hwnd, TIMER_SCROLLBAR_FADE, SCROLLBAR_FADE_INTERVAL, null);
    }
}

/// Page scroll for external window
fn scrollbarPageScrollForExternal(app: *App, grid_id: i64, direction: i8) void {
    const corep = app.corep orelse return;

    var vp: core.ViewportInfo = undefined;
    if (core.zonvie_core_get_viewport(corep, grid_id, &vp) == 0) return;

    const visible_lines = vp.botline - vp.topline;
    const steps = @max(1, visible_lines - 2);
    const dir_str: [*:0]const u8 = if (direction < 0) "up" else "down";

    var i: i64 = 0;
    while (i < steps) : (i += 1) {
        core.zonvie_core_send_mouse_scroll(corep, grid_id, 0, 0, dir_str);
    }
}

/// Handle scrollbar mouse down for external window
fn scrollbarMouseDownForExternal(hwnd: c.HWND, app: *App, ext_win: *ExternalWindow, grid_id: i64, mouse_x: i32, mouse_y: i32) bool {
    var client: c.RECT = undefined;
    _ = c.GetClientRect(hwnd, &client);

    const hit = scrollbarHitTestForExternal(app, grid_id, client.right, client.bottom, mouse_x, mouse_y);

    const corep = app.corep orelse return false;

    switch (hit) {
        .knob => {
            // Start dragging
            ext_win.scrollbar_dragging = true;
            ext_win.scrollbar_drag_start_y = mouse_y;

            var vp: core.ViewportInfo = undefined;
            if (core.zonvie_core_get_viewport(corep, grid_id, &vp) != 0) {
                ext_win.scrollbar_drag_start_topline = vp.topline;
            }

            _ = c.SetCapture(hwnd);
            return true;
        },
        .track_above => {
            // Page up - execute immediately and start repeat timer
            scrollbarPageScrollForExternal(app, grid_id, -1);
            ext_win.scrollbar_repeat_dir = -1;
            _ = c.SetCapture(hwnd);
            ext_win.scrollbar_repeat_timer = c.SetTimer(hwnd, TIMER_SCROLLBAR_REPEAT, SCROLLBAR_REPEAT_DELAY, null);
            showScrollbarForExternal(hwnd, ext_win);
            return true;
        },
        .track_below => {
            // Page down - execute immediately and start repeat timer
            scrollbarPageScrollForExternal(app, grid_id, 1);
            ext_win.scrollbar_repeat_dir = 1;
            _ = c.SetCapture(hwnd);
            ext_win.scrollbar_repeat_timer = c.SetTimer(hwnd, TIMER_SCROLLBAR_REPEAT, SCROLLBAR_REPEAT_DELAY, null);
            showScrollbarForExternal(hwnd, ext_win);
            return true;
        },
        .none => return false,
    }
}

/// Handle scrollbar mouse move (dragging) for external window
fn scrollbarMouseMoveForExternal(hwnd: c.HWND, app: *App, ext_win: *ExternalWindow, grid_id: i64, mouse_y: i32) void {
    if (!ext_win.scrollbar_dragging) return;

    const corep = app.corep orelse return;

    var client: c.RECT = undefined;
    _ = c.GetClientRect(hwnd, &client);

    const geom = getScrollbarGeometryForExternal(app, grid_id, client.right, client.bottom);
    if (!geom.is_scrollable) return;

    var vp: core.ViewportInfo = undefined;
    if (core.zonvie_core_get_viewport(corep, grid_id, &vp) == 0) return;

    const visible_lines = vp.botline - vp.topline;
    if (visible_lines <= 0) return;

    // Calculate knob travel range
    const track_height = geom.track_bottom - geom.track_top;
    const visible_f: f32 = @floatFromInt(visible_lines);
    const total_f: f32 = @floatFromInt(@max(1, vp.line_count));
    const knob_proportion = @min(1.0, visible_f / total_f);
    var knob_height = track_height * knob_proportion;
    knob_height = @max(SCROLLBAR_MIN_KNOB_HEIGHT, knob_height);
    const knob_travel = track_height - knob_height;
    if (knob_travel <= 0) return;

    // Calculate target topline from mouse position relative to track
    const mouse_in_track: f32 = @as(f32, @floatFromInt(mouse_y)) - geom.track_top - knob_height / 2.0;
    const scroll_ratio = @max(0.0, @min(1.0, mouse_in_track / knob_travel));

    // scroll_range is max topline value (0-based: 0 to line_count - visible_lines)
    const scroll_range = @max(0, vp.line_count - visible_lines);
    const target_topline_0based: i64 = @intFromFloat(scroll_ratio * @as(f32, @floatFromInt(scroll_range)));

    // 1-based topline for Neovim
    const target_topline_1based: i64 = target_topline_0based + 1;

    // Determine scroll mode: top half uses zt (top), bottom half uses zb (bottom)
    const use_bottom = scroll_ratio >= 0.5;
    const target_line: i64 = if (use_bottom) blk: {
        const bottom_line = target_topline_1based + visible_lines - 1;
        break :blk @min(bottom_line, vp.line_count);
    } else target_topline_1based;

    // Always store pending position
    ext_win.scrollbar_pending_line = target_line;
    ext_win.scrollbar_pending_use_bottom = use_bottom;

    // Throttle: only send RPC if enough time has passed
    const now: i64 = @intCast(c.GetTickCount64());
    if (now - ext_win.scrollbar_last_update < SCROLLBAR_THROTTLE_MS) return;
    ext_win.scrollbar_last_update = now;

    // Send scroll command to Neovim
    core.zonvie_core_scroll_to_line(corep, target_line, use_bottom);

    ext_win.scrollbar_pending_line = -1;
}

/// Handle scrollbar mouse up for external window
fn scrollbarMouseUpForExternal(hwnd: c.HWND, app: *App, ext_win: *ExternalWindow, _: i64) void {
    if (ext_win.scrollbar_dragging) {
        ext_win.scrollbar_dragging = false;
        _ = c.ReleaseCapture();

        // Flush any pending scroll on mouse up
        if (ext_win.scrollbar_pending_line >= 0) {
            if (app.corep) |corep| {
                core.zonvie_core_scroll_to_line(corep, ext_win.scrollbar_pending_line, ext_win.scrollbar_pending_use_bottom);
            }
            ext_win.scrollbar_pending_line = -1;
        }
    }

    if (ext_win.scrollbar_repeat_timer != 0) {
        _ = c.KillTimer(hwnd, TIMER_SCROLLBAR_REPEAT);
        ext_win.scrollbar_repeat_timer = 0;
        ext_win.scrollbar_repeat_dir = 0;
        _ = c.ReleaseCapture();
    }
}

/// Update scrollbar fade animation for external window
fn updateScrollbarFadeForExternal(hwnd: c.HWND, _: *App, ext_win: *ExternalWindow) void {
    const delta: f32 = 0.1; // Fade step
    var changed = false;

    if (ext_win.scrollbar_alpha < ext_win.scrollbar_target_alpha) {
        ext_win.scrollbar_alpha = @min(ext_win.scrollbar_target_alpha, ext_win.scrollbar_alpha + delta);
        changed = true;
    } else if (ext_win.scrollbar_alpha > ext_win.scrollbar_target_alpha) {
        ext_win.scrollbar_alpha = @max(ext_win.scrollbar_target_alpha, ext_win.scrollbar_alpha - delta);
        changed = true;
    }

    if (changed) {
        _ = c.InvalidateRect(hwnd, null, 0);
    }

    // Check if we've reached target
    if (@abs(ext_win.scrollbar_alpha - ext_win.scrollbar_target_alpha) < 0.01) {
        ext_win.scrollbar_alpha = ext_win.scrollbar_target_alpha;
        _ = c.KillTimer(hwnd, TIMER_SCROLLBAR_FADE);

        // Force full repaint when scrollbar hidden
        if (ext_win.scrollbar_alpha <= 0.0) {
            ext_win.scrollbar_visible = false;
            ext_win.needs_redraw = true;
            _ = c.InvalidateRect(hwnd, null, 0);
        }
    }
}

/// Generate scrollbar vertices for D3D11 rendering
fn generateScrollbarVertices(app: *App, client_width: i32, client_height: i32, out_verts: *[12]core.Vertex) usize {
    if (!app.config.scrollbar.enabled) return 0;
    if (app.scrollbar_alpha <= 0.001) return 0;

    const geom = getScrollbarGeometry(app, client_width, client_height);
    if (!geom.is_scrollable and !app.config.scrollbar.isAlways()) return 0;

    const cw: f32 = @floatFromInt(client_width);
    const ch: f32 = @floatFromInt(client_height);

    // Convert to NDC (-1..1)
    const to_ndc_x = struct {
        fn f(px: f32, w: f32) f32 {
            return (px / w) * 2.0 - 1.0;
        }
    }.f;
    const to_ndc_y = struct {
        fn f(py: f32, h: f32) f32 {
            return 1.0 - (py / h) * 2.0; // Y flipped
        }
    }.f;

    const alpha = app.scrollbar_alpha * app.config.scrollbar.opacity;

    // Track color: fully opaque in "always" mode to prevent ghosting, semi-transparent otherwise
    const is_always_mode = app.config.scrollbar.isAlways();
    const track_alpha: f32 = if (is_always_mode) 1.0 else alpha * 0.5;
    const track_color = [4]f32{ 0.2, 0.2, 0.2, track_alpha };
    // Knob color (light gray with alpha)
    const knob_color = [4]f32{ 0.7, 0.7, 0.7, alpha };

    // Track quad (background) - 6 vertices
    const tl = to_ndc_x(geom.track_left, cw);
    const tr = to_ndc_x(geom.track_right, cw);
    const tt = to_ndc_y(geom.track_top, ch);
    const tb = to_ndc_y(geom.track_bottom, ch);

    // Track Triangle 1
    out_verts[0] = .{ .position = .{ tl, tt }, .texCoord = .{ -1.0, 0 }, .color = track_color, .grid_id = 1, .deco_flags = 0, .deco_phase = 0 };
    out_verts[1] = .{ .position = .{ tr, tt }, .texCoord = .{ -1.0, 0 }, .color = track_color, .grid_id = 1, .deco_flags = 0, .deco_phase = 0 };
    out_verts[2] = .{ .position = .{ tl, tb }, .texCoord = .{ -1.0, 0 }, .color = track_color, .grid_id = 1, .deco_flags = 0, .deco_phase = 0 };

    // Track Triangle 2
    out_verts[3] = .{ .position = .{ tr, tt }, .texCoord = .{ -1.0, 0 }, .color = track_color, .grid_id = 1, .deco_flags = 0, .deco_phase = 0 };
    out_verts[4] = .{ .position = .{ tr, tb }, .texCoord = .{ -1.0, 0 }, .color = track_color, .grid_id = 1, .deco_flags = 0, .deco_phase = 0 };
    out_verts[5] = .{ .position = .{ tl, tb }, .texCoord = .{ -1.0, 0 }, .color = track_color, .grid_id = 1, .deco_flags = 0, .deco_phase = 0 };

    // Knob quad (2 triangles = 6 vertices)
    const kl = to_ndc_x(geom.track_left, cw);
    const kr = to_ndc_x(geom.track_right, cw);
    const kt = to_ndc_y(geom.knob_top, ch);
    const kb = to_ndc_y(geom.knob_bottom, ch);

    // Knob Triangle 1: top-left, top-right, bottom-left
    out_verts[6] = .{ .position = .{ kl, kt }, .texCoord = .{ -1.0, 0 }, .color = knob_color, .grid_id = 1, .deco_flags = 0, .deco_phase = 0 };
    out_verts[7] = .{ .position = .{ kr, kt }, .texCoord = .{ -1.0, 0 }, .color = knob_color, .grid_id = 1, .deco_flags = 0, .deco_phase = 0 };
    out_verts[8] = .{ .position = .{ kl, kb }, .texCoord = .{ -1.0, 0 }, .color = knob_color, .grid_id = 1, .deco_flags = 0, .deco_phase = 0 };

    // Knob Triangle 2: top-right, bottom-right, bottom-left
    out_verts[9] = .{ .position = .{ kr, kt }, .texCoord = .{ -1.0, 0 }, .color = knob_color, .grid_id = 1, .deco_flags = 0, .deco_phase = 0 };
    out_verts[10] = .{ .position = .{ kr, kb }, .texCoord = .{ -1.0, 0 }, .color = knob_color, .grid_id = 1, .deco_flags = 0, .deco_phase = 0 };
    out_verts[11] = .{ .position = .{ kl, kb }, .texCoord = .{ -1.0, 0 }, .color = knob_color, .grid_id = 1, .deco_flags = 0, .deco_phase = 0 };

    return 12; // 6 for track + 6 for knob
}

/// Hit test scrollbar area
fn scrollbarHitTest(app: *App, client_width: i32, client_height: i32, mouse_x: i32, mouse_y: i32) enum { none, knob, track_above, track_below } {
    if (!app.config.scrollbar.enabled) return .none;

    const geom = getScrollbarGeometry(app, client_width, client_height);
    if (!geom.is_scrollable) return .none;

    const mx: f32 = @floatFromInt(mouse_x);
    const my: f32 = @floatFromInt(mouse_y);

    // Check if in track area horizontally
    if (mx < geom.track_left or mx > geom.track_right) return .none;

    // Check vertical position
    if (my < geom.track_top or my > geom.track_bottom) return .none;

    if (my >= geom.knob_top and my <= geom.knob_bottom) {
        return .knob;
    } else if (my < geom.knob_top) {
        return .track_above;
    } else {
        return .track_below;
    }
}

/// Handle scrollbar mouse down
fn scrollbarMouseDown(hwnd: c.HWND, app: *App, mouse_x: i32, mouse_y: i32) bool {
    var client: c.RECT = undefined;
    _ = c.GetClientRect(hwnd, &client);

    const geom = getScrollbarGeometry(app, client.right, client.bottom);
    const hit = scrollbarHitTest(app, client.right, client.bottom, mouse_x, mouse_y);

    applog.appLog("[scrollbar] mouseDown x={d} y={d} client=({d},{d}) track=({d:.0},{d:.0})-({d:.0},{d:.0}) knob=({d:.0},{d:.0}) hit={s}\n", .{
        mouse_x, mouse_y, client.right, client.bottom,
        geom.track_left, geom.track_top, geom.track_right, geom.track_bottom,
        geom.knob_top, geom.knob_bottom,
        @tagName(hit),
    });

    const corep = app.corep orelse return false;

    switch (hit) {
        .knob => {
            // Start dragging
            app.scrollbar_dragging = true;
            app.scrollbar_drag_start_y = mouse_y;

            var vp: core.ViewportInfo = undefined;
            if (core.zonvie_core_get_viewport(corep, -1, &vp) != 0) {
                app.scrollbar_drag_start_topline = vp.topline;
            }

            _ = c.SetCapture(hwnd);
            return true;
        },
        .track_above => {
            // Page up - execute immediately and start repeat timer
            applog.appLog("[scrollbar] track_above: executing page scroll up\n", .{});
            scrollbarPageScroll(app, -1);
            app.scrollbar_repeat_dir = -1;
            _ = c.SetCapture(hwnd);
            app.scrollbar_repeat_timer = c.SetTimer(hwnd, TIMER_SCROLLBAR_REPEAT, SCROLLBAR_REPEAT_DELAY, null);
            showScrollbar(hwnd, app);
            return true;
        },
        .track_below => {
            // Page down - execute immediately and start repeat timer
            applog.appLog("[scrollbar] track_below: executing page scroll down\n", .{});
            scrollbarPageScroll(app, 1);
            app.scrollbar_repeat_dir = 1;
            _ = c.SetCapture(hwnd);
            app.scrollbar_repeat_timer = c.SetTimer(hwnd, TIMER_SCROLLBAR_REPEAT, SCROLLBAR_REPEAT_DELAY, null);
            showScrollbar(hwnd, app);
            return true;
        },
        .none => return false,
    }
}

/// Throttle interval for scrollbar drag (ms)
const SCROLLBAR_THROTTLE_MS: i64 = 32; // ~30fps for smooth but not excessive updates

/// Handle scrollbar mouse move (dragging)
fn scrollbarMouseMove(hwnd: c.HWND, app: *App, mouse_y: i32) void {
    if (!app.scrollbar_dragging) return;

    const corep = app.corep orelse return;

    var client: c.RECT = undefined;
    _ = c.GetClientRect(hwnd, &client);

    const geom = getScrollbarGeometry(app, client.right, client.bottom);
    if (!geom.is_scrollable) return;

    var vp: core.ViewportInfo = undefined;
    if (core.zonvie_core_get_viewport(corep, -1, &vp) == 0) return;

    const visible_lines = vp.botline - vp.topline;
    if (visible_lines <= 0) return;

    // Calculate knob travel range
    const track_height = geom.track_bottom - geom.track_top;
    const visible_f: f32 = @floatFromInt(visible_lines);
    const total_f: f32 = @floatFromInt(@max(1, vp.line_count));
    const knob_proportion = @min(1.0, visible_f / total_f);
    var knob_height = track_height * knob_proportion;
    knob_height = @max(SCROLLBAR_MIN_KNOB_HEIGHT, knob_height);
    const knob_travel = track_height - knob_height;
    if (knob_travel <= 0) return;

    // Calculate target topline from mouse position relative to track
    // mouse_y relative to track top -> position in track
    const mouse_in_track: f32 = @as(f32, @floatFromInt(mouse_y)) - geom.track_top - knob_height / 2.0;
    const scroll_ratio = @max(0.0, @min(1.0, mouse_in_track / knob_travel));

    // scroll_range is max topline value (0-based: 0 to line_count - visible_lines)
    const scroll_range = @max(0, vp.line_count - visible_lines);
    const target_topline_0based: i64 = @intFromFloat(scroll_ratio * @as(f32, @floatFromInt(scroll_range)));

    // 1-based topline for Neovim
    const target_topline_1based: i64 = target_topline_0based + 1;

    // Determine scroll mode: top half uses zt (top), bottom half uses zb (bottom)
    // This allows scrolling to the very end of the file
    const use_bottom = scroll_ratio >= 0.5;
    const target_line: i64 = if (use_bottom) blk: {
        // For bottom mode, calculate the bottom line of the viewport
        const bottom_line = target_topline_1based + visible_lines - 1;
        // Clamp to line_count
        break :blk @min(bottom_line, vp.line_count);
    } else target_topline_1based;

    // Always store pending position
    app.scrollbar_pending_line = target_line;
    app.scrollbar_pending_use_bottom = use_bottom;

    // Throttle: only send RPC if enough time has passed
    const now: i64 = @intCast(c.GetTickCount64());
    const elapsed = now - app.scrollbar_last_scroll_time;

    if (elapsed >= SCROLLBAR_THROTTLE_MS) {
        applog.appLog("[scrollbar] mouseMove y={d} ratio={d:.3} line={d} bottom={any} (sending)\n", .{
            mouse_y, scroll_ratio, target_line, use_bottom,
        });
        core.zonvie_core_scroll_to_line(corep, target_line, use_bottom);
        app.scrollbar_last_scroll_time = now;
        app.scrollbar_pending_line = -1; // Clear pending
    }
}

/// Execute page scroll in given direction (-1 = up, 1 = down)
fn scrollbarPageScroll(app: *App, direction: i8) void {
    const corep = app.corep orelse {
        applog.appLog("[scrollbar] scrollbarPageScroll: corep is null\n", .{});
        return;
    };

    var vp: core.ViewportInfo = undefined;
    if (core.zonvie_core_get_viewport(corep, -1, &vp) == 0) {
        applog.appLog("[scrollbar] scrollbarPageScroll: get_viewport failed\n", .{});
        return;
    }

    const visible_lines = vp.botline - vp.topline;
    // Scroll by one page (visible_lines - 2 for overlap)
    const page_size = @max(1, visible_lines - 2);

    applog.appLog("[scrollbar] scrollbarPageScroll: direction={d} visible={d} page_size={d} topline={d} botline={d} line_count={d}\n", .{
        direction, visible_lines, page_size, vp.topline, vp.botline, vp.line_count,
    });

    if (direction < 0) {
        // Page up: scroll to topline - page_size
        const new_topline = @max(1, vp.topline - page_size + 1);
        core.zonvie_core_scroll_to_line(corep, new_topline, false);
    } else {
        // Page down: scroll to topline + page_size
        const new_topline = @min(vp.line_count - visible_lines + 1, vp.topline + page_size + 1);
        const target_line = @max(1, new_topline);
        core.zonvie_core_scroll_to_line(corep, target_line, false);
    }
}

/// Handle scrollbar mouse up
fn scrollbarMouseUp(hwnd: c.HWND, app: *App) void {
    if (app.scrollbar_dragging) {
        // Send any pending scroll position before releasing
        if (app.scrollbar_pending_line > 0) {
            if (app.corep) |corep| {
                applog.appLog("[scrollbar] mouseUp sending pending line={d} bottom={any}\n", .{ app.scrollbar_pending_line, app.scrollbar_pending_use_bottom });
                core.zonvie_core_scroll_to_line(corep, app.scrollbar_pending_line, app.scrollbar_pending_use_bottom);
            }
            app.scrollbar_pending_line = -1;
        }
        app.scrollbar_dragging = false;
        _ = c.ReleaseCapture();
    }

    // Stop repeat timer if running
    if (app.scrollbar_repeat_timer != 0) {
        _ = c.KillTimer(hwnd, TIMER_SCROLLBAR_REPEAT);
        app.scrollbar_repeat_timer = 0;
        app.scrollbar_repeat_dir = 0;
        _ = c.ReleaseCapture();
    }
}

/// Update scrollbar state based on viewport info (called from message loop)
fn updateScrollbar(hwnd: c.HWND, app: *App) void {
    if (!app.config.scrollbar.enabled) return;

    const corep = app.corep;
    if (corep == null) return;

    // Get current viewport info
    var vp: core.ViewportInfo = undefined;
    if (core.zonvie_core_get_viewport(corep, -1, &vp) == 0) return;

    // Check if viewport changed
    const viewport_changed = vp.topline != app.last_viewport_topline or
        vp.line_count != app.last_viewport_line_count or
        vp.botline != app.last_viewport_botline or
        app.last_viewport_topline == -1;

    if (!viewport_changed) return;

    app.last_viewport_topline = vp.topline;
    app.last_viewport_line_count = vp.line_count;
    app.last_viewport_botline = vp.botline;

    const visible_lines = vp.botline - vp.topline;
    const is_scrollable = vp.line_count > visible_lines;

    if (!is_scrollable and !app.config.scrollbar.isAlways()) {
        hideScrollbar(hwnd, app);
        return;
    }

    // Show scrollbar based on mode
    if (app.config.scrollbar.isScroll() or app.config.scrollbar.isAlways()) {
        showScrollbar(hwnd, app);
    }

    // Request repaint for scrollbar area
    _ = c.InvalidateRect(hwnd, null, c.FALSE);
}

/// Show scrollbar with fade-in animation
fn showScrollbar(hwnd: c.HWND, app: *App) void {
    if (!app.config.scrollbar.enabled) return;

    app.scrollbar_visible = true;
    app.scrollbar_target_alpha = 1.0;

    // Start fade animation if not already at target
    if (app.scrollbar_alpha < 1.0) {
        _ = c.SetTimer(hwnd, TIMER_SCROLLBAR_FADE, SCROLLBAR_FADE_INTERVAL, null);
    }

    // Cancel existing hide timer
    if (app.scrollbar_hide_timer != 0) {
        _ = c.KillTimer(hwnd, TIMER_SCROLLBAR_AUTOHIDE);
        app.scrollbar_hide_timer = 0;
    }

    // Set auto-hide timer if in scroll mode and not always visible
    if (app.config.scrollbar.isScroll() and !app.config.scrollbar.isAlways()) {
        const delay_ms: c.UINT = @intFromFloat(app.config.scrollbar.delay * 1000.0);
        app.scrollbar_hide_timer = c.SetTimer(hwnd, TIMER_SCROLLBAR_AUTOHIDE, delay_ms, null);
    }
}

/// Hide scrollbar with fade-out animation
fn hideScrollbar(hwnd: c.HWND, app: *App) void {
    if (!app.config.scrollbar.enabled) return;
    if (app.config.scrollbar.isAlways()) return; // Never hide in always mode
    if (app.scrollbar_dragging) return; // Don't hide while dragging

    app.scrollbar_target_alpha = 0.0;

    // Start fade animation if not already at target
    if (app.scrollbar_alpha > 0.0) {
        _ = c.SetTimer(hwnd, TIMER_SCROLLBAR_FADE, SCROLLBAR_FADE_INTERVAL, null);
    }
}

/// Update scrollbar fade animation (called from timer)
fn updateScrollbarFade(hwnd: c.HWND, app: *App) void {
    const fade_speed: f32 = 0.15; // Alpha change per frame

    if (app.scrollbar_alpha < app.scrollbar_target_alpha) {
        app.scrollbar_alpha = @min(app.scrollbar_target_alpha, app.scrollbar_alpha + fade_speed);
    } else if (app.scrollbar_alpha > app.scrollbar_target_alpha) {
        app.scrollbar_alpha = @max(app.scrollbar_target_alpha, app.scrollbar_alpha - fade_speed);
    }

    // Stop timer when animation complete
    if (@abs(app.scrollbar_alpha - app.scrollbar_target_alpha) < 0.01) {
        app.scrollbar_alpha = app.scrollbar_target_alpha;
        _ = c.KillTimer(hwnd, TIMER_SCROLLBAR_FADE);

        if (app.scrollbar_alpha <= 0.0) {
            app.scrollbar_visible = false;
            // Force full repaint to clear the scrollbar area from the back buffer.
            // This is necessary because the scrollbar may overlap the gutter area
            // (outside the grid), which is not redrawn by row updates.
            app.need_full_seed.store(true, .seq_cst);
        }
    }

    // Request repaint
    _ = c.InvalidateRect(hwnd, null, c.FALSE);
}

// ============================================================================
// Cursor Blink Functions
// ============================================================================

/// Start cursor blinking with specified timing
fn startCursorBlinking(hwnd: c.HWND, app: *App, wait_ms: u32, on_ms: u32, off_ms: u32) void {
    // Stop any existing timer
    stopCursorBlinking(hwnd, app);

    // Don't blink if on_ms is 0
    if (on_ms == 0) {
        applog.appLog("[blink] on_ms=0, not blinking\n", .{});
        return;
    }

    app.cursor_blink_wait_ms = wait_ms;
    app.cursor_blink_on_ms = on_ms;
    app.cursor_blink_off_ms = off_ms;

    // Start with wait phase if wait_ms > 0
    if (wait_ms > 0) {
        applog.appLog("[blink] starting with wait_ms={d}\n", .{wait_ms});
        app.cursor_blink_phase = 0;
        app.cursor_blink_state = true;
        const timer_result = c.SetTimer(hwnd, TIMER_CURSOR_BLINK, wait_ms, null);
        applog.appLog("[blink] SetTimer result={d}\n", .{timer_result});
        app.cursor_blink_timer = timer_result;
    } else {
        // No wait, start blinking immediately
        enterBlinkCycle(hwnd, app);
    }
}

/// Enter the on/off blink cycle
fn enterBlinkCycle(hwnd: c.HWND, app: *App) void {
    applog.appLog("[blink] enterBlinkCycle\n", .{});
    app.cursor_blink_phase = 1;
    app.cursor_blink_state = true;
    scheduleNextBlink(hwnd, app, true);
    // Request repaint
    _ = c.InvalidateRect(hwnd, null, c.FALSE);
}

/// Schedule the next blink state change
fn scheduleNextBlink(hwnd: c.HWND, app: *App, is_currently_on: bool) void {
    const interval = if (is_currently_on) app.cursor_blink_on_ms else app.cursor_blink_off_ms;

    if (interval == 0) {
        applog.appLog("[blink] interval=0, stopping\n", .{});
        return;
    }

    applog.appLog("[blink] scheduleNextBlink: is_on={} interval={d}ms\n", .{ is_currently_on, interval });
    app.cursor_blink_timer = c.SetTimer(hwnd, TIMER_CURSOR_BLINK, interval, null);
}

/// Handle cursor blink timer event
fn handleCursorBlinkTimer(hwnd: c.HWND, app: *App) void {
    _ = c.KillTimer(hwnd, TIMER_CURSOR_BLINK);
    app.cursor_blink_timer = 0;

    if (app.cursor_blink_phase == 0) {
        // Wait phase complete, enter blink cycle
        enterBlinkCycle(hwnd, app);
    } else {
        // Toggle blink state
        app.cursor_blink_state = !app.cursor_blink_state;
        applog.appLog("[blink] toggled to {}\n", .{app.cursor_blink_state});

        // Update external windows blink state
        updateExternalWindowsBlinkState(app);

        // Request repaint for cursor area
        if (app.last_cursor_rect_px) |rect| {
            _ = c.InvalidateRect(hwnd, &rect, c.FALSE);
        } else {
            _ = c.InvalidateRect(hwnd, null, c.FALSE);
        }

        // Schedule next blink
        scheduleNextBlink(hwnd, app, app.cursor_blink_state);
    }
}

/// Stop cursor blinking
fn stopCursorBlinking(hwnd: c.HWND, app: *App) void {
    if (app.cursor_blink_timer != 0) {
        _ = c.KillTimer(hwnd, TIMER_CURSOR_BLINK);
        app.cursor_blink_timer = 0;
    }
    app.cursor_blink_phase = 0;
    app.cursor_blink_state = true;

    // Update external windows blink state (cursor visible)
    updateExternalWindowsBlinkState(app);
}

/// Update cursor blinking based on current cursor settings from core
fn updateCursorBlinking(hwnd: c.HWND, app: *App) void {
    var wait_ms: u32 = 0;
    var on_ms: u32 = 0;
    var off_ms: u32 = 0;

    if (app.corep) |core_ptr| {
        core.zonvie_core_get_cursor_blink(core_ptr, &wait_ms, &on_ms, &off_ms);
    }

    applog.appLog("[blink] updateCursorBlinking: wait={d} on={d} off={d} (current: wait={d} on={d} off={d})\n", .{ wait_ms, on_ms, off_ms, app.cursor_blink_wait_ms, app.cursor_blink_on_ms, app.cursor_blink_off_ms });

    // Check if blink settings changed
    const settings_changed = wait_ms != app.cursor_blink_wait_ms or
        on_ms != app.cursor_blink_on_ms or
        off_ms != app.cursor_blink_off_ms;

    // Check if timer is currently stopped
    const timer_stopped = app.cursor_blink_timer == 0;

    applog.appLog("[blink] settings_changed={}, on_ms>0={}, off_ms>0={}, timer_stopped={}\n", .{ settings_changed, on_ms > 0, off_ms > 0, timer_stopped });

    if (on_ms > 0 and off_ms > 0) {
        // Blink should be enabled
        if (settings_changed or timer_stopped) {
            // Start/restart if settings changed OR timer was stopped (e.g., after mode change to non-blinking mode)
            applog.appLog("[blink] calling startCursorBlinking\n", .{});
            startCursorBlinking(hwnd, app, wait_ms, on_ms, off_ms);
        }
    } else {
        // Blink should be disabled
        if (settings_changed) {
            applog.appLog("[blink] calling stopCursorBlinking\n", .{});
            stopCursorBlinking(hwnd, app);
        }
    }
}

/// Update blink state for all external windows
fn updateExternalWindowsBlinkState(app: *App) void {
    var it = app.external_windows.iterator();
    while (it.next()) |entry| {
        const ext_win = entry.value_ptr;
        ext_win.cursor_blink_state = app.cursor_blink_state;
        if (ext_win.hwnd) |ext_hwnd| {
            _ = c.InvalidateRect(ext_hwnd, null, c.FALSE);
        }
    }
}

/// WndProc for external windows (simpler than main window)
export fn ExternalWndProc(
    hwnd: c.HWND,
    msg: c.UINT,
    wParam: c.WPARAM,
    lParam: c.LPARAM,
) callconv(.winapi) c.LRESULT {
    switch (msg) {
        c.WM_PAINT => {
            if (applog.isEnabled()) applog.appLog("[win] ExternalWndProc WM_PAINT hwnd={*}\n", .{hwnd});
            if (getApp(hwnd)) |app| {
                // Check if this is the message window
                if (app.message_window) |msg_win| {
                    if (msg_win.hwnd == hwnd) {
                        if (applog.isEnabled()) applog.appLog("[win] ExternalWndProc calling paintMessageWindow\n", .{});
                        paintMessageWindow(hwnd, app);
                        return 0;
                    }
                }
                // Check if this is a mini window
                inline for ([_]MiniWindowId{ .showmode, .showcmd, .ruler }) |id| {
                    const idx = @intFromEnum(id);
                    if (app.mini_windows[idx].hwnd) |mini_hwnd| {
                        if (mini_hwnd == hwnd) {
                            if (applog.isEnabled()) applog.appLog("[win] ExternalWndProc calling paintMiniWindow for {s}\n", .{@tagName(id)});
                            paintMiniWindow(hwnd, app);
                            return 0;
                        }
                    }
                }
                if (applog.isEnabled()) applog.appLog("[win] ExternalWndProc calling paintExternalWindow\n", .{});
                paintExternalWindow(hwnd, app);
            } else {
                if (applog.isEnabled()) applog.appLog("[win] ExternalWndProc getApp returned null\n", .{});
                // Must call BeginPaint/EndPaint even if we don't draw
                var ps: c.PAINTSTRUCT = undefined;
                _ = c.BeginPaint(hwnd, &ps);
                _ = c.EndPaint(hwnd, &ps);
            }
            return 0;
        },
        c.WM_CLOSE => {
            // Don't destroy - just hide or let the core handle it
            _ = c.ShowWindow(hwnd, c.SW_HIDE);
            return 0;
        },
        c.WM_DESTROY => {
            // Clear userdata
            _ = c.SetWindowLongPtrW(hwnd, c.GWLP_USERDATA, 0);
            return 0;
        },
        // Forward keyboard input to core (same as main window)
        c.WM_KEYDOWN, c.WM_SYSKEYDOWN => {
            if (getApp(hwnd)) |app| {
                const vk: u32 = @intCast(wParam);
                const mods = queryMods();
                const keycode: u32 = KEYCODE_WINVK_FLAG | vk;
                const scancode: u32 = @intCast((@as(u32, @intCast(lParam)) >> 16) & 0xFF);

                // Check if IME is composing
                app.mu.lock();
                const ime_composing = app.ime_composing;
                app.mu.unlock();

                // Skip VK_RETURN and VK_BACK when IME is composing to avoid double-input
                if (ime_composing and (vk == c.VK_RETURN or vk == c.VK_BACK)) {
                    // Let IME handle Enter/Backspace
                    return c.DefWindowProcW(hwnd, msg, wParam, lParam);
                }

                // Special keys (arrows, function keys, etc.) go through send_key_event
                if (isSpecialVk(vk)) {
                    sendKeyEventToCore(app, keycode, mods, null, null);
                    return 0;
                }

                // Ctrl/Alt combos: use toUnicodePairUtf8 to get character for <C-x> etc.
                if ((mods & (MOD_CTRL | MOD_ALT)) != 0) {
                    var tmp_chars: [16]u16 = undefined;
                    var tmp_ign: [16]u16 = undefined;
                    var out_chars: [8]u8 = undefined;
                    var out_ign: [8]u8 = undefined;

                    const pair = toUnicodePairUtf8(
                        vk, scancode,
                        &tmp_chars, &tmp_ign,
                        &out_chars, &out_ign,
                    );

                    sendKeyEventToCore(app, keycode, mods, pair.chars, pair.ign);
                    return 0;
                }
                // Otherwise let WM_CHAR handle normal text
            }
        },
        c.WM_CHAR, c.WM_SYSCHAR => {
            if (getApp(hwnd)) |app| {
                const mods = queryMods();

                // Skip if Ctrl/Alt (handled in WM_KEYDOWN)
                if ((mods & (MOD_CTRL | MOD_ALT)) != 0) {
                    return 0;
                }

                const ch0: u16 = @as(u16, @intCast(wParam));

                // Skip control characters handled by WM_KEYDOWN
                if (ch0 == 0x08 or ch0 == 0x09 or ch0 == 0x0D or ch0 == 0x1B) {
                    return 0;
                }

                // Skip surrogates for now
                if (ch0 >= 0xD800 and ch0 <= 0xDFFF) {
                    return 0;
                }

                var tmp: [8]u8 = undefined;
                if (utf16UnitsToUtf8(&tmp, ch0, null)) |s| {
                    sendKeyEventToCore(app, 0, mods, s, null);
                }
                return 0;
            }
        },
        c.WM_SIZE => {
            if (getApp(hwnd)) |app| {
                // Get new client area size
                var rc: c.RECT = undefined;
                _ = c.GetClientRect(hwnd, &rc);
                const client_w: u32 = @intCast(rc.right - rc.left);
                const client_h: u32 = @intCast(rc.bottom - rc.top);

                if (client_w == 0 or client_h == 0) {
                    return 0;
                }

                app.mu.lock();

                // Find grid_id for this hwnd
                var grid_id: ?i64 = null;
                var it = app.external_windows.iterator();
                while (it.next()) |entry| {
                    if (entry.value_ptr.hwnd == hwnd) {
                        grid_id = entry.key_ptr.*;
                        break;
                    }
                }

                const cell_w = app.cell_w_px;
                const cell_h = app.cell_h_px + app.linespace_px;
                const corep = app.corep;

                app.mu.unlock();

                if (grid_id) |gid| {
                    if (cell_w > 0 and cell_h > 0) {
                        const new_cols: u32 = client_w / cell_w;
                        const new_rows: u32 = client_h / cell_h;

                        if (new_rows > 0 and new_cols > 0) {
                            if (applog.isEnabled()) applog.appLog("[win] external WM_SIZE grid_id={d} client=({d},{d}) cell=({d},{d}) -> rows={d} cols={d}\n", .{
                                gid, client_w, client_h, cell_w, cell_h, new_rows, new_cols,
                            });
                            core.zonvie_core_try_resize_grid(corep, gid, new_rows, new_cols);
                        }
                    }
                }
            }
            return 0;
        },
        c.WM_MOUSEWHEEL => {
            if (getApp(hwnd)) |app| {
                // Find grid_id and ext_window for this hwnd
                app.mu.lock();
                var grid_id: ?i64 = null;
                var ext_window: ?*ExternalWindow = null;
                var it = app.external_windows.iterator();
                while (it.next()) |entry| {
                    if (entry.value_ptr.hwnd == hwnd) {
                        grid_id = entry.key_ptr.*;
                        ext_window = entry.value_ptr;
                        break;
                    }
                }
                app.mu.unlock();

                if (grid_id != null and ext_window != null) {
                    handleMouseWheel(hwnd, wParam, lParam, app, grid_id.?, &ext_window.?.scroll_accum);

                    // Show scrollbar on scroll if in scroll mode
                    if (app.config.scrollbar.enabled and app.config.scrollbar.isScroll()) {
                        showScrollbarForExternal(hwnd, ext_window.?);
                        // Auto-hide after delay
                        const delay_ms: c.UINT = @intFromFloat(app.config.scrollbar.delay * 1000.0);
                        _ = c.SetTimer(hwnd, TIMER_SCROLLBAR_AUTOHIDE, delay_ms, null);
                    }
                }
                return 0;
            }
        },

        // --- Scrollbar mouse handling for external windows ---
        c.WM_LBUTTONDOWN => {
            if (getApp(hwnd)) |app| {
                const x: i32 = @bitCast(@as(u32, @intCast(lParam & 0xFFFF)));
                const y: i32 = @bitCast(@as(u32, @intCast((lParam >> 16) & 0xFFFF)));

                app.mu.lock();
                var grid_id: ?i64 = null;
                var ext_window: ?*ExternalWindow = null;
                var it = app.external_windows.iterator();
                while (it.next()) |entry| {
                    if (entry.value_ptr.hwnd == hwnd) {
                        grid_id = entry.key_ptr.*;
                        ext_window = entry.value_ptr;
                        break;
                    }
                }
                app.mu.unlock();

                if (grid_id != null and ext_window != null) {
                    if (scrollbarMouseDownForExternal(hwnd, app, ext_window.?, grid_id.?, x, y)) {
                        return 0;
                    }
                }
            }
        },

        c.WM_LBUTTONUP => {
            if (getApp(hwnd)) |app| {
                app.mu.lock();
                var grid_id: ?i64 = null;
                var ext_window: ?*ExternalWindow = null;
                var it = app.external_windows.iterator();
                while (it.next()) |entry| {
                    if (entry.value_ptr.hwnd == hwnd) {
                        grid_id = entry.key_ptr.*;
                        ext_window = entry.value_ptr;
                        break;
                    }
                }
                app.mu.unlock();

                if (grid_id != null and ext_window != null) {
                    scrollbarMouseUpForExternal(hwnd, app, ext_window.?, grid_id.?);
                }
            }
        },

        c.WM_MOUSEMOVE => {
            if (getApp(hwnd)) |app| {
                const x: i32 = @bitCast(@as(u32, @intCast(lParam & 0xFFFF)));
                const y: i32 = @bitCast(@as(u32, @intCast((lParam >> 16) & 0xFFFF)));

                app.mu.lock();
                var grid_id: ?i64 = null;
                var ext_window: ?*ExternalWindow = null;
                var it = app.external_windows.iterator();
                while (it.next()) |entry| {
                    if (entry.value_ptr.hwnd == hwnd) {
                        grid_id = entry.key_ptr.*;
                        ext_window = entry.value_ptr;
                        break;
                    }
                }
                app.mu.unlock();

                if (grid_id != null and ext_window != null) {
                    const ext_win = ext_window.?;

                    // Handle scrollbar dragging
                    if (ext_win.scrollbar_dragging) {
                        scrollbarMouseMoveForExternal(hwnd, app, ext_win, grid_id.?, y);
                        return 0;
                    }

                    // Check for scrollbar hover
                    if (app.config.scrollbar.enabled and app.config.scrollbar.isHover()) {
                        var client: c.RECT = undefined;
                        _ = c.GetClientRect(hwnd, &client);
                        const hit = scrollbarHitTestForExternal(app, grid_id.?, client.right, client.bottom, x, y);
                        if (hit != .none) {
                            if (!ext_win.scrollbar_hover) {
                                ext_win.scrollbar_hover = true;
                                showScrollbarForExternal(hwnd, ext_win);
                            }
                        } else {
                            if (ext_win.scrollbar_hover) {
                                ext_win.scrollbar_hover = false;
                                hideScrollbarForExternal(hwnd, app, ext_win);
                            }
                        }
                    }

                    // Track mouse for WM_MOUSELEAVE
                    var tme: c.TRACKMOUSEEVENT = .{
                        .cbSize = @sizeOf(c.TRACKMOUSEEVENT),
                        .dwFlags = c.TME_LEAVE,
                        .hwndTrack = hwnd,
                        .dwHoverTime = 0,
                    };
                    _ = c.TrackMouseEvent(&tme);
                }
            }
        },

        c.WM_MOUSELEAVE => {
            if (getApp(hwnd)) |app| {
                app.mu.lock();
                var ext_window: ?*ExternalWindow = null;
                var it = app.external_windows.iterator();
                while (it.next()) |entry| {
                    if (entry.value_ptr.hwnd == hwnd) {
                        ext_window = entry.value_ptr;
                        break;
                    }
                }
                app.mu.unlock();

                if (ext_window) |ext_win| {
                    ext_win.scrollbar_hover = false;
                    hideScrollbarForExternal(hwnd, app, ext_win);
                }
            }
        },

        c.WM_TIMER => {
            if (getApp(hwnd)) |app| {
                const timer_id = wParam;

                app.mu.lock();
                var grid_id: ?i64 = null;
                var ext_window: ?*ExternalWindow = null;
                var it = app.external_windows.iterator();
                while (it.next()) |entry| {
                    if (entry.value_ptr.hwnd == hwnd) {
                        grid_id = entry.key_ptr.*;
                        ext_window = entry.value_ptr;
                        break;
                    }
                }
                app.mu.unlock();

                if (ext_window) |ext_win| {
                    if (timer_id == TIMER_SCROLLBAR_FADE) {
                        updateScrollbarFadeForExternal(hwnd, app, ext_win);
                        return 0;
                    } else if (timer_id == TIMER_SCROLLBAR_REPEAT) {
                        if (grid_id != null and ext_win.scrollbar_repeat_dir != 0) {
                            // Change to faster interval after first fire
                            if (ext_win.scrollbar_repeat_timer != 0) {
                                _ = c.KillTimer(hwnd, TIMER_SCROLLBAR_REPEAT);
                                ext_win.scrollbar_repeat_timer = c.SetTimer(hwnd, TIMER_SCROLLBAR_REPEAT, SCROLLBAR_REPEAT_INTERVAL, null);
                            }
                            scrollbarPageScrollForExternal(app, grid_id.?, ext_win.scrollbar_repeat_dir);
                        }
                        return 0;
                    } else if (timer_id == TIMER_SCROLLBAR_AUTOHIDE) {
                        // Auto-hide scrollbar after scroll mode timeout
                        _ = c.KillTimer(hwnd, TIMER_SCROLLBAR_AUTOHIDE);
                        hideScrollbarForExternal(hwnd, app, ext_win);
                        return 0;
                    }
                }
            }
        },

        // --- IME message handling for external windows ---
        c.WM_IME_STARTCOMPOSITION => {
            if (applog.isEnabled()) applog.appLog("[IME][ext] WM_IME_STARTCOMPOSITION hwnd={*}\n", .{hwnd});
            if (getApp(hwnd)) |app| {
                app.mu.lock();
                app.ime_composing = true;
                app.ime_composition_str.clearRetainingCapacity();
                app.ime_composition_utf8.clearRetainingCapacity();
                app.ime_clause_info.clearRetainingCapacity();
                app.ime_cursor_pos = 0;
                app.ime_target_start = 0;
                app.ime_target_end = 0;
                app.mu.unlock();

                // Position IME candidate window at cursor (using this external window)
                positionImeCandidateWindow(hwnd, app);

                // Trigger redraw to hide cursor during IME composition
                _ = c.InvalidateRect(hwnd, null, 0);
            }
            return 0;
        },

        c.WM_IME_COMPOSITION => {
            if (applog.isEnabled()) applog.appLog("[IME][ext] WM_IME_COMPOSITION lParam=0x{x}\n", .{@as(u32, @intCast(lParam & 0xFFFFFFFF))});
            if (getApp(hwnd)) |app| {
                const himc = c.ImmGetContext(hwnd);
                if (himc != null) {
                    defer _ = c.ImmReleaseContext(hwnd, himc);

                    app.mu.lock();
                    defer app.mu.unlock();

                    // Get composition string
                    if ((lParam & c.GCS_COMPSTR) != 0) {
                        const byte_len = c.ImmGetCompositionStringW(himc, c.GCS_COMPSTR, null, 0);
                        if (byte_len > 0) {
                            const char_len: usize = @intCast(@divTrunc(byte_len, 2));
                            app.ime_composition_str.resize(app.alloc, char_len) catch {
                                return c.DefWindowProcW(hwnd, msg, wParam, lParam);
                            };
                            _ = c.ImmGetCompositionStringW(himc, c.GCS_COMPSTR, app.ime_composition_str.items.ptr, @intCast(byte_len));
                            updateImeCompositionUtf8(app);
                        } else {
                            app.ime_composition_str.clearRetainingCapacity();
                            app.ime_composition_utf8.clearRetainingCapacity();
                        }
                    }

                    // Get clause info
                    if ((lParam & c.GCS_COMPCLAUSE) != 0) {
                        const clause_byte_len = c.ImmGetCompositionStringW(himc, c.GCS_COMPCLAUSE, null, 0);
                        if (clause_byte_len > 0) {
                            const clause_count: usize = @intCast(@divTrunc(clause_byte_len, 4));
                            app.ime_clause_info.resize(app.alloc, clause_count) catch {
                                return c.DefWindowProcW(hwnd, msg, wParam, lParam);
                            };
                            _ = c.ImmGetCompositionStringW(himc, c.GCS_COMPCLAUSE, app.ime_clause_info.items.ptr, @intCast(clause_byte_len));
                        }
                    }

                    // Get cursor position
                    if ((lParam & c.GCS_CURSORPOS) != 0) {
                        const cursor_pos = c.ImmGetCompositionStringW(himc, c.GCS_CURSORPOS, null, 0);
                        if (cursor_pos >= 0) app.ime_cursor_pos = @intCast(@max(0, cursor_pos));
                    }

                    // Get target clause (same logic as main window)
                    // Always try to get COMPATTR, not just when flag is set
                    {
                        const attr_len = c.ImmGetCompositionStringW(himc, c.GCS_COMPATTR, null, 0);
                        if (attr_len > 0) {
                            var attr_buf: [256]u8 = undefined;
                            const len: usize = @intCast(@min(@as(usize, @intCast(@max(0, attr_len))), 256));
                            _ = c.ImmGetCompositionStringW(himc, c.GCS_COMPATTR, &attr_buf, @intCast(len));

                            // Find target clause (ATTR_TARGET_CONVERTED=0x01 or ATTR_TARGET_NOTCONVERTED=0x03)
                            app.ime_target_start = 0;
                            app.ime_target_end = 0;
                            var found_start: bool = false;
                            var i: u32 = 0;
                            while (i < len) : (i += 1) {
                                const attr = attr_buf[i];
                                if (attr == 0x01 or attr == 0x03) {
                                    if (!found_start) {
                                        app.ime_target_start = i;
                                        found_start = true;
                                    }
                                    app.ime_target_end = i + 1;
                                }
                            }
                        }
                    }
                }

                // Update preedit overlay
                updateImePreeditOverlay(hwnd, app);
            }
            // Let DefWindowProc handle for default IME processing
            return c.DefWindowProcW(hwnd, msg, wParam, lParam);
        },

        c.WM_IME_ENDCOMPOSITION => {
            if (applog.isEnabled()) applog.appLog("[IME][ext] WM_IME_ENDCOMPOSITION hwnd={*}\n", .{hwnd});
            if (getApp(hwnd)) |app| {
                app.mu.lock();
                app.ime_composing = false;
                app.ime_composition_str.clearRetainingCapacity();
                app.ime_composition_utf8.clearRetainingCapacity();
                app.ime_clause_info.clearRetainingCapacity();
                app.ime_cursor_pos = 0;
                app.ime_target_start = 0;
                app.ime_target_end = 0;
                app.mu.unlock();

                // Hide overlay
                hideImePreeditOverlay(app);

                // Trigger redraw to show cursor after IME composition ends
                _ = c.InvalidateRect(hwnd, null, 0);
            }
            return 0;
        },

        c.WM_IME_CHAR => {
            // IME committed character - send to Neovim
            if (applog.isEnabled()) applog.appLog("[IME][ext] WM_IME_CHAR wParam=0x{x}\n", .{wParam});
            if (getApp(hwnd)) |app| {
                const ch: u16 = @intCast(wParam);

                // Skip surrogate pairs for now
                if (ch >= 0xD800 and ch <= 0xDFFF) {
                    return 0;
                }

                var out: [8]u8 = undefined;
                const s = utf16UnitsToUtf8(&out, ch, null) orelse return 0;

                sendKeyEventToCore(app, 0, 0, s, s);
                return 0;
            }
        },

        c.WM_SETFOCUS => {
            // Post message to update IME position asynchronously
            // This avoids deadlock when WM_SETFOCUS is triggered while app.mu is held
            // (e.g., during closeExternalWindowOnUIThread destroying a window)
            _ = c.PostMessageW(hwnd, WM_APP_UPDATE_IME_POSITION, 0, 0);
        },

        WM_APP_UPDATE_IME_POSITION => {
            if (getApp(hwnd)) |app| {
                positionImeCandidateWindow(hwnd, app);
            }
        },

        // Enable drag-to-move for cmdline window (entire window acts as title bar)
        c.WM_NCHITTEST => {
            if (getApp(hwnd)) |app| {
                app.mu.lock();
                defer app.mu.unlock();

                // Check if this is the cmdline window
                if (app.external_windows.get(CMDLINE_GRID_ID)) |cw| {
                    if (cw.hwnd == hwnd) {
                        // Return HTCAPTION to make entire window draggable
                        return c.HTCAPTION;
                    }
                }
            }
            // For other windows, use default behavior
            return c.DefWindowProcW(hwnd, msg, wParam, lParam);
        },

        // Save cmdline window position when moved
        c.WM_MOVE => {
            if (getApp(hwnd)) |app| {
                app.mu.lock();
                defer app.mu.unlock();

                // Check if this is the cmdline window
                if (app.external_windows.get(CMDLINE_GRID_ID)) |cw| {
                    if (cw.hwnd == hwnd) {
                        // Get new window position
                        var rect: c.RECT = undefined;
                        if (c.GetWindowRect(hwnd, &rect) != 0) {
                            app.cmdline_saved_x = rect.left;
                            app.cmdline_saved_y = rect.top;
                            if (applog.isEnabled()) applog.appLog("[win] cmdline position saved: ({d},{d})\n", .{ rect.left, rect.top });
                        }
                    }
                }
            }
            return 0;
        },

        else => {},
    }
    return c.DefWindowProcW(hwnd, msg, wParam, lParam);
}

/// Paint message window using GDI
fn paintMessageWindow(hwnd: c.HWND, app: *App) void {
    if (applog.isEnabled()) applog.appLog("[win] paintMessageWindow start\n", .{});
    var ps: c.PAINTSTRUCT = undefined;
    const hdc = c.BeginPaint(hwnd, &ps);
    defer _ = c.EndPaint(hwnd, &ps);

    const msg_win = app.message_window orelse {
        if (applog.isEnabled()) applog.appLog("[win] paintMessageWindow: no message window\n", .{});
        return;
    };

    // Get window size
    var rect: c.RECT = undefined;
    _ = c.GetClientRect(hwnd, &rect);

    // Get colors from Normal highlight
    var bg_rgb: c.COLORREF = c.RGB(38, 38, 46); // Default dark background
    var fg_rgb: c.COLORREF = c.RGB(255, 255, 255); // Default white text
    if (app.corep) |corep| {
        var fg: u32 = 0;
        var bg: u32 = 0;
        const found = core.zonvie_core_get_hl_by_name(corep, "Normal", &fg, &bg);
        if (found != 0) {
            if (bg != 0) {
                // Apply brightness adjustment
                var r = @as(u8, @intCast((bg >> 16) & 0xFF));
                var g = @as(u8, @intCast((bg >> 8) & 0xFF));
                var b = @as(u8, @intCast(bg & 0xFF));
                r = @min(255, @as(u16, r) * 13 / 10 + 12);
                g = @min(255, @as(u16, g) * 13 / 10 + 12);
                b = @min(255, @as(u16, b) * 13 / 10 + 12);
                bg_rgb = c.RGB(r, g, b);
            }
            if (fg != 0) {
                const r = @as(u8, @intCast((fg >> 16) & 0xFF));
                const g = @as(u8, @intCast((fg >> 8) & 0xFF));
                const b = @as(u8, @intCast(fg & 0xFF));
                fg_rgb = c.RGB(r, g, b);
            }
        }
    }

    // Fill background
    const bg_brush = c.CreateSolidBrush(bg_rgb);
    _ = c.FillRect(hdc, &rect, bg_brush);
    _ = c.DeleteObject(bg_brush);

    // Create font
    const cell_h = app.cell_h_px;
    const font_height: c_int = @intCast(cell_h);
    const hfont = c.CreateFontW(
        font_height,
        0,
        0,
        0,
        c.FW_NORMAL,
        0,
        0,
        0,
        c.DEFAULT_CHARSET,
        c.OUT_DEFAULT_PRECIS,
        c.CLIP_DEFAULT_PRECIS,
        c.DEFAULT_QUALITY,
        c.FIXED_PITCH | c.FF_MODERN,
        @ptrCast(&[_:0]u16{ 'C', 'o', 'n', 's', 'o', 'l', 'a', 's', 0 }),
    );
    const old_font = c.SelectObject(hdc, hfont);
    defer {
        _ = c.SelectObject(hdc, old_font);
        _ = c.DeleteObject(hfont);
    }

    // Set text colors based on message kind
    const text_color = msg_win.getTextColor();
    _ = c.SetTextColor(hdc, text_color);
    _ = c.SetBkMode(hdc, c.TRANSPARENT);

    // Convert text to UTF-16 using proper UTF-8 decoding
    var text_utf16: [4096]u16 = undefined;
    var text_utf16_len: usize = 0;
    const utf8_view = std.unicode.Utf8View.initUnchecked(msg_win.text[0..msg_win.text_len]);
    var utf8_iter = utf8_view.iterator();
    while (utf8_iter.nextCodepoint()) |codepoint| {
        if (text_utf16_len >= text_utf16.len - 1) break;
        // Handle surrogate pairs for codepoints > 0xFFFF
        if (codepoint > 0xFFFF) {
            const high = @as(u16, @intCast((codepoint - 0x10000) >> 10)) + 0xD800;
            const low = @as(u16, @intCast((codepoint - 0x10000) & 0x3FF)) + 0xDC00;
            text_utf16[text_utf16_len] = high;
            text_utf16_len += 1;
            if (text_utf16_len < text_utf16.len) {
                text_utf16[text_utf16_len] = low;
                text_utf16_len += 1;
            }
        } else {
            text_utf16[text_utf16_len] = @intCast(codepoint);
            text_utf16_len += 1;
        }
    }

    // Draw text with padding
    const padding: c_int = 12;
    var text_rect = c.RECT{
        .left = rect.left + padding,
        .top = rect.top + padding,
        .right = rect.right - padding,
        .bottom = rect.bottom - padding,
    };

    // Use different draw flags based on long mode
    const draw_flags: c.UINT = if (msg_win.is_long_mode)
        c.DT_LEFT | c.DT_TOP | c.DT_WORDBREAK
    else
        c.DT_LEFT | c.DT_VCENTER | c.DT_SINGLELINE;

    _ = c.DrawTextW(hdc, @ptrCast(&text_utf16), @intCast(text_utf16_len), &text_rect, draw_flags);

    if (applog.isEnabled()) applog.appLog("[win] paintMessageWindow done: long_mode={}\n", .{msg_win.is_long_mode});
}

/// Paint a mini window (individual showmode/showcmd/ruler)
fn paintMiniWindow(hwnd: c.HWND, app: *App) void {
    if (applog.isEnabled()) applog.appLog("[win] paintMiniWindow start\n", .{});
    var ps: c.PAINTSTRUCT = undefined;
    const hdc = c.BeginPaint(hwnd, &ps);
    defer _ = c.EndPaint(hwnd, &ps);

    // Get window size
    var rect: c.RECT = undefined;
    _ = c.GetClientRect(hwnd, &rect);

    // Find which mini window this is
    app.mu.lock();
    var text_buf: [256]u8 = undefined;
    var text_len: usize = 0;
    inline for ([_]MiniWindowId{ .showmode, .showcmd, .ruler }) |id| {
        const idx = @intFromEnum(id);
        if (app.mini_windows[idx].hwnd) |mini_hwnd| {
            if (mini_hwnd == hwnd) {
                text_len = app.mini_windows[idx].text_len;
                if (text_len > 0) {
                    @memcpy(text_buf[0..text_len], app.mini_windows[idx].text[0..text_len]);
                }
                break;
            }
        }
    }
    app.mu.unlock();

    // Get colors from Normal highlight
    var bg_rgb: c.COLORREF = c.RGB(30, 30, 38);
    var fg_rgb: c.COLORREF = c.RGB(180, 180, 180);
    if (app.corep) |corep| {
        var fg: u32 = 0;
        var bg: u32 = 0;
        const found = core.zonvie_core_get_hl_by_name(corep, "Normal", &fg, &bg);
        if (found != 0) {
            if (bg != 0) {
                // Darken background slightly for mini windows
                const r = @as(u8, @intCast((bg >> 16) & 0xFF)) / 2;
                const g = @as(u8, @intCast((bg >> 8) & 0xFF)) / 2;
                const b = @as(u8, @intCast(bg & 0xFF)) / 2;
                bg_rgb = c.RGB(r, g, b);
            }
            if (fg != 0) {
                const r = @as(u8, @intCast((fg >> 16) & 0xFF));
                const g = @as(u8, @intCast((fg >> 8) & 0xFF));
                const b = @as(u8, @intCast(fg & 0xFF));
                fg_rgb = c.RGB(r, g, b);
            }
        }
    }

    // Fill background
    const bg_brush = c.CreateSolidBrush(bg_rgb);
    _ = c.FillRect(hdc, &rect, bg_brush);
    _ = c.DeleteObject(bg_brush);

    // Create font
    const cell_h = app.cell_h_px;
    const font_height: c_int = @intCast(cell_h);
    const hfont = c.CreateFontW(
        font_height,
        0,
        0,
        0,
        c.FW_NORMAL,
        0,
        0,
        0,
        c.DEFAULT_CHARSET,
        c.OUT_DEFAULT_PRECIS,
        c.CLIP_DEFAULT_PRECIS,
        c.DEFAULT_QUALITY,
        c.FIXED_PITCH | c.FF_MODERN,
        @ptrCast(&[_:0]u16{ 'C', 'o', 'n', 's', 'o', 'l', 'a', 's', 0 }),
    );
    const old_font = c.SelectObject(hdc, hfont);
    defer {
        _ = c.SelectObject(hdc, old_font);
        _ = c.DeleteObject(hfont);
    }

    // Set text colors
    _ = c.SetTextColor(hdc, fg_rgb);
    _ = c.SetBkMode(hdc, c.TRANSPARENT);

    // Convert text to UTF-16
    var text_utf16: [256]u16 = undefined;
    var text_utf16_len: usize = 0;
    for (text_buf[0..text_len]) |byte| {
        if (text_utf16_len < text_utf16.len) {
            text_utf16[text_utf16_len] = byte;
            text_utf16_len += 1;
        }
    }

    // Draw text centered
    var text_rect = c.RECT{
        .left = rect.left + 4,
        .top = rect.top,
        .right = rect.right - 4,
        .bottom = rect.bottom,
    };

    _ = c.DrawTextW(hdc, @ptrCast(&text_utf16), @intCast(text_utf16_len), &text_rect, c.DT_CENTER | c.DT_VCENTER | c.DT_SINGLELINE);

    if (applog.isEnabled()) applog.appLog("[win] paintMiniWindow done\n", .{});
}

/// Paint an external window (simpler rendering path than main window)
fn paintExternalWindow(hwnd: c.HWND, app: *App) void {
    if (applog.isEnabled()) applog.appLog("[win] paintExternalWindow start hwnd={*}\n", .{hwnd});
    var ps: c.PAINTSTRUCT = undefined;
    _ = c.BeginPaint(hwnd, &ps);
    defer _ = c.EndPaint(hwnd, &ps);

    app.mu.lock();

    // Find the external window for this hwnd (also get grid_id)
    var ext_win_ptr: ?*ExternalWindow = null;
    var found_grid_id: i64 = 0;
    var ext_it = app.external_windows.iterator();
    while (ext_it.next()) |entry| {
        if (applog.isEnabled()) applog.appLog("[win] paintExternalWindow checking entry hwnd={*} vs {*}\n", .{ entry.value_ptr.hwnd, hwnd });
        if (entry.value_ptr.hwnd == hwnd) {
            ext_win_ptr = entry.value_ptr;
            found_grid_id = entry.key_ptr.*;
            break;
        }
    }

    const ext_win = ext_win_ptr orelse {
        app.mu.unlock();
        if (applog.isEnabled()) applog.appLog("[win] paintExternalWindow: no external window for hwnd={*}\n", .{hwnd});
        return;
    };

    const grid_id = found_grid_id;
    const is_cmdline = (grid_id == CMDLINE_GRID_ID);
    const is_popupmenu = (grid_id == POPUPMENU_GRID_ID);
    const is_msg_show = (grid_id == MESSAGE_GRID_ID);
    const is_msg_history = (grid_id == MSG_HISTORY_GRID_ID);

    if (applog.isEnabled()) applog.appLog("[win] paintExternalWindow found ext_win vert_count={d} grid_id={d} is_cmdline={} is_popupmenu={} is_msg_show={} is_msg_history={}\n", .{ ext_win.vert_count, grid_id, is_cmdline, is_popupmenu, is_msg_show, is_msg_history });

    if (ext_win.vert_count == 0) {
        app.mu.unlock();
        if (applog.isEnabled()) applog.appLog("[win] paintExternalWindow: vert_count=0, skipping\n", .{});
        return;
    }

    // Get renderer and atlas
    const gpu_ptr: ?*d3d11.Renderer = &ext_win.renderer;
    var atlas_ptr: ?*dwrite_d2d.Renderer = null;
    if (app.atlas) |*a| atlas_ptr = a;

    // Copy vertex data under lock
    const verts = ext_win.verts.items;
    const vert_count = ext_win.vert_count;
    const cursor_blink_visible = ext_win.cursor_blink_state;
    ext_win.needs_redraw = false;

    // Check if renderer resize is needed (deferred from onExternalVertices to avoid deadlock)
    const needs_resize = ext_win.needs_renderer_resize;
    if (needs_resize) {
        ext_win.needs_renderer_resize = false;
    }

    // Get cmdline firstc for icon rendering
    const cmdline_firstc = app.cmdline_firstc;

    // Check if we need to upload the full atlas (atlas version changed)
    const current_atlas_version: u64 = if (atlas_ptr) |a| a.atlas_version else 0;
    const need_full_atlas_upload = ext_win.atlas_version < current_atlas_version;
    if (need_full_atlas_upload) {
        ext_win.atlas_version = current_atlas_version;
    }

    app.mu.unlock();

    if (gpu_ptr) |g| {
        g.lockContext();
        defer g.unlockContext();

        // Perform deferred renderer resize (outside app.mu lock to avoid deadlock)
        if (needs_resize) {
            g.resize() catch |e| {
                applog.appLog("[win] paintExternalWindow deferred resize failed: {any}\n", .{e});
            };
        }

        applog.appLog("[win] paintExternalWindow drawing vert_count={d}\n", .{vert_count});

        // Upload atlas to external window's D3D context
        if (atlas_ptr) |a| {
            if (need_full_atlas_upload) {
                // First paint - upload the entire atlas
                applog.appLog("[win] paintExternalWindow uploading full atlas\n", .{});
                a.uploadFullAtlasToD3D(g);
            } else {
                // Subsequent paints - only flush pending uploads
                _ = a.flushPendingAtlasUploadsToD3D(g);
            }
        }

        if (is_cmdline) {
            // For cmdline: transform vertices to content area and add border/icon
            const window_w: f32 = @floatFromInt(g.width);
            const window_h: f32 = @floatFromInt(g.height);

            // Get content size from ext_win (need to re-lock briefly)
            app.mu.lock();
            const content_rows = ext_win.rows;
            const content_cols = ext_win.cols;
            const cell_w = app.cell_w_px;
            const cell_h = app.cell_h_px;
            const hide_cursor_for_ime = app.ime_composing;
            app.mu.unlock();

            const content_w: f32 = @floatFromInt(content_cols * cell_w);
            const content_h: f32 = @floatFromInt(content_rows * cell_h);

            if (window_w > 0 and window_h > 0 and content_w > 0 and content_h > 0) {
                // Content area position in pixels
                const content_left: f32 = @floatFromInt(CMDLINE_PADDING + CMDLINE_ICON_MARGIN_LEFT + CMDLINE_ICON_SIZE + CMDLINE_ICON_MARGIN_RIGHT);
                const content_top: f32 = @floatFromInt(CMDLINE_PADDING);

                // Convert content area bounds to NDC
                const left_ndc: f32 = content_left / window_w * 2.0 - 1.0;
                const right_ndc: f32 = (content_left + content_w) / window_w * 2.0 - 1.0;
                const top_ndc: f32 = 1.0 - content_top / window_h * 2.0;
                const bottom_ndc: f32 = 1.0 - (content_top + content_h) / window_h * 2.0;

                // Calculate scale and offset for vertex transformation
                // Original vertices are in -1.0 to 1.0 (content area)
                // New vertices should map to content area within window
                const scale_x: f32 = (right_ndc - left_ndc) / 2.0;
                const scale_y: f32 = (top_ndc - bottom_ndc) / 2.0;
                const offset_x: f32 = (right_ndc + left_ndc) / 2.0;
                const offset_y: f32 = (top_ndc + bottom_ndc) / 2.0;

                // Create transformed vertices (allocate temporary buffer)
                // Extra verts: 6 for full-window background, 24 for border (4 rects * 6 verts), 20 for icon (SDF: 12 for search, 6 for chevron)
                const extra_verts = 6 + 24 + 20;
                var cmdline_verts = app.alloc.alloc(core.Vertex, vert_count + extra_verts) catch {
                    applog.appLog("[win] paintExternalWindow: failed to alloc cmdline verts\n", .{});
                    return;
                };
                defer app.alloc.free(cmdline_verts);

                // Extract background color from first background vertex (texCoord.x < 0)
                // This matches macOS approach: use actual grid background color, not Normal highlight
                var orig_bg_r: f32 = 0.0;
                var orig_bg_g: f32 = 0.0;
                var orig_bg_b: f32 = 0.0;
                var found_bg_vertex = false;
                for (verts[0..vert_count]) |v| {
                    if (v.texCoord[0] < 0) {
                        orig_bg_r = v.color[0];
                        orig_bg_g = v.color[1];
                        orig_bg_b = v.color[2];
                        found_bg_vertex = true;
                        break;
                    }
                }

                applog.appLog("[win] cmdline bg: found={} orig=({d:.3},{d:.3},{d:.3})\n", .{ found_bg_vertex, orig_bg_r, orig_bg_g, orig_bg_b });

                // If no background vertex found, use cached color (persists across redraws)
                // This prevents color flickering when cmdline content changes
                if (!found_bg_vertex) {
                    app.mu.lock();
                    if (ext_win.cached_bg_color) |cached| {
                        orig_bg_r = cached[0];
                        orig_bg_g = cached[1];
                        orig_bg_b = cached[2];
                        applog.appLog("[win] cmdline bg: using cached=({d:.3},{d:.3},{d:.3})\n", .{ orig_bg_r, orig_bg_g, orig_bg_b });
                    }
                    app.mu.unlock();
                } else {
                    // Update cache with new background color
                    app.mu.lock();
                    ext_win.cached_bg_color = .{ orig_bg_r, orig_bg_g, orig_bg_b };
                    app.mu.unlock();
                }

                // Apply HSB adjustment for cmdline background visibility (same as macOS)
                // Dark colors become slightly lighter, light colors become slightly darker
                const adjusted = adjustBrightnessForCmdline(orig_bg_r, orig_bg_g, orig_bg_b);
                const adj_bg_r = adjusted[0];
                const adj_bg_g = adjusted[1];
                const adj_bg_b = adjusted[2];

                applog.appLog("[win] cmdline bg: adjusted=({d:.3},{d:.3},{d:.3})\n", .{ adj_bg_r, adj_bg_g, adj_bg_b });

                // First, add full-window background quad (drawn first, covers entire window)
                var bg_idx: usize = 0;
                const bg_color: [4]f32 = .{ adj_bg_r, adj_bg_g, adj_bg_b, app.config.window.opacity };
                const bg_tex: [2]f32 = .{ -1.0, -1.0 };
                bg_idx = addRectVerts(cmdline_verts, bg_idx, -1.0, 1.0, 2.0, 2.0, bg_color, bg_tex, grid_id);

                // Copy and transform original vertices after background
                // Make grid cell background vertices transparent (alpha=0) so only full-window bg shows
                // But preserve cursor vertices (marked with DECO_CURSOR flag)
                // Use tight tolerance to avoid accidentally making cursor transparent
                const tolerance: f32 = 0.005;
                for (verts[0..vert_count], 0..) |v, i| {
                    cmdline_verts[bg_idx + i] = v;
                    cmdline_verts[bg_idx + i].position[0] = v.position[0] * scale_x + offset_x;
                    cmdline_verts[bg_idx + i].position[1] = v.position[1] * scale_y + offset_y;

                    // Handle cursor vertices (marked with DECO_CURSOR flag)
                    // When IME is composing, hide cursor by setting alpha to 0
                    if ((v.deco_flags & core.DECO_CURSOR) != 0) {
                        if (hide_cursor_for_ime) {
                            cmdline_verts[bg_idx + i].color[3] = 0.0;
                        }
                        continue;
                    }

                    // Make background vertices fully transparent, but only if they match the original bg color
                    // This preserves cursor and other colored elements
                    if (v.texCoord[0] < 0) {
                        const matches_bg = @abs(v.color[0] - orig_bg_r) < tolerance and
                            @abs(v.color[1] - orig_bg_g) < tolerance and
                            @abs(v.color[2] - orig_bg_b) < tolerance;
                        if (matches_bg) {
                            cmdline_verts[bg_idx + i].color[3] = 0.0;
                        }
                    }
                }
                var extra_idx: usize = bg_idx + vert_count;

                // Get border color from core (Search highlight) or use default yellow
                var border_r: f32 = 1.0;
                var border_g: f32 = 1.0;
                var border_b: f32 = 0.0;
                if (app.corep) |corep| {
                    var fg_rgb: u32 = 0;
                    var bg_rgb: u32 = 0;
                    if (core.zonvie_core_get_hl_by_name(corep, "Search", &fg_rgb, &bg_rgb) != 0) {
                        border_r = @as(f32, @floatFromInt((bg_rgb >> 16) & 0xFF)) / 255.0;
                        border_g = @as(f32, @floatFromInt((bg_rgb >> 8) & 0xFF)) / 255.0;
                        border_b = @as(f32, @floatFromInt(bg_rgb & 0xFF)) / 255.0;
                    }
                }

                // Get icon color from core (Comment highlight) or use gray
                var icon_r: f32 = 0.5;
                var icon_g: f32 = 0.5;
                var icon_b: f32 = 0.5;
                if (app.corep) |corep| {
                    var fg_rgb: u32 = 0;
                    var bg_rgb: u32 = 0;
                    if (core.zonvie_core_get_hl_by_name(corep, "Comment", &fg_rgb, &bg_rgb) != 0) {
                        icon_r = @as(f32, @floatFromInt((fg_rgb >> 16) & 0xFF)) / 255.0;
                        icon_g = @as(f32, @floatFromInt((fg_rgb >> 8) & 0xFF)) / 255.0;
                        icon_b = @as(f32, @floatFromInt(fg_rgb & 0xFF)) / 255.0;
                    }
                }

                // Add border vertices (4 rectangles forming a frame)
                const border_w_ndc: f32 = @as(f32, @floatFromInt(CMDLINE_BORDER_WIDTH)) / (window_w / 2.0);
                const border_h_ndc: f32 = @as(f32, @floatFromInt(CMDLINE_BORDER_WIDTH)) / (window_h / 2.0);
                const border_color: [4]f32 = .{ border_r, border_g, border_b, 1.0 };
                const border_tex: [2]f32 = .{ -1.0, -1.0 };

                // Top border
                extra_idx = addRectVerts(cmdline_verts, extra_idx, -1.0, 1.0, 2.0, border_h_ndc, border_color, border_tex, grid_id);
                // Bottom border
                extra_idx = addRectVerts(cmdline_verts, extra_idx, -1.0, -1.0 + border_h_ndc, 2.0, border_h_ndc, border_color, border_tex, grid_id);
                // Left border
                extra_idx = addRectVerts(cmdline_verts, extra_idx, -1.0, 1.0 - border_h_ndc, border_w_ndc, 2.0 - 2.0 * border_h_ndc, border_color, border_tex, grid_id);
                // Right border
                extra_idx = addRectVerts(cmdline_verts, extra_idx, 1.0 - border_w_ndc, 1.0 - border_h_ndc, border_w_ndc, 2.0 - 2.0 * border_h_ndc, border_color, border_tex, grid_id);

                // Add icon based on cmdline_firstc
                const icon_color: [4]f32 = .{ icon_r, icon_g, icon_b, 1.0 };
                const icon_x_px: f32 = @floatFromInt(CMDLINE_PADDING + CMDLINE_ICON_MARGIN_LEFT);
                const icon_y_px: f32 = (window_h - @as(f32, @floatFromInt(CMDLINE_ICON_SIZE))) / 2.0;
                const icon_size_px: f32 = @floatFromInt(CMDLINE_ICON_SIZE);
                const icon_x_ndc: f32 = icon_x_px / (window_w / 2.0) - 1.0;
                const icon_y_ndc: f32 = 1.0 - icon_y_px / (window_h / 2.0);
                const icon_w_ndc: f32 = icon_size_px / (window_w / 2.0);
                const icon_h_ndc: f32 = icon_size_px / (window_h / 2.0);

                // Draw icon based on cmdline mode:
                // '/' or '?' -> search (magnifying glass)
                // ':' or anything else -> command (chevron)
                if (cmdline_firstc == '/' or cmdline_firstc == '?') {
                    extra_idx = addSearchIconVerts(cmdline_verts, extra_idx, icon_x_ndc, icon_y_ndc, icon_w_ndc, icon_h_ndc, icon_color, grid_id);
                } else {
                    extra_idx = addChevronIconVerts(cmdline_verts, extra_idx, icon_x_ndc, icon_y_ndc, icon_w_ndc, icon_h_ndc, icon_color, grid_id);
                }

                applog.appLog("[win] paintExternalWindow cmdline: total_verts={d} (orig={d} + extra={d})\n", .{ extra_idx, vert_count, extra_idx - vert_count });

                g.draw(cmdline_verts[0..extra_idx], &[_]core.Vertex{}, null) catch |e| {
                    applog.appLog("[win] paintExternalWindow cmdline draw failed: {any}\n", .{e});
                    return;
                };
            } else {
                // Fallback: draw original vertices
                g.draw(verts[0..vert_count], &[_]core.Vertex{}, null) catch |e| {
                    applog.appLog("[win] paintExternalWindow draw failed: {any}\n", .{e});
                    return;
                };
            }
        } else if (is_popupmenu) {
            // For popupmenu: add border around window (same style as cmdline)
            const window_w: f32 = @floatFromInt(g.width);
            const window_h: f32 = @floatFromInt(g.height);

            if (window_w > 0 and window_h > 0) {
                // 24 for border (4 rects * 6 verts)
                const extra_verts = 24;
                var pum_verts = app.alloc.alloc(core.Vertex, vert_count + extra_verts) catch {
                    applog.appLog("[win] paintExternalWindow: failed to alloc popupmenu verts\n", .{});
                    return;
                };
                defer app.alloc.free(pum_verts);

                // Copy original vertices
                @memcpy(pum_verts[0..vert_count], verts[0..vert_count]);
                var extra_idx: usize = vert_count;

                // Get border color from core (Search highlight) or use default yellow
                var border_r: f32 = 1.0;
                var border_g: f32 = 1.0;
                var border_b: f32 = 0.0;
                if (app.corep) |corep| {
                    var fg_rgb: u32 = 0;
                    var bg_rgb: u32 = 0;
                    if (core.zonvie_core_get_hl_by_name(corep, "Search", &fg_rgb, &bg_rgb) != 0) {
                        border_r = @as(f32, @floatFromInt((bg_rgb >> 16) & 0xFF)) / 255.0;
                        border_g = @as(f32, @floatFromInt((bg_rgb >> 8) & 0xFF)) / 255.0;
                        border_b = @as(f32, @floatFromInt(bg_rgb & 0xFF)) / 255.0;
                    }
                }

                // Add border vertices (4 rectangles forming a frame)
                const border_w_ndc: f32 = @as(f32, @floatFromInt(CMDLINE_BORDER_WIDTH)) / (window_w / 2.0);
                const border_h_ndc: f32 = @as(f32, @floatFromInt(CMDLINE_BORDER_WIDTH)) / (window_h / 2.0);
                const border_color: [4]f32 = .{ border_r, border_g, border_b, 1.0 };
                const border_tex: [2]f32 = .{ -1.0, -1.0 };

                // Top border
                extra_idx = addRectVerts(pum_verts, extra_idx, -1.0, 1.0, 2.0, border_h_ndc, border_color, border_tex, grid_id);
                // Bottom border
                extra_idx = addRectVerts(pum_verts, extra_idx, -1.0, -1.0 + border_h_ndc, 2.0, border_h_ndc, border_color, border_tex, grid_id);
                // Left border
                extra_idx = addRectVerts(pum_verts, extra_idx, -1.0, 1.0 - border_h_ndc, border_w_ndc, 2.0 - 2.0 * border_h_ndc, border_color, border_tex, grid_id);
                // Right border
                extra_idx = addRectVerts(pum_verts, extra_idx, 1.0 - border_w_ndc, 1.0 - border_h_ndc, border_w_ndc, 2.0 - 2.0 * border_h_ndc, border_color, border_tex, grid_id);

                applog.appLog("[win] paintExternalWindow popupmenu: total_verts={d} (orig={d} + border={d})\n", .{ extra_idx, vert_count, extra_idx - vert_count });

                g.draw(pum_verts[0..extra_idx], &[_]core.Vertex{}, null) catch |e| {
                    applog.appLog("[win] paintExternalWindow popupmenu draw failed: {any}\n", .{e});
                    return;
                };
            } else {
                // Fallback: draw original vertices
                g.draw(verts[0..vert_count], &[_]core.Vertex{}, null) catch |e| {
                    applog.appLog("[win] paintExternalWindow draw failed: {any}\n", .{e});
                    return;
                };
            }
        } else if (is_msg_show or is_msg_history) {
            // For msg_show/msg_history: apply transparency and padding like cmdline (but no border/icon)
            const window_w: f32 = @floatFromInt(g.width);
            const window_h: f32 = @floatFromInt(g.height);

            // Get content size from ext_win (need to re-lock briefly)
            app.mu.lock();
            const content_rows = ext_win.rows;
            const content_cols = ext_win.cols;
            const cell_w = app.cell_w_px;
            const cell_h = app.cell_h_px;
            app.mu.unlock();

            const content_w: f32 = @floatFromInt(content_cols * cell_w);
            const content_h: f32 = @floatFromInt(content_rows * cell_h);

            if (window_w > 0 and window_h > 0 and content_w > 0 and content_h > 0) {
                // Content area position in pixels (centered with padding)
                const content_left: f32 = @floatFromInt(MSG_PADDING);
                const content_top: f32 = @floatFromInt(MSG_PADDING);

                // Convert content area bounds to NDC
                const left_ndc: f32 = content_left / window_w * 2.0 - 1.0;
                const right_ndc: f32 = (content_left + content_w) / window_w * 2.0 - 1.0;
                const top_ndc: f32 = 1.0 - content_top / window_h * 2.0;
                const bottom_ndc: f32 = 1.0 - (content_top + content_h) / window_h * 2.0;

                // Calculate scale and offset for vertex transformation
                // Original vertices are in -1.0 to 1.0 (content area)
                // New vertices should map to content area within window
                const scale_x: f32 = (right_ndc - left_ndc) / 2.0;
                const scale_y: f32 = (top_ndc - bottom_ndc) / 2.0;
                const offset_x: f32 = (right_ndc + left_ndc) / 2.0;
                const offset_y: f32 = (top_ndc + bottom_ndc) / 2.0;

                // Extra verts: 6 for full-window background
                const extra_verts = 6;
                var msg_verts = app.alloc.alloc(core.Vertex, vert_count + extra_verts) catch {
                    applog.appLog("[win] paintExternalWindow: failed to alloc msg verts\n", .{});
                    return;
                };
                defer app.alloc.free(msg_verts);

                // Extract background color from first background vertex (texCoord.x < 0)
                var orig_bg_r: f32 = 0.0;
                var orig_bg_g: f32 = 0.0;
                var orig_bg_b: f32 = 0.0;
                var found_bg_vertex = false;
                for (verts[0..vert_count]) |v| {
                    if (v.texCoord[0] < 0) {
                        orig_bg_r = v.color[0];
                        orig_bg_g = v.color[1];
                        orig_bg_b = v.color[2];
                        found_bg_vertex = true;
                        break;
                    }
                }

                applog.appLog("[win] msg bg: found={} orig=({d:.3},{d:.3},{d:.3})\n", .{ found_bg_vertex, orig_bg_r, orig_bg_g, orig_bg_b });

                // If no background vertex found, use cached color (persists across redraws)
                if (!found_bg_vertex) {
                    app.mu.lock();
                    if (ext_win.cached_bg_color) |cached| {
                        orig_bg_r = cached[0];
                        orig_bg_g = cached[1];
                        orig_bg_b = cached[2];
                        applog.appLog("[win] msg bg: using cached=({d:.3},{d:.3},{d:.3})\n", .{ orig_bg_r, orig_bg_g, orig_bg_b });
                    }
                    app.mu.unlock();
                } else {
                    // Update cache with new background color
                    app.mu.lock();
                    ext_win.cached_bg_color = .{ orig_bg_r, orig_bg_g, orig_bg_b };
                    app.mu.unlock();
                }

                // Apply HSB adjustment for background visibility (same as cmdline)
                const adjusted = adjustBrightnessForCmdline(orig_bg_r, orig_bg_g, orig_bg_b);
                const adj_bg_r = adjusted[0];
                const adj_bg_g = adjusted[1];
                const adj_bg_b = adjusted[2];

                applog.appLog("[win] msg bg: adjusted=({d:.3},{d:.3},{d:.3})\n", .{ adj_bg_r, adj_bg_g, adj_bg_b });

                // First, add full-window background quad (drawn first, covers entire window)
                var bg_idx: usize = 0;
                const bg_color: [4]f32 = .{ adj_bg_r, adj_bg_g, adj_bg_b, app.config.window.opacity };
                const bg_tex: [2]f32 = .{ -1.0, -1.0 };
                bg_idx = addRectVerts(msg_verts, bg_idx, -1.0, 1.0, 2.0, 2.0, bg_color, bg_tex, grid_id);

                // Copy and transform original vertices after background
                // Make grid cell background vertices transparent (alpha=0) so only full-window bg shows
                // But preserve cursor vertices (marked with DECO_CURSOR flag)
                // Use tight tolerance to avoid accidentally making cursor transparent
                const tolerance: f32 = 0.005;
                for (verts[0..vert_count], 0..) |v, i| {
                    msg_verts[bg_idx + i] = v;
                    msg_verts[bg_idx + i].position[0] = v.position[0] * scale_x + offset_x;
                    msg_verts[bg_idx + i].position[1] = v.position[1] * scale_y + offset_y;

                    // Skip cursor vertices (marked with DECO_CURSOR flag)
                    if ((v.deco_flags & core.DECO_CURSOR) != 0) {
                        continue;
                    }

                    // Make background vertices fully transparent, but only if they match the original bg color
                    // This preserves cursor and other colored elements
                    if (v.texCoord[0] < 0) {
                        const matches_bg = @abs(v.color[0] - orig_bg_r) < tolerance and
                            @abs(v.color[1] - orig_bg_g) < tolerance and
                            @abs(v.color[2] - orig_bg_b) < tolerance;
                        if (matches_bg) {
                            msg_verts[bg_idx + i].color[3] = 0.0;
                        }
                    }
                }
                const total_verts = bg_idx + vert_count;

                applog.appLog("[win] paintExternalWindow msg: total_verts={d} (orig={d} + bg={d})\n", .{ total_verts, vert_count, bg_idx });

                g.draw(msg_verts[0..total_verts], &[_]core.Vertex{}, null) catch |e| {
                    applog.appLog("[win] paintExternalWindow msg draw failed: {any}\n", .{e});
                    return;
                };
            } else {
                // Fallback: draw original vertices
                g.draw(verts[0..vert_count], &[_]core.Vertex{}, null) catch |e| {
                    applog.appLog("[win] paintExternalWindow draw failed: {any}\n", .{e});
                    return;
                };
            }
        } else {
            // Normal external window (detached grid): draw vertices with optional scrollbar
            // Get scrollbar vertices if enabled
            var scrollbar_verts: [12]core.Vertex = undefined;
            var scrollbar_vert_count: usize = 0;

            // Check if scrollbar should be drawn
            if (app.config.scrollbar.enabled and ext_win.scrollbar_alpha > 0.001) {
                scrollbar_vert_count = generateScrollbarVerticesForExternal(
                    app,
                    ext_win,
                    grid_id,
                    @intCast(g.width),
                    @intCast(g.height),
                    &scrollbar_verts,
                );
            }

            // Filter out cursor vertices if blink state is off
            if (!cursor_blink_visible) {
                // Count non-cursor vertices
                var filtered_count: usize = 0;
                for (verts[0..vert_count]) |v| {
                    if ((v.deco_flags & core.DECO_CURSOR) == 0) {
                        filtered_count += 1;
                    }
                }

                if (filtered_count < vert_count or scrollbar_vert_count > 0) {
                    // Allocate temporary buffer for filtered vertices + scrollbar
                    const total_count = filtered_count + scrollbar_vert_count;
                    var combined_verts = app.alloc.alloc(core.Vertex, total_count) catch {
                        // Fallback to drawing all vertices
                        g.draw(verts[0..vert_count], &[_]core.Vertex{}, null) catch |e| {
                            applog.appLog("[win] paintExternalWindow draw failed: {any}\n", .{e});
                            return;
                        };
                        return;
                    };
                    defer app.alloc.free(combined_verts);

                    // Copy non-cursor vertices
                    var idx: usize = 0;
                    for (verts[0..vert_count]) |v| {
                        if ((v.deco_flags & core.DECO_CURSOR) == 0) {
                            combined_verts[idx] = v;
                            idx += 1;
                        }
                    }

                    // Append scrollbar vertices
                    if (scrollbar_vert_count > 0) {
                        @memcpy(combined_verts[idx .. idx + scrollbar_vert_count], scrollbar_verts[0..scrollbar_vert_count]);
                    }

                    g.draw(combined_verts[0..total_count], &[_]core.Vertex{}, null) catch |e| {
                        applog.appLog("[win] paintExternalWindow draw failed: {any}\n", .{e});
                        return;
                    };
                } else {
                    // No cursor vertices to filter and no scrollbar
                    g.draw(verts[0..vert_count], &[_]core.Vertex{}, null) catch |e| {
                        applog.appLog("[win] paintExternalWindow draw failed: {any}\n", .{e});
                        return;
                    };
                }
            } else {
                // Cursor is visible - draw all vertices with scrollbar
                if (scrollbar_vert_count > 0) {
                    const total_count = vert_count + scrollbar_vert_count;
                    var combined_verts = app.alloc.alloc(core.Vertex, total_count) catch {
                        // Fallback to drawing without scrollbar
                        g.draw(verts[0..vert_count], &[_]core.Vertex{}, null) catch |e| {
                            applog.appLog("[win] paintExternalWindow draw failed: {any}\n", .{e});
                            return;
                        };
                        return;
                    };
                    defer app.alloc.free(combined_verts);

                    @memcpy(combined_verts[0..vert_count], verts[0..vert_count]);
                    @memcpy(combined_verts[vert_count .. vert_count + scrollbar_vert_count], scrollbar_verts[0..scrollbar_vert_count]);

                    g.draw(combined_verts[0..total_count], &[_]core.Vertex{}, null) catch |e| {
                        applog.appLog("[win] paintExternalWindow draw failed: {any}\n", .{e});
                        return;
                    };
                } else {
                    g.draw(verts[0..vert_count], &[_]core.Vertex{}, null) catch |e| {
                        applog.appLog("[win] paintExternalWindow draw failed: {any}\n", .{e});
                        return;
                    };
                }
            }
        }

        applog.appLog("[win] paintExternalWindow draw succeeded, presenting\n", .{});

        // Present the rendered content (draw only renders to back buffer)
        g.presentOnlyFromBack(null) catch |e| {
            applog.appLog("[win] paintExternalWindow present failed: {any}\n", .{e});
            return;
        };

        applog.appLog("[win] paintExternalWindow present succeeded\n", .{});
    } else {
        applog.appLog("[win] paintExternalWindow no gpu_ptr\n", .{});
    }
}

/// Adjust brightness for cmdline background visibility (same as macOS).
/// Dark colors become slightly lighter (+0.05), light colors become slightly darker (-0.05).
/// Uses RGB to HSB conversion.
fn adjustBrightnessForCmdline(r: f32, g: f32, b: f32) [3]f32 {
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
fn addRectVerts(
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
fn addSearchIconVerts(
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
fn addChevronIconVerts(
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

// --- modifier helpers ---
const MOD_CTRL  = 1 << 0; // same bit layout as header comment
const MOD_ALT   = 1 << 1;
const MOD_SHIFT = 1 << 2;
// Windows has no "Command", leave it unused.

fn keyIsDown(vk: c_int) bool {
    // GetKeyState returns SHORT. High-order bit set => key down.
    return c.GetKeyState(vk) < 0;
}

fn queryMods() u32 {
    var m: u32 = 0;
    if (keyIsDown(c.VK_CONTROL)) m |= MOD_CTRL;
    if (keyIsDown(c.VK_MENU))    m |= MOD_ALT;   // Alt
    if (keyIsDown(c.VK_SHIFT))   m |= MOD_SHIFT;
    return m;
}

const KEYCODE_WINVK_FLAG: u32 = 0x10000;

fn sendKeyEventToCore(
    app: *App,
    keycode: u32,
    mods: u32,
    chars_utf8: ?[]const u8,
    ign_utf8: ?[]const u8,
) void {
    if (app.corep == null) return;

    const cptr: ?[*]const u8 = if (chars_utf8) |s| s.ptr else null;
    const clen: i32 = if (chars_utf8) |s| @intCast(s.len) else 0;

    const iptr: ?[*]const u8 = if (ign_utf8) |s| s.ptr else null;
    const ilen: i32 = if (ign_utf8) |s| @intCast(s.len) else 0;

    core.zonvie_core_send_key_event(app.corep, keycode, mods, cptr, clen, iptr, ilen);
}

/// Convert a UTF-16 (1 or 2 units) sequence to UTF-8 in a small stack buffer.
fn utf16UnitsToUtf8(tmp: *[8]u8, unit0: u16, unit1_opt: ?u16) ?[]const u8 {
    // Handle surrogate pair if present.
    if (unit0 >= 0xD800 and unit0 <= 0xDBFF) {
        const unit1 = unit1_opt orelse return null;
        if (unit1 < 0xDC00 or unit1 > 0xDFFF) return null;

        const hi: u32 = @as(u32, unit0) - 0xD800;
        const lo: u32 = @as(u32, unit1) - 0xDC00;
        const cp: u32 = 0x10000 + ((hi << 10) | lo);

        const n = std.unicode.utf8Encode(@as(u21, @intCast(cp)), tmp) catch return null;
        return tmp[0..n];
    }

    // Single unit (non-surrogate)
    if (unit0 >= 0xDC00 and unit0 <= 0xDFFF) return null;

    const n = std.unicode.utf8Encode(@as(u21, @intCast(unit0)), tmp) catch return null;
    return tmp[0..n];
}

/// Best-effort: use ToUnicodeEx to get chars and charsIgnoringModifiers for a VK.
/// - chars: using current keyboard state
/// - ign:   using state with Ctrl/Alt/Shift cleared (base letter for <C-x> etc)
fn toUnicodePairUtf8(
    vk: u32,
    scancode: u32,
    tmp_chars: *[16]u16,
    tmp_ign: *[16]u16,
    out_chars_utf8: *[8]u8,
    out_ign_utf8: *[8]u8,
) struct { chars: ?[]const u8, ign: ?[]const u8 } {
    var state: [256]u8 = undefined;
    _ = c.GetKeyboardState(&state);

    // Current chars
    const hkl = c.GetKeyboardLayout(0);
    const n1 = c.ToUnicodeEx(
        @intCast(vk),
        @intCast(scancode),
        &state,
        @ptrCast(tmp_chars.ptr),
        @intCast(tmp_chars.len),
        0,
        hkl,
    );

    var chars: ?[]const u8 = null;
    if (n1 == 1) {
        chars = utf16UnitsToUtf8(out_chars_utf8, tmp_chars[0], null);
    } else if (n1 == 2) {
        chars = utf16UnitsToUtf8(out_chars_utf8, tmp_chars[0], tmp_chars[1]);
    } else {
        // n1==0: no character; n1<0: dead key (ignore here)
        chars = null;
    }

    // Ignoring modifiers: clear Ctrl/Alt/Shift
    var ign_state = state;
    ign_state[c.VK_CONTROL] = 0;
    ign_state[c.VK_MENU] = 0;
    ign_state[c.VK_SHIFT] = 0;

    const n2 = c.ToUnicodeEx(
        @intCast(vk),
        @intCast(scancode),
        &ign_state,
        @ptrCast(tmp_ign.ptr),
        @intCast(tmp_ign.len),
        0,
        hkl,
    );

    var ign: ?[]const u8 = null;
    if (n2 == 1) {
        ign = utf16UnitsToUtf8(out_ign_utf8, tmp_ign[0], null);
    } else if (n2 == 2) {
        ign = utf16UnitsToUtf8(out_ign_utf8, tmp_ign[0], tmp_ign[1]);
    } else {
        ign = null;
    }

    return .{ .chars = chars, .ign = ign };
}

fn isSpecialVk(vk: u32) bool {
    return switch (vk) {
        c.VK_LEFT, c.VK_RIGHT, c.VK_UP, c.VK_DOWN,
        c.VK_HOME, c.VK_END, c.VK_PRIOR, c.VK_NEXT,
        c.VK_INSERT, c.VK_DELETE,
        c.VK_BACK, c.VK_TAB, c.VK_RETURN, c.VK_ESCAPE,
        c.VK_F1, c.VK_F2, c.VK_F3, c.VK_F4, c.VK_F5, c.VK_F6,
        c.VK_F7, c.VK_F8, c.VK_F9, c.VK_F10, c.VK_F11, c.VK_F12,
        => true,
        else => false,
    };
}

// --- IME Helper Functions ---

/// Convert UTF-16 composition string to UTF-8.
/// Must be called with app.mu locked.
fn updateImeCompositionUtf8(app: *App) void {
    app.ime_composition_utf8.clearRetainingCapacity();

    for (app.ime_composition_str.items) |unit| {
        // Handle non-surrogate characters
        if (unit >= 0xD800 and unit <= 0xDFFF) {
            // Skip surrogates for now (would need pair handling)
            continue;
        }

        var buf: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(@as(u21, @intCast(unit)), &buf) catch continue;
        app.ime_composition_utf8.appendSlice(app.alloc, buf[0..n]) catch continue;
    }
}

/// Position IME candidate window at cursor location.
fn positionImeCandidateWindow(hwnd: c.HWND, app: *App) void {
    const himc = c.ImmGetContext(hwnd);
    if (himc == null) return;
    defer _ = c.ImmReleaseContext(hwnd, himc);

    // Get cursor position and cell metrics from core
    app.mu.lock();
    const corep = app.corep;
    const cell_w = app.cell_w_px;
    const cell_h = app.cell_h_px;
    const linespace = app.linespace_px;
    const ext_tabline_enabled = app.ext_tabline_enabled;
    const main_hwnd = app.hwnd;
    app.mu.unlock();

    if (corep == null) return;

    // Row height includes linespace (for row positioning)
    const row_h: i32 = @intCast(cell_h + linespace);

    var row: i32 = 0;
    var col: i32 = 0;
    const grid_id = core.zonvie_core_get_cursor_position(corep, &row, &col);

    var grids: [16]core.GridInfo = undefined;
    const grid_count = core.zonvie_core_get_visible_grids(corep, &grids, 16);

    var screen_row: i32 = row;
    var screen_col: i32 = col;

    // Find the grid and add startRow/startCol
    for (grids[0..grid_count]) |grid| {
        if (grid.grid_id == grid_id) {
            screen_row = grid.start_row + row;
            screen_col = grid.start_col + col;
            break;
        }
    }

    // Calculate pixel position relative to content area
    const x: c.LONG = @intCast(screen_col * @as(i32, @intCast(cell_w)));
    const cursor_y: c.LONG = @intCast(screen_row * row_h);

    // Candidate window should appear immediately below the overlay (cell_h, not row_h)
    const below_overlay_y: c.LONG = cursor_y + @as(c.LONG, @intCast(cell_h));

    // When ext_tabline is enabled on main window, content is rendered below the tabbar.
    // IME context is associated with main window, so we need to add tabline height
    // to convert content-relative coordinates to main window coordinates.
    // External windows don't have a tabbar, so only apply offset for main window.
    var adjusted_cursor_y = cursor_y;
    var adjusted_below_overlay_y = below_overlay_y;
    const is_main_window = if (main_hwnd) |mh| hwnd == mh else false;
    if (ext_tabline_enabled and is_main_window) {
        adjusted_cursor_y += TablineState.TAB_BAR_HEIGHT;
        adjusted_below_overlay_y += TablineState.TAB_BAR_HEIGHT;
    }

    // Set composition window position (at cursor)
    var cf: c.COMPOSITIONFORM = undefined;
    cf.dwStyle = c.CFS_POINT;
    cf.ptCurrentPos = .{ .x = x, .y = adjusted_cursor_y };
    _ = c.ImmSetCompositionWindow(himc, &cf);

    // Set candidate window position (immediately below overlay)
    var candidate_form: c.CANDIDATEFORM = undefined;
    candidate_form.dwIndex = 0;
    candidate_form.dwStyle = c.CFS_CANDIDATEPOS;
    candidate_form.ptCurrentPos = .{ .x = x, .y = adjusted_below_overlay_y };
    _ = c.ImmSetCandidateWindow(himc, &candidate_form);
}

/// Disable IME input (switch to direct input mode).
fn setIMEOff(hwnd: c.HWND) void {
    const himc = c.ImmGetContext(hwnd);
    if (himc != null) {
        const result = c.ImmSetOpenStatus(himc, c.FALSE);
        _ = c.ImmReleaseContext(hwnd, himc);
        if (applog.isEnabled()) applog.appLog("[IME] setIMEOff: result={d}\n", .{result});
    } else {
        if (applog.isEnabled()) applog.appLog("[IME] setIMEOff: cannot get HIMC\n", .{});
    }
}

/// Calculate cell width for a Unicode codepoint (1 for narrow, 2 for wide).
fn imeCellWidth(codepoint: u21) u32 {
    // East Asian Wide characters
    if ((codepoint >= 0x1100 and codepoint <= 0x115F) or // Hangul Jamo
        (codepoint >= 0x2E80 and codepoint <= 0x9FFF) or // CJK
        (codepoint >= 0xAC00 and codepoint <= 0xD7AF) or // Hangul syllables
        (codepoint >= 0xF900 and codepoint <= 0xFAFF) or // CJK compatibility
        (codepoint >= 0xFE10 and codepoint <= 0xFE1F) or // Vertical forms
        (codepoint >= 0xFE30 and codepoint <= 0xFE6F) or // CJK compatibility forms
        (codepoint >= 0xFF00 and codepoint <= 0xFF60) or // Fullwidth forms
        (codepoint >= 0xFFE0 and codepoint <= 0xFFE6) or // Fullwidth symbols
        (codepoint >= 0x20000 and codepoint <= 0x2FFFF) or // CJK Extension B+
        (codepoint >= 0x30000 and codepoint <= 0x3FFFF) or // CJK Extension G+
        (codepoint >= 0x3040 and codepoint <= 0x30FF)) // Hiragana/Katakana
    {
        return 2;
    }
    return 1;
}

/// Create or update the IME preedit overlay window using layered window.
fn updateImePreeditOverlay(hwnd: c.HWND, app: *App) void {
    app.mu.lock();
    const composing = app.ime_composing;
    const comp_len = app.ime_composition_str.items.len;
    app.mu.unlock();

    applog.appLog("[IME] updateImePreeditOverlay composing={d} comp_len={d}\n", .{ @intFromBool(composing), comp_len });

    // Hide overlay if not composing
    if (!composing or comp_len == 0) {
        if (app.ime_overlay_hwnd) |overlay| {
            _ = c.ShowWindow(overlay, c.SW_HIDE);
        }
        return;
    }

    // Get cursor position and cell metrics
    // Avoid nested mutex acquisition by reading atlas ptr under app.mu, then accessing atlas separately
    var font_name_buf: [64]u16 = [_]u16{0} ** 64;
    var atlas_cell_w: u32 = 0;
    var atlas_cell_h: u32 = 0;
    var font_em_size: f32 = 14.0;
    var atlas_ptr: ?*dwrite_d2d.Renderer = null;

    app.mu.lock();
    const corep = app.corep;
    const cell_w = app.cell_w_px;
    const cell_h = app.cell_h_px;
    const linespace = app.linespace_px;
    const comp_str = app.ime_composition_str.items;
    const target_start = app.ime_target_start;
    const target_end = app.ime_target_end;
    atlas_ptr = if (app.atlas) |*a| a else null;
    atlas_cell_w = cell_w;
    atlas_cell_h = cell_h;
    const ext_tabline_enabled = app.ext_tabline_enabled;
    const content_hwnd = app.content_hwnd;
    app.mu.unlock();

    // Access atlas without holding app.mu to avoid nested locking
    if (atlas_ptr) |atlas| {
        atlas.mu.lock();
        defer atlas.mu.unlock();
        @memcpy(&font_name_buf, &atlas.font_name);
        atlas_cell_w = atlas.cell_w_px;
        atlas_cell_h = atlas.cell_h_px;
        font_em_size = atlas.font_em_size;
    }

    if (corep == null) {
        applog.appLog("[IME] corep is null\n", .{});
        return;
    }

    // Validate cell dimensions
    if (cell_w == 0 or cell_h == 0) {
        applog.appLog("[IME] cell dimensions are 0\n", .{});
        return;
    }

    // Row height includes linespace
    const row_h: u32 = cell_h + linespace;

    var row: i32 = 0;
    var col: i32 = 0;
    const grid_id = core.zonvie_core_get_cursor_position(corep, &row, &col);

    // Check if hwnd is an external window (use grid-local coords) or main window (use screen coords)
    var is_external_window = false;
    {
        app.mu.lock();
        defer app.mu.unlock();
        var ext_it = app.external_windows.iterator();
        while (ext_it.next()) |entry| {
            if (entry.value_ptr.hwnd == hwnd) {
                is_external_window = true;
                break;
            }
        }
    }

    var screen_row: i32 = row;
    var screen_col: i32 = col;

    // For external windows, use grid-local coordinates directly
    // For main window, add start_row/start_col to get screen position
    if (!is_external_window) {
        // Get grid info to calculate screen position
        var grids: [16]core.GridInfo = undefined;
        const grid_count = core.zonvie_core_get_visible_grids(corep, &grids, 16);

        for (grids[0..grid_count]) |grid| {
            if (grid.grid_id == grid_id) {
                screen_row = grid.start_row + row;
                screen_col = grid.start_col + col;
                break;
            }
        }
    }

    // Hide overlay if no composition text
    if (comp_str.len == 0) {
        if (app.ime_overlay_hwnd) |overlay| {
            _ = c.ShowWindow(overlay, c.SW_HIDE);
        }
        return;
    }

    // Create a memory DC and font first to measure actual text width
    const screen_dc = c.GetDC(null);
    if (screen_dc == null) return;
    defer _ = c.ReleaseDC(null, screen_dc);

    const mem_dc = c.CreateCompatibleDC(screen_dc);
    if (mem_dc == null) return;
    defer _ = c.DeleteDC(mem_dc);

    // Create GDI font matching the DWrite font
    // Use font_em_size for accurate sizing (negative for character height)
    // Set width to 0 to let Windows determine proper proportions
    const font_height: i32 = -@as(i32, @intFromFloat(font_em_size));

    const hfont = c.CreateFontW(
        font_height,
        0, // width: 0 lets Windows determine proper width based on height
        0, // escapement
        0, // orientation
        c.FW_NORMAL,
        0, // italic
        0, // underline
        0, // strikeout
        c.DEFAULT_CHARSET,
        c.OUT_TT_PRECIS, // TrueType precision for better matching
        c.CLIP_DEFAULT_PRECIS,
        c.CLEARTYPE_QUALITY,
        c.FIXED_PITCH | c.FF_MODERN, // Fixed pitch for monospace
        @ptrCast(&font_name_buf),
    );
    defer {
        if (hfont != null) _ = c.DeleteObject(hfont);
    }

    // Select font into DC to measure text
    const old_font = if (hfont != null) c.SelectObject(mem_dc, hfont) else null;
    defer {
        if (old_font != null) _ = c.SelectObject(mem_dc, old_font);
    }

    // Measure actual text width using GetTextExtentPoint32W
    var text_size: c.SIZE = undefined;
    if (c.GetTextExtentPoint32W(mem_dc, comp_str.ptr, @intCast(comp_str.len), &text_size) == 0) {
        return;
    }

    const overlay_width: i32 = text_size.cx + 4; // Add small padding
    const overlay_height: i32 = @intCast(atlas_cell_h);

    // Convert client position to screen position (use row_h for Y position)
    // For ext-cmdline, add offset for icon area and padding
    const is_cmdline = (grid_id == CMDLINE_GRID_ID);
    const cmdline_x_offset: c.LONG = if (is_external_window and is_cmdline)
        @intCast(CMDLINE_PADDING + CMDLINE_ICON_MARGIN_LEFT + CMDLINE_ICON_SIZE + CMDLINE_ICON_MARGIN_RIGHT)
    else
        0;
    const cmdline_y_offset: c.LONG = if (is_external_window and is_cmdline)
        @intCast(CMDLINE_PADDING)
    else
        0;

    var pt: c.POINT = .{
        .x = screen_col * @as(c.LONG, @intCast(cell_w)) + cmdline_x_offset,
        .y = screen_row * @as(c.LONG, @intCast(row_h)) + cmdline_y_offset,
    };
    // Use content_hwnd for coordinate conversion when it exists (content_hwnd is positioned below tabline).
    // When content_hwnd is null but ext_tabline is enabled on main window, add tabline height manually.
    const coord_hwnd = if (content_hwnd) |ch| ch else hwnd;
    if (content_hwnd == null and ext_tabline_enabled and !is_external_window) {
        pt.y += TablineState.TAB_BAR_HEIGHT;
    }
    _ = c.ClientToScreen(coord_hwnd, &pt);

    applog.appLog("[IME] overlay pos=({d},{d}) size=({d},{d}) text_w={d} cell=({d},{d}) row_h={d}\n", .{ pt.x, pt.y, overlay_width, overlay_height, text_size.cx, cell_w, cell_h, row_h });

    // Create overlay window if it doesn't exist (use layered window)
    if (app.ime_overlay_hwnd == null) {
        const new_overlay = c.CreateWindowExW(
            c.WS_EX_TOOLWINDOW | c.WS_EX_TOPMOST | c.WS_EX_NOACTIVATE | c.WS_EX_LAYERED,
            ime_overlay_class.ptr,
            null,
            c.WS_POPUP,
            pt.x,
            pt.y,
            overlay_width,
            overlay_height,
            hwnd,
            null,
            c.GetModuleHandleW(null),
            null,
        );
        if (new_overlay == null) {
            applog.appLog("[IME] CreateWindowExW failed\n", .{});
            return;
        }
        app.ime_overlay_hwnd = new_overlay;
        applog.appLog("[IME] created overlay window\n", .{});
    }

    const overlay = app.ime_overlay_hwnd orelse return;

    // Create 32-bit ARGB bitmap for layered window
    var bmi: c.BITMAPINFO = undefined;
    bmi.bmiHeader.biSize = @sizeOf(c.BITMAPINFOHEADER);
    bmi.bmiHeader.biWidth = overlay_width;
    bmi.bmiHeader.biHeight = -overlay_height; // top-down
    bmi.bmiHeader.biPlanes = 1;
    bmi.bmiHeader.biBitCount = 32;
    bmi.bmiHeader.biCompression = c.BI_RGB;
    bmi.bmiHeader.biSizeImage = 0;
    bmi.bmiHeader.biXPelsPerMeter = 0;
    bmi.bmiHeader.biYPelsPerMeter = 0;
    bmi.bmiHeader.biClrUsed = 0;
    bmi.bmiHeader.biClrImportant = 0;

    var bits: ?*anyopaque = null;
    const bitmap = c.CreateDIBSection(mem_dc, &bmi, c.DIB_RGB_COLORS, &bits, null, 0);
    if (bitmap == null) return;
    defer _ = c.DeleteObject(bitmap);

    const old_bitmap = c.SelectObject(mem_dc, bitmap);
    defer _ = c.SelectObject(mem_dc, old_bitmap);

    // Fill with opaque white background (BGRA format)
    if (bits) |ptr| {
        const pixel_count: usize = @intCast(@as(i32, overlay_width) * overlay_height);
        const pixels: [*]u32 = @ptrCast(@alignCast(ptr));
        for (0..pixel_count) |i| {
            pixels[i] = 0xFFFFFFFF; // ARGB: fully opaque white
        }
    }

    // Re-select font after bitmap selection
    _ = c.SelectObject(mem_dc, hfont);

    // Draw text to memory DC
    _ = c.SetBkMode(mem_dc, c.TRANSPARENT);
    _ = c.SetTextColor(mem_dc, 0x00000000); // Black text (BGR)

    // Draw the entire composition string
    _ = c.TextOutW(mem_dc, 0, 0, comp_str.ptr, @intCast(comp_str.len));

    applog.appLog("[IME] overlay draw: target_start={d} target_end={d} comp_len={d}\n", .{ target_start, target_end, comp_str.len });

    // Draw underline for target clause using pen (same as main window approach)
    if (target_start < comp_str.len and target_end <= comp_str.len and target_start < target_end) {
        const pen_target = c.CreatePen(c.PS_SOLID, 2, 0x00000000);
        defer _ = c.DeleteObject(pen_target);

        // Calculate underline positions using GetTextExtentPoint32W
        var target_start_x: i32 = 0;
        var target_end_x: i32 = 0;

        if (target_start > 0) {
            var size_before: c.SIZE = undefined;
            if (c.GetTextExtentPoint32W(mem_dc, comp_str.ptr, @intCast(target_start), &size_before) != 0) {
                target_start_x = size_before.cx;
            }
        }

        var size_to_end: c.SIZE = undefined;
        if (c.GetTextExtentPoint32W(mem_dc, comp_str.ptr, @intCast(target_end), &size_to_end) != 0) {
            target_end_x = size_to_end.cx;
        }

        applog.appLog("[IME] underline: start_x={d} end_x={d}\n", .{ target_start_x, target_end_x });

        if (target_end_x > target_start_x) {
            const old_pen = c.SelectObject(mem_dc, pen_target);
            const underline_y = overlay_height - 2;
            _ = c.MoveToEx(mem_dc, target_start_x, underline_y, null);
            _ = c.LineTo(mem_dc, target_end_x, underline_y);
            _ = c.SelectObject(mem_dc, old_pen);
        }
    }

    // Update the layered window
    var blend: c.BLENDFUNCTION = .{
        .BlendOp = c.AC_SRC_OVER,
        .BlendFlags = 0,
        .SourceConstantAlpha = 255,
        .AlphaFormat = c.AC_SRC_ALPHA,
    };

    var src_pt: c.POINT = .{ .x = 0, .y = 0 };
    var wnd_size: c.SIZE = .{ .cx = overlay_width, .cy = overlay_height };

    // Window already has WS_EX_TOPMOST extended style, use SWP_NOZORDER
    _ = c.SetWindowPos(
        overlay,
        null,
        pt.x,
        pt.y,
        overlay_width,
        overlay_height,
        c.SWP_NOACTIVATE | c.SWP_SHOWWINDOW | c.SWP_NOZORDER,
    );

    _ = c.UpdateLayeredWindow(
        overlay,
        screen_dc,
        &pt,
        &wnd_size,
        mem_dc,
        &src_pt,
        0,
        &blend,
        c.ULW_ALPHA,
    );

    applog.appLog("[IME] overlay updated\n", .{});
}

/// Hide IME preedit overlay.
fn hideImePreeditOverlay(app: *App) void {
    if (app.ime_overlay_hwnd) |overlay| {
        _ = c.ShowWindow(overlay, c.SW_HIDE);
    }
}

/// Wide string constant for "STATIC" window class
const ime_overlay_class: [:0]const u16 = std.unicode.utf8ToUtf16LeStringLiteral("STATIC");

/// Get effective content width (subtracts scrollbar width in "always" mode)
fn getEffectiveContentWidth(app: *App, client_width: u32) u32 {
    if (app.config.scrollbar.enabled and app.config.scrollbar.isAlways()) {
        const scrollbar_reserved: u32 = @intFromFloat(SCROLLBAR_WIDTH + SCROLLBAR_MARGIN * 2);
        if (client_width > scrollbar_reserved) {
            return client_width - scrollbar_reserved;
        }
    }
    return client_width;
}

fn updateLayoutToCore(hwnd: c.HWND, app: *App) void {
    if (app.corep == null) return;

    var rc: c.RECT = undefined;
    // When content_hwnd exists, use its client rect (already excludes tabbar area)
    const target_hwnd = if (app.content_hwnd) |ch| ch else hwnd;
    _ = c.GetClientRect(target_hwnd, &rc);

    const client_w: u32 = @intCast(@max(1, rc.right - rc.left));
    const client_h: u32 = @intCast(@max(1, rc.bottom - rc.top));

    // In "always" mode, reserve space for scrollbar
    const w = getEffectiveContentWidth(app, client_w);

    // For DWM custom titlebar without content_hwnd: client area includes titlebar,
    // so subtract tabbar height to get the actual content area for Neovim.
    // When using content_hwnd, it already has the correct size (excludes tabbar).
    const tabbar_height: u32 = if (app.ext_tabline_enabled and app.content_hwnd == null)
        @intCast(TablineState.TAB_BAR_HEIGHT)
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

fn rowHeightPxFromClient(hwnd: c.HWND, rows: u32, fallback: u32) u32 {
    // Always use the fallback (cell_h + linespace) as the authoritative row height.
    // The division-based calculation (client_h / rows) is unreliable when Neovim's
    // row count doesn't match the frontend's expected row count (e.g., during
    // linespace changes where rows haven't been synchronized yet).
    _ = hwnd;
    _ = rows;
    return fallback;
}

fn updateRowsColsFromClientForce(hwnd: c.HWND, app: *App) void {
    var rc: c.RECT = undefined;
    // When content_hwnd exists, use its client rect (already excludes tabbar area)
    const target_hwnd = if (app.content_hwnd) |ch| ch else hwnd;
    _ = c.GetClientRect(target_hwnd, &rc);

    const client_w: u32 = @intCast(@max(1, rc.right - rc.left));
    const client_h: u32 = @intCast(@max(1, rc.bottom - rc.top));

    // In "always" mode, use effective content width
    const w = getEffectiveContentWidth(app, client_w);

    // Subtract tabbar height when ext_tabline is enabled but content_hwnd doesn't exist
    // When using content_hwnd, it already has the correct size (excludes tabbar).
    const tabbar_height: u32 = if (app.ext_tabline_enabled and app.content_hwnd == null)
        @intCast(TablineState.TAB_BAR_HEIGHT)
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

fn updateRowsColsFromClient(hwnd: c.HWND, app: *App) void {
    // Only use client-derived rows/cols as a bootstrap before core provides them.
    if (app.rows != 0 or app.cols != 0) {
        return;
    }
    updateRowsColsFromClientForce(hwnd, app);
}

fn setLogEnabledViaCore(app: *App, enabled: bool) void {
    // 1) core-side switch
    if (app.corep != null) {
        core.zonvie_core_set_log_enabled(app.corep, if (enabled) 1 else 0);
    }

    // 2) app-root switch (Windows side)
    applog.setEnabled(enabled);
}

export fn WndProc(
    hwnd: c.HWND,
    msg: c.UINT,
    wParam: c.WPARAM,
    lParam: c.LPARAM,
) callconv(.winapi) c.LRESULT {
    switch (msg) {
        c.WM_NCCREATE => {
            applog.appLog("WM_NCCREATE hwnd={*} wParam={d} lParam=0x{x}", .{ hwnd, wParam, @as(usize, @bitCast(lParam)) });
        
            const cs: *c.CREATESTRUCTW = @ptrFromInt(@as(usize, @bitCast(lParam)));
            applog.appLog("  CREATESTRUCTW ptr={*} lpCreateParams={*}", .{ cs, cs.lpCreateParams });
        
            const lp = cs.lpCreateParams orelse {
                applog.appLog("  lpCreateParams is null -> fail", .{});
                return 0;
            };
            applog.appLog("  lpCreateParams={*}", .{lp});
        
            const app: *App = @ptrCast(@alignCast(lp));
            applog.appLog("  app ptr={*} align={d}", .{ app, @alignOf(App) });

            app.owned_by_hwnd = true;
            setApp(hwnd, app);
            applog.appLog("  GWLP_USERDATA set", .{});
            return 1;
        },

        // DWM custom titlebar: extend client area into titlebar
        c.WM_NCCALCSIZE => {
            if (getApp(hwnd)) |app| {
                if (app.ext_tabline_enabled and wParam != 0) {
                    // When wParam is TRUE, return 0 to use entire window as client area.
                    // This removes the standard titlebar/frame.
                    // The NCCALCSIZE_PARAMS structure at lParam defines the client rect.
                    // By returning 0 without modification, we get full window as client area.
                    applog.appLog("[win] WM_NCCALCSIZE: extending client area into titlebar\n", .{});
                    return 0;
                }
            }
            return c.DefWindowProcW(hwnd, msg, wParam, lParam);
        },

        // DWM custom titlebar: hit testing for resize borders and caption dragging
        c.WM_NCHITTEST => {
            if (getApp(hwnd)) |app| {
                if (app.ext_tabline_enabled) {
                    // Get cursor position in screen coordinates
                    const x = @as(i16, @truncate(lParam & 0xFFFF));
                    const y = @as(i16, @truncate((lParam >> 16) & 0xFFFF));

                    // Get window rect in screen coordinates
                    var window_rect: c.RECT = undefined;
                    _ = c.GetWindowRect(hwnd, &window_rect);

                    // Frame/border sizes for resize detection
                    const frame_x = c.GetSystemMetrics(c.SM_CXFRAME) + c.GetSystemMetrics(c.SM_CXPADDEDBORDER);
                    const frame_y = c.GetSystemMetrics(c.SM_CYFRAME) + c.GetSystemMetrics(c.SM_CXPADDEDBORDER);

                    // Check if cursor is in the scrollbar area (right edge, below tabbar).
                    // If so, don't treat it as a resize border - let it be handled as HTCLIENT.
                    // But keep rightmost 2 pixels for resize detection.
                    // Only check scrollbar area if scrollbar is enabled.
                    const tabbar_height_i16: i16 = TablineState.TAB_BAR_HEIGHT;
                    const resize_edge_width: i32 = 2; // Keep this many pixels at right edge for resize
                    const in_scrollbar_area = if (app.config.scrollbar.enabled) blk: {
                        const scrollbar_area_left = window_rect.right - @as(i32, @intFromFloat(SCROLLBAR_WIDTH + SCROLLBAR_MARGIN * 2));
                        const scrollbar_area_right = window_rect.right - resize_edge_width; // Leave edge for resize
                        const scrollbar_area_top = window_rect.top + tabbar_height_i16 + @as(i32, @intFromFloat(SCROLLBAR_MARGIN));
                        const scrollbar_area_bottom = window_rect.bottom - @as(i32, @intFromFloat(SCROLLBAR_MARGIN)) - resize_edge_width;
                        break :blk x >= scrollbar_area_left and x < scrollbar_area_right and
                            y >= scrollbar_area_top and y <= scrollbar_area_bottom;
                    } else false;

                    // Check resize borders first
                    const on_left = x < window_rect.left + frame_x;
                    // Exclude scrollbar area from right-edge resize detection
                    const on_right = x >= window_rect.right - frame_x and !in_scrollbar_area;
                    const on_top = y < window_rect.top + frame_y;
                    const on_bottom = y >= window_rect.bottom - frame_y and !in_scrollbar_area;

                    if (on_top) {
                        if (on_left) return c.HTTOPLEFT;
                        if (on_right) return c.HTTOPRIGHT;
                        return c.HTTOP;
                    }
                    if (on_bottom) {
                        if (on_left) return c.HTBOTTOMLEFT;
                        if (on_right) return c.HTBOTTOMRIGHT;
                        return c.HTBOTTOM;
                    }
                    if (on_left) return c.HTLEFT;
                    if (on_right) return c.HTRIGHT;

                    // Check if in tabbar area (custom caption)
                    const tabbar_height = TablineState.TAB_BAR_HEIGHT;
                    if (y < window_rect.top + tabbar_height) {
                        // In tabbar area - check if clicking on interactive elements or empty space
                        const client_x = x - window_rect.left;
                        const client_width = window_rect.right - window_rect.left;

                        // Check window control buttons (min/max/close) on the right
                        const btn_start_x = client_width - TablineState.WINDOW_BTNS_TOTAL;
                        if (client_x >= btn_start_x) {
                            // On window buttons - return HTCLIENT so our click handler works
                            return c.HTCLIENT;
                        }

                        // Check if clicking on a tab or + button
                        app.mu.lock();
                        const tab_count = app.tabline_state.tab_count;
                        app.mu.unlock();

                        if (tab_count > 0) {
                            // Calculate tab positions using same logic as drawTablineContent
                            const available_width = client_width - TablineState.WINDOW_CONTROLS_WIDTH - 40 - TablineState.WINDOW_BTNS_TOTAL;
                            const ideal_width = @divTrunc(available_width, @as(i32, @intCast(tab_count)));
                            const tab_width = @min(TablineState.TAB_MAX_WIDTH, @max(TablineState.TAB_MIN_WIDTH, ideal_width));

                            var tab_x: i32 = TablineState.WINDOW_CONTROLS_WIDTH;
                            for (0..tab_count) |_| {
                                if (client_x >= tab_x and client_x < tab_x + tab_width) {
                                    // On a tab - return HTCLIENT so clicks go to the app
                                    return c.HTCLIENT;
                                }
                                tab_x += tab_width + 1;
                            }

                            // Check + button area
                            const plus_x = tab_x + 8;
                            if (client_x >= plus_x and client_x < plus_x + 20) {
                                return c.HTCLIENT;
                            }
                        }

                        // Empty area in tabbar - allow dragging
                        return c.HTCAPTION;
                    }

                    // Below tabbar - normal client area
                    return c.HTCLIENT;
                }
            }
            return c.DefWindowProcW(hwnd, msg, wParam, lParam);
        },

        c.WM_CREATE => {
            if (builtin.mode == .Debug and !applog.isEnabled()) {
                // Force early logging in debug builds to capture init crashes.
                applog.setEnabled(true);
            }

            applog.appLog("WM_CREATE: begin (deferred init)", .{});
            if (getApp(hwnd)) |app| {
                app.hwnd = hwnd;
                app.ui_thread_id = c.GetCurrentThreadId();

                // DWM custom titlebar: trigger frame recalculation
                if (app.ext_tabline_enabled) {
                    var rc: c.RECT = undefined;
                    _ = c.GetWindowRect(hwnd, &rc);
                    _ = c.SetWindowPos(
                        hwnd,
                        null,
                        rc.left,
                        rc.top,
                        rc.right - rc.left,
                        rc.bottom - rc.top,
                        c.SWP_FRAMECHANGED | c.SWP_NOMOVE | c.SWP_NOSIZE,
                    );
                    applog.appLog("[win] WM_CREATE: triggered SWP_FRAMECHANGED for custom titlebar\n", .{});

                    // NOTE: content_hwnd is NOT created anymore.
                    // D3D11 renders to parent window directly, including tabline area.
                    // This avoids DWM composition issues with GDI/D3D mixing across windows.
                }

                // Initialize tray icon for OS notification (balloon notification)
                app.tray_icon = TrayIcon.init(hwnd);
                if (app.tray_icon) |*tray| {
                    tray.add();
                }

                // Post deferred init message - renderer initialization happens after window is shown
                _ = c.PostMessageW(hwnd, WM_APP_DEFERRED_INIT, 0, 0);

                applog.appLog("WM_CREATE: end (posted deferred init)", .{});
            }
            return 0;
        },
        c.WM_PAINT => {
            applog.appLog("WM_PAINT tid={d}", .{ c.GetCurrentThreadId() });

            if (getApp(hwnd)) |app| {
                var ps: c.PAINTSTRUCT = undefined;
                _ = c.BeginPaint(hwnd, &ps);
                defer _ = c.EndPaint(hwnd, &ps);

                // Log first paint with content timing (startup performance)
                if (!app.first_paint_logged and app.renderer != null) {
                    var first_paint_t: c.LARGE_INTEGER = undefined;
                    _ = c.QueryPerformanceCounter(&first_paint_t);
                    const first_paint_ms = @divTrunc((first_paint_t.QuadPart - g_startup_t0.QuadPart) * 1000, g_startup_freq.QuadPart);
                    applog.appLog("[TIMING] First WM_PAINT (renderer ready): {d}ms from main()\n", .{first_paint_ms});
                    app.first_paint_logged = true;
                }

                // If renderer not yet initialized (deferred init pending), just fill with black
                if (app.renderer == null) {
                    applog.appLog("[win] WM_PAINT: renderer not ready, filling black", .{});
                    const hdc = ps.hdc;
                    const black_brush: c.HBRUSH = @ptrCast(@alignCast(c.GetStockObject(c.BLACK_BRUSH)));
                    _ = c.FillRect(hdc, &ps.rcPaint, black_brush);
                    return 0;
                }

                var dirty: ?c.RECT =
                    if (ps.rcPaint.right > ps.rcPaint.left and ps.rcPaint.bottom > ps.rcPaint.top)
                        ps.rcPaint
                    else
                        null;
        
                // Consume need_full_seed ONCE here.
                const did_need_seed = app.need_full_seed.swap(false, .seq_cst);
                if (did_need_seed) {
                    // Keep rows/cols synced to client size before we snapshot row-mode state.
                    app.mu.lock();
                    updateRowsColsFromClientForce(hwnd, app);
                    app.mu.unlock();

                    // IMPORTANT: do not hold app.mu while calling into core.
                    updateLayoutToCore(hwnd, app);
        
                    // Force full redraw request on this paint.
                    dirty = null;
        
                    // Ensure we get a paint covering the whole surface.
                    _ = c.InvalidateRect(hwnd, null, c.FALSE);
                    app.paint_full = true;
                    app.paint_rects.clearRetainingCapacity();
                }
        
                // Note: row_mode/rows/main_verts length are logged after snapshotting under lock.
                // if (dirty) |r| {
                //     applog.appLog("[win]   dirty_rect=({d},{d})-({d},{d})\n", .{ r.left, r.top, r.right, r.bottom });
                // }
        
                app.mu.lock();
                if (app.rows == 0) {
                    updateRowsColsFromClient(hwnd, app);
                }
                // Snapshot state under lock.
        
                const row_mode = app.row_mode;
                const seed_pending_snapshot = app.seed_pending;
                const row_valid_count_snapshot = app.row_valid_count;
                const rows_snapshot: u32 = app.rows;
                const row_layout_gen_snapshot: u64 = app.row_layout_gen;
                const main_verts_len_snapshot: u32 = @intCast(app.main_verts.items.len);
                const row_mode_max_row_end_snapshot: u32 = app.row_mode_max_row_end;
        
                // IMPORTANT: do NOT copy renderer/atlas structs here.
                // Take pointers to the option payloads instead.
                var atlas_ptr: ?*dwrite_d2d.Renderer = null;
                var gpu_ptr: ?*d3d11.Renderer = null;
                if (app.atlas) |*a| atlas_ptr = a;
                if (app.renderer) |*g| gpu_ptr = g;
        
                var dirty_row_keys: std.ArrayListUnmanaged(u32) = .{};
                defer dirty_row_keys.deinit(app.alloc);

                if (row_mode) {
                    // Pre-allocate capacity based on dirty_rows count
                    dirty_row_keys.ensureTotalCapacity(app.alloc, app.dirty_rows.count()) catch {};
                    var it = app.dirty_rows.keyIterator();
                    while (it.next()) |k| {
                        dirty_row_keys.appendAssumeCapacity(k.*);
                    }
                }
                // Clear dirty rows set now (we have the snapshot).
                app.dirty_rows.clearRetainingCapacity();
        
                // Also snapshot row_verts length (for logging / bounds).
                const row_verts_len: u32 = @intCast(app.row_verts.items.len);
                var effective_rows: u32 = rows_snapshot;
                var rows_mismatch: bool = false;
                if (row_mode and row_mode_max_row_end_snapshot != 0 and row_mode_max_row_end_snapshot < effective_rows) {
                    effective_rows = row_mode_max_row_end_snapshot;
                    rows_mismatch = true;
                }
                const effective_row_valid_count: u32 =
                    if (effective_rows < row_valid_count_snapshot) effective_rows else row_valid_count_snapshot;

                var paint_rects_snapshot: std.ArrayListUnmanaged(c.RECT) = .{};
                defer paint_rects_snapshot.deinit(app.alloc);
                paint_rects_snapshot.ensureTotalCapacity(app.alloc, app.paint_rects.items.len) catch {};
                paint_rects_snapshot.appendSliceAssumeCapacity(app.paint_rects.items);
                app.paint_rects.clearRetainingCapacity();
                
                const paint_full_snapshot = app.paint_full;
                app.paint_full = false;

    app.mu.unlock();

                applog.appLog(
                    "[win] WM_PAINT rcPaint=({d},{d})-({d},{d}) dirty={s} need_seed={d} row_mode={d} rows={d} row_verts_len={d} main_verts={d}\n",
                    .{
                        ps.rcPaint.left, ps.rcPaint.top, ps.rcPaint.right, ps.rcPaint.bottom,
                        if (dirty == null) "null" else "rect",
                        @as(u32, @intFromBool(did_need_seed)),
                        @as(u32, @intFromBool(row_mode)),
                        rows_snapshot,
                        row_verts_len,
                        main_verts_len_snapshot,
                    },
                );
                if (row_mode and rows_mismatch) {
                    applog.appLog(
                        "[win] WM_PAINT(row) WARN rows_mismatch rows={d} max_row_end={d} row_verts_len={d}\n",
                        .{ rows_snapshot, row_mode_max_row_end_snapshot, row_verts_len },
                    );
                }
        
                // Flush atlas uploads (may be triggered by core updates).
                // If uploads occurred, force a repaint so newly uploaded glyphs are drawn.
                var atlas_uploads: u32 = 0;
                if (atlas_ptr) |a| {
                    if (gpu_ptr) |g| {
                        // Lock D3D context for thread-safe atlas upload
                        g.lockContext();
                        defer g.unlockContext();
                        atlas_uploads = a.flushPendingAtlasUploadsToD3D(g);
                    }
                }
                if (atlas_uploads != 0) {
                    applog.appLog("[win] atlas_uploads flushed={d} -> request repaint\n", .{ atlas_uploads });
                    app.mu.lock();
                    app.paint_full = true;
                    app.paint_rects.clearRetainingCapacity();
                    app.mu.unlock();
                    _ = c.InvalidateRect(hwnd, null, c.FALSE);
                }
        
                if (gpu_ptr) |g| {
                    // Lock D3D context for thread-safe rendering
                    g.lockContext();
                    defer g.unlockContext();

                    // Calculate content width for "always" scrollbar mode
                    // When content_hwnd exists, use its size (D3D11 is bound to content_hwnd)
                    var client_for_content: c.RECT = undefined;
                    const size_hwnd = if (app.content_hwnd) |ch| ch else hwnd;
                    _ = c.GetClientRect(size_hwnd, &client_for_content);
                    const client_width_u32: u32 = @intCast(@max(1, client_for_content.right - client_for_content.left));
                    const content_width: ?u32 = if (app.config.scrollbar.enabled and app.config.scrollbar.isAlways())
                        getEffectiveContentWidth(app, client_width_u32)
                    else
                        null;

                    // Content Y offset for ext_tabline (pushes content down below tabbar)
                    // When using content_hwnd (child window for D3D11), offset is 0 because D3D11 renders in child window starting at y=0
                    const content_y_offset: ?u32 = if (app.ext_tabline_enabled and app.content_hwnd == null)
                        @intCast(TablineState.TAB_BAR_HEIGHT)
                    else
                        null;

                    // Tabbar background color (dark gray) - fallback if tabline texture not available
                    const tabbar_bg_color: ?[4]f32 = if (app.ext_tabline_enabled and app.content_hwnd == null)
                        .{ 0.12, 0.12, 0.12, 1.0 }
                    else
                        null;

                    // Update tabline texture (rendered via GDI offscreen -> D3D11 texture)
                    // This avoids DWM composition issues by keeping GDI rendering offscreen
                    if (app.ext_tabline_enabled and app.tabline_state.tab_count > 0) {
                        const tabline_width: u32 = @intCast(@max(1, client_for_content.right));
                        const tabline_height: u32 = TablineState.TAB_BAR_HEIGHT;
                        renderTablineToD3D(app, tabline_width, tabline_height);
                    }

                    if (!row_mode) {
                        // Non-row mode: draw under lock to keep main/cursor verts stable.
                        app.mu.lock();
                        if (!app.row_mode) {
                            const main_verts_now = app.main_verts.items;
                            // Only include cursor verts if blink state is visible
                            const cursor_verts_now = if (app.cursor_blink_state) app.cursor_verts.items else &[_]core.Vertex{};
                            g.drawEx(main_verts_now, cursor_verts_now, dirty, .{ .content_width = content_width, .content_y_offset = content_y_offset, .tabbar_bg_color = tabbar_bg_color }) catch |e| {
                                applog.appLog("gpu.draw failed: {any}\n", .{e});
                            };
                        } else {
                            // Row-mode flipped mid-frame; skip and let the next paint handle it.
                            applog.appLog("[win] WM_PAINT(non-row) row_mode flipped -> skip\n", .{});
                        }
                        app.mu.unlock();
                    } else {
                        // --- Row-mode ---
                        const log_enabled = applog.isEnabled();
                        var t_row_start_ns: i128 = 0;
                        var t_present_start_ns: i128 = 0;
                        if (log_enabled) {
                            t_row_start_ns = std.time.nanoTimestamp();
                        }
        
                        // Build list of rows to draw.
                        // Rule:
                        // - After resize seed OR dirty==null (full redraw request), draw ALL cached rows.
                        // - Otherwise draw only dirty rows.
                        // Use persistent buffer to avoid per-frame alloc/free.
                        const rows_to_draw = &app.wm_paint_rows_to_draw;
                        rows_to_draw.clearRetainingCapacity();

                        const force_full_rows =
                            did_need_seed or (dirty == null) or paint_full_snapshot or seed_pending_snapshot;

                        // Pre-allocate capacity based on expected row count
                        const max_rows = @max(effective_rows, @max(row_verts_len, @as(u32, @intCast(dirty_row_keys.items.len))));
                        rows_to_draw.ensureTotalCapacity(app.alloc, max_rows) catch {};

                        if (force_full_rows) {
                            // Full redraw request
                            var irow: u32 = 0;
                            const n: u32 = if (effective_rows != 0) effective_rows else row_verts_len;
                            while (irow < n) : (irow += 1) {
                                rows_to_draw.appendAssumeCapacity(irow);
                            }
                        } else if (dirty_row_keys.items.len != 0) {
                            // Normal path: use explicit dirty rows
                            rows_to_draw.appendSliceAssumeCapacity(dirty_row_keys.items);
                        } else {
                            // Nothing to draw
                        }

                        // ---- normalize rows_to_draw (MUST be < row_verts_len AND < rows_snapshot) ----
                        //
                        // Some paths (ceil division / region union / external dirty keys) can yield r == row_verts_len.
                        // That would crash later as an out-of-bounds row index, so clamp here unconditionally.
                        // Also filter out rows >= rows_snapshot to prevent drawing stale rows when grid shrinks.
                        if (rows_to_draw.items.len != 0) {
                            // First: filter to valid range [0, min(row_verts_len, rows_snapshot))
                            const max_valid_row: u32 = @min(row_verts_len, rows_snapshot);
                            var w: usize = 0;
                            var i: usize = 0;
                            while (i < rows_to_draw.items.len) : (i += 1) {
                                const r = rows_to_draw.items[i];
                                if (r < max_valid_row) {
                                    rows_to_draw.items[w] = r;
                                    w += 1;
                                }
                            }
                            rows_to_draw.items.len = w;
                        
                            // Second: sort + unique (duplicates can happen)
                            if (rows_to_draw.items.len != 0) {
                                std.sort.pdq(u32, rows_to_draw.items, {}, comptime std.sort.asc(u32));
                        
                                w = 0;
                                i = 0;
                                while (i < rows_to_draw.items.len) : (i += 1) {
                                    const r = rows_to_draw.items[i];
                                    if (w == 0 or rows_to_draw.items[w - 1] != r) {
                                        rows_to_draw.items[w] = r;
                                        w += 1;
                                    }
                                }
                                rows_to_draw.items.len = w;
                            }
                        }
                        // ---- end normalize rows_to_draw ----

                        applog.appLog(
                            "[win] WM_PAINT(row) force_full_rows={d} rows_to_draw={d} dirty_keys={d} row_verts_len={d}\n",
                            .{
                                @as(u32, @intFromBool(force_full_rows)),
                                rows_to_draw.items.len,
                                dirty_row_keys.items.len,
                                row_verts_len,
                            },
                        );
                        if (force_full_rows and effective_rows == 0) {
                            applog.appLog(
                                "[win] WM_PAINT(row) WARN rows_unknown skip_present rows_to_draw={d} row_verts_len={d}\n",
                                .{ rows_to_draw.items.len, row_verts_len },
                            );
                        }
                        if (force_full_rows and effective_rows != 0 and rows_to_draw.items.len != effective_rows) {
                            applog.appLog(
                                "[win] WM_PAINT(row) WARN partial_full_rows rows={d} rows_to_draw={d}\n",
                                .{ effective_rows, rows_to_draw.items.len },
                            );
                        }
                        if (!force_full_rows and rows_to_draw.items.len == 0 and (dirty_row_keys.items.len != 0 or paint_rects_snapshot.items.len != 0)) {
                            applog.appLog(
                                "[win] WM_PAINT(row) WARN empty_rows_to_draw rows={d} row_verts_len={d} dirty_keys={d} paint_rects={d}\n",
                                .{ rows_snapshot, row_verts_len, dirty_row_keys.items.len, paint_rects_snapshot.items.len },
                            );
                        }

                        // --- Build present dirty from actual drawn row_rc + cursor_rc (don't use rcPaint) ---
                        var cursor_verts_snapshot: []const core.Vertex = &[_]core.Vertex{};
                        // Snapshot cursor verts into a stable buffer (avoid races with callbacks).
                        {
                            app.mu.lock();
                            defer app.mu.unlock();
                            app.row_tmp_verts.clearRetainingCapacity();
                            const cur = app.cursor_verts.items;
                            applog.appLog("[win] WM_PAINT(row) cursor_verts.len={d}\n", .{cur.len});
                            if (cur.len != 0) {
                                app.row_tmp_verts.ensureTotalCapacity(app.alloc, cur.len) catch {
                                    applog.appLog("[win] WM_PAINT(row) cursor snapshot ensure cap failed\n", .{});
                                };
                                app.row_tmp_verts.appendSlice(app.alloc, cur) catch {
                                    applog.appLog("[win] WM_PAINT(row) cursor snapshot append failed\n", .{});
                                };
                                cursor_verts_snapshot = app.row_tmp_verts.items;
                            }
                        }
                        // Use content_hwnd size when it exists (D3D11 is bound to content_hwnd)
                        var client: c.RECT = undefined;
                        const client_hwnd = if (app.content_hwnd) |ch| ch else hwnd;
                        _ = c.GetClientRect(client_hwnd, &client);

                        // Get cursor rect and transform Y coords to match viewport when ext_tabline is enabled.
                        // rectFromCursorVerts calculates Y using full window height, but viewport has Y offset
                        // and reduced height. Transform: new_y = y_off + old_y * (full_h - y_off) / full_h
                        const cursor_rc_raw = rectFromCursorVerts(client_hwnd, cursor_verts_snapshot);
                        const cursor_rc_opt: ?c.RECT = if (cursor_rc_raw) |cr| blk: {
                            const y_off: i32 = if (content_y_offset) |off| @intCast(off) else 0;
                            if (y_off > 0) {
                                const full_h: f32 = @floatFromInt(@max(1, client.bottom));
                                const content_h: f32 = full_h - @as(f32, @floatFromInt(y_off));
                                break :blk .{
                                    .left = cr.left,
                                    .top = y_off + @as(i32, @intFromFloat(@as(f32, @floatFromInt(cr.top)) * content_h / full_h)),
                                    .right = cr.right,
                                    .bottom = y_off + @as(i32, @intFromFloat(@ceil(@as(f32, @floatFromInt(cr.bottom)) * content_h / full_h))),
                                };
                            } else {
                                break :blk cr;
                            }
                        } else null;
                        
                        const fallback_row_h: u32 = app.cell_h_px + app.linespace_px;
                        const rows_for_layout: u32 = if (rows_mismatch) 0 else if (rows_snapshot != 0) rows_snapshot else row_verts_len;
                        const row_h_px_u32 = if (rows_mismatch)
                            fallback_row_h
                        else
                            rowHeightPxFromClient(hwnd, rows_for_layout, fallback_row_h);
                        const row_h_px: i32 = @intCast(@as(i32, @intCast(row_h_px_u32)));
                        if (row_h_px_u32 != fallback_row_h or rows_mismatch) {
                            applog.appLog(
                                "[win] WM_PAINT(row) row_h_px adjust rows={d} client_h={d} fallback={d} row_h={d}\n",
                                .{ rows_for_layout, client.bottom, fallback_row_h, row_h_px_u32 },
                            );
                        }

                        // Use persistent buffer to avoid per-frame alloc/free.
                        const present_rects = &app.wm_paint_present_rects;
                        present_rects.clearRetainingCapacity();

                        // Build full-width present_rects initially.
                        // After the row drawing loop, we may replace with cursor rects if no content changed.
                        // Add content_y_offset for ext_tabline (present_rects are in screen coords)
                        const present_y_offset: i32 = if (content_y_offset) |off| @intCast(off) else 0;
                        if (rows_to_draw.items.len != 0) {
                            // Build full-width row rects.
                            // rows_to_draw is already sorted+deduplicated from the normalize step above.
                            var span_start: u32 = rows_to_draw.items[0];
                            var span_end: u32 = span_start + 1;

                            var ispan: usize = 1;
                            while (ispan < rows_to_draw.items.len) : (ispan += 1) {
                                const r = rows_to_draw.items[ispan];
                                if (r == span_end) {
                                    span_end += 1;
                                } else {
                                    const top0: i32 = present_y_offset + @as(i32, @intCast(span_start)) * row_h_px;
                                    const bot0: i32 = present_y_offset + @as(i32, @intCast(span_end)) * row_h_px;

                                    const rc0: c.RECT = .{
                                        .left = 0,
                                        .top = top0,
                                        .right = client.right,
                                        .bottom = bot0,
                                    };
                                    present_rects.append(app.alloc, rc0) catch {};

                                    span_start = r;
                                    span_end = r + 1;
                                }
                            }

                            // last span
                            {
                                const top0: i32 = present_y_offset + @as(i32, @intCast(span_start)) * row_h_px;
                                const bot0: i32 = present_y_offset + @as(i32, @intCast(span_end)) * row_h_px;

                                const rc0: c.RECT = .{
                                    .left = 0,
                                    .top = top0,
                                    .right = client.right,
                                    .bottom = bot0,
                                };
                                present_rects.append(app.alloc, rc0) catch {};
                            }
                        } else if (dirty != null) {
                            present_rects.append(app.alloc, dirty.?) catch {};
                        }

                        // Add bottom gutter rect if client area extends beyond the grid area.
                        // This ensures the gutter is properly cleared in all swapchain buffers
                        // during partial present, preventing ghost artifacts from stale content.
                        // Use the actual maximum y coordinate from present_rects to handle cases
                        // where app.rows is stale (e.g., after font/linespace changes).
                        if (present_rects.items.len != 0) {
                            var max_y: i32 = 0;
                            for (present_rects.items) |r| {
                                if (r.bottom > max_y) max_y = r.bottom;
                            }
                            if (max_y > 0 and max_y < client.bottom) {
                                const gutter_rc: c.RECT = .{
                                    .left = 0,
                                    .top = max_y,
                                    .right = client.right,
                                    .bottom = client.bottom,
                                };
                                present_rects.append(app.alloc, gutter_rc) catch {};
                            }
                        }

                        // Always include explicit paint rects (cursor damage) in present set.
                        if (paint_rects_snapshot.items.len != 0) {
                            present_rects.appendSlice(app.alloc, paint_rects_snapshot.items) catch {};
                        }

                        if (cursor_rc_opt) |cr| {
                            present_rects.append(app.alloc, cr) catch {};
                        }

                        // Remove empty / duplicate / fully-contained rects to avoid redundant copies.
                        if (present_rects.items.len != 0) {
                            var i: usize = 0;
                            while (i < present_rects.items.len) {
                                const r = present_rects.items[i];
                                if (r.right <= r.left or r.bottom <= r.top) {
                                    present_rects.items[i] = present_rects.items[present_rects.items.len - 1];
                                    present_rects.items.len -= 1;
                                    continue;
                                }
                                i += 1;
                            }

                            i = 0;
                            while (i < present_rects.items.len) {
                                const r = present_rects.items[i];
                                var remove = false;
                                var j: usize = 0;
                                while (j < present_rects.items.len) : (j += 1) {
                                    if (i == j) continue;
                                    const o = present_rects.items[j];
                                    if (o.left <= r.left and o.top <= r.top and o.right >= r.right and o.bottom >= r.bottom) {
                                        remove = true;
                                        break;
                                    }
                                }
                                if (remove) {
                                    present_rects.items[i] = present_rects.items[present_rects.items.len - 1];
                                    present_rects.items.len -= 1;
                                    continue;
                                }
                                i += 1;
                            }
                        }

                        // Clamp present rects to client bounds (for Present1 dirty rects).
                        if (present_rects.items.len != 0) {
                            const max_r: i32 = client.right;
                            const max_b: i32 = client.bottom;
                            var i: usize = 0;
                            while (i < present_rects.items.len) {
                                var r = present_rects.items[i];
                                if (r.left < 0) r.left = 0;
                                if (r.top < 0) r.top = 0;
                                if (r.right > max_r) r.right = max_r;
                                if (r.bottom > max_b) r.bottom = max_b;
                                if (r.right <= r.left or r.bottom <= r.top) {
                                    present_rects.items[i] = present_rects.items[present_rects.items.len - 1];
                                    present_rects.items.len -= 1;
                                    continue;
                                }
                                present_rects.items[i] = r;
                                i += 1;
                            }
                        }

                        // Ensure cursor rect is always included for Present1 (drawn after copy).
                        if (cursor_rc_opt) |cr_raw| {
                            var cr = cr_raw;
                            if (cr.left < 0) cr.left = 0;
                            if (cr.top < 0) cr.top = 0;
                            if (cr.right > client.right) cr.right = client.right;
                            if (cr.bottom > client.bottom) cr.bottom = client.bottom;
                            if (cr.right > cr.left and cr.bottom > cr.top) {
                                var exists = false;
                                var contained = false;
                                var i: usize = 0;
                                while (i < present_rects.items.len) : (i += 1) {
                                    const r = present_rects.items[i];
                                    if (r.left == cr.left and r.top == cr.top and r.right == cr.right and r.bottom == cr.bottom) {
                                        exists = true;
                                        break;
                                    }
                                    // Check if cursor is contained by this rect
                                    if (r.left <= cr.left and r.top <= cr.top and r.right >= cr.right and r.bottom >= cr.bottom) {
                                        contained = true;
                                    }
                                }
                                if (!exists) {
                                    present_rects.append(app.alloc, cr) catch {};
                                    applog.appLog("[win] WM_PAINT(row) cursor added to present_rects (contained={d})\n", .{@intFromBool(contained)});
                                } else {
                                    applog.appLog("[win] WM_PAINT(row) cursor already in present_rects\n", .{});
                                }
                            } else {
                                applog.appLog("[win] WM_PAINT(row) cursor rect invalid after clamp\n", .{});
                            }
                        }

                        // --- DEBUG: show real present rects (rcPaint is NOT reliable in union cases) ---
                        if (applog.isEnabled()) {
                            applog.appLog(
                                "[win] WM_PAINT(row) present_rects={d} (rows_to_draw={d})\n",
                                .{ present_rects.items.len, rows_to_draw.items.len },
                            );

                            if (present_rects.items.len != 0) {
                                var u: c.RECT = present_rects.items[0];
                                var j: usize = 1;
                                while (j < present_rects.items.len) : (j += 1) {
                                    u = unionRect(u, present_rects.items[j]);
                                }

                                applog.appLog(
                                    "[win]   present_union=({d},{d})-({d},{d})\n",
                                    .{ u.left, u.top, u.right, u.bottom },
                                );

                                var k: usize = 0;
                                while (k < present_rects.items.len) : (k += 1) {
                                    const r = present_rects.items[k];
                                    applog.appLog(
                                        "[win]   present[{d}]=({d},{d})-({d},{d})\n",
                                        .{ k, r.left, r.top, r.right, r.bottom },
                                    );
                                }
                            } else {
                                applog.appLog("[win]   present_rects is EMPTY\n", .{});
                            }

                            if (cursor_rc_opt) |cr| {
                                applog.appLog(
                                    "[win]   cursor_rc=({d},{d})-({d},{d})\n",
                                    .{ cr.left, cr.top, cr.right, cr.bottom },
                                );
                            }
                        }

                        // row-setup drawEx is the ONLY drawEx in row-mode WM_PAINT.
                        // When did_need_seed is true, we must NOT preserve old back buffer contents,
                        // so integrate "seed-clear" behavior here (no extra drawEx).
                        app.mu.lock();
                        const seed_clear = did_need_seed or app.seed_clear_pending;
                        if (seed_clear) {
                            app.seed_clear_pending = false;
                            // Only clear row vertex data for rows BEYOND the current grid size.
                            // This prevents stale rows from being drawn in the gutter area when
                            // the grid has shrunk (e.g., after font/linespace change).
                            // IMPORTANT: Do NOT clear rows within the current grid - they contain
                            // valid data that should be drawn.
                            const current_rows = app.rows;
                            var clear_idx: usize = current_rows;
                            while (clear_idx < app.row_verts.items.len) : (clear_idx += 1) {
                                app.row_verts.items[clear_idx].verts.clearRetainingCapacity();
                                app.row_verts.items[clear_idx].gen +%= 1;
                            }
                            // Only unset validity for rows beyond current grid
                            clear_idx = current_rows;
                            while (clear_idx < app.row_valid.bit_length) : (clear_idx += 1) {
                                if (app.row_valid.isSet(clear_idx)) {
                                    app.row_valid.unset(clear_idx);
                                    if (app.row_valid_count > 0) {
                                        app.row_valid_count -= 1;
                                    }
                                }
                            }
                        }
                        app.mu.unlock();

                        // During seed mode (seed_pending), always clear the back buffer to ensure
                        // all swapchain buffers are properly cleared as they rotate. This prevents
                        // ghost artifacts in the gutter area when grid shrinks.
                        const preserve_back = !seed_clear and !seed_pending_snapshot;
                        applog.appLog(
                            "[win] WM_PAINT(row) setup preserve_back={d} did_need_seed={d} seed_pending={d} seed_clear={d}\n",
                            .{
                                @as(u32, @intFromBool(preserve_back)),
                                @as(u32, @intFromBool(did_need_seed)),
                                @as(u32, @intFromBool(seed_pending_snapshot)),
                                @as(u32, @intFromBool(seed_clear)),
                            },
                        );

                        g.drawEx(
                            &[_]core.Vertex{},
                            &[_]core.Vertex{},
                            null,
                            .{
                                .present = false,
                                .preserve_on_null_dirty = preserve_back,
                                .content_width = content_width,
                                .content_y_offset = content_y_offset,
                                .tabbar_bg_color = tabbar_bg_color,
                            },
                        ) catch |e| {
                            applog.appLog("gpu.drawEx(row-setup) failed: {any}\n", .{e});
                        };
                        applog.appLog(
                            "[win] WM_PAINT(row) seed_state rows={d} row_valid={d} rows_to_draw={d} row_verts_len={d}\n",
                            .{ rows_snapshot, row_valid_count_snapshot, rows_to_draw.items.len, row_verts_len },
                        );

                        var drawn_rows: u32 = 0;
                        var skipped_empty: u32 = 0;
                        var first_empty_row: ?u32 = null;
                        // log
                        var log_vb_upload_rows: u32 = 0;
                        var log_vb_upload_rows_bytes: u64 = 0;
                        // perf timing
                        var log_vb_upload_ns: i128 = 0;
                        var log_draw_vb_ns: i128 = 0;

                        var ctx_ptr: ?*c.ID3D11DeviceContext = null;
                        var rs_set_sc_fn: ?*const fn (?*c.ID3D11DeviceContext, c.UINT, [*c]const c.D3D11_RECT) callconv(.c) void = null;

                        {
                            const ctx = g.ctx orelse null;
                            if (ctx == null) {
                                applog.appLog("gpu ctx null in WM_PAINT(row)\n", .{});
                            } else {
                                ctx_ptr = ctx.?;
                                const ctx_vtbl = ctx.?.*.lpVtbl;
                                rs_set_sc_fn = ctx_vtbl.*.RSSetScissorRects orelse null;

                                app.mu.lock();
                                defer app.mu.unlock();

                                const use_row_scissor = !seed_pending_snapshot;
                                if (!use_row_scissor) {
                                    applog.appLog("[win] WM_PAINT(row) seed_pending: scissor=full\n", .{});
                                    if (rs_set_sc_fn) |f| {
                                        // Clamp to content width for "always" scrollbar mode
                                        const scissor_right: c.LONG = if (content_width) |cw| @intCast(cw) else client.right;
                                        var sc_full: c.D3D11_RECT = .{
                                            .left = 0,
                                            .top = 0,
                                            .right = scissor_right,
                                            .bottom = client.bottom,
                                        };
                                        f(ctx.?, 1, &sc_full);
                                    }
                                }

                                var i: usize = 0;
                                while (i < rows_to_draw.items.len) : (i += 1) {
                                    const row = rows_to_draw.items[i];
                                    if (row >= app.row_verts.items.len) {
                                        skipped_empty += 1;
                                        continue;
                                    }

                                    var rv = &app.row_verts.items[@intCast(row)];
                                    const src = rv.verts.items;
                                    if (src.len == 0) {
                                        skipped_empty += 1;
                                        if (first_empty_row == null) {
                                            first_empty_row = @intCast(row);
                                        }
                                        continue;
                                    }

                                    if (rv.uploaded_gen != rv.gen or rv.vb == null or rv.vb_bytes < src.len * @sizeOf(core.Vertex)) {
                                        const log_need_bytes_row: usize = src.len * @sizeOf(core.Vertex);

                                        const t_upload_start = if (log_enabled) std.time.nanoTimestamp() else 0;

                                        g.ensureExternalVertexBuffer(&rv.vb, &rv.vb_bytes, log_need_bytes_row) catch |e| {
                                            applog.appLog("ensureExternalVertexBuffer failed row={d}: {any}\n", .{ row, e });
                                            continue;
                                        };
                                        g.uploadVertsToVB(rv.vb.?, src) catch |e| {
                                            applog.appLog("uploadVertsToVB failed row={d}: {any}\n", .{ row, e });
                                            continue;
                                        };

                                        if (log_enabled) {
                                            log_vb_upload_ns += std.time.nanoTimestamp() - t_upload_start;
                                        }

                                        // log: count successful uploads
                                        log_vb_upload_rows += 1;
                                        log_vb_upload_rows_bytes += @as(u64, @intCast(log_need_bytes_row));

                                        rv.uploaded_gen = rv.gen;
                                    }

                                    // Add content_y_offset for ext_tabline (scissor is in screen coords)
                                    const y_offset: i32 = if (content_y_offset) |off| @intCast(off) else 0;
                                    const top: i32 = y_offset + @as(i32, @intCast(row)) * row_h_px;
                                    const bottom: i32 = top + row_h_px;
                                    const row_rc: c.RECT = .{ .left = 0, .top = top, .right = client.right, .bottom = bottom };

                                    if (use_row_scissor) {
                                        if (rs_set_sc_fn) |f| {
                                            // Clamp to content width for "always" scrollbar mode
                                            const scissor_right: c.LONG = if (content_width) |cw| @min(row_rc.right, @as(c.LONG, @intCast(cw))) else row_rc.right;
                                            var sc: c.D3D11_RECT = .{
                                                .left = row_rc.left,
                                                .top = row_rc.top,
                                                .right = scissor_right,
                                                .bottom = row_rc.bottom,
                                            };
                                            f(ctx.?, 1, &sc);
                                        }
                                    }

                                    const t_draw_start = if (log_enabled) std.time.nanoTimestamp() else 0;

                                    g.drawVB(rv.vb.?, src.len) catch |e| {
                                        applog.appLog("drawVB failed row={d}: {any}\n", .{ row, e });
                                        continue;
                                    };

                                    if (log_enabled) {
                                        log_draw_vb_ns += std.time.nanoTimestamp() - t_draw_start;
                                    }

                                    drawn_rows += 1;
                                }

                                applog.appLog(
                                    "[win] WM_PAINT(row-vb) drawn_rows={d} skipped_empty={d} rows_to_draw={d}\n",
                                    .{ drawn_rows, skipped_empty, rows_to_draw.items.len },
                                );
                                if (first_empty_row) |erow| {
                                    applog.appLog(
                                        "[win] WM_PAINT(row-vb) WARN empty_row={d} rows={d} row_verts_len={d}\n",
                                        .{ erow, rows_snapshot, row_verts_len },
                                    );
                                }
                            }
                        }

                        // --- log: per-frame upload counts ---
                        var log_vb_upload_cursor: u32 = 0;
                        var log_vb_upload_cursor_bytes: u64 = 0;

                        if (cursor_verts_snapshot.len != 0) {
                            // Ensure + upload cursor VB only when cursor verts changed (rendered in Present step).
                            const need_bytes: usize = cursor_verts_snapshot.len * @sizeOf(core.Vertex);
                            g.ensureExternalVertexBuffer(&app.cursor_vb, &app.cursor_vb_bytes, need_bytes) catch |e| {
                                applog.appLog("ensureExternalVertexBuffer failed cursor: {any}\n", .{e});
                            };

                            if (app.cursor_vb) |vb| {
                                // Always upload cursor VB each frame to avoid race condition:
                                // cursor_verts_snapshot is taken at WM_PAINT start, but onVerticesPartial
                                // callback may arrive during paint with new cursor data. The generation
                                // check could pass with stale snapshot data. 288 bytes/frame is negligible.
                                g.uploadVertsToVB(vb, cursor_verts_snapshot) catch |e| {
                                    applog.appLog("uploadVertsToVB failed cursor: {any}\n", .{e});
                                };

                                log_vb_upload_cursor += 1;
                                log_vb_upload_cursor_bytes += @as(u64, @intCast(need_bytes));
                            }
                        }

                        if (cursor_verts_snapshot.len != 0) {
                            if (app.cursor_vb) |vb| {
                                if (ctx_ptr != null) {
                                    if (rs_set_sc_fn) |f| {
                                        // Clamp to content width for "always" scrollbar mode
                                        const scissor_right: c.LONG = if (content_width) |cw| @as(c.LONG, @intCast(cw)) else client.right;
                                        if (cursor_rc_opt) |cr| {
                                            // cursor_rc_opt is already transformed to viewport coords
                                            var sc: c.D3D11_RECT = .{
                                                .left = cr.left,
                                                .top = cr.top,
                                                .right = @min(cr.right, scissor_right),
                                                .bottom = cr.bottom,
                                            };
                                            f(ctx_ptr, 1, &sc);
                                        } else {
                                            var sc: c.D3D11_RECT = .{
                                                .left = 0,
                                                .top = 0,
                                                .right = scissor_right,
                                                .bottom = client.bottom,
                                            };
                                            f(ctx_ptr, 1, &sc);
                                        }
                                    }

                                    // Only draw cursor if blink state is visible
                                    if (app.cursor_blink_state) {
                                        applog.appLog("[win] WM_PAINT(row) drawing cursor verts={d}\n", .{cursor_verts_snapshot.len});
                                        g.drawVB(vb, cursor_verts_snapshot.len) catch |e| {
                                            applog.appLog("drawVB failed cursor: {any}\n", .{e});
                                        };
                                    } else {
                                        applog.appLog("[win] WM_PAINT(row) cursor hidden (blink off)\n", .{});
                                        // Redraw cursor row to clear cursor from back_tex
                                        if (cursor_rc_opt) |cr| {
                                            const y_offset_i32: i32 = if (content_y_offset) |off| @intCast(off) else 0;
                                            if (row_h_px > 0) {
                                                const cursor_row: usize = @intCast(@divFloor(@max(0, cr.top - y_offset_i32), row_h_px));
                                                applog.appLog("[win] WM_PAINT(row) redrawing cursor_row={d} to clear\n", .{cursor_row});
                                                if (cursor_row < app.row_verts.items.len) {
                                                    const rv = &app.row_verts.items[cursor_row];
                                                    applog.appLog("[win] WM_PAINT(row) cursor_row rv.vb={} src.len={d}\n", .{ rv.vb != null, rv.verts.items.len });
                                                    if (rv.vb) |row_vb| {
                                                        const src = rv.verts.items;
                                                        if (src.len > 0) {
                                                            // Set scissor to row
                                                            const top_px: i32 = y_offset_i32 + @as(i32, @intCast(cursor_row)) * row_h_px;
                                                            const bottom_px: i32 = top_px + row_h_px;
                                                            const scissor_right: c.LONG = if (content_width) |cw| @as(c.LONG, @intCast(cw)) else client.right;
                                                            var sc: c.D3D11_RECT = .{
                                                                .left = 0,
                                                                .top = top_px,
                                                                .right = scissor_right,
                                                                .bottom = bottom_px,
                                                            };
                                                            if (rs_set_sc_fn) |f| {
                                                                f(ctx_ptr, 1, &sc);
                                                            }
                                                            applog.appLog("[win] WM_PAINT(row) drawing cursor_row={d} verts={d}\n", .{ cursor_row, src.len });
                                                            g.drawVB(row_vb, src.len) catch |e| {
                                                                applog.appLog("drawVB failed cursor_row clear: {any}\n", .{e});
                                                            };
                                                        }
                                                    }
                                                } else {
                                                    applog.appLog("[win] WM_PAINT(row) cursor_row={d} out of range (len={d})\n", .{ cursor_row, app.row_verts.items.len });
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        } else {
                            applog.appLog("[win] WM_PAINT(row) NO cursor (snapshot empty)\n", .{});
                        }

                        if (force_full_rows and skipped_empty != 0) {
                            applog.appLog(
                                "[win] WM_PAINT(row) WARN skip_present missing_rows={d} rows={d} row_verts_len={d}\n",
                                .{ skipped_empty, rows_snapshot, row_verts_len },
                            );
                        }

                        var log_present_rects_area_px: u64 = 0;

                        // --- log: present_rects area (sum of rect areas) ---
                        if (present_rects.items.len != 0) {
                            var pi: usize = 0;
                            while (pi < present_rects.items.len) : (pi += 1) {
                                const r = present_rects.items[pi];
                                const w_i32: i32 = r.right - r.left;
                                const h_i32: i32 = r.bottom - r.top;
                                if (w_i32 > 0 and h_i32 > 0) {
                                    log_present_rects_area_px +=
                                        @as(u64, @intCast(w_i32)) * @as(u64, @intCast(h_i32));
                                }
                            }
                        }

                        if (applog.isEnabled()) {
                            applog.appLog(
                                "[win] WM_PAINT(row-frame) drawn_rows={d} rows_to_draw={d} present_rects={d} present_area_px={d} vb_upload_rows={d} vb_upload_rows_bytes={d} vb_upload_cursor={d} vb_upload_cursor_bytes={d}\n",
                                .{
                                    drawn_rows, // NOTE: variable within row-vb block. See note below
                                    rows_to_draw.items.len,
                                    present_rects.items.len,
                                    log_present_rects_area_px,
                                    log_vb_upload_rows,
                                    log_vb_upload_rows_bytes,
                                    log_vb_upload_cursor,
                                    log_vb_upload_cursor_bytes,
                                },
                            );
                        }

                        if (log_enabled) {
                            t_present_start_ns = std.time.nanoTimestamp();
                        }

                        var layout_ok: bool = true;
                        var rows_current: u32 = 0;
                        app.mu.lock();
                        layout_ok = app.row_layout_gen == row_layout_gen_snapshot;
                        rows_current = app.rows;
                        app.mu.unlock();

                        const allow_present = blk: {
                            // When seed_clear is true, we must present to sync the cleared back buffer
                            // to all swapchain buffers. Skip other checks - the cleared state must be
                            // presented to prevent ghost artifacts in gutter areas.
                            if (seed_clear) break :blk true;

                            // During seed mode with preserve_back=false, we MUST present to ensure
                            // all swapchain buffers get the cleared state. Without this, some buffers
                            // may retain stale gutter content causing ghost artifacts.
                            if (seed_pending_snapshot and !preserve_back) break :blk true;

                            // Never present if layout changed after snapshot.
                            if (!layout_ok) break :blk false;
                            if (rows_current != rows_snapshot) break :blk false;

                            // Never present until core has provided a stable row count.
                            if (effective_rows == 0) break :blk false;

                            if (seed_pending_snapshot) {
                                if (rows_mismatch) {
                                    if (rows_to_draw.items.len != 0 and skipped_empty == 0) break :blk true;
                                    break :blk false;
                                }
                                // Require a complete seed: all rows must have been received.
                                if (effective_row_valid_count == effective_rows) {
                                    if (skipped_empty != 0) break :blk false;
                                    if (rows_to_draw.items.len != effective_rows) break :blk false;
                                    break :blk true;
                                }

                                break :blk false;
                            }

                            if (force_full_rows and skipped_empty != 0) break :blk false;
                            if (force_full_rows and rows_to_draw.items.len != effective_rows) break :blk false;
                            break :blk true;
                        };

                        if (allow_present) {
                            // Draw scrollbar overlay before present
                            if (app.config.scrollbar.enabled and app.scrollbar_alpha > 0.001) {
                                var scrollbar_verts: [12]core.Vertex = undefined;
                                const scrollbar_vert_count = generateScrollbarVertices(app, client.right, client.bottom, &scrollbar_verts);
                                if (scrollbar_vert_count > 0) {
                                    // Reset viewport and scissor to full screen for scrollbar
                                    // (needed when content_width is smaller than window width)
                                    g.setFullViewport();

                                    // Ensure scrollbar VB
                                    const need_bytes = scrollbar_vert_count * @sizeOf(core.Vertex);
                                    g.ensureExternalVertexBuffer(&app.scrollbar_vb, &app.scrollbar_vb_bytes, need_bytes) catch |e| {
                                        applog.appLog("ensureExternalVertexBuffer scrollbar failed: {any}\n", .{e});
                                    };

                                    if (app.scrollbar_vb) |vb| {
                                        g.uploadVertsToVB(vb, scrollbar_verts[0..scrollbar_vert_count]) catch |e| {
                                            applog.appLog("uploadVertsToVB scrollbar failed: {any}\n", .{e});
                                        };
                                        g.drawVB(vb, scrollbar_vert_count) catch |e| {
                                            applog.appLog("drawVB scrollbar failed: {any}\n", .{e});
                                        };
                                    }
                                }
                            }

                            // When seed_clear is true, the back buffer was just cleared.
                            // We must do a full present to sync the cleared state to all swapchain buffers,
                            // otherwise areas not covered by partial present rects may show stale content.
                            // Also force full present when scrollbar is visible to avoid knob ghosting.
                            const scrollbar_needs_full = app.scrollbar_alpha > 0.001;
                            const force_full_present = force_full_rows or (seed_pending_snapshot and !rows_mismatch) or seed_clear or scrollbar_needs_full;
                            const present_rects_slice: []const c.RECT =
                                if (force_full_present) &[_]c.RECT{} else present_rects.items;

                            g.presentFromBackRectsWithCursorNoResize(
                                present_rects_slice,
                                app.cursor_vb,
                                cursor_verts_snapshot.len,
                                cursor_rc_opt,
                                force_full_present,
                            ) catch |e| {
                                applog.appLog("presentFromBackRectsWithCursorNoResize failed: {any}\n", .{e});
                            };

                            if (seed_pending_snapshot and effective_rows != 0 and effective_row_valid_count == effective_rows) {
                                app.mu.lock();
                                app.seed_pending = false;
                                app.paint_full = true;
                                app.paint_rects.clearRetainingCapacity();
                                app.seed_clear_pending = true;
                                app.mu.unlock();
                                applog.appLog(
                                    "[win] WM_PAINT(row) seed_complete rows={d} row_valid={d} -> request repaint\n",
                                    .{ effective_rows, effective_row_valid_count },
                                );
                                _ = c.InvalidateRect(hwnd, null, c.FALSE);
                            }
                        } else {
                            var resize_age_ms: i64 = -1;
                            const last_resize_ns = app.last_resize_ns;
                            if (last_resize_ns != 0) {
                                const now_ns = std.time.nanoTimestamp();
                                const diff_ns = now_ns - last_resize_ns;
                                if (diff_ns > 0) {
                                    resize_age_ms = @intCast(@divTrunc(diff_ns, 1_000_000));
                                } else {
                                    resize_age_ms = 0;
                                }
                            }
                            applog.appLog(
                                "[win] WM_PAINT(row) skip_present seed_pending={d} rows={d} rows_cur={d} row_valid={d} rows_to_draw={d} skipped_empty={d} row_verts_len={d} force_full_rows={d} layout_gen={d} layout_ok={d} rows_mismatch={d} resize_age_ms={d}\n",
                                .{
                                    @as(u32, @intFromBool(seed_pending_snapshot)),
                                    effective_rows,
                                    rows_current,
                                    effective_row_valid_count,
                                    rows_to_draw.items.len,
                                    skipped_empty,
                                    row_verts_len,
                                    @as(u32, @intFromBool(force_full_rows)),
                                    row_layout_gen_snapshot,
                                    @as(u32, @intFromBool(layout_ok)),
                                    @as(u32, @intFromBool(rows_mismatch)),
                                    resize_age_ms,
                                },
                            );
                        }

                        if (log_enabled) {
                            const t_done_ns: i128 = std.time.nanoTimestamp();
                            const row_us: u64 = @intCast(@divTrunc(@max(0, t_present_start_ns - t_row_start_ns), 1000));
                            const present_us: u64 = @intCast(@divTrunc(@max(0, t_done_ns - t_present_start_ns), 1000));
                            const total_us: u64 = row_us + present_us;
                            const vb_upload_us: u64 = @intCast(@divTrunc(@max(0, log_vb_upload_ns), 1000));
                            const draw_vb_us: u64 = @intCast(@divTrunc(@max(0, log_draw_vb_ns), 1000));
                            applog.appLog(
                                "[perf] row_mode_ui rows={d} vb_upload_us={d} draw_vb_us={d} row_us={d} present_us={d} total_us={d}\n",
                                .{ rows_to_draw.items.len, vb_upload_us, draw_vb_us, row_us, present_us, total_us },
                            );
                        }
                    }
                }

                // Update IME preedit overlay (separate popup window)
                updateImePreeditOverlay(hwnd, app);

                // Tabline is now rendered via D3D11 texture (see renderTablineToD3D call before gpu rendering)
            }

            return 0;
        },

        c.WM_SIZE => {
            if (getApp(hwnd)) |app| {
                // 1) GPU state transition must not race with WM_PAINT (which holds app.mu).
                app.mu.lock();
                app.last_resize_ns = std.time.nanoTimestamp();
                app.need_full_seed.store(true, .seq_cst);
                app.seed_pending = true;
                app.seed_clear_pending = true;
                app.row_valid_count = 0;
                if (app.row_valid.bit_length != 0) {
                    app.row_valid.unsetAll();
                }
                // Always keep rows/cols in sync with current client size on resize.
                updateRowsColsFromClientForce(hwnd, app);
                app.mu.unlock();

                var rc: c.RECT = undefined;
                _ = c.GetClientRect(hwnd, &rc);

                applog.appLog(
                    "[win] WM_SIZE wParam={d} client=({d},{d})-({d},{d}) need_full_seed=1 atlas={s} gpu={s} resize_ns={d}\n",
                    .{
                        @as(u32, @intCast(wParam)),
                        rc.left, rc.top, rc.right, rc.bottom,
                        if (app.atlas != null) "Y" else "N",
                        if (app.renderer != null) "Y" else "N",
                        app.last_resize_ns,
                    },
                );

                // 2) core layout update must be outside lock (can re-enter via callbacks).
                updateLayoutToCore(hwnd, app);

                // 3) Resize tabline child window if present
                if (app.tabline_state.hwnd) |tabline_hwnd| {
                    // Use HWND_TOP to ensure tabline stays above content_hwnd
                    // (some environments may have Z-order issues with SWP_NOZORDER)
                    _ = c.SetWindowPos(
                        tabline_hwnd,
                        c.HWND_TOP,
                        0,
                        0,
                        rc.right,
                        TablineState.TAB_BAR_HEIGHT,
                        0,  // No SWP_NOZORDER - explicitly set Z-order
                    );
                }

                // 4) Trigger D3D11 resize
                // When ext_tabline is enabled, D3D11 renders to parent window (no content_hwnd)
                app.mu.lock();
                if (app.renderer) |*g| {
                    g.resize() catch {};
                }
                app.mu.unlock();

                // 5) repaint
                _ = c.InvalidateRect(hwnd, null, 0);
                app.paint_full = true;
                app.paint_rects.clearRetainingCapacity();
            }
            return 0;
        },

        WM_APP_ATLAS_ENSURE_GLYPH => {
            if (getApp(hwnd)) |app| {
                const scalar: u32 = @intCast(wParam);

                // lParam is signed (isize). Preserve bits when converting to pointer.
                const out_entry_ptr_bits: usize = @as(usize, @bitCast(lParam));
                const out_entry: *core.GlyphEntry = @ptrFromInt(out_entry_ptr_bits);

                // This handler is always executed on UI thread.
                // Do NOT take app.mu here: SendMessageW can re-enter while WM_PAINT holds app.mu.
                if (app.atlas) |*a| {
                    const e = a.atlasEnsureGlyphEntry(scalar) catch |err| {
                        applog.appLog("WM_APP_ATLAS_ENSURE_GLYPH: atlasEnsureGlyphEntry ERROR: {any}", .{err});
                        return 0;
                    };
                    out_entry.* = e;

                    applog.appLog("WM_APP_ATLAS_ENSURE_GLYPH: ok scalar={d} out_entry_ptr=0x{x} uv_min=({d:.6},{d:.6}) uv_max=({d:.6},{d:.6})", .{
                        scalar,
                        out_entry_ptr_bits,
                        e.uv_min[0], e.uv_min[1],
                        e.uv_max[0], e.uv_max[1],
                    });

                    return 1;
                }

                applog.appLog("WM_APP_ATLAS_ENSURE_GLYPH: renderer is null", .{});
                return 0;
            }
            return 0;
        },

        WM_APP_CREATE_EXTERNAL_WINDOW => {
            applog.appLog("[win] WM_APP_CREATE_EXTERNAL_WINDOW received\n", .{});
            if (getApp(hwnd)) |app| {
                // Process all pending external window requests
                app.mu.lock();
                const pending = app.pending_external_windows.toOwnedSlice(app.alloc) catch {
                    app.mu.unlock();
                    return 0;
                };
                app.mu.unlock();

                for (pending) |req| {
                    createExternalWindowOnUIThread(app, req);
                }
                app.alloc.free(pending);
            }
            return 0;
        },

        WM_APP_CURSOR_GRID_CHANGED => {
            applog.appLog("[win] WM_APP_CURSOR_GRID_CHANGED received grid_id={d}\n", .{wParam});
            if (getApp(hwnd)) |app| {
                const grid_id: i64 = @bitCast(wParam);

                app.mu.lock();
                const last_grid = app.last_cursor_grid;
                const ext_hwnd = if (app.external_windows.get(grid_id)) |ext_win| ext_win.hwnd else null;

                // Check if this is actually a grid change (not just same grid)
                const is_grid_change = (last_grid != grid_id);

                // Update last cursor grid
                app.last_cursor_grid = grid_id;
                app.mu.unlock();

                // Only activate windows on actual grid changes
                if (!is_grid_change) {
                    applog.appLog("[win] cursor stayed on same grid_id={d}, no activation change\n", .{grid_id});
                    return 0;
                }

                if (ext_hwnd) |eh| {
                    // Cursor moved to external grid - activate that window
                    _ = c.SetForegroundWindow(eh);
                    applog.appLog("[win] activated external window for grid_id={d}\n", .{grid_id});
                } else {
                    // Cursor moved to main grid - activate main window
                    _ = c.SetForegroundWindow(hwnd);
                    _ = c.InvalidateRect(hwnd, null, c.FALSE);
                    applog.appLog("[win] activated main window (cursor on grid_id={d})\n", .{grid_id});
                }
            }
            return 0;
        },

        WM_APP_CLOSE_EXTERNAL_WINDOW => {
            const grid_id: i64 = @bitCast(wParam);
            applog.appLog("[win] WM_APP_CLOSE_EXTERNAL_WINDOW received grid_id={d}\n", .{grid_id});
            if (getApp(hwnd)) |app| {
                closeExternalWindowOnUIThread(app, grid_id);
            }
            return 0;
        },

        WM_APP_MSG_SHOW => {
            applog.appLog("[win] WM_APP_MSG_SHOW received\n", .{});
            if (getApp(hwnd)) |app| {
                // Process all pending messages
                app.mu.lock();
                const pending = app.pending_messages.toOwnedSlice(app.alloc) catch {
                    app.mu.unlock();
                    return 0;
                };
                app.mu.unlock();

                // Process each pending message individually based on its view_type
                for (pending) |req| {
                    const kind_str = req.kind[0..req.kind_len];

                    // Build DisplayMessage for this request
                    var dm = DisplayMessage{};
                    @memcpy(dm.text[0..req.text_len], req.text[0..req.text_len]);
                    dm.text_len = req.text_len;
                    @memcpy(dm.kind[0..req.kind_len], req.kind[0..req.kind_len]);
                    dm.kind_len = req.kind_len;
                    dm.hl_id = req.hl_id;
                    dm.view_type = req.view_type;
                    dm.timeout = req.timeout;

                    // Process based on view_type (each message is routed individually)
                    switch (req.view_type) {
                        .mini => {
                            // Show in mini window
                            const text = dm.text[0..dm.text_len];
                            updateMiniText(app, .showmode, text);
                            updateMiniWindows(app);

                            // Set auto-hide timer based on timeout (use separate timer for mini)
                            _ = c.KillTimer(hwnd, TIMER_MINI_AUTOHIDE);
                            if (dm.timeout > 0) {
                                const timeout_ms: c.UINT = @intFromFloat(dm.timeout * 1000);
                                _ = c.SetTimer(hwnd, TIMER_MINI_AUTOHIDE, timeout_ms, null);
                            }
                        },
                        .confirm => {
                            // Confirm messages: clear display stack and show
                            if (req.replace_last != 0 or std.mem.eql(u8, kind_str, "return_prompt")) {
                                app.display_messages.clearRetainingCapacity();
                            }
                            app.display_messages.append(app.alloc, dm) catch {};
                            showMessageWindowOnUIThread(app, dm);
                            // Confirm dialogs don't auto-hide (only kill message window timer, not mini)
                            _ = c.KillTimer(hwnd, TIMER_MSG_AUTOHIDE);
                        },
                        .ext_float => {
                            // Floating window: add to display stack
                            if (req.replace_last != 0) {
                                app.display_messages.clearRetainingCapacity();
                            }
                            if (req.append != 0 and app.display_messages.items.len > 0) {
                                var last = &app.display_messages.items[app.display_messages.items.len - 1];
                                const append_len = @min(req.text_len, last.text.len - last.text_len);
                                @memcpy(last.text[last.text_len..][0..append_len], req.text[0..append_len]);
                                last.text_len += append_len;
                            } else {
                                app.display_messages.append(app.alloc, dm) catch {};
                                if (app.display_messages.items.len > 5) {
                                    _ = app.display_messages.orderedRemove(0);
                                }
                            }
                            showMessageWindowOnUIThread(app, dm);
                            if (dm.timeout > 0) {
                                _ = c.KillTimer(hwnd, TIMER_MSG_AUTOHIDE);
                                const timeout_ms: c.UINT = @intFromFloat(dm.timeout * 1000);
                                _ = c.SetTimer(hwnd, TIMER_MSG_AUTOHIDE, timeout_ms, null);
                            }
                        },
                        .split => {
                            showMessageWindowOnUIThread(app, dm);
                            _ = c.KillTimer(hwnd, TIMER_MSG_AUTOHIDE);
                        },
                        .notification => {
                            // TODO: Show OS notification
                        },
                        .none => {},
                    }
                }
                app.alloc.free(pending);
            }
            return 0;
        },

        WM_APP_MSG_CLEAR => {
            applog.appLog("[win] WM_APP_MSG_CLEAR received\n", .{});
            if (getApp(hwnd)) |app| {
                // Kill auto-hide timer
                _ = c.KillTimer(hwnd, TIMER_MSG_AUTOHIDE);
                hideMessageWindow(app);
                // Note: Do NOT hide split view on msg_clear.
                // Split view should remain visible until user manually closes it (Esc/q/Enter/Space).
                // This matches noice.nvim's long_message_to_split behavior.
            }
            return 0;
        },

        WM_APP_MINI_UPDATE => {
            const mini_id: MiniWindowId = @enumFromInt(@as(u2, @truncate(wParam)));
            applog.appLog("[win] WM_APP_MINI_UPDATE received: {s}\n", .{@tagName(mini_id)});
            if (getApp(hwnd)) |app| {
                updateMiniWindows(app);
            }
            return 0;
        },

        WM_APP_UPDATE_EXT_FLOAT_POS => {
            if (applog.isEnabled()) applog.appLog("[win] WM_APP_UPDATE_EXT_FLOAT_POS received\n", .{});
            if (getApp(hwnd)) |app| {
                updateExtFloatPositions(app);
            }
            return 0;
        },

        WM_APP_CLIPBOARD_GET => {
            applog.appLog("[win] WM_APP_CLIPBOARD_GET received\n", .{});
            if (getApp(hwnd)) |app| {
                handleClipboardGetOnUIThread(app);
            }
            return 0;
        },

        WM_APP_CLIPBOARD_SET => {
            applog.appLog("[win] WM_APP_CLIPBOARD_SET received\n", .{});
            if (getApp(hwnd)) |app| {
                handleClipboardSetOnUIThread(app);
            }
            return 0;
        },

        WM_APP_SSH_AUTH_PROMPT => {
            applog.appLog("[win] WM_APP_SSH_AUTH_PROMPT received\n", .{});
            if (getApp(hwnd)) |app| {
                handleSSHAuthPromptOnUIThread(app);
            }
            return 0;
        },

        WM_APP_UPDATE_CURSOR_BLINK => {
            if (getApp(hwnd)) |app| {
                updateCursorBlinking(hwnd, app);
            }
            return 0;
        },

        WM_APP_IME_OFF => {
            setIMEOff(hwnd);
            return 0;
        },

        WM_APP_QUIT_REQUESTED => {
            const has_unsaved: c_int = @intCast(wParam);
            if (applog.isEnabled()) applog.appLog("[win] WM_APP_QUIT_REQUESTED: has_unsaved={d}\n", .{has_unsaved});

            // Ignore delayed response if timeout already fired and user chose to wait
            if (getApp(hwnd)) |app| {
                if (app.quit_timeout_fired) {
                    if (applog.isEnabled()) applog.appLog("[win] WM_APP_QUIT_REQUESTED: ignoring - timeout already fired\n", .{});
                    return 0;
                }
            }

            // Cancel timeout timer - Neovim responded in time
            _ = c.KillTimer(hwnd, TIMER_QUIT_TIMEOUT);
            if (getApp(hwnd)) |app| {
                app.quit_pending = false;
            }

            if (has_unsaved != 0) {
                // Show confirmation dialog
                // Note: MessageBox doesn't support custom button text.
                // Using MB_OKCANCEL so "Cancel" matches macOS. "OK" means "Discard and Quit".
                const dialog_msg = std.unicode.utf8ToUtf16LeStringLiteral("You have unsaved changes. Do you want to discard them and quit?");
                const dialog_title = std.unicode.utf8ToUtf16LeStringLiteral("Unsaved Changes");
                const result = c.MessageBoxW(
                    hwnd,
                    dialog_msg,
                    dialog_title,
                    c.MB_OKCANCEL | c.MB_ICONWARNING | c.MB_DEFBUTTON2,
                );

                if (result == c.IDOK) {
                    // User confirmed - force quit
                    if (getApp(hwnd)) |app| {
                        if (app.corep) |corep| {
                            core.zonvie_core_quit_confirmed(corep, 1);
                        }
                    }
                }
                // Cancel - do nothing
            } else {
                // No unsaved buffers - proceed with :qa
                if (getApp(hwnd)) |app| {
                    if (app.corep) |corep| {
                        core.zonvie_core_quit_confirmed(corep, 0);
                    }
                }
            }
            return 0;
        },

        WM_APP_QUIT_TIMEOUT => {
            // Neovim not responding - show force quit dialog
            // Note: quit_timeout_fired was already set in WM_TIMER before posting this message
            if (applog.isEnabled()) applog.appLog("[win] WM_APP_QUIT_TIMEOUT: showing not responding dialog\n", .{});

            const dialog_msg = std.unicode.utf8ToUtf16LeStringLiteral("Neovim is not responding. Do you want to force quit?");
            const dialog_title = std.unicode.utf8ToUtf16LeStringLiteral("Neovim Not Responding");
            const result = c.MessageBoxW(
                hwnd,
                dialog_msg,
                dialog_title,
                c.MB_OKCANCEL | c.MB_ICONERROR | c.MB_DEFBUTTON1,
            );

            if (result == c.IDOK) {
                // Force quit - terminate the app
                if (applog.isEnabled()) applog.appLog("[win] WM_APP_QUIT_TIMEOUT: user chose Force Quit\n", .{});
                _ = c.DestroyWindow(hwnd);
            }
            // Cancel/Wait - do nothing, user can try again later
            return 0;
        },

        WM_APP_TABLINE_INVALIDATE => {
            if (getApp(hwnd)) |app| {
                // Tabline is rendered as D3D11 texture via renderTablineToD3D
                // Invalidate main window to trigger WM_PAINT which calls renderTablineToD3D
                _ = c.InvalidateRect(hwnd, null, 0);
                // Force immediate repaint so tabline updates without waiting for next message
                _ = c.UpdateWindow(hwnd);
                _ = app;
            }
            return 0;
        },

        c.WM_TIMER => {
            if (wParam == TIMER_MSG_AUTOHIDE) {
                applog.appLog("[win] WM_TIMER: message window auto-hide\n", .{});
                // Kill the timer and hide message window
                _ = c.KillTimer(hwnd, TIMER_MSG_AUTOHIDE);
                if (getApp(hwnd)) |app| {
                    hideMessageWindow(app);
                }
            } else if (wParam == TIMER_MINI_AUTOHIDE) {
                applog.appLog("[win] WM_TIMER: mini window auto-hide\n", .{});
                // Kill the timer and hide mini window (showmode slot)
                _ = c.KillTimer(hwnd, TIMER_MINI_AUTOHIDE);
                if (getApp(hwnd)) |app| {
                    updateMiniText(app, .showmode, "");
                    updateMiniWindows(app);
                }
            } else if (wParam == TIMER_SCROLLBAR_AUTOHIDE) {
                // Start fade-out animation after timeout
                _ = c.KillTimer(hwnd, TIMER_SCROLLBAR_AUTOHIDE);
                if (getApp(hwnd)) |app| {
                    app.scrollbar_hide_timer = 0;
                    hideScrollbar(hwnd, app);
                }
            } else if (wParam == TIMER_SCROLLBAR_FADE) {
                // Update scrollbar fade animation
                if (getApp(hwnd)) |app| {
                    updateScrollbarFade(hwnd, app);
                }
            } else if (wParam == TIMER_SCROLLBAR_REPEAT) {
                // Continuous page scroll while holding mouse on track
                if (getApp(hwnd)) |app| {
                    if (app.scrollbar_repeat_dir != 0) {
                        scrollbarPageScroll(app, app.scrollbar_repeat_dir);
                        // After first delay, switch to faster interval
                        _ = c.KillTimer(hwnd, TIMER_SCROLLBAR_REPEAT);
                        app.scrollbar_repeat_timer = c.SetTimer(hwnd, TIMER_SCROLLBAR_REPEAT, SCROLLBAR_REPEAT_INTERVAL, null);
                    }
                }
            } else if (wParam == TIMER_CURSOR_BLINK) {
                applog.appLog("[win] WM_TIMER: cursor blink\n", .{});
                if (getApp(hwnd)) |app| {
                    handleCursorBlinkTimer(hwnd, app);
                }
            } else if (wParam == TIMER_DEVCONTAINER_POLL) {
                // Poll for devcontainer up completion
                if (g_devcontainer_up_done.load(.seq_cst)) {
                    applog.appLog("[win] WM_TIMER: devcontainer up completed\n", .{});
                    _ = c.KillTimer(hwnd, TIMER_DEVCONTAINER_POLL);

                    if (getApp(hwnd)) |app| {
                        if (g_devcontainer_up_success.load(.seq_cst)) {
                            // Success: update label and start nvim with devcontainer exec
                            updateDevcontainerProgressLabel(std.unicode.utf8ToUtf16LeStringLiteral("Connecting..."));

                            // Build devcontainer exec command
                            var nvim_cmd_buf: [4096]u8 = undefined;
                            var nvim_cmd_slice: []const u8 = undefined;

                            if (app.devcontainer_workspace) |workspace| {
                                var fbs = std.io.fixedBufferStream(&nvim_cmd_buf);
                                const writer = fbs.writer();
                                writer.writeAll("devcontainer exec --workspace-folder \"") catch {};
                                writer.writeAll(workspace) catch {};
                                writer.writeAll("\"") catch {};
                                if (app.devcontainer_config) |config_path| {
                                    writer.writeAll(" --config \"") catch {};
                                    writer.writeAll(config_path) catch {};
                                    writer.writeAll("\"") catch {};
                                }
                                writer.writeAll(" --remote-env XDG_CONFIG_HOME=/nvim-config nvim --embed") catch {};
                                nvim_cmd_slice = nvim_cmd_buf[0..fbs.pos];
                                applog.appLog("[win] devcontainer exec command: {s}\n", .{nvim_cmd_slice});

                                // Start nvim
                                const nvim_path_z = app.alloc.dupeZ(u8, nvim_cmd_slice) catch null;
                                defer if (nvim_path_z) |p| app.alloc.free(p);
                                const nvim_path_ptr: ?[*:0]const u8 = if (nvim_path_z) |p| p.ptr else null;
                                applog.appLog("[win] starting neovim via devcontainer exec\n", .{});
                                const start_ok = core.zonvie_core_start(app.corep, nvim_path_ptr, 24, 80);
                                applog.appLog("[win] zonvie_core_start -> {d}\n", .{start_ok});

                                app.devcontainer_up_pending = false;
                                app.devcontainer_nvim_started = true;
                            }

                            // Hide progress dialog
                            hideDevcontainerProgressDialog();
                        } else {
                            // Failure: hide dialog and show error
                            hideDevcontainerProgressDialog();
                            app.devcontainer_up_pending = false;
                            applog.appLog("[win] devcontainer up failed\n", .{});
                            // TODO: show error message to user
                        }
                    }
                }
            } else if (wParam == TIMER_QUIT_TIMEOUT) {
                // Neovim not responding to quit request - show force quit dialog
                applog.appLog("[win] WM_TIMER: quit timeout - Neovim not responding\n", .{});
                _ = c.KillTimer(hwnd, TIMER_QUIT_TIMEOUT);
                if (getApp(hwnd)) |app| {
                    app.quit_pending = false;
                    // Set flag immediately to ignore any delayed WM_APP_QUIT_REQUESTED
                    // that may arrive before WM_APP_QUIT_TIMEOUT is processed
                    app.quit_timeout_fired = true;
                }
                // Post message to handle dialog on main thread
                _ = c.PostMessageW(hwnd, WM_APP_QUIT_TIMEOUT, 0, 0);
            }
            return 0;
        },

        WM_APP_DEFERRED_INIT => {
            applog.appLog("[win] WM_APP_DEFERRED_INIT: begin", .{});

            // Timing measurement for startup diagnostics
            var freq: c.LARGE_INTEGER = undefined;
            var t0: c.LARGE_INTEGER = undefined;
            var t1: c.LARGE_INTEGER = undefined;
            var t2: c.LARGE_INTEGER = undefined;
            _ = c.QueryPerformanceFrequency(&freq);
            _ = c.QueryPerformanceCounter(&t0);

            if (getApp(hwnd)) |app| {
                // ============================================================
                // PHASE 1: Start nvim spawn FIRST (runs in parallel with renderer init)
                // ============================================================
                var cb: core.Callbacks = .{
                    .on_vertices = onVertices,
                    .on_vertices_partial = onVerticesPartial,
                    .on_vertices_row = onVerticesRow,
                    .on_atlas_ensure_glyph = onAtlasEnsureGlyph,
                    .on_atlas_ensure_glyph_styled = onAtlasEnsureGlyphStyled,
                    .on_render_plan = onRenderPlan,
                    .on_log = onLog,
                    .on_guifont = onGuiFont,
                    .on_linespace = onLineSpace,
                    .on_exit = onExit,
                    .on_set_title = onSetTitle,
                    .on_external_window = onExternalWindow,
                    .on_external_window_close = onExternalWindowClose,
                    .on_external_vertices = onExternalVertices,
                    .on_cursor_grid_changed = onCursorGridChanged,
                    .on_cmdline_show = onCmdlineShow,
                    .on_cmdline_hide = onCmdlineHide,
                    .on_msg_show = onMsgShow,
                    .on_msg_clear = onMsgClear,
                    .on_msg_showmode = onMsgShowmode,
                    .on_msg_showcmd = onMsgShowcmd,
                    .on_msg_ruler = onMsgRuler,
                    .on_msg_history_show = onMsgHistoryShow,
                    .on_tabline_update = onTablineUpdate,
                    .on_tabline_hide = onTablineHide,
                    .on_clipboard_get = onClipboardGet,
                    .on_clipboard_set = onClipboardSet,
                    .on_ssh_auth_prompt = onSSHAuthPrompt,
                    .on_ime_off = onIMEOff,
                    .on_quit_requested = onQuitRequested,
                };
                applog.appLog("[win] row_mode enabled: using row-vertex path\n", .{});

                applog.appLog("  core_create callbacks ptr ctx(app)={*}", .{app});
                _ = c.QueryPerformanceCounter(&t1);
                app.corep = core.zonvie_core_create(&cb, app);
                _ = c.QueryPerformanceCounter(&t2);
                const core_create_ms = @divTrunc((t2.QuadPart - t1.QuadPart) * 1000, freq.QuadPart);
                applog.appLog("  [TIMING] zonvie_core_create: {d}ms", .{core_create_ms});
                applog.appLog("  core_create -> corep={*}", .{app.corep});

                // Load config into core for message routing
                if (config_mod.getConfigFilePath(app.alloc)) |config_path| {
                    defer app.alloc.free(config_path);
                    const config_path_z = app.alloc.dupeZ(u8, config_path) catch null;
                    if (config_path_z) |cpath| {
                        defer app.alloc.free(cpath);
                        const load_result = core.zonvie_core_load_config(app.corep, cpath.ptr);
                        applog.appLog("[win] zonvie_core_load_config({s}) = {d}\n", .{ config_path, load_result });
                    }
                } else |_| {
                    applog.appLog("[win] no config path found, using defaults\n", .{});
                }

                // Configure core settings
                setLogEnabledViaCore(app, app.config.log.enabled);
                if (app.ext_cmdline_enabled) {
                    applog.appLog("[win] enabling ext_cmdline\n", .{});
                    core.zonvie_core_set_ext_cmdline(app.corep, 1);
                }
                if (app.config.popup.external) {
                    applog.appLog("[win] enabling ext_popupmenu\n", .{});
                    core.zonvie_core_set_ext_popupmenu(app.corep, 1);
                }
                if (app.ext_messages_enabled) {
                    applog.appLog("[win] enabling ext_messages\n", .{});
                    core.zonvie_core_set_ext_messages(app.corep, 1);
                }
                if (app.ext_tabline_enabled) {
                    applog.appLog("[win] enabling ext_tabline\n", .{});
                    core.zonvie_core_set_ext_tabline(app.corep, 1);
                    // Note: Child window approach doesn't work with D3D11
                    // D3D11 renders on top of GDI child windows
                    // We'll draw tabline using GDI after D3D11 Present instead
                }
                core.zonvie_core_set_background_opacity(app.corep, app.config.window.opacity);
                applog.appLog("[win] set opacity={d:.2}\n", .{app.config.window.opacity});
                core.zonvie_core_set_glyph_cache_size(
                    app.corep,
                    app.config.performance.glyph_cache_ascii_size,
                    app.config.performance.glyph_cache_non_ascii_size,
                );
                applog.appLog("[win] set glyph_cache_size ascii={d} non_ascii={d}\n", .{
                    app.config.performance.glyph_cache_ascii_size,
                    app.config.performance.glyph_cache_non_ascii_size,
                });

                // Build nvim command and start nvim (runs in background thread)
                var nvim_cmd_buf: [1024]u8 = undefined;
                var nvim_cmd_slice: []const u8 = undefined;

                if (app.wsl_mode) {
                    var fbs = std.io.fixedBufferStream(&nvim_cmd_buf);
                    const writer = fbs.writer();
                    writer.writeAll("wsl.exe") catch {};
                    if (app.wsl_distro) |distro| {
                        writer.print(" -d {s}", .{distro}) catch {};
                    }
                    writer.writeAll(" --shell-type login -- nvim --embed") catch {};
                    nvim_cmd_slice = nvim_cmd_buf[0..fbs.pos];
                    applog.appLog("[win] WSL mode enabled, command: {s}\n", .{nvim_cmd_slice});
                } else if (app.ssh_mode) {
                    if (app.ssh_host) |host| {
                        applog.appLog("[win] SSH mode: building SSH command, host={s}\n", .{host});
                        var fbs = std.io.fixedBufferStream(&nvim_cmd_buf);
                        const writer = fbs.writer();
                        // Always use ssh-askpass prefix for GUI dialog (password or key passphrase)
                        writer.writeAll("ssh-askpass ") catch {};
                        writer.writeAll("C:\\Windows\\System32\\OpenSSH\\ssh.exe") catch {};
                        if (app.ssh_port) |port| {
                            writer.print(" -p {d}", .{port}) catch {};
                        }
                        if (app.ssh_identity) |identity| {
                            // Public key auth: use identity file, disable password auth
                            // (key passphrase dialog still works via SSH_ASKPASS)
                            writer.print(" -i \"{s}\"", .{identity}) catch {};
                            writer.writeAll(" -o PasswordAuthentication=no -o KbdInteractiveAuthentication=no") catch {};
                        }
                        writer.writeAll(" -o StrictHostKeyChecking=accept-new") catch {};
                        writer.print(" {s} nvim --headless --embed", .{host}) catch {};
                        nvim_cmd_slice = nvim_cmd_buf[0..fbs.pos];
                        applog.appLog("[win] SSH command: {s}\n", .{nvim_cmd_slice});

                        // Always set up SSH_ASKPASS for on-demand password/passphrase dialog
                        // SSH will call SSH_ASKPASS only when it needs authentication
                        if (app.ssh_password) |pwd| {
                            // Pre-set password mode: store password in environment
                            var pwd_utf16: [256]u16 = undefined;
                            var pwd_idx: usize = 0;
                            for (pwd) |ch| {
                                if (pwd_idx < 255) {
                                    pwd_utf16[pwd_idx] = ch;
                                    pwd_idx += 1;
                                }
                            }
                            pwd_utf16[pwd_idx] = 0;
                            _ = c.SetEnvironmentVariableW(std.unicode.utf8ToUtf16LeStringLiteral("ZONVIE_SSH_PASSWORD"), &pwd_utf16);
                        }
                        // Set zonvie.exe as SSH_ASKPASS program (shows dialog when SSH needs auth)
                        _ = c.SetEnvironmentVariableW(std.unicode.utf8ToUtf16LeStringLiteral("ZONVIE_ASKPASS_MODE"), std.unicode.utf8ToUtf16LeStringLiteral("1"));
                        var exe_path: [c.MAX_PATH + 1]u16 = undefined;
                        const exe_len = c.GetModuleFileNameW(null, &exe_path, c.MAX_PATH + 1);
                        if (exe_len > 0 and exe_len < c.MAX_PATH) {
                            exe_path[exe_len] = 0;
                            _ = c.SetEnvironmentVariableW(std.unicode.utf8ToUtf16LeStringLiteral("SSH_ASKPASS"), &exe_path);
                        }
                        _ = c.SetEnvironmentVariableW(std.unicode.utf8ToUtf16LeStringLiteral("SSH_ASKPASS_REQUIRE"), std.unicode.utf8ToUtf16LeStringLiteral("force"));
                        _ = c.SetEnvironmentVariableW(std.unicode.utf8ToUtf16LeStringLiteral("DISPLAY"), std.unicode.utf8ToUtf16LeStringLiteral("dummy:0"));
                    } else {
                        applog.appLog("[win] SSH mode enabled but no host specified\n", .{});
                        nvim_cmd_slice = app.config.neovim.path;
                    }
                } else if (app.devcontainer_mode) devcontainer_block: {
                    if (app.devcontainer_workspace) |workspace| {
                        applog.appLog("[win] devcontainer mode: workspace={s}, rebuild={}\n", .{ workspace, app.devcontainer_rebuild });

                        if (app.devcontainer_rebuild) {
                            // Rebuild mode: show progress dialog and run devcontainer up in background
                            showDevcontainerProgressDialog(std.unicode.utf8ToUtf16LeStringLiteral("Building devcontainer..."));

                            // Reset atomic flags
                            g_devcontainer_up_done.store(false, .seq_cst);
                            g_devcontainer_up_success.store(false, .seq_cst);

                            // Start background thread for devcontainer up
                            const thread = std.Thread.spawn(.{}, runDevcontainerUpThread, .{ workspace, app.devcontainer_config, app.alloc }) catch |e| {
                                applog.appLog("[win] failed to spawn devcontainer up thread: {any}\n", .{e});
                                hideDevcontainerProgressDialog();
                                nvim_cmd_slice = app.config.neovim.path;
                                break :devcontainer_block;
                            };
                            thread.detach();

                            // Mark that we're waiting for devcontainer up
                            app.devcontainer_up_pending = true;

                            // Start polling timer
                            _ = c.SetTimer(hwnd, TIMER_DEVCONTAINER_POLL, DEVCONTAINER_POLL_INTERVAL, null);
                            applog.appLog("[win] devcontainer poll timer started\n", .{});

                            // Skip nvim startup - will be done after devcontainer up completes
                            applog.appLog("[win] devcontainer up started in background, skipping nvim startup\n", .{});

                            // Initialize renderers anyway (they're needed for the window)
                            // But skip zonvie_core_start until devcontainer up completes
                            break :devcontainer_block;
                        } else {
                            // Normal mode: show connecting dialog and direct devcontainer exec
                            showDevcontainerProgressDialog(std.unicode.utf8ToUtf16LeStringLiteral("Connecting..."));

                            var fbs = std.io.fixedBufferStream(&nvim_cmd_buf);
                            const writer = fbs.writer();
                            writer.writeAll("devcontainer exec --workspace-folder \"") catch {};
                            writer.writeAll(workspace) catch {};
                            writer.writeAll("\"") catch {};
                            if (app.devcontainer_config) |config_path| {
                                writer.writeAll(" --config \"") catch {};
                                writer.writeAll(config_path) catch {};
                                writer.writeAll("\"") catch {};
                            }
                            writer.writeAll(" --remote-env XDG_CONFIG_HOME=/nvim-config nvim --embed") catch {};
                            nvim_cmd_slice = nvim_cmd_buf[0..fbs.pos];
                            applog.appLog("[win] devcontainer exec command: {s}\n", .{nvim_cmd_slice});
                        }
                    } else {
                        applog.appLog("[win] devcontainer mode enabled but no workspace specified\n", .{});
                        nvim_cmd_slice = app.config.neovim.path;
                    }
                } else {
                    // Native mode: add extra args if any
                    if (app.nvim_extra_args.items.len > 0) {
                        var fbs = std.io.fixedBufferStream(&nvim_cmd_buf);
                        const writer = fbs.writer();
                        writer.writeAll(app.config.neovim.path) catch {};
                        for (app.nvim_extra_args.items) |arg| {
                            writer.writeAll(" ") catch {};
                            // Escape arguments with spaces
                            if (std.mem.indexOfScalar(u8, arg, ' ') != null) {
                                writer.writeAll("\"") catch {};
                                writer.writeAll(arg) catch {};
                                writer.writeAll("\"") catch {};
                            } else {
                                writer.writeAll(arg) catch {};
                            }
                        }
                        nvim_cmd_slice = nvim_cmd_buf[0..fbs.pos];
                        applog.appLog("[win] Added nvim extra args, command: {s}\n", .{nvim_cmd_slice});
                    } else {
                        nvim_cmd_slice = app.config.neovim.path;
                    }
                }

                // Skip nvim startup if waiting for devcontainer up
                if (!app.devcontainer_up_pending) {
                    const nvim_path_z = app.alloc.dupeZ(u8, nvim_cmd_slice) catch null;
                    defer if (nvim_path_z) |p| app.alloc.free(p);
                    const nvim_path_ptr: ?[*:0]const u8 = if (nvim_path_z) |p| p.ptr else null;
                    applog.appLog("[win] starting neovim: path={s}\n", .{nvim_cmd_slice});
                    _ = c.QueryPerformanceCounter(&t1);
                    const start_ok = core.zonvie_core_start(app.corep, nvim_path_ptr, 24, 80);
                    _ = c.QueryPerformanceCounter(&t2);
                    const core_start_ms = @divTrunc((t2.QuadPart - t1.QuadPart) * 1000, freq.QuadPart);
                    applog.appLog("  [TIMING] zonvie_core_start: {d}ms (nvim spawn running in background)", .{core_start_ms});
                    applog.appLog("  core_start -> {d}", .{start_ok});

                    // Close devcontainer progress dialog if shown (for non-rebuild mode)
                    if (app.devcontainer_mode and !app.devcontainer_rebuild) {
                        hideDevcontainerProgressDialog();
                    }
                } else {
                    applog.appLog("[win] nvim startup skipped, waiting for devcontainer up\n", .{});
                }

                // ============================================================
                // PHASE 2: Initialize renderers (runs in parallel with nvim spawn)
                // ============================================================
                applog.appLog("  renderer create...", .{});

                // 1) Atlas builder (DirectWrite + CPU atlas)
                _ = c.QueryPerformanceCounter(&t1);
                const atlas = dwrite_d2d.Renderer.init(app.alloc, hwnd) catch |e| {
                    applog.appLog("dwrite_d2d.Renderer.init failed: {any}\n", .{e});
                    app.atlas = null;
                    app.renderer = null;
                    return 0;
                };
                _ = c.QueryPerformanceCounter(&t2);
                const dwrite_ms = @divTrunc((t2.QuadPart - t1.QuadPart) * 1000, freq.QuadPart);
                applog.appLog("  [TIMING] dwrite_d2d.Renderer.init: {d}ms", .{dwrite_ms});

                // 2) GPU renderer (D3D11)
                // When ext_tabline is enabled, use content child window for D3D11 rendering
                const render_hwnd = if (app.ext_tabline_enabled and app.content_hwnd != null)
                    app.content_hwnd.?
                else
                    hwnd;
                applog.appLog("[win] D3D11 target hwnd: {s}\n", .{if (render_hwnd == hwnd) "main" else "content child"});

                _ = c.QueryPerformanceCounter(&t1);
                const gpu = d3d11.Renderer.init(app.alloc, render_hwnd, app.config.window.opacity) catch |e| {
                    applog.appLog("d3d11.Renderer.init failed: {any}\n", .{e});
                    var tmp = atlas;
                    tmp.deinit(); // avoid leak
                    app.atlas = null;
                    app.renderer = null;
                    return 0;
                };
                _ = c.QueryPerformanceCounter(&t2);
                const d3d_ms = @divTrunc((t2.QuadPart - t1.QuadPart) * 1000, freq.QuadPart);
                applog.appLog("  [TIMING] d3d11.Renderer.init: {d}ms", .{d3d_ms});

                app.mu.lock();
                app.atlas = atlas;
                app.renderer = gpu;
                app.mu.unlock();

                applog.appLog("  renderer created ok", .{});

                if (app.atlas) |*a| {
                    app.cell_w_px = a.cellW();
                    app.cell_h_px = a.cellH();
                }

                // Process pending glyphs that were requested before atlas was ready
                // (happens when nvim spawn runs in parallel with renderer init)
                {
                    app.mu.lock();
                    const pending_count = app.pending_glyphs.items.len;
                    app.mu.unlock();

                    if (pending_count > 0) {
                        applog.appLog("  [TIMING] processing {d} pending glyphs", .{pending_count});
                        app.mu.lock();
                        defer app.mu.unlock();
                        if (app.atlas) |*a| {
                            for (app.pending_glyphs.items) |pg| {
                                if (pg.style_flags == 0) {
                                    _ = a.atlasEnsureGlyphEntry(pg.scalar) catch {};
                                } else {
                                    _ = a.atlasEnsureGlyphEntryStyled(pg.scalar, pg.style_flags) catch {};
                                }
                            }
                        }
                        app.pending_glyphs.clearRetainingCapacity();
                    }
                }

                // NOTE: setFontUtf8("Consolas", 14.0) is already called in dwrite_d2d.Renderer.init()
                // Removed redundant call to avoid double font initialization (~10ms savings)

                updateRowsColsFromClientForce(hwnd, app);

                // Update layout after renderer is ready
                updateLayoutToCore(hwnd, app);

                _ = c.QueryPerformanceCounter(&t2);
                const total_ms = @divTrunc((t2.QuadPart - t0.QuadPart) * 1000, freq.QuadPart);
                applog.appLog("[win] WM_APP_DEFERRED_INIT: end (total {d}ms)", .{total_ms});

                // Force a repaint now that renderer is ready
                _ = c.InvalidateRect(hwnd, null, 0);
            }
            return 0;
        },

        c.WM_KEYDOWN, c.WM_SYSKEYDOWN => {
            if (getApp(hwnd)) |app| {
                const vk: u32 = @intCast(wParam);
                const mods = queryMods();

                // Windows keycode is passed as 0x10000|VK so Zig core can distinguish.
                const keycode: u32 = KEYCODE_WINVK_FLAG | vk;

                // scancode is in bits 16..23 of lParam
                const scancode: u32 = @intCast((@as(u32, @intCast(lParam)) >> 16) & 0xFF);

                const has_ctrl_alt = (mods & (MOD_CTRL | MOD_ALT)) != 0;

                // Check if IME is composing
                app.mu.lock();
                const ime_composing = app.ime_composing;
                app.mu.unlock();

                // 1) Special keys always go through send_key_event (chars=nil)
                //    BUT skip VK_RETURN and VK_BACK when IME is composing to avoid double-input
                if (isSpecialVk(vk)) {
                    if (ime_composing and (vk == c.VK_RETURN or vk == c.VK_BACK)) {
                        // Let IME handle Enter/Backspace - committed text comes via WM_IME_CHAR,
                        // then the key comes via WM_CHAR after WM_IME_ENDCOMPOSITION.
                        // Return 0 to prevent DefWindowProcW from also translating.
                        return 0;
                    } else {
                        sendKeyEventToCore(app, keycode, mods, null, null);
                        return 0;
                    }
                }

                // 2) Ctrl/Alt combos: also go through send_key_event, and try to provide chars/ign.
                //    (Let Zig decide <C-x> etc.)
                if (has_ctrl_alt) {
                    var tmp_chars: [16]u16 = undefined;
                    var tmp_ign: [16]u16 = undefined;
                    var out_chars: [8]u8 = undefined;
                    var out_ign: [8]u8 = undefined;

                    const pair = toUnicodePairUtf8(
                        vk, scancode,
                        &tmp_chars, &tmp_ign,
                        &out_chars, &out_ign,
                    );

                    sendKeyEventToCore(app, keycode, mods, pair.chars, pair.ign);
                    return 0;
                }

                // 3) Otherwise (normal text, Shift-only, IME): let WM_CHAR handle.
                // Do not consume here.
            }
        },

        c.WM_CHAR, c.WM_SYSCHAR => {
            if (getApp(hwnd)) |app| {
                const mods = queryMods();

                // If Ctrl/Alt are down, WM_CHAR often becomes ASCII control => ignore
                // (WM_KEYDOWN path handled Ctrl/Alt combos).
                if ((mods & (MOD_CTRL | MOD_ALT)) != 0) {
                    return 0;
                }

                const ch0: u16 = @as(u16, @intCast(wParam));

                // Skip control characters that are already handled by WM_KEYDOWN as special keys.
                // This prevents double-input of Enter, Backspace, Tab, Escape.
                // 0x08 = Backspace, 0x09 = Tab, 0x0D = Enter (CR), 0x1B = Escape
                if (ch0 == 0x08 or ch0 == 0x09 or ch0 == 0x0D or ch0 == 0x1B) {
                    return 0;
                }

                // WM_CHAR gives UTF-16 code unit; handle surrogate pair minimally:
                // If high surrogate, wait for next WM_CHAR is complex; for now ignore high surrogate.
                if (ch0 >= 0xD800 and ch0 <= 0xDBFF) {
                    return 0;
                }
                if (ch0 >= 0xDC00 and ch0 <= 0xDFFF) {
                    return 0;
                }

                var out: [8]u8 = undefined;
                const s = utf16UnitsToUtf8(&out, ch0, null) orelse return 0;

                // keycode=0 means "text input" (Zig will take chars path).
                sendKeyEventToCore(app, 0, mods, s, s);
                return 0;
            }
        },

        // --- IME message handling ---
        c.WM_IME_STARTCOMPOSITION => {
            applog.appLog("[IME] WM_IME_STARTCOMPOSITION\n", .{});
            if (getApp(hwnd)) |app| {
                app.mu.lock();
                app.ime_composing = true;
                app.ime_composition_str.clearRetainingCapacity();
                app.ime_composition_utf8.clearRetainingCapacity();
                app.ime_clause_info.clearRetainingCapacity();
                app.ime_cursor_pos = 0;
                app.ime_target_start = 0;
                app.ime_target_end = 0;
                app.mu.unlock();

                // Position IME candidate window at cursor
                positionImeCandidateWindow(hwnd, app);
            }
            return 0;
        },

        c.WM_IME_COMPOSITION => {
            applog.appLog("[IME] WM_IME_COMPOSITION lParam=0x{x}\n", .{@as(u32, @intCast(lParam & 0xFFFFFFFF))});
            if (getApp(hwnd)) |app| {
                const himc = c.ImmGetContext(hwnd);
                if (himc != null) {
                    defer _ = c.ImmReleaseContext(hwnd, himc);

                    const lparam_u: c.LPARAM = lParam;

                    // Get composition string
                    if ((lparam_u & c.GCS_COMPSTR) != 0) {
                        const byte_len = c.ImmGetCompositionStringW(himc, c.GCS_COMPSTR, null, 0);
                        if (byte_len > 0) {
                            const char_len: usize = @intCast(@divTrunc(byte_len, 2));

                            app.mu.lock();
                            app.ime_composition_str.resize(app.alloc, char_len) catch {
                                app.mu.unlock();
                                return 0;
                            };
                            _ = c.ImmGetCompositionStringW(himc, c.GCS_COMPSTR, app.ime_composition_str.items.ptr, @intCast(byte_len));

                            // Convert to UTF-8 for display
                            updateImeCompositionUtf8(app);
                            applog.appLog("[IME] composition_str len={d}\n", .{app.ime_composition_str.items.len});
                            app.mu.unlock();
                        } else {
                            app.mu.lock();
                            app.ime_composition_str.clearRetainingCapacity();
                            app.ime_composition_utf8.clearRetainingCapacity();
                            app.mu.unlock();
                        }
                    }

                    // Get clause info (for underline segments)
                    if ((lparam_u & c.GCS_COMPCLAUSE) != 0) {
                        const clause_byte_len = c.ImmGetCompositionStringW(himc, c.GCS_COMPCLAUSE, null, 0);
                        if (clause_byte_len > 0) {
                            const clause_count: usize = @intCast(@divTrunc(clause_byte_len, 4));
                            app.mu.lock();
                            app.ime_clause_info.resize(app.alloc, clause_count) catch {
                                app.mu.unlock();
                                return 0;
                            };
                            _ = c.ImmGetCompositionStringW(himc, c.GCS_COMPCLAUSE, app.ime_clause_info.items.ptr, @intCast(clause_byte_len));
                            app.mu.unlock();
                        }
                    }

                    // Get cursor position in composition
                    if ((lparam_u & c.GCS_CURSORPOS) != 0) {
                        const cursor_pos = c.ImmGetCompositionStringW(himc, c.GCS_CURSORPOS, null, 0);
                        app.mu.lock();
                        app.ime_cursor_pos = @intCast(@max(0, cursor_pos));
                        app.mu.unlock();
                    }

                    // Get target clause (the clause being converted)
                    // Always try to get COMPATTR, not just when flag is set
                    {
                        const attr_len = c.ImmGetCompositionStringW(himc, c.GCS_COMPATTR, null, 0);
                        applog.appLog("[IME] GCS_COMPATTR attr_len={d} lparam_has_flag={d}\n", .{
                            attr_len,
                            @intFromBool((lparam_u & c.GCS_COMPATTR) != 0),
                        });
                        if (attr_len > 0) {
                            var attr_buf: [256]u8 = undefined;
                            const len: usize = @intCast(@min(@as(usize, @intCast(@max(0, attr_len))), 256));
                            _ = c.ImmGetCompositionStringW(himc, c.GCS_COMPATTR, &attr_buf, @intCast(len));

                            // Debug: log all attributes
                            applog.appLog("[IME] COMPATTR len={d} attrs=", .{len});
                            for (0..len) |idx| {
                                applog.appLog("{x} ", .{attr_buf[idx]});
                            }
                            applog.appLog("\n", .{});

                            // Find target clause (ATTR_TARGET_CONVERTED or ATTR_TARGET_NOTCONVERTED)
                            // ATTR_INPUT = 0x00, ATTR_TARGET_CONVERTED = 0x01,
                            // ATTR_CONVERTED = 0x02, ATTR_TARGET_NOTCONVERTED = 0x03
                            app.mu.lock();
                            app.ime_target_start = 0;
                            app.ime_target_end = 0;
                            var found_start: bool = false;
                            var i: u32 = 0;
                            while (i < len) : (i += 1) {
                                const attr = attr_buf[i];
                                // ATTR_TARGET_CONVERTED = 0x01, ATTR_TARGET_NOTCONVERTED = 0x03
                                if (attr == 0x01 or attr == 0x03) {
                                    if (!found_start) {
                                        app.ime_target_start = i;
                                        found_start = true;
                                    }
                                    app.ime_target_end = i + 1;
                                }
                            }
                            applog.appLog("[IME] target_start={d} target_end={d}\n", .{ app.ime_target_start, app.ime_target_end });
                            app.mu.unlock();
                        }
                    }

                    // Update preedit overlay directly
                    updateImePreeditOverlay(hwnd, app);
                }
            }
            // Let DefWindowProc handle for default IME processing
            return c.DefWindowProcW(hwnd, msg, wParam, lParam);
        },

        c.WM_IME_ENDCOMPOSITION => {
            if (getApp(hwnd)) |app| {
                app.mu.lock();
                app.ime_composing = false;
                app.ime_composition_str.clearRetainingCapacity();
                app.ime_composition_utf8.clearRetainingCapacity();
                app.ime_clause_info.clearRetainingCapacity();
                app.ime_cursor_pos = 0;
                app.ime_target_start = 0;
                app.ime_target_end = 0;
                app.mu.unlock();

                // Hide preedit overlay
                hideImePreeditOverlay(app);
            }
            return 0;
        },

        c.WM_IME_CHAR => {
            // IME committed character - send to Neovim
            if (getApp(hwnd)) |app| {
                const ch: u16 = @intCast(wParam);

                // Skip surrogate pairs for now (complex handling)
                if (ch >= 0xD800 and ch <= 0xDFFF) {
                    return 0;
                }

                var out: [8]u8 = undefined;
                const s = utf16UnitsToUtf8(&out, ch, null) orelse return 0;

                sendKeyEventToCore(app, 0, 0, s, s);
                return 0;
            }
        },

        c.WM_MOUSEWHEEL => {
            if (getApp(hwnd)) |app| {
                handleMouseWheel(hwnd, wParam, lParam, app, 1, &app.scroll_accum);
                return 0;
            }
        },

        // WM_VSCROLL not used (custom D3D11 scrollbar)

        WM_APP_UPDATE_SCROLLBAR => {
            if (getApp(hwnd)) |app| {
                updateScrollbar(hwnd, app);
                return 0;
            }
        },

        // Mouse button events
        c.WM_LBUTTONDOWN, c.WM_RBUTTONDOWN, c.WM_MBUTTONDOWN => {
            if (getApp(hwnd)) |app| {
                // Extract position from lParam
                const x: i16 = @bitCast(@as(u16, @truncate(@as(usize, @bitCast(lParam)))));
                const y: i16 = @bitCast(@as(u16, @truncate(@as(usize, @bitCast(lParam)) >> 16)));

                // Check tabline area first (left button only, when ext_tabline enabled)
                if (msg == c.WM_LBUTTONDOWN and app.ext_tabline_enabled) {
                    if (y < TablineState.TAB_BAR_HEIGHT) {
                        handleTablineMouseDown(app, hwnd, @as(c_int, x), @as(c_int, y));
                        return 0; // Handled by tabline
                    }
                }

                // Check scrollbar hit first (left button only)
                if (msg == c.WM_LBUTTONDOWN) {
                    if (scrollbarMouseDown(hwnd, app, @as(i32, x), @as(i32, y))) {
                        return 0; // Handled by scrollbar
                    }

                }

                // Capture mouse to receive WM_MOUSEMOVE outside window
                _ = c.SetCapture(hwnd);

                // Determine button name
                const button: [*:0]const u8 = switch (msg) {
                    c.WM_LBUTTONDOWN => blk: {
                        app.mouse_button_held = 1;
                        break :blk "left";
                    },
                    c.WM_RBUTTONDOWN => blk: {
                        app.mouse_button_held = 2;
                        break :blk "right";
                    },
                    c.WM_MBUTTONDOWN => blk: {
                        app.mouse_button_held = 3;
                        break :blk "middle";
                    },
                    else => "left",
                };

                // Get cell dimensions
                app.mu.lock();
                const cell_w = app.cell_w_px;
                const cell_h = app.cell_h_px;
                const linespace = app.linespace_px;
                app.mu.unlock();

                const row_h = cell_h + linespace;
                const col: i32 = if (cell_w > 0) @divTrunc(@as(i32, x), @as(i32, @intCast(cell_w))) else 0;
                // When ext_tabline is enabled, subtract tabbar height to get content-relative Y coordinate
                const content_y: i32 = if (app.ext_tabline_enabled and app.content_hwnd == null)
                    @as(i32, y) - @as(i32, TablineState.TAB_BAR_HEIGHT)
                else
                    @as(i32, y);
                const row: i32 = if (row_h > 0) @divTrunc(@max(0, content_y), @as(i32, @intCast(row_h))) else 0;

                // Build modifier string
                var mod_buf: [4]u8 = .{ 0, 0, 0, 0 };
                var mod_len: usize = 0;
                if ((wParam & c.MK_SHIFT) != 0) {
                    mod_buf[mod_len] = 'S';
                    mod_len += 1;
                }
                if ((wParam & c.MK_CONTROL) != 0) {
                    mod_buf[mod_len] = 'C';
                    mod_len += 1;
                }
                // Alt is not in wParam for mouse messages; would need GetKeyState(VK_MENU)
                if (c.GetKeyState(c.VK_MENU) < 0) {
                    mod_buf[mod_len] = 'A';
                    mod_len += 1;
                }
                mod_buf[mod_len] = 0; // null terminate

                // Track mouse grid for mini window positioning (main window = grid 1)
                app.last_mouse_grid_id = 1;

                core.zonvie_core_send_mouse_input(
                    app.corep,
                    button,
                    "press",
                    @as([*:0]const u8, @ptrCast(&mod_buf)),
                    1, // grid_id
                    @max(0, row),
                    @max(0, col),
                );

                return 0;
            }
        },

        c.WM_LBUTTONUP, c.WM_RBUTTONUP, c.WM_MBUTTONUP => {
            if (getApp(hwnd)) |app| {
                // Extract position from lParam (needed for tabline check)
                const x_up: i16 = @bitCast(@as(u16, @truncate(@as(usize, @bitCast(lParam)))));
                const y_up: i16 = @bitCast(@as(u16, @truncate(@as(usize, @bitCast(lParam)) >> 16)));

                // Check tabline drag end or tabline area click (left button only)
                if (msg == c.WM_LBUTTONUP and app.ext_tabline_enabled) {
                    if (app.tabline_state.dragging_tab != null or y_up < TablineState.TAB_BAR_HEIGHT) {
                        handleTablineMouseUp(app, hwnd, @as(c_int, x_up), @as(c_int, y_up));
                        return 0; // Handled by tabline
                    }
                }

                // Check if we were interacting with scrollbar (left button only)
                if (msg == c.WM_LBUTTONUP and (app.scrollbar_dragging or app.scrollbar_repeat_timer != 0)) {
                    scrollbarMouseUp(hwnd, app);
                    return 0;
                }

                // Release mouse capture
                _ = c.ReleaseCapture();

                // Determine button name
                const button: [*:0]const u8 = switch (msg) {
                    c.WM_LBUTTONUP => "left",
                    c.WM_RBUTTONUP => "right",
                    c.WM_MBUTTONUP => "middle",
                    else => "left",
                };

                app.mouse_button_held = 0;

                // Extract position from lParam
                const x: i16 = @bitCast(@as(u16, @truncate(@as(usize, @bitCast(lParam)))));
                const y: i16 = @bitCast(@as(u16, @truncate(@as(usize, @bitCast(lParam)) >> 16)));

                // Get cell dimensions
                app.mu.lock();
                const cell_w = app.cell_w_px;
                const cell_h = app.cell_h_px;
                const linespace = app.linespace_px;
                app.mu.unlock();

                const row_h = cell_h + linespace;
                const col: i32 = if (cell_w > 0) @divTrunc(@as(i32, x), @as(i32, @intCast(cell_w))) else 0;
                // When ext_tabline is enabled, subtract tabbar height to get content-relative Y coordinate
                const content_y: i32 = if (app.ext_tabline_enabled and app.content_hwnd == null)
                    @as(i32, y) - @as(i32, TablineState.TAB_BAR_HEIGHT)
                else
                    @as(i32, y);
                const row: i32 = if (row_h > 0) @divTrunc(@max(0, content_y), @as(i32, @intCast(row_h))) else 0;

                // Build modifier string
                var mod_buf: [4]u8 = .{ 0, 0, 0, 0 };
                var mod_len: usize = 0;
                if ((wParam & c.MK_SHIFT) != 0) {
                    mod_buf[mod_len] = 'S';
                    mod_len += 1;
                }
                if ((wParam & c.MK_CONTROL) != 0) {
                    mod_buf[mod_len] = 'C';
                    mod_len += 1;
                }
                if (c.GetKeyState(c.VK_MENU) < 0) {
                    mod_buf[mod_len] = 'A';
                    mod_len += 1;
                }
                mod_buf[mod_len] = 0;

                core.zonvie_core_send_mouse_input(
                    app.corep,
                    button,
                    "release",
                    @as([*:0]const u8, @ptrCast(&mod_buf)),
                    1, // grid_id
                    @max(0, row),
                    @max(0, col),
                );

                return 0;
            }
        },

        c.WM_NCMOUSEMOVE => {
            // Handle non-client mouse move (e.g., in HTCAPTION area of tabline)
            if (getApp(hwnd)) |app| {
                if (app.ext_tabline_enabled) {
                    // Clear tabline hover states when mouse moves into NC area (empty tabline region)
                    if (app.tabline_state.hovered_tab != null or
                        app.tabline_state.hovered_close != null or
                        app.tabline_state.hovered_window_btn != null or
                        app.tabline_state.hovered_new_tab_btn)
                    {
                        app.tabline_state.hovered_tab = null;
                        app.tabline_state.hovered_close = null;
                        app.tabline_state.hovered_window_btn = null;
                        app.tabline_state.hovered_new_tab_btn = false;
                        // Invalidate tabline region to redraw without hover
                        var tabline_rect: c.RECT = .{
                            .left = 0,
                            .top = 0,
                            .right = 4096,
                            .bottom = TablineState.TAB_BAR_HEIGHT,
                        };
                        _ = c.InvalidateRect(hwnd, &tabline_rect, 0);
                    }
                }
            }
            return c.DefWindowProcW(hwnd, msg, wParam, lParam);
        },

        c.WM_MOUSEMOVE => {
            if (getApp(hwnd)) |app| {
                // Extract position from lParam
                const x: i16 = @bitCast(@as(u16, @truncate(@as(usize, @bitCast(lParam)))));
                const y: i16 = @bitCast(@as(u16, @truncate(@as(usize, @bitCast(lParam)) >> 16)));

                // Handle tabline drag or hover (when ext_tabline enabled)
                if (app.ext_tabline_enabled) {
                    if (app.tabline_state.dragging_tab != null or y < TablineState.TAB_BAR_HEIGHT) {
                        handleTablineMouseMoveInChild(app, hwnd, @as(c_int, x), @as(c_int, y));
                        // If dragging, consume the message; otherwise let other handlers process too
                        if (app.tabline_state.dragging_tab != null) return 0;
                    } else {
                        // Mouse moved outside tabline area - clear hover state
                        if (app.tabline_state.hovered_tab != null or
                            app.tabline_state.hovered_close != null or
                            app.tabline_state.hovered_window_btn != null or
                            app.tabline_state.hovered_new_tab_btn)
                        {
                            app.tabline_state.hovered_tab = null;
                            app.tabline_state.hovered_close = null;
                            app.tabline_state.hovered_window_btn = null;
                            app.tabline_state.hovered_new_tab_btn = false;
                            // Invalidate tabline region to redraw without hover
                            var tabline_rect: c.RECT = .{
                                .left = 0,
                                .top = 0,
                                .right = 4096,
                                .bottom = TablineState.TAB_BAR_HEIGHT,
                            };
                            _ = c.InvalidateRect(hwnd, &tabline_rect, 0);
                        }
                    }
                }

                // Handle scrollbar dragging
                if (app.scrollbar_dragging) {
                    scrollbarMouseMove(hwnd, app, @as(i32, y));
                    return 0;
                }

                // Check hover mode scrollbar
                if (app.config.scrollbar.enabled and app.config.scrollbar.isHover()) {
                    var client: c.RECT = undefined;
                    _ = c.GetClientRect(hwnd, &client);
                    const hit = scrollbarHitTest(app, client.right, client.bottom, @as(i32, x), @as(i32, y));
                    const in_scrollbar = hit != .none;

                    if (in_scrollbar and !app.scrollbar_hover) {
                        app.scrollbar_hover = true;
                        showScrollbar(hwnd, app);
                    } else if (!in_scrollbar and app.scrollbar_hover) {
                        app.scrollbar_hover = false;
                        if (!app.config.scrollbar.isAlways() and !app.config.scrollbar.isScroll()) {
                            hideScrollbar(hwnd, app);
                        }
                    }
                }

                // Only send drag events if a button is held
                if (app.mouse_button_held == 0) return c.DefWindowProcW(hwnd, msg, wParam, lParam);

                const button: [*:0]const u8 = switch (app.mouse_button_held) {
                    1 => "left",
                    2 => "right",
                    3 => "middle",
                    else => return c.DefWindowProcW(hwnd, msg, wParam, lParam),
                };

                // Get cell dimensions
                app.mu.lock();
                const cell_w = app.cell_w_px;
                const cell_h = app.cell_h_px;
                const linespace = app.linespace_px;
                app.mu.unlock();

                const row_h = cell_h + linespace;
                const col: i32 = if (cell_w > 0) @divTrunc(@as(i32, x), @as(i32, @intCast(cell_w))) else 0;
                // When ext_tabline is enabled, subtract tabbar height to get content-relative Y coordinate
                const content_y: i32 = if (app.ext_tabline_enabled and app.content_hwnd == null)
                    @as(i32, y) - @as(i32, TablineState.TAB_BAR_HEIGHT)
                else
                    @as(i32, y);
                const row: i32 = if (row_h > 0) @divTrunc(@max(0, content_y), @as(i32, @intCast(row_h))) else 0;

                // Build modifier string
                var mod_buf: [4]u8 = .{ 0, 0, 0, 0 };
                var mod_len: usize = 0;
                if ((wParam & c.MK_SHIFT) != 0) {
                    mod_buf[mod_len] = 'S';
                    mod_len += 1;
                }
                if ((wParam & c.MK_CONTROL) != 0) {
                    mod_buf[mod_len] = 'C';
                    mod_len += 1;
                }
                if (c.GetKeyState(c.VK_MENU) < 0) {
                    mod_buf[mod_len] = 'A';
                    mod_len += 1;
                }
                mod_buf[mod_len] = 0;

                core.zonvie_core_send_mouse_input(
                    app.corep,
                    button,
                    "drag",
                    @as([*:0]const u8, @ptrCast(&mod_buf)),
                    1, // grid_id
                    @max(0, row),
                    @max(0, col),
                );

                return 0;
            }
        },

        c.WM_CLOSE => {
            // Intercept window close to check for unsaved buffers
            if (getApp(hwnd)) |app| {
                // If Neovim already exited (e.g., from :qa!), proceed with normal close
                if (app.neovim_exited.load(.acquire)) {
                    if (applog.isEnabled()) applog.appLog("[win] WM_CLOSE: neovim already exited, proceeding with close\n", .{});
                    return c.DefWindowProcW(hwnd, msg, wParam, lParam);
                }
                // If already waiting for quit, don't send another request
                if (app.quit_pending) {
                    if (applog.isEnabled()) applog.appLog("[win] WM_CLOSE: quit already pending, ignoring\n", .{});
                    return 0;
                }
                if (app.corep) |corep| {
                    if (applog.isEnabled()) applog.appLog("[win] WM_CLOSE: requesting quit via core (timeout={}ms)\n", .{QUIT_TIMEOUT_MS});
                    app.quit_pending = true;
                    app.quit_timeout_fired = false; // Reset for new quit request
                    // Start timeout timer
                    _ = c.SetTimer(hwnd, TIMER_QUIT_TIMEOUT, QUIT_TIMEOUT_MS, null);
                    core.zonvie_core_request_quit(corep);
                    return 0; // Don't close yet - wait for quit confirmation
                }
            }
            // If no core, allow normal close
            return c.DefWindowProcW(hwnd, msg, wParam, lParam);
        },

        c.WM_NCDESTROY => {
            if (getApp(hwnd)) |app| {
                // Clear userdata first (prevent access by subsequent messages/re-entry)
                _ = c.SetWindowLongPtrW(hwnd, c.GWLP_USERDATA, 0);

                // If owned_by_hwnd, this is the only destroy point
                if (app.owned_by_hwnd) {
                    app.owned_by_hwnd = false; // Safety

                    // Safely clean up renderer/core/etc (deinit is robust even with partial init)
                    app.deinit();

                    const alloc = app.alloc;
                    alloc.destroy(app);
                }
            }
            return c.DefWindowProcW(hwnd, msg, wParam, lParam);
        },

        c.WM_DESTROY => {
            // Remove tray icon before quitting
            if (getApp(hwnd)) |app| {
                if (app.tray_icon) |*tray| {
                    tray.remove();
                }
            }
            // Nvy style: PostQuitMessage(0), exit code returned from main()
            if (applog.isEnabled()) applog.appLog("[win] WM_DESTROY: calling PostQuitMessage(0)\n", .{});
            c.PostQuitMessage(0);
            return 0;
        },

        // DWM custom titlebar: extend frame into client area on activation
        c.WM_ACTIVATE => {
            if (getApp(hwnd)) |app| {
                if (app.ext_tabline_enabled) {
                    // Enable DWM shadow for borderless window by extending frame with minimal margins.
                    // MARGINS.bottom = 1 tricks DWM into thinking there's a frame, which enables the shadow.
                    // This doesn't cause glass overlay issues because the margin is only 1 pixel.
                    const margins = c.MARGINS{ .cxLeftWidth = 0, .cxRightWidth = 0, .cyTopHeight = 0, .cyBottomHeight = 1 };
                    _ = c.DwmExtendFrameIntoClientArea(hwnd, &margins);
                    applog.appLog("[win] WM_ACTIVATE: DwmExtendFrameIntoClientArea applied for shadow\n", .{});
                }
            }
            return c.DefWindowProcW(hwnd, msg, wParam, lParam);
        },

        c.WM_ACTIVATEAPP => {
            // Hide external windows when app loses focus (like macOS hidesOnDeactivate)
            if (getApp(hwnd)) |app| {
                const is_activating = wParam != 0;
                if (!is_activating) {
                    // App is being deactivated - hide mini and message windows
                    inline for ([_]MiniWindowId{ .showmode, .showcmd, .ruler }) |id| {
                        const idx = @intFromEnum(id);
                        if (app.mini_windows[idx].hwnd) |mini_hwnd| {
                            _ = c.ShowWindow(mini_hwnd, c.SW_HIDE);
                        }
                    }
                    if (app.message_window) |msg_win| {
                        _ = c.ShowWindow(msg_win.hwnd, c.SW_HIDE);
                    }
                    // Hide special external windows (cmdline, popupmenu, msg_show, msg_history)
                    app.mu.lock();
                    defer app.mu.unlock();
                    var ext_it = app.external_windows.iterator();
                    while (ext_it.next()) |entry| {
                        const grid_id = entry.key_ptr.*;
                        // Only hide special windows
                        if (grid_id == CMDLINE_GRID_ID or grid_id == POPUPMENU_GRID_ID or grid_id == MESSAGE_GRID_ID or grid_id == MSG_HISTORY_GRID_ID) {
                            _ = c.ShowWindow(entry.value_ptr.hwnd, c.SW_HIDE);
                        }
                    }
                } else {
                    // App is being activated - disable IME if configured
                    if (app.config.ime.disable_on_activate) {
                        setIMEOff(hwnd);
                    }
                    // App is being activated - show special external windows
                    app.mu.lock();
                    defer app.mu.unlock();
                    var ext_it = app.external_windows.iterator();
                    while (ext_it.next()) |entry| {
                        const grid_id = entry.key_ptr.*;
                        if (grid_id == CMDLINE_GRID_ID or grid_id == POPUPMENU_GRID_ID or grid_id == MESSAGE_GRID_ID or grid_id == MSG_HISTORY_GRID_ID) {
                            _ = c.ShowWindow(entry.value_ptr.hwnd, 8); // SW_SHOWNA
                        }
                    }
                }
            }
            return 0;
        },

        c.WM_CAPTURECHANGED => {
            // Mouse capture lost - cancel any tabline drag
            if (getApp(hwnd)) |app| {
                if (app.ext_tabline_enabled and app.tabline_state.dragging_tab != null) {
                    applog.appLog("[tabline] WM_CAPTURECHANGED (parent): cancelling drag!\n", .{});
                    destroyDragPreviewWindow(app);
                    app.tabline_state.cancelDrag();
                    // Invalidate tabline region
                    var tabline_rect: c.RECT = .{
                        .left = 0,
                        .top = 0,
                        .right = 4096,
                        .bottom = TablineState.TAB_BAR_HEIGHT,
                    };
                    var client_rect: c.RECT = undefined;
                    if (c.GetClientRect(hwnd, &client_rect) != 0) {
                        tabline_rect.right = client_rect.right;
                    }
                    _ = c.InvalidateRect(hwnd, &tabline_rect, 0);
                }
            }
            return 0;
        },

        else => {},
    }
    return c.DefWindowProcW(hwnd, msg, wParam, lParam);
}

pub fn main() u8 {
    // Check for askpass mode via environment variable (SSH_ASKPASS helper)
    // SSH calls the program specified in SSH_ASKPASS, so we detect mode via env var
    const ATTACH_PARENT_PROCESS: c.DWORD = 0xFFFFFFFF;
    var askpass_mode_buf: [8]u8 = undefined;
    const askpass_mode_len = c.GetEnvironmentVariableA("ZONVIE_ASKPASS_MODE", &askpass_mode_buf, askpass_mode_buf.len);
    if (askpass_mode_len > 0) {
        // Askpass mode: output password to stdout and exit
        // First check if password is pre-set in environment
        var pwd_buf: [256]u8 = undefined;
        const pwd_len = c.GetEnvironmentVariableA("ZONVIE_SSH_PASSWORD", &pwd_buf, pwd_buf.len);

        // Attach to parent console for stdout output
        _ = c.AttachConsole(ATTACH_PARENT_PROCESS);
        const stdout = c.GetStdHandle(c.STD_OUTPUT_HANDLE);

        if (pwd_len > 0 and pwd_len < pwd_buf.len) {
            // Use pre-set password
            if (stdout != c.INVALID_HANDLE_VALUE) {
                var written: c.DWORD = 0;
                _ = c.WriteFile(stdout, &pwd_buf, pwd_len, &written, null);
                _ = c.WriteFile(stdout, "\n", 1, &written, null);
            }
        } else {
            // No pre-set password: show input dialog
            // Get prompt from command line args (SSH passes prompt as arg)
            var prompt_buf: [256]u16 = undefined;
            const cmdline = c.GetCommandLineW();
            if (cmdline != null) {
                // Parse to get prompt (usually "Enter passphrase for key '...':")
                var i: usize = 0;
                var in_quote = false;
                var arg_start: usize = 0;
                var arg_count: usize = 0;
                const cmdline_slice = std.mem.span(cmdline);
                while (i < cmdline_slice.len) : (i += 1) {
                    const ch = cmdline_slice[i];
                    if (ch == '"') {
                        in_quote = !in_quote;
                    } else if (ch == ' ' and !in_quote) {
                        if (arg_count == 0) {
                            // Skip first arg (exe path)
                            arg_count = 1;
                            arg_start = i + 1;
                        } else {
                            break; // Found second arg
                        }
                    }
                }
                // Copy prompt to buffer
                const prompt_end = @min(i, arg_start + prompt_buf.len - 1);
                if (prompt_end > arg_start) {
                    @memcpy(prompt_buf[0 .. prompt_end - arg_start], cmdline_slice[arg_start..prompt_end]);
                    prompt_buf[prompt_end - arg_start] = 0;
                } else {
                    const default_prompt = std.unicode.utf8ToUtf16LeStringLiteral("Enter password:");
                    @memcpy(prompt_buf[0..default_prompt.len], default_prompt);
                    prompt_buf[default_prompt.len] = 0;
                }
            } else {
                const default_prompt = std.unicode.utf8ToUtf16LeStringLiteral("Enter password:");
                @memcpy(prompt_buf[0..default_prompt.len], default_prompt);
                prompt_buf[default_prompt.len] = 0;
            }

            // Show simple password input dialog using InputBox-style approach
            // Use GetSaveFileNameW trick or simple MessageBox + clipboard workaround
            // For now, use a simple approach: create a tiny window with password field
            var password: [256]u16 = undefined;
            password[0] = 0;
            const dialog_result = showPasswordInputDialog(&prompt_buf, &password);

            if (dialog_result and stdout != c.INVALID_HANDLE_VALUE) {
                // Convert UTF-16 password to UTF-8 and write to stdout
                var utf8_pwd: [512]u8 = undefined;
                var utf8_len: usize = 0;
                for (password) |wch| {
                    if (wch == 0) break;
                    if (wch < 0x80) {
                        if (utf8_len < utf8_pwd.len) {
                            utf8_pwd[utf8_len] = @truncate(wch);
                            utf8_len += 1;
                        }
                    }
                }
                var written: c.DWORD = 0;
                _ = c.WriteFile(stdout, &utf8_pwd, @intCast(utf8_len), &written, null);
                _ = c.WriteFile(stdout, "\n", 1, &written, null);
            }
        }
        return 0; // Exit immediately
    }

    // Initialize startup timing
    _ = c.QueryPerformanceFrequency(&g_startup_freq);
    _ = c.QueryPerformanceCounter(&g_startup_t0);

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    // Load configuration from config.toml
    var t1: c.LARGE_INTEGER = undefined;
    var t2: c.LARGE_INTEGER = undefined;
    _ = c.QueryPerformanceCounter(&t1);
    const config_result = config_mod.loadWithPath(alloc);
    var config = config_result.config;
    _ = c.QueryPerformanceCounter(&t2);
    const config_ms = @divTrunc((t2.QuadPart - t1.QuadPart) * 1000, g_startup_freq.QuadPart);
    defer config.deinit();
    defer if (config_result.path) |p| alloc.free(p);

    // Early debug: write config info to a debug file (before applog is enabled)
    if (std.fs.createFileAbsolute("C:\\Users\\MaruyamaAkiyoshi\\Dev\\zonvie_config_debug.txt", .{ .truncate = true })) |dbg_file| {
        defer dbg_file.close();
        var buf: [1024]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Config path: {s}\nlog.enabled: {}\nlog.path: {s}\nroutes_count: {d}\nroutes_allocated: {}\n", .{
            config_result.path orelse "(none)",
            config.log.enabled,
            config.log.path orelse "(null)",
            config.messages.routes.len,
            config.routes_allocated,
        }) catch "fmt error";
        _ = dbg_file.write(msg) catch {};
    } else |_| {}

    // Parse command line arguments (override config)
    var ext_cmdline_enabled = config.cmdline.external;
    var ext_popup_enabled = config.popup.external;
    var ext_messages_enabled = config.messages.external;
    var ext_tabline_enabled = config.tabline.external;
    var cli_log_path: ?[]const u8 = null;
    var wsl_mode: bool = config.neovim.wsl;
    var wsl_distro: ?[]const u8 = config.neovim.wsl_distro;
    var ssh_mode: bool = config.neovim.ssh;
    var ssh_host: ?[]const u8 = config.neovim.ssh_host;
    var ssh_port: ?u16 = config.neovim.ssh_port;
    var ssh_identity: ?[]const u8 = config.neovim.ssh_identity;
    var devcontainer_mode: bool = false;
    var devcontainer_workspace: ?[]const u8 = null;
    var devcontainer_config: ?[]const u8 = null;
    var devcontainer_rebuild: bool = false;
    const args = std.process.argsAlloc(alloc) catch return 1;
    defer std.process.argsFree(alloc, args);

    // Check for --help / -h first
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            // Attach to parent console for stdout output
            _ = c.AttachConsole(ATTACH_PARENT_PROCESS);
            const stdout = c.GetStdHandle(c.STD_OUTPUT_HANDLE);
            if (stdout != c.INVALID_HANDLE_VALUE) {
                const help_msg =
                    \\zonvie - A high-performance Neovim GUI
                    \\
                    \\USAGE:
                    \\    zonvie.exe [OPTIONS]
                    \\
                    \\OPTIONS:
                    \\    --log <path>                  Write application logs to specified file path
                    \\    --extcmdline                  Enable external command line UI
                    \\    --extpopup                    Enable external popup menu UI
                    \\    --extmessages                 Enable external messages UI
                    \\    --exttabline                  Enable external tabline UI (Chrome-style tabs)
                    \\    --wsl                         Run Neovim inside WSL (default distro)
                    \\    --wsl=<distro>                Run Neovim inside specified WSL distro
                    \\    --ssh=<user@host[:port]>      Connect to remote host via SSH
                    \\    --ssh-identity=<path>         Path to SSH private key file
                    \\    --devcontainer=<workspace>    Run inside a devcontainer
                    \\    --devcontainer-config=<path>  Path to devcontainer.json
                    \\    --devcontainer-rebuild        Rebuild devcontainer before starting
                    \\    --help, -h                    Show this help message and exit
                    \\    --                            Pass all remaining arguments to nvim
                    \\
                    \\CONFIG:
                    \\    Configuration file: %APPDATA%\zonvie\config.toml
                    \\    (or %USERPROFILE%\.config\zonvie\config.toml)
                    \\
                    \\    [neovim]
                    \\        path            Path to Neovim executable
                    \\        wsl             Enable WSL mode (true/false)
                    \\        wsl_distro      WSL distribution name
                    \\        ssh             Enable SSH mode (true/false)
                    \\        ssh_host        SSH host (user@host format)
                    \\        ssh_port        SSH port number
                    \\        ssh_identity    Path to SSH private key
                    \\
                    \\    [font]
                    \\        family          Font family name
                    \\        size            Font size in points
                    \\        linespace       Extra line spacing in pixels
                    \\
                    \\    [cmdline]
                    \\        external        Enable external command line UI
                    \\
                    \\    [popup]
                    \\        external        Enable external popup menu UI
                    \\
                    \\    [messages]
                    \\        external        Enable external messages UI
                    \\
                    \\    [tabline]
                    \\        external        Enable external tabline UI
                    \\
                    \\    [log]
                    \\        enabled         Enable logging (true/false)
                    \\        path            Log file path
                    \\
                    \\    [performance]
                    \\        glyph_cache_ascii_size      ASCII glyph cache size (min: 128)
                    \\        glyph_cache_non_ascii_size  Non-ASCII glyph cache size (min: 64)
                    \\
                    \\For more information, visit: https://github.com/akiyosi/zonvie
                    \\
                ;
                var written: c.DWORD = 0;
                _ = c.WriteFile(stdout, help_msg.ptr, help_msg.len, &written, null);
            }
            return 0;
        }
    }

    // Collect arguments that are NOT zonvie-specific (these will be passed to nvim)
    // After "--", all remaining arguments are passed to nvim
    var nvim_extra_args = std.ArrayListUnmanaged([]const u8){};
    var pass_all_to_nvim = false;

    var i: usize = 1; // Skip argv[0] (executable path)
    while (i < args.len) : (i += 1) {
        const arg = args[i];

        // After "--", pass all remaining arguments to nvim
        if (std.mem.eql(u8, arg, "--")) {
            pass_all_to_nvim = true;
            continue;
        }

        if (pass_all_to_nvim) {
            nvim_extra_args.append(alloc, arg) catch {};
            continue;
        }

        if (std.mem.eql(u8, arg, "--extcmdline")) {
            ext_cmdline_enabled = true;
            applog.appLog("[win] --extcmdline flag detected (override config)\n", .{});
        } else if (std.mem.eql(u8, arg, "--extpopup")) {
            ext_popup_enabled = true;
            applog.appLog("[win] --extpopup flag detected (override config)\n", .{});
        } else if (std.mem.eql(u8, arg, "--extmessages")) {
            ext_messages_enabled = true;
            applog.appLog("[win] --extmessages flag detected (override config)\n", .{});
        } else if (std.mem.eql(u8, arg, "--exttabline")) {
            ext_tabline_enabled = true;
            applog.appLog("[win] --exttabline flag detected (override config)\n", .{});
        } else if (std.mem.eql(u8, arg, "--log")) {
            if (i + 1 < args.len) {
                cli_log_path = args[i + 1];
                i += 1; // skip the path argument
            }
            applog.appLog("[win] --log flag detected\n", .{});
        } else if (std.mem.eql(u8, arg, "--wsl")) {
            wsl_mode = true;
            applog.appLog("[win] --wsl flag detected\n", .{});
        } else if (std.mem.startsWith(u8, arg, "--wsl=")) {
            wsl_mode = true;
            wsl_distro = arg[6..]; // after "--wsl="
            applog.appLog("[win] --wsl={s} flag detected\n", .{wsl_distro.?});
        } else if (std.mem.startsWith(u8, arg, "--ssh=")) {
            ssh_mode = true;
            const value = arg[6..]; // after "--ssh="
            // Parse user@host:port format (port is after last colon, only if numeric)
            if (std.mem.lastIndexOfScalar(u8, value, ':')) |colon_idx| {
                const port_str = value[colon_idx + 1 ..];
                if (std.fmt.parseInt(u16, port_str, 10)) |port| {
                    ssh_host = value[0..colon_idx];
                    ssh_port = port;
                } else |_| {
                    ssh_host = value;
                }
            } else {
                ssh_host = value;
            }
            applog.appLog("[win] --ssh={s} flag detected\n", .{ssh_host.?});
        } else if (std.mem.startsWith(u8, arg, "--ssh-identity=")) {
            ssh_identity = arg[15..]; // after "--ssh-identity="
            applog.appLog("[win] --ssh-identity flag detected\n", .{});
        } else if (std.mem.startsWith(u8, arg, "--devcontainer=")) {
            devcontainer_mode = true;
            devcontainer_workspace = arg[15..]; // after "--devcontainer="
            applog.appLog("[win] --devcontainer={s} flag detected\n", .{devcontainer_workspace.?});
        } else if (std.mem.startsWith(u8, arg, "--devcontainer-config=")) {
            devcontainer_config = arg[22..]; // after "--devcontainer-config="
            applog.appLog("[win] --devcontainer-config flag detected\n", .{});
        } else if (std.mem.eql(u8, arg, "--devcontainer-rebuild")) {
            devcontainer_rebuild = true;
            applog.appLog("[win] --devcontainer-rebuild flag detected\n", .{});
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            // Already handled above, skip
        } else {
            // Not a zonvie argument - pass to nvim
            nvim_extra_args.append(alloc, arg) catch {};
        }
    }

    // Enable logging if configured (CLI --log overrides config)
    if (cli_log_path) |path| {
        applog.setEnabled(true);
        applog.setLogPath(path);
    } else if (config.log.enabled) {
        applog.setEnabled(true);
        applog.setLogPath(config.log.path);
    }

    // Log config info (after applog is enabled)
    applog.appLog("[TIMING] Config.load: {d}ms\n", .{config_ms});
    applog.appLog("[win] Config path: {s}\n", .{config_result.path orelse "(none)"});
    applog.appLog("[win] Config loaded: neovim.path={s}, font.family={s}, font.size={d}, cmdline.external={}, log.enabled={}\n", .{
        config.neovim.path,
        config.font.family,
        config.font.size,
        config.cmdline.external,
        config.log.enabled,
    });
    applog.appLog("[win] Config messages: external={}, routes_count={d}, routes_allocated={}\n", .{
        config.messages.external,
        config.messages.routes.len,
        config.routes_allocated,
    });

    // SSH mode: no early password dialog
    // SSH_ASKPASS mechanism handles password/passphrase on demand (when SSH requests it)
    const early_ssh_password: ?[]const u8 = null;
    if (ssh_mode) {
        applog.appLog("[win] SSH mode: using SSH_ASKPASS for on-demand authentication\n", .{});
    }

    const class_name: [:0]const u16 = std.unicode.utf8ToUtf16LeStringLiteral("ZonvieWin");
    const title: [:0]const u16 = std.unicode.utf8ToUtf16LeStringLiteral("zonvie (win)");

    var wc: c.WNDCLASSEXW = std.mem.zeroes(c.WNDCLASSEXW);
    wc.cbSize = @sizeOf(c.WNDCLASSEXW);
    wc.style = c.CS_HREDRAW | c.CS_VREDRAW;
    wc.lpfnWndProc = WndProc;
    wc.hInstance = c.GetModuleHandleW(null);
    wc.hCursor = c.LoadCursorW(null, @ptrFromInt(32512)); // IDC_ARROW
    wc.hbrBackground = null;
    wc.lpszClassName = @ptrCast(class_name.ptr);

    if (c.RegisterClassExW(&wc) == 0) return 1;


    const app = alloc.create(App) catch return 1;
    // errdefer alloc.destroy(app); // ← Remove this (causes double-free)

    app.* = .{
        .alloc = alloc,
        .config = config,
        .ext_cmdline_enabled = ext_cmdline_enabled,
        .ext_messages_enabled = ext_messages_enabled,
        .ext_tabline_enabled = ext_tabline_enabled,
        .wsl_mode = wsl_mode,
        .wsl_distro = wsl_distro,
        .ssh_mode = ssh_mode,
        .ssh_host = ssh_host,
        .ssh_port = ssh_port,
        .ssh_identity = ssh_identity,
        .ssh_password = early_ssh_password, // Set password from early dialog
        .devcontainer_mode = devcontainer_mode,
        .devcontainer_workspace = devcontainer_workspace,
        .devcontainer_config = devcontainer_config,
        .devcontainer_rebuild = devcontainer_rebuild,
        .nvim_extra_args = nvim_extra_args,
    };

    // Prevent config.deinit from freeing strings now owned by app
    const opacity = app.config.window.opacity;
    config = .{};

    applog.appLog("[win] opacity={d:.2}\n", .{opacity});

    // Use WS_EX_NOREDIRECTIONBITMAP for DirectComposition-based transparency
    const dwExStyle: c.DWORD = if (opacity < 1.0) c.WS_EX_NOREDIRECTIONBITMAP else 0;

    // Custom D3D11 overlay scrollbar (no WS_VSCROLL)
    const window_style: c.DWORD = c.WS_OVERLAPPEDWINDOW | c.WS_VISIBLE;

    _ = c.QueryPerformanceCounter(&t1);
    const hwnd = c.CreateWindowExW(
        dwExStyle,
        @ptrCast(class_name.ptr),
        @ptrCast(title.ptr),
        window_style,
        c.CW_USEDEFAULT, c.CW_USEDEFAULT,
        1000, 700,
        null, null,
        wc.hInstance,
        app, // lpParam -> WM_NCCREATE
    );
    _ = c.QueryPerformanceCounter(&t2);
    const createwin_ms = @divTrunc((t2.QuadPart - t1.QuadPart) * 1000, g_startup_freq.QuadPart);
    applog.appLog("[TIMING] CreateWindowExW: {d}ms\n", .{createwin_ms});

    if (hwnd == null) {
        if (!app.owned_by_hwnd) {
            alloc.destroy(app);
        }
        return 1;
    }

    var msg: c.MSG = undefined;
    while (c.GetMessageW(&msg, null, 0, 0) > 0) {
        _ = c.TranslateMessage(&msg);
        _ = c.DispatchMessageW(&msg);
    }

    // Return nvim's exit code (Nvy style - return from main instead of ExitProcess)
    const exit_code = g_exit_code.load(.seq_cst);
    if (applog.isEnabled()) applog.appLog("[win] message loop ended, returning exit_code={d}\n", .{exit_code});
    return exit_code;
}
