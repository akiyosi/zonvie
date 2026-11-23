// visual/ts_shader_windows — the contrib/shaders/ts_*.glsl samples across
// several windows: a vertical split of two buffers in the main window, and
// external windows (surfaces of their own) next to it.
//
// What a sample draws must come from the markers of the cells it shades,
// not from where the cursor happens to be: the cursor's rect is one value
// handed to every surface, and in a window that does not hold the cursor it
// lands on unrelated cells. So:
//   - each window that shows marked text draws, whichever window holds the
//     cursor (every capture is compared with the same view after the layer
//     is torn down);
//   - a buffer left behind in another window keeps no cursor markers: with
//     the cursor outside every function, ts_spotlight draws nothing at all.
//
// --extwindows itself is not exercised: it needs a Neovim that accepts the
// ext_windows UI option. Windows opened with nvim_open_win(external=true)
// take the same external-surface path.
//
// The captures with the layer running are written to
// tmp/ts_shader_windows/<name>_<view>.png, for looking at.

const std = @import("std");
const driver = @import("../../driver.zig");
const gui_io = @import("../../gui_io.zig");
const fixture = @import("fixture.zig");
const Gui = driver.Gui;
const Image = driver.capture.Image;

const Sample = struct {
    name: []const u8,
    /// Whether a window showing ANOTHER buffer than the cursor's draws too.
    /// ts_threads reads cursor markers only, and those stay with the
    /// current window's buffer.
    other_buffer_draws: bool = true,
    breaks_syntax: bool = false,
};

const samples = [_]Sample{
    .{ .name = "ts_spotlight" },
    .{ .name = "ts_threads", .other_buffer_draws = false },
    .{ .name = "ts_gutter_glyphs" },
    .{ .name = "ts_strata" },
    .{ .name = "ts_faultline", .breaks_syntax = true },
};

const lua_path = "test/gui/fixtures/ts_shader_sample.lua";
const c_path = "test/gui/fixtures/ts_shader_sample.c";
const break_lua = "setline(13, '  local mixed = (1 + )')";
const break_c = "setline(20, '    int total = (1 + );')";
const out_dir = "tmp/ts_shader_windows";

/// Entry animations have run out this long after the cursor moved, and the
/// app's own scrollbar, which shows on a cursor move, has faded. The views
/// without markers wait as long: one of them must match its marked twin
/// pixel for pixel.
const settle_ms: u64 = 2600;
const settle_plain_ms: u64 = settle_ms;

/// A region counts as drawn on when this fraction of its pixels differs
/// from the same view without markers. The smallest case (one broken token
/// in half a window) is about 0.001; an inert shader changes none.
const min_drawn: f64 = 0.0004;
/// And as untouched below this (capture noise is zero on an opaque window).
const max_untouched: f64 = 0.0001;

/// Fraction of differing pixels in the columns [x0_frac, x1_frac) of two
/// captures of one view.
fn changed(a: Image, b: Image, x0_frac: f64, x1_frac: f64) f64 {
    if (a.w != b.w or a.h != b.h) return 1.0;
    const x0: usize = @intFromFloat(@as(f64, @floatFromInt(a.w)) * x0_frac);
    const x1: usize = @intFromFloat(@as(f64, @floatFromInt(a.w)) * x1_frac);
    var n: usize = 0;
    var y: usize = 0;
    while (y < a.h) : (y += 1) {
        var x = x0;
        while (x < x1) : (x += 1) {
            const i = (y * a.w + x) * 4;
            const dr = @abs(@as(i16, a.rgba[i]) - @as(i16, b.rgba[i]));
            const dg = @abs(@as(i16, a.rgba[i + 1]) - @as(i16, b.rgba[i + 1]));
            const db = @abs(@as(i16, a.rgba[i + 2]) - @as(i16, b.rgba[i + 2]));
            if (dr + dg + db > 6) n += 1;
        }
    }
    const total = (x1 - x0) * a.h;
    if (total == 0) return 0;
    return @as(f64, @floatFromInt(n)) / @as(f64, @floatFromInt(total));
}

/// Print the bounding box of the pixels two captures of one view differ in.
fn printDiffBox(a: Image, b: Image) void {
    if (a.w != b.w or a.h != b.h) return;
    var x0: usize = a.w;
    var y0: usize = a.h;
    var x1: usize = 0;
    var y1: usize = 0;
    var y: usize = 0;
    while (y < a.h) : (y += 1) {
        var x: usize = 0;
        while (x < a.w) : (x += 1) {
            const i = (y * a.w + x) * 4;
            const dr = @abs(@as(i16, a.rgba[i]) - @as(i16, b.rgba[i]));
            const dg = @abs(@as(i16, a.rgba[i + 1]) - @as(i16, b.rgba[i + 1]));
            const db = @abs(@as(i16, a.rgba[i + 2]) - @as(i16, b.rgba[i + 2]));
            if (dr + dg + db > 6) {
                x0 = @min(x0, x);
                y0 = @min(y0, y);
                x1 = @max(x1, x);
                y1 = @max(y1, y);
            }
        }
    }
    std.debug.print("[gui] differing pixels lie in x {d}..{d}, y {d}..{d} of {d}x{d}\n", .{ x0, x1, y0, y1, a.w, a.h });
}

fn expectDrawn(name: []const u8, view: []const u8, frac: f64, want_drawn: bool) !void {
    std.debug.print("[gui] {s} {s}: {d:.4} differs with markers\n", .{ name, view, frac });
    if (want_drawn and frac < min_drawn) {
        std.debug.print("[gui] {s} drew nothing in {s}\n", .{ name, view });
        return error.WindowNotDrawn;
    }
    if (!want_drawn and frac > max_untouched) {
        std.debug.print("[gui] {s} drew in {s}, where it has no markers\n", .{ name, view });
        return error.WindowDrawnWithoutMarkers;
    }
}

fn open(alloc: std.mem.Allocator, name: []const u8) !*Gui {
    try fixture.requireScreenAccess();
    var cfg_buf: [96]u8 = undefined;
    const config_dir = try std.fmt.bufPrint(&cfg_buf, "test/gui/fixtures/config_{s}", .{name});
    var g = try Gui.init(alloc, .{ .config_dir = config_dir });
    errdefer g.deinit();
    g.activateApp();
    try g.exec("execute('set guicursor+=a:blinkon0')");
    try g.exec("execute('set guifont=" ++ fixture.guifont ++ "')");
    try g.exec("execute('set laststatus=2 noruler noshowcmd nowrap signcolumn=yes')");
    gui_io.sleepNs(1200 * std.time.ns_per_ms);
    return g;
}

fn save(alloc: std.mem.Allocator, img: Image, name: []const u8, view: []const u8) !void {
    var buf: [160]u8 = undefined;
    try driver.capture.writeImage(alloc, try std.fmt.bufPrint(&buf, out_dir ++ "/{s}_{s}.png", .{ name, view }), img);
}

/// The main window split in two: C on the left, Lua on the right.
fn splits(alloc: std.mem.Allocator, sample: Sample) !void {
    var g = try open(alloc, sample.name);
    defer g.deinit();
    try g.exec("execute('edit " ++ lua_path ++ "')");
    if (sample.breaks_syntax) try g.exec(break_lua);
    try g.exec("execute('vsplit " ++ c_path ++ "')");
    if (sample.breaks_syntax) try g.exec(break_c);
    // The C buffer is current first, its cursor inside `sum`...
    try g.exec("execute('normal! 26G30|')");
    // ...then the cursor leaves for the Lua window, on a line outside
    // every function.
    try g.exec("execute('wincmd l')");
    try g.exec("execute('normal! gg0')");
    gui_io.sleepNs(settle_ms * std.time.ns_per_ms);
    var outside = try driver.capture.captureMainWindow(alloc, g.app_pid, null);
    defer outside.deinit(alloc);
    try save(alloc, outside, sample.name, "split_outside");

    // Into M.blend, in the Lua window.
    try g.exec("execute('normal! 12G25|')");
    gui_io.sleepNs(settle_ms * std.time.ns_per_ms);
    var inside = try driver.capture.captureMainWindow(alloc, g.app_pid, null);
    defer inside.deinit(alloc);
    try save(alloc, inside, sample.name, "split_inside");

    try g.exec("luaeval('_G.zonvie_shader_ts.teardown()')");
    try g.exec("execute('redraw!')");
    gui_io.sleepNs(settle_plain_ms * std.time.ns_per_ms);
    var inside_plain = try driver.capture.captureMainWindow(alloc, g.app_pid, null);
    defer inside_plain.deinit(alloc);
    try g.exec("execute('normal! gg0')");
    try g.exec("execute('redraw!')");
    gui_io.sleepNs(settle_plain_ms * std.time.ns_per_ms);
    var outside_plain = try driver.capture.captureMainWindow(alloc, g.app_pid, null);
    defer outside_plain.deinit(alloc);

    // The cursor's window draws; the other buffer's window draws what its
    // own markers call for.
    try expectDrawn(sample.name, "split: cursor's window (Lua)", changed(inside, inside_plain, 0.52, 1.0), true);
    try expectDrawn(sample.name, "split: other window (C)", changed(inside, inside_plain, 0.0, 0.48), sample.other_buffer_draws);
    if (std.mem.eql(u8, sample.name, "ts_spotlight")) {
        // No function holds the cursor, and the C buffer's old cursor
        // markers went when the cursor left it: nothing is framed, nothing
        // steps back.
        expectDrawn(sample.name, "split: cursor outside every function", changed(outside, outside_plain, 0.0, 1.0), false) catch |e| {
            printDiffBox(outside, outside_plain);
            save(alloc, outside_plain, sample.name, "split_outside_plain") catch {};
            return e;
        };
    }
    // A window's own row decides what is drawn on it, never the row beside
    // it in the other window. The split puts the C window's rows level with
    // the rows of M.blend, which holds the cursor.
    const w: f64 = @floatFromInt(inside.w);
    if (std.mem.eql(u8, sample.name, "ts_gutter_glyphs")) {
        // Accent icons belong to the function holding the cursor: the Lua
        // window's gutter has them, the C window's has none.
        const sign_px = 32.0 / w;
        const c_accent = count(inside, 0.0, sign_px, isBlue);
        const lua_accent = count(inside, 0.51, 0.51 + sign_px, isBlue);
        std.debug.print("[gui] ts_gutter_glyphs split: accent pixels in the gutters: C {d}, Lua {d}\n", .{ c_accent, lua_accent });
        if (lua_accent < 100) return error.CursorFunctionIconsNotAccented;
        if (c_accent > 0) return error.OtherWindowIconsAccented;
    }
    if (std.mem.eql(u8, sample.name, "ts_faultline")) {
        // Each window has one broken row, and its tick sits at that
        // window's own right edge: one tick's worth of red at each.
        const edge_px = 24.0 / w;
        const c_ticks = count(inside, 0.5 - edge_px, 0.5, isRed);
        const lua_ticks = count(inside, 1.0 - edge_px, 1.0, isRed);
        std.debug.print("[gui] ts_faultline split: red pixels at the right edges: C {d}, Lua {d}\n", .{ c_ticks, lua_ticks });
        if (c_ticks < 60) return error.TickMissingAtItsWindowEdge;
        if (lua_ticks < 60 or lua_ticks > c_ticks + c_ticks / 2) return error.TickAtAnotherWindowsEdge;
    }
}

fn isBlue(r: u16, g: u16, b: u16) bool {
    _ = g;
    return b > r + 60;
}

fn isRed(r: u16, g: u16, b: u16) bool {
    return r > g + 50 and r > b + 50;
}

/// Pixels in the columns [x0_frac, x1_frac) that `pred` holds for.
fn count(img: Image, x0_frac: f64, x1_frac: f64, comptime pred: fn (u16, u16, u16) bool) usize {
    const x0: usize = @intFromFloat(@as(f64, @floatFromInt(img.w)) * x0_frac);
    const x1: usize = @intFromFloat(@as(f64, @floatFromInt(img.w)) * x1_frac);
    var n: usize = 0;
    var y: usize = 0;
    while (y < img.h) : (y += 1) {
        var x = x0;
        while (x < x1) : (x += 1) {
            const i = (y * img.w + x) * 4;
            if (pred(img.rgba[i], img.rgba[i + 1], img.rgba[i + 2])) n += 1;
        }
    }
    return n;
}

/// The Lua buffer in the main window and in an external window, the C
/// buffer in a second external window; the cursor in the Lua external one.
fn externals(alloc: std.mem.Allocator, sample: Sample) !void {
    var g = try open(alloc, sample.name);
    defer g.deinit();
    try g.exec("execute('edit " ++ lua_path ++ "')");
    if (sample.breaks_syntax) try g.exec(break_lua);

    var before = driver.snapshotWindows(g.app_pid);
    try g.exec(
        "luaeval('(function() local b = vim.fn.bufadd(\"" ++ c_path ++ "\") vim.fn.bufload(b) " ++
            "local w = vim.api.nvim_open_win(b, true, {external=true, width=70, height=26}) " ++
            "vim.wo[w].signcolumn = \"yes\" return 1 end)()')",
    );
    const ext_c = try driver.waitNewWindow(g.app_pid, before.slice(), 150);
    if (sample.breaks_syntax) try g.exec(break_c);
    try g.exec("execute('normal! 26G30|')");
    try g.exec("execute('wincmd p')");

    before = driver.snapshotWindows(g.app_pid);
    try g.exec(
        "luaeval('(function() local w = vim.api.nvim_open_win(0, true, {external=true, width=70, height=26}) " ++
            "vim.wo[w].signcolumn = \"yes\" return 1 end)()')",
    );
    const ext_lua = try driver.waitNewWindow(g.app_pid, before.slice(), 150);
    try g.exec("execute('normal! gg0')");
    try g.exec("execute('normal! 12G25|')");
    gui_io.sleepNs(settle_ms * std.time.ns_per_ms);

    var lua_img = try driver.capture.captureWindow(alloc, ext_lua.number);
    defer lua_img.deinit(alloc);
    try save(alloc, lua_img, sample.name, "external_lua");
    var c_img = try driver.capture.captureWindow(alloc, ext_c.number);
    defer c_img.deinit(alloc);
    try save(alloc, c_img, sample.name, "external_c");
    var main_img = try driver.capture.captureMainWindow(alloc, g.app_pid, null);
    defer main_img.deinit(alloc);
    try save(alloc, main_img, sample.name, "external_main");

    try g.exec("luaeval('_G.zonvie_shader_ts.teardown()')");
    try g.exec("execute('redraw!')");
    gui_io.sleepNs(settle_plain_ms * std.time.ns_per_ms);
    var lua_plain = try driver.capture.captureWindow(alloc, ext_lua.number);
    defer lua_plain.deinit(alloc);
    var c_plain = try driver.capture.captureWindow(alloc, ext_c.number);
    defer c_plain.deinit(alloc);
    var main_plain = try driver.capture.captureMainWindow(alloc, g.app_pid, null);
    defer main_plain.deinit(alloc);

    try expectDrawn(sample.name, "external: cursor's window (Lua)", changed(lua_img, lua_plain, 0.0, 1.0), true);
    // The main window shows the same buffer and holds no cursor: it draws
    // from the same markers.
    try expectDrawn(sample.name, "external: main window (same buffer)", changed(main_img, main_plain, 0.0, 1.0), true);
    try expectDrawn(sample.name, "external: other window (C)", changed(c_img, c_plain, 0.0, 1.0), sample.other_buffer_draws);
}

pub fn run(alloc: std.mem.Allocator) !void {
    std.Io.Dir.cwd().createDirPath(gui_io.io(), out_dir) catch {};
    // ZONVIE_TS_SAMPLE narrows the run to one sample while working on it.
    const only = std.process.Environ.getAlloc(std.testing.environ, alloc, "ZONVIE_TS_SAMPLE") catch null;
    defer if (only) |o| alloc.free(o);
    for (samples) |sample| {
        if (only) |o| {
            if (!std.mem.eql(u8, o, sample.name)) continue;
        }
        try splits(alloc, sample);
        try externals(alloc, sample);
    }
}
