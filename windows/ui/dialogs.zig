const std = @import("std");
const app_mod = @import("../app.zig");
const App = app_mod.App;
const c = app_mod.c;
const applog = app_mod.applog;

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
