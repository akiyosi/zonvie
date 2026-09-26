const std = @import("std");
const app_mod = @import("../app.zig");
const App = app_mod.App;
const c = app_mod.c;
const applog = app_mod.applog;
const d3d11 = app_mod.d3d11;
const dwrite_d2d = app_mod.dwrite_d2d;
const core = @import("zonvie_core");
const external_windows = @import("external_windows.zig");
const input = @import("../input.zig");
const callbacks = @import("../callbacks.zig");

/// The grid a `.grid`-anchored message box hangs off: the cursor's, or, for a
/// cursor inside a float (a telescope prompt), the window the float is
/// anchored to. Grid 1 when the chain dead-ends. macOS's cursorAnchorGrid.
fn cursorAnchorGridId(grids: []const app_mod.GridInfo, cursor_grid: i64) i64 {
    var current: i64 = cursor_grid;
    var hops: u32 = 0;
    while (hops < 8) : (hops += 1) {
        const g = for (grids) |g| {
            if (g.grid_id == current) break g;
        } else return 1;
        if (g.zindex <= 0) return g.grid_id;
        current = g.anchor_grid;
    }
    return 1;
}

/// The main window's grid area in screen pixels: the client rect less its
/// chrome (a titlebar tabline, a sidebar on either side). macOS measures
/// against the terminal view for the same reason.
fn mainSurfaceRect(client_screen: c.RECT, origin_x: c_int, origin_y: c_int, right_chrome_px: c_int) c.RECT {
    return .{
        .left = client_screen.left + origin_x,
        .top = client_screen.top + origin_y,
        .right = client_screen.right - right_chrome_px,
        .bottom = client_screen.bottom,
    };
}

/// A grid's cell rect on a surface whose cell (0,0) is `surface`'s top-left.
fn gridCellRect(surface: c.RECT, g: app_mod.GridInfo, cell_w: u32, cell_h: u32) c.RECT {
    const cw: c_int = @intCast(cell_w);
    const ch: c_int = @intCast(cell_h);
    return .{
        .left = surface.left + g.start_col * cw,
        .top = surface.top + g.start_row * ch,
        .right = surface.left + (g.start_col + g.cols) * cw,
        .bottom = surface.top + (g.start_row + g.rows) * ch,
    };
}

/// Screen rect a message box is placed against: the monitor work area
/// (.display), the window showing the cursor grid (.window), or the window
/// grid the cursor is in, walked out of floats (.grid). The one rule for the
/// ext-float create/update/reposition paths, the toast and the minis;
/// macOS's getExtFloatTargetFrame. Takes `app.mu` itself, so call it with the
/// lock NOT held, on the UI thread.
pub fn msgTargetRect(app: *App, mode: app_mod.config_mod.MsgPosition) c.RECT {
    const main_hwnd = app.hwnd orelse return app_mod.monitorWorkArea(null);
    if (mode == .display) return app_mod.monitorWorkArea(main_hwnd);

    // The live cursor grid: app.last_cursor_grid is updated only through
    // posted messages and can still name the previous grid (a closing
    // cmdline) when a message placed in the same flush is laid out.
    const cursor_grid: i64 = if (app.corep) |cp|
        app_mod.zonvie_core_get_cursor_position(cp, null, null)
    else
        app.last_cursor_grid;
    const grids: []const app_mod.GridInfo = if (mode == .grid)
        (if (app.corep) |cp| app.getVisibleGridsCached(cp) else &.{})
    else
        &.{};
    const anchor_grid = if (mode == .grid) cursorAnchorGridId(grids, cursor_grid) else cursor_grid;

    app.mu.lockUncancelable(core.clock.io());
    // Who draws the grid, not whether it is a window of its own: a float an
    // external window hosts has no entry in external_windows.
    const host_hwnd: ?c.HWND = if (callbacks.externalWindowShowingGridLocked(app, anchor_grid)) |shown| shown.win.hwnd else null;
    const origin = input.surfaceOriginPx(app, true);
    const right_chrome_px: c_int = if (app.ext_tabline_enabled and app.tabline_style == .sidebar and app.sidebar_position_right)
        app.scalePx(@as(c_int, @intCast(app.sidebar_width_px)))
    else
        0;
    const cell_w = app.cell_w_px;
    const cell_h = app.rowHeightPx();
    app.mu.unlock(core.clock.io());

    if (host_hwnd) |hwnd| {
        var rect: c.RECT = undefined;
        if (c.GetWindowRect(hwnd, &rect) != 0) return rect;
    }

    var client: c.RECT = undefined;
    if (c.GetClientRect(main_hwnd, &client) == 0) return app_mod.monitorWorkArea(main_hwnd);
    var pt: c.POINT = .{ .x = 0, .y = 0 };
    _ = c.ClientToScreen(main_hwnd, &pt);
    const surface = mainSurfaceRect(.{
        .left = pt.x,
        .top = pt.y,
        .right = pt.x + client.right,
        .bottom = pt.y + client.bottom,
    }, origin.x, origin.y, right_chrome_px);
    if (mode == .grid) {
        for (grids) |g| {
            if (g.grid_id == anchor_grid) return gridCellRect(surface, g, cell_w, cell_h);
        }
    }
    return surface;
}

/// Hand a prepared request to the UI thread and wake it. Caller must already
/// hold app.mu.
///
/// A failed enqueue aborts the core's flush: the core must not go on treating
/// the flush as delivered when the message never reached the UI thread. All
/// three message paths carried their own copy of that contract.
fn enqueuePendingMessage(app: *App, req: app_mod.PendingMessageRequest, what: []const u8) void {
    app.pending_messages.append(app.alloc, req) catch |e| {
        if (applog.isEnabled()) applog.appLog("[win] failed to queue {s}: {any}\n", .{ what, e });
        if (app.corep) |corep| core.zonvie_core_abort_flush(corep);
        return;
    };
    if (app.hwnd) |main_hwnd| {
        _ = c.PostMessageW(main_hwnd, app_mod.WM_APP_MSG_SHOW, 0, 0);
    }
}

/// Publish `text` to a mini message window and ask the main window to repaint
/// it. The .mini route and the fallback route for the views with no dedicated
/// display did this identically.
fn updateMiniWindow(app: *App, mini_id: app_mod.MiniWindowId, text: []const u8) void {
    const idx = @intFromEnum(mini_id);
    app.mu.lockUncancelable(core.clock.io());
    @memcpy(app.mini_windows[idx].text[0..text.len], text);
    app.mini_windows[idx].text_len = text.len;
    app.mu.unlock(core.clock.io());

    if (app.hwnd) |main_hwnd| {
        _ = c.PostMessageW(main_hwnd, app_mod.WM_APP_MINI_UPDATE, @as(c.WPARAM, idx), 0);
    }
}

/// Append one chunk's text to `buf` at `len`, clamped to what is left, and
/// return the new length. Once the buffer is full it copies nothing more.
fn appendChunkText(buf: []u8, len: usize, chunk: app_mod.MsgChunk) usize {
    if (chunk.text_len == 0) return len;
    const text = chunk.text[0..chunk.text_len];
    const copy_len = @min(text.len, buf.len - len);
    @memcpy(buf[len..][0..copy_len], text[0..copy_len]);
    return len + copy_len;
}

/// Decode UTF-8 into UTF-16 for the GDI text calls, tolerating a malformed or
/// mid-codepoint-truncated tail. The message buffers are filled by byte-count
/// clamped memcpy, so the tail can be a partial sequence; Utf8View.initUnchecked
/// traps on that. Undecodable bytes become U+FFFD. Returns the UTF-16 length.
fn utf8ToUtf16Lossy(dst: []u16, src: []const u8) usize {
    var out: usize = 0;
    var i: usize = 0;
    while (i < src.len and out < dst.len) {
        var cp: u21 = 0xFFFD;
        const cp_len = std.unicode.utf8ByteSequenceLength(src[i]) catch {
            i += 1;
            dst[out] = 0xFFFD;
            out += 1;
            continue;
        };
        if (i + cp_len > src.len) {
            dst[out] = 0xFFFD;
            out += 1;
            break;
        }
        cp = std.unicode.utf8Decode(src[i .. i + cp_len]) catch 0xFFFD;
        i += cp_len;
        if (cp > 0xFFFF) {
            if (out + 1 >= dst.len) break;
            dst[out] = @as(u16, @intCast((cp - 0x10000) >> 10)) + 0xD800;
            dst[out + 1] = @as(u16, @intCast((cp - 0x10000) & 0x3FF)) + 0xDC00;
            out += 2;
        } else {
            dst[out] = @intCast(cp);
            out += 1;
        }
    }
    return out;
}

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

    // Build the text straight into the request: an intermediate 2 KiB buffer
    // cut the core's 4 KiB confirm/history text (the choice line included).
    var req = app_mod.PendingMessageRequest{};
    const msg_text = &req.text;
    var msg_len: usize = 0;
    var primary_hl_id: u32 = 0;
    for (chunks[0..chunk_count]) |chunk| {
        if (primary_hl_id == 0) primary_hl_id = chunk.hl_id;
        msg_len = appendChunkText(msg_text, msg_len, chunk);
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
    app.mu.lockUncancelable(core.clock.io());
    defer app.mu.unlock(core.clock.io());

    req.text_len = msg_len;
    const kind_copy_len = @min(kind_len, req.kind.len);
    @memcpy(req.kind[0..kind_copy_len], kind[0..kind_copy_len]);
    req.kind_len = kind_copy_len;
    req.hl_id = primary_hl_id;
    req.replace_last = @intCast(@as(u32, if (replace_last != 0) 1 else 0));
    req.append = @intCast(@as(u32, if (append != 0) 1 else 0));
    req.view_type = view;
    req.timeout = timeout_sec;

    enqueuePendingMessage(app, req, "message");
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
        text_len = appendChunkText(&text_buf, text_len, chunk);
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
            updateMiniWindow(app, mini_id, text_buf[0..text_len]);
        },
        .ext_float => {
            // Queue message for ext_float display
            app.mu.lockUncancelable(core.clock.io());
            defer app.mu.unlock(core.clock.io());

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

            enqueuePendingMessage(app, req, "message");
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
            updateMiniWindow(app, mini_id, text_buf[0..text_len]);
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

/// number_prompt asks the user to pick a numbered choice, so it belongs with
/// the other blocking dialogs: centred over the app, height-clamped, no
/// auto-hide, and not joined with the toast stack.
pub fn isConfirmKind(kind: []const u8) bool {
    return std.mem.eql(u8, kind, "confirm") or
        std.mem.eql(u8, kind, "confirm_sub") or
        std.mem.eql(u8, kind, "number_prompt");
}

/// Whether the message window currently shows a blocking dialog, which a
/// toast update must not re-lay or auto-hide while Neovim waits for input.
pub fn messageWindowIsConfirm(app: *const App) bool {
    const mw = app.message_window orelse return false;
    return isConfirmKind(mw.kind[0..mw.kind_len]);
}

/// The kinds handleMsgMiniOrExtFloat queues for showmode/showcmd/ruler.
pub fn isStatusKind(kind: []const u8) bool {
    return std.mem.eql(u8, kind, "showmode") or
        std.mem.eql(u8, kind, "showcmd") or
        std.mem.eql(u8, kind, "ruler");
}

pub fn showMessageWindowOnUIThread(app: *App, msg: app_mod.DisplayMessage, include_msg: bool) void {
    if (applog.isEnabled()) applog.appLog("[win] showMessageWindowOnUIThread: text_len={d} kind={s}\n", .{ msg.text_len, msg.kind[0..msg.kind_len] });

    const kind_str = msg.kind[0..msg.kind_len];
    const is_confirm = isConfirmKind(kind_str);

    // Build combined content from display_messages stack. A confirm dialog
    // shows only its own text: the stack holds toasts (a config error, status).
    var combined_text: [16384]u8 = undefined;
    var combined_len: usize = 0;
    const stack: []const app_mod.DisplayMessage = if (is_confirm) &.{} else app.display_messages.items;
    for (stack) |dm| {
        if (combined_len > 0 and combined_len < combined_text.len - 1) {
            combined_text[combined_len] = '\n';
            combined_len += 1;
        }
        const copy_len = @min(dm.text_len, combined_text.len - combined_len);
        @memcpy(combined_text[combined_len..][0..copy_len], dm.text[0..copy_len]);
        combined_len += copy_len;
    }
    // Allocation failure while extending display_messages must not make the
    // current message disappear. The caller requests this fixed-buffer
    // fallback when the append failed (and for confirm and split messages,
    // which are not stored in the display stack at all).
    if (include_msg and combined_len < combined_text.len) {
        if (combined_len > 0 and combined_len < combined_text.len - 1) {
            combined_text[combined_len] = '\n';
            combined_len += 1;
        }
        const copy_len = @min(msg.text_len, combined_text.len - combined_len);
        @memcpy(combined_text[combined_len..][0..copy_len], msg.text[0..copy_len]);
        combined_len += copy_len;
    }

    // Count lines for display calculation
    var line_count: u32 = 1;
    for (combined_text[0..combined_len]) |ch| {
        if (ch == '\n') line_count += 1;
    }

    const is_prompt = is_confirm or std.mem.eql(u8, kind_str, "return_prompt");

    // External window with auto-hide
    const cell_h = app.rowHeightPx();
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
        // Regular messages: top-right of msg_pos.ext_float's target, as
        // msg_show and macOS's toast.
        const pos = external_windows.msgFloatOrigin(app, msgTargetRect(app, app.config.messages.msg_pos.ext_float), window_width, null);
        window_x = pos.x;
        window_y = pos.y;
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
    app.mu.lockUncancelable(core.clock.io());
    const ext_win = app.external_windows.get(grid_id) orelse {
        app.mu.unlock(core.clock.io());
        return;
    };

    // Skip if window is pending close or doesn't need resize
    if (ext_win.is_pending_close or !ext_win.needs_window_resize) {
        app.mu.unlock(core.clock.io());
        return;
    }

    const ext_hwnd = ext_win.hwnd;
    const window_w = ext_win.pending_window_w;
    const window_h = ext_win.pending_window_h;
    const is_cmdline = (grid_id == app_mod.CMDLINE_GRID_ID);
    ext_win.needs_window_resize = false;
    app.mu.unlock(core.clock.io());

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
                const work = app_mod.monitorWorkArea(app.hwnd);
                pos_x = work.left + @divTrunc(work.right - work.left - window_w, 2);
                pos_y = work.top + @divTrunc(work.bottom - work.top - window_h, 3);
            }
        } else {
            const work = app_mod.monitorWorkArea(app.hwnd);
            pos_x = work.left + @divTrunc(work.right - work.left - window_w, 2);
            pos_y = work.top + @divTrunc(work.bottom - work.top - window_h, 3);
        }
    } else {
        pos_x = current_rect.left;
        pos_y = current_rect.top;
    }

    if (applog.isEnabled()) applog.appLog("[win] resizeExternalWindowDeferred: grid_id={d} window=({d},{d}) at ({d},{d})\n", .{ grid_id, window_w, window_h, pos_x, pos_y });

    // Suppress the WM_SIZE -> nvim_ui_try_resize_grid feedback loop for this
    // programmatic resize. Set here, immediately before SetWindowPos and
    // after every early-return above, so a bail-out (e.g. GetWindowRect
    // failure) can never leave this flag stuck true. Cleared below once
    // SetWindowPos (and the synchronous WM_SIZE it triggers) has completed.
    // Without this, every programmatic resize (font/linespace change,
    // popupmenu auto-size) unconditionally sends a resize RPC, including for
    // synthetic grid_ids (cmdline/popupmenu/msg_show/msg_history) that don't
    // exist in nvim.
    app.mu.lockUncancelable(core.clock.io());
    if (app.external_windows.get(grid_id)) |ew| {
        ew.suppress_resize_callback = true;
    }
    app.mu.unlock(core.clock.io());

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
    app.mu.lockUncancelable(core.clock.io());
    if (app.external_windows.get(grid_id)) |ew| {
        ew.suppress_resize_callback = false;
    }
    // Clear saved cmdline position after programmatic resize (e.g. font change).
    // SetWindowPos triggers WM_WINDOWPOSCHANGED which re-saves the position,
    // but this stale position would prevent proper re-centering next time.
    if (is_cmdline) {
        app.cmdline_saved_x = null;
        app.cmdline_saved_y = null;
    }
    app.mu.unlock(core.clock.io());
}

/// Move the ext-float message windows (msg_show/msg_history and the toast)
/// after the main window moved or resized (TIMER_REPOSITION_FLOATS).
pub fn updateExtFloatPositions(app: *App) void {
    const target_rect = msgTargetRect(app, app.config.messages.msg_pos.ext_float);

    app.mu.lockUncancelable(core.clock.io());
    const msg_show_hwnd: ?c.HWND = if (app.external_windows.get(app_mod.MESSAGE_GRID_ID)) |e| e.hwnd else null;
    const msg_history_hwnd: ?c.HWND = if (app.external_windows.get(app_mod.MSG_HISTORY_GRID_ID)) |e| e.hwnd else null;
    app.mu.unlock(core.clock.io());

    // The toast is placed like msg_show; a confirm dialog is centred instead.
    if (app.message_window) |mw| {
        if (!isConfirmKind(mw.kind[0..mw.kind_len])) {
            if (windowSize(mw.hwnd)) |size| {
                const pos = external_windows.msgFloatOrigin(app, target_rect, size.w, null);
                _ = c.SetWindowPos(mw.hwnd, null, pos.x, pos.y, 0, 0, c.SWP_NOACTIVATE | c.SWP_NOZORDER | c.SWP_NOSIZE);
            }
        }
    }

    // msg_history first: msg_show stacks below it.
    var history_bottom: ?i32 = null;
    if (msg_history_hwnd) |hwnd| {
        const size = windowSize(hwnd) orelse return;
        const pos = external_windows.msgFloatOrigin(app, target_rect, size.w, null);
        history_bottom = pos.y + size.h;

        _ = c.SetWindowPos(hwnd, null, pos.x, pos.y, 0, 0, c.SWP_NOACTIVATE | c.SWP_NOZORDER | c.SWP_NOSIZE);
        if (applog.isEnabled()) applog.appLog("[win] updateExtFloatPositions: msg_history at ({d},{d})\n", .{ pos.x, pos.y });
    }

    if (msg_show_hwnd) |hwnd| {
        const size = windowSize(hwnd) orelse return;
        const pos = external_windows.msgFloatOrigin(app, target_rect, size.w, history_bottom);

        _ = c.SetWindowPos(hwnd, null, pos.x, pos.y, 0, 0, c.SWP_NOACTIVATE | c.SWP_NOZORDER | c.SWP_NOSIZE);
        if (applog.isEnabled()) applog.appLog("[win] updateExtFloatPositions: msg_show at ({d},{d})\n", .{ pos.x, pos.y });
    }
}

/// Outer size of a window. Only moves are done from here: the size is the
/// external-window sizing path's (externalSurfaceInsetsPx), which counts the
/// copy button this path used to leave out, shrinking the box on every move.
fn windowSize(hwnd: c.HWND) ?struct { w: c_int, h: c_int } {
    var rect: c.RECT = undefined;
    if (c.GetWindowRect(hwnd, &rect) == 0) return null;
    return .{ .w = rect.right - rect.left, .h = rect.bottom - rect.top };
}

/// Update or create mini windows (showmode / showcmd / ruler)
pub fn updateMiniWindows(app: *App) void {
    if (app.hwnd == null) return;

    // Get cell dimensions and config
    app.mu.lockUncancelable(core.clock.io());
    const cell_w = app.cell_w_px;
    const cell_h = app.rowHeightPx();
    const mini_pos_mode = app.config.messages.msg_pos.mini;
    app.mu.unlock(core.clock.io());

    // Mini-specific cell dimensions: ~75% of the editor cell so the popup
    // looks visibly "mini" (macOS sets its mini font size to cellHeightPt *
    // 0.6, an em size rather than a cell height). Floors keep the popup
    // legible at small DPI.
    const mini_cell_h_i: c_int = @max(@as(c_int, 12), @as(c_int, @intCast(@divTrunc(cell_h * 3, 4))));
    const mini_cell_w_i: c_int = @max(@as(c_int, 6), @as(c_int, @intCast(@divTrunc(cell_w * 3, 4))));

    // Minis stack upward from the target's bottom-right corner.
    const target = msgTargetRect(app, mini_pos_mode);
    const anchor_x: c_int = target.right;
    const anchor_y: c_int = target.bottom;

    // Count visible minis and build stack order
    var stacked_height_px: c_int = 0;
    for (0..app.mini_windows.len) |idx| {
        app.mu.lockUncancelable(core.clock.io());
        const text_len = app.mini_windows[idx].text_len;
        var text_buf: [256]u8 = undefined;
        if (text_len > 0) {
            @memcpy(text_buf[0..text_len], app.mini_windows[idx].text[0..text_len]);
        }
        app.mu.unlock(core.clock.io());

        if (text_len == 0) {
            // Hide this mini window
            if (app.mini_windows[idx].hwnd) |mini_hwnd| {
                _ = c.DestroyWindow(mini_hwnd);
                app.mini_windows[idx].hwnd = null;
            }
            continue;
        }

        if (applog.isEnabled()) applog.appLog("[win] updateMiniWindows: idx={d} text=\"{s}\"\n", .{ idx, text_buf[0..text_len] });

        // Compute line count and longest-line byte length so multi-line messages
        // are fully visible. UTF-8 '\n' (0x0A) is a single byte so byte-level counting works.
        var line_count: usize = 1;
        var max_line_bytes: usize = 0;
        var line_start: usize = 0;
        var i: usize = 0;
        while (i < text_len) : (i += 1) {
            if (text_buf[i] == '\n') {
                const len = i - line_start;
                if (len > max_line_bytes) max_line_bytes = len;
                line_count += 1;
                line_start = i + 1;
            }
        }
        if (text_len - line_start > max_line_bytes) max_line_bytes = text_len - line_start;

        // Width based on longest line, height grows with line count.
        // Use mini-cell metrics so the popup is visibly smaller than the
        // editor (and than ext_float windows that use full cell metrics).
        const max_line_i: c_int = @intCast(max_line_bytes);
        const text_width: c_int = max_line_i * mini_cell_w_i + app.scalePx(12);
        const window_width: c_int = @max(app.scalePx(40), text_width);
        const window_height: c_int = mini_cell_h_i * @as(c_int, @intCast(line_count));

        // Position: right edge of target area, stacking upward from bottom
        const window_x = anchor_x - window_width;
        const window_y = anchor_y - window_height - stacked_height_px;

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

        stacked_height_px += window_height;
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

    // Get colors from cached Normal highlight (avoids zonvie_core_get_hl_by_name
    // which locks grid_mu — calling it during WM_PAINT creates deadlock risk with
    // any core callback that blocks on the UI thread).
    var bg_rgb: c.COLORREF = c.RGB(38, 38, 46); // Default dark background
    var fg_rgb: c.COLORREF = c.RGB(220, 220, 220); // Default light gray text
    {
        app.mu.lockUncancelable(core.clock.io());
        const fg = app.colorscheme_fg;
        const bg = app.colorscheme_bg;
        app.mu.unlock(core.clock.io());

        // 0xFFFFFFFF is the only "unset" value: 0 is a black Normal colour.
        if (bg != 0xFFFFFFFF) {
            // Apply brightness adjustment
            var r = @as(u8, @intCast((bg >> 16) & 0xFF));
            var g = @as(u8, @intCast((bg >> 8) & 0xFF));
            var b = @as(u8, @intCast(bg & 0xFF));
            r = @min(255, @as(u16, r) * 13 / 10 + 12);
            g = @min(255, @as(u16, g) * 13 / 10 + 12);
            b = @min(255, @as(u16, b) * 13 / 10 + 12);
            bg_rgb = c.RGB(r, g, b);
        }
        if (fg != 0xFFFFFFFF) {
            const r = @as(u8, @intCast((fg >> 16) & 0xFF));
            const g = @as(u8, @intCast((fg >> 8) & 0xFF));
            const b = @as(u8, @intCast(fg & 0xFF));
            fg_rgb = c.RGB(r, g, b);
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
    const text_color = msg_win.getTextColor(fg_rgb);
    _ = c.SetTextColor(hdc, text_color);
    _ = c.SetBkMode(hdc, c.TRANSPARENT);

    // Convert text to UTF-16 using proper UTF-8 decoding
    var text_utf16: [4096]u16 = undefined;
    const text_utf16_len = utf8ToUtf16Lossy(&text_utf16, msg_win.text[0..msg_win.text_len]);

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
    app.mu.lockUncancelable(core.clock.io());
    var text_buf: [256]u8 = undefined;
    var text_len: usize = 0;
    inline for ([_]app_mod.MiniWindowId{ .showmode, .showcmd, .ruler, .custom }) |id| {
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
    app.mu.unlock(core.clock.io());

    // Get colors from cached Normal highlight (avoids zonvie_core_get_hl_by_name
    // which locks grid_mu — calling it during WM_PAINT creates deadlock risk).
    var bg_rgb: c.COLORREF = c.RGB(30, 30, 38);
    var fg_rgb: c.COLORREF = c.RGB(180, 180, 180);
    {
        app.mu.lockUncancelable(core.clock.io());
        const fg = app.colorscheme_fg;
        const bg = app.colorscheme_bg;
        app.mu.unlock(core.clock.io());

        if (bg != 0xFFFFFFFF) {
            // Darken background slightly for mini windows
            const r = @as(u8, @intCast((bg >> 16) & 0xFF)) / 2;
            const g = @as(u8, @intCast((bg >> 8) & 0xFF)) / 2;
            const b = @as(u8, @intCast(bg & 0xFF)) / 2;
            bg_rgb = c.RGB(r, g, b);
        }
        if (fg != 0xFFFFFFFF) {
            const r = @as(u8, @intCast((fg >> 16) & 0xFF));
            const g = @as(u8, @intCast((fg >> 8) & 0xFF));
            const b = @as(u8, @intCast(fg & 0xFF));
            fg_rgb = c.RGB(r, g, b);
        }
    }

    // Fill background
    const bg_brush = c.CreateSolidBrush(bg_rgb);
    _ = c.FillRect(hdc, &rect, bg_brush);
    _ = c.DeleteObject(bg_brush);

    // Create font at ~75% of the editor cell height so the mini popup is
    // visibly smaller than the editor and the ext_float window. Floor at 11 px
    // for legibility.
    const cell_h = app.cell_h_px;
    const font_height: c_int = @max(@as(c_int, 11), @as(c_int, @intCast(@divTrunc(cell_h * 3, 4))));
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
    // Decoded, not byte-zero-extended: showmode/showcmd/ruler carry non-ASCII
    // (e.g. "-- 挿入 --"), which zero-extension renders as mojibake.
    var text_utf16: [256]u16 = undefined;
    const text_utf16_len = utf8ToUtf16Lossy(&text_utf16, text_buf[0..text_len]);

    // Draw text centered
    const mini_pad = app.scalePx(4);
    var text_rect = c.RECT{
        .left = rect.left + mini_pad,
        .top = rect.top,
        .right = rect.right - mini_pad,
        .bottom = rect.bottom,
    };

    // Multi-line: omit DT_SINGLELINE so '\n' breaks lines; DT_VCENTER is unsupported
    // without DT_SINGLELINE, so use DT_TOP. Keep DT_CENTER for horizontal centering.
    _ = c.DrawTextW(hdc, @ptrCast(&text_utf16), @intCast(text_utf16_len), &text_rect, c.DT_CENTER | c.DT_TOP);

    if (applog.isEnabled()) applog.appLog("[win] paintMiniWindow done\n", .{});
}

fn testGrid(grid_id: i64, zindex: i64, anchor_grid: i64, start_row: i32, start_col: i32, rows: i32, cols: i32) app_mod.GridInfo {
    var g = std.mem.zeroes(app_mod.GridInfo);
    g.grid_id = grid_id;
    g.zindex = zindex;
    g.anchor_grid = anchor_grid;
    g.start_row = start_row;
    g.start_col = start_col;
    g.rows = rows;
    g.cols = cols;
    return g;
}

test "msg target: a .grid box hangs off the split the float is anchored to, in surface space" {
    const grids = [_]app_mod.GridInfo{
        testGrid(1, 0, 0, 0, 0, 40, 120),
        testGrid(2, 0, 0, 0, 0, 40, 60),
        testGrid(3, 0, 0, 0, 61, 40, 59),
        // A telescope prompt anchored to the right split.
        testGrid(9, 50, 3, 5, 70, 1, 30),
    };
    const anchor = cursorAnchorGridId(&grids, 9);
    try std.testing.expectEqual(@as(i64, 3), anchor);
    try std.testing.expectEqual(@as(i64, 1), cursorAnchorGridId(&grids, 77));

    // Left sidebar 200px, titlebar-free; client at screen (100, 50), 1400x900.
    const surface = mainSurfaceRect(.{ .left = 100, .top = 50, .right = 1500, .bottom = 950 }, 200, 0, 0);
    try std.testing.expectEqual(@as(c_int, 300), surface.left);
    const r = gridCellRect(surface, grids[2], 10, 20);
    try std.testing.expectEqual(@as(c_int, 300 + 61 * 10), r.left);
    try std.testing.expectEqual(@as(c_int, 300 + 120 * 10), r.right);
    try std.testing.expectEqual(@as(c_int, 50), r.top);
    try std.testing.expectEqual(@as(c_int, 50 + 40 * 20), r.bottom);
}

test "msg target: a right sidebar and a titlebar tabline are outside the surface" {
    const surface = mainSurfaceRect(.{ .left = 0, .top = 0, .right = 1000, .bottom = 800 }, 0, 32, 180);
    try std.testing.expectEqual(@as(c_int, 820), surface.right);
    try std.testing.expectEqual(@as(c_int, 32), surface.top);
    try std.testing.expectEqual(@as(c_int, 800), surface.bottom);
}

test "message kinds: interactive prompts are dialogs, status kinds are not" {
    try std.testing.expect(isConfirmKind("confirm"));
    try std.testing.expect(isConfirmKind("number_prompt"));
    try std.testing.expect(!isConfirmKind("emsg"));
    try std.testing.expect(isStatusKind("showcmd"));
    try std.testing.expect(!isStatusKind("echo"));
}
