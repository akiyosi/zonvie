const std = @import("std");
const app_mod = @import("../app.zig");
const App = app_mod.App;
const c = app_mod.c;
const applog = app_mod.applog;
const d3d11 = app_mod.d3d11;
const dwrite_d2d = app_mod.dwrite_d2d;
const core = @import("zonvie_core");
const window_mod = @import("../window.zig");
const TablineState = app_mod.TablineState;
const TabEntry = app_mod.TabEntry;

// ---- Shared helpers for titlebar and sidebar tab operations ----

/// Extract the display name (basename) from a tab entry.
/// Returns the length of the display name written to out_buf.
fn extractTabDisplayName(tab: *const TabEntry, out_buf: *[256]u8) usize {
    if (tab.name_len > 0) {
        const display = app_mod.baseName(tab.name[0..tab.name_len]);
        @memcpy(out_buf[0..display.len], display);
        return display.len;
    } else {
        const no_name = "[No Name]";
        @memcpy(out_buf[0..no_name.len], no_name);
        return no_name.len;
    }
}

// AI-agent spinner glyphs (single glyph, no trailing space; drawn centered in a
// fixed-width indicator cell). Claude's official thinking sequence is
// · ✢ ✳ ✶ ✻ ✽ (120ms/frame); Codex and generic agents animate the standard
// Braille spinner. All monochrome (GDI-rendered).
const agent_claude_frames = [_][]const u8{ "·", "✢", "✳", "✶", "✻", "✽" };
const agent_braille_frames = [_][]const u8{ "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" };

/// Working spinner glyph for a tab state+frame ("" for non-working states).
fn agentSpinnerGlyph(state: u8, frame: u32) []const u8 {
    return switch (state) {
        2 => agent_claude_frames[frame % agent_claude_frames.len],
        3 => agent_braille_frames[frame % agent_braille_frames.len],
        else => "",
    };
}

/// Draw a single monochrome indicator glyph centered in a fixed-width cell
/// [x, x+cell_w) so the title (drawn after the cell) never shifts per frame.
fn drawIndicatorGlyph(hdc: c.HDC, glyph: []const u8, x: c_int, cell_w: c_int, top: c_int, bottom: c_int) void {
    var wide: [8]u16 = undefined;
    const n = std.unicode.utf8ToUtf16Le(&wide, glyph) catch return;
    var r = c.RECT{ .left = x, .top = top, .right = x + cell_w, .bottom = bottom };
    _ = c.DrawTextW(hdc, &wide, @intCast(n), &r, c.DT_CENTER | c.DT_VCENTER | c.DT_SINGLELINE | c.DT_NOCLIP);
}

/// Pause glyph (waiting-for-input): two vertical bars in the text color, drawn
/// as filled rects so it stays crisp without depending on an emoji font.
fn drawPauseGlyph(hdc: c.HDC, x: c_int, cell_w: c_int, top: c_int, bottom: c_int) void {
    // Size off cell_w (= ind_px, the robot emoji's footprint), not the full text
    // rect height, so the pause icon matches the robot's scale rather than dwarfing it.
    const bar_h = @divTrunc(cell_w * 8, 10);
    const h = bottom - top;
    const by = top + @divTrunc(h - bar_h, 2);
    const bar_w = @max(@as(c_int, 2), @divTrunc(cell_w, 6));
    const gap = @max(@as(c_int, 2), @divTrunc(cell_w, 6));
    const total = bar_w * 2 + gap;
    const bx = x + @divTrunc(cell_w - total, 2);
    const brush = c.CreateSolidBrush(c.GetTextColor(hdc));
    defer _ = c.DeleteObject(brush);
    var r1 = c.RECT{ .left = bx, .top = by, .right = bx + bar_w, .bottom = by + bar_h };
    _ = c.FillRect(hdc, &r1, brush);
    var r2 = c.RECT{ .left = bx + bar_w + gap, .top = by, .right = bx + bar_w + gap + bar_w, .bottom = by + bar_h };
    _ = c.FillRect(hdc, &r2, brush);
}

// 🤖 (U+1F916 ROBOT FACE) as a UTF-16 surrogate pair, for the idle indicator.
const agent_emoji_utf16 = [_]c.WCHAR{ 0xD83E, 0xDD16 };

/// Rasterize 🤖 in color into a px×px premultiplied-BGRA DIBSection via D2D and
/// return the HBITMAP (caller owns it; freed by ensureAgentEmoji on resize /
/// App deinit). GDI DrawTextW cannot render color emoji, so we reuse the
/// renderer's proven CreateDCRenderTarget + DrawTextW(ENABLE_COLOR_FONT) path.
/// Premultiplied alpha matches AlphaBlend(AC_SRC_ALPHA).
fn rasterizeAgentEmoji(d2d_factory: *c.ID2D1Factory, dwrite_factory: *c.IDWriteFactory, px: i32) ?c.HBITMAP {
    if (px <= 0) return null;

    const hdc = c.CreateCompatibleDC(null);
    if (hdc == null) return null;
    defer _ = c.DeleteDC(hdc);

    var bmi: c.BITMAPINFO = std.mem.zeroes(c.BITMAPINFO);
    bmi.bmiHeader.biSize = @sizeOf(c.BITMAPINFOHEADER);
    bmi.bmiHeader.biWidth = px;
    bmi.bmiHeader.biHeight = -px; // top-down
    bmi.bmiHeader.biPlanes = 1;
    bmi.bmiHeader.biBitCount = 32;
    bmi.bmiHeader.biCompression = c.BI_RGB;

    var bits: ?*anyopaque = null;
    const hbm = c.CreateDIBSection(hdc, &bmi, c.DIB_RGB_COLORS, &bits, null, 0);
    if (hbm == null or bits == null) return null;
    const old_hbm = c.SelectObject(hdc, hbm);

    const ok = blk: {
        const rtp = c.D2D1_RENDER_TARGET_PROPERTIES{
            .type = c.D2D1_RENDER_TARGET_TYPE_DEFAULT,
            .pixelFormat = .{ .format = c.DXGI_FORMAT_B8G8R8A8_UNORM, .alphaMode = c.D2D1_ALPHA_MODE_PREMULTIPLIED },
            .dpiX = 0,
            .dpiY = 0,
            .usage = c.D2D1_RENDER_TARGET_USAGE_NONE,
            .minLevel = c.D2D1_FEATURE_LEVEL_DEFAULT,
        };
        var dc_rt: ?*c.ID2D1DCRenderTarget = null;
        const create_fn = d2d_factory.lpVtbl.*.CreateDCRenderTarget orelse break :blk false;
        if (create_fn(d2d_factory, &rtp, &dc_rt) != 0 or dc_rt == null) break :blk false;
        defer {
            const u: *c.IUnknown = @ptrCast(dc_rt.?);
            _ = u.lpVtbl.*.Release.?(u);
        }

        var bind_rect: c.RECT = .{ .left = 0, .top = 0, .right = px, .bottom = px };
        const bind_fn = dc_rt.?.lpVtbl.*.BindDC orelse break :blk false;
        if (bind_fn(dc_rt.?, hdc, &bind_rect) != 0) break :blk false;

        const emoji_font: [*:0]const u16 = std.unicode.utf8ToUtf16LeStringLiteral("Segoe UI Emoji");
        const font_size: f32 = @as(f32, @floatFromInt(px)) * 0.78;
        var fmt: ?*c.IDWriteTextFormat = null;
        const create_tf = dwrite_factory.lpVtbl.*.CreateTextFormat orelse break :blk false;
        if (create_tf(dwrite_factory, emoji_font, null, c.DWRITE_FONT_WEIGHT_NORMAL, c.DWRITE_FONT_STYLE_NORMAL, c.DWRITE_FONT_STRETCH_NORMAL, font_size, std.unicode.utf8ToUtf16LeStringLiteral("en-us"), &fmt) != 0 or fmt == null) break :blk false;
        defer {
            const u: *c.IUnknown = @ptrCast(fmt.?);
            _ = u.lpVtbl.*.Release.?(u);
        }
        if (fmt.?.lpVtbl.*.SetTextAlignment) |f| _ = f(fmt.?, c.DWRITE_TEXT_ALIGNMENT_CENTER);
        if (fmt.?.lpVtbl.*.SetParagraphAlignment) |f| _ = f(fmt.?, c.DWRITE_PARAGRAPH_ALIGNMENT_CENTER);

        const rt_base: *c.ID2D1RenderTarget = @ptrCast(dc_rt.?);
        const vtbl = rt_base.lpVtbl.*;
        if (vtbl.BeginDraw) |f| f(rt_base);
        if (vtbl.Clear) |f| {
            const transparent = c.D2D1_COLOR_F{ .r = 0, .g = 0, .b = 0, .a = 0 };
            f(rt_base, &transparent);
        }
        var brush: ?*c.ID2D1SolidColorBrush = null;
        if (vtbl.CreateSolidColorBrush) |f| {
            const white = c.D2D1_COLOR_F{ .r = 1, .g = 1, .b = 1, .a = 1 };
            _ = f(rt_base, &white, null, &brush);
        }
        defer {
            if (brush) |b| {
                const u: *c.IUnknown = @ptrCast(b);
                _ = u.lpVtbl.*.Release.?(u);
            }
        }
        if (brush) |b| {
            const layout = c.D2D1_RECT_F{ .left = 0, .top = 0, .right = @floatFromInt(px), .bottom = @floatFromInt(px) };
            if (vtbl.DrawTextW) |draw_fn| {
                draw_fn(rt_base, &agent_emoji_utf16, agent_emoji_utf16.len, fmt.?, &layout, @ptrCast(b), c.D2D1_DRAW_TEXT_OPTIONS_ENABLE_COLOR_FONT, c.DWRITE_MEASURING_MODE_NATURAL);
            }
        }
        var t1: u64 = 0;
        var t2: u64 = 0;
        if (vtbl.EndDraw) |f| {
            if (f(rt_base, &t1, &t2) != 0) break :blk false;
        }
        break :blk true;
    };

    // A selected bitmap cannot be deleted. Restore the DC before either the
    // failure cleanup or returning ownership to the cache.
    _ = c.SelectObject(hdc, old_hbm);
    if (!ok) {
        _ = c.DeleteObject(hbm);
        return null;
    }
    return hbm;
}

/// Cached 🤖 bitmap at the requested square size; re-rasterizes on size change.
fn ensureAgentEmoji(app: *App, px: i32) ?c.HBITMAP {
    if (app.tabline_state.agent_emoji_hbm) |hbm| {
        if (app.tabline_state.agent_emoji_px == px) return hbm;
        _ = c.DeleteObject(hbm);
        app.tabline_state.agent_emoji_hbm = null;
    }
    const r = if (app.atlas) |*rr| rr else return null;
    const d2d = r.d2d_factory orelse return null;
    const dw = r.dwrite_factory orelse return null;
    const hbm = rasterizeAgentEmoji(d2d, dw, px) orelse return null;
    app.tabline_state.agent_emoji_hbm = hbm;
    app.tabline_state.agent_emoji_px = px;
    return hbm;
}

/// AlphaBlend the cached premultiplied 🤖 bitmap onto the tabline DC.
fn blendAgentEmoji(dst_hdc: c.HDC, hbm: c.HBITMAP, x: i32, y: i32, px: i32) void {
    const mem = c.CreateCompatibleDC(dst_hdc);
    if (mem == null) return;
    defer _ = c.DeleteDC(mem);
    const old = c.SelectObject(mem, hbm);
    defer _ = c.SelectObject(mem, old);
    const bf = c.BLENDFUNCTION{ .BlendOp = c.AC_SRC_OVER, .BlendFlags = 0, .SourceConstantAlpha = 255, .AlphaFormat = c.AC_SRC_ALPHA };
    _ = c.AlphaBlend(dst_hdc, x, y, px, px, mem, 0, 0, px, px, bf);
}

/// Calculate the Neovim :tabmove position from a drop target index.
/// Returns the value N for `:tabmove N`.
///
/// `to_idx` is the insertion index in the tab list *before* the move, and
/// `:tabmove N` moves the current tab to after tab page N counted in that same
/// pre-move list (1-based, 0 = very front). The two are the same number, so
/// this only clamps. Subtracting one landed every reorder a slot short, and
/// turned a one-slot rightward drag into "move after myself" — a no-op.
fn calculateTabMovePosition(to_idx: usize, tab_count: usize) i32 {
    return @intCast(@min(to_idx, tab_count));
}

/// Calculate a drop target index from a mouse position along a uniform-sized item list.
/// Works for both X-axis (titlebar) and Y-axis (sidebar) by passing the appropriate coordinate.
fn calculateDropTarget(mouse_pos: c_int, item_count: usize, item_size: c_int) usize {
    var target_idx: usize = 0;
    for (0..item_count) |i| {
        const item_center: c_int = @as(c_int, @intCast(i)) * item_size + @divTrunc(item_size, 2);
        if (mouse_pos < item_center) {
            target_idx = i;
            break;
        }
        target_idx = i + 1;
    }
    if (target_idx > item_count) {
        target_idx = item_count;
    }
    return target_idx;
}





// Content child window for D3D11 rendering (when ext_tabline enabled)




/// Width of one tab for a given client width and tab count. Every drawing and
/// hit-testing path must agree on this; it used to be spelled out at each
/// site, including one copy in window.zig's WM_NCHITTEST.
///
/// tab_count <= 0 returns 0. The inline copies divided without that guard and
/// were safe only because their callers checked first.
pub fn tabWidthPx(app: *App, client_width: c_int, tab_count: c_int) c_int {
    if (tab_count <= 0) return 0;
    const available = client_width -
        app.scalePx(TablineState.WINDOW_CONTROLS_WIDTH) -
        app.scalePx(40) -
        app.scalePx(TablineState.WINDOW_BTNS_TOTAL);
    return @min(
        app.scalePx(TablineState.TAB_MAX_WIDTH),
        @max(app.scalePx(TablineState.TAB_MIN_WIDTH), @divTrunc(available, tab_count)),
    );
}

/// Left edge of the + button, which sits one gap past the last tab.
pub fn plusButtonXPx(app: *App, tab_count: c_int, tab_width: c_int) c_int {
    return app.scalePx(TablineState.WINDOW_CONTROLS_WIDTH) +
        tab_count * (tab_width + 1) + app.scalePx(8);
}

/// Side of the square + button. Both the painted ellipse and every hit test
/// use this.
pub fn plusButtonSizePx(app: *App) c_int {
    return app.scalePx(20);
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
    const close_size = app.scalePx(TablineState.TAB_CLOSE_SIZE);
    const btns_total = app.scalePx(TablineState.WINDOW_BTNS_TOTAL);
    const btn_w = app.scalePx(TablineState.WINDOW_BTN_WIDTH);
    // External drag threshold: do NOT DPI-scale. This is a mouse movement distance
    // threshold, which should be constant in physical pixels regardless of DPI.
    const ext_drag_threshold: c_int = TablineState.EXTERNAL_DRAG_THRESHOLD;
    const close_margin = app.scalePx(6);
    const plus_offset = app.scalePx(8);
    const plus_btn_size = plusButtonSizePx(app);

    // Handle dragging
    if (app.tabline_state.dragging_tab) |drag_idx| {
        app.tabline_state.drag_current_x = x;

        // Check if mouse is outside tabbar area bounds (for external drag)
        // Uses tabbar region (top of window, TAB_BAR_HEIGHT tall) instead of full window
        var is_outside_tabbar = false;
        if (app.hwnd) |main_hwnd| {
            var window_rect: c.RECT = undefined;
            if (c.GetWindowRect(main_hwnd, &window_rect) != 0) {
                // Convert client coords to screen coords
                var screen_pt: c.POINT = .{ .x = x, .y = y };
                _ = c.ClientToScreen(hwnd, &screen_pt);

                // Tabbar area = top of window, TAB_BAR_HEIGHT tall
                var tabbar_rect = window_rect;
                tabbar_rect.bottom = tabbar_rect.top + bar_height;

                // Expand tabbar rect by threshold
                const threshold = ext_drag_threshold;
                const expanded_left = tabbar_rect.left - threshold;
                const expanded_top = tabbar_rect.top - threshold;
                const expanded_right = tabbar_rect.right + threshold;
                const expanded_bottom = tabbar_rect.bottom + threshold;

                is_outside_tabbar = (screen_pt.x < expanded_left or screen_pt.x > expanded_right or
                    screen_pt.y < expanded_top or screen_pt.y > expanded_bottom);

                if (is_outside_tabbar and !app.tabline_state.is_external_drag) {
                    app.tabline_state.is_external_drag = true;
                    if (applog.isEnabled()) applog.appLog("[tabline] entering external drag mode for tab {d}\n", .{drag_idx});
                    createDragPreviewWindow(app, drag_idx, screen_pt.x, screen_pt.y);
                } else if (!is_outside_tabbar and app.tabline_state.is_external_drag) {
                    app.tabline_state.is_external_drag = false;
                    if (applog.isEnabled()) applog.appLog("[tabline] returning to normal drag mode\n", .{});
                    destroyDragPreviewWindow(app);
                }

                if (app.tabline_state.is_external_drag) {
                    updateDragPreviewPosition(app, screen_pt.x, screen_pt.y);
                }
            }
        }

        // Normal in-window drag: calculate drop target
        if (!app.tabline_state.is_external_drag) {
            const tab_count: c_int = @intCast(app.tabline_state.tab_count);
            if (tab_count > 0) {
                const tab_width = tabWidthPx(app, client_width, tab_count);

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
        const tab_count: c_int = @intCast(app.tabline_state.tab_count);
        if (tab_count > 0 and pressed_tab_idx < app.tabline_state.tab_count) {
            const tab_width = tabWidthPx(app, client_width, tab_count);

            const tab_x: c_int = app.scalePx(TablineState.WINDOW_CONTROLS_WIDTH) + @as(c_int, @intCast(pressed_tab_idx)) * (tab_width + 1);
            const close_x = tab_x + tab_width - close_size - close_margin;
            const close_y = @divTrunc(bar_height - close_size, 2);

            const is_still_over_close = (x >= close_x and x < close_x + close_size and
                y >= close_y and y < close_y + close_size);

            if (!is_still_over_close) {
                // Mouse left the close button - cancel the press
                if (applog.isEnabled()) applog.appLog("[tabline] mouseMove: close button cancelled (mouse left)\n", .{});
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
        const tab_count: c_int = @intCast(app.tabline_state.tab_count);
        if (tab_count > 0) {
            const tab_width = tabWidthPx(app, client_width, tab_count);
            const plus_x = app.scalePx(TablineState.WINDOW_CONTROLS_WIDTH) + tab_count * (tab_width + 1) + plus_offset;

            const plus_top = @divTrunc(bar_height - plus_btn_size, 2);
            const is_still_over_plus = (x >= plus_x and x < plus_x + plus_btn_size and y >= plus_top and y < plus_top + plus_btn_size);

            if (!is_still_over_plus) {
                // Mouse left the + button - cancel the press
                if (applog.isEnabled()) applog.appLog("[tabline] mouseMove: new tab button cancelled (mouse left)\n", .{});
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
            if (applog.isEnabled()) applog.appLog("[tabline] mouseMove: window button {d} cancelled (mouse left)\n", .{pressed_btn});
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
        const tab_count: c_int = @intCast(app.tabline_state.tab_count);
        if (tab_count > 0) {
            const tab_width = tabWidthPx(app, client_width, tab_count);

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
        const tab_count_for_plus: c_int = @intCast(app.tabline_state.tab_count);
        if (tab_count_for_plus > 0) {
            const tab_width_for_plus = tabWidthPx(app, client_width, tab_count_for_plus);
            const plus_x = plusButtonXPx(app, tab_count_for_plus, tab_width_for_plus);

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
    if (applog.isEnabled()) applog.appLog("[tabline] mouseDown: x={d} y={d}\n", .{ x, y });

    // DPI-scaled constants
    const bar_height = app.scalePx(TablineState.TAB_BAR_HEIGHT);
    const close_size = app.scalePx(TablineState.TAB_CLOSE_SIZE);
    const btns_total = app.scalePx(TablineState.WINDOW_BTNS_TOTAL);
    const btn_w = app.scalePx(TablineState.WINDOW_BTN_WIDTH);
    const close_margin = app.scalePx(6);
    const plus_btn_size = plusButtonSizePx(app);

    var rect: c.RECT = undefined;
    _ = c.GetClientRect(hwnd, &rect);
    const client_width = rect.right;

    // Check window control buttons first
    const btn_start_x = client_width - btns_total;
    if (x >= btn_start_x and y >= 0 and y < bar_height) {
        // Window button area - record pressed state, action on mouseUp
        const btn_idx = @divTrunc(x - btn_start_x, btn_w);
        if (btn_idx >= 0 and btn_idx < 3) {
            if (applog.isEnabled()) applog.appLog("[tabline] mouseDown: window button {d} pressed\n", .{btn_idx});
            app.tabline_state.pressed_window_btn = @intCast(btn_idx);
            _ = c.SetCapture(hwnd);
            _ = c.InvalidateRect(hwnd, null, 0);
        }
        return;
    }

    // Check close button on tabs
    const tab_count: c_int = @intCast(app.tabline_state.tab_count);
    if (tab_count > 0) {
        const tab_width = tabWidthPx(app, client_width, tab_count);

        if (applog.isEnabled()) applog.appLog("[tabline] mouseDown: tab_count={d} tab_width={d}\n", .{ tab_count, tab_width });

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
                    if (applog.isEnabled()) applog.appLog("[tabline] mouseDown: close button pressed on tab {d}\n", .{i});
                    app.tabline_state.close_button_pressed = i;
                    _ = c.SetCapture(hwnd); // Capture to get mouseUp even if mouse leaves
                    _ = c.InvalidateRect(hwnd, null, 0); // Redraw for pressed state
                    return;
                }

                // Start potential drag - first select this tab
                if (applog.isEnabled()) applog.appLog("[tabline] mouseDown: starting drag on tab {d}\n", .{i});
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
    const tab_count_for_plus: c_int = @intCast(app.tabline_state.tab_count);
    if (tab_count_for_plus > 0) {
        const tab_width_for_plus = tabWidthPx(app, client_width, tab_count_for_plus);
        const plus_x = plusButtonXPx(app, tab_count_for_plus, tab_width_for_plus);

        if (x >= plus_x and x < plus_x + plus_btn_size) {
            // New tab button pressed - record state, action on mouseUp
            if (applog.isEnabled()) applog.appLog("[tabline] mouseDown: new tab button pressed\n", .{});
            app.tabline_state.new_tab_button_pressed = true;
            _ = c.SetCapture(hwnd);
            return;
        }
    }

    // Empty area - no action needed on mouseDown
}

/// Handle mouse up on tabline - finish drag or handle click
pub fn handleTablineMouseUp(app: *App, hwnd: c.HWND, x: c_int, y: c_int) void {
    if (applog.isEnabled()) applog.appLog("[tabline] mouseUp: x={d} y={d} dragging_tab={?} is_external_drag={} close_button_pressed={?}\n", .{ x, y, app.tabline_state.dragging_tab, app.tabline_state.is_external_drag, app.tabline_state.close_button_pressed });

    // Handle close button release first (before ReleaseCapture)
    // Note: If mouse moved away from close button, close_button_pressed was already
    // cleared in handleTablineMouseMoveInChild. So if we get here with close_button_pressed
    // still set, the mouse is still over the button and we should execute the close action.
    if (app.tabline_state.close_button_pressed) |pressed_tab_idx| {
        app.tabline_state.close_button_pressed = null;
        _ = c.ReleaseCapture();

        // Execute close action - mouse was still over button (otherwise mouseMove would have cancelled)
        if (applog.isEnabled()) applog.appLog("[tabline] mouseUp: close button released on tab {d}, closing\n", .{pressed_tab_idx});
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
        if (applog.isEnabled()) applog.appLog("[tabline] mouseUp: new tab button released, creating new tab\n", .{});
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
        if (applog.isEnabled()) applog.appLog("[tabline] mouseUp: window button {d} released, executing action\n", .{pressed_btn});
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

            if (applog.isEnabled()) applog.appLog("[tabline] mouseUp: externalizing tab {d} at screen ({d},{d})\n", .{ drag_idx, screen_pt.x, screen_pt.y });
            externalizeTab(app, drag_idx, screen_pt.x, screen_pt.y);
            _ = c.InvalidateRect(hwnd, null, 0);
            return;
        }

        const moved_distance = if (x > drag_start)
            x - drag_start
        else
            drag_start - x;

        const drag_threshold = app.scalePx(TablineState.DRAG_THRESHOLD);
        if (applog.isEnabled()) applog.appLog("[tabline] mouseUp: drag_idx={d} moved_distance={d} threshold={d}\n", .{ drag_idx, moved_distance, drag_threshold });

        if (moved_distance < drag_threshold) {
            // Didn't move enough - treat as click (select tab)
            // Tab was already selected on mouseDown, nothing more to do
        } else if (drop_target_opt) |target_idx| {
            // Actually moved - reorder tab
            const from_idx = drag_idx;
            const to_idx = target_idx;

            if (applog.isEnabled()) applog.appLog("[tabline] mouseUp: from_idx={d} to_idx={d} tab_count={d}\n", .{ from_idx, to_idx, app.tabline_state.tab_count });

            // Dropping onto your own slot, or just past it, inserts you where
            // you already are.
            if (to_idx != from_idx and to_idx != from_idx + 1) {
                const new_pos = calculateTabMovePosition(to_idx, app.tabline_state.tab_count);

                if (applog.isEnabled()) applog.appLog("[tabline] mouseUp: calculated new_pos={d}\n", .{new_pos});

                if (app.corep) |corep| {
                    // Tab was already selected on mouseDown, just send :tabmove
                    // Use nvim_command API so command doesn't show in cmdline
                    var cmd_buf: [32]u8 = undefined;
                    const cmd = std.fmt.bufPrint(&cmd_buf, "tabmove {d}", .{new_pos}) catch {
                        _ = c.InvalidateRect(hwnd, null, 0);
                        return;
                    };
                    if (applog.isEnabled()) applog.appLog("[tabline] mouseUp: sending cmd len={d}\n", .{cmd.len});
                    app_mod.zonvie_core_send_command(corep, cmd.ptr, cmd.len);
                }
            } else {
                if (applog.isEnabled()) applog.appLog("[tabline] mouseUp: no move needed (same position)\n", .{});
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

    const preview_w: c_int = app.scalePx(150);
    const preview_h: c_int = app.scalePx(30);

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
        if (applog.isEnabled()) applog.appLog("[tabline] failed to create drag preview window\n", .{});
        return;
    }

    // Store app pointer for WM_PAINT
    _ = c.SetWindowLongPtrW(preview_hwnd, c.GWLP_USERDATA, @bitCast(@intFromPtr(app)));

    app.tabline_state.drag_preview_hwnd = preview_hwnd;
    _ = c.ShowWindow(preview_hwnd, c.SW_SHOWNOACTIVATE);
    if (applog.isEnabled()) applog.appLog("[tabline] created drag preview window at ({d},{d})\n", .{ pos_x, pos_y });
}

/// Update the position of the drag preview window
pub fn updateDragPreviewPosition(app: *App, screen_x: c_int, screen_y: c_int) void {
    if (app.tabline_state.drag_preview_hwnd) |preview_hwnd| {
        const preview_w: c_int = app.scalePx(150);
        const preview_h: c_int = app.scalePx(30);
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
        if (applog.isEnabled()) applog.appLog("[tabline] destroyed drag preview window\n", .{});
    }
}

/// Externalize a tab by creating an external Neovim window
pub fn externalizeTab(app: *App, tab_idx: usize, screen_x: c_int, screen_y: c_int) void {
    if (applog.isEnabled()) applog.appLog("[tabline] externalizeTab: tab_idx={d} screen=({d},{d})\n", .{ tab_idx, screen_x, screen_y });

    if (app.corep == null) {
        if (applog.isEnabled()) applog.appLog("[tabline] externalizeTab: corep is null\n", .{});
        return;
    }
    const corep = app.corep.?;

    if (tab_idx >= app.tabline_state.tab_count) {
        if (applog.isEnabled()) applog.appLog("[tabline] externalizeTab: tab_idx out of range\n", .{});
        return;
    }

    // Set pending position for the new external window (with timestamp for timeout)
    app.pending_external_window_position = .{ .x = screen_x, .y = screen_y };
    app.pending_external_window_position_time = @as(i64, @intCast(@divTrunc(core.clock.nowNs(), std.time.ns_per_ms)));

    // Execute single Lua script that does both tab switch and externalization atomically.
    // Uses nvim_open_win to create a new external window instead of vnew + nvim_win_set_config.
    // In ext_windows mode, vnew would trigger win_split which creates another external window.
    // The Lua script:
    // 1. Switch to the target tab
    // 2. Check if tab has multiple windows (split) - abort if so
    // 3. Get the window's buffer, cursor position, and dimensions
    // 4. Create a new external window with nvim_open_win showing the same buffer
    // 5. Replace the original window's buffer with a scratch buffer
    const tab_number = tab_idx + 1;
    var lua_buf: [768]u8 = undefined;
    const lua_script = std.fmt.bufPrint(&lua_buf, "lua vim.cmd('{d}tabnext'); local tp=vim.api.nvim_get_current_tabpage(); local ws=vim.api.nvim_tabpage_list_wins(tp); if #ws>1 then vim.notify('Cannot externalize: split window',vim.log.levels.WARN); return end; local w=ws[1]; local buf=vim.api.nvim_win_get_buf(w); local cur=vim.api.nvim_win_get_cursor(w); local W=vim.api.nvim_win_get_width(w); local H=vim.api.nvim_win_get_height(w); local ew=vim.api.nvim_open_win(buf,true,{{external=true,width=W,height=H}}); vim.api.nvim_win_set_cursor(ew,cur); vim.api.nvim_win_set_buf(w,vim.api.nvim_create_buf(true,true))", .{tab_number}) catch {
        if (applog.isEnabled()) applog.appLog("[tabline] externalizeTab: failed to format Lua script\n", .{});
        return;
    };
    if (applog.isEnabled()) applog.appLog("[tabline] externalizeTab: sending Lua script via command\n", .{});
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
        if (applog.isEnabled()) applog.appLog("[win] Failed to register drag preview window class\n", .{});
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

                // Match the active OS theme so the drag preview blends with
                // the titlebar palette regardless of light/dark mode.
                const preview_pal = currentTitlebarPalette();

                // Fill with theme background
                const bg_brush = c.CreateSolidBrush(preview_pal.bar_bg);
                _ = c.FillRect(hdc, &rect, bg_brush);
                _ = c.DeleteObject(bg_brush);

                // Draw border using the muted glyph pen color
                const border_brush = c.CreateSolidBrush(preview_pal.glyph_pen);
                _ = c.FrameRect(hdc, &rect, border_brush);
                _ = c.DeleteObject(border_brush);

                // Draw tab name
                const app_ptr = c.GetWindowLongPtrW(hwnd, c.GWLP_USERDATA);
                if (app_ptr != 0) {
                    const app: *App = @ptrFromInt(@as(usize, @bitCast(app_ptr)));

                    // Create DPI-scaled font
                    const hfont = c.CreateFontW(
                        app.scalePx(-12),
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
                        c.CLEARTYPE_QUALITY,
                        c.DEFAULT_PITCH | c.FF_DONTCARE,
                        null,
                    );
                    const old_font = c.SelectObject(hdc, hfont);

                    const text_pad = app.scalePx(10);

                    if (app.tabline_state.dragging_tab) |drag_idx| {
                        if (drag_idx < app.tabline_state.tab_count) {
                            const tab = &app.tabline_state.tabs[drag_idx];
                            if (tab.name_len > 0) {
                                // Display name (basename, preserving the agent-status glyph).
                                var name_buf: [256]u8 = undefined;
                                const display_name = name_buf[0..extractTabDisplayName(tab, &name_buf)];

                                // Draw text
                                var text_rect = rect;
                                text_rect.left += text_pad;
                                text_rect.right -= text_pad;
                                _ = c.SetBkMode(hdc, c.TRANSPARENT);
                                _ = c.SetTextColor(hdc, preview_pal.text_selected);

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
                                text_rect.left += text_pad;
                                text_rect.right -= text_pad;
                                _ = c.SetBkMode(hdc, c.TRANSPARENT);
                                _ = c.SetTextColor(hdc, preview_pal.text_normal);
                                _ = c.DrawTextW(hdc, &no_name, 9, &text_rect, c.DT_SINGLELINE | c.DT_VCENTER | c.DT_CENTER);
                            }
                        }
                    }

                    _ = c.SelectObject(hdc, old_font);
                    _ = c.DeleteObject(hfont);
                }

                _ = c.EndPaint(hwnd, &ps);
            }
            return 0;
        },
        else => return c.DefWindowProcW(hwnd, msg, wParam, lParam),
    }
}

/// Normalize an optional index for deterministic hashing (optional padding
/// bytes are undefined and must not enter the signature).
fn sigOptIdx(v: ?usize) u64 {
    return if (v) |x| @as(u64, x) else std.math.maxInt(u64);
}

fn sigOptByte(v: ?u8) u64 {
    return if (v) |x| @as(u64, x) else std.math.maxInt(u64);
}

/// Hash of everything drawTablineContent draws for the titlebar strip.
/// Used by renderTablineToD3D to skip byte-identical re-renders.
fn tablineRenderSignature(app: *App, width: u32, height: u32) u64 {
    const ts = &app.tabline_state;
    var h = std.hash.Wyhash.init(0);
    h.update(std.mem.asBytes(&width));
    h.update(std.mem.asBytes(&height));
    h.update(std.mem.asBytes(&app.dpi_scale));
    h.update(std.mem.asBytes(&window_mod.g_os_dark_theme_cached));
    h.update(std.mem.asBytes(&ts.tab_count));
    h.update(std.mem.asBytes(&ts.current_tab));
    for (ts.tabs[0..ts.tab_count]) |*tab| {
        h.update(std.mem.asBytes(&tab.handle));
        h.update(tab.name[0..tab.name_len]);
    }
    var opt_fields = [_]u64{
        sigOptIdx(ts.hovered_tab),
        sigOptIdx(ts.hovered_close),
        sigOptByte(ts.hovered_window_btn),
        @intFromBool(ts.hovered_new_tab_btn),
        sigOptIdx(ts.dragging_tab),
        @as(u64, @bitCast(@as(i64, ts.drag_current_x))),
        sigOptIdx(ts.drop_target_index),
        sigOptIdx(ts.close_button_pressed),
        @intFromBool(ts.new_tab_button_pressed),
        sigOptByte(ts.pressed_window_btn),
        @as(u64, ts.spinner_frame),
        @as(u64, ts.agent_count),
    };
    h.update(std.mem.sliceAsBytes(opt_fields[0..]));
    h.update(std.mem.asBytes(&ts.agent_handles));
    h.update(std.mem.asBytes(&ts.agent_states));
    return h.final();
}

/// Render tabline to D3D11 texture via offscreen GDI bitmap.
/// This avoids DWM composition issues by keeping GDI rendering offscreen
/// and only using D3D11 for final display.
pub fn renderTablineToD3D(app: *App, width: u32, height: u32) void {
    if (app.renderer == null) return;
    if (app.tabline_state.tab_count == 0) return;
    if (width == 0 or height == 0) return;

    // Change gate: WM_PAINT calls this unconditionally, but the tab strip
    // rarely changes between paints. A full re-render costs a fresh
    // width*height*4 DIB allocation, dozens of GDI object creations, a CPU
    // pass over every pixel and a full-texture GPU upload — per keystroke
    // repaint and per cursor-blink toggle. Skip when the drawn content is
    // byte-identical to what the D3D texture already holds.
    const sig = tablineRenderSignature(app, width, height);
    if (sig == app.tabline_render_sig) return;

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
            if (applog.isEnabled()) applog.appLog("[tabline] updateTablineTexture failed: {any}\n", .{e});
            return;
        };
        // Only record the signature after a successful upload so a failed
        // upload retries on the next paint.
        app.tabline_render_sig = sig;
    }
}

/// Draw tabline content (called from offscreen DC or child window WM_PAINT)
/// Color palette for the custom titlebar / tabline rendering. All values
/// are picked from the OS app-theme preference (Settings → Personalization
/// → Colors) so the titlebar tracks the system light/dark mode regardless
/// of the active Neovim colorscheme. Approximates the Windows 11 native
/// titlebar palette.
const TitlebarPalette = struct {
    bar_bg: c.COLORREF,
    tab_selected: c.COLORREF,
    tab_hover: c.COLORREF,
    tab_normal: c.COLORREF,
    tab_placeholder: c.COLORREF,
    tab_dragging: c.COLORREF,
    text_selected: c.COLORREF,
    text_normal: c.COLORREF,
    glyph_pen: c.COLORREF, // close X, + icon, plus pen
    glyph_hover_bg: c.COLORREF, // close hover bg, plus hover bg
    wbtn_icon: c.COLORREF,
    wbtn_hover_bg: c.COLORREF,
    wbtn_close_hover_bg: c.COLORREF, // red, same in both themes
    wbtn_close_hover_icon: c.COLORREF, // white on red bg, same in both themes
    accent: c.COLORREF, // drop indicator / float-tab border
};

fn currentTitlebarPalette() TitlebarPalette {
    // Read the cached dark-mode flag (UI-thread only). The cache is
    // refreshed by window.applyOsTitlebarTheme() / handleThemeReread() on
    // initial bring-up and on theme-change notifications, so no registry
    // syscall enters the WM_PAINT hot path.
    if (window_mod.g_os_dark_theme_cached) {
        return .{
            .bar_bg = c.RGB(32, 32, 32),
            .tab_selected = c.RGB(48, 48, 48),
            .tab_hover = c.RGB(58, 58, 58),
            .tab_normal = c.RGB(40, 40, 40),
            .tab_placeholder = c.RGB(50, 50, 50),
            .tab_dragging = c.RGB(40, 60, 90),
            .text_selected = c.RGB(255, 255, 255),
            .text_normal = c.RGB(180, 180, 180),
            .glyph_pen = c.RGB(200, 200, 200),
            .glyph_hover_bg = c.RGB(80, 80, 80),
            .wbtn_icon = c.RGB(220, 220, 220),
            .wbtn_hover_bg = c.RGB(60, 60, 60),
            .wbtn_close_hover_bg = c.RGB(232, 17, 35),
            .wbtn_close_hover_icon = c.RGB(255, 255, 255),
            .accent = c.RGB(0, 120, 215),
        };
    }
    return .{
        .bar_bg = c.RGB(240, 240, 240),
        .tab_selected = c.RGB(255, 255, 255),
        .tab_hover = c.RGB(230, 230, 230),
        .tab_normal = c.RGB(220, 220, 220),
        .tab_placeholder = c.RGB(200, 200, 200),
        .tab_dragging = c.RGB(200, 220, 255),
        .text_selected = c.RGB(0, 0, 0),
        .text_normal = c.RGB(80, 80, 80),
        .glyph_pen = c.RGB(100, 100, 100),
        .glyph_hover_bg = c.RGB(200, 200, 200),
        .wbtn_icon = c.RGB(50, 50, 50),
        .wbtn_hover_bg = c.RGB(230, 230, 230),
        .wbtn_close_hover_bg = c.RGB(232, 17, 35),
        .wbtn_close_hover_icon = c.RGB(255, 255, 255),
        .accent = c.RGB(0, 120, 215),
    };
}

pub fn drawTablineContent(app: *App, hdc: c.HDC, client_width: c_int) void {
    if (app.tabline_state.tab_count == 0) {
        return;
    }

    const bar_height = app.scalePx(TablineState.TAB_BAR_HEIGHT);
    const tab_padding = app.scalePx(TablineState.TAB_PADDING);
    const close_size = app.scalePx(TablineState.TAB_CLOSE_SIZE);
    const btns_total = app.scalePx(TablineState.WINDOW_BTNS_TOTAL);
    const btn_w = app.scalePx(TablineState.WINDOW_BTN_WIDTH);
    const drag_threshold = app.scalePx(TablineState.DRAG_THRESHOLD);
    const close_margin = app.scalePx(6);
    const close_inset = app.scalePx(3);
    const top_padding = app.scalePx(4);
    const plus_offset = app.scalePx(8);
    const plus_btn_size = plusButtonSizePx(app);
    const plus_icon_inset = app.scalePx(5);
    const is_dragging = app.tabline_state.dragging_tab != null;

    const pal = currentTitlebarPalette();

    // Background
    const bg_brush = c.CreateSolidBrush(pal.bar_bg);
    defer _ = c.DeleteObject(bg_brush);
    var bar_rect = c.RECT{
        .left = 0,
        .top = 0,
        .right = client_width,
        .bottom = bar_height,
    };
    _ = c.FillRect(hdc, &bar_rect, bg_brush);

    // Calculate tab width
    const tab_count: c_int = @intCast(app.tabline_state.tab_count);
    const tab_width = tabWidthPx(app, client_width, tab_count);

    // Brushes
    const selected_brush = c.CreateSolidBrush(pal.tab_selected);
    const hover_brush = c.CreateSolidBrush(pal.tab_hover);
    const normal_brush = c.CreateSolidBrush(pal.tab_normal);
    const dragging_brush = c.CreateSolidBrush(pal.tab_dragging);
    defer {
        _ = c.DeleteObject(selected_brush);
        _ = c.DeleteObject(hover_brush);
        _ = c.DeleteObject(normal_brush);
        _ = c.DeleteObject(dragging_brush);
    }

    // Font
    const font = c.CreateFontW(
        app.scalePx(-12),
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
        c.CLEARTYPE_QUALITY,
        c.DEFAULT_PITCH | c.FF_DONTCARE,
        null,
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
            const placeholder_brush = c.CreateSolidBrush(pal.tab_placeholder);
            _ = c.FillRect(hdc, &tab_rect, placeholder_brush);
            _ = c.DeleteObject(placeholder_brush);
            x += tab_width + 1;
            continue;
        }

        // Background
        const brush = if (is_selected) selected_brush else if (is_hovered) hover_brush else normal_brush;
        _ = c.FillRect(hdc, &tab_rect, brush);

        // Tab name
        _ = c.SetTextColor(hdc, if (is_selected) pal.text_selected else pal.text_normal);

        var text_rect = c.RECT{
            .left = x + tab_padding,
            .top = top_padding,
            .right = x + tab_width - tab_padding - close_size - top_padding,
            .bottom = bar_height,
        };

        // AI-agent indicator drawn in a FIXED-WIDTH cell so varying spinner
        // glyph widths never shift the tab title between frames. Idle shows a
        // color 🤖 (AlphaBlend; GDI DrawTextW can't render color emoji);
        // working shows a monochrome spinner glyph centered in the same cell.
        const a_state = if (app.config.tabline.agent_indicator) app.tabline_state.agentState(tab.handle) else 0;
        if (a_state != 0) {
            // Indicator cell sized near the text cap height, sitting inline.
            const ind_px = @divTrunc((bar_height - top_padding * 2) * 7, 10);
            const cell_w = ind_px + top_padding; // glyph box + gap, reserved
            if (a_state == 1) {
                if (if (ind_px > 0) ensureAgentEmoji(app, ind_px) else null) |hbm| {
                    const ey = @divTrunc(bar_height - ind_px, 2);
                    blendAgentEmoji(hdc, hbm, text_rect.left, ey, ind_px);
                } else {
                    drawIndicatorGlyph(hdc, "●", text_rect.left, ind_px, text_rect.top, text_rect.bottom);
                }
            } else if (a_state == 4) {
                // Waiting for user input -> pause glyph (two bars).
                drawPauseGlyph(hdc, text_rect.left, ind_px, text_rect.top, text_rect.bottom);
            } else {
                const g = agentSpinnerGlyph(a_state, app.tabline_state.spinner_frame);
                drawIndicatorGlyph(hdc, g, text_rect.left, ind_px, text_rect.top, text_rect.bottom);
            }
            text_rect.left += cell_w; // anchor the title past the fixed cell
        }

        // Display name = basename only (indicator drawn separately above).
        var base_buf: [256]u8 = undefined;
        const base_len = extractTabDisplayName(tab, &base_buf);

        // Convert to wide string
        var wide_buf: [320]u16 = undefined;
        const wide_len = std.unicode.utf8ToUtf16Le(&wide_buf, base_buf[0..base_len]) catch 0;

        _ = c.DrawTextW(hdc, &wide_buf, @intCast(wide_len), &text_rect, c.DT_LEFT | c.DT_VCENTER | c.DT_SINGLELINE | c.DT_END_ELLIPSIS);

        // Close button (X) - show on selected or hovered tabs
        if (is_selected or is_hovered) {
            const close_x = x + tab_width - close_size - close_margin;
            const close_y = @divTrunc(bar_height - close_size, 2);

            // Highlight if close button hovered
            if (app.tabline_state.hovered_close == i) {
                const highlight_brush = c.CreateSolidBrush(pal.glyph_hover_bg);
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
            const pen = c.CreatePen(c.PS_SOLID, 1, pal.glyph_pen);
            const old_pen = c.SelectObject(hdc, pen);
            // GDI LineTo excludes the endpoint pixel. Extend each LineTo target by
            // one step in the line direction so both bottom corners of the X are
            // covered (otherwise the bottom of the X looks clipped).
            _ = c.MoveToEx(hdc, close_x + close_inset, close_y + close_inset, null);
            _ = c.LineTo(hdc, close_x + close_size - close_inset + 1, close_y + close_size - close_inset + 1);
            _ = c.MoveToEx(hdc, close_x + close_size - close_inset, close_y + close_inset, null);
            _ = c.LineTo(hdc, close_x + close_inset - 1, close_y + close_size - close_inset + 1);
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
            const plus_hover_brush = c.CreateSolidBrush(pal.glyph_hover_bg);
            // The previous brush is restored before DeleteObject: GDI refuses to
            // delete an object still selected into a DC, so deleting it while
            // selected silently leaks the handle.
            const old_brush_hover = c.SelectObject(hdc, plus_hover_brush);
            const null_pen = c.GetStockObject(c.NULL_PEN);
            const old_pen_hover = c.SelectObject(hdc, null_pen);
            _ = c.Ellipse(hdc, plus_x, plus_y, plus_x + plus_btn_size, plus_y + plus_btn_size);
            _ = c.SelectObject(hdc, old_pen_hover);
            _ = c.SelectObject(hdc, old_brush_hover);
            _ = c.DeleteObject(plus_hover_brush);
        }

        // Draw + icon as two filled 2px bars. A width-2 GDI pen renders
        // asymmetrically, so each bar spans inset-1 .. (btn-inset) inclusive to
        // keep the arms equal: the 2px thickness sits at center-1..center (half a
        // pixel up-left), so without the -1 on top/left the up-left arms come out
        // 1px short. The +1 on right/bottom also covers FillRect's excluded edge.
        const plus_cx = plus_x + @divTrunc(plus_btn_size, 2);
        const plus_cy = plus_y + @divTrunc(plus_btn_size, 2);
        const plus_brush = c.CreateSolidBrush(pal.glyph_pen);
        var v_bar = c.RECT{
            .left = plus_cx - 1,
            .top = plus_y + plus_icon_inset - 1,
            .right = plus_cx + 1,
            .bottom = plus_y + plus_btn_size - plus_icon_inset + 1,
        };
        var h_bar = c.RECT{
            .left = plus_x + plus_icon_inset - 1,
            .top = plus_cy - 1,
            .right = plus_x + plus_btn_size - plus_icon_inset + 1,
            .bottom = plus_cy + 1,
        };
        _ = c.FillRect(hdc, &v_bar, plus_brush);
        _ = c.FillRect(hdc, &h_bar, plus_brush);
        _ = c.DeleteObject(plus_brush);
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
            const min_hover_brush = c.CreateSolidBrush(pal.wbtn_hover_bg);
            _ = c.FillRect(hdc, &btn_rect, min_hover_brush);
            _ = c.DeleteObject(min_hover_brush);
        }

        // Draw minimize icon (horizontal line)
        const min_icon_pen = c.CreatePen(c.PS_SOLID, wbtn_pen_width, pal.wbtn_icon);
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
            const max_hover_brush = c.CreateSolidBrush(pal.wbtn_hover_bg);
            _ = c.FillRect(hdc, &btn_rect, max_hover_brush);
            _ = c.DeleteObject(max_hover_brush);
        }

        // Draw maximize icon (rectangle)
        const max_icon_pen = c.CreatePen(c.PS_SOLID, wbtn_pen_width, pal.wbtn_icon);
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
            const close_hover_brush = c.CreateSolidBrush(pal.wbtn_close_hover_bg);
            _ = c.FillRect(hdc, &btn_rect, close_hover_brush);
            _ = c.DeleteObject(close_hover_brush);
        }

        // Draw X icon
        const close_icon_color = if (hovered_btn == 2) pal.wbtn_close_hover_icon else pal.wbtn_icon;
        const close_icon_pen = c.CreatePen(c.PS_SOLID, wbtn_pen_width, close_icon_color);
        const old_close_icon_pen = c.SelectObject(hdc, close_icon_pen);
        const close_icon_top = @divTrunc(bar_height - wbtn_icon_size, 2);
        // GDI LineTo excludes the endpoint pixel. Extend each LineTo target by one
        // step in the line direction so the visual diagonals fully cover the
        // wbtn_icon_size_px x wbtn_icon_size_px square symmetrically (otherwise
        // the bottom corners are clipped, making the bottom of the X look shorter).
        const x_left = btn_x + wbtn_icon_inset;
        const x_right_last = btn_x + wbtn_icon_inset + wbtn_icon_size - 1;
        const y_top = close_icon_top;
        const y_bottom_last = close_icon_top + wbtn_icon_size - 1;
        _ = c.MoveToEx(hdc, x_left, y_top, null);
        _ = c.LineTo(hdc, x_right_last + 1, y_bottom_last + 1);
        _ = c.MoveToEx(hdc, x_right_last, y_top, null);
        _ = c.LineTo(hdc, x_left - 1, y_bottom_last + 1);
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
                const indicator_pen = c.CreatePen(c.PS_SOLID, 2, pal.accent);
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

            // Draw floating tab tinted with the accent color (no transparency
            // in GDI; use the dragging-tab palette entry for a consistent feel).
            const float_brush = c.CreateSolidBrush(pal.tab_dragging);
            _ = c.FillRect(hdc, &float_rect, float_brush);
            _ = c.DeleteObject(float_brush);

            // Draw border for floating tab
            const border_pen = c.CreatePen(c.PS_SOLID, 1, pal.accent);
            const old_border_pen = c.SelectObject(hdc, border_pen);
            const float_null_brush = c.GetStockObject(c.NULL_BRUSH);
            const old_float_brush = c.SelectObject(hdc, float_null_brush);
            _ = c.Rectangle(hdc, float_rect.left, float_rect.top, float_rect.right, float_rect.bottom);
            _ = c.SelectObject(hdc, old_float_brush);
            _ = c.SelectObject(hdc, old_border_pen);
            _ = c.DeleteObject(border_pen);

            // Draw tab name on floating tab
            _ = c.SetTextColor(hdc, pal.text_selected);
            var float_text_rect = c.RECT{
                .left = float_x + tab_padding,
                .top = top_padding,
                .right = float_x + tab_width - tab_padding,
                .bottom = bar_height,
            };

            var float_display_name: [256]u8 = undefined;
            const float_display_len = extractTabDisplayName(tab, &float_display_name);

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
        app.mu.lockUncancelable(core.clock.io());
        defer app.mu.unlock(core.clock.io());

        app.tabline_state.clear();
        app.tabline_state.current_tab = curtab;
        app.tabline_state.visible = tab_count > 0;

        if (tabs) |t| {
            const count = @min(tab_count, 32); // Max 32 tabs
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

// AI-agent work state for a tab (from on_agent_status). Stored per handle;
// the spinner timer + paint (drawTablineContent) render the indicator. Fired
// on the core RPC thread, so update under app.mu then invalidate on the UI
// thread (the WM_APP_TABLINE_INVALIDATE handler also reconciles the timer).
//
// Low 7 bits of `state` = indicator state; bit 7 = "the reporter detected a
// completion edge, queue the OS notification now". Edge detection happens in
// the Lua reporter (per terminal buffer, which keeps its identity while
// hidden) rather than here (per tab, which does not) -- see the
// on_agent_status doc comment in zonvie_core.h.
pub fn onAgentStatus(ctx: ?*anyopaque, tab_handle: i64, state: u8, title: [*]const u8, title_len: usize) callconv(.c) void {
    const app: *App = @ptrCast(@alignCast(ctx.?));
    const base: u8 = state & 0x7f;
    {
        app.mu.lockUncancelable(core.clock.io());
        defer app.mu.unlock(core.clock.io());
        if (app.config.tabline.agent_notification and (state & 0x80) != 0) {
            app.tabline_state.pushCompleted(tab_handle, title[0..title_len], base == 4);
        }
        app.tabline_state.setAgentState(tab_handle, base);
    }
    if (app.hwnd) |main_hwnd| {
        _ = c.PostMessageW(main_hwnd, app_mod.WM_APP_TABLINE_INVALIDATE, 0, 0);
    }
}

pub fn onTablineHide(ctx: ?*anyopaque) callconv(.c) void {
    const app: *App = @ptrCast(@alignCast(ctx.?));
    if (applog.isEnabled()) applog.appLog("[win] on_tabline_hide\n", .{});

    app.mu.lockUncancelable(core.clock.io());
    app.tabline_state.visible = false;
    app.mu.unlock(core.clock.io());

    // Hide child window
    if (app.tabline_state.hwnd) |tabline_hwnd| {
        _ = c.ShowWindow(tabline_hwnd, c.SW_HIDE);
    }
}


// =========================================================================
// Sidebar mode rendering and mouse handling
// =========================================================================

/// Render sidebar to D3D11 texture via offscreen GDI bitmap.
pub fn renderSidebarToD3D(app: *App, width: u32, height: u32) void {
    if (app.renderer == null) return;
    if (width == 0 or height == 0) return;
    const screen_dc = c.GetDC(null);
    if (screen_dc == null) return;
    defer _ = c.ReleaseDC(null, screen_dc);

    const mem_dc = c.CreateCompatibleDC(screen_dc);
    if (mem_dc == null) return;
    defer _ = c.DeleteDC(mem_dc);

    var bmi: c.BITMAPINFO = std.mem.zeroes(c.BITMAPINFO);
    bmi.bmiHeader.biSize = @sizeOf(c.BITMAPINFOHEADER);
    bmi.bmiHeader.biWidth = @intCast(width);
    bmi.bmiHeader.biHeight = -@as(c.LONG, @intCast(height));
    bmi.bmiHeader.biPlanes = 1;
    bmi.bmiHeader.biBitCount = 32;
    bmi.bmiHeader.biCompression = c.BI_RGB;

    var pixels_ptr: ?*anyopaque = null;
    const dib = c.CreateDIBSection(mem_dc, &bmi, c.DIB_RGB_COLORS, &pixels_ptr, null, 0);
    if (dib == null or pixels_ptr == null) return;
    defer _ = c.DeleteObject(dib);

    const old_bmp = c.SelectObject(mem_dc, dib);
    defer _ = c.SelectObject(mem_dc, old_bmp);

    drawSidebarContent(app, mem_dc, @intCast(width), @intCast(height));

    // Set alpha to opaque
    const pixels: [*]u8 = @ptrCast(pixels_ptr);
    const pixel_count = width * height;
    var i: u32 = 0;
    while (i < pixel_count) : (i += 1) {
        pixels[i * 4 + 3] = 255;
    }

    const pixel_data = pixels[0 .. width * height * 4];
    if (app.renderer) |*g| {
        g.updateSidebarTexture(width, height, pixel_data) catch |e| {
            if (applog.isEnabled()) applog.appLog("[sidebar] updateSidebarTexture failed: {any}\n", .{e});
        };
    }
}

/// Compute sidebar colors from the Neovim colorscheme.
/// Returns (R, G, B) as 0-255 u8 values. Mirrors macOS TabSidebarView color logic (no blur).
const SidebarColors = struct {
    bg_r: u8,
    bg_g: u8,
    bg_b: u8,
    selected_r: u8,
    selected_g: u8,
    selected_b: u8,
    hover_r: u8,
    hover_g: u8,
    hover_b: u8,
    text_r: u8,
    text_g: u8,
    text_b: u8,
    text_sel_r: u8,
    text_sel_g: u8,
    text_sel_b: u8,
    sep_r: u8,
    sep_g: u8,
    sep_b: u8,
    close_r: u8,
    close_g: u8,
    close_b: u8,
    close_hi_r: u8,
    close_hi_g: u8,
    close_hi_b: u8,
    indicator_r: u8,
    indicator_g: u8,
    indicator_b: u8,

    fn compute(app: *const App) SidebarColors {
        // Extract colorscheme bg/fg as 0.0-1.0 floats
        var bgR: f32 = 0.145;
        var bgG: f32 = 0.149;
        var bgB: f32 = 0.161;
        var fgR: f32 = 1.0;
        var fgG: f32 = 1.0;
        var fgB: f32 = 1.0;

        if (app.colorscheme_bg != 0xFFFFFFFF) {
            bgR = @as(f32, @floatFromInt((app.colorscheme_bg >> 16) & 0xFF)) / 255.0;
            bgG = @as(f32, @floatFromInt((app.colorscheme_bg >> 8) & 0xFF)) / 255.0;
            bgB = @as(f32, @floatFromInt(app.colorscheme_bg & 0xFF)) / 255.0;
        }
        if (app.colorscheme_fg != 0xFFFFFFFF) {
            fgR = @as(f32, @floatFromInt((app.colorscheme_fg >> 16) & 0xFF)) / 255.0;
            fgG = @as(f32, @floatFromInt((app.colorscheme_fg >> 8) & 0xFF)) / 255.0;
            fgB = @as(f32, @floatFromInt(app.colorscheme_fg & 0xFF)) / 255.0;
        }

        const luminance = 0.299 * bgR + 0.587 * bgG + 0.114 * bgB;
        const is_dark = luminance < 0.5;

        // Sidebar background: slightly darker (dark theme) or lighter (light theme) than bg
        const sb_bgR = if (is_dark) bgR * 0.85 else @min(@as(f32, 1.0), bgR + 0.03);
        const sb_bgG = if (is_dark) bgG * 0.85 else @min(@as(f32, 1.0), bgG + 0.03);
        const sb_bgB = if (is_dark) bgB * 0.85 else @min(@as(f32, 1.0), bgB + 0.03);

        // Selected tab: brighter (dark) or darker (light) than bg
        const sel_R = if (is_dark) bgR + 0.06 else @max(@as(f32, 0.0), bgR - 0.06);
        const sel_G = if (is_dark) bgG + 0.06 else @max(@as(f32, 0.0), bgG - 0.06);
        const sel_B = if (is_dark) bgB + 0.06 else @max(@as(f32, 0.0), bgB - 0.06);

        // Hover tab: slightly brighter/darker
        const hov_R = if (is_dark) bgR + 0.03 else @max(@as(f32, 0.0), bgR - 0.03);
        const hov_G = if (is_dark) bgG + 0.03 else @max(@as(f32, 0.0), bgG - 0.03);
        const hov_B = if (is_dark) bgB + 0.03 else @max(@as(f32, 0.0), bgB - 0.03);

        // Text colors
        const dim = if (is_dark) @as(f32, 0.6) else @as(f32, 0.5);
        const txt_R = fgR * dim;
        const txt_G = fgG * dim;
        const txt_B = fgB * dim;

        // Separator: white 10% alpha on dark bg, black 10% alpha on light bg
        // For opaque GDI, blend with sidebar bg
        const sep_R = if (is_dark) sb_bgR * 0.9 + 1.0 * 0.1 else sb_bgR * 0.9;
        const sep_G = if (is_dark) sb_bgG * 0.9 + 1.0 * 0.1 else sb_bgG * 0.9;
        const sep_B = if (is_dark) sb_bgB * 0.9 + 1.0 * 0.1 else sb_bgB * 0.9;

        // Close button
        const close_R = fgR * 0.5;
        const close_G = fgG * 0.5;
        const close_B = fgB * 0.5;

        const close_hi_R = fgR * 0.8;
        const close_hi_G = fgG * 0.8;
        const close_hi_B = fgB * 0.8;

        // Selection indicator: use fg color as accent
        const ind_R = fgR * 0.7;
        const ind_G = fgG * 0.7;
        const ind_B = fgB * 0.7;

        return .{
            .bg_r = f2u8(sb_bgR),
            .bg_g = f2u8(sb_bgG),
            .bg_b = f2u8(sb_bgB),
            .selected_r = f2u8(sel_R),
            .selected_g = f2u8(sel_G),
            .selected_b = f2u8(sel_B),
            .hover_r = f2u8(hov_R),
            .hover_g = f2u8(hov_G),
            .hover_b = f2u8(hov_B),
            .text_r = f2u8(txt_R),
            .text_g = f2u8(txt_G),
            .text_b = f2u8(txt_B),
            .text_sel_r = f2u8(fgR),
            .text_sel_g = f2u8(fgG),
            .text_sel_b = f2u8(fgB),
            .sep_r = f2u8(sep_R),
            .sep_g = f2u8(sep_G),
            .sep_b = f2u8(sep_B),
            .close_r = f2u8(close_R),
            .close_g = f2u8(close_G),
            .close_b = f2u8(close_B),
            .close_hi_r = f2u8(close_hi_R),
            .close_hi_g = f2u8(close_hi_G),
            .close_hi_b = f2u8(close_hi_B),
            .indicator_r = f2u8(ind_R),
            .indicator_g = f2u8(ind_G),
            .indicator_b = f2u8(ind_B),
        };
    }

    fn f2u8(v: f32) u8 {
        const clamped = @max(@as(f32, 0.0), @min(@as(f32, 1.0), v));
        return @intFromFloat(clamped * 255.0);
    }
};

/// Draw sidebar content (vertical tab list) using GDI.
/// Colors are derived from the Neovim colorscheme (mirroring macOS TabSidebarView).
pub fn drawSidebarContent(app: *App, hdc: c.HDC, width: c_int, height: c_int) void {
    const row_h = app.scalePx(TablineState.SIDEBAR_ROW_HEIGHT);
    const padding = app.scalePx(TablineState.SIDEBAR_PADDING);
    const close_size = app.scalePx(TablineState.SIDEBAR_CLOSE_SIZE);
    const new_tab_h = app.scalePx(TablineState.SIDEBAR_NEW_TAB_HEIGHT);
    const sep_w = app.scalePx(TablineState.SIDEBAR_SEPARATOR_WIDTH);
    const indicator_w = app.scalePx(TablineState.SIDEBAR_INDICATOR_WIDTH);
    const close_inset = app.scalePx(3);

    // Compute colors from colorscheme
    const colors = SidebarColors.compute(app);

    // Background
    const bg_brush = c.CreateSolidBrush(c.RGB(colors.bg_r, colors.bg_g, colors.bg_b));
    defer _ = c.DeleteObject(bg_brush);
    var bg_rect = c.RECT{ .left = 0, .top = 0, .right = width, .bottom = height };
    _ = c.FillRect(hdc, &bg_rect, bg_brush);

    // Separator line on content-adjacent edge
    const sep_brush = c.CreateSolidBrush(c.RGB(colors.sep_r, colors.sep_g, colors.sep_b));
    defer _ = c.DeleteObject(sep_brush);
    var sep_rect: c.RECT = undefined;
    if (app.sidebar_position_right) {
        sep_rect = .{ .left = 0, .top = 0, .right = sep_w, .bottom = height };
    } else {
        sep_rect = .{ .left = width - sep_w, .top = 0, .right = width, .bottom = height };
    }
    _ = c.FillRect(hdc, &sep_rect, sep_brush);

    // Brushes for tab states
    const selected_brush = c.CreateSolidBrush(c.RGB(colors.selected_r, colors.selected_g, colors.selected_b));
    const hover_brush = c.CreateSolidBrush(c.RGB(colors.hover_r, colors.hover_g, colors.hover_b));
    const indicator_brush = c.CreateSolidBrush(c.RGB(colors.indicator_r, colors.indicator_g, colors.indicator_b));
    defer {
        _ = c.DeleteObject(selected_brush);
        _ = c.DeleteObject(hover_brush);
        _ = c.DeleteObject(indicator_brush);
    }

    // Font
    const font = c.CreateFontW(
        app.scalePx(-12),
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
        c.CLEARTYPE_QUALITY,
        c.DEFAULT_PITCH | c.FF_DONTCARE,
        null,
    );
    defer _ = c.DeleteObject(font);
    const old_font = c.SelectObject(hdc, font);
    defer _ = c.SelectObject(hdc, old_font);

    _ = c.SetBkMode(hdc, c.TRANSPARENT);

    // Determine if we're in an active internal drag (threshold exceeded)
    const is_internal_drag = app.tabline_state.dragging_tab != null and
        app.tabline_state.drop_target_index != null and
        !app.tabline_state.is_external_drag;

    var y: c_int = 0;
    for (0..app.tabline_state.tab_count) |i| {
        const tab = &app.tabline_state.tabs[i];
        const is_selected = tab.handle == app.tabline_state.current_tab;
        const is_hovered = app.tabline_state.hovered_tab == i;
        const is_being_dragged = is_internal_drag and app.tabline_state.dragging_tab == i;

        var row_rect = c.RECT{
            .left = 0,
            .top = y,
            .right = width - sep_w,
            .bottom = y + row_h,
        };

        // Row background
        if (is_being_dragged) {
            // Ghost appearance for the original position of the dragged tab
            _ = c.FillRect(hdc, &row_rect, indicator_brush);
        } else if (is_selected) {
            _ = c.FillRect(hdc, &row_rect, selected_brush);
        } else if (is_hovered) {
            _ = c.FillRect(hdc, &row_rect, hover_brush);
        }

        // Selection indicator bar
        if (is_selected and !is_being_dragged) {
            var ind_rect: c.RECT = undefined;
            if (app.sidebar_position_right) {
                ind_rect = .{ .left = sep_w, .top = y, .right = sep_w + indicator_w, .bottom = y + row_h };
            } else {
                ind_rect = .{ .left = 0, .top = y, .right = indicator_w, .bottom = y + row_h };
            }
            _ = c.FillRect(hdc, &ind_rect, indicator_brush);
        }

        // Tab name
        const text_color = if (is_selected)
            c.RGB(colors.text_sel_r, colors.text_sel_g, colors.text_sel_b)
        else
            c.RGB(colors.text_r, colors.text_g, colors.text_b);
        _ = c.SetTextColor(hdc, text_color);

        var display_name: [256]u8 = undefined;
        const display_len = extractTabDisplayName(tab, &display_name);

        var wide_buf: [256]u16 = undefined;
        const wide_len = std.unicode.utf8ToUtf16Le(&wide_buf, display_name[0..display_len]) catch 0;

        const text_left: c_int = if (is_selected) padding + indicator_w else padding;
        const close_space: c_int = if (is_selected or is_hovered) close_size + app.scalePx(8) else 0;
        var text_rect = c.RECT{
            .left = text_left,
            .top = y,
            .right = width - sep_w - padding - close_space,
            .bottom = y + row_h,
        };
        _ = c.DrawTextW(hdc, &wide_buf, @intCast(wide_len), &text_rect, c.DT_LEFT | c.DT_VCENTER | c.DT_SINGLELINE | c.DT_END_ELLIPSIS);

        // Close button (X) on selected or hovered tabs
        if ((is_selected or is_hovered) and !is_being_dragged) {
            const close_x = width - sep_w - close_size - app.scalePx(8);
            const close_y_pos = y + @divTrunc(row_h - close_size, 2);

            if (app.tabline_state.hovered_close == i) {
                const close_hover_brush = c.CreateSolidBrush(c.RGB(colors.hover_r, colors.hover_g, colors.hover_b));
                var close_rect = c.RECT{
                    .left = close_x,
                    .top = close_y_pos,
                    .right = close_x + close_size,
                    .bottom = close_y_pos + close_size,
                };
                _ = c.FillRect(hdc, &close_rect, close_hover_brush);
                _ = c.DeleteObject(close_hover_brush);
            }

            const close_color = if (app.tabline_state.hovered_close == i)
                c.RGB(colors.close_hi_r, colors.close_hi_g, colors.close_hi_b)
            else
                c.RGB(colors.close_r, colors.close_g, colors.close_b);
            const pen = c.CreatePen(c.PS_SOLID, 1, close_color);
            const old_pen = c.SelectObject(hdc, pen);
            _ = c.MoveToEx(hdc, close_x + close_inset, close_y_pos + close_inset, null);
            _ = c.LineTo(hdc, close_x + close_size - close_inset, close_y_pos + close_size - close_inset);
            _ = c.MoveToEx(hdc, close_x + close_size - close_inset, close_y_pos + close_inset, null);
            _ = c.LineTo(hdc, close_x + close_inset, close_y_pos + close_size - close_inset);
            _ = c.SelectObject(hdc, old_pen);
            _ = c.DeleteObject(pen);
        }

        y += row_h;
    }

    // New Tab button
    {
        const btn_rect_top = y;
        if (app.tabline_state.hovered_new_tab_btn) {
            var btn_rect = c.RECT{
                .left = 0,
                .top = btn_rect_top,
                .right = width - sep_w,
                .bottom = btn_rect_top + new_tab_h,
            };
            _ = c.FillRect(hdc, &btn_rect, hover_brush);
        }

        // "+" icon
        const icon_size = app.scalePx(16);
        const icon_x = padding;
        const icon_y = btn_rect_top + @divTrunc(new_tab_h - icon_size, 2);
        const icon_inset = app.scalePx(3);

        const new_tab_color = c.RGB(colors.close_r, colors.close_g, colors.close_b);
        const plus_pen = c.CreatePen(c.PS_SOLID, app.scalePx(1), new_tab_color);
        const old_plus_pen = c.SelectObject(hdc, plus_pen);
        _ = c.MoveToEx(hdc, icon_x + @divTrunc(icon_size, 2), icon_y + icon_inset, null);
        _ = c.LineTo(hdc, icon_x + @divTrunc(icon_size, 2), icon_y + icon_size - icon_inset);
        _ = c.MoveToEx(hdc, icon_x + icon_inset, icon_y + @divTrunc(icon_size, 2), null);
        _ = c.LineTo(hdc, icon_x + icon_size - icon_inset, icon_y + @divTrunc(icon_size, 2));
        _ = c.SelectObject(hdc, old_plus_pen);
        _ = c.DeleteObject(plus_pen);

        // "New Tab" text
        _ = c.SetTextColor(hdc, new_tab_color);
        const small_font = c.CreateFontW(
            app.scalePx(-11),
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
            c.CLEARTYPE_QUALITY,
            c.DEFAULT_PITCH | c.FF_DONTCARE,
            null,
        );
        const old_small_font = c.SelectObject(hdc, small_font);
        const new_tab_label: [:0]const u16 = std.unicode.utf8ToUtf16LeStringLiteral("New Tab");
        var nt_rect = c.RECT{
            .left = padding + icon_size + app.scalePx(6),
            .top = btn_rect_top,
            .right = width - sep_w - padding,
            .bottom = btn_rect_top + new_tab_h,
        };
        _ = c.DrawTextW(hdc, @ptrCast(new_tab_label.ptr), @intCast(new_tab_label.len), &nt_rect, c.DT_LEFT | c.DT_VCENTER | c.DT_SINGLELINE);
        _ = c.SelectObject(hdc, old_small_font);
        _ = c.DeleteObject(small_font);
    }

    // Draw drag visual feedback (drop indicator + floating tab) on top of everything
    if (is_internal_drag) {
        if (app.tabline_state.dragging_tab) |drag_idx| {
            if (app.tabline_state.drop_target_index) |target_idx| {
                // B) Drop indicator line
                if (target_idx != drag_idx and target_idx != drag_idx + 1) {
                    const ind_y: c_int = @as(c_int, @intCast(target_idx)) * row_h;
                    var ind_rect = c.RECT{
                        .left = 0,
                        .top = ind_y - 1,
                        .right = width - sep_w,
                        .bottom = ind_y + 1,
                    };
                    _ = c.FillRect(hdc, &ind_rect, indicator_brush);
                }

                // C) Floating tab row at drag position
                if (drag_idx < app.tabline_state.tab_count) {
                    const drag_tab = &app.tabline_state.tabs[drag_idx];
                    const float_y = app.tabline_state.drag_current_y - @divTrunc(row_h, 2);

                    // Floating row background (accent color approximation)
                    const float_brush = c.CreateSolidBrush(c.RGB(colors.indicator_r, colors.indicator_g, colors.indicator_b));
                    var float_rect = c.RECT{
                        .left = 2,
                        .top = float_y,
                        .right = width - sep_w - 2,
                        .bottom = float_y + row_h,
                    };
                    _ = c.FillRect(hdc, &float_rect, float_brush);
                    _ = c.DeleteObject(float_brush);

                    // Floating row border
                    const border_pen = c.CreatePen(c.PS_SOLID, 1, c.RGB(colors.indicator_r, colors.indicator_g, colors.indicator_b));
                    const old_border_pen = c.SelectObject(hdc, border_pen);
                    _ = c.MoveToEx(hdc, float_rect.left, float_rect.top, null);
                    _ = c.LineTo(hdc, float_rect.right, float_rect.top);
                    _ = c.LineTo(hdc, float_rect.right, float_rect.bottom);
                    _ = c.LineTo(hdc, float_rect.left, float_rect.bottom);
                    _ = c.LineTo(hdc, float_rect.left, float_rect.top);
                    _ = c.SelectObject(hdc, old_border_pen);
                    _ = c.DeleteObject(border_pen);

                    // Floating row tab name
                    _ = c.SetTextColor(hdc, c.RGB(colors.text_sel_r, colors.text_sel_g, colors.text_sel_b));

                    var float_display_name: [256]u8 = undefined;
                    const float_display_len = extractTabDisplayName(drag_tab, &float_display_name);

                    var float_wide_buf: [256]u16 = undefined;
                    const float_wide_len = std.unicode.utf8ToUtf16Le(&float_wide_buf, float_display_name[0..float_display_len]) catch 0;

                    var float_text_rect = c.RECT{
                        .left = padding + 2,
                        .top = float_y,
                        .right = width - sep_w - padding - 2,
                        .bottom = float_y + row_h,
                    };
                    _ = c.DrawTextW(hdc, &float_wide_buf, @intCast(float_wide_len), &float_text_rect, c.DT_LEFT | c.DT_VCENTER | c.DT_SINGLELINE | c.DT_END_ELLIPSIS);
                }
            }
        }
    }
}

/// Handle mouse down in sidebar area
pub fn handleSidebarMouseDown(app: *App, hwnd: c.HWND, x: c_int, y: c_int) void {
    const row_h = app.scalePx(TablineState.SIDEBAR_ROW_HEIGHT);
    const close_size = app.scalePx(TablineState.SIDEBAR_CLOSE_SIZE);
    const sep_w = app.scalePx(TablineState.SIDEBAR_SEPARATOR_WIDTH);
    const sidebar_w = app.scalePx(@as(c_int, @intCast(app.sidebar_width_px)));
    const new_tab_h = app.scalePx(TablineState.SIDEBAR_NEW_TAB_HEIGHT);

    if (row_h <= 0) return;

    const tab_idx: usize = @intCast(@divTrunc(@max(0, y), row_h));

    // Check new tab button
    const tabs_bottom: c_int = @intCast(@as(c_int, @intCast(app.tabline_state.tab_count)) * row_h);
    if (y >= tabs_bottom and y < tabs_bottom + new_tab_h) {
        app.tabline_state.new_tab_button_pressed = true;
        _ = c.SetCapture(hwnd);
        _ = c.InvalidateRect(hwnd, null, 0);
        return;
    }

    if (tab_idx >= app.tabline_state.tab_count) return;

    // Check close button
    const close_x_start = sidebar_w - sep_w - close_size - app.scalePx(8);
    const close_y_start = @as(c_int, @intCast(tab_idx)) * row_h + @divTrunc(row_h - close_size, 2);
    if (app.sidebar_position_right) {
        // Adjust for right sidebar coordinate space
    }

    const tab = &app.tabline_state.tabs[tab_idx];
    const is_selected = tab.handle == app.tabline_state.current_tab;
    const is_hovered = app.tabline_state.hovered_tab == tab_idx;

    // Close button hit test (for local_x within sidebar)
    var sb_local_x: c_int = undefined;
    if (app.sidebar_position_right) {
        var client_rect2: c.RECT = undefined;
        _ = c.GetClientRect(hwnd, &client_rect2);
        sb_local_x = x - (client_rect2.right - sidebar_w);
    } else {
        sb_local_x = x;
    }

    if ((is_selected or is_hovered) and
        sb_local_x >= close_x_start and sb_local_x < close_x_start + close_size and
        y >= close_y_start and y < close_y_start + close_size)
    {
        app.tabline_state.close_button_pressed = tab_idx;
        _ = c.SetCapture(hwnd);
        _ = c.InvalidateRect(hwnd, null, 0);
        return;
    }

    // Select tab and start drag tracking
    if (app.corep) |corep| {
        var cmd_buf: [32]u8 = undefined;
        const cmd = std.fmt.bufPrint(&cmd_buf, "{d}tabnext", .{tab_idx + 1}) catch return;
        app_mod.zonvie_core_send_command(corep, cmd.ptr, cmd.len);
    }

    app.tabline_state.dragging_tab = tab_idx;
    app.tabline_state.drag_start_x = x;
    app.tabline_state.drag_current_x = x;
    app.tabline_state.drag_start_y = y;
    app.tabline_state.drag_current_y = y;
    app.tabline_state.drop_target_index = null;
    app.tabline_state.is_external_drag = false;
    _ = c.SetCapture(hwnd);
}

/// Handle mouse up in sidebar area
pub fn handleSidebarMouseUp(app: *App, hwnd: c.HWND, x: c_int, y: c_int) void {
    // Handle close button release
    if (app.tabline_state.close_button_pressed) |pressed_tab_idx| {
        app.tabline_state.close_button_pressed = null;
        _ = c.ReleaseCapture();

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
    if (app.tabline_state.new_tab_button_pressed) {
        app.tabline_state.new_tab_button_pressed = false;
        _ = c.ReleaseCapture();

        if (app.corep) |corep| {
            const cmd = "tabnew";
            app_mod.zonvie_core_send_command(corep, cmd.ptr, cmd.len);
        }
        _ = c.InvalidateRect(hwnd, null, 0);
        return;
    }

    // Handle drag end
    const was_external_drag = app.tabline_state.is_external_drag;
    const drag_idx_opt = app.tabline_state.dragging_tab;
    const drop_target_opt = app.tabline_state.drop_target_index;
    const drag_start_y_saved = app.tabline_state.drag_start_y;

    app.tabline_state.cancelDrag();
    destroyDragPreviewWindow(app);
    _ = c.ReleaseCapture();

    if (drag_idx_opt) |drag_idx| {
        if (was_external_drag) {
            var screen_pt: c.POINT = .{ .x = x, .y = y };
            _ = c.ClientToScreen(hwnd, &screen_pt);
            externalizeTab(app, drag_idx, screen_pt.x, screen_pt.y);
        } else {
            // Internal reorder
            const dy = if (y > drag_start_y_saved)
                y - drag_start_y_saved
            else
                drag_start_y_saved - y;
            const drag_threshold = app.scalePx(TablineState.DRAG_THRESHOLD);

            if (dy > drag_threshold) {
                if (drop_target_opt) |to_idx| {
                    if (to_idx != drag_idx and to_idx != drag_idx + 1) {
                        const new_pos = calculateTabMovePosition(to_idx, app.tabline_state.tab_count);

                        if (app.corep) |corep| {
                            var cmd_buf: [32]u8 = undefined;
                            const cmd = std.fmt.bufPrint(&cmd_buf, "tabmove {d}", .{new_pos}) catch {
                                _ = c.InvalidateRect(hwnd, null, 0);
                                return;
                            };
                            app_mod.zonvie_core_send_command(corep, cmd.ptr, cmd.len);
                        }
                    }
                }
            }
        }
    }
    _ = c.InvalidateRect(hwnd, null, 0);
}

/// Handle mouse move in sidebar area
pub fn handleSidebarMouseMove(app: *App, hwnd: c.HWND, x: c_int, y: c_int) void {
    // Track mouse leave
    var tme: c.TRACKMOUSEEVENT = .{
        .cbSize = @sizeOf(c.TRACKMOUSEEVENT),
        .dwFlags = c.TME_LEAVE,
        .hwndTrack = hwnd,
        .dwHoverTime = 0,
    };
    _ = c.TrackMouseEvent(&tme);

    const row_h = app.scalePx(TablineState.SIDEBAR_ROW_HEIGHT);
    const close_size = app.scalePx(TablineState.SIDEBAR_CLOSE_SIZE);
    const sep_w = app.scalePx(TablineState.SIDEBAR_SEPARATOR_WIDTH);
    const sidebar_w = app.scalePx(@as(c_int, @intCast(app.sidebar_width_px)));
    const new_tab_h = app.scalePx(TablineState.SIDEBAR_NEW_TAB_HEIGHT);
    // External drag threshold: do NOT DPI-scale. This is a mouse movement distance
    // threshold, which should be constant in physical pixels regardless of DPI.
    // macOS uses 50 points (always unscaled), so we match that behavior.
    const ext_drag_threshold: c_int = TablineState.EXTERNAL_DRAG_THRESHOLD;

    // Handle close button pressed state - cancel if mouse leaves the button
    if (app.tabline_state.close_button_pressed) |pressed_tab_idx| {
        if (row_h > 0 and pressed_tab_idx < app.tabline_state.tab_count) {
            const close_x_start = sidebar_w - sep_w - close_size - app.scalePx(8);
            const close_y_start = @as(c_int, @intCast(pressed_tab_idx)) * row_h + @divTrunc(row_h - close_size, 2);

            var sb_x = x;
            if (app.sidebar_position_right) {
                var client_rect: c.RECT = undefined;
                _ = c.GetClientRect(hwnd, &client_rect);
                sb_x = x - (client_rect.right - sidebar_w);
            }

            const is_still_over_close = (sb_x >= close_x_start and sb_x < close_x_start + close_size and
                y >= close_y_start and y < close_y_start + close_size);

            if (!is_still_over_close) {
                app.tabline_state.close_button_pressed = null;
                _ = c.ReleaseCapture();
                _ = c.InvalidateRect(hwnd, null, 0);
            }
        }
        return;
    }

    // Handle new tab button pressed state - cancel if mouse leaves the button
    if (app.tabline_state.new_tab_button_pressed) {
        const tabs_bottom: c_int = @as(c_int, @intCast(app.tabline_state.tab_count)) * row_h;
        var sb_x = x;
        if (app.sidebar_position_right) {
            var client_rect: c.RECT = undefined;
            _ = c.GetClientRect(hwnd, &client_rect);
            sb_x = x - (client_rect.right - sidebar_w);
        }

        const is_still_over_new_tab = (sb_x >= 0 and sb_x < sidebar_w - sep_w and
            y >= tabs_bottom and y < tabs_bottom + new_tab_h);

        if (!is_still_over_new_tab) {
            app.tabline_state.new_tab_button_pressed = false;
            _ = c.ReleaseCapture();
            _ = c.InvalidateRect(hwnd, null, 0);
        }
        return;
    }

    // Handle dragging (external drag detection + internal reorder)
    if (app.tabline_state.dragging_tab != null) {
        app.tabline_state.drag_current_x = x;
        app.tabline_state.drag_current_y = y;

        // Check if mouse is outside sidebar bounds (for external drag)
        if (app.hwnd) |main_hwnd| {
            var client_rect: c.RECT = undefined;
            if (c.GetClientRect(main_hwnd, &client_rect) != 0) {
                var screen_pt: c.POINT = .{ .x = x, .y = y };
                _ = c.ClientToScreen(hwnd, &screen_pt);

                // Get client area origin in screen coordinates
                var client_origin: c.POINT = .{ .x = 0, .y = 0 };
                _ = c.ClientToScreen(main_hwnd, &client_origin);

                // Compute sidebar rect in screen coordinates (from client area, not window frame)
                var sidebar_rect: c.RECT = undefined;
                if (app.sidebar_position_right) {
                    sidebar_rect = .{
                        .left = client_origin.x + client_rect.right - sidebar_w,
                        .top = client_origin.y,
                        .right = client_origin.x + client_rect.right,
                        .bottom = client_origin.y + client_rect.bottom,
                    };
                } else {
                    sidebar_rect = .{
                        .left = client_origin.x,
                        .top = client_origin.y,
                        .right = client_origin.x + sidebar_w,
                        .bottom = client_origin.y + client_rect.bottom,
                    };
                }

                const threshold = ext_drag_threshold;
                const is_outside = (screen_pt.x < sidebar_rect.left - threshold or
                    screen_pt.x > sidebar_rect.right + threshold or
                    screen_pt.y < sidebar_rect.top - threshold or
                    screen_pt.y > sidebar_rect.bottom + threshold);

                if (applog.isEnabled()) {
                    applog.appLog(
                        "[sidebar-drag] screen=({d},{d}) sidebar=({d},{d},{d},{d}) threshold={d} outside={d} client_x={d} sidebar_w={d}\n",
                        .{
                            screen_pt.x,        screen_pt.y,
                            sidebar_rect.left,  sidebar_rect.top,
                            sidebar_rect.right, sidebar_rect.bottom,
                            threshold,          @as(i32, @intFromBool(is_outside)),
                            x,                  sidebar_w,
                        },
                    );
                }

                if (is_outside and !app.tabline_state.is_external_drag) {
                    app.tabline_state.is_external_drag = true;
                    app.tabline_state.drop_target_index = null;
                    createDragPreviewWindow(app, app.tabline_state.dragging_tab.?, screen_pt.x, screen_pt.y);
                } else if (!is_outside and app.tabline_state.is_external_drag) {
                    app.tabline_state.is_external_drag = false;
                    destroyDragPreviewWindow(app);
                }

                if (app.tabline_state.is_external_drag) {
                    updateDragPreviewPosition(app, screen_pt.x, screen_pt.y);
                } else {
                    // Internal reorder: calculate drop target from Y position
                    const dy = if (y > app.tabline_state.drag_start_y)
                        y - app.tabline_state.drag_start_y
                    else
                        app.tabline_state.drag_start_y - y;

                    if (dy > app.scalePx(TablineState.DRAG_THRESHOLD)) {
                        app.tabline_state.drop_target_index = calculateDropTarget(y, app.tabline_state.tab_count, row_h);
                    }
                }
            }
        }

        // Clear hover states during drag
        app.tabline_state.hovered_tab = null;
        app.tabline_state.hovered_close = null;
        app.tabline_state.hovered_new_tab_btn = false;
        _ = c.InvalidateRect(hwnd, null, 0);
        return;
    }

    if (row_h <= 0) return;

    // Local x within sidebar
    var sb_local_x: c_int = undefined;
    if (app.sidebar_position_right) {
        var client_rect: c.RECT = undefined;
        _ = c.GetClientRect(hwnd, &client_rect);
        sb_local_x = x - (client_rect.right - sidebar_w);
    } else {
        sb_local_x = x;
    }

    const tab_idx: usize = @intCast(@divTrunc(@max(0, y), row_h));

    // Check new tab button hover
    const tabs_bottom: c_int = @intCast(@as(c_int, @intCast(app.tabline_state.tab_count)) * row_h);
    const new_hovered_new_tab = y >= tabs_bottom and y < tabs_bottom + new_tab_h;

    var new_hovered_tab: ?usize = null;
    var new_hovered_close: ?usize = null;

    if (tab_idx < app.tabline_state.tab_count and !new_hovered_new_tab) {
        new_hovered_tab = tab_idx;

        // Check close button hover
        const tab = &app.tabline_state.tabs[tab_idx];
        const is_selected = tab.handle == app.tabline_state.current_tab;
        if (is_selected or app.tabline_state.hovered_tab == tab_idx) {
            const close_x_start = sidebar_w - sep_w - close_size - app.scalePx(8);
            const close_y_start = @as(c_int, @intCast(tab_idx)) * row_h + @divTrunc(row_h - close_size, 2);

            if (sb_local_x >= close_x_start and sb_local_x < close_x_start + close_size and
                y >= close_y_start and y < close_y_start + close_size)
            {
                new_hovered_close = tab_idx;
            }
        }
    }

    var needs_repaint = false;
    if (app.tabline_state.hovered_tab != new_hovered_tab) {
        app.tabline_state.hovered_tab = new_hovered_tab;
        needs_repaint = true;
    }
    if (app.tabline_state.hovered_close != new_hovered_close) {
        app.tabline_state.hovered_close = new_hovered_close;
        needs_repaint = true;
    }
    if (app.tabline_state.hovered_new_tab_btn != new_hovered_new_tab) {
        app.tabline_state.hovered_new_tab_btn = new_hovered_new_tab;
        needs_repaint = true;
    }

    if (needs_repaint) {
        _ = c.InvalidateRect(hwnd, null, 0);
    }
}
