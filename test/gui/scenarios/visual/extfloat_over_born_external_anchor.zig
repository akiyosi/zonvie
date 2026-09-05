// visual/extfloat_over_born_external_anchor — a float anchored to an external
// window must reach the screen whichever way the window became external.
//
// An external grid has two origins, and only one leaves a position behind.
// Split-then-detach sends `win_pos` before `win_external_pos`, so
// `Grid.setWinExternalPos` copies that entry into ExternalGridInfo.start_row.
// A window born external — `nvim_open_win(buf, true, {external=true, ...})` —
// never gets a `win_pos`, and `win_external_pos` carries only grid and win, so
// start_row keeps its -1 initialiser.
//
// A float anchored to an external window is drawn by exactly one path: it is
// NOT a main-surface layer (`collectMainLayerEntries` skips a float whose
// anchor is external) and it gets no OS window of its own; it is composited
// into the anchor's own rows. Both halves of that compositing bail out on a
// negative start_row — `Grid.dirtyCompositedRow` returns before marking a row,
// `buildExternalFloatRowIndexWithLimits` returns before building the index —
// which would leave the float drawn by nobody.
//
// The oracle is what a user would see: opening the float changes the anchor's
// OS window pixels. Arm B — the same float over an anchor externalized the
// other way, the route `extfloat_over_scrolled_anchor` already relies on — is
// the control that says what "visible" looks like on this host. Arm A is the
// claim. Without the control, Arm A's number would be an observation rather
// than a proof: a zero could just as easily mean the capture missed.
//
// Each arm also scrolls its anchor BEFORE opening the float. A born-external
// window that painted nothing at all would make "the float is invisible" the
// wrong question, and that gate separates the two.
//
// start_row itself is not reachable from this driver — it is core state with
// no callback, no log line and no exported getter that reports it directly.
// The headless scenario e2e/born_external_anchor_float measures it (0 on the
// control route, -1 on the suspect route) and asserts the same defect against
// the anchor's dirty set.
//
// macOS-only: it enumerates the app's OS windows to find the external one and
// captures that window rather than the main one.

const std = @import("std");
const driver = @import("../../driver.zig");
const platform = driver.platform;
const capture = driver.capture;
const fixture = @import("fixture.zig");
const visual = @import("../../visual.zig");
const gui_io = @import("../../gui_io.zig");

/// Fraction of the anchor window's pixels the float must change to count as
/// having reached the screen. The float covers 24x6 of the anchor's 60x20
/// cells, so a painted float lands two orders of magnitude above this.
const min_paint_ratio: f64 = 0.002;

/// Width of the scrollbar overlay strip on the right, excluded from every
/// comparison: it is an overlay whose presence depends on how recently the
/// grid scrolled, not on what the rows underneath hold.
const scrollbar_exclude_px: f64 = 48;

const max_windows = 16;

const Route = enum {
    /// nvim_open_win({external=true}) — external from birth, no win_pos ever.
    born_external,
    /// An editor float, settled, then nvim_win_set_config({external=true}) —
    /// the route extfloat_over_scrolled_anchor uses, which does get a win_pos.
    detached_float,
};

const Arm = struct {
    /// Fraction the anchor's window changed when its own text scrolled.
    scroll_paint: f64,
    /// Fraction the anchor's window changed when the float opened.
    float_paint: f64,
    /// The same, after a forced `:redraw!`.
    redraw_paint: f64,
    /// Fraction the anchor's window changed when its text scrolled again,
    /// with the float open.
    post_scroll_paint: f64,
};

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

/// captureStable for a window that is not the app's main one: retry until two
/// consecutive captures are pixel-identical, so a frame caught mid-present is
/// never what a comparison sees.
fn captureWindowStable(alloc: std.mem.Allocator, window_number: u32, timeout_ms: u64) !capture.Image {
    var timer = gui_io.Timer.start();
    var prev: ?capture.Image = null;
    defer if (prev) |*p| p.deinit(alloc);
    while (true) {
        gui_io.sleepNs(150 * std.time.ns_per_ms);
        const cur = capture.captureWindow(alloc, window_number) catch |e| {
            if (timer.read() / std.time.ns_per_ms >= timeout_ms) return e;
            continue;
        };
        if (prev) |*p| {
            if (p.w == cur.w and p.h == cur.h and std.mem.eql(u8, p.rgba, cur.rgba)) {
                p.deinit(alloc);
                prev = null;
                return cur;
            }
            p.deinit(alloc);
            prev = null;
        }
        prev = cur;
        if (timer.read() / std.time.ns_per_ms >= timeout_ms) {
            const out = prev.?;
            prev = null;
            return out; // last capture even if not fully settled
        }
    }
}

/// The window minus the scrollbar strip. Derived from the capture rather than
/// hardcoded as a fraction, so it excludes the same pixels at any window size.
fn bodyRegion(img: capture.Image) visual.Region {
    const w: f64 = @floatFromInt(img.w);
    if (w <= scrollbar_exclude_px) return .{};
    return .{ .x1 = (w - scrollbar_exclude_px) / w };
}

fn runArm(alloc: std.mem.Allocator, route: Route) !Arm {
    // A file left by a crashed earlier run would still be appended to; give
    // each arm its own so a failure dump names the process that produced it.
    const log_path = switch (route) {
        .born_external => "tmp/gui_extfloat_born_external.log",
        .detached_float => "tmp/gui_extfloat_detached_float.log",
    };
    std.Io.Dir.cwd().createDirPath(gui_io.io(), "tmp") catch {};
    std.Io.Dir.cwd().deleteFile(gui_io.io(), log_path) catch {};

    var g = try fixture.openWithLog(alloc, log_path);
    defer g.deinit();
    g.activateApp();

    // Nothing outside the text area may react to the cursor, or the
    // comparisons would move for reasons unrelated to the float.
    try g.exec("execute('set laststatus=0 noruler noshowcmd showtabline=0 scrolloff=0 nowrap noswapfile')");
    // A blinking cursor alone produces a false diff between two captures.
    try g.exec("execute('set guicursor=a:block-blinkon0')");

    var before_buf: [max_windows]platform.MainWindow = undefined;
    const before_windows = before_buf[0..platform.windowsForPid(g.app_pid, &before_buf)];
    const main_number = (platform.mainWindowForPid(g.app_pid) orelse return error.MainWindowNotFound).number;

    // The anchor's buffer: every line differs across the full width, so the
    // scroll gate below cannot pass on a screen made of similar rows.
    try g.exec(
        \\luaeval('(function() _G.z_buf = vim.api.nvim_create_buf(false, true) local l = {} for i = 1, 400 do l[i] = string.format("%3d %s", i, string.rep(string.char(65 + i % 26), 56)) end vim.api.nvim_buf_set_lines(_G.z_buf, 0, -1, false, l) return 1 end)()')
    );

    switch (route) {
        .born_external => try g.exec(
            \\luaeval('(function() _G.z_anchor = vim.api.nvim_open_win(_G.z_buf, true, {external=true, width=60, height=20}) return 1 end)()')
        ),
        .detached_float => {
            // Opened as an editor float and externalized afterwards, with the
            // placement reaching the core in between: that `win_pos` is what
            // setWinExternalPos copies into start_row.
            try g.exec(
                \\luaeval('(function() _G.z_anchor = vim.api.nvim_open_win(_G.z_buf, true, {relative="editor", row=1, col=1, width=60, height=20}) return 1 end)()')
            );
            gui_io.sleepNs(600 * std.time.ns_per_ms);
            try g.exec(
                \\luaeval('(function() vim.api.nvim_win_set_config(_G.z_anchor, {external=true, width=60, height=20}) return 1 end)()')
            );
        },
    }

    const ext_win = try waitNewWindow(g.app_pid, before_windows, 150);
    if (ext_win.number == main_number) return error.CapturedMainWindow;
    try g.exec("execute('normal! 100Gzt0')");

    // Gate one: the anchor's own window paints. A born-external window that
    // rendered nothing would make everything below a statement about the
    // window rather than about the float.
    var pre_scroll = try captureWindowStable(alloc, ext_win.number, 8000);
    defer pre_scroll.deinit(alloc);
    try g.remoteSend("3<C-e>");
    gui_io.sleepNs(400 * std.time.ns_per_ms);
    var baseline = try captureWindowStable(alloc, ext_win.number, 8000);
    defer baseline.deinit(alloc);
    if (baseline.w != pre_scroll.w or baseline.h != pre_scroll.h) return error.ExternalWindowResized;
    const region = bodyRegion(baseline);
    const scroll_paint = visual.regionDiffRatio(pre_scroll, baseline, region, 6);

    // The float: a solid bright background over the anchor's text, since this
    // measures whether ANY pixels appear rather than which glyphs.
    try g.exec(
        \\luaeval('(function() vim.api.nvim_set_hl(0, "ZProbeFloat", {bg="#ff00ff", fg="#00ff00"}) local b = vim.api.nvim_create_buf(false, true) local l = {} for i = 1, 6 do l[i] = string.rep("#", 24) end vim.api.nvim_buf_set_lines(b, 0, -1, false, l) _G.z_float = vim.api.nvim_open_win(b, false, {relative="win", win=_G.z_anchor, row=6, col=4, width=24, height=6, style="minimal"}) vim.api.nvim_set_option_value("winhighlight", "Normal:ZProbeFloat,NormalFloat:ZProbeFloat,EndOfBuffer:ZProbeFloat", {win=_G.z_float}) return 1 end)()')
    );
    gui_io.sleepNs(800 * std.time.ns_per_ms);

    // Gate two: the float exists in Neovim, anchored to THIS window. A float
    // Neovim never opened, or one relative to the editor, would produce the
    // same zero for a reason that is not the defect.
    if (try g.evalInt("luaeval('vim.api.nvim_win_is_valid(_G.z_float) and 1 or 0')") != 1) {
        return error.FloatNotOpen;
    }
    if (try g.evalInt("luaeval('(vim.api.nvim_win_get_config(_G.z_float).relative == \"win\") and 1 or 0')") != 1) {
        return error.FloatNotRelativeToWin;
    }
    if (try g.evalInt("luaeval('(vim.api.nvim_win_get_config(_G.z_float).win == _G.z_anchor) and 1 or 0')") != 1) {
        return error.FloatNotAnchoredToExternal;
    }

    // Gate three: Neovim's own geometry puts the float strictly inside the
    // anchor, so every float row has an anchor row to land on.
    const f_row = try g.evalInt("luaeval('vim.api.nvim_win_get_config(_G.z_float).row')");
    const f_col = try g.evalInt("luaeval('vim.api.nvim_win_get_config(_G.z_float).col')");
    const f_h = try g.evalInt("luaeval('vim.api.nvim_win_get_height(_G.z_float)')");
    const f_w = try g.evalInt("luaeval('vim.api.nvim_win_get_width(_G.z_float)')");
    const a_h = try g.evalInt("luaeval('vim.api.nvim_win_get_height(_G.z_anchor)')");
    const a_w = try g.evalInt("luaeval('vim.api.nvim_win_get_width(_G.z_anchor)')");
    if (f_row <= 0 or f_row + f_h >= a_h or f_col <= 0 or f_col + f_w >= a_w) {
        std.debug.print(
            "[gui] the float (rows {d}..{d}, cols {d}..{d}) does not sit strictly inside the anchor's {d}x{d}\n",
            .{ f_row, f_row + f_h, f_col, f_col + f_w, a_h, a_w },
        );
        return error.FloatNotOverAnchor;
    }

    // Gate four: the float is composited into the anchor rather than given a
    // window of its own, or "invisible in the anchor" is the wrong question.
    const window_count = platform.windowsForPid(g.app_pid, &before_buf);
    if (window_count != before_windows.len + 1) {
        std.debug.print(
            "[gui] the anchored float took an OS window of its own ({d} windows, expected {d})\n",
            .{ window_count, before_windows.len + 1 },
        );
        return error.FloatTookOwnWindow;
    }

    var with_float = try captureWindowStable(alloc, ext_win.number, 8000);
    defer with_float.deinit(alloc);
    if (with_float.w != baseline.w or with_float.h != baseline.h) return error.ExternalWindowResized;
    const float_paint = visual.regionDiffRatio(baseline, with_float, region, 6);

    // A defect a forced redraw repairs is a different, smaller defect; measure
    // it rather than assume.
    try g.exec("execute('redraw!')");
    gui_io.sleepNs(800 * std.time.ns_per_ms);
    var after_redraw = try captureWindowStable(alloc, ext_win.number, 8000);
    defer after_redraw.deinit(alloc);
    if (after_redraw.w != baseline.w or after_redraw.h != baseline.h) return error.ExternalWindowResized;
    const redraw_paint = visual.regionDiffRatio(baseline, after_redraw, region, 6);

    // Gate five: the window is still live at the end. Everything above was
    // measured from captures of one window number, and a capture that had gone
    // stale would report exactly the same zero as a float nobody drew.
    try g.remoteSend("3<C-e>");
    gui_io.sleepNs(400 * std.time.ns_per_ms);
    var post_scroll = try captureWindowStable(alloc, ext_win.number, 8000);
    defer post_scroll.deinit(alloc);
    if (post_scroll.w != baseline.w or post_scroll.h != baseline.h) return error.ExternalWindowResized;
    const post_scroll_paint = visual.regionDiffRatio(after_redraw, post_scroll, region, 6);

    return .{
        .scroll_paint = scroll_paint,
        .float_paint = float_paint,
        .redraw_paint = redraw_paint,
        .post_scroll_paint = post_scroll_paint,
    };
}

pub fn run(alloc: std.mem.Allocator) !void {
    // A host without screen capture must skip honestly rather than fail from
    // deep inside a capture call.
    try fixture.requireScreenAccess();

    // The control runs first: a control that paints nothing means the harness
    // is broken, and the suspect's number would say nothing about the product.
    const control = try runArm(alloc, .detached_float);
    std.debug.print(
        "[gui] extfloat_over_born_external_anchor: control (detached float)  scroll={d:.4} float={d:.4} redraw={d:.4} post_scroll={d:.4}\n",
        .{ control.scroll_paint, control.float_paint, control.redraw_paint, control.post_scroll_paint },
    );
    if (control.scroll_paint <= min_paint_ratio) {
        std.debug.print("[gui] the control anchor's window did not paint its own scroll; the harness is broken\n", .{});
        return error.ControlAnchorDidNotPaint;
    }
    if (control.float_paint <= min_paint_ratio) {
        std.debug.print(
            "[gui] the control float changed {d:.4} of its anchor's window, below {d:.4}: the harness cannot see " ++
                "a float that IS drawn, so it cannot prove one is not\n",
            .{ control.float_paint, min_paint_ratio },
        );
        return error.ControlFloatNotOnScreen;
    }

    const suspect = try runArm(alloc, .born_external);
    std.debug.print(
        "[gui] extfloat_over_born_external_anchor: suspect (born external)   scroll={d:.4} float={d:.4} redraw={d:.4} post_scroll={d:.4}\n",
        .{ suspect.scroll_paint, suspect.float_paint, suspect.redraw_paint, suspect.post_scroll_paint },
    );
    if (suspect.scroll_paint <= min_paint_ratio or suspect.post_scroll_paint <= min_paint_ratio) {
        std.debug.print(
            "[gui] the born-external window did not paint its own scroll (before {d:.4}, after {d:.4}); the anchor " ++
                "itself is inert, which is a larger defect than the one under test\n",
            .{ suspect.scroll_paint, suspect.post_scroll_paint },
        );
        return error.BornExternalAnchorDidNotPaint;
    }

    if (suspect.float_paint > min_paint_ratio) return; // the float is drawn

    if (suspect.redraw_paint > min_paint_ratio) {
        std.debug.print(
            "[gui] a float over an anchor born external changed {d:.4} of the anchor's window when it opened " ++
                "(control {d:.4}), and {d:.4} only after a forced redraw: the float reaches the screen but not " ++
                "on the frame it opens\n",
            .{ suspect.float_paint, control.float_paint, suspect.redraw_paint },
        );
        return error.BornExternalAnchorFloatNeedsForcedRedraw;
    }

    std.debug.print(
        "[gui] a float over an anchor born external (nvim_open_win external=true) changed {d:.4} of the anchor's " ++
            "OS window, and {d:.4} after a forced redraw, while the SAME float over an anchor externalized from a " ++
            "settled window changed {d:.4}. It takes no OS window of its own and is not a main-surface layer, so " ++
            "nothing draws it: without a prior win_pos, ExternalGridInfo.start_row stays -1 and both " ++
            "Grid.dirtyCompositedRow and buildExternalFloatRowIndexWithLimits bail out before compositing it into " ++
            "the anchor's rows\n",
        .{ suspect.float_paint, suspect.redraw_paint, control.float_paint },
    );
    return error.BornExternalAnchorFloatInvisible;
}
