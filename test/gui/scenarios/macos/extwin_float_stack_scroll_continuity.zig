// extwin_float_stack_scroll_continuity — the external-surface half of
// float_stack_scroll_continuity.
//
// A bufpos-anchored float follows the window it hangs off as that window
// scrolls: Neovim re-places it through win_float_pos, and the frontend
// withholds the part of the anchor's compensation the float's own placement
// has not performed yet (the float debt ledger). On the MAIN surface that
// subtraction happens at the committed snapshot, where the placement a frame
// DRAWS and the counter describing it are the same commit.
//
// An external surface reaches the same ledger through
// MetalTerminalView.floatDebtPx, which reads `placementRowsUpScratch` — a copy
// taken before the flush that publishes a placement, while the layer snapshot
// is latched after it. That is the same one-commit skew the main surface had,
// and it produced a whole 'mousescroll' step of jump there.
//
// Asserted the same way as the main scenario, from the app's own
// `[ext_layer_draw]` line: a float's drawn Y must not move a whole cell within
// one frame period. The threshold scales with the gap actually measured,
// because a time-based ease legitimately advances further when the app misses
// a vsync — see the main scenario for why that is not this test's business.
//
// macOS-only: ExternalGridView hosts the layer and drives the gesture.

const std = @import("std");
const driver = @import("../../driver.zig");
const platform = driver.platform;
const Gui = driver.Gui;
const gui_io = @import("../../gui_io.zig");
const app_log = @import("../../app_log.zig");

const log_path = "tmp/gui_extwin_float_stack.log";
const draw_marker = "[ext_layer_draw]";
const cell_marker = "[ext_draw_debug]";
const max_windows = 16;

/// The host window's grid, in cells. Wide and tall enough that the floats
/// below stack inside it and the trackpad gesture lands on content.
const host_cols: i64 = 80;
const host_rows: i64 = 30;

const float_count = 4;
const float_stride_lines = 3;
const float_first_line = 4;
const float_rows: i64 = 2;
const float_cols: i64 = 30;

const steps_per_round: u32 = 6;
const rounds: u32 = 6;
/// One row per keypress, spaced so the sub-row ease has paid the previous row
/// down before the next arrives. Pressed faster the offset accumulates to two
/// or three rows and its first decay step alone exceeds a cell — a property of
/// the ease, on either surface, and not what this scenario is about.
const step_interval_ms: u64 = 150;

/// Violations tolerated before the run is called a failure. Matches the main
/// scenario: a frame can be missed or doubled by the capture clock.
const jump_threshold: usize = 2;

fn newWindow(pid: i32, before: []const platform.MainWindow, min_side: f64) ?platform.MainWindow {
    var buf: [max_windows]platform.MainWindow = undefined;
    const now = buf[0..platform.windowsForPid(pid, &buf)];
    outer: for (now) |w| {
        for (before) |b| {
            if (b.number == w.number) continue :outer;
        }
        if (w.bounds.w < min_side or w.bounds.h < min_side) continue;
        return w;
    }
    return null;
}

fn topmostWindowAt(pid: i32, x: f64, y: f64) ?platform.MainWindow {
    var buf: [max_windows]platform.MainWindow = undefined;
    for (buf[0..platform.windowsForPid(pid, &buf)]) |w| {
        if (x >= w.bounds.x and x < w.bounds.x + w.bounds.w and
            y >= w.bounds.y and y < w.bounds.y + w.bounds.h) return w;
    }
    return null;
}

fn waitNewWindow(pid: i32, before: []const platform.MainWindow, min_side: f64) !platform.MainWindow {
    var timer = gui_io.Timer.start();
    while (true) {
        if (newWindow(pid, before, min_side)) |w| return w;
        if (timer.read() / std.time.ns_per_ms >= 10_000) {
            platform.dumpWindowsForPid(pid);
            return error.ExternalWindowNotFound;
        }
        gui_io.sleepNs(100 * std.time.ns_per_ms);
    }
}

/// Cell height in pixels, from the surface's own draw line: it reports the
/// cell-snapped viewport and the rows it was snapped to, and their ratio is
/// the cell height the layer geometry is built from. Read rather than assumed,
/// because it depends on the font the host happens to resolve.
fn cellHeightPx(alloc: std.mem.Allocator, since_ms: f64) !f64 {
    const line = (try app_log.lastLineSince(alloc, log_path, cell_marker, since_ms)) orelse
        return error.NoCellHeightLogged;
    defer alloc.free(line);
    const vp_h = app_log.field(line, "vpH") orelse return error.CellHeightUnparsable;
    const rows = app_log.field(line, "snapRows") orelse return error.CellHeightUnparsable;
    if (vp_h <= 0 or rows <= 0) return error.CellHeightUnparsable;
    return vp_h / rows;
}

const Tally = struct {
    jumps: usize = 0,
    displaced: usize = 0,
    replacements: usize = 0,
    grids: usize = 0,
    worst: f64 = 0,
    period_ms: f64 = 0,
    late: usize = 0,
};

/// The median gap between consecutive drawn frames of ONE layer — every layer
/// of a frame is logged microseconds after the one before it, so taking all
/// the lines would put the median at zero.
fn framePeriodMs(alloc: std.mem.Allocator, lines: []const u8) !f64 {
    var gaps: std.ArrayList(f64) = .empty;
    defer gaps.deinit(alloc);
    var prev: ?f64 = null;
    var only_grid: ?f64 = null;
    var it = std.mem.splitScalar(u8, lines, '\n');
    while (it.next()) |line| {
        const grid = app_log.field(line, "gridId") orelse continue;
        if (only_grid == null) only_grid = grid;
        if (grid != only_grid.?) continue;
        const ts = app_log.lineTimestampMs(line) orelse continue;
        if (prev) |p| {
            const gap = ts - p;
            if (gap > 0) try gaps.append(alloc, gap);
        }
        prev = ts;
    }
    if (gaps.items.len == 0) return 0;
    std.mem.sort(f64, gaps.items, {}, std.sort.asc(f64));
    return gaps.items[gaps.items.len / 2];
}

/// Walk the `[ext_layer_draw]` series and fold it per grid. Every field is
/// required: a silently skipped line would make the assertion vacuous.
fn tally(alloc: std.mem.Allocator, since_ms: f64, cell_px: f64) !Tally {
    const lines = try app_log.linesSince(alloc, log_path, draw_marker, since_ms);
    defer alloc.free(lines);

    var prev_draw = std.AutoHashMap(i64, f64).init(alloc);
    defer prev_draw.deinit();
    var prev_draw_ms = std.AutoHashMap(i64, f64).init(alloc);
    defer prev_draw_ms.deinit();
    var prev_committed = std.AutoHashMap(i64, f64).init(alloc);
    defer prev_committed.deinit();
    var seen = std.AutoHashMap(i64, void).init(alloc);
    defer seen.deinit();

    var t = Tally{};
    t.period_ms = try framePeriodMs(alloc, lines);
    if (t.period_ms <= 0) return t;

    var it = std.mem.splitScalar(u8, lines, '\n');
    while (it.next()) |line| {
        const grid_f = app_log.field(line, "gridId") orelse continue;
        const now_ms = app_log.lineTimestampMs(line) orelse continue;
        const moved = app_log.field(line, "moved") orelse continue;
        const committed = app_log.field(line, "committedY") orelse continue;
        const draw = app_log.field(line, "drawY") orelse continue;
        const grid: i64 = @intFromFloat(grid_f);

        if (prev_committed.get(grid)) |p| {
            if (@abs(committed - p) >= cell_px / 2) t.replacements += 1;
        }
        try prev_committed.put(grid, committed);

        if (moved < 0.5) {
            _ = prev_draw.remove(grid);
            _ = prev_draw_ms.remove(grid);
            continue;
        }
        t.displaced += 1;
        if (!seen.contains(grid)) {
            try seen.put(grid, {});
            t.grids += 1;
        }
        if (prev_draw.get(grid)) |p| {
            const jump = @abs(draw - p);
            if (jump > t.worst) t.worst = jump;
            const elapsed = now_ms - (prev_draw_ms.get(grid) orelse now_ms);
            const scale = @max(1.0, elapsed / t.period_ms);
            if (elapsed > t.period_ms * 1.5) t.late += 1;
            if (jump >= cell_px * scale) t.jumps += 1;
        }
        try prev_draw.put(grid, draw);
        try prev_draw_ms.put(grid, now_ms);
    }
    return t;
}

/// No grid an external window composites may appear in the MAIN renderer's
/// float-debt ledger.
///
/// Both surfaces log `[float_debt]`; only the external one's line carries
/// `surface=`. A grid id on both lists means the main renderer built a scroll
/// offset for a float it does not draw -- and then a debt against it that
/// diverges without bound, because its own placement counter never moves for a
/// layer it never places. `appendFloatScrollOffsets` walked every visible grid
/// and asked only `zindex > 0`, which is true of a float whatever window draws
/// it.
///
/// Read over the whole log: the scenario deletes it at startup, so every line
/// in it is this run's, and a window bounded by a timestamp could exclude the
/// external surface's lines, which land on the first displaced frame.
fn assertLedgerIsPerSurface(alloc: std.mem.Allocator) !void {
    const lines = try app_log.linesSince(alloc, log_path, "[float_debt]", 0);
    defer alloc.free(lines);

    var hosted = std.AutoHashMap(i64, void).init(alloc);
    defer hosted.deinit();
    var on_main = std.AutoHashMap(i64, void).init(alloc);
    defer on_main.deinit();

    var it = std.mem.splitScalar(u8, lines, '\n');
    while (it.next()) |line| {
        const gid = app_log.field(line, "gridId") orelse continue;
        const id: i64 = @intFromFloat(gid);
        if (app_log.field(line, "surface") != null) {
            try hosted.put(id, {});
        } else {
            try on_main.put(id, {});
        }
    }

    // Anti-vacuity: with no external-surface line there is nothing to compare,
    // and an empty left side would pass on a run where the floats never
    // reached the external surface's ledger at all.
    if (hosted.count() == 0) {
        std.debug.print(
            "[gui] no hosted float reached the external surface's float ledger — " ++
                "nothing to compare the main renderer's against\n",
            .{},
        );
        return error.NoHostedFloatLedger;
    }

    var bad: usize = 0;
    var keys = hosted.keyIterator();
    while (keys.next()) |gid| {
        if (!on_main.contains(gid.*)) continue;
        bad += 1;
        std.debug.print(
            "[gui] grid {d} is composited by the external window, yet the main renderer " ++
                "keeps a scroll offset and a float-debt ledger for it\n",
            .{gid.*},
        );
    }
    if (bad != 0) return error.MainLedgerHoldsForeignGrid;
}

pub fn run(alloc: std.mem.Allocator) !void {
    if (!platform.accessibilityTrusted()) {
        std.debug.print(
            "[gui] skipped: not trusted for Accessibility, so scroll gestures cannot " ++
                "target the external window.\n",
            .{},
        );
        return error.SkipZigTest;
    }

    std.Io.Dir.cwd().createDirPath(gui_io.io(), "tmp") catch {};
    std.Io.Dir.cwd().deleteFile(gui_io.io(), log_path) catch {};

    // No shader fixture: the hosted-layer path this measures runs in
    // drawHostedLayers, which does not go through the custom-shader chain, and
    // that fixture's translucent window changed where a posted scroll landed.
    var g = try Gui.init(alloc, .{ .app_args = &.{ "--log", log_path } });
    defer g.deinit();
    g.activateApp();
    gui_io.sleepNs(700 * std.time.ns_per_ms);

    var before_buf: [max_windows]platform.MainWindow = undefined;
    const before = before_buf[0..platform.windowsForPid(g.app_pid, &before_buf)];
    const before_count = before.len;

    // The host: an external window with far more lines than it shows.
    var host_buf: [512]u8 = undefined;
    const open_host = try std.fmt.bufPrint(
        &host_buf,
        "luaeval('(function() local b = vim.api.nvim_create_buf(false, true) local l = {{}} " ++
            "for i = 1, 800 do l[i] = string.rep(\"line \" .. i .. \" \", 6) end " ++
            "vim.api.nvim_buf_set_lines(b, 0, -1, true, l) " ++
            "_G.z_anchor = vim.api.nvim_open_win(b, true, " ++
            "{{external=true, width={d}, height={d}}}) return 1 end)()')",
        .{ host_cols, host_rows },
    );
    try g.exec(open_host);
    _ = try waitNewWindow(g.app_pid, before, 100);
    gui_io.sleepNs(700 * std.time.ns_per_ms);

    // A stack of bufpos-anchored floats over it, unfocused so the wheel
    // scrolls the host underneath rather than a float's own contents.
    var buf: [1024]u8 = undefined;
    const open_floats = try std.fmt.bufPrint(
        &buf,
        "luaeval('(function() _G.z_floats = {{}} " ++
            "for k = 0, {d} do " ++
            "local b = vim.api.nvim_create_buf(false, true) " ++
            "vim.api.nvim_buf_set_lines(b, 0, -1, true, {{\"float \" .. k, \"anchored\"}}) " ++
            "_G.z_floats[k + 1] = vim.api.nvim_open_win(b, false, " ++
            "{{relative=\"win\", win=_G.z_anchor, bufpos={{{d} + k * {d}, 0}}, " ++
            "row=0, col=2, width={d}, height={d}, focusable=false, zindex=50, " ++
            "style=\"minimal\"}}) end return 1 end)()')",
        .{ float_count - 1, float_first_line, float_stride_lines, float_cols, float_rows },
    );
    try g.exec(open_floats);
    gui_io.sleepNs(800 * std.time.ns_per_ms);

    if (try g.evalInt("luaeval('#_G.z_floats')") != float_count) {
        return error.FloatsNotOpen;
    }
    // Gate: the floats have to be composited INTO the external window. One
    // given a window of its own is drawn by its own surface root and would
    // test the path this scenario is not about.
    if (try g.evalInt("luaeval('(vim.api.nvim_win_get_config(_G.z_floats[1]).win == _G.z_anchor) and 1 or 0')") != 1) {
        return error.FloatNotAnchoredToExternal;
    }
    const window_count = platform.windowsForPid(g.app_pid, &before_buf);
    if (window_count != before_count + 1) {
        std.debug.print(
            "[gui] expected the floats to be composited into the external window, but the " ++
                "app has {d} windows (was {d} plus the host)\n",
            .{ window_count, before_count },
        );
        return error.FloatGotItsOwnWindow;
    }

    // Focus the host and scroll it from the KEYBOARD. A posted trackpad
    // gesture would have to win a targeting race with the main window — the
    // driver warps to a window centre and macOS delivers to the frontmost
    // window of the frontmost APPLICATION there — and none of that is what
    // this measures. `<C-e>` moves the host's content through the same
    // grid_scroll and the same sub-row ease, which is what displaces a
    // following float.
    try g.exec("luaeval('(function() vim.api.nvim_set_current_win(_G.z_anchor) return 1 end)()')");
    gui_io.sleepNs(600 * std.time.ns_per_ms);

    const t0 = try app_log.nowMs(alloc, log_path);

    // An arming scroll, so the surface draws a displaced layer once before the
    // measured rounds start.
    try g.remoteSend("<C-e>");
    gui_io.sleepNs(500 * std.time.ns_per_ms);

    var cell_px: f64 = 0;
    var tries: u32 = 0;
    while (tries < 50) : (tries += 1) {
        if (cellHeightPx(alloc, t0)) |c| {
            cell_px = c;
            break;
        } else |_| {}
        gui_io.sleepNs(100 * std.time.ns_per_ms);
    }
    if (cell_px <= 0) return error.NoCellHeightLogged;
    gui_io.sleepNs(500 * std.time.ns_per_ms);

    const t1 = try app_log.nowMs(alloc, log_path);

    // Alternating rounds: a reversal mid-ease is the case that broke an
    // earlier attempt at the main surface's fix, so it belongs here too.
    var round: u32 = 0;
    while (round < rounds) : (round += 1) {
        const key = if (round % 2 == 0) "<C-e>" else "<C-y>";
        var n: u32 = 0;
        while (n < steps_per_round) : (n += 1) {
            try g.remoteSend(key);
            gui_io.sleepNs(step_interval_ms * std.time.ns_per_ms);
        }
        gui_io.sleepNs(400 * std.time.ns_per_ms);
    }

    const t = try tally(alloc, t1, cell_px);
    std.debug.print(
        "[gui] extwin float stack: cell={d:.1}px period={d:.1}ms displaced_frames={d} late={d} " ++
            "grids={d} replacements={d} jumps={d} worst={d:.1}px\n",
        .{ cell_px, t.period_ms, t.displaced, t.late, t.grids, t.replacements, t.jumps, t.worst },
    );

    // Anti-vacuity gates, the same four the main scenario names.
    if (t.period_ms <= 0) {
        std.debug.print("[gui] no frame period could be measured — nothing was drawn\n", .{});
        return error.TooFewDisplacedFrames;
    }
    if (t.displaced < 40) {
        std.debug.print("[gui] too few displaced frames — the ease never ran\n", .{});
        return error.TooFewDisplacedFrames;
    }
    if (t.grids < 2) {
        std.debug.print("[gui] fewer than two floats were displaced — not a stack\n", .{});
        return error.FloatStackNotDisplaced;
    }
    if (t.replacements < 2) {
        std.debug.print(
            "[gui] Neovim never re-placed a float — bufpos anchoring is not live, so the " ++
                "split-step path is untested\n",
            .{},
        );
        return error.FloatsNeverReplaced;
    }

    try assertLedgerIsPerSurface(alloc);

    if (t.jumps > jump_threshold) {
        std.debug.print(
            "[gui] a hosted float's drawn Y jumped a whole cell {d} times within one frame " ++
                "period (worst {d:.1}px, cell {d:.1}px, period {d:.1}ms)\n",
            .{ t.jumps, t.worst, cell_px, t.period_ms },
        );
        return error.FloatPositionDiscontinuous;
    }
}
