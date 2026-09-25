// extwin_blink_without_cursor_skips — an external window that does not hold
// the cursor must not draw a frame every time the cursor blinks.
//
// `scheduleNextBlink` calls `setNeedsDisplay` on EVERY external view on every
// toggle, whether or not that view has a cursor to show. The main surface has
// long refused the resulting frame — GridSurfaceRenderer's blink gate returns
// when the toggle is the only change and the cursor vertex count is zero, on
// the grounds that the whole cycle (drawable acquire, copy pass, present,
// next-vsync wake) produces an identical picture. ExternalGridView had no such
// gate, so every open external surface encoded and presented a frame per
// toggle, and the count scaled with the number of windows.
//
// Measured before the gate, two idle external windows over 25 s with the
// cursor parked in the main window: 118 such frames, 0 of them changing a
// pixel. After: 111 refusals in the same workload.
//
// The assertion is therefore on the refusals. On the unmodified surface the
// marker does not exist and the count is 0, which is what makes this a test.
// The second assertion — that the surface was woken at all — keeps a broken
// blink timer or a dead draw loop from passing it by producing nothing.
//
// macOS-only: ExternalGridView is macOS frontend code.

const std = @import("std");
const driver = @import("../../driver.zig");
const Gui = driver.Gui;
const app_log = @import("../../app_log.zig");
const gui_io = @import("../../gui_io.zig");

const log_path = "tmp/gui_extwin_blink_no_cursor.log";

const ext_rows = 20;
const ext_cols = 60;

/// Long enough that the blink phases below produce many toggles, short enough
/// that the scenario stays in the suite's budget.
const idle_ms = 8_000;
/// 400 ms on, 400 ms off — 2.5 toggles/s, so ~20 in the idle window. Well
/// clear of the threshold below even if the machine is busy.
const blink_on_ms = 400;
const blink_off_ms = 400;
/// A quarter of what the interval predicts. The defect produces zero.
const min_refusals = 5;

fn countMarker(alloc: std.mem.Allocator, marker: []const u8, since_ms: f64) !usize {
    const lines = try app_log.linesSince(alloc, log_path, marker, since_ms);
    defer alloc.free(lines);
    var count: usize = 0;
    var it = std.mem.splitScalar(u8, lines, '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        count += 1;
    }
    return count;
}

pub fn run(alloc: std.mem.Allocator) !void {
    std.Io.Dir.cwd().createDirPath(gui_io.io(), "tmp") catch {};
    std.Io.Dir.cwd().deleteFile(gui_io.io(), log_path) catch {};

    var g = try Gui.init(alloc, .{
        .app_args = &.{ "--log", log_path },
        .config_dir = "test/gui/fixtures/config_render_trace",
    });
    defer g.deinit();

    const base_windows = g.windowCount();

    // A blinking block cursor, and no cursorline: cursorline would rewrite
    // rows and make the frames this counts legitimate content updates.
    try g.exec(
        "luaeval('(function() vim.o.cursorline = false vim.o.number = false " ++
            "vim.o.guicursor = \"a:block-blinkwait300-blinkon" ++
            std.fmt.comptimePrint("{d}", .{blink_on_ms}) ++ "-blinkoff" ++
            std.fmt.comptimePrint("{d}", .{blink_off_ms}) ++ "\" return 1 end)()')",
    );

    try g.exec(
        "luaeval('(function() local b = vim.api.nvim_create_buf(false, true) local l = {} " ++
            "for i = 1, 200 do l[i] = string.format(\"%3d idle line\", i) end " ++
            "vim.api.nvim_buf_set_lines(b, 0, -1, false, l) " ++
            "_G.z_ext = vim.api.nvim_open_win(b, true, {external=true, width=" ++
            std.fmt.comptimePrint("{d}", .{ext_cols}) ++ ", height=" ++
            std.fmt.comptimePrint("{d}", .{ext_rows}) ++ "}) return 1 end)()')",
    );
    try g.waitWindowCount(base_windows + 1, 10_000);

    const ext_grid: i64 = blk: {
        const line = (try app_log.lastLineSince(alloc, log_path, "[external_window] open gridId=", 0)) orelse
            return error.NoExternalWindowOpened;
        defer alloc.free(line);
        const v = app_log.field(line, "gridId") orelse return error.ExternalGridIdUnparsable;
        break :blk @intFromFloat(v);
    };

    // The cursor goes back to the main window. The external surface now has
    // nothing to blink, and every toggle it is woken for is a wasted frame.
    try g.exec("luaeval('(function() vim.api.nvim_set_current_win(1000) return 1 end)()')");
    gui_io.sleepNs(1200 * std.time.ns_per_ms);

    const t0 = try app_log.nowMs(alloc, log_path);
    gui_io.sleepNs(idle_ms * std.time.ns_per_ms);

    var refused_buf: [96]u8 = undefined;
    const refused_marker = try std.fmt.bufPrint(
        &refused_buf,
        "[ext_draw_early_exit] gridId={d} blink-no-cursor",
        .{ext_grid},
    );
    const refusals = try countMarker(alloc, refused_marker, t0);
    const toggles = try countMarker(alloc, "[blink] blink toggled to ", t0);

    std.debug.print(
        "[gui] extwin blink without cursor: surface={d} toggles={d} refused_frames={d}\n",
        .{ ext_grid, toggles, refusals },
    );

    // Gate: the blink timer ran. Without toggles there is nothing to refuse
    // and a zero below would mean nothing.
    if (toggles < min_refusals) {
        std.debug.print(
            "[gui] the cursor blinked only {d} time(s) in {d}ms; guicursor did not take\n",
            .{ toggles, idle_ms },
        );
        return error.CursorDidNotBlink;
    }

    if (refusals < min_refusals) {
        std.debug.print(
            "[gui] the external surface refused only {d} of {d} blink wake-ups " ++
                "(need {d}) — it is drawing frames for a cursor it does not have\n",
            .{ refusals, toggles, min_refusals },
        );
        return error.BlinkWithoutCursorDrewFrames;
    }
}
