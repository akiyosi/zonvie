// visual/ts_shader_samples — each contrib/shaders/ts_*.glsl sample draws
// from the Tree-sitter layer's markers in the real frontend.
//
// A sample shader declares `ZonvieTs*` groups; the core then runs
// src/core/shader_ts_layer.lua in Neovim and the shader reads the markers
// as bits of each cell's group mask. This launches the app once per sample
// and shows it two buffers (Lua, C) under two backgrounds (dark, light).
// Each view is captured twice, with the layer running and after tearing it
// down: same text, same colours, only the markers differ. A sample that
// fails to compile, or never receives its markers, draws the same pixels
// both times.
//
// The captures with the layer running are also written to
// tmp/ts_shader_samples/<name>_<buffer>_<background>.png, for looking at.

const std = @import("std");
const driver = @import("../../driver.zig");
const gui_io = @import("../../gui_io.zig");
const fixture = @import("fixture.zig");
const Image = driver.capture.Image;

const Sample = struct {
    name: []const u8,
    config_dir: []const u8,
    /// Fraction of the window's pixels the markers must change. Set under
    /// what the sample changes on the smaller of the two buffers; a shader
    /// that draws nothing changes none.
    min_changed: f64,
    /// Whether the views get a syntax error to show.
    breaks_syntax: bool = false,
};

const samples = [_]Sample{
    .{ .name = "ts_spotlight", .config_dir = "test/gui/fixtures/config_ts_spotlight", .min_changed = 0.008 },
    .{ .name = "ts_threads", .config_dir = "test/gui/fixtures/config_ts_threads", .min_changed = 0.002 },
    .{ .name = "ts_gutter_glyphs", .config_dir = "test/gui/fixtures/config_ts_gutter_glyphs", .min_changed = 0.008 },
    .{ .name = "ts_strata", .config_dir = "test/gui/fixtures/config_ts_strata", .min_changed = 0.15 },
    // One broken token: a zigzag, a halo and a tick, about a thousandth of
    // the window. What it must add is red (see runSample).
    .{ .name = "ts_faultline", .config_dir = "test/gui/fixtures/config_ts_faultline", .min_changed = 0.0006, .breaks_syntax = true },
};

const Buffer = struct {
    tag: []const u8,
    open: []const u8,
    /// Puts the cursor inside a function, on an argument of a call.
    cursor: []const u8,
    /// Leaves a dangling operator inside parentheses: an ERROR node.
    break_syntax: []const u8,
};

const buffers = [_]Buffer{
    .{
        .tag = "lua",
        .open = "execute('edit! test/gui/fixtures/ts_shader_sample.lua')",
        .cursor = "execute('normal! 12G25|')",
        .break_syntax = "setline(13, '  local mixed = (1 + )')",
    },
    .{
        .tag = "c",
        .open = "execute('edit! test/gui/fixtures/ts_shader_sample.c')",
        .cursor = "execute('normal! 26G30|')",
        .break_syntax = "setline(20, '    int total = (1 + );')",
    },
};

const backgrounds = [_][]const u8{ "dark", "light" };
const view_count = buffers.len * backgrounds.len;

/// The samples animate when the cursor enters a function and then rest; a
/// capture taken this long after the cursor moved holds the resting picture.
const settle_ms: u64 = 2600;
/// Without markers nothing animates.
const settle_plain_ms: u64 = 700;

/// Pixels the broken token must turn red in ts_faultline: its zigzag and
/// its tick alone are a few hundred.
const min_red_px: usize = 150;

fn changedFraction(a: Image, b: Image) f64 {
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

fn redPixels(img: Image) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (i < img.rgba.len) : (i += 4) {
        const r: u16 = img.rgba[i];
        const g: u16 = img.rgba[i + 1];
        const b: u16 = img.rgba[i + 2];
        if (r > g + 50 and r > b + 50) n += 1;
    }
    return n;
}

fn show(g: *driver.Gui, sample: Sample, buffer: Buffer, background: []const u8) !void {
    var expr_buf: [64]u8 = undefined;
    try g.exec(buffer.open);
    try g.exec(try std.fmt.bufPrint(&expr_buf, "execute('set background={s}')", .{background}));
    if (sample.breaks_syntax) try g.exec(buffer.break_syntax);
    // From the first line, so the cursor arrives in its function from outside.
    try g.exec("execute('normal! gg')");
    try g.exec(buffer.cursor);
}

fn runSample(alloc: std.mem.Allocator, sample: Sample) !void {
    var log_buf: [96]u8 = undefined;
    const log_path = try std.fmt.bufPrint(&log_buf, "tmp/gui_{s}.log", .{sample.name});
    std.Io.Dir.cwd().deleteFile(gui_io.io(), log_path) catch {};
    std.Io.Dir.cwd().createDirPath(gui_io.io(), "tmp/ts_shader_samples") catch {};

    var g = try fixture.openWithLogAndConfig(alloc, log_path, sample.config_dir);
    defer g.deinit();
    g.activateApp();
    try g.exec("execute('set laststatus=0 noruler noshowcmd nowrap signcolumn=yes')");

    var with_markers: [view_count]Image = undefined;
    var taken: usize = 0;
    defer for (with_markers[0..taken]) |*img| img.deinit(alloc);

    for (buffers) |buffer| {
        for (backgrounds) |background| {
            try show(g, sample, buffer, background);
            gui_io.sleepNs(settle_ms * std.time.ns_per_ms);
            with_markers[taken] = try driver.capture.captureMainWindow(alloc, g.app_pid, null);
            taken += 1;
            var png_buf: [128]u8 = undefined;
            const png_path = try std.fmt.bufPrint(
                &png_buf,
                "tmp/ts_shader_samples/{s}_{s}_{s}.png",
                .{ sample.name, buffer.tag, background },
            );
            try driver.capture.writeImage(alloc, png_path, with_markers[taken - 1]);
        }
    }

    try g.exec("luaeval('_G.zonvie_shader_ts.teardown()')");

    var view: usize = 0;
    for (buffers) |buffer| {
        for (backgrounds) |background| {
            try show(g, sample, buffer, background);
            try g.exec("execute('redraw!')");
            gui_io.sleepNs(settle_plain_ms * std.time.ns_per_ms);
            var plain = try driver.capture.captureMainWindow(alloc, g.app_pid, null);
            defer plain.deinit(alloc);
            const marked = with_markers[view];
            view += 1;

            const changed = changedFraction(marked, plain);
            std.debug.print(
                "[gui] {s} {s} {s}: {d:.4} of the window differs with markers\n",
                .{ sample.name, buffer.tag, background, changed },
            );
            if (changed < sample.min_changed) {
                std.debug.print("[gui] {s} drew too little from its markers (want {d:.4})\n", .{ sample.name, sample.min_changed });
                return error.SampleShaderInert;
            }
            if (sample.breaks_syntax) {
                const red_with = redPixels(marked);
                const red_plain = redPixels(plain);
                std.debug.print("[gui] {s} {s} {s}: red pixels {d} with markers, {d} without\n", .{ sample.name, buffer.tag, background, red_with, red_plain });
                if (red_with < red_plain + min_red_px) return error.SyntaxErrorNotShown;
            }
        }
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
