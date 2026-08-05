// msg_split_close_key — the split's own `q` mapping must close it.
//
// buildSplitLua registers buffer-local `q` and `<Esc>` maps on the mount path
// (nvim_core.zig:5076-5079) and warns in its own comment that a re-seated
// window would be "a split that `q` and `<Esc>` cannot close". Nothing
// exercised either key: msg_split_quit closes the EDITOR with `:q`, and
// msg_split_timeout closes the split on a timer. This is the dismissal
// gesture a user actually performs.
//
// Ordered signals: appearance is a rising window-count edge; entering the
// split is confirmed by the cursor landing on its grid before `q` is sent;
// disappearance is a falling edge observed strictly after both.

const std = @import("std");
const zc = @import("zonvie_core");
const Harness = @import("../harness.zig").Harness;

// timeout = 0: only the keypress may close it, so a pass cannot be a timer
// firing at the right moment.
var routes = [_]zc.config.MsgRoute{
    .{ .filter = .{ .event = .msg_show }, .view = .split, .opts = .{ .timeout = 0 } },
};

pub fn run(alloc: std.mem.Allocator) !void {
    var h = try Harness.init(alloc, .{ .ext_messages = true, .msg_routes = &routes });
    defer h.deinit();

    const start_windows = h.windowCount();
    const buffer_grid = h.winGrid();

    try h.command("echo 'dismiss me'");
    try h.waitWindowCount(start_windows + 1, h.opts.timeout_ms);

    const ids = try h.positionedGridsAlloc(alloc);
    defer alloc.free(ids);
    var split_grid: i64 = 0;
    for (ids) |id| {
        if (id != buffer_grid and !h.isExternalGrid(id)) split_grid = id;
    }
    if (split_grid == 0) return error.SplitGridNotFound;
    try h.waitRowText(split_grid, 0, "dismiss me", h.opts.timeout_ms);

    // Enter the split, then dismiss it the way the user would.
    try h.input("<C-w>w");
    try h.waitCursorGrid(split_grid, h.opts.timeout_ms);
    try h.input("q");

    h.waitWindowCount(start_windows, h.opts.timeout_ms) catch |e| {
        std.debug.print("[e2e] msg_split_close_key: 'q' did not close the split\n", .{});
        return e;
    };

    // And the cursor is back in the editor, not orphaned on a dead grid.
    try h.waitCursorGrid(buffer_grid, h.opts.timeout_ms);
}
