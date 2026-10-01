// extwin_float_wheel_scroll — a float that an EXTERNAL window hosts must take
// the wheel notch that lands inside it.
//
// A float anchored to an external window gets no window of its own: the
// external surface composites it as a layer. Neovim does no z-order test once
// the UI names a grid (mouse.c, mouse_find_grid_win), so the frontend has to
// name the float itself. The press path already did that
// (input.resolveMouseTarget); handleMouseWheel resolved layers for the MAIN
// window only and passed an external surface's own grid id through, so a
// wheel inside a hosted float scrolled the window underneath it.
//
// Asserted on Neovim's own toplines, not on pixels: the float's viewport has
// to advance AND the host's has to stand still. The macOS half of the same
// defect is covered by scenarios/macos/extwin_float_trackpad_scroll.zig.
//
// The notch is posted straight to the external window's HWND, so the result
// does not depend on which window happens to be frontmost.
//
// Windows-only; gated by the runner.

const std = @import("std");
const driver = @import("../../driver.zig");
const platform = driver.platform;
const Gui = driver.Gui;
const gui_io = @import("../../gui_io.zig");

/// The float's placement inside the 60x20 host. The notch is aimed at the
/// host's client centre (row 10, col 30), so the float is placed to cover it
/// with several rows and columns of slack on every side.
const float_row: i64 = 4;
const float_col: i64 = 6;
const float_rows: i64 = 12;
const float_cols: i64 = 48;

pub fn run(alloc: std.mem.Allocator) !void {
    var g = try Gui.init(alloc, .{});
    defer g.deinit();

    // Deterministic scroll amount: 3 lines per wheel event.
    try g.exec("execute('set mousescroll=ver:3')");

    const before_count = platform.windowCountForPid(g.app_pid);

    // The host: an ordinary editor window given a window of its own, with far
    // more lines than it shows so a scroll applied to IT would move its
    // topline. A host that cannot scroll would let the bug pass unnoticed.
    try g.exec(
        \\luaeval('(function() local b = vim.api.nvim_create_buf(false, true) local l = {} for i = 1, 400 do l[i] = string.format("%3d host line", i) end vim.api.nvim_buf_set_lines(b, 0, -1, false, l) _G.z_anchor = vim.api.nvim_open_win(b, true, {external=true, width=60, height=20}) return 1 end)()')
    );

    var hwnd_opt = platform.externalWindowHandleForPid(g.app_pid, 100);
    var waited: u32 = 0;
    while (hwnd_opt == null and waited < 100) : (waited += 1) {
        gui_io.sleepNs(100 * std.time.ns_per_ms);
        hwnd_opt = platform.externalWindowHandleForPid(g.app_pid, 100);
    }
    const ext_hwnd = hwnd_opt orelse {
        platform.dumpWindowsForPid(g.app_pid);
        return error.ExternalWindowNotFound;
    };
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
    try g.exec(open_float);
    gui_io.sleepNs(600 * std.time.ns_per_ms);

    // Gate: the float has to be composited INTO the external window. A float
    // given a window of its own is driven by its own surface root, whose wheel
    // path was never broken, and would pass for the wrong reason.
    if (try g.evalInt("luaeval('(vim.api.nvim_win_get_config(_G.z_float).win == _G.z_anchor) and 1 or 0')") != 1) {
        return error.FloatNotAnchoredToExternal;
    }
    const window_count = platform.windowCountForPid(g.app_pid);
    if (window_count != before_count + 1) {
        std.debug.print(
            "[gui] expected the float to be composited into the external window, but the app has {d} windows (was {d} plus the anchor)\n",
            .{ window_count, before_count },
        );
        return error.FloatGotItsOwnWindow;
    }

    // Focus back on the host, so the scroll has to reach the float WITHOUT the
    // float being the focused window — the case the user is in.
    try g.exec("luaeval('(function() vim.api.nvim_set_current_win(_G.z_anchor) return 1 end)()')");
    gui_io.sleepNs(400 * std.time.ns_per_ms);

    const float_top0 = try g.evalInt("luaeval('vim.fn.getwininfo(_G.z_float)[1].topline')");
    const host_top0 = try g.evalInt("luaeval('vim.fn.getwininfo(_G.z_anchor)[1].topline')");

    const centre = platform.clientCenterScreen(ext_hwnd) orelse return error.NoClientRect;
    // Win32 convention: negative delta scrolls down.
    if (!platform.sendWheelToWindow(ext_hwnd, -2, centre.x, centre.y)) return error.WheelSendFailed;

    var float_top1 = float_top0;
    var host_top1 = host_top0;
    var polls: u32 = 0;
    while (polls < 40) : (polls += 1) {
        float_top1 = try g.evalInt("luaeval('vim.fn.getwininfo(_G.z_float)[1].topline')");
        host_top1 = try g.evalInt("luaeval('vim.fn.getwininfo(_G.z_anchor)[1].topline')");
        if (float_top1 != float_top0 or host_top1 != host_top0) break;
        gui_io.sleepNs(50 * std.time.ns_per_ms);
    }
    std.debug.print(
        "[gui] topline float {d} -> {d}, host {d} -> {d}\n",
        .{ float_top0, float_top1, host_top0, host_top1 },
    );

    if (float_top1 == float_top0 and host_top1 == host_top0) {
        std.debug.print("[gui] neither window scrolled: the notch never reached the app\n", .{});
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
}
