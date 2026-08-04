// msg_backoff_delivery — a message that arrives while a retry backoff is
// pending must still be displayed, and must clear the backoff behind it.
//
// `notifyMessageChanges`'s immediate branch now REFUSES to attempt a dispatch
// while `msg_show_retry_at` is in the future (flush.zig:8683-8686): it re-arms
// `msg_dirty` and returns, leaving delivery entirely to the frontend's one-shot
// timer built from `nextMsgTimeoutNs`. Any failure arms that deadline and
// doubles the backoff 16ms → 1000ms (flush.zig:8446-8451), so the state this
// scenario reproduces is what an ordinary `:echo` runs into right after ANY
// earlier message failure — including a failure that had nothing to do with
// this message.
//
// Two things can go wrong and neither is visible to a unit test: the deferred
// dispatch may never be re-driven (the message is not late, it is LOST), or the
// deadline may survive the successful dispatch and tax every message after it.
// Both are asserted here.
//
// The backoff is injected rather than provoked — the failures that arm it
// (allocator exhaustion, a full RPC write queue) cannot be produced from a
// scenario, and the branch under test reads exactly the fields injected.
//
// Ordering: delivery is observed as text appearing in the message grid while
// the frontend timer tick is driven (`waitTicking`, the same entry point
// `zonvie_core_tick_msg_throttle` gives the real frontends). Nothing is
// asserted from a bare equality wait, and the retry-state check is made only
// after the text was actually seen.

const std = @import("std");
const zc = @import("zonvie_core");
const Harness = @import("../harness.zig").Harness;

const msg_grid: i64 = -102;

/// Long enough that the message cannot plausibly have been dispatched by the
/// pre-existing flush that was already in flight, short enough to stay well
/// inside the wait budget.
const backoff_ms = 400;

fn gridHas(h: *Harness, needle: []const u8) bool {
    var row: u32 = 0;
    while (row < 24) : (row += 1) {
        const text = h.rowTextAlloc(h.alloc, msg_grid, row) catch continue;
        defer h.alloc.free(text);
        if (std.mem.indexOf(u8, text, needle) != null) return true;
    }
    return false;
}

fn hasBaseline(h: *Harness) bool {
    return gridHas(h, "baseline marker");
}

fn hasDelayed(h: *Harness) bool {
    return gridHas(h, "delayed marker");
}

pub fn run(alloc: std.mem.Allocator) !void {
    // Built-in defaults: ordinary messages go to ext_float, so delivery is
    // observable as grid content rather than through a callback.
    var h = try Harness.init(alloc, .{ .ext_messages = true });
    defer h.deinit();

    // 1. The uncontended path works, and leaves no deadline behind. This is the
    //    control: if it were slow or broken, step 3 would prove nothing.
    try h.command("echo 'baseline marker'");
    h.waitTicking(hasBaseline, h.opts.timeout_ms) catch |e| {
        std.debug.print("[e2e] msg_backoff_delivery: an ordinary message never displayed\n", .{});
        return e;
    };
    if (h.msgShowRetryArmed()) {
        std.debug.print(
            "[e2e] msg_backoff_delivery: an ordinary message left a retry deadline armed — " ++
                "every later message pays the backoff\n",
            .{},
        );
        return error.RetryDeadlineAfterSuccess;
    }

    // 2. Reproduce the post-failure state, then send a perfectly ordinary
    //    message into it.
    h.armMsgShowBackoff(backoff_ms);
    try h.command("echo 'delayed marker'");

    // 3. It must still arrive. `waitTicking` drives exactly the timer the real
    //    frontends arm from nextMsgTimeoutNs — if the deferred dispatch has no
    //    driver, this is where the message is lost.
    h.waitTicking(hasDelayed, h.opts.timeout_ms) catch |e| {
        std.debug.print(
            "[e2e] msg_backoff_delivery: a message that arrived during a {d}ms backoff was " ++
                "never displayed\n",
            .{backoff_ms},
        );
        return e;
    };

    // 4. And the deadline is consumed, not stranded: the NEXT message must not
    //    inherit it. Checked only now that delivery was observed.
    if (h.msgShowRetryArmed()) {
        std.debug.print(
            "[e2e] msg_backoff_delivery: the retry deadline survived a successful dispatch\n",
            .{},
        );
        return error.RetryDeadlineStranded;
    }

    // 5. A following message displays normally — no residual penalty.
    try h.command("echo 'baseline marker two'");
    h.waitTicking(struct {
        fn check(hh: *Harness) bool {
            return gridHas(hh, "baseline marker two");
        }
    }.check, h.opts.timeout_ms) catch |e| {
        std.debug.print(
            "[e2e] msg_backoff_delivery: the message after a backoff never displayed\n",
            .{},
        );
        return e;
    };
}
