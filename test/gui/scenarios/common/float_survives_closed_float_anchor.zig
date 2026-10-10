// float_survives_closed_float_anchor — a float anchored to another FLOAT
// (relative='win') must stay on screen when that anchor float is closed.
//
// Neovim keeps the child open. Nvim 0.12.2 re-sends win_float_pos for it with
// anchor_grid=1 in the same batch as win_close + grid_destroy of the anchor;
// the core also re-points such a child itself on grid_destroy. Either way the
// child must not drop out of the main surface: if its anchor_grid kept naming
// the destroyed grid, its anchor chain would stop resolving.
//
// Asserted on the render trace's layer count for surface 1: closing the anchor
// removes exactly one layer (the anchor), not two.

const std = @import("std");
const builtin = @import("builtin");
const driver = @import("../../driver.zig");
const Gui = driver.Gui;
const app_log = @import("../../app_log.zig");
const gui_io = @import("../../gui_io.zig");

const log_path = "tmp/gui_float_survives_closed_float_anchor.log";
const trace_side = if (builtin.os.tag == .windows) "side=windows" else "side=macos";

/// The last layer count `side` published for surface 1 since `since_ms`.
fn lastMainLayerCount(alloc: std.mem.Allocator, since_ms: f64) !?f64 {
    const lines = try app_log.linesSince(alloc, log_path, "event=layout_stage surface=1 layers=", since_ms);
    defer alloc.free(lines);
    var found: ?f64 = null;
    var it = std.mem.splitScalar(u8, lines, '\n');
    while (it.next()) |line| {
        if (std.mem.indexOf(u8, line, trace_side) == null) continue;
        found = app_log.field(line, "layers") orelse continue;
    }
    return found;
}

/// Waits until surface 1 publishes `want` layers after `since_ms`, returning the
/// last count seen when the timeout expires instead.
fn waitMainLayerCount(alloc: std.mem.Allocator, since_ms: f64, want: f64, timeout_ms: u64) !?f64 {
    var timer = gui_io.Timer.start();
    var last: ?f64 = null;
    while (true) {
        last = try lastMainLayerCount(alloc, since_ms);
        if (last != null and last.? == want) return last;
        if (timer.read() / std.time.ns_per_ms >= timeout_ms) return last;
        gui_io.sleepNs(100 * std.time.ns_per_ms);
    }
}

pub fn run(alloc: std.mem.Allocator) !void {
    std.Io.Dir.cwd().createDirPath(gui_io.io(), "tmp") catch {};
    std.Io.Dir.cwd().deleteFile(gui_io.io(), log_path) catch {};

    var g = try Gui.init(alloc, .{
        .app_args = &.{ "--log", log_path },
        .config_dir = "test/gui/fixtures/config_render_trace",
    });
    defer g.deinit();

    // Float A on the editor, float B anchored to A.
    try g.exec(
        \\luaeval('(function() local ba = vim.api.nvim_create_buf(false, true) vim.api.nvim_buf_set_lines(ba, 0, -1, false, {"anchor float"}) _G.z_a = vim.api.nvim_open_win(ba, false, {relative="editor", row=2, col=4, width=30, height=8, style="minimal"}) local bb = vim.api.nvim_create_buf(false, true) vim.api.nvim_buf_set_lines(bb, 0, -1, false, {"child float"}) _G.z_b = vim.api.nvim_open_win(bb, false, {relative="win", win=_G.z_a, row=3, col=5, width=16, height=2, style="minimal", zindex=60}) return 1 end)()')
    );
    gui_io.sleepNs(800 * std.time.ns_per_ms);

    if (try g.evalInt("luaeval('(vim.api.nvim_win_get_config(_G.z_b).win == _G.z_a) and 1 or 0')") != 1) {
        return error.ChildNotAnchoredToFloat;
    }
    const layers_before = (try lastMainLayerCount(alloc, 0)) orelse return error.NoLayoutForMainSurface;

    // The close under test.
    const t0 = try app_log.nowMs(alloc, log_path);
    const before_close = try app_log.lineMark(alloc, log_path);
    try g.exec("luaeval('(function() vim.api.nvim_win_close(_G.z_a, true) return 1 end)()')");
    try app_log.waitFramesAfter(alloc, log_path, 1, 2, before_close, 10_000);

    // Gate: Neovim still has the child open. Had it closed the child too, two
    // layers going away would be the protocol, not a GUI defect.
    if (try g.evalInt("luaeval('vim.api.nvim_win_is_valid(_G.z_b) and 1 or 0')") != 1) {
        return error.NeovimClosedChildFloat;
    }

    const want = layers_before - 1;
    const layers_after = (try waitMainLayerCount(alloc, t0, want, 10_000)) orelse return error.NoLayoutAfterClose;
    std.debug.print(
        "[gui] main surface layers {d:.0} -> {d:.0} (want {d:.0})\n",
        .{ layers_before, layers_after, want },
    );
    if (layers_after != want) {
        std.debug.print(
            "[gui] closing the anchor float removed the child float from the main surface too\n",
            .{},
        );
        return error.ChildFloatDroppedWithAnchor;
    }
}
