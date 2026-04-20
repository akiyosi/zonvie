const std = @import("std");
const app_mod = @import("../app.zig");
const App = app_mod.App;
const c = app_mod.c;
const applog = app_mod.applog;
const session_registry = @import("../session_registry.zig");

// --- SSH Password Dialog state ---
var ssh_dlg_password: [256]u8 = undefined;
var ssh_dlg_password_len: usize = 0;
var ssh_dlg_result: bool = false;
var ssh_dlg_edit_hwnd: c.HWND = null;
var ssh_dlg_ok_hwnd: c.HWND = null;
var ssh_dlg_cancel_hwnd: c.HWND = null;

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
    if (app.ssh_prompt_owned) |buf| {
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

    // Free the owned prompt buffer (no longer needed)
    if (app.ssh_prompt_owned) |buf| {
        app.alloc.free(buf);
        app.ssh_prompt_owned = null;
    }

    // Hide console after password entry
    _ = c.FreeConsole();
}

/// Window procedure for SSH password dialog
fn sshPasswordDlgProc(hwnd: c.HWND, msg: c.UINT, wParam: c.WPARAM, lParam: c.LPARAM) callconv(.winapi) c.LRESULT {
    switch (msg) {
        c.WM_COMMAND => {
            // Check which button was clicked
            // For button clicks, lParam contains the button HWND
            const lp_value: usize = @bitCast(lParam);
            const notification = (wParam >> 16) & 0xFFFF;

            // BN_CLICKED = 0
            if (notification == 0 and lp_value != 0) {
                // Compare as usize values to avoid alignment issues
                const ok_value: usize = if (ssh_dlg_ok_hwnd) |h| @intFromPtr(h) else 0;
                const cancel_value: usize = if (ssh_dlg_cancel_hwnd) |h| @intFromPtr(h) else 0;

                if (lp_value == ok_value and ok_value != 0) {
                    // OK button clicked - get password
                    if (ssh_dlg_edit_hwnd != null) {
                        const len = c.GetWindowTextA(ssh_dlg_edit_hwnd, &ssh_dlg_password, ssh_dlg_password.len);
                        ssh_dlg_password_len = if (len > 0) @intCast(len) else 0;
                    }
                    ssh_dlg_result = true;
                    _ = c.DestroyWindow(hwnd);
                    return 0;
                } else if (lp_value == cancel_value and cancel_value != 0) {
                    // Cancel button clicked
                    ssh_dlg_result = false;
                    _ = c.DestroyWindow(hwnd);
                    return 0;
                }
            }
        },
        c.WM_CLOSE => {
            ssh_dlg_result = false;
            _ = c.DestroyWindow(hwnd);
            return 0;
        },
        c.WM_DESTROY => {
            c.PostQuitMessage(0);
            return 0;
        },
        else => {},
    }
    return c.DefWindowProcW(hwnd, msg, wParam, lParam);
}

/// Show SSH password dialog using Windows CredUI API
/// This uses the system-provided credential dialog which doesn't interfere with spawn()
/// Returns the password (caller must free) or null if cancelled
pub fn showSSHPasswordDialog(alloc: std.mem.Allocator, host: []const u8) ?[]const u8 {
    if (applog.isEnabled()) applog.appLog("[win] showSSHPasswordDialog (CredUI): host={s}\n", .{host});

    // CredUI flags
    const CREDUI_FLAGS_GENERIC_CREDENTIALS: c.DWORD = 0x00040000;
    const CREDUI_FLAGS_ALWAYS_SHOW_UI: c.DWORD = 0x00000080;
    const CREDUI_FLAGS_DO_NOT_PERSIST: c.DWORD = 0x00000002;

    // Convert host to UTF-16 for target name
    var target_name: [256]u16 = undefined;
    var target_len: usize = 0;
    for (host) |ch| {
        if (target_len < target_name.len - 1) {
            target_name[target_len] = ch;
            target_len += 1;
        }
    }
    target_name[target_len] = 0;

    // Message text
    const msg_text = std.unicode.utf8ToUtf16LeStringLiteral("Enter credentials for SSH connection");
    const caption = std.unicode.utf8ToUtf16LeStringLiteral("SSH Authentication - Zonvie");

    // Setup CREDUI_INFO structure
    var cred_info: c.CREDUI_INFOW = std.mem.zeroes(c.CREDUI_INFOW);
    cred_info.cbSize = @sizeOf(c.CREDUI_INFOW);
    cred_info.hwndParent = null;
    cred_info.pszMessageText = msg_text;
    cred_info.pszCaptionText = caption;
    cred_info.hbmBanner = null;

    // Buffers for username and password
    var username: [256]u16 = undefined;
    var password: [256]u16 = undefined;
    @memset(&username, 0);
    @memset(&password, 0);

    // Pre-fill username from host if it contains user@host format
    var username_len: usize = 0;
    var found_at = false;
    for (host) |ch| {
        if (ch == '@') {
            found_at = true;
            break;
        }
        if (username_len < username.len - 1) {
            username[username_len] = ch;
            username_len += 1;
        }
    }
    if (!found_at) {
        // No user@ prefix, clear username
        @memset(&username, 0);
    }

    var save: c.BOOL = 0; // Don't save credentials

    // Call CredUIPromptForCredentialsW
    const result = c.CredUIPromptForCredentialsW(
        &cred_info,
        &target_name,
        null, // pContext
        0, // dwAuthError
        &username,
        username.len,
        &password,
        password.len,
        &save,
        CREDUI_FLAGS_GENERIC_CREDENTIALS | CREDUI_FLAGS_ALWAYS_SHOW_UI | CREDUI_FLAGS_DO_NOT_PERSIST,
    );

    if (result != 0) {
        // Cancelled or error
        if (applog.isEnabled()) applog.appLog("[win] showSSHPasswordDialog (CredUI): cancelled or error, result={d}\n", .{result});
        @memset(&password, 0);
        return null;
    }

    // Convert password from UTF-16 to UTF-8
    var password_len: usize = 0;
    while (password_len < password.len and password[password_len] != 0) {
        password_len += 1;
    }

    if (password_len == 0) {
        if (applog.isEnabled()) applog.appLog("[win] showSSHPasswordDialog (CredUI): empty password\n", .{});
        return null;
    }

    // Convert UTF-16 to UTF-8
    var utf8_buf: [512]u8 = undefined;
    var utf8_len: usize = 0;
    for (password[0..password_len]) |wch| {
        if (wch < 128) {
            if (utf8_len < utf8_buf.len) {
                utf8_buf[utf8_len] = @intCast(wch);
                utf8_len += 1;
            }
        } else if (wch < 0x800) {
            if (utf8_len + 1 < utf8_buf.len) {
                utf8_buf[utf8_len] = @intCast(0xC0 | (wch >> 6));
                utf8_buf[utf8_len + 1] = @intCast(0x80 | (wch & 0x3F));
                utf8_len += 2;
            }
        } else {
            if (utf8_len + 2 < utf8_buf.len) {
                utf8_buf[utf8_len] = @intCast(0xE0 | (wch >> 12));
                utf8_buf[utf8_len + 1] = @intCast(0x80 | ((wch >> 6) & 0x3F));
                utf8_buf[utf8_len + 2] = @intCast(0x80 | (wch & 0x3F));
                utf8_len += 3;
            }
        }
    }

    // Clear password buffer for security
    @memset(&password, 0);

    // Allocate and return password
    const result_password = alloc.dupe(u8, utf8_buf[0..utf8_len]) catch {
        @memset(&utf8_buf, 0);
        return null;
    };
    @memset(&utf8_buf, 0);

    if (applog.isEnabled()) applog.appLog("[win] showSSHPasswordDialog (CredUI): password entered ({d} chars)\n", .{result_password.len});
    return result_password;
}

/// Simple password input dialog without username field
pub fn showPasswordInputDialog(prompt: *const [256]u16, password_out: *[256]u16) bool {
    const class_name = std.unicode.utf8ToUtf16LeStringLiteral("ZonviePasswordDialog");

    // Register window class
    var wc: c.WNDCLASSEXW = std.mem.zeroes(c.WNDCLASSEXW);
    wc.cbSize = @sizeOf(c.WNDCLASSEXW);
    wc.lpfnWndProc = passwordDialogProc;
    wc.hInstance = c.GetModuleHandleW(null);
    wc.hCursor = c.LoadCursorW(null, @ptrFromInt(32512)); // IDC_ARROW
    wc.hbrBackground = @ptrFromInt(@as(usize, 16)); // COLOR_BTNFACE + 1
    wc.lpszClassName = class_name;
    _ = c.RegisterClassExW(&wc);

    // Store output pointer
    g_password_dialog_output = password_out;
    g_password_dialog_result = false;

    // Create dialog window (centered on screen)
    const screen_w = c.GetSystemMetrics(c.SM_CXSCREEN);
    const screen_h = c.GetSystemMetrics(c.SM_CYSCREEN);
    const dlg_w: i32 = 420;
    const dlg_h: i32 = 180;
    const dlg_x = @divTrunc(screen_w - dlg_w, 2);
    const dlg_y = @divTrunc(screen_h - dlg_h, 2);

    const hwnd = c.CreateWindowExW(
        c.WS_EX_DLGMODALFRAME | c.WS_EX_TOPMOST,
        class_name,
        std.unicode.utf8ToUtf16LeStringLiteral("SSH Authentication"),
        c.WS_POPUP | c.WS_CAPTION | c.WS_SYSMENU,
        dlg_x,
        dlg_y,
        dlg_w,
        dlg_h,
        null,
        null,
        c.GetModuleHandleW(null),
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
        else => {},
    }
    return c.DefWindowProcW(hwnd, msg, wParam, lParam);
}

pub fn showDevcontainerProgressDialog(label_text: [*:0]const u16) void {
    const class_name = std.unicode.utf8ToUtf16LeStringLiteral("ZonvieDevcontainerProgress");

    // Register window class
    var wc: c.WNDCLASSEXW = std.mem.zeroes(c.WNDCLASSEXW);
    wc.cbSize = @sizeOf(c.WNDCLASSEXW);
    wc.lpfnWndProc = devcontainerDialogProc;
    wc.hInstance = c.GetModuleHandleW(null);
    wc.hCursor = c.LoadCursorW(null, @ptrFromInt(32512)); // IDC_ARROW
    wc.hbrBackground = @ptrFromInt(@as(usize, 16)); // COLOR_BTNFACE + 1
    wc.lpszClassName = class_name;
    _ = c.RegisterClassExW(&wc);

    // Create dialog window (centered on screen)
    const screen_w = c.GetSystemMetrics(c.SM_CXSCREEN);
    const screen_h = c.GetSystemMetrics(c.SM_CYSCREEN);
    const dlg_w: i32 = 300;
    const dlg_h: i32 = 80;
    const dlg_x = @divTrunc(screen_w - dlg_w, 2);
    const dlg_y = @divTrunc(screen_h - dlg_h, 2);

    const hwnd = c.CreateWindowExW(
        c.WS_EX_DLGMODALFRAME | c.WS_EX_TOPMOST,
        class_name,
        std.unicode.utf8ToUtf16LeStringLiteral("Devcontainer"),
        c.WS_POPUP | c.WS_CAPTION,
        dlg_x,
        dlg_y,
        dlg_w,
        dlg_h,
        null,
        null,
        c.GetModuleHandleW(null),
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

    // Build command: devcontainer up with features and mount
    var cmd_buf: [4096]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&cmd_buf);
    const writer = fbs.writer();

    writer.writeAll("cmd /c \"devcontainer up --workspace-folder \"\"") catch {};
    writer.writeAll(workspace) catch {};
    writer.writeAll("\"\"") catch {};
    if (config_path) |cfg| {
        writer.writeAll(" --config \"\"") catch {};
        writer.writeAll(cfg) catch {};
        writer.writeAll("\"\"") catch {};
    }
    writer.writeAll(" --additional-features \"{\"\"ghcr.io/duduribeiro/devcontainer-features/neovim:1\"\":{}}\"") catch {};
    writer.writeAll(" --mount type=bind,source=") catch {};
    writer.writeAll(nvim_config_path) catch {};
    writer.writeAll("\\nvim,target=/nvim-config/nvim") catch {};
    writer.writeAll(" --remove-existing-container\"") catch {};

    const cmd_slice = cmd_buf[0..fbs.pos];
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
pub fn handleClipboardGetOnUIThread(app: *App) void {
    app.clipboard_len = 0;
    app.clipboard_result = 1; // Success (empty)

    const hwnd = app.hwnd orelse null;

    // Open clipboard
    if (c.OpenClipboard(hwnd) == 0) {
        if (applog.isEnabled()) applog.appLog("[win] clipboard_get_ui: OpenClipboard failed\n", .{});
        _ = c.SetEvent(app.clipboard_event);
        return;
    }
    defer _ = c.CloseClipboard();

    // Get CF_UNICODETEXT data
    const hdata = c.GetClipboardData(c.CF_UNICODETEXT);
    if (hdata == null) {
        // Empty clipboard
        _ = c.SetEvent(app.clipboard_event);
        return;
    }

    const ptr = c.GlobalLock(hdata);
    if (ptr == null) {
        _ = c.SetEvent(app.clipboard_event);
        return;
    }
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

    if (utf8_len <= 0) {
        _ = c.SetEvent(app.clipboard_event);
        return;
    }

    const copy_len: usize = @min(@as(usize, @intCast(utf8_len - 1)), app.clipboard_buf.len);
    if (copy_len > 0) {
        _ = c.WideCharToMultiByte(
            c.CP_UTF8,
            0,
            wide_ptr,
            -1,
            @ptrCast(&app.clipboard_buf),
            @intCast(app.clipboard_buf.len),
            null,
            null,
        );
    }

    app.clipboard_len = copy_len;
    if (applog.isEnabled()) applog.appLog("[win] clipboard_get_ui: len={d}\n", .{copy_len});

    // Signal completion
    _ = c.SetEvent(app.clipboard_event);
}

/// Handle clipboard set on UI thread (called via WM_APP_CLIPBOARD_SET)
pub fn handleClipboardSetOnUIThread(app: *App) void {
    app.clipboard_result = 0; // Failure by default

    const data = app.clipboard_set_data orelse {
        _ = c.SetEvent(app.clipboard_event);
        return;
    };
    const len = app.clipboard_set_len;

    if (len == 0) {
        app.clipboard_result = 1;
        _ = c.SetEvent(app.clipboard_event);
        return;
    }

    // Convert UTF-8 to UTF-16
    const wide_len = c.MultiByteToWideChar(
        c.CP_UTF8,
        0,
        @ptrCast(data),
        @intCast(len),
        null,
        0,
    );

    if (wide_len <= 0) {
        if (applog.isEnabled()) applog.appLog("[win] clipboard_set_ui: UTF-8 to UTF-16 conversion failed\n", .{});
        _ = c.SetEvent(app.clipboard_event);
        return;
    }

    const hwnd = app.hwnd orelse null;

    // Open clipboard
    if (c.OpenClipboard(hwnd) == 0) {
        if (applog.isEnabled()) applog.appLog("[win] clipboard_set_ui: OpenClipboard failed\n", .{});
        _ = c.SetEvent(app.clipboard_event);
        return;
    }
    defer _ = c.CloseClipboard();

    _ = c.EmptyClipboard();

    // Allocate global memory for UTF-16 data (+1 for null terminator)
    const byte_size: usize = (@as(usize, @intCast(wide_len)) + 1) * 2;
    const hglobal = c.GlobalAlloc(c.GMEM_MOVEABLE, byte_size);
    if (hglobal == null) {
        if (applog.isEnabled()) applog.appLog("[win] clipboard_set_ui: GlobalAlloc failed\n", .{});
        _ = c.SetEvent(app.clipboard_event);
        return;
    }

    const dest_ptr = c.GlobalLock(hglobal);
    if (dest_ptr == null) {
        _ = c.GlobalFree(hglobal);
        _ = c.SetEvent(app.clipboard_event);
        return;
    }

    // Convert and copy
    _ = c.MultiByteToWideChar(
        c.CP_UTF8,
        0,
        @ptrCast(data),
        @intCast(len),
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
        _ = c.SetEvent(app.clipboard_event);
        return;
    }

    if (applog.isEnabled()) applog.appLog("[win] clipboard_set_ui: success len={d}\n", .{len});
    app.clipboard_result = 1;
    _ = c.SetEvent(app.clipboard_event);
}

// ============================================================
// Session Overview / Connection Dialog
// ============================================================

var g_session_overview_hwnd: ?c.HWND = null;
var g_session_overview_list_hwnd: ?c.HWND = null;
var g_session_overview_owner: ?c.HWND = null;
var g_session_overview_activate_hwnd: ?c.HWND = null;
var g_session_overview_new_hwnd: ?c.HWND = null;
var g_session_overview_close_hwnd: ?c.HWND = null;
var g_connection_dialog_hwnd: ?c.HWND = null;

/// Set by the workspace overlay when the user clicks a specific "+"
/// cell (see WM_LBUTTONDOWN handler in window.zig). Consumed by
/// launchConfiguredSession and fed to ConnectionConfig.target_tile_index
/// so the new session lands on the clicked slot instead of appending at
/// the next free position. `null` means "no explicit target — append".
var g_connection_dialog_target_idx: ?u8 = null;

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
var g_conn_ext_cmdline_hwnd: ?c.HWND = null;
var g_conn_ext_popup_hwnd: ?c.HWND = null;
var g_conn_ext_messages_hwnd: ?c.HWND = null;
var g_conn_ext_tabline_hwnd: ?c.HWND = null;
var g_conn_ext_windows_hwnd: ?c.HWND = null;
var g_conn_connect_hwnd: ?c.HWND = null;
var g_conn_cancel_hwnd: ?c.HWND = null;

pub fn preTranslateMessage(msg: *c.MSG) bool {
    if (g_connection_dialog_hwnd) |dialog_hwnd| {
        if (msg.message == c.WM_KEYDOWN and msg.wParam == c.VK_ESCAPE) {
            const root = c.GetAncestor(msg.hwnd, c.GA_ROOT);
            if (root == dialog_hwnd) {
                _ = c.DestroyWindow(dialog_hwnd);
                return true;
            }
        }
    }
    return false;
}

pub fn showSessionOverview(app: *App, owner: c.HWND) void {
    g_session_overview_owner = owner;
    if (g_session_overview_hwnd) |hwnd| {
        refreshSessionOverview(app);
        _ = c.ShowWindow(hwnd, c.SW_SHOWNORMAL);
        _ = c.SetForegroundWindow(hwnd);
        return;
    }

    var wc: c.WNDCLASSEXW = std.mem.zeroes(c.WNDCLASSEXW);
    wc.cbSize = @sizeOf(c.WNDCLASSEXW);
    wc.lpfnWndProc = sessionOverviewProc;
    wc.hInstance = c.GetModuleHandleW(null);
    wc.hCursor = c.LoadCursorW(null, @ptrFromInt(32512));
    wc.hbrBackground = null;
    wc.lpszClassName = std.unicode.utf8ToUtf16LeStringLiteral("ZonvieSessionOverviewWin");
    _ = c.RegisterClassExW(&wc);

    const hwnd = c.CreateWindowExW(
        c.WS_EX_TOOLWINDOW,
        wc.lpszClassName,
        std.unicode.utf8ToUtf16LeStringLiteral("Workspace Overview"),
        c.WS_OVERLAPPED | c.WS_CAPTION | c.WS_SYSMENU,
        c.CW_USEDEFAULT,
        c.CW_USEDEFAULT,
        420,
        320,
        owner,
        null,
        wc.hInstance,
        app,
    );
    if (hwnd == null) return;
    g_session_overview_hwnd = hwnd;
    _ = c.ShowWindow(hwnd, c.SW_SHOWNORMAL);
    _ = c.UpdateWindow(hwnd);
}

/// Open the new-session dialog and, when the user clicks Connect, place
/// the resulting tile at the specific slot the user clicked in the
/// workspace overview. Used by the "+" click path so overlay geometry
/// (e.g. clicking the center cell) becomes the actual target slot, not
/// just "next free append".
pub fn showConnectionDialogForTile(app: *App, owner: c.HWND, target_idx: u8) void {
    g_connection_dialog_target_idx = target_idx;
    showConnectionDialog(app, owner);
}

pub fn showConnectionDialog(app: *App, owner: c.HWND) void {
    if (g_connection_dialog_hwnd) |hwnd| {
        _ = c.ShowWindow(hwnd, c.SW_SHOWNORMAL);
        _ = c.SetForegroundWindow(hwnd);
        return;
    }

    var wc: c.WNDCLASSEXW = std.mem.zeroes(c.WNDCLASSEXW);
    wc.cbSize = @sizeOf(c.WNDCLASSEXW);
    wc.lpfnWndProc = connectionDialogProc;
    wc.hInstance = c.GetModuleHandleW(null);
    wc.hCursor = c.LoadCursorW(null, @ptrFromInt(32512));
    wc.hbrBackground = null;
    wc.lpszClassName = std.unicode.utf8ToUtf16LeStringLiteral("ZonvieConnectionDialogWin");
    _ = c.RegisterClassExW(&wc);

    const hwnd = c.CreateWindowExW(
        c.WS_EX_TOOLWINDOW,
        wc.lpszClassName,
        std.unicode.utf8ToUtf16LeStringLiteral("New Session"),
        c.WS_OVERLAPPED | c.WS_CAPTION | c.WS_SYSMENU,
        c.CW_USEDEFAULT,
        c.CW_USEDEFAULT,
        520,
        520,
        owner,
        null,
        wc.hInstance,
        app,
    );
    if (hwnd == null) return;
    g_connection_dialog_hwnd = hwnd;
    _ = c.ShowWindow(hwnd, c.SW_SHOWNORMAL);
    _ = c.UpdateWindow(hwnd);
}

pub fn hideConnectionDialog() void {
    if (g_connection_dialog_hwnd) |hwnd| {
        _ = c.DestroyWindow(hwnd);
    }
}

fn sessionOverviewProc(hwnd: c.HWND, msg: c.UINT, wParam: c.WPARAM, lParam: c.LPARAM) callconv(.winapi) c.LRESULT {
    switch (msg) {
        c.WM_CREATE => {
            const cs: *c.CREATESTRUCTW = @ptrFromInt(@as(usize, @bitCast(lParam)));
            const app: *App = @ptrCast(@alignCast(cs.lpCreateParams.?));
            _ = c.SetWindowLongPtrW(hwnd, c.GWLP_USERDATA, @bitCast(@intFromPtr(app)));

            _ = c.CreateWindowExW(0, std.unicode.utf8ToUtf16LeStringLiteral("STATIC"), std.unicode.utf8ToUtf16LeStringLiteral("Sessions"), c.WS_CHILD | c.WS_VISIBLE, 12, 12, 120, 20, hwnd, null, c.GetModuleHandleW(null), null);
            g_session_overview_list_hwnd = c.CreateWindowExW(
                c.WS_EX_CLIENTEDGE,
                std.unicode.utf8ToUtf16LeStringLiteral("LISTBOX"),
                null,
                c.WS_CHILD | c.WS_VISIBLE | c.LBS_NOTIFY | c.WS_VSCROLL,
                12,
                36,
                380,
                190,
                hwnd,
                null,
                c.GetModuleHandleW(null),
                null,
            );
            g_session_overview_activate_hwnd = c.CreateWindowExW(0, std.unicode.utf8ToUtf16LeStringLiteral("BUTTON"), std.unicode.utf8ToUtf16LeStringLiteral("Activate"), c.WS_CHILD | c.WS_VISIBLE | c.BS_PUSHBUTTON, 12, 238, 90, 28, hwnd, null, c.GetModuleHandleW(null), null);
            g_session_overview_new_hwnd = c.CreateWindowExW(0, std.unicode.utf8ToUtf16LeStringLiteral("BUTTON"), std.unicode.utf8ToUtf16LeStringLiteral("New Session..."), c.WS_CHILD | c.WS_VISIBLE | c.BS_PUSHBUTTON, 112, 238, 120, 28, hwnd, null, c.GetModuleHandleW(null), null);
            g_session_overview_close_hwnd = c.CreateWindowExW(0, std.unicode.utf8ToUtf16LeStringLiteral("BUTTON"), std.unicode.utf8ToUtf16LeStringLiteral("Close"), c.WS_CHILD | c.WS_VISIBLE | c.BS_PUSHBUTTON, 312, 238, 80, 28, hwnd, null, c.GetModuleHandleW(null), null);
            refreshSessionOverview(app);
            return 0;
        },
        c.WM_COMMAND => {
            const code = (wParam >> 16) & 0xFFFF;
            // Button HWND values arriving in lParam have no alignment
            // guarantee; comparing raw addresses instead of going through
            // @ptrFromInt (which would trip Zig's Debug alignment check
            // on low-bit-set handles) sidesteps the issue.
            const source_addr: usize = if (lParam == 0) 0 else @bitCast(lParam);
            const new_addr: usize = if (g_session_overview_new_hwnd) |h| @intFromPtr(h) else 0;
            const close_addr: usize = if (g_session_overview_close_hwnd) |h| @intFromPtr(h) else 0;
            const activate_addr: usize = if (g_session_overview_activate_hwnd) |h| @intFromPtr(h) else 0;
            const list_addr: usize = if (g_session_overview_list_hwnd) |h| @intFromPtr(h) else 0;
            if (source_addr == new_addr and new_addr != 0) {
                if (g_session_overview_owner) |owner| {
                    const app: *App = @ptrFromInt(@as(usize, @bitCast(c.GetWindowLongPtrW(hwnd, c.GWLP_USERDATA))));
                    showConnectionDialog(app, owner);
                }
                return 0;
            }
            if (source_addr == close_addr and close_addr != 0) {
                _ = c.DestroyWindow(hwnd);
                return 0;
            }
            if ((source_addr == activate_addr and activate_addr != 0) or
                (source_addr == list_addr and list_addr != 0 and code == c.LBN_DBLCLK))
            {
                activateSelectedOverviewSession();
                return 0;
            }
        },
        c.WM_ACTIVATE => {
            if (wParam != 0) {
                const app: *App = @ptrFromInt(@as(usize, @bitCast(c.GetWindowLongPtrW(hwnd, c.GWLP_USERDATA))));
                refreshSessionOverview(app);
            }
            return 0;
        },
        c.WM_DESTROY => {
            g_session_overview_hwnd = null;
            g_session_overview_list_hwnd = null;
            g_session_overview_activate_hwnd = null;
            g_session_overview_new_hwnd = null;
            g_session_overview_close_hwnd = null;
            return 0;
        },
        else => {},
    }
    return c.DefWindowProcW(hwnd, msg, wParam, lParam);
}

fn connectionDialogProc(hwnd: c.HWND, msg: c.UINT, wParam: c.WPARAM, lParam: c.LPARAM) callconv(.winapi) c.LRESULT {
    switch (msg) {
        c.WM_CREATE => {
            const cs: *c.CREATESTRUCTW = @ptrFromInt(@as(usize, @bitCast(lParam)));
            const app: *App = @ptrCast(@alignCast(cs.lpCreateParams.?));
            _ = c.SetWindowLongPtrW(hwnd, c.GWLP_USERDATA, @bitCast(@intFromPtr(app)));

            _ = c.CreateWindowExW(0, std.unicode.utf8ToUtf16LeStringLiteral("STATIC"), std.unicode.utf8ToUtf16LeStringLiteral("Name"), c.WS_CHILD | c.WS_VISIBLE, 14, 14, 120, 20, hwnd, null, c.GetModuleHandleW(null), null);
            g_conn_name_hwnd = createEdit(hwnd, 14, 34, 480, null);
            _ = c.CreateWindowExW(0, std.unicode.utf8ToUtf16LeStringLiteral("STATIC"), std.unicode.utf8ToUtf16LeStringLiteral("Nvim Path"), c.WS_CHILD | c.WS_VISIBLE, 14, 64, 120, 20, hwnd, null, c.GetModuleHandleW(null), null);
            g_conn_nvim_hwnd = createEdit(hwnd, 14, 84, 480, null);

            g_conn_local_hwnd = createRadio(hwnd, std.unicode.utf8ToUtf16LeStringLiteral("Local"), 14, 120, true);
            g_conn_ssh_hwnd = createRadio(hwnd, std.unicode.utf8ToUtf16LeStringLiteral("SSH"), 110, 120, false);
            g_conn_devcontainer_hwnd = createRadio(hwnd, std.unicode.utf8ToUtf16LeStringLiteral("Devcontainer"), 180, 120, false);

            _ = c.CreateWindowExW(0, std.unicode.utf8ToUtf16LeStringLiteral("STATIC"), std.unicode.utf8ToUtf16LeStringLiteral("SSH Host"), c.WS_CHILD | c.WS_VISIBLE, 14, 154, 120, 20, hwnd, null, c.GetModuleHandleW(null), null);
            g_conn_ssh_host_hwnd = createEdit(hwnd, 14, 174, 240, null);
            _ = c.CreateWindowExW(0, std.unicode.utf8ToUtf16LeStringLiteral("STATIC"), std.unicode.utf8ToUtf16LeStringLiteral("SSH Port"), c.WS_CHILD | c.WS_VISIBLE, 266, 154, 80, 20, hwnd, null, c.GetModuleHandleW(null), null);
            g_conn_ssh_port_hwnd = createEdit(hwnd, 266, 174, 70, null);
            _ = c.CreateWindowExW(0, std.unicode.utf8ToUtf16LeStringLiteral("STATIC"), std.unicode.utf8ToUtf16LeStringLiteral("SSH Identity"), c.WS_CHILD | c.WS_VISIBLE, 14, 204, 120, 20, hwnd, null, c.GetModuleHandleW(null), null);
            g_conn_ssh_identity_hwnd = createEdit(hwnd, 14, 224, 480, null);

            _ = c.CreateWindowExW(0, std.unicode.utf8ToUtf16LeStringLiteral("STATIC"), std.unicode.utf8ToUtf16LeStringLiteral("Devcontainer Workspace"), c.WS_CHILD | c.WS_VISIBLE, 14, 258, 180, 20, hwnd, null, c.GetModuleHandleW(null), null);
            g_conn_devcontainer_workspace_hwnd = createEdit(hwnd, 14, 278, 480, null);
            _ = c.CreateWindowExW(0, std.unicode.utf8ToUtf16LeStringLiteral("STATIC"), std.unicode.utf8ToUtf16LeStringLiteral("Devcontainer Config"), c.WS_CHILD | c.WS_VISIBLE, 14, 308, 180, 20, hwnd, null, c.GetModuleHandleW(null), null);
            g_conn_devcontainer_config_hwnd = createEdit(hwnd, 14, 328, 480, null);
            g_conn_devcontainer_rebuild_hwnd = createCheck(hwnd, std.unicode.utf8ToUtf16LeStringLiteral("Rebuild on start"), 14, 358, false);

            g_conn_ext_cmdline_hwnd = createCheck(hwnd, std.unicode.utf8ToUtf16LeStringLiteral("ext-cmdline"), 14, 392, app.ext_cmdline_enabled);
            g_conn_ext_popup_hwnd = createCheck(hwnd, std.unicode.utf8ToUtf16LeStringLiteral("ext-popupmenu"), 130, 392, app.config.popup.external);
            g_conn_ext_messages_hwnd = createCheck(hwnd, std.unicode.utf8ToUtf16LeStringLiteral("ext-messages"), 260, 392, app.ext_messages_enabled);
            g_conn_ext_tabline_hwnd = createCheck(hwnd, std.unicode.utf8ToUtf16LeStringLiteral("ext-tabline"), 14, 418, app.ext_tabline_enabled);
            g_conn_ext_windows_hwnd = createCheck(hwnd, std.unicode.utf8ToUtf16LeStringLiteral("ext-windows"), 130, 418, app.ext_windows_enabled);

            g_conn_connect_hwnd = c.CreateWindowExW(0, std.unicode.utf8ToUtf16LeStringLiteral("BUTTON"), std.unicode.utf8ToUtf16LeStringLiteral("Connect"), c.WS_CHILD | c.WS_VISIBLE | c.BS_DEFPUSHBUTTON, 314, 450, 86, 28, hwnd, null, c.GetModuleHandleW(null), null);
            g_conn_cancel_hwnd = c.CreateWindowExW(0, std.unicode.utf8ToUtf16LeStringLiteral("BUTTON"), std.unicode.utf8ToUtf16LeStringLiteral("Cancel"), c.WS_CHILD | c.WS_VISIBLE | c.BS_PUSHBUTTON, 408, 450, 86, 28, hwnd, null, c.GetModuleHandleW(null), null);
            return 0;
        },
        c.WM_COMMAND => {
            // Button HWND values arriving in lParam have no alignment
            // guarantee; compare raw addresses instead of going through
            // @ptrFromInt (which would trip Zig's Debug alignment check
            // on low-bit-set handles).
            const source_addr: usize = if (lParam == 0) 0 else @bitCast(lParam);
            const cancel_addr: usize = if (g_conn_cancel_hwnd) |h| @intFromPtr(h) else 0;
            const connect_addr: usize = if (g_conn_connect_hwnd) |h| @intFromPtr(h) else 0;
            if (source_addr == cancel_addr and cancel_addr != 0) {
                _ = c.DestroyWindow(hwnd);
                return 0;
            }
            if (source_addr == connect_addr and connect_addr != 0) {
                if (applog.isEnabled()) applog.appLog("[win] connection dialog: Connect clicked\n", .{});
                // The owner window's handle is the parent passed to
                // CreateWindowExW — that's where we dispatch the deferred
                // tile-creation message so it runs against the main zonvie
                // window, not the dialog.
                const owner = c.GetWindow(hwnd, c.GW_OWNER);
                const owner_for_tile = owner orelse hwnd;
                const app_opt: ?*App = blk: {
                    const v = c.GetWindowLongPtrW(hwnd, c.GWLP_USERDATA);
                    if (v == 0) break :blk null;
                    break :blk @ptrFromInt(@as(usize, @bitCast(v)));
                };
                if (app_opt) |app| {
                    const ok = launchConfiguredSession(app, owner_for_tile);
                    if (applog.isEnabled()) applog.appLog("[win] connection dialog: launchConfiguredSession -> {}\n", .{ok});
                    if (ok) {
                        _ = c.DestroyWindow(hwnd);
                    }
                } else if (applog.isEnabled()) {
                    applog.appLog("[win] connection dialog: GWLP_USERDATA missing, leaving dialog open\n", .{});
                }
                return 0;
            }
        },
        c.WM_CLOSE => {
            _ = c.DestroyWindow(hwnd);
            return 0;
        },
        c.WM_DESTROY => {
            g_connection_dialog_hwnd = null;
            g_conn_connect_hwnd = null;
            g_conn_cancel_hwnd = null;
            return 0;
        },
        else => {},
    }
    return c.DefWindowProcW(hwnd, msg, wParam, lParam);
}

fn refreshSessionOverview(app: *App) void {
    const list_hwnd = g_session_overview_list_hwnd orelse return;
    _ = c.SendMessageW(list_hwnd, c.LB_RESETCONTENT, 0, 0);

    var sessions = std.ArrayListUnmanaged(session_registry.SessionInfo){};
    defer sessions.deinit(app.alloc);
    session_registry.loadSessions(app.alloc, &sessions);

    for (sessions.items) |session| {
        // HWND values have no alignment guarantee; go through align(1)
        // opaque to bypass Zig's Debug @ptrFromInt check (see
        // window.zig:hwndFromUsize comment).
        const target_raw: *align(1) anyopaque = @ptrFromInt(session.hwnd);
        const target_hwnd: c.HWND = @ptrCast(target_raw);
        if (c.IsWindow(target_hwnd) == 0) continue;

        var label_w: [320]u16 = std.mem.zeroes([320]u16);
        const label_len = std.unicode.utf8ToUtf16Le(&label_w, session.displayLabel()) catch 0;
        label_w[@min(label_len, label_w.len - 1)] = 0;
        const index = c.SendMessageW(list_hwnd, c.LB_ADDSTRING, 0, @bitCast(@intFromPtr(&label_w)));
        _ = c.SendMessageW(list_hwnd, c.LB_SETITEMDATA, @bitCast(index), @bitCast(session.hwnd));
    }
}

fn activateSelectedOverviewSession() void {
    const list_hwnd = g_session_overview_list_hwnd orelse return;
    const sel = c.SendMessageW(list_hwnd, c.LB_GETCURSEL, 0, 0);
    if (sel == c.LB_ERR) return;
    const hwnd_value: usize = @intCast(c.SendMessageW(list_hwnd, c.LB_GETITEMDATA, @bitCast(sel), 0));
    if (hwnd_value == 0) return;
    // Same alignment-bypass pattern as the loop above; HWND values may
    // carry low-bits set.
    const target_raw: *align(1) anyopaque = @ptrFromInt(hwnd_value);
    const target_hwnd: c.HWND = @ptrCast(target_raw);
    if (c.IsWindow(target_hwnd) == 0) return;
    if (c.IsIconic(target_hwnd) != 0) {
        _ = c.ShowWindow(target_hwnd, c.SW_RESTORE);
    } else {
        _ = c.ShowWindow(target_hwnd, c.SW_SHOW);
    }
    _ = c.SetForegroundWindow(target_hwnd);
}

fn launchConfiguredSession(app: *App, owner_hwnd: c.HWND) bool {
    var config = app_mod.workspace_mod.ConnectionConfig{};

    // Consume the target slot the user clicked in the overview (if any).
    // Reset immediately so a subsequent plain "New Session..." from the
    // system menu doesn't inherit the stale hint.
    config.target_tile_index = g_connection_dialog_target_idx;
    g_connection_dialog_target_idx = null;

    var utf8_buf: [512]u8 = undefined;
    const name = readWindowTextUtf8(g_conn_name_hwnd, &utf8_buf);
    config.setName(name);

    var nvim_buf: [512]u8 = undefined;
    config.setNvimPath(readWindowTextUtf8(g_conn_nvim_hwnd, &nvim_buf));

    const is_ssh = isChecked(g_conn_ssh_hwnd);
    const is_devcontainer = isChecked(g_conn_devcontainer_hwnd);
    if (is_ssh) {
        var host_buf: [256]u8 = undefined;
        config.setSSHHost(readWindowTextUtf8(g_conn_ssh_host_hwnd, &host_buf));

        var port_buf: [32]u8 = undefined;
        const port_text = readWindowTextUtf8(g_conn_ssh_port_hwnd, &port_buf);
        if (port_text.len != 0) {
            config.ssh_port = std.fmt.parseInt(u16, port_text, 10) catch null;
        }

        var identity_buf: [512]u8 = undefined;
        config.setSSHIdentity(readWindowTextUtf8(g_conn_ssh_identity_hwnd, &identity_buf));
    } else if (is_devcontainer) {
        var workspace_buf: [512]u8 = undefined;
        config.setDevcontainerWorkspace(readWindowTextUtf8(g_conn_devcontainer_workspace_hwnd, &workspace_buf));

        var dc_config_buf: [512]u8 = undefined;
        config.setDevcontainerConfig(readWindowTextUtf8(g_conn_devcontainer_config_hwnd, &dc_config_buf));
        config.devcontainer_rebuild = isChecked(g_conn_devcontainer_rebuild_hwnd);
    }

    config.ext_cmdline = isChecked(g_conn_ext_cmdline_hwnd);
    config.ext_popupmenu = isChecked(g_conn_ext_popup_hwnd);
    config.ext_messages = isChecked(g_conn_ext_messages_hwnd);
    config.ext_tabline = isChecked(g_conn_ext_tabline_hwnd);
    config.ext_windows = isChecked(g_conn_ext_windows_hwnd);

    // Defer the actual tile creation to a fresh message dispatch on the
    // UI thread. zonvie_core_start → CreateProcessW pumps messages and
    // can re-enter WM_PAINT; running everything here would panic on the
    // debug mutex recursion check. Allocate the config on the heap and
    // hand the pointer to the handler via WM_APP_CREATE_TILE lParam.
    const heap_config = app.alloc.create(app_mod.workspace_mod.ConnectionConfig) catch {
        if (applog.isEnabled()) applog.appLog("[win] launchConfiguredSession: config alloc failed, falling back to spawn\n", .{});
        return spawnConfiguredSession(&config);
    };
    heap_config.* = config;
    const lp_val: c.LPARAM = @bitCast(@as(usize, @intFromPtr(heap_config)));
    if (c.PostMessageW(owner_hwnd, app_mod.WM_APP_CREATE_TILE, 0, lp_val) == 0) {
        if (applog.isEnabled()) applog.appLog("[win] launchConfiguredSession: PostMessage failed, falling back to spawn\n", .{});
        app.alloc.destroy(heap_config);
        return spawnConfiguredSession(&config);
    }
    return true;
}

fn spawnConfiguredSession(config: *const app_mod.workspace_mod.ConnectionConfig) bool {
    var exe_path_w: [c.MAX_PATH + 1]u16 = std.mem.zeroes([c.MAX_PATH + 1]u16);
    const exe_len = c.GetModuleFileNameW(null, &exe_path_w, c.MAX_PATH);
    if (exe_len == 0 or exe_len >= c.MAX_PATH) return false;
    exe_path_w[exe_len] = 0;

    var cmd_buf: [4096]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&cmd_buf);
    const writer = fbs.writer();
    writer.writeByte('"') catch return false;
    writeWideAsUtf8(writer, exe_path_w[0..exe_len]) catch return false;
    writer.writeByte('"') catch return false;

    if (config.nvimPath().len != 0) {
        writer.writeAll(" --nvim \"") catch return false;
        writer.writeAll(config.nvimPath()) catch return false;
        writer.writeByte('"') catch return false;
    }
    if (config.isSSH()) {
        writer.writeAll(" --ssh \"") catch return false;
        writer.writeAll(config.sshHost()) catch return false;
        if (config.ssh_port) |port| {
            writer.print(":{d}", .{port}) catch return false;
        }
        writer.writeByte('"') catch return false;
        if (config.sshIdentity().len != 0) {
            writer.writeAll(" --ssh-identity \"") catch return false;
            writer.writeAll(config.sshIdentity()) catch return false;
            writer.writeByte('"') catch return false;
        }
    } else if (config.isDevcontainer()) {
        writer.writeAll(" --devcontainer \"") catch return false;
        writer.writeAll(config.devcontainerWorkspace()) catch return false;
        writer.writeByte('"') catch return false;
        if (config.devcontainerConfig().len != 0) {
            writer.writeAll(" --devcontainer-config \"") catch return false;
            writer.writeAll(config.devcontainerConfig()) catch return false;
            writer.writeByte('"') catch return false;
        }
        if (config.devcontainer_rebuild) {
            writer.writeAll(" --devcontainer-rebuild") catch return false;
        }
    }
    if (config.ext_cmdline) writer.writeAll(" --extcmdline") catch return false;
    if (config.ext_popupmenu) writer.writeAll(" --extpopup") catch return false;
    if (config.ext_messages) writer.writeAll(" --extmessages") catch return false;
    if (config.ext_tabline) writer.writeAll(" --exttabline") catch return false;
    if (config.ext_windows) writer.writeAll(" --extwindows") catch return false;

    var cmd_w: [4096]u16 = std.mem.zeroes([4096]u16);
    const cmd_utf8 = cmd_buf[0..fbs.pos];
    const cmd_w_len = std.unicode.utf8ToUtf16Le(&cmd_w, cmd_utf8) catch return false;
    cmd_w[cmd_w_len] = 0;

    var previous_name: [512]u16 = std.mem.zeroes([512]u16);
    const previous_len = c.GetEnvironmentVariableW(std.unicode.utf8ToUtf16LeStringLiteral("ZONVIE_INTERNAL_WORKSPACE_NAME"), &previous_name, previous_name.len);
    const had_previous = previous_len > 0 and previous_len < previous_name.len;
    if (config.name().len != 0) {
        var name_w: [256]u16 = std.mem.zeroes([256]u16);
        const name_w_len = std.unicode.utf8ToUtf16Le(&name_w, config.name()) catch return false;
        name_w[name_w_len] = 0;
        _ = c.SetEnvironmentVariableW(std.unicode.utf8ToUtf16LeStringLiteral("ZONVIE_INTERNAL_WORKSPACE_NAME"), &name_w);
    } else {
        _ = c.SetEnvironmentVariableW(std.unicode.utf8ToUtf16LeStringLiteral("ZONVIE_INTERNAL_WORKSPACE_NAME"), null);
    }

    var si: c.STARTUPINFOW = std.mem.zeroes(c.STARTUPINFOW);
    si.cb = @sizeOf(c.STARTUPINFOW);
    var pi: c.PROCESS_INFORMATION = std.mem.zeroes(c.PROCESS_INFORMATION);
    if (applog.isEnabled()) applog.appLog("[win] spawnConfiguredSession: cmd={s}\n", .{cmd_utf8});
    const create_ok = c.CreateProcessW(&exe_path_w, &cmd_w, null, null, 0, 0, null, null, &si, &pi);
    if (create_ok == 0 and applog.isEnabled()) {
        const err = c.GetLastError();
        applog.appLog("[win] spawnConfiguredSession: CreateProcessW failed, GetLastError={d}\n", .{err});
    }

    if (had_previous) {
        previous_name[previous_len] = 0;
        _ = c.SetEnvironmentVariableW(std.unicode.utf8ToUtf16LeStringLiteral("ZONVIE_INTERNAL_WORKSPACE_NAME"), &previous_name);
    } else {
        _ = c.SetEnvironmentVariableW(std.unicode.utf8ToUtf16LeStringLiteral("ZONVIE_INTERNAL_WORKSPACE_NAME"), null);
    }

    if (create_ok == 0) return false;
    _ = c.CloseHandle(pi.hProcess);
    _ = c.CloseHandle(pi.hThread);
    return true;
}

fn createEdit(parent: c.HWND, x: c_int, y: c_int, w: c_int, initial: ?[*:0]const u16) ?c.HWND {
    const hwnd = c.CreateWindowExW(
        c.WS_EX_CLIENTEDGE,
        std.unicode.utf8ToUtf16LeStringLiteral("EDIT"),
        initial,
        c.WS_CHILD | c.WS_VISIBLE | c.WS_TABSTOP | c.ES_AUTOHSCROLL,
        x,
        y,
        w,
        24,
        parent,
        null,
        c.GetModuleHandleW(null),
        null,
    );
    return hwnd;
}

fn createRadio(parent: c.HWND, text: [*:0]const u16, x: c_int, y: c_int, checked: bool) ?c.HWND {
    const style: c.DWORD =
        @as(c.DWORD, @intCast(c.WS_CHILD)) |
        @as(c.DWORD, @intCast(c.WS_VISIBLE)) |
        @as(c.DWORD, @intCast(c.WS_TABSTOP)) |
        @as(c.DWORD, @intCast(c.BS_AUTORADIOBUTTON)) |
        if (checked) @as(c.DWORD, @intCast(c.WS_GROUP)) else 0;
    const hwnd = c.CreateWindowExW(
        0,
        std.unicode.utf8ToUtf16LeStringLiteral("BUTTON"),
        text,
        style,
        x,
        y,
        120,
        20,
        parent,
        null,
        c.GetModuleHandleW(null),
        null,
    );
    if (checked and hwnd != null) _ = c.SendMessageW(hwnd, c.BM_SETCHECK, c.BST_CHECKED, 0);
    return hwnd;
}

fn createCheck(parent: c.HWND, text: [*:0]const u16, x: c_int, y: c_int, checked: bool) ?c.HWND {
    const hwnd = c.CreateWindowExW(
        0,
        std.unicode.utf8ToUtf16LeStringLiteral("BUTTON"),
        text,
        c.WS_CHILD | c.WS_VISIBLE | c.WS_TABSTOP | c.BS_AUTOCHECKBOX,
        x,
        y,
        140,
        20,
        parent,
        null,
        c.GetModuleHandleW(null),
        null,
    );
    if (checked and hwnd != null) _ = c.SendMessageW(hwnd, c.BM_SETCHECK, c.BST_CHECKED, 0);
    return hwnd;
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

fn writeWideAsUtf8(writer: anytype, wide: []const u16) !void {
    var buf: [1024]u8 = undefined;
    const len = try std.unicode.utf16LeToUtf8(&buf, wide);
    try writer.writeAll(buf[0..len]);
}
