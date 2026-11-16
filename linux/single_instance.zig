//! [server] single_instance: the first zonvie listens on a socket in the
//! user's runtime directory, and a later launch hands it its files and
//! exits. The message is the absolute paths, each ended by a 0 byte; none
//! is a launch without files.

const std = @import("std");
const App = @import("app.zig").App;
const glib = @import("glib.zig");
const session = @import("session.zig");

const max_message = 64 * 1024;

extern "c" fn socket(domain: c_int, sock_type: c_int, protocol: c_int) c_int;
extern "c" fn connect(fd: c_int, addr: *const SockAddr, len: u32) c_int;
extern "c" fn bind(fd: c_int, addr: *const SockAddr, len: u32) c_int;
extern "c" fn listen(fd: c_int, backlog: c_int) c_int;
extern "c" fn accept4(fd: c_int, addr: ?*anyopaque, len: ?*u32, flags: c_int) c_int;
extern "c" fn unlink(path: [*:0]const u8) c_int;
extern "c" fn getuid() c_uint;
extern "c" fn poll(fds: *PollFd, n: c_ulong, timeout_ms: c_int) c_int;

const AF_UNIX = 1;
const SOCK_STREAM = 1;
const SOCK_CLOEXEC = 0o2000000;
const POLLIN = 1;
const PollFd = extern struct { fd: c_int, events: c_short, revents: c_short };
const SockAddr = extern struct { family: u16 = AF_UNIX, path: [108]u8 = @splat(0) };

/// `$XDG_RUNTIME_DIR/zonvie.sock`, else `/tmp/zonvie-<uid>.sock`.
fn address() ?SockAddr {
    var a: SockAddr = .{};
    const text = if (std.c.getenv("XDG_RUNTIME_DIR")) |d|
        std.fmt.bufPrint(a.path[0 .. a.path.len - 1], "{s}/zonvie.sock", .{std.mem.span(d)}) catch return null
    else
        std.fmt.bufPrint(a.path[0 .. a.path.len - 1], "/tmp/zonvie-{d}.sock", .{getuid()}) catch return null;
    _ = text;
    return a;
}

/// Hands `paths` to the instance that listens. False when none does: this
/// launch is then the instance.
pub fn forward(paths: []const [:0]const u8) bool {
    const a = address() orelse return false;
    const fd = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
    if (fd < 0) return false;
    defer _ = std.c.close(fd);
    if (connect(fd, &a, @sizeOf(SockAddr)) != 0) return false;
    for (paths) |p| {
        // The path and its 0.
        var rest: []const u8 = p.ptr[0 .. p.len + 1];
        while (rest.len > 0) {
            const n = std.c.write(fd, rest.ptr, rest.len);
            if (n <= 0) return true;
            rest = rest[@intCast(n)..];
        }
    }
    return true;
}

var listen_fd: c_int = -1;

/// Becomes the instance later launches reach. A socket file left by an
/// instance that is gone is replaced: nobody answered on it (forward).
pub fn serve(app: *App) void {
    const a = address() orelse return;
    const fd = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
    if (fd < 0) return;
    _ = unlink(@ptrCast(&a.path));
    if (bind(fd, &a, @sizeOf(SockAddr)) != 0 or listen(fd, 8) != 0) {
        _ = std.c.close(fd);
        return;
    }
    listen_fd = fd;
    _ = glib.g_unix_fd_add(fd, glib.G_IO_IN, &onConnection, app);
}

/// Removes the socket file, so the next launch does not try it first.
pub fn stop() void {
    if (listen_fd < 0) return;
    if (address()) |a| _ = unlink(@ptrCast(&a.path));
    _ = std.c.close(listen_fd);
    listen_fd = -1;
}

fn onConnection(fd: c_int, _: c_uint, data: ?*anyopaque) callconv(.c) c_int {
    const app: *App = @ptrCast(@alignCast(data.?));
    const conn = accept4(fd, null, null, SOCK_CLOEXEC);
    if (conn < 0) return 1;
    defer _ = std.c.close(conn);
    // The sender writes and closes at once; a second covers a slow one
    // without holding the loop for a peer that never does.
    const buf = app.alloc.alloc(u8, max_message) catch return 1;
    defer app.alloc.free(buf);
    var len: usize = 0;
    while (len < buf.len) {
        var pfd: PollFd = .{ .fd = conn, .events = POLLIN, .revents = 0 };
        if (poll(&pfd, 1, 1000) <= 0) break;
        const n = std.c.read(conn, buf[len..].ptr, buf.len - len);
        if (n <= 0) break;
        len += @intCast(n);
    }
    var paths: [64][:0]const u8 = undefined;
    var count: usize = 0;
    var start: usize = 0;
    for (buf[0..len], 0..) |c, i| {
        if (c != 0) continue;
        if (i > start and count < paths.len) {
            paths[count] = buf[start..i :0];
            count += 1;
        }
        start = i + 1;
    }
    session.openPaths(app, paths[0..count]);
    return 1;
}
