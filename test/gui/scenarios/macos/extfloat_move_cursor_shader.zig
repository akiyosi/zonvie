// extfloat_move_cursor_shader — dragging an external float window must
// move the cursor shader with it.
//
// Reported symptom: with a cursor shader loaded, moving an external float
// leaves the shader drawing at the float's PRE-MOVE position.
//
// Cause: the shader cursor rect is expressed in the MAIN window's drawable
// pixels (screenSpaceParameters measures the float's top-left relative to
// the main view's), but ExternalGridView only recomputed it when Neovim
// delivered new cursor vertices. Dragging a window produces no vertices,
// so the rect kept the offset the float had before the drag.
//
// Asserted on the value the SHADER RECEIVES, logged from
// makeCustomShaderUniforms as [shader_cursor], not on the value the
// external view computed. That distinction is the whole test: the first
// attempt at this fix re-projected the rect correctly and still changed
// nothing on screen, because setCursorShaderState only STAGES and the
// staged value is published by a surface commit — which a window drag
// never produces. Asserting on the computed value passed anyway.
//
// A screenshot comparison would be weaker still: the shader's animation
// would have to be frozen first, and a wrong rect inside the float's own
// bounds could look plausible.
//
// macOS-only: the shader cursor plumbing lives in the macOS frontend.

const std = @import("std");
const driver = @import("../../driver.zig");
const platform = driver.platform;
const Gui = driver.Gui;
const app_log = @import("../../app_log.zig");
const gui_io = @import("../../gui_io.zig");

const log_path = "tmp/gui_extfloat_move.log";
const marker = "[shader_cursor]";

/// Move applied to the float, in screen points.
const move_dx_pt: f64 = 150;
const move_dy_pt: f64 = 100;

/// The rect is in drawable pixels, so it must track the move times the
/// backing scale. One pixel of slack absorbs the cell-rounding the
/// projection does; a stale rect is off by the whole move, not by one px.
const tolerance_px: f64 = 2;

const max_windows = 16;

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
            return error.FloatWindowNotFound;
        }
        gui_io.sleepNs(100 * std.time.ns_per_ms);
    }
}

/// Wait for the app to publish a shader cursor rect after `since_ms` and
/// return its x/y in drawable pixels.
fn waitCursorRect(alloc: std.mem.Allocator, since_ms: f64, timeout_ms: u64) !struct { x: f64, y: f64 } {
    var timer = gui_io.Timer.start();
    while (true) {
        if (try app_log.lastLineSince(alloc, log_path, marker, since_ms)) |line| {
            defer alloc.free(line);
            const x = app_log.field(line, "x") orelse return error.CursorRectUnparsable;
            const y = app_log.field(line, "y") orelse return error.CursorRectUnparsable;
            return .{ .x = x, .y = y };
        }
        if (timer.read() / std.time.ns_per_ms >= timeout_ms) return error.NoCursorRectPublished;
        gui_io.sleepNs(100 * std.time.ns_per_ms);
    }
}

pub fn run(alloc: std.mem.Allocator) !void {
    if (!platform.accessibilityTrusted()) {
        std.debug.print(
            "[gui] skipped: not trusted for Accessibility, so the float cannot be moved. " ++
                "Grant this binary under System Settings > Privacy & Security > Accessibility.\n",
            .{},
        );
        return error.SkipZigTest;
    }

    std.Io.Dir.cwd().createDirPath(gui_io.io(), "tmp") catch {};
    std.Io.Dir.cwd().deleteFile(gui_io.io(), log_path) catch {};

    var g = try Gui.init(alloc, .{
        .app_args = &.{ "--log", log_path },
        .config_dir = "test/gui/fixtures/config_animated_shader",
    });
    defer g.deinit();
    g.activateApp();

    // Open an external float; the cursor goes into it, which is what makes
    // this view the one publishing the shader cursor rect.
    var before_buf: [max_windows]platform.MainWindow = undefined;
    const before = before_buf[0..platform.windowsForPid(g.app_pid, &before_buf)];
    try g.exec(
        "luaeval('(function() _G.e2e_float = vim.api.nvim_open_win(" ++
            "vim.api.nvim_create_buf(false, true), true, " ++
            "{external=true, width=40, height=12}) return 1 end)()')",
    );
    const float_win = try waitNewWindow(g.app_pid, before, 100);

    // Park it somewhere known and fully on screen before measuring.
    const start_x: f64 = 80;
    const start_y: f64 = 80;
    if (!platform.moveWindowBySize(g.app_pid, float_win.bounds.w, float_win.bounds.h, start_x, start_y)) {
        return error.MoveFailed;
    }
    gui_io.sleepNs(500 * std.time.ns_per_ms);

    // Nudge the cursor so a rect is published from the settled position.
    const t0 = try app_log.nowMs(alloc, log_path);
    try g.remoteSend("i");
    const first = try waitCursorRect(alloc, t0, 10_000);
    std.debug.print("[gui] cursor shader rect before move: ({d:.0},{d:.0})\n", .{ first.x, first.y });

    // Move it, with no Neovim activity behind the move: a cursor update
    // would recompute the rect on its own and hide the bug.
    const t1 = try app_log.nowMs(alloc, log_path);
    if (!platform.moveWindowBySize(
        g.app_pid,
        float_win.bounds.w,
        float_win.bounds.h,
        start_x + move_dx_pt,
        start_y + move_dy_pt,
    )) {
        return error.MoveFailed;
    }

    const moved = try waitCursorRect(alloc, t1, 10_000);
    std.debug.print("[gui] cursor shader rect after move:  ({d:.0},{d:.0})\n", .{ moved.x, moved.y });

    // Backing scale from the app's own log rather than assuming Retina:
    // the rect is in drawable pixels, the move was in points.
    const scale = blk: {
        const line = (try app_log.lastLineSince(alloc, log_path, "[resizeExternalWindows]", 0)) orelse
            return error.BackingScaleUnknown;
        defer alloc.free(line);
        break :blk app_log.field(line, "scale") orelse return error.BackingScaleUnknown;
    };
    const expect_dx = move_dx_pt * scale;
    const expect_dy = move_dy_pt * scale;
    const got_dx = moved.x - first.x;
    const got_dy = moved.y - first.y;
    std.debug.print(
        "[gui] rect delta: got ({d:.0},{d:.0}) expected ({d:.0},{d:.0})\n",
        .{ got_dx, got_dy, expect_dx, expect_dy },
    );

    if (@abs(got_dx - expect_dx) > tolerance_px or @abs(got_dy - expect_dy) > tolerance_px) {
        std.debug.print(
            "[gui] the cursor shader rect did not follow the window: it is still projected " ++
                "through the pre-move offset\n",
            .{},
        );
        return error.CursorShaderRectDidNotFollowWindow;
    }
}
