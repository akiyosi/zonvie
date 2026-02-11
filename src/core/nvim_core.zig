const c_api = @import("c_api.zig");
const std = @import("std");
const mp = @import("msgpack.zig");
const rpc = @import("rpc_encode.zig");
const grid_mod = @import("grid.zig");
const Grid = grid_mod.Grid;
const highlight = @import("highlight.zig");
const Highlights = highlight.Highlights;
const ResolvedAttrWithStyles = highlight.ResolvedAttrWithStyles;
const redraw = @import("redraw_handler.zig");
const Logger = @import("log.zig").Logger;
const config = @import("config.zig");
const flush = @import("flush.zig");
const rpc_session = @import("rpc_session.zig");
const shelf_packer = @import("shelf_packer.zig");

pub const Callbacks = struct {
    on_vertices: ?*const fn (
        ctx: ?*anyopaque,
        main_verts: [*]const c_api.Vertex,
        main_count: usize,
        cursor_verts: [*]const c_api.Vertex,
        cursor_count: usize,
    ) callconv(.c) void = null,

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

    on_render_plan: ?*const fn (
        ctx: ?*anyopaque,
        bg_spans: [*]const c_api.BgSpan,
        bg_span_count: usize,
        text_runs: [*]const c_api.TextRun,
        text_run_count: usize,
        rows: u32,
        cols: u32,
        cursor: ?*const c_api.Cursor,
    ) callconv(.c) void = null,

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

    /// Called when a grid should be displayed in an external window.
    on_external_window: ?*const fn (ctx: ?*anyopaque, grid_id: i64, win: i64, rows: u32, cols: u32, start_row: i32, start_col: i32) callconv(.c) void = null,

    /// Called when an external grid is closed.
    on_external_window_close: ?*const fn (ctx: ?*anyopaque, grid_id: i64) callconv(.c) void = null,

    /// Called to update vertices for an external grid.
    on_external_vertices: ?*const fn (ctx: ?*anyopaque, grid_id: i64, verts: [*]const c_api.Vertex, vert_count: usize, rows: u32, cols: u32) callconv(.c) void = null,

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
};

const PipeReader = rpc_session.PipeReader;
const CwdOwner = rpc_session.CwdOwner;

const GridEntry = flush.GridEntry;
const MAX_CACHED_SUBGRIDS = flush.MAX_CACHED_SUBGRIDS;
const CachedSubgrid = flush.CachedSubgrid;
const STYLE_BOLD = flush.STYLE_BOLD;
const STYLE_ITALIC = flush.STYLE_ITALIC;
const STYLE_STRIKETHROUGH = flush.STYLE_STRIKETHROUGH;
const STYLE_UNDERLINE = flush.STYLE_UNDERLINE;
const STYLE_UNDERCURL = flush.STYLE_UNDERCURL;
const STYLE_UNDERDOUBLE = flush.STYLE_UNDERDOUBLE;
const STYLE_UNDERDOTTED = flush.STYLE_UNDERDOTTED;
const STYLE_UNDERDASHED = flush.STYLE_UNDERDASHED;
const RenderCell = flush.RenderCell;
const packStyleFlags = flush.packStyleFlags;
const MsgCachedLine = flush.MsgCachedLine;
pub const FlushCache = flush.FlushCache;

pub const Core = struct {
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

    // Reusable scratch buffers (zero-allocation hot path)
    tmp_cells: std.ArrayListUnmanaged(RenderCell) = .{},
    row_cells: std.ArrayListUnmanaged(RenderCell) = .{},
    grid_entries: std.ArrayListUnmanaged(GridEntry) = .{},
    key_buf: std.ArrayListUnmanaged(u8) = .{},

    msgid: std.atomic.Value(i64) = std.atomic.Value(i64).init(1),
    write_mu: std.Thread.Mutex = .{},

    // Mutex to protect grid state access from concurrent RPC and UI threads.
    // Lock order: grid_mu must be acquired before write_mu if both are needed.
    grid_mu: std.Thread.Mutex = .{},

    stop_flag: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    thread: ?std.Thread = null,

    child_handle: ?std.process.Child.Id = null,
    stdin_file: ?std.fs.File = null,
    stdout_file: ?std.fs.File = null,
    stderr_file: ?std.fs.File = null,
    stderr_thread: ?std.Thread = null,

    drawable_w_px: u32 = 1,
    drawable_h_px: u32 = 1,
    cell_w_px: u32 = 1,
    cell_h_px: u32 = 1,

    /// Extra pixels between lines (Neovim 'linespace').
    linespace_px: u32 = 0,

    init_rows: u32 = 24,
    init_cols: u32 = 80,

    last_layout_rows: u32 = 0,
    last_layout_cols: u32 = 0,
    pending_resize_rows: u32 = 0,
    pending_resize_cols: u32 = 0,
    pending_resize_valid: bool = false,
    missing_glyph_log_count: u32 = 0,

    // Thread ID of the thread currently inside handleRedraw (grid_mu is already held).
    // When updateLayoutPx is called from the SAME thread, it skips locking since
    // that thread already holds grid_mu. Using thread ID instead of a bool prevents
    // the UI thread from incorrectly skipping the lock when the RPC thread is in redraw.
    redraw_thread_id: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),

    // Tracking for external windows (to detect new/closed external grids)
    known_external_grids: std.AutoHashMapUnmanaged(i64, void) = .{},

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
    hl_cache_size: u32 = 512,

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

    // Phase 2: Core-managed atlas
    atlas_packer: ?shelf_packer.ShelfPacker = null,
    atlas_w: u32 = 2048,
    atlas_h: u32 = 2048,
    atlas_initialized: bool = false,
    atlas_reset_during_flush: bool = false,

    // Owned copy of nvim path (kept alive for runLoop thread)
    nvim_path_owned: ?[]const u8 = null,

    // SSH mode flags
    is_ssh_mode: bool = false,
    ssh_auth_pending: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    ssh_auth_done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    // Popupmenu state (for tracking window)
    popupmenu_win_id: ?i64 = null,
    popupmenu_buf_id: ?i64 = null,

    // RPC channel ID (extracted from nvim_get_api_info response)
    channel_id: ?i64 = null,
    get_api_info_msgid: ?i64 = null,

    // Quit request msgid (for tracking nvim_exec_lua response)
    // Atomic to avoid data race between UI thread (requestQuit) and RPC thread (handleRpcResponse)
    // 0 means no pending request
    quit_request_msgid: std.atomic.Value(i64) = std.atomic.Value(i64).init(0),

    // Clipboard setup done flag
    clipboard_setup_done: bool = false,

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

    pub fn start(self: *Core, nvim_path: []const u8, rows: u32, cols: u32) !void {
        self.init_rows = rows;
        self.init_cols = cols;
        // Copy nvim_path so it outlives the caller's scope (thread safety)
        self.nvim_path_owned = self.alloc.dupe(u8, nvim_path) catch null;
        self.thread = try std.Thread.spawn(.{}, runLoop, .{self});
    }

    pub fn stop(self: *Core) void {
        self.stop_flag.store(true, .seq_cst);

        if (self.stdin_file) |f| {
            f.close();
            self.stdin_file = null;
        }

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
        self.tmp_cells.deinit(self.alloc);
        self.row_cells.deinit(self.alloc);
        self.grid_entries.deinit(self.alloc);
        self.key_buf.deinit(self.alloc);

        // Free nvim path copy
        if (self.nvim_path_owned) |p| {
            self.alloc.free(p);
            self.nvim_path_owned = null;
        }

        // Free caches
        self.deinitHlCache();
        self.deinitGlyphCache();
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
    }

    // --- Highlight cache (heap-allocated, used by flush vertex generation) ---

    /// Initialize highlight cache buffers based on hl_cache_size.
    /// Called lazily on first flush.
    pub fn initHlCache(self: *Core) !void {
        if (self.hl_cache_initialized) return;
        const size = self.hl_cache_size;
        self.hl_cache_buf = try self.alloc.alloc(highlight.ResolvedAttrWithStyles, size);
        self.hl_valid_buf = try self.alloc.alloc(bool, size);
        @memset(self.hl_valid_buf.?, false);
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

    /// Phase 2 glyph resolution: rasterize → pack → upload → build GlyphEntry.
    /// Returns null on unrecoverable failure (rasterize callback returned 0).
    pub fn ensureGlyphPhase2(self: *Core, scalar: u32, style_flags: u32) ?c_api.GlyphEntry {
        // Lazy atlas init
        if (!self.atlas_initialized) {
            self.atlas_packer = shelf_packer.ShelfPacker.init(self.atlas_w, self.atlas_h);
            if (self.cb.on_atlas_create) |f| f(self.ctx, self.atlas_w, self.atlas_h);
            self.atlas_initialized = true;
        }

        // Ask frontend to rasterize (no packing / UV)
        var bm: c_api.GlyphBitmap = std.mem.zeroes(c_api.GlyphBitmap);
        const ok = self.cb.on_rasterize_glyph.?(self.ctx, scalar, style_flags, &bm);
        if (ok == 0) return null; // rasterize failed

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
            };
        }

        // Reject glyphs larger than the atlas (can never fit)
        const pad2 = self.atlas_packer.?.padding * 2;
        if (bm.width + pad2 > self.atlas_w or bm.height + pad2 > self.atlas_h) {
            return null;
        }

        // Try to pack
        var packer = &(self.atlas_packer.?);
        var rect = packer.alloc(bm.width, bm.height);

        // Atlas full → reset and retry once.
        // Flag the reset so the flush loop knows earlier rows have stale UVs.
        if (rect == null) {
            self.atlas_reset_during_flush = true;
            self.log.write("[scroll_debug] atlas_full_reset scalar=0x{x} style={d} bm={d}x{d}\n", .{ scalar, style_flags, bm.width, bm.height });
            self.resetCoreAtlas();
            packer = &(self.atlas_packer.?);
            rect = packer.alloc(bm.width, bm.height);
            if (rect == null) return null; // still can't fit, give up
        }

        const r = rect.?;

        // Upload glyph bitmap at (rect.x + padding, rect.y + padding)
        if (self.cb.on_atlas_upload) |f| {
            f(self.ctx, r.x + packer.padding, r.y + packer.padding, bm.width, bm.height, &bm);
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
        };
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
        if (self.cb.on_atlas_create) |f| f(self.ctx, self.atlas_w, self.atlas_h);
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

    /// Send raw data to child process stdin (for SSH password input).
    /// Signals ssh_auth_done after writing.
    pub fn sendStdinData(self: *Core, data: []const u8) void {
        if (self.stdin_file) |f| {
            _ = f.write(data) catch |e| {
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
    /// For MESSAGE_GRID_ID (Zonvie's own grid), scroll is handled locally instead of sending to Neovim.
    pub fn sendMouseScroll(self: *Core, grid_id: i64, row: i32, col: i32, direction: []const u8) void {
        // Handle scroll for Zonvie's own message grid locally
        if (grid_id == grid_mod.MESSAGE_GRID_ID) {
            self.handleMsgGridScroll(direction);
            return;
        }
        // Resolve grid_id -1 to cursor_grid so Neovim receives a valid grid ID
        const effective_id = if (grid_id == -1) self.grid.cursor_grid else grid_id;
        self.requestMouseScroll(effective_id, row, col, direction) catch |e| {
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

        // Always include main grid first
        if (count < out.len) {
            const m1 = self.grid.getViewportMargins(1);
            out[count] = .{
                .grid_id = 1,
                .zindex = 0, // main grid has lowest zindex
                .start_row = 0,
                .start_col = 0,
                .rows = @intCast(self.grid.rows),
                .cols = @intCast(self.grid.cols),
                .margin_top = @intCast(m1.top),
                .margin_bottom = @intCast(m1.bottom),
                .margin_left = @intCast(m1.left),
                .margin_right = @intCast(m1.right),
            };
            count += 1;
        }

        // Add sub-grids (floating windows)
        var it = self.grid.win_pos.iterator();
        while (it.next()) |entry| {
            if (count >= out.len) break;

            const gid = entry.key_ptr.*;
            if (gid == 1) continue; // skip main grid (already added)

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
    fn updateLayoutPxLocked(
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

        // Keep main grid (id=1) cell metrics for future per-grid font metrics.
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
    pub fn setScreenCols(self: *Core, cols: u32) void {
        self.grid_mu.lock();
        defer self.grid_mu.unlock();
        self.grid.screen_cols = cols;
    }

    // ---- Key event encoding (OS trap -> Zig common encode) ----
    fn emitInputString(self: *Core, s: []const u8) void {
        if (s.len == 0) return;
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

    pub fn sendRaw(self: *Core, bytes: []const u8) !void {
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

        self.write_mu.lock();
        defer self.write_mu.unlock();

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
        const id = self.nextMsgId();
        var buf: rpc.Buf = .empty;
        defer buf.deinit(self.alloc);

        try self.sendRequestHeader(&buf, id, "nvim_ui_attach");

        try rpc.packArray(&buf, self.alloc, 3);
        try rpc.packInt(&buf, self.alloc, @as(i64, @intCast(cols)));
        try rpc.packInt(&buf, self.alloc, @as(i64, @intCast(rows)));

        // Option count: ext_multigrid, ext_hlstate, rgb (always) + optional ext_*
        var opt_count: u32 = 3;
        if (self.ext_windows_enabled) opt_count += 1;
        if (self.ext_cmdline_enabled) opt_count += 1;
        if (self.ext_popupmenu_enabled) opt_count += 1;
        if (self.ext_messages_enabled) opt_count += 1;
        if (self.ext_tabline_enabled) opt_count += 1;
        try rpc.packMap(&buf, self.alloc, opt_count);
        try rpc.packStr(&buf, self.alloc, "ext_multigrid");
        try rpc.packBool(&buf, self.alloc, true);
        try rpc.packStr(&buf, self.alloc, "ext_hlstate");
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

        self.log.write("rpc send: nvim_ui_attach (id={d}, rows={d}, cols={d}, ext_cmdline={any}, ext_popupmenu={any}, ext_messages={any}, ext_tabline={any}, ext_windows={any})\n", .{ id, rows, cols, self.ext_cmdline_enabled, self.ext_popupmenu_enabled, self.ext_messages_enabled, self.ext_tabline_enabled, self.ext_windows_enabled });
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
    pub fn requestTryResizeGrid(self: *Core, grid_id: i64, rows: u32, cols: u32) void {
        // Track the target size for external grids so we can re-send
        // if Neovim overrides our size via grid_resize.
        self.grid.external_grid_target_sizes.put(self.alloc, grid_id, .{ .rows = rows, .cols = cols }) catch {};
        self.requestTryResizeGridInternal(grid_id, rows, cols) catch |e| {
            self.log.write("requestTryResizeGrid error: {any}\n", .{e});
        };
    }

    fn requestTryResizeGridInternal(self: *Core, grid_id: i64, rows: u32, cols: u32) !void {
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
            \\  local lines = vim.split(content, '\n')
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
    fn requestMouseScroll(self: *Core, grid_id: i64, row: i32, col: i32, direction: []const u8) !void {
        const id = self.nextMsgId();
        var buf: rpc.Buf = .empty;
        defer buf.deinit(self.alloc);

        try self.sendRequestHeader(&buf, id, "nvim_input_mouse");

        // nvim_input_mouse takes 6 arguments:
        // button: "wheel" for scroll
        // action: "up" or "down"
        // modifier: "" (empty string for no modifiers)
        // grid: grid_id
        // row: row position
        // col: column position
        try rpc.packArray(&buf, self.alloc, 6);
        try rpc.packStr(&buf, self.alloc, "wheel"); // button
        try rpc.packStr(&buf, self.alloc, direction); // action (up/down)
        try rpc.packStr(&buf, self.alloc, ""); // modifier
        try rpc.packInt(&buf, self.alloc, grid_id); // grid
        try rpc.packInt(&buf, self.alloc, @as(i64, row)); // row
        try rpc.packInt(&buf, self.alloc, @as(i64, col)); // col

        try self.sendRaw(buf.items);

        self.log.write("rpc send: nvim_input_mouse (id={d}) wheel {s} grid={d} row={d} col={d}\n", .{ id, direction, grid_id, row, col });
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

    pub fn pumpStderr(self: *Core, f: std.fs.File) void {
        rpc_session.pumpStderr(self, f);
    }

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
