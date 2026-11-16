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
    \\    --extpopup, --extpopupmenu    Enable external popup menu UI
    \\    --extmessages                 Enable external messages UI
    \\    --exttabline                  Enable external tabline UI
    \\    --extwindows                  Enable external windows UI
    \\    --ssh=<user@host[:port]>      Connect to remote host via SSH
    \\    --ssh-identity=<path>         Path to SSH private key file
    \\    --devcontainer=<workspace>    Run inside a devcontainer
    \\    --devcontainer-config=<path>  Path to devcontainer.json
    \\    --devcontainer-rebuild        Rebuild devcontainer before starting
    \\    --connect-nvim=<addr>         Attach to a running Neovim server.
    \\                                    Address: TCP "host:port" or Unix socket path.
    \\                                    Mutually exclusive with --ssh / --devcontainer.
    \\    --remote-ui=<addr>            Alias of --connect-nvim, mirrors `nvim --remote-ui`.
    \\    --dialog                      Ask for the connection (Local / SSH / Devcontainer)
    \\                                    before launching nvim.
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

pub const app_id = "io.github.akiyosi.zonvie";

/// The desktop entry: named after the window's app id, which is the
/// Wayland app_id, so the compositor and launchers match the window to it.
/// `%F` hands chosen files to nvim; the MIME list puts Zonvie under "Open
/// with" for text files, the role Windows' Applications\zonvie.exe has.
fn desktopEntry(buf: []u8, exe: []const u8, icon: []const u8) ![]const u8 {
    return std.fmt.bufPrint(buf,
        \\[Desktop Entry]
        \\Type=Application
        \\Name=Zonvie
        \\GenericName=Text Editor
        \\Comment=A fast, feature-rich Neovim GUI
        \\Exec="{s}" %F
        \\Icon={s}
        \\Terminal=false
        \\Categories=Utility;TextEditor;
        \\Keywords=Text;Editor;Neovim;Vim;
        \\MimeType=text/plain;text/markdown;text/x-csrc;text/x-chdr;text/x-c++src;text/x-python;text/x-shellscript;application/x-shellscript;application/json;application/toml;application/x-yaml;
        \\StartupWMClass={s}
        \\Actions=new-session;
        \\
        \\[Desktop Action new-session]
        \\Name=New Session
        \\Exec="{s}" --dialog
        \\
    , .{ exe, icon, app_id, exe });
}

fn writeFile(path: []const u8, data: []const u8) !void {
    const io = clock.io();
    try std.Io.Dir.cwd().createDirPath(io, std.fs.path.dirname(path).?);
    const f = try std.Io.Dir.createFileAbsolute(io, path, .{ .truncate = true });
    defer f.close(io);
    try f.writeStreamingAll(io, data);
}

/// The desktop entry and its icon under $XDG_DATA_HOME (~/.local/share),
/// pointing at this executable. Rewritten on every --install, so a moved
/// binary is picked up again; a first launch keeps an existing entry.
fn installDesktopEntry(alloc: std.mem.Allocator, overwrite: bool) !void {
    const data_home = if (std.c.getenv("XDG_DATA_HOME")) |x| (if (std.mem.span(x).len > 0) try alloc.dupe(u8, std.mem.span(x)) else null) else null;
    const base = data_home orelse blk: {
        const home = std.c.getenv("HOME") orelse return error.NoHome;
        break :blk try std.fs.path.join(alloc, &.{ std.mem.span(home), ".local", "share" });
    };
    defer alloc.free(base);
    var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = std.c.readlink("/proc/self/exe", &exe_buf, exe_buf.len);
    if (n <= 0) return error.NoExe;
    const exe = exe_buf[0..@intCast(n)];

    const entry_path = try std.fs.path.join(alloc, &.{ base, "applications", app_id ++ ".desktop" });
    defer alloc.free(entry_path);
    if (!overwrite) if (std.Io.Dir.accessAbsolute(clock.io(), entry_path, .{})) |_| return else |_| {};
    const icon = try std.fs.path.join(alloc, &.{ base, "icons", app_id ++ ".png" });
    defer alloc.free(icon);
    try writeFile(icon, @embedFile("zonvie-256.png"));
    var buf: [4096]u8 = undefined;
    try writeFile(entry_path, try desktopEntry(&buf, exe, icon));
    std.debug.print("Desktop entry installed: {s}\n", .{entry_path});
}

/// Writes the default config.toml where the app reads it, never over an
/// existing one, and the desktop entry. Returns the process exit code.
pub fn install(alloc: std.mem.Allocator) u8 {
    installDesktopEntry(alloc, true) catch |e| std.debug.print("Failed to install the desktop entry: {any}\n", .{e});
    return writeDefaultConfig(alloc);
}

/// What a launch with no config file does first, as Windows does: the
/// default config.toml, and the desktop entry unless one exists.
pub fn installFirstLaunch(alloc: std.mem.Allocator) void {
    installDesktopEntry(alloc, false) catch |e| std.debug.print("Failed to install the desktop entry: {any}\n", .{e});
    _ = writeDefaultConfig(alloc);
}

fn writeDefaultConfig(alloc: std.mem.Allocator) u8 {
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
    if (!core.frontend_rules.nvimArgIsFile(prev, arg, after_dash_dash)) return arg;
    return absolutePath(alloc, arg);
}

/// `path` against this process's cwd, unless it is absolute already.
pub fn absolutePath(alloc: std.mem.Allocator, arg: []const u8) ![]const u8 {
    if (std.fs.path.isAbsolute(arg)) return arg;
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
    // quoted span as one argument (its tokenizer steps over \' without
    // ending it); the remote shell unquotes the outer "..." once and the
    // login shell the inner "<path>" again, so every path byte survives both.
    try out.appendSlice(alloc, " '$SHELL --login -c \"");
    try appendRemoteOuter(alloc, &out, "\"");
    for (remote_nvim) |ch| {
        // Inner level: inside "...", these four bytes are special.
        if (isDqSpecial(ch)) try appendRemoteOuter(alloc, &out, "\\");
        try appendRemoteOuter(alloc, &out, &.{ch});
    }
    try appendRemoteOuter(alloc, &out, "\" --embed");
    try out.appendSlice(alloc, "\"'");
    return out.toOwnedSliceSentinel(alloc, 0);
}

fn isDqSpecial(ch: u8) bool {
    return ch == '\\' or ch == '"' or ch == '$' or ch == '`';
}

/// `bytes` as the remote shell reads them inside the outer "...": the four
/// special bytes backslash-escaped, and `'` (which would end the core's
/// single-quoted span) as `"\'"`, a quote escaped outside the double quotes.
fn appendRemoteOuter(alloc: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), bytes: []const u8) !void {
    for (bytes) |ch| {
        if (ch == '\'') {
            try out.appendSlice(alloc, "\"\\'\"");
            continue;
        }
        if (isDqSpecial(ch)) try out.append(alloc, '\\');
        try out.append(alloc, ch);
    }
}

/// Appends `arg` to a spawn command for the core's tokenizer, quoted as
/// `spawnArgQuote` says. error.Unquotable when no quote can carry it (empty,
/// or a space with both quote kinds or a trailing backslash): the tokenizer
/// would hand nvim a different argument.
pub fn appendSpawnArg(list: *std.ArrayListUnmanaged(u8), alloc: std.mem.Allocator, arg: []const u8) !void {
    const q = core.frontend_rules.spawnArgQuote(arg) orelse return error.Unquotable;
    if (list.items.len != 0) try list.append(alloc, ' ');
    if (q != 0) try list.append(alloc, q);
    try list.appendSlice(alloc, arg);
    if (q != 0) try list.append(alloc, q);
}

test "spawn arguments are quoted for the core, or refused" {
    const a = std.testing.allocator;
    var l: std.ArrayListUnmanaged(u8) = .empty;
    defer l.deinit(a);
    try appendSpawnArg(&l, a, "/opt/my nvim/bin/nvim");
    try appendSpawnArg(&l, a, "it's.txt");
    try appendSpawnArg(&l, a, "a \"b\"");
    try std.testing.expectEqualStrings("\"/opt/my nvim/bin/nvim\" it's.txt 'a \"b\"'", l.items);
    try std.testing.expectError(error.Unquotable, appendSpawnArg(&l, a, "it's \"x\""));
    try std.testing.expectError(error.Unquotable, appendSpawnArg(&l, a, ""));
}

/// The Neovim path as the spawn command can carry it, for --nvim,
/// `[neovim] path` and the dialog alike (macOS's --nvim rule, Windows'
/// nvimPathArg): one pair of matching quotes around the whole path is
/// dropped; a path still holding a quote is refused (`ignored`, empty path)
/// so the caller falls back to the default and says so.
pub fn nvimPath(raw: []const u8) struct { path: []const u8, ignored: bool } {
    var p = raw;
    if (p.len >= 2 and (p[0] == '"' or p[0] == '\'') and p[p.len - 1] == p[0]) p = p[1 .. p.len - 1];
    if (std.mem.indexOfAny(u8, p, "'\"") != null) return .{ .path = "", .ignored = true };
    return .{ .path = p, .ignored = false };
}

test "the nvim path drops one pair of quotes and refuses the rest" {
    try std.testing.expectEqualStrings("/opt/my nvim", nvimPath("\"/opt/my nvim\"").path);
    try std.testing.expectEqualStrings("/a", nvimPath("'/a'").path);
    try std.testing.expectEqualStrings("/a", nvimPath("/a").path);
    try std.testing.expect(nvimPath("/a\"b").ignored);
    try std.testing.expect(nvimPath("\"/a'").ignored);
    try std.testing.expect(nvimPath("\"\"/a\"\"").ignored);
    try std.testing.expect(!nvimPath("").ignored);
}

pub extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
pub extern "c" fn unsetenv(name: [*:0]const u8) c_int;

/// Points ssh's SSH_ASKPASS at this executable in askpass mode (form.zig),
/// for every prompt, display or not. Before the core spawns ssh: it passes
/// the environment as it is then.
pub fn setAskpassEnv(env_mode: [:0]const u8) void {
    var buf: [std.fs.max_path_bytes:0]u8 = undefined;
    const n = std.c.readlink("/proc/self/exe", &buf, buf.len - 1);
    if (n <= 0) return;
    buf[@intCast(n)] = 0;
    _ = setenv(askpass_env[0], &buf, 1);
    _ = setenv(askpass_env[1], "force", 1);
    _ = setenv(env_mode, "1", 1);
}

/// The ssh variables setAskpassEnv sets besides its mode marker.
pub const askpass_env = [_][:0]const u8{ "SSH_ASKPASS", "SSH_ASKPASS_REQUIRE" };
/// Sets every variable `$SHELL -l -c 'env -0'` prints, but the ones that
/// describe that shell rather than the user's environment. A shell that
/// fails, or has not answered in 5 s, leaves the environment as it is.
pub fn importLoginShellEnv(alloc: std.mem.Allocator) void {
    const shell: []const u8 = if (std.c.getenv("SHELL")) |sh| std.mem.span(sh) else "/bin/sh";
    const io = clock.io();
    const r = std.process.run(alloc, io, .{
        .argv = &.{ shell, "-l", "-c", "env -0" },
        .stdout_limit = .limited(1 << 20),
        .stderr_limit = .limited(1 << 16),
        .timeout = .{ .duration = .{ .raw = .fromSeconds(5), .clock = .awake } },
    }) catch return;
    defer alloc.free(r.stdout);
    defer alloc.free(r.stderr);
    if (r.term != .exited or r.term.exited != 0) return;
    var it = ShellEnv{ .bytes = r.stdout };
    while (it.next()) |kv| _ = setenv(kv.key, kv.value, 1);
}

/// `KEY=VALUE\0` records, skipping the shell's own bookkeeping.
pub const ShellEnv = struct {
    bytes: []const u8,
    pos: usize = 0,

    pub const Pair = struct { key: [*:0]const u8, value: [*:0]const u8 };
    const skipped = [_][]const u8{ "PWD", "OLDPWD", "SHLVL", "_" };

    /// Each record must be NUL-terminated in `bytes`; the key's '=' is
    /// overwritten in place, so `bytes` must be writable memory.
    pub fn next(self: *ShellEnv) ?Pair {
        while (self.pos < self.bytes.len) {
            const start = self.pos;
            const len = std.mem.indexOfScalar(u8, self.bytes[start..], 0) orelse return null;
            self.pos = start + len + 1;
            const rec = self.bytes[start .. start + len];
            const eq = std.mem.indexOfScalar(u8, rec, '=') orelse continue;
            if (eq == 0) continue;
            if (isSkipped(rec[0..eq])) continue;
            const w: [*]u8 = @constCast(self.bytes.ptr);
            w[start + eq] = 0;
            return .{ .key = @ptrCast(w + start), .value = @ptrCast(w + start + eq + 1) };
        }
        return null;
    }

    fn isSkipped(key: []const u8) bool {
        for (skipped) |k| if (std.mem.eql(u8, k, key)) return true;
        return false;
    }
};

test "shell env records split at the first '=' and skip the shell's own" {
    var bytes = "PATH=/a:/b\x00PWD=/x\x00EQ=a=b\x00=bad\x00MULTI=1\n2\x00".*;
    var it = ShellEnv{ .bytes = &bytes };
    const a = it.next().?;
    try std.testing.expectEqualStrings("PATH", std.mem.span(a.key));
    try std.testing.expectEqualStrings("/a:/b", std.mem.span(a.value));
    const b = it.next().?;
    try std.testing.expectEqualStrings("EQ", std.mem.span(b.key));
    try std.testing.expectEqualStrings("a=b", std.mem.span(b.value));
    const c = it.next().?;
    try std.testing.expectEqualStrings("MULTI", std.mem.span(c.key));
    try std.testing.expectEqualStrings("1\n2", std.mem.span(c.value));
    try std.testing.expect(it.next() == null);
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

/// The command the core spawns for `--devcontainer`: the core's `devcontainer
/// exec` line into a running container, as macOS starts it. A rebuild runs
/// `devcontainerUpArgv` first, outside the core.
pub fn devcontainerCommand(alloc: std.mem.Allocator, d: Devcontainer) ![:0]u8 {
    var exec_buf: [4096]u8 = undefined;
    const cfg = d.config orelse "";
    const n = core.zonvie_core_devcontainer_exec_cmd(&exec_buf, exec_buf.len, d.workspace.ptr, d.workspace.len, if (d.config != null) cfg.ptr else null, cfg.len);
    return alloc.dupeZ(u8, exec_buf[0..n]);
}

/// `devcontainer up` for a rebuild, as an argv for direct spawn: the
/// workspace and config, then the core's arguments (the Neovim feature, the
/// nvim config mount, --remove-existing-container), as macOS runs it.
pub fn devcontainerUpArgv(alloc: std.mem.Allocator, d: Devcontainer, nvim_config_dir: []const u8) ![:null]?[*:0]const u8 {
    var argv: std.ArrayListUnmanaged(?[*:0]const u8) = .empty;
    errdefer argv.deinit(alloc);
    try argv.appendSlice(alloc, &.{ "devcontainer", "up", "--workspace-folder", (try alloc.dupeZ(u8, d.workspace)).ptr });
    if (d.config) |c| try argv.appendSlice(alloc, &.{ "--config", (try alloc.dupeZ(u8, c)).ptr });
    var args_buf: [4096]u8 = undefined;
    const len = core.zonvie_core_devcontainer_up_args(&args_buf, args_buf.len, nvim_config_dir.ptr, nvim_config_dir.len, d.rebuild);
    var it = std.mem.splitScalar(u8, args_buf[0..len], 0);
    while (it.next()) |arg| {
        if (arg.len == 0) continue;
        try argv.append(alloc, (try alloc.dupeZ(u8, arg)).ptr);
    }
    return argv.toOwnedSliceSentinel(alloc, null);
}

test "a devcontainer starts with exec; a rebuild runs up first" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const plain = try devcontainerCommand(a, .{ .workspace = "/w s" });
    try std.testing.expect(std.mem.startsWith(u8, plain, "devcontainer exec --workspace-folder \"/w s\""));
    try std.testing.expect(std.mem.endsWith(u8, plain, "nvim --embed"));
    const up = try devcontainerUpArgv(a, .{ .workspace = "/w", .config = "/c.json", .rebuild = true }, "/home/u/.config/nvim");
    try std.testing.expectEqualStrings("devcontainer", std.mem.span(up[0].?));
    try std.testing.expectEqualStrings("up", std.mem.span(up[1].?));
    try std.testing.expectEqualStrings("/w", std.mem.span(up[3].?));
    try std.testing.expectEqualStrings("--config", std.mem.span(up[4].?));
    try std.testing.expectEqualStrings("--additional-features", std.mem.span(up[6].?));
    try std.testing.expectEqualStrings("--remove-existing-container", std.mem.span(up[up.len - 1].?));
}

test "the ssh command quotes the remote nvim for the login shell" {
    const a = std.testing.allocator;
    const plain = try sshCommand(a, .{ .host = "me@box" }, "nvim");
    defer a.free(plain);
    try std.testing.expectEqualStrings("ssh-askpass ssh -o StrictHostKeyChecking=accept-new me@box '$SHELL --login -c \"\\\"nvim\\\" --embed\"'", plain);
    const keyed = try sshCommand(a, .{ .host = "box", .port = 2222, .identity = "/k/my key" }, "/opt/n\\vim");
    defer a.free(keyed);
    try std.testing.expectEqualStrings("ssh-askpass ssh -p 2222 -i \"/k/my key\" -o PasswordAuthentication=no -o KbdInteractiveAuthentication=no -o StrictHostKeyChecking=accept-new box '$SHELL --login -c \"\\\"/opt/n\\\\\\\\vim\\\" --embed\"'", keyed);
    // Spaces, both quotes, `$` and a trailing backslash: the outer level
    // reads `"/a b/it's/\"q\"/\$x/\\" --embed` back, the inner the path.
    const odd = try sshCommand(a, .{ .host = "box" }, "/a b/it's/\"q\"/$x/\\");
    defer a.free(odd);
    try std.testing.expectEqualStrings("ssh-askpass ssh -o StrictHostKeyChecking=accept-new box '$SHELL --login -c \"\\\"/a b/it\"\\'\"s/\\\\\\\"q\\\\\\\"/\\\\\\$x/\\\\\\\\\\\" --embed\"'", odd);
}

test "the desktop entry runs this executable with the chosen files" {
    var buf: [4096]u8 = undefined;
    const e = try desktopEntry(&buf, "/opt/zonvie/zonvie", "/x/icon.png");
    try std.testing.expect(std.mem.indexOf(u8, e, "Exec=\"/opt/zonvie/zonvie\" %F\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, e, "StartupWMClass=io.github.akiyosi.zonvie\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, e, "[Desktop Action new-session]\nName=New Session\nExec=\"/opt/zonvie/zonvie\" --dialog\n") != null);
}

test "flags after -- belong to nvim" {
    const args = [_][]const u8{ "zonvie", "--nofork", "--", "--help" };
    try std.testing.expect(hasFlag(&args, "--nofork"));
    try std.testing.expect(!hasFlag(&args, "--help"));
    const connect = [_][]const u8{ "zonvie", "--connect-nvim=/tmp/s" };
    try std.testing.expect(hasPrefix(&connect, "--connect-nvim"));
}

/// Why `zonvie_core_start` / `_start_connect` returned `rc`, in the words of
/// macOS's handleCoreStartFailure and Windows' showCoreStartFailed.
pub fn startFailureReason(rc: c_int) []const u8 {
    return switch (rc) {
        -1 => "Invalid core handle.",
        -2 => "Could not spawn the RPC run-loop thread.",
        -3 => "Invalid or unsupported listen address. For --connect-nvim, use a TCP \"host:port\" or an absolute Unix-socket path.",
        else => "Unknown error.",
    };
}

test "every start failure names its reason" {
    try std.testing.expectEqualStrings("Invalid core handle.", startFailureReason(-1));
    try std.testing.expect(std.mem.indexOf(u8, startFailureReason(-3), "--connect-nvim") != null);
    try std.testing.expectEqualStrings("Unknown error.", startFailureReason(-9));
}
