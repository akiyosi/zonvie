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
const render_helpers = @import("../render_pipeline_helpers.zig");

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

/// The anchor's cell rect on a surface whose cell (0,0) is `surface`'s top-left.
fn anchorCellRect(surface: c.RECT, a: app_mod.MsgAnchor, cell_w: u32, cell_h: u32) c.RECT {
    const cw: c_int = @intCast(cell_w);
    const ch: c_int = @intCast(cell_h);
    return .{
        .left = surface.left + a.start_col * cw,
        .top = surface.top + a.start_row * ch,
        .right = surface.left + (a.start_col + a.cols) * cw,
        .bottom = surface.top + (a.start_row + a.rows) * ch,
    };
}

/// Screen rect a message box is placed against: the monitor work area
/// (.display), the window showing the cursor grid (.window), or the window
/// grid the cursor is in, walked out of floats (.grid). The one rule for the
/// ext-float create/update/reposition paths, the toast and the minis;
/// macOS's msgTargetFrame. The core answers which surface and cells
/// (zonvie_core_msg_anchor, from the flush that sent the message); this only
/// maps a surface to its window. Takes `app.mu` itself, so call it with the
/// lock NOT held, on the UI thread.
pub fn msgTargetRect(app: *App, mode: app_mod.config_mod.MsgPosition) c.RECT {
    const main_hwnd = app.hwnd orelse return app_mod.monitorWorkArea(null);
    if (mode == .display) return app_mod.monitorWorkArea(main_hwnd);

    var anchor: app_mod.MsgAnchor = undefined;
    const have_anchor = if (app.corep) |cp| app_mod.zonvie_core_msg_anchor(cp, &anchor) else false;
    const surface_id: i64 = if (!have_anchor) 1 else if (mode == .window) anchor.cursor_surface else anchor.anchor_surface;

    app.mu.lockUncancelable(core.clock.io());
    const host_hwnd: ?c.HWND = if (surface_id != 1) (if (app.external_windows.get(surface_id)) |w| w.hwnd else null) else null;
    const origin = input.surfaceOriginPx(app, true);
    const right_chrome_px: c_int = if (app.ext_tabline_enabled and app.tabline_style == .sidebar and app.sidebar_position_right)
        app.scalePx(@as(c_int, @intCast(app.sidebar_width_px)))
    else
        0;
    const cell_w = app.cell_w_px;
    const cell_h = app.rowHeightPx();
    app.mu.unlock(core.clock.io());

    // An external window's client area, as the main window's below and
    // macOS's contentLayoutRect: its outer rect holds the title bar and the
    // invisible resize borders.
    const surface: c.RECT = blk: {
        if (host_hwnd) |hwnd| {
            if (clientScreenRect(hwnd)) |rect| break :blk rect;
        }
        const client = clientScreenRect(main_hwnd) orelse return app_mod.monitorWorkArea(main_hwnd);
        break :blk mainSurfaceRect(client, origin.x, origin.y, right_chrome_px);
    };
    if (mode == .grid and have_anchor) return anchorCellRect(surface, anchor, cell_w, cell_h);
    return surface;
}

fn clientScreenRect(hwnd: c.HWND) ?c.RECT {
    var client: c.RECT = undefined;
    if (c.GetClientRect(hwnd, &client) == 0) return null;
    var pt: c.POINT = .{ .x = 0, .y = 0 };
    if (c.ClientToScreen(hwnd, &pt) == 0) return null;
    return .{ .left = pt.x, .top = pt.y, .right = pt.x + client.right, .bottom = pt.y + client.bottom };
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
    updateMiniText(app, mini_id, text);
    if (app.hwnd) |main_hwnd| {
        _ = c.PostMessageW(main_hwnd, app_mod.WM_APP_MINI_UPDATE, @as(c.WPARAM, @intFromEnum(mini_id)), 0);
    }
}

/// Append one chunk's text to `buf` at `len.*`, cut at a UTF-8 boundary to
/// what is left. False once a chunk did not fit: later chunks must not follow
/// the gap.
fn appendChunkText(buf: []u8, len: *usize, chunk: app_mod.MsgChunk) bool {
    if (chunk.text_len == 0) return true;
    const text = chunk.text[0..chunk.text_len];
    const copy_len = render_helpers.utf8TruncLen(text, buf.len - len.*);
    @memcpy(buf[len.*..][0..copy_len], text[0..copy_len]);
    len.* += copy_len;
    return copy_len == text.len;
}

/// Decode UTF-8 into UTF-16 for the GDI text calls, tolerating a malformed or
/// mid-codepoint-truncated tail; Utf8View.initUnchecked traps on that.
/// Undecodable bytes become U+FFFD. Returns the UTF-16 length.
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
        if (!appendChunkText(msg_text, &msg_len, chunk)) break;
    }

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
    req.timeout_ms = timeout_ms;

    enqueuePendingMessage(app, req, "message");
}

pub fn onMsgClear(ctx: ?*anyopaque) callconv(.c) void {
    const app: *App = @ptrCast(@alignCast(ctx.?));
    if (applog.isEnabled()) applog.appLog("[win] on_msg_clear\n", .{});

    // In the message queue, not a separate post: a WM_APP_MSG_SHOW already
    // queued drains the statuses the core resends after this clear, and a
    // clear handled after them wiped them.
    app.mu.lockUncancelable(core.clock.io());
    defer app.mu.unlock(core.clock.io());
    enqueuePendingMessage(app, .{ .clear = true }, "clear");
}

/// on_msg_clear on the UI thread: the toast, its stack and the ext_float
/// statuses (the core resends the ones it still holds).
pub fn clearMessagesOnUIThread(app: *App, hwnd: c.HWND) void {
    _ = c.KillTimer(hwnd, app_mod.TIMER_MSG_AUTOHIDE);
    app.status_messages = .{ null, null, null };
    hideMessageWindow(app);
}

pub fn onMsgShowmode(ctx: ?*anyopaque, view: app_mod.zonvie_msg_view_type, chunks: [*]const app_mod.MsgChunk, chunk_count: usize) callconv(.c) void {
    const app: *App = @ptrCast(@alignCast(ctx.?));
    handleMsgMiniOrExtFloat(app, view, .showmode, "showmode", chunks, chunk_count);
}

pub fn onMsgShowcmd(ctx: ?*anyopaque, view: app_mod.zonvie_msg_view_type, chunks: [*]const app_mod.MsgChunk, chunk_count: usize) callconv(.c) void {
    const app: *App = @ptrCast(@alignCast(ctx.?));
    handleMsgMiniOrExtFloat(app, view, .showcmd, "showcmd", chunks, chunk_count);
}

pub fn onMsgRuler(ctx: ?*anyopaque, view: app_mod.zonvie_msg_view_type, chunks: [*]const app_mod.MsgChunk, chunk_count: usize) callconv(.c) void {
    const app: *App = @ptrCast(@alignCast(ctx.?));
    handleMsgMiniOrExtFloat(app, view, .ruler, "ruler", chunks, chunk_count);
}

/// Common handler for showmode/showcmd/ruler that can route to mini or ext_float
pub fn handleMsgMiniOrExtFloat(
    app: *App,
    view: app_mod.zonvie_msg_view_type,
    mini_id: app_mod.MiniWindowId,
    kind_str: []const u8,
    chunks: [*]const app_mod.MsgChunk,
    chunk_count: usize,
) void {
    // Build text from chunks
    var text_buf: [256]u8 = undefined;
    var text_len: usize = 0;
    for (chunks[0..chunk_count]) |chunk| {
        if (!appendChunkText(&text_buf, &text_len, chunk)) break;
    }

    if (applog.isEnabled()) applog.appLog("[win] on_msg_{s}: chunks={d} text=\"{s}\" view={d}\n", .{ kind_str, chunk_count, text_buf[0..text_len], @intFromEnum(view) });

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
        // Queued: the toast and the tray balloon belong to the UI thread.
        .ext_float, .notification => {
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
            // No timeout: the status arm keeps the text until it is emptied.
            req.view_type = view;
            req.status = mini_id;

            enqueuePendingMessage(app, req, "message");
        },
        else => {
            // Fallback to mini for other views (confirm, split)
            updateMiniWindow(app, mini_id, text_buf[0..text_len]);
        },
    }
}

/// Update mini window text directly (for UI thread usage), bounded as macOS
/// bounds it. Under app.mu: the core thread writes the same buffer in
/// updateMiniWindow.
pub fn updateMiniText(app: *App, id: app_mod.MiniWindowId, text: []const u8) void {
    const idx = @intFromEnum(id);
    app.mu.lockUncancelable(core.clock.io());
    defer app.mu.unlock(core.clock.io());
    app.mini_windows[idx].text_len = render_helpers.clampMiniContent(&app.mini_windows[idx].text, text);
}

/// The kinds Neovim blocks on (confirm, confirm_sub, number_prompt): centred
/// over the app, height-clamped, no auto-hide, not joined with the toast
/// stack. The core's list, which its router pins to the confirm view.
pub const isConfirmKind = core.config.isInteractivePrompt;

/// Whether the message window currently shows a blocking dialog, which a
/// toast update must not re-lay or auto-hide while Neovim waits for input.
pub fn messageWindowIsConfirm(app: *const App) bool {
    const mw = app.message_window orelse return false;
    return isConfirmKind(mw.kind[0..mw.kind_len]);
}

/// Bytes the message window keeps; one UTF-16 unit per byte decodes all of it.
const message_text_capacity = @typeInfo(@FieldType(app_mod.MessageWindow, "text")).array.len;
const mini_text_capacity = @typeInfo(@FieldType(app_mod.MiniWindowState, "text")).array.len;
/// Inset of the message window's text from each edge, before DPI scaling.
const message_text_pad_px: c_int = 12;

fn fillMessageWindow(mw: *app_mod.MessageWindow, text: []const u8, msg: app_mod.DisplayMessage, line_count: u32, is_long_mode: bool) void {
    const copy_len = @min(text.len, mw.text.len);
    @memcpy(mw.text[0..copy_len], text[0..copy_len]);
    mw.text_len = copy_len;
    @memcpy(mw.kind[0..msg.kind_len], msg.kind[0..msg.kind_len]);
    mw.kind_len = msg.kind_len;
    mw.hl_id = msg.hl_id;
    mw.line_count = line_count;
    mw.is_long_mode = is_long_mode;
}

/// The GDI font the message window and the minis draw in.
fn createPanelFont(height_px: c_int) c.HFONT {
    return c.CreateFontW(
        height_px,
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
}

/// ~75% of the editor cell height, so the mini reads as smaller than the
/// editor and the ext_float window; floored for legibility.
fn miniFontPx(app: *const App) c_int {
    return @max(@as(c_int, 11), @as(c_int, @intCast(@divTrunc(app.cell_h_px * 3, 4))));
}
/// Inset of a mini's text from its left and right edges, before DPI scaling.
const mini_text_pad_px: c_int = 4;
/// '\n' breaks lines (no DT_SINGLELINE), so DT_TOP: DT_VCENTER needs SINGLELINE.
const mini_draw_flags: c.UINT = c.DT_CENTER | c.DT_TOP;

fn colorrefFromRgb(rgb: u32) c.COLORREF {
    return c.RGB(@as(u8, @truncate(rgb >> 16)), @as(u8, @truncate(rgb >> 8)), @as(u8, @truncate(rgb)));
}

fn colorrefFromFloat(rgb: [3]f32) c.COLORREF {
    return c.RGB(
        @as(u8, @intFromFloat(@round(std.math.clamp(rgb[0], 0.0, 1.0) * 255.0))),
        @as(u8, @intFromFloat(@round(std.math.clamp(rgb[1], 0.0, 1.0) * 255.0))),
        @as(u8, @intFromFloat(@round(std.math.clamp(rgb[2], 0.0, 1.0) * 255.0))),
    );
}

/// The message window's bg from the Normal bg: the cmdline's brightness rule,
/// as the decorated surfaces and macOS's toast (lighter on dark schemes,
/// darker on light ones).
fn messageWindowBg(normal_bg: u32) c.COLORREF {
    return colorrefFromFloat(app_mod.adjustBrightnessForCmdline(
        @as(f32, @floatFromInt((normal_bg >> 16) & 0xFF)) / 255.0,
        @as(f32, @floatFromInt((normal_bg >> 8) & 0xFF)) / 255.0,
        @as(f32, @floatFromInt(normal_bg & 0xFF)) / 255.0,
    ));
}

const TextSizePx = struct { w: c_int, h: c_int };

/// What DrawTextW with `flags` would cover for `text` in the panel font at
/// `font_px`, `width_px` wide. Boxes are sized with the font they are painted
/// in, not with editor cell metrics.
fn measureTextPx(hwnd: c.HWND, font_px: c_int, text: []const u16, width_px: c_int, flags: c.UINT) ?TextSizePx {
    if (text.len == 0) return null;
    const hdc = c.GetDC(hwnd) orelse return null;
    defer _ = c.ReleaseDC(hwnd, hdc);
    const hfont = createPanelFont(font_px);
    const old_font = c.SelectObject(hdc, hfont);
    defer {
        _ = c.SelectObject(hdc, old_font);
        _ = c.DeleteObject(hfont);
    }
    var rect: c.RECT = .{ .left = 0, .top = 0, .right = width_px, .bottom = 0 };
    if (c.DrawTextW(hdc, @ptrCast(text.ptr), @intCast(text.len), &rect, flags | c.DT_CALCRECT) == 0) return null;
    return .{ .w = rect.right - rect.left, .h = rect.bottom - rect.top };
}

/// Measure and paint of a wrapped toast. DT_EDITCONTROL breaks a word wider
/// than the line (a path, a URL) instead of letting it run off the edge.
const wrapped_draw_flags: c.UINT = c.DT_LEFT | c.DT_TOP | c.DT_WORDBREAK | c.DT_EDITCONTROL;

fn wrappedTextHeightPx(hwnd: c.HWND, font_px: c_int, text: []const u8, width_px: c_int) ?c_int {
    var utf16: [message_text_capacity]u16 = undefined;
    const len = utf8ToUtf16Lossy(&utf16, text);
    const size = measureTextPx(hwnd, font_px, utf16[0..len], width_px, wrapped_draw_flags) orelse return null;
    return size.h;
}

/// Append `line` to the toast text at `len`, after a '\n' when it is not the
/// first, cut at a UTF-8 boundary to what is left. False once the line did not
/// fit: later lines must not follow the gap.
fn appendToastLine(buf: []u8, len: *usize, line: []const u8) bool {
    if (len.* > 0) {
        if (len.* == buf.len) return false;
        buf[len.*] = '\n';
        len.* += 1;
    }
    const copy_len = render_helpers.utf8TruncLen(line, buf.len - len.*);
    @memcpy(buf[len.*..][0..copy_len], line[0..copy_len]);
    len.* += copy_len;
    return copy_len == line.len;
}

/// Re-show the toast from the stack and the statuses, or hide it when both
/// are empty. Statuses never enter or clear the stack. A blocking dialog
/// stays.
pub fn refreshToast(app: *App) void {
    if (messageWindowIsConfirm(app)) return;
    // The window takes its kind (colour) from the last stacked message, else
    // from the last status.
    var shown: ?*const app_mod.DisplayMessage = null;
    for (&app.status_messages) |*entry| {
        if (entry.*) |*m| shown = m;
    }
    const stack = app.display_messages.items;
    if (stack.len > 0) shown = &stack[stack.len - 1];
    if (shown) |m| showMessageWindowOnUIThread(app, m.*, false) else hideMessageWindow(app);
}

pub fn showMessageWindowOnUIThread(app: *App, msg: app_mod.DisplayMessage, include_msg: bool) void {
    if (applog.isEnabled()) applog.appLog("[win] showMessageWindowOnUIThread: text_len={d} kind={s}\n", .{ msg.text_len, msg.kind[0..msg.kind_len] });

    const kind_str = msg.kind[0..msg.kind_len];
    const is_confirm = isConfirmKind(kind_str);

    // The toast is the stack's lines followed by the non-empty status lines,
    // macOS's rule. A confirm dialog shows only its own text.
    // Sized to what the window stores, so the line count covers only that.
    var combined_text: [message_text_capacity]u8 = undefined;
    var combined_len: usize = 0;
    var fits = true;
    const stack: []const app_mod.DisplayMessage = if (is_confirm) &.{} else app.display_messages.items;
    for (stack) |*dm| fits = fits and appendToastLine(&combined_text, &combined_len, dm.text[0..dm.text_len]);
    // Allocation failure while extending display_messages must not make the
    // current message disappear. The caller requests this fixed-buffer
    // fallback when the append failed (and for confirm messages, which are
    // not stored in the display stack at all).
    if (include_msg) fits = fits and appendToastLine(&combined_text, &combined_len, msg.text[0..msg.text_len]);
    if (!is_confirm) {
        for (&app.status_messages) |*entry| {
            if (entry.*) |*m| fits = fits and appendToastLine(&combined_text, &combined_len, m.text[0..m.text_len]);
        }
    }

    // Count lines for display calculation
    var line_count: u32 = 1;
    for (combined_text[0..combined_len]) |ch| {
        if (ch == '\n') line_count += 1;
    }

    // Word-wrapped: a dialog, several lines, or a line wider than the cap.
    var is_long_mode = is_confirm or line_count > 1;

    // External window with auto-hide
    const cell_h = app.rowHeightPx();
    const padding: c_int = app.scalePx(16);

    // Get app window position and size (position relative to app window, not screen)
    var app_rect: c.RECT = undefined;
    const main_hwnd = app.hwnd orelse return;
    _ = c.GetWindowRect(main_hwnd, &app_rect);
    const app_width = app_rect.right - app_rect.left;
    const app_height = app_rect.bottom - app_rect.top;
    const target: c.RECT = if (is_confirm) app_rect else msgTargetRect(app, app.config.messages.msg_pos.ext_float);

    // Calculate window size based on message type
    var window_width: c_int = undefined;
    var window_height: c_int = undefined;
    const line_height: c_int = @as(c_int, @intCast(cell_h)) + app.scalePx(4);
    const text_pad = app.scalePx(message_text_pad_px);
    const stored = combined_text[0..combined_len];

    if (is_confirm) {
        // For confirm dialogs (like E325), use larger fixed width and calculate height
        // based on line count. The text will be word-wrapped.
        window_width = @max(app.scalePx(100), @min(app.scalePx(800), app_width - app.scalePx(40)));
        // Height: line_count * line_height + padding, but at least 200px for readability
        var calc_height: c_int = @intCast(@as(u32, @intCast(line_height)) * line_count + @as(u32, @intCast(padding * 2)));
        // The paint word-wraps, so long E325 lines take several rows: measured
        // as the paint draws them, or the choice line falls off the bottom.
        if (wrappedTextHeightPx(main_hwnd, @intCast(app.cell_h_px), stored, window_width - 2 * text_pad)) |text_h| {
            calc_height = @max(calc_height, text_h + 2 * text_pad);
        }
        window_height = @max(app.scalePx(200), @min(calc_height, app_height - app.scalePx(100)));
        if (applog.isEnabled()) applog.appLog("[win] confirm dialog: line_count={d} calc_height={d} window_height={d}\n", .{ line_count, calc_height, window_height });
    } else {
        // The widest line in the paint font, capped at min(80% of the
        // target, 600px) as macOS's toast.
        var utf16: [message_text_capacity]u16 = undefined;
        const utf16_len = utf8ToUtf16Lossy(&utf16, stored);
        const text_w: c_int = if (measureTextPx(main_hwnd, @intCast(app.cell_h_px), utf16[0..utf16_len], 0, c.DT_LEFT | c.DT_TOP)) |size| size.w else 0;
        const natural_width = text_w + 2 * padding;
        const max_width = @min(@divTrunc((target.right - target.left) * 4, 5), app.scalePx(600));
        window_width = @max(app.scalePx(100), @min(natural_width, max_width));
        window_height = @intCast(@as(u32, @intCast(line_height)) * line_count + @as(u32, @intCast(padding * 2)));
        // Text wider than the cap wraps, and the box grows to hold it: measured
        // in the paint font, as macOS measures its toast. A single line was
        // drawn DT_SINGLELINE and cut at the right edge.
        // Several lines are measured too: line_height follows linespace, the
        // paint font does not, so a negative linespace undercounts them.
        if (natural_width > window_width) is_long_mode = true;
        if (is_long_mode or line_count > 1) {
            if (wrappedTextHeightPx(main_hwnd, @intCast(app.cell_h_px), stored, window_width - 2 * text_pad)) |text_h| {
                window_height = @max(window_height, text_h + 2 * text_pad);
            }
        }
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
    } else {
        // Regular messages: top-right of msg_pos.ext_float's target, as
        // msg_show and macOS's toast.
        const pos = external_windows.msgFloatOrigin(app, target, window_width, null);
        window_x = pos.x;
        window_y = pos.y;
    }

    if (app.message_window) |*msg_win| {
        // Update existing window. Written under app.mu: onFlushEnd reads
        // message_window on the core thread.
        app.mu.lockUncancelable(core.clock.io());
        fillMessageWindow(msg_win, combined_text[0..combined_len], msg, line_count, is_long_mode);
        app.mu.unlock(core.clock.io());

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
    var msg_win = app_mod.MessageWindow{ .hwnd = msg_hwnd.? };
    fillMessageWindow(&msg_win, combined_text[0..combined_len], msg, line_count, is_long_mode);
    app.mu.lockUncancelable(core.clock.io());
    app.message_window = msg_win;
    app.mu.unlock(core.clock.io());

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
    if (app.message_window) |msg_win| {
        if (applog.isEnabled()) applog.appLog("[win] hiding message window\n", .{});
        // Unpublished before it is destroyed: onFlushEnd invalidates it from
        // the core thread under app.mu.
        app.mu.lockUncancelable(core.clock.io());
        app.message_window = null;
        app.mu.unlock(core.clock.io());
        var closing = msg_win;
        closing.deinit();
    }
    // Clear display messages stack
    app.display_messages.clearRetainingCapacity();
}

/// Resize external window asynchronously.
/// Called via WM_APP_RESIZE_POPUPMENU to avoid deadlock with WM_SIZE handler.
/// The cmdline re-centres on its monitor, the message floats keep their
/// top-right anchor, everything else keeps its top-left.
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
        const pos = external_windows.centredOnWorkArea(app_mod.monitorWorkArea(ext_hwnd), window_w, window_h, 3);
        pos_x = pos.x;
        pos_y = pos.y;
    } else if (grid_id == app_mod.MESSAGE_GRID_ID or grid_id == app_mod.MSG_HISTORY_GRID_ID) {
        // The message floats keep their top-right anchor, as on every other
        // re-layout; the top-left one grew them past the right margin.
        const pos = external_windows.msgFloatTopRight(app, grid_id == app_mod.MSG_HISTORY_GRID_ID, window_w);
        pos_x = pos.x;
        pos_y = pos.y;
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

    // The two message floats resize in hash-map order; msg_show may have been
    // placed against msg_history's old bottom.
    if (grid_id == app_mod.MSG_HISTORY_GRID_ID) external_windows.restackMsgShowBelowHistory(app);
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
    const main_hwnd = app.hwnd orelse return;

    app.mu.lockUncancelable(core.clock.io());
    const mini_pos_mode = app.config.messages.msg_pos.mini;
    const font_px = miniFontPx(app);
    app.mu.unlock(core.clock.io());

    // Minis stack upward from the target's bottom-right corner, no wider than
    // the main window (macOS's miniWindowSize).
    const target = msgTargetRect(app, mini_pos_mode);
    var main_rect: c.RECT = undefined;
    const max_width_px: c_int = if (c.GetWindowRect(main_hwnd, &main_rect) != 0) main_rect.right - main_rect.left else std.math.maxInt(c_int);
    const anchor_x: c_int = target.right;
    const anchor_y: c_int = target.bottom;

    // Count visible minis and build stack order
    var stacked_height_px: c_int = 0;
    for (0..app.mini_windows.len) |idx| {
        app.mu.lockUncancelable(core.clock.io());
        const text_len = app.mini_windows[idx].text_len;
        var text_buf: [mini_text_capacity]u8 = undefined;
        if (text_len > 0) {
            @memcpy(text_buf[0..text_len], app.mini_windows[idx].text[0..text_len]);
        }
        app.mu.unlock(core.clock.io());

        if (text_len == 0) {
            // Hide this mini window. Unpublished under app.mu first: onFlushEnd
            // invalidates the minis from the core thread.
            if (app.mini_windows[idx].hwnd) |mini_hwnd| {
                app.mu.lockUncancelable(core.clock.io());
                app.mini_windows[idx].hwnd = null;
                app.mu.unlock(core.clock.io());
                _ = c.DestroyWindow(mini_hwnd);
            }
            continue;
        }

        if (applog.isEnabled()) applog.appLog("[win] updateMiniWindows: idx={d} text=\"{s}\"\n", .{ idx, text_buf[0..text_len] });

        // Sized from the text in the font paintMiniWindow draws it in; editor
        // cell metrics clipped it under a negative linespace or a font
        // narrower than Consolas. Lines break at '\n' only.
        var text_utf16: [mini_text_capacity]u16 = undefined;
        const text_utf16_len = utf8ToUtf16Lossy(&text_utf16, text_buf[0..text_len]);
        const text_size = measureTextPx(main_hwnd, font_px, text_utf16[0..text_utf16_len], 0, mini_draw_flags) orelse
            TextSizePx{ .w = 0, .h = font_px };
        const window_width: c_int = @min(max_width_px, @max(app.scalePx(40), text_size.w + 2 * app.scalePx(mini_text_pad_px)));
        const window_height: c_int = text_size.h;

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

            app.mu.lockUncancelable(core.clock.io());
            app.mini_windows[idx].hwnd = mini_hwnd;
            app.mu.unlock(core.clock.io());
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
        if (bg != 0xFFFFFFFF) bg_rgb = messageWindowBg(bg);
        if (fg != 0xFFFFFFFF) fg_rgb = colorrefFromRgb(fg);
    }

    // Fill background
    const bg_brush = c.CreateSolidBrush(bg_rgb);
    _ = c.FillRect(hdc, &rect, bg_brush);
    _ = c.DeleteObject(bg_brush);

    const hfont = createPanelFont(@intCast(app.cell_h_px));
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
    var text_utf16: [message_text_capacity]u16 = undefined;
    const text_utf16_len = utf8ToUtf16Lossy(&text_utf16, msg_win.text[0..msg_win.text_len]);

    // Draw text with padding
    const padding: c_int = app.scalePx(message_text_pad_px);
    var text_rect = c.RECT{
        .left = rect.left + padding,
        .top = rect.top + padding,
        .right = rect.right - padding,
        .bottom = rect.bottom - padding,
    };

    // Use different draw flags based on long mode
    const draw_flags: c.UINT = if (msg_win.is_long_mode)
        wrapped_draw_flags
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
    var text_buf: [mini_text_capacity]u8 = undefined;
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

        // The Normal pair itself, as macOS's mini: halving the bg left the
        // Normal fg unreadable on light schemes.
        if (bg != 0xFFFFFFFF) bg_rgb = colorrefFromRgb(bg);
        if (fg != 0xFFFFFFFF) fg_rgb = colorrefFromRgb(fg);
    }

    // Fill background
    const bg_brush = c.CreateSolidBrush(bg_rgb);
    _ = c.FillRect(hdc, &rect, bg_brush);
    _ = c.DeleteObject(bg_brush);

    const hfont = createPanelFont(miniFontPx(app));
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
    var text_utf16: [mini_text_capacity]u16 = undefined;
    const text_utf16_len = utf8ToUtf16Lossy(&text_utf16, text_buf[0..text_len]);

    // Draw text centered
    const mini_pad = app.scalePx(mini_text_pad_px);
    var text_rect = c.RECT{
        .left = rect.left + mini_pad,
        .top = rect.top,
        .right = rect.right - mini_pad,
        .bottom = rect.bottom,
    };

    _ = c.DrawTextW(hdc, @ptrCast(&text_utf16), @intCast(text_utf16_len), &text_rect, mini_draw_flags);

    if (applog.isEnabled()) applog.appLog("[win] paintMiniWindow done\n", .{});
}

test "msg target: a .grid box covers the anchor's cells in surface space" {
    // The core's anchor for a telescope prompt anchored to the right split.
    const anchor: app_mod.MsgAnchor = .{
        .cursor_surface = 1,
        .anchor_surface = 1,
        .anchor_grid = 3,
        .start_row = 0,
        .start_col = 61,
        .rows = 40,
        .cols = 59,
    };

    // Left sidebar 200px, titlebar-free; client at screen (100, 50), 1400x900.
    const surface = mainSurfaceRect(.{ .left = 100, .top = 50, .right = 1500, .bottom = 950 }, 200, 0, 0);
    try std.testing.expectEqual(@as(c_int, 300), surface.left);
    const r = anchorCellRect(surface, anchor, 10, 20);
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
    try std.testing.expect(isConfirmKind("confirm_sub"));
    try std.testing.expect(!isConfirmKind("return_prompt"));
}

test "message window bg: darker than a light Normal bg, lighter than a dark one" {
    // #fdf6e3 turned pure white under the old *1.3+12 rule.
    const light = messageWindowBg(0xfdf6e3);
    try std.testing.expect(light != c.RGB(255, 255, 255));
    // COLORREF is 0x00BBGGRR.
    try std.testing.expect((light & 0xFF) < 0xfd);
    const dark = messageWindowBg(0x1e1e2e);
    try std.testing.expect(((dark >> 16) & 0xFF) > 0x2e);
    // The mini paints the Normal pair itself.
    try std.testing.expectEqual(c.RGB(0xfa, 0xfa, 0xfa), colorrefFromRgb(0xfafafa));
}

test "cmdline width: clamped to the work area it is given, other surfaces untouched" {
    const laptop: c.RECT = .{ .left = 2560, .top = 0, .right = 2560 + 1366, .bottom = 768 };
    // CMDLINE_SCREEN_MARGIN at 200% DPI.
    const margin: c_int = 80;
    try std.testing.expectEqual(1366 - margin, external_windows.clampCmdlineWidthToWorkArea(app_mod.CMDLINE_GRID_ID, 3000, laptop, margin));
    try std.testing.expectEqual(@as(c_int, 400), external_windows.clampCmdlineWidthToWorkArea(app_mod.CMDLINE_GRID_ID, 400, laptop, margin));
    try std.testing.expectEqual(@as(c_int, 3000), external_windows.clampCmdlineWidthToWorkArea(app_mod.MESSAGE_GRID_ID, 3000, laptop, margin));
}
