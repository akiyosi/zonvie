// visual/split_divider_survives_layer_redraw — moving a vertical split's
// divider must not leave the column it used to occupy on screen.
//
// The divider between two vertical splits is grid 1's own pixel, not a
// window's: under ext_multigrid each window draws as its own layer and the
// root grid keeps only the chrome BETWEEN them. Two things then meet:
//
//   - the core suppresses grid 1's default-background run whenever the main
//     surface has layers (flush.zig, `skip_default_bg = main_has_layers and
//     blur_enabled`; the macOS frontend always passes blur_enabled = true),
//     and a run of spaces emits no glyph quad either — so a grid-1 cell that
//     goes glyph -> space paints nothing at all, and a grid-1 cell that keeps
//     its glyph re-blends it over whatever the surface already held;
//   - since per-grid dirty-row drawing, a layer redraws only the rows that
//     changed, so it no longer scrubs the whole area under it every frame.
//
// A divider move is exactly a glyph -> space transition on grid 1. If nothing
// repaints that column, the old `|` survives and a few width changes leave
// several parallel rules beside the real divider.
//
// Two independent oracles, because they answer different questions:
//
//   - counting vertical rules in the band says whether the artifact is there
//     at all, and does not depend on any other frame being correct;
//   - comparing against a forced full redraw (<C-l>) says whether the
//     incremental path agrees with the path that repaints everything.
//
// Both are relational, so neither needs a golden.

const std = @import("std");
const driver = @import("../../driver.zig");
const fixture = @import("fixture.zig");
const visual = @import("../../visual.zig");
const gui_io = @import("../../gui_io.zig");
const grid_pixels = @import("grid_pixels.zig");

/// The fixture launches the app with this log. It is this scenario's own so
/// a failure can be traced against the run that produced it, without the
/// lines of every other scenario interleaved at overlapping timestamps.
const log_path = "tmp/gui_split_divider.log";

/// The whole window: the divider band is derived below from the capture's
/// own width, and a fixed crop would only add a second size to reason about.
const crop: ?driver.capture.Crop = null;

/// Left-window widths the divider is walked through, in columns. Each is a
/// column the divider occupied and must no longer be painted at; the last is
/// where it ends up. They straddle the final position so the band below
/// contains a leftover from a widening and from a narrowing alike.
const walk_widths_cols = [_]i64{ 43, 38, 41 };
const final_width_cols: i64 = 41;

/// Half-width of the compared band, in cells, around the final divider.
/// Six covers every position in walk_widths_cols with room to spare.
const band_half_cols: f64 = 6;

/// Cursor steps taken after the last divider move. They redraw layers (and
/// nothing else), so the frames that follow are the frames in which only a
/// layer's dirty rows are drawn.
const cursor_keys = [_][]const u8{ "j", "j", "j", "l", "l", "l" };

pub fn run(alloc: std.mem.Allocator) !void {
    // A scenario that builds on fixture.openWithLog still has to make the
    // "no screen capture on this host" case an honest skip rather than a
    // failure from inside captureStable.
    try fixture.requireScreenAccess();
    // A file left by a crashed earlier run would still be appended to.
    std.Io.Dir.cwd().createDirPath(gui_io.io(), "tmp") catch {};
    std.Io.Dir.cwd().deleteFile(gui_io.io(), log_path) catch {};

    var g = try fixture.openWithLog(alloc, log_path);
    defer g.deinit();

    // Grid 1 must carry nothing but the divider column: with a statusline or
    // a ruler on it, a difference inside the band could come from chrome that
    // legitimately changed rather than from the divider.
    try g.exec("execute('set laststatus=0 noruler noshowcmd showtabline=0 scrolloff=0 nowrap cmdheight=1')");

    // Content that differs per line and spans the full width of both panes,
    // so a column left behind by the divider stands out instead of matching
    // whatever is beside it. One letter per line also keeps text out of the
    // rule detector below: a glyph's ink stops inside its own cell, and the
    // next row's letter puts its ink somewhere else.
    try g.exec(
        \\setline(1, map(range(1, 200), {_, i -> printf('%3d %s', i, repeat(nr2char(65 + i % 26), 90))}))
    );

    try g.exec("execute('vsplit')");
    // Pin the divider to a fixed column. `:vsplit` alone halves the CURRENT
    // width and the app autosaves its frame, so the width another scenario
    // left behind decides where a bare vsplit puts the divider.
    try g.exec("execute('vertical resize 40')");
    try g.exec("execute('normal! gg0')");

    // Clear whatever startup left in the command line now, so the <C-l> at
    // the end of the run cannot change that row for a reason of its own.
    try g.remoteSend("<C-l>");

    const total_cols = try g.evalInt("&columns");
    const total_lines = try g.evalInt("&lines");
    const need_cols = final_width_cols + @as(i64, @intFromFloat(band_half_cols)) + 2;
    if (total_cols < need_cols) {
        std.debug.print(
            "[gui] split_divider: window is {d} cols, need at least {d} for the band\n",
            .{ total_cols, need_cols },
        );
        return error.WindowTooNarrow;
    }

    var baseline = try g.captureStable(crop, 8000);
    defer baseline.deinit(alloc);

    // Move the divider, letting each position render as its own settled
    // frame — a batch of resizes coalesced into one flush would only ever
    // dirty grid 1 once and would not exercise the repeated case.
    for (walk_widths_cols) |w| {
        var buf: [64]u8 = undefined;
        const cmd = try std.fmt.bufPrint(&buf, "execute('vertical resize {d}')", .{w});
        try g.exec(cmd);
        var step = try g.captureStable(crop, 8000);
        step.deinit(alloc);
    }

    // Ask Neovim where the divider actually ended up rather than assuming:
    // the band below is centred on it, and a wrong centre would make this
    // scenario compare the wrong columns.
    const width_now = try g.evalInt("winwidth(0)");
    if (width_now != final_width_cols) {
        std.debug.print(
            "[gui] split_divider: left window is {d} cols, expected {d}\n",
            .{ width_now, final_width_cols },
        );
        return error.DividerNotWhereExpected;
    }

    // Cursor-only frames: the divider does not move, grid 1 has nothing to
    // redraw, and only the layer holding the cursor is dirty.
    for (cursor_keys) |k| {
        try g.remoteSend(k);
        gui_io.sleepNs(120 * std.time.ns_per_ms);
    }
    const topline = try g.evalInt("line('w0')");
    if (topline != 1) {
        std.debug.print("[gui] split_divider: cursor steps scrolled the view to line {d}\n", .{topline});
        return error.CursorStepsScrolled;
    }

    var incremental = try g.captureStable(crop, 8000);
    defer incremental.deinit(alloc);

    // Cell size in capture pixels. The grid spans the window, so dividing by
    // the grid size is accurate to well under a cell — far finer than the
    // +/-6 cell band needs — and unlike a logged cell metric it is available
    // on every host the capture layer runs on. The capture includes the
    // title bar, so the row height comes out slightly HIGH, which only makes
    // the rule detector's minimum run length more conservative.
    const img_w = @as(f64, @floatFromInt(incremental.w));
    const img_h = @as(f64, @floatFromInt(incremental.h));
    const cell_w_px = img_w / @as(f64, @floatFromInt(total_cols));
    const cell_h_px = img_h / @as(f64, @floatFromInt(total_lines));
    const divider_x_px = @as(f64, @floatFromInt(final_width_cols)) * cell_w_px;
    const band: visual.Region = .{
        .x0 = (divider_x_px - band_half_cols * cell_w_px) / img_w,
        .x1 = (divider_x_px + (band_half_cols + 1) * cell_w_px) / img_w,
    };
    std.debug.print(
        "[gui] split_divider: capture {d}x{d} grid {d}x{d} cell {d:.2}x{d:.2}px divider at x={d:.0}px band x[{d:.3},{d:.3}]\n",
        .{ incremental.w, incremental.h, total_cols, total_lines, cell_w_px, cell_h_px, divider_x_px, band.x0, band.x1 },
    );

    // Guard against a vacuous pass: if the divider walk never reached the
    // screen, the band would be identical for trivial reasons and every
    // comparison below would hold without guarding anything.
    const moved = visual.regionDiffRatio(baseline, incremental, band, 6);
    if (moved <= 0.0002) {
        std.debug.print(
            "[gui] split_divider: the divider walk did not change the band ({d:.4}) — test would be vacuous\n",
            .{moved},
        );
        return error.DividerDidNotRender;
    }

    // The comparison oracle: <C-l> clears and redraws the screen, so every
    // row of every grid is repainted rather than only the dirty ones.
    try g.remoteSend("<C-l>");
    var redrawn = try g.captureStable(crop, 8000);
    defer redrawn.deinit(alloc);

    const redrawn_moved = visual.regionDiffRatio(baseline, redrawn, band, 6);
    if (redrawn_moved <= 0.0002) {
        std.debug.print(
            "[gui] split_divider: the forced redraw matches the pre-move baseline ({d:.4}) — the capture is not showing the moved divider\n",
            .{redrawn_moved},
        );
        return error.DividerDidNotRender;
    }

    // A second forced redraw, to establish whether the oracle is a fixed
    // point. Grid 1 emits no background run under its glyphs, so a repaint of
    // a root row blends onto what the surface already held; if that
    // accumulates, "full redraw" is not ground truth and the comparison below
    // is measuring the oracle's own drift as well as the incremental path's.
    try g.remoteSend("<C-l>");
    var redrawn_again = try g.captureStable(crop, 8000);
    defer redrawn_again.deinit(alloc);

    // Everything is measured before anything is asserted, so one run reports
    // the whole picture instead of only whichever check trips first.
    const x0_px: u32 = @intFromFloat(@max(0.0, band.x0 * img_w));
    const x1_px: u32 = @intFromFloat(@min(img_w, band.x1 * img_w));
    const rules_incremental = grid_pixels.countVerticalRules("split_divider incremental", incremental, x0_px, x1_px, cell_w_px, cell_h_px);
    const rules_redrawn = grid_pixels.countVerticalRules("split_divider forced redraw", redrawn, x0_px, x1_px, cell_w_px, cell_h_px);
    const oracle_drift = visual.regionDiffRatio(redrawn, redrawn_again, band, 6);
    const band_diff = visual.regionDiffRatio(redrawn, incremental, band, 6);
    const whole_frame = visual.regionDiffRatio(redrawn, incremental, .{}, 6);
    std.debug.print(
        "[gui] split_divider: rules incremental={d} forced_redraw={d} (1 expected); second forced redraw drifted {d:.4}; incremental vs forced redraw band {d:.4} whole frame {d:.4}\n",
        .{ rules_incremental, rules_redrawn, oracle_drift, band_diff, whole_frame },
    );
    // Hand the human both frames, not just the differing one: the diff image
    // says where they disagree, and only the pair says which one is wrong.
    driver.capture.writeImage(alloc, "tmp/split_divider_forced_redraw" ++ driver.capture.image_ext, redrawn) catch {};

    // The artifact itself, independent of any other frame being right.
    if (rules_incremental != 1) {
        std.debug.print(
            "[gui] split_divider: {d} vertical rules beside the divider — the columns it used to occupy are still painted\n",
            .{rules_incremental},
        );
        return error.StaleDividerColumn;
    }
    if (rules_redrawn != 1) {
        std.debug.print(
            "[gui] split_divider: {d} vertical rules survive a forced full redraw\n",
            .{rules_redrawn},
        );
        return error.StaleDividerColumnSurvivesFullRedraw;
    }
    if (oracle_drift > 0.0002) {
        std.debug.print(
            "[gui] split_divider: two forced redraws of the same screen differ ({d:.4}) — repainting a root row is not idempotent\n",
            .{oracle_drift},
        );
        return error.ForcedRedrawNotIdempotent;
    }

    try visual.assertRegionUnchanged(
        alloc,
        "split_divider_survives_layer_redraw",
        redrawn,
        incremental,
        band,
        .{},
    );
}
