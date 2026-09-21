// mini_message_hosted_float_anchor — a mini message belongs to the window that
// draws the grid the cursor is in, including when that grid is a float an
// EXTERNAL window hosts.
//
// With `msg_pos.mini = "window"` the popup anchors to the window the cursor is
// in. The frontend decided that by asking "is the cursor's grid a float?" —
// and a float an external window hosts IS a float, so the answer sent the
// message to the MAIN window, the one surface that float is certainly not
// drawn in. The question is which surface COMPOSITES the grid
// (`zonvie_grid_info.placed_by_surface`), which the core answers.
//
// Asserted on the app's own `[mini_window]` line and the OS window rectangles:
// the mini has to sit inside the external window's frame, not the main one's.
// `mini_message_position` covers the other half of this — a float on the main
// surface anchoring to the main window — and this is the external one.
//
// macOS-only: the external window and its compositing are macOS frontend.

const std = @import("std");
const gui_io = @import("../../gui_io.zig");
const driver = @import("../../driver.zig");
const platform = driver.platform;
const Gui = driver.Gui;
const app_log = @import("../../app_log.zig");

const log_path = "tmp/gui_mini_hosted_anchor.log";
const max_windows = 16;

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

/// The OS window numbers the app says are minis, from `[mini_window]`.
fn miniWindowNumbers(alloc: std.mem.Allocator, since_ms: f64, out: *std.AutoHashMap(u32, void)) !void {
    const lines = try app_log.linesSince(alloc, log_path, "[mini_window]", since_ms);
    defer alloc.free(lines);
    var it = std.mem.splitScalar(u8, lines, '\n');
    while (it.next()) |line| {
        const number = app_log.field(line, "number") orelse continue;
        if (number <= 0) continue;
        try out.put(@intFromFloat(number), {});
    }
}

fn contains(set: []const platform.MainWindow, number: u32) bool {
    for (set) |w| if (w.number == number) return true;
    return false;
}

/// How much of `inner` lies inside `outer`, as a fraction of `inner`'s area.
fn overlapFraction(inner: platform.Bounds, outer: platform.Bounds) f64 {
    const w = @min(inner.x + inner.w, outer.x + outer.w) - @max(inner.x, outer.x);
    const h = @min(inner.y + inner.h, outer.y + outer.h) - @max(inner.y, outer.y);
    if (w <= 0 or h <= 0) return 0;
    const area = inner.w * inner.h;
    if (area <= 0) return 0;
    return (w * h) / area;
}

pub fn run(alloc: std.mem.Allocator) !void {
    std.Io.Dir.cwd().createDirPath(gui_io.io(), "tmp") catch {};
    std.Io.Dir.cwd().deleteFile(gui_io.io(), log_path) catch {};

    var g = try Gui.init(alloc, .{
        .app_args = &.{ "--extmessages", "--log", log_path },
        .config_dir = "test/gui/fixtures/config_mini_window_pos",
    });
    defer g.deinit();
    g.activateApp();
    gui_io.sleepNs(700 * std.time.ns_per_ms);

    var before_buf: [max_windows]platform.MainWindow = undefined;
    const before = before_buf[0..platform.windowsForPid(g.app_pid, &before_buf)];
    const main_b = platform.mainWindowBoundsForPid(g.app_pid) orelse return error.MainWindowNotFound;

    // An external window, and a float anchored inside it with searchable
    // content. The cursor ends in the float.
    try g.exec(
        \\luaeval('(function() local b = vim.api.nvim_create_buf(false, true) vim.api.nvim_buf_set_lines(b, 0, -1, true, {"host"}) _G.z_anchor = vim.api.nvim_open_win(b, true, {external=true, width=60, height=20}) return 1 end)()')
    );
    const ext_win = try waitNewWindow(g.app_pid, before, 100);
    gui_io.sleepNs(700 * std.time.ns_per_ms);

    try g.exec(
        \\luaeval('(function() local b = vim.api.nvim_create_buf(false, true) vim.api.nvim_buf_set_lines(b, 0, -1, true, {"alpha zonvie beta", "gamma zonvie delta"}) _G.z_float = vim.api.nvim_open_win(b, true, {relative="win", win=_G.z_anchor, row=2, col=2, width=30, height=5}) return 1 end)()')
    );
    gui_io.sleepNs(700 * std.time.ns_per_ms);

    // Gates. Each names a way this could pass while proving nothing.
    if (try g.evalInt("luaeval('(vim.api.nvim_get_current_win() == _G.z_float) and 1 or 0')") != 1) {
        return error.CursorNotInFloat;
    }
    if (try g.evalInt("luaeval('(vim.api.nvim_win_get_config(_G.z_float).win == _G.z_anchor) and 1 or 0')") != 1) {
        return error.FloatNotAnchoredToExternal;
    }
    // The float has to be composited INTO the external window. Counted by
    // size rather than by total: the app's own small overlays (a showcmd mini,
    // 122x13 here) come and go on their own, and a window of the float's size
    // is what "it got its own" would look like.
    var now_buf: [max_windows]platform.MainWindow = undefined;
    {
        const now = now_buf[0..platform.windowsForPid(g.app_pid, &now_buf)];
        var big: usize = 0;
        for (now) |w| {
            if (w.bounds.w >= 150 and w.bounds.h >= 100) big += 1;
        }
        var big_before: usize = 0;
        for (before) |w| {
            if (w.bounds.w >= 150 and w.bounds.h >= 100) big_before += 1;
        }
        if (big != big_before + 1) {
            std.debug.print(
                "[gui] expected one new window (the external one); the float looks composited into a window of its own\n",
                .{},
            );
            platform.dumpWindowsForPid(g.app_pid);
            return error.FloatGotItsOwnWindow;
        }
    }

    const t_search = try app_log.nowMs(alloc, log_path);
    var minis = std.AutoHashMap(u32, void).init(alloc);
    defer minis.deinit();

    // Search inside the float: search_count routes to the mini view.
    try g.remoteSend("/zonvie<CR>");

    var timer = gui_io.Timer.start();
    while (true) {
        if (timer.read() / std.time.ns_per_ms >= 10_000) return error.Timeout;

        const now = now_buf[0..platform.windowsForPid(g.app_pid, &now_buf)];
        try miniWindowNumbers(alloc, t_search, &minis);

        var found = false;
        for (now) |w| {
            if (contains(before, w.number)) continue;
            if (!minis.contains(w.number)) continue;
            found = true;

            const in_ext = overlapFraction(w.bounds, ext_win.bounds);
            const in_main = overlapFraction(w.bounds, main_b);
            std.debug.print(
                "[gui] mini #{d} ({d:.0},{d:.0},{d:.0},{d:.0}): {d:.0}% inside the external window, {d:.0}% inside the main one\n",
                .{ w.number, w.bounds.x, w.bounds.y, w.bounds.w, w.bounds.h, in_ext * 100, in_main * 100 },
            );

            if (in_ext < 0.5) {
                std.debug.print(
                    "[gui] the mini anchored away from the window that draws the float the cursor is in\n",
                    .{},
                );
                platform.dumpWindowsForPid(g.app_pid);
                return error.MiniAnchoredToWrongSurface;
            }
        }
        if (found) return;
        gui_io.sleepNs(100 * std.time.ns_per_ms);
    }
}
