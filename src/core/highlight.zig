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
    style_flags: u8, // Pre-packed style flags for fast access
};

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

    // For "hl_group_set"
    groups: std.StringHashMap(u32),

    default_fg: u32 = 0x00FFFFFF,
    default_bg: u32 = 0x00000000,
    default_sp: u32 = 0x00000000,

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

    pub fn setDefaults(self: *Highlights, fg: ?u32, bg: ?u32, sp: ?u32) void {
        if (fg) |v| self.default_fg = v;
        if (bg) |v| self.default_bg = v;
        if (sp) |v| self.default_sp = v;
    }

    pub fn setGroup(self: *Highlights, name: []const u8, hl_id: u32) !void {
        if (self.groups.getEntry(name)) |e| {
            e.value_ptr.* = hl_id;
            return;
        }
        const k = try self.alloc.dupe(u8, name);
        errdefer self.alloc.free(k);
        try self.groups.put(k, hl_id);
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
        };
        try self.map.put(id, a);
    }

    // NOTE: get() remains unchanged (returns fg/bg only) because the current
    // binary frame format only transports fg/bg. This keeps unrelated parts intact.
    pub fn get(self: *const Highlights, id: u32) ResolvedAttr {
        const raw = self.map.get(id) orelse Attr{};

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

    // Sentinel value indicating "special color not set" (0xFFFFFFFF is outside valid RGB range 0x000000-0xFFFFFF)
    pub const SP_NOT_SET: u32 = 0xFFFFFFFF;

    pub fn getWithStyles(self: *const Highlights, id: u32) ResolvedAttrWithStyles {
        const raw = self.map.get(id) orelse Attr{};

        var fg: u32 = raw.fg orelse self.default_fg;
        var bg: u32 = raw.bg orelse self.default_bg;
        // Use SP_NOT_SET sentinel for "not set" - decoration code will fall back to fg
        // This correctly handles the case where special is explicitly set to black (0x000000)
        const sp: u32 = raw.sp orelse SP_NOT_SET;

        if (raw.blend != 0 and raw.bg != null) {
            bg = blendRgb(self.default_bg, bg, raw.blend);
        }

        if (raw.reverse) {
            const tmp = fg;
            fg = bg;
            bg = tmp;
        }

        // Pre-compute style_flags (matching STYLE_* constants in nvim_core.zig)
        var style_flags: u8 = 0;
        if (raw.bold) style_flags |= 0x01;
        if (raw.italic) style_flags |= 0x02;
        if (raw.strikethrough) style_flags |= 0x04;
        if (raw.underline) style_flags |= 0x08;
        if (raw.undercurl) style_flags |= 0x10;
        if (raw.underdouble) style_flags |= 0x20;
        if (raw.underdotted) style_flags |= 0x40;
        if (raw.underdashed) style_flags |= 0x80;

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
            .style_flags = style_flags,
        };
    }
};
