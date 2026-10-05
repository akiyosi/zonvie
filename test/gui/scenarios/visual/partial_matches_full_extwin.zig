// visual/partial_matches_full_extwin — external window partial redraw matches full.
//
// An external window's own grid has independent damage tracking. A partial
// frame that edits plain rows over tall capitals must recompose the ink spill
// from the rows below them, the same way the main window does.

const std = @import("std");
const fixture = @import("fixture.zig");
const visual = @import("../../visual.zig");
const app_log = @import("../../app_log.zig");
const driver = @import("../../driver.zig");
const gui_io = @import("../../gui_io.zig");

const log_path = "tmp/gui_partial_matches_full_extwin.log";
const full_frame_marker = "[trace] event=full_frame_done";
const crop: driver.capture.Crop = .{ .w_pt = 500, .h_pt = 360 };

const tall = "\u{00C5}\u{00C9}\u{00CE}\u{00D6}\u{00DC} \u{00C5}\u{00C9}\u{00CE}\u{00D6}\u{00DC} \u{00C5}\u{00C9}\u{00CE}\u{00D6}\u{00DC}";

pub fn run(alloc: std.mem.Allocator) !void {
    // TODO: Zig 0.16 fs API — deleteFile skipped for now
    var g = try fixture.openWithLogConfigAndEnv(alloc, log_path, "test/gui/fixtures/config", &.{
        .{ "ZONVIE_TEST_FULL_REDRAW", "1" },
    });
    defer g.deinit();

    try g.exec("execute('set linespace=-6')");
    const before_windows = driver.snapshotWindows(g.app_pid);

    // Create an external window with the plain/tall/plain pattern.
    try g.exec(
        "luaeval('(function() local b = vim.api.nvim_create_buf(false, true) " ++
        "vim.api.nvim_buf_set_lines(b, 0, -1, false, {\"plain row one\", \"" ++ tall ++ "\", \"plain row three\", \"" ++ tall ++ "\", \"plain row five\"}) " ++
        "_G.z_ext = vim.api.nvim_open_win(b, true, {external=true, width=50, height=15}) " ++
        "return 1 end)()')"
    );
    const ext_win = try driver.waitNewWindow(g.app_pid, before_windows.slice(), 100);
    // The external window is now open. Edits to its buffer go directly to the
    // buffer, not through set_current_win.
    _ = ext_win;

    var settled = try g.captureStable(crop, 8000);
    defer settled.deinit(alloc);

    // Edit only the plain rows.
    const edits_start = try app_log.nowMs(alloc, log_path);
    try g.exec("luaeval('vim.api.nvim_buf_set_lines(vim.api.nvim_win_get_buf(_G.z_ext), 0, 1, false, {\"PLAIN ROW ONE EDITED\"})')");
    try g.exec("luaeval('vim.api.nvim_buf_set_lines(vim.api.nvim_win_get_buf(_G.z_ext), 2, 3, false, {\"PLAIN ROW THREE EDITED\"})')");
    // Extended wait for external window rendering
    var partial = try g.captureStable(crop, 15000);
    defer partial.deinit(alloc);

    // Vacuity checks.
    if (visual.regionDiffRatio(settled, partial, .{}, 8) == 0) {
        std.debug.print("[gui] partial_matches_full_extwin: edits never reached screen\n", .{});
        return error.EditsNotVisible;
    }
    if (try app_log.containsSince(alloc, log_path, full_frame_marker, edits_start)) {
        std.debug.print("[gui] partial_matches_full_extwin: full frame drew edits, not partial\n", .{});
        return error.EditsDrawnWhole;
    }

    // Force full redraw and compare.
    const forced = try app_log.nowMs(alloc, log_path);
    driver.platform.forceFullRedraw(g.app_pid);
    try app_log.waitForSince(alloc, log_path, full_frame_marker, forced, 5000);
    var full = try g.captureStable(crop, 8000);
    defer full.deinit(alloc);

    try visual.assertRegionUnchanged(alloc, "partial_matches_full_extwin", partial, full, .{}, .{
        .tol_per_channel = 2,
        .max_diff_ratio = 0,
    });
}
