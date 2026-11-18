// fc.zig — Hand-written fontconfig declarations for Linux frontend.
//
// Replaces @cImport of fontconfig/fontconfig.h. Functions are resolved
// at link time via libfontconfig. Enables cross-compilation from macOS.

// =========================================================================
// Types
// =========================================================================

pub const FcChar8 = u8;
pub const FcBool = c_int;
pub const FcPattern = opaque {};
pub const FcConfig = opaque {};
pub const FcCharSet = opaque {};

pub const FcResult = enum(c_int) {
    match = 0,
    no_match = 1,
    type_mismatch = 2,
    no_id = 3,
    out_of_memory = 4,
};

pub const FcMatchKind = enum(c_int) {
    pattern = 0,
    font = 1,
    scan = 2,
};

// =========================================================================
// Constants (property name strings)
// =========================================================================

pub const FC_FAMILY: [*:0]const u8 = "family";
pub const FC_FILE: [*:0]const u8 = "file";
pub const FC_WEIGHT: [*:0]const u8 = "weight";
pub const FC_SLANT: [*:0]const u8 = "slant";
pub const FC_INDEX: [*:0]const u8 = "index";
pub const FC_CHARSET: [*:0]const u8 = "charset";
pub const FC_COLOR: [*:0]const u8 = "color";
pub const FC_FONT_VARIATIONS: [*:0]const u8 = "fontvariations";
pub const FC_EMBOLDEN: [*:0]const u8 = "embolden";
pub const FC_MATRIX: [*:0]const u8 = "matrix";

pub const FcMatrix = extern struct { xx: f64, xy: f64, yx: f64, yy: f64 };

// Weight constants
pub const FC_WEIGHT_BOLD: c_int = 200;

// Slant constants
pub const FC_SLANT_ROMAN: c_int = 0;
pub const FC_SLANT_ITALIC: c_int = 100;

// =========================================================================
// Functions (resolved at link time via libfontconfig)
// =========================================================================

pub extern "c" fn FcPatternCreate() ?*FcPattern;
pub extern "c" fn FcPatternDestroy(p: *FcPattern) void;
pub extern "c" fn FcPatternAddString(p: *FcPattern, object: [*:0]const u8, s: [*]const FcChar8) FcBool;
pub extern "c" fn FcPatternAddInteger(p: *FcPattern, object: [*:0]const u8, i: c_int) FcBool;
pub extern "c" fn FcPatternGetString(p: *FcPattern, object: [*:0]const u8, n: c_int, s: *[*c]FcChar8) FcResult;
pub extern "c" fn FcPatternGetInteger(p: *FcPattern, object: [*:0]const u8, n: c_int, i: *c_int) FcResult;
pub extern "c" fn FcPatternGetBool(p: *FcPattern, object: [*:0]const u8, n: c_int, b: *FcBool) FcResult;
pub extern "c" fn FcPatternGetMatrix(p: *FcPattern, object: [*:0]const u8, n: c_int, m: *?*const FcMatrix) FcResult;
pub extern "c" fn FcPatternAddBool(p: *FcPattern, object: [*:0]const u8, b: FcBool) FcBool;
pub extern "c" fn FcPatternAddCharSet(p: *FcPattern, object: [*:0]const u8, c: *const FcCharSet) FcBool;
pub extern "c" fn FcPatternGetCharSet(p: *FcPattern, object: [*:0]const u8, n: c_int, c: *?*FcCharSet) FcResult;
pub extern "c" fn FcCharSetCreate() ?*FcCharSet;
pub extern "c" fn FcCharSetDestroy(c: *FcCharSet) void;
pub extern "c" fn FcCharSetAddChar(c: *FcCharSet, ucs4: u32) FcBool;
pub extern "c" fn FcCharSetHasChar(c: *const FcCharSet, ucs4: u32) FcBool;

pub extern "c" fn FcConfigSubstitute(config: ?*FcConfig, p: *FcPattern, kind: FcMatchKind) FcBool;
pub extern "c" fn FcDefaultSubstitute(pattern: *FcPattern) void;
pub extern "c" fn FcFontMatch(config: ?*FcConfig, p: *FcPattern, result: *FcResult) ?*FcPattern;

// =========================================================================
// Match policy
// =========================================================================

const std = @import("std");

/// Generic names fontconfig resolves by configuration, so any family it picks
/// for them is the one asked for.
const generic_families = [_][]const u8{ "monospace", "mono", "sans-serif", "sans", "serif" };

/// FcFontMatch always returns a font, falling back to an unrelated family for
/// one that is not installed. A guifont candidate that fell back must fail so
/// the next candidate is tried (zonvie_core.h on_guifont).
pub fn familyAccepted(requested: []const u8, matched: []const u8) bool {
    for (generic_families) |g| if (std.ascii.eqlIgnoreCase(requested, g)) return true;
    return std.ascii.eqlIgnoreCase(requested, matched);
}

test "a fallback family is not the requested one" {
    try std.testing.expect(!familyAccepted("Source Code Pro", "Liberation Sans"));
    try std.testing.expect(familyAccepted("dejavu sans mono", "DejaVu Sans Mono"));
    try std.testing.expect(familyAccepted("monospace", "JetBrainsMono Nerd Font"));
}

// Listing the installed families (font_picker.zig).
pub const FcObjectSet = opaque {};
pub const FcFontSet = extern struct { nfont: c_int, sfont: c_int, fonts: ?[*]*FcPattern };
pub const FC_SPACING: [*:0]const u8 = "spacing";
pub const FC_MONO: c_int = 100;
pub extern "c" fn FcObjectSetBuild(first: [*:0]const u8, ...) ?*FcObjectSet;
pub extern "c" fn FcObjectSetDestroy(os: *FcObjectSet) void;
pub extern "c" fn FcFontList(config: ?*FcConfig, p: *FcPattern, os: *FcObjectSet) ?*FcFontSet;
pub extern "c" fn FcFontSetDestroy(s: *FcFontSet) void;

// Fallback lookup by scalar (renderer/font.zig FallbackIndex).
pub const FcSetName = enum(c_int) { system = 0, application = 1 };
pub extern "c" fn FcConfigReference(config: ?*FcConfig) ?*FcConfig;
pub extern "c" fn FcConfigDestroy(config: *FcConfig) void;
pub extern "c" fn FcConfigGetFonts(config: ?*FcConfig, set: FcSetName) ?*FcFontSet;
pub extern "c" fn FcFontSetMatch(config: ?*FcConfig, sets: [*]const *FcFontSet, nsets: c_int, p: *FcPattern, result: *FcResult) ?*FcPattern;
