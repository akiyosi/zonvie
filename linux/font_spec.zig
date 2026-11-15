//! What face to load, decided without touching fontconfig or FreeType:
//! a per-grid font's candidate line, the variation coordinates a face is
//! opened at, and the styles to synthesize. Pure; renderer/font.zig is the
//! shell that loads what these say.

const std = @import("std");
const Axis = @import("hbft.zig").zonvie_font_axis;

/// The global font a slot payload falls back to.
pub const Defaults = struct {
    family: []const u8,
    point_size: f32,
    features: []const u8,
};

pub const SlotFont = struct {
    family: []const u8,
    point_size: f32,
    features: []const u8,
    /// The line named no family: the global face, in the global style.
    global_face: bool,
};

/// One `<name>\t<size>[\t<features>]` line of an on_font_slot_load payload
/// (zonvie_core.h). An empty name is the global font, with the global
/// features unless the line names its own; a missing or non-positive size is
/// the global size. The size is multiplied by `scale`. Null when no face can
/// come of it. Slices point into `line` or `global`.
pub fn slotCandidate(line: []const u8, global: Defaults, scale: f32) ?SlotFont {
    var fields = std.mem.splitScalar(u8, line, '\t');
    const name = fields.next() orelse "";
    const size_pt = std.fmt.parseFloat(f32, fields.next() orelse "") catch 0;
    const features = fields.rest();
    const family = if (name.len != 0) name else global.family;
    const pt = (if (size_pt > 0) size_pt else global.point_size) * scale;
    if (family.len == 0 or !(pt > 0)) return null;
    return .{
        .family = family,
        .point_size = pt,
        .features = if (features.len != 0 or name.len != 0) features else global.features,
        .global_face = name.len == 0,
    };
}

/// fontconfig's FC_FONT_VARIATIONS ("wght=700,wdth=87.5") into `out`;
/// malformed entries are skipped. Returns the filled prefix.
pub fn parseVariations(s: []const u8, out: []Axis) []Axis {
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, s, ',');
    while (it.next()) |raw| {
        if (n == out.len) break;
        const entry = std.mem.trim(u8, raw, " ");
        const eq = std.mem.indexOfScalar(u8, entry, '=') orelse continue;
        const tag = entry[0..eq];
        if (tag.len != 4) continue;
        const value = std.fmt.parseFloat(f32, entry[eq + 1 ..]) catch continue;
        out[n] = .{ .tag = tag[0..4].*, .value = value };
        n += 1;
    }
    return out[0..n];
}

/// `layers` folded first to last: a later layer's axis replaces an earlier
/// one with the same tag, as macOS FontInstanceAxes.merged puts the user's
/// axes over an instance's. Order: the instance's coordinates, fontconfig's
/// variations, the user's [font] entries. Entries past `out.len` are dropped.
pub fn mergeAxes(out: []Axis, layers: []const []const Axis) []Axis {
    var n: usize = 0;
    for (layers) |layer| {
        for (layer) |a| {
            const slot = for (out[0..n], 0..) |o, i| {
                if (std.mem.eql(u8, &o.tag, &a.tag)) break i;
            } else blk: {
                if (n == out.len) break :blk null;
                n += 1;
                break :blk n - 1;
            };
            if (slot) |i| out[i] = a;
        }
    }
    return out[0..n];
}

/// fontconfig's weight and slant scale (fontconfig.h).
pub const fc_weight_demibold: c_int = 180;
pub const fc_slant_roman: c_int = 0;

pub const Synthetic = struct { bold: bool = false, oblique: bool = false };

/// The styles a matched face must simulate: what was asked for and the face
/// fontconfig found lacks, as DirectWrite simulates a family's missing bold
/// or italic.
///
/// fontconfig's own verdict comes first: its 90-synthetic.conf marks such a
/// match `embolden` or gives it a slanting `matrix`, and then reports the
/// weight and slant asked for, not the face's. Without that rule the matched
/// weight and slant are the face's own, and a regular one answering a bold or
/// italic request is the missing style. `weight`/`slant` null = fontconfig
/// did not say (a variable font's range), which is not taken as missing.
pub const MatchStyle = struct {
    weight: ?c_int = null,
    slant: ?c_int = null,
    fc_embolden: bool = false,
    fc_oblique: bool = false,
};

pub fn synthetic(want_bold: bool, want_italic: bool, m: MatchStyle) Synthetic {
    const regular_weight = if (m.weight) |w| w < fc_weight_demibold else false;
    const roman = if (m.slant) |s| s == fc_slant_roman else false;
    return .{
        .bold = want_bold and (m.fc_embolden or regular_weight),
        .oblique = want_italic and (m.fc_oblique or roman),
    };
}

const testing = std.testing;

const test_global: Defaults = .{ .family = "Iosevka", .point_size = 12, .features = "+ss01" };

/// FreeType's face_index for fontconfig's FC_INDEX: the face number in the
/// low 16 bits, the named instance (1-based, 0 none) in bits 16-30.
/// fontconfig gives a variable face's "any instance" pattern instance
/// 0x8000, which makes the int negative and is no instance FreeType knows:
/// that face opens at its default coordinates (instance 0), its face
/// number kept.
pub fn ftFaceIndex(fc_index: c_int) u32 {
    const bits: u32 = @bitCast(fc_index);
    const face = bits & 0xffff;
    const instance = bits >> 16;
    if (instance == 0x8000) return face;
    return face | ((instance & 0x7fff) << 16);
}

test "a fontconfig index keeps its face and named instance for FreeType" {
    try std.testing.expectEqual(@as(u32, 0), ftFaceIndex(0));
    try std.testing.expectEqual(@as(u32, 2), ftFaceIndex(2));
    // Face 1, named instance 3.
    try std.testing.expectEqual(@as(u32, 0x30001), ftFaceIndex(0x30001));
    // The variable "any instance" pattern of face 2 of a collection.
    try std.testing.expectEqual(@as(u32, 2), ftFaceIndex(@bitCast(@as(u32, 0x80000002))));
}

test "an empty slot line is the global font at its size times scale" {
    const c = slotCandidate("", test_global, 1.5).?;
    try testing.expectEqualStrings("Iosevka", c.family);
    try testing.expectEqual(@as(f32, 18), c.point_size);
    try testing.expectEqualStrings("+ss01", c.features);
    try testing.expect(c.global_face);
}

test "a named slot line keeps its own size and features" {
    const c = slotCandidate("Fira Code\t14\t-liga", test_global, 2).?;
    try testing.expectEqualStrings("Fira Code", c.family);
    try testing.expectEqual(@as(f32, 28), c.point_size);
    try testing.expectEqualStrings("-liga", c.features);
    // Another family does not inherit the global font's features.
    try testing.expectEqualStrings("", slotCandidate("Fira Code\t14", test_global, 1).?.features);
}

test "a slot line with no size takes the global size" {
    try testing.expectEqual(@as(f32, 12), slotCandidate("Fira Code\t", test_global, 1).?.point_size);
    try testing.expectEqual(@as(f32, 12), slotCandidate("Fira Code", test_global, 1).?.point_size);
}

test "no slot font without a family or a size" {
    try testing.expect(slotCandidate("", .{ .family = "", .point_size = 12, .features = "" }, 1) == null);
    try testing.expect(slotCandidate("X\t12", test_global, 0) == null);
}

test "fontconfig variations parse and skip malformed entries" {
    var buf: [4]Axis = undefined;
    const v = parseVariations("wght=700, wdth=87.5,bad,toolong=1,opsz=x", &buf);
    try testing.expectEqual(@as(usize, 2), v.len);
    try testing.expectEqualStrings("wght", &v[0].tag);
    try testing.expectEqual(@as(f32, 700), v[0].value);
    try testing.expectEqual(@as(f32, 87.5), v[1].value);
}

test "later axis layers replace earlier ones by tag, order kept" {
    const inst = [_]Axis{ .{ .tag = "wght".*, .value = 700 }, .{ .tag = "wdth".*, .value = 100 } };
    const user = [_]Axis{ .{ .tag = "wdth".*, .value = 87 }, .{ .tag = "liga".*, .value = 1 } };
    var out: [8]Axis = undefined;
    const m = mergeAxes(&out, &.{ &inst, &.{}, &user });
    try testing.expectEqual(@as(usize, 3), m.len);
    try testing.expectEqual(@as(f32, 700), m[0].value);
    try testing.expectEqual(@as(f32, 87), m[1].value);
    try testing.expectEqualStrings("liga", &m[2].tag);
}

test "a full axis buffer still takes replacements" {
    const a = [_]Axis{.{ .tag = "wght".*, .value = 400 }};
    const b = [_]Axis{ .{ .tag = "opsz".*, .value = 9 }, .{ .tag = "wght".*, .value = 650 } };
    var out: [1]Axis = undefined;
    const m = mergeAxes(&out, &.{ &a, &b });
    try testing.expectEqual(@as(usize, 1), m.len);
    try testing.expectEqual(@as(f32, 650), m[0].value);
}

test "a regular face answering a styled request is simulated" {
    try testing.expectEqual(Synthetic{ .bold = true, .oblique = true }, synthetic(true, true, .{ .weight = 80, .slant = 0 }));
    try testing.expectEqual(Synthetic{}, synthetic(true, true, .{ .weight = 200, .slant = 100 }));
    // A real oblique face (110) is a slant already.
    try testing.expectEqual(Synthetic{}, synthetic(false, true, .{ .weight = 80, .slant = 110 }));
    try testing.expectEqual(Synthetic{}, synthetic(false, false, .{ .weight = 80, .slant = 0 }));
    // Unknown (a variable range) is not missing.
    try testing.expectEqual(Synthetic{}, synthetic(true, true, .{}));
}

test "fontconfig's synthesis hints win over the weight and slant it reports" {
    // 90-synthetic.conf: Regular answering bold italic reports 200/110.
    const hinted: MatchStyle = .{ .weight = 200, .slant = 110, .fc_embolden = true, .fc_oblique = true };
    try testing.expectEqual(Synthetic{ .bold = true, .oblique = true }, synthetic(true, true, hinted));
    // Hints for a style not asked for are ignored.
    try testing.expectEqual(Synthetic{}, synthetic(false, false, hinted));
}
