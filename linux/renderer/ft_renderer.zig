// ft_renderer.zig — FreeType + fontconfig rasterization and font discovery for Linux.
//
// Uses the shared HarfBuzz/FreeType C bridge from zonvie_hbft.h.

const std = @import("std");
const app_mod = @import("../app.zig");
const App = app_mod.App;
const applog = app_mod.applog;
const hbft = @import("../hbft.zig");
const fc = @import("../fc.zig");

// =========================================================================
// Font discovery via fontconfig
// =========================================================================

/// Resolve a font family name to a file path using fontconfig.
/// Returns owned file path (caller must free) or null on failure.
pub fn findFontFile(
    alloc: std.mem.Allocator,
    family: []const u8,
    bold: bool,
    italic: bool,
) ?[]const u8 {
    // Create a null-terminated copy of the family name
    const family_z = alloc.dupeZ(u8, family) catch return null;
    defer alloc.free(family_z);

    const pattern = fc.FcPatternCreate() orelse return null;
    defer fc.FcPatternDestroy(pattern);

    _ = fc.FcPatternAddString(pattern, fc.FC_FAMILY, @ptrCast(family_z.ptr));

    if (bold) {
        _ = fc.FcPatternAddInteger(pattern, fc.FC_WEIGHT, fc.FC_WEIGHT_BOLD);
    }
    if (italic) {
        _ = fc.FcPatternAddInteger(pattern, fc.FC_SLANT, fc.FC_SLANT_ITALIC);
    }

    _ = fc.FcConfigSubstitute(null, pattern, .pattern);
    fc.FcDefaultSubstitute(pattern);

    var result: fc.FcResult = undefined;
    const match = fc.FcFontMatch(null, pattern, &result) orelse return null;
    defer fc.FcPatternDestroy(match);

    var file_ptr: [*c]fc.FcChar8 = undefined;
    if (fc.FcPatternGetString(match, fc.FC_FILE, 0, &file_ptr) != .match) {
        return null;
    }

    const file_slice: []const u8 = std.mem.span(@as([*:0]const u8, @ptrCast(file_ptr)));
    return alloc.dupe(u8, file_slice) catch null;
}

/// Resolve a font family and load FreeType/HarfBuzz font handles.
/// Sets app.ft_hb_font and optionally bold/italic variants.
pub fn loadFont(
    alloc: std.mem.Allocator,
    app: *App,
    family: []const u8,
    size_pt: f32,
    dpi_scale: f32,
) bool {
    // Destroy existing fonts
    destroyFonts(app);

    const pixel_size: u32 = @intFromFloat(size_pt * dpi_scale);
    if (pixel_size == 0) return false;

    // Regular
    const regular_path = findFontFile(alloc, family, false, false) orelse {
        applog.appLog("[ft] Failed to find font: {s}\n", .{family});
        return false;
    };
    defer alloc.free(regular_path);

    app.ft_hb_font = loadFontFromPath(alloc, regular_path, pixel_size);
    if (app.ft_hb_font == null) {
        applog.appLog("[ft] Failed to load font file: {s}\n", .{regular_path});
        return false;
    }

    // Bold
    if (findFontFile(alloc, family, true, false)) |bold_path| {
        defer alloc.free(bold_path);
        app.ft_hb_font_bold = loadFontFromPath(alloc, bold_path, pixel_size);
    }

    // Italic
    if (findFontFile(alloc, family, false, true)) |italic_path| {
        defer alloc.free(italic_path);
        app.ft_hb_font_italic = loadFontFromPath(alloc, italic_path, pixel_size);
    }

    // Bold italic
    if (findFontFile(alloc, family, true, true)) |bi_path| {
        defer alloc.free(bi_path);
        app.ft_hb_font_bold_italic = loadFontFromPath(alloc, bi_path, pixel_size);
    }

    // Compute cell metrics from font
    computeCellMetrics(app);

    if (applog.isEnabled()) {
        applog.appLog("[ft] Loaded font: {s} size={d}pt pixel={d} dpi_scale={d:.2} cell={d}x{d}\n", .{
            family, size_pt, pixel_size, dpi_scale, app.cell_w_px, app.cell_h_px,
        });
    }

    return true;
}

/// Compute cell width and height from the regular font metrics.
/// Uses HarfBuzz shaping of a space character to get x_advance (cell width),
/// and font ascender/descender for cell height.
pub fn computeCellMetrics(app: *App) void {
    const font: *hbft.zonvie_ft_hb_font = @ptrCast(app.ft_hb_font orelse return);

    // Shape a space to get the monospace cell advance
    const space_scalar: u32 = 0x20;
    var glyph_id: u32 = 0;
    var cluster: u32 = 0;
    var x_advance: i32 = 0;
    var y_advance: i32 = 0;
    var x_offset: i32 = 0;
    var y_offset: i32 = 0;
    var ascender: i32 = 0;
    var descender: i32 = 0;
    var font_height: i32 = 0;

    const count = hbft.zonvie_hb_shape_utf32(
        font,
        @as([*]const u32, @ptrCast(&space_scalar)),
        1,
        @as([*]u32, @ptrCast(&glyph_id)),
        @as([*]u32, @ptrCast(&cluster)),
        @as([*]i32, @ptrCast(&x_advance)),
        @as([*]i32, @ptrCast(&y_advance)),
        @as([*]i32, @ptrCast(&x_offset)),
        @as([*]i32, @ptrCast(&y_offset)),
        1,
        &ascender,
        &descender,
        &font_height,
    );

    if (count == 0) return;

    // x_advance is in 26.6 fixed-point (1px = 64 units)
    const cell_w: u32 = @intCast(@max(1, @divTrunc(x_advance + 32, 64)));
    // font_height is in 26.6 fixed-point
    const cell_h: u32 = @intCast(@max(1, @divTrunc(font_height + 32, 64)));

    app.cell_w_px = cell_w;
    app.cell_h_px = cell_h;
    app.font_ascent_26_6 = ascender;
    app.font_descent_26_6 = descender;
}

/// Load a font from a file path, returning an opaque font handle.
fn loadFontFromPath(alloc: std.mem.Allocator, path: []const u8, pixel_size: u32) ?*anyopaque {
    // Read font file into memory
    const file = std.fs.openFileAbsolute(path, .{}) catch return null;
    defer file.close();

    const stat = file.stat() catch return null;
    const font_bytes = alloc.alloc(u8, stat.size) catch return null;
    // Note: font_bytes must remain valid for the lifetime of the font handle.
    // The hbft bridge does NOT copy the data.
    const bytes_read = file.readAll(font_bytes) catch {
        alloc.free(font_bytes);
        return null;
    };
    if (bytes_read != font_bytes.len) {
        alloc.free(font_bytes);
        return null;
    }

    const font = hbft.zonvie_ft_hb_font_create(
        font_bytes.ptr,
        font_bytes.len,
        pixel_size,
        0, // face_index
    );
    if (font == null) {
        alloc.free(font_bytes);
        return null;
    }

    return font;
}

/// Destroy all loaded font handles.
pub fn destroyFonts(app: *App) void {
    if (app.ft_hb_font) |f| {
        hbft.zonvie_ft_hb_font_destroy(@ptrCast(f));
        app.ft_hb_font = null;
    }
    if (app.ft_hb_font_bold) |f| {
        hbft.zonvie_ft_hb_font_destroy(@ptrCast(f));
        app.ft_hb_font_bold = null;
    }
    if (app.ft_hb_font_italic) |f| {
        hbft.zonvie_ft_hb_font_destroy(@ptrCast(f));
        app.ft_hb_font_italic = null;
    }
    if (app.ft_hb_font_bold_italic) |f| {
        hbft.zonvie_ft_hb_font_destroy(@ptrCast(f));
        app.ft_hb_font_bold_italic = null;
    }
}

// =========================================================================
// Glyph rasterization callbacks (Phase 2: core-managed atlas)
// =========================================================================

/// Get the appropriate font handle for the given style flags.
fn getFontForStyle(app: *App, style_flags: u32) ?*hbft.zonvie_ft_hb_font {
    const bold = (style_flags & 1) != 0; // ZONVIE_STYLE_BOLD
    const italic = (style_flags & 2) != 0; // ZONVIE_STYLE_ITALIC

    if (bold and italic) {
        if (app.ft_hb_font_bold_italic) |f| return @ptrCast(f);
    }
    if (bold) {
        if (app.ft_hb_font_bold) |f| return @ptrCast(f);
    }
    if (italic) {
        if (app.ft_hb_font_italic) |f| return @ptrCast(f);
    }
    if (app.ft_hb_font) |f| return @ptrCast(f);
    return null;
}

/// Rasterize a glyph by Unicode scalar (Phase 2 callback).
pub fn rasterizeGlyph(
    app: *App,
    scalar: u32,
    style_flags: u32,
    out_bitmap: *app_mod.GlyphBitmap,
) bool {
    const font = getFontForStyle(app, style_flags) orelse return false;

    // First try color rendering (for emoji)
    var buffer: [*c]const u8 = null;
    var width: c_int = 0;
    var height: c_int = 0;
    var pitch: c_int = 0;
    var left: c_int = 0;
    var top: c_int = 0;
    var advance_26_6: i32 = 0;
    var bpp: c_int = 0;

    // Try to get glyph ID first via shaping single scalar
    var glyph_id: u32 = 0;
    var cluster: u32 = 0;
    var x_advance: i32 = 0;
    var y_advance: i32 = 0;
    var x_offset: i32 = 0;
    var y_offset: i32 = 0;
    var ascender: i32 = 0;
    var descender: i32 = 0;
    var font_height: i32 = 0;

    const glyph_count = hbft.zonvie_hb_shape_utf32(
        font,
        @as([*]const u32, @ptrCast(&scalar)),
        1,
        @as([*]u32, @ptrCast(&glyph_id)),
        @as([*]u32, @ptrCast(&cluster)),
        @as([*]i32, @ptrCast(&x_advance)),
        @as([*]i32, @ptrCast(&y_advance)),
        @as([*]i32, @ptrCast(&x_offset)),
        @as([*]i32, @ptrCast(&y_offset)),
        1,
        &ascender,
        &descender,
        &font_height,
    );

    if (glyph_count == 0) return false;

    // Try color rendering
    const color_result = hbft.zonvie_ft_render_glyph_color(
        font,
        glyph_id,
        &buffer,
        &width,
        &height,
        &pitch,
        &left,
        &top,
        &advance_26_6,
        &bpp,
    );

    if (color_result == 0 and buffer != null) {
        out_bitmap.pixels = buffer;
        out_bitmap.width = @intCast(width);
        out_bitmap.height = @intCast(height);
        out_bitmap.pitch = pitch;
        out_bitmap.bearing_x = left;
        out_bitmap.bearing_y = top;
        out_bitmap.advance_26_6 = advance_26_6;
        out_bitmap.ascent_px = @as(f32, @floatFromInt(ascender)) / 64.0;
        out_bitmap.descent_px = @as(f32, @floatFromInt(descender)) / 64.0;
        out_bitmap.bytes_per_pixel = @intCast(bpp);
        return true;
    }

    // Fallback to grayscale
    const gray_result = hbft.zonvie_ft_render_glyph(
        font,
        glyph_id,
        &buffer,
        &width,
        &height,
        &pitch,
        &left,
        &top,
        &advance_26_6,
    );

    if (gray_result == 0 and buffer != null) {
        out_bitmap.pixels = buffer;
        out_bitmap.width = @intCast(width);
        out_bitmap.height = @intCast(height);
        out_bitmap.pitch = pitch;
        out_bitmap.bearing_x = left;
        out_bitmap.bearing_y = top;
        out_bitmap.advance_26_6 = advance_26_6;
        out_bitmap.ascent_px = @as(f32, @floatFromInt(ascender)) / 64.0;
        out_bitmap.descent_px = @as(f32, @floatFromInt(descender)) / 64.0;
        out_bitmap.bytes_per_pixel = 1;
        return true;
    }

    return false;
}

/// Rasterize a glyph by glyph ID (post-shaping, Phase 2 callback).
pub fn rasterizeGlyphById(
    app: *App,
    glyph_id: u32,
    style_flags: u32,
    out_bitmap: *app_mod.GlyphBitmap,
) bool {
    const font = getFontForStyle(app, style_flags) orelse return false;

    var buffer: [*c]const u8 = null;
    var width: c_int = 0;
    var height: c_int = 0;
    var pitch: c_int = 0;
    var left: c_int = 0;
    var top: c_int = 0;
    var advance_26_6: i32 = 0;
    var bpp: c_int = 0;

    // Try color rendering first
    const color_result = hbft.zonvie_ft_render_glyph_color(
        font,
        glyph_id,
        &buffer,
        &width,
        &height,
        &pitch,
        &left,
        &top,
        &advance_26_6,
        &bpp,
    );

    const asc_px: f32 = @as(f32, @floatFromInt(app.font_ascent_26_6)) / 64.0;
    const desc_px: f32 = @as(f32, @floatFromInt(app.font_descent_26_6)) / 64.0;

    if (color_result == 0 and buffer != null) {
        out_bitmap.pixels = buffer;
        out_bitmap.width = @intCast(width);
        out_bitmap.height = @intCast(height);
        out_bitmap.pitch = pitch;
        out_bitmap.bearing_x = left;
        out_bitmap.bearing_y = top;
        out_bitmap.advance_26_6 = advance_26_6;
        out_bitmap.ascent_px = asc_px;
        out_bitmap.descent_px = desc_px;
        out_bitmap.bytes_per_pixel = @intCast(bpp);
        return true;
    }

    // Fallback to grayscale
    const gray_result = hbft.zonvie_ft_render_glyph(
        font,
        glyph_id,
        &buffer,
        &width,
        &height,
        &pitch,
        &left,
        &top,
        &advance_26_6,
    );

    if (gray_result == 0 and buffer != null) {
        out_bitmap.pixels = buffer;
        out_bitmap.width = @intCast(width);
        out_bitmap.height = @intCast(height);
        out_bitmap.pitch = pitch;
        out_bitmap.bearing_x = left;
        out_bitmap.bearing_y = top;
        out_bitmap.advance_26_6 = advance_26_6;
        out_bitmap.ascent_px = asc_px;
        out_bitmap.descent_px = desc_px;
        out_bitmap.bytes_per_pixel = 1;
        return true;
    }

    return false;
}

// =========================================================================
// Text shaping callbacks
// =========================================================================

/// Shape a text run using HarfBuzz.
pub fn shapeTextRun(
    app: *App,
    scalars: [*]const u32,
    scalar_count: usize,
    style_flags: u32,
    out_glyph_ids: [*]u32,
    out_clusters: [*]u32,
    out_x_advance: [*]i32,
    out_x_offset: [*]i32,
    out_y_offset: [*]i32,
    out_cap: usize,
) usize {
    const font = getFontForStyle(app, style_flags) orelse return 0;

    var y_advances: [256]i32 = undefined;
    var ascender: i32 = 0;
    var descender: i32 = 0;
    var font_height: i32 = 0;

    const result = hbft.zonvie_hb_shape_utf32(
        font,
        scalars,
        scalar_count,
        out_glyph_ids,
        out_clusters,
        out_x_advance,
        &y_advances,
        out_x_offset,
        out_y_offset,
        out_cap,
        &ascender,
        &descender,
        &font_height,
    );

    return result;
}

/// Get pre-computed ASCII shaping tables for a style variant.
pub fn getAsciiTable(
    app: *App,
    style_flags: u32,
    out_glyph_ids: [*]u32,
    out_x_advances: [*]i32,
    out_lig_triggers: [*]u8,
) bool {
    const font = getFontForStyle(app, style_flags) orelse return false;

    if (hbft.zonvie_ft_hb_get_ascii_glyph_ids(font, out_glyph_ids) == 0) return false;
    if (hbft.zonvie_ft_hb_get_ascii_x_advances(font, out_x_advances) == 0) return false;
    if (hbft.zonvie_ft_hb_get_ascii_lig_triggers(font, out_lig_triggers) == 0) return false;

    if (applog.isEnabled()) {
        // Check glyph IDs for 'A' (0x41), 'a' (0x61), ' ' (0x20)
        applog.appLog("[ft] getAsciiTable style={d}: gid['A']={d} gid['a']={d} gid[' ']={d} adv['A']={d}\n", .{
            style_flags, out_glyph_ids[0x41], out_glyph_ids[0x61], out_glyph_ids[0x20], out_x_advances[0x41],
        });
    }

    return true;
}
