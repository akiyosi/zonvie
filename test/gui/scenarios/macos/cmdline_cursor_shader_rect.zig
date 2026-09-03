// cmdline_cursor_shader_rect — the cursor rect a shader receives while the
// cursor is in the ext-cmdline must be the cursor's true on-screen rect.
//
// Reported symptom: with cursor_blaze.glsl loaded, moving between the
// ext-cmdline and the main window drew a wild cursor trail. A cursor shader
// interpolates from iPreviousCursor to iCurrentCursor, so one bogus endpoint
// is enough to produce it.
//
// Cause: per-grid rendering changed vertex positions from NDC to grid-local
// pixels, and ExternalGridView's projection still ran the NDC formula over
// them. The result landed thousands of pixels away, off screen.
//
// Asserted on [shader_cursor], the value makeCustomShaderUniforms actually
// hands the shader, against the cmdline window's own measured column band —
// a rect merely somewhere inside the MAIN window would still be wrong here.
//
// macOS-only: the shader cursor plumbing lives in the macOS frontend.

const std = @import("std");
const driver = @import("../../driver.zig");
const platform = driver.platform;
const Gui = driver.Gui;
const app_log = @import("../../app_log.zig");
const gui_io = @import("../../gui_io.zig");

const log_path = "tmp/gui_cmdline_cursor_shader.log";
const marker = "[shader_cursor]";
const max_windows = 16;


const Rect = struct { x: f64, y: f64, w: f64, h: f64 };

fn waitCursorRect(alloc: std.mem.Allocator, since_ms: f64, timeout_ms: u64) !Rect {
    var timer = gui_io.Timer.start();
    while (true) {
        if (try app_log.lastLineSince(alloc, log_path, marker, since_ms)) |line| {
            defer alloc.free(line);
            return .{
                .x = app_log.field(line, "x") orelse return error.CursorRectUnparsable,
                .y = app_log.field(line, "y") orelse return error.CursorRectUnparsable,
                .w = app_log.field(line, "w") orelse return error.CursorRectUnparsable,
                .h = app_log.field(line, "h") orelse return error.CursorRectUnparsable,
            };
        }
        if (timer.read() / std.time.ns_per_ms >= timeout_ms) return error.NoCursorRectPublished;
        gui_io.sleepNs(100 * std.time.ns_per_ms);
    }
}

fn newWindow(pid: i32, before: []const platform.MainWindow) ?platform.MainWindow {
    var buf: [max_windows]platform.MainWindow = undefined;
    const now = buf[0..platform.windowsForPid(pid, &buf)];
    outer: for (now) |w| {
        for (before) |b| {
            if (b.number == w.number) continue :outer;
        }
        return w;
    }
    return null;
}

pub fn run(alloc: std.mem.Allocator) !void {
    std.Io.Dir.cwd().createDirPath(gui_io.io(), "tmp") catch {};
    std.Io.Dir.cwd().deleteFile(gui_io.io(), log_path) catch {};

    var g = try Gui.init(alloc, .{
        .app_args = &.{ "--extcmdline", "--log", log_path },
        .config_dir = "test/gui/fixtures/config_animated_shader",
    });
    defer g.deinit();
    g.activateApp();

    try g.exec("execute('set laststatus=0 noruler')");

    var main_buf: [max_windows]platform.MainWindow = undefined;
    const main_wins = main_buf[0..platform.windowsForPid(g.app_pid, &main_buf)];
    if (main_wins.len == 0) return error.MainWindowNotFound;
    const main_win = main_wins[0];

    // Open the ext-cmdline and type, so the cursor sits in it and the
    // cmdline view is the one publishing the shader cursor rect.
    const t0 = try app_log.nowMs(alloc, log_path);
    try g.remoteSend(":");
    gui_io.sleepNs(400 * std.time.ns_per_ms);
    try g.remoteSend("echo");
    gui_io.sleepNs(600 * std.time.ns_per_ms);

    const cmdline_win = newWindow(g.app_pid, main_wins) orelse return error.CmdlineWindowNotFound;
    const rect = try waitCursorRect(alloc, t0, 10_000);

    const metrics = blk: {
        const line = (try app_log.lastLineSince(alloc, log_path, "[resizeExternalWindows]", 0)) orelse
            return error.BackingScaleUnknown;
        defer alloc.free(line);
        break :blk .{
            .scale = app_log.field(line, "scale") orelse return error.BackingScaleUnknown,
            .cell_w = app_log.field(line, "cellW") orelse return error.CellMetricsUnknown,
            .cell_h = app_log.field(line, "cellH") orelse return error.CellMetricsUnknown,
        };
    };

    // The rect is in the MAIN VIEW's drawable pixels, whose origin sits
    // below the window's title bar. Horizontal placement carries no such
    // chrome term, so the cmdline window's x band is an exact expectation
    // while y only gets a generous in-window bound.
    const rel_x = (cmdline_win.bounds.x - main_win.bounds.x) * metrics.scale;
    const win_w = cmdline_win.bounds.w * metrics.scale;
    const main_h = main_win.bounds.h * metrics.scale;
    std.debug.print(
        "[gui] cmdline cursor shader rect: ({d:.0},{d:.0}) {d:.0}x{d:.0}; " ++
            "cmdline x band {d:.0}..{d:.0}, main height {d:.0}px\n",
        .{ rect.x, rect.y, rect.w, rect.h, rel_x, rel_x + win_w, main_h },
    );

    // Feeding grid-local pixels through the old NDC formula multiplied them
    // by the viewport width, so x landed astronomically outside this band.
    if (rect.x < rel_x or rect.x > rel_x + win_w) {
        std.debug.print(
            "[gui] the shader cursor rect is outside the cmdline window's columns\n",
            .{},
        );
        return error.CursorShaderRectOutsideCmdline;
    }
    // iCurrentCursor.y is the cursor's BOTTOM edge, so the rect spans y-h..y.
    if (rect.y - rect.h < 0 or rect.y > main_h) {
        std.debug.print(
            "[gui] the shader cursor rect is outside the main window vertically\n",
            .{},
        );
        return error.CursorShaderRectOffScreen;
    }

    // One cell, not the whole ext drawable: the projection must not take the
    // cursor's size from anything but the cursor's own vertices.
    if (@abs(rect.w - metrics.cell_w) > 1 or @abs(rect.h - metrics.cell_h) > 1) {
        std.debug.print(
            "[gui] the rect is not one cell: got {d:.0}x{d:.0}, cell is {d:.0}x{d:.0}\n",
            .{ rect.w, rect.h, metrics.cell_w, metrics.cell_h },
        );
        return error.CursorShaderRectNotOneCell;
    }
}
