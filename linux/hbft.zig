// hbft.zig — Hand-written HarfBuzz/FreeType bridge declarations for Linux frontend.
//
// Replaces @cImport of zonvie_hbft.h. Functions are resolved at link time
// via the core static library. Enables cross-compilation from macOS.

// =========================================================================
// Types
// =========================================================================

/// Opaque handle that owns FreeType + HarfBuzz objects.
pub const zonvie_ft_hb_font = opaque {};

// =========================================================================
// Font lifecycle
// =========================================================================

pub extern "c" fn zonvie_ft_hb_font_create(
    font_bytes: [*]const u8,
    font_len: usize,
    pixel_size: u32,
    face_index: u32,
) ?*zonvie_ft_hb_font;

pub extern "c" fn zonvie_ft_hb_font_destroy(f: *zonvie_ft_hb_font) void;

// =========================================================================
// Text shaping
// =========================================================================

/// Shape UTF-32 scalars.
/// Outputs are HarfBuzz position values in 26.6 fixed-point pixels (1px = 64).
/// Returns glyph_count written to outputs (<= out_cap).
pub extern "c" fn zonvie_hb_shape_utf32(
    f: *zonvie_ft_hb_font,
    scalars: [*]const u32,
    scalar_count: usize,
    out_glyph_ids: [*]u32,
    out_clusters: [*]u32,
    out_x_advance: [*]i32,
    out_y_advance: [*]i32,
    out_x_offset: [*]i32,
    out_y_offset: [*]i32,
    out_cap: usize,
    out_font_ascender: *i32,
    out_font_descender: *i32,
    out_font_height: *i32,
) usize;

// =========================================================================
// Glyph rasterization
// =========================================================================

/// Render a glyph to an 8-bit grayscale bitmap (FT_RENDER_MODE_NORMAL).
/// The returned buffer pointer is valid until the next render call on the same font handle.
pub extern "c" fn zonvie_ft_render_glyph(
    f: *zonvie_ft_hb_font,
    glyph_id: u32,
    out_buffer: *?[*]const u8,
    out_width: *c_int,
    out_height: *c_int,
    out_pitch: *c_int,
    out_left: *c_int,
    out_top: *c_int,
    out_advance_x_26_6: *i32,
) c_int;

/// Render a glyph with color support (FT_LOAD_COLOR).
/// For color glyphs (emoji), produces BGRA bitmap (bytes_per_pixel=4).
/// For non-color glyphs, falls back to grayscale (bytes_per_pixel=1).
pub extern "c" fn zonvie_ft_render_glyph_color(
    f: *zonvie_ft_hb_font,
    glyph_id: u32,
    out_buffer: *?[*]const u8,
    out_width: *c_int,
    out_height: *c_int,
    out_pitch: *c_int,
    out_left: *c_int,
    out_top: *c_int,
    out_advance_x_26_6: *i32,
    out_bytes_per_pixel: *c_int,
) c_int;

// =========================================================================
// ASCII fast path
// =========================================================================

/// Retrieve pre-computed ASCII glyph ID table for codepoints 0-127.
/// Caller provides a [128]-element buffer. Returns 1 if valid, 0 if not.
pub extern "c" fn zonvie_ft_hb_get_ascii_glyph_ids(
    f: *zonvie_ft_hb_font,
    out_glyph_ids: [*]u32,
) c_int;

/// Retrieve pre-computed ASCII x-advance table for codepoints 0-127.
pub extern "c" fn zonvie_ft_hb_get_ascii_x_advances(
    f: *zonvie_ft_hb_font,
    out_x_advances: [*]i32,
) c_int;

/// Retrieve pre-computed ASCII ligature trigger table for codepoints 0-127.
pub extern "c" fn zonvie_ft_hb_get_ascii_lig_triggers(
    f: *zonvie_ft_hb_font,
    out_lig_triggers: [*]u8,
) c_int;
