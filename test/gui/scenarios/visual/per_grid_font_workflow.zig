// visual/per_grid_font_workflow — a stress pass over per-window fonts in the
// ways a user drives them: ligature fonts on several splits, splits resized
// one at a time and in bursts, overlapping floats in their own fonts moved and
// resized, the app window resized, fonts swapped on a live window, a font
// window closed and reopened, and a tab round trip.
//
// Needs Fira Code, JetBrains Mono and Iosevka installed; skipped otherwise.
//
// Oracles, after every phase once the app is idle:
//   - no nvim_ui_try_resize_grid is sent while idle (no resize ping-pong);
//   - every window still has a positive size;
//   - the frame built from partial redraws matches the same commit drawn
//     whole (ZONVIE_TEST_FULL_REDRAW), and matches the screen after Neovim
//     re-sends everything (`:mode`).
// A phase's failure is recorded and the run continues, so one pass reports
// every phase.

const std = @import("std");
const fixture = @import("fixture.zig");
const visual = @import("../../visual.zig");
const app_log = @import("../../app_log.zig");
const driver = @import("../../driver.zig");
const gui_io = @import("../../gui_io.zig");
const capture = driver.capture;

const log_path = "tmp/gui_per_grid_font_workflow.log";
const lua_path = "test/gui/fixtures/per_grid_font_workflow.lua";
const full_frame_marker = "[trace] event=full_frame_done";
const resize_grid_marker = "rpc send: nvim_ui_try_resize_grid";

/// The per-window fonts the Lua script asks for. Missing any skips the run:
/// a fallback font would draw the windows and measure nothing font-specific.
const required_families = [_][:0]const u8{ "Fira Code", "JetBrains Mono", "Iosevka" };

/// fixture.guifont's family, for a global font change at another size.
const global_family = switch (@import("builtin").os.tag) {
    .windows => "Consolas",
    else => "Menlo",
};

const max_diff_ratio = 0.0005;
const idle_window_ms = 1500;

var failures: usize = 0;

fn fail(phase: []const u8, comptime fmt: []const u8, args: anytype) void {
    std.debug.print("[gui] pgf FAIL {s}: " ++ fmt ++ "\n", .{phase} ++ args);
    failures += 1;
}

fn save(alloc: std.mem.Allocator, phase: []const u8, suffix: []const u8, img: capture.Image) void {
    var buf: [128]u8 = undefined;
    const path = std.fmt.bufPrint(&buf, "tmp/pgf_{s}_{s}" ++ capture.image_ext, .{ phase, suffix }) catch return;
    capture.writeImage(alloc, path, img) catch {};
}

fn checkpoint(alloc: std.mem.Allocator, g: *driver.Gui, phase: []const u8) !void {
    gui_io.sleepNs(800 * std.time.ns_per_ms);
    var settled = try g.captureStable(null, 10000);
    defer settled.deinit(alloc);

    const idle_from = try app_log.nowMs(alloc, log_path);
    gui_io.sleepNs(idle_window_ms * std.time.ns_per_ms);
    const pings = try app_log.countLinesSince(alloc, log_path, resize_grid_marker, idle_from);
    if (pings != 0) fail(phase, "{d} try_resize_grid sent while idle", .{pings});

    const bad = try g.evalInt("luaeval('PGF.check_layout()')");
    if (bad != 0) fail(phase, "{d} windows with a non-positive size", .{bad});

    var partial = try g.captureStable(null, 10000);
    defer partial.deinit(alloc);
    save(alloc, phase, "partial", partial);
    const drift = visual.regionDiffRatio(settled, partial, .{}, 6);
    if (drift > max_diff_ratio) fail(phase, "screen still changing while idle ({d:.4})", .{drift});

    const forced = try app_log.nowMs(alloc, log_path);
    driver.platform.forceFullRedraw(g.app_pid);
    try app_log.waitForSince(alloc, log_path, full_frame_marker, forced, 5000);
    var full = try g.captureStable(null, 10000);
    defer full.deinit(alloc);
    const vs_full = visual.regionDiffRatio(partial, full, .{}, 6);
    if (vs_full > max_diff_ratio) {
        save(alloc, phase, "full", full);
        fail(phase, "partial vs full redraw differ {d:.4}", .{vs_full});
    }

    try g.exec("execute('mode')");
    gui_io.sleepNs(600 * std.time.ns_per_ms);
    var resent = try g.captureStable(null, 10000);
    defer resent.deinit(alloc);
    const vs_resent = visual.regionDiffRatio(partial, resent, .{}, 6);
    if (vs_resent > max_diff_ratio) {
        save(alloc, phase, "resent", resent);
        fail(phase, "partial vs :mode redraw differ {d:.4}", .{vs_resent});
    }
    std.debug.print("[gui] pgf {s}: idle_pings={d} drift={d:.4} vs_full={d:.4} vs_mode={d:.4}\n", .{ phase, pings, drift, vs_full, vs_resent });
}

fn call(g: *driver.Gui, comptime expr: []const u8) !void {
    _ = try g.evalInt("luaeval('" ++ expr ++ "')");
}

fn callN(g: *driver.Gui, comptime fn_name: []const u8, i: usize) !void {
    var buf: [96]u8 = undefined;
    _ = try g.evalInt(try std.fmt.bufPrint(&buf, "luaeval('PGF.{s}({d})')", .{ fn_name, i }));
}

pub fn run(alloc: std.mem.Allocator) !void {
    for (required_families) |family| {
        if (!driver.platform.fontInstalled(family)) {
            std.debug.print("[gui] skipped: font family '{s}' is not installed\n", .{family});
            return error.SkipZigTest;
        }
    }
    failures = 0;
    std.Io.Dir.cwd().createDirPath(gui_io.io(), "tmp") catch {};
    std.Io.Dir.cwd().deleteFile(gui_io.io(), log_path) catch {};
    var g = try fixture.openWithLogConfigAndEnv(alloc, log_path, "test/gui/fixtures/config", &.{
        .{ "ZONVIE_TEST_FULL_REDRAW", "1" },
    });
    defer g.deinit();
    g.activateApp();

    const lua_abs = try std.Io.Dir.cwd().realPathFileAlloc(gui_io.io(), lua_path, alloc);
    defer alloc.free(lua_abs);
    var src_buf: [512]u8 = undefined;
    try g.exec(try std.fmt.bufPrint(&src_buf, "execute('luafile {s}')", .{lua_abs}));
    try call(g, "PGF.setup()");

    try call(g, "PGF.splits()");
    try checkpoint(alloc, g, "1_splits_fonts");

    try call(g, "PGF.resize_burst()");
    try checkpoint(alloc, g, "2_resize_burst");

    for (0..16) |i| {
        try callN(g, "resize_step", i);
        gui_io.sleepNs(40 * std.time.ns_per_ms);
    }
    try checkpoint(alloc, g, "3_resize_steps");

    try call(g, "PGF.floats()");
    try checkpoint(alloc, g, "4_floats");

    for (0..20) |i| {
        try callN(g, "float_step", i);
        gui_io.sleepNs(30 * std.time.ns_per_ms);
    }
    try call(g, "PGF.float_scroll()");
    try checkpoint(alloc, g, "5_float_resize");

    try g.exec("execute('set columns=140 lines=46')");
    gui_io.sleepNs(500 * std.time.ns_per_ms);
    try g.exec("execute('set columns=100 lines=36')");
    try checkpoint(alloc, g, "6_app_resize");

    for (0..8) |i| {
        try callN(g, "font_churn", i);
        gui_io.sleepNs(25 * std.time.ns_per_ms);
    }
    try checkpoint(alloc, g, "7_font_churn");

    try call(g, "PGF.close_reopen()");
    try g.remoteSend("6<C-e>");
    try checkpoint(alloc, g, "8_close_reopen");

    try call(g, "PGF.tab_roundtrip()");
    try checkpoint(alloc, g, "9_tab_roundtrip");

    try g.exec("execute('set guifont=" ++ global_family ++ ":h16')");
    gui_io.sleepNs(500 * std.time.ns_per_ms);
    try g.exec("execute('set guifont=" ++ fixture.guifont ++ "')");
    try checkpoint(alloc, g, "10_global_font");

    if (try app_log.contains(alloc, log_path, "per-grid font: load failed")) fail("log", "a per-window font failed to load", .{});
    if (try app_log.contains(alloc, log_path, "try_resize_grid failed")) fail("log", "try_resize_grid failed", .{});
    if (try app_log.contains(alloc, log_path, "panic")) fail("log", "panic in app log", .{});
    if (failures != 0) return error.PerGridFontWorkflowFailed;
}
