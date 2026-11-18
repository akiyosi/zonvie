//! The parts of a surface's custom-shader inputs that need no GL: which
//! iCellText store a surface reads, the cell its lattice is laid out in
//! (iCellSize), its layer table (iLayers) and its per-cell row offsets
//! (iRowOffset). postfx.zig uploads what these produce. Pure.

const std = @import("std");
const core = @import("zonvie_core");
const layer_geom = @import("layer_geom.zig");
const GridFont = layer_geom.GridFont;
const Stores = core.cell_text_store.Stores;

/// on_cell_text_row's body. `wanted` is latched at on_flush_begin from
/// whether a loaded shader reads iCellText; without one a row stages
/// nothing, so the stores never allocate.
pub fn stageCellText(stores: *Stores, wanted: bool, row: core.zonvie_cell_text_row) void {
    if (!wanted) return;
    stores.applyRow(row);
}

/// The store a surface's iCellText reads: keyed by the surface id, 1 for the
/// main window, else the external window's root grid (cell_text_store.Row.grid).
pub fn cellTextGrid(surface_id: i64) i64 {
    return surface_id;
}

/// The cell a surface's lattice is laid out in, for iCellSize: its root
/// grid's own font when it has one (an external window in a per-grid
/// font), else the global cell. `row_h_px` includes 'linespace'.
pub fn latticeCell(root_font: ?GridFont, cell_w_px: u32, row_h_px: u32) [2]u32 {
    if (root_font) |f| return .{ f.cell_w_px, f.cell_h_px };
    return .{ cell_w_px, row_h_px };
}

/// Fill iRootRows and iLayers (core.fillLayers) from a surface's committed
/// layers, root first, as windows/app.zig fillShaderLayers does. `fonts`
/// has `gridFont(grid_id) ?GridFont`. Layers are placed at their surface
/// offset (the root starts at the surface's corner) and sized in the global
/// cell (`cell_w_px`/`row_h_px`) unless in their own font; under a root in
/// its own font every layer has a cell, as the core writes its band.
pub fn fillLayers(u: *core.zonvie_shader_uniforms, layers: []const core.Layer, fonts: anytype, cell_w_px: u32, row_h_px: u32) void {
    var in: [256]core.zonvie_shader_layer = undefined;
    const root_rows: u32 = if (layers.len != 0) layers[0].rows else 0;
    const root_font = layers.len != 0 and fonts.gridFont(layers[0].grid_id) != null;
    const placed = if (layers.len > 1) layers[1..] else layers[0..0];
    var n: usize = 0;
    for (placed[placed.len - @min(placed.len, in.len) ..]) |l| {
        const f = fonts.gridFont(l.grid_id);
        const g = layer_geom.Geom.of(l, f, cell_w_px, row_h_px);
        const has_cell = f != null or root_font;
        in[n] = .{
            .grid_id = l.grid_id,
            .x_px = @floatFromInt(l.x_px),
            .y_px = @floatFromInt(l.y_px),
            .w_px = @floatFromInt(g.widthPx()),
            .h_px = @floatFromInt(g.heightPx()),
            .cell_w_px = if (has_cell) @floatFromInt(g.cell_w_px) else 0,
            .cell_h_px = if (has_cell) @floatFromInt(g.row_h_px) else 0,
            .rows = l.rows,
            .cols = l.cols,
            .z = @intCast(@max(l.z, 0)),
            .flags = if (l.flags & core.LAYER_FLOAT != 0) core.SHADER_LAYER_FLOAT else 0,
        };
        n += 1;
    }
    core.fillLayers(u, in[0..n], root_rows);
}

/// iRowOffset's CPU side: per surface cell, how many pixels down this
/// frame draws that cell's content. Reallocated only when the surface's
/// cell grid changes; `dirty` until the texture takes it.
pub const RowOffsets = struct {
    values: std.ArrayListUnmanaged(f32) = .empty,
    cols: u32 = 0,
    rows: u32 = 0,
    dirty: bool = false,

    pub fn deinit(self: *RowOffsets, alloc: std.mem.Allocator) void {
        self.values.deinit(alloc);
        self.* = .{};
    }

    /// Start the frame at rest over cols x rows cells.
    pub fn begin(self: *RowOffsets, alloc: std.mem.Allocator, cols: u32, rows: u32) void {
        const n = @as(usize, cols) * rows;
        if (self.values.items.len != n or self.cols != cols) {
            self.values.resize(alloc, n) catch {
                self.values.clearRetainingCapacity();
                self.cols = 0;
                self.rows = 0;
                return;
            };
            self.cols = cols;
            self.rows = rows;
            self.dirty = true;
        }
        for (self.values.items) |*v| {
            if (v.* != 0) self.dirty = true;
            v.* = 0;
        }
    }

    /// Cells [col_start, col_end) x [row_start, row_end) draw `offset_px` down.
    pub fn add(self: *RowOffsets, col_start: i64, col_end: i64, row_start: i64, row_end: i64, offset_px: f32) void {
        if (offset_px == 0) return;
        const c0: usize = @intCast(std.math.clamp(col_start, 0, self.cols));
        const c1: usize = @intCast(std.math.clamp(col_end, 0, self.cols));
        const r0: usize = @intCast(std.math.clamp(row_start, 0, self.rows));
        const r1: usize = @intCast(std.math.clamp(row_end, 0, self.rows));
        if (c0 >= c1 or r0 >= r1) return;
        for (r0..r1) |r| @memset(self.values.items[r * self.cols + c0 .. r * self.cols + c1], offset_px);
        self.dirty = true;
    }

    /// This frame's eases over a surface's layers, root first: the root's
    /// scroll region, then each eased layer's at its cells on the lattice,
    /// which wins where it covers the root (windows/app.zig). `eases` has
    /// `gridEase(grid_id)` returning the grid's ease, planned this frame.
    /// `cell` is the lattice's (latticeCell). The surface is sized by its
    /// root, like iCellAge.
    pub fn fill(self: *RowOffsets, alloc: std.mem.Allocator, layers: []const core.Layer, eases: anytype, cell: [2]u32) void {
        if (layers.len == 0 or cell[0] == 0 or cell[1] == 0) return;
        self.begin(alloc, layers[0].cols, layers[0].rows);
        for (layers, 0..) |l, i| {
            const e = eases.gridEase(l.grid_id) orelse continue;
            const r = e.region();
            if (r[1] <= r[0]) continue;
            const top: i64 = if (i == 0) 0 else @divFloor(@as(i64, l.y_px), cell[1]);
            const left: i64 = if (i == 0) 0 else @divFloor(@as(i64, l.x_px), cell[0]);
            self.add(left, left + @as(i64, l.cols), top + r[0], top + r[1], e.offset_px);
        }
    }
};

test "cell text: no shader uses it -> store absent and callback is a no-op" {
    var stores = Stores.init(std.testing.allocator);
    defer stores.deinit();
    const cps = [_]u32{ 'a', 0x112233, 0x445566, 1, 'b', 0x112233, 0x445566, 0 };
    const row: core.zonvie_cell_text_row = .{ .grid = 1, .tex_rows = 1, .tex_cols = 2, .row = 0, .col = 0, .count = 2, .texels = &cps };
    stageCellText(&stores, false, row);
    stores.commit(1);
    try std.testing.expectEqual(@as(usize, 0), stores.stores.items.len);
    var cache: core.cell_text_store.SyncCache = .{};
    var values: []const u32 = &.{};
    try std.testing.expectEqual(core.cell_text_store.SyncResult.unavailable, stores.sync(cellTextGrid(1), true, &cache, &values));

    // With a shader that reads it, the same row reaches the store.
    stageCellText(&stores, true, row);
    stores.commit(1);
    try std.testing.expectEqual(core.cell_text_store.SyncResult.dirty, stores.sync(cellTextGrid(1), true, &cache, &values));
    defer stores.endUpload();
    try std.testing.expectEqualSlices(u32, &cps, values);
}

test "external surface syncs its own grid's cell text" {
    var stores = Stores.init(std.testing.allocator);
    defer stores.deinit();
    const main_cps = [_]u32{ 'm', 1, 2, 3, 'm', 1, 2, 3, 'm', 1, 2, 3 };
    const ext_cps = [_]u32{ 'x', 4, 5, 6, 'y', 7, 8, 9 };
    stageCellText(&stores, true, .{ .grid = 1, .tex_rows = 1, .tex_cols = 3, .row = 0, .col = 0, .count = 3, .texels = &main_cps });
    stageCellText(&stores, true, .{ .grid = 7, .tex_rows = 1, .tex_cols = 2, .row = 0, .col = 0, .count = 2, .texels = &ext_cps });
    stores.commit(1);
    stores.commit(7);
    var cache: core.cell_text_store.SyncCache = .{};
    var values: []const u32 = &.{};
    try std.testing.expectEqual(core.cell_text_store.SyncResult.dirty, stores.sync(cellTextGrid(7), true, &cache, &values));
    defer stores.endUpload();
    try std.testing.expectEqual(@as(u32, 2), cache.cols);
    try std.testing.expectEqualSlices(u32, &ext_cps, values);
}

test "an external surface in its own font sizes iCellSize by its root grid's cell" {
    const f: GridFont = .{ .font_id = 2, .cell_w_px = 12, .cell_h_px = 22, .extent_w_px = 120, .extent_h_px = 88 };
    try std.testing.expectEqual([2]u32{ 12, 22 }, latticeCell(f, 8, 16));
    try std.testing.expectEqual([2]u32{ 8, 16 }, latticeCell(null, 8, 16));
}

const TestFonts = struct {
    id: i64,
    f: GridFont,
    pub fn gridFont(self: TestFonts, id: i64) ?GridFont {
        return if (self.id == id) self.f else null;
    }
};

test "layer table: a float carries FLOAT and a font grid its own cell" {
    const layers = [_]core.Layer{
        .{ .grid_id = 1, .anchor_grid = 1, .x_px = 0, .y_px = 0, .rows = 10, .cols = 20, .z = 0, .flags = 0 },
        .{ .grid_id = 3, .anchor_grid = 1, .x_px = 16, .y_px = 32, .rows = 2, .cols = 5, .z = 1, .flags = 0 },
        .{ .grid_id = 4, .anchor_grid = 1, .x_px = 8, .y_px = 16, .rows = 3, .cols = 4, .z = 2, .flags = core.LAYER_FLOAT },
    };
    const fonts: TestFonts = .{ .id = 3, .f = .{ .font_id = 1, .cell_w_px = 12, .cell_h_px = 24, .extent_w_px = 60, .extent_h_px = 48 } };
    var u: core.zonvie_shader_uniforms = .{};
    fillLayers(&u, &layers, fonts, 8, 16);
    try std.testing.expectEqual(@as(@TypeOf(u.iRootRows), 10), u.iRootRows);
    try std.testing.expectEqual(@as(@TypeOf(u.iLayerCount), 2), u.iLayerCount);
    // Topmost first: the float, on the lattice, then the font grid.
    try std.testing.expectEqual(@as(f32, 4), u.iLayers[2][2]);
    try std.testing.expect(@as(u32, @intFromFloat(u.iLayers[2][3])) & core.SHADER_LAYER_FLOAT != 0);
    try std.testing.expectEqual([4]f32{ 16, 32, 60, 48 }, u.iLayers[3]);
    try std.testing.expectEqual(@as(f32, 12), u.iLayers[4][0]);
}

const GridEase = @import("grid_ease.zig").GridEase;

const TestEases = struct {
    root: *const GridEase,
    split: *const GridEase,
    pub fn gridEase(self: TestEases, id: i64) ?*const GridEase {
        return if (id == 1) self.root else if (id == 2) self.split else null;
    }
};

test "row offsets: an eased split offsets only its own cells" {
    const rest: GridEase = .{};
    var split: GridEase = .{ .easing = true, .offset_px = 5 };
    split.spring.region_start = 0;
    split.spring.region_end = 2;
    const layers = [_]core.Layer{
        .{ .grid_id = 1, .anchor_grid = 1, .x_px = 0, .y_px = 0, .rows = 4, .cols = 4, .z = 0, .flags = 0 },
        .{ .grid_id = 2, .anchor_grid = 1, .x_px = 16, .y_px = 10, .rows = 3, .cols = 2, .z = 1, .flags = 0 },
    };
    var ro: RowOffsets = .{};
    defer ro.deinit(std.testing.allocator);
    ro.fill(std.testing.allocator, &layers, TestEases{ .root = &rest, .split = &split }, .{ 8, 10 });
    try std.testing.expectEqualSlices(f32, &.{
        0, 0, 0, 0,
        0, 0, 5, 5,
        0, 0, 5, 5,
        0, 0, 0, 0,
    }, ro.values.items);
    try std.testing.expect(ro.dirty);
}
