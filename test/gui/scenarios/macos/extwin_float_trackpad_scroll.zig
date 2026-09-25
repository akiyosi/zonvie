// extwin_float_trackpad_scroll — a float that an EXTERNAL window hosts must
// take the trackpad scroll that lands inside it.
//
// A float anchored to an external window gets no window of its own: the
// external surface draws it as a layer at the float's origin inside that
// window. The main window resolves a scroll's target by z-order
// (MetalTerminalView.resolveScrollTarget), so a scroll over a float there
// reaches the float. ExternalGridView.scrollWheel had no such resolution: it
// named its OWN grid on every event, so a scroll inside a hosted float was
// applied to the window underneath it and the float never moved.
//
// The render side had already been built for a hosted float that scrolls on
// its own (ExternalGridView.updateScrollShaderOffset resolves a per-layer
// offset); only the input path never produced that state.
//
// Asserted on Neovim's own toplines rather than on the app log, so it holds
// whatever the frontend logs: the float's viewport has to advance AND the
// host's has to stand still. A fix that merely moved the scroll somewhere
// else would satisfy neither.
//
// macOS-only: ExternalGridView and the window enumeration are macOS frontend.

const std = @import("std");
const driver = @import("../../driver.zig");
const platform = driver.platform;
const Gui = driver.Gui;
const gui_io = @import("../../gui_io.zig");
const app_log = @import("../../app_log.zig");

const log_path = "tmp/gui_extwin_float_trackpad_scroll.log";
const max_windows = 16;

/// The float's placement inside the 60x20 host. The driver's trackpad gesture
/// lands on the host window's centre (roughly host row 10, col 30), so the
/// float is placed to cover it with several rows and columns of slack on every
/// side — a title bar shifting the centre a row or two must not move the
/// pointer out of the float.
const float_row: i64 = 4;
const float_col: i64 = 6;
const float_rows: i64 = 12;
const float_cols: i64 = 48;

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

/// The frontmost window of `pid` covering `point`, which is the one a posted
/// scroll will land on. windowsForPid returns the on-screen list front to back.
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

pub fn run(alloc: std.mem.Allocator) !void {
    std.Io.Dir.cwd().createDirPath(gui_io.io(), "tmp") catch {};
    std.Io.Dir.cwd().deleteFile(gui_io.io(), log_path) catch {};

    var g = try Gui.init(alloc, .{ .app_args = &.{ "--log", log_path } });
    defer g.deinit();
    g.activateApp();

    var before_buf: [max_windows]platform.MainWindow = undefined;
    const before = before_buf[0..platform.windowsForPid(g.app_pid, &before_buf)];
    const before_count = before.len;

    // The host: an ordinary editor window given a window of its own, with far
    // more lines than it shows so that a scroll applied to IT would be visible
    // in its topline. A host that cannot scroll would let the bug pass.
    try g.exec(
        \\luaeval('(function() local b = vim.api.nvim_create_buf(false, true) local l = {} for i = 1, 400 do l[i] = string.format("%3d host line", i) end vim.api.nvim_buf_set_lines(b, 0, -1, false, l) _G.z_anchor = vim.api.nvim_open_win(b, true, {external=true, width=60, height=20}) return 1 end)()')
    );
    const ext_win = try waitNewWindow(g.app_pid, before, 100);
    gui_io.sleepNs(600 * std.time.ns_per_ms);

    // The float, likewise longer than it shows: a float whose content fits is
    // deliberately transparent to scrolling, so it would fall through to the
    // host by design and prove nothing.
    var buf: [640]u8 = undefined;
    const open_float = try std.fmt.bufPrint(
        &buf,
        "luaeval('(function() local b = vim.api.nvim_create_buf(false, true) local l = {{}} " ++
            "for i = 1, 400 do l[i] = string.format(\"%3d float line\", i) end " ++
            "vim.api.nvim_buf_set_lines(b, 0, -1, false, l) " ++
            "_G.z_float = vim.api.nvim_open_win(b, true, {{relative=\"win\", win=_G.z_anchor, " ++
            "row={d}, col={d}, width={d}, height={d}, style=\"minimal\"}}) return 1 end)()')",
        .{ float_row, float_col, float_cols, float_rows },
    );
    const t_float = try app_log.nowMs(alloc, log_path);
    try g.exec(open_float);
    gui_io.sleepNs(600 * std.time.ns_per_ms);

    // Gate: the float has to be composited INTO the external window. A float
    // given a window of its own is drawn by its own surface root, whose scroll
    // path was never broken, and would pass for the wrong reason.
    if (try g.evalInt("luaeval('(vim.api.nvim_win_get_config(_G.z_float).win == _G.z_anchor) and 1 or 0')") != 1) {
        return error.FloatNotAnchoredToExternal;
    }

    // Opening the float moved the cursor onto a grid the EXTERNAL surface
    // hosts, and the app makes key whichever window owns the cursor's grid. It
    // resolved that owner from the COMMITTED map, which does not name the host
    // until the flush that places the float commits — one flush later — so it
    // found no window under the float's own id, fell through to the main
    // window, and took key status away from the window the cursor had just
    // entered. Measured at the decision: `gridId=5 committed=nil pending=4`.
    //
    // Asserted on the app's own line rather than on z-order: an external
    // window sits at `.floating` while the main window is `.normal`, so
    // ordering the main window front cannot actually put it over one — the
    // harm is key status, not stacking. Asserted here rather than after the
    // refocus below, which resolves the host anyway and would hide it.
    if (try app_log.containsSince(alloc, log_path, "activated main window", t_float)) {
        std.debug.print(
            "[gui] entering a float the external window hosts made the MAIN window key\n",
            .{},
        );
        return error.HostWindowLostKeyToMain;
    }
    const window_count = platform.windowsForPid(g.app_pid, &before_buf);
    if (window_count != before_count + 1) {
        std.debug.print(
            "[gui] expected the float to be composited into the external window, but the app has {d} windows (was {d} plus the anchor)\n",
            .{ window_count, before_count },
        );
        return error.FloatGotItsOwnWindow;
    }

    // Put focus back on the host. Two things come of it: the external window is
    // raised (onCursorGridChanged resolves the host grid to its own window), so
    // the posted gesture lands there rather than on the main window it overlaps;
    // and the scroll then has to reach the float WITHOUT the float being the
    // focused window, which is the case the user is in.
    try g.exec("luaeval('(function() vim.api.nvim_set_current_win(_G.z_anchor) return 1 end)()')");
    gui_io.sleepNs(600 * std.time.ns_per_ms);

    const scroll_x = ext_win.bounds.x + ext_win.bounds.w * 0.5;
    const scroll_y = ext_win.bounds.y + ext_win.bounds.h * 0.5;
    const front = topmostWindowAt(g.app_pid, scroll_x, scroll_y) orelse {
        return error.NoWindowUnderScrollPoint;
    };
    if (front.number != ext_win.number) {
        std.debug.print(
            "[gui] the external window is not frontmost at the scroll point; the gesture would land on window {d}\n",
            .{front.number},
        );
        platform.dumpWindowsForPid(g.app_pid);
        return error.ExternalWindowNotFrontmost;
    }

    const float_top0 = try g.evalInt("luaeval('vim.fn.getwininfo(_G.z_float)[1].topline')");
    const host_top0 = try g.evalInt("luaeval('vim.fn.getwininfo(_G.z_anchor)[1].topline')");

    if (!platform.scrollBegin(g.app_pid, ext_win)) {
        std.debug.print("[gui] could not drive a trackpad gesture over the external window\n", .{});
        return error.SkipZigTest;
    }
    var step: usize = 0;
    while (step < 12) : (step += 1) {
        platform.scrollStep(-12);
        gui_io.sleepNs(16 * std.time.ns_per_ms);
    }
    platform.scrollEnd();
    gui_io.sleepNs(900 * std.time.ns_per_ms);

    const float_top1 = try g.evalInt("luaeval('vim.fn.getwininfo(_G.z_float)[1].topline')");
    const host_top1 = try g.evalInt("luaeval('vim.fn.getwininfo(_G.z_anchor)[1].topline')");
    std.debug.print(
        "[gui] topline float {d} -> {d}, host {d} -> {d}\n",
        .{ float_top0, float_top1, host_top0, host_top1 },
    );

    if (float_top1 == float_top0 and host_top1 == host_top0) {
        std.debug.print("[gui] neither window scrolled: the gesture never reached the app\n", .{});
        return error.ScrollNeverArrived;
    }
    if (host_top1 != host_top0) {
        std.debug.print(
            "[gui] the host scrolled instead of the float it draws: the external surface named its own grid\n",
            .{},
        );
        return error.HostScrolledInsteadOfFloat;
    }
    if (float_top1 <= float_top0) return error.FloatDidNotScroll;

    // Phase 2: a float that refuses the mouse must not capture the scroll
    // either. Neovim rejects an event addressed to such a window without
    // re-resolving it, so a hit test that picked it would swallow the gesture
    // instead of letting it reach the host underneath.
    // Reopened rather than reconfigured: Neovim does not re-emit
    // win_float_pos for a `mouse` change alone, so a set_config would leave
    // the UI holding the old flag and the phase would test nothing.
    try g.exec("luaeval('(function() vim.api.nvim_win_close(_G.z_float, true) return 1 end)()')");
    gui_io.sleepNs(300 * std.time.ns_per_ms);
    const open_quiet = try std.fmt.bufPrint(
        &buf,
        "luaeval('(function() local b = vim.api.nvim_create_buf(false, true) local l = {{}} " ++
            "for i = 1, 400 do l[i] = string.format(\"%3d float line\", i) end " ++
            "vim.api.nvim_buf_set_lines(b, 0, -1, false, l) " ++
            "_G.z_float = vim.api.nvim_open_win(b, false, {{relative=\"win\", win=_G.z_anchor, " ++
            "row={d}, col={d}, width={d}, height={d}, style=\"minimal\", mouse=false}}) return 1 end)()')",
        .{ float_row, float_col, float_cols, float_rows },
    );
    try g.exec(open_quiet);
    gui_io.sleepNs(600 * std.time.ns_per_ms);
    // `== false`, not truthiness: a Neovim that does not carry the field at
    // all reports nil, which would pass a truthiness test while the float
    // still takes the mouse.
    if (try g.evalInt("luaeval('(vim.api.nvim_win_get_config(_G.z_float).mouse == false) and 1 or 0')") != 1) {
        return error.FloatStillTakesMouse;
    }

    const float_top2 = try g.evalInt("luaeval('vim.fn.getwininfo(_G.z_float)[1].topline')");
    const host_top2 = try g.evalInt("luaeval('vim.fn.getwininfo(_G.z_anchor)[1].topline')");

    if (!platform.scrollBegin(g.app_pid, ext_win)) return error.ScrollRefused;
    step = 0;
    while (step < 12) : (step += 1) {
        platform.scrollStep(-12);
        gui_io.sleepNs(16 * std.time.ns_per_ms);
    }
    platform.scrollEnd();
    gui_io.sleepNs(900 * std.time.ns_per_ms);

    const float_top3 = try g.evalInt("luaeval('vim.fn.getwininfo(_G.z_float)[1].topline')");
    const host_top3 = try g.evalInt("luaeval('vim.fn.getwininfo(_G.z_anchor)[1].topline')");
    std.debug.print(
        "[gui] mouse=false: float {d} -> {d}, host {d} -> {d}\n",
        .{ float_top2, float_top3, host_top2, host_top3 },
    );

    if (float_top3 != float_top2) {
        std.debug.print("[gui] a float with mouse=false still took the scroll\n", .{});
        return error.MouseDisabledFloatTookScroll;
    }
    if (host_top3 <= host_top2) {
        std.debug.print("[gui] the scroll reached neither window: it was swallowed\n", .{});
        return error.ScrollSwallowedByFloat;
    }
}
