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
/// pixels, already scaled. macOS calls this; Windows still has the same body
/// in windows/ui/msg_float_layout.zig, whose standalone test module
/// (build.zig) cannot import the core.
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
