// visual/partial_matches_full_float_move — moving a float recomposes the background.
//
// When a float moves, the grid beneath it is exposed. A partial redraw must
// restore the grid's contents to that region, not leave the old float's pixels
// behind. The back buffer retains previous content, so only the rows that
// change are repainted; a moved float leaves a "shadow" of unrepainted
// background that the damage bands must cover.

const std = @import("std");
const fixture = @import("fixture.zig");
const visual = @import("../../visual.zig");
const app_log = @import("../../app_log.zig");
const driver = @import("../../driver.zig");
const gui_io = @import("../../gui_io.zig");

const log_path = "tmp/gui_partial_matches_full_float_move.log";
const full_frame_marker = "[trace] event=full_frame_done";
const crop: driver.capture.Crop = .{ .w_pt = 600, .h_pt = 400 };

const tall = "\u{00C5}\u{00C9}\u{00CE}\u{00D6}\u{00DC} \u{00C5}\u{00C9}\u{00CE}\u{00D6}\u{00DC} \u{00C5}\u{00C9}\u{00CE}\u{00D6}\u{00DC}";

pub fn run(alloc: std.mem.Allocator) !void {
    std.Io.Dir.cwd().deleteFile(gui_io.io(), log_path) catch {};
    var g = try fixture.openWithLogConfigAndEnv(alloc, log_path, "test/gui/fixtures/config", &.{
        .{ "ZONVIE_TEST_FULL_REDRAW", "1" },
    });
    defer g.deinit();

    try g.exec("execute('set linespace=-6')");
    try g.exec("setline(1, ['plain row one', '" ++ tall ++ "', 'plain row three', '" ++ tall ++ "', 'plain row five', 'plain row six', 'plain row seven'])");

    // Create a float at an initial position.
    try g.exec(
        "luaeval('(function() local b = vim.api.nvim_create_buf(false, true) " ++
        "vim.api.nvim_buf_set_lines(b, 0, -1, false, {\"FLOAT CONTENT\"}) " ++
        "_G.z_float = vim.api.nvim_open_win(b, false, {relative=\"editor\", row=10, col=20, width=20, height=3, border=\"single\"}) " ++
        "return 1 end)()')"
    );
    var settled = try g.captureStable(crop, 8000);
    defer settled.deinit(alloc);

    // Move the float: expose the old position, cover the new one.
    // Note: nvim_win_set_config requires 'relative' when changing a float position.
    const move_start = try app_log.nowMs(alloc, log_path);
    try g.exec("luaeval('vim.api.nvim_win_set_config(_G.z_float, {relative=\"editor\", row=2, col=40})')");
    var partial = try g.captureStable(crop, 8000);
    defer partial.deinit(alloc);

    // Vacuity checks.
    if (visual.regionDiffRatio(settled, partial, .{}, 8) == 0) {
        std.debug.print("[gui] partial_matches_full_float_move: move never changed screen\n", .{});
        return error.EditsNotVisible;
    }
    if (try app_log.containsSince(alloc, log_path, full_frame_marker, move_start)) {
        std.debug.print("[gui] partial_matches_full_float_move: full frame drew move, not partial\n", .{});
        return error.EditsDrawnWhole;
    }

    // Force full redraw. The background at both the old and new float positions
    // must be restored correctly.
    const forced = try app_log.nowMs(alloc, log_path);
    driver.platform.forceFullRedraw(g.app_pid);
    try app_log.waitForSince(alloc, log_path, full_frame_marker, forced, 5000);
    var full = try g.captureStable(crop, 8000);
    defer full.deinit(alloc);

    try visual.assertRegionUnchanged(alloc, "partial_matches_full_float_move", partial, full, .{}, .{
        .tol_per_channel = 2,
        .max_diff_ratio = 0,
    });
}
