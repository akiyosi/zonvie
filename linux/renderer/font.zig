//! Font loading (fontconfig → hbft) and the rasterize/shape/ascii-table
//! work behind the core's atlas callbacks. Touched only with the core's grid lock held (callbacks.zig).

const std = @import("std");
const core = @import("zonvie_core");
const hbft = @import("../hbft.zig");
const fc = @import("../fc.zig");
const applog = @import("../app_log.zig");
const atlas_pixels = @import("../atlas_pixels.zig");

const font_spec = @import("../font_spec.zig");

const Font = hbft.zonvie_ft_hb_font;

/// The style a family's regular face is loaded in: a Bold or Italic face
/// picked in the font dialog stays bold or italic (windows picked_font_*).
pub const BaseStyle = struct { bold: bool = false, italic: bool = false };

/// A face loaded for scalars the primary family lacks, by font file.
const Fallback = struct {
    path_hash: u64,
    index: c_int,
    font: *Font,
};

/// The fallback for one scalar: fontconfig's best match for the family among
/// the fonts that cover the scalar, without scoring every installed font for
/// every scalar. The covering fonts are passed in the order FcFontMatch walks
/// them (system, then application), so a tie resolves as it does there.
///
/// This is FcFontMatch's pick for {family, charset = scalar} whenever that
/// pick covers the scalar. Where it does not (the substituted family asks
/// for something fontconfig ranks above charset, such as color), the best
/// covering font is returned instead of nothing. A font without a charset
/// cannot be known to cover a scalar and is never a candidate. A config rule
/// that tests the pattern's charset does not apply: the family is
/// substituted once, without one.
const FallbackIndex = struct {
    /// Held so its font sets, which `fonts` points into, stay alive.
    config: *fc.FcConfig,
    /// The family, substituted once as matchFile substitutes it per scalar.
    pattern: *fc.FcPattern,
    /// Every font with a charset, in walk order: `fonts[0..fonts_len]`.
    fonts: []Candidate,
    fonts_len: usize,
    /// The covering subset of `fonts` for one lookup; same capacity.
    covering: []*fc.FcPattern,

    const Candidate = struct { pattern: *fc.FcPattern, charset: *const fc.FcCharSet };

    fn build(alloc: std.mem.Allocator, family: []const u8) !FallbackIndex {
        const config = fc.FcConfigReference(null) orelse return error.NoConfig;
        errdefer fc.FcConfigDestroy(config);
        const family_z = try alloc.dupeZ(u8, family);
        defer alloc.free(family_z);
        const pattern = fc.FcPatternCreate() orelse return error.OutOfMemory;
        errdefer fc.FcPatternDestroy(pattern);
        _ = fc.FcPatternAddString(pattern, fc.FC_FAMILY, family_z.ptr);
        _ = fc.FcConfigSubstitute(config, pattern, .pattern);
        fc.FcDefaultSubstitute(pattern);
        var n: usize = 0;
        for ([_]fc.FcSetName{ .system, .application }) |name| {
            if (fc.FcConfigGetFonts(config, name)) |s| n += @intCast(s.nfont);
        }
        const fonts = try alloc.alloc(Candidate, n);
        errdefer alloc.free(fonts);
        const covering = try alloc.alloc(*fc.FcPattern, n);
        var len: usize = 0;
        for ([_]fc.FcSetName{ .system, .application }) |name| {
            const s = fc.FcConfigGetFonts(config, name) orelse continue;
            const list = s.fonts orelse continue;
            for (list[0..@intCast(s.nfont)]) |p| {
                var cs: ?*fc.FcCharSet = null;
                if (fc.FcPatternGetCharSet(p, fc.FC_CHARSET, 0, &cs) != .match) continue;
                fonts[len] = .{ .pattern = p, .charset = cs.? };
                len += 1;
            }
        }
        return .{ .config = config, .pattern = pattern, .fonts = fonts, .fonts_len = len, .covering = covering };
    }

    fn deinit(self: *FallbackIndex, alloc: std.mem.Allocator) void {
        alloc.free(self.fonts);
        alloc.free(self.covering);
        fc.FcPatternDestroy(self.pattern);
        fc.FcConfigDestroy(self.config);
    }

    fn match(self: *FallbackIndex, alloc: std.mem.Allocator, scalar: u32) ?Match {
        var n: usize = 0;
        for (self.fonts[0..self.fonts_len]) |f| {
            if (fc.FcCharSetHasChar(f.charset, scalar) == 0) continue;
            self.covering[n] = f.pattern;
            n += 1;
        }
        if (n == 0) return null;
        var set: fc.FcFontSet = .{ .nfont = @intCast(n), .sfont = @intCast(n), .fonts = self.covering.ptr };
        const sets = [_]*fc.FcFontSet{&set};
        var result: fc.FcResult = undefined;
        const m = fc.FcFontSetMatch(self.config, &sets, 1, self.pattern, &result) orelse return null;
        defer fc.FcPatternDestroy(m);
        var file_ptr: [*c]fc.FcChar8 = undefined;
        if (fc.FcPatternGetString(m, fc.FC_FILE, 0, &file_ptr) != .match) return null;
        var index: c_int = 0;
        _ = fc.FcPatternGetInteger(m, fc.FC_INDEX, 0, &index);
        const path = alloc.dupe(u8, std.mem.span(@as([*:0]const u8, @ptrCast(file_ptr)))) catch return null;
        return .{ .path = path, .index = index };
    }
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
    /// The feature field and base style the faces were loaded with, so they
    /// can be loaded again at another pixel size (a scale change) and a
    /// per-grid font naming no family can take them.
    features: [256]u8 = undefined,
    features_len: usize = 0,
    base: BaseStyle = .{},
    fallbacks: [max_fallbacks]Fallback = undefined,
    fallback_len: usize = 0,
    /// Built at the first fallback lookup for the loaded family;
    /// `fallback_index_tried` stops a failed build from being retried.
    fallback_index: ?FallbackIndex = null,
    fallback_index_tried: bool = false,
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
        self.destroyFaces(alloc);
        self.y_advance_scratch.deinit(alloc);
        self.scaled.deinit(alloc);
    }

    fn destroyFaces(self: *Fonts, alloc: std.mem.Allocator) void {
        if (self.fallback_index) |*fi| fi.deinit(alloc);
        self.fallback_index = null;
        self.fallback_index_tried = false;
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
    /// candidate keeps the current font. `features` is a guifont candidate's
    /// feature field ("+ss01,-liga,wght=500"), applied to every style, as
    /// macOS applies it: each entry is an OpenType feature for shaping and,
    /// where the font has that axis, a variation coordinate.
    /// `base` is the style the regular face is (a Bold or Italic pick from
    /// the font dialog); the styled faces add to it. Pre: `family` and
    /// `features` do not alias this Fonts' own buffers.
    pub fn load(self: *Fonts, alloc: std.mem.Allocator, family: []const u8, pixel_size: u32, features: []const u8, base: BaseStyle) bool {
        if (pixel_size == 0) return false;
        var list: [32]hbft.zonvie_font_feature = undefined;
        const n_features = core.zonvie_core_parse_font_features(features.ptr, features.len, @ptrCast(&list), list.len);
        const user = list[0..n_features];
        const regular = loadFace(alloc, family, base.bold, base.italic, pixel_size, user) orelse return false;
        self.destroyFaces(alloc);
        self.regular = regular;
        self.bold = loadFace(alloc, family, true, base.italic, pixel_size, user);
        self.italic = loadFace(alloc, family, base.bold, true, pixel_size, user);
        self.bold_italic = loadFace(alloc, family, true, true, pixel_size, user);
        const n = @min(family.len, self.family.len);
        @memcpy(self.family[0..n], family[0..n]);
        self.family_len = n;
        const nf = @min(features.len, self.features.len);
        @memcpy(self.features[0..nf], features[0..nf]);
        self.features_len = nf;
        self.base = base;
        self.pixel_size = pixel_size;
        self.computeCellMetrics();
        return true;
    }

    /// The same family, features and style at `pixel_size`. False keeps the
    /// current faces.
    pub fn reload(self: *Fonts, alloc: std.mem.Allocator, pixel_size: u32) bool {
        if (self.regular == null) return false;
        var family: [128]u8 = undefined;
        var features: [256]u8 = undefined;
        const fl = self.family_len;
        const nf = self.features_len;
        @memcpy(family[0..fl], self.family[0..fl]);
        @memcpy(features[0..nf], self.features[0..nf]);
        return self.load(alloc, family[0..fl], pixel_size, features[0..nf], self.base);
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
        const family = self.family[0..self.family_len];
        if (!self.fallback_index_tried) {
            self.fallback_index_tried = true;
            self.fallback_index = FallbackIndex.build(alloc, family) catch null;
        }
        const found = if (self.fallback_index) |*fi| fi.match(alloc, scalar) else matchFile(alloc, family, scalar, false);
        const m = found orelse {
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

/// The face fontconfig picks for `family` in a style, opened as the face
/// (and, for a variable font, the named instance) it matched, with the
/// user's `[font]` features and axes, and with the style simulated when the
/// family has no such face.
fn loadFace(alloc: std.mem.Allocator, family: []const u8, bold: bool, italic: bool, pixel_size: u32, user: []const hbft.zonvie_font_feature) ?*Font {
    const m = findFontFile(alloc, family, bold, italic) orelse return null;
    defer alloc.free(m.path);
    const f = loadFile(alloc, m.path, m.index, pixel_size) orelse return null;
    if (user.len != 0) hbft.zonvie_ft_hb_font_set_features(f, user.ptr, user.len);
    applyAxes(f, m.variations[0..m.variations_len], user);
    const synth = font_spec.synthetic(bold, italic, m.style);
    if (synth.bold or synth.oblique) {
        hbft.zonvie_ft_hb_font_set_synthetic(f, @intFromBool(synth.bold), @intFromBool(synth.oblique));
        applog.appLog("[font] synthetic bold={} oblique={} for {s}\n", .{ synth.bold, synth.oblique, m.path });
    }
    return f;
}

/// A variable face's coordinates: the instance FreeType opened, then
/// fontconfig's variations for the match, then the user's entries, each
/// replacing the axes the one before set (macOS FontInstanceAxes.merged).
/// set_variation_axes starts every axis it is not given from the font's
/// default, so the instance's own coordinates must be passed back in.
fn applyAxes(f: *Font, fc_variations: []const u8, user: []const hbft.zonvie_font_feature) void {
    if (user.len == 0 and fc_variations.len == 0) return;
    var instance: [32]hbft.zonvie_font_axis = undefined;
    const ni = hbft.zonvie_ft_hb_font_get_variation_axes(f, &instance, instance.len);
    if (ni == 0) return; // static: no axis to set
    var fcv_buf: [16]hbft.zonvie_font_axis = undefined;
    const fcv = font_spec.parseVariations(fc_variations, &fcv_buf);
    var user_axes: [32]hbft.zonvie_font_axis = undefined;
    for (user, 0..) |u, i| user_axes[i] = .{ .tag = u.tag, .value = @floatFromInt(u.value) };
    var out: [80]hbft.zonvie_font_axis = undefined;
    const merged = font_spec.mergeAxes(&out, &.{ instance[0..ni], fcv, user_axes[0..user.len] });
    hbft.zonvie_ft_hb_font_set_variation_axes(f, merged.ptr, merged.len);
}

/// Font files by path, mapped read-only and never unmapped: a face borrows
/// its file's bytes for its whole life, the four styles of a family and every
/// reload at another size share one mapping, and a session names few files.
/// Guarded like the rest of this file (the core's grid lock).
var mapped_files: std.StringHashMapUnmanaged([]const u8) = .empty;

fn mapFile(alloc: std.mem.Allocator, path: []const u8) ?[]const u8 {
    if (mapped_files.get(path)) |bytes| return bytes;
    const path_z = alloc.dupeZ(u8, path) catch return null;
    defer alloc.free(path_z);
    const fd = std.c.open(path_z.ptr, .{ .ACCMODE = .RDONLY, .CLOEXEC = true });
    if (fd < 0) return null;
    defer _ = std.c.close(fd);
    const len = std.c.lseek(fd, 0, std.c.SEEK.END);
    if (len <= 0) return null;
    const ptr = std.c.mmap(null, @intCast(len), .{ .READ = true }, .{ .TYPE = .PRIVATE }, fd, 0);
    if (ptr == std.c.MAP_FAILED) return null;
    const bytes = @as([*]const u8, @ptrCast(ptr))[0..@intCast(len)];
    const key = alloc.dupe(u8, path) catch {
        _ = std.c.munmap(@alignCast(ptr), bytes.len);
        return null;
    };
    mapped_files.put(alloc, key, bytes) catch {
        alloc.free(key);
        _ = std.c.munmap(@alignCast(ptr), bytes.len);
        return null;
    };
    return bytes;
}

fn loadFile(alloc: std.mem.Allocator, path: []const u8, index: c_int, pixel_size: u32) ?*Font {
    const bytes = mapFile(alloc, path) orelse return null;
    const f = hbft.zonvie_ft_hb_font_create_borrowed(bytes.ptr, bytes.len, pixel_size, font_spec.ftFaceIndex(index));
    if (f == null) {
        applog.appLog("[font] failed to load {s}\n", .{path});
        return null;
    }
    // ClearType-like 3x1 coverage, as Windows rasterizes; atlas_pixels
    // collapses it to one coverage value as Windows' shader does.
    hbft.zonvie_ft_hb_font_set_lcd(f.?, 1);
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

/// What fontconfig matched for a styled request. `index` carries the named
/// instance in its high 16 bits, which FreeType opens directly.
const StyledMatch = struct {
    path: []u8,
    index: c_int,
    style: font_spec.MatchStyle,
    variations: [128]u8,
    variations_len: usize,
};

fn findFontFile(alloc: std.mem.Allocator, family: []const u8, bold: bool, italic: bool) ?StyledMatch {
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
    var m: StyledMatch = .{ .path = undefined, .index = 0, .style = .{}, .variations = undefined, .variations_len = 0 };
    _ = fc.FcPatternGetInteger(match, fc.FC_INDEX, 0, &m.index);
    // A variable font's range is no single weight: left null (not missing).
    var v: c_int = 0;
    if (fc.FcPatternGetInteger(match, fc.FC_WEIGHT, 0, &v) == .match) m.style.weight = v;
    if (fc.FcPatternGetInteger(match, fc.FC_SLANT, 0, &v) == .match) m.style.slant = v;
    // fontconfig's synthesis rule (90-synthetic.conf) for a missing style.
    var embolden: fc.FcBool = 0;
    if (fc.FcPatternGetBool(match, fc.FC_EMBOLDEN, 0, &embolden) == .match) m.style.fc_embolden = embolden != 0;
    var matrix: ?*const fc.FcMatrix = null;
    if (fc.FcPatternGetMatrix(match, fc.FC_MATRIX, 0, &matrix) == .match) {
        if (matrix) |mx| m.style.fc_oblique = mx.xy != 0;
    }
    var var_ptr: [*c]fc.FcChar8 = undefined;
    if (fc.FcPatternGetString(match, fc.FC_FONT_VARIATIONS, 0, &var_ptr) == .match) {
        const s = std.mem.span(@as([*:0]const u8, @ptrCast(var_ptr)));
        m.variations_len = @min(s.len, m.variations.len);
        @memcpy(m.variations[0..m.variations_len], s[0..m.variations_len]);
    }
    m.path = alloc.dupe(u8, std.mem.span(@as([*:0]const u8, @ptrCast(file_ptr)))) catch return null;
    return m;
}
