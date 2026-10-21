//! Font loading (fontconfig → hbft) and the rasterize/shape/ascii-table
//! work behind the core's atlas callbacks. Touched only on the core thread.

const std = @import("std");
const core = @import("zonvie_core");
const clock = core.clock;
const hbft = @import("../hbft.zig");
const fc = @import("../fc.zig");
const applog = @import("../app_log.zig");

const Font = hbft.zonvie_ft_hb_font;

pub const Fonts = struct {
    regular: ?*Font = null,
    bold: ?*Font = null,
    italic: ?*Font = null,
    bold_italic: ?*Font = null,
    ascent_26_6: i32 = 0,
    descent_26_6: i32 = 0,
    cell_w_px: u32 = 0,
    cell_h_px: u32 = 0,
    /// HarfBuzz writes y advances the core does not ask for; grown to out_cap.
    y_advance_scratch: std.ArrayListUnmanaged(i32) = .empty,

    pub fn deinit(self: *Fonts, alloc: std.mem.Allocator) void {
        self.destroyFaces();
        self.y_advance_scratch.deinit(alloc);
    }

    fn destroyFaces(self: *Fonts) void {
        inline for (.{ "regular", "bold", "italic", "bold_italic" }) |f| {
            if (@field(self, f)) |h| hbft.zonvie_ft_hb_font_destroy(h);
            @field(self, f) = null;
        }
    }

    /// Replaces every face only once the regular face loaded, so a bad
    /// candidate keeps the current font.
    pub fn load(self: *Fonts, alloc: std.mem.Allocator, family: []const u8, pixel_size: u32) bool {
        if (pixel_size == 0) return false;
        const regular = loadFace(alloc, family, false, false, pixel_size) orelse return false;
        self.destroyFaces();
        self.regular = regular;
        self.bold = loadFace(alloc, family, true, false, pixel_size);
        self.italic = loadFace(alloc, family, false, true, pixel_size);
        self.bold_italic = loadFace(alloc, family, true, true, pixel_size);
        self.computeCellMetrics();
        return true;
    }

    fn computeCellMetrics(self: *Fonts) void {
        const font = self.regular orelse return;
        const space: u32 = 0x20;
        var gid: u32 = 0;
        var cluster: u32 = 0;
        var x_adv: i32 = 0;
        var y_adv: i32 = 0;
        var x_off: i32 = 0;
        var y_off: i32 = 0;
        var asc: i32 = 0;
        var desc: i32 = 0;
        var height: i32 = 0;
        const n = hbft.zonvie_hb_shape_utf32(font, @ptrCast(&space), 1, @ptrCast(&gid), @ptrCast(&cluster), @ptrCast(&x_adv), @ptrCast(&y_adv), @ptrCast(&x_off), @ptrCast(&y_off), 1, &asc, &desc, &height);
        if (n == 0) return;
        self.cell_w_px = @intCast(@max(1, @divTrunc(x_adv + 32, 64)));
        self.cell_h_px = @intCast(@max(1, @divTrunc(height + 32, 64)));
        self.ascent_26_6 = asc;
        self.descent_26_6 = desc;
    }

    fn forStyle(self: *const Fonts, style_flags: u32) ?*Font {
        const bold = style_flags & core.STYLE_BOLD != 0;
        const italic = style_flags & core.STYLE_ITALIC != 0;
        if (bold and italic) if (self.bold_italic) |f| return f;
        if (bold) if (self.bold) |f| return f;
        if (italic) if (self.italic) |f| return f;
        return self.regular;
    }

    pub fn rasterizeScalar(self: *Fonts, scalar: u32, style_flags: u32, out: *core.GlyphBitmap) bool {
        const font = self.forStyle(style_flags) orelse return false;
        var gid: u32 = 0;
        var cluster: u32 = 0;
        var x_adv: i32 = 0;
        var y_adv: i32 = 0;
        var x_off: i32 = 0;
        var y_off: i32 = 0;
        var asc: i32 = 0;
        var desc: i32 = 0;
        var height: i32 = 0;
        const n = hbft.zonvie_hb_shape_utf32(font, @ptrCast(&scalar), 1, @ptrCast(&gid), @ptrCast(&cluster), @ptrCast(&x_adv), @ptrCast(&y_adv), @ptrCast(&x_off), @ptrCast(&y_off), 1, &asc, &desc, &height);
        if (n == 0) return false;
        return self.render(font, gid, out);
    }

    pub fn rasterizeGlyphId(self: *Fonts, glyph_id: u32, style_flags: u32, out: *core.GlyphBitmap) bool {
        const font = self.forStyle(style_flags) orelse return false;
        return self.render(font, glyph_id, out);
    }

    fn render(self: *const Fonts, font: *Font, glyph_id: u32, out: *core.GlyphBitmap) bool {
        var buf: ?[*]const u8 = null;
        var w: c_int = 0;
        var h: c_int = 0;
        var pitch: c_int = 0;
        var left: c_int = 0;
        var top: c_int = 0;
        var adv: i32 = 0;
        var bpp: c_int = 1;
        if (hbft.zonvie_ft_render_glyph_color(font, glyph_id, &buf, &w, &h, &pitch, &left, &top, &adv, &bpp) != 0) {
            bpp = 1;
            if (hbft.zonvie_ft_render_glyph(font, glyph_id, &buf, &w, &h, &pitch, &left, &top, &adv) != 0) return false;
        }
        out.* = .{
            .pixels = buf,
            .width = @intCast(@max(0, w)),
            .height = @intCast(@max(0, h)),
            .pitch = pitch,
            .bearing_x = left,
            .bearing_y = top,
            .advance_26_6 = adv,
            // The regular face's metrics: every style shares one baseline.
            .ascent_px = @as(f32, @floatFromInt(self.ascent_26_6)) / 64.0,
            .descent_px = @as(f32, @floatFromInt(self.descent_26_6)) / 64.0,
            .bytes_per_pixel = @intCast(bpp),
        };
        return true;
    }

    pub fn shape(
        self: *Fonts,
        alloc: std.mem.Allocator,
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
        const font = self.forStyle(style_flags) orelse return 0;
        self.y_advance_scratch.resize(alloc, out_cap) catch return 0;
        var asc: i32 = 0;
        var desc: i32 = 0;
        var height: i32 = 0;
        return hbft.zonvie_hb_shape_utf32(font, scalars, scalar_count, out_glyph_ids, out_clusters, out_x_advance, self.y_advance_scratch.items.ptr, out_x_offset, out_y_offset, out_cap, &asc, &desc, &height);
    }

    pub fn asciiTable(self: *const Fonts, style_flags: u32, gids: [*]u32, advs: [*]i32, ligs: [*]u8) bool {
        const font = self.forStyle(style_flags) orelse return false;
        return hbft.zonvie_ft_hb_get_ascii_glyph_ids(font, gids) != 0 and
            hbft.zonvie_ft_hb_get_ascii_x_advances(font, advs) != 0 and
            hbft.zonvie_ft_hb_get_ascii_lig_triggers(font, ligs) != 0;
    }
};

/// zonvie_ft_hb_font_create copies the bytes (HBFTBridge.c:150-152), so they
/// are freed right after.
fn loadFace(alloc: std.mem.Allocator, family: []const u8, bold: bool, italic: bool, pixel_size: u32) ?*Font {
    const path = findFontFile(alloc, family, bold, italic) orelse return null;
    defer alloc.free(path);
    const bytes = std.Io.Dir.cwd().readFileAlloc(clock.io(), path, alloc, .unlimited) catch return null;
    defer alloc.free(bytes);
    const f = hbft.zonvie_ft_hb_font_create(bytes.ptr, bytes.len, pixel_size, 0);
    if (f == null) applog.appLog("[font] failed to load {s}\n", .{path});
    return f;
}

fn findFontFile(alloc: std.mem.Allocator, family: []const u8, bold: bool, italic: bool) ?[]u8 {
    const family_z = alloc.dupeZ(u8, family) catch return null;
    defer alloc.free(family_z);
    const pattern = fc.FcPatternCreate() orelse return null;
    defer fc.FcPatternDestroy(pattern);
    _ = fc.FcPatternAddString(pattern, fc.FC_FAMILY, family_z.ptr);
    if (bold) _ = fc.FcPatternAddInteger(pattern, fc.FC_WEIGHT, fc.FC_WEIGHT_BOLD);
    if (italic) _ = fc.FcPatternAddInteger(pattern, fc.FC_SLANT, fc.FC_SLANT_ITALIC);
    _ = fc.FcConfigSubstitute(null, pattern, .pattern);
    fc.FcDefaultSubstitute(pattern);
    var result: fc.FcResult = undefined;
    const match = fc.FcFontMatch(null, pattern, &result) orelse return null;
    defer fc.FcPatternDestroy(match);
    var file_ptr: [*c]fc.FcChar8 = undefined;
    if (fc.FcPatternGetString(match, fc.FC_FILE, 0, &file_ptr) != .match) return null;
    return alloc.dupe(u8, std.mem.span(@as([*:0]const u8, @ptrCast(file_ptr)))) catch null;
}
