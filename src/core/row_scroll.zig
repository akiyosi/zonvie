//! The arithmetic of a GPU row-scroll blit, kept apart from every encoder so
//! it can be checked without a device and answered once for both frontends.
//!
//! The scrolled rectangle is a sub-rectangle of the frontend's back texture at
//! (`origin_x_px`, `origin_y_px`), `width_px` wide: origin zero and the full
//! drawable width for a whole surface, the layer's own origin and width for
//! one layer.
//!
//! The row count the scroll callback reports can outlive the texture -- a
//! window shrink, or a guifont/linespace change growing the cell height before
//! try_resize round-trips -- so `row_end` is clamped to the rows that fit
//! below the origin, and the copy, the vacated band and the dirty expansion
//! all stop at that same clamped row.
//!
//! The damage a blit leaves behind is answered here too: which rows of a layer
//! drawn over it moved, and which of a layer's own rows a full-width band of
//! root damage overpaints.

const std = @import("std");

/// Layout must match `zonvie_row_scroll_plan` in include/zonvie_core.h.
pub const Plan = extern struct {
    /// The scrolled rectangle's left edge, which the encoder copies at.
    origin_x_px: i32,
    /// The top edge, already folded into every Y below; `localClearBand` takes
    /// it back out for callers drawing under a layer transform.
    origin_y_px: i32,
    src_y_px: i32,
    dst_y_px: i32,
    copy_w_px: i32,
    copy_h_px: i32,
    /// The band the copy vacated, which the caller clears to the background.
    clear_top_px: i32,
    clear_bottom_px: i32,
    /// `row_end` clamped to the texture: where the blit stopped.
    clamped_row_end: u32,
    /// Rows the caller must redraw: the band vacated by an accumulated delta
    /// D, plus another D for rows an intermediate scroll step copied and a
    /// later one overwrote, which are stale in the back buffer. Half-open and
    /// grid-local -- rows are numbered within the scroll region, which
    /// `origin_y_px` moves the pixels of but does not renumber.
    dirty_row_start: u32,
    dirty_row_end: u32,
};

// The header declares the same eleven fields in the same order, every one of
// them four bytes, so the struct is flat and unpadded. A field that changed
// width here would still compile and would still be read at the header's
// offsets on the other side, silently. Pin it.
comptime {
    if (@sizeOf(Plan) != 11 * 4) @compileError("zonvie_row_scroll_plan layout drifted from the header");
    if (@offsetOf(Plan, "origin_x_px") != 0) @compileError("field order drifted from the header");
    if (@offsetOf(Plan, "clamped_row_end") != 8 * 4) @compileError("field order drifted from the header");
    if (@offsetOf(Plan, "dirty_row_end") != 10 * 4) @compileError("field order drifted from the header");
}

pub const ClearBand = struct { top_px: i32, bottom_px: i32 };

pub fn make(
    row_start: u32,
    row_end: u32,
    rows_delta: i32,
    origin_x_px: i32,
    origin_y_px: i32,
    width_px: i32,
    tex_w_px: i32,
    tex_h_px: i32,
    row_h_px: i32,
) ?Plan {
    if (row_h_px <= 0 or width_px <= 0 or origin_x_px < 0 or origin_y_px < 0) return null;
    const h: i64 = row_h_px;
    const oy: i64 = origin_y_px;
    const start: i64 = row_start;
    const shift: i64 = @intCast(@abs(@as(i64, rows_delta)));
    // Only the rows below the origin belong to this rectangle.
    const tex_max_rows = @max(0, @divTrunc(@as(i64, tex_h_px) - oy, h));
    const clamped_row_end = @min(@as(i64, row_end), tex_max_rows);
    const region_rows = clamped_row_end - start;
    if (shift == 0 or shift >= region_rows) return null;

    const copy_w = @min(@as(i64, width_px), @as(i64, tex_w_px) - @as(i64, origin_x_px));
    if (copy_w <= 0) return null;
    const copy_h = (region_rows - shift) * h;
    if (copy_h <= 0) return null;

    const src_y = oy + (if (rows_delta > 0) start + shift else start) * h;
    const dst_y = oy + (if (rows_delta > 0) start else start + shift) * h;

    // Second clamp: a region low in the texture runs off the end from src or
    // dst even with a within-bounds row count, and the rectangle's own bottom
    // edge binds as well as the texture's.
    const region_bottom = oy + clamped_row_end * h;
    const safe_copy_h = @min(copy_h, @min(@as(i64, tex_h_px), region_bottom) - @max(src_y, dst_y));
    if (safe_copy_h <= 0) return null;

    var clear_top: i64 = undefined;
    var clear_bottom: i64 = undefined;
    var dirty_start: i64 = undefined;
    var dirty_end: i64 = undefined;
    if (rows_delta > 0) {
        // Scroll down: vacated at the bottom, intermediate rows above.
        clear_top = oy + (clamped_row_end - shift) * h;
        clear_bottom = region_bottom;
        dirty_start = @max(start, clamped_row_end - 2 * shift);
        dirty_end = clamped_row_end;
    } else {
        // Scroll up: vacated at the top, intermediate rows below.
        clear_top = oy + start * h;
        clear_bottom = oy + (start + shift) * h;
        dirty_start = start;
        dirty_end = @min(clamped_row_end, start + 2 * shift);
    }

    return .{
        .origin_x_px = origin_x_px,
        .origin_y_px = origin_y_px,
        .src_y_px = @intCast(src_y),
        .dst_y_px = @intCast(dst_y),
        .copy_w_px = @intCast(copy_w),
        .copy_h_px = @intCast(safe_copy_h),
        .clear_top_px = @intCast(clear_top),
        .clear_bottom_px = @intCast(clear_bottom),
        .clamped_row_end = @intCast(clamped_row_end),
        .dirty_row_start = @intCast(dirty_start),
        .dirty_row_end = @intCast(dirty_end),
    };
}

/// The vacated band relative to `origin_y_px`, for callers drawing under a
/// layer transform, whose pixel space starts at the layer origin.
pub fn localClearBand(p: Plan) ClearBand {
    return .{
        .top_px = p.clear_top_px - p.origin_y_px,
        .bottom_px = p.clear_bottom_px - p.origin_y_px,
    };
}

/// The rows to redraw when the blit never ran: nothing was shifted, so every
/// row of the scroll region is stale and the core will not re-send them (it
/// vacates only the band, assuming the frontend shifts the rest). Half-open
/// and grid-local like `dirty_row_start`/`dirty_row_end`, still stopping at
/// the rows that fit below `origin_y_px`. Null when nothing of the region is
/// inside the texture.
pub fn dirtyRowsWithoutBlit(
    row_start: u32,
    row_end: u32,
    origin_y_px: i32,
    tex_h_px: i32,
    row_h_px: i32,
) ?[2]u32 {
    if (row_h_px <= 0) return null;
    const tex_max_rows = @max(0, @divTrunc(@as(i64, tex_h_px) - @as(i64, origin_y_px), @as(i64, row_h_px)));
    const clamped_row_end = @min(@as(i64, row_end), tex_max_rows);
    if (clamped_row_end <= @as(i64, row_start)) return null;
    return .{ row_start, @intCast(clamped_row_end) };
}

/// Every pixel the blit rewrites: the copy plus the band it vacated. Half-open
/// on all four edges, so rectangles that only touch do not intersect.
pub const Rect = struct { left: i32, top: i32, right: i32, bottom: i32 };

pub fn blitRect(p: Plan) Rect {
    return .{
        .left = p.origin_x_px,
        .top = @min(@min(p.src_y_px, p.dst_y_px), p.clear_top_px),
        .right = p.origin_x_px + p.copy_w_px,
        .bottom = @max(@max(p.src_y_px, p.dst_y_px) + p.copy_h_px, p.clear_bottom_px),
    };
}

/// Inclusive row ranges, each absent when its own intersection is empty.
pub const OverBlitRows = struct {
    /// The covering layer's own rows that meet the blit rectangle.
    above: ?[2]u32 = null,
    /// The scrolled layer's rows under them.
    under: ?[2]u32 = null,
    /// Those rows shifted back by the delta: where the covering pixels came
    /// from before the copy dragged them.
    shifted: ?[2]u32 = null,
};

/// The damage an accepted per-layer blit does to a layer drawn on top of it.
///
/// The blit rewrites every pixel of its rectangle R. For a layer M above it:
/// M's own pixels inside R moved, so every row of M meeting R is redrawn; and
/// what they covered moved with them, so the rows of the scrolled layer they
/// were dragged into -- the same rows shifted by -`rows_delta`, plus the
/// unshifted ones to kill boundary off-by-ones -- are redrawn from the
/// scrolled layer's vertices. Both ranges come from a pixel intersection, so a
/// layer off the cell grid gets both rows a boundary straddles.
///
/// Only layers ABOVE need this: R lies inside the scrolled layer's own rect,
/// and a marked layer repaints after it, which is the screen order.
///
/// Null when the covering layer's rectangle does not meet the blit's.
pub fn overBlitRows(
    p: Plan,
    rows_delta: i32,
    above_left_px: i32,
    above_top_px: i32,
    above_rows: u32,
    above_cols: u32,
    cell_w_px: i32,
    row_h_px: i32,
) ?OverBlitRows {
    if (row_h_px <= 0 or above_rows == 0 or above_cols == 0) return null;
    const h: i64 = row_h_px;
    const oy: i64 = p.origin_y_px;
    const r = blitRect(p);
    // r.top is exactly origin_y_px + row_start * row_h.
    const region_first = @divTrunc(@as(i64, r.top) - oy, h);
    const region_last = @as(i64, p.clamped_row_end) - 1;
    if (region_last < region_first) return null;

    const a_top: i64 = above_top_px;
    const a_left: i64 = above_left_px;
    const a_right = a_left + @as(i64, above_cols) * @as(i64, cell_w_px);
    const a_bottom = a_top + @as(i64, above_rows) * h;
    if (a_left >= @as(i64, r.right) or a_right <= @as(i64, r.left)) return null;
    if (a_top >= @as(i64, r.bottom) or a_bottom <= @as(i64, r.top)) return null;

    const overlap_top = @max(a_top, @as(i64, r.top));
    const overlap_bottom = @min(a_bottom, @as(i64, r.bottom));

    var out: OverBlitRows = .{};
    const a_first = @max(0, @divTrunc(overlap_top - a_top, h));
    const a_last = @min(@as(i64, above_rows) - 1, @divTrunc(overlap_bottom - 1 - a_top, h));
    if (a_last >= a_first) out.above = .{ @intCast(a_first), @intCast(a_last) };

    const under_first = @max(region_first, @divTrunc(overlap_top - oy, h));
    const under_last = @min(region_last, @divTrunc(overlap_bottom - 1 - oy, h));
    if (under_last < under_first) return out;
    out.under = .{ @intCast(under_first), @intCast(under_last) };
    const shifted_first = @max(region_first, under_first - @as(i64, rows_delta));
    const shifted_last = @min(region_last, under_last - @as(i64, rows_delta));
    if (shifted_last >= shifted_first) out.shifted = .{ @intCast(shifted_first), @intCast(shifted_last) };
    return out;
}

/// Which of a layer's own rows a full-width damage band overpaints. The band
/// spans the whole surface width, so there is no X test; a layer need not be
/// cell-aligned, so one root row can straddle two of its rows. Inclusive.
pub fn bandLayerRows(
    band_top_px: i32,
    band_bottom_px: i32,
    origin_y_px: i32,
    layer_rows: u32,
    row_h_px: i32,
) ?[2]u32 {
    if (row_h_px <= 0 or layer_rows == 0) return null;
    const h: i64 = row_h_px;
    const oy: i64 = origin_y_px;
    if (@as(i64, band_bottom_px) <= oy) return null;
    const first = @max(0, @divTrunc(@as(i64, band_top_px) - oy, h));
    const last = @min(@as(i64, layer_rows) - 1, @divTrunc(@as(i64, band_bottom_px) - 1 - oy, h));
    if (last < first) return null;
    return .{ @intCast(first), @intCast(last) };
}

// ---------------------------------------------------------------------------
// Tests. Merged from the two implementations this replaced:
// macos/Tests/RowScrollBlitPlanTests.swift and the RowScrollBlitPlan cases in
// windows/render_pipeline_helpers_test.zig.

const testing = std.testing;

/// One row height, one texture, so each case reads as rows.
const row_h = 10;
const tex_w = 100;
const tex_h = 440; // 44 rows

fn plan44(row_start: u32, row_end: u32, rows_delta: i32) ?Plan {
    return make(row_start, row_end, rows_delta, 0, 0, tex_w, tex_w, tex_h, row_h);
}

test "scroll down reads below and writes above, vacating the bottom" {
    const p = plan44(0, 40, 3).?;
    try testing.expectEqual(@as(i32, 30), p.src_y_px);
    try testing.expectEqual(@as(i32, 0), p.dst_y_px);
    try testing.expectEqual(@as(i32, 370), p.copy_h_px); // (40 - 3) rows
    try testing.expectEqual(@as(i32, 370), p.clear_top_px);
    try testing.expectEqual(@as(i32, 400), p.clear_bottom_px);
    try testing.expectEqual(@as(u32, 40), p.clamped_row_end);
    // Vacated 3 rows plus another 3 an intermediate step overwrote.
    try testing.expectEqual(@as(u32, 34), p.dirty_row_start);
    try testing.expectEqual(@as(u32, 40), p.dirty_row_end);
}

test "scroll up is the mirror image" {
    const p = plan44(0, 40, -3).?;
    try testing.expectEqual(@as(i32, 0), p.src_y_px);
    try testing.expectEqual(@as(i32, 30), p.dst_y_px);
    try testing.expectEqual(@as(i32, 370), p.copy_h_px);
    try testing.expectEqual(@as(i32, 0), p.clear_top_px);
    try testing.expectEqual(@as(i32, 30), p.clear_bottom_px);
    try testing.expectEqual(@as(u32, 0), p.dirty_row_start);
    try testing.expectEqual(@as(u32, 6), p.dirty_row_end);
}

test "a region below row 0 never expands above its own start" {
    const p = plan44(5, 40, -3).?;
    try testing.expectEqual(@as(i32, 50), p.src_y_px);
    try testing.expectEqual(@as(i32, 80), p.dst_y_px);
    try testing.expectEqual(@as(u32, 5), p.dirty_row_start);
    try testing.expectEqual(@as(u32, 11), p.dirty_row_end);

    const down = plan44(5, 40, 3).?;
    try testing.expectEqual(@as(u32, 34), down.dirty_row_start);
    try testing.expectEqual(@as(u32, 40), down.dirty_row_end);
}

test "a reported row count past the drawable clamps copy, band and dirty rows alike" {
    // The regression 8a9cba0 fixed: 45 rows reported, 44 fit. Everything must
    // stop at the same clamped row, or part of the band the blit cleared is
    // never redrawn and stays blank until the next full redraw.
    const p = plan44(0, 45, 2).?;
    try testing.expectEqual(@as(u32, 44), p.clamped_row_end);
    try testing.expectEqual(@as(i32, 420), p.clear_top_px);
    try testing.expectEqual(@as(i32, 440), p.clear_bottom_px);
    try testing.expectEqual(@as(u32, 40), p.dirty_row_start);
    try testing.expectEqual(@as(u32, 44), p.dirty_row_end);
    try testing.expect(p.dst_y_px + p.copy_h_px <= tex_h);

    // Larger overshoot.
    const q = plan44(0, 50, 2).?;
    try testing.expectEqual(@as(u32, 44), q.clamped_row_end);
    try testing.expectEqual(@as(i32, 440), q.clear_bottom_px);
    try testing.expect(q.dst_y_px + q.copy_h_px <= tex_h);
}

test "cases that must produce no plan" {
    try testing.expect(plan44(0, 40, 0) == null); // no shift
    try testing.expect(plan44(0, 3, 3) == null); // shift fills the region
    try testing.expect(plan44(0, 3, 5) == null); // shift exceeds the region
    try testing.expect(make(0, 40, 3, 0, 0, tex_w, tex_w, tex_h, 0) == null); // no row height
    try testing.expect(make(0, 40, 3, 0, 0, 0, tex_w, tex_h, row_h) == null); // no width
    try testing.expect(make(0, 40, 3, -1, 0, tex_w, tex_w, tex_h, row_h) == null); // negative origin
    try testing.expect(make(0, 40, 3, 0, -1, tex_w, tex_w, tex_h, row_h) == null);
    // A texture too short to hold the region start.
    try testing.expect(make(0, 40, 3, 0, 0, tex_w, tex_w, 10, row_h) == null);
}

test "the copy width is the caller's, bounded by the texture" {
    const wide = make(0, 40, 3, 0, 0, 200, tex_w, tex_h, row_h).?;
    try testing.expectEqual(@as(i32, tex_w), wide.copy_w_px);
    const narrow = make(0, 40, 3, 0, 0, 40, tex_w, tex_h, row_h).?;
    try testing.expectEqual(@as(i32, 40), narrow.copy_w_px);
}

test "every plan keeps its copy inside the texture and its band inside the dirty rows" {
    // The two invariants, swept over every small geometry.
    var rows: u32 = 2;
    while (rows <= 12) : (rows += 1) {
        var start: u32 = 0;
        while (start < 4) : (start += 1) {
            var delta: i32 = -4;
            while (delta <= 4) : (delta += 1) {
                var th: i32 = 20;
                while (th <= 140) : (th += 20) {
                    const p = make(start, start + rows, delta, 0, 0, tex_w, tex_w, th, row_h) orelse continue;
                    try testing.expect(p.src_y_px >= 0);
                    try testing.expect(p.dst_y_px >= 0);
                    try testing.expect(p.src_y_px + p.copy_h_px <= th);
                    try testing.expect(p.dst_y_px + p.copy_h_px <= th);
                    try testing.expect(p.copy_w_px > 0);
                    // The vacated band lies inside the rows the caller redraws.
                    const band_first = @divTrunc(p.clear_top_px, row_h);
                    const band_last = @divTrunc(p.clear_bottom_px - 1, row_h);
                    try testing.expect(band_first >= @as(i32, @intCast(p.dirty_row_start)));
                    try testing.expect(band_last < @as(i32, @intCast(p.dirty_row_end)));
                }
            }
        }
    }
}

test "without a blit the whole region is stale, still stopping at the texture" {
    const r = dirtyRowsWithoutBlit(0, 40, 0, tex_h, row_h).?;
    try testing.expectEqual([2]u32{ 0, 40 }, r);
    const clamped = dirtyRowsWithoutBlit(0, 50, 0, tex_h, row_h).?;
    try testing.expectEqual([2]u32{ 0, 44 }, clamped);
    const offset = dirtyRowsWithoutBlit(5, 40, 0, tex_h, row_h).?;
    try testing.expectEqual([2]u32{ 5, 40 }, offset);
    // Nothing of the region is inside the texture.
    try testing.expect(dirtyRowsWithoutBlit(0, 40, 0, 0, row_h) == null);
    try testing.expect(dirtyRowsWithoutBlit(10, 40, 0, 50, row_h) == null);
    try testing.expect(dirtyRowsWithoutBlit(0, 40, 0, tex_h, 0) == null);
}

test "a layer's origin slides every pixel but must not renumber its rows" {
    const p = make(0, 10, 2, 30, 100, 200, 400, 300, row_h).?;
    try testing.expectEqual(@as(i32, 30), p.origin_x_px);
    try testing.expectEqual(@as(i32, 100), p.origin_y_px);
    try testing.expectEqual(@as(i32, 120), p.src_y_px); // origin + 2 rows
    try testing.expectEqual(@as(i32, 100), p.dst_y_px);
    try testing.expectEqual(@as(i32, 180), p.clear_top_px);
    try testing.expectEqual(@as(i32, 200), p.clear_bottom_px);
    // Grid-local: the origin moves the pixels, not the row numbering.
    try testing.expectEqual(@as(u32, 6), p.dirty_row_start);
    try testing.expectEqual(@as(u32, 10), p.dirty_row_end);
    // Under a layer transform the caller's pixel space starts at the origin.
    const band = localClearBand(p);
    try testing.expectEqual(@as(i32, 80), band.top_px);
    try testing.expectEqual(@as(i32, 100), band.bottom_px);
}

test "a layer copies its own width, clamped by what is left of the texture" {
    const inside = make(0, 10, 2, 30, 0, 100, 400, 300, row_h).?;
    try testing.expectEqual(@as(i32, 100), inside.copy_w_px);
    const clipped = make(0, 10, 2, 350, 0, 100, 400, 300, row_h).?;
    try testing.expectEqual(@as(i32, 50), clipped.copy_w_px);
    // A left edge at or past the right edge has nothing to copy.
    try testing.expect(make(0, 10, 2, 400, 0, 100, 400, 300, row_h) == null);
}

test "a layer past the bottom of the texture has no rows at all" {
    try testing.expect(make(0, 10, 2, 0, 300, 100, 400, 300, row_h) == null);
    try testing.expect(dirtyRowsWithoutBlit(0, 10, 300, 300, row_h) == null);
}

test "a layer low in the texture clamps copy, dirty rows and fallback alike" {
    // Origin at 250 in a 300-tall texture leaves 5 rows; 10 are reported.
    const p = make(0, 10, 2, 0, 250, 100, 400, 300, row_h).?;
    try testing.expectEqual(@as(u32, 5), p.clamped_row_end);
    try testing.expect(p.src_y_px + p.copy_h_px <= 300);
    try testing.expect(p.dst_y_px + p.copy_h_px <= 300);
    try testing.expectEqual(@as(i32, 280), p.clear_top_px);
    try testing.expectEqual(@as(i32, 300), p.clear_bottom_px);
    try testing.expectEqual(@as(u32, 1), p.dirty_row_start);
    try testing.expectEqual(@as(u32, 5), p.dirty_row_end);
    const fallback = dirtyRowsWithoutBlit(0, 10, 250, 300, row_h).?;
    try testing.expectEqual([2]u32{ 0, 5 }, fallback);
}

// Over-blit damage. Merged from the Windows `rowsOverBlit` cases; the macOS
// copy this replaced had none of its own.

/// A layer at y=100, 20 rows of 20px, scrolled down by 3: the blit rewrites
/// its rows 0..20, pixels 100..500 of a 400px-wide rectangle.
fn overBlitBase() Plan {
    return make(0, 20, 3, 0, 100, 400, 800, 44 * 20, 20).?;
}

test "the blit rectangle spans the copy and the band it vacated" {
    const r = blitRect(overBlitBase());
    try testing.expectEqual(@as(i32, 0), r.left);
    try testing.expectEqual(@as(i32, 100), r.top);
    try testing.expectEqual(@as(i32, 400), r.right);
    try testing.expectEqual(@as(i32, 500), r.bottom);
}

test "a float over the blit marks its own rows, the rows under it and their source" {
    const p = overBlitBase();
    // A float at y=210, 4 rows tall, x=100..200: straddles the band.
    const got = overBlitRows(p, 3, 100, 210, 4, 10, 10, 20).?;
    try testing.expectEqual([2]u32{ 0, 3 }, got.above.?);
    try testing.expectEqual([2]u32{ 5, 9 }, got.under.?);
    // Shifted back by the delta, never forward.
    try testing.expectEqual([2]u32{ 2, 6 }, got.shifted.?);
}

test "rows over a blit clamp to the covering layer and to the scroll region" {
    const p = overBlitBase();

    // Starts above the blit rectangle: the covering layer's first marked row
    // is the one the rectangle's top edge lands in, not its own row 0.
    const high = overBlitRows(p, 3, 0, 60, 4, 40, 10, 20).?;
    try testing.expectEqual([2]u32{ 2, 3 }, high.above.?);

    // Taller than the rectangle: both ranges stop at the region's last row.
    const tall = overBlitRows(p, 3, 0, 100, 30, 40, 10, 20).?;
    try testing.expectEqual([2]u32{ 0, 19 }, tall.above.?);
    try testing.expectEqual([2]u32{ 0, 19 }, tall.under.?);
    try testing.expectEqual([2]u32{ 0, 16 }, tall.shifted.?);
}

test "a float that misses the blit rectangle marks nothing" {
    const p = overBlitBase();
    // Entirely to the right of the copy.
    try testing.expect(overBlitRows(p, 3, 400, 210, 4, 10, 10, 20) == null);
    // Entirely below it.
    try testing.expect(overBlitRows(p, 3, 100, 500, 4, 10, 10, 20) == null);
    // Empty covering layer.
    try testing.expect(overBlitRows(p, 3, 100, 210, 0, 10, 10, 20) == null);
    try testing.expect(overBlitRows(p, 3, 100, 210, 4, 0, 10, 20) == null);
    try testing.expect(overBlitRows(p, 3, 100, 210, 4, 10, 10, 0) == null);
}

test "every over-blit range stays inside the layer it names" {
    const p = overBlitBase();
    var top: i32 = 0;
    while (top <= 600) : (top += 7) {
        var rows: u32 = 1;
        while (rows <= 8) : (rows += 1) {
            const over = overBlitRows(p, 3, 0, top, rows, 40, 10, 20) orelse continue;
            if (over.above) |a| {
                try testing.expect(a[0] <= a[1]);
                try testing.expect(a[1] < rows);
            }
            const region_last: u32 = p.clamped_row_end - 1;
            if (over.under) |u| {
                try testing.expect(u[0] <= u[1]);
                try testing.expect(u[1] <= region_last);
            }
            if (over.shifted) |s| {
                try testing.expect(s[0] <= s[1]);
                try testing.expect(s[1] <= region_last);
            }
        }
    }
}

test "a root dirty band marks the layer rows it overpaints" {
    // Cell-aligned: one root row lands on exactly one layer row.
    try testing.expectEqual([2]u32{ 5, 5 }, bandLayerRows(200, 220, 100, 10, 20).?);
    // Off the cell grid: the same band straddles two.
    try testing.expectEqual([2]u32{ 4, 5 }, bandLayerRows(200, 220, 110, 10, 20).?);
    // Overlapping the layer's top edge from above.
    try testing.expectEqual([2]u32{ 0, 0 }, bandLayerRows(90, 110, 100, 10, 20).?);
    // Entirely above the layer.
    try testing.expect(bandLayerRows(0, 20, 100, 10, 20) == null);
    // Entirely below it.
    try testing.expect(bandLayerRows(400, 420, 100, 2, 20) == null);
    // Degenerate geometry.
    try testing.expect(bandLayerRows(200, 220, 100, 0, 20) == null);
    try testing.expect(bandLayerRows(200, 220, 100, 10, 0) == null);
}

test "a band never names a row outside the layer it covers" {
    var top: i32 = -60;
    while (top <= 400) : (top += 7) {
        var height: i32 = 1;
        while (height <= 90) : (height += 11) {
            var rows: u32 = 1;
            while (rows <= 8) : (rows += 1) {
                const r = bandLayerRows(top, top + height, 100, rows, 20) orelse continue;
                try testing.expect(r[0] <= r[1]);
                try testing.expect(r[1] < rows);
                // The band really does reach the first row it names.
                const first_row_bottom = 100 + (@as(i32, @intCast(r[0])) + 1) * 20;
                try testing.expect(top < first_row_bottom);
            }
        }
    }
}
