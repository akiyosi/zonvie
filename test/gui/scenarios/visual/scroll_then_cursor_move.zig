// visual/scroll_then_cursor_move — a cursor-only row move must not disturb
// content that the preceding scroll already placed.
//
// Regression guard for the macOS phantom scroll re-blit: draw() resolved its
// scroll delta as `pendingScrollAccum ?? bufferSets[csi].pendingScroll`, and
// the per-set field was never cleared once a draw consumed it. While every
// flush rotated committedSetIndex that fallback was unreachable, but once
// cursor-only flushes stopped rotating it (lazy main-write preparation), the
// next cursor-only draw re-read the already-applied delta and GPU-blitted the
// backbuffer a second time. Only the 2*shift dirty band was redrawn from
// committed vertices, so the rest of the screen sat one shift out of place —
// visible as row content changing when only the cursor moved.
//
// The invariant is relational, so this compares two captures from the same
// run instead of a golden: no per-environment baseline, and it is meaningful
// on a fresh checkout.

const std = @import("std");
const driver = @import("../../driver.zig");
const fixture = @import("fixture.zig");
const visual = @import("../../visual.zig");

// The cursor stays in column 0, so a band starting a quarter of the way in
// can never contain it. Everything in that band is scrolled content that a
// cursor move has no business touching.
const content_band: visual.Region = .{ .x0 = 0.25 };

const crop: driver.capture.Crop = .{ .w_pt = 600, .h_pt = 300 };

pub fn run(alloc: std.mem.Allocator) !void {
    var g = try fixture.open(alloc);
    defer g.deinit();

    // Nothing outside the text area may react to cursor movement, or the
    // comparison would fail for reasons unrelated to the scroll pipeline.
    try g.exec("execute('set laststatus=0 noruler noshowcmd scrolloff=0 nowrap')");

    // Every line must differ across the full width: a screen made of
    // identical lines would survive a one-row shift unchanged and make this
    // test blind to the very artifact it exists to catch.
    try g.exec(
        \\setline(1, map(range(1, 300), {_, i -> printf('%3d %s', i, repeat(nr2char(65 + i % 26), 60))}))
    );
    try g.exec("execute('normal! 150Gzz0')");

    var pre_scroll = try g.captureStable(crop, 8000);
    defer pre_scroll.deinit(alloc);

    // Scroll the view by one row (grid_scroll -> core scroll fast path ->
    // on_main_row_scroll -> the frontend's GPU scroll blit).
    try g.remoteSend("<C-e>");
    var after_scroll = try g.captureStable(crop, 8000);
    defer after_scroll.deinit(alloc);

    // Guard against a vacuous pass: if the scroll never rendered, the
    // comparison below would hold trivially and the test would guard nothing.
    const scrolled = visual.regionDiffRatio(pre_scroll, after_scroll, content_band, 6);
    if (scrolled <= 0.0002) {
        std.debug.print(
            "[gui] scroll_then_cursor_move: <C-e> did not change the screen ({d:.4}) — test would be vacuous\n",
            .{scrolled},
        );
        return error.ScrollDidNotRender;
    }

    // Cursor-only move: the view is centered, so `j` moves the cursor one row
    // down without scrolling. Only the two cursor rows may change, and both
    // are in column 0 — outside the band being compared.
    try g.remoteSend("j");
    var after_cursor = try g.captureStable(crop, 8000);
    defer after_cursor.deinit(alloc);

    try visual.assertRegionUnchanged(
        alloc,
        "scroll_then_cursor_move",
        after_scroll,
        after_cursor,
        content_band,
        .{},
    );
}
