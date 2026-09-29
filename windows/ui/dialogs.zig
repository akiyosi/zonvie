const std = @import("std");
const core = @import("zonvie_core");
const app_mod = @import("../app.zig");
const App = app_mod.App;
const c = app_mod.c;
const applog = app_mod.applog;
const window_mod = @import("../window.zig");

// --- SSH Password Dialog state ---

// Global state for password dialog
var g_password_dialog_result: bool = false;
var g_password_dialog_hwnd_edit: ?c.HWND = null;
var g_password_dialog_output: ?*[256]u16 = null;

// ============================================================
// Devcontainer Progress Dialog
// ============================================================

var g_devcontainer_dialog_hwnd: ?c.HWND = null;
var g_devcontainer_label_hwnd: ?c.HWND = null;
pub var g_devcontainer_up_done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);
pub var g_devcontainer_up_success: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

/// Handle SSH auth prompt on UI thread
pub fn handleSSHAuthPromptOnUIThread(app: *App) void {
    // Take the prompt: the core thread frees and replaces the field, and this
    // handler blocks on console input while using it.
    app.mu.lockUncancelable(core.clock.io());
    const prompt_owned = app.ssh_prompt_owned;
    app.ssh_prompt_owned = null;
    app.mu.unlock(core.clock.io());
    defer if (prompt_owned) |buf| app.alloc.free(buf);

    // Check if we have pre-entered password from initial dialog
    if (app.ssh_password) |password| {
        if (applog.isEnabled()) applog.appLog("[win] ssh_auth_prompt_ui: using pre-entered password ({d} chars)\n", .{password.len});

        // Send pre-entered password + newline to stdin
        if (app.corep != null) {
            app_mod.zonvie_core_send_stdin_data(app.corep, password.ptr, @intCast(password.len));
            // Send newline to confirm password
            app_mod.zonvie_core_send_stdin_data(app.corep, "\n", 1);
        }

        // Clear password after use (security)
        @memset(@constCast(password), 0);
        app.alloc.free(password);
        app.ssh_password = null;
        return;
    }

    // No pre-entered password, show dialog
    if (applog.isEnabled()) applog.appLog("[win] ssh_auth_prompt_ui: showing dialog\n", .{});

    // Allocate console for password input (if not already allocated)
    _ = c.AllocConsole();

    // Get console handles
    const hConsoleOut = c.GetStdHandle(c.STD_OUTPUT_HANDLE);
    const hConsoleIn = c.GetStdHandle(c.STD_INPUT_HANDLE);

    if (hConsoleOut == c.INVALID_HANDLE_VALUE or hConsoleIn == c.INVALID_HANDLE_VALUE) {
        if (applog.isEnabled()) applog.appLog("[win] ssh_auth_prompt_ui: failed to get console handles\n", .{});
        return;
    }

    // Write prompt to console
    var written: c.DWORD = 0;
    if (prompt_owned) |buf| {
        _ = c.WriteConsoleA(hConsoleOut, buf.ptr, @intCast(buf.len), &written, null);
        _ = c.WriteConsoleA(hConsoleOut, " ", 1, &written, null);
    }

    // Disable echo for password input
    var console_mode: c.DWORD = 0;
    _ = c.GetConsoleMode(hConsoleIn, &console_mode);
    _ = c.SetConsoleMode(hConsoleIn, console_mode & ~@as(c.DWORD, c.ENABLE_ECHO_INPUT));

    // Read password
    var password_buf: [256]u8 = undefined;
    var read: c.DWORD = 0;
    _ = c.ReadConsoleA(hConsoleIn, &password_buf, 255, &read, null);

    // Restore console mode
    _ = c.SetConsoleMode(hConsoleIn, console_mode);

    // Write newline after password entry
    _ = c.WriteConsoleA(hConsoleOut, "\r\n", 2, &written, null);

    if (applog.isEnabled()) applog.appLog("[win] ssh_auth_prompt_ui: password entered, read={d} bytes\n", .{read});

    // Send password to stdin via core
    if (read > 0 and app.corep != null) {
        app_mod.zonvie_core_send_stdin_data(app.corep, &password_buf, @intCast(read));
    }

    // Hide console after password entry
    _ = c.FreeConsole();
}

/// A dialog: registers `class_name` with `proc`, centres a `w` x `h` window
/// on the monitor `owner` is on (the primary one with no owner) and matches
/// the OS titlebar theme. `parent` and `create_param` go to CreateWindowExW.
/// Null when creation failed.
fn createCenteredDialog(class_name: [*:0]const u16, proc: c.WNDPROC, title: [*:0]const u16, style: c.DWORD, ex_style: c.DWORD, w: i32, h: i32, owner: ?c.HWND, parent: c.HWND, create_param: ?*anyopaque) c.HWND {
    var wc: c.WNDCLASSEXW = std.mem.zeroes(c.WNDCLASSEXW);
    wc.cbSize = @sizeOf(c.WNDCLASSEXW);
    wc.lpfnWndProc = proc;
    wc.hInstance = c.GetModuleHandleW(null);
    wc.hCursor = c.LoadCursorW(null, @ptrFromInt(32512)); // IDC_ARROW
    wc.hbrBackground = @ptrFromInt(@as(usize, 16)); // COLOR_BTNFACE + 1
    wc.lpszClassName = class_name;
    _ = c.RegisterClassExW(&wc);

    const area = app_mod.monitorWorkArea(owner);
    const x = area.left + @divTrunc(area.right - area.left - w, 2);
    const y = area.top + @divTrunc(area.bottom - area.top - h, 2);
    const hwnd = c.CreateWindowExW(
        ex_style,
        class_name,
        title,
        style,
        x,
        y,
        w,
        h,
        parent,
        null,
        c.GetModuleHandleW(null),
        create_param,
    );
    if (hwnd != null) window_mod.applyOsTitlebarTheme(hwnd);
    return hwnd;
}

/// Simple password input dialog without username field. Runs in the
/// ssh-askpass helper process, which has no app window to centre on.
pub fn showPasswordInputDialog(prompt: *const [256]u16, password_out: *[256]u16) bool {
    const class_name = std.unicode.utf8ToUtf16LeStringLiteral("ZonviePasswordDialog");

    // Store output pointer
    g_password_dialog_output = password_out;
    g_password_dialog_result = false;

    const hwnd = createCenteredDialog(
        class_name,
        passwordDialogProc,
        std.unicode.utf8ToUtf16LeStringLiteral("SSH Authentication"),
        c.WS_POPUP | c.WS_CAPTION | c.WS_SYSMENU,
        c.WS_EX_DLGMODALFRAME | c.WS_EX_TOPMOST,
        420,
        180,
        null,
        null,
        null,
    );
    if (hwnd == null) return false;

    // Create prompt label
    _ = c.CreateWindowExW(
        0,
        std.unicode.utf8ToUtf16LeStringLiteral("STATIC"),
        prompt,
        c.WS_CHILD | c.WS_VISIBLE,
        20,
        15,
        360,
        40,
        hwnd,
        null,
        c.GetModuleHandleW(null),
        null,
    );

    // Create password edit field
    g_password_dialog_hwnd_edit = c.CreateWindowExW(
        c.WS_EX_CLIENTEDGE,
        std.unicode.utf8ToUtf16LeStringLiteral("EDIT"),
        std.unicode.utf8ToUtf16LeStringLiteral(""),
        c.WS_CHILD | c.WS_VISIBLE | c.WS_TABSTOP | c.ES_PASSWORD | c.ES_AUTOHSCROLL,
        20,
        55,
        360,
        25,
        hwnd,
        null,
        c.GetModuleHandleW(null),
        null,
    );

    // Create OK button
    const ok_btn = c.CreateWindowExW(
        0,
        std.unicode.utf8ToUtf16LeStringLiteral("BUTTON"),
        std.unicode.utf8ToUtf16LeStringLiteral("OK"),
        c.WS_CHILD | c.WS_VISIBLE | c.WS_TABSTOP | c.BS_DEFPUSHBUTTON,
        200,
        95,
        80,
        30,
        hwnd,
        null,
        c.GetModuleHandleW(null),
        null,
    );
    if (ok_btn) |btn| {
        _ = c.SetWindowLongPtrW(btn, c.GWLP_ID, 1); // ID = 1 for OK
    }

    // Create Cancel button
    const cancel_btn = c.CreateWindowExW(
        0,
        std.unicode.utf8ToUtf16LeStringLiteral("BUTTON"),
        std.unicode.utf8ToUtf16LeStringLiteral("Cancel"),
        c.WS_CHILD | c.WS_VISIBLE | c.WS_TABSTOP,
        300,
        95,
        80,
        30,
        hwnd,
        null,
        c.GetModuleHandleW(null),
        null,
    );
    if (cancel_btn) |btn| {
        _ = c.SetWindowLongPtrW(btn, c.GWLP_ID, 2); // ID = 2 for Cancel
    }

    // Set focus to password field
    if (g_password_dialog_hwnd_edit) |edit_hwnd| {
        _ = c.SetFocus(edit_hwnd);
    }

    // Show window
    _ = c.ShowWindow(hwnd, c.SW_SHOW);
    _ = c.UpdateWindow(hwnd);

    // Message loop
    var msg: c.MSG = undefined;
    while (c.GetMessageW(&msg, null, 0, 0) > 0) {
        if (c.IsDialogMessageW(hwnd, &msg) == 0) {
            _ = c.TranslateMessage(&msg);
            _ = c.DispatchMessageW(&msg);
        }
        // Check if dialog was closed
        if (c.IsWindow(hwnd) == 0) break;
    }

    // Cleanup
    _ = c.UnregisterClassW(class_name, c.GetModuleHandleW(null));
    g_password_dialog_hwnd_edit = null;
    g_password_dialog_output = null;

    return g_password_dialog_result;
}

fn passwordDialogProc(hwnd: c.HWND, msg: c.UINT, wParam: c.WPARAM, lParam: c.LPARAM) callconv(.winapi) c.LRESULT {
    switch (msg) {
        c.WM_COMMAND => {
            const id = wParam & 0xFFFF;
            if (id == 1) {
                // OK button clicked
                if (g_password_dialog_hwnd_edit) |edit_hwnd| {
                    if (g_password_dialog_output) |output| {
                        _ = c.GetWindowTextW(edit_hwnd, output, 256);
                        g_password_dialog_result = true;
                    }
                }
                _ = c.DestroyWindow(hwnd);
                return 0;
            } else if (id == 2) {
                // Cancel button clicked
                g_password_dialog_result = false;
                _ = c.DestroyWindow(hwnd);
                return 0;
            }
        },
        c.WM_CLOSE => {
            g_password_dialog_result = false;
            _ = c.DestroyWindow(hwnd);
            return 0;
        },
        c.WM_DESTROY => {
            c.PostQuitMessage(0);
            return 0;
        },
        c.WM_SETTINGCHANGE, c.WM_THEMECHANGED => return window_mod.themeMessage(hwnd, msg, wParam, lParam).?,
        else => {},
    }
    return c.DefWindowProcW(hwnd, msg, wParam, lParam);
}

/// `owner` is the main window; the dialog centres on its monitor.
pub fn showDevcontainerProgressDialog(owner: c.HWND, label_text: [*:0]const u16) void {
    const hwnd = createCenteredDialog(
        std.unicode.utf8ToUtf16LeStringLiteral("ZonvieDevcontainerProgress"),
        devcontainerDialogProc,
        std.unicode.utf8ToUtf16LeStringLiteral("Devcontainer"),
        c.WS_POPUP | c.WS_CAPTION,
        c.WS_EX_DLGMODALFRAME | c.WS_EX_TOPMOST,
        300,
        80,
        owner,
        null,
        null,
    );
    if (hwnd == null) return;
    g_devcontainer_dialog_hwnd = hwnd;

    // Create label
    g_devcontainer_label_hwnd = c.CreateWindowExW(
        0,
        std.unicode.utf8ToUtf16LeStringLiteral("STATIC"),
        label_text,
        c.WS_CHILD | c.WS_VISIBLE | c.SS_CENTER,
        20,
        20,
        260,
        25,
        hwnd,
        null,
        c.GetModuleHandleW(null),
        null,
    );

    // Show window
    _ = c.ShowWindow(hwnd, c.SW_SHOW);
    _ = c.UpdateWindow(hwnd);

    if (applog.isEnabled()) applog.appLog("[win] devcontainer progress dialog shown\n", .{});
}

pub fn updateDevcontainerProgressLabel(label_text: [*:0]const u16) void {
    if (g_devcontainer_label_hwnd) |label_hwnd| {
        _ = c.SetWindowTextW(label_hwnd, label_text);
    }
}

pub fn hideDevcontainerProgressDialog() void {
    if (g_devcontainer_dialog_hwnd) |hwnd| {
        _ = c.DestroyWindow(hwnd);
        g_devcontainer_dialog_hwnd = null;
        g_devcontainer_label_hwnd = null;
        if (applog.isEnabled()) applog.appLog("[win] devcontainer progress dialog hidden\n", .{});
    }
}

fn devcontainerDialogProc(hwnd: c.HWND, msg: c.UINT, wParam: c.WPARAM, lParam: c.LPARAM) callconv(.winapi) c.LRESULT {
    switch (msg) {
        c.WM_DESTROY => {
            g_devcontainer_dialog_hwnd = null;
            g_devcontainer_label_hwnd = null;
            return 0;
        },
        c.WM_SETTINGCHANGE, c.WM_THEMECHANGED => return window_mod.themeMessage(hwnd, msg, wParam, lParam).?,
        else => {},
    }
    return c.DefWindowProcW(hwnd, msg, wParam, lParam);
}

/// Check if Docker is running by executing `docker info`
pub fn isDockerRunning() bool {
    var si: c.STARTUPINFOA = std.mem.zeroes(c.STARTUPINFOA);
    si.cb = @sizeOf(c.STARTUPINFOA);
    si.dwFlags = c.STARTF_USESHOWWINDOW;
    si.wShowWindow = c.SW_HIDE;

    var pi: c.PROCESS_INFORMATION = std.mem.zeroes(c.PROCESS_INFORMATION);

    var cmd_buf: [256]u8 = undefined;
    @memcpy(cmd_buf[0..21], "cmd /c docker info >nul 2>&1"[0..21]);
    cmd_buf[21] = 0;

    const create_result = c.CreateProcessA(
        null,
        &cmd_buf,
        null,
        null,
        0,
        c.CREATE_NO_WINDOW,
        null,
        null,
        &si,
        &pi,
    );

    if (create_result == 0) {
        return false;
    }

    _ = c.WaitForSingleObject(pi.hProcess, 10000); // 10 second timeout

    var exit_code: c.DWORD = 1;
    _ = c.GetExitCodeProcess(pi.hProcess, &exit_code);

    _ = c.CloseHandle(pi.hProcess);
    _ = c.CloseHandle(pi.hThread);

    return exit_code == 0;
}

/// Start Docker Desktop
pub fn startDockerDesktop() bool {
    if (applog.isEnabled()) applog.appLog("[win] Starting Docker Desktop...\n", .{});

    var si: c.STARTUPINFOA = std.mem.zeroes(c.STARTUPINFOA);
    si.cb = @sizeOf(c.STARTUPINFOA);

    var pi: c.PROCESS_INFORMATION = std.mem.zeroes(c.PROCESS_INFORMATION);

    // Try common Docker Desktop paths
    const docker_paths = [_][]const u8{
        "C:\\Program Files\\Docker\\Docker\\Docker Desktop.exe",
        "C:\\Program Files (x86)\\Docker\\Docker\\Docker Desktop.exe",
    };

    for (docker_paths) |path| {
        var path_buf: [512]u8 = undefined;
        @memcpy(path_buf[0..path.len], path);
        path_buf[path.len] = 0;

        const create_result = c.CreateProcessA(
            &path_buf,
            null,
            null,
            null,
            0,
            0,
            null,
            null,
            &si,
            &pi,
        );

        if (create_result != 0) {
            _ = c.CloseHandle(pi.hProcess);
            _ = c.CloseHandle(pi.hThread);
            if (applog.isEnabled()) applog.appLog("[win] Docker Desktop started from: {s}\n", .{path});
            return true;
        }
    }

    if (applog.isEnabled()) applog.appLog("[win] Failed to start Docker Desktop\n", .{});
    return false;
}

/// Ensure Docker is running, start if needed
pub fn ensureDockerRunning() bool {
    if (isDockerRunning()) {
        if (applog.isEnabled()) applog.appLog("[win] Docker is already running\n", .{});
        return true;
    }

    // Update progress label
    updateDevcontainerProgressLabel(std.unicode.utf8ToUtf16LeStringLiteral("Starting Docker..."));

    if (!startDockerDesktop()) {
        return false;
    }

    // Wait for Docker to be ready (up to 60 seconds)
    const max_wait_seconds: u32 = 60;
    var i: u32 = 0;
    while (i < max_wait_seconds) : (i += 1) {
        c.Sleep(1000); // Sleep 1 second
        if (isDockerRunning()) {
            if (applog.isEnabled()) applog.appLog("[win] Docker started successfully after {d} seconds\n", .{i + 1});
            return true;
        }
    }

    if (applog.isEnabled()) applog.appLog("[win] Docker failed to start within {d} seconds\n", .{max_wait_seconds});
    return false;
}

/// Run devcontainer up in background thread
pub fn runDevcontainerUpThread(workspace: []const u8, config_path: ?[]const u8, alloc: std.mem.Allocator) void {
    if (applog.isEnabled()) applog.appLog("[win] devcontainer up thread started\n", .{});

    // Ensure Docker is running first
    if (!ensureDockerRunning()) {
        if (applog.isEnabled()) applog.appLog("[win] Docker is not running and failed to start\n", .{});
        g_devcontainer_up_success.store(false, .seq_cst);
        g_devcontainer_up_done.store(true, .seq_cst);
        return;
    }

    // Update progress label to "Building..."
    updateDevcontainerProgressLabel(std.unicode.utf8ToUtf16LeStringLiteral("Building devcontainer..."));

    // Get user profile directory for nvim config path
    var local_app_data: [512]u8 = undefined;
    const local_app_data_len = c.GetEnvironmentVariableA("LOCALAPPDATA", &local_app_data, 512);
    const nvim_config_path = if (local_app_data_len > 0)
        local_app_data[0..local_app_data_len]
    else
        "C:\\Users\\Default\\AppData\\Local";
    var nvim_config_dir: [640]u8 = undefined;
    const nvim_config_dir_slice = std.fmt.bufPrint(&nvim_config_dir, "{s}\\nvim", .{nvim_config_path}) catch {
        g_devcontainer_up_success.store(false, .seq_cst);
        g_devcontainer_up_done.store(true, .seq_cst);
        return;
    };

    // Build command: devcontainer up with features and mount
    var cmd_buf: [4096]u8 = undefined;
    // 0.16: std.io.fixedBufferStream was removed; use the fixed Writer.
    var writer = std.Io.Writer.fixed(&cmd_buf);

    writer.writeAll("cmd /c \"devcontainer up --workspace-folder \"\"") catch {};
    core.frontend_rules.writeDevcontainerPath(&writer, workspace) catch {};
    writer.writeAll("\"\"") catch {};
    if (config_path) |cfg| {
        writer.writeAll(" --config \"\"") catch {};
        core.frontend_rules.writeDevcontainerPath(&writer, cfg) catch {};
        writer.writeAll("\"\"") catch {};
    }
    // Only reached on a rebuild (see window.zig), so the container is always
    // replaced. An argument with quotes is quoted for cmd, its own doubled.
    var args_buf: [1024]u8 = undefined;
    var args = std.mem.splitScalar(u8, core.frontend_rules.devcontainerUpArgs(&args_buf, nvim_config_dir_slice, true), 0);
    while (args.next()) |arg| {
        if (arg.len == 0) continue;
        writer.writeByte(' ') catch {};
        if (std.mem.indexOfScalar(u8, arg, '"') == null) {
            writer.writeAll(arg) catch {};
            continue;
        }
        writer.writeByte('"') catch {};
        for (arg) |ch| {
            if (ch == '"') writer.writeAll("\"\"") catch {} else writer.writeByte(ch) catch {};
        }
        writer.writeByte('"') catch {};
    }
    writer.writeByte('"') catch {};

    const cmd_slice = cmd_buf[0..writer.end];
    if (applog.isEnabled()) applog.appLog("[win] devcontainer up command: {s}\n", .{cmd_slice});

    // Convert to null-terminated for CreateProcess
    const cmd_z = alloc.dupeZ(u8, cmd_slice) catch {
        g_devcontainer_up_success.store(false, .seq_cst);
        g_devcontainer_up_done.store(true, .seq_cst);
        return;
    };
    defer alloc.free(cmd_z);

    // Run command via CreateProcess
    var si: c.STARTUPINFOA = std.mem.zeroes(c.STARTUPINFOA);
    si.cb = @sizeOf(c.STARTUPINFOA);
    si.dwFlags = c.STARTF_USESHOWWINDOW;
    si.wShowWindow = c.SW_HIDE;

    var pi: c.PROCESS_INFORMATION = std.mem.zeroes(c.PROCESS_INFORMATION);

    const create_result = c.CreateProcessA(
        null,
        cmd_z.ptr,
        null,
        null,
        0,
        c.CREATE_NO_WINDOW,
        null,
        null,
        &si,
        &pi,
    );

    if (create_result == 0) {
        if (applog.isEnabled()) applog.appLog("[win] devcontainer up CreateProcess failed\n", .{});
        g_devcontainer_up_success.store(false, .seq_cst);
        g_devcontainer_up_done.store(true, .seq_cst);
        return;
    }

    // Wait for process to complete
    _ = c.WaitForSingleObject(pi.hProcess, c.INFINITE);

    var exit_code: c.DWORD = 0;
    _ = c.GetExitCodeProcess(pi.hProcess, &exit_code);

    _ = c.CloseHandle(pi.hProcess);
    _ = c.CloseHandle(pi.hThread);

    if (applog.isEnabled()) applog.appLog("[win] devcontainer up completed with exit code: {d}\n", .{exit_code});

    g_devcontainer_up_success.store(exit_code == 0, .seq_cst);
    g_devcontainer_up_done.store(true, .seq_cst);
}

/// Handle clipboard get on UI thread (called via WM_APP_CLIPBOARD_GET)
pub fn handleClipboardGetOnUIThread(app: *App, seq: u32) void {
    app.clipboard_mu.lockUncancelable(core.clock.io());
    defer app.clipboard_mu.unlock(core.clock.io());
    if (!claimClipboardRequest(app, seq)) return;
    defer finishClipboardRequest(app);

    app.clipboard_len = 0;
    app.clipboard_result = 1; // Success (empty)

    const hwnd = app.hwnd orelse null;

    // Open clipboard
    if (c.OpenClipboard(hwnd) == 0) {
        if (applog.isEnabled()) applog.appLog("[win] clipboard_get_ui: OpenClipboard failed\n", .{});
        return;
    }
    defer _ = c.CloseClipboard();

    // Get CF_UNICODETEXT data
    const hdata = c.GetClipboardData(c.CF_UNICODETEXT);
    if (hdata == null) return; // Empty clipboard

    const ptr = c.GlobalLock(hdata);
    if (ptr == null) return;
    defer _ = c.GlobalUnlock(hdata);

    // Convert UTF-16 to UTF-8
    const wide_ptr: [*:0]const u16 = @ptrCast(@alignCast(ptr));
    const utf8_len = c.WideCharToMultiByte(
        c.CP_UTF8,
        0,
        wide_ptr,
        -1,
        null,
        0,
        null,
        null,
    );

    if (utf8_len <= 0) return;

    // utf8_len counts the terminating NUL that WideCharToMultiByte writes, so
    // the payload is one byte shorter and the buffer must hold both.
    const needed: usize = @intCast(utf8_len - 1);
    if (app.clipboard_buf.len < needed + 1) {
        const grown = app.alloc.alloc(u8, needed + 1) catch {
            if (applog.isEnabled()) applog.appLog(
                "[win] clipboard_get_ui: alloc {d} failed\n",
                .{needed + 1},
            );
            app.clipboard_len = 0;
            return;
        };
        if (app.clipboard_buf.len != 0) app.alloc.free(app.clipboard_buf);
        app.clipboard_buf = grown;
    }

    if (needed > 0) {
        _ = c.WideCharToMultiByte(
            c.CP_UTF8,
            0,
            wide_ptr,
            -1,
            @ptrCast(app.clipboard_buf.ptr),
            @intCast(app.clipboard_buf.len),
            null,
            null,
        );
    }

    app.clipboard_len = needed;
    if (applog.isEnabled()) applog.appLog("[win] clipboard_get_ui: len={d}\n", .{needed});
}

/// Put UTF-8 text on the Windows clipboard as CF_UNICODETEXT. Must run on the
/// UI thread. An empty slice replaces the clipboard with an empty string, as
/// macOS does, so `:let @+ = ''` does not leave the old text for "+p.
pub fn setClipboardTextUtf8(owner_hwnd: c.HWND, text: []const u8) bool {
    // Convert UTF-8 to UTF-16
    const wide_len: c_int = if (text.len == 0) 0 else c.MultiByteToWideChar(
        c.CP_UTF8,
        0,
        @ptrCast(text.ptr),
        @intCast(text.len),
        null,
        0,
    );

    if (text.len != 0 and wide_len <= 0) {
        if (applog.isEnabled()) applog.appLog("[win] clipboard_set_ui: UTF-8 to UTF-16 conversion failed\n", .{});
        return false;
    }

    // Open clipboard
    if (c.OpenClipboard(owner_hwnd) == 0) {
        if (applog.isEnabled()) applog.appLog("[win] clipboard_set_ui: OpenClipboard failed\n", .{});
        return false;
    }
    defer _ = c.CloseClipboard();

    _ = c.EmptyClipboard();

    // Allocate global memory for UTF-16 data (+1 for null terminator)
    const byte_size: usize = (@as(usize, @intCast(wide_len)) + 1) * 2;
    const hglobal = c.GlobalAlloc(c.GMEM_MOVEABLE, byte_size);
    if (hglobal == null) {
        if (applog.isEnabled()) applog.appLog("[win] clipboard_set_ui: GlobalAlloc failed\n", .{});
        return false;
    }

    const dest_ptr = c.GlobalLock(hglobal);
    if (dest_ptr == null) {
        _ = c.GlobalFree(hglobal);
        return false;
    }

    // Convert and copy
    if (wide_len > 0) _ = c.MultiByteToWideChar(
        c.CP_UTF8,
        0,
        @ptrCast(text.ptr),
        @intCast(text.len),
        @ptrCast(@alignCast(dest_ptr)),
        wide_len,
    );

    // Null terminate
    const wide_dest: [*]u16 = @ptrCast(@alignCast(dest_ptr));
    wide_dest[@intCast(wide_len)] = 0;

    _ = c.GlobalUnlock(hglobal);

    // Set clipboard data
    if (c.SetClipboardData(c.CF_UNICODETEXT, hglobal) == null) {
        _ = c.GlobalFree(hglobal);
        if (applog.isEnabled()) applog.appLog("[win] clipboard_set_ui: SetClipboardData failed\n", .{});
        return false;
    }

    if (applog.isEnabled()) applog.appLog("[win] clipboard_set_ui: success len={d}\n", .{text.len});
    return true;
}

/// Handle clipboard set on UI thread (called via WM_APP_CLIPBOARD_SET). The
/// payload is the app-owned copy in clipboard_buf.
pub fn handleClipboardSetOnUIThread(app: *App, seq: u32) void {
    app.clipboard_mu.lockUncancelable(core.clock.io());
    defer app.clipboard_mu.unlock(core.clock.io());
    if (!claimClipboardRequest(app, seq)) return;
    defer finishClipboardRequest(app);

    app.clipboard_result = if (setClipboardTextUtf8(app.hwnd orelse null, app.clipboard_buf[0..app.clipboard_len])) 1 else 0;
}

/// Caller holds clipboard_mu. False when request `seq` is no longer pending:
/// its caller timed out, and a later request may own the shared state.
fn claimClipboardRequest(app: *App, seq: u32) bool {
    return seq != 0 and app.clipboard_active_seq == seq;
}

/// Caller holds clipboard_mu. Clearing the active request is what tells the
/// waiting core thread the result is complete.
fn finishClipboardRequest(app: *App) void {
    app.clipboard_active_seq = 0;
    _ = c.SetEvent(app.clipboard_event);
}

// ============================================================
// Startup Connection Dialog (`--connect-dialog`)
//
// Shown at startup when launched with `--connect-dialog`. Lets the user pick
// the connection (Local / SSH / Devcontainer), the nvim path, ext-* UI options
// and per-connection environment variables before nvim is spawned. On Connect
// the selections are written back onto the App — the same ssh_*/devcontainer_*/
// ext_*_enabled fields the CLI flags populate — and WM_APP_DEFERRED_INIT is
// posted so the normal deferred-init full path builds the command and starts
// nvim. On Cancel the app quits. Mirrors the macOS ConnectionMenuViewController.
// ============================================================

var g_connection_dialog_hwnd: ?c.HWND = null;
var g_conn_font: ?c.HFONT = null;

var g_conn_name_hwnd: ?c.HWND = null;
var g_conn_nvim_hwnd: ?c.HWND = null;
var g_conn_local_hwnd: ?c.HWND = null;
var g_conn_ssh_hwnd: ?c.HWND = null;
var g_conn_devcontainer_hwnd: ?c.HWND = null;
var g_conn_ssh_host_hwnd: ?c.HWND = null;
var g_conn_ssh_port_hwnd: ?c.HWND = null;
var g_conn_ssh_identity_hwnd: ?c.HWND = null;
var g_conn_devcontainer_workspace_hwnd: ?c.HWND = null;
var g_conn_devcontainer_config_hwnd: ?c.HWND = null;
var g_conn_devcontainer_rebuild_hwnd: ?c.HWND = null;
var g_conn_env_hwnd: ?c.HWND = null;
var g_conn_ext_cmdline_hwnd: ?c.HWND = null;
var g_conn_ext_popup_hwnd: ?c.HWND = null;
var g_conn_ext_messages_hwnd: ?c.HWND = null;
var g_conn_ext_tabline_hwnd: ?c.HWND = null;
var g_conn_ext_windows_hwnd: ?c.HWND = null;
var g_conn_connect_hwnd: ?c.HWND = null;
var g_conn_cancel_hwnd: ?c.HWND = null;

/// TAB / ENTER / ESC handling for the connection dialog. Called from the main
/// message loop before TranslateMessage; returns true when the message was
/// consumed by the dialog (the loop then skips normal dispatch).
pub fn connectionDialogPreTranslate(msg: *c.MSG) bool {
    const hwnd = g_connection_dialog_hwnd orelse return false;
    return c.IsDialogMessageW(hwnd, msg) != 0;
}

pub fn showConnectionDialog(app: *App, owner: c.HWND) void {
    if (g_connection_dialog_hwnd) |hwnd| {
        _ = c.ShowWindow(hwnd, c.SW_SHOWNORMAL);
        _ = c.SetForegroundWindow(hwnd);
        return;
    }

    const hwnd = createCenteredDialog(
        std.unicode.utf8ToUtf16LeStringLiteral("ZonvieConnectDialogWin"),
        connectionDialogProc,
        std.unicode.utf8ToUtf16LeStringLiteral("Connect"),
        c.WS_OVERLAPPED | c.WS_CAPTION | c.WS_SYSMENU,
        c.WS_EX_DLGMODALFRAME,
        546,
        640,
        owner,
        owner,
        app,
    );
    if (hwnd == null) return;
    g_connection_dialog_hwnd = hwnd;
    _ = c.ShowWindow(hwnd, c.SW_SHOWNORMAL);
    _ = c.SetForegroundWindow(hwnd);
    _ = c.UpdateWindow(hwnd);
}

fn connectionFont() ?c.HFONT {
    if (g_conn_font) |f| return f;
    // Negative height = character height in device units; -14 ≈ 10.5pt @96dpi.
    g_conn_font = c.CreateFontW(
        -14,
        0,
        0,
        0,
        c.FW_NORMAL,
        0,
        0,
        0,
        c.DEFAULT_CHARSET,
        c.OUT_DEFAULT_PRECIS,
        c.CLIP_DEFAULT_PRECIS,
        c.CLEARTYPE_QUALITY,
        c.DEFAULT_PITCH | c.FF_DONTCARE,
        std.unicode.utf8ToUtf16LeStringLiteral("Segoe UI"),
    );
    return g_conn_font;
}

fn applyFont(hwnd: ?c.HWND) void {
    const h = hwnd orelse return;
    const f = connectionFont() orelse return;
    _ = c.SendMessageW(h, c.WM_SETFONT, @intFromPtr(f), 1);
}

fn createLabel(parent: c.HWND, text: [*:0]const u16, x: c_int, y: c_int, w: c_int) void {
    const h = c.CreateWindowExW(0, std.unicode.utf8ToUtf16LeStringLiteral("STATIC"), text, c.WS_CHILD | c.WS_VISIBLE, x, y, w, 18, parent, null, c.GetModuleHandleW(null), null);
    applyFont(h);
}

fn createEdit(parent: c.HWND, x: c_int, y: c_int, w: c_int) ?c.HWND {
    const h = c.CreateWindowExW(c.WS_EX_CLIENTEDGE, std.unicode.utf8ToUtf16LeStringLiteral("EDIT"), null, c.WS_CHILD | c.WS_VISIBLE | c.WS_TABSTOP | c.ES_AUTOHSCROLL, x, y, w, 24, parent, null, c.GetModuleHandleW(null), null);
    applyFont(h);
    return h;
}

// `group` marks the first radio of a group (WS_GROUP defines the auto-radio
// mutual-exclusion boundary) — it must sit on the first radio regardless of
// which one starts checked. `checked` sets the initial selection.
fn createRadio(parent: c.HWND, text: [*:0]const u16, x: c_int, y: c_int, w: c_int, group: bool, checked: bool) ?c.HWND {
    const style: c.DWORD =
        @as(c.DWORD, @intCast(c.WS_CHILD)) |
        @as(c.DWORD, @intCast(c.WS_VISIBLE)) |
        @as(c.DWORD, @intCast(c.WS_TABSTOP)) |
        @as(c.DWORD, @intCast(c.BS_AUTORADIOBUTTON)) |
        if (group) @as(c.DWORD, @intCast(c.WS_GROUP)) else 0;
    const h = c.CreateWindowExW(0, std.unicode.utf8ToUtf16LeStringLiteral("BUTTON"), text, style, x, y, w, 20, parent, null, c.GetModuleHandleW(null), null);
    applyFont(h);
    if (checked and h != null) _ = c.SendMessageW(h, c.BM_SETCHECK, c.BST_CHECKED, 0);
    return h;
}

/// Set an EDIT control's text from a UTF-8 slice. Used to seed SSH/devcontainer
/// fields from the CLI values when `--ssh` / `--devcontainer` accompany `--dialog`.
fn setEditTextUtf8(hwnd_opt: ?c.HWND, text: []const u8) void {
    const hwnd = hwnd_opt orelse return;
    if (text.len == 0) return;
    var wide: [1024]u16 = std.mem.zeroes([1024]u16);
    const wl = std.unicode.utf8ToUtf16Le(&wide, text) catch return;
    wide[@min(wl, wide.len - 1)] = 0;
    _ = c.SetWindowTextW(hwnd, &wide);
}

fn createCheck(parent: c.HWND, text: [*:0]const u16, x: c_int, y: c_int, w: c_int, checked: bool) ?c.HWND {
    const h = c.CreateWindowExW(0, std.unicode.utf8ToUtf16LeStringLiteral("BUTTON"), text, c.WS_CHILD | c.WS_VISIBLE | c.WS_TABSTOP | c.BS_AUTOCHECKBOX, x, y, w, 20, parent, null, c.GetModuleHandleW(null), null);
    applyFont(h);
    if (checked and h != null) _ = c.SendMessageW(h, c.BM_SETCHECK, c.BST_CHECKED, 0);
    return h;
}

fn createButton(parent: c.HWND, text: [*:0]const u16, x: c_int, y: c_int, w: c_int, default: bool) ?c.HWND {
    const base: c.DWORD = @as(c.DWORD, @intCast(c.WS_CHILD)) | @as(c.DWORD, @intCast(c.WS_VISIBLE)) | @as(c.DWORD, @intCast(c.WS_TABSTOP));
    const style: c.DWORD = base | if (default) @as(c.DWORD, @intCast(c.BS_DEFPUSHBUTTON)) else @as(c.DWORD, @intCast(c.BS_PUSHBUTTON));
    const h = c.CreateWindowExW(0, std.unicode.utf8ToUtf16LeStringLiteral("BUTTON"), text, style, x, y, w, 28, parent, null, c.GetModuleHandleW(null), null);
    applyFont(h);
    return h;
}

fn createConnectionControls(hwnd: c.HWND, app: *App) void {
    const L = std.unicode.utf8ToUtf16LeStringLiteral;

    createLabel(hwnd, L("Name"), 14, 12, 200);
    g_conn_name_hwnd = createEdit(hwnd, 14, 32, 500);
    createLabel(hwnd, L("Nvim Path (empty = default)"), 14, 62, 300);
    g_conn_nvim_hwnd = createEdit(hwnd, 14, 82, 500);

    // Pre-select the tab from the CLI: `--ssh` / `--devcontainer` accompanying
    // `--dialog` focus that mode (fields seeded below); otherwise Local.
    const init_ssh = app.ssh_mode;
    const init_devcontainer = app.devcontainer_mode and !app.ssh_mode;
    const init_local = !init_ssh and !init_devcontainer;
    g_conn_local_hwnd = createRadio(hwnd, L("Local"), 14, 116, 70, true, init_local);
    g_conn_ssh_hwnd = createRadio(hwnd, L("SSH"), 92, 116, 60, false, init_ssh);
    g_conn_devcontainer_hwnd = createRadio(hwnd, L("Devcontainer"), 160, 116, 130, false, init_devcontainer);

    createLabel(hwnd, L("SSH Host"), 14, 150, 120);
    g_conn_ssh_host_hwnd = createEdit(hwnd, 14, 170, 240);
    createLabel(hwnd, L("SSH Port"), 270, 150, 80);
    g_conn_ssh_port_hwnd = createEdit(hwnd, 270, 170, 70);
    createLabel(hwnd, L("SSH Identity"), 14, 202, 120);
    g_conn_ssh_identity_hwnd = createEdit(hwnd, 14, 222, 500);

    createLabel(hwnd, L("Devcontainer Workspace"), 14, 254, 200);
    g_conn_devcontainer_workspace_hwnd = createEdit(hwnd, 14, 274, 500);
    createLabel(hwnd, L("Devcontainer Config"), 14, 304, 200);
    g_conn_devcontainer_config_hwnd = createEdit(hwnd, 14, 324, 500);
    g_conn_devcontainer_rebuild_hwnd = createCheck(hwnd, L("Rebuild on start"), 14, 354, 200, app.devcontainer_rebuild);

    // Seed the mode-specific fields from the CLI values (if any).
    if (app.ssh_host) |host| setEditTextUtf8(g_conn_ssh_host_hwnd, host);
    if (app.ssh_port) |port| {
        var pbuf: [8]u8 = undefined;
        const s = std.fmt.bufPrint(&pbuf, "{d}", .{port}) catch "";
        setEditTextUtf8(g_conn_ssh_port_hwnd, s);
    }
    if (app.ssh_identity) |identity| setEditTextUtf8(g_conn_ssh_identity_hwnd, identity);
    if (app.devcontainer_workspace) |ws| setEditTextUtf8(g_conn_devcontainer_workspace_hwnd, ws);
    if (app.devcontainer_config) |cfg| setEditTextUtf8(g_conn_devcontainer_config_hwnd, cfg);

    createLabel(hwnd, L("Options"), 14, 386, 200);
    g_conn_ext_cmdline_hwnd = createCheck(hwnd, L("ext-cmdline"), 14, 408, 120, app.ext_cmdline_enabled);
    g_conn_ext_popup_hwnd = createCheck(hwnd, L("ext-popupmenu"), 150, 408, 140, app.config.popup.external);
    g_conn_ext_messages_hwnd = createCheck(hwnd, L("ext-messages"), 300, 408, 130, app.ext_messages_enabled);
    g_conn_ext_tabline_hwnd = createCheck(hwnd, L("ext-tabline"), 14, 432, 120, app.ext_tabline_enabled);
    g_conn_ext_windows_hwnd = createCheck(hwnd, L("ext-windows"), 150, 432, 130, app.ext_windows_enabled);

    createLabel(hwnd, L("Environment Variables (KEY=VALUE per line)"), 14, 462, 400);
    g_conn_env_hwnd = c.CreateWindowExW(
        c.WS_EX_CLIENTEDGE,
        L("EDIT"),
        null,
        c.WS_CHILD | c.WS_VISIBLE | c.WS_TABSTOP | c.WS_VSCROLL | c.ES_MULTILINE | c.ES_AUTOVSCROLL | c.ES_WANTRETURN,
        14,
        482,
        500,
        62,
        hwnd,
        null,
        c.GetModuleHandleW(null),
        null,
    );
    applyFont(g_conn_env_hwnd);

    g_conn_connect_hwnd = createButton(hwnd, L("Connect"), 340, 556, 86, true);
    g_conn_cancel_hwnd = createButton(hwnd, L("Cancel"), 434, 556, 86, false);
}

fn connectionDialogProc(hwnd: c.HWND, msg: c.UINT, wParam: c.WPARAM, lParam: c.LPARAM) callconv(.winapi) c.LRESULT {
    switch (msg) {
        c.WM_CREATE => {
            const cs: *c.CREATESTRUCTW = @ptrFromInt(@as(usize, @bitCast(lParam)));
            const app: *App = @ptrCast(@alignCast(cs.lpCreateParams.?));
            _ = c.SetWindowLongPtrW(hwnd, c.GWLP_USERDATA, @bitCast(@intFromPtr(app)));
            createConnectionControls(hwnd, app);
            return 0;
        },
        c.WM_COMMAND => {
            // Button HWND values arriving in lParam have no alignment guarantee;
            // compare raw addresses instead of going through @ptrFromInt (which
            // would trip Zig's Debug alignment check on low-bit-set handles).
            const id: usize = wParam & 0xFFFF;
            const source_addr: usize = if (lParam == 0) 0 else @bitCast(lParam);
            const cancel_addr: usize = if (g_conn_cancel_hwnd) |h| @intFromPtr(h) else 0;
            const connect_addr: usize = if (g_conn_connect_hwnd) |h| @intFromPtr(h) else 0;

            // ESC routed by IsDialogMessageW arrives as WM_COMMAND / IDCANCEL
            // with no source control (lParam == 0).
            if (id == c.IDCANCEL and lParam == 0) {
                cancelConnectionDialog(hwnd);
                return 0;
            }
            if (source_addr == cancel_addr and cancel_addr != 0) {
                cancelConnectionDialog(hwnd);
                return 0;
            }
            if (source_addr == connect_addr and connect_addr != 0) {
                if (applog.isEnabled()) applog.appLog("[win] connection dialog: Connect clicked\n", .{});
                const owner = c.GetWindow(hwnd, c.GW_OWNER) orelse hwnd;
                const app_opt: ?*App = blk: {
                    const v = c.GetWindowLongPtrW(hwnd, c.GWLP_USERDATA);
                    if (v == 0) break :blk null;
                    break :blk @ptrFromInt(@as(usize, @bitCast(v)));
                };
                if (app_opt) |app| {
                    applyConnectionAndStart(app, owner, hwnd);
                    _ = c.DestroyWindow(hwnd);
                } else if (applog.isEnabled()) {
                    applog.appLog("[win] connection dialog: GWLP_USERDATA missing, leaving dialog open\n", .{});
                }
                return 0;
            }
        },
        c.WM_CLOSE => {
            cancelConnectionDialog(hwnd);
            return 0;
        },
        c.WM_SETTINGCHANGE, c.WM_THEMECHANGED => return window_mod.themeMessage(hwnd, msg, wParam, lParam).?,
        c.WM_DESTROY => {
            g_connection_dialog_hwnd = null;
            g_conn_name_hwnd = null;
            g_conn_nvim_hwnd = null;
            g_conn_local_hwnd = null;
            g_conn_ssh_hwnd = null;
            g_conn_devcontainer_hwnd = null;
            g_conn_ssh_host_hwnd = null;
            g_conn_ssh_port_hwnd = null;
            g_conn_ssh_identity_hwnd = null;
            g_conn_devcontainer_workspace_hwnd = null;
            g_conn_devcontainer_config_hwnd = null;
            g_conn_devcontainer_rebuild_hwnd = null;
            g_conn_env_hwnd = null;
            g_conn_ext_cmdline_hwnd = null;
            g_conn_ext_popup_hwnd = null;
            g_conn_ext_messages_hwnd = null;
            g_conn_ext_tabline_hwnd = null;
            g_conn_ext_windows_hwnd = null;
            g_conn_connect_hwnd = null;
            g_conn_cancel_hwnd = null;
            return 0;
        },
        else => {},
    }
    return c.DefWindowProcW(hwnd, msg, wParam, lParam);
}

/// Cancel = quit the app. No connection was chosen and, unlike the start-
/// failure path, the core was never created (WM_APP_DEFERRED_INIT was never
/// posted), so there is nothing to tear down — exit the message loop directly.
fn cancelConnectionDialog(hwnd: c.HWND) void {
    if (applog.isEnabled()) applog.appLog("[win] connection dialog: cancelled, quitting\n", .{});
    _ = c.DestroyWindow(hwnd);
    c.PostQuitMessage(0);
}

/// Write the dialog's selections back onto the App (mirroring how CLI flags
/// populate these fields) and kick off the normal deferred-init full path,
/// which builds the nvim command from ssh_mode/devcontainer_mode/ext_* and
/// starts nvim. Dialog-provided strings are duped from app.alloc; they live
/// for the process lifetime (single startup, freed on exit).
fn applyConnectionAndStart(app: *App, owner: c.HWND, dialog: c.HWND) void {
    var nvim_buf: [512]u8 = undefined;
    var nvim_path = readWindowTextUtf8(g_conn_nvim_hwnd, &nvim_buf);
    // Explorer's "Copy as path" wraps the path in double quotes; one pair
    // around the whole path is dropped. The spawn command's quoting cannot
    // carry a quote inside a path (the --nvim rule in main.zig), so such a
    // path is ignored, and said so.
    if (nvim_path.len >= 2 and (nvim_path[0] == '"' or nvim_path[0] == '\'') and nvim_path[nvim_path.len - 1] == nvim_path[0]) {
        nvim_path = nvim_path[1 .. nvim_path.len - 1];
    }
    const has_quote = std.mem.indexOfAny(u8, nvim_path, "'\"") != null;
    if (has_quote) {
        if (applog.isEnabled()) applog.appLog("[win] connection dialog: nvim path contains quote characters; ignoring it\n", .{});
        // Owned by the dialog, which the box disables for its modal loop:
        // owned by the main window, a second Connect click re-entered here.
        _ = c.MessageBoxW(dialog, std.unicode.utf8ToUtf16LeStringLiteral("The Neovim path contains a quote character and was ignored."), std.unicode.utf8ToUtf16LeStringLiteral("Zonvie"), c.MB_OK | c.MB_ICONWARNING);
    }
    if (nvim_path.len != 0 and !has_quote) {
        if (app.alloc.dupe(u8, nvim_path)) |p| {
            app.cli_nvim_path = p;
        } else |_| {}
    }

    const is_ssh = isChecked(g_conn_ssh_hwnd);
    const is_devcontainer = isChecked(g_conn_devcontainer_hwnd);

    if (is_ssh) {
        app.ssh_mode = true;
        app.devcontainer_mode = false;
        var host_buf: [256]u8 = undefined;
        const host = readWindowTextUtf8(g_conn_ssh_host_hwnd, &host_buf);
        app.ssh_host = if (host.len != 0) (app.alloc.dupe(u8, host) catch null) else null;
        var port_buf: [32]u8 = undefined;
        const port_text = readWindowTextUtf8(g_conn_ssh_port_hwnd, &port_buf);
        app.ssh_port = if (port_text.len != 0) (std.fmt.parseInt(u16, port_text, 10) catch null) else null;
        var id_buf: [512]u8 = undefined;
        const identity = readWindowTextUtf8(g_conn_ssh_identity_hwnd, &id_buf);
        app.ssh_identity = if (identity.len != 0) (app.alloc.dupe(u8, identity) catch null) else null;
    } else if (is_devcontainer) {
        app.devcontainer_mode = true;
        app.ssh_mode = false;
        var ws_buf: [512]u8 = undefined;
        const ws = readWindowTextUtf8(g_conn_devcontainer_workspace_hwnd, &ws_buf);
        app.devcontainer_workspace = if (ws.len != 0) (app.alloc.dupe(u8, ws) catch null) else null;
        var cfg_buf: [512]u8 = undefined;
        const cfg = readWindowTextUtf8(g_conn_devcontainer_config_hwnd, &cfg_buf);
        app.devcontainer_config = if (cfg.len != 0) (app.alloc.dupe(u8, cfg) catch null) else null;
        app.devcontainer_rebuild = isChecked(g_conn_devcontainer_rebuild_hwnd);
    } else {
        // Local: clear any config-derived remote mode.
        app.ssh_mode = false;
        app.devcontainer_mode = false;
    }

    // ext-* options. popup has no dedicated app field; it is read from
    // app.config.popup.external at start, so override that directly.
    app.ext_cmdline_enabled = isChecked(g_conn_ext_cmdline_hwnd);
    app.config.popup.external = isChecked(g_conn_ext_popup_hwnd);
    app.ext_messages_enabled = isChecked(g_conn_ext_messages_hwnd);
    app.ext_tabline_enabled = isChecked(g_conn_ext_tabline_hwnd);
    app.ext_windows_enabled = isChecked(g_conn_ext_windows_hwnd);

    applyConnectionEnvVars();

    if (applog.isEnabled()) applog.appLog("[win] connection dialog: connect ssh={} devcontainer={}\n", .{ app.ssh_mode, app.devcontainer_mode });

    // Resolve the connection in-process: run the deferred-init full path
    // against the now-populated app fields (early_core_init_done is false, so
    // it takes the ssh/devcontainer/native branch).
    _ = c.PostMessageW(owner, app_mod.WM_APP_DEFERRED_INIT, 0, 0);
}

/// Parse the env-vars edit (KEY=VALUE per line) and apply to the process
/// environment so the spawned nvim inherits them. Mirrors the macOS setenv
/// loop; SetEnvironmentVariableW is process-wide (startup one-shot).
fn applyConnectionEnvVars() void {
    const hwnd = g_conn_env_hwnd orelse return;
    var wide: [4096]u16 = std.mem.zeroes([4096]u16);
    const len = c.GetWindowTextW(hwnd, &wide, wide.len);
    if (len <= 0) return;
    var utf8_buf: [8192]u8 = undefined;
    const utf8_len = std.unicode.utf16LeToUtf8(&utf8_buf, wide[0..@intCast(len)]) catch return;
    var it = std.mem.splitScalar(u8, utf8_buf[0..utf8_len], '\n');
    while (it.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0) continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = line[0..eq];
        if (key.len == 0) continue;
        const val = line[eq + 1 ..];
        var key_w: [256]u16 = std.mem.zeroes([256]u16);
        var val_w: [1024]u16 = std.mem.zeroes([1024]u16);
        const kl = std.unicode.utf8ToUtf16Le(&key_w, key) catch continue;
        key_w[@min(kl, key_w.len - 1)] = 0;
        const vl = std.unicode.utf8ToUtf16Le(&val_w, val) catch continue;
        val_w[@min(vl, val_w.len - 1)] = 0;
        _ = c.SetEnvironmentVariableW(&key_w, &val_w);
    }
}

fn readWindowTextUtf8(hwnd_opt: ?c.HWND, dest: []u8) []const u8 {
    const hwnd = hwnd_opt orelse return "";
    var wide: [512]u16 = std.mem.zeroes([512]u16);
    const len = c.GetWindowTextW(hwnd, &wide, wide.len);
    if (len <= 0) return "";
    const slice = wide[0..@intCast(len)];
    const utf8_len = std.unicode.utf16LeToUtf8(dest, slice) catch return "";
    return dest[0..utf8_len];
}

fn isChecked(hwnd_opt: ?c.HWND) bool {
    const hwnd = hwnd_opt orelse return false;
    return c.SendMessageW(hwnd, c.BM_GETCHECK, 0, 0) == c.BST_CHECKED;
}
