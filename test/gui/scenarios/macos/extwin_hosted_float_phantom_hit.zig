// extwin_hosted_float_phantom_hit — a float an EXTERNAL window hosts must not
// be hit-testable in the MAIN window's coordinate space.
//
// `zonvie_grid_info.is_external` names a grid that IS a window of its own. It
// says nothing about a float HOSTED by one, which is an ordinary sub-grid the
// external surface composites as a layer — and which reports startRow/startCol
// in THAT surface's space. MetalTerminalView.hitTestGrid and
// resolveScrollTarget filtered only `isExternal`, so those coordinates came
// through and were read as the main window's own: a phantom region, shaped and
// placed like the float, sitting wherever the numbers happened to land in a
// window the float is not in.
//
// The float here is deliberately placed so the phantom would cover the main
// window's CENTRE, which is where the driver's trackpad gesture lands. Both
// windows carry more lines than they show, so both CAN scroll — a float whose
// content fits is transparent to scrolling by design (the core's
// `capturesScroll`, which `require_scrollable` applies) and would pass for the
// wrong reason.
//
// Asserted on Neovim's own toplines rather than the app log: the main window
// has to advance AND the float has to stand still. A fix that merely sent the
// scroll somewhere else would satisfy neither.
//
// macOS-only: ExternalGridView, the main window's hit test, and the window
// enumeration are macOS frontend.

const std = @import("std");
const driver = @import("../../driver.zig");
const platform = driver.platform;
const Gui = driver.Gui;
const gui_io = @import("../../gui_io.zig");

const log_path = "tmp/gui_extwin_phantom_hit.log";
const max_windows = 16;

/// The phantom's size in cells, centred on the main window's centre cell. Big
/// enough that a tabline or a rounding difference cannot move the gesture out
/// of it, small enough to stay well inside a default main grid.
const phantom_rows: i64 = 12;
const phantom_cols: i64 = 40;

const scroll_steps: u32 = 12;
const step_px: f64 = -40;

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

/// The frontmost window of `pid` covering the point, which is the one a posted
/// scroll lands on. windowsForPid returns the on-screen list front to back.
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
    if (!platform.accessibilityTrusted()) {
        std.debug.print(
            "[gui] skipped: not trusted for Accessibility, so the external window " ++
                "cannot be moved off the main window's centre.\n",
            .{},
        );
        return error.SkipZigTest;
    }

    std.Io.Dir.cwd().createDirPath(gui_io.io(), "tmp") catch {};
    std.Io.Dir.cwd().deleteFile(gui_io.io(), log_path) catch {};

    var g = try Gui.init(alloc, .{ .app_args = &.{ "--log", log_path } });
    defer g.deinit();
    g.activateApp();
    gui_io.sleepNs(700 * std.time.ns_per_ms);

    // The main window, with far more lines than it shows: a main window that
    // cannot scroll would let the phantom pass unnoticed.
    try g.exec(
        \\luaeval('(function() _G.z_main = vim.api.nvim_get_current_win() local l = {} for i = 1, 400 do l[i] = string.format("%3d main line", i) end vim.api.nvim_buf_set_lines(0, 0, -1, false, l) return 1 end)()')
    );
    const main_rows = try g.evalInt("luaeval('vim.api.nvim_win_get_height(_G.z_main)')");
    const main_cols = try g.evalInt("luaeval('vim.api.nvim_win_get_width(_G.z_main)')");
    if (main_rows < phantom_rows + 4 or main_cols < phantom_cols + 4) {
        std.debug.print(
            "[gui] main grid {d}x{d} is too small to centre a {d}x{d} phantom in\n",
            .{ main_rows, main_cols, phantom_rows, phantom_cols },
        );
        return error.MainGridTooSmall;
    }

    var before_buf: [max_windows]platform.MainWindow = undefined;
    const before = before_buf[0..platform.windowsForPid(g.app_pid, &before_buf)];
    const before_count = before.len;

    // The host window.
    try g.exec(
        \\luaeval('(function() local b = vim.api.nvim_create_buf(false, true) local l = {} for i = 1, 400 do l[i] = string.format("%3d host line", i) end vim.api.nvim_buf_set_lines(b, 0, -1, false, l) _G.z_anchor = vim.api.nvim_open_win(b, true, {external=true, width=60, height=20}) return 1 end)()')
    );
    const ext_win = try waitNewWindow(g.app_pid, before, 100);
    gui_io.sleepNs(600 * std.time.ns_per_ms);

    // Placed so that, read as main-window coordinates, it straddles the main
    // window's centre cell — the point the gesture below lands on.
    const phantom_row = @divTrunc(main_rows, 2) - @divTrunc(phantom_rows, 2);
    const phantom_col = @divTrunc(main_cols, 2) - @divTrunc(phantom_cols, 2);

    var buf: [768]u8 = undefined;
    const open_float = try std.fmt.bufPrint(
        &buf,
        "luaeval('(function() local b = vim.api.nvim_create_buf(false, true) local l = {{}} " ++
            "for i = 1, 400 do l[i] = string.format(\"%3d float line\", i) end " ++
            "vim.api.nvim_buf_set_lines(b, 0, -1, false, l) " ++
            "_G.z_float = vim.api.nvim_open_win(b, false, {{relative=\"win\", win=_G.z_anchor, " ++
            "row={d}, col={d}, width={d}, height={d}, style=\"minimal\"}}) return 1 end)()')",
        .{ phantom_row, phantom_col, phantom_cols, phantom_rows },
    );
    try g.exec(open_float);
    gui_io.sleepNs(600 * std.time.ns_per_ms);

    // Gates. Each names a way this could pass while proving nothing.
    if (try g.evalInt("luaeval('(vim.api.nvim_win_get_config(_G.z_float).win == _G.z_anchor) and 1 or 0')") != 1) {
        return error.FloatNotAnchoredToExternal;
    }
    const placed_row = try g.evalInt("luaeval('vim.api.nvim_win_get_config(_G.z_float).row')");
    const placed_col = try g.evalInt("luaeval('vim.api.nvim_win_get_config(_G.z_float).col')");
    if (placed_row != phantom_row or placed_col != phantom_col) {
        std.debug.print(
            "[gui] Neovim moved the float to ({d},{d}); asked for ({d},{d}) — the phantom " ++
                "would not cover the gesture point\n",
            .{ placed_row, placed_col, phantom_row, phantom_col },
        );
        return error.FloatNotWhereAsked;
    }
    const window_count = platform.windowsForPid(g.app_pid, &before_buf);
    if (window_count != before_count + 1) {
        std.debug.print(
            "[gui] expected the float to be composited into the external window, but the " ++
                "app has {d} windows (was {d} plus the anchor)\n",
            .{ window_count, before_count },
        );
        return error.FloatGotItsOwnWindow;
    }

    // Focus back to the main window, and move the host out from over its
    // centre so the posted gesture cannot land on the host by accident.
    try g.exec("luaeval('(function() vim.api.nvim_set_current_win(_G.z_main) return 1 end)()')");
    gui_io.sleepNs(500 * std.time.ns_per_ms);

    const main_b = platform.mainWindowBoundsForPid(g.app_pid) orelse return error.MainWindowNotFound;
    if (!platform.moveWindowBySize(
        g.app_pid,
        ext_win.bounds.w,
        ext_win.bounds.h,
        main_b.x + main_b.w - ext_win.bounds.w,
        main_b.y,
    )) {
        return error.MoveFailed;
    }
    gui_io.sleepNs(500 * std.time.ns_per_ms);

    const main_win = platform.mainWindowForPid(g.app_pid) orelse return error.MainWindowNotFound;
    const cx = main_win.bounds.x + main_win.bounds.w * 0.5;
    const cy = main_win.bounds.y + main_win.bounds.h * 0.5;
    const front = topmostWindowAt(g.app_pid, cx, cy) orelse return error.NoWindowUnderScrollPoint;
    if (front.number != main_win.number) {
        std.debug.print(
            "[gui] the main window is not frontmost at the scroll point; the gesture " ++
                "would land on window {d}\n",
            .{front.number},
        );
        platform.dumpWindowsForPid(g.app_pid);
        return error.MainWindowNotFrontmost;
    }

    const main_top0 = try g.evalInt("luaeval('vim.fn.getwininfo(_G.z_main)[1].topline')");
    const float_top0 = try g.evalInt("luaeval('vim.fn.getwininfo(_G.z_float)[1].topline')");

    if (!platform.scrollBegin(g.app_pid, main_win)) return error.ScrollRefused;
    var n: u32 = 0;
    while (n < scroll_steps) : (n += 1) {
        platform.scrollStep(step_px);
        gui_io.sleepNs(16 * std.time.ns_per_ms);
    }
    platform.scrollEnd();
    gui_io.sleepNs(900 * std.time.ns_per_ms);

    const main_top1 = try g.evalInt("luaeval('vim.fn.getwininfo(_G.z_main)[1].topline')");
    const float_top1 = try g.evalInt("luaeval('vim.fn.getwininfo(_G.z_float)[1].topline')");

    std.debug.print(
        "[gui] phantom hit: main topline {d} -> {d}, hosted float {d} -> {d} " ++
            "(phantom at row {d}, col {d} of a {d}x{d} main grid)\n",
        .{ main_top0, main_top1, float_top0, float_top1, phantom_row, phantom_col, main_rows, main_cols },
    );

    if (float_top1 != float_top0) {
        std.debug.print(
            "[gui] a scroll on the MAIN window moved a float the EXTERNAL window hosts: " ++
                "its coordinates were read as the main window's own\n",
            .{},
        );
        return error.PhantomFloatTookTheScroll;
    }
    if (main_top1 <= main_top0) {
        std.debug.print("[gui] the main window did not scroll at all\n", .{});
        return error.MainWindowDidNotScroll;
    }
}
