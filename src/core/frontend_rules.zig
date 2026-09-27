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
