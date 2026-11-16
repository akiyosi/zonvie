//! Window lifecycle rules, free of any window system: what closing the main window does,
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

/// Where the session's nvim runs, as the start chose it.
pub const StartKind = enum { local, ssh, connect, devcontainer };

/// How long a start that keeps its window hidden until nvim's first frame
/// (--ssh, --connect-nvim) stays invisible before the window shows its
/// progress, so a host that never answers can still be closed.
pub const connect_reveal_ms = 5000;

/// The progress text a hidden start's window shows once revealed; null for
/// a start whose window is never hidden.
pub fn revealText(kind: StartKind) ?[:0]const u8 {
    return switch (kind) {
        .ssh => "Connecting over SSH...",
        .connect => "Connecting to Neovim...",
        .local, .devcontainer => null,
    };
}

/// The alert heading when nvim exits before its first frame: a remote start
/// that failed (ssh refused, devcontainer exec failed, server gone) says so,
/// as a failed `devcontainer up` does. Null for a local start, whose nvim
/// may end early on purpose (`zonvie -- --version`) and passes its code on.
pub fn earlyExitHeading(kind: StartKind) ?[:0]const u8 {
    return switch (kind) {
        .local => null,
        .ssh => "SSH connection failed",
        .connect => "Could not connect to Neovim",
        .devcontainer => "Devcontainer failed to start",
    };
}

/// The early exit's alert text: the tail of what the process printed on
/// stderr, else its exit code and a pointer to the log.
pub fn earlyExitDetail(buf: []u8, output: []const u8, exit_code: i32) [:0]const u8 {
    const tail = outputTail(output, 20, 800);
    const s = if (tail.len != 0)
        std.fmt.bufPrintZ(buf, "{s}", .{tail})
    else
        std.fmt.bufPrintZ(buf, "Neovim exited with code {d} before the session was ready. See the log for details.", .{exit_code});
    return s catch "Neovim exited before the session was ready.";
}

test "a remote start that ends early explains itself; a local one does not" {
    try std.testing.expect(earlyExitHeading(.local) == null);
    try std.testing.expectEqualStrings("SSH connection failed", earlyExitHeading(.ssh).?);
    try std.testing.expect(revealText(.devcontainer) == null);
    try std.testing.expect(revealText(.ssh) != null);
    var buf: [1024]u8 = undefined;
    try std.testing.expectEqualStrings("Permission denied (publickey).", earlyExitDetail(&buf, "Permission denied (publickey).\r\n", 255));
    try std.testing.expectEqualStrings("Neovim exited with code 255 before the session was ready. See the log for details.", earlyExitDetail(&buf, "", 255));
}

/// The last bytes a starting session's process wrote to stderr, for the
/// early-exit alert. Written by the core's stderr thread (on_log), read on
/// the main thread once nvim has exited; its own lock, since on_log may run
/// while the app lock is held elsewhere.
pub const StartOutput = struct {
    mu: std.Io.Mutex = .init,
    /// Cleared on nvim's first frame: later stderr is not about the start.
    open: std.atomic.Value(bool) = .init(false),
    buf: [4096]u8 = undefined,
    len: usize = 0,

    /// Keeps the last `buf.len` bytes. Lines the core itself emits through
    /// on_log without logging enabled (its run-loop markers) are not the
    /// process's output and are skipped.
    pub fn append(self: *StartOutput, io: std.Io, bytes: []const u8) void {
        if (!self.open.load(.acquire)) return;
        if (std.mem.startsWith(u8, bytes, "[RUNLOOP] ") or std.mem.startsWith(u8, bytes, "[DIRECT] ")) return;
        self.mu.lockUncancelable(io);
        defer self.mu.unlock(io);
        self.appendLocked(bytes);
    }

    fn appendLocked(self: *StartOutput, bytes: []const u8) void {
        const in = bytes[bytes.len - @min(bytes.len, self.buf.len) ..];
        const keep = @min(self.len, self.buf.len - in.len);
        std.mem.copyForwards(u8, self.buf[0..keep], self.buf[self.len - keep .. self.len]);
        @memcpy(self.buf[keep..][0..in.len], in);
        self.len = keep + in.len;
    }

    /// The captured bytes into `out`; the result is a slice of `out`.
    pub fn copy(self: *StartOutput, io: std.Io, out: []u8) []const u8 {
        self.mu.lockUncancelable(io);
        defer self.mu.unlock(io);
        const n = @min(self.len, out.len);
        @memcpy(out[0..n], self.buf[self.len - n .. self.len]);
        return out[0..n];
    }
};

test "the start output keeps the newest bytes" {
    var o: StartOutput = .{};
    o.open.store(true, .release);
    o.appendLocked("abc");
    o.appendLocked("def");
    try std.testing.expectEqualStrings("abcdef", o.buf[0..o.len]);
    var big: [5000]u8 = undefined;
    @memset(&big, 'x');
    big[big.len - 1] = 'y';
    o.appendLocked(&big);
    try std.testing.expectEqual(@as(usize, 4096), o.len);
    try std.testing.expectEqual(@as(u8, 'y'), o.buf[o.len - 1]);
    o.len = 0;
    o.appendLocked("12");
    o.appendLocked(big[0..4095]);
    try std.testing.expectEqual(@as(u8, '2'), o.buf[0]);
}

/// The session's name when the dialog gave none, as macOS names a session
/// from its connection: "SSH: <host>", "Devcontainer: <workspace folder>".
/// Empty for a local or --connect-nvim start, whose title stays nvim's.
/// The result is `buf`'s or `target`'s memory.
pub fn defaultSessionName(buf: []u8, kind: StartKind, target: []const u8) []const u8 {
    const prefix = switch (kind) {
        .ssh => "SSH",
        .devcontainer => "Devcontainer",
        .local, .connect => return "",
    };
    const shown = if (kind == .devcontainer) std.fs.path.basename(std.mem.trimEnd(u8, target, "/")) else target;
    if (shown.len == 0) return prefix;
    return std.fmt.bufPrint(buf, "{s}: {s}", .{ prefix, shown }) catch prefix;
}

test "a remote session without a name is named from its connection" {
    var buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings("SSH: me@box", defaultSessionName(&buf, .ssh, "me@box"));
    try std.testing.expectEqualStrings("Devcontainer: proj", defaultSessionName(&buf, .devcontainer, "/home/u/proj/"));
    try std.testing.expectEqualStrings("Devcontainer", defaultSessionName(&buf, .devcontainer, ""));
    try std.testing.expectEqualStrings("", defaultSessionName(&buf, .local, "x"));
    try std.testing.expectEqualStrings("", defaultSessionName(&buf, .connect, "/tmp/s"));
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
