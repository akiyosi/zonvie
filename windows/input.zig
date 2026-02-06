const std = @import("std");
const app_mod = @import("app.zig");
const App = app_mod.App;
const c = app_mod.c;
const applog = app_mod.applog;
const core = @import("zonvie_core");
const dwrite_d2d = app_mod.dwrite_d2d;

// =========================================================================
// Keyboard constants and input helpers
// =========================================================================

pub const MOD_CTRL  = 1 << 0; // same bit layout as header comment
pub const MOD_ALT   = 1 << 1;
pub const MOD_SHIFT = 1 << 2;
// Windows has no "Command", leave it unused.

pub fn keyIsDown(vk: c_int) bool {
    // GetKeyState returns SHORT. High-order bit set => key down.
    return c.GetKeyState(vk) < 0;
}

pub fn queryMods() u32 {
    var m: u32 = 0;
    if (keyIsDown(c.VK_CONTROL)) m |= MOD_CTRL;
    if (keyIsDown(c.VK_MENU))    m |= MOD_ALT;   // Alt
    if (keyIsDown(c.VK_SHIFT))   m |= MOD_SHIFT;
    return m;
}

pub const KEYCODE_WINVK_FLAG: u32 = 0x10000;

pub fn sendKeyEventToCore(
    app: *App,
    keycode: u32,
    mods: u32,
    chars_utf8: ?[]const u8,
    ign_utf8: ?[]const u8,
) void {
    if (app.corep == null) return;

    const cptr: ?[*]const u8 = if (chars_utf8) |s| s.ptr else null;
    const clen: i32 = if (chars_utf8) |s| @intCast(s.len) else 0;

    const iptr: ?[*]const u8 = if (ign_utf8) |s| s.ptr else null;
    const ilen: i32 = if (ign_utf8) |s| @intCast(s.len) else 0;

    app_mod.zonvie_core_send_key_event(app.corep, keycode, mods, cptr, clen, iptr, ilen);
}

/// Convert a UTF-16 (1 or 2 units) sequence to UTF-8 in a small stack buffer.
pub fn utf16UnitsToUtf8(tmp: *[8]u8, unit0: u16, unit1_opt: ?u16) ?[]const u8 {
    // Handle surrogate pair if present.
    if (unit0 >= 0xD800 and unit0 <= 0xDBFF) {
        const unit1 = unit1_opt orelse return null;
        if (unit1 < 0xDC00 or unit1 > 0xDFFF) return null;

        const hi: u32 = @as(u32, unit0) - 0xD800;
        const lo: u32 = @as(u32, unit1) - 0xDC00;
        const cp: u32 = 0x10000 + ((hi << 10) | lo);

        const n = std.unicode.utf8Encode(@as(u21, @intCast(cp)), tmp) catch return null;
        return tmp[0..n];
    }

    // Single unit (non-surrogate)
    if (unit0 >= 0xDC00 and unit0 <= 0xDFFF) return null;

    const n = std.unicode.utf8Encode(@as(u21, @intCast(unit0)), tmp) catch return null;
    return tmp[0..n];
}

/// Best-effort: use ToUnicodeEx to get chars and charsIgnoringModifiers for a VK.
/// - chars: using current keyboard state
/// - ign:   using state with Ctrl/Alt/Shift cleared (base letter for <C-x> etc)
pub fn toUnicodePairUtf8(
    vk: u32,
    scancode: u32,
    tmp_chars: *[16]u16,
    tmp_ign: *[16]u16,
    out_chars_utf8: *[8]u8,
    out_ign_utf8: *[8]u8,
) struct { chars: ?[]const u8, ign: ?[]const u8 } {
    var state: [256]u8 = undefined;
    _ = c.GetKeyboardState(&state);

    // Current chars
    const hkl = c.GetKeyboardLayout(0);
    const n1 = c.ToUnicodeEx(
        @intCast(vk),
        @intCast(scancode),
        &state,
        @ptrCast(tmp_chars.ptr),
        @intCast(tmp_chars.len),
        0,
        hkl,
    );

    var chars: ?[]const u8 = null;
    if (n1 == 1) {
        chars = utf16UnitsToUtf8(out_chars_utf8, tmp_chars[0], null);
    } else if (n1 == 2) {
        chars = utf16UnitsToUtf8(out_chars_utf8, tmp_chars[0], tmp_chars[1]);
    } else {
        // n1==0: no character; n1<0: dead key (ignore here)
        chars = null;
    }

    // Ignoring modifiers: clear Ctrl/Alt/Shift
    var ign_state = state;
    ign_state[c.VK_CONTROL] = 0;
    ign_state[c.VK_MENU] = 0;
    ign_state[c.VK_SHIFT] = 0;

    const n2 = c.ToUnicodeEx(
        @intCast(vk),
        @intCast(scancode),
        &ign_state,
        @ptrCast(tmp_ign.ptr),
        @intCast(tmp_ign.len),
        0,
        hkl,
    );

    var ign: ?[]const u8 = null;
    if (n2 == 1) {
        ign = utf16UnitsToUtf8(out_ign_utf8, tmp_ign[0], null);
    } else if (n2 == 2) {
        ign = utf16UnitsToUtf8(out_ign_utf8, tmp_ign[0], tmp_ign[1]);
    } else {
        ign = null;
    }

    return .{ .chars = chars, .ign = ign };
}

pub fn isSpecialVk(vk: u32) bool {
    return switch (vk) {
        c.VK_LEFT, c.VK_RIGHT, c.VK_UP, c.VK_DOWN,
        c.VK_HOME, c.VK_END, c.VK_PRIOR, c.VK_NEXT,
        c.VK_INSERT, c.VK_DELETE,
        c.VK_BACK, c.VK_TAB, c.VK_RETURN, c.VK_ESCAPE,
        c.VK_F1, c.VK_F2, c.VK_F3, c.VK_F4, c.VK_F5, c.VK_F6,
        c.VK_F7, c.VK_F8, c.VK_F9, c.VK_F10, c.VK_F11, c.VK_F12,
        => true,
        else => false,
    };
}

// =========================================================================
// IME Helper Functions
// =========================================================================

/// Convert UTF-16 composition string to UTF-8.
/// Must be called with app.mu locked.
pub fn updateImeCompositionUtf8(app: *App) void {
    app.ime_composition_utf8.clearRetainingCapacity();

    for (app.ime_composition_str.items) |unit| {
        // Handle non-surrogate characters
        if (unit >= 0xD800 and unit <= 0xDFFF) {
            // Skip surrogates for now (would need pair handling)
            continue;
        }

        var buf: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(@as(u21, @intCast(unit)), &buf) catch continue;
        app.ime_composition_utf8.appendSlice(app.alloc, buf[0..n]) catch continue;
    }
}

/// Position IME candidate window at cursor location.
pub fn positionImeCandidateWindow(hwnd: c.HWND, app: *App) void {
    const himc = c.ImmGetContext(hwnd);
    if (himc == null) return;
    defer _ = c.ImmReleaseContext(hwnd, himc);

    // Get cursor position and cell metrics from core
    app.mu.lock();
    const corep = app.corep;
    const cell_w = app.cell_w_px;
    const cell_h = app.cell_h_px;
    const linespace = app.linespace_px;
    const ext_tabline_enabled = app.ext_tabline_enabled;
    const main_hwnd = app.hwnd;
    app.mu.unlock();

    if (corep == null) return;

    // Row height includes linespace (for row positioning)
    const row_h: i32 = @intCast(cell_h + linespace);

    var row: i32 = 0;
    var col: i32 = 0;
    const grid_id = app_mod.zonvie_core_get_cursor_position(corep, &row, &col);

    var grids: [16]core.GridInfo = undefined;
    const grid_count = app_mod.zonvie_core_get_visible_grids(corep, &grids, 16);

    var screen_row: i32 = row;
    var screen_col: i32 = col;

    // Find the grid and add startRow/startCol
    for (grids[0..grid_count]) |grid| {
        if (grid.grid_id == grid_id) {
            screen_row = grid.start_row + row;
            screen_col = grid.start_col + col;
            break;
        }
    }

    // Calculate pixel position relative to content area
    const x: c.LONG = @intCast(screen_col * @as(i32, @intCast(cell_w)));
    const cursor_y: c.LONG = @intCast(screen_row * row_h);

    // Candidate window should appear immediately below the overlay (cell_h, not row_h)
    const below_overlay_y: c.LONG = cursor_y + @as(c.LONG, @intCast(cell_h));

    // When ext_tabline is enabled on main window, content is rendered below the tabbar.
    // IME context is associated with main window, so we need to add tabline height
    // to convert content-relative coordinates to main window coordinates.
    // External windows don't have a tabbar, so only apply offset for main window.
    var adjusted_cursor_y = cursor_y;
    var adjusted_below_overlay_y = below_overlay_y;
    const is_main_window = if (main_hwnd) |mh| hwnd == mh else false;
    if (ext_tabline_enabled and is_main_window) {
        adjusted_cursor_y += app_mod.TablineState.TAB_BAR_HEIGHT;
        adjusted_below_overlay_y += app_mod.TablineState.TAB_BAR_HEIGHT;
    }

    // Set composition window position (at cursor)
    var cf: c.COMPOSITIONFORM = undefined;
    cf.dwStyle = c.CFS_POINT;
    cf.ptCurrentPos = .{ .x = x, .y = adjusted_cursor_y };
    _ = c.ImmSetCompositionWindow(himc, &cf);

    // Set candidate window position (immediately below overlay)
    var candidate_form: c.CANDIDATEFORM = undefined;
    candidate_form.dwIndex = 0;
    candidate_form.dwStyle = c.CFS_CANDIDATEPOS;
    candidate_form.ptCurrentPos = .{ .x = x, .y = adjusted_below_overlay_y };
    _ = c.ImmSetCandidateWindow(himc, &candidate_form);
}

/// Disable IME input (switch to direct input mode).
pub fn setIMEOff(hwnd: c.HWND) void {
    const himc = c.ImmGetContext(hwnd);
    if (himc != null) {
        const result = c.ImmSetOpenStatus(himc, c.FALSE);
        _ = c.ImmReleaseContext(hwnd, himc);
        if (applog.isEnabled()) applog.appLog("[IME] setIMEOff: result={d}\n", .{result});
    } else {
        if (applog.isEnabled()) applog.appLog("[IME] setIMEOff: cannot get HIMC\n", .{});
    }
}

/// Calculate cell width for a Unicode codepoint (1 for narrow, 2 for wide).
pub fn imeCellWidth(codepoint: u21) u32 {
    // East Asian Wide characters
    if ((codepoint >= 0x1100 and codepoint <= 0x115F) or // Hangul Jamo
        (codepoint >= 0x2E80 and codepoint <= 0x9FFF) or // CJK
        (codepoint >= 0xAC00 and codepoint <= 0xD7AF) or // Hangul syllables
        (codepoint >= 0xF900 and codepoint <= 0xFAFF) or // CJK compatibility
        (codepoint >= 0xFE10 and codepoint <= 0xFE1F) or // Vertical forms
        (codepoint >= 0xFE30 and codepoint <= 0xFE6F) or // CJK compatibility forms
        (codepoint >= 0xFF00 and codepoint <= 0xFF60) or // Fullwidth forms
        (codepoint >= 0xFFE0 and codepoint <= 0xFFE6) or // Fullwidth symbols
        (codepoint >= 0x20000 and codepoint <= 0x2FFFF) or // CJK Extension B+
        (codepoint >= 0x30000 and codepoint <= 0x3FFFF) or // CJK Extension G+
        (codepoint >= 0x3040 and codepoint <= 0x30FF)) // Hiragana/Katakana
    {
        return 2;
    }
    return 1;
}

/// Wide string constant for "STATIC" window class
const ime_overlay_class: [:0]const u16 = std.unicode.utf8ToUtf16LeStringLiteral("STATIC");

/// Create or update the IME preedit overlay window using layered window.
pub fn updateImePreeditOverlay(hwnd: c.HWND, app: *App) void {
    app.mu.lock();
    const composing = app.ime_composing;
    const comp_len = app.ime_composition_str.items.len;
    app.mu.unlock();

    applog.appLog("[IME] updateImePreeditOverlay composing={d} comp_len={d}\n", .{ @intFromBool(composing), comp_len });

    // Hide overlay if not composing
    if (!composing or comp_len == 0) {
        if (app.ime_overlay_hwnd) |overlay| {
            _ = c.ShowWindow(overlay, c.SW_HIDE);
        }
        return;
    }

    // Get cursor position and cell metrics
    // Avoid nested mutex acquisition by reading atlas ptr under app.mu, then accessing atlas separately
    var font_name_buf: [64]u16 = [_]u16{0} ** 64;
    var atlas_cell_w: u32 = 0;
    var atlas_cell_h: u32 = 0;
    var font_em_size: f32 = 14.0;
    var atlas_ptr: ?*dwrite_d2d.Renderer = null;

    app.mu.lock();
    const corep = app.corep;
    const cell_w = app.cell_w_px;
    const cell_h = app.cell_h_px;
    const linespace = app.linespace_px;
    const comp_str = app.ime_composition_str.items;
    const target_start = app.ime_target_start;
    const target_end = app.ime_target_end;
    atlas_ptr = if (app.atlas) |*a| a else null;
    atlas_cell_w = cell_w;
    atlas_cell_h = cell_h;
    const ext_tabline_enabled = app.ext_tabline_enabled;
    const content_hwnd = app.content_hwnd;
    app.mu.unlock();

    // Access atlas without holding app.mu to avoid nested locking
    if (atlas_ptr) |atlas| {
        atlas.mu.lock();
        defer atlas.mu.unlock();
        @memcpy(&font_name_buf, &atlas.font_name);
        atlas_cell_w = atlas.cell_w_px;
        atlas_cell_h = atlas.cell_h_px;
        font_em_size = atlas.font_em_size;
    }

    if (corep == null) {
        applog.appLog("[IME] corep is null\n", .{});
        return;
    }

    // Validate cell dimensions
    if (cell_w == 0 or cell_h == 0) {
        applog.appLog("[IME] cell dimensions are 0\n", .{});
        return;
    }

    // Row height includes linespace
    const row_h: u32 = cell_h + linespace;

    var row: i32 = 0;
    var col: i32 = 0;
    const grid_id = app_mod.zonvie_core_get_cursor_position(corep, &row, &col);

    // Check if hwnd is an external window (use grid-local coords) or main window (use screen coords)
    var is_external_window = false;
    {
        app.mu.lock();
        defer app.mu.unlock();
        var ext_it = app.external_windows.iterator();
        while (ext_it.next()) |entry| {
            if (entry.value_ptr.hwnd == hwnd) {
                is_external_window = true;
                break;
            }
        }
    }

    var screen_row: i32 = row;
    var screen_col: i32 = col;

    // For external windows, use grid-local coordinates directly
    // For main window, add start_row/start_col to get screen position
    if (!is_external_window) {
        // Get grid info to calculate screen position
        var grids: [16]core.GridInfo = undefined;
        const grid_count = app_mod.zonvie_core_get_visible_grids(corep, &grids, 16);

        for (grids[0..grid_count]) |grid| {
            if (grid.grid_id == grid_id) {
                screen_row = grid.start_row + row;
                screen_col = grid.start_col + col;
                break;
            }
        }
    }

    // Hide overlay if no composition text
    if (comp_str.len == 0) {
        if (app.ime_overlay_hwnd) |overlay| {
            _ = c.ShowWindow(overlay, c.SW_HIDE);
        }
        return;
    }

    // Create a memory DC and font first to measure actual text width
    const screen_dc = c.GetDC(null);
    if (screen_dc == null) return;
    defer _ = c.ReleaseDC(null, screen_dc);

    const mem_dc = c.CreateCompatibleDC(screen_dc);
    if (mem_dc == null) return;
    defer _ = c.DeleteDC(mem_dc);

    // Create GDI font matching the DWrite font
    // Use font_em_size for accurate sizing (negative for character height)
    // Set width to 0 to let Windows determine proper proportions
    const font_height: i32 = -@as(i32, @intFromFloat(font_em_size));

    const hfont = c.CreateFontW(
        font_height,
        0, // width: 0 lets Windows determine proper width based on height
        0, // escapement
        0, // orientation
        c.FW_NORMAL,
        0, // italic
        0, // underline
        0, // strikeout
        c.DEFAULT_CHARSET,
        c.OUT_TT_PRECIS, // TrueType precision for better matching
        c.CLIP_DEFAULT_PRECIS,
        c.CLEARTYPE_QUALITY,
        c.FIXED_PITCH | c.FF_MODERN, // Fixed pitch for monospace
        @ptrCast(&font_name_buf),
    );
    defer {
        if (hfont != null) _ = c.DeleteObject(hfont);
    }

    // Select font into DC to measure text
    const old_font = if (hfont != null) c.SelectObject(mem_dc, hfont) else null;
    defer {
        if (old_font != null) _ = c.SelectObject(mem_dc, old_font);
    }

    // Measure actual text width using GetTextExtentPoint32W
    var text_size: c.SIZE = undefined;
    if (c.GetTextExtentPoint32W(mem_dc, comp_str.ptr, @intCast(comp_str.len), &text_size) == 0) {
        return;
    }

    const overlay_width: i32 = text_size.cx + 4; // Add small padding
    const overlay_height: i32 = @intCast(atlas_cell_h);

    // Convert client position to screen position (use row_h for Y position)
    // For ext-cmdline, add offset for icon area and padding
    const is_cmdline = (grid_id == app_mod.CMDLINE_GRID_ID);
    const cmdline_x_offset: c.LONG = if (is_external_window and is_cmdline)
        @intCast(app_mod.CMDLINE_PADDING + app_mod.CMDLINE_ICON_MARGIN_LEFT + app_mod.CMDLINE_ICON_SIZE + app_mod.CMDLINE_ICON_MARGIN_RIGHT)
    else
        0;
    const cmdline_y_offset: c.LONG = if (is_external_window and is_cmdline)
        @intCast(app_mod.CMDLINE_PADDING)
    else
        0;

    var pt: c.POINT = .{
        .x = screen_col * @as(c.LONG, @intCast(cell_w)) + cmdline_x_offset,
        .y = screen_row * @as(c.LONG, @intCast(row_h)) + cmdline_y_offset,
    };
    // Use content_hwnd for coordinate conversion when it exists (content_hwnd is positioned below tabline).
    // When content_hwnd is null but ext_tabline is enabled on main window, add tabline height manually.
    const coord_hwnd = if (content_hwnd) |ch| ch else hwnd;
    if (content_hwnd == null and ext_tabline_enabled and !is_external_window) {
        pt.y += app_mod.TablineState.TAB_BAR_HEIGHT;
    }
    _ = c.ClientToScreen(coord_hwnd, &pt);

    applog.appLog("[IME] overlay pos=({d},{d}) size=({d},{d}) text_w={d} cell=({d},{d}) row_h={d}\n", .{ pt.x, pt.y, overlay_width, overlay_height, text_size.cx, cell_w, cell_h, row_h });

    // Create overlay window if it doesn't exist (use layered window)
    if (app.ime_overlay_hwnd == null) {
        const new_overlay = c.CreateWindowExW(
            c.WS_EX_TOOLWINDOW | c.WS_EX_TOPMOST | c.WS_EX_NOACTIVATE | c.WS_EX_LAYERED,
            ime_overlay_class.ptr,
            null,
            c.WS_POPUP,
            pt.x,
            pt.y,
            overlay_width,
            overlay_height,
            hwnd,
            null,
            c.GetModuleHandleW(null),
            null,
        );
        if (new_overlay == null) {
            applog.appLog("[IME] CreateWindowExW failed\n", .{});
            return;
        }
        app.ime_overlay_hwnd = new_overlay;
        applog.appLog("[IME] created overlay window\n", .{});
    }

    const overlay = app.ime_overlay_hwnd orelse return;

    // Create 32-bit ARGB bitmap for layered window
    var bmi: c.BITMAPINFO = undefined;
    bmi.bmiHeader.biSize = @sizeOf(c.BITMAPINFOHEADER);
    bmi.bmiHeader.biWidth = overlay_width;
    bmi.bmiHeader.biHeight = -overlay_height; // top-down
    bmi.bmiHeader.biPlanes = 1;
    bmi.bmiHeader.biBitCount = 32;
    bmi.bmiHeader.biCompression = c.BI_RGB;
    bmi.bmiHeader.biSizeImage = 0;
    bmi.bmiHeader.biXPelsPerMeter = 0;
    bmi.bmiHeader.biYPelsPerMeter = 0;
    bmi.bmiHeader.biClrUsed = 0;
    bmi.bmiHeader.biClrImportant = 0;

    var bits: ?*anyopaque = null;
    const bitmap = c.CreateDIBSection(mem_dc, &bmi, c.DIB_RGB_COLORS, &bits, null, 0);
    if (bitmap == null) return;
    defer _ = c.DeleteObject(bitmap);

    const old_bitmap = c.SelectObject(mem_dc, bitmap);
    defer _ = c.SelectObject(mem_dc, old_bitmap);

    // Fill with opaque white background (BGRA format)
    if (bits) |ptr| {
        const pixel_count: usize = @intCast(@as(i32, overlay_width) * overlay_height);
        const pixels: [*]u32 = @ptrCast(@alignCast(ptr));
        for (0..pixel_count) |i| {
            pixels[i] = 0xFFFFFFFF; // ARGB: fully opaque white
        }
    }

    // Re-select font after bitmap selection
    _ = c.SelectObject(mem_dc, hfont);

    // Draw text to memory DC
    _ = c.SetBkMode(mem_dc, c.TRANSPARENT);
    _ = c.SetTextColor(mem_dc, 0x00000000); // Black text (BGR)

    // Draw the entire composition string
    _ = c.TextOutW(mem_dc, 0, 0, comp_str.ptr, @intCast(comp_str.len));

    applog.appLog("[IME] overlay draw: target_start={d} target_end={d} comp_len={d}\n", .{ target_start, target_end, comp_str.len });

    // Draw underline for target clause using pen (same as main window approach)
    if (target_start < comp_str.len and target_end <= comp_str.len and target_start < target_end) {
        const pen_target = c.CreatePen(c.PS_SOLID, 2, 0x00000000);
        defer _ = c.DeleteObject(pen_target);

        // Calculate underline positions using GetTextExtentPoint32W
        var target_start_x: i32 = 0;
        var target_end_x: i32 = 0;

        if (target_start > 0) {
            var size_before: c.SIZE = undefined;
            if (c.GetTextExtentPoint32W(mem_dc, comp_str.ptr, @intCast(target_start), &size_before) != 0) {
                target_start_x = size_before.cx;
            }
        }

        var size_to_end: c.SIZE = undefined;
        if (c.GetTextExtentPoint32W(mem_dc, comp_str.ptr, @intCast(target_end), &size_to_end) != 0) {
            target_end_x = size_to_end.cx;
        }

        applog.appLog("[IME] underline: start_x={d} end_x={d}\n", .{ target_start_x, target_end_x });

        if (target_end_x > target_start_x) {
            const old_pen = c.SelectObject(mem_dc, pen_target);
            const underline_y = overlay_height - 2;
            _ = c.MoveToEx(mem_dc, target_start_x, underline_y, null);
            _ = c.LineTo(mem_dc, target_end_x, underline_y);
            _ = c.SelectObject(mem_dc, old_pen);
        }
    }

    // Update the layered window
    var blend: c.BLENDFUNCTION = .{
        .BlendOp = c.AC_SRC_OVER,
        .BlendFlags = 0,
        .SourceConstantAlpha = 255,
        .AlphaFormat = c.AC_SRC_ALPHA,
    };

    var src_pt: c.POINT = .{ .x = 0, .y = 0 };
    var wnd_size: c.SIZE = .{ .cx = overlay_width, .cy = overlay_height };

    // Window already has WS_EX_TOPMOST extended style, use SWP_NOZORDER
    _ = c.SetWindowPos(
        overlay,
        null,
        pt.x,
        pt.y,
        overlay_width,
        overlay_height,
        c.SWP_NOACTIVATE | c.SWP_SHOWWINDOW | c.SWP_NOZORDER,
    );

    _ = c.UpdateLayeredWindow(
        overlay,
        screen_dc,
        &pt,
        &wnd_size,
        mem_dc,
        &src_pt,
        0,
        &blend,
        c.ULW_ALPHA,
    );

    applog.appLog("[IME] overlay updated\n", .{});
}

/// Hide IME preedit overlay.
pub fn hideImePreeditOverlay(app: *App) void {
    if (app.ime_overlay_hwnd) |overlay| {
        _ = c.ShowWindow(overlay, c.SW_HIDE);
    }
}

// =========================================================================
// Cursor blink functions
// =========================================================================

pub fn startCursorBlinking(hwnd: c.HWND, app: *App, wait_ms: u32, on_ms: u32, off_ms: u32) void {
    // Stop any existing timer
    stopCursorBlinking(hwnd, app);

    // Don't blink if on_ms is 0
    if (on_ms == 0) {
        applog.appLog("[blink] on_ms=0, not blinking\n", .{});
        return;
    }

    app.cursor_blink_wait_ms = wait_ms;
    app.cursor_blink_on_ms = on_ms;
    app.cursor_blink_off_ms = off_ms;

    // Start with wait phase if wait_ms > 0
    if (wait_ms > 0) {
        applog.appLog("[blink] starting with wait_ms={d}\n", .{wait_ms});
        app.cursor_blink_phase = 0;
        app.cursor_blink_state = true;
        const timer_result = c.SetTimer(hwnd, app_mod.TIMER_CURSOR_BLINK, wait_ms, null);
        applog.appLog("[blink] SetTimer result={d}\n", .{timer_result});
        app.cursor_blink_timer = timer_result;
    } else {
        // No wait, start blinking immediately
        enterBlinkCycle(hwnd, app);
    }
}

/// Enter the on/off blink cycle
pub fn enterBlinkCycle(hwnd: c.HWND, app: *App) void {
    applog.appLog("[blink] enterBlinkCycle\n", .{});
    app.cursor_blink_phase = 1;
    app.cursor_blink_state = true;
    scheduleNextBlink(hwnd, app, true);
    // Request repaint
    _ = c.InvalidateRect(hwnd, null, c.FALSE);
}

/// Schedule the next blink state change
pub fn scheduleNextBlink(hwnd: c.HWND, app: *App, is_currently_on: bool) void {
    const interval = if (is_currently_on) app.cursor_blink_on_ms else app.cursor_blink_off_ms;

    if (interval == 0) {
        applog.appLog("[blink] interval=0, stopping\n", .{});
        return;
    }

    applog.appLog("[blink] scheduleNextBlink: is_on={} interval={d}ms\n", .{ is_currently_on, interval });
    app.cursor_blink_timer = c.SetTimer(hwnd, app_mod.TIMER_CURSOR_BLINK, interval, null);
}

/// Handle cursor blink timer event
pub fn handleCursorBlinkTimer(hwnd: c.HWND, app: *App) void {
    _ = c.KillTimer(hwnd, app_mod.TIMER_CURSOR_BLINK);
    app.cursor_blink_timer = 0;

    if (app.cursor_blink_phase == 0) {
        // Wait phase complete, enter blink cycle
        enterBlinkCycle(hwnd, app);
    } else {
        // Toggle blink state
        app.cursor_blink_state = !app.cursor_blink_state;
        applog.appLog("[blink] toggled to {}\n", .{app.cursor_blink_state});

        // Update external windows blink state
        updateExternalWindowsBlinkState(app);

        // Request repaint for cursor area
        if (app.last_cursor_rect_px) |rect| {
            _ = c.InvalidateRect(hwnd, &rect, c.FALSE);
        } else {
            _ = c.InvalidateRect(hwnd, null, c.FALSE);
        }

        // Schedule next blink
        scheduleNextBlink(hwnd, app, app.cursor_blink_state);
    }
}

/// Stop cursor blinking
pub fn stopCursorBlinking(hwnd: c.HWND, app: *App) void {
    if (app.cursor_blink_timer != 0) {
        _ = c.KillTimer(hwnd, app_mod.TIMER_CURSOR_BLINK);
        app.cursor_blink_timer = 0;
    }
    app.cursor_blink_phase = 0;
    app.cursor_blink_state = true;

    // Update external windows blink state (cursor visible)
    updateExternalWindowsBlinkState(app);
}

/// Update cursor blinking based on current cursor settings from core
pub fn updateCursorBlinking(hwnd: c.HWND, app: *App) void {
    var wait_ms: u32 = 0;
    var on_ms: u32 = 0;
    var off_ms: u32 = 0;

    if (app.corep) |core_ptr| {
        app_mod.zonvie_core_get_cursor_blink(core_ptr, &wait_ms, &on_ms, &off_ms);
    }

    applog.appLog("[blink] updateCursorBlinking: wait={d} on={d} off={d} (current: wait={d} on={d} off={d})\n", .{ wait_ms, on_ms, off_ms, app.cursor_blink_wait_ms, app.cursor_blink_on_ms, app.cursor_blink_off_ms });

    // Check if blink settings changed
    const settings_changed = wait_ms != app.cursor_blink_wait_ms or
        on_ms != app.cursor_blink_on_ms or
        off_ms != app.cursor_blink_off_ms;

    // Check if timer is currently stopped
    const timer_stopped = app.cursor_blink_timer == 0;

    applog.appLog("[blink] settings_changed={}, on_ms>0={}, off_ms>0={}, timer_stopped={}\n", .{ settings_changed, on_ms > 0, off_ms > 0, timer_stopped });

    if (on_ms > 0 and off_ms > 0) {
        // Blink should be enabled
        if (settings_changed or timer_stopped) {
            // Start/restart if settings changed OR timer was stopped (e.g., after mode change to non-blinking mode)
            applog.appLog("[blink] calling startCursorBlinking\n", .{});
            startCursorBlinking(hwnd, app, wait_ms, on_ms, off_ms);
        }
    } else {
        // Blink should be disabled
        if (settings_changed) {
            applog.appLog("[blink] calling stopCursorBlinking\n", .{});
            stopCursorBlinking(hwnd, app);
        }
    }
}

/// Update blink state for all external windows
pub fn updateExternalWindowsBlinkState(app: *App) void {
    var it = app.external_windows.iterator();
    while (it.next()) |entry| {
        const ext_win = entry.value_ptr;
        ext_win.cursor_blink_state = app.cursor_blink_state;
        if (ext_win.hwnd) |ext_hwnd| {
            _ = c.InvalidateRect(ext_hwnd, null, c.FALSE);
        }
    }
}
