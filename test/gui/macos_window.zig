// macos_window.zig — OS window observation via CGWindowList, plus the
// window manipulation a few scenarios need (move, minimize, drag-resize).
//
// Manual extern declarations instead of @cImport to keep the build light;
// only the handful of CoreGraphics/CoreFoundation/Accessibility calls
// actually used.
//
// Observation is read-only. Manipulation addresses the AXUIElement of a
// known PID wherever it can, so it cannot touch a bystander window; the one
// exception is dragResizeWindowByMouse, which has to post real mouse
// events and guards itself by verifying window ownership — see the comment
// above it.

const std = @import("std");
const gui_io = @import("gui_io.zig");

// CFArrayRef CGWindowListCopyWindowInfo(CGWindowListOption, CGWindowID)
extern "c" fn CGWindowListCopyWindowInfo(option: u32, relative_to: u32) ?*anyopaque;
extern "c" fn CFArrayGetCount(arr: *anyopaque) isize;
extern "c" fn CFArrayGetValueAtIndex(arr: *anyopaque, idx: isize) ?*anyopaque;
extern "c" fn CFDictionaryGetValue(dict: *anyopaque, key: *anyopaque) ?*anyopaque;
extern "c" fn CFNumberGetValue(number: *anyopaque, number_type: i64, out: *anyopaque) bool;
extern "c" fn CFRelease(cf: *anyopaque) void;
extern "c" fn CFRetain(cf: *anyopaque) *anyopaque;

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

// ── Accessibility-driven resize ────────────────────────────────────────
//
// Resizing another process's window needs the Accessibility API. Unlike a
// synthetic mouse drag this addresses the window ELEMENT of a known PID,
// so it cannot land on a bystander window. From the app's point of view it
// is an external resize exactly like a user drag: AppKit posts
// windowDidResize and the app's own "this resize came from me" suppression
// flag is not set, so the full window→grid→window round trip runs.

extern "c" fn AXIsProcessTrusted() bool;
extern "c" fn AXUIElementCreateApplication(pid: i32) ?*anyopaque;
extern "c" fn AXUIElementCopyAttributeValue(elem: *anyopaque, attr: *anyopaque, out: *?*anyopaque) i32;
extern "c" fn AXUIElementSetAttributeValue(elem: *anyopaque, attr: *anyopaque, value: *anyopaque) i32;
extern "c" fn AXValueCreate(type_id: u32, value_ptr: *const anyopaque) ?*anyopaque;
extern "c" fn AXValueGetValue(value: *anyopaque, type_id: u32, out: *anyopaque) bool;

extern "c" fn CFStringCreateWithCString(alloc: ?*anyopaque, cstr: [*:0]const u8, encoding: u32) ?*anyopaque;
extern const kCFBooleanTrue: *anyopaque;
extern const kCFBooleanFalse: *anyopaque;

const kCFStringEncodingUTF8: u32 = 0x08000100;
const kAXValueCGPointType: u32 = 1;
const kAXValueCGSizeType: u32 = 2;
const kAXErrorSuccess: i32 = 0;

// The kAX*Attribute names are CFSTR() macros in the SDK headers, not
// exported symbols, so build the CFStrings here. Created once and kept for
// the life of the test process.
var ax_windows_attr: ?*anyopaque = null;
var ax_size_attr: ?*anyopaque = null;
var ax_position_attr: ?*anyopaque = null;
var ax_minimized_attr: ?*anyopaque = null;

fn axAttr(cache: *?*anyopaque, name: [*:0]const u8) ?*anyopaque {
    if (cache.*) |s| return s;
    cache.* = CFStringCreateWithCString(null, name, kCFStringEncodingUTF8);
    return cache.*;
}

const CGSize = extern struct { w: f64, h: f64 };

/// Whether this process may drive other apps' windows. Without it every AX
/// call fails and a scenario should skip rather than report a false pass.
pub fn accessibilityTrusted() bool {
    return AXIsProcessTrusted();
}

fn axWindowSize(win: *anyopaque) ?CGSize {
    var value: ?*anyopaque = null;
    const attr = axAttr(&ax_size_attr, "AXSize") orelse return null;
    if (AXUIElementCopyAttributeValue(win, attr, &value) != kAXErrorSuccess) return null;
    const v = value orelse return null;
    defer CFRelease(v);
    var size = CGSize{ .w = 0, .h = 0 };
    if (!AXValueGetValue(v, kAXValueCGSizeType, &size)) return null;
    return size;
}

/// Largest accepted |dw| + |dh| when matching a window by size. Without a
/// bound the closest window always wins, so a caller passing a size no
/// window actually has would silently drive the wrong one — and with the ext
/// UI options on there are always several small overlay windows to hit.
const size_match_tolerance_pt: f64 = 40;

/// The app window whose current size is closest to (w, h), or null when
/// nothing is within size_match_tolerance_pt. Used to pick the external
/// float out of the app's windows without depending on AX ordering. Caller
/// must CFRelease the returned element and the window list is released here,
/// so the element is retained first.
fn axFindWindowBySize(app: *anyopaque, w: f64, h: f64) ?*anyopaque {
    var value: ?*anyopaque = null;
    const attr = axAttr(&ax_windows_attr, "AXWindows") orelse return null;
    if (AXUIElementCopyAttributeValue(app, attr, &value) != kAXErrorSuccess) return null;
    const list = value orelse return null;
    defer CFRelease(list);

    var best: ?*anyopaque = null;
    var best_err: f64 = std.math.floatMax(f64);
    const n = CFArrayGetCount(list);
    var i: isize = 0;
    while (i < n) : (i += 1) {
        const win = CFArrayGetValueAtIndex(list, i) orelse continue;
        const size = axWindowSize(win) orelse continue;
        const err = @abs(size.w - w) + @abs(size.h - h);
        if (err < best_err) {
            best_err = err;
            best = win;
        }
    }
    if (best_err > size_match_tolerance_pt) {
        std.debug.print(
            "[gui] no window within {d:.0}pt of {d:.0}x{d:.0} (closest off by {d:.0}pt)\n",
            .{ size_match_tolerance_pt, w, h, best_err },
        );
        return null;
    }
    const chosen = best orelse return null;
    return CFRetain(chosen);
}

/// Move the app window currently sized (w, h) so its top-left corner sits
/// at (x, y) in screen coordinates. A window whose resize corner lies off
/// the bottom of the display cannot be grabbed, so scenarios that drag one
/// must place it fully on screen first.
pub fn moveWindowBySize(pid: i32, w: f64, h: f64, x: f64, y: f64) bool {
    if (!accessibilityTrusted()) return false;
    const app = AXUIElementCreateApplication(pid) orelse return false;
    defer CFRelease(app);
    const win = axFindWindowBySize(app, w, h) orelse return false;
    defer CFRelease(win);
    const attr = axAttr(&ax_position_attr, "AXPosition") orelse return false;
    const pos = CGPoint{ .x = x, .y = y };
    const v = AXValueCreate(kAXValueCGPointType, &pos) orelse return false;
    defer CFRelease(v);
    return AXUIElementSetAttributeValue(win, attr, v) == kAXErrorSuccess;
}

/// Minimize or restore the app window currently sized (w, h). Minimizing
/// genuinely stops the view's display link, so this is how a scenario
/// exercises the "frames must come back" path without depending on the
/// platform hiccup that motivated it.
///
/// A restore has to find the window by size while it is in the Dock, which
/// AX still reports, so callers pass the pre-minimize size both times.
pub fn setWindowMinimizedBySize(pid: i32, w: f64, h: f64, minimized: bool) bool {
    if (!accessibilityTrusted()) return false;
    const app = AXUIElementCreateApplication(pid) orelse return false;
    defer CFRelease(app);
    const win = axFindWindowBySize(app, w, h) orelse return false;
    defer CFRelease(win);
    const attr = axAttr(&ax_minimized_attr, "AXMinimized") orelse return false;
    const value = if (minimized) kCFBooleanTrue else kCFBooleanFalse;
    return AXUIElementSetAttributeValue(win, attr, value) == kAXErrorSuccess;
}

// ── Live drag-resize ───────────────────────────────────────────────────
//
// An AX size change is a plain setFrame: the view never enters
// `inLiveResize` and AppKit never runs its resize event-tracking loop. A
// scenario about what a user's edge drag leaves behind therefore needs
// real mouse events.
//
// Synthetic drags are normally banned here because a coordinate-addressed
// event goes to whatever window owns the point, and that has leaked into
// the zonvie instance hosting the developer's session. CGEventPostToPid
// avoids that by construction but AppKit's window-frame resize tracking
// never starts from a pid-posted event, so a resize drag has to go through
// the HID tap.
//
// The hazard is removed by VERIFICATION instead: every point this posts at
// is first checked against the front-to-back window list, and the drag is
// abandoned unless the frontmost window containing that point belongs to
// the app under test. The path is a corner dragged INWARD, so every
// intermediate point lies over the same window. A resize drag also has no
// drop-target semantics — nothing can "accept" it mid-path. If a check
// fails the caller gets false and the scenario errors out; it never posts
// blindly and hopes.

extern "c" fn CGEventCreateMouseEvent(source: ?*anyopaque, event_type: u32, pos: CGPoint, button: u32) ?*anyopaque;
extern "c" fn CGEventPost(tap: u32, event: *anyopaque) void;
extern "c" fn CGEventSetIntegerValueField(event: *anyopaque, field: u32, value: i64) void;
extern "c" fn CGEventCreate(source: ?*anyopaque) ?*anyopaque;
extern "c" fn CGEventGetLocation(event: *anyopaque) CGPoint;
extern "c" fn CGWarpMouseCursorPosition(pos: CGPoint) i32;

const kCGHIDEventTap: u32 = 0;

/// Print every on-screen window containing (x, y), front to back, with its
/// layer and owner. Used when a drag is refused, to show what is in the way.
pub fn dumpWindowsAtPoint(x: f64, y: f64) void {
    const list = CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly, kCGNullWindowID) orelse return;
    defer CFRelease(list);
    std.debug.print("[gui] windows at ({d:.0},{d:.0}), front to back:\n", .{ x, y });
    const n = CFArrayGetCount(list);
    var i: isize = 0;
    while (i < n) : (i += 1) {
        const dict = CFArrayGetValueAtIndex(list, i) orelse continue;
        const bounds_ref = CFDictionaryGetValue(dict, kCGWindowBounds) orelse continue;
        var rect = CGRect{ .x = 0, .y = 0, .w = 0, .h = 0 };
        if (!CGRectMakeWithDictionaryRepresentation(bounds_ref, &rect)) continue;
        if (x < rect.x or x >= rect.x + rect.w or y < rect.y or y >= rect.y + rect.h) continue;
        var layer: i32 = 0;
        if (CFDictionaryGetValue(dict, kCGWindowLayer)) |lr| _ = CFNumberGetValue(lr, kCFNumberSInt32Type, &layer);
        var owner: i32 = 0;
        if (CFDictionaryGetValue(dict, kCGWindowOwnerPID)) |pr| _ = CFNumberGetValue(pr, kCFNumberSInt32Type, &owner);
        std.debug.print(
            "[gui]   pid={d} layer={d} bounds=({d:.0},{d:.0},{d:.0},{d:.0})\n",
            .{ owner, layer, rect.x, rect.y, rect.w, rect.h },
        );
    }
}

/// Owner PID of the FRONTMOST on-screen window containing (x, y), or 0.
/// CGWindowListCopyWindowInfo returns windows front to back, so the first
/// hit is the one that would receive a click there.
pub fn ownerPidAtPoint(x: f64, y: f64) i32 {
    const list = CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly, kCGNullWindowID) orelse return 0;
    defer CFRelease(list);

    const n = CFArrayGetCount(list);
    var i: isize = 0;
    while (i < n) : (i += 1) {
        const dict = CFArrayGetValueAtIndex(list, i) orelse continue;
        const bounds_ref = CFDictionaryGetValue(dict, kCGWindowBounds) orelse continue;
        var rect = CGRect{ .x = 0, .y = 0, .w = 0, .h = 0 };
        if (!CGRectMakeWithDictionaryRepresentation(bounds_ref, &rect)) continue;
        if (x < rect.x or x >= rect.x + rect.w or y < rect.y or y >= rect.y + rect.h) continue;

        // Only normal windows (layer 0) answer. Below that sit the
        // wallpaper/desktop windows, and above it Dock.app keeps a
        // screen-sized layer-20 window that contains every point on screen
        // — neither is what a click on a window frame would hit.
        var layer: i32 = -1;
        if (CFDictionaryGetValue(dict, kCGWindowLayer)) |layer_ref| {
            _ = CFNumberGetValue(layer_ref, kCFNumberSInt32Type, &layer);
        }
        if (layer != 0) continue;

        const pid_ref = CFDictionaryGetValue(dict, kCGWindowOwnerPID) orelse continue;
        var owner_pid: i32 = 0;
        if (!CFNumberGetValue(pid_ref, kCFNumberSInt32Type, &owner_pid)) continue;
        return owner_pid;
    }
    return 0;
}

const CGPoint = extern struct { x: f64, y: f64 };

const kCGEventLeftMouseDown: u32 = 1;
const kCGEventLeftMouseUp: u32 = 2;
const kCGEventLeftMouseDragged: u32 = 6;
const kCGEventMouseMoved: u32 = 5;
const kCGMouseButtonLeft: u32 = 0;
/// kCGMouseEventClickState. AppKit discards a synthesized mouseDown whose
/// click state is 0 — it never becomes a click, so no resize tracking
/// starts and the drag silently does nothing.
const kCGMouseEventClickState: u32 = 1;

/// Post one mouse event at (x, y), but only after confirming that the
/// frontmost window there belongs to `pid`. Returns false without posting
/// anything otherwise — see the section comment above.
fn postMouseChecked(pid: i32, event_type: u32, x: f64, y: f64) bool {
    const owner = ownerPidAtPoint(x, y);
    if (owner != pid) {
        std.debug.print(
            "[gui] refusing to post mouse event at ({d:.0},{d:.0}): owned by pid {d}, not {d}\n",
            .{ x, y, owner, pid },
        );
        return false;
    }
    const e = CGEventCreateMouseEvent(null, event_type, .{ .x = x, .y = y }, kCGMouseButtonLeft) orelse return false;
    defer CFRelease(e);
    CGEventSetIntegerValueField(e, kCGMouseEventClickState, 1);
    CGEventPost(kCGHIDEventTap, e);
    return true;
}

/// Current pointer location, so a drag can put it back where it was.
fn cursorLocation() CGPoint {
    const e = CGEventCreate(null) orelse return .{ .x = 0, .y = 0 };
    defer CFRelease(e);
    return CGEventGetLocation(e);
}

/// Drag a window's bottom-right corner from its current size to
/// (to_w, to_h), the way a user resizes it: mouseDown on the corner, a run
/// of dragged events one display frame apart, then mouseUp. This is what
/// puts the view into `inLiveResize` and AppKit into its resize
/// event-tracking run loop.
///
/// `win` must carry the window's CURRENT on-screen bounds and CGWindowID
/// (CGWindowList coordinates: top-left origin, y down — the same space
/// CGEvent uses).
pub fn dragResizeWindowByMouse(
    pid: i32,
    win: MainWindow,
    to_w: f64,
    to_h: f64,
    steps: u32,
) bool {
    const bounds = win.bounds;
    // A couple of points inside the corner: exactly on the edge can miss
    // the resize region.
    const grab_x = bounds.x + bounds.w - 3;
    const grab_y = bounds.y + bounds.h - 3;
    const dx = to_w - bounds.w;
    const dy = to_h - bounds.h;

    // The corner is dragged inward, so the end point is the far extreme of
    // the path. Checking both ends before pressing the button means the
    // button is never down over a window that is not ours.
    const end_owner = ownerPidAtPoint(grab_x + dx, grab_y + dy);
    if (end_owner != pid) {
        std.debug.print(
            "[gui] drag end point ({d:.0},{d:.0}) is owned by pid {d}, not {d}; not dragging\n",
            .{ grab_x + dx, grab_y + dy, end_owner, pid },
        );
        dumpWindowsAtPoint(grab_x + dx, grab_y + dy);
        return false;
    }

    const restore = cursorLocation();
    defer _ = CGWarpMouseCursorPosition(restore);

    if (!postMouseChecked(pid, kCGEventMouseMoved, grab_x, grab_y)) return false;
    gui_io.sleepNs(50 * std.time.ns_per_ms);
    if (!postMouseChecked(pid, kCGEventLeftMouseDown, grab_x, grab_y)) return false;
    gui_io.sleepNs(50 * std.time.ns_per_ms);

    const n: f64 = @floatFromInt(@max(1, steps));
    var i: u32 = 1;
    while (i <= steps) : (i += 1) {
        const t: f64 = @as(f64, @floatFromInt(i)) / n;
        // Deliberately unchecked: the button is already down, so these go
        // to the window that started the tracking regardless of what the
        // shrinking frame now leaves under the pointer.
        const e = CGEventCreateMouseEvent(null, kCGEventLeftMouseDragged, .{
            .x = grab_x + dx * t,
            .y = grab_y + dy * t,
        }, kCGMouseButtonLeft);
        if (e) |ev| {
            CGEventSetIntegerValueField(ev, kCGMouseEventClickState, 1);
            CGEventPost(kCGHIDEventTap, ev);
            CFRelease(ev);
        }
        gui_io.sleepNs(16 * std.time.ns_per_ms);
    }

    const up = CGEventCreateMouseEvent(null, kCGEventLeftMouseUp, .{
        .x = grab_x + dx,
        .y = grab_y + dy,
    }, kCGMouseButtonLeft);
    if (up) |ev| {
        CGEventSetIntegerValueField(ev, kCGMouseEventClickState, 1);
        CGEventPost(kCGHIDEventTap, ev);
        CFRelease(ev);
    }
    gui_io.sleepNs(100 * std.time.ns_per_ms);
    return true;
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
