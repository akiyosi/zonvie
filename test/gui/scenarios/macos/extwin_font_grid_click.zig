// extwin_font_grid_click — a click on an external window drawn in its own,
// smaller font names the cell under the pointer, down to the last row and
// column.
//
// The cell a pixel names was measured in the grid's own font but then clamped
// by GridInfo.rows/cols, which for a grid in its own font is its footprint in
// GLOBAL cells. At half the global size that is about half the grid, so every
// click in the lower or right half of the window landed on the same edge
// cell, and the window looked as if it still had the geometry it had before
// the font changed.
//
// Asserted on Neovim's own answer (winline()/wincol() of the cursor the click
// placed), with 'scrolloff' and 'sidescrolloff' at 0 so the click's cell is
// where the cursor stays.
//
// macOS-only: ExternalGridView's hit test and the window enumeration are
// macOS frontend.

const std = @import("std");
const driver = @import("../../driver.zig");
const platform = driver.platform;
const Gui = driver.Gui;
const gui_io = @import("../../gui_io.zig");
const app_log = @import("../../app_log.zig");

const log_path = "tmp/gui_extwin_font_grid_click.log";
const frame_marker = "[trace] event=frame_done";

/// The window's size in global cells before the font; at half size it holds
/// about twice as many rows and columns.
const open_rows: i64 = 20;
const open_cols: i64 = 60;

/// Points inside the window's bottom edge, so the press is on the grid rather
/// than on the frame's resize band; less than a row of the half-size font.
const edge_inset_pt: f64 = 6;


const Cell = struct { line: i64, col: i64 };

pub fn run(alloc: std.mem.Allocator) !void {
    if (!platform.accessibilityTrusted()) {
        std.debug.print("[gui] skipped: not trusted for Accessibility, so clicks cannot be posted.\n", .{});
        return error.SkipZigTest;
    }

    std.Io.Dir.cwd().createDirPath(gui_io.io(), "tmp") catch {};
    std.Io.Dir.cwd().deleteFile(gui_io.io(), log_path) catch {};

    var g = try Gui.init(alloc, .{
        .app_args = &.{ "--log", log_path },
        // Without the scrollbar, which takes a press on the right edge.
        .config_dir = "test/gui/fixtures/config_no_scrollbar",
    });
    defer g.deinit();
    g.activateApp();
    try app_log.waitFramesAfter(alloc, log_path, 1, 1, 0, 10_000);

    const before = driver.snapshotWindows(g.app_pid);

    // Lines longer than any width the window reaches, and more of them than
    // it shows, so the last row and column both hold text a click can land on.
    var buf: [1024]u8 = undefined;
    const open_win = try std.fmt.bufPrint(
        &buf,
        "luaeval('(function() local b = vim.api.nvim_create_buf(false, true) local l = {{}} " ++
            "for i = 1, 400 do l[i] = string.format(\"%3d \", i) .. string.rep(\"x\", 600) end " ++
            "vim.api.nvim_buf_set_lines(b, 0, -1, false, l) " ++
            "_G.z_ext = vim.api.nvim_open_win(b, true, {{external=true, width={d}, height={d}}}) " ++
            "for k, v in pairs({{scrolloff=0, sidescrolloff=0, wrap=false, number=false, relativenumber=false, " ++
            "signcolumn=\"no\", foldcolumn=\"0\", winbar=\"\"}}) do vim.wo[_G.z_ext][k] = v end " ++
            "return 1 end)()')",
        .{ open_cols, open_rows },
    );
    const open_mark = try app_log.lineMark(alloc, log_path);
    try g.exec(open_win);
    _ = try driver.waitNewWindow(g.app_pid, before.slice(), 100);
    try app_log.waitAfter(alloc, log_path, frame_marker, open_mark, 10_000);

    try g.exec("luaeval('(function() zonvie.set_window_font(_G.z_ext, { scale = 0.5 }) return 1 end)()')");
    const size = try waitFontGrid(g);
    std.debug.print("[gui] extwin font grid: {d}x{d} (opened {d}x{d})\n", .{ size.rows, size.cols, open_rows, open_cols });
    // Gate: the font has to have made the grid larger than its footprint in
    // global cells, or the clamp under test cannot bite.
    if (size.rows < open_rows + 4 or size.cols < open_cols + 8) return error.FontDidNotGrowTheGrid;

    const win = try waitWindowStable(g, before.slice());


    const bottom = try clickCell(g, win, win.bounds.x + win.bounds.w * 0.3, win.bounds.y + win.bounds.h - edge_inset_pt);
    const right_x = win.bounds.x + win.bounds.w - edge_inset_pt;
    const right = try clickCell(g, win, right_x, win.bounds.y + win.bounds.h * 0.5);
    const middle = try clickCell(g, win, win.bounds.x + win.bounds.w * 0.5, win.bounds.y + win.bounds.h * 0.5);

    // The frame is the grid's columns exactly, so a column is the window's
    // width over them; the right edge's resize band is wider than a column of
    // this font, so the press there names a column counted from that width
    // rather than the last one.
    const col_pt = win.bounds.w / @as(f64, @floatFromInt(size.cols));
    const want_right: i64 = @min(size.cols, @as(i64, @intFromFloat(@floor((right_x - win.bounds.x) / col_pt))) + 1);

    std.debug.print(
        "[gui] extwin font click: bottom row {d}/{d}, right col {d} (want {d} of {d}), middle ({d},{d})\n",
        .{ bottom.line, size.rows, right.col, want_right, size.cols, middle.line, middle.col },
    );

    if (bottom.line != size.rows) {
        std.debug.print("[gui] a click on the bottom row named row {d} of {d}\n", .{ bottom.line, size.rows });
        return error.BottomClickMissedLastRow;
    }
    if (right.col != want_right) {
        std.debug.print("[gui] a click near the right edge named column {d}, not {d} of {d}\n", .{ right.col, want_right, size.cols });
        return error.RightClickMissedItsColumn;
    }
    // Measured in the grid's own cells: in the global font's cells the
    // middle of the window would name a row about half as far down. The
    // frame includes its title bar, so its middle sits a little below the
    // grid's.
    if (@abs(middle.line - @divTrunc(size.rows, 2)) > 2 or @abs(middle.col - @divTrunc(size.cols, 2)) > 2) {
        std.debug.print("[gui] a click on the middle named ({d},{d}) of {d}x{d}\n", .{ middle.line, middle.col, size.rows, size.cols });
        return error.MiddleClickOffCentre;
    }
}

const GridSize = struct { rows: i64, cols: i64 };

/// The external window's size once the font has resized it and it has held
/// still for a while.
fn waitFontGrid(g: *Gui) !GridSize {
    var last: GridSize = .{ .rows = 0, .cols = 0 };
    var stable: u32 = 0;
    var tries: u32 = 0;
    while (tries < 100) : (tries += 1) {
        gui_io.sleepNs(100 * std.time.ns_per_ms);
        const now: GridSize = .{
            .rows = try g.evalInt("luaeval('vim.api.nvim_win_get_height(_G.z_ext)')"),
            .cols = try g.evalInt("luaeval('vim.api.nvim_win_get_width(_G.z_ext)')"),
        };
        if (now.rows != open_rows and now.rows == last.rows and now.cols == last.cols) {
            stable += 1;
            if (stable >= 5) return now;
        } else stable = 0;
        last = now;
    }
    std.debug.print("[gui] the external window never settled in its font: last {d}x{d}\n", .{ last.rows, last.cols });
    return error.FontGridNotSettled;
}

/// The external window once its frame has stopped moving.
fn waitWindowStable(g: *Gui, before: []const platform.MainWindow) !platform.MainWindow {
    var last: ?platform.MainWindow = null;
    var tries: u32 = 0;
    while (tries < 50) : (tries += 1) {
        gui_io.sleepNs(100 * std.time.ns_per_ms);
        const now = driver.newWindow(g.app_pid, before, 100) orelse continue;
        if (last) |l| {
            if (l.bounds.x == now.bounds.x and l.bounds.y == now.bounds.y and
                l.bounds.w == now.bounds.w and l.bounds.h == now.bounds.h) return now;
        }
        last = now;
    }
    return error.ExternalWindowNotStable;
}

/// Click (x, y) on `win` and read back where Neovim put the cursor.
fn clickCell(g: *Gui, win: platform.MainWindow, x: f64, y: f64) !Cell {
    const front = driver.topmostWindowAt(g.app_pid, x, y) orelse return error.NoWindowUnderClick;
    if (front.number != win.number) {
        std.debug.print("[gui] the external window is not frontmost at ({d:.0},{d:.0})\n", .{ x, y });
        platform.dumpWindowsForPid(g.app_pid);
        return error.ExternalWindowNotFrontmost;
    }
    // Park the cursor on a cell no click below names, so the answer is read
    // only once the click has moved it: the press reaches Neovim
    // asynchronously, and reading too early returns where an earlier click,
    // or the park, left it.
    try g.exec("luaeval('(function() vim.fn.win_execute(_G.z_ext, \"normal! gg0\") vim.api.nvim_win_set_cursor(_G.z_ext, {3, 2}) return 1 end)()')");
    const park = try readCell(g);
    // A click on an app or window that is not frontmost only brings it
    // forward and is not passed on as a mouseDown; how many that takes is
    // not fixed. The same point is pressed again until one arrives, which
    // cannot hide a wrong cell: every press names the same one.
    var attempt: u32 = 0;
    while (attempt < 3) : (attempt += 1) {
        if (!platform.clickAt(g.app_pid, x, y)) return error.ClickRefused;
        var tries: u32 = 0;
        while (tries < 15) : (tries += 1) {
            gui_io.sleepNs(100 * std.time.ns_per_ms);
            if (try g.evalInt("luaeval('vim.api.nvim_get_current_win() == _G.z_ext and 1 or 0')") != 1) continue;
            const now = try readCell(g);
            if (now.line != park.line or now.col != park.col) return now;
        }
    }
    std.debug.print("[gui] {d} clicks at ({d:.0},{d:.0}) never moved the cursor off ({d},{d})\n", .{ attempt, x, y, park.line, park.col });
    return error.ClickNotDelivered;
}

/// The cursor's cell in the current window, 1-based screen row and column.
fn readCell(g: *Gui) !Cell {
    return .{
        .line = try g.evalInt("winline()"),
        .col = try g.evalInt("wincol()"),
    };
}
