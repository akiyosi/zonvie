// visual/extwin_hosted_layer_glow — the bloom pass an EXTERNAL window runs
// over a float it hosts must extract that layer with the extract pipeline.
//
// `drawHostedLayers` is called twice on a glowing frame: once for the ordinary
// surface pass, and once more into the half-size bloom extract target. Only the
// second may use `glowExtractPipeline`, which emits light for a cell's glyph and
// nothing for its background. Drawing that second pass with the ordinary
// pipeline instead extracts the float's background quads too, so the whole
// rectangle blooms rather than the glyphs in it.
//
// Nothing else in test/gui touched glow — a grep across every scenario returned
// zero before this one — so the entire bloom path, on both surfaces, ran
// unobserved.
//
// Two bands, because either alone proves nothing:
//
//   - the GLYPH band (the float's four rows of text) must change when glow is
//     switched on. Without it this would pass on an app that ignored the
//     configuration entirely.
//   - the BLANK band (four of the eight empty rows below, with four more
//     between them as a buffer) must NOT. Empty cells have no glyph, so under
//     the extract pipeline they emit nothing and only a few pixels of Kawase
//     bleed can reach them — but their BACKGROUND is what the ordinary pipeline
//     would hand to the bloom.
//
// Measured, and mutated to prove it is not vacuous:
//
//   correct                              glyph 0.4529   blank 0.0055
//   extract pass uses `pipeline`         glyph 0.5573   blank 0.7648   FAIL
//   extract pass gets no pipeline (nil)  glyph 0.1320   blank 0.7307   FAIL
//
// The blank band moves by two orders of magnitude, which is why the thresholds
// only have to separate populations rather than measure anything.
//
// `groups = "all"` rather than a named group, and that is a finding worth
// keeping: the core resolves a glow group through `hl.groups`, which is filled
// from Neovim's `hl_group_set` — sent only for the UI groups Neovim announces.
// A user-defined group name never arrives, so `resolveGlowGroups` leaves
// `glow_hl_ids` empty while still logging "glow config: enabled", and the
// screen does not change at all. This scenario measured exactly that (0.0000 in
// both bands) before switching to "all". Whether a named group is reachable
// from a GUI test at all is unresolved; "all" exercises the same pipeline
// choice, which is what is under test here.
//
// Relational — the same screen with glow off and glow on — so it needs no
// golden and is immune to per-host font and DPI drift.
//
// macOS-only: it enumerates the app's OS windows to find the external one and
// captures that window rather than the main one.

const std = @import("std");
const driver = @import("../../driver.zig");
const platform = driver.platform;
const capture = driver.capture;
const fixture = @import("fixture.zig");
const visual = @import("../../visual.zig");
const gui_io = @import("../../gui_io.zig");
const app_log = @import("../../app_log.zig");

const log_path = "tmp/gui_extwin_hosted_layer_glow.log";

/// The core's line for an accepted `vim.g.zonvie_glow`. The variable is read
/// over RPC with a startup retry, so it is not in force when `exec` returns.
const glow_ready_marker = "glow config: enabled";

const max_windows = 16;

/// External window and the float it hosts, in cells.
const ext_rows: u32 = 20;
const ext_cols: u32 = 60;
const float_rows: u32 = 12;
const float_row0: u32 = 3;

/// Rows of the float, 0-based within it: four of text, then eight blank. The
/// control band is the last four, so the four between them absorb the bleed.
const glow_rows: u32 = 4;
const gap_rows: u32 = 4;

/// Switching glow on re-clears the surface, so a few pixels move everywhere.
/// The two bands are three orders of magnitude apart when this works, so the
/// thresholds only have to separate populations, not measure anything.
const glyph_band_min = 0.02;
const blank_band_max = 0.01;

fn waitNewWindow(pid: i32, before: []const platform.MainWindow, tries: u32) !platform.MainWindow {
    var buf: [max_windows]platform.MainWindow = undefined;
    var attempt: u32 = 0;
    while (attempt < tries) : (attempt += 1) {
        const now = buf[0..platform.windowsForPid(pid, &buf)];
        for (now) |w| {
            var seen = false;
            for (before) |b| {
                if (b.number == w.number) seen = true;
            }
            if (!seen) return w;
        }
        gui_io.sleepNs(100 * std.time.ns_per_ms);
    }
    platform.dumpWindowsForPid(pid);
    return error.ExternalWindowNotFound;
}

/// captureStable for a window that is not the app's main one: retry until two
/// consecutive captures are pixel-identical, so a frame caught mid-present is
/// never what a comparison sees.
fn captureWindowStable(alloc: std.mem.Allocator, window_number: u32, timeout_ms: u64) !capture.Image {
    var timer = gui_io.Timer.start();
    var prev: ?capture.Image = null;
    defer if (prev) |*p| p.deinit(alloc);
    while (true) {
        gui_io.sleepNs(150 * std.time.ns_per_ms);
        const cur = capture.captureWindow(alloc, window_number) catch |e| {
            if (timer.read() / std.time.ns_per_ms >= timeout_ms) return e;
            continue;
        };
        if (prev) |*p| {
            if (p.w == cur.w and p.h == cur.h and std.mem.eql(u8, p.rgba, cur.rgba)) {
                p.deinit(alloc);
                prev = null;
                return cur;
            }
            p.deinit(alloc);
            prev = null;
        }
        prev = cur;
        if (timer.read() / std.time.ns_per_ms >= timeout_ms) {
            const out = prev.?;
            prev = null;
            return out;
        }
    }
}

/// A band of the captured window covering `row0..row0+count` of the float,
/// as a fraction of the capture. The float sits `float_row0` rows down the
/// external grid, and the capture includes the title bar, so the row height
/// comes out slightly HIGH — which shrinks the bands rather than letting them
/// reach into each other.
fn floatBand(img: capture.Image, row0: u32, count: u32) visual.Region {
    const h: f64 = @floatFromInt(img.h);
    const cell_h = h / @as(f64, @floatFromInt(ext_rows));
    const top = (@as(f64, @floatFromInt(float_row0 + row0))) * cell_h;
    const bottom = top + @as(f64, @floatFromInt(count)) * cell_h;
    return .{ .y0 = top / h, .y1 = @min(1.0, bottom / h) };
}

pub fn run(alloc: std.mem.Allocator) !void {
    try fixture.requireScreenAccess();
    std.Io.Dir.cwd().createDirPath(gui_io.io(), "tmp") catch {};
    std.Io.Dir.cwd().deleteFile(gui_io.io(), log_path) catch {};

    var g = try fixture.openWithLog(alloc, log_path);
    defer g.deinit();
    g.activateApp();

    try g.exec("execute('set laststatus=0 noruler noshowcmd showtabline=0 scrolloff=0 nowrap noswapfile')");
    try g.exec("execute('set guicursor=a:block-blinkon0')");
    // A bright, saturated foreground on the float's text rows, so the light
    // they contribute is unmistakable against the blank rows below. `Search`
    // only because it is a group Neovim announces and therefore one the core
    // can colour; which group it is does not matter under `groups = "all"`.
    try g.exec("execute('highlight Search guifg=#00ff66 guibg=NONE gui=NONE')");

    var before_buf: [max_windows]platform.MainWindow = undefined;
    const before_windows = before_buf[0..platform.windowsForPid(g.app_pid, &before_buf)];

    // The external window. Opened as an editor float and externalized after
    // the placement has reached the core, so the float below is composited at
    // the host's own origin (see extfloat_over_scrolled_anchor for why the
    // `{external=true}`-from-birth route places it differently).
    try g.exec(
        \\luaeval('(function() local b = vim.api.nvim_create_buf(false, true) local l = {} for i = 1, 200 do l[i] = string.rep(".", 56) end vim.api.nvim_buf_set_lines(b, 0, -1, false, l) _G.z_ext = vim.api.nvim_open_win(b, true, {relative="editor", row=1, col=1, width=60, height=20}) return 1 end)()')
    );
    gui_io.sleepNs(600 * std.time.ns_per_ms);
    try g.exec(
        \\luaeval('(function() vim.api.nvim_win_set_config(_G.z_ext, {external=true, width=60, height=20}) return 1 end)()')
    );
    const ext_win = try waitNewWindow(g.app_pid, before_windows, 150);

    // The hosted layer: a float inside the external window whose first four
    // rows carry the glow group, then four blank rows, then four plain ones.
    try g.exec(
        \\luaeval('(function() local b = vim.api.nvim_create_buf(false, true) local l = {} for i = 1, 12 do if i <= 4 then l[i] = string.rep("W", 40) else l[i] = "" end end vim.api.nvim_buf_set_lines(b, 0, -1, false, l) _G.z_float = vim.api.nvim_open_win(b, false, {relative="win", win=_G.z_ext, row=3, col=2, width=44, height=12, style="minimal"}) local ns = vim.api.nvim_create_namespace("zglow") for i = 0, 3 do vim.api.nvim_buf_add_highlight(b, ns, "Search", i, 0, -1) end return 1 end)()')
    );
    gui_io.sleepNs(1200 * std.time.ns_per_ms);

    var glow_off = try captureWindowStable(alloc, ext_win.number, 8000);
    defer glow_off.deinit(alloc);

    // Switch glow on. The core asks Neovim for the variable on a redraw while
    // its startup retries last, so setting it is not enough — the frames below
    // keep redraws coming until the core reports it accepted the config.
    const t_glow = try app_log.nowMs(alloc, log_path);
    try g.exec(
        \\luaeval('(function() vim.g.zonvie_glow = { groups = "all", radius = 6, intensity = 1.0 } return 1 end)()')
    );
    var armed = false;
    var tries: u32 = 0;
    while (tries < 40) : (tries += 1) {
        try g.exec("execute('redraw!')");
        gui_io.sleepNs(150 * std.time.ns_per_ms);
        if (try app_log.containsSince(alloc, log_path, glow_ready_marker, t_glow)) {
            armed = true;
            break;
        }
    }
    if (!armed) {
        std.debug.print(
            "[gui] extwin_hosted_layer_glow: the core never accepted vim.g.zonvie_glow — nothing to measure\n",
            .{},
        );
        return error.GlowNeverEnabled;
    }
    gui_io.sleepNs(1200 * std.time.ns_per_ms);

    var glow_on = try captureWindowStable(alloc, ext_win.number, 8000);
    defer glow_on.deinit(alloc);

    if (glow_off.w != glow_on.w or glow_off.h != glow_on.h) return error.VisualSizeMismatch;

    // Hand the human both frames, not just a ratio. The numbers below separate
    // "changed" from "did not change"; only the pair says whether what changed
    // is a bloom in the right place or a bloom in the wrong one, and the two
    // mutations above produce band values a reader could mistake for a pass.
    driver.capture.writeImage(alloc, "tmp/glow_off" ++ driver.capture.image_ext, glow_off) catch {};
    driver.capture.writeImage(alloc, "tmp/glow_on" ++ driver.capture.image_ext, glow_on) catch {};

    const glyph_band = floatBand(glow_on, 0, glow_rows);
    const blank_band = floatBand(glow_on, glow_rows + gap_rows, glow_rows);
    const lit = visual.regionDiffRatio(glow_off, glow_on, glyph_band, 12);
    const blank = visual.regionDiffRatio(glow_off, glow_on, blank_band, 12);

    std.debug.print(
        "[gui] extwin_hosted_layer_glow: capture {d}x{d}; glyph band {d:.4} (min {d:.4}), blank band {d:.4} (max {d:.4})\n",
        .{ glow_on.w, glow_on.h, lit, glyph_band_min, blank, blank_band_max },
    );

    if (lit < glyph_band_min) {
        std.debug.print(
            "[gui] the configured rows did not light up — the bloom pass did not reach the hosted layer\n",
            .{},
        );
        return error.HostedLayerDidNotGlow;
    }
    if (blank > blank_band_max) {
        std.debug.print(
            "[gui] the float's empty rows lit up too — the extract pass drew the layer with the ordinary pipeline\n",
            .{},
        );
        return error.HostedLayerGlowedEverywhere;
    }
}
