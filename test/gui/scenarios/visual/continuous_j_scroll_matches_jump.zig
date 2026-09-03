// visual/continuous_j_scroll_matches_jump — holding `j` past the bottom of the
// window must leave the same screen as jumping to where it ended up.
//
// This is the input that exposed the per-grid layer draw's two shift defects:
// the layer pass ignored a slot's source row, and `rowTranslationY` was being
// added in NDC while every producer of it had moved to pixels. Content walked
// off the window instead of scrolling. `test/perf/test_60fps.py` drives the
// same continuous `j`, but it only checks frame timing — a window that draws
// nothing still meets a 60 fps budget — so nothing in the suite looked at the
// pixels this input produces.
//
// Two phases, because they reach the scroll fast path differently:
//
//   * one `j` at a time, which is one row shifted per flush, and
//   * a burst of them in a single send, which Neovim coalesces so several
//     rows shift in one flush. Composition never allowed a multi-row shift
//     from a window grid at all, so this path is new.
//
// Both compare against a direct jump, which repaints every row from scratch
// and therefore cannot carry a shift error. The invariant is relational, so
// there is no golden to keep per environment, and it fails on drift as well
// as on total loss.

const std = @import("std");
const driver = @import("../../driver.zig");
const fixture = @import("fixture.zig");
const visual = @import("../../visual.zig");
const app_log = @import("../../app_log.zig");

/// The fixture launches the app with this log.
const log_path = "tmp/gui_app.log";

const content_band: visual.Region = .{};

const crop: driver.capture.Crop = .{ .w_pt = 600, .h_pt = 300 };

// Enough rows that a one-row-per-step drift clears the window rather than
// leaving a near-match.
const single_steps: usize = 12;

pub fn run(alloc: std.mem.Allocator) !void {
    var g = try fixture.open(alloc);
    defer g.deinit();

    // Nothing outside the text area may react to the cursor, or the
    // comparison would fail for reasons unrelated to the scroll pipeline.
    // scrolloff=0 is what makes each `j` past the last visible row scroll by
    // exactly one row.
    try g.exec("execute('set laststatus=0 noruler noshowcmd scrolloff=0 nowrap')");

    // Every line must differ across the full width: a screen made of
    // identical lines would survive a shift unchanged and make this test
    // blind to the very artifact it exists to catch.
    try g.exec(
        \\setline(1, map(range(1, 400), {_, i -> printf('%3d %s', i, repeat(nr2char(65 + i % 26), 60))}))
    );

    try runPhase(alloc, g, "single", single_steps, false);
    try runPhase(alloc, g, "burst", single_steps, true);
}

/// Scroll `steps` rows by pressing `j` from the bottom line of the window,
/// then check the screen against a jump to wherever it ended up.
fn runPhase(
    alloc: std.mem.Allocator,
    g: *driver.Gui,
    phase: []const u8,
    steps: usize,
    burst: bool,
) !void {
    // Start from a known view with the cursor on the last visible row, so
    // every `j` from here scrolls instead of only moving the cursor.
    try g.exec("execute('normal! 100GztL')");
    var before = try g.captureStable(crop, 8000);
    defer before.deinit(alloc);

    const topline_before = try g.evalInt("line('w0')");

    const t_scroll = try app_log.nowMs(alloc, log_path);
    if (burst) {
        // One send, so Neovim coalesces the motions and the core publishes a
        // multi-row shift rather than `steps` single-row ones.
        var keys: [64]u8 = undefined;
        const n = @min(steps, keys.len);
        @memset(keys[0..n], 'j');
        try g.remoteSend(keys[0..n]);
    } else {
        var i: usize = 0;
        while (i < steps) : (i += 1) {
            try g.remoteSend("j");
        }
    }

    var scrolled = try g.captureStable(crop, 8000);
    defer scrolled.deinit(alloc);

    // A refused hint regenerates every row and reaches the same screen, so
    // the pixel comparison alone cannot tell the shift path ran at all. The
    // burst phase coalesces into fewer, larger shifts, so only require one.
    const shifts = try app_log.countLinesSince(alloc, log_path, "[layer_row_scroll]", t_scroll);
    const min_shifts: usize = if (burst) 1 else steps / 2;
    std.debug.print(
        "[gui] continuous_j_scroll_matches_jump[{s}]: row-shift hints applied {d} (need {d})\n",
        .{ phase, shifts, min_shifts },
    );
    if (shifts < min_shifts) {
        std.debug.print("[gui] the scroll fast path did not run; this comparison would guard nothing\n", .{});
        return error.ScrollFastPathDidNotRun;
    }
    if (burst) {
        // The burst phase exists for the COALESCED shift: one hint carrying
        // many rows at once, which is the path that hid a defect a run of
        // single-row shifts did not. A lone one-row hint would satisfy the
        // count above and leave that path unexercised.
        const line = (try app_log.lastLineSince(alloc, log_path, "[layer_row_scroll]", t_scroll)) orelse
            return error.ScrollFastPathDidNotRun;
        defer alloc.free(line);
        const delta = app_log.field(line, "rowsDelta") orelse return error.ScrollHintUnparsable;
        std.debug.print("[gui] continuous_j_scroll_matches_jump[burst]: last shift rowsDelta={d:.0}\n", .{delta});
        if (@abs(delta) < 2) {
            std.debug.print("[gui] the burst did not coalesce into a multi-row shift\n", .{});
            return error.ScrollHintNotCoalesced;
        }
    }

    const topline_after = try g.evalInt("line('w0')");
    const cursor_after = try g.evalInt("line('.')");
    std.debug.print(
        "[gui] continuous_j_scroll_matches_jump[{s}]: topline {d} -> {d}, cursor {d}\n",
        .{ phase, topline_before, topline_after, cursor_after },
    );

    // Guard against a vacuous pass: without an actual scroll the comparison
    // below would hold trivially and the test would guard nothing.
    if (topline_after <= topline_before) {
        std.debug.print(
            "[gui] continuous_j_scroll_matches_jump[{s}]: the view did not scroll — test would be vacuous\n",
            .{phase},
        );
        return error.ScrollDidNotRender;
    }
    const moved = visual.regionDiffRatio(before, scrolled, content_band, 6);
    if (moved <= 0.0002) {
        std.debug.print(
            "[gui] continuous_j_scroll_matches_jump[{s}]: the screen did not change ({d:.4}) — test would be vacuous\n",
            .{ phase, moved },
        );
        return error.ScrollDidNotRender;
    }

    // The same view reached by a repaint. Land somewhere else first so the
    // jump cannot be a no-op that leaves the scrolled screen in place.
    try g.exec("execute('normal! 1Gzt0')");
    var settled = try g.captureStable(crop, 8000);
    settled.deinit(alloc);

    var cmd: [96]u8 = undefined;
    const jump = try std.fmt.bufPrint(
        &cmd,
        "execute('normal! {d}Gzt{d}G')",
        .{ topline_after, cursor_after },
    );
    try g.exec(jump);
    var jumped = try g.captureStable(crop, 8000);
    defer jumped.deinit(alloc);

    var name: [64]u8 = undefined;
    const label = try std.fmt.bufPrint(&name, "continuous_j_scroll_{s}", .{phase});
    try visual.assertRegionUnchanged(alloc, label, jumped, scrolled, content_band, .{});
}
