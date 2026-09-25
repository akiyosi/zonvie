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
//
// The tests below it cover the rest of HBFTBridge.c's font surface with the
// same real-font approach: the ASCII fast-path tables against hb_shape for
// every feature setting, face and variation instance; variation axes
// (outline, clamping, advances); and feature values. Fonts are looked up in
// the user and system font folders; SF Mono and Skia ship with macOS, so the
// variation tests run without anything installed.

const std = @import("std");
const zonvie_core = @import("zonvie_core");

const HbFont = opaque {};
extern fn zonvie_ft_hb_font_create(bytes: [*]const u8, len: usize, pixel_size: u32, face_index: u32) ?*HbFont;
extern fn zonvie_ft_hb_font_destroy(f: *HbFont) void;
extern fn zonvie_ft_hb_font_set_features(f: *HbFont, features: [*]const zonvie_core.FontFeatureC, count: usize) void;
extern fn zonvie_ft_hb_font_set_variations(f: *HbFont, variations: [*]const zonvie_core.FontFeatureC, count: usize) void;
const zonvie_font_axis = extern struct { tag: [4]u8, value: f32 };
extern fn zonvie_ft_hb_font_set_variation_axes(f: *HbFont, axes: [*]const zonvie_font_axis, count: usize) void;
extern fn zonvie_ft_hb_get_ascii_glyph_ids(f: *HbFont, out_glyph_ids: [*]u32) c_int;
extern fn zonvie_ft_hb_get_ascii_x_advances(f: *HbFont, out_x_advances: [*]i32) c_int;
extern fn zonvie_ft_hb_get_ascii_lig_triggers(f: *HbFont, out_lig_triggers: [*]u8) c_int;
extern fn zonvie_ft_render_glyph(
    f: *HbFont,
    glyph_id: u32,
    out_buffer: *?[*]const u8,
    out_width: *c_int,
    out_height: *c_int,
    out_pitch: *c_int,
    out_left: *c_int,
    out_top: *c_int,
    out_advance_x_26_6: *i32,
) c_int;
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
        try requireNoTestFonts();
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

// ---------------------------------------------------------------------------
// Fonts on disk
// ---------------------------------------------------------------------------

const TestFont = struct {
    bytes: []u8,
    font: *HbFont,
    path: []u8,

    /// Opens the first of `names` found in the user or system font folders,
    /// at `face_index` for a collection. Null when none is installed.
    fn open(alloc: std.mem.Allocator, names: []const []const u8, face_index: u32) !?TestFont {
        const io = zonvie_core.clock.io();
        const path = (try findFontFile(alloc, io, names)) orelse {
            try requireNoTestFonts();
            return null;
        };
        errdefer alloc.free(path);
        const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, alloc, .limited(64 * 1024 * 1024));
        errdefer alloc.free(bytes);
        const font = zonvie_ft_hb_font_create(bytes.ptr, bytes.len, 28, face_index) orelse return error.FontLoadFailed;
        return .{ .bytes = bytes, .font = font, .path = path };
    }

    fn deinit(self: *TestFont, alloc: std.mem.Allocator) void {
        zonvie_ft_hb_font_destroy(self.font);
        alloc.free(self.bytes);
        alloc.free(self.path);
    }
};

/// Every font these tests open is either installed by CI at a pinned version
/// (.github/workflows/test.yml) or ships with macOS. With
/// ZONVIE_REQUIRE_TEST_FONTS set, a missing one is a broken CI setup: fail
/// instead of skipping, so CI cannot pass without testing anything.
fn requireNoTestFonts() !void {
    const required = std.process.Environ.getAlloc(std.testing.environ, std.testing.allocator, "ZONVIE_REQUIRE_TEST_FONTS") catch return;
    std.testing.allocator.free(required);
    std.debug.print("a test font is not installed but ZONVIE_REQUIRE_TEST_FONTS is set\n", .{});
    return error.TestFontMissing;
}

fn findFontFile(alloc: std.mem.Allocator, io: std.Io, names: []const []const u8) !?[]u8 {
    const home = std.process.Environ.getAlloc(std.testing.environ, alloc, "HOME") catch null;
    defer if (home) |h| alloc.free(h);
    const user_dir: ?[]u8 = if (home) |h| try std.fmt.allocPrint(alloc, "{s}/Library/Fonts", .{h}) else null;
    defer if (user_dir) |d| alloc.free(d);
    const dirs = [_][]const u8{ user_dir orelse "", "/Library/Fonts", "/System/Library/Fonts", "/System/Library/Fonts/Supplemental" };
    for (names) |name| {
        for (dirs) |dir| {
            if (dir.len == 0) continue;
            const path = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ dir, name });
            if (std.Io.Dir.cwd().access(io, path, .{})) |_| {
                return path;
            } else |_| alloc.free(path);
        }
    }
    return null;
}

/// Applies a [font] family feature field the way GlyphAtlas does: every
/// entry goes to set_variations (which takes the axis tags) and then to
/// set_features.
fn applySpec(font: *HbFont, spec: []const u8) void {
    var features: [32]zonvie_core.FontFeatureC = undefined;
    const n = zonvie_core.zonvie_core_parse_font_features(spec.ptr, spec.len, &features, features.len);
    if (n == 0) return;
    zonvie_ft_hb_font_set_variations(font, &features, n);
    zonvie_ft_hb_font_set_features(font, &features, n);
}

const ShapedChar = struct { gid: u32, x_advance: i32 };

fn shapeOne(font: *HbFont, ch: u8) ShapedChar {
    var scalars = [1]u32{ch};
    var gid: [4]u32 = undefined;
    var clusters: [4]u32 = undefined;
    var xa: [4]i32 = undefined;
    var ya: [4]i32 = undefined;
    var xo: [4]i32 = undefined;
    var yo: [4]i32 = undefined;
    _ = zonvie_hb_shape_utf32(font, &scalars, 1, &gid, &clusters, &xa, &ya, &xo, &yo, gid.len, null, null, null);
    return .{ .gid = gid[0], .x_advance = xa[0] };
}

/// Total coverage of a glyph's grayscale bitmap: heavier outlines cover more.
fn inkOf(font: *HbFont, gid: u32) !u64 {
    var buffer: ?[*]const u8 = null;
    var w: c_int = 0;
    var h: c_int = 0;
    var pitch: c_int = 0;
    var left: c_int = 0;
    var top: c_int = 0;
    var adv: i32 = 0;
    if (zonvie_ft_render_glyph(font, gid, &buffer, &w, &h, &pitch, &left, &top, &adv) != 0) return error.RenderFailed;
    const buf = buffer orelse return 0;
    const stride: usize = @intCast(@abs(pitch));
    var sum: u64 = 0;
    for (0..@intCast(h)) |y| {
        for (0..@intCast(w)) |x| sum += buf[y * stride + x];
    }
    return sum;
}

fn asciiGlyphIds(font: *HbFont) ![128]u32 {
    var gids: [128]u32 = undefined;
    if (zonvie_ft_hb_get_ascii_glyph_ids(font, &gids) == 0) return error.NoAsciiTable;
    return gids;
}

// ---------------------------------------------------------------------------
// ASCII fast path
// ---------------------------------------------------------------------------

/// The operator characters programming ligatures are built from.
const fast_path_operator_chars = "!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~0xw";

/// The core draws a run with no lig-trigger scalar straight from the ASCII
/// tables (flush.zig, ASCII fast path), so every such run must shape to
/// exactly the table's glyphs. Checks every printable pair and every
/// operator triple.
fn expectFastPathMatchesShaping(font: *HbFont, label: []const u8) !void {
    var gids: [128]u32 = undefined;
    var triggers: [128]u8 = undefined;
    try std.testing.expect(zonvie_ft_hb_get_ascii_glyph_ids(font, &gids) != 0);
    try std.testing.expect(zonvie_ft_hb_get_ascii_lig_triggers(font, &triggers) != 0);

    // A table that marks everything a trigger would pass vacuously.
    var fast_path_chars: usize = 0;
    for (0x20..0x7F) |t| {
        if (triggers[t] == 0) fast_path_chars += 1;
    }
    try std.testing.expect(fast_path_chars >= 26);

    var buf: [3]u8 = undefined;
    var a: u8 = 0x20;
    while (a <= 0x7E) : (a += 1) {
        var b: u8 = 0x20;
        while (b <= 0x7E) : (b += 1) {
            buf = .{ a, b, 0 };
            try expectRunMatchesTable(font, label, buf[0..2], &gids, &triggers);
        }
    }
    for (fast_path_operator_chars) |x| for (fast_path_operator_chars) |y| for (fast_path_operator_chars) |z| {
        buf = .{ x, y, z };
        try expectRunMatchesTable(font, label, &buf, &gids, &triggers);
    };
}

fn expectRunMatchesTable(
    font: *HbFont,
    label: []const u8,
    text: []const u8,
    gids: *const [128]u32,
    triggers: *const [128]u8,
) !void {
    for (text) |ch| if (triggers[ch] != 0) return;
    var out: [16]u32 = undefined;
    const shaped = shape(font, text, &out);
    var expected: [16]u32 = undefined;
    for (text, 0..) |ch, i| expected[i] = gids[ch];
    if (!std.mem.eql(u32, shaped, expected[0..text.len])) {
        std.debug.print("{s}: \"{s}\" takes the ASCII fast path as {any} but shapes to {any}\n", .{ label, text, expected[0..text.len], shaped });
        return error.TestExpectedEqual;
    }
}

const FastPathCase = struct {
    /// Alternative file names of one face; the first installed one is used.
    files: []const []const u8,
    face_index: u32 = 0,
    specs: []const []const u8,
};

const fast_path_cases = [_]FastPathCase{
    // Variable: wght=700 is where Cascadia Code's rvrn swaps `$`.
    .{ .files = &.{ "CascadiaCode.ttf", "CascadiaCode-Regular.ttf" }, .specs = &.{ "", "+liga", "-calt", "-liga,-calt", "+zero", "+ss02", "+ss19", "+ss20", "+case", "-rclt", "wght=200", "wght=700", "wght=700,-calt" } },
    .{ .files = &.{ "CascadiaCodeItalic.ttf", "CascadiaCode-Italic.ttf" }, .specs = &.{ "", "-calt", "+ss01", "wght=700,-calt" } },
    .{ .files = &.{ "FiraCode-Regular.ttf", "FiraCode[wght].ttf", "FiraCode-VF.ttf" }, .specs = &.{ "", "+liga", "-calt", "+zero", "+ss01", "+ss05", "+cv01", "+cv14", "+onum", "wght=700" } },
    .{ .files = &.{"FiraCode-Bold.ttf"}, .specs = &.{ "", "-calt" } },
    .{ .files = &.{ "JetBrainsMono-Regular.ttf", "JetBrainsMono[wght].ttf" }, .specs = &.{ "", "-calt", "+zero", "+ss01", "+cv01", "+cv99", "wght=700" } },
    .{ .files = &.{"JetBrainsMono-Bold.ttf"}, .specs = &.{ "", "-calt" } },
    .{ .files = &.{ "JetBrainsMono-Italic.ttf", "JetBrainsMono-Italic[wght].ttf" }, .specs = &.{ "", "-calt" } },
    .{ .files = &.{"SFNSMono.ttf"}, .specs = &.{ "", "wght=700" } },
    .{ .files = &.{"Menlo.ttc"}, .face_index = 0, .specs = &.{""} },
    .{ .files = &.{"Menlo.ttc"}, .face_index = 1, .specs = &.{""} },
};

// The lig-trigger table HBFTBridge builds from GSUB must name every ASCII
// character hb_shape would substitute, for every feature setting, face and
// variation instance; a missed one draws the unsubstituted glyph through the
// fast path.
test "the ASCII fast path agrees with HarfBuzz for every feature setting, face and instance" {
    const alloc = std.testing.allocator;
    var ran: usize = 0;
    for (fast_path_cases) |case| {
        for (case.specs) |spec| {
            var tf = (try TestFont.open(alloc, case.files, case.face_index)) orelse continue;
            defer tf.deinit(alloc);
            applySpec(tf.font, spec);
            var label_buf: [256]u8 = undefined;
            const label = std.fmt.bufPrint(&label_buf, "{s}[{d}] \"{s}\"", .{ tf.path, case.face_index, spec }) catch tf.path;
            try expectFastPathMatchesShaping(tf.font, label);
            ran += 1;
        }
    }
    if (ran == 0) return error.SkipZigTest;
}

// ---------------------------------------------------------------------------
// Features
// ---------------------------------------------------------------------------

const ligature_fonts = [_][]const u8{ "CascadiaCode.ttf", "FiraCode-Regular.ttf", "FiraCode[wght].ttf", "JetBrainsMono-Regular.ttf", "JetBrainsMono[wght].ttf" };

// A feature from the [font] family entry adds to HarfBuzz's defaults; `+liga`
// must not drop the calt ligatures these fonts draw (it did on Windows).
test "a [font] family feature keeps HarfBuzz's default ligatures" {
    const alloc = std.testing.allocator;
    var tf = (try TestFont.open(alloc, &ligature_fonts, 0)) orelse return error.SkipZigTest;
    defer tf.deinit(alloc);
    const samples = [_][]const u8{ "->", "==", "!=", "<=", "=>" };
    var plain: [samples.len][16]u32 = undefined;
    var plain_len: [samples.len]usize = undefined;
    for (samples, 0..) |s, i| plain_len[i] = shape(tf.font, s, &plain[i]).len;

    applySpec(tf.font, "+liga");
    for (samples, 0..) |s, i| {
        var buf: [16]u32 = undefined;
        try std.testing.expectEqualSlices(u32, plain[i][0..plain_len[i]], shape(tf.font, s, &buf));
    }
}

// With every ligature feature off, a run shapes to one cmap glyph per
// character, the same glyphs the ASCII table holds.
test "-liga,-calt shapes the ASCII table's glyphs one per character" {
    const alloc = std.testing.allocator;
    var tf = (try TestFont.open(alloc, &ligature_fonts, 0)) orelse return error.SkipZigTest;
    defer tf.deinit(alloc);
    applySpec(tf.font, "-liga,-calt");
    const gids = try asciiGlyphIds(tf.font);
    for ([_][]const u8{ "->", "==", "!=", "<=", "=>", "===", "www" }) |s| {
        var buf: [16]u32 = undefined;
        const shaped = shape(tf.font, s, &buf);
        try std.testing.expectEqual(s.len, shaped.len);
        for (s, shaped) |ch, g| try std.testing.expectEqual(gids[ch], g);
    }
}

// A feature's value is honored: `zero` swaps the digit zero for the slashed
// (or dotted) form, `zero=0` and `-zero` keep the default.
test "zero picks the alternate zero and zero=0 keeps the default" {
    const alloc = std.testing.allocator;
    var tf = (try TestFont.open(alloc, &ligature_fonts, 0)) orelse return error.SkipZigTest;
    defer tf.deinit(alloc);
    const default_zero = shapeOne(tf.font, '0').gid;

    applySpec(tf.font, "+zero");
    try std.testing.expect(shapeOne(tf.font, '0').gid != default_zero);
    for ([_][]const u8{ "zero=0", "-zero" }) |spec| {
        applySpec(tf.font, spec);
        try std.testing.expectEqual(default_zero, shapeOne(tf.font, '0').gid);
    }
}

// ---------------------------------------------------------------------------
// Variation axes
// ---------------------------------------------------------------------------

const wght_fonts = [_][]const u8{ "SFNSMono.ttf", "Skia.ttf", "CascadiaCode.ttf", "FiraCode[wght].ttf", "JetBrainsMono[wght].ttf" };

// `wght=N` in a [font] family entry moves a variable font's outline; values
// past the axis clamp to its limit, and an axis tag the font lacks (or a
// plain feature) leaves the default instance alone.
test "a wght axis value changes the outline and clamps to the axis range" {
    const alloc = std.testing.allocator;
    var tf = (try TestFont.open(alloc, &wght_fonts, 0)) orelse return error.SkipZigTest;
    defer tf.deinit(alloc);
    const gid = (try asciiGlyphIds(tf.font))['H'];
    const default_ink = try inkOf(tf.font, gid);

    applySpec(tf.font, "wght=1");
    const light_ink = try inkOf(tf.font, gid);
    applySpec(tf.font, "wght=100000");
    const heavy_ink = try inkOf(tf.font, gid);
    applySpec(tf.font, "wght=99999");
    try std.testing.expectEqual(heavy_ink, try inkOf(tf.font, gid));
    try std.testing.expect(heavy_ink > light_ink);

    // count=0 restores the default instance.
    const none = [1]zonvie_core.FontFeatureC{.{ .tag = "wght".*, .value = 0 }};
    zonvie_ft_hb_font_set_variations(tf.font, &none, 0);
    try std.testing.expectEqual(default_ink, try inkOf(tf.font, gid));

    applySpec(tf.font, "ZZZZ=5,+liga");
    try std.testing.expectEqual(default_ink, try inkOf(tf.font, gid));
}

// The ASCII fast path draws with the advances in the ASCII table, so they
// must be the current instance's: Skia's wdth axis narrows every glyph.
test "the ASCII table's advances follow the variation instance" {
    const alloc = std.testing.allocator;
    var tf = (try TestFont.open(alloc, &.{"Skia.ttf"}, 0)) orelse return error.SkipZigTest;
    defer tf.deinit(alloc);
    const default_advance = shapeOne(tf.font, 'a').x_advance;

    // set_variations alone (no set_features after it, which would rebuild
    // the tables itself) must leave tables for the new instance. Clamps to
    // the narrowest width Skia has.
    var narrowest = [1]zonvie_core.FontFeatureC{.{ .tag = "wdth".*, .value = 0 }};
    zonvie_ft_hb_font_set_variations(tf.font, &narrowest, 1);
    const narrow = shapeOne(tf.font, 'a');
    try std.testing.expect(narrow.x_advance < default_advance);

    var advances: [128]i32 = undefined;
    try std.testing.expect(zonvie_ft_hb_get_ascii_x_advances(tf.font, &advances) != 0);
    try std.testing.expectEqual(narrow.x_advance, advances['a']);

    // So must the reset to the default instance.
    zonvie_ft_hb_font_set_variations(tf.font, &narrowest, 0);
    try std.testing.expect(zonvie_ft_hb_get_ascii_x_advances(tf.font, &advances) != 0);
    try std.testing.expectEqual(default_advance, advances['a']);
}

// A CoreText instance's coordinates reach FreeType unrounded: Skia's wght
// runs 0.48-3.2, so 1.5 and 2.0 are different weights (rounding made them
// the same).
test "a fractional axis value reaches FreeType unrounded" {
    const alloc = std.testing.allocator;
    var tf = (try TestFont.open(alloc, &.{"Skia.ttf"}, 0)) orelse return error.SkipZigTest;
    defer tf.deinit(alloc);
    const gid = (try asciiGlyphIds(tf.font))['H'];
    var ink: [3]u64 = undefined;
    for ([_]f32{ 1.0, 1.5, 2.0 }, 0..) |w, i| {
        const axis = [1]zonvie_font_axis{.{ .tag = "wght".*, .value = w }};
        zonvie_ft_hb_font_set_variation_axes(tf.font, &axis, 1);
        ink[i] = try inkOf(tf.font, gid);
    }
    try std.testing.expect(ink[0] < ink[1]);
    try std.testing.expect(ink[1] < ink[2]);
}

/// Programming ligatures in monospace fonts: calt sequences and liga pairs.
const ligature_samples = [_][]const u8{ "->", "==", "!=", "<=", "=>", "===", "!==", "<=>", "->>", "&&", "||", "::", "//", "/*", "www", "0xF" };

// flush.zig maps each shaped glyph to a grid column through its cluster and
// suppresses calt placeholders by position; both assume a monospace ligature
// font keeps one glyph per character, in order, each one cell wide.
test "a monospace ligature keeps one glyph per cell in cluster order" {
    const alloc = std.testing.allocator;
    var ran: usize = 0;
    for ([_][]const []const u8{
        &.{ "CascadiaCode.ttf", "CascadiaCode-Regular.ttf" },
        &.{ "FiraCode-Regular.ttf", "FiraCode[wght].ttf", "FiraCode-VF.ttf" },
        &.{ "JetBrainsMono-Regular.ttf", "JetBrainsMono[wght].ttf" },
    }) |files| {
        var tf = (try TestFont.open(alloc, files, 0)) orelse continue;
        defer tf.deinit(alloc);
        const cell_advance = shapeOne(tf.font, 'a').x_advance;
        const gids = try asciiGlyphIds(tf.font);
        var ligated: usize = 0;
        for (ligature_samples) |s| {
            var scalars: [16]u32 = undefined;
            for (s, 0..) |ch, i| scalars[i] = ch;
            var out: [16]u32 = undefined;
            var clusters: [16]u32 = undefined;
            var xa: [16]i32 = undefined;
            var ya: [16]i32 = undefined;
            var xo: [16]i32 = undefined;
            var yo: [16]i32 = undefined;
            const n = zonvie_hb_shape_utf32(tf.font, &scalars, s.len, &out, &clusters, &xa, &ya, &xo, &yo, out.len, null, null, null);
            try std.testing.expectEqual(s.len, n);
            for (0..n) |i| {
                try std.testing.expectEqual(@as(u32, @intCast(i)), clusters[i]);
                try std.testing.expectEqual(cell_advance, xa[i]);
                if (out[i] != gids[s[i]]) ligated += 1;
            }
        }
        // The samples must actually ligate, or this proves nothing.
        try std.testing.expect(ligated > 0);
        ran += 1;
    }
    if (ran == 0) return error.SkipZigTest;
}

// ---------------------------------------------------------------------------
// Stylistic sets and character variants
// ---------------------------------------------------------------------------

fn readU16(data: []const u8, off: usize) ?u16 {
    if (off + 2 > data.len) return null;
    return std.mem.readInt(u16, data[off..][0..2], .big);
}

fn readU32(data: []const u8, off: usize) ?u32 {
    if (off + 4 > data.len) return null;
    return std.mem.readInt(u32, data[off..][0..4], .big);
}

/// Whether a GSUB feature tag is one a user picks in a [font] family entry to
/// change how characters look: stylistic sets, character variants and the
/// common alternates.
fn isCharacterFeature(tag: [4]u8) bool {
    const digits = std.ascii.isDigit(tag[2]) and std.ascii.isDigit(tag[3]);
    if (digits and std.mem.eql(u8, tag[0..2], "ss")) return true;
    if (digits and std.mem.eql(u8, tag[0..2], "cv")) return true;
    for ([_]*const [4]u8{ "zero", "onum", "case", "salt", "dlig" }) |t| {
        if (std.mem.eql(u8, &tag, t)) return true;
    }
    return false;
}

/// The distinct character-feature tags in a font file's GSUB FeatureList
/// (`face_index` selects the face of a collection).
fn characterFeatures(bytes: []const u8, face_index: u32, out: *[160][4]u8) usize {
    const base: usize = if (std.mem.eql(u8, bytes[0..@min(4, bytes.len)], "ttcf"))
        readU32(bytes, 12 + 4 * @as(usize, face_index)) orelse return 0
    else
        0;
    const num_tables = readU16(bytes, base + 4) orelse return 0;
    const gsub: usize = for (0..num_tables) |i| {
        const rec = base + 12 + i * 16;
        if (rec + 16 > bytes.len) return 0;
        if (std.mem.eql(u8, bytes[rec..][0..4], "GSUB")) break readU32(bytes, rec + 8) orelse return 0;
    } else return 0;
    const fl = gsub + (readU16(bytes, gsub + 6) orelse return 0);
    const count = readU16(bytes, fl) orelse return 0;
    var n: usize = 0;
    for (0..count) |i| {
        const at = fl + 2 + i * 6;
        if (at + 4 > bytes.len) break;
        const tag = bytes[at..][0..4].*;
        if (!isCharacterFeature(tag)) continue;
        const seen = for (out[0..n]) |t| {
            if (std.mem.eql(u8, &t, &tag)) break true;
        } else false;
        if (seen or n == out.len) continue;
        out[n] = tag;
        n += 1;
    }
    return n;
}

fn shapeScalars(font: *HbFont, scalars: []const u32, out: *[16]u32) []const u32 {
    var clusters: [16]u32 = undefined;
    var xa: [16]i32 = undefined;
    var ya: [16]i32 = undefined;
    var xo: [16]i32 = undefined;
    var yo: [16]i32 = undefined;
    const n = zonvie_hb_shape_utf32(font, scalars.ptr, scalars.len, out, &clusters, &xa, &ya, &xo, &yo, out.len, null, null, null);
    return out[0..@min(n, out.len)];
}

/// Text a character feature may act on beyond ASCII pairs: ligatures,
/// fractions, Latin-1 and Latin Extended-A (Consolas's ss01 Eng), combining
/// accents (Cascadia's `case`), Greek and Cyrillic (JetBrains Mono's cv99)
/// and the control pictures (Cascadia's ss20).
fn characterFeatureCorpus(buf: *[1024][4]u32) [][4]u32 {
    var n: usize = 0;
    for (ligature_samples ++ [_][]const u8{ "1/2", "10/31", "0x0", "#{", "{|", "[|", ".=", "..", "...", "~>", "<~", "%%" }) |s| {
        buf[n] = .{ 0, 0, 0, 0 };
        for (s[0..@min(s.len, 4)], 0..) |ch, i| buf[n][i] = ch;
        n += 1;
    }
    const ranges = [_][2]u32{ .{ 0xA1, 0x17F }, .{ 0x0300, 0x030C }, .{ 0x0391, 0x045F }, .{ 0x2400, 0x2426 } };
    for (ranges) |range| {
        var cp = range[0];
        while (cp <= range[1]) : (cp += 1) {
            buf[n] = .{ cp, 0, 0, 0 };
            n += 1;
        }
    }
    return buf[0..n];
}

/// A shaped run kept for comparison: up to 16 glyph ids.
const ShapedRun = struct {
    glyphs: [16]u32,
    len: u8,

    fn init(shaped: []const u32) ShapedRun {
        var s: ShapedRun = .{ .glyphs = undefined, .len = @intCast(shaped.len) };
        @memcpy(s.glyphs[0..shaped.len], shaped);
        return s;
    }

    fn eql(self: *const ShapedRun, shaped: []const u32) bool {
        return std.mem.eql(u32, self.glyphs[0..self.len], shaped);
    }
};

fn scalarsOf(entry: *const [4]u32) []const u32 {
    const len = std.mem.indexOfScalar(u32, entry, 0) orelse 4;
    return entry[0..len];
}

// Every stylistic set, character variant and alternate the font carries
// (read from its GSUB, so none is left out) must reach HarfBuzz, changing
// how something shapes, and must keep the ASCII fast path in agreement: a
// feature that substitutes a character the trigger table misses would draw
// the default glyph through the fast path.
test "every stylistic set and character variant changes shaping and keeps the fast path correct" {
    const alloc = std.testing.allocator;
    // `pinned`: CI installs this font at a fixed version, so every feature it
    // carries is known to act on the corpus. An OS font may change under us.
    const faces = [_]struct { files: []const []const u8, face_index: u32 = 0, pinned: bool }{
        .{ .files = &.{ "CascadiaCode.ttf", "CascadiaCode-Regular.ttf" }, .pinned = true },
        .{ .files = &.{ "FiraCode-Regular.ttf", "FiraCode[wght].ttf", "FiraCode-VF.ttf" }, .pinned = true },
        .{ .files = &.{ "JetBrainsMono-Regular.ttf", "JetBrainsMono[wght].ttf" }, .pinned = true },
        .{ .files = &.{"SFNSMono.ttf"}, .pinned = false },
        .{ .files = &.{"Menlo.ttc"}, .pinned = false },
    };
    var corpus_buf: [1024][4]u32 = undefined;
    const corpus = characterFeatureCorpus(&corpus_buf);
    var ran: usize = 0;
    for (faces) |face| {
        var base = (try TestFont.open(alloc, face.files, face.face_index)) orelse continue;
        defer base.deinit(alloc);
        var tags: [160][4]u8 = undefined;
        const tag_count = characterFeatures(base.bytes, face.face_index, &tags);

        // The baseline never changes across tags: shape it once per face.
        const pair_count = 95 * 95;
        const base_shapes = try alloc.alloc(ShapedRun, pair_count + corpus.len);
        defer alloc.free(base_shapes);
        for (0..pair_count) |i| {
            const pair = [2]u8{ @intCast(0x20 + i / 95), @intCast(0x20 + i % 95) };
            var out: [16]u32 = undefined;
            base_shapes[i] = .init(shape(base.font, &pair, &out));
        }
        for (corpus, 0..) |*entry, i| {
            var out: [16]u32 = undefined;
            base_shapes[pair_count + i] = .init(shapeScalars(base.font, scalarsOf(entry), &out));
        }

        for (tags[0..tag_count]) |tag| {
            var tf = (try TestFont.open(alloc, face.files, face.face_index)) orelse return error.TestUnexpectedResult;
            defer tf.deinit(alloc);
            var spec_buf: [8]u8 = undefined;
            const spec = try std.fmt.bufPrint(&spec_buf, "+{s}", .{&tag});
            applySpec(tf.font, spec);
            var label_buf: [256]u8 = undefined;
            const label = std.fmt.bufPrint(&label_buf, "{s} \"{s}\"", .{ tf.path, spec }) catch tf.path;

            var gids: [128]u32 = undefined;
            var triggers: [128]u8 = undefined;
            try std.testing.expect(zonvie_ft_hb_get_ascii_glyph_ids(tf.font, &gids) != 0);
            try std.testing.expect(zonvie_ft_hb_get_ascii_lig_triggers(tf.font, &triggers) != 0);

            var changed: usize = 0;
            for (0..pair_count) |i| {
                const pair = [2]u8{ @intCast(0x20 + i / 95), @intCast(0x20 + i % 95) };
                var with: [16]u32 = undefined;
                if (!base_shapes[i].eql(shape(tf.font, &pair, &with))) changed += 1;
                try expectRunMatchesTable(tf.font, label, &pair, &gids, &triggers);
            }
            for (corpus, 0..) |*entry, i| {
                var with: [16]u32 = undefined;
                if (!base_shapes[pair_count + i].eql(shapeScalars(tf.font, scalarsOf(entry), &with))) changed += 1;
            }
            if (changed == 0) {
                std.debug.print("{s}: enabling the feature changed nothing it shapes\n", .{label});
                if (face.pinned) return error.TestExpectedEqual;
            }
            ran += 1;
        }
    }
    if (ran == 0) return error.SkipZigTest;
}
