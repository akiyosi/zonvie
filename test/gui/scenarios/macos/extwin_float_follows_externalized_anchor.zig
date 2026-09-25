// extwin_float_follows_externalized_anchor — a float anchored to a window
// (relative='win') must move to that window's external surface when the window
// is externalized, instead of being left behind on the main window.
//
// The core resolves a grid's surface by walking `anchor_grid`
// (Grid.surfaceForGrid), so a float whose anchor enters `external_grids` should
// come out as a LAYER OF THAT EXTERNAL SURFACE: its layout carries two layers,
// the surface root and the float. If the float were left on the main window the
// external surface would publish one layer and the float would keep appearing
// in surface 1's list — which is what "the float falls onto the main window"
// looks like from the layout stream.
//
// Asserted on the render trace rather than on pixels because the trace is the
// core's own statement of which surface owns which grid; a screenshot cannot
// distinguish "drawn on the main window" from "drawn on an external window that
// happens to overlap it".
//
// The scenario also records what Neovim itself says about the float after the
// move (`nvim_win_get_config().relative` / `.win`). If Neovim re-anchors the
// float to the editor, the float belongs on the main window by protocol and no
// GUI can do otherwise — that outcome is reported distinctly from a GUI-side
// failure to follow the anchor.
//
// macOS-only: external windows and their surface plumbing are frontend code.

const std = @import("std");
const driver = @import("../../driver.zig");
const Gui = driver.Gui;
const app_log = @import("../../app_log.zig");
const gui_io = @import("../../gui_io.zig");

const log_path = "tmp/gui_extwin_float_follows_anchor.log";

/// The last layer count `side` published for `surface` since `since_ms`.
fn lastLayerCount(
    alloc: std.mem.Allocator,
    surface: i64,
    side: []const u8,
    since_ms: f64,
) !?f64 {
    var marker_buf: [64]u8 = undefined;
    const marker = try std.fmt.bufPrint(
        &marker_buf,
        "event=layout_stage surface={d} layers=",
        .{surface},
    );
    const lines = try app_log.linesSince(alloc, log_path, marker, since_ms);
    defer alloc.free(lines);
    var found: ?f64 = null;
    var it = std.mem.splitScalar(u8, lines, '\n');
    while (it.next()) |line| {
        if (std.mem.indexOf(u8, line, side) == null) continue;
        found = app_log.field(line, "layers") orelse continue;
    }
    return found;
}

fn waitLayerCount(
    alloc: std.mem.Allocator,
    surface: i64,
    side: []const u8,
    since_ms: f64,
    timeout_ms: u64,
) !f64 {
    var timer = gui_io.Timer.start();
    while (true) {
        if (try lastLayerCount(alloc, surface, side, since_ms)) |n| return n;
        if (timer.read() / std.time.ns_per_ms >= timeout_ms) return error.NoLayoutForSurface;
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

    const base_windows = g.windowCount();

    // Two windows, so externalizing one leaves a main window behind, and a
    // float anchored to the one that leaves.
    try g.exec(
        \\luaeval('(function() vim.cmd("vsplit") _G.z_host = vim.api.nvim_get_current_win() local b = vim.api.nvim_create_buf(false, true) local l = {} for i = 1, 400 do l[i] = string.format("%3d host line", i) end vim.api.nvim_buf_set_lines(b, 0, -1, false, l) vim.api.nvim_win_set_buf(_G.z_host, b) local fb = vim.api.nvim_create_buf(false, true) vim.api.nvim_buf_set_lines(fb, 0, -1, false, {"float A", "float B", "float C"}) _G.z_float = vim.api.nvim_open_win(fb, false, {relative="win", win=_G.z_host, row=2, col=4, width=20, height=6, style="minimal"}) return 1 end)()')
    );
    gui_io.sleepNs(800 * std.time.ns_per_ms);

    // Gate: the float really is window-anchored and composited into the main
    // window. An editor-anchored float belongs to grid 1 by protocol and would
    // pass or fail this scenario for a reason that has nothing to do with it.
    if (try g.evalInt("luaeval('(vim.api.nvim_win_get_config(_G.z_float).relative == \"win\") and 1 or 0')") != 1) {
        return error.FloatNotWindowAnchored;
    }
    if (try g.evalInt("luaeval('(vim.api.nvim_win_get_config(_G.z_float).win == _G.z_host) and 1 or 0')") != 1) {
        return error.FloatNotAnchoredToHost;
    }
    if (g.windowCount() != base_windows) {
        std.debug.print("[gui] the float was given a window of its own before the move\n", .{});
        return error.FloatGotItsOwnWindow;
    }
    const main_layers_before = try waitLayerCount(alloc, 1, "side=macos", 0, 10_000);

    // The move under test.
    const t0 = try app_log.nowMs(alloc, log_path);
    try g.exec(
        \\luaeval('(function() vim.api.nvim_win_set_config(_G.z_host, {external=true, width=60, height=20}) return 1 end)()')
    );
    try g.waitWindowCount(base_windows + 1, 10_000);
    gui_io.sleepNs(1000 * std.time.ns_per_ms);

    // What Neovim says about the float now. If it re-anchored the float to the
    // editor, the float is grid 1's by protocol and the GUI has no say.
    const still_win = try g.evalInt("luaeval('(vim.api.nvim_win_get_config(_G.z_float).relative == \"win\") and 1 or 0')");
    const still_host = try g.evalInt("luaeval('(vim.api.nvim_win_get_config(_G.z_float).win == _G.z_host) and 1 or 0')");

    const ext_grid: i64 = blk: {
        const line = (try app_log.lastLineSince(alloc, log_path, "[external_window] open gridId=", t0)) orelse
            return error.NoExternalWindowOpened;
        defer alloc.free(line);
        const v = app_log.field(line, "gridId") orelse return error.ExternalGridIdUnparsable;
        break :blk @intFromFloat(v);
    };

    const ext_layers = try waitLayerCount(alloc, ext_grid, "side=macos", t0, 10_000);
    const main_layers_after = try waitLayerCount(alloc, 1, "side=macos", t0, 10_000);

    std.debug.print(
        "[gui] ext grid {d}: layers={d:.0}; main surface layers {d:.0} -> {d:.0}; " ++
            "nvim still relative=win:{d} anchored to host:{d}\n",
        .{ ext_grid, ext_layers, main_layers_before, main_layers_after, still_win, still_host },
    );

    if (still_win != 1 or still_host != 1) {
        std.debug.print(
            "[gui] Neovim re-anchored the float away from the externalized window, " ++
                "so it belongs to the editor grid and the GUI cannot move it\n",
            .{},
        );
        return error.NeovimReanchoredFloatToEditor;
    }

    // The external surface publishes its root plus every grid anchored to it.
    // One layer means the float stayed behind on the main window.
    if (ext_layers < 2) {
        std.debug.print(
            "[gui] the external surface published only its root: the float anchored to the " ++
                "externalized window was left on the main window\n",
            .{},
        );
        return error.FloatDidNotFollowAnchor;
    }
    // ...and it must have LEFT the main surface: the host grid and the float
    // both go, so the main surface's list has to shrink.
    if (main_layers_after >= main_layers_before) {
        std.debug.print(
            "[gui] the main surface still lists as many layers as before the move\n",
            .{},
        );
        return error.MainSurfaceStillOwnsFloat;
    }
}
