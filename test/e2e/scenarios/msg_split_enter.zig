// msg_split_enter — a route's `enter` controls whether showing a split-routed
// message moves the cursor into it, in both directions and on every show.
//
// Three behaviors pinned, each the override of a channel default:
//   * enter=true on a msg_show route: a routed message TAKES the cursor
//     (default is not to steal — msg_split_lifecycle pins that side).
//   * enter=true applies on a RE-SHOW into a live split too: nvim_open_win
//     only takes focus when it creates the window, so the generated program
//     must move the cursor itself on later shows.
//   * enter=false on a msg_history_show route: `:messages` does NOT take the
//     cursor (default is that it does — msg_history_repeat pins that side).
//
// Ordering discipline: every cursor assertion follows an ordered signal —
// the split's content visible in its grid proves the show batch (including
// any cursor move it performs) has been fully applied. waitCursorGrid is a
// rising-edge wait for the takes-focus cases; the stays-put case asserts
// only after the content signal.

const std = @import("std");
const zc = @import("zonvie_core");
const Harness = @import("../harness.zig").Harness;

const msg_grid: i64 = -102;

var routes = [_]zc.config.MsgRoute{
    // Only `echo` takes focus — the opposite of the channel default. Keeping
    // the filter narrow lets the history phase seed its entry via `echomsg`
    // without re-opening this split.
    .{ .filter = .{ .event = .msg_show, .kinds = &.{"echo"} }, .view = .split, .opts = .{ .timeout = 0, .enter = true } },
    // `:messages` keeps the cursor — the opposite of its channel default.
    .{ .filter = .{ .event = .msg_history_show }, .view = .split, .opts = .{ .timeout = 0, .enter = false } },
};

fn findSplitGrid(h: *Harness, alloc: std.mem.Allocator, buffer_grid: i64) !i64 {
    const ids = try h.positionedGridsAlloc(alloc);
    defer alloc.free(ids);
    for (ids) |id| {
        if (id != buffer_grid and !h.isExternalGrid(id)) return id;
    }
    return error.SplitGridNotFound;
}

const NeedleCtx = struct { needle: []const u8 };

fn floatHas(c: NeedleCtx, h: *Harness) bool {
    var row: u32 = 0;
    while (row < 24) : (row += 1) {
        const text = h.rowTextAlloc(h.alloc, msg_grid, row) catch continue;
        defer h.alloc.free(text);
        if (std.mem.indexOf(u8, text, c.needle) != null) return true;
    }
    return false;
}

pub fn run(alloc: std.mem.Allocator) !void {
    var h = try Harness.init(alloc, .{ .ext_messages = true, .msg_routes = &routes });
    defer h.deinit();

    const start_windows = h.windowCount();
    const buffer_grid = h.winGrid();

    try h.input("ianchor<Esc>");
    try h.waitRowText(buffer_grid, 0, "anchor", h.opts.timeout_ms);

    // 1. enter=true takes the cursor on the mount.
    try h.command("echo 'enter first'");
    try h.waitWindowCount(start_windows + 1, h.opts.timeout_ms);
    const split_grid = try findSplitGrid(h, alloc, buffer_grid);
    try h.waitRowText(split_grid, 0, "enter first", h.opts.timeout_ms);
    h.waitCursorGrid(split_grid, h.opts.timeout_ms) catch |e| {
        std.debug.print(
            "[e2e] msg_split_enter: enter=true did not move the cursor into the split on mount\n",
            .{},
        );
        return e;
    };

    // 2. ...and on a re-show into the LIVE window. Leave the split first so
    //    the move is observable; the window survives being left
    //    (msg_split_lifecycle pins that), so the next show re-renders in
    //    place instead of mounting.
    try h.command("wincmd p");
    try h.waitCursorGrid(buffer_grid, h.opts.timeout_ms);
    try h.command("echo 'enter again'");
    try h.waitRowText(split_grid, 0, "enter again", h.opts.timeout_ms);
    h.waitCursorGrid(split_grid, h.opts.timeout_ms) catch |e| {
        std.debug.print(
            "[e2e] msg_split_enter: enter=true only took focus on the mount, not on the re-show\n",
            .{},
        );
        return e;
    };

    // Close it so the history phase starts from a clean single window.
    try h.input("q");
    try h.waitWindowCount(start_windows, h.opts.timeout_ms);
    try h.waitCursorGrid(buffer_grid, h.opts.timeout_ms);

    // 3. enter=false keeps the cursor out of `:messages`. The entry is
    //    seeded via `echomsg`, which the narrow route above does not match —
    //    it lands in the ext_float grid (catch-all default), and its
    //    visibility there is the ordered signal that it entered history.
    try h.command("echomsg 'hist entry'");
    try h.waitUntil(NeedleCtx{ .needle = "hist entry" }, floatHas, h.opts.timeout_ms);
    try h.command("messages");
    try h.waitWindowCount(start_windows + 1, h.opts.timeout_ms);
    const hist_grid = try findSplitGrid(h, alloc, buffer_grid);
    // Ordered signal: history content visible, so the show batch — and any
    // cursor move it would have made — is fully applied.
    try h.waitRowText(hist_grid, 0, "hist entry", h.opts.timeout_ms);
    if (h.cursor().grid_id != buffer_grid) {
        std.debug.print(
            "[e2e] msg_split_enter: enter=false but :messages took the cursor (grid={d}, expected {d})\n",
            .{ h.cursor().grid_id, buffer_grid },
        );
        return error.HistoryStoleCursor;
    }
}
