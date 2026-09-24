// extwin_animated_shader_reuses_rows — with an animating custom shader, an
// idle EXTERNAL window must keep its rows, as the main window keeps its own.
//
// An animating shader keeps every surface's draw loop running, so a frame is
// encoded each vsync with nothing in Neovim changing. The main surface skips
// its row pass on such a frame (`noMainWorkFrame`) and hands the retained
// texture to the shader chain. The external surface asked for a cursor-only
// frame before it would reuse its texture, and refused on `shaderAnimates`
// besides, so it cleared and redrew every row of every frame. The shader chain
// only reads that texture, so reusing it is what the main surface already does.
//
// Measured on the load gate's trace: an external frame that decided not to
// reuse while nothing was dirty is the exposure.
//
// macOS-only: ExternalGridView is macOS frontend code.

const std = @import("std");
const driver = @import("../../driver.zig");
const platform = driver.platform;
const Gui = driver.Gui;
const app_log = @import("../../app_log.zig");
const gui_io = @import("../../gui_io.zig");

const log_path = "tmp/gui_extwin_anim_reuse.log";
const max_windows = 16;
const idle_ms = 1500;

fn waitNewWindow(pid: i32, before: []const platform.MainWindow) !void {
    var timer = gui_io.Timer.start();
    while (true) {
        var buf: [max_windows]platform.MainWindow = undefined;
        const now = buf[0..platform.windowsForPid(pid, &buf)];
        if (now.len > before.len) return;
        if (timer.read() / std.time.ns_per_ms >= 10_000) return error.ExternalWindowNotFound;
        gui_io.sleepNs(100 * std.time.ns_per_ms);
    }
}

const Counts = struct { frames: usize, redrawn_idle: usize };

fn externalLoadFrames(alloc: std.mem.Allocator, since_ms: f64) !Counts {
    const lines = try app_log.linesSince(alloc, log_path, "gate=load", since_ms);
    defer alloc.free(lines);
    var c = Counts{ .frames = 0, .redrawn_idle = 0 };
    var it = std.mem.splitScalar(u8, lines, '\n');
    while (it.next()) |line| {
        if (line.len == 0 or std.mem.indexOf(u8, line, "surface=1 ") != null) continue;
        c.frames += 1;
        const idle = std.mem.indexOf(u8, line, "layout=0") != null and
            std.mem.indexOf(u8, line, "rowDirty=0") != null and
            std.mem.indexOf(u8, line, "gpuScroll=0") != null;
        if (idle and std.mem.indexOf(u8, line, "-> reuse=0") != null) c.redrawn_idle += 1;
    }
    return c;
}

pub fn run(alloc: std.mem.Allocator) !void {
    std.Io.Dir.cwd().createDirPath(gui_io.io(), "tmp") catch {};
    std.Io.Dir.cwd().deleteFile(gui_io.io(), log_path) catch {};

    var g = try Gui.init(alloc, .{
        .app_args = &.{ "--log", log_path },
        .config_dir = "test/gui/fixtures/config_animated_shader",
        .app_env = &.{.{ "ZONVIE_DRAW_TRACE", "1" }},
    });
    defer g.deinit();

    try g.exec("execute('set nocursorline noruler noshowcmd laststatus=0 guicursor+=a:blinkon0')");
    var before_buf: [max_windows]platform.MainWindow = undefined;
    const before = before_buf[0..platform.windowsForPid(g.app_pid, &before_buf)];
    try g.exec(
        "luaeval('(function() local b = vim.api.nvim_create_buf(false, true) " ++
            "vim.api.nvim_buf_set_lines(b, 0, -1, true, {\"one\", \"two\", \"three\"}) " ++
            "vim.api.nvim_open_win(b, false, {external=true, width=40, height=12}) return 1 end)()')",
    );
    try waitNewWindow(g.app_pid, before);
    gui_io.sleepNs(1500 * std.time.ns_per_ms);

    const t0 = try app_log.nowMs(alloc, log_path);
    gui_io.sleepNs(idle_ms * std.time.ns_per_ms);
    const c = try externalLoadFrames(alloc, t0);
    std.debug.print(
        "[gui] extwin animated idle: frames={d} redrawn with nothing dirty={d}\n",
        .{ c.frames, c.redrawn_idle },
    );
    // Gate: the shader has to be animating the external window, or no frame
    // was drawn to count.
    if (c.frames < 20) return error.ExternalWindowNotAnimating;
    if (c.redrawn_idle != 0) return error.IdleExternalFrameRedrewRows;
}
