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
const log_mod = @import("log.zig");
const Logger = log_mod.Logger;
const config = @import("config.zig");
const msg_view = @import("msg_view.zig");
const flush = @import("flush.zig");
const rpc_session = @import("rpc_session.zig");
const rpc_transport = @import("rpc_transport.zig");
const shelf_packer = @import("shelf_packer.zig");
const vertexgen = @import("vertexgen.zig");
const clock = @import("clock.zig");

/// Re-exported here so callers in this file can spell `Stream` without
/// reaching into `rpc_transport`.
pub const Stream = rpc_transport.Stream;

/// Position/size snapshot for a known external grid. Used to detect
/// changes in anchor position (e.g. popupmenu re-show) and re-fire
/// on_external_window so the frontend can update window position.
pub const KnownExtGridInfo = struct { win: i64, start_row: i32, start_col: i32, rows: u32, cols: u32 };

pub const GLYPH_CACHE_INVALID_KEY: u64 = std.math.maxInt(u64);

/// Flushes a shifted-out row stays in the reclamation liveness set. macOS keeps
/// at most two retained scroll rows and shifts them one flush at a time; one
/// flush of slack covers the hand-off. An expired shadow only ever delays
/// reclamation, so erring high is the safe direction.
pub const retained_shadow_expiry: u8 = 3;
const TRANSIENT_GLYPH_RETRY_INITIAL_NS: i128 = 250 * std.time.ns_per_ms;
const TRANSIENT_GLYPH_RETRY_MAX_NS: i128 = 4 * std.time.ns_per_s;
const TRANSIENT_GLYPH_RETRY_MAX_ATTEMPTS: u8 = 5;

pub const GlyphCacheProbe = struct {
    hit: ?usize,
    insert: usize,
};

/// Two-choice, allocation-free probe for the fixed-size glyph caches. Two
/// keys that collide at the primary index can coexist at independent secondary
/// indices; when both are occupied a stable hash bit selects the victim.
pub fn glyphCacheProbe(keys: []const u64, key: u64, hash: u64) GlyphCacheProbe {
    std.debug.assert(keys.len > 0);
    const primary: usize = @intCast(hash % keys.len);
    var mixed = hash ^ key ^ 0x9E3779B97F4A7C15;
    mixed ^= mixed >> 30;
    mixed *%= 0xBF58476D1CE4E5B9;
    mixed ^= mixed >> 27;
    mixed *%= 0x94D049BB133111EB;
    mixed ^= mixed >> 31;
    var secondary: usize = @intCast(mixed % keys.len);
    if (secondary == primary and keys.len > 1) secondary = (secondary + 1) % keys.len;

    if (keys[primary] == key) return .{ .hit = primary, .insert = primary };
    if (keys[secondary] == key) return .{ .hit = secondary, .insert = secondary };
    if (keys[primary] == GLYPH_CACHE_INVALID_KEY) return .{ .hit = null, .insert = primary };
    if (keys[secondary] == GLYPH_CACHE_INVALID_KEY) return .{ .hit = null, .insert = secondary };
    return .{ .hit = null, .insert = if ((mixed >> 63) == 0) primary else secondary };
}

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

    /// AI-agent work status for a tabpage (from the zonvie_agent_status RPC
    /// notification). Low 7 bits of state: 0=none, 1=idle (agent present, done),
    /// 2=working/claude, 3=working/braille (codex & generic),
    /// 4=waiting for user input (a decision prompt is on screen). Bit 7 (0x80)
    /// is a "fire the OS notification now" flag (only combined with base 1 or
    /// 4). The frontend renders/animates the per-tab indicator from
    /// `state & 0x7F` and must not edge-detect notifications itself (a
    /// flagged report can target a tab not currently displaying the agent's
    /// terminal). Fired immediately on change (not coupled to redraw, so a
    /// background-tab agent still updates).
    on_agent_status: ?*const fn (ctx: ?*anyopaque, tab_handle: i64, state: u8, title: [*]const u8, title_len: usize) callconv(.c) void = null,

    /// Called when a grid receives a grid_scroll event. rows_delta is the
    /// signed distance the content moved, summed over every scroll of that grid
    /// in the batch this notification stands for — a frontend holding a
    /// sub-cell scroll offset has to give back exactly that distance, and one
    /// notification can stand for several scrolls.
    on_grid_scroll: ?*const fn (ctx: ?*anyopaque, grid_id: i64, rows_delta: i32) callconv(.c) void = null,

    /// Called when IME should be turned off (mode change with input.ime_disable_on_modechange,
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

    /// Neovim-initiated main grid resize (`:set columns=` / `:set lines=`).
    /// Fired only when grid 1's reported size differs from the size the
    /// frontend last supplied via updateLayoutPx, i.e. Neovim changed it
    /// rather than echoing the UI's own resize request.
    on_main_grid_size: ?*const fn (ctx: ?*anyopaque, rows: u32, cols: u32) callconv(.c) void = null,
};

const PipeReader = rpc_session.PipeReader;
const CwdOwner = rpc_session.CwdOwner;

const GridEntry = flush.GridEntry;
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

/// Cumulative attempt/busy counters for a single grid_mu tryLock call site.
/// See the perf_lock_* fields on Core for why these must be atomic.
pub const LockContentionStat = struct {
    attempts: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    busy: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    pub fn record(self: *LockContentionStat, acquired: bool) void {
        _ = self.attempts.fetchAdd(1, .monotonic);
        if (!acquired) _ = self.busy.fetchAdd(1, .monotonic);
    }
};

pub const RedrawRecoveryState = enum {
    healthy,
    await_detach,
    await_attach,
};

pub const Core = struct {
    pub const MAX_WRITE_QUEUE_SIZE: usize = 4 * 1024 * 1024; // 4MB cap for write queue
    const UI_STATE_WRITE_RESERVE_SIZE: usize = 64 * 1024;
    const MAX_TOTAL_WRITE_QUEUE_SIZE: usize = MAX_WRITE_QUEUE_SIZE + UI_STATE_WRITE_RESERVE_SIZE;
    const UI_STATE_RPC_STACK_SIZE: usize = 256;
    const WriteClass = enum { normal, ui_state };

    alloc: std.mem.Allocator,
    cb: Callbacks,
    ctx: ?*anyopaque,

    last_sent_content_rev: u64 = 0,
    last_sent_cursor_rev: u64 = 0,
    last_ext_cursor_grid: i64 = 1, // Track which grid had cursor for external grid updates
    last_ext_cursor_rev: u64 = 0, // Track cursor revision for external grid updates
    // Set by force resend (c_api.zig zonvie_core_force_resend/_locked): forces
    // sendExternalGridVerticesFiltered to treat EVERY external grid as
    // cursor_affected for one flush, regardless of last_ext_cursor_grid.
    // A failed flush can leave last_ext_cursor_grid pointing at the NEW
    // cursor grid even though the frontend never actually committed an empty
    // cursor for the OLD one (the two are tracked independently — see
    // sendExternalGridVerticesFiltered's abort-skip defer) — force resend
    // cannot know which specific grid that was, so instead of relying on
    // last_ext_cursor_grid it just re-checks every external grid once.
    force_ext_cursor_recheck: bool = false,
    pre_cmdline_cursor_grid: i64 = 1, // Cursor grid before cmdline was shown (for restoring after cmdline closes)
    pre_cmdline_cursor_row: u32 = 0,
    pre_cmdline_cursor_col: u32 = 0,

    log: Logger,
    grid: Grid,
    hl: Highlights,

    // Reusable vertex buffers (avoid alloc/free on every flush)
    main_verts: std.ArrayListUnmanaged(c_api.Vertex) = .empty,
    cursor_verts: std.ArrayListUnmanaged(c_api.Vertex) = .empty,

    row_verts: std.ArrayListUnmanaged(c_api.Vertex) = .empty,
    // Partial-only main submission preserves global five-pass ordering by
    // accumulating under-decoration, glyph, strike, and overline layers here.
    // Capacities are retained across flushes; no per-frame buffers are created.
    partial_layer_verts: [4]std.ArrayListUnmanaged(c_api.Vertex) = .{
        .empty,
        .empty,
        .empty,
        .empty,
    },

    // Scroll-aware flush: per-row vertex cache.
    // Each entry holds the last emitted vertices for that row.
    // On scroll, entries are logically shifted and y-coordinates adjusted.
    // Invalidated on resize, guifont, atlas reset.
    scroll_cache: std.ArrayListUnmanaged(std.ArrayListUnmanaged(c_api.Vertex)) = .empty,
    scroll_cache_valid: std.DynamicBitSetUnmanaged = .{},
    scroll_cache_rows: u32 = 0,
    /// The row buffer currently being composed, while it is being composed.
    /// A row only reaches scroll_cache once it is finished, so without this the
    /// mid-flush collection cannot see the quads the in-progress row has
    /// already emitted and would reclaim the shelves they point into. Held as a
    /// pointer, not a slice: the list grows as the row is built.
    inflight_row_verts: ?*const std.ArrayListUnmanaged(c_api.Vertex) = null,
    /// Set when the frontend declined to publish a frame this core had already
    /// regenerated rows for. scroll_cache then holds the refused frame while
    /// the screen still shows the previous one, so it no longer describes what
    /// is displayed and cannot be used to prove a shelf is unreferenced.
    /// Cleared by the next accepted publication.
    display_mirror_stale: bool = false,
    /// Copies of the rows the scroll fast path most recently shifted out of the
    /// viewport. macOS retains those rows in a renderer-owned buffer ring to
    /// ease a scroll sub-row, and keeps drawing them for a few frames after
    /// this core has already overwritten their cache slots. That ring is
    /// invisible here, so reclamation would see their glyphs as unreferenced.
    retained_shadow: [2]std.ArrayListUnmanaged(c_api.Vertex) = .{ .empty, .empty },
    retained_shadow_age: [2]u8 = .{ retained_shadow_expiry, retained_shadow_expiry },
    retained_shadow_next: usize = 0,
    main_vertex_row_counts: std.ArrayListUnmanaged(usize) = .empty,
    main_surface_vertex_count: usize = 0,
    main_vertex_row_ledger_valid: bool = true,
    flush_vertex_count_aggregate: usize = 0,
    vertex_budget_transaction_active: bool = false,
    vertex_budget_main_touched: bool = false,
    vertex_budget_touched_grid_head: ?i64 = null,

    // Subgrid layout snapshot for scroll fast path.
    // Stores the (grid_id, row_start, row_end) of every composited subgrid
    // from the previous successful flush. Compared against the current layout
    // to detect position changes, additions, and removals that invalidate
    // cached row vertices inside the scroll region.
    prev_subgrid_snapshots: std.ArrayListUnmanaged(SubgridSnapshot) = .empty,
    // Current-layout normalization and row-dedup scratch for the subgrid
    // scroll-cache diff. Capacities persist across flushes.
    subgrid_diff_current: std.ArrayListUnmanaged(SubgridSnapshot) = .empty,
    subgrid_diff_row_marks: std.ArrayListUnmanaged(u32) = .empty,
    subgrid_diff_row_generation: u32 = 0,

    // Reusable scratch buffers (zero-allocation hot path)
    tmp_cells: RenderCells = .{},
    row_cells: RenderCells = .{},
    grid_entries: std.ArrayListUnmanaged(GridEntry) = .empty,
    // Sort scratch for float overlays anchored to an external grid — same
    // (zindex, compindex, order, grid_id) ordering as grid_entries, but kept
    // separate since it's populated by a different function
    // (sendExternalGridVerticesFiltered) that can run within the same flush
    // cycle as the main composite path that owns grid_entries.
    ext_float_entries: std.ArrayListUnmanaged(GridEntry) = .empty,
    // One win_pos scan per flush, grouped by external anchor and layer order.
    ext_float_anchor_entries: std.ArrayListUnmanaged(flush.ExternalFloatAnchorEntry) = .empty,
    ext_float_anchor_index_valid: bool = false,
    // Flush-local row index for floats composited into an external grid.
    // Entries are built once per anchor grid, sorted once, then referenced by
    // per-row buckets so dirty rows never rescan/sort the full win_pos map.
    ext_float_row_offsets: std.ArrayListUnmanaged(usize) = .empty,
    ext_float_row_write_offsets: std.ArrayListUnmanaged(usize) = .empty,
    ext_float_row_entry_indices: std.ArrayListUnmanaged(usize) = .empty,
    ext_float_row_index_valid: bool = false,
    ext_float_index_generation: u64 = 0,
    cached_subgrids_buf: std.ArrayListUnmanaged(flush.CachedSubgrid) = .empty,
    // Persistent main-composition row buckets. The exact layout snapshot
    // avoids rebuilding these on content-only flushes.
    main_subgrid_row_offsets: std.ArrayListUnmanaged(usize) = .empty,
    main_subgrid_row_write_offsets: std.ArrayListUnmanaged(usize) = .empty,
    main_subgrid_row_indices: std.ArrayListUnmanaged(usize) = .empty,
    main_subgrid_row_layout: std.ArrayListUnmanaged(flush.MainSubgridRowLayout) = .empty,
    main_subgrid_row_index_rows: u32 = 0,
    main_subgrid_row_index_valid: bool = false,
    main_subgrid_row_index_generation: u64 = 0,
    // The buckets store positions into the per-flush cached_subgrids slice, so
    // reuse additionally requires that slice to have the same length. A grid
    // clipped entirely off the bottom of the main grid contributes nothing to
    // the layout accounting, so a resize that adds or drops one changes the
    // slice without advancing layout_generation.
    main_subgrid_row_index_cached_len: usize = 0,
    key_buf: std.ArrayListUnmanaged(u8) = .empty,
    // Guards key_buf: sendInput/sendKeyEvent may now be called from a
    // frontend-owned display-link thread (macOS key-repeat synthesis) as
    // well as the normal per-keystroke caller, so the shared scratch buffer
    // is no longer single-writer. nextMsgId() (atomic) and sendRaw()'s
    // write_queue_mu are already safe for concurrent callers.
    key_buf_mu: std.Io.Mutex = .init,

    msgid: std.atomic.Value(i64) = std.atomic.Value(i64).init(1),

    // Writer thread: non-blocking stdin writes via dedicated thread.
    // sendRaw() enqueues data here; writerThreadFn drains to stdin pipe.
    // Lock order: grid_mu must be acquired before write_queue_mu if both are needed.
    write_queue_mu: std.Io.Mutex = .init,
    write_queue_cond: std.Io.Condition = .init,
    write_queue: std.ArrayListUnmanaged(u8) = .empty,
    // The writer swaps the active FIFO with this spare and performs transport
    // I/O without holding write_queue_mu. Both buffers permanently reserve
    // UI_STATE_WRITE_RESERVE_SIZE bytes so focus/resize can join the same FIFO
    // without allocation even when normal traffic reaches its 4 MiB cap.
    write_spare_queue: std.ArrayListUnmanaged(u8) = .empty,
    write_queue_normal_bytes: usize = 0,
    write_queue_ui_state_bytes: usize = 0,
    write_queue_closed: bool = false,
    writer_failed: bool = false,
    writer_thread: ?std.Thread = null,
    writer_cancel_requested: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    writer_exited: std.atomic.Value(bool) = std.atomic.Value(bool).init(true),

    // Mutex to protect grid state access from concurrent RPC and UI threads.
    grid_mu: std.Io.Mutex = .init,

    // Mutex to protect stdin_file close-and-null (POSIX socket transport
    // aliases stdin/stdout on one fd). Prevents race between stop() and
    // cleanupSession() closing the same fd. Both must serialize via this mutex.
    stdin_close_mu: std.Io.Mutex = .init,

    stop_flag: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    // stop() owns all Core resource teardown, not just thread shutdown.  It can
    // therefore run exactly once even though the public C API permits the
    // common stop(); destroy(); sequence.  Values: 0 = active, 1 = teardown in
    // progress, 2 = teardown complete.
    stop_state: std.atomic.Value(u8) = std.atomic.Value(u8).init(0),

    /// Set to true after nvim_ui_attach completes successfully.
    ui_attached: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    /// RPC-thread-owned redraw recovery state. A failed batch poisons the
    /// current UI attachment until a tracked detach/reset/attach cycle creates
    /// a fresh protocol epoch.
    redraw_recovery_state: RedrawRecoveryState = .healthy,
    redraw_recovery_msgid: i64 = 0,
    redraw_recovery_failed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    redraw_recovery_attach_rows: u32 = 0,
    redraw_recovery_attach_cols: u32 = 0,
    redraw_recovery_attempts: u8 = 0,
    /// Stores pending focus state when setFocus is called before ui_attach.
    /// 0 = no pending, 1 = pending focus gained, 2 = pending focus lost.
    pending_focus: std.atomic.Value(u8) = std.atomic.Value(u8).init(0),
    pending_focus_sequence: u64 = 0,
    thread: ?std.Thread = null,
    // Stable identity of the RPC run-loop thread. redraw_thread_id only covers
    // the intervals which hold grid_mu; callbacks such as on_exit run outside
    // those intervals and must still avoid joining their own thread in stop().
    rpc_thread_id: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),

    // Serializes publication, signaling, and withdrawal of child_handle.
    // cleanup claims the handle before Child.wait()/kill() can reap/close it,
    // so a concurrent stop can never signal a recycled PID/HANDLE.
    child_handle_mu: std.Io.Mutex = .init,
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
    /// POSIX-only wait service allocated and started with each spawned child.
    /// Preserved children transfer waitpid ownership here without allocating
    /// during cleanup or depending on stderr EOF.
    child_reaper: ?*rpc_session.ChildReaper = null,
    child_reaper_thread: ?std.Thread = null,

    /// Transport mode of the current session. Protected by stdin_close_mu;
    /// teardown must retain a snapshot before releasing that mutex.
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
    linespace_px: i32 = 0,

    /// Set by zonvie_core_abort_flush() from on_flush_begin callback.
    /// When true, the flush pipeline skips vertex generation and atlas operations.
    /// Reset at the start of each flush cycle before on_flush_begin is called.
    flush_aborted: bool = false,
    /// Main-grid dirty state as it stood when the current flush started.
    /// A frontend that refuses to publish (atlas back-sync still in flight,
    /// no free buffer set) leaves the previously committed frame on screen,
    /// so the retry only owes the rows this attempt consumed — restoring
    /// this is what keeps a rejection from costing a whole-viewport resend.
    flush_dirty_snapshot: grid_mod.DirtySnapshot = .{},
    /// Main row ledger as it stood when the current flush started, paired with
    /// flush_dirty_snapshot. Restoring both makes the core's accounting match
    /// the frame the frontend still has on screen after it declined to commit.
    flush_row_counts_snapshot: std.ArrayListUnmanaged(usize) = .empty,
    flush_main_vertex_count_snapshot: usize = 0,
    flush_row_ledger_snapshot_valid: bool = false,
    /// False when aborting cannot be healed by retrying the same state (for
    /// example, a fixed resource budget was exceeded).
    flush_retryable: bool = true,

    /// Set when an atlas reset is detected during the DEFERRED external-grid
    /// pass (sendExternalGridVertices, runs after on_flush_end's LIFO defer
    /// ordering puts it before the callback but after the main row-mode loop
    /// already dispatched this flush's main vertices with pre-reset UVs).
    /// markAllDirty() alone only schedules a correct resend for the NEXT
    /// flush — it cannot undo already-dispatched on_vertices_row calls for
    /// THIS flush, whose vertices would otherwise be committed alongside the
    /// just-reset (differently-packed) atlas texture: one frame of visible
    /// glyph corruption. Read by frontends via
    /// zonvie_core_flush_had_atlas_corruption() (while grid_mu is still
    /// held, from on_flush_end) to cancel the current flush's commit
    /// entirely instead of presenting it. Reset at the start of each flush
    /// cycle, same as flush_aborted.
    flush_atlas_corrupted: bool = false,

    init_rows: u32 = 24,
    init_cols: u32 = 80,

    // Synchronization for delaying nvim_ui_attach until actual layout is known.
    // The RPC thread waits on ui_attach_cond before sending nvim_ui_attach.
    // Call notifyLayoutReady() from the UI thread after renderer init.
    ui_attach_mutex: std.Io.Mutex = .init,
    ui_attach_cond: std.Io.Condition = .init,
    ui_attach_ready: bool = false,
    ui_attach_rows: u32 = 0,
    ui_attach_cols: u32 = 0,

    last_layout_rows: u32 = 0,
    last_layout_cols: u32 = 0,
    // Serializes ui_attached publication and deferred focus/resize state.
    // Lock order when both are needed:
    // pending_resize_mu -> write_queue_mu.
    pending_resize_mu: std.Io.Mutex = .init,
    pending_resize_rows: u32 = 0,
    pending_resize_cols: u32 = 0,
    pending_resize_valid: bool = false,
    pending_resize_sequence: u64 = 0,
    pending_ui_state_sequence: u64 = 0,
    // Latest layout requested by the frontend, retained even after a resize
    // was successfully enqueued. A reconnect may discard the old session's
    // writer queue, so resetSessionState seeds the new attach from this value.
    desired_resize_rows: u32 = 0,
    desired_resize_cols: u32 = 0,
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
    // Cumulative (never reset per-flush, unlike the counters above) count of
    // atlas-full resets specifically -- i.e. packAndUploadBitmap's shelf
    // packer running out of room mid-flush, as opposed to a reset caused by
    // font/scale change. Incremented unconditionally (cheap integer add) so
    // it's accurate even if logging is later enabled after resets already
    // happened; only emitting it in the [perf] atlas line is log-gated.
    perf_atlas_full_reset_count: u64 = 0,
    // Runs whose shaping degraded to the per-scalar fallback (no shape callback,
    // callback failure, or an oversized cluster). A frontend shaper regression
    // silently drops every non-ASCII run onto that path, so it needs a signal.
    // Incremented unconditionally; only its [perf] line is log-gated.
    perf_shape_fallback_runs: u64 = 0,
    // Bumped by EVERY resetCoreAtlas() call, regardless of why (packer-full
    // during packAndUploadBitmap, explicit zonvie_core_invalidate_glyph_cache,
    // onGuifont, DPI/backing-scale change). perf_atlas_full_reset_count only
    // covers the packer-full case — callers that need to detect "did the
    // atlas get reset at all" (e.g. runMsgGridScrollFlush's abort check) must
    // use this instead, or they silently miss the other reset paths.
    atlas_reset_seq: u64 = 0,

    // Cumulative contention stats for the 5 grid_mu tryLock conversions on
    // the input path (mode/cursor-visible, cursor position, msg timeout,
    // note_input_trace, cursor blink). Atomic: these are updated from the
    // UI thread, including on the busy branch where grid_mu itself is NOT
    // held, so an unsynchronized field would race against the core thread's
    // periodic log read below. Read via .load(.monotonic) when emitting the
    // log line; never reset, so the log shows contention rate since app start.
    perf_lock_mode_state: LockContentionStat = .{},
    perf_lock_cursor_pos: LockContentionStat = .{},
    perf_lock_msg_timeout: LockContentionStat = .{},
    perf_lock_input_trace: LockContentionStat = .{},
    perf_lock_cursor_blink: LockContentionStat = .{},
    perf_lock_viewport: LockContentionStat = .{},
    perf_lock_layout: LockContentionStat = .{},
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
    // Allocation/render failures are retried by the frontend timer. Keep a
    // separate deadline so an already-expired throttle does not spin a full
    // flush at 0-1ms intervals under memory pressure.
    msg_show_retry_at: ?i128 = null,
    msg_show_retry_delay_ns: i128 = 16 * std.time.ns_per_ms,
    msg_history_retry_at: ?i128 = null,
    msg_history_retry_delay_ns: i128 = 16 * std.time.ns_per_ms,

    // Scratch buffer for split-view content. Persistent so repeated `:messages`
    // / `:history` dumps reuse capacity instead of reallocating, and so content
    // is never truncated to fit a fixed stack buffer.
    msg_split_buf: std.ArrayListUnmanaged(u8) = .empty,

    // Per-view lifecycle, one ViewSet per message channel (msg_show and
    // msg_history_show — each has its own grid and auto-hide slot). Routing
    // runs once per cycle and the result lives here; every consumer reads the
    // assignment instead of re-routing. See msg_view.zig.
    msg_views: msg_view.ViewSet = .{},
    history_views: msg_view.ViewSet = .{},

    // Auto-hide deadlines for ext_float grids (nanos timestamp)
    msg_show_auto_hide_at: ?i128 = null, // grid -102 auto-hide deadline
    msg_history_auto_hide_at: ?i128 = null, // grid -103 auto-hide deadline

    // Scroll state for msg_show ext-float (Zonvie's own grid)
    msg_scroll_offset: u32 = 0, // Current scroll offset (lines from top)
    msg_total_lines: u32 = 0, // Total line count in current message content
    msg_cached_max_width: u32 = 0, // Cached max line width for grid sizing
    msg_scroll_pending: bool = false, // Pending scroll update (for throttling)
    msg_scroll_last_send: i128 = 0, // Last vertex send time (nanos)
    // Allocation-free latency samples for the full message-scroll
    // transaction (core regeneration + all frontend flush callbacks).
    msg_scroll_perf_us: [256]u32 = .{0} ** 256,
    msg_scroll_perf_count: u16 = 0,
    msg_scroll_perf_aborted: u16 = 0,

    // Cached line data for msg_show scrolling (avoids re-parsing on every scroll)
    msg_line_cache: std.ArrayListUnmanaged(MsgCachedLine) = .empty,
    msg_line_cache_build: std.ArrayListUnmanaged(MsgCachedLine) = .empty,
    msg_cache_valid: bool = false,

    // Track last executed command. Recorded but not yet consumed: the
    // split-view label it was collected for was never wired up.
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
    // Default sized for a full screen of distinct non-ASCII glyphs: a
    // 53x196 viewport of CJK holds ~5,200, and the 2-way probe needs the
    // table to stay well under half full to keep them. At 512 the working
    // set could not fit at all, so every regeneration re-rasterized the
    // whole screen. ~1.8MB across this and the same-sized by-ID table.
    glyph_cache_non_ascii_size: u32 = 16384,

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
    shaping_scalars: std.ArrayListUnmanaged(u32) = .empty,
    shaping_col_widths: std.ArrayListUnmanaged(u32) = .empty,
    /// Maps each shaping_scalars entry back to its composited column index.
    shaping_src_cols: std.ArrayListUnmanaged(u32) = .empty,

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
    // At the maximum texture size, permit one same-size repack for a fresh
    // capacity observation or an armed delayed recovery. A second full
    // condition in the same transaction is negative-cached to converge.
    atlas_full_resets_this_flush: u8 = 0,
    // A blank GlyphEntry was cached because the maximum-size atlas could not
    // hold it. While that capacity-negative episode is pending, new glyph
    // misses must remain stable until its scheduled recovery deadline. Do not
    // reset eagerly from coarse content revisions: cursor movement, color-only
    // edits, and scrolls would otherwise recreate a maximum atlas every frame.
    atlas_has_capacity_negative: bool = false,
    atlas_negative_retry_grid_rev: u64 = 0,
    atlas_negative_retry_style_rev: u64 = 0,
    atlas_negative_retry_at: ?i128 = null,
    atlas_negative_retry_delay_ns: i128 = 250 * std.time.ns_per_ms,
    atlas_negative_recovery_armed: bool = false,
    // Rasterizer callback failures are independent from atlas capacity. They
    // receive a bounded sequence of idle retries so a temporarily busy
    // frontend recovers, while a permanently unsupported glyph converges.
    transient_glyph_has_negative: bool = false,
    transient_glyph_retry_grid_rev: u64 = 0,
    transient_glyph_retry_style_rev: u64 = 0,
    transient_glyph_retry_at: ?i128 = null,
    transient_glyph_retry_delay_ns: i128 = TRANSIENT_GLYPH_RETRY_INITIAL_NS,
    // Starting delay for the NEXT episode. Persists across episodes and grows
    // when one exhausts its attempts, so a permanently unrasterizable glyph
    // cannot be re-probed at the minimum delay forever. Only a genuine success
    // (finishTransientGlyphRetry) returns it to the initial value.
    transient_glyph_episode_delay_ns: i128 = TRANSIENT_GLYPH_RETRY_INITIAL_NS,
    transient_glyph_retry_attempts: u8 = 0,
    transient_glyph_recovery_armed: bool = false,

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

    // Rows one wheel event scrolls: the 'ver' component of Neovim's
    // 'mousescroll'. Seeded with Neovim's own default so the value is usable
    // before the reporter's first notification lands. Updated via RPC
    // notification "zonvie_mousescroll" (see setupMouseScrollReporter); read
    // from the frontend UI thread on every precise scroll event, hence atomic.
    // 'ver:0' disables mouse scrolling in Neovim and reports 0, which the
    // frontend treats as "no row count to reason with".
    mousescroll_ver: std.atomic.Value(u32) = std.atomic.Value(u32).init(3),

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
    glow_group_names: std.ArrayListUnmanaged([]const u8) = .empty,
    // Atomic msgid for tracking pending glow config RPC request (0 = no pending)
    glow_request_msgid: std.atomic.Value(i64) = std.atomic.Value(i64).init(0),
    // Startup retry counter: decremented on nil response, not on each flush.
    // Needs enough retries for -c commands to execute after Neovim startup.
    glow_startup_retries: u8 = 30,

    pub fn getGlowIntensity(self: *const Core) f32 {
        return @bitCast(self.glow_intensity_bits.load(.acquire));
    }

    pub fn isHardRenderFailure(reason: anyerror) bool {
        return switch (reason) {
            error.GridTooLarge,
            error.TooManySubgrids,
            error.TooManyWindowPlacements,
            error.LayoutTooComplex,
            error.VertexBudgetExceeded,
            error.MessageTooLarge,
            error.FrameTooLarge,
            => true,
            else => false,
        };
    }

    /// Record a fixed rendering/resource violation from any flush driver.
    /// The RPC loop observes redraw_recovery_failed and terminates this UI
    /// session instead of retrying state that cannot fit the configured cap.
    pub fn failHardRender(self: *Core, reason: anyerror) void {
        self.log.write("render hard failure: {any}\n", .{reason});
        self.redraw_recovery_failed.store(true, .seq_cst);
        self.ui_attached.store(false, .seq_cst);
    }

    /// Wake a FrameReader blocked after an asynchronous frontend hard failure
    /// without setting stop_flag. The RPC loop must retain ownership of normal
    /// session cleanup and on_exit delivery.
    pub fn wakeRpcReaderForHardFailure(self: *Core) void {
        // Spawn transport: terminating the peer closes its stdout pipe, which
        // is the only portable way to wake a concurrent blocking pipe read.
        self.requestChildTermination();

        // Connect transport: no child owns the peer endpoint, so cancel the
        // local blocking read directly. Keep the Stream published for the RPC
        // thread's cleanup; shutdown/CancelIoEx do not transfer ownership.
        self.stdin_close_mu.lockUncancelable(clock.io());
        defer self.stdin_close_mu.unlock(clock.io());
        if (self.transport_kind != .socket) return;
        if (self.stdin_file) |stream| {
            stream.shutdownIfSocket(true) catch |e| self.log.write(
                "hard-failure wake: socket shutdown failed: {any} (RPC reader stays blocked)\n",
                .{e},
            );
            switch (stream) {
                .win_pipe => stream.close(),
                .file => {},
            }
        }
    }

    pub fn setGlowIntensity(self: *Core, val: f32) void {
        self.glow_intensity_bits.store(@bitCast(val), .release);
    }

    pub fn init(alloc: std.mem.Allocator, cb: Callbacks, ctx: ?*anyopaque) Core {
        var grid = Grid.init(alloc);
        grid.setRowIndexBudgetEnabled(cb.on_vertices_row != null);
        return .{
            .alloc = alloc,
            .cb = cb,
            .ctx = ctx,
            .log = .{ .cb = cb.on_log, .ctx = ctx },
            .grid = grid,
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
        self.flush_dirty_snapshot.deinit(self.alloc);
        self.flush_row_counts_snapshot.deinit(self.alloc);
        for (&self.partial_layer_verts) |*layer| layer.deinit(self.alloc);
        for (self.scroll_cache.items) |*row_cache| {
            row_cache.deinit(self.alloc);
        }
        self.scroll_cache.deinit(self.alloc);
        for (&self.retained_shadow) |*shadow| shadow.deinit(self.alloc);
        self.scroll_cache_valid.deinit(self.alloc);
        self.main_vertex_row_counts.deinit(self.alloc);
        self.tmp_cells.deinit(self.alloc);
        self.row_cells.deinit(self.alloc);
        self.grid_entries.deinit(self.alloc);
        self.ext_float_entries.deinit(self.alloc);
        self.ext_float_anchor_entries.deinit(self.alloc);
        self.ext_float_row_offsets.deinit(self.alloc);
        self.ext_float_row_write_offsets.deinit(self.alloc);
        self.ext_float_row_entry_indices.deinit(self.alloc);
        self.cached_subgrids_buf.deinit(self.alloc);
        self.main_subgrid_row_offsets.deinit(self.alloc);
        self.main_subgrid_row_write_offsets.deinit(self.alloc);
        self.main_subgrid_row_indices.deinit(self.alloc);
        self.main_subgrid_row_layout.deinit(self.alloc);
        self.prev_subgrid_snapshots.deinit(self.alloc);
        self.subgrid_diff_current.deinit(self.alloc);
        self.subgrid_diff_row_marks.deinit(self.alloc);
        self.key_buf.deinit(self.alloc);
        self.write_queue.deinit(self.alloc);
        self.write_spare_queue.deinit(self.alloc);
        self.shaping_bufs.deinit(self.alloc);
        self.shaping_scalars.deinit(self.alloc);
        self.shaping_col_widths.deinit(self.alloc);
        self.shaping_src_cols.deinit(self.alloc);
        self.flush_float_overlay_buf.deinit(self.alloc);
        self.msg_views.deinit(self.alloc);
        self.history_views.deinit(self.alloc);
        self.msg_line_cache.deinit(self.alloc);
        self.msg_line_cache_build.deinit(self.alloc);
        self.msg_split_buf.deinit(self.alloc);
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
    ///     by getVisibleGridsSnapshotLocked (hit-testing).
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
        self.resetProtocolState(true);
    }

    /// Reset a poisoned redraw attachment without touching the live RPC
    /// transport or writer queue. Called only after nvim_ui_detach has replied,
    /// so no event from the old UI epoch can race this reset.
    pub fn resetRedrawProtocolState(self: *Core) void {
        self.resetProtocolState(false);
    }

    fn resetProtocolState(self: *Core, reset_transport: bool) void {
        // UI attachment must be re-issued after reconnect.
        self.pending_resize_mu.lockUncancelable(clock.io());
        self.ui_attached.store(false, .seq_cst);
        const desired_rows = if (self.desired_resize_rows != 0)
            self.desired_resize_rows
        else
            self.last_layout_rows;
        const desired_cols = if (self.desired_resize_cols != 0)
            self.desired_resize_cols
        else
            self.last_layout_cols;
        if (desired_rows != 0 and desired_cols != 0) {
            self.pending_resize_rows = desired_rows;
            self.pending_resize_cols = desired_cols;
            self.pending_resize_valid = true;
            self.pending_resize_sequence = self.nextPendingUiStateSequenceLocked();
        }
        if (reset_transport) {
            self.pending_focus.store(0, .seq_cst);
            self.pending_focus_sequence = 0;
        }
        self.pending_resize_mu.unlock(clock.io());

        // Preedit highlight groups and namespace live in the dead session;
        // re-define them and re-place the extmark on the next composition.
        self.preedit_setup_done.store(false, .monotonic);
        self.preedit_visible.store(false, .monotonic);

        if (reset_transport) {
            // Channel-bound state.
            self.clipboard_setup_done = false;
            self.redraw_recovery_state = .healthy;
            self.redraw_recovery_msgid = 0;
            self.redraw_recovery_failed.store(false, .seq_cst);
            self.redraw_recovery_attach_rows = 0;
            self.redraw_recovery_attach_cols = 0;
            self.redraw_recovery_attempts = 0;

            // In-flight RPC IDs from the dead channel — drop tracking so any
            // stale response from the new server cannot match.
            self.get_api_info_msgid = null;
            self.quit_request_msgid.store(0, .release);
            self.glow_request_msgid.store(0, .release);

            self.glow_startup_retries = 30;
            self.ssh_auth_pending.store(false, .seq_cst);
            self.ssh_auth_done.store(false, .seq_cst);

            // Transport handles are already closed by cleanupSession.
            self.stdin_close_mu.lockUncancelable(clock.io());
            self.transport_kind = .pipes;
            self.stdin_close_mu.unlock(clock.io());

            // Re-arm the writer queue for the next session.
            self.write_queue_mu.lockUncancelable(clock.io());
            self.write_queue_closed = false;
            self.writer_failed = false;
            self.write_queue.clearRetainingCapacity();
            self.write_spare_queue.clearRetainingCapacity();
            self.write_queue_normal_bytes = 0;
            self.write_queue_ui_state_bytes = 0;
            self.write_queue_mu.unlock(clock.io());
        }

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
        self.grid_mu.lockUncancelable(clock.io());
        defer self.grid_mu.unlock(clock.io());

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
            self.log.write("resetSessionState: closed {d} external windows from previous session\n", .{closed_count});
        }
        self.known_external_grids.deinit(self.alloc);
        self.known_external_grids = .{};
        self.grid.external_grids.deinit(self.alloc);
        self.grid.external_grids = .{};
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
        self.grid.pending_main_grid_size = null;

        // Composited / multigrid layout, ext UI overlays, cursor state.
        // See doc comment on this function for the full rationale.
        self.grid.resetForNewSession();
        self.hl.reset();

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
        self.main_surface_vertex_count = 0;
        self.main_vertex_row_ledger_valid = false;
        self.flush_vertex_count_aggregate = 0;
        self.vertex_budget_transaction_active = false;
        self.vertex_budget_main_touched = false;
        self.vertex_budget_touched_grid_head = null;
        self.popupmenu_win_id = null;
        self.popupmenu_buf_id = null;

        // ext_messages timing / scroll state was tied to the old session's
        // msg_show events; carrying it across would auto-hide the new
        // session's first message at the old deadline.
        self.msg_show_pending_since = null;
        self.msg_show_retry_at = null;
        self.msg_history_retry_at = null;
        self.msg_history_retry_delay_ns = 16 * std.time.ns_per_ms;
        self.msg_show_retry_delay_ns = 16 * std.time.ns_per_ms;
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
        self.msg_line_cache_build.clearRetainingCapacity();
        self.resetAtlasMaintenanceBackoff();

        // Last command tracking was a snapshot of the old session's
        // :commands.
        self.last_cmd_len = 0;
        self.last_cmd_firstc = 0;
        self.last_cmd_start_time = null;

        // Subgrid layout snapshot for scroll fast path: stale entries
        // would reference grid_ids the new session has not (yet) created.
        self.prev_subgrid_snapshots.clearRetainingCapacity();

        // The row buckets describe the previous session's placement maps.
        // Release their hostile-input high-water capacity together with the
        // placement maps and force the first new-session row flush to rebuild.
        self.main_subgrid_row_offsets.deinit(self.alloc);
        self.main_subgrid_row_offsets = .empty;
        self.main_subgrid_row_write_offsets.deinit(self.alloc);
        self.main_subgrid_row_write_offsets = .empty;
        self.main_subgrid_row_indices.deinit(self.alloc);
        self.main_subgrid_row_indices = .empty;
        self.main_subgrid_row_layout.deinit(self.alloc);
        self.main_subgrid_row_layout = .empty;
        self.main_subgrid_row_index_rows = 0;
        self.main_subgrid_row_index_valid = false;
        self.main_subgrid_row_index_generation = 0;
        self.main_subgrid_row_index_cached_len = 0;

        // External-float scratch is bounded during a session, but a hostile
        // previous peer may have driven it to that high-water mark. Session
        // changes are cold paths, so release rather than retain these buffers.
        self.ext_float_anchor_entries.deinit(self.alloc);
        self.ext_float_anchor_entries = .empty;
        self.ext_float_entries.deinit(self.alloc);
        self.ext_float_entries = .empty;
        self.ext_float_row_offsets.deinit(self.alloc);
        self.ext_float_row_offsets = .empty;
        self.ext_float_row_write_offsets.deinit(self.alloc);
        self.ext_float_row_write_offsets = .empty;
        self.ext_float_row_entry_indices.deinit(self.alloc);
        self.ext_float_row_entry_indices = .empty;
        self.ext_float_anchor_index_valid = false;
        self.ext_float_row_index_valid = false;
        self.ext_float_index_generation +%= 1;

        self.log.write("resetProtocolState: cleared UI protocol state (transport_reset={any})\n", .{reset_transport});
    }

    /// Signal the RPC thread that the actual layout is known and nvim_ui_attach
    /// can be sent with the correct dimensions. Must be called from the UI
    /// thread after the renderer is initialized and actual rows/cols are computed.
    /// Idempotent: subsequent calls after the first are no-ops.
    pub fn notifyLayoutReady(self: *Core, rows: u32, cols: u32) void {
        self.ui_attach_mutex.lockUncancelable(clock.io());
        defer self.ui_attach_mutex.unlock(clock.io());
        if (self.ui_attach_ready) return;
        self.pending_resize_mu.lockUncancelable(clock.io());
        self.desired_resize_rows = rows;
        self.desired_resize_cols = cols;
        self.pending_resize_mu.unlock(clock.io());
        self.ui_attach_rows = rows;
        self.ui_attach_cols = cols;
        // Pre-set last_layout to suppress a redundant resize after attach.
        self.last_layout_rows = rows;
        self.last_layout_cols = cols;
        self.ui_attach_ready = true;
        self.ui_attach_cond.signal(clock.io());
        self.log.write("notifyLayoutReady: rows={d} cols={d}\n", .{ rows, cols });
    }

    /// True when synchronous teardown would either join the caller itself or
    /// wait for an RPC thread which is blocked in a callback on the caller.
    pub fn isCurrentThreadUnsafeForTeardown(self: *const Core) bool {
        const current_tid: usize = @intCast(std.Thread.getCurrentId());
        return log_mod.isInCallback() or
            self.rpc_thread_id.load(.acquire) == current_tid or
            self.redraw_thread_id.load(.acquire) == current_tid;
    }

    pub fn stop(self: *Core) void {
        // A callback running on the RPC/redraw thread cannot synchronously
        // join its own stack. Request shutdown but leave teardown unclaimed so
        // a later safe-thread stop/destroy can own it synchronously.
        if (self.isCurrentThreadUnsafeForTeardown()) {
            self.requestStopWithoutJoining();
            return;
        }

        // Claim teardown ownership.  A concurrent/re-entrant caller must not
        // wait here: the owner may be joining a thread whose callback made the
        // re-entrant call.  zonvie_core_destroy uses waitUntilStopped() after
        // this returns so it still cannot release CoreBox/GPA early.
        if (self.stop_state.cmpxchgStrong(0, 1, .acq_rel, .acquire) != null) return;
        self.stopTeardownOwned();
    }

    /// Best-effort, idempotent shutdown request for callback-thread stop.
    /// It intentionally does not wait for a mutex: a callback can originate
    /// while the lifecycle owner holds that mutex and joins this callback's
    /// worker. Raw resources remain owned until lifecycle-thread teardown.
    fn requestStopWithoutJoining(self: *Core) void {
        self.stop_flag.store(true, .seq_cst);

        // std.Io.Condition is atomic and permits signaling without its
        // associated mutex. The waiter rechecks stop_flag after every wake.
        self.ui_attach_cond.broadcast(clock.io());
        self.write_queue_cond.broadcast(clock.io());

        // A writer blocked on a POSIX/Windows spawn pipe owns a copy of the
        // raw descriptor/HANDLE. Terminate the peer first; never close that
        // raw resource until a lifecycle-thread teardown has joined writer.
        // A socket session has no published child, so this is a cheap no-op.
        // Avoid reading transport_kind outside stdin_close_mu while the RPC
        // thread may still be publishing a freshly-created transport.
        self.tryRequestChildTermination();

        // Do not wait behind cleanup/teardown: that owner may be joining the
        // worker currently executing this callback. If the locks are free,
        // publish queue closure and cancel socket I/O immediately. Otherwise
        // the lock owner is already transitioning the same resources.
        if (self.write_queue_mu.tryLock()) {
            self.write_queue_closed = true;
            self.write_queue_cond.broadcast(clock.io());
            self.write_queue_mu.unlock(clock.io());
        }
        if (self.stdin_close_mu.tryLock()) {
            if (self.stdin_file) |f| {
                if (self.transport_kind == .socket) {
                    f.shutdownIfSocket(true) catch |e| self.log.write(
                        "stop: socket shutdown failed: {any} (reader stays blocked)\n",
                        .{e},
                    );
                    switch (f) {
                        .win_pipe => f.close(), // CancelIoEx; no HANDLE close.
                        .file => {},
                    }
                }
            }
            self.stdin_close_mu.unlock(clock.io());
        }
    }

    /// Ask the spawned child to terminate without waiting or releasing its
    /// process handle. Safe to call before taking stdin_close_mu so it can wake
    /// another teardown owner which is joining a pipe-blocked writer.
    pub fn requestChildTermination(self: *Core) void {
        self.child_handle_mu.lockUncancelable(clock.io());
        defer self.child_handle_mu.unlock(clock.io());
        self.signalPublishedChildLocked();
    }

    fn tryRequestChildTermination(self: *Core) void {
        if (!self.child_handle_mu.tryLock()) return;
        defer self.child_handle_mu.unlock(clock.io());
        self.signalPublishedChildLocked();
    }

    fn signalPublishedChildLocked(self: *Core) void {
        if (self.child_handle) |child_id| {
            if (comptime @import("builtin").os.tag == .windows) {
                _ = std.os.windows.ntdll.NtTerminateProcess(child_id, @enumFromInt(1));
            } else {
                const pid: std.posix.pid_t = @intCast(child_id);
                _ = std.posix.kill(pid, std.posix.SIG.TERM) catch {};
            }
        }
    }

    /// Publish a newly spawned child for cancellation by stop().
    pub fn publishChildHandle(self: *Core, child_id: ?std.process.Child.Id) void {
        self.child_handle_mu.lockUncancelable(clock.io());
        defer self.child_handle_mu.unlock(clock.io());
        self.child_handle = child_id;
    }

    /// Withdraw the shared cancellation handle before Child.kill()/wait()
    /// reaps the PID or closes the Windows process HANDLE.
    pub fn claimChildHandleForCleanup(self: *Core) void {
        self.child_handle_mu.lockUncancelable(clock.io());
        defer self.child_handle_mu.unlock(clock.io());
        self.child_handle = null;
    }

    fn stopTeardownOwned(self: *Core) void {
        defer self.stop_state.store(2, .release);

        self.stop_flag.store(true, .seq_cst);

        // Unblock RPC thread if it is waiting on ui_attach_cond
        {
            self.ui_attach_mutex.lockUncancelable(clock.io());
            defer self.ui_attach_mutex.unlock(clock.io());
            self.ui_attach_ready = true;
            self.ui_attach_cond.signal(clock.io());
        }

        // A pipe writer owns a by-value copy of the raw fd/HANDLE. Closing the
        // Core's copy before join permits fd reuse while that thread is still
        // inside writeAll(). A published child always belongs to a pipe
        // session, so signal it without racing on transport_kind before
        // waiting for transport ownership.
        self.requestChildTermination();

        self.stdin_close_mu.lockUncancelable(clock.io());
        const transport_kind = self.transport_kind;
        // Close the narrow publication race where the RPC thread published a
        // child after the first signal but before we acquired stdin_close_mu.
        // This must precede writer join because that writer may be blocked in
        // the freshly-published child's pipe.
        self.requestChildTermination();
        var wt: ?std.Thread = null;
        self.write_queue_mu.lockUncancelable(clock.io());
        self.write_queue_closed = true;
        wt = self.writer_thread;
        self.writer_thread = null;
        self.write_queue_cond.signal(clock.io());
        self.write_queue_mu.unlock(clock.io());

        const stdin = self.stdin_file;
        const defer_posix_socket_close = if (stdin) |f|
            transport_kind == .socket and switch (f) {
                .file => true,
                .win_pipe => false,
            }
        else
            false;
        self.cancelWriterIo(wt, stdin, transport_kind);
        if (!defer_posix_socket_close) {
            if (stdin) |f| f.close();
            self.stdin_file = null;
            if (transport_kind == .socket) self.stdout_file = null;
        }
        self.stdin_close_mu.unlock(clock.io());

        if (self.thread) |t| t.join();
        self.thread = null;

        // The POSIX socket fd is also held by the RPC reader. shutdown above
        // wakes it, but raw close waits until that thread is joined so its
        // by-value Stream can never observe a recycled descriptor. Normally
        // cleanupSession already performed this close on the RPC thread.
        if (defer_posix_socket_close) {
            self.stdin_close_mu.lockUncancelable(clock.io());
            if (self.stdin_file) |f| f.close();
            self.stdin_file = null;
            self.stdout_file = null;
            self.stdin_close_mu.unlock(clock.io());
        }

        // Defensive: if a stderr pump is still pointing at Core (e.g., a
        // failure path bypassed cleanupSession), detach it now so its
        // run() loop stops dereferencing Core before we free Core's
        // storage below, then release Core's ref so the struct can be
        // freed when the pump thread releases its own. Normal flows
        // have cleanupSession already null both fields by this point.
        if (self.stderr_pump) |p| {
            p.finishCleanupDecision();
            p.detachFromCore();
            p.release();
            self.stderr_pump = null;
        }
        if (self.stderr_thread) |t2| t2.join();
        self.stderr_thread = null;

        if (self.child_reaper) |reaper| reaper.finishWithoutChild();
        if (self.child_reaper_thread) |reaper_thread| reaper_thread.join();
        self.child_reaper_thread = null;
        if (self.child_reaper) |reaper| reaper.release();
        self.child_reaper = null;

        if (self.stdout_file) |f| f.close();
        if (self.stderr_file) |f| f.close();
        self.stdout_file = null;
        self.stderr_file = null;

        self.claimChildHandleForCleanup();

        // Frontend retry workers serialize with grid mutation through this
        // mutex. Threads which can originate callbacks have already joined,
        // so taking it here cannot invert the RPC/grid lock order. stop_flag
        // was published before the joins, making late retries no-op before
        // they can observe the resources released below.
        self.grid_mu.lockUncancelable(clock.io());
        defer self.grid_mu.unlock(clock.io());

        self.hl.deinit();
        self.grid.deinit();

        // Clean up scratch buffers
        self.main_verts.deinit(self.alloc);
        self.cursor_verts.deinit(self.alloc);
        self.row_verts.deinit(self.alloc);
        self.flush_dirty_snapshot.deinit(self.alloc);
        self.flush_row_counts_snapshot.deinit(self.alloc);
        for (&self.partial_layer_verts) |*layer| layer.deinit(self.alloc);
        for (self.scroll_cache.items) |*row_cache| {
            row_cache.deinit(self.alloc);
        }
        self.scroll_cache.deinit(self.alloc);
        for (&self.retained_shadow) |*shadow| shadow.deinit(self.alloc);
        self.scroll_cache_valid.deinit(self.alloc);
        self.main_vertex_row_counts.deinit(self.alloc);
        self.tmp_cells.deinit(self.alloc);
        self.row_cells.deinit(self.alloc);
        self.grid_entries.deinit(self.alloc);
        self.ext_float_entries.deinit(self.alloc);
        self.ext_float_anchor_entries.deinit(self.alloc);
        self.ext_float_row_offsets.deinit(self.alloc);
        self.ext_float_row_write_offsets.deinit(self.alloc);
        self.ext_float_row_entry_indices.deinit(self.alloc);
        self.cached_subgrids_buf.deinit(self.alloc);
        self.main_subgrid_row_offsets.deinit(self.alloc);
        self.main_subgrid_row_write_offsets.deinit(self.alloc);
        self.main_subgrid_row_indices.deinit(self.alloc);
        self.main_subgrid_row_layout.deinit(self.alloc);
        self.prev_subgrid_snapshots.deinit(self.alloc);
        self.subgrid_diff_current.deinit(self.alloc);
        self.subgrid_diff_row_marks.deinit(self.alloc);
        self.key_buf.deinit(self.alloc);
        self.write_queue.deinit(self.alloc);
        self.write_spare_queue.deinit(self.alloc);

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
        self.msg_line_cache = .empty;
        self.msg_line_cache_build.deinit(self.alloc);
        self.msg_line_cache_build = .empty;
        self.msg_split_buf.deinit(self.alloc);
        self.msg_split_buf = .empty;
        // Full reset, not just deinit: ViewSet.deinit frees the assignment
        // but keeps per-view state, and a stale `visible` flag would make the
        // next session's first empty cycle issue a spurious hide.
        self.msg_views.deinit(self.alloc);
        self.msg_views = .{};
        self.history_views.deinit(self.alloc);
        self.history_views = .{};
        self.msg_config.deinit();
        self.msg_config = .{};

        // Free caches
        self.deinitHlCache();
        self.deinitGlyphCache();
    }

    /// Wait until the single stop() owner has released every Core-owned
    /// allocation.  Only destruction needs this synchronization; ordinary
    /// duplicate stop calls remain non-blocking to avoid callback/join cycles.
    pub fn waitUntilStopped(self: *Core) bool {
        if (self.isCurrentThreadUnsafeForTeardown()) return false;
        while (true) {
            switch (self.stop_state.load(.acquire)) {
                2 => return true,
                else => {},
            }
            std.Io.sleep(clock.io(), .{ .nanoseconds = std.time.ns_per_ms }, .awake) catch {};
        }
    }

    /// Ensure scroll_cache has exactly `target_rows` entries.
    /// Grows or shrinks the per-row vertex lists as needed.
    pub fn ensureScrollCache(self: *Core, target_rows: u32) !void {
        const cur = self.scroll_cache_rows;
        if (cur == target_rows and
            self.scroll_cache.items.len == target_rows and
            self.main_vertex_row_counts.items.len == target_rows) return;

        // Shrink: deinit excess row buffers
        if (self.scroll_cache.items.len > target_rows) {
            for (self.scroll_cache.items[target_rows..]) |*row_buf| {
                row_buf.deinit(self.alloc);
            }
            self.scroll_cache.items.len = target_rows;
        }

        // Grow: append empty row buffers
        while (self.scroll_cache.items.len < target_rows) {
            try self.scroll_cache.append(self.alloc, .empty);
        }

        const old_count_len = self.main_vertex_row_counts.items.len;
        try self.main_vertex_row_counts.ensureTotalCapacity(self.alloc, target_rows);
        self.main_vertex_row_counts.items.len = target_rows;
        if (target_rows > old_count_len) {
            @memset(self.main_vertex_row_counts.items[old_count_len..], 0);
        } else if (target_rows < old_count_len and self.main_vertex_row_ledger_valid) {
            // resize() has already shortened the slice; recompute only on a
            // structural shrink, never on the per-row hot path.
            const old_surface_vertex_count = self.main_surface_vertex_count;
            self.main_surface_vertex_count = 0;
            for (self.main_vertex_row_counts.items) |count| {
                self.main_surface_vertex_count +|= count;
            }
            self.flush_vertex_count_aggregate -|=
                old_surface_vertex_count -| self.main_surface_vertex_count;
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
        self.main_vertex_row_counts.clearRetainingCapacity();
        self.flush_vertex_count_aggregate -|= self.main_surface_vertex_count;
        self.main_surface_vertex_count = 0;
        self.main_vertex_row_ledger_valid = true;

        // Reset subgrid snapshot so the next flush treats all subgrids as new.
        self.prev_subgrid_snapshots.clearRetainingCapacity();
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

        // Partial failure must not leak: the row-mode flush retries this on
        // EVERY flush with the error swallowed, and each retry's `try alloc`
        // would overwrite the still-live pointers from the previous partial
        // attempt — unbounded growth exactly when memory is already scarce.
        // deinitGlyphCache frees-and-nulls every field, so it is a safe
        // rollback for any prefix of the allocations below.
        errdefer self.deinitGlyphCache();

        const ascii_size = self.glyph_cache_ascii_size;
        const non_ascii_size = self.glyph_cache_non_ascii_size;

        self.glyph_cache_ascii = try self.alloc.alloc(c_api.GlyphEntry, ascii_size);
        self.glyph_valid_ascii = try self.alloc.alloc(bool, ascii_size);
        self.glyph_cache_non_ascii = try self.alloc.alloc(c_api.GlyphEntry, non_ascii_size);
        self.glyph_keys_non_ascii = try self.alloc.alloc(u64, non_ascii_size);

        // Initialize valid flags to false
        @memset(self.glyph_valid_ascii.?, false);
        // Initialize keys to invalid sentinel
        const INVALID_KEY = GLYPH_CACHE_INVALID_KEY;
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
        if (self.flush_aborted) return false;
        if (self.ascii_tables_valid) return true;
        const cb = self.cb.on_get_ascii_table orelse return false;

        const log_active = self.log.cb != null;
        const t0: i128 = if (log_active) clock.nowNs() else 0;

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
            if (self.flush_aborted) {
                all_ok = false;
                break;
            }
        }

        const t1: i128 = if (log_active) clock.nowNs() else 0;

        if (all_ok) {
            all_ok = self.preRasterizeAscii();
        }
        self.ascii_tables_valid = all_ok;

        if (log_active) {
            const t2 = clock.nowNs();
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

    fn recordAtlasCapacityNegative(self: *Core) void {
        if (!self.atlas_has_capacity_negative) {
            if (self.atlas_negative_recovery_armed) {
                // The delayed reprobe still could not fit the visible working
                // set. Do not poll an unchanged impossible set; retain a larger
                // delay for the next genuine working-set/style change.
                self.atlas_negative_retry_delay_ns = @min(
                    self.atlas_negative_retry_delay_ns * 2,
                    30 * std.time.ns_per_s,
                );
                self.atlas_negative_recovery_armed = false;
            }
            self.atlas_negative_retry_at = null;
            self.atlas_negative_retry_grid_rev = self.grid.glyph_working_set_rev;
            self.atlas_negative_retry_style_rev = self.hl.glyph_style_rev;
        }
        self.atlas_has_capacity_negative = true;
    }

    fn retryDeadline(now: i128, delay_ns: i128) i128 {
        return std.math.add(i128, now, delay_ns) catch std.math.maxInt(i128);
    }

    fn transientGlyphWorkingSetChanged(self: *const Core) bool {
        return self.transient_glyph_retry_grid_rev != self.grid.glyph_working_set_rev or
            self.transient_glyph_retry_style_rev != self.hl.glyph_style_rev;
    }

    fn resetTransientGlyphRetryBackoff(self: *Core) void {
        self.transient_glyph_has_negative = false;
        self.transient_glyph_retry_at = null;
        self.transient_glyph_retry_delay_ns = TRANSIENT_GLYPH_RETRY_INITIAL_NS;
        self.transient_glyph_episode_delay_ns = TRANSIENT_GLYPH_RETRY_INITIAL_NS;
        self.transient_glyph_retry_attempts = 0;
        self.transient_glyph_recovery_armed = false;
        self.transient_glyph_retry_grid_rev = self.grid.glyph_working_set_rev;
        self.transient_glyph_retry_style_rev = self.hl.glyph_style_rev;
    }

    /// Restart after an exhausted episode. Unlike the full reset above, this
    /// keeps escalating the starting delay. `glyph_working_set_rev` is bumped
    /// by putCell for every changed cell, so "the working set changed" is in
    /// practice "the user typed": restarting at the minimum delay each time
    /// would force a full-screen regeneration (beginNegativeGlyphReprobe
    /// markAllDirty's every grid and blocks the scroll fast path) roughly
    /// every 1.5s for as long as one on-screen codepoint stays unrasterizable.
    ///
    /// Two known residuals, both accepted rather than solved here:
    /// 1. The delay saturates at TRANSIENT_GLYPH_RETRY_MAX_NS (4s), so a
    ///    permanently unrasterizable on-screen codepoint still costs a
    ///    whole-grid invalidation every 4s while the user types. The
    ///    atlas-capacity sibling this otherwise resembles caps at 30s, but
    ///    raising this cap to match would worsen residual 2.
    /// 2. The delay is per-Core, not per-glyph. While one impossible glyph is
    ///    outstanding, a genuinely transient miss on an unrelated glyph
    ///    inherits the escalated delay instead of starting at 250ms, so its
    ///    cell can stay blank for up to 4s. Fixing this properly needs an
    ///    identity for the failing-glyph set; there is no cheap one today
    ///    (the negative entries live scattered across the three glyph caches,
    ///    see invalidateNegativeGlyphCacheEntries).
    fn restartTransientGlyphRetryEpisode(self: *Core, now: i128) void {
        self.transient_glyph_episode_delay_ns = @min(
            self.transient_glyph_episode_delay_ns * 2,
            TRANSIENT_GLYPH_RETRY_MAX_NS,
        );
        self.transient_glyph_recovery_armed = false;
        // startTransientGlyphRetryEpisode sets attempts = 1; no reset needed.
        self.startTransientGlyphRetryEpisode(now);
    }

    fn startTransientGlyphRetryEpisode(self: *Core, now: i128) void {
        self.transient_glyph_has_negative = true;
        self.transient_glyph_retry_grid_rev = self.grid.glyph_working_set_rev;
        self.transient_glyph_retry_style_rev = self.hl.glyph_style_rev;
        self.transient_glyph_retry_delay_ns = self.transient_glyph_episode_delay_ns;
        self.transient_glyph_retry_attempts = 1;
        self.transient_glyph_retry_at = retryDeadline(now, self.transient_glyph_retry_delay_ns);
    }

    /// Record a rasterizer miss that may be transient (for example while the
    /// frontend is temporarily unable to produce the glyph). The callback ABI
    /// reports both unsupported glyphs and temporary busy states as zero, so a
    /// finite exponential sequence recovers the latter without polling the
    /// former forever. Capacity misses have separate state: neither retry
    /// budget can suppress the other.
    pub fn recordTransientGlyphNegativeAt(self: *Core, now: i128) void {
        if (self.transient_glyph_recovery_armed) {
            self.transient_glyph_recovery_armed = false;
            self.transient_glyph_has_negative = true;
            self.transient_glyph_retry_grid_rev = self.grid.glyph_working_set_rev;
            self.transient_glyph_retry_style_rev = self.hl.glyph_style_rev;

            // The fifth delayed reprobe is the bounded final attempt. Leave
            // the blank cached with no timer until a genuinely different
            // working set encounters another rasterizer miss.
            if (self.transient_glyph_retry_attempts >= TRANSIENT_GLYPH_RETRY_MAX_ATTEMPTS) {
                self.transient_glyph_retry_at = null;
                return;
            }

            self.transient_glyph_retry_delay_ns = @min(
                self.transient_glyph_retry_delay_ns * 2,
                TRANSIENT_GLYPH_RETRY_MAX_NS,
            );
            self.transient_glyph_retry_attempts += 1;
            self.transient_glyph_retry_at = retryDeadline(now, self.transient_glyph_retry_delay_ns);
            return;
        }

        if (self.transient_glyph_has_negative) {
            // Before an armed deadline, additional misses belong to the same
            // transaction and must not push it out. After the bounded final
            // failure, only a new working set starts a fresh retry budget --
            // at an escalated starting delay, since the set changes on every
            // edit.
            if (self.transient_glyph_retry_at != null or
                !self.transientGlyphWorkingSetChanged()) return;
            self.restartTransientGlyphRetryEpisode(now);
            return;
        }

        self.startTransientGlyphRetryEpisode(now);
    }

    pub fn recordTransientGlyphNegative(self: *Core) void {
        self.recordTransientGlyphNegativeAt(clock.nowNs());
    }

    fn invalidateNegativeGlyphCacheEntries(self: *Core) void {
        if (self.glyph_cache_ascii) |cache| {
            if (self.glyph_valid_ascii) |valid| {
                const len = @min(cache.len, valid.len);
                for (cache[0..len], valid[0..len]) |entry, *is_valid| {
                    if (is_valid.* and (entry.bbox_size_px[0] <= 0 or entry.bbox_size_px[1] <= 0)) {
                        is_valid.* = false;
                    }
                }
            }
        }
        if (self.glyph_cache_non_ascii) |cache| {
            if (self.glyph_keys_non_ascii) |keys| {
                const len = @min(cache.len, keys.len);
                for (cache[0..len], keys[0..len]) |entry, *key| {
                    if (key.* != GLYPH_CACHE_INVALID_KEY and
                        (entry.bbox_size_px[0] <= 0 or entry.bbox_size_px[1] <= 0))
                    {
                        key.* = GLYPH_CACHE_INVALID_KEY;
                    }
                }
            }
        }
        if (self.glyph_cache_by_id) |cache| {
            if (self.glyph_keys_by_id) |keys| {
                const len = @min(cache.len, keys.len);
                for (cache[0..len], keys[0..len]) |entry, *key| {
                    if (key.* != GLYPH_CACHE_INVALID_KEY and
                        (entry.bbox_size_px[0] <= 0 or entry.bbox_size_px[1] <= 0))
                    {
                        key.* = GLYPH_CACHE_INVALID_KEY;
                    }
                }
            }
        }
    }

    pub fn resetAtlasCapacityRetryBackoff(self: *Core) void {
        self.atlas_has_capacity_negative = false;
        self.atlas_negative_retry_at = null;
        self.atlas_negative_retry_delay_ns = 250 * std.time.ns_per_ms;
        self.atlas_negative_recovery_armed = false;
        self.atlas_negative_retry_grid_rev = self.grid.glyph_working_set_rev;
        self.atlas_negative_retry_style_rev = self.hl.glyph_style_rev;
    }

    pub fn resetAtlasMaintenanceBackoff(self: *Core) void {
        self.resetAtlasCapacityRetryBackoff();
        self.resetTransientGlyphRetryBackoff();
    }

    /// Complete a reprobe after every frontend consumer accepted the flush.
    /// Absence of a renewed capacity-negative means the old missing glyph left
    /// the visible set (or the repack succeeded), so future episodes start at
    /// the minimum delay.
    pub fn finishAtlasCapacityRetry(self: *Core) void {
        if (!self.atlas_negative_recovery_armed or self.atlas_has_capacity_negative) return;
        self.atlas_negative_recovery_armed = false;
        self.atlas_negative_retry_at = null;
        self.atlas_negative_retry_delay_ns = 250 * std.time.ns_per_ms;
    }

    fn finishTransientGlyphRetry(self: *Core) void {
        if (!self.transient_glyph_recovery_armed or self.transient_glyph_has_negative) return;
        self.resetTransientGlyphRetryBackoff();
    }

    pub fn finishAtlasMaintenance(self: *Core) void {
        self.finishAtlasCapacityRetry();
        self.finishTransientGlyphRetry();
    }

    fn beginNegativeGlyphReprobe(self: *Core) void {
        self.invalidateNegativeGlyphCacheEntries();
        self.invalidateScrollCache();
        self.grid.markAllDirty();
        self.grid.scroll_fast_path_blocked = true;
        var sg_it = self.grid.sub_grids.valueIterator();
        while (sg_it.next()) |sg| {
            sg.markAllDirty();
            sg.scroll_fast_path_blocked = true;
        }
        self.grid.cursor_rev +%= 1;
    }

    /// Schedule/execute a selective retry for cached capacity misses. One real
    /// working-set or glyph-style change arms an absolute deadline, allowing the
    /// existing frontend one-shot timer to drive a reprobe even when Neovim is
    /// otherwise idle. An unchanged impossible set has no deadline and therefore
    /// causes no atlas churn.
    fn armAtlasCapacityRetryAt(self: *Core, now: i128) bool {
        if (!self.atlas_has_capacity_negative) {
            return false;
        }

        if (self.atlas_negative_retry_grid_rev != self.grid.glyph_working_set_rev or
            self.atlas_negative_retry_style_rev != self.hl.glyph_style_rev)
        {
            self.atlas_negative_retry_grid_rev = self.grid.glyph_working_set_rev;
            self.atlas_negative_retry_style_rev = self.hl.glyph_style_rev;
            if (self.atlas_negative_retry_at == null) {
                self.atlas_negative_retry_at = retryDeadline(now, self.atlas_negative_retry_delay_ns);
            }
        }

        const retry_at = self.atlas_negative_retry_at orelse return false;
        if (now < retry_at) return false;

        self.atlas_negative_retry_at = null;
        self.atlas_negative_recovery_armed = true;
        // Start a fresh observation window. markAllDirty below guarantees that
        // every visible invalidated negative is reprobed. If none recur, the
        // old missing glyph left the working set and the next flush can retire
        // the episode instead of forcing another full redraw on every edit.
        self.atlas_has_capacity_negative = false;
        return true;
    }

    pub fn prepareAtlasCapacityRetryAt(self: *Core, now: i128) bool {
        if (!self.armAtlasCapacityRetryAt(now)) return false;
        self.beginNegativeGlyphReprobe();
        return true;
    }

    pub fn prepareAtlasCapacityRetry(self: *Core) bool {
        return self.prepareAtlasCapacityRetryAt(clock.nowNs());
    }

    fn armTransientGlyphRetryAt(self: *Core, now: i128) bool {
        if (!self.transient_glyph_has_negative) return false;
        if (self.transient_glyph_retry_at == null and
            self.transient_glyph_retry_attempts >= TRANSIENT_GLYPH_RETRY_MAX_ATTEMPTS and
            self.transientGlyphWorkingSetChanged())
        {
            // Exhausted blanks are still cached, so a changed working set may
            // never call the rasterizer and cannot rely on record...() to
            // restart the budget. Schedule the fresh episode here.
            self.restartTransientGlyphRetryEpisode(now);
        }
        const retry_at = self.transient_glyph_retry_at orelse return false;
        if (now < retry_at) return false;

        self.transient_glyph_retry_at = null;
        self.transient_glyph_recovery_armed = true;
        self.transient_glyph_has_negative = false;
        return true;
    }

    pub fn prepareTransientGlyphRetryAt(self: *Core, now: i128) bool {
        if (!self.armTransientGlyphRetryAt(now)) return false;
        self.beginNegativeGlyphReprobe();
        return true;
    }

    pub fn prepareAtlasMaintenanceAt(self: *Core, now: i128) bool {
        const capacity_due = self.armAtlasCapacityRetryAt(now);
        const transient_due = self.armTransientGlyphRetryAt(now);
        if (!capacity_due and !transient_due) return false;
        self.beginNegativeGlyphReprobe();
        return true;
    }

    pub fn prepareAtlasMaintenance(self: *Core) bool {
        return self.prepareAtlasMaintenanceAt(clock.nowNs());
    }

    /// Restore a due reprobe after a frontend consumer rejected the flush.
    /// The attempt did not complete, so neither retry budget is consumed.
    pub fn rearmAtlasMaintenanceAfterAbort(self: *Core, retry_at: i128) void {
        if (self.atlas_negative_recovery_armed and self.atlas_negative_retry_at == null) {
            self.atlas_negative_recovery_armed = false;
            self.atlas_has_capacity_negative = true;
            self.atlas_negative_retry_at = retry_at;
        }
        if (self.transient_glyph_recovery_armed and self.transient_glyph_retry_at == null) {
            self.transient_glyph_recovery_armed = false;
            self.transient_glyph_has_negative = true;
            self.transient_glyph_retry_at = retry_at;
        }
    }

    fn blankGlyphEntry(bitmap: *const c_api.GlyphBitmap) c_api.GlyphEntry {
        const adv: f32 = @as(f32, @floatFromInt(bitmap.advance_26_6)) / 64.0;
        return c_api.GlyphEntry{
            .uv_min = .{ 0, 0 },
            .uv_max = .{ 0, 0 },
            .bbox_origin_px = .{ 0, 0 },
            .bbox_size_px = .{ 0, 0 },
            .advance_px = adv,
            .ascent_px = bitmap.ascent_px,
            .descent_px = bitmap.descent_px,
            .bytes_per_pixel = bitmap.bytes_per_pixel,
        };
    }

    /// Common helper: pack a rasterized bitmap into the atlas, upload, and build a GlyphEntry.
    /// Handles whitespace, oversized glyphs, bounded atlas growth, UV computation.
    /// A glyph that cannot fit at the maximum atlas size returns a zero-bbox
    /// entry so callers can negative-cache it instead of forcing a full-screen
    /// retry on every flush.
    fn packAndUploadBitmap(self: *Core, bm: *const c_api.GlyphBitmap) ?c_api.GlyphEntry {
        // Whitespace / zero-size glyph → return entry with zero UVs.
        if (bm.width == 0 or bm.height == 0) {
            return blankGlyphEntry(bm);
        }

        const pad2 = self.atlas_packer.?.padding * 2;
        // Dimensions cross the C ABI and are therefore hostile input. Check
        // every addition before ShelfPacker.alloc performs the same arithmetic
        // with ordinary u32 operators. An unrepresentable bitmap can never fit
        // a frontend texture, so it is a stable blank rather than an upload.
        const packed_w = std.math.add(u32, bm.width, pad2) catch return blankGlyphEntry(bm);
        const packed_h = std.math.add(u32, bm.height, pad2) catch return blankGlyphEntry(bm);
        const packed_h_with_border = std.math.add(u32, packed_h, 1) catch return blankGlyphEntry(bm);

        // Grow before packing when a single glyph cannot fit the current
        // texture. Growth invalidates every old UV, exactly like a reset.
        while ((packed_w > self.atlas_w or packed_h_with_border > self.atlas_h) and
            (self.atlas_w < config.atlas_size_max or self.atlas_h < config.atlas_size_max))
        {
            self.atlas_w = @min(config.atlas_size_max, self.atlas_w *| 2);
            self.atlas_h = @min(config.atlas_size_max, self.atlas_h *| 2);
            self.atlas_reset_during_flush = true;
            self.perf_atlas_full_reset_count +%= 1;
            self.resetCoreAtlas();
            if (self.flush_aborted) return null;
        }

        // Still oversized at the frontend-supported maximum: preserve the
        // existing texture and cache a permanent miss for this atlas/font
        // generation.
        if (packed_w > self.atlas_w or packed_h_with_border > self.atlas_h) {
            return blankGlyphEntry(bm);
        }

        const log_on = self.log.cb != null;

        // Try to pack.
        var packer = &(self.atlas_packer.?);
        const t_pack: i128 = if (log_on) clock.nowNs() else 0;
        var alloc_reset_seq = self.atlas_reset_seq;
        var rect = packer.alloc(bm.width, bm.height);

        // Fallback for a flush that exhausts the atlas despite the
        // start-of-flush collection: reclaim what earlier flushes left behind.
        // Shelves this flush already filled are protected by the epoch, so the
        // rows it has composed keep their UVs.
        if (rect == null and self.collectAtlasGarbage()) {
            rect = packer.alloc(bm.width, bm.height);
        }

        // A full atlas grows geometrically up to the configured/frontend-safe
        // maximum. At the maximum, permit one same-size reset for a fresh
        // capacity observation or an armed delayed recovery. Once a capacity
        // miss is negative-cached, ordinary flushes must wait for that
        // episode's deadline instead of recreating the texture for every new
        // glyph edit. If an allowed repack also fills, subsequent misses in
        // this flush become negative entries and the row retry converges.
        if (rect == null and
            (self.atlas_w < config.atlas_size_max or self.atlas_h < config.atlas_size_max))
        {
            self.atlas_w = @min(config.atlas_size_max, self.atlas_w *| 2);
            self.atlas_h = @min(config.atlas_size_max, self.atlas_h *| 2);
            self.atlas_reset_during_flush = true;
            self.perf_atlas_full_reset_count +%= 1;
            self.resetCoreAtlas();
            if (self.flush_aborted) return null;
            packer = &(self.atlas_packer.?);
            alloc_reset_seq = self.atlas_reset_seq;
            rect = packer.alloc(bm.width, bm.height);
        } else if (rect == null and
            self.atlas_full_resets_this_flush == 0 and
            (!self.atlas_has_capacity_negative or self.atlas_negative_recovery_armed))
        {
            self.atlas_full_resets_this_flush = 1;
            self.atlas_reset_during_flush = true;
            self.perf_atlas_full_reset_count +%= 1;
            self.resetCoreAtlas();
            if (self.flush_aborted) return null;
            packer = &(self.atlas_packer.?);
            alloc_reset_seq = self.atlas_reset_seq;
            rect = packer.alloc(bm.width, bm.height);
        }
        if (rect == null) {
            self.recordAtlasCapacityNegative();
            return blankGlyphEntry(bm);
        }
        if (log_on) {
            const dt: u64 = @intCast(@max(0, clock.nowNs() - t_pack));
            self.perf_pack_ns_total +%= dt;
        }

        const r = rect.?;

        // Upload glyph bitmap
        if (self.cb.on_atlas_upload) |f| {
            const t_up: i128 = if (log_on) clock.nowNs() else 0;
            f(self.ctx, r.x + packer.padding, r.y + packer.padding, bm.width, bm.height, bm);
            if (log_on) {
                const dt: u64 = @intCast(@max(0, clock.nowNs() - t_up));
                self.perf_upload_ns_total +%= dt;
                self.perf_upload_calls +%= 1;
            }
        }

        // on_atlas_upload's C ABI is void, so a frontend that discovers the
        // upload didn't actually land (e.g. macOS GlyphAtlas dropping it on
        // a reader-gate timeout or a failed pending blit) has no return
        // value to report that through -- it signals failure by calling
        // zonvie_core_abort_flush (and zonvie_core_invalidate_glyph_cache)
        // synchronously from inside the callback above instead. Checking
        // flush_aborted here and returning null (skipping the UV
        // computation and GlyphEntry below) is what actually stops the
        // caller from re-caching a bad entry: the cache invalidation the
        // callback already did happens BEFORE this point, so without this
        // check the entry built below would be written right back into the
        // just-cleared glyph_cache_by_id/glyph_cache_non_ascii, undoing it.
        if (self.flush_aborted or self.atlas_reset_seq != alloc_reset_seq) {
            // A rejected upload did not consume texture space. Restore the
            // shelf cursor only while it still names the same atlas generation;
            // an invalidate callback may already have replaced the packer.
            if (self.atlas_reset_seq == alloc_reset_seq and self.atlas_packer != null) {
                self.atlas_packer.?.undoLastAlloc();
            }
            if (self.atlas_reset_seq != alloc_reset_seq) self.flush_aborted = true;
            return null;
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

    /// Mark the shelf a vertex's UV points into as still referenced. One lookup
    /// per vertex covers both edges of the quad: the six vertices carry
    /// uv_min[1] and uv_max[1] between them, so a glyph whose lower edge lands
    /// on the next shelf's first row is marked by its own bottom vertices.
    fn markShelfLiveForUv(
        packer: *const shelf_packer.ShelfPacker,
        order: []const u16,
        live: *[shelf_packer.max_shelves]bool,
        uv_y: f32,
    ) void {
        if (uv_y <= 0 or uv_y > 1) return;
        const h_f: f32 = @floatFromInt(packer.height);
        const y_f = uv_y * h_f;
        if (y_f < 0) return;
        const y: u32 = @intFromFloat(@min(y_f, h_f - 1));
        if (packer.shelfIndexForYOrdered(order, y)) |idx| live[idx] = true;
    }

    /// True when every main-grid row the frontend is currently showing is
    /// either mirrored in scroll_cache (so its atlas references are readable
    /// here) or already dirty (so this flush regenerates it before publishing).
    /// Without this, a retained row whose vertices the core cannot inspect
    /// could keep a glyph that garbage collection would recycle underneath it.
    fn mainRowsAccountedForCollect(self: *Core) bool {
        const rows = self.scroll_cache_rows;
        if (rows == 0 or rows != self.grid.rows) return false;
        if (self.scroll_cache.items.len < rows) return false;
        if (self.scroll_cache_valid.bit_length < rows) return false;
        if (self.grid.dirty_all) return true;
        var r: u32 = 0;
        while (r < rows) : (r += 1) {
            if (self.scroll_cache_valid.isSet(r)) continue;
            if (r < self.grid.dirty_rows.bit_length and self.grid.dirty_rows.isSet(r)) continue;
            return false;
        }
        return true;
    }

    /// Reclaim atlas shelves that nothing on screen references any more.
    ///
    /// The high-cardinality case this exists for is a full-width CJK buffer:
    /// every entering row brings a screenful-fraction of never-seen glyphs, so
    /// a bump-only atlas fills within seconds and the only previous recovery
    /// was a full reset — which clears every glyph cache, forces a whole
    /// viewport rebuild, and refills the atlas immediately, i.e. it spirals.
    ///
    /// Liveness comes from the vertices the frontend is actually holding
    /// (scroll_cache mirrors the retained main rows; cursor_verts mirrors the
    /// cursor layer), never from glyph-cache reachability — a cache entry can
    /// be displaced by a hash collision while its glyph stays on screen, so
    /// "no cache entry points here" does not mean "nothing draws this".
    ///
    /// Returns true when at least one shelf became reusable.
    /// Reclaim atlas space before this flush generates anything, while
    /// scroll_cache still mirrors exactly what the frontend is showing.
    ///
    /// Collecting mid-generation instead was actively harmful: the rows this
    /// flush had already recomposed were not in scroll_cache yet, so the
    /// glyphs it had just packed looked unreferenced, were reclaimed, and had
    /// to be rasterized all over again on the next pass — the atlas never held
    /// a screenful for longer than one flush.
    /// Keep a copy of a row the scroll fast path is about to drop from the
    /// cache, so reclamation still counts the glyphs a frontend-retained copy
    /// of that row may keep drawing. Failing to copy costs reclamation accuracy
    /// only, never the scroll, so it is not reported to the caller.
    pub fn captureRetainedShadow(self: *Core, verts: []const c_api.Vertex) void {
        if (verts.len == 0) return;
        const slot = self.retained_shadow_next % self.retained_shadow.len;
        const buf = &self.retained_shadow[slot];
        buf.clearRetainingCapacity();
        buf.ensureTotalCapacity(self.alloc, verts.len) catch {
            self.retained_shadow_age[slot] = retained_shadow_expiry;
            return;
        };
        buf.appendSliceAssumeCapacity(verts);
        self.retained_shadow_age[slot] = 0;
        self.retained_shadow_next = (slot + 1) % self.retained_shadow.len;
    }

    fn ageRetainedShadows(self: *Core) void {
        for (&self.retained_shadow_age, &self.retained_shadow) |*age, *buf| {
            if (age.* >= retained_shadow_expiry) continue;
            age.* += 1;
            if (age.* >= retained_shadow_expiry) buf.clearRetainingCapacity();
        }
    }

    pub fn collectAtlasGarbageIfNeeded(self: *Core) void {
        self.ageRetainedShadows();
        if (self.atlas_packer == null) return;
        const packer = &(self.atlas_packer.?);
        const total: u64 = @as(u64, packer.width) * packer.height;
        if (total == 0) return;
        // free/total < 1/64: collect up front only when the atlas is close
        // enough to exhaustion that this flush would otherwise hit the reset
        // path mid-generation. The multiplier is the reciprocal of that
        // fraction, so the two move together.
        //
        // A collection is not cheap: it walks every glyph vertex on screen and
        // both 16384-entry glyph tables. Raising the trigger to 1/8 — which an
        // earlier version of this comment described, against a constant that
        // has always meant 1/64 — costs more than it saves. Measured on
        // test/perf/test_60fps.py, Release, against this same tree: p50
        // 2.09/2.12ms -> 2.53/2.85ms, p95 6.29/6.96ms -> 10.68/12.28ms,
        // on-glass slips 0.169/0.252/s -> 0.422/1.014/s, with no improvement
        // in p99. Ordinary pressure is handled by the collection inside
        // packAndUploadBitmap, which reclaims exactly as much as the flush
        // needs instead of dropping cache entries it is about to want back.
        if (packer.freeAreaPx() * 64 < total) _ = self.collectAtlasGarbage();
        // Everything packed from here on belongs to this flush and stays
        // off-limits to the mid-flush collection.
        if (self.atlas_packer) |*p| p.beginEpoch();
    }

    fn collectAtlasGarbage(self: *Core) bool {
        const log_on = self.log.cb != null;
        if (!self.isPhase2Atlas()) return false;
        if (self.atlas_packer == null) return false;
        // A grid the frontend owns a surface for (external window, float,
        // popupmenu) retains its own rows, and this core keeps no vertex mirror
        // of them. Keyed on the ownership map itself rather than on its
        // intersection with sub_grids: a grid can lose its GridBuf while the
        // surface is still on screen, and intersecting missed exactly that
        // window. Grids only composited into the main grid are covered by the
        // main-row scan below.
        if (self.known_external_grids.count() > 0) {
            if (log_on) self.log.write(
                "[perf] atlas_gc skip=external_grid count={d}\n",
                .{self.known_external_grids.count()},
            );
            return false;
        }
        if (self.display_mirror_stale) {
            if (log_on) self.log.write("[perf] atlas_gc skip=display_mirror_stale\n", .{});
            return false;
        }
        if (!self.mainRowsAccountedForCollect()) {
            if (log_on) self.log.write(
                "[perf] atlas_gc skip=rows scroll_cache_rows={d} grid_rows={d} dirty_all={any}\n",
                .{ self.scroll_cache_rows, self.grid.rows, self.grid.dirty_all },
            );
            return false;
        }

        const packer = &(self.atlas_packer.?);
        // Overflow means some bands were never recorded, not that the recorded
        // ones are unsafe to reclaim: an unrecorded band resolves to no shelf
        // index, so it marks nothing live (markShelfLiveForUv) and is never
        // dropped from the cache (entryLivesInDeadShelf), and
        // recycleDeadShelves only touches recorded shelves. Disqualifying the
        // whole collection here instead left reclamation off for the rest of
        // the session after a single overflow, because this is the only path
        // that can free tracking slots.
        if (packer.shelf_count == 0) {
            if (log_on) self.log.write(
                "[perf] atlas_gc skip=shelves count={d} overflow={any}\n",
                .{ packer.shelf_count, packer.shelf_overflow },
            );
            return false;
        }

        var live: [shelf_packer.max_shelves]bool = @splat(false);

        // Resolving a UV to a shelf happens once per glyph vertex on screen and
        // again per cached entry, so the ordering is built once here and shared
        // by both passes. Valid until mergeAdjacentRecycled renumbers shelves.
        var y_order: [shelf_packer.max_shelves]u16 = undefined;
        const order = y_order[0..packer.buildYOrder(&y_order)];

        const rows = self.scroll_cache_rows;
        var r: u32 = 0;
        while (r < rows) : (r += 1) {
            if (!self.scroll_cache_valid.isSet(r)) continue;
            for (self.scroll_cache.items[r].items) |v| {
                markShelfLiveForUv(packer, order, &live, v.texCoord[1]);
            }
        }
        for (self.cursor_verts.items) |v| {
            markShelfLiveForUv(packer, order, &live, v.texCoord[1]);
        }
        // The row this flush is composing right now. Its quads are not in
        // scroll_cache yet, and a glyph it took from the cache was allocated in
        // an earlier epoch, so the epoch guard does not cover it either.
        if (self.inflight_row_verts) |row| {
            for (row.items) |v| {
                markShelfLiveForUv(packer, order, &live, v.texCoord[1]);
            }
        }
        // Rows the frontend may still be drawing out of its own retained copy,
        // whose cache slots this core has already reused.
        for (self.retained_shadow_age, &self.retained_shadow) |age, *buf| {
            if (age >= retained_shadow_expiry) continue;
            for (buf.items) |v| {
                markShelfLiveForUv(packer, order, &live, v.texCoord[1]);
            }
        }

        const recycled = packer.recycleDeadShelves(&live);
        if (log_on) {
            var live_count: u32 = 0;
            for (live[0..packer.shelf_count]) |l| {
                if (l) live_count += 1;
            }
            self.log.write(
                "[perf] atlas_gc shelves={d} live={d} recycled={d}\n",
                .{ packer.shelf_count, live_count, recycled },
            );
        }
        if (recycled == 0) return false;

        // Every cached entry that pointed into a reclaimed shelf must go: the
        // space is about to hold a different glyph, and a surviving entry
        // would be a permanent cache hit returning the wrong UVs.
        if (self.glyph_cache_ascii) |cache| {
            if (self.glyph_valid_ascii) |valid| {
                const len = @min(cache.len, valid.len);
                for (cache[0..len], valid[0..len]) |entry, *is_valid| {
                    if (!is_valid.*) continue;
                    if (self.entryLivesInDeadShelf(packer, order, &live, entry)) is_valid.* = false;
                }
            }
        }
        self.dropKeyedEntriesInDeadShelves(packer, order, &live, self.glyph_cache_non_ascii, self.glyph_keys_non_ascii);
        self.dropKeyedEntriesInDeadShelves(packer, order, &live, self.glyph_cache_by_id, self.glyph_keys_by_id);
        // Only now that no cache entry names a reclaimed shelf can shelves be
        // renumbered. Fusing the free runs is what lets a tall glyph land in
        // space vacated by short ones.
        packer.mergeAdjacentRecycled();
        return true;
    }

    fn entryLivesInDeadShelf(
        self: *Core,
        packer: *const shelf_packer.ShelfPacker,
        order: []const u16,
        live: *const [shelf_packer.max_shelves]bool,
        entry: c_api.GlyphEntry,
    ) bool {
        _ = self;
        if (entry.bbox_size_px[0] <= 0 or entry.bbox_size_px[1] <= 0) return false;
        const uv_y = entry.uv_min[1];
        if (uv_y <= 0 or uv_y > 1) return false;
        const h_f: f32 = @floatFromInt(packer.height);
        const y: u32 = @intFromFloat(@min(uv_y * h_f, h_f - 1));
        const idx = packer.shelfIndexForYOrdered(order, y) orelse return false;
        return !live[idx];
    }

    fn dropKeyedEntriesInDeadShelves(
        self: *Core,
        packer: *const shelf_packer.ShelfPacker,
        order: []const u16,
        live: *const [shelf_packer.max_shelves]bool,
        cache_opt: ?[]c_api.GlyphEntry,
        keys_opt: ?[]u64,
    ) void {
        const cache = cache_opt orelse return;
        const keys = keys_opt orelse return;
        const len = @min(cache.len, keys.len);
        for (cache[0..len], keys[0..len]) |entry, *key| {
            if (key.* == GLYPH_CACHE_INVALID_KEY) continue;
            if (self.entryLivesInDeadShelf(packer, order, live, entry)) key.* = GLYPH_CACHE_INVALID_KEY;
        }
    }

    /// Ensure atlas is lazily initialized.
    fn ensureAtlasInit(self: *Core) bool {
        if (!self.atlas_initialized) {
            self.atlas_packer = shelf_packer.ShelfPacker.init(self.atlas_w, self.atlas_h);
            if (self.cb.on_atlas_create) |f| {
                const log_on = self.log.cb != null;
                const t: i128 = if (log_on) clock.nowNs() else 0;
                f(self.ctx, self.atlas_w, self.atlas_h);
                if (log_on) {
                    const dt: u64 = @intCast(@max(0, clock.nowNs() - t));
                    self.perf_atlas_create_ns_total +%= dt;
                    self.perf_atlas_create_calls +%= 1;
                }
            }
            if (self.flush_aborted) {
                self.atlas_packer = null;
                return false;
            }
            self.atlas_initialized = true;
        }
        return true;
    }

    /// Pre-rasterize printable ASCII (0x20-0x7E) for all style combos
    /// to eliminate cold-cache DWrite spikes on first flush.
    /// Called once after loadAsciiTables() succeeds (on font init).
    pub fn preRasterizeAscii(self: *Core) bool {
        if (self.flush_aborted) return false;
        // Guard: required callbacks must be set (ensureGlyphByID unwraps .?)
        if (self.cb.on_rasterize_glyph_by_id == null) return true;
        if (self.cb.on_atlas_upload == null) return true;
        if (self.cb.on_atlas_create == null) return true;

        self.initGlyphCache() catch return false;
        const cache = self.glyph_cache_by_id orelse return false;
        const keys = self.glyph_keys_by_id orelse return false;
        const scalar_cache = self.glyph_cache_ascii orelse return false;
        const scalar_valid = self.glyph_valid_ascii orelse return false;
        // Modulus MUST be the physical hash-table length, not the mutable size field.
        // glyph_cache_non_ascii_size can drift from the allocated arrays (a concurrent
        // setGlyphCacheSize updates the size field before the arrays are reallocated),
        // and hashing with a larger modulus then indexes past the end of `keys`/`cache`
        // -> "index out of bounds". Deriving the modulus from keys.len can never do that.
        const CACHE_SIZE = @as(u32, @intCast(keys.len));
        if (CACHE_SIZE == 0) return false;

        const style_combos = [4]u32{ 0, c_api.STYLE_BOLD, c_api.STYLE_ITALIC, c_api.STYLE_BOLD | c_api.STYLE_ITALIC };

        var rasterized: u32 = 0;
        var skipped: u32 = 0;

        for (0..4) |si| {
            if (self.flush_aborted) return false;
            const gids = &self.ascii_glyph_ids[si];
            const c_style = style_combos[si];

            for (0x20..0x7F) |scalar| {
                if (self.flush_aborted) return false;
                const gid = gids[scalar];
                if (gid == 0) continue; // .notdef

                const key = (@as(u64, gid) << 2) | @as(u64, si);
                const hash_val = (gid *% 2654435761) ^ @as(u32, @intCast(si));
                const probe = glyphCacheProbe(keys, key, hash_val);
                const scalar_index = scalar * 4 + si;

                // Already cached by glyph ID. Mirror it into the canonical
                // scalar*4+style slot used by both row and cursor fast paths.
                // A blank by-ID entry may be a normal primary-face miss, so
                // resolve the scalar fallback before publishing that slot.
                if (probe.hit) |hit| {
                    var scalar_entry = cache[hit];
                    var can_mirror = scalar_entry.bbox_size_px[0] > 0 and scalar_entry.bbox_size_px[1] > 0;
                    if ((scalar_entry.bbox_size_px[0] <= 0 or scalar_entry.bbox_size_px[1] <= 0) and
                        self.cb.on_rasterize_glyph != null)
                    {
                        scalar_entry = self.ensureGlyphPhase2(@intCast(scalar), c_style) orelse {
                            if (self.flush_aborted) return false;
                            skipped += 1;
                            continue;
                        };
                        can_mirror = true;
                    }
                    if (can_mirror and scalar_index < scalar_cache.len and scalar_index < scalar_valid.len) {
                        scalar_cache[scalar_index] = scalar_entry;
                        scalar_valid[scalar_index] = true;
                    }
                    skipped += 1;
                    continue;
                }

                // Rasterize + pack + upload
                if (self.ensureGlyphByID(gid, c_style)) |entry| {
                    cache[probe.insert] = entry;
                    keys[probe.insert] = key;
                    var scalar_entry = entry;
                    var can_mirror = entry.bbox_size_px[0] > 0 and entry.bbox_size_px[1] > 0;
                    if ((entry.bbox_size_px[0] <= 0 or entry.bbox_size_px[1] <= 0) and
                        self.cb.on_rasterize_glyph != null)
                    {
                        scalar_entry = self.ensureGlyphPhase2(@intCast(scalar), c_style) orelse {
                            if (self.flush_aborted) return false;
                            rasterized += 1;
                            continue;
                        };
                        can_mirror = true;
                    }
                    if (can_mirror and scalar_index < scalar_cache.len and scalar_index < scalar_valid.len) {
                        scalar_cache[scalar_index] = scalar_entry;
                        scalar_valid[scalar_index] = true;
                    }
                    rasterized += 1;
                } else if (self.flush_aborted) {
                    return false;
                }
            }
        }

        self.log.write("[perf] preRasterizeAscii rasterized={d} skipped={d}\n", .{ rasterized, skipped });
        return true;
    }

    /// Phase 2 glyph resolution: rasterize → pack → upload → build GlyphEntry.
    /// A non-aborting rasterizer miss returns a blank negative-cache entry and
    /// arms bounded maintenance retries. Upload/create failures use
    /// flush_aborted and still return null, immediately rejecting the whole
    /// transaction rather than publishing a blank.
    pub fn ensureGlyphPhase2(self: *Core, scalar: u32, style_flags: u32) ?c_api.GlyphEntry {
        const log_on = self.log.cb != null;
        const t_total: i128 = if (log_on) clock.nowNs() else 0;
        defer if (log_on) {
            const dt: u64 = @intCast(@max(0, clock.nowNs() - t_total));
            self.perf_atlas_total_ns_total +%= dt;
            self.perf_atlas_total_calls +%= 1;
        };

        if (!self.ensureAtlasInit()) return null;

        // Ask frontend to rasterize (no packing / UV)
        var bm: c_api.GlyphBitmap = std.mem.zeroes(c_api.GlyphBitmap);
        const t_r: i128 = if (log_on) clock.nowNs() else 0;
        const ok = self.cb.on_rasterize_glyph.?(self.ctx, scalar, style_flags, &bm);
        if (log_on) {
            const dt: u64 = @intCast(@max(0, clock.nowNs() - t_r));
            self.perf_rasterize_ns_total +%= dt;
            self.perf_rasterize_calls +%= 1;
        }
        if (self.flush_aborted) return null;
        if (ok == 0) {
            self.recordTransientGlyphNegative();
            return blankGlyphEntry(&bm);
        }

        return self.packAndUploadBitmap(&bm);
    }

    /// Phase B: Resolve a shaped glyph by its glyph ID (post-shaping).
    /// Similar to ensureGlyphPhase2 but uses on_rasterize_glyph_by_id callback.
    /// A zero result is a cacheable blank but does not itself arm maintenance:
    /// primary-face misses commonly succeed through the caller's scalar/fallback
    /// font path. Only a final scalar miss starts the bounded retry episode.
    pub fn ensureGlyphByID(self: *Core, glyph_id: u32, style_flags: u32) ?c_api.GlyphEntry {
        const log_on = self.log.cb != null;
        const t_total: i128 = if (log_on) clock.nowNs() else 0;
        defer if (log_on) {
            const dt: u64 = @intCast(@max(0, clock.nowNs() - t_total));
            self.perf_atlas_total_ns_total +%= dt;
            self.perf_atlas_total_calls +%= 1;
        };

        if (!self.ensureAtlasInit()) return null;

        var bm: c_api.GlyphBitmap = std.mem.zeroes(c_api.GlyphBitmap);
        const t_r: i128 = if (log_on) clock.nowNs() else 0;
        const ok = self.cb.on_rasterize_glyph_by_id.?(self.ctx, glyph_id, style_flags, &bm);
        if (log_on) {
            const dt: u64 = @intCast(@max(0, clock.nowNs() - t_r));
            self.perf_rasterize_ns_total +%= dt;
            self.perf_rasterize_calls +%= 1;
        }
        if (self.flush_aborted) return null;
        if (ok == 0) {
            return blankGlyphEntry(&bm);
        }

        return self.packAndUploadBitmap(&bm);
    }

    /// Reset core atlas: clear packer, invalidate cache, recreate texture.
    pub fn resetCoreAtlas(self: *Core) void {
        const capacity_reprobe_in_progress = self.atlas_negative_recovery_armed;
        self.atlas_reset_seq +%= 1;
        self.atlas_has_capacity_negative = false;
        self.atlas_negative_retry_at = null;
        if (!capacity_reprobe_in_progress) {
            self.atlas_negative_retry_delay_ns = 250 * std.time.ns_per_ms;
            self.atlas_negative_recovery_armed = false;
        }
        // Reinitialize rather than merely reset: atlas_w/h can grow when a
        // full atlas is encountered.
        self.atlas_packer = shelf_packer.ShelfPacker.init(self.atlas_w, self.atlas_h);
        self.resetGlyphCacheFlags();
        self.atlas_initialized = true;
        if (self.cb.on_atlas_create) |f| {
            const log_on = self.log.cb != null;
            const t: i128 = if (log_on) clock.nowNs() else 0;
            f(self.ctx, self.atlas_w, self.atlas_h);
            if (log_on) {
                const dt: u64 = @intCast(@max(0, clock.nowNs() - t));
                self.perf_atlas_create_ns_total +%= dt;
                self.perf_atlas_create_calls +%= 1;
            }
        }
        if (self.flush_aborted) {
            self.atlas_packer = null;
            self.atlas_initialized = false;
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
            // sendInput/sendKeyEvent may be called concurrently now (macOS
            // key-repeat synthesis calls this from a display-link thread as
            // well as the normal per-keystroke caller), so key_buf needs a
            // lock even though requestInput()'s own write path is safe.
            self.key_buf_mu.lockUncancelable(clock.io());
            defer self.key_buf_mu.unlock(clock.io());
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
        self.grid_mu.lockUncancelable(clock.io());
        defer self.grid_mu.unlock(clock.io());
        self.noteInputTraceLocked(seq, sent_ns);
    }

    /// Non-blocking version of noteInputTrace. Drops the sample (this seq's
    /// [perf_input] trace line simply won't appear) if grid_mu could not be
    /// acquired, rather than blocking the input-send path -- this trace
    /// exists only to measure input latency and must not itself add to it.
    /// Returns true if the sample was recorded.
    pub fn tryNoteInputTrace(self: *Core, seq: u64, sent_ns: i64) bool {
        const acquired = self.grid_mu.tryLock();
        self.perf_lock_input_trace.record(acquired);
        if (!acquired) return false;
        defer self.grid_mu.unlock(clock.io());
        self.noteInputTraceLocked(seq, sent_ns);
        return true;
    }

    fn noteInputTraceLocked(self: *Core, seq: u64, sent_ns: i64) void {
        self.grid.noteInputTrace(seq, sent_ns);
        if (self.log.cb != null) {
            self.log.write("[perf_input] seq={d} stage=input_send sent_ns={d}\n", .{ seq, sent_ns });
        }
    }

    /// Send raw data to child process stdin (for SSH password input).
    /// Signals ssh_auth_done after writing.
    pub fn sendStdinData(self: *Core, data: []const u8) void {
        if (self.stop_flag.load(.seq_cst)) return;
        self.stdin_close_mu.lockUncancelable(clock.io());
        defer self.stdin_close_mu.unlock(clock.io());
        if (self.stop_flag.load(.seq_cst)) return;
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
        self.grid_mu.lockUncancelable(clock.io());
        defer self.grid_mu.unlock(clock.io());
        return self.getVisibleGridsSnapshotLocked(out, false).written;
    }

    /// Non-blocking version of getVisibleGrids.
    /// Returns null if grid_mu could not be acquired (another thread holds it).
    pub fn tryGetVisibleGrids(self: *Core, out: []c_api.GridInfo) ?usize {
        if (!self.grid_mu.tryLock()) return null;
        defer self.grid_mu.unlock(clock.io());
        return self.getVisibleGridsSnapshotLocked(out, false).written;
    }

    pub const VisibleGridsSnapshot = struct {
        written: usize,
        total: usize,
    };

    /// Non-blocking complete snapshot. `total` counts every visible grid from
    /// the same locked state even when `out` is too small; `written` is the
    /// initialized prefix of out.
    pub fn tryGetVisibleGridsComplete(self: *Core, out: []c_api.GridInfo) ?VisibleGridsSnapshot {
        if (!self.grid_mu.tryLock()) return null;
        defer self.grid_mu.unlock(clock.io());
        return self.getVisibleGridsSnapshotLocked(out, true);
    }

    /// Internal: snapshot visible grids assuming grid_mu is already held.
    /// `count_all` preserves the legacy APIs' stop-at-capacity hot path while
    /// the complete API scans the same locked state to detect truncation.
    fn getVisibleGridsSnapshotLocked(self: *Core, out: []c_api.GridInfo, count_all: bool) VisibleGridsSnapshot {
        var written: usize = 0;
        var total: usize = 0;

        // Always include global grid first
        if (written < out.len) {
            const m1 = self.grid.getViewportMargins(1);
            out[written] = .{
                .grid_id = 1,
                .zindex = 0, // global grid has lowest zindex
                .start_row = 0,
                .start_col = 0,
                .rows = grid_mod.saturatingI32FromU32(self.grid.rows),
                .cols = grid_mod.saturatingI32FromU32(self.grid.cols),
                .margin_top = grid_mod.saturatingI32FromU32(m1.top),
                .margin_bottom = grid_mod.saturatingI32FromU32(m1.bottom),
                .margin_left = grid_mod.saturatingI32FromU32(m1.left),
                .margin_right = grid_mod.saturatingI32FromU32(m1.right),
                .line_count = if (self.grid.getViewport(1)) |vp| vp.line_count else 0,
                .anchor_grid = 1,
                .follows_scroll = 0,
                .is_external = 0,
            };
            written += 1;
        }
        total += 1;
        if (!count_all and written == out.len) return .{ .written = written, .total = total };

        // Add sub-grids (floating windows)
        var it = self.grid.win_pos.iterator();
        while (it.next()) |entry| {
            const gid = entry.key_ptr.*;
            if (gid == 1) continue; // skip global grid (already added)

            const pos = entry.value_ptr.*;
            const sg = self.grid.sub_grids.get(gid) orelse continue;
            if (written < out.len) {
                const layer = self.grid.win_layer.get(gid) orelse @import("grid.zig").WinLayer{
                    .zindex = 0,
                    .compindex = 0,
                    .order = 0,
                };
                const margins = self.grid.getViewportMargins(gid);

                out[written] = .{
                    .grid_id = gid,
                    .zindex = layer.zindex,
                    .start_row = grid_mod.saturatingI32FromU32(pos.row),
                    .start_col = grid_mod.saturatingI32FromU32(pos.col),
                    .rows = grid_mod.saturatingI32FromU32(sg.rows),
                    .cols = grid_mod.saturatingI32FromU32(sg.cols),
                    .margin_top = grid_mod.saturatingI32FromU32(margins.top),
                    .margin_bottom = grid_mod.saturatingI32FromU32(margins.bottom),
                    .margin_left = grid_mod.saturatingI32FromU32(margins.left),
                    .margin_right = grid_mod.saturatingI32FromU32(margins.right),
                    .line_count = if (self.grid.getViewport(gid)) |vp| vp.line_count else 0,
                    .anchor_grid = pos.anchor_grid,
                    .follows_scroll = if (pos.follows_scroll) 1 else 0,
                    .is_external = 0,
                };
                written += 1;
            }
            total += 1;
            if (!count_all and written == out.len) return .{ .written = written, .total = total };
        }

        // Add external grids (separate top-level windows)
        var ext_it = self.grid.external_grids.keyIterator();
        while (ext_it.next()) |key_ptr| {
            const gid = key_ptr.*;
            const sg = self.grid.sub_grids.get(gid) orelse continue;
            if (written < out.len) {
                const margins = self.grid.getViewportMargins(gid);

                out[written] = .{
                    .grid_id = gid,
                    .zindex = 0, // External grids have their own window, zindex doesn't apply
                    .start_row = 0, // External grids start at (0,0) in their own window
                    .start_col = 0,
                    .rows = grid_mod.saturatingI32FromU32(sg.rows),
                    .cols = grid_mod.saturatingI32FromU32(sg.cols),
                    .margin_top = grid_mod.saturatingI32FromU32(margins.top),
                    .margin_bottom = grid_mod.saturatingI32FromU32(margins.bottom),
                    .margin_left = grid_mod.saturatingI32FromU32(margins.left),
                    .margin_right = grid_mod.saturatingI32FromU32(margins.right),
                    .line_count = if (self.grid.getViewport(gid)) |vp| vp.line_count else 0,
                    .anchor_grid = 1,
                    .follows_scroll = 0,
                    .is_external = 1,
                };
                written += 1;
            }
            total += 1;
            if (!count_all and written == out.len) return .{ .written = written, .total = total };
        }

        return .{ .written = written, .total = total };
    }

    pub const CursorPosition = struct {
        grid_id: i64,
        row: i32,
        col: i32,
    };

    pub fn getCursorPosition(self: *Core) CursorPosition {
        // Lock grid_mu to prevent concurrent modification from RPC thread.
        self.grid_mu.lockUncancelable(clock.io());
        defer self.grid_mu.unlock(clock.io());
        return self.getCursorPositionLocked();
    }

    /// Non-blocking version of getCursorPosition.
    /// Returns null if grid_mu could not be acquired (another thread holds it).
    pub fn tryGetCursorPosition(self: *Core) ?CursorPosition {
        const acquired = self.grid_mu.tryLock();
        self.perf_lock_cursor_pos.record(acquired);
        if (!acquired) return null;
        defer self.grid_mu.unlock(clock.io());
        return self.getCursorPositionLocked();
    }

    /// Internal: get cursor position assuming grid_mu is already held.
    fn getCursorPositionLocked(self: *Core) CursorPosition {
        return .{
            .grid_id = self.grid.cursor_grid,
            .row = grid_mod.saturatingI32FromU32(self.grid.cursor_row),
            .col = grid_mod.saturatingI32FromU32(self.grid.cursor_col),
        };
    }

    /// Internal: copy the current mode name into a caller-provided buffer
    /// (truncated + null-terminated to fit) and read cursor visibility,
    /// assuming grid_mu is already held.
    fn getModeStateLocked(self: *Core, out_mode_buf: [*]u8, buf_len: usize, out_cursor_visible: *bool) void {
        const name = &self.grid.current_mode_name;
        const raw_len = std.mem.indexOfScalar(u8, name, 0) orelse name.len;
        const n = @min(buf_len -| 1, raw_len);
        @memcpy(out_mode_buf[0..n], name[0..n]);
        out_mode_buf[n] = 0;
        out_cursor_visible.* = self.grid.cursor_visible;
    }

    /// Non-blocking combined read of current mode name + cursor visibility.
    /// Returns false if grid_mu could not be acquired (another thread holds
    /// it) -- caller should keep its last-known cached values in that case.
    pub fn tryGetModeState(self: *Core, out_mode_buf: [*]u8, buf_len: usize, out_cursor_visible: *bool) bool {
        const acquired = self.grid_mu.tryLock();
        self.perf_lock_mode_state.record(acquired);
        if (!acquired) return false;
        defer self.grid_mu.unlock(clock.io());
        self.getModeStateLocked(out_mode_buf, buf_len, out_cursor_visible);
        return true;
    }

    /// Get viewport info for a specific grid (for scrollbar rendering).
    /// Returns 1 if found, 0 if not found.
    pub fn getViewportInfo(self: *Core, grid_id: i64, out: *c_api.ViewportInfo) i32 {
        self.grid_mu.lockUncancelable(clock.io());
        defer self.grid_mu.unlock(clock.io());
        return self.getViewportInfoLocked(grid_id, out);
    }

    /// Non-blocking version of getViewportInfo.
    /// Returns null if grid_mu could not be acquired (another thread holds it).
    pub fn tryGetViewportInfo(self: *Core, grid_id: i64, out: *c_api.ViewportInfo) ?i32 {
        const acquired = self.grid_mu.tryLock();
        self.perf_lock_viewport.record(acquired);
        if (!acquired) return null;
        defer self.grid_mu.unlock(clock.io());
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
        self.grid_mu.lockUncancelable(clock.io());
        defer self.grid_mu.unlock(clock.io());
        return self.getHlByNameLocked(name);
    }

    /// Internal: look up a highlight group by name assuming grid_mu is
    /// already held. Lets a caller batch several lookups under one lock
    /// acquisition instead of one lockUncancelable per name.
    pub fn getHlByNameLocked(self: *Core, name: []const u8) HlColors {
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

    pub fn resize(self: *Core, rows: u32, cols: u32) bool {
        self.pending_resize_mu.lockUncancelable(clock.io());
        defer self.pending_resize_mu.unlock(clock.io());

        // Retain the desired dimensions independently of delivery. An enqueue
        // to the old writer can succeed immediately before reconnect cleanup
        // drops that queue; resetSessionState republishes this latest value.
        self.desired_resize_rows = rows;
        self.desired_resize_cols = cols;
        const sequence = self.nextPendingUiStateSequenceLocked();
        self.pending_resize_rows = rows;
        self.pending_resize_cols = cols;
        self.pending_resize_valid = true;
        self.pending_resize_sequence = sequence;

        // nvim_ui_try_resize is invalid before nvim_ui_attach. Publish the
        // newest layout for the attach thread to drain atomically instead.
        if (!self.ui_attached.load(.acquire)) {
            return false;
        }

        self.flushPendingUiStateLocked();
        return !self.pending_resize_valid or self.pending_resize_sequence != sequence;
    }

    pub fn updateLayoutPx(
        self: *Core,
        drawable_w_px: u32,
        drawable_h_px: u32,
        cell_w_px: u32,
        cell_h_px: u32,
    ) bool {
        // If called from within handleRedraw (via callback) on the SAME thread,
        // grid_mu is already held, so we can call the locked version directly.
        // This ensures cell dimensions are updated BEFORE the flush generates vertices.
        // We compare thread IDs to avoid the UI thread incorrectly skipping the lock
        // when the RPC thread is in handleRedraw (which would cause a data race).
        const current_tid: usize = @intCast(std.Thread.getCurrentId());
        const redraw_tid = self.redraw_thread_id.load(.seq_cst);
        if (redraw_tid != 0 and redraw_tid == current_tid) {
            _ = self.updateLayoutPxLocked(drawable_w_px, drawable_h_px, cell_w_px, cell_h_px);
            return false;
        }

        // Called from UI thread - acquire grid_mu to protect grid state access.
        self.grid_mu.lockUncancelable(clock.io());
        const changed = self.updateLayoutPxLocked(drawable_w_px, drawable_h_px, cell_w_px, cell_h_px);
        self.grid_mu.unlock(clock.io());
        return changed;
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
    ) bool {
        // All inputs are already integer pixels (UI measured & rounded).
        // Keep core logic deterministic across macOS/Windows.
        const cw = if (cell_w_px == 0) 1 else cell_w_px;
        const ch = if (cell_h_px == 0) 1 else cell_h_px;
        const dw = if (drawable_w_px == 0) 1 else drawable_w_px;
        const dh = if (drawable_h_px == 0) 1 else drawable_h_px;

        // NDC positions depend on both cell and drawable dimensions.
        const drawable_dims_changed = (dw != self.drawable_w_px or dh != self.drawable_h_px);
        const cell_dims_changed = (cw != self.cell_w_px or ch != self.cell_h_px);

        const cols = @max(@as(u32, 1), dw / cw);
        const rows = @max(@as(u32, 1), dh / ch);
        const grid_dims_changed = (rows != self.last_layout_rows or cols != self.last_layout_cols);
        const vertex_geometry_changed = drawable_dims_changed or cell_dims_changed or grid_dims_changed;

        self.drawable_w_px = dw;
        self.drawable_h_px = dh;
        self.cell_w_px = cw;
        self.cell_h_px = ch;

        // Keep global grid (id=1) cell metrics for future per-grid font metrics.
        self.grid.setGridMetricsPx(1, cw, ch) catch {};

        // Update screen_cols for cmdline max width (cols derived from drawable width).
        // This is done here to avoid a separate lock acquisition in setScreenCols.
        self.grid.screen_cols = cols;

        // Any geometry input change invalidates baked NDC positions, including
        // drawable-only resizes and row/column changes at the same cell size.
        if (vertex_geometry_changed) {
            self.grid.markAllDirty();
            // Cursor geometry is submitted independently of row vertices.
            self.grid.cursor_rev +%= 1;
            // External-grid NDC uses each external drawable/viewport, not the
            // main drawable dimensions. Regenerate them only when shared cell
            // metrics change; a one-pixel main live-resize must stay O(main).
            if (cell_dims_changed) {
                var sg_it = self.grid.sub_grids.valueIterator();
                while (sg_it.next()) |sg| {
                    sg.markAllDirty();
                }
            }
        }

        if (!grid_dims_changed) return vertex_geometry_changed;

        // Only suppress a future resize after the RPC was accepted. A failed
        // send remains pending and the same dimensions must be retried.
        if (self.resize(rows, cols)) {
            self.last_layout_rows = rows;
            self.last_layout_cols = cols;
        }
        return vertex_geometry_changed;
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
        self.grid_mu.lockUncancelable(clock.io());
        defer self.grid_mu.unlock(clock.io());
        self.grid.screen_cols = cols;
    }

    /// Set the cmdline's default width in cells. Same re-entrancy rules as
    /// setScreenCols: the redraw thread already owns grid_mu.
    pub fn setCmdlineDefaultCols(self: *Core, cols: u32) void {
        const current_tid: usize = @intCast(std.Thread.getCurrentId());
        const redraw_tid = self.redraw_thread_id.load(.seq_cst);
        if (redraw_tid != 0 and redraw_tid == current_tid) {
            self.grid.cmdline_default_cols = cols;
            return;
        }
        self.grid_mu.lockUncancelable(clock.io());
        defer self.grid_mu.unlock(clock.io());
        self.grid.cmdline_default_cols = cols;
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
        // Avoid Utf8Iterator.nextCodepoint() because it can panic on invalid
        // UTF-8 (it uses utf8Decode(slice) catch unreachable) — see the same
        // hazard documented in redraw_handler.zig's firstCodepoint().
        const slice = it.nextCodepointSlice() orelse return null;
        const cp = std.unicode.utf8Decode(slice) catch return 0xFFFD;
        return @as(u32, cp);
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
            0x25 => "Left", // VK_LEFT
            0x26 => "Up", // VK_UP
            0x27 => "Right", // VK_RIGHT
            0x28 => "Down", // VK_DOWN
            0x24 => "Home", // VK_HOME
            0x23 => "End", // VK_END
            0x21 => "PageUp", // VK_PRIOR
            0x22 => "PageDown", // VK_NEXT
            0x08 => "BS", // VK_BACK
            0x2E => "Del", // VK_DELETE
            0x0D => "CR", // VK_RETURN
            0x09 => "Tab", // VK_TAB
            0x1B => "Esc", // VK_ESCAPE
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
        // Use persistent buffer (zero-allocation hot path). Locked for the
        // whole function (every branch below reads/writes key_buf before
        // returning): sendInput/sendKeyEvent may now be called concurrently
        // from macOS key-repeat synthesis's display-link thread.
        self.key_buf_mu.lockUncancelable(clock.io());
        defer self.key_buf_mu.unlock(clock.io());
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
        const owned = self.alloc.dupe(u8, listen_addr) catch |e| {
            self.log.write("handleRestartEvent: dupe failed: {any}\n", .{e});
            return e;
        };
        const old = self.restart_pending_addr;
        // Explicit reset in case a prior :connect queued (then aborted) left
        // the hot-swap flag set; :restart is NOT a hot-swap (the old nvim
        // dies), so spawn fallback on connect failure is the desired recovery.
        self.restart_pending_is_connect_hotswap = false;
        self.connect_keeps_child_alive = false;
        // Publish the address last so any observer that sees a pending restart
        // also sees the restart (not hot-swap) cleanup policy above.
        self.restart_pending_addr = owned;
        if (old) |addr| self.alloc.free(addr);

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
        const owned = self.alloc.dupe(u8, server_addr) catch |e| {
            self.log.write("handleConnectEvent: dupe failed: {any}\n", .{e});
            return e;
        };
        const old = self.restart_pending_addr;
        self.restart_pending_is_connect_hotswap = true;
        self.connect_keeps_child_alive = true;
        self.restart_pending_addr = owned;
        if (old) |addr| self.alloc.free(addr);

        self.log.write("handleConnectEvent: server_addr={s}\n", .{server_addr});

        self.emitOnConnect(server_addr);
    }

    /// Dedicated writer thread: drains write_queue and writes to stdin pipe.
    /// Receives the stream by value to avoid racing with stop().
    fn writerThreadFn(self: *Core, file: Stream) void {
        // See rpc_session.runLoop's identical call for rationale: match the
        // UI thread's QoS so this thread isn't starved relative to it.
        if (comptime @import("builtin").os.tag == .macos) {
            _ = std.c.pthread_set_qos_class_self_np(.USER_INTERACTIVE, 0);
        }
        defer self.writer_exited.store(true, .release);

        while (true) {
            self.write_queue_mu.lockUncancelable(clock.io());

            // Wait for data or close signal
            while (self.write_queue.items.len == 0 and !self.write_queue_closed) {
                self.write_queue_cond.waitUncancelable(clock.io(), &self.write_queue_mu);
            }

            // Shutdown is cancellation, not a delivery barrier. Once closed,
            // discard queued RPC bytes instead of starting another potentially
            // blocking write while teardown is trying to join this thread.
            if (self.write_queue_closed) {
                self.write_queue.clearRetainingCapacity();
                self.write_queue_normal_bytes = 0;
                self.write_queue_ui_state_bytes = 0;
                self.write_queue_mu.unlock(clock.io());
                self.log.write("writer thread: shutdown (queued writes dropped)\n", .{});
                break;
            }

            // All producers append to one FIFO. Swapping the whole buffer is
            // the only drain boundary, so normal and UI-state RPCs retain the
            // exact order in which they acquired write_queue_mu.
            std.mem.swap(
                std.ArrayListUnmanaged(u8),
                &self.write_queue,
                &self.write_spare_queue,
            );
            self.write_queue_normal_bytes = 0;
            self.write_queue_ui_state_bytes = 0;
            self.write_queue_mu.unlock(clock.io());

            // Write to pipe WITHOUT holding any mutex
            file.writeAllCancelable(self.write_spare_queue.items, &self.writer_cancel_requested) catch |e| {
                self.log.write("writer thread writeAll err: {any}\n", .{e});
                // Mark writer as failed + closed, notify any future waiters
                self.write_queue_mu.lockUncancelable(clock.io());
                self.writer_failed = true;
                self.write_queue_closed = true;
                self.write_queue_cond.broadcast(clock.io());
                self.write_queue_mu.unlock(clock.io());
                break;
            };

            self.write_spare_queue.clearRetainingCapacity();
        }
    }

    /// Start the dedicated writer thread for non-blocking stdin writes.
    /// Safe to call from rpc_session.zig after stdin_file is set.
    pub fn startWriterThread(self: *Core) bool {
        // Publish the by-value Stream and writer handle atomically with
        // teardown's stdin_close_mu -> write_queue_mu transition. Without the
        // outer lock, stop could close/recycle the descriptor after this copy
        // but before writer_thread becomes visible for joining.
        self.stdin_close_mu.lockUncancelable(clock.io());
        var file = self.stdin_file orelse {
            self.stdin_close_mu.unlock(clock.io());
            self.log.write("startWriterThread: stdin_file is null\n", .{});
            return false;
        };

        self.write_queue_mu.lockUncancelable(clock.io());

        // Guard: don't start if shutdown is in progress or already running.
        // write_queue_closed is set by stop() under the same mutex, so this
        // check fully closes the race window between stop_flag and lock acquisition.
        if (self.writer_thread != null) {
            self.write_queue_mu.unlock(clock.io());
            self.stdin_close_mu.unlock(clock.io());
            return true;
        }
        if (self.write_queue_closed) {
            self.write_queue_mu.unlock(clock.io());
            self.stdin_close_mu.unlock(clock.io());
            return false;
        }

        // Reset state flags and drain stale data (safe for reconnect / re-use)
        self.writer_failed = false;
        self.write_queue.clearRetainingCapacity();
        self.write_spare_queue.clearRetainingCapacity();
        self.write_queue_normal_bytes = 0;
        self.write_queue_ui_state_bytes = 0;
        self.write_queue.ensureTotalCapacityPrecise(self.alloc, UI_STATE_WRITE_RESERVE_SIZE) catch |e| {
            self.write_queue_mu.unlock(clock.io());
            self.stdin_close_mu.unlock(clock.io());
            self.log.write("FATAL: failed to reserve active writer UI-state capacity: {any}\n", .{e});
            return false;
        };
        self.write_spare_queue.ensureTotalCapacityPrecise(self.alloc, UI_STATE_WRITE_RESERVE_SIZE) catch |e| {
            self.write_queue_mu.unlock(clock.io());
            self.stdin_close_mu.unlock(clock.io());
            self.log.write("FATAL: failed to reserve spare writer UI-state capacity: {any}\n", .{e});
            return false;
        };

        if (self.transport_kind == .pipes) {
            file = file.preparePipeWriter() catch |e| {
                self.write_queue_mu.unlock(clock.io());
                self.stdin_close_mu.unlock(clock.io());
                self.log.write("FATAL: failed to make writer pipe cancelable: {any}\n", .{e});
                return false;
            };
            // Keep the Core-owned copy's metadata consistent with the writer
            // copy. The kernel flag is shared by both descriptor aliases.
            self.stdin_file = file;
        }
        self.writer_cancel_requested.store(false, .release);
        self.writer_exited.store(false, .release);

        self.writer_thread = std.Thread.spawn(.{}, writerThreadFn, .{ self, file }) catch |e| {
            self.writer_exited.store(true, .release);
            self.write_queue_mu.unlock(clock.io());
            self.stdin_close_mu.unlock(clock.io());
            self.log.write("FATAL: failed to spawn writer thread: {any}\n", .{e});
            return false;
        };

        self.write_queue_mu.unlock(clock.io());
        self.stdin_close_mu.unlock(clock.io());
        return true;
    }

    /// Release a writer blocked in transport I/O before joining it. The queue
    /// must already be closed and signaled. POSIX child pipes are non-blocking
    /// (preparePipeWriter); sockets use shutdown; Windows named pipes use
    /// CancelIoEx; synchronous Windows child pipes are canceled by thread.
    pub fn cancelWriterIo(self: *Core, writer: ?std.Thread, stdin: ?Stream, transport_kind: TransportKind) void {
        self.writer_cancel_requested.store(true, .release);
        if (stdin) |stream| {
            if (transport_kind == .socket) stream.shutdownIfSocket(true) catch |e| self.log.write(
                "writer cancel: socket shutdown failed: {any} (writer stays blocked)\n",
                .{e},
            );
            switch (stream) {
                .win_pipe => stream.close(),
                .file => {},
            }
        }
        if (writer) |thread| {
            if (comptime @import("builtin").os.tag == .windows) {
                const synchronous_file = if (stdin) |stream| switch (stream) {
                    .file => true,
                    .win_pipe => false,
                } else false;
                if (synchronous_file) {
                    while (!self.writer_exited.load(.acquire)) {
                        var io_status: std.os.windows.IO_STATUS_BLOCK = undefined;
                        _ = std.os.windows.ntdll.NtCancelSynchronousIoFile(thread.getHandle(), null, &io_status);
                        std.Io.sleep(clock.io(), .{ .nanoseconds = std.time.ns_per_ms }, .awake) catch {};
                    }
                }
            }
            thread.join();
        }
    }

    pub fn sendRaw(self: *Core, bytes: []const u8) !void {
        return self.sendRawClassified(bytes, .normal);
    }

    fn sendUiStateRaw(self: *Core, bytes: []const u8) !void {
        return self.sendRawClassified(bytes, .ui_state);
    }

    fn sendRawClassified(self: *Core, bytes: []const u8, class: WriteClass) !void {
        // Don't attempt writes during shutdown (avoids sync fallback re-block)
        if (self.stop_flag.load(.seq_cst)) return error.BrokenPipe;

        // SSH mode: wait if authentication is pending (block RPC sends until password is entered)
        if (self.is_ssh_mode and self.ssh_auth_pending.load(.seq_cst)) {
            self.log.write("sendRaw: blocked during SSH auth, waiting...\n", .{});
            while (self.ssh_auth_pending.load(.seq_cst) and !self.stop_flag.load(.seq_cst)) {
                std.Io.sleep(clock.io(), .{ .nanoseconds = @intCast(50 * std.time.ns_per_ms) }, .awake) catch {};
            }
            if (self.stop_flag.load(.seq_cst)) {
                return error.BrokenPipe;
            }
            self.log.write("sendRaw: SSH auth done, proceeding\n", .{});
        }

        // Check writer thread state under lock to avoid data race with stop()/startWriterThread()
        self.write_queue_mu.lockUncancelable(clock.io());

        if (self.writer_thread != null) {
            // Writer thread is active → enqueue (non-blocking path)
            if (self.writer_failed or self.write_queue_closed) {
                self.write_queue_mu.unlock(clock.io());
                return error.BrokenPipe;
            }

            self.enqueueRawLocked(bytes, class) catch |e| {
                self.write_queue_mu.unlock(clock.io());
                return e;
            };
            self.write_queue_cond.signal(clock.io());
            self.write_queue_mu.unlock(clock.io());
            return;
        }

        self.write_queue_mu.unlock(clock.io());

        // RPC writes must never fall back to a blocking caller-thread write:
        // teardown could otherwise neither cancel it safely nor prevent raw
        // descriptor reuse. Session setup fails if the writer cannot start.
        return error.BrokenPipe;
    }

    /// Append one complete RPC while write_queue_mu is held.
    fn enqueueRawLocked(self: *Core, bytes: []const u8, class: WriteClass) !void {
        switch (class) {
            .normal => {
                if (bytes.len > MAX_WRITE_QUEUE_SIZE or
                    bytes.len > MAX_WRITE_QUEUE_SIZE - self.write_queue_normal_bytes)
                {
                    self.log.write("sendRaw: normal write queue full ({d} bytes), dropping\n", .{
                        self.write_queue_normal_bytes,
                    });
                    return error.OutOfMemory;
                }

                const new_normal_bytes = self.write_queue_normal_bytes + bytes.len;
                const required_capacity = new_normal_bytes + UI_STATE_WRITE_RESERVE_SIZE;
                if (self.write_queue.capacity < required_capacity) {
                    var target_capacity = @max(self.write_queue.capacity, UI_STATE_WRITE_RESERVE_SIZE);
                    while (target_capacity < required_capacity) {
                        target_capacity = @min(MAX_TOTAL_WRITE_QUEUE_SIZE, target_capacity * 2);
                    }
                    self.write_queue.ensureTotalCapacityPrecise(self.alloc, target_capacity) catch {
                        return error.OutOfMemory;
                    };
                }

                self.write_queue.appendSliceAssumeCapacity(bytes);
                self.write_queue_normal_bytes = new_normal_bytes;
            },
            .ui_state => {
                if (bytes.len > UI_STATE_WRITE_RESERVE_SIZE or
                    bytes.len > UI_STATE_WRITE_RESERVE_SIZE - self.write_queue_ui_state_bytes)
                {
                    self.log.write("sendRaw: UI-state write reserve full ({d} bytes), dropping\n", .{
                        self.write_queue_ui_state_bytes,
                    });
                    return error.OutOfMemory;
                }

                // Every active buffer starts with the full reserve, and normal
                // growth always preserves the unused part. This append cannot
                // allocate or be displaced by normal traffic.
                std.debug.assert(
                    self.write_queue.items.len + bytes.len <= self.write_queue.capacity,
                );
                self.write_queue.appendSliceAssumeCapacity(bytes);
                self.write_queue_ui_state_bytes += bytes.len;
            },
        }
    }

    pub fn nextMsgId(self: *Core) i64 {
        return self.msgid.fetchAdd(1, .seq_cst);
    }

    pub fn sendRequestHeader(self: *Core, buf: *rpc.Buf, id: i64, method: []const u8) !void {
        try packRequestHeader(buf, self.alloc, id, method);
    }

    fn packRequestHeader(
        buf: *rpc.Buf,
        alloc: std.mem.Allocator,
        id: i64,
        method: []const u8,
    ) !void {
        try rpc.packArray(buf, alloc, 4);
        try rpc.packInt(buf, alloc, 0);
        try rpc.packInt(buf, alloc, id);
        try rpc.packStr(buf, alloc, method);
    }

    pub fn sendNotificationHeader(self: *Core, buf: *rpc.Buf, method: []const u8) !void {
        try rpc.packArray(buf, self.alloc, 3);
        try rpc.packInt(buf, self.alloc, 2); // msgtype=2 (notification)
        try rpc.packStr(buf, self.alloc, method);
    }

    pub fn requestGetApiInfo(self: *Core) !void {
        const id = self.nextMsgId();
        self.get_api_info_msgid = id; // Save msgid for response matching
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

    fn packUiAttachParams(self: *Core, buf: *rpc.Buf, rows: u32, cols: u32) !void {
        try rpc.packArray(buf, self.alloc, 3);
        try rpc.packInt(buf, self.alloc, @as(i64, @intCast(cols)));
        try rpc.packInt(buf, self.alloc, @as(i64, @intCast(rows)));

        // Option count: ext_multigrid, rgb (always) + optional ext_*
        var opt_count: u32 = 2;
        if (self.ext_windows_enabled) opt_count += 1;
        if (self.ext_cmdline_enabled) opt_count += 1;
        if (self.ext_popupmenu_enabled) opt_count += 1;
        if (self.ext_messages_enabled) opt_count += 1;
        if (self.ext_tabline_enabled) opt_count += 1;
        try rpc.packMap(buf, self.alloc, opt_count);
        try rpc.packStr(buf, self.alloc, "ext_multigrid");
        try rpc.packBool(buf, self.alloc, true);
        try rpc.packStr(buf, self.alloc, "rgb");
        try rpc.packBool(buf, self.alloc, true);

        if (self.ext_windows_enabled) {
            try rpc.packStr(buf, self.alloc, "ext_windows");
            try rpc.packBool(buf, self.alloc, true);
        }

        if (self.ext_cmdline_enabled) {
            try rpc.packStr(buf, self.alloc, "ext_cmdline");
            try rpc.packBool(buf, self.alloc, true);
        }

        if (self.ext_popupmenu_enabled) {
            try rpc.packStr(buf, self.alloc, "ext_popupmenu");
            try rpc.packBool(buf, self.alloc, true);
        }

        if (self.ext_messages_enabled) {
            try rpc.packStr(buf, self.alloc, "ext_messages");
            try rpc.packBool(buf, self.alloc, true);
        }

        if (self.ext_tabline_enabled) {
            try rpc.packStr(buf, self.alloc, "ext_tabline");
            try rpc.packBool(buf, self.alloc, true);
        }
    }

    pub fn requestUiAttach(self: *Core, rows: u32, cols: u32) !void {
        var buf: rpc.Buf = .empty;
        defer buf.deinit(self.alloc);

        try self.sendNotificationHeader(&buf, "nvim_ui_attach");
        try self.packUiAttachParams(&buf, rows, cols);

        try self.sendRaw(buf.items);

        self.log.write("rpc send: nvim_ui_attach (notification, rows={d}, cols={d}, ext_cmdline={any}, ext_popupmenu={any}, ext_messages={any}, ext_tabline={any}, ext_windows={any})\n", .{ rows, cols, self.ext_cmdline_enabled, self.ext_popupmenu_enabled, self.ext_messages_enabled, self.ext_tabline_enabled, self.ext_windows_enabled });
    }

    /// Tracked variants are used only by redraw recovery. Neovim flushes any
    /// pending UI bytes before serializing an RPC response on the same channel,
    /// which makes the detach response a strict old-epoch boundary and the
    /// attach response a completion marker for the fresh full-state replay.
    pub fn requestUiDetachTracked(self: *Core) !i64 {
        const id = self.nextMsgId();
        var buf: rpc.Buf = .empty;
        defer buf.deinit(self.alloc);

        try self.sendRequestHeader(&buf, id, "nvim_ui_detach");
        try rpc.packArray(&buf, self.alloc, 0);
        try self.sendRaw(buf.items);
        return id;
    }

    pub fn requestUiAttachTracked(self: *Core, rows: u32, cols: u32) !i64 {
        const id = self.nextMsgId();
        var buf: rpc.Buf = .empty;
        defer buf.deinit(self.alloc);

        try self.sendRequestHeader(&buf, id, "nvim_ui_attach");
        try self.packUiAttachParams(&buf, rows, cols);
        try self.sendRaw(buf.items);
        return id;
    }

    /// Notify Neovim of window focus change via nvim_ui_set_focus.
    /// Triggers FocusGained/FocusLost autocommands in Neovim.
    /// If called before nvim_ui_attach, the focus state is deferred and
    /// sent automatically once the UI session is established.
    pub fn requestUiSetFocus(self: *Core, gained: bool) void {
        // Serialize the attached check, pending publication, and delivery with
        // attach completion. This prevents a stale false observation from
        // publishing pending focus after the attach thread already drained it.
        self.pending_resize_mu.lockUncancelable(clock.io());
        defer self.pending_resize_mu.unlock(clock.io());

        self.pending_focus.store(if (gained) 1 else 2, .seq_cst);
        self.pending_focus_sequence = self.nextPendingUiStateSequenceLocked();
        if (!self.ui_attached.load(.seq_cst)) {
            self.log.write("requestUiSetFocus: deferred (gained={any})\n", .{gained});
            return;
        }
        self.flushPendingUiStateLocked();
    }

    fn requestUiSetFocusInternal(self: *Core, gained: bool) !void {
        const id = self.nextMsgId();
        var storage: [UI_STATE_RPC_STACK_SIZE]u8 = undefined;
        var fixed = std.heap.FixedBufferAllocator.init(&storage);
        const fixed_alloc = fixed.allocator();
        var buf: rpc.Buf = .empty;
        defer buf.deinit(fixed_alloc);

        try packRequestHeader(&buf, fixed_alloc, id, "nvim_ui_set_focus");

        try rpc.packArray(&buf, fixed_alloc, 1);
        try rpc.packBool(&buf, fixed_alloc, gained);

        try self.sendUiStateRaw(buf.items);

        self.log.write("rpc send: nvim_ui_set_focus (id={d}, gained={any})\n", .{ id, gained });
    }

    fn nextPendingUiStateSequenceLocked(self: *Core) u64 {
        self.pending_ui_state_sequence +%= 1;
        if (self.pending_ui_state_sequence == 0) self.pending_ui_state_sequence = 1;
        return self.pending_ui_state_sequence;
    }

    /// Drain deferred focus/resize in their original publication order. The
    /// caller holds pending_resize_mu, so a newer UI event cannot replace a
    /// record between selection and its FIFO enqueue.
    pub fn flushPendingUiStateLocked(self: *Core) void {
        while (true) {
            const focus = self.pending_focus.load(.seq_cst);
            const have_resize = self.pending_resize_valid;
            if (focus == 0 and !have_resize) return;

            const send_resize = have_resize and
                (focus == 0 or self.pending_resize_sequence < self.pending_focus_sequence);
            if (send_resize) {
                const rows = self.pending_resize_rows;
                const cols = self.pending_resize_cols;
                self.requestTryResize(rows, cols) catch |e| {
                    self.log.write(
                        "pending resize send failed: {any} rows={d} cols={d}\n",
                        .{ e, rows, cols },
                    );
                    return;
                };
                self.pending_resize_valid = false;
                self.pending_resize_sequence = 0;
                continue;
            }

            self.requestUiSetFocusInternal(focus == 1) catch |e| {
                self.log.write("pending focus send failed: {any}\n", .{e});
                return;
            };
            self.pending_focus.store(0, .seq_cst);
            self.pending_focus_sequence = 0;
        }
    }

    pub fn requestTryResize(self: *Core, rows: u32, cols: u32) !void {
        const id = self.nextMsgId();
        var storage: [UI_STATE_RPC_STACK_SIZE]u8 = undefined;
        var fixed = std.heap.FixedBufferAllocator.init(&storage);
        const fixed_alloc = fixed.allocator();
        var buf: rpc.Buf = .empty;
        defer buf.deinit(fixed_alloc);

        try packRequestHeader(&buf, fixed_alloc, id, "nvim_ui_try_resize");

        try rpc.packArray(&buf, fixed_alloc, 2);
        try rpc.packInt(&buf, fixed_alloc, @as(i64, @intCast(cols)));
        try rpc.packInt(&buf, fixed_alloc, @as(i64, @intCast(rows)));

        try self.sendUiStateRaw(buf.items);

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
    /// Show (or update) the message split. Modelled on noice.nvim's
    /// `NuiView:show()` (`view/nui.lua:274-289`): mounting and rendering are
    /// independent, so a second message updates the existing split instead of
    /// being dropped, and stale handles are repaired rather than trusted
    /// (`view/nui.lua:249-272`).
    ///
    /// There is deliberately no `BufLeave` auto-close. noice attaches that to
    /// popups but not to splits (`config/views.lua:99-106` vs `:73-86`): a
    /// split you are meant to enter must survive being left.
    ///
    /// `return_prompt` is answered by the caller at the event layer, so this
    /// no longer feeds a second `<CR>` of its own.
    ///
    /// `timeout_ms` of 0 means the split stays until dismissed. Otherwise the
    /// timer is restarted on every show and stopped on close, mirroring
    /// noice's `NuiView:autohide()` (`view/nui.lua:24-35`, called at the end of
    /// `show()`); noice applies it to splits as well as popups.
    pub fn createMessageSplit(
        self: *Core,
        content: []const u8,
        line_count: u32,
        enter: bool,
        timeout_ms: u32,
    ) !void {
        // Overflow here surfaces as error.NoSpaceLeft, which callers only log,
        // so the split would silently stop appearing. Keep generous headroom.
        var lua_buf: [split_lua_buf_len]u8 = undefined;
        const lua_code = try buildSplitLua(&lua_buf, line_count, enter, timeout_ms);

        // Send nvim_exec_lua with content as argument
        try self.requestExecLuaWithArg(lua_code, content);
        self.log.write("rpc send: createMessageSplit (lines={d}, height={d}, enter={any}, timeout_ms={d})\n", .{ line_count, splitHeight(line_count), enter, timeout_ms });
    }

    /// Buffer size `buildSplitLua` is written against. Exposed so a test can
    /// check the template still fits with headroom rather than discovering
    /// error.NoSpaceLeft in production, where it is only logged. 16 KiB:
    /// the template grew past half of 8 KiB when the enter/leave timer
    /// autocmds were added, and the headroom test demands ≥2x slack.
    pub const split_lua_buf_len = 16384;

    /// Window height for the split: at least one line, at most 20.
    pub fn splitHeight(line_count: u32) u32 {
        return @max(1, @min(line_count, 20));
    }

    /// Render the split-view Lua into `buf`. Pure: no Core, no I/O, so the
    /// generated program can be asserted on directly. Everything the split
    /// does — whether it takes focus, whether it auto-hides, how it closes —
    /// is decided by this text, and previously nothing checked it.
    ///
    /// Keep explanation in Zig comments like this one rather than inside the
    /// `\\` literal: comments in there are RPC payload, re-sent and re-lexed
    /// on every split, and they spend the buffer budget below.
    ///
    /// Two QuitPre limits are accepted rather than worked around, both from
    /// its own semantics (measured against nvim 0.12.2):
    ///   * QuitPre fires before the can-quit check, so a `:q` that then
    ///     aborts (E37, no write since last change) has still closed the
    ///     split. Declining would mean predicting the abort, and guessing
    ///     from 'modified' gets `:q!` wrong in the direction that strands
    ///     the split as the session's last window.
    ///   * `:close` and `:tabclose` do not fire QuitPre at all, so they can
    ///     still leave the split as the last window. Not a lock: `:q` there
    ///     takes the `cur == state.win` branch and Neovim exits normally.
    /// Nothing user-controlled is interpolated into the program below: only
    /// integers and two literal booleans. The message text travels as a
    /// msgpack argument, never as source. Keep it that way — a formatted
    /// string here would need Lua-literal escaping to stay injection-safe.
    pub fn buildSplitLua(
        buf: []u8,
        line_count: u32,
        enter: bool,
        timeout_ms: u32,
    ) ![]const u8 {
        const height = splitHeight(line_count);
        const enter_str = if (enter) "true" else "false";
        return std.fmt.bufPrint(buf,
            \\local content = ...
            \\local height = {d}
            \\local enter = {s}
            \\local timeout = {d}
            \\local uv = vim.uv or vim.loop
            \\local function show()
            \\  local state = _G._zonvie_msg_split or {{}}
            \\  _G._zonvie_msg_split = state
            \\  -- Repair stale handles instead of trusting them.
            \\  if state.buf and not vim.api.nvim_buf_is_valid(state.buf) then state.buf = nil end
            \\  if state.win and not vim.api.nvim_win_is_valid(state.win) then state.win = nil end
            \\  local function stop_timer()
            \\    -- Bumping the generation invalidates any close that
            \\    -- schedule_wrap has already queued: stopping the handle
            \\    -- cannot retract an entry that is waiting to drain.
            \\    state.gen = (state.gen or 0) + 1
            \\    if state.timer then
            \\      state.timer:stop()
            \\      if not state.timer:is_closing() then state.timer:close() end
            \\      state.timer = nil
            \\    end
            \\  end
            \\  local function close()
            \\    stop_timer()
            \\    if state.win and vim.api.nvim_win_is_valid(state.win) then
            \\      pcall(vim.api.nvim_win_close, state.win, true)
            \\    end
            \\    state.win = nil
            \\  end
            \\  state.close = close
            \\  state.timeout = timeout
            \\  local function arm_timer()
            \\    stop_timer()
            \\    if state.timeout > 0 then
            \\      local gen = state.gen
            \\      state.timer = uv.new_timer()
            \\      state.timer:start(state.timeout, 0, vim.schedule_wrap(function()
            \\        if state.gen == gen then state.close() end
            \\      end))
            \\    end
            \\  end
            \\  if not state.buf then
            \\    local ok, buf = pcall(vim.api.nvim_create_buf, false, true)
            \\    if not ok then return end
            \\    state.buf = buf
            \\    pcall(function()
            \\      vim.bo[buf].buftype = 'nofile'
            \\      vim.bo[buf].bufhidden = 'hide'
            \\      vim.bo[buf].buflisted = false
            \\    end)
            \\  end
            \\  -- A window that no longer shows our buffer is not ours to
            \\  -- reuse: the buffer was wiped (`:bd!`), or the user opened a
            \\  -- file in the split. Forget it and mount a fresh split rather
            \\  -- than seating our buffer back into it — re-seating would
            \\  -- hijack the user's window, and the keymaps and pause
            \\  -- autocmds only get registered on the mount path, so the
            \\  -- result would be a split that `q` and `<Esc>` cannot close.
            \\  if state.win and vim.api.nvim_win_get_buf(state.win) ~= state.buf then
            \\    state.win = nil
            \\  end
            \\  local lines = vim.split((content:gsub('\r', '')), '\n')
            \\  -- Always re-render: content is independent of mount state.
            \\  vim.bo[state.buf].modifiable = true
            \\  pcall(vim.api.nvim_buf_set_lines, state.buf, 0, -1, false, lines)
            \\  vim.bo[state.buf].modifiable = false
            \\  if not state.win then
            \\    local ok, win = pcall(vim.api.nvim_open_win, state.buf, enter, {{
            \\      split = 'below',
            \\      height = height,
            \\    }})
            \\    if not ok then return end
            \\    state.win = win
            \\    pcall(function() vim.wo[win].wrap = true end)
            \\    for _, key in ipairs({{ 'q', '<Esc>' }}) do
            \\      vim.keymap.set('n', key, function() state.close() end,
            \\        {{ buffer = state.buf, silent = true, nowait = true }})
            \\    end
            \\    local grp = vim.api.nvim_create_augroup('ZonvieMsgSplit', {{ clear = true }})
            \\    vim.api.nvim_create_autocmd('WinClosed', {{
            \\      group = grp, pattern = tostring(win), once = true,
            \\      -- Closing the split while the cursor is inside fires
            \\      -- BufLeave first, which re-arms a fresh timer. Nothing
            \\      -- would ever close that handle: measured with uv.walk, one
            \\      -- libuv timer leaked per split close. (The generation token
            \\      -- already stops the orphan from closing a later split, so
            \\      -- this is a handle-leak fix, not a correctness one.)
            \\      callback = function() stop_timer() state.win = nil end,
            \\    }})
            \\    -- Zonvie addition (noice has no equivalent): the split must
            \\    -- not be what keeps Neovim alive. On the last real window,
            \\    -- close it first so `:q` still quits.
            \\    vim.api.nvim_create_autocmd('QuitPre', {{
            \\      group = grp,
            \\      callback = function()
            \\        if not (state.win and vim.api.nvim_win_is_valid(state.win)) then return end
            \\        local cur = vim.api.nvim_get_current_win()
            \\        -- Quitting the split itself: Neovim is already closing
            \\        -- that window, so let it, and let WinClosed sync the
            \\        -- state. Defensive — on 0.12.2 closing it here is
            \\        -- tolerated (the quit simply aborts), but nothing in the
            \\        -- API promises that.
            \\        if cur == state.win then return end
            \\        -- Quitting a float never ends the session, and floats are
            \\        -- not counted below, so acting on one would close the
            \\        -- split spuriously — dismissing an LSP hover with `:q`
            \\        -- took the split with it. Checked before every close
            \\        -- decision, including the alone-in-its-tabpage one.
            \\        if vim.api.nvim_win_get_config(cur).relative ~= '' then return end
            \\        -- Count the real windows sharing the SPLIT's tabpage,
            \\        -- which is not necessarily the quitting one.
            \\        local split_tab = vim.api.nvim_win_get_tabpage(state.win)
            \\        local others = 0
            \\        for _, w in ipairs(vim.api.nvim_tabpage_list_wins(split_tab)) do
            \\          if w ~= state.win and vim.api.nvim_win_get_config(w).relative == '' then
            \\            others = others + 1
            \\          end
            \\        end
            \\        -- The split is alone in its tabpage, so it can never be
            \\        -- what the user wants to keep — but only act when THIS
            \\        -- quit would actually leave it as the session's last
            \\        -- window: the quitting window must be the last real one
            \\        -- in its own tabpage, and that tabpage the last besides
            \\        -- the split's. Closing unconditionally instead destroyed
            \\        -- a whole tabpage on a `:q` that left windows behind;
            \\        -- guarding on the tabpage match instead let `:q` in the
            \\        -- last other tab leave the split as the only window.
            \\        if others == 0 then
            \\          local cur_tab = vim.api.nvim_get_current_tabpage()
            \\          local cur_others = 0
            \\          for _, w in ipairs(vim.api.nvim_tabpage_list_wins(cur_tab)) do
            \\            if w ~= cur and vim.api.nvim_win_get_config(w).relative == '' then
            \\              cur_others = cur_others + 1
            \\            end
            \\          end
            \\          if cur_others == 0 and #vim.api.nvim_list_tabpages() <= 2 then state.close() end
            \\          return
            \\        end
            \\        -- Beyond that the split only matters to a quit in its own
            \\        -- tabpage: the count above is per-tabpage, so acting on a
            \\        -- `:q` elsewhere would close a split it never needed to.
            \\        if split_tab ~= vim.api.nvim_get_current_tabpage() then return end
            \\        if others <= 1 then state.close() end
            \\      end,
            \\    }})
            \\    -- The cursor entering the split pauses the auto-hide
            \\    -- countdown (the user is reading it); leaving re-arms the
            \\    -- full timeout. This BufLeave only re-arms a timer — it
            \\    -- never closes the window.
            \\    vim.api.nvim_create_autocmd('BufEnter', {{
            \\      group = grp, buffer = state.buf,
            \\      callback = function() stop_timer() end,
            \\    }})
            \\    vim.api.nvim_create_autocmd('BufLeave', {{
            \\      group = grp, buffer = state.buf,
            \\      callback = function() arm_timer() end,
            \\    }})
            \\  else
            \\    pcall(vim.api.nvim_win_set_height, state.win, height)
            \\  end
            \\  if state.win and vim.api.nvim_win_is_valid(state.win) then
            \\    pcall(vim.api.nvim_win_set_cursor, state.win, {{ 1, 0 }})
            \\    -- enter applies on EVERY show, not just the mount:
            \\    -- nvim_open_win only takes focus when it creates the
            \\    -- window, so a re-show into a live split must move the
            \\    -- cursor itself. Runs before the arming decision below so
            \\    -- the pause logic sees the final cursor location.
            \\    if enter and vim.api.nvim_get_current_win() ~= state.win then
            \\      pcall(vim.api.nvim_set_current_win, state.win)
            \\    end
            \\  end
            \\  -- Restart the auto-hide timer on every show, unless the
            \\  -- cursor currently sits inside the split — the user is
            \\  -- reading it, so the countdown stays paused until they leave.
            \\  if state.win and vim.api.nvim_get_current_win() == state.win then
            \\    stop_timer()
            \\  else
            \\    arm_timer()
            \\  end
            \\end
            \\vim.schedule(show)
        , .{ height, enter_str, timeout_ms });
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
        if (self.msg_config.input.ime_preedit_mode != .extmark) return false;

        // Read the current mode under grid_mu, but keep the critical section
        // tiny: never send RPC (alloc + write-queue lock + possible blocking
        // write) while holding grid_mu, which is shared with the redraw thread.
        var editing = false;
        {
            self.grid_mu.lockUncancelable(clock.io());
            defer self.grid_mu.unlock(clock.io());
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
            self.grid_mu.lockUncancelable(clock.io());
            defer self.grid_mu.unlock(clock.io());
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

    pub fn setGestureSmoothScroll(self: *Core, grid_id: i64, enable: bool) bool {
        return rpc_session.setGestureSmoothScroll(self, grid_id, enable);
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
        _ = flush.sendCmdlineBlockShow(self, current_line_visible, visible_level);
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
        _ = flush.sendPopupmenuShow(self);
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

    pub fn renderMsgGridFromCache(self: *Core, scroll_offset: u32) bool {
        return flush.renderMsgGridFromCache(self, scroll_offset);
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
        _ = flush.sendMsgHistoryShow(self);
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
        self.rpc_thread_id.store(@intCast(std.Thread.getCurrentId()), .release);
        defer self.rpc_thread_id.store(0, .release);
        rpc_session.runLoop(self);
    }
};

fn checkScrollLedgerResizeAllocationFailure(alloc: std.mem.Allocator) !void {
    var core = Core.initForTest(alloc);
    defer core.deinitForTest();
    try core.ensureScrollCache(2);
    @memcpy(core.main_vertex_row_counts.items, &[_]usize{ 11, 22 });

    core.ensureScrollCache(64) catch |err| {
        try std.testing.expectEqualSlices(
            usize,
            &.{ 11, 22 },
            core.main_vertex_row_counts.items[0..2],
        );
        if (core.main_vertex_row_counts.items.len > 2) {
            for (core.main_vertex_row_counts.items[2..]) |count| {
                try std.testing.expectEqual(@as(usize, 0), count);
            }
        }
        return err;
    };
}

test "scroll ledger resize remains initialized on allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        checkScrollLedgerResizeAllocationFailure,
        .{},
    );
}

test "scroll ledger structural changes keep vertex aggregate synchronized" {
    var core = Core.initForTest(std.testing.allocator);
    defer core.deinitForTest();

    try core.ensureScrollCache(3);
    @memcpy(core.main_vertex_row_counts.items, &[_]usize{ 11, 22, 33 });
    core.main_surface_vertex_count = 66;
    core.flush_vertex_count_aggregate = 166;

    try core.ensureScrollCache(2);
    try std.testing.expectEqual(@as(usize, 33), core.main_surface_vertex_count);
    try std.testing.expectEqual(@as(usize, 133), core.flush_vertex_count_aggregate);

    core.invalidateScrollCache();
    try std.testing.expectEqual(@as(usize, 0), core.main_surface_vertex_count);
    try std.testing.expectEqual(@as(usize, 100), core.flush_vertex_count_aggregate);
}

const AtlasFailureTestState = struct {
    core: *Core,
    raster_calls: u32 = 0,
    upload_calls: u32 = 0,
    create_calls: u32 = 0,
    abort_upload: bool = false,
    abort_create: bool = false,
    abort_raster: bool = false,
    raster_miss: bool = false,

    fn rasterize(
        ctx: ?*anyopaque,
        scalar: u32,
        style_flags: u32,
        out_bitmap: *c_api.GlyphBitmap,
    ) callconv(.c) c_int {
        _ = scalar;
        _ = style_flags;
        const self: *@This() = @ptrCast(@alignCast(ctx.?));
        self.raster_calls += 1;
        out_bitmap.* = .{
            .pixels = null,
            .width = 1,
            .height = 1,
            .pitch = 1,
            .bearing_x = 0,
            .bearing_y = 1,
            .advance_26_6 = 64,
            .ascent_px = 1,
            .descent_px = 0,
            .bytes_per_pixel = 1,
        };
        if (self.abort_raster) self.core.flush_aborted = true;
        return if (self.raster_miss) 0 else 1;
    }

    fn upload(
        ctx: ?*anyopaque,
        dest_x: u32,
        dest_y: u32,
        width: u32,
        height: u32,
        bitmap: *const c_api.GlyphBitmap,
    ) callconv(.c) void {
        _ = dest_x;
        _ = dest_y;
        _ = width;
        _ = height;
        _ = bitmap;
        const self: *@This() = @ptrCast(@alignCast(ctx.?));
        self.upload_calls += 1;
        if (self.abort_upload) self.core.flush_aborted = true;
    }

    fn create(ctx: ?*anyopaque, atlas_w: u32, atlas_h: u32) callconv(.c) void {
        _ = atlas_w;
        _ = atlas_h;
        const self: *@This() = @ptrCast(@alignCast(ctx.?));
        self.create_calls += 1;
        if (self.abort_create) self.core.flush_aborted = true;
    }
};

const AsciiPreloadTestState = struct {
    core: *Core,
    table_calls: u32 = 0,
    raster_calls: u32 = 0,
    scalar_calls: u32 = 0,
    upload_calls: u32 = 0,
    create_calls: u32 = 0,
    abort_table_after: u32 = 0,
    abort_raster_after: u32 = 0,
    by_id_miss: bool = false,

    fn getTable(
        ctx: ?*anyopaque,
        style_flags: u32,
        out_glyph_ids: [*]u32,
        out_x_advances: [*]i32,
        out_lig_triggers: [*]u8,
    ) callconv(.c) c_int {
        const self: *@This() = @ptrCast(@alignCast(ctx.?));
        self.table_calls += 1;
        @memset(out_glyph_ids[0..128], 0);
        @memset(out_x_advances[0..128], 64);
        @memset(out_lig_triggers[0..128], 0);
        const style_index: u32 =
            @as(u32, if (style_flags & c_api.STYLE_BOLD != 0) 1 else 0) +
            @as(u32, if (style_flags & c_api.STYLE_ITALIC != 0) 2 else 0);
        out_glyph_ids['A'] = 100 + style_index;
        if (self.abort_table_after != 0 and self.table_calls == self.abort_table_after) {
            self.core.flush_aborted = true;
        }
        return 1;
    }

    fn rasterizeById(
        ctx: ?*anyopaque,
        glyph_id: u32,
        style_flags: u32,
        out_bitmap: *c_api.GlyphBitmap,
    ) callconv(.c) c_int {
        _ = glyph_id;
        _ = style_flags;
        const self: *@This() = @ptrCast(@alignCast(ctx.?));
        self.raster_calls += 1;
        out_bitmap.* = .{
            .pixels = null,
            .width = 1,
            .height = 1,
            .pitch = 1,
            .bearing_x = 0,
            .bearing_y = 1,
            .advance_26_6 = 64,
            .ascent_px = 1,
            .descent_px = 0,
            .bytes_per_pixel = 1,
        };
        if (self.abort_raster_after != 0 and self.raster_calls == self.abort_raster_after) {
            self.core.flush_aborted = true;
        }
        return if (self.by_id_miss) 0 else 1;
    }

    fn rasterizeScalar(
        ctx: ?*anyopaque,
        scalar: u32,
        style_flags: u32,
        out_bitmap: *c_api.GlyphBitmap,
    ) callconv(.c) c_int {
        _ = scalar;
        _ = style_flags;
        const self: *@This() = @ptrCast(@alignCast(ctx.?));
        self.scalar_calls += 1;
        out_bitmap.* = .{
            .pixels = null,
            .width = 1,
            .height = 1,
            .pitch = 1,
            .bearing_x = 0,
            .bearing_y = 1,
            .advance_26_6 = 64,
            .ascent_px = 1,
            .descent_px = 0,
            .bytes_per_pixel = 1,
        };
        return 1;
    }

    fn upload(
        ctx: ?*anyopaque,
        dest_x: u32,
        dest_y: u32,
        width: u32,
        height: u32,
        bitmap: *const c_api.GlyphBitmap,
    ) callconv(.c) void {
        _ = dest_x;
        _ = dest_y;
        _ = width;
        _ = height;
        _ = bitmap;
        const self: *@This() = @ptrCast(@alignCast(ctx.?));
        self.upload_calls += 1;
    }

    fn create(ctx: ?*anyopaque, atlas_w: u32, atlas_h: u32) callconv(.c) void {
        _ = atlas_w;
        _ = atlas_h;
        const self: *@This() = @ptrCast(@alignCast(ctx.?));
        self.create_calls += 1;
    }
};

test "glyph cache two-choice probe preserves a primary collision" {
    var keys = [_]u64{GLYPH_CACHE_INVALID_KEY} ** 8;
    const hash: u64 = 3;
    const key_a: u64 = 0x100;
    const probe_a = glyphCacheProbe(&keys, key_a, hash);
    keys[probe_a.insert] = key_a;

    var key_b: u64 = key_a + 1;
    var probe_b = glyphCacheProbe(&keys, key_b, hash);
    while (probe_b.insert == probe_a.insert) : (key_b += 1) {
        probe_b = glyphCacheProbe(&keys, key_b, hash);
    }
    keys[probe_b.insert] = key_b;

    try std.testing.expectEqual(probe_a.insert, glyphCacheProbe(&keys, key_a, hash).hit.?);
    try std.testing.expectEqual(probe_b.insert, glyphCacheProbe(&keys, key_b, hash).hit.?);
}

test "aborted atlas upload rolls back shelf allocation" {
    var core = Core.initForTest(std.testing.allocator);
    defer core.deinitForTest();
    var state = AtlasFailureTestState{ .core = &core, .abort_upload = true };
    core.ctx = &state;
    core.cb.on_rasterize_glyph = AtlasFailureTestState.rasterize;
    core.cb.on_atlas_upload = AtlasFailureTestState.upload;
    core.cb.on_atlas_create = AtlasFailureTestState.create;

    try std.testing.expect(core.ensureGlyphPhase2('A', 0) == null);
    const after_first = core.atlas_packer.?;
    try std.testing.expectEqual(@as(u32, 1), after_first.next_x);
    try std.testing.expectEqual(@as(u32, 1), after_first.next_y);
    try std.testing.expectEqual(@as(u32, 0), after_first.row_h);

    core.flush_aborted = false;
    try std.testing.expect(core.ensureGlyphPhase2('A', 0) == null);
    const after_second = core.atlas_packer.?;
    try std.testing.expectEqual(after_first.next_x, after_second.next_x);
    try std.testing.expectEqual(after_first.next_y, after_second.next_y);
    try std.testing.expectEqual(after_first.row_h, after_second.row_h);
    try std.testing.expectEqual(@as(u32, 2), state.upload_calls);
}

test "atlas create abort stops raster and retries creation" {
    var core = Core.initForTest(std.testing.allocator);
    defer core.deinitForTest();
    var state = AtlasFailureTestState{ .core = &core, .abort_create = true };
    core.ctx = &state;
    core.cb.on_rasterize_glyph = AtlasFailureTestState.rasterize;
    core.cb.on_atlas_upload = AtlasFailureTestState.upload;
    core.cb.on_atlas_create = AtlasFailureTestState.create;

    try std.testing.expect(core.ensureGlyphPhase2('A', 0) == null);
    try std.testing.expectEqual(@as(u32, 1), state.create_calls);
    try std.testing.expectEqual(@as(u32, 0), state.raster_calls);
    try std.testing.expectEqual(@as(u32, 0), state.upload_calls);
    try std.testing.expect(!core.atlas_initialized);
    try std.testing.expect(core.atlas_packer == null);

    state.abort_create = false;
    core.flush_aborted = false;
    try std.testing.expect(core.ensureGlyphPhase2('A', 0) != null);
    try std.testing.expectEqual(@as(u32, 2), state.create_calls);
    try std.testing.expectEqual(@as(u32, 1), state.raster_calls);
    try std.testing.expectEqual(@as(u32, 1), state.upload_calls);
}

test "atlas reset create abort stops before upload" {
    var core = Core.initForTest(std.testing.allocator);
    defer core.deinitForTest();
    var state = AtlasFailureTestState{ .core = &core };
    core.ctx = &state;
    core.cb.on_rasterize_glyph = AtlasFailureTestState.rasterize;
    core.cb.on_atlas_upload = AtlasFailureTestState.upload;
    core.cb.on_atlas_create = AtlasFailureTestState.create;

    try std.testing.expect(core.ensureGlyphPhase2('A', 0) != null);
    const uploads_before = state.upload_calls;
    core.atlas_w = config.atlas_size_max;
    core.atlas_h = config.atlas_size_max;
    core.atlas_packer = shelf_packer.ShelfPacker.init(core.atlas_w, core.atlas_h);
    core.atlas_packer.?.next_y = config.atlas_size_max;
    core.atlas_full_resets_this_flush = 0;
    state.abort_create = true;

    try std.testing.expect(core.ensureGlyphPhase2('B', 0) == null);
    try std.testing.expectEqual(uploads_before, state.upload_calls);
    try std.testing.expect(!core.atlas_initialized);
    try std.testing.expect(core.atlas_packer == null);
}

test "rasterizer miss returns a cacheable blank while explicit abort stays null" {
    var core = Core.initForTest(std.testing.allocator);
    defer core.deinitForTest();
    var state = AtlasFailureTestState{ .core = &core, .raster_miss = true };
    core.ctx = &state;
    core.cb.on_rasterize_glyph = AtlasFailureTestState.rasterize;
    core.cb.on_rasterize_glyph_by_id = AtlasFailureTestState.rasterize;
    core.cb.on_atlas_upload = AtlasFailureTestState.upload;
    core.cb.on_atlas_create = AtlasFailureTestState.create;

    const id_blank = core.ensureGlyphByID(123, c_api.STYLE_BOLD).?;
    try std.testing.expectEqual(@as(f32, 0), id_blank.bbox_size_px[0]);
    try std.testing.expect(!core.transient_glyph_has_negative);

    const scalar_blank = core.ensureGlyphPhase2('A', 0).?;
    try std.testing.expectEqual(@as(f32, 0), scalar_blank.bbox_size_px[0]);
    try std.testing.expect(core.transient_glyph_has_negative);
    const first_retry_at = core.transient_glyph_retry_at.?;
    try std.testing.expectEqual(@as(u8, 1), core.transient_glyph_retry_attempts);
    try std.testing.expectEqual(first_retry_at, core.transient_glyph_retry_at.?);
    try std.testing.expectEqual(@as(u32, 0), state.upload_calls);

    core.resetAtlasMaintenanceBackoff();
    state.abort_raster = true;
    core.flush_aborted = false;
    try std.testing.expect(core.ensureGlyphPhase2('B', 0) == null);
    try std.testing.expect(core.flush_aborted);
    try std.testing.expect(!core.transient_glyph_has_negative);
    try std.testing.expect(core.transient_glyph_retry_at == null);
}

test "ASCII table and pre-raster callbacks stop immediately on abort" {
    {
        var core = Core.initForTest(std.testing.allocator);
        defer core.deinitForTest();
        var state = AsciiPreloadTestState{ .core = &core, .abort_table_after = 2 };
        core.ctx = &state;
        core.cb.on_get_ascii_table = AsciiPreloadTestState.getTable;
        core.cb.on_rasterize_glyph_by_id = AsciiPreloadTestState.rasterizeById;
        core.cb.on_atlas_upload = AsciiPreloadTestState.upload;
        core.cb.on_atlas_create = AsciiPreloadTestState.create;

        try std.testing.expect(!core.loadAsciiTables());
        try std.testing.expectEqual(@as(u32, 2), state.table_calls);
        try std.testing.expectEqual(@as(u32, 0), state.raster_calls);
        try std.testing.expect(!core.ascii_tables_valid);
    }

    {
        var core = Core.initForTest(std.testing.allocator);
        defer core.deinitForTest();
        var state = AsciiPreloadTestState{ .core = &core, .abort_raster_after = 2 };
        core.ctx = &state;
        core.cb.on_get_ascii_table = AsciiPreloadTestState.getTable;
        core.cb.on_rasterize_glyph_by_id = AsciiPreloadTestState.rasterizeById;
        core.cb.on_atlas_upload = AsciiPreloadTestState.upload;
        core.cb.on_atlas_create = AsciiPreloadTestState.create;

        try std.testing.expect(!core.loadAsciiTables());
        try std.testing.expectEqual(@as(u32, 4), state.table_calls);
        try std.testing.expectEqual(@as(u32, 2), state.raster_calls);
        try std.testing.expectEqual(@as(u32, 1), state.upload_calls);
        try std.testing.expect(!core.ascii_tables_valid);
    }
}

test "ASCII pre-raster mirrors by-ID entries into canonical scalar slots" {
    var core = Core.initForTest(std.testing.allocator);
    defer core.deinitForTest();
    var state = AsciiPreloadTestState{ .core = &core };
    core.ctx = &state;
    core.cb.on_get_ascii_table = AsciiPreloadTestState.getTable;
    core.cb.on_rasterize_glyph_by_id = AsciiPreloadTestState.rasterizeById;
    core.cb.on_atlas_upload = AsciiPreloadTestState.upload;
    core.cb.on_atlas_create = AsciiPreloadTestState.create;

    try std.testing.expect(core.loadAsciiTables());
    try std.testing.expect(core.ascii_tables_valid);
    try std.testing.expectEqual(@as(u32, 4), state.raster_calls);
    for (0..4) |style_index| {
        const scalar_index = @as(usize, 'A') * 4 + style_index;
        try std.testing.expect(core.glyph_valid_ascii.?[scalar_index]);
        try std.testing.expect(core.glyph_cache_ascii.?[scalar_index].bbox_size_px[0] > 0);
        core.glyph_valid_ascii.?[scalar_index] = false;
    }

    // A second preload hits the by-ID cache, repairs the scalar aliases, and
    // performs no duplicate rasterization or upload.
    try std.testing.expect(core.preRasterizeAscii());
    try std.testing.expectEqual(@as(u32, 4), state.raster_calls);
    try std.testing.expectEqual(@as(u32, 4), state.upload_calls);
    for (0..4) |style_index| {
        const scalar_index = @as(usize, 'A') * 4 + style_index;
        try std.testing.expect(core.glyph_valid_ascii.?[scalar_index]);
    }
}

test "ASCII pre-raster resolves a blank by-ID entry through scalar fallback" {
    var core = Core.initForTest(std.testing.allocator);
    defer core.deinitForTest();
    var state = AsciiPreloadTestState{ .core = &core, .by_id_miss = true };
    core.ctx = &state;
    core.cb.on_get_ascii_table = AsciiPreloadTestState.getTable;
    core.cb.on_rasterize_glyph_by_id = AsciiPreloadTestState.rasterizeById;
    core.cb.on_rasterize_glyph = AsciiPreloadTestState.rasterizeScalar;
    core.cb.on_atlas_upload = AsciiPreloadTestState.upload;
    core.cb.on_atlas_create = AsciiPreloadTestState.create;

    try std.testing.expect(core.loadAsciiTables());
    try std.testing.expectEqual(@as(u32, 4), state.raster_calls);
    try std.testing.expectEqual(@as(u32, 4), state.scalar_calls);
    try std.testing.expect(!core.transient_glyph_has_negative);
    for (0..4) |style_index| {
        const scalar_index = @as(usize, 'A') * 4 + style_index;
        try std.testing.expect(core.glyph_valid_ascii.?[scalar_index]);
        try std.testing.expect(core.glyph_cache_ascii.?[scalar_index].bbox_size_px[0] > 0);
    }
}

test "unrepresentable glyph bitmap dimensions return blank without upload" {
    var core = Core.initForTest(std.testing.allocator);
    defer core.deinitForTest();
    var state = AtlasFailureTestState{ .core = &core };
    core.ctx = &state;
    core.cb.on_atlas_upload = AtlasFailureTestState.upload;
    core.atlas_packer = shelf_packer.ShelfPacker.init(core.atlas_w, core.atlas_h);
    core.atlas_initialized = true;
    const packer_before = core.atlas_packer.?;
    const reset_seq_before = core.atlas_reset_seq;

    var hostile = c_api.GlyphBitmap{
        .pixels = null,
        .width = std.math.maxInt(u32),
        .height = 1,
        .pitch = 1,
        .bearing_x = 0,
        .bearing_y = 0,
        .advance_26_6 = 192,
        .ascent_px = 1,
        .descent_px = 0,
        .bytes_per_pixel = 1,
    };
    const too_wide = core.packAndUploadBitmap(&hostile).?;
    try std.testing.expectEqual(@as(f32, 0), too_wide.bbox_size_px[0]);
    try std.testing.expectEqual(@as(f32, 3), too_wide.advance_px);

    hostile.width = 1;
    hostile.height = std.math.maxInt(u32);
    const too_tall = core.packAndUploadBitmap(&hostile).?;
    try std.testing.expectEqual(@as(f32, 0), too_tall.bbox_size_px[1]);
    try std.testing.expectEqual(@as(u32, 0), state.upload_calls);
    try std.testing.expectEqual(reset_seq_before, core.atlas_reset_seq);
    try std.testing.expectEqualDeep(packer_before, core.atlas_packer.?);
}

test "atlas grows and maximum-size full retry converges" {
    var core = Core.initForTest(std.testing.allocator);
    defer core.deinitForTest();

    core.atlas_w = 8;
    core.atlas_h = 8;
    core.atlas_packer = shelf_packer.ShelfPacker.init(8, 8);
    core.atlas_initialized = true;
    const grow_bitmap = c_api.GlyphBitmap{
        .pixels = null,
        .width = 10,
        .height = 10,
        .pitch = 10,
        .bearing_x = 0,
        .bearing_y = 0,
        .advance_26_6 = 64,
        .ascent_px = 8,
        .descent_px = 2,
        .bytes_per_pixel = 1,
    };
    const grown = core.packAndUploadBitmap(&grow_bitmap).?;
    try std.testing.expect(core.atlas_w >= 16 and core.atlas_h >= 16);
    try std.testing.expect(core.atlas_reset_during_flush);
    try std.testing.expect(grown.bbox_size_px[0] > 0);

    core.atlas_w = config.atlas_size_max;
    core.atlas_h = config.atlas_size_max;
    core.atlas_packer = shelf_packer.ShelfPacker.init(core.atlas_w, core.atlas_h);
    core.atlas_reset_during_flush = false;
    const reset_seq = core.atlas_reset_seq;
    const oversized = c_api.GlyphBitmap{
        .pixels = null,
        .width = config.atlas_size_max,
        .height = 1,
        .pitch = config.atlas_size_max,
        .bearing_x = 0,
        .bearing_y = 0,
        .advance_26_6 = 128,
        .ascent_px = 1,
        .descent_px = 0,
        .bytes_per_pixel = 1,
    };
    const missed = core.packAndUploadBitmap(&oversized).?;
    try std.testing.expectEqual(@as(f32, 0), missed.bbox_size_px[0]);
    try std.testing.expectEqual(reset_seq, core.atlas_reset_seq);
    try std.testing.expect(!core.atlas_reset_during_flush);

    // A packer-full miss at max gets exactly one same-size reset so the
    // working set can change. A second full condition in the same flush is
    // blank-negative-cached without another reset.
    const small = c_api.GlyphBitmap{
        .pixels = null,
        .width = 1,
        .height = 1,
        .pitch = 1,
        .bearing_x = 0,
        .bearing_y = 0,
        .advance_26_6 = 64,
        .ascent_px = 1,
        .descent_px = 0,
        .bytes_per_pixel = 1,
    };
    core.atlas_packer.?.next_y = config.atlas_size_max;
    core.atlas_reset_during_flush = false;
    const before_full = core.atlas_reset_seq;
    const first = core.packAndUploadBitmap(&small).?;
    try std.testing.expect(first.bbox_size_px[0] > 0);
    try std.testing.expectEqual(before_full +% 1, core.atlas_reset_seq);
    try std.testing.expectEqual(@as(u8, 1), core.atlas_full_resets_this_flush);

    core.atlas_packer.?.next_y = config.atlas_size_max;
    core.atlas_reset_during_flush = false;
    const before_second = core.atlas_reset_seq;
    const second = core.packAndUploadBitmap(&small).?;
    try std.testing.expectEqual(@as(f32, 0), second.bbox_size_px[0]);
    try std.testing.expectEqual(before_second, core.atlas_reset_seq);
    try std.testing.expect(!core.atlas_reset_during_flush);
    try std.testing.expect(core.atlas_has_capacity_negative);

    // A working-set change schedules one delayed reprobe rather than
    // recreating a maximum atlas synchronously.
    const before_revision_changes = core.atlas_reset_seq;
    try core.grid.resizeGrid(1, 2, 2);
    core.grid.putCell(0, 0, 'x', 0);
    core.grid.scrollGrid(1, 0, 2, 0, 2, 1, 0);
    try core.hl.define(7, null, null, null, false, 0, .{ .bold = true }, false);
    const schedule_now: i128 = 10 * std.time.ns_per_s;
    const retry_at = schedule_now + 250 * std.time.ns_per_ms;
    try std.testing.expect(!core.prepareAtlasCapacityRetryAt(schedule_now));
    try std.testing.expectEqual(retry_at, core.atlas_negative_retry_at.?);
    try std.testing.expectEqual(retry_at, flush.nextMsgTimeoutNs(&core).?);

    // Until the scheduled deadline, repeated new-glyph edits remain negative
    // cached. They neither recreate the maximum texture nor postpone the
    // absolute deadline, even though each is a new flush with a fresh local
    // same-size-reset budget.
    const ordinary_flush_times = [_]i128{
        schedule_now + 1,
        schedule_now + 100 * std.time.ns_per_ms,
    };
    for (ordinary_flush_times) |ordinary_now| {
        core.grid.glyph_working_set_rev +%= 1;
        try std.testing.expect(!core.prepareAtlasCapacityRetryAt(ordinary_now));
        core.atlas_full_resets_this_flush = 0;
        core.atlas_packer.?.next_y = config.atlas_size_max;
        core.atlas_reset_during_flush = false;
        const blocked = core.packAndUploadBitmap(&small).?;
        try std.testing.expectEqual(@as(f32, 0), blocked.bbox_size_px[0]);
        try std.testing.expectEqual(before_revision_changes, core.atlas_reset_seq);
        try std.testing.expectEqual(@as(u8, 0), core.atlas_full_resets_this_flush);
        try std.testing.expectEqual(retry_at, core.atlas_negative_retry_at.?);
        try std.testing.expect(!core.atlas_negative_recovery_armed);
        try std.testing.expect(!core.atlas_reset_during_flush);
    }

    try std.testing.expect(!core.prepareAtlasCapacityRetryAt(retry_at - 1));
    try std.testing.expect(core.prepareAtlasCapacityRetryAt(retry_at));
    try std.testing.expectEqual(before_revision_changes, core.atlas_reset_seq);
    try std.testing.expect(!core.atlas_has_capacity_negative);
    try std.testing.expect(core.atlas_negative_recovery_armed);

    // A genuinely uncached glyph reaches the packer. On the next flush it may
    // reactively perform exactly one same-size reset and recover capacity.
    core.atlas_full_resets_this_flush = 0;
    core.atlas_packer.?.next_y = config.atlas_size_max;
    const recovered = core.packAndUploadBitmap(&small).?;
    try std.testing.expect(recovered.bbox_size_px[0] > 0);
    try std.testing.expectEqual(before_revision_changes +% 1, core.atlas_reset_seq);
    try std.testing.expect(!core.atlas_has_capacity_negative);
    core.finishAtlasCapacityRetry();
    try std.testing.expect(!core.atlas_negative_recovery_armed);
}

test "capacity-negative retry is selective and backs off after repeated failure" {
    var core = Core.initForTest(std.testing.allocator);
    defer core.deinitForTest();
    try core.initGlyphCache();

    const negative_index: usize = 'x';
    const positive_index: usize = 'y';
    core.glyph_cache_ascii.?[negative_index] = std.mem.zeroes(c_api.GlyphEntry);
    core.glyph_valid_ascii.?[negative_index] = true;
    var positive = std.mem.zeroes(c_api.GlyphEntry);
    positive.bbox_size_px = .{ 1, 1 };
    core.glyph_cache_ascii.?[positive_index] = positive;
    core.glyph_valid_ascii.?[positive_index] = true;

    core.atlas_has_capacity_negative = true;
    core.atlas_negative_retry_grid_rev = core.grid.glyph_working_set_rev;
    core.atlas_negative_retry_style_rev = core.hl.glyph_style_rev;
    core.grid.glyph_working_set_rev +%= 1;
    const first_now: i128 = 1 * std.time.ns_per_s;
    const first_retry_at = first_now + 250 * std.time.ns_per_ms;
    try std.testing.expect(!core.prepareAtlasCapacityRetryAt(first_now));
    try std.testing.expectEqual(first_retry_at, core.atlas_negative_retry_at.?);
    try std.testing.expectEqual(first_retry_at, flush.nextMsgTimeoutNs(&core).?);
    try std.testing.expect(!core.prepareAtlasCapacityRetryAt(first_retry_at - 1));
    try std.testing.expect(core.prepareAtlasCapacityRetryAt(first_retry_at));
    try std.testing.expect(!core.glyph_valid_ascii.?[negative_index]);
    try std.testing.expect(core.glyph_valid_ascii.?[positive_index]);
    try std.testing.expect(core.atlas_negative_recovery_armed);

    // Simulate the delayed reprobe finding the working set still impossible.
    // The unchanged set gets no deadline and therefore cannot churn while idle.
    core.recordAtlasCapacityNegative();
    try std.testing.expectEqual(@as(i128, 500 * std.time.ns_per_ms), core.atlas_negative_retry_delay_ns);
    try std.testing.expect(core.atlas_negative_retry_at == null);
    try std.testing.expect(!core.atlas_negative_recovery_armed);
    try std.testing.expect(!core.prepareAtlasCapacityRetryAt(first_retry_at + std.time.ns_per_s));
    try std.testing.expect(core.atlas_negative_retry_at == null);

    const second_now = first_retry_at + 2 * std.time.ns_per_s;
    core.grid.glyph_working_set_rev +%= 1;
    const second_retry_at = second_now + 500 * std.time.ns_per_ms;
    try std.testing.expect(!core.prepareAtlasCapacityRetryAt(second_now));
    try std.testing.expectEqual(second_retry_at, core.atlas_negative_retry_at.?);
    try std.testing.expect(!core.prepareAtlasCapacityRetryAt(second_retry_at - 1));
    try std.testing.expect(core.prepareAtlasCapacityRetryAt(second_retry_at));

    // No renewed miss means the old negative left the visible working set.
    // A successful flush retires the episode and restores the minimum delay.
    core.finishAtlasCapacityRetry();
    try std.testing.expect(!core.atlas_negative_recovery_armed);
    try std.testing.expectEqual(@as(i128, 250 * std.time.ns_per_ms), core.atlas_negative_retry_delay_ns);
    try std.testing.expect(core.atlas_negative_retry_at == null);

    core.atlas_has_capacity_negative = true;
    core.atlas_negative_retry_delay_ns = 4 * std.time.ns_per_s;
    core.atlas_negative_recovery_armed = true;
    core.resetAtlasCapacityRetryBackoff();
    try std.testing.expect(!core.atlas_has_capacity_negative);
    try std.testing.expect(!core.atlas_negative_recovery_armed);
    try std.testing.expectEqual(@as(i128, 250 * std.time.ns_per_ms), core.atlas_negative_retry_delay_ns);
}

test "restart replaces connect cleanup policy before notifying observers" {
    const State = struct {
        core: *Core,
        restart_calls: u32 = 0,
        saw_pending_restart: bool = false,
        saw_connect_hotswap: bool = true,
        saw_keep_child_alive: bool = true,

        fn onRestart(
            ctx: ?*anyopaque,
            listen_addr: [*]const u8,
            listen_addr_len: usize,
        ) callconv(.c) void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            self.restart_calls += 1;
            self.saw_pending_restart = self.core.restart_pending_addr != null and
                std.mem.eql(u8, self.core.restart_pending_addr.?, listen_addr[0..listen_addr_len]);
            self.saw_connect_hotswap = self.core.restart_pending_is_connect_hotswap;
            self.saw_keep_child_alive = self.core.connect_keeps_child_alive;
        }
    };

    var core = Core.initForTest(std.testing.allocator);
    defer core.deinitForTest();
    defer if (core.restart_pending_addr) |addr| core.alloc.free(addr);
    var state = State{ .core = &core };
    core.ctx = &state;
    core.cb.on_restart = State.onRestart;

    try core.handleConnectEvent("old-server");
    try std.testing.expect(core.restart_pending_is_connect_hotswap);
    try std.testing.expect(core.connect_keeps_child_alive);

    try core.handleRestartEvent("new-server");
    try std.testing.expectEqual(@as(u32, 1), state.restart_calls);
    try std.testing.expect(state.saw_pending_restart);
    try std.testing.expect(!state.saw_connect_hotswap);
    try std.testing.expect(!state.saw_keep_child_alive);
}

fn checkRestartReplacementAllocationFailure(alloc: std.mem.Allocator) !void {
    var core = Core.initForTest(alloc);
    defer core.deinitForTest();
    defer if (core.restart_pending_addr) |addr| core.alloc.free(addr);

    try core.handleConnectEvent("old-connect");
    const old = core.restart_pending_addr.?;
    core.handleRestartEvent("new-restart") catch |err| {
        try std.testing.expectEqual(old.ptr, core.restart_pending_addr.?.ptr);
        try std.testing.expectEqualSlices(u8, "old-connect", core.restart_pending_addr.?);
        try std.testing.expect(core.restart_pending_is_connect_hotswap);
        try std.testing.expect(core.connect_keeps_child_alive);
        return err;
    };

    try std.testing.expectEqualSlices(u8, "new-restart", core.restart_pending_addr.?);
    try std.testing.expect(!core.restart_pending_is_connect_hotswap);
    try std.testing.expect(!core.connect_keeps_child_alive);
}

test "restart replacement OOM preserves pending connect address and policy" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        checkRestartReplacementAllocationFailure,
        .{},
    );
}

fn checkConnectReplacementAllocationFailure(alloc: std.mem.Allocator) !void {
    var core = Core.initForTest(alloc);
    defer core.deinitForTest();
    defer if (core.restart_pending_addr) |addr| core.alloc.free(addr);

    try core.handleRestartEvent("old-restart");
    const old = core.restart_pending_addr.?;
    core.handleConnectEvent("new-connect") catch |err| {
        try std.testing.expectEqual(old.ptr, core.restart_pending_addr.?.ptr);
        try std.testing.expectEqualSlices(u8, "old-restart", core.restart_pending_addr.?);
        try std.testing.expect(!core.restart_pending_is_connect_hotswap);
        try std.testing.expect(!core.connect_keeps_child_alive);
        return err;
    };

    try std.testing.expectEqualSlices(u8, "new-connect", core.restart_pending_addr.?);
    try std.testing.expect(core.restart_pending_is_connect_hotswap);
    try std.testing.expect(core.connect_keeps_child_alive);
}

test "connect replacement OOM preserves pending restart address and policy" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        checkConnectReplacementAllocationFailure,
        .{},
    );
}

test "transient glyph retries are bounded and restart after working-set change" {
    var core = Core.initForTest(std.testing.allocator);
    defer core.deinitForTest();

    var now: i128 = 3 * std.time.ns_per_s;
    core.recordTransientGlyphNegativeAt(now);
    try std.testing.expect(core.transient_glyph_has_negative);
    try std.testing.expect(!core.atlas_has_capacity_negative);
    try std.testing.expectEqual(@as(u8, 1), core.transient_glyph_retry_attempts);
    try std.testing.expectEqual(now + 250 * std.time.ns_per_ms, core.transient_glyph_retry_at.?);
    try std.testing.expectEqual(core.transient_glyph_retry_at.?, flush.nextMsgTimeoutNs(&core).?);

    // Repeated misses before the timer fires must not postpone the deadline.
    const first_retry_at = core.transient_glyph_retry_at.?;
    core.recordTransientGlyphNegativeAt(now + 100 * std.time.ns_per_ms);
    try std.testing.expectEqual(first_retry_at, core.transient_glyph_retry_at.?);

    const expected_delays = [_]i128{
        250 * std.time.ns_per_ms,
        500 * std.time.ns_per_ms,
        1 * std.time.ns_per_s,
        2 * std.time.ns_per_s,
        4 * std.time.ns_per_s,
    };
    for (expected_delays, 0..) |delay_ns, attempt_index| {
        const retry_at = core.transient_glyph_retry_at.?;
        try std.testing.expectEqual(now + delay_ns, retry_at);
        try std.testing.expect(!core.prepareAtlasMaintenanceAt(retry_at - 1));
        try std.testing.expect(core.prepareAtlasMaintenanceAt(retry_at));
        try std.testing.expect(core.transient_glyph_recovery_armed);

        now = retry_at;
        core.recordTransientGlyphNegativeAt(now);
        try std.testing.expect(core.transient_glyph_has_negative);
        try std.testing.expect(!core.transient_glyph_recovery_armed);
        if (attempt_index + 1 < expected_delays.len) {
            try std.testing.expectEqual(@as(u8, @intCast(attempt_index + 2)), core.transient_glyph_retry_attempts);
            try std.testing.expect(core.transient_glyph_retry_at != null);
        } else {
            try std.testing.expectEqual(TRANSIENT_GLYPH_RETRY_MAX_ATTEMPTS, core.transient_glyph_retry_attempts);
            try std.testing.expect(core.transient_glyph_retry_at == null);
        }
    }

    // An unchanged unsupported glyph converges with no timer.
    try std.testing.expect(!core.prepareAtlasMaintenanceAt(now + 10 * std.time.ns_per_s));
    try std.testing.expect(core.transient_glyph_retry_at == null);

    // The blank remains cached, so prepare (not another raster callback) must
    // notice a new working set and restart the bounded budget -- but at twice
    // the previous episode's starting delay, not at the minimum. The working
    // set changes on every edit (putCell bumps glyph_working_set_rev), so a
    // restart at the minimum would re-run beginNegativeGlyphReprobe's
    // full-screen invalidation indefinitely for one unrasterizable codepoint.
    const changed_now = now + 20 * std.time.ns_per_s;
    core.grid.glyph_working_set_rev +%= 1;
    try std.testing.expect(!core.prepareAtlasMaintenanceAt(changed_now));
    try std.testing.expectEqual(@as(u8, 1), core.transient_glyph_retry_attempts);
    const restarted_at = changed_now + 2 * TRANSIENT_GLYPH_RETRY_INITIAL_NS;
    try std.testing.expectEqual(restarted_at, core.transient_glyph_retry_at.?);
    try std.testing.expect(core.prepareAtlasMaintenanceAt(restarted_at));

    // No renewed raster miss means the retry succeeded; successful commit
    // clears the transient episode without touching capacity state.
    core.finishAtlasMaintenance();
    try std.testing.expect(!core.transient_glyph_has_negative);
    try std.testing.expect(!core.transient_glyph_recovery_armed);
    try std.testing.expectEqual(@as(u8, 0), core.transient_glyph_retry_attempts);
    try std.testing.expectEqual(TRANSIENT_GLYPH_RETRY_INITIAL_NS, core.transient_glyph_retry_delay_ns);
    // The cross-episode escalation must also be retired by a genuine success,
    // otherwise it stays elevated for the process lifetime and every later
    // first-miss reprobe is needlessly slow.
    try std.testing.expectEqual(TRANSIENT_GLYPH_RETRY_INITIAL_NS, core.transient_glyph_episode_delay_ns);
}

test "maintenance abort rearms capacity and transient retries without consuming attempts" {
    var core = Core.initForTest(std.testing.allocator);
    defer core.deinitForTest();

    const now: i128 = 5 * std.time.ns_per_s;
    core.recordTransientGlyphNegativeAt(now);
    core.atlas_has_capacity_negative = true;
    core.atlas_negative_retry_at = now + TRANSIENT_GLYPH_RETRY_INITIAL_NS;
    try std.testing.expect(core.prepareAtlasMaintenanceAt(now + TRANSIENT_GLYPH_RETRY_INITIAL_NS));
    try std.testing.expect(core.atlas_negative_recovery_armed);
    try std.testing.expect(core.transient_glyph_recovery_armed);

    const retry_at = now + std.time.ns_per_s;
    core.rearmAtlasMaintenanceAfterAbort(retry_at);
    try std.testing.expect(core.atlas_has_capacity_negative);
    try std.testing.expect(core.transient_glyph_has_negative);
    try std.testing.expect(!core.atlas_negative_recovery_armed);
    try std.testing.expect(!core.transient_glyph_recovery_armed);
    try std.testing.expectEqual(@as(u8, 1), core.transient_glyph_retry_attempts);
    try std.testing.expectEqual(retry_at, core.atlas_negative_retry_at.?);
    try std.testing.expectEqual(retry_at, core.transient_glyph_retry_at.?);

    core.resetAtlasMaintenanceBackoff();
    try std.testing.expect(!core.atlas_has_capacity_negative);
    try std.testing.expect(!core.transient_glyph_has_negative);
    try std.testing.expect(core.atlas_negative_retry_at == null);
    try std.testing.expect(core.transient_glyph_retry_at == null);
    try std.testing.expectEqual(@as(u8, 0), core.transient_glyph_retry_attempts);
}

test "maintenance timeout selects earliest independent glyph deadline" {
    var core = Core.initForTest(std.testing.allocator);
    defer core.deinitForTest();

    core.atlas_negative_retry_at = 900;
    core.transient_glyph_retry_at = 700;
    try std.testing.expectEqual(@as(i128, 700), flush.nextMsgTimeoutNs(&core).?);
    core.transient_glyph_retry_at = 1_100;
    try std.testing.expectEqual(@as(i128, 900), flush.nextMsgTimeoutNs(&core).?);
}

test "Core stop owns teardown exactly once" {
    var core = Core.initForTest(std.testing.allocator);
    core.stop();
    core.stop();
    try std.testing.expect(core.waitUntilStopped());
    try std.testing.expectEqual(@as(u8, 2), core.stop_state.load(.acquire));
}

test "RPC-thread stop requests shutdown without joining itself" {
    const Worker = struct {
        fn run(core: *Core, returned: *std.atomic.Value(bool)) void {
            core.rpc_thread_id.store(@intCast(std.Thread.getCurrentId()), .release);
            core.stop();
            core.rpc_thread_id.store(0, .release);
            returned.store(true, .release);
        }
    };

    var core = Core.initForTest(std.testing.allocator);
    var returned = std.atomic.Value(bool).init(false);
    const thread = try std.Thread.spawn(.{}, Worker.run, .{ &core, &returned });
    core.thread = thread;

    while (!returned.load(.acquire)) {
        std.Io.sleep(clock.io(), .{ .nanoseconds = std.time.ns_per_ms }, .awake) catch {};
    }
    try std.testing.expectEqual(@as(u8, 0), core.stop_state.load(.acquire));

    // The lifecycle thread takes ownership and joins the already-returned RPC
    // thread before releasing Core resources.
    core.stop();
    try std.testing.expect(core.waitUntilStopped());
}

test "asynchronous hard failure wakes a socket RPC reader" {
    if (comptime @import("builtin").os.tag == .windows) return error.SkipZigTest;
    clock.init();

    var sockets: [2]std.posix.socket_t = undefined;
    while (true) switch (std.posix.errno(std.posix.system.socketpair(
        std.posix.AF.UNIX,
        std.posix.SOCK.STREAM,
        0,
        &sockets,
    ))) {
        .SUCCESS => break,
        .INTR => continue,
        else => |err| return std.posix.unexpectedErrno(err),
    };

    const local_file = std.Io.File{ .handle = sockets[0], .flags = .{ .nonblocking = false } };
    const peer_file = std.Io.File{ .handle = sockets[1], .flags = .{ .nonblocking = false } };
    defer peer_file.close(clock.io());

    const Reader = struct {
        fn run(
            stream: Stream,
            entered: *std.atomic.Value(bool),
            returned: *std.atomic.Value(bool),
        ) void {
            var byte: [1]u8 = undefined;
            entered.store(true, .release);
            _ = stream.read(&byte) catch {};
            returned.store(true, .release);
        }
    };

    // wakeRpcReaderForHardFailure reports a failed shutdown through the log
    // rather than a return value, and initForTest leaves the log detached.
    // Surface it: a wake that silently no-ops is exactly the failure this
    // test exists to catch, and without this the reason never reaches anyone.
    const Diag = struct {
        fn write(_: ?*anyopaque, msg: [*]const u8, len: usize) callconv(.c) void {
            std.debug.print("[wake-test] {s}", .{msg[0..len]});
        }
    };

    var core = Core.initForTest(std.testing.allocator);
    defer core.deinitForTest();
    core.log.cb = Diag.write;
    core.stdin_file = Stream.fromFile(local_file);
    core.transport_kind = .socket;
    var entered = std.atomic.Value(bool).init(false);
    var returned = std.atomic.Value(bool).init(false);
    const reader = try std.Thread.spawn(
        .{},
        Reader.run,
        .{ core.stdin_file.?, &entered, &returned },
    );

    // The interesting case is a reader already parked in the read syscall, so
    // wait for it to get there. Without this the wake can land before the
    // reader ever blocks, and the test silently stops covering the wake.
    while (!entered.load(.acquire)) {
        std.Io.sleep(clock.io(), .{ .nanoseconds = std.time.ns_per_ms }, .awake) catch {};
    }
    std.Io.sleep(clock.io(), .{ .nanoseconds = 20 * std.time.ns_per_ms }, .awake) catch {};

    core.failHardRender(error.VertexBudgetExceeded);
    core.wakeRpcReaderForHardFailure();

    // Bounded: a wake that does not release the reader must fail the test
    // rather than hang it. Shutting the peer end down is the fallback that
    // guarantees EOF, so the thread is always joinable. Use the raw syscall
    // rather than closing peer_file, which the defer above already owns.
    const deadline_ns: i128 = clock.nowNs() + 5 * std.time.ns_per_s;
    while (!returned.load(.acquire) and clock.nowNs() < deadline_ns) {
        std.Io.sleep(clock.io(), .{ .nanoseconds = std.time.ns_per_ms }, .awake) catch {};
    }
    const woke = returned.load(.acquire);
    if (!woke) _ = std.posix.system.shutdown(sockets[1], std.posix.SHUT.RDWR);
    reader.join();

    core.stdin_file = null;
    local_file.close(clock.io());

    if (!woke) return error.HardFailureWakeDidNotReleaseReader;
    try std.testing.expect(core.redraw_recovery_failed.load(.seq_cst));
}

test "on_log stop stays non-blocking while teardown mutex is held" {
    const Callback = struct {
        fn log(ctx: ?*anyopaque, _: [*]const u8, _: usize) callconv(.c) void {
            const core: *Core = @ptrCast(@alignCast(ctx.?));
            core.stop();
        }
    };

    var core = Core.initForTest(std.testing.allocator);
    core.log.cb = Callback.log;
    core.log.ctx = &core;

    // Models cleanup/teardown joining a callback worker while owning the
    // transport mutex. The callback must only request cancellation.
    core.child_handle_mu.lockUncancelable(clock.io());
    core.stdin_close_mu.lockUncancelable(clock.io());
    core.write_queue_mu.lockUncancelable(clock.io());
    core.log.write("callback stop\n", .{});
    core.write_queue_mu.unlock(clock.io());
    core.stdin_close_mu.unlock(clock.io());
    core.child_handle_mu.unlock(clock.io());

    try std.testing.expect(core.stop_flag.load(.acquire));
    try std.testing.expectEqual(@as(u8, 0), core.stop_state.load(.acquire));
    core.log.cb = null;
    core.stop();
    try std.testing.expect(core.waitUntilStopped());
}

test "session reset republishes the latest desired resize" {
    var core = Core.initForTest(std.testing.allocator);
    defer core.deinitForTest();

    _ = core.resize(47, 113);
    // Model a successful enqueue to the old session: pending delivery was
    // cleared, but the queue can still be discarded by reconnect cleanup.
    core.pending_resize_valid = false;
    core.ui_attached.store(true, .release);
    try core.ext_float_anchor_entries.ensureTotalCapacityPrecise(core.alloc, 32);
    try core.ext_float_entries.ensureTotalCapacityPrecise(core.alloc, 32);
    try core.ext_float_row_entry_indices.ensureTotalCapacityPrecise(core.alloc, 32);
    try core.hl.define(9, 0x123456, null, null, false, 0, .{}, false);
    try core.hl.setGroup("SessionOnly", 9);

    core.resetSessionState();
    try std.testing.expect(!core.ui_attached.load(.acquire));
    try std.testing.expect(core.pending_resize_valid);
    try std.testing.expectEqual(@as(u32, 47), core.pending_resize_rows);
    try std.testing.expectEqual(@as(u32, 113), core.pending_resize_cols);
    try std.testing.expectEqual(@as(usize, 0), core.ext_float_anchor_entries.capacity);
    try std.testing.expectEqual(@as(usize, 0), core.ext_float_entries.capacity);
    try std.testing.expectEqual(@as(usize, 0), core.ext_float_row_entry_indices.capacity);
    try std.testing.expectEqual(@as(usize, 0), core.hl.map.count());
    try std.testing.expectEqual(@as(usize, 0), core.hl.groups.count());
}

test "redraw allocation failure poisons epoch and suppresses batch presentation" {
    const TestCtx = struct {
        row_callbacks: u32 = 0,

        fn onVerticesRow(
            opaque_ctx: ?*anyopaque,
            _: i64,
            _: u32,
            _: u32,
            _: ?[*]const c_api.Vertex,
            _: usize,
            _: u32,
            _: u32,
            _: u32,
        ) callconv(.c) void {
            const ctx: *@This() = @ptrCast(@alignCast(opaque_ctx.?));
            ctx.row_callbacks += 1;
        }
    };

    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var test_ctx: TestCtx = .{};
    var core = Core.init(failing.allocator(), .{ .on_vertices_row = TestCtx.onVerticesRow }, &test_ctx);
    defer core.deinitForTest();
    try core.grid.resize(2, 4);

    var cell_a_fields = [_]mp.Value{.{ .str = "A" }};
    var cells_a = [_]mp.Value{.{ .arr = &cell_a_fields }};
    var line_a_tuple = [_]mp.Value{
        .{ .int = 1 }, .{ .int = 0 }, .{ .int = 0 }, .{ .arr = &cells_a }, .{ .bool = false },
    };
    var line_a_event = [_]mp.Value{ .{ .str = "grid_line" }, .{ .arr = &line_a_tuple } };

    var group_tuple = [_]mp.Value{ .{ .str = "RecoveryTest" }, .{ .int = 7 } };
    var group_event = [_]mp.Value{ .{ .str = "hl_group_set" }, .{ .arr = &group_tuple } };

    var cell_b_fields = [_]mp.Value{.{ .str = "B" }};
    var cells_b = [_]mp.Value{.{ .arr = &cell_b_fields }};
    var line_b_tuple = [_]mp.Value{
        .{ .int = 1 }, .{ .int = 0 }, .{ .int = 1 }, .{ .arr = &cells_b }, .{ .bool = false },
    };
    var line_b_event = [_]mp.Value{ .{ .str = "grid_line" }, .{ .arr = &line_b_tuple } };
    var flush_event = [_]mp.Value{.{ .str = "flush" }};
    var params = [_]mp.Value{
        .{ .arr = &line_a_event },
        .{ .arr = &group_event },
        .{ .arr = &line_b_event },
        .{ .arr = &flush_event },
    };
    var top = [_]mp.Value{ .{ .int = 2 }, .{ .str = "redraw" }, .{ .arr = &params } };

    // The next allocation is hl_group_set's duplicated group-name key.
    failing.fail_index = failing.alloc_index;
    rpc_session.handleRpcNotification(&core, failing.allocator(), &top);

    try std.testing.expectEqual(@as(u32, 'A'), core.grid.getCell(0, 0).cp);
    try std.testing.expectEqual(@as(u32, ' '), core.grid.getCell(0, 1).cp);
    try std.testing.expectEqual(@as(u32, 0), test_ctx.row_callbacks);
    try std.testing.expect(!core.hl.groups.contains("RecoveryTest"));
    try std.testing.expect(core.redraw_recovery_failed.load(.seq_cst));
    try std.testing.expect(!core.ui_attached.load(.acquire));
}

test "redraw detach response resets poisoned protocol state before reattach" {
    var core = Core.initForTest(std.testing.allocator);
    defer core.deinitForTest();
    try core.grid.resizeGrid(2, 1, 1);
    try core.grid.setWinPos(2, 200, 0, 0);
    try core.hl.define(9, 0x123456, null, null, false, 0, .{}, false);
    try core.hl.setGroup("PoisonedEpoch", 9);

    core.redraw_recovery_state = .await_detach;
    core.redraw_recovery_msgid = 77;
    var response = [_]mp.Value{
        .{ .int = 1 },
        .{ .int = 77 },
        .nil,
        .nil,
    };
    rpc_session.handleRpcResponse(&core, &response);

    // The test core has no writer thread, so queueing the fresh attach fails
    // after reset. That still proves the detach-response boundary clears the
    // complete old protocol epoch before any reattach can be attempted.
    try std.testing.expect(core.redraw_recovery_failed.load(.seq_cst));
    try std.testing.expectEqual(@as(usize, 0), core.grid.sub_grids.count());
    try std.testing.expectEqual(@as(usize, 0), core.grid.win_pos.count());
    try std.testing.expectEqual(@as(usize, 0), core.hl.map.count());
    try std.testing.expectEqual(@as(usize, 0), core.hl.groups.count());
}

test "redraw recovery rejects old epoch and admits fresh attach replay" {
    var core = Core.initForTest(std.testing.allocator);
    defer core.deinitForTest();
    try core.grid.resize(1, 2);

    var cell_fields = [_]mp.Value{.{ .str = "A" }};
    var cells = [_]mp.Value{.{ .arr = &cell_fields }};
    var line_tuple = [_]mp.Value{
        .{ .int = 1 }, .{ .int = 0 }, .{ .int = 0 }, .{ .arr = &cells }, .{ .bool = false },
    };
    var line_event = [_]mp.Value{ .{ .str = "grid_line" }, .{ .arr = &line_tuple } };
    var params = [_]mp.Value{.{ .arr = &line_event }};
    var top = [_]mp.Value{ .{ .int = 2 }, .{ .str = "redraw" }, .{ .arr = &params } };

    core.redraw_recovery_state = .await_detach;
    rpc_session.handleRpcNotification(&core, std.testing.allocator, &top);
    try std.testing.expectEqual(@as(u32, ' '), core.grid.getCell(0, 0).cp);

    // Neovim serializes the fresh replay before the ui_attach response, so it
    // must be accepted while that response is still pending.
    core.redraw_recovery_state = .await_attach;
    core.redraw_recovery_attempts = 1;
    rpc_session.handleRpcNotification(&core, std.testing.allocator, &top);
    try std.testing.expectEqual(@as(u32, 'A'), core.grid.getCell(0, 0).cp);
    try std.testing.expectEqual(@as(u8, 1), core.redraw_recovery_attempts);
}

test "redraw recovery retains resize that cannot queue after fresh attach" {
    var core = Core.initForTest(std.testing.allocator);
    defer core.deinitForTest();

    core.redraw_recovery_state = .await_attach;
    core.redraw_recovery_msgid = 91;
    core.redraw_recovery_attach_rows = 24;
    core.redraw_recovery_attach_cols = 80;
    core.pending_resize_valid = true;
    core.pending_resize_rows = 30;
    core.pending_resize_cols = 100;
    var response = [_]mp.Value{
        .{ .int = 1 },
        .{ .int = 91 },
        .nil,
        .nil,
    };
    rpc_session.handleRpcResponse(&core, &response);

    try std.testing.expectEqual(RedrawRecoveryState.healthy, core.redraw_recovery_state);
    try std.testing.expect(core.ui_attached.load(.acquire));
    try std.testing.expect(core.pending_resize_valid);
    try std.testing.expectEqual(@as(u32, 24), core.ui_attach_rows);
    try std.testing.expectEqual(@as(u32, 80), core.ui_attach_cols);
}

test "focus send failure preserves the latest state for attach retry" {
    var core = Core.initForTest(std.testing.allocator);
    defer core.deinitForTest();

    core.ui_attached.store(true, .release);
    core.requestUiSetFocus(true);

    // A test core has no live writer, so the send fails. The focus state must
    // remain pending for a future attachment.
    try std.testing.expectEqual(@as(u8, 1), core.pending_focus.load(.acquire));
}

test "hard redraw resource limit fails the session without epoch retry" {
    var core = Core.initForTest(std.testing.allocator);
    defer core.deinitForTest();

    var resize_tuple = [_]mp.Value{
        .{ .int = 1 },
        .{ .int = 80 },
        .{ .int = @as(i64, grid_mod.MAX_GRID_ROWS) + 1 },
    };
    var resize_event = [_]mp.Value{ .{ .str = "grid_resize" }, .{ .arr = &resize_tuple } };
    var params = [_]mp.Value{.{ .arr = &resize_event }};
    var top = [_]mp.Value{ .{ .int = 2 }, .{ .str = "redraw" }, .{ .arr = &params } };

    rpc_session.handleRpcNotification(&core, std.testing.allocator, &top);

    try std.testing.expect(core.redraw_recovery_failed.load(.seq_cst));
    try std.testing.expectEqual(@as(u8, 0), core.redraw_recovery_attempts);
    try std.testing.expectEqual(RedrawRecoveryState.healthy, core.redraw_recovery_state);
}

test "redraw post-processing failure poisons the attachment" {
    var core = Core.initForTest(std.testing.allocator);
    defer core.deinitForTest();
    try core.grid.pending_grid_resizes.append(core.alloc, .{
        .grid_id = 9,
        .width = 40,
        .height = 12,
    });

    var params = [_]mp.Value{};
    var top = [_]mp.Value{ .{ .int = 2 }, .{ .str = "redraw" }, .{ .arr = &params } };
    rpc_session.handleRpcNotification(&core, std.testing.allocator, &top);

    // The test core has no writer, so try_resize_grid fails. It must enter the
    // same poisoned-session boundary instead of being logged and ignored.
    try std.testing.expect(core.redraw_recovery_failed.load(.seq_cst));
    try std.testing.expect(!core.ui_attached.load(.acquire));
}

test "UI-state reserve preserves order across a full normal queue" {
    if (comptime @import("builtin").os.tag == .windows) return error.SkipZigTest;
    clock.init();

    var fds: [2]std.posix.fd_t = undefined;
    try std.testing.expectEqual(@as(c_int, 0), std.c.pipe(&fds));
    const read_file = std.Io.File{ .handle = fds[0], .flags = .{ .nonblocking = false } };
    defer read_file.close(clock.io());

    var core = Core.initForTest(std.testing.allocator);
    core.stdin_file = Stream.fromFile(.{ .handle = fds[1], .flags = .{ .nonblocking = false } });
    core.transport_kind = .pipes;
    try std.testing.expect(core.startWriterThread());
    defer core.stop();

    var n0: rpc.Buf = .empty;
    defer n0.deinit(core.alloc);
    try core.sendRequestHeader(&n0, 10, "nvim_input");
    try rpc.packArray(&n0, core.alloc, 1);
    const n0_prefix_len = n0.items.len + 5;
    const filler = try core.alloc.alloc(u8, Core.MAX_WRITE_QUEUE_SIZE - n0_prefix_len);
    defer core.alloc.free(filler);
    @memset(filler, 'x');
    try rpc.packStr(&n0, core.alloc, filler);
    try std.testing.expectEqual(Core.MAX_WRITE_QUEUE_SIZE, n0.items.len);

    var r1: rpc.Buf = .empty;
    defer r1.deinit(core.alloc);
    try core.sendRequestHeader(&r1, 11, "nvim_ui_set_focus");
    try rpc.packArray(&r1, core.alloc, 1);
    try rpc.packBool(&r1, core.alloc, false);

    var n1: rpc.Buf = .empty;
    defer n1.deinit(core.alloc);
    try core.sendRequestHeader(&n1, 12, "nvim_input");
    try rpc.packArray(&n1, core.alloc, 1);
    try rpc.packStr(&n1, core.alloc, "y");

    // Reproduce the reported failure boundary. N0 consumes the complete
    // normal allowance, but R1 still appends to the same FIFO from reserved
    // capacity. The writer then swaps N0+R1 before later N1 is produced.
    {
        core.write_queue_mu.lockUncancelable(clock.io());
        defer core.write_queue_mu.unlock(clock.io());
        try core.enqueueRawLocked(n0.items, .normal);
        try core.enqueueRawLocked(r1.items, .ui_state);
        try std.testing.expectEqual(Core.MAX_WRITE_QUEUE_SIZE, core.write_queue_normal_bytes);
        try std.testing.expectEqual(r1.items.len, core.write_queue_ui_state_bytes);
        try std.testing.expectEqual(Core.MAX_WRITE_QUEUE_SIZE + r1.items.len, core.write_queue.items.len);
        core.write_queue_cond.signal(clock.io());
    }

    var swap_waits: usize = 0;
    while (swap_waits < 1000) : (swap_waits += 1) {
        core.write_queue_mu.lockUncancelable(clock.io());
        const swapped = core.write_queue_normal_bytes == 0 and
            core.write_queue_ui_state_bytes == 0;
        core.write_queue_mu.unlock(clock.io());
        if (swapped) break;
        std.Io.sleep(clock.io(), .{ .nanoseconds = std.time.ns_per_ms }, .awake) catch {};
    }
    try std.testing.expect(swap_waits < 1000);
    try core.sendRaw(n1.items);

    const total_len = n0.items.len + r1.items.len + n1.items.len;
    const actual = try std.testing.allocator.alloc(u8, total_len);
    defer std.testing.allocator.free(actual);
    const read_stream = Stream.fromFile(read_file);
    var offset: usize = 0;
    while (offset < actual.len) {
        const n = try read_stream.read(actual[offset..]);
        if (n == 0) return error.UnexpectedEndOfStream;
        offset += n;
    }
    var reader = mp.SliceReader{ .data = actual };
    const decoded_n0 = try mp.decode(std.testing.allocator, &reader);
    defer mp.freeValue(std.testing.allocator, decoded_n0);
    const decoded_r1 = try mp.decode(std.testing.allocator, &reader);
    defer mp.freeValue(std.testing.allocator, decoded_r1);
    const decoded_n1 = try mp.decode(std.testing.allocator, &reader);
    defer mp.freeValue(std.testing.allocator, decoded_n1);
    try std.testing.expectEqual(actual.len, reader.i);
    try std.testing.expectEqualStrings("nvim_input", decoded_n0.arr[2].str);
    try std.testing.expectEqualStrings("nvim_ui_set_focus", decoded_r1.arr[2].str);
    try std.testing.expect(!decoded_r1.arr[3].arr[0].bool);
    try std.testing.expectEqualStrings("nvim_input", decoded_n1.arr[2].str);
    try std.testing.expectEqualStrings("y", decoded_n1.arr[3].arr[0].str);
    try std.testing.expect(core.write_queue.capacity <= Core.MAX_TOTAL_WRITE_QUEUE_SIZE);
    try std.testing.expect(core.write_spare_queue.capacity <= Core.MAX_TOTAL_WRITE_QUEUE_SIZE);
    try std.testing.expect(
        core.write_queue.capacity + core.write_spare_queue.capacity <=
            2 * Core.MAX_TOTAL_WRITE_QUEUE_SIZE,
    );
}

test "pending focus and resize preserve publication order" {
    if (comptime @import("builtin").os.tag == .windows) return error.SkipZigTest;
    clock.init();

    var fds: [2]std.posix.fd_t = undefined;
    try std.testing.expectEqual(@as(c_int, 0), std.c.pipe(&fds));
    const read_file = std.Io.File{ .handle = fds[0], .flags = .{ .nonblocking = false } };
    defer read_file.close(clock.io());

    var core = Core.initForTest(std.testing.allocator);
    core.stdin_file = Stream.fromFile(.{ .handle = fds[1], .flags = .{ .nonblocking = false } });
    core.transport_kind = .pipes;
    try std.testing.expect(core.startWriterThread());
    defer core.stop();

    var expected: rpc.Buf = .empty;
    defer expected.deinit(core.alloc);
    try core.sendRequestHeader(&expected, 1, "nvim_ui_set_focus");
    try rpc.packArray(&expected, core.alloc, 1);
    try rpc.packBool(&expected, core.alloc, false);
    try core.sendRequestHeader(&expected, 2, "nvim_ui_try_resize");
    try rpc.packArray(&expected, core.alloc, 2);
    try rpc.packInt(&expected, core.alloc, 100);
    try rpc.packInt(&expected, core.alloc, 30);
    try core.sendRequestHeader(&expected, 3, "nvim_ui_try_resize");
    try rpc.packArray(&expected, core.alloc, 2);
    try rpc.packInt(&expected, core.alloc, 120);
    try rpc.packInt(&expected, core.alloc, 40);
    try core.sendRequestHeader(&expected, 4, "nvim_ui_set_focus");
    try rpc.packArray(&expected, core.alloc, 1);
    try rpc.packBool(&expected, core.alloc, true);

    core.requestUiSetFocus(false);
    _ = core.resize(30, 100);
    core.pending_resize_mu.lockUncancelable(clock.io());
    core.ui_attached.store(true, .release);
    core.flushPendingUiStateLocked();
    core.pending_resize_mu.unlock(clock.io());

    core.ui_attached.store(false, .release);
    _ = core.resize(40, 120);
    core.requestUiSetFocus(true);
    core.pending_resize_mu.lockUncancelable(clock.io());
    core.ui_attached.store(true, .release);
    core.flushPendingUiStateLocked();
    core.pending_resize_mu.unlock(clock.io());

    const actual = try std.testing.allocator.alloc(u8, expected.items.len);
    defer std.testing.allocator.free(actual);
    const read_stream = Stream.fromFile(read_file);
    var used: usize = 0;
    while (used < actual.len) {
        const n = try read_stream.read(actual[used..]);
        if (n == 0) return error.UnexpectedEndOfStream;
        used += n;
    }
    try std.testing.expectEqualSlices(u8, expected.items, actual);
}

test "writer stop cancels a full unread child pipe" {
    if (comptime @import("builtin").os.tag == .windows) return error.SkipZigTest;
    clock.init();

    var fds: [2]std.posix.fd_t = undefined;
    try std.testing.expectEqual(@as(c_int, 0), std.c.pipe(&fds));
    const read_file = std.Io.File{ .handle = fds[0], .flags = .{ .nonblocking = false } };
    defer read_file.close(clock.io());

    var core = Core.initForTest(std.testing.allocator);
    core.stdin_file = Stream.fromFile(.{ .handle = fds[1], .flags = .{ .nonblocking = false } });
    core.transport_kind = .pipes;
    try std.testing.expect(core.startWriterThread());

    const payload = try std.testing.allocator.alloc(u8, 512 * 1024);
    defer std.testing.allocator.free(payload);
    @memset(payload, 'x');
    try core.sendRaw(payload);

    // Let the writer fill the kernel pipe and enter its WouldBlock retry.
    std.Io.sleep(clock.io(), .{ .nanoseconds = 20 * std.time.ns_per_ms }, .awake) catch {};
    core.stop();
    try std.testing.expectEqual(@as(u8, 2), core.stop_state.load(.acquire));
}

test "complete visible-grid snapshot reports truncation from one lock state" {
    var core = Core.initForTest(std.testing.allocator);
    defer core.deinitForTest();

    try core.grid.resizeGrid(1, 40, 120);
    var grid_id: i64 = 2;
    while (grid_id < 22) : (grid_id += 1) {
        try core.grid.resizeGrid(grid_id, 4, 8);
        try core.grid.setWinPos(grid_id, 1000 + grid_id, @intCast(grid_id), 0);
    }
    try core.grid.resizeGrid(30, 3, 7);
    try core.grid.putSyntheticExternal(30, .{
        .win = 3000,
        .start_row = 0,
        .start_col = 0,
    });

    var out: [16]c_api.GridInfo = undefined;
    const snapshot = core.tryGetVisibleGridsComplete(&out).?;
    try std.testing.expectEqual(@as(usize, out.len), snapshot.written);
    try std.testing.expectEqual(@as(usize, 22), snapshot.total);
    try std.testing.expectEqual(@as(i64, 1), out[0].grid_id);

    var empty: [0]c_api.GridInfo = .{};
    const count_only = core.tryGetVisibleGridsComplete(&empty).?;
    try std.testing.expectEqual(@as(usize, 0), count_only.written);
    try std.testing.expectEqual(snapshot.total, count_only.total);

    core.grid_mu.lockUncancelable(clock.io());
    defer core.grid_mu.unlock(clock.io());
    try std.testing.expect(core.tryGetVisibleGridsComplete(&out) == null);
}

test "visible-grid and cursor snapshots saturate hostile stored u32 fields" {
    var core = Core.initForTest(std.testing.allocator);
    defer core.deinitForTest();

    try core.grid.resizeGrid(1, 4, 4);
    // Deliberately non-square: with equal dimensions the margin assertions
    // below read the same number whether the clamp pairs top/bottom with rows
    // and left/right with cols, or swaps them.
    try core.grid.resizeGrid(2, 2, 3);
    try core.grid.win_pos.put(core.grid.alloc, 2, .{
        .row = std.math.maxInt(u32),
        .col = std.math.maxInt(u32),
    });
    try core.grid.viewport_margins.put(core.grid.alloc, 2, .{
        .top = std.math.maxInt(u32),
        .bottom = std.math.maxInt(u32),
        .left = std.math.maxInt(u32),
        .right = std.math.maxInt(u32),
    });

    var out: [2]c_api.GridInfo = undefined;
    const count = core.getVisibleGrids(&out);
    try std.testing.expectEqual(@as(usize, 2), count);
    try std.testing.expectEqual(std.math.maxInt(i32), out[1].start_row);
    try std.testing.expectEqual(std.math.maxInt(i32), out[1].start_col);
    // Margins are clamped to the grid on the way out — stricter than the
    // saturating conversion the placement fields fall back to, and the reason
    // they can be stored before the grid that bounds them exists.
    try std.testing.expectEqual(@as(i32, 2), out[1].margin_top);
    try std.testing.expectEqual(@as(i32, 3), out[1].margin_right);

    core.grid.cursor_grid = 1;
    core.grid.cursor_row = std.math.maxInt(u32);
    core.grid.cursor_col = std.math.maxInt(u32);
    const cursor = core.getCursorPosition();
    try std.testing.expectEqual(std.math.maxInt(i32), cursor.row);
    try std.testing.expectEqual(std.math.maxInt(i32), cursor.col);
}

test "cmdline rendering consumes normalized hostile position and indent" {
    var core = Core.initForTest(std.testing.allocator);
    defer core.deinitForTest();

    try core.grid.resizeGrid(1, 4, 8);
    core.ext_cmdline_enabled = true;
    const content = [_]grid_mod.CmdlineChunk{.{ .hl_id = 0, .text = "abc" }};
    try core.grid.setCmdlineShow(
        &content,
        std.math.maxInt(u32),
        ':',
        "",
        std.math.maxInt(u32),
        1,
        0,
    );

    core.notifyCmdlineChanges();
    try std.testing.expect(!core.flush_aborted);
    try std.testing.expect(core.grid.sub_grids.contains(grid_mod.CMDLINE_GRID_ID));
    try std.testing.expectEqual(@as(u32, 3), core.grid.getCmdlineState(1).?.pos);
    try std.testing.expectEqual(@as(u32, 8), core.grid.getCmdlineState(1).?.indent);
}

// ---------------------------------------------------------------------------
// Atlas reclamation eligibility
// ---------------------------------------------------------------------------

const AtlasGcTestCallbacks = struct {
    fn rasterize(_: ?*anyopaque, _: u32, _: u32, _: *c_api.GlyphBitmap) callconv(.c) c_int {
        return 0;
    }
    fn upload(_: ?*anyopaque, _: u32, _: u32, _: u32, _: u32, _: *const c_api.GlyphBitmap) callconv(.c) void {}
    fn create(_: ?*anyopaque, _: u32, _: u32) callconv(.c) void {}
};

/// A core whose main rows are all mirrored and empty, over a packer holding
/// closed shelves from a previous epoch. Nothing references those shelves, so a
/// collection that is allowed to run reclaims them.
fn initCoreForAtlasGcTest(core: *Core, rows: u32) !void {
    core.cb.on_rasterize_glyph = AtlasGcTestCallbacks.rasterize;
    core.cb.on_atlas_upload = AtlasGcTestCallbacks.upload;
    core.cb.on_atlas_create = AtlasGcTestCallbacks.create;

    try core.grid.resize(rows, 4);
    try core.ensureScrollCache(rows);
    var r: u32 = 0;
    while (r < rows) : (r += 1) core.scroll_cache_valid.set(r);

    var packer = shelf_packer.ShelfPacker.init(16, 4096);
    _ = packer.alloc(12, 1).?;
    _ = packer.alloc(12, 1).?;
    _ = packer.alloc(12, 1).?;
    packer.beginEpoch();
    core.atlas_packer = packer;
}

fn recycledShelfCount(core: *Core) u32 {
    const packer = &(core.atlas_packer.?);
    var n: u32 = 0;
    var i: u32 = 0;
    while (i < packer.shelf_count) : (i += 1) {
        if (packer.shelves[i].recycled) n += 1;
    }
    return n;
}

test "atlas reclamation runs when the frontend owns no surface" {
    var core = Core.initForTest(std.testing.allocator);
    defer core.deinitForTest();
    defer core.known_external_grids.deinit(core.alloc);
    try initCoreForAtlasGcTest(&core, 4);

    try std.testing.expect(core.collectAtlasGarbage());
    try std.testing.expect(recycledShelfCount(&core) > 0);
}

test "atlas reclamation stands down for a frontend-owned surface" {
    var core = Core.initForTest(std.testing.allocator);
    defer core.deinitForTest();
    defer core.known_external_grids.deinit(core.alloc);
    try initCoreForAtlasGcTest(&core, 4);

    // The ordinary shape of a float: cell storage, placement, and a frontend
    // surface the core was told about.
    try core.grid.resizeGrid(7, 2, 2);
    try core.grid.external_grids.put(core.alloc, 7, .{ .win = 7, .start_row = 0, .start_col = 0 });
    try core.known_external_grids.put(core.alloc, 7, .{ .win = 7, .start_row = 0, .start_col = 0, .rows = 2, .cols = 2 });

    try std.testing.expect(!core.collectAtlasGarbage());
    try std.testing.expectEqual(@as(u32, 0), recycledShelfCount(&core));
}

test "atlas reclamation stands down for a surface that outlived its grid buffer" {
    // grid_destroy can drop the GridBuf while the frontend surface is still on
    // screen. Deriving eligibility from sub_grids missed exactly that window
    // and reclaimed shelves the surface was still drawing from.
    var core = Core.initForTest(std.testing.allocator);
    defer core.deinitForTest();
    defer core.known_external_grids.deinit(core.alloc);
    try initCoreForAtlasGcTest(&core, 4);

    try core.known_external_grids.put(core.alloc, 7, .{ .win = 7, .start_row = 0, .start_col = 0, .rows = 2, .cols = 2 });
    try std.testing.expect(!core.grid.sub_grids.contains(7));

    try std.testing.expect(!core.collectAtlasGarbage());
    try std.testing.expectEqual(@as(u32, 0), recycledShelfCount(&core));
}
