// macos_window.zig — read-only OS window observation via CGWindowList.
//
// Manual extern declarations instead of @cImport to keep the build light;
// only the handful of CoreGraphics/CoreFoundation calls needed to count
// on-screen windows owned by a PID. Strictly read-only: this never touches,
// moves, or closes any window.

const std = @import("std");

// CFArrayRef CGWindowListCopyWindowInfo(CGWindowListOption, CGWindowID)
extern "c" fn CGWindowListCopyWindowInfo(option: u32, relative_to: u32) ?*anyopaque;
extern "c" fn CFArrayGetCount(arr: *anyopaque) isize;
extern "c" fn CFArrayGetValueAtIndex(arr: *anyopaque, idx: isize) ?*anyopaque;
extern "c" fn CFDictionaryGetValue(dict: *anyopaque, key: *anyopaque) ?*anyopaque;
extern "c" fn CFNumberGetValue(number: *anyopaque, number_type: i64, out: *anyopaque) bool;
extern "c" fn CFRelease(cf: *anyopaque) void;

extern "c" fn CGRectMakeWithDictionaryRepresentation(dict: *anyopaque, rect: *CGRect) bool;

const CGRect = extern struct {
    x: f64,
    y: f64,
    w: f64,
    h: f64,
};

// CFString constants exported by CoreGraphics.
extern const kCGWindowOwnerPID: *anyopaque;
extern const kCGWindowLayer: *anyopaque;
extern const kCGWindowBounds: *anyopaque;
extern const kCGWindowNumber: *anyopaque;

const kCGWindowListOptionOnScreenOnly: u32 = 1 << 0;
const kCGNullWindowID: u32 = 0;
const kCFNumberSInt32Type: i64 = 3;

/// Count all on-screen windows owned by `pid`, any layer. Overlay windows
/// (e.g. Zonvie's external cmdline panel) use floating levels, so no layer
/// filter — scenarios assert RELATIVE count changes, which makes the
/// absolute composition irrelevant.
pub fn windowCountForPid(pid: i32) u32 {
    const list = CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly, kCGNullWindowID) orelse return 0;
    defer CFRelease(list);

    var count: u32 = 0;
    const n = CFArrayGetCount(list);
    var i: isize = 0;
    while (i < n) : (i += 1) {
        const dict = CFArrayGetValueAtIndex(list, i) orelse continue;

        const pid_ref = CFDictionaryGetValue(dict, kCGWindowOwnerPID) orelse continue;
        var owner_pid: i32 = 0;
        if (!CFNumberGetValue(pid_ref, kCFNumberSInt32Type, &owner_pid)) continue;
        if (owner_pid != pid) continue;

        count += 1;
    }
    return count;
}

pub const Bounds = struct { x: f64, y: f64, w: f64, h: f64 };

pub const MainWindow = struct { number: u32, bounds: Bounds };

/// The app's main window: the largest-area on-screen LAYER-0 (normal)
/// window owned by `pid`, with its CGWindowID and bounds. Null when the
/// app has no normal window on screen.
pub fn mainWindowForPid(pid: i32) ?MainWindow {
    const list = CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly, kCGNullWindowID) orelse return null;
    defer CFRelease(list);

    var best: ?MainWindow = null;
    var best_area: f64 = -1;
    const n = CFArrayGetCount(list);
    var i: isize = 0;
    while (i < n) : (i += 1) {
        const dict = CFArrayGetValueAtIndex(list, i) orelse continue;

        const pid_ref = CFDictionaryGetValue(dict, kCGWindowOwnerPID) orelse continue;
        var owner_pid: i32 = 0;
        if (!CFNumberGetValue(pid_ref, kCFNumberSInt32Type, &owner_pid)) continue;
        if (owner_pid != pid) continue;

        var layer: i32 = -1;
        if (CFDictionaryGetValue(dict, kCGWindowLayer)) |layer_ref| {
            _ = CFNumberGetValue(layer_ref, kCFNumberSInt32Type, &layer);
        }
        if (layer != 0) continue;

        const bounds_ref = CFDictionaryGetValue(dict, kCGWindowBounds) orelse continue;
        var rect = CGRect{ .x = 0, .y = 0, .w = 0, .h = 0 };
        if (!CGRectMakeWithDictionaryRepresentation(bounds_ref, &rect)) continue;

        const num_ref = CFDictionaryGetValue(dict, kCGWindowNumber) orelse continue;
        var num: i64 = 0;
        if (!CFNumberGetValue(num_ref, 4, &num)) continue; // kCFNumberSInt64Type = 4

        const area = rect.w * rect.h;
        if (area > best_area) {
            best_area = area;
            best = .{ .number = @intCast(num), .bounds = .{ .x = rect.x, .y = rect.y, .w = rect.w, .h = rect.h } };
        }
    }
    return best;
}

/// Bounds of the app's main window. Null when none on screen.
pub fn mainWindowBoundsForPid(pid: i32) ?Bounds {
    const mw = mainWindowForPid(pid) orelse return null;
    return mw.bounds;
}

/// Fill `out` with every on-screen window owned by `pid` (any layer),
/// returning the count. Scenarios identify a newly appeared overlay
/// (e.g. a mini message popup) by diffing two snapshots by window number.
pub fn windowsForPid(pid: i32, out: []MainWindow) usize {
    const list = CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly, kCGNullWindowID) orelse return 0;
    defer CFRelease(list);

    var count: usize = 0;
    const n = CFArrayGetCount(list);
    var i: isize = 0;
    while (i < n and count < out.len) : (i += 1) {
        const dict = CFArrayGetValueAtIndex(list, i) orelse continue;

        const pid_ref = CFDictionaryGetValue(dict, kCGWindowOwnerPID) orelse continue;
        var owner_pid: i32 = 0;
        if (!CFNumberGetValue(pid_ref, kCFNumberSInt32Type, &owner_pid)) continue;
        if (owner_pid != pid) continue;

        const bounds_ref = CFDictionaryGetValue(dict, kCGWindowBounds) orelse continue;
        var rect = CGRect{ .x = 0, .y = 0, .w = 0, .h = 0 };
        if (!CGRectMakeWithDictionaryRepresentation(bounds_ref, &rect)) continue;

        const num_ref = CFDictionaryGetValue(dict, kCGWindowNumber) orelse continue;
        var num: i64 = 0;
        if (!CFNumberGetValue(num_ref, 4, &num)) continue; // kCFNumberSInt64Type = 4

        out[count] = .{ .number = @intCast(num), .bounds = .{ .x = rect.x, .y = rect.y, .w = rect.w, .h = rect.h } };
        count += 1;
    }
    return count;
}

/// No-op on macOS: moving another process's window needs the Accessibility
/// API, and macOS uses grayscale AA (no ClearType subpixel-phase issue), so
/// capture is already position-stable. Mirrors the Windows pinWindow.
pub fn pinWindow(pid: i32, x: i32, y: i32) void {
    _ = pid;
    _ = x;
    _ = y;
}

/// Debug helper: print layer and bounds of every on-screen window owned by
/// `pid`. Used by waitWindowCount on failure to identify stray windows.
pub fn dumpWindowsForPid(pid: i32) void {
    const list = CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly, kCGNullWindowID) orelse return;
    defer CFRelease(list);

    const n = CFArrayGetCount(list);
    var i: isize = 0;
    while (i < n) : (i += 1) {
        const dict = CFArrayGetValueAtIndex(list, i) orelse continue;

        const pid_ref = CFDictionaryGetValue(dict, kCGWindowOwnerPID) orelse continue;
        var owner_pid: i32 = 0;
        if (!CFNumberGetValue(pid_ref, kCFNumberSInt32Type, &owner_pid)) continue;
        if (owner_pid != pid) continue;

        var layer: i32 = -1;
        if (CFDictionaryGetValue(dict, kCGWindowLayer)) |layer_ref| {
            _ = CFNumberGetValue(layer_ref, kCFNumberSInt32Type, &layer);
        }
        var rect = CGRect{ .x = 0, .y = 0, .w = 0, .h = 0 };
        if (CFDictionaryGetValue(dict, kCGWindowBounds)) |bounds_ref| {
            _ = CGRectMakeWithDictionaryRepresentation(bounds_ref, &rect);
        }
        std.debug.print(
            "[gui]   window: layer={d} x={d:.0} y={d:.0} w={d:.0} h={d:.0}\n",
            .{ layer, rect.x, rect.y, rect.w, rect.h },
        );
    }
}
