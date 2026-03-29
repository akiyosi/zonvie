// input.zig — GTK4 keyboard, mouse, and IME input translation for Neovim.
//
// Signal handler callbacks use opaque pointers (no GTK type imports needed).
// GDK key constants and modifier masks from gtk_bindings.zig.

const std = @import("std");
const app_mod = @import("app.zig");
const App = app_mod.App;
const gtk_mod = app_mod.gtk_mod;
const applog = app_mod.applog;
const core = @import("zonvie_core");

// =========================================================================
// Modifier constants (match zonvie_core.h)
// =========================================================================

pub const MOD_CTRL: u32 = 1 << 0;
pub const MOD_ALT: u32 = 1 << 1;
pub const MOD_SHIFT: u32 = 1 << 2;
pub const MOD_SUPER: u32 = 1 << 3;

/// Keycode flag indicating a GDK keyval (not a raw scancode).
pub const KEYCODE_GDK_FLAG: u32 = 0x20000;

// =========================================================================
// GDK extern functions (resolved at link time)
// =========================================================================

extern "c" fn gdk_keyval_to_unicode(keyval: c_uint) u32;
extern "c" fn gdk_keyval_to_lower(keyval: c_uint) c_uint;

// =========================================================================
// Key event handling
// =========================================================================

/// Convert GDK modifier state to Neovim modifier bitmask.
pub fn gdkModsToNeovim(state: c_uint) u32 {
    var m: u32 = 0;
    if ((state & gtk_mod.GDK_CONTROL_MASK) != 0) m |= MOD_CTRL;
    if ((state & gtk_mod.GDK_ALT_MASK) != 0) m |= MOD_ALT;
    if ((state & gtk_mod.GDK_SHIFT_MASK) != 0) m |= MOD_SHIFT;
    if ((state & gtk_mod.GDK_SUPER_MASK) != 0) m |= MOD_SUPER;
    return m;
}

/// Send a key event to the core.
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

/// Convert a GDK keyval to a Windows VK code for core compatibility.
/// Returns null if the keyval is not a recognized special key.
pub fn gdkKeyvalToWinVk(keyval: c_uint) ?u32 {
    return switch (keyval) {
        gtk_mod.GDK_KEY_Left => 0x25,       // VK_LEFT
        gtk_mod.GDK_KEY_Up => 0x26,          // VK_UP
        gtk_mod.GDK_KEY_Right => 0x27,       // VK_RIGHT
        gtk_mod.GDK_KEY_Down => 0x28,        // VK_DOWN
        gtk_mod.GDK_KEY_Home => 0x24,        // VK_HOME
        gtk_mod.GDK_KEY_End => 0x23,         // VK_END
        gtk_mod.GDK_KEY_Page_Up => 0x21,     // VK_PRIOR
        gtk_mod.GDK_KEY_Page_Down => 0x22,   // VK_NEXT
        gtk_mod.GDK_KEY_Insert => 0x2D,      // VK_INSERT
        gtk_mod.GDK_KEY_Delete => 0x2E,      // VK_DELETE
        gtk_mod.GDK_KEY_BackSpace => 0x08,   // VK_BACK
        gtk_mod.GDK_KEY_Tab => 0x09,         // VK_TAB
        gtk_mod.GDK_KEY_Return => 0x0D,      // VK_RETURN
        gtk_mod.GDK_KEY_Escape => 0x1B,      // VK_ESCAPE
        gtk_mod.GDK_KEY_F1 => 0x70,          // VK_F1
        gtk_mod.GDK_KEY_F2 => 0x71,
        gtk_mod.GDK_KEY_F3 => 0x72,
        gtk_mod.GDK_KEY_F4 => 0x73,
        gtk_mod.GDK_KEY_F5 => 0x74,
        gtk_mod.GDK_KEY_F6 => 0x75,
        gtk_mod.GDK_KEY_F7 => 0x76,
        gtk_mod.GDK_KEY_F8 => 0x77,
        gtk_mod.GDK_KEY_F9 => 0x78,
        gtk_mod.GDK_KEY_F10 => 0x79,
        gtk_mod.GDK_KEY_F11 => 0x7A,
        gtk_mod.GDK_KEY_F12 => 0x7B,
        else => null,
    };
}

/// Convert a GDK keyval to UTF-8 in a stack buffer.
/// Returns the UTF-8 slice, or null if the keyval has no printable character.
pub fn keyvalToUtf8(buf: *[8]u8, keyval: c_uint) ?[]const u8 {
    const cp: u32 = gdk_keyval_to_unicode(keyval);
    if (cp == 0) return null;
    if (cp > 0x10FFFF) return null;
    const n = std.unicode.utf8Encode(@intCast(cp), buf) catch return null;
    return buf[0..n];
}

/// GTK4 key-pressed signal handler.
/// Signature: gboolean(GtkEventControllerKey*, guint keyval, guint keycode, GdkModifierType state, gpointer user_data)
pub fn onKeyPressed(
    controller: ?*anyopaque,
    keyval: c_uint,
    keycode: c_uint,
    state: c_uint,
    user_data: ?*anyopaque,
) callconv(.c) c_int {
    _ = controller;
    _ = keycode;
    const app: *App = @ptrCast(@alignCast(user_data orelse return 0));

    // IME filtering is handled by GTK4 automatically via
    // gtk_event_controller_key_set_im_context. When IME consumes a key,
    // this signal handler is not called — the committed text arrives
    // via the "commit" signal instead.

    const mods = gdkModsToNeovim(state);

    // For special keys, convert GDK keyval to Windows VK code for core compatibility
    if (gdkKeyvalToWinVk(keyval)) |vk| {
        sendKeyEventToCore(app, vk | 0x10000, mods, null, null);
        return 1; // TRUE
    }

    // Get UTF-8 representation
    var chars_buf: [8]u8 = undefined;
    const chars = keyvalToUtf8(&chars_buf, keyval);

    // For chars_ignoring_mods, strip Ctrl/Alt and get base character
    var ign_buf: [8]u8 = undefined;
    var ign: ?[]const u8 = null;
    if (mods & (MOD_CTRL | MOD_ALT) != 0) {
        // Get the keyval without modifiers for chars_ignoring_mods
        const lower_kv = gdk_keyval_to_lower(keyval);
        ign = keyvalToUtf8(&ign_buf, lower_kv);
    }

    if (chars != null or mods != 0) {
        sendKeyEventToCore(app, keyval | KEYCODE_GDK_FLAG, mods, chars, ign);
        return 1; // TRUE
    }

    return 0; // FALSE
}

// =========================================================================
// Mouse event handling
// =========================================================================

/// Convert pixel coordinates to grid row/col.
fn pixelToGrid(app: *const App, x: f64, y: f64) struct { row: i32, col: i32 } {
    const cell_w: f64 = @floatFromInt(@max(1, app.cell_w_px));
    const cell_h: f64 = @floatFromInt(@max(1, app.cell_h_px + app.linespace_px));
    return .{
        .row = @intFromFloat(@max(0, y / cell_h)),
        .col = @intFromFloat(@max(0, x / cell_w)),
    };
}

/// GTK4 mouse button pressed signal handler.
pub fn onMousePressed(
    gesture: ?*anyopaque,
    n_press: c_int,
    x: f64,
    y: f64,
    user_data: ?*anyopaque,
) callconv(.c) void {
    _ = gesture;
    const app: *App = @ptrCast(@alignCast(user_data orelse return));
    if (app.corep == null) return;

    // Check scrollbar hit
    if (scrollbarHitTest(app, x, y)) {
        startScrollbarDrag(app, y);
        return;
    }

    const pos = pixelToGrid(app, x, y);

    const button: [*c]const u8 = if (n_press == 2) "left" else "left";
    const action: [*c]const u8 = if (n_press == 2) "press" else "press";
    app_mod.zonvie_core_send_mouse_input(
        app.corep,
        button,
        action,
        "",
        1, // main grid
        pos.row,
        pos.col,
    );
}

/// GTK4 mouse button released signal handler.
pub fn onMouseReleased(
    gesture: ?*anyopaque,
    n_press: c_int,
    x: f64,
    y: f64,
    user_data: ?*anyopaque,
) callconv(.c) void {
    _ = gesture;
    _ = n_press;
    const app: *App = @ptrCast(@alignCast(user_data orelse return));
    if (app.corep == null) return;

    if (app.scrollbar.dragging) {
        endScrollbarDrag(app, y);
        return;
    }

    const pos = pixelToGrid(app, x, y);
    app_mod.zonvie_core_send_mouse_input(
        app.corep,
        "left",
        "release",
        "",
        1,
        pos.row,
        pos.col,
    );
}

/// GTK4 mouse motion signal handler.
pub fn onMouseMotion(
    controller: ?*anyopaque,
    x: f64,
    y: f64,
    user_data: ?*anyopaque,
) callconv(.c) void {
    _ = controller;
    const app: *App = @ptrCast(@alignCast(user_data orelse return));
    if (app.corep == null) return;

    if (app.scrollbar.dragging) {
        updateScrollbarDrag(app, y);
        return;
    }

    const pos = pixelToGrid(app, x, y);
    app_mod.zonvie_core_send_mouse_input(
        app.corep,
        "left",
        "drag",
        "",
        1,
        pos.row,
        pos.col,
    );
}

// =========================================================================
// Scrollbar drag handling
// =========================================================================

fn scrollbarHitTest(app: *const App, x: f64, y: f64) bool {
    if (!app.scrollbar.visible) return false;
    const vp_w: f32 = @floatFromInt(app.drawable_w_px);
    const sb_w = app_mod.scrollbarWidth(app.dpi_scale);
    const sb_margin = app_mod.scrollbarMargin(app.dpi_scale);
    const track_x = vp_w - sb_w - sb_margin;
    return @as(f32, @floatCast(x)) >= track_x and @as(f32, @floatCast(y)) >= sb_margin;
}

fn startScrollbarDrag(app: *App, y: f64) void {
    const vp_h: f32 = @floatFromInt(app.drawable_h_px);
    const sb_margin = app_mod.scrollbarMargin(app.dpi_scale);
    const track_h = vp_h - sb_margin * 2.0;
    if (track_h <= 0) return;

    // Check if click is on the knob or on the track
    const click_in_track: f32 = (@as(f32, @floatCast(y)) - sb_margin) / track_h;
    const knob_top = app.scrollbar.knob_top;
    const knob_bottom = knob_top + app.scrollbar.knob_height;

    if (click_in_track >= knob_top and click_in_track <= knob_bottom) {
        // Clicked on knob — start drag from current position
        app.scrollbar.drag_start_knob_top = knob_top;
    } else {
        // Clicked on track — jump knob to click position
        app.scrollbar.drag_start_knob_top = click_in_track;
        // Immediately scroll to that position
        updateScrollbarDrag(app, y);
    }

    app.scrollbar.dragging = true;
    app.scrollbar.drag_start_y = @floatCast(y);
}

fn updateScrollbarDrag(app: *App, y: f64) void {
    const corep = app.corep orelse return;
    const vp_h: f32 = @floatFromInt(app.drawable_h_px);
    const sb_margin = app_mod.scrollbarMargin(app.dpi_scale);
    const track_h = vp_h - sb_margin * 2.0;
    if (track_h <= 0) return;

    const dy: f32 = @as(f32, @floatCast(y)) - app.scrollbar.drag_start_y;
    const scroll_ratio = std.math.clamp(app.scrollbar.drag_start_knob_top + dy / track_h, 0.0, 1.0);

    // Throttle RPC calls (100ms)
    const now = std.time.milliTimestamp();
    if (now - app.scrollbar_last_scroll_time < 100) return;
    app.scrollbar_last_scroll_time = now;

    const line_count = app.scrollbar.linecount;
    if (line_count <= 0) return;

    const target_line: i64 = @intFromFloat(scroll_ratio * @as(f32, @floatFromInt(line_count)));
    const use_bottom: bool = scroll_ratio >= 0.5;
    app_mod.zonvie_core_scroll_to_line(corep, @max(1, target_line), use_bottom);
}

fn endScrollbarDrag(app: *App, y: f64) void {
    // Flush final position
    updateScrollbarDrag(app, y);
    app.scrollbar.dragging = false;
}

/// GTK4 scroll signal handler (mouse wheel).
pub fn onScroll(
    controller: ?*anyopaque,
    dx: f64,
    dy: f64,
    user_data: ?*anyopaque,
) callconv(.c) c_int {
    _ = controller;
    _ = dx;
    const app: *App = @ptrCast(@alignCast(user_data orelse return 0));
    if (app.corep == null) return 0;

    // Get cursor position for scroll target
    var cursor_row: i32 = 0;
    var cursor_col: i32 = 0;
    _ = app_mod.zonvie_core_get_cursor_position(app.corep, &cursor_row, &cursor_col);

    const direction: [*c]const u8 = if (dy < 0) "up" else "down";
    app_mod.zonvie_core_send_mouse_scroll(
        app.corep,
        1, // main grid
        cursor_row,
        cursor_col,
        direction,
        "",
    );

    return 1; // TRUE
}

// =========================================================================
// IME handling
// =========================================================================

/// GTK4 IMContext "commit" signal handler.
/// Called when IME composition is confirmed — the committed string should
/// be sent to Neovim as regular input.
pub fn onIMECommit(
    im_context: ?*anyopaque,
    str_ptr: ?[*:0]const u8,
    user_data: ?*anyopaque,
) callconv(.c) void {
    _ = im_context;
    const app: *App = @ptrCast(@alignCast(user_data orelse return));
    if (app.corep == null) return;

    const text = if (str_ptr) |s| std.mem.span(s) else return;
    if (text.len == 0) return;

    if (applog.isEnabled()) applog.appLog("[linux] IME commit: \"{s}\" len={d}\n", .{ text, text.len });

    // Hide preedit overlay
    hidePreeditOverlay(app);

    // Send committed text to core as raw input
    app_mod.zonvie_core_send_input(app.corep, text.ptr, text.len);
}

/// GTK4 IMContext "preedit-changed" signal handler.
/// Retrieves preedit string and displays it at the cursor position.
pub fn onIMEPreeditChanged(
    im_context: ?*anyopaque,
    user_data: ?*anyopaque,
) callconv(.c) void {
    const app: *App = @ptrCast(@alignCast(user_data orelse return));
    const im = im_context orelse return;
    const main = @import("main.zig");
    const gtk = main.gtk_externs;

    // Get cursor position from core
    var cursor_row: i32 = 0;
    var cursor_col: i32 = 0;
    if (app.corep) |corep| {
        _ = app_mod.zonvie_core_get_cursor_position(corep, &cursor_row, &cursor_col);
    }

    const cell_w: i32 = @intCast(app.cell_w_px);
    const cell_h: i32 = @intCast(app.cell_h_px + app.linespace_px);

    // Set cursor location for candidate window positioning
    var rect = main.GdkRectangle{
        .x = cursor_col * cell_w,
        .y = cursor_row * cell_h,
        .width = cell_w,
        .height = cell_h,
    };
    gtk.im_context_set_cursor_location(im, &rect);

    // Get preedit string
    var preedit_str: ?[*:0]u8 = null;
    var attrs: ?*anyopaque = null;
    var cursor_pos: c_int = 0;
    gtk.im_context_get_preedit_string(im, &preedit_str, &attrs, &cursor_pos);
    defer if (attrs) |a| gtk.attr_list_unref(a);
    defer if (preedit_str) |s| g_free(@ptrCast(s));

    const preedit_text = if (preedit_str) |s| std.mem.span(s) else "";

    if (preedit_text.len == 0) {
        hidePreeditOverlay(app);
        return;
    }

    if (applog.isEnabled()) applog.appLog("[linux] IME preedit: \"{s}\" cursor={d}\n", .{ preedit_text, cursor_pos });

    // Show preedit overlay at cursor position
    const label = app.preedit_label orelse return;

    // Build Pango markup: text with underline, cursor position highlighted
    // Split text at cursor_pos (byte offset from GTK) to show cursor
    var markup_buf: [1024]u8 = undefined;
    var markup_len: usize = 0;

    // Find the byte offset for cursor_pos (which is in characters)
    var char_count: usize = 0;
    var byte_offset: usize = 0;
    const cursor_byte = blk: {
        while (byte_offset < preedit_text.len and char_count < @as(usize, @intCast(cursor_pos))) {
            const b = preedit_text[byte_offset];
            const seq_len: usize = if (b < 0x80) 1 else if (b < 0xE0) 2 else if (b < 0xF0) 3 else 4;
            byte_offset += @min(seq_len, preedit_text.len - byte_offset);
            char_count += 1;
        }
        break :blk byte_offset;
    };

    // Markup: <u>before_cursor</u><u><b>|</b></u><u>after_cursor</u>
    // Actually simpler: just underline everything, the CSS border handles it
    // Use Pango markup for underline
    const prefix = "<u>";
    const suffix = "</u>";
    if (prefix.len + preedit_text.len + suffix.len < markup_buf.len) {
        @memcpy(markup_buf[0..prefix.len], prefix);
        markup_len = prefix.len;

        // Escape XML special chars in preedit text
        for (preedit_text) |c| {
            if (markup_len >= markup_buf.len - 10) break;
            switch (c) {
                '<' => {
                    @memcpy(markup_buf[markup_len..][0..4], "&lt;");
                    markup_len += 4;
                },
                '>' => {
                    @memcpy(markup_buf[markup_len..][0..4], "&gt;");
                    markup_len += 4;
                },
                '&' => {
                    @memcpy(markup_buf[markup_len..][0..5], "&amp;");
                    markup_len += 5;
                },
                else => {
                    markup_buf[markup_len] = c;
                    markup_len += 1;
                },
            }
        }
        @memcpy(markup_buf[markup_len..][0..suffix.len], suffix);
        markup_len += suffix.len;
        markup_buf[markup_len] = 0;

        gtk.label_set_markup(label, @ptrCast(&markup_buf));
    } else {
        // Fallback: just set plain text
        if (preedit_str) |s| {
            gtk.label_set_text(label, s);
        }
    }

    _ = cursor_byte;

    // Position the label at cursor location via margins
    gtk.widget_set_margin_start(label, cursor_col * cell_w);
    gtk.widget_set_margin_top(label, cursor_row * cell_h + cell_h);
    gtk.widget_set_visible(label, 1);
}

fn hidePreeditOverlay(app: *App) void {
    const main = @import("main.zig");
    if (app.preedit_label) |label| {
        main.gtk_externs.label_set_text(label, "");
        main.gtk_externs.widget_set_visible(label, 0);
    }
}

extern "c" fn g_free(ptr: ?*anyopaque) void;
