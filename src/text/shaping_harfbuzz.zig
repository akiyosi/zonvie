const std = @import("std");
const Allocator = std.mem.Allocator;

// You already have a harfbuzz package in the repo (pkg/harfbuzz).
// Adjust this import to match your build/package wiring.
const hb = @import("harfbuzz");

pub const ShapedGlyph = struct {
    glyph_id: u32,
    cluster: u32,

    /// Advances/offsets are in 26.6 fixed-point pixels (HarfBuzz convention when using hb_font_set_scale).
    x_advance_26_6: i32,
    y_advance_26_6: i32,
    x_offset_26_6: i32,
    y_offset_26_6: i32,
};

pub const ShapeOptions = struct {
    direction: hb.hb_direction_t = hb.HB_DIRECTION_LTR,
    script: hb.hb_script_t = hb.HB_SCRIPT_INVALID,
    language: ?[:0]const u8 = null, // e.g. "ja"
};

pub fn shapeUtf8(
    allocator: Allocator,
    hb_font: *hb.hb_font_t,
    text_utf8: []const u8,
    opts: ShapeOptions,
) ![]ShapedGlyph {
    var buf = hb.hb_buffer_create() orelse return error.OutOfMemory;
    defer hb.hb_buffer_destroy(buf);

    hb.hb_buffer_set_direction(buf, opts.direction);
    hb.hb_buffer_set_script(buf, opts.script);

    if (opts.language) |lang_cstr| {
        const lang = hb.hb_language_from_string(lang_cstr.ptr, -1);
        hb.hb_buffer_set_language(buf, lang);
    }

    // Add UTF-8 bytes
    hb.hb_buffer_add_utf8(buf, text_utf8.ptr, @intCast(text_utf8.len), 0, @intCast(text_utf8.len));

    // Let HarfBuzz infer segment props if script/lang are invalid or unspecified.
    hb.hb_buffer_guess_segment_properties(buf);

    // Shape
    hb.hb_shape(hb_font, buf, null, 0);

    var length: u32 = 0;
    const infos = hb.hb_buffer_get_glyph_infos(buf, &length) orelse return error.ShapeFailed;
    const poss = hb.hb_buffer_get_glyph_positions(buf, &length) orelse return error.ShapeFailed;

    var out = try allocator.alloc(ShapedGlyph, length);
    errdefer allocator.free(out);

    var i: u32 = 0;
    while (i < length) : (i += 1) {
        out[i] = .{
            .glyph_id = infos[i].codepoint,
            .cluster = infos[i].cluster,
            .x_advance_26_6 = poss[i].x_advance,
            .y_advance_26_6 = poss[i].y_advance,
            .x_offset_26_6 = poss[i].x_offset,
            .y_offset_26_6 = poss[i].y_offset,
        };
    }

    return out;
}

