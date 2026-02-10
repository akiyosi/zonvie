const std = @import("std");
const app_mod = @import("../app.zig");
const App = app_mod.App;
const c = app_mod.c;
const applog = app_mod.applog;
const d3d11 = app_mod.d3d11;
const dwrite_d2d = app_mod.dwrite_d2d;
const core = @import("zonvie_core");
const TablineState = app_mod.TablineState;

const tabline_class_name: [:0]const u16 = std.unicode.utf8ToUtf16LeStringLiteral("ZonvieTablineClass");
var tabline_class_registered: bool = false;

pub fn registerTablineWindowClass() bool {
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

pub fn createTablineWindow(parent_hwnd: c.HWND, app: *App) ?c.HWND {
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
        app.scalePx(TablineState.TAB_BAR_HEIGHT),
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

pub fn tablineWndProc(hwnd: c.HWND, msg: c.UINT, wParam: c.WPARAM, lParam: c.LPARAM) callconv(.winapi) c.LRESULT {
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

                // DPI-scaled constants
                const bar_height = app.scalePx(TablineState.TAB_BAR_HEIGHT);
                const btns_total = app.scalePx(TablineState.WINDOW_BTNS_TOTAL);
                const tab_min_w = app.scalePx(TablineState.TAB_MIN_WIDTH);
                const tab_max_w = app.scalePx(TablineState.TAB_MAX_WIDTH);
                const plus_space = app.scalePx(40);

                // Check window control buttons (right side) - handle in this window
                const btn_start_x = client_width - btns_total;
                if (x >= btn_start_x) {
                    return c.HTCLIENT;
                }

                // Check tabs and + button area
                app.mu.lock();
                const tab_count = app.tabline_state.tab_count;
                app.mu.unlock();

                if (tab_count > 0) {
                    // Calculate tab dimensions (same as handleTablineMouseDown)
                    const available_width = client_width - app.scalePx(TablineState.WINDOW_CONTROLS_WIDTH) - plus_space - btns_total;
                    const count_i32: i32 = @intCast(tab_count);
                    const ideal_width = @divTrunc(available_width, count_i32);
                    const tab_width = @min(tab_max_w, @max(tab_min_w, ideal_width));

                    // Check if on a tab
                    var tab_x: i32 = app.scalePx(TablineState.WINDOW_CONTROLS_WIDTH);
                    for (0..tab_count) |_| {
                        if (x >= tab_x and x < tab_x + tab_width and y >= 0 and y < bar_height) {
                            return c.HTCLIENT;
                        }
                        tab_x += tab_width + 1;
                    }

                    // Check + button (after last tab)
                    const plus_x = tab_x + app.scalePx(8);
                    const scaled_plus_size = app.scalePx(24);
                    if (x >= plus_x and x < plus_x + scaled_plus_size) {
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

pub fn registerContentWindowClass() bool {
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

pub fn createContentWindow(parent_hwnd: c.HWND, app: *App) ?c.HWND {
    if (!registerContentWindowClass()) return null;

    var parent_rect: c.RECT = undefined;
    _ = c.GetClientRect(parent_hwnd, &parent_rect);

    const tabbar_height = app.scalePx(TablineState.TAB_BAR_HEIGHT);
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

pub fn contentWndProc(hwnd: c.HWND, msg: c.UINT, wParam: c.WPARAM, lParam: c.LPARAM) callconv(.winapi) c.LRESULT {
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

pub fn handleTablineMouseMoveInChild(app: *App, hwnd: c.HWND, x: c_int, y: c_int) void {
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

    // DPI-scaled constants
    const bar_height = app.scalePx(TablineState.TAB_BAR_HEIGHT);
    const tab_min_w = app.scalePx(TablineState.TAB_MIN_WIDTH);
    const tab_max_w = app.scalePx(TablineState.TAB_MAX_WIDTH);
    const close_size = app.scalePx(TablineState.TAB_CLOSE_SIZE);
    const btns_total = app.scalePx(TablineState.WINDOW_BTNS_TOTAL);
    const btn_w = app.scalePx(TablineState.WINDOW_BTN_WIDTH);
    const ext_drag_threshold = app.scalePx(TablineState.EXTERNAL_DRAG_THRESHOLD);
    const plus_space = app.scalePx(40);
    const close_margin = app.scalePx(6);
    const plus_offset = app.scalePx(8);
    const plus_btn_size = app.scalePx(20);

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
                const threshold = ext_drag_threshold;
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
            const available_width = client_width - app.scalePx(TablineState.WINDOW_CONTROLS_WIDTH) - plus_space - btns_total;
            const tab_count: c_int = @intCast(app.tabline_state.tab_count);
            if (tab_count > 0) {
                const ideal_width = @divTrunc(available_width, tab_count);
                const tab_width = @min(tab_max_w, @max(tab_min_w, ideal_width));

                // Find which slot the mouse is over
                var target_idx: usize = 0;
                var tab_x: c_int = app.scalePx(TablineState.WINDOW_CONTROLS_WIDTH);
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
        const available_width = client_width - app.scalePx(TablineState.WINDOW_CONTROLS_WIDTH) - plus_space - btns_total;
        const tab_count: c_int = @intCast(app.tabline_state.tab_count);
        if (tab_count > 0 and pressed_tab_idx < app.tabline_state.tab_count) {
            const ideal_width = @divTrunc(available_width, tab_count);
            const tab_width = @min(tab_max_w, @max(tab_min_w, ideal_width));

            const tab_x: c_int = app.scalePx(TablineState.WINDOW_CONTROLS_WIDTH) + @as(c_int, @intCast(pressed_tab_idx)) * (tab_width + 1);
            const close_x = tab_x + tab_width - close_size - close_margin;
            const close_y = @divTrunc(bar_height - close_size, 2);

            const is_still_over_close = (x >= close_x and x < close_x + close_size and
                y >= close_y and y < close_y + close_size);

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
        const available_width = client_width - app.scalePx(TablineState.WINDOW_CONTROLS_WIDTH) - plus_space - btns_total;
        const tab_count: c_int = @intCast(app.tabline_state.tab_count);
        if (tab_count > 0) {
            const ideal_width = @divTrunc(available_width, tab_count);
            const tab_width = @min(tab_max_w, @max(tab_min_w, ideal_width));
            const plus_x = app.scalePx(TablineState.WINDOW_CONTROLS_WIDTH) + tab_count * (tab_width + 1) + plus_offset;

            const plus_top = @divTrunc(bar_height - plus_btn_size, 2);
            const is_still_over_plus = (x >= plus_x and x < plus_x + plus_btn_size and y >= plus_top and y < plus_top + plus_btn_size);

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
        const btn_start_x = client_width - btns_total;
        const btn_x = btn_start_x + @as(c_int, pressed_btn) * btn_w;
        const is_still_over_btn = (x >= btn_x and x < btn_x + btn_w and
            y >= 0 and y < bar_height);

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
    const btn_start_x = client_width - btns_total;
    if (x >= btn_start_x and y >= 0 and y < bar_height) {
        const btn_idx = @divTrunc(x - btn_start_x, btn_w);
        if (btn_idx >= 0 and btn_idx < 3) {
            new_hovered_window_btn = @intCast(btn_idx);
        }
    } else {
        // Check tabs
        const available_width = client_width - app.scalePx(TablineState.WINDOW_CONTROLS_WIDTH) - plus_space - btns_total;
        const tab_count: c_int = @intCast(app.tabline_state.tab_count);
        if (tab_count > 0) {
            const ideal_width = @divTrunc(available_width, tab_count);
            const tab_width = @min(tab_max_w, @max(tab_min_w, ideal_width));

            var tab_x: c_int = app.scalePx(TablineState.WINDOW_CONTROLS_WIDTH);
            for (0..app.tabline_state.tab_count) |i| {
                if (x >= tab_x and x < tab_x + tab_width) {
                    new_hovered_tab = i;

                    // Check close button
                    const close_x = tab_x + tab_width - close_size - close_margin;
                    const close_y = @divTrunc(bar_height - close_size, 2);
                    if (x >= close_x and x < close_x + close_size and
                        y >= close_y and y < close_y + close_size)
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
        const available_width_for_plus = client_width - app.scalePx(TablineState.WINDOW_CONTROLS_WIDTH) - plus_space - btns_total;
        const tab_count_for_plus: c_int = @intCast(app.tabline_state.tab_count);
        if (tab_count_for_plus > 0) {
            const ideal_width_for_plus = @divTrunc(available_width_for_plus, tab_count_for_plus);
            const tab_width_for_plus = @min(tab_max_w, @max(tab_min_w, ideal_width_for_plus));
            const plus_x = app.scalePx(TablineState.WINDOW_CONTROLS_WIDTH) + tab_count_for_plus * (tab_width_for_plus + 1) + plus_offset;

            const plus_top = @divTrunc(bar_height - plus_btn_size, 2);
            if (x >= plus_x and x < plus_x + plus_btn_size and y >= plus_top and y < plus_top + plus_btn_size) {
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
pub fn handleTablineMouseDown(app: *App, hwnd: c.HWND, x: c_int, y: c_int) void {
    applog.appLog("[tabline] mouseDown: x={d} y={d}\n", .{ x, y });

    // DPI-scaled constants
    const bar_height = app.scalePx(TablineState.TAB_BAR_HEIGHT);
    const tab_min_w = app.scalePx(TablineState.TAB_MIN_WIDTH);
    const tab_max_w = app.scalePx(TablineState.TAB_MAX_WIDTH);
    const close_size = app.scalePx(TablineState.TAB_CLOSE_SIZE);
    const btns_total = app.scalePx(TablineState.WINDOW_BTNS_TOTAL);
    const btn_w = app.scalePx(TablineState.WINDOW_BTN_WIDTH);
    const plus_space = app.scalePx(40);
    const close_margin = app.scalePx(6);
    const plus_offset = app.scalePx(8);
    const plus_btn_size = app.scalePx(20);

    var rect: c.RECT = undefined;
    _ = c.GetClientRect(hwnd, &rect);
    const client_width = rect.right;

    // Check window control buttons first
    const btn_start_x = client_width - btns_total;
    if (x >= btn_start_x and y >= 0 and y < bar_height) {
        // Window button area - record pressed state, action on mouseUp
        const btn_idx = @divTrunc(x - btn_start_x, btn_w);
        if (btn_idx >= 0 and btn_idx < 3) {
            applog.appLog("[tabline] mouseDown: window button {d} pressed\n", .{btn_idx});
            app.tabline_state.pressed_window_btn = @intCast(btn_idx);
            _ = c.SetCapture(hwnd);
            _ = c.InvalidateRect(hwnd, null, 0);
        }
        return;
    }

    // Check close button on tabs
    const available_width = client_width - app.scalePx(TablineState.WINDOW_CONTROLS_WIDTH) - plus_space - btns_total;
    const tab_count: c_int = @intCast(app.tabline_state.tab_count);
    if (tab_count > 0) {
        const ideal_width = @divTrunc(available_width, tab_count);
        const tab_width = @min(tab_max_w, @max(tab_min_w, ideal_width));

        applog.appLog("[tabline] mouseDown: tab_count={d} tab_width={d}\n", .{ tab_count, tab_width });

        var tab_x: c_int = app.scalePx(TablineState.WINDOW_CONTROLS_WIDTH);
        for (0..app.tabline_state.tab_count) |i| {
            if (x >= tab_x and x < tab_x + tab_width) {
                // Check if on close button
                const close_x = tab_x + tab_width - close_size - close_margin;
                const close_y = @divTrunc(bar_height - close_size, 2);
                if (x >= close_x and x < close_x + close_size and
                    y >= close_y and y < close_y + close_size)
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
                // Use nvim_command API so it works even in terminal mode
                if (app.corep) |corep| {
                    var cmd_buf: [16]u8 = undefined;
                    const cmd = std.fmt.bufPrint(&cmd_buf, "{d}tabnext", .{i + 1}) catch return;
                    app_mod.zonvie_core_send_command(corep, cmd.ptr, cmd.len);
                }

                _ = c.SetCapture(hwnd);
                return;
            }
            tab_x += tab_width + 1;
        }
    }

    // Check + button
    const available_width_for_plus = client_width - app.scalePx(TablineState.WINDOW_CONTROLS_WIDTH) - plus_space - btns_total;
    const tab_count_for_plus: c_int = @intCast(app.tabline_state.tab_count);
    if (tab_count_for_plus > 0) {
        const ideal_width_for_plus = @divTrunc(available_width_for_plus, tab_count_for_plus);
        const tab_width_for_plus = @min(tab_max_w, @max(tab_min_w, ideal_width_for_plus));
        const plus_x = app.scalePx(TablineState.WINDOW_CONTROLS_WIDTH) + tab_count_for_plus * (tab_width_for_plus + 1) + plus_offset;

        if (x >= plus_x and x < plus_x + plus_btn_size) {
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
pub fn handleTablineMouseUp(app: *App, hwnd: c.HWND, x: c_int, y: c_int) void {
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
                app_mod.zonvie_core_send_command(corep, cmd.ptr, cmd.len);
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
            app_mod.zonvie_core_send_command(corep, cmd.ptr, cmd.len);
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

        const drag_threshold = app.scalePx(TablineState.DRAG_THRESHOLD);
        applog.appLog("[tabline] mouseUp: drag_idx={d} moved_distance={d} threshold={d}\n", .{ drag_idx, moved_distance, drag_threshold });

        if (moved_distance < drag_threshold) {
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
                    app_mod.zonvie_core_send_command(corep, cmd.ptr, cmd.len);
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
pub fn createDragPreviewWindow(app: *App, tab_idx: usize, screen_x: c_int, screen_y: c_int) void {
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
pub fn updateDragPreviewPosition(app: *App, screen_x: c_int, screen_y: c_int) void {
    if (app.tabline_state.drag_preview_hwnd) |preview_hwnd| {
        const preview_w: c_int = 150;
        const preview_h: c_int = 30;
        const pos_x = screen_x - @divTrunc(preview_w, 2);
        const pos_y = screen_y - @divTrunc(preview_h, 2);
        _ = c.SetWindowPos(preview_hwnd, null, pos_x, pos_y, 0, 0, c.SWP_NOSIZE | c.SWP_NOZORDER | c.SWP_NOACTIVATE);
    }
}

/// Destroy the drag preview window
pub fn destroyDragPreviewWindow(app: *App) void {
    if (app.tabline_state.drag_preview_hwnd) |preview_hwnd| {
        _ = c.DestroyWindow(preview_hwnd);
        app.tabline_state.drag_preview_hwnd = null;
        applog.appLog("[tabline] destroyed drag preview window\n", .{});
    }
}

/// Externalize a tab by creating an external Neovim window
pub fn externalizeTab(app: *App, tab_idx: usize, screen_x: c_int, screen_y: c_int) void {
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
    app_mod.zonvie_core_send_command(corep, lua_script.ptr, lua_script.len);
}

// Drag preview window class
const drag_preview_class_name: [:0]const u16 = std.unicode.utf8ToUtf16LeStringLiteral("ZonvieDragPreviewClass");
var drag_preview_class_registered: bool = false;

pub fn ensureDragPreviewClassRegistered() bool {
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

pub fn dragPreviewWndProc(hwnd: c.HWND, msg: c.UINT, wParam: c.WPARAM, lParam: c.LPARAM) callconv(.winapi) c.LRESULT {
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
pub fn renderTablineToD3D(app: *App, width: u32, height: u32) void {
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
pub fn drawTablineContent(app: *App, hdc: c.HDC, client_width: c_int) void {
    if (app.tabline_state.tab_count == 0) {
        return;
    }

    const bar_height = app.scalePx(TablineState.TAB_BAR_HEIGHT);
    const tab_min_w = app.scalePx(TablineState.TAB_MIN_WIDTH);
    const tab_max_w = app.scalePx(TablineState.TAB_MAX_WIDTH);
    const tab_padding = app.scalePx(TablineState.TAB_PADDING);
    const close_size = app.scalePx(TablineState.TAB_CLOSE_SIZE);
    const btns_total = app.scalePx(TablineState.WINDOW_BTNS_TOTAL);
    const btn_w = app.scalePx(TablineState.WINDOW_BTN_WIDTH);
    const plus_space = app.scalePx(40);
    const drag_threshold = app.scalePx(TablineState.DRAG_THRESHOLD);
    const close_margin = app.scalePx(6);
    const close_inset = app.scalePx(3);
    const top_padding = app.scalePx(4);
    const plus_offset = app.scalePx(8);
    const plus_btn_size = app.scalePx(20);
    const plus_icon_inset = app.scalePx(5);
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
    const available_width = client_width - app.scalePx(TablineState.WINDOW_CONTROLS_WIDTH) - plus_space - btns_total;
    const tab_count: c_int = @intCast(app.tabline_state.tab_count);
    const ideal_width = @divTrunc(available_width, tab_count);
    const tab_width = @min(tab_max_w, @max(tab_min_w, ideal_width));

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
        app.scalePx(-12), 0, 0, 0, c.FW_NORMAL, 0, 0, 0,
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
        break :blk moved_distance >= drag_threshold;
    } else false;

    var x: c_int = app.scalePx(TablineState.WINDOW_CONTROLS_WIDTH);

    // First pass: draw all tabs (with placeholder for dragged tab)
    for (0..app.tabline_state.tab_count) |i| {
        const tab = &app.tabline_state.tabs[i];
        const is_selected = tab.handle == app.tabline_state.current_tab;
        const is_hovered = app.tabline_state.hovered_tab == i;
        const is_being_dragged = is_actually_dragging and app.tabline_state.dragging_tab == i;

        var tab_rect = c.RECT{
            .left = x + 1,
            .top = top_padding,
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
            .left = x + tab_padding,
            .top = top_padding,
            .right = x + tab_width - tab_padding - close_size - top_padding,
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
            const close_x = x + tab_width - close_size - close_margin;
            const close_y = @divTrunc(bar_height - close_size, 2);

            // Highlight if close button hovered
            if (app.tabline_state.hovered_close == i) {
                const highlight_brush = c.CreateSolidBrush(c.RGB(200, 200, 200));
                var close_rect = c.RECT{
                    .left = close_x,
                    .top = close_y,
                    .right = close_x + close_size,
                    .bottom = close_y + close_size,
                };
                _ = c.FillRect(hdc, &close_rect, highlight_brush);
                _ = c.DeleteObject(highlight_brush);
            }

            // Draw X
            const pen = c.CreatePen(c.PS_SOLID, 1, c.RGB(100, 100, 100));
            const old_pen = c.SelectObject(hdc, pen);
            _ = c.MoveToEx(hdc, close_x + close_inset, close_y + close_inset, null);
            _ = c.LineTo(hdc, close_x + close_size - close_inset, close_y + close_size - close_inset);
            _ = c.MoveToEx(hdc, close_x + close_size - close_inset, close_y + close_inset, null);
            _ = c.LineTo(hdc, close_x + close_inset, close_y + close_size - close_inset);
            _ = c.SelectObject(hdc, old_pen);
            _ = c.DeleteObject(pen);
        }

        x += tab_width + 1;
    }

    // Draw new tab button (+)
    const plus_x = x + plus_offset;
    const plus_y = @divTrunc(bar_height - plus_btn_size, 2);
    {
        // Draw hover background (circular) if hovered
        if (app.tabline_state.hovered_new_tab_btn) {
            const plus_hover_brush = c.CreateSolidBrush(c.RGB(200, 200, 200));
            _ = c.SelectObject(hdc, plus_hover_brush);
            const null_pen = c.GetStockObject(c.NULL_PEN);
            const old_pen_hover = c.SelectObject(hdc, null_pen);
            _ = c.Ellipse(hdc, plus_x, plus_y, plus_x + plus_btn_size, plus_y + plus_btn_size);
            _ = c.SelectObject(hdc, old_pen_hover);
            _ = c.DeleteObject(plus_hover_brush);
        }

        // Draw + icon
        const pen = c.CreatePen(c.PS_SOLID, 2, c.RGB(100, 100, 100));
        const old_pen = c.SelectObject(hdc, pen);
        _ = c.MoveToEx(hdc, plus_x + @divTrunc(plus_btn_size, 2), plus_y + plus_icon_inset, null);
        _ = c.LineTo(hdc, plus_x + @divTrunc(plus_btn_size, 2), plus_y + plus_btn_size - plus_icon_inset);
        _ = c.MoveToEx(hdc, plus_x + plus_icon_inset, plus_y + @divTrunc(plus_btn_size, 2), null);
        _ = c.LineTo(hdc, plus_x + plus_btn_size - plus_icon_inset, plus_y + @divTrunc(plus_btn_size, 2));
        _ = c.SelectObject(hdc, old_pen);
        _ = c.DeleteObject(pen);
    }

    // Draw window control buttons (min, max, close) on the right
    const btn_start_x = client_width - btns_total;

    // DPI-scaled icon geometry (icon is 10px at 96 DPI, centered in btn_w)
    const wbtn_icon_size = app.scalePx(10);
    const wbtn_icon_inset = @divTrunc(btn_w - wbtn_icon_size, 2);
    const wbtn_pen_width: c_int = @max(1, app.scalePx(1));

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
        const min_icon_pen = c.CreatePen(c.PS_SOLID, wbtn_pen_width, c.RGB(50, 50, 50));
        const old_min_icon_pen = c.SelectObject(hdc, min_icon_pen);
        const icon_y = @divTrunc(bar_height, 2);
        _ = c.MoveToEx(hdc, btn_x + wbtn_icon_inset, icon_y, null);
        _ = c.LineTo(hdc, btn_x + wbtn_icon_inset + wbtn_icon_size, icon_y);
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
        const max_icon_pen = c.CreatePen(c.PS_SOLID, wbtn_pen_width, c.RGB(50, 50, 50));
        const old_max_icon_pen = c.SelectObject(hdc, max_icon_pen);
        const max_null_brush = c.GetStockObject(c.NULL_BRUSH);
        const old_max_brush = c.SelectObject(hdc, max_null_brush);
        const max_icon_top = @divTrunc(bar_height - wbtn_icon_size, 2);
        _ = c.Rectangle(hdc, btn_x + wbtn_icon_inset, max_icon_top, btn_x + wbtn_icon_inset + wbtn_icon_size, max_icon_top + wbtn_icon_size);
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
        const close_icon_pen = c.CreatePen(c.PS_SOLID, wbtn_pen_width, close_icon_color);
        const old_close_icon_pen = c.SelectObject(hdc, close_icon_pen);
        const close_icon_top = @divTrunc(bar_height - wbtn_icon_size, 2);
        _ = c.MoveToEx(hdc, btn_x + wbtn_icon_inset, close_icon_top, null);
        _ = c.LineTo(hdc, btn_x + wbtn_icon_inset + wbtn_icon_size, close_icon_top + wbtn_icon_size);
        _ = c.MoveToEx(hdc, btn_x + wbtn_icon_inset + wbtn_icon_size, close_icon_top, null);
        _ = c.LineTo(hdc, btn_x + wbtn_icon_inset, close_icon_top + wbtn_icon_size);
        _ = c.SelectObject(hdc, old_close_icon_pen);
        _ = c.DeleteObject(close_icon_pen);
    }

    // Draw drop indicator and floating tab only when actually dragging (moved beyond threshold)
    if (is_actually_dragging) {
        if (app.tabline_state.drop_target_index) |target_idx| {
            const drag_idx = app.tabline_state.dragging_tab orelse 0;
            // Only show indicator if target is different from current position
            if (target_idx != drag_idx and target_idx != drag_idx + 1) {
                const indicator_x: c_int = app.scalePx(TablineState.WINDOW_CONTROLS_WIDTH) + @as(c_int, @intCast(target_idx)) * (tab_width + 1);
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
                .top = top_padding,
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
                .left = float_x + tab_padding,
                .top = top_padding,
                .right = float_x + tab_width - tab_padding,
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

pub fn onTablineUpdate(
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
        _ = c.PostMessageW(main_hwnd, app_mod.WM_APP_TABLINE_INVALIDATE, 0, 0);
    }
}

pub fn onTablineHide(ctx: ?*anyopaque) callconv(.c) void {
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
pub fn drawTabline(app: *App, hdc: c.HDC, client_width: c_int) void {
    if (!app.ext_tabline_enabled or !app.tabline_state.visible) return;
    if (app.tabline_state.tab_count == 0) return;

    applog.appLog("[win] drawTabline: tab_count={d} current_tab={d} width={d}\n", .{
        app.tabline_state.tab_count,
        app.tabline_state.current_tab,
        client_width,
    });

    // DPI-scaled constants
    const bar_height = app.scalePx(TablineState.TAB_BAR_HEIGHT);
    const tab_min_w = app.scalePx(TablineState.TAB_MIN_WIDTH);
    const tab_max_w = app.scalePx(TablineState.TAB_MAX_WIDTH);
    const tab_padding = app.scalePx(TablineState.TAB_PADDING);
    const close_size = app.scalePx(TablineState.TAB_CLOSE_SIZE);
    const btns_total = app.scalePx(TablineState.WINDOW_BTNS_TOTAL);
    const plus_space = app.scalePx(40);
    const close_margin = app.scalePx(6);
    const close_inset = app.scalePx(3);
    const top_padding = app.scalePx(4);
    const plus_offset = app.scalePx(8);

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
    const available_width = client_width - app.scalePx(TablineState.WINDOW_CONTROLS_WIDTH) - plus_space - btns_total;  // plus_space for new tab button
    const tab_count: c_int = @intCast(app.tabline_state.tab_count);
    const ideal_width = @divTrunc(available_width, tab_count);
    const tab_width = @min(tab_max_w, @max(tab_min_w, ideal_width));

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
        app.scalePx(-12), 0, 0, 0, c.FW_NORMAL, 0, 0, 0,
        c.DEFAULT_CHARSET, c.OUT_DEFAULT_PRECIS, c.CLIP_DEFAULT_PRECIS,
        c.CLEARTYPE_QUALITY, c.DEFAULT_PITCH | c.FF_DONTCARE, null,
    );
    defer _ = c.DeleteObject(font);
    const old_font = c.SelectObject(hdc, font);
    defer _ = c.SelectObject(hdc, old_font);

    _ = c.SetBkMode(hdc, c.TRANSPARENT);

    var x: c_int = app.scalePx(TablineState.WINDOW_CONTROLS_WIDTH);

    for (0..app.tabline_state.tab_count) |i| {
        const tab = &app.tabline_state.tabs[i];
        const is_selected = tab.handle == app.tabline_state.current_tab;
        const is_hovered = app.tabline_state.hovered_tab == i;

        var tab_rect = c.RECT{
            .left = x + 1,
            .top = top_padding,
            .right = x + tab_width - 1,
            .bottom = bar_height,
        };

        // Background
        const brush = if (is_selected) selected_brush else if (is_hovered) hover_brush else normal_brush;
        _ = c.FillRect(hdc, &tab_rect, brush);

        // Tab name
        _ = c.SetTextColor(hdc, if (is_selected) c.RGB(0, 0, 0) else c.RGB(80, 80, 80));

        var text_rect = c.RECT{
            .left = x + tab_padding,
            .top = top_padding,
            .right = x + tab_width - tab_padding - close_size - top_padding,
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
            const close_x = x + tab_width - close_size - close_margin;
            const close_y = @divTrunc(bar_height - close_size, 2);
            const is_close_hovered = app.tabline_state.hovered_close == i;

            if (is_close_hovered) {
                const close_bg = c.CreateSolidBrush(c.RGB(200, 200, 200));
                var close_rect = c.RECT{
                    .left = close_x,
                    .top = close_y,
                    .right = close_x + close_size,
                    .bottom = close_y + close_size,
                };
                _ = c.FillRect(hdc, &close_rect, close_bg);
                _ = c.DeleteObject(close_bg);
            }

            // Draw X
            const pen = c.CreatePen(c.PS_SOLID, 1, if (is_close_hovered) c.RGB(0, 0, 0) else c.RGB(100, 100, 100));
            const old_pen = c.SelectObject(hdc, pen);
            _ = c.MoveToEx(hdc, close_x + close_inset, close_y + close_inset, null);
            _ = c.LineTo(hdc, close_x + close_size - close_inset, close_y + close_size - close_inset);
            _ = c.MoveToEx(hdc, close_x + close_size - close_inset, close_y + close_inset, null);
            _ = c.LineTo(hdc, close_x + close_inset, close_y + close_size - close_inset);
            _ = c.SelectObject(hdc, old_pen);
            _ = c.DeleteObject(pen);
        }

        x += tab_width + 1;
    }

    // Draw + button
    const plus_btn_size = app.scalePx(16);
    const plus_x = x + plus_offset;
    const plus_y = @divTrunc(bar_height - plus_btn_size, 2);
    const plus_pen = c.CreatePen(c.PS_SOLID, 2, c.RGB(100, 100, 100));
    const old_pen = c.SelectObject(hdc, plus_pen);
    const plus_half = @divTrunc(plus_btn_size, 2);
    _ = c.MoveToEx(hdc, plus_x + plus_half, plus_y, null);
    _ = c.LineTo(hdc, plus_x + plus_half, plus_y + plus_btn_size);
    _ = c.MoveToEx(hdc, plus_x, plus_y + plus_half, null);
    _ = c.LineTo(hdc, plus_x + plus_btn_size, plus_y + plus_half);
    _ = c.SelectObject(hdc, old_pen);
    _ = c.DeleteObject(plus_pen);
}

/// Handle tabline mouse click
pub fn handleTablineClick(app: *App, x: c_int, y: c_int) bool {
    if (!app.ext_tabline_enabled or !app.tabline_state.visible) return false;

    // DPI-scaled constants
    const bar_height = app.scalePx(TablineState.TAB_BAR_HEIGHT);
    const tab_min_w = app.scalePx(TablineState.TAB_MIN_WIDTH);
    const tab_max_w = app.scalePx(TablineState.TAB_MAX_WIDTH);
    const close_size = app.scalePx(TablineState.TAB_CLOSE_SIZE);
    const btns_total = app.scalePx(TablineState.WINDOW_BTNS_TOTAL);
    const btn_w = app.scalePx(TablineState.WINDOW_BTN_WIDTH);
    const plus_space = app.scalePx(40);
    const close_margin = app.scalePx(6);
    const plus_offset = app.scalePx(8);
    const plus_btn_size = app.scalePx(20);

    if (y >= bar_height) return false;  // Below tab bar

    // Get client width
    var rect: c.RECT = undefined;
    const main_hwnd = app.hwnd orelse return false;
    _ = c.GetClientRect(main_hwnd, &rect);
    const client_width = rect.right;

    // Check window control buttons first (right side)
    const btn_start_x = client_width - btns_total;
    if (x >= btn_start_x) {
        const btn_idx = @divTrunc(x - btn_start_x, btn_w);
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
    const available_width = client_width - app.scalePx(TablineState.WINDOW_CONTROLS_WIDTH) - plus_space - btns_total;
    const tab_count: c_int = @intCast(app.tabline_state.tab_count);
    if (tab_count == 0) return false;
    const ideal_width = @divTrunc(available_width, tab_count);
    const tab_width = @min(tab_max_w, @max(tab_min_w, ideal_width));

    // Check + button
    const plus_x = app.scalePx(TablineState.WINDOW_CONTROLS_WIDTH) + tab_count * (tab_width + 1) + plus_offset;
    if (x >= plus_x and x < plus_x + plus_btn_size) {
        // New tab - use nvim_command API to avoid showing in cmdline
        if (app.corep) |corep| {
            const cmd = "tabnew";
            app_mod.zonvie_core_send_command(corep, cmd.ptr, cmd.len);
        }
        // Force immediate repaint
        _ = c.InvalidateRect(main_hwnd, null, 0);
        _ = c.UpdateWindow(main_hwnd);
        return true;
    }

    // Check tabs
    var tab_x: c_int = app.scalePx(TablineState.WINDOW_CONTROLS_WIDTH);
    for (0..app.tabline_state.tab_count) |i| {
        if (x >= tab_x and x < tab_x + tab_width) {
            // Check close button
            const close_x = tab_x + tab_width - close_size - close_margin;
            const close_y = @divTrunc(bar_height - close_size, 2);

            if (x >= close_x and x < close_x + close_size and
                y >= close_y and y < close_y + close_size)
            {
                // Close this tab - use nvim_command API to avoid showing in cmdline
                if (app.corep) |corep| {
                    var cmd_buf: [48]u8 = undefined;
                    const cmd = std.fmt.bufPrint(&cmd_buf, "{d}tabclose", .{i + 1}) catch return true;
                    app_mod.zonvie_core_send_command(corep, cmd.ptr, cmd.len);
                }
                // Force immediate repaint
                _ = c.InvalidateRect(main_hwnd, null, 0);
                _ = c.UpdateWindow(main_hwnd);
                return true;
            }

            // Select this tab - use nvim_command API so it works even in terminal mode
            if (app.corep) |corep| {
                var cmd_buf: [16]u8 = undefined;
                const cmd = std.fmt.bufPrint(&cmd_buf, "{d}tabnext", .{i + 1}) catch return true;
                app_mod.zonvie_core_send_command(corep, cmd.ptr, cmd.len);
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
pub fn handleTablineMouseMove(app: *App, x: c_int, y: c_int) void {
    if (!app.ext_tabline_enabled or !app.tabline_state.visible) return;

    // DPI-scaled constants
    const bar_height = app.scalePx(TablineState.TAB_BAR_HEIGHT);
    const tab_min_w = app.scalePx(TablineState.TAB_MIN_WIDTH);
    const tab_max_w = app.scalePx(TablineState.TAB_MAX_WIDTH);
    const close_size = app.scalePx(TablineState.TAB_CLOSE_SIZE);
    const btns_total = app.scalePx(TablineState.WINDOW_BTNS_TOTAL);
    const plus_space = app.scalePx(40);
    const close_margin = app.scalePx(6);

    var new_hovered_tab: ?usize = null;
    var new_hovered_close: ?usize = null;

    if (y < bar_height) {
        var rect: c.RECT = undefined;
        if (app.hwnd) |hwnd| {
            _ = c.GetClientRect(hwnd, &rect);
        } else {
            return;
        }
        const client_width = rect.right;

        const available_width = client_width - app.scalePx(TablineState.WINDOW_CONTROLS_WIDTH) - plus_space - btns_total;
        const tab_count: c_int = @intCast(app.tabline_state.tab_count);
        if (tab_count > 0) {
            const ideal_width = @divTrunc(available_width, tab_count);
            const tab_width = @min(tab_max_w, @max(tab_min_w, ideal_width));

            var tab_x: c_int = app.scalePx(TablineState.WINDOW_CONTROLS_WIDTH);
            for (0..app.tabline_state.tab_count) |i| {
                if (x >= tab_x and x < tab_x + tab_width) {
                    new_hovered_tab = i;

                    // Check close button
                    const close_x = tab_x + tab_width - close_size - close_margin;
                    const close_y = @divTrunc(bar_height - close_size, 2);
                    if (x >= close_x and x < close_x + close_size and
                        y >= close_y and y < close_y + close_size)
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
                .bottom = bar_height,
            };
            _ = c.GetClientRect(hwnd, &tab_rect);
            tab_rect.bottom = bar_height;
            _ = c.InvalidateRect(hwnd, &tab_rect, 0);
        }
    }
}
