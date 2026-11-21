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
const shell = @import("shell.zig");

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
    /// A glyph found no room: the next build starts the atlas over.
    full: bool = false,

    pub fn deinit(self: *Atlas, alloc: std.mem.Allocator) void {
        alloc.free(self.pixels);
        self.glyphs.deinit(alloc);
    }

    /// A rasterized glyph for `insert`: its pixels as RGBA8, w * h * 4 bytes.
    pub const Raster = struct {
        w: u32,
        h: u32,
        rgba: []const u8,
        bearing_x: i32,
        bearing_y: i32,
        cells: u8,
        color: bool,
    };

    /// The texture's pixels, zeroed, on first use.
    fn ensurePixels(self: *Atlas, alloc: std.mem.Allocator, pixel_size: u32) !void {
        if (self.pixels.len != 0) return;
        self.pixels = try alloc.alloc(u8, atlas_size * atlas_size * 4);
        @memset(self.pixels, 0);
        self.pixel_size = pixel_size;
    }

    /// Whether a build at `pixel_size` starts the atlas over: its glyphs are
    /// another size's, or one found no room.
    fn startsOver(self: *const Atlas, pixel_size: u32) bool {
        return self.pixels.len != 0 and (self.pixel_size != pixel_size or self.full);
    }

    /// `r` packed under `key`. A glyph that never fits is kept empty, so it
    /// is not rasterized again; one that finds no room left is returned
    /// empty, uncached, still `r.cells` wide, and marks the atlas full. Null
    /// only when the cache cannot grow. Pre: ensurePixels succeeded.
    fn insert(self: *Atlas, alloc: std.mem.Allocator, key: u64, r: Raster) ?Glyph {
        const empty: Glyph = .{ .x = 0, .y = 0, .w = 0, .h = 0, .bearing_x = 0, .bearing_y = 0, .cells = r.cells, .color = false };
        if (r.w + 2 > atlas_size or r.h + 2 > atlas_size) {
            self.glyphs.put(alloc, key, empty) catch return null;
            return empty;
        }
        var pen_x = self.pen_x;
        var pen_y = self.pen_y;
        var row_h = self.row_h;
        if (pen_x + r.w + 1 > atlas_size) {
            pen_x = 1;
            pen_y += row_h + 1;
            row_h = 0;
        }
        if (pen_y + r.h + 1 > atlas_size) {
            self.full = true;
            return empty;
        }
        const g: Glyph = .{
            .x = @intCast(pen_x),
            .y = @intCast(pen_y),
            .w = @intCast(r.w),
            .h = @intCast(r.h),
            .bearing_x = @intCast(std.math.clamp(r.bearing_x, -32768, 32767)),
            .bearing_y = @intCast(std.math.clamp(r.bearing_y, -32768, 32767)),
            .cells = r.cells,
            .color = r.color,
        };
        self.glyphs.put(alloc, key, g) catch return null;
        var row: usize = 0;
        const row_bytes = @as(usize, r.w) * 4;
        while (row < r.h) : (row += 1) {
            const dst = (@as(usize, pen_y) + row) * atlas_size * 4 + @as(usize, pen_x) * 4;
            @memcpy(self.pixels[dst..][0..row_bytes], r.rgba[row * row_bytes ..][0..row_bytes]);
        }
        self.pen_x = pen_x + r.w + 1;
        self.pen_y = pen_y;
        self.row_h = @max(row_h, r.h);
        self.gen +%= 1;
        return g;
    }

    fn reset(self: *Atlas, pixel_size: u32) void {
        self.glyphs.clearRetainingCapacity();
        @memset(self.pixels, 0);
        self.pen_x = 1;
        self.pen_y = 1;
        self.row_h = 0;
        self.pixel_size = pixel_size;
        self.full = false;
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

    /// Draws the same pixels as `other` (the hits draw nothing).
    pub fn eql(self: *const Layer, other: *const Layer) bool {
        const b = std.mem.sliceAsBytes;
        return std.mem.eql(u8, b(self.solid.items), b(other.solid.items)) and
            std.mem.eql(u8, b(self.round.items), b(other.round.items)) and
            std.mem.eql(u8, b(self.text.items), b(other.text.items));
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
    /// The atlas held no glyph when this build started: an overflow now
    /// would recur on a rebuild, so it does not ask for one.
    started_empty: bool,

    pub fn begin(app: *App, layer: *Layer) Builder {
        layer.clear();
        // Before the core exists (a start that announces its progress)
        // nothing else touches the faces: they are as good as locked.
        if (app.corep) |cp| core.zonvie_core_lock_grid(cp);
        const locked = true;
        const f = &app.fonts;
        const a = &app.ui_atlas;
        // Safe while the layer on screen still samples the old glyphs: the
        // renderer runs on this thread and draws only after the swap.
        if (a.startsOver(f.pixel_size)) a.reset(f.pixel_size);
        return .{
            .app = app,
            .layer = layer,
            .locked = locked,
            .cell_w = @intCast(f.cell_w_px),
            .cell_h = @intCast(f.cell_h_px),
            .ascent = @divTrunc(f.ascent_26_6 + 32, 64),
            .started_empty = a.glyphs.count() == 0,
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
    /// (nothing guards the faces then) or a face. Without room in the atlas
    /// it is an empty glyph of its width, and the atlas starts over with the
    /// next build.
    fn glyph(self: *Builder, scalar: u21, style: Style) ?Glyph {
        const app = self.app;
        const a = &app.ui_atlas;
        const flags: u32 = (if (style.bold) core.STYLE_BOLD else 0) | (if (style.italic) core.STYLE_ITALIC else 0);
        const key = @as(u64, scalar) | (@as(u64, flags) << 32);
        if (a.glyphs.get(key)) |g| return g;
        if (!self.locked or app.fonts.regular == null) return null;
        a.ensurePixels(app.alloc, app.fonts.pixel_size) catch return null;
        var bm: core.GlyphBitmap = undefined;
        if (!app.fonts.rasterizeScalar(app.alloc, scalar, flags, &.{}, &.{}, &bm)) return null;
        const w = bm.width;
        const h = bm.height;
        const adv = @divTrunc(bm.advance_26_6 + 32, 64);
        const len = @as(usize, w) * h * 4;
        const tmp = app.alloc.alloc(u8, len) catch return null;
        defer app.alloc.free(tmp);
        if (len != 0) atlas_pixels.toRgba8(&bm, tmp);
        const was_full = a.full;
        const g = a.insert(app.alloc, key, .{
            .w = w,
            .h = h,
            .rgba = tmp,
            .bearing_x = bm.bearing_x,
            .bearing_y = bm.bearing_y,
            .cells = if (self.cell_w > 0 and adv * 2 > self.cell_w * 3) 2 else 1,
            .color = bm.bytes_per_pixel == 4,
        }) orelse return null;
        // A rebuild starts the atlas over, unless this build already did.
        if (a.full and !was_full and !self.started_empty) shell.queueRefresh(app);
        return g;
    }
};

const testing = std.testing;

/// A w x h glyph of zeros, `cells` wide.
fn raster(buf: []u8, w: u32, h: u32, cells: u8) Atlas.Raster {
    return .{ .w = w, .h = h, .rgba = buf[0 .. @as(usize, w) * h * 4], .bearing_x = 0, .bearing_y = 0, .cells = cells, .color = false };
}

test "a glyph that finds no room keeps its width and marks the atlas full" {
    var a: Atlas = .{};
    defer a.deinit(testing.allocator);
    try a.ensurePixels(testing.allocator, 16);
    const buf = try testing.allocator.alloc(u8, 500 * 500 * 4);
    defer testing.allocator.free(buf);
    @memset(buf, 0);
    // Two 500 px glyphs to a row, two rows.
    for (0..4) |i| try testing.expect(a.insert(testing.allocator, i, raster(buf, 500, 500, 1)).?.w == 500);
    try testing.expect(!a.full);
    const g = a.insert(testing.allocator, 9, raster(buf, 500, 500, 2)).?;
    try testing.expectEqual(@as(u8, 2), g.cells);
    try testing.expectEqual(@as(u16, 0), g.w);
    try testing.expect(a.full);
    // Not cached: it is tried again once the atlas starts over.
    try testing.expect(a.glyphs.get(9) == null);
}

test "a full atlas starts over at the next build" {
    var a: Atlas = .{};
    defer a.deinit(testing.allocator);
    try a.ensurePixels(testing.allocator, 16);
    const buf = try testing.allocator.alloc(u8, 600 * 600 * 4);
    defer testing.allocator.free(buf);
    @memset(buf, 0);
    try testing.expect(!a.startsOver(16));
    _ = a.insert(testing.allocator, 1, raster(buf, 600, 600, 1));
    _ = a.insert(testing.allocator, 2, raster(buf, 600, 600, 1));
    try testing.expect(a.startsOver(16));
    a.reset(16);
    try testing.expect(!a.startsOver(16));
    const g = a.insert(testing.allocator, 2, raster(buf, 600, 600, 1)).?;
    try testing.expectEqual(@as(u16, 1), g.x);
    try testing.expectEqual(@as(u16, 1), g.y);
}

test "a glyph larger than the atlas is kept empty, of its width" {
    var a: Atlas = .{};
    defer a.deinit(testing.allocator);
    try a.ensurePixels(testing.allocator, 16);
    const g = a.insert(testing.allocator, 5, .{ .w = atlas_size, .h = 10, .rgba = &.{}, .bearing_x = 0, .bearing_y = 0, .cells = 2, .color = false }).?;
    try testing.expectEqual(@as(u8, 2), g.cells);
    try testing.expectEqual(@as(u16, 0), g.w);
    try testing.expect(a.glyphs.get(5) != null);
    try testing.expect(!a.full);
}

