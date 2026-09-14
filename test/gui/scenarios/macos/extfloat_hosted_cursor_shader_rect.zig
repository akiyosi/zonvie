// extfloat_hosted_cursor_shader_rect — a cursor inside a float that an
// EXTERNAL window hosts must reach the cursor shader at the float's position.
//
// A float anchored to an external window is not given a window of its own: the
// external surface draws it as a layer at the float's own origin inside that
// window. The surface has one cursor, and when it belongs to such a layer its
// vertices arrive through submitLayerCursor.
//
// That path stored the vertices and stopped. Only the surface's ROOT cursor
// path forwarded a rect into the shared cursor-shader state, so moving the
// cursor into a hosted float left iCurrentCursor wherever it was before —
// the effect stayed behind while the real cursor moved. The main window has
// never had this hole: its submitLayerCursor adds the layer's origin and
// publishes (MetalTerminalRenderer.updateCursorShaderStateFromVerts).
//
// Measured as the DELTA between two float placements rather than an absolute
// rect. The absolute value needs the external view's client origin inside the
// main window's space, which is exactly what the projection computes; taking
// it from window bounds here would re-implement the thing under test and pass
// on its own arithmetic. A delta cancels it and leaves only the layer-origin
// term, which is the term that was missing.
//
// The delta is also what separates this from a fix that forwards the rect but
// forgets the layer origin (the shape of the same defect on Windows): that
// publishes a line, so "a rect appeared" would pass, but both placements
// report the same x.
//
// macOS-only: the shader cursor plumbing lives in the macOS frontend.

const std = @import("std");
const driver = @import("../../driver.zig");
const platform = driver.platform;
const Gui = driver.Gui;
const app_log = @import("../../app_log.zig");
const gui_io = @import("../../gui_io.zig");

const log_path = "tmp/gui_extfloat_hosted_cursor_shader.log";
const marker = "[shader_cursor]";
const max_windows = 16;

/// The two columns the float is opened at, inside the external window. Far
/// enough apart that the expected delta is many cells wide, so a stale rect
/// (delta 0) cannot be mistaken for rounding.
const col_a: i64 = 2;
const col_b: i64 = 26;
/// Rows likewise, to catch an origin applied on one axis only.
const row_a: i64 = 1;
const row_b: i64 = 9;

/// The rect is in drawable pixels and the cursor sits at the float's own
/// column 0 in both placements, so the delta is a whole number of cells.
/// One pixel of slack absorbs the rect's own rounding.
const tolerance_px: f64 = 2;

const Rect = struct { x: f64, y: f64 };

fn waitCursorRect(alloc: std.mem.Allocator, since_ms: f64, timeout_ms: u64) !Rect {
    var timer = gui_io.Timer.start();
    while (true) {
        if (try app_log.lastLineSince(alloc, log_path, marker, since_ms)) |line| {
            defer alloc.free(line);
            return .{
                .x = app_log.field(line, "x") orelse return error.CursorRectUnparsable,
                .y = app_log.field(line, "y") orelse return error.CursorRectUnparsable,
            };
        }
        if (timer.read() / std.time.ns_per_ms >= timeout_ms) return error.NoCursorRectPublished;
        gui_io.sleepNs(100 * std.time.ns_per_ms);
    }
}

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
            return error.ExternalWindowNotFound;
        }
        gui_io.sleepNs(100 * std.time.ns_per_ms);
    }
}

/// Open the float inside the external window and put the cursor in it. Each
/// call is a fresh entry, which is what makes the core send a cursor for that
/// grid and the surface publish a rect for the placement it now has.
fn openFloatAt(g: *Gui, row: i64, col: i64) !void {
    var buf: [512]u8 = undefined;
    const cmd = try std.fmt.bufPrint(
        &buf,
        "luaeval('(function() local b = vim.api.nvim_create_buf(false, true) " ++
            "vim.api.nvim_buf_set_lines(b, 0, -1, false, {{\"probe\", \"probe\"}}) " ++
            "_G.z_float = vim.api.nvim_open_win(b, true, {{relative=\"win\", win=_G.z_anchor, " ++
            "row={d}, col={d}, width=12, height=3, style=\"minimal\"}}) return 1 end)()')",
        .{ row, col },
    );
    try g.exec(cmd);
}

pub fn run(alloc: std.mem.Allocator) !void {
    std.Io.Dir.cwd().createDirPath(gui_io.io(), "tmp") catch {};
    std.Io.Dir.cwd().deleteFile(gui_io.io(), log_path) catch {};

    var g = try Gui.init(alloc, .{
        .app_args = &.{ "--log", log_path },
        .config_dir = "test/gui/fixtures/config_cursor_shader",
    });
    defer g.deinit();
    g.activateApp();

    var before_buf: [max_windows]platform.MainWindow = undefined;
    const before = before_buf[0..platform.windowsForPid(g.app_pid, &before_buf)];
    const before_count = before.len;

    // The host: an ordinary editor window given a window of its own. Its buffer
    // carries more lines than the window shows, or phase two's <C-e> has
    // nothing to scroll and that phase guards nothing.
    try g.exec(
        \\luaeval('(function() local b = vim.api.nvim_create_buf(false, true) local l = {} for i = 1, 200 do l[i] = string.format("%3d host line", i) end vim.api.nvim_buf_set_lines(b, 0, -1, false, l) _G.z_anchor = vim.api.nvim_open_win(b, true, {external=true, width=60, height=20}) return 1 end)()')
    );
    const ext_win = try waitNewWindow(g.app_pid, before, 100);
    gui_io.sleepNs(600 * std.time.ns_per_ms);

    // Cell metrics in the same drawable pixels the rect is expressed in
    // (resizeExternalWindows divides these by the backing scale to get points).
    const cell_w = blk: {
        const line = (try app_log.lastLineSince(alloc, log_path, "[resizeExternalWindows]", 0)) orelse
            return error.CellMetricsUnknown;
        defer alloc.free(line);
        break :blk app_log.field(line, "cellW") orelse return error.CellMetricsUnknown;
    };
    const cell_h = blk: {
        const line = (try app_log.lastLineSince(alloc, log_path, "[resizeExternalWindows]", 0)) orelse
            return error.CellMetricsUnknown;
        defer alloc.free(line);
        break :blk app_log.field(line, "cellH") orelse return error.CellMetricsUnknown;
    };

    // Placement A.
    const t0 = try app_log.nowMs(alloc, log_path);
    try openFloatAt(g, row_a, col_a);
    gui_io.sleepNs(600 * std.time.ns_per_ms);

    // Gate: the float is anchored to the external window and composited INTO
    // it. A float given a window of its own would be drawn by its own surface
    // root, whose cursor path was never broken, and would pass for the wrong
    // reason.
    if (try g.evalInt("luaeval('(vim.api.nvim_win_get_config(_G.z_float).win == _G.z_anchor) and 1 or 0')") != 1) {
        return error.FloatNotAnchoredToExternal;
    }
    const window_count = platform.windowsForPid(g.app_pid, &before_buf);
    if (window_count != before_count + 1) {
        std.debug.print(
            "[gui] expected the float to be composited into the external window, but the app has {d} windows (was {d} plus the anchor)\n",
            .{ window_count, before_count },
        );
        return error.FloatGotItsOwnWindow;
    }

    const at_a = waitCursorRect(alloc, t0, 10_000) catch |e| {
        std.debug.print(
            "[gui] no shader cursor rect was published after the cursor entered a float hosted by " ++
                "the external window: the layer cursor path never forwards one\n",
            .{},
        );
        return e;
    };
    std.debug.print("[gui] hosted-float cursor rect at col {d}: ({d:.0},{d:.0})\n", .{ col_a, at_a.x, at_a.y });

    // Placement B: same float-local cursor cell, a different origin inside the
    // host. Closing and reopening makes the cursor enter afresh, so the core
    // sends a cursor for the new placement rather than leaving the old rect
    // standing.
    const t1 = try app_log.nowMs(alloc, log_path);
    try g.exec("luaeval('(function() vim.api.nvim_win_close(_G.z_float, true) return 1 end)()')");
    gui_io.sleepNs(300 * std.time.ns_per_ms);
    try openFloatAt(g, row_b, col_b);
    gui_io.sleepNs(600 * std.time.ns_per_ms);

    const at_b = try waitCursorRect(alloc, t1, 10_000);
    std.debug.print("[gui] hosted-float cursor rect at col {d}: ({d:.0},{d:.0})\n", .{ col_b, at_b.x, at_b.y });

    const expect_dx = @as(f64, @floatFromInt(col_b - col_a)) * cell_w;
    const expect_dy = @as(f64, @floatFromInt(row_b - row_a)) * cell_h;
    const got_dx = at_b.x - at_a.x;
    const got_dy = at_b.y - at_a.y;
    std.debug.print(
        "[gui] rect delta: got ({d:.0},{d:.0}) expected ({d:.0},{d:.0}) cell {d:.1}x{d:.1}\n",
        .{ got_dx, got_dy, expect_dx, expect_dy, cell_w, cell_h },
    );

    if (@abs(got_dx - expect_dx) > tolerance_px or @abs(got_dy - expect_dy) > tolerance_px) {
        std.debug.print(
            "[gui] the shader cursor rect did not move with the float's placement inside its host: " ++
                "the layer's origin is missing from the projection\n",
            .{},
        );
        return error.HostedCursorShaderRectIgnoresLayerOrigin;
    }

    // The delta is a relative statement: a projection wrong by a constant
    // satisfies it, and per-grid rendering already produced one of those once
    // (grid-local PIXELS fed into an NDC formula, landing thousands of pixels
    // away). So pin the absolute x too. The shader's space is the MAIN
    // window's drawable, so the float's cursor belongs at the host window's
    // own screen offset plus the float's columns — both of which come from the
    // OS here, not from the projection under test.
    //
    // x only: the two windows' client areas start at the same x as their
    // frames, while their title bars make the y offset a frontend detail this
    // has no independent source for. The y axis is covered by the delta above.
    const scale = blk: {
        const line = (try app_log.lastLineSince(alloc, log_path, "[resizeExternalWindows]", 0)) orelse
            return error.BackingScaleUnknown;
        defer alloc.free(line);
        break :blk app_log.field(line, "scale") orelse return error.BackingScaleUnknown;
    };
    var now_buf: [max_windows]platform.MainWindow = undefined;
    const now_wins = now_buf[0..platform.windowsForPid(g.app_pid, &now_buf)];
    var main_win: ?platform.MainWindow = null;
    var host_win: ?platform.MainWindow = null;
    for (now_wins) |wnd| {
        if (wnd.number == ext_win.number) host_win = wnd else if (main_win == null) main_win = wnd;
    }
    const host = host_win orelse return error.ExternalWindowGone;
    const main_w = main_win orelse return error.MainWindowNotFound;
    const expect_ax = (host.bounds.x - main_w.bounds.x) * scale + @as(f64, @floatFromInt(col_a)) * cell_w;
    std.debug.print(
        "[gui] placement A x: got {d:.0} expected {d:.0} (host at {d:.0}, main at {d:.0}, scale {d:.0})\n",
        .{ at_a.x, expect_ax, host.bounds.x, main_w.bounds.x, scale },
    );
    // One cell of slack: the window frame may inset the client area by a
    // border, which is far smaller than a cell and much smaller than any
    // failure this is looking for.
    if (@abs(at_a.x - expect_ax) > cell_w) {
        std.debug.print(
            "[gui] the hosted float's cursor rect is not at the float's place on screen\n",
            .{},
        );
        return error.CursorShaderRectMisprojected;
    }

    // Phase two: the host scrolls underneath a float that does not track the
    // buffer. Such a float stays where it is — drawHostedLayers displaces only
    // `followsScroll` layers — so the cursor inside it is drawn at a standstill
    // and its effect has to stand still too.
    //
    // The rect carries the grid it is on, and that id is what picks the scroll
    // displacement the shader cursor is given. Tagging a hosted float's cursor
    // with the SURFACE handed it the root's displacement: the effect slid a
    // cell up the window while the cursor it tracks never moved.
    //
    // Counted over the whole run rather than sampled mid-animation: the ease
    // decays back to zero, so the settled rect matches in either build and only
    // the frames in between tell them apart. The log keeps them all.
    const t2 = try app_log.nowMs(alloc, log_path);
    const settled_y = at_b.y;
    // A real <C-e> in the host's own context. winrestview moves the view
    // without going through the scroll fast path, and seeds no ease — the gate
    // below caught that. The cursor stays in the float throughout, which is the
    // configuration under test.
    try g.exec(
        \\luaeval('(function() vim.api.nvim_win_call(_G.z_anchor, function() vim.cmd("normal! " .. vim.api.nvim_replace_termcodes("<C-e>", true, false, true)) end) return 1 end)()')
    );
    gui_io.sleepNs(1200 * std.time.ns_per_ms);

    // Gate: the host really did ease. Without a live offset neither build
    // displaces anything and the count below is zero for the wrong reason.
    const eased = try app_log.countLinesSince(alloc, log_path, "[ExternalGridView] scroll offset:", t2);
    std.debug.print("[gui] host scroll offset frames: {d}\n", .{eased});
    if (eased == 0) {
        std.debug.print("[gui] the host never displaced its grid, so this phase would guard nothing\n", .{});
        return error.HostDidNotScroll;
    }

    const moved = try countRectsWithOtherY(alloc, t2, at_b.x, settled_y);
    std.debug.print(
        "[gui] shader cursor rects at a different y while the host eased: {d} (settled y={d:.0})\n",
        .{ moved, settled_y },
    );
    if (moved != 0) {
        std.debug.print(
            "[gui] the cursor effect moved with the HOST's scroll although the float it sits in is fixed\n",
            .{},
        );
        return error.FixedFloatCursorFollowedHostScroll;
    }

    std.debug.print("[gui] PASS: the hosted float's cursor reaches the shader at the float's own origin\n", .{});
}

/// How many shader cursor rects published since `since_ms` sit at the float's
/// cursor column but at a y other than `settled_y`. The cursor did not move, so
/// each one is the effect being displaced by a scroll that is not its own.
///
/// Selected by x rather than by the logged grid: the grid tag is the thing
/// under test here, so a build with the defect would be filtered by the very
/// value the fix corrects. The host's own cursor sits in another column and is
/// excluded by that alone — it is published while the win_call below runs.
fn countRectsWithOtherY(
    alloc: std.mem.Allocator,
    since_ms: f64,
    float_x: f64,
    settled_y: f64,
) !usize {
    const blob = try app_log.linesSince(alloc, log_path, marker, since_ms);
    defer alloc.free(blob);
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, blob, '\n');
    while (it.next()) |line| {
        const x = app_log.field(line, "x") orelse continue;
        if (@abs(x - float_x) > tolerance_px) continue;
        const y = app_log.field(line, "y") orelse continue;
        if (@abs(y - settled_y) <= tolerance_px) continue;
        n += 1;
    }
    return n;
}
