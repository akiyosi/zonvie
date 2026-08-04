// msg_mini_then_split — a frontend-owned message window must be taken down
// when a split-routed message replaces it.
//
// `on_msg_clear` is the ONLY signal a frontend gets that the mini/prompt window
// it is drawing must come down. In the split arm of `showChannelView` that call
// was moved to AFTER the content is handed to Neovim (flush.zig:9059-9062), so
// that a failed assembly or a failed RPC send leaves the old UI in place
// instead of emptying it with nothing to replace it. That reorder is correct
// only if the callback still fires on the success path — and no unit test can
// see it, because the property under test is a two-step frontend-visible
// sequence: mini up, then split up AND mini down.
//
// Ordering discipline: the mini window is only considered up once its
// `on_msg_show` has actually been recorded; the clear counter is sampled only
// after that; and it is re-read only after a rising window-count edge plus the
// split's own content proves the split dispatch completed. No bare equality
// wait is used for either transition.

const std = @import("std");
const zc = @import("zonvie_core");
const Harness = @import("../harness.zig").Harness;
const MsgShowEvent = @import("../harness.zig").MsgShowEvent;

// `echomsg` goes to the frontend-rendered `mini` view; everything else falls
// through to the catch-all, which `views.view` retargets to `split`.
var routes = [_]zc.config.MsgRoute{
    .{
        .filter = .{ .event = .msg_show, .kinds = &.{"echomsg"} },
        .view = .mini,
        .opts = .{ .timeout = 0 },
    },
};

const views: zc.config.ViewSettings = .{ .view = .split };

fn isMiniMarker(e: MsgShowEvent) bool {
    return e.view == @intFromEnum(zc.config.MsgViewType.mini) and
        std.mem.indexOf(u8, e.content, "mini marker") != null;
}

pub fn run(alloc: std.mem.Allocator) !void {
    var h = try Harness.init(alloc, .{
        .ext_messages = true,
        .msg_routes = &routes,
        .msg_views = views,
    });
    defer h.deinit();

    const start_windows = h.windowCount();
    const buffer_grid = h.winGrid();

    // 1. The frontend is handed a mini message. timeout = 0, so nothing but an
    //    explicit clear can legitimately take it down again.
    try h.command("echomsg 'mini marker'");
    h.waitMsgShow(isMiniMarker, h.opts.timeout_ms) catch |e| {
        h.dumpMsgShows();
        std.debug.print("[e2e] msg_mini_then_split: the mini message never reached the frontend\n", .{});
        return e;
    };

    // 2. Sampled only now: any clear that belongs to putting the mini window up
    //    has already been counted.
    const clears_before = h.msgClearCount();

    // 3. A split-routed message arrives and takes over the message UI.
    try h.command("echo 'split marker'");
    h.waitWindowCount(start_windows + 1, h.opts.timeout_ms) catch |e| {
        std.debug.print("[e2e] msg_mini_then_split: the split-routed message opened no window\n", .{});
        return e;
    };

    const ids = try h.positionedGridsAlloc(alloc);
    defer alloc.free(ids);
    var split_grid: i64 = 0;
    for (ids) |id| {
        if (id != buffer_grid and !h.isExternalGrid(id)) split_grid = id;
    }
    if (split_grid == 0) return error.SplitGridNotFound;

    // Ordered signal: the split's content is on screen, so the dispatch that
    // sent it — and everything the core does after the send — has run.
    try h.waitRowText(split_grid, 0, "split marker", h.opts.timeout_ms);

    // 4. End state a user expects: split up, old mini window told to go away.
    if (h.msgClearCount() <= clears_before) {
        std.debug.print(
            "[e2e] msg_mini_then_split: split shown but no on_msg_clear ({d} before, {d} after) " ++
                "— the frontend keeps drawing the stale mini window underneath\n",
            .{ clears_before, h.msgClearCount() },
        );
        return error.StaleMessageWindowNotCleared;
    }

    // 5. And the split really is the surviving window, not a second one
    //    stacked on top of a leftover.
    if (h.windowCount() != start_windows + 1) {
        std.debug.print(
            "[e2e] msg_mini_then_split: {d} windows, expected {d}\n",
            .{ h.windowCount(), start_windows + 1 },
        );
        return error.UnexpectedWindowCount;
    }
}
