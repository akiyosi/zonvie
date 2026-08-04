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
// Ordering discipline: every assertion follows an ordered signal. Appearance is
// a rising window-count edge plus the cursor landing on the split's own grid
// (`:messages` mounts with enter=true, flush.zig:9047); dismissal is a falling
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
}
