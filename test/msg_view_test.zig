//! Tests for the message view lifecycle (`src/core/msg_view.zig`).
//!
//! The point of the abstraction is that one routing pass feeds every consumer,
//! and that show/hide is decided in one place rather than by four ad-hoc
//! `switch` arms. These pin both.

const std = @import("std");
const msg_view = @import("msg_view");

const ViewSet = msg_view.ViewSet;
const alloc = std.testing.allocator;

// -- assignment ---------------------------------------------------------------

test "beginCycle assigns every message to none" {
    var set: ViewSet = .{};
    defer set.deinit(alloc);

    try set.beginCycle(alloc, 3);
    for (0..3) |i| {
        try std.testing.expectEqual(msg_view.MsgViewType.none, set.assignedTo(i));
    }
}

test "assignment is readable by later consumers without re-routing" {
    var set: ViewSet = .{};
    defer set.deinit(alloc);

    try set.beginCycle(alloc, 4);
    set.assign(0, .ext_float, 4.0);
    set.assign(1, .split, 0);
    set.assign(2, .ext_float, 0);
    // index 3 stays `none`

    try std.testing.expectEqual(msg_view.MsgViewType.ext_float, set.assignedTo(0));
    try std.testing.expectEqual(msg_view.MsgViewType.split, set.assignedTo(1));
    try std.testing.expectEqual(msg_view.MsgViewType.ext_float, set.assignedTo(2));
    try std.testing.expectEqual(msg_view.MsgViewType.none, set.assignedTo(3));

    try std.testing.expectEqual(@as(u32, 2), set.state(.ext_float).count);
    try std.testing.expectEqual(@as(u32, 1), set.state(.split).count);
}

test "an out-of-range index is ignored rather than corrupting state" {
    var set: ViewSet = .{};
    defer set.deinit(alloc);

    try set.beginCycle(alloc, 1);
    set.assign(7, .split, 0);
    try std.testing.expectEqual(@as(u32, 0), set.state(.split).count);
    try std.testing.expectEqual(msg_view.MsgViewType.none, set.assignedTo(7));
}

test "a new cycle clears the previous assignment" {
    var set: ViewSet = .{};
    defer set.deinit(alloc);

    try set.beginCycle(alloc, 2);
    set.assign(0, .split, 2.0);
    try std.testing.expectEqual(@as(u32, 1), set.state(.split).count);

    try set.beginCycle(alloc, 2);
    try std.testing.expectEqual(@as(u32, 0), set.state(.split).count);
    try std.testing.expectEqual(@as(f32, 0), set.state(.split).timeout);
    try std.testing.expectEqual(msg_view.MsgViewType.none, set.assignedTo(0));
}

test "an empty cycle leaves no stale assignment" {
    var set: ViewSet = .{};
    defer set.deinit(alloc);

    try set.beginCycle(alloc, 2);
    set.assign(0, .ext_float, 0);
    try set.beginCycle(alloc, 0);

    try std.testing.expectEqual(msg_view.MsgViewType.none, set.assignedTo(0));
    try std.testing.expectEqual(@as(u32, 0), set.state(.ext_float).count);
}

test "the view timeout is the largest among its messages" {
    var set: ViewSet = .{};
    defer set.deinit(alloc);

    try set.beginCycle(alloc, 3);
    set.assign(0, .mini, 2.0);
    set.assign(1, .mini, 6.0);
    set.assign(2, .mini, 4.0);
    try std.testing.expectEqual(@as(f32, 6.0), set.state(.mini).timeout);
}

// -- display() ----------------------------------------------------------------

test "a view holding messages is shown" {
    var set: ViewSet = .{};
    defer set.deinit(alloc);

    try set.beginCycle(alloc, 1);
    set.assign(0, .ext_float, 0);
    try std.testing.expectEqual(msg_view.Action.show, set.action(.ext_float));
}

test "an empty core-owned view that is visible is hidden" {
    var set: ViewSet = .{};
    defer set.deinit(alloc);

    try set.beginCycle(alloc, 1);
    set.assign(0, .ext_float, 0);
    set.markShown(.ext_float);

    try set.beginCycle(alloc, 0);
    try std.testing.expectEqual(msg_view.Action.hide, set.action(.ext_float));
    set.markHidden(.ext_float);
    try std.testing.expectEqual(msg_view.Action.none, set.action(.ext_float));
}

test "an empty view that was never shown needs no action" {
    var set: ViewSet = .{};
    defer set.deinit(alloc);

    try set.beginCycle(alloc, 0);
    for (ViewSet.dispatch_order) |v| {
        try std.testing.expectEqual(msg_view.Action.none, set.action(v));
    }
}

test "handed-off views are never hidden by the core" {
    // Showing `split` transfers display ownership to Neovim, `mini` to the
    // frontend timer, `notification` to the OS. The core must not try to hide
    // them on the next empty cycle.
    var set: ViewSet = .{};
    defer set.deinit(alloc);

    for ([_]msg_view.MsgViewType{ .split, .mini, .notification, .confirm }) |v| {
        try set.beginCycle(alloc, 1);
        set.assign(0, v, 0);
        try std.testing.expectEqual(msg_view.Action.show, set.action(v));
        set.markShown(v);

        try set.beginCycle(alloc, 0);
        try std.testing.expectEqual(msg_view.Action.none, set.action(v));
    }
}

test "the none view is never dispatched" {
    var set: ViewSet = .{};
    defer set.deinit(alloc);

    try set.beginCycle(alloc, 1);
    set.assign(0, .none, 0);
    try std.testing.expectEqual(msg_view.Action.none, set.action(.none));
}

// -- retention ----------------------------------------------------------------

test "only the core-rendered view is retained" {
    try std.testing.expectEqual(msg_view.Retention.retained, msg_view.retentionOf(.ext_float));
    for ([_]msg_view.MsgViewType{ .mini, .confirm, .notification, .split, .none }) |v| {
        try std.testing.expectEqual(msg_view.Retention.transient, msg_view.retentionOf(v));
    }
}

test "unassigned messages are transient so they cannot accumulate" {
    // A message routed to `none`, or a return_prompt that was answered instead
    // of displayed, must be dropped rather than kept until the 1000-message cap.
    try std.testing.expectEqual(msg_view.Retention.transient, msg_view.retentionOf(.none));
}

// -- dispatch order -----------------------------------------------------------

test "both fallible views are dispatched before any handoff" {
    // The two views that can fail — ext_float (render) and split (assembly,
    // RPC send) — must both precede the callback-driven ones. A failure
    // aborts the flush and the retry re-dispatches the whole cycle, so a
    // frontend already handed a message via on_msg_show would receive it
    // twice; frontends do not dedupe (the Windows one discards msg_id).
    // Pinning only dispatch_order[0] left the split half unguarded, which is
    // the reordering the invariant exists to forbid.
    var pos: [msg_view.view_count]?usize = @splat(null);
    for (ViewSet.dispatch_order, 0..) |v, i| pos[@intFromEnum(v)] = i;

    const fallible = [_]msg_view.MsgViewType{ .ext_float, .split };
    const handoff = [_]msg_view.MsgViewType{ .mini, .confirm, .notification };
    for (fallible) |f| {
        const f_at = pos[@intFromEnum(f)] orelse return error.FallibleViewNotDispatched;
        for (handoff) |h| {
            const h_at = pos[@intFromEnum(h)] orelse return error.HandoffViewNotDispatched;
            try std.testing.expect(f_at < h_at);
        }
    }
}

test "dispatch order covers every displayable view exactly once" {
    var seen = [_]bool{false} ** msg_view.view_count;
    for (ViewSet.dispatch_order) |v| {
        const idx = @intFromEnum(v);
        try std.testing.expect(!seen[idx]);
        seen[idx] = true;
    }
    // Every view except `none`, which is not displayable.
    for (seen, 0..) |s, idx| {
        const v: msg_view.MsgViewType = @enumFromInt(idx);
        try std.testing.expectEqual(v != .none, s);
    }
}
