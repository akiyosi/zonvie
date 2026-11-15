//! What a frontend's tab strip keeps of the ext tabline's names and
//! 'guitablabel' chunks, and how tall the strip grows for them. Pure and
//! fixed-size: tabline_update fills it without the heap.

const std = @import("std");
const TabChunk = @import("c_api.zig").TabChunk;
const utf8TruncLen = @import("frontend_rules.zig").utf8PrefixLen;

/// Basename of a path-like name: the part after the last '/' or '\\',
/// ignoring trailing separators as macOS's lastPathComponent does, so
/// `oil:///home/u/proj/` names `proj` rather than nothing. Returns the whole
/// string when there is no separator.
pub fn baseName(name: []const u8) []const u8 {
    var end = name.len;
    while (end > 1 and (name[end - 1] == '/' or name[end - 1] == '\\')) end -= 1;
    const trimmed = name[0..end];
    var last: usize = 0;
    for (trimmed, 0..) |ch, j| {
        if (ch == '/' or ch == '\\') last = j + 1;
    }
    return trimmed[last..];
}

/// What a tab entry keeps of the core's full name within `cap` bytes: the
/// first line of the label, then its basename, which is all any consumer shows,
/// cut on a UTF-8 boundary. The tab bar is single-line, so a 'guitablabel' that
/// spans lines keeps only its first. Cutting the full path first lost the file
/// name, or left a split character that drew no label at all.
pub fn tabNameForStorage(name: []const u8, cap: usize) []const u8 {
    const first_line = name[0 .. std.mem.indexOfScalar(u8, name, '\n') orelse name.len];
    const base = baseName(first_line);
    return base[0..utf8TruncLen(base, cap)];
}

test "tabNameForStorage keeps the basename of a name longer than the cap" {
    try std.testing.expectEqualStrings("file.zig", tabNameForStorage("/very/deep/path/file.zig", 12));
    // "あいう" is 9 bytes; a cap of 7 must not split the third character.
    try std.testing.expectEqualStrings("あい", tabNameForStorage("/d/あいう", 7));
}

test "tab name storage keeps only the first line of a multi-line label" {
    try std.testing.expectEqualStrings("a", tabNameForStorage("a\nb", 255));
    try std.testing.expectEqualStrings("a", tabNameForStorage("a", 255));
}

test "baseName ignores trailing separators" {
    try std.testing.expectEqualStrings("proj", baseName("oil:///home/u/proj/"));
    try std.testing.expectEqualStrings("a.zig", baseName("src\\a.zig"));
    try std.testing.expectEqualStrings("name", baseName("name"));
}

/// What the titlebar tab bar keeps of a label's 'guitablabel' chunks: its
/// first MAX_LINES lines, each cut to LINE_BYTES on a UTF-8 boundary, in at
/// most MAX_RUNS styled runs. Fixed size: tabline_update fills it without
/// the heap.
pub const TabLabel = struct {
    pub const MAX_LINES: u8 = 4;
    pub const LINE_BYTES: usize = 128;
    pub const MAX_RUNS: usize = 24;

    /// One chunk's piece of one line. Chunk bg is not kept: it is never
    /// painted (Neovim combines each chunk over TabLine/TabLineSel).
    pub const Run = struct {
        line: u8,
        start: u16,
        len: u16,
        fg_rgb: u32,
        flags: u32, // ZONVIE_TAB_CHUNK_*
    };

    text: [MAX_LINES * LINE_BYTES]u8 = undefined,
    runs: [MAX_RUNS]Run = undefined,
    run_count: usize = 0,
    /// Lines of the label as sent, capped at MAX_LINES; empty lines and a
    /// trailing "\n" count. 0 when the label came without chunks: the tab
    /// draws its name.
    line_count: u8 = 0,

    pub fn runText(self: *const TabLabel, r: Run) []const u8 {
        return self.text[r.start..][0..r.len];
    }

    /// Replace the label with one tab's chunks. Text past a line's
    /// LINE_BYTES or past MAX_RUNS runs is cut; the line count is not.
    pub fn store(self: *TabLabel, chunks: []const TabChunk) void {
        self.run_count = 0;
        self.line_count = if (chunks.len == 0) 0 else 1;
        var text_len: usize = 0;
        var line_start: usize = 0;
        for (chunks) |ch| {
            var pieces = std.mem.splitScalar(u8, ch.text[0..ch.text_len], '\n');
            var first = true;
            while (pieces.next()) |piece| {
                if (!first) {
                    if (self.line_count == MAX_LINES) return;
                    self.line_count += 1;
                    line_start = text_len;
                }
                first = false;
                const n = utf8TruncLen(piece, LINE_BYTES - (text_len - line_start));
                if (n == 0 or self.run_count == MAX_RUNS) continue;
                @memcpy(self.text[text_len..][0..n], piece[0..n]);
                self.runs[self.run_count] = .{
                    .line = self.line_count - 1,
                    .start = @intCast(text_len),
                    .len = @intCast(n),
                    .fg_rgb = ch.fg_rgb,
                    .flags = ch.flags,
                };
                self.run_count += 1;
                text_len += n;
            }
        }
    }
};


/// The titlebar tab bar at `lines` label lines: the one-line bar grows down
/// a label line per extra line, so the caption-button band keeps `base_px`.
pub fn barHeightPx(base_px: c_int, line_px: c_int, lines: u8) c_int {
    return base_px + @as(c_int, @max(1, lines) - 1) * line_px;
}

fn testChunk(text: []const u8, flags: u32) TabChunk {
    return .{ .fg_rgb = 0x123456, .bg_rgb = 0, .flags = flags, .text = text.ptr, .text_len = text.len };
}

fn testLabelLines(chunks: []const TabChunk) u8 {
    var label: TabLabel = .{};
    label.store(chunks);
    return label.line_count;
}

test "tab label line count: empty lines and a trailing break count, no chunks is none" {
    try std.testing.expectEqual(@as(u8, 0), testLabelLines(&.{}));
    try std.testing.expectEqual(@as(u8, 1), testLabelLines(&.{testChunk("a", 0)}));
    try std.testing.expectEqual(@as(u8, 1), testLabelLines(&.{testChunk("", 0)}));
    try std.testing.expectEqual(@as(u8, 3), testLabelLines(&.{testChunk("a\nb\n", 0)}));
    try std.testing.expectEqual(@as(u8, 3), testLabelLines(&.{testChunk("a\n\nc", 0)}));
    try std.testing.expectEqual(@as(u8, 3), testLabelLines(&.{ testChunk("a\n", 0), testChunk("\n", 0), testChunk("c", 0) }));
    try std.testing.expectEqual(@as(u8, 4), testLabelLines(&.{testChunk("1\n2\n3\n4\n5\n6", 0)}));
}

test "tab label runs: a chunk broken by a break keeps its style on both lines" {
    var label: TabLabel = .{};
    label.store(&.{ testChunk("ab\ncd", 4), testChunk("e", 8) });
    try std.testing.expectEqual(@as(usize, 3), label.run_count);
    try std.testing.expectEqualStrings("ab", label.runText(label.runs[0]));
    try std.testing.expectEqual(@as(u8, 0), label.runs[0].line);
    try std.testing.expectEqualStrings("cd", label.runText(label.runs[1]));
    try std.testing.expectEqual(@as(u8, 1), label.runs[1].line);
    try std.testing.expectEqual(@as(u32, 4), label.runs[1].flags);
    try std.testing.expectEqualStrings("e", label.runText(label.runs[2]));
    try std.testing.expectEqual(@as(u8, 1), label.runs[2].line);
    try std.testing.expectEqual(@as(u32, 0x123456), label.runs[2].fg_rgb);
}

test "tab label storage cuts a long line on a UTF-8 boundary and keeps the next line" {
    // 43 three-byte characters: 129 bytes, one past a line's room.
    const long = "あ" ** 43;
    var label: TabLabel = .{};
    label.store(&.{ testChunk(long ++ "\nb", 0), testChunk(long, 0) });
    try std.testing.expectEqual(@as(u8, 2), label.line_count);
    try std.testing.expectEqual(@as(usize, 3), label.run_count);
    try std.testing.expectEqual(@as(u16, 126), label.runs[0].len);
    try std.testing.expect(std.unicode.utf8ValidateSlice(label.runText(label.runs[0])));
    try std.testing.expectEqualStrings("b", label.runText(label.runs[1]));
    // The second line's room is shared by its runs: "b" took one byte.
    try std.testing.expectEqual(@as(u16, 126), label.runs[2].len);
}

test "tab label storage drops runs past MAX_RUNS but keeps counting lines" {
    var chunks: [TabLabel.MAX_RUNS + 2]TabChunk = undefined;
    for (&chunks) |*ch| ch.* = testChunk("x", 0);
    chunks[chunks.len - 1] = testChunk("\ny", 0);
    var label: TabLabel = .{};
    label.store(&chunks);
    try std.testing.expectEqual(TabLabel.MAX_RUNS, label.run_count);
    try std.testing.expectEqual(@as(u8, 2), label.line_count);
}


test "titlebar bar height: one line is today's bar, each extra line adds a line height" {
    try std.testing.expectEqual(@as(c_int, 32), barHeightPx(32, 16, 1));
    try std.testing.expectEqual(@as(c_int, 32 + 2 * 16), barHeightPx(32, 16, 3));
    try std.testing.expectEqual(@as(c_int, 32), barHeightPx(32, 16, 0));
    try std.testing.expectEqual(@as(c_int, 48 + 3 * 24), barHeightPx(48, 24, 4));
}
