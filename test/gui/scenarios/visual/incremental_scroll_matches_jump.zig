// visual/incremental_scroll_matches_jump — scrolling to a line one row at a
// time must land on the same screen as jumping to it directly.
//
// Regression guard for per-grid layer drawing: a row-shift hint remaps a
// grid's row slots without rewriting the vertices in them, so a slot still
// holds the pixels it was built for. The root grid compensates through
// rowSlotSourceRows; the layer draw added for per-grid rendering did not, so
// every shifted row kept drawing at its pre-scroll y. One `j` looked almost
// right, but the error accumulated with each one and content walked off the
// bottom of the window.
//
// The invariant is relational — incremental scrolling and a direct jump must
// agree — so this compares two captures from the same run instead of a
// golden: no per-environment baseline, and it is meaningful on a fresh
// checkout. It also fails on any drift, not only on total loss.

const std = @import("std");
const driver = @import("../../driver.zig");
const fixture = @import("fixture.zig");
const visual = @import("../../visual.zig");

// The whole text area. Drift moves everything, so nothing needs excluding
// beyond what the fixture's own chrome settings already remove.
const content_band: visual.Region = .{};

const crop: driver.capture.Crop = .{ .w_pt = 600, .h_pt = 300 };

// Enough steps that a one-row-per-scroll drift pushes content clear of the
// window rather than leaving a near-match.
const steps: usize = 12;

pub fn run(alloc: std.mem.Allocator) !void {
    var g = try fixture.open(alloc);
    defer g.deinit();

    // Nothing outside the text area may react to the cursor, or the
    // comparison would fail for reasons unrelated to the scroll pipeline.
    try g.exec("execute('set laststatus=0 noruler noshowcmd scrolloff=0 nowrap')");

    // Every line must differ across the full width: a screen made of
    // identical lines would survive a shift unchanged and make this test
    // blind to the very artifact it exists to catch.
    try g.exec(
        \\setline(1, map(range(1, 300), {_, i -> printf('%3d %s', i, repeat(nr2char(65 + i % 26), 60))}))
    );

    // Land on the target by scrolling one line at a time, which is what takes
    // the row-shift hint on every step.
    try g.exec("execute('normal! 150Gzt0')");
    var before = try g.captureStable(crop, 8000);
    defer before.deinit(alloc);

    var i: usize = 0;
    while (i < steps) : (i += 1) {
        try g.remoteSend("<C-e>");
    }
    var incremental = try g.captureStable(crop, 8000);
    defer incremental.deinit(alloc);

    // Guard against a vacuous pass: if the scrolling never rendered, the
    // comparison below would hold trivially and the test would guard nothing.
    const moved = visual.regionDiffRatio(before, incremental, content_band, 6);
    if (moved <= 0.0002) {
        std.debug.print(
            "[gui] incremental_scroll_matches_jump: {d} scrolls did not change the screen ({d:.4}) — test would be vacuous\n",
            .{ steps, moved },
        );
        return error.ScrollDidNotRender;
    }

    // Ask Neovim where the incremental scrolling actually landed rather than
    // assuming, so the comparison below can never fail for arithmetic reasons.
    const topline = try g.evalInt("line('w0')");
    const cursor_line = try g.evalInt("line('.')");
    std.debug.print(
        "[gui] incremental_scroll_matches_jump: topline={d} cursor={d}\n",
        .{ topline, cursor_line },
    );

    // The same view reached by a jump, which repaints every row from scratch
    // and therefore cannot carry a shift error.
    try g.exec("execute('normal! 1Gzt0')");
    var settled = try g.captureStable(crop, 8000);
    settled.deinit(alloc);
    var jump_buf: [64]u8 = undefined;
    const jump_cmd = try std.fmt.bufPrint(
        &jump_buf,
        "execute('normal! {d}Gzt0')",
        .{topline},
    );
    try g.exec(jump_cmd);
    var jumped = try g.captureStable(crop, 8000);
    defer jumped.deinit(alloc);

    try visual.assertRegionUnchanged(
        alloc,
        "incremental_scroll_matches_jump",
        jumped,
        incremental,
        content_band,
        .{},
    );
}
