// visual/partial_matches_full — a frame built by partial redraws is
// pixel-identical to the same commit drawn whole.
//
// The back buffer is retained, so a partial frame repaints only the rows it
// owes and keeps the rest. Glyph ink is not clamped to its row, and a
// negative linespace makes accented capitals reach into the row above. A
// repaint clipped to an edited row alone erases the ink the row below spilled
// into it and never puts it back, while a full redraw draws that row after it.
// (Ink spilling DOWN is no test: a full redraw paints the next row's
// background over it too.) The damage bands (src/core/damage_bands.zig) widen
// every repaint so the two agree.
//
// Each pane and the float carries a plain row over a row of tall capitals;
// only the plain rows are edited, so the partial frames must recompose the
// spill from the rows below them. The app is then told to redraw everything
// (ZONVIE_TEST_FULL_REDRAW) and the two captures must match.

const std = @import("std");
const fixture = @import("fixture.zig");
const visual = @import("../../visual.zig");
const app_log = @import("../../app_log.zig");
const driver = @import("../../driver.zig");
const gui_io = @import("../../gui_io.zig");

const log_path = "tmp/gui_partial_matches_full.log";
const full_frame_marker = "[trace] event=full_frame_done";
const crop: driver.capture.Crop = .{ .w_pt = 700, .h_pt = 420 };

/// Accented capitals on every column, so the ink above the row is wide.
const tall = "\u{00C5}\u{00C9}\u{00CE}\u{00D6}\u{00DC} \u{00C5}\u{00C9}\u{00CE}\u{00D6}\u{00DC} \u{00C5}\u{00C9}\u{00CE}\u{00D6}\u{00DC}";

pub fn run(alloc: std.mem.Allocator) !void {
    // The app appends to its log and stamps lines from its own start, so an
    // earlier run's lines would read as "since" this run's marks.
    std.Io.Dir.cwd().deleteFile(gui_io.io(), log_path) catch {};
    var g = try fixture.openWithLogConfigAndEnv(alloc, log_path, "test/gui/fixtures/config", &.{
        .{ "ZONVIE_TEST_FULL_REDRAW", "1" },
    });
    defer g.deinit();

    try g.exec("execute('set linespace=-6')");
    try g.exec("setline(1, ['plain row one', '" ++ tall ++ "', 'plain row three', '" ++ tall ++ "', 'plain row five'])");
    try g.exec("execute('vsplit')");
    try g.exec("execute('vertical resize 40')");
    try g.exec("luaeval('(function() local b = vim.api.nvim_create_buf(false, true) " ++
        "vim.api.nvim_buf_set_lines(b, 0, -1, false, {\"float plain\", \"" ++ tall ++ "\", \"float plain\"}) " ++
        "_G.z_float = vim.api.nvim_open_win(b, false, {relative=\"editor\", row=7, col=20, width=30, height=3, border=\"single\"}) " ++
        "return 1 end)()')");
    try g.exec("execute('normal! G$')");

    var settled = try g.captureStable(crop, 8000);
    defer settled.deinit(alloc);

    // Partial frames: only the plain rows over the capitals change, in both
    // panes (they show the same buffer) and in the float.
    const edits_start = try app_log.nowMs(alloc, log_path);
    try g.exec("setline(1, 'PLAIN ROW ONE EDITED')");
    try g.exec("setline(3, 'PLAIN ROW THREE EDITED')");
    try g.exec("luaeval('vim.api.nvim_buf_set_lines(vim.api.nvim_win_get_buf(_G.z_float), 0, 1, false, {\"FLOAT EDITED\"})')");
    var partial = try g.captureStable(crop, 8000);
    defer partial.deinit(alloc);

    // Vacuity: the edits reached the screen, and no full frame drew them.
    if (visual.regionDiffRatio(settled, partial, .{}, 8) == 0) {
        std.debug.print("[gui] partial_matches_full: the edits never changed the screen\n", .{});
        return error.EditsNotVisible;
    }
    if (try app_log.containsSince(alloc, log_path, full_frame_marker, edits_start)) {
        std.debug.print("[gui] partial_matches_full: a full frame drew the edits; nothing partial was measured\n", .{});
        return error.EditsDrawnWhole;
    }

    const forced = try app_log.nowMs(alloc, log_path);
    driver.platform.forceFullRedraw(g.app_pid);
    try app_log.waitForSince(alloc, log_path, full_frame_marker, forced, 5000);
    var full = try g.captureStable(crop, 8000);
    defer full.deinit(alloc);

    try visual.assertRegionUnchanged(alloc, "partial_matches_full", partial, full, .{}, .{
        .tol_per_channel = 2,
        .max_diff_ratio = 0,
    });
}
