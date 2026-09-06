// scrolled_layer_row_gating — a window that has scrolled must go back to
// drawing only its dirty rows once the scroll is over.
//
// Regression guard for the retention lifetime. `ScrollRetention` keeps the
// rows a scroll pushed off a window's edge so the band a sub-cell offset
// opens shows the content that left; a layer holding any of them has to
// redraw every row, because an eased frame re-places all of them. Those rows
// were pruned from exactly one place, `updateScrollOffsets`, which the view
// skips entirely once nothing is easing — so a scroll that never installed an
// offset (a multi-row step seeds no ease) left them published forever, and
// the window redrew all 52 of its rows on every frame for the rest of the
// session while the user only moved the cursor.
//
// The oracle is the app's own `[layer_draw] gridId=… rows=… of=…` line: rows=
// counts what that layer actually encoded this frame. The unit test in
// macos/Tests/ScrollRetentionTests.swift pins the prune predicate; this pins
// that the prune is reached from a path that runs on every frame, which is
// the part that was broken and that no predicate test can see.
//
// Both frontends emit [layer_draw] from their per-layer draw loop.

const std = @import("std");
const driver = @import("../../driver.zig");
const fixture = @import("fixture.zig");
const app_log = @import("../../app_log.zig");
const gui_io = @import("../../gui_io.zig");

const log_path = "tmp/gui_scrolled_layer_row_gating.log";
const draw_marker = "[layer_draw] gridId=";
const blit_marker = "[layer_blit] gridId=";
const refused_marker = "[layer_blit_refused] gridId=";

/// Cursor moves in the measured phase. Each one dirties two rows at most.
const cursor_moves = 16;
const max_grids = 16;

/// A frame that re-encodes at least this share of a layer's rows redrew the
/// whole thing rather than the rows it owed. Deliberately far from both
/// measured populations (1 of 52 when the gating works, 54 of 52 when it does
/// not) so this is a live/dead check, not a performance threshold.
const full_redraw_share = 0.5;

const Layer = struct {
    grid_id: f64,
    frames: usize = 0,
    full_frames: usize = 0,
    rows_total: f64 = 0,
    rows_max: f64 = 0,
    of: f64 = 0,
};

/// Accumulate the [layer_draw] lines logged since `since_ms`, one entry per
/// grid, restricted to `only` when it is non-empty.
fn collect(
    alloc: std.mem.Allocator,
    since_ms: f64,
    only: []const f64,
    out: *[max_grids]Layer,
) !usize {
    const lines = try app_log.linesSince(alloc, log_path, draw_marker, since_ms);
    defer alloc.free(lines);

    var n: usize = 0;
    var it = std.mem.splitScalar(u8, lines, '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        const grid_id = app_log.field(line, "gridId") orelse continue;
        const rows = app_log.field(line, "rows") orelse continue;
        const of = app_log.field(line, "of") orelse continue;
        if (only.len > 0 and std.mem.indexOfScalar(f64, only, grid_id) == null) continue;

        var slot: ?*Layer = null;
        for (out[0..n]) |*l| {
            if (l.grid_id == grid_id) slot = l;
        }
        if (slot == null) {
            if (n == max_grids) continue;
            out[n] = .{ .grid_id = grid_id };
            slot = &out[n];
            n += 1;
        }
        const l = slot.?;
        l.frames += 1;
        l.rows_total += rows;
        l.of = of;
        if (rows > l.rows_max) l.rows_max = rows;
        if (of > 0 and rows >= of * full_redraw_share) l.full_frames += 1;
    }
    return n;
}

/// Which grids the app reported a layer scroll for — accepted blit or refused,
/// either way that grid is the one whose retention this scenario is about.
fn scrolledGrids(
    alloc: std.mem.Allocator,
    since_ms: f64,
    out: *[max_grids]f64,
) !usize {
    var n: usize = 0;
    for ([_][]const u8{ blit_marker, refused_marker }) |marker| {
        const lines = try app_log.linesSince(alloc, log_path, marker, since_ms);
        defer alloc.free(lines);
        var it = std.mem.splitScalar(u8, lines, '\n');
        while (it.next()) |line| {
            if (line.len == 0) continue;
            const grid_id = app_log.field(line, "gridId") orelse continue;
            if (std.mem.indexOfScalar(f64, out[0..n], grid_id) != null) continue;
            if (n == max_grids) break;
            out[n] = grid_id;
            n += 1;
        }
    }
    return n;
}

fn nudgeCursor(g: *driver.Gui) !void {
    var i: usize = 0;
    while (i < cursor_moves) : (i += 1) {
        try g.remoteSend(if (i % 2 == 0) "j" else "k");
        gui_io.sleepNs(120 * std.time.ns_per_ms);
    }
    gui_io.sleepNs(800 * std.time.ns_per_ms);
}

pub fn run(alloc: std.mem.Allocator) !void {
    std.Io.Dir.cwd().createDirPath(gui_io.io(), "tmp") catch {};
    std.Io.Dir.cwd().deleteFile(gui_io.io(), log_path) catch {};

    var g = try fixture.openWithLog(alloc, log_path);
    defer g.deinit();

    // A vertical split always fails the core's full-width row-scroll fast
    // path, so its window grid is drawn as a layer and its outgoing rows can
    // only be kept by the retention this scenario measures.
    try g.exec("execute('set laststatus=0 noruler noshowcmd scrolloff=0 nowrap noswapfile')");
    try g.exec(
        \\setline(1, map(range(1, 400), {_, i -> printf('%3d %s', i, repeat(nr2char(65 + i % 26), 60))}))
    );
    try g.exec("execute('vsplit')");
    try g.exec("execute('normal! ggM0')");
    gui_io.sleepNs(1500 * std.time.ns_per_ms);

    // Phase 1: cursor motion on a grid that has never scrolled. This is the
    // reference the defect did not touch, and it proves the oracle can read a
    // quiet layer at all.
    const t_quiet = try app_log.nowMs(alloc, log_path);
    try nudgeCursor(g);
    var quiet_buf: [max_grids]Layer = undefined;
    const quiet_n = try collect(alloc, t_quiet, &.{}, &quiet_buf);
    var quiet_full: usize = 0;
    var quiet_frames: usize = 0;
    var tallest: f64 = 0;
    for (quiet_buf[0..quiet_n]) |l| {
        quiet_full += l.full_frames;
        quiet_frames += l.frames;
        if (l.of > tallest) tallest = l.of;
    }
    std.debug.print(
        "[gui] scrolled_layer_row_gating: before any scroll, {d} layer frames, {d} full redraws, tallest layer {d:.0} rows\n",
        .{ quiet_frames, quiet_full, tallest },
    );
    if (quiet_frames < cursor_moves or tallest < 8) {
        std.debug.print(
            "[gui] scrolled_layer_row_gating: too few layer draws to measure — test would be vacuous\n",
            .{},
        );
        return error.NoLayerDraws;
    }

    // The scroll itself: more than one row, so no ease seed is staged and the
    // grid is never displaced. That is the shape that leaked.
    const t_scroll = try app_log.nowMs(alloc, log_path);
    const topline_before = try g.evalInt("luaeval('vim.fn.line(\"w0\")')");
    var step: usize = 0;
    while (step < 3) : (step += 1) {
        try g.remoteSend("3<C-e>");
        gui_io.sleepNs(700 * std.time.ns_per_ms);
    }
    gui_io.sleepNs(1500 * std.time.ns_per_ms);
    const topline_after = try g.evalInt("luaeval('vim.fn.line(\"w0\")')");

    var scrolled_buf: [max_grids]f64 = undefined;
    const scrolled_n = try scrolledGrids(alloc, t_scroll, &scrolled_buf);
    std.debug.print(
        "[gui] scrolled_layer_row_gating: topline {d} -> {d}, {d} layer(s) scrolled\n",
        .{ topline_before, topline_after, scrolled_n },
    );
    if (topline_after == topline_before or scrolled_n == 0) {
        std.debug.print(
            "[gui] scrolled_layer_row_gating: nothing scrolled — the leak this guards cannot arm\n",
            .{},
        );
        return error.NoLayerScroll;
    }

    // Phase 2: the same cursor motion on the grid that has now scrolled.
    try g.exec("execute('normal! M0')");
    gui_io.sleepNs(1000 * std.time.ns_per_ms);
    const t_after = try app_log.nowMs(alloc, log_path);
    try nudgeCursor(g);
    var after_buf: [max_grids]Layer = undefined;
    const after_n = try collect(alloc, t_after, scrolled_buf[0..scrolled_n], &after_buf);

    var failed = false;
    for (after_buf[0..after_n]) |l| {
        const per_frame = if (l.frames == 0) 0 else l.rows_total / @as(f64, @floatFromInt(l.frames));
        std.debug.print(
            "[gui] scrolled_layer_row_gating: gridId={d:.0} of={d:.0} frames={d} rows/frame={d:.2} max={d:.0} full redraws={d}\n",
            .{ l.grid_id, l.of, l.frames, per_frame, l.rows_max, l.full_frames },
        );
        if (l.frames < cursor_moves) {
            std.debug.print(
                "[gui] scrolled_layer_row_gating: gridId={d:.0} drew too few frames to judge\n",
                .{l.grid_id},
            );
            failed = true;
            continue;
        }
        // The defect made EVERY frame a full redraw; correct gating makes
        // none of them one. Half is the midpoint between those populations.
        if (@as(f64, @floatFromInt(l.full_frames)) >
            @as(f64, @floatFromInt(l.frames)) * full_redraw_share)
        {
            std.debug.print(
                "[gui] a scrolled layer kept redrawing every row while only the cursor moved\n",
                .{},
            );
            failed = true;
        }
    }
    if (after_n == 0) {
        std.debug.print(
            "[gui] scrolled_layer_row_gating: the scrolled layer drew nothing — test would be vacuous\n",
            .{},
        );
        return error.NoLayerDraws;
    }
    if (failed) return error.ScrolledLayerRedrawsEveryRow;
}
