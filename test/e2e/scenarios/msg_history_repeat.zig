// msg_history_repeat — `:messages` must keep working after it has been
// dismissed, over and over, showing every entry exactly once each time.
//
// `hideMsgHistory` (flush.zig:9928-9941) now also resets the history retry
// deadline and its backoff. That reset is load-bearing in a way no single-shot
// test can see: `notifyMessageChanges`'s history arm (flush.zig:8729-8743) only
// dispatches when `msg_history_retry_at` is null or already due, so a deadline
// left behind by an earlier cycle silently swallows the NEXT `:messages` — the
// user presses the same key and nothing happens. msg_history_content and
// msg_history_split both show the history exactly once and would pass with the
// deadline permanently stranded.
//
// The re-assembly path is exercised too: the split buffer is a persistent Core
// field reused across shows (flush.zig:8995-8996), so a missing
// `clearRetainingCapacity` on a later show duplicates every earlier entry.
// Checking "exactly once" on round 3 is what catches that; a length check or a
// "some history text is on screen" check would not.
//
// A final phase pins the OTHER repeat shape: `:messages` again while the
// split is still open. The history channel's default is enter=true, and
// enter applies on every show — so the re-show must move the cursor back
// into the live split, not just re-render it. That is a deliberate behavior
// change from the mount-only era and this is the only place that pins it
// for the default (no user routes) configuration.
//
// Ordering discipline: every assertion follows an ordered signal. Appearance is
// a rising window-count edge plus the cursor landing on the split's own grid
// (`:messages` enters by channel default — the split arm of showChannelView
// resolves `state.enter orelse (ch == .history)`); dismissal is a falling
// edge observed strictly after the cursor was there; a round's `echomsg` is
// only considered delivered once its text is visible in the ext_float grid.

const std = @import("std");
const zc = @import("zonvie_core");
const Harness = @import("../harness.zig").Harness;

const msg_grid: i64 = -102;
const rounds = 3;

const NeedleCtx = struct { needle: []const u8 };

fn floatHas(h: *Harness, needle: []const u8) bool {
    var row: u32 = 0;
    while (row < 24) : (row += 1) {
        const text = h.rowTextAlloc(h.alloc, msg_grid, row) catch continue;
        defer h.alloc.free(text);
        if (std.mem.indexOf(u8, text, needle) != null) return true;
    }
    return false;
}

fn waitFloatHas(h: *Harness, needle: []const u8) !void {
    try h.waitUntil(NeedleCtx{ .needle = needle }, struct {
        fn check(c: NeedleCtx, hh: *Harness) bool {
            return floatHas(hh, c.needle);
        }
    }.check, h.opts.timeout_ms);
}

/// The split's grid: the positioned, non-external grid that is not the
/// editor's own.
fn findSplitGrid(h: *Harness, alloc: std.mem.Allocator, buffer_grid: i64) !i64 {
    const ids = try h.positionedGridsAlloc(alloc);
    defer alloc.free(ids);
    for (ids) |id| {
        if (id != buffer_grid and !h.isExternalGrid(id)) return id;
    }
    return error.SplitGridNotFound;
}

pub fn run(alloc: std.mem.Allocator) !void {
    // Built-in defaults: view_history is `split` (msg_route.zig:155), ordinary
    // messages go to ext_float (:152). No user routes — this is the
    // out-of-the-box `:messages` a user gets.
    var h = try Harness.init(alloc, .{ .ext_messages = true });
    defer h.deinit();

    const start_windows = h.windowCount();
    const buffer_grid = h.winGrid();

    var round: usize = 0;
    while (round < rounds) : (round += 1) {
        var marker_buf: [32]u8 = undefined;
        const marker = try std.fmt.bufPrint(&marker_buf, "hist-round-{d}-end", .{round});

        var cmd_buf: [64]u8 = undefined;
        const cmd = try std.fmt.bufPrint(&cmd_buf, "echomsg '{s}'", .{marker});
        try h.command(cmd);

        // Ordered signal: this round's message has been routed and rendered,
        // so Neovim's own :messages history certainly contains it.
        waitFloatHas(h, marker) catch |e| {
            std.debug.print(
                "[e2e] msg_history_repeat: round {d} echomsg never reached the ext_float grid\n",
                .{round},
            );
            return e;
        };

        try h.command("messages");
        h.waitWindowCount(start_windows + 1, h.opts.timeout_ms) catch |e| {
            std.debug.print(
                "[e2e] msg_history_repeat: :messages opened no split on round {d} " ++
                    "(a stranded history retry deadline swallows the dispatch)\n",
                .{round},
            );
            return e;
        };

        const split_grid = try findSplitGrid(h, alloc, buffer_grid);
        // `:messages` enters its split, so the cursor landing there is proof
        // the whole mount batch has been applied — the content is final.
        try h.waitCursorGrid(split_grid, h.opts.timeout_ms);

        const content = try h.splitContentAlloc(alloc);
        defer alloc.free(content);

        // Every marker echoed so far, present exactly once, in order.
        var search_from: usize = 0;
        var i: usize = 0;
        while (i <= round) : (i += 1) {
            var needle_buf: [32]u8 = undefined;
            const needle = try std.fmt.bufPrint(&needle_buf, "hist-round-{d}-end", .{i});

            const at = std.mem.indexOfPos(u8, content, search_from, needle) orelse {
                std.debug.print(
                    "[e2e] msg_history_repeat: round {d} is missing entry {d} " ++
                        "({d} bytes of assembled history)\n",
                    .{ round, i, content.len },
                );
                return error.HistoryEntryMissingOnRepeat;
            };

            const first = std.mem.indexOf(u8, content, needle).?;
            if (std.mem.indexOfPos(u8, content, first + needle.len, needle) != null) {
                std.debug.print(
                    "[e2e] msg_history_repeat: round {d} shows entry {d} more than once " ++
                        "(split buffer not reset between shows)\n",
                    .{ round, i },
                );
                return error.HistoryEntryDuplicatedOnRepeat;
            }
            search_from = at + needle.len;
        }

        // Dismiss the way a user does, and observe the falling edge before the
        // next round asks for the split again.
        try h.input("q");
        h.waitWindowCount(start_windows, h.opts.timeout_ms) catch |e| {
            std.debug.print(
                "[e2e] msg_history_repeat: round {d} split did not close on 'q'\n",
                .{round},
            );
            return e;
        };
        try h.waitCursorGrid(buffer_grid, h.opts.timeout_ms);
    }

    // Final phase: `:messages` again while the split is STILL OPEN. The
    // channel default is enter=true, and enter applies on every show, so the
    // re-show into the live window must take the cursor back — the mount-only
    // era left it where it was, and no other scenario pins the default here.
    try h.command("messages");
    try h.waitWindowCount(start_windows + 1, h.opts.timeout_ms);
    const split_grid = try findSplitGrid(h, alloc, buffer_grid);
    try h.waitCursorGrid(split_grid, h.opts.timeout_ms);

    try h.command("wincmd p");
    try h.waitCursorGrid(buffer_grid, h.opts.timeout_ms);

    try h.command("echomsg 'reshow-marker-end'");
    // Ordered signal: the new entry visible in the ext_float grid proves it
    // entered history before the re-show is requested.
    try h.waitUntil(NeedleCtx{ .needle = "reshow-marker-end" }, struct {
        fn check(c: NeedleCtx, hh: *Harness) bool {
            return floatHas(hh, c.needle);
        }
    }.check, h.opts.timeout_ms);

    try h.command("messages");
    // The window count does not change — same live split. The content
    // updating to include the new entry proves the re-show was assembled and
    // queued (msg_split_buf is only rebuilt by the split arm), which is
    // enough ordering here because the cursor check below is itself a
    // bounded wait, not a one-shot assert. The cursor landing back inside is
    // the behavior under test.
    try h.waitUntil(NeedleCtx{ .needle = "reshow-marker-end" }, struct {
        fn check(c: NeedleCtx, hh: *Harness) bool {
            const text = hh.splitContentAlloc(hh.alloc) catch return false;
            defer hh.alloc.free(text);
            return std.mem.indexOf(u8, text, c.needle) != null;
        }
    }.check, h.opts.timeout_ms);
    h.waitCursorGrid(split_grid, h.opts.timeout_ms) catch |e| {
        std.debug.print(
            "[e2e] msg_history_repeat: re-show into the live split did not move the cursor " ++
                "(default :messages must enter on every show)\n",
            .{},
        );
        return e;
    };
}
