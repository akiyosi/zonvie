const std = @import("std");
const app_mod = @import("../app.zig");
const App = app_mod.App;
const c = app_mod.c;
const applog = app_mod.applog;
const d3d11 = app_mod.d3d11;
const dwrite_d2d = app_mod.dwrite_d2d;
const core = @import("zonvie_core");
const window_mod = @import("../window.zig");
const input = @import("../input.zig");
const sidebar_caption = @import("sidebar_caption.zig");
const TablineState = app_mod.TablineState;
const TabEntry = app_mod.TabEntry;

/// Face for every tab label. A null face let GDI pick the system bitmap font,
/// whose one-pixel period abuts a following `z`'s bottom stroke, so
/// "flush.zig" read as "flushzig". Japanese text falls back through font
/// linking.
const tab_font_face = std.unicode.utf8ToUtf16LeStringLiteral("Segoe UI");

/// The tab label font at `height_pt` (negative: character height), DPI-scaled.
pub fn createTabFont(app: *App, height_pt: c_int) c.HFONT {
    return createStyledTabFont(app, height_pt, 0);
}

/// createTabFont in a 'guitablabel' chunk's style (ZONVIE_TAB_CHUNK_* bits).
fn createStyledTabFont(app: *App, height_pt: c_int, flags: u32) c.HFONT {
    const hl = core.highlight;
    return c.CreateFontW(
        app.scalePx(height_pt),
        0,
        0,
        0,
        if (flags & hl.TAB_CHUNK_BOLD != 0) c.FW_BOLD else c.FW_NORMAL,
        @intFromBool(flags & hl.TAB_CHUNK_ITALIC != 0),
        @intFromBool(flags & hl.TAB_CHUNK_UNDERLINE != 0),
        @intFromBool(flags & hl.TAB_CHUNK_STRIKETHROUGH != 0),
        c.DEFAULT_CHARSET,
        c.OUT_DEFAULT_PRECIS,
        c.CLIP_DEFAULT_PRECIS,
        c.CLEARTYPE_QUALITY,
        c.DEFAULT_PITCH | c.FF_DONTCARE,
        tab_font_face,
    );
}

// ---- Shared helpers for titlebar and sidebar tab operations ----

/// Extract the display name (basename) from a tab entry.
/// Returns the length of the display name written to out_buf.
fn extractTabDisplayName(tab: *const TabEntry, out_buf: *[256]u8) usize {
    const display = app_mod.baseName(tab.name[0..tab.name_len]);
    if (display.len > 0) {
        @memcpy(out_buf[0..display.len], display);
        return display.len;
    } else {
        const no_name = "[No Name]";
        @memcpy(out_buf[0..no_name.len], no_name);
        return no_name.len;
    }
}

/// Draw a tab's display name into `rect`: one line, vertically centred,
/// ellipsised; `h_align` is DT_LEFT or DT_CENTER. The text colour is the
/// caller's. A name is at most 255 bytes, so at most 255 UTF-16 units.
fn drawTabLabel(hdc: c.HDC, name: []const u8, rect: *c.RECT, h_align: c.UINT) void {
    var wide_buf: [256]u16 = undefined;
    const wide_len = std.unicode.utf8ToUtf16Le(&wide_buf, name) catch 0;
    _ = c.DrawTextW(hdc, &wide_buf, @intCast(wide_len), rect, h_align | c.DT_VCENTER | c.DT_SINGLELINE | c.DT_END_ELLIPSIS);
}

/// The fonts of one paint's 'guitablabel' runs, created on first use: line 1
/// at the tab font's size, lines 2+ one point smaller (as the sidebar), by
/// the style bits. deinit must run while none of them is selected.
const LabelFonts = struct {
    const STYLE_BITS = core.highlight.TAB_CHUNK_BOLD | core.highlight.TAB_CHUNK_ITALIC |
        core.highlight.TAB_CHUNK_UNDERLINE | core.highlight.TAB_CHUNK_STRIKETHROUGH;
    const STYLE_SHIFT = 2; // TAB_CHUNK_BOLD is the lowest style bit

    fonts: [2][16]?c.HFONT = [_][16]?c.HFONT{[_]?c.HFONT{null} ** 16} ** 2,

    fn get(self: *LabelFonts, app: *App, line: u8, flags: u32) c.HFONT {
        const size: usize = @intFromBool(line > 0);
        const style: usize = (flags & STYLE_BITS) >> STYLE_SHIFT;
        if (self.fonts[size][style]) |f| return f;
        const f = createStyledTabFont(app, if (size == 0) -12 else -11, flags & STYLE_BITS);
        self.fonts[size][style] = f;
        return f;
    }

    fn deinit(self: *LabelFonts) void {
        for (self.fonts) |row| {
            for (row) |f| {
                if (f) |font| _ = c.DeleteObject(font);
            }
        }
    }
};

/// Draw line `line` of a 'guitablabel' label into `rect`, verbatim, run by
/// run in each chunk's fg (else `default_fg`) and style, vertically centred;
/// the run reaching the right edge ends the line with an ellipsis. Chunk bg
/// is never painted. Leaves `base_font` selected.
fn drawLabelLine(app: *App, hdc: c.HDC, fonts: *LabelFonts, base_font: c.HFONT, label: *const app_mod.TabLabel, line: u8, rect: c.RECT, default_fg: c.COLORREF) void {
    defer _ = c.SelectObject(hdc, base_font);
    var x = rect.left;
    for (label.runs[0..label.run_count]) |run| {
        if (run.line != line) continue;
        if (x >= rect.right) break;
        // A run is at most LINE_BYTES bytes, so at most as many UTF-16 units.
        var wide: [app_mod.TabLabel.LINE_BYTES]u16 = undefined;
        const n = std.unicode.utf8ToUtf16Le(&wide, label.runText(run)) catch continue;
        if (n == 0) continue;
        _ = c.SelectObject(hdc, fonts.get(app, line, run.flags));
        _ = c.SetTextColor(hdc, if (run.flags & core.highlight.TAB_CHUNK_HAS_FG != 0) c.RGB(
            @as(u8, @intCast((run.fg_rgb >> 16) & 0xFF)),
            @as(u8, @intCast((run.fg_rgb >> 8) & 0xFF)),
            @as(u8, @intCast(run.fg_rgb & 0xFF)),
        ) else default_fg);
        var size: c.SIZE = undefined;
        if (c.GetTextExtentPoint32W(hdc, &wide, @intCast(n), &size) == 0) size.cx = 0;
        var r = c.RECT{ .left = x, .top = rect.top, .right = rect.right, .bottom = rect.bottom };
        _ = c.DrawTextW(hdc, &wide, @intCast(n), &r, c.DT_LEFT | c.DT_VCENTER | c.DT_SINGLELINE | c.DT_END_ELLIPSIS | c.DT_NOPREFIX);
        x += size.cx;
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

/// The AI-agent indicator for `a_state` in a fixed cell of `ind_px` at `x`,
/// centred in [top, bottom); the colour 🤖 is placed at `emoji_y` (AlphaBlend,
/// since GDI DrawTextW cannot render colour emoji).
fn drawAgentIndicator(app: *App, hdc: c.HDC, a_state: u8, x: c_int, top: c_int, bottom: c_int, emoji_y: c_int, ind_px: c_int) void {
    if (a_state == 1) {
        if (if (ind_px > 0) ensureAgentEmoji(app, ind_px) else null) |hbm| {
            blendAgentEmoji(hdc, hbm, x, emoji_y, ind_px);
        } else {
            drawIndicatorGlyph(hdc, "●", x, ind_px, top, bottom);
        }
    } else if (a_state == 4) {
        // Waiting for user input -> pause glyph (two bars).
        drawPauseGlyph(hdc, x, ind_px, top, bottom);
    } else {
        drawIndicatorGlyph(hdc, agentSpinnerGlyph(a_state, app.tabline_state.spinner_frame), x, ind_px, top, bottom);
    }
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

/// frontend_rules.tabDropIndex in pixels: x on the titlebar, y down the sidebar.
fn calculateDropTarget(mouse_pos: c_int, item_count: usize, origin: c_int, stride: c_int, item_size: c_int) usize {
    return core.frontend_rules.tabDropIndex(@floatFromInt(mouse_pos), @intCast(item_count), @floatFromInt(origin), @floatFromInt(stride), @floatFromInt(item_size));
}

// Content child window for D3D11 rendering (when ext_tabline enabled)

/// Width of one tab for a given client width and tab count. Every drawing and
/// hit-testing path must agree on this; it used to be spelled out at each
/// site, including one copy in window.zig's WM_NCHITTEST.
///
/// tab_count <= 0 returns 0. The inline copies divided without that guard and
/// were safe only because their callers checked first.
pub fn tabWidthPx(app: *App, client_width: c_int, tab_count: c_int) c_int {
    const available = client_width -
        app.scalePx(TablineState.WINDOW_CONTROLS_WIDTH) -
        app.scalePx(40) -
        app.scalePx(TablineState.WINDOW_BTNS_TOTAL);
    return core.frontend_rules.titlebarTabWidth(
        available,
        tab_count,
        app.scalePx(TablineState.TAB_MIN_WIDTH),
        app.scalePx(TablineState.TAB_MAX_WIDTH),
    );
}

/// Height of the titlebar tab bar: a label line taller per extra
/// 'guitablabel' line. The caption buttons keep the top TAB_BAR_HEIGHT.
pub fn titlebarBarPx(app: *const App) c_int {
    return app_mod.titlebarBarHeightPx(app.scalePx(TablineState.TAB_BAR_HEIGHT), labelLinePx(app), app.tabline_state.bar_lines);
}

fn labelLinePx(app: *const App) c_int {
    return app.scalePx(TablineState.TAB_LABEL_LINE_HEIGHT);
}

/// UI thread, after a tabline change: grow or shrink the titlebar bar to the
/// labels' line count, moving the grid top as a window resize does (outside
/// app.mu: the core can re-enter through callbacks). One layout per change
/// of the count, none otherwise.
pub fn syncTitlebarLines(hwnd: c.HWND, app: *App) void {
    if (sidebar_caption.layout(app).tabline != .titlebar) return;
    app.mu.lockUncancelable(core.clock.io());
    const changed = app.tabline_state.syncBarLines();
    app.mu.unlock(core.clock.io());
    if (!changed) return;
    app_mod.updateLayoutToCore(hwnd, app);
    // The grid moved: redraw everything, as the sidebar toggle does, and
    // move message boxes anchored to the window or grid off the grown bar.
    app_mod.requestMainFullPaint(app);
    app_mod.scheduleFloatReposition(app);
}

/// Left edge of the + button, which sits one gap past the last tab.
pub fn plusButtonXPx(app: *App, tab_count: c_int, tab_width: c_int) c_int {
    return app.scalePx(TablineState.WINDOW_CONTROLS_WIDTH) +
        tab_count * (tab_width + 1) + app.scalePx(8);
}

/// Width of the + button, and its height at one label line. Both the painted
/// shape and every hit test use this.
pub fn plusButtonSizePx(app: *App) c_int {
    return app.scalePx(20);
}

/// Height of the + button: one line's square stretched downward by the
/// titlebar bar's extra label lines, so it spans the tabs' height.
pub fn plusButtonHeightPx(app: *App) c_int {
    return plusButtonSizePx(app) + titlebarBarPx(app) - app.scalePx(TablineState.TAB_BAR_HEIGHT);
}

/// What a titlebar-tabline point is on. Hover, press, the pressed-button
/// tracking and WM_NCHITTEST each wrote this geometry out themselves; the
/// + button's press alone ignored its vertical extent.
pub const TablineHit = union(enum) {
    none,
    window_button: u8, // 0 min, 1 max, 2 close
    tab: usize,
    close: usize, // a tab's close button
    new_tab,
};

fn tabLeftPx(app: *App, tab_width: c_int, idx: usize) c_int {
    return app.scalePx(TablineState.WINDOW_CONTROLS_WIDTH) + @as(c_int, @intCast(idx)) * (tab_width + 1);
}

fn inRect(x: c_int, y: c_int, left: c_int, top: c_int, w: c_int, h: c_int) bool {
    return x >= left and x < left + w and y >= top and y < top + h;
}

/// `tab_count` is passed so WM_NCHITTEST can read it under app.mu.
/// Tabs span the whole bar; the window, close and + buttons sit in its
/// one-line band at the top, and the strip under the window buttons is empty
/// bar (it drags the window).
pub fn tablineHitTest(app: *App, client_width: c_int, tab_count: usize, x: c_int, y: c_int) TablineHit {
    const bar_height = titlebarBarPx(app);
    const band_height = app.scalePx(TablineState.TAB_BAR_HEIGHT);
    if (y < 0 or y >= bar_height) return .none;

    const btn_start_x = client_width - app.scalePx(TablineState.WINDOW_BTNS_TOTAL);
    if (x >= btn_start_x) {
        if (y >= band_height) return .none;
        const idx = @divTrunc(x - btn_start_x, app.scalePx(TablineState.WINDOW_BTN_WIDTH));
        return if (idx >= 0 and idx < 3) .{ .window_button = @intCast(idx) } else .none;
    }
    if (tab_count == 0) return .none;

    const count: c_int = @intCast(tab_count);
    const tab_width = tabWidthPx(app, client_width, count);
    const close_size = app.scalePx(TablineState.TAB_CLOSE_SIZE);
    for (0..tab_count) |i| {
        const tab_x = tabLeftPx(app, tab_width, i);
        if (x < tab_x or x >= tab_x + tab_width) continue;
        const close_x = tab_x + tab_width - close_size - app.scalePx(6);
        const close_y = @divTrunc(band_height - close_size, 2);
        return if (inRect(x, y, close_x, close_y, close_size, close_size)) .{ .close = i } else .{ .tab = i };
    }
    const plus_size = plusButtonSizePx(app);
    if (inRect(x, y, plusButtonXPx(app, count, tab_width), @divTrunc(band_height - plus_size, 2), plus_size, plusButtonHeightPx(app))) return .new_tab;
    return .none;
}

/// What a sidebar point is on. `x`, `y` are main-window client pixels; the
/// close button's rectangle is the one drawSidebarContent draws.
pub fn sidebarHitTest(app: *App, hwnd: c.HWND, tab_count: usize, x: c_int, y: c_int) TablineHit {
    const row_h = app.scalePx(TablineState.SIDEBAR_ROW_HEIGHT);
    if (row_h <= 0 or y < 0) return .none;
    const tabs_bottom = @as(c_int, @intCast(tab_count)) * row_h;
    if (y >= tabs_bottom) {
        return if (y < tabs_bottom + app.scalePx(TablineState.SIDEBAR_NEW_TAB_HEIGHT)) .new_tab else .none;
    }
    const idx: usize = @intCast(@divTrunc(y, row_h));
    const close_size = app.scalePx(TablineState.SIDEBAR_CLOSE_SIZE);
    const close_x = app.scalePx(@as(c_int, @intCast(app.sidebar_width_px))) - app.scalePx(TablineState.SIDEBAR_SEPARATOR_WIDTH) - close_size - app.scalePx(8);
    const close_y = @as(c_int, @intCast(idx)) * row_h + @divTrunc(row_h - close_size, 2);
    const local_x = x - sidebarRectPx(app, hwnd).left;
    return if (inRect(local_x, y, close_x, close_y, close_size, close_size)) .{ .close = idx } else .{ .tab = idx };
}

/// Whether a tab press that travelled `moved_px` along the strip's axis is a
/// drag, as drawTablineContent has always judged it. The sidebar treated a
/// travel of exactly the threshold as a click while the titlebar reordered.
pub fn tabDragPastThreshold(moved_px: c_int, threshold_px: c_int) bool {
    return moved_px >= threshold_px;
}

test "tab drag threshold: reaching it is a drag, one pixel short is a click" {
    try std.testing.expect(!tabDragPastThreshold(4, 5));
    try std.testing.expect(tabDragPastThreshold(5, 5));
    try std.testing.expect(tabDragPastThreshold(6, 5));
}

fn absDelta(a: c_int, b: c_int) c_int {
    return if (a > b) a - b else b - a;
}

/// Where the dragged tab is now, or null when no drag is on or it closed.
fn draggedTabIndexNow(st: *const TablineState) ?usize {
    if (st.dragging_tab == null) return null;
    return st.indexOfHandle(st.dragging_tab_handle);
}

/// End a tab press on the titlebar or the sidebar at client (x, y), the
/// pointer having travelled `moved_px` along the strip's axis: snapshot the
/// drag before ReleaseCapture (WM_CAPTURECHANGED clears it synchronously),
/// then externalize, reorder, or leave the click the press already selected.
fn finishTabDrag(app: *App, hwnd: c.HWND, x: c_int, y: c_int, moved_px: c_int) void {
    const st = &app.tabline_state;
    const drag_idx_opt = draggedTabIndexNow(st);
    const was_dragging = st.dragging_tab != null;
    const drop_target_opt = st.drop_target_index;
    const was_external_drag = st.is_external_drag;

    st.cancelDrag();
    destroyDragPreviewWindow(app);
    _ = c.ReleaseCapture();

    if (drag_idx_opt) |drag_idx| {
        if (was_external_drag) {
            var screen_pt: c.POINT = .{ .x = x, .y = y };
            _ = c.ClientToScreen(hwnd, &screen_pt);
            if (applog.isEnabled()) applog.appLog("[tabline] mouseUp: externalizing tab {d} at screen ({d},{d})\n", .{ drag_idx, screen_pt.x, screen_pt.y });
            externalizeTab(app, drag_idx, screen_pt.x, screen_pt.y);
        } else if (tabDragPastThreshold(moved_px, app.scalePx(TablineState.DRAG_THRESHOLD))) {
            // The core's command selects the dragged tab and moves it in one
            // go: the press selected it, but a tab switch landing before a
            // bare `:tabmove` moved another tab. Nothing is sent for a drop
            // onto its own slot.
            if (drop_target_opt) |to_idx| {
                if (applog.isEnabled()) applog.appLog("[tabline] mouseUp: from_idx={d} to_idx={d} tab_count={d}\n", .{ drag_idx, to_idx, st.tab_count });
                if (app.corep) |corep| {
                    _ = core.zonvie_core_tab_move(corep, @intCast(drag_idx), @intCast(to_idx), @intCast(st.tab_count));
                }
            }
        }
    }
    // A dragged tab that closed mid-drag repaints too: nothing to move.
    if (was_dragging) _ = c.InvalidateRect(hwnd, null, 0);
}

/// The release of a pressed close or new-tab button, for the titlebar and the
/// sidebar. A press still set means the pointer stayed on the button: moving
/// off it cancels the press. True when the release was consumed.
fn releaseTabButton(app: *App, hwnd: c.HWND) bool {
    if (app.tabline_state.close_button_pressed != null) {
        app.tabline_state.close_button_pressed = null;
        _ = c.ReleaseCapture();
        if (app.tabline_state.indexOfHandle(app.tabline_state.close_button_pressed_handle)) |idx| {
            if (applog.isEnabled()) applog.appLog("[tabline] mouseUp: close button released on tab {d}, closing\n", .{idx});
            if (app.corep) |corep| {
                var cmd_buf: [32]u8 = undefined;
                const cmd = std.fmt.bufPrint(&cmd_buf, "{d}tabclose", .{idx + 1}) catch return true;
                app_mod.zonvie_core_send_command(corep, cmd.ptr, cmd.len);
            }
        }
        _ = c.InvalidateRect(hwnd, null, 0);
        return true;
    }
    if (app.tabline_state.new_tab_button_pressed) {
        app.tabline_state.new_tab_button_pressed = false;
        _ = c.ReleaseCapture();
        if (applog.isEnabled()) applog.appLog("[tabline] mouseUp: new tab button released, creating new tab\n", .{});
        if (app.corep) |corep| {
            const cmd = "tabnew";
            app_mod.zonvie_core_send_command(corep, cmd.ptr, cmd.len);
        }
        _ = c.InvalidateRect(hwnd, null, 0);
        return true;
    }
    return false;
}

/// Enter or leave external-drag mode as a dragged tab at client (x, y) leaves
/// or re-enters `strip` (client pixels, the titlebar band or the sidebar)
/// expanded by EXTERNAL_DRAG_THRESHOLD, and move the preview with it. The
/// threshold is physical pixels, not DPI-scaled, as macOS's 50pt.
fn trackExternalDrag(app: *App, hwnd: c.HWND, strip: c.RECT, x: c_int, y: c_int) void {
    const t: c_int = TablineState.EXTERNAL_DRAG_THRESHOLD;
    const outside = x < strip.left - t or x > strip.right + t or y < strip.top - t or y > strip.bottom + t;
    var screen_pt: c.POINT = .{ .x = x, .y = y };
    _ = c.ClientToScreen(hwnd, &screen_pt);
    const st = &app.tabline_state;
    if (outside and !st.is_external_drag) {
        st.is_external_drag = true;
        st.drop_target_index = null;
        if (applog.isEnabled()) applog.appLog("[tabline] entering external drag mode for tab {?d}\n", .{st.dragging_tab});
        createDragPreviewWindow(app, st.dragging_tab.?, screen_pt.x, screen_pt.y);
    } else if (!outside and st.is_external_drag) {
        st.is_external_drag = false;
        if (applog.isEnabled()) applog.appLog("[tabline] returning to normal drag mode\n", .{});
        destroyDragPreviewWindow(app);
    }
    if (st.is_external_drag) updateDragPreviewPosition(app, screen_pt.x, screen_pt.y);
}

/// Whether client x is in the sidebar strip.
pub fn pointInSidebar(app: *App, hwnd: c.HWND, x: c_int) bool {
    const r = sidebarRectPx(app, hwnd);
    var client: c.RECT = std.mem.zeroes(c.RECT);
    _ = c.GetClientRect(hwnd, &client);
    return x >= @max(0, r.left) and x < @min(client.right, r.right);
}

/// The main window's sidebar strip, in client pixels.
pub fn sidebarRectPx(app: *App, hwnd: c.HWND) c.RECT {
    var client: c.RECT = std.mem.zeroes(c.RECT);
    _ = c.GetClientRect(hwnd, &client);
    const w = app.scalePx(@as(c_int, @intCast(app.sidebar_width_px)));
    // Mid-slide (or closed) the strip is partly (or wholly) past the edge.
    const covered = sidebar_caption.coveredPx(app);
    return if (app.sidebar_position_right)
        .{ .left = client.right - covered, .top = 0, .right = client.right - covered + w, .bottom = client.bottom }
    else
        .{ .left = covered - w, .top = 0, .right = covered, .bottom = client.bottom };
}

/// The sidebar width a width drag asks for, both in logical px: at most half
/// the client, but never below SIDEBAR_MIN_WIDTH even in a narrow client.
pub fn clampSidebarWidth(want_px: c_int, client_w_px: c_int) u32 {
    const max_px = @max(TablineState.SIDEBAR_MIN_WIDTH, @divTrunc(client_w_px, 2));
    return @intCast(std.math.clamp(want_px, TablineState.SIDEBAR_MIN_WIDTH, max_px));
}

test "clampSidebarWidth: min 120, max half the client, min wins in a narrow client" {
    try std.testing.expectEqual(@as(u32, 200), clampSidebarWidth(200, 1000));
    try std.testing.expectEqual(@as(u32, 120), clampSidebarWidth(50, 1000));
    try std.testing.expectEqual(@as(u32, 120), clampSidebarWidth(-30, 1000));
    try std.testing.expectEqual(@as(u32, 500), clampSidebarWidth(900, 1000));
    try std.testing.expectEqual(@as(u32, 500), clampSidebarWidth(500, 1000));
    try std.testing.expectEqual(@as(u32, 120), clampSidebarWidth(300, 200));
    try std.testing.expectEqual(@as(u32, 120), clampSidebarWidth(10, 200));
}

/// Whether client (x, y) is on the open sidebar's inner edge: the strip
/// SIDEBAR_RESIZE_EDGE wide just inside the edge facing the editor, so it
/// never takes a point from the editor or the scrollbar. Off while the
/// sidebar is closed or sliding, and in the caption band, whose points move
/// the window or press its buttons (a right sidebar's toggle can reach it).
pub fn sidebarResizeEdgeHit(app: *App, hwnd: c.HWND, x: c_int, y: c_int) bool {
    if (!(app.ext_tabline_enabled and app.tabline_style == .sidebar)) return false;
    if (app.sidebar_sliding or sidebar_caption.coveredPx(app) <= 0) return false;
    if (sidebar_caption.drawsBand(app) and y < sidebar_caption.bandPx(app)) return false;
    if (!pointInSidebar(app, hwnd, x)) return false;
    const r = sidebarRectPx(app, hwnd);
    const edge_px = app.scalePx(TablineState.SIDEBAR_RESIZE_EDGE);
    return if (app.sidebar_position_right) x < r.left + edge_px else x >= r.right - edge_px;
}

pub fn setSidebarResizeCursor() void {
    _ = c.SetCursor(input.loadSystemCursor(32644)); // IDC_SIZEWE
}

/// Start a width drag from a press at client x on the inner edge.
pub fn beginSidebarResize(app: *App, hwnd: c.HWND, x: c_int) void {
    const r = sidebarRectPx(app, hwnd);
    app.tabline_state.sidebar_resize_grab_px = if (app.sidebar_position_right) x - r.left else r.right - x;
    setSidebarResizeCursor();
    _ = c.SetCapture(hwnd);
}

/// Follow a width drag to client x. The new width is session-only: nothing
/// writes it back to the config. The grid is resized as a window resize
/// does (outside app.mu: the core can re-enter through callbacks); the
/// window keeps its size.
pub fn updateSidebarResize(app: *App, hwnd: c.HWND, x: c_int) void {
    const grab_px = app.tabline_state.sidebar_resize_grab_px orelse return;
    var client: c.RECT = std.mem.zeroes(c.RECT);
    _ = c.GetClientRect(hwnd, &client);
    const want_px = if (app.sidebar_position_right) client.right - x + grab_px else x + grab_px;
    const width = clampSidebarWidth(logicalPx(app, want_px), logicalPx(app, client.right));
    if (width == app.sidebar_width_px) return;
    // The core thread reads the width under app.mu (contentSizePx from its
    // font and linespace callbacks).
    app.mu.lockUncancelable(core.clock.io());
    app.sidebar_width_px = width;
    app.mu.unlock(core.clock.io());
    app_mod.updateLayoutToCore(hwnd, app);
    // A left sidebar moves the grid: redraw everything, as the toggle does.
    sidebar_caption.repaint(hwnd, app);
}

/// End a width drag. The state is dropped before ReleaseCapture, whose
/// WM_CAPTURECHANGED arrives synchronously.
pub fn endSidebarResize(app: *App) void {
    app.tabline_state.sidebar_resize_grab_px = null;
    _ = c.ReleaseCapture();
}

fn logicalPx(app: *const App, px: c_int) c_int {
    return @intFromFloat(@round(@as(f32, @floatFromInt(px)) / app.dpi_scale));
}

/// Drop the tab bar's (or sidebar's) hover and repaint its band. For every
/// way the pointer can leave it: into the non-client area, into the editor,
/// or out of the window altogether.
pub fn clearTablineHover(app: *App, hwnd: c.HWND) void {
    if (!app.ext_tabline_enabled) return;
    if (app.tabline_style == .sidebar) {
        if (app.tabline_state.hovered_tab == null and
            app.tabline_state.hovered_close == null and
            !app.tabline_state.hovered_new_tab_btn) return;
        app.tabline_state.hovered_tab = null;
        app.tabline_state.hovered_close = null;
        app.tabline_state.hovered_new_tab_btn = false;
        const sidebar_rect = sidebarRectPx(app, hwnd);
        _ = c.InvalidateRect(hwnd, &sidebar_rect, 0);
        return;
    }
    if (app.tabline_style != .titlebar) return;
    if (app.tabline_state.hovered_tab == null and
        app.tabline_state.hovered_close == null and
        app.tabline_state.hovered_window_btn == null and
        !app.tabline_state.hovered_new_tab_btn) return;
    app.tabline_state.hovered_tab = null;
    app.tabline_state.hovered_close = null;
    app.tabline_state.hovered_window_btn = null;
    app.tabline_state.hovered_new_tab_btn = false;
    const band = tablineBandRect(app, hwnd);
    _ = c.InvalidateRect(hwnd, &band, 0);
}

/// The strip the tabs are drawn in, in client pixels: the titlebar band
/// across the whole client width (the caption buttons sit at its right edge;
/// a fixed 4096 px band left them stale on a wider client) or the sidebar.
pub fn tablineBandRect(app: *App, hwnd: c.HWND) c.RECT {
    if (app.tabline_style == .sidebar) return sidebarRectPx(app, hwnd);
    var client: c.RECT = undefined;
    _ = c.GetClientRect(hwnd, &client);
    return .{ .left = 0, .top = 0, .right = client.right, .bottom = titlebarBarPx(app) };
}

/// Drop any tab-strip press or drag when the capture is lost, and repaint
/// the strip.
pub fn cancelTablinePointer(app: *App, hwnd: c.HWND) void {
    const st = &app.tabline_state;
    if (st.dragging_tab == null and st.close_button_pressed == null and
        !st.new_tab_button_pressed and st.pressed_window_btn == null and
        st.sidebar_resize_grab_px == null) return;
    if (applog.isEnabled()) applog.appLog("[tabline] WM_CAPTURECHANGED (parent): cancelling drag/button!\n", .{});
    destroyDragPreviewWindow(app);
    st.cancelDrag();
    // The width already dragged to stays: each step was laid out live.
    st.sidebar_resize_grab_px = null;
    st.close_button_pressed = null;
    st.new_tab_button_pressed = false;
    st.pressed_window_btn = null;
    const band = tablineBandRect(app, hwnd);
    _ = c.InvalidateRect(hwnd, &band, 0);
}

pub fn handleTablineMouseMoveInChild(app: *App, hwnd: c.HWND, x: c_int, y: c_int) void {
    // Track mouse leave
    input.trackMouseLeave(hwnd);

    var rect: c.RECT = undefined;
    _ = c.GetClientRect(hwnd, &rect);
    const client_width = rect.right;

    // DPI-scaled constants
    const bar_height = titlebarBarPx(app);
    const hit = tablineHitTest(app, client_width, app.tabline_state.tab_count, x, y);

    // Handle dragging
    if (app.tabline_state.dragging_tab != null) {
        app.tabline_state.drag_current_x = x;

        // The band the tabs are drawn in: client rows 0..bar_height. The
        // window rect starts a frame above it when maximized.
        trackExternalDrag(app, hwnd, .{ .left = 0, .top = 0, .right = client_width, .bottom = bar_height }, x, y);

        // Normal in-window drag: calculate drop target
        if (!app.tabline_state.is_external_drag) {
            const tab_count: c_int = @intCast(app.tabline_state.tab_count);
            if (tab_count > 0) {
                const tab_width = tabWidthPx(app, client_width, tab_count);
                app.tabline_state.drop_target_index = calculateDropTarget(x, app.tabline_state.tab_count, tabLeftPx(app, tab_width, 0), tab_width + 1, tab_width);
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
        if (pressed_tab_idx < app.tabline_state.tab_count) {
            const is_still_over_close = hit == .close and hit.close == pressed_tab_idx;
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
        if (app.tabline_state.tab_count > 0) {
            if (hit != .new_tab) {
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
        const is_still_over_btn = hit == .window_button and hit.window_button == pressed_btn;
        if (!is_still_over_btn) {
            // Mouse left the window button - cancel the press
            if (applog.isEnabled()) applog.appLog("[tabline] mouseMove: window button {d} cancelled (mouse left)\n", .{pressed_btn});
            app.tabline_state.pressed_window_btn = null;
            _ = c.ReleaseCapture();
            _ = c.InvalidateRect(hwnd, null, 0);
        }
        return;
    }

    const new_hovered_window_btn: ?u8 = if (hit == .window_button) hit.window_button else null;
    const new_hovered_tab: ?usize = switch (hit) {
        .tab => |i| i,
        .close => |i| i,
        else => null,
    };
    const new_hovered_close: ?usize = if (hit == .close) hit.close else null;
    const new_hovered_new_tab_btn = hit == .new_tab;

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

const PressedTab = struct { hit: TablineHit, handle: i64, tab_count: usize };

/// Resolve a tab-strip press from its hit: the core thread rewrites tabs[]
/// and tab_count under app.mu, so the hit, the pressed tab's handle and the
/// count are read in one hold. A close button is pressable only where it is
/// drawn (selected or hovered); elsewhere the press is on the tab. Caller
/// holds app.mu.
fn pressedTabHit(st: *const TablineState, hit: TablineHit) PressedTab {
    var out: PressedTab = .{ .hit = hit, .handle = 0, .tab_count = st.tab_count };
    if (hit == .close) {
        const i = hit.close;
        if (st.tabs[i].handle != st.current_tab and st.hovered_tab != i) out.hit = .{ .tab = i };
    }
    switch (out.hit) {
        .close, .tab => |i| out.handle = st.tabs[i].handle,
        else => {},
    }
    return out;
}

test "tab press: close is pressable only on the selected or hovered tab; the handle is the hit tab's" {
    var st: TablineState = .{};
    st.tabs[0] = .{ .handle = 11 };
    st.tabs[1] = .{ .handle = 22 };
    st.tab_count = 2;
    st.current_tab = 11;
    const on_selected = pressedTabHit(&st, .{ .close = 0 });
    try std.testing.expect(on_selected.hit == .close);
    try std.testing.expectEqual(@as(i64, 11), on_selected.handle);
    const on_other = pressedTabHit(&st, .{ .close = 1 });
    try std.testing.expect(on_other.hit == .tab and on_other.hit.tab == 1);
    try std.testing.expectEqual(@as(i64, 22), on_other.handle);
    st.hovered_tab = 1;
    try std.testing.expect(pressedTabHit(&st, .{ .close = 1 }).hit == .close);
    try std.testing.expectEqual(@as(usize, 2), pressedTabHit(&st, .new_tab).tab_count);
}

/// Handle mouse down on tabline - start potential drag
pub fn handleTablineMouseDown(app: *App, hwnd: c.HWND, x: c_int, y: c_int) void {
    if (applog.isEnabled()) applog.appLog("[tabline] mouseDown: x={d} y={d}\n", .{ x, y });

    var rect: c.RECT = undefined;
    _ = c.GetClientRect(hwnd, &rect);
    const client_width = rect.right;

    // Buttons record their pressed state and act on mouseUp; capture so the
    // mouseUp arrives even if the pointer leaves.
    app.mu.lockUncancelable(core.clock.io());
    const pressed = pressedTabHit(&app.tabline_state, tablineHitTest(app, client_width, app.tabline_state.tab_count, x, y));
    app.mu.unlock(core.clock.io());
    const hit = pressed.hit;
    switch (hit) {
        .window_button => |b| {
            if (applog.isEnabled()) applog.appLog("[tabline] mouseDown: window button {d} pressed\n", .{b});
            app.tabline_state.pressed_window_btn = b;
            _ = c.SetCapture(hwnd);
            _ = c.InvalidateRect(hwnd, null, 0);
        },
        .close => |i| {
            if (applog.isEnabled()) applog.appLog("[tabline] mouseDown: close button pressed on tab {d}\n", .{i});
            app.tabline_state.close_button_pressed = i;
            app.tabline_state.close_button_pressed_handle = pressed.handle;
            _ = c.SetCapture(hwnd);
            _ = c.InvalidateRect(hwnd, null, 0); // Redraw for pressed state
        },
        .tab => |i| {
            // Start potential drag - first select this tab
            if (applog.isEnabled()) applog.appLog("[tabline] mouseDown: starting drag on tab {d}\n", .{i});
            const tab_width = tabWidthPx(app, client_width, @intCast(pressed.tab_count));
            app.tabline_state.drag_start_x = x;
            app.tabline_state.drag_offset_x = x - tabLeftPx(app, tab_width, i);
            app.tabline_state.drag_current_x = x;
            app.tabline_state.dragging_tab = i;
            app.tabline_state.dragging_tab_handle = pressed.handle;
            app.tabline_state.drop_target_index = i;

            // Select the tab being dragged so :tabmove works on it
            // Use nvim_command API so it works even in terminal mode
            if (app.corep) |corep| {
                var cmd_buf: [16]u8 = undefined;
                const cmd = std.fmt.bufPrint(&cmd_buf, "{d}tabnext", .{i + 1}) catch return;
                app_mod.zonvie_core_send_command(corep, cmd.ptr, cmd.len);
            }
            _ = c.SetCapture(hwnd);
        },
        .new_tab => {
            if (applog.isEnabled()) applog.appLog("[tabline] mouseDown: new tab button pressed\n", .{});
            app.tabline_state.new_tab_button_pressed = true;
            _ = c.SetCapture(hwnd);
        },
        .none => {},
    }
}

/// Handle mouse up on tabline - finish drag or handle click
pub fn handleTablineMouseUp(app: *App, hwnd: c.HWND, x: c_int, y: c_int) void {
    if (applog.isEnabled()) applog.appLog("[tabline] mouseUp: x={d} y={d} dragging_tab={?} is_external_drag={} close_button_pressed={?}\n", .{ x, y, app.tabline_state.dragging_tab, app.tabline_state.is_external_drag, app.tabline_state.close_button_pressed });

    if (releaseTabButton(app, hwnd)) return;

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

    finishTabDrag(app, hwnd, x, y, absDelta(x, app.tabline_state.drag_start_x));
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

    app.external_placement.setPending(@floatFromInt(screen_x), @floatFromInt(screen_y), @intCast(@divTrunc(core.clock.nowNs(), std.time.ns_per_ms)));

    core.zonvie_core_externalize_tab(corep, @intCast(tab_idx));
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
                const preview_pal = osTitlebarPalette();

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
                    const hfont = createTabFont(app, -12);
                    const old_font = c.SelectObject(hdc, hfont);

                    const text_pad = app.scalePx(10);

                    // Display name (basename, preserving the agent-status glyph)
                    // of the dragged tab by its handle, as the release resolves
                    // it: tabs[] moves under app.mu on the core thread.
                    var name_buf: [256]u8 = undefined;
                    const name_len: ?usize = blk: {
                        app.mu.lockUncancelable(core.clock.io());
                        defer app.mu.unlock(core.clock.io());
                        const drag_idx = draggedTabIndexNow(&app.tabline_state) orelse break :blk null;
                        break :blk extractTabDisplayName(&app.tabline_state.tabs[drag_idx], &name_buf);
                    };
                    if (name_len) |len| {
                        var text_rect = rect;
                        text_rect.left += text_pad;
                        text_rect.right -= text_pad;
                        _ = c.SetBkMode(hdc, c.TRANSPARENT);
                        _ = c.SetTextColor(hdc, preview_pal.text_selected);
                        drawTabLabel(hdc, name_buf[0..len], &text_rect, c.DT_CENTER);
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
    if (app.renderer) |*r| h.update(std.mem.asBytes(&r.opacity));
    h.update(std.mem.asBytes(&window_mod.g_os_dark_theme_cached));
    // `titlebar_style = "hidden"` paints the bar from the colorscheme.
    h.update(std.mem.asBytes(&app.drag_bar.revealed));
    // What is drawn, not the raw hover state: a pinned band does not change.
    const buttons_shown = sidebar_caption.captionButtonsShown(app);
    h.update(std.mem.asBytes(&buttons_shown));
    h.update(std.mem.asBytes(&app.sidebar_collapsed));
    // The title band: whether it is drawn (not over a card that reaches the
    // top), its text, and the see-through sidebar part mid-slide.
    const title_band = sidebar_caption.titleBand(app);
    h.update(std.mem.asBytes(&title_band));
    if (title_band) {
        h.update(std.mem.sliceAsBytes(app.pending_title[0..app.pending_title_len]));
        const covered = sidebar_caption.coveredPx(app);
        h.update(std.mem.asBytes(&covered));
    }
    h.update(std.mem.asBytes(&app.sidebar_position_right));
    h.update(std.mem.asBytes(&app.colorscheme_bg));
    h.update(std.mem.asBytes(&app.colorscheme_fg));
    h.update(std.mem.asBytes(&ts.tab_count));
    h.update(std.mem.asBytes(&ts.current_tab));
    h.update(std.mem.asBytes(&ts.bar_lines));
    for (ts.tabs[0..ts.tab_count]) |*tab| {
        h.update(std.mem.asBytes(&tab.handle));
        h.update(tab.name[0..tab.name_len]);
        // Field by field: Run's padding bytes are undefined.
        h.update(std.mem.asBytes(&tab.label.line_count));
        for (tab.label.runs[0..tab.label.run_count]) |run| {
            h.update(std.mem.asBytes(&run.line));
            h.update(std.mem.asBytes(&run.fg_rgb));
            h.update(std.mem.asBytes(&run.flags));
            h.update(std.mem.asBytes(&run.len));
            h.update(tab.label.runText(run));
        }
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

/// Which offscreen strip renderOffscreenToD3D is drawing.
const OffscreenSurface = app_mod.d3d11.Strip;

/// Draw one offscreen strip into a 32-bit top-down DIB and upload it to its
/// D3D texture. Returns true only when the upload succeeded.
///
/// Both callers built the DIB identically and both must force the alpha
/// channel opaque afterwards, because GDI leaves it untouched.
///
/// The caller keeps its own preconditions -- the tabline's tab_count and
/// change gates have no sidebar counterpart.
fn renderOffscreenToD3D(app: *App, surface: OffscreenSurface, width: u32, height: u32) bool {
    if (app.renderer == null) return false;
    if (width == 0 or height == 0) return false;

    const screen_dc = c.GetDC(null);
    if (screen_dc == null) return false;
    defer _ = c.ReleaseDC(null, screen_dc);

    const mem_dc = c.CreateCompatibleDC(screen_dc);
    if (mem_dc == null) return false;
    defer _ = c.DeleteDC(mem_dc);

    // 32-bit BGRA, top-down
    var bmi: c.BITMAPINFO = std.mem.zeroes(c.BITMAPINFO);
    bmi.bmiHeader.biSize = @sizeOf(c.BITMAPINFOHEADER);
    bmi.bmiHeader.biWidth = @intCast(width);
    bmi.bmiHeader.biHeight = -@as(c.LONG, @intCast(height));
    bmi.bmiHeader.biPlanes = 1;
    bmi.bmiHeader.biBitCount = 32;
    bmi.bmiHeader.biCompression = c.BI_RGB;

    var pixels_ptr: ?*anyopaque = null;
    const dib = c.CreateDIBSection(mem_dc, &bmi, c.DIB_RGB_COLORS, &pixels_ptr, null, 0);
    if (dib == null or pixels_ptr == null) return false;
    defer _ = c.DeleteObject(dib);

    const old_bmp = c.SelectObject(mem_dc, dib);
    defer _ = c.SelectObject(mem_dc, old_bmp);

    {
        // The core thread rewrites tabline_state under app.mu.
        app.mu.lockUncancelable(core.clock.io());
        defer app.mu.unlock(core.clock.io());
        switch (surface) {
            .tabline => if (sidebar_caption.drawsBand(app))
                sidebar_caption.drawOverlayContent(app, mem_dc, @intCast(width))
            else
                drawTablineContent(app, mem_dc, @intCast(width)),
            .sidebar => drawSidebarContent(app, mem_dc, @intCast(width), @intCast(height)),
        }
    }

    // GDI does not set the alpha channel; force it opaque.
    const pixels: [*]u8 = @ptrCast(pixels_ptr);
    const pixel_count = width * height;
    var i: u32 = 0;
    while (i < pixel_count) : (i += 1) {
        pixels[i * 4 + 3] = 255;
    }
    // The captionless overlay keeps only what it drew over its bar colour,
    // fully transparent elsewhere (premultiplied: zero colour too). Binary
    // alpha, so redrawing it over retained rows never accumulates.
    if (surface == .tabline and sidebar_caption.drawsBand(app)) {
        const key = currentTitlebarPalette(app).bar_bg;
        const kr: u8 = @intCast(key & 0xFF);
        const kg: u8 = @intCast((key >> 8) & 0xFF);
        const kb: u8 = @intCast((key >> 16) & 0xFF);
        const cols = sidebar_caption.seeThroughColumnsPx(app, @intCast(width));
        i = 0;
        while (i < pixel_count) : (i += 1) {
            const x: c_int = @intCast(i % width);
            if (x < cols.lo or x >= cols.hi) continue;
            const p = pixels[i * 4 ..][0..4];
            if (p[0] == kb and p[1] == kg and p[2] == kr) p.* = .{ 0, 0, 0, 0 };
        }
    }

    // On a translucent surface the clear paints the editor card's ground,
    // and the card its bg, at the window opacity, written rather than
    // blended. Chrome beside the card is written the same way, every pixel
    // at that opacity (the strip shader premultiplies), so its ground is the
    // clear's and a selected tab running into the card is the card's own
    // colour. Keyed pixels stay (0,0,0,0): the sidebar, drawn after, covers
    // them.
    const g = &(app.renderer.?);
    g.strips_replace = g.opacity < 1.0 and sidebar_caption.island(app) != null;
    if (g.strips_replace) {
        const a: u8 = @intFromFloat(@round(g.opacity * 255.0));
        i = 0;
        while (i < pixel_count) : (i += 1) {
            if (pixels[i * 4 + 3] != 0) pixels[i * 4 + 3] = a;
        }
    }

    const pixel_data = pixels[0 .. width * height * 4];
    g.updateStripTexture(surface, width, height, pixel_data) catch |e| {
        if (applog.isEnabled()) applog.appLog("[{s}] updateStripTexture failed: {any}\n", .{ @tagName(surface), e });
        return false;
    };
    return true;
}

/// Render tabline to D3D11 texture via offscreen GDI bitmap.
/// This avoids DWM composition issues by keeping GDI rendering offscreen
/// and only using D3D11 for final display.
pub fn renderTablineToD3D(app: *App, width: u32, height: u32) void {
    if (app.renderer == null) return;
    if (width == 0 or height == 0) return;

    // Change gate: WM_PAINT calls this unconditionally, but the tab strip
    // rarely changes between paints. A full re-render costs a fresh
    // width*height*4 DIB allocation, dozens of GDI object creations, a CPU
    // pass over every pixel and a full-texture GPU upload — per keystroke
    // repaint and per cursor-blink toggle. Skip when the drawn content is
    // byte-identical to what the D3D texture already holds.
    app.mu.lockUncancelable(core.clock.io());
    const sig = tablineRenderSignature(app, width, height);
    app.mu.unlock(core.clock.io());
    if (sig == if (app.renderer) |*r| r.stripContentSig(.tabline).* else return) return;

    // Only record the signature after a successful upload so a failed
    // upload retries on the next paint.
    if (renderOffscreenToD3D(app, .tabline, width, height)) {
        if (app.renderer) |*r| r.stripContentSig(.tabline).* = sig;
    }
}

/// Render sidebar to D3D11 texture via offscreen GDI bitmap, skipped when
/// nothing drawSidebarContent reads has changed: it was re-rendered and fully
/// re-uploaded on every WM_PAINT, cursor blinks included.
pub fn renderSidebarToD3D(app: *App, width: u32, height: u32) void {
    app.mu.lockUncancelable(core.clock.io());
    const sig = sidebarRenderSignature(app, width, height);
    app.mu.unlock(core.clock.io());
    if (sig == if (app.renderer) |*r| r.stripContentSig(.sidebar).* else return) return;
    if (renderOffscreenToD3D(app, .sidebar, width, height)) {
        if (app.renderer) |*r| r.stripContentSig(.sidebar).* = sig;
    }
}

/// Everything drawSidebarContent (and SidebarColors.compute) reads.
fn sidebarRenderSignature(app: *App, width: u32, height: u32) u64 {
    const ts = &app.tabline_state;
    var h = std.hash.Wyhash.init(1);
    h.update(std.mem.asBytes(&width));
    h.update(std.mem.asBytes(&height));
    h.update(std.mem.asBytes(&app.dpi_scale));
    if (app.renderer) |*r| h.update(std.mem.asBytes(&r.opacity));
    h.update(std.mem.asBytes(&app.colorscheme_bg));
    h.update(std.mem.asBytes(&app.colorscheme_fg));
    h.update(std.mem.asBytes(&app.sidebar_position_right));
    h.update(std.mem.asBytes(&ts.tab_count));
    h.update(std.mem.asBytes(&ts.current_tab));
    for (ts.tabs[0..ts.tab_count]) |*tab| {
        h.update(std.mem.asBytes(&tab.handle));
        h.update(tab.name[0..tab.name_len]);
    }
    var opt_fields = [_]u64{
        sigOptIdx(ts.hovered_tab),
        sigOptIdx(ts.hovered_close),
        @intFromBool(ts.hovered_new_tab_btn),
        sigOptIdx(ts.dragging_tab),
        @as(u64, @bitCast(@as(i64, ts.drag_current_y))),
        sigOptIdx(ts.drop_target_index),
        @intFromBool(ts.is_external_drag),
        @as(u64, ts.spinner_frame),
        @as(u64, ts.agent_count),
    };
    h.update(std.mem.sliceAsBytes(opt_fields[0..]));
    h.update(std.mem.asBytes(&ts.agent_handles));
    h.update(std.mem.asBytes(&ts.agent_states));
    return h.final();
}

/// Draw tabline content (called from offscreen DC or child window WM_PAINT)
/// Color palette for the custom titlebar / tabline rendering. All values
/// are picked from the OS app-theme preference (Settings → Personalization
/// → Colors) so the titlebar tracks the system light/dark mode regardless
/// of the active Neovim colorscheme. Approximates the Windows 11 native
/// titlebar palette.
pub const TitlebarPalette = struct {
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

pub fn currentTitlebarPalette(app: *const App) TitlebarPalette {
    if (app.config.window.titlebar_style.paintsEditorBg() and app.colorscheme_bg != 0xFFFFFFFF) {
        // Chrome beside an editor card sits on its ground, as the renderer
        // clears it; tab and button states shift from there.
        const base = if (sidebar_caption.chromeOnGround(app)) islandGroundRgb(app.colorscheme_bg) else app.colorscheme_bg;
        return colorschemeTitlebarPalette(base, app.colorscheme_fg);
    }
    return osTitlebarPalette();
}

fn osTitlebarPalette() TitlebarPalette {
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

/// `titlebar_style = "hidden"` or `"unified"`: the bar is the editor's default bg, so it
/// reads as part of the editor (the post shader runs over it too); tab states
/// are that bg shifted toward the text side.
fn colorschemeTitlebarPalette(bg: u32, fg_or_none: u32) TitlebarPalette {
    const bg_r: i32 = @intCast((bg >> 16) & 0xFF);
    const bg_g: i32 = @intCast((bg >> 8) & 0xFF);
    const bg_b: i32 = @intCast(bg & 0xFF);
    const dark = bg_r * 299 + bg_g * 587 + bg_b * 114 < 128 * 1000;
    const fg: u32 = if (fg_or_none != 0xFFFFFFFF) fg_or_none else if (dark) 0xFFFFFF else 0x000000;
    const Mix = struct {
        fn rgb(a: u32, b: u32, t_pct: i32) c.COLORREF {
            var out: [3]i32 = undefined;
            inline for (0..3) |i| {
                const sh: u5 = @intCast(16 - 8 * i);
                const av: i32 = @intCast((a >> sh) & 0xFF);
                const bv: i32 = @intCast((b >> sh) & 0xFF);
                out[i] = av + @divTrunc((bv - av) * t_pct, 100);
            }
            return c.RGB(@as(u8, @intCast(out[0])), @as(u8, @intCast(out[1])), @as(u8, @intCast(out[2])));
        }
    };
    const toward: u32 = if (dark) 0xFFFFFF else 0x000000;
    return .{
        .bar_bg = Mix.rgb(bg, bg, 0),
        .tab_selected = Mix.rgb(bg, toward, 12),
        .tab_hover = Mix.rgb(bg, toward, 6),
        .tab_normal = Mix.rgb(bg, bg, 0),
        .tab_placeholder = Mix.rgb(bg, toward, 8),
        .tab_dragging = Mix.rgb(bg, 0x0078D7, 30),
        .text_selected = Mix.rgb(fg, fg, 0),
        .text_normal = Mix.rgb(fg, bg, 35),
        .glyph_pen = Mix.rgb(fg, bg, 25),
        .glyph_hover_bg = Mix.rgb(bg, toward, 18),
        .wbtn_icon = Mix.rgb(fg, bg, 15),
        .wbtn_hover_bg = Mix.rgb(bg, toward, 10),
        .wbtn_close_hover_bg = c.RGB(232, 17, 35),
        .wbtn_close_hover_icon = c.RGB(255, 255, 255),
        .accent = c.RGB(0, 120, 215),
    };
}

/// The minimize, maximize and close buttons at the right end of the main
/// window's titlebar; a captionless window under hover reveal draws them
/// only while the pointer is in the band.
pub fn drawWindowButtons(app: *App, hdc: c.HDC, client_width: c_int, pal: anytype) void {
    if (!sidebar_caption.captionButtonsShown(app)) return;
    const bar_height = app.scalePx(TablineState.TAB_BAR_HEIGHT);
    const btns_total = app.scalePx(TablineState.WINDOW_BTNS_TOTAL);
    const btn_w = app.scalePx(TablineState.WINDOW_BTN_WIDTH);
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
}

/// Corner radius of a titlebar tab, as macOS TabBarView.tabCornerRadius.
const TAB_CORNER_RADIUS_PT: c_int = 8;

const TabShape = enum {
    /// Every corner rounded.
    rounded,
    /// Top corners rounded; the bottom runs into the editor card below,
    /// flaring out into it with concave corners beside `rect`.
    merged,
};

/// Fill `rect` with `color` in `shape`, corners of `radius` px antialiased.
/// GDI's RoundRect does not antialias, so on a DIB section (the offscreen
/// strip) the corners are blended into its pixels directly; any other DC
/// gets RoundRect, or a plain rect for `merged`.
fn fillTabShape(hdc: c.HDC, rect: c.RECT, radius: c_int, color: c.COLORREF, shape: TabShape) void {
    const w = rect.right - rect.left;
    const h = rect.bottom - rect.top;
    if (w <= 0 or h <= 0) return;
    const r = @max(0, @min(radius, @divTrunc(@min(w, h), 2)));
    const brush = c.CreateSolidBrush(color);
    defer _ = c.DeleteObject(brush);

    var ds: c.DIBSECTION = undefined;
    const bmp = c.GetCurrentObject(hdc, c.OBJ_BITMAP);
    const is_dib = bmp != null and c.GetObjectW(bmp, @sizeOf(c.DIBSECTION), &ds) == @sizeOf(c.DIBSECTION) and
        ds.dsBm.bmBits != null and ds.dsBm.bmBitsPixel == 32;
    if (!is_dib or r == 0) {
        if (r == 0 or shape == .merged) {
            var fill = rect;
            _ = c.FillRect(hdc, &fill, brush);
            return;
        }
        const old_brush = c.SelectObject(hdc, brush);
        const old_pen = c.SelectObject(hdc, c.GetStockObject(c.NULL_PEN));
        // RoundRect's corner argument is the ellipse's diameter.
        _ = c.RoundRect(hdc, rect.left, rect.top, rect.right + 1, rect.bottom + 1, r * 2, r * 2);
        _ = c.SelectObject(hdc, old_pen);
        _ = c.SelectObject(hdc, old_brush);
        return;
    }

    // The body: a cross of two rects leaves the r x r corner squares; a
    // merged shape fills its bottom corners square.
    const bottom_inset = if (shape == .merged) 0 else r;
    var mid = c.RECT{ .left = rect.left + r, .top = rect.top, .right = rect.right - r, .bottom = rect.bottom };
    _ = c.FillRect(hdc, &mid, brush);
    var sides = c.RECT{ .left = rect.left, .top = rect.top + r, .right = rect.right, .bottom = rect.bottom - bottom_inset };
    _ = c.FillRect(hdc, &sides, brush);

    // Pending GDI writes must land before the bits are touched.
    _ = c.GdiFlush();
    // The DC's viewport origin moves what GDI draws; the bits do not.
    var org: c.POINT = .{ .x = 0, .y = 0 };
    _ = c.GetViewportOrgEx(hdc, &org);
    const bw: c_int = ds.dsBm.bmWidth;
    const bh: c_int = ds.dsBm.bmHeight;
    // Row 0 of the bits is the top: the strip's DIB is created top-down
    // (renderOffscreenToD3D), and GetObject cannot be asked, since it reports
    // dsBmih.biHeight without the sign that says so.
    const stride: usize = @intCast(ds.dsBm.bmWidthBytes);
    const bits: [*]u8 = @ptrCast(ds.dsBm.bmBits);
    const col = [3]f32{
        @floatFromInt(c.GetBValue(color)),
        @floatFromInt(c.GetGValue(color)),
        @floatFromInt(c.GetRValue(color)),
    };
    const rf: f32 = @floatFromInt(r);

    // An r x r square at (x, y) and the circle centre its arc is cut from.
    // Convex corners keep the inside of the circle; a concave flare keeps
    // the outside.
    const Corner = struct { x: c_int, y: c_int, cx: c_int, cy: c_int, concave: bool };
    var corners: [4]Corner = undefined;
    corners[0] = .{ .x = rect.left, .y = rect.top, .cx = rect.left + r, .cy = rect.top + r, .concave = false };
    corners[1] = .{ .x = rect.right - r, .y = rect.top, .cx = rect.right - r, .cy = rect.top + r, .concave = false };
    if (shape == .merged) {
        corners[2] = .{ .x = rect.left - r, .y = rect.bottom - r, .cx = rect.left - r, .cy = rect.bottom - r, .concave = true };
        corners[3] = .{ .x = rect.right, .y = rect.bottom - r, .cx = rect.right + r, .cy = rect.bottom - r, .concave = true };
    } else {
        corners[2] = .{ .x = rect.left, .y = rect.bottom - r, .cx = rect.left + r, .cy = rect.bottom - r, .concave = false };
        corners[3] = .{ .x = rect.right - r, .y = rect.bottom - r, .cx = rect.right - r, .cy = rect.bottom - r, .concave = false };
    }
    for (corners) |k| {
        const cx: f32 = @floatFromInt(k.cx);
        const cy: f32 = @floatFromInt(k.cy);
        var y = k.y;
        while (y < k.y + r) : (y += 1) {
            const dy = y + org.y;
            if (dy < 0 or dy >= bh) continue;
            const row: usize = @intCast(dy);
            var x = k.x;
            while (x < k.x + r) : (x += 1) {
                const dx = x + org.x;
                if (dx < 0 or dx >= bw) continue;
                const fx = @as(f32, @floatFromInt(x)) + 0.5 - cx;
                const fy = @as(f32, @floatFromInt(y)) + 0.5 - cy;
                const inside = std.math.clamp(rf - @sqrt(fx * fx + fy * fy) + 0.5, 0.0, 1.0);
                const cov = if (k.concave) 1 - inside else inside;
                if (cov <= 0) continue;
                const p = bits[row * stride + @as(usize, @intCast(dx)) * 4 ..][0..3];
                for (0..3) |ch| {
                    p[ch] = @intFromFloat(@round(@as(f32, @floatFromInt(p[ch])) * (1 - cov) + col[ch] * cov));
                }
            }
        }
    }
}

/// Tabs extend down the whole bar; their first label line, agent indicator,
/// close button and the + button stay in the one-line band at the top, where
/// a single-line bar has them.
pub fn drawTablineContent(app: *App, hdc: c.HDC, client_width: c_int) void {
    const bar_height = titlebarBarPx(app);
    const band_height = app.scalePx(TablineState.TAB_BAR_HEIGHT);
    const line_px = labelLinePx(app);
    const tab_padding = app.scalePx(TablineState.TAB_PADDING);
    const close_size = app.scalePx(TablineState.TAB_CLOSE_SIZE);
    const drag_threshold = app.scalePx(TablineState.DRAG_THRESHOLD);
    const close_margin = app.scalePx(6);
    const close_inset = app.scalePx(3);
    const top_padding = app.scalePx(4);
    const plus_offset = app.scalePx(8);
    const plus_btn_size = plusButtonSizePx(app);
    const plus_btn_height = plusButtonHeightPx(app);
    const plus_icon_inset = app.scalePx(5);
    const is_dragging = app.tabline_state.dragging_tab != null;

    const pal = currentTitlebarPalette(app);

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

    // No tabs (a session swap until its first tabline_update): the empty bar
    // tablineHitTest assumes, window buttons live and the rest caption.
    if (app.tabline_state.tab_count == 0) {
        drawWindowButtons(app, hdc, client_width, pal);
        return;
    }

    // Calculate tab width
    const tab_count: c_int = @intCast(app.tabline_state.tab_count);
    const tab_width = tabWidthPx(app, client_width, tab_count);

    const tab_radius = app.scalePx(TAB_CORNER_RADIUS_PT);
    // A tab's background stands clear of the bar on every side, so its
    // rounded corners do not meet a neighbour or the bar's edges.
    const tab_inset_y = app.scalePx(5);
    const tab_inset_x = app.scalePx(3);
    // The editor card's bg when the tabs sit on its top edge.
    const card_bg: ?c.COLORREF = if (sidebar_caption.island(app) == null) null else blk: {
        const bg = if (app.colorscheme_bg == 0xFFFFFFFF) 0x252629 else app.colorscheme_bg;
        break :blk c.RGB(@as(u8, @intCast((bg >> 16) & 0xFF)), @as(u8, @intCast((bg >> 8) & 0xFF)), @as(u8, @intCast(bg & 0xFF)));
    };

    // Font
    const font = createTabFont(app, -12);
    defer _ = c.DeleteObject(font);
    const old_font = c.SelectObject(hdc, font);
    defer _ = c.SelectObject(hdc, old_font);
    // Freed before the restore above, while `font` is selected (drawLabelLine
    // reselects it): GDI does not delete a selected font.
    var label_fonts: LabelFonts = .{};
    defer label_fonts.deinit();

    _ = c.SetBkMode(hdc, c.TRANSPARENT);

    // Check if mouse has moved beyond drag threshold (for visual feedback)
    const is_actually_dragging = is_dragging and
        tabDragPastThreshold(absDelta(app.tabline_state.drag_current_x, app.tabline_state.drag_start_x), drag_threshold);

    var x: c_int = app.scalePx(TablineState.WINDOW_CONTROLS_WIDTH);

    // First pass: draw all tabs (with placeholder for dragged tab)
    for (0..app.tabline_state.tab_count) |i| {
        const tab = &app.tabline_state.tabs[i];
        const is_selected = tab.handle == app.tabline_state.current_tab;
        const is_hovered = app.tabline_state.hovered_tab == i;
        const is_being_dragged = is_actually_dragging and app.tabline_state.dragging_tab == i;

        const tab_rect = c.RECT{
            .left = x + tab_inset_x,
            .top = tab_inset_y,
            .right = x + tab_width - tab_inset_x,
            .bottom = bar_height - tab_inset_y,
        };

        // If this tab is being dragged (moved beyond threshold), draw a placeholder (dimmed)
        if (is_being_dragged) {
            // Draw dimmed placeholder
            fillTabShape(hdc, tab_rect, tab_radius, pal.tab_placeholder, .rounded);
            x += tab_width + 1;
            continue;
        }

        // Background. Over an editor card the selected tab is the card's
        // own bg, run down into its top edge, and an idle tab is bare
        // ground: a fill there would cut into a neighbour's flare.
        if (is_selected and card_bg != null) {
            var merged_rect = tab_rect;
            merged_rect.bottom = bar_height;
            fillTabShape(hdc, merged_rect, tab_radius, card_bg.?, .merged);
        } else if (is_selected or is_hovered or card_bg == null) {
            const tab_bg = if (is_selected) pal.tab_selected else if (is_hovered) pal.tab_hover else pal.tab_normal;
            fillTabShape(hdc, tab_rect, tab_radius, tab_bg, .rounded);
        }

        // Tab name
        const text_color = if (is_selected) pal.text_selected else pal.text_normal;
        _ = c.SetTextColor(hdc, text_color);

        // The first line's box; line k is the same box k label lines lower.
        var text_rect = c.RECT{
            .left = x + tab_padding,
            .top = top_padding,
            .right = x + tab_width - tab_padding - close_size - top_padding,
            .bottom = band_height,
        };

        // AI-agent indicator drawn in a FIXED-WIDTH cell so varying spinner
        // glyph widths never shift the tab title between frames. Idle shows a
        // color 🤖 (AlphaBlend; GDI DrawTextW can't render color emoji);
        // working shows a monochrome spinner glyph centered in the same cell.
        const a_state = if (app.config.tabline.agent_indicator) app.tabline_state.agentState(tab.handle) else 0;
        if (a_state != 0) {
            // Indicator cell sized near the text cap height, sitting inline.
            const ind_px = @divTrunc((band_height - top_padding * 2) * 7, 10);
            const cell_w = ind_px + top_padding; // glyph box + gap, reserved
            drawAgentIndicator(app, hdc, a_state, text_rect.left, text_rect.top, text_rect.bottom, @divTrunc(band_height - ind_px, 2), ind_px);
            text_rect.left += cell_w; // anchor the title past the fixed cell
        }

        if (tab.label.line_count == 0) {
            // Display name = basename only (indicator drawn separately above).
            var base_buf: [256]u8 = undefined;
            const base_len = extractTabDisplayName(tab, &base_buf);
            drawTabLabel(hdc, base_buf[0..base_len], &text_rect, c.DT_LEFT);
        } else {
            // 'guitablabel' verbatim, no basename. Lines past the bar's are
            // not drawn; the bar catches up on the UI thread.
            const lines = @min(tab.label.line_count, app.tabline_state.bar_lines);
            for (0..lines) |k| {
                const dy = @as(c_int, @intCast(k)) * line_px;
                // The close button and the indicator sit beside the first line only.
                const r = if (k == 0) text_rect else c.RECT{
                    .left = x + tab_padding,
                    .top = text_rect.top + dy,
                    .right = x + tab_width - tab_padding,
                    .bottom = text_rect.bottom + dy,
                };
                drawLabelLine(app, hdc, &label_fonts, font, &tab.label, @intCast(k), r, text_color);
            }
        }

        // Close button (X) - show on selected or hovered tabs
        if (is_selected or is_hovered) {
            const close_x = x + tab_width - close_size - close_margin;
            const close_y = @divTrunc(band_height - close_size, 2);

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
    const plus_y = @divTrunc(band_height - plus_btn_size, 2);
    {
        // Hover background: a circle at one line, a rounded rect when stretched.
        if (app.tabline_state.hovered_new_tab_btn) {
            const plus_hover_brush = c.CreateSolidBrush(pal.glyph_hover_bg);
            // The previous brush is restored before DeleteObject: GDI refuses to
            // delete an object still selected into a DC, so deleting it while
            // selected silently leaks the handle.
            const old_brush_hover = c.SelectObject(hdc, plus_hover_brush);
            const null_pen = c.GetStockObject(c.NULL_PEN);
            const old_pen_hover = c.SelectObject(hdc, null_pen);
            if (plus_btn_height > plus_btn_size) {
                // RoundRect takes the corner ellipse's diameter: 12 gives a 6px radius.
                const corner = app.scalePx(12);
                _ = c.RoundRect(hdc, plus_x, plus_y, plus_x + plus_btn_size, plus_y + plus_btn_height, corner, corner);
            } else {
                _ = c.Ellipse(hdc, plus_x, plus_y, plus_x + plus_btn_size, plus_y + plus_btn_size);
            }
            _ = c.SelectObject(hdc, old_pen_hover);
            _ = c.SelectObject(hdc, old_brush_hover);
            _ = c.DeleteObject(plus_hover_brush);
        }

        // Draw + icon as two filled 2px bars. A width-2 GDI pen renders
        // asymmetrically, so each bar spans inset-1 .. (btn-inset) inclusive to
        // keep the arms equal: the 2px thickness sits at center-1..center (half a
        // pixel up-left), so without the -1 on top/left the up-left arms come out
        // 1px short. The +1 on right/bottom also covers FillRect's excluded edge.
        // The icon is centred in the stretched button, in a square of the
        // one-line size.
        const plus_cx = plus_x + @divTrunc(plus_btn_size, 2);
        const icon_y = plus_y + @divTrunc(plus_btn_height - plus_btn_size, 2);
        const plus_cy = icon_y + @divTrunc(plus_btn_size, 2);
        const plus_brush = c.CreateSolidBrush(pal.glyph_pen);
        var v_bar = c.RECT{
            .left = plus_cx - 1,
            .top = icon_y + plus_icon_inset - 1,
            .right = plus_cx + 1,
            .bottom = icon_y + plus_btn_size - plus_icon_inset + 1,
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

    drawWindowButtons(app, hdc, client_width, pal);

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
            if (drag_idx >= app.tabline_state.tab_count) return;
            const tab = &app.tabline_state.tabs[drag_idx];

            // Calculate floating tab position - centered on cursor
            const float_x = app.tabline_state.drag_current_x - app.tabline_state.drag_offset_x;
            const float_rect = c.RECT{
                .left = float_x + tab_inset_x,
                .top = tab_inset_y,
                .right = float_x + tab_width - tab_inset_x,
                .bottom = bar_height - tab_inset_y,
            };

            // Draw floating tab tinted with the accent color (no transparency
            // in GDI; use the dragging-tab palette entry for a consistent feel).
            fillTabShape(hdc, float_rect, tab_radius, pal.tab_dragging, .rounded);

            // Draw border for floating tab
            const border_pen = c.CreatePen(c.PS_SOLID, 1, pal.accent);
            const old_border_pen = c.SelectObject(hdc, border_pen);
            const float_null_brush = c.GetStockObject(c.NULL_BRUSH);
            const old_float_brush = c.SelectObject(hdc, float_null_brush);
            _ = c.RoundRect(hdc, float_rect.left, float_rect.top, float_rect.right, float_rect.bottom, tab_radius * 2, tab_radius * 2);
            _ = c.SelectObject(hdc, old_float_brush);
            _ = c.SelectObject(hdc, old_border_pen);
            _ = c.DeleteObject(border_pen);

            // Draw tab name on floating tab
            _ = c.SetTextColor(hdc, pal.text_selected);
            var float_text_rect = c.RECT{
                .left = float_x + tab_padding,
                .top = top_padding,
                .right = float_x + tab_width - tab_padding,
                .bottom = band_height,
            };

            var float_display_name: [256]u8 = undefined;
            const float_display_len = extractTabDisplayName(tab, &float_display_name);
            drawTabLabel(hdc, float_display_name[0..float_display_len], &float_text_rect, c.DT_LEFT);
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
                const name = app_mod.tabNameForStorage(if (t[i].name_len > 0) t[i].name[0..t[i].name_len] else "", 255);
                @memcpy(app.tabline_state.tabs[i].name[0..name.len], name);
                app.tabline_state.tabs[i].name_len = name.len;
                app.tabline_state.tabs[i].label.store(if (t[i].chunks) |ch| ch[0..t[i].chunk_count] else &.{});
            }
            app.tabline_state.tab_count = count;
        }
    }

    // Request repaint via PostMessage to UI thread
    // Tabline is now drawn on parent window, so invalidate parent. The
    // handler also resizes a titlebar bar whose label line count changed
    // (syncTitlebarLines): never here, the layout call blocks on the core.
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

    // Fired on a session reset: drop the old session's tabs so they are
    // neither drawn nor clickable until its first tabline_update.
    app.mu.lockUncancelable(core.clock.io());
    app.tabline_state.clear();
    app.mu.unlock(core.clock.io());
    if (app.hwnd) |main_hwnd| {
        _ = c.PostMessageW(main_hwnd, app_mod.WM_APP_TABLINE_INVALIDATE, 0, 0);
    }

    // Hide child window
    if (app.tabline_state.hwnd) |tabline_hwnd| {
        _ = c.ShowWindow(tabline_hwnd, c.SW_HIDE);
    }
}

// =========================================================================
// Sidebar mode rendering and mouse handling
// =========================================================================

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

        // The strip is the editor card's ground when the card is drawn.
        // Captionless, it is macOS's translucent tint over the editor bg: the
        // bg with its OKLab lightness moved, at the overlay's alpha.
        var strip: ?[3]f32 = null;
        if (sidebar_caption.island(app) != null) {
            // Exactly as the renderer clears it.
            const ground = islandGroundRgb(app.colorscheme_bg);
            strip = .{
                @as(f32, @floatFromInt((ground >> 16) & 0xFF)) / 255.0,
                @as(f32, @floatFromInt((ground >> 8) & 0xFF)) / 255.0,
                @as(f32, @floatFromInt(ground & 0xFF)) / 255.0,
            };
        } else if (sidebar_caption.captionless(app)) {
            const is_dark = 0.299 * bgR + 0.587 * bgG + 0.114 * bgB < 0.5;
            const tint = lightnessShifted(bgR, bgG, bgB, !is_dark);
            const overlay_alpha: f32 = 0.55;
            strip = .{
                bgR + (tint[0] - bgR) * overlay_alpha,
                bgG + (tint[1] - bgG) * overlay_alpha,
                bgB + (tint[2] - bgB) * overlay_alpha,
            };
        }
        const p = core.frontend_rules.sidebarPalette(.{ fgR, fgG, fgB }, .{ bgR, bgG, bgB }, strip);

        return .{
            .bg_r = f2u8(p.bg[0]),
            .bg_g = f2u8(p.bg[1]),
            .bg_b = f2u8(p.bg[2]),
            .selected_r = f2u8(p.selected[0]),
            .selected_g = f2u8(p.selected[1]),
            .selected_b = f2u8(p.selected[2]),
            .hover_r = f2u8(p.hover[0]),
            .hover_g = f2u8(p.hover[1]),
            .hover_b = f2u8(p.hover[2]),
            .text_r = f2u8(p.text[0]),
            .text_g = f2u8(p.text[1]),
            .text_b = f2u8(p.text[2]),
            .text_sel_r = f2u8(p.text_selected[0]),
            .text_sel_g = f2u8(p.text_selected[1]),
            .text_sel_b = f2u8(p.text_selected[2]),
            .sep_r = f2u8(p.separator[0]),
            .sep_g = f2u8(p.separator[1]),
            .sep_b = f2u8(p.separator[2]),
            .close_r = f2u8(p.close[0]),
            .close_g = f2u8(p.close[1]),
            .close_b = f2u8(p.close[2]),
            .close_hi_r = f2u8(p.close_hi[0]),
            .close_hi_g = f2u8(p.close_hi[1]),
            .close_hi_b = f2u8(p.close_hi[2]),
            .indicator_r = f2u8(p.indicator[0]),
            .indicator_g = f2u8(p.indicator[1]),
            .indicator_b = f2u8(p.indicator[2]),
        };
    }

    /// `rgb` (sRGB 0-1) with its OKLab L moved by the sidebar delta, hue and
    /// chroma kept. Same constants as macOS TabSidebarView.lightnessShifted.
    fn lightnessShifted(r: f32, g: f32, b: f32, darker: bool) [3]f32 {
        return core.frontend_rules.oklabLightnessShifted(.{ r, g, b }, if (darker) .sidebar_darker else .sidebar_lighter);
    }

    fn f2u8(v: f32) u8 {
        const clamped = @max(@as(f32, 0.0), @min(@as(f32, 1.0), v));
        return @intFromFloat(clamped * 255.0);
    }
};

/// The ground an editor card and the sidebar share, as 0xRRGGBB, from the
/// colorscheme bg (0xFFFFFFFF before one is known: SidebarColors' default).
pub fn islandGroundRgb(colorscheme_bg: u32) u32 {
    const bg = if (colorscheme_bg == 0xFFFFFFFF) 0x252629 else colorscheme_bg;
    const shifted = core.frontend_rules.oklabLightnessShifted(.{
        @as(f32, @floatFromInt((bg >> 16) & 0xFF)) / 255.0,
        @as(f32, @floatFromInt((bg >> 8) & 0xFF)) / 255.0,
        @as(f32, @floatFromInt(bg & 0xFF)) / 255.0,
    }, .island_ground);
    return (@as(u32, SidebarColors.f2u8(shifted[0])) << 16) |
        (@as(u32, SidebarColors.f2u8(shifted[1])) << 8) |
        SidebarColors.f2u8(shifted[2]);
}

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
    // Under the editor (captionless) the sidebar is a tinted overlay with no
    // separator; beside it (the title band) it keeps the plain look.
    const captionless = sidebar_caption.captionless(app);

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
    // An editor card is set apart by its ground, with no line.
    if (!captionless and sidebar_caption.island(app) == null) _ = c.FillRect(hdc, &sep_rect, sep_brush);
    // The list starts below the band that drags the window.
    _ = c.SetViewportOrgEx(hdc, 0, sidebarTopInsetPx(app), null);
    defer _ = c.SetViewportOrgEx(hdc, 0, 0, null);

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
    const font = createTabFont(app, -12);
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

        const text_left: c_int = if (is_selected) padding + indicator_w else padding;
        const close_space: c_int = if (is_selected or is_hovered) close_size + app.scalePx(8) else 0;
        var text_rect = c.RECT{
            .left = text_left,
            .top = y,
            .right = width - sep_w - padding - close_space,
            .bottom = y + row_h,
        };
        // The same agent indicator the titlebar tab draws, before the name.
        const a_state = if (app.config.tabline.agent_indicator) app.tabline_state.agentState(tab.handle) else 0;
        if (a_state != 0) {
            const gap = app.scalePx(4);
            const ind_px = @divTrunc((row_h - gap * 2) * 7, 10);
            drawAgentIndicator(app, hdc, a_state, text_rect.left, text_rect.top, text_rect.bottom, y + @divTrunc(row_h - ind_px, 2), ind_px);
            text_rect.left += ind_px + gap;
        }
        drawTabLabel(hdc, display_name[0..display_len], &text_rect, c.DT_LEFT);

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
            // LineTo leaves out its end pixel: extend each target one step,
            // as the titlebar X does, or the bottom corners are clipped.
            _ = c.MoveToEx(hdc, close_x + close_inset, close_y_pos + close_inset, null);
            _ = c.LineTo(hdc, close_x + close_size - close_inset + 1, close_y_pos + close_size - close_inset + 1);
            _ = c.MoveToEx(hdc, close_x + close_size - close_inset, close_y_pos + close_inset, null);
            _ = c.LineTo(hdc, close_x + close_inset - 1, close_y_pos + close_size - close_inset + 1);
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

        // Filled bars, as the titlebar draws its +: LineTo leaves out its end
        // pixel, so the right and bottom arms came out a pixel short.
        const new_tab_color = c.RGB(colors.close_r, colors.close_g, colors.close_b);
        const bar_t = @max(1, app.scalePx(1));
        const bar_lo = @divTrunc(icon_size, 2) - @divTrunc(bar_t, 2);
        const plus_brush = c.CreateSolidBrush(new_tab_color);
        var v_bar = c.RECT{ .left = icon_x + bar_lo, .top = icon_y + icon_inset, .right = icon_x + bar_lo + bar_t, .bottom = icon_y + icon_size - icon_inset + 1 };
        var h_bar = c.RECT{ .left = icon_x + icon_inset, .top = icon_y + bar_lo, .right = icon_x + icon_size - icon_inset + 1, .bottom = icon_y + bar_lo + bar_t };
        _ = c.FillRect(hdc, &v_bar, plus_brush);
        _ = c.FillRect(hdc, &h_bar, plus_brush);
        _ = c.DeleteObject(plus_brush);

        // "New Tab" text
        _ = c.SetTextColor(hdc, new_tab_color);
        const small_font = createTabFont(app, -11);
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
                    const float_y = app.tabline_state.drag_current_y - app.tabline_state.drag_offset_y;

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
                    var float_text_rect = c.RECT{
                        .left = padding + 2,
                        .top = float_y,
                        .right = width - sep_w - padding - 2,
                        .bottom = float_y + row_h,
                    };
                    drawTabLabel(hdc, float_display_name[0..float_display_len], &float_text_rect, c.DT_LEFT);
                }
            }
        }
    }
}

/// Where the tab list starts in the sidebar: below the window-drag band of
/// a captionless sidebar. The sidebar handlers work in list coordinates.
fn sidebarTopInsetPx(app: *const App) c_int {
    return if (sidebar_caption.enabled(app)) sidebar_caption.bandPx(app) else 0;
}

/// Handle mouse down in sidebar area
pub fn handleSidebarMouseDown(app: *App, hwnd: c.HWND, x: c_int, client_y: c_int) void {
    const y = client_y - sidebarTopInsetPx(app);
    app.mu.lockUncancelable(core.clock.io());
    const pressed = pressedTabHit(&app.tabline_state, sidebarHitTest(app, hwnd, app.tabline_state.tab_count, x, y));
    app.mu.unlock(core.clock.io());
    const hit = pressed.hit;
    switch (hit) {
        .new_tab => {
            app.tabline_state.new_tab_button_pressed = true;
            _ = c.SetCapture(hwnd);
            _ = c.InvalidateRect(hwnd, null, 0);
        },
        .close => |i| {
            app.tabline_state.close_button_pressed = i;
            app.tabline_state.close_button_pressed_handle = pressed.handle;
            _ = c.SetCapture(hwnd);
            _ = c.InvalidateRect(hwnd, null, 0);
        },
        .tab => |i| {
            // Select tab and start drag tracking
            if (app.corep) |corep| {
                var cmd_buf: [32]u8 = undefined;
                const cmd = std.fmt.bufPrint(&cmd_buf, "{d}tabnext", .{i + 1}) catch return;
                app_mod.zonvie_core_send_command(corep, cmd.ptr, cmd.len);
            }

            app.tabline_state.dragging_tab = i;
            app.tabline_state.dragging_tab_handle = pressed.handle;
            app.tabline_state.drag_start_x = x;
            app.tabline_state.drag_current_x = x;
            app.tabline_state.drag_offset_y = y - @as(c_int, @intCast(i)) * app.scalePx(TablineState.SIDEBAR_ROW_HEIGHT);
            app.tabline_state.drag_start_y = y;
            app.tabline_state.drag_current_y = y;
            app.tabline_state.drop_target_index = null;
            app.tabline_state.is_external_drag = false;
            _ = c.SetCapture(hwnd);
        },
        .window_button, .none => {},
    }
}

/// Handle mouse up in sidebar area
pub fn handleSidebarMouseUp(app: *App, hwnd: c.HWND, x: c_int, client_y: c_int) void {
    const y = client_y - sidebarTopInsetPx(app);
    if (releaseTabButton(app, hwnd)) return;
    finishTabDrag(app, hwnd, x, client_y, absDelta(y, app.tabline_state.drag_start_y));
}

/// Handle mouse move in sidebar area
pub fn handleSidebarMouseMove(app: *App, hwnd: c.HWND, x: c_int, client_y: c_int) void {
    const y = client_y - sidebarTopInsetPx(app);
    // Track mouse leave
    input.trackMouseLeave(hwnd);

    const row_h = app.scalePx(TablineState.SIDEBAR_ROW_HEIGHT);
    const hit = sidebarHitTest(app, hwnd, app.tabline_state.tab_count, x, y);

    // Handle close button pressed state - cancel if mouse leaves the button
    if (app.tabline_state.close_button_pressed) |pressed_tab_idx| {
        if (pressed_tab_idx < app.tabline_state.tab_count) {
            const is_still_over_close = hit == .close and hit.close == pressed_tab_idx;
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
        const sb_x = x - sidebarRectPx(app, hwnd).left;
        const sidebar_w = app.scalePx(@as(c_int, @intCast(app.sidebar_width_px)));
        const is_still_over_new_tab = hit == .new_tab and sb_x >= 0 and sb_x < sidebar_w - app.scalePx(TablineState.SIDEBAR_SEPARATOR_WIDTH);

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

        trackExternalDrag(app, hwnd, sidebarRectPx(app, hwnd), x, client_y);
        if (!app.tabline_state.is_external_drag) {
            // Internal reorder: calculate drop target from Y position
            if (tabDragPastThreshold(absDelta(y, app.tabline_state.drag_start_y), app.scalePx(TablineState.DRAG_THRESHOLD))) {
                app.tabline_state.drop_target_index = calculateDropTarget(y, app.tabline_state.tab_count, 0, row_h, row_h);
            }
        }

        // Clear hover states during drag
        app.tabline_state.hovered_tab = null;
        app.tabline_state.hovered_close = null;
        app.tabline_state.hovered_new_tab_btn = false;
        _ = c.InvalidateRect(hwnd, null, 0);
        return;
    }

    const new_hovered_new_tab = hit == .new_tab;
    const new_hovered_tab: ?usize = switch (hit) {
        .tab => |i| i,
        .close => |i| i,
        else => null,
    };
    const new_hovered_close: ?usize = if (hit == .close) hit.close else null;

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
