//! Input-to-paint latency, for comparing renderers (ZONVIE_LATENCY_BENCH=N).
//! A timer types into Neovim through the same core input path as a key; a
//! sample runs from that send to the main frame clock's after-paint of the
//! first frame showing a commit made after it. Both renderers report the
//! commit they handed to GTK in App.presented_seq, so they are timed at the
//! same point. After N samples (past a warm-up) the stats go to stderr and
//! the app quits without saving. GTK main thread only.

const std = @import("std");
const core = @import("zonvie_core");
const clock = core.clock;
const App = @import("app.zig").App;
const gtk = @import("gtk_bindings.zig");

const interval_ms = 60;
const warmup = 20;
/// A sample that never paints (Neovim swallowed the key) is dropped.
const timeout_ns: i128 = std.time.ns_per_s;

pub const Bench = struct {
    app: *App,
    renderer: []const u8,
    wanted: usize,
    samples: []u64,
    n: usize = 0,
    seen: usize = 0,
    waiting: bool = false,
    t0_ns: i128 = 0,
    base_seq: u64 = 0,
    flip: bool = false,
    started: bool = false,
};

var bench_state: ?*Bench = null;

/// Reads ZONVIE_LATENCY_BENCH; arms the bench when it names a sample count.
pub fn init(app: *App, renderer: []const u8) void {
    const v = std.c.getenv("ZONVIE_LATENCY_BENCH") orelse return;
    const n = std.fmt.parseInt(usize, std.mem.span(v), 10) catch return;
    if (n == 0) return;
    const b = app.alloc.create(Bench) catch return;
    const samples = app.alloc.alloc(u64, n) catch {
        app.alloc.destroy(b);
        return;
    };
    b.* = .{ .app = app, .renderer = renderer, .wanted = n, .samples = samples };
    bench_state = b;
    // Long enough for Neovim to attach and the first frames to settle.
    _ = gtk.g_timeout_add(1500, &onStart, b);
}

pub fn deinit(app: *App) void {
    const b = bench_state orelse return;
    app.alloc.free(b.samples);
    app.alloc.destroy(b);
    bench_state = null;
}

fn onStart(data: ?*anyopaque) callconv(.c) c_int {
    const b: *Bench = @ptrCast(@alignCast(data.?));
    const widget = b.app.frame_widget orelse return 0;
    const fc = gtk.gtk_widget_get_frame_clock(widget) orelse return 0;
    _ = gtk.g_signal_connect(fc, "after-paint", @ptrCast(&onAfterPaint), b);
    const cp = b.app.corep orelse return 0;
    core.zonvie_core_send_input(cp, "i", 1);
    b.started = true;
    _ = gtk.g_timeout_add(interval_ms, &onTick, b);
    return 0;
}

fn flushSeq(app: *App) u64 {
    app.mu.lockUncancelable(clock.io());
    defer app.mu.unlock(clock.io());
    return app.flush_seq;
}

fn onTick(data: ?*anyopaque) callconv(.c) c_int {
    const b: *Bench = @ptrCast(@alignCast(data.?));
    const cp = b.app.corep orelse return 0;
    const now = clock.nowNs();
    if (b.waiting and now - b.t0_ns < timeout_ns) return 1;
    b.waiting = true;
    b.base_seq = flushSeq(b.app);
    b.t0_ns = clock.nowNs();
    // Typing and erasing keeps the line short, so every sample redraws one row.
    const key: []const u8 = if (b.flip) "<BS>" else "x";
    b.flip = !b.flip;
    core.zonvie_core_send_input(cp, key.ptr, key.len);
    return 1;
}

fn onAfterPaint(frame_clock: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    _ = frame_clock;
    const b: *Bench = @ptrCast(@alignCast(data.?));
    if (!b.waiting or b.app.presented_seq <= b.base_seq) return;
    const now_ns = clock.nowNs();
    const dt_ns = now_ns - b.t0_ns;
    if (@import("app_log.zig").isEnabled()) @import("app_log.zig").appLog("[perf] bench present_to_paint_us={d}\n", .{@divTrunc(now_ns - b.app.presented_ns, 1000)});
    b.waiting = false;
    // A frame held back for longer (an occluded window gets no frame
    // callbacks) measures the compositor, not the renderer.
    if (dt_ns > timeout_ns) return;
    const dt: u64 = @intCast(dt_ns);
    b.seen += 1;
    if (b.seen <= warmup) return;
    b.samples[b.n] = dt;
    b.n += 1;
    if (b.n == b.wanted) finish(b);
}

fn finish(b: *Bench) void {
    const s = b.samples[0..b.n];
    std.mem.sort(u64, s, {}, std.sort.asc(u64));
    var sum: u128 = 0;
    for (s) |x| sum += x;
    const us = struct {
        fn f(ns: u64) f64 {
            return @as(f64, @floatFromInt(ns)) / 1000.0;
        }
    }.f;
    std.debug.print("latency_bench renderer={s} n={d} mean_us={d:.0} p50_us={d:.0} p95_us={d:.0} min_us={d:.0} max_us={d:.0}\n", .{
        b.renderer,
        s.len,
        @as(f64, @floatFromInt(sum)) / @as(f64, @floatFromInt(s.len)) / 1000.0,
        us(s[s.len / 2]),
        us(s[@min(s.len - 1, s.len * 95 / 100)]),
        us(s[0]),
        us(s[s.len - 1]),
    });
    if (b.app.corep) |cp| core.zonvie_core_quit_confirmed(cp, 1);
}
