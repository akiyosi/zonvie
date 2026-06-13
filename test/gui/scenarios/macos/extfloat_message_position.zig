// extfloat_message_position — sister of mini_message_position for the
// ext-float message view with msg_pos.ext-float = "grid".
//
// The ext-float popup (errors, echoes) anchors to the TOP-right of the
// grid under the cursor in grid mode. Before the fix, a float grid (e.g.
// a telescope prompt) was used as the anchor directly, so the popup
// appeared glued to the float mid-screen. The fix resolves a float to the
// non-float grid it is anchored to — for an editor-anchored float that is
// the global grid, i.e. the main window's top-right corner.
//
// Drives an echoerr inside the float: error kinds route to the ext-float
// view by default. A hit-enter prompt window (bottom-center) may appear
// alongside, so the assertion is existential: once the set of new windows
// settles, exactly the top-right-aligned popup must be among them.

const std = @import("std");
const driver = @import("../../driver.zig");
const platform = driver.platform;
const Gui = driver.Gui;

const max_windows = 16;
const settle_polls = 4; // bounds unchanged for 4 * 250 ms = startup settled
const tol_px = 150.0; // float-anchored placement is off by several hundred px

/// Poll until the main-window bounds stop changing, then return them.
fn waitStableMainBounds(g: *Gui) !platform.Bounds {
    var timer = std.time.Timer.start() catch unreachable;
    var last: ?platform.Bounds = null;
    var same: u32 = 0;
    while (true) {
        if (timer.read() / std.time.ns_per_ms >= 15_000) return error.Timeout;
        std.Thread.sleep(250 * std.time.ns_per_ms);
        const b = platform.mainWindowBoundsForPid(g.app_pid) orelse continue;
        if (last) |l| {
            if (l.x == b.x and l.y == b.y and l.w == b.w and l.h == b.h) {
                same += 1;
                if (same >= settle_polls) return b;
            } else {
                same = 0;
            }
        }
        last = b;
    }
}

fn contains(set: []const platform.MainWindow, number: u32) bool {
    for (set) |w| if (w.number == number) return true;
    return false;
}

pub fn run(alloc: std.mem.Allocator) !void {
    var g = try Gui.init(alloc, .{
        .app_args = &.{ "--extmessages", "--log", "tmp/gui_app.log" },
        .config_dir = "test/gui/fixtures/config_extfloat_grid",
    });
    defer g.deinit();

    const main_b = try waitStableMainBounds(g);

    // Editor-anchored float under the cursor (telescope-prompt shape).
    try g.exec(
        "luaeval('(function() _G.e2e_float = vim.api.nvim_open_win(" ++
            "vim.api.nvim_create_buf(false, true), true, " ++
            "{relative=\"editor\", row=3, col=3, width=30, height=5}) return 1 end)()')",
    );

    // The scenario tests nothing unless the cursor is actually in the float.
    const in_float = try g.evalInt("luaeval('(vim.api.nvim_get_current_win() == _G.e2e_float) and 1 or 0')");
    if (in_float != 1) return error.CursorNotInFloat;

    var before_buf: [max_windows]platform.MainWindow = undefined;
    const before = before_buf[0..platform.windowsForPid(g.app_pid, &before_buf)];

    // Error message while the cursor sits in the float: echoerr routes to
    // the ext-float view. Typed keys, not remote-expr — error emission
    // inside an expression context fails the expression itself.
    try g.remoteSend(":echoerr 'zonvie-e2e-error'<CR>");

    // Wait until at least one new window appeared and the set has settled
    // for 1 s, then require a top-right-aligned popup among the new windows
    // (a hit-enter prompt window may legitimately appear bottom-center).
    var timer = std.time.Timer.start() catch unreachable;
    var stable: u32 = 0;
    var last_fresh: usize = 0;
    while (true) {
        if (timer.read() / std.time.ns_per_ms >= 10_000) {
            std.debug.print("[gui] no ext-float popup appeared (new windows: {d})\n", .{last_fresh});
            return error.Timeout;
        }
        std.Thread.sleep(100 * std.time.ns_per_ms);

        var now_buf: [max_windows]platform.MainWindow = undefined;
        const now = now_buf[0..platform.windowsForPid(g.app_pid, &now_buf)];

        var fresh: usize = 0;
        for (now) |w| {
            if (!contains(before, w.number)) fresh += 1;
        }
        if (fresh == 0 or fresh != last_fresh) {
            stable = 0;
            last_fresh = fresh;
            continue;
        }
        stable += 1;
        if (stable < 10) continue;

        // Set settled: one of the new windows must hug main's top-right.
        for (now) |w| {
            if (contains(before, w.number)) continue;
            const d_right = (main_b.x + main_b.w) - (w.bounds.x + w.bounds.w);
            const d_top = w.bounds.y - main_b.y;
            if (@abs(d_right) <= tol_px and @abs(d_top) <= tol_px) return;
        }
        for (now) |w| {
            if (contains(before, w.number)) continue;
            std.debug.print(
                "[gui] new window not at main top-right: main=({d:.0},{d:.0},{d:.0},{d:.0}) win=({d:.0},{d:.0},{d:.0},{d:.0})\n",
                .{ main_b.x, main_b.y, main_b.w, main_b.h, w.bounds.x, w.bounds.y, w.bounds.w, w.bounds.h },
            );
        }
        return error.ExtFloatWindowMisplaced;
    }
}
