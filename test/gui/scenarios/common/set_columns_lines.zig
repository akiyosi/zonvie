// set_columns_lines — `:set columns=` / `:set lines=` resize the OS window.
//
// Neovim owns 'columns'/'lines' and reports a changed global grid size via
// grid_resize. The core detects the size it did not itself request and asks
// the frontend to resize its window (on_main_grid_size), so the terminal area
// becomes exactly cols x rows cells.
//
// Asserts what a human verifies by eye: typing `:set columns=...` makes the
// real OS window get narrower, and `:set lines=...` makes it shorter.

const std = @import("std");
const Gui = @import("../../driver.zig").Gui;
const gui_io = @import("../../gui_io.zig");

const Axis = enum { width, height };

/// Poll until the main window moved at least 20px on `axis` in `dir`, or time out.
fn waitResized(g: *Gui, axis: Axis, from: f64, dir: enum { shrink, grow }, timeout_ms: u64) !void {
    var elapsed: u64 = 0;
    while (true) {
        if (g.mainWindowBounds()) |b| {
            const cur = switch (axis) {
                .width => b.w,
                .height => b.h,
            };
            switch (dir) {
                .shrink => if (cur < from - 20) return,
                .grow => if (cur > from + 20) return,
            }
        }
        if (elapsed >= timeout_ms) return error.Timeout;
        gui_io.sleepNs(100 * std.time.ns_per_ms);
        elapsed += 100;
    }
}

pub fn run(alloc: std.mem.Allocator) !void {
    var g = try Gui.init(alloc, .{ .app_args = &.{ "--log", "tmp/gui_set_columns.log" } });
    defer g.deinit();

    const base = g.mainWindowBounds() orelse return error.NoMainWindow;

    // Shrink the grid horizontally: the window must get narrower.
    const cols = try g.evalInt("&columns");
    try std.testing.expect(cols > 40);
    try g.exec("execute('set columns=40')");
    try waitResized(g, .width, base.w, .shrink, 10_000);

    // Shrink the grid vertically: the window must get shorter. Re-read the
    // height first so the width change above cannot satisfy this check.
    const after_cols = g.mainWindowBounds() orelse return error.NoMainWindow;
    const lines = try g.evalInt("&lines");
    try std.testing.expect(lines > 15);
    try g.exec("execute('set lines=15')");
    try waitResized(g, .height, after_cols.h, .shrink, 10_000);

    // Grow both axes back: the window must get wider and taller again, and
    // Neovim must end up with exactly the requested grid (growing is where the
    // frontend's repaint has to follow the window, not precede it).
    const small = g.mainWindowBounds() orelse return error.NoMainWindow;
    try g.exec("execute('set columns=90 lines=30')");
    try waitResized(g, .width, small.w, .grow, 10_000);
    try waitResized(g, .height, small.h, .grow, 10_000);

    // Let the try_resize round trip settle, then confirm Neovim's grid is the
    // requested size — i.e. the window reached it and did not bounce back.
    gui_io.sleepNs(1500 * std.time.ns_per_ms);
    try std.testing.expectEqual(@as(i64, 90), try g.evalInt("&columns"));
    try std.testing.expectEqual(@as(i64, 30), try g.evalInt("&lines"));
}
