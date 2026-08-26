// app_log.zig — read the running app's `--log` file and measure how
// regularly a given log marker appears.
//
// The renderer stamps every line with the app's own millisecond clock
// (`[zonvie] [ 17067.965ms] ...`), so the log doubles as a frame-cadence
// trace: `[draw] draw(in:) called` is emitted once per main-window
// draw(in:). A scenario that puts the renderer into animated-shader mode
// (a frame every vsync) can therefore assert on the LARGEST gap between
// consecutive draws — the number a user perceives as the animation
// freezing.
//
// Test-only code: heap allocation and whole-file reads are fine here.

const std = @import("std");
const gui_io = @import("gui_io.zig");

/// Marker emitted once per main-window draw(in:).
pub const main_draw_marker = "[draw] draw(in:) called";

/// Marker proving the renderer entered animated-shader mode.
pub const animated_shader_marker = "anyNeedsAnimation=true";

const max_log_bytes = 256 * 1024 * 1024;

/// Parse the app clock (in milliseconds) out of one log line.
/// Lines look like `[zonvie] [ 1234.567ms] rest…`; anything else -> null.
fn lineTimestampMs(line: []const u8) ?f64 {
    const prefix = "[zonvie] [";
    if (!std.mem.startsWith(u8, line, prefix)) return null;
    const rest = line[prefix.len..];
    const close = std.mem.indexOf(u8, rest, "ms]") orelse return null;
    const num = std.mem.trim(u8, rest[0..close], " ");
    return std.fmt.parseFloat(f64, num) catch null;
}

/// Largest gap, in ms, between consecutive `marker` lines stamped at or
/// after `since_ms`. Also reports how many samples were considered, so a
/// scenario can tell "the loop ran smoothly" apart from "the loop never
/// ran at all" — both of which otherwise produce a zero gap.
pub const Cadence = struct {
    samples: usize = 0,
    max_gap_ms: f64 = 0,
    /// Clock of the draw that started the largest gap (0 when samples < 2).
    gap_start_ms: f64 = 0,
    first_ms: f64 = 0,
    last_ms: f64 = 0,

    pub fn report(self: Cadence, label: []const u8) void {
        std.debug.print(
            "[gui] {s}: draws={d} span={d:.0}..{d:.0}ms max_gap={d:.1}ms @{d:.0}ms\n",
            .{ label, self.samples, self.first_ms, self.last_ms, self.max_gap_ms, self.gap_start_ms },
        );
    }
};

pub fn cadence(alloc: std.mem.Allocator, path: []const u8, marker: []const u8, since_ms: f64) !Cadence {
    const data = try std.Io.Dir.cwd().readFileAlloc(gui_io.io(), path, alloc, .limited(max_log_bytes));
    defer alloc.free(data);

    var out: Cadence = .{};
    // Seeded with the last sample BEFORE the window: a stall that starts
    // just before since_ms and ends inside it is exactly the kind this
    // measures, and it would be invisible if the first in-window sample had
    // nothing to be compared against.
    var prev: ?f64 = null;
    var it = std.mem.splitScalar(u8, data, '\n');
    while (it.next()) |line| {
        if (std.mem.indexOf(u8, line, marker) == null) continue;
        const ts = lineTimestampMs(line) orelse continue;
        if (ts < since_ms) {
            prev = ts;
            continue;
        }
        if (out.samples == 0) out.first_ms = ts;
        out.last_ms = ts;
        out.samples += 1;
        if (prev) |p| {
            const gap = ts - p;
            if (gap > out.max_gap_ms) {
                out.max_gap_ms = gap;
                out.gap_start_ms = p;
            }
        }
        prev = ts;
    }
    return out;
}

/// Clock of the most recent timestamped line — the app-side "now" a
/// scenario uses to start a measurement window.
pub fn nowMs(alloc: std.mem.Allocator, path: []const u8) !f64 {
    const data = try std.Io.Dir.cwd().readFileAlloc(gui_io.io(), path, alloc, .limited(max_log_bytes));
    defer alloc.free(data);

    var last: f64 = 0;
    var it = std.mem.splitScalar(u8, data, '\n');
    while (it.next()) |line| {
        if (lineTimestampMs(line)) |ts| last = ts;
    }
    return last;
}

/// True once `marker` appears anywhere in the log.
pub fn contains(alloc: std.mem.Allocator, path: []const u8, marker: []const u8) !bool {
    return containsSince(alloc, path, marker, 0);
}

/// True once `marker` appears on a line stamped at or after `since_ms`.
/// Scenarios that assert "this happened because of the step I just ran"
/// must use this: the unfiltered form is satisfied by any occurrence from
/// app startup, which quietly turns the assertion into a no-op.
pub fn containsSince(alloc: std.mem.Allocator, path: []const u8, marker: []const u8, since_ms: f64) !bool {
    const data = try std.Io.Dir.cwd().readFileAlloc(gui_io.io(), path, alloc, .limited(max_log_bytes));
    defer alloc.free(data);
    var it = std.mem.splitScalar(u8, data, '\n');
    while (it.next()) |line| {
        if (std.mem.indexOf(u8, line, marker) == null) continue;
        if (since_ms == 0) return true;
        const ts = lineTimestampMs(line) orelse continue;
        if (ts >= since_ms) return true;
    }
    return false;
}

/// The most recent line containing `marker` stamped at or after
/// `since_ms`, or null. Caller owns the returned slice. Used by scenarios
/// that assert on a VALUE the app logged, not merely that it logged.
pub fn lastLineSince(alloc: std.mem.Allocator, path: []const u8, marker: []const u8, since_ms: f64) !?[]u8 {
    const data = try std.Io.Dir.cwd().readFileAlloc(gui_io.io(), path, alloc, .limited(max_log_bytes));
    defer alloc.free(data);

    var found: ?[]const u8 = null;
    var it = std.mem.splitScalar(u8, data, '\n');
    while (it.next()) |line| {
        if (std.mem.indexOf(u8, line, marker) == null) continue;
        const ts = lineTimestampMs(line) orelse continue;
        if (ts < since_ms) continue;
        found = line;
    }
    const line = found orelse return null;
    return try alloc.dupe(u8, line);
}

/// Parse `<name>=<float>` out of a log line. Null when absent or malformed,
/// so a scenario fails on a changed log format instead of on a zero.
pub fn field(line: []const u8, name: []const u8) ?f64 {
    var buf: [64]u8 = undefined;
    const key = std.fmt.bufPrint(&buf, " {s}=", .{name}) catch return null;
    const at = std.mem.indexOf(u8, line, key) orelse return null;
    const rest = line[at + key.len ..];
    var end: usize = 0;
    while (end < rest.len and rest[end] != ' ' and rest[end] != '\r') : (end += 1) {}
    return std.fmt.parseFloat(f64, rest[0..end]) catch null;
}

/// Every line containing `marker` stamped at or after `since_ms`, joined
/// with newlines. Caller owns the slice. Used by scenarios that check an
/// invariant across a whole gesture rather than a single sample.
pub fn linesSince(alloc: std.mem.Allocator, path: []const u8, marker: []const u8, since_ms: f64) ![]u8 {
    const data = try std.Io.Dir.cwd().readFileAlloc(gui_io.io(), path, alloc, .limited(max_log_bytes));
    defer alloc.free(data);

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(alloc);
    var it = std.mem.splitScalar(u8, data, '\n');
    while (it.next()) |line| {
        if (std.mem.indexOf(u8, line, marker) == null) continue;
        const ts = lineTimestampMs(line) orelse continue;
        if (ts < since_ms) continue;
        try out.appendSlice(alloc, line);
        try out.append(alloc, '\n');
    }
    return out.toOwnedSlice(alloc);
}

/// Poll until `marker` shows up, so a scenario can wait for app-side
/// state (e.g. "the custom shader finished loading") instead of sleeping.
pub fn waitFor(alloc: std.mem.Allocator, path: []const u8, marker: []const u8, timeout_ms: u64) !void {
    var timer = gui_io.Timer.start();
    while (true) {
        if (contains(alloc, path, marker) catch false) return;
        if (timer.read() / std.time.ns_per_ms >= timeout_ms) {
            std.debug.print("[gui] app log never contained \"{s}\"\n", .{marker});
            return error.Timeout;
        }
        gui_io.sleepNs(100 * std.time.ns_per_ms);
    }
}

test "field parses a named float out of a log line" {
    const line = "[zonvie] [ 123.000ms] [ext_cursor_shader] gridId=4 x=612.0 y=880.0 w=18.0 h=40.0";
    try std.testing.expectEqual(@as(?f64, 612.0), field(line, "x"));
    try std.testing.expectEqual(@as(?f64, 880.0), field(line, "y"));
    try std.testing.expectEqual(@as(?f64, 40.0), field(line, "h"));
    try std.testing.expectEqual(@as(?f64, null), field(line, "nope"));
}

test "lineTimestampMs parses the app clock" {
    try std.testing.expectEqual(@as(?f64, 17067.965), lineTimestampMs("[zonvie] [17067.965ms] [draw] draw(in:) called"));
    try std.testing.expectEqual(@as(?f64, 582.462), lineTimestampMs("[zonvie] [  582.462ms] [draw] draw(in:) called"));
    try std.testing.expectEqual(@as(?f64, null), lineTimestampMs("not a zonvie line"));
    try std.testing.expectEqual(@as(?f64, null), lineTimestampMs(""));
}
