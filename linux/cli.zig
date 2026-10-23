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
    \\    --ssh=<user@host[:port]>      Connect to remote host via SSH
    \\    --ssh-identity=<path>         Path to SSH private key file
    \\    --devcontainer=<workspace>    Run inside a devcontainer
    \\    --devcontainer-config=<path>  Path to devcontainer.json
    \\    --devcontainer-rebuild        Rebuild devcontainer before starting
    \\    --connect-nvim=<addr>         Attach to a running Neovim server.
    \\                                    Address: TCP "host:port" or Unix socket path.
    \\                                    Mutually exclusive with --ssh / --devcontainer.
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

pub const Ssh = struct { host: []const u8, port: ?u16 = null, identity: ?[]const u8 = null };

/// The command the core spawns for `--ssh`: ssh behind the `ssh-askpass`
/// marker (rpc_session.zig: SSH_ASKPASS answers prompts, the core does not
/// watch for them), running nvim through the remote login shell for its
/// PATH, as macOS builds it. A key turns password prompts off.
pub fn sshCommand(alloc: std.mem.Allocator, s: Ssh, remote_nvim: []const u8) ![:0]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.appendSlice(alloc, "ssh-askpass ssh");
    if (s.port) |p| try out.print(alloc, " -p {d}", .{p});
    if (s.identity) |id| {
        // The core splits on spaces; quoted, a key path with one survives.
        if (std.mem.indexOfScalar(u8, id, ' ') != null) try out.print(alloc, " -i \"{s}\"", .{id}) else try out.print(alloc, " -i {s}", .{id});
        try out.appendSlice(alloc, " -o PasswordAuthentication=no -o KbdInteractiveAuthentication=no");
    }
    try out.appendSlice(alloc, " -o StrictHostKeyChecking=accept-new ");
    try out.appendSlice(alloc, s.host);
    // '$SHELL --login -c "\"nvim\" --embed"': the core keeps the single-
    // quoted span as one argument, and the remote shell reads \" as a quote
    // protecting a path with spaces. Backslashes in the path are doubled.
    try out.appendSlice(alloc, " '$SHELL --login -c \"\\\"");
    for (remote_nvim) |ch| {
        if (ch == '\\') try out.append(alloc, '\\');
        try out.append(alloc, ch);
    }
    try out.appendSlice(alloc, "\\\" --embed\"'");
    return out.toOwnedSliceSentinel(alloc, 0);
}

/// Points ssh's SSH_ASKPASS at this executable in askpass mode (askpass.zig),
/// for every prompt, display or not. Before the core spawns ssh: it passes
/// the environment as it is then.
extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;

pub fn setAskpassEnv(env_mode: [:0]const u8) void {
    var buf: [std.fs.max_path_bytes:0]u8 = undefined;
    const n = std.c.readlink("/proc/self/exe", &buf, buf.len - 1);
    if (n <= 0) return;
    buf[@intCast(n)] = 0;
    _ = setenv("SSH_ASKPASS", &buf, 1);
    _ = setenv("SSH_ASKPASS_REQUIRE", "force", 1);
    _ = setenv(env_mode, "1", 1);
}

/// `~/...` against $HOME.
pub fn expandTilde(alloc: std.mem.Allocator, path: []const u8) ![]const u8 {
    if (!std.mem.startsWith(u8, path, "~/")) return path;
    const home = std.c.getenv("HOME") orelse return path;
    return std.fs.path.join(alloc, &.{ std.mem.span(home), path[2..] });
}

/// The host's nvim config, which a rebuilt devcontainer mounts.
pub fn nvimConfigDir(alloc: std.mem.Allocator) ![]const u8 {
    if (std.c.getenv("XDG_CONFIG_HOME")) |x| {
        if (std.mem.span(x).len > 0) return std.fs.path.join(alloc, &.{ std.mem.span(x), "nvim" });
    }
    const home = std.c.getenv("HOME") orelse return "";
    return std.fs.path.join(alloc, &.{ std.mem.span(home), ".config", "nvim" });
}

pub const Devcontainer = struct {
    workspace: []const u8,
    config: ?[]const u8 = null,
    rebuild: bool = false,
};

/// `s` double-quoted for sh.
fn appendShDq(out: *std.ArrayListUnmanaged(u8), alloc: std.mem.Allocator, s: []const u8) !void {
    try out.append(alloc, '"');
    for (s) |ch| {
        if (ch == '\\' or ch == '"' or ch == '$' or ch == '`') try out.append(alloc, '\\');
        try out.append(alloc, ch);
    }
    try out.append(alloc, '"');
}

/// The command the core spawns for `--devcontainer`: the core's `devcontainer
/// exec` line into a running container, as macOS starts it. With rebuild,
/// `devcontainer up` (the core's arguments: the Neovim feature, the nvim
/// config mount, --remove-existing-container) runs first in a shell the
/// core spawns as is (its "/bin/sh" mode); the single-quoted script reaches
/// sh verbatim, so everything in it is double-quoted.
pub fn devcontainerCommand(alloc: std.mem.Allocator, d: Devcontainer, nvim_config_dir: []const u8) ![:0]u8 {
    var exec_buf: [4096]u8 = undefined;
    const cfg = d.config orelse "";
    const n = core.zonvie_core_devcontainer_exec_cmd(&exec_buf, exec_buf.len, d.workspace.ptr, d.workspace.len, if (d.config != null) cfg.ptr else null, cfg.len);
    const exec_cmd = exec_buf[0..n];
    if (!d.rebuild) return alloc.dupeZ(u8, exec_cmd);

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(alloc);
    try out.appendSlice(alloc, "/bin/sh -c 'devcontainer up --workspace-folder ");
    try appendShDq(&out, alloc, d.workspace);
    if (d.config) |c| {
        try out.appendSlice(alloc, " --config ");
        try appendShDq(&out, alloc, c);
    }
    var args_buf: [4096]u8 = undefined;
    const len = core.zonvie_core_devcontainer_up_args(&args_buf, args_buf.len, nvim_config_dir.ptr, nvim_config_dir.len, true);
    var it = std.mem.splitScalar(u8, args_buf[0..len], 0);
    while (it.next()) |arg| {
        if (arg.len == 0) continue;
        try out.append(alloc, ' ');
        try appendShDq(&out, alloc, arg);
    }
    try out.appendSlice(alloc, " && exec ");
    try out.appendSlice(alloc, exec_cmd);
    try out.append(alloc, '\'');
    return out.toOwnedSliceSentinel(alloc, 0);
}

test "a devcontainer rebuild runs up, then execs nvim" {
    const a = std.testing.allocator;
    const plain = try devcontainerCommand(a, .{ .workspace = "/w s" }, "/home/u/.config/nvim");
    defer a.free(plain);
    try std.testing.expect(std.mem.startsWith(u8, plain, "devcontainer exec --workspace-folder \"/w s\""));
    const rebuild = try devcontainerCommand(a, .{ .workspace = "/w", .rebuild = true }, "/home/u/.config/nvim");
    defer a.free(rebuild);
    try std.testing.expect(std.mem.startsWith(u8, rebuild, "/bin/sh -c 'devcontainer up --workspace-folder \"/w\" \"--additional-features\" \"{\\\"ghcr.io/"));
    try std.testing.expect(std.mem.indexOf(u8, rebuild, "\"--remove-existing-container\" && exec devcontainer exec --workspace-folder \"/w\"") != null);
    try std.testing.expect(std.mem.endsWith(u8, rebuild, "nvim --embed'"));
}

test "the ssh command quotes the remote nvim for the login shell" {
    const a = std.testing.allocator;
    const plain = try sshCommand(a, .{ .host = "me@box" }, "nvim");
    defer a.free(plain);
    try std.testing.expectEqualStrings("ssh-askpass ssh -o StrictHostKeyChecking=accept-new me@box '$SHELL --login -c \"\\\"nvim\\\" --embed\"'", plain);
    const keyed = try sshCommand(a, .{ .host = "box", .port = 2222, .identity = "/k/my key" }, "/opt/n\\vim");
    defer a.free(keyed);
    try std.testing.expectEqualStrings("ssh-askpass ssh -p 2222 -i \"/k/my key\" -o PasswordAuthentication=no -o KbdInteractiveAuthentication=no -o StrictHostKeyChecking=accept-new box '$SHELL --login -c \"\\\"/opt/n\\\\vim\\\" --embed\"'", keyed);
}

test "flags after -- belong to nvim" {
    const args = [_][]const u8{ "zonvie", "--nofork", "--", "--help" };
    try std.testing.expect(hasFlag(&args, "--nofork"));
    try std.testing.expect(!hasFlag(&args, "--help"));
    const connect = [_][]const u8{ "zonvie", "--connect-nvim=/tmp/s" };
    try std.testing.expect(hasPrefix(&connect, "--connect-nvim"));
}
