// visual/main_float_cursor_moves — a cursor moving inside a float the MAIN
// window hosts must produce a frame.
//
// The main surface's row-mode skip gate is
//   rowMode && dirtyRows.isEmpty && !anyLayerWork && !smoothScrolling
//     && !blinkStateChanged && !drawableSizeChanged && hasPresentedOnce
//     && !anyCustomShaderNeedsAnimation
// and it carries no `hasNewCommit` term. A dirty row is therefore the only
// thing that keeps a cursor-only frame alive — but `submitLayerCursor`, the
// route a float's cursor takes (ZonvieCore's `.mainLayer` case), marks no row
// damage and never sets `flushHadLayerWork`, so `anyLayerWork` stays false.
//
// What rescues it today is indirect: there is one global cursor revision, so a
// cursor moving inside the float also fires grid 1's cursor callback with an
// EMPTY slice. The renderer discards that (`cursor_ignore ...
// reason=empty_nonowner`) — but the view marks its row dirty before the
// renderer ever sees it.
//
// WHAT THIS SCENARIO DOES AND DOES NOT COVER. It asserts the OUTCOME: the
// cursor visibly moves inside a float the main window hosts. It does NOT
// isolate the gate above, and that is measured, not assumed. Instrumenting a
// run showed the `.mainLayer` route taken 10 times and the view marking damage
// 157 times, while the gate fired ZERO times — there is enough other redraw
// traffic here (capture itself provokes some) that the gate is never the
// deciding factor. Deleting the view's `markDirtyRows` and re-running leaves
// this scenario passing unchanged. So do not read a green run here as licence
// to remove that damage mark; the tripwire for that change does not exist yet,
// and building one needs a quieter harness than screen capture provides.
//
// Measured as pixels, not as bookkeeping: a frame that is never produced and
// a frame that is produced and identical are the same trace but not the same
// screen. `enter = true` puts the cursor INSIDE the float, which is what
// `visual/float.zig` deliberately avoids; the fixture's steady non-blinking
// cursor (`guicursor+=a:blinkon0`) keeps a blink toggle out of the measurement.
//
// macOS-only: it is the macOS renderer's gate under test.

const std = @import("std");
const fixture = @import("fixture.zig");
const visual = @import("../../visual.zig");
const gui_io = @import("../../gui_io.zig");

/// The float sits in the upper-left quadrant. Cropping to it keeps the main
/// grid's own cursor and any chrome out of the measurement.
const float_region = visual.Region{ .x0 = 0.02, .y0 = 0.05, .x1 = 0.55, .y1 = 0.45 };

/// A cursor is a small part of even a cropped region, so the bar is low — but
/// it is not zero, and zero is exactly the defect.
const min_diff_ratio = 0.0005;

pub fn run(alloc: std.mem.Allocator) !void {
    var g = try fixture.open(alloc);
    defer g.deinit();

    try g.exec("execute('set nocursorline nonumber')");
    // A float with enough rows that the cursor can move without scrolling it,
    // and plain identical-width content so only the cursor varies the pixels.
    try g.exec(
        \\luaeval('(function() local b = vim.api.nvim_create_buf(false, true) local l = {} for i = 1, 12 do l[i] = "float line" end vim.api.nvim_buf_set_lines(b, 0, -1, false, l) _G.z_float = vim.api.nvim_open_win(b, true, {relative="editor", row=3, col=4, width=20, height=10, style="minimal", border="single"}) vim.api.nvim_win_set_cursor(_G.z_float, {1, 0}) return 1 end)()')
    );
    // Let the float's own first frames land before measuring.
    gui_io.sleepNs(1200 * std.time.ns_per_ms);

    var before = try g.captureStable(.{ .w_pt = 600, .h_pt = 300 }, 8000);
    defer before.deinit(alloc);

    // Move the cursor several rows down INSIDE the float. No content changes:
    // every line is identical, cursorline is off, and the float does not
    // scroll.
    try g.exec("luaeval('(function() vim.api.nvim_win_set_cursor(_G.z_float, {6, 0}) return 1 end)()')");
    gui_io.sleepNs(900 * std.time.ns_per_ms);

    var after = try g.captureStable(.{ .w_pt = 600, .h_pt = 300 }, 8000);
    defer after.deinit(alloc);

    const row_now = try g.evalInt("line('.')");
    const ratio = visual.regionDiffRatio(before, after, float_region, 12);
    std.debug.print(
        "[gui] main-float cursor: nvim row -> {d}; float region diff {d:.5} (min {d:.5})\n",
        .{ row_now, ratio, min_diff_ratio },
    );

    // Neovim really did move it — otherwise an unchanged screen would be
    // correct and the assertion below would be vacuous.
    if (row_now != 6) return error.CursorDidNotMoveInNeovim;
    if (ratio < min_diff_ratio) {
        std.debug.print("[gui] the float's cursor move produced no frame\n", .{});
        return error.MainFloatCursorFrameMissing;
    }
}
