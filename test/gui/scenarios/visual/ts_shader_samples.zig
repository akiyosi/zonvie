// visual/ts_shader_samples — each contrib/shaders/ts_*.glsl sample draws
// from the Tree-sitter layer's markers in the real frontend.
//
// A sample shader declares `ZonvieTs*` groups; the core then runs
// src/core/shader_ts_layer.lua in Neovim and the shader reads the markers
// as bits of each cell's group mask. This launches the app once per sample,
// opens a Lua buffer, and compares two captures that differ only in the
// markers: one with the layer running, one after tearing it down. A sample
// that fails to compile, or never receives its markers, draws the same
// pixels both times.
//
// The first capture of each sample is also written to
// tmp/ts_shader_samples/<name>.png, for looking at.

const std = @import("std");
const driver = @import("../../driver.zig");
const gui_io = @import("../../gui_io.zig");
const fixture = @import("fixture.zig");

const Sample = struct {
    name: []const u8,
    config_dir: []const u8,
    /// Run after the buffer is open, before the first capture.
    setup: []const []const u8 = &.{},
};

const samples = [_]Sample{
    .{ .name = "ts_spotlight", .config_dir = "test/gui/fixtures/config_ts_spotlight" },
    .{ .name = "ts_threads", .config_dir = "test/gui/fixtures/config_ts_threads" },
    .{ .name = "ts_gutter_glyphs", .config_dir = "test/gui/fixtures/config_ts_gutter_glyphs" },
    .{ .name = "ts_strata", .config_dir = "test/gui/fixtures/config_ts_strata" },
    .{
        .name = "ts_faultline",
        .config_dir = "test/gui/fixtures/config_ts_faultline",
        // An unclosed parenthesis: an ERROR node on that line.
        .setup = &.{"setline(13, '  local mixed = (1 + )')"},
    },
};

/// The samples animate on entry and then rest; a capture taken this long
/// after the last cursor move holds the resting picture.
const settle_ms: u64 = 2600;

/// Fraction of pixels that must differ between "markers on" and "markers
/// off". The smallest sample (one broken token, its halo and its tick)
/// changes about 0.0014 of this window; an inert shader changes none.
const min_changed: f64 = 0.0004;

fn changedFraction(a: driver.capture.Image, b: driver.capture.Image) f64 {
    if (a.w != b.w or a.h != b.h) return 1.0;
    var changed: usize = 0;
    var i: usize = 0;
    while (i < a.rgba.len) : (i += 4) {
        const dr = @abs(@as(i16, a.rgba[i]) - @as(i16, b.rgba[i]));
        const dg = @abs(@as(i16, a.rgba[i + 1]) - @as(i16, b.rgba[i + 1]));
        const db = @abs(@as(i16, a.rgba[i + 2]) - @as(i16, b.rgba[i + 2]));
        if (dr + dg + db > 6) changed += 1;
    }
    return @as(f64, @floatFromInt(changed)) / @as(f64, @floatFromInt(a.rgba.len / 4));
}

fn runSample(alloc: std.mem.Allocator, sample: Sample) !void {
    var log_buf: [96]u8 = undefined;
    const log_path = try std.fmt.bufPrint(&log_buf, "tmp/gui_{s}.log", .{sample.name});
    std.Io.Dir.cwd().deleteFile(gui_io.io(), log_path) catch {};

    var g = try fixture.openWithLogAndConfig(alloc, log_path, sample.config_dir);
    defer g.deinit();
    g.activateApp();

    try g.exec("execute('set laststatus=0 noruler noshowcmd nowrap signcolumn=yes')");
    try g.exec("execute('edit test/gui/fixtures/ts_shader_sample.lua')");
    for (sample.setup) |expr| try g.exec(expr);
    // Inside M.blend, on the `amount` argument of the call to clamp().
    try g.exec("execute('normal! 12G25|')");
    gui_io.sleepNs(settle_ms * std.time.ns_per_ms);

    var on = try driver.capture.captureMainWindow(alloc, g.app_pid, null);
    defer on.deinit(alloc);
    std.Io.Dir.cwd().createDirPath(gui_io.io(), "tmp/ts_shader_samples") catch {};
    var png_buf: [96]u8 = undefined;
    const png_path = try std.fmt.bufPrint(&png_buf, "tmp/ts_shader_samples/{s}.png", .{sample.name});
    try driver.capture.writeImage(alloc, png_path, on);

    // Same text, same colours, no markers.
    try g.exec("luaeval('_G.zonvie_shader_ts.teardown()')");
    try g.exec("execute('redraw!')");
    gui_io.sleepNs(settle_ms * std.time.ns_per_ms);
    var off = try driver.capture.captureMainWindow(alloc, g.app_pid, null);
    defer off.deinit(alloc);

    const changed = changedFraction(on, off);
    std.debug.print("[gui] {s}: {d:.4} of the window differs with markers ({d}x{d})\n", .{ sample.name, changed, on.w, on.h });
    if (changed < min_changed) {
        std.debug.print("[gui] {s} drew nothing from its markers\n", .{sample.name});
        return error.SampleShaderInert;
    }
}

pub fn run(alloc: std.mem.Allocator) !void {
    // ZONVIE_TS_SAMPLE narrows the run to one sample while working on it.
    const only = std.process.Environ.getAlloc(std.testing.environ, alloc, "ZONVIE_TS_SAMPLE") catch null;
    defer if (only) |o| alloc.free(o);
    for (samples) |sample| {
        if (only) |o| {
            if (!std.mem.eql(u8, o, sample.name)) continue;
        }
        try runSample(alloc, sample);
    }
}
