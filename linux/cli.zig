//! Command-line handling that runs before the app exists: --help,
//! --version, --install and the terminal detach --nofork turns off.

const std = @import("std");
const core = @import("zonvie_core");
const clock = core.clock;
const config_mod = @import("config.zig");

/// Whether `flag` is among zonvie's own arguments: those before `--`, which
/// are forwarded to nvim verbatim (`zonvie -- --help` is nvim's --help).
pub fn hasFlag(args: []const []const u8, flag: []const u8) bool {
    for (args[1..]) |a| {
        if (std.mem.eql(u8, a, "--")) return false;
        if (std.mem.eql(u8, a, flag)) return true;
    }
    return false;
}

/// Whether some argument before `--` starts with `prefix`.
pub fn hasPrefix(args: []const []const u8, prefix: []const u8) bool {
    for (args[1..]) |a| {
        if (std.mem.eql(u8, a, "--")) return false;
        if (std.mem.startsWith(u8, a, prefix)) return true;
    }
    return false;
}

fn writeStdout(s: []const u8) void {
    var rest = s;
    while (rest.len > 0) {
        const n = std.c.write(1, rest.ptr, rest.len);
        if (n <= 0) return;
        rest = rest[@intCast(n)..];
    }
}

const usage =
    \\zonvie - A high-performance Neovim GUI
    \\
    \\USAGE:
    \\    zonvie [OPTIONS] [--] [NVIM_ARGS...]
    \\
    \\OPTIONS:
    \\    --nofork                      Don't fork; stay attached to terminal, keep cwd
    \\    --nvim <path>                 Path to Neovim executable (overrides config)
    \\    --log <path>                  Write application logs to specified file path
    \\    --extcmdline                  Enable external command line UI
    \\    --extpopup                    Enable external popup menu UI
    \\    --extmessages                 Enable external messages UI
    \\    --exttabline                  Enable external tabline UI
    \\    --extwindows                  Enable external windows (each Neovim window as OS window)
    \\    --connect-nvim=<addr>         Attach to a running Neovim server.
    \\                                    Address: TCP "host:port" or Unix socket path.
    \\    --remote-ui=<addr>            Alias of --connect-nvim, mirrors `nvim --remote-ui`.
    \\    --renderer=<glarea|thread>    Draw in GTK's GLArea (default) or on a render thread
    \\    --install                     Create default config file and exit
    \\    --version                     Show version information and exit
    \\    --help, -h                    Show this help message and exit
    \\    --                            Pass all remaining arguments to nvim
    \\
    \\CONFIG:
    \\    Configuration file: $XDG_CONFIG_HOME/zonvie/config.toml when XDG_CONFIG_HOME
    \\    is set, ~/.config/zonvie/config.toml otherwise
    \\
    \\
;

pub fn printHelp() void {
    writeStdout(usage);
    writeStdout(std.mem.span(core.zonvie_core_config_help()));
    writeStdout("For more information, visit: https://github.com/akiyosi/zonvie\n");
}

pub fn printVersion() void {
    writeStdout("zonvie ");
    writeStdout(std.mem.span(core.zonvie_version()));
    writeStdout("\n");
}

/// Writes the default config.toml where the app reads it, never over an
/// existing one. Returns the process exit code.
pub fn install(alloc: std.mem.Allocator) u8 {
    const path = config_mod.configFilePath(alloc) catch {
        std.debug.print("Cannot determine the config path: HOME is not set\n", .{});
        return 1;
    };
    defer alloc.free(path);
    const io = clock.io();
    if (std.Io.Dir.accessAbsolute(io, path, .{})) |_| {
        std.debug.print("Config file already exists, skipped: {s}\n", .{path});
        return 0;
    } else |_| {}
    std.Io.Dir.cwd().createDirPath(io, std.fs.path.dirname(path).?) catch |e| {
        std.debug.print("Failed to create config directory: {any}\n", .{e});
        return 1;
    };
    const f = std.Io.Dir.createFileAbsolute(io, path, .{ .exclusive = true }) catch |e| {
        std.debug.print("Failed to write config file: {any}\n", .{e});
        return 1;
    };
    defer f.close(io);
    f.writeStreamingAll(io, std.mem.span(core.zonvie_core_default_config_toml())) catch |e| {
        std.debug.print("Failed to write config file: {any}\n", .{e});
        return 1;
    };
    std.debug.print("Default config.toml created: {s}\n", .{path});
    return 0;
}

/// Leaves the launching terminal, as macOS does without --nofork: the
/// parent exits at once and the child runs in its own session with stdio on
/// /dev/null. Must run before any thread exists. Returns true in the parent.
pub fn detach() bool {
    const pid = std.c.fork();
    if (pid < 0) return false; // Keep running attached.
    if (pid > 0) return true;
    _ = std.c.setsid();
    const fd = std.c.open("/dev/null", .{ .ACCMODE = .RDWR });
    if (fd >= 0) {
        for ([_]c_int{ 0, 1, 2 }) |target| _ = std.c.dup2(fd, target);
        if (fd > 2) _ = std.c.close(fd);
    }
    return false;
}

/// `arg` made absolute against this process's cwd when nvim would read it
/// as a file: the core starts nvim in $HOME unless the cwd is inherited.
pub fn absoluteFileArg(alloc: std.mem.Allocator, prev: ?[]const u8, arg: []const u8, after_dash_dash: bool) ![]const u8 {
    if (std.fs.path.isAbsolute(arg)) return arg;
    if (!core.frontend_rules.nvimArgIsFile(prev, arg, after_dash_dash)) return arg;
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd = std.c.getcwd(&buf, buf.len) orelse return arg;
    return std.fs.path.join(alloc, &.{ std.mem.sliceTo(cwd, 0), arg });
}

test "flags after -- belong to nvim" {
    const args = [_][]const u8{ "zonvie", "--nofork", "--", "--help" };
    try std.testing.expect(hasFlag(&args, "--nofork"));
    try std.testing.expect(!hasFlag(&args, "--help"));
    const connect = [_][]const u8{ "zonvie", "--connect-nvim=/tmp/s" };
    try std.testing.expect(hasPrefix(&connect, "--connect-nvim"));
}
