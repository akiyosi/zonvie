const std = @import("std");
const clock = @import("zonvie_core").clock;
const app_mod = @import("app.zig");
const App = app_mod.App;
const c = app_mod.c;
const applog = app_mod.applog;
const config_mod = app_mod.config_mod;
const dialogs = @import("ui/dialogs.zig");
const window = @import("window.zig");

pub const std_options = std.Options{
    .log_level = .debug,
    .enable_segfault_handler = true,
};

/// MAKEINTRESOURCE: turn a resource ordinal into the pointer the resource APIs
/// expect. The ordinal is never dereferenced, but a typed LPCWSTR
/// ([*c]const u16) has alignment 2, so `@ptrFromInt` of an odd ordinal (e.g. 1)
/// trips the Debug-build *runtime* alignment check and panics with
/// "incorrect alignment". (Routing through a runtime usize only defeats the
/// *comptime* check; the runtime assertion still fires.) Return an align-1
/// opaque pointer so no alignment is asserted; the resource-name parameter of
/// our local LoadIconW takes the same type, so the value never coerces back to
/// an align-2 pointer.
fn makeIntResource(id: u16) ?*const anyopaque {
    return @ptrFromInt(@as(usize, id));
}

/// user32 LoadIconW redeclared with an align-agnostic resource-name pointer
/// (see makeIntResource) and a direct HICON return, so neither the ordinal
/// argument nor the returned handle is forced through an alignment assertion.
extern "user32" fn LoadIconW(hInstance: c.HINSTANCE, lpIconName: ?*const anyopaque) callconv(.winapi) c.HICON;

/// Custom panic handler that never writes synchronously to stderr or the
/// configured log sink. Either may be a stopped pipe during teardown.
pub fn panic(
    msg: []const u8,
    error_return_trace: ?*std.builtin.StackTrace,
    ret_addr: ?usize,
) noreturn {
    @branchHint(.cold);

    applog.appLogEmergency("\n=== ZONVIE PANIC ===\n", .{});
    applog.appLogEmergency("Panic: {s}\n", .{msg});

    if (error_return_trace) |trace| {
        applog.appLogEmergency("\nError return trace:\n", .{});
        printStackTraceAddresses(trace);
    }

    applog.appLogEmergency("\nStack trace:\n", .{});
    // 0.16: std.debug.StackIterator is no longer pub. Use the supported
    // captureCurrentStackTrace API, which fills the address buffer and
    // returns a StackTrace; first_address omits frames up to ret_addr,
    // preserving the previous "start from the panic site" behavior.
    var addr_buf: [32]usize = undefined;
    const trace = std.debug.captureCurrentStackTrace(.{
        .first_address = ret_addr,
    }, &addr_buf);

    for (trace.return_addresses) |addr| {
        applog.appLogEmergency("  0x{x:0>16}\n", .{addr});
    }

    applog.appLogEmergency("\n=== END PANIC ===\n", .{});

    // Show message box so user can see the error on Windows
    const wide_title = comptime blk: {
        const title = "Zonvie Panic";
        var buf: [title.len + 1]u16 = undefined;
        for (title, 0..) |ch, i| buf[i] = ch;
        buf[title.len] = 0;
        break :blk buf;
    };
    const wide_msg = comptime blk: {
        const m = "A panic occurred. Check the debugger or log for the stack trace.";
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
        applog.appLogEmergency("  0x{x:0>16}\n", .{addr});
    }
}

// DPI functions (Windows 10 v1607+, user32.dll)
extern "user32" fn SetProcessDpiAwarenessContext(value: ?*anyopaque) callconv(.winapi) c.BOOL;

// Timer resolution (winmm.dll) — reduces scheduler quantum from ~15.6ms to 1ms.
// Without this, DWrite COM calls can be preempted for a full scheduler quantum,
// causing intermittent 10-16ms stalls in glyph rasterization during flush.
extern "winmm" fn timeBeginPeriod(uPeriod: c.UINT) callconv(.winapi) c.UINT;

const ATTACH_PARENT_PROCESS: c.DWORD = 0xFFFFFFFF;

/// Current working directory as UTF-8, or null on failure. Used to resolve
/// relative file arguments to absolute paths before forwarding them to a
/// running instance (which may have a different cwd).
fn getCwdUtf8(alloc: std.mem.Allocator) ?[]u8 {
    var stack_buf: [c.MAX_PATH]u16 = undefined;
    const len = c.GetCurrentDirectoryW(@intCast(stack_buf.len), &stack_buf);
    if (len == 0) return null;
    if (len <= stack_buf.len) {
        return std.unicode.utf16LeToUtf8Alloc(alloc, stack_buf[0..len]) catch null;
    }
    // Path longer than MAX_PATH (long-path-aware system). When the buffer is
    // too small GetCurrentDirectoryW returns the required size INCLUDING the
    // null terminator; allocate that and retry. The second call returns the
    // length EXCLUDING the null.
    const heap_buf = alloc.alloc(u16, len) catch return null;
    defer alloc.free(heap_buf);
    const len2 = c.GetCurrentDirectoryW(@intCast(heap_buf.len), heap_buf.ptr);
    if (len2 == 0 or len2 >= heap_buf.len) return null;
    return std.unicode.utf16LeToUtf8Alloc(alloc, heap_buf[0..len2]) catch null;
}

/// Single-instance mode: forward file arguments to an already-running instance
/// via WM_COPYDATA, then let the caller exit. Builds a bare Ex command (no
/// leading ':') of the form "tab drop <abs1> <abs2> ..." — or "drop <abs>" for
/// a single file when [server] open_mode == "current" — and posts it to the
/// existing window. Paths are made absolute (the running instance may have a
/// different working directory) and escaped for Neovim's command line, mirroring
/// the WM_DROPFILES handler in window.zig. An empty path list sends an empty
/// payload, which just brings the existing window to the front.
fn forwardFilesToInstance(
    alloc: std.mem.Allocator,
    target: c.HWND,
    cfg: *const config_mod.Config,
    paths: []const []const u8,
) void {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(alloc);

    if (paths.len > 0) {
        const use_current = paths.len == 1 and std.mem.eql(u8, cfg.server.open_mode, "current");
        buf.appendSlice(alloc, if (use_current) "drop" else "tab drop") catch return;

        const cwd = getCwdUtf8(alloc);
        defer if (cwd) |w| alloc.free(w);

        for (paths) |p| {
            buf.append(alloc, ' ') catch return;

            // Resolve to an absolute path against this process's cwd so the
            // running instance opens the file the user meant. Does not require
            // the file to exist (supports opening a new file).
            const abs: []const u8 = blk: {
                if (std.fs.path.isAbsolute(p)) break :blk p;
                if (cwd) |w| {
                    if (std.fs.path.join(alloc, &.{ w, p })) |joined| break :blk joined else |_| {}
                }
                break :blk p;
            };
            defer if (abs.ptr != p.ptr) alloc.free(abs);

            for (abs) |ch| {
                if (window.escapeNeovimByte(ch)) |e| buf.appendSlice(alloc, e) catch return else buf.append(alloc, ch) catch return;
            }
        }
    }

    // Grant the existing instance permission to take the foreground. Windows
    // blocks SetForegroundWindow unless the calling process is the current
    // foreground process; a freshly-launched process (this one) holds that
    // privilege briefly and can transfer it to the target via
    // AllowSetForegroundWindow. Without this the running window only flashes
    // its taskbar button instead of raising.
    var target_pid: c.DWORD = 0;
    _ = c.GetWindowThreadProcessId(target, &target_pid);
    if (target_pid != 0) _ = c.AllowSetForegroundWindow(target_pid);

    var cds: c.COPYDATASTRUCT = .{
        .dwData = window.ZONVIE_COPYDATA_MAGIC,
        .cbData = @intCast(buf.items.len),
        .lpData = if (buf.items.len > 0) buf.items.ptr else null,
    };
    _ = c.SendMessageW(target, c.WM_COPYDATA, 0, @bitCast(@intFromPtr(&cds)));
}

pub fn main() u8 {
    clock.init();
    defer applog.deinit();

    // Enable Per-Monitor DPI Awareness V2 before any window creation.
    // Value -4 = DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2.
    // Must run before the askpass branch below, which creates a password
    // dialog and exits — otherwise that dialog renders DPI-unaware (blurry).
    _ = SetProcessDpiAwarenessContext(@ptrFromInt(@as(usize, @bitCast(@as(isize, -4)))));

    // Check for askpass mode via environment variable (SSH_ASKPASS helper)
    // SSH calls the program specified in SSH_ASKPASS, so we detect mode via env var
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

    // Reduce Windows scheduler quantum to 1ms for responsive rendering.
    // DWrite glyph rasterization makes COM calls that can yield the thread;
    // default 15.6ms quantum causes 10-16ms stalls when preempted.
    _ = timeBeginPeriod(1);

    // Initialize startup timing
    _ = c.QueryPerformanceFrequency(&app_mod.g_startup_freq);
    _ = c.QueryPerformanceCounter(&app_mod.g_startup_t0);

    var gpa = std.heap.DebugAllocator(.{}){};
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
    var cli_nvim_path: ?[]const u8 = null;
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

    // Connect mode (--connect-nvim=<addr> / --remote-ui=<addr>): attach to
    // a running Neovim server instead of spawning. Mutually exclusive with
    // --wsl / --ssh / --devcontainer (and their config.toml equivalents
    // [neovim].wsl / .ssh). The combination is rejected up-front below,
    // before the App is constructed; see the validation block right after
    // argv parsing.
    var connect_addr: ?[]const u8 = null;

    // `--dialog` (no value): show the interactive connection dialog at startup
    // (Local / SSH / Devcontainer) before spawning nvim. Distinct from
    // --connect-nvim=<addr>; matched exactly below so the two never collide.
    // Mutually exclusive with the mode-fixing flags, rejected up-front below.
    var connect_dialog: bool = false;
    // 0.16: std.process.argsAlloc/argsFree were removed. Obtain the current
    // process command line from the Windows PEB (GetCommandLineW) and parse it
    // via std.process.Args.toSlice, which requires an arena that must outlive
    // every slice referenced below (mirrors the old `defer argsFree` lifetime).
    const cmdline_w = c.GetCommandLineW();
    if (cmdline_w == null) return 1;
    var args_arena = std.heap.ArenaAllocator.init(alloc);
    defer args_arena.deinit();
    const args_obj = std.process.Args{ .vector = std.mem.span(cmdline_w) };
    const args = args_obj.toSlice(args_arena.allocator()) catch return 1;

    // Check for --help / -h first. Stop at `--` so `zonvie -- --help` /
    // `zonvie -- --install` forward those tokens to nvim instead of
    // triggering zonvie's own help / installer.
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--")) break;
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
                    \\    --nvim <path>                 Path to Neovim executable (overrides config)
                    \\    --nvim=<path>                 Same as above (equals-separated)
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
                    \\    --connect-nvim=<addr>         Attach to a running Neovim server.
                    \\                                    Address: Windows named pipe path,
                    \\                                    e.g. "\\\\.\\pipe\\nvim.31920.0".
                    \\                                    (TCP / Unix sockets: not yet supported on Windows.)
                    \\                                    Mutually exclusive with --ssh / --devcontainer / --wsl.
                    \\    --remote-ui=<addr>            Alias of --connect-nvim, mirrors `nvim --remote-ui`.
                    \\    --dialog                      Show a dialog at startup to choose the connection
                    \\                                    (Local / SSH / Devcontainer) before launching nvim.
                    \\    --install                     First-launch setup (icon + default config) and exit
                    \\    --version                     Show version information and exit
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
                    \\        atlas_size                  Glyph atlas texture size (1024-4096, default: 2048)
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
        if (std.mem.eql(u8, arg, "--version")) {
            _ = c.AttachConsole(ATTACH_PARENT_PROCESS);
            const stdout = c.GetStdHandle(c.STD_OUTPUT_HANDLE);
            if (stdout != c.INVALID_HANDLE_VALUE) {
                const ver = std.mem.span(app_mod.zonvie_version());
                var written: c.DWORD = 0;
                const prefix = "zonvie ";
                _ = c.WriteFile(stdout, prefix.ptr, prefix.len, &written, null);
                _ = c.WriteFile(stdout, ver.ptr, @intCast(ver.len), &written, null);
                const nl = "\r\n";
                _ = c.WriteFile(stdout, nl.ptr, nl.len, &written, null);
            }
            return 0;
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
    var nvim_extra_args: std.ArrayListUnmanaged([]const u8) = .empty;
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
            if (applog.isEnabled()) applog.appLog("[win] --extcmdline flag detected (override config)\n", .{});
        } else if (std.mem.eql(u8, arg, "--extpopup")) {
            ext_popup_enabled = true;
            if (applog.isEnabled()) applog.appLog("[win] --extpopup flag detected (override config)\n", .{});
        } else if (std.mem.eql(u8, arg, "--extmessages")) {
            ext_messages_enabled = true;
            if (applog.isEnabled()) applog.appLog("[win] --extmessages flag detected (override config)\n", .{});
        } else if (std.mem.eql(u8, arg, "--exttabline")) {
            ext_tabline_enabled = true;
            if (applog.isEnabled()) applog.appLog("[win] --exttabline flag detected (override config)\n", .{});
        } else if (std.mem.eql(u8, arg, "--extwindows")) {
            ext_windows_enabled = true;
            if (applog.isEnabled()) applog.appLog("[win] --extwindows flag detected (override config)\n", .{});
        } else if (std.mem.eql(u8, arg, "--nvim")) {
            if (i + 1 < args.len) {
                cli_nvim_path = args[i + 1];
                i += 1; // skip the path argument
            }
            if (applog.isEnabled()) applog.appLog("[win] --nvim flag detected\n", .{});
        } else if (std.mem.startsWith(u8, arg, "--nvim=")) {
            cli_nvim_path = arg[7..]; // after "--nvim="
            if (applog.isEnabled()) applog.appLog("[win] --nvim flag detected\n", .{});
        } else if (std.mem.eql(u8, arg, "--log")) {
            if (i + 1 < args.len) {
                cli_log_path = args[i + 1];
                i += 1; // skip the path argument
            }
            if (applog.isEnabled()) applog.appLog("[win] --log flag detected\n", .{});
        } else if (std.mem.eql(u8, arg, "--wsl")) {
            wsl_mode = true;
            if (applog.isEnabled()) applog.appLog("[win] --wsl flag detected\n", .{});
        } else if (std.mem.startsWith(u8, arg, "--wsl=")) {
            wsl_mode = true;
            wsl_distro = arg[6..]; // after "--wsl="
            if (applog.isEnabled()) applog.appLog("[win] --wsl={s} flag detected\n", .{wsl_distro.?});
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
            if (applog.isEnabled()) applog.appLog("[win] --ssh={s} flag detected\n", .{ssh_host.?});
        } else if (std.mem.eql(u8, arg, "--ssh")) {
            ssh_mode = true;
            // Only consume the next token as the host when it is a value, not
            // another flag — otherwise `--ssh --dialog` grabs "--dialog".
            if (i + 1 < args.len and !std.mem.startsWith(u8, args[i + 1], "-")) {
                const value = args[i + 1];
                i += 1;
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
            }
            if (applog.isEnabled()) applog.appLog("[win] --ssh flag detected\n", .{});
        } else if (std.mem.startsWith(u8, arg, "--ssh-identity=")) {
            ssh_identity = arg[15..]; // after "--ssh-identity="
            if (applog.isEnabled()) applog.appLog("[win] --ssh-identity flag detected\n", .{});
        } else if (std.mem.eql(u8, arg, "--ssh-identity")) {
            if (i + 1 < args.len and !std.mem.startsWith(u8, args[i + 1], "-")) {
                ssh_identity = args[i + 1];
                i += 1;
            }
            if (applog.isEnabled()) applog.appLog("[win] --ssh-identity flag detected\n", .{});
        } else if (std.mem.startsWith(u8, arg, "--devcontainer=")) {
            devcontainer_mode = true;
            devcontainer_workspace = arg[15..]; // after "--devcontainer="
            if (applog.isEnabled()) applog.appLog("[win] --devcontainer={s} flag detected\n", .{devcontainer_workspace.?});
        } else if (std.mem.eql(u8, arg, "--devcontainer")) {
            devcontainer_mode = true;
            if (i + 1 < args.len and !std.mem.startsWith(u8, args[i + 1], "-")) {
                devcontainer_workspace = args[i + 1];
                i += 1;
            }
            if (applog.isEnabled()) applog.appLog("[win] --devcontainer flag detected\n", .{});
        } else if (std.mem.startsWith(u8, arg, "--devcontainer-config=")) {
            devcontainer_config = arg[22..]; // after "--devcontainer-config="
            if (applog.isEnabled()) applog.appLog("[win] --devcontainer-config flag detected\n", .{});
        } else if (std.mem.eql(u8, arg, "--devcontainer-config")) {
            if (i + 1 < args.len and !std.mem.startsWith(u8, args[i + 1], "-")) {
                devcontainer_config = args[i + 1];
                i += 1;
            }
            if (applog.isEnabled()) applog.appLog("[win] --devcontainer-config flag detected\n", .{});
        } else if (std.mem.eql(u8, arg, "--devcontainer-rebuild")) {
            devcontainer_rebuild = true;
            if (applog.isEnabled()) applog.appLog("[win] --devcontainer-rebuild flag detected\n", .{});
        } else if (std.mem.startsWith(u8, arg, "--connect-nvim=")) {
            connect_addr = arg["--connect-nvim=".len..];
            if (applog.isEnabled()) applog.appLog("[win] --connect-nvim={s} flag detected\n", .{connect_addr.?});
        } else if (std.mem.eql(u8, arg, "--connect-nvim")) {
            if (i + 1 < args.len) {
                connect_addr = args[i + 1];
                i += 1;
                if (applog.isEnabled()) applog.appLog("[win] --connect-nvim {s} flag detected\n", .{connect_addr.?});
            } else {
                // Mark connect mode requested but value missing. The empty
                // slice flows into the validation block below where we
                // refuse to start instead of silently falling through to
                // a regular nvim spawn.
                connect_addr = "";
                if (applog.isEnabled()) applog.appLog("[win] --connect-nvim flag detected without value\n", .{});
            }
        } else if (std.mem.startsWith(u8, arg, "--remote-ui=")) {
            connect_addr = arg["--remote-ui=".len..];
            if (applog.isEnabled()) applog.appLog("[win] --remote-ui={s} flag detected (alias of --connect-nvim)\n", .{connect_addr.?});
        } else if (std.mem.eql(u8, arg, "--remote-ui")) {
            if (i + 1 < args.len) {
                connect_addr = args[i + 1];
                i += 1;
                if (applog.isEnabled()) applog.appLog("[win] --remote-ui {s} flag detected (alias of --connect-nvim)\n", .{connect_addr.?});
            } else {
                connect_addr = "";
                if (applog.isEnabled()) applog.appLog("[win] --remote-ui flag detected without value\n", .{});
            }
        } else if (std.mem.eql(u8, arg, "--dialog")) {
            connect_dialog = true;
            if (applog.isEnabled()) applog.appLog("[win] --dialog flag detected (startup connection dialog)\n", .{});
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            // Already handled above, skip
        } else {
            // Not a zonvie argument - pass to nvim
            nvim_extra_args.append(alloc, arg) catch {};
        }
    }

    // Apply frontend filters before enabling the sink so perf/scroll modes
    // reject non-matching lines before formatting or enqueueing.
    applog.setFilters(config.log.perf_only, config.log.scroll_only, config.log.verbose);

    // Enable logging if configured (CLI --log overrides config)
    if (cli_log_path) |path| {
        applog.setLogPath(path);
        applog.setEnabled(true);
    } else if (config.log.enabled) {
        applog.setLogPath(config.log.path);
        applog.setEnabled(true);
    }

    // Validate --nvim path (reject quote characters that break shell/Zig parser quoting)
    if (cli_nvim_path) |path| {
        if (std.mem.indexOfScalar(u8, path, '\'') != null or
            std.mem.indexOfScalar(u8, path, '"') != null)
        {
            if (applog.isEnabled()) applog.appLog("[win] ERROR: --nvim path contains quote characters. Ignoring --nvim.\n", .{});
            std.debug.print("Error: --nvim path must not contain quote characters (' or \"). Ignoring --nvim.\n", .{});
            cli_nvim_path = null;
        }
    }

    // Log config info (after applog is enabled)
    if (applog.isEnabled()) {
        if (config_result.large_jump_behavior_invalid) {
            applog.appLog("[win] WARNING: invalid [scroll].large_jump_behavior; using partial\n", .{});
        }
        applog.appLog("[TIMING] Config.load: {d}ms\n", .{config_ms});
        applog.appLog("[win] Config path: {s}\n", .{config_result.path orelse "(none)"});
        applog.appLog("[win] Config loaded: neovim.path={s}, font.family={s}, font.size={d}, cmdline.external={}, log.enabled={}, close_to_tray={}\n", .{
            config.neovim.path,
            config.font.family,
            config.font.size,
            config.cmdline.external,
            config.log.enabled,
            config.server.close_to_tray,
        });
        applog.appLog("[win] Config messages: external={}, routes_count={d}, routes_allocated={}\n", .{
            config.messages.external,
            config.messages.routes.len,
            config.routes_allocated,
        });
    }

    // SSH mode: no early password dialog
    // SSH_ASKPASS mechanism handles password/passphrase on demand (when SSH requests it)
    const early_ssh_password: ?[]const u8 = null;
    if (ssh_mode) {
        if (applog.isEnabled()) applog.appLog("[win] SSH mode: using SSH_ASKPASS for on-demand authentication\n", .{});
    }

    const class_name: [:0]const u16 = std.unicode.utf8ToUtf16LeStringLiteral("ZonvieWin");
    const title: [:0]const u16 = std.unicode.utf8ToUtf16LeStringLiteral("zonvie (win)");

    var wc: c.WNDCLASSEXW = std.mem.zeroes(c.WNDCLASSEXW);
    wc.cbSize = @sizeOf(c.WNDCLASSEXW);
    wc.style = c.CS_HREDRAW | c.CS_VREDRAW;
    wc.lpfnWndProc = window.WndProc;
    wc.hInstance = c.GetModuleHandleW(null);
    wc.hCursor = c.LoadCursorW(null, @ptrFromInt(32512)); // IDC_ARROW
    // Application icon (IDI_ICON1 = 1 in zonvie.rc). The taskbar button picks
    // up the executable's icon resource automatically, but the title-bar /
    // Alt-Tab icon comes from the window class; without these it falls back to
    // the generic default. MAKEINTRESOURCE isn't translated by the C import,
    // so pass the numeric resource id directly as a pointer (same as the
    // IDC_ARROW / IDI_APPLICATION uses elsewhere).
    wc.hIcon = LoadIconW(wc.hInstance, makeIntResource(1)); // large icon (Alt-Tab)
    // Small icon (title bar / Alt-Tab small slot). LoadIconW returns HICON
    // directly. The earlier LoadImageW path returned HANDLE and cast it to HICON
    // ([*c]HICON__, align 4) via @ptrCast(@alignCast(...)); a Win32 USER handle
    // is an opaque table entry, not a real pointer, so it is not guaranteed
    // 4-byte aligned and the cast tripped the Debug alignment check. A direct
    // HICON return needs no conversion. Windows scales it to the small-icon
    // size; exact-size LoadImageW is not worth a startup crash.
    wc.hIconSm = LoadIconW(wc.hInstance, makeIntResource(1));
    wc.hbrBackground = null;
    wc.cbWndExtra = @sizeOf(isize);
    wc.lpszClassName = @ptrCast(class_name.ptr);

    if (c.RegisterClassExW(&wc) == 0) return 1;

    // Single-instance mode (opt-in via [server] single_instance). Use a named
    // mutex to detect an already-running instance; if one exists, forward the
    // file arguments to it via WM_COPYDATA and exit. The mutex handle is kept
    // open for this process's lifetime (released by the OS on exit) so it acts
    // as the live ownership token for subsequent launches.
    if (config.server.single_instance) {
        const mutex_name = std.unicode.utf8ToUtf16LeStringLiteral("Local\\ZonvieSingleInstanceMutex");
        const mutex = c.CreateMutexW(null, c.FALSE, mutex_name);
        if (mutex != null and c.GetLastError() == c.ERROR_ALREADY_EXISTS) {
            // Another instance owns the mutex. Route the files to it. The owning
            // instance creates the mutex before its window, so during a startup
            // race FindWindowW may not see the window yet; poll briefly (up to
            // ~2s) before giving up.
            var existing = c.FindWindowW(@ptrCast(class_name.ptr), null);
            if (existing == null) {
                var waited_ms: u32 = 0;
                while (waited_ms < 2000) : (waited_ms += 50) {
                    c.Sleep(50);
                    existing = c.FindWindowW(@ptrCast(class_name.ptr), null);
                    if (existing != null) break;
                }
            }
            if (existing != null) {
                forwardFilesToInstance(alloc, existing.?, &config, nvim_extra_args.items);
                return 0;
            }
            // Still no window (owning instance headless or stuck). Fall through
            // and start normally as a degraded fallback.
        }
    }

    // Reject empty / missing connect address. Catches both
    // `zonvie --connect-nvim` (bare flag, no value) and
    // `zonvie --connect-nvim=` (`=` with nothing after). Without this
    // check the previous behavior was: bare flag silently fell through
    // to a regular nvim spawn (surprising), and empty-after-`=` flowed
    // into the core which returned -3 anyway but only after the run-
    // thread spin-up. Rejecting here keeps the failure synchronous and
    // gives the user a clear message.
    if (connect_addr) |ca| {
        if (ca.len == 0) {
            _ = c.AttachConsole(ATTACH_PARENT_PROCESS);
            const stderr = c.GetStdHandle(c.STD_ERROR_HANDLE);
            if (stderr != c.INVALID_HANDLE_VALUE) {
                var written: c.DWORD = 0;
                const m = "zonvie: --connect-nvim / --remote-ui requires a non-empty address (e.g. \\\\.\\pipe\\nvim.31920.0). On Windows only named pipes are supported.\r\n";
                _ = c.WriteFile(stderr, m.ptr, @intCast(m.len), &written, null);
            }
            const wide_title = comptime blk: {
                const t = "zonvie: invalid options";
                var buf: [t.len + 1]u16 = undefined;
                for (t, 0..) |ch, idx| buf[idx] = ch;
                buf[t.len] = 0;
                break :blk buf;
            };
            const wide_msg = comptime blk: {
                const m = "--connect-nvim / --remote-ui requires a non-empty address such as \\\\.\\pipe\\nvim.31920.0. On Windows only named pipes are supported.";
                var buf: [m.len + 1]u16 = undefined;
                for (m, 0..) |ch, idx| buf[idx] = ch;
                buf[m.len] = 0;
                break :blk buf;
            };
            _ = c.MessageBoxW(null, &wide_msg, &wide_title, c.MB_OK | c.MB_ICONERROR);
            return 1;
        }
    }

    // Validate flag exclusivity: --connect-nvim attaches to an already-
    // running Neovim server, while --wsl / --ssh / --devcontainer (and
    // their config-file equivalents [neovim].wsl / .ssh) all SPAWN a
    // wrapper-hosted nvim. The two are mutually exclusive — silently
    // letting connect mode override (the previous behavior) would pick
    // the user's wrapper config out from under them. Refuse to start so
    // the user can fix the invocation explicitly.
    if (connect_addr != null and (wsl_mode or ssh_mode or devcontainer_mode)) {
        _ = c.AttachConsole(ATTACH_PARENT_PROCESS);
        const stderr = c.GetStdHandle(c.STD_ERROR_HANDLE);
        if (stderr != c.INVALID_HANDLE_VALUE) {
            var written: c.DWORD = 0;
            const m1 = "zonvie: --connect-nvim is mutually exclusive with";
            _ = c.WriteFile(stderr, m1.ptr, @intCast(m1.len), &written, null);
            if (wsl_mode) {
                const m = " --wsl";
                _ = c.WriteFile(stderr, m.ptr, @intCast(m.len), &written, null);
            }
            if (ssh_mode) {
                const m = " --ssh";
                _ = c.WriteFile(stderr, m.ptr, @intCast(m.len), &written, null);
            }
            if (devcontainer_mode) {
                const m = " --devcontainer";
                _ = c.WriteFile(stderr, m.ptr, @intCast(m.len), &written, null);
            }
            const m2 = " (or [neovim].wsl/[neovim].ssh in config.toml).\r\nRemove the conflicting option(s) and retry.\r\n";
            _ = c.WriteFile(stderr, m2.ptr, @intCast(m2.len), &written, null);
        }
        // Also surface via MessageBox for Explorer / shortcut launches
        // where there is no parent console.
        const wide_title = comptime blk: {
            const t = "zonvie: invalid options";
            var buf: [t.len + 1]u16 = undefined;
            for (t, 0..) |ch, idx| buf[idx] = ch;
            buf[t.len] = 0;
            break :blk buf;
        };
        const wide_msg = comptime blk: {
            const m = "--connect-nvim is mutually exclusive with --wsl / --ssh / --devcontainer (or their config.toml equivalents). Remove the conflicting option(s) and retry.";
            var buf: [m.len + 1]u16 = undefined;
            for (m, 0..) |ch, idx| buf[idx] = ch;
            buf[m.len] = 0;
            break :blk buf;
        };
        _ = c.MessageBoxW(null, &wide_msg, &wide_title, c.MB_OK | c.MB_ICONERROR);
        return 1;
    }

    // `--dialog` picks the connection mode interactively. `--ssh` / `--devcontainer`
    // are NOT conflicts — they pre-select the matching tab and seed its fields
    // (see windows/ui/dialogs.zig). But `--connect-nvim` (attach to a running
    // server) and `--wsl` (no dialog tab) have no dialog representation, so
    // reject those combinations up-front, mirroring the macOS main.swift check.
    if (connect_dialog and (connect_addr != null or wsl_mode)) {
        _ = c.AttachConsole(ATTACH_PARENT_PROCESS);
        const stderr = c.GetStdHandle(c.STD_ERROR_HANDLE);
        if (stderr != c.INVALID_HANDLE_VALUE) {
            var written: c.DWORD = 0;
            const m1 = "zonvie: --dialog is mutually exclusive with";
            _ = c.WriteFile(stderr, m1.ptr, @intCast(m1.len), &written, null);
            if (connect_addr != null) {
                const m = " --connect-nvim / --remote-ui";
                _ = c.WriteFile(stderr, m.ptr, @intCast(m.len), &written, null);
            }
            if (wsl_mode) {
                const m = " --wsl";
                _ = c.WriteFile(stderr, m.ptr, @intCast(m.len), &written, null);
            }
            const m2 = " (or [neovim].wsl in config.toml).\r\nRemove the conflicting option(s) and retry.\r\n";
            _ = c.WriteFile(stderr, m2.ptr, @intCast(m2.len), &written, null);
        }
        const wide_title = comptime blk: {
            const t = "zonvie: invalid options";
            var buf: [t.len + 1]u16 = undefined;
            for (t, 0..) |ch, idx| buf[idx] = ch;
            buf[t.len] = 0;
            break :blk buf;
        };
        const wide_msg = comptime blk: {
            const m = "--dialog opens a dialog to choose the connection. --ssh / --devcontainer pre-select the matching tab, but it cannot be combined with --connect-nvim / --wsl (or [neovim].wsl in config.toml). Remove the conflicting option(s) and retry.";
            var buf: [m.len + 1]u16 = undefined;
            for (m, 0..) |ch, idx| buf[idx] = ch;
            buf[m.len] = 0;
            break :blk buf;
        };
        _ = c.MessageBoxW(null, &wide_msg, &wide_title, c.MB_OK | c.MB_ICONERROR);
        return 1;
    }

    const app = alloc.create(App) catch return 1;
    // errdefer alloc.destroy(app); // ← Remove this (causes double-free)

    app.* = .{
        .alloc = alloc,
        .window_wake_cookie = app_mod.nextWindowWakeCookie(),
        .config = config,
        .large_jump_behavior = config_result.large_jump_behavior,
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
        .connect_addr = connect_addr,
        .connect_dialog = connect_dialog,
        .nvim_extra_args = nvim_extra_args,
        .cli_nvim_path = cli_nvim_path,
    };

    // Prevent config.deinit from freeing strings now owned by app
    const opacity = app.config.window.opacity;
    config = .{};

    if (applog.isEnabled()) applog.appLog("[win] opacity={d:.2}\n", .{opacity});

    // Always use WS_EX_NOREDIRECTIONBITMAP: DWM won't allocate a redirection surface.
    // All rendering goes through DXGI swap chain + DirectComposition.
    const dwExStyle: c.DWORD = c.WS_EX_NOREDIRECTIONBITMAP;

    // Custom D3D11 overlay scrollbar (no WS_VSCROLL)
    const window_style: c.DWORD = c.WS_OVERLAPPEDWINDOW;

    _ = c.QueryPerformanceCounter(&t1);
    const hwnd = c.CreateWindowExW(
        dwExStyle,
        @ptrCast(class_name.ptr),
        @ptrCast(title.ptr),
        window_style,
        c.CW_USEDEFAULT, c.CW_USEDEFAULT,
        c.CW_USEDEFAULT, c.CW_USEDEFAULT,
        null, null,
        wc.hInstance,
        app, // lpParam -> WM_NCCREATE
    );
    _ = c.QueryPerformanceCounter(&t2);
    const createwin_ms = @divTrunc((t2.QuadPart - t1.QuadPart) * 1000, app_mod.g_startup_freq.QuadPart);
    if (applog.isEnabled()) applog.appLog("[TIMING] CreateWindowExW: {d}ms\n", .{createwin_ms});

    if (hwnd == null) {
        if (!app.owned_by_hwnd) {
            alloc.destroy(app);
        }
        return 1;
    }
    if (!window.installWindowWakeCookie(hwnd.?, app.window_wake_cookie)) {
        _ = c.DestroyWindow(hwnd.?);
        return 1;
    }

    var msg: c.MSG = undefined;
    message_loop: while (true) {
        // WM_NCDESTROY may free the original App before WM_QUIT reaches the
        // head of the queue. Never carry the startup pointer across loop
        // iterations; GWLP_USERDATA is cleared before App destruction.
        if (app_mod.getApp(hwnd.?)) |live_app| {
            window.serviceDeferredUiRetries(hwnd.?, live_app);
        }

        if (c.PeekMessageW(&msg, null, 0, 0, c.PM_REMOVE) != 0) {
            if (msg.message == c.WM_QUIT) break :message_loop;
            // Route TAB / ENTER / ESC to the startup connection dialog while it is
            // open (`--dialog`), so it navigates like a real dialog.
            if (dialogs.connectionDialogPreTranslate(&msg)) continue;
            _ = c.TranslateMessage(&msg);
            _ = c.DispatchMessageW(&msg);
            continue;
        }

        // A deadline is the allocation-free final retry driver when both
        // SetTimer and CreateTimerQueueTimer are unavailable. With no pending
        // retry this is INFINITE and retains GetMessage-style idle behavior.
        const timeout_ms = if (app_mod.getApp(hwnd.?)) |live_app|
            window.nextDeferredUiRetryTimeoutMs(live_app)
        else
            c.INFINITE;
        _ = c.MsgWaitForMultipleObjectsEx(
            0,
            null,
            timeout_ms,
            c.QS_ALLINPUT,
            c.MWMO_INPUTAVAILABLE,
        );
    }

    // Return nvim's exit code (Nvy style - return from main instead of ExitProcess)
    const exit_code = app_mod.g_exit_code.load(.seq_cst);
    if (applog.isEnabled()) applog.appLog("[win] message loop ended, returning exit_code={d}\n", .{exit_code});
    return exit_code;
}

const ConfigCreateResult = enum { created, already_exists, err };

/// Create default config.toml at %APPDATA%\zonvie\config.toml if it doesn't exist.
fn createDefaultConfig(alloc: std.mem.Allocator) ConfigCreateResult {
    // 0.16: std.process.getEnvVarOwned was removed; env access goes through
    // std.process.Environ. On Windows `.block = .global` reads the PEB-backed
    // environment, and getAlloc returns owned memory freed with alloc.free.
    const appdata = (std.process.Environ{ .block = .global }).getAlloc(alloc, "APPDATA") catch return .err;
    defer alloc.free(appdata);

    const dir_path = std.fs.path.join(alloc, &.{ appdata, "zonvie" }) catch return .err;
    defer alloc.free(dir_path);

    const file_path = std.fs.path.join(alloc, &.{ dir_path, "config.toml" }) catch return .err;
    defer alloc.free(file_path);

    // Skip if config already exists
    if (std.Io.Dir.accessAbsolute(clock.io(), file_path, .{})) |_| {
        return .already_exists;
    } else |_| {}

    // Create directory if needed
    std.Io.Dir.createDirAbsolute(clock.io(), dir_path, .default_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return .err,
    };

    // Write default config
    const file = std.Io.Dir.createFileAbsolute(clock.io(), file_path, .{}) catch return .err;
    defer file.close(clock.io());
    file.writeStreamingAll(clock.io(), default_config_toml) catch return .err;
    return .created;
}

const default_config_toml =
    \\# Zonvie configuration file
    \\# See `zonvie.exe --help` for all available options.
    \\
    \\[font]
    \\# family = "Consolas"
    \\# size = 18.0
    \\# linespace = 0
    \\
    \\[neovim]
    \\# path = "nvim"
    \\
    \\[window]
    \\# opacity = 1.0
    \\
    \\[server]
    \\# single_instance = false   # route `zonvie <file>` to a running instance (Windows only)
    \\# open_mode = "tab"         # "tab" (new tab) or "current" (replace current window)
    \\# close_to_tray = false     # close button hides to the notification area instead of quitting (Windows only)
    \\
;
