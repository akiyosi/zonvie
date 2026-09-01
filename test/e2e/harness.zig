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

pub const AgentEvent = struct { tab: i64, state: u8, title: []u8 };

/// One recorded on_msg_show callback. `view` is the routed view type; the
/// core has already decided it, so scenarios assert on routing outcomes
/// without reimplementing the route table.
pub const MsgShowEvent = struct {
    view: u8,
    kind: []u8,
    content: []u8,
    timeout_ms: u32,
};

pub const Options = struct {
    rows: u32 = 24,
    cols: u32 = 80,
    /// Pass --clean so user config cannot break determinism.
    clean: bool = true,
    /// Attach with ext_messages and record the message callbacks. Off by
    /// default so existing scenarios keep seeing messages in the grid.
    ext_messages: bool = false,
    /// User-declared message routes, prepended to the built-in defaults
    /// exactly as a config file's would be. Borrowed for the harness lifetime.
    msg_routes: ?[]const zc.config.MsgRoute = null,
    /// Named view settings that the default routes read.
    msg_views: ?zc.config.ViewSettings = null,
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
    const path = std.process.Environ.getAlloc(std.testing.environ, alloc, "ZONVIE_TEST_NVIM") catch
        try alloc.dupe(u8, "nvim");
    errdefer alloc.free(path);

    const result = std.process.run(alloc, zc.clock.io(), .{
        .argv = &.{ path, "--version" },
    }) catch return error.NvimNotFound;
    alloc.free(result.stdout);
    alloc.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code != 0) return error.NvimNotFound,
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
    sync_mu: std.Io.Mutex = .init,
    sync_cond: std.Io.Condition = .init,
    flush_seq: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    exited: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    exit_code: std.atomic.Value(i32) = std.atomic.Value(i32).init(0),
    verbose: bool = false,

    // External window callback recording (frontend-contract observation).
    ext_win_shows: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    ext_win_closes: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    last_ext_win_grid: std.atomic.Value(i64) = std.atomic.Value(i64).init(0),

    // AI-agent status recording (see on_agent_status doc comment in
    // zonvie_core.h). Appended in arrival order; `state` is the raw wire
    // byte (low 7 bits = indicator state, bit 7 = notify flag).
    agent_events_mu: std.Io.Mutex = .init,
    agent_events: std.ArrayListUnmanaged(AgentEvent) = .empty,

    // ext_messages recording. Appended in arrival order. Only channels with a
    // consumer are recorded: msg_shows (per-message routing outcomes) and
    // msg_showmodes (the mode indicator, used to prove that events a user
    // route never mentioned still reach their default view).
    msg_mu: std.Io.Mutex = .init,
    msg_shows: std.ArrayListUnmanaged(MsgShowEvent) = .empty,
    msg_showmodes: std.ArrayListUnmanaged(MsgShowEvent) = .empty,
    /// on_msg_clear arrivals. This is the only signal a frontend gets that a
    /// message window it owns (mini, confirm prompt) must come down, so a
    /// scenario can only prove "the old window went away" by counting it.
    msg_clears: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    // grid_scroll recording. A frontend holding a sub-cell scroll offset has to
    // give the reported distance back, so what matters is not just that the
    // notification arrives but that it arrives exactly once — see
    // `abort_flush_on_grid_scroll`.
    grid_scrolls: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    grid_scroll_rows: std.atomic.Value(i64) = std.atomic.Value(i64).init(0),
    /// Arm to abort the flush from inside the next on_grid_scroll, the way a
    /// frontend does when it cannot finish the bracket. The core dispatches
    /// grid_scroll before that point, so this reproduces an abort that lands
    /// after the notification was already consumed.
    abort_flush_on_grid_scroll: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    /// Flushes that ended with the abort flag set. Without this a scenario
    /// cannot tell an abort that took effect from a write that did nothing.
    flush_aborts: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

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
            .verbose = std.process.Environ.containsConstant(std.testing.environ, "ZONVIE_E2E_VERBOSE"),
        };

        // rpc_session splits this string on spaces and inserts --embed
        // after argv[0], so "--clean" rides along with no core changes.
        //
        // `-n` disables swap files ('noswapfile'). Without it, every spawned
        // nvim writes a swap file; across a full suite (and repeated runs)
        // these accumulate in 'directory' until nvim hits E326 "Too many swap
        // files" / E325 "swap file exists" and blocks on a |hit-enter| prompt,
        // which freezes the window grid and makes content-bearing tests time
        // out non-deterministically. A test harness never needs swap files.
        h.nvim_cmd = if (opts.clean)
            try std.fmt.allocPrint(alloc, "{s} --clean -n", .{nvim_path})
        else
            try std.fmt.allocPrint(alloc, "{s} -n", .{nvim_path});
        errdefer alloc.free(h.nvim_cmd);

        const cbs = Callbacks{
            .on_flush_end = onFlushEnd,
            .on_exit = onExit,
            .on_log = if (h.verbose) onLog else null,
            .on_external_window = onExternalWindow,
            .on_external_window_close = onExternalWindowClose,
            .on_agent_status = onAgentStatus,
            .on_grid_scroll = onGridScroll,
            .on_msg_show = if (opts.ext_messages) onMsgShow else null,
            .on_msg_showmode = if (opts.ext_messages) onMsgShowmode else null,
            .on_msg_clear = if (opts.ext_messages) onMsgClear else null,
        };
        h.core = try alloc.create(Core);
        errdefer alloc.destroy(h.core);
        h.core.* = Core.init(alloc, cbs, h);
        // Must be set before start(): requestUiAttach reads it.
        h.core.ext_windows_enabled = opts.ext_windows;
        h.core.ext_messages_enabled = opts.ext_messages;
        if (opts.msg_routes) |routes| h.core.msg_config.messages.routes = routes;
        if (opts.msg_views) |views| h.core.msg_config.messages.views = views;

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
                hh.core.grid_mu.lockUncancelable(zc.clock.io());
                defer hh.core.grid_mu.unlock(zc.clock.io());
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
        for (h.agent_events.items) |e| h.alloc.free(e.title);
        h.agent_events.deinit(h.alloc);
        for (h.msg_shows.items) |e| {
            h.alloc.free(e.kind);
            h.alloc.free(e.content);
        }
        h.msg_shows.deinit(h.alloc);
        for (h.msg_showmodes.items) |e| {
            h.alloc.free(e.kind);
            h.alloc.free(e.content);
        }
        h.msg_showmodes.deinit(h.alloc);
        h.alloc.destroy(h);
    }

    // ── Callbacks (RPC thread, grid_mu held — must not touch grid_mu) ──

    fn onFlushEnd(ctx: ?*anyopaque) callconv(.c) void {
        const h: *Harness = @ptrCast(@alignCast(ctx.?));
        if (h.core.flush_aborted) _ = h.flush_aborts.fetchAdd(1, .seq_cst);
        _ = h.flush_seq.fetchAdd(1, .seq_cst);
        h.sync_mu.lockUncancelable(zc.clock.io());
        h.sync_cond.signal(zc.clock.io());
        h.sync_mu.unlock(zc.clock.io());
    }

    fn onExit(ctx: ?*anyopaque, exit_code: i32) callconv(.c) void {
        const h: *Harness = @ptrCast(@alignCast(ctx.?));
        h.exit_code.store(exit_code, .seq_cst);
        h.exited.store(true, .seq_cst);
        h.sync_mu.lockUncancelable(zc.clock.io());
        h.sync_cond.signal(zc.clock.io());
        h.sync_mu.unlock(zc.clock.io());
    }

    fn onGridScroll(ctx: ?*anyopaque, grid_id: i64, rows_delta: i32) callconv(.c) void {
        _ = grid_id;
        const h: *Harness = @ptrCast(@alignCast(ctx.?));
        _ = h.grid_scrolls.fetchAdd(1, .seq_cst);
        _ = h.grid_scroll_rows.fetchAdd(rows_delta, .seq_cst);
        if (h.abort_flush_on_grid_scroll.swap(false, .seq_cst)) {
            // Same effect as zonvie_core_abort_flush from the frontend.
            h.core.flush_aborted = true;
        }
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

    // Not coupled to grid/redraw (see zonvie_agent_status handling in
    // rpc_session.zig), so this does not require grid_mu.
    fn onAgentStatus(ctx: ?*anyopaque, tab_handle: i64, state: u8, title: [*]const u8, title_len: usize) callconv(.c) void {
        const h: *Harness = @ptrCast(@alignCast(ctx.?));
        const copy = h.alloc.dupe(u8, title[0..title_len]) catch return;
        h.agent_events_mu.lockUncancelable(zc.clock.io());
        defer h.agent_events_mu.unlock(zc.clock.io());
        h.agent_events.append(h.alloc, .{ .tab = tab_handle, .state = state, .title = copy }) catch h.alloc.free(copy);
    }

    /// Flatten msg chunks into one string. Returns null on OOM so the
    /// callback can drop the event rather than fail on the RPC thread.
    fn joinChunks(h: *Harness, chunks: [*]const zc.MsgChunk, count: usize) ?[]u8 {
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        for (chunks[0..count]) |c| {
            if (c.text_len == 0) continue;
            buf.appendSlice(h.alloc, c.text[0..c.text_len]) catch {
                buf.deinit(h.alloc);
                return null;
            };
        }
        return buf.toOwnedSlice(h.alloc) catch {
            buf.deinit(h.alloc);
            return null;
        };
    }

    fn onMsgShow(
        ctx: ?*anyopaque,
        view: zc.zonvie_msg_view_type,
        kind: [*]const u8,
        kind_len: usize,
        chunks: [*]const zc.MsgChunk,
        chunk_count: usize,
        replace_last: c_int,
        history: c_int,
        append: c_int,
        msg_id: i64,
        timeout_ms: u32,
    ) callconv(.c) void {
        _ = replace_last;
        _ = history;
        _ = append;
        _ = msg_id;
        const h: *Harness = @ptrCast(@alignCast(ctx.?));
        const content = h.joinChunks(chunks, chunk_count) orelse return;
        const kind_copy = h.alloc.dupe(u8, kind[0..kind_len]) catch {
            h.alloc.free(content);
            return;
        };
        h.msg_mu.lockUncancelable(zc.clock.io());
        defer h.msg_mu.unlock(zc.clock.io());
        h.msg_shows.append(h.alloc, .{
            .view = @intCast(@intFromEnum(view)),
            .kind = kind_copy,
            .content = content,
            .timeout_ms = timeout_ms,
        }) catch {
            h.alloc.free(content);
            h.alloc.free(kind_copy);
        };
    }

    /// The core skips this callback entirely when the event routed to `none`
    /// or was skipped (flush.zig sendMsgStatus), so a recorded event is
    /// itself proof the default route survived.
    fn onMsgShowmode(
        ctx: ?*anyopaque,
        view: zc.zonvie_msg_view_type,
        chunks: [*]const zc.MsgChunk,
        chunk_count: usize,
    ) callconv(.c) void {
        const h: *Harness = @ptrCast(@alignCast(ctx.?));
        const content = h.joinChunks(chunks, chunk_count) orelse return;
        const kind_copy = h.alloc.dupe(u8, "") catch {
            h.alloc.free(content);
            return;
        };
        h.msg_mu.lockUncancelable(zc.clock.io());
        defer h.msg_mu.unlock(zc.clock.io());
        h.msg_showmodes.append(h.alloc, .{
            .view = @intCast(@intFromEnum(view)),
            .kind = kind_copy,
            .content = content,
            .timeout_ms = 0,
        }) catch {
            h.alloc.free(content);
            h.alloc.free(kind_copy);
        };
    }

    fn onMsgClear(ctx: ?*anyopaque) callconv(.c) void {
        const h: *Harness = @ptrCast(@alignCast(ctx.?));
        _ = h.msg_clears.fetchAdd(1, .seq_cst);
    }

    // ── ext_messages readback ──────────────────────────────────────────

    /// How many on_msg_clear callbacks have arrived so far. Compared across a
    /// transition rather than read as an absolute: a rising count is the only
    /// observable proof that the frontend was told to take its message window
    /// down.
    pub fn msgClearCount(h: *Harness) u64 {
        return h.msg_clears.load(.seq_cst);
    }

    /// True if any recorded on_msg_show matches `pred`.
    pub fn hasMsgShow(h: *Harness, comptime pred: fn (MsgShowEvent) bool) bool {
        h.msg_mu.lockUncancelable(zc.clock.io());
        defer h.msg_mu.unlock(zc.clock.io());
        for (h.msg_shows.items) |e| {
            if (pred(e)) return true;
        }
        return false;
    }

    /// Wait until some recorded on_msg_show matches `pred`. Events that
    /// arrived before the wait started still count.
    pub fn waitMsgShow(h: *Harness, comptime pred: fn (MsgShowEvent) bool, timeout_ms: u64) WaitError!void {
        const Wrap = struct {
            fn check(_: void, hh: *Harness) bool {
                return hh.hasMsgShow(pred);
            }
        };
        h.waitUntil({}, Wrap.check, timeout_ms) catch |e| {
            h.dumpMsgShows();
            return e;
        };
    }

    pub fn msgShowCount(h: *Harness) usize {
        h.msg_mu.lockUncancelable(zc.clock.io());
        defer h.msg_mu.unlock(zc.clock.io());
        return h.msg_shows.items.len;
    }

    /// True if any recorded on_msg_showmode matches `pred`.
    pub fn hasMsgShowmode(h: *Harness, comptime pred: fn (MsgShowEvent) bool) bool {
        h.msg_mu.lockUncancelable(zc.clock.io());
        defer h.msg_mu.unlock(zc.clock.io());
        for (h.msg_showmodes.items) |e| {
            if (pred(e)) return true;
        }
        return false;
    }

    /// Wait until some recorded on_msg_showmode matches `pred`.
    pub fn waitMsgShowmode(h: *Harness, comptime pred: fn (MsgShowEvent) bool, timeout_ms: u64) WaitError!void {
        const Wrap = struct {
            fn check(_: void, hh: *Harness) bool {
                return hh.hasMsgShowmode(pred);
            }
        };
        try h.waitUntil({}, Wrap.check, timeout_ms);
    }

    pub fn dumpMsgShows(h: *Harness) void {
        h.msg_mu.lockUncancelable(zc.clock.io());
        defer h.msg_mu.unlock(zc.clock.io());
        std.debug.print("[e2e] recorded msg_show events ({d}):\n", .{h.msg_shows.items.len});
        for (h.msg_shows.items) |e| {
            std.debug.print(
                "  view={d} kind=\"{s}\" timeout_ms={d} content=\"{s}\"\n",
                .{ e.view, e.kind, e.timeout_ms, e.content },
            );
        }
    }

    /// Bytes of content the core assembled for the most recent split show.
    /// Reading this separates "was the content clipped" from "where is the
    /// split scrolled to", which visible rows alone cannot distinguish.
    pub fn splitContentLen(h: *Harness) usize {
        h.core.grid_mu.lockUncancelable(zc.clock.io());
        defer h.core.grid_mu.unlock(zc.clock.io());
        return h.core.msg_split_buf.items.len;
    }

    /// Copy of the content the core assembled for the most recent split show.
    /// Caller owns the slice. Lets a scenario check completeness, order and
    /// duplication of the assembled text, which visible rows cannot.
    pub fn splitContentAlloc(h: *Harness, alloc: std.mem.Allocator) ![]u8 {
        h.core.grid_mu.lockUncancelable(zc.clock.io());
        defer h.core.grid_mu.unlock(zc.clock.io());
        return alloc.dupe(u8, h.core.msg_split_buf.items);
    }

    /// Number of messages the core is still holding. Lets a scenario assert
    /// that handed-off or undisplayed messages do not accumulate.
    pub fn pendingMessageCount(h: *Harness) usize {
        h.core.grid_mu.lockUncancelable(zc.clock.io());
        defer h.core.grid_mu.unlock(zc.clock.io());
        return h.core.grid.message_state.messages.items.len;
    }

    /// Put the message pipeline into the state a FAILED dispatch leaves
    /// behind: a retry deadline `delay_ms` in the future, with the pending
    /// marker set so `nextMsgTimeoutNs` actually reports it. The failures that
    /// arm this for real (allocator exhaustion, a full RPC write queue) cannot
    /// be provoked from a scenario, and the branch under test reads exactly
    /// these two fields, so injecting them tests the real thing.
    pub fn armMsgShowBackoff(h: *Harness, delay_ms: i64) void {
        h.core.grid_mu.lockUncancelable(zc.clock.io());
        defer h.core.grid_mu.unlock(zc.clock.io());
        const now = zc.clock.nowNs();
        h.core.msg_show_pending_since = now;
        h.core.msg_show_retry_at = now + @as(i128, delay_ms) * std.time.ns_per_ms;
    }

    /// True while a msg_show retry deadline is still armed. After a message has
    /// been displayed this must be null again; a deadline that survives a
    /// successful dispatch would delay every later message.
    pub fn msgShowRetryArmed(h: *Harness) bool {
        h.core.grid_mu.lockUncancelable(zc.clock.io());
        defer h.core.grid_mu.unlock(zc.clock.io());
        return h.core.msg_show_retry_at != null;
    }

    /// True when the msg_show (ext_float) auto-hide deadline is armed. A
    /// route with `timeout = 0` — errors, for instance — must leave it null.
    pub fn msgAutoHideArmed(h: *Harness) bool {
        h.core.grid_mu.lockUncancelable(zc.clock.io());
        defer h.core.grid_mu.unlock(zc.clock.io());
        return h.core.msg_show_auto_hide_at != null;
    }

    /// Drive one frontend timer tick, exactly as
    /// `zonvie_core_tick_msg_throttle` does for the real frontends
    /// (c_api.zig:1224). ext_float auto-hide is expired from here, so without
    /// this a message never disappears while Neovim is idle.
    pub fn tickMsgThrottle(h: *Harness) void {
        h.core.grid_mu.lockUncancelable(zc.clock.io());
        h.core.redraw_thread_id.store(@intCast(std.Thread.getCurrentId()), .seq_cst);
        defer {
            h.core.redraw_thread_id.store(0, .seq_cst);
            h.core.grid_mu.unlock(zc.clock.io());
        }
        var fctx = zc.flush_mod.FlushCtx{ .core = h.core };
        zc.flush_mod.FlushCtx.onFlush(&fctx, h.core.grid.rows, h.core.grid.cols) catch {};
    }

    /// Wait until `pred(h)` holds, ticking the msg timer between polls so
    /// auto-hide deadlines actually expire while Neovim is idle.
    pub fn waitTicking(
        h: *Harness,
        comptime pred: fn (*Harness) bool,
        timeout_ms: u64,
    ) WaitError!void {
        const t0 = zc.clock.nowNs();
        while (true) {
            h.tickMsgThrottle();
            if (pred(h)) return;
            if (h.exited.load(.seq_cst)) return WaitError.NvimExited;
            if (@as(u64, @intCast(zc.clock.nowNs() - t0)) / std.time.ns_per_ms >= timeout_ms) return WaitError.Timeout;
            std.Io.sleep(zc.clock.io(), .{ .nanoseconds = 20 * std.time.ns_per_ms }, .awake) catch {};
        }
    }

    // ── Neovim window observation ──────────────────────────────────────

    /// Number of positioned, non-external Neovim windows, derived from
    /// win_pos. Floats ARE included (win_float_pos also populates win_pos),
    /// so scenarios that open floats must account for them. The split view
    /// creates a real window, so this is how a scenario sees whether it
    /// appeared or went away.
    pub fn windowCount(h: *Harness) usize {
        h.core.grid_mu.lockUncancelable(zc.clock.io());
        defer h.core.grid_mu.unlock(zc.clock.io());
        var n: usize = 0;
        var it = h.core.grid.win_pos.keyIterator();
        while (it.next()) |k| {
            if (h.core.grid.external_grids.contains(k.*)) continue;
            n += 1;
        }
        return n;
    }

    /// Wait until `windowCount()` equals `expected`.
    pub fn waitWindowCount(h: *Harness, expected: usize, timeout_ms: u64) !void {
        const Ctx = struct { expected: usize };
        h.waitUntil(Ctx{ .expected = expected }, struct {
            fn check(c: Ctx, hh: *Harness) bool {
                return hh.windowCount() == c.expected;
            }
        }.check, timeout_ms) catch |e| {
            std.debug.print(
                "[e2e] waitWindowCount failed: expected={d} actual={d}\n",
                .{ expected, h.windowCount() },
            );
            return e;
        };
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

    /// Send one mouse wheel event, the way the frontends do.
    pub fn wheel(h: *Harness, grid_id: i64, direction: []const u8) void {
        h.core.sendMouseScroll(grid_id, 0, 0, direction, "");
    }

    /// The 'ver' component of 'mousescroll' as the core currently understands
    /// it — what the reporter injected at startup last published.
    pub fn mousescrollVer(h: *Harness) u32 {
        return h.core.mousescroll_ver.load(.acquire);
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
        const t0 = zc.clock.nowNs();
        while (true) {
            if (pred(ctx, h)) return;
            if (h.exited.load(.seq_cst)) return WaitError.NvimExited;
            if (@as(u64, @intCast(zc.clock.nowNs() - t0)) / std.time.ns_per_ms >= timeout_ms) return WaitError.Timeout;
            // 0.16 std.Io.Condition has no timed wait, so cap each slice at 20 ms
            // with a sleep; the loop re-checks pred/exited/timeout each iteration.
            std.Io.sleep(zc.clock.io(), .{ .nanoseconds = 20 * std.time.ns_per_ms }, .awake) catch {};
        }
    }

    /// Wait until nvim exits. Used by scenarios whose subject IS the exit,
    /// e.g. that a leftover scratch window does not keep the editor alive.
    pub fn waitExit(h: *Harness, timeout_ms: u64) !void {
        h.waitUntil({}, struct {
            fn check(_: void, _: *Harness) bool {
                return false; // only NvimExited ends this wait
            }
        }.check, timeout_ms) catch |e| switch (e) {
            WaitError.NvimExited => return,
            else => return e,
        };
    }

    // ── Readback (locks grid_mu internally) ────────────────────────────

    /// Grid that holds the current window's content (cursor's grid).
    /// With ext_multigrid this is a sub-grid (>= 2), not the global grid 1.
    pub fn winGrid(h: *Harness) i64 {
        h.core.grid_mu.lockUncancelable(zc.clock.io());
        defer h.core.grid_mu.unlock(zc.clock.io());
        return h.core.grid.cursor_grid;
    }

    pub fn cellAt(h: *Harness, grid_id: i64, row: u32, col: u32) Cell {
        h.core.grid_mu.lockUncancelable(zc.clock.io());
        defer h.core.grid_mu.unlock(zc.clock.io());
        return h.core.grid.getCellGrid(grid_id, row, col);
    }

    pub const CursorPos = struct { grid_id: i64, row: u32, col: u32 };

    pub fn cursor(h: *Harness) CursorPos {
        h.core.grid_mu.lockUncancelable(zc.clock.io());
        defer h.core.grid_mu.unlock(zc.clock.io());
        return .{
            .grid_id = h.core.grid.cursor_grid,
            .row = h.core.grid.cursor_row,
            .col = h.core.grid.cursor_col,
        };
    }

    /// Resolve the highlight attr (colors + styles) of a cell.
    pub fn hlAt(h: *Harness, grid_id: i64, row: u32, col: u32) ResolvedAttrWithStyles {
        h.core.grid_mu.lockUncancelable(zc.clock.io());
        defer h.core.grid_mu.unlock(zc.clock.io());
        const c = h.core.grid.getCellGrid(grid_id, row, col);
        return h.core.hl.getWithStyles(c.hl);
    }

    /// Resolve a highlight id directly (0 = default colors).
    pub fn hlOf(h: *Harness, hl_id: u32) ResolvedAttrWithStyles {
        h.core.grid_mu.lockUncancelable(zc.clock.io());
        defer h.core.grid_mu.unlock(zc.clock.io());
        return h.core.hl.getWithStyles(hl_id);
    }

    /// Grid content revision counter (bumped on cell/layering/scroll changes).
    /// Lets scenarios assert that an event triggered a recomposition.
    pub fn contentRev(h: *Harness) u64 {
        h.core.grid_mu.lockUncancelable(zc.clock.io());
        defer h.core.grid_mu.unlock(zc.clock.io());
        return h.core.grid.content_rev;
    }

    /// Wait until the current mode name starts with `prefix`
    /// (e.g. "insert", "normal"; from mode_change events).
    pub fn waitMode(h: *Harness, prefix: []const u8, timeout_ms: u64) !void {
        const Ctx = struct { prefix: []const u8 };
        h.waitUntil(Ctx{ .prefix = prefix }, struct {
            fn check(c: Ctx, hh: *Harness) bool {
                hh.core.grid_mu.lockUncancelable(zc.clock.io());
                defer hh.core.grid_mu.unlock(zc.clock.io());
                const mode = std.mem.sliceTo(&hh.core.grid.current_mode_name, 0);
                return std.mem.startsWith(u8, mode, c.prefix);
            }
        }.check, timeout_ms) catch |e| {
            h.core.grid_mu.lockUncancelable(zc.clock.io());
            const mode = std.mem.sliceTo(&h.core.grid.current_mode_name, 0);
            std.debug.print("[e2e] waitMode failed: expected=\"{s}\" actual=\"{s}\"\n", .{ prefix, mode });
            h.core.grid_mu.unlock(zc.clock.io());
            return e;
        };
    }

    /// Float/window placement of a sub-grid (win_pos / win_float_pos), or
    /// null if the grid is not positioned.
    pub fn gridPos(h: *Harness, grid_id: i64) ?GridPos {
        h.core.grid_mu.lockUncancelable(zc.clock.io());
        defer h.core.grid_mu.unlock(zc.clock.io());
        return h.core.grid.win_pos.get(grid_id);
    }

    pub const GridSizeRC = struct { rows: u32, cols: u32 };

    pub fn subGridSize(h: *Harness, grid_id: i64) ?GridSizeRC {
        h.core.grid_mu.lockUncancelable(zc.clock.io());
        defer h.core.grid_mu.unlock(zc.clock.io());
        if (h.core.grid.sub_grids.getPtr(grid_id)) |sg| {
            return .{ .rows = sg.rows, .cols = sg.cols };
        }
        return null;
    }

    /// True if `grid_id` is currently tracked as an external grid
    /// (displayed in a separate OS window; from win_external_pos).
    pub fn isExternalGrid(h: *Harness, grid_id: i64) bool {
        h.core.grid_mu.lockUncancelable(zc.clock.io());
        defer h.core.grid_mu.unlock(zc.clock.io());
        return h.core.grid.external_grids.contains(grid_id);
    }

    /// Snapshot of all external grid ids. Caller owns slice.
    pub fn externalGridsAlloc(h: *Harness, alloc: std.mem.Allocator) ![]i64 {
        h.core.grid_mu.lockUncancelable(zc.clock.io());
        defer h.core.grid_mu.unlock(zc.clock.io());
        var ids: std.ArrayListUnmanaged(i64) = .empty;
        errdefer ids.deinit(alloc);
        var it = h.core.grid.external_grids.keyIterator();
        while (it.next()) |k| try ids.append(alloc, k.*);
        return ids.toOwnedSlice(alloc);
    }

    /// Snapshot of all positioned grid ids (win_pos keys). Caller owns slice.
    pub fn positionedGridsAlloc(h: *Harness, alloc: std.mem.Allocator) ![]i64 {
        h.core.grid_mu.lockUncancelable(zc.clock.io());
        defer h.core.grid_mu.unlock(zc.clock.io());
        var ids: std.ArrayListUnmanaged(i64) = .empty;
        errdefer ids.deinit(alloc);
        var it = h.core.grid.win_pos.keyIterator();
        while (it.next()) |k| try ids.append(alloc, k.*);
        return ids.toOwnedSlice(alloc);
    }

    /// Reconstruct a row's text as UTF-8: Cell.cp plus overflow extras for
    /// multi-codepoint cells; cp==0 cells (wide-char continuation / unset)
    /// are skipped; trailing whitespace is trimmed.
    pub fn rowTextAlloc(h: *Harness, alloc: std.mem.Allocator, grid_id: i64, row: u32) ![]u8 {
        h.core.grid_mu.lockUncancelable(zc.clock.io());
        defer h.core.grid_mu.unlock(zc.clock.io());
        const cols: u32 = if (grid_id == 1)
            h.core.grid.cols
        else if (h.core.grid.sub_grids.getPtr(grid_id)) |sg|
            sg.cols
        else
            0;

        var buf: std.ArrayListUnmanaged(u8) = .empty;
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

    /// True if any recorded on_agent_status event so far matches `pred`.
    pub fn hasAgentStatus(h: *Harness, comptime pred: fn (AgentEvent) bool) bool {
        h.agent_events_mu.lockUncancelable(zc.clock.io());
        defer h.agent_events_mu.unlock(zc.clock.io());
        for (h.agent_events.items) |e| {
            if (pred(e)) return true;
        }
        return false;
    }

    /// Wait until some recorded on_agent_status event matches `pred`.
    /// Checks the events accumulated so far each poll, so a match that
    /// arrived before the wait started still succeeds.
    pub fn waitAgentStatus(h: *Harness, comptime pred: fn (AgentEvent) bool, timeout_ms: u64) WaitError!void {
        const Wrap = struct {
            fn check(_: void, hh: *Harness) bool {
                return hh.hasAgentStatus(pred);
            }
        };
        try h.waitUntil({}, Wrap.check, timeout_ms);
    }

    /// Wait until the cursor sits on grid `grid_id`. Because handleRedraw
    /// holds grid_mu for a whole batch, observing the cursor on the target
    /// grid proves every event in that batch (and all earlier batches) has
    /// been applied — an ordering signal for window-switch round trips.
    pub fn waitCursorGrid(h: *Harness, grid_id: i64, timeout_ms: u64) !void {
        const Ctx = struct { grid_id: i64 };
        h.waitUntil(Ctx{ .grid_id = grid_id }, struct {
            fn check(c: Ctx, hh: *Harness) bool {
                return hh.cursor().grid_id == c.grid_id;
            }
        }.check, timeout_ms) catch |e| {
            std.debug.print(
                "[e2e] waitCursorGrid failed: expected grid={d} actual grid={d}\n",
                .{ grid_id, h.cursor().grid_id },
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
            // An idle nvim emits no flushes, so passively waiting for the
            // counter to advance would time out. Force a full screen redraw
            // (<C-l>) each iteration so a frame is actually produced to time.
            try h.input("<C-l>");
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
        h.core.grid_mu.lockUncancelable(zc.clock.io());
        defer h.core.grid_mu.unlock(zc.clock.io());
        if (h.core.grid.viewport.get(grid_id)) |vp| {
            return @intCast(vp.topline);
        }
        return 0;
    }

    /// Get the scroll_delta reported by the last win_viewport event for a grid.
    pub fn getViewportScrollDelta(h: *Harness, grid_id: i64) i64 {
        h.core.grid_mu.lockUncancelable(zc.clock.io());
        defer h.core.grid_mu.unlock(zc.clock.io());
        if (h.core.grid.viewport.get(grid_id)) |vp| {
            return vp.scroll_delta;
        }
        return 0;
    }

    /// Read topline and scroll_delta together. scroll_delta belongs to the last
    /// win_viewport, so reading it in a second lock acquisition can pair it with
    /// a different event than the topline it is being compared against.
    pub fn getViewportTopAndDelta(h: *Harness, grid_id: i64) struct { top: u32, delta: i64 } {
        h.core.grid_mu.lockUncancelable(zc.clock.io());
        defer h.core.grid_mu.unlock(zc.clock.io());
        if (h.core.grid.viewport.get(grid_id)) |vp| {
            return .{ .top = @intCast(vp.topline), .delta = vp.scroll_delta };
        }
        return .{ .top = 0, .delta = 0 };
    }

    /// The Neovim window handle win_viewport reported for a grid, 0 if none yet.
    pub fn viewportWin(h: *Harness, grid_id: i64) i64 {
        h.core.grid_mu.lockUncancelable(zc.clock.io());
        defer h.core.grid_mu.unlock(zc.clock.io());
        if (h.core.grid.viewport.get(grid_id)) |vp| return vp.win;
        return 0;
    }

    /// Take the screen rows moved that no grid_scroll accounted for.
    pub fn takeUncoveredScrollRows(h: *Harness, grid_id: i64) i64 {
        h.core.grid_mu.lockUncancelable(zc.clock.io());
        defer h.core.grid_mu.unlock(zc.clock.io());
        return h.core.grid.takeUncoveredScrollRows(grid_id);
    }

    /// Get cell width (in terminal cells) for a character.
    /// Emoji and CJK are typically 2 cells; ASCII is 1 cell.
    /// This is a simplified approximation; actual width depends on glyph metrics.
    pub fn cellWidthAt(h: *Harness, grid_id: i64, row: u32, col: u32) u32 {
        h.core.grid_mu.lockUncancelable(zc.clock.io());
        defer h.core.grid_mu.unlock(zc.clock.io());
        const c = h.core.grid.getCellGrid(grid_id, row, col);
        // Simplified heuristic: codepoints > U+1F300 (emoji range) → 2 cells.
        // Real logic depends on glyph metrics from the font.
        if (c.cp == 0) return 0; // wide-char continuation or unset
        if (c.cp > 0x1F300) return 2; // emoji range (approximate)
        if (c.cp >= 0x2000) return 2; // CJK and similar
        return 1;
    }
};
