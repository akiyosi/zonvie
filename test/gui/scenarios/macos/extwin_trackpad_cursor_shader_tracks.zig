// extwin_trackpad_cursor_shader_tracks — while a trackpad gesture scrolls an
// EXTERNAL window, the cursor shader must describe the cursor the frame draws,
// never the one the next flush will draw.
//
// Reported symptom: with a cursor shader loaded, the effect fires a row step
// ahead of the cursor while an external window is being scrolled; the main
// window does not do this.
//
// Cause: three things describe one cursor on the glass — the committed rows a
// frame draws, the cursor rect the shader is handed, and the displacement that
// cancels a row that just landed — and on an external surface they were
// updated at three different moments. The rect is published by the surface's
// commit and evaluated late in the frame, and the compensation was published
// by the MAIN surface's commit, so a frame could pair any generation of one
// with another generation of the rest. The main surface evaluates and settles
// against its own commit, under its own lock.
//
// Measured on [ext_shader_cursor_frame], which the external draw logs with the
// cursor row and displacement it draws the body with beside the rect the
// shader receives. Their difference is a constant while all three describe
// one commit; a frame that mixed generations shows a whole row step in it.
// The count of such frames is the exposure, so one run decides it.
//
// macOS-only: the shader cursor plumbing lives in the macOS frontend.

const std = @import("std");
const driver = @import("../../driver.zig");
const platform = driver.platform;
const Gui = driver.Gui;
const app_log = @import("../../app_log.zig");
const gui_io = @import("../../gui_io.zig");

const log_path = "tmp/gui_extwin_trackpad_cursor_shader.log";
const frame_marker = "[ext_shader_cursor_frame]";
const scroll_marker = "[ExternalGridView] scroll offset:";

const grid_rows = 20;
const grid_cols = 60;
const max_windows = 16;
/// Gestures alternate direction and stay short, so the cursor's screen row
/// walks up and down the middle of the window without reaching an edge. A
/// cursor pinned at an edge keeps its rect across a landing, and a rect that
/// does not change cannot show which generation it came from.
const gesture_passes = 6;
const steps_per_gesture = 50;
const step_px: f64 = 6;

fn waitNewWindow(pid: i32, before: []const platform.MainWindow, min_side: f64) !platform.MainWindow {
    var timer = gui_io.Timer.start();
    while (true) {
        var buf: [max_windows]platform.MainWindow = undefined;
        const now = buf[0..platform.windowsForPid(pid, &buf)];
        outer: for (now) |w| {
            for (before) |b| {
                if (b.number == w.number) continue :outer;
            }
            if (w.bounds.w < min_side or w.bounds.h < min_side) continue;
            return w;
        }
        if (timer.read() / std.time.ns_per_ms >= 10_000) {
            platform.dumpWindowsForPid(pid);
            return error.ExternalWindowNotFound;
        }
        gui_io.sleepNs(100 * std.time.ns_per_ms);
    }
}

fn cellHeightPx(alloc: std.mem.Allocator, since_ms: f64) !f64 {
    const blob = try app_log.linesSince(alloc, log_path, scroll_marker, since_ms);
    defer alloc.free(blob);
    var it = std.mem.splitScalar(u8, blob, '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        const cell_ndc = app_log.field(line, "cellNDC") orelse continue;
        const vp_h = app_log.field(line, "vpH") orelse continue;
        if (cell_ndc > 0 and vp_h > 0) return cell_ndc * vp_h / 2.0;
    }
    return 0;
}

const Tracking = struct {
    samples: usize,
    /// Frames whose rect was a row or more away from the body it was logged with.
    mixed: usize,
    worst_px: f64,
};

fn measure(alloc: std.mem.Allocator, since_ms: f64, cell_px: f64) !Tracking {
    const blob = try app_log.linesSince(alloc, log_path, frame_marker, since_ms);
    defer alloc.free(blob);
    var samples: usize = 0;
    var mixed: usize = 0;
    var worst: f64 = 0;
    var base: ?f64 = null;
    var it = std.mem.splitScalar(u8, blob, '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        const row = app_log.field(line, "row") orelse continue;
        const off = app_log.field(line, "offPx") orelse continue;
        const y = app_log.field(line, "y") orelse continue;
        // Everything but the constant: the rect minus the body's own position.
        const residual = y - off - row * cell_px;
        samples += 1;
        if (base == null) {
            base = residual;
            continue;
        }
        const dev = @abs(residual - base.?);
        if (dev > worst) worst = dev;
        if (dev >= cell_px * 0.5) mixed += 1;
    }
    return .{ .samples = samples, .mixed = mixed, .worst_px = worst };
}

pub fn run(alloc: std.mem.Allocator) !void {
    std.Io.Dir.cwd().createDirPath(gui_io.io(), "tmp") catch {};
    std.Io.Dir.cwd().deleteFile(gui_io.io(), log_path) catch {};

    var g = try Gui.init(alloc, .{
        .app_args = &.{ "--log", log_path },
        .config_dir = "test/gui/fixtures/config_cursor_shader_anim",
    });
    defer g.deinit();
    g.activateApp();

    var before_buf: [max_windows]platform.MainWindow = undefined;
    const before = before_buf[0..platform.windowsForPid(g.app_pid, &before_buf)];

    try g.exec(
        "luaeval('(function() local b = vim.api.nvim_create_buf(false, true) " ++
            "local lines = {} for i = 1, 400 do lines[i] = string.rep(\"line \" .. i .. \" \", 6) end " ++
            "vim.api.nvim_buf_set_lines(b, 0, -1, true, lines) " ++
            "_G.e2e_extwin = vim.api.nvim_open_win(b, true, " ++
            "{external=true, width=" ++ std.fmt.comptimePrint("{d}", .{grid_cols}) ++
            ", height=" ++ std.fmt.comptimePrint("{d}", .{grid_rows}) ++ "}) " ++
            "vim.api.nvim_win_set_cursor(_G.e2e_extwin, {200, 0}) " ++
            "return 1 end)()')",
    );
    const extwin = try waitNewWindow(g.app_pid, before, 150);
    gui_io.sleepNs(800 * std.time.ns_per_ms);

    const t0 = try app_log.nowMs(alloc, log_path);
    const topline_before = try g.evalInt("line('w0')");

    // The passes alternate, so the topline returns to where it started; the
    // gate reads it after the first pass, while it is displaced.
    var topline_mid: i64 = topline_before;
    var pass: usize = 0;
    while (pass < gesture_passes) : (pass += 1) {
        if (!platform.scrollBegin(g.app_pid, extwin)) {
            std.debug.print("[gui] could not drive a trackpad gesture on the external window\n", .{});
            return error.SkipZigTest;
        }
        const dir: f64 = if (pass % 2 == 0) -1 else 1;
        var step: usize = 0;
        while (step < steps_per_gesture) : (step += 1) {
            platform.scrollStep(dir * step_px);
            gui_io.sleepNs(16 * std.time.ns_per_ms);
        }
        platform.scrollEnd();
        gui_io.sleepNs(800 * std.time.ns_per_ms);
        if (pass == 0) topline_mid = try g.evalInt("line('w0')");
    }

    std.debug.print("[gui] extwin topline before={d} after first pass={d}\n", .{ topline_before, topline_mid });
    if (topline_mid == topline_before) {
        std.debug.print("[gui] the gesture never scrolled the external window; nothing to measure\n", .{});
        return error.ExternalWindowDidNotScroll;
    }

    const cell = try cellHeightPx(alloc, t0);
    if (cell <= 0) {
        std.debug.print("[gui] no scroll offset line carried the cell height; the gesture was not eased\n", .{});
        return error.CellHeightUnparsable;
    }

    const tracking = try measure(alloc, t0, cell);
    std.debug.print(
        "[gui] extwin cursor shader vs body: samples={d} mixed_frames={d} worst={d:.1}px cell={d:.1}px\n",
        .{ tracking.samples, tracking.mixed, tracking.worst_px, cell },
    );
    // A run with no per-frame samples measured nothing.
    if (tracking.samples < 20) {
        std.debug.print("[gui] only {d} frame line(s) were logged\n", .{tracking.samples});
        return error.CursorFramesNotLogged;
    }
    if (tracking.mixed != 0) {
        std.debug.print(
            "[gui] {d} frame(s) handed the shader a cursor rect a row step away from the cursor " ++
                "the frame drew: the rect, the rows and the compensation came from different flushes.\n",
            .{tracking.mixed},
        );
        return error.CursorShaderMixedGenerations;
    }
}
