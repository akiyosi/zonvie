//! The panic handler, as windows/main.zig's: the message and the stack go to
//! the log file and stderr. Without a terminal (a detached or launcher
//! start, whose stderr nobody reads) the report is also kept in
//! $XDG_STATE_HOME/zonvie/crash.log. Nothing shows it on screen: there is no
//! dialog to show it in. No allocation: everything uses fixed buffers.

const std = @import("std");
const applog = @import("app_log.zig");

var g_entered = std.atomic.Value(bool).init(false);
/// This process is a form (form.zig): its own crash opens no report window.
pub var is_form = false;

extern "c" fn fork() c_int;
extern "c" fn execv(path: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) c_int;
extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn _exit(code: c_int) noreturn;

/// Shows `text` in a window of its own: this executable again, as the
/// message form, which outlives this process. `text` ends in a 0 byte
/// within `buf`.
pub fn showReport(text: [:0]const u8) void {
    if (is_form) return;
    var exe: [std.fs.max_path_bytes:0]u8 = undefined;
    const n = std.c.readlink("/proc/self/exe", &exe, exe.len - 1);
    if (n <= 0) return;
    exe[@intCast(n)] = 0;
    if (fork() != 0) return;
    _ = std.c.setsid();
    _ = setenv("ZONVIE_CRASH_REPORT", "1", 1);
    const argv = [_:null]?[*:0]const u8{ &exe, text.ptr };
    _ = execv(&exe, &argv);
    _exit(127);
}
var g_report: [16 * 1024]u8 = undefined;

pub fn onPanic(msg: []const u8, first_trace_addr: ?usize) noreturn {
    @branchHint(.cold);
    // Once only: a second panicking thread, or a panic inside this handler,
    // goes straight to the default handler.
    if (g_entered.swap(true, .acq_rel)) std.debug.defaultPanic(msg, first_trace_addr);

    var w = std.Io.Writer.fixed(&g_report);
    w.print("\n=== ZONVIE PANIC ===\npanic: {s}\nstack trace:\n", .{msg}) catch {};
    std.debug.writeCurrentStackTrace(.{
        .first_address = first_trace_addr orelse @returnAddress(),
        .allow_unsafe_unwind = true,
    }, .{ .writer = &w, .mode = .no_color }) catch {};
    w.writeAll("=== END PANIC ===\n") catch {};
    const report = w.buffered();

    if (applog.fileFd()) |fd| writeAll(fd, report);
    if (std.c.isatty(2) == 0) {
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const home: ?[]const u8 = if (std.c.getenv("HOME")) |h| std.mem.span(h) else null;
        const state: ?[]const u8 = if (std.c.getenv("XDG_STATE_HOME")) |s| std.mem.span(s) else null;
        const path = crashPath(&path_buf, state, home);
        if (path) |p| writeCrashFile(p, report);
    }
    // The report in a window: a start from the desktop has no terminal.
    if (report.len < g_report.len) {
        g_report[report.len] = 0;
        showReport(g_report[0..report.len :0]);
    }
    // stderr, then abort, as without this handler.
    std.debug.defaultPanic(msg, first_trace_addr);
}

/// `<state>/zonvie/crash.log`, where `state` is $XDG_STATE_HOME when it is
/// an absolute path (the spec ignores a relative one), else
/// `<home>/.local/state`. Null without either, or when `buf` is too small.
pub fn crashPath(buf: []u8, xdg_state_home: ?[]const u8, home: ?[]const u8) ?[:0]const u8 {
    if (xdg_state_home) |s| if (s.len != 0 and s[0] == '/')
        return std.fmt.bufPrintZ(buf, "{s}/zonvie/crash.log", .{s}) catch null;
    const h = home orelse return null;
    if (h.len == 0) return null;
    return std.fmt.bufPrintZ(buf, "{s}/.local/state/zonvie/crash.log", .{h}) catch null;
}

test "the crash file lives under XDG_STATE_HOME, else ~/.local/state" {
    var buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings("/s/zonvie/crash.log", crashPath(&buf, "/s", "/h").?);
    try std.testing.expectEqualStrings("/h/.local/state/zonvie/crash.log", crashPath(&buf, null, "/h").?);
    try std.testing.expectEqualStrings("/h/.local/state/zonvie/crash.log", crashPath(&buf, "rel", "/h").?);
    try std.testing.expect(crashPath(&buf, null, null) == null);
    var tiny: [8]u8 = undefined;
    try std.testing.expect(crashPath(&tiny, "/s", null) == null);
}

fn writeAll(fd: std.posix.fd_t, bytes: []const u8) void {
    var rest = bytes;
    while (rest.len > 0) {
        const n = std.c.write(fd, rest.ptr, rest.len);
        if (n <= 0) return;
        rest = rest[@intCast(n)..];
    }
}

/// Creates the directories up to the file (mode 0700, as the state dir
/// should be) and replaces the previous report.
fn writeCrashFile(path: [:0]const u8, report: []const u8) void {
    var dir_buf: [std.fs.max_path_bytes:0]u8 = undefined;
    @memcpy(dir_buf[0..path.len], path);
    var i: usize = 1;
    while (i < path.len) : (i += 1) {
        if (path[i] != '/') continue;
        dir_buf[i] = 0;
        _ = std.c.mkdir(@ptrCast(&dir_buf), 0o700);
        dir_buf[i] = '/';
    }
    const fd = std.c.open(path.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o600));
    if (fd < 0) return;
    defer _ = std.c.close(fd);
    writeAll(fd, report);
}
