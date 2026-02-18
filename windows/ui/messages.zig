const std = @import("std");
const app_mod = @import("../app.zig");
const App = app_mod.App;
const c = app_mod.c;
const applog = app_mod.applog;
const d3d11 = app_mod.d3d11;
const dwrite_d2d = app_mod.dwrite_d2d;
const core = @import("zonvie_core");
const external_windows = @import("external_windows.zig");

pub fn onMsgShow(
    ctx: ?*anyopaque,
    view: app_mod.zonvie_msg_view_type,
    kind: [*]const u8,
    kind_len: usize,
    chunks: [*]const app_mod.MsgChunk,
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

    var req = app_mod.PendingMessageRequest{};
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
        _ = c.PostMessageW(main_hwnd, app_mod.WM_APP_MSG_SHOW, 0, 0);
    }
}

pub fn onMsgClear(ctx: ?*anyopaque) callconv(.c) void {
    const app: *App = @ptrCast(@alignCast(ctx.?));
    if (applog.isEnabled()) applog.appLog("[win] on_msg_clear\n", .{});

    // Post message to UI thread to hide window
    if (app.hwnd) |main_hwnd| {
        _ = c.PostMessageW(main_hwnd, app_mod.WM_APP_MSG_CLEAR, 0, 0);
    }
}

pub fn onMsgShowmode(ctx: ?*anyopaque, view: app_mod.zonvie_msg_view_type, chunks: [*]const app_mod.MsgChunk, chunk_count: usize) callconv(.c) void {
    const app: *App = @ptrCast(@alignCast(ctx.?));
    handleMsgMiniOrExtFloat(app, view, .msg_showmode, .showmode, "showmode", chunks, chunk_count);
}

pub fn onMsgShowcmd(ctx: ?*anyopaque, view: app_mod.zonvie_msg_view_type, chunks: [*]const app_mod.MsgChunk, chunk_count: usize) callconv(.c) void {
    const app: *App = @ptrCast(@alignCast(ctx.?));
    handleMsgMiniOrExtFloat(app, view, .msg_showcmd, .showcmd, "showcmd", chunks, chunk_count);
}

pub fn onMsgRuler(ctx: ?*anyopaque, view: app_mod.zonvie_msg_view_type, chunks: [*]const app_mod.MsgChunk, chunk_count: usize) callconv(.c) void {
    const app: *App = @ptrCast(@alignCast(ctx.?));
    handleMsgMiniOrExtFloat(app, view, .msg_ruler, .ruler, "ruler", chunks, chunk_count);
}

/// Common handler for showmode/showcmd/ruler that can route to mini or ext_float
pub fn handleMsgMiniOrExtFloat(
    app: *App,
    view: app_mod.zonvie_msg_view_type,
    event: core.zonvie_msg_event,
    mini_id: app_mod.MiniWindowId,
    kind_str: []const u8,
    chunks: [*]const app_mod.MsgChunk,
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
    const route_result = app_mod.zonvie_core_route_message(app.corep, event, null, 1);

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
                _ = c.PostMessageW(main_hwnd, app_mod.WM_APP_MINI_UPDATE, @as(c.WPARAM, idx), 0);
            }
        },
        .ext_float => {
            // Queue message for ext_float display
            app.mu.lock();
            defer app.mu.unlock();

            var req = app_mod.PendingMessageRequest{};
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
                _ = c.PostMessageW(main_hwnd, app_mod.WM_APP_MSG_SHOW, 0, 0);
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
                _ = c.PostMessageW(main_hwnd, app_mod.WM_APP_MINI_UPDATE, @as(c.WPARAM, idx), 0);
            }
        },
    }
}

/// Update mini window text directly (for UI thread usage)
pub fn updateMiniText(app: *App, id: app_mod.MiniWindowId, text: []const u8) void {
    const idx = @intFromEnum(id);
    const copy_len = @min(text.len, app.mini_windows[idx].text.len);
    @memcpy(app.mini_windows[idx].text[0..copy_len], text[0..copy_len]);
    app.mini_windows[idx].text_len = copy_len;
}

/// Common handler for mini window updates from callbacks
pub fn updateMiniFromCallback(app: *App, id: app_mod.MiniWindowId, chunks: [*]const app_mod.MsgChunk, chunk_count: usize) void {
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
        _ = c.PostMessageW(main_hwnd, app_mod.WM_APP_MINI_UPDATE, @as(c.WPARAM, idx), 0);
    }
}

pub fn onMsgHistoryShow(
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

    var req = app_mod.PendingMessageRequest{};
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
        _ = c.PostMessageW(main_hwnd, app_mod.WM_APP_MSG_SHOW, 0, 0);
    }
}

pub fn showMessageWindowOnUIThread(app: *App, msg: app_mod.DisplayMessage) void {
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
    const cell_h = app.cell_h_px + app.linespace_px;
    const padding: c_int = app.scalePx(16);

    // Get app window position and size (position relative to app window, not screen)
    var app_rect: c.RECT = undefined;
    const main_hwnd = app.hwnd orelse return;
    _ = c.GetWindowRect(main_hwnd, &app_rect);
    const app_width = app_rect.right - app_rect.left;
    const app_height = app_rect.bottom - app_rect.top;

    // Calculate window size based on message type
    var window_width: c_int = undefined;
    var window_height: c_int = undefined;
    const line_height: c_int = @as(c_int, @intCast(cell_h)) + app.scalePx(4);

    if (is_confirm) {
        // For confirm dialogs (like E325), use larger fixed width and calculate height
        // based on line count. The text will be word-wrapped.
        window_width = @max(app.scalePx(100), @min(app.scalePx(800), app_width - app.scalePx(40)));
        // Height: line_count * line_height + padding, but at least 200px for readability
        const calc_height: c_int = @intCast(@as(u32, @intCast(line_height)) * line_count + @as(u32, @intCast(padding * 2)));
        window_height = @max(app.scalePx(200), @min(calc_height, app_height - app.scalePx(100)));
        if (applog.isEnabled()) applog.appLog("[win] confirm dialog: line_count={d} calc_height={d} window_height={d}\n", .{ line_count, calc_height, window_height });
    } else {
        // For regular messages, use text-based width calculation
        const text_len_int: c_int = @intCast(combined_len);
        const estimated_width: c_int = @intCast(@as(u32, @intCast(text_len_int)) * (cell_h / 2) + @as(u32, @intCast(padding * 2)));
        window_width = @max(app.scalePx(100), @min(estimated_width, app.scalePx(600)));
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
            const cmdline_reserve: c_int = @as(c_int, @intCast(cell_h)) + app.scalePx(8);
            const available_height = app_height - cmdline_reserve;
            window_y = app_rect.top + @divTrunc(available_height - window_height, 2);
            // Ensure it doesn't go above app window
            if (window_y < app_rect.top + app.scalePx(10)) {
                window_y = app_rect.top + app.scalePx(10);
            }
        }
        if (applog.isEnabled()) applog.appLog("[win] confirm dialog position: x={d} y={d} ext_cmdline={}\n", .{ window_x, window_y, app.ext_cmdline_enabled });
    } else if (is_prompt) {
        // Bottom center for other prompts (relative to app window)
        window_x = app_rect.left + @divTrunc(app_width - window_width, 2);
        window_y = app_rect.bottom - window_height - app.scalePx(40);
    } else {
        // Top-right for regular messages (screen coordinates like msg_history/macOS)
        const screen_w = c.GetSystemMetrics(c.SM_CXSCREEN);
        window_x = screen_w - window_width - app.scalePx(10);
        window_y = app.scalePx(10);
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
    if (!external_windows.ensureExternalWindowClassRegistered()) {
        if (applog.isEnabled()) applog.appLog("[win] message window class registration failed\n", .{});
        return;
    }

    // Create window
    const msg_hwnd = c.CreateWindowExW(
        c.WS_EX_TOPMOST | c.WS_EX_TOOLWINDOW | c.WS_EX_NOACTIVATE,
        @ptrCast(external_windows.external_window_class_name.ptr),
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
    var msg_win = app_mod.MessageWindow{
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
pub fn hideMessageWindow(app: *App) void {
    if (app.message_window) |*msg_win| {
        if (applog.isEnabled()) applog.appLog("[win] hiding message window\n", .{});
        msg_win.deinit();
        app.message_window = null;
    }
    // Clear display messages stack
    app.display_messages.clearRetainingCapacity();
}

/// Resize external window asynchronously.
/// Called via WM_APP_RESIZE_POPUPMENU to avoid deadlock with WM_SIZE handler.
/// Handles cmdline (keep center), popupmenu (keep top-left), and regular ext_windows (keep top-left).
pub fn resizeExternalWindowDeferred(app: *App, grid_id: i64) void {
    // Get pending resize info while mutex is locked
    app.mu.lock();
    const ext_win = app.external_windows.getPtr(grid_id) orelse {
        app.mu.unlock();
        return;
    };

    // Skip if window is pending close or doesn't need resize
    if (ext_win.is_pending_close or !ext_win.needs_window_resize) {
        app.mu.unlock();
        return;
    }

    const ext_hwnd = ext_win.hwnd;
    const window_w = ext_win.pending_window_w;
    const window_h = ext_win.pending_window_h;
    const is_cmdline = (grid_id == app_mod.CMDLINE_GRID_ID);
    ext_win.needs_window_resize = false;
    app.mu.unlock();

    // Get current window rect (outside lock)
    var current_rect: c.RECT = undefined;
    if (c.GetWindowRect(ext_hwnd, &current_rect) == 0) {
        // GetWindowRect failed, skip resize
        if (applog.isEnabled()) applog.appLog("[win] resizeExternalWindowDeferred: GetWindowRect failed for grid_id={d}\n", .{grid_id});
        return;
    }

    // Calculate position: cmdline re-centers on display, others keep top-left
    var pos_x: c_int = undefined;
    var pos_y: c_int = undefined;
    if (is_cmdline) {
        // Re-center cmdline on the current monitor after font size change.
        // Preserving the old position caused visible drift on repeated changes.
        const monitor = c.MonitorFromWindow(ext_hwnd, c.MONITOR_DEFAULTTONEAREST);
        if (monitor) |mon| {
            var mi: c.MONITORINFO = std.mem.zeroes(c.MONITORINFO);
            mi.cbSize = @sizeOf(c.MONITORINFO);
            if (c.GetMonitorInfoW(mon, &mi) != 0) {
                const work_w = mi.rcWork.right - mi.rcWork.left;
                const work_h = mi.rcWork.bottom - mi.rcWork.top;
                pos_x = mi.rcWork.left + @divTrunc(work_w - window_w, 2);
                pos_y = mi.rcWork.top + @divTrunc(work_h - window_h, 3);
            } else {
                const screen_w = c.GetSystemMetrics(c.SM_CXSCREEN);
                const screen_h = c.GetSystemMetrics(c.SM_CYSCREEN);
                pos_x = @divTrunc(screen_w - window_w, 2);
                pos_y = @divTrunc(screen_h - window_h, 3);
            }
        } else {
            const screen_w = c.GetSystemMetrics(c.SM_CXSCREEN);
            const screen_h = c.GetSystemMetrics(c.SM_CYSCREEN);
            pos_x = @divTrunc(screen_w - window_w, 2);
            pos_y = @divTrunc(screen_h - window_h, 3);
        }
    } else {
        pos_x = current_rect.left;
        pos_y = current_rect.top;
    }

    if (applog.isEnabled()) applog.appLog("[win] resizeExternalWindowDeferred: grid_id={d} window=({d},{d}) at ({d},{d})\n", .{ grid_id, window_w, window_h, pos_x, pos_y });

    // Resize window (outside lock, safe from deadlock).
    // SetWindowPos sends WM_SIZE synchronously - suppress_resize_callback prevents feedback loop.
    _ = c.SetWindowPos(
        ext_hwnd,
        null,
        pos_x,
        pos_y,
        window_w,
        window_h,
        c.SWP_NOACTIVATE | c.SWP_NOZORDER,
    );

    // Clear suppress_resize_callback after SetWindowPos completes.
    // (SetWindowPos sends WM_SIZE synchronously, so by this point it's already handled.)
    app.mu.lock();
    if (app.external_windows.getPtr(grid_id)) |ew| {
        ew.suppress_resize_callback = false;
    }
    // Clear saved cmdline position after programmatic resize (e.g. font change).
    // SetWindowPos triggers WM_WINDOWPOSCHANGED which re-saves the position,
    // but this stale position would prevent proper re-centering next time.
    if (is_cmdline) {
        app.cmdline_saved_x = null;
        app.cmdline_saved_y = null;
    }
    app.mu.unlock();
}

/// Update ext-float (msg_show/msg_history) window positions
/// Called asynchronously via WM_APP_UPDATE_EXT_FLOAT_POS to avoid deadlock
pub fn updateExtFloatPositions(app: *App) void {
    const main_hwnd = app.hwnd orelse return;

    // Get data while mutex is locked
    app.mu.lock();
    const cell_w = app.cell_w_px;
    const cell_h = app.cell_h_px + app.linespace_px;
    const linespace = app.linespace_px;
    const cursor_grid = app.last_cursor_grid;
    const pos_mode = app.config.messages.msg_pos.ext_float;
    const cursor_ext_hwnd: ?c.HWND = if (app.external_windows.get(cursor_grid)) |ew| ew.hwnd else null;
    const msg_show_entry = app.external_windows.getPtr(app_mod.MESSAGE_GRID_ID);
    const msg_history_entry = app.external_windows.getPtr(app_mod.MSG_HISTORY_GRID_ID);
    const corep = app.corep;

    // Copy window info
    const msg_show_hwnd: ?c.HWND = if (msg_show_entry) |e| e.hwnd else null;
    const msg_show_rows: u32 = if (msg_show_entry) |e| e.rows else 0;
    const msg_show_cols: u32 = if (msg_show_entry) |e| e.cols else 0;
    const msg_history_hwnd: ?c.HWND = if (msg_history_entry) |e| e.hwnd else null;
    const msg_history_rows: u32 = if (msg_history_entry) |e| e.rows else 0;
    const msg_history_cols: u32 = if (msg_history_entry) |e| e.cols else 0;
    // When using DWM custom titlebar, client area extends into the titlebar.
    // Compute offset to position floats below the custom titlebar area.
    const titlebar_offset: c_int = if (app.ext_tabline_enabled and app.tabline_style == .titlebar and app.content_hwnd == null)
        app.scalePx(app_mod.TablineState.TAB_BAR_HEIGHT)
    else
        0;
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
                        .top = pt.y + titlebar_offset,
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
                    const cached = app.getVisibleGridsCached(cp);
                    if (cached.count > 0) {
                        for (cached.grids[0..cached.count]) |grid| {
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
                    .top = client_origin.y + titlebar_offset,
                    .right = client_origin.x + grid_right_px,
                    .bottom = client_origin.y + grid_bottom_px,
                };
            }
        },
    }

    // Update msg_history position first (if exists)
    const float_margin = app.scalePx(10);
    var history_bottom: c_int = target_rect.top + float_margin;
    if (msg_history_hwnd) |hwnd| {
        const content_w: c_int = @intCast(msg_history_cols * cell_w);
        const content_h: c_int = @intCast(msg_history_rows * cell_h);
        const scaled_msg_padding = app.scalePx(@as(c_int, app_mod.MSG_PADDING));
        const client_w: c_int = content_w + scaled_msg_padding * 2;
        const client_h: c_int = content_h + scaled_msg_padding * 2;

        var rect: c.RECT = .{ .left = 0, .top = 0, .right = client_w, .bottom = client_h };
        _ = c.AdjustWindowRectEx(&rect, c.WS_POPUP, 0, c.WS_EX_TOPMOST);
        const window_w: c_int = rect.right - rect.left;
        const window_h: c_int = rect.bottom - rect.top;

        const pos_x = target_rect.right - window_w - float_margin;
        const pos_y: c_int = target_rect.top + float_margin;
        history_bottom = pos_y + window_h;

        _ = c.SetWindowPos(hwnd, null, pos_x, pos_y, window_w, window_h, c.SWP_NOACTIVATE | c.SWP_NOZORDER);
        _ = c.InvalidateRect(hwnd, null, 0);
        if (applog.isEnabled()) applog.appLog("[win] updateExtFloatPositions: msg_history at ({d},{d}) size=({d},{d})\n", .{ pos_x, pos_y, window_w, window_h });
    }

    // Update msg_show position (if exists)
    if (msg_show_hwnd) |hwnd| {
        const content_w: c_int = @intCast(msg_show_cols * cell_w);
        const content_h: c_int = @intCast(msg_show_rows * cell_h);
        const scaled_msg_padding2 = app.scalePx(@as(c_int, app_mod.MSG_PADDING));
        const client_w: c_int = content_w + scaled_msg_padding2 * 2;
        const client_h: c_int = content_h + scaled_msg_padding2 * 2;

        var rect: c.RECT = .{ .left = 0, .top = 0, .right = client_w, .bottom = client_h };
        _ = c.AdjustWindowRectEx(&rect, c.WS_POPUP, 0, c.WS_EX_TOPMOST);
        const window_w: c_int = rect.right - rect.left;
        const window_h: c_int = rect.bottom - rect.top;

        const pos_x = target_rect.right - window_w - float_margin;
        // If msg_history exists, position below it; otherwise at top
        const pos_y: c_int = if (msg_history_hwnd != null) history_bottom + app.scalePx(4) else target_rect.top + float_margin;

        _ = c.SetWindowPos(hwnd, null, pos_x, pos_y, window_w, window_h, c.SWP_NOACTIVATE | c.SWP_NOZORDER);
        _ = c.InvalidateRect(hwnd, null, 0);
        if (applog.isEnabled()) applog.appLog("[win] updateExtFloatPositions: msg_show at ({d},{d}) size=({d},{d})\n", .{ pos_x, pos_y, window_w, window_h });
    }
}

/// Update or create mini windows (showmode / showcmd / ruler)
pub fn updateMiniWindows(app: *App) void {
    const main_hwnd = app.hwnd orelse return;

    // Get cell dimensions and config
    app.mu.lock();
    const cell_w = app.cell_w_px;
    const cell_h = app.cell_h_px + app.linespace_px;
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
                // Try to get grid bounds from core (non-blocking)
                if (app.corep) |corep| {
                    const cached = app.getVisibleGridsCached(corep);
                    if (cached.count > 0) {
                        for (cached.grids[0..cached.count]) |grid| {
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

        // Calculate width based on text (use cell_w for DPI-aware char width + scaled padding)
        const text_len_i: c_int = @intCast(text_len);
        const text_width: c_int = text_len_i * @as(c_int, @intCast(cell_w)) + app.scalePx(16);
        const window_width: c_int = @max(app.scalePx(50), text_width);

        // Position: right edge of target area, stacking upward from bottom
        const window_x = anchor_x - window_width;
        const window_y = anchor_y - window_height - @as(c_int, @intCast(stack_index)) * window_height;

        if (app.mini_windows[idx].hwnd) |mini_hwnd| {
            // Update existing window position and size
            _ = c.SetWindowPos(mini_hwnd, null, window_x, window_y, window_width, window_height, c.SWP_NOZORDER | c.SWP_NOACTIVATE);
            _ = c.InvalidateRect(mini_hwnd, null, c.TRUE);
        } else {
            // Create new mini window
            if (!external_windows.ensureExternalWindowClassRegistered()) continue;

            const use_transparency = app.config.window.opacity < 1.0;
            const base_style: c.DWORD = c.WS_EX_TOPMOST | c.WS_EX_TOOLWINDOW | c.WS_EX_NOACTIVATE;
            const dwExStyle: c.DWORD = if (use_transparency) base_style | c.WS_EX_LAYERED else base_style;

            const mini_hwnd = c.CreateWindowExW(
                dwExStyle,
                @ptrCast(external_windows.external_window_class_name.ptr),
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

pub fn paintMessageWindow(hwnd: c.HWND, app: *App) void {
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
        const found = app_mod.zonvie_core_get_hl_by_name(corep, "Normal", &fg, &bg);
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
    const padding: c_int = app.scalePx(12);
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
pub fn paintMiniWindow(hwnd: c.HWND, app: *App) void {
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
    inline for ([_]app_mod.MiniWindowId{ .showmode, .showcmd, .ruler }) |id| {
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
        const found = app_mod.zonvie_core_get_hl_by_name(corep, "Normal", &fg, &bg);
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
    const mini_pad = app.scalePx(4);
    var text_rect = c.RECT{
        .left = rect.left + mini_pad,
        .top = rect.top,
        .right = rect.right - mini_pad,
        .bottom = rect.bottom,
    };

    _ = c.DrawTextW(hdc, @ptrCast(&text_utf16), @intCast(text_utf16_len), &text_rect, c.DT_CENTER | c.DT_VCENTER | c.DT_SINGLELINE);

    if (applog.isEnabled()) applog.appLog("[win] paintMiniWindow done\n", .{});
}
