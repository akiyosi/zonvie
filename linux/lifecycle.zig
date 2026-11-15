//! Window lifecycle rules, free of GTK: what closing the main window does,
//! the quit timeout ("Neovim Not Responding", as macOS's requestQuit and
//! Windows' WM_CLOSE / TIMER_QUIT_TIMEOUT), the failure text of a
//! `devcontainer up`, and the window title a named session carries.

const std = @import("std");

/// How long nvim has to answer a quit request before the user is offered
/// Force Quit (macOS quitTimeoutSeconds, Windows QUIT_TIMEOUT_MS).
pub const quit_timeout_ms = 5000;

/// What stands behind the main window when it is asked to close.
pub const Session = enum {
    /// No nvim and none coming: no core, a failed start, or nvim exited.
    none,
    /// `devcontainer up` runs; the core has not been started yet.
    building,
    /// The core was started; nvim (perhaps not attached yet) answers quits.
    running,
};

pub const Quit = struct {
    phase: Phase = .idle,

    pub const Phase = enum {
        idle,
        /// A quit request is out and its timeout armed.
        pending,
        /// The timeout fired before nvim answered; a late answer is stale.
        timed_out,
    };

    pub const Close = enum {
        /// Let the window close.
        close,
        /// Abandon the pending start (`devcontainer up`) and close.
        cancel_start,
        /// Ask the core (zonvie_core_request_quit) and arm the timeout.
        request_quit,
        /// A request is already pending: neither resend it nor rearm.
        ignore,
    };

    /// A close request for the main window.
    /// Post: `.request_quit` leaves the phase `pending`; the others leave it
    /// as it was.
    pub fn close(self: *Quit, session: Session) Close {
        return switch (session) {
            .none => .close,
            .building => .cancel_start,
            .running => switch (self.phase) {
                .pending => .ignore,
                // A second close after "Wait" asks again, with a new timeout.
                .idle, .timed_out => blk: {
                    self.phase = .pending;
                    break :blk .request_quit;
                },
            },
        };
    }

    /// The core's on_quit_requested arrived. Returns whether to act on it
    /// (quit, or ask about unsaved buffers); the caller cancels the timeout.
    /// An answer after the timeout fired is dropped, as on macOS and Windows:
    /// the user is looking at "Not Responding" and chooses there.
    pub fn reply(self: *Quit) bool {
        if (self.phase == .timed_out) return false;
        self.phase = .idle;
        return true;
    }

    /// The quit timeout fired. Returns whether to show "Not Responding".
    pub fn timeout(self: *Quit) bool {
        if (self.phase != .pending) return false;
        self.phase = .timed_out;
        return true;
    }
};

test "a close while a quit is pending is ignored, and asks again after the timeout" {
    var q: Quit = .{};
    try std.testing.expectEqual(Quit.Close.request_quit, q.close(.running));
    try std.testing.expectEqual(Quit.Close.ignore, q.close(.running));
    try std.testing.expect(q.timeout());
    try std.testing.expect(!q.timeout());
    // "Wait", then close again.
    try std.testing.expectEqual(Quit.Close.request_quit, q.close(.running));
    try std.testing.expectEqual(Quit.Phase.pending, q.phase);
}

test "a timely answer cancels the timeout, a late one is dropped" {
    var q: Quit = .{};
    _ = q.close(.running);
    try std.testing.expect(q.reply());
    try std.testing.expect(!q.timeout());
    try std.testing.expectEqual(Quit.Close.request_quit, q.close(.running));
    try std.testing.expect(q.timeout());
    try std.testing.expect(!q.reply());
}

test "a window with no nvim behind it closes; a build in flight is cancelled" {
    var q: Quit = .{};
    try std.testing.expectEqual(Quit.Close.close, q.close(.none));
    try std.testing.expectEqual(Quit.Close.cancel_start, q.close(.building));
    try std.testing.expectEqual(Quit.Phase.idle, q.phase);
}

/// The last `max_lines` lines of `out`, at most `max_bytes` of them (cut at
/// a UTF-8 boundary), without trailing blank lines: what a failed
/// `devcontainer up` shows (macOS: 20 lines, 800 characters).
/// Post: the result is a slice of `out`.
pub fn outputTail(out: []const u8, max_lines: usize, max_bytes: usize) []const u8 {
    const trimmed = std.mem.trimEnd(u8, out, " \t\r\n");
    var start = trimmed.len;
    var lines: usize = 0;
    while (start > 0) {
        const nl = std.mem.lastIndexOfScalar(u8, trimmed[0..start], '\n') orelse {
            start = 0;
            break;
        };
        lines += 1;
        if (lines == max_lines) {
            start = nl + 1;
            break;
        }
        start = nl;
    }
    var tail = trimmed[start..];
    if (tail.len > max_bytes) {
        var cut = tail.len - max_bytes;
        while (cut < tail.len and (tail[cut] & 0xc0) == 0x80) cut += 1;
        tail = tail[cut..];
    }
    return tail;
}

test "the output tail keeps the last lines and bytes" {
    try std.testing.expectEqualStrings("c\nd", outputTail("a\nb\nc\nd\n\n", 2, 100));
    try std.testing.expectEqualStrings("a\nb", outputTail("a\nb", 5, 100));
    try std.testing.expectEqualStrings("", outputTail("\n\n", 5, 100));
    try std.testing.expectEqualStrings("yz", outputTail("wxyz", 5, 2));
    // Never starts inside a multi-byte character.
    try std.testing.expectEqualStrings("b", outputTail("\xc3\xa9b", 5, 2));
}

/// The window title: nvim's, followed by the session's name when the
/// connection dialog gave one, so windows of several sessions tell apart.
/// `buf` must hold at least one byte; the result is truncated to fit.
pub fn sessionTitle(buf: []u8, title: []const u8, name: []const u8) [:0]const u8 {
    std.debug.assert(buf.len > 0);
    const shown = if (title.len == 0) "zonvie" else title;
    const s = if (name.len == 0)
        std.fmt.bufPrint(buf[0 .. buf.len - 1], "{s}", .{shown})
    else
        std.fmt.bufPrint(buf[0 .. buf.len - 1], "{s} ({s})", .{ shown, name });
    const n = (s catch buf[0 .. buf.len - 1]).len;
    buf[n] = 0;
    return buf[0..n :0];
}

test "a named session carries its name in the title" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("a.txt - NVIM", sessionTitle(&buf, "a.txt - NVIM", ""));
    try std.testing.expectEqualStrings("a.txt (work)", sessionTitle(&buf, "a.txt", "work"));
    try std.testing.expectEqualStrings("zonvie (work)", sessionTitle(&buf, "", "work"));
    var small: [4]u8 = undefined;
    try std.testing.expectEqualStrings("abc", sessionTitle(&small, "abcdef", ""));
}

/// GdkToplevelState bits that mean nothing of the window can be seen.
pub const toplevel_minimized: c_uint = 1 << 0;
/// GTK 4.12: the compositor stopped showing the window (occluded).
pub const toplevel_suspended: c_uint = 1 << 16;

/// Whether a toplevel in `state` cannot be seen, so its cursor need not blink.
pub fn toplevelHidden(state: c_uint) bool {
    return state & (toplevel_minimized | toplevel_suspended) != 0;
}

test "minimized or suspended toplevels are hidden" {
    try std.testing.expect(toplevelHidden(toplevel_minimized));
    try std.testing.expect(toplevelHidden(toplevel_suspended | (1 << 6)));
    try std.testing.expect(!toplevelHidden(1 << 1));
}
