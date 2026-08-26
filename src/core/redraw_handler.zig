const std = @import("std");
const mp = @import("msgpack.zig");
const grid_mod = @import("grid.zig");
const Grid = grid_mod.Grid;
const ModeInfo = grid_mod.ModeInfo;
const CmdlineChunk = grid_mod.CmdlineChunk;
const PopupmenuItem = grid_mod.PopupmenuItem;
const MsgChunk = grid_mod.MsgChunk;
const TabEntry = grid_mod.TabEntry;
const BufferEntry = grid_mod.BufferEntry;
const hlmod = @import("highlight.zig");
const Highlights = hlmod.Highlights;
const Styles = hlmod.Styles;
const Logger = @import("log.zig").Logger;
const clock = @import("clock.zig");

/// All redraw events handled by `handleRedraw`. Order is not significant;
/// `std.meta.stringToEnum` is used for perfect-hash-style dispatch.
/// Unknown event names (e.g., future Neovim additions) return null and are skipped.
pub const RedrawEvent = enum {
    grid_resize,
    grid_clear,
    grid_cursor_goto,
    grid_destroy,
    win_split,
    win_resize,
    win_move,
    win_exchange,
    win_rotate,
    win_resize_equal,
    win_pos,
    win_hide,
    win_close,
    win_viewport,
    win_viewport_margins,
    win_float_pos,
    win_external_pos,
    msg_set_pos,
    grid_scroll,
    hl_attr_define,
    hl_group_set,
    default_colors_set,
    option_set,
    mode_info_set,
    mode_change,
    busy_start,
    busy_stop,
    grid_line,
    cmdline_show,
    cmdline_hide,
    cmdline_pos,
    cmdline_special_char,
    cmdline_block_show,
    cmdline_block_append,
    cmdline_block_hide,
    popupmenu_show,
    popupmenu_hide,
    popupmenu_select,
    tabline_update,
    msg_show,
    msg_clear,
    msg_showmode,
    msg_showcmd,
    msg_ruler,
    msg_history_show,
    msg_history_clear,
    set_title,
    restart,
    connect,
    flush,
};

/// Parse Neovim ext type handle (tab, buffer, window handles).
/// Neovim sends handles as ext types with data containing big-endian integer.
fn parseExtHandle(ext: mp.Ext) i64 {
    // Neovim encodes window/tab/buffer handles as MessagePack EXT with the
    // payload itself a nested MessagePack integer (e.g. handle 128 is the
    // 2-byte payload \xcc\x80: uint8 tag + value 128) — NOT a raw
    // big-endian integer.
    // This path is normally unreachable in practice: mp.decode's own `ext`
    // branch already pre-unwraps well-formed integer payloads into `.int`
    // before this function ever sees a `.ext` Value, so this only runs on
    // malformed/edge-case payloads mp.decode itself failed to unwrap.
    if (ext.data.len == 0) return 0;
    var sr = mp.SliceReader{ .data = ext.data };
    const ib0 = sr.readByte() catch return 0;
    const v = mp.decodeInt(&sr, ib0) catch return 0;
    return v;
}

fn firstCodepoint(utf8: []const u8) u32 {
    // Return 0 for empty strings (continuation cell for wide characters)
    if (utf8.len == 0) return 0;

    var it = std.unicode.Utf8Iterator{ .bytes = utf8, .i = 0 };

    // Avoid Utf8Iterator.nextCodepoint() because it can panic on invalid UTF-8
    // (it uses utf8Decode(slice) catch unreachable).
    const slice = it.nextCodepointSlice() orelse return ' ';

    const cp = std.unicode.utf8Decode(slice) catch {
        // Invalid UTF-8 (e.g., overlong encoding). Return replacement char.
        return 0xFFFD;
    };

    return @as(u32, cp);
}

/// Extract all codepoints from a UTF-8 cell string into a stack buffer.
/// Returns the number of codepoints written (including the first).
/// If the string exceeds the lossless inline cell representation, fail before
/// mutating the grid instead of silently publishing a truncated cluster.
fn extractAllCodepoints(utf8: []const u8, buf: *[16]u32) !u32 {
    if (utf8.len == 0) {
        buf[0] = 0;
        return 1;
    }

    // Cell text arrives as unvalidated wire bytes, so the sequence length is
    // probed before the cursor advances: Utf8Iterator.nextCodepointSlice traps
    // on an invalid start byte and slices out of bounds on a truncated tail.
    var i: usize = 0;
    var count: u32 = 0;

    while (count < buf.len and i < utf8.len) {
        const cp_len = std.unicode.utf8ByteSequenceLength(utf8[i]) catch {
            buf[count] = 0xFFFD;
            count += 1;
            i += 1;
            continue;
        };
        if (i + cp_len > utf8.len) {
            buf[count] = 0xFFFD;
            count += 1;
            i = utf8.len;
            continue;
        }
        const cp = std.unicode.utf8Decode(utf8[i .. i + cp_len]) catch {
            buf[count] = 0xFFFD;
            count += 1;
            i += cp_len;
            continue;
        };
        buf[count] = @as(u32, cp);
        count += 1;
        i += cp_len;
    }

    if (count == buf.len and i < utf8.len) {
        return error.CellClusterTooLong;
    }

    if (count == 0) {
        buf[0] = ' ';
        return 1;
    }
    return count;
}

const ExtractedCellCodepoints = struct {
    count: u32,
    replaced_oversized: bool,
};

/// Preserve redraw-stream alignment when a malformed cell exceeds the inline
/// cluster representation. The low-level extractor remains lossless-or-error;
/// the wire handler substitutes one visible replacement glyph instead of
/// truncating the cluster or aborting the rest of the redraw batch (including
/// its flush event).
fn extractCellCodepoints(utf8: []const u8, buf: *[16]u32) ExtractedCellCodepoints {
    const count = extractAllCodepoints(utf8, buf) catch {
        buf[0] = 0xFFFD;
        return .{ .count = 1, .replaced_oversized = true };
    };
    return .{ .count = count, .replaced_oversized = false };
}

fn mapGetInt(m: []mp.Pair, key: []const u8) ?i64 {
    for (m) |p| {
        if (p.key == .str and std.mem.eql(u8, p.key.str, key) and p.val == .int) {
            return p.val.int;
        }
    }
    return null;
}

fn mapGetStr(m: []mp.Pair, key: []const u8) ?[]const u8 {
    for (m) |p| {
        if (p.key == .str and std.mem.eql(u8, p.key.str, key) and p.val == .str) {
            return p.val.str;
        }
    }
    return null;
}

/// Apply mode_infos[idx] to the grid's live cursor style fields.
///
/// Both mode_info_set and mode_change need this. The live fields are a
/// snapshot of a table entry, so a table rebuilt by `:set guicursor` must be
/// re-applied to the CURRENT mode right away: Neovim does not re-send
/// mode_change after mode_info_set, so resolving the style only on
/// mode_change leaves the previous shape on screen until the user happens to
/// switch modes.
fn applyModeInfo(grid: *Grid, idx: usize) void {
    if (!grid.cursor_style_enabled) return;
    if (idx >= grid.mode_infos.items.len) return;
    const mi = grid.mode_infos.items[idx];
    grid.cursor_shape = mi.shape;
    grid.cursor_cell_percentage = mi.cell_percentage;
    grid.cursor_attr_id = mi.attr_id;
    grid.cursor_blink_wait_ms = mi.blink_wait_ms;
    grid.cursor_blink_on_ms = mi.blink_on_ms;
    grid.cursor_blink_off_ms = mi.blink_off_ms;
}

fn mapGetBool(m: []mp.Pair, key: []const u8) ?bool {
    for (m) |p| {
        if (p.key == .str and std.mem.eql(u8, p.key.str, key) and p.val == .bool) {
            return p.val.bool;
        }
    }
    return null;
}

/// Convert a signed 64-bit msgpack integer to u32, rejecting values that
/// would require an unsafe `@intCast` (negative, or larger than
/// `maxInt(u32)`). `@intCast` in Zig is a safety-checked assertion, not a
/// clamp: an out-of-range value panics in Debug/ReleaseSafe and is UB in
/// ReleaseFast. Callers treat `null` as "skip this event/tuple", matching
/// the existing sign-checked call sites in this file (e.g. `grid_resize`,
/// `grid_cursor_goto`).
fn checkedU32(v: i64) ?u32 {
    if (v < 0 or v > std.math.maxInt(u32)) return null;
    return @as(u32, @intCast(v));
}

/// Neovim allocates grid handles from a positive signed-int domain. Metal's
/// vertex input and scroll-offset ABI consume the low signed 32 bits, so reject
/// values outside that producer domain before they can enter shared grid state.
fn checkedGridId(v: i64) ?i64 {
    if (v <= 0 or v > std.math.maxInt(i32)) return null;
    return v;
}

/// Convert a signed 64-bit msgpack integer to i32, rejecting values outside
/// the i32 range. Exposed as `pub` because `rpc_session.zig`'s
/// `handleWinMoveCursor` — a directly reachable RPC *request* handler, not
/// just a redraw event — needs the identical guard.
pub fn checkedI32(v: i64) ?i32 {
    if (v < std.math.minInt(i32) or v > std.math.maxInt(i32)) return null;
    return @as(i32, @intCast(v));
}

/// Truncate one finite Msgpack float to i64 without letting @intFromFloat
/// assert on NaN, infinity, or a value outside the integer domain.
fn checkedFloatToI64(v: f64) ?i64 {
    if (!std.math.isFinite(v)) return null;
    const min_i64_f: f64 = @floatFromInt(std.math.minInt(i64));
    const max_i64_exclusive_f: f64 = 0x1p63;
    if (v < min_i64_f or v >= max_i64_exclusive_f) return null;
    return @intFromFloat(v);
}

/// Grid positions cross i32 frontend ABI fields. Reject, rather than wrap or
/// clamp, an event which cannot be represented consistently by every consumer.
fn checkedGridCoord(v: i64) ?u32 {
    if (v < 0 or v > std.math.maxInt(i32)) return null;
    return @intCast(v);
}

test "checked float and grid coordinates reject hostile numeric bounds" {
    try std.testing.expectEqual(@as(?i64, -3), checkedFloatToI64(-3.75));
    try std.testing.expectEqual(@as(?i64, null), checkedFloatToI64(std.math.nan(f64)));
    try std.testing.expectEqual(@as(?i64, null), checkedFloatToI64(std.math.inf(f64)));
    try std.testing.expectEqual(@as(?i64, null), checkedFloatToI64(0x1p63));
    try std.testing.expectEqual(@as(?u32, null), checkedGridCoord(std.math.maxInt(i64)));
    try std.testing.expectEqual(@as(?i64, 1), checkedGridId(1));
    try std.testing.expectEqual(@as(?i64, std.math.maxInt(i32)), checkedGridId(std.math.maxInt(i32)));
    try std.testing.expectEqual(@as(?i64, null), checkedGridId(0));
    try std.testing.expectEqual(@as(?i64, null), checkedGridId(@as(i64, std.math.maxInt(i32)) + 1));
}

fn toRgbOpt(v: ?i64) ?u32 {
    if (v == null) return null;
    return checkedU32(v.?);
}

fn tupleIter(a: []mp.Value) []mp.Value {
    if (a.len <= 1) return &[_]mp.Value{};
    return a[1..];
}

const GuiFontList = struct {
    items: [][]const u8,
};

fn isSpaceAfterComma(c: u8) bool {
    return c == ' ' or c == '\t';
}

fn isWinGuiFontSpec(s: []const u8) bool {
    const colon = std.mem.indexOfScalar(u8, s, ':') orelse return false;
    const opts = s[colon + 1 ..];

    var i: usize = 0;
    var saw_any = false;

    while (i < opts.len) {
        var j = i;
        while (j < opts.len and opts[j] != ':') : (j += 1) {}
        const tok = opts[i..j];
        if (tok.len != 0) {
            saw_any = true;
            const c0 = tok[0];
            if (c0 == 'h' or c0 == 'w' or c0 == 'c') return true;
            if (tok.len == 1 and (c0 == 'b' or c0 == 'i' or c0 == 'u' or c0 == 's')) return true;
        }
        i = if (j < opts.len) j + 1 else j;
    }

    return saw_any;
}

fn dupeAndMaybeUnderscoreToSpace(arena: std.mem.Allocator, raw: []const u8) ![]const u8 {
    if (!isWinGuiFontSpec(raw)) return try arena.dupe(u8, raw);

    const colon = std.mem.indexOfScalar(u8, raw, ':') orelse return try arena.dupe(u8, raw);
    const base = raw[0..colon];
    const rest = raw[colon..];

    if (std.mem.indexOfScalar(u8, base, '_') == null) return try arena.dupe(u8, raw);

    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(arena);

    try out.appendSlice(arena, base);
    for (out.items[0..base.len]) |*ch| {
        if (ch.* == '_') ch.* = ' ';
    }
    try out.appendSlice(arena, rest);

    return try arena.dupe(u8, out.items);
}

/// Parse Vim/Neovim 'guifont' list (comma-separated, with escaping).
fn parseGuiFontList(arena: std.mem.Allocator, s: []const u8) !GuiFontList {
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    var cur: std.ArrayListUnmanaged(u8) = .empty;

    var skip_ws = false;
    var bs_count: usize = 0;

    const flushCandidate = struct {
        fn f(arena2: std.mem.Allocator, out2: *std.ArrayListUnmanaged([]const u8), cur2: *std.ArrayListUnmanaged(u8)) !void {
            if (cur2.items.len == 0) return;

            const norm = try dupeAndMaybeUnderscoreToSpace(arena2, cur2.items);
            try out2.append(arena2, norm);

            cur2.items.len = 0;
        }
    }.f;

    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        const ch = s[i];

        if (skip_ws and bs_count == 0 and isSpaceAfterComma(ch)) {
            continue;
        }
        skip_ws = false;

        if (ch == '\\') {
            bs_count += 1;
            continue;
        }

        if (bs_count != 0) {
            const pairs = bs_count / 2;
            var p: usize = 0;
            while (p < pairs) : (p += 1) try cur.append(arena, '\\');

            const odd = (bs_count % 2) == 1;
            bs_count = 0;

            if (odd) {
                if (ch == ',' or ch == ' ' or ch == '\\') {
                    try cur.append(arena, ch);
                    continue;
                } else {
                    try cur.append(arena, '\\');
                }
            }
        }

        if (ch == ',') {
            try flushCandidate(arena, &out, &cur);
            skip_ws = true;
            continue;
        }

        try cur.append(arena, ch);
    }

    if (bs_count != 0) {
        var p: usize = 0;
        while (p < bs_count) : (p += 1) try cur.append(arena, '\\');
    }

    try flushCandidate(arena, &out, &cur);

    return .{ .items = out.items };
}

// ---- guifont "candidate" parse (Zig-side: name + pointSize + features) ----

pub const FontFeature = struct {
    tag: [4]u8,
    value: i32,
};

const MAX_FONT_FEATURES = 32;

pub const GuiFontResolved = struct {
    name: []const u8,
    point_size: f64,
    features: []const FontFeature,
};

/// Try to parse a colon-separated token as an OpenType feature.
/// Accepted formats: "+liga", "-dlig", "ss01=2", "zero" (4-char tag = enable).
pub fn parseFontFeatureToken(tok: []const u8) ?FontFeature {
    if (tok.len == 0) return null;

    var tag_str: []const u8 = undefined;
    var value: i32 = 1;

    if (tok[0] == '+' or tok[0] == '-') {
        tag_str = tok[1..];
        value = if (tok[0] == '+') 1 else 0;
    } else if (std.mem.indexOfScalar(u8, tok, '=')) |eq| {
        tag_str = tok[0..eq];
        value = std.fmt.parseInt(i32, tok[eq + 1 ..], 10) catch return null;
    } else {
        // Bare 4-char tag → enable
        tag_str = tok;
    }

    if (tag_str.len != 4) return null;
    // Reject tags that look like size options (e.g. bare "h140" or "p120")
    if (tag_str[0] == 'h' or tag_str[0] == 'p') {
        if (std.fmt.parseFloat(f64, tag_str[1..])) |_| return null else |_| {}
    }

    return FontFeature{
        .tag = .{ tag_str[0], tag_str[1], tag_str[2], tag_str[3] },
        .value = value,
    };
}

pub fn parseGuiFontCandidate(arena: std.mem.Allocator, cand: []const u8) !GuiFontResolved {
    // Format: "Name:h14:+ss01:-liga:cv02=3" etc.
    // We keep name as-is (already unescaped by parseGuiFontList).
    // point_size default: 14
    var name_part: []const u8 = cand;
    var point: f64 = 14.0;
    var features: std.ArrayListUnmanaged(FontFeature) = .empty;

    if (std.mem.indexOfScalar(u8, cand, ':')) |colon| {
        name_part = cand[0..colon];
        const opts = cand[colon + 1 ..];

        var i: usize = 0;
        while (i < opts.len) {
            var j = i;
            while (j < opts.len and opts[j] != ':') : (j += 1) {}
            const tok = opts[i..j];

            if (tok.len >= 2) {
                const c0 = tok[0];
                if (c0 == 'h' or c0 == 'p') {
                    if (std.fmt.parseFloat(f64, tok[1..])) |v| {
                        point = v;
                        i = if (j < opts.len) j + 1 else j;
                        continue;
                    } else |_| {}
                }
            }

            // Try as OpenType feature
            if (parseFontFeatureToken(tok)) |feat| {
                if (features.items.len < MAX_FONT_FEATURES) {
                    try features.append(arena, feat);
                }
            }

            i = if (j < opts.len) j + 1 else j;
        }
    }

    // Trim whitespace around name.
    // If name is empty, return empty string - frontend will use config/OS default.
    const trimmed = std.mem.trim(u8, name_part, " \t\r\n");

    return .{
        .name = try arena.dupe(u8, trimmed),
        .point_size = point,
        .features = features.items,
    };
}

pub fn formatResolvedGuiFont(arena: std.mem.Allocator, r: GuiFontResolved) ![]const u8 {
    // "<name>\t<size>" or "<name>\t<size>\t<features>"
    if (r.features.len == 0) {
        return try std.fmt.allocPrint(arena, "{s}\t{d}", .{ r.name, r.point_size });
    }

    // Build features string: "+liga,-dlig,ss01=2"
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    const prefix = try std.fmt.allocPrint(arena, "{s}\t{d}\t", .{ r.name, r.point_size });
    try buf.appendSlice(arena, prefix);

    for (r.features, 0..) |f, idx| {
        if (idx > 0) try buf.append(arena, ',');
        if (f.value == 1) {
            try buf.append(arena, '+');
            try buf.appendSlice(arena, &f.tag);
        } else if (f.value == 0) {
            try buf.append(arena, '-');
            try buf.appendSlice(arena, &f.tag);
        } else {
            try buf.appendSlice(arena, &f.tag);
            try buf.append(arena, '=');
            const val_str = try std.fmt.allocPrint(arena, "{d}", .{f.value});
            try buf.appendSlice(arena, val_str);
        }
    }

    return buf.items;
}

fn dumpValue(v: anytype, indent: usize) void {
    const pad = "                                "[0..indent];

    switch (v) {
        .nil => std.log.debug("{s}nil", .{pad}),
        .bool => |b| std.log.debug("{s}bool: {}", .{ pad, b }),
        .int => |i| std.log.debug("{s}int: {}", .{ pad, i }),
        .float => |f| std.log.debug("{s}float: {}", .{ pad, f }),
        .str => |s| std.log.debug("{s}str: \"{s}\"", .{ pad, s }),
        .arr => |a| {
            std.log.debug("{s}arr(len={})", .{ pad, a.len });
            for (a, 0..) |elem, i| {
                std.log.debug("{s}  [{}]", .{ pad, i });
                dumpValue(elem, indent + 4);
            }
        },
        .map => |m| {
            std.log.debug("{s}map(len={})", .{ pad, m.len });
            // Can expand key/value if needed
        },
        .ext => |e| {
            std.log.debug("{s}ext: type_code={} data_len={}", .{ pad, e.type_code, e.data.len });

            // Optional: dump first few bytes (handy when ext is used for handles)
            const n = @min(e.data.len, 16);
            if (n > 0) {
                std.log.debug("{s}  data[0..{}] = {any}", .{ pad, n, e.data[0..n] });
            }
        },
    }
}

fn logValue(log: *Logger, v: mp.Value, indent: usize, depth: u32) void {
    const max_depth: u32 = 4;
    const max_items: usize = 8;
    const max_str: usize = 160;

    const pad = "                                ";
    const pad_len = if (indent > pad.len) pad.len else indent;
    const p = pad[0..pad_len];

    if (depth >= max_depth) {
        log.write("{s}<depth limit>\n", .{p});
        return;
    }

    switch (v) {
        .nil => log.write("{s}nil\n", .{p}),
        .bool => |b| log.write("{s}bool:{any}\n", .{ p, b }),
        .int => |i| log.write("{s}int:{d}\n", .{ p, i }),
        .float => |f| log.write("{s}float:{d}\n", .{ p, f }),
        .str => |s| {
            const n = if (s.len > max_str) max_str else s.len;
            log.write("{s}str:\"{s}\"{s}\n", .{ p, s[0..n], if (s.len > max_str) "..." else "" });
        },
        .arr => |a| {
            log.write("{s}arr(len={d})\n", .{ p, a.len });
            const n = if (a.len > max_items) max_items else a.len;
            var i: usize = 0;
            while (i < n) : (i += 1) {
                log.write("{s}  [{d}]\n", .{ p, i });
                logValue(log, a[i], indent + 4, depth + 1);
            }
            if (a.len > n) {
                log.write("{s}  ... ({d} more)\n", .{ p, a.len - n });
            }
        },
        .map => |m| {
            log.write("{s}map(len={d})\n", .{ p, m.len });
            const n = if (m.len > max_items) max_items else m.len;
            var i: usize = 0;
            while (i < n) : (i += 1) {
                log.write("{s}  key[{d}]\n", .{ p, i });
                logValue(log, m[i].key, indent + 4, depth + 1);
                log.write("{s}  val[{d}]\n", .{ p, i });
                logValue(log, m[i].val, indent + 4, depth + 1);
            }
            if (m.len > n) {
                log.write("{s}  ... ({d} more)\n", .{ p, m.len - n });
            }
        },
        .ext => |e| {
            log.write("{s}ext:type={d} len={d}\n", .{ p, e.type_code, e.data.len });
        },
    }
}

/// Bound one grid_line cell tuple to the destination row. This is applied
/// even when `repeat` was omitted or malformed (defaulting to one), so a
/// hostile starting column can neither wrap u32 nor turn no-op writes beyond
/// the grid into unbounded work.
fn clampGridLineRepeat(col: u32, cols: u32, repeat: u32) u32 {
    if (col >= cols) return 0;
    return @min(repeat, cols - col);
}

/// Narrow Neovim's 'linespace' to the width the callback carries. Negative
/// values are legal and must survive: Neovim documents them for fonts that
/// leave too much room between lines (options.txt 'linespace'). The frontends
/// floor the row height that results, so nothing downstream needs a zero here.
fn linespacePxFromWire(v: i64) i32 {
    return @intCast(std.math.clamp(v, std.math.minInt(i32), std.math.maxInt(i32)));
}

test "linespace keeps negative values coming off the wire" {
    try std.testing.expectEqual(@as(i32, 0), linespacePxFromWire(0));
    try std.testing.expectEqual(@as(i32, 4), linespacePxFromWire(4));
    // Clamping this to zero silently discards the setting: the value reaches
    // the frontend unchanged and the row simply gets shorter.
    try std.testing.expectEqual(@as(i32, -5), linespacePxFromWire(-5));
    try std.testing.expectEqual(@as(i32, std.math.minInt(i32)), linespacePxFromWire(std.math.minInt(i64)));
    try std.testing.expectEqual(@as(i32, std.math.maxInt(i32)), linespacePxFromWire(std.math.maxInt(i64)));
}

test "grid_line repeat clamp handles untrusted u32 bounds" {
    try std.testing.expectEqual(@as(u32, 2), clampGridLineRepeat(2, 4, std.math.maxInt(u32)));
    try std.testing.expectEqual(@as(u32, 0), clampGridLineRepeat(4, 4, 1));
    try std.testing.expectEqual(@as(u32, 0), clampGridLineRepeat(std.math.maxInt(u32), 4, std.math.maxInt(u32)));
}

// ---------------------------------------------------------------------------
// grid_line semantics
//
// These drive the real `handleRedraw` with hand-built event trees and assert
// the resulting grid state. They replace the parity suite that used to pin
// this behaviour by diffing two decoder implementations against each other:
// once the streaming decoder was removed there was no second implementation
// left to compare against, and the per-cell rules below — sticky hl, the
// `-1` left-inherit, `repeat == 0` writing nothing — are subtle enough that
// they need pinning on their own terms rather than by mutual agreement.
// ---------------------------------------------------------------------------

/// One `grid_line` cell: `[text]`, `[text, hl]` or `[text, hl, repeat]`.
/// `hl`/`repeat` of null omit that field, which is how Neovim asks for
/// "keep the previous hl" and "write once".
fn testCell(arena: std.mem.Allocator, text: []const u8, hl: ?i64, repeat: ?i64) !mp.Value {
    // `repeat` occupies field 2, so asking for it without an `hl` still has to
    // put something in field 1. Neovim itself never sends that shape; a nil
    // there keeps the array well-formed rather than leaving it uninitialised.
    const n: usize = if (repeat != null) 3 else if (hl != null) 2 else 1;
    const fields = try arena.alloc(mp.Value, n);
    fields[0] = .{ .str = text };
    if (n >= 2) fields[1] = if (hl) |h| .{ .int = h } else .nil;
    if (repeat) |r| fields[2] = .{ .int = r };
    return .{ .arr = fields };
}

/// One `grid_line` tuple, built with all five fields Neovim actually sends
/// (`[grid, row, col_start, cells, wrap]`). A four-field tuple is silently
/// discarded by the `t.len < 5` guard, so building one by accident would make
/// a test assert against a grid nothing was ever written to.
fn testGridLineTuple(
    arena: std.mem.Allocator,
    grid_id: i64,
    row: i64,
    col: i64,
    cells: []const mp.Value,
) !mp.Value {
    const cells_copy = try arena.dupe(mp.Value, cells);
    const tuple = try arena.alloc(mp.Value, 5);
    tuple[0] = .{ .int = grid_id };
    tuple[1] = .{ .int = row };
    tuple[2] = .{ .int = col };
    tuple[3] = .{ .arr = cells_copy };
    tuple[4] = .{ .bool = false }; // wrap
    return .{ .arr = tuple };
}

/// A `grid_line` event carrying the given tuples, in order.
fn testGridLineEventOf(arena: std.mem.Allocator, tuples: []const mp.Value) !mp.Value {
    const ev = try arena.alloc(mp.Value, 1 + tuples.len);
    ev[0] = .{ .str = "grid_line" };
    for (tuples, 0..) |t, i| ev[1 + i] = t;
    return .{ .arr = ev };
}

/// The common case: one `grid_line` event carrying one tuple.
fn testGridLineEvent(
    arena: std.mem.Allocator,
    grid_id: i64,
    row: i64,
    col: i64,
    cells: []const mp.Value,
) !mp.Value {
    const t = try testGridLineTuple(arena, grid_id, row, col, cells);
    return testGridLineEventOf(arena, &[_]mp.Value{t});
}

fn runRedrawEvents(grid: *Grid, hl: *Highlights, arena: std.mem.Allocator, events: []mp.Value) !void {
    var log = Logger{};
    const noop = struct {
        fn preFlush(_: *u8) anyerror!void {}
        fn flush(_: *u8, _: u32, _: u32) anyerror!void {}
        fn guifont(_: *u8, _: []const u8) anyerror!void {}
        fn linespace(_: *u8, _: i32) anyerror!void {}
    };
    var ctx: u8 = 0;
    try handleRedraw(
        grid,
        hl,
        arena,
        events,
        &log,
        &ctx,
        noop.preFlush,
        noop.flush,
        &ctx,
        noop.guifont,
        &ctx,
        noop.linespace,
        null,
        null,
        null,
        null,
    );
}

test "grid_line keeps hl sticky across cells and inherits leftwards on -1" {
    var arena_inst = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    var grid = Grid.init(std.testing.allocator);
    defer grid.deinit();
    var hl = Highlights.init(std.testing.allocator);
    defer hl.deinit();
    try grid.resize(1, 8); // rows, cols

    const cells = [_]mp.Value{
        // hl 5 is given once and must stick to the next cell, which omits it.
        try testCell(arena, "a", 5, null),
        try testCell(arena, "b", null, null),
        // -1 past column 0 inherits whatever the left neighbour resolved to.
        try testCell(arena, "c", -1, null),
        // A fresh id ends the inheritance.
        try testCell(arena, "d", 9, null),
    };
    var events = [_]mp.Value{try testGridLineEvent(arena, 1, 0, 0, &cells)};
    try runRedrawEvents(&grid, &hl, arena, &events);

    try std.testing.expectEqual(@as(u32, 'a'), grid.getCell(0, 0).cp);
    try std.testing.expectEqual(@as(u32, 5), grid.getCellHL(0, 0));
    try std.testing.expectEqual(@as(u32, 5), grid.getCellHL(0, 1)); // sticky
    try std.testing.expectEqual(@as(u32, 5), grid.getCellHL(0, 2)); // inherited
    try std.testing.expectEqual(@as(u32, 9), grid.getCellHL(0, 3));
}

test "grid_line -1 at column 0 falls back to the default highlight" {
    var arena_inst = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    var grid = Grid.init(std.testing.allocator);
    defer grid.deinit();
    var hl = Highlights.init(std.testing.allocator);
    defer hl.deinit();
    try grid.resize(1, 4);

    // There is no left neighbour to inherit from, so this must resolve to 0
    // rather than reading the cell at col - 1 and underflowing.
    const cells = [_]mp.Value{try testCell(arena, "x", -1, null)};
    var events = [_]mp.Value{try testGridLineEvent(arena, 1, 0, 0, &cells)};
    try runRedrawEvents(&grid, &hl, arena, &events);

    try std.testing.expectEqual(@as(u32, 'x'), grid.getCell(0, 0).cp);
    try std.testing.expectEqual(@as(u32, 0), grid.getCellHL(0, 0));
}

test "grid_line repeat writes that many cells and zero writes none" {
    var arena_inst = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    var grid = Grid.init(std.testing.allocator);
    defer grid.deinit();
    var hl = Highlights.init(std.testing.allocator);
    defer hl.deinit();
    try grid.resize(1, 8);

    const cells = [_]mp.Value{
        try testCell(arena, "-", 3, 3), // columns 0..2
        // repeat 0 must write NOTHING and must not advance the column, so the
        // next cell lands on column 3. Treating it as 1 would shift the rest
        // of the row right by one.
        try testCell(arena, "Z", 4, 0),
        try testCell(arena, "e", 7, null), // column 3
    };
    var events = [_]mp.Value{try testGridLineEvent(arena, 1, 0, 0, &cells)};
    try runRedrawEvents(&grid, &hl, arena, &events);

    for (0..3) |c| {
        try std.testing.expectEqual(@as(u32, '-'), grid.getCell(0, @intCast(c)).cp);
        try std.testing.expectEqual(@as(u32, 3), grid.getCellHL(0, @intCast(c)));
    }
    try std.testing.expectEqual(@as(u32, 'e'), grid.getCell(0, 3).cp);
    try std.testing.expectEqual(@as(u32, 7), grid.getCellHL(0, 3));
}

test "grid_line clamps a repeat that would run past the last column" {
    var arena_inst = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    var grid = Grid.init(std.testing.allocator);
    defer grid.deinit();
    var hl = Highlights.init(std.testing.allocator);
    defer hl.deinit();
    try grid.resize(1, 4);

    // A hostile repeat must stop at the row edge instead of wrapping the
    // column counter or looping billions of times.
    const cells = [_]mp.Value{try testCell(arena, "#", 2, std.math.maxInt(u32))};
    var events = [_]mp.Value{try testGridLineEvent(arena, 1, 0, 1, &cells)};
    try runRedrawEvents(&grid, &hl, arena, &events);

    try std.testing.expectEqual(@as(u32, ' '), grid.getCell(0, 0).cp); // untouched
    for (1..4) |c| {
        try std.testing.expectEqual(@as(u32, '#'), grid.getCell(0, @intCast(c)).cp);
    }
}

test "grid_line keeps a multi-codepoint cluster addressable from its base cell" {
    var arena_inst = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    var grid = Grid.init(std.testing.allocator);
    defer grid.deinit();
    var hl = Highlights.init(std.testing.allocator);
    defer hl.deinit();
    try grid.resize(1, 4);

    // U+26A0 U+FE0F — the variation selector must reach the overflow map
    // rather than being dropped or occupying a cell of its own.
    const cells = [_]mp.Value{try testCell(arena, "\u{26A0}\u{FE0F}", 1, null)};
    var events = [_]mp.Value{try testGridLineEvent(arena, 1, 0, 0, &cells)};
    try runRedrawEvents(&grid, &hl, arena, &events);

    try std.testing.expectEqual(@as(u32, 0x26A0), grid.getCell(0, 0).cp);
    const extras = grid.getOverflow(1, 0, 0);
    try std.testing.expect(extras != null);
    try std.testing.expectEqual(@as(usize, 1), extras.?.len);
    try std.testing.expectEqual(@as(u32, 0xFE0F), extras.?[0]);
}

test "grid_line ignores a tuple that is missing the wrap field" {
    var arena_inst = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    var grid = Grid.init(std.testing.allocator);
    defer grid.deinit();
    var hl = Highlights.init(std.testing.allocator);
    defer hl.deinit();
    try grid.resize(1, 4);

    // Four-field tuples are discarded by the `t.len < 5` guard. This is
    // pinned deliberately: a benchmark once built its payload this way and
    // silently measured a decode path that never wrote a single cell.
    const cell = try testCell(arena, "q", 1, null);
    const cells_copy = try arena.dupe(mp.Value, &[_]mp.Value{cell});
    const short = try arena.alloc(mp.Value, 4);
    short[0] = .{ .int = 1 };
    short[1] = .{ .int = 0 };
    short[2] = .{ .int = 0 };
    short[3] = .{ .arr = cells_copy };

    // A well-formed tuple rides along so the assertion below distinguishes
    // "the short tuple was dropped" from "the event was never processed".
    const good_cells = [_]mp.Value{try testCell(arena, "r", 2, null)};
    const good = try testGridLineTuple(arena, 1, 0, 1, &good_cells);

    var events = [_]mp.Value{try testGridLineEventOf(arena, &[_]mp.Value{ .{ .arr = short }, good })};
    try runRedrawEvents(&grid, &hl, arena, &events);

    try std.testing.expectEqual(@as(u32, ' '), grid.getCell(0, 0).cp);
    try std.testing.expectEqual(@as(u32, 'r'), grid.getCell(0, 1).cp);
}

test "grid_line maps an hl_id beyond u32 to the default highlight" {
    var arena_inst = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    var grid = Grid.init(std.testing.allocator);
    defer grid.deinit();
    var hl = Highlights.init(std.testing.allocator);
    defer hl.deinit();
    try grid.resize(1, 4);

    // The hl table is u32-keyed. A raw @intCast of an out-of-range id would
    // panic the redraw thread, so it has to fall back to the default style.
    const cells = [_]mp.Value{try testCell(arena, "x", @as(i64, 1) << 32, null)};
    var events = [_]mp.Value{try testGridLineEvent(arena, 1, 0, 0, &cells)};
    try runRedrawEvents(&grid, &hl, arena, &events);

    try std.testing.expectEqual(@as(u32, 'x'), grid.getCell(0, 0).cp);
    try std.testing.expectEqual(@as(u32, 0), grid.getCellHL(0, 0));
}

test "grid_line drops a tuple whose col_start is out of range" {
    var arena_inst = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    var grid = Grid.init(std.testing.allocator);
    defer grid.deinit();
    var hl = Highlights.init(std.testing.allocator);
    defer hl.deinit();
    try grid.resize(1, 4);

    // Both the omitted-repeat and explicit-repeat shapes must be rejected by
    // the clamp rather than wrapping the column counter.
    const plain = [_]mp.Value{try testCell(arena, "a", 1, null)};
    const huge = [_]mp.Value{try testCell(arena, "b", 1, std.math.maxInt(u32))};
    var events = [_]mp.Value{
        try testGridLineEvent(arena, 1, 0, std.math.maxInt(u32), &plain),
        try testGridLineEvent(arena, 1, 0, std.math.maxInt(u32), &huge),
    };
    try runRedrawEvents(&grid, &hl, arena, &events);

    for (0..4) |c| {
        try std.testing.expectEqual(@as(u32, ' '), grid.getCell(0, @intCast(c)).cp);
        try std.testing.expectEqual(@as(u32, 0), grid.getCellHL(0, @intCast(c)));
    }
}

test "grid_line writes an oversized cluster as one replacement glyph" {
    var arena_inst = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    var grid = Grid.init(std.testing.allocator);
    defer grid.deinit();
    var hl = Highlights.init(std.testing.allocator);
    defer hl.deinit();
    try grid.resize(1, 4);

    // 17 codepoints exceed the 16-slot cluster buffer. The cell collapses to
    // U+FFFD with no overflow entry, and must not consume extra columns.
    const cells = [_]mp.Value{
        try testCell(arena, "abcdefghijklmnopq", 1, null),
        try testCell(arena, "x", 1, null),
    };
    var events = [_]mp.Value{try testGridLineEvent(arena, 1, 0, 0, &cells)};
    try runRedrawEvents(&grid, &hl, arena, &events);

    try std.testing.expectEqual(@as(u32, 0xFFFD), grid.getCell(0, 0).cp);
    try std.testing.expect(grid.getOverflow(1, 0, 0) == null);
    try std.testing.expectEqual(@as(u32, 'x'), grid.getCell(0, 1).cp);
}

test "grid_line skips a malformed tuple but keeps the rest of the event" {
    var arena_inst = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    var grid = Grid.init(std.testing.allocator);
    defer grid.deinit();
    var hl = Highlights.init(std.testing.allocator);
    defer hl.deinit();
    try grid.resize(1, 4);

    // A tuple that is not an array at all must cost only itself. Aborting the
    // whole batch here would leave the grid half-applied relative to Neovim.
    const cells = [_]mp.Value{try testCell(arena, "a", 1, null)};
    const good = try testGridLineTuple(arena, 1, 0, 0, &cells);
    var events = [_]mp.Value{try testGridLineEventOf(arena, &[_]mp.Value{ .{ .bool = false }, good })};
    try runRedrawEvents(&grid, &hl, arena, &events);

    try std.testing.expectEqual(@as(u32, 'a'), grid.getCell(0, 0).cp);
}

test "grid_line starts each tuple with a fresh highlight state" {
    var arena_inst = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    var grid = Grid.init(std.testing.allocator);
    defer grid.deinit();
    var hl = Highlights.init(std.testing.allocator);
    defer hl.deinit();
    try grid.resize(2, 4);

    // hl is sticky *within* a tuple only. A second tuple that omits hl must
    // start from the default, not inherit 5 from the tuple before it.
    const first = [_]mp.Value{try testCell(arena, "a", 5, null)};
    const second = [_]mp.Value{try testCell(arena, "b", null, null)};
    var events = [_]mp.Value{try testGridLineEventOf(arena, &[_]mp.Value{
        try testGridLineTuple(arena, 1, 0, 0, &first),
        try testGridLineTuple(arena, 1, 1, 0, &second),
    })};
    try runRedrawEvents(&grid, &hl, arena, &events);

    try std.testing.expectEqual(@as(u32, 5), grid.getCellHL(0, 0));
    try std.testing.expectEqual(@as(u32, 'b'), grid.getCell(1, 0).cp);
    try std.testing.expectEqual(@as(u32, 0), grid.getCellHL(1, 0));
}

test "cell cluster extraction rejects rather than truncates codepoint 17" {
    var buf: [16]u32 = undefined;
    try std.testing.expectEqual(@as(u32, 16), try extractAllCodepoints("abcdefghijklmnop", &buf));
    try std.testing.expectError(error.CellClusterTooLong, extractAllCodepoints("abcdefghijklmnopq", &buf));
    const wire_result = extractCellCodepoints("abcdefghijklmnopq", &buf);
    try std.testing.expect(wire_result.replaced_oversized);
    try std.testing.expectEqual(@as(u32, 1), wire_result.count);
    try std.testing.expectEqual(@as(u32, 0xFFFD), buf[0]);
}

/// Supported redraw events:
/// grid_resize, grid_line, grid_clear, grid_cursor_goto, hl_attr_define,
/// default_colors_set, option_set, set_title, restart, connect, flush
pub fn handleRedraw(
    grid: *Grid,
    hl: *Highlights,
    arena: std.mem.Allocator,
    params: []mp.Value,
    log: *Logger,
    flush_ctx: anytype,
    pre_flush_fn: *const fn (ctx: @TypeOf(flush_ctx)) anyerror!void,
    flush_fn: *const fn (ctx: @TypeOf(flush_ctx), rows: u32, cols: u32) anyerror!void,
    opt_ctx: anytype,
    guifont_fn: *const fn (ctx: @TypeOf(opt_ctx), font: []const u8) anyerror!void,
    linespace_ctx: anytype,
    linespace_fn: *const fn (ctx: @TypeOf(linespace_ctx), px: i32) anyerror!void,
    set_title_fn: ?*const fn (ctx: @TypeOf(opt_ctx), title: []const u8) anyerror!void,
    default_colors_fn: ?*const fn (ctx: @TypeOf(opt_ctx), fg: u32, bg: u32) anyerror!void,
    restart_fn: ?*const fn (ctx: @TypeOf(opt_ctx), listen_addr: []const u8) anyerror!void,
    connect_fn: ?*const fn (ctx: @TypeOf(opt_ctx), server_addr: []const u8) anyerror!void,
) !void {
    const redraw_epoch = grid.redraw_epoch_override orelse grid.beginRedrawBatch();

    // Per-handleRedraw aggregate. Each "redraw" notification batches many
    // events (grid_line, grid_scroll, hl_attr_define, ...). The [perf_input]
    // grid_line / flush_start lines already mark dispatch latency; this gives
    // a single batch-level [perf] line so a profiler can see total wall time
    // and event count without scraping per-event lines.
    const log_on_batch = log.cb != null;
    const t_batch_start: i128 = if (log_on_batch) clock.nowNs() else 0;
    var ev_count: u32 = 0;
    var tuple_count: u32 = 0;
    // grid_line cell-write counter (after repeat expansion). Quantifies the
    // "type B" terminal-buffer scroll cost: tig/less/lazygit produce no
    // grid_scroll, but rewrite affected rows via grid_line — so a single
    // PageDown can write rows*cols cells per batch. Compare against
    // grid_scroll batches where dirty rows are minimal.
    var grid_line_cells_total: u64 = 0;
    var grid_line_tuple_total: u32 = 0;

    // Per-event-tag dispatch time (ns) and call count, indexed by
    // @intFromEnum(RedrawEvent). Stack-allocated, zero-init. Dumped once at
    // batch end as a single [perf] redraw_events line, sorted client-side.
    @setEvalBranchQuota(4000);
    const N_EVENTS = @typeInfo(RedrawEvent).@"enum".fields.len;
    var per_event_ns: [N_EVENTS]u64 = .{0} ** N_EVENTS;
    var per_event_cnt: [N_EVENTS]u32 = .{0} ** N_EVENTS;

    defer {
        if (log_on_batch) {
            const batch_us: i64 = @intCast(@divTrunc(@max(0, clock.nowNs() - t_batch_start), 1000));
            log.write(
                "[perf] redraw_batch events={d} tuples={d} us={d}\n",
                .{ ev_count, tuple_count, batch_us },
            );
            // Always emit even when zero, so a downstream analyzer can pair
            // it 1:1 with redraw_batch and detect zero-grid_line batches.
            log.write(
                "[perf] grid_line_stats tuples={d} cells={d}\n",
                .{ grid_line_tuple_total, grid_line_cells_total },
            );
            // One [perf] redraw_event line per nonzero tag. Verbose tier:
            // several lines per batch add up during scroll bursts (measured
            // ~2.7k lines in a 30s tig session) and the batch-level
            // redraw_batch/grid_line_stats aggregates above stay available.
            if (log.verbose) {
                inline for (@typeInfo(RedrawEvent).@"enum".fields, 0..) |f, i| {
                    if (per_event_cnt[i] != 0) {
                        log.write(
                            "[perf] redraw_event name={s} count={d} ns={d}\n",
                            .{ f.name, per_event_cnt[i], per_event_ns[i] },
                        );
                    }
                }
            }
        }
    }

    for (params) |ev| {
        if (ev != .arr) continue;
        const a = ev.arr;
        if (a.len == 0 or a[0] != .str) continue;

        const name = a[0].str;
        const tuples = tupleIter(a);
        if (log_on_batch) {
            ev_count +%= 1;
            tuple_count +%= @intCast(tuples.len);
        }

        // Raw tuple dumps recursively traverse every value. Keep that work out
        // of normal/perf/scroll logging; it is an explicit verbose diagnostic.
        if (log.cb != null and log.verbose and !log.perf_only and !log.scroll_only) {
            log.write("ui_ev {s} tuples={d}\n", .{ name, tuples.len });
            if (tuples.len != 0) {
                var ti: usize = 0;
                while (ti < tuples.len) : (ti += 1) {
                    log.write("ui_ev tuple[{d}]\n", .{ti});
                    logValue(log, tuples[ti], 2, 0);
                }
            }
        }

        const ev_tag = std.meta.stringToEnum(RedrawEvent, name) orelse continue;
        // Per-event timing. defer fires at end of each loop iteration even
        // when the switch case path uses `try` to surface an error, since
        // defer runs on scope exit including through error returns.
        const t_ev_start: i128 = if (log_on_batch) clock.nowNs() else 0;
        defer if (log_on_batch) {
            const dt_ns: i128 = clock.nowNs() - t_ev_start;
            const idx = @intFromEnum(ev_tag);
            per_event_ns[idx] +|= @as(u64, @intCast(@max(@as(i128, 0), dt_ns)));
            per_event_cnt[idx] +|= 1;
        };
        switch (ev_tag) {
            .grid_resize => {
                for (tuples) |tv| {
                    if (tv != .arr) continue;
                    const t = tv.arr;
                    if (t.len < 3) continue;
                    if (t[0] != .int or t[1] != .int or t[2] != .int) continue;

                    const grid_id = checkedGridId(t[0].int) orelse continue;

                    const width = checkedU32(t[1].int) orelse continue;
                    const height = checkedU32(t[2].int) orelse continue;
                    grid.resizeGrid(grid_id, height, width) catch |err| {
                        log.write("grid_resize rejected grid={d} cols={d} rows={d}: {any}\n", .{ grid_id, width, height, err });
                        return err;
                    };

                    // Update external grid target size so NDC viewport matches the actual grid.
                    // Only for grids that are actual external windows (ext_windows splits
                    // or UI-extension grids like popupmenu/messages). Float windows
                    // (e.g. Telescope) must NOT get entries here — they render on the
                    // global grid and their NDC uses sg.rows/sg.cols directly.
                    if (grid.external_grids.contains(grid_id) or grid.ext_windows_grids.contains(grid_id)) {
                        try grid.external_grid_target_sizes.put(grid.alloc, grid_id, .{ .rows = height, .cols = width });
                    }

                    // Record the global grid size so core can detect a
                    // Neovim-initiated resize (`:set columns=` / `:set lines=`)
                    // after the batch completes.
                    if (grid_id == 1) {
                        grid.pending_main_grid_size = .{ .rows = height, .cols = width };
                    }

                    if (log.cb != null) log.write("grid_resize grid={d} cols={d} rows={d}\n", .{ grid_id, width, height });
                }
            },
            .grid_clear => {
                // Spec always sends [grid]; an empty tuple array is malformed
                // input. Skip instead of silently defaulting to grid 1 — the
                // loop below is already a no-op when `tuples` is empty.
                for (tuples) |tv| {
                    if (tv != .arr) continue;
                    const t = tv.arr;

                    // grid_clear: [grid]
                    if (t.len < 1 or t[0] != .int) continue;
                    const grid_id = checkedGridId(t[0].int) orelse continue;
                    grid.clearGrid(grid_id);
                }
            },
            .grid_cursor_goto => {
                for (tuples) |tv| {
                    if (tv != .arr) continue;
                    const t = tv.arr;
                    if (t.len < 3) continue;
                    if (t[0] != .int or t[1] != .int or t[2] != .int) continue;

                    const grid_id = checkedGridId(t[0].int) orelse continue;
                    const row = checkedU32(t[1].int) orelse continue;
                    const col = checkedU32(t[2].int) orelse continue;
                    grid.setCursor(grid_id, row, col);
                }
            },
            .grid_destroy => {
                for (tuples) |tv| {
                    if (tv != .arr) continue;
                    const t = tv.arr;
                    if (t.len < 1 or t[0] != .int) continue;

                    const grid_id = checkedGridId(t[0].int) orelse continue;
                    if (grid_id == 1) {
                        log.write("grid_destroy: rejected attempt to destroy main grid (grid_id=1)\n", .{});
                        continue;
                    }
                    try grid.destroyGrid(grid_id);
                }
            },
            .win_split => {
                // win_split (ext_windows): [win1, grid1, win2, grid2, flags]
                // win1/grid1 = source window, win2/grid2 = new window
                // flags: 0=below, 1=above, 2=right, 3=left
                for (tuples) |tv| {
                    if (tv != .arr) continue;
                    const t = tv.arr;
                    if (t.len < 5) continue;
                    if (t[0] != .int or t[1] != .int or t[2] != .int or t[3] != .int or t[4] != .int) continue;

                    const win1 = t[0].int;
                    const grid1 = checkedGridId(t[1].int) orelse continue;
                    const win2 = t[2].int;
                    const grid2 = checkedGridId(t[3].int) orelse continue;
                    const flags = t[4].int;
                    log.write("[win_split] win1={d} grid1={d} win2={d} grid2={d} flags={d}\n", .{ win1, grid1, win2, grid2, flags });

                    // Only register the NEW window (grid2/win2) as external.
                    // The source window (grid1/win1) stays where it is (global grid or already external).
                    _ = grid.setWinExternalPos(grid2, win2) catch |err| switch (err) {
                        error.TooManyWindowPlacements => {
                            log.write("[win_split] rejected grid2={d}: TooManyWindowPlacements\n", .{grid2});
                            return error.TooManyWindowPlacements;
                        },
                        else => return err,
                    };

                    // Persistently track only the NEW window as an ext_windows grid.
                    // This survives win_hide (tab switch) so win_pos can re-register it.
                    // Do NOT track grid1 (source) - it may be the main editor grid (grid 2)
                    // which should remain composited in the main window.
                    try grid.ext_windows_grids.put(grid.alloc, grid2, win2);
                }
            },
            .win_resize => {
                // win_resize (ext_windows): [win, grid, width, height]
                for (tuples) |tv| {
                    if (tv != .arr) continue;
                    const t = tv.arr;
                    if (t.len < 4) continue;
                    if (t[0] != .int or t[1] != .int or t[2] != .int or t[3] != .int) continue;

                    const win_id = t[0].int;
                    const grid_id = checkedGridId(t[1].int) orelse continue;
                    const width = checkedU32(t[2].int) orelse continue;
                    const height = checkedU32(t[3].int) orelse continue;
                    log.write("[win_resize] win={d} grid={d} width={d} height={d}\n", .{ win_id, grid_id, width, height });

                    // Re-register grid as external if it was removed (e.g. tab switch).
                    // When switching back to a tab, Neovim sends win_resize (not win_split)
                    // for windows that already exist in its model.
                    if (!grid.external_grids.contains(grid_id)) {
                        _ = grid.setWinExternalPos(grid_id, win_id) catch |err| switch (err) {
                            error.TooManyWindowPlacements => {
                                log.write("[win_resize] rejected grid={d}: TooManyWindowPlacements\n", .{grid_id});
                                return error.TooManyWindowPlacements;
                            },
                            else => return err,
                        };
                    }

                    // Queue a grid resize request for core to send after redraw
                    try grid.pending_grid_resizes.append(grid.alloc, .{
                        .grid_id = grid_id,
                        .width = width,
                        .height = height,
                    });
                }
            },
            .win_move => {
                // win_move (ext_windows): [win, grid, flags]
                // flags: 0=below, 1=above, 2=right, 3=left
                for (tuples) |tv| {
                    if (tv != .arr) continue;
                    const t = tv.arr;
                    if (t.len < 3) continue;
                    if (t[0] != .int or t[1] != .int or t[2] != .int) continue;

                    const win_id = t[0].int;
                    const grid_id = checkedGridId(t[1].int) orelse continue;
                    const flags = checkedI32(t[2].int) orelse continue;
                    log.write("[win_move] win={d} grid={d} flags={d}\n", .{ win_id, grid_id, flags });

                    try grid.pending_win_ops.append(grid.alloc, .{
                        .op = .move,
                        .win = win_id,
                        .grid_id = grid_id,
                        .flags_or_direction = flags,
                    });
                }
            },
            .win_exchange => {
                // win_exchange (ext_windows): [win, grid, count]
                for (tuples) |tv| {
                    if (tv != .arr) continue;
                    const t = tv.arr;
                    if (t.len < 3) continue;
                    if (t[0] != .int or t[1] != .int or t[2] != .int) continue;

                    const win_id = t[0].int;
                    const grid_id = checkedGridId(t[1].int) orelse continue;
                    const count = checkedI32(t[2].int) orelse continue;
                    log.write("[win_exchange] win={d} grid={d} count={d}\n", .{ win_id, grid_id, count });

                    try grid.pending_win_ops.append(grid.alloc, .{
                        .op = .exchange,
                        .win = win_id,
                        .grid_id = grid_id,
                        .count = count,
                    });
                }
            },
            .win_rotate => {
                // win_rotate (ext_windows): [win, grid, direction, count]
                // direction: 0=downward, 1=upward
                for (tuples) |tv| {
                    if (tv != .arr) continue;
                    const t = tv.arr;
                    if (t.len < 4) continue;
                    if (t[0] != .int or t[1] != .int or t[2] != .int or t[3] != .int) continue;

                    const win_id = t[0].int;
                    const grid_id = checkedGridId(t[1].int) orelse continue;
                    const direction = checkedI32(t[2].int) orelse continue;
                    const count = checkedI32(t[3].int) orelse continue;
                    log.write("[win_rotate] win={d} grid={d} direction={d} count={d}\n", .{ win_id, grid_id, direction, count });

                    try grid.pending_win_ops.append(grid.alloc, .{
                        .op = .rotate,
                        .win = win_id,
                        .grid_id = grid_id,
                        .flags_or_direction = direction,
                        .count = count,
                    });
                }
            },
            .win_resize_equal => {
                // win_resize_equal (ext_windows): no parameters
                log.write("[win_resize_equal]\n", .{});

                try grid.pending_win_ops.append(grid.alloc, .{
                    .op = .resize_equal,
                });
            },
            .win_pos => {
                // win_pos: [grid, win, startrow, startcol, width, height]
                for (tuples) |tv| {
                    if (tv != .arr) continue;
                    const t = tv.arr;
                    if (t.len < 6) continue;
                    if (t[0] != .int or t[1] != .int or t[2] != .int or t[3] != .int) continue;

                    const grid_id = checkedGridId(t[0].int) orelse continue;
                    const win_id = t[1].int;
                    const startrow = checkedGridCoord(t[2].int) orelse continue;
                    const startcol = checkedGridCoord(t[3].int) orelse continue;
                    log.write("[win_pos] grid_id={d} win={d} startrow={d} startcol={d}\n", .{ grid_id, win_id, startrow, startcol });

                    // If this grid is tracked as an ext_windows grid (created by win_split),
                    // re-register it as external instead of compositing. This happens when
                    // switching back to a tab - Neovim sends win_pos for all windows but
                    // may not send win_resize/win_split for all of them.
                    if (grid.ext_windows_grids.contains(grid_id)) {
                        if (!grid.external_grids.contains(grid_id)) {
                            _ = grid.setWinExternalPosAt(grid_id, win_id, startrow, startcol) catch |err| switch (err) {
                                error.TooManyWindowPlacements => {
                                    log.write("[win_pos] rejected ext_windows grid={d}: TooManyWindowPlacements\n", .{grid_id});
                                    return error.TooManyWindowPlacements;
                                },
                                else => return err,
                            };
                            log.write("[win_pos] re-registered ext_windows grid={d} as external at ({d},{d})\n", .{ grid_id, startrow, startcol });
                        } else {
                            // Already external (e.g. win_pos after win_split in same
                            // redraw batch): update position directly.
                            grid.updateExternalGridPos(grid_id, startrow, startcol);
                            log.write("[win_pos] updated ext_windows grid={d} position to ({d},{d})\n", .{ grid_id, startrow, startcol });
                        }
                    } else {
                        grid.setWinPos(grid_id, win_id, startrow, startcol) catch |err| switch (err) {
                            error.TooManyWindowPlacements => {
                                log.write("[win_pos] rejected grid={d}: TooManyWindowPlacements\n", .{grid_id});
                                return error.TooManyWindowPlacements;
                            },
                            else => return err,
                        };
                    }
                }
            },
            .win_hide, .win_close => {
                // win_hide/win_close: [grid]
                const is_close = ev_tag == .win_close;
                for (tuples) |tv| {
                    if (tv != .arr) continue;
                    const t = tv.arr;
                    if (t.len < 1 or t[0] != .int) continue;
                    const grid_id = checkedGridId(t[0].int) orelse continue;
                    // Track if a composited (non-external, non-float) editor window
                    // is being closed. The promotion logic uses this to detect when
                    // Neovim re-composites grid 2 as a fallback in the same batch.
                    if (is_close and grid.win_pos.contains(grid_id) and !grid.win_layer.contains(grid_id) and grid_id != 1) {
                        grid.composited_win_closed = true;
                    }
                    try grid.hideWin(grid_id);
                    // On permanent close, remove from ext_windows tracking.
                    // On hide (tab switch), keep tracking so win_pos can restore.
                    if (is_close) {
                        _ = grid.ext_windows_grids.remove(grid_id);
                        _ = grid.external_grid_target_sizes.remove(grid_id);
                    }
                }
            },
            .win_viewport => {
                // win_viewport: [grid, win, topline, botline, curline, curcol, line_count, scroll_delta]
                for (tuples) |tv| {
                    if (tv != .arr) continue;
                    const t = tv.arr;
                    if (t.len < 8) continue;
                    if (t[0] != .int) continue;

                    const grid_id = checkedGridId(t[0].int) orelse continue;
                    // t[1] is the window handle. Kept so window-local options
                    // can be addressed from a grid id.
                    const win = if (t[1] == .int) t[1].int else 0;
                    const topline = if (t[2] == .int) t[2].int else 0;
                    const botline = if (t[3] == .int) t[3].int else 0;
                    const curline = if (t[4] == .int) t[4].int else 0;
                    const curcol = if (t[5] == .int) t[5].int else 0;
                    const line_count = if (t[6] == .int) t[6].int else 0;
                    const scroll_delta = if (t[7] == .int) t[7].int else 0;

                    log.write("[win_viewport] grid_id={d} topline={d} line_count={d}\n", .{ grid_id, topline, line_count });
                    try grid.setViewport(grid_id, win, topline, botline, curline, curcol, line_count, scroll_delta);
                }
            },
            .win_viewport_margins => {
                // win_viewport_margins: [grid, win, top, bottom, left, right]
                for (tuples) |tv| {
                    if (tv != .arr) continue;
                    const t = tv.arr;
                    if (t.len < 6) continue;
                    if (t[0] != .int) continue;

                    const grid_id = checkedGridId(t[0].int) orelse continue;
                    // t[1] is win (window handle), not used here
                    const top = if (t[2] == .int) (checkedU32(t[2].int) orelse 0) else 0;
                    const bottom = if (t[3] == .int) (checkedU32(t[3].int) orelse 0) else 0;
                    const left = if (t[4] == .int) (checkedU32(t[4].int) orelse 0) else 0;
                    const right = if (t[5] == .int) (checkedU32(t[5].int) orelse 0) else 0;

                    log.write("[win_viewport_margins] grid_id={d} top={d} bottom={d} left={d} right={d}\n", .{ grid_id, top, bottom, left, right });
                    try grid.setViewportMargins(grid_id, top, bottom, left, right);
                }
            },
            .win_float_pos => {

                // Observed (older nvim): [grid, win, anchor, anchor_grid, anchor_row, anchor_col, mouse_enabled, zindex]
                // Docs (newer nvim):     [grid, win, anchor, anchor_grid, anchor_row, anchor_col, mouse_enabled,
                //                         zindex, compindex, screen_row, screen_col]
                for (tuples) |tv| {

                    // log.write("win_float_pos:", .{});
                    // dumpValue(tv, 2);
                    if (tv != .arr) continue;
                    const t = tv.arr;

                    // Need at least: grid..zindex (len >= 8)
                    if (t.len < 8) continue;

                    // grid_id, win, and zindex are required for both forms.
                    if (t[0] != .int or t[1] != .int or t[7] != .int) continue;

                    const grid_id = checkedGridId(t[0].int) orelse continue;
                    const win_id = t[1].int;
                    const zindex = t[7].int;

                    // Optional fields (newer form)
                    var compindex: i64 = 0;
                    var screen_row_i: i64 = -1;
                    var screen_col_i: i64 = -1;

                    if (t.len >= 11) {
                        if (t[8] != .int or t[9] != .int or t[10] != .int) continue;
                        compindex = t[8].int;
                        screen_row_i = t[9].int;
                        screen_col_i = t[10].int;
                    }

                    var row_i64: i64 = 0;
                    var col_i64: i64 = 0;

                    // Extract anchor_grid (always at t[3] when present)
                    const anchor_grid = checkedGridId(if (t[3] == .int) t[3].int else 1) orelse continue;

                    if (screen_row_i >= 0 and screen_col_i >= 0) {
                        // Let nvim take care of positioning.
                        row_i64 = screen_row_i;
                        col_i64 = screen_col_i;
                    } else {
                        // Manual anchor mode: [anchor, anchor_grid, anchor_row, anchor_col]
                        // anchor_row/col may be int or float depending on nvim version.
                        if (t[2] != .str or t[3] != .int) continue;

                        // Need indices [4], [5] to exist
                        if (t.len < 6) continue;

                        const anchor = t[2].str;

                        var anchor_row_i: i64 = 0;
                        var anchor_col_i: i64 = 0;

                        if (t[4] == .int) {
                            anchor_row_i = t[4].int;
                        } else if (t[4] == .float) {
                            anchor_row_i = checkedFloatToI64(t[4].float) orelse continue;
                        } else {
                            continue;
                        }

                        if (t[5] == .int) {
                            anchor_col_i = t[5].int;
                        } else if (t[5] == .float) {
                            anchor_col_i = checkedFloatToI64(t[5].float) orelse continue;
                        } else {
                            continue;
                        }

                        var base_row: i64 = 0;
                        var base_col: i64 = 0;

                        if (anchor_grid != 1) {
                            if (grid.win_pos.get(anchor_grid)) |p| {
                                base_row = @as(i64, p.row);
                                base_col = @as(i64, p.col);
                            } else if (grid.external_grids.get(anchor_grid)) |ext| {
                                // anchor_grid is an external window - use its stored position
                                if (ext.start_row >= 0 and ext.start_col >= 0) {
                                    base_row = @as(i64, ext.start_row);
                                    base_col = @as(i64, ext.start_col);
                                }
                            }
                        }

                        // Adjust by anchor using goneovim-like metrics conversion.
                        // We compute float window size in "global grid cell units" using per-grid pixel metrics.
                        const main_m = grid.getGridMetricsPx(1);
                        const anchor_m = grid.getGridMetricsPx(anchor_grid);
                        const float_m = grid.getGridMetricsPx(grid_id);

                        // Convert anchor point from anchor_grid units -> global grid units.
                        // base_row/base_col are already in global grid units (win_pos is relative to grid=1).
                        const anchor_row_main = checkedFloatToI64(@as(f64, @floatFromInt(anchor_row_i)) * @as(f64, @floatFromInt(anchor_m.cell_h_px)) /
                            @as(f64, @floatFromInt(main_m.cell_h_px))) orelse continue;
                        const anchor_col_main = checkedFloatToI64(@as(f64, @floatFromInt(anchor_col_i)) * @as(f64, @floatFromInt(anchor_m.cell_w_px)) /
                            @as(f64, @floatFromInt(main_m.cell_w_px))) orelse continue;

                        row_i64 = std.math.add(i64, base_row, anchor_row_main) catch continue;
                        col_i64 = std.math.add(i64, base_col, anchor_col_main) catch continue;

                        // Compute float window size in global grid units (approx; future-proof for per-grid fonts).
                        if (grid.sub_grids.get(grid_id)) |sg| {
                            const float_rows: i64 = @as(i64, sg.rows);
                            const float_cols: i64 = @as(i64, sg.cols);

                            const wincols_main = checkedFloatToI64(@as(f64, @floatFromInt(float_cols)) * @as(f64, @floatFromInt(float_m.cell_w_px)) /
                                @as(f64, @floatFromInt(main_m.cell_w_px))) orelse continue;

                            const winrows_main = checkedFloatToI64(@ceil(@as(f64, @floatFromInt(float_rows)) * @as(f64, @floatFromInt(float_m.cell_h_px)) /
                                @as(f64, @floatFromInt(main_m.cell_h_px)))) orelse continue;

                            // Anchor string: "NW", "NE", "SW", "SE"
                            if (std.mem.indexOfScalar(u8, anchor, 'S') != null) {
                                row_i64 = std.math.sub(i64, row_i64, winrows_main) catch std.math.minInt(i64);
                            }
                            if (std.mem.indexOfScalar(u8, anchor, 'E') != null) {
                                col_i64 = std.math.sub(i64, col_i64, wincols_main) catch std.math.minInt(i64);
                            }
                        }
                    }

                    if (row_i64 < 0) row_i64 = 0;
                    if (col_i64 < 0) col_i64 = 0;

                    const row = checkedGridCoord(row_i64) orelse continue;
                    const col = checkedGridCoord(col_i64) orelse continue;

                    grid.setWinFloatPos(
                        grid_id,
                        win_id,
                        row,
                        col,
                        zindex,
                        compindex,
                        anchor_grid,
                    ) catch |err| switch (err) {
                        error.TooManyWindowPlacements => {
                            log.write("[win_float_pos] rejected grid={d}: TooManyWindowPlacements\n", .{grid_id});
                            return error.TooManyWindowPlacements;
                        },
                        else => return err,
                    };
                }
            },
            .win_external_pos => {
                // win_external_pos: [grid, win]
                // Marks a grid as "external" - to be displayed in a separate top-level window.
                for (tuples) |tv| {
                    if (tv != .arr) continue;
                    const t = tv.arr;

                    // Need at least: grid, win
                    if (t.len < 2) continue;
                    if (t[0] != .int or t[1] != .int) continue;

                    const grid_id = checkedGridId(t[0].int) orelse continue;
                    const win = t[1].int;

                    // Mark this grid as external
                    const is_new = grid.setWinExternalPos(grid_id, win) catch |err| switch (err) {
                        error.TooManyWindowPlacements => {
                            log.write("[win_external_pos] rejected grid={d}: TooManyWindowPlacements\n", .{grid_id});
                            return error.TooManyWindowPlacements;
                        },
                        else => return err,
                    };
                    _ = is_new; // Callback notification is handled by nvim_core after redraw processing
                }
            },
            .msg_set_pos => {
                // msg_set_pos: [grid, row, scrolled, sep_char, zindex, compindex]
                // The message grid is positioned on the default grid (grid=1) at the given row,
                // covering the full width. Treat it like an overlay layer (zindex is typically 200).
                for (tuples) |tv| {
                    if (tv != .arr) continue;
                    const t = tv.arr;

                    // log.write("msg_set_pos:\n", .{});

                    // Accept old/new msg_set_pos:
                    // old: [grid, row, scrolled, sep_char]
                    // new: [grid, row, scrolled, sep_char, zindex, compindex]
                    if (t.len < 4) continue;
                    if (t[0] != .int or t[1] != .int) continue;

                    const grid_id = checkedGridId(t[0].int) orelse continue;
                    const row_i = t[1].int;

                    var zindex: i64 = 200;
                    var compindex: i64 = 0;
                    if (t.len >= 6) {
                        if (t[4] != .int or t[5] != .int) continue;
                        zindex = t[4].int;
                        compindex = t[5].int;
                    }

                    const row = checkedGridCoord(row_i) orelse continue;
                    const col: u32 = 0;
                    // msg_set_pos has no win handle; pass 0 (no window mapping stored)
                    grid.setWinFloatPos(grid_id, 0, row, col, zindex, compindex, 1) catch |err| switch (err) {
                        error.TooManyWindowPlacements => {
                            log.write("msg_set_pos rejected grid={d}: TooManyWindowPlacements\n", .{grid_id});
                            return error.TooManyWindowPlacements;
                        },
                        else => return err,
                    };
                }
            },
            .grid_scroll => {
                for (tuples) |tv| {
                    if (tv != .arr) continue;
                    const t = tv.arr;
                    if (t.len < 7) continue;
                    if (t[0] != .int or t[1] != .int or t[2] != .int or t[3] != .int or t[4] != .int or t[5] != .int or t[6] != .int) continue;

                    const grid_id = checkedGridId(t[0].int) orelse continue;

                    const top = checkedU32(t[1].int) orelse continue;
                    const bot = checkedU32(t[2].int) orelse continue;
                    const left = checkedU32(t[3].int) orelse continue;
                    const right = checkedU32(t[4].int) orelse continue;
                    const rows = checkedI32(t[5].int) orelse continue;
                    const cols = checkedI32(t[6].int) orelse continue;

                    // No-op scroll: avoid touching dirty state for nothing.
                    // Neovim's spec reserves `cols` for future use (always 0
                    // today), so `rows == 0` alone is the authoritative signal
                    // that nothing visually changes — treat it as a no-op
                    // regardless of `cols`.
                    if (rows == 0) continue;

                    if (log.cb != null) {
                        var target_rows: u32 = grid.rows;
                        var target_cols: u32 = grid.cols;
                        if (grid_id != 1) {
                            if (grid.sub_grids.getPtr(grid_id)) |sg| {
                                target_rows = sg.rows;
                                target_cols = sg.cols;
                            }
                        }
                        log.write("[scroll_debug] grid_scroll grid={d} top={d} bot={d} left={d} right={d} rows={d} cols={d} target_rows={d} target_cols={d}\n", .{
                            grid_id, top, bot, left, right, rows, cols, target_rows, target_cols,
                        });
                        if (grid.input_trace_seq != 0 and grid.input_trace_first_grid_event_logged_seq != grid.input_trace_seq) {
                            const now_ns = clock.nowNs();
                            const delta_us: i64 = @intCast(@divTrunc(@max(@as(i128, 0), now_ns - @as(i128, grid.input_trace_sent_ns)), 1000));
                            log.write("[perf_input] seq={d} stage=grid_scroll delta_us={d} grid={d}\n", .{
                                grid.input_trace_seq, delta_us, grid_id,
                            });
                            grid.input_trace_first_grid_event_logged_seq = grid.input_trace_seq;
                        }
                    }

                    // Apply scroll to the target grid under ext_multigrid.
                    grid.scrollGrid(grid_id, top, bot, left, right, rows, cols);
                    grid.creditScrollCoverage(grid_id, rows);
                }
            },
            .hl_attr_define => {
                for (tuples) |tv| {
                    if (tv != .arr) continue;
                    const t = tv.arr;
                    if (t.len < 2) continue;
                    if (t[0] != .int) continue;

                    const id_u32: u32 = checkedU32(t[0].int) orelse continue;

                    if (t[1] == .map) {
                        const m = t[1].map;

                        const fg = toRgbOpt(mapGetInt(m, "foreground"));
                        const bg = toRgbOpt(mapGetInt(m, "background"));
                        const sp = toRgbOpt(mapGetInt(m, "special"));

                        const reverse = mapGetBool(m, "reverse") orelse false;

                        var blend_u8: u8 = 0;
                        if (mapGetInt(m, "blend")) |b64| {
                            var b = b64;
                            if (b < 0) b = 0;
                            if (b > 100) b = 100;
                            blend_u8 = @as(u8, @intCast(b));
                        }

                        const styles: Styles = .{
                            .italic = mapGetBool(m, "italic") orelse false,
                            .bold = mapGetBool(m, "bold") orelse false,
                            .strikethrough = mapGetBool(m, "strikethrough") orelse false,
                            .underline = mapGetBool(m, "underline") orelse false,
                            .undercurl = mapGetBool(m, "undercurl") orelse false,
                            .underdouble = mapGetBool(m, "underdouble") orelse false,
                            .underdotted = mapGetBool(m, "underdotted") orelse false,
                            .underdashed = mapGetBool(m, "underdashed") orelse false,
                            .overline = mapGetBool(m, "overline") orelse false,
                        };

                        const has_url = (mapGetStr(m, "url") != null);

                        try hl.define(id_u32, fg, bg, sp, reverse, blend_u8, styles, has_url);
                    } else {
                        try hl.define(id_u32, null, null, null, false, 0, Styles{}, false);
                    }
                }
            },
            .hl_group_set => {
                for (tuples) |tv| {
                    if (tv != .arr) continue;
                    const t = tv.arr;
                    if (t.len < 2) continue;
                    if (t[0] != .str or t[1] != .int) continue;

                    const group_name = t[0].str;
                    const hl_id_u32: u32 = checkedU32(t[1].int) orelse continue;
                    try hl.setGroup(group_name, hl_id_u32);
                }
            },
            .default_colors_set => {
                for (tuples) |tv| {
                    if (tv != .arr) continue;
                    const t = tv.arr;
                    if (t.len < 2) continue;

                    const fg = if (t[0] == .int) toRgbOpt(t[0].int) else null;
                    const bg = if (t[1] == .int) toRgbOpt(t[1].int) else null;
                    const sp = if (t.len >= 3 and t[2] == .int) toRgbOpt(t[2].int) else null;
                    hl.setDefaults(fg, bg, sp);

                    if (default_colors_fn) |dcf| {
                        try dcf(opt_ctx, fg orelse 0xFFFFFFFF, bg orelse 0xFFFFFFFF);
                    }
                }
            },
            .option_set => {
                for (tuples) |tv| {
                    if (tv != .arr) continue;
                    const t = tv.arr;
                    if (t.len < 2) continue;
                    if (t[0] != .str) continue;

                    const opt_name = t[0].str;
                    // Per-option timing. option_set fires rarely (startup + :set)
                    // so per-call logging is acceptable. The aggregate redraw_event
                    // line shows option_set as a 57ms outlier; this breakdown
                    // points at the specific option doing the heavy lifting
                    // (typically guifont triggers atlas reset + font rebuild).
                    const log_on_opt = log.cb != null;
                    const t_opt_start: i128 = if (log_on_opt) clock.nowNs() else 0;
                    defer if (log_on_opt) {
                        const dt_us: i64 = @intCast(@divTrunc(@max(0, clock.nowNs() - t_opt_start), 1000));
                        log.write("[perf] option_set name={s} us={d}\n", .{ opt_name, dt_us });
                    };

                    // switch (t[1]) {
                    //     .str => {
                    //         const v = t[1].str;
                    //         const n = @min(v.len, 120);
                    //         log.write("option_set {s} = '{s}' (len={d})\n", .{ opt_name, v[0..n], v.len });
                    //     },
                    //     .int => log.write("option_set {s} = {d}\n", .{ opt_name, t[1].int }),
                    //     .bool => log.write("option_set {s} = {any}\n", .{ opt_name, t[1].bool }),
                    //     .nil => log.write("option_set {s} = nil\n", .{ opt_name }),
                    //     else => log.write("option_set {s} = <{s}>\n", .{ opt_name, @tagName(t[1]) }),
                    // }

                    if (std.mem.eql(u8, opt_name, "guifont")) {
                        if (t[1] != .str) {
                            if (log.cb != null) log.write("guifont option_set had non-string value tag={s}\n", .{@tagName(t[1])});
                            continue;
                        }

                        const raw = t[1].str;

                        if (std.mem.eql(u8, raw, "*")) {
                            if (log.cb != null) log.write("guifont: request picker '*'\n", .{});
                            try guifont_fn(opt_ctx, raw);
                            continue;
                        }

                        if (raw.len == 0) {
                            if (log.cb != null) log.write("guifont: empty -> notify frontend\n", .{});
                            // Notify frontend with empty name and size 0 - it will use config/OS default for both.
                            const msg = try std.fmt.allocPrint(arena, "\t0", .{});
                            try guifont_fn(opt_ctx, msg);
                            continue;
                        }

                        const list = try parseGuiFontList(arena, raw);
                        if (log.cb != null) log.write("guifont: {d} candidate(s)\n", .{list.items.len});

                        // Build a single newline-separated string of all resolved
                        // candidates and notify the frontend once.  The frontend
                        // tries each entry in order and uses the first loadable font.
                        var combined: std.ArrayListUnmanaged(u8) = .empty;
                        for (list.items, 0..) |cand, idx| {
                            const resolved = try parseGuiFontCandidate(arena, cand);
                            const msg = try formatResolvedGuiFont(arena, resolved);
                            if (log.cb != null) log.write("guifont resolved: '{s}'\n", .{msg});
                            if (idx > 0) try combined.append(arena, '\n');
                            try combined.appendSlice(arena, msg);
                        }
                        try guifont_fn(opt_ctx, combined.items);
                    }

                    if (std.mem.eql(u8, opt_name, "linespace")) {
                        // Neovim sends integer pixels.
                        // Default is 0 (no extra leading).
                        var px_i32: i32 = 0;

                        switch (t[1]) {
                            .int => {
                                px_i32 = linespacePxFromWire(t[1].int);
                            },
                            .nil => {
                                px_i32 = 0;
                            },
                            else => {
                                if (log.cb != null) log.write("linespace option_set had non-int value tag={s}\n", .{@tagName(t[1])});
                                continue;
                            },
                        }

                        try linespace_fn(linespace_ctx, px_i32);
                    }
                }
            },
            .mode_info_set => {
                // ["mode_info_set", cursor_style_enabled, mode_info]
                for (tuples) |tv| {
                    if (tv != .arr) continue;
                    const t = tv.arr;
                    if (t.len < 2) continue;

                    const enabled = (t[0] == .int and t[0].int != 0) or (t[0] == .bool and t[0].bool);
                    grid.cursor_style_enabled = enabled;

                    if (t[1] != .arr) continue;
                    const arr = t[1].arr;

                    grid.mode_infos.clearRetainingCapacity();
                    try grid.mode_infos.ensureTotalCapacity(grid.alloc, arr.len);

                    for (arr, 0..) |mv, mode_idx| {
                        var mi: ModeInfo = .{};
                        if (mv == .map) {
                            const m = mv.map;

                            if (mapGetStr(m, "cursor_shape")) |s| {
                                if (std.mem.eql(u8, s, "block")) mi.shape = .block else if (std.mem.eql(u8, s, "vertical")) mi.shape = .vertical else if (std.mem.eql(u8, s, "horizontal")) mi.shape = .horizontal;
                                // Debug: log parsed shape
                                if (log.cb != null) {
                                    log.write("  parse mode[{d}]: cursor_shape='{s}' -> {s}\n", .{
                                        mode_idx, s, @tagName(mi.shape),
                                    });
                                }
                            }
                            if (mapGetInt(m, "cell_percentage")) |p64| {
                                var p = p64;
                                if (p <= 0) p = 100;
                                if (p > 100) p = 100;
                                mi.cell_percentage = @as(u8, @intCast(p));
                            }
                            if (mapGetInt(m, "attr_id")) |a64| {
                                mi.attr_id = checkedU32(a64) orelse 0;
                            }
                            // Parse blink parameters
                            if (mapGetInt(m, "blinkwait")) |bw| {
                                mi.blink_wait_ms = checkedU32(bw) orelse 0;
                            }
                            if (mapGetInt(m, "blinkon")) |bon| {
                                mi.blink_on_ms = checkedU32(bon) orelse 0;
                            }
                            if (mapGetInt(m, "blinkoff")) |boff| {
                                mi.blink_off_ms = checkedU32(boff) orelse 0;
                            }
                        } else {
                            // Debug: mv is not a map
                            if (log.cb != null) {
                                log.write("  parse mode[{d}]: NOT a map!\n", .{mode_idx});
                            }
                        }
                        grid.mode_infos.appendAssumeCapacity(mi);
                    }

                    // Debug log: mode_info_set processed
                    if (log.cb != null) {
                        log.write("mode_info_set: enabled={} mode_count={d}\n", .{
                            grid.cursor_style_enabled,
                            grid.mode_infos.items.len,
                        });
                        for (grid.mode_infos.items, 0..) |mi2, i| {
                            log.write("  mode[{d}]: shape={s} cell_pct={d} attr_id={d}\n", .{
                                i,
                                @tagName(mi2.shape),
                                mi2.cell_percentage,
                                mi2.attr_id,
                            });
                        }
                    }
                }
                // The table just changed under the current mode (`:set guicursor`).
                // Neovim sends no mode_change for it, so re-resolve the live style
                // here or the cursor keeps its old shape until the mode changes.
                applyModeInfo(grid, grid.current_mode_idx);
                grid.cursor_rev +%= 1;
            },
            .mode_change => {
                // ["mode_change", mode, mode_idx]
                for (tuples) |tv| {
                    if (tv != .arr) continue;
                    const t = tv.arr;
                    if (t.len < 2) continue;
                    if (t[1] != .int) continue;

                    const idx64 = t[1].int;
                    if (idx64 < 0) continue;
                    const idx = std.math.cast(usize, idx64) orelse continue;

                    grid.current_mode_idx = idx;

                    applyModeInfo(grid, idx);

                    // Debug log: mode_change processed
                    if (log.cb != null) {
                        log.write("mode_change: idx={d} cursor_style_enabled={} shape={s} cell_pct={d} blink=({d},{d},{d})\n", .{
                            idx,
                            grid.cursor_style_enabled,
                            @tagName(grid.cursor_shape),
                            grid.cursor_cell_percentage,
                            grid.cursor_blink_wait_ms,
                            grid.cursor_blink_on_ms,
                            grid.cursor_blink_off_ms,
                        });
                    }

                    // Store mode name for external queries (e.g., terminal mode detection)
                    if (t[0] == .str) {
                        const mode_str = t[0].str;
                        // Copy mode name to fixed buffer (null-terminated)
                        const copy_len = @min(mode_str.len, grid.current_mode_name.len - 1);
                        @memcpy(grid.current_mode_name[0..copy_len], mode_str[0..copy_len]);
                        grid.current_mode_name[copy_len] = 0; // null terminate
                    }

                    // Clear showmode when exiting insert/replace mode
                    // Neovim doesn't always send empty msg_showmode on mode exit
                    if (t[0] == .str) {
                        const mode_str = t[0].str;
                        // Check if mode is NOT insert-related (i, R, Rv, etc.)
                        const is_insert_mode = mode_str.len > 0 and
                            (mode_str[0] == 'i' or mode_str[0] == 'R');
                        if (!is_insert_mode and grid.message_state.showmode_content.items.len > 0) {
                            // Clear showmode content
                            for (grid.message_state.showmode_content.items) |chunk| {
                                if (chunk.text.len > 0) grid.alloc.free(chunk.text);
                            }
                            grid.message_state.showmode_content.clearRetainingCapacity();
                            grid.message_state.showmode_dirty = true;
                            if (log.cb != null) log.write("mode_change: cleared showmode (mode={s})\n", .{mode_str});
                        }
                    }
                }
                // Request IME off on any mode change (config check done by nvim_core)
                grid.ime_off_requested = true;
                grid.cursor_rev +%= 1;
            },
            .busy_start => {
                grid.cursor_visible = false;
                grid.cursor_rev +%= 1;
            },
            .busy_stop => {
                grid.cursor_visible = true;
                grid.cursor_rev +%= 1;
            },
            .grid_line => {
                if (log_on_batch) grid_line_tuple_total +%= @intCast(tuples.len);
                for (tuples) |tv| {
                    if (tv != .arr) continue;
                    const t = tv.arr;
                    if (t.len < 5) continue;
                    if (t[0] != .int or t[1] != .int or t[2] != .int) continue;
                    if (t[3] != .arr) continue;

                    const grid_id = checkedGridId(t[0].int) orelse continue;

                    if (log.cb != null and grid.input_trace_seq != 0 and grid.input_trace_first_grid_event_logged_seq != grid.input_trace_seq) {
                        const now_ns = clock.nowNs();
                        const delta_us: i64 = @intCast(@divTrunc(@max(@as(i128, 0), now_ns - @as(i128, grid.input_trace_sent_ns)), 1000));
                        log.write("[perf_input] seq={d} stage=grid_line delta_us={d} grid={d} row={d}\n", .{
                            grid.input_trace_seq, delta_us, grid_id, t[1].int,
                        });
                        grid.input_trace_first_grid_event_logged_seq = grid.input_trace_seq;
                    }

                    const row = checkedU32(t[1].int) orelse continue;
                    var col = checkedU32(t[2].int) orelse continue;

                    // Update order (existing behavior)
                    grid.noteGridLine(grid_id, redraw_epoch);

                    const cells = t[3].arr;

                    // Resolved once per grid_line tuple (grid_id is constant within
                    // it); used by the repeat clamp below. A per-cell sub_grids
                    // lookup here would be a hash probe on the grid_line hot path.
                    const grid_cols: u32 = if (grid_id == 1)
                        grid.cols
                    else if (grid.sub_grids.get(grid_id)) |sg|
                        sg.cols
                    else
                        0;

                    // "hl" is a state that persists across cell tuples within THIS grid_line event.
                    // - If hl is omitted, keep previous hl value.
                    // - If hl == -1, inherit from left cell at write time (except col==0).
                    //
                    // NOTE:
                    // Neovim help says the first cell in the event always includes hl_id, but we still
                    // implement the state machine safely.
                    var hl_state: i64 = 0;

                    for (cells) |cellv| {
                        if (cellv != .arr) continue;
                        const c = cellv.arr;
                        if (c.len < 1 or c[0] != .str) continue;

                        // Extract all codepoints from the cell string.
                        // If >1 codepoint (e.g., U+26A0 + U+FE0F), extras go to overflow map.
                        var cp_buf: [16]u32 = undefined;
                        const extracted = extractCellCodepoints(c[0].str, &cp_buf);
                        const cp_count = extracted.count;
                        if (extracted.replaced_oversized) {
                            log.write("[redraw] oversized grid_line cluster grid={d} row={d} col={d} bytes={d}; using U+FFFD\n", .{
                                grid_id, row, col, c[0].str.len,
                            });
                        }
                        const cp = cp_buf[0];
                        const has_overflow = cp_count > 1;

                        // Update hl_state only when provided.
                        if (c.len >= 2 and c[1] == .int) {
                            hl_state = c[1].int; // may be -1
                        }

                        // repeat:
                        // - If not present: 1
                        // - If present and == 0: write NOTHING (this is important; do not treat as 1)
                        // - If present and > 0: repeat times
                        var repeat: u32 = 1;
                        if (c.len >= 3 and c[2] == .int) {
                            const r64 = c[2].int;
                            if (r64 <= 0) {
                                // repeat==0 => no-op; repeat<0 => treat as no-op as well
                                continue;
                            }
                            repeat = checkedU32(r64) orelse continue;
                        }

                        // Always clamp, including an omitted or malformed
                        // repeat which defaults to one. Keeping this outside
                        // the optional repeat branch also rejects col >= cols
                        // before col += 1 can overflow.
                        repeat = clampGridLineRepeat(col, grid_cols, repeat);
                        if (repeat == 0) continue;

                        if (log_on_batch) grid_line_cells_total +%= repeat;
                        var i: u32 = 0;
                        while (i < repeat) : (i += 1) {
                            var hl_to_use: u32 = 0;

                            // goneovim-compatible behavior:
                            // if hl != -1 OR col == 0 -> use hl
                            // else -> inherit from left cell
                            if (hl_state != -1 or col == 0) {
                                if (hl_state >= 0) {
                                    // A malformed/malicious redraw event can carry an
                                    // hl_id beyond u32; a raw @intCast would panic the
                                    // render thread. Out-of-range ids fall back to 0
                                    // (default hl) — the hl table is u32-keyed anyway.
                                    hl_to_use = std.math.cast(u32, hl_state) orelse 0;
                                } else {
                                    // hl_state can be -1 here only when col==0; treat as 0.
                                    hl_to_use = 0;
                                }
                            } else {
                                // hl_state == -1 and col > 0 -> inherit from left cell
                                hl_to_use = grid.getCellHLGrid(grid_id, row, col - 1);
                            }

                            try grid.putCellGridCluster(
                                grid_id,
                                row,
                                col,
                                cp,
                                hl_to_use,
                                if (has_overflow) cp_buf[1..cp_count] else &.{},
                            );

                            col += 1;
                        }
                    }
                }

                // =====================================================================
                // ext_cmdline events
                // =====================================================================
            },
            .cmdline_show => {
                // cmdline_show: [[content, pos, firstc, prompt, indent, level, hl_id], ...]
                // content is array of [attr, text, hl_id] tuples
                for (tuples) |tv| {
                    if (tv != .arr) continue;
                    const t = tv.arr;
                    if (t.len < 5) continue;

                    // Parse content (array of [attrs, text] or [attrs, text, hl_id])
                    var chunks: std.ArrayListUnmanaged(CmdlineChunk) = .empty;
                    if (t[0] == .arr) {
                        for (t[0].arr) |chunk_v| {
                            if (chunk_v != .arr) continue;
                            const chunk = chunk_v.arr;
                            if (chunk.len < 2) continue;

                            // chunk[0] is attrs (map or int for hl_id)
                            // chunk[1] is text
                            const hl_id: u32 = if (chunk[0] == .int) (checkedU32(chunk[0].int) orelse 0) else 0;
                            const text: []const u8 = if (chunk[1] == .str) chunk[1].str else "";
                            try chunks.append(arena, CmdlineChunk{ .hl_id = hl_id, .text = text });
                        }
                    }

                    const pos: u32 = if (t[1] == .int) (checkedU32(t[1].int) orelse 0) else 0;
                    const firstc: u8 = if (t[2] == .str and t[2].str.len > 0) t[2].str[0] else 0;
                    const prompt: []const u8 = if (t[3] == .str) t[3].str else "";
                    const indent: u32 = if (t[4] == .int) (checkedU32(t[4].int) orelse 0) else 0;
                    const level: u32 = if (t.len > 5 and t[5] == .int and t[5].int >= 1) (checkedU32(t[5].int) orelse 1) else 1;
                    const prompt_hl_id: u32 = if (t.len > 6 and t[6] == .int) (checkedU32(t[6].int) orelse 0) else 0;

                    try grid.setCmdlineShow(chunks.items, pos, firstc, prompt, indent, level, prompt_hl_id);
                    if (log.cb != null) log.write("cmdline_show pos={d} firstc={c} level={d}\n", .{ pos, firstc, level });
                }
            },
            .cmdline_hide => {
                // cmdline_hide: [[level], ...] or [level, abort]
                for (tuples) |tv| {
                    if (tv != .arr) continue;
                    const t = tv.arr;

                    const level: u32 = if (t.len >= 1 and t[0] == .int and t[0].int >= 1) (checkedU32(t[0].int) orelse 1) else 1;

                    grid.setCmdlineHide(level);
                    if (log.cb != null) log.write("cmdline_hide level={d}\n", .{level});
                }
            },
            .cmdline_pos => {
                // cmdline_pos: [[pos, level], ...]
                for (tuples) |tv| {
                    if (tv != .arr) continue;
                    const t = tv.arr;
                    if (t.len < 2) continue;
                    if (t[0] != .int or t[1] != .int) continue;

                    const pos: u32 = checkedU32(t[0].int) orelse 0;
                    const level: u32 = if (t[1].int >= 1) (checkedU32(t[1].int) orelse 1) else 1;

                    grid.setCmdlinePos(pos, level);
                    if (log.cb != null) log.write("cmdline_pos pos={d} level={d}\n", .{ pos, level });
                }
            },
            .cmdline_special_char => {
                // cmdline_special_char: [[c, shift, level], ...]
                for (tuples) |tv| {
                    if (tv != .arr) continue;
                    const t = tv.arr;
                    if (t.len < 3) continue;

                    const c: []const u8 = if (t[0] == .str) t[0].str else "";
                    const shift: bool = if (t[1] == .bool) t[1].bool else false;
                    const level: u32 = if (t[2] == .int and t[2].int >= 1) (checkedU32(t[2].int) orelse 1) else 1;

                    grid.setCmdlineSpecialChar(c, shift, level);
                    if (log.cb != null) {
                        log.write("cmdline_special_char c=\"{s}\" len={d} shift={} level={d}\n", .{ c, c.len, shift, level });
                        // Log bytes for debugging
                        if (c.len > 0) {
                            log.write("cmdline_special_char bytes: ", .{});
                            for (c) |b| {
                                log.write("0x{x:0>2} ", .{b});
                            }
                            log.write("\n", .{});
                        }
                    }
                }
            },
            .cmdline_block_show => {
                // cmdline_block_show: [[lines], ...]
                // lines is array of arrays of [attrs, text] tuples (same format as cmdline content)
                for (tuples) |tv| {
                    if (tv != .arr) continue;
                    const t = tv.arr;
                    if (t.len < 1) continue;
                    if (t[0] != .arr) continue;

                    var lines: std.ArrayListUnmanaged([]const CmdlineChunk) = .empty;
                    for (t[0].arr) |line_v| {
                        if (line_v != .arr) continue;
                        var line_chunks: std.ArrayListUnmanaged(CmdlineChunk) = .empty;
                        for (line_v.arr) |chunk_v| {
                            if (chunk_v != .arr) continue;
                            const chunk = chunk_v.arr;
                            if (chunk.len < 2) continue;

                            const hl_id: u32 = if (chunk[0] == .int) (checkedU32(chunk[0].int) orelse 0) else 0;
                            const text: []const u8 = if (chunk[1] == .str) chunk[1].str else "";
                            try line_chunks.append(arena, CmdlineChunk{ .hl_id = hl_id, .text = text });
                        }
                        try lines.append(arena, line_chunks.items);
                    }

                    try grid.setCmdlineBlockShow(lines.items);
                    if (log.cb != null) log.write("cmdline_block_show lines={d}\n", .{lines.items.len});
                }
            },
            .cmdline_block_append => {
                // cmdline_block_append: [[line], ...]
                for (tuples) |tv| {
                    if (tv != .arr) continue;
                    const t = tv.arr;
                    if (t.len < 1) continue;
                    if (t[0] != .arr) continue;

                    var line_chunks: std.ArrayListUnmanaged(CmdlineChunk) = .empty;
                    for (t[0].arr) |chunk_v| {
                        if (chunk_v != .arr) continue;
                        const chunk = chunk_v.arr;
                        if (chunk.len < 2) continue;

                        const hl_id: u32 = if (chunk[0] == .int) (checkedU32(chunk[0].int) orelse 0) else 0;
                        const text: []const u8 = if (chunk[1] == .str) chunk[1].str else "";
                        try line_chunks.append(arena, CmdlineChunk{ .hl_id = hl_id, .text = text });
                    }

                    try grid.appendCmdlineBlock(line_chunks.items);
                    if (log.cb != null) log.write("cmdline_block_append\n", .{});
                }
            },
            .cmdline_block_hide => {
                // cmdline_block_hide: []
                grid.hideCmdlineBlock();
                if (log.cb != null) log.write("cmdline_block_hide\n", .{});

                // =====================================================================
                // ext_popupmenu events
                // =====================================================================
            },
            .popupmenu_show => {
                // popupmenu_show: [[items, selected, row, col, grid], ...]
                // items: [[word, kind, menu, info], ...]
                for (tuples) |tv| {
                    if (tv != .arr) continue;
                    const t = tv.arr;
                    if (t.len < 5) continue;

                    // Parse items array
                    var items: std.ArrayListUnmanaged(PopupmenuItem) = .empty;
                    if (t[0] == .arr) {
                        for (t[0].arr) |item_v| {
                            if (item_v != .arr) continue;
                            const item = item_v.arr;
                            // Each item is [word, kind, menu, info]
                            const word: []const u8 = if (item.len > 0 and item[0] == .str) item[0].str else "";
                            const kind: []const u8 = if (item.len > 1 and item[1] == .str) item[1].str else "";
                            const menu: []const u8 = if (item.len > 2 and item[2] == .str) item[2].str else "";
                            const info: []const u8 = if (item.len > 3 and item[3] == .str) item[3].str else "";

                            try items.append(arena, PopupmenuItem{
                                .word = word,
                                .kind = kind,
                                .menu = menu,
                                .info = info,
                            });
                        }
                    }

                    const selected: i32 = if (t[1] == .int) (checkedI32(t[1].int) orelse -1) else -1;
                    const row: i32 = if (t[2] == .int) (checkedI32(t[2].int) orelse 0) else 0;
                    const col: i32 = if (t[3] == .int) (checkedI32(t[3].int) orelse 0) else 0;
                    const raw_grid_id: i64 = if (t[4] == .int) t[4].int else 1;
                    // -1 is the documented ext_cmdline anchor sentinel. All
                    // real Neovim grid handles must fit the Metal i32 domain.
                    const grid_id = if (raw_grid_id == -1)
                        raw_grid_id
                    else
                        checkedGridId(raw_grid_id) orelse continue;

                    try grid.setPopupmenuShow(items.items, selected, row, col, grid_id);
                    if (log.cb != null) log.write("popupmenu_show items={d} selected={d} row={d} col={d} grid={d}\n", .{ items.items.len, selected, row, col, grid_id });
                }
            },
            .popupmenu_hide => {
                // popupmenu_hide: []
                grid.setPopupmenuHide();
                if (log.cb != null) log.write("popupmenu_hide\n", .{});
            },
            .popupmenu_select => {
                // popupmenu_select: [[selected], ...]
                for (tuples) |tv| {
                    if (tv != .arr) continue;
                    const t = tv.arr;
                    if (t.len < 1) continue;

                    const selected: i32 = if (t[0] == .int) (checkedI32(t[0].int) orelse -1) else -1;
                    grid.setPopupmenuSelect(selected);
                    if (log.cb != null) log.write("popupmenu_select selected={d}\n", .{selected});
                }
            },
            .tabline_update => {
                // tabline_update: [[curtab, tabs, curbuf, buffers], ...]
                // tabs: [{tab: Integer, name: String}, ...]
                // buffers: [{buffer: Integer, name: String}, ...]
                for (tuples) |tv| {
                    if (tv != .arr) continue;
                    const t = tv.arr;
                    if (t.len < 4) continue;

                    // curtab can be int or ext type
                    const curtab: i64 = if (t[0] == .int) t[0].int else if (t[0] == .ext) parseExtHandle(t[0].ext) else 0;

                    // Parse tabs array
                    var tabs: std.ArrayListUnmanaged(TabEntry) = .empty;
                    if (t[1] == .arr) {
                        for (t[1].arr) |tab_v| {
                            if (tab_v != .map) continue;
                            const tab_map = tab_v.map;
                            var tab_handle: i64 = 0;
                            var tab_name: []const u8 = "";
                            for (tab_map) |pair| {
                                if (pair.key == .str) {
                                    if (std.mem.eql(u8, pair.key.str, "tab")) {
                                        tab_handle = if (pair.val == .int) pair.val.int else if (pair.val == .ext) parseExtHandle(pair.val.ext) else 0;
                                    } else if (std.mem.eql(u8, pair.key.str, "name")) {
                                        tab_name = if (pair.val == .str) pair.val.str else "";
                                    }
                                }
                            }
                            try tabs.append(arena, TabEntry{
                                .tab_handle = tab_handle,
                                .name = tab_name,
                            });
                        }
                    }

                    // curbuf can be int or ext type
                    const curbuf: i64 = if (t[2] == .int) t[2].int else if (t[2] == .ext) parseExtHandle(t[2].ext) else 0;

                    // Parse buffers array
                    var buffers: std.ArrayListUnmanaged(BufferEntry) = .empty;
                    if (t[3] == .arr) {
                        for (t[3].arr) |buf_v| {
                            if (buf_v != .map) continue;
                            const buf_map = buf_v.map;
                            var buffer_handle: i64 = 0;
                            var buf_name: []const u8 = "";
                            for (buf_map) |pair| {
                                if (pair.key == .str) {
                                    if (std.mem.eql(u8, pair.key.str, "buffer")) {
                                        buffer_handle = if (pair.val == .int) pair.val.int else if (pair.val == .ext) parseExtHandle(pair.val.ext) else 0;
                                    } else if (std.mem.eql(u8, pair.key.str, "name")) {
                                        buf_name = if (pair.val == .str) pair.val.str else "";
                                    }
                                }
                            }
                            try buffers.append(arena, BufferEntry{
                                .buffer_handle = buffer_handle,
                                .name = buf_name,
                            });
                        }
                    }

                    try grid.setTablineUpdate(curtab, tabs.items, curbuf, buffers.items);
                    if (log.cb != null) log.write("tabline_update curtab={d} tabs={d} curbuf={d} buffers={d}\n", .{ curtab, tabs.items.len, curbuf, buffers.items.len });
                }
            },
            .msg_show => {
                // msg_show: [[kind, content, replace_last, history, append, msg_id], ...]
                // content: [[attr_id, text_chunk, hl_id], ...]
                for (tuples) |tv| {
                    if (tv != .arr) continue;
                    const t = tv.arr;
                    if (t.len < 2) continue;

                    const kind: []const u8 = if (t[0] == .str) t[0].str else "";

                    // Parse content array
                    var chunks: std.ArrayListUnmanaged(MsgChunk) = .empty;
                    if (t[1] == .arr) {
                        for (t[1].arr) |chunk_v| {
                            if (chunk_v != .arr) continue;
                            const chunk = chunk_v.arr;
                            // Each chunk is [attr_id, text_chunk] or [attr_id, text_chunk, hl_id]
                            // attr_id is typically the highlight id
                            const hl_id: u32 = if (chunk.len > 0 and chunk[0] == .int) (checkedU32(chunk[0].int) orelse 0) else 0;
                            const text: []const u8 = if (chunk.len > 1 and chunk[1] == .str) chunk[1].str else "";

                            try chunks.append(arena, MsgChunk{
                                .hl_id = hl_id,
                                .text = text,
                            });
                        }
                    }

                    const replace_last: bool = if (t.len > 2 and t[2] == .bool) t[2].bool else false;
                    const history: bool = if (t.len > 3 and t[3] == .bool) t[3].bool else false;
                    const append_flag: bool = if (t.len > 4 and t[4] == .bool) t[4].bool else false;
                    const msg_id: i64 = if (t.len > 5 and t[5] == .int) t[5].int else 0;

                    try grid.setMsgShow(kind, chunks.items, replace_last, history, append_flag, msg_id);
                    if (log.cb != null) log.write("msg_show kind={s} chunks={d} replace_last={} history={} append={} msg_id={d}\n", .{ kind, chunks.items.len, replace_last, history, append_flag, msg_id });
                }
            },
            .msg_clear => {
                // msg_clear: []
                grid.setMsgClear();
                if (log.cb != null) log.write("msg_clear\n", .{});
            },
            .msg_showmode => {
                // msg_showmode: [[content], ...]
                for (tuples) |tv| {
                    if (tv != .arr) continue;
                    const t = tv.arr;

                    var chunks: std.ArrayListUnmanaged(MsgChunk) = .empty;
                    if (t.len > 0 and t[0] == .arr) {
                        for (t[0].arr) |chunk_v| {
                            if (chunk_v != .arr) continue;
                            const chunk = chunk_v.arr;
                            const hl_id: u32 = if (chunk.len > 0 and chunk[0] == .int) (checkedU32(chunk[0].int) orelse 0) else 0;
                            const text: []const u8 = if (chunk.len > 1 and chunk[1] == .str) chunk[1].str else "";
                            try chunks.append(arena, MsgChunk{ .hl_id = hl_id, .text = text });
                        }
                    }
                    try grid.setMsgShowmode(chunks.items);
                    if (log.cb != null) log.write("msg_showmode chunks={d}\n", .{chunks.items.len});
                }
            },
            .msg_showcmd => {
                // msg_showcmd: [[content], ...]
                for (tuples) |tv| {
                    if (tv != .arr) continue;
                    const t = tv.arr;

                    var chunks: std.ArrayListUnmanaged(MsgChunk) = .empty;
                    if (t.len > 0 and t[0] == .arr) {
                        for (t[0].arr) |chunk_v| {
                            if (chunk_v != .arr) continue;
                            const chunk = chunk_v.arr;
                            const hl_id: u32 = if (chunk.len > 0 and chunk[0] == .int) (checkedU32(chunk[0].int) orelse 0) else 0;
                            const text: []const u8 = if (chunk.len > 1 and chunk[1] == .str) chunk[1].str else "";
                            try chunks.append(arena, MsgChunk{ .hl_id = hl_id, .text = text });
                        }
                    }
                    try grid.setMsgShowcmd(chunks.items);
                    if (log.cb != null) log.write("msg_showcmd chunks={d}\n", .{chunks.items.len});
                }
            },
            .msg_ruler => {
                // msg_ruler: [[content], ...]
                for (tuples) |tv| {
                    if (tv != .arr) continue;
                    const t = tv.arr;

                    var chunks: std.ArrayListUnmanaged(MsgChunk) = .empty;
                    if (t.len > 0 and t[0] == .arr) {
                        for (t[0].arr) |chunk_v| {
                            if (chunk_v != .arr) continue;
                            const chunk = chunk_v.arr;
                            const hl_id: u32 = if (chunk.len > 0 and chunk[0] == .int) (checkedU32(chunk[0].int) orelse 0) else 0;
                            const text: []const u8 = if (chunk.len > 1 and chunk[1] == .str) chunk[1].str else "";
                            try chunks.append(arena, MsgChunk{ .hl_id = hl_id, .text = text });
                        }
                    }
                    try grid.setMsgRuler(chunks.items);
                    if (log.cb != null) log.write("msg_ruler chunks={d}\n", .{chunks.items.len});
                }
            },
            .msg_history_show => {
                // msg_history_show: [[entries, prev_cmd], ...]
                // entries: [[kind, content, append], ...]
                // content: [[hl_id, text], ...]
                if (log.cb != null) log.write("msg_history_show: tuples.len={d}\n", .{tuples.len});
                for (tuples, 0..) |tv, ti| {
                    if (log.cb != null) log.write("  tuple[{d}] type={s}\n", .{ ti, @tagName(tv) });
                    if (tv != .arr) continue;
                    const t = tv.arr;
                    if (log.cb != null) log.write("  tuple[{d}].len={d}\n", .{ ti, t.len });
                    if (t.len < 1) continue;

                    if (log.cb != null) log.write("  t[0] type={s}\n", .{@tagName(t[0])});

                    // Parse entries array
                    var entries: std.ArrayListUnmanaged(grid_mod.MsgHistoryEntry) = .empty;
                    if (t[0] == .arr) {
                        if (log.cb != null) log.write("  t[0].arr.len={d}\n", .{t[0].arr.len});
                        for (t[0].arr, 0..) |entry_v, ei| {
                            if (log.cb != null) log.write("    entry[{d}] type={s}\n", .{ ei, @tagName(entry_v) });
                            if (entry_v != .arr) continue;
                            const entry = entry_v.arr;
                            if (log.cb != null) log.write("    entry[{d}].len={d}\n", .{ ei, entry.len });
                            // entry: [kind, content] or [kind, content, append]
                            if (entry.len < 2) {
                                if (log.cb != null) log.write("    entry[{d}] skipped (len < 2)\n", .{ei});
                                continue;
                            }

                            const kind: []const u8 = if (entry[0] == .str) entry[0].str else "";

                            // Parse content array [[hl_id, text], ...]
                            var chunks: std.ArrayListUnmanaged(MsgChunk) = .empty;
                            if (entry[1] == .arr) {
                                for (entry[1].arr) |chunk_v| {
                                    if (chunk_v != .arr) continue;
                                    const chunk = chunk_v.arr;
                                    if (chunk.len < 2) continue;

                                    const hl_id: u32 = if (chunk[0] == .int) (checkedU32(chunk[0].int) orelse 0) else 0;
                                    const text: []const u8 = if (chunk[1] == .str) chunk[1].str else "";
                                    try chunks.append(arena, MsgChunk{ .hl_id = hl_id, .text = text });
                                }
                            }

                            // append is optional (3rd element)
                            const append_flag: bool = if (entry.len > 2 and entry[2] == .bool) entry[2].bool else false;

                            try entries.append(arena, grid_mod.MsgHistoryEntry{
                                .kind = kind,
                                .content = chunks,
                                .append = append_flag,
                            });
                        }
                    }

                    const prev_cmd: bool = if (t.len > 1 and t[1] == .bool) t[1].bool else false;

                    try grid.setMsgHistoryShow(entries.items, prev_cmd);
                    if (log.cb != null) log.write("msg_history_show entries={d} prev_cmd={}\n", .{ entries.items.len, prev_cmd });
                }
            },
            .msg_history_clear => {
                // msg_history_clear: []
                grid.setMsgHistoryClear();
                if (log.cb != null) log.write("msg_history_clear\n", .{});
            },
            .set_title => {
                // set_title: [title]
                if (set_title_fn) |fn_ptr| {
                    for (tuples) |tv| {
                        if (tv != .arr) continue;
                        const t = tv.arr;
                        if (t.len < 1 or t[0] != .str) continue;

                        const title = t[0].str;
                        if (log.cb != null) log.write("set_title: {s}\n", .{title});
                        try fn_ptr(opt_ctx, title);
                    }
                }
            },
            .restart => {
                // restart: [listen_addr]
                // Nvim invoked :restart and started a new server. The current
                // channel is about to close; the UI should attach to the new
                // server at listen_addr after the close is observed.
                if (restart_fn) |fn_ptr| {
                    for (tuples) |tv| {
                        if (tv != .arr) continue;
                        const t = tv.arr;
                        if (t.len < 1 or t[0] != .str) continue;

                        const listen_addr = t[0].str;
                        if (log.cb != null) log.write("restart: listen_addr={s}\n", .{listen_addr});
                        try fn_ptr(opt_ctx, listen_addr);
                    }
                }
            },
            .connect => {
                // connect: [server_addr]
                // Nvim invoked :connect and detached the current UI. Unlike
                // restart, the old server keeps running headless; the UI
                // should immediately attach to the new server at server_addr.
                // The core's reconnect machinery is identical for both events
                // (only the old-server fate differs, and the UI sees the same
                // channel-close handshake), but the dispatcher routes through
                // a distinct callback so the frontend can tell them apart for
                // logging / UI-hint purposes.
                if (connect_fn) |fn_ptr| {
                    for (tuples) |tv| {
                        if (tv != .arr) continue;
                        const t = tv.arr;
                        if (t.len < 1 or t[0] != .str) continue;

                        const server_addr = t[0].str;
                        if (log.cb != null) log.write("connect: server_addr={s}\n", .{server_addr});
                        try fn_ptr(opt_ctx, server_addr);
                    }
                }
            },
            .flush => {
                if (log.cb != null) log.write("flush rows={d} cols={d}\n", .{ grid.rows, grid.cols });
                if (log.cb != null and grid.input_trace_seq != 0 and grid.input_trace_flush_logged_seq != grid.input_trace_seq) {
                    const now_ns = clock.nowNs();
                    const delta_us: i64 = @intCast(@divTrunc(@max(@as(i128, 0), now_ns - @as(i128, grid.input_trace_sent_ns)), 1000));
                    log.write("[perf_input] seq={d} stage=flush_start delta_us={d} rows={d} cols={d}\n", .{
                        grid.input_trace_seq, delta_us, grid.rows, grid.cols,
                    });
                    grid.input_trace_flush_logged_seq = grid.input_trace_seq;
                }
                // Render-affecting state derived from the completed redraw batch
                // must be applied before the frontend transaction is committed.
                try pre_flush_fn(flush_ctx);
                try flush_fn(flush_ctx, grid.rows, grid.cols);
                // Dirty state (dirty_all, dirty_rows, scroll provenance) is cleared
                // inside onFlush on successful completion. On abort, all state is
                // preserved for the next flush attempt.
            },
        }
    }
}
