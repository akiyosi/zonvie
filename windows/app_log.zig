const std = @import("std");

var g_enabled: bool = false;
var g_log_file: ?std.fs.File = null;

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
        f.close();
        g_log_file = null;
    }

    if (path) |p| {
        if (p.len > 0) {
            g_log_file = std.fs.createFileAbsolute(p, .{ .truncate = true }) catch null;
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
        _ = f.write(msg) catch {};
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
        _ = f.write(prefix) catch {};
        _ = f.write(bytes) catch {};
        _ = f.write("\n") catch {};
    } else {
        std.debug.print("{s}{s}\n", .{ prefix, bytes });
    }
}

/// Cleanup: close log file if open
pub fn deinit() void {
    if (g_log_file) |f| {
        f.close();
        g_log_file = null;
    }
}
