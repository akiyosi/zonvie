const std = @import("std");
const clock = @import("zonvie_core").clock;

var g_enabled: bool = false;
var g_log_file: ?std.Io.File = null;

/// App-root log switch (Windows side).
/// This is the single source of truth for "frontend logging enabled".
pub fn setEnabled(enabled: bool) void {
    g_enabled = enabled;
}

pub fn isEnabled() bool {
    return g_enabled;
}

/// Set log output file path. If path is provided, logs go to file instead of stderr.
pub fn setLogPath(path: ?[]const u8) void {
    // Close existing file if any
    if (g_log_file) |f| {
        f.close(clock.io());
        g_log_file = null;
    }

    if (path) |p| {
        if (p.len > 0) {
            g_log_file = std.Io.Dir.createFileAbsolute(clock.io(), p, .{ .truncate = true }) catch null;
        }
    }
}

/// printf-style logging for app/frontend side.
pub fn appLog(comptime fmt: []const u8, args: anytype) void {
    if (!g_enabled) return;

    if (g_log_file) |f| {
        // Write to file using a stack buffer
        var buf: [4096]u8 = undefined;
        const msg = switch (@typeInfo(@TypeOf(args))) {
            .@"struct" => std.fmt.bufPrint(&buf, fmt, args) catch return,
            else => std.fmt.bufPrint(&buf, fmt, .{args}) catch return,
        };
        f.writeStreamingAll(clock.io(), msg) catch {};
    } else {
        // Write to stderr
        switch (@typeInfo(@TypeOf(args))) {
            .@"struct" => std.debug.print(fmt, args),
            else => std.debug.print(fmt, .{args}),
        }
    }
}

/// Used by core on_log callback: bytes already contain newline sometimes; caller decides.
pub fn appLogBytes(prefix: []const u8, bytes: []const u8) void {
    if (!g_enabled) return;

    if (g_log_file) |f| {
        f.writeStreamingAll(clock.io(), prefix) catch {};
        f.writeStreamingAll(clock.io(), bytes) catch {};
        f.writeStreamingAll(clock.io(), "\n") catch {};
    } else {
        std.debug.print("{s}{s}\n", .{ prefix, bytes });
    }
}

/// Cleanup: close log file if open
pub fn deinit() void {
    if (g_log_file) |f| {
        f.close(clock.io());
        g_log_file = null;
    }
}
