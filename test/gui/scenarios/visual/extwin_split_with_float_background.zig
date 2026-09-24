// visual/extwin_split_with_float_background — a split that hosts a float,
// externalized with <C-w>ge, must open an external window painted with the
// split's own background, not black.
//
// Reported by hand: the same split without a float opened with the right
// colour. The oracle is the colour of a stretch of the new window that holds
// neither text nor the float, compared against `Normal`'s background, which
// this scenario sets to a colour far from black so the two cannot be confused.
//
// Run under two opaque fixtures: without blur, the control, and with blur at
// full opacity, the failing case. Under blur the core drops the
// default-background runs of a surface root once it hosts a layer, and the
// window's background used to be recovered from the first such run of row 0 —
// so with a float the window was never given one and stayed black. Full
// opacity keeps the captured colour meaningful; the default fixture's 0.5
// would show the desktop through a correct window too.
//
// macOS-only: it enumerates the app's OS windows to capture the external one.

const std = @import("std");
const driver = @import("../../driver.zig");
const platform = driver.platform;
const capture = driver.capture;
const fixture = @import("fixture.zig");
const gui_io = @import("../../gui_io.zig");

const max_windows = 16;

/// `Normal`'s background for this run: far from black on every channel.
const normal_bg = [3]u8{ 0x20, 0x60, 0xa0 };
/// A channel may differ by this much (colour-space conversion in the capture).
const tolerance: i32 = 24;

fn waitNewWindow(pid: i32, before: []const platform.MainWindow, tries: u32) !platform.MainWindow {
    var buf: [max_windows]platform.MainWindow = undefined;
    var attempt: u32 = 0;
    while (attempt < tries) : (attempt += 1) {
        const now = buf[0..platform.windowsForPid(pid, &buf)];
        for (now) |w| {
            var seen = false;
            for (before) |b| {
                if (b.number == w.number) seen = true;
            }
            if (!seen and w.bounds.w >= 100 and w.bounds.h >= 100) return w;
        }
        gui_io.sleepNs(100 * std.time.ns_per_ms);
    }
    platform.dumpWindowsForPid(pid);
    return error.ExternalWindowNotFound;
}

/// Mean colour of the lower-right quarter of the capture. The buffer's text
/// is at the left edge of each row and the float sits near the top-left, so
/// this stretch shows only the window's background.
fn backgroundSample(img: capture.Image) [3]i32 {
    var sum = [3]u64{ 0, 0, 0 };
    var n: u64 = 0;
    var y: u32 = img.h * 3 / 5;
    while (y < img.h * 19 / 20) : (y += 1) {
        var x: u32 = img.w * 3 / 5;
        while (x < img.w * 19 / 20) : (x += 1) {
            const i = (@as(usize, y) * img.w + x) * 4;
            sum[0] += img.rgba[i];
            sum[1] += img.rgba[i + 1];
            sum[2] += img.rgba[i + 2];
            n += 1;
        }
    }
    if (n == 0) return .{ 0, 0, 0 };
    return .{
        @intCast(sum[0] / n),
        @intCast(sum[1] / n),
        @intCast(sum[2] / n),
    };
}

fn runWith(alloc: std.mem.Allocator, config_dir: []const u8, log_path: []const u8) !void {
    std.Io.Dir.cwd().createDirPath(gui_io.io(), "tmp") catch {};
    std.Io.Dir.cwd().deleteFile(gui_io.io(), log_path) catch {};

    var g = try fixture.openWithLogAndConfig(alloc, log_path, config_dir);
    defer g.deinit();
    g.activateApp();

    try g.exec("execute('set laststatus=0 noruler noshowcmd showtabline=0 nowrap noswapfile')");
    try g.exec("execute('highlight Normal guibg=#2060a0 guifg=#ffffff')");
    try g.exec("execute('highlight NormalFloat guibg=#a02060 guifg=#ffffff')");

    // A split holding a short buffer, and a float anchored to it.
    try g.exec(
        \\luaeval('(function() vim.cmd("vsplit") _G.z_host = vim.api.nvim_get_current_win() local b = vim.api.nvim_create_buf(false, true) vim.api.nvim_buf_set_lines(b, 0, -1, false, {"host 1", "host 2", "host 3"}) vim.api.nvim_win_set_buf(_G.z_host, b) local fb = vim.api.nvim_create_buf(false, true) vim.api.nvim_buf_set_lines(fb, 0, -1, false, {"float A", "float B"}) _G.z_float = vim.api.nvim_open_win(fb, false, {relative="win", win=_G.z_host, row=1, col=2, width=12, height=3, style="minimal"}) return 1 end)()')
    );
    gui_io.sleepNs(800 * std.time.ns_per_ms);

    var before_buf: [max_windows]platform.MainWindow = undefined;
    const before = before_buf[0..platform.windowsForPid(g.app_pid, &before_buf)];

    // The user's repro: externalize the split that hosts the float.
    try g.remoteSend("<C-w>ge");
    const ext = try waitNewWindow(g.app_pid, before, 150);
    gui_io.sleepNs(1500 * std.time.ns_per_ms);

    var img = try capture.captureWindow(alloc, ext.number);
    defer img.deinit(alloc);
    driver.capture.writeImage(alloc, "tmp/extwin_split_float_bg" ++ driver.capture.image_ext, img) catch {};

    const got = backgroundSample(img);
    std.debug.print(
        "[gui] extwin_split_with_float_background ({s}): capture {d}x{d}; background ({d},{d},{d}), Normal ({d},{d},{d})\n",
        .{ config_dir, img.w, img.h, got[0], got[1], got[2], normal_bg[0], normal_bg[1], normal_bg[2] },
    );
    for (0..3) |ch| {
        if (@abs(got[ch] - @as(i32, normal_bg[ch])) > tolerance) {
            std.debug.print(
                "[gui] the externalized split's background is not Normal's — a split hosting a float opened with the wrong colour\n",
                .{},
            );
            return error.ExternalWindowBackgroundWrong;
        }
    }
}

pub fn run(alloc: std.mem.Allocator) !void {
    try fixture.requireScreenAccess();
    try runWith(alloc, "test/gui/fixtures/config_hosted_opaque", "tmp/gui_extwin_split_float_bg.log");
    try runWith(alloc, "test/gui/fixtures/config_blur_opaque", "tmp/gui_extwin_split_float_bg_blur.log");
}
