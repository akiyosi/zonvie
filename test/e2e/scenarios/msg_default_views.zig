// msg_default_views — with NO user routes at all, the documented defaults
// must actually be what happens.
//
// README's [messages] section documents view = "ext-float",
// view_error = "ext-float", view_history = "split"; msg_route.zig's
// ViewSettings (src/core/msg_route.zig:152-158) and defaultRoutes
// (:186-211) are supposed to implement exactly that. Every existing
// msg_* scenario declares a user route, so the plain out-of-the-box path
// — the one almost every user gets — was untested.
//
// ext_float is core-rendered into grid -102, so it is observed as grid
// content plus external-grid registration, not through on_msg_show (which
// the core only fires for frontend-rendered views).

const std = @import("std");
const zc = @import("zonvie_core");
const Harness = @import("../harness.zig").Harness;

const msg_grid: i64 = -102;

/// True when some row of the message grid contains `needle`.
fn gridHas(h: *Harness, grid_id: i64, needle: []const u8) bool {
    var row: u32 = 0;
    while (row < 24) : (row += 1) {
        const text = h.rowTextAlloc(h.alloc, grid_id, row) catch continue;
        defer h.alloc.free(text);
        if (std.mem.indexOf(u8, text, needle) != null) return true;
    }
    return false;
}

fn waitGridHas(h: *Harness, grid_id: i64, comptime needle: []const u8) !void {
    const Ctx = struct { grid: i64 };
    try h.waitUntil(Ctx{ .grid = grid_id }, struct {
        fn check(c: Ctx, hh: *Harness) bool {
            return gridHas(hh, c.grid, needle);
        }
    }.check, h.opts.timeout_ms);
}

pub fn run(alloc: std.mem.Allocator) !void {
    // No msg_routes, no msg_views: pure built-in defaults.
    var h = try Harness.init(alloc, .{ .ext_messages = true });
    defer h.deinit();

    const start_windows = h.windowCount();

    // 1. An ordinary message reaches ext_float and is visible there.
    try h.command("echo 'plain hello'");
    waitGridHas(h, msg_grid, "plain hello") catch |e| {
        std.debug.print("[e2e] msg_default_views: :echo never reached the ext_float grid\n", .{});
        return e;
    };
    if (!h.isExternalGrid(msg_grid)) {
        std.debug.print("[e2e] msg_default_views: message grid not registered as external\n", .{});
        return error.MsgGridNotExternal;
    }
    // Ordinary messages get the transient view default (4s), so the
    // auto-hide deadline must be armed.
    if (!h.msgAutoHideArmed()) {
        std.debug.print("[e2e] msg_default_views: no auto-hide armed for an ordinary message\n", .{});
        return error.OrdinaryMessageNotAutoHidden;
    }

    // 2. An error routes per view_error (ext-float) and never auto-hides.
    //
    // Typed at the cmdline, not via `h.command`: `nvim_command` is an RPC
    // *request* (nvim_core.zig:4704-4716), so a failing ex command comes back
    // as an RPC error response and never becomes an `emsg` msg_show at all.
    // The user-visible error path is the one being tested.
    try h.input(":echoerr 'boom marker'<CR>");
    waitGridHas(h, msg_grid, "boom marker") catch |e| {
        std.debug.print("[e2e] msg_default_views: :echoerr never reached the ext_float grid\n", .{});
        return e;
    };
    if (h.msgAutoHideArmed()) {
        std.debug.print("[e2e] msg_default_views: an error message armed auto-hide (should be timeout=0)\n", .{});
        return error.ErrorMessageAutoHidden;
    }

    // 3. History routes per view_history (split): a real Neovim window.
    try h.command("messages");
    h.waitWindowCount(start_windows + 1, h.opts.timeout_ms) catch |e| {
        std.debug.print("[e2e] msg_default_views: :messages did not open a split\n", .{});
        return e;
    };
}
