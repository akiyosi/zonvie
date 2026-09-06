// visual/decorated_surface_background_alpha — a decorated surface's
// transparent background must satisfy BOTH of its consumers.
//
// ext-cmdline / ext-messages resolve backgroundAlpha to 0 when blur is on.
// Two different things then read that back texture, and they want opposite
// conventions:
//
//   * straight to CoreAnimation — the data must be premultiplied, so a
//     transparent background is (0,0,0,0). Writing the theme colour at
//     alpha 0 makes the compositor add the backdrop a second time for the
//     (1-coverage) part of every antialiased glyph edge, which pushes edge
//     pixels PAST the background, away from the text. On a light theme that
//     clips to white and reads as "antialiasing is off".
//
//   * through the custom post-process chain — that chain compiles with
//     preserve_alpha OFF for decorated surfaces, so it discards alpha and
//     takes RGB as the final colour. A premultiplied zero is black there.
//
// Both arms below must stay green together. Fixing either one by itself is
// what produced this test: the premultiplied-zero write cured the halo and
// turned the cmdline panel black under a shader.

const std = @import("std");
const driver = @import("../../driver.zig");
const platform = driver.platform;
const capture = driver.capture;
const Gui = driver.Gui;
const gui_io = @import("../../gui_io.zig");

const log_path = "tmp/gui_decorated_alpha.log";
const home_dir = "tmp/gui_home_decorated_alpha";

/// Proves the custom-shader chain the shader arm depends on actually
/// compiled. Without this the arm would pass on a plain blit.
const shader_loaded_marker = "custom shaders (decorated=1)";

const max_windows = 16;

/// A light theme is the discriminating one: the doubled background pushes
/// edge pixels brighter than the panel, which "past the background, away
/// from the text" can detect. On a dark theme the same error moves edges
/// toward the foreground and measures as 0 either way.
const guibg = "#eff1f5";
const guifg = "#4c4f69";

/// Insets past the cmdline's leading chevron icon and trailing copy button,
/// which are AppKit views rather than core-rendered cells. Everything
/// between is core-rendered, so the measured strip scales with the window
/// and the panel keeps outvoting the text on every row.
const x_lo: u32 = 110;
const x_trailing_inset: u32 = 110;

/// Fixed grid size, so the cmdline is always far wider than the stems
/// below. At ~40 columns they fill the measured strip and the text, not the
/// panel, becomes each row's mode.
const grid_cols: i64 = 120;
const grid_lines: i64 = 30;

const stems = "llllllllllllllllllllllllllllll";

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

fn lumAt(img: capture.Image, x: u32, y: u32) u32 {
    const i = (@as(usize, y) * img.w + x) * 4;
    const r: u32 = img.rgba[i];
    const g: u32 = img.rgba[i + 1];
    const b: u32 = img.rgba[i + 2];
    return (r * 299 + g * 587 + b * 114) / 1000;
}

/// Screenshot a screen-coordinate rect (points) through `screencapture -R`,
/// which yields the DESKTOP COMPOSITE — the pixels the user actually sees —
/// unlike a single-window capture, which keeps the window's own alpha.
fn shootRegion(alloc: std.mem.Allocator, r: platform.Bounds, path: []const u8) !capture.Image {
    const arg_r = try std.fmt.allocPrint(alloc, "-R{d},{d},{d},{d}", .{ r.x, r.y, r.w, r.h });
    defer alloc.free(arg_r);
    const res = try std.process.run(alloc, gui_io.io(), .{
        .argv = &.{ "screencapture", "-x", arg_r, path },
    });
    alloc.free(res.stdout);
    alloc.free(res.stderr);
    return capture.readImage(alloc, path);
}

const Profile = struct {
    /// Modal luminance of the measured strip: the panel background.
    bg: u32,
    /// Strongest mode at least 40 levels away from `bg`: the text.
    fg: u32,
    /// Pixels at the text mode. The "text actually rendered" gate.
    fg_px: u32,
    /// Pixels strictly between the two modes: antialiased glyph edges.
    edge_px: u32,
    /// Distinct luminance levels among those. A surface with no
    /// antialiasing at all reports a handful; a healthy one reports ~10+.
    edge_levels: u32,
    /// Pixels past `bg` in the direction AWAY from `fg`. Correct
    /// antialiasing cannot produce one; a double-composited background can.
    overshoot_px: u32,
    /// Darkest per-row modal luminance, and the row it came from. The
    /// window-wide mode cannot see a lost panel: the decorated shell's
    /// padding surrounds the Metal viewport on all four sides and keeps its
    /// colour through the clear, so a black text area is outvoted by the
    /// frame around it. Per row, the text area is its own mode.
    min_row_bg: u32,
    min_row_y: u32,

    fn report(p: Profile, label: []const u8) void {
        std.debug.print(
            "[gui] {s}: bg={d} fg={d} fg_px={d} edge_px={d} edge_levels={d}" ++
                " overshoot_px={d} min_row_bg={d}@y{d}\n",
            .{ label, p.bg, p.fg, p.fg_px, p.edge_px, p.edge_levels, p.overshoot_px, p.min_row_bg, p.min_row_y },
        );
    }
};

fn profile(img: capture.Image) Profile {
    const xb = if (img.w > x_lo + x_trailing_inset) img.w - x_trailing_inset else img.w;
    var hist = [_]u32{0} ** 256;
    // Inset past the 1pt window border, which is neither panel nor text.
    const ya: u32 = 6;
    const yb: u32 = if (img.h > 12) img.h - 6 else img.h;
    var y: u32 = ya;
    while (y < yb) : (y += 1) {
        var x: u32 = x_lo;
        while (x < xb) : (x += 1) hist[lumAt(img, x, y)] += 1;
    }

    var bg: u32 = 0;
    for (hist, 0..) |c, v| if (c > hist[bg]) {
        bg = @intCast(v);
    };
    var fg: u32 = bg;
    var best: u32 = 0;
    for (hist, 0..) |c, v| {
        const d = if (v > bg) v - bg else bg - v;
        if (d >= 40 and c > best) {
            best = c;
            fg = @intCast(v);
        }
    }

    var out: Profile = .{
        .bg = bg,
        .fg = fg,
        .fg_px = hist[fg],
        .edge_px = 0,
        .edge_levels = 0,
        .overshoot_px = 0,
        .min_row_bg = 255,
        .min_row_y = 0,
    };

    y = ya;
    while (y < yb) : (y += 1) {
        var row = [_]u32{0} ** 256;
        var x: u32 = x_lo;
        while (x < xb) : (x += 1) row[lumAt(img, x, y)] += 1;
        var mode: u32 = 0;
        for (row, 0..) |c, v| if (c > row[mode]) {
            mode = @intCast(v);
        };
        if (mode < out.min_row_bg) {
            out.min_row_bg = mode;
            out.min_row_y = y;
        }
    }

    if (fg == bg) return out;

    const lo = @min(bg, fg) + 8;
    const hi = @max(bg, fg) - 8;
    var v: u32 = lo;
    while (v <= hi) : (v += 1) {
        out.edge_px += hist[v];
        if (hist[v] > 0) out.edge_levels += 1;
    }

    // The +-7 skirt around the modal value absorbs the compositor's own
    // dither and the 1-level rounding of the luminance weights, so only a
    // genuine excursion past the panel counts.
    if (fg < bg) {
        var t: u32 = bg + 7;
        while (t < 256) : (t += 1) out.overshoot_px += hist[t];
    } else if (bg >= 7) {
        var t: u32 = 0;
        while (t <= bg - 7) : (t += 1) out.overshoot_px += hist[t];
    }
    return out;
}

/// Bring up `:llll…` in the ext-cmdline and measure the desktop composite
/// of the cmdline window.
fn measureCmdline(alloc: std.mem.Allocator, config_dir: []const u8, tag: []const u8) !Profile {
    std.Io.Dir.cwd().deleteFile(gui_io.io(), log_path) catch {};
    // Isolated, freshly emptied HOME: the main window frame is autosaved in
    // NSUserDefaults, so without this the cmdline inherits whatever width the
    // last scenario left there, and `set columns` below would write this
    // scenario's width back for the next one.
    std.Io.Dir.cwd().deleteTree(gui_io.io(), home_dir) catch {};
    std.Io.Dir.cwd().createDirPath(gui_io.io(), home_dir) catch {};

    var g = try Gui.init(alloc, .{
        .app_args = &.{ "--extcmdline", "--log", log_path },
        .home_dir = home_dir,
        .config_dir = config_dir,
    });
    defer g.deinit();
    platform.pinWindow(g.app_pid, 80, 80);
    g.activateApp();

    try g.exec("execute('set guicursor+=a:blinkon0')");
    try g.exec("execute('set guifont=Menlo:h13')");
    try g.exec("execute('set laststatus=0 noruler nonumber')");
    const size = try std.fmt.allocPrint(
        alloc,
        "execute('set columns={d} lines={d}')",
        .{ grid_cols, grid_lines },
    );
    defer alloc.free(size);
    try g.exec(size);
    gui_io.sleepNs(1500 * std.time.ns_per_ms);
    if (try g.evalInt("&columns") != grid_cols) return error.GridSizeNotApplied;

    const hl = try std.fmt.allocPrint(
        alloc,
        "execute('hi Normal guibg={s} guifg={s} | hi MsgArea guibg={s} guifg={s} | hi NormalFloat guibg={s} guifg={s}')",
        .{ guibg, guifg, guibg, guifg, guibg, guifg },
    );
    defer alloc.free(hl);
    try g.exec(hl);
    gui_io.sleepNs(800 * std.time.ns_per_ms);

    var before_buf: [max_windows]platform.MainWindow = undefined;
    const before = before_buf[0..platform.windowsForPid(g.app_pid, &before_buf)];
    if (before.len == 0) return error.MainWindowNotFound;

    try g.remoteSend(":");
    gui_io.sleepNs(700 * std.time.ns_per_ms);
    try g.remoteSend(stems);
    gui_io.sleepNs(1500 * std.time.ns_per_ms);

    const cmd_win = newWindow(g.app_pid, before) orelse return error.CmdlineWindowNotFound;
    if (cmd_win.bounds.w < @as(f64, @floatFromInt(x_lo + x_trailing_inset)) or cmd_win.bounds.h < 10) {
        std.debug.print(
            "[gui] {s}: cmdline window too small to measure: {d}x{d}\n",
            .{ tag, cmd_win.bounds.w, cmd_win.bounds.h },
        );
        return error.CmdlineWindowNotOnScreen;
    }

    const path = try std.fmt.allocPrint(alloc, "tmp/decorated_alpha_{s}.png", .{tag});
    defer alloc.free(path);
    var img = try shootRegion(alloc, cmd_win.bounds, path);
    defer img.deinit(alloc);

    const p = profile(img);
    p.report(tag);
    try g.remoteSend("<Esc>");
    gui_io.sleepNs(200 * std.time.ns_per_ms);

    // Vacuity gates common to both arms: a run that rendered no text, or
    // that captured a uniform rectangle, would otherwise satisfy the
    // overshoot assertion for the wrong reason.
    if (p.fg == p.bg) return error.NoTextRendered;
    if (p.fg_px < min_fg_px) return error.TooLittleTextRendered;
    return p;
}

/// Thirty 'l' stems at Menlo:h13 measure 1916 pixels at the text mode in
/// both arms. A tenth of that is far below any run that drew the text and
/// far above a blank or uniform capture.
const min_fg_px: u32 = 190;

/// Floor for every row's panel luminance. Measured 228 in the no-shader arm
/// and 240 in the shader arm, against 0 for the rows of the black text area
/// the defect produces. Half of the smaller measurement sits in the empty
/// middle of that gap, so neither the display colour profile nor a shader
/// that tints its output can drift across it.
const min_panel_lum: u32 = 114;

pub fn run(alloc: std.mem.Allocator) !void {
    std.Io.Dir.cwd().createDirPath(gui_io.io(), "tmp") catch {};

    // Arm 1 — straight to the compositor. The premultiplied convention is
    // the only one that antialiases correctly there, so no edge pixel may
    // land outside the closed [fg, bg] interval. Exactly zero: the two
    // correct conventions both measure 0, and the defect measures ~1100.
    const plain = try measureCmdline(alloc, "test/gui/fixtures/config_decorated_alpha", "no_shader");
    if (plain.overshoot_px != 0) {
        std.debug.print(
            "[gui] FAIL: {d} cmdline pixels overshoot the panel (bg={d}) — the" ++
                " transparent background is not premultiplied\n",
            .{ plain.overshoot_px, plain.bg },
        );
        return error.GlyphEdgeHalo;
    }

    // Arm 2 — consumed by the custom-shader chain, which discards alpha.
    // The panel must still carry its colour.
    const shaded = try measureCmdline(alloc, "test/gui/fixtures/config_decorated_shader", "shader");
    const log = std.Io.Dir.cwd().readFileAlloc(gui_io.io(), log_path, alloc, .limited(64 * 1024 * 1024)) catch |e| {
        std.debug.print("[gui] cannot read {s}: {any}\n", .{ log_path, e });
        return e;
    };
    defer alloc.free(log);
    if (std.mem.indexOf(u8, log, shader_loaded_marker) == null) {
        std.debug.print("[gui] FAIL: shader arm ran without a decorated shader chain\n", .{});
        return error.ShaderChainNotActive;
    }
    if (shaded.min_row_bg < min_panel_lum) {
        std.debug.print(
            "[gui] FAIL: cmdline row y={d} has panel luminance {d} under a shader" ++
                " — the chain discards alpha, so a premultiplied-zero background" ++
                " becomes black\n",
            .{ shaded.min_row_y, shaded.min_row_bg },
        );
        return error.ShaderPanelLostColor;
    }
    // The no-shader arm goes through the same rows, so hold it to the same
    // floor: a premultiplied zero that reached the compositor unblended
    // would show there as the identical black band.
    if (plain.min_row_bg < min_panel_lum) {
        std.debug.print(
            "[gui] FAIL: cmdline row y={d} has panel luminance {d} without a shader\n",
            .{ plain.min_row_y, plain.min_row_bg },
        );
        return error.PanelLostColor;
    }
}
