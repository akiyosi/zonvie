// app_log.zig — Frontend logging for Linux (mirrors windows/app_log.zig).

const std = @import("std");
const clock = @import("zonvie_core").clock;

var g_enabled: bool = false;
var g_log_file: ?std.Io.File = null;
/// The core, GTK and render threads all log: one line is one locked write.
var g_mu: std.Io.Mutex = .init;
var g_start_ns: i128 = 0;

/// Monotonic, so a wall-clock step cannot reorder the stamps the GUI harness
/// filters by.
fn monoNs() i128 {
    return std.Io.Timestamp.now(clock.io(), .awake).nanoseconds;
}

/// `[zonvie] [   12.345ms] `, the prefix the other frontends write and the
/// GUI harness parses (test/gui/app_log.zig lineTimestampMs).
fn stampInto(buf: []u8) []const u8 {
    const ms = @as(f64, @floatFromInt(monoNs() - g_start_ns)) / std.time.ns_per_ms;
    return std.fmt.bufPrint(buf, "[zonvie] [{d:>9.3}ms] ", .{ms}) catch "[zonvie] [    0.000ms] ";
}

/// App-root log switch (Linux side).
/// This is the single source of truth for "frontend logging enabled".
pub fn setEnabled(enabled: bool) void {
    g_enabled = enabled;
    if (g_start_ns == 0) g_start_ns = monoNs();
}

pub fn isEnabled() bool {
    return g_enabled;
}

var g_verbose: bool = false;

/// config.toml [log] verbose (and neither perf_only nor scroll_only): emit
/// the structured render traces, as windows/app_log.zig isVerbose.
pub fn setVerbose(verbose: bool) void {
    g_verbose = verbose;
}

pub fn isVerbose() bool {
    return g_enabled and g_verbose;
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
            g_log_file = if (std.fs.path.isAbsolute(p))
                std.Io.Dir.createFileAbsolute(clock.io(), p, .{ .truncate = true }) catch null
            else
                std.Io.Dir.cwd().createFile(clock.io(), p, .{ .truncate = true }) catch null;
        }
    }
}

/// printf-style logging for app/frontend side.
pub fn appLog(comptime fmt: []const u8, args: anytype) void {
    if (!g_enabled) return;

    if (g_log_file) |f| {
        // Write to file using a stack buffer
        var buf: [4096]u8 = undefined;
        const stamp = stampInto(&buf);
        const msg = switch (@typeInfo(@TypeOf(args))) {
            .@"struct" => std.fmt.bufPrint(buf[stamp.len..], fmt, args) catch return,
            else => std.fmt.bufPrint(buf[stamp.len..], fmt, .{args}) catch return,
        };
        g_mu.lockUncancelable(clock.io());
        defer g_mu.unlock(clock.io());
        f.writeStreamingAll(clock.io(), buf[0 .. stamp.len + msg.len]) catch {};
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
        var buf: [32]u8 = undefined;
        g_mu.lockUncancelable(clock.io());
        defer g_mu.unlock(clock.io());
        f.writeStreamingAll(clock.io(), stampInto(&buf)) catch {};
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
