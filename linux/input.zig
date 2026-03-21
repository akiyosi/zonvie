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

    // Let IME handle the key first
    if (app.im_context) |im| {
        // TODO: forward to im_context_filter_keypress when GTK4 IME is wired
        _ = im;
    }

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
