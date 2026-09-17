// main_cursor_move_reuses_rows — moving the cursor in the MAIN window must not
// redraw anything, the way the same move does not redraw an external window's
// rows.
//
// The twin of scenarios/macos/extwin_cursor_move_reuses_rows.zig, and the
// reason it is a pair: the two surfaces used to reach the same picture by
// different routes. `ExternalGridView` recognises a cursor-only commit and
// reuses the surface. The main surface marked the cursor's ROOT row dirty from
// `MetalTerminalView.submitVerticesRowRaw` and let that row keep the frame
// alive — which also banded that row, redrew it, and pulled every layer
// crossing it into the redraw. Both arrived at "the cursor moved"; only one
// said so. `MetalTerminalRenderer` now records the commit as cursor-only, and
// `noMainWorkFrame`/`skipMainPass` encode no main pass at all.
//
// Observed through the app log rather than through pixels: a reused frame and
// a redrawn one are the same picture by construction, and only the log says
// which of the two produced it. `skipMainPass=true` names its reason, and only
// `noop` is this one — `blink-only` is a different frame the blink clock
// produces on its own, so counting it would let a passing run mean nothing.
//
// `nocursorline` matters, exactly as in the external twin: cursorline rewrites
// the row the cursor leaves and the row it enters, which is real content change
// and correctly redraws.
//
// macOS-only: MetalTerminalRenderer is macOS frontend code.

const std = @import("std");
const driver = @import("../../driver.zig");
const Gui = driver.Gui;
const app_log = @import("../../app_log.zig");
const gui_io = @import("../../gui_io.zig");

const log_path = "tmp/gui_main_cursor_reuse.log";

/// Each one moves the cursor a row without touching any row's content.
const cursor_keys = 8;
const key_gap_ms = 120;

/// How many of those moves must produce a frame that encoded no main pass. Not
/// all of them will: a redraw landing in the same frame legitimately draws. A
/// clear majority is the signal, and zero is the defect.
const min_reuse_frames = 3;

const marker = "[draw] skipMainPass=true (noop";

fn reuseFrames(alloc: std.mem.Allocator, since_ms: f64) !usize {
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
        .config_dir = "test/gui/fixtures/config",
    });
    defer g.deinit();

    // Everything that would repaint a row on its own: the cursorline pair, the
    // ruler and showcmd (both track the cursor), and a statusline that could
    // carry either. A steady cursor keeps the blink clock from producing frames
    // of its own alongside the ones being counted.
    try g.exec("execute('set nocursorline nonumber noruler noshowcmd laststatus=0 scrolloff=0 nowrap guicursor+=a:blinkon0')");
    try g.exec(
        \\setline(1, map(range(1, 400), {_, i -> printf('%3d plain line', i)}))
    );
    try g.exec("execute('normal! 100G0')");
    // Let the first frames settle, so the moves below are not racing the
    // buffer's own painting (which legitimately redraws everything).
    gui_io.sleepNs(1500 * std.time.ns_per_ms);

    const t0 = try app_log.nowMs(alloc, log_path);
    const row_before = try g.evalInt("line('.')");
    const topline_before = try g.evalInt("line('w0')");

    var sent: usize = 0;
    while (sent < cursor_keys) : (sent += 1) {
        // Down one row, well inside the viewport, so nothing scrolls.
        try g.remoteSend("j");
        gui_io.sleepNs(key_gap_ms * std.time.ns_per_ms);
    }
    gui_io.sleepNs(400 * std.time.ns_per_ms);

    const row_after = try g.evalInt("line('.')");
    const topline_after = try g.evalInt("line('w0')");
    const frames = try reuseFrames(alloc, t0);

    std.debug.print(
        "[gui] main cursor: row {d} -> {d}, topline {d} -> {d}, reuse frames={d}\n",
        .{ row_before, row_after, topline_before, topline_after, frames },
    );

    // Gate: without movement there was no cursor-only frame to reuse, and
    // every count below would be measuring an app that ignored the keys.
    if (row_after == row_before) return error.CursorDidNotMove;
    // Gate: a scroll makes each frame carry real content, which must redraw.
    if (topline_after != topline_before) return error.ViewScrolledInsteadOfCursorOnly;

    if (frames < min_reuse_frames) {
        std.debug.print(
            "[gui] the main window redrew for a cursor move: " ++
                "{d} reused frames, wanted at least {d}\n",
            .{ frames, min_reuse_frames },
        );
        return error.MainCursorMoveRedrewRows;
    }
}
