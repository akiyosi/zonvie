const std = @import("std");
const core = @import("nvim_core.zig");
pub const config = @import("config.zig");

pub const Cell = extern struct {
    scalar: u32,
    fgRGB: u32,
    bgRGB: u32,
};

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
    blink_wait_ms: u32,  // wait time before blink starts (ms), 0=no blink
    blink_on_ms: u32,    // on time for blink cycle (ms)
    blink_off_ms: u32,   // off time for blink cycle (ms)
};

pub const BgSpan = extern struct {
    row: u32,
    col_start: u32, // inclusive
    col_end: u32, // exclusive
    bgRGB: u32, // 0x00RRGGBB
};

pub const TextRun = extern struct {
    row: u32,
    col_start: u32,
    len: u32, // number of UTF-32 scalars / cells
    fgRGB: u32, // 0x00RRGGBB
    bgRGB: u32, // 0x00RRGGBB
    scalars: [*]const u32, // points to len scalars (valid only during callback)
};

pub const OnRenderPlanFn = *const fn (
    ctx: ?*anyopaque,
    bg_spans: [*]const BgSpan,
    bg_span_count: usize,
    text_runs: [*]const TextRun,
    text_run_count: usize,
    rows: u32,
    cols: u32,
    cursor: ?*const Cursor,
) callconv(.c) void;

pub const OnFrameFn = *const fn (
    ctx: ?*anyopaque,
    cells: [*]const Cell,
    cell_count: usize,
    rows: u32,
    cols: u32,
    cursor: ?*const Cursor,
) callconv(.c) void;

// Decoration flags (must match ZONVIE_DECO_* in zonvie_core.h)
pub const DECO_UNDERCURL: u32 = 1 << 0;
pub const DECO_UNDERLINE: u32 = 1 << 1;
pub const DECO_UNDERDOUBLE: u32 = 1 << 2;
pub const DECO_UNDERDOTTED: u32 = 1 << 3;
pub const DECO_UNDERDASHED: u32 = 1 << 4;
pub const DECO_STRIKETHROUGH: u32 = 1 << 5;
pub const DECO_CURSOR: u32 = 1 << 6; // Marker for cursor vertices (not a decoration, used to preserve cursor from transparency)

pub const Vertex = extern struct {
    position: [2]f32,
    texCoord: [2]f32,
    color: [4]f32 align(16), // 16-byte alignment to match Swift simd_float4
    grid_id: i64, // 1 = main grid, >1 = sub-grid (float window)
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

pub const OnVerticesFn = *const fn (
    ctx: ?*anyopaque,
    main_verts: [*]const Vertex,
    main_count: usize,
    cursor_verts: [*]const Vertex,
    cursor_count: usize,
) callconv(.c) void;

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
};

/// Viewport info for scrollbar rendering
pub const ViewportInfo = extern struct {
    grid_id: i64,
    topline: i64,      // First visible line (0-based)
    botline: i64,      // First line below window (exclusive)
    line_count: i64,   // Total lines in buffer
    curline: i64,      // Current cursor line
    curcol: i64,       // Current cursor column
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

pub const Callbacks = extern struct {
    on_vertices: ?OnVerticesFn = null,

    on_vertices_partial: ?OnVerticesPartialFn = null,
    on_vertices_row: ?OnVerticesRowFn = null,

    on_atlas_ensure_glyph: ?AtlasEnsureGlyphFn = null,
    on_atlas_ensure_glyph_styled: ?AtlasEnsureGlyphStyledFn = null,

    on_render_plan: ?OnRenderPlanFn = null,

    on_log: ?*const fn (ctx: ?*anyopaque, p: [*]const u8, n: usize) callconv(.c) void = null,

    on_guifont: ?*const fn (ctx: ?*anyopaque, p: [*]const u8, n: usize) callconv(.c) void = null,
    on_linespace: ?*const fn (ctx: ?*anyopaque, linespace_px: i32) callconv(.c) void = null,

    on_exit: ?*const fn (ctx: ?*anyopaque, exit_code: i32) callconv(.c) void = null,
    on_set_title: ?*const fn (ctx: ?*anyopaque, title: [*]const u8, title_len: usize) callconv(.c) void = null,

    // External window callbacks (ext_multigrid)
    on_external_window: ?*const fn (ctx: ?*anyopaque, grid_id: i64, win: i64, rows: u32, cols: u32, start_row: i32, start_col: i32) callconv(.c) void = null,
    on_external_window_close: ?*const fn (ctx: ?*anyopaque, grid_id: i64) callconv(.c) void = null,
    on_external_vertices: ?*const fn (ctx: ?*anyopaque, grid_id: i64, verts: [*]const Vertex, vert_count: usize, rows: u32, cols: u32) callconv(.c) void = null,

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

    // Grid scroll notification (for clearing smooth scroll pixel offset)
    on_grid_scroll: ?*const fn (ctx: ?*anyopaque, grid_id: i64) callconv(.c) void = null,

    // IME off notification (for mode change or RPC zonvie_ime_off)
    on_ime_off: ?*const fn (ctx: ?*anyopaque) callconv(.c) void = null,

    // Quit request notification (window close with unsaved buffer check)
    on_quit_requested: ?*const fn (ctx: ?*anyopaque, has_unsaved: c_int) callconv(.c) void = null,
};

pub const zonvie_render_plan = opaque {};

pub const zonvie_core = opaque {};

const CoreBox = struct {
    // Own an allocator for the core lifetime.
    gpa: std.heap.GeneralPurposeAllocator(.{}) = .{},

    core: core.Core = undefined,
    cb: Callbacks = .{},
    ctx: ?*anyopaque = null,

    // Config for message routing
    msg_config: config.Config = .{},

    fn allocator(self: *CoreBox) std.mem.Allocator {
        return self.gpa.allocator();
    }
};

fn asBox(p: *zonvie_core) *CoreBox {
    return @ptrCast(@alignCast(p));
}

pub export fn zonvie_core_create(cb: ?*const Callbacks, ctx: ?*anyopaque) ?*zonvie_core {
    const box = std.heap.c_allocator.create(CoreBox) catch return null;

    // Initialize box state.
    box.* = .{
        .gpa = .{},
        .core = undefined,
        .cb = if (cb) |p| p.* else .{},
        .ctx = ctx,
    };

    // Build core.Callbacks from the C-facing callback struct.
    const cb_core: core.Callbacks = .{
        .on_vertices = box.cb.on_vertices,

        .on_vertices_partial = box.cb.on_vertices_partial,
        .on_vertices_row = box.cb.on_vertices_row,

        .on_atlas_ensure_glyph = box.cb.on_atlas_ensure_glyph,
        .on_atlas_ensure_glyph_styled = box.cb.on_atlas_ensure_glyph_styled,
        .on_render_plan = box.cb.on_render_plan,

        .on_log = box.cb.on_log,

        .on_guifont = box.cb.on_guifont,
        .on_linespace = box.cb.on_linespace,

        .on_exit = box.cb.on_exit,
        .on_set_title = box.cb.on_set_title,

        .on_external_window = box.cb.on_external_window,
        .on_external_window_close = box.cb.on_external_window_close,
        .on_external_vertices = box.cb.on_external_vertices,

        .on_cursor_grid_changed = box.cb.on_cursor_grid_changed,

        // ext_cmdline callbacks
        .on_cmdline_show = box.cb.on_cmdline_show,
        .on_cmdline_hide = box.cb.on_cmdline_hide,
        .on_cmdline_pos = box.cb.on_cmdline_pos,
        .on_cmdline_special_char = box.cb.on_cmdline_special_char,
        .on_cmdline_block_show = box.cb.on_cmdline_block_show,
        .on_cmdline_block_append = box.cb.on_cmdline_block_append,
        .on_cmdline_block_hide = box.cb.on_cmdline_block_hide,

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

        // Grid scroll notification
        .on_grid_scroll = box.cb.on_grid_scroll,

        // IME off notification
        .on_ime_off = box.cb.on_ime_off,

        // Quit request notification
        .on_quit_requested = box.cb.on_quit_requested,
    };

    box.core = core.Core.init(box.allocator(), cb_core, ctx);

    return @ptrCast(box);
}

pub export fn zonvie_core_destroy(p: ?*zonvie_core) callconv(.c) void {
    if (p == null) return;
    const box = asBox(p.?);
    box.core.stop();
    _ = box.gpa.deinit();
    std.heap.c_allocator.destroy(box);
}

pub export fn zonvie_core_start(p: ?*zonvie_core, nvim_path_c: ?[*:0]const u8, rows: u32, cols: u32) callconv(.c) i32 {
    if (p == null) return -1;
    const box = asBox(p.?);
    const nvim_path = if (nvim_path_c) |s| std.mem.span(s) else "nvim";
    box.core.start(nvim_path, rows, cols) catch return -2;
    return 0;
}

pub export fn zonvie_core_stop(p: ?*zonvie_core) callconv(.c) void {
    if (p == null) return;
    const box = asBox(p.?);
    box.core.stop();
}

pub export fn zonvie_core_send_input(p: ?*zonvie_core, keys: [*]const u8, len: usize) callconv(.c) void {
    if (p == null) return;
    const box = asBox(p.?);
    box.core.sendInput(keys[0..len]);
}

/// Send a Neovim command (via nvim_command API, does not show in cmdline)
pub export fn zonvie_core_send_command(p: ?*zonvie_core, cmd: [*]const u8, len: usize) callconv(.c) void {
    if (p == null) return;
    const box = asBox(p.?);
    box.core.requestCommand(cmd[0..len]) catch {};
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
    box.core.resize(rows, cols);
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
    box.core.updateLayoutPx(drawable_w_px, drawable_h_px, cell_w_px, cell_h_px);
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

pub export fn zonvie_core_set_log_enabled(p: ?*zonvie_core, enabled: i32) callconv(.c) void {
    if (p == null) return;
    const box = asBox(p.?);

    const on = enabled != 0;
    // Logger.write() is a no-op when cb is null.
    box.core.log.cb = if (on) box.cb.on_log else null;
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

/// Enable ext_messages UI extension. Must be called before zonvie_core_start().
/// When enabled, message events are sent to frontend callbacks instead of being
/// rendered in the main grid. Messages are displayed as external floating windows.
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

/// Check if msg_show throttle timeout has expired and process pending messages.
/// Frontend should call this periodically (e.g., every frame or 16ms) to ensure
/// messages are displayed even when Neovim is waiting for user input.
pub export fn zonvie_core_tick_msg_throttle(p: ?*zonvie_core) callconv(.c) void {
    if (p == null) return;
    const box = asBox(p.?);
    box.core.checkMsgShowThrottleTimeout();
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

/// Get current mode name (e.g., "normal", "insert", "terminal").
/// Returns pointer to null-terminated string. Do not free.
/// Returns null if core is null.
pub export fn zonvie_core_get_current_mode(p: ?*zonvie_core) callconv(.c) [*:0]const u8 {
    if (p == null) return "";
    const box = asBox(p.?);
    box.core.grid_mu.lock();
    defer box.core.grid_mu.unlock();
    // Return pointer to the internal buffer (null-terminated)
    return @ptrCast(&box.core.grid.current_mode_name);
}

/// Check if cursor is visible (false during busy_start, true after busy_stop).
pub export fn zonvie_core_is_cursor_visible(p: ?*zonvie_core) callconv(.c) bool {
    if (p == null) return true;
    const box = asBox(p.?);
    box.core.grid_mu.lock();
    defer box.core.grid_mu.unlock();
    return box.core.grid.cursor_visible;
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
    box.core.grid_mu.lock();
    defer box.core.grid_mu.unlock();
    if (out_wait_ms) |ptr| ptr.* = box.core.grid.cursor_blink_wait_ms;
    if (out_on_ms) |ptr| ptr.* = box.core.grid.cursor_blink_on_ms;
    if (out_off_ms) |ptr| ptr.* = box.core.grid.cursor_blink_off_ms;
}

/// Send mouse scroll event to Neovim.
pub export fn zonvie_core_send_mouse_scroll(
    p: ?*zonvie_core,
    grid_id: i64,
    row: i32,
    col: i32,
    direction: ?[*:0]const u8,
) callconv(.c) void {
    if (p == null or direction == null) return;
    const box = asBox(p.?);
    const dir_str = std.mem.span(direction.?);
    box.core.sendMouseScroll(grid_id, row, col, dir_str);
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

/// Process pending message scroll update (for throttled scroll).
/// Call this after scroll events stop to ensure final position is rendered.
pub export fn zonvie_core_process_pending_msg_scroll(
    p: ?*zonvie_core,
) callconv(.c) void {
    if (p == null) return;
    const box = asBox(p.?);
    box.core.processPendingMsgScroll();
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

// ========================================================================
// Message routing API
// ========================================================================

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
    const c_view: zonvie_msg_view_type = switch (route_result.view) {
        .mini => .mini,
        .ext_float => .ext_float,
        .confirm => .confirm,
        .split => .split,
        .none => .none,
        .notification => .notification,
    };

    return zonvie_route_result{
        .view = c_view,
        .timeout = route_result.timeout,
    };
}
