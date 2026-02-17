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

pub export fn WndProc(
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
                        applog.appLog("[win] WM_NCCALCSIZE: maximized, inset by frame=({d},{d})\n", .{ frame_x, frame_y });
                    } else {
                        applog.appLog("[win] WM_NCCALCSIZE: extending client area into titlebar\n", .{});
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
            if (builtin.mode == .Debug and !applog.isEnabled()) {
                // Force early logging in debug builds to capture init crashes.
                applog.setEnabled(true);
            }

            applog.appLog("WM_CREATE: begin (deferred init)", .{});
            if (getApp(hwnd)) |app| {
                app.hwnd = hwnd;
                app.ui_thread_id = c.GetCurrentThreadId();

                // Set DPI scale early so that any scalePx() calls before
                // WM_APP_DEFERRED_INIT (e.g. WM_NCHITTEST, initial layout)
                // use the correct value.
                const initial_dpi = GetDpiForWindow(hwnd);
                if (initial_dpi > 0) {
                    app.dpi_scale = @as(f32, @floatFromInt(initial_dpi)) / 96.0;
                    applog.appLog("[win] WM_CREATE: initial dpi={d} scale={d:.2}\n", .{ initial_dpi, app.dpi_scale });
                }

                // DWM custom titlebar: trigger frame recalculation (titlebar mode only)
                if (app.ext_tabline_enabled and app.tabline_style == .titlebar) {
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

                // Accept file drops via drag & drop
                c.DragAcceptFiles(hwnd, 1);

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
                    const first_paint_ms = @divTrunc((first_paint_t.QuadPart - app_mod.g_startup_t0.QuadPart) * 1000, app_mod.g_startup_freq.QuadPart);
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
                    {
                        app.mu.lock();
                        app.paint_full = true;
                        app.paint_rects.clearRetainingCapacity();
                        app.mu.unlock();
                    }
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

                // If the glyph atlas was reset, all cached row vertex UVs are stale.
                // Request a full re-seed so the core regenerates every row.
                // Guard with renderer mutex (resetAtlas sets the flag under a.mu).
                if (atlas_ptr) |a| {
                    a.mu.lock();
                    const reset_pending = a.atlas_reset_pending;
                    if (reset_pending) a.atlas_reset_pending = false;
                    a.mu.unlock();
                    if (reset_pending) {
                        app.need_full_seed.store(true, .seq_cst);
                        app.paint_full = true;
                        app.paint_rects.clearRetainingCapacity();
                        // After atlas reset, external window paints may consume
                        // shared pending_uploads before the main window sees them.
                        // Schedule a full atlas upload to ensure all glyph data is present.
                        app.atlas_full_upload_needed = true;
                    }
                }

                var dirty_row_keys: std.ArrayListUnmanaged(u32) = .{};
                defer dirty_row_keys.deinit(app.alloc);

                if (row_mode) {
                    var it = app.dirty_rows.keyIterator();
                    while (it.next()) |k| {
                        dirty_row_keys.append(app.alloc, k.*) catch break;
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
                paint_rects_snapshot.appendSlice(app.alloc, app.paint_rects.items) catch {};
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
                        // After atlas reset, external windows may have consumed some
                        // pending_uploads before the main window. Upload the full atlas
                        // once to ensure all glyph data (including shared glyphs) is present.
                        if (app.atlas_full_upload_needed) {
                            a.uploadFullAtlasToD3D(g);
                            app.atlas_full_upload_needed = false;
                            applog.appLog("[win] atlas full upload (post-reset sync)\n", .{});
                        }
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

                    // Snap viewport height to cell boundaries to match core's NDC calculation.
                    // The core computes NDC using grid_rows * cell_h (snapped to cell boundaries),
                    // so the D3D11 viewport must use the same snapped height to prevent sub-pixel
                    // misalignment between vertex positions and scissor rects (which causes stripes).
                    const content_height: u32 = blk: {
                        const cell_total_h: u32 = @max(1, app.cell_h_px + app.linespace_px);
                        const client_h: u32 = @intCast(@max(1, client_for_content.bottom - client_for_content.top));
                        const y_off: u32 = content_y_offset orelse 0;
                        const drawable_h: u32 = if (client_h > y_off) client_h - y_off else 0;
                        const snapped: u32 = (drawable_h / cell_total_h) * cell_total_h;
                        // Match core's @max(1, grid_rows) guarantee: at least 1 row tall
                        break :blk @max(snapped, cell_total_h);
                    };

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
                        // Non-row mode: draw under lock to keep main/cursor verts stable.
                        app.mu.lock();
                        if (!app.row_mode) {
                            const main_verts_now = app.main_verts.items;
                            // Only include cursor verts if blink state is visible
                            const cursor_verts_now = if (app.cursor_blink_state) app.cursor_verts.items else &[_]core.Vertex{};
                            if (g.drawEx(main_verts_now, cursor_verts_now, dirty, .{ .content_width = content_width, .content_y_offset = content_y_offset, .content_x_offset = content_x_offset, .sidebar_right_width = sidebar_right_width, .content_height = content_height, .tabbar_bg_color = tabbar_bg_color })) {
                                render_ok = true;
                            } else |e| {
                                applog.appLog("gpu.draw failed: {any}\n", .{e});
                            }
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
                                rows_to_draw.append(app.alloc, irow) catch break;
                            }
                        } else if (dirty_row_keys.items.len != 0) {
                            // Normal path: use explicit dirty rows
                            rows_to_draw.appendSlice(app.alloc, dirty_row_keys.items) catch {};
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
                                .content_x_offset = content_x_offset,
                                .sidebar_right_width = sidebar_right_width,
                                .content_height = content_height,
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

                                    // Add content offsets for ext_tabline (scissor is in screen coords)
                                    const y_offset: i32 = if (content_y_offset) |off| @intCast(off) else 0;
                                    const x_offset: i32 = if (content_x_offset) |off| @intCast(off) else 0;
                                    const top: i32 = y_offset + @as(i32, @intCast(row)) * row_h_px;
                                    const bottom: i32 = top + row_h_px;
                                    const row_rc: c.RECT = .{ .left = x_offset, .top = top, .right = client.right, .bottom = bottom };

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
                                        // Compute scissor bounds matching content viewport (absolute coords)
                                        const sc_x_off: c.LONG = if (content_x_offset) |off| @intCast(off) else 0;
                                        const sc_y_off: c.LONG = if (content_y_offset) |off| @intCast(off) else 0;
                                        // content_width is viewport-relative; add x_off for absolute coords
                                        const sc_right: c.LONG = if (content_width) |cw| sc_x_off + @as(c.LONG, @intCast(cw)) else client.right;
                                        if (cursor_rc_opt) |cr| {
                                            // cursor_rc_opt is already transformed to viewport coords
                                            var sc: c.D3D11_RECT = .{
                                                .left = cr.left,
                                                .top = cr.top,
                                                .right = @min(cr.right, sc_right),
                                                .bottom = cr.bottom,
                                            };
                                            f(ctx_ptr, 1, &sc);
                                        } else {
                                            var sc: c.D3D11_RECT = .{
                                                .left = sc_x_off,
                                                .top = sc_y_off,
                                                .right = sc_right,
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
                                const scrollbar_vert_count = scrollbar.generateScrollbarVertices(app, client.right, client.bottom, &scrollbar_verts);
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

                            if (g.presentFromBackRectsWithCursorNoResize(
                                present_rects_slice,
                                app.cursor_vb,
                                cursor_verts_snapshot.len,
                                cursor_rc_opt,
                                force_full_present,
                            )) {
                                render_ok = true;
                            } else |e| {
                                applog.appLog("presentFromBackRectsWithCursorNoResize failed: {any}\n", .{e});
                            }

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

                // Recover dirty state if rendering failed, so the next
                // WM_PAINT will retry a full redraw instead of showing stale content.
                if (!render_ok) {
                    app.mu.lock();
                    app.paint_full = true;
                    app.mu.unlock();
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
                applog.appLog("[win] WM_DPICHANGED: new_dpi={d}\n", .{new_dpi});

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
                        app.scalePx(TablineState.TAB_BAR_HEIGHT),
                        0,  // No SWP_NOZORDER - explicitly set Z-order
                    );
                }

                // 4) Trigger D3D11 resize
                // When ext_tabline is enabled, D3D11 renders to parent window (no content_hwnd)
                app.mu.lock();
                if (app.renderer) |*g| {
                    g.resize() catch {};
                }
                app.paint_full = true;
                app.paint_rects.clearRetainingCapacity();
                app.mu.unlock();

                // 5) repaint
                _ = c.InvalidateRect(hwnd, null, 0);
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
                external_windows.closeExternalWindowOnUIThread(app, grid_id);
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
            applog.appLog("[win] WM_APP_MSG_CLEAR received\n", .{});
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
            applog.appLog("[win] WM_APP_MINI_UPDATE received: {s}\n", .{@tagName(mini_id)});
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
            applog.appLog("[win] WM_APP_CLIPBOARD_GET received\n", .{});
            if (getApp(hwnd)) |app| {
                dialogs.handleClipboardGetOnUIThread(app);
            }
            return 0;
        },

        WM_APP_CLIPBOARD_SET => {
            applog.appLog("[win] WM_APP_CLIPBOARD_SET received\n", .{});
            if (getApp(hwnd)) |app| {
                dialogs.handleClipboardSetOnUIThread(app);
            }
            return 0;
        },

        WM_APP_SSH_AUTH_PROMPT => {
            applog.appLog("[win] WM_APP_SSH_AUTH_PROMPT received\n", .{});
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

        c.WM_TIMER => {
            if (wParam == TIMER_MSG_AUTOHIDE) {
                applog.appLog("[win] WM_TIMER: message window auto-hide\n", .{});
                // Kill the timer and hide message window
                _ = c.KillTimer(hwnd, TIMER_MSG_AUTOHIDE);
                if (getApp(hwnd)) |app| {
                    messages.hideMessageWindow(app);
                }
            } else if (wParam == TIMER_MINI_AUTOHIDE) {
                applog.appLog("[win] WM_TIMER: mini window auto-hide\n", .{});
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
                applog.appLog("[win] WM_TIMER: cursor blink\n", .{});
                if (getApp(hwnd)) |app| {
                    input.handleCursorBlinkTimer(hwnd, app);
                }
            } else if (wParam == TIMER_DEVCONTAINER_POLL) {
                // Poll for devcontainer up completion
                if (dialogs.g_devcontainer_up_done.load(.seq_cst)) {
                    applog.appLog("[win] WM_TIMER: devcontainer up completed\n", .{});
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
                            dialogs.hideDevcontainerProgressDialog();
                        } else {
                            // Failure: hide dialog and show error
                            dialogs.hideDevcontainerProgressDialog();
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
                    .on_vertices = callbacks.onVertices,
                    .on_vertices_partial = callbacks.onVerticesPartial,
                    .on_vertices_row = callbacks.onVerticesRow,
                    .on_atlas_ensure_glyph = callbacks.onAtlasEnsureGlyph,
                    .on_atlas_ensure_glyph_styled = callbacks.onAtlasEnsureGlyphStyled,
                    .on_render_plan = callbacks.onRenderPlan,
                    .on_log = callbacks.onLog,
                    .on_guifont = callbacks.onGuiFont,
                    .on_linespace = callbacks.onLineSpace,
                    .on_exit = callbacks.onExit,
                    .on_default_colors_set = callbacks.onDefaultColorsSet,
                    .on_set_title = callbacks.onSetTitle,
                    .on_external_window = external_windows.onExternalWindow,
                    .on_external_window_close = external_windows.onExternalWindowClose,
                    .on_external_vertices = external_windows.onExternalVertices,
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
                };
                applog.appLog("[win] row_mode enabled: using row-vertex path\n", .{});

                applog.appLog("  core_create callbacks ptr ctx(app)={*}", .{app});
                _ = c.QueryPerformanceCounter(&t1);
                app.corep = core.zonvie_core_create(&cb, @sizeOf(core.Callbacks), app);
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
                if (app.ext_windows_enabled) {
                    applog.appLog("[win] enabling ext_windows\n", .{});
                    core.zonvie_core_set_ext_windows(app.corep, 1);
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
                            dialogs.showDevcontainerProgressDialog(std.unicode.utf8ToUtf16LeStringLiteral("Building devcontainer..."));

                            // Reset atomic flags
                            dialogs.g_devcontainer_up_done.store(false, .seq_cst);
                            dialogs.g_devcontainer_up_success.store(false, .seq_cst);

                            // Start background thread for devcontainer up
                            const thread = std.Thread.spawn(.{}, dialogs.runDevcontainerUpThread, .{ workspace, app.devcontainer_config, app.alloc }) catch |e| {
                                applog.appLog("[win] failed to spawn devcontainer up thread: {any}\n", .{e});
                                dialogs.hideDevcontainerProgressDialog();
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
                        dialogs.hideDevcontainerProgressDialog();
                    }
                } else {
                    applog.appLog("[win] nvim startup skipped, waiting for devcontainer up\n", .{});
                }

                // ============================================================
                // PHASE 2: Initialize renderers (runs in parallel with nvim spawn)
                // ============================================================
                applog.appLog("  renderer create...", .{});

                // 1) Atlas builder (DirectWrite + CPU atlas)
                // Font priority: config.font.family > OS default (Consolas)
                const initial_font = if (app.config.font.family.len > 0) app.config.font.family else "Consolas";
                const initial_pt: f32 = if (app.config.font.size > 0.0) app.config.font.size else 14.0;
                applog.appLog("[win] initial font: '{s}' pt={d}\n", .{ initial_font, initial_pt });

                _ = c.QueryPerformanceCounter(&t1);
                const atlas = dwrite_d2d.Renderer.init(app.alloc, hwnd, initial_font, initial_pt) catch |e| {
                    applog.appLog("dwrite_d2d.Renderer.init failed: {any}\n", .{e});
                    app.atlas = null;
                    app.renderer = null;
                    return 0;
                };
                _ = c.QueryPerformanceCounter(&t2);
                const dwrite_ms = @divTrunc((t2.QuadPart - t1.QuadPart) * 1000, freq.QuadPart);
                applog.appLog("  [TIMING] dwrite_d2d.Renderer.init: {d}ms", .{dwrite_ms});

                // Set initial DPI scale from renderer
                app.dpi_scale = @as(f32, @floatFromInt(atlas.dpi)) / 96.0;
                applog.appLog("[win] initial dpi_scale={d:.2}\n", .{app.dpi_scale});

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
                        vk, scancode,
                        &tmp_chars, &tmp_ign,
                        &out_chars, &out_ign,
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
                input.positionImeCandidateWindow(hwnd, app);
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
                            input.updateImeCompositionUtf8(app);
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
                if ((wParam & c.MK_SHIFT) != 0) { mod_buf[mod_len] = 'S'; mod_len += 1; }
                if ((wParam & c.MK_CONTROL) != 0) { mod_buf[mod_len] = 'C'; mod_len += 1; }
                if (c.GetKeyState(c.VK_MENU) < 0) { mod_buf[mod_len] = 'A'; mod_len += 1; }
                if (c.GetKeyState(c.VK_LWIN) < 0 or c.GetKeyState(c.VK_RWIN) < 0) { mod_buf[mod_len] = 'D'; mod_len += 1; }
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
                if ((wParam & c.MK_SHIFT) != 0) { mod_buf[mod_len] = 'S'; mod_len += 1; }
                if ((wParam & c.MK_CONTROL) != 0) { mod_buf[mod_len] = 'C'; mod_len += 1; }
                if (c.GetKeyState(c.VK_MENU) < 0) { mod_buf[mod_len] = 'A'; mod_len += 1; }
                if (c.GetKeyState(c.VK_LWIN) < 0 or c.GetKeyState(c.VK_RWIN) < 0) { mod_buf[mod_len] = 'D'; mod_len += 1; }
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

                var i: c.UINT = 0;
                while (i < file_count) : (i += 1) {
                    // Query required buffer length (excluding null terminator)
                    const required_len = c.DragQueryFileW(hDrop, i, null, 0);
                    if (required_len == 0) continue;

                    const buf_len = required_len + 1; // +1 for null terminator

                    // Use stack buffer for typical paths, heap for long paths
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

                    // UTF-16 -> UTF-8 conversion (worst case: 4 bytes per code unit)
                    const utf8_max = len * 4;
                    var utf8_stack: [c.MAX_PATH * 4]u8 = undefined;
                    const utf8_heap = if (utf8_max > utf8_stack.len)
                        std.heap.page_allocator.alloc(u8, utf8_max) catch continue
                    else
                        null;
                    defer if (utf8_heap) |hb| std.heap.page_allocator.free(hb);

                    const utf8_dest = if (utf8_heap) |hb| hb else &utf8_stack;
                    const utf8_len = std.unicode.utf16LeToUtf8(utf8_dest, wide_slice) catch continue;
                    const utf8_path = utf8_dest[0..utf8_len];

                    // Build "drop <escaped_path>" command
                    // Worst case: each byte escapes to 2 bytes + "drop " prefix
                    const cmd_max = 5 + utf8_len * 2;
                    var cmd_stack: [c.MAX_PATH * 4 + 8]u8 = undefined;
                    const cmd_heap = if (cmd_max > cmd_stack.len)
                        std.heap.page_allocator.alloc(u8, cmd_max) catch continue
                    else
                        null;
                    defer if (cmd_heap) |hb| std.heap.page_allocator.free(hb);

                    const cmd_buf = if (cmd_heap) |hb| hb else &cmd_stack;
                    var pos: usize = 0;

                    const prefix = "drop ";
                    @memcpy(cmd_buf[pos..][0..prefix.len], prefix);
                    pos += prefix.len;

                    // Escape special characters for Neovim
                    for (utf8_path) |ch| {
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
                            '$' => "\\$",
                            '`' => "\\`",
                            else => null,
                        };

                        if (escaped) |esc| {
                            @memcpy(cmd_buf[pos..][0..esc.len], esc);
                            pos += esc.len;
                        } else {
                            cmd_buf[pos] = ch;
                            pos += 1;
                        }
                    }

                    app_mod.zonvie_core_send_command(corep, cmd_buf.ptr, pos);
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
                        applog.appLog("[tabline] WM_CAPTURECHANGED (parent): cancelling drag/button!\n", .{});
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
