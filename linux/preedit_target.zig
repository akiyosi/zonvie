//! The clause an IME is converting, from the Pango attributes GTK hands
//! over with the preedit string (gtk_im_context_get_preedit_string). The
//! IMs mark it with a background (IBus reverses the target segment, Fcitx5
//! highlights it) over the underline that spans the whole composition.

const std = @import("std");
const gtk = @import("gtk_bindings.zig");

/// One run of the attribute iterator: bytes [start, end) of the preedit and
/// whether a background attribute covers them.
pub const Span = struct { start: usize, end: usize, background: bool };

/// The target clause as the byte range zonvie_core_set_preedit takes: the
/// first run carrying a background, merged with the runs right after it
/// that carry one too. {0, 0} (no clause) when none does.
/// Pre: spans ascend and do not overlap. Post: start <= end <= len.
pub fn target(spans: []const Span, len: usize) [2]usize {
    var out: ?[2]usize = null;
    for (spans) |s| {
        std.debug.assert(s.start <= s.end);
        if (!s.background) {
            if (out != null) break;
            continue;
        }
        const a = @min(s.start, len);
        const b = @min(s.end, len);
        if (out) |*o| {
            if (a != o[1]) break;
            o[1] = b;
        } else out = .{ a, b };
    }
    const r = out orelse return .{ 0, 0 };
    std.debug.assert(r[0] <= r[1] and r[1] <= len);
    return r;
}

const max_spans = 32;

/// target() over a Pango attribute list (null: no clause). Walks it with a
/// stack buffer: a composition has a handful of runs, and the rest past
/// `max_spans` cannot hold the first highlighted one any more.
pub fn fromPango(attrs: ?*anyopaque, len: usize) [2]usize {
    const list = attrs orelse return .{ 0, 0 };
    const it = gtk.pango_attr_list_get_iterator(list) orelse return .{ 0, 0 };
    defer gtk.pango_attr_iterator_destroy(it);
    var spans: [max_spans]Span = undefined;
    var n: usize = 0;
    while (n < max_spans) {
        var start: c_int = 0;
        var end: c_int = 0;
        gtk.pango_attr_iterator_range(it, &start, &end);
        // The last run ends at G_MAXINT.
        const s: usize = @intCast(@max(0, start));
        const e: usize = if (end < 0) len else @min(len, @as(usize, @intCast(end)));
        if (s >= len) break;
        spans[n] = .{ .start = s, .end = @max(s, e), .background = gtk.pango_attr_iterator_get(it, gtk.PANGO_ATTR_BACKGROUND) != null };
        n += 1;
        if (gtk.pango_attr_iterator_next(it) == 0) break;
    }
    return target(spans[0..n], len);
}

const testing = std.testing;

test "the highlighted run is the target clause" {
    const spans = [_]Span{
        .{ .start = 0, .end = 6, .background = false },
        .{ .start = 6, .end = 12, .background = true },
        .{ .start = 12, .end = 18, .background = false },
    };
    try testing.expectEqual([2]usize{ 6, 12 }, target(&spans, 18));
}

test "no highlight is no clause, and adjacent highlighted runs join" {
    try testing.expectEqual([2]usize{ 0, 0 }, target(&.{.{ .start = 0, .end = 9, .background = false }}, 9));
    try testing.expectEqual([2]usize{ 0, 0 }, target(&.{}, 9));
    const joined = [_]Span{
        .{ .start = 0, .end = 3, .background = true },
        .{ .start = 3, .end = 6, .background = true },
        .{ .start = 6, .end = 9, .background = false },
        .{ .start = 9, .end = 12, .background = true },
    };
    try testing.expectEqual([2]usize{ 0, 6 }, target(&joined, 12));
}

test "a run past the text is cut to it" {
    try testing.expectEqual([2]usize{ 3, 9 }, target(&.{.{ .start = 3, .end = 2147483647, .background = true }}, 9));
}
