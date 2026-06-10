const c_api = @import("c_api.zig");
const std = @import("std");
const mp = @import("msgpack.zig");
const rpc = @import("rpc_encode.zig");
const grid_mod = @import("grid.zig");
const Grid = grid_mod.Grid;
const highlight = @import("highlight.zig");
const Highlights = highlight.Highlights;
const ResolvedAttrWithStyles = highlight.ResolvedAttrWithStyles;
pub const redraw = @import("redraw_handler.zig");
const Logger = @import("log.zig").Logger;
const config = @import("config.zig");
const flush = @import("flush.zig");
const rpc_session = @import("rpc_session.zig");
const rpc_transport = @import("rpc_transport.zig");
const shelf_packer = @import("shelf_packer.zig");
const vertexgen = @import("vertexgen.zig");

/// Re-exported here so callers in this file can spell `Stream` without
/// reaching into `rpc_transport`.
pub const Stream = rpc_transport.Stream;

/// Position/size snapshot for a known external grid. Used to detect
/// changes in anchor position (e.g. popupmenu re-show) and re-fire
/// on_external_window so the frontend can update window position.
pub const KnownExtGridInfo = struct { win: i64, start_row: i32, start_col: i32, rows: u32, cols: u32 };

/// Backing transport for the current RPC session.
pub const TransportKind = enum {
    /// Spawned nvim child process; stdin/stdout/stderr are 3 separate pipes.
    pipes,
    /// Connected to a running nvim server over TCP or unix socket.
    /// stdin_file and stdout_file alias the same fd; stderr_file is null.
    socket,
};

pub const Callbacks = struct {
    on_vertices_partial: ?*const fn (
        ctx: ?*anyopaque,
        main_verts: ?[*]const c_api.Vertex,
        main_count: usize,
        cursor_verts: ?[*]const c_api.Vertex,
        cursor_count: usize,
        flags: u32,
    ) callconv(.c) void = null,

    on_vertices_row: ?*const fn (
        ctx: ?*anyopaque,
        grid_id: i64,
        row_start: u32,
        row_count: u32,
        verts: ?[*]const c_api.Vertex,
        vert_count: usize,
        flags: u32,
        total_rows: u32,
        total_cols: u32,
    ) callconv(.c) void = null,

    on_atlas_ensure_glyph: ?c_api.AtlasEnsureGlyphFn = null,
    on_atlas_ensure_glyph_styled: ?c_api.AtlasEnsureGlyphStyledFn = null,

    on_log: ?*const fn (ctx: ?*anyopaque, p: [*]const u8, n: usize) callconv(.c) void = null,

    /// UTF-8 "<name>\t<size>"
    on_guifont: ?*const fn (ctx: ?*anyopaque, utf8: [*]const u8, len: usize) callconv(.c) void = null,

    /// Neovim 'linespace' (extra pixels between lines).
    on_linespace: ?*const fn (ctx: ?*anyopaque, linespace_px: i32) callconv(.c) void = null,

    /// Called when embedded nvim terminates (e.g. :q).
    /// exit_code: 0 = normal, 1+ = error (:cq), 128+N = signal N (Unix).
    on_exit: ?*const fn (ctx: ?*anyopaque, exit_code: i32) callconv(.c) void = null,

    /// Called when Neovim sets the window title (set_title UI event).
    on_set_title: ?*const fn (ctx: ?*anyopaque, title: [*]const u8, title_len: usize) callconv(.c) void = null,

    /// Called when Neovim sends the `restart` UI event (`:restart` command).
    /// listen_addr is the new server address that the core will attach to.
    /// Informational only — the core handles the actual reconnect; the
    /// frontend must NOT tear down its window or treat this as `on_exit`.
    on_restart: ?*const fn (ctx: ?*anyopaque, listen_addr: [*]const u8, listen_addr_len: usize) callconv(.c) void = null,

    /// Called when Neovim sends the `connect` UI event (`:connect <addr>`).
    /// server_addr is the server the UI is being hot-swapped to. Same
    /// reconnect machinery as `on_restart`; the only difference is that
    /// the previous server keeps running headless (it is not dying).
    on_connect: ?*const fn (ctx: ?*anyopaque, server_addr: [*]const u8, server_addr_len: usize) callconv(.c) void = null,

    /// Called when a grid should be displayed in an external window.
    on_external_window: ?*const fn (ctx: ?*anyopaque, grid_id: i64, win: i64, rows: u32, cols: u32, start_row: i32, start_col: i32) callconv(.c) void = null,

    /// Called when an external grid is closed.
    on_external_window_close: ?*const fn (ctx: ?*anyopaque, grid_id: i64) callconv(.c) void = null,

    /// Called when cursor moves to a different grid.
    on_cursor_grid_changed: ?*const fn (ctx: ?*anyopaque, grid_id: i64) callconv(.c) void = null,

    // ext_cmdline callbacks
    /// Called when cmdline should be shown.
    on_cmdline_show: ?*const fn (
        ctx: ?*anyopaque,
        content: [*]const c_api.CmdlineChunk,
        content_count: usize,
        pos: u32,
        firstc: u8,
        prompt: [*]const u8,
        prompt_len: usize,
        indent: u32,
        level: u32,
        prompt_hl_id: u32,
    ) callconv(.c) void = null,

    /// Called when cmdline should be hidden.
    on_cmdline_hide: ?*const fn (ctx: ?*anyopaque, level: u32) callconv(.c) void = null,

    /// Called when cmdline cursor position changes.
    on_cmdline_pos: ?*const fn (ctx: ?*anyopaque, pos: u32, level: u32) callconv(.c) void = null,

    /// Called when a special character is shown (e.g. after Ctrl-V).
    on_cmdline_special_char: ?*const fn (ctx: ?*anyopaque, c: [*]const u8, c_len: usize, shift: bool, level: u32) callconv(.c) void = null,

    /// Called when cmdline block (multi-line input) should be shown.
    on_cmdline_block_show: ?*const fn (
        ctx: ?*anyopaque,
        lines: [*]const c_api.CmdlineBlockLine,
        line_count: usize,
    ) callconv(.c) void = null,

    /// Called when a line is appended to cmdline block.
    on_cmdline_block_append: ?*const fn (
        ctx: ?*anyopaque,
        line: [*]const c_api.CmdlineChunk,
        chunk_count: usize,
    ) callconv(.c) void = null,

    /// Called when cmdline block should be hidden.
    on_cmdline_block_hide: ?*const fn (ctx: ?*anyopaque) callconv(.c) void = null,

    // ext_popupmenu callbacks
    on_popupmenu_show: ?*const fn (
        ctx: ?*anyopaque,
        items: ?*const anyopaque, // zonvie_popupmenu_item*
        item_count: usize,
        selected: i32,
        row: i32,
        col: i32,
        grid_id: i64,
        colors: ?*const c_api.PopupmenuColors,
    ) callconv(.c) void = null,

    on_popupmenu_hide: ?*const fn (ctx: ?*anyopaque) callconv(.c) void = null,

    on_popupmenu_select: ?*const fn (ctx: ?*anyopaque, selected: i32) callconv(.c) void = null,

    // ext_messages callbacks
    /// Called when a message should be shown.
    on_msg_show: ?*const fn (
        ctx: ?*anyopaque,
        view: c_api.zonvie_msg_view_type,
        kind: [*]const u8,
        kind_len: usize,
        chunks: [*]const c_api.MsgChunk,
        chunk_count: usize,
        replace_last: c_int,
        history: c_int,
        append: c_int,
        msg_id: i64,
        timeout_ms: u32,
    ) callconv(.c) void = null,

    /// Called when messages should be cleared.
    on_msg_clear: ?*const fn (ctx: ?*anyopaque) callconv(.c) void = null,

    /// Called when mode info should be shown (e.g., "-- INSERT --", recording).
    on_msg_showmode: ?*const fn (
        ctx: ?*anyopaque,
        view: c_api.zonvie_msg_view_type,
        chunks: [*]const c_api.MsgChunk,
        chunk_count: usize,
    ) callconv(.c) void = null,

    /// Called when showcmd info should be shown.
    on_msg_showcmd: ?*const fn (
        ctx: ?*anyopaque,
        view: c_api.zonvie_msg_view_type,
        chunks: [*]const c_api.MsgChunk,
        chunk_count: usize,
    ) callconv(.c) void = null,

    /// Called when ruler info should be shown.
    on_msg_ruler: ?*const fn (
        ctx: ?*anyopaque,
        view: c_api.zonvie_msg_view_type,
        chunks: [*]const c_api.MsgChunk,
        chunk_count: usize,
    ) callconv(.c) void = null,

    /// Called when message history should be shown.
    on_msg_history_show: ?*const fn (
        ctx: ?*anyopaque,
        entries: [*]const c_api.MsgHistoryEntry,
        entry_count: usize,
        prev_cmd: c_int,
    ) callconv(.c) void = null,

    // Clipboard callbacks
    /// Called to get clipboard content.
    /// Returns 1 on success, 0 on failure.
    on_clipboard_get: ?*const fn (
        ctx: ?*anyopaque,
        register: [*]const u8,
        out_buf: [*]u8,
        out_len: *usize,
        max_len: usize,
    ) callconv(.c) c_int = null,

    /// Called to set clipboard content.
    /// Returns 1 on success, 0 on failure.
    on_clipboard_set: ?*const fn (
        ctx: ?*anyopaque,
        register: [*]const u8,
        data: [*]const u8,
        len: usize,
    ) callconv(.c) c_int = null,

    /// SSH authentication prompt callback.
    /// Called when SSH mode detects a password/passphrase prompt.
    on_ssh_auth_prompt: ?*const fn (
        ctx: ?*anyopaque,
        prompt: [*]const u8,
        prompt_len: usize,
    ) callconv(.c) void = null,

    // ext_tabline callbacks
    /// Called when tabline should be updated.
    on_tabline_update: ?*const fn (
        ctx: ?*anyopaque,
        curtab: i64,
        tabs: [*]const c_api.TabEntry,
        tab_count: usize,
        curbuf: i64,
        buffers: [*]const c_api.BufferEntry,
        buffer_count: usize,
    ) callconv(.c) void = null,

    /// Called when tabline should be hidden.
    on_tabline_hide: ?*const fn (ctx: ?*anyopaque) callconv(.c) void = null,

    /// Called when a grid receives a grid_scroll event.
    /// Frontend should clear pixel-based smooth scroll offset for this grid.
    on_grid_scroll: ?*const fn (ctx: ?*anyopaque, grid_id: i64) callconv(.c) void = null,

    /// Called when IME should be turned off (mode change with ime.disable_on_modechange,
    /// or RPC zonvie_ime_off notification).
    on_ime_off: ?*const fn (ctx: ?*anyopaque) callconv(.c) void = null,

    /// Called when user-initiated quit is requested (window close button).
    /// has_unsaved: non-zero if there are unsaved buffers.
    on_quit_requested: ?*const fn (ctx: ?*anyopaque, has_unsaved: c_int) callconv(.c) void = null,

    // Phase 2: Core-managed atlas callbacks
    on_rasterize_glyph: ?c_api.RasterizeGlyphFn = null,
    on_atlas_upload: ?c_api.AtlasUploadFn = null,
    on_atlas_create: ?c_api.AtlasCreateFn = null,

    // Flush bracketing (for GPU buffer management)
    on_flush_begin: ?*const fn (ctx: ?*anyopaque) callconv(.c) void = null,
    on_flush_end: ?*const fn (ctx: ?*anyopaque) callconv(.c) void = null,

    // Neovim default_colors_set notification (colorscheme change).
    // fg/bg are 24-bit RGB (0x00RRGGBB) or 0xFFFFFFFF if not set.
    on_default_colors_set: ?*const fn (ctx: ?*anyopaque, fg: u32, bg: u32) callconv(.c) void = null,

    // ext_windows layout operation callbacks
    on_win_move: ?*const fn (ctx: ?*anyopaque, grid_id: i64, win: i64, flags: i32) callconv(.c) void = null,
    on_win_exchange: ?*const fn (ctx: ?*anyopaque, grid_id: i64, win: i64, count: i32) callconv(.c) void = null,
    on_win_rotate: ?*const fn (ctx: ?*anyopaque, grid_id: i64, win: i64, direction: i32, count: i32) callconv(.c) void = null,
    on_win_resize_equal: ?*const fn (ctx: ?*anyopaque) callconv(.c) void = null,
    on_win_move_cursor: ?*const fn (ctx: ?*anyopaque, direction: i32, count: i32) callconv(.c) i64 = null,

    // Phase B: Text-run shaping (ligatures)
    on_shape_text_run: ?c_api.ShapeTextRunFn = null,
    on_rasterize_glyph_by_id: ?c_api.RasterizeGlyphByIdFn = null,

    // ASCII fast path table callback
    on_get_ascii_table: ?c_api.GetAsciiTableFn = null,

    // Main row-buffer scroll fast path notification
    on_main_row_scroll: ?*const fn (
        ctx: ?*anyopaque,
        row_start: u32,
        row_end: u32,
        col_start: u32,
        col_end: u32,
        rows_delta: i32,
        total_rows: u32,
        total_cols: u32,
    ) callconv(.c) void = null,

    // External grid (sub-grid) row-buffer scroll fast path notification
    on_grid_row_scroll: ?*const fn (
        ctx: ?*anyopaque,
        grid_id: i64,
        row_start: u32,
        row_end: u32,
        col_start: u32,
        col_end: u32,
        rows_delta: i32,
        total_rows: u32,
        total_cols: u32,
    ) callconv(.c) void = null,
};

const PipeReader = rpc_session.PipeReader;
const CwdOwner = rpc_session.CwdOwner;

const GridEntry = flush.GridEntry;
const MAX_CACHED_SUBGRIDS = flush.MAX_CACHED_SUBGRIDS;
const CachedSubgrid = flush.CachedSubgrid;
const SubgridSnapshot = flush.SubgridSnapshot;
const STYLE_BOLD = flush.STYLE_BOLD;
const STYLE_ITALIC = flush.STYLE_ITALIC;
const STYLE_STRIKETHROUGH = flush.STYLE_STRIKETHROUGH;
const STYLE_UNDERLINE = flush.STYLE_UNDERLINE;
const STYLE_UNDERCURL = flush.STYLE_UNDERCURL;
const STYLE_UNDERDOUBLE = flush.STYLE_UNDERDOUBLE;
const STYLE_UNDERDOTTED = flush.STYLE_UNDERDOTTED;
const STYLE_UNDERDASHED = flush.STYLE_UNDERDASHED;
const RenderCells = flush.RenderCells;
const packStyleFlags = flush.packStyleFlags;
const MsgCachedLine = flush.MsgCachedLine;
pub const FlushCache = flush.FlushCache;

// Phase B: Shaping result cache (4-way set associative)
pub const SHAPE_CACHE_WAYS: usize = 4;
pub const SHAPE_CACHE_MAX_GLYPHS: usize = 64;

/// Round up to next power of 2 (for hash masking).
pub fn nextPow2(n: u32) u32 {
    if (n <= 1) return 1;
    var v: u32 = n - 1;
    v |= v >> 1;
    v |= v >> 2;
    v |= v >> 4;
    v |= v >> 8;
    v |= v >> 16;
    return v +% 1;
}

pub const ShapeCacheEntry = struct {
    key_hash: u64 = 0, // Primary hash (0 = empty)
    key_hash2: u64 = 0, // Secondary hash (different seed)
    font_gen: u64 = 0, // Font generation at time of caching
    scalar_count: u32 = 0,
    glyph_count: u32 = 0,
    glyph_ids: [SHAPE_CACHE_MAX_GLYPHS]u32 = undefined,
    clusters: [SHAPE_CACHE_MAX_GLYPHS]u32 = undefined,
    x_adv: [SHAPE_CACHE_MAX_GLYPHS]i32 = undefined,
    x_off: [SHAPE_CACHE_MAX_GLYPHS]i32 = undefined,
    y_off: [SHAPE_CACHE_MAX_GLYPHS]i32 = undefined,
};

/// Primary hash (FNV-1a, offset basis 0xcbf29ce484222325)
pub fn shapeCacheHash(scalars: []const u32, style_flags: u32) u64 {
    var h: u64 = 0xcbf29ce484222325;
    const prime: u64 = 0x100000001b3;
    h ^= @as(u64, style_flags);
    h *%= prime;
    for (scalars) |s| {
        h ^= @as(u64, s & 0xFFFF);
        h *%= prime;
        h ^= @as(u64, s >> 16);
        h *%= prime;
    }
    return if (h == 0) 1 else h;
}

/// Secondary hash (FNV-1a, different offset basis)
pub fn shapeCacheHash2(scalars: []const u32, style_flags: u32) u64 {
    var h: u64 = 0x9e3779b97f4a7c15;
    const prime: u64 = 0x100000001b3;
    h ^= @as(u64, style_flags);
    h *%= prime;
    for (scalars) |s| {
        h ^= @as(u64, s);
        h *%= prime;
    }
    return if (h == 0) 1 else h;
}

pub const Core = struct {
    const MAX_WRITE_QUEUE_SIZE: usize = 4 * 1024 * 1024; // 4MB cap for write queue

    alloc: std.mem.Allocator,
    cb: Callbacks,
    ctx: ?*anyopaque,

    last_sent_content_rev: u64 = 0,
    last_sent_cursor_rev: u64 = 0,
    last_ext_cursor_grid: i64 = 1, // Track which grid had cursor for external grid updates
    last_ext_cursor_rev: u64 = 0, // Track cursor revision for external grid updates
    pre_cmdline_cursor_grid: i64 = 1, // Cursor grid before cmdline was shown (for restoring after cmdline closes)
    pre_cmdline_cursor_row: u32 = 0,
    pre_cmdline_cursor_col: u32 = 0,

    log: Logger,
    grid: Grid,
    hl: Highlights,

    // Reusable vertex buffers (avoid alloc/free on every flush)
    main_verts: std.ArrayListUnmanaged(c_api.Vertex) = .{},
    cursor_verts: std.ArrayListUnmanaged(c_api.Vertex) = .{},

    row_verts: std.ArrayListUnmanaged(c_api.Vertex) = .{},

    // Scroll-aware flush: per-row vertex cache.
    // Each entry holds the last emitted vertices for that row.
    // On scroll, entries are logically shifted and y-coordinates adjusted.
    // Invalidated on resize, guifont, atlas reset.
    scroll_cache: std.ArrayListUnmanaged(std.ArrayListUnmanaged(c_api.Vertex)) = .{},
    scroll_cache_valid: std.DynamicBitSetUnmanaged = .{},
    scroll_cache_rows: u32 = 0,

    // Subgrid layout snapshot for scroll fast path.
    // Stores the (grid_id, row_start, row_end) of every composited subgrid
    // from the previous successful flush. Compared against the current layout
    // to detect position changes, additions, and removals that invalidate
    // cached row vertices inside the scroll region.
    prev_subgrid_snapshots: [MAX_CACHED_SUBGRIDS]SubgridSnapshot = undefined,
    prev_subgrid_snapshot_count: u32 = 0,

    // Reusable scratch buffers (zero-allocation hot path)
    tmp_cells: RenderCells = .{},
    row_cells: RenderCells = .{},
    grid_entries: std.ArrayListUnmanaged(GridEntry) = .{},
    key_buf: std.ArrayListUnmanaged(u8) = .{},

    msgid: std.atomic.Value(i64) = std.atomic.Value(i64).init(1),

    // Writer thread: non-blocking stdin writes via dedicated thread.
    // sendRaw() enqueues data here; writerThreadFn drains to stdin pipe.
    // Lock order: grid_mu must be acquired before write_queue_mu if both are needed.
    write_queue_mu: std.Thread.Mutex = .{},
    write_queue_cond: std.Thread.Condition = .{},
    write_queue: std.ArrayListUnmanaged(u8) = .{},
    write_queue_closed: bool = false,
    writer_failed: bool = false,
    writer_thread: ?std.Thread = null,

    // Mutex to protect grid state access from concurrent RPC and UI threads.
    grid_mu: std.Thread.Mutex = .{},

    // Mutex to protect stdin_file close-and-null (POSIX socket transport
    // aliases stdin/stdout on one fd). Prevents race between stop() and
    // cleanupSession() closing the same fd. Both must serialize via this mutex.
    stdin_close_mu: std.Thread.Mutex = .{},

    stop_flag: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    /// Set to true after nvim_ui_attach completes successfully.
    ui_attached: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    /// Stores pending focus state when setFocus is called before ui_attach.
    /// 0 = no pending, 1 = pending focus gained, 2 = pending focus lost.
    pending_focus: std.atomic.Value(u8) = std.atomic.Value(u8).init(0),
    thread: ?std.Thread = null,

    child_handle: ?std.process.Child.Id = null,
    stdin_file: ?Stream = null,
    stdout_file: ?Stream = null,
    stderr_file: ?Stream = null,
    stderr_thread: ?std.Thread = null,
    /// Heap-allocated state shared with the stderr pump thread.
    /// Lifetime: created at session spawn, freed by the pump thread's
    /// run() defer block on exit. This back-pointer in Core is just a
    /// handle for cleanupSession to call detachFromCore() before the
    /// pump might outlive Core (`:connect` orphan path). Always null
    /// it after detach / join — the pump destroys the struct itself.
    stderr_pump: ?*rpc_session.StderrPump = null,

    /// Transport mode of the current session.
    /// .pipes: spawned child + 3 pipes (stdin/stdout/stderr separate handles).
    /// .socket: connected to a running nvim via TCP/Unix socket. In this mode
    /// stdin_file and stdout_file alias the same fd; close() must run only
    /// once and stderr_file is null.
    transport_kind: TransportKind = .pipes,

    /// Owning pointer to the Windows named-pipe wrapper for the current
    /// session, when transport_kind == .socket and the platform is Windows.
    /// stdin_file / stdout_file's `Stream.close()` calls
    /// `WindowsOverlappedPipe.closeHandles()` which only fires
    /// `CancelIoEx` to abort pending overlapped I/O — neither the pipe
    /// HANDLE nor the event HANDLEs are closed there, because closing
    /// a HANDLE another thread is still using as the file argument to
    /// `GetOverlappedResult` (or as the wait HANDLE for an overlapped
    /// completion event) is undefined behavior per MSDN. The pipe
    /// HANDLE, the event HANDLEs, and the heap-allocated wrapper are
    /// all released exactly once via `session_pipe.destroy()` from
    /// cleanupSession, AFTER the writer / stderr threads have been
    /// joined. Without this separation, stop()/cleanupSession would
    /// close those HANDLEs and `alloc.destroy(self)` while the writer
    /// thread was still mid-writeAll(), corrupting kernel state and
    /// heap memory. Null on POSIX and on spawn-mode sessions.
    session_pipe: ?*rpc_transport.WindowsOverlappedPipe = null,

    /// Set by handleRestartEvent / handleConnectEvent to the next session's
    /// listen address (owned). Observed by the RPC run loop after the
    /// current session terminates; when non-null, the loop reconnects to
    /// this address instead of firing on_exit. Cleared once the next
    /// session is established.
    restart_pending_addr: ?[]u8 = null,

    /// Distinguishes how `restart_pending_addr` was queued:
    ///   - false (default): set by handleRestartEvent. The old nvim died
    ///     and a new instance came up at this address; if connecting back
    ///     fails, falling through to spawn the original argv is the
    ///     correct recovery (the user lost their session anyway).
    ///   - true: set by handleConnectEvent. `:connect` is a hot-swap that
    ///     orphans the old nvim (still alive headless on its own listen
    ///     socket); if connecting to the NEW server fails, spawning a
    ///     fresh local nvim would orphan the user's editing session in
    ///     the old nvim while opening a wholly different blank session.
    ///     Exit the run loop instead so the frontend can surface the
    ///     failure.
    /// Consumed (reset to false) by the run loop alongside
    /// restart_pending_addr.
    restart_pending_is_connect_hotswap: bool = false,

    /// Set by handleConnectEvent. When true, the run loop's cleanup must
    /// NOT wait on or kill the spawned child — `:connect` is a hot-swap
    /// where the old nvim stays alive headless and would otherwise make
    /// child.wait() block forever. The handle is dropped (orphaned).
    /// Consumed (reset to false) by the run loop before the next iteration.
    connect_keeps_child_alive: bool = false,

    drawable_w_px: u32 = 1,
    drawable_h_px: u32 = 1,
    cell_w_px: u32 = 1,
    cell_h_px: u32 = 1,

    /// Extra pixels between lines (Neovim 'linespace').
    linespace_px: u32 = 0,

    /// Set by zonvie_core_abort_flush() from on_flush_begin callback.
    /// When true, the flush pipeline skips vertex generation and atlas operations.
    /// Reset at the start of each flush cycle before on_flush_begin is called.
    flush_aborted: bool = false,

    init_rows: u32 = 24,
    init_cols: u32 = 80,

    // Synchronization for delaying nvim_ui_attach until actual layout is known.
    // The RPC thread waits on ui_attach_cond before sending nvim_ui_attach.
    // Call notifyLayoutReady() from the UI thread after renderer init.
    ui_attach_mutex: std.Thread.Mutex = .{},
    ui_attach_cond: std.Thread.Condition = .{},
    ui_attach_ready: bool = false,
    ui_attach_rows: u32 = 0,
    ui_attach_cols: u32 = 0,

    last_layout_rows: u32 = 0,
    last_layout_cols: u32 = 0,
    pending_resize_rows: u32 = 0,
    pending_resize_cols: u32 = 0,
    pending_resize_valid: bool = false,
    missing_glyph_log_count: u32 = 0,

    // Per-flush atlas/callback aggregation (reset at flush start, dumped at flush end).
    // Per-glyph log lines would dominate the trace; aggregating here gives one
    // [perf] atlas line per flush with rasterize / upload / pack totals.
    perf_rasterize_ns_total: u64 = 0,
    perf_upload_ns_total: u64 = 0,
    perf_pack_ns_total: u64 = 0,
    perf_rasterize_calls: u32 = 0,
    perf_upload_calls: u32 = 0,
    perf_atlas_create_calls: u32 = 0,
    perf_atlas_create_ns_total: u64 = 0,
    // ensureGlyphPhase2 / ensureGlyphByID wall time, including dispatch
    // overhead, cache check, and the rasterize/upload/pack subset already
    // accounted for above. (atlas_total_ns - rasterize_ns - upload_ns -
    // pack_ns) reveals pure dispatch overhead — i.e. how much glyph_pass
    // time the atlas-resolve path consumes outside of GPU work.
    perf_atlas_total_ns_total: u64 = 0,
    perf_atlas_total_calls: u32 = 0,

    // Thread ID of the thread currently inside handleRedraw (grid_mu is already held).
    // When updateLayoutPx is called from the SAME thread, it skips locking since
    // that thread already holds grid_mu. Using thread ID instead of a bool prevents
    // the UI thread from incorrectly skipping the lock when the RPC thread is in redraw.
    redraw_thread_id: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),

    // Tracking for external windows (to detect new/closed external grids)
    known_external_grids: std.AutoHashMapUnmanaged(i64, KnownExtGridInfo) = .{},

    // ext_cmdline UI extension flag (set before start)
    ext_cmdline_enabled: bool = false,

    // ext_popupmenu UI extension flag (set before start)
    ext_popupmenu_enabled: bool = false,

    // ext_messages UI extension flag (set before start)
    ext_messages_enabled: bool = false,

    // ext_tabline UI extension flag (set before start)
    ext_tabline_enabled: bool = false,

    // ext_windows UI extension flag (set before start)
    ext_windows_enabled: bool = false,

    // Throttle for msg_show (noice.nvim-style): delay display to accumulate messages
    // noice.nvim uses 1000/30 = ~33ms throttle by default
    msg_show_pending_since: ?i128 = null, // nanos timestamp when first msg_dirty was set
    msg_show_throttle_ns: i128 = 33 * std.time.ns_per_ms, // 33ms default throttle (matches noice.nvim)

    // Auto-hide deadlines for ext_float grids (nanos timestamp)
    msg_show_auto_hide_at: ?i128 = null, // grid -102 auto-hide deadline
    msg_history_auto_hide_at: ?i128 = null, // grid -103 auto-hide deadline

    // Scroll state for msg_show ext-float (Zonvie's own grid)
    msg_scroll_offset: u32 = 0, // Current scroll offset (lines from top)
    msg_total_lines: u32 = 0, // Total line count in current message content
    msg_cached_max_width: u32 = 0, // Cached max line width for grid sizing
    msg_scroll_pending: bool = false, // Pending scroll update (for throttling)
    msg_scroll_last_send: i128 = 0, // Last vertex send time (nanos)

    // Cached line data for msg_show scrolling (avoids re-parsing on every scroll)
    msg_line_cache: std.ArrayListUnmanaged(MsgCachedLine) = .{},
    msg_cache_valid: bool = false,

    // Track last executed command for split view label
    last_cmd_buf: [256]u8 = .{0} ** 256,
    last_cmd_len: usize = 0,
    last_cmd_firstc: u8 = 0, // ':' or '!' etc.
    last_cmd_start_time: ?i128 = null, // nanos timestamp when command started

    // Message routing config (loaded from config.toml)
    msg_config: config.Config = .{},
    // Config error notification: true after first notification attempt (prevents retry)
    config_error_sent: bool = false,

    // Blur transparency enabled (macOS only, Windows should keep false)
    blur_enabled: bool = false,

    // Inherit CWD from parent process (when true, don't set child cwd to $HOME)
    inherit_cwd: bool = false,

    // Background opacity for transparency (0.0 = fully transparent, 1.0 = opaque)
    background_opacity: f32 = 1.0,

    // GlyphEntry cache configuration (settable via C API)
    // ASCII cache: 128 * 4 = 512 entries (codepoint 0-127 × 4 style combinations)
    // Non-ASCII cache: hash table for Unicode chars >= 128
    glyph_cache_ascii_size: u32 = 512, // default: 128 ASCII × 4 styles
    glyph_cache_non_ascii_size: u32 = 256, // default: 256 entries hash table

    // Highlight cache size for flush vertex generation (configurable via [performance] in config.toml)
    hl_cache_size: u32 = 2048, // NOTE: default must match config.zig PerformanceConfig.hl_cache_size

    // Heap-allocated highlight cache buffers (sized by hl_cache_size, allocated on first flush)
    hl_cache_buf: ?[]highlight.ResolvedAttrWithStyles = null,
    hl_valid_buf: ?[]bool = null,
    hl_cache_initialized: bool = false,

    // Dynamic glyph caches (allocated on first use, reallocated if size changes)
    glyph_cache_ascii: ?[]c_api.GlyphEntry = null,
    glyph_valid_ascii: ?[]bool = null,
    glyph_cache_non_ascii: ?[]c_api.GlyphEntry = null,
    glyph_keys_non_ascii: ?[]u64 = null,
    glyph_cache_initialized: bool = false,

    // Phase B: Glyph-ID cache (for shaped glyphs; keyed by (glyph_id << 2) | style_index)
    glyph_cache_by_id: ?[]c_api.GlyphEntry = null,
    glyph_keys_by_id: ?[]u64 = null,

    // Phase B: Persistent shaping buffers (reused across flushes, zero per-call alloc)
    shaping_bufs: vertexgen.ShapingBuffers = .{},
    shaping_scalars: std.ArrayListUnmanaged(u32) = .{},
    shaping_col_widths: std.ArrayListUnmanaged(u32) = .{},
    /// Maps each shaping_scalars entry back to its composited column index.
    shaping_src_cols: std.ArrayListUnmanaged(u32) = .{},

    /// Pointer to the float overlay overflow map for the current ext grid.
    /// Set during ext grid composition, null during main grid / non-ext-grid paths.
    flush_float_overlay: ?*const flush.FloatOverlayMap = null,

    /// Persistent float overlay map reused across flushes (avoids per-flush allocation).
    /// Cleared and repopulated for each ext grid that has float overlays.
    flush_float_overlay_buf: flush.FloatOverlayMap = .{},

    /// Per-instance emoji cluster context for the current rasterize callback.
    /// Set during flush vertex generation, read by on_rasterize_glyph callbacks.
    emoji_cluster_buf: [16]u32 = undefined,
    emoji_cluster_len: u8 = 0,

    // Phase B: Shaping result cache (4-way set associative, keyed by text content + style)
    shape_cache_size: u32 = 4096, // total entries (configurable via [performance] in config.toml)
    shape_cache_sets: u32 = 2048, // number of sets (power of 2, computed from shape_cache_size)
    shape_cache: ?[]ShapeCacheEntry = null,
    font_generation: u64 = 0,

    // ASCII fast path tables (4 style variants × 128 codepoints, no heap alloc)
    ascii_glyph_ids: [4][128]u32 = .{.{0} ** 128} ** 4,
    ascii_x_advances: [4][128]i32 = .{.{0} ** 128} ** 4,
    ascii_lig_triggers: [4][128]u8 = .{.{0} ** 128} ** 4,
    ascii_tables_valid: bool = false,

    // Phase 2: Core-managed atlas
    atlas_packer: ?shelf_packer.ShelfPacker = null,
    atlas_w: u32 = 2048,
    atlas_h: u32 = 2048,
    atlas_initialized: bool = false,
    atlas_reset_during_flush: bool = false,

    // Set to true after successful start(); prevents post-start setter calls
    started: bool = false,

    // Owned copy of nvim path (kept alive for runLoop thread)
    nvim_path_owned: ?[]const u8 = null,

    // SSH mode flags
    is_ssh_mode: bool = false,
    ssh_auth_pending: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    ssh_auth_done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    // Popupmenu state (for tracking window)
    popupmenu_win_id: ?i64 = null,
    popupmenu_buf_id: ?i64 = null,

    // Option-as-Meta setting (0=both, 1=none, 2=only_left, 3=only_right).
    // Updated via RPC notification "zonvie_option_as_meta". Atomic for
    // cross-thread reads from the frontend UI thread.
    option_as_meta: std.atomic.Value(u8) = std.atomic.Value(u8).init(0),

    // IME preedit-via-extmark state. Written from the frontend UI thread (IME
    // composition callbacks) and also from the RPC thread (resetSessionState
    // on :restart/:connect), so these are atomic.
    preedit_setup_done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false), // hl groups defined
    preedit_visible: std.atomic.Value(bool) = std.atomic.Value(bool).init(false), // an inline preedit extmark is set

    // RPC channel ID (extracted from nvim_get_api_info response)
    channel_id: ?i64 = null,
    get_api_info_msgid: ?i64 = null,

    // Quit request msgid (for tracking nvim_exec_lua response)
    // Atomic to avoid data race between UI thread (requestQuit) and RPC thread (handleRpcResponse)
    // 0 means no pending request
    quit_request_msgid: std.atomic.Value(i64) = std.atomic.Value(i64).init(0),

    // Clipboard setup done flag
    clipboard_setup_done: bool = false,

    // Neon glow configuration (read from vim.g.zonvie_glow)
    // glow_enabled and glow_intensity are atomic: written by RPC thread, read by frontend draw thread.
    glow_enabled: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    glow_all: bool = false, // true = apply glow to all cells (groups = "all")
    glow_radius_px: f32 = 6.0,
    glow_intensity_bits: std.atomic.Value(u32) = std.atomic.Value(u32).init(@bitCast(@as(f32, 0.8))),
    glow_hl_ids: ?std.AutoHashMap(u32, void) = null,
    // Owned strings — each element is alloc.dupe'd from RPC response
    glow_group_names: std.ArrayListUnmanaged([]const u8) = .{},
    // Atomic msgid for tracking pending glow config RPC request (0 = no pending)
    glow_request_msgid: std.atomic.Value(i64) = std.atomic.Value(i64).init(0),
    // Startup retry counter: decremented on nil response, not on each flush.
    // Needs enough retries for -c commands to execute after Neovim startup.
    glow_startup_retries: u8 = 30,

    pub fn getGlowIntensity(self: *const Core) f32 {
        return @bitCast(self.glow_intensity_bits.load(.acquire));
    }

    pub fn setGlowIntensity(self: *Core, val: f32) void {
        self.glow_intensity_bits.store(@bitCast(val), .release);
    }

    pub fn init(alloc: std.mem.Allocator, cb: Callbacks, ctx: ?*anyopaque) Core {
        return .{
            .alloc = alloc,
            .cb = cb,
            .ctx = ctx,
            .log = .{ .cb = cb.on_log, .ctx = ctx },
            .grid = Grid.init(alloc),
            .hl = Highlights.init(alloc),
        };
    }

    /// Lightweight constructor for unit tests. No callbacks, no threads.
    pub fn initForTest(alloc: std.mem.Allocator) Core {
        return .{
            .alloc = alloc,
            .cb = .{},
            .ctx = null,
            .log = .{ .cb = null, .ctx = null },
            .grid = Grid.init(alloc),
            .hl = Highlights.init(alloc),
        };
    }

    /// Cleanup for test-created Core instances (no threads/processes to join).
    pub fn deinitForTest(self: *Core) void {
        self.hl.deinit();
        self.grid.deinit();
        self.main_verts.deinit(self.alloc);
        self.cursor_verts.deinit(self.alloc);
        self.row_verts.deinit(self.alloc);
        for (self.scroll_cache.items) |*row_cache| {
            row_cache.deinit(self.alloc);
        }
        self.scroll_cache.deinit(self.alloc);
        self.scroll_cache_valid.deinit(self.alloc);
        self.tmp_cells.deinit(self.alloc);
        self.row_cells.deinit(self.alloc);
        self.grid_entries.deinit(self.alloc);
        self.key_buf.deinit(self.alloc);
        self.write_queue.deinit(self.alloc);
        self.shaping_bufs.deinit(self.alloc);
        self.shaping_scalars.deinit(self.alloc);
        self.shaping_col_widths.deinit(self.alloc);
        self.shaping_src_cols.deinit(self.alloc);
        self.flush_float_overlay_buf.deinit(self.alloc);
        self.freeGlowGroupNames();
        self.glow_group_names.deinit(self.alloc);
        if (self.glow_hl_ids) |*m| m.deinit();
        self.deinitHlCache();
        self.deinitGlyphCache();
    }

    pub fn start(self: *Core, nvim_path: []const u8, rows: u32, cols: u32) !void {
        self.init_rows = rows;
        self.init_cols = cols;
        // Copy nvim_path so it outlives the caller's scope (thread safety)
        self.nvim_path_owned = self.alloc.dupe(u8, nvim_path) catch null;
        self.thread = try std.Thread.spawn(.{}, runLoop, .{self});
        self.started = true;
    }

    /// Start in connect mode: attach to a Neovim server already listening
    /// at `listen_addr` (TCP `host:port` or Unix socket path) instead of
    /// spawning a child. Used by both the future "connect to running
    /// nvim" CLI flag and as the initial entry that the runLoop already
    /// supports via the `:restart` machinery.
    ///
    /// nvim_path_owned is left empty so the connect-failure fall-through
    /// inside runLoop does NOT silently spawn a local nvim — that would
    /// surprise a caller who explicitly opted into connect mode.
    pub fn startConnect(self: *Core, listen_addr: []const u8, rows: u32, cols: u32) !void {
        self.init_rows = rows;
        self.init_cols = cols;
        self.nvim_path_owned = self.alloc.dupe(u8, "") catch null;
        // Pre-populate restart_pending_addr so the run loop's first
        // iteration takes the connect path. Same machinery as `:restart`.
        self.restart_pending_addr = try self.alloc.dupe(u8, listen_addr);
        self.thread = try std.Thread.spawn(.{}, runLoop, .{self});
        self.started = true;
    }

    /// Reset session-scoped state between RPC sessions (called by the run
    /// loop when transitioning to the next session for `:restart` /
    /// `:connect`). Clears transient flags, in-flight RPC msgids, and
    /// every piece of state tied to the previous server's grid_id space
    /// or UI overlays so the new session starts from a clean slate.
    ///
    /// Channel-bound state (cleared here):
    ///   - external windows + their grid registry (existing, see below)
    ///   - composited grid layout: sub_grids / win_pos / grid_win_ids /
    ///     win_layer / viewport(_margins) / cell_overflow / grid_metrics.
    ///     The new server never sends grid_destroy for grid_ids it does
    ///     not know about, so leftover entries would be rendered as
    ///     stale floats (flush.zig:rebuildMain) and reported as visible
    ///     by getVisibleGridsLocked (hit-testing).
    ///   - ext UI state: cmdline_states / cmdline_block / popupmenu /
    ///     tabline_state / message_state / msg_history_state. The new
    ///     server does not send hide events for overlays it never
    ///     created.
    ///   - cursor state: cursor_grid may point at a now-deleted sub_grid.
    ///   - Core-side flush bookkeeping: last_sent_*_rev, msg throttle
    ///     state, last_cmd snapshot, popupmenu Lua-mirror handles,
    ///     pre_cmdline cursor snapshot, prev_subgrid_snapshots.
    ///
    /// Frontend overlay teardown:
    ///   - external_grids cleanup below already fires on_external_window_close
    ///     for cmdline / popupmenu / message / msg_history overlays
    ///     (those use external grid_ids -100..-103).
    ///   - tabline lives outside that path, so on_tabline_hide is fired
    ///     explicitly. on_popupmenu_hide / on_msg_clear are also fired
    ///     defensively in case the frontend tracks overlay state outside
    ///     the external-grid path.
    ///
    /// Preserved intentionally:
    ///   - global grid (id=1) cells/dimensions: the new server overwrites
    ///     them via grid_resize + grid_line right after attach. The
    ///     frontend's last committed frame keeps the screen visually
    ///     stable in the gap (no flush runs between sessions).
    ///   - hl table: hl_ids are redefined by hl_attr_define on attach.
    ///   - atlas / glyph caches / shape cache: keyed by content + style
    ///     + font_generation; valid as long as font is unchanged.
    ///   - mode info / cursor shape / cursor_visible: replaced by the
    ///     new session's mode_info_set + mode_change.
    ///   - layout dimensions (last_layout_rows/cols, init_rows/cols).
    ///
    /// EXCEPTION: external windows (multigrid windows mapped to OS-level
    /// windows by the frontend) ARE channel-bound. The new server uses a
    /// fresh grid_id space, so old grid_ids in known_external_grids /
    /// grid.external_grids would never receive grid_resize from the new
    /// server and never appear in the closed-detection diff at
    /// flush.notifyExternalWindowChanges. Without explicit teardown, the
    /// stale OS windows remain visible holding dead grid state. Fire
    /// on_external_window_close for each known grid_id and clear both
    /// maps before the next session.
    ///
    /// MUST be called only from the RPC thread, after the previous
    /// session's writer thread has been joined and pipes/sockets closed.
    pub fn resetSessionState(self: *Core) void {
        // UI attachment must be re-issued after reconnect.
        self.ui_attached.store(false, .seq_cst);

        // Channel-bound state.
        self.clipboard_setup_done = false;

        // Preedit highlight groups and namespace live in the dead session;
        // re-define them and re-place the extmark on the next composition.
        self.preedit_setup_done.store(false, .monotonic);
        self.preedit_visible.store(false, .monotonic);

        // In-flight RPC IDs from the dead channel — drop tracking so any
        // stale response from the new server (very unlikely; new msgid
        // counter starts fresh on the nvim side) does not match.
        self.get_api_info_msgid = null;
        self.quit_request_msgid.store(0, .release);
        self.glow_request_msgid.store(0, .release);

        // Re-arm the glow startup probe so it queries vim.g.zonvie_glow on
        // the new server (the user's init.lua may set it again, identically
        // or differently).
        self.glow_startup_retries = 30;

        // Pending focus state from before the reconnect should not leak —
        // the new server has its own initial focus state.
        self.pending_focus.store(0, .seq_cst);

        // SSH auth flags only apply to spawn-mode SSH sessions; reset so a
        // future spawn-mode session (re-spawn fallback) starts unauthenticated.
        self.ssh_auth_pending.store(false, .seq_cst);
        self.ssh_auth_done.store(false, .seq_cst);

        // Transport handles are cleaned up by the caller (closed and nulled);
        // here we only flip the kind tag for clarity until the next session
        // re-assigns it.
        self.transport_kind = .pipes;

        // Re-arm the writer queue: the previous session's cleanup set
        // write_queue_closed=true so the writer thread would drain and exit.
        // Clearing it now allows startWriterThread() to succeed for the
        // next session.
        self.write_queue_mu.lock();
        self.write_queue_closed = false;
        self.writer_failed = false;
        self.write_queue.clearRetainingCapacity();
        self.write_queue_mu.unlock();

        // === Grid-protected critical section ===
        //
        // Everything below mutates state that the frontend reads under
        // grid_mu via the public C API (`zonvie_core_get_visible_grids`,
        // viewport / cursor lookups, message tick, etc.). Without this
        // lock, a frontend reader holding grid_mu could race with us
        // clear/deinit'ing AutoHashMap nodes or sub_grid cell buffers.
        //
        // Locking contract (matches handleRedraw at rpc_session.zig:849):
        // frontend callbacks (on_external_window_close, on_tabline_hide,
        // on_popupmenu_hide, on_msg_clear) execute while grid_mu is held.
        // Callbacks MUST NOT call zonvie_core_get_* or any other API that
        // re-acquires grid_mu, otherwise this thread will deadlock against
        // its own lock.
        //
        // The `defer unlock` covers every early return path here (none
        // exist today, but future edits stay safe).
        self.grid_mu.lock();
        defer self.grid_mu.unlock();

        // Tear down channel-bound external-window state. See doc comment
        // above for the rationale (new server's grid_id space is fresh,
        // so any stale grid_id left in these maps can later be matched
        // against an unrelated win_pos / grid_resize from the new server
        // and silently re-promote a normal window to "external", or feed
        // a stale target size into the next win_external_pos diff).
        //
        // Fire close callbacks first so the frontend can dismiss its OS
        // windows; then clear every channel-bound map so the new session
        // starts with an empty external-grid registry.
        if (self.known_external_grids.count() > 0) {
            const closed_count = self.known_external_grids.count();
            if (self.cb.on_external_window_close) |cb| {
                var it = self.known_external_grids.keyIterator();
                while (it.next()) |grid_id_ptr| {
                    cb(self.ctx, grid_id_ptr.*);
                }
            }
            self.known_external_grids.clearRetainingCapacity();
            self.log.write("resetSessionState: closed {d} external windows from previous session\n", .{closed_count});
        }
        self.grid.external_grids.clearRetainingCapacity();
        // ext_windows_grids: grid_id -> win_id mapping. Without clearing,
        // a fresh win_pos for the same grid_id on the new server hits
        // the redraw_handler.zig stale-detection path that re-promotes
        // it to external (redraw_handler.zig:~1171).
        self.grid.ext_windows_grids.clearRetainingCapacity();
        // external_grid_target_sizes: dimensions used to match resize
        // events to known external grids (redraw_handler.zig:~960).
        // Stale entries would feed the wrong size into the new session.
        self.grid.external_grid_target_sizes.clearRetainingCapacity();
        // pending_ext_window_grids: grids waiting for their first
        // grid_resize before the frontend window is created.
        self.grid.pending_ext_window_grids.clearRetainingCapacity();
        // pending_grid_resizes / pending_win_ops: queued ops referring
        // to old-session grid_ids; carrying them across would apply to
        // unrelated grids in the new session.
        self.grid.pending_grid_resizes.clearRetainingCapacity();
        self.grid.pending_win_ops.clearRetainingCapacity();

        // Composited / multigrid layout, ext UI overlays, cursor state.
        // See doc comment on this function for the full rationale.
        self.grid.resetForNewSession();

        // Frontend overlay teardown for paths not covered by the external
        // window cleanup above. The cmdline / popupmenu / message external
        // grids are torn down via on_external_window_close (fired by the
        // known_external_grids loop above), but:
        //   - tabline is rendered without an external grid; without an
        //     explicit hide the frontend keeps the old tabs on screen
        //     until the new session sends tabline_update.
        //   - on_popupmenu_hide / on_msg_clear are fired defensively in
        //     case the frontend tracks overlay state outside the
        //     external-grid path (e.g. an in-window popup overlay).
        if (self.cb.on_tabline_hide) |cb| cb(self.ctx);
        if (self.cb.on_popupmenu_hide) |cb| cb(self.ctx);
        if (self.cb.on_msg_clear) |cb| cb(self.ctx);

        // Core-side flush bookkeeping. Without resetting these, the next
        // flush could short-circuit on rev equality or use stale
        // window-handle references from the previous channel.
        // These fields are consulted from the flush path which already
        // runs under grid_mu (see handleRedraw); resetting them inside
        // this critical section keeps the flush invariants consistent.
        self.last_sent_content_rev = 0;
        self.last_sent_cursor_rev = 0;
        self.last_ext_cursor_grid = 1;
        self.last_ext_cursor_rev = 0;
        self.pre_cmdline_cursor_grid = 1;
        self.pre_cmdline_cursor_row = 0;
        self.pre_cmdline_cursor_col = 0;
        self.popupmenu_win_id = null;
        self.popupmenu_buf_id = null;

        // ext_messages timing / scroll state was tied to the old session's
        // msg_show events; carrying it across would auto-hide the new
        // session's first message at the old deadline.
        self.msg_show_pending_since = null;
        self.msg_show_auto_hide_at = null;
        self.msg_history_auto_hide_at = null;
        self.msg_scroll_offset = 0;
        self.msg_total_lines = 0;
        self.msg_cached_max_width = 0;
        self.msg_scroll_pending = false;
        self.msg_scroll_last_send = 0;
        self.msg_cache_valid = false;
        // MsgCachedLine has only fixed-size buffers (no heap-owned strings).
        self.msg_line_cache.clearRetainingCapacity();

        // Last command tracking for the split-view label was a snapshot
        // of the old session's :commands.
        self.last_cmd_len = 0;
        self.last_cmd_firstc = 0;
        self.last_cmd_start_time = null;

        // Subgrid layout snapshot for scroll fast path: stale entries
        // would reference grid_ids the new session has not (yet) created.
        self.prev_subgrid_snapshot_count = 0;

        self.log.write("resetSessionState: cleared session-scoped state\n", .{});
    }

    /// Signal the RPC thread that the actual layout is known and nvim_ui_attach
    /// can be sent with the correct dimensions. Must be called from the UI
    /// thread after the renderer is initialized and actual rows/cols are computed.
    /// Idempotent: subsequent calls after the first are no-ops.
    pub fn notifyLayoutReady(self: *Core, rows: u32, cols: u32) void {
        self.ui_attach_mutex.lock();
        defer self.ui_attach_mutex.unlock();
        if (self.ui_attach_ready) return;
        self.ui_attach_rows = rows;
        self.ui_attach_cols = cols;
        // Pre-set last_layout to suppress a redundant resize after attach.
        self.last_layout_rows = rows;
        self.last_layout_cols = cols;
        self.ui_attach_ready = true;
        self.ui_attach_cond.signal();
        self.log.write("notifyLayoutReady: rows={d} cols={d}\n", .{ rows, cols });
    }

    pub fn stop(self: *Core) void {
        self.stop_flag.store(true, .seq_cst);

        // Unblock RPC thread if it is waiting on ui_attach_cond
        {
            self.ui_attach_mutex.lock();
            defer self.ui_attach_mutex.unlock();
            self.ui_attach_ready = true;
            self.ui_attach_cond.signal();
        }

        // Signal writer thread to stop and capture thread handle under lock
        var wt: ?std.Thread = null;
        {
            self.write_queue_mu.lock();
            self.write_queue_closed = true;
            wt = self.writer_thread;
            self.writer_thread = null;
            self.write_queue_cond.signal();
            self.write_queue_mu.unlock();
        }

        // Unblock writer thread's writeAll() if blocked on transport I/O.
        // Transport-specific semantics of Stream.close():
        //   - POSIX (.file): closes the fd outright. For socket transport
        //     (connect mode) stdin_file and stdout_file alias the same fd;
        //     a second close would close an unrelated fd that the kernel
        //     may have already recycled, so we null the alias to skip
        //     cleanupSession's stdout close.
        //   - Windows named pipe (.win_pipe): calls closeHandles() which
        //     only fires CancelIoEx — the pipe HANDLE itself stays alive
        //     until session_pipe.destroy() runs in cleanupSession (after
        //     all threads holding a Stream value have been joined). We
        //     still null the stdout alias to keep the cleanupSession path
        //     symmetric: closeHandles is idempotent under its swap()
        //     guard, but skipping the duplicate call is clearer.
        // Serialize with cleanupSession() (rpc_session.zig) to prevent
        // a race where both threads close the same fd. For POSIX .socket
        // transport (where stdin/stdout alias the same fd), double-close
        // causes EBADF signal 6. Whichever thread gets the lock first wins;
        // the other thread's `if (self.stdin_file)` check then sees null.
        self.stdin_close_mu.lock();
        defer self.stdin_close_mu.unlock();
        if (self.stdin_file) |f| {
            // For POSIX .socket transport (connect mode, where stdin/
            // stdout alias the same fd) close() alone does not wake
            // the reader/writer thread blocked on the fd. Issue
            // shutdown(SHUT_RDWR) first so those threads return EOF /
            // EPIPE and can be join()ed below; otherwise stop() would
            // hang waiting on self.thread / writer thread join.
            f.shutdownIfSocket(self.transport_kind == .socket);
            f.close();
            self.stdin_file = null;
            if (self.transport_kind == .socket) {
                self.stdout_file = null;
            }
        }

        // Join writer thread. It exits via:
        //   - clean shutdown: write_queue_closed observed with empty queue
        //   - I/O error: POSIX broken-pipe from the stdin close above, or
        //     OperationAborted from CancelIoEx on the Windows pipe HANDLE
        if (wt) |t| t.join();

        if (self.child_handle) |_| {
            // On Windows targets, std.posix.kill is not available.
            // We rely on closing stdin + the child termination path in runLoop().
            if (comptime @import("builtin").os.tag != .windows) {
                // Keep POSIX behavior.
                // NOTE: Child.Id is pid_t on POSIX.
                const pid: std.posix.pid_t = @intCast(self.child_handle.?);
                _ = std.posix.kill(pid, std.posix.SIG.TERM) catch {};
            }
        }

        if (self.thread) |t| t.join();
        self.thread = null;

        // Defensive: if a stderr pump is still pointing at Core (e.g., a
        // failure path bypassed cleanupSession), detach it now so its
        // run() loop stops dereferencing Core before we free Core's
        // storage below, then release Core's ref so the struct can be
        // freed when the pump thread releases its own. Normal flows
        // have cleanupSession already null both fields by this point.
        if (self.stderr_pump) |p| {
            p.detachFromCore();
            p.release();
            self.stderr_pump = null;
        }
        if (self.stderr_thread) |t2| t2.join();
        self.stderr_thread = null;

        if (self.stdout_file) |f| f.close();
        if (self.stderr_file) |f| f.close();
        self.stdout_file = null;
        self.stderr_file = null;

        self.child_handle = null;

        self.hl.deinit();
        self.grid.deinit();

        // Clean up scratch buffers
        self.main_verts.deinit(self.alloc);
        self.cursor_verts.deinit(self.alloc);
        self.row_verts.deinit(self.alloc);
        for (self.scroll_cache.items) |*row_cache| {
            row_cache.deinit(self.alloc);
        }
        self.scroll_cache.deinit(self.alloc);
        self.scroll_cache_valid.deinit(self.alloc);
        self.tmp_cells.deinit(self.alloc);
        self.row_cells.deinit(self.alloc);
        self.grid_entries.deinit(self.alloc);
        self.key_buf.deinit(self.alloc);
        self.write_queue.deinit(self.alloc);

        // Free nvim path copy
        if (self.nvim_path_owned) |p| {
            self.alloc.free(p);
            self.nvim_path_owned = null;
        }

        // Free any pending restart address (queued but never consumed because
        // stop() raced ahead of the run loop's restart handling). Reset the
        // companion hot-swap flag too — the run loop reads them as a pair.
        if (self.restart_pending_addr) |a| {
            self.alloc.free(a);
            self.restart_pending_addr = null;
        }
        self.restart_pending_is_connect_hotswap = false;

        // Free shaping buffers (Phase B)
        self.shaping_bufs.deinit(self.alloc);
        self.shaping_scalars.deinit(self.alloc);
        self.shaping_col_widths.deinit(self.alloc);
        self.shaping_src_cols.deinit(self.alloc);
        self.flush_float_overlay_buf.deinit(self.alloc);

        // Free glow state
        self.freeGlowGroupNames();
        self.glow_group_names.deinit(self.alloc);
        if (self.glow_hl_ids) |*m| m.deinit();

        // Free session state that was previously leaked on stop.
        self.known_external_grids.deinit(self.alloc);
        self.known_external_grids = .{};
        self.msg_line_cache.deinit(self.alloc);
        self.msg_line_cache = .{};
        self.msg_config.deinit();
        self.msg_config = .{};

        // Free caches
        self.deinitHlCache();
        self.deinitGlyphCache();
    }

    /// Ensure scroll_cache has exactly `target_rows` entries.
    /// Grows or shrinks the per-row vertex lists as needed.
    pub fn ensureScrollCache(self: *Core, target_rows: u32) !void {
        const cur = self.scroll_cache_rows;
        if (cur == target_rows and self.scroll_cache.items.len == target_rows) return;

        // Shrink: deinit excess row buffers
        if (self.scroll_cache.items.len > target_rows) {
            for (self.scroll_cache.items[target_rows..]) |*row_buf| {
                row_buf.deinit(self.alloc);
            }
            self.scroll_cache.items.len = target_rows;
        }

        // Grow: append empty row buffers
        while (self.scroll_cache.items.len < target_rows) {
            try self.scroll_cache.append(self.alloc, .{});
        }

        // Resize the valid bitset
        if (self.scroll_cache_valid.bit_length != target_rows) {
            self.scroll_cache_valid.deinit(self.alloc);
            self.scroll_cache_valid = .{}; // zero state so use-after-free cannot occur on alloc failure
            self.scroll_cache_rows = 0; // invalidate cache_ready check in flush
            self.scroll_cache_valid = try std.DynamicBitSetUnmanaged.initEmpty(self.alloc, target_rows);
        }

        self.scroll_cache_rows = target_rows;
    }

    /// Invalidate all scroll cache entries (e.g., on resize, guifont, atlas reset).
    /// Also releases per-row vertex capacity to reclaim peak memory from prior frames.
    pub fn invalidateScrollCache(self: *Core) void {
        // Free per-row vertex buffers to release peak capacity
        for (self.scroll_cache.items) |*row_buf| {
            row_buf.deinit(self.alloc);
        }
        self.scroll_cache.items.len = 0;

        if (self.scroll_cache_valid.bit_length != 0) {
            self.scroll_cache_valid.unsetAll();
        }
        self.scroll_cache_rows = 0;

        // Reset subgrid snapshot so the next flush treats all subgrids as new.
        self.prev_subgrid_snapshot_count = 0;
    }

    /// Deinitialize glyph caches (call before changing cache sizes or on destroy)
    fn deinitGlyphCache(self: *Core) void {
        if (self.glyph_cache_ascii) |buf| {
            self.alloc.free(buf);
            self.glyph_cache_ascii = null;
        }
        if (self.glyph_valid_ascii) |buf| {
            self.alloc.free(buf);
            self.glyph_valid_ascii = null;
        }
        if (self.glyph_cache_non_ascii) |buf| {
            self.alloc.free(buf);
            self.glyph_cache_non_ascii = null;
        }
        if (self.glyph_keys_non_ascii) |buf| {
            self.alloc.free(buf);
            self.glyph_keys_non_ascii = null;
        }
        // Phase B: glyph-ID cache
        if (self.glyph_cache_by_id) |buf| {
            self.alloc.free(buf);
            self.glyph_cache_by_id = null;
        }
        if (self.glyph_keys_by_id) |buf| {
            self.alloc.free(buf);
            self.glyph_keys_by_id = null;
        }
        // Phase B: shaping result cache
        if (self.shape_cache) |buf| {
            self.alloc.free(buf);
            self.shape_cache = null;
        }
        self.glyph_cache_initialized = false;
    }

    /// Initialize glyph caches based on current size settings
    pub fn initGlyphCache(self: *Core) !void {
        if (self.glyph_cache_initialized) return;

        const ascii_size = self.glyph_cache_ascii_size;
        const non_ascii_size = self.glyph_cache_non_ascii_size;

        self.glyph_cache_ascii = try self.alloc.alloc(c_api.GlyphEntry, ascii_size);
        self.glyph_valid_ascii = try self.alloc.alloc(bool, ascii_size);
        self.glyph_cache_non_ascii = try self.alloc.alloc(c_api.GlyphEntry, non_ascii_size);
        self.glyph_keys_non_ascii = try self.alloc.alloc(u64, non_ascii_size);

        // Initialize valid flags to false
        @memset(self.glyph_valid_ascii.?, false);
        // Initialize keys to invalid sentinel
        const INVALID_KEY: u64 = 0xFFFFFFFFFFFFFFFF;
        @memset(self.glyph_keys_non_ascii.?, INVALID_KEY);

        // Phase B: glyph-ID cache (same size as non-ASCII cache)
        self.glyph_cache_by_id = try self.alloc.alloc(c_api.GlyphEntry, non_ascii_size);
        self.glyph_keys_by_id = try self.alloc.alloc(u64, non_ascii_size);
        @memset(self.glyph_keys_by_id.?, INVALID_KEY);

        // Phase B: shaping result cache (4-way set associative)
        // Sets count derived from shape_cache_size / 2 (not / WAYS) to maintain
        // the same number of sets when associativity increases. Total entries =
        // sets * WAYS, which is 2x the user-configured size for better collision resistance.
        self.shape_cache_sets = nextPow2(@max(1, self.shape_cache_size >> 1));
        const shape_total: usize = @as(usize, self.shape_cache_sets) * SHAPE_CACHE_WAYS;
        self.shape_cache = try self.alloc.alloc(ShapeCacheEntry, shape_total);
        @memset(self.shape_cache.?, .{});

        self.glyph_cache_initialized = true;
    }

    /// Reset glyph cache valid flags.
    /// Called when the frontend atlas is invalidated (e.g. guifont change),
    /// so that the next flush re-queries all glyphs via callbacks.
    pub fn resetGlyphCacheFlags(self: *Core) void {
        if (self.glyph_valid_ascii) |buf| {
            @memset(buf, false);
        }
        if (self.glyph_keys_non_ascii) |buf| {
            const INVALID_KEY: u64 = 0xFFFFFFFFFFFFFFFF;
            @memset(buf, INVALID_KEY);
        }
        // Phase B: glyph-ID cache
        if (self.glyph_keys_by_id) |buf| {
            const INVALID_KEY: u64 = 0xFFFFFFFFFFFFFFFF;
            @memset(buf, INVALID_KEY);
        }
    }

    /// Reset shaping result cache. Called on guifont/font feature change.
    /// NOT called on atlas reset (shaping results are atlas-independent).
    pub fn resetShapeCache(self: *Core) void {
        self.font_generation +%= 1;
        if (self.shape_cache) |buf| {
            @memset(buf, .{});
        }
        self.ascii_tables_valid = false;
    }

    /// Lazily load ASCII fast path tables from the frontend.
    /// Called once after font change. No-op if callback is not registered.
    /// Returns true if tables were loaded (or already valid).
    pub fn loadAsciiTables(self: *Core) bool {
        if (self.ascii_tables_valid) return true;
        const cb = self.cb.on_get_ascii_table orelse return false;

        const log_active = self.log.cb != null;
        const t0: i128 = if (log_active) std.time.nanoTimestamp() else 0;

        const style_combos = [4]u32{ 0, c_api.STYLE_BOLD, c_api.STYLE_ITALIC, c_api.STYLE_BOLD | c_api.STYLE_ITALIC };
        var all_ok = true;
        for (0..4) |i| {
            const ok = cb(
                self.ctx,
                style_combos[i],
                &self.ascii_glyph_ids[i],
                &self.ascii_x_advances[i],
                &self.ascii_lig_triggers[i],
            );
            if (ok == 0) all_ok = false;
        }

        const t1: i128 = if (log_active) std.time.nanoTimestamp() else 0;

        self.ascii_tables_valid = all_ok;
        if (all_ok) {
            self.preRasterizeAscii();
        }

        if (log_active) {
            const t2 = std.time.nanoTimestamp();
            const table_us: i64 = @intCast(@divTrunc(@max(0, t1 - t0), 1000));
            const preraster_us: i64 = @intCast(@divTrunc(@max(0, t2 - t1), 1000));
            self.log.write("[perf] loadAsciiTables table_fetch_us={d} preraster_us={d} ok={}\n", .{ table_us, preraster_us, all_ok });
        }

        return all_ok;
    }

    /// Set shape cache size (triggers reinit on next flush).
    pub fn setShapeCacheSize(self: *Core, size: u32) void {
        self.shape_cache_size = @max(512, @min(65536, size));
        // Free existing cache; will be reallocated in initGlyphCache on next flush
        if (self.shape_cache) |buf| {
            self.alloc.free(buf);
            self.shape_cache = null;
        }
        if (self.glyph_cache_initialized) {
            self.deinitGlyphCache();
        }
    }

    // --- Highlight cache (heap-allocated, used by flush vertex generation) ---

    /// Initialize highlight cache buffers based on hl_cache_size.
    /// Called lazily on first flush.
    pub fn initHlCache(self: *Core) !void {
        if (self.hl_cache_initialized) return;
        const size = self.hl_cache_size;
        const hl_buf = try self.alloc.alloc(highlight.ResolvedAttrWithStyles, size);
        errdefer self.alloc.free(hl_buf);
        const valid_buf = try self.alloc.alloc(bool, size);
        @memset(valid_buf, false);
        self.hl_cache_buf = hl_buf;
        self.hl_valid_buf = valid_buf;
        self.hl_cache_initialized = true;
    }

    /// Free highlight cache buffers.
    fn deinitHlCache(self: *Core) void {
        if (self.hl_cache_buf) |buf| self.alloc.free(buf);
        if (self.hl_valid_buf) |buf| self.alloc.free(buf);
        self.hl_cache_buf = null;
        self.hl_valid_buf = null;
        self.hl_cache_initialized = false;
    }

    /// Reinitialize highlight cache with new size (called when config changes).
    pub fn reinitHlCache(self: *Core) void {
        self.deinitHlCache();
        // Will be lazily re-allocated on next flush
    }

    // --- Phase 2: Core-managed atlas ---

    /// Returns true if all three Phase 2 callbacks are registered.
    /// When true, the core drives atlas packing/UV instead of the frontend.
    pub fn isPhase2Atlas(self: *const Core) bool {
        return self.cb.on_rasterize_glyph != null and
            self.cb.on_atlas_upload != null and
            self.cb.on_atlas_create != null;
    }

    /// Common helper: pack a rasterized bitmap into the atlas, upload, and build a GlyphEntry.
    /// Handles whitespace, oversized glyphs, atlas-full reset, UV computation.
    /// Returns null only if the glyph cannot fit even after atlas reset.
    fn packAndUploadBitmap(self: *Core, bm: *const c_api.GlyphBitmap) ?c_api.GlyphEntry {
        // Whitespace / zero-size glyph → return entry with zero UVs
        if (bm.width == 0 or bm.height == 0) {
            const adv: f32 = @as(f32, @floatFromInt(bm.advance_26_6)) / 64.0;
            return c_api.GlyphEntry{
                .uv_min = .{ 0, 0 },
                .uv_max = .{ 0, 0 },
                .bbox_origin_px = .{ 0, 0 },
                .bbox_size_px = .{ 0, 0 },
                .advance_px = adv,
                .ascent_px = bm.ascent_px,
                .descent_px = bm.descent_px,
                .bytes_per_pixel = bm.bytes_per_pixel,
            };
        }

        // Reject glyphs larger than the atlas (can never fit)
        const pad2 = self.atlas_packer.?.padding * 2;
        if (bm.width + pad2 > self.atlas_w or bm.height + pad2 > self.atlas_h) {
            return null;
        }

        const log_on = self.log.cb != null;

        // Try to pack
        var packer = &(self.atlas_packer.?);
        const t_pack: i128 = if (log_on) std.time.nanoTimestamp() else 0;
        var rect = packer.alloc(bm.width, bm.height);

        // Atlas full → reset and retry once.
        if (rect == null) {
            self.atlas_reset_during_flush = true;
            self.resetCoreAtlas();
            packer = &(self.atlas_packer.?);
            rect = packer.alloc(bm.width, bm.height);
            if (rect == null) return null;
        }
        if (log_on) {
            const dt: u64 = @intCast(@max(0, std.time.nanoTimestamp() - t_pack));
            self.perf_pack_ns_total +%= dt;
        }

        const r = rect.?;

        // Upload glyph bitmap
        if (self.cb.on_atlas_upload) |f| {
            const t_up: i128 = if (log_on) std.time.nanoTimestamp() else 0;
            f(self.ctx, r.x + packer.padding, r.y + packer.padding, bm.width, bm.height, bm);
            if (log_on) {
                const dt: u64 = @intCast(@max(0, std.time.nanoTimestamp() - t_up));
                self.perf_upload_ns_total +%= dt;
                self.perf_upload_calls +%= 1;
            }
        }

        // Compute UVs (excluding padding)
        const uvs = packer.computeUV(r.x, r.y, bm.width, bm.height);

        // Build GlyphEntry
        const adv: f32 = @as(f32, @floatFromInt(bm.advance_26_6)) / 64.0;
        const bearing_x_f: f32 = @floatFromInt(bm.bearing_x);
        const bearing_y_f: f32 = @floatFromInt(bm.bearing_y);
        const bm_h_f: f32 = @floatFromInt(bm.height);
        const bm_w_f: f32 = @floatFromInt(bm.width);

        return c_api.GlyphEntry{
            .uv_min = .{ uvs[0], uvs[1] },
            .uv_max = .{ uvs[2], uvs[3] },
            .bbox_origin_px = .{ bearing_x_f, bearing_y_f - bm_h_f },
            .bbox_size_px = .{ bm_w_f, bm_h_f },
            .advance_px = adv,
            .ascent_px = bm.ascent_px,
            .descent_px = bm.descent_px,
            .bytes_per_pixel = bm.bytes_per_pixel,
        };
    }

    /// Ensure atlas is lazily initialized.
    fn ensureAtlasInit(self: *Core) void {
        if (!self.atlas_initialized) {
            self.atlas_packer = shelf_packer.ShelfPacker.init(self.atlas_w, self.atlas_h);
            if (self.cb.on_atlas_create) |f| {
                const log_on = self.log.cb != null;
                const t: i128 = if (log_on) std.time.nanoTimestamp() else 0;
                f(self.ctx, self.atlas_w, self.atlas_h);
                if (log_on) {
                    const dt: u64 = @intCast(@max(0, std.time.nanoTimestamp() - t));
                    self.perf_atlas_create_ns_total +%= dt;
                    self.perf_atlas_create_calls +%= 1;
                }
            }
            self.atlas_initialized = true;
        }
    }

    /// Pre-rasterize printable ASCII (0x20-0x7E) for all style combos
    /// to eliminate cold-cache DWrite spikes on first flush.
    /// Called once after loadAsciiTables() succeeds (on font init).
    pub fn preRasterizeAscii(self: *Core) void {
        // Guard: required callbacks must be set (ensureGlyphByID unwraps .?)
        if (self.cb.on_rasterize_glyph_by_id == null) return;
        if (self.cb.on_atlas_upload == null) return;
        if (self.cb.on_atlas_create == null) return;

        self.initGlyphCache() catch return;
        const cache = self.glyph_cache_by_id orelse return;
        const keys = self.glyph_keys_by_id orelse return;
        const CACHE_SIZE = self.glyph_cache_non_ascii_size;
        if (CACHE_SIZE == 0) return;

        const INVALID_KEY: u64 = 0xFFFFFFFFFFFFFFFF;
        const style_combos = [4]u32{ 0, c_api.STYLE_BOLD, c_api.STYLE_ITALIC, c_api.STYLE_BOLD | c_api.STYLE_ITALIC };

        var rasterized: u32 = 0;
        var skipped: u32 = 0;

        for (0..4) |si| {
            const gids = &self.ascii_glyph_ids[si];
            const c_style = style_combos[si];

            for (0x20..0x7F) |scalar| {
                const gid = gids[scalar];
                if (gid == 0) continue; // .notdef

                const key = (@as(u64, gid) << 2) | @as(u64, si);
                const hash_val = (gid *% 2654435761) ^ @as(u32, @intCast(si));
                const hash_idx = @as(usize, hash_val % CACHE_SIZE);

                // Already cached → skip
                if (keys[hash_idx] != INVALID_KEY and keys[hash_idx] == key) {
                    skipped += 1;
                    continue;
                }

                // Rasterize + pack + upload
                if (self.ensureGlyphByID(gid, c_style)) |entry| {
                    cache[hash_idx] = entry;
                    keys[hash_idx] = key;
                    rasterized += 1;
                }
            }
        }

        self.log.write("[perf] preRasterizeAscii rasterized={d} skipped={d}\n", .{ rasterized, skipped });
    }

    /// Phase 2 glyph resolution: rasterize → pack → upload → build GlyphEntry.
    /// Returns null on unrecoverable failure (rasterize callback returned 0).
    pub fn ensureGlyphPhase2(self: *Core, scalar: u32, style_flags: u32) ?c_api.GlyphEntry {
        const log_on = self.log.cb != null;
        const t_total: i128 = if (log_on) std.time.nanoTimestamp() else 0;
        defer if (log_on) {
            const dt: u64 = @intCast(@max(0, std.time.nanoTimestamp() - t_total));
            self.perf_atlas_total_ns_total +%= dt;
            self.perf_atlas_total_calls +%= 1;
        };

        self.ensureAtlasInit();

        // Ask frontend to rasterize (no packing / UV)
        var bm: c_api.GlyphBitmap = std.mem.zeroes(c_api.GlyphBitmap);
        const t_r: i128 = if (log_on) std.time.nanoTimestamp() else 0;
        const ok = self.cb.on_rasterize_glyph.?(self.ctx, scalar, style_flags, &bm);
        if (log_on) {
            const dt: u64 = @intCast(@max(0, std.time.nanoTimestamp() - t_r));
            self.perf_rasterize_ns_total +%= dt;
            self.perf_rasterize_calls +%= 1;
        }
        if (ok == 0) return null;

        return self.packAndUploadBitmap(&bm);
    }

    /// Phase B: Resolve a shaped glyph by its glyph ID (post-shaping).
    /// Similar to ensureGlyphPhase2 but uses on_rasterize_glyph_by_id callback.
    pub fn ensureGlyphByID(self: *Core, glyph_id: u32, style_flags: u32) ?c_api.GlyphEntry {
        const log_on = self.log.cb != null;
        const t_total: i128 = if (log_on) std.time.nanoTimestamp() else 0;
        defer if (log_on) {
            const dt: u64 = @intCast(@max(0, std.time.nanoTimestamp() - t_total));
            self.perf_atlas_total_ns_total +%= dt;
            self.perf_atlas_total_calls +%= 1;
        };

        self.ensureAtlasInit();

        var bm: c_api.GlyphBitmap = std.mem.zeroes(c_api.GlyphBitmap);
        const t_r: i128 = if (log_on) std.time.nanoTimestamp() else 0;
        const ok = self.cb.on_rasterize_glyph_by_id.?(self.ctx, glyph_id, style_flags, &bm);
        if (log_on) {
            const dt: u64 = @intCast(@max(0, std.time.nanoTimestamp() - t_r));
            self.perf_rasterize_ns_total +%= dt;
            self.perf_rasterize_calls +%= 1;
        }
        if (ok == 0) return null;

        return self.packAndUploadBitmap(&bm);
    }

    /// Reset core atlas: clear packer, invalidate cache, recreate texture.
    pub fn resetCoreAtlas(self: *Core) void {
        if (self.atlas_packer) |*p| {
            p.reset();
        } else {
            // Packer not yet created (e.g. onGuifont before first glyph render).
            // Create it now so atlas_initialized=true is safe.
            self.atlas_packer = shelf_packer.ShelfPacker.init(self.atlas_w, self.atlas_h);
        }
        self.resetGlyphCacheFlags();
        self.atlas_initialized = true;
        if (self.cb.on_atlas_create) |f| {
            const log_on = self.log.cb != null;
            const t: i128 = if (log_on) std.time.nanoTimestamp() else 0;
            f(self.ctx, self.atlas_w, self.atlas_h);
            if (log_on) {
                const dt: u64 = @intCast(@max(0, std.time.nanoTimestamp() - t));
                self.perf_atlas_create_ns_total +%= dt;
                self.perf_atlas_create_calls +%= 1;
            }
        }
    }

    /// Set glyph cache sizes (must be called before start or during stop)
    pub fn setGlyphCacheSize(self: *Core, ascii_size: u32, non_ascii_size: u32) void {
        // Ensure minimum sizes
        self.glyph_cache_ascii_size = @max(128, ascii_size);
        self.glyph_cache_non_ascii_size = @max(64, non_ascii_size);

        // If already initialized, need to reinitialize
        if (self.glyph_cache_initialized) {
            self.deinitGlyphCache();
            // Will be reinitialized on next flush
        }
    }

    pub fn sendInput(self: *Core, keys: []const u8) void {
        self.log.write("[input] sendInput: \"{s}\"\n", .{keys});
        // Escape '<' as '<lt>' for Neovim input notation
        var needs_escape = false;
        for (keys) |c| {
            if (c == '<') {
                needs_escape = true;
                break;
            }
        }

        if (needs_escape) {
            self.key_buf.clearRetainingCapacity();
            for (keys) |c| {
                if (c == '<') {
                    self.key_buf.appendSlice(self.alloc, "<lt>") catch return;
                } else {
                    self.key_buf.append(self.alloc, c) catch return;
                }
            }
            self.requestInput(self.key_buf.items) catch |e| {
                self.log.write("sendInput err: {any}\n", .{e});
            };
        } else {
            self.requestInput(keys) catch |e| {
                self.log.write("sendInput err: {any}\n", .{e});
            };
        }
    }

    pub fn noteInputTrace(self: *Core, seq: u64, sent_ns: i64) void {
        self.grid_mu.lock();
        defer self.grid_mu.unlock();
        self.grid.noteInputTrace(seq, sent_ns);
        if (self.log.cb != null) {
            self.log.write("[perf_input] seq={d} stage=input_send sent_ns={d}\n", .{ seq, sent_ns });
        }
    }

    /// Send raw data to child process stdin (for SSH password input).
    /// Signals ssh_auth_done after writing.
    pub fn sendStdinData(self: *Core, data: []const u8) void {
        if (self.stdin_file) |f| {
            f.writeAll(data) catch |e| {
                self.log.write("sendStdinData write err: {any}\n", .{e});
                return;
            };
            self.log.write("sendStdinData: wrote {d} bytes\n", .{data.len});
            // Signal that auth data was sent
            self.ssh_auth_done.store(true, .seq_cst);
        } else {
            self.log.write("sendStdinData: stdin_file is null\n", .{});
        }
    }

    /// Send mouse scroll event to Neovim (nvim_input_mouse).
    /// direction: "up" or "down"
    /// modifier: "" or combination of "S" (shift), "C" (ctrl), "A" (alt)
    /// For MESSAGE_GRID_ID (Zonvie's own grid), scroll is handled locally instead of sending to Neovim.
    pub fn sendMouseScroll(self: *Core, grid_id: i64, row: i32, col: i32, direction: []const u8, modifier: []const u8) void {
        // Handle scroll for Zonvie's own message grid locally
        if (grid_id == grid_mod.MESSAGE_GRID_ID) {
            self.handleMsgGridScroll(direction);
            return;
        }
        // Resolve grid_id -1 to cursor_grid so Neovim receives a valid grid ID
        const effective_id = if (grid_id == -1) self.grid.cursor_grid else grid_id;
        self.requestMouseScroll(effective_id, row, col, direction, modifier) catch |e| {
            self.log.write("sendMouseScroll err: {any}\n", .{e});
        };
    }

    /// Send mouse input event to Neovim (nvim_input_mouse).
    /// button: "left", "right", "middle", "x1", "x2"
    /// action: "press", "drag", "release"
    /// modifier: "" or combination of "S" (shift), "C" (ctrl), "A" (alt)
    pub fn sendMouseInput(
        self: *Core,
        button: []const u8,
        action: []const u8,
        modifier: []const u8,
        grid_id: i64,
        row: i32,
        col: i32,
    ) void {
        self.requestMouseInput(button, action, modifier, grid_id, row, col) catch |e| {
            self.log.write("sendMouseInput err: {any}\n", .{e});
        };
    }

    /// Scroll view to specified line number (1-based).
    /// If use_bottom is true, positions the line at the bottom of the screen (zb).
    /// Otherwise, positions at the top (zt).
    pub fn scrollToLine(self: *Core, line: i64, use_bottom: bool) void {
        self.requestScrollToLine(line, use_bottom) catch |e| {
            self.log.write("scrollToLine err: {any}\n", .{e});
        };
    }

    /// Scroll a window by one page using Neovim's native <C-f>/<C-b>.
    /// grid_id: target grid (-1 for cursor grid / current window).
    /// forward: true = page down, false = page up.
    pub fn pageScroll(self: *Core, grid_id: i64, forward: bool) void {
        self.requestPageScroll(grid_id, forward) catch |e| {
            self.log.write("pageScroll err: {any}\n", .{e});
        };
    }

    /// Get list of visible grids for hit-testing.
    /// Returns number of grids written (up to out.len).
    pub fn getVisibleGrids(self: *Core, out: []c_api.GridInfo) usize {
        self.grid_mu.lock();
        defer self.grid_mu.unlock();
        return self.getVisibleGridsLocked(out);
    }

    /// Non-blocking version of getVisibleGrids.
    /// Returns null if grid_mu could not be acquired (another thread holds it).
    pub fn tryGetVisibleGrids(self: *Core, out: []c_api.GridInfo) ?usize {
        if (!self.grid_mu.tryLock()) return null;
        defer self.grid_mu.unlock();
        return self.getVisibleGridsLocked(out);
    }

    /// Internal: get visible grids assuming grid_mu is already held.
    fn getVisibleGridsLocked(self: *Core, out: []c_api.GridInfo) usize {
        var count: usize = 0;

        // Always include global grid first
        if (count < out.len) {
            const m1 = self.grid.getViewportMargins(1);
            out[count] = .{
                .grid_id = 1,
                .zindex = 0, // global grid has lowest zindex
                .start_row = 0,
                .start_col = 0,
                .rows = @intCast(self.grid.rows),
                .cols = @intCast(self.grid.cols),
                .margin_top = @intCast(m1.top),
                .margin_bottom = @intCast(m1.bottom),
                .margin_left = @intCast(m1.left),
                .margin_right = @intCast(m1.right),
                .line_count = if (self.grid.getViewport(1)) |vp| vp.line_count else 0,
                .anchor_grid = 1,
                .follows_scroll = 0,
                .is_external = 0,
            };
            count += 1;
        }

        // Add sub-grids (floating windows)
        var it = self.grid.win_pos.iterator();
        while (it.next()) |entry| {
            if (count >= out.len) break;

            const gid = entry.key_ptr.*;
            if (gid == 1) continue; // skip global grid (already added)

            const pos = entry.value_ptr.*;
            const sg = self.grid.sub_grids.get(gid) orelse continue;
            const layer = self.grid.win_layer.get(gid) orelse @import("grid.zig").WinLayer{
                .zindex = 0,
                .compindex = 0,
                .order = 0,
            };
            const margins = self.grid.getViewportMargins(gid);

            out[count] = .{
                .grid_id = gid,
                .zindex = layer.zindex,
                .start_row = @intCast(pos.row),
                .start_col = @intCast(pos.col),
                .rows = @intCast(sg.rows),
                .cols = @intCast(sg.cols),
                .margin_top = @intCast(margins.top),
                .margin_bottom = @intCast(margins.bottom),
                .margin_left = @intCast(margins.left),
                .margin_right = @intCast(margins.right),
                .line_count = if (self.grid.getViewport(gid)) |vp| vp.line_count else 0,
                .anchor_grid = pos.anchor_grid,
                .follows_scroll = if (pos.follows_scroll) 1 else 0,
                .is_external = 0,
            };
            count += 1;
        }

        // Add external grids (separate top-level windows)
        var ext_it = self.grid.external_grids.keyIterator();
        while (ext_it.next()) |key_ptr| {
            if (count >= out.len) break;

            const gid = key_ptr.*;
            const sg = self.grid.sub_grids.get(gid) orelse continue;
            const margins = self.grid.getViewportMargins(gid);

            out[count] = .{
                .grid_id = gid,
                .zindex = 0, // External grids have their own window, zindex doesn't apply
                .start_row = 0, // External grids start at (0,0) in their own window
                .start_col = 0,
                .rows = @intCast(sg.rows),
                .cols = @intCast(sg.cols),
                .margin_top = @intCast(margins.top),
                .margin_bottom = @intCast(margins.bottom),
                .margin_left = @intCast(margins.left),
                .margin_right = @intCast(margins.right),
                .line_count = if (self.grid.getViewport(gid)) |vp| vp.line_count else 0,
                .anchor_grid = 1,
                .follows_scroll = 0,
                .is_external = 1,
            };
            count += 1;
        }

        return count;
    }

    pub const CursorPosition = struct {
        grid_id: i64,
        row: i32,
        col: i32,
    };

    pub fn getCursorPosition(self: *Core) CursorPosition {
        // Lock grid_mu to prevent concurrent modification from RPC thread.
        self.grid_mu.lock();
        defer self.grid_mu.unlock();

        return .{
            .grid_id = self.grid.cursor_grid,
            .row = @intCast(self.grid.cursor_row),
            .col = @intCast(self.grid.cursor_col),
        };
    }

    /// Get viewport info for a specific grid (for scrollbar rendering).
    /// Returns 1 if found, 0 if not found.
    pub fn getViewportInfo(self: *Core, grid_id: i64, out: *c_api.ViewportInfo) i32 {
        self.grid_mu.lock();
        defer self.grid_mu.unlock();
        return self.getViewportInfoLocked(grid_id, out);
    }

    /// Non-blocking version of getViewportInfo.
    /// Returns null if grid_mu could not be acquired (another thread holds it).
    pub fn tryGetViewportInfo(self: *Core, grid_id: i64, out: *c_api.ViewportInfo) ?i32 {
        if (!self.grid_mu.tryLock()) return null;
        defer self.grid_mu.unlock();
        return self.getViewportInfoLocked(grid_id, out);
    }

    /// Internal: get viewport info assuming grid_mu is already held.
    fn getViewportInfoLocked(self: *Core, grid_id: i64, out: *c_api.ViewportInfo) i32 {
        const vp = self.grid.getViewport(grid_id) orelse {
            // self.log.write("[getViewportInfo] grid_id={d} not found\n", .{grid_id});
            return 0;
        };

        out.* = .{
            .grid_id = grid_id,
            .topline = vp.topline,
            .botline = vp.botline,
            .line_count = vp.line_count,
            .curline = vp.curline,
            .curcol = vp.curcol,
            .scroll_delta = vp.scroll_delta,
        };
        // self.log.write("[getViewportInfo] grid_id={d} topline={d} line_count={d}\n", .{ grid_id, vp.topline, vp.line_count });
        return 1;
    }

    pub const HlColors = struct {
        fg: u32,
        bg: u32,
        found: bool,
    };

    /// Get highlight colors by group name (e.g., "Search", "Normal").
    pub fn getHlByName(self: *Core, name: []const u8) HlColors {
        self.grid_mu.lock();
        defer self.grid_mu.unlock();

        // Look up hl_id from group name
        const hl_id = self.hl.groups.get(name) orelse {
            // Not found - return default colors
            return .{
                .fg = self.hl.default_fg,
                .bg = self.hl.default_bg,
                .found = false,
            };
        };

        // Get colors for this hl_id
        const attr = self.hl.get(hl_id);
        return .{
            .fg = attr.fg,
            .bg = attr.bg,
            .found = true,
        };
    }

    pub fn resize(self: *Core, rows: u32, cols: u32) void {
        self.requestTryResize(rows, cols) catch |e| {
            self.pending_resize_rows = rows;
            self.pending_resize_cols = cols;
            self.pending_resize_valid = true;
            self.log.write(
                "resize err: {any} -> pending_resize rows={d} cols={d}\n",
                .{ e, rows, cols },
            );
            return;
        };

        if (self.pending_resize_valid and self.pending_resize_rows == rows and self.pending_resize_cols == cols) {
            self.pending_resize_valid = false;
        }
    }

    pub fn updateLayoutPx(
        self: *Core,
        drawable_w_px: u32,
        drawable_h_px: u32,
        cell_w_px: u32,
        cell_h_px: u32,
    ) void {
        // If called from within handleRedraw (via callback) on the SAME thread,
        // grid_mu is already held, so we can call the locked version directly.
        // This ensures cell dimensions are updated BEFORE the flush generates vertices.
        // We compare thread IDs to avoid the UI thread incorrectly skipping the lock
        // when the RPC thread is in handleRedraw (which would cause a data race).
        const current_tid: usize = @intCast(std.Thread.getCurrentId());
        const redraw_tid = self.redraw_thread_id.load(.seq_cst);
        if (redraw_tid != 0 and redraw_tid == current_tid) {
            self.updateLayoutPxLocked(drawable_w_px, drawable_h_px, cell_w_px, cell_h_px);
            return;
        }

        // Called from UI thread - acquire grid_mu to protect grid state access.
        self.grid_mu.lock();
        defer self.grid_mu.unlock();

        self.updateLayoutPxLocked(drawable_w_px, drawable_h_px, cell_w_px, cell_h_px);
    }

    // Internal implementation: assumes grid_mu is already held or we're in a safe context.
    // Exposed via zonvie_core_update_layout_px_locked C ABI for frontends that
    // hold grid_mu themselves (see zonvie_core_lock_grid).
    pub fn updateLayoutPxLocked(
        self: *Core,
        drawable_w_px: u32,
        drawable_h_px: u32,
        cell_w_px: u32,
        cell_h_px: u32,
    ) void {
        // All inputs are already integer pixels (UI measured & rounded).
        // Keep core logic deterministic across macOS/Windows.
        const cw = if (cell_w_px == 0) 1 else cell_w_px;
        const ch = if (cell_h_px == 0) 1 else cell_h_px;
        const dw = if (drawable_w_px == 0) 1 else drawable_w_px;
        const dh = if (drawable_h_px == 0) 1 else drawable_h_px;

        // Track whether cell dimensions changed (affects vertex positions).
        const cell_dims_changed = (cw != self.cell_w_px or ch != self.cell_h_px);

        const cols = @max(@as(u32, 1), dw / cw);
        const rows = @max(@as(u32, 1), dh / ch);

        self.drawable_w_px = dw;
        self.drawable_h_px = dh;
        self.cell_w_px = cw;
        self.cell_h_px = ch;

        // Keep global grid (id=1) cell metrics for future per-grid font metrics.
        self.grid.setGridMetricsPx(1, cw, ch) catch {};

        // Update screen_cols for cmdline max width (cols derived from drawable width).
        // This is done here to avoid a separate lock acquisition in setScreenCols.
        self.grid.screen_cols = cols;

        // If cell dimensions changed, mark grid dirty to force vertex regeneration.
        // This handles linespace changes where rows/cols may not change but
        // vertex positions need recalculation.
        if (cell_dims_changed) {
            self.grid.markAllDirty();
            // Also mark all external grids dirty so they get regenerated with new cell size
            var sg_it = self.grid.sub_grids.valueIterator();
            while (sg_it.next()) |sg| {
                sg.dirty = true;
            }
            // Immediately send external grid vertices with new cell size
            // (don't wait for next flush from Neovim)
            self.sendExternalGridVertices(true);
        }

        if (rows == self.last_layout_rows and cols == self.last_layout_cols) return;
        self.last_layout_rows = rows;
        self.last_layout_cols = cols;
        // Use existing resize path (already catches/logs errors).
        self.resize(rows, cols);
    }

    /// Set screen width in cells (for cmdline max width).
    /// Uses the same thread-ID check as updateLayoutPx to avoid deadlock
    /// when called from within redraw callbacks (where grid_mu is already held).
    pub fn setScreenCols(self: *Core, cols: u32) void {
        const current_tid: usize = @intCast(std.Thread.getCurrentId());
        const redraw_tid = self.redraw_thread_id.load(.seq_cst);
        if (redraw_tid != 0 and redraw_tid == current_tid) {
            // Already holding grid_mu on this thread (inside handleRedraw).
            self.grid.screen_cols = cols;
            return;
        }
        self.grid_mu.lock();
        defer self.grid_mu.unlock();
        self.grid.screen_cols = cols;
    }

    // ---- Key event encoding (OS trap -> Zig common encode) ----
    fn emitInputString(self: *Core, s: []const u8) void {
        if (s.len == 0) return;
        self.log.write("[input] nvim_input: \"{s}\"\n", .{s});
        self.requestInput(s) catch |e| self.log.write("emitInputString err: {any}\n", .{e});
    }

    fn isAsciiControl(cp: u32) bool {
        return cp < 0x20 or cp == 0x7F;
    }

    fn firstCodepointUtf8(s: []const u8) ?u32 {
        if (s.len == 0) return null;
        var it = std.unicode.Utf8Iterator{ .bytes = s, .i = 0 };
        if (it.nextCodepoint()) |cp| return @as(u32, cp);
        return null;
    }

    fn appendModPrefix(buf: *std.ArrayListUnmanaged(u8), alloc: std.mem.Allocator, mods: u32) !void {
        // mods bitmask:
        // 1<<0 Ctrl, 1<<1 Alt/Meta, 1<<2 Shift, 1<<3 Super(Command)
        var first = true;

        const add = struct {
            fn f(b: *std.ArrayListUnmanaged(u8), a: std.mem.Allocator, s: []const u8, first2: *bool) !void {
                if (!first2.*) try b.append(a, '-');
                try b.appendSlice(a, s);
                first2.* = false;
            }
        }.f;

        if ((mods & (1 << 0)) != 0) try add(buf, alloc, "C", &first);
        if ((mods & (1 << 1)) != 0) try add(buf, alloc, "M", &first);
        if ((mods & (1 << 2)) != 0) try add(buf, alloc, "S", &first);
        if ((mods & (1 << 3)) != 0) try add(buf, alloc, "D", &first);

        if (!first) try buf.append(alloc, '-');
    }

    pub fn isWinVkKeycode(keycode: u32) bool {
        return (keycode & 0x10000) != 0;
    }
    pub fn winVk(keycode: u32) u32 {
        return keycode & 0xFFFF;
    }

    pub fn winSpecialName(vk: u32) ?[]const u8 {
        // Win32 Virtual-Key mapping -> Neovim special key names.
        return switch (vk) {
            0x25 => "Left",    // VK_LEFT
            0x26 => "Up",      // VK_UP
            0x27 => "Right",   // VK_RIGHT
            0x28 => "Down",    // VK_DOWN
            0x24 => "Home",    // VK_HOME
            0x23 => "End",     // VK_END
            0x21 => "PageUp",  // VK_PRIOR
            0x22 => "PageDown",// VK_NEXT
            0x08 => "BS",      // VK_BACK
            0x2E => "Del",     // VK_DELETE
            0x0D => "CR",      // VK_RETURN
            0x09 => "Tab",     // VK_TAB
            0x1B => "Esc",     // VK_ESCAPE
            else => null,
        };
    }

    pub fn macSpecialName(keycode: u32) ?[]const u8 {
        // Keep OS-specific keycode mapping here (macOS trap data -> common names).
        return switch (keycode) {
            123 => "Left",
            124 => "Right",
            125 => "Down",
            126 => "Up",
            115 => "Home",
            119 => "End",
            116 => "PageUp",
            121 => "PageDown",
            51 => "BS",
            117 => "Del",
            36 => "CR",
            48 => "Tab",
            53 => "Esc",
            else => null,
        };
    }

    // Pure function for key event formatting (testable, no side effects).
    // Returns a slice of out_buf containing the formatted key string, or null if no output.
    pub fn formatKeyEvent(out_buf: []u8, keycode: u32, mods: u32, chars: []const u8, ign: []const u8) ?[]const u8 {
        var pos: usize = 0;

        // Helper to append a byte
        const appendByte = struct {
            fn f(buf: []u8, p: *usize, byte: u8) bool {
                if (p.* >= buf.len) return false;
                buf[p.*] = byte;
                p.* += 1;
                return true;
            }
        }.f;

        // Helper to append a slice
        const appendSlice = struct {
            fn f(buf: []u8, p: *usize, s: []const u8) bool {
                if (p.* + s.len > buf.len) return false;
                @memcpy(buf[p.*..][0..s.len], s);
                p.* += s.len;
                return true;
            }
        }.f;

        // Helper to append modifier prefix (C-M-S-D-)
        const writeMods = struct {
            fn f(buf: []u8, p: *usize, m: u32) bool {
                var first = true;
                if ((m & (1 << 0)) != 0) { // Ctrl
                    if (!first) {
                        if (p.* >= buf.len) return false;
                        buf[p.*] = '-';
                        p.* += 1;
                    }
                    if (p.* >= buf.len) return false;
                    buf[p.*] = 'C';
                    p.* += 1;
                    first = false;
                }
                if ((m & (1 << 1)) != 0) { // Alt/Meta
                    if (!first) {
                        if (p.* >= buf.len) return false;
                        buf[p.*] = '-';
                        p.* += 1;
                    }
                    if (p.* >= buf.len) return false;
                    buf[p.*] = 'M';
                    p.* += 1;
                    first = false;
                }
                if ((m & (1 << 2)) != 0) { // Shift
                    if (!first) {
                        if (p.* >= buf.len) return false;
                        buf[p.*] = '-';
                        p.* += 1;
                    }
                    if (p.* >= buf.len) return false;
                    buf[p.*] = 'S';
                    p.* += 1;
                    first = false;
                }
                if ((m & (1 << 3)) != 0) { // Super/Command
                    if (!first) {
                        if (p.* >= buf.len) return false;
                        buf[p.*] = '-';
                        p.* += 1;
                    }
                    if (p.* >= buf.len) return false;
                    buf[p.*] = 'D';
                    p.* += 1;
                    first = false;
                }
                if (!first) {
                    if (p.* >= buf.len) return false;
                    buf[p.*] = '-';
                    p.* += 1;
                }
                return true;
            }
        }.f;

        // 1) Special keys by keycode (macOS / Win32)
        if (isWinVkKeycode(keycode)) {
            if (winSpecialName(winVk(keycode))) |name| {
                if (!appendByte(out_buf, &pos, '<')) return null;
                if (!writeMods(out_buf, &pos, mods)) return null;
                if (!appendSlice(out_buf, &pos, name)) return null;
                if (!appendByte(out_buf, &pos, '>')) return null;
                return out_buf[0..pos];
            }
        } else if (macSpecialName(keycode)) |name| {
            if (!appendByte(out_buf, &pos, '<')) return null;
            if (!writeMods(out_buf, &pos, mods)) return null;
            if (!appendSlice(out_buf, &pos, name)) return null;
            if (!appendByte(out_buf, &pos, '>')) return null;
            return out_buf[0..pos];
        }

        // 2) For modified keys (Ctrl/Alt/Super), use charsIgnoringModifiers when it is a single codepoint.
        const has_mod = (mods & ((1 << 0) | (1 << 1) | (1 << 3))) != 0;
        if (has_mod) {
            const base_cp = firstCodepointUtf8(ign) orelse firstCodepointUtf8(chars) orelse return null;

            if (!appendByte(out_buf, &pos, '<')) return null;
            if (!writeMods(out_buf, &pos, mods)) return null;

            // Lowercase for ASCII letters to match Neovim notation (<C-x>)
            if (base_cp <= 0x7F) {
                var ch: u8 = @intCast(base_cp);
                if (ch >= 'A' and ch <= 'Z') ch = ch - 'A' + 'a';
                if (!appendByte(out_buf, &pos, ch)) return null;
            } else {
                var tmp: [4]u8 = undefined;
                const n = std.unicode.utf8Encode(@intCast(base_cp), &tmp) catch return null;
                if (!appendSlice(out_buf, &pos, tmp[0..n])) return null;
            }

            if (!appendByte(out_buf, &pos, '>')) return null;
            return out_buf[0..pos];
        }

        // 3) No mods: pass through raw characters (text input)
        if (chars.len == 0) return null;

        // Check if we need to escape '<' as '<lt>'
        var needs_escape = false;
        for (chars) |c| {
            if (c == '<') {
                needs_escape = true;
                break;
            }
        }

        if (needs_escape) {
            for (chars) |c| {
                if (c == '<') {
                    if (!appendSlice(out_buf, &pos, "<lt>")) return null;
                } else {
                    if (!appendByte(out_buf, &pos, c)) return null;
                }
            }
            return out_buf[0..pos];
        } else {
            // No escaping needed, just copy
            if (!appendSlice(out_buf, &pos, chars)) return null;
            return out_buf[0..pos];
        }
    }

    pub fn sendKeyEvent(self: *Core, keycode: u32, mods: u32, chars: []const u8, ign: []const u8) void {
        // Use persistent buffer (zero-allocation hot path)
        self.key_buf.clearRetainingCapacity();

        // 1) Special keys by keycode (macOS / Win32)
        if (isWinVkKeycode(keycode)) {
            if (winSpecialName(winVk(keycode))) |name| {
                self.key_buf.append(self.alloc, '<') catch return;
                appendModPrefix(&self.key_buf, self.alloc, mods) catch return;
                self.key_buf.appendSlice(self.alloc, name) catch return;
                self.key_buf.append(self.alloc, '>') catch return;

                self.emitInputString(self.key_buf.items);
                return;
            }
        } else if (macSpecialName(keycode)) |name| {
            self.key_buf.append(self.alloc, '<') catch return;
            appendModPrefix(&self.key_buf, self.alloc, mods) catch return;
            self.key_buf.appendSlice(self.alloc, name) catch return;
            self.key_buf.append(self.alloc, '>') catch return;

            self.emitInputString(self.key_buf.items);
            return;
        }

        // 2) For modified keys (Ctrl/Alt/Super), use charsIgnoringModifiers when it is a single codepoint.
        const has_mod = (mods & ((1 << 0) | (1 << 1) | (1 << 3))) != 0;
        if (has_mod) {
            const base_cp = firstCodepointUtf8(ign) orelse firstCodepointUtf8(chars) orelse return;

            // If it's a control ASCII produced as a result of Ctrl, prefer the angle-bracket form anyway.
            self.key_buf.clearRetainingCapacity();
            self.key_buf.append(self.alloc, '<') catch return;
            appendModPrefix(&self.key_buf, self.alloc, mods) catch return;

            // Lowercase for ASCII letters to match Neovim notation (<C-x>)
            if (base_cp <= 0x7F) {
                var ch: u8 = @intCast(base_cp);
                if (ch >= 'A' and ch <= 'Z') ch = ch - 'A' + 'a';
                self.key_buf.append(self.alloc, ch) catch return;
            } else {
                var tmp: [4]u8 = undefined;
                const n = std.unicode.utf8Encode(@intCast(base_cp), &tmp) catch return;
                self.key_buf.appendSlice(self.alloc, tmp[0..n]) catch return;
            }

            self.key_buf.append(self.alloc, '>') catch return;

            self.emitInputString(self.key_buf.items);
            return;
        }

        // 3) No mods: pass through raw characters (text input)
        // Neovim's nvim_input interprets <...> as special key notation (e.g., <CR>, <Esc>).
        // We must escape '<' as '<lt>' to send a literal '<' character.
        // Note: '\' and '|' can be escaped as <Bslash> and <Bar>, but are not required
        // for nvim_input - they're passed through as-is.
        if (chars.len == 0) return;

        // Check if we need to escape any characters
        var needs_escape = false;
        for (chars) |c| {
            if (c == '<') {
                needs_escape = true;
                break;
            }
        }

        if (needs_escape) {
            self.key_buf.clearRetainingCapacity();
            for (chars) |c| {
                if (c == '<') {
                    self.key_buf.appendSlice(self.alloc, "<lt>") catch return;
                } else {
                    self.key_buf.append(self.alloc, c) catch return;
                }
            }
            self.emitInputString(self.key_buf.items);
        } else {
            self.emitInputString(chars);
        }
    }

    // ---- guifont notify ----

    pub fn emitGuiFont(self: *Core, font: []const u8) void {
        if (self.cb.on_guifont) |f| {
            f(self.ctx, font.ptr, font.len);
        }
    }

    pub fn emitLineSpace(self: *Core, px: i32) void {
        if (self.cb.on_linespace) |f| {
            f(self.ctx, px);
        }
    }

    pub fn emitSetTitle(self: *Core, title: []const u8) void {
        self.log.write("[core] emitSetTitle: len={d} cb={any}\n", .{ title.len, self.cb.on_set_title != null });
        if (self.cb.on_set_title) |f| {
            f(self.ctx, title.ptr, title.len);
        }
    }

    pub fn emitDefaultColors(self: *Core, fg: u32, bg: u32) void {
        if (self.cb.on_default_colors_set) |f| {
            f(self.ctx, fg, bg);
        }
    }

    pub fn emitOnRestart(self: *Core, listen_addr: []const u8) void {
        if (self.cb.on_restart) |f| {
            f(self.ctx, listen_addr.ptr, listen_addr.len);
        }
    }

    pub fn emitOnConnect(self: *Core, server_addr: []const u8) void {
        if (self.cb.on_connect) |f| {
            f(self.ctx, server_addr.ptr, server_addr.len);
        }
    }

    /// Handle the `restart` UI event from Neovim. Records the new server's
    /// listen address and signals the current session to shut down. The RPC
    /// run loop observes restart_pending_addr and reconnects on the next
    /// session iteration instead of firing on_exit.
    ///
    /// Called from the redraw thread (grid_mu held).
    pub fn handleRestartEvent(self: *Core, listen_addr: []const u8) !void {
        // Drop any previously queued restart (only the latest matters).
        if (self.restart_pending_addr) |old| {
            self.alloc.free(old);
            self.restart_pending_addr = null;
        }

        const owned = self.alloc.dupe(u8, listen_addr) catch |e| {
            self.log.write("handleRestartEvent: dupe failed: {any}\n", .{e});
            return e;
        };
        self.restart_pending_addr = owned;
        // Explicit reset in case a prior :connect queued (then aborted) left
        // the hot-swap flag set; :restart is NOT a hot-swap (the old nvim
        // dies), so spawn fallback on connect failure is the desired recovery.
        self.restart_pending_is_connect_hotswap = false;

        self.log.write("handleRestartEvent: listen_addr={s}\n", .{listen_addr});

        // Notify frontend (informational; frontend MUST NOT close window).
        self.emitOnRestart(listen_addr);

        // The RPC run loop will observe restart_pending_addr after the
        // current session terminates (nvim closes the channel). We do NOT
        // proactively close stdin here because nvim is in the middle of
        // sending its final batch (the `restart` event itself is part of
        // that batch). Letting the read side EOF naturally is cleaner.
    }

    /// Handle the `connect` UI event from Neovim (`:connect <addr>`). The
    /// reconnect machinery is identical to `restart` — we record the new
    /// server's address in restart_pending_addr and let the run loop
    /// observe it after the channel closes — but the frontend gets a
    /// distinct `on_connect` callback so it can distinguish a hot-swap
    /// (`:connect`, old server stays alive headless) from a server
    /// replacement (`:restart`, old server dies).
    pub fn handleConnectEvent(self: *Core, server_addr: []const u8) !void {
        if (self.restart_pending_addr) |old| {
            self.alloc.free(old);
            self.restart_pending_addr = null;
        }

        const owned = self.alloc.dupe(u8, server_addr) catch |e| {
            self.log.write("handleConnectEvent: dupe failed: {any}\n", .{e});
            return e;
        };
        self.restart_pending_addr = owned;
        self.restart_pending_is_connect_hotswap = true;
        self.connect_keeps_child_alive = true;

        self.log.write("handleConnectEvent: server_addr={s}\n", .{server_addr});

        self.emitOnConnect(server_addr);
    }

    /// Dedicated writer thread: drains write_queue and writes to stdin pipe.
    /// Receives the stream by value to avoid racing with stop().
    fn writerThreadFn(self: *Core, file: Stream) void {
        var drain: std.ArrayListUnmanaged(u8) = .{};
        defer drain.deinit(self.alloc);

        while (true) {
            self.write_queue_mu.lock();

            // Wait for data or close signal
            while (self.write_queue.items.len == 0 and !self.write_queue_closed) {
                self.write_queue_cond.wait(&self.write_queue_mu);
            }

            if (self.write_queue.items.len == 0 and self.write_queue_closed) {
                self.write_queue_mu.unlock();
                self.log.write("writer thread: clean shutdown (queue drained)\n", .{});
                break;
            }

            // O(1) swap: take full queue, leave empty drain buffer for producers
            std.mem.swap(std.ArrayListUnmanaged(u8), &self.write_queue, &drain);
            self.write_queue_mu.unlock();

            // Write to pipe WITHOUT holding any mutex
            file.writeAll(drain.items) catch |e| {
                self.log.write("writer thread writeAll err: {any}\n", .{e});
                // Mark writer as failed + closed, notify any future waiters
                self.write_queue_mu.lock();
                self.writer_failed = true;
                self.write_queue_closed = true;
                self.write_queue_cond.broadcast();
                self.write_queue_mu.unlock();
                break;
            };

            drain.clearRetainingCapacity();
        }
    }

    /// Start the dedicated writer thread for non-blocking stdin writes.
    /// Safe to call from rpc_session.zig after stdin_file is set.
    pub fn startWriterThread(self: *Core) void {
        const file = self.stdin_file orelse {
            self.log.write("startWriterThread: stdin_file is null\n", .{});
            return;
        };

        self.write_queue_mu.lock();

        // Guard: don't start if shutdown is in progress or already running.
        // write_queue_closed is set by stop() under the same mutex, so this
        // check fully closes the race window between stop_flag and lock acquisition.
        if (self.write_queue_closed or self.writer_thread != null) {
            self.write_queue_mu.unlock();
            return;
        }

        // Reset state flags and drain stale data (safe for reconnect / re-use)
        self.writer_failed = false;
        self.write_queue.clearRetainingCapacity();

        self.writer_thread = std.Thread.spawn(.{}, writerThreadFn, .{ self, file }) catch |e| {
            self.write_queue_mu.unlock();
            self.log.write("FATAL: failed to spawn writer thread: {any}, using sync writes\n", .{e});
            return; // writer_thread remains null → sendRaw uses sync fallback
        };

        self.write_queue_mu.unlock();
    }

    pub fn sendRaw(self: *Core, bytes: []const u8) !void {
        // Don't attempt writes during shutdown (avoids sync fallback re-block)
        if (self.stop_flag.load(.seq_cst)) return error.BrokenPipe;

        // SSH mode: wait if authentication is pending (block RPC sends until password is entered)
        if (self.is_ssh_mode and self.ssh_auth_pending.load(.seq_cst)) {
            self.log.write("sendRaw: blocked during SSH auth, waiting...\n", .{});
            while (self.ssh_auth_pending.load(.seq_cst) and !self.stop_flag.load(.seq_cst)) {
                std.Thread.sleep(50 * std.time.ns_per_ms);
            }
            if (self.stop_flag.load(.seq_cst)) {
                return error.BrokenPipe;
            }
            self.log.write("sendRaw: SSH auth done, proceeding\n", .{});
        }

        // Check writer thread state under lock to avoid data race with stop()/startWriterThread()
        self.write_queue_mu.lock();

        if (self.writer_thread != null) {
            // Writer thread is active → enqueue (non-blocking path)
            if (self.writer_failed or self.write_queue_closed) {
                self.write_queue_mu.unlock();
                return error.BrokenPipe;
            }

            // Queue cap check (subtraction form to avoid usize overflow)
            if (bytes.len > MAX_WRITE_QUEUE_SIZE - self.write_queue.items.len) {
                self.log.write("sendRaw: write queue full ({d} bytes), dropping\n",
                    .{self.write_queue.items.len});
                self.write_queue_mu.unlock();
                return error.OutOfMemory;
            }

            self.write_queue.appendSlice(self.alloc, bytes) catch {
                self.write_queue_mu.unlock();
                return error.OutOfMemory;
            };
            self.write_queue_cond.signal();
            self.write_queue_mu.unlock();
            return;
        }

        self.write_queue_mu.unlock();

        // Fallback: no writer thread → synchronous write (startup / spawn failure)
        if (self.stdin_file) |f| {
            try f.writeAll(bytes);
        } else {
            return error.BrokenPipe;
        }
    }

    pub fn nextMsgId(self: *Core) i64 {
        return self.msgid.fetchAdd(1, .seq_cst);
    }

    pub fn sendRequestHeader(self: *Core, buf: *rpc.Buf, id: i64, method: []const u8) !void {
        try rpc.packArray(buf, self.alloc, 4);
        try rpc.packInt(buf, self.alloc, 0);
        try rpc.packInt(buf, self.alloc, id);
        try rpc.packStr(buf, self.alloc, method);
    }

    pub fn sendNotificationHeader(self: *Core, buf: *rpc.Buf, method: []const u8) !void {
        try rpc.packArray(buf, self.alloc, 3);
        try rpc.packInt(buf, self.alloc, 2); // msgtype=2 (notification)
        try rpc.packStr(buf, self.alloc, method);
    }

    pub fn requestGetApiInfo(self: *Core) !void {
        const id = self.nextMsgId();
        self.get_api_info_msgid = id;  // Save msgid for response matching
        var buf: rpc.Buf = .empty;
        defer buf.deinit(self.alloc);

        try self.sendRequestHeader(&buf, id, "nvim_get_api_info");
        try rpc.packArray(&buf, self.alloc, 0);
        try self.sendRaw(buf.items);

        self.log.write("rpc send: nvim_get_api_info (id={d})\n", .{id});
    }

    pub fn requestSetClientInfo(self: *Core) !void {
        const id = self.nextMsgId();
        var buf: rpc.Buf = .empty;
        defer buf.deinit(self.alloc);

        try self.sendRequestHeader(&buf, id, "nvim_set_client_info");

        try rpc.packArray(&buf, self.alloc, 5);
        try rpc.packStr(&buf, self.alloc, "zonvie");

        try rpc.packMap(&buf, self.alloc, 1);
        try rpc.packStr(&buf, self.alloc, "major");
        try rpc.packInt(&buf, self.alloc, 0);

        try rpc.packStr(&buf, self.alloc, "ui");
        try rpc.packMap(&buf, self.alloc, 0);
        try rpc.packMap(&buf, self.alloc, 0);

        try self.sendRaw(buf.items);

        self.log.write("rpc send: nvim_set_client_info (id={d})\n", .{id});
    }

    pub fn requestUiAttach(self: *Core, rows: u32, cols: u32) !void {
        var buf: rpc.Buf = .empty;
        defer buf.deinit(self.alloc);

        try self.sendNotificationHeader(&buf, "nvim_ui_attach");

        try rpc.packArray(&buf, self.alloc, 3);
        try rpc.packInt(&buf, self.alloc, @as(i64, @intCast(cols)));
        try rpc.packInt(&buf, self.alloc, @as(i64, @intCast(rows)));

        // Option count: ext_multigrid, rgb (always) + optional ext_*
        var opt_count: u32 = 2;
        if (self.ext_windows_enabled) opt_count += 1;
        if (self.ext_cmdline_enabled) opt_count += 1;
        if (self.ext_popupmenu_enabled) opt_count += 1;
        if (self.ext_messages_enabled) opt_count += 1;
        if (self.ext_tabline_enabled) opt_count += 1;
        try rpc.packMap(&buf, self.alloc, opt_count);
        try rpc.packStr(&buf, self.alloc, "ext_multigrid");
        try rpc.packBool(&buf, self.alloc, true);
        try rpc.packStr(&buf, self.alloc, "rgb");
        try rpc.packBool(&buf, self.alloc, true);

        if (self.ext_windows_enabled) {
            try rpc.packStr(&buf, self.alloc, "ext_windows");
            try rpc.packBool(&buf, self.alloc, true);
        }

        if (self.ext_cmdline_enabled) {
            try rpc.packStr(&buf, self.alloc, "ext_cmdline");
            try rpc.packBool(&buf, self.alloc, true);
        }

        if (self.ext_popupmenu_enabled) {
            try rpc.packStr(&buf, self.alloc, "ext_popupmenu");
            try rpc.packBool(&buf, self.alloc, true);
        }

        if (self.ext_messages_enabled) {
            try rpc.packStr(&buf, self.alloc, "ext_messages");
            try rpc.packBool(&buf, self.alloc, true);
        }

        if (self.ext_tabline_enabled) {
            try rpc.packStr(&buf, self.alloc, "ext_tabline");
            try rpc.packBool(&buf, self.alloc, true);
        }

        try self.sendRaw(buf.items);

        self.log.write("rpc send: nvim_ui_attach (notification, rows={d}, cols={d}, ext_cmdline={any}, ext_popupmenu={any}, ext_messages={any}, ext_tabline={any}, ext_windows={any})\n", .{ rows, cols, self.ext_cmdline_enabled, self.ext_popupmenu_enabled, self.ext_messages_enabled, self.ext_tabline_enabled, self.ext_windows_enabled });
    }

    /// Notify Neovim of window focus change via nvim_ui_set_focus.
    /// Triggers FocusGained/FocusLost autocommands in Neovim.
    /// If called before nvim_ui_attach, the focus state is deferred and
    /// sent automatically once the UI session is established.
    pub fn requestUiSetFocus(self: *Core, gained: bool) void {
        if (!self.ui_attached.load(.seq_cst)) {
            // UI not attached yet — store for later delivery.
            self.pending_focus.store(if (gained) 1 else 2, .seq_cst);
            self.log.write("requestUiSetFocus: deferred (gained={any})\n", .{gained});
            return;
        }
        self.requestUiSetFocusInternal(gained) catch |e| {
            self.log.write("requestUiSetFocus error: {any}\n", .{e});
        };
    }

    fn requestUiSetFocusInternal(self: *Core, gained: bool) !void {
        const id = self.nextMsgId();
        var buf: rpc.Buf = .empty;
        defer buf.deinit(self.alloc);

        try self.sendRequestHeader(&buf, id, "nvim_ui_set_focus");

        try rpc.packArray(&buf, self.alloc, 1);
        try rpc.packBool(&buf, self.alloc, gained);

        try self.sendRaw(buf.items);

        self.log.write("rpc send: nvim_ui_set_focus (id={d}, gained={any})\n", .{ id, gained });
    }

    /// Send any focus state that was deferred before nvim_ui_attach.
    pub fn flushPendingFocus(self: *Core) void {
        const pending = self.pending_focus.swap(0, .seq_cst);
        if (pending == 1) {
            self.requestUiSetFocusInternal(true) catch |e| {
                self.log.write("flushPendingFocus error: {any}\n", .{e});
            };
        } else if (pending == 2) {
            self.requestUiSetFocusInternal(false) catch |e| {
                self.log.write("flushPendingFocus error: {any}\n", .{e});
            };
        }
    }

    pub fn requestTryResize(self: *Core, rows: u32, cols: u32) !void {
        const id = self.nextMsgId();
        var buf: rpc.Buf = .empty;
        defer buf.deinit(self.alloc);

        try self.sendRequestHeader(&buf, id, "nvim_ui_try_resize");

        try rpc.packArray(&buf, self.alloc, 2);
        try rpc.packInt(&buf, self.alloc, @as(i64, @intCast(cols)));
        try rpc.packInt(&buf, self.alloc, @as(i64, @intCast(rows)));

        try self.sendRaw(buf.items);

        self.log.write("rpc send: nvim_ui_try_resize (id={d}, rows={d}, cols={d})\n", .{ id, rows, cols });
    }

    /// Request resize of a specific grid (for external windows).
    /// Request Neovim to resize an external grid.
    /// Does NOT update external_grid_target_sizes here — the authoritative
    /// update happens in grid_resize (redraw_handler.zig) when Neovim confirms
    /// the new size. Updating target_sizes eagerly would cause viewport_rows
    /// to temporarily mismatch the NDC baked into existing row vertices (e.g.
    /// frontend requests 44 rows but Neovim keeps 45 including winbar).
    pub fn requestTryResizeGrid(self: *Core, grid_id: i64, rows: u32, cols: u32) void {
        self.requestTryResizeGridInternal(grid_id, rows, cols) catch |e| {
            self.log.write("requestTryResizeGrid error: {any}\n", .{e});
        };
    }

    pub fn requestTryResizeGridInternal(self: *Core, grid_id: i64, rows: u32, cols: u32) !void {
        const id = self.nextMsgId();
        var buf: rpc.Buf = .empty;
        defer buf.deinit(self.alloc);

        try self.sendRequestHeader(&buf, id, "nvim_ui_try_resize_grid");

        try rpc.packArray(&buf, self.alloc, 3);
        try rpc.packInt(&buf, self.alloc, grid_id);
        try rpc.packInt(&buf, self.alloc, @as(i64, @intCast(cols)));
        try rpc.packInt(&buf, self.alloc, @as(i64, @intCast(rows)));

        try self.sendRaw(buf.items);

        self.log.write("rpc send: nvim_ui_try_resize_grid (id={d}, grid={d}, rows={d}, cols={d})\n", .{ id, grid_id, rows, cols });
    }

    /// Sync Neovim's internal window height to match the grid height.
    fn requestWinSetHeight(self: *Core, win_id: i64, height: u32) void {
        const id = self.nextMsgId();
        var buf: rpc.Buf = .empty;
        defer buf.deinit(self.alloc);

        self.sendRequestHeader(&buf, id, "nvim_win_set_height") catch return;
        rpc.packArray(&buf, self.alloc, 2) catch return;
        rpc.packInt(&buf, self.alloc, win_id) catch return;
        rpc.packInt(&buf, self.alloc, @as(i64, @intCast(height))) catch return;

        self.sendRaw(buf.items) catch return;
    }

    /// Sync Neovim's internal window width to match the grid width.
    fn requestWinSetWidth(self: *Core, win_id: i64, width: u32) void {
        const id = self.nextMsgId();
        var buf: rpc.Buf = .empty;
        defer buf.deinit(self.alloc);

        self.sendRequestHeader(&buf, id, "nvim_win_set_width") catch return;
        rpc.packArray(&buf, self.alloc, 2) catch return;
        rpc.packInt(&buf, self.alloc, win_id) catch return;
        rpc.packInt(&buf, self.alloc, @as(i64, @intCast(width))) catch return;

        self.sendRaw(buf.items) catch return;
    }

    pub fn requestInput(self: *Core, keys: []const u8) !void {
        const id = self.nextMsgId();
        var buf: rpc.Buf = .empty;
        defer buf.deinit(self.alloc);

        try self.sendRequestHeader(&buf, id, "nvim_input");

        try rpc.packArray(&buf, self.alloc, 1);
        try rpc.packStr(&buf, self.alloc, keys);

        try self.sendRaw(buf.items);
    }

    pub fn requestCommand(self: *Core, cmd: []const u8) !void {
        const id = self.nextMsgId();
        var buf: rpc.Buf = .empty;
        defer buf.deinit(self.alloc);

        try self.sendRequestHeader(&buf, id, "nvim_command");

        try rpc.packArray(&buf, self.alloc, 1);
        try rpc.packStr(&buf, self.alloc, cmd);

        try self.sendRaw(buf.items);

        self.log.write("rpc send: nvim_command (id={d}) {s}\n", .{ id, cmd });
    }

    /// Request graceful quit (called by frontend on window close button).
    /// Checks for unsaved buffers and calls on_quit_requested callback with result.
    pub fn requestQuit(self: *Core) void {
        // Ignore if already in progress (use cmpxchg to atomically check and set)
        const current = self.quit_request_msgid.load(.acquire);
        if (current != 0) {
            self.log.write("requestQuit: already in progress, ignoring\n", .{});
            return;
        }

        const id = self.nextMsgId();
        self.quit_request_msgid.store(id, .release);

        var buf: rpc.Buf = .empty;
        defer buf.deinit(self.alloc);

        self.sendRequestHeader(&buf, id, "nvim_exec_lua") catch |e| {
            self.log.write("requestQuit sendRequestHeader error: {any}\n", .{e});
            self.quit_request_msgid.store(0, .release);
            return;
        };

        // Lua code to check for unsaved buffers (wrapped in pcall for safety)
        const lua_code =
            \\local ok, modified = pcall(vim.fn.getbufinfo, {bufmodified = 1})
            \\if not ok then return false end
            \\return #modified > 0
        ;

        rpc.packArray(&buf, self.alloc, 2) catch |e| {
            self.log.write("requestQuit packArray error: {any}\n", .{e});
            self.quit_request_msgid.store(0, .release);
            return;
        };
        rpc.packStr(&buf, self.alloc, lua_code) catch |e| {
            self.log.write("requestQuit packStr error: {any}\n", .{e});
            self.quit_request_msgid.store(0, .release);
            return;
        };
        rpc.packArray(&buf, self.alloc, 0) catch |e| {
            self.log.write("requestQuit packArray(args) error: {any}\n", .{e});
            self.quit_request_msgid.store(0, .release);
            return;
        };

        self.sendRaw(buf.items) catch |e| {
            self.log.write("requestQuit sendRaw error: {any}\n", .{e});
            self.quit_request_msgid.store(0, .release);
            return;
        };

        self.log.write("rpc send: nvim_exec_lua for quit check (id={d})\n", .{id});
    }

    /// Confirm quit after user dialog.
    /// force: if true, use :qa! (discard changes), otherwise :qa
    pub fn quitConfirmed(self: *Core, force: bool) void {
        const cmd = if (force) "qa!" else "qa";
        self.requestCommand(cmd) catch |e| {
            self.log.write("quitConfirmed error: {any}\n", .{e});
        };
        self.log.write("quitConfirmed: sent {s}\n", .{cmd});
    }

    // ---- Neon glow configuration ----

    /// Free all owned glow group name strings.
    pub fn freeGlowGroupNames(self: *Core) void {
        for (self.glow_group_names.items) |name| {
            self.alloc.free(@constCast(name));
        }
        self.glow_group_names.clearRetainingCapacity();
    }

    /// Re-resolve glow group names → highlight IDs.
    /// Lightweight (hash lookups only). Safe to call under grid_mu.
    pub fn resolveGlowGroups(self: *Core) void {
        if (self.glow_hl_ids) |*m| {
            m.clearRetainingCapacity();
        } else {
            self.glow_hl_ids = std.AutoHashMap(u32, void).init(self.alloc);
        }
        // glow_all mode: skip per-group resolution, glow applies to all cells
        if (self.glow_all) {
            self.glow_enabled.store(true, .release);
            return;
        }
        var map = &(self.glow_hl_ids.?);
        for (self.glow_group_names.items) |name| {
            if (self.hl.groups.get(name)) |hl_id| {
                map.put(hl_id, {}) catch {};
            }
        }
        self.glow_enabled.store(self.glow_group_names.items.len > 0, .release);
    }

    /// Request vim.g.zonvie_glow from Neovim via RPC.
    /// Tracked by glow_request_msgid; response handled in handleRpcResponse.
    /// Multiple requests may be in flight; only the latest one's response is processed.
    pub fn requestGlowConfig(self: *Core) void {
        const id = self.nextMsgId();
        self.glow_request_msgid.store(id, .release);

        var buf: rpc.Buf = .empty;
        defer buf.deinit(self.alloc);

        self.sendRequestHeader(&buf, id, "nvim_exec_lua") catch {
            self.glow_request_msgid.store(0, .release);
            return;
        };
        rpc.packArray(&buf, self.alloc, 2) catch {
            self.glow_request_msgid.store(0, .release);
            return;
        };
        rpc.packStr(&buf, self.alloc, "return vim.g.zonvie_glow") catch {
            self.glow_request_msgid.store(0, .release);
            return;
        };
        rpc.packArray(&buf, self.alloc, 0) catch {
            self.glow_request_msgid.store(0, .release);
            return;
        };
        self.sendRaw(buf.items) catch {
            self.glow_request_msgid.store(0, .release);
            return;
        };
        self.log.write("rpc send: requestGlowConfig (id={d})\n", .{id});
    }

    /// Set a global option value in Neovim via nvim_set_option_value.
    /// Used e.g. to sync the effective `guifont` back to Neovim so `:set
    /// guifont?` reports what the frontend is actually rendering.
    pub fn requestSetOptionValue(self: *Core, name: []const u8, value: []const u8) !void {
        const id = self.nextMsgId();
        var buf: rpc.Buf = .empty;
        defer buf.deinit(self.alloc);

        try self.sendRequestHeader(&buf, id, "nvim_set_option_value");

        // nvim_set_option_value(name, value, opts{}) — empty opts applies globally.
        try rpc.packArray(&buf, self.alloc, 3);
        try rpc.packStr(&buf, self.alloc, name);
        try rpc.packStr(&buf, self.alloc, value);
        try rpc.packMap(&buf, self.alloc, 0);

        try self.sendRaw(buf.items);

        self.log.write("rpc send: nvim_set_option_value {s}='{s}' (id={d})\n", .{ name, value, id });
    }

    /// Execute Lua code in Neovim via nvim_exec_lua.
    pub fn requestExecLua(self: *Core, lua_code: []const u8) !void {
        const id = self.nextMsgId();
        var buf: rpc.Buf = .empty;
        defer buf.deinit(self.alloc);

        try self.sendRequestHeader(&buf, id, "nvim_exec_lua");

        // nvim_exec_lua(code, args) - args is an empty array
        try rpc.packArray(&buf, self.alloc, 2);
        try rpc.packStr(&buf, self.alloc, lua_code);
        try rpc.packArray(&buf, self.alloc, 0); // empty args

        try self.sendRaw(buf.items);

        self.log.write("rpc send: nvim_exec_lua (id={d})\n", .{id});
    }

    /// Create message split window in Neovim via Lua.
    /// This creates a real Neovim split window that the user can interact with.
    /// Based on noice.nvim/nui.nvim patterns for state management.
    /// enter=true: focus moves to split (for regular messages)
    /// enter=false: focus stays in current window (for confirm dialogs)
    /// label: optional label line showing command and duration (prepended to content)
    pub fn createMessageSplit(self: *Core, content: []const u8, line_count: u32, enter: bool, clear_prompt: bool, label: ?[]const u8) !void {
        // Calculate height (max 20 lines, min 5)
        // Add 2 for label line + separator if label is present
        const extra_lines: u32 = if (label != null) 2 else 0;
        const height = @min(line_count + extra_lines, 20);

        // Lua code based on noice.nvim/nui.nvim patterns:
        // - If clear_prompt is true, send <CR> to clear return_prompt first (like noice.nvim)
        // - State tracked in _G._zonvie_msg_split
        // - Autocmd for cleanup on BufWipeout
        // - Skip if already mounted (prevents duplicate splits)
        var lua_buf: [4096]u8 = undefined;
        const enter_str = if (enter) "true" else "false";
        const clear_prompt_str = if (clear_prompt) "true" else "false";
        const label_str = label orelse "";
        const has_label_str = if (label != null) "true" else "false";
        const lua_code = try std.fmt.bufPrint(&lua_buf,
            \\local content = ...
            \\local height = {d}
            \\local enter = {s}
            \\local clear_prompt = {s}
            \\local label = "{s}"
            \\local has_label = {s}
            \\-- Function to create the split window
            \\local function create_split()
            \\  local state = _G._zonvie_msg_split or {{}}
            \\  _G._zonvie_msg_split = state
            \\  -- Check if already mounted
            \\  if state.buf and vim.api.nvim_buf_is_valid(state.buf) then
            \\    if state.win and vim.api.nvim_win_is_valid(state.win) then
            \\      return
            \\    end
            \\  end
            \\  -- Create buffer
            \\  local ok, buf = pcall(vim.api.nvim_create_buf, false, true)
            \\  if not ok then return end
            \\  state.buf = buf
            \\  -- Prepare lines with optional label
            \\  local lines = vim.split(content:gsub('\r', ''), '\n')
            \\  if has_label and label ~= "" then
            \\    local sep = string.rep("─", 40)
            \\    table.insert(lines, 1, sep)
            \\    table.insert(lines, 1, label)
            \\  end
            \\  -- Set buffer content
            \\  pcall(vim.api.nvim_buf_set_lines, buf, 0, -1, false, lines)
            \\  -- Create split window
            \\  local win_ok, win = pcall(vim.api.nvim_open_win, buf, enter, {{
            \\    split = 'below',
            \\    height = height,
            \\  }})
            \\  if not win_ok then return end
            \\  state.win = win
            \\  -- Buffer options
            \\  pcall(function()
            \\    vim.bo[buf].modifiable = false
            \\    vim.bo[buf].buftype = 'nofile'
            \\    vim.bo[buf].bufhidden = 'wipe'
            \\    vim.bo[buf].buflisted = false
            \\  end)
            \\  -- Apply highlight to label line (if present)
            \\  if has_label and label ~= "" then
            \\    pcall(vim.api.nvim_buf_add_highlight, buf, -1, "Title", 0, 0, -1)
            \\    pcall(vim.api.nvim_buf_add_highlight, buf, -1, "Comment", 1, 0, -1)
            \\  end
            \\  -- Keymaps for closing (only when entered)
            \\  if enter then
            \\    vim.keymap.set('n', 'q', ':close<CR>', {{buffer = buf, silent = true}})
            \\    vim.keymap.set('n', '<Esc>', ':close<CR>', {{buffer = buf, silent = true}})
            \\  end
            \\  -- Autocmd for cleanup
            \\  vim.api.nvim_create_autocmd('BufWipeout', {{
            \\    buffer = buf,
            \\    once = true,
            \\    callback = function()
            \\      _G._zonvie_msg_split = nil
            \\    end,
            \\  }})
            \\  -- Close on BufLeave (only when entered)
            \\  if enter then
            \\    vim.api.nvim_create_autocmd('BufLeave', {{
            \\      buffer = buf,
            \\      once = true,
            \\      callback = function()
            \\        if vim.api.nvim_win_is_valid(win) then
            \\          vim.api.nvim_win_close(win, true)
            \\        end
            \\      end,
            \\    }})
            \\  end
            \\end
            \\-- Clear return_prompt first if needed, then create split
            \\-- Use nested vim.schedule when clear_prompt to ensure <CR> is fully processed
            \\if clear_prompt then
            \\  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<cr>", true, false, true), "n", false)
            \\  vim.schedule(function()
            \\    vim.schedule(create_split)
            \\  end)
            \\else
            \\  vim.schedule(create_split)
            \\end
        , .{ height, enter_str, clear_prompt_str, label_str, has_label_str });

        // Send nvim_exec_lua with content as argument
        try self.requestExecLuaWithArg(lua_code, content);
        self.log.write("rpc send: createMessageSplit (lines={d}, height={d}, enter={any}, label={?s})\n", .{ line_count, height, enter, label });
    }

    /// Execute Lua code in Neovim via nvim_exec_lua with a string argument.
    fn requestExecLuaWithArg(self: *Core, lua_code: []const u8, arg: []const u8) !void {
        const id = self.nextMsgId();
        var buf: rpc.Buf = .empty;
        defer buf.deinit(self.alloc);

        try self.sendRequestHeader(&buf, id, "nvim_exec_lua");

        // nvim_exec_lua(code, args) - args is array with one string
        try rpc.packArray(&buf, self.alloc, 2);
        try rpc.packStr(&buf, self.alloc, lua_code);
        try rpc.packArray(&buf, self.alloc, 1);
        try rpc.packStr(&buf, self.alloc, arg);

        try self.sendRaw(buf.items);

        self.log.write("rpc send: nvim_exec_lua with arg (id={d})\n", .{id});
    }

    // --- IME preedit via inline virt_text extmark --------------------------
    //
    // These run on the frontend UI thread from the platform IME composition
    // callbacks (macOS setMarkedText / Windows WM_IME_COMPOSITION), the same
    // thread that already calls sendInput, so sendRaw is safe to use here.

    /// Define the preedit highlight groups once. `default = true` lets a user
    /// colorscheme override them. ZonviePreedit is the normal (unconverted)
    /// clause; ZonviePreeditTarget marks the clause currently being converted
    /// (the IME's focused/selected clause), drawn with a bold double underline
    /// plus a lightened selection background (Visual blended toward Normal) so
    /// the converting clause stands out.
    fn ensurePreeditSetup(self: *Core) void {
        if (self.preedit_setup_done.load(.monotonic)) return;
        self.preedit_setup_done.store(true, .monotonic);
        self.requestExecLua(
            \\vim.api.nvim_set_hl(0, "ZonviePreedit", { underline = true, default = true })
            \\local function rgb(c) return math.floor(c / 65536) % 256, math.floor(c / 256) % 256, c % 256 end
            \\local function blend(c1, c2, t)
            \\  local r1, g1, b1 = rgb(c1)
            \\  local r2, g2, b2 = rgb(c2)
            \\  return math.floor(r1 * t + r2 * (1 - t) + 0.5) * 65536
            \\    + math.floor(g1 * t + g2 * (1 - t) + 0.5) * 256
            \\    + math.floor(b1 * t + b2 * (1 - t) + 0.5)
            \\end
            \\local hl = { underdouble = true, bold = true, default = true }
            \\local ok_v, vis = pcall(vim.api.nvim_get_hl, 0, { name = "Visual", link = false })
            \\local visbg = ok_v and vis.bg or nil
            \\if visbg then
            \\  -- Lighten the selection color toward the editor background. When
            \\  -- Normal has no explicit bg (transparent setups), fall back to
            \\  -- black/white per &background so a color is still produced.
            \\  local ok_n, nor = pcall(vim.api.nvim_get_hl, 0, { name = "Normal", link = false })
            \\  local base = (vim.o.background == "light") and 0xffffff or 0x000000
            \\  local norbg = (ok_n and nor.bg) or base
            \\  hl.bg = string.format("#%06x", blend(visbg, norbg, 0.5))
            \\end
            \\vim.api.nvim_set_hl(0, "ZonviePreeditTarget", hl)
        ) catch {};
    }

    /// Delete the inline preedit extmark from the buffer it was last placed in
    /// (recorded in vim.g.zonvie_preedit_buf), so a buffer/focus change during
    /// composition cannot leave a stale extmark behind.
    fn clearPreeditExtmark(self: *Core) void {
        self.requestExecLua(
            \\local ns = vim.api.nvim_create_namespace("zonvie_preedit")
            \\local b = vim.g.zonvie_preedit_buf
            \\if b and vim.api.nvim_buf_is_valid(b) then
            \\  vim.api.nvim_buf_clear_namespace(b, ns, 0, -1)
            \\end
            \\vim.g.zonvie_preedit_buf = nil
        ) catch {};
    }

    /// Set/update the IME preedit display as an inline virt_text extmark at the
    /// cursor. Returns true when the preedit was placed via extmark (the
    /// frontend should hide its overlay); false when the frontend should draw
    /// the preedit itself — extmark mode disabled, or not in an insert/replace
    /// mode where an inline buffer extmark makes sense (cmdline, terminal, ...).
    ///
    /// target_start/target_end are UTF-8 byte offsets into `text` marking the
    /// clause currently being converted (the IME's focused clause), highlighted
    /// with ZonviePreeditTarget. When target_start >= target_end the whole
    /// preedit uses the normal ZonviePreedit group.
    pub fn setPreedit(self: *Core, text: []const u8, target_start: usize, target_end: usize) bool {
        if (self.msg_config.ime.preedit_mode != .extmark) return false;

        // Read the current mode under grid_mu, but keep the critical section
        // tiny: never send RPC (alloc + write-queue lock + possible blocking
        // write) while holding grid_mu, which is shared with the redraw thread.
        var editing = false;
        {
            self.grid_mu.lock();
            defer self.grid_mu.unlock();
            const mode = std.mem.sliceTo(&self.grid.current_mode_name, 0);
            editing = std.mem.startsWith(u8, mode, "insert") or
                std.mem.startsWith(u8, mode, "replace");
        }

        if (!editing) {
            // Outside insert/replace (cmdline, terminal, ...): the frontend
            // draws the overlay. Drop any stale extmark from a previous
            // insert-mode composition first (RPC sent here, outside grid_mu).
            if (self.preedit_visible.load(.monotonic)) {
                self.clearPreeditExtmark();
                self.preedit_visible.store(false, .monotonic);
            }
            return false;
        }

        self.ensurePreeditSetup();

        if (text.len == 0) {
            self.clearPreedit();
            return true;
        }

        // Re-place the extmark at the cursor on every composition update. The
        // previous preedit (possibly in another buffer) is cleared first via
        // the buffer recorded in vim.g.zonvie_preedit_buf, so a buffer/focus
        // change mid-composition can't leave a stale extmark behind. The Lua
        // splits the preedit into normal/target/normal chunks so the
        // converting clause is visually distinct.
        const id = self.nextMsgId();
        var buf: rpc.Buf = .empty;
        defer buf.deinit(self.alloc);
        self.sendRequestHeader(&buf, id, "nvim_exec_lua") catch return false;
        rpc.packArray(&buf, self.alloc, 2) catch return false; // [code, args]
        rpc.packStr(&buf, self.alloc,
            \\local text, ts, te = ...
            \\local ns = vim.api.nvim_create_namespace("zonvie_preedit")
            \\local buf = vim.api.nvim_get_current_buf()
            \\local prev = vim.g.zonvie_preedit_buf
            \\if prev and prev ~= buf and vim.api.nvim_buf_is_valid(prev) then
            \\  vim.api.nvim_buf_clear_namespace(prev, ns, 0, -1)
            \\end
            \\vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
            \\vim.g.zonvie_preedit_buf = buf
            \\local pos = vim.api.nvim_win_get_cursor(0)
            \\local chunks
            \\if ts < te and te <= #text then
            \\  chunks = {}
            \\  if ts > 0 then chunks[#chunks + 1] = { text:sub(1, ts), "ZonviePreedit" } end
            \\  chunks[#chunks + 1] = { text:sub(ts + 1, te), "ZonviePreeditTarget" }
            \\  if te < #text then chunks[#chunks + 1] = { text:sub(te + 1), "ZonviePreedit" } end
            \\else
            \\  chunks = { { text, "ZonviePreedit" } }
            \\end
            \\pcall(vim.api.nvim_buf_set_extmark, buf, ns, pos[1] - 1, pos[2], {
            \\  virt_text = chunks,
            \\  virt_text_pos = "inline",
            \\  right_gravity = false,
            \\})
        ) catch return false;
        rpc.packArray(&buf, self.alloc, 3) catch return false; // args: text, ts, te
        rpc.packStr(&buf, self.alloc, text) catch return false;
        rpc.packInt(&buf, self.alloc, @intCast(target_start)) catch return false;
        rpc.packInt(&buf, self.alloc, @intCast(target_end)) catch return false;
        self.sendRaw(buf.items) catch return false;

        self.preedit_visible.store(true, .monotonic);
        return true;
    }

    /// Clear the inline preedit extmark (called on commit or cancel).
    pub fn clearPreedit(self: *Core) void {
        if (!self.preedit_visible.load(.monotonic)) return;
        self.clearPreeditExtmark();
        self.preedit_visible.store(false, .monotonic);
    }

    /// Scroll view to specified line number (1-based) via nvim_exec_lua.
    /// If use_bottom is true, positions the line at the bottom (zb), otherwise at the top (zt).
    fn requestScrollToLine(self: *Core, line: i64, use_bottom: bool) !void {
        const id = self.nextMsgId();
        var buf: rpc.Buf = .empty;
        defer buf.deinit(self.alloc);

        try self.sendRequestHeader(&buf, id, "nvim_exec_lua");

        // Lua code: args are passed as varargs
        // arg1 = line number, arg2 = use_bottom (0 or 1)
        // Use normal command to scroll (same approach as nvim-scrollview)
        // Temporarily set scrolloff=0 to allow scrolling to the very end of file
        const lua_code =
            \\local line, use_bottom = select(1, ...), select(2, ...)
            \\local so = vim.wo.scrolloff
            \\vim.wo.scrolloff = 0
            \\if use_bottom == 1 then
            \\  vim.cmd('keepjumps normal! ' .. line .. 'Gzb')
            \\else
            \\  vim.cmd('keepjumps normal! ' .. line .. 'Gzt')
            \\end
            \\vim.wo.scrolloff = so
        ;

        // nvim_exec_lua(code, args) - args is array with two integers
        try rpc.packArray(&buf, self.alloc, 2);
        try rpc.packStr(&buf, self.alloc, lua_code);
        try rpc.packArray(&buf, self.alloc, 2);
        try rpc.packInt(&buf, self.alloc, line);
        try rpc.packInt(&buf, self.alloc, if (use_bottom) @as(i64, 1) else @as(i64, 0));

        try self.sendRaw(buf.items);

        self.log.write("rpc send: nvim_exec_lua scrollToLine (id={d}) line={d} bottom={any}\n", .{ id, line, use_bottom });
    }

    /// Send page scroll via nvim_exec_lua using winsaveview/winrestview API.
    /// Resolves grid_id to a Neovim winid and uses nvim_win_call for explicit
    /// window targeting. Uses winsaveview to preserve full view state (topfill,
    /// skipcol, etc.), modifies topline, and adjusts cursor only when it would
    /// fall outside the new visible range. Works for all buffer types including
    /// terminal buffers. No normal! or key mappings involved.
    fn requestPageScroll(self: *Core, grid_id: i64, forward: bool) !void {
        const id = self.nextMsgId();
        var buf: rpc.Buf = .empty;
        defer buf.deinit(self.alloc);

        try self.sendRequestHeader(&buf, id, "nvim_exec_lua");

        // Resolve grid_id -> Neovim winid (requires grid_mu)
        const winid: i64 = blk: {
            self.grid_mu.lock();
            defer self.grid_mu.unlock();
            break :blk self.grid.getWinId(grid_id) orelse 0;
        };

        const lua_code =
            \\local fwd, winid = ...
            \\local win = winid > 0 and winid or vim.api.nvim_get_current_win()
            \\vim.api.nvim_win_call(win, function()
            \\  if vim.fn.mode() == 't' then
            \\    vim.cmd('stopinsert')
            \\  end
            \\  local view = vim.fn.winsaveview()
            \\  local h = vim.api.nvim_win_get_height(win)
            \\  local lc = vim.api.nvim_buf_line_count(vim.api.nvim_win_get_buf(win))
            \\  local amt = math.max(1, h - 2)
            \\  if fwd then
            \\    view.topline = math.min(lc, view.topline + amt)
            \\  else
            \\    view.topline = math.max(1, view.topline - amt)
            \\  end
            \\  local bot = math.min(lc, view.topline + h - 1)
            \\  if view.lnum < view.topline then
            \\    view.lnum = view.topline
            \\  elseif view.lnum > bot then
            \\    view.lnum = bot
            \\  end
            \\  vim.fn.winrestview(view)
            \\end)
        ;

        // nvim_exec_lua(code, args) - args: [forward, winid]
        try rpc.packArray(&buf, self.alloc, 2);
        try rpc.packStr(&buf, self.alloc, lua_code);
        try rpc.packArray(&buf, self.alloc, 2);
        try rpc.packBool(&buf, self.alloc, forward);
        try rpc.packInt(&buf, self.alloc, winid);

        try self.sendRaw(buf.items);

        self.log.write("rpc send: nvim_exec_lua pageScroll (id={d}) grid={d} winid={d} forward={any}\n", .{ id, grid_id, winid, forward });
    }

    /// Send nvim_input_mouse RPC for scroll events.
    /// nvim_input_mouse(button, action, modifier, grid, row, col)
    fn requestMouseScroll(self: *Core, grid_id: i64, row: i32, col: i32, direction: []const u8, modifier: []const u8) !void {
        const id = self.nextMsgId();
        var buf: rpc.Buf = .empty;
        defer buf.deinit(self.alloc);

        try self.sendRequestHeader(&buf, id, "nvim_input_mouse");

        // nvim_input_mouse takes 6 arguments:
        // button: "wheel" for scroll
        // action: "up" or "down"
        // modifier: "" or combination like "SC" for shift+ctrl
        // grid: grid_id
        // row: row position
        // col: column position
        try rpc.packArray(&buf, self.alloc, 6);
        try rpc.packStr(&buf, self.alloc, "wheel"); // button
        try rpc.packStr(&buf, self.alloc, direction); // action (up/down)
        try rpc.packStr(&buf, self.alloc, modifier); // modifier
        try rpc.packInt(&buf, self.alloc, grid_id); // grid
        try rpc.packInt(&buf, self.alloc, @as(i64, row)); // row
        try rpc.packInt(&buf, self.alloc, @as(i64, col)); // col

        try self.sendRaw(buf.items);

        self.log.write("rpc send: nvim_input_mouse (id={d}) wheel {s} mod=\"{s}\" grid={d} row={d} col={d}\n", .{ id, direction, modifier, grid_id, row, col });
    }

    /// Send nvim_input_mouse RPC for button events (click, drag, release).
    /// nvim_input_mouse(button, action, modifier, grid, row, col)
    fn requestMouseInput(
        self: *Core,
        button: []const u8,
        action: []const u8,
        modifier: []const u8,
        grid_id: i64,
        row: i32,
        col: i32,
    ) !void {
        const id = self.nextMsgId();
        var buf: rpc.Buf = .empty;
        defer buf.deinit(self.alloc);

        try self.sendRequestHeader(&buf, id, "nvim_input_mouse");

        // nvim_input_mouse takes 6 arguments:
        // button: "left", "right", "middle", "x1", "x2"
        // action: "press", "drag", "release"
        // modifier: "" or combination like "SC" for shift+ctrl
        // grid: grid_id
        // row: row position
        // col: column position
        try rpc.packArray(&buf, self.alloc, 6);
        try rpc.packStr(&buf, self.alloc, button);
        try rpc.packStr(&buf, self.alloc, action);
        try rpc.packStr(&buf, self.alloc, modifier);
        try rpc.packInt(&buf, self.alloc, grid_id);
        try rpc.packInt(&buf, self.alloc, @as(i64, row));
        try rpc.packInt(&buf, self.alloc, @as(i64, col));

        try self.sendRaw(buf.items);

        self.log.write("rpc send: nvim_input_mouse (id={d}) {s} {s} mod={s} grid={d} row={d} col={d}\n", .{ id, button, action, modifier, grid_id, row, col });
    }

    const FlushCtx = flush.FlushCtx;


    // --- Forwarding stubs for rpc_session.zig ---

    pub fn containsPasswordPrompt(data: []const u8) bool {
        return rpc_session.containsPasswordPrompt(data);
    }

    pub fn eqlIgnoreCase(a: []const u8, b: []const u8) bool {
        return rpc_session.eqlIgnoreCase(a, b);
    }

    pub fn logEnvHints(self: *Core) void {
        rpc_session.logEnvHints(self);
    }

    pub fn handleRpcResponse(self: *Core, top: []mp.Value) void {
        rpc_session.handleRpcResponse(self, top);
    }

    pub fn handleRpcRequest(self: *Core, arena: std.mem.Allocator, top: []mp.Value) void {
        rpc_session.handleRpcRequest(self, arena, top);
    }

    pub fn handleClipboardGet(self: *Core, msgid: i64, params: mp.Value) void {
        rpc_session.handleClipboardGet(self, msgid, params);
    }

    pub fn handleClipboardSet(self: *Core, msgid: i64, params: mp.Value) void {
        rpc_session.handleClipboardSet(self, msgid, params);
    }

    pub fn sendRpcErrorResponse(self: *Core, msgid: i64, err_msg: []const u8) !void {
        return rpc_session.sendRpcErrorResponse(self, msgid, err_msg);
    }

    pub fn sendRpcBoolResponse(self: *Core, msgid: i64, value: bool) !void {
        return rpc_session.sendRpcBoolResponse(self, msgid, value);
    }

    pub fn sendClipboardGetResponse(self: *Core, msgid: i64, content: []const u8) !void {
        return rpc_session.sendClipboardGetResponse(self, msgid, content);
    }

    pub fn setupClipboard(self: *Core) void {
        rpc_session.setupClipboard(self);
    }

    pub fn handleRpcNotification(self: *Core, arena: std.mem.Allocator, top: []mp.Value) void {
        rpc_session.handleRpcNotification(self, arena, top);
    }


    /// Compare current external_grids with known_external_grids and notify frontend.
    /// Returns true if new external grids were added (need forced render).

    // --- Forwarding stubs for flush.zig ---

    pub fn notifyExternalWindowChanges(self: *Core) bool {
        return flush.notifyExternalWindowChanges(self);
    }

    pub fn sendExternalGridVerticesFiltered(self: *Core, force_render: bool, only_grid_id: ?i64) void {
        flush.sendExternalGridVerticesFiltered(self, force_render, only_grid_id);
    }

    pub fn sendExternalGridVertices(self: *Core, force_render: bool) void {
        flush.sendExternalGridVertices(self, force_render);
    }

    pub fn notifyCmdlineChanges(self: *Core) void {
        flush.notifyCmdlineChanges(self);
    }

    pub fn sendCmdlineBlockShow(self: *Core, current_line_visible: bool, visible_level: u32) void {
        flush.sendCmdlineBlockShow(self, current_line_visible, visible_level);
    }

    pub fn sendCmdlineHide(self: *Core) void {
        flush.sendCmdlineHide(self);
    }

    pub fn notifyPopupmenuChanges(self: *Core) void {
        flush.notifyPopupmenuChanges(self);
    }

    pub fn notifyTablineChanges(self: *Core) void {
        flush.notifyTablineChanges(self);
    }

    pub fn sendPopupmenuShow(self: *Core) void {
        flush.sendPopupmenuShow(self);
    }

    pub fn sendPopupmenuHide(self: *Core) void {
        flush.sendPopupmenuHide(self);
    }

    pub fn checkMsgShowThrottleTimeout(self: *Core) void {
        flush.checkMsgShowThrottleTimeout(self);
        flush.checkMsgAutoHideTimeout(self);
    }

    pub fn notifyMessageChanges(self: *Core) void {
        flush.notifyMessageChanges(self);
    }

    pub fn sendMsgShow(self: *Core) void {
        flush.sendMsgShow(self);
    }

    pub fn buildMsgLineCache(self: *Core) void {
        flush.buildMsgLineCache(self);
    }

    pub fn renderMsgGridFromCache(self: *Core, scroll_offset: u32) void {
        flush.renderMsgGridFromCache(self, scroll_offset);
    }

    pub fn handleMsgGridScroll(self: *Core, direction: []const u8) void {
        flush.handleMsgGridScroll(self, direction);
    }

    pub fn processPendingMsgScroll(self: *Core) void {
        flush.processPendingMsgScroll(self);
    }

    pub fn hideMsgShow(self: *Core) void {
        flush.hideMsgShow(self);
    }

    pub fn sendMsgShowCallback(self: *Core, msg: anytype, chunks: anytype, view: config.MsgViewType, timeout_sec: f32) void {
        flush.sendMsgShowCallback(self, msg, chunks, view, timeout_sec);
    }

    pub fn sendMsgHistoryCallbackAll(self: *Core, entries: []const grid_mod.MsgHistoryEntry, view: config.MsgViewType) void {
        flush.sendMsgHistoryCallbackAll(self, entries, view);
    }

    pub fn sendPendingMsgShowAt(self: *Core, index: usize) void {
        flush.sendPendingMsgShowAt(self, index);
    }

    pub fn sendPendingMsgShowCallback(self: *Core, pm: *const grid_mod.PendingMessage) void {
        flush.sendPendingMsgShowCallback(self, pm);
    }

    pub fn sendMsgClear(self: *Core) void {
        flush.sendMsgClear(self);
    }

    pub fn closeMessageSplit(self: *Core) void {
        flush.closeMessageSplit(self);
    }

    pub fn sendMsgShowmode(self: *Core) void {
        flush.sendMsgShowmode(self);
    }

    pub fn sendMsgShowcmd(self: *Core) void {
        flush.sendMsgShowcmd(self);
    }

    pub fn sendMsgRuler(self: *Core) void {
        flush.sendMsgRuler(self);
    }

    pub fn sendMsgHistoryShow(self: *Core) void {
        flush.sendMsgHistoryShow(self);
    }

    pub fn hideMsgHistory(self: *Core) void {
        flush.hideMsgHistory(self);
    }


    /// Set a Neovim global variable via nvim_set_var
    fn requestSetVar(self: *Core, name: []const u8, value: []const u8) !void {
        const id = self.nextMsgId();
        var buf: rpc.Buf = .empty;
        defer buf.deinit(self.alloc);

        try self.sendRequestHeader(&buf, id, "nvim_set_var");

        try rpc.packArray(&buf, self.alloc, 2);
        try rpc.packStr(&buf, self.alloc, name);
        try rpc.packStr(&buf, self.alloc, value);

        try self.sendRaw(buf.items);
    }

    /// Count UTF-8 codepoints in a string.

    // --- Utility forwarding stubs ---

    pub fn countUtf8Codepoints(s: []const u8) u32 {
        return flush.countUtf8Codepoints(s);
    }

    pub fn isWideChar(cp: u32) bool {
        return flush.isWideChar(cp);
    }

    pub fn countDisplayWidth(s: []const u8) u32 {
        return flush.countDisplayWidth(s);
    }



    fn runLoop(self: *Core) void {
        rpc_session.runLoop(self);
    }
};
