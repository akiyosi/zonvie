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
const render_pipeline_helpers = @import("render_pipeline_helpers.zig");
pub const PaintRetryState = render_pipeline_helpers.PaintRetryState;

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
pub const zonvie_core_start_connect = core.zonvie_core_start_connect;
pub const zonvie_core_stop = core.zonvie_core_stop;
pub const zonvie_core_notify_layout_ready = core.zonvie_core_notify_layout_ready;
pub const zonvie_core_send_input = core.zonvie_core_send_input;
pub const zonvie_core_send_key_event = core.zonvie_core_send_key_event;
pub const zonvie_core_resize = core.zonvie_core_resize;
pub const zonvie_core_try_resize_grid = core.zonvie_core_try_resize_grid;
pub const zonvie_core_get_viewport = core.zonvie_core_get_viewport;
pub const zonvie_core_try_get_viewport = core.zonvie_core_try_get_viewport;
pub const zonvie_core_get_visible_grids = core.zonvie_core_get_visible_grids;
pub const zonvie_core_try_get_visible_grids = core.zonvie_core_try_get_visible_grids;
pub const zonvie_core_try_get_visible_grids_complete = core.zonvie_core_try_get_visible_grids_complete;
pub const zonvie_core_get_cursor_position = core.zonvie_core_get_cursor_position;
pub const zonvie_core_try_get_cursor_position = core.zonvie_core_try_get_cursor_position;
pub const zonvie_core_get_win_id = core.zonvie_core_get_win_id;
pub const zonvie_core_get_current_mode = core.zonvie_core_get_current_mode;
pub const zonvie_core_is_cursor_visible = core.zonvie_core_is_cursor_visible;
pub const zonvie_core_get_cursor_blink = core.zonvie_core_get_cursor_blink;
pub const zonvie_core_try_get_cursor_blink = core.zonvie_core_try_get_cursor_blink;
pub const zonvie_core_send_mouse_scroll = core.zonvie_core_send_mouse_scroll;
pub const zonvie_core_scroll_to_line = core.zonvie_core_scroll_to_line;
pub const zonvie_core_page_scroll = core.zonvie_core_page_scroll;
pub const zonvie_core_process_pending_msg_scroll = core.zonvie_core_process_pending_msg_scroll;
pub const zonvie_core_process_pending_msg_scroll_retry_needed = core.zonvie_core_process_pending_msg_scroll_retry_needed;
pub const zonvie_core_send_mouse_input = core.zonvie_core_send_mouse_input;
pub const zonvie_core_update_layout_px = core.zonvie_core_update_layout_px;
pub const zonvie_core_set_screen_cols = core.zonvie_core_set_screen_cols;
pub const zonvie_core_set_cmdline_default_cols = core.zonvie_core_set_cmdline_default_cols;
pub const zonvie_core_get_hl_by_name = core.zonvie_core_get_hl_by_name;
pub const zonvie_core_get_hl_by_names_batch = core.zonvie_core_get_hl_by_names_batch;
pub const zonvie_core_set_log_enabled = core.zonvie_core_set_log_enabled;
pub const zonvie_core_set_log_perf_only = core.zonvie_core_set_log_perf_only;
pub const zonvie_core_set_ext_cmdline = core.zonvie_core_set_ext_cmdline;
pub const zonvie_core_set_ext_popupmenu = core.zonvie_core_set_ext_popupmenu;
pub const zonvie_core_set_ext_messages = core.zonvie_core_set_ext_messages;
pub const zonvie_core_set_ext_tabline = core.zonvie_core_set_ext_tabline;
pub const zonvie_core_tick_msg_throttle = core.zonvie_core_tick_msg_throttle;
pub const zonvie_core_try_next_msg_timeout_ms = core.zonvie_core_try_next_msg_timeout_ms;
pub const zonvie_core_set_msg_hover = core.zonvie_core_set_msg_hover;
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
pub const zonvie_core_set_preedit = core.zonvie_core_set_preedit;
pub const zonvie_core_clear_preedit = core.zonvie_core_clear_preedit;
pub const zonvie_core_set_option_value = core.zonvie_core_set_option_value;
pub const zonvie_core_set_background_opacity = core.zonvie_core_set_background_opacity;
pub const zonvie_core_perf_now_ns = core.zonvie_core_perf_now_ns;
pub const zonvie_version = core.zonvie_version;
pub const zonvie_core_note_input_trace = core.zonvie_core_note_input_trace;
pub const zonvie_core_abort_flush = core.zonvie_core_abort_flush;
pub const zonvie_core_retry_flush = core.zonvie_core_retry_flush;
pub const zonvie_core_flush_had_atlas_corruption = core.zonvie_core_flush_had_atlas_corruption;
pub const zonvie_core_flush_was_aborted = core.zonvie_core_flush_was_aborted;
pub const zonvie_core_flush_is_retryable = core.zonvie_core_flush_is_retryable;
pub const zonvie_core_invalidate_glyph_cache = core.zonvie_core_invalidate_glyph_cache;

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
// Small shared text helpers
// =========================================================================

/// Length of the longest prefix of `s` that fits in `max_bytes` without
/// splitting a UTF-8 codepoint. Used to truncate user text before copying into
/// a fixed buffer so later UTF-16 conversion can't see a partial codepoint.
pub fn utf8TruncLen(s: []const u8, max_bytes: usize) usize {
    var n = @min(s.len, max_bytes);
    // Back up off any UTF-8 continuation byte (0b10xxxxxx) so we end on a
    // codepoint boundary.
    while (n > 0 and (s[n - 1] & 0xC0) == 0x80) n -= 1;
    return n;
}

/// Basename of a path-like name: the part after the last '/' or '\\'.
/// Returns the whole string when there is no separator.
pub fn baseName(name: []const u8) []const u8 {
    var last: usize = 0;
    for (name, 0..) |ch, j| {
        if (ch == '/' or ch == '\\') last = j + 1;
    }
    return name[last..];
}

// =========================================================================
// Custom window messages (WM_APP + N)
// =========================================================================

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
pub const WM_APP_SHOW_WINDOW: c.UINT = c.WM_APP + 25;
pub const WM_APP_SWP_FRAMECHANGED: c.UINT = c.WM_APP + 26;
pub const WM_APP_POST_SHOW_INIT: c.UINT = c.WM_APP + 27;
/// Posted from onGuiFont/onLineSpace after cell metrics change. The UI
/// thread handler computes the largest window size whose client area is
/// an exact multiple of the new cell, and SetWindowPos's the window to
/// that size. Without this, the bottom/right `client_px % cell_px`
/// remainder strip is outside the cell-aligned NDC viewport used by both
/// the core's vertex generator and the d3d11 renderer's RSSetViewports,
/// so it never receives any draw and shows whatever the renderer last
/// cleared it to (historically hardcoded black).
pub const WM_APP_SNAP_MAIN_WINDOW: c.UINT = c.WM_APP + 28;
/// Posted from the theme-watcher worker thread when the
/// `HKCU\...\Personalize` registry key changes (i.e. the user toggled the
/// OS light/dark mode). The UI thread's handler re-applies the OS-theme
/// titlebar setting to every caption-bearing top-level window via
/// EnumThreadWindows.
pub const WM_APP_THEME_REREAD: c.UINT = c.WM_APP + 29;
/// Posted from the on_guifont callback when nvim sends `:set guifont=*`.
/// The UI thread's handler opens the native ChooseFontW dialog (which must
/// run on the UI thread, not the core thread that fires the callback).
pub const WM_APP_OPEN_FONT_PICKER: c.UINT = c.WM_APP + 30;
/// Posted from WM_PAINT when the D3D11 device is lost (TDR / driver reset).
/// The handler rebuilds the shared device, the D2D interop, the main
/// renderer, and every external window's renderer, then forces a full
/// reseed. Without this the app freezes forever after a TDR.
pub const WM_APP_DEVICE_LOST_RECOVER: c.UINT = c.WM_APP + 31;
/// Posted from onFlushBegin (CORE thread) when it aborts a flush. SetTimer
/// must run on the thread that owns hwnd's message queue (the UI thread),
/// so the core thread cannot arm TIMER_FLUSH_RETRY directly — it records a
/// durable request and posts this wakeup. The UI message loop consumes that
/// request directly if PostMessageW fails because the queue is full.
pub const WM_APP_FLUSH_RETRY_ARM: c.UINT = c.WM_APP + 32;
/// Coalesced request from onFlushEnd to arm/cancel the message throttle
/// one-shot timer after grid_mu has been released.
pub const WM_APP_MSG_THROTTLE_ARM: c.UINT = c.WM_APP + 33;
/// Posted from onFlushEnd when glow first becomes enabled. The UI-thread
/// handler compiles bloom shaders before invalidating glow-enabled surfaces.
pub const WM_APP_PREPARE_GLOW: c.UINT = c.WM_APP + 34;
/// Timer-queue fallback messages are distinct from WM_TIMER so a late
/// callback cannot consume a newer HWND timer generation.
pub const WM_APP_PAINT_RETRY_FALLBACK: c.UINT = c.WM_APP + 35;
pub const WM_APP_DEVICE_LOST_RETRY_FALLBACK: c.UINT = c.WM_APP + 36;
pub const WM_APP_SIZE_REPLAY_FALLBACK: c.UINT = c.WM_APP + 37;
pub const WM_APP_EXTERNAL_CREATE_RETRY_FALLBACK: c.UINT = c.WM_APP + 38;
pub const WM_APP_FLUSH_RETRY_FALLBACK: c.UINT = c.WM_APP + 39;
/// Posted from WM_CREATE when launched with `--dialog`; the handler shows the
/// startup connection dialog once the main window exists (see dialogs.zig).
pub const WM_APP_SHOW_CONNECT_DIALOG: c.UINT = c.WM_APP + 40;
/// Posted from the on_main_grid_size callback when Neovim resizes the global
/// grid itself (`:set columns=` / `:set lines=`). wParam = rows, lParam = cols.
/// The UI thread's handler grows/shrinks the main window by the terminal-area
/// delta. Posted (not sent) because the callback runs on the core thread with
/// grid_mu held, and SetWindowPos would re-enter updateLayoutToCore.
pub const WM_APP_RESIZE_TO_GRID: c.UINT = c.WM_APP + 41;
/// Posted when the pointer enters or leaves a message surface. wParam = 1 for
/// entered, 0 for left; lParam = grid id. Posted (not sent) because the mouse
/// message can be dispatched from a nested message pump inside DXGI Present,
/// which runs while the core's grid lock is held — taking that lock from the
/// handler directly would self-deadlock.
pub const WM_APP_MSG_HOVER: c.UINT = c.WM_APP + 42;

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
/// Timer ID for deferred tray icon initialization
pub const TIMER_TRAY_INIT: c.UINT_PTR = 9;
/// Timer ID for custom shader animation loop (~60Hz redraw trigger).
/// Armed only while a loaded custom shader references time-varying
/// Shadertoy uniforms (iTime / iFrame / etc.). Otherwise rendering stays
/// flush-driven and the process remains 0-CPU idle.
pub const TIMER_CUSTOM_SHADER_ANIM: c.UINT_PTR = 11;
/// ~60Hz cadence for TIMER_CUSTOM_SHADER_ANIM.
pub const CUSTOM_SHADER_ANIM_INTERVAL_MS: c.UINT = 16;
/// AI-agent tab spinner animation timer (only runs while a tab is working).
pub const TIMER_AGENT_SPINNER: c.UINT_PTR = 12;
/// Frame cadence for the agent spinner (matches Claude Code's 120ms).
pub const AGENT_SPINNER_INTERVAL_MS: c.UINT = 120;
/// One-shot retry timer for cursor-blink settings reads that hit grid_mu
/// contention (WM_APP_UPDATE_CURSOR_BLINK is posted while the core thread
/// still holds grid_mu, so a busy tryLock there is structurally common).
pub const TIMER_CURSOR_BLINK_RETRY: c.UINT_PTR = 13;
/// One-shot retry timer for scrollbar updates that only saw a stale cached
/// viewport under grid_mu contention (the WM_APP_UPDATE_SCROLLBAR message
/// is one-shot; without a retry the post-scroll repaint would be dropped).
pub const TIMER_SCROLLBAR_RETRY: c.UINT_PTR = 14;
/// Retry cadence for the two grid_mu-contention retry timers above
/// (mirrors macOS's 16ms timer re-arm for the same conversions).
pub const LOCK_RETRY_INTERVAL_MS: c.UINT = 16;
/// One-shot retry after a failed device-loss recovery. D3D11CreateDevice
/// transiently fails while the driver is still mid-reset right after a TDR,
/// and the WM_PAINT re-post condition (renderer.device_lost) is unreachable
/// once app.renderer is null — this timer is the only retry path then.
pub const TIMER_DEVICE_LOST_RETRY: c.UINT_PTR = 15;
pub const DEVICE_LOST_RETRY_INTERVAL_MS: c.UINT = 1000;
/// Compatibility timer ID for a queued flush retry. New retries use the main
/// message loop's allocation-free deadline driver and exponential backoff, so
/// permanent frontend allocation failures neither lose their wake nor spin at
/// a fixed frame cadence.
pub const TIMER_FLUSH_RETRY: c.UINT_PTR = 16;
pub const FLUSH_RETRY_INTERVAL_MS: c.UINT = LOCK_RETRY_INTERVAL_MS;
pub const FLUSH_RETRY_MAX_MS: u32 = 2000;
/// One-shot completion retry for throttled message-grid scrolling.
pub const TIMER_MSG_SCROLL_RETRY: c.UINT_PTR = 17;
/// Replays an external WM_SIZE that arrived while device recovery held the
/// App/renderer generation in an unpublished state.
pub const TIMER_EXTERNAL_SIZE_REPLAY: c.UINT_PTR = 18;
pub const TIMER_MSG_THROTTLE: c.UINT_PTR = 19;
/// Replays a main-window WM_SIZE suppressed during device recovery so the
/// recovered HWND size is also propagated to Neovim rows/cols.
pub const TIMER_MAIN_SIZE_REPLAY: c.UINT_PTR = 20;
pub const EXTERNAL_CREATE_RETRY_INTERVAL_MS: c.UINT = 100;
pub const EXTERNAL_CREATE_RETRY_MAX_MS: u32 = 5000;
pub const MSG_SCROLL_RETRY_INTERVAL_MS: c.UINT = 16;
/// Tray icon init delay in milliseconds
pub const TRAY_INIT_DELAY_MS: c.UINT = 50;
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
/// Percent of the main window's width the cmdline window spans before its
/// content needs more room. Applies to the whole window, chrome included.
pub const CMDLINE_DEFAULT_WINDOW_PERCENT: u32 = 95;

// --- Msg_show window styling constants ---
pub const MSG_PADDING: u32 = 8; // Padding around content (pixels)

// --- Copy-content button (decorated cmdline / message surfaces) ---
// Unscaled base sizes; every consumer runs them through App.scalePx.
pub const COPY_BUTTON_SIZE: u32 = 18; // Icon box / hit area (pixels)
pub const COPY_BUTTON_MARGIN_LEFT: u32 = 4; // Gap from grid content (pixels)
pub const COPY_BUTTON_MARGIN_RIGHT: u32 = 8; // Gap from trailing edge (pixels)
/// Vertices the copy button consumes: one SDF quad for the icon plus one for
/// the hover wash behind it.
pub const COPY_ICON_VERTS: usize = 12;

// =========================================================================
// Scrollbar throttle
// =========================================================================

pub const SCROLLBAR_THROTTLE_MS: i64 = 32; // ~30fps for smooth but not excessive updates

// =========================================================================
// Global variables
// =========================================================================

// Global exit code for Nvy-style exit (returned from main instead of ExitProcess)
pub var g_exit_code: std.atomic.Value(u8) = std.atomic.Value(u8).init(0);
// Failure/success epochs are the durable retry state. PostMessageW is only a
// wakeup; the UI thread never clears a producer-owned pending flag, so a
// failure racing an older success observation cannot be lost.
pub var g_flush_retry_failure_epoch: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);
pub var g_flush_retry_success_epoch: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);
pub var g_flush_retry_delivery_failed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);
pub var g_external_create_retry_delivery_failed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);
pub var g_device_lost_retry_delivery_failed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);
pub var g_main_size_replay_delivery_failed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);
pub var g_external_size_replay_delivery_failed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);
var g_next_window_wake_cookie: std.atomic.Value(usize) = std.atomic.Value(usize).init(1);

pub fn nextWindowWakeCookie() usize {
    var cookie = g_next_window_wake_cookie.fetchAdd(1, .monotonic);
    if (cookie == 0) cookie = g_next_window_wake_cookie.fetchAdd(1, .monotonic);
    return cookie;
}

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
    /// Monotonic identifier assigned by onExternalWindow at enqueue.
    /// The corresponding WM_APP_CREATE_EXTERNAL_WINDOW message carries
    /// this value in lParam so the UI-thread handler can dequeue the
    /// exact request the message was posted for. Without this, an old-
    /// session WM_APP_CREATE message could pick up a same-grid_id new-
    /// session request that landed in the queue after a session reset.
    /// Coalescing same-grid_id requests in onExternalWindow preserves
    /// the existing entry's seq so the original posted message still
    /// matches.
    seq: u64,
    /// Set while the UI thread is attempting the fallible HWND/renderer/map
    /// creation. The request stays queued until every step succeeds so a
    /// transient failure can be retried without allocating another entry.
    create_in_progress: bool = false,
    /// Incremented whenever a same-grid lifecycle callback replaces the
    /// geometry while this request is being created from an older snapshot.
    update_revision: u64 = 0,
    /// A close received while create_in_progress cannot remove this storage;
    /// the UI thread observes this flag and tears down any just-published HWND.
    cancel_requested: bool = false,
};

/// CPU-side surface state shared between external windows and pending
/// external vertices. Holds vertex storage, grid dimensions, dirty
/// tracking, and cursor row info. GPU resources (VBs, scratch buffers)
/// remain on the owning window struct.
pub const SurfaceState = struct {
    verts: std.ArrayListUnmanaged(Vertex) = .empty,
    row_verts: std.ArrayListUnmanaged(RowVerts) = .empty,
    cursor_verts: std.ArrayListUnmanaged(Vertex) = .empty,
    row_mode: bool = false,
    paint_full: bool = true,
    rows: u32 = 0,
    cols: u32 = 0,
    last_cursor_row: ?u32 = null,

    pub fn ensureRowStorage(self: *SurfaceState, alloc: std.mem.Allocator, row: u32) bool {
        const need: usize = @intCast(row + 1);
        if (self.row_verts.items.len >= need) return true;
        const old_len = self.row_verts.items.len;
        self.row_verts.resize(alloc, need) catch return false;
        var i = old_len;
        while (i < need) : (i += 1) {
            self.row_verts.items[i] = .{};
        }
        return true;
    }

    pub fn truncateRows(self: *SurfaceState, alloc: std.mem.Allocator, needed_rows: u32) usize {
        const start: usize = @intCast(needed_rows);
        if (start >= self.row_verts.items.len) return 0;
        var removed: usize = 0;
        for (self.row_verts.items[start..]) |*rv| {
            removed += rv.verts.items.len;
            rv.verts.deinit(alloc);
            rv.* = .{};
        }
        self.row_verts.shrinkAndFree(alloc, start);
        return removed;
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
    row_map: std.ArrayListUnmanaged(RowMapping) = .empty, // logical row → physical slot index
    flat_verts: std.ArrayListUnmanaged(Vertex) = .empty,
    row_mode: bool = false,
    rows: u32 = 0,
    cols: u32 = 0,
    // Shared font/cell/linespace generation used to build row NDC. Main
    // drawable-only resizes deliberately do not affect this value.
    metrics_gen: u64 = 0,

    pub fn ensureRowStorage(self: *VertexSet, alloc: std.mem.Allocator, row: u32) bool {
        const need: usize = @intCast(row + 1);
        if (self.row_map.items.len >= need) return true;
        const old_len = self.row_map.items.len;
        self.row_map.resize(alloc, need) catch return false;
        var i = old_len;
        while (i < need) : (i += 1) {
            self.row_map.items[i] = .{};
        }
        return true;
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
                total += pool.slotPtrConst(m.slot).verts.items.len;
            }
        }
        return total;
    }

    /// Free VertexSet-owned arrays. Slot memory is owned by SlotPool.
    /// Caller must releaseAllSlots before calling this.
    pub fn deinitCpu(self: *VertexSet, alloc: std.mem.Allocator) void {
        self.flat_verts.deinit(alloc);
        self.row_map.deinit(alloc);
    }
};

/// Cursor publication is independent from the O(rows) row-map
/// snapshot. Cursor callbacks replace this complete (small) buffer, so a
/// cursor-only flush can rotate one of these sets without cloning row slots.
pub const CursorSet = struct {
    verts: std.ArrayListUnmanaged(Vertex) = .empty,
    last_cursor_row: ?u32 = null,

    fn deinit(self: *CursorSet, alloc: std.mem.Allocator) void {
        self.verts.deinit(alloc);
    }
};

/// Snapshot returned by acquireForPaint.
pub const PaintSnapshot = struct {
    committed_index: u8,
    cursor_index: u8,
    paint_full: bool,
    /// Scroll state bundled with this committed set (consumed atomically).
    scroll_rect: ?c.RECT = null,
    scroll_dy_px: i32 = 0,
    vb_shift: i32 = 0,
    /// Scroll region in rows, matching remapRowSlots' [row_start, row_end).
    scroll_row_start: u32 = 0,
    scroll_row_end: u32 = 0,
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
    pub const SET_COUNT = render_pipeline_helpers.SparseRowSyncStorage.set_count;
    sets: [SET_COUNT]VertexSet = .{ .{}, .{}, .{} },
    pool: SlotPool = .{}, // Shared slot pool across all sets

    // --- rotation_mu protects these fields ---
    rotation_mu: std.Io.Mutex = .init,
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

    // The cursor rotates under the same lock as the row sets, but has its
    // own read refs so cursor-only flushes never touch the row_map.
    main_cursor_sets: [SET_COUNT]CursorSet = .{ .{}, .{}, .{} },
    main_cursor_write_index: u8 = 0,
    main_cursor_committed_index: u8 = 1,
    main_cursor_in_flush: bool = false,
    main_cursor_flush_paint_full: bool = false,
    main_cursor_flush_old_row: ?u32 = null,
    main_cursor_flush_new_row: ?u32 = null,
    main_cursor_ui_read_refcount: [SET_COUNT]u32 = .{ 0, 0, 0 },

    // Dirty state accumulation (rotation_mu protected, WM_PAINT clears).
    pending_dirty: std.DynamicBitSetUnmanaged = .{},
    pending_paint_full: bool = true,

    // Flush-local dirty state plus the per-set sparse catch-up history.
    // Extracted as a production type so partial allocation failures can be
    // exhaustively tested on non-Windows hosts without importing Win32.
    sparse_sync: render_pipeline_helpers.SparseRowSyncStorage = .{},
    flush_paint_full: bool = false,
    flush_requires_full_sync: bool = false,

    // Flush-local scroll state (core thread only, no lock needed).
    // Accumulated by onMainRowScroll / onGridRowScroll during a single flush.
    flush_scroll_rect: ?c.RECT = null,
    flush_scroll_dy_px: i32 = 0,
    flush_vb_shift: i32 = 0,
    // Scroll region bounds in rows, matching remapRowSlots' [row_start, row_end).
    // Used by applyScrollShift to limit shiftRowVBs to the same range.
    flush_scroll_row_start: u32 = 0,
    flush_scroll_row_end: u32 = 0,

    // Pending scroll state (rotation_mu protected).
    // Merged from flush_scroll_* at commitFlush, consumed at acquireForPaint.
    pending_scroll_rect: ?c.RECT = null,
    pending_scroll_dy_px: i32 = 0,
    pending_vb_shift: i32 = 0,
    pending_scroll_row_start: u32 = 0,
    pending_scroll_row_end: u32 = 0,

    // Paint-time dirty snapshot (rotation_mu protected, persistent, no per-paint alloc).
    paint_dirty_snapshot: std.DynamicBitSetUnmanaged = .{},
    paint_nesting: u32 = 0,

    /// Begin a flush cycle. Picks a free write set and catches up only slot
    /// mappings changed since that set's previous publication.
    /// Returns false on alloc failure or no free set (caller should abort flush).
    pub fn beginFlush(self: *TripleBufferedSurface, alloc: std.mem.Allocator) bool {
        var picked: ?u8 = null;
        var ci: u8 = undefined;

        {
            self.rotation_mu.lockUncancelable(core.clock.io());
            defer self.rotation_mu.unlock(core.clock.io());
            ci = self.committed_index;
            var best_cost: usize = std.math.maxInt(usize);
            for (0..SET_COUNT) |i| {
                const idx: u8 = @intCast(i);
                if (idx != ci and self.ui_read_refcount[i] == 0) {
                    const cost = if (self.sparse_sync.row_sync_full[i])
                        std.math.maxInt(usize)
                    else
                        self.sparse_sync.row_sync_rows[i].items.len;
                    if (picked == null or cost < best_cost) {
                        picked = idx;
                        best_cost = cost;
                    }
                }
            }
            if (picked == null) return false;
            self.write_index = picked.?;
            self.flush_source_index = ci;
        }

        const wi = picked.?;

        // Recover a previously partial sparse-storage grow before any write
        // set mutation. The common case is an allocation-free readiness check.
        if (!self.prepareRowSyncTracking(alloc, self.sets[ci].row_map.items.len)) return false;

        const perf_enabled = applog.isEnabled();
        var sync_freq: c.LARGE_INTEGER = undefined;
        var sync_start: c.LARGE_INTEGER = undefined;
        if (perf_enabled) {
            _ = c.QueryPerformanceFrequency(&sync_freq);
            _ = c.QueryPerformanceCounter(&sync_start);
        }
        const sparse_row_count = self.sparse_sync.row_sync_rows[wi].items.len;
        const did_full_sync = self.sparse_sync.row_sync_full[wi] or
            self.sets[wi].row_map.items.len != self.sets[ci].row_map.items.len;

        // Bring only mappings changed while this set was spare/read-owned up
        // to the committed snapshot. Dimension/layout barriers use the old
        // full clone path, but steady one-row updates touch one mapping.
        if (!self.syncVertexSetForWrite(alloc, wi, ci)) return false;

        if (perf_enabled) {
            var sync_end: c.LARGE_INTEGER = undefined;
            _ = c.QueryPerformanceCounter(&sync_end);
            const sync_us: i64 = if (sync_freq.QuadPart > 0)
                @divTrunc((sync_end.QuadPart - sync_start.QuadPart) * 1_000_000, sync_freq.QuadPart)
            else
                0;
            applog.appLog(
                "[perf] tbs_begin_sync rows={d} sparse_rows={d} full={d} total_us={d}\n",
                .{ self.sets[ci].row_map.items.len, sparse_row_count, @intFromBool(did_full_sync), sync_us },
            );
        }

        // Clear flush-local dirty state.
        self.sparse_sync.clearFlushDirty();
        self.sparse_sync.clearFlushMapping();
        self.flush_paint_full = false;
        self.flush_requires_full_sync = false;

        // Clear flush-local scroll state.
        self.flush_scroll_rect = null;
        self.flush_scroll_dy_px = 0;
        self.flush_vb_shift = 0;
        self.flush_scroll_row_start = 0;
        self.flush_scroll_row_end = 0;

        self.is_in_flush = true;
        return true;
    }

    /// Reserve persistent sparse-sync state. This storage is core-owned and
    /// may be resized while a UI reader holds a VertexSet; row maps themselves
    /// are never reallocated through this method.
    pub fn prepareRowSyncTracking(self: *TripleBufferedSurface, alloc: std.mem.Allocator, row_count: usize) bool {
        self.sparse_sync.prepare(alloc, row_count) catch return false;
        std.debug.assert(self.sparse_sync.isReady(row_count));
        return true;
    }

    /// Mark a visual row dirty without claiming that its slot mapping changed
    /// (cursor damage uses this path).
    pub fn markFlushDirtyRow(self: *TripleBufferedSurface, row: usize) bool {
        return self.sparse_sync.markFlushDirtyRow(row);
    }

    /// Mark a row whose logical-to-physical slot mapping changed, and mark it
    /// visually dirty as well.
    pub fn markFlushRowChanged(self: *TripleBufferedSurface, row: usize) bool {
        if (!self.markFlushDirtyRow(row)) return false;
        return self.markFlushMappingChanged(row);
    }

    /// Record a mapping-only change, such as a non-vacated scroll row that is
    /// moved by Present1 instead of redrawn.
    pub fn markFlushMappingChanged(self: *TripleBufferedSurface, row: usize) bool {
        return self.sparse_sync.markFlushMappingRow(row);
    }

    pub fn requireFullRowSync(self: *TripleBufferedSurface) void {
        self.flush_requires_full_sync = true;
    }

    /// Replace the complete cursor buffer for this flush. The
    /// candidate is reserved before any bytes are overwritten, so OOM leaves
    /// the last committed cursor intact and the caller can abort the flush.
    pub fn storeMainCursor(
        self: *TripleBufferedSurface,
        alloc: std.mem.Allocator,
        verts: []const Vertex,
        last_cursor_row: ?u32,
    ) bool {
        if (!self.main_cursor_in_flush) {
            var picked: ?u8 = null;
            self.rotation_mu.lockUncancelable(core.clock.io());
            const ci = self.main_cursor_committed_index;
            for (0..SET_COUNT) |i| {
                const idx: u8 = @intCast(i);
                if (idx != ci and self.main_cursor_ui_read_refcount[i] == 0) {
                    picked = idx;
                    break;
                }
            }
            self.rotation_mu.unlock(core.clock.io());
            if (picked == null) return false;

            const dst = &self.main_cursor_sets[picked.?];
            dst.verts.ensureTotalCapacity(alloc, verts.len) catch return false;
            self.main_cursor_write_index = picked.?;
            self.main_cursor_flush_paint_full = false;
            self.main_cursor_flush_old_row = self.main_cursor_sets[ci].last_cursor_row;
            self.main_cursor_in_flush = true;
        } else {
            self.main_cursor_sets[self.main_cursor_write_index].verts.ensureTotalCapacity(alloc, verts.len) catch return false;
        }

        const dst = &self.main_cursor_sets[self.main_cursor_write_index];
        dst.verts.clearRetainingCapacity();
        dst.verts.appendSliceAssumeCapacity(verts);
        dst.last_cursor_row = last_cursor_row;
        self.main_cursor_flush_new_row = last_cursor_row;
        return true;
    }

    /// Reserve the cursor candidate selected by storeMainCursor without
    /// publishing it. External-window seed application uses this to keep all
    /// fallible allocations ahead of its row/cursor publication phase.
    pub fn reserveMainCursorCapacity(
        self: *TripleBufferedSurface,
        alloc: std.mem.Allocator,
        vert_count: usize,
    ) bool {
        var candidate = self.main_cursor_write_index;
        if (!self.main_cursor_in_flush) {
            var picked: ?u8 = null;
            self.rotation_mu.lockUncancelable(core.clock.io());
            const ci = self.main_cursor_committed_index;
            for (0..SET_COUNT) |i| {
                const idx: u8 = @intCast(i);
                if (idx != ci and self.main_cursor_ui_read_refcount[i] == 0) {
                    picked = idx;
                    break;
                }
            }
            self.rotation_mu.unlock(core.clock.io());
            candidate = picked orelse return false;
        }
        self.main_cursor_sets[candidate].verts.ensureTotalCapacity(alloc, vert_count) catch return false;
        return true;
    }

    pub fn markFlushPaintFull(self: *TripleBufferedSurface) void {
        if (self.is_in_flush) self.flush_paint_full = true;
        if (self.main_cursor_in_flush) self.main_cursor_flush_paint_full = true;
    }

    /// Cancel a flush (reset is_in_flush without committing).
    pub fn cancelFlush(self: *TripleBufferedSurface) void {
        if (self.is_in_flush) self.sparse_sync.row_sync_full[self.write_index] = true;
        self.is_in_flush = false;
        self.main_cursor_in_flush = false;
        self.main_cursor_flush_paint_full = false;
        self.main_cursor_flush_old_row = null;
        self.main_cursor_flush_new_row = null;
    }

    /// Commit the write set as the new committed set.
    pub fn commitFlush(self: *TripleBufferedSurface, alloc: std.mem.Allocator) void {
        if (!self.is_in_flush and !self.main_cursor_in_flush) return;

        self.rotation_mu.lockUncancelable(core.clock.io());
        defer self.rotation_mu.unlock(core.clock.io());

        // Cursor and rows publish while holding the same lock. A paint can
        // therefore observe either the complete old pair or complete new pair,
        // never new rows with the previous cursor (or vice versa).
        if (self.main_cursor_in_flush) {
            // The retained back texture contains no cursor after a row draw,
            // but the currently presented buffer does. Redraw both logical
            // rows before overlaying the replacement cursor so moves, shape
            // changes, and disappearance cannot leave the previous cursor.
            const row_count: usize = if (self.is_in_flush)
                self.sets[self.write_index].row_map.items.len
            else
                self.sets[self.committed_index].row_map.items.len;
            if (self.pending_dirty.bit_length != row_count) {
                self.pending_dirty.resize(alloc, row_count, false) catch {
                    self.pending_paint_full = true;
                };
            }
            if (self.pending_dirty.bit_length == row_count) {
                var cursor_dirty_storage: [2]usize = undefined;
                for (render_pipeline_helpers.cursorDirtyRows(
                    self.main_cursor_flush_old_row,
                    self.main_cursor_flush_new_row,
                    row_count,
                    &cursor_dirty_storage,
                )) |row_index| self.pending_dirty.set(row_index);
            } else {
                self.pending_paint_full = true;
            }
            self.main_cursor_committed_index = self.main_cursor_write_index;
            if (self.main_cursor_flush_paint_full) self.pending_paint_full = true;
            self.main_cursor_in_flush = false;
            self.main_cursor_flush_paint_full = false;
            self.main_cursor_flush_old_row = null;
            self.main_cursor_flush_new_row = null;
        }
        if (!self.is_in_flush) return;

        // Merge flush_dirty into pending_dirty.
        if (self.sparse_sync.flush_dirty.bit_length > 0) {
            if (self.pending_dirty.bit_length != self.sparse_sync.flush_dirty.bit_length) {
                // Resize pending_dirty to match flush_dirty.
                self.pending_dirty.resize(alloc, self.sparse_sync.flush_dirty.bit_length, false) catch {
                    // Dirty-rect precision is optional; row-map publication
                    // and spare-set catch-up are not. Fall back to a full
                    // paint but continue through the single publication path.
                    self.pending_paint_full = true;
                };
                // Resize paint_dirty_snapshot if no paint is active.
                if (self.paint_nesting == 0) {
                    self.paint_dirty_snapshot.resize(alloc, self.sparse_sync.flush_dirty.bit_length, false) catch {
                        self.pending_paint_full = true;
                    };
                }
                // else: deferred to next acquireForPaint when nesting=0
            }

            // Bitwise OR merge: pending_dirty |= flush_dirty
            if (self.pending_dirty.bit_length == self.sparse_sync.flush_dirty.bit_length) {
                for (self.sparse_sync.flush_dirty_rows.items) |row| {
                    if (row < self.pending_dirty.bit_length) self.pending_dirty.set(row);
                }
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
                    // row_start/end unchanged: same region by definition
                } else {
                    // Different scroll region: invalidate optimization, fall back to full paint.
                    self.pending_scroll_rect = null;
                    self.pending_scroll_dy_px = 0;
                    self.pending_vb_shift = 0;
                    self.pending_scroll_row_start = 0;
                    self.pending_scroll_row_end = 0;
                    self.pending_paint_full = true;
                }
            } else {
                self.pending_scroll_rect = flush_rect;
                self.pending_scroll_dy_px = self.flush_scroll_dy_px;
                self.pending_vb_shift = self.flush_vb_shift;
                self.pending_scroll_row_start = self.flush_scroll_row_start;
                self.pending_scroll_row_end = self.flush_scroll_row_end;
            }
        }
        // Non-fast-path flushes (flush_scroll_rect == null) do NOT invalidate
        // an existing pending_scroll_rect.  beginFlush shallow-copies the
        // committed set, so the write set inherits the prior scroll-shifted
        // row_map.  A subsequent non-scroll flush only updates specific rows
        // via on_vertices_row; the shift described by pending_scroll_* still
        // matches the committed row_map at paint time.

        const old_committed = self.committed_index;
        const new_committed = self.write_index;
        const new_set = &self.sets[new_committed];
        const old_set = &self.sets[old_committed];
        const structural_barrier = self.flush_requires_full_sync or
            new_set.row_mode != old_set.row_mode or
            new_set.rows != old_set.rows or
            new_set.cols != old_set.cols or
            new_set.metrics_gen != old_set.metrics_gen;

        // Publish an exact row-map snapshot while keeping spare sets caught up
        // by only the mappings changed in this flush. Reader-owned sets merely
        // accumulate sparse indices and are synchronized after release.
        self.clearSetStaleTracking(new_committed);
        for (0..SET_COUNT) |i| {
            const idx: u8 = @intCast(i);
            if (idx == new_committed) continue;
            if (structural_barrier) {
                self.sparse_sync.row_sync_full[i] = true;
                self.sparse_sync.clearSetStale(i);
            } else if (!self.sparse_sync.row_sync_full[i]) {
                for (self.sparse_sync.flush_mapping_rows.items) |row| {
                    if (!self.addSetStaleRow(idx, row)) {
                        self.sparse_sync.row_sync_full[i] = true;
                        self.sparse_sync.clearSetStale(i);
                        break;
                    }
                }
            }

            // A spare set that never saw this layout (e.g. a surface whose
            // committed set was seeded directly, so the spare row_maps are
            // still empty) cannot be caught up by row indices: sparse sync
            // indexes both maps by the same row. Force the full copy path,
            // matching the guard syncVertexSetForWrite already applies.
            if (self.sets[idx].row_map.items.len != new_set.row_map.items.len) {
                self.sparse_sync.row_sync_full[i] = true;
            }

            if (self.ui_read_refcount[i] == 0) {
                if (self.sparse_sync.row_sync_full[i]) {
                    if (self.shallowCopyVertexSet(alloc, idx, new_committed)) {
                        self.clearSetStaleTracking(idx);
                    }
                } else {
                    self.applySparseRowSync(alloc, idx, new_committed);
                }
            }
        }

        self.committed_index = new_committed;
        self.commit_rev +%= 1;
        self.is_in_flush = false;
    }

    /// Get the current write set (core thread, during flush only).
    pub fn writeSet(self: *TripleBufferedSurface) *VertexSet {
        return &self.sets[self.write_index];
    }

    /// Acquire the committed set for painting. Returns snapshot info.
    /// Caller must call releaseFromPaint when done.
    pub fn acquireForPaint(self: *TripleBufferedSurface, alloc: std.mem.Allocator) PaintSnapshot {
        self.rotation_mu.lockUncancelable(core.clock.io());
        defer self.rotation_mu.unlock(core.clock.io());

        const ci = self.committed_index;
        const cursor_ci = self.main_cursor_committed_index;
        self.ui_read_refcount[ci] += 1;
        self.main_cursor_ui_read_refcount[cursor_ci] += 1;

        var paint_full: bool = false;

        if (self.paint_nesting == 0) {
            // Outermost paint: snapshot dirty state.
            var snapshot_ready = true;
            if (self.paint_dirty_snapshot.bit_length != self.pending_dirty.bit_length) {
                // A dimension-changing commit can land while another paint is
                // active, in which case commitFlush deliberately defers this
                // resize. Retry it here; otherwise the mismatch would persist
                // forever because pending_dirty already has the new length and
                // later commits no longer enter their resize branch.
                self.paint_dirty_snapshot.resize(alloc, self.pending_dirty.bit_length, false) catch {
                    snapshot_ready = false;
                    self.pending_paint_full = true;
                    self.pending_dirty.unsetAll();
                    self.paint_dirty_snapshot.unsetAll();
                };
            }
            if (snapshot_ready and self.pending_dirty.bit_length > 0) {
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
        var scroll_row_start: u32 = 0;
        var scroll_row_end: u32 = 0;
        if (self.paint_nesting == 0) {
            scroll_rect = self.pending_scroll_rect;
            scroll_dy_px = self.pending_scroll_dy_px;
            vb_shift = self.pending_vb_shift;
            scroll_row_start = self.pending_scroll_row_start;
            scroll_row_end = self.pending_scroll_row_end;
            self.pending_scroll_rect = null;
            self.pending_scroll_dy_px = 0;
            self.pending_vb_shift = 0;
            self.pending_scroll_row_start = 0;
            self.pending_scroll_row_end = 0;
        }

        self.paint_nesting += 1;
        return .{
            .committed_index = ci,
            .cursor_index = cursor_ci,
            .paint_full = paint_full,
            .scroll_rect = scroll_rect,
            .scroll_dy_px = scroll_dy_px,
            .vb_shift = vb_shift,
            .scroll_row_start = scroll_row_start,
            .scroll_row_end = scroll_row_end,
        };
    }

    /// Release the committed set after painting. Returns true if
    /// InvalidateRect is needed (pending dirty accumulated during paint).
    pub fn releaseFromPaint(self: *TripleBufferedSurface, index: u8, cursor_index: u8) bool {
        self.rotation_mu.lockUncancelable(core.clock.io());
        defer self.rotation_mu.unlock(core.clock.io());
        self.ui_read_refcount[index] -= 1;
        self.main_cursor_ui_read_refcount[cursor_index] -= 1;
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

    fn clearSetStaleTracking(self: *TripleBufferedSurface, idx: u8) void {
        self.sparse_sync.row_sync_full[idx] = false;
        self.sparse_sync.clearSetStale(idx);
    }

    fn addSetStaleRow(self: *TripleBufferedSurface, idx: u8, row: u32) bool {
        const stale = &self.sparse_sync.row_sync_stale[idx];
        if (row >= stale.bit_length) return false;
        if (!stale.isSet(row)) {
            // prepareRowSyncTracking reserves row_count entries, so this is
            // infallible in steady state. If a caller missed the dimension
            // barrier, conservatively force a complete clone.
            if (self.sparse_sync.row_sync_rows[idx].items.len == self.sparse_sync.row_sync_rows[idx].capacity) return false;
            self.sparse_sync.row_sync_rows[idx].appendAssumeCapacity(row);
            stale.set(row);
        }
        return true;
    }

    fn applySparseRowSync(self: *TripleBufferedSurface, alloc: std.mem.Allocator, dst_idx: u8, src_idx: u8) void {
        const dst = &self.sets[dst_idx];
        const src = &self.sets[src_idx];
        std.debug.assert(dst.row_map.items.len == src.row_map.items.len);
        for (self.sparse_sync.row_sync_rows[dst_idx].items) |row_u32| {
            const row: usize = @intCast(row_u32);
            if (row >= dst.row_map.items.len) continue;
            const old_slot = dst.row_map.items[row].slot;
            const new_slot = src.row_map.items[row].slot;
            if (old_slot != new_slot) {
                // Retain first: releasing an exclusive old slot puts it on
                // free_list immediately and must never race a same-slot retain.
                self.pool.retain(new_slot);
                self.pool.release(alloc, old_slot);
                dst.row_map.items[row] = src.row_map.items[row];
            }
        }
        dst.row_mode = src.row_mode;
        dst.rows = src.rows;
        dst.cols = src.cols;
        dst.metrics_gen = src.metrics_gen;
        self.clearSetStaleTracking(dst_idx);
    }

    fn syncVertexSetForWrite(self: *TripleBufferedSurface, alloc: std.mem.Allocator, dst_idx: u8, src_idx: u8) bool {
        const dst = &self.sets[dst_idx];
        const src = &self.sets[src_idx];
        if (self.sparse_sync.row_sync_full[dst_idx] or dst.row_map.items.len != src.row_map.items.len) {
            if (!self.shallowCopyVertexSet(alloc, dst_idx, src_idx)) return false;
            self.clearSetStaleTracking(dst_idx);
            return true;
        }

        // Reserve payload arrays before mutating any mapping, preserving the
        // existing all-or-nothing beginFlush failure contract.
        if (!src.row_mode) {
            dst.flat_verts.ensureTotalCapacity(alloc, src.flat_verts.items.len) catch return false;
        }
        self.applySparseRowSync(alloc, dst_idx, src_idx);
        if (!src.row_mode) {
            dst.flat_verts.clearRetainingCapacity();
            dst.flat_verts.appendSliceAssumeCapacity(src.flat_verts.items);
        }
        return true;
    }

    /// Shallow-copy slot mappings from src set to dst set (COW).
    /// Only copies the u16 row_map array + retains slots. ~130 bytes for 65 rows.
    /// Returns false on alloc failure.
    fn shallowCopyVertexSet(self: *TripleBufferedSurface, alloc: std.mem.Allocator, dst_idx: u8, src_idx: u8) bool {
        const dst = &self.sets[dst_idx];
        const src = &self.sets[src_idx];

        // Reserve every destination array before releasing any slot references
        // or changing scalar state. A failed beginFlush must leave the candidate
        // set intact so a later retry can safely reuse it.
        const src_len = src.row_map.items.len;
        dst.row_map.ensureTotalCapacity(alloc, src_len) catch return false;
        if (!src.row_mode) {
            dst.flat_verts.ensureTotalCapacity(alloc, src.flat_verts.items.len) catch return false;
        }

        // All remaining operations are infallible.
        dst.releaseAllSlots(alloc, &self.pool);

        // Copy scalar fields (no alloc).
        dst.row_mode = src.row_mode;
        dst.rows = src.rows;
        dst.cols = src.cols;
        dst.metrics_gen = src.metrics_gen;

        // Shallow copy row_map (u16 array).
        dst.row_map.items.len = src_len;
        @memcpy(dst.row_map.items[0..src_len], src.row_map.items[0..src_len]);

        // Retain all slot references for dst.
        for (dst.row_map.items) |m| {
            self.pool.retain(m.slot);
        }

        // Flat verts are irrelevant in row mode. Avoid copying an old flat
        // payload on a row-mode barrier/catch-up; a transition back to flat
        // mode publishes a complete replacement payload.
        if (!src.row_mode) {
            dst.flat_verts.clearRetainingCapacity();
            dst.flat_verts.appendSliceAssumeCapacity(src.flat_verts.items);
        }

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
            return self.pool.slotPtr(new_idx);
        }

        if (self.pool.slotPtr(old_slot).ref_count > 1) {
            // COW: allocate new slot, release old.
            const new_idx = self.pool.acquireSlot(alloc) orelse return null;
            self.pool.release(alloc, old_slot);
            mapping.slot = new_idx;
            self.pool.retain(new_idx);
            return self.pool.slotPtr(new_idx);
        }

        // Exclusive ownership — write in place.
        return self.pool.slotPtr(old_slot);
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
        for (&self.main_cursor_sets) |*set| set.deinit(alloc);
        // Free slot pool (vertex memory lives in slots).
        self.pool.deinit(alloc);
        self.pending_dirty.deinit(alloc);
        self.sparse_sync.deinit(alloc);
        self.paint_dirty_snapshot.deinit(alloc);
    }
};

/// Pending vertices for an external window that hasn't been created yet.
/// Uses SurfaceState (legacy RowVerts) since TBS is not set up until window creation.
pub const PendingExternalVertices = struct {
    grid_id: i64,
    flush_generation: u64 = 0,
    metrics_gen: u64 = 0,
    surface: SurfaceState,

    pub fn deinit(self: *PendingExternalVertices, alloc: std.mem.Allocator) void {
        for (self.surface.row_verts.items) |*rv| {
            if (rv.vb) |vb| _ = vb.lpVtbl.*.Release.?(vb);
        }
        self.surface.deinitCpuState(alloc);
    }
};

// user32 LoadIconW redeclared with an align-agnostic resource-name pointer and
// a direct HICON return, so the odd app-icon ordinal (MAKEINTRESOURCE(1)) does
// not trip the Debug alignment assertion. Same shim as main.zig's; see the
// MAKEINTRESOURCE alignment gotcha.
extern "user32" fn LoadIconW(hInstance: c.HINSTANCE, lpIconName: ?*const anyopaque) callconv(.winapi) c.HICON;

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
        // Zonvie app icon (window class icon, resource ordinal 1) rather than the
        // generic IDI_APPLICATION. Shared HICON (no DestroyIcon needed);
        // GetModuleHandleW(null) is the exe module that owns the resource.
        nid.hIcon = LoadIconW(c.GetModuleHandleW(null), @ptrFromInt(@as(usize, 1)));
        // Set tip text "Zonvie"
        const tip = [_]u16{ 'Z', 'o', 'n', 'v', 'i', 'e', 0 };
        @memcpy(nid.szTip[0..tip.len], &tip);
        return .{ .nid = nid };
    }

    /// Register the icon. Returns whether the icon is present afterward
    /// (true if already added, or NIM_ADD succeeded). Callers that hide the
    /// window to the tray must check this so they never hide with no icon.
    pub fn add(self: *TrayIcon) bool {
        if (!self.added) {
            if (c.Shell_NotifyIconW(c.NIM_ADD, &self.nid) == 0) {
                if (applog.isEnabled()) applog.appLog("[tray] Shell_NotifyIconW(NIM_ADD) failed\n", .{});
                return false;
            }
            self.added = true;
            if (applog.isEnabled()) applog.appLog("[tray] added tray icon\n", .{});
        }
        return self.added;
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

        // Title -> szInfoTitle (proper UTF-8 -> UTF-16; byte-copy garbles non-ASCII).
        // utf8ToUtf16Le does NOT bounds-check its destination, so the source must
        // be truncated to fit first. Each UTF-8 codepoint yields <= as many UTF-16
        // units as bytes, so bounding the source to the dest u16 capacity (minus
        // the null terminator slot) guarantees the conversion stays in bounds.
        const title_cap = self.nid.szInfoTitle.len - 1;
        const tt = title[0..utf8TruncLen(title, title_cap)];
        const tn = std.unicode.utf8ToUtf16Le(self.nid.szInfoTitle[0..title_cap], tt) catch 0;
        self.nid.szInfoTitle[tn] = 0;

        // Message -> szInfo (proper UTF-8 -> UTF-16, same bounding rule).
        const msg_cap = self.nid.szInfo.len - 1;
        const mt = msg_text[0..utf8TruncLen(msg_text, msg_cap)];
        const mn = std.unicode.utf8ToUtf16Le(self.nid.szInfo[0..msg_cap], mt) catch 0;
        self.nid.szInfo[mn] = 0;

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

    // AI-agent indicator state, keyed by tab handle (set via on_agent_status).
    // state: 1=idle (agent present)→●, 2=working/claude, 3=working/braille.
    agent_handles: [32]i64 = [_]i64{0} ** 32,
    agent_states: [32]u8 = [_]u8{0} ** 32,
    agent_count: usize = 0,
    spinner_frame: u32 = 0,
    spinner_timer_active: bool = false,
    // Tab handles that just finished (working 2/3 -> idle 1). Drained on the UI
    // thread for per-tab completion notifications; kept (not dropped) until the
    // tray is ready so a startup-race completion isn't silently lost.
    agent_completed: [32]i64 = [_]i64{0} ** 32,
    // Agent title/summary captured at each completion (parallel to agent_completed).
    agent_completed_titles: [32][128]u8 = undefined,
    agent_completed_title_lens: [32]usize = [_]usize{0} ** 32,
    // true = paused waiting for user input; false = finished (parallel array).
    agent_completed_waiting: [32]bool = [_]bool{false} ** 32,
    agent_completed_count: usize = 0,

    // Cached color-emoji bitmap for the idle indicator (🤖), rasterized via
    // D2D and AlphaBlend'd onto the tab (GDI DrawTextW can't render color
    // emoji). Re-rasterized only on size change; freed in App deinit.
    agent_emoji_hbm: ?c.HBITMAP = null,
    agent_emoji_px: i32 = 0,

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

    /// Upsert/remove (state==0) the AI-agent state for a tab handle.
    pub fn setAgentState(self: *TablineState, handle: i64, state: u8) void {
        var i: usize = 0;
        while (i < self.agent_count) : (i += 1) {
            if (self.agent_handles[i] == handle) {
                if (state == 0) {
                    self.agent_count -= 1;
                    self.agent_handles[i] = self.agent_handles[self.agent_count];
                    self.agent_states[i] = self.agent_states[self.agent_count];
                } else {
                    self.agent_states[i] = state;
                }
                return;
            }
        }
        if (state != 0 and self.agent_count < 32) {
            self.agent_handles[self.agent_count] = handle;
            self.agent_states[self.agent_count] = state;
            self.agent_count += 1;
        }
    }

    pub fn agentState(self: *const TablineState, handle: i64) u8 {
        var i: usize = 0;
        while (i < self.agent_count) : (i += 1) {
            if (self.agent_handles[i] == handle) return self.agent_states[i];
        }
        return 0;
    }

    pub fn anyAgentWorking(self: *const TablineState) bool {
        var i: usize = 0;
        while (i < self.agent_count) : (i += 1) {
            if (self.agent_states[i] == 2 or self.agent_states[i] == 3) return true;
        }
        return false;
    }

    /// Queue a finished/waiting tab handle + its title (de-duplicated, capped).
    pub fn pushCompleted(self: *TablineState, handle: i64, title: []const u8, waiting: bool) void {
        var i: usize = 0;
        while (i < self.agent_completed_count) : (i += 1) {
            if (self.agent_completed[i] == handle) return;
        }
        if (self.agent_completed_count < self.agent_completed.len) {
            const idx = self.agent_completed_count;
            self.agent_completed[idx] = handle;
            // Truncate on a UTF-8 boundary so the stored title never holds a
            // partial codepoint (which would later fail UTF-16 conversion and
            // produce an empty balloon body).
            const n = utf8TruncLen(title, self.agent_completed_titles[idx].len);
            @memcpy(self.agent_completed_titles[idx][0..n], title[0..n]);
            self.agent_completed_title_lens[idx] = n;
            self.agent_completed_waiting[idx] = waiting;
            self.agent_completed_count += 1;
        }
    }

    /// Basename of a tab's name by handle (term://…/bin/zsh -> "zsh"), or "".
    pub fn tabName(self: *const TablineState, handle: i64) []const u8 {
        var i: usize = 0;
        while (i < self.tab_count) : (i += 1) {
            if (self.tabs[i].handle == handle) {
                return baseName(self.tabs[i].name[0..self.tabs[i].name_len]);
            }
        }
        return "";
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


/// GPU-side per-row vertex buffer (D3D11). Owned exclusively by the UI thread.
pub const RowVB = struct {
    vb: ?*c.ID3D11Buffer = null,
    vb_bytes: usize = 0,
    // Slot identity + version for upload detection (replaces uploaded_gen).
    // Upload is needed when uploaded_slot != mapping.slot or uploaded_ver != slot.ver.
    uploaded_slot: u16 = SLOT_NONE,
    uploaded_ver: u64 = 0,
};

pub const RowVBPhysicalBudget = render_pipeline_helpers.RowVBPhysicalBudget;

// =========================================================================
// Slot-based COW types (slot remapping + reference sharing)
// =========================================================================

/// Sentinel value for "no slot assigned".
pub const SLOT_NONE: u16 = std.math.maxInt(u16);

/// Physical row slot. Ref-counted vertex buffer shared across VertexSets.
pub const RowSlot = struct {
    verts: std.ArrayListUnmanaged(Vertex) = .empty,
    ref_count: u16 = 0, // 0=unused, 1=exclusive, 2+=shared
    origin_row: u32 = 0, // Logical row at vertex generation time (viewport Y translation)
    ver: u64 = 0, // Content version (incremented on each write)
};

/// Logical-to-physical row mapping (one per logical row per VertexSet).
pub const RowMapping = struct {
    slot: u16 = SLOT_NONE,
};

/// Number of RowSlot entries per chunk. 256 keeps a typical pool (a few
/// hundred rows) to 1-2 chunk allocations while keeping the fixed directory
/// small (256 * @sizeOf(?*SlotChunk) = 2048 bytes per pool).
const SLOTS_PER_CHUNK: usize = 256;

/// Directory size. SLOTS_PER_CHUNK * MAX_SLOT_CHUNKS == 65536 index values,
/// of which 65535 are usable slots -- SLOT_NONE (maxInt(u16)) is reserved as
/// the sentinel, and acquireSlot's `len >= SLOT_NONE` guard turns index-space
/// exhaustion into a graceful `null` (allocation-failure path callers already
/// handle) instead of a silent sentinel alias at 65535 or an @intCast panic
/// at 65536. (acquireSlot casts the index to u16 today; this fix does not
/// change that range.)
const MAX_SLOT_CHUNKS: usize = 256;

pub const SlotChunk = [SLOTS_PER_CHUNK]RowSlot;

/// Pool of physical row slots shared across all VertexSets in a TBS.
///
/// Pointer-stability rationale: `chunks` is a FIXED-SIZE array field (never
/// reallocated), so reading `chunks[i]` is a single non-moving load — no
/// concurrent writer can ever free or relocate this directory. Each
/// individual chunk is heap-allocated once via `alloc.create` and is never
/// moved or freed until SlotPool.deinit(); therefore a `*RowSlot` obtained
/// from `slotPtr`/`slotPtrConst` remains valid for the pool's entire
/// lifetime, even while other slots are concurrently being acquired on
/// another thread. This is what fixes the UAF: the OLD `ArrayListUnmanaged`
/// design could relocate+free the entire backing buffer on every single
/// `append`; this design never relocates anything after a chunk is created.
pub const SlotPool = struct {
    chunks: [MAX_SLOT_CHUNKS]?*SlotChunk = [_]?*SlotChunk{null} ** MAX_SLOT_CHUNKS,
    len: usize = 0, // number of logically-allocated slots (monotonic)
    free_list: std.ArrayListUnmanaged(u16) = .empty,

    /// Largest row payload observed since `layout_cols` last changed, or 0
    /// before this layout has written a row. `len` is monotonic and `release`
    /// keeps a slot's payload allocation, so without this the pool would stay
    /// pinned at the widest grid ever displayed.
    ///
    /// This is a measurement, not an estimate: a row's vertex count is the sum
    /// of its background runs, its glyph quads and its decoration, so no
    /// per-cell constant bounds it — a cell carrying a two-quad block glyph, an
    /// unmerged background and an underdouble already exceeds the core's own
    /// 12-verts-per-cell capacity estimate. Deriving the retirement threshold
    /// from a constant would retire the backing of any row denser than the
    /// guess on every release, and slot rotation would then reallocate it on
    /// the next write — per-frame heap churn on the render path. Comparing
    /// against what this layout actually produced cannot misjudge a dense row.
    layout_peak_verts: usize = 0,

    /// Width `layout_peak_verts` was observed at. A change discards the peak so
    /// it rebuilds against the new layout; otherwise a shrink would keep
    /// comparing against the widest grid ever displayed and never retire.
    layout_cols: u32 = 0,

    // pub: slotPtr is called cross-file (windows/ui/external_windows.zig,
    // the external-window TBS seed); slotPtrConst is made pub for symmetry.
    pub fn slotPtr(self: *SlotPool, idx: u16) *RowSlot {
        const chunk_idx = idx / SLOTS_PER_CHUNK;
        const offset = idx % SLOTS_PER_CHUNK;
        return &self.chunks[chunk_idx].?[offset];
    }

    pub fn slotPtrConst(self: *const SlotPool, idx: u16) *const RowSlot {
        const chunk_idx = idx / SLOTS_PER_CHUNK;
        const offset = idx % SLOTS_PER_CHUNK;
        return &self.chunks[chunk_idx].?[offset];
    }

    /// Publish the layout a subsequent noteRowVerts applies to. Discards the
    /// observed peak on a width change so retirement is measured against the
    /// new layout rather than the widest one ever displayed.
    pub fn noteLayoutWidth(self: *SlotPool, cols: u32) void {
        if (self.layout_cols == cols) return;
        self.layout_cols = cols;
        self.layout_peak_verts = 0;
    }

    /// Record a row payload this layout produced. Feeds the retirement floor,
    /// so a legitimately dense row raises the bar and keeps its own backing.
    pub fn noteRowVerts(self: *SlotPool, vert_count: usize) void {
        if (vert_count > self.layout_peak_verts) self.layout_peak_verts = vert_count;
    }

    /// Acquire an unused slot. Returns null on OOM or index-space exhaustion.
    pub fn acquireSlot(self: *SlotPool, alloc: std.mem.Allocator) ?u16 {
        if (self.free_list.items.len > 0) {
            return self.free_list.pop();
        }
        if (self.len >= SLOT_NONE) return null; // slot index space exhausted; SLOT_NONE is reserved
        const idx: u16 = @intCast(self.len);
        const chunk_idx: usize = @as(usize, idx) / SLOTS_PER_CHUNK;
        if (self.chunks[chunk_idx] == null) {
            // Every slot in a published chunk can eventually be released at
            // once. Reserve that worst case before publishing the chunk so
            // release() is infallible and never silently loses a slot.
            const chunk_slot_count = @min((chunk_idx + 1) * SLOTS_PER_CHUNK, @as(usize, SLOT_NONE));
            self.free_list.ensureTotalCapacity(alloc, chunk_slot_count) catch return null;
            const new_chunk = alloc.create(SlotChunk) catch return null;
            new_chunk.* = [_]RowSlot{.{}} ** SLOTS_PER_CHUNK;
            self.chunks[chunk_idx] = new_chunk;
        }
        self.len += 1;
        return idx;
    }

    /// Increment ref_count for a slot.
    pub fn retain(self: *SlotPool, idx: u16) void {
        if (idx == SLOT_NONE) return;
        self.slotPtr(idx).ref_count += 1;
    }

    /// Decrement ref_count. If it reaches 0, return slot to free_list.
    pub fn release(self: *SlotPool, alloc: std.mem.Allocator, idx: u16) void {
        if (idx == SLOT_NONE) return;
        const slot = self.slotPtr(idx);
        if (slot.ref_count == 0) return;
        slot.ref_count -= 1;
        if (slot.ref_count == 0) {
            // A slot reaching ref_count 0 is referenced by no VertexSet, so no
            // painter can reach it and its payload is dead — the next acquirer
            // overwrites it. Retire backing this layout has outgrown, mirroring
            // maybeShrinkRowStorage's 2x threshold. Freeing cannot fail, so
            // release stays infallible.
            if (render_pipeline_helpers.shouldRetireSlotBacking(slot.verts.capacity, self.layout_peak_verts)) {
                slot.verts.clearAndFree(alloc);
            }
            self.free_list.appendAssumeCapacity(idx);
        }
    }

    pub fn deinit(self: *SlotPool, alloc: std.mem.Allocator) void {
        for (&self.chunks) |*maybe_chunk| {
            if (maybe_chunk.*) |chunk| {
                for (chunk) |*s| s.verts.deinit(alloc);
                alloc.destroy(chunk);
                maybe_chunk.* = null;
            }
        }
        self.len = 0;
        self.free_list.deinit(alloc);
    }
};

/// Legacy combined struct for backward compatibility during migration.
/// Contains both CPU vertex data and GPU VB resources.
pub const RowVerts = struct {
    verts: std.ArrayListUnmanaged(Vertex) = .empty,

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
    window_wake_cookie: usize,
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
    paint_retry: PaintRetryState = .{},
    paint_retry_deadline_ms: u64 = 0,
    needs_renderer_resize: bool = false, // Deferred renderer resize (to avoid deadlock)
    needs_window_resize: bool = false, // Deferred window resize (to avoid deadlock with WM_SIZE)
    pending_window_w: c_int = 0, // Pending window width for deferred resize
    pending_window_h: c_int = 0, // Pending window height for deferred resize
    atlas_version: u64 = 0, // Last atlas version uploaded to this window's D3D context
    atlas_reset_generation: u64 = 0, // Last atlas_reset_generation this window has fully re-uploaded for
    atlas_upload_cursor: u64 = 0, // Per-window cursor into renderer's pending_uploads queue
    // DPI scale of the monitor this external window is currently on (may
    // differ from app.dpi_scale on a mixed-DPI multi-monitor setup). Used
    // ONLY for this window's own scrollbar hit-test geometry — NOT for font
    // rasterization, which remains driven solely by the shared app.atlas
    // (see ExternalWndProc's WM_DPICHANGED case for why).
    dpi_scale: f32 = 1.0,
    cached_bg_color: ?[3]f32 = null, // Cached background color for cmdline (persists across redraws)
    is_float_external: bool = false, // True if float-origin external (nvim_open_win external=true)
    cursor_blink_state: bool = true, // Cursor blink state (true = visible)
    flat_draw_scratch: std.ArrayListUnmanaged(Vertex) = .empty, // Scratch buffer for flat-mode drawing (cursor filter + scrollbar)

    // Per-window GPU vertex buffers for cursor and scrollbar overlays (row-mode rendering).
    cursor_vb: ?*c.ID3D11Buffer = null,
    cursor_vb_bytes: usize = 0,
    // Per-row GPU vertex buffers (TBS: uploaded from committed set row_verts).
    row_vbs: std.ArrayListUnmanaged(RowVB) = .empty,
    row_vb_retained_bytes: usize = 0,
    // Persistent scratch buffer for shiftRowVBs; sized to abs(vb_shift) before each shift.
    // Owned here (not on stack) so large scrolls never overflow a fixed stack array.
    row_vbs_shift_scratch: std.ArrayListUnmanaged(RowVB) = .empty,
    // Persistent destination for linear dirty-row/range union during scroll.
    scroll_rows_merge_scratch: std.ArrayListUnmanaged(u32) = .empty,
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
    // Pointer is over the decorated surface's copy-content button.
    copy_button_hover: bool = false,
    // Pointer is over a message surface, reported to the core so it holds the
    // view's auto-hide countdown. Tracked here so an ordinary mouse move does
    // not take the core's grid lock on every WM_MOUSEMOVE.
    msg_hover: bool = false,
    // OLE drop target (cmdline surface only). See ui/drop_target.zig; opaque
    // here so app.zig carries none of the COM plumbing.
    drop_target: ?*anyopaque = null,

    // Scratch buffer for vertex copy during paint (avoids per-frame alloc).
    // Per-window to prevent re-entrancy corruption when DXGI Present pumps messages.
    paint_scratch: std.ArrayListUnmanaged(Vertex) = .empty,
    paint_row_ranges: std.ArrayListUnmanaged(PaintRowRange) = .empty,
    paint_dirty_row_keys: std.ArrayListUnmanaged(u32) = .empty,
    paint_rows_to_draw: std.ArrayListUnmanaged(u32) = .empty,
    // Back-texture damage submitted through the renderer's per-swapchain-
    // buffer queue. Persistent so partial external paints allocate only when
    // the grid's high-water row count grows.
    paint_present_rects: std.ArrayListUnmanaged(c.RECT) = .empty,

    pub fn recomputeVertCount(self: *ExternalWindow) void {
        self.vert_count = self.surface.recomputeVertCount();
    }

    pub fn deinit(
        self: *ExternalWindow,
        alloc: std.mem.Allocator,
        row_vb_budget: *RowVBPhysicalBudget,
    ) void {
        // Clear user data first to prevent WndProc from accessing App during destruction
        _ = c.SetWindowLongPtrW(self.hwnd, c.GWLP_USERDATA, 0);

        // Destroy window first (this will process WM_DESTROY etc.)
        _ = c.DestroyWindow(self.hwnd);

        // Now safe to release D3D resources
        self.paint_scratch.deinit(alloc);
        self.paint_row_ranges.deinit(alloc);
        self.paint_dirty_row_keys.deinit(alloc);
        self.paint_rows_to_draw.deinit(alloc);
        self.paint_present_rects.deinit(alloc);
        self.flat_draw_scratch.deinit(alloc);
        // Release GPU VBs from row_verts before deinitCpuState frees the list.
        for (self.surface.row_verts.items) |*rv| {
            if (rv.vb) |vb| _ = vb.lpVtbl.*.Release.?(vb);
        }
        self.surface.deinitCpuState(alloc);
        // Release GPU VBs from TBS row_vbs.
        releaseRowVBs(
            self.row_vbs.items,
            row_vb_budget,
            &self.row_vb_retained_bytes,
        );
        self.row_vbs.deinit(alloc);
        // Scratch holds copies of RowVB entries during a shift; the GPU
        // buffers are owned by row_vbs, never by the scratch, so just free
        // the list backing without touching .vb pointers.
        self.row_vbs_shift_scratch.deinit(alloc);
        self.scroll_rows_merge_scratch.deinit(alloc);
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
) bool {
    out.clearRetainingCapacity();

    // Reserve the complete row range once. This also leaves enough room for
    // scroll-exposed rows appended later in the same paint without hot-path
    // allocation.
    out.ensureTotalCapacity(alloc, @max(total_rows, max_valid_row)) catch return false;

    if (force_full) {
        var r: u32 = 0;
        const n: u32 = @min(total_rows, max_valid_row);
        while (r < n) : (r += 1) {
            out.appendAssumeCapacity(r);
        }
        return true; // Already in order, no duplicates possible.
    }

    // Dirty-row path: filter to valid range, then sort + dedup.
    for (dirty_row_keys) |k| {
        if (k < max_valid_row) {
            out.appendAssumeCapacity(k);
        }
    }

    if (out.items.len <= 1) return true;

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
    return true;
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

fn ensureBudgetedRowVertexBuffer(
    g: *d3d11.Renderer,
    budget: *RowVBPhysicalBudget,
    surface_retained_bytes: *usize,
    vb_ptr: *?*c.ID3D11Buffer,
    vb_bytes_ptr: *usize,
    need_bytes: usize,
) !void {
    if (need_bytes == 0) return;
    if (vb_ptr.* != null and vb_bytes_ptr.* >= need_bytes) return;

    const old_bytes = if (vb_ptr.* != null) vb_bytes_ptr.* else 0;
    const new_bytes = d3d11.Renderer.plannedExternalVertexBufferCapacity(
        old_bytes,
        need_bytes,
    ) orelse return error.VertexBufferTooLarge;
    var reservation = try budget.reserveGrowth(
        surface_retained_bytes.*,
        old_bytes,
        new_bytes,
    );
    errdefer budget.cancel(&reservation);
    try g.replaceExternalVertexBuffer(vb_ptr, vb_bytes_ptr, new_bytes);
    budget.commit(surface_retained_bytes, &reservation);
}

/// Upload slot vertex data to a separate RowVB, comparing slot identity + version.
/// Used by TBS-based paint path where CPU verts and GPU VBs are separate arrays.
pub fn ensureRowVBReadyFromSlot(
    g: *d3d11.Renderer,
    budget: *RowVBPhysicalBudget,
    surface_retained_bytes: *usize,
    vb: *RowVB,
    mapping: RowMapping,
    pool: *const SlotPool,
) !bool {
    if (mapping.slot == SLOT_NONE) return false;
    const slot = pool.slotPtrConst(mapping.slot);
    const src = slot.verts.items;
    if (src.len == 0) return false;

    if (vb.uploaded_slot != mapping.slot or vb.uploaded_ver != slot.ver or vb.vb == null or vb.vb_bytes < src.len * @sizeOf(Vertex)) {
        const need_bytes = src.len * @sizeOf(Vertex);
        try ensureBudgetedRowVertexBuffer(
            g,
            budget,
            surface_retained_bytes,
            &vb.vb,
            &vb.vb_bytes,
            need_bytes,
        );
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
///
/// `saved_scratch` must have capacity >= abs(delta); the caller owns it and
/// typically reuses a persistent per-window buffer so this path stays
/// allocation-free across flushes.
pub fn shiftRowVBs(
    row_vbs: []RowVB,
    delta: i32,
    row_start: u32,
    row_end: u32,
    saved_scratch: []RowVB,
) void {
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

    // The vacated side reuses `abs_delta` RowVBs from the scrolled-off side
    // to keep their GPU buffers (just resets upload state for re-upload).
    // If the caller failed to size `saved_scratch`, fall back to resetting
    // the entire region: this leaks the original GPU buffers for the
    // scrolled-off rows, but never corrupts memory. Callers are expected to
    // size the scratch via `ensureShiftScratch` so this fallback is unreachable.
    if (saved_scratch.len < abs_delta) {
        for (region) |*vb| {
            vb.uploaded_slot = SLOT_NONE;
            vb.uploaded_ver = 0;
        }
        return;
    }

    if (delta > 0) {
        // Scroll up: row_vbs[start] gets row_vbs[start + abs_delta], etc.
        // Save VBs that scroll off (at the top of the region).
        for (0..abs_delta) |s| {
            saved_scratch[s] = region[s];
        }
        var i: usize = 0;
        while (i + abs_delta < region.len) : (i += 1) {
            region[i] = region[i + abs_delta];
        }
        // Vacated tail entries: reuse saved VBs (keep GPU buffer, reset upload state).
        for (0..abs_delta) |s| {
            region[region.len - abs_delta + s] = saved_scratch[s];
            region[region.len - abs_delta + s].uploaded_slot = SLOT_NONE;
            region[region.len - abs_delta + s].uploaded_ver = 0;
        }
    } else {
        // Scroll down: row_vbs[end-1] gets row_vbs[end-1-abs_delta], etc.
        for (0..abs_delta) |s| {
            saved_scratch[s] = region[region.len - 1 - s];
        }
        var i: usize = region.len;
        while (i > abs_delta) {
            i -= 1;
            region[i] = region[i - abs_delta];
        }
        // Vacated head entries: reuse saved VBs.
        // Index is region-local (region = row_vbs[start..end]).
        for (0..abs_delta) |s| {
            region[s] = saved_scratch[s];
            region[s].uploaded_slot = SLOT_NONE;
            region[s].uploaded_ver = 0;
        }
    }
}

/// Ensure `list` has at least `need` capacity+length, growing via `alloc` if
/// needed. Used by scroll paths to size the scratch slice passed to
/// `shiftRowVBs` so the shift itself is allocation-free.
pub fn ensureShiftScratch(
    alloc: std.mem.Allocator,
    list: *std.ArrayListUnmanaged(RowVB),
    need: usize,
) void {
    if (list.items.len >= need) return;
    list.resize(alloc, need) catch {};
}

/// Scroll state consumed by paint. Returned by consumeScrollState / applyScrollShift.
pub const ScrollShiftResult = struct {
    /// The scroll region rect (in back_tex coords). null if no scroll was applied.
    scroll_rect: ?c.RECT = null,
    /// False when dirty-row union scratch could not grow. The caller must not
    /// present this partially shifted back buffer and must schedule a full draw.
    rows_complete: bool = true,
};

/// Apply scroll pixel shift to back_tex, shift row_vbs, and add cursor ghost
/// rows to rows_to_draw.  Shared between main window and external windows.
/// macOS equivalent: encodePendingMainRowScrollCopy + dirty row expansion
/// in MetalTerminalRenderer.draw().
/// When fast path is blocked (no scroll_rect), both platforms skip this
/// entirely and redraw all dirty rows from scratch.
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
    shift_scratch: *std.ArrayListUnmanaged(RowVB),
    rows_to_draw: *std.ArrayListUnmanaged(u32),
    row_merge_scratch: *std.ArrayListUnmanaged(u32),
    scroll_rect: c.RECT,
    scroll_dy_px: i32,
    vb_shift_rows: i32,
    scroll_row_start: u32,
    scroll_row_end: u32,
    last_cursor_row_ptr: *?u32,
    row_h_px: i32,
    effective_rows: u32,
    y_offset: i32,
) ScrollShiftResult {
    if (scroll_dy_px == 0) return .{};

    if (applog.isEnabled()) applog.appLog(
        "[scroll_diag] applyScrollShift dy_px={d} vb_shift={d} row_range=[{d},{d}) row_vbs_len={d} rect=({d},{d},{d},{d}) row_h={d} eff_rows={d}\n",
        .{ scroll_dy_px, vb_shift_rows, scroll_row_start, scroll_row_end, row_vbs.len, scroll_rect.left, scroll_rect.top, scroll_rect.right, scroll_rect.bottom, row_h_px, effective_rows },
    );

    // 1. Shift row_vbs within the scroll region only, matching remapRowSlots'
    //    [row_start, row_end) range.  Shifting the full array corrupts VB
    //    tracking for rows outside the scroll region (e.g. tabline at row 0).
    if (vb_shift_rows != 0 and scroll_row_end > scroll_row_start) {
        const abs_shift: u32 = @intCast(if (vb_shift_rows < 0) -vb_shift_rows else vb_shift_rows);
        ensureShiftScratch(alloc, shift_scratch, abs_shift);
        shiftRowVBs(row_vbs, vb_shift_rows, scroll_row_start, scroll_row_end, shift_scratch.items);
    }

    // 2. Cursor ghost erasure: add previous cursor row (shifted + original) to rows_to_draw.
    if (last_cursor_row_ptr.*) |prev_cr| {
        if (row_h_px > 0) {
            const scroll_rows: i32 = @divTrunc(scroll_dy_px, row_h_px);
            const shifted_row: i32 = @as(i32, @intCast(prev_cr)) + scroll_rows;
            if (shifted_row >= 0 and shifted_row < @as(i32, @intCast(effective_rows))) {
                const sr_u32: u32 = @intCast(shifted_row);
                if (!render_pipeline_helpers.insertSortedRow(alloc, rows_to_draw, sr_u32)) {
                    return .{ .rows_complete = false };
                }
            }
            if (prev_cr < effective_rows) {
                if (!render_pipeline_helpers.insertSortedRow(alloc, rows_to_draw, prev_cr)) {
                    return .{ .rows_complete = false };
                }
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

    const scroll_copy_ok = g.scrollBackTex(filled, scroll_dy_px);

    // 4. When multiple scroll flushes accumulate before a paint, the back buffer
    //    shift leaves gap rows with stale pixels.  The per-flush dirty bitmap
    //    only covers each flush's own vacated rows, but the accumulated shift
    //    exposes abs(vb_shift_rows) rows that scrollBackTex could not fill from
    //    valid source pixels.  Add those gap rows to rows_to_draw so they are
    //    redrawn from the current slot data.
    if (row_h_px > 0) {
        const abs_shift: u32 = @intCast(if (vb_shift_rows < 0) -vb_shift_rows else vb_shift_rows);
        if (abs_shift > 1 or !scroll_copy_ok) {
            const region_top_row: u32 = @intCast(@divTrunc(filled.top - y_offset, row_h_px));
            const region_bot_row: u32 = @intCast(@divTrunc(filled.bottom - y_offset, row_h_px));
            const region_height: u32 = region_bot_row - region_top_row;

            if (!scroll_copy_ok or abs_shift >= region_height) {
                // scrollBackTex reported failure (resource/context missing,
                // staging texture OOM, or the shift covered the whole
                // region and it early-returned without copying anything)
                // — back_tex pixels were never shifted, so every row in the
                // scroll region, not just the accumulated-shift gap, still
                // shows stale pre-scroll content. Redraw the whole region.
                if (!render_pipeline_helpers.mergeSortedRowsWithRange(
                    alloc,
                    rows_to_draw,
                    row_merge_scratch,
                    region_top_row,
                    @min(region_bot_row, effective_rows),
                )) return .{ .scroll_rect = filled, .rows_complete = false };
            } else if (vb_shift_rows > 0) {
                // Scroll up (j-key): gap rows at bottom of scroll region.
                // Gap rows form a contiguous range; merge them into the sorted
                // rows_to_draw list in one pass to avoid repeated O(n) scans in
                // appendRowSorted.
                const gap_start: u32 = region_bot_row - abs_shift;
                const gap_end: u32 = @min(region_bot_row, effective_rows);
                if (!render_pipeline_helpers.mergeSortedRowsWithRange(
                    alloc,
                    rows_to_draw,
                    row_merge_scratch,
                    gap_start,
                    gap_end,
                )) return .{ .scroll_rect = filled, .rows_complete = false };
            } else {
                // Scroll down (k-key): gap rows at top of scroll region.
                const gap_end: u32 = @min(region_top_row + abs_shift, effective_rows);
                if (!render_pipeline_helpers.mergeSortedRowsWithRange(
                    alloc,
                    rows_to_draw,
                    row_merge_scratch,
                    region_top_row,
                    gap_end,
                )) return .{ .scroll_rect = filled, .rows_complete = false };
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

/// Draw rows from slot-based row_map with separate RowVB GPU buffers.
/// This is the TBS-equivalent of drawSurfaceRowsVB.
pub fn drawSurfaceRowsVBFromSlots(
    g: *d3d11.Renderer,
    budget: *RowVBPhysicalBudget,
    surface_retained_bytes: *usize,
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
) !void {
    const row_count: usize = if (rows_to_draw) |rows| rows.len else row_map.len;
    var vp_dirty = false;
    var i: usize = 0;
    while (i < row_count) : (i += 1) {
        const row: u32 = if (rows_to_draw) |rows| rows[i] else @intCast(i);
        if (row >= row_map.len or row >= row_vbs.len) {
            metrics.skipped_empty += 1;
            metrics.failed_rows += 1;
            continue;
        }

        const mapping = row_map[@intCast(row)];
        if (mapping.slot == SLOT_NONE) {
            metrics.skipped_empty += 1;
            metrics.failed_rows += 1;
            if (metrics.first_empty_row == null) {
                metrics.first_empty_row = row;
            }
            continue;
        }

        const slot = pool.slotPtrConst(mapping.slot);
        const src = slot.verts.items;
        if (src.len == 0) {
            // Core sends vert_count==0 as "clear row" (flush.zig:2904).
            // Draw a bg-fill quad to overwrite stale back_tex pixels.
            if (ctx_ptr != null and rs_set_sc_fn != null and row_h_px > 0) {
                const clear_top = y_offset + @as(i32, @intCast(row)) * row_h_px;
                const clear_bot = clear_top + row_h_px;
                var sc: c.D3D11_RECT = .{ .left = x_offset, .top = clear_top, .right = content_right, .bottom = clear_bot };
                rs_set_sc_fn.?(ctx_ptr, 1, &sc);
                if (vp_dirty) {
                    if (rs_set_vp_fn) |vp_fn| {
                        var vp: c.D3D11_VIEWPORT = .{ .TopLeftX = base_vp.x, .TopLeftY = base_vp.y, .Width = base_vp.w, .Height = base_vp.h, .MinDepth = 0, .MaxDepth = 1 };
                        vp_fn(ctx_ptr, 1, &vp);
                        vp_dirty = false;
                    }
                }
                g.drawClearRow() catch {
                    metrics.skipped_empty += 1;
                    metrics.failed_rows += 1;
                    continue;
                };
                metrics.drawn_rows += 1;
            } else {
                metrics.skipped_empty += 1;
                metrics.failed_rows += 1;
                if (metrics.first_empty_row == null) metrics.first_empty_row = row;
            }
            continue;
        }

        const vb = &row_vbs[@intCast(row)];
        if (vb.uploaded_slot != mapping.slot or vb.uploaded_ver != slot.ver or vb.vb == null or vb.vb_bytes < src.len * @sizeOf(Vertex)) {
            const need_bytes = src.len * @sizeOf(Vertex);
            const t_upload_start = if (log_enabled) core.clock.nowNs() else 0;
            _ = ensureRowVBReadyFromSlot(
                g,
                budget,
                surface_retained_bytes,
                vb,
                mapping,
                pool,
            ) catch |err| {
                if (err == error.RowVBPhysicalBudgetExceeded) return err;
                metrics.skipped_empty += 1;
                metrics.failed_rows += 1;
                continue;
            };
            if (log_enabled) {
                metrics.vb_upload_ns += core.clock.nowNs() - t_upload_start;
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

        const row_vb = vb.vb orelse {
            metrics.skipped_empty += 1;
            metrics.failed_rows += 1;
            continue;
        };
        const t_draw_start = if (log_enabled) core.clock.nowNs() else 0;
        g.drawVB(row_vb, src.len) catch {
            metrics.skipped_empty += 1;
            metrics.failed_rows += 1;
            continue;
        };
        if (log_enabled) {
            metrics.draw_vb_ns += core.clock.nowNs() - t_draw_start;
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
    budget: *RowVBPhysicalBudget,
    surface_retained_bytes: *usize,
    row_map: []const RowMapping,
    pool: *const SlotPool,
    row_vbs: []RowVB,
    rows_to_draw: []const u32,
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

    try drawSurfaceRowsVBFromSlots(
        g,
        budget,
        surface_retained_bytes,
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

    return result;
}

/// Flush pending atlas uploads to a D3D renderer.
/// Both main window WM_PAINT and external window paintExternalWindow
/// call this inside their respective gpu.lockContext() scopes.
/// Returns the new upload cursor value.
/// Device-loss recovery: release the GPU vertex buffers referenced by a
/// SurfaceState. CPU vertex data survives; upload bookkeeping resets so the
/// next paint re-creates and re-uploads the buffers on the new device.
pub fn releaseSurfaceGpuVBs(surface: *SurfaceState) void {
    for (surface.row_verts.items) |*rv| {
        if (rv.vb) |vb| _ = vb.lpVtbl.*.Release.?(vb);
        rv.vb = null;
        rv.vb_bytes = 0;
        rv.uploaded_gen = 0;
    }
}

/// Detach one device-bound row buffer without calling COM. The caller may
/// release the returned pointer after dropping app.mu.
pub fn detachOneSurfaceGpuVB(surface: *SurfaceState) ?*c.ID3D11Buffer {
    for (surface.row_verts.items) |*rv| {
        if (rv.vb) |vb| {
            rv.vb = null;
            rv.vb_bytes = 0;
            rv.uploaded_gen = 0;
            return vb;
        }
    }
    return null;
}

/// Device-loss recovery: release row-slot GPU buffers and reset their upload
/// bookkeeping (slot mappings stay valid — they index the CPU-side pool).
pub fn releaseRowVBs(
    row_vbs: []RowVB,
    budget: *RowVBPhysicalBudget,
    surface_retained_bytes: *usize,
) void {
    for (row_vbs) |*rvb| {
        if (rvb.vb) |vb| {
            const bytes = rvb.vb_bytes;
            _ = vb.lpVtbl.*.Release.?(vb);
            budget.release(surface_retained_bytes, bytes);
        }
        rvb.* = .{};
    }
}

/// Match the UI-thread-owned GPU row-buffer list to the committed row count.
/// Shrinking releases the unreachable tail immediately but retains the CPU
/// pointer-array capacity, so a later resize back to the previous high-water
/// mark does not allocate metadata in WM_PAINT. D3D11 defers destruction while
/// an already-submitted command still references a released resource.
pub fn resizeRowVBsForPaint(
    alloc: std.mem.Allocator,
    row_vbs: *std.ArrayListUnmanaged(RowVB),
    budget: *RowVBPhysicalBudget,
    surface_retained_bytes: *usize,
    need_len: usize,
) bool {
    if (row_vbs.items.len > need_len) {
        releaseRowVBs(
            row_vbs.items[need_len..],
            budget,
            surface_retained_bytes,
        );
        row_vbs.items.len = need_len;
        return true;
    }
    if (row_vbs.items.len == need_len) return true;

    const old_len = row_vbs.items.len;
    row_vbs.resize(alloc, need_len) catch return false;
    for (row_vbs.items[old_len..]) |*rvb| rvb.* = .{};
    return true;
}

pub const DetachedRowVB = struct {
    buffer: *c.ID3D11Buffer,
    bytes: usize,
};

pub fn detachOneRowVB(row_vbs: []RowVB) ?DetachedRowVB {
    for (row_vbs) |*rvb| {
        if (rvb.vb) |vb| {
            const bytes = rvb.vb_bytes;
            rvb.* = .{};
            return .{ .buffer = vb, .bytes = bytes };
        }
    }
    return null;
}

pub const AtlasFlushResult = struct {
    cursor: u64,
    success: bool,
};

pub fn flushAtlasUploads(
    atlas: *dwrite_d2d.Renderer,
    gpu: *d3d11.Renderer,
    upload_cursor: u64,
    need_full_upload: bool,
) AtlasFlushResult {
    if (need_full_upload) {
        const full = atlas.uploadFullAtlasToD3D(gpu);
        return .{ .cursor = full.cursor, .success = full.success };
    }
    const pending = atlas.flushPendingAtlasUploadsSinceToD3D(gpu, upload_cursor);
    return .{ .cursor = pending.cursor, .success = pending.success };
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

pub const SurfaceRowDrawMetrics = struct {
    drawn_rows: u32 = 0,
    skipped_empty: u32 = 0,
    // Rows whose clear/upload/draw could not be submitted. Callers must not
    // consume the paint snapshot as a successful partial frame.
    failed_rows: u32 = 0,
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
    /// When true, clear the cursor row to bg and redraw its content before
    /// drawing the cursor. External windows use preserve_back and do not clear
    /// their back_tex per paint, so an in-place cursor shape/position change
    /// would stack the new overlay on top of the stale one (block + bar). The
    /// clear+redraw erases the old overlay even over empty (no-bg-quad) cells.
    erase_cursor_row: bool = false,
    /// The caller already redrew every row, including the cursor row, in this
    /// frame. In that case blink-on only needs the cursor quad and blink-off
    /// needs no work; clearing/redrawing again would double-blend transparent
    /// row content.
    row_already_redrawn: bool = false,
};

pub fn drawCursorOverlay(g: *d3d11.Renderer, p: CursorOverlayParams) !void {
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
    try g.ensureExternalVertexBuffer(p.cursor_vb, p.cursor_vb_bytes, need_bytes);
    const vb = p.cursor_vb.* orelse return error.CursorVertexBufferMissing;
    try g.uploadVertsToVB(vb, p.cursor_verts);

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

    // 4. Erase the previous cursor overlay, then draw the new one.
    // erase_cursor_row (external windows): clear the cursor row to bg and redraw
    // its content first, so a stale overlay left in the preserved back_tex is
    // erased even over empty cells. Without it, an in-place shape change stacks
    // the new overlay on top of the old (block + bar). Then draw the cursor when
    // blink is visible.
    // Default path (main window): blink on draws the cursor; blink off redraws
    // the row content to erase the cursor.
    if (p.row_already_redrawn) {
        if (p.blink_visible) {
            if (log_enabled) applog.appLog("[cursor-overlay] row already redrawn, draw cursor row={d}\n", .{cursor_row});
            try g.drawVB(vb, p.cursor_verts.len);
        } else if (log_enabled) {
            applog.appLog("[cursor-overlay] row already redrawn, blink off row={d}\n", .{cursor_row});
        }
    } else if (p.erase_cursor_row) {
        if (log_enabled) applog.appLog("[cursor-overlay] erase+draw row={d} verts={d} blink={}\n", .{ cursor_row, p.cursor_verts.len, p.blink_visible });
        try g.drawClearRow();
        if (cursor_row < p.row_vbs.len and cursor_row < p.row_map.len) {
            const rvb = &p.row_vbs[cursor_row];
            const mapping = p.row_map[cursor_row];
            const slot_verts_len: usize = if (mapping.slot != SLOT_NONE) p.pool.slotPtrConst(mapping.slot).verts.items.len else 0;
            if (rvb.vb) |row_vb| {
                if (slot_verts_len > 0) {
                    try g.drawVB(row_vb, slot_verts_len);
                }
            } else if (slot_verts_len > 0) {
                return error.CursorRowVertexBufferMissing;
            }
        }
        if (p.blink_visible) {
            try g.drawVB(vb, p.cursor_verts.len);
        }
    } else if (p.blink_visible) {
        if (log_enabled) applog.appLog("[cursor-overlay] draw cursor row={d} verts={d}\n", .{ cursor_row, p.cursor_verts.len });
        try g.drawVB(vb, p.cursor_verts.len);
    } else {
        if (log_enabled) applog.appLog("[cursor-overlay] blink off, redraw row={d}\n", .{cursor_row});
        // The core represents a genuinely empty row with an empty vertex list.
        // Redrawing that list is a no-op, so first overwrite the scissored row
        // with the default background to erase the previously composited cursor.
        try g.drawClearRow();
        if (cursor_row < p.row_vbs.len and cursor_row < p.row_map.len) {
            const rvb = &p.row_vbs[cursor_row];
            const mapping = p.row_map[cursor_row];
            const slot_verts_len: usize = if (mapping.slot != SLOT_NONE) p.pool.slotPtrConst(mapping.slot).verts.items.len else 0;
            if (rvb.vb) |row_vb| {
                if (slot_verts_len > 0) {
                    try g.drawVB(row_vb, slot_verts_len);
                }
            } else if (slot_verts_len > 0) {
                return error.CursorRowVertexBufferMissing;
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
) !void {
    if (scrollbar_verts.len == 0) return;
    g.setFullViewport();
    const need_bytes = scrollbar_verts.len * @sizeOf(Vertex);
    try g.ensureExternalVertexBuffer(vb_ptr, vb_bytes_ptr, need_bytes);
    const vb = vb_ptr.* orelse return error.ScrollbarVertexBufferMissing;
    try g.uploadVertsToVB(vb, scrollbar_verts);
    try g.drawVB(vb, scrollbar_verts.len);
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

const BloomRowsContext = struct {
    row_map: []const RowMapping,
    pool: *const SlotPool,
    row_vbs: []const RowVB,
    row_h_px: i32,
};

fn drawBloomRowBuffers(
    opaque_ctx: ?*const anyopaque,
    g: *d3d11.Renderer,
    d3d_ctx: *c.ID3D11DeviceContext,
    viewport_x: f32,
    viewport_y: f32,
    viewport_w: f32,
    viewport_h: f32,
) void {
    const ctx: *const BloomRowsContext = @ptrCast(@alignCast(opaque_ctx orelse return));
    const set_viewport = d3d_ctx.*.lpVtbl.*.RSSetViewports orelse return;

    for (ctx.row_map, 0..) |mapping, row_index| {
        if (row_index >= ctx.row_vbs.len or mapping.slot == SLOT_NONE) continue;
        const vb = ctx.row_vbs[row_index].vb orelse continue;
        const slot = ctx.pool.slotPtrConst(mapping.slot);
        if (slot.verts.items.len == 0) continue;

        const row_delta = @as(i32, @intCast(row_index)) - @as(i32, @intCast(slot.origin_row));
        var viewport: c.D3D11_VIEWPORT = .{
            .TopLeftX = viewport_x,
            .TopLeftY = viewport_y + @as(f32, @floatFromInt(row_delta * ctx.row_h_px)) / 2.0,
            .Width = viewport_w,
            .Height = viewport_h,
            .MinDepth = 0,
            .MaxDepth = 1,
        };
        set_viewport(d3d_ctx, 1, &viewport);
        g.drawVB(vb, slot.verts.items.len) catch {};
    }

    // drawBloomPasses draws the cursor after this callback using the base
    // extract viewport, so do not leave the final row's scroll offset active.
    var base_viewport: c.D3D11_VIEWPORT = .{
        .TopLeftX = viewport_x,
        .TopLeftY = viewport_y,
        .Width = viewport_w,
        .Height = viewport_h,
        .MinDepth = 0,
        .MaxDepth = 1,
    };
    set_viewport(d3d_ctx, 1, &base_viewport);
}

/// Row-mode bloom path that reuses the already-uploaded row VBs. This keeps
/// glow out of the per-paint heap and avoids copying every grid vertex.
pub fn drawBloomRowsOverlay(
    g: *d3d11.Renderer,
    row_map: []const RowMapping,
    pool: *const SlotPool,
    row_vbs: []const RowVB,
    cursor_verts: []const Vertex,
    glow_intensity: f32,
    draw_params: RowModeDrawParams,
) void {
    var has_rows = false;
    for (row_map, 0..) |mapping, row_index| {
        if (row_index >= row_vbs.len or mapping.slot == SLOT_NONE or row_vbs[row_index].vb == null) continue;
        if (pool.slotPtrConst(mapping.slot).verts.items.len != 0) {
            has_rows = true;
            break;
        }
    }
    if (!has_rows) return;

    const rows_ctx = BloomRowsContext{
        .row_map = row_map,
        .pool = pool,
        .row_vbs = row_vbs,
        .row_h_px = draw_params.row_h_px,
    };
    const bvp = draw_params.bloomViewport(g.width);
    g.drawBloomFromRowBuffers(&rows_ctx, drawBloomRowBuffers, cursor_verts, glow_intensity, bvp.x, bvp.y, bvp.w, bvp.h);
}

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

    mu: std.Io.Mutex = .init,

    hwnd: ?c.HWND = null,
    window_wake_cookie: usize = 0,
    content_hwnd: ?c.HWND = null, // Child window for D3D11 rendering (when ext_tabline enabled)
    corep: ?*zonvie_core = null,

    ui_thread_id: u32 = 0,

    // Atlas builder (DirectWrite + CPU atlas, metrics)
    atlas: ?dwrite_d2d.Renderer = null,

    // Early atlas from doEarlyCoreInit (reused in WM_APP_DEFERRED_INIT for native mode)
    early_atlas: ?dwrite_d2d.Renderer = null,

    early_core_init_done: bool = false,
    nvim_spawned: bool = false,

    // D3D11 device (created early in WM_CREATE for D2D context)
    d3d_device: ?*c.ID3D11Device = null,
    d3d_ctx: ?*c.ID3D11DeviceContext = null,

    // GPU renderer (D3D11)
    renderer: ?d3d11.Renderer = null,

    // External windows (grid_id -> ExternalWindow)
    external_windows: std.AutoHashMapUnmanaged(i64, *ExternalWindow) = .{},

    // UI-thread custom-shader animation snapshot. Capacity tracks the
    // high-water external-window count so the 60 Hz path allocates only when
    // that population grows and never truncates at a fixed grid count.
    shader_anim_external_grids: std.ArrayListUnmanaged(i64) = .empty,
    shader_anim_external_renderers: std.ArrayListUnmanaged(*d3d11.Renderer) = .empty,

    // Pending external window creation requests (for UI thread processing)
    pending_external_windows: std.ArrayListUnmanaged(PendingExternalWindow) = .empty,

    // Monotonically increasing identifier assigned to each
    // PendingExternalWindow at enqueue. Used to bind WM_APP_CREATE_
    // EXTERNAL_WINDOW messages 1:1 to their request: a stale message
    // (e.g., posted by a previous session whose request was removed
    // by onExternalWindowClose) won't dequeue an unrelated new-session
    // request whose seq doesn't match the message's lParam.
    pending_external_seq_counter: u64 = 0,
    external_create_retry_delay_ms: u32 = EXTERNAL_CREATE_RETRY_INTERVAL_MS,
    external_create_retry_generation: u32 = 0,
    external_create_retry_armed: bool = false,
    external_create_retry_needed: bool = false,
    external_create_retry_fallback_wake_issued: bool = false,
    external_create_retry_deadline_ms: u64 = 0,
    external_close_drain_needed: bool = false,
    flush_retry_wake_armed: bool = false,
    flush_retry_fallback_wake_issued: bool = false,
    /// Bumped on every arm. Carried in the WM_APP_FLUSH_RETRY_FALLBACK wParam
    /// so a stale delivery can be rejected: scheduleReliableWindowMessage has
    /// no cancellation path, so a fallback armed for an already-serviced retry
    /// would otherwise consume a newer one early and double-advance the
    /// backoff. Mirrors PaintRetryState's generation token.
    flush_retry_wake_generation: u32 = 0,
    flush_retry_delay_ms: u32 = FLUSH_RETRY_INTERVAL_MS,
    flush_retry_deadline_ms: u64 = 0,
    flush_retry_armed_failure_epoch: u64 = 0,
    flush_retry_consumed_failure_epoch: u64 = 0,
    flush_retry_observed_success_epoch: u64 = 0,
    main_paint_retry_deadline_ms: u64 = 0,
    external_paint_retry_deadline_ms: u64 = 0,
    device_lost_retry_deadline_ms: u64 = 0,

    // Pending position for next external window (set by tab externalization)
    pending_external_window_position: ?struct { x: c_int, y: c_int } = null,
    pending_external_window_position_time: i64 = 0, // Timestamp when position was set (for timeout)

    // Saved positions for external windows (restored on tab switch back)
    saved_external_window_positions: std.AutoHashMapUnmanaged(i64, struct { x: c_int, y: c_int }) = .{},

    // Pending vertices for external windows that haven't been created yet
    pending_external_verts: std.ArrayListUnmanaged(PendingExternalVertices) = .empty,

    // ext_messages window state
    message_window: ?MessageWindow = null,
    pending_messages: std.ArrayListUnmanaged(PendingMessageRequest) = .empty,
    display_messages: std.ArrayListUnmanaged(DisplayMessage) = .empty, // Stack of visible messages

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
    // Same-thread re-entrancy guard for presentShaderAnimationFrame: a
    // nested message pump inside DXGI's Present (triggered by the timer
    // tick below) could otherwise re-enter this same UI-thread handler
    // before the outer call returns. Plain bool (not atomic): both the
    // set and the check always happen on the UI thread.
    in_present_shader_animation_frame: bool = false,
    // D3DCompile/CreateShader can pump messages. Treat the one-time bloom
    // warm-up like paint/recovery so reentrant destruction is deferred.
    glow_prepare_in_progress: bool = false,
    // Set by the tray menu's "Quit" so the next WM_CLOSE runs the real
    // graceful-quit path instead of hiding back to the tray (close_to_tray).
    tray_quit_requested: bool = false,

    // Main surface vertex state (shared structure with external windows).
    // paint_full=false: main window uses explicit dirty tracking; external windows default to true.
    surface: SurfaceState = .{ .paint_full = false },

    // Triple-buffered surface for lock-free vertex handoff (core → UI thread).
    tbs: TripleBufferedSurface = .{},
    // Cross-thread flush bracket state. The core thread publishes it from
    // onFlushBegin and clears it while atomically committing/cancelling in
    // onFlushEnd. Main and external TBS write sets join lazily on mutation;
    // the UI thread uses this flag when publishing a newly-created HWND so its
    // TBS joins the current transaction instead of exposing a partial seed.
    core_flush_active: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    // An atlas reset invalidates every previously committed vertex UV. Unlike
    // additive atlas uploads, it must exclude paints until a flush commits a
    // matching vertex generation. A failed flush intentionally leaves the
    // gate closed so the last frame is frozen rather than redrawn with the
    // new atlas and old UVs.
    atlas_reset_active: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    atlas_paint_active: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    // Set before teardown waits for the core thread. Atlas callbacks use it to
    // reject late non-blocking reset admission while App is still alive.
    shutting_down: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    // on_atlas_create has a void ABI. If paint admission or CPU-atlas recreation
    // fails, retain the requested dimensions and retry from a later
    // on_flush_begin before accepting any atlas uploads for that generation.
    atlas_create_retry_pending: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    atlas_create_retry_w: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    atlas_create_retry_h: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    // Monotonic identity of the current core flush. Pending external CPU
    // captures record this when mutated so onFlushEnd can discard only data
    // produced by a failed transaction while preserving older valid seeds.
    core_flush_generation: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    // GPU row vertex buffers (UI thread owned, corresponds to TBS committed set row_map slots).
    row_vbs: std.ArrayListUnmanaged(RowVB) = .empty,
    row_vb_retained_bytes: usize = 0,
    row_vb_budget: RowVBPhysicalBudget = .{},
    row_vb_budget_failed: bool = false,
    // Persistent scratch for shiftRowVBs; see ExternalWindow.row_vbs_shift_scratch.
    row_vbs_shift_scratch: std.ArrayListUnmanaged(RowVB) = .empty,
    // Persistent destination for linear dirty-row/range union during scroll.
    scroll_rows_merge_scratch: std.ArrayListUnmanaged(u32) = .empty,
    // DXGI scroll state is now bundled in TBS (flush_scroll_* → pending_scroll_* → PaintSnapshot).
    // See TripleBufferedSurface.flush_scroll_rect / pending_scroll_rect / PaintSnapshot.scroll_rect.
    // Last cursor rectangle in client pixels (derived from cursor_verts).
    last_cursor_rect_px: ?c.RECT = null,
    // Row index where cursor was last painted into back_tex.
    // Used by scrollBackTex to erase cursor ghost before shifting.
    last_painted_cursor_row: ?u32 = null,

    // Scratch buffer for WM_PAINT(row): per-row vertex copy.
    // Reused to avoid per-paint alloc/free.
    row_tmp_verts: std.ArrayListUnmanaged(Vertex) = .empty,

    // WM_PAINT(row) persistent buffers (avoid per-frame alloc/free)
    wm_paint_dirty_row_keys: std.ArrayListUnmanaged(u32) = .empty,
    wm_paint_rects_snapshot: std.ArrayListUnmanaged(c.RECT) = .empty,
    wm_paint_rows_to_draw: std.ArrayListUnmanaged(u32) = .empty,
    wm_paint_present_rects: std.ArrayListUnmanaged(c.RECT) = .empty,
    paint_retry: PaintRetryState = .{},

    // Cursor overlay VB for row-mode (avoid extra g.drawEx per paint).
    cursor_vb: ?*c.ID3D11Buffer = null,
    cursor_vb_bytes: usize = 0,

    cursor: ?Cursor = null,

    row_mode_max_row_end: u32 = 0,

    // ---- NEW: self-managed damage queue (avoid OS update region dependency) ----
    paint_rects: std.ArrayListUnmanaged(c.RECT) = .empty,

    // Set by vertex callbacks when dirty state changes during a flush.
    // Checked and cleared by onFlushEnd to decide whether to InvalidateRect.
    // Skips InvalidateRect for flushes with no visual changes (e.g. msg_showcmd-only).
    flush_needs_invalidate: bool = false,

    // Set (under app.mu) by vertex callbacks that hit OOM mid-flush, paired
    // with zonvie_core_abort_flush (which makes the CORE keep its dirty
    // state). onFlushEnd checks this and CANCELS the TBS write-set brackets
    // instead of committing them — the write sets hold partially-updated
    // rows, and committing would publish them as a complete frame.
    flush_failed: bool = false,

    // Frontend row submission aggregate. Updated under app.mu and emitted
    // once from onFlushEnd after releasing the lock.
    log_flush_row_callbacks: u64 = 0,
    log_flush_vertex_count: u64 = 0,

    // Scrollbar update coalescing: set by on_flush_end (core thread), cleared by WM_APP_UPDATE_SCROLLBAR (UI thread).
    scrollbar_update_pending: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    msg_throttle_arm_posted: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    // Claimed by the first glow warm-up request in an enabled period. A flush
    // with glow disabled clears it so later runtime re-enable warms renderers
    // created while glow was off.
    glow_prepare_posted: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

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
    ime_composition_str: std.ArrayListUnmanaged(u16) = .empty, // UTF-16 composition string
    ime_composition_utf8: std.ArrayListUnmanaged(u8) = .empty, // UTF-8 for display
    ime_clause_info: std.ArrayListUnmanaged(u32) = .empty, // clause boundaries
    ime_cursor_pos: u32 = 0, // cursor position in composition
    ime_target_start: u32 = 0, // start of target clause (thick underline)
    ime_target_end: u32 = 0, // end of target clause
    ime_overlay_hwnd: ?c.HWND = null, // Layered window for preedit overlay
    // True while the current composition is shown via the core's inline extmark
    // (ime_preedit_mode = inline). The preedit overlay must stay hidden then, even
    // when a repaint calls updateImePreeditOverlay, to avoid a doubled preedit.
    ime_extmark_active: bool = false,

    // Pending UTF-16 high surrogate from a previous WM_CHAR / WM_IME_CHAR.
    // Windows delivers a non-BMP character (e.g. emoji) as two consecutive
    // messages: high surrogate first, then low surrogate. We buffer the high
    // surrogate here and combine it with the next low surrogate to form one
    // UTF-8 sequence to send to core. Stored separately for WM_CHAR vs.
    // WM_IME_CHAR because they can interleave around composition. 0 = none.
    pending_high_surrogate_char: u16 = 0,
    pending_high_surrogate_ime: u16 = 0,

    // When row-mode starts (or after resize), we must seed the persistent back buffer once.
    // Otherwise the first present may clear to black and only the dirty row gets drawn.
    need_full_seed: std.atomic.Value(bool) = std.atomic.Value(bool).init(true),
    // Set from WM_DPICHANGED (UI thread) when the DPI actually changed;
    // consumed at the start of onFlushBegin (core thread) which is the only
    // thread allowed to call zonvie_core_invalidate_glyph_cache — see MED-1
    // in the fix-plan doc for why the call cannot be made directly from the
    // wndproc.
    pending_core_glyph_invalidate: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    // After atlas reset, external window paints may consume shared pending_uploads.
    // This flag ensures the main window uploads the full atlas to cover any missed regions.
    // Atomic: set from the core/RPC thread (callbacks.zig), consumed via a
    // read-then-clear on the UI thread (window.zig paint path). A plain bool
    // read-then-write is a check-then-act race — a new true set by the RPC
    // thread between the UI thread's read and its write-back-to-false gets
    // silently lost. swap(false, .acq_rel) makes the read+clear atomic.
    atlas_full_upload_needed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    // Device-loss recovery state (WM_APP_DEVICE_LOST_RECOVER). `posted`
    // dedupes the paint-side trigger. Failed attempts drive a bounded
    // exponential backoff; recovery continues until success or HWND teardown.
    device_lost_recover_posted: bool = false,
    // Durable UI-loop wake when both USER timers and the process timer queue
    // are unavailable during device-loss recovery.
    device_lost_retry_needed: bool = false,
    main_size_replay_needed: bool = false,
    external_size_replay_needed: bool = false,
    device_lost_recover_attempts: u32 = 0,
    device_lost_recovery_warning_shown: bool = false,
    device_lost_recovery_cancelled: bool = false,
    // Set for the entire WM_APP_DEVICE_LOST_RECOVER handler (window.zig).
    // Device/D2D/swapchain creation there can pump window messages, which
    // can reenter WM_PAINT/WM_SIZE on this same UI thread — those handlers
    // check this (same idiom as wm_paint_in_progress) and bail instead of
    // blocking on app.mu, which recovery holds across parts of its own
    // handler and would otherwise self-deadlock against.
    device_lost_recovering: bool = false,
    // ResizeBuffers can synchronously pump this thread's message queue. Keep
    // App/renderer alive and defer every nested main resize until the outer
    // swapchain transition has completely unwound.
    main_resize_in_progress: bool = false,
    // WM_DPICHANGED calls SetWindowPos, which synchronously dispatches WM_SIZE.
    // Pin the outer DPI stack until its post-resize layout update returns.
    main_dpi_change_in_progress: bool = false,
    main_dpi_replay_needed: bool = false,
    pending_main_dpi: u32 = 0,
    pending_main_dpi_rect: c.RECT = std.mem.zeroes(c.RECT),
    // serviceDeferredUiRetries issues synchronous WM_SIZE messages. Pin App
    // for the whole service pass so a nested WM_NCDESTROY cannot free the
    // pointer that the remaining retry stages still use.
    deferred_ui_service_in_progress: bool = false,
    // Set by WM_NCDESTROY while any message-pumping operation still uses
    // App/renderer state, including main resize and deferred retry service.
    // Actual destruction is deferred until the last active operation returns.
    pending_destroy_after_active_operation: bool = false,
    // UI-thread guard for fallible external HWND/D3D creation. Those APIs can
    // pump messages just like Present(), so WM_NCDESTROY must defer App
    // destruction until the outer create handler has unwound.
    external_window_create_in_progress: bool = false,
    // Scratch for the external-window recovery snapshot in
    // WM_APP_DEVICE_LOST_RECOVER (window.zig). Unbounded — external_windows
    // has no fixed size limit, so a fixed-size array silently drops windows
    // beyond its capacity. This is a rare recovery path (at most a handful
    // of times per process lifetime), not a per-frame hot path, so reusing
    // one persistent buffer (cleared and re-filled each call) is fine.
    device_lost_recover_grids: std.ArrayListUnmanaged(i64) = .empty,

    // Last-uploaded tabline content signature (renderTablineToD3D change
    // gate). 0 forces a re-render — reset when the renderer/texture is
    // recreated (device-loss recovery).
    tabline_render_sig: u64 = 0,
    // Main window cursor into renderer's pending_uploads queue (since-based upload).
    atlas_upload_cursor: u64 = 0,
    // Row-mode seed tracking: require a full set of rows before presenting.
    seed_pending: bool = true,
    seed_clear_pending: bool = true,
    row_valid: std.DynamicBitSetUnmanaged = .{},
    row_valid_count: u32 = 0,
    row_layout_gen: u64 = 0,
    // Incremented only when shared font/cell/linespace metrics change.
    // External row vertices do not depend on main drawable rows/cols.
    shared_metrics_gen: u64 = 0,

    // True when back_tex holds a fully-painted frame at the current dimensions
    // and metrics, so subsequent paints may preserve it (preserve_back=true) and
    // overwrite only dirty rows. Decoupled from seed_pending so that a partial
    // seed (e.g. WM_SIZE on minimize/restore where row data is still current,
    // followed by a scroll that propagates zero validity bits via
    // swapAndShiftRows) does not force a back_tex clear on every frame.
    // Reset by paths that invalidate back_tex content: swapchain resize (real
    // dimension change), font/linespace/DPI changes that shift cell metrics
    // without necessarily resizing the swapchain. macOS analogue:
    // hasPresentedOnce on MetalTerminalRenderer.
    back_tex_valid: bool = false,

    linespace_px: i32 = 0,

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
    // Non-blocking viewport query cache (scrollbar paint/flush/drag paths),
    // keyed by grid_id (-1 for the main/cursor grid). Updated on tryLock
    // success, served stale (at most one flush old) when the core's grid
    // lock is busy -- mirrors macOS's cachedViewports.
    viewport_cache: std.AutoHashMapUnmanaged(i64, ViewportInfo) = .empty,
    // Non-blocking cursor position cache (IME candidate-window positioning).
    // Single slot: IME only ever needs "the current cursor position".
    cursor_pos_cache: struct { grid_id: i64 = -1, row: i32 = -1, col: i32 = -1 } = .{},
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

    // Cached highlight group bg colors for external window clear color.
    // Updated in updateExternalWindowColors (UI thread) to avoid grid_mu during WM_PAINT.
    // 0xFFFFFFFF = not set (fall back to colorscheme_bg).
    cached_normal_float_bg: u32 = 0xFFFFFFFF,
    cached_msg_area_bg: u32 = 0xFFFFFFFF,
    cached_pmenu_bg: u32 = 0xFFFFFFFF,

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

    // ext_popupmenu: Pmenu bg color (0x00RRGGBB) from on_popupmenu_show callback
    popupmenu_bg_rgb: u32 = 0xFFFFFFFF,

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

    // Connect mode (--connect-nvim=<addr> or --remote-ui=<addr>): attach to a
    // running Neovim server instead of spawning. When set, doEarlyCoreInit
    // calls zonvie_core_start_connect with this address. Mutually exclusive
    // with wsl/ssh/devcontainer modes (CLI parsing rejects mixed use).
    connect_addr: ?[]const u8 = null,

    // `--dialog`: show the interactive connection dialog (Local / SSH /
    // Devcontainer) at startup instead of spawning immediately. When set,
    // WM_CREATE skips the normal start path and defers WM_APP_DEFERRED_INIT
    // until the dialog resolves; the dialog's Connect populates the ssh_*/
    // devcontainer_*/ext_* fields below, which the deferred-init full path then
    // consumes exactly as if they had come from CLI flags. Distinct from
    // --connect-nvim (attach to a running server).
    connect_dialog: bool = false,

    // Extra arguments to pass to nvim (not recognized as zonvie arguments)
    nvim_extra_args: std.ArrayListUnmanaged([]const u8) = .empty,

    // CLI --nvim override (points into args allocation, no ownership)
    cli_nvim_path: ?[]const u8 = null,

    // Startup timing: first WM_PAINT with nvim content
    first_paint_logged: bool = false,

    // Paint reentrancy guard (UI-thread-only, no lock needed): DXGI
    // Present() can internally pump Win32 messages, which may deliver a
    // reentrant WM_PAINT (main or external window; they share this one
    // App/Renderer) on the same thread while the outer call still holds
    // Renderer.ctx_mu (non-recursive std.Io.Mutex). The reentrant call must
    // skip rendering and instead request follow-up paints once the outer call
    // finishes. A bool intentionally invalidates every surface: multiple
    // distinct HWNDs can reenter one Present, so a single HWND slot loses all
    // but the last request.
    wm_paint_in_progress: bool = false,
    wm_paint_reinvalidate_all: bool = false,

    // Atomic: written by RPC thread (onFlushEnd), read by UI thread
    // (WM_SIZE handler) to gate updateLayoutToCore vs notify_layout_ready.
    window_shown: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    // Atomic: set by the UI thread when the user picks a font in ChooseFontW,
    // read+cleared by the RPC thread in onGuiFont so that explicit pick wins
    // over config.toml [font] precedence (which otherwise ignores the payload).
    font_picker_selection_pending: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    // Base weight/slant of the picked font (valid while the pending flag above
    // is set). Written by the UI thread from the ChooseFontW LOGFONT, applied by
    // onGuiFont so the picked Bold/Italic face becomes the base font.
    picked_font_bold: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    picked_font_italic: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    pending_show_window: bool = false,

    // Clipboard request state (for cross-thread clipboard operations)
    clipboard_event: c.HANDLE = null, // Manual-reset event for sync
    // Grown to fit whatever the system clipboard holds. A fixed buffer here
    // truncated large pastes silently, and the core cannot recover what the
    // UI thread never fetched.
    clipboard_buf: []u8 = &.{},
    clipboard_len: usize = 0,
    clipboard_result: c_int = 0,
    clipboard_set_data: ?[*]const u8 = null,
    clipboard_set_len: usize = 0,

    // OLE drop target for the main window (ui/drop_target.zig). Null when
    // RegisterDragDrop failed, in which case WM_DROPFILES still delivers drops
    // without the drag-cursor badge. Typed opaque to keep app.zig free of the
    // COM plumbing.
    main_drop_target: ?*anyopaque = null,

    // SSH auth prompt state (owned copy - core frees original after callback)
    ssh_prompt_owned: ?[]u8 = null,

    // Persistent query/cache storage for non-blocking visible-grid queries
    // (UI thread only). Capacity grows only when the core reports that the
    // current query buffer cannot hold a complete snapshot; steady-state
    // hit-testing performs no heap work. The published cache is separate so
    // an incomplete query can never replace the last complete snapshot.
    visible_grids_query: std.ArrayListUnmanaged(GridInfo) = .empty,
    cached_visible_grids: std.ArrayListUnmanaged(GridInfo) = .empty,

    // Tray icon for OS notification (balloon notification)
    tray_icon: ?TrayIcon = null,

    d3d_init_thread: ?std.Thread = null,
    // Set before teardown joins d3d_init_thread. The worker owns any device it
    // creates until it observes this flag and publishes into App.
    d3d_init_cancelled: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    /// Match the core's accepted grid-row limit. The per-surface SlotPool can
    /// hold three 20,000-row sets (60,000 slots) below its u16 sentinel limit;
    /// the core's aggregate cell cap remains the primary memory bound.
    pub const max_row_buffers: u32 = 20_000;

    pub const AtlasResetAdmission = render_pipeline_helpers.AtlasResetAdmission;

    /// Height of one grid row: the cell plus 'linespace'. Neovim allows
    /// 'linespace' to be negative to tighten rows under a font that reserves
    /// too much room between lines, so the sum is taken signed and floored —
    /// the layout divides the client area by this to get its row count.
    pub fn rowHeightPx(self: *const App) u32 {
        const total: i32 = @as(i32, @intCast(self.cell_h_px)) + self.linespace_px;
        return if (total < 1) 1 else @intCast(total);
    }

    /// Close paint admission before onAtlasCreate invalidates the atlas.
    /// This is non-blocking because the core callback can hold grid_mu while a
    /// paint is stalled in Present. A busy reader aborts the current flush and
    /// the existing timer retries after the UI reader is no longer active.
    pub fn beginAtlasResetTransaction(self: *App) AtlasResetAdmission {
        return render_pipeline_helpers.tryBeginAtlasReset(
            &self.atlas_reset_active,
            &self.atlas_paint_active,
            &self.shutting_down,
        );
    }

    /// Open paint admission after a successful matching TBS commit. Returns
    /// true when an atlas transaction was active, so onFlushEnd can repaint
    /// every surface whose WM_PAINT was consumed while the gate was closed.
    pub fn endAtlasResetTransaction(self: *App) bool {
        return self.atlas_reset_active.swap(false, .seq_cst);
    }

    /// Acquire the single UI-thread atlas reader. The second active check
    /// closes the race where onAtlasCreate starts between admission checks.
    pub fn beginAtlasPaint(self: *App) bool {
        return render_pipeline_helpers.tryBeginAtlasPaint(
            &self.atlas_reset_active,
            &self.atlas_paint_active,
        );
    }

    pub fn endAtlasPaint(self: *App) void {
        render_pipeline_helpers.endAtlasPaint(&self.atlas_paint_active);
    }

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

    /// Non-blocking visible grids query with complete-snapshot cache fallback
    /// (UI thread only). Busy, allocation failure, and truncated queries keep
    /// the last complete cache. Buffers grow only when the visible-grid count
    /// exceeds their current size, so steady-state input paths do no heap work.
    pub fn getVisibleGridsCached(self: *App, corep: *zonvie_core) []const GridInfo {
        const initial_capacity = 16;

        if (self.visible_grids_query.items.len == 0) {
            self.visible_grids_query.resize(self.alloc, initial_capacity) catch
                return self.cached_visible_grids.items;
        }
        if (self.cached_visible_grids.capacity < self.visible_grids_query.items.len) {
            self.cached_visible_grids.ensureTotalCapacity(self.alloc, self.visible_grids_query.items.len) catch
                return self.cached_visible_grids.items;
        }

        // One bounded retry publishes a newly grown snapshot without allowing
        // a core whose grid count is changing continuously to stall the UI.
        var attempt: u8 = 0;
        while (attempt < 2) : (attempt += 1) {
            var total_count: usize = 0;
            const result = zonvie_core_try_get_visible_grids_complete(
                corep,
                self.visible_grids_query.items.ptr,
                self.visible_grids_query.items.len,
                &total_count,
            );
            if (result < 0) return self.cached_visible_grids.items;

            const written: usize = @intCast(result);
            if (written > self.visible_grids_query.items.len or written > total_count) {
                return self.cached_visible_grids.items;
            }

            if (written == total_count) {
                self.cached_visible_grids.items.len = written;
                @memcpy(
                    self.cached_visible_grids.items,
                    self.visible_grids_query.items[0..written],
                );
                return self.cached_visible_grids.items;
            }

            // The core returned a valid but truncated snapshot. Grow both
            // persistent buffers, but never expose its partial contents.
            if (total_count <= self.visible_grids_query.items.len or
                total_count > std.math.maxInt(i32))
            {
                return self.cached_visible_grids.items;
            }
            self.visible_grids_query.resize(self.alloc, total_count) catch
                return self.cached_visible_grids.items;
            self.cached_visible_grids.ensureTotalCapacity(self.alloc, total_count) catch
                return self.cached_visible_grids.items;
        }

        return self.cached_visible_grids.items;
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

    pub fn hasActiveOperation(self: *const App) bool {
        return (render_pipeline_helpers.ActiveOperationFlags{
            .paint = self.wm_paint_in_progress,
            .shader_present = self.in_present_shader_animation_frame,
            .glow_prepare = self.glow_prepare_in_progress,
            .device_recovery = self.device_lost_recovering,
            .external_create = self.external_window_create_in_progress,
            .main_resize = self.main_resize_in_progress,
            .main_dpi_change = self.main_dpi_change_in_progress,
            .deferred_service = self.deferred_ui_service_in_progress,
        }).any();
    }

    /// Finish a message-pumping operation. Returns
    /// true when this call destroyed `self`; callers must not dereference App again.
    pub fn finishActiveOperation(self: *App) bool {
        if (self.hasActiveOperation()) return false;

        if (self.pending_destroy_after_active_operation) {
            self.pending_destroy_after_active_operation = false;
            self.owned_by_hwnd = false;
            const alloc = self.alloc;
            self.deinit();
            alloc.destroy(self);
            return true;
        }

        if (self.wm_paint_reinvalidate_all) {
            self.wm_paint_reinvalidate_all = false;
            if (self.hwnd) |main_hwnd| {
                _ = c.InvalidateRect(main_hwnd, null, c.FALSE);
            }
            self.mu.lockUncancelable(core.clock.io());
            var it = self.external_windows.valueIterator();
            while (it.next()) |ext_win_ptr| {
                _ = c.InvalidateRect(ext_win_ptr.*.hwnd, null, c.FALSE);
            }
            self.mu.unlock(core.clock.io());
        }
        return false;
    }

    pub fn deinit(self: *App) void {
        // Publish shutdown before waiting for the core thread. A core callback
        // may currently be attempting non-blocking atlas reset admission; it
        // must observe this while App and callback-visible fields are alive.
        self.shutting_down.store(true, .release);
        // The startup worker writes d3d_device/d3d_ctx through App. Stop that
        // publication and join it while App is still alive, including shutdown
        // before WM_APP_DEFERRED_INIT had a chance to perform its normal join.
        self.d3d_init_cancelled.store(true, .release);
        if (self.d3d_init_thread) |thr| {
            thr.join();
            self.d3d_init_thread = null;
        }

        // Join the core thread FIRST. zonvie_core_destroy() -> Core.stop() blocks
        // until both the writer thread and the core/RPC thread have fully exited
        // (src/core/nvim_core.zig Core.stop(), joins the writer thread and then
        // the core/RPC thread). This MUST happen before any renderer/TBS/atlas/
        // external-window state is freed below: the core thread's callbacks
        // (on_vertices_row, on_atlas_*, etc.) read and write that state, and can
        // still be executing at the moment deinit() is called (e.g. the
        // force-quit path in windows/window.zig WM_APP_QUIT_TIMEOUT is
        // specifically for a Neovim process that is NOT responding, i.e. very
        // plausibly mid-callback).
        if (self.corep) |p| zonvie_core_destroy(p);
        self.corep = null;
        // No core callbacks or UI paints can remain after the core join and
        // active-operation teardown. Do not carry a failed-flush freeze into
        // destruction diagnostics or any late idempotent cleanup path.
        self.atlas_reset_active.store(false, .seq_cst);
        self.atlas_paint_active.store(false, .seq_cst);

        // Cached AI-agent color-emoji bitmap (tabline idle indicator).
        if (self.tabline_state.agent_emoji_hbm) |hbm| {
            _ = c.DeleteObject(hbm);
            self.tabline_state.agent_emoji_hbm = null;
        }

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
        releaseRowVBs(
            self.row_vbs.items,
            &self.row_vb_budget,
            &self.row_vb_retained_bytes,
        );
        self.row_vbs.deinit(self.alloc);
        // Scratch holds shallow copies during a shift; GPU buffers belong to
        // row_vbs, so only free the list storage.
        self.row_vbs_shift_scratch.deinit(self.alloc);
        self.scroll_rows_merge_scratch.deinit(self.alloc);

        // WM_PAINT(row) scratch
        self.row_tmp_verts.deinit(self.alloc);
        self.wm_paint_dirty_row_keys.deinit(self.alloc);
        self.wm_paint_rects_snapshot.deinit(self.alloc);
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
        self.viewport_cache.deinit(self.alloc);
        self.visible_grids_query.deinit(self.alloc);
        self.cached_visible_grids.deinit(self.alloc);

        // IME state cleanup
        self.ime_composition_str.deinit(self.alloc);
        self.ime_composition_utf8.deinit(self.alloc);
        self.ime_clause_info.deinit(self.alloc);

        // External windows cleanup
        var ext_it = self.external_windows.iterator();
        while (ext_it.next()) |entry| {
            entry.value_ptr.*.deinit(self.alloc, &self.row_vb_budget);
            self.alloc.destroy(entry.value_ptr.*);
        }
        self.external_windows.deinit(self.alloc);
        self.shader_anim_external_grids.deinit(self.alloc);
        self.shader_anim_external_renderers.deinit(self.alloc);
        self.pending_external_windows.deinit(self.alloc);
        for (self.pending_external_verts.items) |*pv| {
            pv.deinit(self.alloc);
        }
        self.pending_external_verts.deinit(self.alloc);
        self.saved_external_window_positions.deinit(self.alloc);
        self.pending_messages.deinit(self.alloc);
        self.display_messages.deinit(self.alloc);
        self.device_lost_recover_grids.deinit(self.alloc);

        if (self.renderer) |*r| r.deinit();
        self.renderer = null;

        // Release App's own reference on the shared D3D11 device/context (the
        // renderer, as of this fix, takes and releases its OWN reference via
        // AddRef/Release in initWithDevice/deinit -- see
        // windows/renderer/d3d11_renderer.zig). Without this, the device
        // would leak by one reference at process exit.
        if (self.d3d_ctx) |p| {
            const rel = p.*.lpVtbl.*.Release orelse null;
            if (rel) |f| _ = f(p);
            self.d3d_ctx = null;
        }
        if (self.d3d_device) |p| {
            const rel = p.*.lpVtbl.*.Release orelse null;
            if (rel) |f| _ = f(p);
            self.d3d_device = null;
        }

        if (self.atlas) |*a| a.deinit();
        self.atlas = null;
        // doEarlyCoreInit stores the metrics renderer here until deferred
        // renderer initialization takes ownership. Startup may fail before
        // that transfer, so App remains the owner of this optional value.
        if (self.early_atlas) |*a| a.deinit();
        self.early_atlas = null;

        // Clipboard event cleanup
        if (self.clipboard_event != null) {
            _ = c.CloseHandle(self.clipboard_event);
            self.clipboard_event = null;
        }
        if (self.clipboard_buf.len != 0) {
            self.alloc.free(self.clipboard_buf);
            self.clipboard_buf = &.{};
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

/// Add a filled rounded rect spanning the given area, using SDF.
/// Area: top-left (x, y), bottom-right (x + w, y - h).
/// Returns 6 vertices (1 quad, rendered via shader SDF).
pub fn addRoundFillVerts(
    verts: []core.Vertex,
    start_idx: usize,
    x: f32,
    y: f32,
    w: f32,
    h: f32,
    color: [4]f32,
    grid_id: i64,
) usize {
    var idx = start_idx;

    // uv.x = -7.0 (ICON_ROUND_FILL), uv.y = local_x, deco_phase = local_y
    const fill_tex_x: f32 = -7.0;
    const positions = [_][2]f32{
        .{ x, y }, // top-left
        .{ x + w, y }, // top-right
        .{ x, y - h }, // bottom-left
        .{ x + w, y }, // top-right
        .{ x + w, y - h }, // bottom-right
        .{ x, y - h }, // bottom-left
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
            .texCoord = .{ fill_tex_x, luv[0] },
            .color = color,
            .grid_id = grid_id,
            .deco_flags = 0,
            .deco_phase = luv[1],
        };
        idx += 1;
    }

    return idx;
}

/// Add a "copy" icon (two overlapping rounded squares) using SDF.
/// Icon area: top-left (x, y), bottom-right (x + w, y - h). The icon is inset
/// so the hover wash drawn across the same area has a margin around it.
/// Returns 6 vertices (1 quad, rendered via shader SDF).
pub fn addCopyIconVerts(
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
    const margin = 0.16;
    const safe_x = x + w * margin;
    const safe_y = y - h * margin;
    const safe_w = w * (1.0 - 2.0 * margin);
    const safe_h = h * (1.0 - 2.0 * margin);

    var idx = start_idx;

    // uv.x = -6.0 (ICON_COPY), uv.y = local_x, deco_phase = local_y
    const copy_tex_x: f32 = -6.0;
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
            .texCoord = .{ copy_tex_x, luv[0] }, // uv.y = local_x
            .color = color,
            .grid_id = grid_id,
            .deco_flags = 0,
            .deco_phase = luv[1], // local_y
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

/// Terminal content area in pixels (client rect minus sidebar/scrollbar/tabbar chrome).
pub fn contentSizePx(hwnd: c.HWND, app: *App) struct { w: u32, h: u32 } {
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

    return .{ .w = w, .h = h };
}

pub fn updateLayoutToCore(hwnd: c.HWND, app: *App) void {
    if (app.corep == null) return;

    const content = contentSizePx(hwnd, app);
    const w = content.w;
    const h = content.h;

    const cw: u32 = @max(1, app.cell_w_px);
    const ch: u32 = app.rowHeightPx();

    if (applog.isEnabled()) applog.appLog(
        "[win] updateLayoutToCore px=({d},{d}) cell=({d},{d})\n",
        .{ w, h, cw, ch },
    );
    core.zonvie_core_update_layout_px(app.corep, w, h, cw, ch);

    // Override screen_cols with monitor work area minus margin (matching macOS).
    // updateLayoutPxLocked sets screen_cols = drawable_cols, but for cmdline
    // max width we want the screen-based value with margin subtracted.
    if (app.hwnd) |main_hwnd| {
        const copy_button_w: u32 = if (app.config.cmdline.copy_button)
            @intCast(@max(0, app.scalePx(@as(c_int, COPY_BUTTON_MARGIN_LEFT + COPY_BUTTON_SIZE + COPY_BUTTON_MARGIN_RIGHT))))
        else
            0;
        // Chrome that sits beside the cmdline grid inside its own window.
        const cmdline_chrome_w: u32 = CMDLINE_PADDING * 2 + CMDLINE_ICON_MARGIN_LEFT +
            CMDLINE_ICON_SIZE + CMDLINE_ICON_MARGIN_RIGHT + copy_button_w;

        const monitor = c.MonitorFromWindow(main_hwnd, c.MONITOR_DEFAULTTONEAREST);
        if (monitor) |mon| {
            var mi: c.MONITORINFO = std.mem.zeroes(c.MONITORINFO);
            mi.cbSize = @sizeOf(c.MONITORINFO);
            if (c.GetMonitorInfoW(mon, &mi) != 0) {
                const work_w: u32 = @intCast(@max(1, mi.rcWork.right - mi.rcWork.left));
                const overhead: u32 = cmdline_chrome_w + CMDLINE_SCREEN_MARGIN;
                const available_w: u32 = if (work_w > overhead) work_w - overhead else 1;
                const screen_cols: u32 = @max(40, available_w / cw);
                core.zonvie_core_set_screen_cols(app.corep, screen_cols);
            }
        }

        // Default cmdline width: the cmdline WINDOW spans
        // CMDLINE_DEFAULT_WINDOW_PERCENT of the main window, so the chrome
        // comes off before converting to cells. Without this the core falls
        // back to the main grid's cols, which makes the cmdline window wider
        // than the main window by exactly the chrome.
        var wr: c.RECT = undefined;
        if (c.GetWindowRect(main_hwnd, &wr) != 0) {
            const main_w: u32 = @intCast(@max(1, wr.right - wr.left));
            const target_w: u32 = main_w * CMDLINE_DEFAULT_WINDOW_PERCENT / 100;
            const content_w: u32 = if (target_w > cmdline_chrome_w) target_w - cmdline_chrome_w else 1;
            core.zonvie_core_set_cmdline_default_cols(app.corep, @max(20, content_w / cw));
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
    const ch: u32 = app.rowHeightPx();

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
