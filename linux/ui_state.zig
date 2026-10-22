//! What the frontend-drawn ext UI shows: the minis (showmode, showcmd,
//! ruler, mini-routed messages), a confirm prompt, a toast and the ext
//! tabline. Core callbacks write it under App.mu; the GTK thread copies it
//! out and updates the widgets (ui_widgets.zig). Fixed buffers, so a
//! callback never allocates.

const std = @import("std");
const core = @import("zonvie_core");
const rules = core.frontend_rules;

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

pub const tab_cap = 32;
pub const Tab = struct {
    handle: i64 = 0,
    name: TextBuf(128) = .{},
};

pub const UiState = struct {
    minis: [4]TextBuf(256) = @splat(.{}),
    /// A prompt Neovim blocks on, shown until the next message or a clear.
    confirm: TextBuf(4096) = .{},
    toast: TextBuf(4096) = .{},
    toast_tone: u8 = 0,
    toast_timeout_ms: u32 = 0,
    /// Bumped per toast, so a timer for an older one does not hide it.
    toast_seq: u32 = 0,
    tabline_visible: bool = false,
    curtab: i64 = 0,
    tabs: [tab_cap]Tab = @splat(.{}),
    tab_count: usize = 0,

    /// on_msg_show for a view this frontend draws. `kind` picks the confirm
    /// box; append (:echon) extends the text shown, anything else replaces it.
    pub fn msgShow(self: *UiState, view: core.zonvie_msg_view_type, kind: []const u8, chunks: []const core.MsgChunk, append: bool, timeout_ms: u32) void {
        switch (view) {
            .none, .split => {},
            .mini => {
                const m = &self.minis[@intFromEnum(Mini.message)];
                if (!append) m.clear();
                m.appendChunks(chunks);
            },
            .confirm => {
                self.confirm.clear();
                self.confirm.appendChunks(chunks);
            },
            .notification, .ext_float => {
                // A new message replaces a confirm that is no longer asked.
                self.confirm.clear();
                if (!append) self.toast.clear();
                self.toast.appendChunks(chunks);
                self.toast_tone = core.zonvie_core_msg_kind_tone(kind.ptr, kind.len);
                self.toast_timeout_ms = timeout_ms;
                self.toast_seq +%= 1;
            },
        }
    }

    /// on_msg_clear: the core resends the statuses it still holds.
    pub fn msgClear(self: *UiState) void {
        self.confirm.clear();
        self.toast.clear();
        self.toast_seq +%= 1;
        self.minis[@intFromEnum(Mini.message)].clear();
    }

    /// showmode, showcmd or ruler; an empty list hides that mini.
    pub fn status(self: *UiState, which: Mini, view: core.zonvie_msg_view_type, chunks: []const core.MsgChunk) void {
        if (view == .none) return;
        const m = &self.minis[@intFromEnum(which)];
        m.clear();
        m.appendChunks(chunks);
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

const testing = std.testing;

fn chunk(s: []const u8) core.MsgChunk {
    return .{ .hl_id = 0, .text = s.ptr, .text_len = s.len };
}

test "a text buffer cuts at a UTF-8 boundary and marks the cut" {
    var b: TextBuf(4) = .{};
    b.append("ab\xe3\x81\x82");
    try testing.expectEqualStrings("a\u{2026}", b.text());
}

test "echon appends to the toast, a new message replaces it" {
    var s: UiState = .{};
    s.msgShow(.ext_float, "echo", &.{chunk("a")}, false, 4000);
    s.msgShow(.ext_float, "echo", &.{chunk("b")}, true, 4000);
    try testing.expectEqualStrings("ab", s.toast.text());
    s.msgShow(.ext_float, "echo", &.{chunk("c")}, false, 4000);
    try testing.expectEqualStrings("c", s.toast.text());
}

test "a confirm stays until a clear or the next message" {
    var s: UiState = .{};
    s.msgShow(.confirm, "confirm", &.{chunk("Save? [Y]es")}, false, 0);
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
    for (&entries, 0..) |*e, i| e.* = .{ .tab_handle = @intCast(i + 1), .name = "x", .name_len = 1 };
    s.tabline(2, &entries);
    try testing.expectEqual(@as(usize, tab_cap), s.tab_count);
    try testing.expect(s.tabline_visible);
}
