// OpenType features reach the macOS shaper.
//
// A [font] family entry such as `JetBrains Mono:-liga:-calt` travels as a
// feature string through the core's parser (zonvie_core_parse_font_features,
// what GlyphAtlas calls) into HBFTBridge.c's zonvie_ft_hb_font_set_features
// and HarfBuzz. The pure tests stop at the parser; this one shapes `->` and
// friends with a real ligature font, with and without `-calt,-liga`, and
// requires the glyphs to differ.
//
// Uses a font already on the system (ZONVIE_TEST_LIGATURE_FONT, or a
// JetBrains Mono / Fira Code / Cascadia Code file under ~/Library/Fonts or
// /Library/Fonts) and skips when there is none.

const std = @import("std");
const zonvie_core = @import("zonvie_core");

const HbFont = opaque {};
extern fn zonvie_ft_hb_font_create(bytes: [*]const u8, len: usize, pixel_size: u32, face_index: u32) ?*HbFont;
extern fn zonvie_ft_hb_font_destroy(f: *HbFont) void;
extern fn zonvie_ft_hb_font_set_features(f: *HbFont, features: [*]const zonvie_core.FontFeatureC, count: usize) void;
extern fn zonvie_hb_shape_utf32(
    f: *HbFont,
    scalars: [*]const u32,
    scalar_count: usize,
    out_glyph_ids: [*]u32,
    out_clusters: [*]u32,
    out_x_advance: [*]i32,
    out_y_advance: [*]i32,
    out_x_offset: [*]i32,
    out_y_offset: [*]i32,
    out_cap: usize,
    out_font_ascender: ?*i32,
    out_font_descender: ?*i32,
    out_font_height: ?*i32,
) usize;

/// Font files known to carry ligatures on `->`, `==`, `!=`, `<=`, `=>`.
const known_ligature_fonts = [_][]const u8{
    "JetBrainsMono-Regular.ttf",
    "JetBrainsMono[wght].ttf",
    "FiraCode-Regular.ttf",
    "FiraCode[wght].ttf",
    "FiraCode-VF.ttf",
    "CascadiaCode.ttf",
    "CascadiaCode-Regular.ttf",
};

fn findLigatureFont(alloc: std.mem.Allocator, io: std.Io) !?[]u8 {
    if (std.process.Environ.getAlloc(std.testing.environ, alloc, "ZONVIE_TEST_LIGATURE_FONT")) |path| {
        return path;
    } else |_| {}
    var dirs: [2][]const u8 = .{ "", "/Library/Fonts" };
    const home = std.process.Environ.getAlloc(std.testing.environ, alloc, "HOME") catch null;
    defer if (home) |h| alloc.free(h);
    var user_dir: ?[]u8 = null;
    defer if (user_dir) |d| alloc.free(d);
    if (home) |h| {
        user_dir = try std.fmt.allocPrint(alloc, "{s}/Library/Fonts", .{h});
        dirs[0] = user_dir.?;
    }
    for (dirs) |dir| {
        if (dir.len == 0) continue;
        for (known_ligature_fonts) |name| {
            const path = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ dir, name });
            if (std.Io.Dir.cwd().access(io, path, .{})) |_| {
                return path;
            } else |_| alloc.free(path);
        }
    }
    return null;
}

fn shape(font: *HbFont, text: []const u8, out: *[16]u32) []const u32 {
    var scalars: [16]u32 = undefined;
    for (text, 0..) |ch, i| scalars[i] = ch;
    var clusters: [16]u32 = undefined;
    var xa: [16]i32 = undefined;
    var ya: [16]i32 = undefined;
    var xo: [16]i32 = undefined;
    var yo: [16]i32 = undefined;
    const n = zonvie_hb_shape_utf32(font, &scalars, text.len, out, &clusters, &xa, &ya, &xo, &yo, out.len, null, null, null);
    return out[0..@min(n, out.len)];
}

test "features from a [font] family entry change what HarfBuzz shapes" {
    const alloc = std.testing.allocator;
    const io = zonvie_core.clock.io();
    const path = (try findLigatureFont(alloc, io)) orelse {
        std.debug.print("font_shaping_test: no ligature font installed, skipped\n", .{});
        return error.SkipZigTest;
    };
    defer alloc.free(path);
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .limited(64 * 1024 * 1024));
    defer alloc.free(bytes);
    const font = zonvie_ft_hb_font_create(bytes.ptr, bytes.len, 28, 0) orelse return error.FontLoadFailed;
    defer zonvie_ft_hb_font_destroy(font);

    const samples = [_][]const u8{ "->", "==", "!=", "<=", "=>" };
    var with_ligatures: [samples.len][16]u32 = undefined;
    var with_ligatures_len: [samples.len]usize = undefined;
    for (samples, 0..) |s, i| with_ligatures_len[i] = shape(font, s, &with_ligatures[i]).len;

    // The feature field of `JetBrains Mono:h14:-liga:-calt`, read the way
    // every frontend reads it.
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const lines = try zonvie_core.config.formatFontFamilyAsCandidateList(arena.allocator(), "Font:h14:-liga:-calt", 14.0, "Font");
    const cand = zonvie_core.config.parseFontCandidateLine(lines, 14.0, false).?;
    var features: [8]zonvie_core.FontFeatureC = undefined;
    const n = zonvie_core.zonvie_core_parse_font_features(cand.features.ptr, cand.features.len, &features, features.len);
    try std.testing.expectEqual(@as(usize, 2), n);
    zonvie_ft_hb_font_set_features(font, &features, n);

    var changed: usize = 0;
    for (samples, 0..) |s, i| {
        var buf: [16]u32 = undefined;
        const plain = shape(font, s, &buf);
        const lig = with_ligatures[i][0..with_ligatures_len[i]];
        if (!std.mem.eql(u32, plain, lig)) changed += 1;
    }
    std.debug.print("font_shaping_test: {s}: {d}/{d} samples change under -liga,-calt\n", .{ path, changed, samples.len });
    // A font from the list above shapes these as ligatures by default; with
    // the features off, none of them may stay the same glyphs everywhere.
    try std.testing.expect(changed > 0);

    // Clearing the features restores the default shaping.
    zonvie_ft_hb_font_set_features(font, &features, 0);
    for (samples, 0..) |s, i| {
        var buf: [16]u32 = undefined;
        try std.testing.expectEqualSlices(u32, with_ligatures[i][0..with_ligatures_len[i]], shape(font, s, &buf));
    }
}
