// mpack_bench.zig — decode-path micro benchmark.
//
// SCOPE: this benchmark measures the MessagePack *decode path only* —
// reading bytes into a `Value` tree. It does NOT capture end-to-end
// redraw timing, which is also influenced by flush scheduling, grid
// state updates, highlight resolution, vertex generation, and frontend
// rendering. A 1.9x slowdown on decode translates to a much smaller
// fraction of a real redraw's wall-clock. Use these numbers to reason
// about decoder design only; use instrumented end-to-end measurements
// when reasoning about user-visible latency.
//
// The Variant B/C helpers below intentionally retain references to
// `mp.decodeFromStream` after the streaming redraw bridge was removed
// from production (see the git history around the Phase 5 revert).
// Keeping this bench compilable preserves the A/B/C evidence for any
// future attempt at a handler-level streaming rewrite.
//
// Compares three decode strategies for a synthetic Neovim `redraw`
// notification frame, keeping the workload identical across variants so
// that wall-clock and allocator usage differences reflect the decoder
// design, not the payload shape:
//
//   A) old  — full `mp.decode` of the outer frame, mimicking the pre-
//             streaming rpc_session loop (PipeReader days).
//   B) new2 — current rpc_session streaming path: probe top header via
//             `InnerDecoder`, skip-validate the entire events array via
//             `skipAny`, then materialize each event via
//             `decodeFromStream`. Two passes over the payload bytes.
//   C) new1 — hypothetical simplification: same as B but without the
//             skip-validate pass. One pass; no frame-boundary guarantee.
//
// The benchmark is a `zig test` entry so it can be wired into `zig build
// bench` with `-Doptimize=ReleaseFast`. Run:
//
//     zig build bench
//
// Frame layout for the test: `[2, "redraw", [["grid_line", [2,0,0,
// [cell, cell, cell, ...]]]]]` where each cell is `[str, hl_id, repeat]`.
// This shape is intentionally close to the hot path — `grid_line` with
// many cells dominates the allocation budget in real redraws.

const std = @import("std");
const mp = @import("zonvie_core").msgpack;
const mps = @import("zonvie_core").mpack_stream;

/// Minimal slice-backed reader for driving `mp.decode` over an in-memory
/// byte buffer. Duplicates the adapter from `msgpack_test.zig` so the
/// benchmark module stays self-contained.
const SliceReader = struct {
    data: []const u8,
    i: usize = 0,

    pub fn readByte(self: *SliceReader) anyerror!u8 {
        if (self.i >= self.data.len) return error.EndOfStream;
        const b = self.data[self.i];
        self.i += 1;
        return b;
    }

    pub fn readNoEof(self: *SliceReader, buf: []u8) anyerror!void {
        if (self.i + buf.len > self.data.len) return error.EndOfStream;
        @memcpy(buf, self.data[self.i .. self.i + buf.len]);
        self.i += buf.len;
    }
};

// ---------------------------------------------------------------------------
// Synthetic frame builder.
// ---------------------------------------------------------------------------

fn writeArrayHead(buf: *std.ArrayListUnmanaged(u8), alloc: std.mem.Allocator, count: u32) !void {
    if (count <= 15) {
        try buf.append(alloc, 0x90 | @as(u8, @intCast(count)));
    } else if (count <= std.math.maxInt(u16)) {
        try buf.append(alloc, 0xdc);
        try buf.append(alloc, @intCast((count >> 8) & 0xFF));
        try buf.append(alloc, @intCast(count & 0xFF));
    } else {
        try buf.append(alloc, 0xdd);
        try buf.append(alloc, @intCast((count >> 24) & 0xFF));
        try buf.append(alloc, @intCast((count >> 16) & 0xFF));
        try buf.append(alloc, @intCast((count >> 8) & 0xFF));
        try buf.append(alloc, @intCast(count & 0xFF));
    }
}

fn writeFixStr(buf: *std.ArrayListUnmanaged(u8), alloc: std.mem.Allocator, s: []const u8) !void {
    std.debug.assert(s.len <= 31);
    try buf.append(alloc, 0xa0 | @as(u8, @intCast(s.len)));
    try buf.appendSlice(alloc, s);
}

/// Build a single-event redraw notification with a `grid_line` carrying
/// `n_cells` cells. Returns an owned byte slice that the caller must free.
fn buildGridLineFrame(alloc: std.mem.Allocator, n_cells: u32) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(alloc);

    // Top array: [msg_type, method, params]
    try writeArrayHead(&buf, alloc, 3);
    try buf.append(alloc, 0x02); // msg_type = 2 (notification)
    try writeFixStr(&buf, alloc, "redraw");

    // params: [event1]
    try writeArrayHead(&buf, alloc, 1);

    // event1: ["grid_line", tuple1]
    try writeArrayHead(&buf, alloc, 2);
    try writeFixStr(&buf, alloc, "grid_line");

    // tuple1: [grid_id, row, col, cells]
    try writeArrayHead(&buf, alloc, 4);
    try buf.append(alloc, 0x02); // grid_id = 2
    try buf.append(alloc, 0x00); // row = 0
    try buf.append(alloc, 0x00); // col = 0

    // cells: array of n_cells
    try writeArrayHead(&buf, alloc, n_cells);

    // Each cell: ["a", 10, 1] — [str, hl_id, repeat]
    var i: u32 = 0;
    while (i < n_cells) : (i += 1) {
        try writeArrayHead(&buf, alloc, 3);
        try buf.append(alloc, 0xa1);
        try buf.append(alloc, 'a');
        try buf.append(alloc, 0x0a);
        try buf.append(alloc, 0x01);
    }

    return try buf.toOwnedSlice(alloc);
}

// ---------------------------------------------------------------------------
// Three decode variants under test.
// ---------------------------------------------------------------------------

/// Variant A — pre-streaming behaviour. Materialize the whole frame into
/// a `Value` tree via `mp.decode`.
fn runOld(arena: std.mem.Allocator, bytes: []const u8) !void {
    var sr = SliceReader{ .data = bytes };
    const root = try mp.decode(arena, &sr);
    std.mem.doNotOptimizeAway(root);
}

/// Variant B — current rpc_session streaming path with skip-validate.
fn runNew2Pass(arena: std.mem.Allocator, bytes: []const u8) !void {
    var p = mps.InnerDecoder{ .data = bytes };
    _ = try p.expectArray(); // top array length (3)
    _ = try p.expectUInt(); // msg_type
    _ = try p.expectString(); // "redraw"
    const n_events = try p.expectArray();

    // skip-validate pass
    var probe2 = p;
    try probe2.skipAny(n_events);

    // materialize pass
    const params = try arena.alloc(mp.Value, n_events);
    var i: u32 = 0;
    while (i < n_events) : (i += 1) {
        params[i] = try mp.decodeFromStream(arena, &p);
    }
    std.mem.doNotOptimizeAway(params);
}

/// Variant C — same as B but without skip-validate. One pass only.
fn runNew1Pass(arena: std.mem.Allocator, bytes: []const u8) !void {
    var p = mps.InnerDecoder{ .data = bytes };
    _ = try p.expectArray();
    _ = try p.expectUInt();
    _ = try p.expectString();
    const n_events = try p.expectArray();

    const params = try arena.alloc(mp.Value, n_events);
    var i: u32 = 0;
    while (i < n_events) : (i += 1) {
        params[i] = try mp.decodeFromStream(arena, &p);
    }
    std.mem.doNotOptimizeAway(params);
}

// ---------------------------------------------------------------------------
// Harness.
// ---------------------------------------------------------------------------

const Variant = struct {
    name: []const u8,
    fun: *const fn (std.mem.Allocator, []const u8) anyerror!void,
};

/// Returns `{ ns_per_iter, peak_arena_bytes }` for `n_iter` invocations of
/// `variant` on `bytes`. The arena is reset (retain_capacity) between
/// iterations so that per-frame allocations are reclaimed — matching the
/// rpc_session run loop's lifecycle — while the capacity grown by the
/// first iteration survives and reflects steady-state memory cost.
fn bench(
    backing_alloc: std.mem.Allocator,
    variant: Variant,
    bytes: []const u8,
    n_warmup: u32,
    n_iter: u32,
) !struct { ns_per_iter: u64, peak_bytes: usize } {
    var arena_state = std.heap.ArenaAllocator.init(backing_alloc);
    defer arena_state.deinit();

    // Warmup to stabilise caches and arena backing.
    var w: u32 = 0;
    while (w < n_warmup) : (w += 1) {
        _ = arena_state.reset(.retain_capacity);
        try variant.fun(arena_state.allocator(), bytes);
    }

    // Snapshot steady-state arena capacity. This is a lower-bound proxy
    // for peak allocation — the arena only retains what it needed.
    const peak_bytes = arena_state.queryCapacity();

    var timer = try std.time.Timer.start();
    var i: u32 = 0;
    while (i < n_iter) : (i += 1) {
        _ = arena_state.reset(.retain_capacity);
        try variant.fun(arena_state.allocator(), bytes);
    }
    const elapsed_ns = timer.read();
    return .{
        .ns_per_iter = elapsed_ns / n_iter,
        .peak_bytes = peak_bytes,
    };
}

test "bench: redraw grid_line decode paths" {
    const gpa = std.heap.page_allocator;

    const variants = [_]Variant{
        .{ .name = "A old  (mp.decode)       ", .fun = runOld },
        .{ .name = "B new  (probe+skip+decde)", .fun = runNew2Pass },
        .{ .name = "C new  (probe+decode)    ", .fun = runNew1Pass },
    };

    const sizes = [_]u32{ 10, 100, 1000, 10000 };

    std.debug.print("\n\n=== mpack decode bench (ns/iter, arena peak bytes) ===\n", .{});
    std.debug.print("(Built with the active optimize mode; use `zig build bench` for ReleaseFast)\n", .{});

    for (sizes) |n_cells| {
        const bytes = try buildGridLineFrame(gpa, n_cells);
        defer gpa.free(bytes);

        std.debug.print("\n--- n_cells = {d:<6} frame = {d} bytes ---\n", .{ n_cells, bytes.len });

        // Size iteration count down as frames grow — keep total wall time
        // per row in the seconds range.
        const n_iter: u32 = if (n_cells <= 100) 50_000 else if (n_cells <= 1000) 5_000 else 500;
        const n_warmup: u32 = @max(10, n_iter / 50);

        var baseline_ns: u64 = 0;
        for (variants, 0..) |v, idx| {
            const r = try bench(gpa, v, bytes, n_warmup, n_iter);
            if (idx == 0) baseline_ns = r.ns_per_iter;

            const ratio: f64 = if (baseline_ns != 0)
                @as(f64, @floatFromInt(r.ns_per_iter)) / @as(f64, @floatFromInt(baseline_ns))
            else
                1.0;

            std.debug.print("  {s}  {d:>10} ns/iter   {d:>10} B peak   ({d:.2}x vs A)\n", .{
                v.name, r.ns_per_iter, r.peak_bytes, ratio,
            });
        }
    }
    std.debug.print("\n", .{});
}
