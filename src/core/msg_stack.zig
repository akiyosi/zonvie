//! How one msg_show changes the stack of messages a frontend shows together.
//!
//! Both frontends kept the stack themselves and both read `replace_last` as
//! "clear everything": Neovim's UI spec says it replaces only the message the
//! previous msg_show put up, and every other visible message stays.

const std = @import("std");

/// Messages shown together at most; the oldest goes first.
pub const max_messages: usize = 5;

pub const Action = enum(c_int) {
    /// Add the message at the end.
    push = 0,
    /// Put the message in place of the last one.
    replace_last = 1,
    /// Append the message's text to the last one.
    append_to_last = 2,
};

pub const Plan = struct {
    action: Action,
    /// Messages to drop from the front after the action.
    evict_oldest: usize,
};

pub fn plan(stack_len: usize, replace_last: bool, append: bool) Plan {
    if (stack_len > 0 and replace_last) return .{ .action = .replace_last, .evict_oldest = 0 };
    if (stack_len > 0 and append) return .{ .action = .append_to_last, .evict_oldest = 0 };
    const len = stack_len + 1;
    return .{ .action = .push, .evict_oldest = if (len > max_messages) len - max_messages else 0 };
}

test "replace_last replaces only the last message and keeps the rest" {
    try std.testing.expectEqual(Plan{ .action = .replace_last, .evict_oldest = 0 }, plan(3, true, false));
}

test "replace_last on an empty stack pushes" {
    try std.testing.expectEqual(Plan{ .action = .push, .evict_oldest = 0 }, plan(0, true, false));
}

test "append extends the last message, and pushes when there is none" {
    try std.testing.expectEqual(Plan{ .action = .append_to_last, .evict_oldest = 0 }, plan(2, false, true));
    try std.testing.expectEqual(Plan{ .action = .push, .evict_oldest = 0 }, plan(0, false, true));
}

test "a push past the cap drops the oldest" {
    try std.testing.expectEqual(Plan{ .action = .push, .evict_oldest = 0 }, plan(4, false, false));
    try std.testing.expectEqual(Plan{ .action = .push, .evict_oldest = 1 }, plan(5, false, false));
}
