const std = @import("std");

pub const Attr = struct {
    fg: ?u32 = null,
    bg: ?u32 = null,
    sp: ?u32 = null, // "special" color (underline/undercurl/etc)
    reverse: bool = false,
    blend: u8 = 0,

    italic: bool = false,
    bold: bool = false,
    strikethrough: bool = false,
    underline: bool = false,
    undercurl: bool = false,
    underdouble: bool = false,
    underdotted: bool = false,
    underdashed: bool = false,
    overline: bool = false,
    has_url: bool = false,
};

pub const Styles = struct {
    italic: bool = false,
    bold: bool = false,
    strikethrough: bool = false,
    underline: bool = false,
    undercurl: bool = false,
    underdouble: bool = false,
    underdotted: bool = false,
    underdashed: bool = false,
    overline: bool = false,
};

pub const ResolvedAttr = struct {
    fg: u32,
    bg: u32,
};

pub const ResolvedAttrWithStyles = struct {
    fg: u32,
    bg: u32,
    sp: u32,
    bold: bool,
    italic: bool,
    strikethrough: bool,
    underline: bool,
    undercurl: bool,
    underdouble: bool,
    underdotted: bool,
    underdashed: bool,
    overline: bool,
    style_flags: u8, // Pre-packed style flags for fast access
};

/// Style bit positions for the packed `style_flags` byte.
///
/// This is the wire encoding: getWithStyles packs it, flush.zig re-exports
/// these names, and the frontends decode the same bits. Definitions live here
/// because highlight.zig is the only module both the packer and flush.zig can
/// import -- flush imports highlight, not the other way round.
///
/// Overline is deliberately absent. There are nine style booleans and eight
/// bits; overline travels as its own byte in the SoA row buffer.
pub const STYLE_BOLD: u8 = 1 << 0;
pub const STYLE_ITALIC: u8 = 1 << 1;
pub const STYLE_STRIKETHROUGH: u8 = 1 << 2;
pub const STYLE_UNDERLINE: u8 = 1 << 3;
pub const STYLE_UNDERCURL: u8 = 1 << 4;
pub const STYLE_UNDERDOUBLE: u8 = 1 << 5;
pub const STYLE_UNDERDOTTED: u8 = 1 << 6;
pub const STYLE_UNDERDASHED: u8 = 1 << 7;

fn blendRgb(base: u32, top: u32, transparency: u8) u32 {
    // transparency: 0 => opaque(top), 100 => fully transparent(use base)
    const t: u32 = @as(u32, transparency);
    const inv: u32 = 100 - t;

    const br: u32 = (base >> 16) & 0xFF;
    const bg: u32 = (base >> 8) & 0xFF;
    const bb: u32 = base & 0xFF;

    const tr: u32 = (top >> 16) & 0xFF;
    const tg: u32 = (top >> 8) & 0xFF;
    const tb: u32 = top & 0xFF;

    const r: u32 = (br * t + tr * inv + 50) / 100;
    const g: u32 = (bg * t + tg * inv + 50) / 100;
    const b: u32 = (bb * t + tb * inv + 50) / 100;

    return (r << 16) | (g << 8) | b;
}

pub const Highlights = struct {
    alloc: std.mem.Allocator,
    map: std.AutoHashMap(u32, Attr),

    // Changes only when the bold/italic rasterization inputs for an hl_id
    // change. Atlas-capacity recovery uses this to distinguish a genuinely
    // new glyph working set from color-only highlight updates.
    glyph_style_rev: u64 = 0,

    // For "hl_group_set"
    groups: std.StringHashMap(u32),

    default_fg: u32 = 0x00FFFFFF,
    default_bg: u32 = 0x00000000,
    default_sp: u32 = 0x00000000,

    // Flags set by setGroup/setDefaults, consumed by rpc_session post-handleRedraw
    groups_changed: bool = false,
    default_colors_changed: bool = false,

    pub fn init(alloc: std.mem.Allocator) Highlights {
        return .{
            .alloc = alloc,
            .map = std.AutoHashMap(u32, Attr).init(alloc),
            .groups = std.StringHashMap(u32).init(alloc),
        };
    }

    pub fn deinit(self: *Highlights) void {
        // Free duplicated group-name keys.
        var it = self.groups.iterator();
        while (it.next()) |e| {
            self.alloc.free(@constCast(e.key_ptr.*));
        }
        self.groups.deinit();

        self.map.deinit();
    }

    /// Drop all state owned by one Neovim UI attachment while retaining map
    /// capacity. The next ui_attach sends the complete highlight table again.
    pub fn reset(self: *Highlights) void {
        var it = self.groups.iterator();
        while (it.next()) |e| {
            self.alloc.free(@constCast(e.key_ptr.*));
        }
        self.groups.clearRetainingCapacity();
        self.map.clearRetainingCapacity();
        self.glyph_style_rev +%= 1;
        self.default_fg = 0x00FFFFFF;
        self.default_bg = 0x00000000;
        self.default_sp = 0x00000000;
        self.groups_changed = false;
        self.default_colors_changed = false;
    }

    pub fn setDefaults(self: *Highlights, fg: ?u32, bg: ?u32, sp: ?u32) void {
        if (fg) |v| self.default_fg = v;
        if (bg) |v| self.default_bg = v;
        if (sp) |v| self.default_sp = v;
        self.default_colors_changed = true;
    }

    pub fn setGroup(self: *Highlights, name: []const u8, hl_id: u32) !void {
        if (self.groups.getEntry(name)) |e| {
            e.value_ptr.* = hl_id;
            self.groups_changed = true;
            return;
        }
        const k = try self.alloc.dupe(u8, name);
        errdefer self.alloc.free(k);
        try self.groups.put(k, hl_id);
        self.groups_changed = true;
    }

    pub fn define(
        self: *Highlights,
        id: u32,
        fg: ?u32,
        bg: ?u32,
        sp: ?u32,
        reverse: bool,
        blend: u8,
        styles: Styles,
        has_url: bool,
    ) !void {
        const a: Attr = .{
            .fg = fg,
            .bg = bg,
            .sp = sp,
            .reverse = reverse,
            .blend = blend,

            .italic = styles.italic,
            .bold = styles.bold,
            .strikethrough = styles.strikethrough,
            .underline = styles.underline,
            .undercurl = styles.undercurl,
            .underdouble = styles.underdouble,
            .underdotted = styles.underdotted,
            .underdashed = styles.underdashed,
            .overline = styles.overline,
            .has_url = has_url,
        };
        const old = self.map.get(id);
        try self.map.put(id, a);
        if (old == null or old.?.bold != a.bold or old.?.italic != a.italic) {
            self.glyph_style_rev +%= 1;
        }
    }

    /// Resolve a raw attribute's foreground and background.
    ///
    /// Shared by get() and getWithStyles(), which carried byte-identical
    /// copies of this. The order matters and is pinned by a test: blend mixes
    /// the background toward the default first, and only then does reverse
    /// swap the pair. Reversing first would blend the foreground instead.
    ///
    /// Blend applies only when bg was set explicitly -- blending the default
    /// against itself is a no-op that would still cost the arithmetic.
    ///
    /// `inline` because getWithStyles is per-cell on the hl-cache overflow
    /// path; the body is branch-and-shift with no allocation.
    inline fn resolveFgBg(self: *const Highlights, raw: Attr) ResolvedAttr {
        var fg: u32 = raw.fg orelse self.default_fg;
        var bg: u32 = raw.bg orelse self.default_bg;

        if (raw.blend != 0 and raw.bg != null) {
            bg = blendRgb(self.default_bg, bg, raw.blend);
        }

        if (raw.reverse) {
            const tmp = fg;
            fg = bg;
            bg = tmp;
        }

        return .{ .fg = fg, .bg = bg };
    }

    // NOTE: get() remains unchanged (returns fg/bg only) because the current
    // binary frame format only transports fg/bg. This keeps unrelated parts intact.
    pub fn get(self: *const Highlights, id: u32) ResolvedAttr {
        return self.resolveFgBg(self.map.get(id) orelse Attr{});
    }

    // Sentinel value indicating "special color not set" (0xFFFFFFFF is outside valid RGB range 0x000000-0xFFFFFF)
    pub const SP_NOT_SET: u32 = 0xFFFFFFFF;

    pub fn getWithStyles(self: *const Highlights, id: u32) ResolvedAttrWithStyles {
        const raw = self.map.get(id) orelse Attr{};
        const base = self.resolveFgBg(raw);
        const fg = base.fg;
        const bg = base.bg;
        // Use SP_NOT_SET sentinel for "not set" - decoration code will fall back to fg
        // This correctly handles the case where special is explicitly set to black (0x000000)
        const sp: u32 = raw.sp orelse SP_NOT_SET;

        // Pre-compute style_flags. The constants are declared above; the
        // comment here used to point at nvim_core.zig, which only aliases two
        // of them.
        var style_flags: u8 = 0;
        if (raw.bold) style_flags |= STYLE_BOLD;
        if (raw.italic) style_flags |= STYLE_ITALIC;
        if (raw.strikethrough) style_flags |= STYLE_STRIKETHROUGH;
        if (raw.underline) style_flags |= STYLE_UNDERLINE;
        if (raw.undercurl) style_flags |= STYLE_UNDERCURL;
        if (raw.underdouble) style_flags |= STYLE_UNDERDOUBLE;
        if (raw.underdotted) style_flags |= STYLE_UNDERDOTTED;
        if (raw.underdashed) style_flags |= STYLE_UNDERDASHED;

        return .{
            .fg = fg,
            .bg = bg,
            .sp = sp,
            .bold = raw.bold,
            .italic = raw.italic,
            .strikethrough = raw.strikethrough,
            .underline = raw.underline,
            .undercurl = raw.undercurl,
            .underdouble = raw.underdouble,
            .underdotted = raw.underdotted,
            .underdashed = raw.underdashed,
            .overline = raw.overline,
            .style_flags = style_flags,
        };
    }
};

test "colour resolution blends before it reverses, and both paths agree" {
    // highlight.zig had no tests at all, and get() and getWithStyles()
    // carried byte-identical copies of this arithmetic. Pin the order and the
    // agreement before either is shared, because nothing else would catch a
    // blend applied after the swap or a divergence between the two.
    var hl = Highlights.init(std.testing.allocator);
    defer hl.deinit();
    hl.setDefaults(0x111111, 0x222222, null);

    // blend=50 mixes bg toward default_bg; reverse then swaps the result into
    // fg. Applying reverse first would blend the FOREGROUND instead, so the
    // two orders give different answers and this pins which one runs.
    try hl.define(1, 0xFF0000, 0x00FF00, null, true, 50, .{}, false);
    const blended_bg = blendRgb(0x222222, 0x00FF00, 50);

    const a = hl.get(1);
    try std.testing.expectEqual(blended_bg, a.fg);
    try std.testing.expectEqual(@as(u32, 0xFF0000), a.bg);

    // getWithStyles must resolve fg/bg identically -- that agreement is the
    // whole reason the two bodies can share one implementation.
    const b = hl.getWithStyles(1);
    try std.testing.expectEqual(a.fg, b.fg);
    try std.testing.expectEqual(a.bg, b.bg);

    // blend applies only when bg was explicitly set: a null bg keeps the
    // default untouched even with a non-zero blend.
    //
    // Note this assertion cannot distinguish the guard being present from it
    // being absent, because blending the default against itself is the
    // identity for any transparency. It pins the resulting value, not the
    // guard. The guard's own effect is pinned by the explicit-bg case above,
    // where blending moves the value away from what a missing blend would
    // leave.
    try hl.define(2, 0xFF0000, null, null, false, 50, .{}, false);
    try std.testing.expectEqual(@as(u32, 0x222222), hl.get(2).bg);
    try std.testing.expectEqual(hl.get(2).bg, hl.getWithStyles(2).bg);

    // An unknown id resolves to the defaults through both entry points.
    try std.testing.expectEqual(@as(u32, 0x111111), hl.get(999).fg);
    try std.testing.expectEqual(@as(u32, 0x222222), hl.get(999).bg);
    try std.testing.expectEqual(@as(u32, 0x111111), hl.getWithStyles(999).fg);
}

test "the packed style byte keeps its wire values" {
    // These bits cross the C ABI and are decoded by both frontends, one of
    // which (dwrite_d2d_renderer.zig) keeps its own hand-written copy of the
    // low two, held in sync by a comment. Pin the numbering as literals so
    // moving the definitions cannot renumber them silently.
    try std.testing.expectEqual(@as(u8, 0x01), STYLE_BOLD);
    try std.testing.expectEqual(@as(u8, 0x02), STYLE_ITALIC);
    try std.testing.expectEqual(@as(u8, 0x04), STYLE_STRIKETHROUGH);
    try std.testing.expectEqual(@as(u8, 0x08), STYLE_UNDERLINE);
    try std.testing.expectEqual(@as(u8, 0x10), STYLE_UNDERCURL);
    try std.testing.expectEqual(@as(u8, 0x20), STYLE_UNDERDOUBLE);
    try std.testing.expectEqual(@as(u8, 0x40), STYLE_UNDERDOTTED);
    try std.testing.expectEqual(@as(u8, 0x80), STYLE_UNDERDASHED);

    // And that getWithStyles actually packs them, rather than the constants
    // merely existing with the right values.
    var hl = Highlights.init(std.testing.allocator);
    defer hl.deinit();
    try hl.define(1, null, null, null, false, 0, .{
        .bold = true,
        .strikethrough = true,
        .underdashed = true,
        .overline = true,
    }, false);
    const a = hl.getWithStyles(1);
    try std.testing.expectEqual(
        @as(u8, STYLE_BOLD | STYLE_STRIKETHROUGH | STYLE_UNDERDASHED),
        a.style_flags,
    );
    // Overline has no bit -- nine booleans, eight bits -- and travels
    // separately. Its presence must not have set one.
    try std.testing.expect(a.overline);
}
