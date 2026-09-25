// main_float_mouse_disabled_scroll — a float in the MAIN window that refuses
// the mouse must let the scroll through to the window under it.
//
// The twin of extwin_float_trackpad_scroll's second phase, which has asserted
// this on the EXTERNAL surface since 5e7e9cb. The main window had no such rule:
// `MetalTerminalView.resolveScrollTarget` resolves against `zonvie_grid_info`,
// which carries no mouse field, so it named the float and the gesture died.
//
// Why it dies rather than going somewhere wrong. Neovim looks a named grid up
// by handle (`mouse_find_grid_win`), rejects a float whose `mouse` is false,
// and `mouse_find_win_inner` then returns NULL because the grid is still > 1 —
// no fall-through to the frame-tree walk, no compositor hit test. The event is
// dropped. `include/zonvie_core.h` states this as a MUST on the frontend.
//
// The visible shape is worse than "nothing happens": zonvie eases the float's
// own pixels for the gesture it thinks it routed there, gets no `grid_scroll`
// back, and the offset decays — so the float slides and snaps back while the
// window underneath never moves. A trackpad flick loses the whole gesture,
// momentum included, because `lockedScrollTarget` latches the float for its
// duration.
//
// Three phases, because the interesting failure is indistinguishable from a
// dead harness without the first:
//
//   0. No float. The gesture must scroll the main window — otherwise nothing
//      below means anything.
//   1. A `mouse=false` float over the pointer. The float must NOT move and the
//      main window MUST. Those are separate assertions: a fix that merely
//      swallowed the event differently would satisfy the first alone.
//
// Asserted on Neovim's own toplines, not on the app log, so it holds whatever
// the frontend chooses to log.
//
// macOS-only: it drives a real trackpad gesture and tests the macOS hit test.

const std = @import("std");
const driver = @import("../../driver.zig");
const platform = driver.platform;
const Gui = driver.Gui;
const gui_io = @import("../../gui_io.zig");

const log_path = "tmp/gui_main_float_mouse_disabled_scroll.log";

/// The gesture lands on the main window's centre. The float is placed to cover
/// that point with slack on every side, so a title bar or a tabline shifting
/// the centre by a row or two cannot move the pointer out of it.
const float_row: i64 = 3;
const float_col: i64 = 4;
const float_rows: i64 = 20;
const float_cols: i64 = 70;

/// Scroll steps per gesture, and the pixels each one carries. Twelve steps of
/// 12px is what the external twin uses and is comfortably more than one row.
const scroll_steps: usize = 12;
const scroll_dy: f64 = -12;

fn oneGesture(win: platform.MainWindow, pid: i32) bool {
    if (!platform.scrollBegin(pid, win)) return false;
    var step: usize = 0;
    while (step < scroll_steps) : (step += 1) {
        platform.scrollStep(scroll_dy);
        gui_io.sleepNs(16 * std.time.ns_per_ms);
    }
    platform.scrollEnd();
    gui_io.sleepNs(900 * std.time.ns_per_ms);
    return true;
}

pub fn run(alloc: std.mem.Allocator) !void {
    std.Io.Dir.cwd().createDirPath(gui_io.io(), "tmp") catch {};
    std.Io.Dir.cwd().deleteFile(gui_io.io(), log_path) catch {};

    var g = try Gui.init(alloc, .{
        .app_args = &.{ "--log", log_path },
        .config_dir = "test/gui/fixtures/config",
    });
    defer g.deinit();
    g.activateApp();

    try g.exec("execute('set laststatus=0 noruler noshowcmd showtabline=0 scrolloff=0 nowrap noswapfile')");
    try g.exec(
        \\setline(1, map(range(1, 400), {_, i -> printf('%3d host line', i)}))
    );
    try g.exec("execute('normal! gg')");
    gui_io.sleepNs(1200 * std.time.ns_per_ms);

    const win = platform.mainWindowForPid(g.app_pid) orelse {
        std.debug.print("[gui] no main window for the app\n", .{});
        return error.MainWindowNotFound;
    };

    // Phase 0 — control. Without this a broken harness and a swallowed gesture
    // look the same.
    const host_top0 = try g.evalInt("line('w0')");
    if (!oneGesture(win, g.app_pid)) {
        std.debug.print("[gui] could not drive a trackpad gesture over the main window\n", .{});
        return error.SkipZigTest;
    }
    const host_top1 = try g.evalInt("line('w0')");
    std.debug.print("[gui] control: host topline {d} -> {d}\n", .{ host_top0, host_top1 });
    if (host_top1 <= host_top0) {
        std.debug.print("[gui] the gesture never scrolled the main window — nothing below is measurable\n", .{});
        return error.ScrollNeverArrived;
    }

    // Phase 1 — the float that refuses the mouse. Its own 400-line buffer makes
    // it logically scrollable, so `resolveScrollTarget`'s existing
    // non-scrollable-float skip does NOT cover it: only the mouse rule does.
    var buf: [640]u8 = undefined;
    const open_float = try std.fmt.bufPrint(
        &buf,
        "luaeval('(function() local b = vim.api.nvim_create_buf(false, true) local l = {{}} " ++
            "for i = 1, 400 do l[i] = string.format(\"%3d float line\", i) end " ++
            "vim.api.nvim_buf_set_lines(b, 0, -1, false, l) " ++
            "_G.z_float = vim.api.nvim_open_win(b, false, {{relative=\"editor\", " ++
            "row={d}, col={d}, width={d}, height={d}, style=\"minimal\", mouse=false}}) return 1 end)()')",
        .{ float_row, float_col, float_cols, float_rows },
    );
    try g.exec(open_float);
    gui_io.sleepNs(900 * std.time.ns_per_ms);

    const float_top0 = try g.evalInt("luaeval('vim.fn.getwininfo(_G.z_float)[1].topline')");
    const host_top2 = try g.evalInt("line('w0')");
    _ = oneGesture(win, g.app_pid);
    const float_top1 = try g.evalInt("luaeval('vim.fn.getwininfo(_G.z_float)[1].topline')");
    const host_top3 = try g.evalInt("line('w0')");

    std.debug.print(
        "[gui] mouse=false float: float {d} -> {d}, host {d} -> {d}\n",
        .{ float_top0, float_top1, host_top2, host_top3 },
    );

    if (float_top1 != float_top0) {
        std.debug.print("[gui] a float with mouse=false took the scroll\n", .{});
        return error.MouseDisabledFloatTookScroll;
    }
    if (host_top3 <= host_top2) {
        std.debug.print("[gui] the scroll reached neither window: it was swallowed by the float\n", .{});
        return error.ScrollSwallowedByFloat;
    }
}
