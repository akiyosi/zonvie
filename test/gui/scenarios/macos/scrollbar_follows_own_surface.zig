// scrollbar_follows_own_surface — a window's scrollbar shows a window's own
// content, and only that.
//
// Both frontends asked the core for grid -1 on the MAIN window — the cursor's
// grid, wherever it is — so moving the cursor into an external window and
// scrolling there moved the main window's knob too, over content it does not
// draw. And both asked an external window for its OWN root, so a float that
// window hosts scrolled without moving the knob beside it. The rule is the
// core's now (`zonvie_core_try_scrollbar_grid`): the cursor's grid when this
// surface composites it, the surface's own root otherwise.
//
// Read from the app's own `[scrollbar]` line rather than from pixels: a knob a
// few points tall is exactly the kind of thing a golden cannot tell apart from
// noise, and the line names the grid each surface decided to follow, which is
// the decision under test.
//
// Scrolled from the KEYBOARD. A posted gesture has to win a targeting race
// with whatever window is frontmost under the pointer, and that race is not
// what this measures.
//
// Covers what each knob SHOWS. What it ACTS on — page and drag — reads the
// same expression (`scrollbarInteractionGrid`, which is
// `scrollbarGridNonBlocking` for this surface), so it cannot disagree with the
// display without that expression changing. Triggering it would mean clicking
// a track that auto-hides, at coordinates measured from a window that may not
// be frontmost, which is the fragility this file's keyboard scrolling exists
// to avoid. `[scrollbar_action]` records the decision instead.
//
// macOS-only: ExternalGridView and the window enumeration are macOS frontend.

const std = @import("std");
const driver = @import("../../driver.zig");
const platform = driver.platform;
const Gui = driver.Gui;
const gui_io = @import("../../gui_io.zig");
const app_log = @import("../../app_log.zig");

const log_path = "tmp/gui_scrollbar_surface.log";
const marker = "[scrollbar]";
const max_windows = 16;

const Report = struct { surface: i64, grid: i64, topline: i64 };

/// The last `[scrollbar]` line since `since_ms` from the main surface
/// (`want_main`) or from any other one. Null when none reported.
fn lastFor(alloc: std.mem.Allocator, want_main: bool, since_ms: f64) !?Report {
    const lines = try app_log.linesSince(alloc, log_path, marker, since_ms);
    defer alloc.free(lines);
    var out: ?Report = null;
    var it = std.mem.splitScalar(u8, lines, '\n');
    while (it.next()) |line| {
        const sf = app_log.field(line, "surface") orelse continue;
        const surface: i64 = @intFromFloat(sf);
        if ((surface == 1) != want_main) continue;
        const gr = app_log.field(line, "grid") orelse continue;
        const tl = app_log.field(line, "topline") orelse continue;
        out = .{ .surface = surface, .grid = @intFromFloat(gr), .topline = @intFromFloat(tl) };
    }
    return out;
}

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

pub fn run(alloc: std.mem.Allocator) !void {
    std.Io.Dir.cwd().createDirPath(gui_io.io(), "tmp") catch {};
    std.Io.Dir.cwd().deleteFile(gui_io.io(), log_path) catch {};

    var g = try Gui.init(alloc, .{ .app_args = &.{ "--log", log_path } });
    defer g.deinit();
    g.activateApp();
    gui_io.sleepNs(700 * std.time.ns_per_ms);

    // The main window, with far more lines than it shows so its knob has
    // somewhere to be.
    try g.exec(
        \\luaeval('(function() _G.z_main = vim.api.nvim_get_current_win() local l = {} for i = 1, 800 do l[i] = string.format("%3d main line", i) end vim.api.nvim_buf_set_lines(0, 0, -1, false, l) return 1 end)()')
    );
    gui_io.sleepNs(400 * std.time.ns_per_ms);

    // Gate: the main window has to have reported a knob position at all, or
    // "it did not move" proves nothing.
    const t0 = try app_log.nowMs(alloc, log_path);
    try g.exec("luaeval('(function() vim.api.nvim_set_current_win(_G.z_main) return 1 end)()')");
    gui_io.sleepNs(300 * std.time.ns_per_ms);
    try g.remoteSend("<C-e>");
    gui_io.sleepNs(500 * std.time.ns_per_ms);
    const main_seen = (try lastFor(alloc, true, t0)) orelse {
        std.debug.print("[gui] the main window never reported a scrollbar position\n", .{});
        return error.MainScrollbarSilent;
    };
    std.debug.print("[gui] main window: grid {d}, topline {d}\n", .{ main_seen.grid, main_seen.topline });


    var before_buf: [max_windows]platform.MainWindow = undefined;
    const before = before_buf[0..platform.windowsForPid(g.app_pid, &before_buf)];

    // An external window, likewise longer than it shows.
    try g.exec(
        \\luaeval('(function() local b = vim.api.nvim_create_buf(false, true) local l = {} for i = 1, 800 do l[i] = string.format("%3d host line", i) end vim.api.nvim_buf_set_lines(b, 0, -1, false, l) _G.z_anchor = vim.api.nvim_open_win(b, true, {external=true, width=60, height=20}) return 1 end)()')
    );
    _ = try waitNewWindow(g.app_pid, before, 100);
    gui_io.sleepNs(800 * std.time.ns_per_ms);

    // Now scroll the EXTERNAL window, from the keyboard, with the cursor in it.
    try g.exec("luaeval('(function() vim.api.nvim_set_current_win(_G.z_anchor) return 1 end)()')");
    gui_io.sleepNs(400 * std.time.ns_per_ms);

    const t1 = try app_log.nowMs(alloc, log_path);
    var n: u32 = 0;
    while (n < 12) : (n += 1) {
        try g.remoteSend("<C-e>");
        gui_io.sleepNs(60 * std.time.ns_per_ms);
    }
    gui_io.sleepNs(800 * std.time.ns_per_ms);

    // The external window's own viewport must have moved, or nothing was
    // scrolled and the assertion below is vacuous.
    const host_top = try g.evalInt("luaeval('vim.fn.getwininfo(_G.z_anchor)[1].topline')");
    if (host_top <= 1) {
        std.debug.print("[gui] the external window did not scroll (topline {d})\n", .{host_top});
        return error.ExternalWindowDidNotScroll;
    }

    const ext = try lastFor(alloc, false, t1);
    const main_after = try lastFor(alloc, true, t1);

    // Anti-vacuity: the external window's own knob HAS to have moved, or the
    // main window standing still says nothing.
    const e = ext orelse {
        std.debug.print("[gui] the external window's scrollbar never reported\n", .{});
        return error.ExternalScrollbarSilent;
    };
    std.debug.print(
        "[gui] external surface {d}: grid {d}, topline {d}\n",
        .{ e.surface, e.grid, e.topline },
    );
    if (e.topline <= 1) {
        std.debug.print("[gui] the external window's knob did not move\n", .{});
        return error.ExternalScrollbarDidNotMove;
    }

    if (main_after) |m| {
        std.debug.print(
            "[gui] the MAIN window's scrollbar followed a scroll in another window: grid {d}, topline {d}\n",
            .{ m.grid, m.topline },
        );
        return error.MainScrollbarFollowedAnotherSurface;
    }

    // Phase 2: a float the EXTERNAL window hosts. Its content is that window's
    // content, so that window's knob is the one that has to move — and the
    // main window's still must not. Reported from Windows: the float scrolled
    // and the MAIN window's knob was the one that moved.
    try g.exec(
        \\luaeval('(function() local b = vim.api.nvim_create_buf(false, true) local l = {} for i = 1, 800 do l[i] = string.format("%3d float line", i) end vim.api.nvim_buf_set_lines(b, 0, -1, false, l) _G.z_float = vim.api.nvim_open_win(b, true, {relative="win", win=_G.z_anchor, row=2, col=2, width=40, height=10}) return 1 end)()')
    );
    gui_io.sleepNs(800 * std.time.ns_per_ms);

    // Gate: it has to be composited INTO the external window. A float given a
    // window of its own is a surface, and this would test nothing.
    if (try g.evalInt("luaeval('(vim.api.nvim_win_get_config(_G.z_float).win == _G.z_anchor) and 1 or 0')") != 1) {
        return error.FloatNotAnchoredToExternal;
    }

    const t2 = try app_log.nowMs(alloc, log_path);
    var k: u32 = 0;
    while (k < 12) : (k += 1) {
        try g.remoteSend("<C-e>");
        gui_io.sleepNs(60 * std.time.ns_per_ms);
    }
    gui_io.sleepNs(800 * std.time.ns_per_ms);

    const float_top = try g.evalInt("luaeval('vim.fn.getwininfo(_G.z_float)[1].topline')");
    if (float_top <= 1) {
        std.debug.print("[gui] the hosted float did not scroll (topline {d})\n", .{float_top});
        return error.HostedFloatDidNotScroll;
    }

    const ext2 = (try lastFor(alloc, false, t2)) orelse {
        std.debug.print(
            "[gui] the external window's scrollbar did not move while a float it hosts scrolled\n",
            .{},
        );
        return error.HostSurfaceScrollbarSilent;
    };
    std.debug.print(
        "[gui] hosted float scrolled: external surface {d} follows grid {d}, topline {d}\n",
        .{ ext2.surface, ext2.grid, ext2.topline },
    );

    if (try lastFor(alloc, true, t2)) |m2| {
        std.debug.print(
            "[gui] the MAIN window's scrollbar followed a float another window hosts: grid {d}, topline {d}\n",
            .{ m2.grid, m2.topline },
        );
        return error.MainScrollbarFollowedHostedFloat;
    }
}
