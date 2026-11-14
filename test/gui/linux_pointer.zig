// linux_pointer.zig — synthetic pointer input on Wayland, for the GUI
// scenarios that click, drag and scroll. Counterpart to the CGEvent posting
// in macos_window.zig.
//
// A Wayland client cannot inject input into another, so this is a client of
// the compositor's zwlr_virtual_pointer_manager_v1 (wlroots, Hyprland). The
// protocol's interface tables are written out here rather than generated
// from its XML: only the requests below are used, and none has events.
// Positions are layout (logical) px, as Hyprland reports window bounds.
//
// Test-only code.

const std = @import("std");
const gui_io = @import("gui_io.zig");

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
extern "c" fn wl_display_disconnect(display: *Display) void;
extern "c" fn wl_display_roundtrip(display: *Display) c_int;
extern "c" fn wl_proxy_marshal_flags(proxy: *anyopaque, opcode: u32, interface: ?*const wl_interface, version: u32, flags: u32, ...) ?*Proxy;
extern "c" fn wl_proxy_add_listener(proxy: *Proxy, implementation: *const anyopaque, data: ?*anyopaque) c_int;
extern "c" fn wl_proxy_get_version(proxy: *Proxy) u32;
extern const wl_registry_interface: wl_interface;

const null_types = [_]?*const wl_interface{ null, null, null, null, null };

const pointer_requests = [_]wl_message{
    .{ .name = "motion", .signature = "uff", .types = &null_types },
    .{ .name = "motion_absolute", .signature = "uuuuu", .types = &null_types },
    .{ .name = "button", .signature = "uuu", .types = &null_types },
    .{ .name = "axis", .signature = "uuf", .types = &null_types },
    .{ .name = "frame", .signature = "", .types = &null_types },
    .{ .name = "axis_source", .signature = "u", .types = &null_types },
    .{ .name = "axis_stop", .signature = "uu", .types = &null_types },
    .{ .name = "axis_discrete", .signature = "uufi", .types = &null_types },
    .{ .name = "destroy", .signature = "", .types = &null_types },
};

const pointer_interface: wl_interface = .{
    .name = "zwlr_virtual_pointer_v1",
    .version = 1,
    .method_count = pointer_requests.len,
    .methods = &pointer_requests,
    .event_count = 0,
    .events = null,
};

// create_virtual_pointer(seat: ?object wl_seat, id: new_id). A null seat is
// the compositor's default, so wl_seat's own table is never needed here.
const create_types = [_]?*const wl_interface{ null, &pointer_interface };
const manager_requests = [_]wl_message{
    .{ .name = "create_virtual_pointer", .signature = "?on", .types = &create_types },
    .{ .name = "destroy", .signature = "", .types = &null_types },
};

const manager_interface: wl_interface = .{
    .name = "zwlr_virtual_pointer_manager_v1",
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

const Found = struct { name: u32 = 0 };

fn onGlobal(data: ?*anyopaque, _: *Proxy, name: u32, interface: [*:0]const u8, _: u32) callconv(.c) void {
    const found: *Found = @ptrCast(@alignCast(data.?));
    if (std.mem.eql(u8, std.mem.span(interface), "zwlr_virtual_pointer_manager_v1")) found.name = name;
}

fn onGlobalRemove(_: ?*anyopaque, _: *Proxy, _: u32) callconv(.c) void {}

const listener: RegistryListener = .{ .global = onGlobal, .global_remove = onGlobalRemove };

// Opcodes of zwlr_virtual_pointer_v1.
const op_motion_absolute = 1;
const op_button = 2;
const op_frame = 4;
const op_axis_source = 5;
const op_axis_discrete = 7;
const op_destroy = 8;

pub const btn_left: u32 = 0x110;
pub const btn_right: u32 = 0x111;
pub const btn_middle: u32 = 0x112;

/// One virtual pointer for a scenario's lifetime.
pub const Pointer = struct {
    display: *Display,
    ptr: *Proxy,
    /// The output layout's extent, which motion_absolute positions scale to.
    extent_w: u32,
    extent_h: u32,
    time_ms: u32 = 0,

    pub fn deinit(self: *Pointer) void {
        // Destroying the device at once can drop its last events before
        // the compositor hands them on.
        gui_io.sleepNs(200 * std.time.ns_per_ms);
        _ = wl_proxy_marshal_flags(self.ptr, op_destroy, null, 1, 1);
        _ = wl_display_roundtrip(self.display);
        wl_display_disconnect(self.display);
    }

    fn now(self: *Pointer) u32 {
        self.time_ms +%= 10;
        return self.time_ms;
    }

    fn sync(self: *Pointer) void {
        _ = wl_proxy_marshal_flags(self.ptr, op_frame, null, 1, 0);
        _ = wl_display_roundtrip(self.display);
    }

    /// Puts the pointer at layout (x, y).
    pub fn moveTo(self: *Pointer, x: f64, y: f64) void {
        const cx: u32 = @intFromFloat(std.math.clamp(@round(x), 0, @as(f64, @floatFromInt(self.extent_w - 1))));
        const cy: u32 = @intFromFloat(std.math.clamp(@round(y), 0, @as(f64, @floatFromInt(self.extent_h - 1))));
        _ = wl_proxy_marshal_flags(self.ptr, op_motion_absolute, null, 1, 0, self.now(), cx, cy, self.extent_w, self.extent_h);
        self.sync();
    }

    pub fn button(self: *Pointer, code: u32, pressed: bool) void {
        _ = wl_proxy_marshal_flags(self.ptr, op_button, null, 1, 0, self.now(), code, @as(u32, @intFromBool(pressed)));
        self.sync();
    }

    pub fn click(self: *Pointer, x: f64, y: f64, code: u32) void {
        self.moveTo(x, y);
        gui_io.sleepNs(150 * std.time.ns_per_ms);
        self.button(code, true);
        gui_io.sleepNs(30 * std.time.ns_per_ms);
        self.button(code, false);
    }

    /// Press at `from`, move to `to` in `steps`, release.
    pub fn drag(self: *Pointer, from: [2]f64, to: [2]f64, steps: u32) void {
        self.moveTo(from[0], from[1]);
        // The surface must have taken the pointer (wl_pointer.enter) before
        // the press, or the press goes nowhere.
        gui_io.sleepNs(150 * std.time.ns_per_ms);
        self.button(btn_left, true);
        var i: u32 = 1;
        while (i <= steps) : (i += 1) {
            const t = @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(steps));
            self.moveTo(from[0] + (to[0] - from[0]) * t, from[1] + (to[1] - from[1]) * t);
            gui_io.sleepNs(16 * std.time.ns_per_ms);
        }
        self.button(btn_left, false);
    }

    /// `notches` wheel steps at the pointer, positive down.
    pub fn wheel(self: *Pointer, notches: i32) void {
        const vertical: u32 = 0;
        const wheel_source: u32 = 0;
        var n: i32 = 0;
        const dir: i32 = if (notches < 0) -1 else 1;
        while (n != notches) : (n += dir) {
            _ = wl_proxy_marshal_flags(self.ptr, op_axis_source, null, 1, 0, wheel_source);
            // 15 is a notch's value in wl_fixed units of 1/256 (wlroots' 15.0).
            _ = wl_proxy_marshal_flags(self.ptr, op_axis_discrete, null, 1, 0, self.now(), vertical, @as(i32, 15 * 256) * dir, dir);
            self.sync();
            gui_io.sleepNs(30 * std.time.ns_per_ms);
        }
    }
};

/// A virtual pointer on the session's compositor, or null when it offers no
/// virtual-pointer manager. `extent_w` x `extent_h` is the output layout in
/// logical px.
pub fn open(extent_w: u32, extent_h: u32) ?Pointer {
    const display = wl_display_connect(null) orelse return null;
    const registry = wl_proxy_marshal_flags(display, 1, &wl_registry_interface, 1, 0, @as(?*anyopaque, null)) orelse {
        wl_display_disconnect(display);
        return null;
    };
    var found: Found = .{};
    _ = wl_proxy_add_listener(registry, &listener, &found);
    _ = wl_display_roundtrip(display);
    if (found.name == 0) {
        wl_display_disconnect(display);
        return null;
    }
    const manager = wl_proxy_marshal_flags(registry, 0, &manager_interface, 1, 0, found.name, manager_interface.name, @as(u32, 1), @as(?*anyopaque, null)) orelse {
        wl_display_disconnect(display);
        return null;
    };
    const ptr = wl_proxy_marshal_flags(manager, 0, &pointer_interface, 1, 0, @as(?*anyopaque, null), @as(?*anyopaque, null)) orelse {
        wl_display_disconnect(display);
        return null;
    };
    _ = wl_display_roundtrip(display);
    return .{ .display = display, .ptr = ptr, .extent_w = extent_w, .extent_h = extent_h };
}
