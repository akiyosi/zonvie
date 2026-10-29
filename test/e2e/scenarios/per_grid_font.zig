// per_grid_font — vim.w.zonvie_font_scale / neovide_font_scale against real nvim.
// Exercises: tracked exec_lua pull, nvim_ui_try_resize_grid, grid_resize, win_pos.
//
// The harness frontend reports a 10x20 px global cell and a slot cell of
// 10x20 x scale (doubled for a size-28 guifont). Expected cells follow the
// spec formula max(1, floor(frame_cells * global_cell_px / grid_cell_px)).

const std = @import("std");
const Harness = @import("../harness.zig").Harness;
const FontMode = @import("zonvie_core").grid_mod.FontMode;

const global_cell_w_px: u32 = 10;
const global_cell_h_px: u32 = 20;

fn requestedCells(frame_cells: u32, global_cell_px: u32, grid_cell_px: u32) u32 {
    return @max(1, frame_cells * global_cell_px / grid_cell_px);
}

fn waitGridSize(h: *Harness, grid_id: i64, rows: u32, cols: u32) !void {
    const Ctx = struct { g: i64, r: u32, c: u32 };
    h.waitUntil(Ctx{ .g = grid_id, .r = rows, .c = cols }, struct {
        fn check(c: Ctx, hh: *Harness) bool {
            const s = hh.subGridSize(c.g) orelse return false;
            return s.rows == c.r and s.cols == c.c;
        }
    }.check, h.opts.timeout_ms) catch |e| {
        const s = h.subGridSize(grid_id);
        std.debug.print("[e2e] waitGridSize failed: grid={d} want {d}x{d} have {any}\n", .{ grid_id, rows, cols, s });
        return e;
    };
}

fn vsplitPair(h: *Harness) !struct { left: i64, right: i64 } {
    const right = h.winGrid();
    try h.command("vsplit");
    const Ctx = struct { prev: i64 };
    try h.waitUntil(Ctx{ .prev = right }, struct {
        fn check(c: Ctx, hh: *Harness) bool {
            return hh.winGrid() != c.prev;
        }
    }.check, h.opts.timeout_ms);
    return .{ .left = h.winGrid(), .right = right };
}

/// The one positioned grid that carries a font in `mode`, waiting for it.
fn waitFontGrid(h: *Harness, mode: FontMode) !i64 {
    const Ctx = struct { mode: FontMode };
    try h.waitUntil(Ctx{ .mode = mode }, struct {
        fn check(c: Ctx, hh: *Harness) bool {
            return hh.findFontGrid(c.mode) != null;
        }
    }.check, h.opts.timeout_ms);
    return h.findFontGrid(mode).?;
}

pub fn runSplit(alloc: std.mem.Allocator) !void {
    var h = try Harness.init(alloc, .{ .font_slots = true });
    defer h.deinit();
    const pair = try vsplitPair(h);
    const frame = h.subGridSize(pair.left) orelse return error.GridNotFound;
    const right_before = h.gridPos(pair.right) orelse return error.GridNotFound;
    const sent_before = h.fontResizeStats().requests;
    try h.command("lua zonvie.set_window_font(0, { scale = 0.5 })");
    // Slot cell 5x10 in a 10x20 lattice: twice the rows and cols.
    const rows = requestedCells(frame.rows, global_cell_h_px, 10);
    const cols = requestedCells(frame.cols, global_cell_w_px, 5);
    try std.testing.expectEqual(frame.rows * 2, rows);
    try waitGridSize(h, pair.left, rows, cols);
    const stats = h.fontResizeStats();
    try std.testing.expect(stats.requests > sent_before);
    try std.testing.expectEqual(rows, stats.last_rows);
    try std.testing.expectEqual(cols, stats.last_cols);
    const right_after = h.gridPos(pair.right) orelse return error.GridNotFound;
    try std.testing.expectEqual(right_before.row, right_after.row);
    try std.testing.expectEqual(right_before.col, right_after.col);
}

pub fn runSplitResize(alloc: std.mem.Allocator) !void {
    var h = try Harness.init(alloc, .{ .font_slots = true });
    defer h.deinit();
    const pair = try vsplitPair(h);
    const frame = h.subGridSize(pair.left) orelse return error.GridNotFound;
    try h.command("lua zonvie.set_window_font(0, { scale = 0.5 })");
    try waitGridSize(h, pair.left, requestedCells(frame.rows, global_cell_h_px, 10), requestedCells(frame.cols, global_cell_w_px, 5));
    // The frame shrinks by 4 global cells; the request must follow it.
    try h.command("vertical resize -4");
    try waitGridSize(h, pair.left, requestedCells(frame.rows, global_cell_h_px, 10), requestedCells(frame.cols - 4, global_cell_w_px, 5));
}

pub fn runSplitToExternalResize(alloc: std.mem.Allocator) !void {
    var h = try Harness.init(alloc, .{ .font_slots = true });
    defer h.deinit();
    const pair = try vsplitPair(h);
    const frame = h.subGridSize(pair.left) orelse return error.GridNotFound;
    try h.command("lua zonvie.set_window_font(0, { scale = 0.5 })");
    const rows = requestedCells(frame.rows, global_cell_h_px, 10);
    const cols = requestedCells(frame.cols, global_cell_w_px, 5);
    try waitGridSize(h, pair.left, rows, cols);
    try h.command("wincmd ge");
    const Ctx = struct { g: i64 };
    try h.waitUntil(Ctx{ .g = pair.left }, struct {
        fn check(c: Ctx, hh: *Harness) bool {
            return hh.isExternalGrid(c.g);
        }
    }.check, h.opts.timeout_ms);
    // The split's request survives into the float; the core releases it.
    try h.waitUntil(Ctx{ .g = pair.left }, struct {
        fn check(c: Ctx, hh: *Harness) bool {
            return !hh.core.grid.split_request_held.contains(c.g) and hh.core.split_release_outbox.items.len == 0;
        }
    }.check, h.opts.timeout_ms);
    // A round trip after the release: Neovim has handled it.
    try h.command("redraw");
    try waitGridSize(h, pair.left, rows, cols);
    // The external window's OS resize, in its font's cells: the grid follows.
    h.core.requestTryResizeGrid(pair.left, rows / 2, cols / 2);
    try waitGridSize(h, pair.left, rows / 2, cols / 2);
}

pub fn runClear(alloc: std.mem.Allocator) !void {
    var h = try Harness.init(alloc, .{ .font_slots = true });
    defer h.deinit();
    const pair = try vsplitPair(h);
    const frame = h.subGridSize(pair.left) orelse return error.GridNotFound;
    try h.command("lua zonvie.set_window_font(0, { scale = 0.5 })");
    try waitGridSize(h, pair.left, requestedCells(frame.rows, global_cell_h_px, 10), requestedCells(frame.cols, global_cell_w_px, 5));
    try std.testing.expect(h.gridFont(pair.left) != null);
    const sent = h.fontResizeStats().requests;
    try h.command("lua zonvie.set_window_font(0, {})");
    // Clearing a split sends a 0x0 request and the layout size comes back.
    try waitGridSize(h, pair.left, frame.rows, frame.cols);
    const stats = h.fontResizeStats();
    try std.testing.expect(stats.requests > sent);
    try std.testing.expectEqual(@as(u32, 0), stats.last_rows);
    try std.testing.expectEqual(@as(u32, 0), stats.last_cols);
    try std.testing.expect(h.gridFont(pair.left) == null);
}

const float_cfg = "relative = 'editor', row = 2, col = 10, width = 20, height = 4";

pub fn runScaleViewFloat(alloc: std.mem.Allocator) !void {
    var h = try Harness.init(alloc, .{ .font_slots = true });
    defer h.deinit();
    try h.command("lua _G.fw = vim.api.nvim_open_win(vim.api.nvim_create_buf(false, true), false, { " ++ float_cfg ++ " })");
    try h.command("lua vim.w[_G.fw].neovide_font_scale = 0.5; vim.rpcnotify(vim.g.zonvie_channel or 0, 'zonvie_window_font', _G.fw)");
    const gid = try waitFontGrid(h, .scale_view);
    // try_resize_grid on a float would rewrite its config (ui.c:769-773) and
    // change the grid size; neither happens.
    try std.testing.expectEqual(@as(u64, 0), h.fontResizeStats().requests);
    const sz = h.subGridSize(gid) orelse return error.GridNotFound;
    try std.testing.expectEqual(@as(u32, 4), sz.rows);
    try std.testing.expectEqual(@as(u32, 20), sz.cols);
}

/// The one positioned grid not in `known`, waiting for it.
fn newPositionedGrid(h: *Harness, alloc: std.mem.Allocator, known: []const i64) !i64 {
    const Ctx = struct { known: []const i64, alloc: std.mem.Allocator };
    try h.waitUntil(Ctx{ .known = known, .alloc = alloc }, struct {
        fn check(c: Ctx, hh: *Harness) bool {
            const ids = hh.positionedGridsAlloc(c.alloc) catch return false;
            defer c.alloc.free(ids);
            return ids.len == c.known.len + 1;
        }
    }.check, h.opts.timeout_ms);
    const ids = try h.positionedGridsAlloc(alloc);
    defer alloc.free(ids);
    for (ids) |id| {
        if (std.mem.indexOfScalar(i64, known, id) == null) return id;
    }
    return error.GridNotFound;
}

/// Neovim paints floats of one zindex in compositor order, the later-opened
/// one on top (ui_compositor.c ui_comp_put_grid). A float's own font does
/// not move it in that order.
pub fn runFontViewFloatKeepsZOrder(alloc: std.mem.Allocator) !void {
    var h = try Harness.init(alloc, .{ .font_slots = true });
    defer h.deinit();
    const before = try h.positionedGridsAlloc(alloc);
    defer alloc.free(before);
    try h.command("lua _G.f1 = vim.api.nvim_open_win(vim.api.nvim_create_buf(false, true), false, { " ++ float_cfg ++ ", zindex = 50, border = 'single' })");
    const g1 = try newPositionedGrid(h, alloc, before);
    const with_f1 = try std.mem.concat(alloc, i64, &.{ before, &.{g1} });
    defer alloc.free(with_f1);
    try h.command("lua _G.f2 = vim.api.nvim_open_win(vim.api.nvim_create_buf(false, true), false, { relative = 'editor', row = 3, col = 12, width = 20, height = 4, zindex = 50, border = 'single' })");
    const g2 = try newPositionedGrid(h, alloc, with_f1);
    try h.command("redraw");
    const Ctx = struct { g1: i64, g2: i64 };
    const above = struct {
        fn check(c: Ctx, hh: *Harness) bool {
            const z1 = hh.layoutZ(1, c.g1) orelse return false;
            const z2 = hh.layoutZ(1, c.g2) orelse return false;
            return z2 > z1;
        }
    }.check;
    try h.waitUntil(Ctx{ .g1 = g1, .g2 = g2 }, above, h.opts.timeout_ms);

    try h.command("lua zonvie.set_window_font(_G.f1, { guifont = 'Big:h28' })");
    try h.command("lua zonvie.set_window_font(_G.f2, { scale = 0.6 })");
    try h.waitUntil(Ctx{ .g1 = g1, .g2 = g2 }, struct {
        fn check(c: Ctx, hh: *Harness) bool {
            return hh.gridFont(c.g1) != null and hh.gridFont(c.g2) != null;
        }
    }.check, h.opts.timeout_ms);
    try h.command("redraw");
    try h.waitUntil(Ctx{ .g1 = g1, .g2 = g2 }, above, h.opts.timeout_ms);
    // Reconfiguring both, the font float last, does not lift it either.
    try h.command("lua vim.api.nvim_win_set_config(_G.f2, { relative = 'editor', row = 4, col = 14, width = 22, height = 5 })");
    try h.command("lua vim.api.nvim_win_set_config(_G.f1, { relative = 'editor', row = 3, col = 11, width = 24, height = 6 })");
    try h.command("redraw");
    try h.waitUntil(Ctx{ .g1 = g1, .g2 = g2 }, above, h.opts.timeout_ms);
    // Nor does a resend of every row (what the GUI does on :mode).
    try h.command("mode");
    try h.command("redraw");
    try h.waitUntil(Ctx{ .g1 = g1, .g2 = g2 }, above, h.opts.timeout_ms);
}

pub fn runFontViewFloat(alloc: std.mem.Allocator) !void {
    var h = try Harness.init(alloc, .{ .font_slots = true });
    defer h.deinit();
    try h.command("lua _G.fw = vim.api.nvim_open_win(vim.api.nvim_create_buf(false, true), false, { " ++ float_cfg ++ " })");
    try h.command("lua zonvie.set_window_font(_G.fw, { guifont = 'Big:h28' })");
    const gid = try waitFontGrid(h, .font_view);
    try std.testing.expectEqual(@as(u64, 0), h.fontResizeStats().requests);
    // A later round trip through Neovim proves the grid was not resized.
    try h.command("lua vim.api.nvim_win_set_cursor(_G.fw, {1, 0})");
    try h.command("redraw");
    const sz = h.subGridSize(gid) orelse return error.GridNotFound;
    try std.testing.expectEqual(@as(u32, 4), sz.rows);
    try std.testing.expectEqual(@as(u32, 20), sz.cols);
    try std.testing.expectEqual(@as(u64, 0), h.fontResizeStats().requests);
}
