// rpc_transport.zig — RPC transport layer for nvim sessions.
//
// Two transports are supported:
//   - Spawn: a child nvim process attached over 3 pipes (stdin/stdout/stderr).
//     This is the default and what `runSpawnOnce` uses.
//   - Socket: a TCP, Unix-domain-socket, or Windows named-pipe connection
//     to an already-running nvim server. Used for `:restart` and the
//     "connect to running nvim" feature. The connected fd/HANDLE serves
//     both read and write, and is wrapped in a `std.fs.File` so the
//     existing `FrameReader` and `writerThreadFn` (which both operate on
//     `std.fs.File`) can be reused unchanged.
//
// Platform notes:
//   - POSIX: TCP and Unix-domain sockets work via std.net (same posix.fd_t
//     as a regular file, so the alias trick is transparent).
//   - Windows: NEITHER TCP NOR named-pipe connect is supported yet.
//     - TCP: winsock SOCKET is not interchangeable with a HANDLE for
//       ReadFile/WriteFile.
//     - Named pipe: synchronous-mode HANDLEs serialize ReadFile/WriteFile
//       at the kernel level, so when FrameReader is blocked in ReadFile
//       waiting for nvim output, the writer thread's WriteFile deadlocks
//       indefinitely. Real fix requires opening the pipe with
//       FILE_FLAG_OVERLAPPED and rewriting the I/O paths around OVERLAPPED
//       structures (libuv's approach). Tracked as TODO; the parser still
//       recognizes pipe paths so the future implementation has a clean
//       hook point. Until then, callers fall back to re-spawning nvim.

const std = @import("std");
const builtin = @import("builtin");

pub const ConnectError = error{
    InvalidAddress,
    UnsupportedOnWindows,
    UnsupportedOnPosix,
    ConnectionRefused,
} || std.net.TcpConnectToHostError ||
    std.net.TcpConnectToAddressError ||
    std.posix.SocketError ||
    std.posix.ConnectError ||
    std.mem.Allocator.Error;

/// A connected RPC transport. The `file` field aliases the socket fd
/// (POSIX) or pipe HANDLE (Windows); reading and writing both operate
/// on the same handle, so closing the file once is sufficient — never
/// close it twice.
pub const Connection = struct {
    file: std.fs.File,

    pub fn close(self: *Connection) void {
        self.file.close();
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
    // Match "pipe\" case-insensitively.
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

/// Connect to a Neovim listen address and return a `Connection`. The
/// connection's underlying fd is used for both read and write, and is
/// closed exactly once at session teardown.
///
/// Windows: returns `error.UnsupportedOnWindows` for all forms today (see
/// file header for the named-pipe deadlock rationale). The caller's
/// re-spawn fallback handles `:restart` in degraded mode.
pub fn connectListenAddr(alloc: std.mem.Allocator, addr: []const u8) ConnectError!Connection {
    if (builtin.os.tag == .windows) return error.UnsupportedOnWindows;

    const parsed = parseListenAddr(addr) orelse return error.InvalidAddress;

    const stream = switch (parsed) {
        .tcp => |t| try std.net.tcpConnectToHost(alloc, t.host, t.port),
        .unix => |p| try std.net.connectUnixSocket(p),
        // Pipe paths are Windows-only; the early return above already
        // handled them for that platform.
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
