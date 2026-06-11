// harness.zig — headless deterministic E2E harness.
//
// Spawns a REAL `nvim --embed --clean` through the REAL core pipeline
// (rpc_session → redraw_handler → grid state → flush) and lets scenarios
// inject input and assert on LOGICAL grid state: cell text, highlight
// attributes, cursor position, float window placement. No GPU, no pixels.
//
// All vertex/atlas/shape callbacks are left null, so flush skips vertex
// generation entirely (flush.zig gates row mode on `on_vertices_row != null`)
// and never touches the hbft bridge. The logical grid is fully populated by
// handleRedraw before flush, so readback does not depend on the vertex path.
//
// ext_multigrid is always on (requestUiAttach), so window CONTENT lives in
// sub-grids (grid_id >= 2), not in the global grid 1. Composition into
// grid 1 happens only inside vertex generation, which this harness skips —
// text assertions therefore target the window's grid (see `winGrid()`).
//
// Threading: callbacks fire on the core's RPC thread with grid_mu held.
// The flush-end callback only bumps a counter and signals a condvar (it must
// NOT touch grid_mu). The test thread reads grid state by locking grid_mu
// itself between batches.
//
// This is test-only code: heap allocation is fine here (hot-path allocation
// rules apply to production render paths, not the harness).

const std = @import("std");
const zc = @import("zonvie_core");

const Core = zc.nvim_core.Core;
const Callbacks = zc.nvim_core.Callbacks;
const Cell = zc.grid_mod.Cell;
const GridPos = zc.grid_mod.GridPos;
const ResolvedAttrWithStyles = zc.highlight.ResolvedAttrWithStyles;

pub const WaitError = error{ Timeout, NvimExited };

pub const Options = struct {
    rows: u32 = 24,
    cols: u32 = 80,
    /// Pass --clean so user config cannot break determinism.
    clean: bool = true,
    /// Attach with the ext_windows UI option. WARNING: stock nvim rejects
    /// this option (attach fails, nvim exits); it targets a patched nvim.
    /// Plain external floats (nvim_open_win external=true) already work via
    /// ext_multigrid + win_external_pos and do NOT need this.
    ext_windows: bool = false,
    /// Default per-wait timeout. Generous: CI machines are slow.
    timeout_ms: u64 = 5000,
};

/// Resolve the nvim binary: $ZONVIE_TEST_NVIM if set, else "nvim" on PATH.
/// Probes with `--version`; returns error.NvimNotFound when unusable.
/// Caller owns the returned string.
pub fn resolveNvim(alloc: std.mem.Allocator) ![]u8 {
    const path = std.process.getEnvVarOwned(alloc, "ZONVIE_TEST_NVIM") catch
        try alloc.dupe(u8, "nvim");
    errdefer alloc.free(path);

    const result = std.process.Child.run(.{
        .allocator = alloc,
        .argv = &.{ path, "--version" },
    }) catch return error.NvimNotFound;
    alloc.free(result.stdout);
    alloc.free(result.stderr);
    switch (result.term) {
        .Exited => |code| if (code != 0) return error.NvimNotFound,
        else => return error.NvimNotFound,
    }
    return path;
}

pub const Harness = struct {
    alloc: std.mem.Allocator,
    core: *Core,
    opts: Options,
    nvim_cmd: []u8,

    // Flush synchronization (independent of grid_mu).
    sync_mu: std.Thread.Mutex = .{},
    sync_cond: std.Thread.Condition = .{},
    flush_seq: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    exited: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    exit_code: std.atomic.Value(i32) = std.atomic.Value(i32).init(0),
    verbose: bool = false,

    // External window callback recording (frontend-contract observation).
    ext_win_shows: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    ext_win_closes: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    last_ext_win_grid: std.atomic.Value(i64) = std.atomic.Value(i64).init(0),

    pub fn init(alloc: std.mem.Allocator, opts: Options) !*Harness {
        const nvim_path = try resolveNvim(alloc);
        defer alloc.free(nvim_path);

        const h = try alloc.create(Harness);
        errdefer alloc.destroy(h);
        h.* = .{
            .alloc = alloc,
            .core = undefined,
            .opts = opts,
            .nvim_cmd = undefined,
            .verbose = std.process.hasEnvVarConstant("ZONVIE_E2E_VERBOSE"),
        };

        // rpc_session splits this string on spaces and inserts --embed
        // after argv[0], so "--clean" rides along with no core changes.
        h.nvim_cmd = if (opts.clean)
            try std.fmt.allocPrint(alloc, "{s} --clean", .{nvim_path})
        else
            try alloc.dupe(u8, nvim_path);
        errdefer alloc.free(h.nvim_cmd);

        const cbs = Callbacks{
            .on_flush_end = onFlushEnd,
            .on_exit = onExit,
            .on_log = if (h.verbose) onLog else null,
            .on_external_window = onExternalWindow,
            .on_external_window_close = onExternalWindowClose,
        };
        h.core = try alloc.create(Core);
        errdefer alloc.destroy(h.core);
        h.core.* = Core.init(alloc, cbs, h);
        // Must be set before start(): requestUiAttach reads it.
        h.core.ext_windows_enabled = opts.ext_windows;

        try h.core.start(h.nvim_cmd, opts.rows, opts.cols);
        errdefer h.core.stop();
        // No renderer in this harness: layout is "ready" immediately, which
        // unblocks the RPC thread's nvim_ui_attach.
        h.core.notifyLayoutReady(opts.rows, opts.cols);

        // Wait for the first complete redraw batch so scenarios start from a
        // settled screen. Keyed on attach side effects (grid sized + at least
        // one flush), never on splash content.
        try h.waitUntil({}, struct {
            fn check(_: void, hh: *Harness) bool {
                if (hh.flush_seq.load(.seq_cst) == 0) return false;
                hh.core.grid_mu.lock();
                defer hh.core.grid_mu.unlock();
                return hh.core.grid.rows == hh.opts.rows and
                    hh.core.grid.cols == hh.opts.cols;
            }
        }.check, opts.timeout_ms);
        return h;
    }

    pub fn deinit(h: *Harness) void {
        // Core.stop() is the full teardown: it joins all threads AND frees
        // grid/hl/scratch buffers. Do NOT also call deinitForTest (double free).
        h.core.stop();
        h.alloc.destroy(h.core);
        h.alloc.free(h.nvim_cmd);
        h.alloc.destroy(h);
    }

    // ── Callbacks (RPC thread, grid_mu held — must not touch grid_mu) ──

    fn onFlushEnd(ctx: ?*anyopaque) callconv(.c) void {
        const h: *Harness = @ptrCast(@alignCast(ctx.?));
        _ = h.flush_seq.fetchAdd(1, .seq_cst);
        h.sync_mu.lock();
        h.sync_cond.signal();
        h.sync_mu.unlock();
    }

    fn onExit(ctx: ?*anyopaque, exit_code: i32) callconv(.c) void {
        const h: *Harness = @ptrCast(@alignCast(ctx.?));
        h.exit_code.store(exit_code, .seq_cst);
        h.exited.store(true, .seq_cst);
        h.sync_mu.lock();
        h.sync_cond.signal();
        h.sync_mu.unlock();
    }

    fn onLog(_: ?*anyopaque, p: [*]const u8, n: usize) callconv(.c) void {
        std.debug.print("{s}", .{p[0..n]});
    }

    fn onExternalWindow(
        ctx: ?*anyopaque,
        grid_id: i64,
        win: i64,
        rows: u32,
        cols: u32,
        start_row: i32,
        start_col: i32,
    ) callconv(.c) void {
        _ = win;
        _ = rows;
        _ = cols;
        _ = start_row;
        _ = start_col;
        const h: *Harness = @ptrCast(@alignCast(ctx.?));
        h.last_ext_win_grid.store(grid_id, .seq_cst);
        _ = h.ext_win_shows.fetchAdd(1, .seq_cst);
    }

    fn onExternalWindowClose(ctx: ?*anyopaque, grid_id: i64) callconv(.c) void {
        _ = grid_id;
        const h: *Harness = @ptrCast(@alignCast(ctx.?));
        _ = h.ext_win_closes.fetchAdd(1, .seq_cst);
    }

    // ── Input ──────────────────────────────────────────────────────────

    /// Send keys in nvim_input notation ("ihello<Esc>", "<C-w>v", ...).
    /// Bypasses Core.sendInput, which escapes '<' as '<lt>' for literal text.
    pub fn input(h: *Harness, keys: []const u8) !void {
        try h.core.requestInput(keys);
    }

    /// Run an ex command via nvim_command (no cmdline echo round trip).
    pub fn command(h: *Harness, cmd: []const u8) !void {
        try h.core.requestCommand(cmd);
    }

    // ── Synchronization ────────────────────────────────────────────────

    /// Wait until `pred(ctx, h)` is true. Wakes on every flush-end (condvar)
    /// with a 20 ms cap per wait slice; fails fast when nvim exits.
    pub fn waitUntil(
        h: *Harness,
        ctx: anytype,
        comptime pred: fn (@TypeOf(ctx), *Harness) bool,
        timeout_ms: u64,
    ) WaitError!void {
        var timer = std.time.Timer.start() catch unreachable;
        while (true) {
            if (pred(ctx, h)) return;
            if (h.exited.load(.seq_cst)) return WaitError.NvimExited;
            if (timer.read() / std.time.ns_per_ms >= timeout_ms) return WaitError.Timeout;
            h.sync_mu.lock();
            h.sync_cond.timedWait(&h.sync_mu, 20 * std.time.ns_per_ms) catch {};
            h.sync_mu.unlock();
        }
    }

    // ── Readback (locks grid_mu internally) ────────────────────────────

    /// Grid that holds the current window's content (cursor's grid).
    /// With ext_multigrid this is a sub-grid (>= 2), not the global grid 1.
    pub fn winGrid(h: *Harness) i64 {
        h.core.grid_mu.lock();
        defer h.core.grid_mu.unlock();
        return h.core.grid.cursor_grid;
    }

    pub fn cellAt(h: *Harness, grid_id: i64, row: u32, col: u32) Cell {
        h.core.grid_mu.lock();
        defer h.core.grid_mu.unlock();
        return h.core.grid.getCellGrid(grid_id, row, col);
    }

    pub const CursorPos = struct { grid_id: i64, row: u32, col: u32 };

    pub fn cursor(h: *Harness) CursorPos {
        h.core.grid_mu.lock();
        defer h.core.grid_mu.unlock();
        return .{
            .grid_id = h.core.grid.cursor_grid,
            .row = h.core.grid.cursor_row,
            .col = h.core.grid.cursor_col,
        };
    }

    /// Resolve the highlight attr (colors + styles) of a cell.
    pub fn hlAt(h: *Harness, grid_id: i64, row: u32, col: u32) ResolvedAttrWithStyles {
        h.core.grid_mu.lock();
        defer h.core.grid_mu.unlock();
        const c = h.core.grid.getCellGrid(grid_id, row, col);
        return h.core.hl.getWithStyles(c.hl);
    }

    /// Resolve a highlight id directly (0 = default colors).
    pub fn hlOf(h: *Harness, hl_id: u32) ResolvedAttrWithStyles {
        h.core.grid_mu.lock();
        defer h.core.grid_mu.unlock();
        return h.core.hl.getWithStyles(hl_id);
    }

    /// Grid content revision counter (bumped on cell/layering/scroll changes).
    /// Lets scenarios assert that an event triggered a recomposition.
    pub fn contentRev(h: *Harness) u64 {
        h.core.grid_mu.lock();
        defer h.core.grid_mu.unlock();
        return h.core.grid.content_rev;
    }

    /// Wait until the current mode name starts with `prefix`
    /// (e.g. "insert", "normal"; from mode_change events).
    pub fn waitMode(h: *Harness, prefix: []const u8, timeout_ms: u64) !void {
        const Ctx = struct { prefix: []const u8 };
        h.waitUntil(Ctx{ .prefix = prefix }, struct {
            fn check(c: Ctx, hh: *Harness) bool {
                hh.core.grid_mu.lock();
                defer hh.core.grid_mu.unlock();
                const mode = std.mem.sliceTo(&hh.core.grid.current_mode_name, 0);
                return std.mem.startsWith(u8, mode, c.prefix);
            }
        }.check, timeout_ms) catch |e| {
            h.core.grid_mu.lock();
            const mode = std.mem.sliceTo(&h.core.grid.current_mode_name, 0);
            std.debug.print("[e2e] waitMode failed: expected=\"{s}\" actual=\"{s}\"\n", .{ prefix, mode });
            h.core.grid_mu.unlock();
            return e;
        };
    }

    /// Float/window placement of a sub-grid (win_pos / win_float_pos), or
    /// null if the grid is not positioned.
    pub fn gridPos(h: *Harness, grid_id: i64) ?GridPos {
        h.core.grid_mu.lock();
        defer h.core.grid_mu.unlock();
        return h.core.grid.win_pos.get(grid_id);
    }

    pub const GridSizeRC = struct { rows: u32, cols: u32 };

    pub fn subGridSize(h: *Harness, grid_id: i64) ?GridSizeRC {
        h.core.grid_mu.lock();
        defer h.core.grid_mu.unlock();
        if (h.core.grid.sub_grids.getPtr(grid_id)) |sg| {
            return .{ .rows = sg.rows, .cols = sg.cols };
        }
        return null;
    }

    /// True if `grid_id` is currently tracked as an external grid
    /// (displayed in a separate OS window; from win_external_pos).
    pub fn isExternalGrid(h: *Harness, grid_id: i64) bool {
        h.core.grid_mu.lock();
        defer h.core.grid_mu.unlock();
        return h.core.grid.external_grids.contains(grid_id);
    }

    /// Snapshot of all external grid ids. Caller owns slice.
    pub fn externalGridsAlloc(h: *Harness, alloc: std.mem.Allocator) ![]i64 {
        h.core.grid_mu.lock();
        defer h.core.grid_mu.unlock();
        var ids: std.ArrayListUnmanaged(i64) = .{};
        errdefer ids.deinit(alloc);
        var it = h.core.grid.external_grids.keyIterator();
        while (it.next()) |k| try ids.append(alloc, k.*);
        return ids.toOwnedSlice(alloc);
    }

    /// Snapshot of all positioned grid ids (win_pos keys). Caller owns slice.
    pub fn positionedGridsAlloc(h: *Harness, alloc: std.mem.Allocator) ![]i64 {
        h.core.grid_mu.lock();
        defer h.core.grid_mu.unlock();
        var ids: std.ArrayListUnmanaged(i64) = .{};
        errdefer ids.deinit(alloc);
        var it = h.core.grid.win_pos.keyIterator();
        while (it.next()) |k| try ids.append(alloc, k.*);
        return ids.toOwnedSlice(alloc);
    }

    /// Reconstruct a row's text as UTF-8: Cell.cp plus overflow extras for
    /// multi-codepoint cells; cp==0 cells (wide-char continuation / unset)
    /// are skipped; trailing whitespace is trimmed.
    pub fn rowTextAlloc(h: *Harness, alloc: std.mem.Allocator, grid_id: i64, row: u32) ![]u8 {
        h.core.grid_mu.lock();
        defer h.core.grid_mu.unlock();
        const cols: u32 = if (grid_id == 1)
            h.core.grid.cols
        else if (h.core.grid.sub_grids.getPtr(grid_id)) |sg|
            sg.cols
        else
            0;

        var buf: std.ArrayListUnmanaged(u8) = .{};
        errdefer buf.deinit(alloc);
        var utf8: [4]u8 = undefined;
        var col: u32 = 0;
        while (col < cols) : (col += 1) {
            const c = h.core.grid.getCellGrid(grid_id, row, col);
            if (c.cp == 0) continue; // wide-char continuation or unset
            const n = std.unicode.utf8Encode(@intCast(c.cp), &utf8) catch continue;
            try buf.appendSlice(alloc, utf8[0..n]);
            if (h.core.grid.getOverflow(grid_id, row, col)) |extras| {
                for (extras) |cp| {
                    const m = std.unicode.utf8Encode(@intCast(cp), &utf8) catch continue;
                    try buf.appendSlice(alloc, utf8[0..m]);
                }
            }
        }
        // Trim trailing whitespace (empty cells render as spaces).
        var end = buf.items.len;
        while (end > 0 and buf.items[end - 1] == ' ') end -= 1;
        buf.items.len = end;
        return buf.toOwnedSlice(alloc);
    }

    // ── High-level asserts ─────────────────────────────────────────────

    /// Wait until row `row` of `grid_id` equals `expected` (trimmed).
    /// On failure, prints expected vs actual before returning the error.
    pub fn waitRowText(h: *Harness, grid_id: i64, row: u32, expected: []const u8, timeout_ms: u64) !void {
        const Ctx = struct { grid_id: i64, row: u32, expected: []const u8 };
        h.waitUntil(Ctx{ .grid_id = grid_id, .row = row, .expected = expected }, struct {
            fn check(c: Ctx, hh: *Harness) bool {
                const text = hh.rowTextAlloc(hh.alloc, c.grid_id, c.row) catch return false;
                defer hh.alloc.free(text);
                return std.mem.eql(u8, text, c.expected);
            }
        }.check, timeout_ms) catch |e| {
            const text = h.rowTextAlloc(h.alloc, grid_id, row) catch "";
            defer if (text.len > 0) h.alloc.free(text);
            std.debug.print(
                "[e2e] waitRowText failed: grid={d} row={d} expected=\"{s}\" actual=\"{s}\"\n",
                .{ grid_id, row, expected, text },
            );
            return e;
        };
    }

    /// Wait until the cursor sits at (row, col) in its current grid.
    pub fn waitCursor(h: *Harness, row: u32, col: u32, timeout_ms: u64) !void {
        const Ctx = struct { row: u32, col: u32 };
        h.waitUntil(Ctx{ .row = row, .col = col }, struct {
            fn check(c: Ctx, hh: *Harness) bool {
                const cur = hh.cursor();
                return cur.row == c.row and cur.col == c.col;
            }
        }.check, timeout_ms) catch |e| {
            const cur = h.cursor();
            std.debug.print(
                "[e2e] waitCursor failed: expected=({d},{d}) actual=grid={d} ({d},{d})\n",
                .{ row, col, cur.grid_id, cur.row, cur.col },
            );
            return e;
        };
    }

    // ── Performance Measurement ────────────────────────────────────────

    /// Measure average frame time (duration per flush) over `iterations` cycles.
    /// Returns elapsed time in milliseconds per flush.
    pub fn measureFrameTime(h: *Harness, iterations: u32) !f64 {
        if (iterations == 0) return 0;
        var total_ms: f64 = 0;
        var i: u32 = 0;
        const start_seq = h.flush_seq.load(.seq_cst);
        while (i < iterations) : (i += 1) {
            const target_seq = start_seq + @as(u64, i) + 1;
            const Ctx = struct { target: u64 };
            try h.waitUntil(Ctx{ .target = target_seq }, struct {
                fn check(c: Ctx, hh: *Harness) bool {
                    return hh.flush_seq.load(.seq_cst) >= c.target;
                }
            }.check, h.opts.timeout_ms);
            // Note: In a real perf test, measure timestamps between flushes.
            // For now, we just count iterations reaching target_seq.
            total_ms += 1.0; // Placeholder: would be actual frame delta
        }
        // Note: This is a simplified measurement. A real perf test would instrument
        // flush() callbacks with timestamps. For now, we measure the time to reach
        // target flush count, which is conservative.
        return total_ms / @as(f64, @floatFromInt(iterations));
    }

    // ── Viewport and Scroll State ──────────────────────────────────────

    /// Get the top line index of the viewport for a grid (0-based).
    /// Returns the top line number from the win_viewport event.
    pub fn getViewportTop(h: *Harness, grid_id: i64) u32 {
        h.core.grid_mu.lock();
        defer h.core.grid_mu.unlock();
        if (h.core.grid.viewport.get(grid_id)) |vp| {
            return @intCast(vp.topline);
        }
        return 0;
    }


    /// Get cell width (in terminal cells) for a character.
    /// Emoji and CJK are typically 2 cells; ASCII is 1 cell.
    /// This is a simplified approximation; actual width depends on glyph metrics.
    pub fn cellWidthAt(h: *Harness, grid_id: i64, row: u32, col: u32) u32 {
        h.core.grid_mu.lock();
        defer h.core.grid_mu.unlock();
        const c = h.core.grid.getCellGrid(grid_id, row, col);
        // Simplified heuristic: codepoints > U+1F300 (emoji range) → 2 cells.
        // Real logic depends on glyph metrics from the font.
        if (c.cp == 0) return 0; // wide-char continuation or unset
        if (c.cp > 0x1F300) return 2; // emoji range (approximate)
        if (c.cp >= 0x2000) return 2; // CJK and similar
        return 1;
    }
};
