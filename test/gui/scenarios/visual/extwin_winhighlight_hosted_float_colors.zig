// visual/extwin_winhighlight_hosted_float_colors — an external window whose
// `winhighlight` maps NormalFloat to Normal, hosting a float, must show its
// own cells in Normal's colour and the float's in NormalFloat's.
//
// Seen while building hosted_float_scroll_band: the host's rows came out in
// NormalFloat's colour. (The float's cells came out in Normal's too, but that
// was Neovim's doing: a window opened from the current one inherits its
// window-local `winhighlight`. The float's is cleared here so its cells are
// NormalFloat and the two colours can be told apart.)
// An external window opened with nvim_open_win(external=true) is a float to
// Neovim; under blur the core drops a surface root's default-background runs
// while it hosts a layer, and the window's fill underneath was NormalFloat.
//
// Run under the opaque blur fixture (blur on, opacity 1): blur is what makes
// the core drop those runs, and full opacity keeps a captured colour
// meaningful. Sampled from cells, not margins, well inside each rectangle.
//
// macOS-only: it enumerates the app's OS windows to capture the external one.

const std = @import("std");
const driver = @import("../../driver.zig");
const platform = driver.platform;
const capture = driver.capture;
const fixture = @import("fixture.zig");
const gui_io = @import("../../gui_io.zig");

const max_windows = 16;
const normal_bg = [3]i32{ 0x20, 0x60, 0xa0 };
const float_bg = [3]i32{ 0xa0, 0x20, 0x60 };
const tolerance: i32 = 24;

fn waitNewWindow(pid: i32, before: []const platform.MainWindow) !platform.MainWindow {
    var buf: [max_windows]platform.MainWindow = undefined;
    var attempt: u32 = 0;
    while (attempt < 150) : (attempt += 1) {
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

/// Mean colour of a rectangle given in fractions of the capture.
fn meanColour(img: capture.Image, x0f: f32, y0f: f32, x1f: f32, y1f: f32) [3]i32 {
    const fw: f32 = @floatFromInt(img.w);
    const fh: f32 = @floatFromInt(img.h);
    var sum = [3]u64{ 0, 0, 0 };
    var n: u64 = 0;
    var y: u32 = @intFromFloat(y0f * fh);
    while (y < @as(u32, @intFromFloat(y1f * fh))) : (y += 1) {
        var x: u32 = @intFromFloat(x0f * fw);
        while (x < @as(u32, @intFromFloat(x1f * fw))) : (x += 1) {
            const i = (@as(usize, y) * img.w + x) * 4;
            sum[0] += img.rgba[i];
            sum[1] += img.rgba[i + 1];
            sum[2] += img.rgba[i + 2];
            n += 1;
        }
    }
    if (n == 0) return .{ 0, 0, 0 };
    return .{ @intCast(sum[0] / n), @intCast(sum[1] / n), @intCast(sum[2] / n) };
}

fn near(got: [3]i32, want: [3]i32) bool {
    for (0..3) |ch| {
        if (@abs(got[ch] - want[ch]) > tolerance) return false;
    }
    return true;
}

pub fn run(alloc: std.mem.Allocator) !void {
    try fixture.requireScreenAccess();
    const log_path = "tmp/gui_extwin_winhighlight_colors.log";
    std.Io.Dir.cwd().createDirPath(gui_io.io(), "tmp") catch {};
    std.Io.Dir.cwd().deleteFile(gui_io.io(), log_path) catch {};

    var g = try fixture.openWithLogAndConfig(alloc, log_path, "test/gui/fixtures/config_blur_opaque");
    defer g.deinit();
    g.activateApp();

    try g.exec("execute('set laststatus=0 noruler noshowcmd showtabline=0 nowrap noswapfile')");
    try g.exec("execute('highlight Normal guibg=#2060a0 guifg=#ffffff')");
    try g.exec("execute('highlight NormalFloat guibg=#a02060 guifg=#ffffff')");

    var before_buf: [max_windows]platform.MainWindow = undefined;
    const before = before_buf[0..platform.windowsForPid(g.app_pid, &before_buf)];
    // 60x20 external window, its NormalFloat mapped to Normal.
    try g.exec(
        \\luaeval('(function() local b = vim.api.nvim_create_buf(false, true) vim.api.nvim_buf_set_lines(b, 0, -1, false, {"host"}) _G.z_anchor = vim.api.nvim_open_win(b, true, {external=true, width=60, height=20}) vim.wo[_G.z_anchor].winhighlight = "NormalFloat:Normal" return 1 end)()')
    );
    const ext = try waitNewWindow(g.app_pid, before);
    gui_io.sleepNs(600 * std.time.ns_per_ms);

    // A float over the left half of rows 4..15 (cols 6..30 of 60).
    try g.exec(
        \\luaeval('(function() local fb = vim.api.nvim_create_buf(false, true) vim.api.nvim_buf_set_lines(fb, 0, -1, false, {"float"}) _G.z_float = vim.api.nvim_open_win(fb, false, {relative="win", win=_G.z_anchor, row=4, col=6, width=24, height=12, style="minimal"}) vim.wo[_G.z_float].winhighlight = "" return 1 end)()')
    );
    gui_io.sleepNs(1200 * std.time.ns_per_ms);

    var img = try capture.captureWindow(alloc, ext.number);
    defer img.deinit(alloc);
    capture.writeImage(alloc, "tmp/extwin_winhighlight_colors" ++ capture.image_ext, img) catch {};

    // The capture includes the title bar, so fractions are taken of the
    // lower part: the host far right of the float, rows alongside it; and the
    // middle of the float, clear of its first line of text.
    const host = meanColour(img, 0.75, 0.55, 0.95, 0.70);
    const float = meanColour(img, 0.25, 0.55, 0.45, 0.70);
    std.debug.print(
        "[gui] extwin_winhighlight_colors: host ({d},{d},{d}) want Normal, float ({d},{d},{d}) want NormalFloat\n",
        .{ host[0], host[1], host[2], float[0], float[1], float[2] },
    );
    if (!near(host, normal_bg)) return error.HostCellsNotNormal;
    if (!near(float, float_bg)) return error.FloatCellsNotNormalFloat;
}
