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
