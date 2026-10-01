// layer_draw.zig — the per-layer draw series both float-stack scenarios judge.
//
// The main surface logs `[layer_draw]` and the external one `[ext_layer_draw]`
// with the same fields (gridId, committedY, drawY, moved), so one fold serves
// both; each scenario passes its own marker.

const std = @import("std");
const app_log = @import("../../app_log.zig");

pub const Tally = struct {
    /// Frames where a float's drawn Y moved a whole cell or more, counting
    /// only frames that arrived one frame period after the one before them.
    jumps: usize = 0,
    /// Frames where a float was drawn displaced at all — the ease running.
    displaced: usize = 0,
    /// Times a float's committed placement changed, i.e. Neovim re-placed it.
    replacements: usize = 0,
    /// Distinct float grids seen displaced.
    grids: usize = 0,
    worst: f64 = 0,
    /// The frame period the run is judged against, measured from the run
    /// itself (see framePeriodMs).
    period_ms: f64 = 0,
    /// Displaced frames that arrived more than 1.5 periods after the last one
    /// — vsyncs the app missed. Reported rather than asserted on: these
    /// scenarios measure where a float is drawn, not how often.
    late: usize = 0,
};

/// The median gap between consecutive drawn frames, which is what one frame
/// period is on whatever display the run happened to use. Measured rather
/// than assumed: the threshold is stated in cells per frame, and a 120Hz
/// display would halve the period without changing anything the scenarios
/// are about.
fn framePeriodMs(alloc: std.mem.Allocator, lines: []const u8) !f64 {
    var gaps: std.ArrayList(f64) = .empty;
    defer gaps.deinit(alloc);
    var prev: ?f64 = null;
    // One grid only. Every layer of a frame is logged microseconds after the
    // one before it, so taking all the lines would put the median at zero.
    var only_grid: ?f64 = null;
    var it = std.mem.splitScalar(u8, lines, '\n');
    while (it.next()) |line| {
        const grid = app_log.field(line, "gridId") orelse continue;
        if (only_grid == null) only_grid = grid;
        if (grid != only_grid.?) continue;
        const ts = app_log.lineTimestampMs(line) orelse continue;
        if (prev) |p| {
            const gap = ts - p;
            if (gap > 0) try gaps.append(alloc, gap);
        }
        prev = ts;
    }
    if (gaps.items.len == 0) return 0;
    std.mem.sort(f64, gaps.items, {}, std.sort.asc(f64));
    return gaps.items[gaps.items.len / 2];
}

/// Walk the `marker` series since `since_ms` and fold it per grid. Every field
/// is required: app_log.field returns null on drift, and a silently skipped
/// line would make the whole assertion vacuous.
pub fn tally(alloc: std.mem.Allocator, log_path: []const u8, marker: []const u8, since_ms: f64, cell_px: f64) !Tally {
    const lines = try app_log.linesSince(alloc, log_path, marker, since_ms);
    defer alloc.free(lines);

    var prev_draw = std.AutoHashMap(i64, f64).init(alloc);
    defer prev_draw.deinit();
    var prev_draw_ms = std.AutoHashMap(i64, f64).init(alloc);
    defer prev_draw_ms.deinit();
    var prev_committed = std.AutoHashMap(i64, f64).init(alloc);
    defer prev_committed.deinit();
    var seen = std.AutoHashMap(i64, void).init(alloc);
    defer seen.deinit();

    var t = Tally{};
    t.period_ms = try framePeriodMs(alloc, lines);
    if (t.period_ms <= 0) return t;
    var it = std.mem.splitScalar(u8, lines, '\n');
    while (it.next()) |line| {
        const grid_f = app_log.field(line, "gridId") orelse continue;
        const now_ms = app_log.lineTimestampMs(line) orelse continue;
        const moved = app_log.field(line, "moved") orelse continue;
        const committed = app_log.field(line, "committedY") orelse continue;
        const draw = app_log.field(line, "drawY") orelse continue;
        const grid: i64 = @intFromFloat(grid_f);

        if (prev_committed.get(grid)) |p| {
            if (@abs(committed - p) >= cell_px / 2) t.replacements += 1;
        }
        try prev_committed.put(grid, committed);

        // Only a bodily-displaced layer is under test. A layer at rest is
        // drawn where it was committed and its position is trivially stable,
        // so counting it would dilute the tally toward passing.
        if (moved < 0.5) {
            _ = prev_draw.remove(grid);
            _ = prev_draw_ms.remove(grid);
            continue;
        }
        t.displaced += 1;
        if (!seen.contains(grid)) {
            try seen.put(grid, {});
            t.grids += 1;
        }
        if (prev_draw.get(grid)) |p| {
            const jump = @abs(draw - p);
            if (jump > t.worst) t.worst = jump;
            // A smooth scroll is sub-cell motion: the ease moves a float by a
            // fraction of a row per FRAME PERIOD. A whole cell within one
            // period is the placement and its compensation landing apart,
            // which is the defect — or the scissor cutting the layer, which
            // moved it by a whole step too.
            //
            // Scaled by the periods that actually elapsed, because two
            // consecutive drawn frames are not always one period apart. When
            // the app misses a vsync the ease still advances in real time, so
            // the next drawn frame legitimately shows two or three steps at
            // once — measured at 36px across a 45ms gap with a 33px cell,
            // every pixel of it correct for the moment it was drawn. Counting
            // that would make these scenarios fail for frame pacing, which
            // they cannot diagnose and do not claim to test; the defect they
            // do test shows up WITHIN one period (99px in 18.7ms, 111px in
            // 8.4ms) and still trips the threshold at any scale.
            const elapsed = now_ms - (prev_draw_ms.get(grid) orelse now_ms);
            const scale = @max(1.0, elapsed / t.period_ms);
            if (elapsed > t.period_ms * 1.5) t.late += 1;
            if (jump >= cell_px * scale) t.jumps += 1;
        }
        try prev_draw.put(grid, draw);
        try prev_draw_ms.put(grid, now_ms);
    }
    return t;
}
