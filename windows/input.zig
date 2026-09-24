const std = @import("std");
const app_mod = @import("app.zig");
const App = app_mod.App;
const c = app_mod.c;
const applog = app_mod.applog;
const core = @import("zonvie_core");
const dwrite_d2d = app_mod.dwrite_d2d;
const render_helpers = @import("render_pipeline_helpers.zig");
const callbacks = @import("callbacks.zig");
const external_windows = @import("ui/external_windows.zig");

/// The external window that shows the cursor's grid, and where that grid
/// sits inside it: zero for the window's own root, the layer's origin for a
/// float it hosts. Null when the main window shows the grid. The IME
/// candidate and the preedit overlay both place against this; they looked the
/// grid up by exact id, so a hosted float fell through to main-window
/// coordinates. Caller holds `app.mu`.
const ImeExternalSurface = struct { hwnd: c.HWND, root_grid_id: i64, x_px: c.LONG, y_px: c.LONG };

/// Where core content starts inside a decorated external surface: the
/// cmdline's icon strip and padding, a message window's padding. The IME wrote
/// the cmdline's out by hand, twice, and gave a message window none.
fn imeDecoratedOrigin(app: *App, surface: ?ImeExternalSurface) [2]c.LONG {
    const s = surface orelse return .{ 0, 0 };
    const o = external_windows.decoratedContentOriginPx(app, external_windows.classifyExternalSurface(s.root_grid_id));
    return .{ @intFromFloat(o.x), @intFromFloat(o.y) };
}

fn imeExternalSurfaceLocked(app: *App, grid_id: i64) ?ImeExternalSurface {
    const shown = callbacks.externalWindowShowingGridLocked(app, grid_id) orelse return null;
    const hwnd = shown.win.hwnd orelse return null;
    const origin = render_helpers.layerOriginPx(
        app_mod.SurfaceLayer,
        shown.win.tbs.committed_layers.slice(),
        grid_id,
        shown.root_grid_id,
    );
    return .{ .hwnd = hwnd, .root_grid_id = shown.root_grid_id, .x_px = origin[0], .y_px = origin[1] };
}

// =========================================================================
// Keyboard constants and input helpers
// =========================================================================

pub const MOD_CTRL = 1 << 0; // same bit layout as header comment
pub const MOD_ALT = 1 << 1;
pub const MOD_SHIFT = 1 << 2;
// Windows has no "Command", leave it unused.

/// Non-blocking cursor position query with cache fallback (mirrors macOS's
/// getCursorPositionNonBlocking). The IME candidate-window paths used to
/// block on the core's grid lock on every WM_IME_STARTCOMPOSITION and every
/// WM_PAINT during composition. Returns the grid_id and fills out_row/
/// out_col on success (fresh or cached, at most one flush stale); -1 with
/// out_row/out_col = -1 if there is no cursor position available at all
/// (never queried successfully and no cache entry yet) -- callers must not
/// use the coordinates without a >= 0 check. Shared by the IME paths here
/// and the scrollbar update path (ui/scrollbar.zig).
/// out_stale, if non-null, is set to true when the result was served from
/// the cache (lock busy) rather than freshly read -- the IME call sites
/// below pass null since a stale IME position self-heals within a frame;
/// the scrollbar call site needs this to decide whether to retry instead of
/// silently dropping a one-shot scrollbar-update message.
pub fn getCursorPositionNonBlocking(app: *App, corep: *app_mod.zonvie_core, out_row: *i32, out_col: *i32, out_stale: ?*bool) i64 {
    const result = app_mod.zonvie_core_try_get_cursor_position(corep, out_row, out_col);
    if (result != -2) {
        app.cursor_pos_cache = .{ .grid_id = result, .row = out_row.*, .col = out_col.* };
        if (out_stale) |s| s.* = false;
        return result;
    }
    // Lock busy -- serve the cached value.
    out_row.* = app.cursor_pos_cache.row;
    out_col.* = app.cursor_pos_cache.col;
    if (out_stale) |s| s.* = true;
    return app.cursor_pos_cache.grid_id;
}

pub fn keyIsDown(vk: c_int) bool {
    // GetKeyState returns SHORT. High-order bit set => key down.
    return c.GetKeyState(vk) < 0;
}

pub fn queryMods() u32 {
    var m: u32 = 0;
    if (keyIsDown(c.VK_CONTROL)) m |= MOD_CTRL;
    if (keyIsDown(c.VK_MENU)) m |= MOD_ALT; // Alt
    if (keyIsDown(c.VK_SHIFT)) m |= MOD_SHIFT;
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

/// The `:` <-> `;` swap (config input.swap_colon_semicolon) for one typed
/// character. Paste arrives through the clipboard path and is unaffected.
pub fn swapColonSemicolon(ch: u16, enabled: bool) u16 {
    if (!enabled) return ch;
    return switch (ch) {
        0x3A => 0x3B,
        0x3B => 0x3A,
        else => ch,
    };
}

test "colon and semicolon swap only when enabled" {
    try std.testing.expectEqual(@as(u16, ';'), swapColonSemicolon(':', true));
    try std.testing.expectEqual(@as(u16, ':'), swapColonSemicolon(';', true));
    try std.testing.expectEqual(@as(u16, 'a'), swapColonSemicolon('a', true));
    try std.testing.expectEqual(@as(u16, ':'), swapColonSemicolon(':', false));
}

/// WM_KEYDOWN / WM_SYSKEYDOWN for any surface, main or external. True when
/// the key was consumed; false leaves it to WM_CHAR (plain text, Shift-only,
/// IME). The two WndProcs carried copies of this body.
pub fn handleKeyDownMessage(app: *App, wParam: c.WPARAM, lParam: c.LPARAM) bool {
    const vk: u32 = @intCast(wParam);
    const mods = queryMods();
    // Passed as 0x10000|VK so the core can tell a Windows keycode apart.
    const keycode: u32 = KEYCODE_WINVK_FLAG | vk;
    const scancode: u32 = @intCast((@as(u32, @intCast(lParam)) >> 16) & 0xFF);

    app.mu.lockUncancelable(core.clock.io());
    const ime_composing = app.ime_composing;
    app.mu.unlock(core.clock.io());

    // Special keys always go through send_key_event, except Enter and
    // Backspace while IME composes: the committed text comes via WM_IME_CHAR
    // and the key via WM_CHAR after WM_IME_ENDCOMPOSITION, so sending it here
    // too would input it twice.
    if (isSpecialVk(vk)) {
        if (!(ime_composing and (vk == c.VK_RETURN or vk == c.VK_BACK))) {
            sendKeyEventToCore(app, keycode, mods, null, null);
        }
        return true;
    }

    // Ctrl/Alt combos go through send_key_event with the characters the core
    // needs to decide <C-x> and the like.
    if ((mods & (MOD_CTRL | MOD_ALT)) != 0) {
        var tmp_chars: [16]u16 = undefined;
        var tmp_ign: [16]u16 = undefined;
        var out_chars: [8]u8 = undefined;
        var out_ign: [8]u8 = undefined;
        const pair = toUnicodePairUtf8(vk, scancode, &tmp_chars, &tmp_ign, &out_chars, &out_ign);
        sendKeyEventToCore(app, keycode, mods, pair.chars, pair.ign);
        return true;
    }
    return false;
}

/// WM_CHAR / WM_SYSCHAR for any surface, main or external. The two WndProcs
/// carried copies of this body and one had lost the colon/semicolon swap.
pub fn handleCharMessage(app: *App, wParam: c.WPARAM) void {
    const mods = queryMods();
    // If Ctrl/Alt are down, WM_CHAR often becomes an ASCII control character;
    // the WM_KEYDOWN path handled those combos.
    if ((mods & (MOD_CTRL | MOD_ALT)) != 0) return;

    const ch0 = swapColonSemicolon(@as(u16, @intCast(wParam)), app.config.input.swap_colon_semicolon);

    // Enter, Backspace, Tab and Escape are sent by WM_KEYDOWN as special keys.
    if (ch0 == 0x08 or ch0 == 0x09 or ch0 == 0x0D or ch0 == 0x1B) {
        app.pending_high_surrogate_char = 0;
        return;
    }

    // Non-BMP characters (e.g. emoji) arrive as two WM_CHARs: high surrogate
    // first, then low. Buffer the high one and combine it with the next.
    var out: [8]u8 = undefined;
    var s: ?[]const u8 = null;
    if (ch0 >= 0xD800 and ch0 <= 0xDBFF) {
        app.pending_high_surrogate_char = ch0;
        return;
    } else if (ch0 >= 0xDC00 and ch0 <= 0xDFFF) {
        const hi = app.pending_high_surrogate_char;
        app.pending_high_surrogate_char = 0;
        if (hi == 0) return; // stray low surrogate
        s = utf16UnitsToUtf8(&out, hi, ch0);
    } else {
        app.pending_high_surrogate_char = 0;
        s = utf16UnitsToUtf8(&out, ch0, null);
    }

    const text = s orelse return;
    // keycode=0 means "text input" (the core takes the chars path).
    sendKeyEventToCore(app, 0, mods, text, text);
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
        c.VK_LEFT,
        c.VK_RIGHT,
        c.VK_UP,
        c.VK_DOWN,
        c.VK_HOME,
        c.VK_END,
        c.VK_PRIOR,
        c.VK_NEXT,
        c.VK_INSERT,
        c.VK_DELETE,
        c.VK_BACK,
        c.VK_TAB,
        c.VK_RETURN,
        c.VK_ESCAPE,
        c.VK_F1,
        c.VK_F2,
        c.VK_F3,
        c.VK_F4,
        c.VK_F5,
        c.VK_F6,
        c.VK_F7,
        c.VK_F8,
        c.VK_F9,
        c.VK_F10,
        c.VK_F11,
        c.VK_F12,
        => true,
        else => false,
    };
}

// =========================================================================
// Mouse Input
// =========================================================================

/// Build a NUL-terminated mouse modifier string ('S'/'C'/'A'/'D') from a
/// mouse message's wParam MK_* flags plus GetKeyState for Alt/Win.
/// The returned buffer is zero-padded, so &result casts to [*:0]const u8.
/// Client-pixel (x, y) to a grid cell. The main window's content is offset by
/// its chrome -- a left sidebar tabline shifts X, a titlebar tabline shifts Y
/// -- and external windows carry neither, which is what is_main_window
/// selects.
///
/// That guard is the whole reason this is one function. The five copies in
/// window.zig's mouse arms omitted it and were correct only because they sit
/// inside the main window's procedure; the copy here needed it because
/// handleMouseWheel runs for both window kinds. Sharing the version without
/// the guard would have made every external-window wheel event land on the
/// wrong cell.
///
/// cell_w and row_h are parameters rather than reads of app: every caller
/// already has them in hand from the same locked read as the other metrics.
pub const CellPos = struct { row: i32, col: i32 };

/// `allow_negative` keeps a position above or left of the grid as a negative
/// cell instead of clamping it to 0. A drag needs that: Neovim scrolls the
/// window while the pointer is held past its edge, and row 0 reads as "at the
/// first line", which stops the scroll. Everything else clamps, because a
/// press cannot land outside the grid it was captured in.
pub fn clientPxToCell(
    app: *App,
    is_main_window: bool,
    x: i32,
    y: i32,
    cell_w: u32,
    row_h: u32,
    allow_negative: bool,
) CellPos {
    // Single early return rather than an is_main_window term inside each
    // offset: this way removing the guard makes the parameter unused, which
    // Zig rejects. An external window silently taking the main window's
    // chrome offsets is otherwise invisible until someone clicks.
    if (!is_main_window) return cellAt(x, y, cell_w, row_h, allow_negative);
    const origin = surfaceOriginPx(app, true);
    return cellAt(x - origin.x, y - origin.y, cell_w, row_h, allow_negative);
}

/// Offset from a window's client origin to its SURFACE origin -- grid 1's cell
/// (0,0). Only the main window draws chrome inside its own client area, so it
/// is zero everywhere else, which is why an external window can pass client
/// pixels to a layer test unchanged and the main window cannot.
///
/// Split out of clientPxToCell because a hit test has to reach surface space
/// BEFORE comparing against `zonvie_layer.x_px`, which is surface-local
/// (include/zonvie_core.h), and must not then pay the offset a second time on
/// the way to the core.
pub fn surfaceOriginPx(app: *App, is_main_window: bool) render_helpers.SurfaceOrigin {
    return render_helpers.surfaceOriginPx(.{
        .is_main_window = is_main_window,
        .ext_tabline_enabled = app.ext_tabline_enabled,
        .style_is_sidebar = app.tabline_style == .sidebar,
        .style_is_titlebar = app.tabline_style == .titlebar,
        .sidebar_on_right = app.sidebar_position_right,
        .has_content_hwnd = app.content_hwnd != null,
        .sidebar_width_px = @as(i32, app.scalePx(@as(c_int, @intCast(app.sidebar_width_px)))),
        .tab_bar_height_px = @as(i32, app.scalePx(app_mod.TablineState.TAB_BAR_HEIGHT)),
    });
}

/// Whether a MAIN-window client point is on the chrome -- a titlebar tabline or
/// a sidebar -- rather than the grid. The origin rule is `surfaceOriginPx`'s; a
/// sidebar on the right takes no leading columns, so it is tested at the edge.
pub fn pointInMainChrome(app: *App, hwnd: c.HWND, px: i32, py: i32) bool {
    if (!app.ext_tabline_enabled) return false;
    const origin = surfaceOriginPx(app, true);
    if (px < origin.x or py < origin.y) return true;
    if (app.tabline_style == .sidebar and app.sidebar_position_right) {
        var client: c.RECT = undefined;
        if (c.GetClientRect(hwnd, &client) == 0) return false;
        const sidebar_w: i32 = app.scalePx(@as(c_int, @intCast(app.sidebar_width_px)));
        return px >= client.right - sidebar_w;
    }
    return false;
}

/// Resolve a MAIN-window client point to the grid the pointer is actually over,
/// the way ExternalWndProc has resolved its own since 5e7e9cb. Takes app.mu,
/// which is what the committed layer list is protected by.
pub fn resolveMainWindowTarget(app: *App, x: i32, y: i32) MouseTarget {
    return resolveSurfaceTarget(app, &app.tbs, 1, true, x, y);
}

/// resolveMainWindowTarget for any surface: `tbs` and `root_grid_id` name the
/// surface, and `is_main_window` picks its origin (an external window's is 0).
pub fn resolveSurfaceTarget(app: *App, tbs: *app_mod.TripleBufferedSurface, root_grid_id: i64, is_main_window: bool, x: i32, y: i32) MouseTarget {
    const grids: []const app_mod.GridInfo = if (app.corep) |cp| app.getVisibleGridsCached(cp) else &.{};
    app.mu.lockUncancelable(core.clock.io());
    defer app.mu.unlock(core.clock.io());
    const origin = surfaceOriginPx(app, is_main_window);
    return resolveMouseTarget(
        tbs.committed_layers.slice(),
        grids,
        root_grid_id,
        x - origin.x,
        y - origin.y,
        app.cell_w_px,
        app.rowHeightPx(),
    );
}

/// The drag/release counterpart: pin to the grid the press chose rather than
/// hit-testing again, so a selection dragged out of a float does not retarget
/// the moment the pointer leaves it.
pub fn rebaseMainWindowTarget(app: *App, grid_id: i64, x: i32, y: i32) MouseTarget {
    return rebaseSurfaceTarget(app, &app.tbs, 1, true, grid_id, x, y);
}

pub fn rebaseSurfaceTarget(app: *App, tbs: *app_mod.TripleBufferedSurface, root_grid_id: i64, is_main_window: bool, grid_id: i64, x: i32, y: i32) MouseTarget {
    app.mu.lockUncancelable(core.clock.io());
    defer app.mu.unlock(core.clock.io());
    const origin = surfaceOriginPx(app, is_main_window);
    return rebaseToGrid(tbs.committed_layers.slice(), root_grid_id, grid_id, x - origin.x, y - origin.y);
}

fn cellAt(content_x: i32, content_y: i32, cell_w: u32, row_h: u32, allow_negative: bool) CellPos {
    return .{
        .col = axisCell(content_x, cell_w, allow_negative),
        .row = axisCell(content_y, row_h, allow_negative),
    };
}

fn axisCell(px: i32, size_px: u32, allow_negative: bool) i32 {
    if (size_px == 0) return 0;
    const size: i32 = @intCast(size_px);
    // Floor, not trunc: -1px is the row above, not row 0.
    return if (allow_negative) @divFloor(px, size) else @divTrunc(@max(0, px), size);
}

/// Clear the shared IME composition state. `end` additionally lowers
/// ime_composing and ime_extmark_active; WM_IME_STARTCOMPOSITION raises
/// ime_composing instead.
pub fn resetImeComposition(app: *App, end: bool) void {
    app.mu.lockUncancelable(core.clock.io());
    app.ime_composing = !end;
    app.ime_composition_str.clearRetainingCapacity();
    app.ime_composition_utf8.clearRetainingCapacity();
    app.ime_clause_info.clearRetainingCapacity();
    app.ime_cursor_pos = 0;
    app.ime_target_start = 0;
    app.ime_target_end = 0;
    if (end) app.ime_extmark_active = false;
    app.mu.unlock(core.clock.io());
}

/// Whether the shared WM_IME_COMPOSITION body ran to completion. On
/// `.alloc_failed` the caller must bail out of the message; the two window
/// procedures return different values there, so the helper does not.
pub const ImeCompositionOutcome = enum { done, alloc_failed };

/// The whole WM_IME_COMPOSITION body: read the composition string, clause
/// info, cursor position and target clause out of the input context, then
/// publish the preedit through the core's inline-extmark path or the overlay.
///
/// Everything here sits inside the ImmGetContext guard. The external-window
/// copy this replaces ran its preedit half OUTSIDE that guard, so a
/// composition message arriving with no input context would republish
/// whatever stale text App still held and flip ime_extmark_active on it. Both
/// windows now behave as the main window did.
pub fn handleImeComposition(app: *App, hwnd: c.HWND, lParam: c.LPARAM) ImeCompositionOutcome {
    const himc = c.ImmGetContext(hwnd);
    if (himc == null) return .done;
    defer _ = c.ImmReleaseContext(hwnd, himc);

    // Get composition string
    if ((lParam & c.GCS_COMPSTR) != 0) {
        const byte_len = c.ImmGetCompositionStringW(himc, c.GCS_COMPSTR, null, 0);
        if (byte_len > 0) {
            const char_len: usize = @intCast(@divTrunc(byte_len, 2));
            app.mu.lockUncancelable(core.clock.io());
            app.ime_composition_str.resize(app.alloc, char_len) catch {
                app.mu.unlock(core.clock.io());
                return .alloc_failed;
            };
            _ = c.ImmGetCompositionStringW(himc, c.GCS_COMPSTR, app.ime_composition_str.items.ptr, @intCast(byte_len));
            // Convert to UTF-8 for display
            updateImeCompositionUtf8(app);
            if (applog.isEnabled()) applog.appLog("[IME] composition_str len={d}\n", .{app.ime_composition_str.items.len});
            app.mu.unlock(core.clock.io());
        } else {
            app.mu.lockUncancelable(core.clock.io());
            app.ime_composition_str.clearRetainingCapacity();
            app.ime_composition_utf8.clearRetainingCapacity();
            app.mu.unlock(core.clock.io());
        }
    }

    // Get clause info (for underline segments)
    if ((lParam & c.GCS_COMPCLAUSE) != 0) {
        const clause_byte_len = c.ImmGetCompositionStringW(himc, c.GCS_COMPCLAUSE, null, 0);
        if (clause_byte_len > 0) {
            const clause_count: usize = @intCast(@divTrunc(clause_byte_len, 4));
            app.mu.lockUncancelable(core.clock.io());
            app.ime_clause_info.resize(app.alloc, clause_count) catch {
                app.mu.unlock(core.clock.io());
                return .alloc_failed;
            };
            _ = c.ImmGetCompositionStringW(himc, c.GCS_COMPCLAUSE, app.ime_clause_info.items.ptr, @intCast(clause_byte_len));
            app.mu.unlock(core.clock.io());
        }
    }

    // Get cursor position in composition
    if ((lParam & c.GCS_CURSORPOS) != 0) {
        const cursor_pos = c.ImmGetCompositionStringW(himc, c.GCS_CURSORPOS, null, 0);
        app.mu.lockUncancelable(core.clock.io());
        app.ime_cursor_pos = @intCast(@max(0, cursor_pos));
        app.mu.unlock(core.clock.io());
    }

    // Get the target clause (the one being converted). Always read COMPATTR,
    // not just when the flag is set.
    {
        const attr_len = c.ImmGetCompositionStringW(himc, c.GCS_COMPATTR, null, 0);
        if (applog.isEnabled()) applog.appLog("[IME] GCS_COMPATTR attr_len={d} lparam_has_flag={d}\n", .{
            attr_len,
            @intFromBool((lParam & c.GCS_COMPATTR) != 0),
        });
        if (attr_len > 0) {
            var attr_buf: [256]u8 = undefined;
            const len: usize = @intCast(@min(@as(usize, @intCast(@max(0, attr_len))), 256));
            _ = c.ImmGetCompositionStringW(himc, c.GCS_COMPATTR, &attr_buf, @intCast(len));

            if (applog.isEnabled()) {
                applog.appLog("[IME] COMPATTR len={d} attrs=", .{len});
                for (0..len) |idx| {
                    applog.appLog("{x} ", .{attr_buf[idx]});
                }
                applog.appLog("\n", .{});
            }

            // ATTR_INPUT = 0x00, ATTR_TARGET_CONVERTED = 0x01,
            // ATTR_CONVERTED = 0x02, ATTR_TARGET_NOTCONVERTED = 0x03
            app.mu.lockUncancelable(core.clock.io());
            app.ime_target_start = 0;
            app.ime_target_end = 0;
            var found_start = false;
            var i: u32 = 0;
            while (i < len) : (i += 1) {
                const attr = attr_buf[i];
                if (attr == 0x01 or attr == 0x03) {
                    if (!found_start) {
                        app.ime_target_start = i;
                        found_start = true;
                    }
                    app.ime_target_end = i + 1;
                }
            }
            if (applog.isEnabled()) applog.appLog("[IME] target_start={d} target_end={d}\n", .{ app.ime_target_start, app.ime_target_end });
            app.mu.unlock(core.clock.io());
        }
    }

    // Display preedit: prefer the core's inline-extmark mode when it accepts
    // it (extmark mode + insert/replace); otherwise fall back to the overlay.
    var handled = false;
    if (app.corep) |corep| {
        app.mu.lockUncancelable(core.clock.io());
        // ime_composition_utf8 is mutated only on this (UI) thread, and the
        // core call below runs synchronously on it, so the backing buffer
        // stays valid after unlock -- pass the full string directly.
        const utf8_ptr = app.ime_composition_utf8.items.ptr;
        const utf8_len = app.ime_composition_utf8.items.len;
        // Map the target clause (UTF-16 unit indices) to UTF-8 byte offsets.
        const units = app.ime_composition_str.items;
        var ts: usize = 0;
        var te: usize = 0;
        if (app.ime_target_start < app.ime_target_end) {
            ts = utf16PrefixUtf8Len(units, app.ime_target_start);
            te = utf16PrefixUtf8Len(units, app.ime_target_end);
        }
        app.mu.unlock(core.clock.io());
        if (utf8_len == 0) {
            app_mod.zonvie_core_clear_preedit(corep);
            handled = true; // nothing to display
        } else {
            handled = app_mod.zonvie_core_set_preedit(corep, utf8_ptr, utf8_len, ts, te) != 0;
        }
    }
    app.mu.lockUncancelable(core.clock.io());
    app.ime_extmark_active = handled;
    app.mu.unlock(core.clock.io());
    if (handled) {
        hideImePreeditOverlay(app);
    } else {
        // Must run WITHOUT app.mu held: updateImePreeditOverlay acquires it.
        updateImePreeditOverlay(hwnd, app);
    }
    return .done;
}

/// The WM_IME_CHAR body. Non-BMP commits arrive as two consecutive messages
/// (high then low surrogate), so a lone high surrogate is buffered.
pub fn handleImeChar(app: *App, ch: u16) void {
    var out: [8]u8 = undefined;
    var s: ?[]const u8 = null;
    if (ch >= 0xD800 and ch <= 0xDBFF) {
        app.pending_high_surrogate_ime = ch;
        return;
    } else if (ch >= 0xDC00 and ch <= 0xDFFF) {
        const hi = app.pending_high_surrogate_ime;
        app.pending_high_surrogate_ime = 0;
        if (hi == 0) return;
        s = utf16UnitsToUtf8(&out, hi, ch);
    } else {
        app.pending_high_surrogate_ime = 0;
        s = utf16UnitsToUtf8(&out, ch, null);
    }
    const text = s orelse return;
    sendKeyEventToCore(app, 0, 0, text, text);
}

pub fn buildMouseModifiers(wParam: c.WPARAM) [5]u8 {
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
    return mod_buf;
}

/// Client-area mouse position out of an lParam. The two halves are SIGNED:
/// a drag that leaves the window reports negative coordinates, and reading
/// them as unsigned turns a few pixels above the top edge into ~65500.
pub fn mousePosFromLParam(lParam: c.LPARAM) struct { x: i32, y: i32 } {
    const packed_bits: usize = @bitCast(lParam);
    const x: i16 = @bitCast(@as(u16, @truncate(packed_bits)));
    const y: i16 = @bitCast(@as(u16, @truncate(packed_bits >> 16)));
    return .{ .x = @intCast(x), .y = @intCast(y) };
}

/// The name Neovim knows a held button by, from the code stored in
/// `App.mouse_button_held`. Null for "no button held", which is what tells a
/// move it is not a drag.
pub fn heldMouseButtonName(held: u8) ?[*:0]const u8 {
    return switch (held) {
        1 => "left",
        2 => "right",
        3 => "middle",
        4 => "x1",
        5 => "x2",
        else => null,
    };
}

/// Shared press/release/drag delivery for the main window and external
/// windows. Both resolve the cell the same way handleMouseWheel does: the
/// content offsets (titlebar tabline, left sidebar) belong to the main window
/// only, and an external window passes its own grid_id with window-local
/// coordinates, so the caller never has to know which convention it is in.
/// Which grid a surface-local point belongs to, and the point rebased into it.
pub const MouseTarget = struct { grid_id: i64, x: i32, y: i32 };

/// Resolve a surface-local pixel against the layers that surface composites,
/// back to front, so a click on a float reaches the float.
///
/// Neovim does no z-order test of its own once the UI names a grid: for a
/// grid > 1 it looks the window up by handle and CLAMPS the position into it
/// (nvim mouse.c, mouse_find_grid_win). Only grid 0 is hit-tested by the
/// compositor. So a surface that composites layers has to answer the question
/// itself or every click lands in the window behind the one under the pointer.
///
/// Which grid is chosen is the core's rule (`zonvie_core_resolve_pointer_grid`),
/// the one the wheel path and macOS use: it skips a grid that refuses the
/// mouse — Neovim rejects an event addressed to it without re-resolving —
/// and takes the front-most by the order the core sorts layers in. This used
/// to be a pixel loop here where the last layer in list order won, a third
/// rule beside the wheel's and macOS's. The pixel rebase into the chosen
/// layer stays local: `layers` is what this surface drew, and a grid the
/// cached snapshot names but the drawn list does not falls back to the root.
/// Caller holds app.mu, which is what the layer list is protected by;
/// `grids` is the non-blocking cached snapshot.
pub fn resolveMouseTarget(
    layers: []const app_mod.SurfaceLayer,
    grids: []const app_mod.GridInfo,
    root_grid_id: i64,
    x: i32,
    y: i32,
    cell_w: u32,
    row_h: u32,
) MouseTarget {
    const target = MouseTarget{ .grid_id = root_grid_id, .x = x, .y = y };
    if (cell_w == 0 or row_h == 0 or layers.len <= 1 or grids.len == 0) return target;
    var hit: app_mod.zonvie_pointer_hit = undefined;
    if (app_mod.zonvie_core_resolve_pointer_grid(
        grids.ptr,
        grids.len,
        root_grid_id,
        @divFloor(y, @as(i32, @intCast(row_h))),
        @divFloor(x, @as(i32, @intCast(cell_w))),
        0, // a click
        &hit,
    ) == 0) return target;
    return rebaseToGrid(layers, root_grid_id, hit.grid_id, x, y);
}

/// Rebase a surface-local point into the layer a press already chose, for the
/// drag and release that follow it. The layer's CURRENT origin is used, so a
/// float that moves mid-drag keeps receiving the right cells. A layer that has
/// gone falls back to the surface's own grid.
pub fn rebaseToGrid(
    layers: []const app_mod.SurfaceLayer,
    root_grid_id: i64,
    grid_id: i64,
    x: i32,
    y: i32,
) MouseTarget {
    if (grid_id == root_grid_id or grid_id == 0 or layers.len <= 1) {
        return .{ .grid_id = root_grid_id, .x = x, .y = y };
    }
    for (layers[1..]) |layer| {
        if (layer.grid_id != grid_id) continue;
        return .{ .grid_id = grid_id, .x = x - layer.x_px, .y = y - layer.y_px };
    }
    return .{ .grid_id = root_grid_id, .x = x, .y = y };
}

pub const MouseAction = enum {
    press,
    release,
    drag,

    fn name(self: MouseAction) [*:0]const u8 {
        return switch (self) {
            .press => "press",
            .release => "release",
            .drag => "drag",
        };
    }
};

/// `x`/`y` are SURFACE-local pixels -- layer-local when a hit test chose a
/// float, otherwise the surface origin already subtracted. The window handle is
/// no longer a parameter: it existed only to re-derive the chrome offset here,
/// which now happens once in the caller, before the layer rects are tested.
pub fn sendMouseButton(
    app: *App,
    grid_id: i64,
    button: [*:0]const u8,
    action: MouseAction,
    x: i32,
    y: i32,
    wParam: c.WPARAM,
) void {
    app.mu.lockUncancelable(core.clock.io());
    const cell_w = app.cell_w_px;
    const row_h = app.rowHeightPx();
    app.mu.unlock(core.clock.io());

    const drag = action == .drag;
    const cell = clientPxToCell(app, false, x, y, cell_w, row_h, drag);
    const mod_buf = buildMouseModifiers(wParam);

    // Where the mini window anchors itself next.
    app.last_mouse_grid_id = grid_id;

    core.zonvie_core_send_mouse_input(
        app.corep,
        button,
        action.name(),
        @as([*:0]const u8, @ptrCast(&mod_buf)),
        grid_id,
        if (drag) cell.row else @max(0, cell.row),
        if (drag) cell.col else @max(0, cell.col),
    );
}

/// Shared WM_MOUSEWHEEL / WM_MOUSEHWHEEL handler for the main window and
/// external windows. `grid_id` is the surface this hwnd draws — 1 for the main
/// window — and is all the core needs to resolve the target against, so this
/// no longer reaches for the surface's layer list or takes `app.mu`.
pub fn handleMouseWheel(
    hwnd: c.HWND,
    wParam: c.WPARAM,
    lParam: c.LPARAM,
    app: *App,
    grid_id: i64,
    horizontal: bool,
) void {
    // Extract scroll delta from high word of wParam
    const delta: i16 = @bitCast(@as(u16, @truncate(wParam >> 16)));
    if (delta == 0) return;

    // Get mouse position (in screen coordinates)
    const x_screen: i16 = @bitCast(@as(u16, @truncate(@as(usize, @bitCast(lParam)))));
    const y_screen: i16 = @bitCast(@as(u16, @truncate(@as(usize, @bitCast(lParam)) >> 16)));

    // Convert to client coordinates
    var pt: c.POINT = .{ .x = x_screen, .y = y_screen };
    _ = c.ScreenToClient(hwnd, &pt);

    // Get cell dimensions
    app.mu.lockUncancelable(core.clock.io());
    const cell_w = app.cell_w_px;
    const row_h = app.rowHeightPx();
    const corep = app.corep;
    app.mu.unlock(core.clock.io());

    // Calculate cell position (include linespace in row height).
    // Mirror the click handler's content-offset rules (window.zig WM_LBUTTONDOWN):
    // titlebar tabline shifts Y, left sidebar shifts X. External windows
    // (floating windows) have neither, so only apply offsets for the main window.
    const is_main_window = if (app.hwnd) |main_hwnd| hwnd == main_hwnd else false;
    const px: i32 = @intCast(pt.x);
    const py: i32 = @intCast(pt.y);
    // Clicks there are the chrome's; a wheel clamped its negative cell to 0
    // and scrolled whatever window sat at row 0 or column 0.
    if (is_main_window and pointInMainChrome(app, hwnd, px, py)) return;
    const cell = clientPxToCell(app, is_main_window, px, py, cell_w, row_h, false);
    const col = cell.col;
    const row = cell.row;

    // Resolve the scroll target on the main window: hit-test visible grids so
    // a wheel event over a composited grid (float/split) targets that grid
    // with grid-local coordinates, matching the URL-hover hit-test and macOS
    // resolveScrollTarget. An external window resolves against its own layer
    // list instead, below. Uses the non-blocking cached query, so no lock
    // contention is added to the input path.
    var target_grid_id: i64 = grid_id;
    var target_row: i32 = row;
    var target_col: i32 = col;
    {
        // The rule is the core's, for both surfaces and both frontends. It
        // used to be a loop here and another in macOS's MetalTerminalView, and
        // between them they held different parts of it: this one applied
        // neither the mouse flag nor the scrollability rule on the main
        // window, and that one hit-tested floats an external surface hosts.
        const grids: []const app_mod.GridInfo = if (corep) |cp| app.getVisibleGridsCached(cp) else &.{};
        var hit: app_mod.zonvie_pointer_hit = undefined;
        if (grids.len > 0 and app_mod.zonvie_core_resolve_pointer_grid(
            grids.ptr,
            grids.len,
            grid_id,
            row,
            col,
            1, // a wheel event: a float showing all its content lets it through
            &hit,
        ) != 0) {
            target_grid_id = hit.grid_id;
            target_row = hit.row;
            target_col = hit.col;
        }
    }

    // Build modifier string from wParam flags and GetKeyState
    const mod_buf = buildMouseModifiers(wParam);

    // Determine scroll direction
    // Vertical: positive delta = scroll up (wheel away from user)
    // Horizontal: positive delta = scroll right (wheel tilt right)
    const direction: [*:0]const u8 = if (horizontal)
        (if (delta > 0) "right" else "left")
    else
        (if (delta > 0) "up" else "down");

    // One scroll event per wheel message, with no WHEEL_DELTA accumulation: a
    // high-resolution touchpad moves the view on every delta it reports rather
    // than staying still until a full notch has built up. 'mousescroll' decides
    // how many lines each event travels, so a device that reports finely now
    // scrolls proportionally faster.
    app_mod.zonvie_core_send_mouse_scroll(corep, target_grid_id, target_row, target_col, direction, @as([*:0]const u8, @ptrCast(&mod_buf)));

    if (target_grid_id == app_mod.MESSAGE_GRID_ID) {
        if (app.hwnd) |main_hwnd| {
            _ = c.SetTimer(main_hwnd, app_mod.TIMER_MSG_SCROLL_RETRY, app_mod.MSG_SCROLL_RETRY_INTERVAL_MS, null);
        }
    }
}

// =========================================================================
// IME Helper Functions
// =========================================================================

/// Convert UTF-16 composition string to UTF-8.
/// Must be called with app.mu locked.
/// Decode the UTF-16 code unit at units[i], combining a surrogate pair when
/// present. Returns the codepoint and the number of units consumed (1 or 2).
fn decodeUtf16At(units: []const u16, i: usize) struct { cp: u21, consumed: usize } {
    const hi = units[i];
    if (hi >= 0xD800 and hi <= 0xDBFF and i + 1 < units.len) {
        const lo = units[i + 1];
        if (lo >= 0xDC00 and lo <= 0xDFFF) {
            const cp = 0x10000 + ((@as(u21, hi) - 0xD800) << 10) + (@as(u21, lo) - 0xDC00);
            return .{ .cp = cp, .consumed = 2 };
        }
    }
    return .{ .cp = @as(u21, hi), .consumed = 1 };
}

pub fn updateImeCompositionUtf8(app: *App) void {
    app.ime_composition_utf8.clearRetainingCapacity();

    const units = app.ime_composition_str.items;
    var i: usize = 0;
    while (i < units.len) {
        const d = decodeUtf16At(units, i);
        i += d.consumed;
        // Skip a lone surrogate that could not be combined.
        if (d.cp >= 0xD800 and d.cp <= 0xDFFF) continue;
        var buf: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(d.cp, &buf) catch continue;
        app.ime_composition_utf8.appendSlice(app.alloc, buf[0..n]) catch continue;
    }
}

/// UTF-8 byte length of the first `unit_count` UTF-16 code units of `units`,
/// decoding surrogate pairs. Used to map an IME clause boundary (a UTF-16 unit
/// index) to a byte offset into the UTF-8 composition string, matching
/// updateImeCompositionUtf8's encoding.
pub fn utf16PrefixUtf8Len(units: []const u16, unit_count: usize) usize {
    const end = @min(unit_count, units.len);
    var n: usize = 0;
    var i: usize = 0;
    while (i < end) {
        const d = decodeUtf16At(units, i);
        i += d.consumed;
        if (d.cp >= 0xD800 and d.cp <= 0xDFFF) continue;
        var buf: [4]u8 = undefined;
        n += std.unicode.utf8Encode(d.cp, &buf) catch 0;
    }
    return n;
}

/// Position IME candidate window at cursor location.
pub fn positionImeCandidateWindow(hwnd: c.HWND, app: *App) void {
    const himc = c.ImmGetContext(hwnd);
    if (himc == null) return;
    defer _ = c.ImmReleaseContext(hwnd, himc);

    // Get cursor position and cell metrics from core
    app.mu.lockUncancelable(core.clock.io());
    const corep = app.corep;
    const cell_w = app.cell_w_px;
    const cell_h = app.cell_h_px;
    const row_h_px = app.rowHeightPx();
    const main_hwnd = app.hwnd;
    app.mu.unlock(core.clock.io());

    if (corep == null) return;

    // Row height includes linespace (for row positioning)
    const row_h: i32 = @intCast(row_h_px);

    var row: i32 = 0;
    var col: i32 = 0;
    const grid_id = getCursorPositionNonBlocking(app, corep.?, &row, &col, null);

    // A cold cache under lock contention yields (-1,-1); skip positioning
    // rather than placing the candidate window at negative coordinates
    // (macOS counterpart checks cursor.row >= 0 the same way).
    if (row < 0 or col < 0) return;

    // Check if cursor is on an external window's grid (e.g. ext-cmdline).
    // If so, we need to calculate screen coordinates via that window, then convert
    // back to the IME hwnd's client coordinates. Otherwise the candidate window
    // appears behind the topmost external window and is invisible.
    const ext_surface = blk: {
        app.mu.lockUncancelable(core.clock.io());
        defer app.mu.unlock(core.clock.io());
        break :blk imeExternalSurfaceLocked(app, grid_id);
    };

    if (ext_surface) |es| {
        const ehwnd = es.hwnd;
        // Cursor is on an external grid — position via that window's client area.
        const decorated_origin = imeDecoratedOrigin(app, es);
        const cmdline_x_offset: c.LONG = decorated_origin[0];
        const cmdline_y_offset: c.LONG = decorated_origin[1];

        // Grid-local pixel position within the external window's client
        // area, plus where a hosted float sits in it.
        const local_x: c.LONG = es.x_px + col * @as(c.LONG, @intCast(cell_w)) + cmdline_x_offset;
        const local_cursor_y: c.LONG = es.y_px + row * row_h + cmdline_y_offset;
        const local_below_y: c.LONG = local_cursor_y + @as(c.LONG, @intCast(cell_h));

        // Convert external window client coords → screen → IME hwnd client coords
        var pt_cursor: c.POINT = .{ .x = local_x, .y = local_cursor_y };
        var pt_below: c.POINT = .{ .x = local_x, .y = local_below_y };
        _ = c.ClientToScreen(ehwnd, &pt_cursor);
        _ = c.ClientToScreen(ehwnd, &pt_below);
        _ = c.ScreenToClient(hwnd, &pt_cursor);
        _ = c.ScreenToClient(hwnd, &pt_below);

        var cf: c.COMPOSITIONFORM = undefined;
        cf.dwStyle = c.CFS_POINT;
        cf.ptCurrentPos = .{ .x = pt_cursor.x, .y = pt_cursor.y };
        _ = c.ImmSetCompositionWindow(himc, &cf);

        var candidate_form: c.CANDIDATEFORM = undefined;
        candidate_form.dwIndex = 0;
        candidate_form.dwStyle = c.CFS_CANDIDATEPOS;
        candidate_form.ptCurrentPos = .{ .x = pt_below.x, .y = pt_below.y };
        _ = c.ImmSetCandidateWindow(himc, &candidate_form);
    } else {
        // Cursor is on a main-window grid — use startRow/startCol offset.
        const cached = app.getVisibleGridsCached(corep.?);

        var screen_row: i32 = row;
        var screen_col: i32 = col;

        for (cached) |grid| {
            if (grid.grid_id == grid_id) {
                screen_row = grid.start_row + row;
                screen_col = grid.start_col + col;
                break;
            }
        }

        // In the MAIN window's client area: the surface starts below a
        // titlebar tab bar and right of a left sidebar — the rule the paint
        // and the mouse use. Adding the tab bar for every tabline style put
        // the candidate a bar too low under a sidebar and never moved it right.
        const origin = surfaceOriginPx(app, true);
        const x: c.LONG = origin.x + @as(c.LONG, @intCast(screen_col * @as(i32, @intCast(cell_w))));
        const cursor_y: c.LONG = origin.y + @as(c.LONG, @intCast(screen_row * row_h));
        var pt_cursor: c.POINT = .{ .x = x, .y = cursor_y };
        var pt_below: c.POINT = .{ .x = x, .y = cursor_y + @as(c.LONG, @intCast(cell_h)) };
        // Then into the client area of the window IME is attached to, which
        // is another window when focus sits in an external one: the preedit
        // overlay converts through the main window too.
        if (main_hwnd) |mh| {
            if (mh != hwnd) {
                _ = c.ClientToScreen(mh, &pt_cursor);
                _ = c.ClientToScreen(mh, &pt_below);
                _ = c.ScreenToClient(hwnd, &pt_cursor);
                _ = c.ScreenToClient(hwnd, &pt_below);
            }
        }

        var cf: c.COMPOSITIONFORM = undefined;
        cf.dwStyle = c.CFS_POINT;
        cf.ptCurrentPos = pt_cursor;
        _ = c.ImmSetCompositionWindow(himc, &cf);

        var candidate_form: c.CANDIDATEFORM = undefined;
        candidate_form.dwIndex = 0;
        candidate_form.dwStyle = c.CFS_CANDIDATEPOS;
        candidate_form.ptCurrentPos = pt_below;
        _ = c.ImmSetCandidateWindow(himc, &candidate_form);
    }
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

/// Wide string constant for "STATIC" window class
const ime_overlay_class: [:0]const u16 = std.unicode.utf8ToUtf16LeStringLiteral("STATIC");

/// HWND_TOPMOST is ((HWND)-1); translate-c's cast of -1 to HWND ([*c]HWND__,
/// align 4) trips Zig's pointer alignment check. Win32 USER handles are opaque
/// values, never dereferenced, so redeclare SetWindowPos with an align-agnostic
/// insert-after pointer (same approach as LoadIconW in main.zig).
const HWND_TOPMOST: *const anyopaque = @ptrFromInt(std.math.maxInt(usize));
extern "user32" fn SetWindowPos(hWnd: c.HWND, hWndInsertAfter: ?*const anyopaque, X: c_int, Y: c_int, cx: c_int, cy: c_int, uFlags: c.UINT) callconv(.winapi) c.BOOL;

/// Create or update the IME preedit overlay window using layered window.
pub fn updateImePreeditOverlay(hwnd: c.HWND, app: *App) void {
    app.mu.lockUncancelable(core.clock.io());
    const composing = app.ime_composing;
    const comp_len = app.ime_composition_str.items.len;
    const extmark_active = app.ime_extmark_active;
    app.mu.unlock(core.clock.io());

    const log_active = applog.isEnabled();
    if (log_active) applog.appLog("[IME] updateImePreeditOverlay composing={d} comp_len={d} extmark={d}\n", .{ @intFromBool(composing), comp_len, @intFromBool(extmark_active) });

    // Hide overlay if not composing, or if the preedit is rendered inline by the
    // core via an extmark (the overlay would otherwise double the preedit).
    if (!composing or comp_len == 0 or extmark_active) {
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

    app.mu.lockUncancelable(core.clock.io());
    const corep = app.corep;
    const cell_w = app.cell_w_px;
    const cell_h = app.cell_h_px;
    const row_h_px = app.rowHeightPx();
    const comp_str = app.ime_composition_str.items;
    const target_start = app.ime_target_start;
    const target_end = app.ime_target_end;
    atlas_ptr = if (app.atlas) |*a| a else null;
    atlas_cell_w = cell_w;
    atlas_cell_h = cell_h;
    const content_hwnd = app.content_hwnd;
    const main_hwnd = app.hwnd;
    app.mu.unlock(core.clock.io());

    // Access atlas without holding app.mu to avoid nested locking
    if (atlas_ptr) |atlas| {
        atlas.mu.lockUncancelable(core.clock.io());
        defer atlas.mu.unlock(core.clock.io());
        @memcpy(&font_name_buf, &atlas.font_name);
        atlas_cell_w = atlas.cell_w_px;
        atlas_cell_h = atlas.cell_h_px;
        font_em_size = atlas.font_em_size;
    }

    if (corep == null) {
        if (log_active) applog.appLog("[IME] corep is null\n", .{});
        return;
    }

    // Validate cell dimensions
    if (cell_w == 0 or cell_h == 0) {
        if (log_active) applog.appLog("[IME] cell dimensions are 0\n", .{});
        return;
    }

    // Row height includes linespace
    const row_h: u32 = row_h_px;

    var row: i32 = 0;
    var col: i32 = 0;
    const grid_id = getCursorPositionNonBlocking(app, corep.?, &row, &col, null);

    // The window that shows the cursor's grid, as the candidate window finds
    // it. This asked whether the window with focus was an external one, so a
    // float an external window hosts was placed at its grid-local position.
    const ext_surface = blk: {
        app.mu.lockUncancelable(core.clock.io());
        defer app.mu.unlock(core.clock.io());
        break :blk imeExternalSurfaceLocked(app, grid_id);
    };
    const is_external_window = ext_surface != null;

    var screen_row: i32 = row;
    var screen_col: i32 = col;

    // For external windows, use grid-local coordinates directly
    // For main window, add start_row/start_col to get screen position
    if (!is_external_window) {
        // Get grid info to calculate screen position (non-blocking)
        const cached = app.getVisibleGridsCached(corep.?);

        for (cached) |grid| {
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

    // A cold cursor-position cache under lock contention yields (-1,-1);
    // keep the overlay's previous position rather than drawing off-window.
    if (row < 0 or col < 0) return;

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

    // Convert client position to screen position (use row_h for Y position),
    // past a decorated surface's icon strip and padding.
    const decorated_origin = imeDecoratedOrigin(app, ext_surface);
    const cmdline_x_offset: c.LONG = decorated_origin[0];
    const cmdline_y_offset: c.LONG = decorated_origin[1];

    var pt: c.POINT = .{
        .x = screen_col * @as(c.LONG, @intCast(cell_w)) + cmdline_x_offset,
        .y = screen_row * @as(c.LONG, @intCast(row_h)) + cmdline_y_offset,
    };
    // An external window's coordinates are relative to its own client area,
    // plus where a hosted float sits in it. The main window's start at the
    // surface origin (below a titlebar tab bar, right of a left sidebar),
    // or in content_hwnd when a child window hosts the content.
    var coord_hwnd: c.HWND = hwnd;
    if (ext_surface) |es| {
        coord_hwnd = es.hwnd;
        pt.x += es.x_px;
        pt.y += es.y_px;
    } else if (content_hwnd) |ch| {
        coord_hwnd = ch;
    } else {
        if (main_hwnd) |mh| coord_hwnd = mh;
        const origin = surfaceOriginPx(app, true);
        pt.x += origin.x;
        pt.y += origin.y;
    }
    _ = c.ClientToScreen(coord_hwnd, &pt);

    if (log_active) applog.appLog("[IME] overlay pos=({d},{d}) size=({d},{d}) text_w={d} cell=({d},{d}) row_h={d}\n", .{ pt.x, pt.y, overlay_width, overlay_height, text_size.cx, cell_w, cell_h, row_h });

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
            if (log_active) applog.appLog("[IME] CreateWindowExW failed\n", .{});
            return;
        }
        app.ime_overlay_hwnd = new_overlay;
        if (log_active) applog.appLog("[IME] created overlay window\n", .{});
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

    if (log_active) applog.appLog("[IME] overlay draw: target_start={d} target_end={d} comp_len={d}\n", .{ target_start, target_end, comp_str.len });

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

        if (log_active) applog.appLog("[IME] underline: start_x={d} end_x={d}\n", .{ target_start_x, target_end_x });

        if (target_end_x > target_start_x) {
            const old_pen = c.SelectObject(mem_dc, pen_target);
            const underline_y = overlay_height - 2;
            _ = c.MoveToEx(mem_dc, target_start_x, underline_y, null);
            _ = c.LineTo(mem_dc, target_end_x, underline_y);
            _ = c.SelectObject(mem_dc, old_pen);
        }
    }

    // Update the layered window.
    // AlphaFormat = 0 (not AC_SRC_ALPHA): ignore per-pixel alpha channel.
    // GDI text rendering destroys alpha on 32-bit DIBs, but with AlphaFormat=0
    // only SourceConstantAlpha (255 = fully opaque) is used, so that's harmless.
    var blend: c.BLENDFUNCTION = .{
        .BlendOp = c.AC_SRC_OVER,
        .BlendFlags = 0,
        .SourceConstantAlpha = 255,
        .AlphaFormat = 0,
    };

    var src_pt: c.POINT = .{ .x = 0, .y = 0 };
    var wnd_size: c.SIZE = .{ .cx = overlay_width, .cy = overlay_height };

    // Re-assert the top of the topmost band on every show: external windows
    // (e.g. ext-cmdline) are also WS_EX_TOPMOST and may have been created or
    // brought to foreground after this overlay was created, which would leave
    // the overlay hidden behind them if SWP_NOZORDER were used.
    _ = SetWindowPos(
        overlay,
        HWND_TOPMOST,
        pt.x,
        pt.y,
        overlay_width,
        overlay_height,
        c.SWP_NOACTIVATE | c.SWP_SHOWWINDOW,
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

    if (log_active) applog.appLog("[IME] overlay updated\n", .{});
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
        if (applog.isEnabled()) applog.appLog("[blink] on_ms=0, not blinking\n", .{});
        return;
    }

    app.cursor_blink_wait_ms = wait_ms;
    app.cursor_blink_on_ms = on_ms;
    app.cursor_blink_off_ms = off_ms;

    // Start with wait phase if wait_ms > 0
    if (wait_ms > 0) {
        if (applog.isEnabled()) applog.appLog("[blink] starting with wait_ms={d}\n", .{wait_ms});
        app.cursor_blink_phase = 0;
        app.cursor_blink_state = true;
        const timer_result = c.SetTimer(hwnd, app_mod.TIMER_CURSOR_BLINK, wait_ms, null);
        if (applog.isEnabled()) applog.appLog("[blink] SetTimer result={d}\n", .{timer_result});
        app.cursor_blink_timer = timer_result;
    } else {
        // No wait, start blinking immediately
        enterBlinkCycle(hwnd, app);
    }
}

/// Enter the on/off blink cycle
pub fn enterBlinkCycle(hwnd: c.HWND, app: *App) void {
    if (applog.isEnabled()) applog.appLog("[blink] enterBlinkCycle\n", .{});
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
        if (applog.isEnabled()) applog.appLog("[blink] interval=0, stopping\n", .{});
        return;
    }

    if (applog.isEnabled()) applog.appLog("[blink] scheduleNextBlink: is_on={} interval={d}ms\n", .{ is_currently_on, interval });
    app.cursor_blink_timer = c.SetTimer(hwnd, app_mod.TIMER_CURSOR_BLINK, interval, null);
}

/// Handle cursor blink timer event
pub fn handleCursorBlinkTimer(hwnd: c.HWND, app: *App) void {
    _ = c.KillTimer(hwnd, app_mod.TIMER_CURSOR_BLINK);
    app.cursor_blink_timer = 0;
    // Minimized or covered since the last tick: stop here, within one
    // interval, rather than hooking every way a window can stop showing.
    if (!cursorBlinkAllowed(app)) {
        pauseCursorBlinking(hwnd, app);
        return;
    }

    if (app.cursor_blink_phase == 0) {
        // Wait phase complete, enter blink cycle
        enterBlinkCycle(hwnd, app);
    } else {
        // Toggle blink state
        app.cursor_blink_state = !app.cursor_blink_state;
        if (applog.isEnabled()) applog.appLog("[blink] toggled to {}\n", .{app.cursor_blink_state});

        // Update external windows blink state
        updateExternalWindowsBlinkState(app);

        // Request repaint for cursor area. No rect means this window holds no
        // cursor (it is in an external window), so a blink toggle changes no
        // pixel here; a whole-window invalidate would present the full frame.
        app.mu.lockUncancelable(core.clock.io());
        const cursor_rect_snapshot = app.last_cursor_rect_px;
        app.mu.unlock(core.clock.io());
        if (cursor_rect_snapshot) |rect| {
            _ = c.InvalidateRect(hwnd, &rect, c.FALSE);
        }

        // Schedule next blink
        scheduleNextBlink(hwnd, app, app.cursor_blink_state);
    }
}

/// Whether the blink timer may run: this process is in front and the window
/// showing the cursor is visible and not minimized -- macOS's
/// `cursorBlinkAllowed`. The timer used to run regardless, repainting a
/// window in the background or in the taskbar twice a second.
fn cursorBlinkAllowed(app: *App) bool {
    const foreground = c.GetForegroundWindow() orelse return false;
    var foreground_pid: c.DWORD = 0;
    _ = c.GetWindowThreadProcessId(foreground, &foreground_pid);
    if (foreground_pid != c.GetCurrentProcessId()) return false;
    app.mu.lockUncancelable(core.clock.io());
    const holder: ?c.HWND = if (callbacks.externalWindowShowingGridLocked(app, app.last_cursor_grid)) |shown|
        shown.win.hwnd
    else
        app.hwnd;
    app.mu.unlock(core.clock.io());
    const h = holder orelse return false;
    return c.IsWindowVisible(h) != 0 and c.IsIconic(h) == 0;
}

/// Stop the timer and leave the cursor drawn. Stopping in the off phase left
/// the main window's cursor hidden until something else repainted it.
pub fn pauseCursorBlinking(hwnd: c.HWND, app: *App) void {
    const was_off = !app.cursor_blink_state;
    stopCursorBlinking(hwnd, app);
    if (!was_off) return;
    app.mu.lockUncancelable(core.clock.io());
    const cursor_rect = app.last_cursor_rect_px;
    app.mu.unlock(core.clock.io());
    if (cursor_rect) |rect| _ = c.InvalidateRect(hwnd, &rect, c.FALSE);
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
    // Pre-seed with the last-known values: try_get_cursor_blink leaves its
    // out params untouched on lock contention, so a busy lock here
    // naturally reads back as "unchanged since last time" below.
    var wait_ms: u32 = app.cursor_blink_wait_ms;
    var on_ms: u32 = app.cursor_blink_on_ms;
    var off_ms: u32 = app.cursor_blink_off_ms;

    if (app.corep) |core_ptr| {
        if (!app_mod.zonvie_core_try_get_cursor_blink(core_ptr, &wait_ms, &on_ms, &off_ms)) {
            // Lock busy. WM_APP_UPDATE_CURSOR_BLINK is one-shot and posted
            // while the core thread still holds grid_mu, so contention here
            // is structurally common; acting on the stale pre-seeded values
            // would silently drop the new blink settings. Retry shortly
            // (mirrors macOS's 16ms timer re-arm). Deliberately not re-posted if
            // SetTimer fails: the message would re-enter this handler with no
            // delay while the condition that failed SetTimer persists, spinning
            // the message loop ahead of WM_PAINT.
            _ = c.SetTimer(hwnd, app_mod.TIMER_CURSOR_BLINK_RETRY, app_mod.LOCK_RETRY_INTERVAL_MS, null);
            return;
        }
    }

    if (applog.isEnabled()) applog.appLog("[blink] updateCursorBlinking: wait={d} on={d} off={d} (current: wait={d} on={d} off={d})\n", .{ wait_ms, on_ms, off_ms, app.cursor_blink_wait_ms, app.cursor_blink_on_ms, app.cursor_blink_off_ms });

    // Check if blink settings changed
    const settings_changed = wait_ms != app.cursor_blink_wait_ms or
        on_ms != app.cursor_blink_on_ms or
        off_ms != app.cursor_blink_off_ms;

    // Check if timer is currently stopped
    const timer_stopped = app.cursor_blink_timer == 0;

    if (applog.isEnabled()) applog.appLog("[blink] settings_changed={}, on_ms>0={}, off_ms>0={}, timer_stopped={}\n", .{ settings_changed, on_ms > 0, off_ms > 0, timer_stopped });

    if (on_ms > 0 and off_ms > 0) {
        // Blink should be enabled -- where it can be seen. Gated here as well
        // as in the tick: a stopped timer reads as "restart" below, and every
        // cursor callback lands here.
        if (!cursorBlinkAllowed(app)) {
            if (!timer_stopped) pauseCursorBlinking(hwnd, app);
            return;
        }
        if (settings_changed or timer_stopped) {
            // Start/restart if settings changed OR timer was stopped (e.g., after mode change to non-blinking mode)
            if (applog.isEnabled()) applog.appLog("[blink] calling startCursorBlinking\n", .{});
            startCursorBlinking(hwnd, app, wait_ms, on_ms, off_ms);
        }
    } else {
        // Blink should be disabled
        if (settings_changed) {
            if (applog.isEnabled()) applog.appLog("[blink] calling stopCursorBlinking\n", .{});
            stopCursorBlinking(hwnd, app);
        }
    }
}

/// Update blink state for all external windows
pub fn updateExternalWindowsBlinkState(app: *App) void {
    var it = app.external_windows.iterator();
    while (it.next()) |entry| {
        const ext_win = entry.value_ptr.*;
        // Every surface tracks the state, because the one that gains the cursor
        // next must draw it in the phase the rest are in.
        ext_win.cursor_blink_state = app.cursor_blink_state;
        // Only the surface that actually holds a cursor repaints. A toggle
        // changes no pixel on the others, and the whole-window invalidate cost
        // each of them a no-op WM_PAINT — app.mu, a layer scan and a snapshot
        // acquire/release — twice a second, scaling with the window count. The
        // main window has always skipped its own invalidate the same way, on a
        // null `last_cursor_rect_px`.
        if (!ext_win.has_committed_cursor) continue;
        if (ext_win.hwnd) |ext_hwnd| {
            _ = c.InvalidateRect(ext_hwnd, null, c.FALSE);
        }
    }
}
