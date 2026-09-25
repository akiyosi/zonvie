// mini_message_position — regression test for mini ext-message anchoring
// when the cursor sits inside a float (telescope-prompt shape).
//
// With msg_pos.mini = "grid" (the default), the mini popup anchors to the
// bottom-right of the grid under the cursor. Before the fix, a float grid
// was used as the anchor directly, so the popup appeared mid-screen glued
// to the float. The fix resolves a float to the non-float grid it is
// anchored to — for an editor-anchored float that is the global grid, i.e.
// the main window's bottom-right corner.
//
// Drives a search inside the float: search_count routes to the mini view
// by default (no custom config needed). Asserts every newly appeared OS
// window hugs the main window's bottom-right corner instead of the float's.

const std = @import("std");
const gui_io = @import("../../gui_io.zig");
const driver = @import("../../driver.zig");
const platform = driver.platform;
const Gui = driver.Gui;
const app_log = @import("../../app_log.zig");

const log_path = "tmp/gui_app.log";

const max_windows = 16;
const settle_polls = 4; // bounds unchanged for 4 * 250 ms = startup settled
const tol_px = 150.0; // float-anchored placement is off by several hundred px

/// Poll until the main-window bounds stop changing, then return them.
fn waitStableMainBounds(g: *Gui) !platform.Bounds {
    var timer = gui_io.Timer.start();
    var last: ?platform.Bounds = null;
    var same: u32 = 0;
    while (true) {
        if (timer.read() / std.time.ns_per_ms >= 15_000) return error.Timeout;
        gui_io.sleepNs(250 * std.time.ns_per_ms);
        const b = platform.mainWindowBoundsForPid(g.app_pid) orelse continue;
        if (last) |l| {
            if (l.x == b.x and l.y == b.y and l.w == b.w and l.h == b.h) {
                same += 1;
                if (same >= settle_polls) return b;
            } else {
                same = 0;
            }
        }
        last = b;
    }
}

fn contains(set: []const platform.MainWindow, number: u32) bool {
    for (set) |w| if (w.number == number) return true;
    return false;
}

/// The OS window numbers the app says are minis, from `[mini_window]`.
///
/// "Any window that was not there before" is not the same thing. A search
/// also puts a message float on screen, at the TOP-right of the main window
/// rather than the bottom-right — a different anchor, correctly — and this
/// scenario used to measure whichever of the two the poll happened to catch.
/// When it caught the float alone it reported `mini_bottom=73` and failed,
/// always with that same number, which read like a deterministic defect in
/// the anchoring. The anchoring was right every time: instrumented over
/// twelve runs it resolved to grid 1 at the same anchorY in all of them,
/// including the two that failed.
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

pub fn run(alloc: std.mem.Allocator) !void {
    // Or a previous scenario's minis are still named in it.
    std.Io.Dir.cwd().createDirPath(gui_io.io(), "tmp") catch {};
    std.Io.Dir.cwd().deleteFile(gui_io.io(), log_path) catch {};

    var g = try Gui.init(alloc, .{ .app_args = &.{ "--extmessages", "--log", log_path } });
    defer g.deinit();

    const main_b = try waitStableMainBounds(g);

    // Editor-anchored float under the cursor, with searchable content.
    try g.exec(
        "luaeval('(function() local b = vim.api.nvim_create_buf(false, true) " ++
            "vim.api.nvim_buf_set_lines(b, 0, -1, true, {\"alpha zonvie beta\", \"gamma zonvie delta\"}) " ++
            "_G.e2e_float = vim.api.nvim_open_win(b, true, {relative=\"editor\", row=3, col=3, width=30, height=5}) " ++
            "return 1 end)()')",
    );

    // The scenario tests nothing unless the cursor is actually in the float.
    const in_float = try g.evalInt("luaeval('(vim.api.nvim_get_current_win() == _G.e2e_float) and 1 or 0')");
    if (in_float != 1) return error.CursorNotInFloat;

    var before_buf: [max_windows]platform.MainWindow = undefined;
    const before = before_buf[0..platform.windowsForPid(g.app_pid, &before_buf)];

    const t_search = try app_log.nowMs(alloc, log_path);
    var minis = std.AutoHashMap(u32, void).init(alloc);
    defer minis.deinit();

    // Search inside the float: search_count routes to the mini view.
    try g.remoteSend("/zonvie<CR>");

    // Wait for a window that was not in the before-snapshot (the mini popup;
    // showcmd minis may also appear — same anchor logic, equally valid).
    // Minis stack upward from the anchor, so every new window must be
    // right-aligned and the bottom-most must sit at the main window bottom.
    var timer = gui_io.Timer.start();
    while (true) {
        if (timer.read() / std.time.ns_per_ms >= 10_000) return error.Timeout;

        var now_buf: [max_windows]platform.MainWindow = undefined;
        const now = now_buf[0..platform.windowsForPid(g.app_pid, &now_buf)];
        try miniWindowNumbers(alloc, t_search, &minis);

        var fresh: usize = 0;
        var max_bottom: f64 = -1;
        for (now) |w| {
            if (contains(before, w.number)) continue;
            // Only the app's own minis. Everything else a search puts on
            // screen answers to a different anchor.
            if (!minis.contains(w.number)) continue;
            fresh += 1;
            const d_right = (main_b.x + main_b.w) - (w.bounds.x + w.bounds.w);
            if (@abs(d_right) > tol_px) {
                std.debug.print(
                    "[gui] mini window not right-aligned: main=({d:.0},{d:.0},{d:.0},{d:.0}) mini=({d:.0},{d:.0},{d:.0},{d:.0})\n",
                    .{ main_b.x, main_b.y, main_b.w, main_b.h, w.bounds.x, w.bounds.y, w.bounds.w, w.bounds.h },
                );
                return error.MiniWindowMisplaced;
            }
            const bottom = w.bounds.y + w.bounds.h;
            if (bottom > max_bottom) max_bottom = bottom;
        }

        if (fresh > 0) {
            // Every fresh window, named: the assertion below is about the
            // bottom-most of them, and a failure that reports only that number
            // cannot say WHICH window was measured — nor whether it was a mini
            // at all.
            for (now) |w| {
                if (contains(before, w.number)) continue;
                if (!minis.contains(w.number)) continue;
                std.debug.print(
                    "[gui] fresh window #{d}: ({d:.0},{d:.0},{d:.0},{d:.0}) bottom={d:.0} right={d:.0}\n",
                    .{ w.number, w.bounds.x, w.bounds.y, w.bounds.w, w.bounds.h, w.bounds.y + w.bounds.h, w.bounds.x + w.bounds.w },
                );
            }
            const d_bottom = (main_b.y + main_b.h) - max_bottom;
            if (@abs(d_bottom) > tol_px) {
                std.debug.print(
                    "[gui] mini window not at main-window bottom: main_bottom={d:.0} mini_bottom={d:.0}\n",
                    .{ main_b.y + main_b.h, max_bottom },
                );
                return error.MiniWindowMisplaced;
            }
            return;
        }
        gui_io.sleepNs(100 * std.time.ns_per_ms);
    }
}
