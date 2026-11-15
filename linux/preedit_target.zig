//! The clause an IME is converting, from the Pango attributes GTK hands
//! over with the preedit string (gtk_im_context_get_preedit_string). The
//! IMs mark it with a background (IBus reverses the target segment, Fcitx5
//! highlights it) over the underline that spans the whole composition;
//! GTK's own Wayland text-input module marks the range between the preedit
//! cursors bold instead, and some IMs mark it with a double underline.

const std = @import("std");
const gtk = @import("gtk_bindings.zig");

/// One run of the attribute iterator: bytes [start, end) of the preedit and
/// which clause marks cover them: a background, a bold (or heavier) weight,
/// a double underline.
pub const Span = struct { start: usize, end: usize, background: bool, bold: bool = false, double_underline: bool = false };

const Mark = enum { background, bold, double_underline };

fn has(s: Span, m: Mark) bool {
    return switch (m) {
        .background => s.background,
        .bold => s.bold,
        .double_underline => s.double_underline,
    };
}

fn anyHas(spans: []const Span, m: Mark) bool {
    for (spans) |s| if (has(s, m)) return true;
    return false;
}

/// The target clause as the byte range zonvie_core_set_preedit takes: the
/// first run carrying the mark, merged with the runs right after it that
/// carry it too. The mark is a background when any run has one, else a
/// bold weight, else a double underline, so an IM that highlights the
/// clause and emboldens or underlines the whole composition is read by its
/// highlight. {0, 0} (no clause) when no run is marked.
/// Pre: spans ascend and do not overlap. Post: start <= end <= len.
pub fn target(spans: []const Span, len: usize) [2]usize {
    const mark: Mark = for ([_]Mark{ .background, .bold, .double_underline }) |m| {
        if (anyHas(spans, m)) break m;
    } else return .{ 0, 0 };
    var out: ?[2]usize = null;
    for (spans) |s| {
        std.debug.assert(s.start <= s.end);
        if (!has(s, mark)) {
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
        spans[n] = .{
            .start = s,
            .end = @max(s, e),
            .background = gtk.pango_attr_iterator_get(it, gtk.PANGO_ATTR_BACKGROUND) != null,
            .bold = if (intAttr(it, gtk.PANGO_ATTR_WEIGHT)) |w| w >= gtk.PANGO_WEIGHT_BOLD else false,
            .double_underline = if (intAttr(it, gtk.PANGO_ATTR_UNDERLINE)) |u| u == gtk.PANGO_UNDERLINE_DOUBLE or u == gtk.PANGO_UNDERLINE_DOUBLE_LINE else false,
        };
        n += 1;
        if (gtk.pango_attr_iterator_next(it) == 0) break;
    }
    return target(spans[0..n], len);
}

/// The value of the PangoAttrInt of `attr_type` over the iterator's run.
fn intAttr(it: *anyopaque, attr_type: c_int) ?c_int {
    const a = gtk.pango_attr_iterator_get(it, attr_type) orelse return null;
    const int: *const gtk.PangoAttrInt = @ptrCast(@alignCast(a));
    return int.value;
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

test "without a background the bold run is the clause, then a double underline" {
    // GTK's Wayland module: the whole composition underlined, the clause bold.
    const bold = [_]Span{
        .{ .start = 0, .end = 3, .background = false },
        .{ .start = 3, .end = 9, .background = false, .bold = true },
        .{ .start = 9, .end = 12, .background = false },
    };
    try testing.expectEqual([2]usize{ 3, 9 }, target(&bold, 12));
    const double = [_]Span{
        .{ .start = 0, .end = 6, .background = false, .double_underline = true },
        .{ .start = 6, .end = 12, .background = false },
    };
    try testing.expectEqual([2]usize{ 0, 6 }, target(&double, 12));
    // A background wins over a bold spanning the composition.
    const both = [_]Span{
        .{ .start = 0, .end = 3, .background = false, .bold = true },
        .{ .start = 3, .end = 6, .background = true, .bold = true },
    };
    try testing.expectEqual([2]usize{ 3, 6 }, target(&both, 6));
}

test "a run past the text is cut to it" {
    try testing.expectEqual([2]usize{ 3, 9 }, target(&.{.{ .start = 3, .end = 2147483647, .background = true }}, 9));
}
