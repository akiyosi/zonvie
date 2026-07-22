const std = @import("std");
const builtin = @import("builtin");
const clock = @import("zonvie_core").clock;

var g_enabled: std.atomic.Value(bool) = .init(false);
var g_log_file: ?std.Io.File = null;
var g_perf_only: std.atomic.Value(bool) = .init(false);
var g_scroll_only: std.atomic.Value(bool) = .init(false);
var g_verbose: std.atomic.Value(bool) = .init(false);

// Logging callbacks can run while core grid_mu or app.mu is held. Queue into a
// fixed ring so those hot paths never perform file/stderr I/O or heap work.
const queue_capacity = 1024 * 1024;
var g_queue: [queue_capacity]u8 = undefined;
var g_queue_head: usize = 0;
var g_queue_len: usize = 0;
var g_queue_stop: bool = false;
var g_queue_mu: std.Io.Mutex = .init;
var g_queue_cond: std.Io.Condition = .init;
var g_log_thread: ?std.Thread = null;
var g_queue_busy_drops: std.atomic.Value(u64) = .init(0);
var g_queue_full_drops: std.atomic.Value(u64) = .init(0);
var g_queue_stopped_drops: std.atomic.Value(u64) = .init(0);
var g_queue_shutdown_drop_bytes: std.atomic.Value(u64) = .init(0);
var g_format_drops: std.atomic.Value(u64) = .init(0);
var g_sink_inflight_bytes: std.atomic.Value(u64) = .init(0);

fn enqueueLocked(bytes: []const u8) bool {
    if (bytes.len > queue_capacity - g_queue_len) return false;
    const tail = (g_queue_head + g_queue_len) % queue_capacity;
    const first_len = @min(bytes.len, queue_capacity - tail);
    @memcpy(g_queue[tail .. tail + first_len], bytes[0..first_len]);
    if (first_len < bytes.len) {
        @memcpy(g_queue[0 .. bytes.len - first_len], bytes[first_len..]);
    }
    g_queue_len += bytes.len;
    return true;
}

fn enqueueDropSummaryLocked(required_after: usize) void {
    const busy = g_queue_busy_drops.load(.acquire);
    const full = g_queue_full_drops.load(.acquire);
    const stopped = g_queue_stopped_drops.load(.acquire);
    const format = g_format_drops.load(.acquire);
    if (busy == 0 and full == 0 and stopped == 0 and format == 0) return;

    var buf: [192]u8 = undefined;
    const summary = std.fmt.bufPrint(
        &buf,
        "[log] dropped messages: busy={d} full={d} stopped={d} format={d}\n",
        .{ busy, full, stopped, format },
    ) catch return;
    if (summary.len > queue_capacity - g_queue_len or
        required_after > queue_capacity - g_queue_len - summary.len)
    {
        return;
    }

    _ = g_queue_busy_drops.fetchSub(busy, .acq_rel);
    _ = g_queue_full_drops.fetchSub(full, .acq_rel);
    _ = g_queue_stopped_drops.fetchSub(stopped, .acq_rel);
    _ = g_format_drops.fetchSub(format, .acq_rel);
    _ = enqueueLocked(summary);
}

fn enqueue(bytes: []const u8) void {
    if (!g_queue_mu.tryLock()) {
        _ = g_queue_busy_drops.fetchAdd(1, .monotonic);
        return;
    }
    defer g_queue_mu.unlock(clock.io());

    if (g_queue_stop) {
        _ = g_queue_stopped_drops.fetchAdd(1, .monotonic);
        return;
    }
    if (bytes.len > queue_capacity - g_queue_len) {
        _ = g_queue_full_drops.fetchAdd(1, .monotonic);
        return;
    }
    enqueueDropSummaryLocked(bytes.len);
    _ = enqueueLocked(bytes);
    g_queue_cond.signal(clock.io());
}

fn enqueueParts(prefix: []const u8, bytes: []const u8, suffix: []const u8) void {
    const total = std.math.add(usize, prefix.len, bytes.len) catch return;
    const required = std.math.add(usize, total, suffix.len) catch return;
    if (!g_queue_mu.tryLock()) {
        _ = g_queue_busy_drops.fetchAdd(1, .monotonic);
        return;
    }
    defer g_queue_mu.unlock(clock.io());

    if (g_queue_stop) {
        _ = g_queue_stopped_drops.fetchAdd(1, .monotonic);
        return;
    }
    if (required > queue_capacity - g_queue_len) {
        _ = g_queue_full_drops.fetchAdd(1, .monotonic);
        return;
    }
    enqueueDropSummaryLocked(required);
    _ = enqueueLocked(prefix);
    _ = enqueueLocked(bytes);
    _ = enqueueLocked(suffix);
    g_queue_cond.signal(clock.io());
}

fn writeChunk(chunk: []const u8) void {
    if (g_log_file) |f| {
        f.writeStreamingAll(clock.io(), chunk) catch {};
    } else {
        std.debug.print("{s}", .{chunk});
    }
}

fn outputDebug(bytes: []const u8) void {
    if (comptime builtin.os.tag == .windows) {
        const kernel32 = struct {
            extern "kernel32" fn OutputDebugStringA(message: [*:0]const u8) callconv(.winapi) void;
        };
        var debug_buf: [4097]u8 = undefined;
        const len = @min(bytes.len, debug_buf.len - 1);
        @memcpy(debug_buf[0..len], bytes[0..len]);
        debug_buf[len] = 0;
        kernel32.OutputDebugStringA(@ptrCast(&debug_buf));
    }
}

fn logThreadMain() void {
    defer {
        const busy = g_queue_busy_drops.load(.acquire);
        const full = g_queue_full_drops.load(.acquire);
        const stopped = g_queue_stopped_drops.load(.acquire);
        const format = g_format_drops.load(.acquire);
        const shutdown_bytes = g_queue_shutdown_drop_bytes.load(.acquire);
        if (busy != 0 or full != 0 or stopped != 0 or format != 0 or shutdown_bytes != 0) {
            var summary_buf: [224]u8 = undefined;
            if (std.fmt.bufPrint(
                &summary_buf,
                "[log] final drops: busy={d} full={d} stopped={d} format={d} shutdown_bytes={d}\n",
                .{ busy, full, stopped, format, shutdown_bytes },
            )) |summary| {
                writeChunk(summary);
            } else |_| {}
        }
        if (g_log_file) |f| {
            f.close(clock.io());
            g_log_file = null;
        }
    }

    var scratch: [8192]u8 = undefined;
    while (true) {
        g_queue_mu.lockUncancelable(clock.io());
        while (g_queue_len == 0 and !g_queue_stop) {
            g_queue_cond.waitUncancelable(clock.io(), &g_queue_mu);
        }
        if (g_queue_stop) {
            if (g_queue_len != 0) {
                _ = g_queue_shutdown_drop_bytes.fetchAdd(@intCast(g_queue_len), .monotonic);
                g_queue_head = 0;
                g_queue_len = 0;
            }
            g_queue_mu.unlock(clock.io());
            break;
        }

        const n = @min(scratch.len, g_queue_len);
        const first_len = @min(n, queue_capacity - g_queue_head);
        @memcpy(scratch[0..first_len], g_queue[g_queue_head .. g_queue_head + first_len]);
        if (first_len < n) {
            @memcpy(scratch[first_len..n], g_queue[0 .. n - first_len]);
        }
        g_queue_head = (g_queue_head + n) % queue_capacity;
        g_queue_len -= n;
        g_queue_mu.unlock(clock.io());

        g_sink_inflight_bytes.store(@intCast(n), .release);
        writeChunk(scratch[0..n]);
        g_sink_inflight_bytes.store(0, .release);
    }
}

/// App-root log switch (Windows side).
/// This is the single source of truth for "frontend logging enabled".
pub fn setEnabled(enabled: bool) void {
    if (enabled and g_log_thread == null) {
        g_queue_stop = false;
        g_log_thread = std.Thread.spawn(.{}, logThreadMain, .{}) catch {
            std.debug.print("failed to start log writer thread; logging disabled\n", .{});
            g_enabled.store(false, .release);
            return;
        };
    }
    g_enabled.store(enabled, .release);
}

pub fn isEnabled() bool {
    return g_enabled.load(.acquire);
}

pub fn setFilters(perf_only: bool, scroll_only: bool, verbose: bool) void {
    g_perf_only.store(perf_only, .release);
    g_scroll_only.store(scroll_only, .release);
    g_verbose.store(verbose, .release);
}

/// True only when expensive frontend diagnostics should inspect row/vertex
/// payloads. perf_only/scroll_only must reject before that traversal begins.
pub fn isVerbose() bool {
    return isEnabled() and
        g_verbose.load(.acquire) and
        !g_perf_only.load(.acquire) and
        !g_scroll_only.load(.acquire);
}

fn shouldEmit(comptime fmt: []const u8) bool {
    const is_perf = comptime (std.mem.startsWith(u8, fmt, "[perf]") or
        std.mem.startsWith(u8, fmt, "[perf_"));
    const is_scroll = comptime std.mem.startsWith(u8, fmt, "[scroll_debug]");
    if (g_scroll_only.load(.acquire)) return is_perf or is_scroll;
    if (g_perf_only.load(.acquire)) return is_perf;
    return true;
}

fn shouldEmitBytes(prefix: []const u8, bytes: []const u8) bool {
    const line = if (prefix.len != 0) prefix else bytes;
    const is_perf = std.mem.startsWith(u8, line, "[perf]") or
        std.mem.startsWith(u8, line, "[perf_");
    const is_scroll = std.mem.startsWith(u8, line, "[scroll_debug]");
    if (g_scroll_only.load(.acquire)) return is_perf or is_scroll;
    if (g_perf_only.load(.acquire)) return is_perf;
    return true;
}

pub const DropStats = struct {
    busy: u64,
    full: u64,
    stopped: u64,
    format: u64,
    shutdown_bytes: u64,
};

/// Lock-free snapshot for diagnostics and tests. Drop visibility does not rely
/// on the asynchronous writer reaching a final summary during process exit.
pub fn dropStats() DropStats {
    return .{
        .busy = g_queue_busy_drops.load(.acquire),
        .full = g_queue_full_drops.load(.acquire),
        .stopped = g_queue_stopped_drops.load(.acquire),
        .format = g_format_drops.load(.acquire),
        .shutdown_bytes = g_queue_shutdown_drop_bytes.load(.acquire),
    };
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
    if (!isEnabled() or !shouldEmit(fmt)) return;

    var buf: [4096]u8 = undefined;
    const msg = switch (@typeInfo(@TypeOf(args))) {
        .@"struct" => std.fmt.bufPrint(&buf, fmt, args) catch {
            _ = g_format_drops.fetchAdd(1, .monotonic);
            return;
        },
        else => std.fmt.bufPrint(&buf, fmt, .{args}) catch {
            _ = g_format_drops.fetchAdd(1, .monotonic);
            return;
        },
    };
    enqueue(msg);
}

/// Used by core on_log callback: bytes already contain newline sometimes; caller decides.
pub fn appLogBytes(prefix: []const u8, bytes: []const u8) void {
    if (!isEnabled() or !shouldEmitBytes(prefix, bytes)) return;

    enqueueParts(prefix, bytes, "\n");
}

/// Panic-only best-effort path. Never wait on the configured sink: it may be a
/// stopped pipe. Queue opportunistically and mirror to the Windows debugger;
/// the process can then reach abort even when the file/pipe consumer is stuck.
pub fn appLogEmergency(comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    const msg = switch (@typeInfo(@TypeOf(args))) {
        .@"struct" => std.fmt.bufPrint(&buf, fmt, args) catch {
            _ = g_format_drops.fetchAdd(1, .monotonic);
            return;
        },
        else => std.fmt.bufPrint(&buf, fmt, .{args}) catch {
            _ = g_format_drops.fetchAdd(1, .monotonic);
            return;
        },
    };
    if (isEnabled()) enqueue(msg);
    outputDebug(msg);
}

/// Cleanup: close log file if open
pub fn deinit() void {
    g_enabled.store(false, .release);
    g_queue_mu.lockUncancelable(clock.io());
    g_queue_stop = true;
    const queued_at_shutdown = g_queue_len;
    g_queue_cond.signal(clock.io());
    g_queue_mu.unlock(clock.io());

    const drops = dropStats();
    const sink_inflight = g_sink_inflight_bytes.load(.acquire);
    if (drops.busy != 0 or drops.full != 0 or drops.stopped != 0 or
        drops.format != 0 or drops.shutdown_bytes != 0 or queued_at_shutdown != 0 or sink_inflight != 0)
    {
        var summary_buf: [256]u8 = undefined;
        const summary = std.fmt.bufPrint(
            &summary_buf,
            "[log] final drops: busy={d} full={d} stopped={d} format={d} shutdown_bytes={d}\n",
            .{ drops.busy, drops.full, drops.stopped, drops.format, drops.shutdown_bytes +| @as(u64, @intCast(queued_at_shutdown)) +| sink_inflight },
        ) catch "[log] final drop summary formatting failed\n";
        // The consumer may be permanently blocked in its configured sink.
        // Emit the summary synchronously only to the debugger channel before
        // detaching, so visibility does not depend on writer progress.
        outputDebug(summary);
    }
    if (g_log_thread) |thread| {
        // A synchronous file/pipe write may never return. Do not make process
        // shutdown depend on the writer; it owns the file until it exits, and
        // the OS closes both thread and file resources at process termination.
        thread.detach();
        g_log_thread = null;
    } else if (g_log_file) |f| {
        f.close(clock.io());
        g_log_file = null;
    }
}

test "logging producer drops instead of waiting for the queue mutex" {
    clock.init();
    g_queue_busy_drops.store(0, .release);
    g_queue_stop = false;

    g_queue_mu.lockUncancelable(clock.io());
    enqueue("contended");
    g_queue_mu.unlock(clock.io());

    try std.testing.expectEqual(@as(u64, 1), g_queue_busy_drops.load(.acquire));
    g_queue_busy_drops.store(0, .release);
}

test "multipart logging drops atomically when the ring is full" {
    clock.init();
    g_queue_full_drops.store(0, .release);
    g_queue_stop = false;
    g_queue_head = 0;
    g_queue_len = queue_capacity - 1;

    enqueueParts("a", "b", "c");

    try std.testing.expectEqual(queue_capacity - 1, g_queue_len);
    try std.testing.expectEqual(@as(u64, 1), g_queue_full_drops.load(.acquire));
    g_queue_head = 0;
    g_queue_len = 0;
    g_queue_full_drops.store(0, .release);
}

test "raw log filtering matches core perf and scroll-debug tiers" {
    g_perf_only.store(true, .release);
    g_scroll_only.store(false, .release);
    try std.testing.expect(shouldEmitBytes("", "[perf] flush us=1"));
    try std.testing.expect(!shouldEmitBytes("", "child stderr"));

    g_perf_only.store(false, .release);
    g_scroll_only.store(true, .release);
    try std.testing.expect(shouldEmitBytes("", "[scroll_debug] row=1"));
    try std.testing.expect(!shouldEmitBytes("", "[scrollbar] row=1"));
    try std.testing.expect(shouldEmitBytes("", "[perf_input] seq=1"));

    g_perf_only.store(false, .release);
    g_scroll_only.store(false, .release);
}

test "format overflow is observable as a drop" {
    const huge = [_]u8{'x'} ** 4097;
    g_perf_only.store(false, .release);
    g_scroll_only.store(false, .release);
    g_enabled.store(true, .release);
    const before = g_format_drops.load(.acquire);

    appLog("{s}", .{huge[0..]});

    try std.testing.expectEqual(before + 1, dropStats().format);
    g_enabled.store(false, .release);
}
