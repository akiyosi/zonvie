//! What the frontend-drawn ext UI shows: the minis (showmode, showcmd,
//! ruler, mini-routed messages), a confirm prompt, a toast, OS
//! notifications and the ext tabline. Core callbacks write it under App.mu; the GTK thread copies it
//! out and updates the widgets (ui_widgets.zig). Fixed buffers, so a
//! callback never allocates.

const std = @import("std");
const core = @import("zonvie_core");
const rules = core.frontend_rules;
const msg_stack = core.msg_stack;

pub fn TextBuf(comptime cap: usize) type {
    return struct {
        const Self = @This();
        bytes: [cap]u8 = undefined,
        len: usize = 0,

        pub fn text(self: *const Self) []const u8 {
            return self.bytes[0..self.len];
        }

        pub fn clear(self: *Self) void {
            self.len = 0;
        }

        /// Appends what fits, cut at a UTF-8 boundary and ended with '…'.
        pub fn append(self: *Self, s: []const u8) void {
            self.len += rules.copyUtf8Truncated(self.bytes[self.len..], s);
        }

        pub fn appendChunks(self: *Self, chunks: []const core.MsgChunk) void {
            for (chunks) |c| if (c.text_len != 0) self.append(c.text[0..c.text_len]);
        }
    };
}

pub const Mini = enum(u2) { showmode, showcmd, ruler, message };

pub const ToastMsg = struct {
    text: TextBuf(1024) = .{},
    /// zonvie_core_msg_kind_tone.
    tone: u8 = 0,
};

pub const tab_cap = 32;
pub const Tab = struct {
    handle: i64 = 0,
    name: TextBuf(128) = .{},
};

/// An agent completion to announce (on_agent_status with bit 7).
pub const Completion = struct {
    title: TextBuf(128) = .{},
    /// It stopped for input rather than finishing.
    waiting: bool = false,
};

pub const Agent = struct { handle: i64 = 0, state: u8 = 0 };

pub const UiState = struct {
    minis: [4]TextBuf(256) = @splat(.{}),
    /// A prompt Neovim blocks on, shown until the next message or a clear.
    confirm: TextBuf(4096) = .{},
    /// The messages the toast shows together, oldest first (msg_stack).
    toast: [msg_stack.max_messages]ToastMsg = @splat(.{}),
    toast_count: usize = 0,
    toast_timeout_ms: u32 = 0,
    /// Bumped per toast, so a timer for an older one does not hide it.
    toast_seq: u32 = 0,
    /// The message mini's auto-hide, as the toast's.
    mini_timeout_ms: u32 = 0,
    mini_seq: u32 = 0,
    /// A message for the "notification" view, not yet handed to the OS;
    /// the GTK thread sends it and clears `notice_pending`.
    notice: TextBuf(1024) = .{},
    notice_pending: bool = false,
    /// showmode, showcmd and ruler routed to ext_float, by Mini: state,
    /// not a log, so each keeps its latest text under the toast and never
    /// times out (as windows/window.zig status_messages).
    float_status: [3]TextBuf(256) = @splat(.{}),
    tabline_visible: bool = false,
    curtab: i64 = 0,
    tabs: [tab_cap]Tab = @splat(.{}),
    tab_count: usize = 0,
    /// AI-agent state by tab handle, `state & 0x7f`; none for 0.
    agents: [tab_cap]Agent = @splat(.{}),
    agent_count: usize = 0,
    /// Completions not yet announced; the GTK thread drains them.
    done: [8]Completion = @splat(.{}),
    done_count: usize = 0,

    /// on_agent_status. Bit 7 asks for the OS notification; `announce` is
    /// [tabline] agent_notification.
    pub fn agentStatus(self: *UiState, handle: i64, state: u8, title: []const u8, announce: bool) void {
        const base = state & 0x7f;
        if (announce and state & 0x80 != 0 and self.done_count < self.done.len) {
            const d = &self.done[self.done_count];
            d.title.clear();
            d.title.append(title);
            d.waiting = base == 4;
            self.done_count += 1;
        }
        for (self.agents[0..self.agent_count], 0..) |*a, i| {
            if (a.handle != handle) continue;
            if (base == 0) {
                self.agents[i] = self.agents[self.agent_count - 1];
                self.agent_count -= 1;
            } else a.state = base;
            return;
        }
        if (base == 0 or self.agent_count == self.agents.len) return;
        self.agents[self.agent_count] = .{ .handle = handle, .state = base };
        self.agent_count += 1;
    }

    pub fn agentState(self: *const UiState, handle: i64) u8 {
        for (self.agents[0..self.agent_count]) |a| if (a.handle == handle) return a.state;
        return 0;
    }

    pub fn anyWorking(self: *const UiState) bool {
        for (self.agents[0..self.agent_count]) |a| if (a.state == 2 or a.state == 3) return true;
        return false;
    }

    /// A mini's text from `chunks`, clamped as every frontend clamps it.
    fn setMini(self: *UiState, which: Mini, chunks: []const core.MsgChunk) void {
        var raw: TextBuf(4096) = .{};
        raw.appendChunks(chunks);
        const m = &self.minis[@intFromEnum(which)];
        m.len = rules.clampMiniContent(&m.bytes, raw.text());
    }

    /// on_msg_show for a view this frontend draws. `kind` picks the confirm
    /// box. The toast stacks its messages by the core's rule (msg_stack).
    pub fn msgShow(self: *UiState, view: core.zonvie_msg_view_type, kind: []const u8, chunks: []const core.MsgChunk, replace_last: bool, append: bool, timeout_ms: u32) void {
        switch (view) {
            .none, .split => {},
            .mini => {
                self.setMini(.message, chunks);
                self.mini_timeout_ms = timeout_ms;
                self.mini_seq +%= 1;
            },
            .confirm => {
                self.confirm.clear();
                self.confirm.appendChunks(chunks);
            },
            .notification => {
                // As macOS and Windows: an OS notification titled "Neovim".
                // :echon extends one not yet sent.
                if (!append or !self.notice_pending) self.notice.clear();
                self.notice.appendChunks(chunks);
                self.notice_pending = self.notice.len != 0;
            },
            .ext_float => {
                // A new message replaces a confirm that is no longer asked.
                self.confirm.clear();
                const plan = msg_stack.plan(self.toast_count, replace_last, append);
                // Only a push evicts, so the room it needs is made first.
                if (plan.evict_oldest != 0) {
                    const n = self.toast_count - plan.evict_oldest;
                    std.mem.copyForwards(ToastMsg, self.toast[0..n], self.toast[plan.evict_oldest..self.toast_count]);
                    self.toast_count = n;
                }
                if (plan.action == .push) {
                    self.toast[self.toast_count] = .{};
                    self.toast_count += 1;
                }
                const last = &self.toast[self.toast_count - 1];
                if (plan.action == .replace_last) last.text.clear();
                last.text.appendChunks(chunks);
                // An appended piece keeps the tone of the message it joins.
                if (plan.action != .append_to_last) last.tone = core.zonvie_core_msg_kind_tone(kind.ptr, kind.len);
                self.toast_timeout_ms = timeout_ms;
                self.toast_seq +%= 1;
            },
        }
    }

    /// on_msg_clear: the core resends the statuses it still holds.
    pub fn msgClear(self: *UiState) void {
        self.confirm.clear();
        self.toast_count = 0;
        self.toast_seq +%= 1;
        self.minis[@intFromEnum(Mini.message)].clear();
        self.mini_seq +%= 1;
        for (&self.float_status) |*f| f.clear();
    }

    /// showmode, showcmd or ruler, by the view its route picks, as Windows
    /// routes them: ext_float joins the toast, notification goes to the OS,
    /// anything else shows in its mini. An empty list hides it.
    pub fn status(self: *UiState, which: Mini, view: core.zonvie_msg_view_type, chunks: []const core.MsgChunk) void {
        switch (view) {
            .none => {},
            .ext_float => {
                const f = &self.float_status[@intFromEnum(which)];
                f.clear();
                f.appendChunks(chunks);
                self.minis[@intFromEnum(which)].clear();
            },
            .notification => {
                self.notice.clear();
                self.notice.appendChunks(chunks);
                self.notice_pending = self.notice.len != 0;
            },
            else => self.setMini(which, chunks),
        }
    }

    /// The tone of the toast's newest message; 0 when only statuses show.
    pub fn toastTone(self: *const UiState) u8 {
        return if (self.toast_count == 0) 0 else self.toast[self.toast_count - 1].tone;
    }

    /// The toast's text: the stacked messages, then each ext_float status,
    /// every one on a line of its own, cut to `buf`.
    pub fn toastText(self: *const UiState, buf: []u8) []const u8 {
        var n: usize = 0;
        const add = struct {
            fn f(b: []u8, len: *usize, line: []const u8) void {
                if (line.len == 0) return;
                if (len.* != 0 and len.* < b.len) {
                    b[len.*] = '\n';
                    len.* += 1;
                }
                len.* += rules.copyUtf8Truncated(b[len.*..], line);
            }
        }.f;
        for (self.toast[0..self.toast_count]) |*m| add(buf, &n, m.text.text());
        for (&self.float_status) |*f| add(buf, &n, f.text());
        return buf[0..n];
    }

    pub fn tabline(self: *UiState, curtab: i64, tabs: []const core.TabEntry) void {
        self.curtab = curtab;
        self.tab_count = @min(tabs.len, tab_cap);
        for (tabs[0..self.tab_count], self.tabs[0..self.tab_count]) |src, *dst| {
            dst.handle = src.tab_handle;
            dst.name.clear();
            dst.name.append(src.name[0..src.name_len]);
        }
        self.tabline_visible = self.tab_count > 0;
    }
};

/// The notification for completions drained together, as Windows words it.
/// The result lies in `buf`, in `done`, or is static:
/// one names its summary, several are counted, and "needs input" is never
/// reported as finished.
pub fn completionMessage(buf: []u8, done: []const Completion) []const u8 {
    if (done.len == 1) {
        // By pointer: a failure's title is returned as it lies in `done`.
        const d = &done[0];
        const label = if (d.waiting) "Needs input" else "Finished";
        const fallback = if (d.waiting) "AI agent needs input" else "AI agent finished";
        if (d.title.len == 0) return fallback;
        // A failure's title is its whole body (on_agent_status).
        if (!d.waiting and std.mem.startsWith(u8, d.title.text(), "Failed: ")) return d.title.text();
        return std.fmt.bufPrint(buf, "{s}: {s}", .{ label, d.title.text() }) catch fallback;
    }
    var waiting: usize = 0;
    for (done) |d| waiting += @intFromBool(d.waiting);
    if (waiting == done.len) return std.fmt.bufPrint(buf, "{d} AI agents need input", .{done.len}) catch "AI agents need input";
    if (waiting > 0) return std.fmt.bufPrint(buf, "{d} finished, {d} need input", .{ done.len - waiting, waiting }) catch "AI agents finished";
    return std.fmt.bufPrint(buf, "{d} AI agents finished", .{done.len}) catch "AI agents finished";
}

const testing = std.testing;

fn chunk(s: []const u8) core.MsgChunk {
    return .{ .hl_id = 0, .text = s.ptr, .text_len = s.len };
}

test "a text buffer cuts at a UTF-8 boundary and marks the cut" {
    var b: TextBuf(4) = .{};
    b.append("ab\xe3\x81\x82");
    try testing.expectEqualStrings("a\u{2026}", b.text());
}

test "the toast stacks messages; echon extends and replace_last replaces the last" {
    var s: UiState = .{};
    var buf: [64]u8 = undefined;
    s.msgShow(.ext_float, "emsg", &.{chunk("a")}, false, false, 4000);
    s.msgShow(.ext_float, "echo", &.{chunk("b")}, false, true, 4000);
    try testing.expectEqualStrings("ab", s.toastText(&buf));
    // The appended piece did not take the error's tone away.
    try testing.expectEqual(core.zonvie_core_msg_kind_tone("emsg", 4), s.toastTone());
    s.msgShow(.ext_float, "echo", &.{chunk("c")}, false, false, 4000);
    try testing.expectEqualStrings("ab\nc", s.toastText(&buf));
    s.msgShow(.ext_float, "echo", &.{chunk("d")}, true, false, 4000);
    try testing.expectEqualStrings("ab\nd", s.toastText(&buf));
    // Past the cap the oldest goes.
    for (0..4) |_| s.msgShow(.ext_float, "echo", &.{chunk("x")}, false, false, 4000);
    try testing.expectEqualStrings("d\nx\nx\nx\nx", s.toastText(&buf));
}

test "a mini message is clamped to ten lines and replaced, not extended" {
    var s: UiState = .{};
    s.msgShow(.mini, "echo", &.{chunk("1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12\n")}, false, false, 3000);
    const m = &s.minis[@intFromEnum(Mini.message)];
    try testing.expectEqualStrings("1\n2\n3\n4\n5\n6\n7\n8\n9\n\u{2026}(3 more lines)", m.text());
    try testing.expectEqual(@as(u32, 3000), s.mini_timeout_ms);
    const seq = s.mini_seq;
    s.msgShow(.mini, "echo", &.{chunk("b")}, false, true, 0);
    try testing.expectEqualStrings("b", m.text());
    try testing.expect(s.mini_seq != seq);
}

test "the notification view queues an OS notification, not a toast" {
    var s: UiState = .{};
    s.msgShow(.notification, "echo", &.{chunk("built")}, false, false, 0);
    s.msgShow(.notification, "echo", &.{chunk(" ok")}, false, true, 0);
    try testing.expect(s.notice_pending);
    try testing.expectEqualStrings("built ok", s.notice.text());
    try testing.expectEqual(@as(usize, 0), s.toast_count);
    // Once sent, the next message starts a new one even when appended.
    s.notice_pending = false;
    s.msgShow(.notification, "echo", &.{chunk("next")}, false, true, 0);
    try testing.expectEqualStrings("next", s.notice.text());
}

test "statuses follow their route: ext_float joins the toast, others their mini" {
    var s: UiState = .{};
    s.status(.showmode, .ext_float, &.{chunk("-- INSERT --")});
    try testing.expectEqual(@as(usize, 0), s.minis[@intFromEnum(Mini.showmode)].len);
    s.msgShow(.ext_float, "echo", &.{chunk("saved")}, false, false, 4000);
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("saved\n-- INSERT --", s.toastText(&buf));
    // The message times out; the status stays.
    s.toast_count = 0;
    try testing.expectEqualStrings("-- INSERT --", s.toastText(&buf));
    s.status(.showcmd, .mini, &.{chunk("2d")});
    try testing.expectEqualStrings("2d", s.minis[@intFromEnum(Mini.showcmd)].text());
    s.status(.ruler, .none, &.{chunk("1,1")});
    try testing.expectEqual(@as(usize, 0), s.minis[@intFromEnum(Mini.ruler)].len);
    s.msgClear();
    try testing.expectEqualStrings("", s.toastText(&buf));
}

test "a confirm stays until a clear or the next message" {
    var s: UiState = .{};
    s.msgShow(.confirm, "confirm", &.{chunk("Save? [Y]es")}, false, false, 0);
    try testing.expectEqualStrings("Save? [Y]es", s.confirm.text());
    s.msgClear();
    try testing.expectEqual(@as(usize, 0), s.confirm.len);
}

test "an empty status hides its mini and leaves the others" {
    var s: UiState = .{};
    s.status(.showmode, .mini, &.{chunk("-- INSERT --")});
    s.status(.ruler, .mini, &.{chunk("1,1")});
    s.status(.showmode, .mini, &.{});
    try testing.expectEqual(@as(usize, 0), s.minis[@intFromEnum(Mini.showmode)].len);
    try testing.expectEqualStrings("1,1", s.minis[@intFromEnum(Mini.ruler)].text());
}

test "the tabline keeps at most tab_cap tabs" {
    var s: UiState = .{};
    var entries: [tab_cap + 3]core.TabEntry = undefined;
    for (&entries, 0..) |*e, i| e.* = .{ .tab_handle = @intCast(i + 1), .name = "x", .name_len = 1, .chunks = null, .chunk_count = 0 };
    s.tabline(2, &entries);
    try testing.expectEqual(@as(usize, tab_cap), s.tab_count);
    try testing.expect(s.tabline_visible);
}

test "agent state per tab, and a flagged report queues one completion" {
    var s: UiState = .{};
    s.agentStatus(7, 2, "", true);
    try testing.expectEqual(@as(u8, 2), s.agentState(7));
    try testing.expect(s.anyWorking());
    s.agentStatus(7, 0x80 | 1, "fixed the bug", true);
    try testing.expectEqual(@as(u8, 1), s.agentState(7));
    try testing.expectEqual(@as(usize, 1), s.done_count);
    s.agentStatus(7, 0x80 | 4, "", false);
    try testing.expectEqual(@as(usize, 1), s.done_count);
    s.agentStatus(7, 0, "", true);
    try testing.expectEqual(@as(u8, 0), s.agentState(7));
    try testing.expect(!s.anyWorking());
}

test "a completion message names one and counts several" {
    var buf: [128]u8 = undefined;
    var one: [1]Completion = .{.{}};
    one[0].title.append("fixed the bug");
    try testing.expectEqualStrings("Finished: fixed the bug", completionMessage(&buf, &one));
    var failed = [_]Completion{.{}};
    failed[0].title.append("Failed: build broke");
    const body = completionMessage(&buf, &failed);
    try testing.expectEqualStrings("Failed: build broke", body);
    // In `failed` itself, not in a copy that died with the call.
    try testing.expectEqual(@intFromPtr(failed[0].title.text().ptr), @intFromPtr(body.ptr));
    one[0] = .{ .waiting = true };
    try testing.expectEqualStrings("AI agent needs input", completionMessage(&buf, &one));
    const mixed = [_]Completion{ .{}, .{ .waiting = true }, .{} };
    try testing.expectEqualStrings("2 finished, 1 need input", completionMessage(&buf, &mixed));
}
