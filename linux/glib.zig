//! GLib, GObject and GIO as the frontend uses them: the main loop's idles and
//! timers, and D-Bus for the input method frameworks. Hand-written extern
//! declarations, so a cross build needs no system headers.

const std = @import("std");

pub const GAsyncReadyCallback = *const fn (?*anyopaque, ?*anyopaque, ?*anyopaque) callconv(.c) void;

pub const GSourceFunc = *const fn (?*anyopaque) callconv(.c) c_int;

pub const G_BUS_TYPE_SESSION: c_int = 2;

pub const G_DBUS_CONNECTION_FLAGS_AUTHENTICATION_CLIENT: c_uint = 1 << 0;

pub const G_DBUS_CONNECTION_FLAGS_MESSAGE_BUS_CONNECTION: c_uint = 1 << 3;

pub extern "c" fn g_bus_get_sync(bus_type: c_int, cancellable: ?*anyopaque, err: ?*?*anyopaque) ?*anyopaque;

pub extern "c" fn g_dbus_connection_call(
    connection: *anyopaque,
    bus_name: ?[*:0]const u8,
    object_path: [*:0]const u8,
    interface_name: ?[*:0]const u8,
    method_name: [*:0]const u8,
    parameters: ?*anyopaque,
    reply_type: ?*const anyopaque,
    flags: c_uint,
    timeout_msec: c_int,
    cancellable: ?*anyopaque,
    callback: ?GAsyncReadyCallback,
    user_data: ?*anyopaque,
) void;

pub extern "c" fn g_dbus_connection_call_finish(connection: *anyopaque, res: ?*anyopaque, err: ?*?*anyopaque) ?*anyopaque;

pub extern "c" fn g_dbus_connection_new_for_address_sync(address: [*:0]const u8, flags: c_uint, observer: ?*anyopaque, cancellable: ?*anyopaque, err: ?*?*anyopaque) ?*anyopaque;

pub extern "c" fn g_dir_close(dir: *anyopaque) void;

pub extern "c" fn g_dir_open(path: [*:0]const u8, flags: c_uint, err: ?*?*anyopaque) ?*anyopaque;

pub extern "c" fn g_dir_read_name(dir: *anyopaque) ?[*:0]const u8;

pub extern "c" fn g_error_free(err: *anyopaque) void;

pub extern "c" fn g_file_get_contents(filename: [*:0]const u8, contents: *?[*:0]u8, length: ?*usize, err: ?*?*anyopaque) c_int;
// Window lifecycle: realizing a window before it is shown, its toplevel
// state, `devcontainer up` as a subprocess, the workspace folder picker.

pub extern "c" fn g_free(ptr: ?*anyopaque) void;

pub extern "c" fn g_get_user_config_dir() [*:0]const u8;

pub extern "c" fn g_getenv(variable: [*:0]const u8) ?[*:0]const u8;

pub extern "c" fn g_idle_add(function: GSourceFunc, data: ?*anyopaque) c_uint;

pub extern "c" fn g_object_unref(object: *anyopaque) void;

pub extern "c" fn g_source_remove(tag: c_uint) c_int;

pub extern "c" fn g_timeout_add(interval: c_uint, function: GSourceFunc, data: ?*anyopaque) c_uint;

pub extern "c" fn g_variant_get_child_value(value: *anyopaque, index: usize) ?*anyopaque;

pub extern "c" fn g_variant_get_string(value: *anyopaque, length: ?*usize) ?[*:0]const u8;

pub extern "c" fn g_variant_get_type_string(value: *anyopaque) [*:0]const u8;

pub extern "c" fn g_variant_get_variant(value: *anyopaque) ?*anyopaque;

pub extern "c" fn g_variant_n_children(value: *anyopaque) usize;

pub extern "c" fn g_variant_new_string(string: [*:0]const u8) ?*anyopaque;

pub extern "c" fn g_variant_new_tuple(children: [*]const *anyopaque, n_children: usize) ?*anyopaque;

pub extern "c" fn g_variant_unref(value: *anyopaque) void;

pub const G_IO_IN: c_uint = 1;
/// Calls `func` on the main loop whenever `fd` meets `condition`, until it
/// returns 0.
pub extern "c" fn g_unix_fd_add(fd: c_int, condition: c_uint, func: *const fn (c_int, c_uint, ?*anyopaque) callconv(.c) c_int, data: ?*anyopaque) c_uint;
