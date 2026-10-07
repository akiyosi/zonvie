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
const external_windows = @import("ui/external_windows.zig");
pub const PaintRetryState = render_pipeline_helpers.PaintRetryState;

// Re-export core types used across modules
pub const Vertex = core.Vertex;
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
pub const zonvie_core_try_get_visible_grids_complete = core.zonvie_core_try_get_visible_grids_complete;
pub const zonvie_core_get_cursor_position = core.zonvie_core_get_cursor_position;
pub const zonvie_core_msg_anchor = core.zonvie_core_msg_anchor;
pub const zonvie_core_try_get_cursor_position = core.zonvie_core_try_get_cursor_position;
pub const zonvie_core_get_win_id = core.zonvie_core_get_win_id;
pub const zonvie_core_get_current_mode = core.zonvie_core_get_current_mode;
pub const zonvie_core_is_cursor_visible = core.zonvie_core_is_cursor_visible;
pub const zonvie_core_try_get_cursor_blink = core.zonvie_core_try_get_cursor_blink;
pub const zonvie_core_send_mouse_scroll = core.zonvie_core_send_mouse_scroll;
pub const zonvie_core_resolve_pointer_grid = core.zonvie_core_resolve_pointer_grid;
pub const zonvie_pointer_hit = core.zonvie_pointer_hit;
pub const zonvie_core_try_scrollbar_grid = core.zonvie_core_try_scrollbar_grid;
pub const zonvie_core_scrollbar_metrics = core.zonvie_core_scrollbar_metrics;
pub const zonvie_scrollbar_metrics = core.zonvie_scrollbar_metrics;
pub const zonvie_core_scrollbar_drag_target = core.zonvie_core_scrollbar_drag_target;
pub const zonvie_scrollbar_drag_target = core.zonvie_scrollbar_drag_target;
pub const zonvie_core_popupmenu_top = core.zonvie_core_popupmenu_top;
pub const zonvie_core_cmdline_popupmenu_top = core.zonvie_core_cmdline_popupmenu_top;
pub const zonvie_core_scroll_to_line = core.zonvie_core_scroll_to_line;
pub const zonvie_core_page_scroll = core.zonvie_core_page_scroll;
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
pub const zonvie_core_drop_paths = core.zonvie_core_drop_paths;
pub const zonvie_core_msg_stack_plan = core.zonvie_core_msg_stack_plan;
pub const zonvie_core_popupmenu_left = core.zonvie_core_popupmenu_left;
pub const zonvie_core_clamp_window_origin = core.zonvie_core_clamp_window_origin;
// The values zonvie_core_msg_stack_plan returns (ZONVIE_MSG_STACK_* in the header).
pub const ZONVIE_MSG_STACK_REPLACE_LAST: c_int = 1;
pub const ZONVIE_MSG_STACK_APPEND_TO_LAST: c_int = 2;
pub const zonvie_core_request_win_close = core.zonvie_core_request_win_close;
pub const zonvie_core_set_preedit = core.zonvie_core_set_preedit;
pub const zonvie_core_clear_preedit = core.zonvie_core_clear_preedit;
pub const zonvie_core_set_option_value = core.zonvie_core_set_option_value;
pub const zonvie_core_set_background_opacity = core.zonvie_core_set_background_opacity;
pub const zonvie_core_perf_now_ns = core.zonvie_core_perf_now_ns;
pub const zonvie_version = core.zonvie_version;
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
pub const MsgAnchor = core.MsgAnchor;
pub const MsgHistoryEntry = core.MsgHistoryEntry;
pub const zonvie_msg_event = core.zonvie_msg_event;

// =========================================================================
// Small shared text helpers
// =========================================================================

pub const utf8TruncLen = render_pipeline_helpers.utf8TruncLen;
pub const utf8ValidPrefix = render_pipeline_helpers.utf8ValidPrefix;

/// Basename of a path-like name: the part after the last '/' or '\\',
/// ignoring trailing separators as macOS's lastPathComponent does, so
/// `oil:///home/u/proj/` names `proj` rather than nothing. Returns the whole
/// string when there is no separator.
pub fn baseName(name: []const u8) []const u8 {
    var end = name.len;
    while (end > 1 and (name[end - 1] == '/' or name[end - 1] == '\\')) end -= 1;
    const trimmed = name[0..end];
    var last: usize = 0;
    for (trimmed, 0..) |ch, j| {
        if (ch == '/' or ch == '\\') last = j + 1;
    }
    return trimmed[last..];
}

/// What a tab entry keeps of the core's full name within `cap` bytes: the
/// basename, which is all any consumer shows, cut on a UTF-8 boundary. Cutting
/// the full path first lost the file name, or left a split character that
/// drew no label at all.
pub fn tabNameForStorage(name: []const u8, cap: usize) []const u8 {
    const base = baseName(name);
    return base[0..utf8TruncLen(base, cap)];
}

test "tabNameForStorage keeps the basename of a name longer than the cap" {
    try std.testing.expectEqualStrings("file.zig", tabNameForStorage("/very/deep/path/file.zig", 12));
    // "あいう" is 9 bytes; a cap of 7 must not split the third character.
    try std.testing.expectEqualStrings("あい", tabNameForStorage("/d/あいう", 7));
}

test "baseName ignores trailing separators" {
    try std.testing.expectEqualStrings("proj", baseName("oil:///home/u/proj/"));
    try std.testing.expectEqualStrings("a.zig", baseName("src\\a.zig"));
    try std.testing.expectEqualStrings("name", baseName("name"));
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
pub const WM_APP_MINI_UPDATE: c.UINT = c.WM_APP + 9;
pub const WM_APP_CLIPBOARD_GET: c.UINT = c.WM_APP + 10;
pub const WM_APP_CLIPBOARD_SET: c.UINT = c.WM_APP + 11;
pub const WM_APP_SSH_AUTH_PROMPT: c.UINT = c.WM_APP + 12;
pub const WM_APP_UPDATE_SCROLLBAR: c.UINT = c.WM_APP + 13;
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
/// Test only (ZONVIE_TEST_FULL_REDRAW=1): repaint the main window whole, so a
/// gui-test can compare it with the partial frame before it.
pub const WM_APP_TEST_FULL_REDRAW: c.UINT = c.WM_APP + 43;

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
/// Replays an external WM_SIZE that arrived while device recovery held the
/// App/renderer generation in an unpublished state.
pub const TIMER_EXTERNAL_SIZE_REPLAY: c.UINT_PTR = 18;
pub const TIMER_MSG_THROTTLE: c.UINT_PTR = 19;
/// Replays a main-window WM_SIZE suppressed during device recovery so the
/// recovered HWND size is also propagated to Neovim rows/cols.
pub const TIMER_MAIN_SIZE_REPLAY: c.UINT_PTR = 20;
/// One-shot revert of the copy button's post-copy checkmark back to the copy
/// icon. Re-armed on a repeat click, so the acknowledgement simply extends.
pub const TIMER_COPY_BUTTON_REVERT: c.UINT_PTR = 21;
/// How long the copy button shows its checkmark (matches macOS's 0.8s).
pub const COPY_BUTTON_REVERT_MS: c.UINT = 800;
/// One-shot trailing send of a knob drag position the throttle held back.
pub const TIMER_SCROLLBAR_DRAG_FLUSH: c.UINT_PTR = 22;
/// One-shot re-read for a copy click whose grid try-lock was busy.
pub const TIMER_COPY_BUTTON_RETRY: c.UINT_PTR = 23;
pub const EXTERNAL_CREATE_RETRY_INTERVAL_MS: c.UINT = 100;
pub const EXTERNAL_CREATE_RETRY_MAX_MS: u32 = 5000;
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

/// The core's reserved grid ids for the ext_* windows, read from where they
/// are defined rather than restated.
pub const CMDLINE_GRID_ID: i64 = core.grid_mod.CMDLINE_GRID_ID;
pub const POPUPMENU_GRID_ID: i64 = core.grid_mod.POPUPMENU_GRID_ID;
pub const MESSAGE_GRID_ID: i64 = core.grid_mod.MESSAGE_GRID_ID;
pub const MSG_HISTORY_GRID_ID: i64 = core.grid_mod.MSG_HISTORY_GRID_ID;

// =========================================================================
// Cmdline / message styling constants
// =========================================================================

// --- Cmdline window styling constants (matching macOS) ---
pub const CMDLINE_PADDING: u32 = 12; // Padding around content (pixels)
pub const CMDLINE_ICON_SIZE: u32 = 18; // Icon size (pixels)
// Measured from the content padding, so the icon sits at x = 12 and the text
// at x = 44, where macOS puts them (its cmdlineIconMarginLeft is measured from
// the window edge and already includes the padding). These were 2 and 4, which
// drew the icon at 14 and the text at 36.
pub const CMDLINE_ICON_MARGIN_LEFT: u32 = 0; // Left margin for icon (pixels)
pub const CMDLINE_ICON_MARGIN_RIGHT: u32 = 14; // Right margin for icon (pixels)
pub const CMDLINE_BORDER_WIDTH: u32 = 1; // Border width (pixels)
pub const CMDLINE_CORNER_RADIUS: f32 = 8.0; // Corner radius for rounded rect
pub const CMDLINE_SCREEN_MARGIN: u32 = 40; // Margin from screen edges (matching macOS cmdlineScreenMargin)

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
    /// App.external_session_generation when the core asked for this window.
    /// Read at request time: a create still queued across on_restart /
    /// on_connect belongs to the old session, whatever the counter says when
    /// the UI thread gets to it.
    session_generation: u64,
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
/// One grid placed on one surface, mirroring `zonvie_layer` in
/// include/zonvie_core.h.
pub const SurfaceLayer = struct {
    grid_id: i64,
    anchor_grid: i64,
    x_px: i32,
    y_px: i32,
    rows: u32,
    cols: u32,
    z: i32,
    follows_scroll: bool,
    /// The layer accepts mouse input. A hit test must skip a layer without
    /// it -- Neovim refuses an event addressed to such a window rather than
    /// passing it to what is behind.
    mouse_enabled: bool = true,
};

/// Immutable while retained by a paint; capacity is reused after retirement.
pub const SurfaceLayers = core.render_layout.List(SurfaceLayer);

pub const SurfaceState = struct {
    row_verts: std.ArrayListUnmanaged(RowVerts) = .empty,
    cursor_verts: std.ArrayListUnmanaged(Vertex) = .empty,
    row_mode: bool = false,
    paint_full: bool = true,
    rows: u32 = 0,
    cols: u32 = 0,
    last_cursor_row: ?u32 = null,

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

    /// Free CPU-side allocations only. GPU resources (VBs) are owned by the
    /// window struct and must be released separately.
    pub fn deinitCpuState(self: *SurfaceState, alloc: std.mem.Allocator) void {
        self.cursor_verts.deinit(alloc);
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
    row_mode: bool = false,
    rows: u32 = 0,
    cols: u32 = 0,
    // Shared font/cell/linespace generation used to build row NDC. Main
    // drawable-only resizes deliberately do not affect this value.
    metrics_gen: u64 = 0,
    /// Rows of the non-root grids this surface places as layers. They rotate
    /// with the root rows, so a paint reads every grid from one commit. The
    /// list never shrinks: a free entry has `grid_id == 0` and keeps its map's
    /// capacity for the next grid.
    layer_rows: std.ArrayListUnmanaged(LayerRows) = .empty,

    pub fn layerRows(self: *const VertexSet, grid_id: i64) ?*const LayerRows {
        for (self.layer_rows.items) |*lr| {
            if (lr.grid_id == grid_id) return lr;
        }
        return null;
    }

    fn layerRowsMut(self: *VertexSet, grid_id: i64) ?*LayerRows {
        for (self.layer_rows.items) |*lr| {
            if (lr.grid_id == grid_id) return lr;
        }
        return null;
    }

    fn freeLayerEntry(alloc: std.mem.Allocator, pool: *SlotPool, lr: *LayerRows) void {
        for (lr.row_map.items) |m| pool.release(alloc, m.slot);
        lr.row_map.items.len = 0;
        lr.grid_id = 0;
    }

    /// Release every layer row slot; entries keep their map capacity.
    pub fn releaseLayerSlots(self: *VertexSet, alloc: std.mem.Allocator, pool: *SlotPool) void {
        for (self.layer_rows.items) |*lr| freeLayerEntry(alloc, pool, lr);
    }

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
    /// Caller must releaseAllSlots and releaseLayerSlots before calling this.
    pub fn deinitCpu(self: *VertexSet, alloc: std.mem.Allocator) void {
        self.row_map.deinit(alloc);
        for (self.layer_rows.items) |*lr| lr.row_map.deinit(alloc);
        self.layer_rows.deinit(alloc);
    }
};

/// One non-root grid's rows inside a VertexSet, slots from the surface's pool.
pub const LayerRows = struct {
    grid_id: i64 = 0,
    row_map: std.ArrayListUnmanaged(RowMapping) = .empty,
};

/// What the core changed in one layer grid since the last paint, for the
/// paint to turn into redraw rows and a GPU copy.
pub const LayerDamage = struct {
    grid_id: i64 = 0,
    rows: std.DynamicBitSetUnmanaged = .{},
    full: bool = false,
    scroll: ?LayerScroll = null,

    fn markRows(self: *LayerDamage, row_start: usize, row_end: usize) void {
        const end = @min(row_end, self.rows.bit_length);
        const start = @min(row_start, end);
        if (start == end) return;
        self.rows.setRangeValue(.{ .start = start, .end = end }, true);
    }

    /// Fold a shift into this damage: the bits travel with the rows, the band
    /// it vacated is owed, and the rest of the region is a GPU copy the paint
    /// still owes. Two shifts of different regions cannot be one copy, so
    /// neither runs and both regions are redrawn.
    fn addShift(self: *LayerDamage, s: LayerScroll) void {
        render_pipeline_helpers.shiftRowBits(&self.rows, s.row_start, s.row_end, s.rows_delta);
        const shift: u32 = @intCast(@abs(s.rows_delta));
        if (s.rows_delta > 0) {
            self.markRows(s.row_end - shift, s.row_end);
        } else {
            self.markRows(s.row_start, s.row_start + shift);
        }
        switch (render_pipeline_helpers.mergeLayerScroll(self.scroll, s)) {
            .accumulate => |merged| self.scroll = merged,
            .conflict => |both| {
                self.markRows(both.old.row_start, both.old.row_end);
                self.markRows(both.new.row_start, both.new.row_end);
                self.scroll = null;
            },
        }
    }
};

/// Per-grid damage, kept in a list that never shrinks so its bitsets are
/// reused; entries past `len` are free.
pub const LayerDamageList = struct {
    items: std.ArrayListUnmanaged(LayerDamage) = .empty,
    len: usize = 0,

    pub fn slice(self: *const LayerDamageList) []const LayerDamage {
        return self.items.items[0..self.len];
    }

    pub fn find(self: *const LayerDamageList, grid_id: i64) ?*const LayerDamage {
        for (self.items.items[0..self.len]) |*d| {
            if (d.grid_id == grid_id) return d;
        }
        return null;
    }

    /// The entry for `grid_id`, sized to `rows`, added clear when missing.
    /// Null on allocation failure, in which case the caller owes a full paint.
    fn getOrAdd(self: *LayerDamageList, alloc: std.mem.Allocator, grid_id: i64, rows: usize) ?*LayerDamage {
        const d = for (self.items.items[0..self.len]) |*d| {
            if (d.grid_id == grid_id) break d;
        } else blk: {
            if (self.len == self.items.items.len) self.items.append(alloc, .{}) catch return null;
            const d = &self.items.items[self.len];
            self.len += 1;
            d.grid_id = grid_id;
            d.full = false;
            d.scroll = null;
            if (d.rows.bit_length > 0) d.rows.unsetAll();
            break :blk d;
        };
        if (d.rows.bit_length < rows) d.rows.resize(alloc, rows, false) catch return null;
        return d;
    }

    pub fn clear(self: *LayerDamageList) void {
        self.len = 0;
    }

    fn deinit(self: *LayerDamageList, alloc: std.mem.Allocator) void {
        for (self.items.items) |*d| d.rows.deinit(alloc);
        self.items.deinit(alloc);
        self.len = 0;
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
    /// Layer list bundled with this committed set, so a paint sees the layers
    /// and the vertices they place from the same transaction.
    layers: SurfaceLayers = .{},
    /// Which grid owns the cursor in this committed set, from the same
    /// transaction as the cursor vertices themselves.
    cursor_layer_grid_id: i64 = 1,
    /// Layer damage taken with this snapshot. Owned by the outermost paint
    /// until the next one; empty for a re-entrant paint.
    layer_damage: []const LayerDamage = &.{},
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
    /// The grid this surface's rows belong to: 1 for the main window, its
    /// own grid for an external one. Cursor rows are rows of the cursor's
    /// grid, so they name root rows only when that grid is this one.
    root_grid_id: i64 = 1,

    // --- rotation_mu protects these fields ---
    rotation_mu: std.Io.Mutex = .init,
    write_index: u8 = 0,
    committed_index: u8 = 1,
    is_in_flush: bool = false,

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
    // Accumulated by onGridRowScroll during a single flush.
    flush_scroll_rect: ?c.RECT = null,
    flush_scroll_dy_px: i32 = 0,
    flush_vb_shift: i32 = 0,
    // Scroll region bounds in rows, matching remapRowSlots' [row_start, row_end).
    // Used by applyScrollShift to limit shiftRowVBs to the same range.
    flush_scroll_row_start: u32 = 0,
    flush_scroll_row_end: u32 = 0,

    // Layer list for this surface. Staged by on_surface_layout during a flush
    // and promoted at commitFlush, so layers and the vertices they place
    // become visible in the same transaction.
    flush_layers: ?SurfaceLayers = null,
    committed_layers: SurfaceLayers = .{},
    spare_layers: SurfaceLayers = .{},
    /// Which grid owns the surface's one cursor. Staged by the cursor
    /// callback and promoted with the cursor set.
    flush_cursor_layer_grid_id: ?i64 = null,
    committed_cursor_layer_grid_id: i64 = 1,

    /// Layer damage of the open flush (core thread), accumulated since the
    /// last paint (rotation_mu), and taken by the outermost paint (UI thread).
    flush_layer_damage: LayerDamageList = .{},
    pending_layer_damage: LayerDamageList = .{},
    paint_layer_damage: LayerDamageList = .{},

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
        if (!self.copyLayerRows(alloc, wi, ci)) return false;

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
        self.flush_layer_damage.clear();
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
            const pick = self.pickCursorCandidate() orelse return false;
            self.main_cursor_sets[pick.picked].verts.ensureTotalCapacity(alloc, verts.len) catch return false;
            self.main_cursor_write_index = pick.picked;
            self.main_cursor_flush_paint_full = false;
            self.main_cursor_flush_old_row = self.main_cursor_sets[pick.committed].last_cursor_row;
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

    /// The cursor row this flush has staged, or the committed one when it has
    /// staged none. Core thread only.
    pub fn stagedCursorRow(self: *const TripleBufferedSurface) ?u32 {
        const idx = if (self.main_cursor_in_flush) self.main_cursor_write_index else self.main_cursor_committed_index;
        return self.main_cursor_sets[idx].last_cursor_row;
    }

    /// Whether every row of the write set holds content the core has sent,
    /// so a row shift carries only rows that exist. A new row starts with no
    /// slot; one a shift vacates keeps its slot until the core resends it.
    pub fn writeSetRowsSeeded(self: *TripleBufferedSurface, total_rows: u32) bool {
        const ws = self.writeSet();
        if (!ws.row_mode or ws.row_map.items.len < total_rows) return false;
        for (ws.row_map.items[0..total_rows]) |mapping| {
            if (mapping.slot == SLOT_NONE) return false;
        }
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
            candidate = (self.pickCursorCandidate() orelse return false).picked;
        }
        self.main_cursor_sets[candidate].verts.ensureTotalCapacity(alloc, vert_count) catch return false;
        return true;
    }

    /// The first cursor set that is neither committed nor held by a UI
    /// reader, with the committed index read under the same lock.
    fn pickCursorCandidate(self: *TripleBufferedSurface) ?struct { picked: u8, committed: u8 } {
        self.rotation_mu.lockUncancelable(core.clock.io());
        defer self.rotation_mu.unlock(core.clock.io());
        const ci = self.main_cursor_committed_index;
        for (0..SET_COUNT) |i| {
            const idx: u8 = @intCast(i);
            if (idx != ci and self.main_cursor_ui_read_refcount[i] == 0) return .{ .picked = idx, .committed = ci };
        }
        return null;
    }

    pub fn markFlushPaintFull(self: *TripleBufferedSurface) void {
        if (self.is_in_flush) self.flush_paint_full = true;
        if (self.main_cursor_in_flush) self.main_cursor_flush_paint_full = true;
    }

    /// Cancel a flush (reset is_in_flush without committing).
    pub fn cancelFlush(self: *TripleBufferedSurface) void {
        if (self.is_in_flush) self.sparse_sync.row_sync_full[self.write_index] = true;
        // An aborted flush's staged state must not be promoted by the next
        // successful commit: the core re-sends everything after an abort.
        if (self.flush_layers) |*staged| staged.deinit();
        self.flush_layers = null;
        self.flush_cursor_layer_grid_id = null;
        self.flush_layer_damage.clear();
        self.is_in_flush = false;
        self.main_cursor_in_flush = false;
        self.main_cursor_flush_paint_full = false;
        self.main_cursor_flush_old_row = null;
        self.main_cursor_flush_new_row = null;
    }

    /// Stage this surface's layer list. Core thread, inside the flush bracket.
    pub fn stageLayers(self: *TripleBufferedSurface, layers: SurfaceLayers) void {
        if (self.flush_layers) |*staged| staged.deinit();
        self.flush_layers = layers;
    }

    pub fn prepareLayers(self: *TripleBufferedSurface, alloc: std.mem.Allocator, budget: *core.render_layout.Budget, count: usize) !SurfaceLayers {
        try self.spare_layers.resize(alloc, budget, count);
        const layers = self.spare_layers;
        self.spare_layers = .{};
        return layers;
    }

    /// Stage which grid owns the surface's one cursor. Promoted with the
    /// cursor set, so a paint never pairs one grid's origin with another
    /// grid's cursor vertices.
    pub fn stageCursorLayerGrid(self: *TripleBufferedSurface, grid_id: i64) void {
        self.flush_cursor_layer_grid_id = grid_id;
    }

    /// The cursor's owning grid as this flush sees it: the value staged in
    /// this bracket, else the committed one. Core thread, inside the bracket.
    pub fn cursorLayerGridIdInFlush(self: *const TripleBufferedSurface) i64 {
        return self.flush_cursor_layer_grid_id orelse self.committed_cursor_layer_grid_id;
    }

    /// Commit the write set as the new committed set.
    pub fn commitFlush(self: *TripleBufferedSurface, alloc: std.mem.Allocator) void {
        if (!self.is_in_flush and !self.main_cursor_in_flush and self.flush_layers == null) return;

        self.rotation_mu.lockUncancelable(core.clock.io());
        defer self.rotation_mu.unlock(core.clock.io());

        // Before the placement is promoted: a moved layer is found by
        // comparing the staged placement with the committed one.
        self.mergeLayerDamageLocked(alloc, self.flush_layers);
        self.flush_layer_damage.clear();
        if (self.is_in_flush) self.pruneLayerRows(alloc, self.flush_layers orelse self.committed_layers);

        // Layers and the vertices they place become visible together.
        if (self.flush_layers) |staged| {
            self.spare_layers.deinit();
            self.spare_layers = self.committed_layers;
            self.committed_layers = staged;
            self.flush_layers = null;
            self.pending_paint_full = true;
        }
        if (self.flush_cursor_layer_grid_id) |staged_grid| {
            self.committed_cursor_layer_grid_id = staged_grid;
            self.flush_cursor_layer_grid_id = null;
        }

        // Cursor and rows publish while holding the same lock. A paint can
        // therefore observe either the complete old pair or complete new pair,
        // never new rows with the previous cursor (or vice versa).
        if (self.main_cursor_in_flush) {
            // The cursor is drawn into the retained back texture, not at
            // present time (present ignores cursor_vb), so the previous one is
            // still there. Redraw both logical rows before overlaying the
            // replacement so moves, shape changes, and disappearance cannot
            // leave it behind.
            const row_count: usize = if (self.is_in_flush)
                self.sets[self.write_index].row_map.items.len
            else
                self.sets[self.committed_index].row_map.items.len;
            if (self.pending_dirty.bit_length != row_count) {
                self.pending_dirty.resize(alloc, row_count, false) catch {
                    self.pending_paint_full = true;
                };
            }
            // A cursor on a layer: its rows are that grid's, and marking
            // them here dirtied unrelated root rows (a whole-width band of
            // grid 1 on the main window, which is empty under multigrid). A
            // cursor changing grids repaints whole on its own.
            const cursor_on_root = self.committed_cursor_layer_grid_id == self.root_grid_id;
            if (!cursor_on_root) {
                // Nothing of the root to redraw.
            } else if (self.pending_dirty.bit_length == row_count) {
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
        self.is_in_flush = false;
    }

    /// Get the current write set (core thread, during flush only).
    pub fn writeSet(self: *TripleBufferedSurface) *VertexSet {
        return &self.sets[self.write_index];
    }

    /// Acquire the committed set for painting. Returns snapshot info.
    /// Caller must call releaseFromPaint when done.
    /// Copy the rows `acquireForPaint` snapshotted as dirty into `keys`,
    /// sorted and unique (the bitset iterates in order). False when the
    /// list could not be grown, in which case it is left empty and the
    /// caller abandons the paint. Both drivers had this loop inline.
    pub fn snapshotDirtyRowKeys(
        self: *const TripleBufferedSurface,
        alloc: std.mem.Allocator,
        keys: *std.ArrayListUnmanaged(u32),
    ) bool {
        keys.clearRetainingCapacity();
        keys.ensureTotalCapacity(alloc, self.paint_dirty_snapshot.count()) catch return false;
        var it = self.paint_dirty_snapshot.iterator(.{});
        while (it.next()) |row_idx| keys.appendAssumeCapacity(@intCast(row_idx));
        return true;
    }

    /// Ask the next paint to redraw the whole surface. The one way either
    /// driver arms it; the main driver had the three lines inline at ten
    /// sites and the external one at one.
    pub fn requestFullPaint(self: *TripleBufferedSurface) void {
        self.rotation_mu.lockUncancelable(core.clock.io());
        self.pending_paint_full = true;
        self.rotation_mu.unlock(core.clock.io());
    }

    /// Hand back the damage a paint took at acquireForPaint and never drew:
    /// its dirty rows, and a full paint when it was one. Only for a paint
    /// that consumed no scroll; a scroll is not handed back.
    pub fn returnUndrawnDamage(self: *TripleBufferedSurface, rows: []const u32, full: bool) void {
        self.rotation_mu.lockUncancelable(core.clock.io());
        defer self.rotation_mu.unlock(core.clock.io());
        if (full) self.pending_paint_full = true;
        for (rows) |row| {
            if (row < self.pending_dirty.bit_length) {
                self.pending_dirty.set(row);
            } else {
                self.pending_paint_full = true;
            }
        }
    }

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
            // A swap, not a copy: the previous paint's list becomes the next
            // commits' storage, bitsets and all.
            std.mem.swap(LayerDamageList, &self.paint_layer_damage, &self.pending_layer_damage);
            self.pending_layer_damage.clear();
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

        const layer_damage: []const LayerDamage = if (self.paint_nesting == 0) self.paint_layer_damage.slice() else &.{};
        self.paint_nesting += 1;
        return .{
            .committed_index = ci,
            .cursor_index = cursor_ci,
            .paint_full = paint_full,
            .layers = self.committed_layers.retain(),
            .cursor_layer_grid_id = self.committed_cursor_layer_grid_id,
            .layer_damage = layer_damage,
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
            (self.pending_dirty.count() > 0 or self.pending_paint_full or self.pending_layer_damage.len != 0);
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

        self.applySparseRowSync(alloc, dst_idx, src_idx);
        return true;
    }

    /// Make dst's layer rows a shallow copy of src's. Layers are small, so
    /// every flush copies them whole instead of tracking sparse changes.
    /// Every allocation comes first: a failure leaves dst untouched.
    fn copyLayerRows(self: *TripleBufferedSurface, alloc: std.mem.Allocator, dst_idx: u8, src_idx: u8) bool {
        const dst = &self.sets[dst_idx];
        const src = &self.sets[src_idx];
        const n = src.layer_rows.items.len;
        while (dst.layer_rows.items.len < n) dst.layer_rows.append(alloc, .{}) catch return false;
        for (src.layer_rows.items, 0..) |s, i| {
            dst.layer_rows.items[i].row_map.ensureTotalCapacity(alloc, s.row_map.items.len) catch return false;
        }

        dst.releaseLayerSlots(alloc, &self.pool);
        for (src.layer_rows.items, 0..) |s, i| {
            const d = &dst.layer_rows.items[i];
            d.grid_id = s.grid_id;
            d.row_map.appendSliceAssumeCapacity(s.row_map.items);
            for (s.row_map.items) |m| self.pool.retain(m.slot);
        }
        return true;
    }

    /// Store one layer row in the open flush's write set: detach its slot,
    /// write, and record the damage. `total_rows` is authoritative, so rows
    /// past it are released. False means the caller must abort the flush.
    pub fn writeLayerRow(
        self: *TripleBufferedSurface,
        alloc: std.mem.Allocator,
        grid_id: i64,
        row: u32,
        verts: []const Vertex,
        total_rows: u32,
    ) bool {
        std.debug.assert(self.is_in_flush);
        if (row >= total_rows) return true;
        const ws = self.writeSet();
        const lr = ws.layerRowsMut(grid_id) orelse blk: {
            const free = ws.layerRowsMut(0) orelse free_blk: {
                ws.layer_rows.append(alloc, .{}) catch return false;
                break :free_blk &ws.layer_rows.items[ws.layer_rows.items.len - 1];
            };
            free.grid_id = grid_id;
            break :blk free;
        };
        const rows: usize = total_rows;
        if (lr.row_map.items.len > rows) {
            for (lr.row_map.items[rows..]) |m| self.pool.release(alloc, m.slot);
            lr.row_map.items.len = rows;
        } else if (lr.row_map.items.len < rows) {
            lr.row_map.appendNTimes(alloc, .{}, rows - lr.row_map.items.len) catch return false;
        }
        const dmg = self.flush_layer_damage.getOrAdd(alloc, grid_id, rows) orelse return false;

        const mapping = &lr.row_map.items[row];
        const slot = self.detachSlot(alloc, mapping) orelse return false;
        slot.verts.clearRetainingCapacity();
        slot.verts.appendSlice(alloc, verts) catch return false;
        // Under ext_multigrid the text is all in layers, so their rows set the
        // pool's retirement floor too.
        self.pool.noteRowVerts(verts.len);
        slot.origin_row = row;
        slot.ver +%= 1;
        dmg.markRows(row, @as(usize, row) + 1);
        return true;
    }

    /// Move a layer's surviving rows for a row shift; the vacated band is
    /// emptied for the core to refill. False when the region does not fit the
    /// grid's rows, in which case the caller asks for a full resend.
    pub fn shiftLayerRows(
        self: *TripleBufferedSurface,
        alloc: std.mem.Allocator,
        grid_id: i64,
        scroll: LayerScroll,
    ) bool {
        std.debug.assert(self.is_in_flush);
        const lr = self.writeSet().layerRowsMut(grid_id) orelse return false;
        switch (render_pipeline_helpers.checkShift(scroll.row_start, scroll.row_end, scroll.rows_delta, lr.row_map.items.len)) {
            .noop => return true,
            .invalid => return false,
            .fits => {},
        }
        const dmg = self.flush_layer_damage.getOrAdd(alloc, grid_id, lr.row_map.items.len) orelse return false;
        const band = render_pipeline_helpers.rotateRegion(RowMapping, lr.row_map.items, scroll.row_start, scroll.row_end, scroll.rows_delta);
        for (lr.row_map.items[band.start..band.end]) |*m| {
            self.pool.release(alloc, m.slot);
            m.slot = SLOT_NONE;
        }
        dmg.addShift(scroll);
        return true;
    }

    /// Whether the open flush's write set holds rows for `grid_id`.
    pub fn hasLayerRows(self: *TripleBufferedSurface, grid_id: i64) bool {
        return self.writeSet().layerRowsMut(grid_id) != null;
    }

    /// Fold this flush's layer damage into the pending damage, and mark every
    /// layer whose placement changed for a whole redraw. Caller holds
    /// rotation_mu. An allocation failure degrades to a full paint, which
    /// redraws every layer.
    fn mergeLayerDamageLocked(self: *TripleBufferedSurface, alloc: std.mem.Allocator, staged_layers: ?SurfaceLayers) void {
        for (self.flush_layer_damage.slice()) |*f| {
            const p = self.pending_layer_damage.getOrAdd(alloc, f.grid_id, f.rows.bit_length) orelse {
                self.pending_paint_full = true;
                continue;
            };
            // The rows already pending moved with this flush's shift.
            if (f.scroll) |s| p.addShift(s);
            if (f.full) p.full = true;
            // Recycled entries keep their longest length, so the two can
            // differ; getOrAdd made p at least as long as f.
            var it = f.rows.iterator(.{});
            while (it.next()) |row| p.rows.set(row);
        }
        const staged = staged_layers orelse return;
        for (staged.slice(), 0..) |layer, index| {
            if (index == 0) continue;
            const unchanged = for (self.committed_layers.slice()) |prev| {
                if (prev.grid_id != layer.grid_id) continue;
                break prev.x_px == layer.x_px and prev.y_px == layer.y_px and
                    prev.rows == layer.rows and prev.cols == layer.cols and
                    prev.z == layer.z and prev.follows_scroll == layer.follows_scroll;
            } else false;
            if (unchanged) continue;
            const p = self.pending_layer_damage.getOrAdd(alloc, layer.grid_id, layer.rows) orelse {
                self.pending_paint_full = true;
                continue;
            };
            p.full = true;
            p.scroll = null;
        }
    }

    /// Hand a whole redraw of `layers` back to the next paint, for a frame
    /// that took their damage and never reached the screen.
    pub fn returnLayerDamageFull(self: *TripleBufferedSurface, alloc: std.mem.Allocator, layers: []const SurfaceLayer) void {
        self.rotation_mu.lockUncancelable(core.clock.io());
        defer self.rotation_mu.unlock(core.clock.io());
        if (layers.len <= 1) return;
        for (layers[1..]) |layer| {
            const p = self.pending_layer_damage.getOrAdd(alloc, layer.grid_id, layer.rows) orelse {
                self.pending_paint_full = true;
                continue;
            };
            p.full = true;
            p.scroll = null;
        }
    }

    /// Drop the write set's rows of grids the surface no longer places. Core
    /// thread, at commit, before the set is published.
    fn pruneLayerRows(self: *TripleBufferedSurface, alloc: std.mem.Allocator, layers: SurfaceLayers) void {
        const ws = &self.sets[self.write_index];
        for (ws.layer_rows.items) |*lr| {
            if (lr.grid_id == 0) continue;
            const placed = for (layers.slice()) |layer| {
                if (layer.grid_id == lr.grid_id) break true;
            } else false;
            if (!placed) VertexSet.freeLayerEntry(alloc, &self.pool, lr);
        }
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

        return true;
    }

    /// One core row into the open flush's write set: detach, write, mark it
    /// changed. A row past `ws.rows` is ignored. False means the caller must
    /// abort the flush: a row written but not marked is dropped by commitFlush
    /// and skipped by the paint, and a failed detach or append would publish a
    /// stale or blank row.
    pub fn writeFlushRow(self: *TripleBufferedSurface, alloc: std.mem.Allocator, row: u32, verts: []const Vertex) bool {
        const ws = self.writeSet();
        if (ws.rows != 0 and row >= ws.rows) return true;
        ws.row_mode = true;
        if (!ws.ensureRowStorage(alloc, row)) return false;
        const slot = self.cowDetachRow(alloc, row) orelse return false;
        slot.verts.clearRetainingCapacity();
        slot.verts.appendSlice(alloc, verts) catch return false;
        self.pool.noteRowVerts(verts.len);
        slot.origin_row = row;
        slot.ver +%= 1;
        if (row >= self.sparse_sync.flush_dirty.bit_length) {
            if (ws.rows <= self.sparse_sync.flush_dirty.bit_length) return false;
            if (!self.prepareRowSyncTracking(alloc, ws.rows)) return false;
            if (row >= self.sparse_sync.flush_dirty.bit_length) return false;
        }
        return self.markFlushRowChanged(row);
    }

    /// COW detach: prepare a slot for exclusive write access.
    /// If ref_count > 1, allocate a new slot and release the old one.
    /// Returns a pointer to the exclusively-owned RowSlot, or null on OOM.
    pub fn cowDetachRow(self: *TripleBufferedSurface, alloc: std.mem.Allocator, row: u32) ?*RowSlot {
        const vs = self.writeSet();
        if (row >= vs.row_map.items.len) return null;
        return self.detachSlot(alloc, &vs.row_map.items[row]);
    }

    /// cowDetachRow for any mapping of the write set, root or layer.
    fn detachSlot(self: *TripleBufferedSurface, alloc: std.mem.Allocator, mapping: *RowMapping) ?*RowSlot {
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
        if (self.flush_layers) |*staged| staged.deinit();
        self.flush_layers = null;
        self.committed_layers.deinit();
        self.spare_layers.deinit();
        // Release all slot references from each set.
        for (&self.sets) |*set| {
            set.releaseAllSlots(alloc, &self.pool);
            set.releaseLayerSlots(alloc, &self.pool);
            set.deinitCpu(alloc);
        }
        self.flush_layer_damage.deinit(alloc);
        self.pending_layer_damage.deinit(alloc);
        self.paint_layer_damage.deinit(alloc);
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

    const icon_flags = c.NIF_ICON | c.NIF_TIP | c.NIF_MESSAGE;

    pub fn init(hwnd: c.HWND) TrayIcon {
        var nid: c.NOTIFYICONDATAW = std.mem.zeroes(c.NOTIFYICONDATAW);
        nid.cbSize = @sizeOf(c.NOTIFYICONDATAW);
        nid.hWnd = hwnd;
        nid.uID = 1;
        nid.uFlags = icon_flags;
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
            // showBalloon leaves NIF_INFO alone in uFlags.
            self.nid.uFlags = icon_flags;
            if (c.Shell_NotifyIconW(c.NIM_ADD, &self.nid) == 0) {
                if (applog.isEnabled()) applog.appLog("[tray] Shell_NotifyIconW(NIM_ADD) failed\n", .{});
                return false;
            }
            self.added = true;
            if (applog.isEnabled()) applog.appLog("[tray] added tray icon\n", .{});
        }
        return self.added;
    }

    /// Put the icon back after the shell broadcast TaskbarCreated: after an
    /// Explorer restart it is gone (NIM_ADD); on a broadcast that kept it,
    /// NIM_ADD fails and NIM_MODIFY confirms it is still there.
    pub fn readd(self: *TrayIcon) bool {
        self.added = false;
        if (self.add()) return true;
        self.nid.uFlags = icon_flags;
        self.added = c.Shell_NotifyIconW(c.NIM_MODIFY, &self.nid) != 0;
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

        // Bounded in UTF-16 units before converting (one slot kept for the
        // null), as onSetTitle does.
        const title_cap = self.nid.szInfoTitle.len - 1;
        const tn = std.unicode.utf8ToUtf16Le(self.nid.szInfoTitle[0..title_cap], utf8ValidPrefix(title, title_cap)) catch 0;
        self.nid.szInfoTitle[tn] = 0;

        const msg_cap = self.nid.szInfo.len - 1;
        const mn = std.unicode.utf8ToUtf16Le(self.nid.szInfo[0..msg_cap], utf8ValidPrefix(msg_text, msg_cap)) catch 0;
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
    timeout_ms: u32 = 4000, // 0 = no auto-hide
    /// showmode / showcmd / ruler: the status channel; null for msg_show.
    status: ?MiniWindowId = null,
    /// on_msg_clear, queued in order with the messages: the core resends the
    /// statuses it holds right after the clear.
    clear: bool = false,
};

/// Stored message for display stack (keeps track of multiple messages)
pub const DisplayMessage = struct {
    text: [8192]u8 = undefined,
    text_len: usize = 0,
    kind: [32]u8 = undefined,
    kind_len: usize = 0,
    hl_id: u32 = 0,
    view_type: zonvie_msg_view_type = .ext_float,
};

/// Mini window type identifier (for routing)
pub const MiniWindowId = enum(u2) {
    showmode = 0,
    showcmd = 1,
    ruler = 2,
    /// A msg_show routed to the mini view. It had borrowed `showmode`, so it
    /// overwrote "-- INSERT --" and a later showmode erased it; macOS keeps
    /// the same separate slot.
    custom = 3,
};

/// Mini window state (one per type)
/// See App.device_lost_shader_carry.
pub const ShaderCarry = struct {
    start_qpc: i64,
    last_qpc: i64,
    cur: [4]f32,
    prev: [4]f32,
    cur_color: [4]f32,
    prev_color: [4]f32,
    change_time: f32,
};

pub const MiniWindowState = struct {
    hwnd: ?c.HWND = null,
    /// Ten lines (render_helpers.clampMiniContent) of a msg_history dump.
    text: [2048]u8 = undefined,
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

    pub fn deinit(self: *MessageWindow) void {
        _ = c.DestroyWindow(self.hwnd);
    }

    /// Get text color based on message kind; ordinary kinds use the Normal
    /// foreground `normal_fg`, as on macOS.
    pub fn getTextColor(self: *const MessageWindow, normal_fg: c.COLORREF) c.COLORREF {
        return switch (core.config.toneForKind(self.kind[0..self.kind_len])) {
            .err => c.RGB(255, 102, 102),
            .warn => c.RGB(255, 217, 102),
            .prompt => c.RGB(153, 204, 255),
            .search => c.RGB(153, 255, 153),
            .normal => normal_fg,
        };
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

    // Drag state for tab reordering
    dragging_tab: ?usize = null, // Index of tab being dragged
    // Its handle: the release acts on that tab wherever a tabline_update in
    // between moved it, as macOS does.
    dragging_tab_handle: i64 = 0,
    drag_start_x: c_int = 0, // Mouse X when drag started
    drag_offset_x: c_int = 0, // Offset from tab left edge to mouse
    drag_current_x: c_int = 0, // Current mouse X during drag
    drop_target_index: ?usize = null, // Where the tab would be dropped
    drag_start_y: c_int = 0, // Mouse Y when drag started (sidebar)
    drag_current_y: c_int = 0, // Current mouse Y during drag (sidebar)
    drag_offset_y: c_int = 0, // Offset from row top edge to mouse (sidebar)

    // External drag state (for tab externalization)
    is_external_drag: bool = false,
    drag_preview_hwnd: ?c.HWND = null,

    // Close button pressed state (for proper click handling)
    close_button_pressed: ?usize = null, // Tab index of pressed close button
    // Its tab's handle: the release closes that tab wherever a tabline_update
    // in between moved it, as macOS does.
    close_button_pressed_handle: i64 = 0,

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

    /// The tab index `handle` is at now, or null once it is gone.
    pub fn indexOfHandle(self: *const TablineState, handle: i64) ?usize {
        for (self.tabs[0..self.tab_count], 0..) |tab, i| {
            if (tab.handle == handle) return i;
        }
        return null;
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

pub const LayerScroll = render_pipeline_helpers.LayerScroll;

/// What one surface's paint keeps for a layer it draws: its GPU row buffers
/// and the plan of the frame being drawn. UI thread only; the rows themselves
/// are read from the committed set the paint pinned.
pub const LayerPaintState = struct {
    grid_id: i64 = 0,
    row_vbs: std.ArrayListUnmanaged(RowVB) = .empty,
    /// The plan of one frame, settled by planLayerFrame and spent by
    /// drawSurfaceLayers.
    draw_rows: std.DynamicBitSetUnmanaged = .{},
    draw_all: bool = false,
    draw_scroll: ?LayerScroll = null,
    draw_blit_rect: ?render_pipeline_helpers.BlitRectPx = null,
    /// Layer-local, like everything the layer transform draws.
    blit_clear_band: ?struct { top_px: i32, bottom_px: i32 } = null,
    last_drawn_rows: usize = 0,

    /// Release this state's buffers and free the entry for another grid.
    fn release(self: *LayerPaintState, budget: *RowVBPhysicalBudget, retained_bytes: *usize) void {
        releaseRowVBs(self.row_vbs.items, budget, retained_bytes);
        self.row_vbs.items.len = 0;
        if (self.draw_rows.bit_length > 0) self.draw_rows.unsetAll();
        self.grid_id = 0;
        self.draw_all = false;
        self.draw_scroll = null;
        self.draw_blit_rect = null;
        self.blit_clear_band = null;
        self.last_drawn_rows = 0;
    }

    /// Something of this layer is redrawn this frame.
    fn drawsAnything(self: *const LayerPaintState) bool {
        return self.draw_all or self.draw_blit_rect != null or self.draw_rows.findFirstSet() != null;
    }
};

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

/// The buffers one surface paints with: per-row GPU vertex buffers, the
/// cursor and scrollbar overlays, the per-paint lists, and
/// where the cursor was last painted. The main window and every external
/// window hold one; they used to be two sets of fields under two sets of
/// names, and the shared row pass took them one pointer at a time.
pub const SurfacePaintState = struct {
    // Per-row GPU vertex buffers (TBS: uploaded from committed set row_verts).
    row_vbs: std.ArrayListUnmanaged(RowVB) = .empty,
    row_vb_retained_bytes: usize = 0,
    // Persistent destination for linear dirty-row/range union during scroll.
    scroll_rows_merge_scratch: std.ArrayListUnmanaged(u32) = .empty,
    cursor_vb: ?*c.ID3D11Buffer = null,
    cursor_vb_bytes: usize = 0,
    scrollbar_vb: ?*c.ID3D11Buffer = null,
    scrollbar_vb_bytes: usize = 0,
    // Per-paint lists, reused so a paint does not allocate.
    dirty_row_keys: std.ArrayListUnmanaged(u32) = .empty,
    rows_to_draw: std.ArrayListUnmanaged(u32) = .empty,
    present_rects: std.ArrayListUnmanaged(c.RECT) = .empty,
    // Row the cursor was last painted into back_tex, erased before a shift.
    last_painted_cursor_row: ?u32 = null,
    /// Which grid that row belongs to. A surface draws one cursor, but the
    /// grid that owns it changes as the user moves between windows, and the
    /// row is that grid's OWN row -- so a row remembered from the last paint
    /// cannot be placed with the grid holding the cursor now.
    last_painted_cursor_grid: i64 = 0,
    /// Paint state of each non-root layer this surface drew. Never shrinks: a
    /// free entry has `grid_id == 0` and keeps its storage for the next grid.
    layers: std.ArrayListUnmanaged(LayerPaintState) = .empty,
    layer_row_vb_retained_bytes: usize = 0,
    /// The damage spans and redraw bands of the paint being drawn
    /// (planLayerFrame), reused so a paint does not allocate.
    damage_spans: std.ArrayListUnmanaged(core.damage_bands.Band) = .empty,
    bands: std.ArrayListUnmanaged(core.damage_bands.Band) = .empty,

    pub fn layerState(self: *SurfacePaintState, grid_id: i64) ?*LayerPaintState {
        for (self.layers.items) |*s| {
            if (s.grid_id == grid_id) return s;
        }
        return null;
    }

    /// Give every non-root layer of `layers` a paint state and free the states
    /// of grids no longer placed, returning their buffers to the budget. A
    /// layer new to this surface is drawn whole. Fails only to allocate a
    /// state, which the caller treats as a failed paint.
    pub fn syncLayers(
        self: *SurfacePaintState,
        alloc: std.mem.Allocator,
        budget: *RowVBPhysicalBudget,
        layers: []const SurfaceLayer,
    ) error{OutOfMemory}!void {
        for (self.layers.items) |*s| {
            if (s.grid_id == 0) continue;
            const placed = for (layers) |layer| {
                if (layer.grid_id == s.grid_id) break true;
            } else false;
            if (!placed) s.release(budget, &self.layer_row_vb_retained_bytes);
        }
        if (layers.len <= 1) return;
        for (layers[1..]) |layer| {
            if (self.layerState(layer.grid_id) != null) continue;
            const s = self.layerState(0) orelse blk: {
                try self.layers.append(alloc, .{});
                break :blk &self.layers.items[self.layers.items.len - 1];
            };
            s.grid_id = layer.grid_id;
            s.last_drawn_rows = std.math.maxInt(usize);
        }
    }

    pub fn deinit(self: *SurfacePaintState, alloc: std.mem.Allocator, row_vb_budget: *RowVBPhysicalBudget) void {
        for (self.layers.items) |*s| {
            s.release(row_vb_budget, &self.layer_row_vb_retained_bytes);
            s.row_vbs.deinit(alloc);
            s.draw_rows.deinit(alloc);
        }
        self.layers.deinit(alloc);
        self.damage_spans.deinit(alloc);
        self.bands.deinit(alloc);
        releaseRowVBs(self.row_vbs.items, row_vb_budget, &self.row_vb_retained_bytes);
        self.row_vbs.deinit(alloc);
        self.scroll_rows_merge_scratch.deinit(alloc);
        self.dirty_row_keys.deinit(alloc);
        self.rows_to_draw.deinit(alloc);
        self.present_rects.deinit(alloc);
        if (self.cursor_vb) |vb| _ = vb.lpVtbl.*.Release.?(vb);
        self.cursor_vb = null;
        self.cursor_vb_bytes = 0;
        if (self.scrollbar_vb) |vb| _ = vb.lpVtbl.*.Release.?(vb);
        self.scrollbar_vb = null;
        self.scrollbar_vb_bytes = 0;
    }
};

/// One surface's overlay scrollbar: fade, drag, track-repeat and the viewport
/// it last showed. The main window and every external window hold one, and
/// ui/scrollbar.zig drives them all; they used to be two sets of fields with
/// two sets of functions, which had drifted (fade speed, pending-line test,
/// capture order, which grid a drag read).
pub const ScrollbarState = struct {
    visible: bool = false,
    alpha: f32 = 0.0,
    target_alpha: f32 = 0.0,
    hover: bool = false,
    dragging: bool = false,
    // Where on the knob the press landed, from its top edge: the knob keeps
    // that point under the pointer for the whole drag.
    drag_grab_px: f32 = 0,
    repeat_dir: i8 = 0, // -1 = page up, 1 = page down, 0 = none
    repeat_timer: c.UINT_PTR = 0,
    hide_timer: c.UINT_PTR = 0,
    last_scroll_time: i64 = 0, // ms, drag RPC throttle
    pending_line: i64 = -1, // throttled drag target, -1 = none
    pending_use_bottom: bool = false,
    // Viewport last shown (-1 = never).
    last_viewport_topline: i64 = -1,
    last_viewport_line_count: i64 = -1,
    last_viewport_botline: i64 = -1,
    // Grid the bar last showed (0 = none yet); kept while grid_mu is busy.
    last_grid: i64 = 0,
};

/// What every window's surface keeps, the main window's and each external
/// window's alike: the vertex state, the triple buffer, the draw buffers, the
/// scrollbar, and the paint-retry and atlas bookkeeping. They were loose fields
/// on App for the main window and a parallel set on ExternalWindow, so every
/// helper took them one by one.
pub const WindowSurface = struct {
    // CPU-side surface state (grid dims, dirty tracking).
    surface: SurfaceState = .{},
    // Triple-buffered surface for lock-free vertex handoff (core → UI thread).
    tbs: TripleBufferedSurface = .{},
    // The draw buffers.
    paint: SurfacePaintState = .{},
    // The overlay scrollbar (ui/scrollbar.zig).
    scrollbar: ScrollbarState = .{},
    /// This flush owes the window an invalidate. Set under `app.mu` by work
    /// that joins the open flush (core callbacks, and a window seeding its
    /// write set mid-flush), cleared only by onFlushEnd or a failed flush —
    /// never by paint: a paint landing mid-flush would erase the request
    /// before onFlushEnd read it, leaving the window a flush behind.

    flush_needs_invalidate: bool = false,
    /// Whether the committed cursor set holds any vertices, recorded by paint
    /// under `app.mu`: whether a blink toggle changes a pixel here. Committed,
    /// not staged, state: a cancelled flush never reaches the screen.
    /// `last_painted_cursor_row` cannot answer it, being cleared on every
    /// blink-off.
    has_committed_cursor: bool = true,
    paint_retry: PaintRetryState = .{},
    paint_retry_deadline_ms: u64 = 0,
    // The App's atlas_upload_seq this window's last paint saw (syncSharedAtlas).
    atlas_seen_upload_seq: u64 = 0,
    // OLE drop target. See ui/drop_target.zig; opaque here so app.zig carries
    // none of the COM plumbing.
    drop_target: ?*anyopaque = null,

    /// A paint of this surface succeeded: the retry it was owed is done.
    pub fn completePaintRetry(self: *WindowSurface) void {
        self.paint_retry_deadline_ms = 0;
        _ = self.paint_retry.succeeded();
    }

    /// Release every row VB, for a paint that draws no rows (flat or
    /// decorated) after an earlier row-mode frame.
    pub fn dropRowVBs(self: *WindowSurface, app: *App) void {
        _ = resizeRowVBsForPaint(app.alloc, &self.paint.row_vbs, &app.row_vb_budget, &self.paint.row_vb_retained_bytes, 0);
    }

    pub const RecoveryVB = struct {
        buffer: *c.ID3D11Buffer,
        row_bytes: usize,
        /// The bytes are owed to `paint.layer_row_vb_retained_bytes`, not to
        /// the root's.
        layer: bool = false,
    };

    /// Detach one of this surface's device-bound buffers without calling COM,
    /// for device-loss teardown; the caller releases it after dropping app.mu.
    /// `row_bytes` is what a row buffer returns to the row budget. Caller
    /// holds app.mu.
    pub fn detachOneRecoveryVB(self: *WindowSurface) ?RecoveryVB {
        if (detachOneRowVB(self.paint.row_vbs.items)) |d| return .{ .buffer = d.buffer, .row_bytes = d.bytes };
        for (self.paint.layers.items) |*s| {
            if (detachOneRowVB(s.row_vbs.items)) |d| return .{ .buffer = d.buffer, .row_bytes = d.bytes, .layer = true };
        }
        if (self.paint.cursor_vb) |vb| {
            self.paint.cursor_vb = null;
            self.paint.cursor_vb_bytes = 0;
            return .{ .buffer = vb, .row_bytes = 0 };
        }
        if (self.paint.scrollbar_vb) |vb| {
            self.paint.scrollbar_vb = null;
            self.paint.scrollbar_vb_bytes = 0;
            return .{ .buffer = vb, .row_bytes = 0 };
        }
        return null;
    }
};

pub const ExternalWindow = struct {
    hwnd: c.HWND,
    window_wake_cookie: usize,
    win_id: i64 = 0, // Neovim window handle
    renderer: d3d11.Renderer,

    /// The state every window's surface keeps; see WindowSurface.
    surf: WindowSurface = .{},

    needs_renderer_resize: bool = false, // Deferred renderer resize (to avoid deadlock)
    needs_window_resize: bool = false, // Deferred window resize (to avoid deadlock with WM_SIZE)
    pending_window_w: c_int = 0, // Pending window width for deferred resize
    pending_window_h: c_int = 0, // Pending window height for deferred resize
    // DPI scale of the monitor this external window is currently on (may
    // differ from app.dpi_scale on a mixed-DPI multi-monitor setup). Used
    // ONLY for this window's own scrollbar hit-test geometry — NOT for font
    // rasterization, which remains driven solely by the shared app.atlas
    // (see ExternalWndProc's WM_DPICHANGED case for why).
    dpi_scale: f32 = 1.0,
    cached_bg_color: ?[3]f32 = null, // Cached background color for cmdline (persists across redraws)
    decorated_scratch: std.ArrayListUnmanaged(Vertex) = .empty, // drawDecoratedExternalSurface's output


    // When true, suppress tryResizeGrid in WM_SIZE handler (programmatic resize from grid_resize).
    suppress_resize_callback: bool = false,

    // Close state - set when window is scheduled for closing (don't paint or access renderer)
    is_pending_close: bool = false,

    /// App.external_session_generation when this window was created. Its
    /// position is saved on close only while that is still the current one.
    session_generation: u64 = 0,

    // Paint reference count - prevents freeing while paint is in progress
    // DXGI operations can pump Win32 messages, so close could be triggered during paint.
    // This counter ensures ext_win isn't freed until all paint operations complete.
    paint_ref_count: u32 = 0,

    // Pointer is over the decorated surface's copy-content button.
    copy_button_hover: bool = false,
    // The left press landed on the copy button; only then does its release
    // copy (a press on the message text slid onto the button did not).
    copy_button_pressed: bool = false,
    // A copy just succeeded, so the button shows a checkmark instead of the
    // copy icon until TIMER_COPY_BUTTON_REVERT fires.
    copy_button_copied: bool = false,
    // Reads left for the pending copy click (TIMER_COPY_BUTTON_RETRY).
    copy_attempts_left: u8 = 0,
    // Pointer is over a message surface, reported to the core so it holds the
    // view's auto-hide countdown. Tracked here so an ordinary mouse move does
    // not take the core's grid lock on every WM_MOUSEMOVE.
    msg_hover: bool = false,

    // Scratch buffer for vertex copy during paint (avoids per-frame alloc).
    // Per-window to prevent re-entrancy corruption when DXGI Present pumps messages.
    paint_scratch: std.ArrayListUnmanaged(Vertex) = .empty,
    paint_row_ranges: std.ArrayListUnmanaged(PaintRowRange) = .empty,
    // Whether the last paint drew any root row, for atlasUploadOwesFullPaint.
    paint_drew_root_rows: bool = false,

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
        self.decorated_scratch.deinit(alloc);
        self.surf.surface.deinitCpuState(alloc);
        self.surf.paint.deinit(alloc, row_vb_budget);
        self.surf.tbs.deinit(alloc); // Handles slot release + pool deinit
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

/// The grid-local row a cursor's vertices sit on. Core cursor vertices are
/// grid-local pixels with y down.
pub fn cursorRowFromVerts(verts: []const Vertex, row_h_px: i32) u32 {
    if (verts.len == 0 or row_h_px <= 0) return 0;
    var min_y: f32 = verts[0].position[1];
    var max_y: f32 = min_y;
    for (verts[1..]) |v| {
        if (v.position[1] < min_y) min_y = v.position[1];
        if (v.position[1] > max_y) max_y = v.position[1];
    }
    const row_i: i32 = @intFromFloat(@floor(
        (min_y + max_y) * 0.5 / @as(f32, @floatFromInt(row_h_px)),
    ));
    return @intCast(@max(0, row_i));
}

/// Flatten a committed set into `scratch` for a surface drawn as one list
/// (decorated windows). The committed set, not the per-row
/// mirror the core thread writes one callback at a time: a paint landing
/// between two rows of a flush showed new and old rows together, and a
/// cancelled flush left its partial rows on screen until the resend.
/// `set` must be held by the paint (acquireForPaint).
pub fn snapshotSetRows(
    alloc: std.mem.Allocator,
    scratch: *std.ArrayListUnmanaged(Vertex),
    row_ranges: *std.ArrayListUnmanaged(PaintRowRange),
    set: *const VertexSet,
    pool: *const SlotPool,
) bool {
    scratch.clearRetainingCapacity();
    row_ranges.clearRetainingCapacity();
    scratch.ensureTotalCapacity(alloc, set.recomputeVertCount(pool)) catch return false;
    row_ranges.ensureTotalCapacity(alloc, set.row_map.items.len) catch return false;
    var start: usize = 0;
    for (set.row_map.items) |m| {
        if (m.slot == SLOT_NONE) continue;
        const verts = pool.slotPtrConst(m.slot).verts.items;
        if (verts.len == 0) continue;
        scratch.appendSliceAssumeCapacity(verts);
        row_ranges.appendAssumeCapacity(.{ .start = start, .count = verts.len });
        start += verts.len;
    }
    return true;
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
/// The vacated entries keep the scrolled-off rows' GPU buffers and only reset
/// their upload state.
pub fn shiftRowVBs(row_vbs: []RowVB, delta: i32, row_start: u32, row_end: u32) void {
    const end: usize = @min(@as(usize, @intCast(row_end)), row_vbs.len);
    if (delta == 0 or row_start >= end) return;
    const band = render_pipeline_helpers.rotateRegion(RowVB, row_vbs, row_start, end, delta);
    for (row_vbs[band.start..band.end]) |*vb| {
        vb.uploaded_slot = SLOT_NONE;
        vb.uploaded_ver = 0;
    }
}

/// Scroll state consumed by paint. Returned by applyScrollShift.
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
/// in GridSurfaceRenderer.draw().
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
///   last_cursor_on_root: That row is the root's; false leaves it untouched
///   row_h_px:            Row height in pixels
///   effective_rows:      Total valid row count
///   y_offset:            Content Y offset in back_tex pixels (e.g. tabbar height). 0 for ext windows.
pub fn applyScrollShift(
    g: *d3d11.Renderer,
    alloc: std.mem.Allocator,
    row_vbs: []RowVB,
    rows_to_draw: *std.ArrayListUnmanaged(u32),
    row_merge_scratch: *std.ArrayListUnmanaged(u32),
    scroll_rect: c.RECT,
    scroll_dy_px: i32,
    vb_shift_rows: i32,
    scroll_row_start: u32,
    scroll_row_end: u32,
    last_cursor_row_ptr: *?u32,
    last_cursor_on_root: bool,
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
    shiftRowVBs(row_vbs, vb_shift_rows, scroll_row_start, scroll_row_end);

    // 2. Cursor ghost erasure: add previous cursor row (shifted + original) to
    //    rows_to_draw. Only a row of the root is one: a cursor last painted in
    //    a hosted float names that float's row, which the root's shift did not
    //    move, and the layer plan still needs it to repaint the float.
    if (!last_cursor_on_root) {
        // Leave it for the layer plan.
    } else if (last_cursor_row_ptr.*) |prev_cr| {
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
    if (last_cursor_on_root) last_cursor_row_ptr.* = null;

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
                // rows_to_draw list in one pass to avoid repeated O(n) scans
                // from per-row sorted inserts.
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
/// This is the TBS row-mode draw path.
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
    /// Where this layer's top-left sits inside the viewport. Zero for a
    /// surface's root layer; an anchored float carries its own offset.
    layer_origin_x_px: f32,
    layer_origin_y_px: f32,
    /// See RowModeDrawParams.root_rows_may_be_empty.
    root_rows_may_be_empty: bool,
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
            if (root_rows_may_be_empty) {
                // Nothing was owed for this row: its content lives in a
                // layer drawn on top. Counting it as failed or skipped would
                // refuse the present and loop the paint forever.
                metrics.empty_rows += 1;
                continue;
            }
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
            // Overwrite the band with the background so stale pixels go and
            // the row's alpha is reset rather than compounded.
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
                g.drawClearRowOverwrite() catch {
                    metrics.skipped_empty += 1;
                    metrics.failed_rows += 1;
                    continue;
                };
                metrics.drawn_rows += 1;
            } else if (root_rows_may_be_empty) {
                // The seed path draws under a full-area scissor, so a per-row
                // clear is unavailable here; nothing was owed for this row
                // anyway, its content lives in a layer. Counting it as failed
                // refused every present and re-requested the seed forever.
                metrics.empty_rows += 1;
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
        // A translucent surface must not blend this row over its own previous
        // pixels: reset the band first so alpha does not compound across
        // redraws. With blur on, the core skips the root grid's default-bg
        // run entirely (flush.zig, skip_default_bg), so an opaque surface
        // needs the same overwrite or nothing repaints a vacated column.
        // (Only when a scissor limits the band to this row; the seed path
        // draws every row under a full-area scissor and a whole-surface
        // overwrite there would erase rows already drawn.)
        if ((g.opacity < 1.0 or g.blur_enabled) and rs_set_sc_fn != null) {
            g.drawClearRowOverwrite() catch {
                metrics.skipped_empty += 1;
                metrics.failed_rows += 1;
                continue;
            };
        }
        // Core row vertices are grid-local pixels against this viewport,
        // offset by where the layer sits inside it.
        g.setLayerTransform(layer_origin_x_px, layer_origin_y_px, base_vp.w, base_vp.h) catch {
            metrics.skipped_empty += 1;
            metrics.failed_rows += 1;
            continue;
        };
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
    const vp_width = rowModeViewportWidth(g, params);
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
        params.layer_origin_x_px,
        params.layer_origin_y_px,
        params.root_rows_may_be_empty,
        log_enabled,
        &result.metrics,
    );

    return result;
}

/// Detach one device-bound row buffer held by a grid drawn as a layer. These
/// live outside every SurfaceState because the grid can be drawn by whichever
/// surface places it, so device-loss recovery has to walk them separately or
/// the next paint maps a buffer created on the dead device.
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

/// The core's glow settings, read once per paint before the atlas reader
/// transaction: core calls stay outside it so atlas-reset admission never
/// waits on grid_mu from the paint path.
pub const GlowPaintSettings = struct { enabled: bool, intensity: f32, radius_scale: f32 };

pub fn glowPaintSettings(app: *App) GlowPaintSettings {
    const cp = app.corep orelse return .{ .enabled = false, .intensity = 0.8, .radius_scale = 1.0 };
    return .{
        .enabled = core.zonvie_core_get_glow_enabled(cp),
        .intensity = core.zonvie_core_get_glow_intensity(cp),
        .radius_scale = core.zonvie_core_get_glow_radius_scale(cp),
    };
}

/// The atlas generation a paint uploads against, read under the atlas's own
/// mutex (ensureGlyph bumps it from the core thread). `consume_reset` also
/// takes the pending-reset request, which only the main paint acts on (the
/// re-seed it drives is the main surface's).
pub fn atlasPaintGeneration(atlas: *dwrite_d2d.Renderer, consume_reset: bool) struct { generation: u64, reset: bool } {
    atlas.mu.lockUncancelable(core.clock.io());
    defer atlas.mu.unlock(core.clock.io());
    const reset = consume_reset and atlas.atlas_reset_pending;
    if (reset) atlas.atlas_reset_pending = false;
    return .{ .generation = atlas.atlas_reset_generation, .reset = reset };
}

pub const SharedAtlasSync = struct {
    ok: bool,
    /// New pixels reached the texture since this window's last paint.
    uploaded: bool,
};

/// Reposition the ext-float and mini windows after a window they may anchor
/// to moved or resized: with msg_pos `window` or `grid` that is the cursor's
/// window, main or external. A coalescing timer on the main window, so a drag
/// does not flood the queue (SetTimer resets a pending one of the same id).
pub fn scheduleFloatReposition(app: *App) void {
    if (app.hwnd) |main_hwnd| _ = c.SetTimer(main_hwnd, TIMER_REPOSITION_FLOATS, 15, null);
}

/// The work area of the monitor `hwnd` is on (the primary one's full screen
/// when there is none), so a box anchored to the display neither sits under
/// the taskbar nor lands on another monitor.
pub fn monitorWorkArea(hwnd: ?c.HWND) c.RECT {
    if (hwnd) |h| {
        var mi: c.MONITORINFO = undefined;
        mi.cbSize = @sizeOf(c.MONITORINFO);
        const monitor = c.MonitorFromWindow(h, c.MONITOR_DEFAULTTONEAREST);
        if (monitor != null and c.GetMonitorInfoW(monitor, &mi) != 0) return mi.rcWork;
    }
    return .{ .left = 0, .top = 0, .right = c.GetSystemMetrics(c.SM_CXSCREEN), .bottom = c.GetSystemMetrics(c.SM_CYSCREEN) };
}

/// Resize `g`'s swapchain to its window's client area before a paint draws.
/// Recreating it later -- inside drawEx or the present -- drops what was
/// already drawn into the old back texture while the present still treats the
/// new one as valid. True when it resized: every row must be redrawn. May pump
/// messages (DXGI). UI thread, caller holds g's context lock.
pub fn resizeSurfaceIfNeeded(g: *d3d11.Renderer, force: bool) !bool {
    if (!force) {
        var rc: c.RECT = undefined;
        _ = c.GetClientRect(g.hwnd, &rc);
        const cw: u32 = @intCast(@max(1, rc.right - rc.left));
        const ch: u32 = @intCast(@max(1, rc.bottom - rc.top));
        if (cw == g.width and ch == g.height) return false;
    }
    try g.resize();
    return true;
}

/// Bring the one atlas texture every window samples up to date and bind it to
/// `g`: resized to the atlas, then the uploads it is owed. It is the main
/// renderer's; an external renderer borrows it. Each window used to hold and
/// upload its own copy of the same pixels. `seen_seq` is the calling window's
/// record of the uploads it has seen, so it can tell a paint that drew no
/// root row that glyphs arrived (atlasUploadOwesFullPaint) whichever window
/// uploaded them. A failure owes a full upload and leaves `g` unbound; the
/// caller must not draw. UI thread, caller holds g's context lock.
pub fn syncSharedAtlas(
    app: *App,
    atlas: *dwrite_d2d.Renderer,
    g: *d3d11.Renderer,
    generation: u64,
    seen_seq: *u64,
) SharedAtlasSync {
    const failed: SharedAtlasSync = .{ .ok = false, .uploaded = false };
    const owner: *d3d11.Renderer = if (app.renderer) |*r| r else return failed;
    var w: u32 = 0;
    var h: u32 = 0;
    {
        atlas.mu.lockUncancelable(core.clock.io());
        defer atlas.mu.unlock(core.clock.io());
        w = atlas.atlas_w;
        h = atlas.atlas_h;
    }
    owner.recreateAtlasTextureIfNeeded(w, h) catch {
        app.atlas_upload.forceFull();
        return failed;
    };
    if (g != owner and !g.borrowAtlas(owner)) return failed;
    const need_full = app.atlas_upload.needsFull(generation);
    const upload = flushAtlasUploads(atlas, g, app.atlas_upload_cursor, need_full);
    if (!upload.success) {
        // A failed incremental upload is promoted to a full one: the cursor
        // it would retry can lie below what the atlas still queues.
        app.atlas_upload.forceFull();
        return failed;
    }
    if (need_full or upload.cursor != app.atlas_upload_cursor) app.atlas_upload_seq +%= 1;
    app.atlas_upload_cursor = upload.cursor;
    if (need_full) app.atlas_upload.fullUploaded(generation);
    const uploaded = seen_seq.* != app.atlas_upload_seq;
    seen_seq.* = app.atlas_upload_seq;
    return .{ .ok = true, .uploaded = uploaded };
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

/// Parameters for shared row-mode draw sequence (drawEx setup + drawSurfaceRowsVBFromSlots + bloom collect).
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
    /// Where the layer being drawn sits inside the viewport. Zero for a
    /// surface's root layer; an anchored float carries its own offset.
    layer_origin_x_px: f32 = 0,
    layer_origin_y_px: f32 = 0,
    /// The surface draws other grids as layers on top of this root grid, so
    /// a root row with no slot or no vertices is empty by design — the
    /// layers hold its content — and must not be counted as a failed or
    /// missing row by the present decision.
    root_rows_may_be_empty: bool = false,
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
    /// Root rows that are empty by design under a layered surface. Neither
    /// failed nor skipped: nothing was owed for them.
    empty_rows: u32 = 0,
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
/// Width of the viewport the row-mode pass draws into. Core row and cursor
/// vertices are grid-local pixels against this width, so the cursor overlay
/// has to build its layer transform from the same number the row pass used.
pub fn rowModeViewportWidth(g: *d3d11.Renderer, params: RowModeDrawParams) u32 {
    return render_pipeline_helpers.contentViewportWidthPx(
        params.content_width orelse g.width,
        params.content_x_offset orelse 0,
        params.sidebar_right_width orelse 0,
    );
}

/// How far a row-shift hint moved this slot's vertices from where they were
/// built. The layer draw, the cursor overlay and the bloom extract apply the
/// same offset.
fn slotRowShiftPx(slot: *const RowSlot, row_index: usize, row_h_px: i32) f32 {
    return @floatFromInt(
        (@as(i32, @intCast(row_index)) - @as(i32, @intCast(slot.origin_row))) * row_h_px,
    );
}

/// What a paint needs to read its layers: the rows of the committed set it
/// pinned, the damage it took with it, and its own paint state.
pub const LayerFrameSource = struct {
    set: *const VertexSet,
    pool: *const SlotPool,
    damage: []const LayerDamage,
    paint: *SurfacePaintState,
    alloc: std.mem.Allocator,
    budget: *RowVBPhysicalBudget,

    fn rows(self: LayerFrameSource, layer: SurfaceLayer) []const RowMapping {
        const lr = self.set.layerRows(layer.grid_id) orelse return &.{};
        return lr.row_map.items[0..@min(lr.row_map.items.len, @as(usize, layer.rows))];
    }

    fn damageFor(self: LayerFrameSource, grid_id: i64) ?*const LayerDamage {
        for (self.damage) |*d| {
            if (d.grid_id == grid_id) return d;
        }
        return null;
    }
};

/// What one paint's layer plan needs that does not live on `App`.
pub const LayerFramePlanParams = struct {
    x_offset: i32,
    y_offset: i32,
    content_right: i32,
    content_height: i32,
    row_h_px: i32,
    cell_w_px: i32,
    /// False whenever the root redraws whole, its paint_full (an atlas reset
    /// invalidates the layers' glyph UVs too) included.
    preserve_back: bool,
    cursor_grid: i64,
    last_cursor_row: ?u32,
    /// Rows of the cursor's grid the overlay would otherwise erase: where the
    /// previous cursor was baked into back_tex, and where this one lands.
    cursor_erase_rows: [2]?u32 = .{ null, null },
    /// The root grid's rows this paint redraws. The plan adds the root rows
    /// its bands reach, so it is sorted and unique on return as on entry.
    rows_to_draw: *std.ArrayListUnmanaged(u32),
    scroll_rows_merge_scratch: *std.ArrayListUnmanaged(u32),
    /// The root grid's row count.
    root_rows: u32,
    /// The rectangle the root's GPU scroll copied, in back_tex pixels, or null
    /// when the root did not shift. Every pixel inside it moved, including the
    /// layers drawn there, while the root only redraws the band it vacated.
    root_scroll_rect: ?c.RECT = null,
    log_enabled: bool,
};

/// Half-open, clamped to the set's length, so a caller working in layout rows
/// never has to know the bitset's size.
fn markDrawRows(state: *LayerPaintState, row_start: usize, row_end: usize) void {
    const end = @min(row_end, state.draw_rows.bit_length);
    const start = @min(row_start, end);
    if (start == end) return;
    state.draw_rows.setRangeValue(.{ .start = start, .end = end }, true);
}

/// No copy ran, so the whole scroll region still holds pre-scroll pixels: the
/// core vacated only the band, leaving the rest to a shift that did not happen.
fn refuseLayerBlit(
    state: *LayerPaintState,
    grid_id: i64,
    scroll: LayerScroll,
    origin_y_px: i32,
    tex_h: i32,
    row_h_px: i32,
    reason: []const u8,
    log_enabled: bool,
) void {
    if (log_enabled) applog.appLog(
        "[layer_blit_refused] gridId={d} reason={s}\n",
        .{ grid_id, reason },
    );
    const rows = core.row_scroll.dirtyRowsWithoutBlit(
        scroll.row_start,
        scroll.row_end,
        origin_y_px,
        tex_h,
        row_h_px,
    ) orelse return;
    markDrawRows(state, rows[0], rows[1]);
}

/// Whether this frame redraws `row` of layer `grid_id`, after planLayerFrame.
pub fn layerRowDrawn(paint: *SurfacePaintState, grid_id: i64, row: u32) bool {
    const state = paint.layerState(grid_id) orelse return false;
    if (state.draw_all) return true;
    return row < state.draw_rows.bit_length and state.draw_rows.isSet(row);
}

/// Decide which rows of every layer this paint draws, and shift on the GPU
/// the ones whose scroll a copy of their own rectangle can serve. Runs before
/// the root rows for the same reason applyScrollShift does: the copy has to
/// land before anything paints over the band it moves.
///
/// What the layers owe, the root's dirty rows and the cursor's rows become
/// the core's damage bands (damage_bands.zig), and every layer, the root
/// included, redraws the rows those bands reach. A band spans the whole
/// surface, so a lower layer's repaint reaches the layers over it without a
/// propagation of its own. The bands are left in `src.paint.bands` for the
/// present damage. `src.paint` must already hold a state for every layer
/// (syncLayers).
pub fn planLayerFrame(
    g: *d3d11.Renderer,
    src: LayerFrameSource,
    layers: []const SurfaceLayer,
    p: LayerFramePlanParams,
) error{OutOfMemory}!void {
    const paint = src.paint;
    paint.bands.clearRetainingCapacity();
    if (layers.len <= 1 or p.row_h_px <= 0) return;
    const n = layers.len;
    const h = p.row_h_px;

    // 1. Take the damage this paint consumed and settle the redraw decision.
    for (layers[1..n]) |layer| {
        const state = paint.layerState(layer.grid_id) orelse continue;
        const row_limit = src.rows(layer).len;
        var grow_failed = false;
        if (state.draw_rows.bit_length < row_limit) {
            state.draw_rows.resize(src.alloc, row_limit, false) catch {
                grow_failed = true;
            };
        }
        if (!resizeRowVBsForPaint(src.alloc, &state.row_vbs, src.budget, &paint.layer_row_vb_retained_bytes, row_limit))
            grow_failed = true;
        if (state.draw_rows.bit_length > 0) state.draw_rows.unsetAll();
        const dmg = src.damageFor(layer.grid_id);
        if (dmg) |d| {
            var it = d.rows.iterator(.{});
            while (it.next()) |r| {
                if (r >= state.draw_rows.bit_length) break;
                state.draw_rows.set(r);
            }
        }
        // A row count that moved invalidates last_drawn_rows' bookkeeping and
        // the blit's geometry alike, so it belongs with the other full-redraw
        // reasons rather than only in the refusal ladder.
        state.draw_all = grow_failed or !p.preserve_back or
            (dmg != null and dmg.?.full) or row_limit != state.last_drawn_rows;
        state.blit_clear_band = null;
        state.draw_scroll = if (dmg) |d| d.scroll else null;
        state.draw_blit_rect = null;
        // The row buffers follow the slots through the shift, so the rows
        // that only moved are not uploaded again.
        if (state.draw_scroll) |s| shiftRowVBs(state.row_vbs.items, s.rows_delta, s.row_start, s.row_end);
    }

    // 2. The refusal ladder, back-to-front. Order matters twice: a rung only
    //    runs once the cheaper ones passed, and an accepted copy is always the
    //    lowest in the stack, so the marking below it stays one-directional.
    const tex_h: i32 = @min(@as(i32, @intCast(g.height)), p.y_offset + p.content_height);
    for (layers[1..n], 1..) |layer, li| {
        const state = paint.layerState(layer.grid_id) orelse continue;
        const scroll = state.draw_scroll orelse continue;
        const origin_x: i32 = p.x_offset + layer.x_px;
        const origin_y: i32 = p.y_offset + layer.y_px;

        var plan: ?render_pipeline_helpers.RowScrollBlitPlan = null;
        const refusal: ?[]const u8 = ladder: {
            // Folds macOS's presented/resize/glow/opacity rungs: each of them
            // is a reason the pixels here are not a previous frame of this
            // rectangle, and each already clears preserve_back.
            if (!p.preserve_back) break :ladder "presented";
            if (layer.rows == 0 or layer.cols == 0) break :ladder "layout";
            if (scroll.total_rows != layer.rows or scroll.total_cols != layer.cols)
                break :ladder "size";
            const made = core.row_scroll.make(
                scroll.row_start,
                scroll.row_end,
                scroll.rows_delta,
                origin_x,
                origin_y,
                @as(i32, @intCast(layer.cols)) * p.cell_w_px,
                p.content_right,
                tex_h,
                h,
            ) orelse break :ladder "plan";
            plan = made;

            // A layer over an accepted copy would move pixels that copy just
            // moved, and repainting cannot undo the smear.
            const layer_rect: render_pipeline_helpers.BlitRectPx = .{
                .left = origin_x,
                .top = origin_y,
                .right = origin_x + @as(i32, @intCast(layer.cols)) * p.cell_w_px,
                .bottom = origin_y + @as(i32, @intCast(layer.rows)) * h,
            };
            for (layers[1..li]) |below| {
                const below_state = paint.layerState(below.grid_id) orelse continue;
                const r = below_state.draw_blit_rect orelse continue;
                if (render_pipeline_helpers.blitRectsIntersect(layer_rect, r))
                    break :ladder "overlap";
            }

            if (state.draw_all) break :ladder "drawall";

            const t0: i128 = if (p.log_enabled) core.clock.nowNs() else 0;
            // Positive dy moves content down, so it is the negation of the
            // core's rows_delta, which counts rows the content moved up.
            const ok = g.scrollBackTex(.{
                .left = origin_x,
                .top = origin_y + @as(i32, @intCast(scroll.row_start)) * h,
                .right = origin_x + made.copy_w_px,
                .bottom = origin_y + @as(i32, @intCast(made.clamped_row_end)) * h,
            }, -scroll.rows_delta * h);
            if (!ok) break :ladder "plan";
            if (p.log_enabled) {
                const us = @as(f64, @floatFromInt(core.clock.nowNs() - t0)) / 1000.0;
                applog.appLog(
                    "[layer_blit] gridId={d} rowStart={d} rowEnd={d} rowsDelta={d} us={d:.1}\n",
                    .{ layer.grid_id, scroll.row_start, made.clamped_row_end, scroll.rows_delta, us },
                );
            }
            break :ladder null;
        };

        if (refusal) |reason| {
            refuseLayerBlit(state, layer.grid_id, scroll, origin_y, tex_h, h, reason, p.log_enabled);
            continue;
        }

        const pl = plan.?;
        markDrawRows(state, pl.dirty_row_start, pl.dirty_row_end);
        const band = core.row_scroll.localClearBand(pl);
        state.blit_clear_band = .{ .top_px = band.top_px, .bottom_px = band.bottom_px };

        // The copy rewrote every pixel of its rectangle, so a layer drawn over
        // it moved with it, and so did what it covered.
        for (layers[li + 1 .. n]) |above| {
            const over = core.row_scroll.overBlitRows(
                pl,
                scroll.rows_delta,
                p.x_offset + above.x_px,
                p.y_offset + above.y_px,
                above.rows,
                above.cols,
                p.cell_w_px,
                h,
            ) orelse continue;
            if (over.above) |a| {
                if (paint.layerState(above.grid_id)) |above_state| {
                    markDrawRows(above_state, a[0], @as(usize, a[1]) + 1);
                }
            }
            if (over.under) |u| markDrawRows(state, u[0], @as(usize, u[1]) + 1);
            if (over.shifted) |s| markDrawRows(state, s[0], @as(usize, s[1]) + 1);
        }

        // Present ignores cursor_vb, so the cursor lives in back_tex and the
        // copy dragged it from its row to that row minus rows_delta. Redraw
        // both, as applyScrollShift does for the root grid; rows outside the
        // scrolled region were not copied and hold no ghost.
        if (p.cursor_grid == layer.grid_id) {
            if (p.last_cursor_row) |prev| {
                const first: i64 = scroll.row_start;
                const last: i64 = @as(i64, pl.clamped_row_end) - 1;
                const ghosts = [2]i64{ @as(i64, prev), @as(i64, prev) - scroll.rows_delta };
                for (ghosts) |row| {
                    if (row < first or row > last) continue;
                    markDrawRows(state, @intCast(row), @as(usize, @intCast(row)) + 1);
                }
            }
        }

        state.draw_blit_rect = core.row_scroll.blitRect(pl);
    }

    // 3. Everything owed, as surface pixel spans.
    const spans = &paint.damage_spans;
    spans.clearRetainingCapacity();
    const root = layers[0];
    try spans.ensureUnusedCapacity(src.alloc, p.rows_to_draw.items.len + 3);
    for (p.rows_to_draw.items) |row| {
        const top = root.y_px + @as(i32, @intCast(row)) * h;
        spans.appendAssumeCapacity(.{ .top_px = top, .bottom_px = top + h });
    }
    if (p.root_scroll_rect) |sr| spans.appendAssumeCapacity(.{ .top_px = sr.top - p.y_offset, .bottom_px = sr.bottom - p.y_offset });
    for (layers[1..n]) |layer| {
        const state = paint.layerState(layer.grid_id) orelse continue;
        const row_limit = src.rows(layer).len;
        if (row_limit == 0) continue;
        if (state.draw_all) {
            try spans.append(src.alloc, .{ .top_px = layer.y_px, .bottom_px = layer.y_px + @as(i32, @intCast(row_limit)) * h });
            continue;
        }
        var it = state.draw_rows.iterator(.{});
        while (it.next()) |ri| {
            if (ri >= row_limit) break;
            const top = layer.y_px + @as(i32, @intCast(ri)) * h;
            try spans.append(src.alloc, .{ .top_px = top, .bottom_px = top + h });
        }
        if (layer.grid_id == p.cursor_grid) {
            for (p.cursor_erase_rows) |maybe_row| {
                const r = maybe_row orelse continue;
                if (r >= row_limit) continue;
                const top = layer.y_px + @as(i32, @intCast(r)) * h;
                try spans.append(src.alloc, .{ .top_px = top, .bottom_px = top + h });
            }
        }
    }

    // 4. The bands, and every row they reach.
    try paint.bands.ensureTotalCapacity(src.alloc, @max(1, spans.items.len));
    paint.bands.items.len = core.damage_bands.bands(spans.items, h, p.content_height, paint.bands.allocatedSlice());
    for (paint.bands.items) |band| {
        for (layers[1..n]) |layer| {
            const state = paint.layerState(layer.grid_id) orelse continue;
            if (state.draw_all) continue;
            const rows = core.damage_bands.layerRowsForBand(band, layer.y_px, @intCast(src.rows(layer).len), h) orelse continue;
            markDrawRows(state, rows[0], @as(usize, rows[1]) + 1);
        }
        const root_rows = core.damage_bands.layerRowsForBand(band, root.y_px, p.root_rows, h) orelse continue;
        if (!render_pipeline_helpers.mergeSortedRowsWithRange(src.alloc, p.rows_to_draw, p.scroll_rows_merge_scratch, root_rows[0], root_rows[1] + 1))
            return error.OutOfMemory;
    }
}

/// Queue the bands this frame redraws as present damage, full content width.
/// `x_offset`/`y_offset` is where the surface's content sits in its client
/// area; `client_right`/`client_bottom` bound the rects. A rect that cannot be
/// queued makes the present full.
pub fn appendBandPresentRects(
    bands: []const core.damage_bands.Band,
    x_offset: i32,
    y_offset: i32,
    client_right: i32,
    client_bottom: i32,
    present: *PresentRectBuilder,
) void {
    for (bands) |band| present.add(.{
        .left = x_offset,
        .top = y_offset + band.top_px,
        .right = client_right,
        .bottom = @min(client_bottom, y_offset + band.bottom_px),
    });
}

/// A row frame refused for its vertex-buffer budget: the layer damage this
/// paint took is handed back whole, and the core is told the budget failed.
/// Unlike every other failure, this one does not requeue a full paint.
pub fn failRowVbBudget(app: *App, tbs: *TripleBufferedSurface, layers: []const SurfaceLayer) void {
    app.row_vb_budget_failed = true;
    tbs.returnLayerDamageFull(app.alloc, layers);
    if (app.corep) |corep| core.zonvie_core_fail_render_budget(corep);
}

/// What one layer row's draw produced: whether anything was encoded for it
/// (both arms count that for `[layer_draw]`), and whether a GPU step failed, so
/// the row never reached back_tex. A failure has to travel out to the paint,
/// exactly as a root row's does: this row's plan is about to be consumed.
const LayerRowOutcome = struct {
    encoded: bool,
    failed: bool = false,
    budget_exceeded: bool = false,
};

/// What a surface's whole layer draw produced. A frame with rows missing from
/// back_tex may not be presented.
pub const LayerDrawOutcome = struct {
    failed_rows: u32 = 0,
    /// Some of the failed rows were refused by the row VB budget.
    budget_exceeded: bool = false,

    pub fn incomplete(self: LayerDrawOutcome) bool {
        return self.failed_rows != 0;
    }
};

/// One layer row: scissor, background overwrite, upload, draw.
fn drawLayerRow(
    g: *d3d11.Renderer,
    src: LayerFrameSource,
    state: *LayerPaintState,
    rows: []const RowMapping,
    ri: usize,
    d: LayerRowDrawCtx,
) LayerRowOutcome {
    if (d.rs_set_sc_fn) |f| {
        const top = d.y_offset + d.layer.y_px + @as(i32, @intCast(ri)) * d.row_h_px;
        var sc: c.D3D11_RECT = .{
            .left = @max(d.x_offset, d.x_offset + d.layer.x_px),
            .top = top,
            .right = @min(d.content_right, d.x_offset + d.layer.x_px + d.layer_w_px),
            .bottom = top + d.row_h_px,
        };
        if (sc.right <= sc.left or sc.bottom <= sc.top) return .{ .encoded = false };
        f(d.ctx_ptr, 1, &sc);
    }

    const mapping = rows[ri];
    const verts_len: usize = if (mapping.slot != SLOT_NONE) src.pool.slotPtrConst(mapping.slot).verts.items.len else 0;

    // Reset this row's band to exactly (bg * opacity, opacity) before
    // drawing it. A translucent background blended over its own previous
    // output compounds toward opaque; the overwrite also erases whatever a
    // now-empty row used to show (a closed split's separator).
    // An opaque surface needs it for a row the core emptied, and with
    // blur on for every row: the core then skips the root grid's
    // default-bg run (flush.zig, skip_default_bg), so no other pass
    // repaints the columns this layer's row no longer covers.
    var encoded = false;
    if (g.opacity < 1.0 or g.blur_enabled or verts_len == 0) {
        g.drawClearRowOverwrite() catch return .{ .encoded = encoded, .failed = true };
        encoded = true;
    }
    if (verts_len == 0) return .{ .encoded = encoded };

    const rvb = &state.row_vbs.items[ri];
    _ = ensureRowVBReadyFromSlot(g, src.budget, &src.paint.layer_row_vb_retained_bytes, rvb, mapping, src.pool) catch |e|
        return .{ .encoded = encoded, .failed = true, .budget_exceeded = e == error.RowVBPhysicalBudgetExceeded };
    const vb = rvb.vb orelse return .{ .encoded = encoded, .failed = true };
    // A row-shift hint moves a slot between rows without rewriting its
    // pixels, so offset it by the distance it moved.
    const row_dy = slotRowShiftPx(src.pool.slotPtrConst(mapping.slot), ri, d.row_h_px);
    g.setLayerTransform(d.origin_x, d.origin_y + row_dy, d.base_vp.w, d.base_vp.h) catch
        return .{ .encoded = encoded, .failed = true };
    g.drawVB(vb, verts_len) catch
        return .{ .encoded = encoded, .failed = true };
    return .{ .encoded = true };
}

/// Everything drawLayerRow needs that is the same for every row of a layer.
const LayerRowDrawCtx = struct {
    layer: SurfaceLayer,
    layer_w_px: i32,
    origin_x: f32,
    origin_y: f32,
    base_vp: BaseViewport,
    x_offset: i32,
    y_offset: i32,
    content_right: i32,
    row_h_px: i32,
    ctx_ptr: ?*c.ID3D11DeviceContext,
    rs_set_sc_fn: ?RSSetScissorRectsFn,
};

/// Draw the surface's non-root layers, back-to-front, on top of the root grid.
/// Each layer gets its own pixel space and is clipped to its own rect. A layer
/// whose grid has no rows yet draws nothing, which is what the core's layout
/// contract requires. Reads only the pinned set and the UI thread's state, so
/// no lock is held.
///
/// The caller must refuse to present a frame the outcome calls incomplete.
pub fn drawSurfaceLayers(
    g: *d3d11.Renderer,
    src: LayerFrameSource,
    layers: []const SurfaceLayer,
    base_vp: BaseViewport,
    x_offset: i32,
    y_offset: i32,
    content_right: i32,
    row_h_px: i32,
    cell_w_px: i32,
    ctx_ptr: ?*c.ID3D11DeviceContext,
    rs_set_sc_fn: ?RSSetScissorRectsFn,
    log_enabled: bool,
) LayerDrawOutcome {
    if (layers.len <= 1 or row_h_px <= 0) return .{};
    var failed_rows: u32 = 0;
    var budget_exceeded = false;
    for (layers[1..]) |layer| {
        const state = src.paint.layerState(layer.grid_id) orelse continue;
        const rows = src.rows(layer);
        const row_limit = @min(rows.len, state.row_vbs.items.len);
        // The plan is spent whether or not this layer drew anything.
        defer {
            state.last_drawn_rows = rows.len;
            state.draw_all = false;
            if (state.draw_rows.bit_length > 0) state.draw_rows.unsetAll();
            state.blit_clear_band = null;
        }
        if (row_limit == 0) continue;

        const d = LayerRowDrawCtx{
            .layer = layer,
            .layer_w_px = @as(i32, @intCast(layer.cols)) * cell_w_px,
            .origin_x = @floatFromInt(layer.x_px),
            .origin_y = @floatFromInt(layer.y_px),
            .base_vp = base_vp,
            .x_offset = x_offset,
            .y_offset = y_offset,
            .content_right = content_right,
            .row_h_px = row_h_px,
            .ctx_ptr = ctx_ptr,
            .rs_set_sc_fn = rs_set_sc_fn,
        };

        var encoded: u32 = 0;
        var band_drawn = false;
        if (state.draw_all) {
            for (0..row_limit) |ri| {
                const out = drawLayerRow(g, src, state, rows, ri, d);
                if (out.encoded) encoded += 1;
                if (out.failed) failed_rows += 1;
                if (out.budget_exceeded) budget_exceeded = true;
            }
        } else {
            // The band this layer's GPU copy vacated, before the rows: the
            // plan's dirty rows cover it and have to land on top.
            if (state.blit_clear_band) |band| {
                if (rs_set_sc_fn) |f| {
                    var sc: c.D3D11_RECT = .{
                        .left = @max(x_offset, x_offset + layer.x_px),
                        .top = y_offset + layer.y_px + band.top_px,
                        .right = @min(content_right, x_offset + layer.x_px + d.layer_w_px),
                        .bottom = y_offset + layer.y_px + band.bottom_px,
                    };
                    if (sc.right > sc.left and sc.bottom > sc.top) {
                        f(ctx_ptr, 1, &sc);
                        if (g.drawClearRowOverwrite()) |_| {
                            band_drawn = true;
                        } else |_| {
                            failed_rows += 1;
                        }
                    }
                }
            }
            var it = state.draw_rows.iterator(.{});
            while (it.next()) |ri| {
                if (ri >= row_limit) break;
                const out = drawLayerRow(g, src, state, rows, ri, d);
                if (out.encoded) encoded += 1;
                if (out.failed) failed_rows += 1;
                if (out.budget_exceeded) budget_exceeded = true;
            }
        }
        if (log_enabled) applog.appLog(
            "[layer_draw] gridId={d} rows={d} of={d} blit={d} failed={d}\n",
            .{ layer.grid_id, encoded, row_limit, @as(u32, @intFromBool(band_drawn)), failed_rows },
        );
    }
    // Restore the surface's own pixel space for whatever draws next.
    g.setLayerTransform(0, 0, base_vp.w, base_vp.h) catch {
        failed_rows += 1;
    };
    return .{ .failed_rows = failed_rows, .budget_exceeded = budget_exceeded };
}

/// The cursor's row in its layer: the slot the pinned set maps it to, and the
/// layer's GPU buffer for that row.
pub const LayerCursorRow = struct {
    row: usize,
    mapping: RowMapping,
    rvb: *RowVB,
};

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
    content_width: u32,
    content_height: u32,
    row_h_px: i32,
    /// Where the cursor's own layer sits inside the surface. Zero when the
    /// cursor is on the surface's root grid.
    cursor_layer_origin_x_px: f32 = 0,
    cursor_layer_origin_y_px: f32 = 0,
    /// The width of the cursor's layer, which bounds the row scissor. Null
    /// when the cursor is on the surface's root grid.
    cursor_layer_w_px: ?i32 = null,
    /// The cursor's row in its own layer, when the cursor is not on the root
    /// grid. Blink-off redraws this instead of the root's (empty) row.
    cursor_layer_row: ?LayerCursorRow = null,
    /// What `cursor_layer_row`'s buffer is charged to.
    row_vb_budget: *RowVBPhysicalBudget,
    layer_row_vb_retained_bytes: *usize,
    ctx_ptr: ?*c.ID3D11DeviceContext,
    rs_set_sc_fn: ?RSSetScissorRectsFn,
    last_painted_cursor_row: *?u32,
    /// When true, clear the cursor row to bg and redraw its content before
    /// drawing the cursor. External windows use preserve_back and do not clear
    /// their back_tex per paint, so an in-place cursor shape/position change
    /// would stack the new overlay on top of the stale one (block + bar). The
    /// clear+redraw erases the old overlay even over empty (no-bg-quad) cells.
    /// The caller already redrew every row, including the cursor row, in this
    /// frame. In that case blink-on only needs the cursor quad and blink-off
    /// needs no work; clearing/redrawing again would double-blend transparent
    /// row content.
    row_already_redrawn: bool = false,
};

/// Redraw the content of the row the cursor sits on, so a cleared band gets
/// its text back. The cursor may belong to a layer, whose row lives in that
/// layer's own storage rather than the root's row set — under ext_multigrid
/// the root's row there is empty, so redrawing it would erase the text.
fn redrawCursorRowContent(
    g: *d3d11.Renderer,
    p: CursorOverlayParams,
    cursor_row: u32,
    cursor_ox: f32,
    cursor_oy: f32,
    layer_w: f32,
    layer_h: f32,
) !void {
    if (p.cursor_layer_row) |lr| {
        if (lr.mapping.slot == SLOT_NONE) return;
        const slot = p.pool.slotPtrConst(lr.mapping.slot);
        if (slot.verts.items.len == 0) return;
        _ = try ensureRowVBReadyFromSlot(g, p.row_vb_budget, p.layer_row_vb_retained_bytes, lr.rvb, lr.mapping, p.pool);
        const lvb = lr.rvb.vb orelse return error.CursorRowVertexBufferMissing;
        // Same offset drawSurfaceLayers applies: a shift hint moved these
        // vertices between rows without rewriting them.
        try g.setLayerTransform(cursor_ox, cursor_oy + slotRowShiftPx(slot, lr.row, p.row_h_px), layer_w, layer_h);
        try g.drawVB(lvb, slot.verts.items.len);
        return;
    }
    if (cursor_row >= p.row_vbs.len or cursor_row >= p.row_map.len) return;
    const rvb = &p.row_vbs[cursor_row];
    const mapping = p.row_map[cursor_row];
    const slot_verts_len: usize = if (mapping.slot != SLOT_NONE) p.pool.slotPtrConst(mapping.slot).verts.items.len else 0;
    if (rvb.vb) |row_vb| {
        if (slot_verts_len > 0) {
            // A scroll moves a row's pixels with a GPU copy and its buffer
            // with shiftRowVBs, leaving the vertices inside built for the row
            // they were generated at. The row draw pays for that by offsetting
            // the viewport (drawSurfaceRowsVBFromSlots), and the layer branch
            // above by cursor_layer_row_dy_px. This branch did not: under this
            // row's scissor the stale vertices landed nowhere, so the band the
            // erase above cleared stayed empty -- the whole row blank, but only
            // once something had scrolled.
            const origin_row: i32 = @intCast(p.pool.slotPtrConst(mapping.slot).origin_row);
            const row_dy: f32 = @floatFromInt((@as(i32, @intCast(cursor_row)) - origin_row) * p.row_h_px);
            try g.setLayerTransform(0, row_dy, layer_w, layer_h);
            try g.drawVB(row_vb, slot_verts_len);
        }
    } else if (slot_verts_len > 0) {
        return error.CursorRowVertexBufferMissing;
    }
}

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

    // 2. Resolve cursor row: use explicit value or compute from vertex
    // positions, which are grid-local pixels with y down.
    const cursor_row: u32 = p.cursor_row orelse cursorRowFromVerts(p.cursor_verts, p.row_h_px);

    // Core cursor and row vertices are grid-local pixels against the surface's
    // content extent. drawClearRow() pins the identity transform, so this is
    // re-applied before every core-vertex draw below. The cursor may belong to
    // a layer, whose own origin places it.
    const layer_w: f32 = @floatFromInt(p.content_width);
    const layer_h: f32 = @floatFromInt(p.content_height);
    const cursor_ox = p.cursor_layer_origin_x_px;
    const cursor_oy = p.cursor_layer_origin_y_px;

    // 3. Set scissor to cursor row. cursor_row is grid-local to the cursor's
    // layer, so the layer's own origin places it on the surface.
    // Bounded by the cursor's own layer: the blink-off erase below clears
    // the whole scissor, and a full-width one wiped a vertical-split
    // neighbour's row.
    const layer_top_px: i32 = @intFromFloat(@floor(cursor_oy));
    if (p.rs_set_sc_fn) |f| {
        var sc = render_pipeline_helpers.cursorRowScissor(
            c.D3D11_RECT,
            p.x_offset,
            p.y_offset,
            p.content_right,
            @intFromFloat(@floor(cursor_ox)),
            layer_top_px,
            p.cursor_layer_w_px,
            cursor_row,
            p.row_h_px,
        );
        // A layer with no columns on the surface shows no cursor.
        if (sc.right <= sc.left) {
            p.last_painted_cursor_row.* = null;
            return;
        }
        f(p.ctx_ptr, 1, &sc);
    }

    // 4. Erase the previous cursor overlay, then draw the new one.
    // Both drivers now claim the cursor's rows into the redraw set, so the
    // stale overlay is gone before this runs and the two branches left are the
    // whole policy: the row was already redrawn, or it was not and blink-off
    // has to redraw its content to erase the cursor.
    if (p.row_already_redrawn) {
        if (p.blink_visible) {
            if (log_enabled) applog.appLog("[cursor-overlay] row already redrawn, draw cursor row={d}\n", .{cursor_row});
            try g.setLayerTransform(cursor_ox, cursor_oy, layer_w, layer_h);
            try g.drawVB(vb, p.cursor_verts.len);
        } else if (log_enabled) {
            applog.appLog("[cursor-overlay] row already redrawn, blink off row={d}\n", .{cursor_row});
        }
    } else if (p.blink_visible) {
        if (log_enabled) applog.appLog("[cursor-overlay] draw cursor row={d} verts={d}\n", .{ cursor_row, p.cursor_verts.len });
        try g.setLayerTransform(cursor_ox, cursor_oy, layer_w, layer_h);
        try g.drawVB(vb, p.cursor_verts.len);
    } else {
        if (log_enabled) applog.appLog("[cursor-overlay] blink off, redraw row={d}\n", .{cursor_row});
        // The core represents a genuinely empty row with an empty vertex list.
        // Redrawing that list is a no-op, so first overwrite the scissored row
        // with the default background to erase the previously composited cursor.
        try g.drawClearRow();
        try redrawCursorRowContent(g, p, cursor_row, cursor_ox, cursor_oy, layer_w, layer_h);
    }

    // 5. Update tracking for scroll ghost erasure.
    if (p.blink_visible) {
        p.last_painted_cursor_row.* = cursor_row;
    } else {
        p.last_painted_cursor_row.* = null;
    }
}

/// A paint's retained-back damage, built the same way by both drivers:
/// reserved up front, row runs as spans, then single rects, clamped to the
/// back buffer and compacted. A rect that cannot be added makes the frame
/// present in full (`full`) rather than let a truncated list consume dirty
/// state. What an EMPTY list means is the present gate's question, not this.
pub const PresentRectBuilder = struct {
    list: *std.ArrayListUnmanaged(c.RECT),
    alloc: std.mem.Allocator,
    full: bool = false,

    pub fn begin(list: *std.ArrayListUnmanaged(c.RECT), alloc: std.mem.Allocator, capacity: usize) PresentRectBuilder {
        list.clearRetainingCapacity();
        var b: PresentRectBuilder = .{ .list = list, .alloc = alloc };
        list.ensureTotalCapacity(alloc, capacity) catch {
            b.full = true;
        };
        return b;
    }

    pub fn add(self: *PresentRectBuilder, rect: c.RECT) void {
        if (self.full) return;
        self.list.append(self.alloc, rect) catch {
            self.full = true;
        };
    }

    pub fn addOpt(self: *PresentRectBuilder, rect: ?c.RECT) void {
        if (rect) |r| self.add(r);
    }

    /// One span per run of consecutive rows (rowSpanRects).
    pub fn addRowSpans(self: *PresentRectBuilder, rows: []const u32, y_offset: i32, right: i32, row_h_px: i32) void {
        if (self.full or rows.len == 0) return;
        self.list.ensureUnusedCapacity(self.alloc, rows.len) catch {
            self.full = true;
            return;
        };
        self.list.items.len += render_pipeline_helpers.rowSpanRects(c.RECT, rows, y_offset, right, row_h_px, self.list.unusedCapacitySlice());
    }

    /// Drop what lies past the back buffer: a rect that clamps to EMPTY inside
    /// the presenter marks every swapchain buffer fully damaged
    /// (clampBackDamageRect), and producers name rows past it after a shrink.
    pub fn clamp(self: *PresentRectBuilder, width: u32, height: u32) void {
        if (self.list.items.len == 0) return;
        self.list.items.len = render_pipeline_helpers.clampPresentRects(c.RECT, self.list.items, @intCast(width), @intCast(height));
    }

    /// Clamp, then compact in place: O(n log n) sort plus a linear safe-union
    /// pass (an all-pairs scan reached O(rows^2) for alternating dirty rows).
    pub fn finish(self: *PresentRectBuilder, width: u32, height: u32) void {
        self.clamp(width, height);
        if (self.list.items.len > 1) {
            self.list.items.len = render_pipeline_helpers.compactDamageRects(c.RECT, self.list.items);
        }
    }
};

pub fn drawScrollbarOverlayOverUnderlay(
    g: *d3d11.Renderer,
    vb_ptr: *?*c.ID3D11Buffer,
    vb_bytes_ptr: *usize,
    scrollbar_verts: []const Vertex,
    track_rect: c.RECT,
) !?c.RECT {
    const captured_rect = (try g.captureScrollbarUnderlay(track_rect)) orelse return null;
    try drawScrollbarOverlay(g, vb_ptr, vb_bytes_ptr, scrollbar_verts);
    return captured_rect;
}

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
    // Scrollbar geometry is built in clip space by this frontend.
    try g.setLayerTransform(0, 0, 0, 0);
    try g.drawVB(vb, scrollbar_verts.len);
}

const BloomRowsContext = struct {
    row_map: []const RowMapping,
    pool: *const SlotPool,
    row_vbs: []const RowVB,
    row_h_px: i32,
    /// Non-root layers extracted after the root rows: the pinned set the
    /// frame drew them from, and the full layer list, root first.
    layers: []const SurfaceLayer = &.{},
    layer_src: ?LayerFrameSource = null,
    /// Cursor vertices are grid-local; drawBloomPasses draws them right after
    /// this callback with the transform it leaves bound.
    cursor_layer_origin: [2]f32 = .{ 0, 0 },
};

/// False when a transform could not be bound, so the extract is missing rows
/// and the frame may not be presented.
fn drawBloomRowBuffers(
    opaque_ctx: ?*const anyopaque,
    g: *d3d11.Renderer,
    d3d_ctx: *c.ID3D11DeviceContext,
    viewport_x: f32,
    viewport_y: f32,
    viewport_w: f32,
    viewport_h: f32,
) bool {
    const ctx: *const BloomRowsContext = @ptrCast(@alignCast(opaque_ctx orelse return true));
    const set_viewport = d3d_ctx.*.lpVtbl.*.RSSetViewports orelse return true;

    // The extract target is half resolution, so the viewport handed in is half
    // the surface's while core vertices stay in full-resolution surface pixels.
    // Binding the FULL-resolution extent against that half-size viewport is
    // what scales them down by 2 (NDC is viewport relative): a vertex at
    // surface pixel p lands at extract pixel viewport_origin + p / 2. Binding
    // the half extent instead would make the mapping one-to-one and push
    // everything past half the surface outside the extract target.
    const extent_w_px = viewport_w * 2.0;
    const extent_h_px = viewport_h * 2.0;

    for (ctx.row_map, 0..) |mapping, row_index| {
        if (row_index >= ctx.row_vbs.len or mapping.slot == SLOT_NONE) continue;
        const vb = ctx.row_vbs[row_index].vb orelse continue;
        const slot = ctx.pool.slotPtrConst(mapping.slot);
        if (slot.verts.items.len == 0) continue;

        const row_delta = @as(i32, @intCast(row_index)) - @as(i32, @intCast(slot.origin_row));
        var viewport: c.D3D11_VIEWPORT = .{
            .TopLeftX = viewport_x,
            // The shift is a full-resolution pixel distance, but the viewport
            // origin is in half-resolution extract pixels, hence the halving.
            .TopLeftY = viewport_y + @as(f32, @floatFromInt(row_delta * ctx.row_h_px)) / 2.0,
            .Width = viewport_w,
            .Height = viewport_h,
            .MinDepth = 0,
            .MaxDepth = 1,
        };
        set_viewport(d3d_ctx, 1, &viewport);
        // Core row vertices are grid-local pixels against this viewport.
        g.setLayerTransform(0, 0, extent_w_px, extent_h_px) catch return false;
        g.drawVB(vb, slot.verts.items.len) catch return false;
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

    // Non-root layers glow too: under ext_multigrid the root grid holds only
    // chrome, so extracting root rows alone leaves the whole buffer unlit.
    // Same rows, same row-shift offset as drawSurfaceLayers, with each
    // layer's origin carried by the layer transform instead of the viewport.
    if (ctx.layer_src) |src| {
        if (ctx.layers.len > 1) {
            for (ctx.layers[1..]) |layer| {
                const state = src.paint.layerState(layer.grid_id) orelse continue;
                const rows = src.rows(layer);
                const origin_x: f32 = @floatFromInt(layer.x_px);
                const origin_y: f32 = @floatFromInt(layer.y_px);
                // Pass 0 attenuates what the layers below already extracted by
                // this layer's background coverage, pass 1 adds this layer's
                // own light. Back to front over the layer list, which is the
                // screen order the extract pass otherwise has no way to honour.
                var pass: u8 = 0;
                while (pass < 2) : (pass += 1) {
                    if (!g.setBloomOccludePass(d3d_ctx, pass == 0)) continue;
                    for (rows, 0..) |mapping, ri| {
                        if (ri >= state.row_vbs.items.len or mapping.slot == SLOT_NONE) continue;
                        const slot = src.pool.slotPtrConst(mapping.slot);
                        if (slot.verts.items.len == 0) continue;
                        // Only a buffer holding this row's current vertices is
                        // safe to draw: the layer pass skips a row whose upload
                        // failed and leaves it behind.
                        const rvb = state.row_vbs.items[ri];
                        if (rvb.uploaded_slot != mapping.slot or rvb.uploaded_ver != slot.ver) continue;
                        const vb = rvb.vb orelse continue;
                        const row_dy = slotRowShiftPx(slot, ri, ctx.row_h_px);
                        g.setLayerTransform(origin_x, origin_y + row_dy, extent_w_px, extent_h_px) catch return false;
                        g.drawVB(vb, slot.verts.items.len) catch return false;
                    }
                }
            }
        }
    }
    // drawBloomPasses draws the cursor after this callback, in its layer's
    // space as the main pass does; it used to be left at the surface origin,
    // so a cursor in a split or float glowed away from where it was drawn.
    g.setLayerTransform(ctx.cursor_layer_origin[0], ctx.cursor_layer_origin[1], extent_w_px, extent_h_px) catch return false;
    return true;
}

/// Release the snapshot a paint took with `acquireForPaint`, once, from the
/// paint's `defer`. Returns whether the window has to be invalidated again
/// for dirty state that accumulated while it painted. A failed paint with an
/// armed retry wake defers that, or the release would defeat the backoff; a
/// successful atlas-reset transaction repaints every surface itself, and a
/// failed one intentionally keeps the previous frame frozen, so neither may
/// start a WM_PAINT loop here.
pub fn releasePaintSnapshot(
    tbs: *TripleBufferedSurface,
    snapshot: PaintSnapshot,
    retry: *const PaintRetryState,
    atlas_reset_active: bool,
) bool {
    var layers = snapshot.layers;
    layers.deinit();
    const needs_reinvalidate = tbs.releaseFromPaint(snapshot.committed_index, snapshot.cursor_index);
    return retry.shouldInvalidateAfterRelease(needs_reinvalidate) and !atlas_reset_active;
}

/// What every paint that produced no frame owes before it returns: the next
/// paint of this surface is a full one, and the retry clock advances. Returns
/// the wake to arm, if the retry state issued one.
///
/// A lost device gets no retry ticket: device recovery repaints every surface
/// when it completes, and a paint retry armed against a lost device only
/// fires into the recovery gate. The external driver used to arm one anyway;
/// the main driver never did.
///
/// `app.mu` must be free: the surface flag is taken under it, the TBS flag
/// under rotation_mu, never nested.
pub fn failSurfacePaint(
    app: *App,
    ws: *WindowSurface,
    device_lost: bool,
) ?PaintRetryState.Ticket {
    requestSurfaceFullPaint(app, ws);
    if (device_lost) return null;
    return ws.paint_retry.fail();
}

/// Make the next paint of `ws` a full one. `app.mu` must be free: the surface
/// flag is taken under it, the TBS flag under rotation_mu, never nested.
pub fn requestSurfaceFullPaint(app: *App, ws: *WindowSurface) void {
    app.mu.lockUncancelable(core.clock.io());
    ws.surface.paint_full = true;
    app.mu.unlock(core.clock.io());
    ws.tbs.requestFullPaint();
}

/// Make the main window's next paint a full one. `app.mu` held. The row-mode
/// damage list goes with it: a full paint covers every rect it held.
pub fn requestMainFullPaintLocked(app: *App) void {
    app.surf.surface.paint_full = true;
    app.paint_rects.clearRetainingCapacity();
}

/// requestMainFullPaintLocked under `app.mu`.
pub fn requestMainFullPaint(app: *App) void {
    app.mu.lockUncancelable(core.clock.io());
    defer app.mu.unlock(core.clock.io());
    requestMainFullPaintLocked(app);
}

/// What a surface owns across paints and lends to one row frame: its row VB
/// array (already sized for the committed row count), its cursor VB, and the
/// two facts the next paint reads back to place the remembered cursor row.
pub const RowFrameSurface = struct {
    row_vbs: []RowVB,
    row_vb_retained_bytes: *usize,
    layer_row_vb_retained_bytes: *usize,
    pool: *const SlotPool,
    cursor_vb: *?*c.ID3D11Buffer,
    cursor_vb_bytes: *usize,
    last_painted_cursor_row: *?u32,
    last_painted_cursor_grid: *i64,
};

pub const RowFrameGlow = struct {
    intensity: f32,
    radius_scale: f32,
    /// The cursor blooms only while it is drawn.
    cursor_visible: bool,
};

/// Everything one row frame needs that the caller settled before it: the
/// committed set, the redraw set, the cursor, and the viewport the rows are
/// drawn into.
pub const RowFrameInput = struct {
    /// The grid this surface's root layer draws; a cursor on it is placed by
    /// the root's transform, any other by its layer's.
    root_grid_id: i64,
    layers: []const SurfaceLayer,
    /// The pinned set's layer rows and their paint state. Null when the
    /// surface places no layers.
    layer_src: ?LayerFrameSource = null,
    row_map: []const RowMapping,
    rows_to_draw: []const u32,
    cursor_verts: []const Vertex,
    /// The row the cursor callback named, grid-local to `cursor_grid`. Null
    /// when the callback carried no cursor.
    cursor_row: ?u32,
    cursor_grid: i64,
    /// The rows the overlay would otherwise erase: where the previous cursor
    /// was baked into back_tex, and where this one lands. Both grid-local to
    /// the cursor's own grid.
    cursor_erase_rows: [2]?u32,
    cursor_layer_origin: [2]f32,
    blink_visible: bool,
    force_full_rows: bool,
    glow: ?RowFrameGlow,
    draw_params: RowModeDrawParams,
    log_enabled: bool,
};

pub const RowFrameOutcome = struct {
    rows: RowModeDrawResult = .{},
    layers: LayerDrawOutcome = .{},
    cursor_overlay_failed: bool = false,
    /// The bloom extract could not bind a transform, so the glow it
    /// composited is missing rows.
    bloom_failed: bool = false,
    /// The row pass hit the physical VB budget. Nothing after it ran, so the
    /// layer damage taken for the frame was never paid for; the caller hands
    /// it back and reports the budget to the core.
    row_vb_budget_exceeded: bool = false,

    /// A frame that must not be presented: rows missing from back_tex, a
    /// cursor that never landed, or a glow missing rows.
    pub fn incomplete(self: RowFrameOutcome) bool {
        return self.rows.metrics.failed_rows != 0 or self.layers.incomplete() or
            self.cursor_overlay_failed or self.bloom_failed;
    }
};

/// One surface's row frame, root rows to bloom, in the order both paint
/// drivers used to run it separately: root rows, hosted layers, cursor
/// overlay, bloom. Snapshot, present rectangles, Present, and the chrome
/// around the content stay with the caller.
///
/// Rules this frame settles once, where the two drivers used to differ:
/// - The cursor's row is the one its callback named (`cursor_row`), never
///   re-derived from the vertices' pixels.
/// - A cursor on the root grid counts as redrawn when both of its rows are in
///   `rows_to_draw`, layers or not. Both drivers put them there, and the
///   overlay's erase branch double-blends a row that was already redrawn.
/// - Any row-pass failure ends the frame before the layers and the cursor;
///   the outcome refuses the present and the caller re-arms.
/// - `last_painted_cursor_grid` is recorded whether or not the overlay
///   succeeded, so a blink-off frame cannot leave the pair naming different
///   paints.
///
/// Every row it draws comes from the set the paint pinned, so no lock is held.
pub fn drawSurfaceRowFrame(
    g: *d3d11.Renderer,
    app: *App,
    surface: RowFrameSurface,
    in: RowFrameInput,
) RowFrameOutcome {
    var out = RowFrameOutcome{};
    const log_enabled = in.log_enabled;
    const row_h_px = in.draw_params.row_h_px;
    const cell_w_px: i32 = @intCast(@max(1, app.cell_w_px));

    out.rows = drawRowModeSetupAndRowsFromSlots(
        g,
        &app.row_vb_budget,
        surface.row_vb_retained_bytes,
        in.row_map,
        surface.pool,
        surface.row_vbs,
        in.rows_to_draw,
        in.draw_params,
    ) catch |e| {
        out.row_vb_budget_exceeded = e == error.RowVBPhysicalBudgetExceeded;
        if (log_enabled) applog.appLog("drawRowModeSetupAndRowsFromSlots failed: {any}\n", .{e});
        out.rows.metrics.failed_rows = 1;
        return out;
    };
    if (out.rows.metrics.failed_rows != 0) return out;

    const cursor_on_root = in.cursor_grid == in.root_grid_id;

    // What row_already_redrawn promises drawCursorOverlay: this frame
    // repainted the cursor's OWN grid's row, so blink-on needs only the
    // cursor quad and blink-off needs nothing. planLayerFrame put a layer
    // cursor's rows into its bands; the root's went into rows_to_draw before
    // the frame. Read before drawSurfaceLayers' defer clears the plan.
    var cursor_row_redrawn = in.force_full_rows;
    if (!cursor_row_redrawn) {
        var claimed = true;
        for (in.cursor_erase_rows) |maybe_row| {
            const r = maybe_row orelse continue;
            if (cursor_on_root) {
                if (std.mem.indexOfScalar(u32, in.rows_to_draw, r) == null) claimed = false;
            } else if (in.layer_src) |src| {
                if (!layerRowDrawn(src.paint, in.cursor_grid, r)) claimed = false;
            } else claimed = false;
        }
        cursor_row_redrawn = claimed;
    }

    // Non-root layers on top of the root grid, before the cursor so the
    // cursor stays on top of everything.
    if (in.layer_src) |src| {
        out.layers = drawSurfaceLayers(
            g,
            src,
            in.layers,
            .{
                .x = @floatFromInt(in.draw_params.x_offset),
                .y = @floatFromInt(in.draw_params.y_offset),
                .w = @floatFromInt(rowModeViewportWidth(g, in.draw_params)),
                .h = @floatFromInt(in.draw_params.content_height),
            },
            in.draw_params.x_offset,
            in.draw_params.y_offset,
            in.draw_params.content_right,
            row_h_px,
            cell_w_px,
            out.rows.ctx_ptr,
            out.rows.rs_set_sc_fn,
            log_enabled,
        );
        if (out.layers.budget_exceeded) out.row_vb_budget_exceeded = true;
    }

    // The cursor's own row in its layer. Blink-off redraws this instead of
    // the root's row, which is empty under ext_multigrid.
    var cursor_layer_row: ?LayerCursorRow = null;
    var cursor_layer_w_px: ?i32 = null;
    if (!cursor_on_root) {
        for (in.layers) |layer| {
            if (layer.grid_id != in.cursor_grid) continue;
            cursor_layer_w_px = @as(i32, @intCast(layer.cols)) * cell_w_px;
            const row = in.cursor_row orelse break;
            const src = in.layer_src orelse break;
            const state = src.paint.layerState(layer.grid_id) orelse break;
            const rows = src.rows(layer);
            if (row < rows.len and row < state.row_vbs.items.len) {
                cursor_layer_row = .{ .row = row, .mapping = rows[row], .rvb = &state.row_vbs.items[row] };
            }
            break;
        }
    }

    drawCursorOverlay(g, .{
        .cursor_verts = in.cursor_verts,
        .cursor_row = in.cursor_row,
        .cursor_vb = surface.cursor_vb,
        .cursor_vb_bytes = surface.cursor_vb_bytes,
        .row_vbs = surface.row_vbs,
        .row_map = in.row_map,
        .pool = surface.pool,
        .blink_visible = in.blink_visible,
        .x_offset = in.draw_params.x_offset,
        .y_offset = in.draw_params.y_offset,
        .content_right = in.draw_params.content_right,
        .content_width = rowModeViewportWidth(g, in.draw_params),
        .content_height = in.draw_params.content_height,
        .row_h_px = row_h_px,
        .cursor_layer_origin_x_px = in.cursor_layer_origin[0],
        .cursor_layer_origin_y_px = in.cursor_layer_origin[1],
        .cursor_layer_w_px = cursor_layer_w_px,
        .cursor_layer_row = cursor_layer_row,
        .row_vb_budget = &app.row_vb_budget,
        .layer_row_vb_retained_bytes = surface.layer_row_vb_retained_bytes,
        .ctx_ptr = out.rows.ctx_ptr,
        .rs_set_sc_fn = out.rows.rs_set_sc_fn,
        .last_painted_cursor_row = surface.last_painted_cursor_row,
        .row_already_redrawn = cursor_row_redrawn,
    }) catch |e| {
        out.cursor_overlay_failed = true;
        if (e == error.RowVBPhysicalBudgetExceeded) out.row_vb_budget_exceeded = true;
        if (log_enabled) applog.appLog("drawCursorOverlay failed: {any}\n", .{e});
    };
    // Paired with the row drawCursorOverlay just recorded, so the next
    // paint can tell whether that row is one it can still place.
    surface.last_painted_cursor_grid.* = in.cursor_grid;

    if (in.glow) |glow| {
        const bloom_cursor = if (glow.cursor_visible) in.cursor_verts else &[_]Vertex{};
        // The blur reads this from the renderer rather than the call, so it
        // has to be current before the passes run.
        g.glow_radius_scale = glow.radius_scale;
        if (!drawBloomRowsOverlay(
            g,
            in.row_map,
            surface.pool,
            surface.row_vbs,
            in.layers,
            in.layer_src,
            bloom_cursor,
            glow.intensity,
            in.cursor_layer_origin,
            in.draw_params,
        )) out.bloom_failed = true;
    }
    return out;
}

/// What a surface owns across paints for its row pass: the row-frame state
/// plus the growable row VB list and the scratch the scroll shift uses.
pub const RowPassSurface = struct {
    pub fn of(ws: *WindowSurface) RowPassSurface {
        return .{ .tbs = &ws.tbs, .paint = &ws.paint };
    }

    tbs: *TripleBufferedSurface,
    paint: *SurfacePaintState,
};

/// Where the layer rectangles of this frame's present damage go, and what
/// bounds them.
pub const RowPassLayerPresent = struct {
    present: *PresentRectBuilder,
    right: i32,
    bottom: i32,
    /// Grid-local rows of the cursor's grid this frame redraws.
    cursor_grid: i64,
    cursor_rows: [2]?u32,
};

pub const RowPassInput = struct {
    snapshot: PaintSnapshot,
    rows_to_draw: *std.ArrayListUnmanaged(u32),
    /// Row VB slots the committed set needs.
    row_vb_len: usize,
    /// The root's row count the scroll shift and its layer reach clamp to.
    total_rows: u32,
    preserve_back: bool,
    cell_w_px: i32,
    layer_present: ?RowPassLayerPresent = null,
    /// The frame, minus what this pass settles: the redraw set and the layers.
    frame: RowFrameInput,
};

pub const RowPassOutcome = struct {
    frame: RowFrameOutcome,
    /// The rectangle the root's GPU scroll copied, or null.
    scroll_damage: ?c.RECT,
};

/// The row pass both paint drivers run, in one order: size the row VBs, shift
/// the root's retained pixels for a committed scroll, plan the layers, then
/// draw the row frame. Prologue, redraw set, present rects and Present stay
/// with the driver. OutOfMemory means nothing may be presented and the driver
/// requeues a full paint.
pub fn drawSurfaceRowPass(
    g: *d3d11.Renderer,
    app: *App,
    surface: RowPassSurface,
    in_: RowPassInput,
) error{OutOfMemory}!RowPassOutcome {
    var in = in_;
    const p = in.frame.draw_params;
    const rows_to_draw = in.rows_to_draw;
    const layers = in.snapshot.layers.slice();
    const has_layers = layers.len > 1;
    const paint = surface.paint;

    if (!resizeRowVBsForPaint(app.alloc, &paint.row_vbs, &app.row_vb_budget, &paint.row_vb_retained_bytes, in.row_vb_len))
        return error.OutOfMemory;
    try paint.syncLayers(app.alloc, &app.row_vb_budget, layers);

    var scroll_damage: ?c.RECT = null;
    if (in.preserve_back) {
        if (in.snapshot.scroll_rect) |sr| {
            const shift = applyScrollShift(
                g,
                app.alloc,
                paint.row_vbs.items,
                rows_to_draw,
                &paint.scroll_rows_merge_scratch,
                sr,
                in.snapshot.scroll_dy_px,
                in.snapshot.vb_shift,
                in.snapshot.scroll_row_start,
                in.snapshot.scroll_row_end,
                &paint.last_painted_cursor_row,
                paint.last_painted_cursor_grid == in.frame.root_grid_id,
                p.row_h_px,
                in.total_rows,
                p.y_offset,
            );
            if (!shift.rows_complete) return error.OutOfMemory;
            scroll_damage = shift.scroll_rect;

            // The copy moved every pixel of the region, a layer composited
            // into it included. The plan repaints each layer where it IS, but
            // the root rows its pixels were dragged ONTO belong to the root,
            // which only redraws the band the scroll vacated. Both directions,
            // at one band's cost, so a wrong sign cannot leave the ghost. A
            // root that never scrolls under its layers (the main surface's)
            // never reaches this.
            if (has_layers and p.row_h_px > 0 and in.snapshot.scroll_dy_px != 0) {
                const shift_rows: u32 = @intCast(@abs(@divTrunc(in.snapshot.scroll_dy_px, p.row_h_px)));
                for (layers[1..]) |layer| {
                    const span = render_pipeline_helpers.rootRowsLayerScrollReached(
                        layer.y_px,
                        layer.rows,
                        shift_rows,
                        p.row_h_px,
                        in.total_rows,
                    ) orelse continue;
                    if (!render_pipeline_helpers.mergeSortedRowsWithRange(
                        app.alloc,
                        rows_to_draw,
                        &paint.scroll_rows_merge_scratch,
                        span[0],
                        span[1],
                    )) return error.OutOfMemory;
                }
            }
        }
    } else {
        // A frame that redraws every row still applies the staged shift, or
        // the stale slot order carries into the next partial frame.
        shiftRowVBs(paint.row_vbs.items, in.snapshot.vb_shift, in.snapshot.scroll_row_start, in.snapshot.scroll_row_end);
    }

    // The copy has to land before the rows below paint over the band it
    // moves, and the plan before the draw.
    var layer_src: ?LayerFrameSource = null;
    if (has_layers) {
        const src: LayerFrameSource = .{
            .set = &surface.tbs.sets[in.snapshot.committed_index],
            .pool = &surface.tbs.pool,
            .damage = in.snapshot.layer_damage,
            .paint = paint,
            .alloc = app.alloc,
            .budget = &app.row_vb_budget,
        };
        layer_src = src;
        try planLayerFrame(g, src, layers, .{
            .x_offset = p.x_offset,
            .y_offset = p.y_offset,
            .content_right = p.content_right,
            .content_height = @intCast(p.content_height),
            .row_h_px = p.row_h_px,
            .cell_w_px = in.cell_w_px,
            .preserve_back = in.preserve_back,
            .cursor_grid = in.snapshot.cursor_layer_grid_id,
            .last_cursor_row = paint.last_painted_cursor_row,
            .cursor_erase_rows = in.frame.cursor_erase_rows,
            .rows_to_draw = rows_to_draw,
            .scroll_rows_merge_scratch = &paint.scroll_rows_merge_scratch,
            .root_rows = in.total_rows,
            .root_scroll_rect = scroll_damage,
            .log_enabled = in.frame.log_enabled,
        });
        if (in.layer_present) |lp| appendBandPresentRects(
            paint.bands.items,
            p.x_offset,
            p.y_offset,
            lp.right,
            lp.bottom,
            lp.present,
        );
    }

    in.frame.layers = layers;
    in.frame.layer_src = layer_src;
    in.frame.rows_to_draw = rows_to_draw.items;
    const frame = drawSurfaceRowFrame(g, app, .{
        .row_vbs = paint.row_vbs.items,
        .row_vb_retained_bytes = &paint.row_vb_retained_bytes,
        .layer_row_vb_retained_bytes = &paint.layer_row_vb_retained_bytes,
        .pool = &surface.tbs.pool,
        .cursor_vb = &paint.cursor_vb,
        .cursor_vb_bytes = &paint.cursor_vb_bytes,
        .last_painted_cursor_row = &paint.last_painted_cursor_row,
        .last_painted_cursor_grid = &paint.last_painted_cursor_grid,
    }, in.frame);
    return .{ .frame = frame, .scroll_damage = scroll_damage };
}

/// Row-mode bloom path that reuses the already-uploaded row VBs. This keeps
/// glow out of the per-paint heap and avoids copying every grid vertex.
/// False when the extract could not be drawn whole.
pub fn drawBloomRowsOverlay(
    g: *d3d11.Renderer,
    row_map: []const RowMapping,
    pool: *const SlotPool,
    row_vbs: []const RowVB,
    layers: []const SurfaceLayer,
    layer_src: ?LayerFrameSource,
    cursor_verts: []const Vertex,
    glow_intensity: f32,
    cursor_layer_origin: [2]f32,
    draw_params: RowModeDrawParams,
) bool {
    var has_rows = false;
    for (row_map, 0..) |mapping, row_index| {
        if (row_index >= row_vbs.len or mapping.slot == SLOT_NONE or row_vbs[row_index].vb == null) continue;
        if (pool.slotPtrConst(mapping.slot).verts.items.len != 0) {
            has_rows = true;
            break;
        }
    }
    // A root grid that only holds chrome has no rows here, but its layers do.
    if (!has_rows) {
        if (layer_src) |src| {
            if (layers.len > 1) layer_scan: for (layers[1..]) |layer| {
                for (src.rows(layer)) |m| {
                    if (m.slot != SLOT_NONE and pool.slotPtrConst(m.slot).verts.items.len != 0) {
                        has_rows = true;
                        break :layer_scan;
                    }
                }
            };
        }
    }
    if (!has_rows) return true;

    const rows_ctx = BloomRowsContext{
        .row_map = row_map,
        .pool = pool,
        .row_vbs = row_vbs,
        .row_h_px = draw_params.row_h_px,
        .layers = layers,
        .layer_src = layer_src,
        .cursor_layer_origin = cursor_layer_origin,
    };
    const bvp = draw_params.bloomViewport(g.width);
    return g.drawBloomFromRowBuffers(&rows_ctx, drawBloomRowBuffers, cursor_verts, glow_intensity, bvp.x, bvp.y, bvp.w, bvp.h);
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

    layout_budget: core.render_layout.Budget = .{},

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
    external_paint_retry_deadline_ms: u64 = 0,
    device_lost_retry_deadline_ms: u64 = 0,

    /// Where the next external window goes: a tab drag's drop point, or the
    /// origin the grid's window closed at. The rule is the core's.
    external_placement: core.frontend_rules.PlacementMemory = .{},
    /// Bumped on `restart` and `connect`: Neovim restarts grid ids per
    /// server, so a position saved under the previous one would move an
    /// unrelated window that reuses its id. macOS keeps the same generation.
    external_session_generation: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    // Pending vertices for external windows that haven't been created yet
    pending_external_verts: std.ArrayListUnmanaged(PendingExternalVertices) = .empty,

    // ext_messages window state
    message_window: ?MessageWindow = null,
    pending_messages: std.ArrayListUnmanaged(PendingMessageRequest) = .empty,
    display_messages: std.ArrayListUnmanaged(DisplayMessage) = .empty, // Stack of visible messages
    /// showmode / showcmd / ruler routed to ext_float, indexed by
    /// MiniWindowId. UI thread.
    status_messages: [3]?DisplayMessage = .{ null, null, null },

    // ext_tabline state
    tabline_state: TablineState = .{},

    // Mini view state (showmode/showcmd/ruler)
    mini_windows: [4]MiniWindowState = .{ .{}, .{}, .{}, .{} },

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

    // The main window's surface, the same type every external window keeps.
    // paint_full=false: main window uses explicit dirty tracking; external windows default to true.
    surf: WindowSurface = .{ .surface = .{ .paint_full = false } },
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
    // Shared by every surface's row buffers.
    row_vb_budget: RowVBPhysicalBudget = .{},
    row_vb_budget_failed: bool = false,
    /// WM_APP_TEST_FULL_REDRAW asked for a full repaint; the next successful
    /// main paint is it and logs `[trace] event=full_frame_done`. UI thread.
    test_full_redraw_armed: bool = false,
    // DXGI scroll state is now bundled in TBS (flush_scroll_* → pending_scroll_* → PaintSnapshot).
    // See TripleBufferedSurface.flush_scroll_rect / pending_scroll_rect / PaintSnapshot.scroll_rect.
    // Last cursor rectangle in client pixels (derived from cursor_verts).
    last_cursor_rect_px: ?c.RECT = null,

    // Scratch buffer for WM_PAINT(row): per-row vertex copy.
    // Reused to avoid per-paint alloc/free.
    row_tmp_verts: std.ArrayListUnmanaged(Vertex) = .empty,

    // WM_PAINT(row) persistent buffers (avoid per-frame alloc/free)
    wm_paint_rects_snapshot: std.ArrayListUnmanaged(c.RECT) = .empty,

    row_mode_max_row_end: u32 = 0,

    // ---- NEW: self-managed damage queue (avoid OS update region dependency) ----
    paint_rects: std.ArrayListUnmanaged(c.RECT) = .empty,

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
    // The one glyph atlas texture every window samples is the main
    // renderer's (syncSharedAtlas). What it last received in full, its cursor
    // into the atlas's pending_uploads, and a count of the uploads that
    // changed it. UI thread only: the core thread signals by bumping the
    // atlas's generation under its `mu`, which the paint reads.
    atlas_upload: render_pipeline_helpers.AtlasUploadLedger = .{},
    atlas_upload_cursor: u64 = 0,
    atlas_upload_seq: u64 = 0,

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
    /// The main renderer's shader clock and cursor, carried from the lost
    /// device to the renderer a recovery publishes. UI thread.
    device_lost_shader_carry: ?ShaderCarry = null,
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
    // hasPresentedOnce on GridSurfaceRenderer.
    back_tex_valid: bool = false,

    linespace_px: i32 = 0,

    // DPI scaling factor (e.g. 1.0 at 96 DPI, 2.0 at 192 DPI)
    dpi_scale: f32 = 1.0,

    // cell metrics used for layout->core_update_layout_px
    cell_w_px: u32 = 9,
    cell_h_px: u32 = 18,

    // Timestamp of last WM_SIZE (ns since epoch).
    last_resize_ns: i128 = 0,

    /// The user's *desired* main-window terminal content size, in pixels,
    /// that WM_APP_SNAP_MAIN_WINDOW snaps. Set from a genuine WM_SIZE (user
    /// drag, zoom, system resize) and left untouched by the snap's own
    /// resize echo, mirroring macOS's desiredTermPx (ZonvieCore.swift). Zero
    /// means unset (before the first WM_SIZE). UI thread only.
    desired_content_w_px: u32 = 0,
    desired_content_h_px: u32 = 0,
    /// Content size the last snap set the window to, so WM_SIZE can tell its
    /// own resize echo from a genuine user resize (mirrors lastSnappedTermPx).
    /// UI thread only.
    last_snapped_content_w_px: u32 = 0,
    last_snapped_content_h_px: u32 = 0,

    /// Which buttons' presses reached the editor, and the one drags are
    /// reported as (owner: 0 none, 1 left, 2 right, 3 middle, 4 x1, 5 x2).
    press_claim: core.frontend_rules.PressClaim = .{},
    /// The grid the press resolved to, held for the drag and release that
    /// follow it. Re-resolving per event would retarget a selection the
    /// moment the pointer leaves the float it started in. Zero means the
    /// press did not resolve to a layer and the surface's own grid stands.
    mouse_press_grid_id: i64 = 0,

    // Track last cursor grid to detect transitions from external windows
    last_cursor_grid: i64 = 1,
    /// The grid on_cursor_grid_changed last named, for dropping its repeats.
    core_reported_cursor_grid: i64 = 1,

    // Cursor blink state
    cursor_blink: core.frontend_rules.Blink = .{}, // .visible: the cursor is drawn
    cursor_blink_timer: c.UINT_PTR = 0, // Timer ID for blink

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
    // Scrollbar vertex buffer


    // ext_cmdline: current firstc character (':', '/', '?', etc.)
    cmdline_firstc: u8 = 0,

    // Cached cmdline UI colors (updated when highlights change, avoids core calls during paint)
    // Border uses Search highlight bg, icon uses Comment highlight fg
    cmdline_border_color: [3]f32 = .{ 1.0, 1.0, 0.0 }, // default yellow
    cmdline_icon_color: [3]f32 = .{ 0.5, 0.5, 0.5 }, // default gray

    // Cached highlight group bg colors for external window clear color.
    // Updated in updateExternalWindowColors (UI thread) to avoid grid_mu during WM_PAINT.
    // 0xFFFFFFFF = not set (fall back to colorscheme_bg).
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
    // A new default bg waiting for the flush commit, so the clear colour
    // changes together with the cells (0xFFFFFFFF = none).
    pending_colorscheme_bg: u32 = 0xFFFFFFFF,
    pending_colorscheme_fg: u32 = 0xFFFFFFFF,

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
    // Guards the fields below between the core thread and the UI handler. A
    // handler acts only while clipboard_active_seq still names its request,
    // so one that runs after its caller timed out touches nothing.
    clipboard_mu: std.Io.Mutex = .init,
    clipboard_seq: u32 = 0,
    clipboard_active_seq: u32 = 0,
    // Both directions' payload: a set copies into it before posting. Grown to
    // fit whatever the system clipboard holds. A fixed buffer here
    // truncated large pastes silently, and the core cannot recover what the
    // UI thread never fetched.
    clipboard_buf: []u8 = &.{},
    clipboard_len: usize = 0,
    clipboard_result: c_int = 0,


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
    // RegisterWindowMessageW("TaskbarCreated"): the shell broadcasts it after
    // Explorer restarts, which drops every notification icon. 0 = unregistered.
    taskbar_created_msg: c.UINT = 0,

    d3d_init_thread: ?std.Thread = null,
    // Set before teardown joins d3d_init_thread. The worker owns any device it
    // creates until it observes this flag and publishes into App.
    d3d_init_cancelled: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    pub const AtlasResetAdmission = render_pipeline_helpers.AtlasResetAdmission;

    /// Create the tray icon on first use, then register it. Never replaces an
    /// existing TrayIcon: a fresh one would reset `added` and its NIM_ADD for
    /// the same (hwnd, uID) would fail. Returns whether the icon is present.
    pub fn ensureTray(self: *App, hwnd: c.HWND) bool {
        if (self.tray_icon == null) self.tray_icon = TrayIcon.init(hwnd);
        return self.tray_icon.?.add();
    }

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

    /// `beginAtlasPaint` for a paint driver: a refused admission (an atlas
    /// reset is committing) leaves the surface owing a full paint, since the
    /// frame it would have drawn pairs old UVs with the new atlas. Both
    /// drivers open their paint with this; the caller still owns the
    /// `endAtlasPaint` defer and whatever it holds at the time.
    pub fn beginAtlasPaintOrRequestFull(self: *App, tbs: *TripleBufferedSurface) bool {
        if (self.beginAtlasPaint()) return true;
        tbs.requestFullPaint();
        return false;
    }

    /// Whether a WM_PAINT arriving now would re-enter a paint or another
    /// owner of the D3D immediate context on this thread: another WM_PAINT
    /// (g.lockContext() is a non-recursive mutex), the shader-animation
    /// timer mid-Present, glow prepare, device-lost recovery, or a resize /
    /// DPI change still holding `mu`. Any of their DXGI calls can pump the
    /// message queue and deliver WM_PAINT reentrantly. Both drivers ask this;
    /// the flush-retry and WM_SIZE gates add external-window creation to it.
    pub fn paintReentrancyBlocked(self: *const App) bool {
        return self.wm_paint_in_progress or
            self.in_present_shader_animation_frame or
            self.glow_prepare_in_progress or
            self.device_lost_recovering or
            self.main_resize_in_progress or
            self.main_dpi_change_in_progress;
    }

    /// Consume a WM_PAINT that `paintReentrancyBlocked` refused: BeginPaint /
    /// EndPaint so Windows stops re-issuing it, no rendering, and a follow-up
    /// paint of every window once the outer call finishes.
    pub fn consumeReentrantPaint(self: *App, hwnd: c.HWND) void {
        var ps_reentrant: c.PAINTSTRUCT = undefined;
        _ = c.BeginPaint(hwnd, &ps_reentrant);
        _ = c.EndPaint(hwnd, &ps_reentrant);
        self.wm_paint_reinvalidate_all = true;
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

        // Main surface CPU state (its row buffers live in surf.paint).
        self.surf.surface.deinitCpuState(self.alloc);

        // Triple-buffered surface cleanup (handles slot release + pool deinit)
        self.surf.tbs.deinit(self.alloc);
        self.surf.paint.deinit(self.alloc, &self.row_vb_budget);

        // WM_PAINT(row) scratch
        self.row_tmp_verts.deinit(self.alloc);
        self.wm_paint_rects_snapshot.deinit(self.alloc);
        self.row_valid.deinit(self.alloc);

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

/// The panel background rule (frontend_rules.panelBg), as macOS uses it.
pub const adjustBrightnessForCmdline = core.frontend_rules.panelBg;

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

/// Add the copy button's icon using SDF: two overlapping rounded squares, or
/// the acknowledgement checkmark for a moment after a successful copy. Both
/// share one inset box so they swap in place.
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
    copied: bool,
) usize {
    // Same margin percentage for both axes -> visually square on screen
    const margin = 0.16;
    const safe_x = x + w * margin;
    const safe_y = y - h * margin;
    const safe_w = w * (1.0 - 2.0 * margin);
    const safe_h = h * (1.0 - 2.0 * margin);

    var idx = start_idx;

    // uv.x = -6.0 (ICON_COPY) or -8.0 (ICON_CHECK), uv.y = local_x,
    // deco_phase = local_y
    const tex_marker: f32 = if (copied) -8.0 else -6.0;
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
            .texCoord = .{ tex_marker, luv[0] }, // uv.y = local_x
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

/// Get effective content width (subtracts scrollbar width in "always" mode).
///
/// `dpi_scale` is an argument because the two surfaces answer it differently:
/// the main window uses `app.dpi_scale`, an external one uses its own
/// `ext_win.dpi_scale`, which is also the scale its scrollbar is drawn at. The
/// rule itself is the same, and was applied on the main window only — an
/// external window drew a permanently visible scrollbar over its own rightmost
/// text column.
pub fn effectiveContentWidthAt(app: *App, client_width: u32, dpi_scale: f32) u32 {
    if (app.config.scrollbar.enabled and app.config.scrollbar.isAlways()) {
        const scrollbar_reserved: u32 = @intFromFloat(scrollbarReservedWidth(dpi_scale));
        if (client_width > scrollbar_reserved) {
            return client_width - scrollbar_reserved;
        }
    }
    return client_width;
}

pub fn getEffectiveContentWidth(app: *App, client_width: u32) u32 {
    return effectiveContentWidthAt(app, client_width, app.dpi_scale);
}

/// Terminal content area in pixels (client rect minus sidebar/scrollbar/tabbar chrome).
pub fn contentSizePx(hwnd: c.HWND, app: *App) struct { w: u32, h: u32 } {
    var rc: c.RECT = undefined;
    _ = c.GetClientRect(hwnd, &rc);

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

    // The DWM custom titlebar is inside the client area: the tab bar's rows
    // are not Neovim's.
    const tabbar_height: u32 = if (app.ext_tabline_enabled and app.tabline_style == .titlebar)
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

    // The cmdline's width budget goes in first so the flush the layout update
    // retries already sizes the cmdline with it.
    if (app.hwnd) |main_hwnd| {
        // Chrome that sits beside the cmdline grid inside its own window.
        const cmdline_chrome_w: u32 = @intCast(@max(0, external_windows.externalSurfaceInsetsPx(app, CMDLINE_GRID_ID, app.dpi_scale).w));

        var work_w: u32 = 0;
        if (c.MonitorFromWindow(main_hwnd, c.MONITOR_DEFAULTTONEAREST)) |mon| {
            var mi: c.MONITORINFO = std.mem.zeroes(c.MONITORINFO);
            mi.cbSize = @sizeOf(c.MONITORINFO);
            if (c.GetMonitorInfoW(mon, &mi) != 0) work_w = @intCast(@max(1, mi.rcWork.right - mi.rcWork.left));
        }
        var main_w: u32 = 0;
        var wr: c.RECT = undefined;
        if (c.GetWindowRect(main_hwnd, &wr) != 0) main_w = @intCast(@max(1, wr.right - wr.left));

        const budget = core.frontend_rules.cmdlineCols(work_w, main_w, cmdline_chrome_w, @intCast(@max(0, external_windows.cmdlineScreenMarginPx(app))), cw);
        if (budget.screen_cols != 0) core.zonvie_core_set_screen_cols(app.corep, budget.screen_cols);
        if (budget.default_cols != 0) core.zonvie_core_set_cmdline_default_cols(app.corep, budget.default_cols);
    }

    core.zonvie_core_update_layout_px(app.corep, w, h, cw, ch);
}

pub fn updateRowsColsFromClientForce(hwnd: c.HWND, app: *App) void {
    const content = contentSizePx(hwnd, app);
    const w = content.w;
    const h = content.h;

    const cw: u32 = @max(1, app.cell_w_px);
    const ch: u32 = app.rowHeightPx();

    const rows: u32 = @intCast(@max(1, h / ch));
    const cols: u32 = @intCast(@max(1, w / cw));

    if (rows != app.surf.surface.rows or cols != app.surf.surface.cols) {
        app.surf.surface.rows = rows;
        app.surf.surface.cols = cols;
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
        if (applog.isEnabled()) applog.appLog(
            "[win] bootstrap rows/cols from client rows={d} cols={d} cell={d}x{d} client={d}x{d} row_mode_max_row_end=0\n",
            .{ rows, cols, cw, ch, w, h },
        );
    }
}

test "writeFlushRow ignores a row past the write set and marks the one it writes" {
    const alloc = std.testing.allocator;
    var tbs = TripleBufferedSurface{};
    defer tbs.deinit(alloc);
    try std.testing.expect(tbs.beginFlush(alloc));
    const ws = tbs.writeSet();
    ws.rows = 2;
    try std.testing.expect(tbs.prepareRowSyncTracking(alloc, 2));

    try std.testing.expect(tbs.writeFlushRow(alloc, 5, &.{}));
    try std.testing.expect(ws.row_map.items.len <= 2);

    try std.testing.expect(tbs.writeFlushRow(alloc, 1, &.{}));
    try std.testing.expectEqual(@as(usize, 2), ws.row_map.items.len);
    try std.testing.expect(tbs.sparse_sync.flush_dirty.isSet(1));
    tbs.commitFlush(alloc);
}

/// Test helpers for layer rows living in a TripleBufferedSurface.
const LayerTestProbe = struct {
    fn marker(value: f32) Vertex {
        return .{
            .position = .{ value, value },
            .texCoord = .{ 0, 0 },
            .color = .{ 0, 0, 0, 1 },
            .grid_id = 1,
            .deco_flags = 0,
            .deco_phase = 0,
        };
    }

    /// Stage a root plus one layer per entry of `grids`, each `rows` tall,
    /// stacked at `y_px`.
    fn place(t: *TripleBufferedSurface, a: std.mem.Allocator, b: *core.render_layout.Budget, grids: []const i64, rows: u32, y_px: i32) !void {
        var staged = try t.prepareLayers(a, b, grids.len + 1);
        staged.items[0] = .{ .grid_id = 1, .anchor_grid = 0, .x_px = 0, .y_px = 0, .rows = 10, .cols = 8, .z = 0, .follows_scroll = false };
        for (grids, 1..) |grid, i| {
            staged.items[i] = .{ .grid_id = grid, .anchor_grid = 1, .x_px = 0, .y_px = y_px, .rows = rows, .cols = 8, .z = @intCast(i), .follows_scroll = false };
        }
        t.stageLayers(staged);
    }

    /// One layer row, written the way onVerticesRow writes it.
    fn writeLayer(t: *TripleBufferedSurface, a: std.mem.Allocator, grid: i64, row: u32, value: f32, total_rows: u32) !void {
        if (!t.is_in_flush) try std.testing.expect(t.beginFlush(a));
        try std.testing.expect(t.writeLayerRow(a, grid, row, &.{marker(value)}, total_rows));
    }

    /// What a layer draw reads out of one set: that row's first vertex.
    fn layerMarker(t: *TripleBufferedSurface, set_index: u8, grid: i64, row: usize) ?f32 {
        const lr = t.sets[set_index].layerRows(grid) orelse return null;
        if (row >= lr.row_map.items.len or lr.row_map.items[row].slot == SLOT_NONE) return null;
        const verts = t.pool.slotPtrConst(lr.row_map.items[row].slot).verts.items;
        if (verts.len == 0) return null;
        return verts[0].position[0];
    }

    fn unpin(t: *TripleBufferedSurface, snapshot: *PaintSnapshot) bool {
        snapshot.layers.deinit();
        return t.releaseFromPaint(snapshot.committed_index, snapshot.cursor_index);
    }

    fn damageFor(snapshot: PaintSnapshot, grid: i64) ?*const LayerDamage {
        for (snapshot.layer_damage) |*d| {
            if (d.grid_id == grid) return d;
        }
        return null;
    }
};

test "a paint reads the layer rows of the commit it pinned" {
    // I3: the layer rows rotate with the root's sets, so a commit landing
    // while a paint holds a set cannot change what that paint draws. The old
    // design republished layer rows in place and refused the frame instead.
    const alloc = std.testing.allocator;
    var budget = core.render_layout.Budget{};
    var tbs = TripleBufferedSurface{};
    defer tbs.deinit(alloc);

    try LayerTestProbe.place(&tbs, alloc, &budget, &.{2}, 3, 0);
    try LayerTestProbe.writeLayer(&tbs, alloc, 2, 0, 1.0, 3);
    tbs.commitFlush(alloc);

    var pinned = tbs.acquireForPaint(alloc);
    // Control: the pinned set holds the row this flush wrote.
    try std.testing.expectEqual(@as(?f32, 1.0), LayerTestProbe.layerMarker(&tbs, pinned.committed_index, 2, 0));

    // The next flush rewrites the same row and commits while the paint holds
    // its set.
    try LayerTestProbe.writeLayer(&tbs, alloc, 2, 0, 2.0, 3);
    tbs.commitFlush(alloc);
    try std.testing.expect(tbs.committed_index != pinned.committed_index);
    try std.testing.expectEqual(@as(?f32, 2.0), LayerTestProbe.layerMarker(&tbs, tbs.committed_index, 2, 0));
    try std.testing.expectEqual(@as(?f32, 1.0), LayerTestProbe.layerMarker(&tbs, pinned.committed_index, 2, 0));

    // The release asks for the paint that draws the newer commit.
    try std.testing.expect(LayerTestProbe.unpin(&tbs, &pinned));
    var fresh = tbs.acquireForPaint(alloc);
    defer _ = LayerTestProbe.unpin(&tbs, &fresh);
    try std.testing.expectEqual(@as(?f32, 2.0), LayerTestProbe.layerMarker(&tbs, fresh.committed_index, 2, 0));
    try std.testing.expect(LayerTestProbe.damageFor(fresh, 2).?.rows.isSet(0));
}

test "an aborted flush leaves the committed layer rows and their damage alone" {
    const alloc = std.testing.allocator;
    var budget = core.render_layout.Budget{};
    var tbs = TripleBufferedSurface{};
    defer tbs.deinit(alloc);

    try LayerTestProbe.place(&tbs, alloc, &budget, &.{2}, 3, 0);
    try LayerTestProbe.writeLayer(&tbs, alloc, 2, 0, 1.0, 3);
    tbs.commitFlush(alloc);
    {
        var drain = tbs.acquireForPaint(alloc);
        _ = LayerTestProbe.unpin(&tbs, &drain);
    }

    try LayerTestProbe.writeLayer(&tbs, alloc, 2, 1, 9.0, 3);
    tbs.cancelFlush();

    var pinned = tbs.acquireForPaint(alloc);
    try std.testing.expectEqual(@as(?f32, 1.0), LayerTestProbe.layerMarker(&tbs, pinned.committed_index, 2, 0));
    try std.testing.expectEqual(@as(?f32, null), LayerTestProbe.layerMarker(&tbs, pinned.committed_index, 2, 1));
    try std.testing.expectEqual(@as(usize, 0), pinned.layer_damage.len);
    // A paint still pinned would make the next acquire a nested one, which
    // carries no damage by design.
    _ = LayerTestProbe.unpin(&tbs, &pinned);

    // A later flush must not publish the cancelled row's damage either.
    try LayerTestProbe.writeLayer(&tbs, alloc, 2, 2, 3.0, 3);
    tbs.commitFlush(alloc);
    var next = tbs.acquireForPaint(alloc);
    defer _ = LayerTestProbe.unpin(&tbs, &next);
    const d = LayerTestProbe.damageFor(next, 2).?;
    try std.testing.expect(d.rows.isSet(2));
    try std.testing.expect(!d.rows.isSet(1));
}

test "a layer shift carries the pending damage with the rows" {
    const alloc = std.testing.allocator;
    var budget = core.render_layout.Budget{};
    var tbs = TripleBufferedSurface{};
    defer tbs.deinit(alloc);

    try LayerTestProbe.place(&tbs, alloc, &budget, &.{2}, 6, 0);
    for (0..6) |r| try LayerTestProbe.writeLayer(&tbs, alloc, 2, @intCast(r), @floatFromInt(r), 6);
    tbs.commitFlush(alloc);
    {
        var drain = tbs.acquireForPaint(alloc);
        _ = LayerTestProbe.unpin(&tbs, &drain);
    }

    // Row 3 changes and commits, but no paint takes it yet.
    try LayerTestProbe.writeLayer(&tbs, alloc, 2, 3, 30.0, 6);
    tbs.commitFlush(alloc);

    // Then the grid scrolls up one row; the core resends only the vacated row.
    try std.testing.expect(tbs.beginFlush(alloc));
    try std.testing.expect(tbs.shiftLayerRows(alloc, 2, .{ .row_start = 0, .row_end = 6, .rows_delta = 1, .total_rows = 6, .total_cols = 8 }));
    try LayerTestProbe.writeLayer(&tbs, alloc, 2, 5, 50.0, 6);
    tbs.commitFlush(alloc);

    var pinned = tbs.acquireForPaint(alloc);
    defer _ = LayerTestProbe.unpin(&tbs, &pinned);
    // The rows moved up one: what was row 3 is row 2 now.
    try std.testing.expectEqual(@as(?f32, 30.0), LayerTestProbe.layerMarker(&tbs, pinned.committed_index, 2, 2));
    try std.testing.expectEqual(@as(?f32, 50.0), LayerTestProbe.layerMarker(&tbs, pinned.committed_index, 2, 5));
    const d = LayerTestProbe.damageFor(pinned, 2).?;
    // Its damage went with it, the vacated row is owed, and the rest is a copy.
    try std.testing.expect(d.rows.isSet(2));
    try std.testing.expect(!d.rows.isSet(3));
    try std.testing.expect(d.rows.isSet(5));
    try std.testing.expect(!d.full);
    try std.testing.expectEqual(@as(i32, 1), d.scroll.?.rows_delta);
}

test "a commit merges layer damage whose recycled entries differ in length" {
    // Damage entries are recycled by position and only ever grow, so the
    // pending and flush entries for one grid can carry different bit lengths.
    const alloc = std.testing.allocator;
    var budget = core.render_layout.Budget{};
    var tbs = TripleBufferedSurface{};
    defer tbs.deinit(alloc);

    try LayerTestProbe.place(&tbs, alloc, &budget, &.{ 2, 3, 4 }, 6, 0);
    try LayerTestProbe.writeLayer(&tbs, alloc, 2, 0, 1.0, 6);
    tbs.commitFlush(alloc);
    try LayerTestProbe.writeLayer(&tbs, alloc, 3, 0, 1.0, 6);
    tbs.commitFlush(alloc);
    {
        var drain = tbs.acquireForPaint(alloc);
        _ = LayerTestProbe.unpin(&tbs, &drain);
    }

    // Grid 3 lands in a fresh 3-bit flush entry but a recycled 6-bit pending one.
    try LayerTestProbe.writeLayer(&tbs, alloc, 4, 0, 1.0, 6);
    try LayerTestProbe.writeLayer(&tbs, alloc, 3, 2, 2.0, 3);
    tbs.commitFlush(alloc);

    var pinned = tbs.acquireForPaint(alloc);
    defer _ = LayerTestProbe.unpin(&tbs, &pinned);
    try std.testing.expect(LayerTestProbe.damageFor(pinned, 3).?.rows.isSet(2));
    try std.testing.expect(LayerTestProbe.damageFor(pinned, 4).?.rows.isSet(0));
}

test "a layer the layout no longer places releases its rows at commit" {
    const alloc = std.testing.allocator;
    var budget = core.render_layout.Budget{};
    var tbs = TripleBufferedSurface{};
    defer tbs.deinit(alloc);

    try LayerTestProbe.place(&tbs, alloc, &budget, &.{ 2, 3 }, 2, 0);
    try LayerTestProbe.writeLayer(&tbs, alloc, 2, 0, 1.0, 2);
    try LayerTestProbe.writeLayer(&tbs, alloc, 3, 0, 1.0, 2);
    tbs.commitFlush(alloc);
    try std.testing.expect(tbs.sets[tbs.committed_index].layerRows(3) != null);

    try LayerTestProbe.place(&tbs, alloc, &budget, &.{2}, 2, 0);
    try LayerTestProbe.writeLayer(&tbs, alloc, 2, 1, 2.0, 2);
    tbs.commitFlush(alloc);
    const set = &tbs.sets[tbs.committed_index];
    try std.testing.expect(set.layerRows(2) != null);
    try std.testing.expect(set.layerRows(3) == null);
}

test "a layer that shrinks drops the rows past its height" {
    const alloc = std.testing.allocator;
    var budget = core.render_layout.Budget{};
    var tbs = TripleBufferedSurface{};
    defer tbs.deinit(alloc);

    try LayerTestProbe.place(&tbs, alloc, &budget, &.{2}, 3, 0);
    for (0..3) |r| try LayerTestProbe.writeLayer(&tbs, alloc, 2, @intCast(r), 1.0, 3);
    tbs.commitFlush(alloc);
    try std.testing.expectEqual(@as(usize, 3), tbs.sets[tbs.committed_index].layerRows(2).?.row_map.items.len);

    try LayerTestProbe.writeLayer(&tbs, alloc, 2, 0, 1.0, 1);
    tbs.commitFlush(alloc);
    try std.testing.expectEqual(@as(usize, 1), tbs.sets[tbs.committed_index].layerRows(2).?.row_map.items.len);
}

test "a layer that moves is redrawn whole" {
    const alloc = std.testing.allocator;
    var budget = core.render_layout.Budget{};
    var tbs = TripleBufferedSurface{};
    defer tbs.deinit(alloc);

    try LayerTestProbe.place(&tbs, alloc, &budget, &.{2}, 3, 0);
    try LayerTestProbe.writeLayer(&tbs, alloc, 2, 0, 1.0, 3);
    tbs.commitFlush(alloc);
    {
        var drain = tbs.acquireForPaint(alloc);
        _ = LayerTestProbe.unpin(&tbs, &drain);
    }

    // Control: the same placement again owes nothing.
    try LayerTestProbe.place(&tbs, alloc, &budget, &.{2}, 3, 0);
    tbs.commitFlush(alloc);
    {
        var same = tbs.acquireForPaint(alloc);
        defer _ = LayerTestProbe.unpin(&tbs, &same);
        try std.testing.expect(LayerTestProbe.damageFor(same, 2) == null);
    }

    try LayerTestProbe.place(&tbs, alloc, &budget, &.{2}, 3, 40);
    tbs.commitFlush(alloc);
    var moved = tbs.acquireForPaint(alloc);
    defer _ = LayerTestProbe.unpin(&tbs, &moved);
    try std.testing.expect(LayerTestProbe.damageFor(moved, 2).?.full);
}

/// A committed set holding `rows_each[i]` empty rows for grid `grids[i]`, and
/// a paint state that already drew them, for the plan tests below.
const LayerPlanFixture = struct {
    tbs: TripleBufferedSurface = .{},
    paint: SurfacePaintState = .{},
    budget: RowVBPhysicalBudget = .{},
    damage: LayerDamageList = .{},
    layout_budget_unused: core.render_layout.Budget = .{},

    fn init(self: *LayerPlanFixture, a: std.mem.Allocator, grids: []const i64, rows_each: []const u32, layers: []const SurfaceLayer) !void {
        try std.testing.expect(self.tbs.beginFlush(a));
        for (grids, rows_each) |grid, n| {
            for (0..n) |r| try std.testing.expect(self.tbs.writeLayerRow(a, grid, @intCast(r), &.{}, n));
        }
        // Commit without a layout: pruning keeps only what the committed
        // layout places, and these tests hand the layers to the plan directly.
        var staged = try self.tbs.prepareLayers(a, &self.layout_budget_unused, layers.len);
        @memcpy(staged.items[0..layers.len], layers);
        self.tbs.stageLayers(staged);
        self.tbs.commitFlush(a);
        try self.paint.syncLayers(a, &self.budget, layers);
        for (grids, rows_each) |grid, n| self.paint.layerState(grid).?.last_drawn_rows = n;
    }

    fn src(self: *LayerPlanFixture, a: std.mem.Allocator) LayerFrameSource {
        return .{
            .set = &self.tbs.sets[self.tbs.committed_index],
            .pool = &self.tbs.pool,
            .damage = self.damage.slice(),
            .paint = &self.paint,
            .alloc = a,
            .budget = &self.budget,
        };
    }

    fn deinit(self: *LayerPlanFixture, a: std.mem.Allocator) void {
        self.paint.deinit(a, &self.budget);
        self.damage.deinit(a);
        self.tbs.deinit(a);
    }
};

/// Run planLayerFrame over `fx` the way drawSurfaceRowPass does, with a root
/// that owes nothing of its own.
fn planForTest(
    fx: *LayerPlanFixture,
    a: std.mem.Allocator,
    layers: []const SurfaceLayer,
    row_h_px: i32,
    cell_w_px: i32,
    cursor_grid: i64,
    cursor_erase_rows: [2]?u32,
    rows_to_draw: *std.ArrayListUnmanaged(u32),
    scratch: *std.ArrayListUnmanaged(u32),
) !void {
    var g: d3d11.Renderer = undefined;
    g.height = 1000;
    try planLayerFrame(&g, fx.src(a), layers, .{
        .x_offset = 0,
        .y_offset = 0,
        .content_right = 400,
        .content_height = @intCast(layers[0].rows * @as(u32, @intCast(row_h_px))),
        .row_h_px = row_h_px,
        .cell_w_px = cell_w_px,
        .preserve_back = true,
        .cursor_grid = cursor_grid,
        .last_cursor_row = null,
        .cursor_erase_rows = cursor_erase_rows,
        .rows_to_draw = rows_to_draw,
        .scroll_rows_merge_scratch = scratch,
        .root_rows = layers[0].rows,
        .log_enabled = false,
    });
}

test "a layer's cursor row is repainted over the layers above it" {
    // A float sits over the rows the cursor's own grid owns. Repainting the
    // cursor's row rewrites the whole row rectangle, float pixels included, so
    // the float has to redraw those rows too, or it keeps the hole until
    // something else redraws it.
    const alloc = std.testing.allocator;
    const row_h_px: i32 = 10;
    const cell_w_px: i32 = 8;

    const layers = [_]SurfaceLayer{
        .{ .grid_id = 1, .anchor_grid = 0, .x_px = 0, .y_px = 0, .rows = 10, .cols = 20, .z = 0, .follows_scroll = false },
        .{ .grid_id = 2, .anchor_grid = 1, .x_px = 0, .y_px = 0, .rows = 10, .cols = 20, .z = 1, .follows_scroll = false },
        .{ .grid_id = 3, .anchor_grid = 1, .x_px = 0, .y_px = 6 * row_h_px, .rows = 2, .cols = 10, .z = 2, .follows_scroll = false },
    };
    var fx = LayerPlanFixture{};
    defer fx.deinit(alloc);
    try fx.init(alloc, &.{ 2, 3 }, &.{ 10, 2 }, &layers);
    var rows_to_draw: std.ArrayListUnmanaged(u32) = .empty;
    defer rows_to_draw.deinit(alloc);
    var scratch: std.ArrayListUnmanaged(u32) = .empty;
    defer scratch.deinit(alloc);

    // Control: with the cursor far from the float, the float owes nothing.
    try planForTest(&fx, alloc, &layers, row_h_px, cell_w_px, 2, .{ 1, null }, &rows_to_draw, &scratch);
    try std.testing.expect(layerRowDrawn(&fx.paint, 2, 1));
    try std.testing.expect(!layerRowDrawn(&fx.paint, 3, 0));
    try std.testing.expect(!fx.paint.layerState(3).?.draw_all);

    // The cursor on row 6 of the lower layer, which is the float's row 0.
    rows_to_draw.clearRetainingCapacity();
    try planForTest(&fx, alloc, &layers, row_h_px, cell_w_px, 2, .{ 6, null }, &rows_to_draw, &scratch);
    try std.testing.expect(layerRowDrawn(&fx.paint, 2, 6));
    try std.testing.expect(layerRowDrawn(&fx.paint, 3, 0));
}

test "a layer's cursor row reaches a float that only overlaps the float above it" {
    // Columns, with the cursor's own grid at the bottom:
    //   A (cursor)  0..80
    //   B          40..120   overlaps A
    //   C          90..110   over B, overlapping B only
    // B repaints its whole row rectangle, so C loses its pixels to B even
    // though C never touches A. A band spans the whole surface, so C is in it.
    const alloc = std.testing.allocator;
    const row_h_px: i32 = 10;
    const cell_w_px: i32 = 10;

    const layers = [_]SurfaceLayer{
        .{ .grid_id = 1, .anchor_grid = 0, .x_px = 0, .y_px = 0, .rows = 10, .cols = 12, .z = 0, .follows_scroll = false },
        .{ .grid_id = 2, .anchor_grid = 1, .x_px = 0, .y_px = 0, .rows = 10, .cols = 8, .z = 1, .follows_scroll = false },
        .{ .grid_id = 3, .anchor_grid = 1, .x_px = 40, .y_px = 6 * row_h_px, .rows = 2, .cols = 8, .z = 2, .follows_scroll = false },
        .{ .grid_id = 4, .anchor_grid = 1, .x_px = 90, .y_px = 6 * row_h_px, .rows = 2, .cols = 2, .z = 3, .follows_scroll = false },
    };
    var fx = LayerPlanFixture{};
    defer fx.deinit(alloc);
    try fx.init(alloc, &.{ 2, 3, 4 }, &.{ 10, 2, 2 }, &layers);
    var rows_to_draw: std.ArrayListUnmanaged(u32) = .empty;
    defer rows_to_draw.deinit(alloc);
    var scratch: std.ArrayListUnmanaged(u32) = .empty;
    defer scratch.deinit(alloc);

    // Control: nothing owes a row before the cursor claims one.
    try planForTest(&fx, alloc, &layers, row_h_px, cell_w_px, 2, .{ null, null }, &rows_to_draw, &scratch);
    for ([_]i64{ 2, 3, 4 }) |grid| {
        const st = fx.paint.layerState(grid).?;
        try std.testing.expect(!st.draw_all);
        try std.testing.expect(st.draw_rows.count() == 0);
    }

    try planForTest(&fx, alloc, &layers, row_h_px, cell_w_px, 2, .{ 6, null }, &rows_to_draw, &scratch);
    // B is directly over the cursor's row; C is only over B.
    try std.testing.expect(layerRowDrawn(&fx.paint, 3, 0));
    try std.testing.expect(layerRowDrawn(&fx.paint, 4, 0));
}

test "a band redraws the root rows and layer rows one row past its edges" {
    // The bands are the damage widened by a row each way, and each layer
    // draws the rows meeting the band widened by one more: ink a row outside
    // spills in is drawn too.
    const alloc = std.testing.allocator;
    const row_h_px: i32 = 10;

    const layers = [_]SurfaceLayer{
        .{ .grid_id = 1, .anchor_grid = 0, .x_px = 0, .y_px = 0, .rows = 20, .cols = 20, .z = 0, .follows_scroll = false },
        .{ .grid_id = 2, .anchor_grid = 1, .x_px = 0, .y_px = 0, .rows = 20, .cols = 20, .z = 1, .follows_scroll = false },
    };
    var fx = LayerPlanFixture{};
    defer fx.deinit(alloc);
    try fx.init(alloc, &.{2}, &.{20}, &layers);
    (fx.damage.getOrAdd(alloc, 2, 20) orelse return error.OutOfMemory).rows.set(10);
    var rows_to_draw: std.ArrayListUnmanaged(u32) = .empty;
    defer rows_to_draw.deinit(alloc);
    var scratch: std.ArrayListUnmanaged(u32) = .empty;
    defer scratch.deinit(alloc);

    try planForTest(&fx, alloc, &layers, row_h_px, 8, 1, .{ null, null }, &rows_to_draw, &scratch);
    // One band: row 10 widened to rows 9..11.
    try std.testing.expectEqual(@as(usize, 1), fx.paint.bands.items.len);
    try std.testing.expectEqual(core.damage_bands.Band{ .top_px = 90, .bottom_px = 120 }, fx.paint.bands.items[0]);
    // Each draws rows 8..12.
    try std.testing.expectEqualSlices(u32, &.{ 8, 9, 10, 11, 12 }, rows_to_draw.items);
    for (0..20) |r| {
        try std.testing.expectEqual(r >= 8 and r <= 12, layerRowDrawn(&fx.paint, 2, @intCast(r)));
    }
}

test {
    // input.zig's pure helpers (the colon/semicolon swap) run with this suite.
    _ = @import("input.zig");
    // Message placement rules and the status/confirm stack rules.
    _ = @import("ui/messages.zig");
    _ = @import("ui/scrollbar.zig");
    // The tab drag threshold rule shared by the titlebar and the sidebar.
    _ = @import("ui/tabbar.zig");
    // DirectWrite shaping with [font] family features (skips without the font).
    _ = @import("renderer/dwrite_d2d_renderer.zig");
}
