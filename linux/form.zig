//! The frontend's dialogs, without a toolkit: a zonvie window whose Neovim
//! is a throwaway one running a few lines of Lua. It asks through Neovim's
//! own prompts, writes the answer to a file, and quits; the process that
//! wanted the answer reads the file.
//!
//! Three of them: the SSH password prompt (this executable as ssh's
//! SSH_ASKPASS), the connection dialog (`--dialog`), and the crash report.
//! Each is one process: the mode is in the environment, which a form's own
//! Neovim does not inherit as a mode of its own (main.zig clears it).

const std = @import("std");
const core = @import("zonvie_core");
const clock = core.clock;

pub const Kind = enum { secret, connect, message };

/// Set, with the form's kind, in the environment of the process that is to
/// be the form.
pub const env_kind = "ZONVIE_FORM";
/// Where that process writes the answer.
pub const env_result = "ZONVIE_FORM_RESULT";
/// ssh's askpass marker: this executable is asked for a password, the
/// prompt in argv[1], the answer expected on stdout.
pub const env_askpass = "ZONVIE_ASKPASS_MODE";
/// The crash handler's marker: argv[1] is the report to show.
pub const env_crash = "ZONVIE_CRASH_REPORT";

/// The form this process is, by its environment.
pub fn requested() ?Kind {
    if (std.c.getenv(env_askpass) != null) return .secret;
    if (std.c.getenv(env_crash) != null) return .message;
    const k = std.mem.span(std.c.getenv(env_kind) orelse return null);
    return std.meta.stringToEnum(Kind, k);
}

/// `s` as a Lua string literal.
fn luaString(out: *std.ArrayListUnmanaged(u8), a: std.mem.Allocator, s: []const u8) !void {
    try out.append(a, '"');
    for (s) |ch| switch (ch) {
        '"', '\\' => try out.appendSlice(a, &.{ '\\', ch }),
        '\n' => try out.appendSlice(a, "\\n"),
        '\r' => {},
        else => try out.append(a, ch),
    };
    try out.append(a, '"');
}

/// What the connection dialog starts from, and what it answers: the same
/// keys, one `key=value` per line.
pub const Connect = struct {
    /// Read by the caller only; the dialog asks for it.
    mode: []const u8 = "local",
    name: []const u8 = "",
    nvim: []const u8 = "",
    ssh_host: []const u8 = "",
    ssh_identity: []const u8 = "",
    dc_workspace: []const u8 = "",
    dc_config: []const u8 = "",
    dc_rebuild: bool = false,

    /// The answer file's text as a Connect; slices point into `text`.
    pub fn parse(text: []const u8) Connect {
        var c: Connect = .{};
        var lines = std.mem.tokenizeScalar(u8, text, '\n');
        while (lines.next()) |line| {
            const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
            const key = line[0..eq];
            const value = line[eq + 1 ..];
            inline for (.{ "mode", "name", "nvim", "ssh_host", "ssh_identity", "dc_workspace", "dc_config" }) |f| {
                if (std.mem.eql(u8, key, f)) @field(c, f) = value;
            }
            if (std.mem.eql(u8, key, "dc_rebuild")) c.dc_rebuild = std.mem.eql(u8, value, "1");
        }
        return c;
    }
};

test "the connection answer reads back by key" {
    const c = Connect.parse("mode=ssh\nssh_host=me@box:2222\nname=work\ndc_rebuild=1\nnoise\n");
    try std.testing.expectEqualStrings("ssh", c.mode);
    try std.testing.expectEqualStrings("me@box:2222", c.ssh_host);
    try std.testing.expectEqualStrings("work", c.name);
    try std.testing.expect(c.dc_rebuild);
    try std.testing.expectEqualStrings("", c.nvim);
}

/// The Lua the form's Neovim runs once its UI is attached. `text`: the
/// prompt (secret) or the report (message). `seed`: the connection dialog's
/// starting values.
pub fn script(a: std.mem.Allocator, kind: Kind, text: []const u8, result_path: []const u8, seed: Connect) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    try out.appendSlice(a, "local RESULT = ");
    try luaString(&out, a, result_path);
    try out.appendSlice(a, "\nlocal TEXT = ");
    try luaString(&out, a, text);
    try out.appendSlice(a, "\nlocal SEED = {");
    inline for (.{ "mode", "name", "nvim", "ssh_host", "ssh_identity", "dc_workspace", "dc_config" }) |f| {
        try out.appendSlice(a, f ++ " = ");
        try luaString(&out, a, @field(seed, f));
        try out.appendSlice(a, ", ");
    }
    try out.appendSlice(a, if (seed.dc_rebuild) "dc_rebuild = true}\n" else "dc_rebuild = false}\n");
    try out.appendSlice(a,
        \\vim.o.laststatus = 0
        \\vim.o.ruler = false
        \\vim.o.showcmd = false
        \\vim.o.shortmess = vim.o.shortmess .. 'I'
        \\local function done(lines)
        \\  if lines then
        \\    local f = io.open(RESULT, 'w')
        \\    if f then f:write(table.concat(lines, '\n')); f:close() end
        \\  end
        \\  vim.cmd('qa!')
        \\end
        \\local function ask(prompt, default)
        \\  local ok, v = pcall(vim.fn.input, {prompt = prompt, default = default or '', cancelreturn = vim.NIL})
        \\  if not ok or v == vim.NIL then return nil end
        \\  return v
        \\end
        \\
    );
    switch (kind) {
        .secret => try out.appendSlice(a,
            \\local function run()
            \\  local ok, v = pcall(vim.fn.inputsecret, TEXT .. ' ')
            \\  if ok and v ~= '' then done({v}) else done(nil) end
            \\end
            \\
        ),
        .message => try out.appendSlice(a,
            \\local function run()
            \\  vim.api.nvim_buf_set_lines(0, 0, -1, false, vim.split(TEXT .. '\n\nPress q or Enter to close.', '\n'))
            \\  vim.bo.modifiable = false
            \\  vim.bo.modified = false
            \\  for _, k in ipairs({'q', '<CR>', '<Esc>'}) do vim.keymap.set('n', k, '<cmd>qa!<cr>', {buffer = 0}) end
            \\end
            \\
        ),
        .connect => try out.appendSlice(a,
            \\local function run()
            \\  local modes = {'local', 'ssh', 'devcontainer'}
            \\  local mode = modes[vim.fn.inputlist({'Zonvie: where does Neovim run?', '1. This computer', '2. A host over SSH', '3. A devcontainer'})]
            \\  if not mode then return done(nil) end
            \\  local out = {'mode=' .. mode}
            \\  local function field(key, prompt, default)
            \\    local v = ask(prompt, default)
            \\    if v == nil then return false end
            \\    out[#out + 1] = key .. '=' .. v
            \\    return true
            \\  end
            \\  if not field('name', 'Session name (optional): ', SEED.name) then return done(nil) end
            \\  if mode == 'local' then
            \\    if not field('nvim', 'Neovim executable (empty: default): ', SEED.nvim) then return done(nil) end
            \\  elseif mode == 'ssh' then
            \\    if not field('ssh_host', 'Host ([user@]host[:port]): ', SEED.ssh_host) then return done(nil) end
            \\    if not field('ssh_identity', 'Identity file (optional): ', SEED.ssh_identity) then return done(nil) end
            \\    if not field('nvim', 'Remote Neovim executable (empty: nvim): ', SEED.nvim) then return done(nil) end
            \\  else
            \\    if not field('dc_workspace', 'Workspace folder: ', SEED.dc_workspace) then return done(nil) end
            \\    if not field('dc_config', 'devcontainer.json (optional): ', SEED.dc_config) then return done(nil) end
            \\    local r = vim.fn.confirm('Rebuild the container first?', '&No\n&Yes', SEED.dc_rebuild and 2 or 1)
            \\    out[#out + 1] = 'dc_rebuild=' .. ((r == 2) and '1' or '0')
            \\  end
            \\  done(out)
            \\end
            \\
        ),
    }
    try out.appendSlice(a,
        \\-- A prompt blocks Neovim: it waits until the grid has taken the window's size.
        \\vim.api.nvim_create_autocmd('UIEnter', {once = true, callback = function() vim.defer_fn(run, 150) end})
        \\
    );
    return out.items;
}

/// A file for this process in the user's runtime directory (else /tmp).
pub fn tempPath(buf: []u8, name: []const u8) ?[:0]const u8 {
    const dir: []const u8 = if (std.c.getenv("XDG_RUNTIME_DIR")) |d| std.mem.span(d) else "/tmp";
    return std.fmt.bufPrintZ(buf, "{s}/zonvie-{d}-{s}", .{ dir, std.c.getpid(), name }) catch null;
}

pub fn writeFile(path: [:0]const u8, bytes: []const u8) bool {
    const fd = std.c.open(path.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true }, @as(std.c.mode_t, 0o600));
    if (fd < 0) return false;
    defer _ = std.c.close(fd);
    var rest = bytes;
    while (rest.len > 0) {
        const n = std.c.write(fd, rest.ptr, rest.len);
        if (n <= 0) return false;
        rest = rest[@intCast(n)..];
    }
    return true;
}

/// The whole file, or null when there is none (a cancelled form writes none).
pub fn readFile(a: std.mem.Allocator, path: [:0]const u8) ?[]u8 {
    const fd = std.c.open(path.ptr, .{ .ACCMODE = .RDONLY, .CLOEXEC = true });
    if (fd < 0) return null;
    defer _ = std.c.close(fd);
    var out: std.ArrayListUnmanaged(u8) = .empty;
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = std.c.read(fd, &buf, buf.len);
        if (n <= 0) break;
        out.appendSlice(a, buf[0..@intCast(n)]) catch return null;
    }
    return out.items;
}

extern "c" fn unlink(path: [*:0]const u8) c_int;

pub fn remove(path: [:0]const u8) void {
    _ = unlink(path.ptr);
}
