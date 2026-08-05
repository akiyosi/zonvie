// msg_split_lifecycle — the split message view must appear, update, keep the
// cursor where it was, and survive being left.
//
// Covers three defects that all lived in the split path and had no test:
//   * a second message did not update an already-mounted split (early return)
//   * a `BufLeave` autocmd closed the split on any window switch
//   * the split was opened with enter=true and stole the cursor
//
// The split is a real Neovim window, so it is observed through win_pos rather
// than through any callback.
//
// Ordering discipline: window-count and cursor assertions are made only AFTER
// an ordered signal proves the round trip completed — content visible in a
// grid, or the cursor observed on a specific grid. A bare
// `waitWindowCount(expected)` after an input is an equality-wait that passes
// on the FIRST poll, i.e. before a buggy close or a stacked window could have
// been observed; an earlier version of this scenario had exactly that hole.

const std = @import("std");
const zc = @import("zonvie_core");
const Harness = @import("../harness.zig").Harness;

var routes = [_]zc.config.MsgRoute{
    // No timeout: the split must stay until this scenario is done with it.
    .{ .filter = .{ .event = .msg_show }, .view = .split, .opts = .{ .timeout = 0 } },
};

pub fn run(alloc: std.mem.Allocator) !void {
    var h = try Harness.init(alloc, .{ .ext_messages = true, .msg_routes = &routes });
    defer h.deinit();

    const start_windows = h.windowCount();
    const buffer_grid = h.winGrid();

    // Put known content in the buffer so cursor ownership is observable.
    try h.input("ianchor<Esc>");
    try h.waitRowText(buffer_grid, 0, "anchor", h.opts.timeout_ms);

    // First message: the split window appears. Waiting for the count to RISE
    // is a legitimate rising-edge wait.
    try h.command("echo 'first message'");
    try h.waitWindowCount(start_windows + 1, h.opts.timeout_ms);

    // Find the split's grid: the positioned grid that is not the buffer's.
    const ids = try h.positionedGridsAlloc(alloc);
    defer alloc.free(ids);
    var split_grid: i64 = 0;
    for (ids) |id| {
        if (id != buffer_grid and !h.isExternalGrid(id)) split_grid = id;
    }
    if (split_grid == 0) return error.SplitGridNotFound;

    // Ordered signal: the split's content is visible, so the batch that
    // created the window (and would have moved the cursor, had enter been
    // true) has been fully applied.
    try h.waitRowText(split_grid, 0, "first message", h.opts.timeout_ms);
    if (h.cursor().grid_id != buffer_grid) {
        std.debug.print(
            "[e2e] msg_split_lifecycle: split stole the cursor (grid={d}, expected {d})\n",
            .{ h.cursor().grid_id, buffer_grid },
        );
        return error.SplitStoleCursor;
    }

    // Second message: the existing split must be UPDATED in place.
    //
    // This one wait catches both remount defects: with the early-return bug
    // the first split keeps its old content and this times out; with a
    // stacking bug the new content lands in a NEW window's grid, so the
    // first split's grid never shows it and this times out too.
    try h.command("echo 'second message'");
    try h.waitRowText(split_grid, 0, "second message", h.opts.timeout_ms);

    // The update batch is applied (content proved it), so a stacked window
    // would be visible in win_pos by now.
    if (h.windowCount() != start_windows + 1) {
        std.debug.print(
            "[e2e] msg_split_lifecycle: window count changed on update ({d}, expected {d})\n",
            .{ h.windowCount(), start_windows + 1 },
        );
        return error.SplitWindowStacked;
    }

    // Leaving and returning must not close the split. Each switch is ordered
    // by observing the cursor land on the target grid.
    try h.input("<C-w>w");
    try h.waitCursorGrid(split_grid, h.opts.timeout_ms);
    try h.input("<C-w>w");
    try h.waitCursorGrid(buffer_grid, h.opts.timeout_ms);

    // Full round trip after the switches: a BufLeave-triggered close from the
    // switch would have been processed strictly before this edit's events.
    try h.input("osync<Esc>");
    try h.waitRowText(buffer_grid, 1, "sync", h.opts.timeout_ms);
    if (h.windowCount() != start_windows + 1) {
        std.debug.print(
            "[e2e] msg_split_lifecycle: split closed on window switch ({d} windows, expected {d})\n",
            .{ h.windowCount(), start_windows + 1 },
        );
        return error.SplitClosedOnLeave;
    }

    // The buffer is untouched throughout.
    try h.waitRowText(buffer_grid, 0, "anchor", h.opts.timeout_ms);
}
