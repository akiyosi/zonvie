// visual/statusline_survives_layer_redraw — a statusline that gets shorter
// must not leave its old tail on screen.
//
// Same class as split_divider_survives_layer_redraw, different chrome. Under
// ext_multigrid the statuslines belong to grid 1, not to any window's grid,
// and the core suppresses grid 1's default-background run once the main
// surface has layers (flush.zig, `skip_default_bg = main_has_layers and
// blur_enabled`). A run of spaces emits no glyph quad either, so a grid-1
// cell that goes glyph -> space paints nothing — and since per-grid dirty-row
// drawing, no layer sweeps over that row afterwards to erase what was there.
//
// Shortening a statusline is that transition: the cursor moves from a long
// line to a short one, `%c` drops from three digits to one, and the two cells
// the ruler no longer occupies must come back as background.
//
// The oracle is the same forced full redraw (<C-l>), which repaints every row
// of every grid instead of only the dirty ones. It is only ground truth while
// it is a fixed point, so the scenario takes a second one and checks the two
// agree before comparing anything against them — repainting a root row blends
// over what the surface already held, and split_divider_survives_layer_redraw
// shows that this does not always converge.

const std = @import("std");
const driver = @import("../../driver.zig");
const fixture = @import("fixture.zig");
const visual = @import("../../visual.zig");
const gui_io = @import("../../gui_io.zig");
const grid_pixels = @import("grid_pixels.zig");

/// This scenario's own app log, so a failure can be traced against the run
/// that produced it rather than against every scenario sharing one file.
const log_path = "tmp/gui_statusline_chrome.log";

const crop: ?driver.capture.Crop = null;

/// How much of a row to leave out at each edge of the compared band, so
/// rounding in the row arithmetic cannot pull a neighbouring row in. A
/// statusline that failed to shrink leaves whole cells behind, so trimming a
/// fraction of a row costs the scenario no sensitivity.
const row_inset_rows: f64 = 0.15;

/// Cursor steps, each settled on its own. The buffer alternates long and
/// short lines, so every step swings the ruler's width; the last one lands
/// on a short line, leaving the widest statusline of the run behind it.
const cursor_steps = [_][]const u8{
    "execute('normal! 5G$')",
    "execute('normal! 6G$')",
    "execute('normal! 7G$')",
    "execute('normal! 8G0')",
};

pub fn run(alloc: std.mem.Allocator) !void {
    try fixture.requireScreenAccess();
    std.Io.Dir.cwd().createDirPath(gui_io.io(), "tmp") catch {};
    std.Io.Dir.cwd().deleteFile(gui_io.io(), log_path) catch {};

    var g = try fixture.openWithLog(alloc, log_path);
    defer g.deinit();

    // laststatus=2 is the default in current Neovim, but state it: the point
    // of the scenario is that every window has a statusline, and inheriting
    // that from whatever config the host happens to load would make the
    // scenario silently degrade into one with no chrome to test.
    try g.exec("execute('set laststatus=2 noshowcmd showtabline=0 scrolloff=0 nowrap cmdheight=1')");
    // A statusline whose width follows the cursor column, so a move from a
    // long line to a short one shortens it by several cells.
    try g.exec("execute(\"let &statusline='%f %l,%c %P'\")");

    // Odd lines long, even lines short: `$` on consecutive lines swings the
    // column between three digits and one.
    try g.exec(
        \\setline(1, map(range(1, 200), {_, i -> i % 2 == 1 ? printf('%d %s', i, repeat('L', 120)) : printf('%d', i)}))
    );

    // Two vertical splits, so three statuslines share the row and the one
    // that changes sits between two that must not.
    try g.exec("execute('vsplit')");
    try g.exec("execute('vsplit')");
    try g.exec("execute('wincmd =')");
    try g.exec("execute('normal! gg0')");

    // Clear whatever startup left in the command line, so the <C-l> below
    // cannot change that row for a reason of its own.
    try g.remoteSend("<C-l>");

    var baseline = try g.captureStable(crop, 8000);
    defer baseline.deinit(alloc);

    for (cursor_steps) |step| {
        try g.exec(step);
        var img = try g.captureStable(crop, 8000);
        img.deinit(alloc);
    }

    // The steps must have stayed inside the visible screen: a vertical scroll
    // would redraw the whole layer and repaint the row underneath for reasons
    // that have nothing to do with the statusline.
    const topline = try g.evalInt("line('w0')");
    if (topline != 1) {
        std.debug.print("[gui] statusline_chrome: cursor steps scrolled the view to line {d}\n", .{topline});
        return error.CursorStepsScrolled;
    }

    var incremental = try g.captureStable(crop, 8000);
    defer incremental.deinit(alloc);

    // The statusline row, in capture pixels, from the capture itself and the
    // grid size rather than a logged metric — the only cell metric the app
    // logs is macOS-specific, and this scenario runs wherever capture does.
    // The capture includes the title bar, so the grid's first row is found by
    // scanning; from there the grid fills the rest of the window.
    //
    // The band is ONE row, not the bottom of the window: with vertical splits
    // the window separators run down to the row above the statusline, and a
    // looser band would report their pixels as a statusline difference.
    const total_lines = try g.evalInt("&lines");
    const img_h = @as(f64, @floatFromInt(incremental.h));
    const bg = grid_pixels.modalLuma(incremental, 0, incremental.w, 0, incremental.h);
    const grid_top_px = @as(f64, @floatFromInt(grid_pixels.firstContentRow(incremental, bg)));
    const cell_h_px = (img_h - grid_top_px) / @as(f64, @floatFromInt(total_lines));
    // cmdheight=1, so the statusline is the row above the command line.
    const statusline_row = @as(f64, @floatFromInt(total_lines - 2));
    const row_top_px = grid_top_px + statusline_row * cell_h_px;
    // Inset a little, so that rounding in the row arithmetic cannot let the
    // band touch the row above.
    const inset_px = row_inset_rows * cell_h_px;
    const band: visual.Region = .{
        .y0 = (row_top_px + inset_px) / img_h,
        .y1 = (row_top_px + cell_h_px - inset_px) / img_h,
    };
    std.debug.print(
        "[gui] statusline_chrome: capture {d}x{d} lines={d} grid_top={d:.0}px cell_h={d:.2}px statusline row {d:.0} band y[{d:.4},{d:.4}]\n",
        .{ incremental.w, incremental.h, total_lines, grid_top_px, cell_h_px, statusline_row, band.y0, band.y1 },
    );

    // The band must be ON the statusline. Nothing above says so — an
    // arithmetic slip, or a host whose config left laststatus alone, would
    // put it on a text row instead, and every comparison below would still
    // read plausibly while guarding the wrong pixels. A statusline is a bar
    // painted in its own highlight, so the luminance that dominates its row
    // is that highlight; a text row's is the window background.
    const band_y0: u32 = @intFromFloat(band.y0 * img_h);
    const band_y1: u32 = @intFromFloat(band.y1 * img_h);
    const band_bg = grid_pixels.modalLuma(incremental, 0, incremental.w, band_y0, band_y1);
    std.debug.print(
        "[gui] statusline_chrome: band luma {d} vs window background {d}\n",
        .{ band_bg, bg },
    );
    if (@abs(@as(i32, band_bg) - @as(i32, bg)) < 8) {
        std.debug.print("[gui] statusline_chrome: the band is filled with the window background — it is not on a statusline\n", .{});
        return error.BandIsNotTheStatusline;
    }

    // Guard against a vacuous pass: if the cursor steps never reached the
    // statusline, the band would be unchanged for trivial reasons.
    const moved = visual.regionDiffRatio(baseline, incremental, band, 6);
    if (moved <= 0.0002) {
        std.debug.print(
            "[gui] statusline_chrome: the cursor steps did not change the statusline band ({d:.4}) — test would be vacuous\n",
            .{moved},
        );
        return error.StatuslineDidNotRender;
    }

    // Ground truth: <C-l> clears and redraws every row of every grid.
    try g.remoteSend("<C-l>");
    var redrawn = try g.captureStable(crop, 8000);
    defer redrawn.deinit(alloc);

    const redrawn_moved = visual.regionDiffRatio(baseline, redrawn, band, 6);
    if (redrawn_moved <= 0.0002) {
        std.debug.print(
            "[gui] statusline_chrome: the forced redraw matches the pre-move baseline ({d:.4}) — the capture is not showing the moved cursor\n",
            .{redrawn_moved},
        );
        return error.StatuslineDidNotRender;
    }

    // The forced redraw is only ground truth if it is a fixed point. Grid 1
    // emits no background run under its glyphs (see the header), so a repaint
    // of a root row blends onto whatever is already there — if that
    // accumulated, a second <C-l> would land on different pixels than the
    // first and the comparison below would be measuring the oracle's own
    // drift rather than the incremental path's.
    try g.remoteSend("<C-l>");
    var redrawn_again = try g.captureStable(crop, 8000);
    defer redrawn_again.deinit(alloc);
    const oracle_drift = visual.regionDiffRatio(redrawn, redrawn_again, band, 6);
    std.debug.print("[gui] statusline_chrome: second forced redraw drifted {d:.4}\n", .{oracle_drift});
    if (oracle_drift > 0.0002) {
        std.debug.print("[gui] statusline_chrome: the forced redraw is not idempotent — it is not ground truth\n", .{});
        return error.ForcedRedrawNotIdempotent;
    }

    std.debug.print(
        "[gui] statusline_chrome: cursor steps changed the band by {d:.4}; incremental vs forced redraw — band {d:.4}, whole frame {d:.4}\n",
        .{
            moved,
            visual.regionDiffRatio(redrawn, incremental, band, 6),
            visual.regionDiffRatio(redrawn, incremental, .{}, 6),
        },
    );
    // Hand the human both frames, not just the differing one.
    driver.capture.writeImage(alloc, "tmp/statusline_forced_redraw" ++ driver.capture.image_ext, redrawn) catch {};

    try visual.assertRegionUnchanged(
        alloc,
        "statusline_survives_layer_redraw",
        redrawn,
        incremental,
        band,
        .{},
    );
}
