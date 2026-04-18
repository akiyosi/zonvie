// mpack_bench.zig — redraw decode-path and full-path micro benchmarks.
//
// Two independent `test`-blocks:
//
//   1. "bench: redraw grid_line decode paths" — isolates the decoder
//      alone and compares `mp.decode` vs `InnerDecoder + decodeFromStream`.
//   2. "bench: redraw full-path (old ... vs new handleRedrawStream)" —
//      measures the full redraw pipeline including `grid.putCell`,
//      dirty tracking, and a noop flush callback.
//
// SCOPE AND GATE HISTORY
// ----------------------
// Both benches are unwired from production: they exist to evaluate
// streaming-decoder designs without requiring a live Neovim. A
// "streaming fast path" for redraw notifications was prototyped on top
// of `handleRedrawStream`, wired into rpc_session, and measured here.
// The gate criterion was "new full-path faster than old on this bench".
//
// Result (Apple Silicon, ReleaseFast):
//
//   n_cells = 100     old  2190 ns/iter   new  3119 ns/iter  (1.42x)
//   n_cells = 1000    old 21222 ns/iter   new 29908 ns/iter  (1.41x)
//   n_cells = 10000   old 216834 ns/iter  new 293443 ns/iter (1.35x)
//
//   arena peak bytes: old 14 KiB / 254 KiB / 2.3 MiB respectively;
//                     new  0 / 0 / 0 (streamGridLine doesn't alloc).
//
// The new path LOST on wall-clock by ~1.35x-1.42x despite eliminating
// per-cell `Value` allocation entirely. Root cause: the
// `InnerDecoder.readHead -> ValueHead union -> switch` abstraction
// costs more per cell than `mp.decode`'s direct byte-to-Value
// dispatch, and the savings from skipping arena allocs are smaller
// than that overhead at grid_line cell counts typical on this bench.
// The behaviour flip was reverted; handleRedrawStream and its bridge
// helper remain in the tree as unwired reference implementations,
// and this bench stays as the baseline that any future attempt must
// beat. A future attempt is likely to succeed only by dropping the
// generic ValueHead layer in favour of a grid_line-specific
// tag-byte direct parser.
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
const zc = @import("zonvie_core");
const mp = zc.msgpack;
const mps = zc.mpack_stream;
const redraw = zc.redraw_handler;
const Grid = zc.grid_mod.Grid;
const Highlights = zc.highlight.Highlights;
const Logger = zc.log_mod.Logger;

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

// ---------------------------------------------------------------------------
// Full-path bench. In contrast to the decode-only suite above, this one
// measures the entire redraw pipeline per frame:
//
//   old: mp.decode(arena, bytes) → extract params → handleRedraw (walks
//        the Value tree, calls grid.putCell for every cell, marks dirty,
//        and runs frontend callbacks)
//   new: InnerDecoder → probeRedrawFrame equivalent → skipAny validate →
//        handleRedrawStream (streams grid_line cells directly into the
//        grid; other events materialise one at a time via the bridge)
//
// Both variants write into an identically-sized fresh `Grid` and
// `Highlights`, using noop callback stubs. A fresh Grid/Highlights is
// allocated per iteration so the workload stays representative —
// re-running against an already-populated grid would let `putCell`'s
// early-return short-circuit the hot path and measure nothing.
// Timer.read() is sampled around the variant call only, excluding the
// Grid init / resize / deinit overhead from the measurement.
// ---------------------------------------------------------------------------

const NoopCtx = struct {};

fn noopFlush(_: *NoopCtx, _: u32, _: u32) anyerror!void {}
fn noopGuifont(_: *NoopCtx, _: []const u8) anyerror!void {}
fn noopLinespace(_: *NoopCtx, _: i32) anyerror!void {}
fn noopSetTitle(_: *NoopCtx, _: []const u8) anyerror!void {}
fn noopDefaultColors(_: *NoopCtx, _: u32, _: u32) anyerror!void {}

fn runOldFull(
    arena: std.mem.Allocator,
    bytes: []const u8,
    grid: *Grid,
    hl: *Highlights,
    log: *Logger,
    ctx: *NoopCtx,
) !void {
    var sr = SliceReader{ .data = bytes };
    const root = try mp.decode(arena, &sr);
    if (root != .arr) return error.Malformed;
    const top = root.arr;
    if (top.len < 3 or top[2] != .arr) return error.Malformed;
    const params = top[2].arr;

    try redraw.handleRedraw(
        grid,
        hl,
        arena,
        params,
        log,
        ctx,
        noopFlush,
        ctx,
        noopGuifont,
        ctx,
        noopLinespace,
        noopSetTitle,
        noopDefaultColors,
    );
}

fn runNewFull(
    arena: std.mem.Allocator,
    bytes: []const u8,
    grid: *Grid,
    hl: *Highlights,
    log: *Logger,
    ctx: *NoopCtx,
) !void {
    var in = mps.InnerDecoder{ .data = bytes };
    _ = try in.expectArray(); // top = 3
    _ = try in.expectUInt(); // msg_type = 2
    _ = try in.expectString(); // "redraw"
    const n_events = try in.expectArray();

    // Skip-validate pass, mirroring what rpc_session's main loop does.
    var v = in;
    try v.skipAny(n_events);

    try redraw.handleRedrawStream(
        grid,
        hl,
        arena,
        &in,
        n_events,
        log,
        ctx,
        noopFlush,
        ctx,
        noopGuifont,
        ctx,
        noopLinespace,
        noopSetTitle,
        noopDefaultColors,
    );
}

fn benchFull(
    backing_alloc: std.mem.Allocator,
    comptime variant_fn: fn (std.mem.Allocator, []const u8, *Grid, *Highlights, *Logger, *NoopCtx) anyerror!void,
    bytes: []const u8,
    rows: u32,
    cols: u32,
    n_warmup: u32,
    n_iter: u32,
) !struct { ns_per_iter: u64, peak_arena_bytes: usize } {
    var arena_state = std.heap.ArenaAllocator.init(backing_alloc);
    defer arena_state.deinit();

    var log: Logger = .{};
    var ctx = NoopCtx{};

    // Warmup — populates arena capacity too.
    {
        var w: u32 = 0;
        while (w < n_warmup) : (w += 1) {
            var grid = Grid.init(backing_alloc);
            defer grid.deinit();
            try grid.resize(rows, cols);
            var hl = Highlights.init(backing_alloc);
            defer hl.deinit();
            _ = arena_state.reset(.retain_capacity);
            try variant_fn(arena_state.allocator(), bytes, &grid, &hl, &log, &ctx);
        }
    }

    const peak = arena_state.queryCapacity();

    // Timed loop. Grid/Highlights init/resize/deinit overhead is
    // excluded from the wall-clock sample by bracketing the timer
    // around just the variant call. Both variants incur the same
    // setup/teardown, so absolute numbers exclude that noise.
    var total_ns: u64 = 0;
    var i: u32 = 0;
    while (i < n_iter) : (i += 1) {
        var grid = Grid.init(backing_alloc);
        defer grid.deinit();
        try grid.resize(rows, cols);
        var hl = Highlights.init(backing_alloc);
        defer hl.deinit();
        _ = arena_state.reset(.retain_capacity);

        var timer = try std.time.Timer.start();
        try variant_fn(arena_state.allocator(), bytes, &grid, &hl, &log, &ctx);
        total_ns += timer.read();
    }

    return .{
        .ns_per_iter = total_ns / n_iter,
        .peak_arena_bytes = peak,
    };
}

test "bench: redraw full-path (old mp.decode+handleRedraw vs new handleRedrawStream)" {
    const gpa = std.heap.page_allocator;

    // Grid must be large enough to hold the widest cell count in the
    // workload. `buildGridLineFrame` writes all cells into row 0, so
    // `rows = 2` suffices; columns must be >= n_cells.
    const Workload = struct { n_cells: u32, rows: u32, cols: u32, n_iter: u32 };
    const workloads = [_]Workload{
        .{ .n_cells = 100, .rows = 2, .cols = 200, .n_iter = 20_000 },
        .{ .n_cells = 1000, .rows = 2, .cols = 1200, .n_iter = 2_000 },
        .{ .n_cells = 10000, .rows = 2, .cols = 12000, .n_iter = 200 },
    };

    std.debug.print("\n\n=== redraw full-path bench (old vs new; ns/iter, arena peak B) ===\n", .{});
    std.debug.print("(decode + grid.putCell + dirty tracking + noop flush; excludes Grid/Highlights setup)\n", .{});

    for (workloads) |w| {
        const bytes = try buildGridLineFrame(gpa, w.n_cells);
        defer gpa.free(bytes);

        std.debug.print("\n--- n_cells = {d:<6} frame = {d} bytes  grid = {d}x{d}  iters = {d} ---\n", .{
            w.n_cells, bytes.len, w.rows, w.cols, w.n_iter,
        });

        const n_warmup: u32 = @max(10, w.n_iter / 50);

        const r_old = try benchFull(gpa, runOldFull, bytes, w.rows, w.cols, n_warmup, w.n_iter);
        const r_new = try benchFull(gpa, runNewFull, bytes, w.rows, w.cols, n_warmup, w.n_iter);

        const ratio = @as(f64, @floatFromInt(r_new.ns_per_iter)) /
            @as(f64, @floatFromInt(r_old.ns_per_iter));

        std.debug.print("  old  {d:>10} ns/iter   {d:>10} B peak\n", .{ r_old.ns_per_iter, r_old.peak_arena_bytes });
        std.debug.print("  new  {d:>10} ns/iter   {d:>10} B peak   ({d:.2}x vs old)\n", .{
            r_new.ns_per_iter, r_new.peak_arena_bytes, ratio,
        });
    }
    std.debug.print("\n", .{});
}
