// main_float_mouse_disabled_wheel — Linux twin of
// main_float_mouse_disabled_scroll: a float in the main window that refuses
// the mouse (mouse=false) must let a wheel notch through to the window under
// it (include/zonvie_core.h states this as a MUST on the frontend). Driven by
// virtual-pointer wheel notches where macOS drives a trackpad gesture;
// asserted on Neovim's own toplines.
//
// Linux-only: linux/input.zig's wheel path.

const std = @import("std");
const driver = @import("../../driver.zig");
const platform = driver.platform;
const Gui = driver.Gui;
const gui_io = @import("../../gui_io.zig");
const app_log = @import("../../app_log.zig");

const log_path = "tmp/gui_main_float_mouse_disabled_wheel.log";

/// Covers the main window's centre with slack on every side.
const float_row: i64 = 3;
const float_col: i64 = 4;
const float_rows: i64 = 20;
const float_cols: i64 = 70;

fn wheelAtCentre(g: *Gui) !void {
    const b = g.mainWindowBounds() orelse return error.MainWindowNotFound;
    if (!platform.sendWheel(g.app_pid, -2, @intFromFloat(b.x + b.w / 2), @intFromFloat(b.y + b.h / 2))) return error.SkipZigTest;
    gui_io.sleepNs(700 * std.time.ns_per_ms);
}

pub fn run(alloc: std.mem.Allocator) !void {
    std.Io.Dir.cwd().createDirPath(gui_io.io(), "tmp") catch {};
    std.Io.Dir.cwd().deleteFile(gui_io.io(), log_path) catch {};
    var g = try Gui.init(alloc, .{
        .app_args = &.{ "--log", log_path },
        .config_dir = "test/gui/fixtures/config",
    });
    defer g.deinit();

    const before_setup = try app_log.lineMark(alloc, log_path);
    try g.exec("execute('set laststatus=0 noruler noshowcmd showtabline=0 scrolloff=0 nowrap noswapfile mousescroll=ver:3')");
    try g.exec(
        \\setline(1, map(range(1, 400), {_, i -> printf('%3d host line', i)}))
    );
    try g.exec("execute('normal! gg')");
    try app_log.waitFramesAfter(alloc, log_path, 1, 2, before_setup, 10_000);

    // Control: with no float the notches scroll the main window.
    const host_top0 = try g.evalInt("line('w0')");
    try wheelAtCentre(g);
    const host_top1 = try g.evalInt("line('w0')");
    std.debug.print("[gui] control: host topline {d} -> {d}\n", .{ host_top0, host_top1 });
    if (host_top1 <= host_top0) return error.ScrollNeverArrived;

    // A float that refuses the mouse, scrollable in its own right.
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
    const before_float = try app_log.lineMark(alloc, log_path);
    try g.exec(open_float);
    try app_log.waitFramesAfter(alloc, log_path, 1, 2, before_float, 10_000);

    const float_top0 = try g.evalInt("luaeval('vim.fn.getwininfo(_G.z_float)[1].topline')");
    const host_top2 = try g.evalInt("line('w0')");
    try wheelAtCentre(g);
    const float_top1 = try g.evalInt("luaeval('vim.fn.getwininfo(_G.z_float)[1].topline')");
    const host_top3 = try g.evalInt("line('w0')");
    std.debug.print("[gui] mouse=false float: float {d} -> {d}, host {d} -> {d}\n", .{ float_top0, float_top1, host_top2, host_top3 });
    if (float_top1 != float_top0) return error.MouseDisabledFloatTookScroll;
    if (host_top3 <= host_top2) return error.ScrollSwallowedByFloat;
}
