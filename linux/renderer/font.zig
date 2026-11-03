//! Font loading (fontconfig → hbft) and the rasterize/shape/ascii-table
//! work behind the core's atlas callbacks. Touched only on the core thread.

const std = @import("std");
const core = @import("zonvie_core");
const clock = core.clock;
const hbft = @import("../hbft.zig");
const fc = @import("../fc.zig");
const applog = @import("../app_log.zig");
const atlas_pixels = @import("../atlas_pixels.zig");

const Font = hbft.zonvie_ft_hb_font;

/// A face loaded for scalars the primary family lacks, by font file.
const Fallback = struct {
    path_hash: u64,
    index: c_int,
    font: *Font,
};

const max_fallbacks = 16;
/// Scalars no installed face covers, remembered so a run of them does not
/// query fontconfig for every cell.
const miss_cap = 64;

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
    /// The loaded family and size, which fallback faces are matched against.
    family: [128]u8 = undefined,
    family_len: usize = 0,
    pixel_size: u32 = 0,
    fallbacks: [max_fallbacks]Fallback = undefined,
    fallback_len: usize = 0,
    /// The colour emoji face, loaded on first use; `emoji_tried` stops a
    /// system without one from searching again.
    emoji: ?*Font = null,
    emoji_tried: bool = false,
    misses: [miss_cap]u32 = undefined,
    miss_len: usize = 0,
    miss_next: usize = 0,
    /// A fixed-strike glyph scaled to the font's size; the bitmap handed to
    /// the core points here until the next rasterize.
    scaled: std.ArrayListUnmanaged(u8) = .empty,

    pub fn deinit(self: *Fonts, alloc: std.mem.Allocator) void {
        self.destroyFaces();
        self.y_advance_scratch.deinit(alloc);
        self.scaled.deinit(alloc);
    }

    fn destroyFaces(self: *Fonts) void {
        inline for (.{ "regular", "bold", "italic", "bold_italic" }) |f| {
            if (@field(self, f)) |h| hbft.zonvie_ft_hb_font_destroy(h);
            @field(self, f) = null;
        }
        for (self.fallbacks[0..self.fallback_len]) |fb| hbft.zonvie_ft_hb_font_destroy(fb.font);
        self.fallback_len = 0;
        if (self.emoji) |e| hbft.zonvie_ft_hb_font_destroy(e);
        self.emoji = null;
        self.emoji_tried = false;
        self.miss_len = 0;
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
        const n = @min(family.len, self.family.len);
        @memcpy(self.family[0..n], family[0..n]);
        self.family_len = n;
        self.pixel_size = pixel_size;
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

    /// One scalar, or with `cluster` the emoji cluster the core composed
    /// (zonvie_core_get_emoji_cluster). The core asks here for every scalar
    /// the primary face shaped to .notdef, so this is where faces other than
    /// the primary one come in: the colour emoji face for emoji, else the
    /// first installed face fontconfig finds covering the scalar.
    pub fn rasterizeScalar(self: *Fonts, alloc: std.mem.Allocator, scalar: u32, style_flags: u32, cluster: []const u32, out: *core.GlyphBitmap) bool {
        const font = self.forStyle(style_flags) orelse return false;
        if (cluster.len != 0 or core.flush_mod.isEmojiPresentation(scalar)) {
            if (self.emojiFace(alloc)) |e| {
                const scalars: []const u32 = if (cluster.len != 0) cluster else (&scalar)[0..1];
                const gid = firstGlyph(e, scalars);
                if (gid != 0) return self.render(alloc, e, gid, out);
            }
        }
        const gid = firstGlyph(font, (&scalar)[0..1]);
        if (gid != 0) return self.render(alloc, font, gid, out);
        if (self.fallbackFace(alloc, scalar)) |fb| {
            const fgid = firstGlyph(fb, (&scalar)[0..1]);
            if (fgid != 0) return self.render(alloc, fb, fgid, out);
        }
        // No face has it: the primary's .notdef box.
        return self.render(alloc, font, 0, out);
    }

    pub fn rasterizeGlyphId(self: *Fonts, alloc: std.mem.Allocator, glyph_id: u32, style_flags: u32, out: *core.GlyphBitmap) bool {
        const font = self.forStyle(style_flags) orelse return false;
        return self.render(alloc, font, glyph_id, out);
    }

    fn emojiFace(self: *Fonts, alloc: std.mem.Allocator) ?*Font {
        if (self.emoji != null or self.emoji_tried) return self.emoji;
        self.emoji_tried = true;
        const m = matchFile(alloc, "emoji", null, true) orelse return null;
        defer alloc.free(m.path);
        self.emoji = loadFile(alloc, m.path, m.index, self.pixel_size);
        return self.emoji;
    }

    fn fallbackFace(self: *Fonts, alloc: std.mem.Allocator, scalar: u32) ?*Font {
        for (self.misses[0..self.miss_len]) |m| if (m == scalar) return null;
        const m = matchFile(alloc, self.family[0..self.family_len], scalar, false) orelse {
            self.misses[self.miss_next] = scalar;
            self.miss_next = (self.miss_next + 1) % miss_cap;
            self.miss_len = @min(self.miss_len + 1, miss_cap);
            return null;
        };
        defer alloc.free(m.path);
        const hash = std.hash.Wyhash.hash(0, m.path);
        for (self.fallbacks[0..self.fallback_len]) |fb| {
            if (fb.path_hash == hash and fb.index == m.index) return fb.font;
        }
        const font = loadFile(alloc, m.path, m.index, self.pixel_size) orelse return null;
        // A full cache drops its oldest face; the core keeps the glyphs it
        // already rasterized, so only a later new scalar reloads it.
        if (self.fallback_len == max_fallbacks) {
            hbft.zonvie_ft_hb_font_destroy(self.fallbacks[0].font);
            std.mem.copyForwards(Fallback, self.fallbacks[0 .. max_fallbacks - 1], self.fallbacks[1..]);
            self.fallback_len -= 1;
        }
        self.fallbacks[self.fallback_len] = .{ .path_hash = hash, .index = m.index, .font = font };
        self.fallback_len += 1;
        applog.appLog("[font] fallback for U+{X:0>4}: {s}\n", .{ scalar, m.path });
        return font;
    }

    fn render(self: *Fonts, alloc: std.mem.Allocator, font: *Font, glyph_id: u32, out: *core.GlyphBitmap) bool {
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
        const strike = hbft.zonvie_ft_hb_font_strike_px(font);
        if (strike != 0 and strike > self.pixel_size and bpp == 4 and w > 0 and h > 0) self.scaleStrike(alloc, out, strike);
        return true;
    }

    /// A fixed-strike glyph (a CBDT colour emoji) comes out at the strike's
    /// size; scale it, and its metrics, to the font's pixel size.
    fn scaleStrike(self: *Fonts, alloc: std.mem.Allocator, out: *core.GlyphBitmap, strike_px: u32) void {
        const s = @as(f32, @floatFromInt(self.pixel_size)) / @as(f32, @floatFromInt(strike_px));
        const dw: usize = @max(1, @as(usize, @intFromFloat(@round(@as(f32, @floatFromInt(out.width)) * s))));
        const dh: usize = @max(1, @as(usize, @intFromFloat(@round(@as(f32, @floatFromInt(out.height)) * s))));
        self.scaled.resize(alloc, dw * dh * 4) catch return;
        const src = out.pixels orelse return;
        if (out.pitch < 0) return;
        const pitch: usize = @intCast(out.pitch);
        atlas_pixels.downscale4(src[0 .. pitch * out.height], out.width, out.height, pitch, self.scaled.items, dw, dh);
        out.pixels = self.scaled.items.ptr;
        out.width = @intCast(dw);
        out.height = @intCast(dh);
        out.pitch = @intCast(dw * 4);
        out.bearing_x = @intFromFloat(@round(@as(f32, @floatFromInt(out.bearing_x)) * s));
        out.bearing_y = @intFromFloat(@round(@as(f32, @floatFromInt(out.bearing_y)) * s));
        out.advance_26_6 = @intFromFloat(@round(@as(f32, @floatFromInt(out.advance_26_6)) * s));
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

/// The first glyph `scalars` shape to in `font`; 0 (.notdef) when it lacks them.
fn firstGlyph(font: *Font, scalars: []const u32) u32 {
    var gids: [8]u32 = undefined;
    var clusters: [8]u32 = undefined;
    var x_adv: [8]i32 = undefined;
    var y_adv: [8]i32 = undefined;
    var x_off: [8]i32 = undefined;
    var y_off: [8]i32 = undefined;
    var asc: i32 = 0;
    var desc: i32 = 0;
    var height: i32 = 0;
    const n = hbft.zonvie_hb_shape_utf32(font, scalars.ptr, scalars.len, &gids, &clusters, &x_adv, &y_adv, &x_off, &y_off, gids.len, &asc, &desc, &height);
    if (n == 0 or n > gids.len) return 0;
    return gids[0];
}

fn loadFace(alloc: std.mem.Allocator, family: []const u8, bold: bool, italic: bool, pixel_size: u32) ?*Font {
    const path = findFontFile(alloc, family, bold, italic) orelse return null;
    defer alloc.free(path);
    return loadFile(alloc, path, 0, pixel_size);
}

/// zonvie_ft_hb_font_create copies the bytes (HBFTBridge.c:150-152), so they
/// are freed right after.
fn loadFile(alloc: std.mem.Allocator, path: []const u8, index: c_int, pixel_size: u32) ?*Font {
    const bytes = std.Io.Dir.cwd().readFileAlloc(clock.io(), path, alloc, .unlimited) catch return null;
    defer alloc.free(bytes);
    const f = hbft.zonvie_ft_hb_font_create(bytes.ptr, bytes.len, pixel_size, @intCast(@max(0, index)));
    if (f == null) applog.appLog("[font] failed to load {s}\n", .{path});
    return f;
}

const Match = struct { path: []u8, index: c_int };

/// The font file fontconfig picks for `family` that covers `scalar` (when
/// given) and is a colour face (when `color`). Null when even its best match
/// lacks the scalar, which is fontconfig saying nothing installed has it.
fn matchFile(alloc: std.mem.Allocator, family: []const u8, scalar: ?u32, color: bool) ?Match {
    const family_z = alloc.dupeZ(u8, family) catch return null;
    defer alloc.free(family_z);
    const pattern = fc.FcPatternCreate() orelse return null;
    defer fc.FcPatternDestroy(pattern);
    _ = fc.FcPatternAddString(pattern, fc.FC_FAMILY, family_z.ptr);
    if (color) _ = fc.FcPatternAddBool(pattern, fc.FC_COLOR, 1);
    if (scalar) |sc| {
        const cs = fc.FcCharSetCreate() orelse return null;
        defer fc.FcCharSetDestroy(cs);
        _ = fc.FcCharSetAddChar(cs, sc);
        _ = fc.FcPatternAddCharSet(pattern, fc.FC_CHARSET, cs);
    }
    _ = fc.FcConfigSubstitute(null, pattern, .pattern);
    fc.FcDefaultSubstitute(pattern);
    var result: fc.FcResult = undefined;
    const match = fc.FcFontMatch(null, pattern, &result) orelse return null;
    defer fc.FcPatternDestroy(match);
    if (scalar) |sc| {
        var cs: ?*fc.FcCharSet = null;
        if (fc.FcPatternGetCharSet(match, fc.FC_CHARSET, 0, &cs) != .match) return null;
        if (fc.FcCharSetHasChar(cs.?, sc) == 0) return null;
    }
    var file_ptr: [*c]fc.FcChar8 = undefined;
    if (fc.FcPatternGetString(match, fc.FC_FILE, 0, &file_ptr) != .match) return null;
    var index: c_int = 0;
    _ = fc.FcPatternGetInteger(match, fc.FC_INDEX, 0, &index);
    const path = alloc.dupe(u8, std.mem.span(@as([*:0]const u8, @ptrCast(file_ptr)))) catch return null;
    return .{ .path = path, .index = index };
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
    // A font lists every family name it answers to (localized, aliases).
    var accepted = false;
    var i: c_int = 0;
    var family_ptr: [*c]fc.FcChar8 = undefined;
    while (fc.FcPatternGetString(match, fc.FC_FAMILY, i, &family_ptr) == .match) : (i += 1) {
        if (fc.familyAccepted(family, std.mem.span(@as([*:0]const u8, @ptrCast(family_ptr))))) {
            accepted = true;
            break;
        }
    }
    if (!accepted) return null;
    var file_ptr: [*c]fc.FcChar8 = undefined;
    if (fc.FcPatternGetString(match, fc.FC_FILE, 0, &file_ptr) != .match) return null;
    return alloc.dupe(u8, std.mem.span(@as([*:0]const u8, @ptrCast(file_ptr)))) catch null;
}
