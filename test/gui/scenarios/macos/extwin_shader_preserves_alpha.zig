// extwin_shader_preserves_alpha — a normal external editor window must run
// the same custom-shader chain the main window does, not the decorated one.
//
// The chain is compiled twice. The main set keeps the configured
// `preserve_alpha`; the DECORATED set is always compiled with it OFF, because
// an ext-cmdline / popupmenu / message surface has alpha-0 padding and
// empty-input regions where preserving alpha makes the shader vanish
// (GridSurfaceRenderer's customShaderPipelinesDecorated).
//
// ExternalGridView chose the decorated set for every surface it drew,
// including ordinary editor windows given a window of their own. Those have no
// padding and are not decorated, so a user who asked for preserve_alpha got it
// everywhere except there.
//
// Asserted on which chain the surface actually selects, logged as
// [ext_shader]. The alternative — screenshotting and comparing alpha — would
// need the shader's own output to differ visibly between the two compilations
// on this content, which is a property of the probe shader rather than of the
// selection under test.
//
// Runs with --extcmdline so a decorated surface exists in the same session:
// the test is that the two surface kinds disagree, and a run with only one
// kind would pass against a frontend that hard-coded either answer.
//
// macOS-only: the two-variant shader chain lives in the macOS frontend.

const std = @import("std");
const driver = @import("../../driver.zig");
const platform = driver.platform;
const Gui = driver.Gui;
const app_log = @import("../../app_log.zig");
const gui_io = @import("../../gui_io.zig");

const log_path = "tmp/gui_extwin_shader_alpha.log";
const marker = "[ext_shader]";
const max_windows = 16;

/// ZonvieCore.cmdlineGridId: the surface id the ext-cmdline logs under.
const cmdline_grid_id: f64 = -100;

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
            return error.WindowNotFound;
        }
        gui_io.sleepNs(100 * std.time.ns_per_ms);
    }
}

/// Which surface an [ext_shader] line is about, and whether the chain it
/// actually took is the opaque (decorated) one.
const Selection = struct { grid: f64, opaque_chain: f64 };

/// The last [ext_shader] line since `since_ms` that `accept` agrees with.
fn lastSelection(
    alloc: std.mem.Allocator,
    since_ms: f64,
    accept: *const fn (f64) bool,
) !?Selection {
    const blob = try app_log.linesSince(alloc, log_path, marker, since_ms);
    defer alloc.free(blob);
    var found: ?Selection = null;
    var it = std.mem.splitScalar(u8, blob, '\n');
    while (it.next()) |line| {
        const grid = app_log.field(line, "gridId") orelse continue;
        if (!accept(grid)) continue;
        const opaque_chain = app_log.field(line, "opaque") orelse continue;
        found = .{ .grid = grid, .opaque_chain = opaque_chain };
    }
    return found;
}

fn waitSelection(
    alloc: std.mem.Allocator,
    since_ms: f64,
    timeout_ms: u64,
    accept: *const fn (f64) bool,
) !Selection {
    var timer = gui_io.Timer.start();
    while (true) {
        if (try lastSelection(alloc, since_ms, accept)) |s| return s;
        if (timer.read() / std.time.ns_per_ms >= timeout_ms) return error.NoShaderVariantLogged;
        gui_io.sleepNs(100 * std.time.ns_per_ms);
    }
}

/// An external editor window logs under its own grid id, which is positive;
/// the decorated surfaces use fixed negative ids.
fn isEditorSurface(grid: f64) bool {
    return grid > 0;
}

fn isCmdlineSurface(grid: f64) bool {
    return grid == cmdline_grid_id;
}

pub fn run(alloc: std.mem.Allocator) !void {
    std.Io.Dir.cwd().createDirPath(gui_io.io(), "tmp") catch {};
    std.Io.Dir.cwd().deleteFile(gui_io.io(), log_path) catch {};

    var g = try Gui.init(alloc, .{
        .app_args = &.{ "--extcmdline", "--log", log_path },
        .config_dir = "test/gui/fixtures/config_preserve_alpha_shader",
    });
    defer g.deinit();
    g.activateApp();

    var before_buf: [max_windows]platform.MainWindow = undefined;
    const before = before_buf[0..platform.windowsForPid(g.app_pid, &before_buf)];

    // A normal editor window with a window of its own.
    try g.exec(
        \\luaeval('(function() _G.z_ext = vim.api.nvim_open_win(vim.api.nvim_create_buf(false, true), true, {external=true, width=50, height=14}) return 1 end)()')
    );
    const ext_win = try waitNewWindow(g.app_pid, before, 100);
    gui_io.sleepNs(800 * std.time.ns_per_ms);

    const ext_grid = @as(f64, @floatFromInt(
        try g.evalInt("luaeval('vim.api.nvim_win_get_config(_G.z_ext).external and 1 or 0')"),
    ));
    if (ext_grid != 1) return error.WindowNotExternal;

    const editor = try waitSelection(alloc, 0, 10_000, isEditorSurface);
    const ext_variant = editor.opaque_chain;
    std.debug.print(
        "[gui] external editor window (surface {d:.0}) took the opaque chain: {d:.0}\n",
        .{ editor.grid, ext_variant },
    );

    // A decorated surface in the same session, so the comparison is between
    // two live surfaces rather than against a constant.
    const t0 = try app_log.nowMs(alloc, log_path);
    try g.remoteSend(":");
    gui_io.sleepNs(800 * std.time.ns_per_ms);
    const cmdline_variant = (try waitSelection(alloc, t0, 10_000, isCmdlineSurface)).opaque_chain;
    std.debug.print("[gui] ext-cmdline took the opaque chain: {d:.0}\n", .{cmdline_variant});
    try g.remoteSend("<Esc>");

    if (cmdline_variant != 1) {
        std.debug.print(
            "[gui] the ext-cmdline must keep the OPAQUE chain: its padding is alpha 0 and " ++
                "preserve_alpha would make the shader vanish there\n",
            .{},
        );
        return error.DecoratedSurfaceLostOpaqueChain;
    }
    if (ext_variant != 0) {
        std.debug.print(
            "[gui] a normal external editor window took the decorated (opaque) chain, so the " ++
                "configured preserve_alpha does not reach it\n",
            .{},
        );
        return error.ExternalWindowTookDecoratedChain;
    }

    _ = ext_win;
    std.debug.print("[gui] PASS: editor surfaces keep preserve_alpha, decorated surfaces stay opaque\n", .{});
}
