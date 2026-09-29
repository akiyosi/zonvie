//! Rules both frontends applied with their own copies: the commands a tab drag
//! sends, whether a custom shader animates, where the message floats and the
//! cmdline sit, and the cursor blink cadence. Pure; the frontends keep the
//! windows, timers and events.

const std = @import("std");

// ---------------------------------------------------------------------------
// Tabs

/// The command that moves the tab at `from_idx` (0-based) to the drop
/// insertion index `drop_idx` of the list before the move, or null when the
/// drop leaves it where it is. `:tabmove N` acts on the current tab and moves
/// it after tab page N of that same list (1-based, 0 = front), so the dragged
/// tab is made current in the same command: sent as two commands, a tab switch
/// landing between them (an autocmd, a job opening a tab) moved another tab.
pub fn tabMoveCommand(buf: []u8, from_idx: u32, drop_idx: u32, tab_count: u32) ?[]const u8 {
    if (from_idx >= tab_count) return null;
    // Onto its own slot, or just past it, is where it already is.
    if (drop_idx == from_idx or drop_idx == from_idx + 1) return null;
    const pos = @min(drop_idx, tab_count);
    return std.fmt.bufPrint(buf, "{d}tabnext | tabmove {d}", .{ from_idx + 1, pos }) catch null;
}

/// The insertion index a tab drag at `pos` drops on: the first of `count`
/// equal tabs (tab i starts at origin + i*stride and is `size` long) whose
/// centre is past `pos`, else `count`. One axis: x on a tab bar, y down a
/// sidebar.
pub fn tabDropIndex(pos: f64, count: u32, origin: f64, stride: f64, size: f64) u32 {
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        if (pos < origin + @as(f64, @floatFromInt(i)) * stride + size / 2) return i;
    }
    return count;
}

test "tabDropIndex is the first tab whose centre is past the pointer" {
    // Tabs at 10, 110, 210, each 90 long: centres 55, 155, 255.
    try std.testing.expectEqual(@as(u32, 0), tabDropIndex(54, 3, 10, 100, 90));
    try std.testing.expectEqual(@as(u32, 1), tabDropIndex(55, 3, 10, 100, 90));
    try std.testing.expectEqual(@as(u32, 2), tabDropIndex(200, 3, 10, 100, 90));
    try std.testing.expectEqual(@as(u32, 3), tabDropIndex(900, 3, 10, 100, 90));
    try std.testing.expectEqual(@as(u32, 0), tabDropIndex(0, 0, 10, 100, 90));
}

/// The command that moves the only window of tab `tab_idx` (0-based) into an
/// external window, leaving a scratch buffer in the tab. Refuses a tab with a
/// split. nvim_open_win rather than a split: under ext_windows a split would
/// open another external window.
pub fn externalizeTabCommand(buf: []u8, tab_idx: u32) ?[]const u8 {
    return std.fmt.bufPrint(buf, "lua vim.cmd('{d}tabnext'); local tp=vim.api.nvim_get_current_tabpage(); local ws=vim.api.nvim_tabpage_list_wins(tp); if #ws>1 then vim.notify('Cannot externalize: split window',vim.log.levels.WARN); return end; local w=ws[1]; local buf=vim.api.nvim_win_get_buf(w); local cur=vim.api.nvim_win_get_cursor(w); local W=vim.api.nvim_win_get_width(w); local H=vim.api.nvim_win_get_height(w); local ew=vim.api.nvim_open_win(buf,true,{{external=true,width=W,height=H}}); vim.api.nvim_win_set_cursor(ew,cur); vim.api.nvim_win_set_buf(w,vim.api.nvim_create_buf(true,true))", .{tab_idx + 1}) catch null;
}

test "a tab move is one command that selects the dragged tab first" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("1tabnext | tabmove 3", tabMoveCommand(&buf, 0, 3, 4).?);
    try std.testing.expectEqualStrings("4tabnext | tabmove 0", tabMoveCommand(&buf, 3, 0, 4).?);
    // Past the end clamps to the last position.
    try std.testing.expectEqualStrings("1tabnext | tabmove 4", tabMoveCommand(&buf, 0, 9, 4).?);
}

test "a tab dropped onto or just past itself does not move" {
    var buf: [64]u8 = undefined;
    try std.testing.expect(tabMoveCommand(&buf, 2, 2, 4) == null);
    try std.testing.expect(tabMoveCommand(&buf, 2, 3, 4) == null);
    try std.testing.expect(tabMoveCommand(&buf, 4, 0, 4) == null);
}

test "externalizing selects the tab by its 1-based number" {
    var buf: [1024]u8 = undefined;
    const cmd = externalizeTabCommand(&buf, 2).?;
    try std.testing.expect(std.mem.startsWith(u8, cmd, "lua vim.cmd('3tabnext');"));
    try std.testing.expect(std.mem.indexOf(u8, cmd, "{external=true,width=W,height=H}") != null);
}

// ---------------------------------------------------------------------------
// Mouse modifiers

/// The modifier string of nvim_input_mouse ("S", "C", "A", "D" in that
/// order) for the send_key_event bitmask: 1<<0 Ctrl, 1<<1 Alt, 1<<2 Shift,
/// 1<<3 Super. NUL-terminated in `buf`.
pub fn mouseModifierString(buf: *[5]u8, mods: u32) [:0]const u8 {
    var len: usize = 0;
    const order = [_]struct { bit: u32, letter: u8 }{
        .{ .bit = 1 << 2, .letter = 'S' },
        .{ .bit = 1 << 0, .letter = 'C' },
        .{ .bit = 1 << 1, .letter = 'A' },
        .{ .bit = 1 << 3, .letter = 'D' },
    };
    for (order) |m| {
        if (mods & m.bit == 0) continue;
        buf[len] = m.letter;
        len += 1;
    }
    buf[len] = 0;
    return buf[0..len :0];
}

test "mouse modifiers come out as S, C, A, D in that order" {
    var buf: [5]u8 = undefined;
    try std.testing.expectEqualStrings("", mouseModifierString(&buf, 0));
    try std.testing.expectEqualStrings("S", mouseModifierString(&buf, 1 << 2));
    try std.testing.expectEqualStrings("CA", mouseModifierString(&buf, (1 << 0) | (1 << 1)));
    try std.testing.expectEqualStrings("SCAD", mouseModifierString(&buf, 0xF));
    try std.testing.expectEqualStrings("D", mouseModifierString(&buf, (1 << 3) | (1 << 8)));
}

/// The pointer claim of a surface: which buttons have had a press sent to the
/// editor, and which one's press chose the grid every release and drag goes
/// to. Buttons are 1 left, 2 right, 3 middle, 4 x1, 5 x2 (as in zonvie_core.h).
/// A left press takes the claim; another button's takes it unless left holds
/// it. Every sent press gets its release, to the claim's grid, whatever the
/// order they are let go in; the claim ends with the last held button.
pub const PressClaim = extern struct {
    held_mask: u8 = 0,
    /// The button drags are reported as; 0 once nothing is held.
    owner: u8 = 0,

    pub const Release = struct { send: bool, ends: bool };

    fn bit(button: u8) u8 {
        return @as(u8, 1) << @intCast(button & 7);
    }

    /// Whether this press takes the claim (the caller pins its grid).
    pub fn press(self: *PressClaim, button: u8) bool {
        self.held_mask |= bit(button);
        if (self.owner == 1 and button != 1) return false;
        self.owner = button;
        return true;
    }

    /// Whether to send this release (to the claim's grid), and whether it
    /// ends the claim. A release whose press was never sent is dropped.
    pub fn release(self: *PressClaim, button: u8) Release {
        if (self.held_mask & bit(button) == 0) return .{ .send = false, .ends = self.held_mask == 0 };
        self.held_mask &= ~bit(button);
        if (self.held_mask == 0) {
            self.owner = 0;
        } else if (button == self.owner) {
            self.owner = @ctz(self.held_mask); // bit n is button n
        }
        return .{ .send = true, .ends = self.held_mask == 0 };
    }
};

test "every sent press gets its release, in any release order" {
    var c = PressClaim{};
    // Right, then middle (which takes the claim), let go last-in first-out.
    try std.testing.expect(c.press(2));
    try std.testing.expect(c.press(3));
    try std.testing.expectEqual(PressClaim.Release{ .send = true, .ends = false }, c.release(3));
    try std.testing.expectEqual(@as(u8, 2), c.owner);
    try std.testing.expectEqual(PressClaim.Release{ .send = true, .ends = true }, c.release(2));
    // Left holds the claim against a right press; left let go first.
    try std.testing.expect(c.press(1));
    try std.testing.expect(!c.press(2));
    try std.testing.expectEqual(@as(u8, 1), c.owner);
    try std.testing.expectEqual(PressClaim.Release{ .send = true, .ends = false }, c.release(1));
    try std.testing.expectEqual(PressClaim.Release{ .send = true, .ends = true }, c.release(2));
    // A left press takes over a right claim; the right release keeps it.
    try std.testing.expect(c.press(2));
    try std.testing.expect(c.press(1));
    try std.testing.expectEqual(PressClaim.Release{ .send = true, .ends = false }, c.release(2));
    try std.testing.expectEqual(@as(u8, 1), c.owner);
    try std.testing.expectEqual(PressClaim.Release{ .send = true, .ends = true }, c.release(1));
    // A release whose press never reached the editor is not sent.
    try std.testing.expectEqual(PressClaim.Release{ .send = false, .ends = true }, c.release(3));
    try std.testing.expectEqual(@as(u8, 0), c.held_mask);
}

// ---------------------------------------------------------------------------
// CLI

pub const SshTarget = struct { host: []const u8, port: ?u16 };

/// `user@host[:port]`: the port is what follows the last colon, and only when
/// that is a port number; otherwise the whole value is the host.
pub fn sshTarget(value: []const u8) SshTarget {
    const colon = std.mem.lastIndexOfScalar(u8, value, ':') orelse return .{ .host = value, .port = null };
    const port = std.fmt.parseInt(u16, value[colon + 1 ..], 10) catch return .{ .host = value, .port = null };
    return .{ .host = value[0..colon], .port = port };
}

/// Whether a bare flag (`--ssh host`) takes the token after it as its value:
/// only when there is one and it is not itself a flag, so `--ssh --dialog`
/// does not take "--dialog" as the host.
pub fn cliNextIsValue(next: ?[]const u8) bool {
    const n = next orelse return false;
    return !std.mem.startsWith(u8, n, "-");
}

/// The longest prefix of `bytes` at most `max` long that does not end inside a
/// UTF-8 sequence, for copies into fixed-size message buffers. A cut in the
/// middle of a character left a truncated sequence that macOS decodes as an
/// empty string.
pub fn utf8PrefixLen(bytes: []const u8, max: usize) usize {
    if (bytes.len <= max) return bytes.len;
    var n = max;
    while (n > 0 and (bytes[n] & 0xC0) == 0x80) n -= 1;
    return n;
}

test "utf8PrefixLen never cuts a character" {
    const s = "a\u{3042}b"; // 'a', 3-byte hiragana, 'b'
    try std.testing.expectEqual(@as(usize, 1), utf8PrefixLen(s, 2));
    try std.testing.expectEqual(@as(usize, 1), utf8PrefixLen(s, 3));
    try std.testing.expectEqual(@as(usize, 4), utf8PrefixLen(s, 4));
    try std.testing.expectEqual(s.len, utf8PrefixLen(s, 99));
}

/// Copy `src` into `dst`; when it does not fit, cut at a UTF-8 boundary and
/// end with '…' so the reader sees text is missing. Returns the bytes written.
pub fn copyUtf8Truncated(dst: []u8, src: []const u8) usize {
    if (src.len <= dst.len) {
        @memcpy(dst[0..src.len], src);
        return src.len;
    }
    const marker = "\u{2026}";
    if (dst.len < marker.len) return 0;
    const cut = utf8PrefixLen(src, dst.len - marker.len);
    @memcpy(dst[0..cut], src[0..cut]);
    @memcpy(dst[cut..][0..marker.len], marker);
    return cut + marker.len;
}

/// Lines a mini window shows; noice.nvim's views.mini max_height.
pub const mini_max_lines = 10;

/// Mini content as shown: a trailing newline dropped, and past
/// `mini_max_lines` lines the first nine plus a "…(N more lines)" summary
/// line. Content past `dst` is cut by copyUtf8Truncated. Returns the bytes
/// written.
pub fn clampMiniContent(dst: []u8, content: []const u8) usize {
    const src = if (content.len > 0 and content[content.len - 1] == '\n') content[0 .. content.len - 1] else content;
    const lines = std.mem.count(u8, src, "\n") + 1;
    if (lines <= mini_max_lines) return copyUtf8Truncated(dst, src);
    const kept = mini_max_lines - 1;
    var head_end: usize = 0;
    for (0..kept) |n| {
        const nl = std.mem.indexOfScalarPos(u8, src, head_end, '\n').?;
        head_end = if (n + 1 == kept) nl else nl + 1;
    }
    var summary_buf: [48]u8 = undefined;
    const summary = std.fmt.bufPrint(&summary_buf, "\n\u{2026}({d} more lines)", .{lines - kept}) catch unreachable;
    if (dst.len < summary.len) return copyUtf8Truncated(dst, src[0..head_end]);
    const head_len = copyUtf8Truncated(dst[0 .. dst.len - summary.len], src[0..head_end]);
    @memcpy(dst[head_len..][0..summary.len], summary);
    return head_len + summary.len;
}

/// A message or cmdline panel's background from Normal's (sRGB 0..1): HSB
/// brightness moved 0.05 toward the middle, hue and saturation kept. With
/// both kept, that is RGB scaled by the brightness ratio.
pub fn panelBg(r: f32, g: f32, b: f32) [3]f32 {
    const v = @max(r, @max(g, b));
    const v2 = if (v < 0.5) @min(v + 0.05, 1.0) else @max(v - 0.05, 0.0);
    if (v == 0) return .{ v2, v2, v2 };
    const k = v2 / v;
    return .{ r * k, g * k, b * k };
}

test "panelBg moves brightness toward the middle and keeps hue and saturation" {
    const tol = 1e-6;
    const dark = panelBg(0.1, 0.2, 0.3);
    try std.testing.expectApproxEqAbs(@as(f32, 0.35), dark[2], tol);
    try std.testing.expectApproxEqAbs(@as(f32, 0.35) / 3.0, dark[0], tol);
    const light = panelBg(1.0, 1.0, 1.0);
    try std.testing.expectApproxEqAbs(@as(f32, 0.95), light[0], tol);
    const black = panelBg(0, 0, 0);
    try std.testing.expectApproxEqAbs(@as(f32, 0.05), black[1], tol);
}

/// How one argument goes into a spawn command so the core's tokenizer
/// (rpc_session.zig tokenizeCommand) hands it back unchanged: 0 bare, or the
/// quote to wrap it in. The tokenizer splits on spaces, takes a leading quote
/// as grouping, never unescapes, and ends a quoted token at its quote (or at
/// a backslash-quote pair). Null when neither quote can carry the argument
/// (an empty one, or one with a space and both quote kinds).
pub fn spawnArgQuote(arg: []const u8) ?u8 {
    if (arg.len == 0) return null;
    const needs_quote = std.mem.indexOfScalar(u8, arg, ' ') != null or arg[0] == '"' or arg[0] == '\'';
    if (!needs_quote) return 0;
    const ends_in_backslash = arg[arg.len - 1] == '\\';
    for ([_]u8{ '"', '\'' }) |q| {
        if (std.mem.indexOfScalar(u8, arg, q) == null and !ends_in_backslash) return q;
    }
    return null;
}

test "spawnArgQuote picks a quote the core's tokenizer gives back unchanged" {
    try std.testing.expectEqual(@as(?u8, 0), spawnArgQuote("notes.txt"));
    try std.testing.expectEqual(@as(?u8, 0), spawnArgQuote("a\"b"));
    try std.testing.expectEqual(@as(?u8, '"'), spawnArgQuote("my notes.txt"));
    // `-c "echo \"hi there\""` arrives as `echo "hi there"`: double quotes
    // would end the token at the first inner one.
    try std.testing.expectEqual(@as(?u8, '\''), spawnArgQuote("echo \"hi there\""));
    try std.testing.expectEqual(@as(?u8, '"'), spawnArgQuote("'quoted'"));
    try std.testing.expectEqual(@as(?u8, null), spawnArgQuote("it's \"x\""));
    try std.testing.expectEqual(@as(?u8, null), spawnArgQuote("C:\\My Dir\\"));
    try std.testing.expectEqual(@as(?u8, null), spawnArgQuote(""));
}

/// Whether `arg` is a file argument to nvim: not a flag (`-`), not a command
/// (`+`), not the value of the option `prev` names (`-u NONE`). After `--`
/// every token but `-` (stdin) is a file.
pub fn nvimArgIsFile(prev: ?[]const u8, arg: []const u8, after_dash_dash: bool) bool {
    if (arg.len == 0) return false;
    if (after_dash_dash) return !std.mem.eql(u8, arg, "-");
    if (arg[0] == '-' or arg[0] == '+') return false;
    const takes_value = [_][]const u8{ "-u", "-i", "-c", "-S", "-s", "-t", "-w", "-W", "-l", "--cmd", "--listen", "--server", "--startuptime" };
    if (prev) |p| for (takes_value) |o| if (std.mem.eql(u8, p, o)) return false;
    return true;
}

test "nvimArgIsFile keeps flags, commands and option values out of the file list" {
    try std.testing.expect(nvimArgIsFile(null, "foo.txt", false));
    try std.testing.expect(nvimArgIsFile("-p", "foo.txt", false));
    try std.testing.expect(nvimArgIsFile(null, "C:foo.txt", false));
    try std.testing.expect(!nvimArgIsFile(null, "-p", false));
    try std.testing.expect(!nvimArgIsFile(null, "+10", false));
    try std.testing.expect(!nvimArgIsFile("-u", "NONE", false));
    try std.testing.expect(!nvimArgIsFile("--cmd", "set nu", false));
    try std.testing.expect(!nvimArgIsFile("-t", "main", false));
    try std.testing.expect(!nvimArgIsFile(null, "", false));
    try std.testing.expect(nvimArgIsFile(null, "-u", true));
    try std.testing.expect(nvimArgIsFile(null, "+10", true));
    try std.testing.expect(!nvimArgIsFile(null, "-", true));
}

/// A devcontainer workspace or config path as the devcontainer commands can
/// quote it: one pair of Explorer "Copy as path" quotes dropped, and trailing
/// backslashes dropped (`C:\proj\` is `C:\proj`); a root keeps its backslash
/// and gets a `.` after it (`C:\.`). Inside `"..."` a trailing backslash
/// escapes the closing quote, and the rest of the command becomes part of
/// the path. A POSIX path passes through unchanged.
pub fn writeDevcontainerPath(w: *std.Io.Writer, raw: []const u8) !void {
    var p = raw;
    if (p.len >= 2 and p[0] == '"' and p[p.len - 1] == '"') p = p[1 .. p.len - 1];
    while (p.len > 1 and p[p.len - 1] == '\\' and p[p.len - 2] != ':') p = p[0 .. p.len - 1];
    try w.writeAll(p);
    if (p.len > 0 and p[p.len - 1] == '\\') try w.writeByte('.');
}

/// The `devcontainer exec ... nvim --embed` command line, as much of it as
/// fits in `buf`: a truncated command fails at the spawn.
pub fn devcontainerExecCmd(buf: []u8, workspace: []const u8, config_path: ?[]const u8) []const u8 {
    var w = std.Io.Writer.fixed(buf);
    w.writeAll("devcontainer exec --workspace-folder \"") catch {};
    writeDevcontainerPath(&w, workspace) catch {};
    w.writeAll("\"") catch {};
    if (config_path) |cfg| {
        w.writeAll(" --config \"") catch {};
        writeDevcontainerPath(&w, cfg) catch {};
        w.writeAll("\"") catch {};
    }
    w.writeAll(" --remote-env XDG_CONFIG_HOME=/nvim-config nvim --embed") catch {};
    return buf[0..w.end];
}

/// The `devcontainer up` arguments after the workspace and config paths, each
/// NUL-terminated in `buf` so the frontends can apply their own shell quoting
/// per argument: the Neovim feature pinned to its stable release (nightly
/// builds with assertions on and aborts in msg_scroll_flush; the pin also
/// changes the feature hash, so a rebuild drops a cached nightly layer), the
/// bind mount of the user's nvim config where devcontainerExecCmd's
/// XDG_CONFIG_HOME finds it, and the rebuild flag.
pub fn devcontainerUpArgs(buf: []u8, nvim_config_dir: []const u8, rebuild: bool) []const u8 {
    var w = std.Io.Writer.fixed(buf);
    w.writeAll("--additional-features\x00{\"ghcr.io/duduribeiro/devcontainer-features/neovim:1\":{\"version\":\"stable\"}}\x00") catch {};
    w.writeAll("--mount\x00type=bind,source=") catch {};
    w.writeAll(nvim_config_dir) catch {};
    w.writeAll(",target=/nvim-config/nvim\x00") catch {};
    if (rebuild) w.writeAll("--remove-existing-container\x00") catch {};
    return buf[0..w.end];
}

test "the devcontainer up arguments pin the stable feature and mount the nvim config" {
    var buf: [512]u8 = undefined;
    try std.testing.expectEqualStrings(
        "--additional-features\x00{\"ghcr.io/duduribeiro/devcontainer-features/neovim:1\":{\"version\":\"stable\"}}\x00" ++
            "--mount\x00type=bind,source=/home/me/.config/nvim,target=/nvim-config/nvim\x00--remove-existing-container\x00",
        devcontainerUpArgs(&buf, "/home/me/.config/nvim", true),
    );
    // Without a rebuild the existing container is kept.
    const keep = devcontainerUpArgs(&buf, "C:\\Users\\me\\AppData\\Local\\nvim", false);
    try std.testing.expect(std.mem.indexOf(u8, keep, "--remove-existing-container") == null);
    try std.testing.expect(std.mem.indexOf(u8, keep, "source=C:\\Users\\me\\AppData\\Local\\nvim,target=/nvim-config/nvim\x00") != null);
    // The mount lands where the exec command's XDG_CONFIG_HOME looks.
    var exec_buf: [256]u8 = undefined;
    try std.testing.expect(std.mem.indexOf(u8, devcontainerExecCmd(&exec_buf, "/w", null), "XDG_CONFIG_HOME=/nvim-config ") != null);
}

test "a devcontainer path drops what would break the quoted argument" {
    const cases = [_]struct { raw: []const u8, want: []const u8 }{
        .{ .raw = ".\\proj\\", .want = ".\\proj" },
        .{ .raw = "C:\\My Dir\\\\", .want = "C:\\My Dir" },
        .{ .raw = "\"C:\\proj\"", .want = "C:\\proj" },
        .{ .raw = "C:\\", .want = "C:\\." },
        .{ .raw = "\"D:\\\"", .want = "D:\\." },
        .{ .raw = "/work/app", .want = "/work/app" },
        .{ .raw = "/work/app/", .want = "/work/app/" },
        .{ .raw = "\\", .want = "\\." },
    };
    for (cases) |case| {
        var buf: [64]u8 = undefined;
        var w = std.Io.Writer.fixed(&buf);
        try writeDevcontainerPath(&w, case.raw);
        try std.testing.expectEqualStrings(case.want, buf[0..w.end]);
    }
}

test "the devcontainer exec command quotes both paths and embeds nvim" {
    var buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings(
        "devcontainer exec --workspace-folder \"/work/app\" --remote-env XDG_CONFIG_HOME=/nvim-config nvim --embed",
        devcontainerExecCmd(&buf, "/work/app", null),
    );
    try std.testing.expectEqualStrings(
        "devcontainer exec --workspace-folder \"C:\\proj\" --config \"C:\\proj\\.devcontainer\\devcontainer.json\" --remote-env XDG_CONFIG_HOME=/nvim-config nvim --embed",
        devcontainerExecCmd(&buf, "\"C:\\proj\\\"", "C:\\proj\\.devcontainer\\devcontainer.json"),
    );
}

test "an ssh target splits its port off the last colon, only when numeric" {
    const plain = sshTarget("me@host");
    try std.testing.expectEqualStrings("me@host", plain.host);
    try std.testing.expect(plain.port == null);
    const with_port = sshTarget("me@host:2222");
    try std.testing.expectEqualStrings("me@host", with_port.host);
    try std.testing.expectEqual(@as(?u16, 2222), with_port.port);
    // Not a port: the colon stays in the host.
    const alias = sshTarget("me@host:dev");
    try std.testing.expectEqualStrings("me@host:dev", alias.host);
    try std.testing.expect(alias.port == null);
    try std.testing.expectEqualStrings("host:", sshTarget("host:").host);
    try std.testing.expectEqualStrings("host:99999", sshTarget("host:99999").host);
}

test "a bare flag takes the next token only when it is a value" {
    try std.testing.expect(cliNextIsValue("me@host"));
    try std.testing.expect(!cliNextIsValue("--dialog"));
    try std.testing.expect(!cliNextIsValue("-u"));
    try std.testing.expect(!cliNextIsValue(null));
}

// ---------------------------------------------------------------------------
// File drops

/// Whether a drop inserts the path into the command line rather than opening
/// the file: always on the external cmdline window itself (`force`); never on
/// a buffer surface while the cmdline has its own window; otherwise while the
/// built-in cmdline is up.
pub fn dropInsertsPath(mode: []const u8, has_external_cmdline: bool, force: bool) bool {
    if (force) return true;
    if (has_external_cmdline) return false;
    return std.mem.startsWith(u8, mode, "cmdline");
}

/// `path` as Neovim's fnameescape() writes it for a `:e`-style argument: its
/// PATH_ESC_CHARS backslashed, plus a leading `>`, `+` or lone `-`, which are
/// special at the start of :edit/:write/:cd. With `backslash_is_separator`
/// (a Windows server) `$` and `\` are plain path bytes and `[{!` are in the
/// default 'isfname', so none of them is escaped. Needs
/// `out.len >= 2 * path.len + 1`; null when the result does not fit.
pub fn escapePathForCmdline(out: []u8, path: []const u8, backslash_is_separator: bool) ?[]const u8 {
    const special: []const u8 = if (backslash_is_separator) " \t\n*?`%#'\"|<" else " \t\n*?[{`$\\%#'\"|!<";
    var n: usize = 0;
    if (path.len > 0 and (path[0] == '>' or path[0] == '+' or (path[0] == '-' and path.len == 1))) {
        if (n >= out.len) return null;
        out[n] = '\\';
        n += 1;
    }
    for (path) |ch| {
        if (std.mem.indexOfScalar(u8, special, ch) != null) {
            if (n >= out.len) return null;
            out[n] = '\\';
            n += 1;
        }
        if (n >= out.len) return null;
        out[n] = ch;
        n += 1;
    }
    return out[0..n];
}

test "a drop inserts the path only onto a command line" {
    try std.testing.expect(dropInsertsPath("cmdline_normal", false, false));
    try std.testing.expect(!dropInsertsPath("cmdline_normal", true, false));
    try std.testing.expect(dropInsertsPath("normal", true, true));
    try std.testing.expect(!dropInsertsPath("normal", false, false));
    try std.testing.expect(!dropInsertsPath("", false, false));
}

test "a cmdline path is escaped as fnameescape escapes it" {
    var buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings("a\\*b\\ c\\?.txt", escapePathForCmdline(&buf, "a*b c?.txt", false).?);
    try std.testing.expectEqualStrings(
        "\\%\\#\\|\\\"\\'\\[\\{\\$\\`\\!\\<\\\\\\\t\\\n",
        escapePathForCmdline(&buf, "%#|\"'[{$`!<\\\t\n", false).?,
    );
    // `]` and `}` are not special; `>`, `+` and a lone `-` only lead.
    try std.testing.expectEqualStrings("a]}>+-", escapePathForCmdline(&buf, "a]}>+-", false).?);
    try std.testing.expectEqualStrings("\\+x", escapePathForCmdline(&buf, "+x", false).?);
    try std.testing.expectEqualStrings("\\>x", escapePathForCmdline(&buf, ">x", false).?);
    try std.testing.expectEqualStrings("\\-", escapePathForCmdline(&buf, "-", false).?);
    try std.testing.expectEqualStrings("-x", escapePathForCmdline(&buf, "-x", false).?);
    try std.testing.expectEqualStrings("", escapePathForCmdline(&buf, "", false).?);
}

test "a Windows server keeps backslashes, dollars and the isfname brackets" {
    var buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings(
        "C:\\Users\\me\\[a]\\ $b\\*!.txt",
        escapePathForCmdline(&buf, "C:\\Users\\me\\[a] $b*!.txt", true).?,
    );
}

test "a cmdline path that does not fit is refused, not cut" {
    var buf: [3]u8 = undefined;
    try std.testing.expect(escapePathForCmdline(&buf, "a b", false) == null);
    try std.testing.expectEqualStrings("a\\ ", escapePathForCmdline(&buf, "a ", false).?);
}

// ---------------------------------------------------------------------------
// Custom shaders

/// Whether a Shadertoy-style shader reads a uniform that changes every frame,
/// so its surface has to keep drawing while nothing else changes. Whole words
/// only. iResolution, iSampleRate and iChannel0 are constant, and iMouse is
/// not implemented (always zero), so none of them animates.
pub fn shaderNeedsAnimation(source: []const u8) bool {
    const tokens = [_][]const u8{ "iTime", "iTimeDelta", "iFrame", "iFrameRate", "iDate" };
    for (tokens) |tok| {
        var search: usize = 0;
        while (std.mem.indexOfPos(u8, source, search, tok)) |pos| {
            const before_ok = pos == 0 or !isWordPart(source[pos - 1]);
            const after_idx = pos + tok.len;
            const after_ok = after_idx >= source.len or !isWordPart(source[after_idx]);
            if (before_ok and after_ok) return true;
            search = after_idx;
        }
    }
    return false;
}

fn isWordPart(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '_';
}

test "a shader animates when it reads a per-frame uniform as a whole word" {
    try std.testing.expect(shaderNeedsAnimation("fragColor = vec4(sin(iTime));"));
    try std.testing.expect(shaderNeedsAnimation("float f = float(iFrame);"));
    try std.testing.expect(shaderNeedsAnimation("x = iTimeDelta;"));
    try std.testing.expect(!shaderNeedsAnimation("vec2 uv = fragCoord / iResolution.xy;"));
    try std.testing.expect(!shaderNeedsAnimation("vec4 m = iMouse;"));
    try std.testing.expect(!shaderNeedsAnimation("float myiTime = 1.0; float iTimes = 2.0;"));
}

// ---------------------------------------------------------------------------
// Message floats

pub const Rect = extern struct { left: i32, top: i32, right: i32, bottom: i32 };
pub const Point = extern struct { x: i32, y: i32 };

/// Where msg_show or msg_history puts its top-left corner: `margin` in from
/// the target's top-right corner, and msg_show `gap` below msg_history when
/// that is up (`history_bottom`, screen coordinates, y down). The core
/// registers these grids with the "top-right" sentinel position, so x follows
/// the window's current width and never a previous position: reusing that made
/// a short message keep a long one's left edge. Margins are the caller's
/// pixels, already scaled.
pub fn msgFloatTopRight(target: Rect, window_w: i32, history_bottom: ?i32, margin: i32, gap: i32) Point {
    return .{
        .x = target.right - window_w - margin,
        .y = if (history_bottom) |bottom| bottom + gap else target.top + margin,
    };
}

test "msg_show sits in from the top-right corner, below msg_history when shown" {
    const target: Rect = .{ .left = 0, .top = 100, .right = 800, .bottom = 600 };
    try std.testing.expectEqual(Point{ .x = 800 - 200 - 15, .y = 115 }, msgFloatTopRight(target, 200, null, 15, 6));
    try std.testing.expectEqual(Point{ .x = 800 - 200 - 15, .y = 300 + 6 }, msgFloatTopRight(target, 200, 300, 15, 6));
}

const msg_test_screen: Rect = .{ .left = 0, .top = 0, .right = 1920, .bottom = 1080 };

test "a message float's right edge is invariant across every width" {
    // The regression: a resize in place (SWP_NOMOVE) kept the previous long
    // message's left edge. The right edge is the contract; the left edge must
    // move whenever the width does.
    const widths = [_]i32{ 1, 80, 400, 401, 1200, 1910 };
    var previous_x: ?i32 = null;
    for (widths) |w| {
        const p = msgFloatTopRight(msg_test_screen, w, null, 10, 4);
        try std.testing.expectEqual(msg_test_screen.right - 10, p.x + w);
        try std.testing.expectEqual(@as(i32, 10), p.y);
        if (previous_x) |prev| try std.testing.expect(p.x != prev);
        previous_x = p.x;
    }
}

test "a short message after a long one is not left where the long one was" {
    const long = msgFloatTopRight(msg_test_screen, 900, null, 10, 4);
    const short = msgFloatTopRight(msg_test_screen, 120, null, 10, 4);
    try std.testing.expect(short.x > long.x);
    try std.testing.expectEqual(long.x + 900, short.x + 120);
}

test "msg_show stacks below msg_history without changing its right edge" {
    const history = msgFloatTopRight(msg_test_screen, 600, null, 10, 4);
    const history_bottom = history.y + 300;
    const show = msgFloatTopRight(msg_test_screen, 240, history_bottom, 10, 4);
    try std.testing.expectEqual(history_bottom + 4, show.y);
    try std.testing.expectEqual(msg_test_screen.right - 10, show.x + 240);
}

test "message placement follows a target rect off the screen origin" {
    // msg_pos = window/grid hands over the cursor window's rect in screen
    // coordinates, offset on both axes.
    const windowed: Rect = .{ .left = 300, .top = 150, .right = 1400, .bottom = 900 };
    try std.testing.expectEqual(Point{ .x = 1400 - 500 - 10, .y = 160 }, msgFloatTopRight(windowed, 500, null, 10, 4));
}

test "a message float wider than the target overhangs the left, never the right" {
    const p = msgFloatTopRight(msg_test_screen, 2400, null, 10, 4);
    try std.testing.expectEqual(msg_test_screen.right - 10, p.x + 2400);
    try std.testing.expect(p.x < msg_test_screen.left);
}

// ---------------------------------------------------------------------------
// Cmdline

/// Where an open cmdline window goes when its size changes, screen
/// coordinates with y down: it keeps its centre, so a cmdline growing as you
/// type widens both ways, and once it takes 90% of the area's width it is
/// centred. Always kept inside `area`. Windows grew it rightward from its
/// top-left, past the monitor edge.
pub fn cmdlineOrigin(old: Rect, new_w: i32, new_h: i32, area: Rect) Point {
    const area_w = area.right - area.left;
    var x = old.left + @divTrunc(old.right - old.left, 2) - @divTrunc(new_w, 2);
    var y = old.top + @divTrunc(old.bottom - old.top, 2) - @divTrunc(new_h, 2);
    if (@as(i64, new_w) * 10 >= @as(i64, area_w) * 9) x = area.left + @divTrunc(area_w - new_w, 2);
    x = @max(area.left, @min(x, area.right - new_w));
    y = @max(area.top, @min(y, area.bottom - new_h));
    return .{ .x = x, .y = y };
}

test "a growing cmdline keeps its centre, and stays on the area" {
    const area: Rect = .{ .left = 0, .top = 0, .right = 1000, .bottom = 900 };
    const old: Rect = .{ .left = 300, .top = 280, .right = 700, .bottom = 320 };
    try std.testing.expectEqual(Point{ .x = 250, .y = 280 }, cmdlineOrigin(old, 500, 40, area));
    // Near the right edge: clamped instead of running off it.
    const right: Rect = .{ .left = 800, .top = 280, .right = 1000, .bottom = 320 };
    try std.testing.expectEqual(Point{ .x = 600, .y = 280 }, cmdlineOrigin(right, 400, 40, area));
}

test "a cmdline taking 90% of the width is centred" {
    const area: Rect = .{ .left = 100, .top = 0, .right = 1100, .bottom = 900 };
    const old: Rect = .{ .left = 150, .top = 280, .right = 550, .bottom = 320 };
    try std.testing.expectEqual(Point{ .x = 150, .y = 280 }, cmdlineOrigin(old, 900, 40, area));
}

pub const CmdlineCols = extern struct { screen_cols: u32, default_cols: u32 };

/// The cmdline's width budget in cells, from widths in the frontend's pixels.
/// `screen_cols` caps its growth: the work area less the chrome beside the
/// grid and `margin_px`, at least 40. `default_cols` is its width before the
/// content needs more: the cmdline window spans 95% of the main window, chrome
/// included, at least 20. A zero width gives 0, "not supplied" to the core.
pub fn cmdlineCols(work_w_px: u32, main_w_px: u32, chrome_px: u32, margin_px: u32, cell_w_px: u32) CmdlineCols {
    const cw = @max(1, cell_w_px);
    const target_w_px: u32 = @intCast(@as(u64, main_w_px) * 95 / 100);
    return .{
        .screen_cols = if (work_w_px == 0) 0 else @max(40, (work_w_px -| (chrome_px +| margin_px)) / cw),
        .default_cols = if (main_w_px == 0) 0 else @max(20, (target_w_px -| chrome_px) / cw),
    };
}

test "the cmdline grows to the work area less chrome and margin, from 95% of the main window" {
    // 2000 - 64 - 40 = 1896 / 8 = 237; 1000 * 95% = 950 - 64 = 886 / 8 = 110.
    try std.testing.expectEqual(CmdlineCols{ .screen_cols = 237, .default_cols = 110 }, cmdlineCols(2000, 1000, 64, 40, 8));
}

test "a narrow screen or window still gives the cmdline 40 and 20 cells" {
    try std.testing.expectEqual(CmdlineCols{ .screen_cols = 40, .default_cols = 20 }, cmdlineCols(50, 50, 64, 40, 8));
    try std.testing.expectEqual(CmdlineCols{ .screen_cols = 0, .default_cols = 0 }, cmdlineCols(0, 0, 64, 40, 8));
}

// ---------------------------------------------------------------------------
// External window placement memory

pub const SavedOrigin = extern struct { grid_id: i64, x: f64, y: f64, generation: u64 };

pub const Placement = struct {
    kind: enum(u8) { pending, saved },
    x: f64,
    y: f64,
};

/// Where the next external window goes, in the caller's screen units: the
/// drop point of a tab drag (`pending`, good for 500 ms) beats the origin the
/// grid's window had when it closed (`saved`), which is kept only for the
/// session that created it: grid ids restart per server. Holds 100 saved
/// origins; a new one past that evicts the smallest grid id.
pub const PlacementMemory = extern struct {
    pub const cap = 100;
    pub const pending_timeout_ms: i64 = 500;

    saved: [cap + 1]SavedOrigin = undefined,
    saved_len: usize = 0,
    pending_x: f64 = 0,
    pending_y: f64 = 0,
    pending_set_ms: i64 = 0,
    has_pending: bool = false,

    pub fn setPending(self: *PlacementMemory, x: f64, y: f64, now_ms: i64) void {
        self.pending_x = x;
        self.pending_y = y;
        self.pending_set_ms = now_ms;
        self.has_pending = true;
    }

    /// The window of `grid_id`, created under `generation`, closed at (x, y).
    pub fn save(self: *PlacementMemory, grid_id: i64, x: f64, y: f64, generation: u64, current_generation: u64) void {
        if (generation != current_generation) {
            self.forget(grid_id);
            return;
        }
        if (self.find(grid_id)) |i| {
            self.saved[i] = .{ .grid_id = grid_id, .x = x, .y = y, .generation = generation };
            return;
        }
        if (self.saved_len > cap) {
            var min_i: usize = 0;
            for (self.saved[0..self.saved_len], 0..) |e, i| {
                if (e.grid_id < self.saved[min_i].grid_id) min_i = i;
            }
            self.removeAt(min_i);
        }
        self.saved[self.saved_len] = .{ .grid_id = grid_id, .x = x, .y = y, .generation = generation };
        self.saved_len += 1;
    }

    /// The placement for a window of `grid_id` opening under `generation`, or
    /// null for none. A pending drop point is consumed; a saved origin stays
    /// for the next reopen; one from another session is dropped.
    pub fn take(self: *PlacementMemory, grid_id: i64, generation: u64, now_ms: i64) ?Placement {
        if (self.has_pending) {
            self.has_pending = false;
            if (now_ms - self.pending_set_ms < pending_timeout_ms) {
                return .{ .kind = .pending, .x = self.pending_x, .y = self.pending_y };
            }
        }
        const i = self.find(grid_id) orelse return null;
        const e = self.saved[i];
        if (e.generation != generation) {
            self.removeAt(i);
            return null;
        }
        return .{ .kind = .saved, .x = e.x, .y = e.y };
    }

    fn forget(self: *PlacementMemory, grid_id: i64) void {
        if (self.find(grid_id)) |i| self.removeAt(i);
    }

    fn find(self: *const PlacementMemory, grid_id: i64) ?usize {
        for (self.saved[0..self.saved_len], 0..) |e, i| {
            if (e.grid_id == grid_id) return i;
        }
        return null;
    }

    fn removeAt(self: *PlacementMemory, i: usize) void {
        self.saved_len -= 1;
        self.saved[i] = self.saved[self.saved_len];
    }
};

test "a drop point beats a saved origin and is used once, within 500 ms" {
    var m: PlacementMemory = .{};
    m.save(5, 10, 20, 1, 1);
    m.setPending(300, 400, 1000);
    const p = m.take(5, 1, 1400).?;
    try std.testing.expectEqual(@as(f64, 300), p.x);
    try std.testing.expect(p.kind == .pending);
    // Consumed: the saved origin is what remains.
    const s = m.take(5, 1, 1401).?;
    try std.testing.expect(s.kind == .saved);
    try std.testing.expectEqual(@as(f64, 10), s.x);
    try std.testing.expectEqual(@as(f64, 20), s.y);
    // A stale drop point is dropped, not used.
    m.setPending(1, 2, 2000);
    try std.testing.expect(m.take(7, 1, 2500) == null);
    try std.testing.expect(!m.has_pending);
}

test "a saved origin belongs to the session that created it" {
    var m: PlacementMemory = .{};
    // Closed after a restart: nothing kept.
    m.save(3, 1, 1, 1, 2);
    try std.testing.expect(m.take(3, 2, 0) == null);
    // Kept, then asked for under a later generation: dropped.
    m.save(3, 1, 1, 2, 2);
    try std.testing.expect(m.take(3, 2, 0) != null);
    try std.testing.expect(m.take(3, 3, 0) == null);
    try std.testing.expectEqual(@as(usize, 0), m.saved_len);
}

test "the 101st new grid evicts the smallest grid id; a re-save evicts nothing" {
    var m: PlacementMemory = .{};
    var g: i64 = 1;
    while (g <= 101) : (g += 1) m.save(g, @floatFromInt(g), 0, 1, 1);
    try std.testing.expectEqual(@as(usize, 101), m.saved_len);
    m.save(50, 0, 0, 1, 1);
    try std.testing.expectEqual(@as(usize, 101), m.saved_len);
    m.save(102, 0, 0, 1, 1);
    try std.testing.expectEqual(@as(usize, 101), m.saved_len);
    try std.testing.expect(m.take(1, 1, 0) == null);
    try std.testing.expectEqual(@as(f64, 2), m.take(2, 1, 0).?.x);
}

// ---------------------------------------------------------------------------
// Cursor blink

/// A surface's cursor blink cadence, as the frontends' timers drive it.
/// `blinkwait`/`blinkon`/`blinkoff` come from guicursor via mode_info_set.
/// Neovim sends 0 for any entry guicursor leaves out (cursor_shape.c clears
/// the table), and its default gives terminal mode blinkon/blinkoff with no
/// blinkwait, so a zero wait means "start blinking at once", not "never".
pub const Blink = extern struct {
    wait_ms: u32 = 0,
    on_ms: u32 = 0,
    off_ms: u32 = 0,
    /// 0 = not blinking, 1 = waiting out blinkwait, 2 = cycling.
    phase: u8 = 0,
    visible: bool = true,

    /// Whether these settings blink at all.
    pub fn blinks(on_ms: u32, off_ms: u32) bool {
        return on_ms > 0 and off_ms > 0;
    }

    /// (Re)start with these settings, the cursor shown. Returns the delay to
    /// the first tick, or 0 for no timer (the cursor stays shown).
    pub fn start(self: *Blink, wait_ms: u32, on_ms: u32, off_ms: u32) u32 {
        self.wait_ms = wait_ms;
        self.on_ms = on_ms;
        self.off_ms = off_ms;
        self.visible = true;
        if (!blinks(on_ms, off_ms)) {
            self.phase = 0;
            return 0;
        }
        if (wait_ms > 0) {
            self.phase = 1;
            return wait_ms;
        }
        self.phase = 2;
        return on_ms;
    }

    /// The timer fired. Returns the delay to the next tick, or 0 for none.
    pub fn tick(self: *Blink) u32 {
        switch (self.phase) {
            1 => {
                self.phase = 2;
                self.visible = true;
                return self.on_ms;
            },
            2 => {
                self.visible = !self.visible;
                return if (self.visible) self.on_ms else self.off_ms;
            },
            else => return 0,
        }
    }

    /// Stop with the cursor shown, keeping the settings.
    pub fn stop(self: *Blink) void {
        self.phase = 0;
        self.visible = true;
    }

    pub fn sameSettings(self: *const Blink, wait_ms: u32, on_ms: u32, off_ms: u32) bool {
        return self.wait_ms == wait_ms and self.on_ms == on_ms and self.off_ms == off_ms;
    }
};

test "blinkwait, then on and off in turn" {
    var b: Blink = .{};
    try std.testing.expectEqual(@as(u32, 700), b.start(700, 400, 250));
    try std.testing.expect(b.visible);
    try std.testing.expectEqual(@as(u32, 400), b.tick());
    try std.testing.expect(b.visible);
    try std.testing.expectEqual(@as(u32, 250), b.tick());
    try std.testing.expect(!b.visible);
    try std.testing.expectEqual(@as(u32, 400), b.tick());
    try std.testing.expect(b.visible);
}

test "a zero blinkwait cycles at once; a zero on or off never blinks" {
    var b: Blink = .{};
    try std.testing.expectEqual(@as(u32, 500), b.start(0, 500, 500));
    try std.testing.expectEqual(@as(u32, 500), b.tick());
    try std.testing.expect(!b.visible);
    try std.testing.expectEqual(@as(u32, 0), b.start(700, 0, 250));
    try std.testing.expectEqual(@as(u32, 0), b.tick());
    try std.testing.expect(b.visible);
}

test "stopping leaves the cursor shown" {
    var b: Blink = .{};
    _ = b.start(0, 400, 250);
    _ = b.tick();
    try std.testing.expect(!b.visible);
    b.stop();
    try std.testing.expect(b.visible);
    try std.testing.expectEqual(@as(u32, 0), b.tick());
}
