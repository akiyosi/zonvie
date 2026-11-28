// extwin_cmdline_popup_visible — the ext cmdline popup (linux/panel_popup.zig)
// must show while an external window has the keyboard, not stay transparent.
//
// Reported by hand: with an external window focused, the cmdline popup of
// the main window let that window show through: the compositor showed
// nothing of a popup whose window had no keyboard, though the app drew it.
// The cmdline now hangs from the surface the keyboard is on
// (popup_place.zig hostSurface). The oracle compares captures of the
// window it hangs from (the composited screen, so the popup is in them)
// before and after the cmdline opens: a painted panel changes most of its
// area, a transparent one leaves the window as it was. Run without an
// external window first, the control; then with one, which takes the
// keyboard as it maps; then with one and the keyboard given back to the
// main window by a click, where the cmdline must come back to it; then with
// the cursor taken back to the main window by <C-w><C-w>, which must hand
// the main window the keyboard (on_cursor_grid_changed) and so the cmdline.

const std = @import("std");
const driver = @import("../../driver.zig");
const platform = driver.platform;
const capture = driver.capture;
const Gui = driver.Gui;
const app_log = @import("../../app_log.zig");
const gui_io = @import("../../gui_io.zig");

const log_path = "tmp/gui_extwin_cmdline_popup.log";

/// A painted panel changes at least this share of its area.
const min_changed = 0.5;

/// The last logged cmdline panel's area since `after`, in device px (the
/// capture's px: grim grabs at the output's scale, as the app draws).
fn panelArea(alloc: std.mem.Allocator, after: usize) !f64 {
    const lines = try app_log.linesAfter(alloc, log_path, "[overlay] cmdline", after);
    defer alloc.free(lines);
    var it = std.mem.splitBackwardsScalar(u8, std.mem.trimEnd(u8, lines, "\n"), '\n');
    const line = it.next() orelse return error.NoCmdlinePanel;
    const w = app_log.field(line, "w") orelse return error.NoCmdlinePanel;
    const h = app_log.field(line, "h") orelse return error.NoCmdlinePanel;
    return w * h;
}

/// Pixels that differ between the two captures of the window.
fn changedPixels(a: capture.Image, b: capture.Image) !usize {
    if (a.w != b.w or a.h != b.h) return error.WindowResizedBetweenCaptures;
    var n: usize = 0;
    var i: usize = 0;
    while (i + 3 < a.rgba.len) : (i += 4) {
        var d: u32 = 0;
        for (0..3) |c| d += @abs(@as(i32, a.rgba[i + c]) - @as(i32, b.rgba[i + c]));
        if (d > 48) n += 1;
    }
    return n;
}

fn grab(alloc: std.mem.Allocator, pid: i32, window: u32) !capture.Image {
    return if (window == 0) capture.captureMainWindow(alloc, pid, null) else capture.captureWindow(alloc, window);
}

const Case = enum { control, ext_focused, main_focused, cursor_moved };

fn runWith(alloc: std.mem.Allocator, case: Case) !void {
    const with_ext = case != .control;
    std.Io.Dir.cwd().createDirPath(gui_io.io(), "tmp") catch {};
    std.Io.Dir.cwd().deleteFile(gui_io.io(), log_path) catch {};
    var g = try Gui.init(alloc, .{
        .app_args = &.{ "--extcmdline", "--log", log_path },
        .config_dir = "test/gui/fixtures/config_render_trace",
    });
    defer g.deinit();
    g.activateApp();
    try app_log.waitFramesAfter(alloc, log_path, 1, 1, 0, 10_000);
    try g.exec("execute('set laststatus=0 noruler noshowcmd showtabline=0 noswapfile')");
    // The panel takes Normal's background; the windows' grids are given
    // another one, so a painted panel differs from what it covers.
    try g.exec("execute('highlight Normal guibg=#2060a0 guifg=#ffffff')");
    try g.exec("execute('highlight ZMainBg guibg=#a02060 guifg=#ffffff')");
    try g.exec("execute('setlocal winhighlight=Normal:ZMainBg')");

    // The window the cmdline is expected on: 0 for the main one.
    var host_window: u32 = 0;
    if (with_ext) {
        const before = driver.snapshotWindows(g.app_pid);
        const mark = try app_log.lineMark(alloc, log_path);
        const enter = if (case == .cursor_moved) "true" else "false";
        var open_buf: [512]u8 = undefined;
        try g.exec(try std.fmt.bufPrint(&open_buf, "luaeval('(function() local b = vim.api.nvim_create_buf(false, true) vim.api.nvim_buf_set_lines(b, 0, -1, false, {{\"external\"}}) _G.z_ext = vim.api.nvim_open_win(b, {s}, {{external=true, width=30, height=8}}) vim.wo[_G.z_ext].winhighlight = \"Normal:ZMainBg,NormalFloat:ZMainBg\" return 1 end)()')", .{enter}));
        host_window = (try driver.waitNewWindow(g.app_pid, before.slice(), 100)).number;
        try app_log.waitFramesAfter(alloc, log_path, app_log.any_external_surface, 2, mark, 10_000);
    }
    // Tiling compositors resize the main window when another one maps.
    gui_io.sleepNs(500 * std.time.ns_per_ms);
    if (case == .main_focused) {
        // A click on the main window gives it the keyboard.
        var ptr = platform.pointer() orelse {
            std.debug.print("[gui] main_focused case skipped: no virtual pointer\n", .{});
            return;
        };
        defer ptr.deinit();
        const b = g.mainWindowBounds() orelse return error.MainWindowNotFound;
        ptr.click(b.x + b.w / 2, b.y + b.h * 0.8, 0x110);
        gui_io.sleepNs(300 * std.time.ns_per_ms);
        host_window = 0;
    }
    if (case == .cursor_moved) {
        // A click in the external window, which has the keyboard and the
        // cursor already: the input a real <C-w><C-w> would come with.
        var ptr = platform.pointer() orelse {
            std.debug.print("[gui] cursor_moved case skipped: no virtual pointer\n", .{});
            return;
        };
        defer ptr.deinit();
        const eb = platform.boundsOf(host_window) orelse return error.ExternalWindowNotFound;
        ptr.click(eb.x + eb.w / 2, eb.y + eb.h / 2, 0x110);
        gui_io.sleepNs(300 * std.time.ns_per_ms);
        try g.remoteSend("<C-w><C-w>");
        gui_io.sleepNs(500 * std.time.ns_per_ms);
        if (try g.evalInt("win_gettype() == 'popup' ? 1 : 0") != 0) return error.CursorStayedInExternalWindow;
        host_window = 0;
    }

    var shut = try grab(alloc, g.app_pid, host_window);
    defer shut.deinit(alloc);

    const mark = try app_log.lineMark(alloc, log_path);
    try g.remoteSend(":");
    try g.remoteSend("echo 'cmdline popup must be painted over the window'");
    try app_log.waitAfter(alloc, log_path, "[panel_popup] show cmdline", mark, 5_000);
    try app_log.waitAfter(alloc, log_path, "[overlay] cmdline", mark, 5_000);
    gui_io.sleepNs(500 * std.time.ns_per_ms);
    // With the keyboard on the external window, the cmdline hangs from it.
    const shown = try app_log.linesAfter(alloc, log_path, "[panel_popup] show cmdline on surface ", mark);
    defer alloc.free(shown);
    var lines = std.mem.splitBackwardsScalar(u8, std.mem.trimEnd(u8, shown, "\n"), '\n');
    const last = lines.next() orelse return error.NoCmdlinePanel;
    const on_main = std.mem.endsWith(u8, last, " surface 1");
    if (on_main != (case != .ext_focused)) {
        std.debug.print("[gui] the cmdline is not on the surface with the keyboard\n", .{});
        // DIAG(ci-linux-gui-sway): where the windows are and which has the focus.
        if (g.mainWindowBounds()) |b| std.debug.print("[gui] DIAG main bounds ({d:.0},{d:.0}) {d:.0}x{d:.0}, clicked ({d:.0},{d:.0})\n", .{ b.x, b.y, b.w, b.h, b.x + b.w / 2, b.y + b.h * 0.8 });
        platform.dumpWindowsForPid(g.app_pid);
        return error.CmdlineOnWrongSurface;
    }

    var open = try grab(alloc, g.app_pid, host_window);
    defer open.deinit(alloc);
    const name = @tagName(case);
    var path_buf: [96]u8 = undefined;
    capture.writeImage(alloc, try std.fmt.bufPrint(&path_buf, "tmp/extwin_cmdline_{s}_closed" ++ capture.image_ext, .{name}), shut) catch {};
    capture.writeImage(alloc, try std.fmt.bufPrint(&path_buf, "tmp/extwin_cmdline_{s}_open" ++ capture.image_ext, .{name}), open) catch {};

    const area = try panelArea(alloc, mark);
    const share = @as(f64, @floatFromInt(try changedPixels(shut, open))) / area;
    std.debug.print("[gui] extwin_cmdline_popup_visible ({s}): window {d}x{d}, panel area {d}, changed/area {d:.3}\n", .{ name, open.w, open.h, area, share });
    try g.remoteSend("<Esc>");
    if (share < min_changed) {
        std.debug.print("[gui] the cmdline popup left the window under it showing: it was not painted\n", .{});
        return error.CmdlinePopupNotPainted;
    }
}

pub fn run(alloc: std.mem.Allocator) !void {
    if (!capture.hasScreenAccess()) {
        std.debug.print("[gui] skipped: no screen capture\n", .{});
        return error.SkipZigTest;
    }
    try runWith(alloc, .control);
    try runWith(alloc, .ext_focused);
    try runWith(alloc, .main_focused);
    try runWith(alloc, .cursor_moved);
}
