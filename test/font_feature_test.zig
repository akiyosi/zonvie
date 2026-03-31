// Font feature and variable font axis parsing tests.
// Tests parseFontFeatureToken and parseGuiFontCandidate from redraw_handler.zig.

const std = @import("std");
const zonvie_core = @import("zonvie_core");
const redraw = zonvie_core.nvim_core.redraw;

const parseFontFeatureToken = redraw.parseFontFeatureToken;
const parseGuiFontCandidate = redraw.parseGuiFontCandidate;

// ============================================================================
// parseFontFeatureToken
// ============================================================================

test "feature: +liga enables" {
    const f = parseFontFeatureToken("+liga").?;
    try std.testing.expectEqualSlices(u8, "liga", &f.tag);
    try std.testing.expectEqual(@as(i32, 1), f.value);
}

test "feature: -dlig disables" {
    const f = parseFontFeatureToken("-dlig").?;
    try std.testing.expectEqualSlices(u8, "dlig", &f.tag);
    try std.testing.expectEqual(@as(i32, 0), f.value);
}

test "feature: ss01=2 explicit value" {
    const f = parseFontFeatureToken("ss01=2").?;
    try std.testing.expectEqualSlices(u8, "ss01", &f.tag);
    try std.testing.expectEqual(@as(i32, 2), f.value);
}

test "feature: bare 4-char tag enables" {
    const f = parseFontFeatureToken("zero").?;
    try std.testing.expectEqualSlices(u8, "zero", &f.tag);
    try std.testing.expectEqual(@as(i32, 1), f.value);
}

test "feature: -calt disables contextual alternates" {
    const f = parseFontFeatureToken("-calt").?;
    try std.testing.expectEqualSlices(u8, "calt", &f.tag);
    try std.testing.expectEqual(@as(i32, 0), f.value);
}

test "axis: wght=500" {
    const f = parseFontFeatureToken("wght=500").?;
    try std.testing.expectEqualSlices(u8, "wght", &f.tag);
    try std.testing.expectEqual(@as(i32, 500), f.value);
}

test "axis: MONO=1" {
    const f = parseFontFeatureToken("MONO=1").?;
    try std.testing.expectEqualSlices(u8, "MONO", &f.tag);
    try std.testing.expectEqual(@as(i32, 1), f.value);
}

test "axis: slnt=-12" {
    const f = parseFontFeatureToken("slnt=-12").?;
    try std.testing.expectEqualSlices(u8, "slnt", &f.tag);
    try std.testing.expectEqual(@as(i32, -12), f.value);
}

test "axis: CASL=0" {
    const f = parseFontFeatureToken("CASL=0").?;
    try std.testing.expectEqualSlices(u8, "CASL", &f.tag);
    try std.testing.expectEqual(@as(i32, 0), f.value);
}

test "axis: wdth=87" {
    const f = parseFontFeatureToken("wdth=87").?;
    try std.testing.expectEqualSlices(u8, "wdth", &f.tag);
    try std.testing.expectEqual(@as(i32, 87), f.value);
}

test "reject: short tag" {
    try std.testing.expect(parseFontFeatureToken("ss1") == null);
}

test "reject: long tag" {
    try std.testing.expect(parseFontFeatureToken("ss012") == null);
}

test "reject: h14 is size not feature" {
    try std.testing.expect(parseFontFeatureToken("h14") == null);
}

test "reject: empty string" {
    try std.testing.expect(parseFontFeatureToken("") == null);
}

// ============================================================================
// parseGuiFontCandidate
// ============================================================================

test "guifont: name and size" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const r = try parseGuiFontCandidate(arena.allocator(), "Fira Code:h15");
    try std.testing.expectEqualSlices(u8, "Fira Code", r.name);
    try std.testing.expectEqual(@as(f64, 15.0), r.point_size);
    try std.testing.expectEqual(@as(usize, 0), r.features.len);
}

test "guifont: name only defaults to 14pt" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const r = try parseGuiFontCandidate(arena.allocator(), "Menlo");
    try std.testing.expectEqualSlices(u8, "Menlo", r.name);
    try std.testing.expectEqual(@as(f64, 14.0), r.point_size);
}

test "guifont: features +ss01 -liga zero ss08=2" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const r = try parseGuiFontCandidate(arena.allocator(), "Fira Code:h14:+ss01:-liga:zero:ss08=2");
    try std.testing.expectEqual(@as(usize, 4), r.features.len);
    try std.testing.expectEqualSlices(u8, "ss01", &r.features[0].tag);
    try std.testing.expectEqual(@as(i32, 1), r.features[0].value);
    try std.testing.expectEqualSlices(u8, "liga", &r.features[1].tag);
    try std.testing.expectEqual(@as(i32, 0), r.features[1].value);
    try std.testing.expectEqualSlices(u8, "zero", &r.features[2].tag);
    try std.testing.expectEqual(@as(i32, 1), r.features[2].value);
    try std.testing.expectEqualSlices(u8, "ss08", &r.features[3].tag);
    try std.testing.expectEqual(@as(i32, 2), r.features[3].value);
}

test "guifont: variable axes wght CASL MONO slnt" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const r = try parseGuiFontCandidate(arena.allocator(), "Recursive:h14:wght=500:CASL=1:MONO=1:slnt=-12");
    try std.testing.expectEqualSlices(u8, "Recursive", r.name);
    try std.testing.expectEqual(@as(usize, 4), r.features.len);
    try std.testing.expectEqualSlices(u8, "wght", &r.features[0].tag);
    try std.testing.expectEqual(@as(i32, 500), r.features[0].value);
    try std.testing.expectEqualSlices(u8, "CASL", &r.features[1].tag);
    try std.testing.expectEqual(@as(i32, 1), r.features[1].value);
    try std.testing.expectEqualSlices(u8, "MONO", &r.features[2].tag);
    try std.testing.expectEqual(@as(i32, 1), r.features[2].value);
    try std.testing.expectEqualSlices(u8, "slnt", &r.features[3].tag);
    try std.testing.expectEqual(@as(i32, -12), r.features[3].value);
}

test "guifont: mixed features and axes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const r = try parseGuiFontCandidate(arena.allocator(), "Recursive:h16:+ss01:wght=700:MONO=1:-liga");
    try std.testing.expectEqual(@as(usize, 4), r.features.len);
    try std.testing.expectEqualSlices(u8, "ss01", &r.features[0].tag);
    try std.testing.expectEqualSlices(u8, "wght", &r.features[1].tag);
    try std.testing.expectEqual(@as(i32, 700), r.features[1].value);
    try std.testing.expectEqualSlices(u8, "MONO", &r.features[2].tag);
    try std.testing.expectEqualSlices(u8, "liga", &r.features[3].tag);
    try std.testing.expectEqual(@as(i32, 0), r.features[3].value);
}

test "guifont: wdth axis" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const r = try parseGuiFontCandidate(arena.allocator(), "Inter:h13:wdth=87");
    try std.testing.expectEqual(@as(usize, 1), r.features.len);
    try std.testing.expectEqualSlices(u8, "wdth", &r.features[0].tag);
    try std.testing.expectEqual(@as(i32, 87), r.features[0].value);
}
