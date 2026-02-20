const std = @import("std");
const app_mod = @import("app.zig");
const App = app_mod.App;
const c = app_mod.c;
const applog = app_mod.applog;
const builtin = @import("builtin");
const config_mod = app_mod.config_mod;
const dialogs = @import("ui/dialogs.zig");
const window = @import("window.zig");

pub const std_options = std.Options{
    .log_level = .debug,
    .enable_segfault_handler = true,
};

/// Custom panic handler for debug builds that prints stack traces.
/// In release builds, falls back to std default behavior.
pub fn panic(
    msg: []const u8,
    error_return_trace: ?*std.builtin.StackTrace,
    ret_addr: ?usize,
) noreturn {
    @branchHint(.cold);

    // In release builds, just use the default behavior
    if (builtin.mode != .Debug) {
        std.debug.defaultPanic(msg, ret_addr);
    }

    // Print panic message using std.debug.print (unbuffered to stderr)
    std.debug.print("\n=== ZONVIE PANIC (Debug Build) ===\n", .{});
    std.debug.print("Panic: {s}\n", .{msg});

    // Also log to app log if enabled
    if (applog.isEnabled()) {
        applog.appLog("\n=== ZONVIE PANIC (Debug Build) ===\n", .{});
        applog.appLog("Panic: {s}\n", .{msg});
    }

    // Print error return trace if available
    if (error_return_trace) |trace| {
        std.debug.print("\nError return trace:\n", .{});
        if (applog.isEnabled()) {
            applog.appLog("\nError return trace:\n", .{});
        }
        printStackTraceAddresses(trace);
    }

    // Print stack trace from current location
    std.debug.print("\nStack trace:\n", .{});
    if (applog.isEnabled()) {
        applog.appLog("\nStack trace:\n", .{});
    }
    var it = std.debug.StackIterator.init(ret_addr orelse @returnAddress(), @frameAddress());
    var addr_buf: [32]usize = undefined;
    var addr_count: usize = 0;

    // Collect addresses
    while (addr_count < addr_buf.len) {
        if (it.next()) |addr| {
            addr_buf[addr_count] = addr;
            addr_count += 1;
        } else break;
    }

    // Print addresses
    for (addr_buf[0..addr_count]) |addr| {
        std.debug.print("  0x{x:0>16}\n", .{addr});
        if (applog.isEnabled()) {
            applog.appLog("  0x{x:0>16}\n", .{addr});
        }
    }

    std.debug.print("\n=== END PANIC ===\n", .{});
    if (applog.isEnabled()) {
        applog.appLog("\n=== END PANIC ===\n", .{});
    }

    // Show message box so user can see the error on Windows
    const wide_title = comptime blk: {
        const title = "Zonvie Panic (Debug)";
        var buf: [title.len + 1]u16 = undefined;
        for (title, 0..) |ch, i| buf[i] = ch;
        buf[title.len] = 0;
        break :blk buf;
    };
    const wide_msg = comptime blk: {
        const m = "A panic occurred. Check stderr/log for stack trace.";
        var buf: [m.len + 1]u16 = undefined;
        for (m, 0..) |ch, i| buf[i] = ch;
        buf[m.len] = 0;
        break :blk buf;
    };
    _ = c.MessageBoxW(null, &wide_msg, &wide_title, c.MB_OK | c.MB_ICONERROR);

    std.process.abort();
}

fn printStackTraceAddresses(trace: *std.builtin.StackTrace) void {
    for (trace.instruction_addresses[0..@min(trace.index, trace.instruction_addresses.len)]) |addr| {
        std.debug.print("  0x{x:0>16}\n", .{addr});
        if (applog.isEnabled()) {
            applog.appLog("  0x{x:0>16}\n", .{addr});
        }
    }
}

// DPI functions (Windows 10 v1607+, user32.dll)
extern "user32" fn SetProcessDpiAwarenessContext(value: ?*anyopaque) callconv(.winapi) c.BOOL;

pub fn main() u8 {
    // Enable Per-Monitor DPI Awareness V2 before any window creation.
    // Value -4 = DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2
    _ = SetProcessDpiAwarenessContext(@ptrFromInt(@as(usize, @bitCast(@as(isize, -4)))));

    // Check for askpass mode via environment variable (SSH_ASKPASS helper)
    // SSH calls the program specified in SSH_ASKPASS, so we detect mode via env var
    const ATTACH_PARENT_PROCESS: c.DWORD = 0xFFFFFFFF;
    var askpass_mode_buf: [8]u8 = undefined;
    const askpass_mode_len = c.GetEnvironmentVariableA("ZONVIE_ASKPASS_MODE", &askpass_mode_buf, askpass_mode_buf.len);
    if (askpass_mode_len > 0) {
        // Askpass mode: output password to stdout and exit
        // First check if password is pre-set in environment
        var pwd_buf: [256]u8 = undefined;
        const pwd_len = c.GetEnvironmentVariableA("ZONVIE_SSH_PASSWORD", &pwd_buf, pwd_buf.len);

        // Attach to parent console for stdout output
        _ = c.AttachConsole(ATTACH_PARENT_PROCESS);
        const stdout = c.GetStdHandle(c.STD_OUTPUT_HANDLE);

        if (pwd_len > 0 and pwd_len < pwd_buf.len) {
            // Use pre-set password
            if (stdout != c.INVALID_HANDLE_VALUE) {
                var written: c.DWORD = 0;
                _ = c.WriteFile(stdout, &pwd_buf, pwd_len, &written, null);
                _ = c.WriteFile(stdout, "\n", 1, &written, null);
            }
        } else {
            // No pre-set password: show input dialog
            // Get prompt from command line args (SSH passes prompt as arg)
            var prompt_buf: [256]u16 = undefined;
            const cmdline = c.GetCommandLineW();
            if (cmdline != null) {
                // Parse to get prompt (usually "Enter passphrase for key '...':")
                var i: usize = 0;
                var in_quote = false;
                var arg_start: usize = 0;
                var arg_count: usize = 0;
                const cmdline_slice = std.mem.span(cmdline);
                while (i < cmdline_slice.len) : (i += 1) {
                    const ch = cmdline_slice[i];
                    if (ch == '"') {
                        in_quote = !in_quote;
                    } else if (ch == ' ' and !in_quote) {
                        if (arg_count == 0) {
                            // Skip first arg (exe path)
                            arg_count = 1;
                            arg_start = i + 1;
                        } else {
                            break; // Found second arg
                        }
                    }
                }
                // Copy prompt to buffer
                const prompt_end = @min(i, arg_start + prompt_buf.len - 1);
                if (prompt_end > arg_start) {
                    @memcpy(prompt_buf[0 .. prompt_end - arg_start], cmdline_slice[arg_start..prompt_end]);
                    prompt_buf[prompt_end - arg_start] = 0;
                } else {
                    const default_prompt = std.unicode.utf8ToUtf16LeStringLiteral("Enter password:");
                    @memcpy(prompt_buf[0..default_prompt.len], default_prompt);
                    prompt_buf[default_prompt.len] = 0;
                }
            } else {
                const default_prompt = std.unicode.utf8ToUtf16LeStringLiteral("Enter password:");
                @memcpy(prompt_buf[0..default_prompt.len], default_prompt);
                prompt_buf[default_prompt.len] = 0;
            }

            // Show simple password input dialog using InputBox-style approach
            // Use GetSaveFileNameW trick or simple MessageBox + clipboard workaround
            // For now, use a simple approach: create a tiny window with password field
            var password: [256]u16 = undefined;
            password[0] = 0;
            const dialog_result = dialogs.showPasswordInputDialog(&prompt_buf, &password);

            if (dialog_result and stdout != c.INVALID_HANDLE_VALUE) {
                // Convert UTF-16 password to UTF-8 and write to stdout
                var utf8_pwd: [512]u8 = undefined;
                var utf8_len: usize = 0;
                for (password) |wch| {
                    if (wch == 0) break;
                    if (wch < 0x80) {
                        if (utf8_len < utf8_pwd.len) {
                            utf8_pwd[utf8_len] = @truncate(wch);
                            utf8_len += 1;
                        }
                    }
                }
                var written: c.DWORD = 0;
                _ = c.WriteFile(stdout, &utf8_pwd, @intCast(utf8_len), &written, null);
                _ = c.WriteFile(stdout, "\n", 1, &written, null);
            }
        }
        return 0; // Exit immediately
    }

    // Initialize startup timing
    _ = c.QueryPerformanceFrequency(&app_mod.g_startup_freq);
    _ = c.QueryPerformanceCounter(&app_mod.g_startup_t0);

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    // Load configuration from config.toml
    var t1: c.LARGE_INTEGER = undefined;
    var t2: c.LARGE_INTEGER = undefined;
    _ = c.QueryPerformanceCounter(&t1);
    const config_result = config_mod.loadWithPath(alloc);
    var config = config_result.config;
    _ = c.QueryPerformanceCounter(&t2);
    const config_ms = @divTrunc((t2.QuadPart - t1.QuadPart) * 1000, app_mod.g_startup_freq.QuadPart);
    defer config.deinit();
    defer if (config_result.path) |p| alloc.free(p);

    // Early debug: write config info to a debug file (before applog is enabled)
    if (std.fs.createFileAbsolute("C:\\Users\\MaruyamaAkiyoshi\\Dev\\zonvie_config_debug.txt", .{ .truncate = true })) |dbg_file| {
        defer dbg_file.close();
        var buf: [1024]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Config path: {s}\nlog.enabled: {}\nlog.path: {s}\nroutes_count: {d}\nroutes_allocated: {}\n", .{
            config_result.path orelse "(none)",
            config.log.enabled,
            config.log.path orelse "(null)",
            config.messages.routes.len,
            config.routes_allocated,
        }) catch "fmt error";
        _ = dbg_file.write(msg) catch {};
    } else |_| {}

    // Parse command line arguments (override config)
    var ext_cmdline_enabled = config.cmdline.external;
    var ext_popup_enabled = config.popup.external;
    var ext_messages_enabled = config.messages.external;
    var ext_tabline_enabled = config.tabline.external;
    var tabline_style: app_mod.TablineStyle = .titlebar;
    var sidebar_position_right: bool = false;
    var sidebar_width_px: u32 = 200;
    if (ext_tabline_enabled) {
        if (std.mem.eql(u8, config.tabline.style, "sidebar")) {
            tabline_style = .sidebar;
        }
        // "menu" is not supported on Windows, falls through to titlebar
        sidebar_position_right = std.mem.eql(u8, config.tabline.sidebar_position, "right");
        sidebar_width_px = config.tabline.sidebar_width;
    }
    var ext_windows_enabled = config.windows.external;
    var cli_log_path: ?[]const u8 = null;
    var wsl_mode: bool = config.neovim.wsl;
    var wsl_distro: ?[]const u8 = config.neovim.wsl_distro;
    var ssh_mode: bool = config.neovim.ssh;
    var ssh_host: ?[]const u8 = config.neovim.ssh_host;
    var ssh_port: ?u16 = config.neovim.ssh_port;
    var ssh_identity: ?[]const u8 = config.neovim.ssh_identity;
    var devcontainer_mode: bool = false;
    var devcontainer_workspace: ?[]const u8 = null;
    var devcontainer_config: ?[]const u8 = null;
    var devcontainer_rebuild: bool = false;
    const args = std.process.argsAlloc(alloc) catch return 1;
    defer std.process.argsFree(alloc, args);

    // Check for --help / -h first
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            // Attach to parent console for stdout output
            _ = c.AttachConsole(ATTACH_PARENT_PROCESS);
            const stdout = c.GetStdHandle(c.STD_OUTPUT_HANDLE);
            if (stdout != c.INVALID_HANDLE_VALUE) {
                const help_msg =
                    \\zonvie - A high-performance Neovim GUI
                    \\
                    \\USAGE:
                    \\    zonvie.exe [OPTIONS]
                    \\
                    \\OPTIONS:
                    \\    --log <path>                  Write application logs to specified file path
                    \\    --extcmdline                  Enable external command line UI
                    \\    --extpopup                    Enable external popup menu UI
                    \\    --extmessages                 Enable external messages UI
                    \\    --exttabline                  Enable external tabline UI (Chrome-style tabs)
                    \\    --extwindows                  Enable external windows UI
                    \\    --wsl                         Run Neovim inside WSL (default distro)
                    \\    --wsl=<distro>                Run Neovim inside specified WSL distro
                    \\    --ssh=<user@host[:port]>      Connect to remote host via SSH
                    \\    --ssh-identity=<path>         Path to SSH private key file
                    \\    --devcontainer=<workspace>    Run inside a devcontainer
                    \\    --devcontainer-config=<path>  Path to devcontainer.json
                    \\    --devcontainer-rebuild        Rebuild devcontainer before starting
                    \\    --install                     First-launch setup (icon + default config) and exit
                    \\    --help, -h                    Show this help message and exit
                    \\    --                            Pass all remaining arguments to nvim
                    \\
                    \\CONFIG:
                    \\    Configuration file: %APPDATA%\zonvie\config.toml
                    \\    (or %USERPROFILE%\.config\zonvie\config.toml)
                    \\
                    \\    [neovim]
                    \\        path            Path to Neovim executable
                    \\        wsl             Enable WSL mode (true/false)
                    \\        wsl_distro      WSL distribution name
                    \\        ssh             Enable SSH mode (true/false)
                    \\        ssh_host        SSH host (user@host format)
                    \\        ssh_port        SSH port number
                    \\        ssh_identity    Path to SSH private key
                    \\
                    \\    [font]
                    \\        family          Font family name
                    \\        size            Font size in points
                    \\        linespace       Extra line spacing in pixels
                    \\
                    \\    [cmdline]
                    \\        external        Enable external command line UI
                    \\
                    \\    [popup]
                    \\        external        Enable external popup menu UI
                    \\
                    \\    [messages]
                    \\        external        Enable external messages UI
                    \\
                    \\    [tabline]
                    \\        external        Enable external tabline UI
                    \\
                    \\    [log]
                    \\        enabled         Enable logging (true/false)
                    \\        path            Log file path
                    \\
                    \\    [performance]
                    \\        glyph_cache_ascii_size      ASCII glyph cache size (min: 128)
                    \\        glyph_cache_non_ascii_size  Non-ASCII glyph cache size (min: 64)
                    \\        hl_cache_size               Highlight cache size (64-2048, default: 512)
                    \\        shape_cache_size            Shape cache size (512-65536, default: 4096)
                    \\
                    \\For more information, visit: https://github.com/akiyosi/zonvie
                    \\
                ;
                var written: c.DWORD = 0;
                _ = c.WriteFile(stdout, help_msg.ptr, help_msg.len, &written, null);
            }
            return 0;
        }
        if (std.mem.eql(u8, arg, "--install")) {
            const file_assoc = @import("file_assoc.zig");
            const icon_ok = file_assoc.registerAppIcon();
            const config_result2 = createDefaultConfig(alloc);
            const has_error = !icon_ok or config_result2 == .err;

            _ = c.AttachConsole(ATTACH_PARENT_PROCESS);
            const stdout = c.GetStdHandle(c.STD_OUTPUT_HANDLE);
            if (stdout != c.INVALID_HANDLE_VALUE) {
                var written: c.DWORD = 0;
                if (icon_ok) {
                    const m = "File association icon registered.\r\n";
                    _ = c.WriteFile(stdout, m.ptr, @intCast(m.len), &written, null);
                } else {
                    const m = "ERROR: Failed to register file association icon.\r\n";
                    _ = c.WriteFile(stdout, m.ptr, @intCast(m.len), &written, null);
                }
                switch (config_result2) {
                    .created => {
                        const m = "Default config.toml created.\r\n";
                        _ = c.WriteFile(stdout, m.ptr, @intCast(m.len), &written, null);
                    },
                    .already_exists => {
                        const m = "Config file already exists, skipped.\r\n";
                        _ = c.WriteFile(stdout, m.ptr, @intCast(m.len), &written, null);
                    },
                    .err => {
                        const m = "ERROR: Failed to create config file.\r\n";
                        _ = c.WriteFile(stdout, m.ptr, @intCast(m.len), &written, null);
                    },
                }
            }
            return if (has_error) 1 else 0;
        }
    }

    // First launch (no config file) — register file association icon and create default config.
    // Placed after --help / --install early-exit loop so those commands stay side-effect-free.
    if (config_result.path == null) {
        const file_assoc = @import("file_assoc.zig");
        _ = file_assoc.registerAppIcon();
        _ = createDefaultConfig(alloc);
    }

    // Collect arguments that are NOT zonvie-specific (these will be passed to nvim)
    // After "--", all remaining arguments are passed to nvim
    var nvim_extra_args = std.ArrayListUnmanaged([]const u8){};
    var pass_all_to_nvim = false;

    var i: usize = 1; // Skip argv[0] (executable path)
    while (i < args.len) : (i += 1) {
        const arg = args[i];

        // After "--", pass all remaining arguments to nvim
        if (std.mem.eql(u8, arg, "--")) {
            pass_all_to_nvim = true;
            continue;
        }

        if (pass_all_to_nvim) {
            nvim_extra_args.append(alloc, arg) catch {};
            continue;
        }

        if (std.mem.eql(u8, arg, "--extcmdline")) {
            ext_cmdline_enabled = true;
            applog.appLog("[win] --extcmdline flag detected (override config)\n", .{});
        } else if (std.mem.eql(u8, arg, "--extpopup")) {
            ext_popup_enabled = true;
            applog.appLog("[win] --extpopup flag detected (override config)\n", .{});
        } else if (std.mem.eql(u8, arg, "--extmessages")) {
            ext_messages_enabled = true;
            applog.appLog("[win] --extmessages flag detected (override config)\n", .{});
        } else if (std.mem.eql(u8, arg, "--exttabline")) {
            ext_tabline_enabled = true;
            applog.appLog("[win] --exttabline flag detected (override config)\n", .{});
        } else if (std.mem.eql(u8, arg, "--extwindows")) {
            ext_windows_enabled = true;
            applog.appLog("[win] --extwindows flag detected (override config)\n", .{});
        } else if (std.mem.eql(u8, arg, "--log")) {
            if (i + 1 < args.len) {
                cli_log_path = args[i + 1];
                i += 1; // skip the path argument
            }
            applog.appLog("[win] --log flag detected\n", .{});
        } else if (std.mem.eql(u8, arg, "--wsl")) {
            wsl_mode = true;
            applog.appLog("[win] --wsl flag detected\n", .{});
        } else if (std.mem.startsWith(u8, arg, "--wsl=")) {
            wsl_mode = true;
            wsl_distro = arg[6..]; // after "--wsl="
            applog.appLog("[win] --wsl={s} flag detected\n", .{wsl_distro.?});
        } else if (std.mem.startsWith(u8, arg, "--ssh=")) {
            ssh_mode = true;
            const value = arg[6..]; // after "--ssh="
            // Parse user@host:port format (port is after last colon, only if numeric)
            if (std.mem.lastIndexOfScalar(u8, value, ':')) |colon_idx| {
                const port_str = value[colon_idx + 1 ..];
                if (std.fmt.parseInt(u16, port_str, 10)) |port| {
                    ssh_host = value[0..colon_idx];
                    ssh_port = port;
                } else |_| {
                    ssh_host = value;
                }
            } else {
                ssh_host = value;
            }
            applog.appLog("[win] --ssh={s} flag detected\n", .{ssh_host.?});
        } else if (std.mem.startsWith(u8, arg, "--ssh-identity=")) {
            ssh_identity = arg[15..]; // after "--ssh-identity="
            applog.appLog("[win] --ssh-identity flag detected\n", .{});
        } else if (std.mem.startsWith(u8, arg, "--devcontainer=")) {
            devcontainer_mode = true;
            devcontainer_workspace = arg[15..]; // after "--devcontainer="
            applog.appLog("[win] --devcontainer={s} flag detected\n", .{devcontainer_workspace.?});
        } else if (std.mem.startsWith(u8, arg, "--devcontainer-config=")) {
            devcontainer_config = arg[22..]; // after "--devcontainer-config="
            applog.appLog("[win] --devcontainer-config flag detected\n", .{});
        } else if (std.mem.eql(u8, arg, "--devcontainer-rebuild")) {
            devcontainer_rebuild = true;
            applog.appLog("[win] --devcontainer-rebuild flag detected\n", .{});
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            // Already handled above, skip
        } else {
            // Not a zonvie argument - pass to nvim
            nvim_extra_args.append(alloc, arg) catch {};
        }
    }

    // Enable logging if configured (CLI --log overrides config)
    if (cli_log_path) |path| {
        applog.setEnabled(true);
        applog.setLogPath(path);
    } else if (config.log.enabled) {
        applog.setEnabled(true);
        applog.setLogPath(config.log.path);
    }

    // Log config info (after applog is enabled)
    applog.appLog("[TIMING] Config.load: {d}ms\n", .{config_ms});
    applog.appLog("[win] Config path: {s}\n", .{config_result.path orelse "(none)"});
    applog.appLog("[win] Config loaded: neovim.path={s}, font.family={s}, font.size={d}, cmdline.external={}, log.enabled={}\n", .{
        config.neovim.path,
        config.font.family,
        config.font.size,
        config.cmdline.external,
        config.log.enabled,
    });
    applog.appLog("[win] Config messages: external={}, routes_count={d}, routes_allocated={}\n", .{
        config.messages.external,
        config.messages.routes.len,
        config.routes_allocated,
    });

    // SSH mode: no early password dialog
    // SSH_ASKPASS mechanism handles password/passphrase on demand (when SSH requests it)
    const early_ssh_password: ?[]const u8 = null;
    if (ssh_mode) {
        applog.appLog("[win] SSH mode: using SSH_ASKPASS for on-demand authentication\n", .{});
    }

    const class_name: [:0]const u16 = std.unicode.utf8ToUtf16LeStringLiteral("ZonvieWin");
    const title: [:0]const u16 = std.unicode.utf8ToUtf16LeStringLiteral("zonvie (win)");

    var wc: c.WNDCLASSEXW = std.mem.zeroes(c.WNDCLASSEXW);
    wc.cbSize = @sizeOf(c.WNDCLASSEXW);
    wc.style = c.CS_HREDRAW | c.CS_VREDRAW;
    wc.lpfnWndProc = window.WndProc;
    wc.hInstance = c.GetModuleHandleW(null);
    wc.hCursor = c.LoadCursorW(null, @ptrFromInt(32512)); // IDC_ARROW
    wc.hbrBackground = null;
    wc.lpszClassName = @ptrCast(class_name.ptr);

    if (c.RegisterClassExW(&wc) == 0) return 1;


    const app = alloc.create(App) catch return 1;
    // errdefer alloc.destroy(app); // ← Remove this (causes double-free)

    app.* = .{
        .alloc = alloc,
        .config = config,
        .ext_cmdline_enabled = ext_cmdline_enabled,
        .ext_messages_enabled = ext_messages_enabled,
        .ext_tabline_enabled = ext_tabline_enabled,
        .tabline_style = tabline_style,
        .sidebar_position_right = sidebar_position_right,
        .sidebar_width_px = sidebar_width_px,
        .ext_windows_enabled = ext_windows_enabled,
        .wsl_mode = wsl_mode,
        .wsl_distro = wsl_distro,
        .ssh_mode = ssh_mode,
        .ssh_host = ssh_host,
        .ssh_port = ssh_port,
        .ssh_identity = ssh_identity,
        .ssh_password = early_ssh_password, // Set password from early dialog
        .devcontainer_mode = devcontainer_mode,
        .devcontainer_workspace = devcontainer_workspace,
        .devcontainer_config = devcontainer_config,
        .devcontainer_rebuild = devcontainer_rebuild,
        .nvim_extra_args = nvim_extra_args,
    };

    // Prevent config.deinit from freeing strings now owned by app
    const opacity = app.config.window.opacity;
    config = .{};

    applog.appLog("[win] opacity={d:.2}\n", .{opacity});

    // Use WS_EX_NOREDIRECTIONBITMAP for DirectComposition-based transparency
    const dwExStyle: c.DWORD = if (opacity < 1.0) c.WS_EX_NOREDIRECTIONBITMAP else 0;

    // Custom D3D11 overlay scrollbar (no WS_VSCROLL)
    const window_style: c.DWORD = c.WS_OVERLAPPEDWINDOW | c.WS_VISIBLE;

    _ = c.QueryPerformanceCounter(&t1);
    const hwnd = c.CreateWindowExW(
        dwExStyle,
        @ptrCast(class_name.ptr),
        @ptrCast(title.ptr),
        window_style,
        c.CW_USEDEFAULT, c.CW_USEDEFAULT,
        1000, 700,
        null, null,
        wc.hInstance,
        app, // lpParam -> WM_NCCREATE
    );
    _ = c.QueryPerformanceCounter(&t2);
    const createwin_ms = @divTrunc((t2.QuadPart - t1.QuadPart) * 1000, app_mod.g_startup_freq.QuadPart);
    applog.appLog("[TIMING] CreateWindowExW: {d}ms\n", .{createwin_ms});

    if (hwnd == null) {
        if (!app.owned_by_hwnd) {
            alloc.destroy(app);
        }
        return 1;
    }

    var msg: c.MSG = undefined;
    while (c.GetMessageW(&msg, null, 0, 0) > 0) {
        _ = c.TranslateMessage(&msg);
        _ = c.DispatchMessageW(&msg);
    }

    // Return nvim's exit code (Nvy style - return from main instead of ExitProcess)
    const exit_code = app_mod.g_exit_code.load(.seq_cst);
    if (applog.isEnabled()) applog.appLog("[win] message loop ended, returning exit_code={d}\n", .{exit_code});
    return exit_code;
}

const ConfigCreateResult = enum { created, already_exists, err };

/// Create default config.toml at %APPDATA%\zonvie\config.toml if it doesn't exist.
fn createDefaultConfig(alloc: std.mem.Allocator) ConfigCreateResult {
    const appdata = std.process.getEnvVarOwned(alloc, "APPDATA") catch return .err;
    defer alloc.free(appdata);

    const dir_path = std.fs.path.join(alloc, &.{ appdata, "zonvie" }) catch return .err;
    defer alloc.free(dir_path);

    const file_path = std.fs.path.join(alloc, &.{ dir_path, "config.toml" }) catch return .err;
    defer alloc.free(file_path);

    // Skip if config already exists
    if (std.fs.accessAbsolute(file_path, .{})) |_| {
        return .already_exists;
    } else |_| {}

    // Create directory if needed
    std.fs.makeDirAbsolute(dir_path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return .err,
    };

    // Write default config
    const file = std.fs.createFileAbsolute(file_path, .{}) catch return .err;
    defer file.close();
    file.writeAll(default_config_toml) catch return .err;
    return .created;
}

const default_config_toml =
    \\# Zonvie configuration file
    \\# See `zonvie.exe --help` for all available options.
    \\
    \\[font]
    \\# family = "Consolas"
    \\# size = 14.0
    \\# linespace = 0
    \\
    \\[neovim]
    \\# path = "nvim"
    \\
    \\[window]
    \\# opacity = 1.0
    \\
;
