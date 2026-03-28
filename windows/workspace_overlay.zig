// workspace_overlay.zig — D3D11 workspace tile overlay for Windows.
//
// Renders a grid of tile thumbnails on top of the main back_tex when the
// workspace overview is visible (workspace.scale < 1.0). Follows the same
// visual model as the macOS WorkspaceOverlayView: a camera-zoom effect
// where scale=1.0 shows the active tile fullscreen and scale=0.0 shows
// a 3×3 grid of all tile slots.

const std = @import("std");
const c = @import("win32.zig").c;
const d3d11 = @import("renderer/d3d11_renderer.zig");
const workspace_mod = @import("workspace.zig");
const WorkspaceState = workspace_mod.WorkspaceState;
const applog = @import("app.zig").applog;

/// Pixel rect for a tile slot in the overlay. Produced by layoutTile so
/// rendering and hit-testing share a single geometry source.
pub const TileRect = struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,

    pub fn contains(self: TileRect, px: f32, py: f32) bool {
        return px >= self.x and px <= self.x + self.w and py >= self.y and py <= self.y + self.h;
    }
};

/// Kind of slot, determined by the WorkspaceState at layout time.
pub const SlotKind = enum { occupied, plus, empty };

/// Compute the pixel rect and slot kind for tile index `idx` at the current
/// workspace scale. Returns null if `idx` is out of range (>= max_tiles).
/// Keep this in sync with the loop body in `draw`.
pub fn layoutTile(workspace: *const WorkspaceState, window_w: u32, window_h: u32, idx: u32) ?struct { rect: TileRect, kind: SlotKind } {
    if (window_w == 0 or window_h == 0) return null;
    if (idx >= workspace.max_tiles) return null;

    const scale = workspace.scale;
    const t = 1.0 - scale;

    const cols: u32 = @intFromFloat(@ceil(@sqrt(@as(f32, @floatFromInt(workspace.max_tiles)))));
    const rows: u32 = (workspace.max_tiles + cols - 1) / cols;

    const wf: f32 = @floatFromInt(window_w);
    const hf: f32 = @floatFromInt(window_h);
    const pad_px: f32 = 12.0;

    const grid_tile_w: f32 = (wf - pad_px * @as(f32, @floatFromInt(cols + 1))) / @as(f32, @floatFromInt(cols));
    const grid_tile_h: f32 = (hf - pad_px * @as(f32, @floatFromInt(rows + 1))) / @as(f32, @floatFromInt(rows));

    const tile_w: f32 = wf + (grid_tile_w - wf) * t;
    const tile_h: f32 = hf + (grid_tile_h - hf) * t;

    const active_col: u32 = workspace.active_tile % @as(u8, @intCast(cols));
    const active_row: u32 = workspace.active_tile / @as(u8, @intCast(cols));

    const grid_origin_x: f32 = pad_px;
    const grid_origin_y: f32 = pad_px;

    const active_cx_grid: f32 = grid_origin_x + @as(f32, @floatFromInt(active_col)) * (grid_tile_w + pad_px) + grid_tile_w * 0.5;
    const active_cy_grid: f32 = grid_origin_y + @as(f32, @floatFromInt(active_row)) * (grid_tile_h + pad_px) + grid_tile_h * 0.5;

    const active_cx_full: f32 = wf * 0.5;
    const active_cy_full: f32 = hf * 0.5;

    const active_cx: f32 = active_cx_full + (active_cx_grid - active_cx_full) * t;
    const active_cy: f32 = active_cy_full + (active_cy_grid - active_cy_full) * t;

    const offset_x: f32 = active_cx - @as(f32, @floatFromInt(active_col)) * (tile_w + pad_px * t) - tile_w * 0.5 - pad_px * t;
    const offset_y: f32 = active_cy - @as(f32, @floatFromInt(active_row)) * (tile_h + pad_px * t) - tile_h * 0.5 - pad_px * t;

    const col = idx % cols;
    const row = idx / cols;
    const px_x: f32 = offset_x + @as(f32, @floatFromInt(col)) * (tile_w + pad_px * t) + pad_px * t;
    const px_y: f32 = offset_y + @as(f32, @floatFromInt(row)) * (tile_h + pad_px * t) + pad_px * t;

    const rect = TileRect{ .x = px_x, .y = px_y, .w = tile_w, .h = tile_h };
    const kind: SlotKind = blk: {
        if (idx < workspace.tiles.items.len) {
            const tile = &workspace.tiles.items[idx];
            if (tile.isOccupied()) break :blk .occupied;
        }
        // First non-occupied slot is the "+" slot; others are hidden empties.
        var first_empty: u32 = workspace.max_tiles;
        var i: u32 = 0;
        while (i < workspace.max_tiles) : (i += 1) {
            const occupied = i < workspace.tiles.items.len and workspace.tiles.items[i].isOccupied();
            if (!occupied) {
                first_empty = i;
                break;
            }
        }
        break :blk if (idx == first_empty) .plus else .empty;
    };

    return .{ .rect = rect, .kind = kind };
}

/// Result of a mouse hit-test on the overlay.
pub const HitResult = union(enum) {
    none,
    tile: u32,
    plus: u32,
};

pub fn hitTest(workspace: *const WorkspaceState, window_w: u32, window_h: u32, px: f32, py: f32) HitResult {
    var idx: u32 = 0;
    while (idx < workspace.max_tiles) : (idx += 1) {
        const layout = layoutTile(workspace, window_w, window_h, idx) orelse continue;
        if (!layout.rect.contains(px, py)) continue;
        return switch (layout.kind) {
            .occupied => .{ .tile = idx },
            .plus => .{ .plus = idx },
            .empty => .none,
        };
    }
    return .none;
}

/// Draw the workspace overlay on top of the current back_tex.
/// Call this from WM_PAINT when workspace.isOverviewVisible() is true.
pub fn draw(renderer: *d3d11.Renderer, workspace: *const WorkspaceState, window_w: u32, window_h: u32) void {
    if (window_w == 0 or window_h == 0) return;

    const scale = workspace.scale;
    const t = 1.0 - scale;

    const bg_alpha = @min(t * 1.5, 0.88);
    renderer.drawOverlaySolid(.{ -1, 1, 1, -1 }, .{ 0, 0, 0, bg_alpha }) catch return;

    const wf: f32 = @floatFromInt(window_w);
    const hf: f32 = @floatFromInt(window_h);

    var idx: u32 = 0;
    while (idx < workspace.max_tiles) : (idx += 1) {
        const layout = layoutTile(workspace, window_w, window_h, idx) orelse continue;
        const rect = layout.rect;

        const ndc = pixelToNDC(rect.x, rect.y, rect.w, rect.h, wf, hf);
        if (ndc[2] < -1.0 or ndc[0] > 1.0 or ndc[3] > 1.0 or ndc[1] < -1.0) continue;

        const is_active = (idx == workspace.active_tile);

        switch (layout.kind) {
            .occupied => {
                const bg_color: [4]f32 = if (is_active) .{ 0.15, 0.15, 0.2, 1.0 } else .{ 0.08, 0.08, 0.1, 1.0 };
                renderer.drawOverlaySolid(ndc, bg_color) catch continue;
                if (idx < workspace.tiles.items.len) {
                    const tile = &workspace.tiles.items[idx];
                    if (tile.snapshot) |snap| {
                        renderer.drawOverlayQuad(snap.srv, ndc, 1.0) catch {};
                    }
                }
                if (is_active) {
                    drawBorder(renderer, ndc, .{ 0.4, 0.6, 1.0, 0.9 }, 2.0, wf, hf) catch {};
                }
            },
            .plus => {
                const bg_color: [4]f32 = .{ 0.05, 0.05, 0.08, 1.0 };
                renderer.drawOverlaySolid(ndc, bg_color) catch continue;
                drawBorder(renderer, ndc, .{ 0.35, 0.35, 0.42, 0.8 }, 1.5, wf, hf) catch {};
                drawPlusGlyph(renderer, rect, wf, hf) catch {};
            },
            .empty => {
                // Leave fully empty slots faintly visible for structure.
                const bg_color: [4]f32 = .{ 0.04, 0.04, 0.05, 0.9 };
                renderer.drawOverlaySolid(ndc, bg_color) catch continue;
            },
        }
    }
}

/// Convert pixel rect to NDC coordinates.
/// Returns { ndc_left, ndc_top, ndc_right, ndc_bottom }.
fn pixelToNDC(px_x: f32, px_y: f32, px_w: f32, px_h: f32, win_w: f32, win_h: f32) [4]f32 {
    return .{
        px_x / win_w * 2.0 - 1.0,
        1.0 - px_y / win_h * 2.0,
        (px_x + px_w) / win_w * 2.0 - 1.0,
        1.0 - (px_y + px_h) / win_h * 2.0,
    };
}

fn drawBorder(renderer: *d3d11.Renderer, ndc: [4]f32, color: [4]f32, thickness_px: f32, win_w: f32, win_h: f32) !void {
    const dx = thickness_px / win_w * 2.0;
    const dy = thickness_px / win_h * 2.0;

    try renderer.drawOverlaySolid(.{ ndc[0], ndc[1], ndc[2], ndc[1] - dy }, color);
    try renderer.drawOverlaySolid(.{ ndc[0], ndc[3] + dy, ndc[2], ndc[3] }, color);
    try renderer.drawOverlaySolid(.{ ndc[0], ndc[1], ndc[0] + dx, ndc[3] }, color);
    try renderer.drawOverlaySolid(.{ ndc[2] - dx, ndc[1], ndc[2], ndc[3] }, color);
}

/// Draw a "+" glyph centered inside `rect` (pixel-space rect). Two solid
/// crossed rectangles, sized to remain visible at every animation frame.
fn drawPlusGlyph(renderer: *d3d11.Renderer, rect: TileRect, win_w: f32, win_h: f32) !void {
    const short_dim = @min(rect.w, rect.h);
    const arm_len = short_dim * 0.35;
    const arm_thickness = @max(short_dim * 0.08, 2.0);
    const cx = rect.x + rect.w * 0.5;
    const cy = rect.y + rect.h * 0.5;

    const color: [4]f32 = .{ 0.75, 0.78, 0.82, 0.95 };

    // Horizontal arm
    const h_ndc = pixelToNDC(cx - arm_len, cy - arm_thickness * 0.5, arm_len * 2.0, arm_thickness, win_w, win_h);
    try renderer.drawOverlaySolid(h_ndc, color);

    // Vertical arm
    const v_ndc = pixelToNDC(cx - arm_thickness * 0.5, cy - arm_len, arm_thickness, arm_len * 2.0, win_w, win_h);
    try renderer.drawOverlaySolid(v_ndc, color);
}
