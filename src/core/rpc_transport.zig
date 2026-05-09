// rpc_transport.zig — RPC transport layer for nvim sessions.
//
// Two transports are supported:
//   - Spawn: a child nvim process attached over 3 pipes (stdin/stdout/stderr).
//     This is the default and what `runSpawnOnce` uses.
//   - Socket: a TCP, Unix-domain-socket, or Windows named-pipe connection
//     to an already-running nvim server. Used for `:restart` and the
//     "connect to running nvim" feature. The connected fd/HANDLE serves
//     both read and write.
//
// All callers operate on a `Stream` wrapper so the read/write paths look
// identical regardless of backend:
//   - On POSIX, `Stream.file` is a `std.fs.File` aliasing the socket fd
//     (or the child pipe). `read`/`writeAll`/`close` go straight through.
//   - On Windows for spawn-mode child pipes, `Stream.file` works the same
//     way (separate handles for stdin/stdout/stderr; each I/O path uses
//     its own handle, so the kernel's per-handle synchronization never
//     contends).
//   - On Windows for named-pipe connect, the pipe is opened with
//     FILE_FLAG_OVERLAPPED and wrapped as a `*WindowsOverlappedPipe`.
//     Sync-mode HANDLEs would serialize ReadFile/WriteFile at the kernel
//     level — when FrameReader is blocked in ReadFile waiting for nvim
//     output, the writer thread's WriteFile would deadlock — so the
//     overlapped path uses `OVERLAPPED` + `GetOverlappedResult` to let
//     read and write proceed independently. The wrapper exposes
//     synchronous-blocking semantics so the existing FrameReader and
//     writerThreadFn don't need to know about overlapped I/O.

const std = @import("std");
const builtin = @import("builtin");

pub const ConnectError = error{
    InvalidAddress,
    UnsupportedOnWindows,
    UnsupportedOnPosix,
    ConnectionRefused,
    PipeBusy,
    PipeOpenFailed,
    EventCreateFailed,
} || std.net.TcpConnectToHostError ||
    std.net.TcpConnectToAddressError ||
    std.posix.SocketError ||
    std.posix.ConnectError ||
    std.mem.Allocator.Error;

/// Synchronous-blocking I/O abstraction over either a regular file/socket
/// (`std.fs.File`) or a Windows overlapped named pipe. The abstraction
/// hides overlapped-I/O bookkeeping so FrameReader / writerThreadFn / the
/// stderr pump can treat any backend uniformly.
pub const Stream = union(enum) {
    file: std.fs.File,
    win_pipe: *WindowsOverlappedPipe,

    pub fn read(self: Stream, buf: []u8) !usize {
        return switch (self) {
            .file => |f| f.read(buf),
            .win_pipe => |p| p.read(buf),
        };
    }

    pub fn writeAll(self: Stream, bytes: []const u8) !void {
        return switch (self) {
            .file => |f| f.writeAll(bytes),
            .win_pipe => |p| p.writeAll(bytes),
        };
    }

    /// Cancel pending I/O on the underlying transport so any blocked
    /// read/write returns. Semantics differ by backend:
    ///   - `.file`: closes the fd/HANDLE outright. Self-contained.
    ///   - `.win_pipe`: calls `WindowsOverlappedPipe.closeHandles()`
    ///     which fires `CancelIoEx` only — neither the pipe HANDLE
    ///     nor the event HANDLEs are closed here, because other
    ///     threads holding a Stream value may still be sleeping in
    ///     `GetOverlappedResult(self.handle, ovl, ..., TRUE)` and
    ///     closing those HANDLEs mid-wait is undefined behavior.
    ///     Both the HANDLEs and the wrapper memory are released
    ///     later via `WindowsOverlappedPipe.destroy()`, which the
    ///     owner must call exactly once after every such thread has
    ///     been joined.
    pub fn close(self: Stream) void {
        switch (self) {
            .file => |f| f.close(),
            .win_pipe => |p| p.closeHandles(),
        }
    }

    /// Wake any blocked read/writeAll on this stream so the holding
    /// thread can return promptly. Must be called BEFORE close().
    /// Used at session teardown when the reader/writer threads sit on
    /// a socket fd that another thread is about to close.
    ///
    /// Why this is needed (POSIX socket only):
    ///   For connect-mode (.socket transport) stdin and stdout alias
    ///   the same fd. Closing it from another thread does NOT
    ///   reliably wake threads already blocked in read()/write() on
    ///   the same fd — the kernel keeps an in-flight reference for
    ///   each blocked syscall, and only completes them when the peer
    ///   shuts down its side. shutdown(SHUT_RDWR) makes the kernel
    ///   immediately deliver EOF to readers and EPIPE to writers on
    ///   our side, regardless of peer state.
    ///
    /// Pipe transport (.file with pipe fds): not needed. stdin and
    /// stdout are separate fds, and closing stdin causes nvim to
    /// exit, which closes stdout from its side → reader gets EOF
    /// naturally.
    ///
    /// Windows .win_pipe: not needed. closeHandles() already fires
    /// CancelIoEx on the pipe HANDLE, which releases blocked
    /// GetOverlappedResult calls.
    ///
    /// `is_socket` MUST be accurate: posix.shutdown panics on a
    /// non-socket fd (NOTSOCK is `unreachable` in the Zig wrapper).
    /// Errors are swallowed — at teardown we only care that the
    /// blocked thread is woken; a SocketNotConnected or
    /// ConnectionResetByPeer is acceptable noise.
    pub fn shutdownIfSocket(self: Stream, is_socket: bool) void {
        if (!is_socket) return;
        // Windows `.file` is only used for spawn-mode pipe transport in
        // this codebase — connect-mode socket equivalent is `.win_pipe`
        // (named pipe), whose closeHandles() already fires CancelIoEx
        // to release blocked GetOverlappedResult calls. Skip the
        // POSIX shutdown branch on Windows: std.fs.File.handle is
        // windows.HANDLE while std.posix.shutdown expects
        // ws2_32.SOCKET, so the call would not even compile.
        if (builtin.os.tag == .windows) return;
        switch (self) {
            .file => |f| {
                std.posix.shutdown(f.handle, .both) catch {};
            },
            .win_pipe => {},
        }
    }

    pub fn fromFile(f: std.fs.File) Stream {
        return .{ .file = f };
    }
};

/// Opaque-on-POSIX struct with a stub interface that panics if the
/// non-Windows code paths somehow hit it. On Windows it's a full wrapper
/// around an overlapped HANDLE plus per-direction completion events.
pub const WindowsOverlappedPipe = if (builtin.os.tag == .windows) struct {
    const windows = std.os.windows;

    handle: windows.HANDLE,
    read_event: windows.HANDLE,
    write_event: windows.HANDLE,
    /// Atomic shutdown flag observed by read()/writeAll() at the top
    /// of every loop iteration AND re-checked after a WriteFile/
    /// ReadFile returns IO_PENDING. Set exactly once via swap() in
    /// closeHandles(). Atomic (not plain bool) because closeHandles()
    /// runs on the UI / RPC thread while read()/writeAll() run on the
    /// reader / writer thread; without acquire-release synchronization
    /// the writer could miss the cancellation, issue a fresh WriteFile
    /// after CancelIoEx fired (which only catches I/O outstanding at
    /// the time of the call), and then hang in GetOverlappedResult.
    handles_closed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    alloc: std.mem.Allocator,

    /// Open a Windows named pipe with FILE_FLAG_OVERLAPPED and set up
    /// auto-reset completion events for read and write. Returns a heap-
    /// allocated wrapper.
    ///
    /// Lifetime contract: the wrapper has TWO teardown phases the
    /// owner must run in order:
    ///   1. `closeHandles()` (idempotent) — calls `CancelIoEx` on the
    ///      pipe HANDLE, which marks all currently-pending overlapped
    ///      I/O on that handle as aborted; the kernel writes
    ///      STATUS_CANCELLED into OVERLAPPED.Internal and signals
    ///      OVERLAPPED.hEvent. Any thread sleeping in
    ///      `GetOverlappedResult(self.handle, ovl, ..., TRUE)` wakes
    ///      up and returns FALSE with ERROR_OPERATION_ABORTED. We do
    ///      NOT call `CloseHandle(self.handle)` here, because closing
    ///      the file HANDLE while another thread still holds it as
    ///      the first argument to GetOverlappedResult is undefined
    ///      behavior per MSDN. Event HANDLEs are also left alive for
    ///      the same reason. Do NOT free the wrapper here.
    ///   2. `destroy()` — closes the pipe HANDLE, the event HANDLEs,
    ///      and frees the wrapper struct. MUST be called exactly once,
    ///      AFTER every thread that received a copy of the Stream
    ///      value (writer, reader, stderr pump) has been joined;
    ///      otherwise the close races with their in-flight use of
    ///      self.handle / read_event / write_event.
    /// Skipping phase 1 is safe (destroy() closes the handle anyway)
    /// but loses the ability to unblock blocked I/O before joining.
    pub fn open(alloc: std.mem.Allocator, addr: []const u8) ConnectError!*WindowsOverlappedPipe {
        const path_w = std.unicode.utf8ToUtf16LeAllocZ(alloc, addr) catch return error.OutOfMemory;
        defer alloc.free(path_w);

        const handle = windows.kernel32.CreateFileW(
            path_w.ptr,
            windows.GENERIC_READ | windows.GENERIC_WRITE,
            0, // no sharing
            null, // default security
            windows.OPEN_EXISTING,
            windows.FILE_FLAG_OVERLAPPED,
            null,
        );

        if (handle == windows.INVALID_HANDLE_VALUE) {
            return switch (windows.kernel32.GetLastError()) {
                .FILE_NOT_FOUND, .PATH_NOT_FOUND => error.ConnectionRefused,
                .PIPE_BUSY => error.PipeBusy,
                else => error.PipeOpenFailed,
            };
        }
        errdefer windows.CloseHandle(handle);

        // Auto-reset events (dwFlags=0): GetOverlappedResult resets the
        // event when it returns successfully, so consecutive I/O calls
        // that reuse the same OVERLAPPED+event don't need ResetEvent.
        const read_event = windows.kernel32.CreateEventExW(null, null, 0, windows.EVENT_ALL_ACCESS) orelse return error.EventCreateFailed;
        errdefer windows.CloseHandle(read_event);

        const write_event = windows.kernel32.CreateEventExW(null, null, 0, windows.EVENT_ALL_ACCESS) orelse return error.EventCreateFailed;
        errdefer windows.CloseHandle(write_event);

        const self = try alloc.create(WindowsOverlappedPipe);
        self.* = .{
            .handle = handle,
            .read_event = read_event,
            .write_event = write_event,
            .alloc = alloc,
        };
        return self;
    }

    /// Phase 1 of teardown: cancel pending overlapped I/O without
    /// closing any HANDLE. `CancelIoEx(self.handle, NULL)` marks every
    /// outstanding I/O on the pipe as aborted; the kernel updates
    /// OVERLAPPED.Internal to STATUS_CANCELLED and signals the
    /// associated event. A thread blocked in
    /// `GetOverlappedResult(self.handle, ovl, ..., TRUE)` wakes up
    /// and returns FALSE with ERROR_OPERATION_ABORTED, which `read()`
    /// / `writeAll()` translate to EOF / OperationAborted.
    ///
    /// IMPORTANT: self.handle, read_event, and write_event are all
    /// left alive here. MSDN's contract is that closing a HANDLE while
    /// another thread is still using it (as the file handle for
    /// GetOverlappedResult, or as the wait HANDLE for an overlapped
    /// completion event) is undefined behavior. They are closed in
    /// destroy() after the caller has joined every thread that could
    /// hold a reference. Idempotent — safe to call multiple times
    /// (e.g. from the alias close in socket mode).
    ///
    /// Race coverage: CancelIoEx only cancels I/O outstanding at the
    /// time of the call. To stop the writer from issuing a *fresh*
    /// WriteFile after CancelIoEx fires (which would then hang in
    /// GetOverlappedResult), the atomic flag is set BEFORE CancelIoEx
    /// runs (release ordering pairs with the acquire load at the top
    /// of writeAll/read iterations); writeAll/read also re-check the
    /// flag after a successful WriteFile/ReadFile returns IO_PENDING
    /// and call CancelIoEx targeted at the specific OVERLAPPED so
    /// that fresh I/O is also canceled. See read()/writeAll().
    pub fn closeHandles(self: *WindowsOverlappedPipe) void {
        // swap returns the previous value; if it was already true,
        // closeHandles already ran (e.g. via the alias close in socket
        // mode) and CancelIoEx has nothing new to do.
        if (self.handles_closed.swap(true, .acq_rel)) return;
        _ = windows.kernel32.CancelIoEx(self.handle, null);
    }

    /// Phase 2 of teardown: close the pipe HANDLE, the completion
    /// events, and free the heap allocation. MUST be called exactly
    /// once and only after every thread that holds a
    /// `*WindowsOverlappedPipe` (writer thread, reader, stderr pump,
    /// etc.) has been joined — otherwise closing self.handle /
    /// read_event / write_event mid-use is undefined behavior, and
    /// the alloc.destroy() races with the threads' dereferences.
    /// Calls closeHandles() first as a safety net (no-op if already
    /// canceled by Stream.close()).
    pub fn destroy(self: *WindowsOverlappedPipe) void {
        self.closeHandles();
        windows.CloseHandle(self.handle);
        windows.CloseHandle(self.read_event);
        windows.CloseHandle(self.write_event);
        self.alloc.destroy(self);
    }

    /// Wait for an overlapped I/O to complete. Returns the byte count on
    /// success; returns null on broken-pipe / EOF (i.e. read EOF, write
    /// to closed pipe). Other errors propagate.
    fn waitOverlapped(self: *WindowsOverlappedPipe, overlapped: *windows.OVERLAPPED) !?windows.DWORD {
        var bytes: windows.DWORD = 0;
        if (windows.kernel32.GetOverlappedResult(self.handle, overlapped, &bytes, @intFromBool(true)) == 0) {
            return switch (windows.kernel32.GetLastError()) {
                .BROKEN_PIPE, .HANDLE_EOF => null,
                .OPERATION_ABORTED => error.OperationAborted,
                .NETNAME_DELETED => error.ConnectionResetByPeer,
                else => error.Unexpected,
            };
        }
        return bytes;
    }

    /// Blocking read. Returns 0 on EOF (broken pipe or shutdown
    /// observed). Uses overlapped I/O so a concurrent writeAll() on
    /// the same handle doesn't block.
    pub fn read(self: *WindowsOverlappedPipe, buf: []u8) !usize {
        if (buf.len == 0) return 0;
        // Pre-check shutdown (acquire pairs with the release in
        // closeHandles' swap). If shutdown was observed, return EOF
        // without issuing a fresh ReadFile that the prior CancelIoEx
        // would not catch.
        if (self.handles_closed.load(.acquire)) return 0;

        var overlapped: windows.OVERLAPPED = std.mem.zeroes(windows.OVERLAPPED);
        overlapped.hEvent = self.read_event;

        const want: windows.DWORD = @intCast(@min(buf.len, std.math.maxInt(windows.DWORD)));
        var bytes_read: windows.DWORD = 0;

        const ok = windows.kernel32.ReadFile(self.handle, buf.ptr, want, &bytes_read, &overlapped);
        if (ok == 0) {
            switch (windows.kernel32.GetLastError()) {
                .IO_PENDING => {
                    // Race recovery: closeHandles may have fired between
                    // our pre-check and ReadFile. The prior CancelIoEx
                    // (with NULL OVERLAPPED) only catches I/O outstanding
                    // at its call instant, so this fresh ReadFile would
                    // otherwise hang in GetOverlappedResult. Re-check the
                    // flag and cancel this specific OVERLAPPED if so;
                    // GetOverlappedResult will then return ABORTED quickly.
                    if (self.handles_closed.load(.acquire)) {
                        _ = windows.kernel32.CancelIoEx(self.handle, &overlapped);
                    }
                },
                .BROKEN_PIPE, .HANDLE_EOF => return 0,
                .OPERATION_ABORTED => return error.OperationAborted,
                .NETNAME_DELETED => return error.ConnectionResetByPeer,
                else => return error.Unexpected,
            }

            const maybe_got = try self.waitOverlapped(&overlapped);
            const got = maybe_got orelse return 0; // EOF
            return @intCast(got);
        }
        return @intCast(bytes_read);
    }

    /// Blocking writeAll. Loops on partial writes (rare for pipes but
    /// possible for very large buffers). Per-iteration shutdown check
    /// + post-IO_PENDING re-check + targeted CancelIoEx eliminate the
    /// race where stop() fires CancelIoEx between writer's queue-pop
    /// and WriteFile call (the prior CancelIoEx wouldn't catch the
    /// fresh I/O, leaving the writer hung in GetOverlappedResult).
    pub fn writeAll(self: *WindowsOverlappedPipe, bytes: []const u8) !void {
        var idx: usize = 0;
        while (idx < bytes.len) {
            // Per-iteration pre-check (acquire pairs with the release
            // in closeHandles' swap).
            if (self.handles_closed.load(.acquire)) return error.OperationAborted;

            var overlapped: windows.OVERLAPPED = std.mem.zeroes(windows.OVERLAPPED);
            overlapped.hEvent = self.write_event;

            const want: windows.DWORD = @intCast(@min(bytes.len - idx, std.math.maxInt(windows.DWORD)));
            var bytes_written: windows.DWORD = 0;

            const ok = windows.kernel32.WriteFile(self.handle, bytes.ptr + idx, want, &bytes_written, &overlapped);
            if (ok == 0) {
                switch (windows.kernel32.GetLastError()) {
                    .IO_PENDING => {
                        // Race recovery: closeHandles may have fired
                        // between our pre-check and WriteFile. The prior
                        // CancelIoEx (NULL OVERLAPPED) only catches I/O
                        // outstanding at the call instant, so this fresh
                        // WriteFile would otherwise hang in
                        // GetOverlappedResult. Cancel this specific
                        // OVERLAPPED so GetOverlappedResult returns
                        // ABORTED quickly.
                        if (self.handles_closed.load(.acquire)) {
                            _ = windows.kernel32.CancelIoEx(self.handle, &overlapped);
                        }
                    },
                    .BROKEN_PIPE => return error.BrokenPipe,
                    .OPERATION_ABORTED => return error.OperationAborted,
                    .NETNAME_DELETED => return error.ConnectionResetByPeer,
                    else => return error.Unexpected,
                }

                const maybe_got = try self.waitOverlapped(&overlapped);
                bytes_written = maybe_got orelse return error.BrokenPipe;
            }

            if (bytes_written == 0) return error.BrokenPipe;
            idx += @as(usize, bytes_written);
        }
    }
} else struct {
    // POSIX stub: never instantiated. Methods are unreachable so the
    // Stream switch arms type-check on POSIX even though .win_pipe is
    // never constructed there.
    pub fn open(_: std.mem.Allocator, _: []const u8) ConnectError!*@This() {
        unreachable;
    }
    pub fn closeHandles(_: *@This()) void {
        unreachable;
    }
    pub fn destroy(_: *@This()) void {
        unreachable;
    }
    pub fn read(_: *@This(), _: []u8) !usize {
        unreachable;
    }
    pub fn writeAll(_: *@This(), _: []const u8) !void {
        unreachable;
    }
};

/// Parse a Neovim listen address into one of the three supported forms.
///
/// Forms recognized:
///   - "host:port"        (TCP) — first character is digit, '[' (IPv6
///                                bracket), or alphanumeric followed by
///                                ':' and digits.
///   - "/abs/path"        (Unix domain socket) — absolute path starting
///                                with '/'. No '~' expansion is performed,
///                                so home-relative paths must be expanded
///                                by the caller before being passed in.
///   - "\\.\pipe\..."     (Windows named pipe) — also accepts "\\?\pipe\".
pub const Parsed = union(enum) {
    tcp: struct { host: []const u8, port: u16 },
    unix: []const u8,
    pipe: []const u8,
};

fn isPipePath(addr: []const u8) bool {
    // \\.\pipe\... or \\?\pipe\...
    if (addr.len < 9) return false;
    if (addr[0] != '\\' or addr[1] != '\\') return false;
    if (addr[2] != '.' and addr[2] != '?') return false;
    if (addr[3] != '\\') return false;
    const tail = addr[4..];
    if (tail.len < 5) return false;
    if (std.ascii.toLower(tail[0]) != 'p') return false;
    if (std.ascii.toLower(tail[1]) != 'i') return false;
    if (std.ascii.toLower(tail[2]) != 'p') return false;
    if (std.ascii.toLower(tail[3]) != 'e') return false;
    if (tail[4] != '\\') return false;
    return true;
}

pub fn parseListenAddr(addr: []const u8) ?Parsed {
    if (addr.len == 0) return null;

    // Windows named pipe: \\.\pipe\... or \\?\pipe\...
    if (isPipePath(addr)) {
        return .{ .pipe = addr };
    }

    // Unix domain socket: absolute path only. `~` home-relative paths are
    // intentionally rejected — the C ABI promises `fail fast` on invalid
    // addresses, but nothing on the connect path expands `~` (it would be
    // passed verbatim to connectUnixSocket and fail at runtime). Users
    // should pass an absolute path, e.g. `/Users/me/.cache/nvim/nvim.sock`.
    if (addr[0] == '/') {
        return .{ .unix = addr };
    }

    // Other "\\..." UNC paths (not pipes) — ambiguous; reject.
    if (addr.len >= 2 and addr[0] == '\\' and addr[1] == '\\') return null;

    // TCP host:port. Find the LAST ':' so IPv6 addresses ("::1:port") parse
    // correctly when bracketed ("[::1]:port"); for the unbracketed case we
    // intentionally treat them as ambiguous and return null.
    if (addr[0] == '[') {
        // IPv6 bracketed form: "[host]:port"
        const close_bracket = std.mem.lastIndexOfScalar(u8, addr, ']') orelse return null;
        if (close_bracket + 1 >= addr.len or addr[close_bracket + 1] != ':') return null;
        const host = addr[1..close_bracket];
        const port_str = addr[close_bracket + 2 ..];
        const port = std.fmt.parseInt(u16, port_str, 10) catch return null;
        return .{ .tcp = .{ .host = host, .port = port } };
    }

    const colon = std.mem.lastIndexOfScalar(u8, addr, ':') orelse return null;
    // If there are multiple ':' (IPv6 unbracketed), treat as ambiguous.
    if (std.mem.indexOfScalar(u8, addr[0..colon], ':') != null) return null;
    const host = addr[0..colon];
    const port_str = addr[colon + 1 ..];
    const port = std.fmt.parseInt(u16, port_str, 10) catch return null;
    if (host.len == 0) return null;
    return .{ .tcp = .{ .host = host, .port = port } };
}

/// Returns true if `addr` is a well-formed listen address that
/// `connectListenAddr` would accept on the current platform. Used by
/// the C ABI (`zonvie_core_start_connect`) to fail fast with a parse
/// error before spawning the run-loop thread, instead of letting the
/// failure surface asynchronously through `on_exit`.
///
/// Platform support matrix:
///     POSIX (macOS, Linux): TCP, Unix socket
///     Windows:              named pipe
pub fn isAddrSupported(addr: []const u8) bool {
    const parsed = parseListenAddr(addr) orelse return false;
    return switch (parsed) {
        .tcp, .unix => builtin.os.tag != .windows,
        .pipe => builtin.os.tag == .windows,
    };
}

/// Connect to a Neovim listen address and return a `Stream`. The
/// connection's underlying fd/HANDLE is used for both read and write,
/// and is closed exactly once at session teardown via `Stream.close()`.
pub fn connectListenAddr(alloc: std.mem.Allocator, addr: []const u8) ConnectError!Stream {
    const parsed = parseListenAddr(addr) orelse return error.InvalidAddress;

    if (builtin.os.tag == .windows) {
        return switch (parsed) {
            .pipe => |p| .{ .win_pipe = try WindowsOverlappedPipe.open(alloc, p) },
            // TCP on Windows would require a winsock SOCKET-as-HANDLE
            // shim that the existing FrameReader/writer don't expose.
            .tcp => error.UnsupportedOnWindows,
            .unix => error.UnsupportedOnWindows,
        };
    }

    const stream = switch (parsed) {
        .tcp => |t| try std.net.tcpConnectToHost(alloc, t.host, t.port),
        .unix => |p| try std.net.connectUnixSocket(p),
        // Pipe paths are Windows-only; the early return above handled it.
        .pipe => return error.UnsupportedOnPosix,
    };

    // Alias the socket fd as a std.fs.File. On POSIX both expose the same
    // posix.fd_t, and posix.read/write/close work uniformly on socket fds.
    return .{ .file = std.fs.File{ .handle = stream.handle } };
}

// =========================================================================
// Tests
// =========================================================================

test "parseListenAddr: unix socket path" {
    const r = parseListenAddr("/tmp/nvim.42.0") orelse unreachable;
    try std.testing.expect(r == .unix);
    try std.testing.expectEqualStrings("/tmp/nvim.42.0", r.unix);
}

test "parseListenAddr: tcp ipv4" {
    const r = parseListenAddr("127.0.0.1:6789") orelse unreachable;
    try std.testing.expect(r == .tcp);
    try std.testing.expectEqualStrings("127.0.0.1", r.tcp.host);
    try std.testing.expectEqual(@as(u16, 6789), r.tcp.port);
}

test "parseListenAddr: tcp ipv6 bracketed" {
    const r = parseListenAddr("[::1]:6789") orelse unreachable;
    try std.testing.expect(r == .tcp);
    try std.testing.expectEqualStrings("::1", r.tcp.host);
    try std.testing.expectEqual(@as(u16, 6789), r.tcp.port);
}

test "parseListenAddr: windows named pipe (\\\\.\\)" {
    const r = parseListenAddr("\\\\.\\pipe\\nvim.31920.0") orelse unreachable;
    try std.testing.expect(r == .pipe);
    try std.testing.expectEqualStrings("\\\\.\\pipe\\nvim.31920.0", r.pipe);
}

test "parseListenAddr: windows named pipe (\\\\?\\)" {
    const r = parseListenAddr("\\\\?\\pipe\\nvim") orelse unreachable;
    try std.testing.expect(r == .pipe);
}

test "parseListenAddr: windows named pipe case-insensitive" {
    const r = parseListenAddr("\\\\.\\PIPE\\nvim") orelse unreachable;
    try std.testing.expect(r == .pipe);
}

test "parseListenAddr: rejects empty" {
    try std.testing.expect(parseListenAddr("") == null);
}

test "parseListenAddr: rejects bare hostname" {
    try std.testing.expect(parseListenAddr("localhost") == null);
}

test "parseListenAddr: rejects bare port" {
    try std.testing.expect(parseListenAddr(":1234") == null);
}

test "parseListenAddr: rejects unbracketed ipv6" {
    // Ambiguous: ::1:6789 has multiple colons and no brackets.
    try std.testing.expect(parseListenAddr("::1:6789") == null);
}

test "parseListenAddr: rejects non-pipe UNC path" {
    try std.testing.expect(parseListenAddr("\\\\server\\share") == null);
}

test "parseListenAddr: rejects ~ home-relative path (no expansion)" {
    // The connect path passes the address verbatim to connectUnixSocket,
    // which does not expand `~`. Accepting it here would let
    // zonvie_core_start_connect return 0 and fail asynchronously, breaking
    // the `fail fast` ABI contract. Force absolute paths instead.
    try std.testing.expect(parseListenAddr("~/nvim.sock") == null);
    try std.testing.expect(parseListenAddr("~root/nvim.sock") == null);
}

test "isAddrSupported: rejects malformed input on every platform" {
    try std.testing.expect(!isAddrSupported(""));
    try std.testing.expect(!isAddrSupported("localhost"));
    try std.testing.expect(!isAddrSupported(":1234"));
    try std.testing.expect(!isAddrSupported("\\\\server\\share"));
}

test "isAddrSupported: platform-specific acceptance matrix" {
    if (builtin.os.tag == .windows) {
        // Windows: only named pipes are supported today.
        try std.testing.expect(isAddrSupported("\\\\.\\pipe\\nvim.31920.0"));
        try std.testing.expect(!isAddrSupported("127.0.0.1:6789"));
        try std.testing.expect(!isAddrSupported("/tmp/nvim.42.0"));
    } else {
        // POSIX: TCP and Unix sockets supported; pipes are not.
        try std.testing.expect(isAddrSupported("127.0.0.1:6789"));
        try std.testing.expect(isAddrSupported("[::1]:6789"));
        try std.testing.expect(isAddrSupported("/tmp/nvim.42.0"));
        try std.testing.expect(!isAddrSupported("\\\\.\\pipe\\nvim.31920.0"));
    }
}
