// visual/partial_matches_full_scroll — scrolled content's partial redraw matches full.
//
// Scrolling combines grid_scroll (a GPU blit of rows) with new row renders for
// the gap. A partial redraw must not leave stale pixels in the newly-exposed
// rows. The damage bands account for both the blit region and the new rows,
// but a retained back buffer retains unrepainted rows if the bands miss.

const std = @import("std");
const fixture = @import("fixture.zig");
const visual = @import("../../visual.zig");
const app_log = @import("../../app_log.zig");
const driver = @import("../../driver.zig");
const gui_io = @import("../../gui_io.zig");

const log_path = "tmp/gui_partial_matches_full_scroll.log";
const full_frame_marker = "[trace] event=full_frame_done";
const crop: driver.capture.Crop = .{ .w_pt = 700, .h_pt = 480 };

const tall = "\u{00C5}\u{00C9}\u{00CE}\u{00D6}\u{00DC} \u{00C5}\u{00C9}\u{00CE}\u{00D6}\u{00DC} \u{00C5}\u{00C9}\u{00CE}\u{00D6}\u{00DC}";

pub fn run(alloc: std.mem.Allocator) !void {
    // TODO: Zig 0.16 fs API — deleteFile skipped for now
    var g = try fixture.openWithLogConfigAndEnv(alloc, log_path, "test/gui/fixtures/config", &.{
        .{ "ZONVIE_TEST_FULL_REDRAW", "1" },
    });
    defer g.deinit();

    try g.exec("execute('set linespace=-6')");

    // Populate the buffer with 60 lines: plain and tall alternating.
    // Tall lines carry accents that spill ink upward, so a scroll gap must
    // repaint rows above the newly-scrolled content.
    try g.exec("execute('call append(0, repeat([\"line x: plain\", \"" ++ tall ++ "\"], 30))')");
    try g.exec("execute('1d')");
    try g.exec("execute('normal! gg')"); // Go to start for settled capture.

    // Position at the start.
    try g.exec("execute('normal! gg')");
    var settled = try g.captureStable(crop, 8000);
    defer settled.deinit(alloc);

    // Scroll down by 7 lines.
    const scroll_start = try app_log.nowMs(alloc, log_path);
    try g.exec("execute('normal! 7<C-e>')");
    var partial = try g.captureStable(crop, 8000);
    defer partial.deinit(alloc);

    // Vacuity checks.
    if (visual.regionDiffRatio(settled, partial, .{}, 8) == 0) {
        std.debug.print("[gui] partial_matches_full_scroll: scroll never changed screen\n", .{});
        return error.EditsNotVisible;
    }
    if (try app_log.containsSince(alloc, log_path, full_frame_marker, scroll_start)) {
        std.debug.print("[gui] partial_matches_full_scroll: full frame drew scroll, not partial\n", .{});
        return error.EditsDrawnWhole;
    }

    // Force full redraw and compare.
    const forced = try app_log.nowMs(alloc, log_path);
    driver.platform.forceFullRedraw(g.app_pid);
    try app_log.waitForSince(alloc, log_path, full_frame_marker, forced, 5000);
    var full = try g.captureStable(crop, 8000);
    defer full.deinit(alloc);

    try visual.assertRegionUnchanged(alloc, "partial_matches_full_scroll", partial, full, .{}, .{
        .tol_per_channel = 2,
        .max_diff_ratio = 0,
    });
}
