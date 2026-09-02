const std = @import("std");
const build_options = @import("build_options");
const core = @import("nvim_core.zig");
pub const config = @import("config.zig");
const shader_compiler = @import("shader_compiler.zig");
const rpc_transport = @import("rpc_transport.zig");

threadlocal var current_mode_snapshot: [16]u8 = [_]u8{0} ** 16;

// Process-wide std.Io provider (Zig 0.16). Re-exported so frontend and test
// code that imports the core package can reach the shared Io and clock.
pub const clock = @import("clock.zig");

// Re-exports for test access
pub const nvim_core = core;
pub const grid_mod = @import("grid.zig");
pub const flush_mod = @import("flush.zig");
pub const msgpack = @import("msgpack.zig");
pub const rpc_encode = @import("rpc_encode.zig");
pub const redraw_handler = @import("redraw_handler.zig");
pub const highlight = @import("highlight.zig");
pub const log_mod = @import("log.zig");

pub const CursorShape = enum(u32) {
    block = 0,
    vertical = 1,
    horizontal = 2,
};

pub const Cursor = extern struct {
    enabled: u32,
    row: u32,
    col: u32,
    shape: CursorShape,
    cell_percentage: u32,
    fgRGB: u32,
    bgRGB: u32,
    blink_wait_ms: u32, // wait time before blink starts (ms), 0=no blink
    blink_on_ms: u32, // on time for blink cycle (ms)
    blink_off_ms: u32, // off time for blink cycle (ms)
};

// Decoration flags (must match ZONVIE_DECO_* in zonvie_core.h)
pub const DECO_UNDERCURL: u32 = 1 << 0;
pub const DECO_UNDERLINE: u32 = 1 << 1;
pub const DECO_UNDERDOUBLE: u32 = 1 << 2;
pub const DECO_UNDERDOTTED: u32 = 1 << 3;
pub const DECO_UNDERDASHED: u32 = 1 << 4;
pub const DECO_STRIKETHROUGH: u32 = 1 << 5;
pub const DECO_CURSOR: u32 = 1 << 6; // Marker for cursor vertices (not a decoration, used to preserve cursor from transparency)
pub const DECO_SCROLLABLE: u32 = 1 << 7; // Vertex is in scrollable content area (not margin)
pub const DECO_OVERLINE: u32 = 1 << 8;
pub const DECO_GLOW: u32 = 1 << 9;
pub const DECO_COLOR_EMOJI: u32 = 1 << 10; // Color glyph (emoji): sample RGBA, not coverage
// Solid-color quad that is foreground text: block elements filled
// geometrically rather than rasterized. Tells the frontend not to treat them
// as background, which would fade them under a translucent/blurred window.
pub const DECO_SOLID_GLYPH: u32 = 1 << 11;

pub const Vertex = extern struct {
    position: [2]f32,
    texCoord: [2]f32,
    color: [4]f32 align(16), // 16-byte alignment to match Swift simd_float4
    grid_id: i64, // 1 = global grid, >1 = sub-grid (float window)
    deco_flags: u32, // DECO_* flags for decoration type
    deco_phase: f32, // phase offset for undercurl (cell column position)

    // Verify struct layout matches C ABI expectations:
    // - position:   8 bytes @ offset 0
    // - texCoord:   8 bytes @ offset 8
    // - color:      16 bytes @ offset 16 (aligned to 16)
    // - grid_id:    8 bytes @ offset 32
    // - deco_flags: 4 bytes @ offset 40
    // - deco_phase: 4 bytes @ offset 44
    // - Total: 48 bytes
    comptime {
        if (@sizeOf(Vertex) != 48) {
            @compileError("Vertex struct size mismatch! Expected 48 bytes.");
        }
        if (@alignOf(Vertex) != 16) {
            @compileError("Vertex struct alignment mismatch! Expected 16-byte alignment.");
        }
        if (@offsetOf(Vertex, "position") != 0) {
            @compileError("Vertex.position offset mismatch! Expected 0.");
        }
        if (@offsetOf(Vertex, "texCoord") != 8) {
            @compileError("Vertex.texCoord offset mismatch! Expected 8.");
        }
        if (@offsetOf(Vertex, "color") != 16) {
            @compileError("Vertex.color offset mismatch! Expected 16.");
        }
        if (@offsetOf(Vertex, "grid_id") != 32) {
            @compileError("Vertex.grid_id offset mismatch! Expected 32.");
        }
        if (@offsetOf(Vertex, "deco_flags") != 40) {
            @compileError("Vertex.deco_flags offset mismatch! Expected 40.");
        }
        if (@offsetOf(Vertex, "deco_phase") != 44) {
            @compileError("Vertex.deco_phase offset mismatch! Expected 44.");
        }
    }
};

pub const GlyphEntry = extern struct {
    uv_min: [2]f32,
    uv_max: [2]f32,
    bbox_origin_px: [2]f32,
    bbox_size_px: [2]f32,
    advance_px: f32,
    ascent_px: f32,
    descent_px: f32,
    bytes_per_pixel: u32 = 1, // 1=grayscale, 3=ClearType RGB, 4=RGBA color (emoji)
};

pub const AtlasEnsureGlyphFn = *const fn (
    ctx: ?*anyopaque,
    scalar: u32,
    out_entry: *GlyphEntry,
) callconv(.c) c_int;

// Style flags for font variant selection (must match ZONVIE_STYLE_* in zonvie_core.h)
pub const STYLE_BOLD: u32 = 1 << 0;
pub const STYLE_ITALIC: u32 = 1 << 1;

pub const AtlasEnsureGlyphStyledFn = *const fn (
    ctx: ?*anyopaque,
    scalar: u32,
    style_flags: u32,
    out_entry: *GlyphEntry,
) callconv(.c) c_int;

// Phase 2: Core-managed atlas types
pub const GlyphBitmap = extern struct {
    pixels: ?[*]const u8,
    width: u32,
    height: u32,
    pitch: i32,
    bearing_x: i32,
    bearing_y: i32,
    advance_26_6: i32,
    ascent_px: f32,
    descent_px: f32,
    bytes_per_pixel: u32,
};

pub const RasterizeGlyphFn = *const fn (
    ctx: ?*anyopaque,
    scalar: u32,
    style_flags: u32,
    out_bitmap: *GlyphBitmap,
) callconv(.c) c_int;

pub const AtlasUploadFn = *const fn (
    ctx: ?*anyopaque,
    dest_x: u32,
    dest_y: u32,
    width: u32,
    height: u32,
    bitmap: *const GlyphBitmap,
) callconv(.c) void;

pub const AtlasCreateFn = *const fn (
    ctx: ?*anyopaque,
    atlas_w: u32,
    atlas_h: u32,
) callconv(.c) void;

// Phase B: Text-run shaping callback type
pub const ShapeTextRunFn = *const fn (
    ctx: ?*anyopaque,
    scalars: [*]const u32,
    scalar_count: usize,
    style_flags: u32,
    out_glyph_ids: [*]u32,
    out_clusters: [*]u32,
    out_x_advance: [*]i32,
    out_x_offset: [*]i32,
    out_y_offset: [*]i32,
    out_cap: usize,
) callconv(.c) usize;

// Phase B: Rasterize glyph by ID (post-shaping, skips scalar→glyph_id lookup)
pub const RasterizeGlyphByIdFn = *const fn (
    ctx: ?*anyopaque,
    glyph_id: u32,
    style_flags: u32,
    out_bitmap: *GlyphBitmap,
) callconv(.c) c_int;

// ASCII fast path table retrieval callback
pub const GetAsciiTableFn = *const fn (
    ctx: ?*anyopaque,
    style_flags: u32,
    out_glyph_ids: [*]u32,
    out_x_advances: [*]i32,
    out_lig_triggers: [*]u8,
) callconv(.c) c_int;

pub const VERT_UPDATE_MAIN: u32 = 1 << 0;
pub const VERT_UPDATE_CURSOR: u32 = 1 << 1;

pub const OnVerticesPartialFn = *const fn (
    ctx: ?*anyopaque,
    main_verts: ?[*]const Vertex,
    main_count: usize,
    cursor_verts: ?[*]const Vertex,
    cursor_count: usize,
    flags: u32,
) callconv(.c) void;

pub const OnVerticesRowFn = *const fn (
    ctx: ?*anyopaque,
    grid_id: i64,
    row_start: u32,
    row_count: u32,
    verts: ?[*]const Vertex,
    vert_count: usize,
    flags: u32,
    total_rows: u32,
    total_cols: u32,
) callconv(.c) void;

/// Grid info for hit-testing (smooth scroll support)
pub const GridInfo = extern struct {
    grid_id: i64,
    zindex: i64,
    start_row: i32,
    start_col: i32,
    rows: i32,
    cols: i32,
    // Viewport margins (rows/cols NOT part of scrollable area)
    margin_top: i32,
    margin_bottom: i32,
    margin_left: i32,
    margin_right: i32,
    // Total buffer line count for this grid (from win_viewport), or 0 if unknown.
    // Lets a frontend decide logical scrollability (line_count > content rows)
    // without a blocking viewport query on the input path.
    line_count: i64,
    // For float sub-grids, the grid this float is anchored to (1 = editor/global).
    // Lets a frontend route smooth-scroll following: a window-anchored float
    // follows only that window, not any window it merely overlaps.
    anchor_grid: i64,
    // 1 if this float has been repositioned (row changed) since creation, i.e. it
    // tracks the buffer on scroll. A fixed float stays 0 and must not pixel-shift.
    follows_scroll: i32,
    // 1 if this grid is an external (separate top-level) window. Such grids are
    // reported with start (0,0) and must be excluded from main-window hit-testing.
    is_external: i32,
};

/// Viewport info for scrollbar rendering
pub const ViewportInfo = extern struct {
    grid_id: i64,
    topline: i64, // First visible line (0-based)
    botline: i64, // First line below window (exclusive)
    line_count: i64, // Total lines in buffer
    curline: i64, // Current cursor line
    curcol: i64, // Current cursor column
    scroll_delta: i64, // Lines scrolled since last update
};

// ext_cmdline types
/// A single highlighted chunk in cmdline content.
pub const CmdlineChunk = extern struct {
    hl_id: u32,
    text: [*]const u8,
    text_len: usize,
};

/// A single line in cmdline block (multi-line input).
pub const CmdlineBlockLine = extern struct {
    chunks: [*]const CmdlineChunk,
    chunk_count: usize,
};

/// A single highlighted chunk in message content (ext_messages).
pub const MsgChunk = extern struct {
    hl_id: u32,
    text: [*]const u8,
    text_len: usize,
};

/// A single entry in message history (ext_messages).
pub const MsgHistoryEntry = extern struct {
    kind: [*]const u8,
    kind_len: usize,
    chunks: [*]const MsgChunk,
    chunk_count: usize,
    append: c_int,
};

/// A single tab entry (ext_tabline).
pub const TabEntry = extern struct {
    tab_handle: i64,
    name: [*]const u8,
    name_len: usize,
};

/// A single buffer entry (ext_tabline).
pub const BufferEntry = extern struct {
    buffer_handle: i64,
    name: [*]const u8,
    name_len: usize,
};

/// Resolved Pmenu / PmenuSel colors (0x00RRGGBB), passed with popupmenu_show.
pub const PopupmenuColors = extern struct {
    pmenu_bg: u32,
    pmenu_fg: u32,
    pmenu_sel_bg: u32,
    pmenu_sel_fg: u32,
};

pub const Callbacks = extern struct {
    on_vertices_partial: ?OnVerticesPartialFn = null,
    on_vertices_row: ?OnVerticesRowFn = null,

    on_atlas_ensure_glyph: ?AtlasEnsureGlyphFn = null,
    on_atlas_ensure_glyph_styled: ?AtlasEnsureGlyphStyledFn = null,

    on_log: ?*const fn (ctx: ?*anyopaque, p: [*]const u8, n: usize) callconv(.c) void = null,

    on_guifont: ?*const fn (ctx: ?*anyopaque, p: [*]const u8, n: usize) callconv(.c) void = null,
    on_linespace: ?*const fn (ctx: ?*anyopaque, linespace_px: i32) callconv(.c) void = null,

    on_exit: ?*const fn (ctx: ?*anyopaque, exit_code: i32) callconv(.c) void = null,
    on_set_title: ?*const fn (ctx: ?*anyopaque, title: [*]const u8, title_len: usize) callconv(.c) void = null,

    // External window callbacks (ext_multigrid)
    on_external_window: ?*const fn (ctx: ?*anyopaque, grid_id: i64, win: i64, rows: u32, cols: u32, start_row: i32, start_col: i32) callconv(.c) void = null,
    on_external_window_close: ?*const fn (ctx: ?*anyopaque, grid_id: i64) callconv(.c) void = null,

    // Cursor grid change notification
    on_cursor_grid_changed: ?*const fn (ctx: ?*anyopaque, grid_id: i64) callconv(.c) void = null,

    // ext_cmdline callbacks
    on_cmdline_show: ?*const fn (
        ctx: ?*anyopaque,
        content: [*]const CmdlineChunk,
        content_count: usize,
        pos: u32,
        firstc: u8,
        prompt: [*]const u8,
        prompt_len: usize,
        indent: u32,
        level: u32,
        prompt_hl_id: u32,
    ) callconv(.c) void = null,

    on_cmdline_hide: ?*const fn (ctx: ?*anyopaque, level: u32) callconv(.c) void = null,

    on_cmdline_pos: ?*const fn (ctx: ?*anyopaque, pos: u32, level: u32) callconv(.c) void = null,

    on_cmdline_special_char: ?*const fn (ctx: ?*anyopaque, c: [*]const u8, c_len: usize, shift: bool, level: u32) callconv(.c) void = null,

    on_cmdline_block_show: ?*const fn (
        ctx: ?*anyopaque,
        lines: [*]const CmdlineBlockLine,
        line_count: usize,
    ) callconv(.c) void = null,

    on_cmdline_block_append: ?*const fn (
        ctx: ?*anyopaque,
        line: [*]const CmdlineChunk,
        chunk_count: usize,
    ) callconv(.c) void = null,

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
        colors: ?*const PopupmenuColors,
    ) callconv(.c) void = null,

    on_popupmenu_hide: ?*const fn (ctx: ?*anyopaque) callconv(.c) void = null,

    on_popupmenu_select: ?*const fn (ctx: ?*anyopaque, selected: i32) callconv(.c) void = null,

    // ext_messages callbacks
    on_msg_show: ?*const fn (
        ctx: ?*anyopaque,
        view: zonvie_msg_view_type,
        kind: [*]const u8,
        kind_len: usize,
        chunks: [*]const MsgChunk,
        chunk_count: usize,
        replace_last: c_int,
        history: c_int,
        append: c_int,
        msg_id: i64,
        timeout_ms: u32,
    ) callconv(.c) void = null,

    on_msg_clear: ?*const fn (ctx: ?*anyopaque) callconv(.c) void = null,

    on_msg_showmode: ?*const fn (
        ctx: ?*anyopaque,
        view: zonvie_msg_view_type,
        chunks: [*]const MsgChunk,
        chunk_count: usize,
    ) callconv(.c) void = null,

    on_msg_showcmd: ?*const fn (
        ctx: ?*anyopaque,
        view: zonvie_msg_view_type,
        chunks: [*]const MsgChunk,
        chunk_count: usize,
    ) callconv(.c) void = null,

    on_msg_ruler: ?*const fn (
        ctx: ?*anyopaque,
        view: zonvie_msg_view_type,
        chunks: [*]const MsgChunk,
        chunk_count: usize,
    ) callconv(.c) void = null,

    on_msg_history_show: ?*const fn (
        ctx: ?*anyopaque,
        entries: [*]const MsgHistoryEntry,
        entry_count: usize,
        prev_cmd: c_int,
    ) callconv(.c) void = null,

    // Clipboard callbacks
    on_clipboard_get: ?*const fn (
        ctx: ?*anyopaque,
        register: [*]const u8,
        out_buf: [*]u8,
        out_len: *usize,
        max_len: usize,
    ) callconv(.c) c_int = null,

    on_clipboard_set: ?*const fn (
        ctx: ?*anyopaque,
        register: [*]const u8,
        data: [*]const u8,
        len: usize,
    ) callconv(.c) c_int = null,

    on_ssh_auth_prompt: ?*const fn (
        ctx: ?*anyopaque,
        prompt: [*]const u8,
        prompt_len: usize,
    ) callconv(.c) void = null,

    // ext_tabline callbacks
    on_tabline_update: ?*const fn (
        ctx: ?*anyopaque,
        curtab: i64,
        tabs: [*]const TabEntry,
        tab_count: usize,
        curbuf: i64,
        buffers: [*]const BufferEntry,
        buffer_count: usize,
    ) callconv(.c) void = null,

    on_tabline_hide: ?*const fn (ctx: ?*anyopaque) callconv(.c) void = null,

    // Grid scroll notification (for reconciling a smooth scroll pixel offset).
    // rows_delta is the signed distance the content moved, summed over every
    // scroll of that grid in the batch this notification stands for.
    on_grid_scroll: ?*const fn (ctx: ?*anyopaque, grid_id: i64, rows_delta: i32) callconv(.c) void = null,

    // IME off notification (for mode change or RPC zonvie_ime_off)
    on_ime_off: ?*const fn (ctx: ?*anyopaque) callconv(.c) void = null,

    // Quit request notification (window close with unsaved buffer check)
    on_quit_requested: ?*const fn (ctx: ?*anyopaque, has_unsaved: c_int) callconv(.c) void = null,

    // Phase 2: Core-managed atlas callbacks
    on_rasterize_glyph: ?RasterizeGlyphFn = null,
    on_atlas_upload: ?AtlasUploadFn = null,
    on_atlas_create: ?AtlasCreateFn = null,

    // Flush bracketing (for GPU buffer management)
    on_flush_begin: ?*const fn (ctx: ?*anyopaque) callconv(.c) void = null,
    on_flush_end: ?*const fn (ctx: ?*anyopaque) callconv(.c) void = null,

    // Neovim default_colors_set notification
    on_default_colors_set: ?*const fn (ctx: ?*anyopaque, fg: u32, bg: u32) callconv(.c) void = null,

    // ext_windows layout operation callbacks
    on_win_move: ?*const fn (ctx: ?*anyopaque, grid_id: i64, win: i64, flags: i32) callconv(.c) void = null,
    on_win_exchange: ?*const fn (ctx: ?*anyopaque, grid_id: i64, win: i64, count: i32) callconv(.c) void = null,
    on_win_rotate: ?*const fn (ctx: ?*anyopaque, grid_id: i64, win: i64, direction: i32, count: i32) callconv(.c) void = null,
    on_win_resize_equal: ?*const fn (ctx: ?*anyopaque) callconv(.c) void = null,
    on_win_move_cursor: ?*const fn (ctx: ?*anyopaque, direction: i32, count: i32) callconv(.c) i64 = null,

    // Phase B: Text-run shaping (ligatures)
    on_shape_text_run: ?ShapeTextRunFn = null,
    on_rasterize_glyph_by_id: ?RasterizeGlyphByIdFn = null,

    // ASCII fast path table callback (NULL = no fast path, always use shaping)
    on_get_ascii_table: ?GetAsciiTableFn = null,

    // Main row-buffer scroll fast path notification (optional)
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

    // External grid (sub-grid) row-buffer scroll fast path notification (optional)
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

    // Restart UI event observer (informational; core handles reconnect).
    // Appended at the end of the struct to preserve ABI for older callers
    // that pass a smaller callbacks_size to zonvie_core_create.
    on_restart: ?*const fn (ctx: ?*anyopaque, listen_addr: [*]const u8, listen_addr_len: usize) callconv(.c) void = null,

    // Connect UI event observer (informational; core handles reconnect).
    // Appended after on_restart for the same ABI-compat reason. Old callers
    // that don't fill this field get a null callback and lose the
    // notification — the reconnect itself still happens transparently.
    on_connect: ?*const fn (ctx: ?*anyopaque, server_addr: [*]const u8, server_addr_len: usize) callconv(.c) void = null,

    // AI-agent work status per tab. Appended at the end for ABI compat (see
    // on_restart note). Low 7 bits of state: 0=none, 1=idle (agent present,
    // done), 2=working/claude, 3=working/braille (codex & generic),
    // 4=waiting for user input (a decision prompt is on screen). Bit 7 (0x80)
    // is a "fire the OS notification now" flag (only combined with base 1 or
    // 4); frontends render the indicator from state & 0x7F and must not
    // edge-detect notifications themselves.
    on_agent_status: ?*const fn (ctx: ?*anyopaque, tab_handle: i64, state: u8, title: [*]const u8, title_len: usize) callconv(.c) void = null,

    // Neovim-initiated main grid resize (`:set columns=` / `:set lines=`).
    // Appended at the end for ABI compat (see on_restart note).
    on_main_grid_size: ?*const fn (ctx: ?*anyopaque, rows: u32, cols: u32) callconv(.c) void = null,
};

pub const zonvie_core = opaque {};

const CoreBox = struct {
    // Own an allocator for the core lifetime.
    gpa: std.heap.DebugAllocator(.{}) = .{},

    core: core.Core = undefined,
    cb: Callbacks = .{},
    ctx: ?*anyopaque = null,

    // Config for message routing
    msg_config: config.Config = .{},
    // A safe lifecycle-thread destroy is a one-shot ownership transfer.
    // Callback-thread destroy requests shutdown without claiming ownership so
    // the lifecycle thread can still release the retained box afterwards.
    destroy_claimed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    fn allocator(self: *CoreBox) std.mem.Allocator {
        return self.gpa.allocator();
    }
};

fn asBox(p: *zonvie_core) *CoreBox {
    return @ptrCast(@alignCast(p));
}

pub export fn zonvie_core_create(cb: ?*const Callbacks, callbacks_size: usize, ctx: ?*anyopaque) ?*zonvie_core {
    // Eagerly initialize the shared Io before any worker threads spawn.
    clock.init();

    const box = std.heap.c_allocator.create(CoreBox) catch return null;

    // Initialize box state.
    box.* = .{
        .gpa = .{},
        .core = undefined,
        .cb = if (cb) |p| blk: {
            var result: Callbacks = .{}; // zero-init: all callbacks null
            if (callbacks_size == 0) {
                // Unspecified size: a whole-struct copy would read past a
                // smaller caller-side struct, so refuse rather than guess.
                break :blk result;
            }
            if (callbacks_size >= @sizeOf(Callbacks)) {
                // Current version: copy whole struct
                result = p.*;
            } else {
                // Older version with fewer fields: copy only what they provided
                const src = @as([*]const u8, @ptrCast(p));
                const dst = @as([*]u8, @ptrCast(&result));
                @memcpy(dst[0..callbacks_size], src[0..callbacks_size]);
            }
            break :blk result;
        } else .{},
        .ctx = ctx,
    };

    // Build core.Callbacks from the C-facing callback struct.
    const cb_core: core.Callbacks = .{
        .on_vertices_partial = box.cb.on_vertices_partial,
        .on_vertices_row = box.cb.on_vertices_row,

        .on_atlas_ensure_glyph = box.cb.on_atlas_ensure_glyph,
        .on_atlas_ensure_glyph_styled = box.cb.on_atlas_ensure_glyph_styled,

        .on_log = box.cb.on_log,

        .on_guifont = box.cb.on_guifont,
        .on_linespace = box.cb.on_linespace,

        .on_exit = box.cb.on_exit,
        .on_set_title = box.cb.on_set_title,
        .on_restart = box.cb.on_restart,
        .on_connect = box.cb.on_connect,

        .on_external_window = box.cb.on_external_window,
        .on_external_window_close = box.cb.on_external_window_close,

        .on_cursor_grid_changed = box.cb.on_cursor_grid_changed,

        // ext_cmdline callbacks
        .on_cmdline_show = box.cb.on_cmdline_show,
        .on_cmdline_hide = box.cb.on_cmdline_hide,
        .on_cmdline_pos = box.cb.on_cmdline_pos,
        .on_cmdline_special_char = box.cb.on_cmdline_special_char,
        .on_cmdline_block_show = box.cb.on_cmdline_block_show,
        .on_cmdline_block_append = box.cb.on_cmdline_block_append,
        .on_cmdline_block_hide = box.cb.on_cmdline_block_hide,

        // ext_popupmenu callbacks
        .on_popupmenu_show = box.cb.on_popupmenu_show,
        .on_popupmenu_hide = box.cb.on_popupmenu_hide,
        .on_popupmenu_select = box.cb.on_popupmenu_select,

        // ext_messages callbacks
        .on_msg_show = box.cb.on_msg_show,
        .on_msg_clear = box.cb.on_msg_clear,
        .on_msg_showmode = box.cb.on_msg_showmode,
        .on_msg_showcmd = box.cb.on_msg_showcmd,
        .on_msg_ruler = box.cb.on_msg_ruler,
        .on_msg_history_show = box.cb.on_msg_history_show,

        // Clipboard callbacks
        .on_clipboard_get = box.cb.on_clipboard_get,
        .on_clipboard_set = box.cb.on_clipboard_set,

        // SSH auth callback
        .on_ssh_auth_prompt = box.cb.on_ssh_auth_prompt,

        // ext_tabline callbacks
        .on_tabline_update = box.cb.on_tabline_update,
        .on_tabline_hide = box.cb.on_tabline_hide,
        .on_agent_status = box.cb.on_agent_status,

        // Neovim-initiated main grid resize
        .on_main_grid_size = box.cb.on_main_grid_size,

        // Grid scroll notification
        .on_grid_scroll = box.cb.on_grid_scroll,

        // IME off notification
        .on_ime_off = box.cb.on_ime_off,

        // Quit request notification
        .on_quit_requested = box.cb.on_quit_requested,

        // Phase 2: Core-managed atlas
        .on_rasterize_glyph = box.cb.on_rasterize_glyph,
        .on_atlas_upload = box.cb.on_atlas_upload,
        .on_atlas_create = box.cb.on_atlas_create,

        // Flush bracketing (for GPU buffer management)
        .on_flush_begin = box.cb.on_flush_begin,
        .on_flush_end = box.cb.on_flush_end,

        // Neovim default_colors_set notification
        .on_default_colors_set = box.cb.on_default_colors_set,

        // ext_windows layout operation callbacks
        .on_win_move = box.cb.on_win_move,
        .on_win_exchange = box.cb.on_win_exchange,
        .on_win_rotate = box.cb.on_win_rotate,
        .on_win_resize_equal = box.cb.on_win_resize_equal,
        .on_win_move_cursor = box.cb.on_win_move_cursor,

        // Phase B: Text-run shaping (ligatures)
        .on_shape_text_run = box.cb.on_shape_text_run,
        .on_rasterize_glyph_by_id = box.cb.on_rasterize_glyph_by_id,

        // ASCII fast path
        .on_get_ascii_table = box.cb.on_get_ascii_table,

        // Main row-buffer scroll fast path notification
        .on_main_row_scroll = box.cb.on_main_row_scroll,

        // External grid row-buffer scroll fast path notification
        .on_grid_row_scroll = box.cb.on_grid_row_scroll,
    };

    box.core = core.Core.init(box.allocator(), cb_core, ctx);

    return @ptrCast(box);
}

pub export fn zonvie_core_destroy(p: ?*zonvie_core) callconv(.c) void {
    if (p == null) return;
    const box = asBox(p.?);

    // The RPC/redraw thread may be inside a frontend callback. Joining that
    // stack here self-deadlocks, while asynchronously freeing the box would
    // invalidate callback context/local handle copies. Request shutdown but do
    // not claim destruction: the frontend must finish it later from its
    // lifecycle thread.
    if (box.core.isCurrentThreadUnsafeForTeardown()) {
        box.core.stop();
        return;
    }

    if (box.destroy_claimed.cmpxchgStrong(false, true, .acq_rel, .acquire) != null) return;

    box.core.stop();
    // stop() is idempotent and non-blocking for a concurrent teardown owner;
    // the allocator and CoreBox must outlive that owner.
    if (!box.core.waitUntilStopped()) return;
    _ = box.gpa.deinit();
    std.heap.c_allocator.destroy(box);
}

test "callback destroy can be completed after enclosing API returns" {
    const State = struct {
        core: ?*zonvie_core = null,
        callback_count: u32 = 0,

        fn onFlushBegin(ctx: ?*anyopaque) callconv(.c) void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            self.callback_count += 1;
            zonvie_core_destroy(self.core);
        }
    };

    var state = State{};
    var callbacks: Callbacks = .{ .on_flush_begin = State.onFlushBegin };
    const p = zonvie_core_create(&callbacks, @sizeOf(Callbacks), &state) orelse return error.OutOfMemory;
    state.core = p;
    const box = asBox(p);
    try box.core.grid.resizeGrid(1, 1, 1);

    // retry_flush models a UI-thread Core API that invokes a synchronous
    // callback. The callback's destroy request must not claim or free the box
    // while retry_flush still has grid_mu/redraw-thread state to unwind.
    zonvie_core_retry_flush(p);
    try std.testing.expectEqual(@as(u32, 1), state.callback_count);
    try std.testing.expect(!box.destroy_claimed.load(.acquire));
    try std.testing.expect(box.core.stop_flag.load(.acquire));
    try std.testing.expectEqual(@as(u8, 0), box.core.stop_state.load(.acquire));

    // Once the callback and enclosing API have both returned, the serialized
    // lifecycle owner can join teardown and release the retained handle.
    zonvie_core_destroy(p);
}

test "retry entry points reject work after stop is requested" {
    const State = struct {
        callback_count: u32 = 0,

        fn onFlushBegin(ctx: ?*anyopaque) callconv(.c) void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            self.callback_count += 1;
        }
    };

    var state = State{};
    var callbacks: Callbacks = .{ .on_flush_begin = State.onFlushBegin };
    const p = zonvie_core_create(&callbacks, @sizeOf(Callbacks), &state) orelse return error.OutOfMemory;
    defer zonvie_core_destroy(p);
    const box = asBox(p);
    try box.core.grid.resizeGrid(1, 1, 1);

    box.core.stop_flag.store(true, .release);
    zonvie_core_retry_flush(p);
    zonvie_core_retry_flush_locked(p);
    try std.testing.expectEqual(@as(u32, 0), state.callback_count);
}

test "grid text extraction trims blanks and reports the size a short buffer needs" {
    const p = zonvie_core_create(null, 0, null) orelse return error.OutOfMemory;
    defer zonvie_core_destroy(p);
    const box = asBox(p);

    const gid = grid_mod.MESSAGE_GRID_ID;
    try box.core.grid.resizeGrid(gid, 4, 8);
    box.core.grid.clearGrid(gid);
    // Row 0 "hi", row 1 blank, row 2 "ok" with trailing blanks, row 3 blank.
    _ = box.core.grid.putCellGrid(gid, 0, 0, 'h', 0);
    _ = box.core.grid.putCellGrid(gid, 0, 1, 'i', 0);
    _ = box.core.grid.putCellGrid(gid, 2, 0, 'o', 0);
    _ = box.core.grid.putCellGrid(gid, 2, 1, 'k', 0);

    var buf: [32]u8 = undefined;
    const needed = zonvie_core_try_get_grid_text(p, gid, &buf, buf.len);
    try std.testing.expectEqual(@as(isize, 6), needed);
    try std.testing.expectEqualStrings("hi\n\nok", buf[0..@intCast(needed)]);

    // A buffer that cannot hold the whole text still reports the full size.
    var short: [2]u8 = undefined;
    try std.testing.expectEqual(@as(isize, 6), zonvie_core_try_get_grid_text(p, gid, &short, short.len));

    // An unknown grid is empty, not an error.
    try std.testing.expectEqual(@as(isize, 0), zonvie_core_try_get_grid_text(p, 4242, &buf, buf.len));
}

test "current mode accessor returns a snapshot independent of core storage" {
    const p = zonvie_core_create(null, 0, null) orelse return error.OutOfMemory;
    defer zonvie_core_destroy(p);
    const box = asBox(p);

    @memset(box.core.grid.current_mode_name[0..], 0);
    @memcpy(box.core.grid.current_mode_name[0..6], "normal");
    const snapshot = zonvie_core_get_current_mode(p);

    box.core.grid_mu.lockUncancelable(clock.io());
    @memset(box.core.grid.current_mode_name[0..], 0);
    @memcpy(box.core.grid.current_mode_name[0..6], "insert");
    box.core.grid_mu.unlock(clock.io());

    try std.testing.expectEqualStrings("normal", std.mem.span(snapshot));
}

pub export fn zonvie_core_start(p: ?*zonvie_core, nvim_path_c: ?[*:0]const u8, rows: u32, cols: u32) callconv(.c) i32 {
    if (p == null) return -1;
    const box = asBox(p.?);
    const nvim_path = if (nvim_path_c) |s| std.mem.span(s) else "nvim";
    box.core.start(nvim_path, rows, cols) catch return -2;
    return 0;
}

/// Start in connect mode: attach to a running Neovim server at
/// listen_addr instead of spawning a child. Address forms supported:
///   POSIX (macOS, Linux): "host:port" (TCP) or "/abs/path" (Unix socket)
///   Windows:              "\\.\pipe\..." (named pipe); TCP and Unix
///                         sockets are not yet supported.
///
/// Address validity (parse errors and platform-unsupported forms) is
/// checked synchronously and returned as -3 before the run-loop thread
/// is spawned, so callers can react immediately instead of waiting for
/// an async on_exit.
pub export fn zonvie_core_start_connect(
    p: ?*zonvie_core,
    listen_addr: ?[*]const u8,
    listen_addr_len: usize,
    rows: u32,
    cols: u32,
) callconv(.c) i32 {
    if (p == null) return -1;
    const box = asBox(p.?);
    const addr = if (listen_addr) |s| s[0..listen_addr_len] else {
        box.core.log.write("[c_api] start_connect: listen_addr=null -> -3\n", .{});
        return -3;
    };
    box.core.log.write("[c_api] start_connect: enter addr_len={d} addr=\"{s}\"\n", .{ addr.len, addr });
    if (addr.len == 0) {
        box.core.log.write("[c_api] start_connect: empty addr -> -3\n", .{});
        return -3;
    }
    const supported = rpc_transport.isAddrSupported(addr);
    box.core.log.write("[c_api] start_connect: isAddrSupported(\"{s}\") = {}\n", .{ addr, supported });
    if (!supported) return -3;
    box.core.startConnect(addr, rows, cols) catch return -2;
    box.core.log.write("[c_api] start_connect: thread spawned, returning 0\n", .{});
    return 0;
}

pub export fn zonvie_core_stop(p: ?*zonvie_core) callconv(.c) void {
    if (p == null) return;
    const box = asBox(p.?);
    box.core.stop();
}

/// Notify the core that actual layout dimensions are ready. Must be called from
/// the UI thread after the renderer is initialized and rows/cols are computed.
/// This unblocks the RPC thread so it can send nvim_ui_attach with the correct
/// size, preventing Neovim from rendering the initial splash at the wrong position.
pub export fn zonvie_core_notify_layout_ready(p: ?*zonvie_core, rows: u32, cols: u32) callconv(.c) void {
    if (p == null) return;
    const box = asBox(p.?);
    box.core.notifyLayoutReady(rows, cols);
}

pub export fn zonvie_core_send_input(p: ?*zonvie_core, keys: [*]const u8, len: usize) callconv(.c) void {
    if (p == null) return;
    const box = asBox(p.?);
    box.core.sendInput(keys[0..len]);
}

pub export fn zonvie_core_perf_now_ns() callconv(.c) i64 {
    return @intCast(clock.nowNs());
}

// Build-time version string from `git describe`, null-terminated for C.
const version_cstr: [*:0]const u8 = std.fmt.comptimePrint("{s}", .{build_options.version});

pub export fn zonvie_version() callconv(.c) [*:0]const u8 {
    return version_cstr;
}

pub export fn zonvie_core_note_input_trace(p: ?*zonvie_core, seq: u64, sent_ns: i64) callconv(.c) void {
    if (p == null) return;
    const box = asBox(p.?);
    box.core.noteInputTrace(seq, sent_ns);
}

/// Non-blocking version of zonvie_core_note_input_trace. Drops the sample
/// (no [perf_input] line for this seq) if grid_mu could not be acquired,
/// rather than blocking the input-send path with the very lock this trace
/// exists to measure contention on. Returns true if the sample was recorded.
pub export fn zonvie_core_try_note_input_trace(p: ?*zonvie_core, seq: u64, sent_ns: i64) callconv(.c) bool {
    if (p == null) return false;
    const box = asBox(p.?);
    return box.core.tryNoteInputTrace(seq, sent_ns);
}

/// Notify Neovim of window focus change (triggers FocusGained/FocusLost autocmds).
pub export fn zonvie_core_set_focus(p: ?*zonvie_core, gained: bool) callconv(.c) void {
    if (p == null) return;
    const box = asBox(p.?);
    box.core.requestUiSetFocus(gained);
}

/// Set a global Neovim option value via `nvim_set_option_value`.
/// Used by frontends to sync the effective `guifont` back to Neovim so
/// `:set guifont?` reports what the frontend is actually rendering.
pub export fn zonvie_core_set_option_value(
    p: ?*zonvie_core,
    name: [*]const u8,
    name_len: usize,
    value: [*]const u8,
    value_len: usize,
) callconv(.c) void {
    if (p == null) return;
    const box = asBox(p.?);
    box.core.requestSetOptionValue(name[0..name_len], value[0..value_len]) catch {};
}

/// Send a Neovim command (via nvim_command API, does not show in cmdline)
pub export fn zonvie_core_send_command(p: ?*zonvie_core, cmd: [*]const u8, len: usize) callconv(.c) void {
    if (p == null) return;
    const box = asBox(p.?);
    box.core.requestCommand(cmd[0..len]) catch {};
}

/// Set/update IME preedit (composition) text.
/// target_start/target_end are UTF-8 byte offsets into `text` marking the
/// clause being converted (highlighted distinctly); pass target_start >=
/// target_end when there is no target clause.
/// Returns 1 if the core placed the preedit as an inline extmark (the frontend
/// should hide its own preedit overlay), 0 if the frontend should display the
/// preedit itself (extmark mode disabled, or not in insert/replace mode).
pub export fn zonvie_core_set_preedit(
    p: ?*zonvie_core,
    text: [*]const u8,
    len: usize,
    target_start: usize,
    target_end: usize,
) callconv(.c) c_int {
    if (p == null) return 0;
    const box = asBox(p.?);
    return if (box.core.setPreedit(text[0..len], target_start, target_end)) 1 else 0;
}

/// Clear any inline preedit extmark (called on IME commit or cancel).
pub export fn zonvie_core_clear_preedit(p: ?*zonvie_core) callconv(.c) void {
    if (p == null) return;
    const box = asBox(p.?);
    box.core.clearPreedit();
}

/// Request graceful quit (called by frontend on window close button).
/// This checks for unsaved buffers and calls on_quit_requested callback.
pub export fn zonvie_core_request_quit(p: ?*zonvie_core) callconv(.c) void {
    if (p == null) return;
    const box = asBox(p.?);
    box.core.requestQuit();
}

/// Confirm quit after user dialog (called after on_quit_requested).
/// force: if non-zero, use :qa! (discard changes), otherwise :qa
pub export fn zonvie_core_quit_confirmed(p: ?*zonvie_core, force: c_int) callconv(.c) void {
    if (p == null) return;
    const box = asBox(p.?);
    box.core.quitConfirmed(force != 0);
}

/// Send raw data to child process stdin (for SSH password input).
/// Used when on_ssh_auth_prompt callback is triggered.
pub export fn zonvie_core_send_stdin_data(p: ?*zonvie_core, data: [*]const u8, len: i32) callconv(.c) void {
    if (p == null) return;
    if (len <= 0) return;
    const box = asBox(p.?);
    box.core.sendStdinData(data[0..@as(usize, @intCast(len))]);
}

pub export fn zonvie_core_send_key_event(
    p: ?*zonvie_core,
    keycode: u32,
    mods: u32,
    chars_ptr: ?[*]const u8,
    chars_len: i32,
    ign_ptr: ?[*]const u8,
    ign_len: i32,
) callconv(.c) void {
    if (p == null) return;
    const box = asBox(p.?);

    const chars: []const u8 = if (chars_ptr != null and chars_len > 0)
        chars_ptr.?[0..@as(usize, @intCast(chars_len))]
    else
        &[_]u8{};

    const ign: []const u8 = if (ign_ptr != null and ign_len > 0)
        ign_ptr.?[0..@as(usize, @intCast(ign_len))]
    else
        &[_]u8{};

    box.core.sendKeyEvent(keycode, mods, chars, ign);
}

pub export fn zonvie_core_resize(p: ?*zonvie_core, rows: u32, cols: u32) callconv(.c) void {
    if (p == null) return;
    const box = asBox(p.?);
    _ = box.core.resize(rows, cols);
}

/// Request resize of a specific grid (for external windows).
pub export fn zonvie_core_try_resize_grid(p: ?*zonvie_core, grid_id: i64, rows: u32, cols: u32) callconv(.c) void {
    if (p == null) return;
    const box = asBox(p.?);
    box.core.requestTryResizeGrid(grid_id, rows, cols);
}

pub export fn zonvie_core_update_layout_px(
    p: ?*zonvie_core,
    drawable_w_px: u32,
    drawable_h_px: u32,
    cell_w_px: u32,
    cell_h_px: u32,
) callconv(.c) void {
    if (p == null) return;
    const box = asBox(p.?);
    if (box.core.updateLayoutPx(drawable_w_px, drawable_h_px, cell_w_px, cell_h_px)) {
        // Standalone layout changes must publish main and external vertices
        // together. Re-entrant redraw callbacks are flushed by their batch.
        zonvie_core_retry_flush(p);
    }
}

/// Non-blocking version of zonvie_core_update_layout_px, for callers that
/// must not stall the calling thread (e.g. drag-resize on the UI thread)
/// if the core thread is mid-flush holding grid_mu. Returns false ("busy")
/// if grid_mu could not be acquired; the caller must retry shortly, since
/// unlike a read-only trace this is a write that must not be dropped.
///
/// `screen_cols` folds zonvie_core_set_screen_cols into the same critical
/// section: pass 0 to keep the drawable-width-derived value that
/// updateLayoutPxLocked computes, or a display-derived count to override it.
/// Taking grid_mu a second time via the blocking set_screen_cols would negate
/// the whole point of this entry point. `cmdline_default_cols` folds
/// zonvie_core_set_cmdline_default_cols in for the same reason; 0 keeps the
/// current value.
pub export fn zonvie_core_try_update_layout_px(
    p: ?*zonvie_core,
    drawable_w_px: u32,
    drawable_h_px: u32,
    cell_w_px: u32,
    cell_h_px: u32,
    screen_cols: u32,
    cmdline_default_cols: u32,
) callconv(.c) bool {
    // A null handle is permanently unusable, not transiently busy. Returning
    // "busy" here would make a conforming caller retry forever.
    if (p == null) return true;
    const box = asBox(p.?);
    const cp = &box.core;
    if (cp.stop_flag.load(.acquire)) return true;

    const current_tid: usize = @intCast(std.Thread.getCurrentId());
    const redraw_tid = cp.redraw_thread_id.load(.seq_cst);
    if (redraw_tid != 0 and redraw_tid == current_tid) {
        // Re-entrant redraw callback: grid_mu is already held by this thread
        // and the in-progress batch publishes the result. Do NOT retry the
        // flush here -- that would re-acquire the non-recursive grid_mu this
        // thread already owns. Same reasoning as the blocking twin above.
        _ = cp.updateLayoutPxLocked(drawable_w_px, drawable_h_px, cell_w_px, cell_h_px);
        if (screen_cols != 0) cp.grid.screen_cols = screen_cols;
        if (cmdline_default_cols != 0) cp.grid.cmdline_default_cols = cmdline_default_cols;
        return true;
    }

    const acquired = cp.grid_mu.tryLock();
    cp.perf_lock_layout.record(acquired);
    if (!acquired) return false;
    defer cp.grid_mu.unlock(clock.io());
    const changed = cp.updateLayoutPxLocked(drawable_w_px, drawable_h_px, cell_w_px, cell_h_px);
    if (screen_cols != 0) cp.grid.screen_cols = screen_cols;
    if (cmdline_default_cols != 0) cp.grid.cmdline_default_cols = cmdline_default_cols;
    if (changed) {
        // Standalone layout changes must publish main and external vertices
        // together, still holding the lock tryLock just acquired. Dropping it
        // and calling zonvie_core_retry_flush would re-acquire grid_mu with an
        // unbounded blocking wait -- exactly what this entry point avoids.
        retryFlushLocked(cp);
    }
    return true;
}

/// Set screen width in cells (for cmdline max width).
/// This should be called when screen size or cell size changes.
/// Note: On Windows, this is now handled automatically inside updateLayoutPxLocked
/// to avoid deadlock when called from redraw callbacks. macOS still uses this API
/// since it sets screen_cols based on NSScreen width rather than window width.
pub export fn zonvie_core_set_screen_cols(p: ?*zonvie_core, cols: u32) callconv(.c) void {
    if (p == null) return;
    const box = asBox(p.?);
    box.core.setScreenCols(cols);
}

/// Set the cmdline's default width in cells: the width it shows before its
/// content needs more, clamped up by zonvie_core_set_screen_cols. Only the
/// frontend knows the window chrome beside the cmdline grid, so it derives
/// this from the main window width. 0 restores the main grid's width.
pub export fn zonvie_core_set_cmdline_default_cols(p: ?*zonvie_core, cols: u32) callconv(.c) void {
    if (p == null) return;
    const box = asBox(p.?);
    box.core.setCmdlineDefaultCols(cols);
}

pub export fn zonvie_core_set_log_enabled(p: ?*zonvie_core, enabled: i32) callconv(.c) void {
    if (p == null) return;
    const box = asBox(p.?);

    const on = enabled != 0;
    // Logger.write() is a no-op when cb is null.
    box.core.log.cb = if (on) box.cb.on_log else null;
}

/// When enabled is non-zero, only [perf...] log lines are emitted; all other
/// debug logs ([scroll_debug], [cmdline], [msg], etc.) are dropped at the
/// Logger.write boundary. Independent of zonvie_core_set_log_enabled — caller
/// must still enable logging for any output to appear. Intended for low-noise
/// hot-path profiling.
pub export fn zonvie_core_set_log_perf_only(p: ?*zonvie_core, enabled: i32) callconv(.c) void {
    if (p == null) return;
    const box = asBox(p.?);
    box.core.log.perf_only = (enabled != 0);
}

/// Scroll-pipeline analysis mode: when enabled is non-zero, only [perf...]
/// and [scroll_debug] log lines are emitted, so the input -> grid_scroll ->
/// flush -> commit -> draw chain can be traced without other debug noise.
/// Takes precedence over zonvie_core_set_log_perf_only when both are set.
/// Independent of zonvie_core_set_log_enabled — caller must still enable
/// logging for any output to appear.
pub export fn zonvie_core_set_log_scroll_only(p: ?*zonvie_core, enabled: i32) callconv(.c) void {
    if (p == null) return;
    const box = asBox(p.?);
    box.core.log.scroll_only = (enabled != 0);
}

/// Verbose tier: when enabled is non-zero, the highest-frequency per-row /
/// per-glyph log lines ([perf] row_mode / row_mode_post, [shape_dump],
/// [glyph_quad]) are also emitted. Off by default because their formatting
/// and I/O cost is heavy enough to perturb the measured pipeline (~1-2ms
/// per flush). Independent of zonvie_core_set_log_enabled — caller must
/// still enable logging for any output to appear.
pub export fn zonvie_core_set_log_verbose(p: ?*zonvie_core, enabled: i32) callconv(.c) void {
    if (p == null) return;
    const box = asBox(p.?);
    box.core.log.verbose = (enabled != 0);
}

/// Enable ext_cmdline UI extension. Must be called before zonvie_core_start().
/// When enabled, cmdline is rendered as a separate external window.
pub export fn zonvie_core_set_ext_cmdline(p: ?*zonvie_core, enabled: i32) callconv(.c) void {
    if (p == null) return;
    const box = asBox(p.?);
    const was_enabled = box.core.ext_cmdline_enabled;
    box.core.ext_cmdline_enabled = (enabled != 0);
    box.core.log.write("[c_api] zonvie_core_set_ext_cmdline called: enabled={d} -> ext_cmdline_enabled={any} (was {any})\n", .{ enabled, box.core.ext_cmdline_enabled, was_enabled });
}

/// Enable ext_popupmenu UI extension. Must be called before zonvie_core_start().
/// When enabled, popup menu events are sent to frontend callbacks.
pub export fn zonvie_core_set_ext_popupmenu(p: ?*zonvie_core, enabled: i32) callconv(.c) void {
    if (p == null) return;
    const box = asBox(p.?);
    const was_enabled = box.core.ext_popupmenu_enabled;
    box.core.ext_popupmenu_enabled = (enabled != 0);
    box.core.log.write("[c_api] zonvie_core_set_ext_popupmenu called: enabled={d} -> ext_popupmenu_enabled={any} (was {any})\n", .{ enabled, box.core.ext_popupmenu_enabled, was_enabled });
}

/// Set glyph cache sizes for performance tuning.
/// ascii_size: cache size for ASCII chars (0-127) × 4 style combinations (default: 512, min: 128)
/// non_ascii_size: hash table size for non-ASCII chars (default: 256, min: 64)
/// Should be called before zonvie_core_start() for best results.
pub export fn zonvie_core_set_glyph_cache_size(p: ?*zonvie_core, ascii_size: u32, non_ascii_size: u32) callconv(.c) void {
    if (p == null) return;
    const box = asBox(p.?);
    box.core.setGlyphCacheSize(ascii_size, non_ascii_size);
    box.core.log.write("[c_api] zonvie_core_set_glyph_cache_size: ascii={d} non_ascii={d}\n", .{ box.core.glyph_cache_ascii_size, box.core.glyph_cache_non_ascii_size });
}

/// Set glyph atlas texture size (square). Must be called before zonvie_core_start().
/// Ignored after start. size is clamped to [1024, 4096].
pub export fn zonvie_core_set_atlas_size(p: ?*zonvie_core, size: u32) callconv(.c) void {
    if (p == null) return;
    const box = asBox(p.?);
    if (box.core.started) {
        box.core.log.write("[c_api] zonvie_core_set_atlas_size: ignored (already started)\n", .{});
        return;
    }
    const clamped = @max(config.atlas_size_min, @min(config.atlas_size_max, size));
    box.core.atlas_w = clamped;
    box.core.atlas_h = clamped;
    box.core.log.write("[c_api] zonvie_core_set_atlas_size: {d}x{d}\n", .{ clamped, clamped });
}

/// Enable ext_messages UI extension. Must be called before zonvie_core_start().
/// When enabled, message events are sent to frontend callbacks instead of being
/// rendered in the global grid. Messages are displayed as external floating windows.
pub export fn zonvie_core_set_ext_messages(p: ?*zonvie_core, enabled: i32) callconv(.c) void {
    if (p == null) return;
    const box = asBox(p.?);
    const was_enabled = box.core.ext_messages_enabled;
    box.core.ext_messages_enabled = (enabled != 0);
    box.core.log.write("[c_api] zonvie_core_set_ext_messages called: enabled={d} -> ext_messages_enabled={any} (was {any})\n", .{ enabled, box.core.ext_messages_enabled, was_enabled });
}

/// Enable ext_tabline UI extension. Must be called before zonvie_core_start().
pub export fn zonvie_core_set_ext_tabline(p: ?*zonvie_core, enabled: i32) callconv(.c) void {
    if (p == null) return;
    const box = asBox(p.?);
    box.core.ext_tabline_enabled = (enabled != 0);
    box.core.log.write("[c_api] zonvie_core_set_ext_tabline: enabled={any}\n", .{box.core.ext_tabline_enabled});
}

/// Enable ext_windows UI extension. Must be called before zonvie_core_start().
pub export fn zonvie_core_set_ext_windows(p: ?*zonvie_core, enabled: i32) callconv(.c) void {
    if (p == null) return;
    const box = asBox(p.?);
    box.core.ext_windows_enabled = (enabled != 0);
    box.core.log.write("[c_api] zonvie_core_set_ext_windows: enabled={any}\n", .{box.core.ext_windows_enabled});
}

/// Process due message timeouts and render-maintenance retries. The legacy
/// exported name is retained for ABI compatibility; frontends normally call
/// this from the one-shot deadline query below.
pub export fn zonvie_core_tick_msg_throttle(p: ?*zonvie_core) callconv(.c) void {
    if (p == null) return;
    const box = asBox(p.?);
    // Lock grid_mu to synchronize with handleRedraw (RPC thread).
    // IMPORTANT: All callbacks fired from within this tick (on_external_window_close,
    // on_msg_clear, on_msg_show) execute while grid_mu is held. Frontend callback
    // implementations MUST NOT synchronously call back into core APIs that acquire
    // grid_mu. Use async dispatch (DispatchQueue.main.async on macOS, PostMessage
    // on Windows) instead.
    box.core.grid_mu.lockUncancelable(clock.io());
    box.core.redraw_thread_id.store(@intCast(std.Thread.getCurrentId()), .seq_cst);
    defer {
        box.core.redraw_thread_id.store(0, .seq_cst);
        box.core.grid_mu.unlock(clock.io());
    }

    // The timeout can create/remove external grids. onFlush runs vertex
    // generation and external-window lifecycle notification inside the same
    // frontend bracket, so atlas publication and commit are one transaction.
    var fctx = flush_mod.FlushCtx{ .core = &box.core };
    flush_mod.FlushCtx.onFlush(&fctx, box.core.grid.rows, box.core.grid.cols) catch |reason| {
        if (nvim_core.Core.isHardRenderFailure(reason)) box.core.failHardRender(reason);
    };
}

/// Milliseconds until the next armed message deadline, or -1 when none is
/// armed and 0 when one is already due.
///
/// Rounds up: a deadline 1 ns away must report 1 ms, not 0, or a frontend
/// that trusts the value schedules a timer that fires before the deadline and
/// spins. Both exported entry points share this so the two cannot round
/// differently.
///
/// The caller owns grid_mu; this only reads under it.
fn nextMsgTimeoutMsLocked(box: *CoreBox) i64 {
    const deadline = flush_mod.nextMsgTimeoutNs(&box.core) orelse return -1;
    const now = clock.nowNs();
    if (deadline <= now) return 0;
    const remaining_ns = deadline - now;
    const remaining_ms = @divTrunc(remaining_ns - 1, std.time.ns_per_ms) + 1;
    return @intCast(remaining_ms);
}

/// Returns milliseconds until the earliest pending message or render-
/// maintenance deadline, clamped to >= 0. Returns -1 if no timeout is armed.
/// Frontends use this to schedule one timer instead of polling every frame.
pub export fn zonvie_core_next_msg_timeout_ms(p: ?*zonvie_core) callconv(.c) i64 {
    if (p == null) return -1;
    const box = asBox(p.?);
    box.core.grid_mu.lockUncancelable(clock.io());
    defer box.core.grid_mu.unlock(clock.io());
    return nextMsgTimeoutMsLocked(box);
}

/// Non-blocking version of zonvie_core_next_msg_timeout_ms.
/// Returns the same values on success, or -2 if the lock could not be
/// acquired. -2 is distinct from -1 ("no timeout pending" -- a real,
/// actionable answer) because the caller must NOT treat a busy lock as
/// "nothing pending": doing so could silently drop an armed msg_show/
/// msg_history/atlas maintenance deadline. On -2 the caller should re-arm its
/// timer for a short fixed retry instead of trusting a stale/absent value.
pub export fn zonvie_core_try_next_msg_timeout_ms(p: ?*zonvie_core) callconv(.c) i64 {
    if (p == null) return -2;
    const box = asBox(p.?);
    const acquired = box.core.grid_mu.tryLock();
    box.core.perf_lock_msg_timeout.record(acquired);
    if (!acquired) return -2;
    defer box.core.grid_mu.unlock(clock.io());
    return nextMsgTimeoutMsLocked(box);
}

/// Report whether the pointer rests on a message ext_float window. While
/// hovered the view's auto-hide countdown is stopped — the user is reading it,
/// or reaching for its copy button — and leaving restarts it at full length.
/// Ignores any grid that is not a message float.
///
/// Both transitions change the earliest pending deadline, so the caller must
/// re-arm its one-shot timer from zonvie_core_next_msg_timeout_ms afterwards.
pub export fn zonvie_core_set_msg_hover(p: ?*zonvie_core, grid_id: i64, hovered: i32) callconv(.c) void {
    if (p == null) return;
    const box = asBox(p.?);
    const ch: flush_mod.MsgChannel = switch (grid_id) {
        grid_mod.MESSAGE_GRID_ID => .show,
        grid_mod.MSG_HISTORY_GRID_ID => .history,
        else => return,
    };
    box.core.grid_mu.lockUncancelable(clock.io());
    defer box.core.grid_mu.unlock(clock.io());
    flush_mod.setChannelHover(&box.core, ch, hovered != 0);
}

pub export fn zonvie_core_set_blur_enabled(p: ?*zonvie_core, enabled: i32) callconv(.c) void {
    if (p == null) return;
    const box = asBox(p.?);
    box.core.blur_enabled = (enabled != 0);
}

/// Set inherit_cwd flag. Must be called before zonvie_core_start().
/// When enabled, child process inherits parent's CWD instead of $HOME.
pub export fn zonvie_core_set_inherit_cwd(p: ?*zonvie_core, enabled: i32) callconv(.c) void {
    if (p == null) return;
    const box = asBox(p.?);
    box.core.inherit_cwd = (enabled != 0);
}

pub export fn zonvie_core_set_background_opacity(p: ?*zonvie_core, opacity: f32) callconv(.c) void {
    if (p == null) return;
    const box = asBox(p.?);
    box.core.background_opacity = std.math.clamp(opacity, 0.0, 1.0);
}

/// Get list of visible grids for hit-testing.
/// Returns number of grids written (up to max_count).
pub export fn zonvie_core_get_visible_grids(
    p: ?*zonvie_core,
    out_grids: ?[*]GridInfo,
    max_count: usize,
) callconv(.c) usize {
    if (p == null or out_grids == null or max_count == 0) return 0;
    const box = asBox(p.?);
    return box.core.getVisibleGrids(out_grids.?[0..max_count]);
}

/// Non-blocking version of zonvie_core_get_visible_grids.
/// Returns grid count on success, or -1 if the lock could not be acquired.
/// Use this from the UI thread to avoid blocking when the core is in handleRedraw.
pub export fn zonvie_core_try_get_visible_grids(
    p: ?*zonvie_core,
    out_grids: ?[*]GridInfo,
    max_count: usize,
) callconv(.c) i32 {
    if (p == null or out_grids == null or max_count == 0) return -1;
    const box = asBox(p.?);
    if (box.core.tryGetVisibleGrids(out_grids.?[0..max_count])) |count| {
        return @intCast(count);
    }
    return -1;
}

/// Non-blocking visible-grid snapshot with truncation detection.
/// On success, returns the initialized prefix length and publishes the total
/// visible-grid count from the same grid lock acquisition. A zero-capacity
/// output is a valid count-only query. Busy or invalid calls return -1 without
/// changing either output.
pub export fn zonvie_core_try_get_visible_grids_complete(
    p: ?*zonvie_core,
    out_grids: ?[*]GridInfo,
    max_count: usize,
    out_total_count: ?*usize,
) callconv(.c) i32 {
    if (p == null or out_total_count == null or max_count > std.math.maxInt(i32)) return -1;
    if (max_count != 0 and out_grids == null) return -1;

    var empty: [0]GridInfo = .{};
    const out: []GridInfo = if (max_count == 0)
        empty[0..]
    else
        out_grids.?[0..max_count];
    const box = asBox(p.?);
    const snapshot = box.core.tryGetVisibleGridsComplete(out) orelse return -1;
    out_total_count.?.* = snapshot.total;
    return @intCast(snapshot.written);
}

/// Get viewport info for a specific grid (for scrollbar rendering).
/// Returns 1 if found, 0 if not found.
pub export fn zonvie_core_get_viewport(
    p: ?*zonvie_core,
    grid_id: i64,
    out_viewport: ?*ViewportInfo,
) callconv(.c) i32 {
    if (p == null or out_viewport == null) return 0;
    const box = asBox(p.?);
    return box.core.getViewportInfo(grid_id, out_viewport.?);
}

/// Non-blocking version of zonvie_core_get_viewport.
/// Returns 1 if found, 0 if not found, or -1 if the lock could not be acquired.
/// Use this from the UI thread to avoid blocking when the core is in handleRedraw.
pub export fn zonvie_core_try_get_viewport(
    p: ?*zonvie_core,
    grid_id: i64,
    out_viewport: ?*ViewportInfo,
) callconv(.c) i32 {
    if (p == null or out_viewport == null) return -1;
    const box = asBox(p.?);
    return box.core.tryGetViewportInfo(grid_id, out_viewport.?) orelse -1;
}

/// Borrow 'smoothscroll' for a grid's window while a trackpad gesture runs, and
/// hand it back afterwards. No-op off macOS. Returns 0 when the request could
/// not be issued (grid lock busy, or no window known yet) — the caller must try
/// again, which matters most for the restore.
pub export fn zonvie_core_set_gesture_smooth_scroll(
    p: ?*zonvie_core,
    grid_id: i64,
    enable: bool,
) callconv(.c) i32 {
    if (p == null) return 0;
    const box = asBox(p.?);
    return if (box.core.setGestureSmoothScroll(grid_id, enable)) 1 else 0;
}

/// Get current cursor position.
/// Returns the grid_id of the cursor.
pub export fn zonvie_core_get_cursor_position(
    p: ?*zonvie_core,
    out_row: ?*i32,
    out_col: ?*i32,
) callconv(.c) i64 {
    if (p == null) return -1;
    const box = asBox(p.?);
    const cursor = box.core.getCursorPosition();
    if (out_row) |r| r.* = cursor.row;
    if (out_col) |c| c.* = cursor.col;
    return cursor.grid_id;
}

/// Non-blocking version of zonvie_core_get_cursor_position.
/// Returns the grid_id of the cursor on success, or -2 if the lock could
/// not be acquired, or if core is null (grid_id is always >= 1, so -2 is
/// unambiguous either way). Note this differs from the blocking
/// zonvie_core_get_cursor_position above, which reserves -1 for null core.
pub export fn zonvie_core_try_get_cursor_position(
    p: ?*zonvie_core,
    out_row: ?*i32,
    out_col: ?*i32,
) callconv(.c) i64 {
    if (p == null) return -2;
    const box = asBox(p.?);
    const cursor = box.core.tryGetCursorPosition() orelse return -2;
    if (out_row) |r| r.* = cursor.row;
    if (out_col) |c| c.* = cursor.col;
    return cursor.grid_id;
}

/// Get Neovim window handle (winid) for a grid.
/// Pass grid_id=-1 to get the winid for the cursor's current grid.
/// Returns 0 if the mapping is not available.
pub export fn zonvie_core_get_win_id(p: ?*zonvie_core, grid_id: i64) callconv(.c) i64 {
    if (p == null) return 0;
    const box = asBox(p.?);
    box.core.grid_mu.lockUncancelable(clock.io());
    defer box.core.grid_mu.unlock(clock.io());
    return box.core.grid.getWinId(grid_id) orelse 0;
}

/// Get current mode name (e.g., "normal", "insert", "terminal").
/// Returns a thread-local null-terminated snapshot. Do not free.
/// Returns an empty string if core is null.
pub export fn zonvie_core_get_current_mode(p: ?*zonvie_core) callconv(.c) [*:0]const u8 {
    if (p == null) return "";
    const box = asBox(p.?);
    box.core.grid_mu.lockUncancelable(clock.io());
    defer box.core.grid_mu.unlock(clock.io());
    @memcpy(current_mode_snapshot[0..], box.core.grid.current_mode_name[0..]);
    current_mode_snapshot[current_mode_snapshot.len - 1] = 0;
    return @ptrCast(&current_mode_snapshot);
}

/// Check if cursor is visible (false during busy_start, true after busy_stop).
pub export fn zonvie_core_is_cursor_visible(p: ?*zonvie_core) callconv(.c) bool {
    if (p == null) return true;
    const box = asBox(p.?);
    box.core.grid_mu.lockUncancelable(clock.io());
    defer box.core.grid_mu.unlock(clock.io());
    return box.core.grid.cursor_visible;
}

/// Non-blocking combined read of current mode name + cursor visibility.
/// Copies the null-terminated mode name into out_mode_buf (truncated to fit
/// buf_len, including the terminator) and writes cursor visibility to
/// out_cursor_visible. Unlike zonvie_core_get_current_mode, the string is
/// copied while the lock is held rather than returning a pointer into core
/// memory that could be concurrently rewritten after unlock.
/// Returns 1 on success, -1 if the lock could not be acquired (caller
/// should keep using its last-known cached mode/visibility in that case).
/// -1 is also returned for invalid arguments (null core, null out_mode_buf,
/// buf_len == 0, or null out_cursor_visible) -- these share the busy
/// sentinel rather than a distinct value since no caller is expected to
/// pass invalid arguments in practice.
pub export fn zonvie_core_try_get_mode_state(
    p: ?*zonvie_core,
    out_mode_buf: ?[*]u8,
    buf_len: usize,
    out_cursor_visible: ?*bool,
) callconv(.c) i32 {
    if (p == null or out_mode_buf == null or buf_len == 0 or out_cursor_visible == null) return -1;
    const box = asBox(p.?);
    if (box.core.tryGetModeState(out_mode_buf.?, buf_len, out_cursor_visible.?)) return 1;
    return -1;
}

/// Get option_as_meta value (0=both, 1=none, 2=only_left, 3=only_right).
/// Set via RPC notification "zonvie_option_as_meta". Lock-free atomic read.
pub export fn zonvie_core_get_option_as_meta(p: ?*zonvie_core) callconv(.c) u8 {
    if (p == null) return 0;
    const box = asBox(p.?);
    return box.core.option_as_meta.load(.acquire);
}

/// Rows one wheel event scrolls: the 'ver' component of 'mousescroll'.
/// Reported by the auto-injected reporter (macOS only) and refreshed when the
/// option changes. Returns 0 for 'ver:0', which disables mouse scrolling in
/// Neovim rather than making it page-relative. Lock-free atomic read.
pub export fn zonvie_core_get_mousescroll_ver(p: ?*zonvie_core) callconv(.c) u32 {
    if (p == null) return 0;
    const box = asBox(p.?);
    return box.core.mousescroll_ver.load(.acquire);
}

/// Set option_as_meta initial value from config (0=both, 1=none, 2=only_left, 3=only_right).
pub export fn zonvie_core_set_option_as_meta(p: ?*zonvie_core, value: u8) callconv(.c) void {
    if (p == null) return;
    const box = asBox(p.?);
    box.core.option_as_meta.store(value, .release);
}

/// Write the three blink intervals into whichever out-pointers the caller
/// supplied. Shared by the blocking and try variants so a future fourth
/// interval cannot reach one and miss the other.
///
/// The caller owns grid_mu; this only reads under it.
fn writeCursorBlinkLocked(
    box: *CoreBox,
    out_wait_ms: ?*u32,
    out_on_ms: ?*u32,
    out_off_ms: ?*u32,
) void {
    if (out_wait_ms) |ptr| ptr.* = box.core.grid.cursor_blink_wait_ms;
    if (out_on_ms) |ptr| ptr.* = box.core.grid.cursor_blink_on_ms;
    if (out_off_ms) |ptr| ptr.* = box.core.grid.cursor_blink_off_ms;
}

/// Get current cursor blink parameters (in milliseconds).
pub export fn zonvie_core_get_cursor_blink(
    p: ?*zonvie_core,
    out_wait_ms: ?*u32,
    out_on_ms: ?*u32,
    out_off_ms: ?*u32,
) callconv(.c) void {
    if (p == null) {
        if (out_wait_ms) |ptr| ptr.* = 0;
        if (out_on_ms) |ptr| ptr.* = 0;
        if (out_off_ms) |ptr| ptr.* = 0;
        return;
    }
    const box = asBox(p.?);
    box.core.grid_mu.lockUncancelable(clock.io());
    defer box.core.grid_mu.unlock(clock.io());
    writeCursorBlinkLocked(box, out_wait_ms, out_on_ms, out_off_ms);
}

/// Non-blocking version of zonvie_core_get_cursor_blink. On success, fills
/// all three out params and returns true. On busy, leaves every out param
/// UNTOUCHED (does not write a "safe default") -- the intended usage is
/// for the caller to pre-seed the out params with its own last-known
/// values, so an untouched param is automatically "serve cached value".
/// Returns false if the lock could not be acquired or core is null.
pub export fn zonvie_core_try_get_cursor_blink(
    p: ?*zonvie_core,
    out_wait_ms: ?*u32,
    out_on_ms: ?*u32,
    out_off_ms: ?*u32,
) callconv(.c) bool {
    if (p == null) return false;
    const box = asBox(p.?);
    const acquired = box.core.grid_mu.tryLock();
    box.core.perf_lock_cursor_blink.record(acquired);
    if (!acquired) return false;
    defer box.core.grid_mu.unlock(clock.io());
    writeCursorBlinkLocked(box, out_wait_ms, out_on_ms, out_off_ms);
    return true;
}

/// Send mouse scroll event to Neovim.
///
/// Acquires grid_mu: sendMouseScroll's message-grid branch
/// (handleMsgGridScroll) mutates Grid/vertex/atlas-scratch state directly
/// and can invoke frontend callbacks (row_cb via sendExternalGridVerticesFiltered)
/// — the SAME state handleRedraw mutates under grid_mu on the RPC thread.
/// This is called directly from a mouse-wheel event on the UI thread, so
/// without this lock the two threads race HashMap/ArrayList/atlas-scratch
/// mutations. redraw_thread_id follows the same lock-then-set ordering as
/// zonvie_core_retry_flush (see its doc comment) so a re-entrant callback
/// from within sendExternalGridVerticesFiltered recognizes this thread as
/// the current owner instead of self-deadlocking on grid_mu.
pub export fn zonvie_core_send_mouse_scroll(
    p: ?*zonvie_core,
    grid_id: i64,
    row: i32,
    col: i32,
    direction: ?[*:0]const u8,
    modifier: ?[*:0]const u8,
) callconv(.c) void {
    if (p == null or direction == null) return;
    const box = asBox(p.?);
    const dir_str = std.mem.span(direction.?);
    const mod_str = if (modifier) |m| std.mem.span(m) else "";
    if (grid_id == grid_mod.MESSAGE_GRID_ID) {
        box.core.grid_mu.lockUncancelable(clock.io());
        box.core.redraw_thread_id.store(@intCast(std.Thread.getCurrentId()), .seq_cst);
        box.core.sendMouseScroll(grid_id, row, col, dir_str, mod_str);
        box.core.redraw_thread_id.store(0, .seq_cst);
        box.core.grid_mu.unlock(clock.io());
        return;
    }

    // Resolve the cursor-grid sentinel under grid_mu, but do not retain the
    // lock across allocation or the potentially blocking RPC transport write.
    var effective_id = grid_id;
    if (grid_id == -1) {
        box.core.grid_mu.lockUncancelable(clock.io());
        effective_id = box.core.grid.cursor_grid;
        box.core.grid_mu.unlock(clock.io());
    }
    box.core.sendMouseScroll(effective_id, row, col, dir_str, mod_str);
}

/// Scroll view to specified line number (1-based).
/// If use_bottom is true, positions line at screen bottom (zb), otherwise at top (zt).
pub export fn zonvie_core_scroll_to_line(
    p: ?*zonvie_core,
    line: i64,
    use_bottom: bool,
) callconv(.c) void {
    if (p == null) return;
    const box = asBox(p.?);
    box.core.scrollToLine(line, use_bottom);
}

/// Scroll a window by one page (Neovim's <C-f>/<C-b>).
/// grid_id: target grid (-1 for cursor grid / current window).
/// forward: true for page down, false for page up.
pub export fn zonvie_core_page_scroll(
    p: ?*zonvie_core,
    grid_id: i64,
    forward: bool,
) callconv(.c) void {
    if (p == null) return;
    const box = asBox(p.?);
    box.core.pageScroll(grid_id, forward);
}

/// Process pending message scroll update (for throttled scroll).
/// Call this after scroll events stop to ensure final position is rendered.
///
/// Acquires grid_mu — same rationale as zonvie_core_send_mouse_scroll:
/// processPendingMsgScroll mutates the same Grid/vertex/atlas-scratch state
/// and can invoke frontend callbacks, called from a UI-thread timer.
pub export fn zonvie_core_process_pending_msg_scroll(
    p: ?*zonvie_core,
) callconv(.c) void {
    _ = zonvie_core_process_pending_msg_scroll_retry_needed(p);
}

pub export fn zonvie_core_process_pending_msg_scroll_retry_needed(
    p: ?*zonvie_core,
) callconv(.c) bool {
    if (p == null) return false;
    const box = asBox(p.?);
    box.core.grid_mu.lockUncancelable(clock.io());
    box.core.redraw_thread_id.store(@intCast(std.Thread.getCurrentId()), .seq_cst);
    box.core.processPendingMsgScroll();
    const retry_needed = box.core.msg_scroll_pending;
    box.core.redraw_thread_id.store(0, .seq_cst);
    box.core.grid_mu.unlock(clock.io());
    return retry_needed;
}

/// Send mouse input event to Neovim (click, drag, release).
pub export fn zonvie_core_send_mouse_input(
    p: ?*zonvie_core,
    button: ?[*:0]const u8,
    action: ?[*:0]const u8,
    modifier: ?[*:0]const u8,
    grid_id: i64,
    row: i32,
    col: i32,
) callconv(.c) void {
    if (p == null or button == null or action == null) return;
    const box = asBox(p.?);
    const btn_str = std.mem.span(button.?);
    const act_str = std.mem.span(action.?);
    const mod_str = if (modifier) |m| std.mem.span(m) else "";
    box.core.sendMouseInput(btn_str, act_str, mod_str, grid_id, row, col);
}

/// Get highlight colors by group name (e.g., "Search", "Normal").
/// Returns 1 if found, 0 if not found.
pub export fn zonvie_core_get_hl_by_name(
    p: ?*zonvie_core,
    name: ?[*:0]const u8,
    fg_rgb: ?*u32,
    bg_rgb: ?*u32,
) callconv(.c) i32 {
    if (p == null or name == null) return 0;
    const box = asBox(p.?);
    const name_str = std.mem.span(name.?);
    const result = box.core.getHlByName(name_str);
    if (fg_rgb) |fg| fg.* = result.fg;
    if (bg_rgb) |bg| bg.* = result.bg;
    return if (result.found) 1 else 0;
}

/// Batched version of zonvie_core_get_hl_by_name: looks up `count` group
/// names under a single grid_mu acquisition instead of one lock round-trip
/// per name. names/out_fg_rgb/out_bg_rgb/out_found must each have length
/// count. A null entry in names writes 0/0/0 rather than leaving its slots
/// untouched, so a caller may pass uninitialized out arrays.
/// Returns 1 on success, 0 if core/arrays are null.
pub export fn zonvie_core_get_hl_by_names_batch(
    p: ?*zonvie_core,
    names: ?[*]const ?[*:0]const u8,
    out_fg_rgb: ?[*]u32,
    out_bg_rgb: ?[*]u32,
    out_found: ?[*]i32,
    count: usize,
) callconv(.c) i32 {
    if (p == null or names == null or out_fg_rgb == null or out_bg_rgb == null or out_found == null) return 0;
    const box = asBox(p.?);
    box.core.grid_mu.lockUncancelable(clock.io());
    defer box.core.grid_mu.unlock(clock.io());
    for (0..count) |i| {
        const name_ptr = names.?[i] orelse {
            // Written rather than skipped: every caller reads out_found[i]
            // unconditionally, and skipping left it reading uninitialized memory
            // while the function still reported success.
            out_fg_rgb.?[i] = 0;
            out_bg_rgb.?[i] = 0;
            out_found.?[i] = 0;
            continue;
        };
        const result = box.core.getHlByNameLocked(std.mem.span(name_ptr));
        out_fg_rgb.?[i] = result.fg;
        out_bg_rgb.?[i] = result.bg;
        out_found.?[i] = if (result.found) 1 else 0;
    }
    return 1;
}

/// Return the Neovim default background color as 0x00RRGGBB.
/// Safe to call from within callbacks (grid_mu already held) and from
/// any other thread (u32 read is atomic on arm64/x86_64).
pub export fn zonvie_core_get_default_bg(p: ?*zonvie_core) callconv(.c) u32 {
    if (p == null) return 0;
    const box = asBox(p.?);
    return box.core.hl.default_bg;
}

/// Check whether an external grid originated from a floating window
/// (nvim_open_win with external=true) as opposed to a regular split
/// window externalized by ext_windows mode.
/// Returns 1 if the grid is a float-origin external, 0 otherwise.
/// Thread-safe: acquires grid_mu.
pub export fn zonvie_core_is_float_external(p: ?*zonvie_core, grid_id: i64) callconv(.c) i32 {
    if (p == null) return 0;
    const box = asBox(p.?);
    box.core.grid_mu.lockUncancelable(clock.io());
    defer box.core.grid_mu.unlock(clock.io());
    const info = box.core.grid.external_grids.get(grid_id) orelse return 0;
    // start_row == -1 means no prior win_pos → created directly as external (float origin)
    return if (info.start_row < 0) 1 else 0;
}

/// Get the current emoji cluster context set during flush.
/// Returns a pointer to the cluster scalars and writes the count to out_len.
/// Valid only during on_rasterize_glyph callbacks (single-threaded flush context).
/// Returns null with *out_len=0 when no cluster context is active.
/// Returns the emoji cluster context from the core instance.
/// Valid only during on_rasterize_glyph callbacks (single-threaded flush context).
pub export fn zonvie_core_get_emoji_cluster(p: ?*zonvie_core, out_len: ?*u8) callconv(.c) ?[*]const u32 {
    if (p == null) {
        if (out_len) |ol| ol.* = 0;
        return null;
    }
    const box = asBox(p.?);
    const len = box.core.emoji_cluster_len;
    if (out_len) |ol| ol.* = len;
    if (len == 0) return null;
    return &box.core.emoji_cluster_buf;
}

/// Query whether post-process bloom glow is enabled (lock-free atomic read).
pub export fn zonvie_core_get_glow_enabled(p: ?*zonvie_core) callconv(.c) bool {
    if (p == null) return false;
    const box = asBox(p.?);
    return box.core.glow_enabled.load(.acquire);
}

/// Query the glow bloom intensity (0.0–1.0) for post-process composite (lock-free atomic read).
pub export fn zonvie_core_get_glow_intensity(p: ?*zonvie_core) callconv(.c) f32 {
    if (p == null) return 0.0;
    const box = asBox(p.?);
    return box.core.getGlowIntensity();
}

/// Read the current drawable/cell layout stored in core.
/// Intended for use from on_flush_end callback (grid_mu is held, so the
/// returned values match exactly what was used for the flush's NDC computation).
pub export fn zonvie_core_get_layout(
    p: ?*zonvie_core,
    out_dw: ?*u32,
    out_dh: ?*u32,
    out_cw: ?*u32,
    out_ch: ?*u32,
) callconv(.c) void {
    if (p == null) {
        if (out_dw) |ptr| ptr.* = 0;
        if (out_dh) |ptr| ptr.* = 0;
        if (out_cw) |ptr| ptr.* = 0;
        if (out_ch) |ptr| ptr.* = 0;
        return;
    }
    const box = asBox(p.?);
    if (out_dw) |ptr| ptr.* = box.core.drawable_w_px;
    if (out_dh) |ptr| ptr.* = box.core.drawable_h_px;
    if (out_cw) |ptr| ptr.* = box.core.cell_w_px;
    if (out_ch) |ptr| ptr.* = box.core.cell_h_px;
}

// ========================================================================
// Message routing API
// ========================================================================

/// Convert an internal view type to the one the frontends receive.
///
/// The arms are written out rather than expressed as
/// `@enumFromInt(@intFromEnum(view))`, and that is the whole point of this
/// function. The exhaustive switch with no `else` is a compile-time guard:
/// adding a variant to `config.MsgViewType` breaks the build here and forces
/// a decision about what it means on the wire. A numeric cast would compile
/// unchanged and ship an out-of-range `c_int` -- which neither frontend
/// rejects, since macOS falls through to ext_float and Windows to mini.
///
/// Do not replace the arm list. The identity is only correct because both
/// enums, and include/zonvie_core.h, pin the same six values.
pub fn msgViewTypeToC(view: config.MsgViewType) zonvie_msg_view_type {
    return switch (view) {
        .mini => .mini,
        .ext_float => .ext_float,
        .confirm => .confirm,
        .split => .split,
        .none => .none,
        .notification => .notification,
    };
}

/// Message view type (C ABI compatible - must match C enum size)
pub const zonvie_msg_view_type = enum(c_int) {
    mini = 0,
    ext_float = 1,
    confirm = 2,
    split = 3,
    none = 4,
    notification = 5,
};

/// Message event type (C ABI compatible - must match C enum size)
pub const zonvie_msg_event = enum(c_int) {
    msg_show = 0,
    msg_showmode = 1,
    msg_showcmd = 2,
    msg_ruler = 3,
    msg_history_show = 4,
};

/// Result of routing a message
pub const zonvie_route_result = extern struct {
    view: zonvie_msg_view_type,
    timeout: f32, // -1 = no auto-hide, 0 = use default
};

/// Load config from file path.
/// Returns 1 on success, 0 on failure.
pub export fn zonvie_core_load_config(
    p: ?*zonvie_core,
    path: ?[*:0]const u8,
) callconv(.c) i32 {
    if (p == null or path == null) return 0;
    const box = asBox(p.?);
    const path_str = std.mem.span(path.?);

    // Deinit old config first
    box.msg_config.deinit();

    // Load new config
    box.msg_config = config.Config.loadFromPath(box.allocator(), path_str);
    box.msg_config.alloc = box.allocator();

    // Also update nvim_core's config reference
    box.core.msg_config = box.msg_config;

    // Reset config error notification flag so new errors get reported
    box.core.config_error_sent = false;

    // Apply performance settings to core
    const new_hl_size = box.msg_config.performance.hl_cache_size;
    if (new_hl_size != box.core.hl_cache_size) {
        box.core.hl_cache_size = new_hl_size;
        box.core.reinitHlCache();
    }
    const new_shape_size = box.msg_config.performance.shape_cache_size;
    if (new_shape_size != box.core.shape_cache_size) {
        box.core.setShapeCacheSize(new_shape_size);
    }

    return 1;
}

/// Route a message to the appropriate view based on config.
/// Returns the view type and timeout for the given event, kind, and line count.
pub export fn zonvie_core_route_message(
    p: ?*zonvie_core,
    event: zonvie_msg_event,
    kind: ?[*:0]const u8,
    line_count: u32,
) callconv(.c) zonvie_route_result {
    // Default result: ext_float with 4 second timeout
    const default_result = zonvie_route_result{
        .view = .ext_float,
        .timeout = 4.0,
    };

    if (p == null) return default_result;
    const box = asBox(p.?);

    // Convert C event enum to config event enum
    const cfg_event: config.MsgEvent = switch (event) {
        .msg_show => .msg_show,
        .msg_showmode => .msg_showmode,
        .msg_showcmd => .msg_showcmd,
        .msg_ruler => .msg_ruler,
        .msg_history_show => .msg_history_show,
    };

    // Get kind string
    const kind_str = if (kind) |k| std.mem.span(k) else "";

    // Route using config (line_count used for min_lines/max_lines filters)
    const route_result = box.msg_config.routeMessage(cfg_event, kind_str, line_count);

    // Convert config view type to C view type
    const c_view = msgViewTypeToC(route_result.view);

    return zonvie_route_result{
        .view = c_view,
        .timeout = route_result.timeout,
    };
}

// ========================================================================
// Standalone config API (independent of zonvie_core)
// ========================================================================

pub const zonvie_config = opaque {};

/// Source for the `font.*`, `window.*` and `performance.*` defaults below,
/// so `zonvie_config_get_values(NULL)` reports what a config-less run really
/// uses. Those groups are the ones that had gone wrong: the two cache sizes
/// each diverged in a separate commit, and the macOS-only window translucency
/// and font size were written out with the non-macOS values from the start.
/// The remaining fields are still hand-copied; the test at the end of this
/// file is what keeps every one of them honest.
const cfg_defaults: config.Config = .{};

pub const zonvie_config_values = extern struct {
    // font
    font_family: [*:0]const u8 = "",
    font_size: f32 = cfg_defaults.font.size,
    font_linespace: i32 = cfg_defaults.font.linespace,
    // True when the user explicitly set [font] family / size in config.toml.
    // Frontends should prefer config over nvim's default `guifont`.
    font_family_explicit: bool = false,
    font_size_explicit: bool = false,
    // window
    window_blur: bool = cfg_defaults.window.blur,
    window_opacity: f32 = cfg_defaults.window.opacity,
    window_blur_radius: i32 = cfg_defaults.window.blur_radius,
    // scrollbar
    scrollbar_enabled: bool = true,
    scrollbar_show_mode: [*:0]const u8 = "scroll",
    scrollbar_opacity: f32 = 0.7,
    scrollbar_delay: f32 = 1.0,
    // ext features
    cmdline_external: bool = false,
    cmdline_copy_button: bool = true,
    popup_external: bool = false,
    messages_external: bool = false,
    messages_copy_button: bool = true,
    messages_ext_float_pos: i32 = 0, // 0=window, 1=grid, 2=display
    messages_mini_pos: i32 = 1, // 0=window, 1=grid, 2=display
    tabline_external: bool = false,
    tabline_style: [*:0]const u8 = "titlebar",
    tabline_sidebar_position: [*:0]const u8 = "left",
    tabline_sidebar_width: i32 = 200,
    tabline_agent_indicator: bool = true,
    tabline_agent_notification: bool = true,
    windows_external: bool = false,
    // neovim
    neovim_path: [*:0]const u8 = "nvim",
    neovim_ssh: bool = false,
    neovim_ssh_host: ?[*:0]const u8 = null,
    neovim_ssh_port: i32 = 0,
    neovim_ssh_identity: ?[*:0]const u8 = null,
    // log
    log_enabled: bool = false,
    log_path: ?[*:0]const u8 = null,
    log_perf_only: bool = false,
    log_scroll_only: bool = false,
    log_verbose: bool = false,
    // performance
    perf_glyph_cache_ascii: i32 = @intCast(cfg_defaults.performance.glyph_cache_ascii_size),
    perf_glyph_cache_non_ascii: i32 = @intCast(cfg_defaults.performance.glyph_cache_non_ascii_size),
    perf_hl_cache_size: i32 = @intCast(cfg_defaults.performance.hl_cache_size),
    perf_shape_cache_size: i32 = @intCast(cfg_defaults.performance.shape_cache_size),
    perf_atlas_size: i32 = @intCast(cfg_defaults.performance.atlas_size),
    // ime
    ime_disable_on_activate: bool = false,
    ime_disable_on_modechange: bool = false,
    ime_option_as_meta: u8 = 0, // 0=both, 1=none, 2=only_left, 3=only_right
    // shaders (custom post-process). Path array accessed via
    // zonvie_config_get_shader_count / zonvie_config_get_shader_path.
    shader_enabled: bool = false,
    shader_post_process: u8 = 0, // 0=after_bloom, 1=before_bloom, 2=replace_bloom
    shader_preserve_alpha: bool = false, // keep terminal alpha through the shader bridge
    // input
    input_swap_colon_semicolon: bool = false, // swap `:` and `;` on single keypresses
    // server (single-instance file open). single_instance is Windows-only and
    // read directly from config.Config by the Windows frontend, so it is not
    // mirrored here.
    server_open_mode: [*:0]const u8 = "tab", // "tab" or "current"
};

const ConfigHandle = struct {
    arena: std.heap.ArenaAllocator,
    cfg: config.Config,
    values: zonvie_config_values,
    // Null-terminated copies of cfg.shaders.paths, arena-owned.
    shader_paths_c: []?[*:0]const u8 = &.{},
};

fn dupeZForC(alloc: std.mem.Allocator, s: []const u8, fallback: [*:0]const u8) [*:0]const u8 {
    const z = alloc.dupeZ(u8, s) catch return fallback;
    return z.ptr;
}

fn dupeZForCOpt(alloc: std.mem.Allocator, s: ?[]const u8) ?[*:0]const u8 {
    const str = s orelse return null;
    const z = alloc.dupeZ(u8, str) catch return null;
    return z.ptr;
}

fn msgPosToInt(pos: config.MsgPosition) i32 {
    return switch (pos) {
        .window => 0,
        .grid => 1,
        .display => 2,
    };
}

fn buildConfigValues(alloc: std.mem.Allocator, cfg: *const config.Config) zonvie_config_values {
    // Format the user-supplied (or default) family string into a
    // newline-separated `<name>\t<size>[\t<features>]` list so the
    // frontend can reuse the same parser as for nvim's `guifont`
    // payload. See `config.formatFontFamilyAsCandidateList`.
    //
    // On formatter / dupe failure (only OOM in practice) we emit a
    // well-formed minimal single entry instead of falling back to the
    // raw comma-separated `cfg.font.family`: the frontend expects a
    // newline-separated candidate list, so handing it the unformatted
    // string would make it treat the whole list as one font name.
    const default_size_pt: f64 = if (cfg.font.size > 0) cfg.font.size else 14.0;
    const fallback_name: []const u8 = if (@import("builtin").os.tag == .macos) "Menlo" else "Consolas";
    const family_list_z: [*:0]const u8 = blk: {
        if (config.formatFontFamilyAsCandidateList(
            alloc,
            cfg.font.family,
            default_size_pt,
            fallback_name,
        )) |formatted| {
            if (alloc.dupeZ(u8, formatted)) |z| break :blk z.ptr else |_| {}
        } else |_| {}
        if (std.fmt.allocPrint(alloc, "{s}\t{d}", .{ fallback_name, default_size_pt })) |fb| {
            if (alloc.dupeZ(u8, fb)) |z| break :blk z.ptr else |_| {}
        } else |_| {}
        break :blk dupeZForC(alloc, "", "Menlo");
    };

    return .{
        // font
        .font_family = family_list_z,
        .font_size = cfg.font.size,
        .font_linespace = cfg.font.linespace,
        .font_family_explicit = cfg.font.family_explicit,
        .font_size_explicit = cfg.font.size_explicit,
        // window
        .window_blur = cfg.window.blur,
        .window_opacity = cfg.window.opacity,
        .window_blur_radius = cfg.window.blur_radius,
        // scrollbar
        .scrollbar_enabled = cfg.scrollbar.enabled,
        .scrollbar_show_mode = dupeZForC(alloc, cfg.scrollbar.show_mode, "scroll"),
        .scrollbar_opacity = cfg.scrollbar.opacity,
        .scrollbar_delay = cfg.scrollbar.delay,
        // ext features
        .cmdline_external = cfg.cmdline.external,
        .cmdline_copy_button = cfg.cmdline.copy_button,
        .popup_external = cfg.popup.external,
        .messages_external = cfg.messages.external,
        .messages_copy_button = cfg.messages.copy_button,
        .messages_ext_float_pos = msgPosToInt(cfg.messages.msg_pos.ext_float),
        .messages_mini_pos = msgPosToInt(cfg.messages.msg_pos.mini),
        .tabline_external = cfg.tabline.external,
        .tabline_style = dupeZForC(alloc, cfg.tabline.style, "titlebar"),
        .tabline_sidebar_position = dupeZForC(alloc, cfg.tabline.sidebar_position, "left"),
        .tabline_sidebar_width = @intCast(cfg.tabline.sidebar_width),
        .tabline_agent_indicator = cfg.tabline.agent_indicator,
        .tabline_agent_notification = cfg.tabline.agent_notification,
        .windows_external = cfg.windows.external,
        // neovim
        .neovim_path = dupeZForC(alloc, cfg.neovim.path, "nvim"),
        .neovim_ssh = cfg.neovim.ssh,
        .neovim_ssh_host = dupeZForCOpt(alloc, cfg.neovim.ssh_host),
        .neovim_ssh_port = if (cfg.neovim.ssh_port) |p| @as(i32, @intCast(p)) else 0,
        .neovim_ssh_identity = dupeZForCOpt(alloc, cfg.neovim.ssh_identity),
        // log
        .log_enabled = cfg.log.enabled,
        .log_path = dupeZForCOpt(alloc, cfg.log.path),
        .log_perf_only = cfg.log.perf_only,
        .log_scroll_only = cfg.log.scroll_only,
        .log_verbose = cfg.log.verbose,
        // performance
        .perf_glyph_cache_ascii = @intCast(cfg.performance.glyph_cache_ascii_size),
        .perf_glyph_cache_non_ascii = @intCast(cfg.performance.glyph_cache_non_ascii_size),
        .perf_hl_cache_size = @intCast(cfg.performance.hl_cache_size),
        .perf_shape_cache_size = @intCast(cfg.performance.shape_cache_size),
        .perf_atlas_size = @intCast(cfg.performance.atlas_size),
        // ime (config surface lives in [input])
        .ime_disable_on_activate = cfg.input.ime_disable_on_activate,
        .ime_disable_on_modechange = cfg.input.ime_disable_on_modechange,
        .ime_option_as_meta = @intFromEnum(cfg.input.option_as_meta),
        // shaders
        .shader_enabled = cfg.shaders.enabled,
        .shader_post_process = @intFromEnum(cfg.shaders.post_process),
        .shader_preserve_alpha = cfg.shaders.preserve_alpha,
        // input
        .input_swap_colon_semicolon = cfg.input.swap_colon_semicolon,
        // server
        .server_open_mode = dupeZForC(alloc, cfg.server.open_mode, "tab"),
    };
}

/// Load config from TOML file. path may be NULL for defaults only.
/// Returns opaque handle; call zonvie_config_destroy when done.
pub export fn zonvie_config_load(path: ?[*:0]const u8) callconv(.c) ?*zonvie_config {
    const handle = std.heap.page_allocator.create(ConfigHandle) catch return null;
    handle.arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const arena_alloc = handle.arena.allocator();

    if (path) |p| {
        const path_str = std.mem.span(p);
        handle.cfg = config.Config.loadFromPath(arena_alloc, path_str);
    } else {
        handle.cfg = config.Config{};
    }
    handle.cfg.alloc = arena_alloc;

    handle.values = buildConfigValues(arena_alloc, &handle.cfg);
    handle.shader_paths_c = buildShaderPathArray(arena_alloc, &handle.cfg);
    return @ptrCast(handle);
}

fn buildShaderPathArray(alloc: std.mem.Allocator, cfg: *const config.Config) []?[*:0]const u8 {
    if (cfg.shaders.paths.len == 0) return &.{};
    const c_paths = alloc.alloc(?[*:0]const u8, cfg.shaders.paths.len) catch return &.{};
    for (cfg.shaders.paths, 0..) |p, i| {
        c_paths[i] = dupeZForCOpt(alloc, p);
    }
    return c_paths;
}

/// Get flat config values from handle.
pub export fn zonvie_config_get_values(p: ?*const zonvie_config) callconv(.c) zonvie_config_values {
    if (p == null) return zonvie_config_values{};
    const handle: *const ConfigHandle = @ptrCast(@alignCast(p.?));
    return handle.values;
}

/// Number of configured custom shader passes.
pub export fn zonvie_config_get_shader_count(p: ?*const zonvie_config) callconv(.c) u32 {
    if (p == null) return 0;
    const handle: *const ConfigHandle = @ptrCast(@alignCast(p.?));
    return @intCast(handle.shader_paths_c.len);
}

/// Get the i-th custom shader path as a null-terminated C string.
/// Returns NULL if index out of range or allocation failed.
/// String is valid until zonvie_config_destroy.
pub export fn zonvie_config_get_shader_path(p: ?*const zonvie_config, index: u32) callconv(.c) ?[*:0]const u8 {
    if (p == null) return null;
    const handle: *const ConfigHandle = @ptrCast(@alignCast(p.?));
    if (index >= handle.shader_paths_c.len) return null;
    return handle.shader_paths_c[index];
}

/// Free config handle and all associated memory.
pub export fn zonvie_config_destroy(p: ?*zonvie_config) callconv(.c) void {
    if (p == null) return;
    const handle: *ConfigHandle = @ptrCast(@alignCast(p.?));
    handle.arena.deinit();
    std.heap.page_allocator.destroy(handle);
}

/// Non-blocking check whether a cell's highlight has a URL attribute.
/// Returns: 1 = has url, 0 = no url, -1 = lock unavailable.
pub export fn zonvie_core_try_cell_has_url(
    p: ?*zonvie_core,
    grid_id: i64,
    row: i32,
    col: i32,
) callconv(.c) i32 {
    if (p == null) return 0;
    if (row < 0 or col < 0) return 0;
    const box = asBox(p.?);
    if (!box.core.grid_mu.tryLock()) return -1;
    defer box.core.grid_mu.unlock(clock.io());
    const hl_id = box.core.grid.getCellHLGrid(grid_id, @intCast(row), @intCast(col));
    const attr = box.core.hl.map.get(hl_id) orelse return 0;
    return if (attr.has_url) @as(i32, 1) else @as(i32, 0);
}

/// Truncating UTF-8 sink for zonvie_core_try_get_grid_text. `needed` keeps
/// counting past `cap` so the caller learns the exact size to retry with.
const GridTextSink = struct {
    buf: ?[*]u8,
    cap: usize,
    needed: usize = 0,
    written: usize = 0,

    fn pushBytes(self: *GridTextSink, src: []const u8) void {
        self.needed += src.len;
        const buf = self.buf orelse return;
        for (src) |ch| {
            if (self.written >= self.cap) return;
            buf[self.written] = ch;
            self.written += 1;
        }
    }

    fn pushCodepoint(self: *GridTextSink, cp: u32) void {
        const cp21 = std.math.cast(u21, cp) orelse return;
        var scratch: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(cp21, &scratch) catch return;
        self.pushBytes(scratch[0..n]);
    }
};

/// Non-blocking extraction of a grid's rendered text as UTF-8.
///
/// Rows are joined with '\n' and each row is trimmed of trailing blanks; a
/// wide glyph's continuation cell (cp == 0) contributes nothing. Backs the
/// frontends' "copy content" button on the decorated ext_cmdline /
/// ext_messages surfaces, so it must never block the UI thread: the core
/// thread holds `grid_mu` for the whole of handleRedraw and its callbacks
/// can wait on the UI thread, so a blocking lock here would deadlock.
///
/// Returns the byte length the full text needs (NUL terminator excluded),
/// or -1 when the grid lock is unavailable. When the return value is
/// <= out_cap the buffer holds the complete text.
pub export fn zonvie_core_try_get_grid_text(
    p: ?*zonvie_core,
    grid_id: i64,
    out_buf: ?[*]u8,
    out_cap: usize,
) callconv(.c) isize {
    if (p == null) return 0;
    const box = asBox(p.?);
    if (!box.core.grid_mu.tryLock()) return -1;
    defer box.core.grid_mu.unlock(clock.io());

    const g = &box.core.grid;
    var rows: u32 = 0;
    var cols: u32 = 0;
    if (grid_id == 1) {
        rows = g.rows;
        cols = g.cols;
    } else if (g.sub_grids.getPtr(grid_id)) |sg| {
        rows = sg.rows;
        cols = sg.cols;
    } else {
        return 0;
    }

    // `needed` counts the full text; `written` only what fit in out_buf, so
    // a caller with a too-small buffer learns the exact size to retry with.
    var sink = GridTextSink{ .buf = out_buf, .cap = out_cap };

    // Newlines are emitted lazily so a run of blank rows costs nothing until
    // a row with content follows; trailing blank rows produce no newlines.
    var pending_newlines: usize = 0;
    var row: u32 = 0;
    while (row < rows) : (row += 1) {
        // Trim trailing blanks by locating the last meaningful cell first.
        var last_non_blank: ?u32 = null;
        var probe: u32 = 0;
        while (probe < cols) : (probe += 1) {
            const cell = g.getCellGrid(grid_id, row, probe);
            if (cell.cp != 0 and cell.cp != ' ') last_non_blank = probe;
        }
        const end_col = if (last_non_blank) |lc| lc + 1 else 0;
        if (end_col == 0) {
            if (sink.needed > 0) pending_newlines += 1;
            continue;
        }
        while (pending_newlines > 0) : (pending_newlines -= 1) sink.pushBytes("\n");
        if (sink.needed > 0 and row > 0) sink.pushBytes("\n");

        var col: u32 = 0;
        while (col < end_col) : (col += 1) {
            const cell = g.getCellGrid(grid_id, row, col);
            // cp == 0 is a wide glyph's continuation cell: it has no text.
            if (cell.cp == 0) continue;
            sink.pushCodepoint(cell.cp);
            if (g.getOverflow(grid_id, row, col)) |extras| {
                for (extras) |extra_cp| sink.pushCodepoint(extra_cp);
            }
        }
    }
    const needed = sink.needed;

    return std.math.cast(isize, needed) orelse std.math.maxInt(isize);
}

// Invalidate glyph cache, shape cache, and atlas state.
// Mirrors onGuifont invalidation sequence (flush.zig).
// Must be called on core thread (e.g. from on_flush_begin callback).
pub export fn zonvie_core_invalidate_glyph_cache(p: ?*zonvie_core) callconv(.c) void {
    if (p == null) return;
    const box = asBox(p.?);
    box.core.resetGlyphCacheFlags();
    box.core.resetShapeCache();
    if (box.core.isPhase2Atlas()) {
        box.core.resetCoreAtlas();
    }
    // Scroll cache stores vertices with atlas UVs; invalidate after atlas reset.
    box.core.invalidateScrollCache();
    box.core.grid.markAllDirty();
    // Bump content_rev so the flush's need_main check passes even when
    // Neovim has not changed any cells (e.g. backing-scale change only).
    box.core.grid.content_rev +%= 1;
    // Every sub_grid's cached row vertices hold stale atlas UVs / font
    // metrics too. sg.dirty alone is not enough: the per-row emit path
    // checks dirty_rows to decide which rows to regenerate, so with no
    // bits set every row is skipped and dirty gets cleared at flush end
    // with nothing ever actually resent — markAllDirty() sets both.
    var sg_it = box.core.grid.sub_grids.valueIterator();
    while (sg_it.next()) |sg| {
        sg.markAllDirty();
    }
    // The main cursor's own regen check is gated on cursor_rev alone (not
    // content_rev/dirty_all), and an external grid's cursor is a separate
    // vertex consumer again — neither is covered by the dirtying above, so
    // both would keep rendering with the stale atlas UVs/font metrics this
    // call exists to invalidate.
    box.core.grid.cursor_rev +%= 1;
}

// Abort the current flush cycle.
// Called from on_flush_begin when the frontend cannot accept this flush.
pub export fn zonvie_core_abort_flush(p: ?*zonvie_core) callconv(.c) void {
    if (p == null) return;
    const box = asBox(p.?);
    box.core.flush_aborted = true;
}

// Terminate a rendering session after a frontend-side fixed resource budget
// rejects capacity provisioning. Safe from the asynchronous provision worker.
pub export fn zonvie_core_fail_render_budget(p: ?*zonvie_core) callconv(.c) void {
    if (p == null) return;
    const cp = &asBox(p.?).core;
    cp.failHardRender(error.VertexBudgetExceeded);
    cp.wakeRpcReaderForHardFailure();
}

// Mark every grid (main + all sub_grids/external grids) and the cursor
// dirty. Shared by zonvie_core_force_resend/_locked below.
//
// markAllDirty() alone only covers the MAIN grid (dirty_all). A frontend
// failure discovered after onFlush already consumed dirty state can affect
// ANY of: external grid rows, main cursor, external cursor, or the vacated
// area of an external grid's cursor after it moved — main-grid-only
// resend leaves those stale, since each sub_grid tracks its own
// dirty/dirty_rows independently and cursor_rev is a separate revision
// counter entirely. Cursor is bumped once (not per-grid): Neovim has a
// single active cursor at a time (tracked via cursor_grid/cursor_row/
// cursor_col), so one cursor_rev bump covers whichever grid currently
// owns it, main or external.
fn forceResendAll(cp: *core.Core) void {
    cp.grid.markAllDirty();
    var sub_it = cp.grid.sub_grids.iterator();
    while (sub_it.next()) |entry| {
        entry.value_ptr.markAllDirty();
    }
    cp.grid.cursor_rev +%= 1;
    // A prior failed flush may have moved the cursor between external
    // grids without the old grid ever actually receiving its empty-cursor
    // update (see force_ext_cursor_recheck's doc comment) — force every
    // external grid to re-check its cursor state once rather than relying
    // on last_ext_cursor_grid, which cannot be trusted to still name the
    // right stale grid in that scenario.
    cp.force_ext_cursor_recheck = true;
}

// Force every grid to be treated as dirty on the next flush attempt.
// This is for failures discovered outside the on_flush_begin/on_flush_end
// transaction, after onFlush returned and can no longer observe
// zonvie_core_abort_flush. Content the frontend failed to store is then
// regenerated instead of silently staying missing/stale.
// Call zonvie_core_retry_flush afterward (or rely on the next Neovim
// redraw) to actually drive that next attempt.
//
// Takes grid_mu itself — call ONLY from a context that does not already
// hold it (e.g. a main-thread timer). on_flush_begin/on_flush_end run on
// the core/RPC thread with grid_mu held for the ENTIRE handleRedraw
// duration (rpc_session.zig); calling this from there would self-deadlock
// on the non-recursive std.Io.Mutex. Those callbacks must use
// zonvie_core_force_resend_locked instead.
pub export fn zonvie_core_force_resend(p: ?*zonvie_core) callconv(.c) void {
    if (p == null) return;
    const box = asBox(p.?);
    const cp = &box.core;
    cp.grid_mu.lockUncancelable(clock.io());
    defer cp.grid_mu.unlock(clock.io());
    forceResendAll(cp);
}

// Same effect as zonvie_core_force_resend, but for callers that ALREADY
// hold grid_mu — specifically on_flush_begin/on_flush_end, which run on the
// core/RPC thread for the entire handleRedraw duration. Calling the
// locking variant from there deadlocks on the non-recursive grid_mu.
pub export fn zonvie_core_force_resend_locked(p: ?*zonvie_core) callconv(.c) void {
    if (p == null) return;
    const box = asBox(p.?);
    forceResendAll(&box.core);
}

// Returns true when the flush that JUST ran (i.e. inside the current
// on_flush_begin/on_flush_end pair) detected an atlas reset during the
// deferred external-grid pass, after main vertices for this same flush were
// already dispatched with pre-reset UVs. Call from on_flush_end, BEFORE
// committing, while grid_mu is still held (no locking needed here — this is
// a plain field read, safe under the caller's existing grid_mu hold, same
// as flush_aborted's internal-only reads). When true, the frontend must
// cancel this flush's commit entirely (treat exactly like an allocation
// failure: cancel brackets instead of publishing them) — committing would
// present main-grid vertices sampling the wrong (freshly repacked) atlas
// for one frame. The core has already scheduled a corrected full resend for
// the next flush (markAllDirty), so cancelling here is purely about not
// showing the corrupted frame; no data is lost.
pub export fn zonvie_core_flush_had_atlas_corruption(p: ?*zonvie_core) callconv(.c) bool {
    if (p == null) return false;
    const box = asBox(p.?);
    return box.core.flush_atlas_corrupted;
}

// Returns true when the flush that JUST ran was aborted — either by an
// explicit frontend zonvie_core_abort_flush() call, or by an internal Zig
// error (e.g. OOM growing a persistent composition buffer) caught inside
// onFlush itself. Call from on_flush_end, BEFORE committing, while grid_mu
// is still held (plain field read, same as flush_had_atlas_corruption).
// When true, the frontend must cancel this flush's commit — whatever
// partial write-set was composed before the abort is incomplete and must
// not be presented as a full frame. Dirty state is preserved either way, so
// cancelling loses no data; call zonvie_core_retry_flush once frontend
// capacity recovers (or after an internal-error backoff) to resend it.
pub export fn zonvie_core_flush_was_aborted(p: ?*zonvie_core) callconv(.c) bool {
    if (p == null) return false;
    const box = asBox(p.?);
    return box.core.flush_aborted;
}

/// Whether retrying the just-aborted flush can make progress. Fixed budget
/// violations are hard failures and must not arm frontend retry loops.
pub export fn zonvie_core_flush_is_retryable(p: ?*zonvie_core) callconv(.c) bool {
    if (p == null) return false;
    return asBox(p.?).core.flush_retryable;
}

// Retry a flush that was previously aborted by the frontend (backpressure —
// no free triple-buffer set, all GPU-in-flight — or a mid-flush frontend
// OOM). Aborting preserves the core's dirty state, but flushes are
// otherwise only driven by incoming Neovim redraw batches (handleRedraw ->
// onFlush): if the buggy/busy condition clears (a GPU frame completes,
// memory pressure eases) with no further redraw event arriving, the
// pending content would sit unflushed forever with a stale screen.
// Frontends should call this once they recover capacity (e.g. a one-shot
// retry timer armed right after the abort, mirroring the existing
// TIMER_CURSOR_BLINK_RETRY / TIMER_SCROLLBAR_RETRY idiom).
//
// Calls onFlush() UNCONDITIONALLY rather than gating on a "something is
// pending" check. An earlier version only checked main content_rev/
// dirty_all, which silently dropped retries for cursor-only updates
// (cursor_rev vs last_sent_cursor_rev is a separate predicate — and the
// row-mode cursor path syncs last_sent_cursor_rev before any abort check
// can run) and external/subgrid-only updates (each sub_grid tracks its own
// dirty flag, not reflected in the main grid's content_rev at all). Rather
// than growing this into a predicate that has to enumerate every kind of
// pending state (main/cursor/subgrid/external — and stay in sync with
// every future addition), just run the real flush: onFlush already
// short-circuits internally into near-zero work when nothing is actually
// dirty (the same path every no-op Neovim redraw batch already takes,
// e.g. a msg_showcmd-only flush), so the cost of an unconditional call
// when nothing was pending is one wasted triple-buffer bracket open/close
// — bounded, since this only runs once per one-shot retry timer fire, not
// as a repeating poll.
fn retryFlushLocked(cp: *nvim_core.Core) void {
    if (cp.stop_flag.load(.acquire) or !cp.flush_retryable) return;
    cp.redraw_thread_id.store(@intCast(std.Thread.getCurrentId()), .seq_cst);
    defer {
        // Clear the owner id while grid_mu is still held. Both callers keep
        // the lock through this helper, so another thread cannot acquire the
        // mutex and publish its own redraw_thread_id before this store.
        cp.redraw_thread_id.store(0, .seq_cst);
    }

    var fctx = flush_mod.FlushCtx{ .core = cp };
    flush_mod.FlushCtx.onFlush(&fctx, cp.grid.rows, cp.grid.cols) catch |reason| {
        if (nvim_core.Core.isHardRenderFailure(reason)) cp.failHardRender(reason);
    };
}

pub export fn zonvie_core_retry_flush(p: ?*zonvie_core) callconv(.c) void {
    if (p == null) return;
    const box = asBox(p.?);
    const cp = &box.core;
    if (cp.stop_flag.load(.acquire)) return;

    // Acquire grid_mu FIRST, then record the calling thread (here, whatever
    // thread the frontend's retry timer fires on — main/UI, not the usual
    // core/RPC thread) as the current handleRedraw-equivalent owner.
    //
    // Storing BEFORE the lock (as forceGlowFlush in rpc_session.zig does —
    // safe there because it always runs on the single RPC thread that also
    // owns redraw_thread_id) would race here: if the RPC thread is
    // concurrently mid-handleRedraw (grid_mu held, its OWN tid already in
    // redraw_thread_id) when this UI-thread call overwrites
    // redraw_thread_id with the UI tid before blocking on the lock, a
    // re-entrant zonvie_core_update_layout_px() call ON THE RPC THREAD
    // (e.g. row_cb -> update_layout_px, a documented re-entrant path) would
    // no longer see redraw_thread_id == its own tid, conclude it must
    // acquire grid_mu itself, and self-deadlock on the lock it already
    // holds. Storing only after this call's own lockUncancelable() returns
    // guarantees the RPC thread is no longer inside handleRedraw (mutual
    // exclusion via grid_mu already ensures that), so this store can never
    // clobber a live owner's id.
    cp.grid_mu.lockUncancelable(clock.io());
    defer cp.grid_mu.unlock(clock.io());
    if (cp.stop_flag.load(.acquire)) return;
    retryFlushLocked(cp);
}

// Variant for a frontend that already holds grid_mu. This lets a retry timer
// acquire grid_mu, revalidate its own generation against a just-completed
// normal redraw, and only then execute the retry without an unlock/relock race.
//
// MUST NOT be called from inside a flush bracket (on_flush_begin/on_flush_end)
// even though those also run with grid_mu held: the nested onFlush trips
// beginVertexBudgetTransaction's already-active guard, which is classified as a
// hard render failure and terminates the nvim child with unsaved buffers.
pub export fn zonvie_core_retry_flush_locked(p: ?*zonvie_core) callconv(.c) void {
    if (p == null) return;
    const box = asBox(p.?);
    retryFlushLocked(&box.core);
}

// Acquire grid_mu from a frontend (UI) thread.
//
// Lets a frontend run a multi-step state mutation (e.g. atlas rebuild +
// updateLayoutPx + invalidate_glyph_cache) atomically with respect to the
// RPC thread's handleRedraw cycle, in the same way that the original
// in-flush onGuifont path is atomic. The caller MUST balance every lock
// with zonvie_core_unlock_grid and MUST NOT call any core API that itself
// tries to acquire grid_mu while holding it (use the *_locked variants).
pub export fn zonvie_core_lock_grid(p: ?*zonvie_core) callconv(.c) void {
    if (p == null) return;
    const box = asBox(p.?);
    box.core.grid_mu.lockUncancelable(clock.io());
}

pub export fn zonvie_core_unlock_grid(p: ?*zonvie_core) callconv(.c) void {
    if (p == null) return;
    const box = asBox(p.?);
    box.core.grid_mu.unlock(clock.io());
}

// updateLayoutPx variant for callers that already hold grid_mu (typically
// via zonvie_core_lock_grid). Skips the redraw_thread_id check and the
// internal grid_mu acquisition that the regular API performs.
pub export fn zonvie_core_update_layout_px_locked(
    p: ?*zonvie_core,
    drawable_w_px: u32,
    drawable_h_px: u32,
    cell_w_px: u32,
    cell_h_px: u32,
) callconv(.c) void {
    if (p == null) return;
    const box = asBox(p.?);
    _ = box.core.updateLayoutPxLocked(drawable_w_px, drawable_h_px, cell_w_px, cell_h_px);
}

// ========================================================================
// Custom shader cross-compilation API
// ========================================================================
//
// Input: Shadertoy / Ghostty compatible GLSL fragment shader source.
// Output: compiled source in the target shading language (MSL or HLSL).
// Implementation: glslang (GLSL -> SPIR-V) + SPIRV-Cross (SPIR-V -> target).

pub const zonvie_shader_target = enum(c_int) {
    msl = 0, // Metal Shading Language
    hlsl = 1, // HLSL (shader model 5.0)
};

comptime {
    if (@sizeOf(zonvie_shader_target) != @sizeOf(c_int) or
        @alignOf(zonvie_shader_target) != @alignOf(c_int))
    {
        @compileError("zonvie_shader_target must match the C enum ABI");
    }
}

/// Per-frame Shadertoy-style uniforms. Layout matches the std140
/// `ZonvieShaderUniforms` block emitted by `shader_compiler.zig`'s
/// Shadertoy preamble; keep this struct and the C header version
/// (`zonvie_shader_uniforms` in `include/zonvie_core.h`) in lock-step.
/// Total size is 160 bytes; field ordering is load-bearing.
///
/// iResolution is the main window's drawable size for every view, so the
/// shader sees a single coordinate space across windows. iWindowOffset
/// and iWindowSize describe the current view's rectangle within that
/// space. For the main window itself, iWindowOffset is (0,0) and
/// iWindowSize == iResolution.xy.
pub const zonvie_shader_uniforms = extern struct {
    iResolution: [3]f32 = .{ 0, 0, 0 }, // 0..11
    iTime: f32 = 0, // 12..15 (packs into iResolution's trailing std140 slot)
    // Shadertoy iMouse (xy = cursor px, zw = click px). NOT implemented
    // today — the frontends never update this block, so shaders that
    // read iMouse see all zeroes. Kept in the ABI for future plumbing.
    iMouse: [4]f32 = .{ 0, 0, 0, 0 }, // 16..31
    iDate: [4]f32 = .{ 0, 0, 0, 0 }, // 32..47
    iTimeDelta: f32 = 0, // 48..51
    iFrame: i32 = 0, // 52..55
    iSampleRate: f32 = 44100.0, // 56..59
    iFrameRate: f32 = 60.0, // 60..63
    iWindowOffset: [2]f32 = .{ 0, 0 }, // 64..71
    iWindowSize: [2]f32 = .{ 0, 0 }, // 72..79
    // Cursor state (Ghostty 1.1+ custom-shader compatibility). Rect is
    // (x, y, w, h) in drawable pixels within the shader "screen"
    // universe (the main window). Color is straight (non-premultiplied)
    // RGBA in [0, 1]. iTimeCursorChange is the value of iTime at the
    // moment the cursor position or color last changed.
    iCurrentCursor: [4]f32 = .{ 0, 0, 0, 0 }, // 80..95
    iPreviousCursor: [4]f32 = .{ 0, 0, 0, 0 }, // 96..111
    iCurrentCursorColor: [4]f32 = .{ 0, 0, 0, 0 }, // 112..127
    iPreviousCursorColor: [4]f32 = .{ 0, 0, 0, 0 }, // 128..143
    iTimeCursorChange: f32 = 0, // 144..147
    _pad_cursor: [3]f32 = .{ 0, 0, 0 }, // 148..159 — keep UBO size %16==0
};

comptime {
    std.debug.assert(@sizeOf(zonvie_shader_uniforms) == 160);
}

/// Result of a shader compile. Owns an internal allocation; the caller must
/// invoke zonvie_shader_result_destroy exactly once to release it.
pub const zonvie_shader_result = extern struct {
    /// Null-terminated compiled source; NULL on failure.
    data: ?[*:0]const u8 = null,
    /// Length of data, excluding the null terminator.
    data_len: usize = 0,
    /// Null-terminated error message; NULL on success.
    error_msg: ?[*:0]const u8 = null,
    /// Opaque pointer used by zonvie_shader_result_destroy.
    internal: ?*anyopaque = null,
};

const ShaderResultHandle = struct {
    alloc: std.mem.Allocator,
    data: ?[:0]u8,
    error_msg: ?[:0]u8,
};

fn buildShaderError(comptime msg: []const u8) zonvie_shader_result {
    const gpa = std.heap.page_allocator;
    const handle = gpa.create(ShaderResultHandle) catch {
        return .{};
    };
    handle.* = .{
        .alloc = gpa,
        .data = null,
        .error_msg = gpa.dupeZ(u8, msg) catch null,
    };
    return .{
        .data = null,
        .data_len = 0,
        .error_msg = if (handle.error_msg) |s| s.ptr else null,
        .internal = @ptrCast(handle),
    };
}

fn buildShaderSuccess(alloc: std.mem.Allocator, compiled: []u8) zonvie_shader_result {
    const handle = alloc.create(ShaderResultHandle) catch {
        alloc.free(compiled);
        return buildShaderError("out of memory");
    };
    // Null-terminate for C consumers.
    const data_z = alloc.allocSentinel(u8, compiled.len, 0) catch {
        alloc.free(compiled);
        alloc.destroy(handle);
        return buildShaderError("out of memory");
    };
    @memcpy(data_z, compiled);
    alloc.free(compiled);
    handle.* = .{
        .alloc = alloc,
        .data = data_z,
        .error_msg = null,
    };
    return .{
        .data = data_z.ptr,
        .data_len = data_z.len,
        .error_msg = null,
        .internal = @ptrCast(handle),
    };
}

/// Compile a GLSL fragment shader (Shadertoy/Ghostty style) to the target
/// shading language. The returned result owns its buffers; pass it to
/// zonvie_shader_result_destroy to release them.
pub export fn zonvie_shader_compile_glsl(
    glsl_source: ?[*]const u8,
    glsl_len: usize,
    target: zonvie_shader_target,
) callconv(.c) zonvie_shader_result {
    if (glsl_source == null or glsl_len == 0) {
        return buildShaderError("empty shader source");
    }
    const src: []const u8 = glsl_source.?[0..glsl_len];
    const gpa = std.heap.page_allocator;
    const t: shader_compiler.Target = switch (target) {
        .msl => .msl,
        .hlsl => .hlsl,
    };
    const compiled = shader_compiler.compileGlslToTarget(gpa, src, t) catch |err| {
        return switch (err) {
            error.EmptySource => buildShaderError("empty shader source"),
            error.ParseFailed => buildShaderError("GLSL parse failed"),
            error.LinkFailed => buildShaderError("GLSL link failed"),
            error.SpirvGenFailed => buildShaderError("SPIR-V generation failed"),
            error.CrossCompileFailed => buildShaderError("SPIR-V cross-compile failed"),
            error.OutOfMemory => buildShaderError("out of memory"),
        };
    };
    return buildShaderSuccess(gpa, compiled);
}

/// Release the internal allocation held by a result. Safe to call on a
/// default-initialized / already-destroyed result; the function is a no-op
/// when internal is NULL.
pub export fn zonvie_shader_result_destroy(result: ?*zonvie_shader_result) callconv(.c) void {
    const r = result orelse return;
    const internal = r.internal orelse return;
    const handle: *ShaderResultHandle = @ptrCast(@alignCast(internal));
    if (handle.data) |d| handle.alloc.free(d);
    if (handle.error_msg) |e| handle.alloc.free(e);
    handle.alloc.destroy(handle);
    r.internal = null;
    r.data = null;
    r.data_len = 0;
    r.error_msg = null;
}

test "the exported route API reports every view as its matching ABI view" {
    // This is the only conversion site reachable with every view: the two
    // msg_show sites are called from one arm that only ever holds mini,
    // confirm and notification, and the status site early-returns on none.
    // Without this, the split and none arms are dead in every test and a
    // shared helper could get them wrong unnoticed.
    const p = zonvie_core_create(null, 0, null) orelse return error.OutOfMemory;
    defer zonvie_core_destroy(p);

    // "confirm" and the interactive-prompt kinds are pinned to their own views
    // upstream of the user routes, so the kinds here are deliberately inert.
    var routes = [_]config.MsgRoute{
        .{ .filter = .{ .kinds = &.{"k_mini"} }, .view = .mini },
        .{ .filter = .{ .kinds = &.{"k_float"} }, .view = .ext_float },
        .{ .filter = .{ .kinds = &.{"k_conf"} }, .view = .confirm },
        .{ .filter = .{ .kinds = &.{"k_split"} }, .view = .split },
        .{ .filter = .{ .kinds = &.{"k_none"} }, .view = .none },
        .{ .filter = .{ .kinds = &.{"k_notify"} }, .view = .notification },
    };
    asBox(p).msg_config.messages.routes = &routes;

    const cases = [_]struct { kind: [*:0]const u8, expect: zonvie_msg_view_type }{
        .{ .kind = "k_mini", .expect = .mini },
        .{ .kind = "k_float", .expect = .ext_float },
        .{ .kind = "k_conf", .expect = .confirm },
        .{ .kind = "k_split", .expect = .split },
        .{ .kind = "k_none", .expect = .none },
        .{ .kind = "k_notify", .expect = .notification },
    };
    for (cases) |case| {
        const result = zonvie_core_route_message(p, .msg_show, case.kind, 1);
        try std.testing.expectEqualStrings(@tagName(case.expect), @tagName(result.view));
    }
}

test "the null-handle config values match what a default config would build" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const built = buildConfigValues(arena.allocator(), &cfg_defaults);
    const declared: zonvie_config_values = .{};

    inline for (@typeInfo(zonvie_config_values).@"struct".fields) |f| {
        // font_family is the one field the null path cannot reproduce: the
        // candidate list is formatted into allocated memory, and there is no
        // allocator to format it into when the handle is NULL.
        if (comptime std.mem.eql(u8, f.name, "font_family")) continue;

        const built_v = @field(built, f.name);
        const declared_v = @field(declared, f.name);
        switch (@typeInfo(f.type)) {
            .pointer => try std.testing.expectEqualStrings(std.mem.span(built_v), std.mem.span(declared_v)),
            .optional => {
                try std.testing.expectEqual(built_v == null, declared_v == null);
                if (built_v != null) {
                    try std.testing.expectEqualStrings(std.mem.span(built_v.?), std.mem.span(declared_v.?));
                }
            },
            else => try std.testing.expectEqual(built_v, declared_v),
        }
    }
}
