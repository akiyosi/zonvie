// virtual_keyboard.zig — give a headless wlroots session a keyboard.
//
// Headless sway (the Linux GUI job in .github/workflows/test.yml) starts with
// no input devices, so its seat has no keyboard and no client ever gets
// wl_keyboard.enter: the app never learns it has the focus, and what follows
// the focus (the cursor blink, the cmdline's surface) never happens. This
// holds one zwp_virtual_keyboard_v1 with the default keymap for as long as it
// runs; it sends no keys. A local session has a real keyboard and needs none.
//
// Built and started by the CI job alone:
//   zig build-exe test/gui/ci/virtual_keyboard.zig -lc -lwayland-client -lxkbcommon
// The interface tables are written out as in linux_pointer.zig.

const std = @import("std");

const wl_message = extern struct {
    name: [*:0]const u8,
    signature: [*:0]const u8,
    types: [*]const ?*const wl_interface,
};

const wl_interface = extern struct {
    name: [*:0]const u8,
    version: c_int,
    method_count: c_int,
    methods: ?[*]const wl_message,
    event_count: c_int,
    events: ?[*]const wl_message,
};

const Proxy = opaque {};
const Display = opaque {};

extern "c" fn wl_display_connect(name: ?[*:0]const u8) ?*Display;
extern "c" fn wl_display_roundtrip(display: *Display) c_int;
extern "c" fn wl_display_dispatch(display: *Display) c_int;
extern "c" fn wl_proxy_marshal_flags(proxy: *anyopaque, opcode: u32, interface: ?*const wl_interface, version: u32, flags: u32, ...) ?*Proxy;
extern "c" fn wl_proxy_add_listener(proxy: *Proxy, implementation: *const anyopaque, data: ?*anyopaque) c_int;
extern const wl_registry_interface: wl_interface;
extern const wl_seat_interface: wl_interface;

const Xkb = opaque {};
extern "c" fn xkb_context_new(flags: c_int) ?*Xkb;
extern "c" fn xkb_keymap_new_from_names(ctx: *Xkb, names: ?*const anyopaque, flags: c_int) ?*Xkb;
extern "c" fn xkb_keymap_get_as_string(keymap: *Xkb, format: c_int) ?[*:0]u8;
const xkb_keymap_format_text_v1 = 1;
const wl_keyboard_keymap_format_xkb_v1 = 1;

extern "c" fn memfd_create(name: [*:0]const u8, flags: c_uint) c_int;
extern "c" fn write(fd: c_int, buf: [*]const u8, count: usize) isize;

const null_types = [_]?*const wl_interface{ null, null, null, null };

const keyboard_requests = [_]wl_message{
    .{ .name = "keymap", .signature = "uhu", .types = &null_types },
    .{ .name = "key", .signature = "uuu", .types = &null_types },
    .{ .name = "modifiers", .signature = "uuuu", .types = &null_types },
    .{ .name = "destroy", .signature = "", .types = &null_types },
};

const keyboard_interface: wl_interface = .{
    .name = "zwp_virtual_keyboard_v1",
    .version = 1,
    .method_count = keyboard_requests.len,
    .methods = &keyboard_requests,
    .event_count = 0,
    .events = null,
};

// create_virtual_keyboard(seat: object wl_seat, id: new_id): the seat is
// not nullable here, unlike the virtual pointer's.
const create_types = [_]?*const wl_interface{ &wl_seat_interface, &keyboard_interface };
const manager_requests = [_]wl_message{
    .{ .name = "create_virtual_keyboard", .signature = "on", .types = &create_types },
};

const manager_interface: wl_interface = .{
    .name = "zwp_virtual_keyboard_manager_v1",
    .version = 1,
    .method_count = manager_requests.len,
    .methods = &manager_requests,
    .event_count = 0,
    .events = null,
};

const RegistryListener = extern struct {
    global: *const fn (?*anyopaque, *Proxy, u32, [*:0]const u8, u32) callconv(.c) void,
    global_remove: *const fn (?*anyopaque, *Proxy, u32) callconv(.c) void,
};

const Found = struct { manager: u32 = 0, seat: u32 = 0 };

fn onGlobal(data: ?*anyopaque, _: *Proxy, name: u32, interface: [*:0]const u8, _: u32) callconv(.c) void {
    const found: *Found = @ptrCast(@alignCast(data.?));
    const iface = std.mem.span(interface);
    if (std.mem.eql(u8, iface, "zwp_virtual_keyboard_manager_v1")) found.manager = name;
    if (std.mem.eql(u8, iface, "wl_seat") and found.seat == 0) found.seat = name;
}

fn onGlobalRemove(_: ?*anyopaque, _: *Proxy, _: u32) callconv(.c) void {}

const listener: RegistryListener = .{ .global = onGlobal, .global_remove = onGlobalRemove };

fn fail(comptime msg: []const u8) u8 {
    std.debug.print("virtual_keyboard: " ++ msg ++ "\n", .{});
    return 1;
}

pub fn main() u8 {
    const display = wl_display_connect(null) orelse return fail("no Wayland display");
    const registry = wl_proxy_marshal_flags(display, 1, &wl_registry_interface, 1, 0, @as(?*anyopaque, null)) orelse return fail("no registry");
    var found: Found = .{};
    _ = wl_proxy_add_listener(registry, &listener, &found);
    _ = wl_display_roundtrip(display);
    if (found.manager == 0) return fail("the compositor offers no zwp_virtual_keyboard_manager_v1");
    if (found.seat == 0) return fail("the compositor offers no wl_seat");

    const seat = wl_proxy_marshal_flags(registry, 0, &wl_seat_interface, 1, 0, found.seat, wl_seat_interface.name, @as(u32, 1), @as(?*anyopaque, null)) orelse return fail("cannot bind wl_seat");
    const manager = wl_proxy_marshal_flags(registry, 0, &manager_interface, 1, 0, found.manager, manager_interface.name, @as(u32, 1), @as(?*anyopaque, null)) orelse return fail("cannot bind the manager");
    const kb = wl_proxy_marshal_flags(manager, 0, &keyboard_interface, 1, 0, seat, @as(?*anyopaque, null)) orelse return fail("cannot create the keyboard");

    // The default (RMLVO from the environment, else us) keymap, as text in a
    // memfd: the protocol carries a file descriptor, not the bytes.
    const ctx = xkb_context_new(0) orelse return fail("no xkb context");
    const keymap = xkb_keymap_new_from_names(ctx, null, 0) orelse return fail("no default keymap");
    const text = xkb_keymap_get_as_string(keymap, xkb_keymap_format_text_v1) orelse return fail("cannot serialize the keymap");
    const bytes = std.mem.span(text);
    const fd = memfd_create("zonvie-keymap", 0);
    if (fd < 0) return fail("memfd_create failed");
    var written: usize = 0;
    while (written <= bytes.len) {
        // Including the terminating NUL, which the compositor expects.
        const n = write(fd, text + written, bytes.len + 1 - written);
        if (n <= 0) return fail("cannot write the keymap");
        written += @intCast(n);
    }
    _ = wl_proxy_marshal_flags(kb, 0, null, 1, 0, @as(u32, wl_keyboard_keymap_format_xkb_v1), fd, @as(u32, @intCast(bytes.len + 1)));
    _ = wl_display_roundtrip(display);
    std.debug.print("virtual_keyboard: ready\n", .{});

    // Hold the device: it goes with this connection.
    while (wl_display_dispatch(display) != -1) {}
    return 0;
}
