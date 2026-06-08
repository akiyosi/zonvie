// windows_window.zig — read-only OS window observation via EnumWindows.
//
// Windows counterpart of macos_window.zig with the same API surface.
// Unlike CGWindowList, Win32 exposes window CLASS NAMES, so counting is
// filtered to Zonvie's own top-level classes ("ZonvieWin" main window,
// "ZonvieExternalWin" external grids — see windows/main.zig and
// windows/ui/external_windows.zig). This structurally excludes noise like
// the IME preedit overlay, drag previews, and dialogs. Strictly read-only.

const std = @import("std");
const W = std.os.windows;

extern "user32" fn EnumWindows(
    cb: *const fn (W.HWND, W.LPARAM) callconv(.winapi) W.BOOL,
    lparam: W.LPARAM,
) callconv(.winapi) W.BOOL;
extern "user32" fn GetWindowThreadProcessId(hwnd: W.HWND, pid: ?*W.DWORD) callconv(.winapi) W.DWORD;
extern "user32" fn IsWindowVisible(hwnd: W.HWND) callconv(.winapi) W.BOOL;
extern "user32" fn GetClassNameW(hwnd: W.HWND, out: [*]u16, max: i32) callconv(.winapi) i32;
extern "user32" fn GetWindowRect(hwnd: W.HWND, rect: *W.RECT) callconv(.winapi) W.BOOL;
extern "user32" fn PostMessageW(hwnd: W.HWND, msg: W.UINT, wParam: W.WPARAM, lParam: W.LPARAM) callconv(.winapi) W.BOOL;
extern "user32" fn SetForegroundWindow(hwnd: W.HWND) callconv(.winapi) W.BOOL;

const main_class = std.unicode.utf8ToUtf16LeStringLiteral("ZonvieWin");
const external_class = std.unicode.utf8ToUtf16LeStringLiteral("ZonvieExternalWin");

fn classOf(hwnd: W.HWND, buf: *[64]u16) []const u16 {
    const n = GetClassNameW(hwnd, buf, buf.len);
    if (n <= 0) return buf[0..0];
    return buf[0..@intCast(n)];
}

fn isZonvieClass(name: []const u16) bool {
    return std.mem.eql(u16, name, main_class) or std.mem.eql(u16, name, external_class);
}

const CountCtx = struct { pid: W.DWORD, count: u32 };

fn countCb(hwnd: W.HWND, lparam: W.LPARAM) callconv(.winapi) W.BOOL {
    const ctx: *CountCtx = @ptrFromInt(@as(usize, @bitCast(lparam)));
    var wpid: W.DWORD = 0;
    _ = GetWindowThreadProcessId(hwnd, &wpid);
    if (wpid != ctx.pid) return 1;
    if (IsWindowVisible(hwnd) == 0) return 1;
    var buf: [64]u16 = undefined;
    if (!isZonvieClass(classOf(hwnd, &buf))) return 1;
    ctx.count += 1;
    return 1;
}

/// Count visible top-level Zonvie windows (main + external grids) owned by
/// `pid`. Scenarios assert RELATIVE count changes.
pub fn windowCountForPid(pid: i32) u32 {
    var ctx = CountCtx{ .pid = @intCast(pid), .count = 0 };
    _ = EnumWindows(countCb, @bitCast(@intFromPtr(&ctx)));
    return ctx.count;
}

pub const Bounds = struct { x: f64, y: f64, w: f64, h: f64 };

const BoundsCtx = struct { pid: W.DWORD, found: ?Bounds = null };

fn boundsCb(hwnd: W.HWND, lparam: W.LPARAM) callconv(.winapi) W.BOOL {
    const ctx: *BoundsCtx = @ptrFromInt(@as(usize, @bitCast(lparam)));
    var wpid: W.DWORD = 0;
    _ = GetWindowThreadProcessId(hwnd, &wpid);
    if (wpid != ctx.pid) return 1;
    if (IsWindowVisible(hwnd) == 0) return 1;
    var buf: [64]u16 = undefined;
    if (!std.mem.eql(u16, classOf(hwnd, &buf), main_class)) return 1;
    var r: W.RECT = undefined;
    if (GetWindowRect(hwnd, &r) == 0) return 1;
    ctx.found = .{
        .x = @floatFromInt(r.left),
        .y = @floatFromInt(r.top),
        .w = @floatFromInt(r.right - r.left),
        .h = @floatFromInt(r.bottom - r.top),
    };
    return 0; // stop enumeration
}

/// Bounds of the app's MAIN window (class "ZonvieWin"), or null.
pub fn mainWindowBoundsForPid(pid: i32) ?Bounds {
    var ctx = BoundsCtx{ .pid = @intCast(pid) };
    _ = EnumWindows(boundsCb, @bitCast(@intFromPtr(&ctx)));
    return ctx.found;
}

const HandleCtx = struct { pid: W.DWORD, found: ?W.HWND = null };

fn handleCb(hwnd: W.HWND, lparam: W.LPARAM) callconv(.winapi) W.BOOL {
    const ctx: *HandleCtx = @ptrFromInt(@as(usize, @bitCast(lparam)));
    var wpid: W.DWORD = 0;
    _ = GetWindowThreadProcessId(hwnd, &wpid);
    if (wpid != ctx.pid) return 1;
    if (IsWindowVisible(hwnd) == 0) return 1;
    var buf: [64]u16 = undefined;
    if (!std.mem.eql(u16, classOf(hwnd, &buf), main_class)) return 1;
    ctx.found = hwnd;
    return 0; // stop enumeration
}

/// HWND of the app's MAIN window (class "ZonvieWin"), or null.
pub fn mainWindowHandleForPid(pid: i32) ?W.HWND {
    var ctx = HandleCtx{ .pid = @intCast(pid) };
    _ = EnumWindows(handleCb, @bitCast(@intFromPtr(&ctx)));
    return ctx.found;
}

const WM_MOUSEWHEEL: W.UINT = 0x020A;
const WHEEL_DELTA: i32 = 120;

/// Synthesize `notches` physical wheel notches at screen point (x_px, y_px).
/// Positive notches scroll up, negative scroll down (Win32 convention).
/// Posts WM_MOUSEWHEEL to the main window so the frontend's real wheel
/// handler runs — this exercises the input path the GUI normally drives.
pub fn sendWheel(pid: i32, notches: i32, x_px: i32, y_px: i32) bool {
    const hwnd = mainWindowHandleForPid(pid) orelse return false;
    _ = SetForegroundWindow(hwnd);
    const delta: i32 = notches * WHEEL_DELTA;
    // wParam: high word = wheel delta (signed), low word = key state (0).
    const wparam: W.WPARAM = @as(u32, @bitCast(delta)) << 16;
    // lParam: low word = x, high word = y (screen coordinates).
    const lo: u32 = @as(u32, @bitCast(x_px)) & 0xFFFF;
    const hi: u32 = @as(u32, @bitCast(y_px)) & 0xFFFF;
    const lparam: W.LPARAM = @bitCast(@as(usize, (hi << 16) | lo));
    return PostMessageW(hwnd, WM_MOUSEWHEEL, wparam, lparam) != 0;
}

const DumpCtx = struct { pid: W.DWORD };

fn dumpCb(hwnd: W.HWND, lparam: W.LPARAM) callconv(.winapi) W.BOOL {
    const ctx: *DumpCtx = @ptrFromInt(@as(usize, @bitCast(lparam)));
    var wpid: W.DWORD = 0;
    _ = GetWindowThreadProcessId(hwnd, &wpid);
    if (wpid != ctx.pid) return 1;
    if (IsWindowVisible(hwnd) == 0) return 1;
    var buf: [64]u16 = undefined;
    const name16 = classOf(hwnd, &buf);
    var name8: [64]u8 = undefined;
    const n8 = std.unicode.utf16LeToUtf8(&name8, name16) catch 0;
    var r: W.RECT = std.mem.zeroes(W.RECT);
    _ = GetWindowRect(hwnd, &r);
    std.debug.print(
        "[gui]   window: class={s} x={d} y={d} w={d} h={d}\n",
        .{ name8[0..n8], r.left, r.top, r.right - r.left, r.bottom - r.top },
    );
    return 1;
}

/// Debug helper: print class and bounds of every visible top-level window
/// owned by `pid`. Used by waitWindowCount on failure.
pub fn dumpWindowsForPid(pid: i32) void {
    var ctx = DumpCtx{ .pid = @intCast(pid) };
    _ = EnumWindows(dumpCb, @bitCast(@intFromPtr(&ctx)));
}
