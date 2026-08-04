// msg_ext_float_timeout — the ext_float auto-hide must fire when a timeout is
// set, and must never fire when it is 0. Both directions.
//
// This is the view that ordinary `:echo` output lands in by default
// (msg_route.zig:152-158), and its whole point is that it goes away on its
// own. The deadline is armed in showChannelView (flush.zig:8942) and expired
// in checkMsgAutoHideTimeout (flush.zig:8487), which only runs from the
// frontend's one-shot msg timer while Neovim is idle — so the scenario drives
// that timer itself (Harness.tickMsgThrottle mirrors
// zonvie_core_tick_msg_throttle).
//
// Ordered signals, not bare equality waits:
//   * appearance is a rising edge (grid content becomes visible),
//   * disappearance is a falling edge (the external grid registration goes
//     away) observed only AFTER the appearance was observed, so it cannot
//     pass on a state that predates the show,
//   * "does not disappear" is a hold across many ticks past the deadline the
//     buggy version would have armed — a never-true wait whose Timeout is
//     the success case.

const std = @import("std");
const zc = @import("zonvie_core");
const Harness = @import("../harness.zig").Harness;

const msg_grid: i64 = -102;

// Errors keep the built-in `timeout = 0`; everything else auto-hides fast so
// the scenario stays quick. 0.8s is far longer than the 20ms tick interval,
// so the "shown" state is always observable before it expires.
var routes = [_]zc.config.MsgRoute{
    .{ .filter = .{ .event = .msg_show, .level = .err }, .view = .ext_float, .opts = .{ .timeout = 0 } },
    .{ .filter = .{ .event = .msg_show }, .view = .ext_float, .opts = .{ .timeout = 0.8 } },
};

fn gridHas(h: *Harness, needle: []const u8) bool {
    var row: u32 = 0;
    while (row < 24) : (row += 1) {
        const text = h.rowTextAlloc(h.alloc, msg_grid, row) catch continue;
        defer h.alloc.free(text);
        if (std.mem.indexOf(u8, text, needle) != null) return true;
    }
    return false;
}

pub fn run(alloc: std.mem.Allocator) !void {
    var h = try Harness.init(alloc, .{ .ext_messages = true, .msg_routes = &routes });
    defer h.deinit();

    // ── Direction 1: a timeout actually hides the message ──────────────
    try h.command("echo 'vanishing marker'");
    try h.waitUntil({}, struct {
        fn check(_: void, hh: *Harness) bool {
            return gridHas(hh, "vanishing marker") and hh.isExternalGrid(msg_grid);
        }
    }.check, h.opts.timeout_ms);

    if (!h.msgAutoHideArmed()) {
        std.debug.print("[e2e] msg_ext_float_timeout: timeout=0.8 armed no deadline\n", .{});
        return error.TimeoutNotArmed;
    }

    // Falling edge, observed strictly after the rising edge above.
    h.waitTicking(struct {
        fn check(hh: *Harness) bool {
            return !hh.isExternalGrid(msg_grid);
        }
    }.check, 4000) catch |e| {
        std.debug.print("[e2e] msg_ext_float_timeout: message never auto-hid\n", .{});
        return e;
    };
    if (h.msgAutoHideArmed()) {
        std.debug.print("[e2e] msg_ext_float_timeout: deadline still armed after the hide\n", .{});
        return error.DeadlineNotCleared;
    }
    if (h.pendingMessageCount() != 0) {
        std.debug.print(
            "[e2e] msg_ext_float_timeout: {d} message(s) survived the auto-hide\n",
            .{h.pendingMessageCount()},
        );
        return error.MessagesSurvivedAutoHide;
    }

    // ── Direction 2: timeout = 0 keeps the message up ──────────────────
    // Typed, not `nvim_command`: that is an RPC request, so a failing ex
    // command returns an error response instead of emitting an `emsg`
    // msg_show (nvim_core.zig:4704-4716).
    try h.input(":echoerr 'sticky marker'<CR>");
    try h.waitUntil({}, struct {
        fn check(_: void, hh: *Harness) bool {
            return gridHas(hh, "sticky marker") and hh.isExternalGrid(msg_grid);
        }
    }.check, h.opts.timeout_ms);

    if (h.msgAutoHideArmed()) {
        std.debug.print("[e2e] msg_ext_float_timeout: timeout=0 still armed a deadline\n", .{});
        return error.ZeroTimeoutArmed;
    }

    // Hold across ~2.5s of ticks — three times the 0.8s the other route
    // uses, so a wrongly-armed deadline could not survive it.
    h.waitTicking(struct {
        fn check(hh: *Harness) bool {
            return !hh.isExternalGrid(msg_grid);
        }
    }.check, 2500) catch |e| switch (e) {
        error.Timeout => {}, // success: it never went away
        else => return e,
    };
    if (!h.isExternalGrid(msg_grid) or !gridHas(h, "sticky marker")) {
        std.debug.print("[e2e] msg_ext_float_timeout: timeout=0 message disappeared anyway\n", .{});
        return error.ZeroTimeoutMessageHidden;
    }
}
