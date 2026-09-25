// Tests for config.formatFontFamilyAsCandidateList.
//
// The helper turns a guifont-style comma-separated string into the
// newline-separated `<name>\t<size>[\t<features>]` form delivered to
// frontends via zonvie_config_values.font_family.

const std = @import("std");
const zonvie_core = @import("zonvie_core");
const config = zonvie_core.config;

fn fmt(arena: std.mem.Allocator, raw: []const u8, default_pt: f64, fallback: []const u8) ![]const u8 {
    return config.formatFontFamilyAsCandidateList(arena, raw, default_pt, fallback);
}

test "single name inherits default size" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const out = try fmt(arena.allocator(), "Menlo", 14.0, "Menlo");
    try std.testing.expectEqualStrings("Menlo\t14", out);
}

test "comma separated list" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const out = try fmt(arena.allocator(), "SF Mono,Menlo,Monaco", 14.0, "Menlo");
    try std.testing.expectEqualStrings("SF Mono\t14\nMenlo\t14\nMonaco\t14", out);
}

test "spaces after commas are ignored" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const out = try fmt(arena.allocator(), "SF Mono, Menlo, Monaco", 14.0, "Menlo");
    try std.testing.expectEqualStrings("SF Mono\t14\nMenlo\t14\nMonaco\t14", out);
}

test "per-entry :h size overrides default" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const out = try fmt(arena.allocator(), "SF Mono:h13,JetBrains Mono:h14,Menlo", 16.0, "Menlo");
    try std.testing.expectEqualStrings("SF Mono\t13\nJetBrains Mono\t14\nMenlo\t16", out);
}

test "empty input emits fallback" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const out = try fmt(arena.allocator(), "", 14.0, "Menlo");
    try std.testing.expectEqualStrings("Menlo\t14", out);
}

test "OpenType features round-trip" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const out = try fmt(arena.allocator(), "JetBrains Mono:h14:+ss01:-liga", 14.0, "Menlo");
    try std.testing.expectEqualStrings("JetBrains Mono\t14\t+ss01,-liga", out);
}

test "nvim DFLT_GFN macOS default" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const out = try fmt(arena.allocator(), "SF Mono,Menlo,Monaco,Courier New,monospace", 14.0, "Menlo");
    try std.testing.expectEqualStrings(
        "SF Mono\t14\nMenlo\t14\nMonaco\t14\nCourier New\t14\nmonospace\t14",
        out,
    );
}

test "nvim DFLT_GFN Windows default" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const out = try fmt(arena.allocator(), "Cascadia Code,Cascadia Mono,Consolas,Courier New,monospace", 18.0, "Consolas");
    try std.testing.expectEqualStrings(
        "Cascadia Code\t18\nCascadia Mono\t18\nConsolas\t18\nCourier New\t18\nmonospace\t18",
        out,
    );
}

// ============================================================================
// config.parseFontCandidateLine: what a frontend loads from one line. The
// Windows guifont and config paths and every macOS path read lines this way,
// so a [font] family entry's size and features reach the font loader intact.
// ============================================================================

test "candidate line: config features reach the loader" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const lines = try fmt(arena.allocator(), "JetBrains Mono:h14:-liga:-calt, Consolas", 12.0, "Consolas");
    var it = std.mem.splitScalar(u8, lines, '\n');
    const first = config.parseFontCandidateLine(it.next().?, 12.0, false).?;
    try std.testing.expectEqualStrings("JetBrains Mono", first.name);
    try std.testing.expectEqual(@as(f32, 14.0), first.point_size);
    try std.testing.expectEqualStrings("-liga,-calt", first.features);
    // A bare entry inherits [font] size and carries no features.
    const second = config.parseFontCandidateLine(it.next().?, 12.0, false).?;
    try std.testing.expectEqualStrings("Consolas", second.name);
    try std.testing.expectEqual(@as(f32, 12.0), second.point_size);
    try std.testing.expectEqualStrings("", second.features);
}

test "candidate line: explicit [font] size wins over the line's" {
    const c = config.parseFontCandidateLine("Cascadia Code\t14\t+ss01", 18.0, true).?;
    try std.testing.expectEqual(@as(f32, 18.0), c.point_size);
    try std.testing.expectEqualStrings("+ss01", c.features);
}

test "candidate line: a zero or unreadable size falls back to the default" {
    try std.testing.expectEqual(@as(f32, 13.0), config.parseFontCandidateLine("Menlo\t0", 13.0, false).?.point_size);
    try std.testing.expectEqual(@as(f32, 13.0), config.parseFontCandidateLine("Menlo\tbig", 13.0, false).?.point_size);
}

test "candidate line: no name or no size field is not a candidate" {
    try std.testing.expect(config.parseFontCandidateLine("\t14", 13.0, false) == null);
    try std.testing.expect(config.parseFontCandidateLine("Menlo", 13.0, false) == null);
    try std.testing.expect(config.parseFontCandidateLine("", 13.0, false) == null);
}

test "candidate line: the C ABI reads it the same way" {
    const line = "JetBrains Mono\t15\t-liga,-calt";
    var name_len: usize = 0;
    var pt: f32 = 0;
    var feat_off: usize = 0;
    var feat_len: usize = 0;
    try std.testing.expect(zonvie_core.zonvie_core_parse_font_candidate(line.ptr, line.len, 12.0, false, &name_len, &pt, &feat_off, &feat_len));
    try std.testing.expectEqualStrings("JetBrains Mono", line[0..name_len]);
    try std.testing.expectEqual(@as(f32, 15.0), pt);
    try std.testing.expectEqualStrings("-liga,-calt", line[feat_off..][0..feat_len]);
}
