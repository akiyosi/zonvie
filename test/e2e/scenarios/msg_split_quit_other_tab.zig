// msg_split_quit_other_tab — quitting a different tabpage must not take the
// split with it.
//
// The QuitPre handler closes the split when it would otherwise be the last
// window keeping Neovim alive. The window count used to come from
// `nvim_tabpage_list_wins(0)` — the QUITTING tabpage: in a freshly opened tab
// holding a single window that count saw exactly one "other" real window and
// the `others <= 1` test fired, closing a split that lives in a completely
// different tabpage and was never at risk.
//
// The count is now taken over the SPLIT's own tabpage, and a tabpage guard
// stops a `:q` elsewhere from acting on it (nvim_core.zig, buildSplitLua
// QuitPre callback). The one case that deliberately ignores that guard is a
// split alone in its tabpage, which can never be what the user wants to keep.
// This scenario pins the under-block direction: with the split in tab 1
// alongside a real window, `:q` in tab 2 must close tab 2 and leave the split
// standing. msg_split_quit.zig pins the opposite direction — that the guard
// does not over-block a same-tabpage `:q`.

const std = @import("std");
const zc = @import("zonvie_core");
const Harness = @import("../harness.zig").Harness;

var routes = [_]zc.config.MsgRoute{
    .{ .filter = .{ .event = .msg_show }, .view = .split, .opts = .{ .timeout = 0 } },
};

pub fn run(alloc: std.mem.Allocator) !void {
    var h = try Harness.init(alloc, .{ .ext_messages = true, .msg_routes = &routes });
    defer h.deinit();

    const start_windows = h.windowCount();

    try h.command("echo 'tab one message'");
    try h.waitWindowCount(start_windows + 1, h.opts.timeout_ms);

    // A second tabpage with exactly one window: the shape that made the
    // per-tabpage count reach `others == 1`. Windows of tab 1 are hidden
    // (win_hide), so only tab 2's single window is positioned.
    try h.command("tabnew");
    try h.waitWindowCount(1, h.opts.timeout_ms);

    // Closing tab 2 returns to tab 1. Both windows there must come back;
    // if QuitPre closed the split, only the editor window returns and this
    // wait times out.
    try h.command("q");
    h.waitWindowCount(start_windows + 1, h.opts.timeout_ms) catch |e| switch (e) {
        error.Timeout => {
            std.debug.print(
                "[e2e] msg_split_quit_other_tab: {d} window(s) after quitting tab 2, expected {d}\n",
                .{ h.windowCount(), start_windows + 1 },
            );
            return error.SplitClosedByOtherTabQuit;
        },
        // NvimExited would mean `:q` in tab 2 quit the whole editor.
        else => return e,
    };
}
