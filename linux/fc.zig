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

// Weight constants
pub const FC_WEIGHT_BOLD: c_int = 200;

// Slant constants
pub const FC_SLANT_ITALIC: c_int = 100;

// =========================================================================
// Functions (resolved at link time via libfontconfig)
// =========================================================================

pub extern "c" fn FcPatternCreate() ?*FcPattern;
pub extern "c" fn FcPatternDestroy(p: *FcPattern) void;
pub extern "c" fn FcPatternAddString(p: *FcPattern, object: [*:0]const u8, s: [*]const FcChar8) FcBool;
pub extern "c" fn FcPatternAddInteger(p: *FcPattern, object: [*:0]const u8, i: c_int) FcBool;
pub extern "c" fn FcPatternGetString(p: *FcPattern, object: [*:0]const u8, n: c_int, s: *[*c]FcChar8) FcResult;

pub extern "c" fn FcConfigSubstitute(config: ?*FcConfig, p: *FcPattern, kind: FcMatchKind) FcBool;
pub extern "c" fn FcDefaultSubstitute(pattern: *FcPattern) void;
pub extern "c" fn FcFontMatch(config: ?*FcConfig, p: *FcPattern, result: *FcResult) ?*FcPattern;
