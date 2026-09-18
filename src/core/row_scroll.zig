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
