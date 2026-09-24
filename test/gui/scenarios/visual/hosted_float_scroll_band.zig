// visual/hosted_float_scroll_band — while a float is smooth-scrolled on its
// own, the band its sub-row offset opens at the top or bottom must be filled
// with the float's own content, on the main window and inside an external one.
//
// Reported by hand: the main window fills that band with the rows the scroll
// retained, while a float an external window hosts showed an empty strip
// there. The external surface released the edge-row stretch
// (`pin_edges`) for its root only, so a hosted float stretched its edge row's
// background over the rows it had retained.
//
// The oracle is colour. Float lines alternate two backgrounds across the whole
// width, so a correctly drawn float is a stack of stripes exactly one cell
// tall; a band filled by stretching the edge row shows up as that stripe
// growing taller. Host-coloured pixels inside the float's rect are counted as
// well, for a band nothing drew at all. The rect is found from a capture taken
// before the gesture and does not move while the float scrolls on its own.
// Sampled while the gesture is held, where the offset stays put, both ways.
//
// The float is bordered, as a real one usually is. That is not decoration:
// a border makes its scroll region narrower than its grid, so the core does
// not take the row-shift fast path, and the rows have to be retained from the
// grid_scroll hand-over instead — the path an external window never received
// for a float it hosts. A borderless float scrolls full width, takes the fast
// path, and passes whether that hand-over works or not.
//
// The main window runs first as the control: it shows the oracle can see a
// correct band as correct, so a failure on the external window is the
// external window's.
//
// macOS-only: it drives a trackpad gesture and enumerates the app's windows.

const std = @import("std");
const driver = @import("../../driver.zig");
const platform = driver.platform;
const capture = driver.capture;
const fixture = @import("fixture.zig");
const gui_io = @import("../../gui_io.zig");

const max_windows = 16;
const config_dir = "test/gui/fixtures/config_hosted_opaque";

const host_bg = [3]i32{ 0x20, 0x60, 0xa0 };
/// Alternate float lines are painted these two colours, so every row of the
/// float is a stripe exactly one cell tall.
const odd_bg = [3]i32{ 0xa0, 0x20, 0x60 };
const even_bg = [3]i32{ 0x60, 0xa0, 0x20 };
/// A channel may differ by this much (colour-space conversion in the capture).
const tolerance: i32 = 24;
/// Pixels kept clear of the rect's edge, where the float's edge pixels blend
/// with the host.
const inset_px: u32 = 3;
/// A stripe may exceed the settled cell height by this much (a pixel of
/// rounding at a sub-pixel offset).
const stripe_slack_px: usize = 2;

/// Gesture steps per direction, and how far each moves. Several steps per row,
/// so the samples land on many different sub-row offsets.
const steps_per_direction: usize = 14;
const step_px: f64 = 4;

const Rect = struct { x0: u32, y0: u32, x1: u32, y1: u32 };

const Sample = struct {
    /// Host-coloured pixels inside the float's rect: a strip nothing drew.
    host_px: usize,
    /// The tallest single-colour stripe, in pixels.
    stripe_px: usize,
};

fn near(img: capture.Image, i: usize, rgb: [3]i32) bool {
    return @abs(@as(i32, img.rgba[i]) - rgb[0]) <= tolerance and
        @abs(@as(i32, img.rgba[i + 1]) - rgb[1]) <= tolerance and
        @abs(@as(i32, img.rgba[i + 2]) - rgb[2]) <= tolerance;
}

fn isFloat(img: capture.Image, i: usize) bool {
    return near(img, i, odd_bg) or near(img, i, even_bg);
}

/// The bounding box of the float's two stripe colours, inset.
fn floatRect(img: capture.Image) ?Rect {
    var r = Rect{ .x0 = img.w, .y0 = img.h, .x1 = 0, .y1 = 0 };
    var y: u32 = 0;
    while (y < img.h) : (y += 1) {
        var x: u32 = 0;
        while (x < img.w) : (x += 1) {
            if (!isFloat(img, (@as(usize, y) * img.w + x) * 4)) continue;
            r.x0 = @min(r.x0, x);
            r.y0 = @min(r.y0, y);
            r.x1 = @max(r.x1, x + 1);
            r.y1 = @max(r.y1, y + 1);
        }
    }
    if (r.x1 <= r.x0 + 2 * inset_px or r.y1 <= r.y0 + 2 * inset_px) return null;
    return .{ .x0 = r.x0 + inset_px, .y0 = r.y0 + inset_px, .x1 = r.x1 - inset_px, .y1 = r.y1 - inset_px };
}

fn measure(img: capture.Image, r: Rect) Sample {
    var out = Sample{ .host_px = 0, .stripe_px = 0 };
    var y = r.y0;
    while (y < @min(r.y1, img.h)) : (y += 1) {
        var x = r.x0;
        while (x < @min(r.x1, img.w)) : (x += 1) {
            if (near(img, (@as(usize, y) * img.w + x) * 4, host_bg)) out.host_px += 1;
        }
    }
    // Stripes are read down a column near the rect's right edge, clear of the
    // line text at the left. A band the renderer fills by stretching the edge
    // row's background, instead of drawing the row that belongs there, shows
    // up as that edge stripe growing taller than one cell.
    const x = r.x1 - 1 - @min(r.x1 - r.x0 - 1, 12);
    var run_px: usize = 0;
    var run_colour: u8 = 0;
    y = r.y0;
    while (y < @min(r.y1, img.h)) : (y += 1) {
        const i = (@as(usize, y) * img.w + x) * 4;
        const colour: u8 = if (near(img, i, odd_bg)) 1 else if (near(img, i, even_bg)) 2 else 0;
        if (colour != 0 and colour == run_colour) {
            run_px += 1;
        } else {
            run_px = if (colour != 0) 1 else 0;
            run_colour = colour;
        }
        out.stripe_px = @max(out.stripe_px, run_px);
    }
    return out;
}

fn waitNewWindow(pid: i32, before: []const platform.MainWindow) !platform.MainWindow {
    var buf: [max_windows]platform.MainWindow = undefined;
    var attempt: u32 = 0;
    while (attempt < 150) : (attempt += 1) {
        const now = buf[0..platform.windowsForPid(pid, &buf)];
        for (now) |w| {
            var seen = false;
            for (before) |b| {
                if (b.number == w.number) seen = true;
            }
            if (!seen and w.bounds.w >= 100 and w.bounds.h >= 100) return w;
        }
        gui_io.sleepNs(100 * std.time.ns_per_ms);
    }
    platform.dumpWindowsForPid(pid);
    return error.ExternalWindowNotFound;
}

/// Glide the float one way and back while the gesture is held, sampling the
/// float's rect after each step. Returns the worst host strip and the worst
/// stripe overrun beyond one settled cell.
fn glideAndSample(alloc: std.mem.Allocator, g: *driver.Gui, win: platform.MainWindow, label: []const u8) !Sample {
    var base = try capture.captureWindow(alloc, win.number);
    defer base.deinit(alloc);
    {
        var name_buf: [96]u8 = undefined;
        const name = std.fmt.bufPrint(&name_buf, "tmp/hosted_float_scroll_band_{s}_settled" ++ capture.image_ext, .{label}) catch "";
        if (name.len != 0) capture.writeImage(alloc, name, base) catch {};
    }
    const rect = floatRect(base) orelse {
        std.debug.print("[gui] {s}: the float's colours are not in the capture\n", .{label});
        return error.FloatNotFound;
    };
    // Settled, the float must be clean and striped one cell per row, or the
    // samples below measure nothing.
    const settled = measure(base, rect);
    if (settled.host_px != 0 or settled.stripe_px < 8) {
        std.debug.print("[gui] {s}: settled float host_px={d} stripe_px={d}\n", .{ label, settled.host_px, settled.stripe_px });
        return error.OracleNotClean;
    }

    const top0 = try g.evalInt("luaeval('vim.fn.getwininfo(_G.z_float)[1].topline')");
    if (!platform.scrollBegin(g.app_pid, win)) {
        std.debug.print("[gui] {s}: could not drive a trackpad gesture\n", .{label});
        return error.SkipZigTest;
    }
    var top_mid: i64 = top0;
    var worst = Sample{ .host_px = 0, .stripe_px = 0 };
    var worst_step: usize = 0;
    var step: usize = 0;
    while (step < 2 * steps_per_direction) : (step += 1) {
        // Down (content up) first, so there is room above for the return.
        platform.scrollStep(if (step < steps_per_direction) -step_px else step_px);
        gui_io.sleepNs(120 * std.time.ns_per_ms);
        var img = capture.captureWindow(alloc, win.number) catch continue;
        defer img.deinit(alloc);
        const m = measure(img, rect);
        if (step == steps_per_direction - 1) {
            top_mid = try g.evalInt("luaeval('vim.fn.getwininfo(_G.z_float)[1].topline')");
        }
        worst.host_px = @max(worst.host_px, m.host_px);
        if (m.stripe_px > worst.stripe_px) {
            worst.stripe_px = m.stripe_px;
            worst_step = step;
            var name_buf: [96]u8 = undefined;
            const name = std.fmt.bufPrint(&name_buf, "tmp/hosted_float_scroll_band_{s}" ++ capture.image_ext, .{label}) catch "";
            if (name.len != 0) capture.writeImage(alloc, name, img) catch {};
        }
    }
    platform.scrollEnd();
    gui_io.sleepNs(600 * std.time.ns_per_ms);

    std.debug.print(
        "[gui] {s}: float rect {d},{d}-{d},{d}; topline {d} -> {d} at the turn; cell stripe {d}px; worst stripe {d}px at step {d}, worst host {d}px\n",
        .{ label, rect.x0, rect.y0, rect.x1, rect.y1, top0, top_mid, settled.stripe_px, worst.stripe_px, worst_step, worst.host_px },
    );
    // Liveness: a gesture that never reached the float samples a still float
    // and would pass. Read at the turn, since the return leg undoes it.
    if (top_mid <= top0) return error.FloatDidNotScroll;
    return .{
        .host_px = worst.host_px,
        .stripe_px = worst.stripe_px -| (settled.stripe_px + stripe_slack_px),
    };
}

fn setColours(g: *driver.Gui) !void {
    try g.exec("execute('set laststatus=0 noruler noshowcmd showtabline=0 nowrap noswapfile')");
    try g.exec("execute('highlight Normal guibg=#2060a0 guifg=#ffffff')");
    try g.exec("execute('highlight NormalFloat guibg=#a02060 guifg=#ffffff')");
    try g.exec("execute('highlight ZOdd guibg=#a02060 guifg=#ffffff')");
    try g.exec("execute('highlight ZEven guibg=#60a020 guifg=#ffffff')");
    try g.exec("execute('highlight FloatBorder guibg=#303030 guifg=#ffffff')");
}

/// A float scrolled on its own needs more lines than it shows; a float whose
/// content fits lets the scroll fall through to the host. Each line is
/// painted across the float's whole width, alternating ZOdd and ZEven.
const float_lines_lua = "local fb = vim.api.nvim_create_buf(false, true) local fl = {} for i = 1, 400 do fl[i] = string.format(\"%3d float line\", i) end vim.api.nvim_buf_set_lines(fb, 0, -1, false, fl) " ++
    "local ns = vim.api.nvim_create_namespace(\"z_stripes\") for i = 1, 400 do vim.api.nvim_buf_set_extmark(fb, ns, i - 1, 0, {line_hl_group = (i % 2 == 1) and \"ZOdd\" or \"ZEven\"}) end ";
const host_lines_lua = "local b = vim.api.nvim_create_buf(false, true) local l = {} for i = 1, 400 do l[i] = string.format(\"%3d host line\", i) end vim.api.nvim_buf_set_lines(b, 0, -1, false, l) ";

fn runMain(alloc: std.mem.Allocator) !Sample {
    var g = try fixture.openWithLogAndConfig(alloc, "tmp/gui_hosted_float_scroll_band_main.log", config_dir);
    defer g.deinit();
    g.activateApp();
    try setColours(g);
    // Centred on the editor, where the gesture lands.
    try g.exec("luaeval('(function() " ++ host_lines_lua ++ "vim.api.nvim_win_set_buf(0, b) " ++ float_lines_lua ++
        "_G.z_float = vim.api.nvim_open_win(fb, false, {relative=\"editor\", row=math.floor(vim.o.lines/2)-6, col=math.floor(vim.o.columns/2)-24, width=48, height=12, style=\"minimal\", border=\"single\"}) return 1 end)()')");
    gui_io.sleepNs(800 * std.time.ns_per_ms);
    const win = platform.mainWindowForPid(g.app_pid) orelse return error.NoMainWindow;
    return glideAndSample(alloc, g, win, "main");
}

fn runExternal(alloc: std.mem.Allocator) !Sample {
    var g = try fixture.openWithLogAndConfig(alloc, "tmp/gui_hosted_float_scroll_band_ext.log", config_dir);
    defer g.deinit();
    g.activateApp();
    try setColours(g);
    // An external window is a float to Neovim, so it takes NormalFloat: give
    // that the host's colour and the hosted float a group of its own.
    try g.exec("execute('highlight NormalFloat guibg=#2060a0 guifg=#ffffff')");
    try g.exec("execute('highlight ZFloat guibg=#a02060 guifg=#ffffff')");

    var before_buf: [max_windows]platform.MainWindow = undefined;
    const before = before_buf[0..platform.windowsForPid(g.app_pid, &before_buf)];
    try g.exec("luaeval('(function() " ++ host_lines_lua ++
        "_G.z_anchor = vim.api.nvim_open_win(b, true, {external=true, width=60, height=20})  return 1 end)()')");
    const ext = try waitNewWindow(g.app_pid, before);
    gui_io.sleepNs(600 * std.time.ns_per_ms);

    // Covers the external window's centre, where the gesture lands.
    try g.exec("luaeval('(function() " ++ float_lines_lua ++
        "_G.z_float = vim.api.nvim_open_win(fb, false, {relative=\"win\", win=_G.z_anchor, row=4, col=6, width=48, height=12, style=\"minimal\", border=\"single\"}) " ++
        "vim.wo[_G.z_float].winhighlight = \"NormalFloat:ZFloat\" return 1 end)()')");
    gui_io.sleepNs(800 * std.time.ns_per_ms);
    // Hosted, not given a window of its own.
    if (platform.windowsForPid(g.app_pid, &before_buf) != before.len + 1) return error.FloatGotItsOwnWindow;
    return glideAndSample(alloc, g, ext, "external");
}

pub fn run(alloc: std.mem.Allocator) !void {
    try fixture.requireScreenAccess();
    const main_worst = try runMain(alloc);
    const ext_worst = try runExternal(alloc);
    std.debug.print(
        "[gui] hosted_float_scroll_band: main host={d}px overrun={d}px, external host={d}px overrun={d}px\n",
        .{ main_worst.host_px, main_worst.stripe_px, ext_worst.host_px, ext_worst.stripe_px },
    );
    if (main_worst.host_px != 0 or main_worst.stripe_px != 0) {
        std.debug.print("[gui] the MAIN window's float did not fill its scroll band: the oracle or the control is broken\n", .{});
        return error.MainFloatBandUncovered;
    }
    if (ext_worst.host_px != 0) {
        std.debug.print("[gui] a float an external window hosts showed the host through its scroll band\n", .{});
        return error.HostedFloatBandUndrawn;
    }
    if (ext_worst.stripe_px != 0) {
        std.debug.print("[gui] a float an external window hosts filled its scroll band by stretching the edge row, not with the row that left\n", .{});
        return error.HostedFloatBandStretched;
    }
}
