// visual/scrollbind_layers_blit_matches_jump — several layers scrolling in the
// same frame must land on the same screen a jump to that view shows.
//
// The per-layer GPU scroll copy runs once per layer per frame, all of them into
// one blit encoder in back-to-front snapshot order. Three vertical splits and a
// float over the middle one, all `scrollbind`, put four layers into that loop at
// once — the case where the blits can interfere with each other:
//
//   - a layer whose rectangle overlaps one already accepted this frame would
//     copy pixels the lower shift has just moved, so it is refused as "overlap"
//     and redraws its whole region instead;
//   - a layer above an accepted blit has its own rows, and the rows under it,
//     marked for repaint by markLayersOverBlit.
//
// Two oracles. The set oracle says WHICH grids took which path, written as a set
// comparison so it does not depend on which grid id is which — the driver cannot
// query them, they are parsed out of the app's own log. The pixel oracle says the
// resulting screen matches the same view reached by a jump, which repaints every
// row from scratch and therefore cannot carry a smear.
//
// `3<C-e>` rather than `<C-d>`: the fast path refuses a shift past half the
// region, so a half-window step that a 22-row split accepts is rejected by an
// 8-row float and the float would never enter the loop this exists to cover.
//
// macOS-only: [layer_blit] is the macOS frontend's line.

const std = @import("std");
const driver = @import("../../driver.zig");
const fixture = @import("fixture.zig");
const visual = @import("../../visual.zig");
const gui_io = @import("../../gui_io.zig");
const app_log = @import("../../app_log.zig");

/// The fixture launches the app with this log. It is this scenario's own: the
/// grid sets below are only an oracle while every line they see came from this
/// run's app process.
const log_path = "tmp/gui_scrollbind_layers.log";

const scroll_marker = "[layer_row_scroll] gridId=";
const blit_marker = "[layer_blit] gridId=";
const refused_marker = "[layer_blit_refused] gridId=";

/// The whole text area. A layer that shifts wrongly moves content anywhere in
/// its own rectangle, and the four rectangles cover the frame.
const region: visual.Region = .{};

const crop: driver.capture.Crop = .{ .w_pt = 600, .h_pt = 300 };

const steps: usize = 4;
const step_settle_ms = 300;

/// Widths of the two left splits, in columns. Pinned rather than left to
/// `:vsplit`, which halves the CURRENT width — and the app autosaves its frame,
/// so a scenario earlier in the suite that resized the window decides where a
/// bare vsplit puts the dividers.
const split_width_cols: i64 = 30;

/// The float over the middle split, in editor coordinates. `col` sits inside the
/// middle window (which spans columns split_width_cols+1 .. 2*split_width_cols),
/// and `height` is deliberately far below a split's so a step both accept has to
/// be small.
const float_row: i64 = 4;
const float_col: i64 = split_width_cols + 4;
const float_width_cols: i64 = 20;
const float_height_rows: i64 = 8;

/// Windows expected to scroll: three splits plus the float, every one of them a
/// layer, every one of them scrollbound.
const scrolled_windows: usize = 4;

/// Windows expected to BLIT: the three splits. They stand side by side, so no
/// split's rectangle can intersect another's, and each blits on its own.
///
/// The float does not: its rectangle sits inside the middle split's, the splits
/// are lower in the back-to-front layer order and are therefore accepted first,
/// and all accepted blits share one encoder — so a float blit would copy pixels
/// the split's shift had already moved. The frontend refuses it as "overlap"
/// and redraws the float's whole region instead.
///
/// This is a pin on that policy, not on the pixels: measured with the overlap
/// rung deleted, the float blits and the screen is still right, because
/// markLayersOverBlit has already marked every row of the float for repaint (it
/// lies entirely inside the split's blit rectangle) and that repaint lands on
/// top of whatever the float's own blit moved. A geometry where the float only
/// partly overlapped would leave the unmarked rows exposed. So this assertion
/// exists to make removing the rung a decision someone has to defend, and the
/// pixel oracle below is not a substitute for it.
const blitting_windows: usize = 3;

const max_grids = 16;

const GridSet = struct {
    ids: [max_grids]f64 = undefined,
    n: usize = 0,

    fn add(self: *GridSet, id: f64) void {
        if (std.mem.indexOfScalar(f64, self.ids[0..self.n], id) != null) return;
        if (self.n == max_grids) return;
        self.ids[self.n] = id;
        self.n += 1;
    }

    fn has(self: GridSet, id: f64) bool {
        return std.mem.indexOfScalar(f64, self.ids[0..self.n], id) != null;
    }

    fn report(self: GridSet, label: []const u8) void {
        std.debug.print("[gui] scrollbind_layers: {s} = {{", .{label});
        for (self.ids[0..self.n], 0..) |id, i| {
            std.debug.print("{s}{d:.0}", .{ if (i == 0) "" else ", ", id });
        }
        std.debug.print("}} ({d})\n", .{self.n});
    }
};

/// The grid ids named on lines containing `marker` since `since_ms`, restricted
/// to lines that also contain `require` when it is non-empty.
fn gridsWith(alloc: std.mem.Allocator, marker: []const u8, require: []const u8, since_ms: f64) !GridSet {
    const lines = try app_log.linesSince(alloc, log_path, marker, since_ms);
    defer alloc.free(lines);

    var out: GridSet = .{};
    var it = std.mem.splitScalar(u8, lines, '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        if (require.len > 0 and std.mem.indexOf(u8, line, require) == null) continue;
        const id = app_log.field(line, "gridId") orelse continue;
        out.add(id);
    }
    return out;
}

pub fn run(alloc: std.mem.Allocator) !void {
    try fixture.requireScreenAccess();
    std.Io.Dir.cwd().createDirPath(gui_io.io(), "tmp") catch {};
    std.Io.Dir.cwd().deleteFile(gui_io.io(), log_path) catch {};

    var g = try fixture.openWithLog(alloc, log_path);
    defer g.deinit();

    try g.exec("execute('set laststatus=0 noruler noshowcmd showtabline=0 scrolloff=0 nowrap noswapfile')");
    // A blinking cursor alone produces a false diff between the two captures.
    try g.exec("execute('set guicursor=a:block-blinkon0')");

    // Every line differs across the full width, so a wrongly shifted row shows
    // instead of matching whatever it landed on.
    try g.exec(
        \\setline(1, map(range(1, 400), {_, i -> printf('%3d %s', i, repeat(nr2char(65 + i % 26), 60))}))
    );

    const total_cols = try g.evalInt("&columns");
    const need_cols = split_width_cols * 2 + 12;
    if (total_cols < need_cols) {
        std.debug.print(
            "[gui] scrollbind_layers: window is {d} cols, need at least {d} for three splits\n",
            .{ total_cols, need_cols },
        );
        return error.WindowTooNarrow;
    }

    // Three vertical splits. Each fails the core's full-width row-scroll fast
    // path check, so each window is drawn as its own layer.
    try g.exec("execute('vsplit')");
    try g.exec("execute('vsplit')");
    var resize_buf: [96]u8 = undefined;
    try g.exec("execute('1wincmd w')");
    try g.exec(try std.fmt.bufPrint(&resize_buf, "execute('vertical resize {d}')", .{split_width_cols}));
    try g.exec("execute('2wincmd w')");
    try g.exec(try std.fmt.bufPrint(&resize_buf, "execute('vertical resize {d}')", .{split_width_cols}));

    // A float over the MIDDLE split, with its own 400 lines so scrollbind can
    // actually move it, and content that does not match the split underneath so
    // a row of either landing in the other's rectangle is visible.
    var float_buf: [512]u8 = undefined;
    const float_cmd = try std.fmt.bufPrint(
        &float_buf,
        "luaeval('(function() local b = vim.api.nvim_create_buf(false, true) local t = {{}} for i = 1, 400 do t[i] = string.format(\"F%03d %s\", i, string.rep(string.char(97 + i % 26), 14)) end vim.api.nvim_buf_set_lines(b, 0, -1, false, t) vim.api.nvim_open_win(b, false, {{relative=\"editor\", row={d}, col={d}, width={d}, height={d}, style=\"minimal\"}}) return 1 end)()')",
        .{ float_row, float_col, float_width_cols, float_height_rows },
    );
    try g.exec(float_cmd);

    // scrollbind per window HANDLE: `:windo` walks only the split layout and
    // would skip the float, which is exactly the window this scenario needs
    // scrolling. Same for 'scroll', so no window can choose a bigger step than
    // the fast path accepts.
    try g.exec(
        \\luaeval('(function() for _, h in ipairs(vim.api.nvim_list_wins()) do vim.api.nvim_set_option_value("scrollbind", true, {win = h}) vim.api.nvim_set_option_value("scroll", 3, {win = h}) vim.api.nvim_set_option_value("wrap", false, {win = h}) end return 1 end)()')
    );

    try g.exec("execute('1wincmd w')");
    try g.exec("execute('normal! 100Gzt0')");
    try g.exec("execute('syncbind')");

    // Warm-up, then back where it started. A commit that places a layer at a
    // rectangle it did not have before drops that layer's staged shift and
    // marks it fully dirty, so a scroll issued while the layout is still
    // settling produces no blit at all — observed once as zero blits over all
    // four steps. Spending one scroll outside the measured window keeps that
    // out of the gates below.
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

    // Which grids took the core's row-shift fast path, and which of those the
    // frontend actually blitted. Sets, not counts: the driver cannot ask Neovim
    // for a grid id, so the assertion must not care which id is which.
    const scrolled = try gridsWith(alloc, scroll_marker, "", t_scroll);
    const blitted = try gridsWith(alloc, blit_marker, "", t_scroll);
    const overlap_refused = try gridsWith(alloc, refused_marker, "reason=overlap", t_scroll);
    scrolled.report("row-shift fast path");
    blitted.report("blitted");
    overlap_refused.report("refused as overlapping");
    {
        // The refusals, for the human reading a failure: which layer declined
        // and why is the first thing worth knowing.
        const lines = try app_log.linesSince(alloc, log_path, refused_marker, t_scroll);
        defer alloc.free(lines);
        var it = std.mem.splitScalar(u8, lines, '\n');
        while (it.next()) |line| {
            if (line.len == 0) continue;
            const at = std.mem.indexOf(u8, line, refused_marker) orelse continue;
            std.debug.print("[gui] scrollbind_layers: {s}\n", .{line[at..]});
        }
    }

    if (scrolled.n != scrolled_windows) {
        std.debug.print(
            "[gui] scrollbind_layers: {d} layers took the row-shift fast path, expected {d} — the multi-layer case this guards did not arm\n",
            .{ scrolled.n, scrolled_windows },
        );
        return error.NotEveryWindowScrolled;
    }
    if (blitted.n != blitting_windows) {
        std.debug.print(
            "[gui] scrollbind_layers: {d} layers blitted, expected {d} (the splits, not the float)\n",
            .{ blitted.n, blitting_windows },
        );
        return error.WrongLayersBlitted;
    }
    for (blitted.ids[0..blitted.n]) |id| {
        if (scrolled.has(id)) continue;
        std.debug.print(
            "[gui] scrollbind_layers: gridId={d:.0} blitted without a row-shift hint — the frontend shifted pixels the core did not remap slots for\n",
            .{id},
        );
        return error.BlitWithoutRowScroll;
    }
    // Everything that scrolled without blitting must say so, and say why. A
    // layer that silently dropped its shift for some other reason would leave
    // this scenario measuring a frame that never took the path it is about.
    for (scrolled.ids[0..scrolled.n]) |id| {
        if (blitted.has(id) or overlap_refused.has(id)) continue;
        std.debug.print(
            "[gui] scrollbind_layers: gridId={d:.0} scrolled but neither blitted nor refused as overlapping\n",
            .{id},
        );
        return error.LayerNeitherBlittedNorOverlapped;
    }

    const moved = visual.regionDiffRatio(before, incremental, region, 6);
    if (moved <= 0.0002) {
        std.debug.print(
            "[gui] scrollbind_layers: {d} scroll steps did not change the screen ({d:.4}) — test would be vacuous\n",
            .{ steps, moved },
        );
        return error.ScrollDidNotRender;
    }

    const topline = try g.evalInt("line('w0')");
    std.debug.print(
        "[gui] scrollbind_layers: topline={d} scroll moved {d:.4} of the frame\n",
        .{ topline, moved },
    );

    // The same view reached by a jump. scrollbind carries every bound window
    // with the current one, so all four layers are repainted from scratch.
    try g.exec("execute('normal! 1Gzt0')");
    try g.exec("execute('syncbind')");
    var settled = try g.captureStable(crop, 8000);
    settled.deinit(alloc);
    var jump_buf: [64]u8 = undefined;
    const jump_cmd = try std.fmt.bufPrint(&jump_buf, "execute('normal! {d}Gzt0')", .{topline});
    try g.exec(jump_cmd);
    try g.exec("execute('syncbind')");
    var jumped = try g.captureStable(crop, 8000);
    defer jumped.deinit(alloc);

    try visual.assertRegionUnchanged(
        alloc,
        "scrollbind_layers_blit_matches_jump",
        jumped,
        incremental,
        region,
        .{},
    );
}
