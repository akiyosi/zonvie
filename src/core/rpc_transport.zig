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

    pub fn close(self: Stream) void {
        switch (self) {
            .file => |f| f.close(),
            .win_pipe => |p| p.deinit(),
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
    alloc: std.mem.Allocator,

    /// Open a Windows named pipe with FILE_FLAG_OVERLAPPED and set up
    /// auto-reset completion events for read and write. Returns a heap-
    /// allocated wrapper; the caller is responsible for calling
    /// `deinit()` exactly once at session teardown.
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

    pub fn deinit(self: *WindowsOverlappedPipe) void {
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

    /// Blocking read. Returns 0 on EOF (broken pipe). Uses overlapped
    /// I/O so a concurrent writeAll() on the same handle doesn't block.
    pub fn read(self: *WindowsOverlappedPipe, buf: []u8) !usize {
        if (buf.len == 0) return 0;

        var overlapped: windows.OVERLAPPED = std.mem.zeroes(windows.OVERLAPPED);
        overlapped.hEvent = self.read_event;

        const want: windows.DWORD = @intCast(@min(buf.len, std.math.maxInt(windows.DWORD)));
        var bytes_read: windows.DWORD = 0;

        const ok = windows.kernel32.ReadFile(self.handle, buf.ptr, want, &bytes_read, &overlapped);
        if (ok == 0) {
            switch (windows.kernel32.GetLastError()) {
                .IO_PENDING => {}, // proceed to GetOverlappedResult below
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
    /// possible for very large buffers).
    pub fn writeAll(self: *WindowsOverlappedPipe, bytes: []const u8) !void {
        var idx: usize = 0;
        while (idx < bytes.len) {
            var overlapped: windows.OVERLAPPED = std.mem.zeroes(windows.OVERLAPPED);
            overlapped.hEvent = self.write_event;

            const want: windows.DWORD = @intCast(@min(bytes.len - idx, std.math.maxInt(windows.DWORD)));
            var bytes_written: windows.DWORD = 0;

            const ok = windows.kernel32.WriteFile(self.handle, bytes.ptr + idx, want, &bytes_written, &overlapped);
            if (ok == 0) {
                switch (windows.kernel32.GetLastError()) {
                    .IO_PENDING => {}, // proceed to GetOverlappedResult below
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
    pub fn deinit(_: *@This()) void {
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
///   - "/abs/path"        (Unix domain socket) — starts with '/' or '~'.
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

    // Unix domain socket: absolute path or home-relative.
    if (addr[0] == '/' or addr[0] == '~') {
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
