//! The frontend's own drawing over and around the editor: text and
//! rectangles in window px, and the regions of them a pointer can hit. The
//! title bar, the tab strip, the message labels and the IME's composition
//! are built from these (shell.zig); the renderer draws the result after
//! the editor (renderer/gl_renderer.zig drawUi).
//!
//! Text is the editor's own faces, rasterized into an atlas of this layer's:
//! the core owns the other one. A build runs on the main thread with the
//! core's grid lock held, which is what guards the faces; the finished layer
//! is swapped in under App.mu.

const std = @import("std");
const core = @import("zonvie_core");
const App = @import("app.zig").App;
const atlas_pixels = @import("atlas_pixels.zig");

pub const atlas_size = 1024;

pub const Rect = struct { x: i32, y: i32, w: i32, h: i32 };

/// A region the pointer can act on; `id` is the builder's (shell.zig).
pub const Hit = struct { rect: Rect, id: u32, arg: i32 = 0 };

const Glyph = struct {
    x: u16,
    y: u16,
    w: u16,
    h: u16,
    bearing_x: i16,
    bearing_y: i16,
    /// Cells it takes: 2 for a wide character.
    cells: u8,
    color: bool,
};

/// The layer's glyphs. `pixels` is the whole texture, RGBA8; `gen` moves
/// with every glyph added, and the renderer uploads when its copy is older.
pub const Atlas = struct {
    pixels: []u8 = &.{},
    pen_x: u32 = 1,
    pen_y: u32 = 1,
    row_h: u32 = 0,
    glyphs: std.AutoHashMapUnmanaged(u64, Glyph) = .empty,
    /// The faces' pixel size the glyphs were made at; another size starts over.
    pixel_size: u32 = 0,
    gen: u64 = 0,

    pub fn deinit(self: *Atlas, alloc: std.mem.Allocator) void {
        alloc.free(self.pixels);
        self.glyphs.deinit(alloc);
    }

    fn reset(self: *Atlas, pixel_size: u32) void {
        self.glyphs.clearRetainingCapacity();
        @memset(self.pixels, 0);
        self.pen_x = 1;
        self.pen_y = 1;
        self.row_h = 0;
        self.pixel_size = pixel_size;
        self.gen +%= 1;
    }
};

pub const Layer = struct {
    /// Solid quads, then glyph quads: two draws, as the glyphs sample this
    /// layer's atlas.
    solid: std.ArrayListUnmanaged(core.Vertex) = .empty,
    /// Rounded corners, drawn over the solid quads in the shader's corner
    /// mode (Builder.corner).
    round: std.ArrayListUnmanaged(core.Vertex) = .empty,
    text: std.ArrayListUnmanaged(core.Vertex) = .empty,
    hits: std.ArrayListUnmanaged(Hit) = .empty,

    pub fn deinit(self: *Layer, alloc: std.mem.Allocator) void {
        self.solid.deinit(alloc);
        self.round.deinit(alloc);
        self.text.deinit(alloc);
        self.hits.deinit(alloc);
    }

    pub fn clear(self: *Layer) void {
        self.solid.clearRetainingCapacity();
        self.round.clearRetainingCapacity();
        self.text.clearRetainingCapacity();
        self.hits.clearRetainingCapacity();
    }

    /// The topmost hit under (x, y) window px: the last one added.
    pub fn hitAt(self: *const Layer, x: i32, y: i32) ?Hit {
        var i = self.hits.items.len;
        while (i > 0) {
            i -= 1;
            const h = self.hits.items[i];
            if (x >= h.rect.x and x < h.rect.x + h.rect.w and y >= h.rect.y and y < h.rect.y + h.rect.h) return h;
        }
        return null;
    }
};

pub const Style = struct { bold: bool = false, italic: bool = false };

/// Builds one layer. Create with `begin`, which takes the core's grid lock
/// when there is a core, and finish with `end`.
pub const Builder = struct {
    app: *App,
    layer: *Layer,
    locked: bool,
    cell_w: i32,
    cell_h: i32,
    ascent: i32,

    pub fn begin(app: *App, layer: *Layer) Builder {
        layer.clear();
        // Before the core exists (a start that announces its progress)
        // nothing else touches the faces: they are as good as locked.
        if (app.corep) |cp| core.zonvie_core_lock_grid(cp);
        const locked = true;
        const f = &app.fonts;
        if (app.ui_atlas.pixels.len != 0 and app.ui_atlas.pixel_size != f.pixel_size) app.ui_atlas.reset(f.pixel_size);
        return .{
            .app = app,
            .layer = layer,
            .locked = locked,
            .cell_w = @intCast(f.cell_w_px),
            .cell_h = @intCast(f.cell_h_px),
            .ascent = @divTrunc(f.ascent_26_6 + 32, 64),
        };
    }

    pub fn end(self: *Builder) void {
        if (self.locked) if (self.app.corep) |cp| core.zonvie_core_unlock_grid(cp);
        self.locked = false;
    }

    pub fn rect(self: *Builder, r: Rect, color: [4]f32) void {
        if (r.w <= 0 or r.h <= 0) return;
        const x0: f32 = @floatFromInt(r.x);
        const y0: f32 = @floatFromInt(r.y);
        const x1: f32 = @floatFromInt(r.x + r.w);
        const y1: f32 = @floatFromInt(r.y + r.h);
        const corners = [_][2]f32{ .{ x0, y0 }, .{ x1, y0 }, .{ x0, y1 }, .{ x1, y0 }, .{ x1, y1 }, .{ x0, y1 } };
        for (corners) |p| {
            self.layer.solid.append(self.app.alloc, .{ .position = p, .texCoord = .{ -1, -1 }, .color = color, .grid_id = 0, .deco_flags = 0, .deco_phase = 0 }) catch return;
        }
    }

    /// A line `half_w` px to each side of a..b: icons are drawn with these.
    pub fn segment(self: *Builder, a: [2]f32, b: [2]f32, half_w: f32, color: [4]f32) void {
        const dx = b[0] - a[0];
        const dy = b[1] - a[1];
        const len = @sqrt(dx * dx + dy * dy);
        if (len == 0) return;
        const nx = -dy / len * half_w;
        const ny = dx / len * half_w;
        const q = [_][2]f32{ .{ a[0] + nx, a[1] + ny }, .{ b[0] + nx, b[1] + ny }, .{ a[0] - nx, a[1] - ny }, .{ b[0] + nx, b[1] + ny }, .{ b[0] - nx, b[1] - ny }, .{ a[0] - nx, a[1] - ny } };
        for (q) |p| {
            self.layer.solid.append(self.app.alloc, .{ .position = p, .texCoord = .{ -1, -1 }, .color = color, .grid_id = 0, .deco_flags = 0, .deco_phase = 0 }) catch return;
        }
    }

    /// One corner of a rounded box: the arc of `radius` px about `centre`,
    /// in the quadrant `dir` (each -1 or 1) points to. `color` fills what
    /// of the quadrant's square lies outside the arc, or with `stroke_px`
    /// draws a line that wide just inside it. Antialiased.
    pub fn corner(self: *Builder, centre: [2]i32, dir: [2]i32, radius: i32, color: [4]f32, stroke_px: u32) void {
        const r: f32 = @floatFromInt(radius);
        const cx: f32 = @floatFromInt(centre[0]);
        const cy: f32 = @floatFromInt(centre[1]);
        const ox = r * @as(f32, @floatFromInt(dir[0]));
        const oy = r * @as(f32, @floatFromInt(dir[1]));
        // texCoord is the offset from the centre, which the shader measures.
        const offsets = [_][2]f32{ .{ 0, 0 }, .{ ox, 0 }, .{ 0, oy }, .{ ox, 0 }, .{ ox, oy }, .{ 0, oy } };
        for (offsets) |o| {
            self.layer.round.append(self.app.alloc, .{ .position = .{ cx + o[0], cy + o[1] }, .texCoord = o, .color = color, .grid_id = 0, .deco_flags = stroke_px, .deco_phase = r }) catch return;
        }
    }

    pub fn hit(self: *Builder, r: Rect, id: u32, arg: i32) void {
        self.layer.hits.append(self.app.alloc, .{ .rect = r, .id = id, .arg = arg }) catch {};
    }

    /// The width `text` takes, px: a cell per character, two for a wide one.
    pub fn textWidth(self: *Builder, str: []const u8) i32 {
        var cells: i32 = 0;
        var it = (std.unicode.Utf8View.init(str) catch return 0).iterator();
        while (it.nextCodepoint()) |cp| cells += if (self.glyph(cp, .{})) |g| g.cells else 1;
        return cells * self.cell_w;
    }

    /// `text` in one line whose box starts at (x, y) and is a cell high,
    /// cut at `max_w` px. Returns the width drawn.
    pub fn text(self: *Builder, x: i32, y: i32, max_w: i32, str: []const u8, color: [4]f32, style: Style) i32 {
        var pen = x;
        var it = (std.unicode.Utf8View.init(str) catch return 0).iterator();
        while (it.nextCodepoint()) |cp| {
            const g = self.glyph(cp, style) orelse {
                pen += self.cell_w;
                continue;
            };
            const adv = @as(i32, g.cells) * self.cell_w;
            if (pen + adv - x > max_w) break;
            if (g.w != 0 and g.h != 0) {
                const gx: f32 = @floatFromInt(pen + g.bearing_x);
                const gy: f32 = @floatFromInt(y + self.ascent - g.bearing_y);
                const gw: f32 = @floatFromInt(g.w);
                const gh: f32 = @floatFromInt(g.h);
                const k: f32 = 1.0 / @as(f32, atlas_size);
                const u_min = @as(f32, @floatFromInt(g.x)) * k;
                const v_min = @as(f32, @floatFromInt(g.y)) * k;
                const u_max = @as(f32, @floatFromInt(g.x + g.w)) * k;
                const v_max = @as(f32, @floatFromInt(g.y + g.h)) * k;
                const quad = [_][4]f32{
                    .{ gx, gy, u_min, v_min },      .{ gx + gw, gy, u_max, v_min },      .{ gx, gy + gh, u_min, v_max },
                    .{ gx + gw, gy, u_max, v_min }, .{ gx + gw, gy + gh, u_max, v_max }, .{ gx, gy + gh, u_min, v_max },
                };
                for (quad) |p| {
                    self.layer.text.append(self.app.alloc, .{
                        .position = .{ p[0], p[1] },
                        .texCoord = .{ p[2], p[3] },
                        .color = color,
                        .grid_id = 0,
                        .deco_flags = if (g.color) core.DECO_COLOR_EMOJI else 0,
                        .deco_phase = 0,
                    }) catch return pen - x;
                }
            }
            pen += adv;
        }
        return pen - x;
    }

    /// The glyph for `scalar`, rasterized on first use. Null without a core
    /// (nothing guards the faces then), a face, or room in the atlas.
    fn glyph(self: *Builder, scalar: u21, style: Style) ?Glyph {
        const app = self.app;
        const a = &app.ui_atlas;
        const flags: u32 = (if (style.bold) core.STYLE_BOLD else 0) | (if (style.italic) core.STYLE_ITALIC else 0);
        const key = @as(u64, scalar) | (@as(u64, flags) << 32);
        if (a.glyphs.get(key)) |g| return g;
        if (!self.locked or app.fonts.regular == null) return null;
        if (a.pixels.len == 0) {
            a.pixels = app.alloc.alloc(u8, atlas_size * atlas_size * 4) catch return null;
            @memset(a.pixels, 0);
            a.pixel_size = app.fonts.pixel_size;
        }
        var bm: core.GlyphBitmap = undefined;
        if (!app.fonts.rasterizeScalar(app.alloc, scalar, flags, &.{}, &.{}, &bm)) return null;
        const w = bm.width;
        const h = bm.height;
        if (w + 2 > atlas_size or h + 2 > atlas_size) return null;
        if (a.pen_x + w + 1 > atlas_size) {
            a.pen_x = 1;
            a.pen_y += a.row_h + 1;
            a.row_h = 0;
        }
        if (a.pen_y + h + 1 > atlas_size) return null;
        if (w != 0 and h != 0) {
            const tmp = app.alloc.alloc(u8, @as(usize, w) * h * 4) catch return null;
            defer app.alloc.free(tmp);
            atlas_pixels.toRgba8(&bm, tmp);
            var row: usize = 0;
            while (row < h) : (row += 1) {
                const dst = (@as(usize, a.pen_y) + row) * atlas_size * 4 + @as(usize, a.pen_x) * 4;
                @memcpy(a.pixels[dst..][0 .. @as(usize, w) * 4], tmp[row * w * 4 ..][0 .. @as(usize, w) * 4]);
            }
        }
        const adv = @divTrunc(bm.advance_26_6 + 32, 64);
        const g: Glyph = .{
            .x = @intCast(a.pen_x),
            .y = @intCast(a.pen_y),
            .w = @intCast(w),
            .h = @intCast(h),
            .bearing_x = @intCast(std.math.clamp(bm.bearing_x, -32768, 32767)),
            .bearing_y = @intCast(std.math.clamp(bm.bearing_y, -32768, 32767)),
            .cells = if (self.cell_w > 0 and adv * 2 > self.cell_w * 3) 2 else 1,
            .color = bm.bytes_per_pixel == 4,
        };
        a.pen_x += w + 1;
        a.row_h = @max(a.row_h, h);
        a.gen +%= 1;
        a.glyphs.put(app.alloc, key, g) catch return null;
        return g;
    }
};
