// driver.zig — GUI test driver: runs the REAL zonvie app against a shared
// nvim server and observes OS-level effects. macOS and Windows hosts.
//
// Topology (three processes):
//
//   nvim --headless --clean --listen <addr>
//        ├──← zonvie app  (real frontend, --connect-nvim=<addr>)
//        └──← this driver (drives/queries the SAME nvim via
//                          `nvim --server <addr> --remote-expr/-send`)
//
// nvim accepts multiple RPC channels, so the driver shares the exact
// nvim state the GUI is rendering — that is the oracle. GUI-side effects
// are observed read-only via the platform window module:
//   macOS:   CGWindowList   (test/gui/macos_window.zig)
//   Windows: EnumWindows    (test/gui/windows_window.zig)
//
// Platform notes:
//   - listen address: absolute unix socket path on macOS (the core's
//     connect-address validation rejects relative paths), named pipe
//     \\.\pipe\... on Windows (the only supported transport there).
//   - config isolation: XDG_CONFIG_HOME on macOS, APPDATA on Windows,
//     both pointed at test/gui/fixtures/config (zonvie/config.toml layout
//     is identical). Options.home_dir overrides HOME / USERPROFILE.
//
// Safety: test processes are OUR children, terminated by exact PID only
// (this session itself may be running inside a zonvie instance — never
// target zonvie by name or bundle id).
//
// Local-only by design: launches real windows on the current desktop.
// Test-only code: heap allocation is fine here.

const std = @import("std");
const builtin = @import("builtin");

pub const platform = switch (builtin.os.tag) {
    .windows => @import("windows_window.zig"),
    else => @import("macos_window.zig"),
};

pub const capture = switch (builtin.os.tag) {
    .windows => @import("windows_capture.zig"),
    else => @import("macos_capture.zig"),
};

pub const default_app_rel_path = switch (builtin.os.tag) {
    .windows => "windows/zig-out/bin/zonvie.exe",
    else => "macos/.derived/Build/Products/Debug/zonvie.app/Contents/MacOS/zonvie",
};

extern "kernel32" fn GetProcessId(h: std.os.windows.HANDLE) callconv(.winapi) u32;

/// Resolve the nvim binary: $ZONVIE_TEST_NVIM if set, else "nvim" on PATH.
pub fn resolveNvim(alloc: std.mem.Allocator) ![]u8 {
    const path = std.process.getEnvVarOwned(alloc, "ZONVIE_TEST_NVIM") catch
        try alloc.dupe(u8, "nvim");
    errdefer alloc.free(path);
    const result = std.process.Child.run(.{
        .allocator = alloc,
        .argv = &.{ path, "--version" },
    }) catch return error.NvimNotFound;
    alloc.free(result.stdout);
    alloc.free(result.stderr);
    switch (result.term) {
        .Exited => |code| if (code != 0) return error.NvimNotFound,
        else => return error.NvimNotFound,
    }
    return path;
}

/// Resolve the built zonvie binary: $ZONVIE_TEST_APP if set, else the
/// platform default build product. Returns error.AppNotFound when missing.
pub fn resolveApp(alloc: std.mem.Allocator) ![]u8 {
    const path = std.process.getEnvVarOwned(alloc, "ZONVIE_TEST_APP") catch
        try alloc.dupe(u8, default_app_rel_path);
    errdefer alloc.free(path);
    std.fs.cwd().access(path, .{}) catch return error.AppNotFound;
    return path;
}

fn currentPid() u32 {
    if (builtin.os.tag == .windows) {
        return std.os.windows.GetCurrentProcessId();
    }
    return @intCast(std.c.getpid());
}

pub const Options = struct {
    /// Extra CLI args for the zonvie app (e.g. "--extcmdline").
    app_args: []const []const u8 = &.{},
    /// When set, the app runs with HOME (macOS) / USERPROFILE (Windows)
    /// pointing at this dir (created if missing). Isolates persisted app
    /// state (e.g. NSUserDefaults frame autosave) from the user's real
    /// state — required by relaunch-comparison scenarios.
    home_dir: ?[]const u8 = null,
};

pub const Gui = struct {
    alloc: std.mem.Allocator,
    nvim_path: []u8,
    listen_addr: []u8,
    nvim_child: std.process.Child,
    app_child: std.process.Child,
    app_env: std.process.EnvMap,
    /// Owned argv for the app, kept so the scenario can relaunch it.
    app_argv: [][]u8,
    app_pid: i32,
    app_exited: bool = false,

    pub fn init(alloc: std.mem.Allocator, opts: Options) !*Gui {
        const nvim_path = try resolveNvim(alloc);
        errdefer alloc.free(nvim_path);
        const app_path = try resolveApp(alloc);
        defer alloc.free(app_path);

        const g = try alloc.create(Gui);
        errdefer alloc.destroy(g);
        g.* = .{
            .alloc = alloc,
            .nvim_path = nvim_path,
            .listen_addr = undefined,
            .nvim_child = undefined,
            .app_child = undefined,
            .app_env = undefined,
            .app_argv = undefined,
            .app_pid = 0,
        };

        // Unique listen address. macOS: ABSOLUTE socket path (the core's
        // connect-address validation rejects relative paths). Windows:
        // named pipe (the only transport the core supports there).
        if (builtin.os.tag == .windows) {
            g.listen_addr = try std.fmt.allocPrint(alloc, "\\\\.\\pipe\\zonvie_gui_e2e_{d}", .{currentPid()});
        } else {
            std.fs.cwd().makePath("tmp") catch {};
            const tmp_abs = try std.fs.cwd().realpathAlloc(alloc, "tmp");
            defer alloc.free(tmp_abs);
            g.listen_addr = try std.fmt.allocPrint(alloc, "{s}/gui_e2e_{d}.sock", .{ tmp_abs, currentPid() });
            std.fs.cwd().deleteFile(g.listen_addr) catch {};
        }
        errdefer alloc.free(g.listen_addr);

        // 1. Shared nvim server (headless, clean).
        g.nvim_child = std.process.Child.init(
            &.{ nvim_path, "--clean", "--headless", "--listen", g.listen_addr },
            alloc,
        );
        g.nvim_child.stdin_behavior = .Ignore;
        g.nvim_child.stdout_behavior = .Ignore;
        g.nvim_child.stderr_behavior = .Ignore;
        try g.nvim_child.spawn();
        errdefer _ = g.nvim_child.kill() catch undefined;

        // Wait until the server answers a trivial expression.
        try g.waitServerReady(10_000);

        // 2. Real frontend, attached to the same nvim. Keep an owned argv
        // so relaunchApp() can spawn an identical instance.
        var argv: std.ArrayListUnmanaged([]u8) = .{};
        errdefer {
            for (argv.items) |a| alloc.free(a);
            argv.deinit(alloc);
        }
        try argv.append(alloc, try alloc.dupe(u8, app_path));
        try argv.append(alloc, try std.fmt.allocPrint(alloc, "--connect-nvim={s}", .{g.listen_addr}));
        for (opts.app_args) |a| try argv.append(alloc, try alloc.dupe(u8, a));
        g.app_argv = try argv.toOwnedSlice(alloc);

        // Isolate from the user's real config: point the platform config
        // root at the (empty) fixtures dir so only CLI flags shape app
        // behavior. Both platforms resolve <root>/zonvie/config.toml.
        g.app_env = try std.process.getEnvMap(alloc);
        errdefer g.app_env.deinit();
        const fixtures_abs = try std.fs.cwd().realpathAlloc(alloc, "test/gui/fixtures/config");
        defer alloc.free(fixtures_abs);
        try g.app_env.put(if (builtin.os.tag == .windows) "APPDATA" else "XDG_CONFIG_HOME", fixtures_abs);

        // Optional home isolation (persisted app state, frame autosave).
        if (opts.home_dir) |home| {
            std.fs.cwd().makePath(home) catch {};
            const home_abs = try std.fs.cwd().realpathAlloc(alloc, home);
            defer alloc.free(home_abs);
            try g.app_env.put(if (builtin.os.tag == .windows) "USERPROFILE" else "HOME", home_abs);
        }

        try g.launchApp();
        errdefer if (!g.app_exited) {
            _ = g.app_child.kill() catch undefined;
        };

        // 3. Wait for the main window to actually appear on screen.
        try g.waitWindowCount(1, 15_000);
        return g;
    }

    /// Spawn the app with the stored argv/env. Used by init and relaunchApp.
    fn launchApp(g: *Gui) !void {
        const argv_const: []const []const u8 = @ptrCast(g.app_argv);
        g.app_child = std.process.Child.init(argv_const, g.alloc);
        g.app_child.env_map = &g.app_env;
        g.app_child.stdin_behavior = .Ignore;
        g.app_child.stdout_behavior = .Ignore;
        g.app_child.stderr_behavior = .Ignore;
        try g.app_child.spawn();
        g.app_pid = if (builtin.os.tag == .windows)
            @intCast(GetProcessId(g.app_child.id))
        else
            @intCast(g.app_child.id);
        g.app_exited = false;
    }

    /// Kill the running app instance and start a fresh one with identical
    /// argv/env, then wait for its main window. The nvim server (and all
    /// its state, e.g. 'guifont') persists across the relaunch.
    pub fn relaunchApp(g: *Gui) !void {
        if (!g.app_exited) _ = g.app_child.kill() catch undefined;
        g.app_exited = true; // kill() reaped it; appAlive must not reap again

        // Wait until its windows are gone before measuring the next instance.
        var timer = std.time.Timer.start() catch unreachable;
        while (platform.windowCountForPid(g.app_pid) != 0) {
            if (timer.read() / std.time.ns_per_ms >= 10_000) return error.Timeout;
            std.Thread.sleep(100 * std.time.ns_per_ms);
        }

        try g.launchApp();
        try g.waitWindowCount(1, 15_000);
    }

    pub fn deinit(g: *Gui) void {
        // Exact-PID teardown of OUR children only, app first, then nvim.
        // Skip the kill when the app already exited (appAlive reaped it).
        if (!g.app_exited) _ = g.app_child.kill() catch undefined;
        _ = g.nvim_child.kill() catch undefined;
        g.app_env.deinit();
        for (g.app_argv) |a| g.alloc.free(a);
        g.alloc.free(g.app_argv);
        if (builtin.os.tag != .windows) {
            std.fs.cwd().deleteFile(g.listen_addr) catch {};
        }
        g.alloc.free(g.listen_addr);
        g.alloc.free(g.nvim_path);
        g.alloc.destroy(g);
    }

    // ── nvim oracle channel ────────────────────────────────────────────

    /// Evaluate a vimscript expression on the shared server; returns stdout.
    /// Caller owns the returned slice.
    pub fn remoteExpr(g: *Gui, expr: []const u8) ![]u8 {
        return g.remoteExprInner(expr, false);
    }

    fn remoteExprInner(g: *Gui, expr: []const u8, quiet: bool) ![]u8 {
        const result = try std.process.Child.run(.{
            .allocator = g.alloc,
            .argv = &.{ g.nvim_path, "--server", g.listen_addr, "--remote-expr", expr },
        });
        errdefer g.alloc.free(result.stdout);
        defer g.alloc.free(result.stderr);
        switch (result.term) {
            .Exited => |code| if (code != 0) {
                if (!quiet) {
                    std.debug.print("[gui] remote-expr failed ({d}): {s}\n{s}\n", .{ code, expr, result.stderr });
                }
                g.alloc.free(result.stdout);
                return error.RemoteExprFailed;
            },
            else => return error.RemoteExprFailed,
        }
        return result.stdout;
    }

    /// Send keys (nvim notation) to the shared server.
    pub fn remoteSend(g: *Gui, keys: []const u8) !void {
        const result = try std.process.Child.run(.{
            .allocator = g.alloc,
            .argv = &.{ g.nvim_path, "--server", g.listen_addr, "--remote-send", keys },
        });
        defer g.alloc.free(result.stdout);
        defer g.alloc.free(result.stderr);
        switch (result.term) {
            .Exited => |code| if (code != 0) return error.RemoteSendFailed,
            else => return error.RemoteSendFailed,
        }
    }

    fn waitServerReady(g: *Gui, timeout_ms: u64) !void {
        var timer = std.time.Timer.start() catch unreachable;
        while (true) {
            const out = g.remoteExprInner("1", true) catch {
                if (timer.read() / std.time.ns_per_ms >= timeout_ms) return error.Timeout;
                std.Thread.sleep(100 * std.time.ns_per_ms);
                continue;
            };
            g.alloc.free(out);
            return;
        }
    }

    // ── GUI observation ────────────────────────────────────────────────

    pub fn windowCount(g: *Gui) u32 {
        return platform.windowCountForPid(g.app_pid);
    }

    /// Capture the app's main window, retrying until two consecutive
    /// captures are pixel-identical (the frame has settled) or timeout.
    /// `crop` (a fixed top-left region) keeps the output dimensions stable
    /// across runs; pass null for the whole window. Caller frees the image.
    /// Cursor blink etc. must be disabled by the scenario first, or the
    /// frames will never settle.
    pub fn captureStable(g: *Gui, crop: ?capture.Crop, timeout_ms: u64) !capture.Image {
        var timer = std.time.Timer.start() catch unreachable;
        var prev: ?capture.Image = null;
        defer if (prev) |*p| p.deinit(g.alloc);
        while (true) {
            std.Thread.sleep(150 * std.time.ns_per_ms);
            const cur = capture.captureMainWindow(g.alloc, g.app_pid, crop) catch |e| {
                if (timer.read() / std.time.ns_per_ms >= timeout_ms) return e;
                continue;
            };
            if (prev) |*p| {
                if (p.w == cur.w and p.h == cur.h and std.mem.eql(u8, p.rgba, cur.rgba)) {
                    p.deinit(g.alloc);
                    prev = null;
                    return cur;
                }
                p.deinit(g.alloc);
                prev = null;
            }
            prev = cur;
            if (timer.read() / std.time.ns_per_ms >= timeout_ms) {
                const out = prev.?;
                prev = null;
                return out; // last capture even if not fully settled
            }
        }
    }

    /// True while the app process is still running. Reaps/observes at most
    /// once; after that, deinit must not kill/wait the child again.
    fn appAlive(g: *Gui) bool {
        if (g.app_exited) return false;
        if (builtin.os.tag == .windows) {
            std.os.windows.WaitForSingleObject(g.app_child.id, 0) catch |e| switch (e) {
                error.WaitTimeOut => return true, // still running
                else => return true, // indeterminate: assume alive
            };
        } else {
            const res = std.posix.waitpid(@intCast(g.app_pid), std.posix.W.NOHANG);
            if (res.pid == 0) return true;
        }
        g.app_exited = true;
        std.debug.print("[gui] zonvie app exited unexpectedly (pid={d})\n", .{g.app_pid});
        return false;
    }

    /// Poll until the app owns exactly `target` on-screen windows.
    /// Fails fast when the app process dies (a vanished window count of 0
    /// must surface as AppExited, not a confusing Timeout).
    pub fn waitWindowCount(g: *Gui, target: u32, timeout_ms: u64) !void {
        var timer = std.time.Timer.start() catch unreachable;
        while (true) {
            if (g.windowCount() == target) return;
            if (!g.appAlive()) return error.AppExited;
            if (timer.read() / std.time.ns_per_ms >= timeout_ms) {
                std.debug.print(
                    "[gui] waitWindowCount failed: expected={d} actual={d} (pid={d})\n",
                    .{ target, g.windowCount(), g.app_pid },
                );
                platform.dumpWindowsForPid(g.app_pid);
                return error.Timeout;
            }
            std.Thread.sleep(100 * std.time.ns_per_ms);
        }
    }
};
