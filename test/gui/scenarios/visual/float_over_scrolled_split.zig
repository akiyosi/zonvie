// visual/float_over_scrolled_split — a float sitting over a scrolling split
// must show the same screen a direct jump to the same view shows.
//
// Regression guard for the per-layer GPU scroll copy. A window that takes the
// core's row-shift fast path is scrolled on the GPU: one blit moves the
// rectangle that layer owns inside the shared back texture, and only the band
// the shift vacated is redrawn. A float drawn on top of that rectangle is not
// part of the copy, so two things happen to its pixels:
//
//   - the float's own pixels inside the blitted rectangle move with the shift,
//     so every row of the float that the rectangle touches has to be drawn
//     again to put the float back;
//   - what those pixels covered moved with them, into rows of the split the
//     float no longer hides, so those rows have to be drawn again from the
//     split's own vertices.
//
// `markLayersOverBlit` repaints both halves. Deleting the second one leaves a
// smear no other scenario sees: the float's six lines print across twelve rows
// of the split (18220 differing pixels against 522 for a correct frame) and
// the whole GUI suite still passes.
//
// The oracle is relational — incremental scrolling and a jump to the same
// topline must agree — so it needs no golden, is meaningful on a fresh
// checkout, and is immune to the per-host font/DPI drift a golden suffers. A
// jump repaints every row from scratch and therefore cannot carry a smear.
//
// Both frontends emit [layer_blit] and [layer_draw].

const std = @import("std");
const driver = @import("../../driver.zig");
const fixture = @import("fixture.zig");
const visual = @import("../../visual.zig");
const gui_io = @import("../../gui_io.zig");
const app_log = @import("../../app_log.zig");

/// The fixture launches the app with this log. It is this scenario's own, not
/// the shared one: the counts below are only an oracle while every line they
/// see came from this run's app process.
const log_path = "tmp/gui_float_over_scrolled_split.log";

const blit_marker = "[layer_blit] gridId=";
const refused_overlap_marker = "reason=overlap";
const draw_marker = "[layer_draw] gridId=";

/// The whole text area. A smear moves content the float used to cover, which
/// can land anywhere in the scroll region, so nothing is excluded beyond what
/// the fixture's own chrome settings already remove.
const region: visual.Region = .{};

const crop: driver.capture.Crop = .{ .w_pt = 600, .h_pt = 300 };

/// Scroll steps, each `3<C-e>`. Twelve rows in total: twice the float's height,
/// so a smear has room to print the whole float below itself.
///
/// Deliberately NOT `<C-d>`: the core's dirty-row bookkeeping expands by twice
/// the delta, so a step of half the region or more dirties every row, the layer
/// redraws all of them, and the blit is refused as "drawall" — the path this
/// scenario exists for would never run.
const steps: usize = 4;

/// The float's height in rows. `[layer_draw] … of=` is a layer's row count, so
/// this tells the float apart from the ~50-row splits without a grid id, which
/// the driver cannot query.
const float_rows_f: f64 = 6;

/// Frames the app is given to settle each scroll step. Sends that coalesce into
/// one flush produce one blit for several steps, which would make the count gate
/// below unreachable for reasons unrelated to the blit.
const step_settle_ms = 300;

/// Frames since `since_ms` in which the float's layer encoded at least one row.
fn floatDrawFrames(alloc: std.mem.Allocator, since_ms: f64) !usize {
    const lines = try app_log.linesSince(alloc, log_path, draw_marker, since_ms);
    defer alloc.free(lines);

    var n: usize = 0;
    var it = std.mem.splitScalar(u8, lines, '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        const of = app_log.field(line, "of") orelse continue;
        const rows = app_log.field(line, "rows") orelse continue;
        if (of != float_rows_f or rows <= 0) continue;
        n += 1;
    }
    return n;
}

pub fn run(alloc: std.mem.Allocator) !void {
    // A scenario that builds on fixture.openWithLog still has to make the "no
    // screen capture on this host" case an honest skip rather than a failure
    // from deep inside captureStable.
    try fixture.requireScreenAccess();
    // A file left by a crashed earlier run would still be appended to, and its
    // lines would be counted alongside this run's.
    std.Io.Dir.cwd().createDirPath(gui_io.io(), "tmp") catch {};
    std.Io.Dir.cwd().deleteFile(gui_io.io(), log_path) catch {};

    var g = try fixture.openWithLog(alloc, log_path);
    defer g.deinit();

    // Nothing outside the text area may react to the cursor, or the comparison
    // would fail for reasons unrelated to the scroll pipeline.
    try g.exec("execute('set laststatus=0 noruler noshowcmd showtabline=0 scrolloff=0 nowrap noswapfile')");
    // A blinking cursor alone produces a false diff between the two captures.
    try g.exec("execute('set guicursor=a:block-blinkon0')");

    // Every line must differ across the full width: a screen made of similar
    // lines would survive a bad shift unchanged and make this blind to the very
    // artifact it exists to catch.
    try g.exec(
        \\setline(1, map(range(1, 400), {_, i -> printf('%3d %s', i, repeat(nr2char(65 + i % 26), 60))}))
    );

    // A vertical split always fails the core's full-width row-scroll fast path
    // check, so its window is drawn as a layer — which is what the blit acts on.
    try g.exec("execute('vsplit')");

    // A float over the LEFT window, overlapping the scroll region in its middle
    // rather than at an edge, so the smear this guards has rows on both sides of
    // it to print into. style='minimal' keeps the oracle about the smear instead
    // of border geometry.
    try g.exec(
        \\luaeval('(function() local b = vim.api.nvim_create_buf(false, true) vim.api.nvim_buf_set_lines(b, 0, -1, false, {"FLOAT 1", "FLOAT 2", "FLOAT 3", "FLOAT 4", "FLOAT 5", "FLOAT 6"}) vim.api.nvim_open_win(b, false, {relative="editor", row=6, col=4, width=24, height=6, style="minimal"}) return 1 end)()')
    );

    // Back to the left window — nvim_open_win did not enter the float, but
    // being explicit costs nothing and the scroll must land on the split the
    // float covers.
    try g.exec("execute('wincmd t')");
    try g.exec("execute('normal! 100Gzt0')");

    // Warm-up, then back where it started. A commit that places a layer at a
    // rectangle it did not have before drops that layer's staged shift and
    // marks it fully dirty, so a scroll issued while the layout is still
    // settling produces no blit at all — observed once as zero blits over all
    // four steps. Spending one scroll outside the measured window keeps that
    // out of the gate below.
    try g.remoteSend("3<C-e>");
    gui_io.sleepNs(step_settle_ms * std.time.ns_per_ms);
    try g.remoteSend("3<C-y>");
    gui_io.sleepNs(step_settle_ms * std.time.ns_per_ms);

    var before = try g.captureStable(crop, 8000);
    defer before.deinit(alloc);

    const t_scroll = try app_log.nowMs(alloc, log_path);
    var i: usize = 0;
    while (i < steps) : (i += 1) {
        try g.remoteSend("3<C-e>");
        gui_io.sleepNs(step_settle_ms * std.time.ns_per_ms);
    }
    var incremental = try g.captureStable(crop, 8000);
    defer incremental.deinit(alloc);

    // The pixel comparison at the end passes just as well when every layer
    // redraws itself from scratch: same screen, different path, and the defect
    // this exists for lives only on the blit path. Require that the blit ran.
    const blits = try app_log.countLinesSince(alloc, log_path, blit_marker, t_scroll);
    const float_draws = try floatDrawFrames(alloc, t_scroll);
    const overlap_refusals = try app_log.countLinesSince(alloc, log_path, refused_overlap_marker, t_scroll);
    std.debug.print(
        "[gui] float_over_scrolled_split: {d} blits, {d} float draws, {d} overlap refusals over {d} steps\n",
        .{ blits, float_draws, overlap_refusals, steps },
    );
    if (blits < steps) {
        std.debug.print("[gui] the per-layer scroll blit did not run; this comparison would guard nothing\n", .{});
        return error.BlitDidNotRun;
    }
    // An overlap refusal drops the shift and redraws the whole region instead,
    // which bypasses the marking entirely — the frame would be correct for a
    // reason that has nothing to do with what this guards.
    if (overlap_refusals > 0) {
        std.debug.print("[gui] a layer refused its blit as overlapping; the marking under test was bypassed\n", .{});
        return error.BlitRefusedOverlap;
    }
    // Without this, a build that drew the float as a separate OS window (or
    // never drew it at all) would pass trivially: there would be no float
    // pixels for the blit to drag.
    if (float_draws < steps) {
        std.debug.print("[gui] the float was not repainted over the scrolled split; there is no smear to catch\n", .{});
        return error.FloatNotRepainted;
    }

    // Guard against a vacuous pass: if the scrolling never rendered, the
    // comparison below would hold trivially.
    const moved = visual.regionDiffRatio(before, incremental, region, 6);
    if (moved <= 0.0002) {
        std.debug.print(
            "[gui] float_over_scrolled_split: {d} scroll steps did not change the screen ({d:.4}) — test would be vacuous\n",
            .{ steps, moved },
        );
        return error.ScrollDidNotRender;
    }

    // Ask Neovim where the incremental scrolling actually landed rather than
    // assuming, so the comparison below can never fail for arithmetic reasons.
    const topline = try g.evalInt("line('w0')");
    const cursor_line = try g.evalInt("line('.')");
    std.debug.print(
        "[gui] float_over_scrolled_split: topline={d} cursor={d} scroll moved {d:.4} of the frame\n",
        .{ topline, cursor_line, moved },
    );

    // The same view reached by a jump, which repaints every row of every layer
    // from scratch and therefore cannot carry a smear.
    try g.exec("execute('normal! 1Gzt0')");
    var settled = try g.captureStable(crop, 8000);
    settled.deinit(alloc);
    var jump_buf: [64]u8 = undefined;
    const jump_cmd = try std.fmt.bufPrint(&jump_buf, "execute('normal! {d}Gzt0')", .{topline});
    try g.exec(jump_cmd);
    var jumped = try g.captureStable(crop, 8000);
    defer jumped.deinit(alloc);

    try visual.assertRegionUnchanged(
        alloc,
        "float_over_scrolled_split",
        jumped,
        incremental,
        region,
        .{},
    );
}
