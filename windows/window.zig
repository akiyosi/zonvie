const std = @import("std");
const app_mod = @import("app.zig");
const App = app_mod.App;
const core = @import("zonvie_core");
const d3d11 = app_mod.d3d11;
const dwrite_d2d = app_mod.dwrite_d2d;
const c = app_mod.c;
const applog = app_mod.applog;
const builtin = @import("builtin");
const config_mod = app_mod.config_mod;
const scroll_types = app_mod.scroll_types;

// Sub-module imports
const callbacks = @import("callbacks.zig");
const tabline_mod = @import("ui/tabbar.zig");
const messages = @import("ui/messages.zig");
const external_windows = @import("ui/external_windows.zig");
const scrollbar = @import("ui/scrollbar.zig");
const input = @import("input.zig");
const dialogs = @import("ui/dialogs.zig");
const drop_target = @import("ui/drop_target.zig");
const render_helpers = @import("render_pipeline_helpers.zig");
const smooth_session = @import("scroll/session.zig");
const ease_math = @import("scroll/ease_math.zig");
const scroll_route = app_mod.scroll_route;

/// dwData tag identifying a single-instance file-open message (see main.zig's
/// single-instance forwarding and the WM_COPYDATA handler below). 'ZONV'.
pub const ZONVIE_COPYDATA_MAGIC: usize = 0x5A4F4E56;

/// Neovim command-line escape for a single byte of a file path. Returns the
/// escaped multi-byte sequence, or null if the byte needs no escaping. Shared
/// by the WM_DROPFILES handler and the single-instance forwarding path
/// (main.zig) so both escape identically; the set matches the macOS
/// `escapePathForNeovim`. `$` and `` ` `` are included so Neovim does not
/// perform environment-variable / backtick expansion on a literal path.
pub fn escapeNeovimByte(ch: u8) ?[]const u8 {
    return switch (ch) {
        '\\' => "\\\\",
        ' ' => "\\ ",
        '%' => "\\%",
        '#' => "\\#",
        '|' => "\\|",
        '"' => "\\\"",
        '\'' => "\\'",
        '[' => "\\[",
        ']' => "\\]",
        '{' => "\\{",
        '}' => "\\}",
        '$' => "\\$",
        '`' => "\\`",
        else => null,
    };
}

/// HWND_TOPMOST / HWND_NOTOPMOST are ((HWND)-1) / ((HWND)-2); translate-c's
/// cast to HWND ([*c]HWND__, align 4) trips Zig's pointer alignment check.
/// Win32 USER handles are opaque values, never dereferenced, so redeclare
/// SetWindowPos with an align-agnostic insert-after pointer (same approach as
/// input.zig's IME overlay).
const HWND_TOPMOST_PTR: *const anyopaque = @ptrFromInt(std.math.maxInt(usize));
const HWND_NOTOPMOST_PTR: *const anyopaque = @ptrFromInt(std.math.maxInt(usize) - 1);
extern "user32" fn SetWindowPos(
    hWnd: c.HWND,
    hWndInsertAfter: ?*const anyopaque,
    X: c_int,
    Y: c_int,
    cx: c_int,
    cy: c_int,
    uFlags: c.UINT,
) callconv(.winapi) c.BOOL;

/// Add or remove WS_EX_TOPMOST on a decorated external window without moving,
/// resizing or activating it.
fn setExternalWindowTopmost(hwnd: c.HWND, topmost: bool) void {
    _ = SetWindowPos(
        hwnd,
        if (topmost) HWND_TOPMOST_PTR else HWND_NOTOPMOST_PTR,
        0,
        0,
        0,
        0,
        c.SWP_NOMOVE | c.SWP_NOSIZE | c.SWP_NOACTIVATE,
    );
}

/// Turn a shell file drop into editor input.
///
/// `force_cmdline` is set by the external cmdline window: a drop there means
/// "put this path here" no matter what mode the editor reports. The main
/// window leaves it false and keeps deciding by mode, so a drop while the
/// built-in (non-external) command line is up still expands the path.
/// Whether a drop on this target inserts a path rather than opening the file.
///
/// The drop target decides. `force_cmdline` comes from the external cmdline
/// window itself. Otherwise this is the main window: when the command line has
/// its own window the main window is purely the buffer and a drop here opens
/// the file, so only the built-in bottom row ([cmdline] external = false) makes
/// a drop mean "put the path here". The drag-time badge (ui/drop_target.zig)
/// reads the same answer, so what the pointer promises is what the drop does.
pub fn dropInsertsPath(app: *app_mod.App, force_cmdline: bool) bool {
    if (force_cmdline) return true;
    const corep = app.corep orelse return false;

    app.mu.lockUncancelable(core.clock.io());
    const has_external_cmdline = app.external_windows.contains(CMDLINE_GRID_ID);
    app.mu.unlock(core.clock.io());
    if (has_external_cmdline) return false;

    const mode_ptr: [*:0]const u8 = app_mod.zonvie_core_get_current_mode(corep);
    return std.mem.startsWith(u8, std.mem.span(mode_ptr), "cmdline");
}

pub fn handleDroppedFiles(app: *app_mod.App, hDrop: c.HDROP, force_cmdline: bool) void {
    const corep = app.corep orelse return;
    const file_count = c.DragQueryFileW(hDrop, 0xFFFFFFFF, null, 0);
    if (file_count == 0) return;

    // Build a single command buffer: "drop path1 path2 ..."
    // or just "path1 path2 ..." for cmdline insertion.
    var cmd_buf: [32768]u8 = undefined;
    var pos: usize = 0;

    const is_cmdline = dropInsertsPath(app, force_cmdline);

    if (!is_cmdline) {
        const prefix = "drop ";
        @memcpy(cmd_buf[pos..][0..prefix.len], prefix);
        pos += prefix.len;
    }

    var i: c.UINT = 0;
    while (i < file_count) : (i += 1) {
        const required_len = c.DragQueryFileW(hDrop, i, null, 0);
        if (required_len == 0) continue;

        const buf_len = required_len + 1;
        var stack_buf: [c.MAX_PATH + 1]c.WCHAR = undefined;
        const heap_buf = if (buf_len > stack_buf.len)
            std.heap.page_allocator.alloc(c.WCHAR, buf_len) catch continue
        else
            null;
        defer if (heap_buf) |hb| std.heap.page_allocator.free(hb);

        const path_buf = if (heap_buf) |hb| hb.ptr else &stack_buf;
        const len = c.DragQueryFileW(hDrop, i, path_buf, @intCast(buf_len));
        if (len == 0) continue;

        const wide_slice: []const u16 = @as([*]const u16, @ptrCast(path_buf))[0..len];

        var utf8_stack: [c.MAX_PATH * 4]u8 = undefined;
        const utf8_max = len * 4;
        const utf8_heap = if (utf8_max > utf8_stack.len)
            std.heap.page_allocator.alloc(u8, utf8_max) catch continue
        else
            null;
        defer if (utf8_heap) |hb| std.heap.page_allocator.free(hb);

        const utf8_dest = if (utf8_heap) |hb| hb else &utf8_stack;
        const utf8_len = std.unicode.utf16LeToUtf8(utf8_dest, wide_slice) catch continue;
        const utf8_path = utf8_dest[0..utf8_len];

        // Add space separator between paths
        if (i > 0 or (!is_cmdline and pos > 5)) {
            if (pos < cmd_buf.len) {
                cmd_buf[pos] = ' ';
                pos += 1;
            }
        }

        // Escape special characters for Neovim
        for (utf8_path) |ch| {
            if (pos + 2 > cmd_buf.len) break;
            if (escapeNeovimByte(ch)) |esc| {
                if (pos + esc.len <= cmd_buf.len) {
                    @memcpy(cmd_buf[pos..][0..esc.len], esc);
                    pos += esc.len;
                }
            } else {
                cmd_buf[pos] = ch;
                pos += 1;
            }
        }
    }

    if (pos == 0) return;
    if (is_cmdline) {
        // Insert paths at the cursor position.
        app_mod.zonvie_core_send_input(corep, &cmd_buf, @intCast(pos));
    } else {
        // Normal/insert/visual mode: execute :drop immediately.
        app_mod.zonvie_core_send_command(corep, &cmd_buf, pos);
    }
}

// Load a system cursor by integer resource ID (avoids MAKEINTRESOURCE alignment issues with odd values)
fn loadSystemCursor(id: usize) c.HCURSOR {
    const RawLoadCursorFn = *const fn (?*anyopaque, usize) callconv(.winapi) ?*anyopaque;
    const load_fn: RawLoadCursorFn = @ptrCast(&c.LoadCursorW);
    return @ptrCast(@alignCast(load_fn(null, id)));
}

fn messageTimerMilliseconds(timeout_sec: f32) c.UINT {
    if (!std.math.isFinite(timeout_sec) or timeout_sec <= 0) return 0;

    const timeout_ms = @as(f64, timeout_sec) * 1000.0;
    const max_timeout_ms: c.UINT = @intCast(c.USER_TIMER_MAXIMUM);
    if (timeout_ms >= @as(f64, @floatFromInt(max_timeout_ms))) return max_timeout_ms;
    return @intFromFloat(timeout_ms);
}

// DWM titlebar immersive-dark-mode attribute. Defined locally so the code
// compiles against older mingw-w64 headers that may predate this constant.
//
// Officially documented as Windows 11 22000+ only (see DWMWINDOWATTRIBUTE).
// Works empirically on Windows 10 19041+ as well, which is what most
// Win32 dark-mode-aware apps rely on. On systems where the attribute is
// not supported, DwmSetWindowAttribute returns E_INVALIDARG and the
// titlebar simply stays at its default color — that failure is intentional
// and the HRESULT is discarded at every call site.
const DWMWA_USE_IMMERSIVE_DARK_MODE: c.DWORD = 20;

// HKEY_CURRENT_USER cannot be expressed as a Zig pointer constant: zig's
// comptime alignment check rejects the magic 0x80000001 sentinel because
// the underlying HKEY type is align(4). Bind RegGetValueW through @extern
// with a usize-typed hkey parameter — the Win64 ABI passes the pointer as
// an integer-sized register anyway.
const RegGetValueW_usizeFn = *const fn (
    hkey: usize,
    lpSubKey: ?[*:0]const u16,
    lpValue: ?[*:0]const u16,
    dwFlags: c.DWORD,
    pdwType: ?*c.DWORD,
    pvData: ?*anyopaque,
    pcbData: ?*c.DWORD,
) callconv(.winapi) c.LONG;

// Read the user's OS-wide app theme preference (Settings → Personalization
// → Colors → "Choose your mode"). Returns true if dark mode is selected,
// false otherwise (including when the registry value cannot be read).
//
// Microsoft's officially-recommended path is
// `Windows.UI.ViewManagement.UISettings.GetColorValue(UIColorType.Foreground)`
// through WinRT, but every Win32 dark-mode-aware app (Windows Terminal,
// VSCode's electron shell, Chromium) ends up reading this registry key
// directly because pulling in a WinRT activation for a one-bit query is
// disproportionate. `Personalize\AppsUseLightTheme` is a stable user-mode
// value on every supported Windows build, so the failure path here is
// effectively unreachable on a sane system; we still default to "light"
// to match the value's own missing-state semantics.
pub fn osAppThemeIsDark() bool {
    var apps_use_light_theme: c.DWORD = 1; // default light if read fails
    var data_size: c.DWORD = @sizeOf(c.DWORD);
    const subkey = std.unicode.utf8ToUtf16LeStringLiteral(
        "Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize",
    );
    const value = std.unicode.utf8ToUtf16LeStringLiteral("AppsUseLightTheme");
    const HKEY_CURRENT_USER: usize = 0x80000001;
    const reg_get_value_w: RegGetValueW_usizeFn = @extern(
        RegGetValueW_usizeFn,
        .{ .name = "RegGetValueW" },
    );
    _ = reg_get_value_w(
        HKEY_CURRENT_USER,
        subkey,
        value,
        c.RRF_RT_REG_DWORD,
        null,
        &apps_use_light_theme,
        &data_size,
    );
    return apps_use_light_theme == 0;
}

// UI-thread cached copy of `osAppThemeIsDark()`. The custom titlebar / tabline
// renderer (drawTablineContent) reads this on every WM_PAINT to pick its
// palette, so we MUST NOT call osAppThemeIsDark() (a registry syscall) from
// the paint hot path. The cache is refreshed by applyOsTitlebarTheme() and
// handleThemeReread(), which run only at initial bring-up, on theme-change
// notifications, and from the registry watcher.
//
// Only the UI thread reads/writes this; no synchronisation needed.
pub var g_os_dark_theme_cached: bool = false;

// Apply the user's OS light/dark theme preference to the DWM titlebar and
// refresh the cached dark-mode flag in the same call. Called from WM_CREATE
// (initial frame) and from theme-change handlers. Works regardless of
// ext-tabline state: the custom tabline (when ext-tabline=titlebar) covers
// the caption area itself, but the system min/max/close buttons, resize
// border, and alt-tab / window-switch chrome still come from DWM and follow
// this bit. HRESULT is ignored — pre-19041 Windows 10 builds simply no-op.
pub fn applyOsTitlebarTheme(hwnd: c.HWND) void {
    g_os_dark_theme_cached = osAppThemeIsDark();
    var dark_mode: c.BOOL = if (g_os_dark_theme_cached) 1 else 0;
    _ = c.DwmSetWindowAttribute(
        hwnd,
        DWMWA_USE_IMMERSIVE_DARK_MODE,
        &dark_mode,
        @sizeOf(c.BOOL),
    );
}

// Win11 22H2+ system backdrop. Setting an acrylic backdrop makes window
// transparency show a frosted blur of what's behind, and DWM draws a drop
// shadow for the window — both of which a plain per-pixel-alpha borderless
// window cannot get (the shadow trick, DwmExtendFrameIntoClientArea with a
// real backdrop, otherwise renders an opaque frame behind the client and
// defeats transparency). HRESULT is ignored: pre-22H2 builds no-op.
const DWMWA_SYSTEMBACKDROP_TYPE: c.DWORD = 38;
const DWMSBT_TRANSIENTWINDOW: c_int = 3; // acrylic

// Enable the acrylic backdrop + sheet-of-glass frame extension so the backdrop
// fills the whole client and the window gets its shadow back. Call when blur is
// enabled (config [window] blur = true). Idempotent.
pub fn applyWindowBackdrop(hwnd: c.HWND) void {
    var backdrop: c_int = DWMSBT_TRANSIENTWINDOW;
    _ = c.DwmSetWindowAttribute(
        hwnd,
        DWMWA_SYSTEMBACKDROP_TYPE,
        &backdrop,
        @sizeOf(c_int),
    );
    // Sheet of glass: extend the (now acrylic) frame across the entire client.
    const margins = c.MARGINS{ .cxLeftWidth = -1, .cxRightWidth = -1, .cyTopHeight = -1, .cyBottomHeight = -1 };
    _ = c.DwmExtendFrameIntoClientArea(hwnd, &margins);
}

// WM_SETTINGCHANGE dispatch helper for any top-level window that wants its
// DWM titlebar to follow the OS app theme. Returns true if the message was
// the "ImmersiveColorSet" broadcast and the theme was re-applied.
//
// "ImmersiveColorSet" is a de-facto broadcast string the Windows shell
// sends when the user toggles light/dark mode. It is NOT in the public
// WM_SETTINGCHANGE documentation — the officially-supported live-tracking
// path is `Windows.UI.ViewManagement.UISettings.ColorValuesChanged` through
// WinRT. We listen for it here because every Win32 dark-mode app does
// (Windows Terminal, Chromium, VSCode), and pair it with WM_THEMECHANGED
// (a documented Win32 message) via handleThemeChanged() so theme tracking
// still works if a future Windows build stops broadcasting the string.
//
// Performs a NUL-terminated wide-string compare so shorter lParam values
// like "intl" / "Policy" / "Environment" do not read past their NUL into
// adjacent memory. Skips windows without WS_CAPTION (caption-less popups
// such as ext-cmdline / popupmenu / msg overlays) since DwmSetWindowAttribute
// has nothing to colour for them.
pub fn handleImmersiveColorSet(hwnd: c.HWND, lParam: c.LPARAM) bool {
    if (lParam == 0) return false;
    const param_ptr: [*:0]const u16 = @ptrFromInt(@as(usize, @bitCast(lParam)));
    const expected = [_:0]u16{ 'I', 'm', 'm', 'e', 'r', 's', 'i', 'v', 'e', 'C', 'o', 'l', 'o', 'r', 'S', 'e', 't' };
    var i: usize = 0;
    while (i < expected.len) : (i += 1) {
        const got = param_ptr[i];
        if (got == 0 or got != expected[i]) return false;
    }
    if (param_ptr[expected.len] != 0) return false;
    const style: c.LONG = c.GetWindowLongW(hwnd, c.GWL_STYLE);
    if ((@as(c.DWORD, @bitCast(style)) & c.WS_CAPTION) == 0) return false;
    applyOsTitlebarTheme(hwnd);
    // ext-tabline=titlebar paints its own custom titlebar inside the client
    // area whose palette is picked from g_os_dark_theme_cached at paint
    // time. Force a repaint so the tabline texture is regenerated with the
    // new palette even if the registry-watcher path is unavailable.
    _ = c.InvalidateRect(hwnd, null, 0);
    return true;
}

// =========================================================================
// OS theme live-tracking (RegNotifyChangeKeyValue worker)
// =========================================================================
//
// Microsoft's officially-supported channel for color-mode change events is
// `UISettings.ColorValuesChanged` (WinRT). Adopting it would pull in COM
// activation and a runtimeobject link, which is heavy for a one-bit query.
// Instead we watch the underlying registry key the OS updates whenever the
// user toggles light/dark mode (`HKCU\Software\Microsoft\Windows\
// CurrentVersion\Themes\Personalize`) with `RegNotifyChangeKeyValue` — a
// stable, documented Win32 API. A single worker thread arms the
// notification with an async event, waits on (change_event, stop_event)
// via WaitForMultipleObjects, and posts WM_APP_THEME_REREAD to the main
// HWND on change. The UI-thread handler then re-applies the theme to every
// caption-bearing top-level window.
//
// Synchronisation contract: the worker only touches its own kernel handles
// and posts a Win32 message; it never enters rendering or input code. The
// UI thread owns DwmSetWindowAttribute calls.

var g_theme_watch_thread: ?c.HANDLE = null;
var g_theme_watch_stop_event: ?c.HANDLE = null;
var g_theme_watch_main_hwnd: c.HWND = null;

// HKEY-using extern bindings re-typed to usize for the same reason
// osAppThemeIsDark() needs: HKEY's align(4) trips zig's comptime check
// when we'd otherwise pass a sentinel pointer literal.
const RegOpenKeyExW_usizeFn = *const fn (
    hkey: usize,
    lpSubKey: ?[*:0]const u16,
    ulOptions: c.DWORD,
    samDesired: c.REGSAM,
    phkResult: *c.HKEY,
) callconv(.winapi) c.LONG;

fn themeWatchThread(_: ?*anyopaque) callconv(.winapi) c.DWORD {
    const main_hwnd = g_theme_watch_main_hwnd;
    if (main_hwnd == null) return 1;

    const HKEY_CURRENT_USER: usize = 0x80000001;
    const reg_open: RegOpenKeyExW_usizeFn = @extern(
        RegOpenKeyExW_usizeFn,
        .{ .name = "RegOpenKeyExW" },
    );
    const subkey = std.unicode.utf8ToUtf16LeStringLiteral(
        "Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize",
    );
    var hkey: c.HKEY = undefined;
    if (reg_open(HKEY_CURRENT_USER, subkey, 0, c.KEY_NOTIFY, &hkey) != c.ERROR_SUCCESS) {
        return 1;
    }
    defer _ = c.RegCloseKey(hkey);

    const change_event = c.CreateEventW(null, 1, 0, null);
    if (change_event == null) return 1;
    defer _ = c.CloseHandle(change_event);

    while (true) {
        _ = c.ResetEvent(change_event);
        const r = c.RegNotifyChangeKeyValue(
            hkey,
            0, // bWatchSubtree = FALSE
            c.REG_NOTIFY_CHANGE_LAST_SET,
            change_event,
            1, // fAsynchronous = TRUE
        );
        if (r != c.ERROR_SUCCESS) break;

        const stop_event = g_theme_watch_stop_event orelse break;
        var handles = [_]c.HANDLE{ change_event.?, stop_event };
        const wait_r = c.WaitForMultipleObjects(2, &handles, 0, c.INFINITE);
        if (wait_r == c.WAIT_OBJECT_0) {
            // Registry changed — ask the UI thread to re-apply. Do not call
            // DwmSetWindowAttribute from this thread; PostMessageW is the
            // only synchronisation point.
            _ = c.PostMessageW(main_hwnd, WM_APP_THEME_REREAD, 0, 0);
            continue;
        }
        // Stop signalled (WAIT_OBJECT_0 + 1) or wait failed — exit.
        break;
    }
    return 0;
}

pub fn startThemeWatcher(main_hwnd: c.HWND) void {
    if (g_theme_watch_thread != null) return; // already running
    g_theme_watch_main_hwnd = main_hwnd;
    g_theme_watch_stop_event = c.CreateEventW(null, 1, 0, null);
    if (g_theme_watch_stop_event == null) return;
    var tid: c.DWORD = 0;
    g_theme_watch_thread = c.CreateThread(
        null,
        0,
        themeWatchThread,
        null,
        0,
        &tid,
    );
    if (g_theme_watch_thread == null) {
        _ = c.CloseHandle(g_theme_watch_stop_event.?);
        g_theme_watch_stop_event = null;
    }
}

pub fn stopThemeWatcher() void {
    if (g_theme_watch_stop_event) |ev| {
        _ = c.SetEvent(ev);
    }
    if (g_theme_watch_thread) |th| {
        // Bounded wait — the worker only blocks in WaitForMultipleObjects,
        // which is woken by SetEvent above. Only close the kernel handles
        // once we have confirmed the worker has exited; closing a handle
        // that another thread is still waiting on is documented as
        // undefined behaviour, so on timeout/error we intentionally leak
        // the thread and event handles (the process is shutting down and
        // the kernel will reclaim them at exit).
        const wait_r = c.WaitForSingleObject(th, 2000);
        if (wait_r == c.WAIT_OBJECT_0) {
            _ = c.CloseHandle(th);
            g_theme_watch_thread = null;
            if (g_theme_watch_stop_event) |ev| {
                _ = c.CloseHandle(ev);
                g_theme_watch_stop_event = null;
            }
        } else {
            if (applog.isEnabled()) applog.appLog(
                "[win] stopThemeWatcher: worker did not exit within 2s (wait_r=0x{x}); leaking handles\n",
                .{wait_r},
            );
        }
    } else {
        // Thread never started (worker creation failed) — safe to drop
        // the standalone event handle here.
        if (g_theme_watch_stop_event) |ev| {
            _ = c.CloseHandle(ev);
            g_theme_watch_stop_event = null;
        }
    }
}

fn enumApplyThemeProc(hwnd: c.HWND, _: c.LPARAM) callconv(.winapi) c.BOOL {
    const style: c.LONG = c.GetWindowLongW(hwnd, c.GWL_STYLE);
    if ((@as(c.DWORD, @bitCast(style)) & c.WS_CAPTION) != 0) {
        applyOsTitlebarTheme(hwnd);
        // The ext-tabline=titlebar mode replaces the system caption with a
        // GDI/D3D-drawn custom titlebar whose palette is picked at paint
        // time from currentTitlebarPalette(). DWM attributes alone don't
        // refresh that surface, so force a repaint to redraw the tabline
        // (and any other client-area UI) under the new theme.
        _ = c.InvalidateRect(hwnd, null, 0);
    }
    return 1;
}

// UI-thread handler for WM_APP_THEME_REREAD. Re-applies the OS-theme
// titlebar setting to every caption-bearing top-level window owned by the
// current (UI) thread — main window, all external windows, and any open
// dialogs are covered in one pass.
fn handleThemeReread() void {
    // Refresh the cache once up-front so even the no-window case (or a
    // future caller that bypasses EnumThreadWindows) leaves the UI-thread
    // dark-mode flag consistent with the OS state.
    g_os_dark_theme_cached = osAppThemeIsDark();
    _ = c.EnumThreadWindows(c.GetCurrentThreadId(), enumApplyThemeProc, 0);
}

// UI-thread handler for WM_APP_OPEN_FONT_PICKER (posted from onGuiFont when
// nvim sends `:set guifont=*`). Opens the modal ChooseFontW dialog and, on
// confirm, writes the chosen font back to nvim's `guifont` as "Family:hN".
// The concrete value returns through the normal option_set -> onGuiFont path
// which applies it (writing "*" would loop; we never write "*").
fn openFontPicker(hwnd: c.HWND, app: *App) void {
    var lf: c.LOGFONTW = std.mem.zeroes(c.LOGFONTW);
    lf.lfCharSet = c.DEFAULT_CHARSET;

    // Seed the dialog with the currently rendered font. Copy under app.mu;
    // never hold the lock across the modal dialog (it would stall rendering).
    var seed_pt: f32 = 14.0;
    {
        app.mu.lockUncancelable(core.clock.io());
        defer app.mu.unlock(core.clock.io());
        if (app.atlas) |*a| {
            a.mu.lockUncancelable(core.clock.io());
            defer a.mu.unlock(core.clock.io());
            seed_pt = a.base_point_size;
            // Seed the current weight/slant so re-opening the dialog reflects a
            // previously-picked Bold/Italic. FW_BOLD == 700, FW_NORMAL == 400.
            lf.lfWeight = if (a.base_bold) 700 else 400;
            lf.lfItalic = if (a.base_italic) 1 else 0;
            var i: usize = 0;
            while (i < 31 and i < a.font_name.len and a.font_name[i] != 0) : (i += 1) {
                lf.lfFaceName[i] = a.font_name[i];
            }
        }
    }

    const hdc = c.GetDC(hwnd);
    const dpi_y: i32 = if (hdc != null) c.GetDeviceCaps(hdc, c.LOGPIXELSY) else 96;
    if (hdc != null) _ = c.ReleaseDC(hwnd, hdc);
    const pt_int: i32 = @intFromFloat(@round(seed_pt));
    lf.lfHeight = -@divTrunc(pt_int * dpi_y, 72);

    var cf: c.CHOOSEFONTW = std.mem.zeroes(c.CHOOSEFONTW);
    cf.lStructSize = @sizeOf(c.CHOOSEFONTW);
    cf.hwndOwner = hwnd;
    cf.lpLogFont = &lf;
    cf.Flags = c.CF_SCREENFONTS | c.CF_FORCEFONTEXIST | c.CF_INITTOLOGFONTSTRUCT;

    if (c.ChooseFontW(&cf) == 0) return; // cancelled or error

    const pt: i32 = @max(1, @divTrunc(cf.iPointSize, 10));

    var face_len: usize = 0;
    while (face_len < lf.lfFaceName.len and lf.lfFaceName[face_len] != 0) : (face_len += 1) {}
    var name_buf: [256]u8 = undefined;
    const name_len = std.unicode.utf16LeToUtf8(&name_buf, lf.lfFaceName[0..face_len]) catch return;

    var val_buf: [320]u8 = undefined;
    const val = std.fmt.bufPrint(&val_buf, "{s}:h{d}", .{ name_buf[0..name_len], pt }) catch return;

    if (app.corep) |corep| {
        // Capture the picked weight/slant so onGuiFont applies it as the base
        // font (guifont carries only family+size). FW_SEMIBOLD == 600.
        app.picked_font_bold.store(lf.lfWeight >= 600, .release);
        app.picked_font_italic.store(lf.lfItalic != 0, .release);
        // Mark the resulting guifont broadcast as an explicit user choice so it
        // overrides config.toml [font] precedence in onGuiFont.
        app.font_picker_selection_pending.store(true, .release);
        const opt = "guifont";
        core.zonvie_core_set_option_value(corep, opt.ptr, opt.len, val.ptr, val.len);
    }
}

// Rewrite nvim's `guifont` to the font currently rendered, so it is never left
// as the literal "*". Without this a `:set guifont=*` that doesn't change the
// value (guifont already "*") sends no option_set, so the picker can never be
// re-triggered; a leftover "*" on a reused nvim would also re-pop or get stuck.
// Picking a font in the dialog overwrites this value.
fn resetGuifontToCurrent(app: *App) void {
    var name_buf: [256]u8 = undefined;
    var name_len: usize = 0;
    var pt: i32 = 14;
    var cur_bold = false;
    var cur_italic = false;
    {
        app.mu.lockUncancelable(core.clock.io());
        defer app.mu.unlock(core.clock.io());
        if (app.atlas) |*a| {
            a.mu.lockUncancelable(core.clock.io());
            defer a.mu.unlock(core.clock.io());
            pt = @intFromFloat(@round(a.base_point_size));
            cur_bold = a.base_bold;
            cur_italic = a.base_italic;
            var u16_len: usize = 0;
            while (u16_len < a.font_name.len and a.font_name[u16_len] != 0) : (u16_len += 1) {}
            name_len = std.unicode.utf16LeToUtf8(&name_buf, a.font_name[0..u16_len]) catch 0;
        }
    }
    if (name_len == 0) return;
    if (pt < 1) pt = 1;
    var val_buf: [320]u8 = undefined;
    const val = std.fmt.bufPrint(&val_buf, "{s}:h{d}", .{ name_buf[0..name_len], pt }) catch return;
    if (app.corep) |corep| {
        // guifont carries only family+size, so preserve the current base
        // weight/slant across this rewrite the same way a pick does: stash it
        // and mark the resulting broadcast as a picker selection. Otherwise the
        // round-trip would reset a previously-picked Bold/Italic to regular.
        app.picked_font_bold.store(cur_bold, .release);
        app.picked_font_italic.store(cur_italic, .release);
        app.font_picker_selection_pending.store(true, .release);
        const opt = "guifont";
        core.zonvie_core_set_option_value(corep, opt.ptr, opt.len, val.ptr, val.len);
    }
}

// WM_THEMECHANGED dispatch helper. WM_THEMECHANGED is a documented Win32
// message, but the documentation only covers theme enable/disable and
// classic-vs-themed transitions — it does NOT contract to fire on a pure
// light↔dark color-mode toggle. The officially-supported live-tracking
// channel for color-mode changes is `UISettings.ColorValuesChanged` via
// WinRT. Until/unless we adopt WinRT, color-mode tracking effectively
// depends on the de-facto "ImmersiveColorSet" broadcast handled in
// handleImmersiveColorSet(). This helper is best-effort: if the OS happens
// to send WM_THEMECHANGED on color-mode toggle (some shell builds do),
// we'll pick it up; otherwise we rely on the WM_SETTINGCHANGE path.
//
// Skips caption-less windows for the same reason as handleImmersiveColorSet().
pub fn handleThemeChanged(hwnd: c.HWND) bool {
    const style: c.LONG = c.GetWindowLongW(hwnd, c.GWL_STYLE);
    if ((@as(c.DWORD, @bitCast(style)) & c.WS_CAPTION) == 0) return false;
    applyOsTitlebarTheme(hwnd);
    // Force a repaint so the custom tabline texture is regenerated with the
    // refreshed palette (same reasoning as in handleImmersiveColorSet).
    _ = c.InvalidateRect(hwnd, null, 0);
    return true;
}

// Type aliases from app_mod (to minimize changes in WndProc)
const ExternalWindow = app_mod.ExternalWindow;
const RowVerts = app_mod.RowVerts;
const PendingExternalWindow = app_mod.PendingExternalWindow;
const PendingExternalVertices = app_mod.PendingExternalVertices;
const PendingGlyph = app_mod.PendingGlyph;
const TablineState = app_mod.TablineState;
const TabEntry = app_mod.TabEntry;
const BufferEntry = app_mod.BufferEntry;
const MiniWindowId = app_mod.MiniWindowId;
const MiniWindowState = app_mod.MiniWindowState;
const MessageWindow = app_mod.MessageWindow;
const TrayIcon = app_mod.TrayIcon;
const PendingMessageRequest = app_mod.PendingMessageRequest;
const DisplayMessage = app_mod.DisplayMessage;
const ScrollbarGeometry = app_mod.ScrollbarGeometry;

// Function aliases from app_mod
const getApp = app_mod.getApp;
const setApp = app_mod.setApp;

// WM_APP_* message constants
const WM_APP_ATLAS_ENSURE_GLYPH = app_mod.WM_APP_ATLAS_ENSURE_GLYPH;
const WM_APP_CREATE_EXTERNAL_WINDOW = app_mod.WM_APP_CREATE_EXTERNAL_WINDOW;
const WM_APP_CURSOR_GRID_CHANGED = app_mod.WM_APP_CURSOR_GRID_CHANGED;
const WM_APP_CLOSE_EXTERNAL_WINDOW = app_mod.WM_APP_CLOSE_EXTERNAL_WINDOW;
const WM_APP_DEFERRED_INIT = app_mod.WM_APP_DEFERRED_INIT;
const WM_APP_SHOW_CONNECT_DIALOG = app_mod.WM_APP_SHOW_CONNECT_DIALOG;

const WM_APP_UPDATE_IME_POSITION = app_mod.WM_APP_UPDATE_IME_POSITION;
const WM_APP_MSG_SHOW = app_mod.WM_APP_MSG_SHOW;
const WM_APP_MSG_CLEAR = app_mod.WM_APP_MSG_CLEAR;
const WM_APP_MINI_UPDATE = app_mod.WM_APP_MINI_UPDATE;
const WM_APP_CLIPBOARD_GET = app_mod.WM_APP_CLIPBOARD_GET;
const WM_APP_CLIPBOARD_SET = app_mod.WM_APP_CLIPBOARD_SET;
const WM_APP_SSH_AUTH_PROMPT = app_mod.WM_APP_SSH_AUTH_PROMPT;
const WM_APP_UPDATE_SCROLLBAR = app_mod.WM_APP_UPDATE_SCROLLBAR;
const WM_APP_UPDATE_EXT_FLOAT_POS = app_mod.WM_APP_UPDATE_EXT_FLOAT_POS;
const WM_APP_TRAY = app_mod.WM_APP_TRAY;
const WM_APP_UPDATE_CURSOR_BLINK = app_mod.WM_APP_UPDATE_CURSOR_BLINK;
const WM_APP_IME_OFF = app_mod.WM_APP_IME_OFF;
const WM_APP_TABLINE_INVALIDATE = app_mod.WM_APP_TABLINE_INVALIDATE;
const WM_APP_QUIT_REQUESTED = app_mod.WM_APP_QUIT_REQUESTED;
const WM_APP_QUIT_TIMEOUT = app_mod.WM_APP_QUIT_TIMEOUT;
const WM_APP_RESIZE_POPUPMENU = app_mod.WM_APP_RESIZE_POPUPMENU;
const WM_APP_UPDATE_CMDLINE_COLORS = app_mod.WM_APP_UPDATE_CMDLINE_COLORS;
const WM_APP_SET_TITLE = app_mod.WM_APP_SET_TITLE;
const WM_APP_DEFERRED_WIN_POS = app_mod.WM_APP_DEFERRED_WIN_POS;
const WM_APP_SHOW_WINDOW = app_mod.WM_APP_SHOW_WINDOW;
const WM_APP_SWP_FRAMECHANGED = app_mod.WM_APP_SWP_FRAMECHANGED;
const WM_APP_POST_SHOW_INIT = app_mod.WM_APP_POST_SHOW_INIT;
const WM_APP_SNAP_MAIN_WINDOW = app_mod.WM_APP_SNAP_MAIN_WINDOW;
const WM_APP_THEME_REREAD = app_mod.WM_APP_THEME_REREAD;
const WM_APP_OPEN_FONT_PICKER = app_mod.WM_APP_OPEN_FONT_PICKER;

// System-menu command id for the "About zonvie" item. Must be < 0xF000 and
// is matched via (wParam & 0xFFF0) in WM_SYSCOMMAND (the OS reserves the low
// 4 bits), so keep it aligned to 16.
const IDM_ABOUT: usize = 0x0010;
// Hoisted to file scope so the comptime UTF-16 conversion is instantiated once
// here rather than inside WndProc (whose cumulative comptime branch budget is
// already near the default quota).
const about_title_w = std.unicode.utf8ToUtf16LeStringLiteral("About zonvie");

// Tray context-menu command ids (TrackPopupMenu TPM_RETURNCMD). Any non-zero
// values work; 0 is returned when the menu is dismissed without a selection.
const IDM_TRAY_OPEN: usize = 1;
const IDM_TRAY_QUIT: usize = 2;
const tray_open_w = std.unicode.utf8ToUtf16LeStringLiteral("Open Zonvie");
const tray_quit_w = std.unicode.utf8ToUtf16LeStringLiteral("Quit");

// Restore the main window from the notification area (close_to_tray). The tray
// icon itself stays registered — it is shared with balloon notifications and
// re-added at startup, so it is not removed here.
fn restoreFromTray(hwnd: c.HWND) void {
    _ = c.ShowWindow(hwnd, c.SW_SHOW);
    if (c.IsIconic(hwnd) != 0) _ = c.ShowWindow(hwnd, c.SW_RESTORE);
    _ = c.SetForegroundWindow(hwnd);
}

fn armMsgThrottleTimer(hwnd: c.HWND, app: *App) void {
    const corep = app.corep orelse {
        _ = c.KillTimer(hwnd, app_mod.TIMER_MSG_THROTTLE);
        return;
    };
    const timeout_ms = app_mod.zonvie_core_try_next_msg_timeout_ms(corep);
    if (timeout_ms == -2) {
        _ = c.SetTimer(hwnd, app_mod.TIMER_MSG_THROTTLE, app_mod.LOCK_RETRY_INTERVAL_MS, null);
    } else if (timeout_ms < 0) {
        _ = c.KillTimer(hwnd, app_mod.TIMER_MSG_THROTTLE);
    } else {
        const delay_ms: c.UINT = @intCast(@max(@as(i64, 1), timeout_ms));
        _ = c.SetTimer(hwnd, app_mod.TIMER_MSG_THROTTLE, delay_ms, null);
    }
}

pub fn postDeviceLostRecovery(hwnd: c.HWND, app: *App) void {
    if (app.device_lost_recovery_cancelled) return;
    if (app.device_lost_recover_posted) return;
    app.device_lost_recover_posted = true;
    if (c.PostMessageW(hwnd, app_mod.WM_APP_DEVICE_LOST_RECOVER, 0, @bitCast(app.window_wake_cookie)) == 0) {
        app.device_lost_recover_posted = false;
        scheduleDeviceLostRetry(hwnd, app);
    }
}

const ReliableWindowMessageContext = struct {
    hwnd: c.HWND,
    message: c.UINT,
    w_param: c.WPARAM,
    l_param: c.LPARAM,
    window_cookie: usize,
    owner_process_id: c.DWORD,
    owner_thread_id: c.DWORD,
    timer: c.HANDLE = null,
};

pub const WINDOW_WAKE_STATE_OFFSET: c_int = 0;

pub fn installWindowWakeCookie(hwnd: c.HWND, cookie: usize) bool {
    c.SetLastError(0);
    const previous = c.SetWindowLongPtrW(hwnd, WINDOW_WAKE_STATE_OFFSET, @bitCast(cookie << 1));
    return previous != 0 or c.GetLastError() == 0;
}

pub fn windowWakeCookie(hwnd: c.HWND) usize {
    return @as(usize, @bitCast(c.GetWindowLongPtrW(hwnd, WINDOW_WAKE_STATE_OFFSET))) >> 1;
}

fn reliableWindowTargetMatches(context: *const ReliableWindowMessageContext) bool {
    var process_id: c.DWORD = 0;
    const thread_id = c.GetWindowThreadProcessId(context.hwnd, &process_id);
    return thread_id == context.owner_thread_id and
        process_id == context.owner_process_id and
        process_id == c.GetCurrentProcessId() and
        windowWakeCookie(context.hwnd) == context.window_cookie;
}

fn recordReliableWindowDeliveryFailure(context: *const ReliableWindowMessageContext) void {
    switch (context.message) {
        app_mod.WM_APP_FLUSH_RETRY_FALLBACK => app_mod.g_flush_retry_delivery_failed.store(true, .release),
        app_mod.WM_APP_EXTERNAL_CREATE_RETRY_FALLBACK => app_mod.g_external_create_retry_delivery_failed.store(true, .release),
        app_mod.WM_APP_DEVICE_LOST_RETRY_FALLBACK => app_mod.g_device_lost_retry_delivery_failed.store(true, .release),
        app_mod.WM_APP_SIZE_REPLAY_FALLBACK => {
            // The main-loop service safely handles both cases. External HWNDs
            // use bit 0 as a durable size-replay marker; setting it on the main
            // HWND is harmless because only external windows are scanned.
            const wake_state: usize = @bitCast(c.GetWindowLongPtrW(context.hwnd, WINDOW_WAKE_STATE_OFFSET));
            _ = c.SetWindowLongPtrW(context.hwnd, WINDOW_WAKE_STATE_OFFSET, @bitCast(wake_state | 1));
            app_mod.g_main_size_replay_delivery_failed.store(true, .release);
            app_mod.g_external_size_replay_delivery_failed.store(true, .release);
        },
        else => {},
    }
    _ = c.InvalidateRect(context.hwnd, null, c.FALSE);
}

fn reliableWindowMessageTimerCallback(raw_context: ?*anyopaque, _: c.BOOLEAN) callconv(.winapi) void {
    const context: *ReliableWindowMessageContext = @ptrCast(@alignCast(raw_context orelse return));
    if (context.timer != null) {
        _ = c.DeleteTimerQueueTimer(null, context.timer, null);
    }

    // Never send a private WM_APP message to a recycled foreign HWND. Bound
    // the worker lifetime as well: after the synchronous attempts, one posted
    // message can remain queued while a hung UI thread recovers without
    // retaining this worker or heap context.
    const max_send_attempts = 4;
    for (0..max_send_attempts) |attempt| {
        if (!reliableWindowTargetMatches(context)) break;
        var send_result: c.DWORD_PTR = 0;
        if (c.SendMessageTimeoutW(
            context.hwnd,
            context.message,
            context.w_param,
            context.l_param,
            c.SMTO_ABORTIFHUNG | c.SMTO_BLOCK,
            125,
            &send_result,
        ) != 0) break;
        if (attempt + 1 < max_send_attempts) c.Sleep(125);
    } else {
        if (reliableWindowTargetMatches(context)) {
            var posted = false;
            for (0..4) |attempt| {
                if (!reliableWindowTargetMatches(context)) break;
                if (c.PostMessageW(context.hwnd, context.message, context.w_param, context.l_param) != 0) {
                    posted = true;
                    break;
                }
                if (attempt + 1 < 4) c.Sleep(125);
            }
            if (!posted and reliableWindowTargetMatches(context)) {
                recordReliableWindowDeliveryFailure(context);
            }
        }
    }
    std.heap.page_allocator.destroy(context);
}

/// SetTimer can fail under USER resource pressure. Use the process timer queue
/// as an independent delayed wake so retry backoff still works without
/// allocating or blocking on the UI/paint thread.
pub fn scheduleReliableWindowMessage(
    hwnd: c.HWND,
    message: c.UINT,
    w_param: c.WPARAM,
    l_param: c.LPARAM,
    delay_ms: u32,
) bool {
    const context = std.heap.page_allocator.create(ReliableWindowMessageContext) catch return false;
    var owner_process_id: c.DWORD = 0;
    const owner_thread_id = c.GetWindowThreadProcessId(hwnd, &owner_process_id);
    const window_cookie: usize = @bitCast(l_param);
    if (owner_thread_id == 0 or owner_process_id != c.GetCurrentProcessId() or windowWakeCookie(hwnd) != window_cookie) {
        std.heap.page_allocator.destroy(context);
        return false;
    }
    context.* = .{
        .hwnd = hwnd,
        .message = message,
        .w_param = w_param,
        .l_param = l_param,
        .window_cookie = window_cookie,
        .owner_process_id = owner_process_id,
        .owner_thread_id = owner_thread_id,
    };
    if (c.CreateTimerQueueTimer(
        &context.timer,
        null,
        reliableWindowMessageTimerCallback,
        context,
        delay_ms,
        0,
        c.WT_EXECUTEONLYONCE,
    ) == 0) {
        std.heap.page_allocator.destroy(context);
        return false;
    }
    return true;
}

pub fn scheduleDeviceLostRetry(hwnd: c.HWND, app: *App) void {
    if (app.device_lost_recovery_cancelled) return;
    const delay_ms = render_helpers.deviceLostRetryDelayMs(app.device_lost_recover_attempts);
    app.device_lost_retry_needed = true;
    app.device_lost_retry_deadline_ms = c.GetTickCount64() + delay_ms;
    if (c.SetTimer(hwnd, app_mod.TIMER_DEVICE_LOST_RETRY, delay_ms, null) != 0) return;
    if (!scheduleReliableWindowMessage(
        hwnd,
        app_mod.WM_APP_DEVICE_LOST_RETRY_FALLBACK,
        0,
        @bitCast(app.window_wake_cookie),
        delay_ms,
    )) {
        // The main-loop deadline remains armed even when both USER timer
        // mechanisms are unavailable.
    }
}

fn releaseRemainingDeviceLostRecoveryPins(app: *App, start_index: usize) void {
    for (app.device_lost_recover_grids.items[start_index..]) |grid_id| {
        external_windows.finishExternalWindowPaint(app, grid_id);
    }
}

pub fn serviceDeferredUiRetries(hwnd: c.HWND, app: *App) void {
    if (app.deferred_ui_service_in_progress) return;
    app.deferred_ui_service_in_progress = true;
    defer {
        app.deferred_ui_service_in_progress = false;
        _ = app.finishActiveOperation();
    }

    const now_ms = c.GetTickCount64();
    smooth_session.servicePendingReset(app);
    smooth_session.serviceDeferredUiWork(app);
    smooth_session.serviceFallbackDeadline(app, now_ms);
    smooth_session.servicePendingResend(app);
    if (app_mod.g_device_lost_retry_delivery_failed.swap(false, .acq_rel)) {
        app.device_lost_retry_needed = true;
    }
    if (app_mod.g_main_size_replay_delivery_failed.swap(false, .acq_rel)) {
        app.main_size_replay_needed = true;
    }
    if (app_mod.g_external_size_replay_delivery_failed.swap(false, .acq_rel)) {
        app.external_size_replay_needed = true;
    }
    external_windows.closePendingExternalWindowsOnUIThread(app);
    if (app.pending_destroy_after_active_operation) return;
    observeFlushRetrySuccess(hwnd, app);
    if (app.device_lost_retry_needed and
        app.device_lost_retry_deadline_ms != 0 and
        app.device_lost_retry_deadline_ms <= now_ms)
    {
        _ = c.KillTimer(hwnd, app_mod.TIMER_DEVICE_LOST_RETRY);
        app.device_lost_retry_needed = false;
        app.device_lost_retry_deadline_ms = 0;
        postDeviceLostRecovery(hwnd, app);
    }
    if (app.main_size_replay_needed and !app.device_lost_recovering) {
        app.main_size_replay_needed = false;
        replayMainSize(hwnd, app);
        if (app.pending_destroy_after_active_operation) return;
    }
    external_windows.serviceDeferredSizeReplays(app);
    if (app.pending_destroy_after_active_operation) return;
    external_windows.serviceDeferredRetries(app, now_ms);
    if (app.pending_destroy_after_active_operation) return;
    if (app.main_paint_retry_deadline_ms != 0 and app.main_paint_retry_deadline_ms <= now_ms) {
        app.main_paint_retry_deadline_ms = 0;
        _ = app.paint_retry.timerFired(app.paint_retry.generation);
        _ = c.InvalidateRect(hwnd, null, c.FALSE);
    }
    if (app.flush_retry_deadline_ms != 0 and app.flush_retry_deadline_ms <= now_ms) {
        consumeFlushRetryWake(hwnd, app);
    }
    armFlushRetryWake(hwnd, app);
}

fn includeDeadline(deadline_ms: u64, now_ms: u64, timeout_ms: *c.DWORD) void {
    if (deadline_ms == 0) return;
    const remaining: c.DWORD = if (deadline_ms <= now_ms)
        0
    else
        @intCast(@min(deadline_ms - now_ms, @as(u64, std.math.maxInt(c.DWORD) - 1)));
    timeout_ms.* = @min(timeout_ms.*, remaining);
}

pub fn nextDeferredUiRetryTimeoutMs(app: *App) c.DWORD {
    if (app.smooth_scroll_reset_pending.load(.acquire)) return 0;
    const now_ms = c.GetTickCount64();
    var timeout_ms: c.DWORD = c.INFINITE;
    includeDeadline(app.device_lost_retry_deadline_ms, now_ms, &timeout_ms);
    includeDeadline(app.flush_retry_deadline_ms, now_ms, &timeout_ms);
    includeDeadline(app.main_paint_retry_deadline_ms, now_ms, &timeout_ms);
    includeDeadline(app.external_create_retry_deadline_ms, now_ms, &timeout_ms);
    includeDeadline(external_windows.nextPaintRetryDeadlineMs(app), now_ms, &timeout_ms);
    includeDeadline(smooth_session.fallbackDeadlineMs(app), now_ms, &timeout_ms);
    return timeout_ms;
}

fn armFlushRetryWake(hwnd: c.HWND, app: *App) void {
    _ = app_mod.g_flush_retry_delivery_failed.swap(false, .acq_rel);
    observeFlushRetrySuccess(hwnd, app);
    const failure_epoch = app_mod.g_flush_retry_failure_epoch.load(.acquire);
    const success_epoch = app_mod.g_flush_retry_success_epoch.load(.acquire);
    if (!render_helpers.retryEpochNeedsArm(
        failure_epoch,
        success_epoch,
        app.flush_retry_consumed_failure_epoch,
    )) return;
    if (app.flush_retry_wake_armed) {
        // Multiple failures before the same retry coalesce. If a success had
        // intervened, observeFlushRetrySuccess() would have cancelled this
        // deadline and the newer epoch would be armed from the base delay.
        app.flush_retry_armed_failure_epoch = failure_epoch;
        return;
    }
    const delay_ms = app.flush_retry_delay_ms;
    app.flush_retry_deadline_ms = c.GetTickCount64() + delay_ms;
    app.flush_retry_wake_armed = true;
    app.flush_retry_armed_failure_epoch = failure_epoch;
    app.flush_retry_fallback_wake_issued = false;
    app.flush_retry_wake_generation +%= 1;
    const wake_generation = app.flush_retry_wake_generation;
    // The deadline above is only consumed by main()'s own message loop, which
    // stops running for the entire duration of any modal loop DefWindowProc
    // enters -- notably a resize/move border drag, where WM_SIZE drives the
    // aborts that armed this retry in the first place. Without an OS-level
    // wake the frame stays stale until the drag ends. WM_TIMER and a posted
    // fallback message are both dispatched by the modal loop, so arm one of
    // them; every sibling retry path (device-lost, paint, external-create,
    // size-replay) already does. Mirrors scheduleMainPaintRetry.
    if (c.SetTimer(hwnd, app_mod.TIMER_FLUSH_RETRY, delay_ms, null) != 0) return;
    if (scheduleReliableWindowMessage(
        hwnd,
        app_mod.WM_APP_FLUSH_RETRY_FALLBACK,
        wake_generation,
        @bitCast(app.window_wake_cookie),
        delay_ms,
    )) {
        app.flush_retry_fallback_wake_issued = true;
        return;
    }
    // Neither OS wake could be armed. The message-loop deadline remains as
    // the last resort; invalidate so at least one more loop turn is
    // guaranteed once the modal loop exits.
    _ = c.InvalidateRect(hwnd, null, c.FALSE);
}

/// True when a message-driven flush retry must be deferred. consumeFlushRetryWake
/// takes grid_mu and runs a complete onFlush, which publishes vertices through
/// app.mu-taking callbacks. Any operation that pumps messages (device-loss
/// recovery runs its rebuild unlocked precisely because DXGI/DComposition pump;
/// Present pumps too) can therefore dispatch a WM_TIMER or the fallback message
/// into the middle of its own critical section. Every sibling timer guards this
/// way -- TIMER_CUSTOM_SHADER_ANIM and TIMER_MAIN_SIZE_REPLAY -- and until the
/// OS wake was armed this path was only ever reached from main()'s own loop,
/// where nesting was impossible.
///
/// deferred_ui_service_in_progress is deliberately NOT included: the polled
/// deadline in serviceDeferredUiRetries runs with that flag set, and it is the
/// path that picks the retry back up after this returns true.
fn flushRetryReentrancyBlocked(app: *const App) bool {
    return app.wm_paint_in_progress or
        app.in_present_shader_animation_frame or
        app.glow_prepare_in_progress or
        app.device_lost_recovering or
        app.external_window_create_in_progress or
        app.main_resize_in_progress or
        app.main_dpi_change_in_progress;
}

fn consumeFlushRetryWake(hwnd: c.HWND, app: *App) void {
    observeFlushRetrySuccess(hwnd, app);
    if (!app.flush_retry_wake_armed) {
        armFlushRetryWake(hwnd, app);
        return;
    }
    const failure_epoch = app.flush_retry_armed_failure_epoch;
    _ = c.KillTimer(hwnd, app_mod.TIMER_FLUSH_RETRY);
    app.flush_retry_wake_armed = false;
    app.flush_retry_fallback_wake_issued = false;
    app.flush_retry_deadline_ms = 0;
    app.flush_retry_armed_failure_epoch = 0;
    if (render_helpers.retryEpochWasCovered(
        failure_epoch,
        app_mod.g_flush_retry_success_epoch.load(.acquire),
    )) return;
    app.flush_retry_consumed_failure_epoch = @max(app.flush_retry_consumed_failure_epoch, failure_epoch);
    app.flush_retry_delay_ms = render_helpers.nextBackoffDelayMs(app.flush_retry_delay_ms, app_mod.FLUSH_RETRY_MAX_MS);
    if (app.corep) |corep| app_mod.zonvie_core_retry_flush(corep);
}

fn observeFlushRetrySuccess(hwnd: c.HWND, app: *App) void {
    const success_epoch = app_mod.g_flush_retry_success_epoch.load(.acquire);
    if (success_epoch <= app.flush_retry_observed_success_epoch) return;
    app.flush_retry_observed_success_epoch = success_epoch;
    app.flush_retry_delay_ms = app_mod.FLUSH_RETRY_INTERVAL_MS;

    if (app.flush_retry_wake_armed and
        render_helpers.retryEpochWasCovered(app.flush_retry_armed_failure_epoch, success_epoch))
    {
        _ = c.KillTimer(hwnd, app_mod.TIMER_FLUSH_RETRY);
        app.flush_retry_wake_armed = false;
        app.flush_retry_fallback_wake_issued = false;
        app.flush_retry_deadline_ms = 0;
        app.flush_retry_armed_failure_epoch = 0;
    }
}

/// Replay a WM_SIZE that was suppressed while another operation was active.
/// The real WM_SIZE handler refuses to resize on SIZE_MINIMIZED, because
/// GetClientRect on a minimized HWND returns 0x0 and the rows/cols derivation
/// clamps that to 1x1, which destroys split proportions in Neovim. A synthetic
/// replay always passes SIZE_RESTORED, so it has to make that check itself.
/// Keep the request pending rather than dropping it; restoring the window also
/// emits a real WM_SIZE, so this converges either way.
fn replayMainSize(hwnd: c.HWND, app: *App) void {
    if (c.IsIconic(hwnd) != 0) {
        app.main_size_replay_needed = true;
        return;
    }
    _ = c.SendMessageW(hwnd, c.WM_SIZE, 0, 0);
}

fn scheduleMainSizeReplay(hwnd: c.HWND, app: *App) void {
    if (c.SetTimer(hwnd, app_mod.TIMER_MAIN_SIZE_REPLAY, app_mod.DEVICE_LOST_RETRY_INTERVAL_MS, null) != 0) return;
    if (!scheduleReliableWindowMessage(
        hwnd,
        app_mod.WM_APP_SIZE_REPLAY_FALLBACK,
        0,
        @bitCast(app.window_wake_cookie),
        app_mod.DEVICE_LOST_RETRY_INTERVAL_MS,
    )) {
        app.main_size_replay_needed = true;
        _ = c.InvalidateRect(hwnd, null, c.FALSE);
    }
}

fn scheduleMainPaintRetry(hwnd: c.HWND, app: *App) void {
    const ticket = app.paint_retry.fail() orelse return;
    app.main_paint_retry_deadline_ms = c.GetTickCount64() + ticket.delay_ms;
    if (!scheduleReliableWindowMessage(
        hwnd,
        app_mod.WM_APP_PAINT_RETRY_FALLBACK,
        ticket.generation,
        @bitCast(app.window_wake_cookie),
        ticket.delay_ms,
    )) _ = app.paint_retry.timerArmFailed(ticket.generation);
}

fn recoverMainPaintFailure(hwnd: c.HWND, app: *App) void {
    app.mu.lockUncancelable(core.clock.io());
    app.surface.paint_full = true;
    app.mu.unlock(core.clock.io());
    app.tbs.rotation_mu.lockUncancelable(core.clock.io());
    app.tbs.pending_paint_full = true;
    app.tbs.rotation_mu.unlock(core.clock.io());

    var device_lost = false;
    if (app.renderer) |*renderer| device_lost = renderer.device_lost;
    if (device_lost) {
        postDeviceLostRecovery(hwnd, app);
    } else {
        scheduleMainPaintRetry(hwnd, app);
    }
}

fn completeMainPaintRetry(app: *App) void {
    app.main_paint_retry_deadline_ms = 0;
    _ = app.paint_retry.succeeded();
}

fn prepareGlowShadersOnUiThread(hwnd: c.HWND, app: *App) void {
    const corep = app.corep orelse {
        app.glow_prepare_posted.store(false, .release);
        return;
    };
    if (!core.zonvie_core_get_glow_enabled(corep)) {
        app.glow_prepare_posted.store(false, .release);
        return;
    }
    if (app.wm_paint_in_progress or
        app.in_present_shader_animation_frame or
        app.device_lost_recovering or
        app.external_window_create_in_progress or
        app.main_resize_in_progress or
        app.main_dpi_change_in_progress or
        app.glow_prepare_in_progress)
    {
        // The normal request is queued before InvalidateRect, so this only
        // happens through a nested message pump. Let the next flush retry.
        app.glow_prepare_posted.store(false, .release);
        return;
    }

    app.glow_prepare_in_progress = true;
    defer {
        app.glow_prepare_in_progress = false;
        _ = app.finishActiveOperation();
    }

    var prepared_any = false;
    if (app.renderer) |*renderer| {
        _ = renderer.prepareBloomShaders();
        prepared_any = true;
        _ = c.InvalidateRect(hwnd, null, c.FALSE);
    }

    // Keep the warm-up snapshot independent from the 60 Hz shader-animation
    // scratch. Shader creation may pump messages, and a nested animation tick
    // must never be able to clear or repopulate this operation's ownership
    // records. This one-time path may allocate; WM_PAINT remains allocation-free.
    var external_grids: std.ArrayListUnmanaged(i64) = .empty;
    defer external_grids.deinit(app.alloc);
    var external_renderers: std.ArrayListUnmanaged(*d3d11.Renderer) = .empty;
    defer external_renderers.deinit(app.alloc);
    app.mu.lockUncancelable(core.clock.io());
    const ext_capacity = app.external_windows.count();
    const snapshot_ready = snapshot: {
        external_grids.ensureTotalCapacity(app.alloc, ext_capacity) catch break :snapshot false;
        external_renderers.ensureTotalCapacity(app.alloc, ext_capacity) catch break :snapshot false;
        var it = app.external_windows.iterator();
        while (it.next()) |entry| {
            const ext_win = entry.value_ptr.*;
            if (ext_win.is_pending_close) continue;
            ext_win.paint_ref_count += 1;
            external_grids.appendAssumeCapacity(entry.key_ptr.*);
            external_renderers.appendAssumeCapacity(&ext_win.renderer);
        }
        break :snapshot true;
    };
    app.mu.unlock(core.clock.io());

    if (!snapshot_ready) {
        app.glow_prepare_posted.store(false, .release);
        return;
    }

    for (external_renderers.items, 0..) |renderer, i| {
        _ = renderer.prepareBloomShaders();
        prepared_any = true;
        _ = c.InvalidateRect(renderer.hwnd, null, c.FALSE);
        external_windows.finishExternalWindowPaint(app, external_grids.items[i]);
    }

    if (!prepared_any) app.glow_prepare_posted.store(false, .release);
}

// Show the tray context menu ("Open Zonvie" / "Quit") at the cursor. "Quit"
// sets tray_quit_requested so the subsequent WM_CLOSE runs the real graceful-
// quit path instead of hiding back to the tray.
fn showTrayMenu(hwnd: c.HWND, app: *App) void {
    const menu = c.CreatePopupMenu() orelse return;
    defer _ = c.DestroyMenu(menu);
    _ = c.AppendMenuW(menu, c.MF_STRING, IDM_TRAY_OPEN, tray_open_w);
    _ = c.AppendMenuW(menu, c.MF_STRING, IDM_TRAY_QUIT, tray_quit_w);

    var pt: c.POINT = undefined;
    _ = c.GetCursorPos(&pt);
    // TrackPopupMenu needs a foreground window to dismiss correctly; the
    // trailing WM_NULL is the documented workaround so the menu closes when
    // the user clicks elsewhere.
    _ = c.SetForegroundWindow(hwnd);
    const cmd = c.TrackPopupMenu(
        menu,
        c.TPM_RETURNCMD | c.TPM_RIGHTBUTTON,
        @intCast(pt.x),
        @intCast(pt.y),
        0,
        hwnd,
        null,
    );
    _ = c.PostMessageW(hwnd, c.WM_NULL, 0, 0);
    switch (@as(usize, @intCast(cmd))) {
        IDM_TRAY_OPEN => restoreFromTray(hwnd),
        IDM_TRAY_QUIT => {
            app.tray_quit_requested = true;
            _ = c.PostMessageW(hwnd, c.WM_CLOSE, 0, 0);
        },
        else => {},
    }
}

// Timer and timing constants
const TIMER_MSG_AUTOHIDE = app_mod.TIMER_MSG_AUTOHIDE;
const TIMER_MINI_AUTOHIDE = app_mod.TIMER_MINI_AUTOHIDE;
const MSG_AUTOHIDE_TIMEOUT = app_mod.MSG_AUTOHIDE_TIMEOUT;
const TIMER_DEVCONTAINER_POLL = app_mod.TIMER_DEVCONTAINER_POLL;
const DEVCONTAINER_POLL_INTERVAL = app_mod.DEVCONTAINER_POLL_INTERVAL;
const TIMER_SCROLLBAR_AUTOHIDE = app_mod.TIMER_SCROLLBAR_AUTOHIDE;
const TIMER_SCROLLBAR_FADE = app_mod.TIMER_SCROLLBAR_FADE;
const TIMER_SCROLLBAR_REPEAT = app_mod.TIMER_SCROLLBAR_REPEAT;
const TIMER_CURSOR_BLINK = app_mod.TIMER_CURSOR_BLINK;
const TIMER_QUIT_TIMEOUT = app_mod.TIMER_QUIT_TIMEOUT;
const TIMER_REPOSITION_FLOATS = app_mod.TIMER_REPOSITION_FLOATS;
const TIMER_TRAY_INIT = app_mod.TIMER_TRAY_INIT;

/// Device-loss teardown detaches under app.mu and calls COM only after the
/// lock is dropped. A Release may synchronously dispatch a nested message.
fn releaseMainRecoveryBuffers(app: *App) void {
    while (true) {
        app.mu.lockUncancelable(core.clock.io());
        var vb = app_mod.detachOneSurfaceGpuVB(&app.surface);
        var row_vb_bytes: usize = 0;
        if (vb == null) {
            if (app_mod.detachOneRowVB(app.row_vbs.items)) |detached| {
                vb = detached.buffer;
                row_vb_bytes = detached.bytes;
            }
        }
        if (vb == null) {
            if (app_mod.detachOneRetentionVB(app.retention_vbs[0..])) |detached| {
                vb = detached.buffer;
                row_vb_bytes = detached.bytes;
            }
        }
        if (vb == null) {
            vb = app.cursor_vb;
            app.cursor_vb = null;
            app.cursor_vb_bytes = 0;
        }
        if (vb == null) {
            vb = app.scrollbar_vb;
            app.scrollbar_vb = null;
            app.scrollbar_vb_bytes = 0;
        }
        app.mu.unlock(core.clock.io());
        if (vb) |buffer| {
            _ = buffer.lpVtbl.*.Release.?(buffer);
            if (row_vb_bytes != 0) {
                app.row_vb_budget.release(
                    &app.row_vb_retained_bytes,
                    row_vb_bytes,
                );
            }
        } else {
            break;
        }
    }
}

fn releaseExternalRecoveryBuffers(app: *App, grid_id: i64, ext_win: *app_mod.ExternalWindow) bool {
    while (true) {
        app.mu.lockUncancelable(core.clock.io());
        if (app.external_windows.get(grid_id) != ext_win) {
            app.mu.unlock(core.clock.io());
            return false;
        }
        var vb = app_mod.detachOneSurfaceGpuVB(&ext_win.surface);
        var row_vb_bytes: usize = 0;
        if (vb == null) {
            if (app_mod.detachOneRowVB(ext_win.row_vbs.items)) |detached| {
                vb = detached.buffer;
                row_vb_bytes = detached.bytes;
            }
        }
        if (vb == null) {
            vb = ext_win.vb;
            ext_win.vb = null;
            ext_win.vb_bytes = 0;
        }
        if (vb == null) {
            vb = ext_win.cursor_vb;
            ext_win.cursor_vb = null;
            ext_win.cursor_vb_bytes = 0;
        }
        if (vb == null) {
            vb = ext_win.scrollbar_vb;
            ext_win.scrollbar_vb = null;
            ext_win.scrollbar_vb_bytes = 0;
        }
        app.mu.unlock(core.clock.io());
        if (vb) |buffer| {
            _ = buffer.lpVtbl.*.Release.?(buffer);
            if (row_vb_bytes != 0) {
                app.row_vb_budget.release(
                    &ext_win.row_vb_retained_bytes,
                    row_vb_bytes,
                );
            }
        } else {
            return true;
        }
    }
}
const TRAY_INIT_DELAY_MS = app_mod.TRAY_INIT_DELAY_MS;
const QUIT_TIMEOUT_MS = app_mod.QUIT_TIMEOUT_MS;
const SCROLLBAR_FADE_INTERVAL = app_mod.SCROLLBAR_FADE_INTERVAL;
const SCROLLBAR_REPEAT_DELAY = app_mod.SCROLLBAR_REPEAT_DELAY;
const SCROLLBAR_REPEAT_INTERVAL = app_mod.SCROLLBAR_REPEAT_INTERVAL;

// Win32 DPI API (Windows 10 v1607+)
extern "user32" fn GetDpiForWindow(hwnd: c.HWND) callconv(.winapi) c.UINT;

// Grid ID constants
const CMDLINE_GRID_ID = app_mod.CMDLINE_GRID_ID;
const POPUPMENU_GRID_ID = app_mod.POPUPMENU_GRID_ID;
const MESSAGE_GRID_ID = app_mod.MESSAGE_GRID_ID;
const MSG_HISTORY_GRID_ID = app_mod.MSG_HISTORY_GRID_ID;

// Styling constants
const CMDLINE_PADDING = app_mod.CMDLINE_PADDING;
const CMDLINE_ICON_SIZE = app_mod.CMDLINE_ICON_SIZE;
const CMDLINE_ICON_MARGIN_LEFT = app_mod.CMDLINE_ICON_MARGIN_LEFT;
const CMDLINE_ICON_MARGIN_RIGHT = app_mod.CMDLINE_ICON_MARGIN_RIGHT;
const CMDLINE_BORDER_WIDTH = app_mod.CMDLINE_BORDER_WIDTH;
const CMDLINE_CORNER_RADIUS = app_mod.CMDLINE_CORNER_RADIUS;
const MSG_PADDING = app_mod.MSG_PADDING;

// Layout helpers are in app_mod (getEffectiveContentWidth, updateLayoutToCore,
// rowHeightPxFromClient, updateRowsColsFromClientForce).
const getEffectiveContentWidth = app_mod.getEffectiveContentWidth;
const updateLayoutToCore = app_mod.updateLayoutToCore;
const rowHeightPxFromClient = app_mod.rowHeightPxFromClient;
const updateRowsColsFromClientForce = app_mod.updateRowsColsFromClientForce;

fn applyMainDpiState(app: *App, new_dpi: u32) void {
    var atlas_ptr: ?*dwrite_d2d.Renderer = null;
    app.mu.lockUncancelable(core.clock.io());
    if (app.atlas) |*a| atlas_ptr = a;
    app.mu.unlock(core.clock.io());

    var metrics: ?struct { w_px: u32, h_px: u32 } = null;
    if (atlas_ptr) |a| {
        const old_dpi = a.dpiValue();
        a.updateDpi(new_dpi);
        const current_metrics = a.cellMetrics();
        metrics = .{ .w_px = current_metrics.w_px, .h_px = current_metrics.h_px };
        if (new_dpi != old_dpi) {
            app.pending_core_glyph_invalidate.store(true, .release);
        }
    }

    app.mu.lockUncancelable(core.clock.io());
    app.dpi_scale = @as(f32, @floatFromInt(new_dpi)) / 96.0;
    if (metrics) |m| {
        if (app.cell_w_px != m.w_px or app.cell_h_px != m.h_px) {
            app.row_layout_gen +%= 1;
            app.shared_metrics_gen +%= 1;
        }
        app.cell_w_px = m.w_px;
        app.cell_h_px = m.h_px;
    }
    app.need_full_seed.store(true, .seq_cst);
    app.seed_pending = true;
    app.seed_clear_pending = true;
    app.row_valid_count = 0;
    if (app.row_valid.bit_length != 0) app.row_valid.unsetAll();
    app.back_tex_valid = false;
    app.last_cursor_rect_px = null;
    app.mu.unlock(core.clock.io());
}

fn updateRowsColsFromClient(hwnd: c.HWND, app: *App) void {
    // Only use client-derived rows/cols as a bootstrap before core provides them.
    if (app.surface.rows != 0 or app.surface.cols != 0) {
        return;
    }
    updateRowsColsFromClientForce(hwnd, app);
}

fn setLogEnabledViaCore(app: *App, enabled: bool) void {
    // 1) core-side switch
    if (app.corep != null) {
        core.zonvie_core_set_log_enabled(app.corep, if (enabled) 1 else 0);
        // Re-apply perf_only/scroll_only on every enable toggle so a runtime
        // toggle of the log flag doesn't reset them to their core defaults (off).
        core.zonvie_core_set_log_perf_only(app.corep, if (app.config.log.perf_only) 1 else 0);
        core.zonvie_core_set_log_scroll_only(app.corep, if (app.config.log.scroll_only) 1 else 0);
        core.zonvie_core_set_log_verbose(app.corep, if (app.config.log.verbose) 1 else 0);
    }

    // 2) app-root switch (Windows side)
    applog.setFilters(app.config.log.perf_only, app.config.log.scroll_only, app.config.log.verbose);
    applog.setEnabled(enabled);
}

// =========================================================================
// Helper: build core.Callbacks struct (shared between WM_CREATE and DEFERRED_INIT)
// =========================================================================
fn makeCoreCbs() core.Callbacks {
    return .{
        .on_vertices_partial = callbacks.onVerticesPartial,
        .on_vertices_row = callbacks.onVerticesRow,
        .on_atlas_ensure_glyph = callbacks.onAtlasEnsureGlyph,
        .on_atlas_ensure_glyph_styled = callbacks.onAtlasEnsureGlyphStyled,
        .on_log = callbacks.onLog,
        .on_guifont = callbacks.onGuiFont,
        .on_linespace = callbacks.onLineSpace,
        .on_exit = callbacks.onExit,
        .on_default_colors_set = callbacks.onDefaultColorsSet,
        .on_set_title = callbacks.onSetTitle,
        .on_restart = callbacks.onRestart,
        .on_connect = callbacks.onConnect,
        .on_external_window = external_windows.onExternalWindow,
        .on_external_window_close = external_windows.onExternalWindowClose,
        .on_cursor_grid_changed = external_windows.onCursorGridChanged,
        .on_cmdline_show = callbacks.onCmdlineShow,
        .on_cmdline_hide = callbacks.onCmdlineHide,
        .on_popupmenu_show = callbacks.onPopupmenuShow,
        .on_popupmenu_hide = callbacks.onPopupmenuHide,
        .on_msg_show = messages.onMsgShow,
        .on_msg_clear = messages.onMsgClear,
        .on_msg_showmode = messages.onMsgShowmode,
        .on_msg_showcmd = messages.onMsgShowcmd,
        .on_msg_ruler = messages.onMsgRuler,
        .on_msg_history_show = messages.onMsgHistoryShow,
        .on_tabline_update = tabline_mod.onTablineUpdate,
        .on_tabline_hide = tabline_mod.onTablineHide,
        .on_agent_status = tabline_mod.onAgentStatus,
        .on_clipboard_get = callbacks.onClipboardGet,
        .on_clipboard_set = callbacks.onClipboardSet,
        .on_ssh_auth_prompt = callbacks.onSSHAuthPrompt,
        .on_ime_off = callbacks.onIMEOff,
        .on_quit_requested = callbacks.onQuitRequested,
        .on_rasterize_glyph = callbacks.onRasterizeGlyph,
        .on_atlas_upload = callbacks.onAtlasUpload,
        .on_atlas_create = callbacks.onAtlasCreate,
        .on_win_move = external_windows.onWinMove,
        .on_win_exchange = external_windows.onWinExchange,
        .on_win_rotate = external_windows.onWinRotate,
        .on_win_resize_equal = external_windows.onWinResizeEqual,
        .on_win_move_cursor = external_windows.onWinMoveCursor,
        .on_shape_text_run = callbacks.onShapeTextRun,
        .on_rasterize_glyph_by_id = callbacks.onRasterizeGlyphById,
        .on_get_ascii_table = callbacks.onGetAsciiTable,
        .on_flush_begin = callbacks.onFlushBegin,
        .on_flush_end = callbacks.onFlushEnd,
        .on_main_grid_size = callbacks.onMainGridSize,
        .on_main_row_scroll = callbacks.onMainRowScroll,
        .on_grid_row_scroll = callbacks.onGridRowScroll,
        .on_grid_scroll = callbacks.onGridScroll,
    };
}

// =========================================================================
// Helper: D3D11 device creation on a separate thread
// =========================================================================
fn d3dInitThreadFn(app: *App) void {
    const result = d3d11.Renderer.createDeviceOnly() catch return;
    if (app.d3d_init_cancelled.load(.acquire)) {
        _ = result.ctx.lpVtbl.*.Release.?(result.ctx);
        _ = result.device.lpVtbl.*.Release.?(result.device);
        return;
    }
    app.d3d_device = result.device;
    app.d3d_ctx = result.ctx;
    if (applog.isEnabled()) applog.appLog("[win] d3d_init_thread: device ready\n", .{});
}

// =========================================================================
// Helper: build native-mode nvim command string
// =========================================================================
fn buildNativeNvimCmd(app: *App, buf: []u8) []const u8 {
    const effective_nvim = app.cli_nvim_path orelse app.config.neovim.path;
    if (app.nvim_extra_args.items.len == 0) return effective_nvim;
    var w = std.Io.Writer.fixed(buf);
    const writer = &w;
    const needs_quote = std.mem.indexOfScalar(u8, effective_nvim, ' ') != null;
    if (needs_quote) writer.writeByte('\'') catch {};
    writer.writeAll(effective_nvim) catch {};
    if (needs_quote) writer.writeByte('\'') catch {};
    for (app.nvim_extra_args.items) |arg| {
        writer.writeByte(' ') catch {};
        if (std.mem.indexOfScalar(u8, arg, ' ') != null) {
            writer.writeByte('"') catch {};
            writer.writeAll(arg) catch {};
            writer.writeByte('"') catch {};
        } else {
            writer.writeAll(arg) catch {};
        }
    }
    return buf[0..w.end];
}

// =========================================================================
// doEarlyCoreInit: called from WM_CREATE for native mode only
// Creates core, loads config, inits DWrite metrics, spawns nvim, and
// kicks off D3D11 device creation on a separate thread.
// =========================================================================
fn doEarlyCoreInit(hwnd: c.HWND, app: *App) !void {
    const log_enabled = applog.isEnabled();
    var t1: c.LARGE_INTEGER = undefined;
    var t2: c.LARGE_INTEGER = undefined;

    // 1. Create core with callbacks
    var cb = makeCoreCbs();
    if (log_enabled) _ = c.QueryPerformanceCounter(&t1);
    app.corep = core.zonvie_core_create(&cb, @sizeOf(core.Callbacks), app);
    if (log_enabled) {
        _ = c.QueryPerformanceCounter(&t2);
        const ms = @divTrunc((t2.QuadPart - t1.QuadPart) * 1000, app_mod.g_startup_freq.QuadPart);
        applog.appLog("[win] doEarlyCoreInit: core_create {d}ms\n", .{ms});
    }

    // 2. Load config into core
    if (config_mod.getConfigFilePath(app.alloc)) |config_path| {
        defer app.alloc.free(config_path);
        const config_path_z = app.alloc.dupeZ(u8, config_path) catch null;
        if (config_path_z) |cpath| {
            defer app.alloc.free(cpath);
            _ = core.zonvie_core_load_config(app.corep, cpath.ptr);
        }
    } else |_| {}

    // 3. Set log/ext flags
    setLogEnabledViaCore(app, app.config.log.enabled);
    if (app.ext_cmdline_enabled) core.zonvie_core_set_ext_cmdline(app.corep, 1);
    if (app.config.popup.external) core.zonvie_core_set_ext_popupmenu(app.corep, 1);
    if (app.ext_messages_enabled) core.zonvie_core_set_ext_messages(app.corep, 1);
    if (app.ext_tabline_enabled) core.zonvie_core_set_ext_tabline(app.corep, 1);
    if (app.ext_windows_enabled) core.zonvie_core_set_ext_windows(app.corep, 1);
    core.zonvie_core_set_background_opacity(app.corep, app.config.window.opacity);
    core.zonvie_core_set_blur_enabled(app.corep, if (app.config.window.blur) 1 else 0);
    core.zonvie_core_set_glyph_cache_size(
        app.corep,
        app.config.performance.glyph_cache_ascii_size,
        app.config.performance.glyph_cache_non_ascii_size,
    );
    core.zonvie_core_set_atlas_size(app.corep, app.config.performance.atlas_size);

    // 4. DWrite metrics init (font metrics calculation) -> store in early_atlas.
    // Pass the raw config family string; initMetrics walks the
    // guifont-style candidate list and picks the first loadable font.
    const initial_pt: f32 = if (app.config.font.size > 0.0) app.config.font.size else 14.0;

    if (log_enabled) _ = c.QueryPerformanceCounter(&t1);
    var atlas_val = try dwrite_d2d.Renderer.initMetrics(
        app.alloc,
        hwnd,
        app.config.font.family,
        initial_pt,
        app.config.font.size_explicit,
    );
    if (log_enabled) {
        _ = c.QueryPerformanceCounter(&t2);
        const ms = @divTrunc((t2.QuadPart - t1.QuadPart) * 1000, app_mod.g_startup_freq.QuadPart);
        applog.appLog("[win] doEarlyCoreInit: initMetrics {d}ms\n", .{ms});
    }

    app.mu.lockUncancelable(core.clock.io());
    app.dpi_scale = @as(f32, @floatFromInt(atlas_val.dpi)) / 96.0;
    app.mu.unlock(core.clock.io());
    app.cell_w_px = atlas_val.cellW();
    app.cell_h_px = atlas_val.cellH();
    app.early_atlas = atlas_val;

    // 5. Compute rows/cols from actual cell metrics
    updateRowsColsFromClientForce(hwnd, app);

    // 6. Start session: connect mode if --connect-nvim/--remote-ui was set,
    //    otherwise spawn nvim (native mode). Capture the int return: a
    //    negative value means the core thread was NOT started (-1 invalid
    //    handle, -2 thread spawn failed, -3 invalid/unsupported listen
    //    address). on_exit will not fire in that case, so we must abort
    //    startup ourselves instead of leaving a zombie window with no
    //    backing nvim.
    const start_rc: i32 = if (app.connect_addr) |addr| blk: {
        if (log_enabled) applog.appLog("[win] doEarlyCoreInit: connect mode addr={s} rows={d} cols={d}\n", .{ addr, app.surface.rows, app.surface.cols });
        break :blk core.zonvie_core_start_connect(app.corep, addr.ptr, addr.len, app.surface.rows, app.surface.cols);
    } else blk: {
        var nvim_cmd_buf: [1024]u8 = undefined;
        const nvim_cmd_slice = buildNativeNvimCmd(app, &nvim_cmd_buf);
        const nvim_path_z = app.alloc.dupeZ(u8, nvim_cmd_slice) catch null;
        defer if (nvim_path_z) |p| app.alloc.free(p);
        const nvim_path_ptr: ?[*:0]const u8 = if (nvim_path_z) |p| p.ptr else null;

        if (log_enabled) applog.appLog("[win] doEarlyCoreInit: spawning nvim rows={d} cols={d}\n", .{ app.surface.rows, app.surface.cols });
        break :blk core.zonvie_core_start(app.corep, nvim_path_ptr, app.surface.rows, app.surface.cols);
    };

    if (start_rc != 0) {
        if (log_enabled) applog.appLog("[win] doEarlyCoreInit: core start failed rc={d}; aborting startup\n", .{start_rc});
        // Mark the session as already exited so the WM_CLOSE handler
        // takes the fast path (no quit dialog, no waiting on the core).
        app.neovim_exited.store(true, .release);
        // Set the global exit code so wWinMain returns 1 to the shell
        // (mirrors macOS Darwin.exit(1)). main.zig pulls this value
        // out of g_exit_code after the message loop exits — the
        // wParam passed to PostQuitMessage is intentionally ignored.
        app_mod.g_exit_code.store(1, .seq_cst);
        _ = c.PostMessageW(hwnd, c.WM_CLOSE, 0, 0);
        return;
    }
    app.nvim_spawned = true;
    app.early_core_init_done = true;

    // 7. D3D11 device init on separate thread
    app.d3d_init_cancelled.store(false, .release);
    app.d3d_init_thread = std.Thread.spawn(.{}, d3dInitThreadFn, .{app}) catch null;

    // 8. Tabline titlebar mode: trigger SWP_FRAMECHANGED immediately
    if (app.ext_tabline_enabled and app.tabline_style == .titlebar) {
        _ = c.SetWindowPos(hwnd, null, 0, 0, 0, 0, c.SWP_FRAMECHANGED | c.SWP_NOMOVE | c.SWP_NOSIZE);
        if (log_enabled) applog.appLog("[win] WM_CREATE: SWP_FRAMECHANGED applied (overlaps nvim spawn ~50ms)\n", .{});
    }

    if (log_enabled) applog.appLog("[win] WM_CREATE: early core init done, nvim spawn started rows={d} cols={d}\n", .{ app.surface.rows, app.surface.cols });
}

pub export fn WndProc(
    hwnd: c.HWND,
    msg: c.UINT,
    wParam: c.WPARAM,
    lParam: c.LPARAM,
) callconv(.winapi) c.LRESULT {
    switch (msg) {
        c.WM_NCCREATE => {
            if (applog.isEnabled()) applog.appLog("WM_NCCREATE hwnd={*} wParam={d} lParam=0x{x}", .{ hwnd, wParam, @as(usize, @bitCast(lParam)) });

            const cs: *c.CREATESTRUCTW = @ptrFromInt(@as(usize, @bitCast(lParam)));
            if (applog.isEnabled()) applog.appLog("  CREATESTRUCTW ptr={*} lpCreateParams={*}", .{ cs, cs.lpCreateParams });

            const lp = cs.lpCreateParams orelse {
                if (applog.isEnabled()) applog.appLog("  lpCreateParams is null -> fail", .{});
                return 0;
            };
            if (applog.isEnabled()) applog.appLog("  lpCreateParams={*}", .{lp});

            const app: *App = @ptrCast(@alignCast(lp));
            if (applog.isEnabled()) applog.appLog("  app ptr={*} align={d}", .{ app, @alignOf(App) });

            app.owned_by_hwnd = true;
            setApp(hwnd, app);
            if (applog.isEnabled()) applog.appLog("  GWLP_USERDATA set", .{});
            return 1;
        },

        // DWM custom titlebar: extend client area into titlebar
        c.WM_NCCALCSIZE => {
            if (getApp(hwnd)) |app| {
                if (app.ext_tabline_enabled and app.tabline_style == .titlebar and wParam != 0) {
                    // When wParam is TRUE, return 0 to use entire window as client area.
                    // This removes the standard titlebar/frame.
                    if (c.IsZoomed(hwnd) != 0) {
                        // When maximized, Windows extends the window beyond the visible
                        // screen by the frame thickness (invisible resize borders).
                        // Inset the proposed rect to match the actual visible area.
                        const params: *c.NCCALCSIZE_PARAMS = @ptrFromInt(@as(usize, @bitCast(lParam)));
                        const frame_x = c.GetSystemMetrics(c.SM_CXFRAME) + c.GetSystemMetrics(c.SM_CXPADDEDBORDER);
                        const frame_y = c.GetSystemMetrics(c.SM_CYFRAME) + c.GetSystemMetrics(c.SM_CXPADDEDBORDER);
                        params.rgrc[0].left += frame_x;
                        params.rgrc[0].top += frame_y;
                        params.rgrc[0].right -= frame_x;
                        params.rgrc[0].bottom -= frame_y;
                        if (applog.isEnabled()) applog.appLog("[win] WM_NCCALCSIZE: maximized, inset by frame=({d},{d})\n", .{ frame_x, frame_y });
                    } else {
                        if (applog.isEnabled()) applog.appLog("[win] WM_NCCALCSIZE: extending client area into titlebar\n", .{});
                    }
                    return 0;
                }
            }
            return c.DefWindowProcW(hwnd, msg, wParam, lParam);
        },

        // DWM custom titlebar: hit testing for resize borders and caption dragging
        c.WM_NCHITTEST => {
            if (getApp(hwnd)) |app| {
                if (app.ext_tabline_enabled and app.tabline_style == .titlebar) {
                    // Get cursor position in screen coordinates
                    const x = @as(i16, @truncate(lParam & 0xFFFF));
                    const y = @as(i16, @truncate((lParam >> 16) & 0xFFFF));

                    // Get window rect in screen coordinates
                    var window_rect: c.RECT = undefined;
                    _ = c.GetWindowRect(hwnd, &window_rect);

                    // Frame/border sizes for resize detection
                    const frame_x = c.GetSystemMetrics(c.SM_CXFRAME) + c.GetSystemMetrics(c.SM_CXPADDEDBORDER);
                    const frame_y = c.GetSystemMetrics(c.SM_CYFRAME) + c.GetSystemMetrics(c.SM_CXPADDEDBORDER);

                    // Check if cursor is in the scrollbar area (right edge, below tabbar).
                    // If so, don't treat it as a resize border - let it be handled as HTCLIENT.
                    // But keep rightmost 2 pixels for resize detection.
                    // Only check scrollbar area if scrollbar is enabled.
                    const tabbar_height_i16: i16 = @intCast(app.scalePx(TablineState.TAB_BAR_HEIGHT));
                    const resize_edge_width: i32 = 2; // Keep this many pixels at right edge for resize
                    const in_scrollbar_area = if (app.config.scrollbar.enabled) blk: {
                        const scrollbar_area_left = window_rect.right - @as(i32, @intFromFloat(app_mod.scrollbarReservedWidth(app.dpi_scale)));
                        const scrollbar_area_right = window_rect.right - resize_edge_width; // Leave edge for resize
                        const scrollbar_area_top = window_rect.top + tabbar_height_i16 + @as(i32, @intFromFloat(app_mod.scrollbarMargin(app.dpi_scale)));
                        const scrollbar_area_bottom = window_rect.bottom - @as(i32, @intFromFloat(app_mod.scrollbarMargin(app.dpi_scale))) - resize_edge_width;
                        break :blk x >= scrollbar_area_left and x < scrollbar_area_right and
                            y >= scrollbar_area_top and y <= scrollbar_area_bottom;
                    } else false;

                    // Check resize borders first
                    const on_left = x < window_rect.left + frame_x;
                    // Exclude scrollbar area from right-edge resize detection
                    const on_right = x >= window_rect.right - frame_x and !in_scrollbar_area;
                    const on_top = y < window_rect.top + frame_y;
                    const on_bottom = y >= window_rect.bottom - frame_y and !in_scrollbar_area;

                    if (on_top) {
                        if (on_left) return c.HTTOPLEFT;
                        if (on_right) return c.HTTOPRIGHT;
                        return c.HTTOP;
                    }
                    if (on_bottom) {
                        if (on_left) return c.HTBOTTOMLEFT;
                        if (on_right) return c.HTBOTTOMRIGHT;
                        return c.HTBOTTOM;
                    }
                    if (on_left) return c.HTLEFT;
                    if (on_right) return c.HTRIGHT;

                    // Check if in tabbar area (custom caption)
                    const tabbar_height = app.scalePx(TablineState.TAB_BAR_HEIGHT);
                    if (y < window_rect.top + tabbar_height) {
                        // In tabbar area - check if clicking on interactive elements or empty space
                        const client_x = x - window_rect.left;
                        const client_width = window_rect.right - window_rect.left;

                        // Check window control buttons (min/max/close) on the right
                        const btn_start_x = client_width - app.scalePx(TablineState.WINDOW_BTNS_TOTAL);
                        if (client_x >= btn_start_x) {
                            // On window buttons - return HTCLIENT so our click handler works
                            return c.HTCLIENT;
                        }

                        // Check if clicking on a tab or + button
                        app.mu.lockUncancelable(core.clock.io());
                        const tab_count = app.tabline_state.tab_count;
                        app.mu.unlock(core.clock.io());

                        if (tab_count > 0) {
                            // Calculate tab positions using same logic as drawTablineContent
                            const available_width = client_width - app.scalePx(TablineState.WINDOW_CONTROLS_WIDTH) - app.scalePx(40) - app.scalePx(TablineState.WINDOW_BTNS_TOTAL);
                            const ideal_width = @divTrunc(available_width, @as(i32, @intCast(tab_count)));
                            const tab_width = @min(app.scalePx(TablineState.TAB_MAX_WIDTH), @max(app.scalePx(TablineState.TAB_MIN_WIDTH), ideal_width));

                            var tab_x: i32 = app.scalePx(TablineState.WINDOW_CONTROLS_WIDTH);
                            for (0..tab_count) |_| {
                                if (client_x >= tab_x and client_x < tab_x + tab_width) {
                                    // On a tab - return HTCLIENT so clicks go to the app
                                    return c.HTCLIENT;
                                }
                                tab_x += tab_width + 1;
                            }

                            // Check + button area
                            const plus_x = tab_x + app.scalePx(8);
                            if (client_x >= plus_x and client_x < plus_x + app.scalePx(24)) {
                                return c.HTCLIENT;
                            }
                        }

                        // Empty area in tabbar - allow dragging
                        return c.HTCAPTION;
                    }

                    // Below tabbar - normal client area
                    return c.HTCLIENT;
                }
            }
            return c.DefWindowProcW(hwnd, msg, wParam, lParam);
        },

        // Custom-titlebar mode: right-click on the empty caption area (the
        // tabbar space not occupied by tabs/buttons, which WM_NCHITTEST maps
        // to HTCAPTION) pops the window's system menu — including the
        // "About zonvie" item appended in WM_CREATE. Without this, the custom
        // titlebar has no standard frame for the OS to attach that menu to.
        c.WM_NCRBUTTONUP => {
            if (getApp(hwnd)) |app| {
                if (app.ext_tabline_enabled and app.tabline_style == .titlebar and wParam == c.HTCAPTION) {
                    if (c.GetSystemMenu(hwnd, 0)) |sysmenu| {
                        // lParam holds screen coordinates for non-client clicks.
                        const sx = @as(i16, @truncate(lParam & 0xFFFF));
                        const sy = @as(i16, @truncate((lParam >> 16) & 0xFFFF));
                        const cmd = c.TrackPopupMenu(
                            sysmenu,
                            c.TPM_RETURNCMD | c.TPM_RIGHTBUTTON,
                            @as(c_int, sx),
                            @as(c_int, sy),
                            0,
                            hwnd,
                            null,
                        );
                        if (cmd != 0) {
                            // Route through WM_SYSCOMMAND so both IDM_ABOUT and
                            // the standard verbs (Move/Size/Close/...) are handled.
                            _ = c.PostMessageW(hwnd, c.WM_SYSCOMMAND, @as(c.WPARAM, @intCast(cmd)), 0);
                        }
                    }
                    return 0;
                }
            }
            return c.DefWindowProcW(hwnd, msg, wParam, lParam);
        },

        c.WM_SYSCOMMAND => {
            // The OS reserves the low 4 bits of the command id, so mask them.
            if ((wParam & 0xFFF0) == IDM_ABOUT) {
                const ver = std.mem.span(app_mod.zonvie_version());
                var buf: [256]u8 = undefined;
                const text = std.fmt.bufPrint(&buf, "zonvie\n\nVersion {s}", .{ver}) catch "zonvie";
                // 257 elements: convert into the first 256 so wlen <= 256,
                // leaving wbuf[wlen] in range for the NUL terminator even when
                // a long tag fills `text` to its full 256 bytes.
                var wbuf: [257]u16 = undefined;
                const wlen = std.unicode.utf8ToUtf16Le(wbuf[0 .. wbuf.len - 1], text) catch 0;
                wbuf[wlen] = 0;
                _ = c.MessageBoxW(hwnd, &wbuf, about_title_w, c.MB_OK | c.MB_ICONINFORMATION);
                return 0;
            }
            return c.DefWindowProcW(hwnd, msg, wParam, lParam);
        },

        c.WM_CREATE => {
            // Debug builds no longer force logging on by default.
            // Use --log <path> or [log] config to enable.

            if (applog.isEnabled()) applog.appLog("WM_CREATE: begin (deferred init)", .{});
            if (getApp(hwnd)) |app| {
                app.hwnd = hwnd;
                app.ui_thread_id = c.GetCurrentThreadId();

                // Set DPI scale early so that any scalePx() calls before
                // WM_APP_DEFERRED_INIT (e.g. WM_NCHITTEST, initial layout)
                // use the correct value.
                const initial_dpi = GetDpiForWindow(hwnd);
                if (initial_dpi > 0) {
                    app.mu.lockUncancelable(core.clock.io());
                    app.dpi_scale = @as(f32, @floatFromInt(initial_dpi)) / 96.0;
                    app.mu.unlock(core.clock.io());
                    if (applog.isEnabled()) applog.appLog("[win] WM_CREATE: initial dpi={d} scale={d:.2}\n", .{ initial_dpi, app.dpi_scale });
                }

                // Accept file drops via drag & drop. The OLE target is what
                // makes the drag cursor reflect what the drop will do; it
                // turns the legacy path off when it succeeds and leaves it on
                // when it does not, so drops keep working either way.
                c.DragAcceptFiles(hwnd, 1);
                _ = c.OleInitialize(null);
                app.main_drop_target = drop_target.register(app, hwnd, false);

                // Add "About zonvie" to the window's system menu (title-bar
                // right-click / Alt+Space). Handled in WM_SYSCOMMAND below.
                if (c.GetSystemMenu(hwnd, 0)) |sysmenu| {
                    _ = c.AppendMenuW(sysmenu, c.MF_SEPARATOR, 0, null);
                    _ = c.AppendMenuW(sysmenu, c.MF_STRING, IDM_ABOUT, about_title_w);
                }

                // Apply the OS app-theme preference to the DWM titlebar so the
                // very first frame matches the user's light/dark choice.
                // Re-applied on WM_SETTINGCHANGE / ImmersiveColorSet and
                // WM_APP_THEME_REREAD (RegNotifyChangeKeyValue worker).
                applyOsTitlebarTheme(hwnd);
                // Start the registry-watcher worker so light/dark toggles
                // taken while Zonvie is running are picked up live.
                startThemeWatcher(hwnd);

                if (app.connect_dialog) {
                    // `--connect-dialog`: the connection mode is unknown until the
                    // user chooses it, so defer everything. Show the dialog once
                    // the window exists (WM_APP_SHOW_CONNECT_DIALOG); its Connect
                    // handler populates ssh_*/devcontainer_*/ext_* and posts
                    // WM_APP_DEFERRED_INIT, which then takes the full-init path.
                    _ = c.PostMessageW(hwnd, WM_APP_SHOW_CONNECT_DIALOG, 0, 0);
                    if (applog.isEnabled()) applog.appLog("WM_CREATE: end (--connect-dialog: deferring start until dialog resolves)", .{});
                } else {
                    // Native mode: perform early core init (before deferred init)
                    // WSL/SSH/devcontainer modes use the traditional WM_APP_DEFERRED_INIT path
                    const is_remote = app.wsl_mode or app.ssh_mode or app.devcontainer_mode;
                    if (!is_remote) {
                        doEarlyCoreInit(hwnd, app) catch |e| {
                            if (applog.isEnabled()) applog.appLog("[win] WM_CREATE: doEarlyCoreInit failed: {any}\n", .{e});
                        };
                    }

                    // Post deferred init message - renderer initialization happens after window is shown
                    _ = c.PostMessageW(hwnd, WM_APP_DEFERRED_INIT, 0, 0);

                    if (applog.isEnabled()) applog.appLog("WM_CREATE: end (posted deferred init)", .{});
                }
            }
            return 0;
        },
        c.WM_PAINT => {
            const log_enabled = applog.isEnabled();
            if (log_enabled) applog.appLog("WM_PAINT tid={d}", .{c.GetCurrentThreadId()});

            if (getApp(hwnd)) |app| {
                app.main_paint_retry_deadline_ms = 0;
                app.paint_retry.paintStarted();
                // Reentrant relative to either: another WM_PAINT already
                // rendering on this thread (g.lockContext() below is a
                // non-recursive std.Io.Mutex), or the TIMER_CUSTOM_SHADER_ANIM
                // handler's presentShaderAnimationFrame() mid-Present on the
                // same D3D immediate context — either one's DXGI Present()
                // can pump the Win32 message queue and deliver this WM_PAINT
                // reentrantly on the same thread.
                if (app.wm_paint_in_progress or app.in_present_shader_animation_frame or app.glow_prepare_in_progress or app.device_lost_recovering or app.main_resize_in_progress or app.main_dpi_change_in_progress) {
                    // Still consume BeginPaint/EndPaint so Windows stops
                    // re-issuing WM_PAINT, but skip rendering entirely and
                    // ask for a follow-up paint once the outer call finishes
                    // instead of self-deadlocking / corrupting immediate
                    // context state. device_lost_recovering: device/D2D/
                    // swapchain creation in WM_APP_DEVICE_LOST_RECOVER can
                    // pump messages and reenter WM_PAINT on this same UI
                    // thread while that handler still holds app.mu.
                    var ps_reentrant: c.PAINTSTRUCT = undefined;
                    _ = c.BeginPaint(hwnd, &ps_reentrant);
                    _ = c.EndPaint(hwnd, &ps_reentrant);
                    app.wm_paint_reinvalidate_all = true;
                    return 0;
                }
                // Also completes closes whose PostMessageW failed because the
                // UI queue was full. Successful posts are harmlessly
                // idempotent if this paint reaches the pending state first.
                external_windows.closePendingExternalWindowsOnUIThread(app);
                app.wm_paint_in_progress = true;
                defer {
                    app.wm_paint_in_progress = false;
                    _ = app.finishActiveOperation();
                }

                var ps: c.PAINTSTRUCT = undefined;
                _ = c.BeginPaint(hwnd, &ps);
                defer _ = c.EndPaint(hwnd, &ps);

                // While minimized, GetClientRect returns the iconic size
                // (e.g. 160x28); letting drawEx → resize run would shrink
                // swapchain/back_tex to that size and discard their contents,
                // so the next restore would Present an empty surface as a
                // gray rectangle. BeginPaint/EndPaint above still consumes
                // the paint region so Windows stops re-issuing WM_PAINT.
                if (c.IsIconic(hwnd) != 0) {
                    return 0;
                }

                // Log first paint with content timing (startup performance)
                if (!app.first_paint_logged and app.renderer != null) {
                    if (log_enabled) {
                        var first_paint_t: c.LARGE_INTEGER = undefined;
                        _ = c.QueryPerformanceCounter(&first_paint_t);
                        const first_paint_ms = @divTrunc((first_paint_t.QuadPart - app_mod.g_startup_t0.QuadPart) * 1000, app_mod.g_startup_freq.QuadPart);
                        applog.appLog("[TIMING] First WM_PAINT (renderer ready): {d}ms from main()\n", .{first_paint_ms});
                    }
                    app.first_paint_logged = true;
                }

                // Renderer not yet initialized (deferred init pending). Fill
                // the paint rect with the colorscheme bg if Neovim has
                // already pushed default_colors_set; otherwise fall back to
                // black to match the legacy behavior. Without the bg path,
                // the early frames of startup show a black flash even when
                // the colorscheme is light.
                if (app.renderer == null) {
                    const hdc = ps.hdc;
                    app.mu.lockUncancelable(core.clock.io());
                    const bg_rgb = app.colorscheme_bg;
                    app.mu.unlock(core.clock.io());
                    if (bg_rgb != 0xFFFFFFFF) {
                        // Win32 COLORREF is 0x00BBGGRR — swap from our 0x00RRGGBB.
                        const r: u32 = (bg_rgb >> 16) & 0xFF;
                        const g: u32 = (bg_rgb >> 8) & 0xFF;
                        const b: u32 = bg_rgb & 0xFF;
                        const colorref: c.COLORREF = @intCast((b << 16) | (g << 8) | r);
                        if (log_enabled) applog.appLog("[win] WM_PAINT: renderer not ready, filling bg=0x{x:0>6}", .{bg_rgb});
                        const brush = c.CreateSolidBrush(colorref);
                        if (brush != null) {
                            _ = c.FillRect(hdc, &ps.rcPaint, brush);
                            _ = c.DeleteObject(@ptrCast(brush));
                        } else {
                            const black_brush: c.HBRUSH = @ptrCast(@alignCast(c.GetStockObject(c.BLACK_BRUSH)));
                            _ = c.FillRect(hdc, &ps.rcPaint, black_brush);
                        }
                    } else {
                        if (log_enabled) applog.appLog("[win] WM_PAINT: renderer not ready, filling black (bg unset)", .{});
                        const black_brush: c.HBRUSH = @ptrCast(@alignCast(c.GetStockObject(c.BLACK_BRUSH)));
                        _ = c.FillRect(hdc, &ps.rcPaint, black_brush);
                    }
                    return 0;
                }

                var dirty: ?c.RECT =
                    if (ps.rcPaint.right > ps.rcPaint.left and ps.rcPaint.bottom > ps.rcPaint.top)
                        ps.rcPaint
                    else
                        null;

                // Consume need_full_seed ONCE here.
                const did_need_seed = app.need_full_seed.swap(false, .seq_cst);
                if (did_need_seed) {
                    // Keep rows/cols synced to client size before we snapshot row-mode state.
                    app.mu.lockUncancelable(core.clock.io());
                    updateRowsColsFromClientForce(hwnd, app);
                    app.mu.unlock(core.clock.io());

                    // IMPORTANT: do not hold app.mu while calling into core.
                    updateLayoutToCore(hwnd, app);

                    // Force full redraw request on this paint.
                    dirty = null;

                    // Ensure we get a paint covering the whole surface.
                    _ = c.InvalidateRect(hwnd, null, c.FALSE);
                    {
                        app.mu.lockUncancelable(core.clock.io());
                        app.surface.paint_full = true;
                        app.paint_rects.clearRetainingCapacity();
                        app.mu.unlock(core.clock.io());
                    }
                }

                // Note: row_mode/rows/main_verts length are logged after snapshotting under lock.
                // if (dirty) |r| {
                //     applog.appLog("[win]   dirty_rect=({d},{d})-({d},{d})\n", .{ r.left, r.top, r.right, r.bottom });
                // }

                // Phase timing for WM_PAINT
                var t_snapshot_start_ns: i128 = 0;
                var t_snapshot_end_ns: i128 = 0;
                var t_atlas_end_ns: i128 = 0;
                if (log_enabled) {
                    t_snapshot_start_ns = core.clock.nowNs();
                }

                // Read core-owned render settings before entering the atlas
                // reader transaction. Keep the transaction free of core
                // callbacks so atlas reset admission remains one-way and does
                // not acquire grid_mu from the UI paint path.
                const glow_enabled = if (app.corep) |cp| core.zonvie_core_get_glow_enabled(cp) else false;
                const glow_intensity = if (app.corep) |cp| core.zonvie_core_get_glow_intensity(cp) else @as(f32, 0.8);

                // The atlas transaction must cover the TBS and atlas snapshots,
                // not only the eventual draw. Otherwise a reset can commit
                // between acquireForPaint() and a later admission check, leaving
                // this paint with old UVs and the newly uploaded atlas.
                if (!app.beginAtlasPaint()) {
                    app.tbs.rotation_mu.lockUncancelable(core.clock.io());
                    app.tbs.pending_paint_full = true;
                    app.tbs.rotation_mu.unlock(core.clock.io());
                    return 0;
                }
                defer app.endAtlasPaint();

                // Step 1: TBS acquire (rotation_mu short lock).
                // Captures committed_index, paint_full, and copies pending_dirty → paint_dirty_snapshot.
                const tbs_snapshot = app.tbs.acquireForPaint(app.alloc);
                defer {
                    const needs_reinvalidate = app.tbs.releaseFromPaint(tbs_snapshot.committed_index, tbs_snapshot.cursor_index);
                    if (app.paint_retry.shouldInvalidateAfterRelease(needs_reinvalidate)) {
                        // A successful atlas-reset transaction repaints every
                        // surface. Avoid a WM_PAINT loop while a failed reset
                        // intentionally keeps the previous frame frozen.
                        if (!app.atlas_reset_active.load(.seq_cst)) {
                            _ = c.InvalidateRect(hwnd, null, c.FALSE);
                        }
                    }
                }
                // Main ease records are drained at the paint barrier:
                //   1. acquireForPaint captures the commit revision under
                //      rotation_mu.
                //   2. covered main records are drained before pending scroll
                //      and vertex consumption.
                // Reentrant paints never consume pending scroll (their snapshot
                // carries none), so the drain is gated on the outermost paint,
                // matching the external FIFO consumption rule.
                // Convert drained records at this barrier before any pending
                // scroll or vertex consumption.
                // Freeze shader_recompose_frame once at the barrier; false for
                // reentrant paints, whose snapshots
                // carry no pending scroll and which must not tick the ledger.
                var b_recompose_frame = false;
                var b_schedule_next_frame = false;
                // First ordinary paint after a recompose run.
                var b_leaving_recompose = false;
                if (tbs_snapshot.outermost_paint) {
                    // Core-thread invalidation requests are consumed here, on
                    // the UI thread that owns the offset ledger. A consumed
                    // drop also discards THIS paint's drained records: the
                    // core-side clearBEaseCommits races the drain below under
                    // rotation_mu, and pre-change records that win the race
                    // must not re-seed onto the freshly dropped ledger with
                    // stale geometry.
                    var b_discard_seeds_this_paint = false;
                    if (app.b_drop_all_request.swap(false, .seq_cst)) {
                        if (app.b_offset_ledger.dropAll()) app.b_forced_zero_pending = true;
                        b_discard_seeds_this_paint = true;
                    }
                    var dropped_ledger_grids: [app_mod.RetentionStorage.MAX_GRIDS]i64 = undefined;
                    const dropped_ledger_count = app.tbs.drainDroppedGrids(&dropped_ledger_grids);
                    var dropped_active_grid = false;
                    for (dropped_ledger_grids[0..dropped_ledger_count]) |dropped_grid_id| {
                        if (app.b_offset_ledger.dropGrid(dropped_grid_id)) dropped_active_grid = true;
                    }
                    if (dropped_active_grid and app.b_offset_ledger.count() == 0) {
                        app.b_forced_zero_pending = true;
                    }
                    // Rate-independent spring tick before drain/seed. Integrating a
                    // just-arrived seed over the idle gap that preceded it
                    // would settle it instantly, reintroducing pause-dependent
                    // snap-vs-glide nondeterminism. Existing entries correctly
                    // integrate wall-clock time. QPC-backed monotonic time
                    // keeps the spring rate-independent; wall-clock
                    // adjustments cannot stretch or reverse dt.
                    const b_now_ns = core.clock.monotonicNs();
                    const b_dt_sec: f64 = if (app.b_last_ease_tick_ns == 0)
                        0.0
                    else
                        @as(f64, @floatFromInt(@max(0, b_now_ns - app.b_last_ease_tick_ns))) / 1_000_000_000.0;
                    app.b_last_ease_tick_ns = b_now_ns;
                    const b_reached_zero = app.b_offset_ledger.tick(b_dt_sec);

                    var drained_grid_ids: [scroll_types.MaxSemanticCommits]i64 = undefined;
                    var drained_rows: [scroll_types.MaxSemanticCommits]i32 = undefined;
                    const b_ease_drained = app.tbs.drainBEaseRecordsUpTo(
                        tbs_snapshot.commit_rev,
                        &drained_grid_ids,
                        &drained_rows,
                    );
                    if (b_ease_drained != 0 and log_enabled) {
                        applog.appLog(
                            "[smooth] b_ease drain records={d} commit_rev={d}\n",
                            .{ b_ease_drained, tbs_snapshot.commit_rev },
                        );
                    }

                    app.mu.lockUncancelable(core.clock.io());
                    const row_height_px: f64 = @floatFromInt(app.cell_h_px + app.linespace_px);
                    app.mu.unlock(core.clock.io());
                    var b_real_seeded = false;
                    if (!app.b_in_size_move and !b_discard_seeds_this_paint) {
                        for (drained_grid_ids[0..b_ease_drained], drained_rows[0..b_ease_drained]) |grid_id, rows_delta| {
                            const live_ver: i32 = if (app.corep) |cp|
                                @intCast(@min(app_mod.zonvie_core_get_mousescroll_ver(cp), @as(u32, 32)))
                            else
                                0;
                            switch (app.b_offset_ledger.seedArrivalWithPolicy(grid_id, rows_delta, row_height_px, false, live_ver, app.large_jump_behavior)) {
                                .seeded => b_real_seeded = true,
                                .capacity_drop => applog.appLog(
                                    "[smooth] b_ease drop grid={d} rows={d} reason=offset-ledger-capacity\n",
                                    .{ grid_id, rows_delta },
                                ),
                                .skipped => {},
                            }
                        }
                    }

                    // Derive and freeze the recompose state; persist
                    // was_active_last_frame := active_now; consume the forced
                    // drop flag armed by resize or device loss.
                    // Capture a pending final-zero wake before this paint
                    // consumes it.  A natural spring settling crossing is rendered by
                    // this paint itself; it must not schedule one extra idle
                    // paint after the final-zero frame has run.
                    const b_final_zero_pending_before = app.b_forced_zero_pending;
                    const b_paint_tick = scroll_route.deriveRecomposeForPaint(.{
                        .offset_active = app.b_offset_ledger.hasActive(),
                        .seeded_this_frame = b_real_seeded,
                        .reached_zero_this_frame = b_reached_zero,
                        .forced_zero_pending = app.b_forced_zero_pending,
                        .was_active_last_frame = app.b_was_active_last_frame,
                    });
                    app.b_forced_zero_pending = false;
                    app.b_was_active_last_frame = b_paint_tick.was_active_next;
                    b_recompose_frame = b_paint_tick.shader_recompose_frame;
                    b_schedule_next_frame = scroll_route.shouldScheduleNextFrame(
                        b_paint_tick.recompose.offset_active,
                        b_final_zero_pending_before,
                        tbs_snapshot.outermost_paint,
                    );

                    // Underlay transition edge. If this paint fails
                    // before drawing, its recovery path requeues a full paint
                    // (paint_full), which re-primes the underlay anyway.
                    b_leaving_recompose = app.b_prev_paint_recompose and !b_recompose_frame;
                    app.b_prev_paint_recompose = b_recompose_frame;
                    if (log_enabled and (b_recompose_frame or b_leaving_recompose)) {
                        applog.appLog(
                            "[smooth] b_recompose frame={d} leaving={d} active={d} seeded={d} final_zero={d} ledger_grids={d}\n",
                            .{
                                @as(u32, @intFromBool(b_recompose_frame)),
                                @as(u32, @intFromBool(b_leaving_recompose)),
                                @as(u32, @intFromBool(b_paint_tick.recompose.offset_active)),
                                @as(u32, @intFromBool(b_paint_tick.recompose.seeded_this_frame)),
                                @as(u32, @intFromBool(b_paint_tick.recompose.final_zero_frame or b_paint_tick.recompose.final_zero_frame_pending)),
                                app.b_offset_ledger.count(),
                            },
                        );
                    }
                }

                const committed = &app.tbs.sets[tbs_snapshot.committed_index];
                const committed_cursor = &app.tbs.main_cursor_sets[tbs_snapshot.cursor_index];

                // Step 2: UI metadata snapshot (app.mu short lock).
                app.mu.lockUncancelable(core.clock.io());
                if (app.surface.rows == 0) {
                    updateRowsColsFromClient(hwnd, app);
                }

                // Read vertex-related state from TBS committed set (refcount-protected, lock-free).
                const row_mode = committed.row_mode;
                const rows_snapshot: u32 = committed.rows;
                const row_verts_len: u32 = @intCast(committed.row_map.items.len);
                const main_verts_len_snapshot: u32 = @intCast(committed.flat_verts.items.len);

                // Read UI metadata under app.mu.
                const seed_pending_snapshot = app.seed_pending;
                const seed_clear_pending_snapshot = app.seed_clear_pending;
                const back_tex_valid_snapshot = app.back_tex_valid;
                const row_valid_count_snapshot = app.row_valid_count;
                const row_layout_gen_snapshot: u64 = app.row_layout_gen;
                const row_mode_max_row_end_snapshot: u32 = app.row_mode_max_row_end;
                const row_h_px_snapshot: u32 = app.cell_h_px + app.linespace_px;
                const scrollbar_alpha_snapshot = app.scrollbar_alpha;

                // Retention is paint-side state: validate its cell metric only
                // after the spring tick/drain barrier and before any vertices
                // are consumed. Captures for settled grids have no useful
                // destination and are invalidated here, matching the macOS
                // retention prune.
                if (tbs_snapshot.outermost_paint) {
                    _ = app.tbs.drainRetentionForPaint(
                        tbs_snapshot.commit_rev,
                        @floatFromInt(row_h_px_snapshot),
                    );
                    app.tbs.pruneRetentionInactive(
                        tbs_snapshot.commit_rev,
                        app.b_offset_ledger.grid_ids[0..app.b_offset_ledger.len],
                    );
                }

                // IMPORTANT: do NOT copy renderer/atlas structs here.
                // Take pointers to the option payloads instead.
                var atlas_ptr: ?*dwrite_d2d.Renderer = null;
                var gpu_ptr: ?*d3d11.Renderer = null;
                if (app.atlas) |*a| atlas_ptr = a;
                if (app.renderer) |*g| gpu_ptr = g;
                var atlas_recreate_needed = false;
                var atlas_recreate_w: u32 = 0;
                var atlas_recreate_h: u32 = 0;

                // If the glyph atlas was reset, all cached row vertex UVs are stale.
                // Request a full re-seed so the core regenerates every row.
                // Guard with renderer mutex (resetAtlas sets the flag under a.mu).
                if (atlas_ptr) |a| {
                    var reset_pending = false;
                    var cur_atlas_w: u32 = 0;
                    var cur_atlas_h: u32 = 0;
                    {
                        a.mu.lockUncancelable(core.clock.io());
                        defer a.mu.unlock(core.clock.io());
                        reset_pending = a.atlas_reset_pending;
                        if (reset_pending) a.atlas_reset_pending = false;
                        cur_atlas_w = a.atlas_w;
                        cur_atlas_h = a.atlas_h;
                    }
                    if (reset_pending) {
                        // D3D creation/Release can pump messages. Capture the
                        // request here and perform it after releasing app.mu.
                        atlas_recreate_needed = true;
                        atlas_recreate_w = cur_atlas_w;
                        atlas_recreate_h = cur_atlas_h;
                        app.need_full_seed.store(true, .seq_cst);
                        app.surface.paint_full = true;
                        app.paint_rects.clearRetainingCapacity();
                        // Retained captures carry pre-reset atlas UVs; live rows
                        // re-seed but the retention ring would keep drawing the
                        // stale glyphs.
                        app.tbs.clearRetention();
                        // After atlas reset, external window paints may consume
                        // shared pending_uploads before the main window sees them.
                        // Schedule a full atlas upload to ensure all glyph data is present.
                        app.atlas_full_upload_needed.store(true, .release);
                    }
                }

                // Build dirty row keys from TBS paint_dirty_snapshot (captured by acquireForPaint).
                // The bitset iterator yields sorted, unique row indices — no dedup needed.
                const dirty_row_keys = &app.wm_paint_dirty_row_keys;
                dirty_row_keys.clearRetainingCapacity();
                var paint_snapshot_ok = true;

                if (row_mode) {
                    const dirty_count = app.tbs.paint_dirty_snapshot.count();
                    dirty_row_keys.ensureTotalCapacity(app.alloc, dirty_count) catch {
                        paint_snapshot_ok = false;
                    };
                    if (paint_snapshot_ok) {
                        var dit = app.tbs.paint_dirty_snapshot.iterator(.{});
                        while (dit.next()) |row_idx| {
                            dirty_row_keys.appendAssumeCapacity(@intCast(row_idx));
                        }
                    }
                }

                // Use committed.rows (content rows from core) as the baseline,
                // not app.surface.rows (global grid rows) which includes
                // tabline/statusline rows that never receive vertex data.
                var effective_rows: u32 = committed.rows;
                var rows_mismatch: bool = false;
                if (row_mode and row_mode_max_row_end_snapshot != 0 and row_mode_max_row_end_snapshot < effective_rows) {
                    effective_rows = row_mode_max_row_end_snapshot;
                    rows_mismatch = true;
                }
                const effective_row_valid_count: u32 =
                    if (effective_rows < row_valid_count_snapshot) effective_rows else row_valid_count_snapshot;

                const paint_rects_snapshot = &app.wm_paint_rects_snapshot;
                paint_rects_snapshot.clearRetainingCapacity();
                paint_rects_snapshot.ensureTotalCapacity(app.alloc, app.paint_rects.items.len) catch {
                    paint_snapshot_ok = false;
                };
                if (paint_snapshot_ok) {
                    paint_rects_snapshot.appendSliceAssumeCapacity(app.paint_rects.items);
                    app.paint_rects.clearRetainingCapacity();
                }

                const paint_full_snapshot = tbs_snapshot.paint_full;

                app.mu.unlock(core.clock.io());

                if (atlas_recreate_needed) {
                    var recreate_ok = false;
                    if (gpu_ptr) |g| {
                        g.lockContext();
                        g.recreateAtlasTextureIfNeeded(atlas_recreate_w, atlas_recreate_h) catch |e| {
                            if (log_enabled) applog.appLog("[win] D3D atlas texture recreation failed, retrying: {any}\n", .{e});
                        };
                        recreate_ok = (g.atlas_w == atlas_recreate_w and g.atlas_h == atlas_recreate_h);
                        g.unlockContext();
                    }
                    if (!recreate_ok) {
                        if (atlas_ptr) |a| {
                            a.mu.lockUncancelable(core.clock.io());
                            a.atlas_reset_pending = true;
                            a.mu.unlock(core.clock.io());
                        }
                        app.atlas_full_upload_needed.store(true, .release);
                        app.tbs.rotation_mu.lockUncancelable(core.clock.io());
                        app.tbs.pending_paint_full = true;
                        app.tbs.rotation_mu.unlock(core.clock.io());
                        scheduleMainPaintRetry(hwnd, app);
                        return 0;
                    }
                }

                if (!paint_snapshot_ok) {
                    app.tbs.rotation_mu.lockUncancelable(core.clock.io());
                    app.tbs.pending_paint_full = true;
                    app.tbs.rotation_mu.unlock(core.clock.io());
                    scheduleMainPaintRetry(hwnd, app);
                    return 0;
                }

                if (log_enabled) {
                    t_snapshot_end_ns = core.clock.nowNs();
                }

                if (log_enabled) {
                    applog.appLog(
                        "[win] WM_PAINT rcPaint=({d},{d})-({d},{d}) dirty={s} need_seed={d} row_mode={d} rows={d} row_verts_len={d} main_verts={d}\n",
                        .{
                            ps.rcPaint.left,                       ps.rcPaint.top,                        ps.rcPaint.right,                 ps.rcPaint.bottom,
                            if (dirty == null) "null" else "rect", @as(u32, @intFromBool(did_need_seed)), @as(u32, @intFromBool(row_mode)), rows_snapshot,
                            row_verts_len,                         main_verts_len_snapshot,
                        },
                    );
                    if (row_mode and rows_mismatch) {
                        applog.appLog(
                            "[win] WM_PAINT(row) WARN rows_mismatch rows={d} max_row_end={d} row_verts_len={d}\n",
                            .{ rows_snapshot, row_mode_max_row_end_snapshot, row_verts_len },
                        );
                    }
                }

                // Flush atlas uploads (may be triggered by core updates).
                // Uses since-based cursor so multiple windows can independently
                // consume the same append-only pending_uploads queue.
                var atlas_uploaded = false;
                if (atlas_ptr) |a| {
                    if (gpu_ptr) |g| {
                        g.lockContext();
                        defer g.unlockContext();
                        // Atomic read-then-clear: a plain load followed by a
                        // separate store would let a NEW true set by the
                        // core/RPC thread between them get silently
                        // overwritten back to false, losing that signal.
                        const need_full = app.atlas_full_upload_needed.swap(false, .acq_rel);
                        if (need_full) {
                            if (log_enabled) applog.appLog("[win] atlas full upload (post-reset sync)\n", .{});
                        }
                        const upload = app_mod.flushAtlasUploads(a, g, app.atlas_upload_cursor, need_full);
                        if (upload.success) {
                            if (upload.cursor != app.atlas_upload_cursor) atlas_uploaded = true;
                            app.atlas_upload_cursor = upload.cursor;
                        } else {
                            // Keep the cursor unchanged and promote every
                            // failure (including incremental upload) to a full
                            // retry. Do not draw this frame against a texture
                            // missing pixels referenced by committed UVs.
                            app.atlas_full_upload_needed.store(true, .release);
                            app.tbs.rotation_mu.lockUncancelable(core.clock.io());
                            app.tbs.pending_paint_full = true;
                            app.tbs.rotation_mu.unlock(core.clock.io());
                            scheduleMainPaintRetry(hwnd, app);
                            if (log_enabled) applog.appLog("[win] atlas upload failed; requeued full paint\n", .{});
                            return 0;
                        }
                    }
                }
                if (log_enabled and atlas_uploaded) {
                    applog.appLog("[win] atlas_uploads flushed (cursor={d})\n", .{app.atlas_upload_cursor});
                }
                if (log_enabled) {
                    t_atlas_end_ns = core.clock.nowNs();
                }

                var retention_snapshot = app_mod.RetentionDrawSnapshot{};
                if (b_recompose_frame) {
                    app_mod.snapshotRetainedRows(
                        app.alloc,
                        &app.tbs,
                        app.retention_vbs[0..],
                        app.retention_cpu_snapshots[0..],
                        tbs_snapshot.commit_rev,
                        &retention_snapshot,
                    );
                }

                var render_ok = false;
                if (gpu_ptr) |g| {
                    // Lock D3D context for thread-safe rendering
                    g.lockContext();
                    defer g.unlockContext();

                    // Leaving recompose clears
                    // the per-grid offsets so the HLSL identity gate
                    // (count == 0) restores the exact pre-B pipeline. Guarded
                    // by the live count so a paint that failed on the
                    // transition frame still gets the clear on its retry. Only
                    // the row-mode recompose path uploads offsets, so a
                    // non-row paint always clears too.
                    if ((!b_recompose_frame or !row_mode) and g.scroll_offset_count != 0) {
                        g.clearScrollOffsets() catch |e| {
                            if (log_enabled) applog.appLog("clearScrollOffsets failed: {any}\n", .{e});
                            recoverMainPaintFailure(hwnd, app);
                            return 0;
                        };
                    }

                    // Calculate content width for "always" scrollbar mode
                    // When content_hwnd exists, use its size (D3D11 is bound to content_hwnd)
                    var client_for_content: c.RECT = undefined;
                    const size_hwnd = if (app.content_hwnd) |ch| ch else hwnd;
                    _ = c.GetClientRect(size_hwnd, &client_for_content);
                    const client_width_u32: u32 = @intCast(@max(1, client_for_content.right - client_for_content.left));
                    const content_width: ?u32 = if (app.config.scrollbar.enabled and app.config.scrollbar.isAlways())
                        getEffectiveContentWidth(app, client_width_u32)
                    else
                        null;

                    // Content Y offset for ext_tabline (pushes content down below tabbar)
                    // When using content_hwnd (child window for D3D11), offset is 0 because D3D11 renders in child window starting at y=0
                    // Only applies to titlebar mode (sidebar mode uses standard titlebar)
                    const content_y_offset: ?u32 = if (app.ext_tabline_enabled and app.tabline_style == .titlebar and app.content_hwnd == null)
                        @intCast(app.scalePx(TablineState.TAB_BAR_HEIGHT))
                    else
                        null;

                    // Content X offset for sidebar mode (pushes content right of sidebar)
                    const content_x_offset: ?u32 = if (app.ext_tabline_enabled and app.tabline_style == .sidebar and !app.sidebar_position_right)
                        @intCast(app.scalePx(@as(c_int, @intCast(app.sidebar_width_px))))
                    else
                        null;

                    // Sidebar right width (reduces content area from right edge)
                    const sidebar_right_width: ?u32 = if (app.ext_tabline_enabled and app.tabline_style == .sidebar and app.sidebar_position_right)
                        @intCast(app.scalePx(@as(c_int, @intCast(app.sidebar_width_px))))
                    else
                        null;

                    // Tabbar background color - fallback strip shown if the
                    // tabline texture is not yet generated (initial frame or
                    // update failure). Track the OS light/dark theme cache so
                    // the fallback matches currentTitlebarPalette().bar_bg
                    // (RGB(32,32,32) dark / RGB(240,240,240) light).
                    const tabbar_bg_color: ?[4]f32 = if (app.ext_tabline_enabled and app.tabline_style == .titlebar and app.content_hwnd == null)
                        (if (g_os_dark_theme_cached)
                            [4]f32{ 32.0 / 255.0, 32.0 / 255.0, 32.0 / 255.0, 1.0 }
                        else
                            [4]f32{ 240.0 / 255.0, 240.0 / 255.0, 240.0 / 255.0, 1.0 })
                    else
                        null;
                    const content_x_offset_i32: i32 = if (content_x_offset) |off| @intCast(off) else 0;
                    const content_y_offset_i32: i32 = if (content_y_offset) |off| @intCast(off) else 0;
                    const content_right_i32: i32 = if (content_width) |cw|
                        content_x_offset_i32 + @as(i32, @intCast(cw))
                    else
                        client_for_content.right;

                    // Snap viewport height to cell boundaries to match core's NDC calculation.
                    // The core computes NDC using grid_rows * cell_h (snapped to cell boundaries),
                    // so the D3D11 viewport must use the same snapped height to prevent sub-pixel
                    // misalignment between vertex positions and scissor rects (which causes stripes).
                    const content_height: u32 = app_mod.snappedContentHeight(
                        @intCast(@max(1, client_for_content.bottom - client_for_content.top)),
                        row_h_px_snapshot,
                        content_y_offset orelse 0,
                    );

                    // Update tabline/sidebar texture (rendered via GDI offscreen -> D3D11 texture)
                    // This avoids DWM composition issues by keeping GDI rendering offscreen
                    if (app.ext_tabline_enabled) {
                        if (app.tabline_style == .titlebar and app.tabline_state.tab_count > 0) {
                            const tabline_width: u32 = @intCast(@max(1, client_for_content.right));
                            const tabline_height: u32 = @intCast(app.scalePx(TablineState.TAB_BAR_HEIGHT));
                            tabline_mod.renderTablineToD3D(app, tabline_width, tabline_height);
                        } else if (app.tabline_style == .sidebar) {
                            // Always call renderSidebarToD3D: it releases texture when tab_count == 0
                            const sw: u32 = @intCast(app.scalePx(@as(c_int, @intCast(app.sidebar_width_px))));
                            const sh: u32 = @intCast(@max(1, client_for_content.bottom));
                            tabline_mod.renderSidebarToD3D(app, sw, sh);
                        }
                    }

                    if (!row_mode) {
                        // Flat rendering no longer references the per-row
                        // buffers retained by a previous row-mode frame.
                        _ = app_mod.resizeRowVBsForPaint(
                            app.alloc,
                            &app.row_vbs,
                            &app.row_vb_budget,
                            &app.row_vb_retained_bytes,
                            0,
                        );

                        // A mode transition can leave a row-mode scrollbar in
                        // retained back_tex. Restore it and widen this flat
                        // draw's damage so the clean strip is also presented.
                        const restored_scrollbar_rect = g.restoreScrollbarUnderlay() catch |e| {
                            if (log_enabled) applog.appLog("restoreScrollbarUnderlay failed: {any}\n", .{e});
                            recoverMainPaintFailure(hwnd, app);
                            return 0;
                        };
                        if (restored_scrollbar_rect) |restored_rect| {
                            dirty = if (dirty) |old| callbacks.unionRect(old, restored_rect) else restored_rect;
                        }

                        // Non-row mode: draw directly from the refcount-protected
                        // committed set. acquireForPaint keeps this set immutable
                        // until releaseFromPaint, and the outer WM_PAINT guard
                        // rejects Present-driven reentrancy, so an O(V) heap
                        // snapshot is neither necessary nor safe under OOM.
                        // IMPORTANT: Do NOT hold app.mu during drawEx.
                        // drawEx calls DXGI Present which can pump Win32 messages internally.
                        // If a re-entrant message handler tries app.mu.lock() on the same thread
                        // -> self-deadlock (SRWLOCK is non-reentrant).
                        var non_row_draw = false;
                        if (!committed.row_mode) {
                            non_row_draw = true;
                        } else {
                            // Row-mode flipped mid-frame; skip and let the next paint handle it.
                            if (log_enabled) applog.appLog("[win] WM_PAINT(non-row) row_mode flipped -> skip\n", .{});
                        }
                        if (non_row_draw) {
                            const cursor_items: []const core.Vertex = if (app.cursor_blink_state) committed_cursor.verts.items else &.{};
                            if (g.drawEx(committed.flat_verts.items, cursor_items, dirty, .{ .content_width = content_width, .content_y_offset = content_y_offset, .content_x_offset = content_x_offset, .sidebar_right_width = sidebar_right_width, .content_height = content_height, .tabbar_bg_color = tabbar_bg_color, .glow_enabled = glow_enabled, .glow_intensity = glow_intensity })) {
                                render_ok = true;
                                // Non-row-mode equivalent of row-mode's
                                // (back_tex_valid_snapshot AND preserve_back) OR rendered_complete.
                                //
                                // draw_preserved: drawEx actually preserved back_tex this paint.
                                //   d3d11_renderer.zig:821 clears whenever
                                //     !has_presented_once OR dirty == null OR opacity < 1.0,
                                //   so all three conditions must hold for the previous validity
                                //   to carry forward. (has_presented_once is true after a
                                //   successful drawEx so is not re-checked here.)
                                //
                                // rendered_complete: drawEx just did a full redraw of complete
                                //   flat_verts. dirty == null is the "full redraw" indicator
                                //   for non-row-mode (no scissor restriction). !seed_pending
                                //   is the proxy for "flat_verts covers the whole grid".
                                //   Without dirty == null, a transparent partial-dirty paint
                                //   would clear and only draw within the scissor — bv would
                                //   then be claimed on an incomplete back_tex.
                                const draw_preserved =
                                    back_tex_valid_snapshot and dirty != null and g.opacity >= 1.0;
                                const rendered_complete =
                                    !seed_pending_snapshot and dirty == null;
                                app.mu.lockUncancelable(core.clock.io());
                                app.back_tex_valid = draw_preserved or rendered_complete;
                                app.mu.unlock(core.clock.io());
                            } else |e| {
                                if (log_enabled) applog.appLog("gpu.draw failed: {any}\n", .{e});
                            }
                        }
                    } else {
                        // --- Row-mode ---
                        var t_row_start_ns: i128 = 0;
                        var t_present_start_ns: i128 = 0;
                        if (log_enabled) {
                            t_row_start_ns = core.clock.nowNs();
                        }

                        // Build sorted, deduplicated list of rows to draw.
                        const rows_to_draw = &app.wm_paint_rows_to_draw;

                        // Transparency mode (opacity<1.0) must force full rows too:
                        // preserve_back=false clears back_tex entirely in drawEx, so if only
                        // dirty rows are drawn the unchanged rows disappear.  Matches
                        // drawNormalExtRowMode's force_full_rows logic for external windows.
                        //
                        // seed_pending alone no longer forces a full redraw: when
                        // back_tex_valid_snapshot is true the previous frame is preserved on
                        // back_tex, so incremental dirty/scroll updates suffice. Limiting the
                        // seed_pending reason to !back_tex_valid_snapshot keeps the
                        // fresh-from-scratch seed path (initial attach, real resize) doing
                        // full redraws while restoring partial-redraw / DXGI scroll fast paths
                        // when the seed has stuck for unrelated reasons (e.g. zero validity
                        // bits propagated through swapAndShiftRows after WM_SIZE no-op).
                        //
                        // seed_clear_pending_snapshot is the tight coupling: whenever the
                        // back_tex is going to be cleared this frame (preserve_back=false via
                        // the seed_clear branch), every row must be redrawn. Not every
                        // seed_clear_pending setter co-sets paint_full / need_full_seed (e.g.
                        // the on_vertices_row dimension-change path at callbacks.zig:1067), so
                        // relying on those flags alone leaves a window where back_tex is
                        // cleared but only dirty rows are drawn — non-dirty rows show the
                        // clear color until Neovim re-sends grid_line.
                        // Recompose additions:
                        //   b_recompose_frame: full recomposition draws every row.
                        //   b_leaving_recompose: the first ordinary paint after a
                        //   recompose run redraws every row once, erasing the
                        //   scrollbar overlay that recompose frames baked into
                        //   back_tex without an
                        //   underlay capture, so the capture below re-primes
                        //   from clean pixels.
                        const force_full_rows =
                            did_need_seed or
                            b_recompose_frame or
                            b_leaving_recompose or
                            (dirty == null) or
                            paint_full_snapshot or
                            seed_clear_pending_snapshot or
                            (seed_pending_snapshot and !back_tex_valid_snapshot) or
                            glow_enabled or
                            (g.opacity < 1.0);

                        const total_rows_for_enum: u32 = if (effective_rows != 0) effective_rows else row_verts_len;
                        const max_valid_row: u32 = @min(row_verts_len, rows_snapshot);

                        if (!app_mod.computeRowsToDraw(
                            app.alloc,
                            rows_to_draw,
                            force_full_rows,
                            dirty_row_keys.items,
                            total_rows_for_enum,
                            max_valid_row,
                        )) {
                            app.tbs.rotation_mu.lockUncancelable(core.clock.io());
                            app.tbs.pending_paint_full = true;
                            app.tbs.rotation_mu.unlock(core.clock.io());
                            scheduleMainPaintRetry(hwnd, app);
                            return 0;
                        }

                        // If atlas was uploaded but no rows will be drawn in this frame,
                        // request a full repaint so newly uploaded glyphs become visible.
                        if (atlas_uploaded and rows_to_draw.items.len == 0) {
                            app.mu.lockUncancelable(core.clock.io());
                            app.surface.paint_full = true;
                            app.paint_rects.clearRetainingCapacity();
                            app.mu.unlock(core.clock.io());
                            {
                                app.tbs.rotation_mu.lockUncancelable(core.clock.io());
                                app.tbs.pending_paint_full = true;
                                app.tbs.rotation_mu.unlock(core.clock.io());
                            }
                            _ = c.InvalidateRect(hwnd, null, c.FALSE);
                        }

                        if (log_enabled) {
                            applog.appLog(
                                "[win] WM_PAINT(row) force_full_rows={d} rows_to_draw={d} dirty_keys={d} row_verts_len={d}\n",
                                .{
                                    @as(u32, @intFromBool(force_full_rows)),
                                    rows_to_draw.items.len,
                                    dirty_row_keys.items.len,
                                    row_verts_len,
                                },
                            );
                            if (force_full_rows and effective_rows == 0) {
                                applog.appLog(
                                    "[win] WM_PAINT(row) WARN rows_unknown skip_present rows_to_draw={d} row_verts_len={d}\n",
                                    .{ rows_to_draw.items.len, row_verts_len },
                                );
                            }
                            if (force_full_rows and effective_rows != 0 and rows_to_draw.items.len != effective_rows) {
                                applog.appLog(
                                    "[win] WM_PAINT(row) WARN partial_full_rows rows={d} rows_to_draw={d}\n",
                                    .{ effective_rows, rows_to_draw.items.len },
                                );
                            }
                            if (!force_full_rows and rows_to_draw.items.len == 0 and (dirty_row_keys.items.len != 0 or paint_rects_snapshot.items.len != 0)) {
                                applog.appLog(
                                    "[win] WM_PAINT(row) WARN empty_rows_to_draw rows={d} row_verts_len={d} dirty_keys={d} paint_rects={d}\n",
                                    .{ rows_snapshot, row_verts_len, dirty_row_keys.items.len, paint_rects_snapshot.items.len },
                                );
                            }
                        }

                        // --- Build present dirty from actual drawn row_rc + cursor_rc (don't use rcPaint) ---
                        // Read cursor verts from TBS committed set (refcount-protected, lock-free).
                        const cursor_verts_snapshot: []const core.Vertex = committed_cursor.verts.items;
                        if (log_enabled) applog.appLog("[win] WM_PAINT(row) cursor_verts.len={d}\n", .{cursor_verts_snapshot.len});
                        // Use content_hwnd size when it exists (D3D11 is bound to content_hwnd)
                        var client: c.RECT = undefined;
                        const client_hwnd = if (app.content_hwnd) |ch| ch else hwnd;
                        _ = c.GetClientRect(client_hwnd, &client);

                        // Compute cursor rect directly from NDC vertices using viewport
                        // dimensions (content_height etc.) to match the D3D11 viewport's
                        // NDC-to-pixel mapping. Using the client rect (as rectFromCursorVerts
                        // does) causes cumulative position drift because the viewport is
                        // snapped to cell boundaries, which is smaller than the client area.
                        const cursor_rc_opt: ?c.RECT = if (cursor_verts_snapshot.len != 0) blk: {
                            var minx: f32 = cursor_verts_snapshot[0].position[0];
                            var maxx: f32 = minx;
                            var miny: f32 = cursor_verts_snapshot[0].position[1];
                            var maxy: f32 = miny;
                            for (cursor_verts_snapshot) |v| {
                                if (v.position[0] < minx) minx = v.position[0];
                                if (v.position[0] > maxx) maxx = v.position[0];
                                if (v.position[1] < miny) miny = v.position[1];
                                if (v.position[1] > maxy) maxy = v.position[1];
                            }
                            // Mirror the D3D11 viewport calculation from drawEx:
                            //   viewport = (x_offset, y_offset, viewport_width, content_height)
                            const vp_x: u32 = content_x_offset orelse 0;
                            const vp_y: u32 = content_y_offset orelse 0;
                            const base_w: u32 = content_width orelse @intCast(@max(1, client.right));
                            const sidebar_w: u32 = sidebar_right_width orelse 0;
                            const vp_w: u32 = if (base_w > vp_x + sidebar_w) base_w - vp_x - sidebar_w else 1;
                            const vp_h: u32 = content_height;

                            const w_f: f32 = @floatFromInt(vp_w);
                            const h_f: f32 = @floatFromInt(vp_h);
                            const x_off_f: f32 = @floatFromInt(vp_x);
                            const y_off_f: f32 = @floatFromInt(vp_y);

                            const l_f = x_off_f + (minx + 1.0) * 0.5 * w_f;
                            const r_f = x_off_f + (maxx + 1.0) * 0.5 * w_f;
                            const t_f = y_off_f + (1.0 - maxy) * 0.5 * h_f;
                            const b_f = y_off_f + (1.0 - miny) * 0.5 * h_f;

                            var l: i32 = @intFromFloat(@floor(l_f));
                            var r: i32 = @intFromFloat(@ceil(r_f));
                            var t: i32 = @intFromFloat(@floor(t_f));
                            var b: i32 = @intFromFloat(@ceil(b_f));

                            if (l < 0) l = 0;
                            if (t < 0) t = 0;
                            if (r > client.right) r = client.right;
                            if (b > client.bottom) b = client.bottom;

                            if (r <= l or b <= t) break :blk null;
                            break :blk .{ .left = l, .top = t, .right = r, .bottom = b };
                        } else null;

                        // Feed cursor state into the custom shader
                        // uniforms (Ghostty 1.1+ iCurrentCursor /
                        // iPreviousCursor / iTimeCursorChange etc.). No-op
                        // when the rect + color match the last call.
                        // Recompute the rect in floating point to avoid
                        // the 1-pixel inflation that cursor_rc_opt picks
                        // up from its floor/ceil integer rounding (the
                        // dirty-rect consumer needs that, the shader
                        // doesn't).
                        if (cursor_verts_snapshot.len != 0) {
                            if (app.renderer) |*r_sh| {
                                var minx_sh: f32 = cursor_verts_snapshot[0].position[0];
                                var maxx_sh: f32 = minx_sh;
                                var miny_sh: f32 = cursor_verts_snapshot[0].position[1];
                                var maxy_sh: f32 = miny_sh;
                                for (cursor_verts_snapshot) |v| {
                                    if (v.position[0] < minx_sh) minx_sh = v.position[0];
                                    if (v.position[0] > maxx_sh) maxx_sh = v.position[0];
                                    if (v.position[1] < miny_sh) miny_sh = v.position[1];
                                    if (v.position[1] > maxy_sh) maxy_sh = v.position[1];
                                }
                                const vp_x_sh: u32 = content_x_offset orelse 0;
                                const vp_y_sh: u32 = content_y_offset orelse 0;
                                const base_w_sh: u32 = content_width orelse @intCast(@max(1, client.right));
                                const sidebar_w_sh: u32 = sidebar_right_width orelse 0;
                                const vp_w_sh: u32 =
                                    if (base_w_sh > vp_x_sh + sidebar_w_sh)
                                        base_w_sh - vp_x_sh - sidebar_w_sh
                                    else
                                        1;
                                const vp_h_sh: u32 = content_height;
                                const wf_sh: f32 = @floatFromInt(vp_w_sh);
                                const hf_sh: f32 = @floatFromInt(vp_h_sh);
                                const xo_sh: f32 = @floatFromInt(vp_x_sh);
                                const yo_sh: f32 = @floatFromInt(vp_y_sh);
                                const left_sh = xo_sh + (minx_sh + 1.0) * 0.5 * wf_sh;
                                const right_sh = xo_sh + (maxx_sh + 1.0) * 0.5 * wf_sh;
                                const top_sh = yo_sh + (1.0 - maxy_sh) * 0.5 * hf_sh;
                                const bottom_sh = yo_sh + (1.0 - miny_sh) * 0.5 * hf_sh;
                                // Ghostty's cursor shaders interpret the y
                                // component as the BOTTOM edge of the
                                // cursor rect (center is computed as
                                // `y - h/2`, rect spans `y-h..y`). Pass
                                // the bottom-edge so the shader renders
                                // over the actual cursor, not one row
                                // above it.
                                const v0 = cursor_verts_snapshot[0];
                                r_sh.setCursorShaderState(
                                    .{ left_sh, bottom_sh, right_sh - left_sh, bottom_sh - top_sh },
                                    v0.color,
                                );
                            }
                        }

                        const fallback_row_h: u32 = row_h_px_snapshot;
                        const rows_for_layout: u32 = if (rows_mismatch) 0 else if (rows_snapshot != 0) rows_snapshot else row_verts_len;
                        const row_h_px_u32 = if (rows_mismatch)
                            fallback_row_h
                        else
                            rowHeightPxFromClient(hwnd, rows_for_layout, fallback_row_h);
                        const row_h_px: i32 = @intCast(@as(i32, @intCast(row_h_px_u32)));
                        if (log_enabled and (row_h_px_u32 != fallback_row_h or rows_mismatch)) {
                            applog.appLog(
                                "[win] WM_PAINT(row) row_h_px adjust rows={d} client_h={d} fallback={d} row_h={d}\n",
                                .{ rows_for_layout, client.bottom, fallback_row_h, row_h_px_u32 },
                            );
                        }

                        // Use persistent buffer to avoid per-frame alloc/free.
                        const present_rects = &app.wm_paint_present_rects;
                        present_rects.clearRetainingCapacity();
                        var present_rects_fallback_full = false;
                        // Reserve every possible rect before construction:
                        // one span per dirty row, copied cursor/paint damage,
                        // gutter, and scroll damage. If reservation fails we
                        // still draw, but force a full back-buffer present so
                        // a truncated rect list cannot consume TBS dirty state.
                        const present_rect_capacity = rows_to_draw.items.len + paint_rects_snapshot.items.len + 6;
                        present_rects.ensureTotalCapacity(app.alloc, present_rect_capacity) catch {
                            present_rects_fallback_full = true;
                        };

                        // The scrollbar is alpha-blended into retained back_tex.
                        // Restore only its narrow saved underlay before applying
                        // this frame's row/cursor updates; the returned strip is
                        // real back_tex damage and must reach every swapchain
                        // buffer through the per-buffer damage queue.
                        // A recompose paint does
                        // not use underlay capture/restore at all — the full
                        // clear below repaints the strip, and drawEx's clear
                        // invalidates any saved underlay so a later ordinary
                        // paint can never restore stale pre-recompose pixels.
                        const restored_scrollbar_rect = if (b_recompose_frame)
                            null
                        else
                            g.restoreScrollbarUnderlay() catch |e| {
                                if (log_enabled) applog.appLog("restoreScrollbarUnderlay failed: {any}\n", .{e});
                                recoverMainPaintFailure(hwnd, app);
                                return 0;
                            };
                        if (restored_scrollbar_rect) |restored_rect| {
                            present_rects.append(app.alloc, restored_rect) catch {
                                present_rects_fallback_full = true;
                            };
                        }

                        // Build full-width present_rects initially.
                        // After the row drawing loop, we may replace with cursor rects if no content changed.
                        // Add content_y_offset for ext_tabline (present_rects are in screen coords)
                        const present_y_offset: i32 = if (content_y_offset) |off| @intCast(off) else 0;
                        if (rows_to_draw.items.len != 0) {
                            // Build full-width row rects.
                            // rows_to_draw is already sorted+deduplicated from the normalize step above.
                            var span_start: u32 = rows_to_draw.items[0];
                            var span_end: u32 = span_start + 1;

                            var ispan: usize = 1;
                            while (ispan < rows_to_draw.items.len) : (ispan += 1) {
                                const r = rows_to_draw.items[ispan];
                                if (r == span_end) {
                                    span_end += 1;
                                } else {
                                    const top0: i32 = present_y_offset + @as(i32, @intCast(span_start)) * row_h_px;
                                    const bot0: i32 = present_y_offset + @as(i32, @intCast(span_end)) * row_h_px;

                                    const rc0: c.RECT = .{
                                        .left = 0,
                                        .top = top0,
                                        .right = client.right,
                                        .bottom = bot0,
                                    };
                                    present_rects.append(app.alloc, rc0) catch {};

                                    span_start = r;
                                    span_end = r + 1;
                                }
                            }

                            // last span
                            {
                                const top0: i32 = present_y_offset + @as(i32, @intCast(span_start)) * row_h_px;
                                const bot0: i32 = present_y_offset + @as(i32, @intCast(span_end)) * row_h_px;

                                const rc0: c.RECT = .{
                                    .left = 0,
                                    .top = top0,
                                    .right = client.right,
                                    .bottom = bot0,
                                };
                                present_rects.append(app.alloc, rc0) catch {};
                            }
                        } else if (dirty != null) {
                            present_rects.append(app.alloc, dirty.?) catch {};
                        }

                        // Add bottom gutter rect if client area extends beyond the grid area.
                        // This ensures the gutter is properly cleared in all swapchain buffers
                        // during partial present, preventing ghost artifacts from stale content.
                        // Use the actual maximum y coordinate from present_rects to handle cases
                        // where app.surface.rows is stale (e.g., after font/linespace changes).
                        if (present_rects.items.len != 0) {
                            var max_y: i32 = 0;
                            for (present_rects.items) |r| {
                                if (r.bottom > max_y) max_y = r.bottom;
                            }
                            if (max_y > 0 and max_y < client.bottom) {
                                const gutter_rc: c.RECT = .{
                                    .left = 0,
                                    .top = max_y,
                                    .right = client.right,
                                    .bottom = client.bottom,
                                };
                                present_rects.append(app.alloc, gutter_rc) catch {};
                            }
                        }

                        // Always include explicit paint rects (cursor damage) in present set.
                        if (paint_rects_snapshot.items.len != 0) {
                            present_rects.appendSlice(app.alloc, paint_rects_snapshot.items) catch {};
                        }

                        if (cursor_rc_opt) |cr| {
                            present_rects.append(app.alloc, cr) catch {};
                        }

                        // Clamp first, then compact in place with O(n log n)
                        // sorting plus a linear safe-union pass. The previous
                        // all-pairs containment scan reached O(rows^2) for
                        // alternating dirty rows on the accepted 20,000-row
                        // boundary.
                        if (present_rects.items.len != 0) {
                            const max_r: i32 = client.right;
                            const max_b: i32 = client.bottom;
                            var i: usize = 0;
                            while (i < present_rects.items.len) {
                                var r = present_rects.items[i];
                                if (r.left < 0) r.left = 0;
                                if (r.top < 0) r.top = 0;
                                if (r.right > max_r) r.right = max_r;
                                if (r.bottom > max_b) r.bottom = max_b;
                                if (r.right <= r.left or r.bottom <= r.top) {
                                    present_rects.items[i] = present_rects.items[present_rects.items.len - 1];
                                    present_rects.items.len -= 1;
                                    continue;
                                }
                                present_rects.items[i] = r;
                                i += 1;
                            }
                            present_rects.items.len = render_helpers.compactDamageRects(c.RECT, present_rects.items);
                        }

                        // --- DEBUG: show real present rects (rcPaint is NOT reliable in union cases) ---
                        if (applog.isEnabled()) {
                            applog.appLog(
                                "[win] WM_PAINT(row) present_rects={d} (rows_to_draw={d})\n",
                                .{ present_rects.items.len, rows_to_draw.items.len },
                            );

                            if (present_rects.items.len != 0) {
                                var u: c.RECT = present_rects.items[0];
                                var j: usize = 1;
                                while (j < present_rects.items.len) : (j += 1) {
                                    u = callbacks.unionRect(u, present_rects.items[j]);
                                }

                                applog.appLog(
                                    "[win]   present_union=({d},{d})-({d},{d})\n",
                                    .{ u.left, u.top, u.right, u.bottom },
                                );

                                var k: usize = 0;
                                while (k < present_rects.items.len) : (k += 1) {
                                    const r = present_rects.items[k];
                                    applog.appLog(
                                        "[win]   present[{d}]=({d},{d})-({d},{d})\n",
                                        .{ k, r.left, r.top, r.right, r.bottom },
                                    );
                                }
                            } else {
                                applog.appLog("[win]   present_rects is EMPTY\n", .{});
                            }

                            if (cursor_rc_opt) |cr| {
                                applog.appLog(
                                    "[win]   cursor_rc=({d},{d})-({d},{d})\n",
                                    .{ cr.left, cr.top, cr.right, cr.bottom },
                                );
                            }
                        }

                        // row-setup drawEx is the ONLY drawEx in row-mode WM_PAINT.
                        // When did_need_seed is true, we must NOT preserve old back buffer contents,
                        // so integrate "seed-clear" behavior here (no extra drawEx).
                        // With TBS, committed set is read-only — only clear row_valid under app.mu.
                        app.mu.lockUncancelable(core.clock.io());

                        // Use the snapshot rather than a live re-read so seed_clear matches the
                        // value force_full_rows above was computed from. If an RPC callback
                        // (e.g. on_vertices_row dimension change) sets app.seed_clear_pending
                        // between the snapshot and this point, the new request is handled by
                        // the next WM_PAINT — never in a frame where force_full_rows was false.
                        const seed_clear = did_need_seed or seed_clear_pending_snapshot;
                        if (seed_clear) {
                            // Only consume the pending flag when no RPC dimension change has
                            // landed since the snapshot. A bumped row_layout_gen means the new
                            // committed set will need its own clear at the new dimensions;
                            // leaving seed_clear_pending=true defers that to the next paint.
                            if (app.row_layout_gen == row_layout_gen_snapshot) {
                                app.seed_clear_pending = false;
                            }
                            // Only unset validity for rows beyond current grid
                            const current_rows = committed.rows;
                            var clear_idx: usize = current_rows;
                            while (clear_idx < app.row_valid.bit_length) : (clear_idx += 1) {
                                if (app.row_valid.isSet(clear_idx)) {
                                    app.row_valid.unset(clear_idx);
                                    if (app.row_valid_count > 0) {
                                        app.row_valid_count -= 1;
                                    }
                                }
                            }
                        }
                        app.mu.unlock(core.clock.io());

                        // Gate preservation on back_tex_valid (mirror of macOS hasPresentedOnce
                        // plus explicit invalidation on font/linespace/DPI changes) rather than
                        // on !seed_pending. seed_pending alone gets stuck in a dead state when
                        // a scroll arrives before Neovim finishes re-sending grid_line for all
                        // rows: swapAndShiftRows propagates zero validity bits through every
                        // shifted slot, row_valid_count never reaches total_rows, and the old
                        // gating cleared back_tex on every frame.
                        // Transparency mode (opacity<1.0) must still force clear: premultiplied
                        // alpha blending accumulates on retained back_tex, producing faint ghost
                        // text on rows that are drawn over without an intervening clear (matches
                        // external window logic in drawNormalExtRowMode).
                        // A recompose paint
                        // never preserves — the content viewport is cleared to
                        // the background color and fully recomposed. (drawEx's
                        // clear also invalidates the saved scrollbar underlay,
                        // which the underlay lifecycle requires.)
                        const preserve_back = !seed_clear and
                            !b_recompose_frame and
                            back_tex_valid_snapshot and
                            !glow_enabled and
                            g.opacity >= 1.0;
                        if (log_enabled) applog.appLog(
                            "[win] WM_PAINT(row) setup preserve_back={d} did_need_seed={d} seed_pending={d} seed_clear={d}\n",
                            .{
                                @as(u32, @intFromBool(preserve_back)),
                                @as(u32, @intFromBool(did_need_seed)),
                                @as(u32, @intFromBool(seed_pending_snapshot)),
                                @as(u32, @intFromBool(seed_clear)),
                            },
                        );

                        const row_draw_params = app_mod.RowModeDrawParams{
                            .content_height = content_height,
                            .row_h_px = row_h_px,
                            .x_offset = content_x_offset_i32,
                            .y_offset = content_y_offset_i32,
                            .content_right = content_right_i32,
                            .preserve_back = preserve_back,
                            // Per-row scissor when we're either past seed mode or
                            // preserving a valid back_tex (incremental updates on top of
                            // a previously-painted frame). Only the fresh-from-scratch
                            // seed path (back_tex_valid=false) keeps the full-area scissor.
                            // A recompose paint
                            // disables per-row scissor while keeping row translation
                            // through the VS constant (use_vs_row_translation).
                            .use_row_scissor = (!seed_pending_snapshot or back_tex_valid_snapshot) and !b_recompose_frame,
                            .use_vs_row_translation = b_recompose_frame,
                            .glow_enabled = glow_enabled,
                            .content_width = content_width,
                            .content_y_offset = content_y_offset,
                            .content_x_offset = content_x_offset,
                            .sidebar_right_width = sidebar_right_width,
                            .tabbar_bg_color = tabbar_bg_color,
                        };

                        // Ensure row_vbs array covers committed set's row count.
                        {
                            const need_len = committed.row_map.items.len;
                            if (!app_mod.resizeRowVBsForPaint(
                                app.alloc,
                                &app.row_vbs,
                                &app.row_vb_budget,
                                &app.row_vb_retained_bytes,
                                need_len,
                            )) {
                                app.tbs.rotation_mu.lockUncancelable(core.clock.io());
                                app.tbs.pending_paint_full = true;
                                app.tbs.rotation_mu.unlock(core.clock.io());
                                scheduleMainPaintRetry(hwnd, app);
                                return 0;
                            }
                        }

                        // Apply scroll pixel shift (row_vbs shift + cursor ghost + back_tex shift).
                        // Scroll state is bundled in PaintSnapshot, atomically consistent with committed set.
                        // Drain-barrier order: pending scroll is consumed after the barrier
                        // above and before any vertex consumption below. The
                        // RowVB metadata shift is applied on every path; the
                        // back_tex blit runs only when
                        // ease_math.scrollBackTexAllowed(recompose). A recompose
                        // paint that also blitted would double-move the pixels.
                        var scroll_shift_result = app_mod.ScrollShiftResult{};
                        if (tbs_snapshot.scroll_rect != null and (preserve_back or b_recompose_frame)) {
                            const sr = tbs_snapshot.scroll_rect.?;
                            scroll_shift_result = app_mod.applyScrollShiftGated(
                                g,
                                app.alloc,
                                app.row_vbs.items,
                                &app.row_vbs_shift_scratch,
                                rows_to_draw,
                                &app.scroll_rows_merge_scratch,
                                ease_math.scrollBackTexAllowed(b_recompose_frame),
                                sr,
                                tbs_snapshot.scroll_dy_px,
                                tbs_snapshot.vb_shift,
                                tbs_snapshot.scroll_row_start,
                                tbs_snapshot.scroll_row_end,
                                &app.last_painted_cursor_row,
                                row_h_px,
                                effective_rows,
                                content_y_offset_i32,
                            );
                            if (!scroll_shift_result.rows_complete) {
                                app.tbs.rotation_mu.lockUncancelable(core.clock.io());
                                app.tbs.pending_paint_full = true;
                                app.tbs.rotation_mu.unlock(core.clock.io());
                                scheduleMainPaintRetry(hwnd, app);
                                return 0;
                            }
                        } else if (!preserve_back) {
                            // No scroll shift, but still apply pending vb shift to scroll region.
                            if (tbs_snapshot.vb_shift != 0 and tbs_snapshot.scroll_row_end > tbs_snapshot.scroll_row_start) {
                                const abs_shift: u32 = @intCast(if (tbs_snapshot.vb_shift < 0) -tbs_snapshot.vb_shift else tbs_snapshot.vb_shift);
                                app_mod.ensureShiftScratch(app.alloc, &app.row_vbs_shift_scratch, abs_shift);
                                app_mod.shiftRowVBs(app.row_vbs.items, tbs_snapshot.vb_shift, tbs_snapshot.scroll_row_start, tbs_snapshot.scroll_row_end, app.row_vbs_shift_scratch.items);
                            }
                        }

                        // Recompose path: upload the offset ledger before any
                        // vertex consumption. The offset buffer must be bound
                        // for the main color, cursor, and bloom-extract
                        // passes. Fixed-size stack array:
                        // no allocation on the paint path.
                        if (b_recompose_frame) {
                            var b_offset_entries: [d3d11.max_scroll_offsets]d3d11.ScrollOffset = undefined;
                            var b_offset_count: usize = 0;
                            const b_ledger = &app.b_offset_ledger;
                            const visible_grids: []const app_mod.GridInfo = if (app.corep) |corep|
                                app.getVisibleGridsCached(corep)
                            else
                                &[_]app_mod.GridInfo{};
                            const content_height_f64: f64 = @floatFromInt(content_height);
                            const row_height_f64: f64 = @floatFromInt(row_h_px_snapshot);
                            const cell_height_ndc: f64 = if (content_height_f64 > 0.0)
                                2.0 * row_height_f64 / content_height_f64
                            else
                                0.0;
                            var b_capacity_dropped = false;
                            var b_oi: usize = 0;
                            while (b_oi < b_ledger.len) {
                                const grid_id = b_ledger.grid_ids[b_oi];
                                // A fixed float above an animating grid owns the
                                // pixels in its rectangle. Drop the source entry,
                                // rather than merely omitting it, so the residual
                                // offset cannot reappear when the float closes.
                                var covered_by_fixed_float = false;
                                var anim_start_row: i64 = 0;
                                var anim_start_col: i64 = 0;
                                var anim_end_row: i64 = 0;
                                var anim_end_col: i64 = 0;
                                var anim_found = false;
                                for (visible_grids) |anim_grid| {
                                    if (anim_grid.grid_id != grid_id) continue;
                                    anim_found = true;
                                    anim_start_row = @as(i64, anim_grid.start_row);
                                    anim_start_col = @as(i64, anim_grid.start_col);
                                    anim_end_row = anim_start_row + @max(@as(i64, anim_grid.rows), 0);
                                    anim_end_col = anim_start_col + @max(@as(i64, anim_grid.cols), 0);
                                    break;
                                }
                                for (visible_grids) |fixed_grid| {
                                    if (!anim_found) break;
                                    if (fixed_grid.zindex <= 0 or fixed_grid.follows_scroll != 0) continue;
                                    if (fixed_grid.grid_id == grid_id) continue;
                                    const fixed_start_row: i64 = @as(i64, fixed_grid.start_row);
                                    const fixed_start_col: i64 = @as(i64, fixed_grid.start_col);
                                    const fixed_end_row = fixed_start_row + @max(@as(i64, fixed_grid.rows), 0);
                                    const fixed_end_col = fixed_start_col + @max(@as(i64, fixed_grid.cols), 0);
                                    if (anim_start_row < fixed_end_row and fixed_start_row < anim_end_row and
                                        anim_start_col < fixed_end_col and fixed_start_col < anim_end_col)
                                    {
                                        covered_by_fixed_float = true;
                                        break;
                                    }
                                }
                                if (covered_by_fixed_float) {
                                    // Arm the pending flag like every sibling
                                    // drop site. Today the was_active edge
                                    // already guarantees the final recompose
                                    // frame, but this site must not silently
                                    // depend on that if the derivation ever
                                    // changes.
                                    if (b_ledger.dropGrid(grid_id)) app.b_forced_zero_pending = true;
                                    continue;
                                }
                                if (b_offset_count >= b_offset_entries.len) {
                                    _ = b_ledger.dropAll();
                                    app.b_forced_zero_pending = true;
                                    b_offset_count = 0;
                                    b_capacity_dropped = true;
                                    if (log_enabled) applog.appLog("[smooth] offset frame dropped: renderer capacity exceeded\n", .{});
                                    break;
                                }
                                var content_top_ndc: f64 = 1.0;
                                var content_bottom_ndc: f64 = -1.0;
                                for (visible_grids) |visible_grid| {
                                    if (visible_grid.grid_id != grid_id) continue;
                                    if (visible_grid.start_row < 0 or visible_grid.rows <= 0) continue;
                                    const grid_start_row: i64 = @max(@as(i64, visible_grid.start_row), 0);
                                    const grid_rows: i64 = @max(@as(i64, visible_grid.rows), 0);
                                    const margin_top: i64 = @max(@as(i64, visible_grid.margin_top), 0);
                                    const margin_bottom: i64 = @max(@as(i64, visible_grid.margin_bottom), 0);
                                    const content_start_row = grid_start_row + @min(margin_top, grid_rows);
                                    // Exclusive end = start + rows - margin_bottom (macOS
                                    // parity); subtracting margin_top here too would clip
                                    // the last scrollable row of a split with a winbar.
                                    const content_end_row = @max(
                                        content_start_row,
                                        grid_start_row + grid_rows - @min(margin_bottom, grid_rows),
                                    );
                                    const top_px = @min(content_height_f64, @as(f64, @floatFromInt(content_start_row)) * row_height_f64);
                                    const bottom_px = @min(content_height_f64, @as(f64, @floatFromInt(content_end_row)) * row_height_f64);
                                    content_top_ndc = ease_math.localNdcY(top_px, content_height_f64);
                                    content_bottom_ndc = ease_math.localNdcY(bottom_px, content_height_f64);
                                    break;
                                }
                                var retained_count: i32 = 0;
                                for (0..retention_snapshot.count) |ri| {
                                    // Only rows that will actually draw may release the
                                    // pin; a failed snapshot copy must keep the stretch.
                                    if (!retention_snapshot.ready[ri]) continue;
                                    if (retention_snapshot.captures[ri].grid_id == grid_id) retained_count += 1;
                                }
                                const offset_ndc = ease_math.offsetNdc(
                                    b_ledger.offsets_px[b_oi],
                                    content_height_f64,
                                );
                                b_offset_entries[b_offset_count] = .{
                                    // Low 32-bit word match (Shader ABI section).
                                    .grid_id = @truncate(grid_id),
                                    // offset_ndc = -2 * offset_px / snapped
                                    // viewport height (Shader ABI: 正 = 画面下方向).
                                    .offset_ndc = @floatCast(offset_ndc),
                                    .content_top_ndc = @floatCast(content_top_ndc),
                                    .content_bottom_ndc = @floatCast(content_bottom_ndc),
                                    .move_all = 0,
                                    // Keep the exposed edge pinned until the
                                    // published retention rows cover its band.
                                    .pin_edges = if (ease_math.coversBand(retained_count, offset_ndc, cell_height_ndc)) 0 else 1,
                                    .zindex = 0,
                                };
                                b_offset_count += 1;
                                b_oi += 1;
                            }
                            // Following floats are a second pass: only entries
                            // produced by the ledger loop can act as anchors.
                            if (!b_capacity_dropped) {
                                for (visible_grids) |float_grid| {
                                    if (float_grid.zindex <= 0 or float_grid.grid_id == 1 or
                                        float_grid.follows_scroll == 0 or float_grid.anchor_grid <= 1) continue;
                                    var has_entry = false;
                                    for (b_offset_entries[0..b_offset_count]) |entry| {
                                        if (@as(i64, entry.grid_id) == float_grid.grid_id) {
                                            has_entry = true;
                                            break;
                                        }
                                    }
                                    if (has_entry) continue;
                                    var anchor_is_visible = false;
                                    for (visible_grids) |anchor_grid| {
                                        if (anchor_grid.grid_id == float_grid.anchor_grid and anchor_grid.zindex <= 0) {
                                            anchor_is_visible = true;
                                            break;
                                        }
                                    }
                                    if (!anchor_is_visible) continue;
                                    var anchor_entry: ?d3d11.ScrollOffset = null;
                                    for (b_offset_entries[0..b_offset_count]) |entry| {
                                        if (@as(i64, entry.grid_id) == float_grid.anchor_grid) {
                                            anchor_entry = entry;
                                            break;
                                        }
                                    }
                                    if (anchor_entry) |anchor| {
                                        if (b_offset_count >= b_offset_entries.len) {
                                            _ = b_ledger.dropAll();
                                            app.b_forced_zero_pending = true;
                                            b_offset_count = 0;
                                            b_capacity_dropped = true;
                                            if (log_enabled) applog.appLog("[smooth] offset frame dropped: renderer capacity exceeded\n", .{});
                                            break;
                                        }
                                        b_offset_entries[b_offset_count] = .{
                                            .grid_id = @truncate(float_grid.grid_id),
                                            .offset_ndc = anchor.offset_ndc,
                                            .content_top_ndc = 2.0,
                                            .content_bottom_ndc = -2.0,
                                            .move_all = 1,
                                            .pin_edges = 0,
                                            .zindex = @truncate(float_grid.zindex),
                                        };
                                        b_offset_count += 1;
                                    }
                                }
                            }
                            if (b_offset_count == 0) {
                                // Final-zero frame: the
                                // ledger is empty but the frame must still be a
                                // full recomposition with row translation live.
                                // The HLSL identity gate skips row_translation
                                // entirely when the count is zero, so publish
                                // one neutral entry whose grid_id matches no
                                // vertex (offset_ndc 0 = no movement either way).
                                b_offset_entries[0] = .{
                                    .grid_id = std.math.maxInt(i32),
                                    .offset_ndc = 0.0,
                                    .content_top_ndc = 1.0,
                                    .content_bottom_ndc = -1.0,
                                    .move_all = 0,
                                    .pin_edges = 0,
                                    .zindex = 0,
                                };
                                b_offset_count = 1;
                            }
                            g.updateScrollOffsets(b_offset_entries[0..b_offset_count]) catch |e| {
                                // Fail closed: without the offsets
                                // the full-row draw would land untranslated.
                                if (log_enabled) applog.appLog("updateScrollOffsets failed: {any}\n", .{e});
                                recoverMainPaintFailure(hwnd, app);
                                return 0;
                            };
                        }

                        // TBS lock-free draw: committed set is protected by refcount,
                        // no app.mu needed during VB upload + draw.
                        var row_vb_budget_exceeded = false;
                        const row_draw_result = app_mod.drawRowModeSetupAndRowsFromSlots(
                            g,
                            &app.row_vb_budget,
                            &app.row_vb_retained_bytes,
                            committed.row_map.items,
                            &app.tbs.pool,
                            app.row_vbs.items,
                            rows_to_draw.items,
                            row_draw_params,
                        ) catch |e| blk: {
                            row_vb_budget_exceeded = e == error.RowVBPhysicalBudgetExceeded;
                            if (log_enabled) applog.appLog("drawRowModeSetupAndRowsFromSlots failed: {any}\n", .{e});
                            var failed_result = app_mod.RowModeDrawResult{};
                            failed_result.metrics.failed_rows = 1;
                            break :blk failed_result;
                        };
                        if (row_vb_budget_exceeded) {
                            app.row_vb_budget_failed = true;
                            if (app.corep) |corep| core.zonvie_core_fail_render_budget(corep);
                            return 0;
                        }

                        // Retention pass: retained captures are
                        // virtual rows and must follow the live remapped rows
                        // while the scroll-offset SRV is still bound. Their
                        // per-capture VS translation is reset before cursor,
                        // bloom, and fixed-overlay passes consume vertices.
                        var retention_metrics = app_mod.SurfaceRowDrawMetrics{
                            .failed_rows = retention_snapshot.failed_rows,
                        };
                        if (b_recompose_frame) {
                            app_mod.drawRetainedRows(
                                g,
                                &retention_snapshot,
                                app.retention_vbs[0..],
                                app.retention_cpu_snapshots[0..],
                                &app.row_vb_budget,
                                &app.row_vb_retained_bytes,
                                row_h_px,
                                @floatFromInt(content_height),
                                &retention_metrics,
                            ) catch |e| {
                                // Retention is cosmetic: a budget trip here skips the
                                // retained rows (pin stays via the ready-count rule)
                                // instead of failing the whole paint like a live-row
                                // budget overrun would.
                                retention_metrics.failed_rows += 1;
                                if (log_enabled) applog.appLog("drawRetainedRows failed: {any}\n", .{e});
                            };
                        }

                        if (log_enabled) applog.appLog(
                            "[win] WM_PAINT(row) seed_state rows={d} row_valid={d} rows_to_draw={d} row_verts_len={d} committed_rows={d} committed_cols={d} row_map_len={d}\n",
                            .{ rows_snapshot, row_valid_count_snapshot, rows_to_draw.items.len, row_verts_len, committed.rows, committed.cols, committed.row_map.items.len },
                        );

                        const drawn_rows = row_draw_result.metrics.drawn_rows;
                        const skipped_empty = row_draw_result.metrics.skipped_empty;
                        const failed_rows = row_draw_result.metrics.failed_rows + retention_metrics.failed_rows;
                        const first_empty_row = row_draw_result.metrics.first_empty_row;
                        const log_vb_upload_rows = row_draw_result.metrics.vb_upload_rows;
                        const log_vb_upload_rows_bytes = row_draw_result.metrics.vb_upload_rows_bytes;
                        const log_vb_upload_ns = row_draw_result.metrics.vb_upload_ns;
                        const log_draw_vb_ns = row_draw_result.metrics.draw_vb_ns;
                        const ctx_ptr = row_draw_result.ctx_ptr;
                        const rs_set_sc_fn = row_draw_result.rs_set_sc_fn;

                        if (log_enabled) {
                            applog.appLog(
                                "[win] WM_PAINT(row-vb) drawn_rows={d} skipped_empty={d} rows_to_draw={d}\n",
                                .{ drawn_rows, skipped_empty, rows_to_draw.items.len },
                            );
                            if (first_empty_row) |erow| {
                                applog.appLog(
                                    "[win] WM_PAINT(row-vb) WARN empty_row={d} rows={d} row_verts_len={d}\n",
                                    .{ erow, rows_snapshot, row_verts_len },
                                );
                            }
                        }

                        // Cursor overlay — shared helper handles upload, scissor, draw/blink-off, and tracking.
                        var cursor_overlay_failed = false;
                        app_mod.drawCursorOverlay(g, .{
                            .cursor_verts = cursor_verts_snapshot,
                            .cursor_row = committed_cursor.last_cursor_row,
                            .cursor_vb = &app.cursor_vb,
                            .cursor_vb_bytes = &app.cursor_vb_bytes,
                            .row_vbs = app.row_vbs.items,
                            .row_map = committed.row_map.items,
                            .pool = &app.tbs.pool,
                            .blink_visible = app.cursor_blink_state,
                            .x_offset = content_x_offset_i32,
                            .y_offset = content_y_offset_i32,
                            .content_right = content_right_i32,
                            .content_height = content_height,
                            .row_h_px = row_h_px,
                            .ctx_ptr = ctx_ptr,
                            // No per-row scissor on a recompose paint; the
                            // cursor pass draws under the full-content scissor
                            // set by the row draw, so the shader offset cannot
                            // clip it against its logical row band.
                            .rs_set_sc_fn = if (b_recompose_frame) null else rs_set_sc_fn,
                            .last_painted_cursor_row = &app.last_painted_cursor_row,
                            .row_already_redrawn = force_full_rows,
                        }) catch |e| {
                            cursor_overlay_failed = true;
                            if (log_enabled) applog.appLog("drawCursorOverlay failed: {any}\n", .{e});
                        };

                        // Post-process bloom (neon glow) for row-mode
                        if (glow_enabled) {
                            const bloom_cursor = if (app.cursor_blink_state)
                                cursor_verts_snapshot
                            else
                                &[_]core.Vertex{};
                            app_mod.drawBloomRowsOverlay(
                                g,
                                committed.row_map.items,
                                &app.tbs.pool,
                                app.row_vbs.items,
                                bloom_cursor,
                                glow_intensity,
                                row_draw_params,
                            );
                        }

                        if (log_enabled and force_full_rows and skipped_empty != 0) {
                            applog.appLog(
                                "[win] WM_PAINT(row) WARN skip_present missing_rows={d} rows={d} row_verts_len={d}\n",
                                .{ skipped_empty, rows_snapshot, row_verts_len },
                            );
                        }

                        if (log_enabled) {
                            var log_present_rects_area_px: u64 = 0;

                            // --- log: present_rects area (sum of rect areas) ---
                            if (present_rects.items.len != 0) {
                                var pi: usize = 0;
                                while (pi < present_rects.items.len) : (pi += 1) {
                                    const r = present_rects.items[pi];
                                    const w_i32: i32 = r.right - r.left;
                                    const h_i32: i32 = r.bottom - r.top;
                                    if (w_i32 > 0 and h_i32 > 0) {
                                        log_present_rects_area_px +=
                                            @as(u64, @intCast(w_i32)) * @as(u64, @intCast(h_i32));
                                    }
                                }
                            }

                            applog.appLog(
                                "[win] WM_PAINT(row-frame) drawn_rows={d} rows_to_draw={d} present_rects={d} present_area_px={d} vb_upload_rows={d} vb_upload_rows_bytes={d} vb_upload_cursor={d} vb_upload_cursor_bytes={d}\n",
                                .{
                                    drawn_rows, // NOTE: variable within row-vb block. See note below
                                    rows_to_draw.items.len,
                                    present_rects.items.len,
                                    log_present_rects_area_px,
                                    log_vb_upload_rows,
                                    log_vb_upload_rows_bytes,
                                    @as(u32, if (cursor_verts_snapshot.len != 0) 1 else 0),
                                    @as(u64, cursor_verts_snapshot.len * @sizeOf(core.Vertex)),
                                },
                            );
                        }

                        if (log_enabled) {
                            t_present_start_ns = core.clock.nowNs();
                        }

                        var layout_ok: bool = true;
                        var rows_current: u32 = 0;
                        app.mu.lockUncancelable(core.clock.io());
                        layout_ok = app.row_layout_gen == row_layout_gen_snapshot;
                        rows_current = committed.rows;
                        app.mu.unlock(core.clock.io());

                        const allow_present = blk: {
                            // Never publish vertices against a newer layout,
                            // even for a seed-clear frame. A metric change can
                            // keep rows/cols unchanged while invalidating the
                            // NDC and row-height snapshot used above. The
                            // render-failure path requeues a full paint at the
                            // new generation.
                            if (!layout_ok) break :blk false;
                            if (rows_current != rows_snapshot) break :blk false;
                            // A failed VB create/upload/draw means one or more
                            // rows from this paint snapshot never reached
                            // back_tex. Treat the whole paint as failed so the
                            // common recovery path requeues a full redraw.
                            if (failed_rows != 0) break :blk false;
                            if (cursor_overlay_failed) break :blk false;

                            // When seed_clear is true, we must present to sync the cleared back buffer
                            // to all swapchain buffers. Skip other checks - the cleared state must be
                            // presented to prevent ghost artifacts in gutter areas.
                            if (seed_clear) break :blk true;

                            // During seed mode with preserve_back=false, we MUST present to ensure
                            // all swapchain buffers get the cleared state. Without this, some buffers
                            // may retain stale gutter content causing ghost artifacts.
                            if (seed_pending_snapshot and !preserve_back) break :blk true;

                            // Never present until core has provided a stable row count.
                            if (effective_rows == 0) break :blk false;

                            if (seed_pending_snapshot) {
                                // back_tex_valid_snapshot is the source-of-truth gate
                                // (same flag preserve_back uses). When it is true,
                                // back_tex already holds a fully-painted frame at the
                                // current dimensions/metrics, so an incomplete row_valid
                                // bitset does not block presenting scroll/dirty updates
                                // — the rows we have not yet re-validated stay sourced
                                // from the preserved back_tex content. Without this,
                                // a WM_SIZE on minimize/restore that resets row_valid,
                                // combined with grid_scroll propagating zero validity
                                // bits via swapAndShiftRows, would freeze present while
                                // preserve_back=true masked the gray-rectangle symptom.
                                if (back_tex_valid_snapshot) {
                                    if (rows_mismatch) {
                                        if (rows_to_draw.items.len != 0 and skipped_empty == 0) break :blk true;
                                        break :blk false;
                                    }
                                    break :blk true;
                                }

                                if (rows_mismatch) {
                                    if (rows_to_draw.items.len != 0 and skipped_empty == 0) break :blk true;
                                    break :blk false;
                                }
                                // No back_tex yet: require a complete seed so the first
                                // present covers every row.
                                if (effective_row_valid_count == effective_rows) {
                                    if (skipped_empty != 0) break :blk false;
                                    if (rows_to_draw.items.len != effective_rows) break :blk false;
                                    break :blk true;
                                }

                                break :blk false;
                            }

                            if (force_full_rows and skipped_empty != 0) break :blk false;
                            if (force_full_rows and rows_to_draw.items.len != effective_rows) break :blk false;
                            break :blk true;
                        };

                        // When scrollBackTex shifted back_tex content, the entire scroll
                        // region changed in back_tex. Add it to present_rects so the
                        // CopySubresourceRegion in present copies the shifted pixels
                        // to all swapchain buffers.
                        if (scroll_shift_result.scroll_rect) |sr| {
                            present_rects.append(app.alloc, sr) catch {};
                        }

                        if (allow_present) {
                            present_frame: {
                                // Save only the track strip before drawing the
                                // alpha-blended overlay. The next fade/update paint
                                // restores this clean copy instead of clearing and
                                // regenerating the entire row set.
                                if (app.config.scrollbar.enabled and scrollbar_alpha_snapshot > 0.001) {
                                    var scrollbar_verts: [12]core.Vertex = undefined;
                                    const scrollbar_vert_count = scrollbar.generateScrollbarVertices(app, client.right, client.bottom, &scrollbar_verts);
                                    if (scrollbar_vert_count != 0) {
                                        if (b_recompose_frame) {
                                            // The scrollbar/fixed
                                            // overlay draws directly onto the
                                            // freshly recomposed back_tex —
                                            // underlay capture/restore is not
                                            // used. The first ordinary paint
                                            // after this run re-primes the
                                            // capture via
                                            // b_leaving_recompose's full-row
                                            // redraw above.
                                            app_mod.drawScrollbarOverlay(
                                                g,
                                                &app.scrollbar_vb,
                                                &app.scrollbar_vb_bytes,
                                                scrollbar_verts[0..scrollbar_vert_count],
                                            ) catch |e| {
                                                if (log_enabled) applog.appLog("drawScrollbarOverlay failed: {any}\n", .{e});
                                                break :present_frame;
                                            };
                                        } else if (scrollbar.getScrollbarTrackRect(app, client.right, client.bottom)) |track_rect| {
                                            const captured_scrollbar_rect = g.captureScrollbarUnderlay(track_rect) catch |e| {
                                                if (log_enabled) applog.appLog("captureScrollbarUnderlay failed: {any}\n", .{e});
                                                break :present_frame;
                                            };
                                            if (captured_scrollbar_rect) |captured_rect| {
                                                present_rects.append(app.alloc, captured_rect) catch {
                                                    present_rects_fallback_full = true;
                                                };
                                                app_mod.drawScrollbarOverlay(
                                                    g,
                                                    &app.scrollbar_vb,
                                                    &app.scrollbar_vb_bytes,
                                                    scrollbar_verts[0..scrollbar_vert_count],
                                                ) catch |e| {
                                                    if (log_enabled) applog.appLog("drawScrollbarOverlay failed: {any}\n", .{e});
                                                    break :present_frame;
                                                };
                                            }
                                        }
                                    }
                                }

                                // When seed_clear is true, the back buffer was just cleared.
                                // We must do a full present to sync the cleared state to all swapchain buffers,
                                // otherwise areas not covered by partial present rects may show stale content.
                                // seed_pending alone no longer forces a full present: when
                                // back_tex_valid_snapshot is true the swapchain has already been
                                // synced to a complete frame, and partial present rects keep
                                // DXGI from copying unchanged regions every paint.
                                // A recompose paint registers full-viewport damage on every
                                // swapchain buffer (a dirty-rect partial present
                                // would leave old glyphs outside the moved
                                // fragment clip). b_recompose_frame already
                                // implies force_full_rows; the explicit term
                                // keeps the damage rule independent of the
                                // row-selection rule.
                                const force_full_present = force_full_rows or
                                    b_recompose_frame or
                                    (seed_pending_snapshot and !back_tex_valid_snapshot and !rows_mismatch) or
                                    seed_clear or
                                    present_rects_fallback_full;
                                const present_rects_slice: []const c.RECT =
                                    if (force_full_present) &[_]c.RECT{} else present_rects.items;

                                // Present1 scroll params: disabled for now.
                                // back_tex pixel shift (scrollBackTex) already handles the retained
                                // content shift. Adding pScrollRect/pScrollOffset to Present1 would
                                // cause a double-shift since we CopySubresourceRegion back_tex→bb.

                                if (g.presentFromBackRectsWithCursorNoResize(
                                    present_rects_slice,
                                    app.cursor_vb,
                                    cursor_verts_snapshot.len,
                                    cursor_rc_opt,
                                    force_full_present,
                                    null,
                                    null,
                                    b_recompose_frame or b_leaving_recompose,
                                )) {
                                    render_ok = true;
                                    // Assign back_tex_valid directly so it can also transition
                                    // true → false in the same paint. Two paths to true:
                                    //
                                    //   1. preserve_back was true AND back_tex_valid_snapshot was
                                    //      true. The previous paint left back_tex in a valid state
                                    //      and this paint only overlaid dirty rows on top of it —
                                    //      back_tex is still valid even if this paint didn't render
                                    //      every row.
                                    //
                                    //   2. We just rendered a complete frame regardless of prior
                                    //      state. "Complete" here is render-side completeness
                                    //      (skipped_empty == 0 and rows_to_draw covers every row),
                                    //      not Neovim-side validation (row_valid_count). The
                                    //      distinction matters for minimize/restore, where
                                    //      row_valid is unsetAll'd by WM_SIZE but row_verts still
                                    //      holds full pre-minimize data — a seed_clear paint
                                    //      redraws every row from that data and back_tex becomes
                                    //      complete even with row_valid_count == 0.
                                    //
                                    // Both conditions fail (preserve_back=false AND incomplete
                                    // render) → back_tex_valid falls to false. This is the
                                    // critical case for the on_vertices_row dimension-change path:
                                    // seed_clear bypasses the row_valid completeness check at
                                    // allow_present and presents anyway, so without an explicit
                                    // false-assignment a stale snapshot value would survive a
                                    // paint that wiped back_tex.
                                    const rendered_complete_frame =
                                        effective_rows != 0 and
                                        skipped_empty == 0 and
                                        rows_to_draw.items.len == effective_rows;
                                    const new_back_tex_valid =
                                        (back_tex_valid_snapshot and preserve_back) or
                                        rendered_complete_frame;
                                    app.mu.lockUncancelable(core.clock.io());
                                    app.back_tex_valid = new_back_tex_valid;
                                    app.mu.unlock(core.clock.io());
                                    // last_painted_cursor_row is tracked by drawCursorOverlay above.
                                } else |e| {
                                    if (log_enabled) applog.appLog("presentFromBackRectsWithCursorNoResize failed: {any}\n", .{e});
                                }

                                if (seed_pending_snapshot and effective_rows != 0 and effective_row_valid_count == effective_rows) {
                                    app.mu.lockUncancelable(core.clock.io());
                                    app.seed_pending = false;
                                    app.surface.paint_full = true;
                                    app.paint_rects.clearRetainingCapacity();
                                    app.seed_clear_pending = true;
                                    app.mu.unlock(core.clock.io());
                                    // Also set TBS pending_paint_full for next paint cycle.
                                    {
                                        app.tbs.rotation_mu.lockUncancelable(core.clock.io());
                                        app.tbs.pending_paint_full = true;
                                        app.tbs.rotation_mu.unlock(core.clock.io());
                                    }
                                    if (log_enabled) applog.appLog(
                                        "[win] WM_PAINT(row) seed_complete rows={d} row_valid={d} -> request repaint\n",
                                        .{ effective_rows, effective_row_valid_count },
                                    );
                                    _ = c.InvalidateRect(hwnd, null, c.FALSE);
                                }
                            }
                        } else if (log_enabled) {
                            var resize_age_ms: i64 = -1;
                            const last_resize_ns = app.last_resize_ns;
                            if (last_resize_ns != 0) {
                                const now_ns = core.clock.nowNs();
                                const diff_ns = now_ns - last_resize_ns;
                                if (diff_ns > 0) {
                                    resize_age_ms = @intCast(@divTrunc(diff_ns, 1_000_000));
                                } else {
                                    resize_age_ms = 0;
                                }
                            }
                            applog.appLog(
                                "[win] WM_PAINT(row) skip_present seed_pending={d} rows={d} rows_cur={d} row_valid={d} rows_to_draw={d} skipped_empty={d} row_verts_len={d} force_full_rows={d} layout_gen={d} layout_ok={d} rows_mismatch={d} resize_age_ms={d}\n",
                                .{
                                    @as(u32, @intFromBool(seed_pending_snapshot)),
                                    effective_rows,
                                    rows_current,
                                    effective_row_valid_count,
                                    rows_to_draw.items.len,
                                    skipped_empty,
                                    row_verts_len,
                                    @as(u32, @intFromBool(force_full_rows)),
                                    row_layout_gen_snapshot,
                                    @as(u32, @intFromBool(layout_ok)),
                                    @as(u32, @intFromBool(rows_mismatch)),
                                    resize_age_ms,
                                },
                            );
                        }

                        if (log_enabled) {
                            const t_done_ns: i128 = core.clock.nowNs();
                            const snapshot_us: u64 = @intCast(@divTrunc(@max(0, t_snapshot_end_ns - t_snapshot_start_ns), 1000));
                            const atlas_us: u64 = @intCast(@divTrunc(@max(0, t_atlas_end_ns - t_snapshot_end_ns), 1000));
                            const row_us: u64 = @intCast(@divTrunc(@max(0, t_present_start_ns - t_row_start_ns), 1000));
                            const present_us: u64 = @intCast(@divTrunc(@max(0, t_done_ns - t_present_start_ns), 1000));
                            const total_us: u64 = row_us + present_us;
                            const vb_upload_us: u64 = @intCast(@divTrunc(@max(0, log_vb_upload_ns), 1000));
                            const draw_vb_us: u64 = @intCast(@divTrunc(@max(0, log_draw_vb_ns), 1000));
                            applog.appLog(
                                "[perf] row_mode_ui snapshot_us={d} atlas_us={d} rows={d} vb_upload_us={d} draw_vb_us={d} row_us={d} present_us={d} total_us={d}\n",
                                .{ snapshot_us, atlas_us, rows_to_draw.items.len, vb_upload_us, draw_vb_us, row_us, present_us, total_us },
                            );
                        }
                    }
                }

                // Recover dirty state if rendering failed, so the next
                // WM_PAINT will retry a full redraw instead of showing stale content.
                if (!render_ok) {
                    recoverMainPaintFailure(hwnd, app);
                } else {
                    completeMainPaintRetry(app);
                }

                // Update IME preedit overlay (separate popup window)
                input.updateImePreeditOverlay(hwnd, app);

                // Tabline is now rendered via D3D11 texture (see renderTablineToD3D call before gpu rendering)
                if (b_schedule_next_frame) {
                    // Active offsets or the required final-zero frame are the
                    // complete wake condition; when both clear, no idle
                    // counter is needed because this remains false.
                    const content_hwnd = app.content_hwnd orelse hwnd;
                    _ = c.InvalidateRect(content_hwnd, null, c.FALSE);
                }
            }

            return 0;
        },

        c.WM_SETTINGCHANGE => {
            // Only consume the message if it was the color-mode broadcast we
            // care about. Other WM_SETTINGCHANGE flavours ("intl", "Policy",
            // "Environment", ...) need to reach DefWindowProcW so the OS can
            // do its standard handling.
            if (handleImmersiveColorSet(hwnd, lParam)) return 0;
            return c.DefWindowProcW(hwnd, msg, wParam, lParam);
        },
        c.WM_THEMECHANGED => {
            // WM_THEMECHANGED covers all visual-style transitions, not just
            // light/dark color-mode. Re-apply the OS titlebar attribute as
            // a best-effort addition, then fall through to DefWindowProcW
            // so the standard uxtheme client-side refresh still runs. This
            // also means caption-less popups (where handleThemeChanged()
            // returns false) get their default handling instead of being
            // silently swallowed.
            _ = handleThemeChanged(hwnd);
            return c.DefWindowProcW(hwnd, msg, wParam, lParam);
        },
        WM_APP_THEME_REREAD => {
            // Posted by the registry-watcher worker thread when
            // AppsUseLightTheme changes. Re-apply to every caption-bearing
            // top-level window on this thread in one pass.
            handleThemeReread();
            return 0;
        },

        WM_APP_OPEN_FONT_PICKER => {
            // Posted from onGuiFont on `:set guifont=*`. Always clear the "*"
            // by writing the current font back (so guifont is never left as
            // "*"); open the dialog only if the first frame was already shown
            // (wParam == 1), i.e. this is an interactive request, not nvim's
            // initial attach broadcast.
            if (getApp(hwnd)) |app| {
                resetGuifontToCurrent(app);
                if (wParam == 1) {
                    openFontPicker(hwnd, app);
                }
            }
            return 0;
        },

        app_mod.WM_APP_PREPARE_GLOW => {
            if (getApp(hwnd)) |app| prepareGlowShadersOnUiThread(hwnd, app);
            return 0;
        },

        // Per-Monitor DPI change (e.g. moving window between monitors)
        0x02E0 => { // WM_DPICHANGED
            if (getApp(hwnd)) |app| {
                const incoming_dpi: u32 = @as(u32, @intCast(wParam & 0xFFFF)); // LOWORD
                const suggested: *const c.RECT = @ptrFromInt(@as(usize, @bitCast(lParam)));
                const incoming_rect = suggested.*;

                // SetWindowPos and downstream layout work may pump messages.
                // Coalesce a nested DPI transition into the outer lifetime
                // pin instead of letting an inner defer clear the same bool.
                if (app.main_dpi_change_in_progress) {
                    app.pending_main_dpi = incoming_dpi;
                    app.pending_main_dpi_rect = incoming_rect;
                    app.main_dpi_replay_needed = true;
                    return 0;
                }
                app.main_dpi_change_in_progress = true;
                defer {
                    app.main_dpi_change_in_progress = false;
                    _ = app.finishActiveOperation();
                }
                // DPI changes invalidate geometry immediately; do not rely
                // on the nested WM_SIZE generated by SetWindowPos.
                app.tbs.clearBEaseCommits();
                app.tbs.clearRetention();
                if (app.b_offset_ledger.dropAll()) app.b_forced_zero_pending = true;
                // Device/D2D/renderer creation in WM_APP_DEVICE_LOST_RECOVER
                // can pump messages and reenter this handler on the same UI
                // thread while that handler still holds app.mu/atlas.mu for
                // parts of its own work — this handler normally acquires both
                // atlas.mu and app.mu. Apply only the suggested HWND rect in
                // that case; recovery replays the resulting DPI and metrics
                // before publishing its new renderer generation.
                if (app.device_lost_recovering) {
                    var target_rect = incoming_rect;
                    while (true) {
                        _ = c.SetWindowPos(
                            hwnd,
                            null,
                            target_rect.left,
                            target_rect.top,
                            target_rect.right - target_rect.left,
                            target_rect.bottom - target_rect.top,
                            c.SWP_NOZORDER | c.SWP_NOACTIVATE,
                        );
                        if (!app.main_dpi_replay_needed) break;
                        target_rect = app.pending_main_dpi_rect;
                        app.main_dpi_replay_needed = false;
                    }
                    return 0;
                }
                var new_dpi = incoming_dpi;
                var target_rect = incoming_rect;
                while (true) {
                    if (applog.isEnabled()) applog.appLog("[win] WM_DPICHANGED: new_dpi={d}\n", .{new_dpi});
                    applyMainDpiState(app, new_dpi);

                    // Resize window to the suggested rect from WM_DPICHANGED.
                    // Nested WM_SIZE is replayed because the DPI pin is live.
                    _ = c.SetWindowPos(
                        hwnd,
                        null,
                        target_rect.left,
                        target_rect.top,
                        target_rect.right - target_rect.left,
                        target_rect.bottom - target_rect.top,
                        c.SWP_NOZORDER | c.SWP_NOACTIVATE,
                    );

                    // SetWindowPos normally triggers WM_SIZE, but that nested
                    // handler is deliberately deferred while this pin is live.
                    updateLayoutToCore(hwnd, app);

                    if (!app.main_dpi_replay_needed) break;
                    new_dpi = app.pending_main_dpi;
                    target_rect = app.pending_main_dpi_rect;
                    app.main_dpi_replay_needed = false;
                }
            }
            return 0;
        },

        c.WM_SIZE => {
            // SIZE_MINIMIZED: skip resize to avoid sending tiny rows/cols to Neovim,
            // which would destroy split window proportions.
            const SIZE_MINIMIZED = 1;
            if (wParam == SIZE_MINIMIZED) return 0;

            if (getApp(hwnd)) |app| {
                // Device/D2D/swapchain creation in WM_APP_DEVICE_LOST_RECOVER
                // can pump messages and reenter WM_SIZE on this same UI
                // thread while that handler still holds app.mu — blocking
                // here would self-deadlock. Replay the complete WM_SIZE path
                // after recovery: rebuilding the swapchain from GetClientRect
                // fixes GPU size, but does not resend rows/cols to Neovim.
                if (app.device_lost_recovering or
                    app.main_resize_in_progress or
                    app.main_dpi_change_in_progress or
                    app.wm_paint_in_progress or
                    app.in_present_shader_animation_frame or
                    app.glow_prepare_in_progress or
                    app.external_window_create_in_progress)
                {
                    app.main_size_replay_needed = true;
                    if (app.device_lost_recovering) scheduleMainSizeReplay(hwnd, app);
                    return 0;
                }
                app.main_resize_in_progress = true;
                defer {
                    app.main_resize_in_progress = false;
                    _ = app.finishActiveOperation();
                }
                _ = c.KillTimer(hwnd, app_mod.TIMER_MAIN_SIZE_REPLAY);
                app.main_size_replay_needed = false;
                // 1) GPU state transition must not race with WM_PAINT (which holds app.mu).
                app.mu.lockUncancelable(core.clock.io());
                app.last_resize_ns = core.clock.nowNs();
                app.need_full_seed.store(true, .seq_cst);
                app.seed_pending = true;
                app.seed_clear_pending = true;
                app.row_valid_count = 0;
                if (app.row_valid.bit_length != 0) {
                    app.row_valid.unsetAll();
                }
                app.last_cursor_rect_px = null;
                // Always keep rows/cols in sync with current client size on resize.
                updateRowsColsFromClientForce(hwnd, app);
                app.mu.unlock(core.clock.io());

                // Resize drops the grid's transforms wholesale: undrained
                // b_ease records and retained ledger rows were accounted
                // against the pre-resize row geometry. Clear both alongside the full-seed reset
                // above. UI thread, so the lock-free ledger clear is safe.
                app.tbs.clearBEaseCommits();
                app.tbs.clearRetention();
                // The forced zeroing of active px offsets must, like natural
                // spring settling, still produce exactly one final recompose
                // frame before the blit path resumes.
                if (app.b_offset_ledger.dropAll()) app.b_forced_zero_pending = true;

                var rc: c.RECT = undefined;
                _ = c.GetClientRect(hwnd, &rc);

                if (applog.isEnabled()) {
                    applog.appLog(
                        "[win] WM_SIZE wParam={d} client=({d},{d})-({d},{d}) need_full_seed=1 atlas={s} gpu={s} resize_ns={d}\n",
                        .{
                            @as(u32, @intCast(wParam)),
                            rc.left,
                            rc.top,
                            rc.right,
                            rc.bottom,
                            if (app.atlas != null) "Y" else "N",
                            if (app.renderer != null) "Y" else "N",
                            app.last_resize_ns,
                        },
                    );
                }

                // 2) core layout update must be outside lock (can re-enter via callbacks).
                // Snapshot window_shown once (atomic) to avoid the TOCTOU race
                // where the RPC thread's onFlushEnd flips it between our two reads.
                const shown = app.window_shown.load(.acquire);
                if (shown) {
                    updateLayoutToCore(hwnd, app);
                }

                // Unblock RPC thread once layout is known (before window is shown).
                // Guard: app.atlas must be set (done in WM_APP_DEFERRED_INIT) before
                // unblocking. WM_SIZE fires synchronously during CreateWindowExW right
                // after WM_CREATE, at which point early_atlas exists but app.atlas is
                // still null. If we unblock here, onGuiFont fires with a null atlas and
                // the configured font is silently dropped. WM_APP_DEFERRED_INIT sets
                // app.atlas first and then calls notify_layout_ready; this WM_SIZE path
                // only matters for subsequent WM_SIZE events that arrive with updated
                // dimensions before the window is shown.
                if (app.early_core_init_done and app.nvim_spawned and !shown and app.atlas != null) {
                    if (app.corep) |corep| {
                        if (app.surface.rows > 0 and app.surface.cols > 0) {
                            core.zonvie_core_notify_layout_ready(corep, app.surface.rows, app.surface.cols);
                        }
                    }
                }

                // 3) Resize tabline child window if present
                if (app.tabline_state.hwnd) |tabline_hwnd| {
                    // Use HWND_TOP to ensure tabline stays above content_hwnd
                    // (some environments may have Z-order issues with SWP_NOZORDER)
                    _ = c.SetWindowPos(
                        tabline_hwnd,
                        c.HWND_TOP,
                        0,
                        0,
                        rc.right,
                        app.scalePx(TablineState.TAB_BAR_HEIGHT),
                        0, // No SWP_NOZORDER - explicitly set Z-order
                    );
                }

                // 4) Trigger D3D11 resize
                // IMPORTANT: Do NOT hold app.mu during g.resize().
                // DXGI ResizeBuffers (FLIP model) can pump Win32 messages internally.
                // If a pending WM_PAINT is dispatched re-entrantly, it tries app.mu.lock()
                // on the same thread -> self-deadlock (SRWLOCK is non-reentrant).
                {
                    var gpu_ptr: ?*d3d11.Renderer = null;
                    app.mu.lockUncancelable(core.clock.io());
                    if (app.renderer) |*g| gpu_ptr = g;
                    app.mu.unlock(core.clock.io());

                    if (gpu_ptr) |g| {
                        g.resize() catch {};
                        // renderer.resize() short-circuits when client size is unchanged
                        // (e.g. minimize/restore), leaving has_presented_once true; only
                        // an actual dimension change resets it. Mirror that decision into
                        // back_tex_valid so preserve_back keeps the buffer across no-op
                        // resizes but forces a clear when the swapchain was rebuilt.
                        if (!g.has_presented_once) {
                            app.mu.lockUncancelable(core.clock.io());
                            app.back_tex_valid = false;
                            app.mu.unlock(core.clock.io());
                        }
                    }
                }
                {
                    app.mu.lockUncancelable(core.clock.io());
                    app.surface.paint_full = true;
                    app.paint_rects.clearRetainingCapacity();
                    app.mu.unlock(core.clock.io());
                }

                // 5) repaint
                _ = c.InvalidateRect(hwnd, null, 0);
            }
            return 0;
        },

        c.WM_ENTERSIZEMOVE => {
            if (getApp(hwnd)) |app| {
                app.b_in_size_move = true;
                app.tbs.clearBEaseCommits();
                app.tbs.clearRetention();
                if (app.b_offset_ledger.dropAll()) app.b_forced_zero_pending = true;
            }
            return 0;
        },

        c.WM_EXITSIZEMOVE => {
            if (getApp(hwnd)) |app| app.b_in_size_move = false;
            return 0;
        },

        c.WM_MOVE => {
            // Reposition ext-float and mini windows when main window moves.
            // Use a coalescing timer to avoid flooding the message queue
            // during window drag (SetTimer resets if the same ID is pending).
            _ = c.SetTimer(hwnd, TIMER_REPOSITION_FLOATS, 15, null);
            return 0;
        },

        WM_APP_ATLAS_ENSURE_GLYPH => {
            if (getApp(hwnd)) |app| {
                const scalar: u32 = @intCast(wParam);

                // lParam is signed (isize). Preserve bits when converting to pointer.
                const out_entry_ptr_bits: usize = @as(usize, @bitCast(lParam));
                const out_entry: *core.GlyphEntry = @ptrFromInt(out_entry_ptr_bits);

                // This handler is always executed on UI thread.
                // Do NOT take app.mu here: SendMessageW can re-enter while WM_PAINT holds app.mu.
                if (app.atlas) |*a| {
                    const e = a.atlasEnsureGlyphEntry(scalar) catch |err| {
                        if (applog.isEnabled()) applog.appLog("WM_APP_ATLAS_ENSURE_GLYPH: atlasEnsureGlyphEntry ERROR: {any}", .{err});
                        return 0;
                    };
                    out_entry.* = e;

                    if (applog.isEnabled()) applog.appLog("WM_APP_ATLAS_ENSURE_GLYPH: ok scalar={d} out_entry_ptr=0x{x} uv_min=({d:.6},{d:.6}) uv_max=({d:.6},{d:.6})", .{
                        scalar,
                        out_entry_ptr_bits,
                        e.uv_min[0],
                        e.uv_min[1],
                        e.uv_max[0],
                        e.uv_max[1],
                    });

                    return 1;
                }

                if (applog.isEnabled()) applog.appLog("WM_APP_ATLAS_ENSURE_GLYPH: renderer is null", .{});
                return 0;
            }
            return 0;
        },

        WM_APP_CREATE_EXTERNAL_WINDOW => {
            if (applog.isEnabled()) applog.appLog("[win] WM_APP_CREATE_EXTERNAL_WINDOW received\n", .{});
            if (getApp(hwnd)) |app| {
                if (app.main_resize_in_progress or app.main_dpi_change_in_progress) {
                    // ResizeBuffers may have pumped this create message. Keep
                    // the retained request and let the UI-loop deadline driver
                    // retry after the swapchain transition finishes.
                    app.external_create_retry_needed = true;
                    return 0;
                }
                // Update external window colors (border/icon) before creating windows
                // This ensures colors are available for popupmenu even if cmdline wasn't shown
                external_windows.updateExternalWindowColors(app);

                // Find the single pending request whose seq matches the one
                // posted in lParam. Each onExternalWindow enqueue posts
                // one message tagged with the request's seq, so messages
                // bind 1:1 to specific requests — even if the request was
                // later coalesced (same grid_id, fields replaced, seq kept)
                // or removed (e.g., dropped from a previous session by
                // onExternalWindowClose), the lookup remains unambiguous.
                //
                // Skip if the matching entry's grid_id is currently held
                // by an is_pending_close entry in external_windows (close
                // received but deferred because paint was in progress).
                // Creating now would put() over the old entry while paint
                // still references it, leaking the old HWND. Leave the
                // request in the queue; closeExternalWindowOnUIThread re-
                // posts WM_APP_CREATE with the same seq after the destroy
                // completes, and the next pass will find the slot free.
                const msg_seq: u64 = @bitCast(lParam);
                app.mu.lockUncancelable(core.clock.io());
                if (app.external_window_create_in_progress) {
                    // HWND/D3D creation can pump another create message. Keep
                    // all requests queued and let the outer handler wake them
                    // after it has published or cancelled its own window.
                    app.mu.unlock(core.clock.io());
                    return 0;
                }
                var create_idx: ?usize = null;
                var update_existing = false;
                for (app.pending_external_windows.items, 0..) |item, i| {
                    if (item.seq != msg_seq) continue;
                    if (item.create_in_progress) {
                        app.mu.unlock(core.clock.io());
                        return 0;
                    }
                    const blocked = if (app.external_windows.get(item.grid_id)) |e| blk: {
                        update_existing = !e.is_pending_close;
                        break :blk e.is_pending_close;
                    } else false;
                    if (blocked) {
                        // Matching entry exists but is blocked — leave
                        // it; the deferred close will re-post a wake.
                        app.mu.unlock(core.clock.io());
                        return 0;
                    }
                    create_idx = i;
                    break;
                }
                if (create_idx == null) {
                    // No matching pending entry. Either the request was
                    // removed by onExternalWindowClose (old session) or
                    // consumed after a successful earlier same-seq wake.
                    // Either way, this is a no-op.
                    app.mu.unlock(core.clock.io());
                    return 0;
                }
                // Keep the request in its retained-capacity queue slot until
                // HWND, D3D renderer, heap box, and map publication all
                // succeed. Fallible UI-thread creation can then retry without
                // asking the already-known core grid to emit another callback.
                app.pending_external_windows.items[create_idx.?].create_in_progress = true;
                const req = app.pending_external_windows.items[create_idx.?];
                app.external_window_create_in_progress = true;
                app.mu.unlock(core.clock.io());

                const create_result: external_windows.ExternalWindowCreateResult = if (update_existing)
                    (if (external_windows.updateExternalWindowGeometryOnUIThread(app, req)) .obsolete else .retry)
                else
                    external_windows.createExternalWindowOnUIThread(app, req);

                app.mu.lockUncancelable(core.clock.io());
                var delay_retry = false;
                var close_published_window = false;
                for (app.pending_external_windows.items, 0..) |item, i| {
                    if (item.seq != msg_seq) continue;
                    if (item.cancel_requested) {
                        close_published_window = create_result == .published;
                        _ = app.pending_external_windows.orderedRemove(i);
                        break;
                    }
                    switch (create_result) {
                        .published => {
                            if (item.update_revision != req.update_revision) {
                                // An updater that was already waiting on app.mu
                                // can run immediately after map publication.
                                // Preserve its latest request; the next pass
                                // updates this HWND in place without discarding
                                // the surface vertices just published with it.
                                app.pending_external_windows.items[i].create_in_progress = false;
                            } else {
                                _ = app.pending_external_windows.orderedRemove(i);
                            }
                        },
                        .obsolete => {
                            if (item.update_revision != req.update_revision) {
                                app.pending_external_windows.items[i].create_in_progress = false;
                            } else {
                                _ = app.pending_external_windows.orderedRemove(i);
                            }
                        },
                        .retry => {
                            app.pending_external_windows.items[i].create_in_progress = false;
                            delay_retry = true;
                        },
                    }
                    break;
                }
                app.mu.unlock(core.clock.io());

                if (close_published_window) {
                    external_windows.closeExternalWindowOnUIThread(app, req.grid_id);
                }

                app.mu.lockUncancelable(core.clock.io());
                app.external_window_create_in_progress = false;
                const destroy_pending = app.pending_destroy_after_active_operation;
                const wake_pending = !destroy_pending and app.pending_external_windows.items.len != 0;
                app.mu.unlock(core.clock.io());

                if (wake_pending) {
                    if (delay_retry) {
                        external_windows.retryPendingExternalWindowCreates(app);
                    } else {
                        external_windows.wakePendingExternalWindowCreates(app);
                    }
                }
                external_windows.resetExternalCreateRetryIfIdle(app);
                _ = app.finishActiveOperation();
            }
            return 0;
        },

        WM_APP_CURSOR_GRID_CHANGED => {
            if (applog.isEnabled()) applog.appLog("[win] WM_APP_CURSOR_GRID_CHANGED received grid_id={d}\n", .{wParam});
            if (getApp(hwnd)) |app| {
                const grid_id: i64 = @bitCast(wParam);

                // app.last_cursor_grid is already updated synchronously by
                // onCursorGridChanged (the core callback), so we only fetch
                // ext_hwnd here. The core fires this callback only when the
                // cursor grid actually changes, so no is_grid_change guard
                // is needed in the UI handler.
                app.mu.lockUncancelable(core.clock.io());
                const ext_hwnd = if (app.external_windows.get(grid_id)) |ext_win| ext_win.hwnd else null;
                app.mu.unlock(core.clock.io());

                if (ext_hwnd) |eh| {
                    // Cursor moved to external grid - activate that window
                    _ = c.SetForegroundWindow(eh);
                    if (applog.isEnabled()) applog.appLog("[win] activated external window for grid_id={d}\n", .{grid_id});
                } else if (grid_id == CMDLINE_GRID_ID or grid_id == POPUPMENU_GRID_ID or grid_id == MESSAGE_GRID_ID or grid_id == MSG_HISTORY_GRID_ID) {
                    // Cursor moved onto a synthetic decorated grid (cmdline /
                    // popupmenu / message) whose host window has not been
                    // created yet: its WM_APP_CREATE_EXTERNAL_WINDOW is still
                    // behind us in the UI queue and the window (WS_EX_TOPMOST,
                    // shown with SW_SHOWNA) surfaces itself on creation.
                    // Activating the main window here would yank it in front of
                    // a focused float while the cmdline is shown.
                    if (applog.isEnabled()) applog.appLog("[win] special grid {d} not yet registered; skip main activation\n", .{grid_id});
                } else {
                    // Cursor moved to global grid - activate main window
                    _ = c.SetForegroundWindow(hwnd);
                    // Only invalidate if no paint is already pending from on_vertices_row/partial.
                    // When dirty_rows, paint_full, or paint_rects is set, the pending WM_PAINT
                    // will handle cursor rendering as part of the normal draw.
                    app.mu.lockUncancelable(core.clock.io());
                    const has_pending = app.paint_rects.items.len > 0;
                    app.mu.unlock(core.clock.io());
                    if (!has_pending) {
                        _ = c.InvalidateRect(hwnd, null, c.FALSE);
                    }
                    if (applog.isEnabled()) applog.appLog("[win] activated main window (cursor on grid_id={d}) pending={}\n", .{ grid_id, has_pending });
                }
            }
            return 0;
        },

        WM_APP_CLOSE_EXTERNAL_WINDOW => {
            const grid_id: i64 = @bitCast(wParam);
            if (applog.isEnabled()) applog.appLog("[win] WM_APP_CLOSE_EXTERNAL_WINDOW received grid_id={d}\n", .{grid_id});
            if (getApp(hwnd)) |app| {
                external_windows.closeExternalWindowOnUIThread(app, grid_id);
            }
            return 0;
        },

        WM_APP_MSG_SHOW => {
            if (applog.isEnabled()) applog.appLog("[win] WM_APP_MSG_SHOW received\n", .{});
            if (getApp(hwnd)) |app| {
                // Process all pending messages
                app.mu.lockUncancelable(core.clock.io());
                var pending = app.pending_messages;
                app.pending_messages = .empty;
                app.mu.unlock(core.clock.io());
                defer pending.deinit(app.alloc);

                // Process each pending message individually based on its view_type
                for (pending.items) |req| {
                    const kind_str = req.kind[0..req.kind_len];

                    // Build DisplayMessage for this request
                    var dm = DisplayMessage{};
                    @memcpy(dm.text[0..req.text_len], req.text[0..req.text_len]);
                    dm.text_len = req.text_len;
                    @memcpy(dm.kind[0..req.kind_len], req.kind[0..req.kind_len]);
                    dm.kind_len = req.kind_len;
                    dm.hl_id = req.hl_id;
                    dm.view_type = req.view_type;
                    dm.timeout = req.timeout;

                    // Process based on view_type (each message is routed individually)
                    switch (req.view_type) {
                        .mini => {
                            // Show in mini window
                            const text = dm.text[0..dm.text_len];
                            messages.updateMiniText(app, .showmode, text);
                            messages.updateMiniWindows(app);

                            // Set auto-hide timer based on timeout (use separate timer for mini)
                            _ = c.KillTimer(hwnd, TIMER_MINI_AUTOHIDE);
                            const timeout_ms = messageTimerMilliseconds(dm.timeout);
                            if (timeout_ms > 0) {
                                _ = c.SetTimer(hwnd, TIMER_MINI_AUTOHIDE, timeout_ms, null);
                            }
                        },
                        .confirm => {
                            // Confirm messages: clear display stack and show
                            if (req.replace_last != 0 or std.mem.eql(u8, kind_str, "return_prompt")) {
                                app.display_messages.clearRetainingCapacity();
                            }
                            var append_failed = false;
                            app.display_messages.append(app.alloc, dm) catch {
                                append_failed = true;
                            };
                            messages.showMessageWindowOnUIThread(app, dm, append_failed);
                            // Confirm dialogs don't auto-hide (only kill message window timer, not mini)
                            _ = c.KillTimer(hwnd, TIMER_MSG_AUTOHIDE);
                        },
                        .ext_float => {
                            // Floating window: add to display stack
                            if (req.replace_last != 0) {
                                app.display_messages.clearRetainingCapacity();
                            }
                            if (req.append != 0 and app.display_messages.items.len > 0) {
                                var last = &app.display_messages.items[app.display_messages.items.len - 1];
                                const append_len = @min(req.text_len, last.text.len - last.text_len);
                                @memcpy(last.text[last.text_len..][0..append_len], req.text[0..append_len]);
                                last.text_len += append_len;
                                messages.showMessageWindowOnUIThread(app, dm, false);
                            } else {
                                var append_failed = false;
                                app.display_messages.append(app.alloc, dm) catch {
                                    append_failed = true;
                                };
                                if (app.display_messages.items.len > 5) {
                                    _ = app.display_messages.orderedRemove(0);
                                }
                                messages.showMessageWindowOnUIThread(app, dm, append_failed);
                            }
                            _ = c.KillTimer(hwnd, TIMER_MSG_AUTOHIDE);
                            const timeout_ms = messageTimerMilliseconds(dm.timeout);
                            if (timeout_ms > 0) {
                                _ = c.SetTimer(hwnd, TIMER_MSG_AUTOHIDE, timeout_ms, null);
                            }
                        },
                        .split => {
                            messages.showMessageWindowOnUIThread(app, dm, true);
                            _ = c.KillTimer(hwnd, TIMER_MSG_AUTOHIDE);
                        },
                        .notification => {
                            // TODO: Show OS notification
                        },
                        .none => {},
                    }
                }
            }
            return 0;
        },

        WM_APP_MSG_CLEAR => {
            if (applog.isEnabled()) applog.appLog("[win] WM_APP_MSG_CLEAR received\n", .{});
            if (getApp(hwnd)) |app| {
                // Kill auto-hide timer
                _ = c.KillTimer(hwnd, TIMER_MSG_AUTOHIDE);
                messages.hideMessageWindow(app);
                // Note: Do NOT hide split view on msg_clear.
                // Split view should remain visible until user manually closes it (Esc/q/Enter/Space).
                // This matches noice.nvim's long_message_to_split behavior.
            }
            return 0;
        },

        WM_APP_MINI_UPDATE => {
            const mini_id: MiniWindowId = @enumFromInt(@as(u2, @truncate(wParam)));
            if (applog.isEnabled()) applog.appLog("[win] WM_APP_MINI_UPDATE received: {s}\n", .{@tagName(mini_id)});
            if (getApp(hwnd)) |app| {
                messages.updateMiniWindows(app);
            }
            return 0;
        },

        WM_APP_UPDATE_EXT_FLOAT_POS => {
            if (applog.isEnabled()) applog.appLog("[win] WM_APP_UPDATE_EXT_FLOAT_POS received\n", .{});
            if (getApp(hwnd)) |app| {
                messages.updateExtFloatPositions(app);
            }
            return 0;
        },

        WM_APP_RESIZE_POPUPMENU => {
            const grid_id: i64 = @bitCast(wParam);
            if (applog.isEnabled()) applog.appLog("[win] WM_APP_RESIZE_POPUPMENU received grid_id={d}\n", .{grid_id});
            if (getApp(hwnd)) |app| {
                messages.resizeExternalWindowDeferred(app, grid_id);
            }
            return 0;
        },

        WM_APP_CLIPBOARD_GET => {
            if (applog.isEnabled()) applog.appLog("[win] WM_APP_CLIPBOARD_GET received\n", .{});
            if (getApp(hwnd)) |app| {
                dialogs.handleClipboardGetOnUIThread(app);
            }
            return 0;
        },

        WM_APP_CLIPBOARD_SET => {
            if (applog.isEnabled()) applog.appLog("[win] WM_APP_CLIPBOARD_SET received\n", .{});
            if (getApp(hwnd)) |app| {
                dialogs.handleClipboardSetOnUIThread(app);
            }
            return 0;
        },

        WM_APP_SSH_AUTH_PROMPT => {
            if (applog.isEnabled()) applog.appLog("[win] WM_APP_SSH_AUTH_PROMPT received\n", .{});
            if (getApp(hwnd)) |app| {
                dialogs.handleSSHAuthPromptOnUIThread(app);
            }
            return 0;
        },

        WM_APP_UPDATE_CURSOR_BLINK => {
            if (getApp(hwnd)) |app| {
                input.updateCursorBlinking(hwnd, app);
            }
            return 0;
        },

        WM_APP_IME_OFF => {
            input.setIMEOff(hwnd);
            return 0;
        },

        WM_APP_TRAY => {
            // Notification-area icon interaction (close_to_tray). With the
            // default tray version (no NIM_SETVERSION), lParam's low word holds
            // the mouse message. Left click / double-click restores the window;
            // right click opens the Open/Quit context menu.
            if (getApp(hwnd)) |app| {
                const event = @as(u32, @as(u16, @truncate(@as(usize, @bitCast(lParam)))));
                switch (event) {
                    c.WM_LBUTTONUP, c.WM_LBUTTONDBLCLK => restoreFromTray(hwnd),
                    c.WM_RBUTTONUP => showTrayMenu(hwnd, app),
                    else => {},
                }
            }
            return 0;
        },

        WM_APP_QUIT_REQUESTED => {
            const has_unsaved: c_int = @intCast(wParam);
            if (applog.isEnabled()) applog.appLog("[win] WM_APP_QUIT_REQUESTED: has_unsaved={d}\n", .{has_unsaved});

            // Ignore delayed response if timeout already fired and user chose to wait
            if (getApp(hwnd)) |app| {
                if (app.quit_timeout_fired) {
                    if (applog.isEnabled()) applog.appLog("[win] WM_APP_QUIT_REQUESTED: ignoring - timeout already fired\n", .{});
                    return 0;
                }
            }

            // Cancel timeout timer - Neovim responded in time
            _ = c.KillTimer(hwnd, TIMER_QUIT_TIMEOUT);
            if (getApp(hwnd)) |app| {
                app.quit_pending = false;
            }

            if (has_unsaved != 0) {
                // Show confirmation dialog
                // Note: MessageBox doesn't support custom button text.
                // Using MB_OKCANCEL so "Cancel" matches macOS. "OK" means "Discard and Quit".
                const dialog_msg = std.unicode.utf8ToUtf16LeStringLiteral("You have unsaved changes. Do you want to discard them and quit?");
                const dialog_title = std.unicode.utf8ToUtf16LeStringLiteral("Unsaved Changes");
                const result = c.MessageBoxW(
                    hwnd,
                    dialog_msg,
                    dialog_title,
                    c.MB_OKCANCEL | c.MB_ICONWARNING | c.MB_DEFBUTTON2,
                );

                if (result == c.IDOK) {
                    // User confirmed - force quit
                    if (getApp(hwnd)) |app| {
                        if (app.corep) |corep| {
                            core.zonvie_core_quit_confirmed(corep, 1);
                        }
                    }
                }
                // Cancel - do nothing
            } else {
                // No unsaved buffers - proceed with :qa
                if (getApp(hwnd)) |app| {
                    if (app.corep) |corep| {
                        core.zonvie_core_quit_confirmed(corep, 0);
                    }
                }
            }
            return 0;
        },

        WM_APP_QUIT_TIMEOUT => {
            // Neovim not responding - show force quit dialog
            // Note: quit_timeout_fired was already set in WM_TIMER before posting this message
            if (applog.isEnabled()) applog.appLog("[win] WM_APP_QUIT_TIMEOUT: showing not responding dialog\n", .{});

            const dialog_msg = std.unicode.utf8ToUtf16LeStringLiteral("Neovim is not responding. Do you want to force quit?");
            const dialog_title = std.unicode.utf8ToUtf16LeStringLiteral("Neovim Not Responding");
            const result = c.MessageBoxW(
                hwnd,
                dialog_msg,
                dialog_title,
                c.MB_OKCANCEL | c.MB_ICONERROR | c.MB_DEFBUTTON1,
            );

            if (result == c.IDOK) {
                // Force quit - terminate the app
                if (applog.isEnabled()) applog.appLog("[win] WM_APP_QUIT_TIMEOUT: user chose Force Quit\n", .{});
                _ = c.DestroyWindow(hwnd);
            }
            // Cancel/Wait - do nothing, user can try again later
            return 0;
        },

        WM_APP_TABLINE_INVALIDATE => {
            if (getApp(hwnd)) |app| {
                // Start/stop the agent spinner animation timer to match whether
                // any tab is currently working (idle/none need no animation).
                const working = blk: {
                    if (!app.config.tabline.agent_indicator) break :blk false;
                    app.mu.lockUncancelable(core.clock.io());
                    defer app.mu.unlock(core.clock.io());
                    break :blk app.tabline_state.anyAgentWorking();
                };
                if (working and !app.tabline_state.spinner_timer_active) {
                    _ = c.SetTimer(hwnd, app_mod.TIMER_AGENT_SPINNER, app_mod.AGENT_SPINNER_INTERVAL_MS, null);
                    app.tabline_state.spinner_timer_active = true;
                } else if (!working and app.tabline_state.spinner_timer_active) {
                    _ = c.KillTimer(hwnd, app_mod.TIMER_AGENT_SPINNER);
                    app.tabline_state.spinner_timer_active = false;
                }
                // Drain queued agent completions into a per-tab OS notification.
                // Always notify (window-level focus suppression doesn't fit
                // running the agent inside zonvie's own terminal). Keep the queue
                // if the tray isn't ready yet (startup race).
                const n_completed = blk: {
                    app.mu.lockUncancelable(core.clock.io());
                    defer app.mu.unlock(core.clock.io());
                    break :blk app.tabline_state.agent_completed_count;
                };
                if (n_completed > 0) {
                    if (app.tray_icon) |*tray| {
                        var msg_buf: [320]u8 = undefined;
                        var bmsg: []const u8 = "AI agent finished";
                        {
                            app.mu.lockUncancelable(core.clock.io());
                            defer app.mu.unlock(core.clock.io());
                            if (app.tabline_state.agent_completed_count == 1) {
                                const tlen = app.tabline_state.agent_completed_title_lens[0];
                                const summary = if (tlen > 0)
                                    app.tabline_state.agent_completed_titles[0][0..tlen]
                                else
                                    app.tabline_state.tabName(app.tabline_state.agent_completed[0]);
                                const waiting = app.tabline_state.agent_completed_waiting[0];
                                const label = if (waiting) "Needs input" else "Finished";
                                const fallback = if (waiting) "AI agent needs input" else "AI agent finished";
                                if (summary.len > 0) {
                                    bmsg = std.fmt.bufPrint(&msg_buf, "{s}: {s}", .{ label, summary }) catch fallback;
                                } else {
                                    bmsg = fallback;
                                }
                            } else {
                                // Multiple completions drained together: some may be
                                // "waiting for input" rather than finished. Count them
                                // so the message doesn't falsely claim work is done.
                                const total = app.tabline_state.agent_completed_count;
                                var waiting_n: usize = 0;
                                var wi: usize = 0;
                                while (wi < total) : (wi += 1) {
                                    if (app.tabline_state.agent_completed_waiting[wi]) waiting_n += 1;
                                }
                                if (waiting_n == total) {
                                    bmsg = std.fmt.bufPrint(&msg_buf, "{d} AI agents need input", .{total}) catch "AI agents need input";
                                } else if (waiting_n > 0) {
                                    bmsg = std.fmt.bufPrint(&msg_buf, "{d} finished, {d} need input", .{ total - waiting_n, waiting_n }) catch "AI agents finished";
                                } else {
                                    bmsg = std.fmt.bufPrint(&msg_buf, "{d} AI agents finished", .{total}) catch "AI agents finished";
                                }
                            }
                            app.tabline_state.agent_completed_count = 0;
                        }
                        tray.showBalloon("Zonvie", bmsg);
                    }
                    // else: tray not ready — keep the queue for a later drain.
                }
                // Tabline is rendered as D3D11 texture via renderTablineToD3D
                // Invalidate main window to trigger WM_PAINT which calls renderTablineToD3D
                _ = c.InvalidateRect(hwnd, null, 0);
                // Force immediate repaint so tabline updates without waiting for next message
                _ = c.UpdateWindow(hwnd);
            }
            return 0;
        },

        WM_APP_UPDATE_CMDLINE_COLORS => {
            // Update cmdline border/icon colors from core highlights.
            // Called from UI thread (via PostMessage from onCmdlineShow) to avoid
            // deadlock when calling zonvie_core_get_hl_by_name from callback context.
            if (getApp(hwnd)) |app| {
                app.external_colors_update_pending.store(false, .release);
                external_windows.updateExternalWindowColors(app);
            }
            return 0;
        },

        WM_APP_SET_TITLE => {
            // Deferred SetWindowTextW from onSetTitle callback.
            // SetWindowTextW from the core thread would be an implicit cross-thread
            // SendMessage(WM_SETTEXT), blocking with grid_mu held → deadlock.
            if (getApp(hwnd)) |app| {
                var local_buf: [512]u16 = undefined;
                app.mu.lockUncancelable(core.clock.io());
                const len = app.pending_title_len;
                if (len > 0) {
                    @memcpy(local_buf[0..len], app.pending_title[0..len]);
                }
                app.mu.unlock(core.clock.io());
                if (len > 0) {
                    local_buf[len] = 0; // null terminate
                    _ = c.SetWindowTextW(hwnd, &local_buf);
                }
            }
            return 0;
        },

        WM_APP_SNAP_MAIN_WINDOW => {
            // Snap the main window's client rect down to a multiple of the
            // current cell size in both axes. Posted from the RPC thread by
            // onGuiFont/onLineSpace after cell metrics change. The actual
            // SetWindowPos must run on the UI thread because it triggers a
            // synchronous WM_SIZE → updateLayoutToCore → grid_mu, which
            // would deadlock if invoked from the RPC thread (which already
            // holds grid_mu via handleRedraw).
            //
            // No-op when the remainder is already zero on both axes, so
            // this does not interfere with steady-state user resizes.
            if (getApp(hwnd)) |app| {
                var client_rc: c.RECT = undefined;
                var window_rc: c.RECT = undefined;
                if (c.GetClientRect(hwnd, &client_rc) == 0) return 0;
                if (c.GetWindowRect(hwnd, &window_rc) == 0) return 0;

                app.mu.lockUncancelable(core.clock.io());
                const cell_w: u32 = app.cell_w_px;
                const cell_h: u32 = app.cell_h_px + app.linespace_px;
                app.mu.unlock(core.clock.io());
                if (cell_w == 0 or cell_h == 0) return 0;

                const client_w_i: i32 = client_rc.right - client_rc.left;
                const client_h_i: i32 = client_rc.bottom - client_rc.top;
                if (client_w_i <= 0 or client_h_i <= 0) return 0;
                const client_w: u32 = @intCast(client_w_i);
                const client_h: u32 = @intCast(client_h_i);

                const snapped_w: u32 = (client_w / cell_w) * cell_w;
                const snapped_h: u32 = (client_h / cell_h) * cell_h;
                if (snapped_w == 0 or snapped_h == 0) return 0;
                if (snapped_w == client_w and snapped_h == client_h) return 0;

                // Frame delta = outer - client. AdjustWindowRectEx is not
                // reliable here because the window may use a custom NCCALCSIZE
                // (DWM titlebar mode), so derive the delta from the live rects.
                const outer_w: i32 = window_rc.right - window_rc.left;
                const outer_h: i32 = window_rc.bottom - window_rc.top;
                const frame_dw: i32 = outer_w - client_w_i;
                const frame_dh: i32 = outer_h - client_h_i;
                const new_outer_w: c_int = @as(c_int, @intCast(snapped_w)) + frame_dw;
                const new_outer_h: c_int = @as(c_int, @intCast(snapped_h)) + frame_dh;

                if (applog.isEnabled()) applog.appLog(
                    "[win] WM_APP_SNAP_MAIN_WINDOW: client=({d},{d}) -> ({d},{d}) cell=({d},{d}) outer=({d},{d})\n",
                    .{ client_w, client_h, snapped_w, snapped_h, cell_w, cell_h, new_outer_w, new_outer_h },
                );
                _ = c.SetWindowPos(
                    hwnd,
                    null,
                    0,
                    0,
                    new_outer_w,
                    new_outer_h,
                    c.SWP_NOZORDER | c.SWP_NOMOVE | c.SWP_NOACTIVATE,
                );
            }
            return 0;
        },

        app_mod.WM_APP_RESIZE_TO_GRID => {
            // Neovim resized the global grid itself (`:set columns=` /
            // `:set lines=`). Grow/shrink the main window by the delta between
            // the current terminal content area and the requested cell grid,
            // so sidebar/tabbar/scrollbar chrome keeps its size.
            // wParam = rows, lParam = cols.
            if (getApp(hwnd)) |app| {
                const rows: u32 = @intCast(wParam);
                const cols: u32 = @intCast(lParam);
                if (rows == 0 or cols == 0) return 0;

                var window_rc: c.RECT = undefined;
                if (c.GetWindowRect(hwnd, &window_rc) == 0) return 0;

                app.mu.lockUncancelable(core.clock.io());
                const cell_w: u32 = app.cell_w_px;
                const cell_h: u32 = app.cell_h_px + app.linespace_px;
                app.mu.unlock(core.clock.io());
                if (cell_w == 0 or cell_h == 0) return 0;

                const content = app_mod.contentSizePx(hwnd, app);
                const dw: i32 = @as(i32, @intCast(cols * cell_w)) - @as(i32, @intCast(content.w));
                const dh: i32 = @as(i32, @intCast(rows * cell_h)) - @as(i32, @intCast(content.h));
                if (dw == 0 and dh == 0) return 0;

                const new_outer_w: c_int = (window_rc.right - window_rc.left) + dw;
                const new_outer_h: c_int = (window_rc.bottom - window_rc.top) + dh;
                if (new_outer_w <= 0 or new_outer_h <= 0) return 0;

                if (applog.isEnabled()) applog.appLog(
                    "[win] WM_APP_RESIZE_TO_GRID: rows={d} cols={d} content=({d},{d}) delta=({d},{d}) outer=({d},{d})\n",
                    .{ rows, cols, content.w, content.h, dw, dh, new_outer_w, new_outer_h },
                );
                _ = c.SetWindowPos(
                    hwnd,
                    null,
                    0,
                    0,
                    new_outer_w,
                    new_outer_h,
                    c.SWP_NOZORDER | c.SWP_NOMOVE | c.SWP_NOACTIVATE,
                );
            }
            return 0;
        },

        WM_APP_DEFERRED_WIN_POS => {
            // Deferred SetWindowPos from onWinResizeEqual/onWinRotate callbacks.
            // SetWindowPos from the core thread sends WM_SIZE to the UI thread,
            // which calls updateLayoutToCore → grid_mu.lock() → deadlock.
            if (getApp(hwnd)) |app| {
                var local_ops: [App.MAX_DEFERRED_WIN_OPS]App.DeferredWinOp = undefined;
                var count: usize = 0;
                app.mu.lockUncancelable(core.clock.io());
                count = @min(app.deferred_win_ops_count, App.MAX_DEFERRED_WIN_OPS);
                if (count > 0) {
                    @memcpy(local_ops[0..count], app.deferred_win_ops[0..count]);
                    app.deferred_win_ops_count = 0;
                }
                app.mu.unlock(core.clock.io());
                for (local_ops[0..count]) |op| {
                    _ = c.SetWindowPos(op.hwnd, null, op.x, op.y, op.w, op.h, op.flags);
                }
            }
            return 0;
        },

        c.WM_TIMER => {
            if (wParam == TIMER_MSG_AUTOHIDE) {
                if (applog.isEnabled()) applog.appLog("[win] WM_TIMER: message window auto-hide\n", .{});
                // Kill the timer and hide message window
                _ = c.KillTimer(hwnd, TIMER_MSG_AUTOHIDE);
                if (getApp(hwnd)) |app| {
                    messages.hideMessageWindow(app);
                }
            } else if (wParam == TIMER_MINI_AUTOHIDE) {
                if (applog.isEnabled()) applog.appLog("[win] WM_TIMER: mini window auto-hide\n", .{});
                // Kill the timer and hide mini window (showmode slot)
                _ = c.KillTimer(hwnd, TIMER_MINI_AUTOHIDE);
                if (getApp(hwnd)) |app| {
                    messages.updateMiniText(app, .showmode, "");
                    messages.updateMiniWindows(app);
                }
            } else if (wParam == TIMER_SCROLLBAR_AUTOHIDE) {
                // Start fade-out animation after timeout
                _ = c.KillTimer(hwnd, TIMER_SCROLLBAR_AUTOHIDE);
                if (getApp(hwnd)) |app| {
                    app.scrollbar_hide_timer = 0;
                    scrollbar.hideScrollbar(hwnd, app);
                }
            } else if (wParam == TIMER_SCROLLBAR_FADE) {
                // Update scrollbar fade animation
                if (getApp(hwnd)) |app| {
                    scrollbar.updateScrollbarFade(hwnd, app);
                }
            } else if (wParam == TIMER_SCROLLBAR_REPEAT) {
                // Continuous page scroll while holding mouse on track
                if (getApp(hwnd)) |app| {
                    if (app.scrollbar_repeat_dir != 0) {
                        scrollbar.scrollbarPageScroll(app, app.scrollbar_repeat_dir);
                        // After first delay, switch to faster interval
                        _ = c.KillTimer(hwnd, TIMER_SCROLLBAR_REPEAT);
                        app.scrollbar_repeat_timer = c.SetTimer(hwnd, TIMER_SCROLLBAR_REPEAT, SCROLLBAR_REPEAT_INTERVAL, null);
                    }
                }
            } else if (wParam == TIMER_CURSOR_BLINK) {
                if (applog.isEnabled()) applog.appLog("[win] WM_TIMER: cursor blink\n", .{});
                if (getApp(hwnd)) |app| {
                    input.handleCursorBlinkTimer(hwnd, app);
                }
            } else if (wParam == app_mod.TIMER_CURSOR_BLINK_RETRY) {
                // One-shot retry after a grid_mu-busy cursor-blink read.
                _ = c.KillTimer(hwnd, app_mod.TIMER_CURSOR_BLINK_RETRY);
                if (getApp(hwnd)) |app| {
                    input.updateCursorBlinking(hwnd, app);
                }
            } else if (wParam == app_mod.TIMER_SCROLLBAR_RETRY) {
                // One-shot retry after a scrollbar update only saw a stale
                // cached viewport under grid_mu contention.
                _ = c.KillTimer(hwnd, app_mod.TIMER_SCROLLBAR_RETRY);
                if (getApp(hwnd)) |app| {
                    scrollbar.updateScrollbar(hwnd, app);
                }
            } else if (wParam == app_mod.TIMER_DEVICE_LOST_RETRY) {
                // One-shot retry after a failed device-loss recovery (device
                // creation transiently fails while the driver is resetting).
                _ = c.KillTimer(hwnd, app_mod.TIMER_DEVICE_LOST_RETRY);
                if (getApp(hwnd)) |app| {
                    app.device_lost_retry_needed = false;
                    app.device_lost_retry_deadline_ms = 0;
                    postDeviceLostRecovery(hwnd, app);
                }
            } else if (wParam == app_mod.TIMER_MAIN_SIZE_REPLAY) {
                if (getApp(hwnd)) |app| {
                    if (app.device_lost_recovering) {
                        scheduleMainSizeReplay(hwnd, app);
                    } else {
                        _ = c.KillTimer(hwnd, app_mod.TIMER_MAIN_SIZE_REPLAY);
                        replayMainSize(hwnd, app);
                    }
                } else {
                    _ = c.KillTimer(hwnd, app_mod.TIMER_MAIN_SIZE_REPLAY);
                }
            } else if (wParam == app_mod.TIMER_FLUSH_RETRY) {
                // One-shot retry after an aborted flush (backpressure or
                // frontend OOM). No-op core-side if nothing is pending.
                if (getApp(hwnd)) |app| {
                    // Do NOT kill the timer before the guard. SetTimer is
                    // periodic, so leaving it running is what makes a deferral
                    // recover: the next tick retries until it lands outside a
                    // pumping operation. Killing it here would drop the only
                    // OS wake while flush_retry_wake_armed stays true, so
                    // armFlushRetryWake would early-return forever and the
                    // retry would wait on serviceDeferredUiRetries -- which
                    // runs from main()'s loop, the very loop that is not
                    // turning inside a modal drag. consumeFlushRetryWake kills
                    // the timer itself once it actually services the retry.
                    if (!flushRetryReentrancyBlocked(app)) {
                        consumeFlushRetryWake(hwnd, app);
                    }
                } else {
                    _ = c.KillTimer(hwnd, app_mod.TIMER_FLUSH_RETRY);
                }
            } else if (wParam == app_mod.TIMER_MSG_SCROLL_RETRY) {
                _ = c.KillTimer(hwnd, app_mod.TIMER_MSG_SCROLL_RETRY);
                if (getApp(hwnd)) |app| {
                    if (app.corep) |corep| {
                        if (app_mod.zonvie_core_process_pending_msg_scroll_retry_needed(corep)) {
                            _ = c.SetTimer(hwnd, app_mod.TIMER_MSG_SCROLL_RETRY, app_mod.MSG_SCROLL_RETRY_INTERVAL_MS, null);
                        }
                    }
                }
            } else if (wParam == app_mod.TIMER_SMOOTH_SCROLL_DEADLINE) {
                if (getApp(hwnd)) |app| smooth_session.onDeadline(app);
            } else if (wParam == app_mod.TIMER_MSG_THROTTLE) {
                _ = c.KillTimer(hwnd, app_mod.TIMER_MSG_THROTTLE);
                if (getApp(hwnd)) |app| {
                    if (app.corep) |corep| app_mod.zonvie_core_tick_msg_throttle(corep);
                    armMsgThrottleTimer(hwnd, app);
                }
            } else if (wParam == app_mod.TIMER_AGENT_SPINNER) {
                // Advance the AI-agent spinner frame and repaint only the tabline.
                // Invalidating the whole window would re-present the entire grid at
                // the spinner rate (~8 Hz) even when the content is static; bound
                // the dirty region to the tabline strip instead (matches the hover
                // redraw path).
                if (getApp(hwnd)) |app| {
                    app.tabline_state.spinner_frame +%= 1;
                    var tabline_rect: c.RECT = .{
                        .left = 0,
                        .top = 0,
                        .right = 4096,
                        .bottom = app.scalePx(TablineState.TAB_BAR_HEIGHT),
                    };
                    _ = c.InvalidateRect(hwnd, &tabline_rect, 0);
                }
            } else if (wParam == app_mod.TIMER_CUSTOM_SHADER_ANIM) {
                // Continuous-redraw tick for animated custom shaders.
                // Runs a minimal shader-only present on the UI thread
                // (no row VB draws, no overlays). Using InvalidateRect +
                // full WM_PAINT here stalls input at 60 Hz because each
                // tick re-runs the full row-mode paint path.
                if (getApp(hwnd)) |app| {
                    // Guard against same-thread re-entrancy: a nested
                    // message pump inside DXGI's Present (below) can
                    // dispatch another TIMER_CUSTOM_SHADER_ANIM tick before
                    // this call returns. A re-entrant tick skips the
                    // entire animation-frame tick, not just the main
                    // renderer's present.
                    //
                    // Also skip while another D3D lifecycle operation is
                    // active on this thread. This timer calls
                    // presentShaderAnimationFrame() directly, without
                    // acquiring ctx_mu or checking resourcesReady() the way
                    // WM_PAINT's render path does. Reentry risks interleaving
                    // immediate-context state or using a renderer while it is
                    // being prepared, replaced, or published. The next tick
                    // (~16ms later) retries.
                    if (app.in_present_shader_animation_frame or
                        app.wm_paint_in_progress or
                        app.glow_prepare_in_progress or
                        app.device_lost_recovering or
                        app.external_window_create_in_progress or
                        app.main_resize_in_progress or
                        app.main_dpi_change_in_progress)
                    {
                        if (applog.isEnabled()) applog.appLog("[win] presentShaderAnimationFrame: re-entrant/busy call skipped\n", .{});
                    } else {
                        app.in_present_shader_animation_frame = true;
                        defer {
                            app.in_present_shader_animation_frame = false;
                            _ = app.finishActiveOperation();
                        }
                        if (app.renderer) |*r| {
                            r.presentShaderAnimationFrame();
                        }
                        // Iterating external_windows under app.mu while
                        // calling Present on each renderer would self-
                        // deadlock if DXGI's Present pumps a message whose
                        // handler also locks app.mu (close, resize,
                        // repaint, etc.). Snapshot the renderers under
                        // the lock and bump paint_ref_count so concurrent
                        // close handlers wait, then drop the lock for the
                        // actual presents. finishExternalWindowPaint
                        // releases the ref + drives any deferred close.
                        app.shader_anim_external_grids.clearRetainingCapacity();
                        app.shader_anim_external_renderers.clearRetainingCapacity();
                        app.mu.lockUncancelable(core.clock.io());
                        const ext_capacity = app.external_windows.count();
                        const snapshot_ready = snapshot: {
                            app.shader_anim_external_grids.ensureTotalCapacity(app.alloc, ext_capacity) catch break :snapshot false;
                            app.shader_anim_external_renderers.ensureTotalCapacity(app.alloc, ext_capacity) catch break :snapshot false;
                            var it = app.external_windows.iterator();
                            while (it.next()) |entry| {
                                const ew = entry.value_ptr.*;
                                if (ew.is_pending_close) continue;
                                ew.paint_ref_count += 1;
                                app.shader_anim_external_grids.appendAssumeCapacity(entry.key_ptr.*);
                                app.shader_anim_external_renderers.appendAssumeCapacity(&ew.renderer);
                            }
                            break :snapshot true;
                        };
                        if (!snapshot_ready) {
                            app.shader_anim_external_grids.clearRetainingCapacity();
                            app.shader_anim_external_renderers.clearRetainingCapacity();
                        }
                        app.mu.unlock(core.clock.io());

                        var anim_dev_lost = false;
                        if (app.renderer) |*r| anim_dev_lost = r.device_lost;
                        var i: usize = 0;
                        while (i < app.shader_anim_external_renderers.items.len) : (i += 1) {
                            const renderer = app.shader_anim_external_renderers.items[i];
                            if (renderer.contractBOffsetActive()) {
                                _ = c.InvalidateRect(renderer.hwnd, null, c.FALSE);
                            } else {
                                renderer.presentShaderAnimationFrame();
                            }
                            anim_dev_lost = anim_dev_lost or renderer.device_lost;
                        }
                        var j: usize = 0;
                        while (j < app.shader_anim_external_grids.items.len) : (j += 1) {
                            external_windows.finishExternalWindowPaint(app, app.shader_anim_external_grids.items[j]);
                        }
                        // A pending close can release a renderer in the finish
                        // call above. Never dereference the stored pointers
                        // afterwards; retain only their allocation capacity.
                        app.shader_anim_external_grids.clearRetainingCapacity();
                        app.shader_anim_external_renderers.clearRetainingCapacity();

                        // presentShaderAnimationFrame() sets device_lost on a
                        // failed Present but, unlike the WM_PAINT path, this
                        // timer has no repaint to notice it — without this,
                        // the animation ticker keeps firing Present on a torn-
                        // down device until an unrelated Neovim redraw
                        // happens to arrive. Route into the same deduplicated
                        // recovery handler WM_PAINT uses.
                        if (anim_dev_lost) postDeviceLostRecovery(hwnd, app);
                    }
                }
            } else if (wParam == TIMER_DEVCONTAINER_POLL) {
                // Poll for devcontainer up completion
                if (dialogs.g_devcontainer_up_done.load(.seq_cst)) {
                    if (applog.isEnabled()) applog.appLog("[win] WM_TIMER: devcontainer up completed\n", .{});
                    _ = c.KillTimer(hwnd, TIMER_DEVCONTAINER_POLL);

                    if (getApp(hwnd)) |app| {
                        if (dialogs.g_devcontainer_up_success.load(.seq_cst)) {
                            // Success: update label and start nvim with devcontainer exec
                            dialogs.updateDevcontainerProgressLabel(std.unicode.utf8ToUtf16LeStringLiteral("Connecting..."));

                            // Build devcontainer exec command
                            var nvim_cmd_buf: [4096]u8 = undefined;
                            var nvim_cmd_slice: []const u8 = undefined;

                            if (app.devcontainer_workspace) |workspace| {
                                var w = std.Io.Writer.fixed(&nvim_cmd_buf);
                                const writer = &w;
                                writer.writeAll("devcontainer exec --workspace-folder \"") catch {};
                                writer.writeAll(workspace) catch {};
                                writer.writeAll("\"") catch {};
                                if (app.devcontainer_config) |config_path| {
                                    writer.writeAll(" --config \"") catch {};
                                    writer.writeAll(config_path) catch {};
                                    writer.writeAll("\"") catch {};
                                }
                                writer.writeAll(" --remote-env XDG_CONFIG_HOME=/nvim-config nvim --embed") catch {};
                                nvim_cmd_slice = nvim_cmd_buf[0..w.end];
                                if (applog.isEnabled()) applog.appLog("[win] devcontainer exec command: {s}\n", .{nvim_cmd_slice});

                                // Start nvim
                                const nvim_path_z = app.alloc.dupeZ(u8, nvim_cmd_slice) catch null;
                                defer if (nvim_path_z) |p| app.alloc.free(p);
                                const nvim_path_ptr: ?[*:0]const u8 = if (nvim_path_z) |p| p.ptr else null;
                                if (applog.isEnabled()) applog.appLog("[win] starting neovim via devcontainer exec\n", .{});
                                const start_ok = core.zonvie_core_start(app.corep, nvim_path_ptr, 24, 80);
                                if (applog.isEnabled()) applog.appLog("[win] zonvie_core_start -> {d}\n", .{start_ok});

                                // Renderer is already initialized at this point; notify with correct rows/cols.
                                core.zonvie_core_notify_layout_ready(app.corep, app.surface.rows, app.surface.cols);

                                app.devcontainer_up_pending = false;
                                app.devcontainer_nvim_started = true;
                            }

                            // Hide progress dialog
                            dialogs.hideDevcontainerProgressDialog();
                        } else {
                            // Failure: hide dialog and show error
                            dialogs.hideDevcontainerProgressDialog();
                            app.devcontainer_up_pending = false;
                            if (applog.isEnabled()) applog.appLog("[win] devcontainer up failed\n", .{});
                            // TODO: show error message to user
                        }
                    }
                }
            } else if (wParam == TIMER_REPOSITION_FLOATS) {
                _ = c.KillTimer(hwnd, TIMER_REPOSITION_FLOATS);
                if (getApp(hwnd)) |app| {
                    messages.updateExtFloatPositions(app);
                    messages.updateMiniWindows(app);
                }
            } else if (wParam == TIMER_TRAY_INIT) {
                _ = c.KillTimer(hwnd, TIMER_TRAY_INIT);
                if (getApp(hwnd)) |app| {
                    app.tray_icon = TrayIcon.init(hwnd);
                    if (app.tray_icon) |*tray| {
                        _ = tray.add();
                    }
                    if (applog.isEnabled()) applog.appLog("[win] TIMER_TRAY_INIT: tray icon initialized\n", .{});
                }
            } else if (wParam == TIMER_QUIT_TIMEOUT) {
                // Neovim not responding to quit request - show force quit dialog
                if (applog.isEnabled()) applog.appLog("[win] WM_TIMER: quit timeout - Neovim not responding\n", .{});
                _ = c.KillTimer(hwnd, TIMER_QUIT_TIMEOUT);
                if (getApp(hwnd)) |app| {
                    app.quit_pending = false;
                    // Set flag immediately to ignore any delayed WM_APP_QUIT_REQUESTED
                    // that may arrive before WM_APP_QUIT_TIMEOUT is processed
                    app.quit_timeout_fired = true;
                }
                // Post message to handle dialog on main thread
                _ = c.PostMessageW(hwnd, WM_APP_QUIT_TIMEOUT, 0, 0);
            }
            return 0;
        },

        app_mod.WM_APP_FLUSH_RETRY_ARM => {
            // Posted from the core thread (onFlushBegin / failFlush) after a
            // flush abort. SetTimer must run on this (UI) thread — that's
            // why the core thread couldn't arm it directly. Re-arming with
            // the same timer ID just resets the deadline if another abort
            // arrives before this fires (no double-fire, no extra state).
            if (getApp(hwnd)) |app| armFlushRetryWake(hwnd, app);
            return 0;
        },

        app_mod.WM_APP_FLUSH_RETRY_FALLBACK => {
            if (getApp(hwnd)) |app| {
                // Reject a stale delivery: the timer-queue worker cannot be
                // cancelled, so a fallback armed for an already-serviced retry
                // would consume a newer one early and double-advance the
                // backoff. Same guard shape as WM_APP_PAINT_RETRY_FALLBACK.
                if (@as(usize, @bitCast(lParam)) == app.window_wake_cookie and
                    @as(u32, @intCast(wParam & 0xFFFF_FFFF)) == app.flush_retry_wake_generation)
                {
                    if (flushRetryReentrancyBlocked(app)) {
                        // Unlike TIMER_FLUSH_RETRY this delivery is one-shot,
                        // so deferring it would destroy the only wake. Release
                        // the armed state so the next armFlushRetryWake issues
                        // a fresh one instead of coalescing onto a wake that
                        // will never arrive, and keep the elapsed deadline so
                        // serviceDeferredUiRetries can still pick it up first.
                        app.flush_retry_wake_armed = false;
                        app.flush_retry_fallback_wake_issued = false;
                        armFlushRetryWake(hwnd, app);
                    } else {
                        consumeFlushRetryWake(hwnd, app);
                    }
                }
            }
            return 0;
        },

        app_mod.WM_APP_EXTERNAL_CREATE_RETRY_FALLBACK => {
            if (getApp(hwnd)) |app| {
                if (@as(usize, @bitCast(lParam)) == app.window_wake_cookie) {
                    external_windows.consumeExternalCreateRetryWake(app, @intCast(wParam));
                }
            }
            return 0;
        },

        app_mod.WM_APP_MSG_THROTTLE_ARM => {
            if (getApp(hwnd)) |app| {
                app.msg_throttle_arm_posted.store(false, .release);
                armMsgThrottleTimer(hwnd, app);
            }
            return 0;
        },

        app_mod.WM_APP_PAINT_RETRY_FALLBACK => {
            if (getApp(hwnd)) |app| {
                if (@as(usize, @bitCast(lParam)) == app.window_wake_cookie and
                    app.paint_retry.timerFired(@intCast(wParam)))
                {
                    app.main_paint_retry_deadline_ms = 0;
                    _ = c.InvalidateRect(hwnd, null, c.FALSE);
                }
            }
            return 0;
        },

        app_mod.WM_APP_DEVICE_LOST_RETRY_FALLBACK => {
            if (getApp(hwnd)) |app| {
                if (@as(usize, @bitCast(lParam)) == app.window_wake_cookie) {
                    app.device_lost_retry_needed = false;
                    app.device_lost_retry_deadline_ms = 0;
                    postDeviceLostRecovery(hwnd, app);
                }
            }
            return 0;
        },

        app_mod.WM_APP_SIZE_REPLAY_FALLBACK => {
            if (getApp(hwnd)) |app| {
                if (@as(usize, @bitCast(lParam)) == app.window_wake_cookie) {
                    replayMainSize(hwnd, app);
                }
            }
            return 0;
        },

        app_mod.WM_APP_DEVICE_LOST_RECOVER => {
            // D3D11 device lost (TDR / driver reset / driver update). Rebuild
            // the device-bound world: shared device, D2D interop, main
            // renderer, per-external-window renderers and every GPU vertex
            // buffer. CPU-side state (vertices, CPU atlas pixels, glyph maps)
            // survives, so recovery is a re-upload, not a re-rasterization.
            if (getApp(hwnd)) |app| {
                if (lParam != 0 and @as(usize, @bitCast(lParam)) != app.window_wake_cookie) return 0;
                if (app.device_lost_recovering) {
                    // Reentrant recovery: message-pumping device/D2D/renderer
                    // creation further down this same handler reentered the
                    // message loop and dispatched another
                    // WM_APP_DEVICE_LOST_RECOVER. Proceeding would let the
                    // inner call's freshly-created device/context/renderer be
                    // overwritten by the outer call finishing afterward with
                    // an OLDER generation, or vice versa — reject re-entry
                    // outright. The already-running outer call will complete
                    // (or re-arm TIMER_DEVICE_LOST_RETRY on failure) on its own.
                    // Clear the dedup flag so a FUTURE (genuinely new)
                    // device-loss detection can post again — the outer call
                    // already cleared it for ITS OWN dispatch, but this
                    // rejected reentrant one was never given a chance to.
                    // Leaving it stuck true would permanently disable
                    // device-lost recovery after the first reentrant hit.
                    app.device_lost_recover_posted = false;
                    if (applog.isEnabled()) applog.appLog("[win] device-lost recovery: reentrant call rejected\n", .{});
                    return 0;
                }
                if (app.wm_paint_in_progress or
                    app.in_present_shader_animation_frame or
                    app.glow_prepare_in_progress or
                    app.main_resize_in_progress or
                    app.main_dpi_change_in_progress)
                {
                    // An outer paint, shader-animation Present, or glow
                    // warm-up is currently using the renderer/device state
                    // this recovery is about to tear down and release. If a
                    // queued WM_APP_DEVICE_LOST_RECOVER is dispatched through
                    // that operation's message-pump reentrancy, proceeding now
                    // would free objects the outer operation resumes using —
                    // a use-after-Release, not just a lock/deadlock hazard.
                    // Defer: clear the dedup flag and re-arm a retry: once
                    // the outer paint/present finishes, the next attempt
                    // runs with nothing else in flight.
                    app.device_lost_recover_posted = false;
                    if (applog.isEnabled()) applog.appLog("[win] device-lost recovery: render operation in progress, deferring\n", .{});
                    scheduleDeviceLostRetry(hwnd, app);
                    return 0;
                }

                // A retry timer can outlive the recovery generation that
                // armed it. If another path already rebuilt every renderer,
                // do not tear that healthy generation down again.
                var any_device_lost = false;
                app.mu.lockUncancelable(core.clock.io());
                if (app.renderer) |*r| {
                    any_device_lost = r.device_lost;
                } else {
                    any_device_lost = true;
                }
                if (!any_device_lost) {
                    var lost_it = app.external_windows.valueIterator();
                    while (lost_it.next()) |ew_ptr| {
                        if (ew_ptr.*.renderer.device_lost) {
                            any_device_lost = true;
                            break;
                        }
                    }
                }
                app.mu.unlock(core.clock.io());
                if (!any_device_lost) {
                    app.device_lost_recover_posted = false;
                    app.device_lost_recover_attempts = 0;
                    app.device_lost_recovery_warning_shown = false;
                    app.device_lost_retry_needed = false;
                    app.device_lost_retry_deadline_ms = 0;
                    _ = c.KillTimer(hwnd, app_mod.TIMER_DEVICE_LOST_RETRY);
                    if (applog.isEnabled()) applog.appLog("[win] device-lost recovery: stale retry ignored\n", .{});
                    return 0;
                }

                smooth_session.onDeviceLost(app);
                // Device loss drops transforms wholesale; stale ease accounting
                // must not survive into the rebuilt device generation. UI
                // thread, so the lock-free ledger clear is safe.
                app.tbs.clearBEaseCommits();
                app.tbs.clearRetention();
                // A device-loss drop of active px offsets also owes one final
                // recompose frame on the rebuilt device before the blit
                // path resumes.
                if (app.b_offset_ledger.dropAll()) app.b_forced_zero_pending = true;

                _ = c.KillTimer(hwnd, app_mod.TIMER_DEVICE_LOST_RETRY);
                app.device_lost_retry_needed = false;
                app.device_lost_retry_deadline_ms = 0;
                app.device_lost_recovering = true;
                defer {
                    app.device_lost_recovering = false;
                    _ = app.finishActiveOperation();
                }
                app.device_lost_recover_posted = false;
                app.device_lost_recover_attempts +|= 1;
                if (render_helpers.shouldWarnDeviceLostRecovery(
                    app.device_lost_recover_attempts,
                    app.device_lost_recovery_warning_shown,
                )) {
                    app.device_lost_recovery_warning_shown = true;
                    // A modal dialog would suspend the recovery loop until
                    // dismissed. Use the existing non-blocking tray channel so
                    // the next rebuild attempt starts immediately.
                    if (app.tray_icon == null) app.tray_icon = TrayIcon.init(hwnd);
                    if (app.tray_icon) |*tray| {
                        if (tray.add()) {
                            tray.showBalloon(
                                "Zonvie",
                                "GPU recovery is taking longer than expected. Zonvie will keep retrying; restart the app if the problem persists.",
                            );
                        }
                    }
                }
                if (applog.isEnabled()) applog.appLog("[win] device-lost recovery attempt {d}\n", .{app.device_lost_recover_attempts});

                // Steps 1-2 detach shared objects under a SHORT app.mu hold,
                // then perform every Release()/deinit() after unlocking.
                // Step 3 (fresh device + D2D
                // rebind + renderer) runs UNLOCKED — CreateDevice/DXGI/
                // DirectComposition calls there CAN pump messages, which can
                // reenter WM_PAINT/WM_SIZE/close handlers on this same UI
                // thread; holding app.mu across that window would
                // self-deadlock the first time one of those reentrant
                // handlers tried to acquire it (device_lost_recovering only
                // guards WM_PAINT/WM_SIZE specifically, not every possible
                // reentrant path — e.g. close/create/timer/DPI-change
                // handlers). D2D field mutations (initD2DDeviceContext /
                // releaseD2DDeviceObjects) are self-protected via the
                // atlas's own self.mu now (see their doc comments), so
                // running them unlocked here is still safe relative to
                // core-thread atlas callbacks even without app.mu held.
                // The shared D3D device/context and the main renderer are
                // detached (swapped to null) under app.mu, but their actual
                // teardown (Release()/deinit()) runs AFTER unlocking — a TDR/
                // device-removal is exactly the scenario where COM teardown
                // has been known to synchronously pump the message queue,
                // and holding app.mu across that risks the same reentrant
                // deadlock CreateDevice/CreateBitmap did before this file's
                // other lock-scope fixes. releaseD2DDeviceObjects() already
                // applies the same pattern internally (its own self.mu).
                var old_main_renderer: ?d3d11.Renderer = null;
                var old_d3d_ctx: ?*c.ID3D11DeviceContext = null;
                var old_d3d_device: ?*c.ID3D11Device = null;
                var old_cursor_vb: ?*c.ID3D11Buffer = null;
                var old_scrollbar_vb: ?*c.ID3D11Buffer = null;
                {
                    app.mu.lockUncancelable(core.clock.io());
                    defer app.mu.unlock(core.clock.io());

                    // Detach singleton objects only. Row buffers are detached
                    // one at a time below so no COM Release runs under app.mu.
                    old_cursor_vb = app.cursor_vb;
                    app.cursor_vb = null;
                    app.cursor_vb_bytes = 0;
                    old_scrollbar_vb = app.scrollbar_vb;
                    app.scrollbar_vb = null;
                    app.scrollbar_vb_bytes = 0;
                    old_main_renderer = app.renderer;
                    app.renderer = null;

                    old_d3d_ctx = app.d3d_ctx;
                    app.d3d_ctx = null;
                    old_d3d_device = app.d3d_device;
                    app.d3d_device = null;
                }
                releaseMainRecoveryBuffers(app);
                if (old_cursor_vb) |vb| _ = vb.lpVtbl.*.Release.?(vb);
                if (old_scrollbar_vb) |vb| _ = vb.lpVtbl.*.Release.?(vb);
                // releaseD2DDeviceObjects drops its own mutex before COM;
                // call it with no outer app.mu held as well.
                if (app.atlas) |*a| a.releaseD2DDeviceObjects();
                if (old_main_renderer) |*r| r.deinit();
                if (old_d3d_ctx) |ctx| _ = ctx.lpVtbl.*.Release.?(ctx);
                if (old_d3d_device) |dev| _ = dev.lpVtbl.*.Release.?(dev);
                if (app.device_lost_recovery_cancelled) return 0;

                // 3. Fresh device + D2D rebind + renderer, unlocked as above.
                var new_d3d_device: ?*c.ID3D11Device = null;
                var new_d3d_ctx: ?*c.ID3D11DeviceContext = null;
                if (d3d11.Renderer.createDeviceOnly() catch null) |result| {
                    new_d3d_device = result.device;
                    new_d3d_ctx = result.ctx;
                }
                if (new_d3d_device) |d3d_dev| {
                    if (app.atlas) |*a| {
                        a.initD2DDeviceContext(d3d_dev) catch {
                            a.initRenderTarget() catch {};
                        };
                    }
                } else if (app.atlas) |*a| {
                    a.initRenderTarget() catch {};
                }

                // WM_DPICHANGED can be delivered reentrantly by the COM/DXGI
                // calls above. Its recovery guard applies the suggested rect
                // without touching shared locks; replay the resulting DPI and
                // metrics now, before the new renderer generation is built.
                applyMainDpiState(app, GetDpiForWindow(hwnd));

                // Device/context are NOT published yet — see below. Publishing
                // them here, separately from the renderer, would let a
                // reader observe "new device, no/old renderer" — a real
                // generation mismatch, not just a theoretical one, since a
                // later renderer-init failure leaves that combination
                // visible until the next retry. Everything publishes
                // together, atomically, only once ALL of device/context/
                // renderer are known-good (or not at all, on failure).
                const recover_render_hwnd = if (app.ext_tabline_enabled and app.content_hwnd != null)
                    app.content_hwnd.?
                else
                    hwnd;
                var recovered_gpu: ?d3d11.Renderer = blk: {
                    if (new_d3d_device != null and new_d3d_ctx != null) {
                        break :blk d3d11.Renderer.initWithDevice(app.alloc, recover_render_hwnd, app.config.window.opacity, new_d3d_device.?, new_d3d_ctx.?) catch null;
                    }
                    break :blk d3d11.Renderer.init(app.alloc, recover_render_hwnd, app.config.window.opacity) catch null;
                };
                if (recovered_gpu) |*r| {
                    // Complete the generation before publication: shader
                    // pipelines, current client size, and current atlas size
                    // must all belong to the same renderer generation.
                    r.loadCustomShaderPipelines(&app.config);
                    if (app.corep) |corep| {
                        if (core.zonvie_core_get_glow_enabled(corep)) {
                            _ = r.prepareBloomShaders();
                        }
                    }
                    r.resize() catch {
                        r.deinit();
                        recovered_gpu = null;
                    };
                    if (recovered_gpu != null) {
                        if (app.atlas) |*a| {
                            a.mu.lockUncancelable(core.clock.io());
                            const atlas_w = a.atlas_w;
                            const atlas_h = a.atlas_h;
                            a.mu.unlock(core.clock.io());
                            r.recreateAtlasTextureIfNeeded(atlas_w, atlas_h) catch {
                                r.deinit();
                                recovered_gpu = null;
                            };
                        }
                    }
                }
                if (recovered_gpu == null) {
                    // Device creation transiently fails while the driver is
                    // still mid-reset (the common case right after a TDR).
                    // Nothing was published, so release the orphaned
                    // device/context/D2D-interop we just built instead of
                    // leaking them — the next retry rebuilds from scratch.
                    // WM_PAINT cannot re-post recovery here: its condition
                    // reads renderer.device_lost, and app.renderer is still
                    // null. Schedule the retry explicitly instead.
                    if (app.atlas) |*a| a.releaseD2DDeviceObjects();
                    if (new_d3d_ctx) |ctx| _ = ctx.lpVtbl.*.Release.?(ctx);
                    if (new_d3d_device) |dev| _ = dev.lpVtbl.*.Release.?(dev);
                    if (applog.isEnabled()) applog.appLog("[win] device-lost recovery: renderer re-init failed\n", .{});
                    scheduleDeviceLostRetry(hwnd, app);
                    _ = c.InvalidateRect(hwnd, null, c.FALSE);
                    return 0;
                }
                // Resize once more immediately before publication. A nested
                // WM_SIZE during renderer/atlas creation only updated the
                // actual HWND while recovery was active.
                recovered_gpu.?.resize() catch {
                    recovered_gpu.?.deinit();
                    if (app.atlas) |*a| a.releaseD2DDeviceObjects();
                    if (new_d3d_ctx) |ctx| _ = ctx.lpVtbl.*.Release.?(ctx);
                    if (new_d3d_device) |dev| _ = dev.lpVtbl.*.Release.?(dev);
                    scheduleDeviceLostRetry(hwnd, app);
                    return 0;
                };
                if (app.device_lost_recovery_cancelled) {
                    recovered_gpu.?.deinit();
                    if (app.atlas) |*a| a.releaseD2DDeviceObjects();
                    if (new_d3d_ctx) |ctx| _ = ctx.lpVtbl.*.Release.?(ctx);
                    if (new_d3d_device) |dev| _ = dev.lpVtbl.*.Release.?(dev);
                    return 0;
                }
                app.mu.lockUncancelable(core.clock.io());
                app.d3d_device = new_d3d_device;
                app.d3d_ctx = new_d3d_ctx;
                app.renderer = recovered_gpu.?;
                app.mu.unlock(core.clock.io());

                // 4. Full reseed: GPU atlas + all rows + tabline texture.
                app.atlas_full_upload_needed.store(true, .release);
                app.tabline_render_sig = 0;
                app.mu.lockUncancelable(core.clock.io());
                app.surface.paint_full = true;
                app.mu.unlock(core.clock.io());
                {
                    app.tbs.rotation_mu.lockUncancelable(core.clock.io());
                    app.tbs.pending_paint_full = true;
                    app.tbs.rotation_mu.unlock(core.clock.io());
                }

                // 5. External windows own independent (equally lost) devices.
                // Snapshot grid_ids and pin each via paint_ref_count under
                // app.mu first — mirroring presentShaderAnimationFrame's
                // pattern above. d3d11.Renderer.init below runs unlocked
                // (device creation is slow) and can pump window messages via
                // DXGI/DComposition, which can reenter this UI thread's
                // message loop and process a queued WM_APP_CLOSE_EXTERNAL_WINDOW
                // for the SAME grid_id mid-iteration.
                // closeExternalWindowOnUIThread only destroys immediately
                // when paint_ref_count == 0 (else it defers via
                // is_pending_close); without pinning the ref here first, that
                // reentrant close would free ext_win while this loop still
                // holds a pointer to it — a use-after-free. Iterating the
                // raw HashMapUnmanaged iterator across that same unlocked
                // window is also unsafe if a close mutates the map
                // concurrently, so the iteration itself only ever runs while
                // app.mu is held, over a bounded snapshot of grid_ids.
                var any_ext_failed = false;
                app.device_lost_recover_grids.clearRetainingCapacity();
                app.mu.lockUncancelable(core.clock.io());
                {
                    var it = app.external_windows.iterator();
                    while (it.next()) |entry| {
                        const ew = entry.value_ptr.*;
                        if (ew.is_pending_close) continue;
                        ew.paint_ref_count += 1;
                        app.device_lost_recover_grids.append(app.alloc, entry.key_ptr.*) catch {
                            // OOM collecting the snapshot: this window's ref
                            // was never pinned (append failed before it could
                            // be recorded), so leave it unrecovered rather
                            // than risk a pin/iteration mismatch. any_ext_failed
                            // below arms a retry that picks it up later.
                            ew.paint_ref_count -= 1;
                            any_ext_failed = true;
                            continue;
                        };
                    }
                }
                app.mu.unlock(core.clock.io());

                var ri: usize = 0;
                while (ri < app.device_lost_recover_grids.items.len) : (ri += 1) {
                    if (app.device_lost_recovery_cancelled) {
                        releaseRemainingDeviceLostRecoveryPins(app, ri);
                        return 0;
                    }
                    const grid_id = app.device_lost_recover_grids.items[ri];
                    app.mu.lockUncancelable(core.clock.io());
                    const ext_win_opt = app.external_windows.get(grid_id);
                    app.mu.unlock(core.clock.io());
                    const ext_win = ext_win_opt orelse {
                        external_windows.finishExternalWindowPaint(app, grid_id);
                        continue;
                    };
                    // Build the fresh renderer FIRST, outside app.mu (device
                    // creation is slow and touches no shared state). On
                    // failure the OLD renderer stays fully intact: it remains
                    // device_lost (paint skips via resourcesReady) and the
                    // window-close path can still deinit it exactly once —
                    // deinit leaves the struct undefined, so replacing it
                    // only on success is what prevents a later double-deinit
                    // on garbage COM pointers.
                    // Classify like the create path so decorated surfaces
                    // (cmdline/msg/popupmenu) recover with their own cached
                    // background instead of the colorscheme fallback.
                    const recovery_cached: u32 = switch (external_windows.classifyExternalSurface(grid_id)) {
                        .normal => if (ext_win.is_float_external) app.cached_normal_float_bg else 0xFFFFFFFF,
                        .cmdline, .msg_show, .msg_history => app.cached_msg_area_bg,
                        .popupmenu => app.cached_pmenu_bg,
                    };
                    const recovery_bg = if (recovery_cached != 0xFFFFFFFF) recovery_cached else app.colorscheme_bg;
                    const recovered_surface_kind = external_windows.classifyExternalSurface(grid_id);
                    var new_renderer = d3d11.Renderer.initExternal(app.alloc, ext_win.hwnd, app.config.window.opacity, app.config.window.blur, app.colorscheme_bg, recovery_bg, recovered_surface_kind == .cmdline) catch {
                        if (applog.isEnabled()) applog.appLog("[win] device-lost recovery: external renderer re-init failed (window stays lost)\n", .{});
                        any_ext_failed = true;
                        external_windows.finishExternalWindowPaint(app, grid_id);
                        continue;
                    };
                    new_renderer.loadCustomShaderPipelines(&app.config);
                    if (app.corep) |corep| {
                        if (core.zonvie_core_get_glow_enabled(corep)) {
                            _ = new_renderer.prepareBloomShaders();
                        }
                    }
                    new_renderer.resize() catch {
                        new_renderer.deinit();
                        any_ext_failed = true;
                        external_windows.finishExternalWindowPaint(app, grid_id);
                        continue;
                    };
                    if (app.atlas) |*a| {
                        a.mu.lockUncancelable(core.clock.io());
                        const atlas_w = a.atlas_w;
                        const atlas_h = a.atlas_h;
                        a.mu.unlock(core.clock.io());
                        new_renderer.recreateAtlasTextureIfNeeded(atlas_w, atlas_h) catch {
                            new_renderer.deinit();
                            any_ext_failed = true;
                            external_windows.finishExternalWindowPaint(app, grid_id);
                            continue;
                        };
                    }
                    // Replay any WM_SIZE delivered while the unlocked device
                    // and atlas creation calls pumped the message queue.
                    new_renderer.resize() catch {
                        new_renderer.deinit();
                        any_ext_failed = true;
                        external_windows.finishExternalWindowPaint(app, grid_id);
                        continue;
                    };
                    if (app.device_lost_recovery_cancelled) {
                        new_renderer.deinit();
                        releaseRemainingDeviceLostRecoveryPins(app, ri);
                        return 0;
                    }
                    const ext_dpi = GetDpiForWindow(ext_win.hwnd);
                    if (!releaseExternalRecoveryBuffers(app, grid_id, ext_win)) {
                        new_renderer.deinit();
                        external_windows.finishExternalWindowPaint(app, grid_id);
                        continue;
                    }
                    // Teardown + swap under app.mu: the core thread mutates
                    // surface.row_verts / row_vbs (including their .vb GPU
                    // pointers — onGridRowScroll's swapAndShiftRows permutes
                    // them) under app.mu; releasing them unlocked races those
                    // writers into use-after-Release or double-Release.
                    app.mu.lockUncancelable(core.clock.io());
                    // Re-validate map identity after the unlocked device
                    // creation above: the paint_ref_count pin guarantees
                    // ext_win's memory wasn't freed, but not that grid_id
                    // still names this exact window (defense in depth —
                    // is_pending_close blocking grid_id reuse should already
                    // prevent this in practice).
                    const still_same = app.external_windows.get(grid_id) == ext_win;
                    if (!still_same) {
                        app.mu.unlock(core.clock.io());
                        new_renderer.deinit();
                        external_windows.finishExternalWindowPaint(app, grid_id);
                        continue;
                    }
                    // The old renderer belongs to the lost COM generation.
                    // Discard records bound to the old surface before publishing
                    // the replacement renderer.
                    ext_win.tbs.rotation_mu.lockUncancelable(core.clock.io());
                    ext_win.tbs.a2_settle_commits.clear();
                    ext_win.tbs.rotation_mu.unlock(core.clock.io());
                    var old_renderer = ext_win.renderer;
                    ext_win.renderer = new_renderer;
                    // Force full atlas + content reseed on the fresh device.
                    ext_win.atlas_version = 0;
                    ext_win.atlas_upload_cursor = 0;
                    ext_win.atlas_reset_generation = 0;
                    ext_win.dpi_scale = @as(f32, @floatFromInt(ext_dpi)) / 96.0;
                    ext_win.surface.paint_full = true;
                    ext_win.needs_redraw = true;
                    app.mu.unlock(core.clock.io());
                    // The old renderer's COM objects are solely owned by this
                    // local copy now; releasing them needs no lock.
                    old_renderer.deinit();
                    _ = c.InvalidateRect(ext_win.hwnd, null, c.FALSE);
                    external_windows.finishExternalWindowPaint(app, grid_id);
                }

                if (any_ext_failed) {
                    // One or more external windows failed to get a fresh
                    // renderer (transient — driver still mid-reset) or were
                    // dropped from the snapshot under OOM. Re-running the
                    // whole handler is the same recovery mechanism already
                    // used when the MAIN renderer's own re-init fails above;
                    // reusing it here also catches these stragglers instead
                    // of leaving them permanently unrecovered.
                    if (applog.isEnabled()) applog.appLog("[win] device-lost recovery: one or more external windows still unrecovered\n", .{});
                    scheduleDeviceLostRetry(hwnd, app);
                } else {
                    app.device_lost_recover_attempts = 0;
                    app.device_lost_recovery_warning_shown = false;
                    app.device_lost_retry_needed = false;
                    app.device_lost_retry_deadline_ms = 0;
                    _ = c.KillTimer(hwnd, app_mod.TIMER_DEVICE_LOST_RETRY);
                }

                _ = c.InvalidateRect(hwnd, null, c.FALSE);
                if (applog.isEnabled()) applog.appLog("[win] device-lost recovery complete\n", .{});
            }
            return 0;
        },

        WM_APP_SHOW_CONNECT_DIALOG => {
            // `--connect-dialog`: present the startup connection chooser now that
            // the window exists. On Connect it populates the app's mode/ext
            // fields and posts WM_APP_DEFERRED_INIT; on Cancel it quits.
            if (getApp(hwnd)) |app| {
                dialogs.showConnectionDialog(app, hwnd);
            }
            return 0;
        },
        WM_APP_DEFERRED_INIT => {
            if (applog.isEnabled()) applog.appLog("[win] WM_APP_DEFERRED_INIT: begin", .{});

            // Timing measurement for startup diagnostics
            const deferred_log_enabled = applog.isEnabled();
            var freq: c.LARGE_INTEGER = undefined;
            var t0: c.LARGE_INTEGER = undefined;
            var t1: c.LARGE_INTEGER = undefined;
            var t2: c.LARGE_INTEGER = undefined;
            if (deferred_log_enabled) {
                _ = c.QueryPerformanceFrequency(&freq);
                _ = c.QueryPerformanceCounter(&t0);
            }

            if (getApp(hwnd)) |app| {
                var atlas: dwrite_d2d.Renderer = undefined;
                var owns_local_atlas = false;
                defer if (owns_local_atlas) atlas.deinit();

                if (app.early_core_init_done) {
                    // Native mode: core, config, nvim already initialized in doEarlyCoreInit.
                    // Reuse early_atlas for renderer setup.
                    if (deferred_log_enabled) applog.appLog("[win] DEFERRED_INIT: early_core_init path\n", .{});
                    atlas = app.early_atlas orelse return 0;
                    app.early_atlas = null;
                    owns_local_atlas = true;
                } else {
                    // WSL/SSH/devcontainer mode: full initialization path
                    if (deferred_log_enabled) applog.appLog("[win] DEFERRED_INIT: full init path\n", .{});

                    var cb = makeCoreCbs();
                    if (deferred_log_enabled) _ = c.QueryPerformanceCounter(&t1);
                    app.corep = core.zonvie_core_create(&cb, @sizeOf(core.Callbacks), app);
                    if (deferred_log_enabled) {
                        _ = c.QueryPerformanceCounter(&t2);
                        const core_create_ms = @divTrunc((t2.QuadPart - t1.QuadPart) * 1000, freq.QuadPart);
                        applog.appLog("  [TIMING] zonvie_core_create: {d}ms", .{core_create_ms});
                    }

                    // Load config into core for message routing
                    if (config_mod.getConfigFilePath(app.alloc)) |config_path| {
                        defer app.alloc.free(config_path);
                        const config_path_z = app.alloc.dupeZ(u8, config_path) catch null;
                        if (config_path_z) |cpath| {
                            defer app.alloc.free(cpath);
                            _ = core.zonvie_core_load_config(app.corep, cpath.ptr);
                        }
                    } else |_| {}

                    // Configure core settings
                    setLogEnabledViaCore(app, app.config.log.enabled);
                    if (app.ext_cmdline_enabled) core.zonvie_core_set_ext_cmdline(app.corep, 1);
                    if (app.config.popup.external) core.zonvie_core_set_ext_popupmenu(app.corep, 1);
                    if (app.ext_messages_enabled) core.zonvie_core_set_ext_messages(app.corep, 1);
                    if (app.ext_tabline_enabled) core.zonvie_core_set_ext_tabline(app.corep, 1);
                    if (app.ext_windows_enabled) core.zonvie_core_set_ext_windows(app.corep, 1);
                    core.zonvie_core_set_background_opacity(app.corep, app.config.window.opacity);
                    core.zonvie_core_set_blur_enabled(app.corep, if (app.config.window.blur) 1 else 0);
                    core.zonvie_core_set_glyph_cache_size(
                        app.corep,
                        app.config.performance.glyph_cache_ascii_size,
                        app.config.performance.glyph_cache_non_ascii_size,
                    );
                    core.zonvie_core_set_atlas_size(app.corep, app.config.performance.atlas_size);

                    // DWrite metrics init: walk the guifont-style candidate
                    // list from config and pick the first loadable font.
                    const initial_pt: f32 = if (app.config.font.size > 0.0) app.config.font.size else 14.0;

                    if (deferred_log_enabled) _ = c.QueryPerformanceCounter(&t1);
                    atlas = dwrite_d2d.Renderer.initMetrics(
                        app.alloc,
                        hwnd,
                        app.config.font.family,
                        initial_pt,
                        app.config.font.size_explicit,
                    ) catch |e| {
                        if (deferred_log_enabled) applog.appLog("dwrite_d2d.Renderer.initMetrics failed: {any}\n", .{e});
                        return 0;
                    };
                    owns_local_atlas = true;
                    if (deferred_log_enabled) {
                        _ = c.QueryPerformanceCounter(&t2);
                        const dwrite_metrics_ms = @divTrunc((t2.QuadPart - t1.QuadPart) * 1000, freq.QuadPart);
                        applog.appLog("  [TIMING] dwrite_d2d.Renderer.initMetrics: {d}ms", .{dwrite_metrics_ms});
                    }

                    app.mu.lockUncancelable(core.clock.io());
                    app.dpi_scale = @as(f32, @floatFromInt(atlas.dpi)) / 96.0;
                    app.mu.unlock(core.clock.io());
                    app.cell_w_px = atlas.cellW();
                    app.cell_h_px = atlas.cellH();
                    updateRowsColsFromClientForce(hwnd, app);

                    // Build nvim command and start nvim
                    var nvim_cmd_buf: [1024]u8 = undefined;
                    var nvim_cmd_slice: []const u8 = undefined;

                    const effective_nvim = app.cli_nvim_path orelse app.config.neovim.path;
                    const quoted_nvim: []const u8 = blk: {
                        if (std.mem.indexOfScalar(u8, effective_nvim, ' ') != null) {
                            const buf = app.alloc.alloc(u8, effective_nvim.len + 2) catch
                                break :blk effective_nvim;
                            buf[0] = '\'';
                            @memcpy(buf[1 .. 1 + effective_nvim.len], effective_nvim);
                            buf[1 + effective_nvim.len] = '\'';
                            break :blk buf;
                        }
                        break :blk effective_nvim;
                    };
                    defer if (quoted_nvim.ptr != effective_nvim.ptr) app.alloc.free(@constCast(quoted_nvim));

                    if (app.wsl_mode) {
                        var w = std.Io.Writer.fixed(&nvim_cmd_buf);
                        const writer = &w;
                        writer.writeAll("wsl.exe") catch {};
                        if (app.wsl_distro) |distro| {
                            writer.print(" -d {s}", .{distro}) catch {};
                        }
                        writer.writeAll(" --shell-type login -- nvim --embed") catch {};
                        nvim_cmd_slice = nvim_cmd_buf[0..w.end];
                    } else if (app.ssh_mode) {
                        if (app.ssh_host) |host| {
                            var w = std.Io.Writer.fixed(&nvim_cmd_buf);
                            const writer = &w;
                            writer.writeAll("ssh-askpass ") catch {};
                            writer.writeAll("C:\\Windows\\System32\\OpenSSH\\ssh.exe") catch {};
                            if (app.ssh_port) |port| {
                                writer.print(" -p {d}", .{port}) catch {};
                            }
                            if (app.ssh_identity) |identity| {
                                writer.print(" -i \"{s}\"", .{identity}) catch {};
                                writer.writeAll(" -o PasswordAuthentication=no -o KbdInteractiveAuthentication=no") catch {};
                            }
                            writer.writeAll(" -o StrictHostKeyChecking=accept-new") catch {};
                            const remote_nvim = app.cli_nvim_path orelse "nvim";
                            writer.print(" {s} \"'{s}'\" --headless --embed", .{ host, remote_nvim }) catch {};
                            nvim_cmd_slice = nvim_cmd_buf[0..w.end];

                            if (app.ssh_password) |pwd| {
                                var pwd_utf16: [256]u16 = undefined;
                                var pwd_idx: usize = 0;
                                for (pwd) |ch| {
                                    if (pwd_idx < 255) {
                                        pwd_utf16[pwd_idx] = ch;
                                        pwd_idx += 1;
                                    }
                                }
                                pwd_utf16[pwd_idx] = 0;
                                _ = c.SetEnvironmentVariableW(std.unicode.utf8ToUtf16LeStringLiteral("ZONVIE_SSH_PASSWORD"), &pwd_utf16);
                            }
                            _ = c.SetEnvironmentVariableW(std.unicode.utf8ToUtf16LeStringLiteral("ZONVIE_ASKPASS_MODE"), std.unicode.utf8ToUtf16LeStringLiteral("1"));
                            var exe_path: [c.MAX_PATH + 1]u16 = undefined;
                            const exe_len = c.GetModuleFileNameW(null, &exe_path, c.MAX_PATH + 1);
                            if (exe_len > 0 and exe_len < c.MAX_PATH) {
                                exe_path[exe_len] = 0;
                                _ = c.SetEnvironmentVariableW(std.unicode.utf8ToUtf16LeStringLiteral("SSH_ASKPASS"), &exe_path);
                            }
                            _ = c.SetEnvironmentVariableW(std.unicode.utf8ToUtf16LeStringLiteral("SSH_ASKPASS_REQUIRE"), std.unicode.utf8ToUtf16LeStringLiteral("force"));
                            _ = c.SetEnvironmentVariableW(std.unicode.utf8ToUtf16LeStringLiteral("DISPLAY"), std.unicode.utf8ToUtf16LeStringLiteral("dummy:0"));
                        } else {
                            nvim_cmd_slice = quoted_nvim;
                        }
                    } else if (app.devcontainer_mode) devcontainer_block: {
                        if (app.devcontainer_workspace) |workspace| {
                            if (app.devcontainer_rebuild) {
                                dialogs.showDevcontainerProgressDialog(std.unicode.utf8ToUtf16LeStringLiteral("Building devcontainer..."));
                                dialogs.g_devcontainer_up_done.store(false, .seq_cst);
                                dialogs.g_devcontainer_up_success.store(false, .seq_cst);
                                const thread = std.Thread.spawn(.{}, dialogs.runDevcontainerUpThread, .{ workspace, app.devcontainer_config, app.alloc }) catch |e| {
                                    if (deferred_log_enabled) applog.appLog("[win] failed to spawn devcontainer up thread: {any}\n", .{e});
                                    dialogs.hideDevcontainerProgressDialog();
                                    nvim_cmd_slice = quoted_nvim;
                                    break :devcontainer_block;
                                };
                                thread.detach();
                                app.devcontainer_up_pending = true;
                                _ = c.SetTimer(hwnd, TIMER_DEVCONTAINER_POLL, DEVCONTAINER_POLL_INTERVAL, null);
                                break :devcontainer_block;
                            } else {
                                dialogs.showDevcontainerProgressDialog(std.unicode.utf8ToUtf16LeStringLiteral("Connecting..."));
                                var w = std.Io.Writer.fixed(&nvim_cmd_buf);
                                const writer = &w;
                                writer.writeAll("devcontainer exec --workspace-folder \"") catch {};
                                writer.writeAll(workspace) catch {};
                                writer.writeAll("\"") catch {};
                                if (app.devcontainer_config) |config_path| {
                                    writer.writeAll(" --config \"") catch {};
                                    writer.writeAll(config_path) catch {};
                                    writer.writeAll("\"") catch {};
                                }
                                writer.writeAll(" --remote-env XDG_CONFIG_HOME=/nvim-config nvim --embed") catch {};
                                nvim_cmd_slice = nvim_cmd_buf[0..w.end];
                            }
                        } else {
                            nvim_cmd_slice = quoted_nvim;
                        }
                    } else {
                        nvim_cmd_slice = quoted_nvim;
                    }

                    // Start nvim
                    if (!app.devcontainer_up_pending) {
                        const nvim_path_z = app.alloc.dupeZ(u8, nvim_cmd_slice) catch null;
                        defer if (nvim_path_z) |p| app.alloc.free(p);
                        const nvim_path_ptr: ?[*:0]const u8 = if (nvim_path_z) |p| p.ptr else null;
                        const start_rc = core.zonvie_core_start(app.corep, nvim_path_ptr, app.surface.rows, app.surface.cols);
                        if (start_rc != 0) {
                            if (applog.isEnabled()) applog.appLog("[win] devcontainer-up: core start failed rc={d}; aborting\n", .{start_rc});
                            app.neovim_exited.store(true, .release);
                            app_mod.g_exit_code.store(1, .seq_cst);
                            _ = c.PostMessageW(hwnd, c.WM_CLOSE, 0, 0);
                            return 0;
                        }
                        app.nvim_spawned = true;
                        if (app.devcontainer_mode and !app.devcontainer_rebuild) {
                            dialogs.hideDevcontainerProgressDialog();
                        }
                    }

                    // Create D3D11 device (inline, not threaded for remote modes)
                    const d3d_result = d3d11.Renderer.createDeviceOnly() catch null;
                    if (d3d_result) |result| {
                        app.d3d_device = result.device;
                        app.d3d_ctx = result.ctx;
                    }

                    // DWM custom titlebar: post SWP_FRAMECHANGED (fallback path only)
                    if (!app.early_core_init_done and app.ext_tabline_enabled and app.tabline_style == .titlebar) {
                        _ = c.PostMessageW(hwnd, app_mod.WM_APP_SWP_FRAMECHANGED, 0, 0);
                        if (deferred_log_enabled) applog.appLog("[win] deferred_init: SWP_FRAMECHANGED posted (fallback path)\n", .{});
                    }
                }

                // ============================================================
                // PHASE 2: Initialize renderers
                // ============================================================

                // Assign atlas BEFORE renderer creation so callbacks can use it
                app.mu.lockUncancelable(core.clock.io());
                app.atlas = atlas;
                owns_local_atlas = false;
                app.mu.unlock(core.clock.io());

                // Notify layout ready BEFORE renderer setup (atlas is ready, unblock RPC thread)
                core.zonvie_core_notify_layout_ready(app.corep, app.surface.rows, app.surface.cols);
                if (deferred_log_enabled) applog.appLog("[win] notified layout ready: rows={d} cols={d}\n", .{ app.surface.rows, app.surface.cols });

                // Complete DWrite/D2D: create D2D device context from D3D11 device.
                if (deferred_log_enabled) _ = c.QueryPerformanceCounter(&t1);

                // Join D3D11 init thread if it was spawned (native mode)
                if (app.d3d_init_thread) |thr| {
                    thr.join();
                    app.d3d_init_thread = null;
                    if (deferred_log_enabled) applog.appLog("[win] d3d_init_thread joined\n", .{});
                }

                // If no D3D device after thread join, create inline
                if (app.d3d_device == null) {
                    const d3d_inline = d3d11.Renderer.createDeviceOnly() catch null;
                    if (d3d_inline) |result| {
                        app.d3d_device = result.device;
                        app.d3d_ctx = result.ctx;
                    }
                }

                if (app.d3d_device) |d3d_dev| {
                    if (app.atlas) |*a| {
                        a.initD2DDeviceContext(d3d_dev) catch |e| {
                            if (deferred_log_enabled) applog.appLog("dwrite_d2d initD2DDeviceContext failed: {any}, trying legacy\n", .{e});
                            a.initRenderTarget() catch {};
                        };
                    }
                } else {
                    if (app.atlas) |*a| {
                        a.initRenderTarget() catch {};
                    }
                }
                // Check we have at least one render path
                if (app.atlas) |*a| {
                    if (a.d2d_device_ctx == null and a.rt == null) {
                        if (deferred_log_enabled) applog.appLog("dwrite_d2d: no D2D render path available; quitting\n", .{});
                        // The atlas is already published and a core callback
                        // may be using its inline optional payload outside
                        // app.mu. Keep ownership in App: WM_CLOSE teardown
                        // joins the core thread before deinit() destroys it.
                        app.neovim_exited.store(true, .release);
                        app_mod.g_exit_code.store(1, .seq_cst);
                        _ = c.PostMessageW(hwnd, c.WM_CLOSE, 0, 0);
                        return 0;
                    }
                }
                if (deferred_log_enabled) {
                    _ = c.QueryPerformanceCounter(&t2);
                    const rt_ms = @divTrunc((t2.QuadPart - t1.QuadPart) * 1000, freq.QuadPart);
                    applog.appLog("  [TIMING] D2D context init: {d}ms", .{rt_ms});
                }

                // D3D11 GPU renderer
                const render_hwnd = if (app.ext_tabline_enabled and app.content_hwnd != null)
                    app.content_hwnd.?
                else
                    hwnd;

                if (deferred_log_enabled) _ = c.QueryPerformanceCounter(&t1);
                const gpu = blk: {
                    if (app.d3d_device != null and app.d3d_ctx != null) {
                        break :blk d3d11.Renderer.initWithDevice(app.alloc, render_hwnd, app.config.window.opacity, app.d3d_device.?, app.d3d_ctx.?) catch |e| {
                            if (deferred_log_enabled) applog.appLog("d3d11.Renderer.initWithDevice failed: {any}\n", .{e});
                            return 0;
                        };
                    }
                    break :blk d3d11.Renderer.init(app.alloc, render_hwnd, app.config.window.opacity) catch |e| {
                        if (deferred_log_enabled) applog.appLog("d3d11.Renderer.init failed: {any}\n", .{e});
                        return 0;
                    };
                };
                if (deferred_log_enabled) {
                    _ = c.QueryPerformanceCounter(&t2);
                    const d3d_ms = @divTrunc((t2.QuadPart - t1.QuadPart) * 1000, freq.QuadPart);
                    applog.appLog("  [TIMING] d3d11.Renderer.init: {d}ms", .{d3d_ms});
                }

                app.mu.lockUncancelable(core.clock.io());
                app.renderer = gpu;
                app.mu.unlock(core.clock.io());

                if (deferred_log_enabled) applog.appLog("  renderer created ok", .{});

                // Load user-supplied custom post-process shaders. Disabled
                // by default; fails soft and logs on broken config. Must
                // run after the renderer is installed into `app.renderer`
                // because compilation + pixel-shader creation need the
                // live D3D11 device.
                if (app.renderer) |*r| {
                    r.loadCustomShaderPipelines(&app.config);
                    if (r.any_custom_shader_needs_animation) {
                        // Kick continuous-redraw ticker. Runs ~60Hz until
                        // the renderer (or a future config reload) tells
                        // us no animated shader is loaded anymore.
                        const tr = c.SetTimer(
                            hwnd,
                            app_mod.TIMER_CUSTOM_SHADER_ANIM,
                            app_mod.CUSTOM_SHADER_ANIM_INTERVAL_MS,
                            null,
                        );
                        if (applog.isEnabled()) applog.appLog("[win] TIMER_CUSTOM_SHADER_ANIM SetTimer hwnd={*} interval={d}ms -> {d}\n", .{ hwnd, app_mod.CUSTOM_SHADER_ANIM_INTERVAL_MS, tr });
                    } else {
                        if (applog.isEnabled()) applog.appLog("[win] TIMER_CUSTOM_SHADER_ANIM not started (no animated shader)\n", .{});
                    }
                }

                // Process pending glyphs
                {
                    app.mu.lockUncancelable(core.clock.io());
                    var pending_glyphs = app.pending_glyphs;
                    app.pending_glyphs = .empty;
                    app.mu.unlock(core.clock.io());
                    defer pending_glyphs.deinit(app.alloc);

                    if (pending_glyphs.items.len > 0) {
                        if (deferred_log_enabled) applog.appLog("  processing {d} pending glyphs", .{pending_glyphs.items.len});
                        var atlas_ptr: ?*dwrite_d2d.Renderer = null;
                        app.mu.lockUncancelable(core.clock.io());
                        if (app.atlas) |*a| atlas_ptr = a;
                        app.mu.unlock(core.clock.io());
                        if (atlas_ptr) |a| {
                            for (pending_glyphs.items) |pg| {
                                if (pg.style_flags == 0) {
                                    _ = a.atlasEnsureGlyphEntry(pg.scalar) catch {};
                                } else {
                                    _ = a.atlasEnsureGlyphEntryStyled(pg.scalar, pg.style_flags) catch {};
                                }
                            }
                        }
                    }
                }

                // Show window if pending (renderer now ready)
                if (app.pending_show_window) {
                    app.pending_show_window = false;
                    _ = c.ShowWindow(hwnd, c.SW_SHOW);
                    _ = c.PostMessageW(hwnd, app_mod.WM_APP_POST_SHOW_INIT, 0, 0);
                    if (deferred_log_enabled) {
                        var t_show: c.LARGE_INTEGER = undefined;
                        _ = c.QueryPerformanceCounter(&t_show);
                        const show_ms = @divTrunc((t_show.QuadPart - app_mod.g_startup_t0.QuadPart) * 1000, app_mod.g_startup_freq.QuadPart);
                        applog.appLog("[TIMING] ShowWindow (deferred, renderer ready): {d}ms from main()\n", .{show_ms});
                    }
                }

                // Update rows/cols + layout (non-titlebar mode)
                if (!(app.ext_tabline_enabled and app.tabline_style == .titlebar)) {
                    updateRowsColsFromClientForce(hwnd, app);
                    updateLayoutToCore(hwnd, app);
                }

                if (deferred_log_enabled) {
                    _ = c.QueryPerformanceCounter(&t2);
                    const total_ms = @divTrunc((t2.QuadPart - t0.QuadPart) * 1000, freq.QuadPart);
                    applog.appLog("[win] WM_APP_DEFERRED_INIT: end (total {d}ms)", .{total_ms});
                }

                // A glow request posted by the core may have been consumed
                // reentrantly while the renderer was still null. Reclaim the
                // coalesced slot now so warm-up is queued before this paint.
                if (app.corep) |corep| {
                    if (core.zonvie_core_get_glow_enabled(corep) and
                        app.glow_prepare_posted.cmpxchgStrong(false, true, .release, .monotonic) == null)
                    {
                        if (c.PostMessageW(hwnd, app_mod.WM_APP_PREPARE_GLOW, 0, 0) == 0) {
                            app.glow_prepare_posted.store(false, .release);
                        }
                    }
                }

                // Force a repaint now that renderer is ready
                _ = c.InvalidateRect(hwnd, null, 0);
            }
            return 0;
        },

        WM_APP_SHOW_WINDOW => {
            if (getApp(hwnd)) |app| {
                if (app.renderer == null) {
                    app.pending_show_window = true;
                    return 0;
                }
            }
            _ = c.ShowWindow(hwnd, c.SW_SHOW);
            _ = c.PostMessageW(hwnd, app_mod.WM_APP_POST_SHOW_INIT, 0, 0);
            if (applog.isEnabled()) {
                var t_show: c.LARGE_INTEGER = undefined;
                _ = c.QueryPerformanceCounter(&t_show);
                const elapsed_ms = @divTrunc((t_show.QuadPart - app_mod.g_startup_t0.QuadPart) * 1000, app_mod.g_startup_freq.QuadPart);
                applog.appLog("[TIMING] ShowWindow (first flush): {d}ms from main()\n", .{elapsed_ms});
            }
            return 0;
        },

        WM_APP_POST_SHOW_INIT => {
            // Deferred tray icon initialization (after window is shown)
            _ = c.SetTimer(hwnd, TIMER_TRAY_INIT, TRAY_INIT_DELAY_MS, null);
            return 0;
        },

        WM_APP_SWP_FRAMECHANGED => {
            var rc: c.RECT = undefined;
            _ = c.GetWindowRect(hwnd, &rc);
            _ = c.SetWindowPos(
                hwnd,
                null,
                rc.left,
                rc.top,
                rc.right - rc.left,
                rc.bottom - rc.top,
                c.SWP_FRAMECHANGED | c.SWP_NOMOVE | c.SWP_NOSIZE,
            );
            if (applog.isEnabled()) applog.appLog("[win] WM_APP_SWP_FRAMECHANGED: applied\n", .{});
            return 0;
        },

        c.WM_KEYDOWN, c.WM_SYSKEYDOWN => {
            if (getApp(hwnd)) |app| {
                const vk: u32 = @intCast(wParam);
                const mods = input.queryMods();

                // Windows keycode is passed as 0x10000|VK so Zig core can distinguish.
                const keycode: u32 = input.KEYCODE_WINVK_FLAG | vk;

                // scancode is in bits 16..23 of lParam
                const scancode: u32 = @intCast((@as(u32, @intCast(lParam)) >> 16) & 0xFF);

                const has_ctrl_alt = (mods & (input.MOD_CTRL | input.MOD_ALT)) != 0;

                // Check if IME is composing
                app.mu.lockUncancelable(core.clock.io());
                const ime_composing = app.ime_composing;
                app.mu.unlock(core.clock.io());

                // 1) Special keys always go through send_key_event (chars=nil)
                //    BUT skip VK_RETURN and VK_BACK when IME is composing to avoid double-input
                if (input.isSpecialVk(vk)) {
                    if (ime_composing and (vk == c.VK_RETURN or vk == c.VK_BACK)) {
                        // Let IME handle Enter/Backspace - committed text comes via WM_IME_CHAR,
                        // then the key comes via WM_CHAR after WM_IME_ENDCOMPOSITION.
                        // Return 0 to prevent DefWindowProcW from also translating.
                        return 0;
                    } else {
                        input.sendKeyEventToCore(app, keycode, mods, null, null);
                        return 0;
                    }
                }

                // 2) Ctrl/Alt combos: also go through send_key_event, and try to provide chars/ign.
                //    (Let Zig decide <C-x> etc.)
                if (has_ctrl_alt) {
                    var tmp_chars: [16]u16 = undefined;
                    var tmp_ign: [16]u16 = undefined;
                    var out_chars: [8]u8 = undefined;
                    var out_ign: [8]u8 = undefined;

                    const pair = input.toUnicodePairUtf8(
                        vk,
                        scancode,
                        &tmp_chars,
                        &tmp_ign,
                        &out_chars,
                        &out_ign,
                    );

                    input.sendKeyEventToCore(app, keycode, mods, pair.chars, pair.ign);
                    return 0;
                }

                // 3) Otherwise (normal text, Shift-only, IME): let WM_CHAR handle.
                // Do not consume here.
            }
        },

        c.WM_CHAR, c.WM_SYSCHAR => {
            if (getApp(hwnd)) |app| {
                const mods = input.queryMods();

                // If Ctrl/Alt are down, WM_CHAR often becomes ASCII control => ignore
                // (WM_KEYDOWN path handled Ctrl/Alt combos).
                if ((mods & (input.MOD_CTRL | input.MOD_ALT)) != 0) {
                    return 0;
                }

                var ch0: u16 = @as(u16, @intCast(wParam));

                // Skip control characters that are already handled by WM_KEYDOWN as special keys.
                // This prevents double-input of Enter, Backspace, Tab, Escape.
                // 0x08 = Backspace, 0x09 = Tab, 0x0D = Enter (CR), 0x1B = Escape
                if (ch0 == 0x08 or ch0 == 0x09 or ch0 == 0x0D or ch0 == 0x1B) {
                    app.pending_high_surrogate_char = 0;
                    return 0;
                }

                // `:` <-> `;` swap (config-gated) for single keypresses. Paste
                // arrives via a separate clipboard path, so it is unaffected.
                if (app.config.input.swap_colon_semicolon) {
                    if (ch0 == 0x3A) {
                        ch0 = 0x3B; // ':' -> ';'
                    } else if (ch0 == 0x3B) {
                        ch0 = 0x3A; // ';' -> ':'
                    }
                }

                // Non-BMP characters (e.g. emoji) arrive as two WM_CHARs: high
                // surrogate first, then low surrogate. Buffer the high one and
                // combine it with the next low one before sending to core.
                var out: [8]u8 = undefined;
                var s: ?[]const u8 = null;
                if (ch0 >= 0xD800 and ch0 <= 0xDBFF) {
                    app.pending_high_surrogate_char = ch0;
                    return 0;
                } else if (ch0 >= 0xDC00 and ch0 <= 0xDFFF) {
                    const hi = app.pending_high_surrogate_char;
                    app.pending_high_surrogate_char = 0;
                    if (hi == 0) return 0; // stray low surrogate
                    s = input.utf16UnitsToUtf8(&out, hi, ch0);
                } else {
                    app.pending_high_surrogate_char = 0;
                    s = input.utf16UnitsToUtf8(&out, ch0, null);
                }

                const text = s orelse return 0;
                // keycode=0 means "text input" (Zig will take chars path).
                input.sendKeyEventToCore(app, 0, mods, text, text);
                return 0;
            }
        },

        // --- IME message handling ---
        c.WM_IME_STARTCOMPOSITION => {
            if (applog.isEnabled()) applog.appLog("[IME] WM_IME_STARTCOMPOSITION\n", .{});
            if (getApp(hwnd)) |app| {
                app.mu.lockUncancelable(core.clock.io());
                app.ime_composing = true;
                app.ime_composition_str.clearRetainingCapacity();
                app.ime_composition_utf8.clearRetainingCapacity();
                app.ime_clause_info.clearRetainingCapacity();
                app.ime_cursor_pos = 0;
                app.ime_target_start = 0;
                app.ime_target_end = 0;
                app.mu.unlock(core.clock.io());

                // Position IME candidate window at cursor
                input.positionImeCandidateWindow(hwnd, app);
            }
            return 0;
        },

        c.WM_IME_COMPOSITION => {
            if (applog.isEnabled()) applog.appLog("[IME] WM_IME_COMPOSITION lParam=0x{x}\n", .{@as(u32, @intCast(lParam & 0xFFFFFFFF))});
            if (getApp(hwnd)) |app| {
                const himc = c.ImmGetContext(hwnd);
                if (himc != null) {
                    defer _ = c.ImmReleaseContext(hwnd, himc);

                    const lparam_u: c.LPARAM = lParam;

                    // Get composition string
                    if ((lparam_u & c.GCS_COMPSTR) != 0) {
                        const byte_len = c.ImmGetCompositionStringW(himc, c.GCS_COMPSTR, null, 0);
                        if (byte_len > 0) {
                            const char_len: usize = @intCast(@divTrunc(byte_len, 2));

                            app.mu.lockUncancelable(core.clock.io());
                            app.ime_composition_str.resize(app.alloc, char_len) catch {
                                app.mu.unlock(core.clock.io());
                                return 0;
                            };
                            _ = c.ImmGetCompositionStringW(himc, c.GCS_COMPSTR, app.ime_composition_str.items.ptr, @intCast(byte_len));

                            // Convert to UTF-8 for display
                            input.updateImeCompositionUtf8(app);
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
                    if ((lparam_u & c.GCS_COMPCLAUSE) != 0) {
                        const clause_byte_len = c.ImmGetCompositionStringW(himc, c.GCS_COMPCLAUSE, null, 0);
                        if (clause_byte_len > 0) {
                            const clause_count: usize = @intCast(@divTrunc(clause_byte_len, 4));
                            app.mu.lockUncancelable(core.clock.io());
                            app.ime_clause_info.resize(app.alloc, clause_count) catch {
                                app.mu.unlock(core.clock.io());
                                return 0;
                            };
                            _ = c.ImmGetCompositionStringW(himc, c.GCS_COMPCLAUSE, app.ime_clause_info.items.ptr, @intCast(clause_byte_len));
                            app.mu.unlock(core.clock.io());
                        }
                    }

                    // Get cursor position in composition
                    if ((lparam_u & c.GCS_CURSORPOS) != 0) {
                        const cursor_pos = c.ImmGetCompositionStringW(himc, c.GCS_CURSORPOS, null, 0);
                        app.mu.lockUncancelable(core.clock.io());
                        app.ime_cursor_pos = @intCast(@max(0, cursor_pos));
                        app.mu.unlock(core.clock.io());
                    }

                    // Get target clause (the clause being converted)
                    // Always try to get COMPATTR, not just when flag is set
                    {
                        const attr_len = c.ImmGetCompositionStringW(himc, c.GCS_COMPATTR, null, 0);
                        if (applog.isEnabled()) applog.appLog("[IME] GCS_COMPATTR attr_len={d} lparam_has_flag={d}\n", .{
                            attr_len,
                            @intFromBool((lparam_u & c.GCS_COMPATTR) != 0),
                        });
                        if (attr_len > 0) {
                            var attr_buf: [256]u8 = undefined;
                            const len: usize = @intCast(@min(@as(usize, @intCast(@max(0, attr_len))), 256));
                            _ = c.ImmGetCompositionStringW(himc, c.GCS_COMPATTR, &attr_buf, @intCast(len));

                            // Debug: log all attributes
                            if (applog.isEnabled()) {
                                applog.appLog("[IME] COMPATTR len={d} attrs=", .{len});
                                for (0..len) |idx| {
                                    applog.appLog("{x} ", .{attr_buf[idx]});
                                }
                                applog.appLog("\n", .{});
                            }

                            // Find target clause (ATTR_TARGET_CONVERTED or ATTR_TARGET_NOTCONVERTED)
                            // ATTR_INPUT = 0x00, ATTR_TARGET_CONVERTED = 0x01,
                            // ATTR_CONVERTED = 0x02, ATTR_TARGET_NOTCONVERTED = 0x03
                            app.mu.lockUncancelable(core.clock.io());
                            app.ime_target_start = 0;
                            app.ime_target_end = 0;
                            var found_start: bool = false;
                            var i: u32 = 0;
                            while (i < len) : (i += 1) {
                                const attr = attr_buf[i];
                                // ATTR_TARGET_CONVERTED = 0x01, ATTR_TARGET_NOTCONVERTED = 0x03
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

                    // Display preedit: prefer the core's inline-extmark mode
                    // when it accepts it (extmark mode + insert/replace);
                    // otherwise fall back to the overlay. Copy the UTF-8 out
                    // under the lock so the core call runs unlocked.
                    var handled = false;
                    if (app.corep) |corep| {
                        app.mu.lockUncancelable(core.clock.io());
                        // ime_composition_utf8 is mutated only on this (UI)
                        // thread, and the core call below runs synchronously on
                        // it, so the backing buffer stays valid after unlock —
                        // pass the full string directly (no copy/truncation).
                        const utf8_ptr = app.ime_composition_utf8.items.ptr;
                        const utf8_len = app.ime_composition_utf8.items.len;
                        // Map the target clause (UTF-16 unit indices) to UTF-8
                        // byte offsets within the composition string.
                        const units = app.ime_composition_str.items;
                        var ts: usize = 0;
                        var te: usize = 0;
                        if (app.ime_target_start < app.ime_target_end) {
                            ts = input.utf16PrefixUtf8Len(units, app.ime_target_start);
                            te = input.utf16PrefixUtf8Len(units, app.ime_target_end);
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
                        input.hideImePreeditOverlay(app);
                    } else {
                        input.updateImePreeditOverlay(hwnd, app);
                    }
                }
            }
            // Let DefWindowProc handle for default IME processing
            return c.DefWindowProcW(hwnd, msg, wParam, lParam);
        },

        c.WM_IME_ENDCOMPOSITION => {
            if (getApp(hwnd)) |app| {
                app.mu.lockUncancelable(core.clock.io());
                app.ime_composing = false;
                app.ime_composition_str.clearRetainingCapacity();
                app.ime_composition_utf8.clearRetainingCapacity();
                app.ime_clause_info.clearRetainingCapacity();
                app.ime_cursor_pos = 0;
                app.ime_target_start = 0;
                app.ime_target_end = 0;
                app.ime_extmark_active = false;
                app.mu.unlock(core.clock.io());

                // Clear any inline preedit extmark and hide the overlay.
                if (app.corep) |corep| app_mod.zonvie_core_clear_preedit(corep);
                input.hideImePreeditOverlay(app);
            }
            return 0;
        },

        c.WM_IME_CHAR => {
            // IME committed character - send to Neovim. Non-BMP commits arrive
            // as two consecutive WM_IME_CHAR messages (high then low surrogate).
            if (getApp(hwnd)) |app| {
                const ch: u16 = @intCast(wParam);

                var out: [8]u8 = undefined;
                var s: ?[]const u8 = null;
                if (ch >= 0xD800 and ch <= 0xDBFF) {
                    app.pending_high_surrogate_ime = ch;
                    return 0;
                } else if (ch >= 0xDC00 and ch <= 0xDFFF) {
                    const hi = app.pending_high_surrogate_ime;
                    app.pending_high_surrogate_ime = 0;
                    if (hi == 0) return 0;
                    s = input.utf16UnitsToUtf8(&out, hi, ch);
                } else {
                    app.pending_high_surrogate_ime = 0;
                    s = input.utf16UnitsToUtf8(&out, ch, null);
                }

                const text = s orelse return 0;
                input.sendKeyEventToCore(app, 0, 0, text, text);
                return 0;
            }
        },

        c.WM_MOUSEWHEEL => {
            if (getApp(hwnd)) |app| {
                // The main HWND is not an eligible external grid. Keep its
                // hit-tested grid routing on the legacy path.
                input.handleMouseWheel(hwnd, wParam, lParam, app, 1, false);
                return 0;
            }
        },

        c.WM_MOUSEHWHEEL => {
            if (getApp(hwnd)) |app| {
                input.handleMouseWheel(hwnd, wParam, lParam, app, 1, true);
                return 0;
            }
        },

        c.WM_POINTERWHEEL => {
            if (getApp(hwnd)) |app| {
                input.handleMouseWheel(hwnd, wParam, lParam, app, 1, false);
                return 0;
            }
        },

        c.WM_POINTERHWHEEL => {
            if (getApp(hwnd)) |app| {
                input.handleMouseWheel(hwnd, wParam, lParam, app, 1, true);
                return 0;
            }
        },

        // WM_VSCROLL not used (custom D3D11 scrollbar)

        WM_APP_UPDATE_SCROLLBAR => {
            if (getApp(hwnd)) |app| {
                // Clear pending flag BEFORE processing (allows new PostMessage during updateScrollbar)
                app.scrollbar_update_pending.store(false, .release);
                scrollbar.updateScrollbar(hwnd, app);
                return 0;
            }
        },

        app_mod.WM_APP_SMOOTH_SCROLL_COMMIT => {
            if (getApp(hwnd)) |app| {
                // Coalesced wakeup posted from onFlushEnd (core thread) after
                // a semantic smooth-scroll commit. Clear the flag BEFORE any
                // processing so a commit landing from here on can post again.
                // The session owner drains the target TBS semantic ring and
                // feeds the UI-thread coordinator below.
                app.smooth_scroll_commit_posted.store(false, .release);
                smooth_session.onSmoothCommit(app);
                return 0;
            }
        },

        app_mod.WM_APP_DM_UPDATE => {
            if (getApp(hwnd)) |app| {
                // Coalesced wakeup posted from the Direct Manipulation
                // delegate callback after a DmSnapshot mailbox write. Clear
                // the flag BEFORE any processing so a snapshot landing from
                // here on can post again. The coordinator drain that reads
                // the mailbox is performed by the session owner below.
                app.dm_update_posted.store(false, .release);
                smooth_session.onDmUpdate(app);
                return 0;
            }
        },

        // Mouse button events
        c.WM_LBUTTONDOWN, c.WM_RBUTTONDOWN, c.WM_MBUTTONDOWN => {
            if (getApp(hwnd)) |app| {
                // Extract position from lParam
                const x: i16 = @bitCast(@as(u16, @truncate(@as(usize, @bitCast(lParam)))));
                const y: i16 = @bitCast(@as(u16, @truncate(@as(usize, @bitCast(lParam)) >> 16)));

                // Check tabline/sidebar area first (when ext_tabline enabled)
                if (app.ext_tabline_enabled) {
                    if (app.tabline_style == .titlebar) {
                        if (msg == c.WM_LBUTTONDOWN and y < app.scalePx(TablineState.TAB_BAR_HEIGHT)) {
                            tabline_mod.handleTablineMouseDown(app, hwnd, @as(c_int, x), @as(c_int, y));
                            return 0;
                        }
                    } else if (app.tabline_style == .sidebar) {
                        var client_rect_sb: c.RECT = undefined;
                        _ = c.GetClientRect(hwnd, &client_rect_sb);
                        const sidebar_w_px = app.scalePx(@as(c_int, @intCast(app.sidebar_width_px)));
                        const in_sidebar = if (app.sidebar_position_right)
                            x >= @as(i16, @intCast(client_rect_sb.right - sidebar_w_px))
                        else
                            x < @as(i16, @intCast(sidebar_w_px));
                        if (in_sidebar) {
                            // Left button: handle sidebar interaction
                            // Right/middle button: consume event to prevent Neovim input
                            if (msg == c.WM_LBUTTONDOWN) {
                                tabline_mod.handleSidebarMouseDown(app, hwnd, @as(c_int, x), @as(c_int, y));
                            }
                            return 0;
                        }
                    }
                }

                // Check scrollbar hit first (left button only)
                if (msg == c.WM_LBUTTONDOWN) {
                    if (scrollbar.scrollbarMouseDown(hwnd, app, @as(i32, x), @as(i32, y))) {
                        return 0; // Handled by scrollbar
                    }
                }

                // Capture mouse to receive WM_MOUSEMOVE outside window
                _ = c.SetCapture(hwnd);

                // Determine button name
                const button: [*:0]const u8 = switch (msg) {
                    c.WM_LBUTTONDOWN => blk: {
                        app.mouse_button_held = 1;
                        break :blk "left";
                    },
                    c.WM_RBUTTONDOWN => blk: {
                        app.mouse_button_held = 2;
                        break :blk "right";
                    },
                    c.WM_MBUTTONDOWN => blk: {
                        app.mouse_button_held = 3;
                        break :blk "middle";
                    },
                    else => "left",
                };

                // Get cell dimensions
                app.mu.lockUncancelable(core.clock.io());
                const cell_w = app.cell_w_px;
                const cell_h = app.cell_h_px;
                const linespace = app.linespace_px;
                app.mu.unlock(core.clock.io());

                const row_h = cell_h + linespace;
                // When ext_tabline sidebar is enabled, subtract sidebar width to get content-relative X coordinate
                const content_x: i32 = if (app.ext_tabline_enabled and app.tabline_style == .sidebar and !app.sidebar_position_right)
                    @as(i32, x) - @as(i32, app.scalePx(@as(c_int, @intCast(app.sidebar_width_px))))
                else
                    @as(i32, x);
                const col: i32 = if (cell_w > 0) @divTrunc(@max(0, content_x), @as(i32, @intCast(cell_w))) else 0;
                // When ext_tabline titlebar is enabled, subtract tabbar height to get content-relative Y coordinate
                const content_y: i32 = if (app.ext_tabline_enabled and app.tabline_style == .titlebar and app.content_hwnd == null)
                    @as(i32, y) - @as(i32, app.scalePx(TablineState.TAB_BAR_HEIGHT))
                else
                    @as(i32, y);
                const row: i32 = if (row_h > 0) @divTrunc(@max(0, content_y), @as(i32, @intCast(row_h))) else 0;

                // Build modifier string
                const mod_buf = input.buildMouseModifiers(wParam);

                // Track mouse grid for mini window positioning (main window = grid 1)
                app.last_mouse_grid_id = 1;

                core.zonvie_core_send_mouse_input(
                    app.corep,
                    button,
                    "press",
                    @as([*:0]const u8, @ptrCast(&mod_buf)),
                    1, // grid_id
                    @max(0, row),
                    @max(0, col),
                );

                return 0;
            }
        },

        c.WM_LBUTTONUP, c.WM_RBUTTONUP, c.WM_MBUTTONUP => {
            if (getApp(hwnd)) |app| {
                // Extract position from lParam (needed for tabline check)
                const x_up: i16 = @bitCast(@as(u16, @truncate(@as(usize, @bitCast(lParam)))));
                const y_up: i16 = @bitCast(@as(u16, @truncate(@as(usize, @bitCast(lParam)) >> 16)));

                // Check tabline/sidebar drag end or area click
                if (app.ext_tabline_enabled) {
                    if (app.tabline_style == .titlebar) {
                        if (msg == c.WM_LBUTTONUP and (app.tabline_state.dragging_tab != null or y_up < app.scalePx(TablineState.TAB_BAR_HEIGHT))) {
                            tabline_mod.handleTablineMouseUp(app, hwnd, @as(c_int, x_up), @as(c_int, y_up));
                            return 0;
                        }
                    } else if (app.tabline_style == .sidebar) {
                        if (msg == c.WM_LBUTTONUP and (app.tabline_state.dragging_tab != null or
                            app.tabline_state.close_button_pressed != null or
                            app.tabline_state.new_tab_button_pressed))
                        {
                            tabline_mod.handleSidebarMouseUp(app, hwnd, @as(c_int, x_up), @as(c_int, y_up));
                            return 0;
                        }
                        // Check if event is in sidebar area — consume all buttons
                        var client_rect_sb2: c.RECT = undefined;
                        _ = c.GetClientRect(hwnd, &client_rect_sb2);
                        const sb_w = app.scalePx(@as(c_int, @intCast(app.sidebar_width_px)));
                        const in_sb = if (app.sidebar_position_right)
                            x_up >= @as(i16, @intCast(client_rect_sb2.right - sb_w))
                        else
                            x_up < @as(i16, @intCast(sb_w));
                        if (in_sb) {
                            if (msg == c.WM_LBUTTONUP) {
                                tabline_mod.handleSidebarMouseUp(app, hwnd, @as(c_int, x_up), @as(c_int, y_up));
                            }
                            return 0;
                        }
                    }
                }

                // Check if we were interacting with scrollbar (left button only)
                if (msg == c.WM_LBUTTONUP and (app.scrollbar_dragging or app.scrollbar_repeat_timer != 0)) {
                    scrollbar.scrollbarMouseUp(hwnd, app);
                    return 0;
                }

                // Release mouse capture
                _ = c.ReleaseCapture();

                // Determine button name
                const button: [*:0]const u8 = switch (msg) {
                    c.WM_LBUTTONUP => "left",
                    c.WM_RBUTTONUP => "right",
                    c.WM_MBUTTONUP => "middle",
                    else => "left",
                };

                app.mouse_button_held = 0;

                // Extract position from lParam
                const x: i16 = @bitCast(@as(u16, @truncate(@as(usize, @bitCast(lParam)))));
                const y: i16 = @bitCast(@as(u16, @truncate(@as(usize, @bitCast(lParam)) >> 16)));

                // Get cell dimensions
                app.mu.lockUncancelable(core.clock.io());
                const cell_w = app.cell_w_px;
                const cell_h = app.cell_h_px;
                const linespace = app.linespace_px;
                app.mu.unlock(core.clock.io());

                const row_h = cell_h + linespace;
                // When ext_tabline sidebar is enabled, subtract sidebar width to get content-relative X coordinate
                const content_x: i32 = if (app.ext_tabline_enabled and app.tabline_style == .sidebar and !app.sidebar_position_right)
                    @as(i32, x) - @as(i32, app.scalePx(@as(c_int, @intCast(app.sidebar_width_px))))
                else
                    @as(i32, x);
                const col: i32 = if (cell_w > 0) @divTrunc(@max(0, content_x), @as(i32, @intCast(cell_w))) else 0;
                // When ext_tabline titlebar is enabled, subtract tabbar height to get content-relative Y coordinate
                const content_y: i32 = if (app.ext_tabline_enabled and app.tabline_style == .titlebar and app.content_hwnd == null)
                    @as(i32, y) - @as(i32, app.scalePx(TablineState.TAB_BAR_HEIGHT))
                else
                    @as(i32, y);
                const row: i32 = if (row_h > 0) @divTrunc(@max(0, content_y), @as(i32, @intCast(row_h))) else 0;

                // Build modifier string
                const mod_buf = input.buildMouseModifiers(wParam);

                core.zonvie_core_send_mouse_input(
                    app.corep,
                    button,
                    "release",
                    @as([*:0]const u8, @ptrCast(&mod_buf)),
                    1, // grid_id
                    @max(0, row),
                    @max(0, col),
                );

                return 0;
            }
        },

        c.WM_XBUTTONDOWN => {
            if (getApp(hwnd)) |app| {
                _ = c.SetCapture(hwnd);

                const x: i16 = @bitCast(@as(u16, @truncate(@as(usize, @bitCast(lParam)))));
                const y: i16 = @bitCast(@as(u16, @truncate(@as(usize, @bitCast(lParam)) >> 16)));

                // HIWORD(wParam) contains XBUTTON1 (1) or XBUTTON2 (2)
                const x_button: u16 = @truncate(wParam >> 16);
                const button: [*:0]const u8 = if (x_button == 1) blk: {
                    app.mouse_button_held = 4;
                    break :blk "x1";
                } else blk: {
                    app.mouse_button_held = 5;
                    break :blk "x2";
                };

                app.mu.lockUncancelable(core.clock.io());
                const cell_w = app.cell_w_px;
                const cell_h = app.cell_h_px;
                const linespace = app.linespace_px;
                app.mu.unlock(core.clock.io());

                const row_h = cell_h + linespace;
                const content_x: i32 = if (app.ext_tabline_enabled and app.tabline_style == .sidebar and !app.sidebar_position_right)
                    @as(i32, x) - @as(i32, app.scalePx(@as(c_int, @intCast(app.sidebar_width_px))))
                else
                    @as(i32, x);
                const col: i32 = if (cell_w > 0) @divTrunc(@max(0, content_x), @as(i32, @intCast(cell_w))) else 0;
                const content_y: i32 = if (app.ext_tabline_enabled and app.tabline_style == .titlebar and app.content_hwnd == null)
                    @as(i32, y) - @as(i32, app.scalePx(TablineState.TAB_BAR_HEIGHT))
                else
                    @as(i32, y);
                const row: i32 = if (row_h > 0) @divTrunc(@max(0, content_y), @as(i32, @intCast(row_h))) else 0;

                const mod_buf = input.buildMouseModifiers(wParam);

                app.last_mouse_grid_id = 1;

                core.zonvie_core_send_mouse_input(
                    app.corep,
                    button,
                    "press",
                    @as([*:0]const u8, @ptrCast(&mod_buf)),
                    1,
                    @max(0, row),
                    @max(0, col),
                );

                // WM_XBUTTONDOWN requires returning TRUE
                return 1;
            }
        },

        c.WM_XBUTTONUP => {
            if (getApp(hwnd)) |app| {
                _ = c.ReleaseCapture();

                const x: i16 = @bitCast(@as(u16, @truncate(@as(usize, @bitCast(lParam)))));
                const y: i16 = @bitCast(@as(u16, @truncate(@as(usize, @bitCast(lParam)) >> 16)));

                const x_button: u16 = @truncate(wParam >> 16);
                const button: [*:0]const u8 = if (x_button == 1) "x1" else "x2";

                app.mouse_button_held = 0;

                app.mu.lockUncancelable(core.clock.io());
                const cell_w = app.cell_w_px;
                const cell_h = app.cell_h_px;
                const linespace = app.linespace_px;
                app.mu.unlock(core.clock.io());

                const row_h = cell_h + linespace;
                const content_x: i32 = if (app.ext_tabline_enabled and app.tabline_style == .sidebar and !app.sidebar_position_right)
                    @as(i32, x) - @as(i32, app.scalePx(@as(c_int, @intCast(app.sidebar_width_px))))
                else
                    @as(i32, x);
                const col: i32 = if (cell_w > 0) @divTrunc(@max(0, content_x), @as(i32, @intCast(cell_w))) else 0;
                const content_y: i32 = if (app.ext_tabline_enabled and app.tabline_style == .titlebar and app.content_hwnd == null)
                    @as(i32, y) - @as(i32, app.scalePx(TablineState.TAB_BAR_HEIGHT))
                else
                    @as(i32, y);
                const row: i32 = if (row_h > 0) @divTrunc(@max(0, content_y), @as(i32, @intCast(row_h))) else 0;

                const mod_buf = input.buildMouseModifiers(wParam);

                core.zonvie_core_send_mouse_input(
                    app.corep,
                    button,
                    "release",
                    @as([*:0]const u8, @ptrCast(&mod_buf)),
                    1,
                    @max(0, row),
                    @max(0, col),
                );

                // WM_XBUTTONUP requires returning TRUE
                return 1;
            }
        },

        c.WM_NCMOUSEMOVE => {
            // Handle non-client mouse move (e.g., in HTCAPTION area of tabline)
            if (getApp(hwnd)) |app| {
                if (app.ext_tabline_enabled and app.tabline_style == .titlebar) {
                    // Clear tabline hover states when mouse moves into NC area (empty tabline region)
                    if (app.tabline_state.hovered_tab != null or
                        app.tabline_state.hovered_close != null or
                        app.tabline_state.hovered_window_btn != null or
                        app.tabline_state.hovered_new_tab_btn)
                    {
                        app.tabline_state.hovered_tab = null;
                        app.tabline_state.hovered_close = null;
                        app.tabline_state.hovered_window_btn = null;
                        app.tabline_state.hovered_new_tab_btn = false;
                        // Invalidate tabline region to redraw without hover
                        var tabline_rect: c.RECT = .{
                            .left = 0,
                            .top = 0,
                            .right = 4096,
                            .bottom = app.scalePx(TablineState.TAB_BAR_HEIGHT),
                        };
                        _ = c.InvalidateRect(hwnd, &tabline_rect, 0);
                    }
                }
            }
            return c.DefWindowProcW(hwnd, msg, wParam, lParam);
        },

        c.WM_SETCURSOR => {
            if (getApp(hwnd)) |app| {
                const hit_test: u16 = @truncate(@as(usize, @bitCast(lParam)));
                if (hit_test == c.HTCLIENT) {
                    // Perform URL hit-test here (WM_SETCURSOR fires before WM_MOUSEMOVE)
                    var cursor_pt: c.POINT = undefined;
                    _ = c.GetCursorPos(&cursor_pt);
                    _ = c.ScreenToClient(hwnd, &cursor_pt);
                    const mx: i16 = @intCast(cursor_pt.x);
                    const my: i16 = @intCast(cursor_pt.y);

                    app.mu.lockUncancelable(core.clock.io());
                    const sc_cell_w = app.cell_w_px;
                    const sc_cell_h = app.cell_h_px;
                    const sc_ls = app.linespace_px;
                    app.mu.unlock(core.clock.io());

                    const sc_row_h = sc_cell_h + sc_ls;
                    const sc_cx: i32 = if (app.ext_tabline_enabled and app.tabline_style == .sidebar and !app.sidebar_position_right)
                        @as(i32, mx) - @as(i32, app.scalePx(@as(c_int, @intCast(app.sidebar_width_px))))
                    else
                        @as(i32, mx);
                    const sc_cy: i32 = if (app.ext_tabline_enabled and app.tabline_style == .titlebar and app.content_hwnd == null)
                        @as(i32, my) - @as(i32, app.scalePx(TablineState.TAB_BAR_HEIGHT))
                    else
                        @as(i32, my);

                    if (sc_cx < 0 or sc_cy < 0) {
                        app.cursor_is_hand = false;
                    } else if (app.corep) |corep| {
                        const global_col: i32 = if (sc_cell_w > 0) @divTrunc(sc_cx, @as(i32, @intCast(sc_cell_w))) else 0;
                        const global_row: i32 = if (sc_row_h > 0) @divTrunc(sc_cy, @as(i32, @intCast(sc_row_h))) else 0;

                        // Hit-test visible grids to find the correct grid and local coordinates
                        const vg = app.getVisibleGridsCached(corep);
                        var best_grid_id: i64 = 1;
                        var local_row: i32 = global_row;
                        var local_col: i32 = global_col;
                        var best_zindex: i64 = -1;
                        for (vg) |g| {
                            if (global_row >= g.start_row and global_row < g.start_row + g.rows and
                                global_col >= g.start_col and global_col < g.start_col + g.cols and
                                g.zindex > best_zindex)
                            {
                                best_zindex = g.zindex;
                                best_grid_id = g.grid_id;
                                local_row = global_row - g.start_row;
                                local_col = global_col - g.start_col;
                            }
                        }

                        const result = core.zonvie_core_try_cell_has_url(corep, best_grid_id, local_row, local_col);
                        if (result >= 0) {
                            app.cursor_is_hand = (result == 1);
                            app.url_cache_grid = best_grid_id;
                            app.url_cache_row = local_row;
                            app.url_cache_col = local_col;
                        } else {
                            // Lock unavailable: use cached value only for same cell, else reset
                            if (app.url_cache_grid != best_grid_id or app.url_cache_row != local_row or app.url_cache_col != local_col) {
                                app.cursor_is_hand = false;
                            }
                        }
                    }

                    if (app.cursor_is_hand) {
                        _ = c.SetCursor(loadSystemCursor(32649)); // IDC_HAND
                        return 1;
                    }
                }
            }
            return c.DefWindowProcW(hwnd, msg, wParam, lParam);
        },

        c.WM_MOUSEMOVE => {
            if (getApp(hwnd)) |app| {
                // Extract position from lParam
                const x: i16 = @bitCast(@as(u16, @truncate(@as(usize, @bitCast(lParam)))));
                const y: i16 = @bitCast(@as(u16, @truncate(@as(usize, @bitCast(lParam)) >> 16)));

                // Handle tabline/sidebar drag or hover (when ext_tabline enabled)
                if (app.ext_tabline_enabled) {
                    if (app.tabline_style == .titlebar) {
                        if (app.tabline_state.dragging_tab != null or y < app.scalePx(TablineState.TAB_BAR_HEIGHT)) {
                            tabline_mod.handleTablineMouseMoveInChild(app, hwnd, @as(c_int, x), @as(c_int, y));
                            if (app.tabline_state.dragging_tab != null) return 0;
                        } else {
                            if (app.tabline_state.hovered_tab != null or
                                app.tabline_state.hovered_close != null or
                                app.tabline_state.hovered_window_btn != null or
                                app.tabline_state.hovered_new_tab_btn)
                            {
                                app.tabline_state.hovered_tab = null;
                                app.tabline_state.hovered_close = null;
                                app.tabline_state.hovered_window_btn = null;
                                app.tabline_state.hovered_new_tab_btn = false;
                                var tabline_rect: c.RECT = .{
                                    .left = 0,
                                    .top = 0,
                                    .right = 4096,
                                    .bottom = app.scalePx(TablineState.TAB_BAR_HEIGHT),
                                };
                                _ = c.InvalidateRect(hwnd, &tabline_rect, 0);
                            }
                        }
                    } else if (app.tabline_style == .sidebar) {
                        var client_rect_sb3: c.RECT = undefined;
                        _ = c.GetClientRect(hwnd, &client_rect_sb3);
                        const sb_w3 = app.scalePx(@as(c_int, @intCast(app.sidebar_width_px)));
                        const in_sb3 = if (app.sidebar_position_right)
                            x >= @as(i16, @intCast(client_rect_sb3.right - sb_w3))
                        else
                            x < @as(i16, @intCast(sb_w3));

                        if (app.tabline_state.dragging_tab != null or in_sb3) {
                            tabline_mod.handleSidebarMouseMove(app, hwnd, @as(c_int, x), @as(c_int, y));
                            // Consume event: sidebar area is UI, not Neovim editor input
                            return 0;
                        } else {
                            if (app.tabline_state.hovered_tab != null or
                                app.tabline_state.hovered_close != null or
                                app.tabline_state.hovered_new_tab_btn)
                            {
                                app.tabline_state.hovered_tab = null;
                                app.tabline_state.hovered_close = null;
                                app.tabline_state.hovered_new_tab_btn = false;
                                _ = c.InvalidateRect(hwnd, null, 0);
                            }
                        }
                    }
                }

                // Handle scrollbar dragging
                if (app.scrollbar_dragging) {
                    scrollbar.scrollbarMouseMove(hwnd, app, @as(i32, y));
                    return 0;
                }

                // Check hover mode scrollbar
                if (app.config.scrollbar.enabled and app.config.scrollbar.isHover()) {
                    var client: c.RECT = undefined;
                    _ = c.GetClientRect(hwnd, &client);
                    const hit = scrollbar.scrollbarHitTest(app, client.right, client.bottom, @as(i32, x), @as(i32, y));
                    const in_scrollbar = hit != .none;

                    if (in_scrollbar and !app.scrollbar_hover) {
                        app.scrollbar_hover = true;
                        scrollbar.showScrollbar(hwnd, app);
                    } else if (!in_scrollbar and app.scrollbar_hover) {
                        app.scrollbar_hover = false;
                        if (!app.config.scrollbar.isAlways() and !app.config.scrollbar.isScroll()) {
                            scrollbar.hideScrollbar(hwnd, app);
                        }
                    }
                }

                // Only send drag events if a button is held
                if (app.mouse_button_held == 0) return c.DefWindowProcW(hwnd, msg, wParam, lParam);

                const button: [*:0]const u8 = switch (app.mouse_button_held) {
                    1 => "left",
                    2 => "right",
                    3 => "middle",
                    4 => "x1",
                    5 => "x2",
                    else => return c.DefWindowProcW(hwnd, msg, wParam, lParam),
                };

                // Get cell dimensions
                app.mu.lockUncancelable(core.clock.io());
                const cell_w = app.cell_w_px;
                const cell_h = app.cell_h_px;
                const linespace = app.linespace_px;
                app.mu.unlock(core.clock.io());

                const row_h = cell_h + linespace;
                // When ext_tabline sidebar is enabled, subtract sidebar width to get content-relative X coordinate
                const content_x: i32 = if (app.ext_tabline_enabled and app.tabline_style == .sidebar and !app.sidebar_position_right)
                    @as(i32, x) - @as(i32, app.scalePx(@as(c_int, @intCast(app.sidebar_width_px))))
                else
                    @as(i32, x);
                const col: i32 = if (cell_w > 0) @divTrunc(@max(0, content_x), @as(i32, @intCast(cell_w))) else 0;
                // When ext_tabline titlebar is enabled, subtract tabbar height to get content-relative Y coordinate
                const content_y: i32 = if (app.ext_tabline_enabled and app.tabline_style == .titlebar and app.content_hwnd == null)
                    @as(i32, y) - @as(i32, app.scalePx(TablineState.TAB_BAR_HEIGHT))
                else
                    @as(i32, y);
                const row: i32 = if (row_h > 0) @divTrunc(@max(0, content_y), @as(i32, @intCast(row_h))) else 0;

                // Build modifier string
                const mod_buf = input.buildMouseModifiers(wParam);

                core.zonvie_core_send_mouse_input(
                    app.corep,
                    button,
                    "drag",
                    @as([*:0]const u8, @ptrCast(&mod_buf)),
                    1, // grid_id
                    @max(0, row),
                    @max(0, col),
                );

                return 0;
            }
        },

        c.WM_DROPFILES => {
            const hDrop: c.HDROP = @ptrFromInt(@as(usize, wParam));
            defer c.DragFinish(hDrop);
            if (getApp(hwnd)) |app| handleDroppedFiles(app, hDrop, false);
            return 0;
        },

        c.WM_COPYDATA => {
            // Single-instance file open: a second `zonvie <file>` process found
            // this running instance and forwarded a pre-built Ex command (e.g.
            // "tab drop /abs/path"). See main.zig's forwarding path. The payload
            // is the bare command bytes (no leading ':'); an empty payload means
            // "just bring me to the front".
            const cds: *const c.COPYDATASTRUCT = @ptrFromInt(@as(usize, @bitCast(lParam)));
            if (cds.dwData != ZONVIE_COPYDATA_MAGIC) {
                return c.DefWindowProcW(hwnd, msg, wParam, lParam);
            }
            if (getApp(hwnd)) |app| {
                // Bring the window to the front, also un-hiding it if the
                // instance was hidden to the tray (close_to_tray) or minimized.
                if (app.hwnd) |main_hwnd| {
                    restoreFromTray(main_hwnd);
                }
                if (cds.cbData > 0 and cds.lpData != null) {
                    if (app.corep) |corep| {
                        const bytes: [*]const u8 = @ptrCast(cds.lpData.?);
                        app_mod.zonvie_core_send_command(corep, bytes, @intCast(cds.cbData));
                    }
                }
            }
            return c.TRUE;
        },

        c.WM_CLOSE => {
            // Intercept window close to check for unsaved buffers
            if (getApp(hwnd)) |app| {
                // If Neovim already exited (e.g., from :qa!), proceed with normal close
                if (app.neovim_exited.load(.acquire)) {
                    if (applog.isEnabled()) applog.appLog("[win] WM_CLOSE: neovim already exited, proceeding with close\n", .{});
                    return c.DefWindowProcW(hwnd, msg, wParam, lParam);
                }
                // Close-to-tray ([server] close_to_tray): hide the window to the
                // notification area instead of quitting; Neovim keeps running and
                // the tray icon restores it. The tray menu's "Quit" sets
                // tray_quit_requested to skip this and fall through to the real
                // graceful quit below. Consume the flag (read once, then reset) so
                // a cancelled graceful quit does not permanently disable
                // close-to-tray for the rest of the session.
                const tray_quit = app.tray_quit_requested;
                app.tray_quit_requested = false;
                if (app.config.server.close_to_tray and !tray_quit) {
                    // Ensure the tray icon is registered BEFORE hiding. It is
                    // normally created ~50ms after first show (TIMER_TRAY_INIT); if
                    // the user closes before that fires, create it here. If it
                    // cannot be added, do NOT hide — fall through to a normal quit
                    // so the process is never left behind an invisible window with
                    // no way back.
                    if (app.tray_icon == null) app.tray_icon = TrayIcon.init(hwnd);
                    const tray_ready = if (app.tray_icon) |*tray| tray.add() else false;
                    if (tray_ready) {
                        _ = c.ShowWindow(hwnd, c.SW_HIDE);
                        if (applog.isEnabled()) applog.appLog("[win] WM_CLOSE: hidden to tray (close_to_tray)\n", .{});
                        return 0;
                    }
                    if (applog.isEnabled()) applog.appLog("[win] WM_CLOSE: tray icon unavailable, proceeding with quit\n", .{});
                }
                // If already waiting for quit, don't send another request
                if (app.quit_pending) {
                    if (applog.isEnabled()) applog.appLog("[win] WM_CLOSE: quit already pending, ignoring\n", .{});
                    return 0;
                }
                if (app.corep) |corep| {
                    if (applog.isEnabled()) applog.appLog("[win] WM_CLOSE: requesting quit via core (timeout={}ms)\n", .{QUIT_TIMEOUT_MS});
                    app.quit_pending = true;
                    app.quit_timeout_fired = false; // Reset for new quit request
                    // Start timeout timer
                    _ = c.SetTimer(hwnd, TIMER_QUIT_TIMEOUT, QUIT_TIMEOUT_MS, null);
                    core.zonvie_core_request_quit(corep);
                    return 0; // Don't close yet - wait for quit confirmation
                }
            }
            // If no core, allow normal close
            return c.DefWindowProcW(hwnd, msg, wParam, lParam);
        },

        c.WM_NCDESTROY => {
            if (getApp(hwnd)) |app| {
                smooth_session.shutdown(app);
                // End the recovery lifecycle before removing HWND ownership.
                // Queued messages are rejected by the wake cookie, while the
                // durable deadline and USER timer are cancelled explicitly.
                app.device_lost_recovery_cancelled = true;
                app.device_lost_recover_posted = false;
                app.device_lost_retry_needed = false;
                app.device_lost_retry_deadline_ms = 0;
                _ = c.KillTimer(hwnd, app_mod.TIMER_DEVICE_LOST_RETRY);

                // Clear userdata first (prevent access by subsequent messages/re-entry)
                _ = c.SetWindowLongPtrW(hwnd, c.GWLP_USERDATA, 0);

                // If owned_by_hwnd, this is the only destroy point
                if (app.owned_by_hwnd) {
                    if (app.hasActiveOperation()) {
                        // The outer paint/Present/recovery/create frame still
                        // owns App and renderer pointers. Defer destruction
                        // until that last active operation returns.
                        app.pending_destroy_after_active_operation = true;
                        return c.DefWindowProcW(hwnd, msg, wParam, lParam);
                    }
                    app.owned_by_hwnd = false; // Safety

                    // Safely clean up renderer/core/etc (deinit is robust even with partial init)
                    app.deinit();

                    const alloc = app.alloc;
                    alloc.destroy(app);
                }
            }
            return c.DefWindowProcW(hwnd, msg, wParam, lParam);
        },

        c.WM_DESTROY => {
            // Stop the theme-watcher worker before the HWND goes away so the
            // last PostMessageW target is still valid up to this point.
            stopThemeWatcher();
            // Remove tray icon before quitting
            if (getApp(hwnd)) |app| {
                if (app.tray_icon) |*tray| {
                    tray.remove();
                }
                // Revoke before the HWND dies; OLE holds a reference until then.
                if (app.main_drop_target) |target| {
                    drop_target.revoke(hwnd, @ptrCast(@alignCast(target)));
                    app.main_drop_target = null;
                }
            }
            // Nvy style: PostQuitMessage(0). The actual exit code is
            // pulled from app_mod.g_exit_code by wWinMain after the
            // message loop exits, so the wParam here is irrelevant.
            if (applog.isEnabled()) applog.appLog("[win] WM_DESTROY: calling PostQuitMessage(0)\n", .{});
            c.PostQuitMessage(0);
            return 0;
        },

        // When the acrylic backdrop is in use, force DWM to keep treating the
        // window as active so the backdrop stays blurred after focus is lost
        // (Win11 renders inactive backdrops without the blur). Gated on blur
        // alone so it matches the backdrop application and the external windows.
        c.WM_NCACTIVATE => {
            if (getApp(hwnd)) |app| {
                if (app.config.window.blur) {
                    return c.DefWindowProcW(hwnd, msg, 1, lParam);
                }
            }
            return c.DefWindowProcW(hwnd, msg, wParam, lParam);
        },

        // Restore the drop shadow / backdrop on activation. Modes:
        //   - blur on  -> acrylic system backdrop (sheet-of-glass frame); DWM
        //     draws the shadow and the frosted blur shows through translucent
        //     content. Applied in every tabline mode so it matches the core's
        //     blur flag and the external windows (the backdrop works on a
        //     standard-framed window too, as the external floats demonstrate).
        //   - opaque + custom titlebar -> the classic 1px frame-extend shadow
        //     trick to restore the shadow the borderless custom frame loses.
        //   - translucent, no blur -> no frame extend: a real frame backdrop
        //     would defeat per-pixel alpha and make the window opaque, so this
        //     mode renders transparent without a shadow.
        c.WM_ACTIVATE => {
            if (getApp(hwnd)) |app| {
                if (app.config.window.blur) {
                    applyWindowBackdrop(hwnd);
                } else if (app.ext_tabline_enabled and app.tabline_style == .titlebar and app.config.window.opacity >= 1.0) {
                    const margins = c.MARGINS{ .cxLeftWidth = 0, .cxRightWidth = 0, .cyTopHeight = 0, .cyBottomHeight = 1 };
                    _ = c.DwmExtendFrameIntoClientArea(hwnd, &margins);
                }
            }
            return c.DefWindowProcW(hwnd, msg, wParam, lParam);
        },

        c.WM_ACTIVATEAPP => {
            // Notify Neovim of focus change (triggers FocusGained/FocusLost autocmds)
            if (getApp(hwnd)) |app| {
                const is_activating = wParam != 0;
                if (app.corep) |corep| {
                    core.zonvie_core_set_focus(corep, is_activating);
                }
                if (!is_activating) {
                    // App is being deactivated - hide mini and message windows
                    inline for ([_]MiniWindowId{ .showmode, .showcmd, .ruler }) |id| {
                        const idx = @intFromEnum(id);
                        if (app.mini_windows[idx].hwnd) |mini_hwnd| {
                            _ = c.ShowWindow(mini_hwnd, c.SW_HIDE);
                        }
                    }
                    if (app.message_window) |msg_win| {
                        _ = c.ShowWindow(msg_win.hwnd, c.SW_HIDE);
                    }
                    // Hide special external windows (cmdline, popupmenu, msg_show, msg_history)
                    app.mu.lockUncancelable(core.clock.io());
                    defer app.mu.unlock(core.clock.io());
                    var ext_it = app.external_windows.iterator();
                    while (ext_it.next()) |entry| {
                        const grid_id = entry.key_ptr.*;
                        if (grid_id == CMDLINE_GRID_ID) {
                            // The cmdline stays visible so a file can be
                            // dragged onto it from Explorer, which necessarily
                            // deactivates this app. Drop WS_EX_TOPMOST instead
                            // so it does not hover above whatever the user
                            // switched to (mirrors the macOS .floating ->
                            // .normal demotion in setCmdlineWindowActive).
                            setExternalWindowTopmost(entry.value_ptr.*.hwnd, false);
                            continue;
                        }
                        // Only hide special windows
                        if (grid_id == POPUPMENU_GRID_ID or grid_id == MESSAGE_GRID_ID or grid_id == MSG_HISTORY_GRID_ID) {
                            _ = c.ShowWindow(entry.value_ptr.*.hwnd, c.SW_HIDE);
                        }
                    }
                } else {
                    // App is being activated - disable IME if configured
                    if (app.config.input.ime_disable_on_activate) {
                        input.setIMEOff(hwnd);
                    }
                    // App is being activated - show special external windows
                    app.mu.lockUncancelable(core.clock.io());
                    defer app.mu.unlock(core.clock.io());
                    var ext_it = app.external_windows.iterator();
                    while (ext_it.next()) |entry| {
                        const grid_id = entry.key_ptr.*;
                        if (grid_id == CMDLINE_GRID_ID) {
                            // Never hidden on deactivate, so only the topmost
                            // demotion has to be undone.
                            setExternalWindowTopmost(entry.value_ptr.*.hwnd, true);
                            continue;
                        }
                        if (grid_id == POPUPMENU_GRID_ID or grid_id == MESSAGE_GRID_ID or grid_id == MSG_HISTORY_GRID_ID) {
                            _ = c.ShowWindow(entry.value_ptr.*.hwnd, 8); // SW_SHOWNA
                        }
                    }
                }
            }
            return 0;
        },

        c.WM_MOUSELEAVE => {
            // Mouse left the client area - clear sidebar hover states
            if (getApp(hwnd)) |app| {
                if (app.ext_tabline_enabled and app.tabline_style == .sidebar) {
                    if (app.tabline_state.hovered_tab != null or
                        app.tabline_state.hovered_close != null or
                        app.tabline_state.hovered_new_tab_btn)
                    {
                        app.tabline_state.hovered_tab = null;
                        app.tabline_state.hovered_close = null;
                        app.tabline_state.hovered_new_tab_btn = false;
                        // Invalidate sidebar region
                        var client_rect: c.RECT = undefined;
                        _ = c.GetClientRect(hwnd, &client_rect);
                        const sidebar_w = app.scalePx(@as(c_int, @intCast(app.sidebar_width_px)));
                        var sidebar_rect: c.RECT = .{
                            .left = if (app.sidebar_position_right) client_rect.right - sidebar_w else 0,
                            .top = 0,
                            .right = if (app.sidebar_position_right) client_rect.right else sidebar_w,
                            .bottom = client_rect.bottom,
                        };
                        _ = c.InvalidateRect(hwnd, &sidebar_rect, 0);
                    }
                }
            }
            return 0;
        },

        c.WM_CAPTURECHANGED => {
            // Mouse capture lost - cancel any tabline/sidebar drag or button press
            if (getApp(hwnd)) |app| {
                // Scrollbar drag and track-repeat are both armed on button-down
                // and cleared only in scrollbarMouseUp. With capture stolen,
                // WM_LBUTTONUP never arrives here: the repeat timer would keep
                // issuing page scrolls, and scrollbar_dragging would leave every
                // later button-up-less WM_MOUSEMOVE scrolling the buffer. The
                // drag is cancelled rather than committed — its pending line was
                // never confirmed by a mouse-up.
                if (app.scrollbar_dragging) {
                    app.scrollbar_dragging = false;
                    app.scrollbar_pending_line = -1;
                }
                if (app.scrollbar_repeat_timer != 0 or app.scrollbar_repeat_dir != 0) {
                    _ = c.KillTimer(hwnd, TIMER_SCROLLBAR_REPEAT);
                    app.scrollbar_repeat_timer = 0;
                    app.scrollbar_repeat_dir = 0;
                }
                if (app.ext_tabline_enabled) {
                    const had_state = app.tabline_state.dragging_tab != null or
                        app.tabline_state.close_button_pressed != null or
                        app.tabline_state.new_tab_button_pressed or
                        app.tabline_state.pressed_window_btn != null;

                    if (had_state) {
                        if (applog.isEnabled()) applog.appLog("[tabline] WM_CAPTURECHANGED (parent): cancelling drag/button!\n", .{});
                        tabline_mod.destroyDragPreviewWindow(app);
                        app.tabline_state.cancelDrag();
                        app.tabline_state.close_button_pressed = null;
                        app.tabline_state.new_tab_button_pressed = false;
                        app.tabline_state.pressed_window_btn = null;
                        // Invalidate the relevant tab area
                        var client_rect: c.RECT = undefined;
                        _ = c.GetClientRect(hwnd, &client_rect);
                        if (app.tabline_style == .sidebar) {
                            const sidebar_w = app.scalePx(@as(c_int, @intCast(app.sidebar_width_px)));
                            var sidebar_rect: c.RECT = .{
                                .left = if (app.sidebar_position_right) client_rect.right - sidebar_w else 0,
                                .top = 0,
                                .right = if (app.sidebar_position_right) client_rect.right else sidebar_w,
                                .bottom = client_rect.bottom,
                            };
                            _ = c.InvalidateRect(hwnd, &sidebar_rect, 0);
                        } else {
                            var tabline_rect: c.RECT = .{
                                .left = 0,
                                .top = 0,
                                .right = client_rect.right,
                                .bottom = app.scalePx(TablineState.TAB_BAR_HEIGHT),
                            };
                            _ = c.InvalidateRect(hwnd, &tabline_rect, 0);
                        }
                    }
                }
            }
            return 0;
        },

        else => {},
    }
    return c.DefWindowProcW(hwnd, msg, wParam, lParam);
}
