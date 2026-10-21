// gtk_bindings.zig — GTK4/GDK4/GLib constants and extern declarations for Linux frontend.
//
// Defines GDK key/modifier constants and GLib helper function declarations.
// All GTK function calls use hand-written extern "c" declarations in the
// modules that need them (main.zig, external_windows.zig, etc.).
// No @cImport, no zig-gobject — enables cross-compilation from macOS.

// =========================================================================
// GDK key values (stable constants from gdk/gdkkeysyms.h)
// =========================================================================

pub const GDK_KEY_Escape = 0xff1b;
pub const GDK_KEY_Return = 0xff0d;
pub const GDK_KEY_Tab = 0xff09;
pub const GDK_KEY_BackSpace = 0xff08;
pub const GDK_KEY_Delete = 0xffff;
pub const GDK_KEY_Insert = 0xff63;
pub const GDK_KEY_Home = 0xff50;
pub const GDK_KEY_End = 0xff57;
pub const GDK_KEY_Page_Up = 0xff55;
pub const GDK_KEY_Page_Down = 0xff56;
pub const GDK_KEY_Left = 0xff51;
pub const GDK_KEY_Right = 0xff53;
pub const GDK_KEY_Up = 0xff52;
pub const GDK_KEY_Down = 0xff54;
pub const GDK_KEY_F1 = 0xffbe;
pub const GDK_KEY_F2 = 0xffbf;
pub const GDK_KEY_F3 = 0xffc0;
pub const GDK_KEY_F4 = 0xffc1;
pub const GDK_KEY_F5 = 0xffc2;
pub const GDK_KEY_F6 = 0xffc3;
pub const GDK_KEY_F7 = 0xffc4;
pub const GDK_KEY_F8 = 0xffc5;
pub const GDK_KEY_F9 = 0xffc6;
pub const GDK_KEY_F10 = 0xffc7;
pub const GDK_KEY_F11 = 0xffc8;
pub const GDK_KEY_F12 = 0xffc9;

// =========================================================================
// GDK modifier masks (from gdk/gdkenums.h, stable ABI)
// =========================================================================

pub const GDK_SHIFT_MASK: c_uint = 1 << 0;
pub const GDK_CONTROL_MASK: c_uint = 1 << 2;
pub const GDK_ALT_MASK: c_uint = 1 << 3;
pub const GDK_SUPER_MASK: c_uint = 1 << 26;

// =========================================================================
// GLib idle/timeout helpers (convenience wrappers)
// =========================================================================

/// Signature for g_idle_add / g_timeout_add callbacks.
pub const GSourceFunc = *const fn (?*anyopaque) callconv(.c) c_int;

/// Post a callback to the GTK main thread (equivalent to PostMessageW on Windows).
pub extern "c" fn g_idle_add(function: GSourceFunc, data: ?*anyopaque) c_uint;

/// Schedule a timeout callback (equivalent to SetTimer on Windows).
pub extern "c" fn g_timeout_add(interval: c_uint, function: GSourceFunc, data: ?*anyopaque) c_uint;

/// Remove a source by ID.
pub extern "c" fn g_source_remove(tag: c_uint) c_int;

// =========================================================================
// GDK standalone functions (not available as methods in zig-gobject)
// =========================================================================

pub extern "c" fn gdk_keyval_to_unicode(keyval: c_uint) u32;

// =========================================================================
// GLib signal connection helper
// =========================================================================

/// Connect a signal handler (simplified g_signal_connect macro).
pub fn g_signal_connect(
    instance: *anyopaque,
    detailed_signal: [*:0]const u8,
    c_handler: *const anyopaque,
    data: ?*anyopaque,
) c_ulong {
    return g_signal_connect_data(instance, detailed_signal, c_handler, data, null, 0);
}

pub extern "c" fn gtk_gl_area_queue_render(area: *anyopaque) void;
pub extern "c" fn gtk_window_set_title(window: *anyopaque, title: [*:0]const u8) void;
pub extern "c" fn gtk_im_context_reset(context: *anyopaque) void;
pub extern "c" fn g_application_quit(application: *anyopaque) void;

pub const GAsyncReadyCallback = *const fn (?*anyopaque, ?*anyopaque, ?*anyopaque) callconv(.c) void;
pub extern "c" fn gdk_display_get_default() ?*anyopaque;
pub extern "c" fn gdk_display_get_clipboard(display: *anyopaque) ?*anyopaque;
pub extern "c" fn gdk_clipboard_read_text_async(clipboard: *anyopaque, cancellable: ?*anyopaque, callback: GAsyncReadyCallback, user_data: ?*anyopaque) void;
pub extern "c" fn gdk_clipboard_read_text_finish(clipboard: *anyopaque, result: ?*anyopaque, err: *?*anyopaque) ?[*:0]u8;
pub extern "c" fn gdk_clipboard_set_text(clipboard: *anyopaque, text: [*:0]const u8) void;
pub extern "c" fn g_free(ptr: ?*anyopaque) void;
pub extern "c" fn g_error_free(err: *anyopaque) void;

extern "c" fn g_signal_connect_data(
    instance: *anyopaque,
    detailed_signal: [*:0]const u8,
    c_handler: *const anyopaque,
    data: ?*anyopaque,
    destroy_data: ?*anyopaque,
    connect_flags: c_uint,
) c_ulong;
