// msg_history_split — `:messages` must reach the split view, whole.
//
// Two defects met here. `msg_history_show` used to be dropped entirely when a
// user declared any unrelated route, and the split content was assembled into
// a fixed 8 KiB stack buffer, so a long history was silently clipped.

const std = @import("std");
const zc = @import("zonvie_core");
const Harness = @import("../harness.zig").Harness;

// One unrelated user route. History must still reach its default view.
var routes = [_]zc.config.MsgRoute{
    .{ .filter = .{ .event = .msg_show }, .view = .mini },
};

pub fn run(alloc: std.mem.Allocator) !void {
    var h = try Harness.init(alloc, .{ .ext_messages = true, .msg_routes = &routes });
    defer h.deinit();

    const start_windows = h.windowCount();
    const editor_grid = h.winGrid();

    // Build a history well past the old 8 KiB assembly limit. Sized for the
    // strictest supported nvim: versions before 0.11 cap message history at
    // 200 entries (0.11+ defaults to 500 via 'messagesopt'), so use 180 lines
    // of ~68 bytes ≈ 12 KiB — comfortably over 8 KiB under either cap, and a
    // truncating implementation must clip it.
    try h.command("for i in range(180) | echomsg 'history line ' .. i .. ' ' .. repeat('-', 50) | endfor");

    try h.command("messages");
    try h.waitWindowCount(start_windows + 1, h.opts.timeout_ms);

    // `:messages` is content the user asked to read, so unlike a routed
    // msg_show the split takes focus (noice makes the same distinction:
    // config/views.lua:91-94 `enter = true` vs :75 `enter = false`).
    const Focus = struct { editor: i64 };
    h.waitUntil(Focus{ .editor = editor_grid }, struct {
        fn check(c: Focus, hh: *Harness) bool {
            return hh.winGrid() != c.editor;
        }
    }.check, h.opts.timeout_ms) catch {
        std.debug.print("[e2e] msg_history_split: :messages split did not take focus\n", .{});
        return error.HistorySplitNotFocused;
    };

    // Whether the content was clipped is a property of the assembled buffer,
    // not of what happens to be scrolled into view: the split opens at line 1,
    // so the visible rows are the START of the history either way.
    const assembled = h.splitContentLen();
    if (assembled <= 8192) {
        std.debug.print(
            "[e2e] msg_history_split: assembled only {d} bytes; the old fixed 8 KiB buffer would clip here\n",
            .{assembled},
        );
        return error.HistoryContentClipped;
    }

    // And it really is the history that got rendered. The split holds the
    // cursor now, so it is the grid the editor window is NOT on.
    const split_grid = h.winGrid();
    if (split_grid == editor_grid) return error.SplitGridNotFound;

    const Ctx = struct { grid: i64 };
    h.waitUntil(Ctx{ .grid = split_grid }, struct {
        fn check(c: Ctx, hh: *Harness) bool {
            var row: u32 = 0;
            while (row < 20) : (row += 1) {
                const text = hh.rowTextAlloc(hh.alloc, c.grid, row) catch continue;
                defer hh.alloc.free(text);
                if (std.mem.indexOf(u8, text, "history line ") != null) return true;
            }
            return false;
        }
    }.check, h.opts.timeout_ms) catch |e| {
        std.debug.print("[e2e] msg_history_split: no history content visible in the split\n", .{});
        return e;
    };
}
