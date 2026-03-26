const std = @import("std");
const app_mod = @import("app.zig");
const App = app_mod.App;
const core = @import("zonvie_core");
const d3d11 = app_mod.d3d11;
const dwrite_d2d = app_mod.dwrite_d2d;
const c = app_mod.c;
const applog = app_mod.applog;
const builtin = @import("builtin");
const config_mod = app_mod.config_mod;

// Sub-module imports
const callbacks = @import("callbacks.zig");
const tabline_mod = @import("ui/tabbar.zig");
const messages = @import("ui/messages.zig");
const external_windows = @import("ui/external_windows.zig");
const scrollbar = @import("ui/scrollbar.zig");
const input = @import("input.zig");
const dialogs = @import("ui/dialogs.zig");

// Load a system cursor by integer resource ID (avoids MAKEINTRESOURCE alignment issues with odd values)
fn loadSystemCursor(id: usize) c.HCURSOR {
    const RawLoadCursorFn = *const fn (?*anyopaque, usize) callconv(.winapi) ?*anyopaque;
    const load_fn: RawLoadCursorFn = @ptrCast(&c.LoadCursorW);
    return @ptrCast(@alignCast(load_fn(null, id)));
}

// Type aliases from app_mod (to minimize changes in WndProc)
const ExternalWindow = app_mod.ExternalWindow;
const RowVerts = app_mod.RowVerts;
const PendingExternalWindow = app_mod.PendingExternalWindow;
const PendingExternalVertices = app_mod.PendingExternalVertices;
const PendingGlyph = app_mod.PendingGlyph;
const TablineState = app_mod.TablineState;
const TabEntry = app_mod.TabEntry;
const BufferEntry = app_mod.BufferEntry;
const MiniWindowId = app_mod.MiniWindowId;
const MiniWindowState = app_mod.MiniWindowState;
const MessageWindow = app_mod.MessageWindow;
const TrayIcon = app_mod.TrayIcon;
const PendingMessageRequest = app_mod.PendingMessageRequest;
const DisplayMessage = app_mod.DisplayMessage;
const ScrollbarGeometry = app_mod.ScrollbarGeometry;

// Function aliases from app_mod
const getApp = app_mod.getApp;
const setApp = app_mod.setApp;

// WM_APP_* message constants
const WM_APP_ATLAS_ENSURE_GLYPH = app_mod.WM_APP_ATLAS_ENSURE_GLYPH;
const WM_APP_CREATE_EXTERNAL_WINDOW = app_mod.WM_APP_CREATE_EXTERNAL_WINDOW;
const WM_APP_CURSOR_GRID_CHANGED = app_mod.WM_APP_CURSOR_GRID_CHANGED;
const WM_APP_CLOSE_EXTERNAL_WINDOW = app_mod.WM_APP_CLOSE_EXTERNAL_WINDOW;
const WM_APP_DEFERRED_INIT = app_mod.WM_APP_DEFERRED_INIT;
const WM_APP_UPDATE_IME_POSITION = app_mod.WM_APP_UPDATE_IME_POSITION;
const WM_APP_MSG_SHOW = app_mod.WM_APP_MSG_SHOW;
const WM_APP_MSG_CLEAR = app_mod.WM_APP_MSG_CLEAR;
const WM_APP_MINI_UPDATE = app_mod.WM_APP_MINI_UPDATE;
const WM_APP_CLIPBOARD_GET = app_mod.WM_APP_CLIPBOARD_GET;
const WM_APP_CLIPBOARD_SET = app_mod.WM_APP_CLIPBOARD_SET;
const WM_APP_SSH_AUTH_PROMPT = app_mod.WM_APP_SSH_AUTH_PROMPT;
const WM_APP_UPDATE_SCROLLBAR = app_mod.WM_APP_UPDATE_SCROLLBAR;
const WM_APP_UPDATE_EXT_FLOAT_POS = app_mod.WM_APP_UPDATE_EXT_FLOAT_POS;
const WM_APP_TRAY = app_mod.WM_APP_TRAY;
const WM_APP_UPDATE_CURSOR_BLINK = app_mod.WM_APP_UPDATE_CURSOR_BLINK;
const WM_APP_IME_OFF = app_mod.WM_APP_IME_OFF;
const WM_APP_TABLINE_INVALIDATE = app_mod.WM_APP_TABLINE_INVALIDATE;
const WM_APP_QUIT_REQUESTED = app_mod.WM_APP_QUIT_REQUESTED;
const WM_APP_QUIT_TIMEOUT = app_mod.WM_APP_QUIT_TIMEOUT;
const WM_APP_RESIZE_POPUPMENU = app_mod.WM_APP_RESIZE_POPUPMENU;
const WM_APP_UPDATE_CMDLINE_COLORS = app_mod.WM_APP_UPDATE_CMDLINE_COLORS;
const WM_APP_SET_TITLE = app_mod.WM_APP_SET_TITLE;
const WM_APP_DEFERRED_WIN_POS = app_mod.WM_APP_DEFERRED_WIN_POS;
const WM_APP_SHOW_WINDOW = app_mod.WM_APP_SHOW_WINDOW;
const WM_APP_SWP_FRAMECHANGED = app_mod.WM_APP_SWP_FRAMECHANGED;
const WM_APP_POST_SHOW_INIT = app_mod.WM_APP_POST_SHOW_INIT;

// Timer and timing constants
const TIMER_MSG_AUTOHIDE = app_mod.TIMER_MSG_AUTOHIDE;
const TIMER_MINI_AUTOHIDE = app_mod.TIMER_MINI_AUTOHIDE;
const MSG_AUTOHIDE_TIMEOUT = app_mod.MSG_AUTOHIDE_TIMEOUT;
const TIMER_DEVCONTAINER_POLL = app_mod.TIMER_DEVCONTAINER_POLL;
const DEVCONTAINER_POLL_INTERVAL = app_mod.DEVCONTAINER_POLL_INTERVAL;
const TIMER_SCROLLBAR_AUTOHIDE = app_mod.TIMER_SCROLLBAR_AUTOHIDE;
const TIMER_SCROLLBAR_FADE = app_mod.TIMER_SCROLLBAR_FADE;
const TIMER_SCROLLBAR_REPEAT = app_mod.TIMER_SCROLLBAR_REPEAT;
const TIMER_CURSOR_BLINK = app_mod.TIMER_CURSOR_BLINK;
const TIMER_QUIT_TIMEOUT = app_mod.TIMER_QUIT_TIMEOUT;
const TIMER_REPOSITION_FLOATS = app_mod.TIMER_REPOSITION_FLOATS;
const TIMER_TRAY_INIT = app_mod.TIMER_TRAY_INIT;
const TRAY_INIT_DELAY_MS = app_mod.TRAY_INIT_DELAY_MS;
const QUIT_TIMEOUT_MS = app_mod.QUIT_TIMEOUT_MS;
const SCROLLBAR_FADE_INTERVAL = app_mod.SCROLLBAR_FADE_INTERVAL;
const SCROLLBAR_REPEAT_DELAY = app_mod.SCROLLBAR_REPEAT_DELAY;
const SCROLLBAR_REPEAT_INTERVAL = app_mod.SCROLLBAR_REPEAT_INTERVAL;

// Win32 DPI API (Windows 10 v1607+)
extern "user32" fn GetDpiForWindow(hwnd: c.HWND) callconv(.winapi) c.UINT;

// Grid ID constants
const CMDLINE_GRID_ID = app_mod.CMDLINE_GRID_ID;
const POPUPMENU_GRID_ID = app_mod.POPUPMENU_GRID_ID;
const MESSAGE_GRID_ID = app_mod.MESSAGE_GRID_ID;
const MSG_HISTORY_GRID_ID = app_mod.MSG_HISTORY_GRID_ID;

// Styling constants
const CMDLINE_PADDING = app_mod.CMDLINE_PADDING;
const CMDLINE_ICON_SIZE = app_mod.CMDLINE_ICON_SIZE;
const CMDLINE_ICON_MARGIN_LEFT = app_mod.CMDLINE_ICON_MARGIN_LEFT;
const CMDLINE_ICON_MARGIN_RIGHT = app_mod.CMDLINE_ICON_MARGIN_RIGHT;
const CMDLINE_BORDER_WIDTH = app_mod.CMDLINE_BORDER_WIDTH;
const CMDLINE_CORNER_RADIUS = app_mod.CMDLINE_CORNER_RADIUS;
const MSG_PADDING = app_mod.MSG_PADDING;

// Layout helpers are in app_mod (getEffectiveContentWidth, updateLayoutToCore,
// rowHeightPxFromClient, updateRowsColsFromClientForce).
const getEffectiveContentWidth = app_mod.getEffectiveContentWidth;
const updateLayoutToCore = app_mod.updateLayoutToCore;
const rowHeightPxFromClient = app_mod.rowHeightPxFromClient;
const updateRowsColsFromClientForce = app_mod.updateRowsColsFromClientForce;

fn updateRowsColsFromClient(hwnd: c.HWND, app: *App) void {
    // Only use client-derived rows/cols as a bootstrap before core provides them.
    if (app.surface.rows != 0 or app.surface.cols != 0) {
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

// =========================================================================
// Helper: build core.Callbacks struct (shared between WM_CREATE and DEFERRED_INIT)
// =========================================================================
fn makeCoreCbs() core.Callbacks {
    return .{
        .on_vertices_partial = callbacks.onVerticesPartial,
        .on_vertices_row = callbacks.onVerticesRow,
        .on_atlas_ensure_glyph = callbacks.onAtlasEnsureGlyph,
        .on_atlas_ensure_glyph_styled = callbacks.onAtlasEnsureGlyphStyled,
        .on_log = callbacks.onLog,
        .on_guifont = callbacks.onGuiFont,
        .on_linespace = callbacks.onLineSpace,
        .on_exit = callbacks.onExit,
        .on_default_colors_set = callbacks.onDefaultColorsSet,
        .on_set_title = callbacks.onSetTitle,
        .on_external_window = external_windows.onExternalWindow,
        .on_external_window_close = external_windows.onExternalWindowClose,
        .on_cursor_grid_changed = external_windows.onCursorGridChanged,
        .on_cmdline_show = callbacks.onCmdlineShow,
        .on_cmdline_hide = callbacks.onCmdlineHide,
        .on_msg_show = messages.onMsgShow,
        .on_msg_clear = messages.onMsgClear,
        .on_msg_showmode = messages.onMsgShowmode,
        .on_msg_showcmd = messages.onMsgShowcmd,
        .on_msg_ruler = messages.onMsgRuler,
        .on_msg_history_show = messages.onMsgHistoryShow,
        .on_tabline_update = tabline_mod.onTablineUpdate,
        .on_tabline_hide = tabline_mod.onTablineHide,
        .on_clipboard_get = callbacks.onClipboardGet,
        .on_clipboard_set = callbacks.onClipboardSet,
        .on_ssh_auth_prompt = callbacks.onSSHAuthPrompt,
        .on_ime_off = callbacks.onIMEOff,
        .on_quit_requested = callbacks.onQuitRequested,
        .on_rasterize_glyph = callbacks.onRasterizeGlyph,
        .on_atlas_upload = callbacks.onAtlasUpload,
        .on_atlas_create = callbacks.onAtlasCreate,
        .on_win_move = external_windows.onWinMove,
        .on_win_exchange = external_windows.onWinExchange,
        .on_win_rotate = external_windows.onWinRotate,
        .on_win_resize_equal = external_windows.onWinResizeEqual,
        .on_win_move_cursor = external_windows.onWinMoveCursor,
        .on_shape_text_run = callbacks.onShapeTextRun,
        .on_rasterize_glyph_by_id = callbacks.onRasterizeGlyphById,
        .on_get_ascii_table = callbacks.onGetAsciiTable,
        .on_flush_begin = callbacks.onFlushBegin,
        .on_flush_end = callbacks.onFlushEnd,
        .on_main_row_scroll = callbacks.onMainRowScroll,
        .on_grid_row_scroll = callbacks.onGridRowScroll,
    };
}

// =========================================================================
// Helper: D3D11 device creation on a separate thread
// =========================================================================
fn d3dInitThreadFn(app: *App) void {
    const result = d3d11.Renderer.createDeviceOnly() catch return;
    app.d3d_device = result.device;
    app.d3d_ctx = result.ctx;
    if (applog.isEnabled()) applog.appLog("[win] d3d_init_thread: device ready\n", .{});
}

// =========================================================================
// Helper: build native-mode nvim command string
// =========================================================================
fn buildNativeNvimCmd(app: *App, buf: []u8) []const u8 {
    const effective_nvim = app.cli_nvim_path orelse app.config.neovim.path;
    if (app.nvim_extra_args.items.len == 0) return effective_nvim;
    var fbs = std.io.fixedBufferStream(buf);
    const writer = fbs.writer();
    const needs_quote = std.mem.indexOfScalar(u8, effective_nvim, ' ') != null;
    if (needs_quote) writer.writeByte('\'') catch {};
    writer.writeAll(effective_nvim) catch {};
    if (needs_quote) writer.writeByte('\'') catch {};
    for (app.nvim_extra_args.items) |arg| {
        writer.writeByte(' ') catch {};
        if (std.mem.indexOfScalar(u8, arg, ' ') != null) {
            writer.writeByte('"') catch {};
            writer.writeAll(arg) catch {};
            writer.writeByte('"') catch {};
        } else {
            writer.writeAll(arg) catch {};
        }
    }
    return buf[0..fbs.pos];
}

// =========================================================================
// doEarlyCoreInit: called from WM_CREATE for native mode only
// Creates core, loads config, inits DWrite metrics, spawns nvim, and
// kicks off D3D11 device creation on a separate thread.
// =========================================================================
fn doEarlyCoreInit(hwnd: c.HWND, app: *App) !void {
    const log_enabled = applog.isEnabled();
    var t1: c.LARGE_INTEGER = undefined;
    var t2: c.LARGE_INTEGER = undefined;

    // 1. Create core with callbacks
    var cb = makeCoreCbs();
    if (log_enabled) _ = c.QueryPerformanceCounter(&t1);
    app.corep = core.zonvie_core_create(&cb, @sizeOf(core.Callbacks), app);
    if (log_enabled) {
        _ = c.QueryPerformanceCounter(&t2);
        const ms = @divTrunc((t2.QuadPart - t1.QuadPart) * 1000, app_mod.g_startup_freq.QuadPart);
        applog.appLog("[win] doEarlyCoreInit: core_create {d}ms\n", .{ms});
    }

    // 2. Load config into core
    if (config_mod.getConfigFilePath(app.alloc)) |config_path| {
        defer app.alloc.free(config_path);
        const config_path_z = app.alloc.dupeZ(u8, config_path) catch null;
        if (config_path_z) |cpath| {
            defer app.alloc.free(cpath);
            _ = core.zonvie_core_load_config(app.corep, cpath.ptr);
        }
    } else |_| {}

    // 3. Set log/ext flags
    setLogEnabledViaCore(app, app.config.log.enabled);
    if (app.ext_cmdline_enabled) core.zonvie_core_set_ext_cmdline(app.corep, 1);
    if (app.config.popup.external) core.zonvie_core_set_ext_popupmenu(app.corep, 1);
    if (app.ext_messages_enabled) core.zonvie_core_set_ext_messages(app.corep, 1);
    if (app.ext_tabline_enabled) core.zonvie_core_set_ext_tabline(app.corep, 1);
    if (app.ext_windows_enabled) core.zonvie_core_set_ext_windows(app.corep, 1);
    core.zonvie_core_set_background_opacity(app.corep, app.config.window.opacity);
    core.zonvie_core_set_glyph_cache_size(
        app.corep,
        app.config.performance.glyph_cache_ascii_size,
        app.config.performance.glyph_cache_non_ascii_size,
    );
    core.zonvie_core_set_atlas_size(app.corep, app.config.performance.atlas_size);

    // 4. DWrite metrics init (font metrics calculation) -> store in early_atlas
    const initial_font = if (app.config.font.family.len > 0) app.config.font.family else "Consolas";
    const initial_pt: f32 = if (app.config.font.size > 0.0) app.config.font.size else 14.0;

    if (log_enabled) _ = c.QueryPerformanceCounter(&t1);
    var atlas_val = try dwrite_d2d.Renderer.initMetrics(app.alloc, hwnd, initial_font, initial_pt);
    if (log_enabled) {
        _ = c.QueryPerformanceCounter(&t2);
        const ms = @divTrunc((t2.QuadPart - t1.QuadPart) * 1000, app_mod.g_startup_freq.QuadPart);
        applog.appLog("[win] doEarlyCoreInit: initMetrics {d}ms\n", .{ms});
    }

    app.dpi_scale = @as(f32, @floatFromInt(atlas_val.dpi)) / 96.0;
    app.cell_w_px = atlas_val.cellW();
    app.cell_h_px = atlas_val.cellH();
    app.early_atlas = atlas_val;

    // 5. Compute rows/cols from actual cell metrics
    updateRowsColsFromClientForce(hwnd, app);

    // 6. Spawn nvim (native mode only)
    var nvim_cmd_buf: [1024]u8 = undefined;
    const nvim_cmd_slice = buildNativeNvimCmd(app, &nvim_cmd_buf);
    const nvim_path_z = app.alloc.dupeZ(u8, nvim_cmd_slice) catch null;
    defer if (nvim_path_z) |p| app.alloc.free(p);
    const nvim_path_ptr: ?[*:0]const u8 = if (nvim_path_z) |p| p.ptr else null;

    if (log_enabled) applog.appLog("[win] doEarlyCoreInit: starting nvim rows={d} cols={d}\n", .{ app.surface.rows, app.surface.cols });
    _ = core.zonvie_core_start(app.corep, nvim_path_ptr, app.surface.rows, app.surface.cols);
    app.nvim_spawned = true;
    app.early_core_init_done = true;

    // 7. D3D11 device init on separate thread
    app.d3d_init_thread = std.Thread.spawn(.{}, d3dInitThreadFn, .{app}) catch null;

    // 8. Tabline titlebar mode: trigger SWP_FRAMECHANGED immediately
    if (app.ext_tabline_enabled and app.tabline_style == .titlebar) {
        _ = c.SetWindowPos(hwnd, null, 0, 0, 0, 0, c.SWP_FRAMECHANGED | c.SWP_NOMOVE | c.SWP_NOSIZE);
        if (log_enabled) applog.appLog("[win] WM_CREATE: SWP_FRAMECHANGED applied (overlaps nvim spawn ~50ms)\n", .{});
    }

    if (log_enabled) applog.appLog("[win] WM_CREATE: early core init done, nvim spawn started rows={d} cols={d}\n", .{ app.surface.rows, app.surface.cols });
}

pub export fn WndProc(
    hwnd: c.HWND,
    msg: c.UINT,
    wParam: c.WPARAM,
    lParam: c.LPARAM,
) callconv(.winapi) c.LRESULT {
    switch (msg) {
        c.WM_NCCREATE => {
            if (applog.isEnabled()) applog.appLog("WM_NCCREATE hwnd={*} wParam={d} lParam=0x{x}", .{ hwnd, wParam, @as(usize, @bitCast(lParam)) });

            const cs: *c.CREATESTRUCTW = @ptrFromInt(@as(usize, @bitCast(lParam)));
            if (applog.isEnabled()) applog.appLog("  CREATESTRUCTW ptr={*} lpCreateParams={*}", .{ cs, cs.lpCreateParams });

            const lp = cs.lpCreateParams orelse {
                if (applog.isEnabled()) applog.appLog("  lpCreateParams is null -> fail", .{});
                return 0;
            };
            if (applog.isEnabled()) applog.appLog("  lpCreateParams={*}", .{lp});

            const app: *App = @ptrCast(@alignCast(lp));
            if (applog.isEnabled()) applog.appLog("  app ptr={*} align={d}", .{ app, @alignOf(App) });

            app.owned_by_hwnd = true;
            setApp(hwnd, app);
            if (applog.isEnabled()) applog.appLog("  GWLP_USERDATA set", .{});
            return 1;
        },

        // DWM custom titlebar: extend client area into titlebar
        c.WM_NCCALCSIZE => {
            if (getApp(hwnd)) |app| {
                if (app.ext_tabline_enabled and app.tabline_style == .titlebar and wParam != 0) {
                    // When wParam is TRUE, return 0 to use entire window as client area.
                    // This removes the standard titlebar/frame.
                    if (c.IsZoomed(hwnd) != 0) {
                        // When maximized, Windows extends the window beyond the visible
                        // screen by the frame thickness (invisible resize borders).
                        // Inset the proposed rect to match the actual visible area.
                        const params: *c.NCCALCSIZE_PARAMS = @ptrFromInt(@as(usize, @bitCast(lParam)));
                        const frame_x = c.GetSystemMetrics(c.SM_CXFRAME) + c.GetSystemMetrics(c.SM_CXPADDEDBORDER);
                        const frame_y = c.GetSystemMetrics(c.SM_CYFRAME) + c.GetSystemMetrics(c.SM_CXPADDEDBORDER);
                        params.rgrc[0].left += frame_x;
                        params.rgrc[0].top += frame_y;
                        params.rgrc[0].right -= frame_x;
                        params.rgrc[0].bottom -= frame_y;
                        if (applog.isEnabled()) applog.appLog("[win] WM_NCCALCSIZE: maximized, inset by frame=({d},{d})\n", .{ frame_x, frame_y });
                    } else {
                        if (applog.isEnabled()) applog.appLog("[win] WM_NCCALCSIZE: extending client area into titlebar\n", .{});
                    }
                    return 0;
                }
            }
            return c.DefWindowProcW(hwnd, msg, wParam, lParam);
        },

        // DWM custom titlebar: hit testing for resize borders and caption dragging
        c.WM_NCHITTEST => {
            if (getApp(hwnd)) |app| {
                if (app.ext_tabline_enabled and app.tabline_style == .titlebar) {
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
                    const tabbar_height_i16: i16 = @intCast(app.scalePx(TablineState.TAB_BAR_HEIGHT));
                    const resize_edge_width: i32 = 2; // Keep this many pixels at right edge for resize
                    const in_scrollbar_area = if (app.config.scrollbar.enabled) blk: {
                        const scrollbar_area_left = window_rect.right - @as(i32, @intFromFloat(app_mod.scrollbarReservedWidth(app.dpi_scale)));
                        const scrollbar_area_right = window_rect.right - resize_edge_width; // Leave edge for resize
                        const scrollbar_area_top = window_rect.top + tabbar_height_i16 + @as(i32, @intFromFloat(app_mod.scrollbarMargin(app.dpi_scale)));
                        const scrollbar_area_bottom = window_rect.bottom - @as(i32, @intFromFloat(app_mod.scrollbarMargin(app.dpi_scale))) - resize_edge_width;
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
                    const tabbar_height = app.scalePx(TablineState.TAB_BAR_HEIGHT);
                    if (y < window_rect.top + tabbar_height) {
                        // In tabbar area - check if clicking on interactive elements or empty space
                        const client_x = x - window_rect.left;
                        const client_width = window_rect.right - window_rect.left;

                        // Check window control buttons (min/max/close) on the right
                        const btn_start_x = client_width - app.scalePx(TablineState.WINDOW_BTNS_TOTAL);
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
                            const available_width = client_width - app.scalePx(TablineState.WINDOW_CONTROLS_WIDTH) - app.scalePx(40) - app.scalePx(TablineState.WINDOW_BTNS_TOTAL);
                            const ideal_width = @divTrunc(available_width, @as(i32, @intCast(tab_count)));
                            const tab_width = @min(app.scalePx(TablineState.TAB_MAX_WIDTH), @max(app.scalePx(TablineState.TAB_MIN_WIDTH), ideal_width));

                            var tab_x: i32 = app.scalePx(TablineState.WINDOW_CONTROLS_WIDTH);
                            for (0..tab_count) |_| {
                                if (client_x >= tab_x and client_x < tab_x + tab_width) {
                                    // On a tab - return HTCLIENT so clicks go to the app
                                    return c.HTCLIENT;
                                }
                                tab_x += tab_width + 1;
                            }

                            // Check + button area
                            const plus_x = tab_x + app.scalePx(8);
                            if (client_x >= plus_x and client_x < plus_x + app.scalePx(24)) {
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
            // Debug builds no longer force logging on by default.
            // Use --log <path> or [log] config to enable.

            if (applog.isEnabled()) applog.appLog("WM_CREATE: begin (deferred init)", .{});
            if (getApp(hwnd)) |app| {
                app.hwnd = hwnd;
                app.ui_thread_id = c.GetCurrentThreadId();

                // Set DPI scale early so that any scalePx() calls before
                // WM_APP_DEFERRED_INIT (e.g. WM_NCHITTEST, initial layout)
                // use the correct value.
                const initial_dpi = GetDpiForWindow(hwnd);
                if (initial_dpi > 0) {
                    app.dpi_scale = @as(f32, @floatFromInt(initial_dpi)) / 96.0;
                    if (applog.isEnabled()) applog.appLog("[win] WM_CREATE: initial dpi={d} scale={d:.2}\n", .{ initial_dpi, app.dpi_scale });
                }

                // Accept file drops via drag & drop
                c.DragAcceptFiles(hwnd, 1);

                // Native mode: perform early core init (before deferred init)
                // WSL/SSH/devcontainer modes use the traditional WM_APP_DEFERRED_INIT path
                const is_remote = app.wsl_mode or app.ssh_mode or app.devcontainer_mode;
                if (!is_remote) {
                    doEarlyCoreInit(hwnd, app) catch |e| {
                        if (applog.isEnabled()) applog.appLog("[win] WM_CREATE: doEarlyCoreInit failed: {any}\n", .{e});
                    };
                }

                // Post deferred init message - renderer initialization happens after window is shown
                _ = c.PostMessageW(hwnd, WM_APP_DEFERRED_INIT, 0, 0);

                if (applog.isEnabled()) applog.appLog("WM_CREATE: end (posted deferred init)", .{});
            }
            return 0;
        },
        c.WM_PAINT => {
            const log_enabled = applog.isEnabled();
            if (log_enabled) applog.appLog("WM_PAINT tid={d}", .{c.GetCurrentThreadId()});

            if (getApp(hwnd)) |app| {
                var ps: c.PAINTSTRUCT = undefined;
                _ = c.BeginPaint(hwnd, &ps);
                defer _ = c.EndPaint(hwnd, &ps);

                // Log first paint with content timing (startup performance)
                if (!app.first_paint_logged and app.renderer != null) {
                    if (log_enabled) {
                        var first_paint_t: c.LARGE_INTEGER = undefined;
                        _ = c.QueryPerformanceCounter(&first_paint_t);
                        const first_paint_ms = @divTrunc((first_paint_t.QuadPart - app_mod.g_startup_t0.QuadPart) * 1000, app_mod.g_startup_freq.QuadPart);
                        applog.appLog("[TIMING] First WM_PAINT (renderer ready): {d}ms from main()\n", .{first_paint_ms});
                    }
                    app.first_paint_logged = true;
                }

                // If renderer not yet initialized (deferred init pending), just fill with black
                if (app.renderer == null) {
                    if (log_enabled) applog.appLog("[win] WM_PAINT: renderer not ready, filling black", .{});
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
                    {
                        app.mu.lock();
                        app.surface.paint_full = true;
                        app.paint_rects.clearRetainingCapacity();
                        app.mu.unlock();
                    }
                }

                // Note: row_mode/rows/main_verts length are logged after snapshotting under lock.
                // if (dirty) |r| {
                //     applog.appLog("[win]   dirty_rect=({d},{d})-({d},{d})\n", .{ r.left, r.top, r.right, r.bottom });
                // }

                // Phase timing for WM_PAINT
                var t_snapshot_start_ns: i128 = 0;
                var t_snapshot_end_ns: i128 = 0;
                var t_atlas_end_ns: i128 = 0;
                if (log_enabled) {
                    t_snapshot_start_ns = std.time.nanoTimestamp();
                }

                // Step 1: TBS acquire (rotation_mu short lock).
                // Captures committed_index, paint_full, and copies pending_dirty → paint_dirty_snapshot.
                const tbs_snapshot = app.tbs.acquireForPaint();
                defer {
                    const needs_reinvalidate = app.tbs.releaseFromPaint(tbs_snapshot.committed_index);
                    if (needs_reinvalidate) {
                        _ = c.InvalidateRect(hwnd, null, c.FALSE);
                    }
                }
                const committed = &app.tbs.sets[tbs_snapshot.committed_index];

                // Step 2: UI metadata snapshot (app.mu short lock).
                app.mu.lock();
                if (app.surface.rows == 0) {
                    updateRowsColsFromClient(hwnd, app);
                }

                // Read vertex-related state from TBS committed set (refcount-protected, lock-free).
                const row_mode = committed.row_mode;
                const rows_snapshot: u32 = committed.rows;
                const row_verts_len: u32 = @intCast(committed.row_map.items.len);
                const main_verts_len_snapshot: u32 = @intCast(committed.flat_verts.items.len);

                // Read UI metadata under app.mu.
                const seed_pending_snapshot = app.seed_pending;
                const row_valid_count_snapshot = app.row_valid_count;
                const row_layout_gen_snapshot: u64 = app.row_layout_gen;
                const row_mode_max_row_end_snapshot: u32 = app.row_mode_max_row_end;

                // IMPORTANT: do NOT copy renderer/atlas structs here.
                // Take pointers to the option payloads instead.
                var atlas_ptr: ?*dwrite_d2d.Renderer = null;
                var gpu_ptr: ?*d3d11.Renderer = null;
                if (app.atlas) |*a| atlas_ptr = a;
                if (app.renderer) |*g| gpu_ptr = g;

                // If the glyph atlas was reset, all cached row vertex UVs are stale.
                // Request a full re-seed so the core regenerates every row.
                // Guard with renderer mutex (resetAtlas sets the flag under a.mu).
                if (atlas_ptr) |a| {
                    var reset_pending = false;
                    var cur_atlas_w: u32 = 0;
                    var cur_atlas_h: u32 = 0;
                    {
                        a.mu.lock();
                        defer a.mu.unlock();
                        reset_pending = a.atlas_reset_pending;
                        if (reset_pending) a.atlas_reset_pending = false;
                        cur_atlas_w = a.atlas_w;
                        cur_atlas_h = a.atlas_h;
                    }
                    if (reset_pending) {
                        // Resize D3D atlas texture if dimensions changed (render-thread-owned)
                        if (gpu_ptr) |g| {
                            g.recreateAtlasTextureIfNeeded(cur_atlas_w, cur_atlas_h) catch {
                                if (log_enabled) applog.appLog("[win] FATAL: D3D atlas texture recreation failed, skipping frame\n", .{});
                                if (app.hwnd) |h| _ = c.PostMessageW(h, c.WM_CLOSE, 0, 0);
                                app.mu.unlock();
                                return 0;
                            };
                        }
                        app.need_full_seed.store(true, .seq_cst);
                        app.surface.paint_full = true;
                        app.paint_rects.clearRetainingCapacity();
                        // After atlas reset, external window paints may consume
                        // shared pending_uploads before the main window sees them.
                        // Schedule a full atlas upload to ensure all glyph data is present.
                        app.atlas_full_upload_needed = true;
                    }
                }

                // Build dirty row keys from TBS paint_dirty_snapshot (captured by acquireForPaint).
                // The bitset iterator yields sorted, unique row indices — no dedup needed.
                var dirty_row_keys: std.ArrayListUnmanaged(u32) = .{};
                defer dirty_row_keys.deinit(app.alloc);

                if (row_mode) {
                    var dit = app.tbs.paint_dirty_snapshot.iterator(.{});
                    while (dit.next()) |row_idx| {
                        dirty_row_keys.append(app.alloc, @intCast(row_idx)) catch break;
                    }
                }

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
                paint_rects_snapshot.appendSlice(app.alloc, app.paint_rects.items) catch {};
                app.paint_rects.clearRetainingCapacity();

                const paint_full_snapshot = tbs_snapshot.paint_full;

                app.mu.unlock();

                if (log_enabled) {
                    t_snapshot_end_ns = std.time.nanoTimestamp();
                }

                if (log_enabled) {
                    applog.appLog(
                        "[win] WM_PAINT rcPaint=({d},{d})-({d},{d}) dirty={s} need_seed={d} row_mode={d} rows={d} row_verts_len={d} main_verts={d}\n",
                        .{
                            ps.rcPaint.left,                       ps.rcPaint.top,                        ps.rcPaint.right,                 ps.rcPaint.bottom,
                            if (dirty == null) "null" else "rect", @as(u32, @intFromBool(did_need_seed)), @as(u32, @intFromBool(row_mode)), rows_snapshot,
                            row_verts_len,                         main_verts_len_snapshot,
                        },
                    );
                    if (row_mode and rows_mismatch) {
                        applog.appLog(
                            "[win] WM_PAINT(row) WARN rows_mismatch rows={d} max_row_end={d} row_verts_len={d}\n",
                            .{ rows_snapshot, row_mode_max_row_end_snapshot, row_verts_len },
                        );
                    }
                }

                // Flush atlas uploads (may be triggered by core updates).
                // Uses since-based cursor so multiple windows can independently
                // consume the same append-only pending_uploads queue.
                var atlas_uploaded = false;
                if (atlas_ptr) |a| {
                    if (gpu_ptr) |g| {
                        g.lockContext();
                        defer g.unlockContext();
                        const need_full = app.atlas_full_upload_needed;
                        if (need_full) {
                            app.atlas_full_upload_needed = false;
                            if (log_enabled) applog.appLog("[win] atlas full upload (post-reset sync)\n", .{});
                        }
                        const new_cursor = app_mod.flushAtlasUploads(a, g, app.atlas_upload_cursor, need_full);
                        if (new_cursor != app.atlas_upload_cursor) atlas_uploaded = true;
                        app.atlas_upload_cursor = new_cursor;
                    }
                }
                if (log_enabled and atlas_uploaded) {
                    applog.appLog("[win] atlas_uploads flushed (cursor={d})\n", .{app.atlas_upload_cursor});
                }
                if (log_enabled) {
                    t_atlas_end_ns = std.time.nanoTimestamp();
                }

                var render_ok = false;
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
                    // Only applies to titlebar mode (sidebar mode uses standard titlebar)
                    const content_y_offset: ?u32 = if (app.ext_tabline_enabled and app.tabline_style == .titlebar and app.content_hwnd == null)
                        @intCast(app.scalePx(TablineState.TAB_BAR_HEIGHT))
                    else
                        null;

                    // Content X offset for sidebar mode (pushes content right of sidebar)
                    const content_x_offset: ?u32 = if (app.ext_tabline_enabled and app.tabline_style == .sidebar and !app.sidebar_position_right)
                        @intCast(app.scalePx(@as(c_int, @intCast(app.sidebar_width_px))))
                    else
                        null;

                    // Sidebar right width (reduces content area from right edge)
                    const sidebar_right_width: ?u32 = if (app.ext_tabline_enabled and app.tabline_style == .sidebar and app.sidebar_position_right)
                        @intCast(app.scalePx(@as(c_int, @intCast(app.sidebar_width_px))))
                    else
                        null;

                    // Tabbar background color (dark gray) - fallback if tabline texture not available
                    const tabbar_bg_color: ?[4]f32 = if (app.ext_tabline_enabled and app.tabline_style == .titlebar and app.content_hwnd == null)
                        .{ 0.12, 0.12, 0.12, 1.0 }
                    else
                        null;
                    const content_x_offset_i32: i32 = if (content_x_offset) |off| @intCast(off) else 0;
                    const content_y_offset_i32: i32 = if (content_y_offset) |off| @intCast(off) else 0;
                    const content_right_i32: i32 = if (content_width) |cw|
                        content_x_offset_i32 + @as(i32, @intCast(cw))
                    else
                        client_for_content.right;

                    // Post-process bloom (neon glow) state from core
                    const glow_enabled = if (app.corep) |cp| core.zonvie_core_get_glow_enabled(cp) else false;
                    const glow_intensity = if (app.corep) |cp| core.zonvie_core_get_glow_intensity(cp) else @as(f32, 0.8);

                    // Snap viewport height to cell boundaries to match core's NDC calculation.
                    // The core computes NDC using grid_rows * cell_h (snapped to cell boundaries),
                    // so the D3D11 viewport must use the same snapped height to prevent sub-pixel
                    // misalignment between vertex positions and scissor rects (which causes stripes).
                    const content_height: u32 = app_mod.snappedContentHeight(
                        @intCast(@max(1, client_for_content.bottom - client_for_content.top)),
                        app.cell_h_px + app.linespace_px,
                        content_y_offset orelse 0,
                    );

                    // Update tabline/sidebar texture (rendered via GDI offscreen -> D3D11 texture)
                    // This avoids DWM composition issues by keeping GDI rendering offscreen
                    if (app.ext_tabline_enabled) {
                        if (app.tabline_style == .titlebar and app.tabline_state.tab_count > 0) {
                            const tabline_width: u32 = @intCast(@max(1, client_for_content.right));
                            const tabline_height: u32 = @intCast(app.scalePx(TablineState.TAB_BAR_HEIGHT));
                            tabline_mod.renderTablineToD3D(app, tabline_width, tabline_height);
                        } else if (app.tabline_style == .sidebar) {
                            // Always call renderSidebarToD3D: it releases texture when tab_count == 0
                            const sw: u32 = @intCast(app.scalePx(@as(c_int, @intCast(app.sidebar_width_px))));
                            const sh: u32 = @intCast(@max(1, client_for_content.bottom));
                            tabline_mod.renderSidebarToD3D(app, sw, sh);
                        }
                    }

                    if (!row_mode) {
                        // Non-row mode: read from TBS committed set (refcount-protected, lock-free).
                        // IMPORTANT: Do NOT hold app.mu during drawEx.
                        // drawEx calls DXGI Present which can pump Win32 messages internally.
                        // If a re-entrant message handler tries app.mu.lock() on the same thread
                        // -> self-deadlock (SRWLOCK is non-reentrant).
                        // Use local arrays (not app fields) so that even if DXGI message pumping
                        // causes a re-entrant WM_PAINT, each invocation has its own snapshot.
                        var local_main: std.ArrayListUnmanaged(core.Vertex) = .{};
                        defer local_main.deinit(app.alloc);
                        var local_cursor: std.ArrayListUnmanaged(core.Vertex) = .{};
                        defer local_cursor.deinit(app.alloc);
                        var non_row_draw = false;
                        {
                            // TBS committed set is safe to read (refcount protects from rotation).
                            if (!committed.row_mode) {
                                non_row_draw = blk: {
                                    local_main.appendSlice(app.alloc, committed.flat_verts.items) catch |e| {
                                        if (log_enabled) applog.appLog("[win] WM_PAINT(non-row) main snapshot failed: {any}\n", .{e});
                                        break :blk false;
                                    };
                                    if (app.cursor_blink_state) {
                                        local_cursor.appendSlice(app.alloc, committed.cursor_verts.items) catch |e| {
                                            if (log_enabled) applog.appLog("[win] WM_PAINT(non-row) cursor snapshot failed: {any}\n", .{e});
                                            break :blk false;
                                        };
                                    }
                                    break :blk true;
                                };
                            } else {
                                // Row-mode flipped mid-frame; skip and let the next paint handle it.
                                if (log_enabled) applog.appLog("[win] WM_PAINT(non-row) row_mode flipped -> skip\n", .{});
                            }
                        }
                        if (non_row_draw) {
                            if (g.drawEx(local_main.items, local_cursor.items, dirty, .{ .content_width = content_width, .content_y_offset = content_y_offset, .content_x_offset = content_x_offset, .sidebar_right_width = sidebar_right_width, .content_height = content_height, .tabbar_bg_color = tabbar_bg_color, .glow_enabled = glow_enabled, .glow_intensity = glow_intensity })) {
                                render_ok = true;
                            } else |e| {
                                if (log_enabled) applog.appLog("gpu.draw failed: {any}\n", .{e});
                            }
                        }
                    } else {
                        // --- Row-mode ---
                        var t_row_start_ns: i128 = 0;
                        var t_present_start_ns: i128 = 0;
                        if (log_enabled) {
                            t_row_start_ns = std.time.nanoTimestamp();
                        }

                        // Build sorted, deduplicated list of rows to draw.
                        const rows_to_draw = &app.wm_paint_rows_to_draw;

                        const force_full_rows =
                            did_need_seed or (dirty == null) or paint_full_snapshot or seed_pending_snapshot or glow_enabled;

                        const total_rows_for_enum: u32 = if (effective_rows != 0) effective_rows else row_verts_len;
                        const max_valid_row: u32 = @min(row_verts_len, rows_snapshot);

                        app_mod.computeRowsToDraw(
                            app.alloc,
                            rows_to_draw,
                            force_full_rows,
                            dirty_row_keys.items,
                            total_rows_for_enum,
                            max_valid_row,
                        );

                        // If atlas was uploaded but no rows will be drawn in this frame,
                        // request a full repaint so newly uploaded glyphs become visible.
                        if (atlas_uploaded and rows_to_draw.items.len == 0) {
                            app.mu.lock();
                            app.surface.paint_full = true;
                            app.paint_rects.clearRetainingCapacity();
                            app.mu.unlock();
                            {
                                app.tbs.rotation_mu.lock();
                                app.tbs.pending_paint_full = true;
                                app.tbs.rotation_mu.unlock();
                            }
                            _ = c.InvalidateRect(hwnd, null, c.FALSE);
                        }

                        if (log_enabled) {
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
                        }

                        // --- Build present dirty from actual drawn row_rc + cursor_rc (don't use rcPaint) ---
                        // Read cursor verts from TBS committed set (refcount-protected, lock-free).
                        const cursor_verts_snapshot: []const core.Vertex = committed.cursor_verts.items;
                        if (log_enabled) applog.appLog("[win] WM_PAINT(row) cursor_verts.len={d}\n", .{cursor_verts_snapshot.len});
                        // Use content_hwnd size when it exists (D3D11 is bound to content_hwnd)
                        var client: c.RECT = undefined;
                        const client_hwnd = if (app.content_hwnd) |ch| ch else hwnd;
                        _ = c.GetClientRect(client_hwnd, &client);

                        // Compute cursor rect directly from NDC vertices using viewport
                        // dimensions (content_height etc.) to match the D3D11 viewport's
                        // NDC-to-pixel mapping. Using the client rect (as rectFromCursorVerts
                        // does) causes cumulative position drift because the viewport is
                        // snapped to cell boundaries, which is smaller than the client area.
                        const cursor_rc_opt: ?c.RECT = if (cursor_verts_snapshot.len != 0) blk: {
                            var minx: f32 = cursor_verts_snapshot[0].position[0];
                            var maxx: f32 = minx;
                            var miny: f32 = cursor_verts_snapshot[0].position[1];
                            var maxy: f32 = miny;
                            for (cursor_verts_snapshot) |v| {
                                if (v.position[0] < minx) minx = v.position[0];
                                if (v.position[0] > maxx) maxx = v.position[0];
                                if (v.position[1] < miny) miny = v.position[1];
                                if (v.position[1] > maxy) maxy = v.position[1];
                            }
                            // Mirror the D3D11 viewport calculation from drawEx:
                            //   viewport = (x_offset, y_offset, viewport_width, content_height)
                            const vp_x: u32 = content_x_offset orelse 0;
                            const vp_y: u32 = content_y_offset orelse 0;
                            const base_w: u32 = content_width orelse @intCast(@max(1, client.right));
                            const sidebar_w: u32 = sidebar_right_width orelse 0;
                            const vp_w: u32 = if (base_w > vp_x + sidebar_w) base_w - vp_x - sidebar_w else 1;
                            const vp_h: u32 = content_height;

                            const w_f: f32 = @floatFromInt(vp_w);
                            const h_f: f32 = @floatFromInt(vp_h);
                            const x_off_f: f32 = @floatFromInt(vp_x);
                            const y_off_f: f32 = @floatFromInt(vp_y);

                            const l_f = x_off_f + (minx + 1.0) * 0.5 * w_f;
                            const r_f = x_off_f + (maxx + 1.0) * 0.5 * w_f;
                            const t_f = y_off_f + (1.0 - maxy) * 0.5 * h_f;
                            const b_f = y_off_f + (1.0 - miny) * 0.5 * h_f;

                            var l: i32 = @intFromFloat(@floor(l_f));
                            var r: i32 = @intFromFloat(@ceil(r_f));
                            var t: i32 = @intFromFloat(@floor(t_f));
                            var b: i32 = @intFromFloat(@ceil(b_f));

                            if (l < 0) l = 0;
                            if (t < 0) t = 0;
                            if (r > client.right) r = client.right;
                            if (b > client.bottom) b = client.bottom;

                            if (r <= l or b <= t) break :blk null;
                            break :blk .{ .left = l, .top = t, .right = r, .bottom = b };
                        } else null;

                        const fallback_row_h: u32 = app.cell_h_px + app.linespace_px;
                        const rows_for_layout: u32 = if (rows_mismatch) 0 else if (rows_snapshot != 0) rows_snapshot else row_verts_len;
                        const row_h_px_u32 = if (rows_mismatch)
                            fallback_row_h
                        else
                            rowHeightPxFromClient(hwnd, rows_for_layout, fallback_row_h);
                        const row_h_px: i32 = @intCast(@as(i32, @intCast(row_h_px_u32)));
                        if (log_enabled and (row_h_px_u32 != fallback_row_h or rows_mismatch)) {
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
                        // where app.surface.rows is stale (e.g., after font/linespace changes).
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
                                    if (log_enabled) applog.appLog("[win] WM_PAINT(row) cursor added to present_rects (contained={d})\n", .{@intFromBool(contained)});
                                } else {
                                    if (log_enabled) applog.appLog("[win] WM_PAINT(row) cursor already in present_rects\n", .{});
                                }
                            } else {
                                if (log_enabled) applog.appLog("[win] WM_PAINT(row) cursor rect invalid after clamp\n", .{});
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
                                    u = callbacks.unionRect(u, present_rects.items[j]);
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
                        // With TBS, committed set is read-only — only clear row_valid under app.mu.
                        app.mu.lock();

                        const seed_clear = did_need_seed or app.seed_clear_pending;
                        if (seed_clear) {
                            app.seed_clear_pending = false;
                            // Only unset validity for rows beyond current grid
                            const current_rows = committed.rows;
                            var clear_idx: usize = current_rows;
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
                        const preserve_back = !seed_clear and !seed_pending_snapshot and !glow_enabled;
                        if (log_enabled) applog.appLog(
                            "[win] WM_PAINT(row) setup preserve_back={d} did_need_seed={d} seed_pending={d} seed_clear={d}\n",
                            .{
                                @as(u32, @intFromBool(preserve_back)),
                                @as(u32, @intFromBool(did_need_seed)),
                                @as(u32, @intFromBool(seed_pending_snapshot)),
                                @as(u32, @intFromBool(seed_clear)),
                            },
                        );

                        const row_draw_params = app_mod.RowModeDrawParams{
                            .content_height = content_height,
                            .row_h_px = row_h_px,
                            .x_offset = content_x_offset_i32,
                            .y_offset = content_y_offset_i32,
                            .content_right = content_right_i32,
                            .preserve_back = preserve_back,
                            .use_row_scissor = !seed_pending_snapshot,
                            .glow_enabled = glow_enabled,
                            .content_width = content_width,
                            .content_y_offset = content_y_offset,
                            .content_x_offset = content_x_offset,
                            .sidebar_right_width = sidebar_right_width,
                            .tabbar_bg_color = tabbar_bg_color,
                        };

                        // Bloom: collect row verts, draw after row VBs
                        var bloom_verts: std.ArrayListUnmanaged(core.Vertex) = .{};
                        defer bloom_verts.deinit(app.alloc);

                        // Ensure row_vbs array covers committed set's row count.
                        {
                            const need_len = committed.row_map.items.len;
                            if (app.row_vbs.items.len < need_len) {
                                const old_len = app.row_vbs.items.len;
                                app.row_vbs.resize(app.alloc, need_len) catch {};
                                for (app.row_vbs.items[old_len..]) |*rvb| {
                                    rvb.* = .{};
                                }
                            }
                        }

                        // Apply scroll pixel shift (row_vbs shift + cursor ghost + back_tex shift).
                        // Scroll state is bundled in PaintSnapshot, atomically consistent with committed set.
                        var scroll_shift_result = app_mod.ScrollShiftResult{};
                        if (preserve_back) {
                            if (tbs_snapshot.scroll_rect) |sr| {
                                scroll_shift_result = app_mod.applyScrollShift(
                                    g,
                                    app.alloc,
                                    app.row_vbs.items,
                                    rows_to_draw,
                                    sr,
                                    tbs_snapshot.scroll_dy_px,
                                    tbs_snapshot.vb_shift,
                                    &app.last_painted_cursor_row,
                                    row_h_px,
                                    effective_rows,
                                    content_y_offset_i32,
                                );
                            }
                        } else {
                            // No scroll shift, but still apply pending vb shift to avoid stale state.
                            if (tbs_snapshot.vb_shift != 0) {
                                app_mod.shiftRowVBs(app.row_vbs.items, tbs_snapshot.vb_shift, 0, @intCast(app.row_vbs.items.len));
                            }
                        }

                        // TBS lock-free draw: committed set is protected by refcount,
                        // no app.mu needed during VB upload + draw.
                        const row_draw_result = app_mod.drawRowModeSetupAndRowsFromSlots(
                            g,
                            app.alloc,
                            committed.row_map.items,
                            &app.tbs.pool,
                            app.row_vbs.items,
                            rows_to_draw.items,
                            &bloom_verts,
                            row_draw_params,
                        ) catch |e| blk: {
                            if (log_enabled) applog.appLog("drawRowModeSetupAndRowsFromSlots failed: {any}\n", .{e});
                            break :blk app_mod.RowModeDrawResult{};
                        };

                        if (log_enabled) applog.appLog(
                            "[win] WM_PAINT(row) seed_state rows={d} row_valid={d} rows_to_draw={d} row_verts_len={d}\n",
                            .{ rows_snapshot, row_valid_count_snapshot, rows_to_draw.items.len, row_verts_len },
                        );

                        const drawn_rows = row_draw_result.metrics.drawn_rows;
                        const skipped_empty = row_draw_result.metrics.skipped_empty;
                        const first_empty_row = row_draw_result.metrics.first_empty_row;
                        const log_vb_upload_rows = row_draw_result.metrics.vb_upload_rows;
                        const log_vb_upload_rows_bytes = row_draw_result.metrics.vb_upload_rows_bytes;
                        const log_vb_upload_ns = row_draw_result.metrics.vb_upload_ns;
                        const log_draw_vb_ns = row_draw_result.metrics.draw_vb_ns;
                        const ctx_ptr = row_draw_result.ctx_ptr;
                        const rs_set_sc_fn = row_draw_result.rs_set_sc_fn;

                        if (log_enabled) {
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

                        // Cursor overlay — shared helper handles upload, scissor, draw/blink-off, and tracking.
                        app_mod.drawCursorOverlay(g, .{
                            .cursor_verts = cursor_verts_snapshot,
                            .cursor_row = committed.last_cursor_row,
                            .cursor_vb = &app.cursor_vb,
                            .cursor_vb_bytes = &app.cursor_vb_bytes,
                            .row_vbs = app.row_vbs.items,
                            .row_map = committed.row_map.items,
                            .pool = &app.tbs.pool,
                            .blink_visible = app.cursor_blink_state,
                            .x_offset = content_x_offset_i32,
                            .y_offset = content_y_offset_i32,
                            .content_right = content_right_i32,
                            .content_height = content_height,
                            .row_h_px = row_h_px,
                            .ctx_ptr = ctx_ptr,
                            .rs_set_sc_fn = rs_set_sc_fn,
                            .last_painted_cursor_row = &app.last_painted_cursor_row,
                        });

                        // Post-process bloom (neon glow) for row-mode
                        if (glow_enabled) {
                            app_mod.drawBloomOverlay(g, bloom_verts.items, cursor_verts_snapshot, glow_intensity, row_draw_params);
                        }

                        if (log_enabled and force_full_rows and skipped_empty != 0) {
                            applog.appLog(
                                "[win] WM_PAINT(row) WARN skip_present missing_rows={d} rows={d} row_verts_len={d}\n",
                                .{ skipped_empty, rows_snapshot, row_verts_len },
                            );
                        }

                        if (log_enabled) {
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

                            applog.appLog(
                                "[win] WM_PAINT(row-frame) drawn_rows={d} rows_to_draw={d} present_rects={d} present_area_px={d} vb_upload_rows={d} vb_upload_rows_bytes={d} vb_upload_cursor={d} vb_upload_cursor_bytes={d}\n",
                                .{
                                    drawn_rows, // NOTE: variable within row-vb block. See note below
                                    rows_to_draw.items.len,
                                    present_rects.items.len,
                                    log_present_rects_area_px,
                                    log_vb_upload_rows,
                                    log_vb_upload_rows_bytes,
                                    @as(u32, if (cursor_verts_snapshot.len != 0) 1 else 0),
                                    @as(u64, cursor_verts_snapshot.len * @sizeOf(core.Vertex)),
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
                        rows_current = committed.rows;
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

                        // When scrollBackTex shifted back_tex content, the entire scroll
                        // region changed in back_tex. Add it to present_rects so the
                        // CopySubresourceRegion in present copies the shifted pixels
                        // to all swapchain buffers.
                        if (scroll_shift_result.scroll_rect) |sr| {
                            present_rects.append(app.alloc, sr) catch {};
                        }

                        if (allow_present) {
                            // Draw scrollbar overlay before present
                            if (app.config.scrollbar.enabled and app.scrollbar_alpha > 0.001) {
                                var scrollbar_verts: [12]core.Vertex = undefined;
                                const scrollbar_vert_count = scrollbar.generateScrollbarVertices(app, client.right, client.bottom, &scrollbar_verts);
                                app_mod.drawScrollbarOverlay(g, &app.scrollbar_vb, &app.scrollbar_vb_bytes, scrollbar_verts[0..scrollbar_vert_count]);
                            }

                            // When seed_clear is true, the back buffer was just cleared.
                            // We must do a full present to sync the cleared state to all swapchain buffers,
                            // otherwise areas not covered by partial present rects may show stale content.
                            // Also force full present when scrollbar is visible to avoid knob ghosting.
                            const scrollbar_needs_full = app.scrollbar_alpha > 0.001;
                            const force_full_present = force_full_rows or (seed_pending_snapshot and !rows_mismatch) or seed_clear or scrollbar_needs_full;
                            const present_rects_slice: []const c.RECT =
                                if (force_full_present) &[_]c.RECT{} else present_rects.items;

                            // Present1 scroll params: disabled for now.
                            // back_tex pixel shift (scrollBackTex) already handles the retained
                            // content shift. Adding pScrollRect/pScrollOffset to Present1 would
                            // cause a double-shift since we CopySubresourceRegion back_tex→bb.

                            if (g.presentFromBackRectsWithCursorNoResize(
                                present_rects_slice,
                                app.cursor_vb,
                                cursor_verts_snapshot.len,
                                cursor_rc_opt,
                                force_full_present,
                                null,
                                null,
                            )) {
                                render_ok = true;
                                // last_painted_cursor_row is tracked by drawCursorOverlay above.
                            } else |e| {
                                if (log_enabled) applog.appLog("presentFromBackRectsWithCursorNoResize failed: {any}\n", .{e});
                            }

                            if (seed_pending_snapshot and effective_rows != 0 and effective_row_valid_count == effective_rows) {
                                app.mu.lock();
                                app.seed_pending = false;
                                app.surface.paint_full = true;
                                app.paint_rects.clearRetainingCapacity();
                                app.seed_clear_pending = true;
                                app.mu.unlock();
                                // Also set TBS pending_paint_full for next paint cycle.
                                {
                                    app.tbs.rotation_mu.lock();
                                    app.tbs.pending_paint_full = true;
                                    app.tbs.rotation_mu.unlock();
                                }
                                if (log_enabled) applog.appLog(
                                    "[win] WM_PAINT(row) seed_complete rows={d} row_valid={d} -> request repaint\n",
                                    .{ effective_rows, effective_row_valid_count },
                                );
                                _ = c.InvalidateRect(hwnd, null, c.FALSE);
                            }
                        } else if (log_enabled) {
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
                            const snapshot_us: u64 = @intCast(@divTrunc(@max(0, t_snapshot_end_ns - t_snapshot_start_ns), 1000));
                            const atlas_us: u64 = @intCast(@divTrunc(@max(0, t_atlas_end_ns - t_snapshot_end_ns), 1000));
                            const row_us: u64 = @intCast(@divTrunc(@max(0, t_present_start_ns - t_row_start_ns), 1000));
                            const present_us: u64 = @intCast(@divTrunc(@max(0, t_done_ns - t_present_start_ns), 1000));
                            const total_us: u64 = row_us + present_us;
                            const vb_upload_us: u64 = @intCast(@divTrunc(@max(0, log_vb_upload_ns), 1000));
                            const draw_vb_us: u64 = @intCast(@divTrunc(@max(0, log_draw_vb_ns), 1000));
                            applog.appLog(
                                "[perf] row_mode_ui snapshot_us={d} atlas_us={d} rows={d} vb_upload_us={d} draw_vb_us={d} row_us={d} present_us={d} total_us={d}\n",
                                .{ snapshot_us, atlas_us, rows_to_draw.items.len, vb_upload_us, draw_vb_us, row_us, present_us, total_us },
                            );
                        }
                    }
                }

                // Recover dirty state if rendering failed, so the next
                // WM_PAINT will retry a full redraw instead of showing stale content.
                if (!render_ok) {
                    app.mu.lock();
                    app.surface.paint_full = true;
                    app.mu.unlock();
                    {
                        app.tbs.rotation_mu.lock();
                        app.tbs.pending_paint_full = true;
                        app.tbs.rotation_mu.unlock();
                    }
                    _ = c.InvalidateRect(hwnd, null, c.FALSE);
                }

                // Update IME preedit overlay (separate popup window)
                input.updateImePreeditOverlay(hwnd, app);

                // Tabline is now rendered via D3D11 texture (see renderTablineToD3D call before gpu rendering)
            }

            return 0;
        },

        // Per-Monitor DPI change (e.g. moving window between monitors)
        0x02E0 => { // WM_DPICHANGED
            if (getApp(hwnd)) |app| {
                const new_dpi: u32 = @as(u32, @intCast(wParam & 0xFFFF)); // LOWORD
                if (applog.isEnabled()) applog.appLog("[win] WM_DPICHANGED: new_dpi={d}\n", .{new_dpi});

                // Update app-level DPI scale
                app.dpi_scale = @as(f32, @floatFromInt(new_dpi)) / 96.0;

                // Update renderer DPI (re-scales font, clears glyph cache).
                // Get atlas pointer under app.mu, then release before calling
                // updateDpi to maintain consistent lock ordering (avoid holding
                // app.mu while acquiring renderer.mu inside updateDpi).
                var atlas_ptr: ?*dwrite_d2d.Renderer = null;
                app.mu.lock();
                if (app.atlas) |*a| atlas_ptr = a;
                app.mu.unlock();

                if (atlas_ptr) |a| {
                    a.updateDpi(new_dpi);
                }

                // Update app-level state under app.mu
                app.mu.lock();
                if (atlas_ptr) |a| {
                    app.cell_w_px = a.cellW();
                    app.cell_h_px = a.cellH();
                }
                app.need_full_seed.store(true, .seq_cst);
                app.seed_pending = true;
                app.seed_clear_pending = true;
                app.row_valid_count = 0;
                if (app.row_valid.bit_length != 0) {
                    app.row_valid.unsetAll();
                }
                app.mu.unlock();

                // Resize window to the suggested rect from WM_DPICHANGED
                const suggested: *const c.RECT = @ptrFromInt(@as(usize, @bitCast(lParam)));
                _ = c.SetWindowPos(
                    hwnd,
                    null,
                    suggested.left,
                    suggested.top,
                    suggested.right - suggested.left,
                    suggested.bottom - suggested.top,
                    c.SWP_NOZORDER | c.SWP_NOACTIVATE,
                );

                // Layout update to core (SetWindowPos triggers WM_SIZE which handles this,
                // but ensure it's done)
                updateLayoutToCore(hwnd, app);
            }
            return 0;
        },

        c.WM_SIZE => {
            // SIZE_MINIMIZED: skip resize to avoid sending tiny rows/cols to Neovim,
            // which would destroy split window proportions.
            const SIZE_MINIMIZED = 1;
            if (wParam == SIZE_MINIMIZED) return 0;

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

                if (applog.isEnabled()) {
                    applog.appLog(
                        "[win] WM_SIZE wParam={d} client=({d},{d})-({d},{d}) need_full_seed=1 atlas={s} gpu={s} resize_ns={d}\n",
                        .{
                            @as(u32, @intCast(wParam)),
                            rc.left,
                            rc.top,
                            rc.right,
                            rc.bottom,
                            if (app.atlas != null) "Y" else "N",
                            if (app.renderer != null) "Y" else "N",
                            app.last_resize_ns,
                        },
                    );
                }

                // 2) core layout update must be outside lock (can re-enter via callbacks).
                if (app.window_shown) {
                    updateLayoutToCore(hwnd, app);
                }

                // Unblock RPC thread once layout is known (before window is shown)
                if (app.early_core_init_done and app.nvim_spawned and !app.window_shown) {
                    if (app.corep) |corep| {
                        if (app.surface.rows > 0 and app.surface.cols > 0) {
                            core.zonvie_core_notify_layout_ready(corep, app.surface.rows, app.surface.cols);
                        }
                    }
                }

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
                        app.scalePx(TablineState.TAB_BAR_HEIGHT),
                        0, // No SWP_NOZORDER - explicitly set Z-order
                    );
                }

                // 4) Trigger D3D11 resize
                // IMPORTANT: Do NOT hold app.mu during g.resize().
                // DXGI ResizeBuffers (FLIP model) can pump Win32 messages internally.
                // If a pending WM_PAINT is dispatched re-entrantly, it tries app.mu.lock()
                // on the same thread -> self-deadlock (SRWLOCK is non-reentrant).
                {
                    var gpu_ptr: ?*d3d11.Renderer = null;
                    app.mu.lock();
                    if (app.renderer) |*g| gpu_ptr = g;
                    app.mu.unlock();

                    if (gpu_ptr) |g| {
                        g.resize() catch {};
                    }
                }
                {
                    app.mu.lock();
                    app.surface.paint_full = true;
                    app.paint_rects.clearRetainingCapacity();
                    app.mu.unlock();
                }

                // 5) repaint
                _ = c.InvalidateRect(hwnd, null, 0);
            }
            return 0;
        },

        c.WM_MOVE => {
            // Reposition ext-float and mini windows when main window moves.
            // Use a coalescing timer to avoid flooding the message queue
            // during window drag (SetTimer resets if the same ID is pending).
            _ = c.SetTimer(hwnd, TIMER_REPOSITION_FLOATS, 15, null);
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
                        if (applog.isEnabled()) applog.appLog("WM_APP_ATLAS_ENSURE_GLYPH: atlasEnsureGlyphEntry ERROR: {any}", .{err});
                        return 0;
                    };
                    out_entry.* = e;

                    if (applog.isEnabled()) applog.appLog("WM_APP_ATLAS_ENSURE_GLYPH: ok scalar={d} out_entry_ptr=0x{x} uv_min=({d:.6},{d:.6}) uv_max=({d:.6},{d:.6})", .{
                        scalar,
                        out_entry_ptr_bits,
                        e.uv_min[0],
                        e.uv_min[1],
                        e.uv_max[0],
                        e.uv_max[1],
                    });

                    return 1;
                }

                if (applog.isEnabled()) applog.appLog("WM_APP_ATLAS_ENSURE_GLYPH: renderer is null", .{});
                return 0;
            }
            return 0;
        },

        WM_APP_CREATE_EXTERNAL_WINDOW => {
            if (applog.isEnabled()) applog.appLog("[win] WM_APP_CREATE_EXTERNAL_WINDOW received\n", .{});
            if (getApp(hwnd)) |app| {
                // Update external window colors (border/icon) before creating windows
                // This ensures colors are available for popupmenu even if cmdline wasn't shown
                external_windows.updateExternalWindowColors(app);

                // Process all pending external window requests
                app.mu.lock();
                const pending = app.pending_external_windows.toOwnedSlice(app.alloc) catch {
                    app.mu.unlock();
                    return 0;
                };
                app.mu.unlock();

                for (pending) |req| {
                    external_windows.createExternalWindowOnUIThread(app, req);
                }
                app.alloc.free(pending);
            }
            return 0;
        },

        WM_APP_CURSOR_GRID_CHANGED => {
            if (applog.isEnabled()) applog.appLog("[win] WM_APP_CURSOR_GRID_CHANGED received grid_id={d}\n", .{wParam});
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
                    if (applog.isEnabled()) applog.appLog("[win] cursor stayed on same grid_id={d}, no activation change\n", .{grid_id});
                    return 0;
                }

                if (ext_hwnd) |eh| {
                    // Cursor moved to external grid - activate that window
                    _ = c.SetForegroundWindow(eh);
                    if (applog.isEnabled()) applog.appLog("[win] activated external window for grid_id={d}\n", .{grid_id});
                } else {
                    // Cursor moved to global grid - activate main window
                    _ = c.SetForegroundWindow(hwnd);
                    // Only invalidate if no paint is already pending from on_vertices_row/partial.
                    // When dirty_rows, paint_full, or paint_rects is set, the pending WM_PAINT
                    // will handle cursor rendering as part of the normal draw.
                    app.mu.lock();
                    const has_pending = app.paint_rects.items.len > 0;
                    app.mu.unlock();
                    if (!has_pending) {
                        _ = c.InvalidateRect(hwnd, null, c.FALSE);
                    }
                    if (applog.isEnabled()) applog.appLog("[win] activated main window (cursor on grid_id={d}) pending={}\n", .{ grid_id, has_pending });
                }
            }
            return 0;
        },

        WM_APP_CLOSE_EXTERNAL_WINDOW => {
            const grid_id: i64 = @bitCast(wParam);
            if (applog.isEnabled()) applog.appLog("[win] WM_APP_CLOSE_EXTERNAL_WINDOW received grid_id={d}\n", .{grid_id});
            if (getApp(hwnd)) |app| {
                external_windows.closeExternalWindowOnUIThread(app, grid_id);
            }
            return 0;
        },

        WM_APP_MSG_SHOW => {
            if (applog.isEnabled()) applog.appLog("[win] WM_APP_MSG_SHOW received\n", .{});
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
                            messages.updateMiniText(app, .showmode, text);
                            messages.updateMiniWindows(app);

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
                            messages.showMessageWindowOnUIThread(app, dm);
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
                            messages.showMessageWindowOnUIThread(app, dm);
                            if (dm.timeout > 0) {
                                _ = c.KillTimer(hwnd, TIMER_MSG_AUTOHIDE);
                                const timeout_ms: c.UINT = @intFromFloat(dm.timeout * 1000);
                                _ = c.SetTimer(hwnd, TIMER_MSG_AUTOHIDE, timeout_ms, null);
                            }
                        },
                        .split => {
                            messages.showMessageWindowOnUIThread(app, dm);
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
            if (applog.isEnabled()) applog.appLog("[win] WM_APP_MSG_CLEAR received\n", .{});
            if (getApp(hwnd)) |app| {
                // Kill auto-hide timer
                _ = c.KillTimer(hwnd, TIMER_MSG_AUTOHIDE);
                messages.hideMessageWindow(app);
                // Note: Do NOT hide split view on msg_clear.
                // Split view should remain visible until user manually closes it (Esc/q/Enter/Space).
                // This matches noice.nvim's long_message_to_split behavior.
            }
            return 0;
        },

        WM_APP_MINI_UPDATE => {
            const mini_id: MiniWindowId = @enumFromInt(@as(u2, @truncate(wParam)));
            if (applog.isEnabled()) applog.appLog("[win] WM_APP_MINI_UPDATE received: {s}\n", .{@tagName(mini_id)});
            if (getApp(hwnd)) |app| {
                messages.updateMiniWindows(app);
            }
            return 0;
        },

        WM_APP_UPDATE_EXT_FLOAT_POS => {
            if (applog.isEnabled()) applog.appLog("[win] WM_APP_UPDATE_EXT_FLOAT_POS received\n", .{});
            if (getApp(hwnd)) |app| {
                messages.updateExtFloatPositions(app);
            }
            return 0;
        },

        WM_APP_RESIZE_POPUPMENU => {
            const grid_id: i64 = @bitCast(wParam);
            if (applog.isEnabled()) applog.appLog("[win] WM_APP_RESIZE_POPUPMENU received grid_id={d}\n", .{grid_id});
            if (getApp(hwnd)) |app| {
                messages.resizeExternalWindowDeferred(app, grid_id);
            }
            return 0;
        },

        WM_APP_CLIPBOARD_GET => {
            if (applog.isEnabled()) applog.appLog("[win] WM_APP_CLIPBOARD_GET received\n", .{});
            if (getApp(hwnd)) |app| {
                dialogs.handleClipboardGetOnUIThread(app);
            }
            return 0;
        },

        WM_APP_CLIPBOARD_SET => {
            if (applog.isEnabled()) applog.appLog("[win] WM_APP_CLIPBOARD_SET received\n", .{});
            if (getApp(hwnd)) |app| {
                dialogs.handleClipboardSetOnUIThread(app);
            }
            return 0;
        },

        WM_APP_SSH_AUTH_PROMPT => {
            if (applog.isEnabled()) applog.appLog("[win] WM_APP_SSH_AUTH_PROMPT received\n", .{});
            if (getApp(hwnd)) |app| {
                dialogs.handleSSHAuthPromptOnUIThread(app);
            }
            return 0;
        },

        WM_APP_UPDATE_CURSOR_BLINK => {
            if (getApp(hwnd)) |app| {
                input.updateCursorBlinking(hwnd, app);
            }
            return 0;
        },

        WM_APP_IME_OFF => {
            input.setIMEOff(hwnd);
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

        WM_APP_UPDATE_CMDLINE_COLORS => {
            // Update cmdline border/icon colors from core highlights.
            // Called from UI thread (via PostMessage from onCmdlineShow) to avoid
            // deadlock when calling zonvie_core_get_hl_by_name from callback context.
            if (getApp(hwnd)) |app| {
                external_windows.updateExternalWindowColors(app);
            }
            return 0;
        },

        WM_APP_SET_TITLE => {
            // Deferred SetWindowTextW from onSetTitle callback.
            // SetWindowTextW from the core thread would be an implicit cross-thread
            // SendMessage(WM_SETTEXT), blocking with grid_mu held → deadlock.
            if (getApp(hwnd)) |app| {
                var local_buf: [512]u16 = undefined;
                app.mu.lock();
                const len = app.pending_title_len;
                if (len > 0) {
                    @memcpy(local_buf[0..len], app.pending_title[0..len]);
                }
                app.mu.unlock();
                if (len > 0) {
                    local_buf[len] = 0; // null terminate
                    _ = c.SetWindowTextW(hwnd, &local_buf);
                }
            }
            return 0;
        },

        WM_APP_DEFERRED_WIN_POS => {
            // Deferred SetWindowPos from onWinResizeEqual/onWinRotate callbacks.
            // SetWindowPos from the core thread sends WM_SIZE to the UI thread,
            // which calls updateLayoutToCore → grid_mu.lock() → deadlock.
            if (getApp(hwnd)) |app| {
                var local_ops: [App.MAX_DEFERRED_WIN_OPS]App.DeferredWinOp = undefined;
                var count: usize = 0;
                app.mu.lock();
                count = @min(app.deferred_win_ops_count, App.MAX_DEFERRED_WIN_OPS);
                if (count > 0) {
                    @memcpy(local_ops[0..count], app.deferred_win_ops[0..count]);
                    app.deferred_win_ops_count = 0;
                }
                app.mu.unlock();
                for (local_ops[0..count]) |op| {
                    _ = c.SetWindowPos(op.hwnd, null, op.x, op.y, op.w, op.h, op.flags);
                }
            }
            return 0;
        },

        c.WM_TIMER => {
            if (wParam == TIMER_MSG_AUTOHIDE) {
                if (applog.isEnabled()) applog.appLog("[win] WM_TIMER: message window auto-hide\n", .{});
                // Kill the timer and hide message window
                _ = c.KillTimer(hwnd, TIMER_MSG_AUTOHIDE);
                if (getApp(hwnd)) |app| {
                    messages.hideMessageWindow(app);
                }
            } else if (wParam == TIMER_MINI_AUTOHIDE) {
                if (applog.isEnabled()) applog.appLog("[win] WM_TIMER: mini window auto-hide\n", .{});
                // Kill the timer and hide mini window (showmode slot)
                _ = c.KillTimer(hwnd, TIMER_MINI_AUTOHIDE);
                if (getApp(hwnd)) |app| {
                    messages.updateMiniText(app, .showmode, "");
                    messages.updateMiniWindows(app);
                }
            } else if (wParam == TIMER_SCROLLBAR_AUTOHIDE) {
                // Start fade-out animation after timeout
                _ = c.KillTimer(hwnd, TIMER_SCROLLBAR_AUTOHIDE);
                if (getApp(hwnd)) |app| {
                    app.scrollbar_hide_timer = 0;
                    scrollbar.hideScrollbar(hwnd, app);
                }
            } else if (wParam == TIMER_SCROLLBAR_FADE) {
                // Update scrollbar fade animation
                if (getApp(hwnd)) |app| {
                    scrollbar.updateScrollbarFade(hwnd, app);
                }
            } else if (wParam == TIMER_SCROLLBAR_REPEAT) {
                // Continuous page scroll while holding mouse on track
                if (getApp(hwnd)) |app| {
                    if (app.scrollbar_repeat_dir != 0) {
                        scrollbar.scrollbarPageScroll(app, app.scrollbar_repeat_dir);
                        // After first delay, switch to faster interval
                        _ = c.KillTimer(hwnd, TIMER_SCROLLBAR_REPEAT);
                        app.scrollbar_repeat_timer = c.SetTimer(hwnd, TIMER_SCROLLBAR_REPEAT, SCROLLBAR_REPEAT_INTERVAL, null);
                    }
                }
            } else if (wParam == TIMER_CURSOR_BLINK) {
                if (applog.isEnabled()) applog.appLog("[win] WM_TIMER: cursor blink\n", .{});
                if (getApp(hwnd)) |app| {
                    input.handleCursorBlinkTimer(hwnd, app);
                }
            } else if (wParam == TIMER_DEVCONTAINER_POLL) {
                // Poll for devcontainer up completion
                if (dialogs.g_devcontainer_up_done.load(.seq_cst)) {
                    if (applog.isEnabled()) applog.appLog("[win] WM_TIMER: devcontainer up completed\n", .{});
                    _ = c.KillTimer(hwnd, TIMER_DEVCONTAINER_POLL);

                    if (getApp(hwnd)) |app| {
                        if (dialogs.g_devcontainer_up_success.load(.seq_cst)) {
                            // Success: update label and start nvim with devcontainer exec
                            dialogs.updateDevcontainerProgressLabel(std.unicode.utf8ToUtf16LeStringLiteral("Connecting..."));

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
                                if (applog.isEnabled()) applog.appLog("[win] devcontainer exec command: {s}\n", .{nvim_cmd_slice});

                                // Start nvim
                                const nvim_path_z = app.alloc.dupeZ(u8, nvim_cmd_slice) catch null;
                                defer if (nvim_path_z) |p| app.alloc.free(p);
                                const nvim_path_ptr: ?[*:0]const u8 = if (nvim_path_z) |p| p.ptr else null;
                                if (applog.isEnabled()) applog.appLog("[win] starting neovim via devcontainer exec\n", .{});
                                const start_ok = core.zonvie_core_start(app.corep, nvim_path_ptr, 24, 80);
                                if (applog.isEnabled()) applog.appLog("[win] zonvie_core_start -> {d}\n", .{start_ok});

                                // Renderer is already initialized at this point; notify with correct rows/cols.
                                core.zonvie_core_notify_layout_ready(app.corep, app.surface.rows, app.surface.cols);

                                app.devcontainer_up_pending = false;
                                app.devcontainer_nvim_started = true;
                            }

                            // Hide progress dialog
                            dialogs.hideDevcontainerProgressDialog();
                        } else {
                            // Failure: hide dialog and show error
                            dialogs.hideDevcontainerProgressDialog();
                            app.devcontainer_up_pending = false;
                            if (applog.isEnabled()) applog.appLog("[win] devcontainer up failed\n", .{});
                            // TODO: show error message to user
                        }
                    }
                }
            } else if (wParam == TIMER_REPOSITION_FLOATS) {
                _ = c.KillTimer(hwnd, TIMER_REPOSITION_FLOATS);
                if (getApp(hwnd)) |app| {
                    messages.updateExtFloatPositions(app);
                    messages.updateMiniWindows(app);
                }
            } else if (wParam == TIMER_TRAY_INIT) {
                _ = c.KillTimer(hwnd, TIMER_TRAY_INIT);
                if (getApp(hwnd)) |app| {
                    app.tray_icon = TrayIcon.init(hwnd);
                    if (app.tray_icon) |*tray| {
                        tray.add();
                    }
                    if (applog.isEnabled()) applog.appLog("[win] TIMER_TRAY_INIT: tray icon initialized\n", .{});
                }
            } else if (wParam == TIMER_QUIT_TIMEOUT) {
                // Neovim not responding to quit request - show force quit dialog
                if (applog.isEnabled()) applog.appLog("[win] WM_TIMER: quit timeout - Neovim not responding\n", .{});
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
            if (applog.isEnabled()) applog.appLog("[win] WM_APP_DEFERRED_INIT: begin", .{});

            // Timing measurement for startup diagnostics
            const deferred_log_enabled = applog.isEnabled();
            var freq: c.LARGE_INTEGER = undefined;
            var t0: c.LARGE_INTEGER = undefined;
            var t1: c.LARGE_INTEGER = undefined;
            var t2: c.LARGE_INTEGER = undefined;
            if (deferred_log_enabled) {
                _ = c.QueryPerformanceFrequency(&freq);
                _ = c.QueryPerformanceCounter(&t0);
            }

            if (getApp(hwnd)) |app| {
                var atlas: dwrite_d2d.Renderer = undefined;

                if (app.early_core_init_done) {
                    // Native mode: core, config, nvim already initialized in doEarlyCoreInit.
                    // Reuse early_atlas for renderer setup.
                    if (deferred_log_enabled) applog.appLog("[win] DEFERRED_INIT: early_core_init path\n", .{});
                    atlas = app.early_atlas orelse return 0;
                    app.early_atlas = null;
                } else {
                    // WSL/SSH/devcontainer mode: full initialization path
                    if (deferred_log_enabled) applog.appLog("[win] DEFERRED_INIT: full init path\n", .{});

                    var cb = makeCoreCbs();
                    if (deferred_log_enabled) _ = c.QueryPerformanceCounter(&t1);
                    app.corep = core.zonvie_core_create(&cb, @sizeOf(core.Callbacks), app);
                    if (deferred_log_enabled) {
                        _ = c.QueryPerformanceCounter(&t2);
                        const core_create_ms = @divTrunc((t2.QuadPart - t1.QuadPart) * 1000, freq.QuadPart);
                        applog.appLog("  [TIMING] zonvie_core_create: {d}ms", .{core_create_ms});
                    }

                    // Load config into core for message routing
                    if (config_mod.getConfigFilePath(app.alloc)) |config_path| {
                        defer app.alloc.free(config_path);
                        const config_path_z = app.alloc.dupeZ(u8, config_path) catch null;
                        if (config_path_z) |cpath| {
                            defer app.alloc.free(cpath);
                            _ = core.zonvie_core_load_config(app.corep, cpath.ptr);
                        }
                    } else |_| {}

                    // Configure core settings
                    setLogEnabledViaCore(app, app.config.log.enabled);
                    if (app.ext_cmdline_enabled) core.zonvie_core_set_ext_cmdline(app.corep, 1);
                    if (app.config.popup.external) core.zonvie_core_set_ext_popupmenu(app.corep, 1);
                    if (app.ext_messages_enabled) core.zonvie_core_set_ext_messages(app.corep, 1);
                    if (app.ext_tabline_enabled) core.zonvie_core_set_ext_tabline(app.corep, 1);
                    if (app.ext_windows_enabled) core.zonvie_core_set_ext_windows(app.corep, 1);
                    core.zonvie_core_set_background_opacity(app.corep, app.config.window.opacity);
                    core.zonvie_core_set_glyph_cache_size(
                        app.corep,
                        app.config.performance.glyph_cache_ascii_size,
                        app.config.performance.glyph_cache_non_ascii_size,
                    );
                    core.zonvie_core_set_atlas_size(app.corep, app.config.performance.atlas_size);

                    // DWrite metrics init
                    const initial_font = if (app.config.font.family.len > 0) app.config.font.family else "Consolas";
                    const initial_pt: f32 = if (app.config.font.size > 0.0) app.config.font.size else 14.0;

                    if (deferred_log_enabled) _ = c.QueryPerformanceCounter(&t1);
                    atlas = dwrite_d2d.Renderer.initMetrics(app.alloc, hwnd, initial_font, initial_pt) catch |e| {
                        if (deferred_log_enabled) applog.appLog("dwrite_d2d.Renderer.initMetrics failed: {any}\n", .{e});
                        return 0;
                    };
                    if (deferred_log_enabled) {
                        _ = c.QueryPerformanceCounter(&t2);
                        const dwrite_metrics_ms = @divTrunc((t2.QuadPart - t1.QuadPart) * 1000, freq.QuadPart);
                        applog.appLog("  [TIMING] dwrite_d2d.Renderer.initMetrics: {d}ms", .{dwrite_metrics_ms});
                    }

                    app.dpi_scale = @as(f32, @floatFromInt(atlas.dpi)) / 96.0;
                    app.cell_w_px = atlas.cellW();
                    app.cell_h_px = atlas.cellH();
                    updateRowsColsFromClientForce(hwnd, app);

                    // Build nvim command and start nvim
                    var nvim_cmd_buf: [1024]u8 = undefined;
                    var nvim_cmd_slice: []const u8 = undefined;

                    const effective_nvim = app.cli_nvim_path orelse app.config.neovim.path;
                    const quoted_nvim: []const u8 = blk: {
                        if (std.mem.indexOfScalar(u8, effective_nvim, ' ') != null) {
                            const buf = app.alloc.alloc(u8, effective_nvim.len + 2) catch
                                break :blk effective_nvim;
                            buf[0] = '\'';
                            @memcpy(buf[1 .. 1 + effective_nvim.len], effective_nvim);
                            buf[1 + effective_nvim.len] = '\'';
                            break :blk buf;
                        }
                        break :blk effective_nvim;
                    };
                    defer if (quoted_nvim.ptr != effective_nvim.ptr) app.alloc.free(@constCast(quoted_nvim));

                    if (app.wsl_mode) {
                        var fbs = std.io.fixedBufferStream(&nvim_cmd_buf);
                        const writer = fbs.writer();
                        writer.writeAll("wsl.exe") catch {};
                        if (app.wsl_distro) |distro| {
                            writer.print(" -d {s}", .{distro}) catch {};
                        }
                        writer.writeAll(" --shell-type login -- nvim --embed") catch {};
                        nvim_cmd_slice = nvim_cmd_buf[0..fbs.pos];
                    } else if (app.ssh_mode) {
                        if (app.ssh_host) |host| {
                            var fbs = std.io.fixedBufferStream(&nvim_cmd_buf);
                            const writer = fbs.writer();
                            writer.writeAll("ssh-askpass ") catch {};
                            writer.writeAll("C:\\Windows\\System32\\OpenSSH\\ssh.exe") catch {};
                            if (app.ssh_port) |port| {
                                writer.print(" -p {d}", .{port}) catch {};
                            }
                            if (app.ssh_identity) |identity| {
                                writer.print(" -i \"{s}\"", .{identity}) catch {};
                                writer.writeAll(" -o PasswordAuthentication=no -o KbdInteractiveAuthentication=no") catch {};
                            }
                            writer.writeAll(" -o StrictHostKeyChecking=accept-new") catch {};
                            const remote_nvim = app.cli_nvim_path orelse "nvim";
                            writer.print(" {s} \"'{s}'\" --headless --embed", .{ host, remote_nvim }) catch {};
                            nvim_cmd_slice = nvim_cmd_buf[0..fbs.pos];

                            if (app.ssh_password) |pwd| {
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
                            nvim_cmd_slice = quoted_nvim;
                        }
                    } else if (app.devcontainer_mode) devcontainer_block: {
                        if (app.devcontainer_workspace) |workspace| {
                            if (app.devcontainer_rebuild) {
                                dialogs.showDevcontainerProgressDialog(std.unicode.utf8ToUtf16LeStringLiteral("Building devcontainer..."));
                                dialogs.g_devcontainer_up_done.store(false, .seq_cst);
                                dialogs.g_devcontainer_up_success.store(false, .seq_cst);
                                const thread = std.Thread.spawn(.{}, dialogs.runDevcontainerUpThread, .{ workspace, app.devcontainer_config, app.alloc }) catch |e| {
                                    if (deferred_log_enabled) applog.appLog("[win] failed to spawn devcontainer up thread: {any}\n", .{e});
                                    dialogs.hideDevcontainerProgressDialog();
                                    nvim_cmd_slice = quoted_nvim;
                                    break :devcontainer_block;
                                };
                                thread.detach();
                                app.devcontainer_up_pending = true;
                                _ = c.SetTimer(hwnd, TIMER_DEVCONTAINER_POLL, DEVCONTAINER_POLL_INTERVAL, null);
                                break :devcontainer_block;
                            } else {
                                dialogs.showDevcontainerProgressDialog(std.unicode.utf8ToUtf16LeStringLiteral("Connecting..."));
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
                            }
                        } else {
                            nvim_cmd_slice = quoted_nvim;
                        }
                    } else {
                        nvim_cmd_slice = quoted_nvim;
                    }

                    // Start nvim
                    if (!app.devcontainer_up_pending) {
                        const nvim_path_z = app.alloc.dupeZ(u8, nvim_cmd_slice) catch null;
                        defer if (nvim_path_z) |p| app.alloc.free(p);
                        const nvim_path_ptr: ?[*:0]const u8 = if (nvim_path_z) |p| p.ptr else null;
                        _ = core.zonvie_core_start(app.corep, nvim_path_ptr, app.surface.rows, app.surface.cols);
                        app.nvim_spawned = true;
                        if (app.devcontainer_mode and !app.devcontainer_rebuild) {
                            dialogs.hideDevcontainerProgressDialog();
                        }
                    }

                    // Create D3D11 device (inline, not threaded for remote modes)
                    const d3d_result = d3d11.Renderer.createDeviceOnly() catch null;
                    if (d3d_result) |result| {
                        app.d3d_device = result.device;
                        app.d3d_ctx = result.ctx;
                    }

                    // DWM custom titlebar: post SWP_FRAMECHANGED (fallback path only)
                    if (!app.early_core_init_done and app.ext_tabline_enabled and app.tabline_style == .titlebar) {
                        _ = c.PostMessageW(hwnd, app_mod.WM_APP_SWP_FRAMECHANGED, 0, 0);
                        if (deferred_log_enabled) applog.appLog("[win] deferred_init: SWP_FRAMECHANGED posted (fallback path)\n", .{});
                    }
                }

                // ============================================================
                // PHASE 2: Initialize renderers
                // ============================================================

                // Assign atlas BEFORE renderer creation so callbacks can use it
                app.mu.lock();
                app.atlas = atlas;
                app.mu.unlock();

                // Notify layout ready BEFORE renderer setup (atlas is ready, unblock RPC thread)
                core.zonvie_core_notify_layout_ready(app.corep, app.surface.rows, app.surface.cols);
                if (deferred_log_enabled) applog.appLog("[win] notified layout ready: rows={d} cols={d}\n", .{ app.surface.rows, app.surface.cols });

                // Complete DWrite/D2D: create D2D device context from D3D11 device.
                if (deferred_log_enabled) _ = c.QueryPerformanceCounter(&t1);

                // Join D3D11 init thread if it was spawned (native mode)
                if (app.d3d_init_thread) |thr| {
                    thr.join();
                    app.d3d_init_thread = null;
                    if (deferred_log_enabled) applog.appLog("[win] d3d_init_thread joined\n", .{});
                }

                // If no D3D device after thread join, create inline
                if (app.d3d_device == null) {
                    const d3d_inline = d3d11.Renderer.createDeviceOnly() catch null;
                    if (d3d_inline) |result| {
                        app.d3d_device = result.device;
                        app.d3d_ctx = result.ctx;
                    }
                }

                if (app.d3d_device) |d3d_dev| {
                    if (app.atlas) |*a| {
                        a.initD2DDeviceContext(d3d_dev) catch |e| {
                            if (deferred_log_enabled) applog.appLog("dwrite_d2d initD2DDeviceContext failed: {any}, trying legacy\n", .{e});
                            a.initRenderTarget() catch {};
                        };
                    }
                } else {
                    if (app.atlas) |*a| {
                        a.initRenderTarget() catch {};
                    }
                }
                // Check we have at least one render path
                if (app.atlas) |*a| {
                    if (a.d2d_device_ctx == null and a.rt == null) {
                        if (deferred_log_enabled) applog.appLog("dwrite_d2d: no D2D render path available\n", .{});
                        a.deinit();
                        app.atlas = null;
                        app.renderer = null;
                        return 0;
                    }
                }
                if (deferred_log_enabled) {
                    _ = c.QueryPerformanceCounter(&t2);
                    const rt_ms = @divTrunc((t2.QuadPart - t1.QuadPart) * 1000, freq.QuadPart);
                    applog.appLog("  [TIMING] D2D context init: {d}ms", .{rt_ms});
                }

                // D3D11 GPU renderer
                const render_hwnd = if (app.ext_tabline_enabled and app.content_hwnd != null)
                    app.content_hwnd.?
                else
                    hwnd;

                if (deferred_log_enabled) _ = c.QueryPerformanceCounter(&t1);
                const gpu = blk: {
                    if (app.d3d_device != null and app.d3d_ctx != null) {
                        break :blk d3d11.Renderer.initWithDevice(app.alloc, render_hwnd, app.config.window.opacity, app.d3d_device.?, app.d3d_ctx.?) catch |e| {
                            if (deferred_log_enabled) applog.appLog("d3d11.Renderer.initWithDevice failed: {any}\n", .{e});
                            return 0;
                        };
                    }
                    break :blk d3d11.Renderer.init(app.alloc, render_hwnd, app.config.window.opacity) catch |e| {
                        if (deferred_log_enabled) applog.appLog("d3d11.Renderer.init failed: {any}\n", .{e});
                        return 0;
                    };
                };
                if (deferred_log_enabled) {
                    _ = c.QueryPerformanceCounter(&t2);
                    const d3d_ms = @divTrunc((t2.QuadPart - t1.QuadPart) * 1000, freq.QuadPart);
                    applog.appLog("  [TIMING] d3d11.Renderer.init: {d}ms", .{d3d_ms});
                }

                app.mu.lock();
                app.renderer = gpu;
                app.mu.unlock();

                if (deferred_log_enabled) applog.appLog("  renderer created ok", .{});

                // Process pending glyphs
                {
                    app.mu.lock();
                    const pending_count = app.pending_glyphs.items.len;
                    app.mu.unlock();

                    if (pending_count > 0) {
                        if (deferred_log_enabled) applog.appLog("  processing {d} pending glyphs", .{pending_count});
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

                // Show window if pending (renderer now ready)
                if (app.pending_show_window) {
                    app.pending_show_window = false;
                    _ = c.ShowWindow(hwnd, c.SW_SHOW);
                    _ = c.PostMessageW(hwnd, app_mod.WM_APP_POST_SHOW_INIT, 0, 0);
                    if (deferred_log_enabled) {
                        var t_show: c.LARGE_INTEGER = undefined;
                        _ = c.QueryPerformanceCounter(&t_show);
                        const show_ms = @divTrunc((t_show.QuadPart - app_mod.g_startup_t0.QuadPart) * 1000, app_mod.g_startup_freq.QuadPart);
                        applog.appLog("[TIMING] ShowWindow (deferred, renderer ready): {d}ms from main()\n", .{show_ms});
                    }
                }

                // Update rows/cols + layout (non-titlebar mode)
                if (!(app.ext_tabline_enabled and app.tabline_style == .titlebar)) {
                    updateRowsColsFromClientForce(hwnd, app);
                    updateLayoutToCore(hwnd, app);
                }

                if (deferred_log_enabled) {
                    _ = c.QueryPerformanceCounter(&t2);
                    const total_ms = @divTrunc((t2.QuadPart - t0.QuadPart) * 1000, freq.QuadPart);
                    applog.appLog("[win] WM_APP_DEFERRED_INIT: end (total {d}ms)", .{total_ms});
                }

                // Force a repaint now that renderer is ready
                _ = c.InvalidateRect(hwnd, null, 0);
            }
            return 0;
        },

        WM_APP_SHOW_WINDOW => {
            if (getApp(hwnd)) |app| {
                if (app.renderer == null) {
                    app.pending_show_window = true;
                    return 0;
                }
            }
            _ = c.ShowWindow(hwnd, c.SW_SHOW);
            _ = c.PostMessageW(hwnd, app_mod.WM_APP_POST_SHOW_INIT, 0, 0);
            if (applog.isEnabled()) {
                var t_show: c.LARGE_INTEGER = undefined;
                _ = c.QueryPerformanceCounter(&t_show);
                const elapsed_ms = @divTrunc((t_show.QuadPart - app_mod.g_startup_t0.QuadPart) * 1000, app_mod.g_startup_freq.QuadPart);
                applog.appLog("[TIMING] ShowWindow (first flush): {d}ms from main()\n", .{elapsed_ms});
            }
            return 0;
        },

        WM_APP_POST_SHOW_INIT => {
            // Deferred tray icon initialization (after window is shown)
            _ = c.SetTimer(hwnd, TIMER_TRAY_INIT, TRAY_INIT_DELAY_MS, null);
            return 0;
        },

        WM_APP_SWP_FRAMECHANGED => {
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
            if (applog.isEnabled()) applog.appLog("[win] WM_APP_SWP_FRAMECHANGED: applied\n", .{});
            return 0;
        },

        c.WM_KEYDOWN, c.WM_SYSKEYDOWN => {
            if (getApp(hwnd)) |app| {
                const vk: u32 = @intCast(wParam);
                const mods = input.queryMods();

                // Windows keycode is passed as 0x10000|VK so Zig core can distinguish.
                const keycode: u32 = input.KEYCODE_WINVK_FLAG | vk;

                // scancode is in bits 16..23 of lParam
                const scancode: u32 = @intCast((@as(u32, @intCast(lParam)) >> 16) & 0xFF);

                const has_ctrl_alt = (mods & (input.MOD_CTRL | input.MOD_ALT)) != 0;

                // Check if IME is composing
                app.mu.lock();
                const ime_composing = app.ime_composing;
                app.mu.unlock();

                // 1) Special keys always go through send_key_event (chars=nil)
                //    BUT skip VK_RETURN and VK_BACK when IME is composing to avoid double-input
                if (input.isSpecialVk(vk)) {
                    if (ime_composing and (vk == c.VK_RETURN or vk == c.VK_BACK)) {
                        // Let IME handle Enter/Backspace - committed text comes via WM_IME_CHAR,
                        // then the key comes via WM_CHAR after WM_IME_ENDCOMPOSITION.
                        // Return 0 to prevent DefWindowProcW from also translating.
                        return 0;
                    } else {
                        input.sendKeyEventToCore(app, keycode, mods, null, null);
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

                    const pair = input.toUnicodePairUtf8(
                        vk,
                        scancode,
                        &tmp_chars,
                        &tmp_ign,
                        &out_chars,
                        &out_ign,
                    );

                    input.sendKeyEventToCore(app, keycode, mods, pair.chars, pair.ign);
                    return 0;
                }

                // 3) Otherwise (normal text, Shift-only, IME): let WM_CHAR handle.
                // Do not consume here.
            }
        },

        c.WM_CHAR, c.WM_SYSCHAR => {
            if (getApp(hwnd)) |app| {
                const mods = input.queryMods();

                // If Ctrl/Alt are down, WM_CHAR often becomes ASCII control => ignore
                // (WM_KEYDOWN path handled Ctrl/Alt combos).
                if ((mods & (input.MOD_CTRL | input.MOD_ALT)) != 0) {
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
                const s = input.utf16UnitsToUtf8(&out, ch0, null) orelse return 0;

                // keycode=0 means "text input" (Zig will take chars path).
                input.sendKeyEventToCore(app, 0, mods, s, s);
                return 0;
            }
        },

        // --- IME message handling ---
        c.WM_IME_STARTCOMPOSITION => {
            if (applog.isEnabled()) applog.appLog("[IME] WM_IME_STARTCOMPOSITION\n", .{});
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
                input.positionImeCandidateWindow(hwnd, app);
            }
            return 0;
        },

        c.WM_IME_COMPOSITION => {
            if (applog.isEnabled()) applog.appLog("[IME] WM_IME_COMPOSITION lParam=0x{x}\n", .{@as(u32, @intCast(lParam & 0xFFFFFFFF))});
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
                            input.updateImeCompositionUtf8(app);
                            if (applog.isEnabled()) applog.appLog("[IME] composition_str len={d}\n", .{app.ime_composition_str.items.len});
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
                        if (applog.isEnabled()) applog.appLog("[IME] GCS_COMPATTR attr_len={d} lparam_has_flag={d}\n", .{
                            attr_len,
                            @intFromBool((lparam_u & c.GCS_COMPATTR) != 0),
                        });
                        if (attr_len > 0) {
                            var attr_buf: [256]u8 = undefined;
                            const len: usize = @intCast(@min(@as(usize, @intCast(@max(0, attr_len))), 256));
                            _ = c.ImmGetCompositionStringW(himc, c.GCS_COMPATTR, &attr_buf, @intCast(len));

                            // Debug: log all attributes
                            if (applog.isEnabled()) {
                                applog.appLog("[IME] COMPATTR len={d} attrs=", .{len});
                                for (0..len) |idx| {
                                    applog.appLog("{x} ", .{attr_buf[idx]});
                                }
                                applog.appLog("\n", .{});
                            }

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
                            if (applog.isEnabled()) applog.appLog("[IME] target_start={d} target_end={d}\n", .{ app.ime_target_start, app.ime_target_end });
                            app.mu.unlock();
                        }
                    }

                    // Update preedit overlay directly
                    input.updateImePreeditOverlay(hwnd, app);
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
                input.hideImePreeditOverlay(app);
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
                const s = input.utf16UnitsToUtf8(&out, ch, null) orelse return 0;

                input.sendKeyEventToCore(app, 0, 0, s, s);
                return 0;
            }
        },

        c.WM_MOUSEWHEEL => {
            if (getApp(hwnd)) |app| {
                external_windows.handleMouseWheel(hwnd, wParam, lParam, app, 1, &app.scroll_accum, false);
                return 0;
            }
        },

        c.WM_MOUSEHWHEEL => {
            if (getApp(hwnd)) |app| {
                external_windows.handleMouseWheel(hwnd, wParam, lParam, app, 1, &app.h_scroll_accum, true);
                return 0;
            }
        },

        // WM_VSCROLL not used (custom D3D11 scrollbar)

        WM_APP_UPDATE_SCROLLBAR => {
            if (getApp(hwnd)) |app| {
                // Clear pending flag BEFORE processing (allows new PostMessage during updateScrollbar)
                app.scrollbar_update_pending.store(false, .release);
                scrollbar.updateScrollbar(hwnd, app);
                return 0;
            }
        },

        // Mouse button events
        c.WM_LBUTTONDOWN, c.WM_RBUTTONDOWN, c.WM_MBUTTONDOWN => {
            if (getApp(hwnd)) |app| {
                // Extract position from lParam
                const x: i16 = @bitCast(@as(u16, @truncate(@as(usize, @bitCast(lParam)))));
                const y: i16 = @bitCast(@as(u16, @truncate(@as(usize, @bitCast(lParam)) >> 16)));

                // Check tabline/sidebar area first (when ext_tabline enabled)
                if (app.ext_tabline_enabled) {
                    if (app.tabline_style == .titlebar) {
                        if (msg == c.WM_LBUTTONDOWN and y < app.scalePx(TablineState.TAB_BAR_HEIGHT)) {
                            tabline_mod.handleTablineMouseDown(app, hwnd, @as(c_int, x), @as(c_int, y));
                            return 0;
                        }
                    } else if (app.tabline_style == .sidebar) {
                        var client_rect_sb: c.RECT = undefined;
                        _ = c.GetClientRect(hwnd, &client_rect_sb);
                        const sidebar_w_px = app.scalePx(@as(c_int, @intCast(app.sidebar_width_px)));
                        const in_sidebar = if (app.sidebar_position_right)
                            x >= @as(i16, @intCast(client_rect_sb.right - sidebar_w_px))
                        else
                            x < @as(i16, @intCast(sidebar_w_px));
                        if (in_sidebar) {
                            // Left button: handle sidebar interaction
                            // Right/middle button: consume event to prevent Neovim input
                            if (msg == c.WM_LBUTTONDOWN) {
                                tabline_mod.handleSidebarMouseDown(app, hwnd, @as(c_int, x), @as(c_int, y));
                            }
                            return 0;
                        }
                    }
                }

                // Check scrollbar hit first (left button only)
                if (msg == c.WM_LBUTTONDOWN) {
                    if (scrollbar.scrollbarMouseDown(hwnd, app, @as(i32, x), @as(i32, y))) {
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
                // When ext_tabline sidebar is enabled, subtract sidebar width to get content-relative X coordinate
                const content_x: i32 = if (app.ext_tabline_enabled and app.tabline_style == .sidebar and !app.sidebar_position_right)
                    @as(i32, x) - @as(i32, app.scalePx(@as(c_int, @intCast(app.sidebar_width_px))))
                else
                    @as(i32, x);
                const col: i32 = if (cell_w > 0) @divTrunc(@max(0, content_x), @as(i32, @intCast(cell_w))) else 0;
                // When ext_tabline titlebar is enabled, subtract tabbar height to get content-relative Y coordinate
                const content_y: i32 = if (app.ext_tabline_enabled and app.tabline_style == .titlebar and app.content_hwnd == null)
                    @as(i32, y) - @as(i32, app.scalePx(TablineState.TAB_BAR_HEIGHT))
                else
                    @as(i32, y);
                const row: i32 = if (row_h > 0) @divTrunc(@max(0, content_y), @as(i32, @intCast(row_h))) else 0;

                // Build modifier string
                var mod_buf: [5]u8 = .{ 0, 0, 0, 0, 0 };
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
                if (c.GetKeyState(c.VK_LWIN) < 0 or c.GetKeyState(c.VK_RWIN) < 0) {
                    mod_buf[mod_len] = 'D';
                    mod_len += 1;
                }
                mod_buf[mod_len] = 0;

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

                // Check tabline/sidebar drag end or area click
                if (app.ext_tabline_enabled) {
                    if (app.tabline_style == .titlebar) {
                        if (msg == c.WM_LBUTTONUP and (app.tabline_state.dragging_tab != null or y_up < app.scalePx(TablineState.TAB_BAR_HEIGHT))) {
                            tabline_mod.handleTablineMouseUp(app, hwnd, @as(c_int, x_up), @as(c_int, y_up));
                            return 0;
                        }
                    } else if (app.tabline_style == .sidebar) {
                        if (msg == c.WM_LBUTTONUP and (app.tabline_state.dragging_tab != null or
                            app.tabline_state.close_button_pressed != null or
                            app.tabline_state.new_tab_button_pressed))
                        {
                            tabline_mod.handleSidebarMouseUp(app, hwnd, @as(c_int, x_up), @as(c_int, y_up));
                            return 0;
                        }
                        // Check if event is in sidebar area — consume all buttons
                        var client_rect_sb2: c.RECT = undefined;
                        _ = c.GetClientRect(hwnd, &client_rect_sb2);
                        const sb_w = app.scalePx(@as(c_int, @intCast(app.sidebar_width_px)));
                        const in_sb = if (app.sidebar_position_right)
                            x_up >= @as(i16, @intCast(client_rect_sb2.right - sb_w))
                        else
                            x_up < @as(i16, @intCast(sb_w));
                        if (in_sb) {
                            if (msg == c.WM_LBUTTONUP) {
                                tabline_mod.handleSidebarMouseUp(app, hwnd, @as(c_int, x_up), @as(c_int, y_up));
                            }
                            return 0;
                        }
                    }
                }

                // Check if we were interacting with scrollbar (left button only)
                if (msg == c.WM_LBUTTONUP and (app.scrollbar_dragging or app.scrollbar_repeat_timer != 0)) {
                    scrollbar.scrollbarMouseUp(hwnd, app);
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
                // When ext_tabline sidebar is enabled, subtract sidebar width to get content-relative X coordinate
                const content_x: i32 = if (app.ext_tabline_enabled and app.tabline_style == .sidebar and !app.sidebar_position_right)
                    @as(i32, x) - @as(i32, app.scalePx(@as(c_int, @intCast(app.sidebar_width_px))))
                else
                    @as(i32, x);
                const col: i32 = if (cell_w > 0) @divTrunc(@max(0, content_x), @as(i32, @intCast(cell_w))) else 0;
                // When ext_tabline titlebar is enabled, subtract tabbar height to get content-relative Y coordinate
                const content_y: i32 = if (app.ext_tabline_enabled and app.tabline_style == .titlebar and app.content_hwnd == null)
                    @as(i32, y) - @as(i32, app.scalePx(TablineState.TAB_BAR_HEIGHT))
                else
                    @as(i32, y);
                const row: i32 = if (row_h > 0) @divTrunc(@max(0, content_y), @as(i32, @intCast(row_h))) else 0;

                // Build modifier string
                var mod_buf: [5]u8 = .{ 0, 0, 0, 0, 0 };
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
                if (c.GetKeyState(c.VK_LWIN) < 0 or c.GetKeyState(c.VK_RWIN) < 0) {
                    mod_buf[mod_len] = 'D';
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

        c.WM_XBUTTONDOWN => {
            if (getApp(hwnd)) |app| {
                _ = c.SetCapture(hwnd);

                const x: i16 = @bitCast(@as(u16, @truncate(@as(usize, @bitCast(lParam)))));
                const y: i16 = @bitCast(@as(u16, @truncate(@as(usize, @bitCast(lParam)) >> 16)));

                // HIWORD(wParam) contains XBUTTON1 (1) or XBUTTON2 (2)
                const x_button: u16 = @truncate(wParam >> 16);
                const button: [*:0]const u8 = if (x_button == 1) blk: {
                    app.mouse_button_held = 4;
                    break :blk "x1";
                } else blk: {
                    app.mouse_button_held = 5;
                    break :blk "x2";
                };

                app.mu.lock();
                const cell_w = app.cell_w_px;
                const cell_h = app.cell_h_px;
                const linespace = app.linespace_px;
                app.mu.unlock();

                const row_h = cell_h + linespace;
                const content_x: i32 = if (app.ext_tabline_enabled and app.tabline_style == .sidebar and !app.sidebar_position_right)
                    @as(i32, x) - @as(i32, app.scalePx(@as(c_int, @intCast(app.sidebar_width_px))))
                else
                    @as(i32, x);
                const col: i32 = if (cell_w > 0) @divTrunc(@max(0, content_x), @as(i32, @intCast(cell_w))) else 0;
                const content_y: i32 = if (app.ext_tabline_enabled and app.tabline_style == .titlebar and app.content_hwnd == null)
                    @as(i32, y) - @as(i32, app.scalePx(TablineState.TAB_BAR_HEIGHT))
                else
                    @as(i32, y);
                const row: i32 = if (row_h > 0) @divTrunc(@max(0, content_y), @as(i32, @intCast(row_h))) else 0;

                var mod_buf: [5]u8 = .{ 0, 0, 0, 0, 0 };
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
                if (c.GetKeyState(c.VK_LWIN) < 0 or c.GetKeyState(c.VK_RWIN) < 0) {
                    mod_buf[mod_len] = 'D';
                    mod_len += 1;
                }
                mod_buf[mod_len] = 0;

                app.last_mouse_grid_id = 1;

                core.zonvie_core_send_mouse_input(
                    app.corep,
                    button,
                    "press",
                    @as([*:0]const u8, @ptrCast(&mod_buf)),
                    1,
                    @max(0, row),
                    @max(0, col),
                );

                // WM_XBUTTONDOWN requires returning TRUE
                return 1;
            }
        },

        c.WM_XBUTTONUP => {
            if (getApp(hwnd)) |app| {
                _ = c.ReleaseCapture();

                const x: i16 = @bitCast(@as(u16, @truncate(@as(usize, @bitCast(lParam)))));
                const y: i16 = @bitCast(@as(u16, @truncate(@as(usize, @bitCast(lParam)) >> 16)));

                const x_button: u16 = @truncate(wParam >> 16);
                const button: [*:0]const u8 = if (x_button == 1) "x1" else "x2";

                app.mouse_button_held = 0;

                app.mu.lock();
                const cell_w = app.cell_w_px;
                const cell_h = app.cell_h_px;
                const linespace = app.linespace_px;
                app.mu.unlock();

                const row_h = cell_h + linespace;
                const content_x: i32 = if (app.ext_tabline_enabled and app.tabline_style == .sidebar and !app.sidebar_position_right)
                    @as(i32, x) - @as(i32, app.scalePx(@as(c_int, @intCast(app.sidebar_width_px))))
                else
                    @as(i32, x);
                const col: i32 = if (cell_w > 0) @divTrunc(@max(0, content_x), @as(i32, @intCast(cell_w))) else 0;
                const content_y: i32 = if (app.ext_tabline_enabled and app.tabline_style == .titlebar and app.content_hwnd == null)
                    @as(i32, y) - @as(i32, app.scalePx(TablineState.TAB_BAR_HEIGHT))
                else
                    @as(i32, y);
                const row: i32 = if (row_h > 0) @divTrunc(@max(0, content_y), @as(i32, @intCast(row_h))) else 0;

                var mod_buf: [5]u8 = .{ 0, 0, 0, 0, 0 };
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
                if (c.GetKeyState(c.VK_LWIN) < 0 or c.GetKeyState(c.VK_RWIN) < 0) {
                    mod_buf[mod_len] = 'D';
                    mod_len += 1;
                }
                mod_buf[mod_len] = 0;

                core.zonvie_core_send_mouse_input(
                    app.corep,
                    button,
                    "release",
                    @as([*:0]const u8, @ptrCast(&mod_buf)),
                    1,
                    @max(0, row),
                    @max(0, col),
                );

                // WM_XBUTTONUP requires returning TRUE
                return 1;
            }
        },

        c.WM_NCMOUSEMOVE => {
            // Handle non-client mouse move (e.g., in HTCAPTION area of tabline)
            if (getApp(hwnd)) |app| {
                if (app.ext_tabline_enabled and app.tabline_style == .titlebar) {
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
                            .bottom = app.scalePx(TablineState.TAB_BAR_HEIGHT),
                        };
                        _ = c.InvalidateRect(hwnd, &tabline_rect, 0);
                    }
                }
            }
            return c.DefWindowProcW(hwnd, msg, wParam, lParam);
        },

        c.WM_SETCURSOR => {
            if (getApp(hwnd)) |app| {
                const hit_test: u16 = @truncate(@as(usize, @bitCast(lParam)));
                if (hit_test == c.HTCLIENT) {
                    // Perform URL hit-test here (WM_SETCURSOR fires before WM_MOUSEMOVE)
                    var cursor_pt: c.POINT = undefined;
                    _ = c.GetCursorPos(&cursor_pt);
                    _ = c.ScreenToClient(hwnd, &cursor_pt);
                    const mx: i16 = @intCast(cursor_pt.x);
                    const my: i16 = @intCast(cursor_pt.y);

                    app.mu.lock();
                    const sc_cell_w = app.cell_w_px;
                    const sc_cell_h = app.cell_h_px;
                    const sc_ls = app.linespace_px;
                    app.mu.unlock();

                    const sc_row_h = sc_cell_h + sc_ls;
                    const sc_cx: i32 = if (app.ext_tabline_enabled and app.tabline_style == .sidebar and !app.sidebar_position_right)
                        @as(i32, mx) - @as(i32, app.scalePx(@as(c_int, @intCast(app.sidebar_width_px))))
                    else
                        @as(i32, mx);
                    const sc_cy: i32 = if (app.ext_tabline_enabled and app.tabline_style == .titlebar and app.content_hwnd == null)
                        @as(i32, my) - @as(i32, app.scalePx(TablineState.TAB_BAR_HEIGHT))
                    else
                        @as(i32, my);

                    if (sc_cx < 0 or sc_cy < 0) {
                        app.cursor_is_hand = false;
                    } else if (app.corep) |corep| {
                        const global_col: i32 = if (sc_cell_w > 0) @divTrunc(sc_cx, @as(i32, @intCast(sc_cell_w))) else 0;
                        const global_row: i32 = if (sc_row_h > 0) @divTrunc(sc_cy, @as(i32, @intCast(sc_row_h))) else 0;

                        // Hit-test visible grids to find the correct grid and local coordinates
                        const vg = app.getVisibleGridsCached(corep);
                        var best_grid_id: i64 = 1;
                        var local_row: i32 = global_row;
                        var local_col: i32 = global_col;
                        var best_zindex: i64 = -1;
                        for (vg.grids[0..vg.count]) |g| {
                            if (global_row >= g.start_row and global_row < g.start_row + g.rows and
                                global_col >= g.start_col and global_col < g.start_col + g.cols and
                                g.zindex > best_zindex)
                            {
                                best_zindex = g.zindex;
                                best_grid_id = g.grid_id;
                                local_row = global_row - g.start_row;
                                local_col = global_col - g.start_col;
                            }
                        }

                        const result = core.zonvie_core_try_cell_has_url(corep, best_grid_id, local_row, local_col);
                        if (result >= 0) {
                            app.cursor_is_hand = (result == 1);
                            app.url_cache_grid = best_grid_id;
                            app.url_cache_row = local_row;
                            app.url_cache_col = local_col;
                        } else {
                            // Lock unavailable: use cached value only for same cell, else reset
                            if (app.url_cache_grid != best_grid_id or app.url_cache_row != local_row or app.url_cache_col != local_col) {
                                app.cursor_is_hand = false;
                            }
                        }
                    }

                    if (app.cursor_is_hand) {
                        _ = c.SetCursor(loadSystemCursor(32649)); // IDC_HAND
                        return 1;
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

                // Handle tabline/sidebar drag or hover (when ext_tabline enabled)
                if (app.ext_tabline_enabled) {
                    if (app.tabline_style == .titlebar) {
                        if (app.tabline_state.dragging_tab != null or y < app.scalePx(TablineState.TAB_BAR_HEIGHT)) {
                            tabline_mod.handleTablineMouseMoveInChild(app, hwnd, @as(c_int, x), @as(c_int, y));
                            if (app.tabline_state.dragging_tab != null) return 0;
                        } else {
                            if (app.tabline_state.hovered_tab != null or
                                app.tabline_state.hovered_close != null or
                                app.tabline_state.hovered_window_btn != null or
                                app.tabline_state.hovered_new_tab_btn)
                            {
                                app.tabline_state.hovered_tab = null;
                                app.tabline_state.hovered_close = null;
                                app.tabline_state.hovered_window_btn = null;
                                app.tabline_state.hovered_new_tab_btn = false;
                                var tabline_rect: c.RECT = .{
                                    .left = 0,
                                    .top = 0,
                                    .right = 4096,
                                    .bottom = app.scalePx(TablineState.TAB_BAR_HEIGHT),
                                };
                                _ = c.InvalidateRect(hwnd, &tabline_rect, 0);
                            }
                        }
                    } else if (app.tabline_style == .sidebar) {
                        var client_rect_sb3: c.RECT = undefined;
                        _ = c.GetClientRect(hwnd, &client_rect_sb3);
                        const sb_w3 = app.scalePx(@as(c_int, @intCast(app.sidebar_width_px)));
                        const in_sb3 = if (app.sidebar_position_right)
                            x >= @as(i16, @intCast(client_rect_sb3.right - sb_w3))
                        else
                            x < @as(i16, @intCast(sb_w3));

                        if (app.tabline_state.dragging_tab != null or in_sb3) {
                            tabline_mod.handleSidebarMouseMove(app, hwnd, @as(c_int, x), @as(c_int, y));
                            // Consume event: sidebar area is UI, not Neovim editor input
                            return 0;
                        } else {
                            if (app.tabline_state.hovered_tab != null or
                                app.tabline_state.hovered_close != null or
                                app.tabline_state.hovered_new_tab_btn)
                            {
                                app.tabline_state.hovered_tab = null;
                                app.tabline_state.hovered_close = null;
                                app.tabline_state.hovered_new_tab_btn = false;
                                _ = c.InvalidateRect(hwnd, null, 0);
                            }
                        }
                    }
                }

                // Handle scrollbar dragging
                if (app.scrollbar_dragging) {
                    scrollbar.scrollbarMouseMove(hwnd, app, @as(i32, y));
                    return 0;
                }

                // Check hover mode scrollbar
                if (app.config.scrollbar.enabled and app.config.scrollbar.isHover()) {
                    var client: c.RECT = undefined;
                    _ = c.GetClientRect(hwnd, &client);
                    const hit = scrollbar.scrollbarHitTest(app, client.right, client.bottom, @as(i32, x), @as(i32, y));
                    const in_scrollbar = hit != .none;

                    if (in_scrollbar and !app.scrollbar_hover) {
                        app.scrollbar_hover = true;
                        scrollbar.showScrollbar(hwnd, app);
                    } else if (!in_scrollbar and app.scrollbar_hover) {
                        app.scrollbar_hover = false;
                        if (!app.config.scrollbar.isAlways() and !app.config.scrollbar.isScroll()) {
                            scrollbar.hideScrollbar(hwnd, app);
                        }
                    }
                }

                // Only send drag events if a button is held
                if (app.mouse_button_held == 0) return c.DefWindowProcW(hwnd, msg, wParam, lParam);

                const button: [*:0]const u8 = switch (app.mouse_button_held) {
                    1 => "left",
                    2 => "right",
                    3 => "middle",
                    4 => "x1",
                    5 => "x2",
                    else => return c.DefWindowProcW(hwnd, msg, wParam, lParam),
                };

                // Get cell dimensions
                app.mu.lock();
                const cell_w = app.cell_w_px;
                const cell_h = app.cell_h_px;
                const linespace = app.linespace_px;
                app.mu.unlock();

                const row_h = cell_h + linespace;
                // When ext_tabline sidebar is enabled, subtract sidebar width to get content-relative X coordinate
                const content_x: i32 = if (app.ext_tabline_enabled and app.tabline_style == .sidebar and !app.sidebar_position_right)
                    @as(i32, x) - @as(i32, app.scalePx(@as(c_int, @intCast(app.sidebar_width_px))))
                else
                    @as(i32, x);
                const col: i32 = if (cell_w > 0) @divTrunc(@max(0, content_x), @as(i32, @intCast(cell_w))) else 0;
                // When ext_tabline titlebar is enabled, subtract tabbar height to get content-relative Y coordinate
                const content_y: i32 = if (app.ext_tabline_enabled and app.tabline_style == .titlebar and app.content_hwnd == null)
                    @as(i32, y) - @as(i32, app.scalePx(TablineState.TAB_BAR_HEIGHT))
                else
                    @as(i32, y);
                const row: i32 = if (row_h > 0) @divTrunc(@max(0, content_y), @as(i32, @intCast(row_h))) else 0;

                // Build modifier string
                var mod_buf: [5]u8 = .{ 0, 0, 0, 0, 0 };
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
                if (c.GetKeyState(c.VK_LWIN) < 0 or c.GetKeyState(c.VK_RWIN) < 0) {
                    mod_buf[mod_len] = 'D';
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

        c.WM_DROPFILES => {
            const hDrop: c.HDROP = @ptrFromInt(@as(usize, wParam));
            defer c.DragFinish(hDrop);

            if (getApp(hwnd)) |app| {
                const corep = app.corep orelse return 0;
                const file_count = c.DragQueryFileW(hDrop, 0xFFFFFFFF, null, 0);
                if (file_count == 0) return 0;

                // Build a single command buffer: "drop path1 path2 ..."
                // or just "path1 path2 ..." for cmdline mode insertion.
                var cmd_buf: [32768]u8 = undefined;
                var pos: usize = 0;

                // Check if Neovim is in command-line mode.
                const mode_ptr: [*:0]const u8 = app_mod.zonvie_core_get_current_mode(corep);
                const mode = std.mem.span(mode_ptr);
                const is_cmdline = std.mem.startsWith(u8, mode, "cmdline");

                if (!is_cmdline) {
                    const prefix = "drop ";
                    @memcpy(cmd_buf[pos..][0..prefix.len], prefix);
                    pos += prefix.len;
                }

                var i: c.UINT = 0;
                while (i < file_count) : (i += 1) {
                    const required_len = c.DragQueryFileW(hDrop, i, null, 0);
                    if (required_len == 0) continue;

                    const buf_len = required_len + 1;
                    var stack_buf: [c.MAX_PATH + 1]c.WCHAR = undefined;
                    const heap_buf = if (buf_len > stack_buf.len)
                        std.heap.page_allocator.alloc(c.WCHAR, buf_len) catch continue
                    else
                        null;
                    defer if (heap_buf) |hb| std.heap.page_allocator.free(hb);

                    const path_buf = if (heap_buf) |hb| hb.ptr else &stack_buf;
                    const len = c.DragQueryFileW(hDrop, i, path_buf, @intCast(buf_len));
                    if (len == 0) continue;

                    const wide_slice: []const u16 = @as([*]const u16, @ptrCast(path_buf))[0..len];

                    var utf8_stack: [c.MAX_PATH * 4]u8 = undefined;
                    const utf8_max = len * 4;
                    const utf8_heap = if (utf8_max > utf8_stack.len)
                        std.heap.page_allocator.alloc(u8, utf8_max) catch continue
                    else
                        null;
                    defer if (utf8_heap) |hb| std.heap.page_allocator.free(hb);

                    const utf8_dest = if (utf8_heap) |hb| hb else &utf8_stack;
                    const utf8_len = std.unicode.utf16LeToUtf8(utf8_dest, wide_slice) catch continue;
                    const utf8_path = utf8_dest[0..utf8_len];

                    // Add space separator between paths
                    if (i > 0 or (!is_cmdline and pos > 5)) {
                        if (pos < cmd_buf.len) {
                            cmd_buf[pos] = ' ';
                            pos += 1;
                        }
                    }

                    // Escape special characters for Neovim
                    for (utf8_path) |ch| {
                        if (pos + 2 > cmd_buf.len) break;
                        const escaped: ?[]const u8 = switch (ch) {
                            '\\' => "\\\\",
                            ' ' => "\\ ",
                            '%' => "\\%",
                            '#' => "\\#",
                            '|' => "\\|",
                            '"' => "\\\"",
                            '\'' => "\\'",
                            '[' => "\\[",
                            ']' => "\\]",
                            '{' => "\\{",
                            '}' => "\\}",
                            else => null,
                        };

                        if (escaped) |esc| {
                            if (pos + esc.len <= cmd_buf.len) {
                                @memcpy(cmd_buf[pos..][0..esc.len], esc);
                                pos += esc.len;
                            }
                        } else {
                            cmd_buf[pos] = ch;
                            pos += 1;
                        }
                    }
                }

                if (pos > 0) {
                    if (is_cmdline) {
                        // In command-line mode: insert paths at cursor position.
                        app_mod.zonvie_core_send_input(corep, &cmd_buf, @intCast(pos));
                    } else {
                        // In normal/insert/visual mode: execute :drop immediately.
                        app_mod.zonvie_core_send_command(corep, &cmd_buf, pos);
                    }
                }
            }
            return 0;
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
                if (app.ext_tabline_enabled and app.tabline_style == .titlebar) {
                    // Enable DWM shadow for borderless window by extending frame with minimal margins.
                    // MARGINS.bottom = 1 tricks DWM into thinking there's a frame, which enables the shadow.
                    // This doesn't cause glass overlay issues because the margin is only 1 pixel.
                    const margins = c.MARGINS{ .cxLeftWidth = 0, .cxRightWidth = 0, .cyTopHeight = 0, .cyBottomHeight = 1 };
                    _ = c.DwmExtendFrameIntoClientArea(hwnd, &margins);
                    if (applog.isEnabled()) applog.appLog("[win] WM_ACTIVATE: DwmExtendFrameIntoClientArea applied for shadow\n", .{});
                }
            }
            return c.DefWindowProcW(hwnd, msg, wParam, lParam);
        },

        c.WM_ACTIVATEAPP => {
            // Notify Neovim of focus change (triggers FocusGained/FocusLost autocmds)
            if (getApp(hwnd)) |app| {
                const is_activating = wParam != 0;
                if (app.corep) |corep| {
                    core.zonvie_core_set_focus(corep, is_activating);
                }
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
                        input.setIMEOff(hwnd);
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

        c.WM_MOUSELEAVE => {
            // Mouse left the client area - clear sidebar hover states
            if (getApp(hwnd)) |app| {
                if (app.ext_tabline_enabled and app.tabline_style == .sidebar) {
                    if (app.tabline_state.hovered_tab != null or
                        app.tabline_state.hovered_close != null or
                        app.tabline_state.hovered_new_tab_btn)
                    {
                        app.tabline_state.hovered_tab = null;
                        app.tabline_state.hovered_close = null;
                        app.tabline_state.hovered_new_tab_btn = false;
                        // Invalidate sidebar region
                        var client_rect: c.RECT = undefined;
                        _ = c.GetClientRect(hwnd, &client_rect);
                        const sidebar_w = app.scalePx(@as(c_int, @intCast(app.sidebar_width_px)));
                        var sidebar_rect: c.RECT = .{
                            .left = if (app.sidebar_position_right) client_rect.right - sidebar_w else 0,
                            .top = 0,
                            .right = if (app.sidebar_position_right) client_rect.right else sidebar_w,
                            .bottom = client_rect.bottom,
                        };
                        _ = c.InvalidateRect(hwnd, &sidebar_rect, 0);
                    }
                }
            }
            return 0;
        },

        c.WM_CAPTURECHANGED => {
            // Mouse capture lost - cancel any tabline/sidebar drag or button press
            if (getApp(hwnd)) |app| {
                if (app.ext_tabline_enabled) {
                    const had_state = app.tabline_state.dragging_tab != null or
                        app.tabline_state.close_button_pressed != null or
                        app.tabline_state.new_tab_button_pressed or
                        app.tabline_state.pressed_window_btn != null;

                    if (had_state) {
                        if (applog.isEnabled()) applog.appLog("[tabline] WM_CAPTURECHANGED (parent): cancelling drag/button!\n", .{});
                        tabline_mod.destroyDragPreviewWindow(app);
                        app.tabline_state.cancelDrag();
                        app.tabline_state.close_button_pressed = null;
                        app.tabline_state.new_tab_button_pressed = false;
                        app.tabline_state.pressed_window_btn = null;
                        // Invalidate the relevant tab area
                        var client_rect: c.RECT = undefined;
                        _ = c.GetClientRect(hwnd, &client_rect);
                        if (app.tabline_style == .sidebar) {
                            const sidebar_w = app.scalePx(@as(c_int, @intCast(app.sidebar_width_px)));
                            var sidebar_rect: c.RECT = .{
                                .left = if (app.sidebar_position_right) client_rect.right - sidebar_w else 0,
                                .top = 0,
                                .right = if (app.sidebar_position_right) client_rect.right else sidebar_w,
                                .bottom = client_rect.bottom,
                            };
                            _ = c.InvalidateRect(hwnd, &sidebar_rect, 0);
                        } else {
                            var tabline_rect: c.RECT = .{
                                .left = 0,
                                .top = 0,
                                .right = client_rect.right,
                                .bottom = app.scalePx(TablineState.TAB_BAR_HEIGHT),
                            };
                            _ = c.InvalidateRect(hwnd, &tabline_rect, 0);
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
