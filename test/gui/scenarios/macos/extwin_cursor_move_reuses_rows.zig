// extwin_cursor_move_reuses_rows — moving the cursor inside an EXTERNAL
// window must not redraw that window's rows, the way the same move does not
// redraw the main window's.
//
// The cursor is composited onto the drawable, never into the back texture, so
// a frame that carries only a cursor change can keep every pixel it already
// has. The main surface states that outright: GridSurfaceRenderer computes
// `noMainWorkFrame`/`skipMainPass` and encodes no main pass at all.
// ExternalGridView had the same intent — its `cursorOnlyFrame` sets the pass
// to `.load` — but no branch of its row ladder said "draw nothing", so the
// frame fell through to the full-redraw arm and re-encoded every row for each
// keystroke. With a hosted float present it took `reuseHostedContents` and
// drew nothing, so the window WITHOUT floats was the expensive one.
//
// Observed through the render trace rather than through pixels: a reused
// frame and a redrawn one are the same picture by construction, and only the
// trace says which of the two produced it.
//
// `nocursorline` matters. Cursorline rewrites the row the cursor leaves and
// the row it enters, which is real content change and correctly redraws; with
// it on this scenario would measure Neovim's highlighting, not the GUI.
//
// macOS-only: ExternalGridView is macOS frontend code.

const std = @import("std");
const driver = @import("../../driver.zig");
const platform = driver.platform;
const Gui = driver.Gui;
const app_log = @import("../../app_log.zig");
const gui_io = @import("../../gui_io.zig");

const log_path = "tmp/gui_extwin_cursor_reuse.log";

const grid_rows = 20;
const grid_cols = 60;
/// Each one moves the cursor a row without touching any row's content.
const cursor_keys = 8;
const key_gap_ms = 120;

/// How many of those moves must produce a frame that drew no row. Not all of
/// them will: a blink toggle or a redraw landing in the same frame legitimately
/// draws. A clear majority is the signal, and zero is the defect.
const min_reuse_frames = 3;

fn reuseFrames(alloc: std.mem.Allocator, surface: i64, since_ms: f64) !usize {
    var marker_buf: [96]u8 = undefined;
    const marker = try std.fmt.bufPrint(
        &marker_buf,
        "event=retained_content_reuse surface={d} root_row_draws=0",
        .{surface},
    );
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

    try g.exec(
        "luaeval('(function() vim.o.cursorline = false vim.o.number = false " ++
            "local b = vim.api.nvim_create_buf(false, true) local l = {} " ++
            "for i = 1, 400 do l[i] = string.format(\"%3d plain line\", i) end " ++
            "vim.api.nvim_buf_set_lines(b, 0, -1, false, l) " ++
            "_G.z_extwin = vim.api.nvim_open_win(b, true, {external=true, width=" ++
            std.fmt.comptimePrint("{d}", .{grid_cols}) ++ ", height=" ++
            std.fmt.comptimePrint("{d}", .{grid_rows}) ++ "}) " ++
            "vim.api.nvim_win_set_cursor(_G.z_extwin, {100, 0}) return 1 end)()')",
    );
    try g.waitWindowCount(base_windows + 1, 10_000);
    // Let the first frames settle, so the moves below are not racing the
    // window's own seeding (which legitimately redraws everything).
    gui_io.sleepNs(1200 * std.time.ns_per_ms);

    const ext_grid: i64 = blk: {
        const line = (try app_log.lastLineSince(alloc, log_path, "[external_window] open gridId=", 0)) orelse
            return error.NoExternalWindowOpened;
        defer alloc.free(line);
        const v = app_log.field(line, "gridId") orelse return error.ExternalGridIdUnparsable;
        break :blk @intFromFloat(v);
    };

    const t0 = try app_log.nowMs(alloc, log_path);
    const row_before = try g.evalInt("line('.')");
    const topline_before = try g.evalInt("line('w0')");

    var sent: usize = 0;
    while (sent < cursor_keys) : (sent += 1) {
        // Down one row, well inside the viewport, so nothing scrolls.
        try g.remoteSend("j");
        gui_io.sleepNs(key_gap_ms * std.time.ns_per_ms);
    }

    const row_after = try g.evalInt("line('.')");
    const topline_after = try g.evalInt("line('w0')");
    const frames = try reuseFrames(alloc, ext_grid, t0);

    std.debug.print(
        "[gui] extwin cursor: row {d} -> {d}, topline {d} -> {d}, reuse frames={d}\n",
        .{ row_before, row_after, topline_before, topline_after, frames },
    );

    // Gate: without movement there was no cursor-only frame to reuse, and
    // every count below would be measuring an app that ignored the keys.
    if (row_after == row_before) return error.CursorDidNotMove;
    // Gate: a scroll makes each frame carry real content, which must redraw.
    if (topline_after != topline_before) return error.ViewScrolledInsteadOfCursorOnly;

    if (frames < min_reuse_frames) {
        std.debug.print(
            "[gui] the external window redrew its rows for a cursor move: " ++
                "{d} reused frames, wanted at least {d}\n",
            .{ frames, min_reuse_frames },
        );
        return error.ExternalCursorMoveRedrewRows;
    }
}
