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
};

const PipeReader = struct {
    file: std.fs.File,
    buf: [8192]u8 = undefined,
    start: usize = 0,
    end: usize = 0,

    fn fill(self: *PipeReader) !void {
        if (self.start < self.end) return;
        const n = try self.file.read(&self.buf);
        self.start = 0;
        self.end = n;
    }

    pub fn read(self: *PipeReader, dest: []u8) !usize {
        if (dest.len == 0) return 0;

        var out_i: usize = 0;
        while (out_i < dest.len) {
            try self.fill();
            if (self.end == 0) break; // EOF

            const avail = self.end - self.start;
            const take = @min(avail, dest.len - out_i);
            std.mem.copyForwards(u8, dest[out_i .. out_i + take], self.buf[self.start .. self.start + take]);
            self.start += take;
            out_i += take;

            if (take == 0) break;
        }
        return out_i;
    }

    pub fn readByte(self: *PipeReader) !u8 {
        var one: [1]u8 = undefined;
        const n = try self.read(one[0..]);
        if (n != 1) return error.EndOfStream;
        return one[0];
    }

    pub fn readNoEof(self: *PipeReader, dest: []u8) !void {
        var off: usize = 0;
        while (off < dest.len) {
            const n = try self.read(dest[off..]);
            if (n == 0) return error.EndOfStream;
            off += n;
        }
    }
};

const CwdOwner = struct {
    open: bool = false,
    dir: std.fs.Dir = undefined,

    pub fn close(self: *CwdOwner) void {
        if (self.open) {
            self.dir.close();
            self.open = false;
        }
    }

    pub fn openPreferred(self: *CwdOwner, alloc: std.mem.Allocator, log: *Logger) void {
        self.close();
    
        // Prefer $HOME when present.
        const home = std.process.getEnvVarOwned(alloc, "HOME") catch null;
        defer if (home) |s| alloc.free(s);
    
        if (home) |home_path| {
            if (std.fs.openDirAbsolute(home_path, .{})) |d| {
                self.dir = d;
                self.open = true;
                log.write("child cwd set to HOME: {s}\n", .{home_path});
                return;
            } else |e| {
                log.write("openDirAbsolute(HOME) failed: {any} (HOME={s})\n", .{ e, home_path });
            }
        } else {
            log.write("HOME is not set; leaving child cwd as default\n", .{});
        }
    }

    pub fn applyToChild(self: *CwdOwner, child: *std.process.Child) void {
        const CwdT = @TypeOf(child.cwd_dir);

        comptime {
            if (!(CwdT == ?std.fs.Dir or CwdT == std.fs.Dir or CwdT == ?*std.fs.Dir or CwdT == *std.fs.Dir)) {
                @compileError("Unsupported std.process.Child.cwd_dir type: " ++ @typeName(CwdT));
            }
        }

        if (!self.open) return;

        if (comptime CwdT == ?std.fs.Dir) {
            child.cwd_dir = self.dir;
            return;
        }
        if (comptime CwdT == std.fs.Dir) {
            child.cwd_dir = self.dir;
            return;
        }
        if (comptime CwdT == ?*std.fs.Dir) {
            child.cwd_dir = &self.dir;
            return;
        }
        if (comptime CwdT == *std.fs.Dir) {
            child.cwd_dir = &self.dir;
            return;
        }
    }
};

const GridEntry = struct {
    grid_id: i64,
    zindex: i64,
    compindex: i64,
    order: u64,
};

// Pre-computed subgrid info for row-mode compose optimization.
// Caches win_pos/sub_grids lookups to avoid per-row hash map access.
const MAX_CACHED_SUBGRIDS = 32;
const CachedSubgrid = struct {
    grid_id: i64,
    row_start: u32, // pos.row
    row_end: u32, // pos.row + sg.rows (exclusive)
    col_start: u32, // pos.col
    sg_cols: u32,
    sg_rows: u32,
    cells: [*]const grid_mod.Cell, // pointer to subgrid cells
};

// Style flags for RenderCell (bit positions)
const STYLE_BOLD: u8 = 1 << 0;
const STYLE_ITALIC: u8 = 1 << 1;
const STYLE_STRIKETHROUGH: u8 = 1 << 2;
const STYLE_UNDERLINE: u8 = 1 << 3;
const STYLE_UNDERCURL: u8 = 1 << 4;
const STYLE_UNDERDOUBLE: u8 = 1 << 5;
const STYLE_UNDERDOTTED: u8 = 1 << 6;
const STYLE_UNDERDASHED: u8 = 1 << 7;

/// Internal cell representation with grid_id tracking for smooth scrolling support.
const RenderCell = struct {
    scalar: u32,
    fgRGB: u32,
    bgRGB: u32,
    spRGB: u32, // special color for decorations
    grid_id: i64, // 1 = main grid, >1 = sub-grid (float window)
    style_flags: u8, // packed style flags
};

/// Pack style flags from ResolvedAttrWithStyles into u8.
fn packStyleFlags(a: ResolvedAttrWithStyles) u8 {
    var flags: u8 = 0;
    if (a.bold) flags |= STYLE_BOLD;
    if (a.italic) flags |= STYLE_ITALIC;
    if (a.strikethrough) flags |= STYLE_STRIKETHROUGH;
    if (a.underline) flags |= STYLE_UNDERLINE;
    if (a.undercurl) flags |= STYLE_UNDERCURL;
    if (a.underdouble) flags |= STYLE_UNDERDOUBLE;
    if (a.underdotted) flags |= STYLE_UNDERDOTTED;
    if (a.underdashed) flags |= STYLE_UNDERDASHED;
    return flags;
}

/// Cached line data for msg_show scrolling optimization.
const MsgCachedLine = struct {
    data: [256]u8 = undefined,
    len: u8 = 0,
    display_width: u16 = 0,
};

/// Cache for highlight and glyph lookups during vertex generation.
/// Shared across all rows in a single flush to maximize cache hits.
pub const FlushCache = struct {
    const HL_CACHE_SIZE = 64;

    // Highlight cache: direct-index for O(1) lookup (hl_id is typically < 64)
    hl_cache: [HL_CACHE_SIZE]ResolvedAttrWithStyles = undefined,
    hl_valid: [HL_CACHE_SIZE]bool = [_]bool{false} ** HL_CACHE_SIZE,

    // Performance counters
    perf_hl_cache_hits: u32 = 0,
    perf_hl_cache_misses: u32 = 0,
    perf_glyph_ascii_hits: u32 = 0,
    perf_glyph_ascii_misses: u32 = 0,
    perf_glyph_nonascii_hits: u32 = 0,
    perf_glyph_nonascii_misses: u32 = 0,

    /// Get resolved attribute with caching.
    pub fn getAttr(self: *FlushCache, hl: *Highlights, hl_id: u32) ResolvedAttrWithStyles {
        if (hl_id < HL_CACHE_SIZE) {
            if (self.hl_valid[hl_id]) {
                self.perf_hl_cache_hits += 1;
                return self.hl_cache[hl_id];
            }
            self.perf_hl_cache_misses += 1;
            const resolved = hl.getWithStyles(hl_id);
            self.hl_cache[hl_id] = resolved;
            self.hl_valid[hl_id] = true;
            return resolved;
        }
        // Fallback for hl_id >= 64 (rare)
        self.perf_hl_cache_misses += 1;
        return hl.getWithStyles(hl_id);
    }

    /// Reset cache for a new flush.
    pub fn reset(self: *FlushCache) void {
        @memset(&self.hl_valid, false);
        self.perf_hl_cache_hits = 0;
        self.perf_hl_cache_misses = 0;
        self.perf_glyph_ascii_hits = 0;
        self.perf_glyph_ascii_misses = 0;
        self.perf_glyph_nonascii_hits = 0;
        self.perf_glyph_nonascii_misses = 0;
    }
};

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

    // Flag to track if we're inside handleRedraw (grid_mu is already held).
    // When true, updateLayoutPx skips locking since the same thread already holds grid_mu.
    in_handle_redraw: bool = false,

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

    // Dynamic glyph caches (allocated on first use, reallocated if size changes)
    glyph_cache_ascii: ?[]c_api.GlyphEntry = null,
    glyph_valid_ascii: ?[]bool = null,
    glyph_cache_non_ascii: ?[]c_api.GlyphEntry = null,
    glyph_keys_non_ascii: ?[]u64 = null,
    glyph_cache_initialized: bool = false,

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

        // Free glyph caches
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
    fn initGlyphCache(self: *Core) !void {
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

    /// Reset glyph cache valid flags (call at start of each flush)
    fn resetGlyphCacheFlags(self: *Core) void {
        if (self.glyph_valid_ascii) |buf| {
            @memset(buf, false);
        }
        if (self.glyph_keys_non_ascii) |buf| {
            const INVALID_KEY: u64 = 0xFFFFFFFFFFFFFFFF;
            @memset(buf, INVALID_KEY);
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
        self.requestMouseScroll(grid_id, row, col, direction) catch |e| {
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

    /// Get list of visible grids for hit-testing.
    /// Returns number of grids written (up to out.len).
    pub fn getVisibleGrids(self: *Core, out: []c_api.GridInfo) usize {
        // Lock grid_mu to prevent concurrent modification from RPC thread.
        self.grid_mu.lock();
        defer self.grid_mu.unlock();

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
        // If called from within handleRedraw (via callback), grid_mu is already
        // held by the same thread, so we can call the locked version directly.
        // This ensures cell dimensions are updated BEFORE the flush generates vertices.
        if (self.in_handle_redraw) {
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

    fn emitGuiFont(self: *Core, font: []const u8) void {
        if (self.cb.on_guifont) |f| {
            f(self.ctx, font.ptr, font.len);
        }
    }

    fn emitLineSpace(self: *Core, px: i32) void {
        if (self.cb.on_linespace) |f| {
            f(self.ctx, px);
        }
    }

    fn emitSetTitle(self: *Core, title: []const u8) void {
        self.log.write("[core] emitSetTitle: len={d} cb={any}\n", .{ title.len, self.cb.on_set_title != null });
        if (self.cb.on_set_title) |f| {
            f(self.ctx, title.ptr, title.len);
        }
    }

    fn sendRaw(self: *Core, bytes: []const u8) !void {
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

    fn nextMsgId(self: *Core) i64 {
        return self.msgid.fetchAdd(1, .seq_cst);
    }

    fn sendRequestHeader(self: *Core, buf: *rpc.Buf, id: i64, method: []const u8) !void {
        try rpc.packArray(buf, self.alloc, 4);
        try rpc.packInt(buf, self.alloc, 0);
        try rpc.packInt(buf, self.alloc, id);
        try rpc.packStr(buf, self.alloc, method);
    }

    fn requestGetApiInfo(self: *Core) !void {
        const id = self.nextMsgId();
        self.get_api_info_msgid = id;  // Save msgid for response matching
        var buf: rpc.Buf = .empty;
        defer buf.deinit(self.alloc);

        try self.sendRequestHeader(&buf, id, "nvim_get_api_info");
        try rpc.packArray(&buf, self.alloc, 0);
        try self.sendRaw(buf.items);

        self.log.write("rpc send: nvim_get_api_info (id={d})\n", .{id});
    }

    fn requestSetClientInfo(self: *Core) !void {
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

    fn requestUiAttach(self: *Core, rows: u32, cols: u32) !void {
        const id = self.nextMsgId();
        var buf: rpc.Buf = .empty;
        defer buf.deinit(self.alloc);

        try self.sendRequestHeader(&buf, id, "nvim_ui_attach");

        try rpc.packArray(&buf, self.alloc, 3);
        try rpc.packInt(&buf, self.alloc, @as(i64, @intCast(cols)));
        try rpc.packInt(&buf, self.alloc, @as(i64, @intCast(rows)));

        // Option count: ext_multigrid, ext_hlstate, rgb + (optional ext_cmdline) + (optional ext_popupmenu) + (optional ext_messages) + (optional ext_tabline)
        var opt_count: u32 = 3;
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

        self.log.write("rpc send: nvim_ui_attach (id={d}, rows={d}, cols={d}, ext_cmdline={any}, ext_popupmenu={any}, ext_messages={any}, ext_tabline={any})\n", .{ id, rows, cols, self.ext_cmdline_enabled, self.ext_popupmenu_enabled, self.ext_messages_enabled, self.ext_tabline_enabled });
    }

    fn requestTryResize(self: *Core, rows: u32, cols: u32) !void {
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

    fn requestInput(self: *Core, keys: []const u8) !void {
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
    fn requestExecLua(self: *Core, lua_code: []const u8) !void {
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
    fn createMessageSplit(self: *Core, content: []const u8, line_count: u32, enter: bool, clear_prompt: bool, label: ?[]const u8) !void {
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

    const FlushCtx = struct {
        core: *Core,

        pub fn onFlush(ctx: *FlushCtx, rows: u32, cols: u32) !void {
            const n_cells: usize = @as(usize, rows) * @as(usize, cols);
            if (n_cells == 0) return;

            // === PERF LOG: flush開始 ===
            const perf_enabled = ctx.core.log.cb != null;
            var t_flush_start: i128 = 0;
            if (perf_enabled) {
                t_flush_start = std.time.nanoTimestamp();
            }
            defer {
                if (perf_enabled) {
                    const t_flush_end = std.time.nanoTimestamp();
                    const flush_us: i64 = @intCast(@divTrunc(@max(0, t_flush_end - t_flush_start), 1000));
                    ctx.core.log.write("[perf] flush_total rows={d} cols={d} us={d}\n", .{ rows, cols, flush_us });
                }
            }

            ctx.core.missing_glyph_log_count = 0;

            // Notify frontend about scrolled grids BEFORE vertex generation.
            // This allows Swift to clear pixel offsets before new vertices are rendered,
            // preventing double-shift glitches in split windows.
            if (ctx.core.cb.on_grid_scroll) |cb| {
                for (ctx.core.grid.scrolled_grid_ids[0..ctx.core.grid.scrolled_grid_count]) |grid_id| {
                    cb(ctx.core.ctx, grid_id);
                }
            }
            ctx.core.grid.clearScrolledGrids();

            // Check msg_show throttle timeout for external commands
            ctx.core.checkMsgShowThrottleTimeout();

            // Process cmdline changes BEFORE generating vertices
            // This ensures cursor position is restored before vertex generation
            ctx.core.notifyCmdlineChanges();

            var cursor_out: c_api.Cursor = .{
                .enabled = 0,
                .row = 0,
                .col = 0,
                .shape = .block,
                .cell_percentage = 100,
                .fgRGB = 0,
                .bgRGB = 0,
                .blink_wait_ms = 0,
                .blink_on_ms = 0,
                .blink_off_ms = 0,
            };
            
            // NOTE: cursor row/col are relative to cursor_grid.
            // Convert them to screen(grid 1) coordinates using win_pos,
            // because we already flattened sub-grids into tmp[] in screen space.
            if (ctx.core.grid.cursor_valid and ctx.core.grid.cursor_visible) {
                var cr: i64 = @as(i64, ctx.core.grid.cursor_row);
                var cc: i64 = @as(i64, ctx.core.grid.cursor_col);

                if (ctx.core.grid.cursor_grid != 1) {
                    if (ctx.core.grid.win_pos.get(ctx.core.grid.cursor_grid)) |p| {
                        cr += @as(i64, p.row);
                        cc += @as(i64, p.col);
                    } else {
                        cr = -1;
                        cc = -1;
                    }
                }

                if (cr >= 0 and cc >= 0 and cr < @as(i64, rows) and cc < @as(i64, cols)) {
                    const row: u32 = @intCast(cr);
                    const col: u32 = @intCast(cc);

                    cursor_out.enabled = 1;
                    cursor_out.row = row;
                    cursor_out.col = col;
                    cursor_out.shape = switch (ctx.core.grid.cursor_shape) {
                        .block => .block,
                        .vertical => .vertical,
                        .horizontal => .horizontal,
                    };
                    cursor_out.cell_percentage = ctx.core.grid.cursor_cell_percentage;

                    // Set blink parameters
                    cursor_out.blink_wait_ms = ctx.core.grid.cursor_blink_wait_ms;
                    cursor_out.blink_on_ms = ctx.core.grid.cursor_blink_on_ms;
                    cursor_out.blink_off_ms = ctx.core.grid.cursor_blink_off_ms;

                    // Resolve cursor colors
                    if (ctx.core.grid.cursor_attr_id != 0) {
                        const attr = ctx.core.hl.get(ctx.core.grid.cursor_attr_id);
                        cursor_out.fgRGB = attr.fg;
                        cursor_out.bgRGB = attr.bg;
                    } else {
                        // attr_id == 0: swap default colors (per Nvim spec)
                        cursor_out.fgRGB = ctx.core.hl.default_bg;
                        cursor_out.bgRGB = ctx.core.hl.default_fg;
                    }

                    // Debug log: cursor_out values
                    if (ctx.core.log.cb != null) {
                        ctx.core.log.write("cursor_out: shape={d} cell_pct={d} blink=({d},{d},{d}) row={d} col={d}\n", .{
                            @intFromEnum(cursor_out.shape),
                            cursor_out.cell_percentage,
                            cursor_out.blink_wait_ms,
                            cursor_out.blink_on_ms,
                            cursor_out.blink_off_ms,
                            cursor_out.row,
                            cursor_out.col,
                        });
                    }
                }
            }

            // --- fast path: build vertices directly (skip bg_spans/text_runs/scalars_buf) ---
            // Prefer partial updates when available.
            if (ctx.core.cb.on_vertices_partial != null or ctx.core.cb.on_vertices != null) {
                const pf_opt = ctx.core.cb.on_vertices_partial;
                const vf_opt = ctx.core.cb.on_vertices;

                // Decide what needs rebuilding/sending.
                const need_main: bool = (ctx.core.grid.content_rev != ctx.core.last_sent_content_rev);
                const need_cursor: bool = (ctx.core.grid.cursor_rev != ctx.core.last_sent_cursor_rev);

                // If nothing changed, avoid doing any work.
                if (!need_main and !need_cursor) return;

                var main = &ctx.core.main_verts;
                var cursor = &ctx.core.cursor_verts;

                const dw: f32 = @floatFromInt(ctx.core.drawable_w_px);
                const dh: f32 = @floatFromInt(ctx.core.drawable_h_px);
                const cellW: f32 = @floatFromInt(ctx.core.cell_w_px);
                const cellH: f32 = @floatFromInt(ctx.core.cell_h_px);

                const lineSpacePx: u32 = ctx.core.linespace_px;
                const topPadPx: u32 = lineSpacePx / 2;
                const topPad: f32 = @floatFromInt(topPadPx);

                const Helpers = struct {
                    fn ndc(x: f32, y: f32, vw: f32, vh: f32) [2]f32 {
                        const nx = (x / vw) * 2.0 - 1.0;
                        const ny = 1.0 - (y / vh) * 2.0;
                        return .{ nx, ny };
                    }

                    inline fn rgb(v: u32) [4]f32 {
                        const rr: f32 = @as(f32, @floatFromInt((v >> 16) & 0xFF)) / 255.0;
                        const gg: f32 = @as(f32, @floatFromInt((v >> 8) & 0xFF)) / 255.0;
                        const bb: f32 = @as(f32, @floatFromInt(v & 0xFF)) / 255.0;
                        return .{ rr, gg, bb, 1.0 };
                    }

                    inline fn rgba(v: u32, alpha: f32) [4]f32 {
                        const rr: f32 = @as(f32, @floatFromInt((v >> 16) & 0xFF)) / 255.0;
                        const gg: f32 = @as(f32, @floatFromInt((v >> 8) & 0xFF)) / 255.0;
                        const bb: f32 = @as(f32, @floatFromInt(v & 0xFF)) / 255.0;
                        return .{ rr, gg, bb, alpha };
                    }

                    const solid_uv: [2]f32 = .{ -1.0, -1.0 };

                    fn pushSolidQuad(
                        out: *std.ArrayListUnmanaged(c_api.Vertex),
                        alloc: std.mem.Allocator,
                        x0: f32, y0: f32, x1: f32, y1: f32,
                        col: [4]f32,
                        vw: f32, vh: f32,
                        grid_id: i64,
                    ) !void {
                        const p0 = ndc(x0, y0, vw, vh);
                        const p1 = ndc(x1, y0, vw, vh);
                        const p2 = ndc(x0, y1, vw, vh);
                        const p3 = ndc(x1, y1, vw, vh);

                        try out.ensureUnusedCapacity(alloc, 6);
                        const v = out.addManyAsSliceAssumeCapacity(6);

                        v[0] = .{ .position = p0, .texCoord = solid_uv, .color = col, .grid_id = grid_id, .deco_flags = 0, .deco_phase = 0 };
                        v[1] = .{ .position = p2, .texCoord = solid_uv, .color = col, .grid_id = grid_id, .deco_flags = 0, .deco_phase = 0 };
                        v[2] = .{ .position = p1, .texCoord = solid_uv, .color = col, .grid_id = grid_id, .deco_flags = 0, .deco_phase = 0 };

                        v[3] = .{ .position = p1, .texCoord = solid_uv, .color = col, .grid_id = grid_id, .deco_flags = 0, .deco_phase = 0 };
                        v[4] = .{ .position = p2, .texCoord = solid_uv, .color = col, .grid_id = grid_id, .deco_flags = 0, .deco_phase = 0 };
                        v[5] = .{ .position = p3, .texCoord = solid_uv, .color = col, .grid_id = grid_id, .deco_flags = 0, .deco_phase = 0 };
                    }

                    fn pushGlyphQuad(
                        out: *std.ArrayListUnmanaged(c_api.Vertex),
                        alloc: std.mem.Allocator,
                        x0: f32, y0: f32, x1: f32, y1: f32,
                        uv0: [2]f32, uv1: [2]f32, uv2: [2]f32, uv3: [2]f32,
                        col: [4]f32,
                        vw: f32, vh: f32,
                        grid_id: i64,
                    ) !void {
                        const p0 = ndc(x0, y0, vw, vh);
                        const p1 = ndc(x1, y0, vw, vh);
                        const p2 = ndc(x0, y1, vw, vh);
                        const p3 = ndc(x1, y1, vw, vh);

                        try out.ensureUnusedCapacity(alloc, 6);
                        const v = out.addManyAsSliceAssumeCapacity(6);

                        v[0] = .{ .position = p0, .texCoord = uv0, .color = col, .grid_id = grid_id, .deco_flags = 0, .deco_phase = 0 };
                        v[1] = .{ .position = p2, .texCoord = uv2, .color = col, .grid_id = grid_id, .deco_flags = 0, .deco_phase = 0 };
                        v[2] = .{ .position = p1, .texCoord = uv1, .color = col, .grid_id = grid_id, .deco_flags = 0, .deco_phase = 0 };

                        v[3] = .{ .position = p1, .texCoord = uv1, .color = col, .grid_id = grid_id, .deco_flags = 0, .deco_phase = 0 };
                        v[4] = .{ .position = p2, .texCoord = uv2, .color = col, .grid_id = grid_id, .deco_flags = 0, .deco_phase = 0 };
                        v[5] = .{ .position = p3, .texCoord = uv3, .color = col, .grid_id = grid_id, .deco_flags = 0, .deco_phase = 0 };
                    }

                    fn pushDecoQuad(
                        out: *std.ArrayListUnmanaged(c_api.Vertex),
                        alloc: std.mem.Allocator,
                        x0: f32, y0: f32, x1: f32, y1: f32,
                        col: [4]f32,
                        vw: f32, vh: f32,
                        grid_id: i64,
                        deco_flags: u32,
                        deco_phase: f32,
                    ) !void {
                        const p0 = ndc(x0, y0, vw, vh);
                        const p1 = ndc(x1, y0, vw, vh);
                        const p2 = ndc(x0, y1, vw, vh);
                        const p3 = ndc(x1, y1, vw, vh);

                        // UV coordinates for decorations:
                        // - UV.x = -1 (sentinel for solid/decoration)
                        // - UV.y = local Y position within quad (0.0 at top, 1.0 at bottom)
                        // This allows the shader to know the fragment's position within the quad
                        const uv_top: [2]f32 = .{ -1.0, 0.0 };    // y0 vertices (top)
                        const uv_bottom: [2]f32 = .{ -1.0, 1.0 }; // y1 vertices (bottom)

                        try out.ensureUnusedCapacity(alloc, 6);
                        const v = out.addManyAsSliceAssumeCapacity(6);

                        // Triangle 1: p0 (top-left), p2 (bottom-left), p1 (top-right)
                        v[0] = .{ .position = p0, .texCoord = uv_top, .color = col, .grid_id = grid_id, .deco_flags = deco_flags, .deco_phase = deco_phase };
                        v[1] = .{ .position = p2, .texCoord = uv_bottom, .color = col, .grid_id = grid_id, .deco_flags = deco_flags, .deco_phase = deco_phase };
                        v[2] = .{ .position = p1, .texCoord = uv_top, .color = col, .grid_id = grid_id, .deco_flags = deco_flags, .deco_phase = deco_phase };

                        // Triangle 2: p1 (top-right), p2 (bottom-left), p3 (bottom-right)
                        v[3] = .{ .position = p1, .texCoord = uv_top, .color = col, .grid_id = grid_id, .deco_flags = deco_flags, .deco_phase = deco_phase };
                        v[4] = .{ .position = p2, .texCoord = uv_bottom, .color = col, .grid_id = grid_id, .deco_flags = deco_flags, .deco_phase = deco_phase };
                        v[5] = .{ .position = p3, .texCoord = uv_bottom, .color = col, .grid_id = grid_id, .deco_flags = deco_flags, .deco_phase = deco_phase };
                    }
                };

                var sent_main_by_rows: bool = false;

                // ----------------------------
                // Rebuild MAIN only when needed
                // ----------------------------
                if (need_main) {
                    main.clearRetainingCapacity();
                    var tmp: []RenderCell = &[_]RenderCell{};

                    // Collect visible grids using persistent buffer (zero-allocation hot path)
                    ctx.core.grid_entries.clearRetainingCapacity();
                    const est_count = ctx.core.grid.win_pos.count();
                    if (est_count != 0) {
                        try ctx.core.grid_entries.ensureTotalCapacity(ctx.core.alloc, est_count);

                        var itp = ctx.core.grid.win_pos.iterator();
                        while (itp.next()) |e| {
                            const grid_id = e.key_ptr.*;
                            // Only sub grids
                            if (grid_id == 1) continue;

                            const layer = ctx.core.grid.win_layer.get(grid_id) orelse @as(@import("grid.zig").WinLayer, .{
                                .zindex = 0,
                                .compindex = 0,
                                .order = 0,
                            });
                            ctx.core.grid_entries.appendAssumeCapacity(.{
                                .grid_id = grid_id,
                                .zindex = layer.zindex,
                                .compindex = layer.compindex,
                                .order = layer.order,
                            });
                        }

                        // Sort back-to-front: smaller first, larger last (insertion sort)
                        {
                            var j: usize = 1;
                            while (j < ctx.core.grid_entries.items.len) : (j += 1) {
                                const key = ctx.core.grid_entries.items[j];
                                var k: usize = j;
                                while (k > 0) {
                                    const prev = ctx.core.grid_entries.items[k - 1];

                                    const less =
                                        (key.zindex < prev.zindex) or
                                        (key.zindex == prev.zindex and key.compindex < prev.compindex) or
                                        (key.zindex == prev.zindex and key.compindex == prev.compindex and key.order < prev.order) or
                                        (key.zindex == prev.zindex and key.compindex == prev.compindex and key.order == prev.order and key.grid_id < prev.grid_id);

                                    if (!less) break;

                                    ctx.core.grid_entries.items[k] = prev;
                                    k -= 1;
                                }
                                ctx.core.grid_entries.items[k] = key;
                            }
                        }
                    }

                    // -------------------------------------------------
                    // Row callback mode: send only dirty rows (main grid)
                    // -------------------------------------------------

                    const use_row_mode = (ctx.core.cb.on_vertices_row != null);
                    if (use_row_mode) {
                        const row_cb = ctx.core.cb.on_vertices_row.?;
                        sent_main_by_rows = true;

                        const rebuild_all = ctx.core.grid.dirty_all;
                        var had_glyph_miss: bool = false;
                        const row_cells = &ctx.core.row_cells;
                        if (cols != 0) {
                            try row_cells.ensureTotalCapacity(ctx.core.alloc, cols);
                            row_cells.items.len = cols;
                        }

                        var log_dirty_rows: u32 = 0;
                        const log_enabled = ctx.core.log.cb != null;
                        var t_rows_start_ns: i128 = 0;
                        if (log_enabled) {
                            if (rebuild_all) {
                                log_dirty_rows = rows;
                            } else {
                                log_dirty_rows = 0;
                                var rr: u32 = 0;
                                while (rr < rows) : (rr += 1) {
                                    if (ctx.core.grid.dirty_rows.isSet(@as(usize, rr))) {
                                        log_dirty_rows += 1;
                                    }
                                }
                            }
                            t_rows_start_ns = std.time.nanoTimestamp();
                        }

                        // HL cache: direct-index for O(1) lookup (hl_id is typically < 64)
                        // Placed outside row loop - initialized once per flush, shared across all rows
                        // ResolvedAttrWithStyles now includes pre-computed style_flags
                        const HL_CACHE_SIZE = 64;
                        var hl_cache: [HL_CACHE_SIZE]highlight.ResolvedAttrWithStyles = undefined;
                        var hl_valid: [HL_CACHE_SIZE]bool = [_]bool{false} ** HL_CACHE_SIZE;

                        // Performance counters for cache statistics
                        var perf_hl_cache_hits: u32 = 0;
                        var perf_hl_cache_misses: u32 = 0;
                        var perf_glyph_ascii_hits: u32 = 0;
                        var perf_glyph_ascii_misses: u32 = 0;
                        var perf_glyph_nonascii_hits: u32 = 0;
                        var perf_glyph_nonascii_misses: u32 = 0;

                        // Initialize dynamic glyph caches if not already done
                        ctx.core.initGlyphCache() catch {
                            ctx.core.log.write("[flush] Failed to initialize glyph cache\n", .{});
                        };
                        // Reset glyph cache valid flags for this flush
                        ctx.core.resetGlyphCacheFlags();

                        // Get dynamic cache references (fallback to empty if not initialized)
                        const glyph_cache_ascii = ctx.core.glyph_cache_ascii;
                        const glyph_valid_ascii = ctx.core.glyph_valid_ascii;
                        const glyph_cache_non_ascii = ctx.core.glyph_cache_non_ascii;
                        const glyph_keys_non_ascii = ctx.core.glyph_keys_non_ascii;
                        const GLYPH_CACHE_ASCII_SIZE = ctx.core.glyph_cache_ascii_size;
                        const GLYPH_CACHE_NON_ASCII_SIZE = ctx.core.glyph_cache_non_ascii_size;

                        // Pre-compute subgrid info to avoid per-row hash map lookups
                        // This is a major optimization for full-screen redraws with many subgrids
                        var cached_subgrids: [MAX_CACHED_SUBGRIDS]CachedSubgrid = undefined;
                        var cached_subgrid_count: usize = 0;
                        for (ctx.core.grid_entries.items) |ent| {
                            if (cached_subgrid_count >= MAX_CACHED_SUBGRIDS) break;
                            const subgrid_id = ent.grid_id;
                            const pos = ctx.core.grid.win_pos.get(subgrid_id) orelse continue;
                            const sg = ctx.core.grid.sub_grids.get(subgrid_id) orelse continue;

                            // Skip float windows anchored to external grids
                            if (pos.anchor_grid != 1 and ctx.core.grid.external_grids.contains(pos.anchor_grid)) continue;

                            cached_subgrids[cached_subgrid_count] = .{
                                .grid_id = subgrid_id,
                                .row_start = pos.row,
                                .row_end = pos.row + sg.rows,
                                .col_start = pos.col,
                                .sg_cols = sg.cols,
                                .sg_rows = sg.rows,
                                .cells = sg.cells.ptr,
                            };
                            cached_subgrid_count += 1;
                        }

                        var r: u32 = 0;
                        while (r < rows) : (r += 1) {
                            if (!rebuild_all) {
                                if (!ctx.core.grid.dirty_rows.isSet(@as(usize, r))) continue;
                            }

                            var out = &ctx.core.row_verts;
                            out.clearRetainingCapacity();

                            // Row-mode timing for composition measurement
                            var t_row_compose_start: i128 = 0;
                            if (log_enabled) {
                                t_row_compose_start = std.time.nanoTimestamp();
                            }

                            // Compose this row only (avoid full-screen tmp)
                            // SIMD-optimized: batch process consecutive cells with same hl_id
                            {
                                const row_start: usize = @as(usize, r) * @as(usize, cols);
                                const grid_cells = ctx.core.grid.cells;
                                var c: u32 = 0;

                                while (c < cols) {
                                    const first_cell = grid_cells[row_start + @as(usize, c)];
                                    const run_hl = first_cell.hl;

                                    // Find run of consecutive cells with same hl_id
                                    // This reduces hl_cache lookups from O(cols) to O(unique_hl_ids)
                                    var run_end: u32 = c + 1;
                                    while (run_end < cols) : (run_end += 1) {
                                        if (grid_cells[row_start + @as(usize, run_end)].hl != run_hl) break;
                                    }

                                    // Get resolved attributes once for the entire run
                                    const a = blk: {
                                        if (run_hl < HL_CACHE_SIZE) {
                                            if (hl_valid[run_hl]) {
                                                perf_hl_cache_hits += 1;
                                                break :blk hl_cache[run_hl];
                                            }
                                            perf_hl_cache_misses += 1;
                                            const resolved = ctx.core.hl.getWithStyles(run_hl);
                                            hl_cache[run_hl] = resolved;
                                            hl_valid[run_hl] = true;
                                            break :blk resolved;
                                        }
                                        // Fallback for hl_id >= 64 (rare)
                                        perf_hl_cache_misses += 1;
                                        break :blk ctx.core.hl.getWithStyles(run_hl);
                                    };

                                    // Batch write all cells in the run with same fg/bg/sp/style_flags
                                    // Only scalar differs per cell
                                    const fg = a.fg;
                                    const bg = a.bg;
                                    const sp = a.sp;
                                    const flags = a.style_flags;

                                    var i: u32 = c;
                                    while (i < run_end) : (i += 1) {
                                        const src_cell = grid_cells[row_start + @as(usize, i)];
                                        row_cells.items[@intCast(i)] = .{
                                            .scalar = src_cell.cp,
                                            .fgRGB = fg,
                                            .bgRGB = bg,
                                            .spRGB = sp,
                                            .grid_id = 1, // main grid
                                            .style_flags = flags,
                                        };
                                    }

                                    c = run_end;
                                }

                                // Overlay sub-grids using pre-cached info (avoids per-row hash map lookups)
                                for (cached_subgrids[0..cached_subgrid_count]) |csg| {
                                    // Fast row range check using cached bounds
                                    if (r < csg.row_start or r >= csg.row_end) continue;
                                    const r2: u32 = r - csg.row_start;

                                    var c2: u32 = 0;
                                    while (c2 < csg.sg_cols) : (c2 += 1) {
                                        const tc = csg.col_start + c2;
                                        if (tc >= cols) break;

                                        const src_i: usize = @as(usize, r2) * @as(usize, csg.sg_cols) + @as(usize, c2);
                                        const cell = csg.cells[src_i];
                                        // Use HL cache with direct index for O(1) access
                                        const a2 = blk2: {
                                            if (cell.hl < HL_CACHE_SIZE) {
                                                if (hl_valid[cell.hl]) {
                                                    perf_hl_cache_hits += 1;
                                                    break :blk2 hl_cache[cell.hl];
                                                }
                                                perf_hl_cache_misses += 1;
                                                const resolved = ctx.core.hl.getWithStyles(cell.hl);
                                                hl_cache[cell.hl] = resolved;
                                                hl_valid[cell.hl] = true;
                                                break :blk2 resolved;
                                            }
                                            // Fallback for hl_id >= 64 (rare)
                                            perf_hl_cache_misses += 1;
                                            break :blk2 ctx.core.hl.getWithStyles(cell.hl);
                                        };
                                        row_cells.items[@intCast(tc)] = .{
                                            .scalar = cell.cp,
                                            .fgRGB = a2.fg,
                                            .bgRGB = a2.bg,
                                            .spRGB = a2.sp,
                                            .grid_id = csg.grid_id,
                                            .style_flags = a2.style_flags,
                                        };
                                    }
                                }
                            }

                            // Row-mode timing for background measurement
                            var t_row_compose_end: i128 = 0;
                            var t_row_bg_start: i128 = 0;
                            if (log_enabled) {
                                t_row_compose_end = std.time.nanoTimestamp();
                                t_row_bg_start = t_row_compose_end;
                            }

                            // 1) Background: run-length by bgRGB and grid_id for this row
                            {
                                var c: u32 = 0;
                                while (c < cols) {
                                    const first = row_cells.items[@intCast(c)];
                                    const run_bg = first.bgRGB;
                                    const run_grid_id = first.grid_id;
                                    const run_start = c;

                                    var end: u32 = c;
                                    while (end < cols) : (end += 1) {
                                        const cell = row_cells.items[@intCast(end)];
                                        if (cell.bgRGB != run_bg or cell.grid_id != run_grid_id) break;
                                    }

                                    const x0: f32 = @as(f32, @floatFromInt(run_start)) * cellW;
                                    const x1: f32 = @as(f32, @floatFromInt(end)) * cellW;
                                    const y0: f32 = @as(f32, @floatFromInt(r)) * cellH;
                                    const y1: f32 = y0 + cellH;

                                    // Use semi-transparent alpha for default background (blur/transparency)
                                    const bg_alpha: f32 = if (run_bg == ctx.core.hl.default_bg)
                                        (if (ctx.core.blur_enabled) 0.5 else ctx.core.background_opacity)
                                    else
                                        1.0;
                                    try Helpers.pushSolidQuad(out, ctx.core.alloc, x0, y0, x1, y1, Helpers.rgba(run_bg, bg_alpha), dw, dh, run_grid_id);
                                    c = end;
                                }
                            }

                            // Row-mode timing for performance measurement
                            var t_row_bg_end: i128 = 0;
                            var t_row_under_deco_start: i128 = 0;
                            if (log_enabled) {
                                t_row_bg_end = std.time.nanoTimestamp();
                                t_row_under_deco_start = t_row_bg_end;
                            }

                            // 2) Under-decorations (drawn behind glyphs): underline, underdouble, undercurl, underdotted, underdashed
                            {
                                var c: u32 = 0;
                                while (c < cols) {
                                    const cell = row_cells.items[@intCast(c)];
                                    const under_deco_mask = STYLE_UNDERLINE | STYLE_UNDERDOUBLE | STYLE_UNDERCURL | STYLE_UNDERDOTTED | STYLE_UNDERDASHED;
                                    if (cell.style_flags & under_deco_mask == 0) {
                                        c += 1;
                                        continue;
                                    }

                                    // Find run of cells with same decoration style
                                    const run_start = c;
                                    const run_flags = cell.style_flags;
                                    const run_sp = cell.spRGB;
                                    const run_fg = cell.fgRGB;
                                    const run_grid_id = cell.grid_id;

                                    var run_end: u32 = c + 1;
                                    while (run_end < cols) : (run_end += 1) {
                                        const next = row_cells.items[@intCast(run_end)];
                                        if (next.style_flags != run_flags or next.spRGB != run_sp or next.grid_id != run_grid_id) break;
                                    }

                                    // Use special color if set, otherwise foreground
                                    const deco_color = if (run_sp != highlight.Highlights.SP_NOT_SET) Helpers.rgb(run_sp) else Helpers.rgb(run_fg);

                                    const x0: f32 = @as(f32, @floatFromInt(run_start)) * cellW;
                                    const x1: f32 = @as(f32, @floatFromInt(run_end)) * cellW;
                                    const row_y: f32 = @as(f32, @floatFromInt(r)) * cellH;

                                    // Underline: 1px line at bottom of cell
                                    if (run_flags & STYLE_UNDERLINE != 0) {
                                        const y0 = row_y + cellH - 2.0;
                                        const y1 = y0 + 1.0;
                                        try Helpers.pushDecoQuad(out, ctx.core.alloc, x0, y0, x1, y1, deco_color, dw, dh, run_grid_id, c_api.DECO_UNDERLINE, 0);
                                    }

                                    // Underdouble: 2 lines at bottom with clear gap
                                    if (run_flags & STYLE_UNDERDOUBLE != 0) {
                                        const y0_1 = row_y + cellH - 6.0;
                                        const y1_1 = y0_1 + 1.0;
                                        const y0_2 = row_y + cellH - 2.0;
                                        const y1_2 = y0_2 + 1.0;
                                        try Helpers.pushDecoQuad(out, ctx.core.alloc, x0, y0_1, x1, y1_1, deco_color, dw, dh, run_grid_id, c_api.DECO_UNDERLINE, 0);
                                        try Helpers.pushDecoQuad(out, ctx.core.alloc, x0, y0_2, x1, y1_2, deco_color, dw, dh, run_grid_id, c_api.DECO_UNDERLINE, 0);
                                    }

                                    // Undercurl: wavy line (shader-based)
                                    if (run_flags & STYLE_UNDERCURL != 0) {
                                        const y0 = row_y + cellH - 4.0;
                                        const y1 = row_y + cellH;
                                        const phase: f32 = @floatFromInt(run_start);
                                        try Helpers.pushDecoQuad(out, ctx.core.alloc, x0, y0, x1, y1, deco_color, dw, dh, run_grid_id, c_api.DECO_UNDERCURL, phase);
                                    }

                                    // Underdotted: dotted line (shader-based)
                                    if (run_flags & STYLE_UNDERDOTTED != 0) {
                                        const y0 = row_y + cellH - 2.0;
                                        const y1 = y0 + 1.0;
                                        try Helpers.pushDecoQuad(out, ctx.core.alloc, x0, y0, x1, y1, deco_color, dw, dh, run_grid_id, c_api.DECO_UNDERDOTTED, 0);
                                    }

                                    // Underdashed: dashed line (shader-based)
                                    if (run_flags & STYLE_UNDERDASHED != 0) {
                                        const y0 = row_y + cellH - 2.0;
                                        const y1 = y0 + 1.0;
                                        try Helpers.pushDecoQuad(out, ctx.core.alloc, x0, y0, x1, y1, deco_color, dw, dh, run_grid_id, c_api.DECO_UNDERDASHED, 0);
                                    }

                                    c = run_end;
                                }
                            }

                            var t_row_under_deco_end: i128 = 0;
                            var t_row_glyph_start: i128 = 0;
                            if (log_enabled) {
                                t_row_under_deco_end = std.time.nanoTimestamp();
                                t_row_glyph_start = t_row_under_deco_end;
                            }

                            // 3) Glyphs: same as main path, but only this row
                            const ensure_base = ctx.core.cb.on_atlas_ensure_glyph;
                            const ensure_styled = ctx.core.cb.on_atlas_ensure_glyph_styled;
                            if (ensure_base != null or ensure_styled != null) {
                                var c: u32 = 0;
                                while (c < cols) {
                                    const first = row_cells.items[@intCast(c)];
                                    const run_fg = first.fgRGB;
                                    const run_bg = first.bgRGB;
                                    const run_grid_id = first.grid_id;
                                    const run_start = c;

                                    var end: u32 = c;
                                    var has_ink = false;
                                    while (end < cols) : (end += 1) {
                                        const cell = row_cells.items[@intCast(end)];
                                        if (cell.fgRGB != run_fg or cell.bgRGB != run_bg or cell.grid_id != run_grid_id) break;

                                        const s: u32 = if (cell.scalar == 0) 32 else cell.scalar;
                                        if (s != 32) has_ink = true;
                                    }

                                    if (has_ink) {
                                        const baseX = @as(f32, @floatFromInt(run_start)) * cellW;
                                        const baseY = @as(f32, @floatFromInt(r)) * cellH + topPad;


                                        var penX: f32 = baseX;
                                        const fg = Helpers.rgb(run_fg);

                                        var col_i: u32 = run_start;
                                        while (col_i < end) : (col_i += 1) {
                                            const cell = row_cells.items[@intCast(col_i)];
                                            const scalar: u32 = if (cell.scalar == 0) 32 else cell.scalar;
                                            if (scalar == 32) {
                                                penX += cellW;
                                                continue;
                                            }

                                            var ge: c_api.GlyphEntry = undefined;
                                            // Use styled callback for bold/italic if available
                                            const style_mask = cell.style_flags & (STYLE_BOLD | STYLE_ITALIC);
                                            // Compute style index: 0=none, 1=bold, 2=italic, 3=bold+italic
                                            const style_index: u32 = @as(u32, if (cell.style_flags & STYLE_BOLD != 0) @as(u32, 1) else 0) +
                                                @as(u32, if (cell.style_flags & STYLE_ITALIC != 0) @as(u32, 2) else 0);
                                            // GlyphEntry cache lookup for ASCII characters (using dynamic cache)
                                            const glyph_ok = blk: {
                                                // Check dynamic cache for ASCII (0-127)
                                                if (scalar < 128 and glyph_cache_ascii != null and glyph_valid_ascii != null) {
                                                    const cache_key: usize = scalar * 4 + style_index;
                                                    if (cache_key < GLYPH_CACHE_ASCII_SIZE) {
                                                        if (glyph_valid_ascii.?[cache_key]) {
                                                            perf_glyph_ascii_hits += 1;
                                                            ge = glyph_cache_ascii.?[cache_key];
                                                            break :blk true;
                                                        }
                                                        // Cache miss: call Swift callback
                                                        perf_glyph_ascii_misses += 1;
                                                        const ok = if (style_mask != 0 and ensure_styled != null) cb: {
                                                            const c_style: u32 = @as(u32, if (cell.style_flags & STYLE_BOLD != 0) c_api.STYLE_BOLD else 0) |
                                                                @as(u32, if (cell.style_flags & STYLE_ITALIC != 0) c_api.STYLE_ITALIC else 0);
                                                            break :cb ensure_styled.?(ctx.core.ctx, scalar, c_style, &ge) != 0;
                                                        } else if (ensure_base) |ensure| cb: {
                                                            break :cb ensure(ctx.core.ctx, scalar, &ge) != 0;
                                                        } else false;
                                                        if (ok) {
                                                            glyph_cache_ascii.?[cache_key] = ge;
                                                            glyph_valid_ascii.?[cache_key] = true;
                                                        }
                                                        break :blk ok;
                                                    }
                                                }
                                                // Non-ASCII or cache not initialized: use hash table cache
                                                if (glyph_cache_non_ascii != null and glyph_keys_non_ascii != null and GLYPH_CACHE_NON_ASCII_SIZE > 0) {
                                                    const key = (@as(u64, scalar) << 2) | @as(u64, style_index);
                                                    // FNV-1a inspired hash
                                                    const hash_val = (scalar *% 2654435761) ^ style_index;
                                                    const hash_idx = @as(usize, hash_val % GLYPH_CACHE_NON_ASCII_SIZE);
                                                    if (glyph_keys_non_ascii.?[hash_idx] == key) {
                                                        perf_glyph_nonascii_hits += 1;
                                                        ge = glyph_cache_non_ascii.?[hash_idx];
                                                        break :blk true;
                                                    }
                                                    // Cache miss: call Swift callback
                                                    perf_glyph_nonascii_misses += 1;
                                                    const ok = if (style_mask != 0 and ensure_styled != null) cb: {
                                                        const c_style: u32 = @as(u32, if (cell.style_flags & STYLE_BOLD != 0) c_api.STYLE_BOLD else 0) |
                                                            @as(u32, if (cell.style_flags & STYLE_ITALIC != 0) c_api.STYLE_ITALIC else 0);
                                                        break :cb ensure_styled.?(ctx.core.ctx, scalar, c_style, &ge) != 0;
                                                    } else if (ensure_base) |ensure| cb: {
                                                        break :cb ensure(ctx.core.ctx, scalar, &ge) != 0;
                                                    } else false;
                                                    if (ok) {
                                                        glyph_cache_non_ascii.?[hash_idx] = ge;
                                                        glyph_keys_non_ascii.?[hash_idx] = key;
                                                    }
                                                    break :blk ok;
                                                }
                                                // No cache available: call Swift callback directly
                                                const ok = if (style_mask != 0 and ensure_styled != null) cb: {
                                                    const c_style: u32 = @as(u32, if (cell.style_flags & STYLE_BOLD != 0) c_api.STYLE_BOLD else 0) |
                                                        @as(u32, if (cell.style_flags & STYLE_ITALIC != 0) c_api.STYLE_ITALIC else 0);
                                                    break :cb ensure_styled.?(ctx.core.ctx, scalar, c_style, &ge) != 0;
                                                } else if (ensure_base) |ensure| cb: {
                                                    break :cb ensure(ctx.core.ctx, scalar, &ge) != 0;
                                                } else false;
                                                break :blk ok;
                                            };
                                            if (!glyph_ok) {
                                                had_glyph_miss = true;
                                                if (ctx.core.missing_glyph_log_count < 16) {
                                                    ctx.core.log.write(
                                                        "glyph_missing row={d} col={d} scalar=0x{x}\n",
                                                        .{ r, col_i, scalar },
                                                    );
                                                    ctx.core.missing_glyph_log_count += 1;
                                                }
                                                penX += cellW;
                                                continue;
                                            }

                                            const baselineY: f32 = baseY + ge.ascent_px;

                                            const gx0: f32 = penX + ge.bbox_origin_px[0];
                                            const gx1: f32 = gx0 + ge.bbox_size_px[0];
                                            const gy0: f32 = (baselineY) - (ge.bbox_origin_px[1] + ge.bbox_size_px[1]);
                                            const gy1: f32 = gy0 + ge.bbox_size_px[1];

                                            const uv0: [2]f32 = .{ ge.uv_min[0], ge.uv_min[1] };
                                            const uv1: [2]f32 = .{ ge.uv_max[0], ge.uv_min[1] };
                                            const uv2: [2]f32 = .{ ge.uv_min[0], ge.uv_max[1] };
                                            const uv3: [2]f32 = .{ ge.uv_max[0], ge.uv_max[1] };

                                            if (ge.bbox_size_px[0] > 0 and ge.bbox_size_px[1] > 0) {
                                                try Helpers.pushGlyphQuad(out, ctx.core.alloc, gx0, gy0, gx1, gy1, uv0, uv1, uv2, uv3, fg, dw, dh, run_grid_id);
                                            }

                                            penX += cellW;
                                        }
                                    }

                                    c = end;
                                }
                            }

                            var t_row_glyph_end: i128 = 0;
                            var t_row_strike_start: i128 = 0;
                            if (log_enabled) {
                                t_row_glyph_end = std.time.nanoTimestamp();
                                t_row_strike_start = t_row_glyph_end;
                            }

                            // 4) Strikethrough (drawn on top of glyphs)
                            {
                                var c: u32 = 0;
                                while (c < cols) {
                                    const cell = row_cells.items[@intCast(c)];
                                    if (cell.style_flags & STYLE_STRIKETHROUGH == 0) {
                                        c += 1;
                                        continue;
                                    }

                                    const run_start = c;
                                    const run_flags = cell.style_flags;
                                    const run_sp = cell.spRGB;
                                    const run_fg = cell.fgRGB;
                                    const run_grid_id = cell.grid_id;

                                    var run_end: u32 = c + 1;
                                    while (run_end < cols) : (run_end += 1) {
                                        const next = row_cells.items[@intCast(run_end)];
                                        if (next.style_flags != run_flags or next.spRGB != run_sp or next.grid_id != run_grid_id) break;
                                    }

                                    const deco_color = if (run_sp != highlight.Highlights.SP_NOT_SET) Helpers.rgb(run_sp) else Helpers.rgb(run_fg);
                                    const x0: f32 = @as(f32, @floatFromInt(run_start)) * cellW;
                                    const x1: f32 = @as(f32, @floatFromInt(run_end)) * cellW;
                                    const row_y: f32 = @as(f32, @floatFromInt(r)) * cellH;

                                    const y0 = row_y + cellH * 0.5 - 0.5;
                                    const y1 = y0 + 1.0;
                                    try Helpers.pushDecoQuad(out, ctx.core.alloc, x0, y0, x1, y1, deco_color, dw, dh, run_grid_id, c_api.DECO_STRIKETHROUGH, 0);

                                    c = run_end;
                                }
                            }

                            // Log row timing for performance measurement
                            if (log_enabled) {
                                const t_row_strike_end = std.time.nanoTimestamp();
                                const compose_us: i64 = @intCast(@divTrunc(@max(0, t_row_compose_end - t_row_compose_start), 1000));
                                const bg_us: i64 = @intCast(@divTrunc(@max(0, t_row_bg_end - t_row_bg_start), 1000));
                                const under_deco_us: i64 = @intCast(@divTrunc(@max(0, t_row_under_deco_end - t_row_under_deco_start), 1000));
                                const glyph_us: i64 = @intCast(@divTrunc(@max(0, t_row_glyph_end - t_row_glyph_start), 1000));
                                const strike_us: i64 = @intCast(@divTrunc(@max(0, t_row_strike_end - t_row_strike_start), 1000));
                                const total_us: i64 = @intCast(@divTrunc(@max(0, t_row_strike_end - t_row_compose_start), 1000));
                                ctx.core.log.write(
                                    "[perf] row_mode row={d} cols={d} compose_us={d} bg_us={d} under_deco_us={d} glyph_us={d} strike_us={d} total_us={d}\n",
                                    .{ r, cols, compose_us, bg_us, under_deco_us, glyph_us, strike_us, total_us },
                                );
                            }

                            // Contract: row_count == 1, grid_id == 1 for main window
                            row_cb(ctx.core.ctx, 1, r, 1, out.items.ptr, out.items.len, 1, rows, cols); // grid_id=1 (main), flags=1 (ZONVIE_VERT_UPDATE_MAIN)
                        }

                        ctx.core.grid.clearDirty();
                        if (had_glyph_miss) {
                            ctx.core.grid.markAllDirty();
                        }
                        ctx.core.last_sent_content_rev = ctx.core.grid.content_rev;
                        if (log_enabled) {
                            const t_rows_done_ns: i128 = std.time.nanoTimestamp();
                            const dur_us: i64 = @intCast(@divTrunc(@max(0, t_rows_done_ns - t_rows_start_ns), 1000));
                            ctx.core.log.write(
                                "[perf] row_mode_compose rows={d} cols={d} dirty_rows={d} subgrids={d} us={d}\n",
                                .{ rows, cols, log_dirty_rows, ctx.core.grid_entries.items.len, dur_us },
                            );
                            // Cache statistics: helps tune cache sizes and identify bottlenecks
                            ctx.core.log.write(
                                "[perf] hl_cache hits={d} misses={d}\n",
                                .{ perf_hl_cache_hits, perf_hl_cache_misses },
                            );
                            ctx.core.log.write(
                                "[perf] glyph_cache ascii_hits={d} ascii_misses={d} nonascii_hits={d} nonascii_misses={d}\n",
                                .{ perf_glyph_ascii_hits, perf_glyph_ascii_misses, perf_glyph_nonascii_hits, perf_glyph_nonascii_misses },
                            );
                        }
                    } else {
                        const n_cells2: usize = @as(usize, rows) * @as(usize, cols);

                        // Use persistent buffer (zero-allocation hot path)
                        try ctx.core.tmp_cells.ensureTotalCapacity(ctx.core.alloc, n_cells2);
                        ctx.core.tmp_cells.clearRetainingCapacity();
                        ctx.core.tmp_cells.items.len = n_cells2;
                        tmp = ctx.core.tmp_cells.items;

                        // 1) draw main grid(1)
                        var cell_i: usize = 0;
                        while (cell_i < n_cells2) : (cell_i += 1) {
                            const cell = ctx.core.grid.cells[cell_i];
                            const a = ctx.core.hl.getWithStyles(cell.hl);
                            tmp[cell_i] = .{
                                .scalar = cell.cp,
                                .fgRGB = a.fg,
                                .bgRGB = a.bg,
                                .spRGB = a.sp,
                                .grid_id = 1, // main grid
                                .style_flags = packStyleFlags(a),
                            };
                        }

                        // Then overlay in that order
                        for (ctx.core.grid_entries.items) |ent| {
                            const subgrid_id = ent.grid_id;
                            const pos = ctx.core.grid.win_pos.get(subgrid_id) orelse continue;
                            const sg = ctx.core.grid.sub_grids.get(subgrid_id) orelse continue;

                            // Skip float windows anchored to external grids (they belong to that external window)
                            if (pos.anchor_grid != 1 and ctx.core.grid.external_grids.contains(pos.anchor_grid)) continue;

                            var r2: u32 = 0;
                            while (r2 < sg.rows) : (r2 += 1) {
                                const tr = pos.row + r2;
                                if (tr >= rows) break;

                                var c2: u32 = 0;
                                while (c2 < sg.cols) : (c2 += 1) {
                                    const tc = pos.col + c2;
                                    if (tc >= cols) break;

                                    const src_i: usize = @as(usize, r2) * @as(usize, sg.cols) + @as(usize, c2);
                                    const dst_i: usize = @as(usize, tr) * @as(usize, cols) + @as(usize, tc);

                                    const cell = sg.cells[src_i];
                                    const a = ctx.core.hl.getWithStyles(cell.hl);
                                    tmp[dst_i] = .{
                                        .scalar = cell.cp,
                                        .fgRGB = a.fg,
                                        .bgRGB = a.bg,
                                        .spRGB = a.sp,
                                        .grid_id = subgrid_id,
                                        .style_flags = packStyleFlags(a),
                                    };
                                }
                            }
                        }
                    }



                    if (!sent_main_by_rows) {

                        // Estimate capacity: rows*cols*12 vertices (BG + glyph)
                        const est_cells: usize = @as(usize, rows) * @as(usize, cols);
                        _ = main.ensureTotalCapacity(ctx.core.alloc, est_cells * 12) catch {};

                        // 1) Background: run-length by bgRGB and grid_id per row
                        var r: u32 = 0;




                        while (r < rows) : (r += 1) {
                            const row_start: usize = @as(usize, r) * @as(usize, cols);

                            var c: u32 = 0;
                            while (c < cols) {
                                const first = tmp[row_start + @as(usize, c)];
                                const run_bg = first.bgRGB;
                                const run_grid_id = first.grid_id;
                                const run_start = c;

                                var end: u32 = c;
                                while (end < cols) : (end += 1) {
                                    const cell = tmp[row_start + @as(usize, end)];
                                    if (cell.bgRGB != run_bg or cell.grid_id != run_grid_id) break;
                                }

                                const x0: f32 = @as(f32, @floatFromInt(run_start)) * cellW;
                                const x1: f32 = @as(f32, @floatFromInt(end)) * cellW;
                                const y0: f32 = @as(f32, @floatFromInt(r)) * cellH;
                                const y1: f32 = y0 + cellH;

                                // Use transparency for default background (blur or background_opacity)
                                const bg_alpha: f32 = if (run_bg == ctx.core.hl.default_bg)
                                    (if (ctx.core.blur_enabled) 0.0 else ctx.core.background_opacity)
                                else
                                    1.0;
                                try Helpers.pushSolidQuad(main, ctx.core.alloc, x0, y0, x1, y1, Helpers.rgba(run_bg, bg_alpha), dw, dh, run_grid_id);
                                c = end;
                            }
                        }

                        // Timing for performance measurement (only when logging enabled)
                        const perf_log_enabled = ctx.core.log.cb != null;
                        var t_under_deco_start: i128 = 0;
                        if (perf_log_enabled) {
                            t_under_deco_start = std.time.nanoTimestamp();
                        }

                        // 2) Under-decorations: underline, underdouble, undercurl, underdotted, underdashed (drawn BEHIND glyphs)
                        {
                            var r2: u32 = 0;
                            while (r2 < rows) : (r2 += 1) {
                                const row_start: usize = @as(usize, r2) * @as(usize, cols);

                                var c: u32 = 0;
                                while (c < cols) {
                                    const cell = tmp[row_start + @as(usize, c)];
                                    // Check for any under-decoration (not strikethrough)
                                    const under_mask = STYLE_UNDERLINE | STYLE_UNDERDOUBLE | STYLE_UNDERCURL | STYLE_UNDERDOTTED | STYLE_UNDERDASHED;
                                    if (cell.style_flags & under_mask == 0) {
                                        c += 1;
                                        continue;
                                    }

                                    // Find run of cells with same decoration style
                                    const run_start = c;
                                    const run_flags = cell.style_flags;
                                    const run_sp = cell.spRGB;
                                    const run_fg = cell.fgRGB;
                                    const run_grid_id = cell.grid_id;

                                    var run_end: u32 = c + 1;
                                    while (run_end < cols) : (run_end += 1) {
                                        const next = tmp[row_start + @as(usize, run_end)];
                                        if (next.style_flags != run_flags or next.spRGB != run_sp or next.grid_id != run_grid_id) break;
                                    }

                                    // Use special color if set, otherwise foreground
                                    const deco_color = if (run_sp != highlight.Highlights.SP_NOT_SET) Helpers.rgb(run_sp) else Helpers.rgb(run_fg);

                                    const x0: f32 = @as(f32, @floatFromInt(run_start)) * cellW;
                                    const x1: f32 = @as(f32, @floatFromInt(run_end)) * cellW;
                                    const row_y: f32 = @as(f32, @floatFromInt(r2)) * cellH;

                                    // Underline: 1px line at bottom of cell
                                    if (run_flags & STYLE_UNDERLINE != 0) {
                                        const y0 = row_y + cellH - 2.0;
                                        const y1 = y0 + 1.0;
                                        try Helpers.pushDecoQuad(main, ctx.core.alloc, x0, y0, x1, y1, deco_color, dw, dh, run_grid_id, c_api.DECO_UNDERLINE, 0);
                                    }

                                    // Underdouble: 2 lines at bottom with clear gap
                                    if (run_flags & STYLE_UNDERDOUBLE != 0) {
                                        // First line: 6px from bottom
                                        const y0_1 = row_y + cellH - 6.0;
                                        const y1_1 = y0_1 + 1.0;
                                        // Second line: 2px from bottom (4px gap between lines)
                                        const y0_2 = row_y + cellH - 2.0;
                                        const y1_2 = y0_2 + 1.0;
                                        try Helpers.pushDecoQuad(main, ctx.core.alloc, x0, y0_1, x1, y1_1, deco_color, dw, dh, run_grid_id, c_api.DECO_UNDERLINE, 0);
                                        try Helpers.pushDecoQuad(main, ctx.core.alloc, x0, y0_2, x1, y1_2, deco_color, dw, dh, run_grid_id, c_api.DECO_UNDERLINE, 0);
                                    }

                                    // Undercurl: wavy line (shader-based)
                                    if (run_flags & STYLE_UNDERCURL != 0) {
                                        const y0 = row_y + cellH - 4.0;
                                        const y1 = row_y + cellH;
                                        const phase: f32 = @floatFromInt(run_start);
                                        try Helpers.pushDecoQuad(main, ctx.core.alloc, x0, y0, x1, y1, deco_color, dw, dh, run_grid_id, c_api.DECO_UNDERCURL, phase);
                                    }

                                    // Underdotted: dotted line (shader-based)
                                    if (run_flags & STYLE_UNDERDOTTED != 0) {
                                        const y0 = row_y + cellH - 2.0;
                                        const y1 = y0 + 1.0;
                                        try Helpers.pushDecoQuad(main, ctx.core.alloc, x0, y0, x1, y1, deco_color, dw, dh, run_grid_id, c_api.DECO_UNDERDOTTED, 0);
                                    }

                                    // Underdashed: dashed line (shader-based)
                                    if (run_flags & STYLE_UNDERDASHED != 0) {
                                        const y0 = row_y + cellH - 2.0;
                                        const y1 = y0 + 1.0;
                                        try Helpers.pushDecoQuad(main, ctx.core.alloc, x0, y0, x1, y1, deco_color, dw, dh, run_grid_id, c_api.DECO_UNDERDASHED, 0);
                                    }

                                    c = run_end;
                                }
                            }
                        }

                        var t_under_deco_end: i128 = 0;
                        var t_glyph_start: i128 = 0;
                        if (perf_log_enabled) {
                            t_under_deco_end = std.time.nanoTimestamp();
                            t_glyph_start = t_under_deco_end;
                        }

                        // 3) Glyphs: run-length by (fg,bg,grid_id) and skip "all spaces"
                        const ensure_base_full = ctx.core.cb.on_atlas_ensure_glyph;
                        const ensure_styled_full = ctx.core.cb.on_atlas_ensure_glyph_styled;
                        if (ensure_base_full != null or ensure_styled_full != null) {
                            r = 0;
                            while (r < rows) : (r += 1) {
                                const row_start: usize = @as(usize, r) * @as(usize, cols);

                                var c: u32 = 0;
                                while (c < cols) {
                                    const first = tmp[row_start + @as(usize, c)];
                                    const run_fg = first.fgRGB;
                                    const run_bg = first.bgRGB;
                                    const run_grid_id = first.grid_id;
                                    const run_start = c;

                                    var end: u32 = c;
                                    var has_ink = false;
                                    while (end < cols) : (end += 1) {
                                        const cell = tmp[row_start + @as(usize, end)];
                                        if (cell.fgRGB != run_fg or cell.bgRGB != run_bg or cell.grid_id != run_grid_id) break;

                                        const s: u32 = if (cell.scalar == 0) 32 else cell.scalar;
                                        if (s != 32) has_ink = true;
                                    }

                                    if (has_ink) {
                                        const baseX = @as(f32, @floatFromInt(run_start)) * cellW;
                                        const baseY = @as(f32, @floatFromInt(r)) * cellH + topPad;

                                        var penX: f32 = baseX;
                                        const fg = Helpers.rgb(run_fg);

                                        var col_i: u32 = run_start;
                                        while (col_i < end) : (col_i += 1) {
                                            const cell = tmp[row_start + @as(usize, col_i)];
                                            const scalar: u32 = if (cell.scalar == 0) 32 else cell.scalar;
                                            if (scalar == 32) {
                                                penX += cellW;
                                                continue;
                                            }

                                            var ge: c_api.GlyphEntry = undefined;
                                            // Use styled callback for bold/italic if available
                                            const style_mask = cell.style_flags & (STYLE_BOLD | STYLE_ITALIC);
                                            const glyph_ok = blk: {
                                                if (style_mask != 0 and ensure_styled_full != null) {
                                                    // Convert to C API style flags
                                                    const c_style: u32 = @as(u32, if (cell.style_flags & STYLE_BOLD != 0) c_api.STYLE_BOLD else 0) |
                                                        @as(u32, if (cell.style_flags & STYLE_ITALIC != 0) c_api.STYLE_ITALIC else 0);
                                                    break :blk ensure_styled_full.?(ctx.core.ctx, scalar, c_style, &ge) != 0;
                                                } else if (ensure_base_full) |ensure| {
                                                    break :blk ensure(ctx.core.ctx, scalar, &ge) != 0;
                                                } else {
                                                    break :blk false;
                                                }
                                            };
                                            if (!glyph_ok) {
                                                penX += cellW;
                                                continue;
                                            }

                                            const baselineY: f32 = baseY + ge.ascent_px;

                                            const gx0: f32 = penX + ge.bbox_origin_px[0];
                                            const gx1: f32 = gx0 + ge.bbox_size_px[0];
                                            const gy0: f32 = (baselineY) - (ge.bbox_origin_px[1] + ge.bbox_size_px[1]);
                                            const gy1: f32 = gy0 + ge.bbox_size_px[1];

                                            const uv0: [2]f32 = .{ ge.uv_min[0], ge.uv_min[1] };
                                            const uv1: [2]f32 = .{ ge.uv_max[0], ge.uv_min[1] };
                                            const uv2: [2]f32 = .{ ge.uv_min[0], ge.uv_max[1] };
                                            const uv3: [2]f32 = .{ ge.uv_max[0], ge.uv_max[1] };

                                            if (ge.bbox_size_px[0] > 0 and ge.bbox_size_px[1] > 0) {
                                                try Helpers.pushGlyphQuad(main, ctx.core.alloc, gx0, gy0, gx1, gy1, uv0, uv1, uv2, uv3, fg, dw, dh, run_grid_id);
                                            }

                                            // Monospace cell model: advance by cellW
                                            penX += cellW;
                                        }
                                    }

                                    c = end;
                                }
                            }
                        }

                        var t_glyph_end: i128 = 0;
                        var t_strike_start: i128 = 0;
                        if (perf_log_enabled) {
                            t_glyph_end = std.time.nanoTimestamp();
                            t_strike_start = t_glyph_end;
                        }

                        // 4) Strikethrough: drawn ON TOP of glyphs
                        {
                            var r2: u32 = 0;
                            while (r2 < rows) : (r2 += 1) {
                                const row_start: usize = @as(usize, r2) * @as(usize, cols);

                                var c: u32 = 0;
                                while (c < cols) {
                                    const cell = tmp[row_start + @as(usize, c)];
                                    // Only handle strikethrough here
                                    if (cell.style_flags & STYLE_STRIKETHROUGH == 0) {
                                        c += 1;
                                        continue;
                                    }

                                    // Find run of cells with same strikethrough style
                                    const run_start = c;
                                    const run_sp = cell.spRGB;
                                    const run_fg = cell.fgRGB;
                                    const run_grid_id = cell.grid_id;

                                    var run_end: u32 = c + 1;
                                    while (run_end < cols) : (run_end += 1) {
                                        const next = tmp[row_start + @as(usize, run_end)];
                                        if (next.style_flags & STYLE_STRIKETHROUGH == 0 or next.spRGB != run_sp or next.grid_id != run_grid_id) break;
                                    }

                                    // Use special color if set, otherwise foreground
                                    const deco_color = if (run_sp != highlight.Highlights.SP_NOT_SET) Helpers.rgb(run_sp) else Helpers.rgb(run_fg);

                                    const x0: f32 = @as(f32, @floatFromInt(run_start)) * cellW;
                                    const x1: f32 = @as(f32, @floatFromInt(run_end)) * cellW;
                                    const row_y: f32 = @as(f32, @floatFromInt(r2)) * cellH;

                                    // Strikethrough: line through middle
                                    const y0 = row_y + cellH * 0.5 - 0.5;
                                    const y1 = y0 + 1.0;
                                    try Helpers.pushDecoQuad(main, ctx.core.alloc, x0, y0, x1, y1, deco_color, dw, dh, run_grid_id, c_api.DECO_STRIKETHROUGH, 0);

                                    c = run_end;
                                }
                            }
                        }

                        // Log timing for performance measurement
                        if (perf_log_enabled) {
                            const t_strike_end = std.time.nanoTimestamp();
                            const under_deco_ns: i128 = t_under_deco_end - t_under_deco_start;
                            const glyph_ns: i128 = t_glyph_end - t_glyph_start;
                            const strike_ns: i128 = t_strike_end - t_strike_start;
                            const total_ns: i128 = t_strike_end - t_under_deco_start;
                            ctx.core.log.write(
                                "[perf] full_redraw rows={d} cols={d} under_deco_ns={d} glyph_ns={d} strike_ns={d} total_ns={d}\n",
                                .{ rows, cols, under_deco_ns, glyph_ns, strike_ns, total_ns },
                            );
                        }

                        // Mark main as sent (content revision)
                        ctx.core.last_sent_content_rev = ctx.core.grid.content_rev;

                    }

                }

                // ----------------------------
                // Rebuild CURSOR only when needed
                // ----------------------------
                if (need_cursor) {
                    cursor.clearRetainingCapacity();

                    // Skip cursor generation if cursor is NOT on main grid and NOT embedded in main grid
                    // Embedded grids (win_pos) have their cursor drawn on main grid via coordinate transform
                    // External/special grids (external_grids, cmdline, etc.) render their own cursor
                    const cursor_grid = ctx.core.grid.cursor_grid;
                    const cursor_embedded_in_main = (cursor_grid == 1) or ctx.core.grid.win_pos.contains(cursor_grid);

                    if (cursor_embedded_in_main) {
                        _ = cursor.ensureTotalCapacity(ctx.core.alloc, 64) catch {};
                    }

                    if (cursor_embedded_in_main and cursor_out.enabled != 0) {
                        const cur_row = cursor_out.row;
                        const cur_col = cursor_out.col;
                        if (cur_row < rows and cur_col < cols) {
                            const x0 = @as(f32, @floatFromInt(cur_col)) * cellW;
                            const y0 = @as(f32, @floatFromInt(cur_row)) * cellH;

                            const pct_u32 = @max(@as(u32, 1), @min(cursor_out.cell_percentage, 100));
                            const pct: f32 = @floatFromInt(pct_u32);

                            const tW = cellW * pct / 100.0;
                            const tH = cellH * pct / 100.0;

                            // Get the cell at cursor position (grid-relative coordinates)
                            const cursor_grid_id = ctx.core.grid.cursor_grid;
                            const grid_cursor_row = ctx.core.grid.cursor_row;
                            const grid_cursor_col = ctx.core.grid.cursor_col;
                            const cursor_cell = ctx.core.grid.getCellGrid(cursor_grid_id, grid_cursor_row, grid_cursor_col);
                            const cursor_cp = cursor_cell.cp;

                            // Check if this is a double-width character
                            // Next cell having cp == 0 indicates a continuation cell for wide char
                            var is_double_width = false;
                            if (cursor_grid_id == 1) {
                                if (grid_cursor_col + 1 < ctx.core.grid.cols) {
                                    const next_cell = ctx.core.grid.getCell(grid_cursor_row, grid_cursor_col + 1);
                                    if (next_cell.cp == 0) {
                                        is_double_width = true;
                                    }
                                }
                            } else {
                                if (ctx.core.grid.sub_grids.getPtr(cursor_grid_id)) |sg| {
                                    if (grid_cursor_col + 1 < sg.cols) {
                                        const next_idx: usize = @as(usize, grid_cursor_row) * @as(usize, sg.cols) + @as(usize, grid_cursor_col + 1);
                                        if (next_idx < sg.cells.len and sg.cells[next_idx].cp == 0) {
                                            is_double_width = true;
                                        }
                                    }
                                }
                            }

                            const cursor_width: f32 = if (is_double_width) cellW * 2 else cellW;

                            const rx0: f32 = x0;
                            var ry0: f32 = y0;
                            var rx1: f32 = x0 + cursor_width;
                            const ry1: f32 = y0 + cellH;

                            switch (@intFromEnum(cursor_out.shape)) {
                                1 => { // vertical
                                    rx1 = x0 + tW;
                                },
                                2 => { // horizontal
                                    ry0 = y0 + (cellH - tH);
                                },
                                else => { // block
                                    // full cell (or double-width)
                                },
                            }

                            // Push cursor background quad with DECO_CURSOR flag
                            // (so shader treats it as decoration, not background with transparency)
                            {
                                const p0 = Helpers.ndc(rx0, ry0, dw, dh);
                                const p1 = Helpers.ndc(rx1, ry0, dw, dh);
                                const p2 = Helpers.ndc(rx0, ry1, dw, dh);
                                const p3 = Helpers.ndc(rx1, ry1, dw, dh);
                                const col = Helpers.rgb(cursor_out.bgRGB);
                                const solid_uv = Helpers.solid_uv;

                                try cursor.ensureUnusedCapacity(ctx.core.alloc, 6);
                                cursor.appendAssumeCapacity(.{ .position = p0, .texCoord = solid_uv, .color = col, .grid_id = cursor_grid_id, .deco_flags = c_api.DECO_CURSOR, .deco_phase = 0 });
                                cursor.appendAssumeCapacity(.{ .position = p2, .texCoord = solid_uv, .color = col, .grid_id = cursor_grid_id, .deco_flags = c_api.DECO_CURSOR, .deco_phase = 0 });
                                cursor.appendAssumeCapacity(.{ .position = p1, .texCoord = solid_uv, .color = col, .grid_id = cursor_grid_id, .deco_flags = c_api.DECO_CURSOR, .deco_phase = 0 });
                                cursor.appendAssumeCapacity(.{ .position = p1, .texCoord = solid_uv, .color = col, .grid_id = cursor_grid_id, .deco_flags = c_api.DECO_CURSOR, .deco_phase = 0 });
                                cursor.appendAssumeCapacity(.{ .position = p2, .texCoord = solid_uv, .color = col, .grid_id = cursor_grid_id, .deco_flags = c_api.DECO_CURSOR, .deco_phase = 0 });
                                cursor.appendAssumeCapacity(.{ .position = p3, .texCoord = solid_uv, .color = col, .grid_id = cursor_grid_id, .deco_flags = c_api.DECO_CURSOR, .deco_phase = 0 });
                            }

                            // Render cursor text (character under cursor) with inverted color
                            // Only for block cursor and non-space characters
                            if (@intFromEnum(cursor_out.shape) == 0 and cursor_cp != 0 and cursor_cp != ' ') {
                                const ensure_base = ctx.core.cb.on_atlas_ensure_glyph;
                                const ensure_styled = ctx.core.cb.on_atlas_ensure_glyph_styled;

                                if (ensure_base != null or ensure_styled != null) {
                                    var ge: c_api.GlyphEntry = undefined;
                                    var glyph_ok = false;

                                    // Get glyph entry from atlas
                                    if (ensure_styled) |styled_fn| {
                                        glyph_ok = styled_fn(ctx.core.ctx, cursor_cp, 0, &ge) != 0;
                                    } else if (ensure_base) |base_fn| {
                                        glyph_ok = base_fn(ctx.core.ctx, cursor_cp, &ge) != 0;
                                    }

                                    if (glyph_ok and ge.bbox_size_px[0] > 0 and ge.bbox_size_px[1] > 0) {
                                        // Calculate glyph position (same as main grid rendering)
                                        // Use topPad from outer scope
                                        const cursorBaseY: f32 = y0 + topPad;
                                        const baselineY: f32 = cursorBaseY + ge.ascent_px;

                                        const gx0: f32 = x0 + ge.bbox_origin_px[0];
                                        const gx1: f32 = gx0 + ge.bbox_size_px[0];
                                        const gy0: f32 = baselineY - (ge.bbox_origin_px[1] + ge.bbox_size_px[1]);
                                        const gy1: f32 = gy0 + ge.bbox_size_px[1];

                                        // UV coordinates from atlas
                                        const uv0 = [2]f32{ ge.uv_min[0], ge.uv_min[1] };
                                        const uv1 = [2]f32{ ge.uv_max[0], ge.uv_min[1] };
                                        const uv2 = [2]f32{ ge.uv_min[0], ge.uv_max[1] };
                                        const uv3 = [2]f32{ ge.uv_max[0], ge.uv_max[1] };

                                        // Use cursor foreground color (inverted)
                                        const fg = Helpers.rgb(cursor_out.fgRGB);

                                        try Helpers.pushGlyphQuad(
                                            cursor,
                                            ctx.core.alloc,
                                            gx0, gy0, gx1, gy1,
                                            uv0, uv1, uv2, uv3,
                                            fg,
                                            dw, dh,
                                            cursor_grid_id, // cursor belongs to its actual grid
                                        );
                                    }
                                }
                            }
                        }
                    }

                    // Mark cursor as sent
                    ctx.core.last_sent_cursor_rev = ctx.core.grid.cursor_rev;
                }

                // ----------------------------
                // Send vertices: partial if possible, else legacy full callback
                // ----------------------------
                if (pf_opt) |pf| {
                    var flags: u32 = 0;
                
                    // If main was already sent by rows, do NOT send main here.
                    const send_main_here = need_main and !sent_main_by_rows;
                
                    if (send_main_here) flags |= 1; // ZONVIE_VERT_UPDATE_MAIN
                    if (need_cursor)    flags |= 2; // ZONVIE_VERT_UPDATE_CURSOR
                
                    const main_ptr_opt: ?[*]const c_api.Vertex = if (send_main_here) main.items.ptr else null;
                    const cur_ptr_opt: ?[*]const c_api.Vertex  = if (need_cursor) cursor.items.ptr else null;
                
                    pf(
                        ctx.core.ctx,
                        main_ptr_opt, if (send_main_here) main.items.len else 0,
                        cur_ptr_opt,  if (need_cursor) cursor.items.len else 0,
                        flags,
                    );
                    return;
                }

                // If main was sent via row callback, do not call legacy full callback.
                if (sent_main_by_rows) return;

                // Legacy path: must always provide BOTH buffers to avoid frontend clearing main on cursor-only updates.
                if (vf_opt) |vf| {
                    vf(
                        ctx.core.ctx,
                        main.items.ptr, main.items.len,
                        cursor.items.ptr, cursor.items.len,
                    );
                    return;
                }

                // No callback (shouldn't happen because we gated above), but keep safe:
                return;

            }

        }

        pub fn onGuifont(ctx: *FlushCtx, font: []const u8) !void {
            ctx.core.emitGuiFont(font);
        }

        pub fn onLinespace(ctx: *FlushCtx, px: i32) !void {
            // Store in core and notify frontend.
            const clamped: i32 = if (px < 0) 0 else px;
            ctx.core.linespace_px = @as(u32, @intCast(clamped));
            ctx.core.emitLineSpace(clamped);
        }

        pub fn onSetTitle(ctx: *FlushCtx, title: []const u8) !void {
            ctx.core.emitSetTitle(title);
        }
    };

    fn pumpStderr(self: *Core, f: std.fs.File) void {
        var buf: [4096]u8 = undefined;
        while (!self.stop_flag.load(.seq_cst)) {
            const n = f.read(&buf) catch break;
            if (n == 0) break;

            // Log stderr output
            if (self.cb.on_log) |logfn| logfn(self.ctx, buf[0..n].ptr, n);

            // SSH mode: detect password prompt in stderr
            if (self.is_ssh_mode and !self.ssh_auth_done.load(.seq_cst)) {
                const data = buf[0..n];
                // Check for common password prompts (case-insensitive check for "password")
                if (containsPasswordPrompt(data)) {
                    self.log.write("SSH: detected password prompt in stderr\n", .{});
                    if (self.cb.on_ssh_auth_prompt) |cb| {
                        self.ssh_auth_pending.store(true, .seq_cst);
                        cb(self.ctx, "SSH Password:", 13);
                    }
                }
            }
        }
    }

    /// Check if data contains a password prompt (case-insensitive)
    fn containsPasswordPrompt(data: []const u8) bool {
        // Convert to lowercase for comparison
        var i: usize = 0;
        while (i + 8 <= data.len) : (i += 1) {
            // Check for "password" (case-insensitive)
            const slice = data[i .. i + 8];
            if (eqlIgnoreCase(slice, "password")) {
                return true;
            }
        }
        // Also check for "passphrase"
        i = 0;
        while (i + 10 <= data.len) : (i += 1) {
            const slice = data[i .. i + 10];
            if (eqlIgnoreCase(slice, "passphrase")) {
                return true;
            }
        }
        return false;
    }

    fn eqlIgnoreCase(a: []const u8, b: []const u8) bool {
        if (a.len != b.len) return false;
        for (a, b) |ca, cb| {
            const la = if (ca >= 'A' and ca <= 'Z') ca + 32 else ca;
            const lb = if (cb >= 'A' and cb <= 'Z') cb + 32 else cb;
            if (la != lb) return false;
        }
        return true;
    }

    fn logEnvHints(self: *Core) void {
        const cwd = std.process.getCwdAlloc(self.alloc) catch null;
        defer if (cwd) |s| self.alloc.free(s);
        if (cwd) |s|
            self.log.write("cwd: {s}\n", .{s})
        else
            self.log.write("cwd: (unknown)\n", .{});

        const path_env = std.process.getEnvVarOwned(self.alloc, "PATH") catch null;
        defer if (path_env) |s| self.alloc.free(s);
        if (path_env) |s|
            self.log.write("PATH: {s}\n", .{s})
        else
            self.log.write("PATH: (missing)\n", .{});
    }

    fn handleRpcResponse(self: *Core, top: []mp.Value) void {
        // [type=1, msgid, error, result]
        if (top.len < 4) return;
        if (top[1] != .int) return;
        const id = top[1].int;

        const errv = top[2];
        const has_err = (errv != .nil);

        if (has_err) {
            self.log.write("rpc resp id={d} error={any}\n", .{ id, errv });
            // Clear quit_request_msgid if this was a failed quit request
            const pending_quit_id = self.quit_request_msgid.load(.acquire);
            if (pending_quit_id != 0 and id == pending_quit_id) {
                self.quit_request_msgid.store(0, .release);
                // On error, still try to quit (fallback)
                if (self.cb.on_quit_requested) |cb| {
                    cb(self.ctx, 0); // Assume no unsaved on error
                }
            }
            return;
        }

        // Check if this is nvim_get_api_info response
        // Response format: [channel_id, api_metadata]
        if (self.get_api_info_msgid != null and id == self.get_api_info_msgid.? and self.channel_id == null) {
            if (top[3] == .arr and top[3].arr.len >= 1) {
                const result = top[3].arr;
                if (result[0] == .int) {
                    self.channel_id = result[0].int;
                    self.log.write("channel_id extracted: {d}\n", .{self.channel_id.?});

                    // Setup clipboard after getting channel_id
                    self.setupClipboard();
                }
            }
            return;
        }

        // Check if this is quit request response
        const pending_quit_id = self.quit_request_msgid.load(.acquire);
        if (pending_quit_id != 0 and id == pending_quit_id) {
            self.quit_request_msgid.store(0, .release);

            // Log the response type for debugging
            self.log.write("quit request response: result type={s}\n", .{@tagName(top[3])});

            // Result is boolean: true if there are unsaved buffers
            const has_unsaved: bool = switch (top[3]) {
                .bool => |b| b,
                .int => |i| i != 0,
                else => false,
            };

            self.log.write("quit request response: has_unsaved={}\n", .{has_unsaved});

            // Notify frontend via callback
            if (self.cb.on_quit_requested) |cb| {
                cb(self.ctx, if (has_unsaved) 1 else 0);
            } else {
                // No callback - proceed with :qa (may fail if unsaved)
                self.quitConfirmed(false);
            }
            return;
        }
    }

    fn handleRpcRequest(self: *Core, arena: std.mem.Allocator, top: []mp.Value) void {
        // [type=0, msgid, method, params]
        _ = arena;
        if (top.len < 4) return;
        if (top[1] != .int) return;
        if (top[2] != .str) return;

        const msgid = top[1].int;
        const method = top[2].str;

        self.log.write("rpc request: method={s} msgid={d}\n", .{ method, msgid });

        if (std.mem.eql(u8, method, "zonvie.get_clipboard")) {
            self.handleClipboardGet(msgid, top[3]);
        } else if (std.mem.eql(u8, method, "zonvie.set_clipboard")) {
            self.handleClipboardSet(msgid, top[3]);
        } else {
            // Unknown method - send error response
            self.sendRpcErrorResponse(msgid, "Unknown method") catch |e| {
                self.log.write("sendRpcErrorResponse failed: {any}\n", .{e});
            };
        }
    }

    fn handleClipboardGet(self: *Core, msgid: i64, params: mp.Value) void {
        // params = [register_name] (e.g. "+" or "*")
        var register: []const u8 = "+";
        if (params == .arr and params.arr.len >= 1) {
            if (params.arr[0] == .str) {
                register = params.arr[0].str;
            }
        }

        self.log.write("clipboard get: register={s}\n", .{register});

        // Call frontend callback
        if (self.cb.on_clipboard_get) |cb| {
            var buf: [64 * 1024]u8 = undefined;
            var out_len: usize = 0;

            const result = cb(self.ctx, register.ptr, &buf, &out_len, buf.len);
            if (result != 0) {
                // Success - send clipboard content
                self.sendClipboardGetResponse(msgid, buf[0..out_len]) catch |e| {
                    self.log.write("sendClipboardGetResponse failed: {any}\n", .{e});
                };
                return;
            }
        }

        // Failure - send empty result
        self.sendClipboardGetResponse(msgid, "") catch |e| {
            self.log.write("sendClipboardGetResponse (empty) failed: {any}\n", .{e});
        };
    }

    fn handleClipboardSet(self: *Core, msgid: i64, params: mp.Value) void {
        // params = [register_name, lines_array]
        if (params != .arr or params.arr.len < 2) {
            self.sendRpcErrorResponse(msgid, "Invalid params") catch {};
            return;
        }

        var register: []const u8 = "+";
        if (params.arr[0] == .str) {
            register = params.arr[0].str;
        }

        self.log.write("clipboard set: register={s}\n", .{register});

        // Convert lines array to newline-separated string
        var content_buf: [64 * 1024]u8 = undefined;
        var content_len: usize = 0;

        if (params.arr[1] == .arr) {
            const lines = params.arr[1].arr;
            for (lines, 0..) |line, i| {
                if (line == .str) {
                    const line_str = line.str;
                    if (content_len + line_str.len + 1 < content_buf.len) {
                        @memcpy(content_buf[content_len..][0..line_str.len], line_str);
                        content_len += line_str.len;
                        // Add newline between lines (not after last)
                        if (i < lines.len - 1) {
                            content_buf[content_len] = '\n';
                            content_len += 1;
                        }
                    }
                }
            }
        }

        // Call frontend callback
        if (self.cb.on_clipboard_set) |cb| {
            const result = cb(self.ctx, register.ptr, &content_buf, content_len);
            self.sendRpcBoolResponse(msgid, result != 0) catch |e| {
                self.log.write("sendRpcBoolResponse failed: {any}\n", .{e});
            };
            return;
        }

        self.sendRpcErrorResponse(msgid, "Clipboard not available") catch {};
    }

    fn sendRpcErrorResponse(self: *Core, msgid: i64, err_msg: []const u8) !void {
        var buf: rpc.Buf = .empty;
        defer buf.deinit(self.alloc);

        try rpc.packArray(&buf, self.alloc, 4);
        try rpc.packInt(&buf, self.alloc, 1); // type=1 (response)
        try rpc.packInt(&buf, self.alloc, msgid);
        try rpc.packStr(&buf, self.alloc, err_msg); // error
        try rpc.packNil(&buf, self.alloc); // result

        try self.sendRaw(buf.items);
        self.log.write("rpc error response sent: msgid={d} err={s}\n", .{ msgid, err_msg });
    }

    fn sendRpcBoolResponse(self: *Core, msgid: i64, value: bool) !void {
        var buf: rpc.Buf = .empty;
        defer buf.deinit(self.alloc);

        try rpc.packArray(&buf, self.alloc, 4);
        try rpc.packInt(&buf, self.alloc, 1); // type=1 (response)
        try rpc.packInt(&buf, self.alloc, msgid);
        try rpc.packNil(&buf, self.alloc); // no error
        try rpc.packBool(&buf, self.alloc, value); // result

        try self.sendRaw(buf.items);
        self.log.write("rpc bool response sent: msgid={d} value={}\n", .{ msgid, value });
    }

    fn sendClipboardGetResponse(self: *Core, msgid: i64, content: []const u8) !void {
        // Response format: [[line1, line2, ...], regtype]
        // regtype: "v" (charwise), "V" (linewise)
        var buf: rpc.Buf = .empty;
        defer buf.deinit(self.alloc);

        try rpc.packArray(&buf, self.alloc, 4);
        try rpc.packInt(&buf, self.alloc, 1); // type=1 (response)
        try rpc.packInt(&buf, self.alloc, msgid);
        try rpc.packNil(&buf, self.alloc); // no error

        // Result: [[lines...], regtype]
        try rpc.packArray(&buf, self.alloc, 2);

        // Split content by newlines into array
        var line_count: usize = 1;
        for (content) |c| {
            if (c == '\n') line_count += 1;
        }

        try rpc.packArray(&buf, self.alloc, line_count);

        var line_start: usize = 0;
        var i: usize = 0;
        while (i <= content.len) : (i += 1) {
            if (i == content.len or content[i] == '\n') {
                try rpc.packStr(&buf, self.alloc, content[line_start..i]);
                line_start = i + 1;
            }
        }

        // regtype: "V" if ends with newline, "v" otherwise
        const regtype: []const u8 = if (content.len > 0 and content[content.len - 1] == '\n') "V" else "v";
        try rpc.packStr(&buf, self.alloc, regtype);

        try self.sendRaw(buf.items);
        self.log.write("clipboard get response sent: msgid={d} lines={d} regtype={s}\n", .{ msgid, line_count, regtype });
    }

    fn setupClipboard(self: *Core) void {
        if (self.clipboard_setup_done) return;
        if (self.channel_id == null) return;

        const channel = self.channel_id.?;

        // Build Lua code to setup vim.g.clipboard
        // Use vim.schedule to ensure it runs after current RPC processing
        var lua_buf: [2048]u8 = undefined;
        const lua_code = std.fmt.bufPrint(&lua_buf,
            \\vim.g.zonvie_channel = {d}
            \\vim.schedule(function()
            \\  vim.g.clipboard = {{
            \\    name = 'zonvie',
            \\    copy = {{
            \\      ['+'] = function(lines, regtype)
            \\        return vim.rpcrequest({d}, 'zonvie.set_clipboard', '+', lines)
            \\      end,
            \\      ['*'] = function(lines, regtype)
            \\        return vim.rpcrequest({d}, 'zonvie.set_clipboard', '*', lines)
            \\      end,
            \\    }},
            \\    paste = {{
            \\      ['+'] = function()
            \\        return vim.rpcrequest({d}, 'zonvie.get_clipboard', '+')
            \\      end,
            \\      ['*'] = function()
            \\        return vim.rpcrequest({d}, 'zonvie.get_clipboard', '*')
            \\      end,
            \\    }},
            \\  }}
            \\end)
        , .{ channel, channel, channel, channel, channel }) catch {
            self.log.write("setupClipboard: bufPrint failed\n", .{});
            return;
        };

        self.requestExecLua(lua_code) catch |e| {
            self.log.write("setupClipboard: requestExecLua failed: {any}\n", .{e});
            return;
        };

        self.clipboard_setup_done = true;
        self.log.write("clipboard setup done (channel={d})\n", .{channel});
    }

    fn handleRpcNotification(self: *Core, arena: std.mem.Allocator, top: []mp.Value) void {
        if (top.len < 3) return;
        if (top[1] != .str or top[2] != .arr) return;

        const method = top[1].str;
        const params = top[2].arr;

        if (std.mem.eql(u8, method, "redraw")) {
            // Set flag before acquiring lock to detect re-entrant updateLayoutPx calls.
            self.in_handle_redraw = true;

            // Lock grid_mu to prevent concurrent access from UI thread during redraw.
            self.grid_mu.lock();

            var fctx = FlushCtx{ .core = self };
            redraw.handleRedraw(
                &self.grid,
                &self.hl,
                arena,
                params,
                &self.log,
                &fctx,
                FlushCtx.onFlush,
                &fctx,
                FlushCtx.onGuifont,
                &fctx,
                FlushCtx.onLinespace,
                FlushCtx.onSetTitle,
            ) catch |re| {
                self.log.write("redraw err: {any}\n", .{re});
            };

            // Update cmdline grid BEFORE checking external windows
            // (cmdline is rendered as an external grid)
            self.notifyCmdlineChanges();

            // Handle popupmenu changes (creates external float window via Lua API)
            self.notifyPopupmenuChanges();

            // Handle message changes (ext_messages)
            self.notifyMessageChanges();

            // Handle tabline changes (ext_tabline)
            self.notifyTablineChanges();

            // Check for external window changes and notify frontend
            const new_ext_grids = self.notifyExternalWindowChanges();

            // Generate and send vertices for all external grids
            // Force render if new grids were added (to show initial content)
            self.sendExternalGridVertices(new_ext_grids);

            // Check IME off request (from mode_change event)
            if (self.grid.ime_off_requested) {
                self.grid.ime_off_requested = false;
                if (self.msg_config.ime.disable_on_modechange) {
                    if (self.cb.on_ime_off) |cb| {
                        cb(self.ctx);
                    }
                }
            }

            self.grid_mu.unlock();
            self.in_handle_redraw = false;
        } else if (std.mem.eql(u8, method, "zonvie_ime_off")) {
            // Custom RPC notification for IME off (user-invokable)
            if (self.cb.on_ime_off) |cb| {
                cb(self.ctx);
            }
        }
    }

    /// Compare current external_grids with known_external_grids and notify frontend.
    /// Returns true if new external grids were added (need forced render).
    fn notifyExternalWindowChanges(self: *Core) bool {
        var new_grids_added = false;

        // Find closed external windows (were known, but no longer in grid.external_grids)
        var closed_grids: std.ArrayListUnmanaged(i64) = .{};
        defer closed_grids.deinit(self.alloc);

        var known_it = self.known_external_grids.keyIterator();
        while (known_it.next()) |grid_id_ptr| {
            const grid_id = grid_id_ptr.*;
            if (!self.grid.external_grids.contains(grid_id)) {
                closed_grids.append(self.alloc, grid_id) catch continue;
            }
        }

        // Notify closed external windows
        if (self.cb.on_external_window_close) |cb| {
            for (closed_grids.items) |grid_id| {
                cb(self.ctx, grid_id);
            }
        }

        // Remove closed grids from known set
        for (closed_grids.items) |grid_id| {
            _ = self.known_external_grids.remove(grid_id);
        }

        // Find new external windows (in grid.external_grids but not in known)
        var ext_it = self.grid.external_grids.iterator();
        while (ext_it.next()) |entry| {
            const grid_id = entry.key_ptr.*;
            const info = entry.value_ptr.*;

            if (!self.known_external_grids.contains(grid_id)) {
                // New external grid - get dimensions from sub_grids
                var rows: u32 = 0;
                var cols: u32 = 0;
                if (self.grid.sub_grids.get(grid_id)) |sg| {
                    rows = sg.rows;
                    cols = sg.cols;
                }

                // Notify frontend with position info
                if (self.cb.on_external_window) |cb| {
                    cb(self.ctx, grid_id, info.win, rows, cols, info.start_row, info.start_col);
                }

                // Add to known set
                self.known_external_grids.put(self.alloc, grid_id, {}) catch continue;
                new_grids_added = true;
            }
        }

        return new_grids_added;
    }

    /// Generate and send vertices for all external grids.
    /// force_render: if true, render all grids regardless of dirty/cursor flags (used when new grids added)
    /// Generate and send vertices for external grids.
    /// force_render: if true, render regardless of dirty flags
    /// only_grid_id: if non-null, only update this specific grid (for scroll optimization)
    fn sendExternalGridVerticesFiltered(self: *Core, force_render: bool, only_grid_id: ?i64) void {
        self.log.write("[sendExternalGridVertices] called, known_external_grids.count={d} force={} only_grid={?d}\n", .{ self.known_external_grids.count(), force_render, only_grid_id });

        // Check if cursor changed (position or grid) - do this first, before early returns
        const cursor_grid = self.grid.cursor_grid;
        const cursor_rev = self.grid.cursor_rev;
        const cursor_changed = (cursor_rev != self.last_ext_cursor_rev);
        const cursor_grid_changed = (cursor_grid != self.last_ext_cursor_grid);

        self.log.write("[sendExternalGridVertices] cursor_grid={d} cursor_rev={d} last_grid={d} last_rev={d} changed={} grid_changed={}\n", .{
            cursor_grid, cursor_rev, self.last_ext_cursor_grid, self.last_ext_cursor_rev, cursor_changed, cursor_grid_changed,
        });

        // Only update last cursor state if we have external grids to process
        // Otherwise we consume the cursor state before the grid window is created
        const should_update_cursor_state = self.known_external_grids.count() > 0;
        defer {
            if (should_update_cursor_state) {
                self.last_ext_cursor_grid = cursor_grid;
                self.last_ext_cursor_rev = cursor_rev;
            }
        }

        // Check if cursor is on a non-existent external grid (e.g., closed cmdline)
        // In this case, we need to force redraw the grid that previously had cursor
        const cursor_on_closed_grid = !self.known_external_grids.contains(cursor_grid) and
            cursor_grid != 1; // cursor_grid != main grid
        const need_force_redraw_last = cursor_on_closed_grid and
            self.known_external_grids.contains(self.last_ext_cursor_grid);

        if (need_force_redraw_last) {
            self.log.write("[sendExternalGridVertices] cursor on closed grid, forcing redraw of last_grid={d}\n", .{self.last_ext_cursor_grid});
        }

        // Notify frontend when cursor grid changes (for window activation)
        if (cursor_grid_changed) {
            if (self.cb.on_cursor_grid_changed) |cursor_cb| {
                cursor_cb(self.ctx, cursor_grid);
            }
        }

        // Early return if no row-based vertices callback
        const row_cb = self.cb.on_vertices_row orelse return;

        // Reuse row_verts buffer for external grid vertices (per-row)
        var ext_verts = &self.row_verts;

        const cellW: f32 = @floatFromInt(self.cell_w_px);
        const cellH: f32 = @floatFromInt(self.cell_h_px);

        const lineSpacePx: u32 = self.linespace_px;
        const topPadPx: u32 = lineSpacePx / 2;
        const topPad: f32 = @floatFromInt(topPadPx);

        const Helpers = struct {
            fn ndc(x: f32, y: f32, vw: f32, vh: f32) [2]f32 {
                const nx = (x / vw) * 2.0 - 1.0;
                const ny = 1.0 - (y / vh) * 2.0;
                return .{ nx, ny };
            }

            inline fn rgb(v: u32) [4]f32 {
                const rr: f32 = @as(f32, @floatFromInt((v >> 16) & 0xFF)) / 255.0;
                const gg: f32 = @as(f32, @floatFromInt((v >> 8) & 0xFF)) / 255.0;
                const bb: f32 = @as(f32, @floatFromInt(v & 0xFF)) / 255.0;
                return .{ rr, gg, bb, 1.0 };
            }

            inline fn rgba(v: u32, alpha: f32) [4]f32 {
                const rr: f32 = @as(f32, @floatFromInt((v >> 16) & 0xFF)) / 255.0;
                const gg: f32 = @as(f32, @floatFromInt((v >> 8) & 0xFF)) / 255.0;
                const bb: f32 = @as(f32, @floatFromInt(v & 0xFF)) / 255.0;
                return .{ rr, gg, bb, alpha };
            }
        };

        // Default background for blur transparency
        const default_bg = self.hl.default_bg;

        // Initialize FlushCache for hl_cache optimization
        var cache = FlushCache{};

        // Initialize glyph cache (same as row_mode)
        self.initGlyphCache() catch {
            self.log.write("[ext_grid] Failed to initialize glyph cache\n", .{});
        };
        self.resetGlyphCacheFlags();

        // Get glyph cache references
        const glyph_cache_ascii = self.glyph_cache_ascii;
        const glyph_valid_ascii = self.glyph_valid_ascii;
        const glyph_cache_non_ascii = self.glyph_cache_non_ascii;
        const glyph_keys_non_ascii = self.glyph_keys_non_ascii;
        const GLYPH_CACHE_ASCII_SIZE = self.glyph_cache_ascii_size;
        const GLYPH_CACHE_NON_ASCII_SIZE = self.glyph_cache_non_ascii_size;

        // Iterate over all known external grids
        var ext_it = self.known_external_grids.keyIterator();
        while (ext_it.next()) |grid_id_ptr| {
            const grid_id = grid_id_ptr.*;

            // Filter by specific grid if requested (for scroll optimization)
            if (only_grid_id) |target_id| {
                if (grid_id != target_id) continue;
            }

            const sg = self.grid.sub_grids.getPtr(grid_id) orelse continue;

            // Need update if:
            // 1. Grid content is dirty, OR
            // 2. Cursor moved to/from this grid (grid changed), OR
            // 3. Cursor moved within this grid (cursor changed while on this grid)
            const cursor_on_this_grid = (cursor_grid == grid_id);
            const cursor_was_on_this_grid = (self.last_ext_cursor_grid == grid_id);
            const cursor_affected = cursor_grid_changed and (cursor_on_this_grid or cursor_was_on_this_grid);
            const cursor_moved_within = cursor_changed and cursor_on_this_grid and !cursor_grid_changed;

            // Check if this grid needs forced redraw because cursor left closed cmdline
            const force_redraw_this = need_force_redraw_last and (grid_id == self.last_ext_cursor_grid);

            self.log.write("[ext_cursor_check] grid_id={d} dirty={} cursor_on={} cursor_was={} affected={} moved_within={} force={} force_closed={} cursor_grid={d} last_grid={d} rev={d} last_rev={d}\n", .{
                grid_id, sg.dirty, cursor_on_this_grid, cursor_was_on_this_grid, cursor_affected, cursor_moved_within, force_render, force_redraw_this,
                cursor_grid, self.last_ext_cursor_grid, cursor_rev, self.last_ext_cursor_rev,
            });

            // Skip if no update needed (unless force_render is set or forced due to closed grid)
            if (!force_render and !force_redraw_this and !sg.dirty and !cursor_affected and !cursor_moved_within) continue;

            // Reset hl_cache for this grid
            cache.reset();

            // Check if we need full redraw or can use dirty_rows
            const need_full_redraw = force_render or force_redraw_this or cursor_affected or cursor_moved_within;

            // Calculate viewport size for this grid
            const grid_w: f32 = @as(f32, @floatFromInt(sg.cols)) * cellW;
            const grid_h: f32 = @as(f32, @floatFromInt(sg.rows)) * cellH;

            // Debug: count non-space cells
            var non_space_count: u32 = 0;
            var glyph_success_count: u32 = 0;
            var glyph_fail_count: u32 = 0;
            var sample_cps: [10]u32 = .{0} ** 10;
            var sample_idx: usize = 0;

            ext_verts.clearRetainingCapacity();

            // Debug: log grid cell array info
            self.log.write("[ext_grid_debug] grid_id={d} sg.rows={d} sg.cols={d} sg.cells.len={d}\n", .{
                grid_id, sg.rows, sg.cols, sg.cells.len,
            });

            // Two-pass vertex generation (same as main window):
            // Pass 1: All backgrounds first
            // Pass 2: All glyphs on top
            // This prevents glyphs that extend beyond cell bounds from being clipped by adjacent backgrounds.

            // Pre-allocate capacity: 6 verts/cell for bg + 6 verts/cell for glyphs + 6 for cursor
            const n_cells = @as(usize, sg.rows) * @as(usize, sg.cols);
            const est_verts = n_cells * 12 + 6;
            ext_verts.ensureTotalCapacity(self.alloc, est_verts) catch {
                self.log.write("[ext_grid] WARN: failed to pre-allocate {d} vertices\n", .{est_verts});
                continue; // Skip this grid if we can't allocate
            };

            const solid_uv: [2]f32 = .{ -1.0, -1.0 };

            // Create composite cell array - copy external grid cells and overlay float windows
            // This approach ensures float windows completely overwrite (not blend with) the underlying cells
            const composite_cells = self.alloc.alloc(grid_mod.Cell, n_cells) catch {
                self.log.write("[ext_grid] WARN: failed to allocate composite cells for {d} cells\n", .{n_cells});
                continue;
            };
            defer self.alloc.free(composite_cells);

            // Copy external grid cells to composite array
            if (sg.cells.len >= n_cells) {
                @memcpy(composite_cells[0..n_cells], sg.cells[0..n_cells]);
            } else {
                // Fill with defaults if source is smaller
                for (composite_cells) |*c| {
                    c.* = .{ .cp = ' ', .hl = 0 };
                }
                @memcpy(composite_cells[0..sg.cells.len], sg.cells);
            }

            // Overlay float windows anchored to this external grid into composite_cells
            const ext_info = self.grid.external_grids.get(grid_id);
            self.log.write("[ext_overlay_debug] grid_id={d} ext_info_exists={} win_pos_count={d}\n", .{
                grid_id, ext_info != null, self.grid.win_pos.count(),
            });

            var overlay_cell_count: u32 = 0;
            if (ext_info) |info| {
                self.log.write("[ext_overlay_debug] ext grid {d}: start_row={d} start_col={d}\n", .{
                    grid_id, info.start_row, info.start_col,
                });
                if (info.start_row >= 0 and info.start_col >= 0) {
                    const ext_start_row: i32 = info.start_row;
                    const ext_start_col: i32 = info.start_col;

                    // Scan win_pos for float windows anchored to this external grid
                    var win_it = self.grid.win_pos.iterator();
                    while (win_it.next()) |entry| {
                        const float_grid_id = entry.key_ptr.*;
                        const float_pos = entry.value_ptr.*;

                        self.log.write("[ext_overlay_debug] checking win_pos: float_grid={d} anchor={d} pos=({d},{d}) (target ext={d})\n", .{
                            float_grid_id, float_pos.anchor_grid, float_pos.row, float_pos.col, grid_id,
                        });

                        // Check if this float window is anchored to our external grid
                        if (float_pos.anchor_grid != grid_id) continue;

                        // Get the float window's sub_grid
                        const float_sg = self.grid.sub_grids.get(float_grid_id) orelse {
                            self.log.write("[ext_overlay_debug] WARN: float grid {d} has no sub_grid!\n", .{float_grid_id});
                            continue;
                        };

                        // Calculate float window position relative to this external grid
                        const float_row_in_ext: i32 = @as(i32, @intCast(float_pos.row)) - ext_start_row;
                        const float_col_in_ext: i32 = @as(i32, @intCast(float_pos.col)) - ext_start_col;

                        self.log.write("[ext_overlay_cells] FOUND anchored float: grid={d} size=({d}x{d}) rel_pos=({d},{d}) cells_len={d}\n", .{
                            float_grid_id, float_sg.rows, float_sg.cols, float_row_in_ext, float_col_in_ext, float_sg.cells.len,
                        });

                        // Sample first few cells from float_sg for debugging
                        if (float_sg.cells.len > 0) {
                            const sample_count = @min(float_sg.cells.len, 5);
                            for (0..sample_count) |i| {
                                const c = float_sg.cells[i];
                                self.log.write("[ext_overlay_cells] float_sg.cells[{d}]: cp=0x{x} hl={d}\n", .{ i, c.cp, c.hl });
                            }
                        }

                        // Copy float window cells into composite array (overwriting underlying cells)
                        for (0..float_sg.rows) |fr_idx| {
                            const fr: u32 = @intCast(fr_idx);
                            const target_row = float_row_in_ext + @as(i32, @intCast(fr));
                            if (target_row < 0 or target_row >= @as(i32, @intCast(sg.rows))) continue;

                            for (0..float_sg.cols) |fc_idx| {
                                const fc: u32 = @intCast(fc_idx);
                                const target_col = float_col_in_ext + @as(i32, @intCast(fc));
                                if (target_col < 0 or target_col >= @as(i32, @intCast(sg.cols))) continue;

                                const float_cell_idx: usize = @as(usize, fr) * @as(usize, float_sg.cols) + @as(usize, fc);
                                if (float_cell_idx >= float_sg.cells.len) continue;

                                const target_idx: usize = @as(usize, @intCast(target_row)) * @as(usize, sg.cols) + @as(usize, @intCast(target_col));
                                if (target_idx >= n_cells) continue;

                                // Overwrite composite cell with float window cell
                                composite_cells[target_idx] = float_sg.cells[float_cell_idx];
                                overlay_cell_count += 1;
                            }
                        }

                        self.log.write("[ext_overlay_cells] Copied {d} cells from float grid {d}\n", .{ overlay_cell_count, float_grid_id });
                    }
                }
            }

            self.log.write("[ext_overlay_summary] grid_id={d} total_overlay_cells={d}\n", .{ grid_id, overlay_cell_count });

            // Sample composite_cells after overlay for debugging
            if (overlay_cell_count > 0) {
                // Log a few cells from the overlay region
                const sample_row: usize = 0;
                for (0..@min(sg.cols, 10)) |c| {
                    const idx = sample_row * @as(usize, sg.cols) + c;
                    if (idx < n_cells) {
                        const cell = composite_cells[idx];
                        self.log.write("[ext_overlay_result] composite[row=0,col={d}]: cp=0x{x} hl={d}\n", .{ c, cell.cp, cell.hl });
                    }
                }
            }

            // Row-based vertex generation: process each row independently
            // This matches the main window's row-based approach for better partial updates
            const cursor_row: ?u32 = if (self.grid.cursor_grid == grid_id and self.grid.cursor_valid and self.grid.cursor_visible)
                self.grid.cursor_row
            else
                null;
            const cursor_col = self.grid.cursor_col;
            const is_cmdline = grid_id == grid_mod.CMDLINE_GRID_ID;

            for (0..sg.rows) |row_idx| {
                const row: u32 = @intCast(row_idx);

                // Skip clean rows unless full redraw needed or cursor is on this row
                const is_cursor_row = if (cursor_row) |cr| cr == row else false;
                if (!need_full_redraw and !is_cursor_row) {
                    // Check dirty_rows bitmap (also respect dirty flag which is set on resize/clear)
                    // When dirty=true (after resize), all rows should be redrawn
                    if (!sg.dirty and sg.dirty_rows.bit_length > row and !sg.dirty_rows.isSet(row)) {
                        continue; // Row is clean, skip it
                    }
                }

                const row_y: f32 = @as(f32, @floatFromInt(row)) * cellH;

                // Clear buffer for this row
                ext_verts.clearRetainingCapacity();

                // Estimate capacity for this row: 6 bg + 6 glyph + 6 deco per cell + 12 cursor
                const row_est = @as(usize, sg.cols) * 18 + 12;
                ext_verts.ensureTotalCapacity(self.alloc, row_est) catch continue;

                // Compose RenderCells for this row (resolve hl -> fg/bg/sp/style_flags)
                self.row_cells.clearRetainingCapacity();
                self.row_cells.ensureTotalCapacity(self.alloc, sg.cols) catch continue;
                self.row_cells.items.len = sg.cols;

                const row_start: usize = @as(usize, row) * @as(usize, sg.cols);
                for (0..sg.cols) |c| {
                    const cell_idx = row_start + c;
                    if (cell_idx >= n_cells) {
                        self.row_cells.items[c] = .{ .scalar = ' ', .fgRGB = default_bg, .bgRGB = default_bg, .spRGB = highlight.Highlights.SP_NOT_SET, .grid_id = grid_id, .style_flags = 0 };
                        continue;
                    }
                    const cell = composite_cells[cell_idx];
                    const attr = cache.getAttr(&self.hl, cell.hl);
                    self.row_cells.items[c] = .{
                        .scalar = cell.cp,
                        .fgRGB = attr.fg,
                        .bgRGB = attr.bg,
                        .spRGB = attr.sp,
                        .grid_id = grid_id,
                        .style_flags = packStyleFlags(attr),
                    };
                }

                // Pass 1: Background (run-length optimized)
                {
                    var c: u32 = 0;
                    while (c < sg.cols) {
                        const first = self.row_cells.items[c];
                        const run_bg = first.bgRGB;
                        const run_start = c;

                        var end: u32 = c;
                        while (end < sg.cols) : (end += 1) {
                            if (self.row_cells.items[end].bgRGB != run_bg) break;
                        }

                        const x0: f32 = @as(f32, @floatFromInt(run_start)) * cellW;
                        const x1: f32 = @as(f32, @floatFromInt(end)) * cellW;
                        const y0: f32 = row_y;
                        const y1: f32 = row_y + cellH;

                        const bg_alpha: f32 = if (run_bg == default_bg)
                            (if (self.blur_enabled) (if (is_cmdline) 0.0 else 0.5) else self.background_opacity)
                        else
                            1.0;
                        const bg_col = Helpers.rgba(run_bg, bg_alpha);

                        const tl = Helpers.ndc(x0, y0, grid_w, grid_h);
                        const tr = Helpers.ndc(x1, y0, grid_w, grid_h);
                        const bl = Helpers.ndc(x0, y1, grid_w, grid_h);
                        const br = Helpers.ndc(x1, y1, grid_w, grid_h);

                        ext_verts.appendAssumeCapacity(.{ .position = tl, .texCoord = solid_uv, .color = bg_col, .grid_id = grid_id, .deco_flags = 0, .deco_phase = 0 });
                        ext_verts.appendAssumeCapacity(.{ .position = tr, .texCoord = solid_uv, .color = bg_col, .grid_id = grid_id, .deco_flags = 0, .deco_phase = 0 });
                        ext_verts.appendAssumeCapacity(.{ .position = bl, .texCoord = solid_uv, .color = bg_col, .grid_id = grid_id, .deco_flags = 0, .deco_phase = 0 });
                        ext_verts.appendAssumeCapacity(.{ .position = tr, .texCoord = solid_uv, .color = bg_col, .grid_id = grid_id, .deco_flags = 0, .deco_phase = 0 });
                        ext_verts.appendAssumeCapacity(.{ .position = br, .texCoord = solid_uv, .color = bg_col, .grid_id = grid_id, .deco_flags = 0, .deco_phase = 0 });
                        ext_verts.appendAssumeCapacity(.{ .position = bl, .texCoord = solid_uv, .color = bg_col, .grid_id = grid_id, .deco_flags = 0, .deco_phase = 0 });

                        c = end;
                    }
                }

                // Pass 2: Under-decorations (underline, undercurl, etc.)
                {
                    const under_deco_mask: u8 = STYLE_UNDERLINE | STYLE_UNDERDOUBLE | STYLE_UNDERCURL | STYLE_UNDERDOTTED | STYLE_UNDERDASHED;
                    var c: u32 = 0;
                    while (c < sg.cols) {
                        const cell = self.row_cells.items[c];
                        if (cell.style_flags & under_deco_mask == 0) {
                            c += 1;
                            continue;
                        }

                        const run_start = c;
                        const run_flags = cell.style_flags;
                        const run_sp = cell.spRGB;
                        const run_fg = cell.fgRGB;

                        var run_end: u32 = c + 1;
                        while (run_end < sg.cols) : (run_end += 1) {
                            const next = self.row_cells.items[run_end];
                            if (next.style_flags != run_flags or next.spRGB != run_sp) break;
                        }

                        const deco_color = if (run_sp != highlight.Highlights.SP_NOT_SET) Helpers.rgb(run_sp) else Helpers.rgb(run_fg);
                        const x0: f32 = @as(f32, @floatFromInt(run_start)) * cellW;
                        const x1: f32 = @as(f32, @floatFromInt(run_end)) * cellW;

                        // Underline
                        if (run_flags & STYLE_UNDERLINE != 0) {
                            const uy0 = row_y + cellH - 2.0;
                            const uy1 = uy0 + 1.0;
                            const utl = Helpers.ndc(x0, uy0, grid_w, grid_h);
                            const utr = Helpers.ndc(x1, uy0, grid_w, grid_h);
                            const ubl = Helpers.ndc(x0, uy1, grid_w, grid_h);
                            const ubr = Helpers.ndc(x1, uy1, grid_w, grid_h);
                            ext_verts.appendAssumeCapacity(.{ .position = utl, .texCoord = solid_uv, .color = deco_color, .grid_id = grid_id, .deco_flags = c_api.DECO_UNDERLINE, .deco_phase = 0 });
                            ext_verts.appendAssumeCapacity(.{ .position = utr, .texCoord = solid_uv, .color = deco_color, .grid_id = grid_id, .deco_flags = c_api.DECO_UNDERLINE, .deco_phase = 0 });
                            ext_verts.appendAssumeCapacity(.{ .position = ubl, .texCoord = solid_uv, .color = deco_color, .grid_id = grid_id, .deco_flags = c_api.DECO_UNDERLINE, .deco_phase = 0 });
                            ext_verts.appendAssumeCapacity(.{ .position = utr, .texCoord = solid_uv, .color = deco_color, .grid_id = grid_id, .deco_flags = c_api.DECO_UNDERLINE, .deco_phase = 0 });
                            ext_verts.appendAssumeCapacity(.{ .position = ubr, .texCoord = solid_uv, .color = deco_color, .grid_id = grid_id, .deco_flags = c_api.DECO_UNDERLINE, .deco_phase = 0 });
                            ext_verts.appendAssumeCapacity(.{ .position = ubl, .texCoord = solid_uv, .color = deco_color, .grid_id = grid_id, .deco_flags = c_api.DECO_UNDERLINE, .deco_phase = 0 });
                        }

                        // Underdouble
                        if (run_flags & STYLE_UNDERDOUBLE != 0) {
                            const uy0_1 = row_y + cellH - 6.0;
                            const uy1_1 = uy0_1 + 1.0;
                            const uy0_2 = row_y + cellH - 2.0;
                            const uy1_2 = uy0_2 + 1.0;
                            // First line
                            var utl = Helpers.ndc(x0, uy0_1, grid_w, grid_h);
                            var utr = Helpers.ndc(x1, uy0_1, grid_w, grid_h);
                            var ubl = Helpers.ndc(x0, uy1_1, grid_w, grid_h);
                            var ubr = Helpers.ndc(x1, uy1_1, grid_w, grid_h);
                            ext_verts.appendAssumeCapacity(.{ .position = utl, .texCoord = solid_uv, .color = deco_color, .grid_id = grid_id, .deco_flags = c_api.DECO_UNDERLINE, .deco_phase = 0 });
                            ext_verts.appendAssumeCapacity(.{ .position = utr, .texCoord = solid_uv, .color = deco_color, .grid_id = grid_id, .deco_flags = c_api.DECO_UNDERLINE, .deco_phase = 0 });
                            ext_verts.appendAssumeCapacity(.{ .position = ubl, .texCoord = solid_uv, .color = deco_color, .grid_id = grid_id, .deco_flags = c_api.DECO_UNDERLINE, .deco_phase = 0 });
                            ext_verts.appendAssumeCapacity(.{ .position = utr, .texCoord = solid_uv, .color = deco_color, .grid_id = grid_id, .deco_flags = c_api.DECO_UNDERLINE, .deco_phase = 0 });
                            ext_verts.appendAssumeCapacity(.{ .position = ubr, .texCoord = solid_uv, .color = deco_color, .grid_id = grid_id, .deco_flags = c_api.DECO_UNDERLINE, .deco_phase = 0 });
                            ext_verts.appendAssumeCapacity(.{ .position = ubl, .texCoord = solid_uv, .color = deco_color, .grid_id = grid_id, .deco_flags = c_api.DECO_UNDERLINE, .deco_phase = 0 });
                            // Second line
                            utl = Helpers.ndc(x0, uy0_2, grid_w, grid_h);
                            utr = Helpers.ndc(x1, uy0_2, grid_w, grid_h);
                            ubl = Helpers.ndc(x0, uy1_2, grid_w, grid_h);
                            ubr = Helpers.ndc(x1, uy1_2, grid_w, grid_h);
                            ext_verts.appendAssumeCapacity(.{ .position = utl, .texCoord = solid_uv, .color = deco_color, .grid_id = grid_id, .deco_flags = c_api.DECO_UNDERLINE, .deco_phase = 0 });
                            ext_verts.appendAssumeCapacity(.{ .position = utr, .texCoord = solid_uv, .color = deco_color, .grid_id = grid_id, .deco_flags = c_api.DECO_UNDERLINE, .deco_phase = 0 });
                            ext_verts.appendAssumeCapacity(.{ .position = ubl, .texCoord = solid_uv, .color = deco_color, .grid_id = grid_id, .deco_flags = c_api.DECO_UNDERLINE, .deco_phase = 0 });
                            ext_verts.appendAssumeCapacity(.{ .position = utr, .texCoord = solid_uv, .color = deco_color, .grid_id = grid_id, .deco_flags = c_api.DECO_UNDERLINE, .deco_phase = 0 });
                            ext_verts.appendAssumeCapacity(.{ .position = ubr, .texCoord = solid_uv, .color = deco_color, .grid_id = grid_id, .deco_flags = c_api.DECO_UNDERLINE, .deco_phase = 0 });
                            ext_verts.appendAssumeCapacity(.{ .position = ubl, .texCoord = solid_uv, .color = deco_color, .grid_id = grid_id, .deco_flags = c_api.DECO_UNDERLINE, .deco_phase = 0 });
                        }

                        // Undercurl
                        if (run_flags & STYLE_UNDERCURL != 0) {
                            const uy0 = row_y + cellH - 4.0;
                            const uy1 = row_y + cellH;
                            const phase: f32 = @floatFromInt(run_start);
                            const utl = Helpers.ndc(x0, uy0, grid_w, grid_h);
                            const utr = Helpers.ndc(x1, uy0, grid_w, grid_h);
                            const ubl = Helpers.ndc(x0, uy1, grid_w, grid_h);
                            const ubr = Helpers.ndc(x1, uy1, grid_w, grid_h);
                            ext_verts.appendAssumeCapacity(.{ .position = utl, .texCoord = solid_uv, .color = deco_color, .grid_id = grid_id, .deco_flags = c_api.DECO_UNDERCURL, .deco_phase = phase });
                            ext_verts.appendAssumeCapacity(.{ .position = utr, .texCoord = solid_uv, .color = deco_color, .grid_id = grid_id, .deco_flags = c_api.DECO_UNDERCURL, .deco_phase = phase });
                            ext_verts.appendAssumeCapacity(.{ .position = ubl, .texCoord = solid_uv, .color = deco_color, .grid_id = grid_id, .deco_flags = c_api.DECO_UNDERCURL, .deco_phase = phase });
                            ext_verts.appendAssumeCapacity(.{ .position = utr, .texCoord = solid_uv, .color = deco_color, .grid_id = grid_id, .deco_flags = c_api.DECO_UNDERCURL, .deco_phase = phase });
                            ext_verts.appendAssumeCapacity(.{ .position = ubr, .texCoord = solid_uv, .color = deco_color, .grid_id = grid_id, .deco_flags = c_api.DECO_UNDERCURL, .deco_phase = phase });
                            ext_verts.appendAssumeCapacity(.{ .position = ubl, .texCoord = solid_uv, .color = deco_color, .grid_id = grid_id, .deco_flags = c_api.DECO_UNDERCURL, .deco_phase = phase });
                        }

                        // Underdotted
                        if (run_flags & STYLE_UNDERDOTTED != 0) {
                            const uy0 = row_y + cellH - 2.0;
                            const uy1 = uy0 + 1.0;
                            const utl = Helpers.ndc(x0, uy0, grid_w, grid_h);
                            const utr = Helpers.ndc(x1, uy0, grid_w, grid_h);
                            const ubl = Helpers.ndc(x0, uy1, grid_w, grid_h);
                            const ubr = Helpers.ndc(x1, uy1, grid_w, grid_h);
                            ext_verts.appendAssumeCapacity(.{ .position = utl, .texCoord = solid_uv, .color = deco_color, .grid_id = grid_id, .deco_flags = c_api.DECO_UNDERDOTTED, .deco_phase = 0 });
                            ext_verts.appendAssumeCapacity(.{ .position = utr, .texCoord = solid_uv, .color = deco_color, .grid_id = grid_id, .deco_flags = c_api.DECO_UNDERDOTTED, .deco_phase = 0 });
                            ext_verts.appendAssumeCapacity(.{ .position = ubl, .texCoord = solid_uv, .color = deco_color, .grid_id = grid_id, .deco_flags = c_api.DECO_UNDERDOTTED, .deco_phase = 0 });
                            ext_verts.appendAssumeCapacity(.{ .position = utr, .texCoord = solid_uv, .color = deco_color, .grid_id = grid_id, .deco_flags = c_api.DECO_UNDERDOTTED, .deco_phase = 0 });
                            ext_verts.appendAssumeCapacity(.{ .position = ubr, .texCoord = solid_uv, .color = deco_color, .grid_id = grid_id, .deco_flags = c_api.DECO_UNDERDOTTED, .deco_phase = 0 });
                            ext_verts.appendAssumeCapacity(.{ .position = ubl, .texCoord = solid_uv, .color = deco_color, .grid_id = grid_id, .deco_flags = c_api.DECO_UNDERDOTTED, .deco_phase = 0 });
                        }

                        // Underdashed
                        if (run_flags & STYLE_UNDERDASHED != 0) {
                            const uy0 = row_y + cellH - 2.0;
                            const uy1 = uy0 + 1.0;
                            const utl = Helpers.ndc(x0, uy0, grid_w, grid_h);
                            const utr = Helpers.ndc(x1, uy0, grid_w, grid_h);
                            const ubl = Helpers.ndc(x0, uy1, grid_w, grid_h);
                            const ubr = Helpers.ndc(x1, uy1, grid_w, grid_h);
                            ext_verts.appendAssumeCapacity(.{ .position = utl, .texCoord = solid_uv, .color = deco_color, .grid_id = grid_id, .deco_flags = c_api.DECO_UNDERDASHED, .deco_phase = 0 });
                            ext_verts.appendAssumeCapacity(.{ .position = utr, .texCoord = solid_uv, .color = deco_color, .grid_id = grid_id, .deco_flags = c_api.DECO_UNDERDASHED, .deco_phase = 0 });
                            ext_verts.appendAssumeCapacity(.{ .position = ubl, .texCoord = solid_uv, .color = deco_color, .grid_id = grid_id, .deco_flags = c_api.DECO_UNDERDASHED, .deco_phase = 0 });
                            ext_verts.appendAssumeCapacity(.{ .position = utr, .texCoord = solid_uv, .color = deco_color, .grid_id = grid_id, .deco_flags = c_api.DECO_UNDERDASHED, .deco_phase = 0 });
                            ext_verts.appendAssumeCapacity(.{ .position = ubr, .texCoord = solid_uv, .color = deco_color, .grid_id = grid_id, .deco_flags = c_api.DECO_UNDERDASHED, .deco_phase = 0 });
                            ext_verts.appendAssumeCapacity(.{ .position = ubl, .texCoord = solid_uv, .color = deco_color, .grid_id = grid_id, .deco_flags = c_api.DECO_UNDERDASHED, .deco_phase = 0 });
                        }

                        c = run_end;
                    }
                }

                // Pass 3: Glyphs (with glyph_cache)
                const ensure_base = self.cb.on_atlas_ensure_glyph;
                const ensure_styled = self.cb.on_atlas_ensure_glyph_styled;
                for (0..sg.cols) |col_idx| {
                    const col: u32 = @intCast(col_idx);
                    const cell = self.row_cells.items[col];
                    const scalar: u32 = if (cell.scalar == 0) 32 else cell.scalar;

                    if (scalar == ' ' or scalar == 32) continue;

                    if (sample_idx < 10) {
                        sample_cps[sample_idx] = scalar;
                        sample_idx += 1;
                    }
                    non_space_count += 1;

                    const x0: f32 = @as(f32, @floatFromInt(col)) * cellW;
                    const style_mask: u32 = @as(u32, cell.style_flags & (STYLE_BOLD | STYLE_ITALIC));
                    const style_index: u32 = @as(u32, if (cell.style_flags & STYLE_BOLD != 0) @as(u32, 1) else 0) +
                        @as(u32, if (cell.style_flags & STYLE_ITALIC != 0) @as(u32, 2) else 0);

                    var ge: c_api.GlyphEntry = undefined;

                    // Glyph cache lookup (same logic as row_mode)
                    const glyph_ok = blk: {
                        // Check ASCII cache (scalar < 128)
                        if (scalar < 128 and glyph_cache_ascii != null and glyph_valid_ascii != null) {
                            const cache_key: usize = scalar * 4 + style_index;
                            if (cache_key < GLYPH_CACHE_ASCII_SIZE) {
                                if (glyph_valid_ascii.?[cache_key]) {
                                    cache.perf_glyph_ascii_hits += 1;
                                    ge = glyph_cache_ascii.?[cache_key];
                                    break :blk true;
                                }
                                // Cache miss: call callback
                                cache.perf_glyph_ascii_misses += 1;
                                const ok = if (style_mask != 0 and ensure_styled != null) cb: {
                                    const c_style: u32 = @as(u32, if (cell.style_flags & STYLE_BOLD != 0) c_api.STYLE_BOLD else 0) |
                                        @as(u32, if (cell.style_flags & STYLE_ITALIC != 0) c_api.STYLE_ITALIC else 0);
                                    break :cb ensure_styled.?(self.ctx, scalar, c_style, &ge) != 0;
                                } else if (ensure_base) |ensure| cb: {
                                    break :cb ensure(self.ctx, scalar, &ge) != 0;
                                } else false;
                                if (ok) {
                                    glyph_cache_ascii.?[cache_key] = ge;
                                    glyph_valid_ascii.?[cache_key] = true;
                                }
                                break :blk ok;
                            }
                        }
                        // Non-ASCII: use hash table cache
                        if (glyph_cache_non_ascii != null and glyph_keys_non_ascii != null and GLYPH_CACHE_NON_ASCII_SIZE > 0) {
                            const key = (@as(u64, scalar) << 2) | @as(u64, style_index);
                            const hash_val = (scalar *% 2654435761) ^ style_index;
                            const hash_idx = @as(usize, hash_val % GLYPH_CACHE_NON_ASCII_SIZE);
                            if (glyph_keys_non_ascii.?[hash_idx] == key) {
                                cache.perf_glyph_nonascii_hits += 1;
                                ge = glyph_cache_non_ascii.?[hash_idx];
                                break :blk true;
                            }
                            // Cache miss: call callback
                            cache.perf_glyph_nonascii_misses += 1;
                            const ok = if (style_mask != 0 and ensure_styled != null) cb: {
                                const c_style: u32 = @as(u32, if (cell.style_flags & STYLE_BOLD != 0) c_api.STYLE_BOLD else 0) |
                                    @as(u32, if (cell.style_flags & STYLE_ITALIC != 0) c_api.STYLE_ITALIC else 0);
                                break :cb ensure_styled.?(self.ctx, scalar, c_style, &ge) != 0;
                            } else if (ensure_base) |ensure| cb: {
                                break :cb ensure(self.ctx, scalar, &ge) != 0;
                            } else false;
                            if (ok) {
                                glyph_cache_non_ascii.?[hash_idx] = ge;
                                glyph_keys_non_ascii.?[hash_idx] = key;
                            }
                            break :blk ok;
                        }
                        // No cache: call callback directly
                        const ok = if (style_mask != 0 and ensure_styled != null) cb: {
                            const c_style: u32 = @as(u32, if (cell.style_flags & STYLE_BOLD != 0) c_api.STYLE_BOLD else 0) |
                                @as(u32, if (cell.style_flags & STYLE_ITALIC != 0) c_api.STYLE_ITALIC else 0);
                            break :cb ensure_styled.?(self.ctx, scalar, c_style, &ge) != 0;
                        } else if (ensure_base) |ensure| cb: {
                            break :cb ensure(self.ctx, scalar, &ge) != 0;
                        } else false;
                        break :blk ok;
                    };

                    if (glyph_ok) {
                        glyph_success_count += 1;
                        const glyph_col = Helpers.rgb(cell.fgRGB);

                        const baseY = row_y + topPad;
                        const baselineY = baseY + ge.ascent_px;
                        const gx0 = x0 + ge.bbox_origin_px[0];
                        const gx1 = gx0 + ge.bbox_size_px[0];
                        const gy0 = baselineY - (ge.bbox_origin_px[1] + ge.bbox_size_px[1]);
                        const gy1 = gy0 + ge.bbox_size_px[1];

                        const gtl = Helpers.ndc(gx0, gy0, grid_w, grid_h);
                        const gtr = Helpers.ndc(gx1, gy0, grid_w, grid_h);
                        const gbl = Helpers.ndc(gx0, gy1, grid_w, grid_h);
                        const gbr = Helpers.ndc(gx1, gy1, grid_w, grid_h);

                        const uv_x0 = ge.uv_min[0];
                        const uv_y0 = ge.uv_min[1];
                        const uv_x1 = ge.uv_max[0];
                        const uv_y1 = ge.uv_max[1];

                        ext_verts.appendAssumeCapacity(.{ .position = gtl, .texCoord = .{ uv_x0, uv_y0 }, .color = glyph_col, .grid_id = grid_id, .deco_flags = 0, .deco_phase = 0 });
                        ext_verts.appendAssumeCapacity(.{ .position = gtr, .texCoord = .{ uv_x1, uv_y0 }, .color = glyph_col, .grid_id = grid_id, .deco_flags = 0, .deco_phase = 0 });
                        ext_verts.appendAssumeCapacity(.{ .position = gbl, .texCoord = .{ uv_x0, uv_y1 }, .color = glyph_col, .grid_id = grid_id, .deco_flags = 0, .deco_phase = 0 });
                        ext_verts.appendAssumeCapacity(.{ .position = gtr, .texCoord = .{ uv_x1, uv_y0 }, .color = glyph_col, .grid_id = grid_id, .deco_flags = 0, .deco_phase = 0 });
                        ext_verts.appendAssumeCapacity(.{ .position = gbr, .texCoord = .{ uv_x1, uv_y1 }, .color = glyph_col, .grid_id = grid_id, .deco_flags = 0, .deco_phase = 0 });
                        ext_verts.appendAssumeCapacity(.{ .position = gbl, .texCoord = .{ uv_x0, uv_y1 }, .color = glyph_col, .grid_id = grid_id, .deco_flags = 0, .deco_phase = 0 });
                    } else {
                        glyph_fail_count += 1;
                    }
                }

                // Pass 4: Strikethrough
                {
                    var c: u32 = 0;
                    while (c < sg.cols) {
                        const cell = self.row_cells.items[c];
                        if (cell.style_flags & STYLE_STRIKETHROUGH == 0) {
                            c += 1;
                            continue;
                        }

                        const run_start = c;
                        const run_flags = cell.style_flags;
                        const run_sp = cell.spRGB;
                        const run_fg = cell.fgRGB;

                        var run_end: u32 = c + 1;
                        while (run_end < sg.cols) : (run_end += 1) {
                            const next = self.row_cells.items[run_end];
                            if (next.style_flags != run_flags or next.spRGB != run_sp) break;
                        }

                        const deco_color = if (run_sp != highlight.Highlights.SP_NOT_SET) Helpers.rgb(run_sp) else Helpers.rgb(run_fg);
                        const x0: f32 = @as(f32, @floatFromInt(run_start)) * cellW;
                        const x1: f32 = @as(f32, @floatFromInt(run_end)) * cellW;
                        const sy0 = row_y + cellH * 0.5 - 0.5;
                        const sy1 = sy0 + 1.0;

                        const stl = Helpers.ndc(x0, sy0, grid_w, grid_h);
                        const str = Helpers.ndc(x1, sy0, grid_w, grid_h);
                        const sbl = Helpers.ndc(x0, sy1, grid_w, grid_h);
                        const sbr = Helpers.ndc(x1, sy1, grid_w, grid_h);

                        ext_verts.appendAssumeCapacity(.{ .position = stl, .texCoord = solid_uv, .color = deco_color, .grid_id = grid_id, .deco_flags = c_api.DECO_STRIKETHROUGH, .deco_phase = 0 });
                        ext_verts.appendAssumeCapacity(.{ .position = str, .texCoord = solid_uv, .color = deco_color, .grid_id = grid_id, .deco_flags = c_api.DECO_STRIKETHROUGH, .deco_phase = 0 });
                        ext_verts.appendAssumeCapacity(.{ .position = sbl, .texCoord = solid_uv, .color = deco_color, .grid_id = grid_id, .deco_flags = c_api.DECO_STRIKETHROUGH, .deco_phase = 0 });
                        ext_verts.appendAssumeCapacity(.{ .position = str, .texCoord = solid_uv, .color = deco_color, .grid_id = grid_id, .deco_flags = c_api.DECO_STRIKETHROUGH, .deco_phase = 0 });
                        ext_verts.appendAssumeCapacity(.{ .position = sbr, .texCoord = solid_uv, .color = deco_color, .grid_id = grid_id, .deco_flags = c_api.DECO_STRIKETHROUGH, .deco_phase = 0 });
                        ext_verts.appendAssumeCapacity(.{ .position = sbl, .texCoord = solid_uv, .color = deco_color, .grid_id = grid_id, .deco_flags = c_api.DECO_STRIKETHROUGH, .deco_phase = 0 });

                        c = run_end;
                    }
                }

                // Cursor rendering if cursor is on this row
                if (cursor_row) |cur_row| {
                    if (cur_row == row and cursor_col < sg.cols) {
                        const cx0 = @as(f32, @floatFromInt(cursor_col)) * cellW;
                        const cy0 = row_y;

                        var is_double_width = false;
                        if (cursor_col + 1 < sg.cols) {
                            const next_idx: usize = @as(usize, cur_row) * @as(usize, sg.cols) + @as(usize, cursor_col + 1);
                            if (next_idx < sg.cells.len and sg.cells[next_idx].cp == 0) {
                                is_double_width = true;
                            }
                        }
                        const cursor_width: f32 = if (is_double_width) cellW * 2 else cellW;

                        const pct_u32 = @max(@as(u32, 1), @min(self.grid.cursor_cell_percentage, 100));
                        const pct: f32 = @floatFromInt(pct_u32);
                        const tW = cellW * pct / 100.0;
                        const tH = cellH * pct / 100.0;

                        const crx0: f32 = cx0;
                        var cry0: f32 = cy0;
                        var crx1: f32 = cx0 + cursor_width;
                        const cry1: f32 = cy0 + cellH;

                        self.log.write("[ext_cursor] shape={s} pct={d} cursor_style_enabled={}\n", .{
                            @tagName(self.grid.cursor_shape), pct_u32, self.grid.cursor_style_enabled,
                        });

                        switch (self.grid.cursor_shape) {
                            .vertical => crx1 = cx0 + tW,
                            .horizontal => cry0 = cy0 + (cellH - tH),
                            .block => {},
                        }

                        // Resolve cursor colors (same as main grid)
                        const cursor_bg: u32 = if (self.grid.cursor_attr_id != 0)
                            self.hl.get(self.grid.cursor_attr_id).bg
                        else
                            self.hl.default_fg; // attr_id == 0: swap default colors (per Nvim spec)
                        const cursor_color = Helpers.rgb(cursor_bg);

                        const ctl = Helpers.ndc(crx0, cry0, grid_w, grid_h);
                        const ctr = Helpers.ndc(crx1, cry0, grid_w, grid_h);
                        const cbl = Helpers.ndc(crx0, cry1, grid_w, grid_h);
                        const cbr = Helpers.ndc(crx1, cry1, grid_w, grid_h);

                        ext_verts.appendAssumeCapacity(.{ .position = ctl, .texCoord = solid_uv, .color = cursor_color, .grid_id = grid_id, .deco_flags = c_api.DECO_CURSOR, .deco_phase = 0 });
                        ext_verts.appendAssumeCapacity(.{ .position = ctr, .texCoord = solid_uv, .color = cursor_color, .grid_id = grid_id, .deco_flags = c_api.DECO_CURSOR, .deco_phase = 0 });
                        ext_verts.appendAssumeCapacity(.{ .position = cbl, .texCoord = solid_uv, .color = cursor_color, .grid_id = grid_id, .deco_flags = c_api.DECO_CURSOR, .deco_phase = 0 });
                        ext_verts.appendAssumeCapacity(.{ .position = ctr, .texCoord = solid_uv, .color = cursor_color, .grid_id = grid_id, .deco_flags = c_api.DECO_CURSOR, .deco_phase = 0 });
                        ext_verts.appendAssumeCapacity(.{ .position = cbr, .texCoord = solid_uv, .color = cursor_color, .grid_id = grid_id, .deco_flags = c_api.DECO_CURSOR, .deco_phase = 0 });
                        ext_verts.appendAssumeCapacity(.{ .position = cbl, .texCoord = solid_uv, .color = cursor_color, .grid_id = grid_id, .deco_flags = c_api.DECO_CURSOR, .deco_phase = 0 });

                        // Cursor text for block cursor
                        if (self.grid.cursor_shape == .block) {
                            const cell_idx: usize = @as(usize, cur_row) * @as(usize, sg.cols) + @as(usize, cursor_col);
                            if (cell_idx < sg.cells.len) {
                                const cursor_cell = sg.cells[cell_idx];
                                if (cursor_cell.cp != 0 and cursor_cell.cp != ' ') {
                                    var glyph_entry: c_api.GlyphEntry = undefined;
                                    var glyph_ok: c_int = -1;

                                    if (self.cb.on_atlas_ensure_glyph_styled) |styled_fn| {
                                        glyph_ok = styled_fn(self.ctx, cursor_cell.cp, 0, &glyph_entry);
                                    } else if (self.cb.on_atlas_ensure_glyph) |fn_ptr| {
                                        glyph_ok = fn_ptr(self.ctx, cursor_cell.cp, &glyph_entry);
                                    }

                                    if (glyph_ok != 0 and glyph_entry.bbox_size_px[0] > 0 and glyph_entry.bbox_size_px[1] > 0) {
                                        const cursorBaseY: f32 = cy0 + topPad;
                                        const baselineY: f32 = cursorBaseY + glyph_entry.ascent_px;
                                        const gx0: f32 = cx0 + glyph_entry.bbox_origin_px[0];
                                        const gx1: f32 = gx0 + glyph_entry.bbox_size_px[0];
                                        const gy0: f32 = baselineY - (glyph_entry.bbox_origin_px[1] + glyph_entry.bbox_size_px[1]);
                                        const gy1: f32 = gy0 + glyph_entry.bbox_size_px[1];

                                        const uv_x0 = glyph_entry.uv_min[0];
                                        const uv_y0 = glyph_entry.uv_min[1];
                                        const uv_x1 = glyph_entry.uv_max[0];
                                        const uv_y1 = glyph_entry.uv_max[1];

                                        const cursor_fg: u32 = if (self.grid.cursor_attr_id != 0)
                                            self.hl.get(self.grid.cursor_attr_id).fg
                                        else
                                            self.hl.default_bg; // attr_id == 0: swap default colors (per Nvim spec)
                                        const text_col = Helpers.rgb(cursor_fg);

                                        const gtl = Helpers.ndc(gx0, gy0, grid_w, grid_h);
                                        const gtr = Helpers.ndc(gx1, gy0, grid_w, grid_h);
                                        const gbl = Helpers.ndc(gx0, gy1, grid_w, grid_h);
                                        const gbr = Helpers.ndc(gx1, gy1, grid_w, grid_h);

                                        ext_verts.appendAssumeCapacity(.{ .position = gtl, .texCoord = .{ uv_x0, uv_y0 }, .color = text_col, .grid_id = grid_id, .deco_flags = 0, .deco_phase = 0 });
                                        ext_verts.appendAssumeCapacity(.{ .position = gtr, .texCoord = .{ uv_x1, uv_y0 }, .color = text_col, .grid_id = grid_id, .deco_flags = 0, .deco_phase = 0 });
                                        ext_verts.appendAssumeCapacity(.{ .position = gbl, .texCoord = .{ uv_x0, uv_y1 }, .color = text_col, .grid_id = grid_id, .deco_flags = 0, .deco_phase = 0 });
                                        ext_verts.appendAssumeCapacity(.{ .position = gtr, .texCoord = .{ uv_x1, uv_y0 }, .color = text_col, .grid_id = grid_id, .deco_flags = 0, .deco_phase = 0 });
                                        ext_verts.appendAssumeCapacity(.{ .position = gbr, .texCoord = .{ uv_x1, uv_y1 }, .color = text_col, .grid_id = grid_id, .deco_flags = 0, .deco_phase = 0 });
                                        ext_verts.appendAssumeCapacity(.{ .position = gbl, .texCoord = .{ uv_x0, uv_y1 }, .color = text_col, .grid_id = grid_id, .deco_flags = 0, .deco_phase = 0 });
                                    }
                                }
                            }
                        }
                    }
                }

                // Send this row's vertices
                if (ext_verts.items.len > 0) {
                    row_cb(self.ctx, grid_id, row, 1, ext_verts.items.ptr, ext_verts.items.len, 1, sg.rows, sg.cols);
                }
            }

            // Debug log glyph statistics
            self.log.write("[ext_grid_row] grid_id={d} rows={d} cols={d} non_space={d} glyph_ok={d} glyph_fail={d}\n", .{
                grid_id, sg.rows, sg.cols, non_space_count, glyph_success_count, glyph_fail_count,
            });

            // Log cache performance for this grid
            self.log.write("[ext_grid_perf] grid_id={d} hl_cache hits={d} misses={d}\n", .{
                grid_id, cache.perf_hl_cache_hits, cache.perf_hl_cache_misses,
            });
            self.log.write("[ext_grid_perf] grid_id={d} glyph_cache ascii_hits={d} ascii_misses={d} nonascii_hits={d} nonascii_misses={d}\n", .{
                grid_id, cache.perf_glyph_ascii_hits, cache.perf_glyph_ascii_misses, cache.perf_glyph_nonascii_hits, cache.perf_glyph_nonascii_misses,
            });

            // Clear dirty flags after sending (both dirty and dirty_rows)
            sg.clearDirty();
        }
    }

    /// Wrapper for sendExternalGridVerticesFiltered - updates all grids.
    fn sendExternalGridVertices(self: *Core, force_render: bool) void {
        self.sendExternalGridVerticesFiltered(force_render, null);
    }

    /// Check for cmdline state changes and create/update/close external float window via Neovim API.
    /// The cmdline is rendered by Neovim in an external float window.
    fn notifyCmdlineChanges(self: *Core) void {
        if (!self.grid.cmdline_dirty) return;
        if (!self.ext_cmdline_enabled) return;
        defer self.grid.clearCmdlineDirty();

        // Check if any cmdline is visible, find the highest level (most recent)
        var any_visible = false;
        var visible_level: u32 = 0;
        var state_it = self.grid.cmdline_states.iterator();
        while (state_it.next()) |entry| {
            if (entry.value_ptr.visible) {
                any_visible = true;
                // Use the highest level (Expression register is level 2, normal cmdline is level 1)
                if (entry.key_ptr.* > visible_level) {
                    visible_level = entry.key_ptr.*;
                }
            }
        }

        const block_visible = self.grid.cmdline_block.visible;
        const block_line_count: u32 = @intCast(self.grid.cmdline_block.lines.items.len);

        // Handle cmdline_block mode (multi-line input like :lua <<EOF)
        if (block_visible and block_line_count > 0) {
            self.sendCmdlineBlockShow(any_visible, visible_level);
            return;
        }

        if (any_visible) {
            const state = self.grid.cmdline_states.getPtr(visible_level) orelse return;
            const cmdline_grid_id = grid_mod.CMDLINE_GRID_ID;

            // Record command content for split view label
            // (record every update, the final content before hide is the executed command)
            self.last_cmd_firstc = state.firstc;
            self.last_cmd_len = 0;
            for (state.content.items) |chunk| {
                const remaining = self.last_cmd_buf.len - self.last_cmd_len;
                const copy_len = @min(chunk.text.len, remaining);
                if (copy_len > 0) {
                    @memcpy(self.last_cmd_buf[self.last_cmd_len..][0..copy_len], chunk.text[0..copy_len]);
                    self.last_cmd_len += copy_len;
                }
            }
            // Record start time when command is first shown
            if (self.last_cmd_start_time == null) {
                self.last_cmd_start_time = std.time.nanoTimestamp();
            }

            // Notify Swift about cmdline show (for icon update etc.)
            // Note: We pass minimal info here since content requires type conversion.
            // The main purpose is to inform Swift about firstc for icon display.
            if (self.cb.on_cmdline_show) |callback| {
                var dummy_content: [1]c_api.CmdlineChunk = .{c_api.CmdlineChunk{
                    .hl_id = 0,
                    .text = "",
                    .text_len = 0,
                }};
                callback(
                    self.ctx,
                    &dummy_content,
                    0, // content_count = 0, so Swift won't read content
                    state.pos,
                    state.firstc,
                    state.prompt.ptr,
                    state.prompt.len,
                    state.indent,
                    visible_level,
                    state.prompt_hl_id,
                );
            }

            // Check if content has control characters (affects special_char display)
            const has_control_chars = blk: {
                for (state.content.items) |chunk| {
                    var citer = std.unicode.Utf8View.initUnchecked(chunk.text).iterator();
                    while (citer.nextCodepoint()) |cp| {
                        if (cp < 0x20 or cp == 0x7F) break :blk true;
                    }
                }
                break :blk false;
            };

            // Calculate display width: firstc + prompt + indent + content (with caret notation) + special_char
            var display_width: u32 = 0;
            if (state.firstc != 0) display_width += 1;
            display_width += countDisplayWidth(state.prompt);
            display_width += state.indent;
            for (state.content.items) |chunk| {
                display_width += countDisplayWidth(chunk.text);
            }
            const special = state.getSpecialChar();
            if (!has_control_chars and special.len > 0) {
                display_width += countDisplayWidth(special);
            }

            // Grid width: start at main grid width, expand up to screen width, then scroll
            const min_width: u32 = if (self.grid.cols > 0) self.grid.cols else 80;
            const max_width: u32 = if (self.grid.screen_cols > 0) self.grid.screen_cols else min_width;
            const content_width: u32 = display_width + 1; // +1 for cursor
            const width: u32 = @min(@max(content_width, min_width), max_width);

            // Calculate scroll offset: if content exceeds width, scroll to show cursor (end)
            // We want cursor position (+ 1 for cursor cell) to be visible at the right edge
            const total_width: u32 = display_width + 1; // +1 for cursor at end
            const scroll_offset: u32 = if (total_width > width) total_width - width else 0;

            // Create or resize cmdline grid
            self.grid.resizeGrid(cmdline_grid_id, 1, width) catch |e| {
                self.log.write("[cmdline] resizeGrid failed: {any}\n", .{e});
                return;
            };
            self.grid.clearGrid(cmdline_grid_id);

            // Write to grid with proper hl_ids, accounting for scroll offset
            var logical_col: u32 = 0; // Position in the full content
            var grid_col: u32 = 0; // Position in the visible grid

            // Helper to write a cell, respecting scroll offset
            const WriterState = struct {
                grid: *grid_mod.Grid,
                grid_id: i64,
                scroll_offset: u32,
                width: u32,
                logical_col: *u32,
                grid_col: *u32,

                fn writeCell(s: @This(), cp: u32, hl_id: u32) bool {
                    if (s.logical_col.* >= s.scroll_offset) {
                        if (s.grid_col.* >= s.width) return false;
                        s.grid.putCellGrid(s.grid_id, 0, s.grid_col.*, cp, hl_id);
                        s.grid_col.* += 1;
                    }
                    s.logical_col.* += 1;
                    return true;
                }
            };

            var writer = WriterState{
                .grid = &self.grid,
                .grid_id = cmdline_grid_id,
                .scroll_offset = scroll_offset,
                .width = width,
                .logical_col = &logical_col,
                .grid_col = &grid_col,
            };

            // firstc (e.g. ':' '/' '?') - use hl_id 0 (default)
            if (state.firstc != 0) {
                if (!writer.writeCell(state.firstc, 0)) {}
            }

            // prompt - use prompt_hl_id
            if (state.prompt.len > 0) {
                var piter = std.unicode.Utf8View.initUnchecked(state.prompt).iterator();
                while (piter.nextCodepoint()) |cp| {
                    if (!writer.writeCell(cp, state.prompt_hl_id)) break;
                    // Add continuation cell for wide characters
                    if (isWideChar(cp)) {
                        if (!writer.writeCell(0, state.prompt_hl_id)) break;
                    }
                }
            }

            // indent (spaces) - use hl_id 0
            var indent_i: u32 = 0;
            while (indent_i < state.indent) : (indent_i += 1) {
                if (!writer.writeCell(' ', 0)) break;
            }

            // content chunks - use each chunk's hl_id, with caret notation for control chars
            for (state.content.items) |chunk| {
                var citer = std.unicode.Utf8View.initUnchecked(chunk.text).iterator();
                while (citer.nextCodepoint()) |cp| {
                    if (cp < 0x20) {
                        // Control character: display as ^X with chunk's hl_id
                        if (!writer.writeCell('^', chunk.hl_id)) break;
                        const ctrl_char: u32 = '@' + cp;
                        if (!writer.writeCell(ctrl_char, chunk.hl_id)) break;
                    } else if (cp == 0x7F) {
                        // DEL character: display as ^?
                        if (!writer.writeCell('^', chunk.hl_id)) break;
                        if (!writer.writeCell('?', chunk.hl_id)) break;
                    } else {
                        if (!writer.writeCell(cp, chunk.hl_id)) break;
                        // Add continuation cell for wide characters
                        if (isWideChar(cp)) {
                            if (!writer.writeCell(0, chunk.hl_id)) break;
                        }
                    }
                }
            }

            // special_char (shown at cursor position after Ctrl-V etc.)
            if (!has_control_chars and special.len > 0) {
                var siter = std.unicode.Utf8View.initUnchecked(special).iterator();
                while (siter.nextCodepoint()) |cp| {
                    if (!writer.writeCell(cp, 0)) break;
                    // Add continuation cell for wide characters
                    if (isWideChar(cp)) {
                        if (!writer.writeCell(0, 0)) break;
                    }
                }
            }

            // Cursor position: firstc + prompt + indent + display_pos - scroll_offset
            var cursor_col: u32 = 0;
            if (state.firstc != 0) cursor_col += 1;
            cursor_col += countDisplayWidth(state.prompt);
            cursor_col += state.indent;
            // Calculate display position by counting through content
            var pos_remaining: u32 = state.pos;
            outer: for (state.content.items) |chunk| {
                var piter = std.unicode.Utf8View.initUnchecked(chunk.text).iterator();
                while (piter.nextCodepoint()) |cp| {
                    if (pos_remaining == 0) break :outer;
                    pos_remaining -= 1;
                    if (cp < 0x20 or cp == 0x7F) {
                        cursor_col += 2; // ^X notation
                    } else if (isWideChar(cp)) {
                        cursor_col += 2; // Wide character
                    } else {
                        cursor_col += 1;
                    }
                }
            }
            // Adjust cursor position for scroll offset
            cursor_col = if (cursor_col >= scroll_offset) cursor_col - scroll_offset else 0;

            // Mark as external grid
            _ = self.grid.setWinExternalPos(cmdline_grid_id, 0) catch |e| {
                self.log.write("[cmdline] setWinExternalPos failed: {any}\n", .{e});
                return;
            };

            // Save current cursor position before switching to cmdline (only if not already on cmdline)
            if (self.grid.cursor_grid != cmdline_grid_id) {
                self.pre_cmdline_cursor_grid = self.grid.cursor_grid;
                self.pre_cmdline_cursor_row = self.grid.cursor_row;
                self.pre_cmdline_cursor_col = self.grid.cursor_col;
                self.log.write("[cmdline] saving pre_cmdline cursor: grid={d} row={d} col={d}\n", .{
                    self.pre_cmdline_cursor_grid, self.pre_cmdline_cursor_row, self.pre_cmdline_cursor_col,
                });
            }

            // Set cursor position
            self.grid.cursor_grid = cmdline_grid_id;
            self.grid.cursor_row = 0;
            self.grid.cursor_col = cursor_col;
            self.grid.cursor_valid = true;

            self.log.write("[cmdline] show: width={d} cursor={d} display_width={d}\n", .{ width, cursor_col, display_width });
        } else if (!block_visible) {
            // No cmdline visible and no block visible - close the external float window
            self.sendCmdlineHide();
        }
    }

    /// Handle cmdline_block mode (multi-line input).
    /// Shows all block lines + current cmdline line in a multi-row grid.
    fn sendCmdlineBlockShow(self: *Core, current_line_visible: bool, visible_level: u32) void {
        const cmdline_grid_id = grid_mod.CMDLINE_GRID_ID;
        const block_lines = self.grid.cmdline_block.lines.items;
        const block_line_count: u32 = @intCast(block_lines.len);

        // Calculate total rows and max width
        // Minimum width = main grid width; frontend constrains to screen width
        const min_width: u32 = if (self.grid.cols > 0) self.grid.cols else 40;
        var max_width: u32 = min_width;

        // Calculate width from block lines (accounting for control characters)
        for (block_lines) |line| {
            var line_width: u32 = 0;
            for (line.items) |chunk| {
                line_width += countDisplayWidth(chunk.text);
            }
            if (line_width + 1 > max_width) max_width = line_width + 1;
        }

        // Calculate current cmdline line width if visible
        var cursor_col: u32 = 0;
        var current_has_control_chars = false;
        var current_state: ?*grid_mod.CmdlineState = null;

        if (current_line_visible) {
            if (self.grid.cmdline_states.getPtr(visible_level)) |state| {
                current_state = state;

                // Check for control characters
                current_has_control_chars = blk: {
                    for (state.content.items) |chunk| {
                        var citer = std.unicode.Utf8View.initUnchecked(chunk.text).iterator();
                        while (citer.nextCodepoint()) |cp| {
                            if (cp < 0x20 or cp == 0x7F) break :blk true;
                        }
                    }
                    break :blk false;
                };

                // Calculate display width
                var current_width: u32 = 0;
                if (state.firstc != 0) current_width += 1;
                current_width += countDisplayWidth(state.prompt);
                current_width += state.indent;
                for (state.content.items) |chunk| {
                    current_width += countDisplayWidth(chunk.text);
                }
                const special = state.getSpecialChar();
                if (!current_has_control_chars and special.len > 0) {
                    current_width += countDisplayWidth(special);
                }
                if (current_width + 1 > max_width) max_width = current_width + 1;

                // Cursor position: firstc + prompt + indent + display_pos
                if (state.firstc != 0) cursor_col += 1;
                cursor_col += countDisplayWidth(state.prompt);
                cursor_col += state.indent;
                // Calculate display position by counting through content
                var pos_remaining: u32 = state.pos;
                outer: for (state.content.items) |chunk| {
                    var piter = std.unicode.Utf8View.initUnchecked(chunk.text).iterator();
                    while (piter.nextCodepoint()) |cp| {
                        if (pos_remaining == 0) break :outer;
                        pos_remaining -= 1;
                        if (cp < 0x20 or cp == 0x7F) {
                            cursor_col += 2; // ^X notation
                        } else if (isWideChar(cp)) {
                            cursor_col += 2; // Wide character
                        } else {
                            cursor_col += 1;
                        }
                    }
                }
            }
        }

        // Frontend will constrain max_width to screen width
        const total_rows: u32 = block_line_count + (if (current_line_visible) @as(u32, 1) else @as(u32, 0));

        // Create or resize cmdline grid
        self.grid.resizeGrid(cmdline_grid_id, total_rows, max_width) catch |e| {
            self.log.write("[cmdline_block] resizeGrid failed: {any}\n", .{e});
            return;
        };

        // Clear the grid first
        self.grid.clearGrid(cmdline_grid_id);

        // Write block lines to grid (with caret notation for control characters)
        for (block_lines, 0..) |line, row_idx| {
            var col: u32 = 0;
            for (line.items) |chunk| {
                var iter = std.unicode.Utf8View.initUnchecked(chunk.text).iterator();
                while (iter.nextCodepoint()) |cp| {
                    if (col >= max_width) break;
                    if (cp < 0x20) {
                        // Control character: display as ^X (caret notation)
                        self.grid.putCellGrid(cmdline_grid_id, @intCast(row_idx), col, '^', chunk.hl_id);
                        col += 1;
                        if (col >= max_width) break;
                        const ctrl_char: u32 = '@' + cp;
                        self.grid.putCellGrid(cmdline_grid_id, @intCast(row_idx), col, ctrl_char, chunk.hl_id);
                        col += 1;
                    } else if (cp == 0x7F) {
                        // DEL character: display as ^?
                        self.grid.putCellGrid(cmdline_grid_id, @intCast(row_idx), col, '^', chunk.hl_id);
                        col += 1;
                        if (col >= max_width) break;
                        self.grid.putCellGrid(cmdline_grid_id, @intCast(row_idx), col, '?', chunk.hl_id);
                        col += 1;
                    } else {
                        self.grid.putCellGrid(cmdline_grid_id, @intCast(row_idx), col, cp, chunk.hl_id);
                        col += 1;
                        // Add continuation cell for wide characters
                        if (isWideChar(cp)) {
                            if (col >= max_width) break;
                            self.grid.putCellGrid(cmdline_grid_id, @intCast(row_idx), col, 0, chunk.hl_id);
                            col += 1;
                        }
                    }
                }
            }
        }

        // Write current cmdline line (last row) with proper hl_ids
        if (current_line_visible) {
            if (current_state) |state| {
                var col: u32 = 0;

                // firstc (e.g. ':' '/' '?') - use hl_id 0 (default)
                if (state.firstc != 0) {
                    self.grid.putCellGrid(cmdline_grid_id, block_line_count, col, state.firstc, 0);
                    col += 1;
                }

                // prompt - use prompt_hl_id
                if (state.prompt.len > 0) {
                    var piter = std.unicode.Utf8View.initUnchecked(state.prompt).iterator();
                    while (piter.nextCodepoint()) |cp| {
                        if (col >= max_width) break;
                        self.grid.putCellGrid(cmdline_grid_id, block_line_count, col, cp, state.prompt_hl_id);
                        col += 1;
                        // Add continuation cell for wide characters
                        if (isWideChar(cp)) {
                            if (col >= max_width) break;
                            self.grid.putCellGrid(cmdline_grid_id, block_line_count, col, 0, state.prompt_hl_id);
                            col += 1;
                        }
                    }
                }

                // indent (spaces) - use hl_id 0
                var indent_i: u32 = 0;
                while (indent_i < state.indent and col < max_width) : (indent_i += 1) {
                    self.grid.putCellGrid(cmdline_grid_id, block_line_count, col, ' ', 0);
                    col += 1;
                }

                // content chunks - use each chunk's hl_id
                for (state.content.items) |chunk| {
                    var citer = std.unicode.Utf8View.initUnchecked(chunk.text).iterator();
                    while (citer.nextCodepoint()) |cp| {
                        if (col >= max_width) break;
                        if (cp < 0x20) {
                            // Control character: display as ^X with chunk's hl_id
                            self.grid.putCellGrid(cmdline_grid_id, block_line_count, col, '^', chunk.hl_id);
                            col += 1;
                            if (col >= max_width) break;
                            const ctrl_char: u32 = '@' + cp;
                            self.grid.putCellGrid(cmdline_grid_id, block_line_count, col, ctrl_char, chunk.hl_id);
                            col += 1;
                        } else if (cp == 0x7F) {
                            // DEL character: display as ^?
                            self.grid.putCellGrid(cmdline_grid_id, block_line_count, col, '^', chunk.hl_id);
                            col += 1;
                            if (col >= max_width) break;
                            self.grid.putCellGrid(cmdline_grid_id, block_line_count, col, '?', chunk.hl_id);
                            col += 1;
                        } else {
                            self.grid.putCellGrid(cmdline_grid_id, block_line_count, col, cp, chunk.hl_id);
                            col += 1;
                            // Add continuation cell for wide characters
                            if (isWideChar(cp)) {
                                if (col >= max_width) break;
                                self.grid.putCellGrid(cmdline_grid_id, block_line_count, col, 0, chunk.hl_id);
                                col += 1;
                            }
                        }
                    }
                }

                // special_char (shown at cursor position after Ctrl-V etc.)
                if (!current_has_control_chars) {
                    const special = state.getSpecialChar();
                    if (special.len > 0) {
                        var siter = std.unicode.Utf8View.initUnchecked(special).iterator();
                        while (siter.nextCodepoint()) |cp| {
                            if (col >= max_width) break;
                            self.grid.putCellGrid(cmdline_grid_id, block_line_count, col, cp, 0);
                            col += 1;
                            // Add continuation cell for wide characters
                            if (isWideChar(cp)) {
                                if (col >= max_width) break;
                                self.grid.putCellGrid(cmdline_grid_id, block_line_count, col, 0, 0);
                                col += 1;
                            }
                        }
                    }
                }
            }
        }

        // Mark as external grid
        _ = self.grid.setWinExternalPos(cmdline_grid_id, 0) catch |e| {
            self.log.write("[cmdline_block] setWinExternalPos failed: {any}\n", .{e});
            return;
        };

        // Set cursor position (on the last row - current cmdline line)
        self.grid.cursor_grid = cmdline_grid_id;
        self.grid.cursor_row = if (current_line_visible) block_line_count else block_line_count -| 1;
        self.grid.cursor_col = cursor_col;
        self.grid.cursor_valid = true;

        self.log.write("[cmdline_block] show: rows={d} cols={d} cursor_row={d} cursor_col={d}\n", .{ total_rows, max_width, self.grid.cursor_row, cursor_col });
    }

    /// Hide cmdline external window by removing from external grids
    fn sendCmdlineHide(self: *Core) void {
        const cmdline_grid_id = grid_mod.CMDLINE_GRID_ID;

        // Remove from external grids.
        // Note: Don't call on_external_window_close here - it will be called by
        // notifyExternalWindowChanges() which detects the grid was removed from
        // external_grids but still exists in known_external_grids.
        _ = self.grid.external_grids.fetchRemove(cmdline_grid_id);

        // Fallback: restore cursor to pre-cmdline position if Neovim doesn't send grid_cursor_goto
        // (This is a workaround for possible Neovim bug where cursor position isn't updated after cmdline closes)
        if (self.grid.cursor_grid == cmdline_grid_id and self.pre_cmdline_cursor_grid != cmdline_grid_id) {
            self.log.write("[cmdline] hide: restoring cursor to pre_cmdline: grid={d} row={d} col={d}\n", .{
                self.pre_cmdline_cursor_grid, self.pre_cmdline_cursor_row, self.pre_cmdline_cursor_col,
            });
            self.grid.cursor_grid = self.pre_cmdline_cursor_grid;
            self.grid.cursor_row = self.pre_cmdline_cursor_row;
            self.grid.cursor_col = self.pre_cmdline_cursor_col;
            self.grid.cursor_rev +%= 1;
        }

        self.log.write("[cmdline] hide\n", .{});
    }

    /// Handle popupmenu changes - creates/closes external window using grid (like cmdline).
    fn notifyPopupmenuChanges(self: *Core) void {
        if (!self.grid.popupmenu.changed) return;
        if (!self.ext_popupmenu_enabled) return;
        defer self.grid.clearPopupmenuChanged();

        // Verbose logging disabled for performance
        // self.log.write("[popupmenu] notifyPopupmenuChanges visible={} items={d}\n", .{
        //     self.grid.popupmenu.visible,
        //     self.grid.popupmenu.items.items.len,
        // });

        if (self.grid.popupmenu.visible) {
            self.sendPopupmenuShow();
        } else {
            self.sendPopupmenuHide();
        }
    }

    /// Notify frontend of tabline changes.
    fn notifyTablineChanges(self: *Core) void {
        if (!self.grid.tabline_state.dirty) return;
        if (!self.ext_tabline_enabled) return;
        defer self.grid.clearTablineDirty();

        const state = &self.grid.tabline_state;

        if (state.visible and state.tabs.items.len > 0) {
            // Build C-compatible tab array
            var c_tabs = std.ArrayListUnmanaged(c_api.TabEntry){};
            defer c_tabs.deinit(self.alloc);

            for (state.tabs.items) |tab| {
                c_tabs.append(self.alloc, .{
                    .tab_handle = tab.tab_handle,
                    .name = tab.name.ptr,
                    .name_len = tab.name.len,
                }) catch continue;
            }

            // Build C-compatible buffer array
            var c_buffers = std.ArrayListUnmanaged(c_api.BufferEntry){};
            defer c_buffers.deinit(self.alloc);

            for (state.buffers.items) |buf| {
                c_buffers.append(self.alloc, .{
                    .buffer_handle = buf.buffer_handle,
                    .name = buf.name.ptr,
                    .name_len = buf.name.len,
                }) catch continue;
            }

            if (self.cb.on_tabline_update) |cb| {
                cb(
                    self.ctx,
                    state.current_tab,
                    c_tabs.items.ptr,
                    c_tabs.items.len,
                    state.current_buffer,
                    c_buffers.items.ptr,
                    c_buffers.items.len,
                );
            }
        } else {
            if (self.cb.on_tabline_hide) |cb| {
                cb(self.ctx);
            }
        }
    }

    /// Show popupmenu as external window by creating a grid.
    fn sendPopupmenuShow(self: *Core) void {
        const pum_grid_id = grid_mod.POPUPMENU_GRID_ID;
        const items = self.grid.popupmenu.items.items;
        const selected = self.grid.popupmenu.selected;
        const anchor_row = self.grid.popupmenu.row;
        const anchor_col = self.grid.popupmenu.col;
        const anchor_grid = self.grid.popupmenu.grid_id;

        if (items.len == 0) return;

        self.log.write("[popupmenu] show: anchor_grid={d} anchor_row={d} anchor_col={d} items={d}\n", .{ anchor_grid, anchor_row, anchor_col, items.len });

        // Calculate dimensions
        var max_width: u32 = 10;
        for (items) |item| {
            const item_width = countDisplayWidth(item.word);
            if (item_width > max_width) max_width = item_width;
        }
        // Limit height to reasonable number
        const max_height: u32 = 15;
        const height: u32 = @intCast(@min(items.len, max_height));
        const width: u32 = max_width + 2; // +2 for padding

        // Calculate scroll offset to keep selected item visible
        const selected_u: usize = if (selected >= 0) @intCast(selected) else 0;
        var scroll_offset: usize = 0;
        if (selected_u >= height) {
            // Selected item is below visible range, scroll to show it at bottom
            scroll_offset = selected_u - height + 1;
        }
        const display_start = scroll_offset;
        const display_end = @min(scroll_offset + height, items.len);

        // Create or resize popupmenu grid
        self.grid.resizeGrid(pum_grid_id, height, width) catch |e| {
            self.log.write("[popupmenu] resizeGrid failed: {any}\n", .{e});
            return;
        };
        self.grid.clearGrid(pum_grid_id);

        // Write items to grid (with scroll offset)
        for (items[display_start..display_end], 0..) |item, row_idx| {
            const row: u32 = @intCast(row_idx);
            const item_idx = display_start + row_idx;
            // Use different hl_id for selected item (PmenuSel vs Pmenu)
            // Note: selected = -1 means no selection, so only compare when selected >= 0
            const is_selected = (selected >= 0) and (item_idx == selected_u);
            const hl_id: u32 = if (is_selected) 1 else 0; // TODO: proper highlight

            // Write item.word to grid with padding
            var col: u32 = 1; // Start with 1 cell padding
            var iter = std.unicode.Utf8View.initUnchecked(item.word).iterator();
            while (iter.nextCodepoint()) |cp| {
                if (col >= width - 1) break; // Leave 1 cell padding at end
                self.grid.putCellGrid(pum_grid_id, row, col, cp, hl_id);
                col += 1;
                // Handle wide characters
                if (isWideChar(cp)) {
                    if (col >= width - 1) break;
                    self.grid.putCellGrid(pum_grid_id, row, col, 0, hl_id);
                    col += 1;
                }
            }
        }

        // Register as external grid with position
        // For cmdline completion (grid_id < 0 or -1), use special positioning
        // For buffer completion, position 2 rows below anchor (1 for cursor line, 1 for spacing)
        const is_cmdline_completion = (anchor_grid < 0 or anchor_grid == -1);
        const start_row: i32 = if (is_cmdline_completion)
            -1 // Special marker for cmdline completion (Swift will position above cmdline)
        else
            anchor_row + 2; // 2 rows below: 1 for current line, 1 for spacing
        const start_col: i32 = anchor_col;

        self.grid.external_grids.put(self.alloc, pum_grid_id, .{
            .win = anchor_grid, // Store anchor grid ID for positioning
            .start_row = start_row,
            .start_col = start_col,
        }) catch |e| {
            self.log.write("[popupmenu] external_grids.put failed: {any}\n", .{e});
            return;
        };

        // Verbose logging disabled for performance
        // self.log.write("[popupmenu] show: size={d}x{d} pos=({d},{d})\n", .{width, height, start_row, start_col});
    }

    /// Hide popupmenu by removing from external grids.
    fn sendPopupmenuHide(self: *Core) void {
        const pum_grid_id = grid_mod.POPUPMENU_GRID_ID;

        // Remove from external grids.
        // Note: Don't call on_external_window_close here - it will be called by
        // notifyExternalWindowChanges() which detects the grid was removed from
        // external_grids but still exists in known_external_grids.
        _ = self.grid.external_grids.fetchRemove(pum_grid_id);

        self.log.write("[popupmenu] hide\n", .{});
    }

    // --- ext_messages support ---

    /// Check if msg_show throttle timeout has expired and process pending messages.
    /// Called from frontend tick (zonvie_core_tick_msg_throttle) to ensure messages are
    /// properly accumulated across multiple flush events before display (noice.nvim-style).
    /// This must NOT be called from onFlush, as Neovim may send multiple msg_show events
    /// across separate flush batches (e.g., list_cmd then shell_out for "!ls").
    pub fn checkMsgShowThrottleTimeout(self: *Core) void {
        if (!self.ext_messages_enabled) return;

        const pending_since = self.msg_show_pending_since orelse return;
        const now = std.time.nanoTimestamp();
        const elapsed = now - pending_since;

        if (elapsed >= self.msg_show_throttle_ns) {
            self.log.write("[msg] throttle timeout: {d}ms elapsed >= {d}ms, processing\n", .{
                @divTrunc(elapsed, std.time.ns_per_ms),
                @divTrunc(self.msg_show_throttle_ns, std.time.ns_per_ms),
            });
            self.sendMsgShow();
            self.grid.message_state.pending_count = 0;
            self.grid.message_state.msg_dirty = false;
            self.msg_show_pending_since = null;
        }
    }

    /// Handle message changes - notify frontend via callbacks.
    /// Uses throttle for msg_show (like noice.nvim) to accumulate messages before deciding view.
    fn notifyMessageChanges(self: *Core) void {
        if (!self.ext_messages_enabled) return;

        const msg_dirty = self.grid.message_state.msg_dirty;
        const showmode_dirty = self.grid.message_state.showmode_dirty;
        const showcmd_dirty = self.grid.message_state.showcmd_dirty;
        const ruler_dirty = self.grid.message_state.ruler_dirty;
        const history_dirty = self.grid.msg_history_state.dirty;

        // Also check if there's a pending throttle timeout to handle
        const has_pending_throttle = self.msg_show_pending_since != null;

        if (!msg_dirty and !showmode_dirty and !showcmd_dirty and !ruler_dirty and !history_dirty and !has_pending_throttle) return;

        // Note: We don't use defer for clearMessageDirty anymore because msg_dirty
        // should only be cleared after throttle period expires
        defer self.grid.clearMsgHistoryDirty();

        // Handle msg_show/msg_clear changes
        // Use throttle only for external command output (list_cmd, shell_out, shell_err)
        // to accumulate messages before deciding split view vs message window.
        // When return_prompt arrives, we must act immediately (like noice.nvim).
        if (msg_dirty) {
            const messages = self.grid.message_state.messages.items;
            if (messages.len == 0) {
                // msg_clear: hide immediately
                self.hideMsgShow();
                self.msg_show_pending_since = null;
            } else {
                // Check message types
                var has_shell_cmd = false;
                var has_return_prompt = false;
                for (messages) |m| {
                    // Only shell commands need throttle to accumulate output
                    // list_cmd (:ls, :version, etc.) should display immediately
                    if (std.mem.eql(u8, m.kind, "shell_out") or
                        std.mem.eql(u8, m.kind, "shell_err"))
                    {
                        has_shell_cmd = true;
                    }
                    if (std.mem.eql(u8, m.kind, "return_prompt")) {
                        has_return_prompt = true;
                    }
                }

                // Each event is processed independently.
                // auto_dismiss (CR sending) is handled inside sendMsgShow based on view type.
                if (has_shell_cmd and !has_return_prompt) {
                    // Shell command without return_prompt yet: use throttle to accumulate output
                    if (self.msg_show_pending_since == null) {
                        self.msg_show_pending_since = std.time.nanoTimestamp();
                    }
                } else {
                    // Other messages (including list_cmd): display immediately
                    self.sendMsgShow();
                    self.msg_show_pending_since = null;
                }
            }
        }

        self.grid.message_state.msg_dirty = false;
        self.grid.message_state.showmode_dirty = false;
        self.grid.message_state.showcmd_dirty = false;
        self.grid.message_state.ruler_dirty = false;

        // Handle showmode/showcmd/ruler changes only when their respective dirty flag is set
        if (showmode_dirty) {
            self.sendMsgShowmode();
        }
        if (showcmd_dirty) {
            self.sendMsgShowcmd();
        }
        if (ruler_dirty) {
            self.sendMsgRuler();
        }

        // Handle msg_history_show
        if (history_dirty) {
            self.sendMsgHistoryShow();
        }
    }

    /// Send msg_show as external grid (like popupmenu pattern).
    /// Confirm dialogs are sent via callback (special case for cmdline mode).
    fn sendMsgShow(self: *Core) void {
        const msg_grid_id = grid_mod.MESSAGE_GRID_ID;
        const messages = self.grid.message_state.messages.items;

        if (messages.len == 0) {
            // No messages - hide the message window and notify frontend (for confirm/prompt windows)
            _ = self.grid.external_grids.fetchRemove(msg_grid_id);
            self.log.write("[msg] sendMsgShow: hide (empty)\n", .{});
            // Call on_msg_clear to hide any native prompt windows (confirm dialogs)
            if (self.cb.on_msg_clear) |cb| {
                cb(self.ctx);
            }
            return;
        }

        // Count total lines across all messages (for min_lines/max_lines routing)
        var total_line_count: u32 = 0;
        for (messages) |m| {
            total_line_count += 1;
            for (m.content.items) |chunk| {
                for (chunk.text) |ch| {
                    if (ch == '\n') total_line_count += 1;
                }
            }
        }

        // Route each message individually and track which views are needed
        var has_ext_float = false;
        var has_split = false;
        var split_auto_dismiss = false;

        for (messages) |msg| {
            const chunks = msg.content.items;
            const route_result = self.msg_config.routeMessage(.msg_show, msg.kind, total_line_count);

            self.log.write("[msg] sendMsgShow: kind={s} lines={d} routed to view={s} timeout={d:.1}\n", .{
                msg.kind,
                total_line_count,
                @tagName(route_result.view),
                route_result.timeout,
            });

            switch (route_result.view) {
                .none => {
                    // Don't show this message
                },
                .mini => {
                    // Send to frontend callback for mini view display
                    self.log.write("[msg] sendMsgShow: view=mini, sending to callback\n", .{});
                    self.sendMsgShowCallback(msg, chunks, route_result.view, route_result.timeout);
                },
                .confirm => {
                    // Send to frontend callback for confirm view display (no timeout)
                    self.log.write("[msg] sendMsgShow: view=confirm, sending to callback\n", .{});
                    self.sendMsgShowCallback(msg, chunks, route_result.view, 0);
                },
                .notification => {
                    // Send to frontend callback for OS notification display (no timeout)
                    self.log.write("[msg] sendMsgShow: view=notification, sending to callback\n", .{});
                    self.sendMsgShowCallback(msg, chunks, route_result.view, 0);
                },
                .ext_float => {
                    has_ext_float = true;
                },
                .split => {
                    has_split = true;
                    if (route_result.auto_dismiss) split_auto_dismiss = true;
                },
            }
        }

        // Handle ext_float view (renders all ext_float-routed messages together)
        if (has_ext_float) {
            self.log.write("[msg] sendMsgShow: view=ext_float, rendering message grid\n", .{});
            self.buildMsgLineCache();
            self.msg_scroll_offset = 0;
            self.renderMsgGridFromCache(0);
        }

        // Handle split view (renders all split-routed messages together)
        if (has_split) {
            self.log.write("[msg] sendMsgShow: view=split (auto_dismiss={}), creating split window\n", .{split_auto_dismiss});

            // auto_dismiss: send <CR> to clear any pending prompt (e.g. return_prompt)
            if (split_auto_dismiss) {
                self.requestInput("<CR>") catch {};
            }

            // Clear any pending prompt windows on frontend
            if (self.cb.on_msg_clear) |cb| {
                cb(self.ctx);
            }

            // Build content string from split-routed messages only
            var content_buf: [8192]u8 = undefined;
            var content_len: usize = 0;
            var split_line_count: u32 = 0;
            for (messages) |m| {
                // Only include messages that route to split
                const route_result = self.msg_config.routeMessage(.msg_show, m.kind, total_line_count);
                if (route_result.view != .split) continue;

                for (m.content.items) |chunk| {
                    const copy_len = @min(chunk.text.len, content_buf.len - content_len);
                    @memcpy(content_buf[content_len..][0..copy_len], chunk.text[0..copy_len]);
                    content_len += copy_len;
                    if (content_len >= content_buf.len) break;
                    // Count lines
                    for (chunk.text[0..copy_len]) |ch| {
                        if (ch == '\n') split_line_count += 1;
                    }
                }
                // Add newline between messages
                if (content_len < content_buf.len - 1) {
                    content_buf[content_len] = '\n';
                    content_len += 1;
                    split_line_count += 1;
                }
            }
            self.createMessageSplit(content_buf[0..content_len], split_line_count, true, true, null) catch |e| {
                self.log.write("[msg] createMessageSplit failed: {any}\n", .{e});
            };
        }

        // If no ext_float messages, remove the message grid
        if (!has_ext_float) {
            _ = self.grid.external_grids.fetchRemove(msg_grid_id);
        }
    }

    /// Build line cache from current messages (called once when messages change).
    /// Only includes messages that route to ext_float view.
    fn buildMsgLineCache(self: *Core) void {
        const messages = self.grid.message_state.messages.items;

        // Clear existing cache
        self.msg_line_cache.clearRetainingCapacity();
        self.msg_cache_valid = false;
        self.msg_total_lines = 0;
        self.msg_cached_max_width = 10;

        if (messages.len == 0) return;

        var max_width: u32 = 10;

        for (messages) |m| {
            // Only include messages that route to ext_float
            const route_result = self.msg_config.routeMessage(.msg_show, m.kind, 1);
            if (route_result.view != .ext_float) continue;
            // Process all chunks, splitting on newlines
            var current_line: MsgCachedLine = .{};

            for (m.content.items) |chunk| {
                var remaining = chunk.text;
                while (remaining.len > 0) {
                    const nl_pos = std.mem.indexOfScalar(u8, remaining, '\n');

                    if (nl_pos) |pos| {
                        // Copy text before newline
                        const copy_len = @min(pos, current_line.data.len - current_line.len);
                        @memcpy(current_line.data[current_line.len..][0..copy_len], remaining[0..copy_len]);
                        current_line.len += @intCast(copy_len);

                        // Finish current line (skip leading empty lines)
                        if (current_line.len > 0 or self.msg_line_cache.items.len > 0) {
                            current_line.display_width = @intCast(countDisplayWidth(current_line.data[0..current_line.len]));
                            if (current_line.display_width > max_width) max_width = current_line.display_width;
                            self.msg_line_cache.append(self.alloc, current_line) catch break;
                        }
                        current_line = .{};
                        remaining = remaining[pos + 1 ..];
                    } else {
                        // No newline - copy rest to current line
                        const copy_len = @min(remaining.len, current_line.data.len - current_line.len);
                        @memcpy(current_line.data[current_line.len..][0..copy_len], remaining[0..copy_len]);
                        current_line.len += @intCast(copy_len);
                        break;
                    }
                }
            }

            // Finish last line of this message
            if (current_line.len > 0 or self.msg_line_cache.items.len == 0) {
                current_line.display_width = @intCast(countDisplayWidth(current_line.data[0..current_line.len]));
                if (current_line.display_width > max_width) max_width = current_line.display_width;
                self.msg_line_cache.append(self.alloc, current_line) catch {};
            }
        }

        self.msg_total_lines = @intCast(self.msg_line_cache.items.len);
        self.msg_cached_max_width = max_width;
        self.msg_cache_valid = true;

        self.log.write("[msg] buildMsgLineCache: {d} lines cached, max_width={d}\n", .{
            self.msg_line_cache.items.len,
            max_width,
        });
    }

    /// Render msg_show grid from cache (fast path for scrolling).
    fn renderMsgGridFromCache(self: *Core, scroll_offset: u32) void {
        const msg_grid_id = grid_mod.MESSAGE_GRID_ID;
        const lines = self.msg_line_cache.items;

        if (lines.len == 0) return;

        // Apply scroll offset (clamp to valid range)
        const actual_scroll: usize = @min(scroll_offset, if (lines.len > 0) lines.len - 1 else 0);

        // Calculate grid dimensions
        const max_height: u32 = @min(self.grid.rows, 256);
        const visible_lines = lines.len - actual_scroll;
        const height: u32 = @intCast(@min(visible_lines, max_height));
        const width: u32 = @min(self.msg_cached_max_width + 2, 80);

        self.log.write("[msg] renderMsgGridFromCache: lines={d} scroll={d} visible={d} size={d}x{d}\n", .{
            lines.len,
            actual_scroll,
            visible_lines,
            width,
            height,
        });

        // Create or resize grid
        self.grid.resizeGrid(msg_grid_id, height, width) catch |e| {
            self.log.write("[msg] resizeGrid failed: {any}\n", .{e});
            return;
        };
        self.grid.clearGrid(msg_grid_id);

        // Write lines to grid from cache
        for (0..height) |row_idx| {
            const source_line_idx = actual_scroll + row_idx;
            if (source_line_idx >= lines.len) break;

            const row: u32 = @intCast(row_idx);
            const cached_line = lines[source_line_idx];
            const line = cached_line.data[0..cached_line.len];

            var col: u32 = 1; // Start with 1 cell padding
            var iter = std.unicode.Utf8View.initUnchecked(line).iterator();
            while (iter.nextCodepoint()) |cp| {
                if (col >= width - 1) break;
                self.grid.putCellGrid(msg_grid_id, row, col, cp, 0);
                col += 1;
                if (isWideChar(cp)) {
                    if (col >= width - 1) break;
                    self.grid.putCellGrid(msg_grid_id, row, col, 0, 0);
                    col += 1;
                }
            }
        }

        // Register as external grid
        self.grid.external_grids.put(self.alloc, msg_grid_id, .{
            .win = 1, // Main grid
            .start_row = -2, // Special marker: position at top-right
            .start_col = -2,
        }) catch |e| {
            self.log.write("[msg] external_grids.put failed: {any}\n", .{e});
            return;
        };
    }

    /// Handle scroll event for msg_show grid (Zonvie's own grid).
    /// Updates scroll offset and re-renders grid content.
    fn handleMsgGridScroll(self: *Core, direction: []const u8) void {
        // Check if message grid is active
        if (!self.grid.external_grids.contains(grid_mod.MESSAGE_GRID_ID)) {
            self.log.write("[msg] handleMsgGridScroll: grid not active\n", .{});
            return;
        }

        const scroll_amount: u32 = 3; // Lines per scroll event
        var new_offset = self.msg_scroll_offset;

        if (std.mem.eql(u8, direction, "down")) {
            // Scroll down (show later content)
            const max_scroll = if (self.msg_total_lines > self.grid.rows)
                self.msg_total_lines - self.grid.rows
            else
                0;
            new_offset = @min(new_offset + scroll_amount, max_scroll);
        } else if (std.mem.eql(u8, direction, "up")) {
            // Scroll up (show earlier content)
            if (new_offset >= scroll_amount) {
                new_offset -= scroll_amount;
            } else {
                new_offset = 0;
            }
        }

        if (new_offset != self.msg_scroll_offset) {
            self.msg_scroll_offset = new_offset;

            // Throttle vertex updates to ~60fps (16ms)
            const now = std.time.nanoTimestamp();
            const throttle_ns: i128 = 16 * std.time.ns_per_ms;
            const elapsed = now - self.msg_scroll_last_send;

            if (elapsed >= throttle_ns) {
                self.log.write("[msg] handleMsgGridScroll: {s} offset {d} (send)\n", .{ direction, new_offset });
                self.renderMsgGridFromCache(new_offset);
                self.sendExternalGridVerticesFiltered(true, grid_mod.MESSAGE_GRID_ID);
                self.msg_scroll_last_send = now;
                self.msg_scroll_pending = false;
            } else {
                // Mark pending - will be processed on next throttle window or flush
                self.msg_scroll_pending = true;
            }
        }
    }

    /// Process pending scroll update (called from flush or timer).
    pub fn processPendingMsgScroll(self: *Core) void {
        if (!self.msg_scroll_pending) return;
        if (!self.grid.external_grids.contains(grid_mod.MESSAGE_GRID_ID)) return;

        self.log.write("[msg] processPendingMsgScroll: offset {d}\n", .{self.msg_scroll_offset});
        self.renderMsgGridFromCache(self.msg_scroll_offset);
        self.sendExternalGridVerticesFiltered(true, grid_mod.MESSAGE_GRID_ID);
        self.msg_scroll_last_send = std.time.nanoTimestamp();
        self.msg_scroll_pending = false;
    }

    /// Hide msg_show external grid.
    fn hideMsgShow(self: *Core) void {
        const msg_grid_id = grid_mod.MESSAGE_GRID_ID;
        _ = self.grid.external_grids.fetchRemove(msg_grid_id);
        // Reset scroll state and invalidate cache
        self.msg_scroll_offset = 0;
        self.msg_total_lines = 0;
        self.msg_cached_max_width = 0;
        self.msg_cache_valid = false;
        self.msg_line_cache.clearRetainingCapacity();
        self.log.write("[msg] hideMsgShow\n", .{});
        // Call on_msg_clear to hide any native prompt windows (confirm dialogs)
        if (self.cb.on_msg_clear) |cb| {
            cb(self.ctx);
        }
    }

    /// Send msg_show callback to frontend (helper for short messages or fallback).
    fn sendMsgShowCallback(self: *Core, msg: anytype, chunks: anytype, view: config.MsgViewType, timeout_sec: f32) void {
        const cb = self.cb.on_msg_show orelse return;

        // Build C ABI chunk array
        var c_chunks: [256]c_api.MsgChunk = undefined;
        const chunk_count = @min(chunks.len, c_chunks.len);

        for (chunks[0..chunk_count], 0..) |chunk, i| {
            c_chunks[i] = .{
                .hl_id = chunk.hl_id,
                .text = chunk.text.ptr,
                .text_len = chunk.text.len,
            };
        }

        // Convert view type to C ABI enum
        const c_view: c_api.zonvie_msg_view_type = switch (view) {
            .mini => .mini,
            .ext_float => .ext_float,
            .confirm => .confirm,
            .split => .split,
            .none => .none,
            .notification => .notification,
        };

        // Convert timeout from seconds to milliseconds
        const timeout_ms: u32 = if (timeout_sec > 0) @intFromFloat(timeout_sec * 1000.0) else 0;

        cb(
            self.ctx,
            c_view,
            msg.kind.ptr,
            msg.kind.len,
            &c_chunks,
            chunk_count,
            if (msg.replace_last) 1 else 0,
            if (msg.history) 1 else 0,
            if (msg.append) 1 else 0,
            msg.id,
            timeout_ms,
        );
    }

    /// Send all msg_history entries combined to frontend callback (for mini view).
    fn sendMsgHistoryCallbackAll(self: *Core, entries: []const grid_mod.MsgHistoryEntry, view: config.MsgViewType) void {
        const cb = self.cb.on_msg_show orelse return;

        // Build combined text from all entries
        var text_buf: [4096]u8 = undefined;
        var text_len: usize = 0;

        for (entries, 0..) |entry, entry_idx| {
            // Add newline between entries
            if (entry_idx > 0 and text_len < text_buf.len - 1) {
                text_buf[text_len] = '\n';
                text_len += 1;
            }

            for (entry.content.items) |chunk| {
                const copy_len = @min(chunk.text.len, text_buf.len - text_len);
                @memcpy(text_buf[text_len..][0..copy_len], chunk.text[0..copy_len]);
                text_len += copy_len;
                if (text_len >= text_buf.len) break;
            }
            if (text_len >= text_buf.len) break;
        }

        // Create single chunk with combined text
        var c_chunks: [1]c_api.MsgChunk = .{.{
            .hl_id = 0,
            .text = &text_buf,
            .text_len = text_len,
        }};

        // Convert view type to C ABI enum
        const c_view: c_api.zonvie_msg_view_type = switch (view) {
            .mini => .mini,
            .ext_float => .ext_float,
            .confirm => .confirm,
            .split => .split,
            .none => .none,
            .notification => .notification,
        };

        // Use special kind "_msg_history" to distinguish from regular msg_show
        const history_kind = "_msg_history";
        cb(
            self.ctx,
            c_view,
            history_kind.ptr,
            history_kind.len,
            &c_chunks,
            1, // chunk_count
            0, // replace_last
            0, // history (don't use this flag, use kind instead)
            0, // append
            0, // id
            0, // timeout_ms (no auto-hide for history)
        );
    }

    /// Send pending msg_show at index from snapshot (survives msg_clear).
    fn sendPendingMsgShowAt(self: *Core, index: usize) void {
        if (index >= self.grid.message_state.pending_count) return;
        const pm = &self.grid.message_state.pending_messages[index];
        if (pm.text_len == 0) return;

        // Count lines in pending message
        var line_count: u32 = 1;
        for (pm.text[0..pm.text_len]) |ch| {
            if (ch == '\n') line_count += 1;
        }

        self.log.write("[msg] sendPendingMsgShow[{d}] kind={s} text_len={d} lines={d}\n", .{
            index,
            pm.kind[0..pm.kind_len],
            pm.text_len,
            line_count,
        });

        // Check if this is a confirm dialog
        const kind = pm.kind[0..pm.kind_len];
        const is_confirm = std.mem.eql(u8, kind, "confirm") or
            std.mem.eql(u8, kind, "confirm_sub");

        // For confirm dialogs: always send to frontend callback (GUI message window).
        // Neovim split/float windows cannot be rendered during cmdline mode,
        // but the GUI's message window is a native window that can display anytime.
        // (This is similar to how noice.nvim displays confirm dialogs in its own popup)
        if (is_confirm) {
            self.log.write("[msg] sendPendingMsgShow: confirm dialog -> send to GUI callback\n", .{});
            self.sendPendingMsgShowCallback(pm);
            return;
        }

        // Send message to frontend via callback (routing handles view selection)
        self.sendPendingMsgShowCallback(pm);
    }

    /// Send pending message to frontend via callback.
    fn sendPendingMsgShowCallback(self: *Core, pm: *const grid_mod.PendingMessage) void {
        const cb = self.cb.on_msg_show orelse return;

        // Build single chunk from pending message
        var c_chunks: [1]c_api.MsgChunk = undefined;
        c_chunks[0] = .{
            .hl_id = pm.hl_id,
            .text = &pm.text,
            .text_len = pm.text_len,
        };

        // Route message to determine view type
        const kind = pm.kind[0..pm.kind_len];
        const route_result = self.msg_config.routeMessage(.msg_show, kind, 1);

        // Convert view type to C ABI enum
        const c_view: c_api.zonvie_msg_view_type = switch (route_result.view) {
            .mini => .mini,
            .ext_float => .ext_float,
            .confirm => .confirm,
            .split => .split,
            .none => .none,
            .notification => .notification,
        };

        cb(
            self.ctx,
            c_view,
            &pm.kind,
            pm.kind_len,
            &c_chunks,
            1,
            if (pm.replace_last) 1 else 0,
            if (pm.history) 1 else 0,
            if (pm.append) 1 else 0,
            pm.id,
        );
    }

    /// Send msg_clear callback to frontend and close any split view.
    fn sendMsgClear(self: *Core) void {
        self.log.write("[msg] sendMsgClear\n", .{});

        // Close any existing message split window
        self.closeMessageSplit();

        // Hide msg_show external grid
        self.hideMsgShow();

        // Hide msg_history external grid
        self.hideMsgHistory();

        // Call frontend callback
        if (self.cb.on_msg_clear) |cb| {
            cb(self.ctx);
        }
    }

    /// Close any existing message split window via Lua.
    fn closeMessageSplit(self: *Core) void {
        const lua_code =
            \\local state = _G._zonvie_msg_split
            \\if state and state.win and vim.api.nvim_win_is_valid(state.win) then
            \\  vim.api.nvim_win_close(state.win, true)
            \\end
            \\_G._zonvie_msg_split = nil
        ;
        self.requestExecLua(lua_code) catch |e| {
            self.log.write("[msg] closeMessageSplit failed: {any}\n", .{e});
        };
    }

    /// Send msg_showmode callback to frontend.
    fn sendMsgShowmode(self: *Core) void {
        const chunks = self.grid.message_state.showmode_content.items;

        // Route message using config
        const route_result = self.msg_config.routeMessage(.msg_showmode, "", 1);
        self.log.write("[msg] sendMsgShowmode chunks={d} routed to view={s}\n", .{ chunks.len, @tagName(route_result.view) });

        if (route_result.view == .none) return; // Don't show anything

        const cb = self.cb.on_msg_showmode orelse return;

        var c_chunks: [64]c_api.MsgChunk = undefined;
        const chunk_count = @min(chunks.len, c_chunks.len);

        for (chunks[0..chunk_count], 0..) |chunk, i| {
            c_chunks[i] = .{
                .hl_id = chunk.hl_id,
                .text = chunk.text.ptr,
                .text_len = chunk.text.len,
            };
        }

        // Convert view type to C ABI enum
        const c_view: c_api.zonvie_msg_view_type = switch (route_result.view) {
            .mini => .mini,
            .ext_float => .ext_float,
            .confirm => .confirm,
            .split => .split,
            .none => .none,
            .notification => .notification,
        };

        cb(self.ctx, c_view, &c_chunks, chunk_count);
    }

    /// Send msg_showcmd callback to frontend.
    fn sendMsgShowcmd(self: *Core) void {
        const chunks = self.grid.message_state.showcmd_content.items;

        // Route message using config
        const route_result = self.msg_config.routeMessage(.msg_showcmd, "", 1);
        self.log.write("[msg] sendMsgShowcmd chunks={d} routed to view={s}\n", .{ chunks.len, @tagName(route_result.view) });

        if (route_result.view == .none) return; // Don't show anything

        const cb = self.cb.on_msg_showcmd orelse return;

        var c_chunks: [64]c_api.MsgChunk = undefined;
        const chunk_count = @min(chunks.len, c_chunks.len);

        for (chunks[0..chunk_count], 0..) |chunk, i| {
            c_chunks[i] = .{
                .hl_id = chunk.hl_id,
                .text = chunk.text.ptr,
                .text_len = chunk.text.len,
            };
        }

        // Convert view type to C ABI enum
        const c_view: c_api.zonvie_msg_view_type = switch (route_result.view) {
            .mini => .mini,
            .ext_float => .ext_float,
            .confirm => .confirm,
            .split => .split,
            .none => .none,
            .notification => .notification,
        };

        cb(self.ctx, c_view, &c_chunks, chunk_count);
    }

    /// Send msg_ruler callback to frontend.
    fn sendMsgRuler(self: *Core) void {
        const chunks = self.grid.message_state.ruler_content.items;

        // Route message using config
        const route_result = self.msg_config.routeMessage(.msg_ruler, "", 1);
        self.log.write("[msg] sendMsgRuler chunks={d} routed to view={s}\n", .{ chunks.len, @tagName(route_result.view) });

        if (route_result.view == .none) return; // Don't show anything

        const cb = self.cb.on_msg_ruler orelse return;

        var c_chunks: [64]c_api.MsgChunk = undefined;
        const chunk_count = @min(chunks.len, c_chunks.len);

        for (chunks[0..chunk_count], 0..) |chunk, i| {
            c_chunks[i] = .{
                .hl_id = chunk.hl_id,
                .text = chunk.text.ptr,
                .text_len = chunk.text.len,
            };
        }

        // Convert view type to C ABI enum
        const c_view: c_api.zonvie_msg_view_type = switch (route_result.view) {
            .mini => .mini,
            .ext_float => .ext_float,
            .confirm => .confirm,
            .split => .split,
            .none => .none,
            .notification => .notification,
        };

        cb(self.ctx, c_view, &c_chunks, chunk_count);
    }

    /// Show msg_history as external grid (like popupmenu pattern).
    fn sendMsgHistoryShow(self: *Core) void {
        const history_grid_id = grid_mod.MSG_HISTORY_GRID_ID;
        const entries = self.grid.msg_history_state.entries.items;

        if (entries.len == 0) {
            // No entries - hide the history window if visible
            _ = self.grid.external_grids.fetchRemove(history_grid_id);
            self.log.write("[msg_history] hide (empty)\n", .{});
            return;
        }

        // Route message using config (use entry count as line count)
        const route_result = self.msg_config.routeMessage(.msg_history_show, "", @intCast(entries.len));
        self.log.write("[msg_history] entries={d} routed to view={s}\n", .{ entries.len, @tagName(route_result.view) });

        // Handle based on routing result
        switch (route_result.view) {
            .none => {
                // Don't show anything
                _ = self.grid.external_grids.fetchRemove(history_grid_id);
                self.log.write("[msg_history] view=none, hiding\n", .{});
                return;
            },
            .mini => {
                // Mini view: send all entries combined to frontend callback
                self.log.write("[msg_history] view=mini, sending {d} entries to callback\n", .{entries.len});
                self.sendMsgHistoryCallbackAll(entries, route_result.view);
                return;
            },
            .notification => {
                // Notification view: send all entries combined to frontend callback for OS notification
                self.log.write("[msg_history] view=notification, sending {d} entries to callback\n", .{entries.len});
                self.sendMsgHistoryCallbackAll(entries, route_result.view);
                return;
            },
            .split => {
                // Split view: create Neovim split window
                self.log.write("[msg_history] view=split (auto_dismiss={}), creating split window\n", .{route_result.auto_dismiss});

                // auto_dismiss: send <CR> to clear any pending prompt (e.g. return_prompt)
                // This allows split view to display without user pressing Enter
                if (route_result.auto_dismiss) {
                    self.requestInput("<CR>") catch {};
                }

                // Clear any pending prompt windows on frontend
                if (self.cb.on_msg_clear) |cb| {
                    cb(self.ctx);
                }

                // Build content string from all entries
                var content_buf: [8192]u8 = undefined;
                var content_len: usize = 0;
                for (entries) |entry| {
                    for (entry.content.items) |chunk| {
                        const copy_len = @min(chunk.text.len, content_buf.len - content_len);
                        @memcpy(content_buf[content_len..][0..copy_len], chunk.text[0..copy_len]);
                        content_len += copy_len;
                        if (content_len >= content_buf.len) break;
                    }
                    // Add newline between entries
                    if (content_len < content_buf.len - 1) {
                        content_buf[content_len] = '\n';
                        content_len += 1;
                    }
                }
                self.createMessageSplit(content_buf[0..content_len], @intCast(entries.len), true, true, null) catch |e| {
                    self.log.write("[msg_history] createMessageSplit failed: {any}\n", .{e});
                };
                return;
            },
            else => {
                // Continue to external grid rendering below (ext_float, confirm)
            },
        }

        // Build content lines from entries
        var lines: [256][256]u8 = undefined;
        var line_lens: [256]usize = undefined;
        var line_count: usize = 0;
        var max_width: u32 = 20;

        for (entries) |entry| {
            if (line_count >= lines.len) break;

            // Combine all chunks into one line
            var line_len: usize = 0;
            for (entry.content.items) |chunk| {
                const copy_len = @min(chunk.text.len, lines[line_count].len - line_len);
                @memcpy(lines[line_count][line_len..][0..copy_len], chunk.text[0..copy_len]);
                line_len += copy_len;
                if (line_len >= lines[line_count].len) break;
            }
            line_lens[line_count] = line_len;

            // Track max width
            const display_width = countDisplayWidth(lines[line_count][0..line_len]);
            if (display_width > max_width) max_width = display_width;

            line_count += 1;
        }

        if (line_count == 0) return;

        // Calculate grid dimensions
        const max_height: u32 = 20;
        const height: u32 = @intCast(@min(line_count, max_height));
        const width: u32 = @min(max_width + 2, 80); // +2 for padding, max 80

        self.log.write("[msg_history] show: entries={d} size={d}x{d}\n", .{ entries.len, width, height });

        // Create or resize grid
        self.grid.resizeGrid(history_grid_id, height, width) catch |e| {
            self.log.write("[msg_history] resizeGrid failed: {any}\n", .{e});
            return;
        };
        self.grid.clearGrid(history_grid_id);

        // Write lines to grid
        for (0..height) |row_idx| {
            const row: u32 = @intCast(row_idx);
            const line = lines[row_idx][0..line_lens[row_idx]];

            var col: u32 = 1; // Start with 1 cell padding
            var iter = std.unicode.Utf8View.initUnchecked(line).iterator();
            while (iter.nextCodepoint()) |cp| {
                if (col >= width - 1) break;
                self.grid.putCellGrid(history_grid_id, row, col, cp, 0);
                col += 1;
                if (isWideChar(cp)) {
                    if (col >= width - 1) break;
                    self.grid.putCellGrid(history_grid_id, row, col, 0, 0);
                    col += 1;
                }
            }
        }

        // Register as external grid
        // Position: use special marker -2 to indicate "msg_show position" (top-right)
        // Frontend will interpret this and position like msg_show
        self.grid.external_grids.put(self.alloc, history_grid_id, .{
            .win = 1, // Main grid
            .start_row = -2, // Special marker: position like msg_show (top-right)
            .start_col = -2,
        }) catch |e| {
            self.log.write("[msg_history] external_grids.put failed: {any}\n", .{e});
            return;
        };
    }

    /// Hide msg_history external grid.
    fn hideMsgHistory(self: *Core) void {
        const history_grid_id = grid_mod.MSG_HISTORY_GRID_ID;
        _ = self.grid.external_grids.fetchRemove(history_grid_id);
        self.log.write("[msg_history] hide\n", .{});
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
    fn countUtf8Codepoints(s: []const u8) u32 {
        var count: u32 = 0;
        var iter = std.unicode.Utf8View.initUnchecked(s).iterator();
        while (iter.nextCodepoint()) |_| {
            count += 1;
        }
        return count;
    }

    /// Check if a codepoint is a wide (double-width) character.
    /// Based on East Asian Width (simplified version for CJK).
    fn isWideChar(cp: u32) bool {
        // Hangul Jamo
        if (cp >= 0x1100 and cp <= 0x115F) return true;
        // CJK Radicals, Kangxi, Ideographic, Hiragana, Katakana, Bopomofo, Hangul Compat, Kanbun, etc.
        if (cp >= 0x2E80 and cp <= 0x4DBF) return true;
        // CJK Unified Ideographs
        if (cp >= 0x4E00 and cp <= 0x9FFF) return true;
        // Yi Syllables, Yi Radicals, Lisu, Vai, Hangul Syllables
        if (cp >= 0xA000 and cp <= 0xD7FF) return true;
        // CJK Compatibility Ideographs
        if (cp >= 0xF900 and cp <= 0xFAFF) return true;
        // Vertical Forms, CJK Compatibility Forms
        if (cp >= 0xFE10 and cp <= 0xFE6F) return true;
        // Halfwidth and Fullwidth Forms (fullwidth part)
        if (cp >= 0xFF00 and cp <= 0xFF60) return true;
        if (cp >= 0xFFE0 and cp <= 0xFFE6) return true;
        // CJK Unified Ideographs Extension B and beyond
        if (cp >= 0x20000 and cp <= 0x3FFFF) return true;
        return false;
    }

    /// Count display width accounting for control characters (^X notation) and wide characters.
    /// Control characters (0x00-0x1F) and DEL (0x7F) take 2 columns.
    /// Wide characters (CJK, etc.) take 2 columns.
    fn countDisplayWidth(s: []const u8) u32 {
        var count: u32 = 0;
        var iter = std.unicode.Utf8View.initUnchecked(s).iterator();
        while (iter.nextCodepoint()) |cp| {
            if (cp < 0x20 or cp == 0x7F) {
                count += 2; // ^X notation takes 2 columns
            } else if (isWideChar(cp)) {
                count += 2; // Wide character takes 2 columns
            } else {
                count += 1;
            }
        }
        return count;
    }

    fn runLoop(self: *Core) void {
        // DEBUG: Log immediately at runLoop start
        if (self.cb.on_log) |logfn| {
            const msg = "[RUNLOOP] runLoop started!\n";
            logfn(self.ctx, msg.ptr, msg.len);
        }

        const nvim_path = self.nvim_path_owned orelse "nvim";

        // Check if this is a WSL or SSH command
        // WSL command format: "wsl.exe [-d distro] --shell-type login -- nvim --embed"
        // SSH command format: "ssh [-p port] [-i identity] user@host ..." or full path like "C:\...\ssh.exe ..."
        // SSH-ASKPASS format: "ssh-askpass ..." - SSH_ASKPASS already handled auth, skip waiting
        // CMD format: "cmd.exe /c ssh ..." - used on Windows to run SSH via shell
        // Shell format: "/bin/sh -c ..." - used for complex commands (e.g., devcontainer up && exec)
        const is_wsl = std.mem.startsWith(u8, nvim_path, "wsl");
        const is_ssh_askpass = std.mem.startsWith(u8, nvim_path, "ssh-askpass");
        const is_cmd = std.mem.startsWith(u8, nvim_path, "cmd");
        const is_shell = std.mem.startsWith(u8, nvim_path, "/bin/sh") or std.mem.startsWith(u8, nvim_path, "/bin/bash");
        // Check for devcontainer: "devcontainer exec ..." or "devcontainer.cmd exec ..."
        const is_devcontainer = std.mem.startsWith(u8, nvim_path, "devcontainer");
        // Check for SSH: starts with "ssh", contains "ssh.exe", or cmd.exe with ssh
        const contains_ssh_exe = std.mem.indexOf(u8, nvim_path, "ssh.exe") != null;
        const is_ssh = (std.mem.startsWith(u8, nvim_path, "ssh") and !is_ssh_askpass) or
            contains_ssh_exe or
            (is_cmd and std.mem.indexOf(u8, nvim_path, "ssh") != null);

        // Buffer for parsed arguments
        var argv_buf: [16][]const u8 = undefined;
        var argc: usize = 0;

        if (is_wsl or is_ssh or is_ssh_askpass or is_cmd or is_devcontainer or is_shell) {
            // Parse command string into arguments (split by spaces, handle quotes and escapes)
            var i: usize = 0;
            while (i < nvim_path.len and argc < argv_buf.len) {
                // Skip leading spaces
                while (i < nvim_path.len and nvim_path[i] == ' ') : (i += 1) {}
                if (i >= nvim_path.len) break;

                var arg_start = i;
                var arg_end = i;

                if (nvim_path[i] == '\'' or nvim_path[i] == '"') {
                    // Quoted argument - find closing quote (handle escaped quotes)
                    const quote_char = nvim_path[i];
                    i += 1;
                    arg_start = i;
                    while (i < nvim_path.len) {
                        if (nvim_path[i] == '\\' and i + 1 < nvim_path.len and nvim_path[i + 1] == quote_char) {
                            // Skip escaped quote (e.g., \" inside "..." or \' inside '...')
                            i += 2;
                        } else if (nvim_path[i] == quote_char) {
                            // Found unescaped closing quote
                            break;
                        } else {
                            i += 1;
                        }
                    }
                    arg_end = i;
                    if (i < nvim_path.len) i += 1; // Skip closing quote
                } else {
                    // Unquoted argument - find next space
                    while (i < nvim_path.len and nvim_path[i] != ' ') : (i += 1) {}
                    arg_end = i;
                }

                if (arg_end > arg_start) {
                    const part = nvim_path[arg_start..arg_end];
                    // Skip "ssh-askpass" prefix - actual ssh command is next argument
                    if (argc == 0 and is_ssh_askpass and std.mem.eql(u8, part, "ssh-askpass")) {
                        // Don't add to argv, just continue to next argument
                        continue;
                    }
                    argv_buf[argc] = part;
                    argc += 1;
                }
            }
            if (is_wsl) {
                self.log.write("WSL mode: parsed {d} arguments\n", .{argc});
            } else if (is_ssh_askpass) {
                self.log.write("SSH-ASKPASS mode: parsed {d} arguments (auth already done)\n", .{argc});
                // Don't set is_ssh_mode - auth is already handled by SSH_ASKPASS
            } else if (is_devcontainer) {
                self.log.write("devcontainer mode: parsed {d} arguments\n", .{argc});
                // Don't set is_ssh_mode - devcontainer doesn't need SSH auth
            } else if (is_shell) {
                self.log.write("shell mode: parsed {d} arguments\n", .{argc});
                // Don't set is_ssh_mode - shell command handles its own execution
            } else {
                self.log.write("SSH mode: parsed {d} arguments\n", .{argc});
                self.is_ssh_mode = true;
            }
        } else {
            // Native: parse command string and insert --embed after first argument
            // e.g., "nvim file.txt" → ["nvim", "--embed", "file.txt"]
            // e.g., "nvim -u /tmp/init.lua +10 file.txt" → ["nvim", "--embed", "-u", "/tmp/init.lua", "+10", "file.txt"]
            var i: usize = 0;
            while (i < nvim_path.len and argc < argv_buf.len - 1) { // -1 to leave room for --embed
                // Skip leading spaces
                while (i < nvim_path.len and nvim_path[i] == ' ') : (i += 1) {}
                if (i >= nvim_path.len) break;

                var arg_start = i;
                var arg_end = i;

                if (nvim_path[i] == '\'' or nvim_path[i] == '"') {
                    // Quoted argument - find closing quote (handle escaped quotes)
                    const quote_char = nvim_path[i];
                    i += 1;
                    arg_start = i;
                    while (i < nvim_path.len) {
                        if (nvim_path[i] == '\\' and i + 1 < nvim_path.len and nvim_path[i + 1] == quote_char) {
                            // Skip escaped quote
                            i += 2;
                        } else if (nvim_path[i] == quote_char) {
                            // Found unescaped closing quote
                            break;
                        } else {
                            i += 1;
                        }
                    }
                    arg_end = i;
                    if (i < nvim_path.len) i += 1; // Skip closing quote
                } else {
                    // Unquoted argument - find next space
                    while (i < nvim_path.len and nvim_path[i] != ' ') : (i += 1) {}
                    arg_end = i;
                }

                if (arg_end > arg_start) {
                    argv_buf[argc] = nvim_path[arg_start..arg_end];
                    argc += 1;

                    // Insert --embed after first argument (nvim executable)
                    if (argc == 1) {
                        argv_buf[argc] = "--embed";
                        argc += 1;
                    }
                }
            }

            // If no arguments parsed, fall back to simple path + --embed
            if (argc == 0) {
                argv_buf[0] = nvim_path;
                argv_buf[1] = "--embed";
                argc = 2;
            }

            self.log.write("Native mode: parsed {d} arguments\n", .{argc});
        }

        self.log.write("spawning nvim: {s}\n", .{nvim_path});
        for (argv_buf[0..argc]) |arg| {
            self.log.write("  arg: {s}\n", .{arg});
        }
        self.log.write("[MARKER] before logEnvHints\n", .{});
        logEnvHints(self);
        self.log.write("[MARKER] after logEnvHints\n", .{});

        var child = std.process.Child.init(argv_buf[0..argc], self.alloc);
        child.stdin_behavior = .Pipe;
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Pipe;
        child.create_no_window = true;

        var cwd_owner: CwdOwner = .{};
        defer cwd_owner.close();
        if (!self.inherit_cwd) {
            cwd_owner.openPreferred(self.alloc, &self.log);
            cwd_owner.applyToChild(&child);
        } else {
            self.log.write("inherit_cwd=true; child inherits parent cwd\n", .{});
        }

        // Check for path separators - both '/' (Unix) and '\' (Windows)
        const has_slash = (std.mem.indexOfScalar(u8, nvim_path, '/') != null) or
            (std.mem.indexOfScalar(u8, nvim_path, '\\') != null);
        if (@hasField(@TypeOf(child), "expand_arg0")) {
            child.expand_arg0 = if (has_slash) .no_expand else .expand;
        }
        self.log.write("expand_arg0: has_slash={}, mode={s}\n", .{ has_slash, if (has_slash) "no_expand" else "expand" });

        self.log.write("about to spawn...\n", .{});
        // Direct callback log before spawn
        if (self.cb.on_log) |logfn| {
            const msg1 = "[DIRECT] calling child.spawn() now\n";
            logfn(self.ctx, msg1.ptr, msg1.len);
        }
        const spawn_start_ns = std.time.nanoTimestamp();
        child.spawn() catch |e| {
            self.log.write("spawn failed: {any}\n", .{e});
            if (self.cb.on_log) |logfn| {
                const msg_err = "[DIRECT] spawn error occurred\n";
                logfn(self.ctx, msg_err.ptr, msg_err.len);
            }
            return;
        };
        const spawn_end_ns = std.time.nanoTimestamp();
        const spawn_ms = @divTrunc(spawn_end_ns - spawn_start_ns, 1_000_000);
        // Direct callback log after spawn
        if (self.cb.on_log) |logfn| {
            const msg2 = "[DIRECT] child.spawn() returned successfully\n";
            logfn(self.ctx, msg2.ptr, msg2.len);
        }
        self.log.write("[TIMING] nvim spawn: {d}ms\n", .{spawn_ms});
        self.log.write("spawn returned ok, pid={any}\n", .{child.id});

        // Note: Don't try to read stderr here - it blocks if no data available

        self.child_handle = child.id;
        self.stdin_file = child.stdin;
        self.stdout_file = child.stdout;
        self.stderr_file = child.stderr;

        // OWNERSHIP TRANSFER:
        // We keep the pipe handles in Core, so prevent std.process.Child from closing them.
        child.stdin = null;
        child.stdout = null;
        child.stderr = null;

        if (self.stderr_file) |ef| {
            self.stderr_thread = std.Thread.spawn(.{}, pumpStderr, .{ self, ef }) catch null;
        }

        // SSH mode: prompt for password immediately after process start
        // With -tt option, password prompt goes to TTY (not visible via pipes)
        // So we show dialog immediately and wait for user to enter password
        if (self.is_ssh_mode) {
            self.log.write("SSH mode: prompting for password immediately...\n", .{});

            // Set pending flag to block other stdin writes (RPC sends)
            self.ssh_auth_pending.store(true, .seq_cst);

            // Small delay to let SSH start
            std.Thread.sleep(200 * std.time.ns_per_ms);

            // Call callback to show password dialog
            if (self.cb.on_ssh_auth_prompt) |cb| {
                cb(self.ctx, "SSH Password:", 13);

                // Wait for password to be sent (ssh_auth_done flag)
                self.log.write("SSH mode: waiting for user to enter password...\n", .{});
                var waited_ms: u32 = 0;
                const timeout_ms: u32 = 60000; // 60 seconds
                const poll_ms: u32 = 100;

                while (waited_ms < timeout_ms and !self.stop_flag.load(.seq_cst)) {
                    if (self.ssh_auth_done.load(.seq_cst)) {
                        self.log.write("SSH mode: password sent, waiting for connection...\n", .{});
                        // Give SSH time to authenticate
                        std.Thread.sleep(2000 * std.time.ns_per_ms);
                        break;
                    }
                    std.Thread.sleep(poll_ms * std.time.ns_per_ms);
                    waited_ms += poll_ms;
                }

                if (waited_ms >= timeout_ms) {
                    self.log.write("SSH mode: authentication timeout\n", .{});
                }
            } else {
                self.log.write("SSH mode: no callback registered\n", .{});
            }

            // Clear pending flag
            self.ssh_auth_pending.store(false, .seq_cst);

            if (self.stop_flag.load(.seq_cst)) {
                self.log.write("SSH mode: stopped by user\n", .{});
                return;
            }
        }

        var ui_attached = false;

        self.requestGetApiInfo() catch |e| self.log.write("send get_api_info failed: {any}\n", .{e});
        self.requestSetClientInfo() catch |e| self.log.write("send set_client_info failed: {any}\n", .{e});
        self.requestUiAttach(self.init_rows, self.init_cols) catch |e| {
            self.log.write("ui_attach send failed: {any}\n", .{e});
            _ = child.kill() catch {};
            _ = child.wait() catch {};
            return;
        };
        ui_attached = true;
        self.requestTryResize(self.init_rows, self.init_cols) catch |e| self.log.write("try_resize send failed: {any}\n", .{e});
        self.requestCommand("redraw!") catch |e| self.log.write("redraw! send failed: {any}\n", .{e});

        if (self.pending_resize_valid) {
            const pr = self.pending_resize_rows;
            const pc = self.pending_resize_cols;
            var pending_sent = true;
            self.requestTryResize(pr, pc) catch |e| {
                self.log.write("pending resize send failed: {any}\n", .{e});
                pending_sent = false;
            };
            if (pending_sent) {
                self.pending_resize_valid = false;
                self.log.write("pending resize sent rows={d} cols={d}\n", .{ pr, pc });
            }
        }

        if (self.stdout_file == null) {
            self.log.write("stdout pipe is null\n", .{});
            _ = child.kill() catch {};
            _ = child.wait() catch {};
            return;
        }
        var pr = PipeReader{ .file = self.stdout_file.? };

        while (!self.stop_flag.load(.seq_cst)) {
            var arena_state = std.heap.ArenaAllocator.init(self.alloc);
            defer arena_state.deinit();
            const arena = arena_state.allocator();

            const root = mp.decode(arena, &pr) catch |e| {
                if (e == error.EndOfStream) {
                    self.log.write("decode err: EndOfStream (nvim stdout closed)\n", .{});
                } else {
                    self.log.write("decode err: {any}\n", .{e});
                }
                break;
            };

            if (root != .arr or root.arr.len < 1) continue;
            const top = root.arr;
            if (top[0] != .int) continue;

            const t = top[0].int;
            if (t == 0) {
                // RPC request from Neovim (e.g., clipboard operations)
                self.handleRpcRequest(arena, top);
                continue;
            }
            if (t == 1) {
                // RPC response (e.g., nvim_get_api_info result)
                self.handleRpcResponse(top);
                continue;
            }
            if (t == 2) {
                self.handleRpcNotification(arena, top);
                continue;
            }
        }

        if (self.stop_flag.load(.seq_cst)) {
            _ = child.kill() catch {};
        }

        const term = child.wait() catch |e| {
            self.log.write("wait err: {any}\n", .{e});
            return;
        };
        self.log.write("nvim terminated: {any}\n", .{term});
        self.child_handle = null;


        self.log.write("nvim terminated: {any}\n", .{term});
        self.child_handle = null;

        // If nvim exited by itself (e.g. :q), notify the frontend.
        // When stop() is requested by the app side, stop_flag is set and we should not trigger on_exit.
        if (!self.stop_flag.load(.seq_cst) and ui_attached) {
            if (self.cb.on_exit) |f| {
                // Convert Term to exit code:
                // - Exited: use exit code directly
                // - Signal: 128 + signal number (Unix convention)
                // - Stopped/Unknown: return 1 (generic error)
                const exit_code: i32 = switch (term) {
                    .Exited => |code| @intCast(code),
                    .Signal => |sig| 128 + @as(i32, @intCast(sig)),
                    .Stopped, .Unknown => 1,
                };
                self.log.write("calling on_exit with code: {d}\n", .{exit_code});
                f(self.ctx, exit_code);
            }
        }
    }
};
