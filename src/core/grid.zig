const std = @import("std");
const Highlights = @import("highlight.zig").Highlights;

/// Reserved grid ID for ext_cmdline (displayed as external window).
/// Using a large negative value to avoid collision with Neovim's grid IDs.
pub const CMDLINE_GRID_ID: i64 = -100;

/// Reserved grid ID for ext_popupmenu (displayed as external window).
pub const POPUPMENU_GRID_ID: i64 = -101;

/// Reserved grid ID for ext_tabline (displayed as Chrome-style tabs in titlebar).
pub const TABLINE_GRID_ID: i64 = -104;

pub const Cell = struct {
    cp: u32,
    hl: u32,
};

pub const CursorShape = enum(u8) { block, vertical, horizontal };

// ext_cmdline types

/// A single highlighted chunk in cmdline content (Zig-managed, not C ABI).
pub const CmdlineChunk = struct {
    hl_id: u32,
    text: []const u8,
};

/// State for a single cmdline level.
pub const CmdlineState = struct {
    content: std.ArrayListUnmanaged(CmdlineChunk) = .{},
    pos: u32 = 0, // cursor position
    firstc: u8 = 0, // ':' '/' '?' etc.
    prompt: []const u8 = "",
    indent: u32 = 0,
    level: u32 = 1,
    prompt_hl_id: u32 = 0,
    // Fixed buffer for special_char (copied from arena memory)
    special_char_buf: [8]u8 = .{0} ** 8,
    special_char_len: u8 = 0,
    special_shift: bool = false,
    visible: bool = false,

    pub fn deinit(self: *CmdlineState, alloc: std.mem.Allocator) void {
        // Free all duped text in chunks
        for (self.content.items) |chunk| {
            if (chunk.text.len > 0) {
                alloc.free(chunk.text);
            }
        }
        self.content.deinit(alloc);
        self.content = .{};
        // Free duped prompt
        if (self.prompt.len > 0) {
            alloc.free(self.prompt);
            self.prompt = "";
        }
    }

    pub fn clear(self: *CmdlineState, alloc: std.mem.Allocator) void {
        // Free all duped text in chunks
        for (self.content.items) |chunk| {
            if (chunk.text.len > 0) {
                alloc.free(chunk.text);
            }
        }
        self.content.clearRetainingCapacity();
        // Free duped prompt
        if (self.prompt.len > 0) {
            alloc.free(self.prompt);
        }
        self.pos = 0;
        self.firstc = 0;
        self.prompt = "";
        self.indent = 0;
        self.prompt_hl_id = 0;
        self.special_char_len = 0;
        self.special_shift = false;
        self.visible = false;
    }

    pub fn getSpecialChar(self: *const CmdlineState) []const u8 {
        return self.special_char_buf[0..self.special_char_len];
    }

    pub fn setSpecialChar(self: *CmdlineState, c: []const u8) void {
        const len = @min(c.len, self.special_char_buf.len);
        @memcpy(self.special_char_buf[0..len], c[0..len]);
        self.special_char_len = @intCast(len);
    }
};

/// State for cmdline block (multi-line input).
pub const CmdlineBlock = struct {
    /// Each line is an array of chunks
    lines: std.ArrayListUnmanaged(std.ArrayListUnmanaged(CmdlineChunk)) = .{},
    visible: bool = false,

    pub fn deinit(self: *CmdlineBlock, alloc: std.mem.Allocator) void {
        for (self.lines.items) |*line| {
            // Free duped text in each chunk
            for (line.items) |chunk| {
                if (chunk.text.len > 0) {
                    alloc.free(chunk.text);
                }
            }
            line.deinit(alloc);
        }
        self.lines.deinit(alloc);
        self.lines = .{};
    }

    pub fn clear(self: *CmdlineBlock, alloc: std.mem.Allocator) void {
        for (self.lines.items) |*line| {
            // Free duped text in each chunk
            for (line.items) |chunk| {
                if (chunk.text.len > 0) {
                    alloc.free(chunk.text);
                }
            }
            line.deinit(alloc);
        }
        self.lines.clearRetainingCapacity();
        self.visible = false;
    }
};

// ext_messages types

/// Reserved grid ID for ext_messages (displayed as external window).
pub const MESSAGE_GRID_ID: i64 = -102;

/// Reserved grid ID for msg_history_show (displayed as external window).
pub const MSG_HISTORY_GRID_ID: i64 = -103;

/// A single highlighted chunk in message content (same structure as CmdlineChunk).
pub const MsgChunk = struct {
    hl_id: u32,
    text: []const u8,
};

/// A single message from Neovim's ext_messages.
pub const Message = struct {
    id: i64 = 0, // msg_id from Neovim
    kind: []const u8 = "", // "emsg", "echo", etc.
    content: std.ArrayListUnmanaged(MsgChunk) = .{},
    history: bool = false, // added to :messages
    append: bool = false, // append to previous
    replace_last: bool = false, // replace last message

    pub fn deinit(self: *Message, alloc: std.mem.Allocator) void {
        // Free duped text in chunks
        for (self.content.items) |chunk| {
            if (chunk.text.len > 0) {
                alloc.free(chunk.text);
            }
        }
        self.content.deinit(alloc);
        self.content = .{};
        // Free duped kind
        if (self.kind.len > 0) {
            alloc.free(self.kind);
            self.kind = "";
        }
    }

    pub fn clear(self: *Message, alloc: std.mem.Allocator) void {
        // Free duped text in chunks
        for (self.content.items) |chunk| {
            if (chunk.text.len > 0) {
                alloc.free(chunk.text);
            }
        }
        self.content.clearRetainingCapacity();
        // Free duped kind
        if (self.kind.len > 0) {
            alloc.free(self.kind);
            self.kind = "";
        }
        self.id = 0;
        self.history = false;
        self.append = false;
    }
};

/// State for ext_messages.
/// Pending message snapshot for sending to frontend (survives msg_clear)
pub const PendingMessage = struct {
    kind: [32]u8 = undefined,
    kind_len: usize = 0,
    text: [4096]u8 = undefined,
    text_len: usize = 0,
    hl_id: u32 = 0,
    replace_last: bool = false,
    history: bool = false,
    append: bool = false,
    id: i64 = 0,
};

/// Singleton confirm message (noice.nvim pattern: confirm lifecycle = cmdline lifecycle).
/// Zero-alloc: fixed-size buffers matching PendingMessage pattern.
pub const ConfirmMessage = struct {
    kind: [32]u8 = undefined,
    kind_len: usize = 0,
    text: [4096]u8 = undefined,
    text_len: usize = 0,
    hl_id: u32 = 0,
    id: i64 = 0,
    active: bool = false,

    pub fn clear(self: *ConfirmMessage) void {
        self.active = false;
        self.kind_len = 0;
        self.text_len = 0;
        self.hl_id = 0;
        self.id = 0;
    }

    /// Append text to existing confirm message (for append semantics).
    pub fn appendText(self: *ConfirmMessage, text: []const u8) void {
        const copy_len = @min(text.len, self.text.len - self.text_len);
        @memcpy(self.text[self.text_len..][0..copy_len], text[0..copy_len]);
        self.text_len += copy_len;
    }
};

pub const MessageState = struct {
    messages: std.ArrayListUnmanaged(Message) = .{},
    showmode_content: std.ArrayListUnmanaged(MsgChunk) = .{},
    showcmd_content: std.ArrayListUnmanaged(MsgChunk) = .{},
    ruler_content: std.ArrayListUnmanaged(MsgChunk) = .{},
    visible: bool = false,
    /// Dirty flag for msg_show/msg_clear changes
    msg_dirty: bool = false,
    /// Singleton confirm message (separated from messages list per noice.nvim pattern)
    confirm_msg: ConfirmMessage = .{},
    /// Dirty flag for confirm message changes
    confirm_dirty: bool = false,
    /// Set by setMsgClear within an RPC batch. Ensures on_msg_clear is sent to the
    /// frontend even when new msg_show events follow in the same batch.
    /// Reset by notifyMessageChanges after processing.
    msg_cleared_in_batch: bool = false,
    /// Dirty flag for showmode changes
    showmode_dirty: bool = false,
    /// Dirty flag for showcmd changes
    showcmd_dirty: bool = false,
    /// Dirty flag for ruler changes
    ruler_dirty: bool = false,
    /// Pending msg_show events that need to be sent to frontend.
    /// These survive msg_clear within the same redraw frame.
    pending_messages: [8]PendingMessage = undefined,
    pending_count: usize = 0,

    pub fn deinit(self: *MessageState, alloc: std.mem.Allocator) void {
        for (self.messages.items) |*msg| {
            msg.deinit(alloc);
        }
        self.messages.deinit(alloc);
        self.messages = .{};

        // Free showmode chunks
        for (self.showmode_content.items) |chunk| {
            if (chunk.text.len > 0) alloc.free(chunk.text);
        }
        self.showmode_content.deinit(alloc);

        // Free showcmd chunks
        for (self.showcmd_content.items) |chunk| {
            if (chunk.text.len > 0) alloc.free(chunk.text);
        }
        self.showcmd_content.deinit(alloc);

        // Free ruler chunks
        for (self.ruler_content.items) |chunk| {
            if (chunk.text.len > 0) alloc.free(chunk.text);
        }
        self.ruler_content.deinit(alloc);
    }

    /// Clear msg_show messages only. Does NOT clear showmode/showcmd/ruler
    /// (per Neovim docs: msg_clear only clears msg_show content).
    pub fn clearMessages(self: *MessageState, alloc: std.mem.Allocator) void {
        for (self.messages.items) |*msg| {
            msg.deinit(alloc);
        }
        self.messages.clearRetainingCapacity();
        self.visible = false;
    }

    pub fn clear(self: *MessageState, alloc: std.mem.Allocator) void {
        for (self.messages.items) |*msg| {
            msg.deinit(alloc);
        }
        self.messages.clearRetainingCapacity();

        // Free showmode chunks
        for (self.showmode_content.items) |chunk| {
            if (chunk.text.len > 0) alloc.free(chunk.text);
        }
        self.showmode_content.clearRetainingCapacity();

        // Free showcmd chunks
        for (self.showcmd_content.items) |chunk| {
            if (chunk.text.len > 0) alloc.free(chunk.text);
        }
        self.showcmd_content.clearRetainingCapacity();

        // Free ruler chunks
        for (self.ruler_content.items) |chunk| {
            if (chunk.text.len > 0) alloc.free(chunk.text);
        }
        self.ruler_content.clearRetainingCapacity();

        self.confirm_msg.clear();
        self.visible = false;
        self.msg_dirty = false;
        self.showmode_dirty = false;
        self.showcmd_dirty = false;
        self.ruler_dirty = false;
    }
};

/// A single entry in message history (for msg_history_show).
pub const MsgHistoryEntry = struct {
    kind: []const u8 = "",
    content: std.ArrayListUnmanaged(MsgChunk) = .{},
    append: bool = false,

    pub fn deinit(self: *MsgHistoryEntry, alloc: std.mem.Allocator) void {
        for (self.content.items) |chunk| {
            if (chunk.text.len > 0) alloc.free(chunk.text);
        }
        self.content.deinit(alloc);
        if (self.kind.len > 0) alloc.free(self.kind);
    }
};

/// State for msg_history_show event.
pub const MsgHistoryState = struct {
    entries: std.ArrayListUnmanaged(MsgHistoryEntry) = .{},
    prev_cmd: bool = false,
    dirty: bool = false,

    pub fn deinit(self: *MsgHistoryState, alloc: std.mem.Allocator) void {
        for (self.entries.items) |*entry| {
            entry.deinit(alloc);
        }
        self.entries.deinit(alloc);
    }

    pub fn clear(self: *MsgHistoryState, alloc: std.mem.Allocator) void {
        for (self.entries.items) |*entry| {
            entry.deinit(alloc);
        }
        self.entries.clearRetainingCapacity();
        self.prev_cmd = false;
        self.dirty = false;
    }
};

// ext_popupmenu types

/// A single item in the popup menu.
pub const PopupmenuItem = struct {
    word: []const u8 = "",
    kind: []const u8 = "",
    menu: []const u8 = "",
    info: []const u8 = "",
};

/// State for popup menu.
pub const PopupmenuState = struct {
    items: std.ArrayListUnmanaged(PopupmenuItem) = .{},
    selected: i32 = -1,
    row: i32 = 0,
    col: i32 = 0,
    grid_id: i64 = 1,
    visible: bool = false,
    changed: bool = false, // Flag to trigger Lua API call

    pub fn deinit(self: *PopupmenuState, alloc: std.mem.Allocator) void {
        for (self.items.items) |item| {
            if (item.word.len > 0) alloc.free(item.word);
            if (item.kind.len > 0) alloc.free(item.kind);
            if (item.menu.len > 0) alloc.free(item.menu);
            if (item.info.len > 0) alloc.free(item.info);
        }
        self.items.deinit(alloc);
        self.items = .{};
    }

    pub fn clear(self: *PopupmenuState, alloc: std.mem.Allocator) void {
        for (self.items.items) |item| {
            if (item.word.len > 0) alloc.free(item.word);
            if (item.kind.len > 0) alloc.free(item.kind);
            if (item.menu.len > 0) alloc.free(item.menu);
            if (item.info.len > 0) alloc.free(item.info);
        }
        self.items.clearRetainingCapacity();
        self.selected = -1;
        self.row = 0;
        self.col = 0;
        self.grid_id = 1;
        self.visible = false;
        self.changed = false;
    }
};

// ext_tabline types

/// A single tab entry from Neovim.
pub const TabEntry = struct {
    tab_handle: i64,
    name: []const u8,
};

/// A single buffer entry from Neovim.
pub const BufferEntry = struct {
    buffer_handle: i64,
    name: []const u8,
};

/// State for tabline (Chrome-style tabs).
pub const TablineState = struct {
    tabs: std.ArrayListUnmanaged(TabEntry) = .{},
    buffers: std.ArrayListUnmanaged(BufferEntry) = .{},
    current_tab: i64 = 0,
    current_buffer: i64 = 0,
    visible: bool = false,
    dirty: bool = false,

    pub fn deinit(self: *TablineState, alloc: std.mem.Allocator) void {
        for (self.tabs.items) |tab| {
            if (tab.name.len > 0) alloc.free(tab.name);
        }
        self.tabs.deinit(alloc);
        self.tabs = .{};
        for (self.buffers.items) |buf| {
            if (buf.name.len > 0) alloc.free(buf.name);
        }
        self.buffers.deinit(alloc);
        self.buffers = .{};
    }

    pub fn clear(self: *TablineState, alloc: std.mem.Allocator) void {
        for (self.tabs.items) |tab| {
            if (tab.name.len > 0) alloc.free(tab.name);
        }
        self.tabs.clearRetainingCapacity();
        for (self.buffers.items) |buf| {
            if (buf.name.len > 0) alloc.free(buf.name);
        }
        self.buffers.clearRetainingCapacity();
        self.current_tab = 0;
        self.current_buffer = 0;
        self.visible = false;
        self.dirty = false;
    }
};

pub const ModeInfo = struct {
    shape: CursorShape = .block,
    cell_percentage: u8 = 100,
    attr_id: u32 = 0,
    blink_wait_ms: u32 = 0,  // wait time before blink starts (ms), 0=no blink
    blink_on_ms: u32 = 0,    // on time for blink cycle (ms)
    blink_off_ms: u32 = 0,   // off time for blink cycle (ms)
};

pub const ScrollDelta = struct {
    top: u32,
    bot: u32,
    left: u32,
    right: u32,
    rows: i32,
    cols: i32,
};

pub const GridBuf = struct {
    rows: u32 = 0,
    cols: u32 = 0,
    cells: []Cell = &[_]Cell{},
    dirty: bool = true, // Dirty flag for external grid vertex updates
    dirty_rows: std.DynamicBitSetUnmanaged = .{}, // Row-level dirty tracking for partial updates
    last_scroll_op: ?ScrollDelta = null, // Per-GridBuf scroll tracking for on_grid_row_scroll
    scroll_fast_path_blocked: bool = false, // True when multiple scrolls in same batch
    prev_cursor_row: ?u32 = null, // Previous cursor row (grid-relative) for erasing old cursor

    fn deinit(self: *GridBuf, alloc: std.mem.Allocator) void {
        self.dirty_rows.deinit(alloc);
        if (self.cells.len != 0) alloc.free(self.cells);
        self.cells = &[_]Cell{};
        self.rows = 0;
        self.cols = 0;
    }

    fn resize(self: *GridBuf, alloc: std.mem.Allocator, rows: u32, cols: u32) !void {
        const new_len: usize = @as(usize, rows) * @as(usize, cols);
        const new_cells = try alloc.alloc(Cell, new_len);
        @memset(new_cells, .{ .cp = ' ', .hl = 0 });

        const min_rows = @min(self.rows, rows);
        const min_cols = @min(self.cols, cols);

        if (self.cells.len != 0) {
            // Row-level @memcpy instead of per-cell copy
            var r: u32 = 0;
            while (r < min_rows) : (r += 1) {
                const old_start: usize = @as(usize, r) * @as(usize, self.cols);
                const new_start: usize = @as(usize, r) * @as(usize, cols);
                @memcpy(new_cells[new_start..new_start + min_cols], self.cells[old_start..old_start + min_cols]);
            }
            alloc.free(self.cells);
        }

        self.cells = new_cells;
        self.rows = rows;
        self.cols = cols;
        self.dirty = true;

        // Resize dirty_rows bitset and mark all rows as dirty
        if (self.dirty_rows.bit_length < rows) {
            self.dirty_rows.resize(alloc, rows, true) catch {};
        }
        self.dirty_rows.setRangeValue(.{ .start = 0, .end = rows }, true);
    }

    fn clear(self: *GridBuf) void {
        @memset(self.cells, .{ .cp = ' ', .hl = 0 });
        self.dirty = true;
        // Mark all rows as dirty
        if (self.dirty_rows.bit_length > 0) {
            self.dirty_rows.setRangeValue(.{ .start = 0, .end = self.dirty_rows.bit_length }, true);
        }
    }

    /// Returns true if the cell was actually changed.
    fn putCell(self: *GridBuf, row: u32, col: u32, cp: u32, hl: u32) bool {
        if (row >= self.rows or col >= self.cols) return false;
        const idx: usize = @as(usize, row) * @as(usize, self.cols) + @as(usize, col);

        // Skip if no change (same optimization as global Grid.putCell)
        const old = self.cells[idx];
        if (old.cp == cp and old.hl == hl) return false;

        self.cells[idx] = .{ .cp = cp, .hl = hl };
        self.dirty = true;
        // Mark this row as dirty for partial updates
        if (self.dirty_rows.bit_length > row) {
            self.dirty_rows.set(row);
        }
        return true;
    }

    fn getCellHL(self: *const GridBuf, row: u32, col: u32) u32 {
        if (row >= self.rows or col >= self.cols) return 0;
        const idx: usize = @as(usize, row) * @as(usize, self.cols) + @as(usize, col);
        return self.cells[idx].hl;
    }

    /// Implements the "grid_scroll" UI event for a sub-grid.
    /// Note: 'cols' is reserved (currently always 0 in Nvim) and is ignored.
    fn scroll(
        self: *GridBuf,
        top_in: u32,
        bot_in: u32,
        left_in: u32,
        right_in: u32,
        rows: i32,
        cols: i32,
    ) void {
        _ = cols;

        if (self.rows == 0 or self.cols == 0) return;
        if (rows == 0) return;

        // Safety check: ensure cells buffer is correctly sized
        const expected_len: usize = @as(usize, self.rows) * @as(usize, self.cols);
        if (self.cells.len < expected_len) return;

        const top: u32 = if (top_in > self.rows) self.rows else top_in;
        const bot: u32 = if (bot_in > self.rows) self.rows else bot_in;
        const left: u32 = if (left_in > self.cols) self.cols else left_in;
        const right: u32 = if (right_in > self.cols) self.cols else right_in;
        if (top >= bot or left >= right) return;

        const height: u32 = bot - top;
        const width: u32 = right - left;

        const shift: u32 = blk: {
            if (rows == std.math.minInt(i32)) break :blk height;
            const a: i32 = if (rows < 0) -rows else rows;
            break :blk @as(u32, @intCast(a));
        };

        if (shift >= height) {
            var rr: u32 = top;
            while (rr < bot) : (rr += 1) {
                const off: usize = @as(usize, rr) * @as(usize, self.cols) + @as(usize, left);
                const slice = self.cells[off .. off + @as(usize, width)];
                @memset(slice, .{ .cp = ' ', .hl = 0 });
            }
            return;
        }

        if (rows > 0) {
            // Move up by 'shift'
            var r: u32 = 0;
            while (r < height - shift) : (r += 1) {
                const src_row = top + shift + r;
                const dst_row = top + r;

                const src_off: usize = @as(usize, src_row) * @as(usize, self.cols) + @as(usize, left);
                const dst_off: usize = @as(usize, dst_row) * @as(usize, self.cols) + @as(usize, left);

                std.mem.copyForwards(
                    Cell,
                    self.cells[dst_off .. dst_off + @as(usize, width)],
                    self.cells[src_off .. src_off + @as(usize, width)],
                );
            }

            // clear bottom
            var rr: u32 = bot - shift;
            while (rr < bot) : (rr += 1) {
                const off: usize = @as(usize, rr) * @as(usize, self.cols) + @as(usize, left);
                const slice = self.cells[off .. off + @as(usize, width)];
                @memset(slice, .{ .cp = ' ', .hl = 0 });
            }
        } else {
            // Move down by 'shift' (bottom-up)
            var r: u32 = height - shift;
            while (r > 0) {
                r -= 1;

                const src_row = top + r;
                const dst_row = top + shift + r;

                const src_off: usize = @as(usize, src_row) * @as(usize, self.cols) + @as(usize, left);
                const dst_off: usize = @as(usize, dst_row) * @as(usize, self.cols) + @as(usize, left);

                std.mem.copyForwards(
                    Cell,
                    self.cells[dst_off .. dst_off + @as(usize, width)],
                    self.cells[src_off .. src_off + @as(usize, width)],
                );
            }

            // clear top
            var rr: u32 = top;
            while (rr < top + shift) : (rr += 1) {
                const off: usize = @as(usize, rr) * @as(usize, self.cols) + @as(usize, left);
                const slice = self.cells[off .. off + @as(usize, width)];
                @memset(slice, .{ .cp = ' ', .hl = 0 });
            }
        }

        // Mark only vacated rows as dirty — non-vacated rows are just shifted
        // and the frontend's row slot remapping handles the visual shift.
        // grid_line events will mark truly-changed rows dirty separately.
        if (self.dirty_rows.bit_length > 0) {
            if (rows > 0) {
                // Scroll up: vacated band is [bot-shift, bot)
                var rr: u32 = bot - shift;
                while (rr < bot) : (rr += 1) {
                    if (rr < self.dirty_rows.bit_length) {
                        self.dirty_rows.set(rr);
                    }
                }
            } else {
                // Scroll down: vacated band is [top, top+shift)
                var rr: u32 = top;
                while (rr < top + shift) : (rr += 1) {
                    if (rr < self.dirty_rows.bit_length) {
                        self.dirty_rows.set(rr);
                    }
                }
            }
        }
        self.dirty = true;
    }

    /// Clear dirty flags after vertex generation
    pub fn clearDirty(self: *GridBuf) void {
        self.dirty = false;
        self.last_scroll_op = null;
        self.scroll_fast_path_blocked = false;
        self.prev_cursor_row = null;
        if (self.dirty_rows.bit_length > 0) {
            self.dirty_rows.setRangeValue(.{ .start = 0, .end = self.dirty_rows.bit_length }, false);
        }
    }
};

pub const GridPos = struct {
    row: u32,
    col: u32,
    anchor_grid: i64 = 1, // which grid this float is anchored to (1 = global grid)
};

/// Info for an external grid (displayed in a separate window).
pub const ExternalGridInfo = struct {
    win: i64,
    start_row: i32, // -1 if no position info available
    start_col: i32,
};

/// Pending grid resize request from ext_windows win_resize event.
pub const PendingGridResize = struct {
    grid_id: i64,
    width: u32,
    height: u32,
};

/// ext_windows layout operation type.
pub const WinOpType = enum { move, exchange, rotate, resize_equal };

/// Pending ext_windows layout operation (win_move, win_exchange, win_rotate, win_resize_equal).
pub const PendingWinOp = struct {
    op: WinOpType,
    win: i64 = 0,
    grid_id: i64 = 0,
    flags_or_direction: i32 = 0, // win_move: flags, win_rotate: direction
    count: i32 = 0, // win_exchange: count, win_rotate: count
};

/// Target (desired) grid dimensions for external windows.
/// Updated by grid_resize events so NDC viewport always matches the actual grid.
pub const GridSize = struct {
    rows: u32,
    cols: u32,
};

pub const WinLayer = struct {
    zindex: i64 = 0,
    compindex: i64 = 0,

    // Tie-breaker when zindex/compindex are equal.
    // Larger order means "draw later" (= front).
    order: u64 = 0,
};

/// Viewport margins from win_viewport_margins event.
/// These rows/cols are NOT part of the scrollable viewport (e.g., winbar, borders).
pub const ViewportMargins = struct {
    top: u32 = 0,
    bottom: u32 = 0,
    left: u32 = 0,
    right: u32 = 0,
};

/// Viewport info from win_viewport event.
pub const Viewport = struct {
    topline: i64 = 0,
    botline: i64 = 0,
    curline: i64 = 0,
    curcol: i64 = 0,
    line_count: i64 = 0,
    scroll_delta: i64 = 0,
};

/// Describes a pending grid_scroll operation preserved until flush.
/// Used by scroll-aware flush to determine whether row cache can be reused
/// instead of recomposing all dirty rows.
pub const ScrollOp = struct {
    grid_id: i64,
    top: u32,
    bot: u32,
    left: u32,
    right: u32,
    rows: i32, // positive = scroll up (content moves up), negative = scroll down
    cols: i32,
    /// Grid dimensions at scroll time (target grid, not necessarily global grid)
    target_rows: u32,
    target_cols: u32,
    /// Global grid row offset from win_pos (0 if grid_id == 1)
    win_pos_row: u32,
};

pub const Grid = struct {
    alloc: std.mem.Allocator,

    content_rev: u64 = 0, // cells / layering / resize / scroll etc
    cursor_rev: u64 = 0,  // cursor position/shape/attr/visibility

    // IME off request (set by mode_change, cleared after callback is called)
    ime_off_requested: bool = false,

    rows: u32 = 0,
    cols: u32 = 0,

    // Screen width in cells (for cmdline max width). Set by frontend.
    screen_cols: u32 = 0,
    // Dirty tracking (global grid only)
    dirty_all: bool = true,
    dirty_rows: std.DynamicBitSetUnmanaged = .{},

    cells: []Cell = &[_]Cell{},

    // ext_multigrid: sub-grids and their positions
    sub_grids: std.AutoHashMapUnmanaged(i64, GridBuf) = .{},
    win_pos: std.AutoHashMapUnmanaged(i64, GridPos) = .{},

    // grid_id -> Neovim window handle (from win_pos/win_float_pos/win_external_pos events)
    grid_win_ids: std.AutoHashMapUnmanaged(i64, i64) = .{},

    grid_metrics: std.AutoHashMapUnmanaged(i64, CellMetricsPx) = .{},

    // Viewport info per grid (from win_viewport / win_viewport_margins)
    viewport: std.AutoHashMapUnmanaged(i64, Viewport) = .{},
    viewport_margins: std.AutoHashMapUnmanaged(i64, ViewportMargins) = .{},

    // cursor state (grid-relative)
    cursor_grid: i64 = 1,
    cursor_row: u32 = 0,
    cursor_col: u32 = 0,
    cursor_valid: bool = false,

    cursor_visible: bool = true,
    cursor_shape: CursorShape = .block,
    cursor_cell_percentage: u8 = 100,
    cursor_attr_id: u32 = 0,
    cursor_blink_wait_ms: u32 = 0,  // wait time before blink starts (ms), 0=no blink
    cursor_blink_on_ms: u32 = 0,    // on time for blink cycle (ms)
    cursor_blink_off_ms: u32 = 0,   // off time for blink cycle (ms)

    cursor_style_enabled: bool = false,
    mode_infos: std.ArrayListUnmanaged(ModeInfo) = .{},
    current_mode_idx: usize = 0,
    /// Current mode name (e.g., "normal", "insert", "terminal")
    /// Fixed-size buffer to avoid allocation; null-terminated.
    current_mode_name: [16]u8 = [_]u8{0} ** 16,

    win_layer: std.AutoHashMapUnmanaged(i64, WinLayer) = .{},

    // Monotonic counter for WinLayer.order (used to emulate goneovim's "last grid_line wins").
    layer_order_counter: u64 = 0,

    // ext_multigrid: external grids (displayed in separate top-level windows)
    // Maps grid_id -> win handle (Neovim window handle, for reference)
    external_grids: std.AutoHashMapUnmanaged(i64, ExternalGridInfo) = .{},

    // ext_windows: pending grid resize requests (processed by core after redraw)
    pending_grid_resizes: std.ArrayListUnmanaged(PendingGridResize) = .{},

    // ext_windows: pending layout operations (win_move, win_exchange, etc.)
    pending_win_ops: std.ArrayListUnmanaged(PendingWinOp) = .{},

    // ext_windows: grids awaiting initial resize response from Neovim.
    // Window creation is deferred until grid_resize provides adequate dimensions.
    pending_ext_window_grids: std.AutoHashMapUnmanaged(i64, PendingGridResize) = .{},

    // ext_windows: grids that were created by win_split (persistently tracked).
    // Survives win_hide (tab switch) so win_pos can re-register them as external.
    // Only removed on win_close (permanent close).
    ext_windows_grids: std.AutoHashMapUnmanaged(i64, i64) = .{}, // grid_id -> win_id

    // ext_windows: actual grid dimensions for each external grid.
    // Updated on grid_resize so NDC viewport always matches the grid data.
    // Also set initially by tryResizeGrid for new windows.
    external_grid_target_sizes: std.AutoHashMapUnmanaged(i64, GridSize) = .{},

    // ext_windows: set during handleRedraw when a composited (non-external,
    // non-float) editor window receives win_close. Used by the promotion
    // logic in rpc_session.zig to detect that Neovim may have re-composited
    // grid 2 as a fallback, which should not block promotion.
    // Cleared after the promotion check.
    composited_win_closed: bool = false,

    // ext_cmdline state
    cmdline_states: std.AutoHashMapUnmanaged(u32, CmdlineState) = .{}, // level -> state
    cmdline_block: CmdlineBlock = .{},
    cmdline_dirty: bool = false,

    // ext_popupmenu state
    popupmenu: PopupmenuState = .{},

    // ext_tabline state
    tabline_state: TablineState = .{},

    // ext_messages state
    message_state: MessageState = .{},
    msg_history_state: MsgHistoryState = .{},

    // Track grid_ids that received grid_scroll events (for frontend pixel offset clearing)
    scrolled_grid_ids: [16]i64 = [_]i64{0} ** 16,
    scrolled_grid_count: u8 = 0,

    // Pending scroll operation for scroll-aware flush optimization.
    // Set by scrollGrid(), consumed and cleared by flush via clearDirty().
    // When present, flush can potentially reuse row cache instead of recomposing all rows.
    // A second grid_scroll in the same batch disables fast path for that flush.
    pending_scroll: ?ScrollOp = null,

    // True when this batch observed multiple grid_scroll events and must not use
    // the scroll fast path. Cleared after flush via clearScrollState().
    scroll_fast_path_blocked: bool = false,

    // Rows touched by grid_line (via putCell/putCellGrid) AFTER pending_scroll was set.
    // These are global grid coordinates (already offset by win_pos for sub-grids).
    // Tracked as a fixed-size array to avoid allocation. Overflow invalidates pending_scroll.
    scroll_touched_rows: [8]u32 = undefined,
    scroll_touched_count: u8 = 0,

    // Previous cursor row before grid_cursor_goto update.
    // Stored as global grid coordinate (offset by win_pos for sub-grid cursors).
    // Used by scroll-aware flush to know which rows need cursor redraw.
    // Set by setCursor(), cleared by clearScrollState().
    prev_cursor_row: ?u32 = null,
    prev_cursor_grid: ?i64 = null,

    // Input trace markers for end-to-end perf logging.
    input_trace_seq: u64 = 0,
    input_trace_sent_ns: i64 = 0,
    input_trace_first_grid_event_logged_seq: u64 = 0,
    input_trace_flush_logged_seq: u64 = 0,

    pub fn init(alloc: std.mem.Allocator) Grid {
        return .{ .alloc = alloc };
    }

    pub fn noteInputTrace(self: *Grid, seq: u64, sent_ns: i64) void {
        self.input_trace_seq = seq;
        self.input_trace_sent_ns = sent_ns;
        self.input_trace_first_grid_event_logged_seq = 0;
        self.input_trace_flush_logged_seq = 0;
    }

    pub fn deinit(self: *Grid) void {
        // global grid
        if (self.cells.len != 0) self.alloc.free(self.cells);
        self.cells = &[_]Cell{};
        self.rows = 0;
        self.cols = 0;

        self.dirty_rows.deinit(self.alloc);

        // sub grids
        var it = self.sub_grids.iterator();
        while (it.next()) |e| {
            e.value_ptr.deinit(self.alloc);
        }
        self.sub_grids.deinit(self.alloc);
        self.win_pos.deinit(self.alloc);
        self.grid_win_ids.deinit(self.alloc);
        self.win_layer.deinit(self.alloc);
        self.external_grids.deinit(self.alloc);
        self.pending_grid_resizes.deinit(self.alloc);
        self.pending_win_ops.deinit(self.alloc);
        self.pending_ext_window_grids.deinit(self.alloc);
        self.ext_windows_grids.deinit(self.alloc);
        self.external_grid_target_sizes.deinit(self.alloc);
        self.grid_metrics.deinit(self.alloc);
        self.viewport.deinit(self.alloc);
        self.viewport_margins.deinit(self.alloc);

        // cursor
        self.cursor_valid = false;
        self.cursor_grid = 1;
        self.cursor_row = 0;
        self.cursor_col = 0;

        // ext_cmdline
        var cmdline_it = self.cmdline_states.iterator();
        while (cmdline_it.next()) |e| {
            e.value_ptr.deinit(self.alloc);
        }
        self.cmdline_states.deinit(self.alloc);
        self.cmdline_block.deinit(self.alloc);

        // ext_popupmenu
        self.popupmenu.deinit(self.alloc);

        // ext_tabline
        self.tabline_state.deinit(self.alloc);

        // ext_messages
        self.message_state.deinit(self.alloc);
        self.msg_history_state.deinit(self.alloc);

        // mode info
        self.mode_infos.deinit(self.alloc);
    }

    // Per-grid cell metrics in drawable pixels (for goneovim-like float positioning).
    pub const CellMetricsPx = struct {
        cell_w_px: u32,
        cell_h_px: u32,
    };

    pub fn setGridMetricsPx(self: *Grid, grid_id: i64, cell_w_px: u32, cell_h_px: u32) !void {
        const cw = if (cell_w_px == 0) 1 else cell_w_px;
        const ch = if (cell_h_px == 0) 1 else cell_h_px;
        try self.grid_metrics.put(self.alloc, grid_id, .{ .cell_w_px = cw, .cell_h_px = ch });
    }

    pub fn getGridMetricsPx(self: *const Grid, grid_id: i64) CellMetricsPx {
        if (self.grid_metrics.get(grid_id)) |m| return m;
        // Fallback to global grid metrics; if not set, assume 1 to avoid div-by-zero.
        if (self.grid_metrics.get(1)) |m1| return m1;
        return .{ .cell_w_px = 1, .cell_h_px = 1 };
    }

    pub fn ensureGridMetricsPx(self: *Grid, grid_id: i64) !void {
        if (self.grid_metrics.contains(grid_id)) return;
        const base = self.getGridMetricsPx(1);
        try self.grid_metrics.put(self.alloc, grid_id, base);
    }

    pub fn getCellHL(self: *const Grid, row: u32, col: u32) u32 {
        if (row >= self.rows or col >= self.cols) return 0;
        const idx: usize = @as(usize, row) * @as(usize, self.cols) + @as(usize, col);
        return self.cells[idx].hl;
    }

    pub fn getCellHLGrid(self: *const Grid, grid_id: i64, row: u32, col: u32) u32 {
        if (grid_id == 1) return self.getCellHL(row, col);

        // sub grid
        if (self.sub_grids.getPtr(grid_id)) |sg| {
            return sg.getCellHL(row, col);
        }
        return 0;
    }

    /// Get cell at (row, col) for global grid
    pub fn getCell(self: *const Grid, row: u32, col: u32) Cell {
        if (row >= self.rows or col >= self.cols) return .{ .cp = 0, .hl = 0 };
        const idx: usize = @as(usize, row) * @as(usize, self.cols) + @as(usize, col);
        return self.cells[idx];
    }

    /// Get cell at (row, col) for any grid
    pub fn getCellGrid(self: *const Grid, grid_id: i64, row: u32, col: u32) Cell {
        if (grid_id == 1) return self.getCell(row, col);

        // sub grid
        if (self.sub_grids.getPtr(grid_id)) |sg| {
            if (row >= sg.rows or col >= sg.cols) return .{ .cp = 0, .hl = 0 };
            const idx: usize = @as(usize, row) * @as(usize, sg.cols) + @as(usize, col);
            return sg.cells[idx];
        }
        return .{ .cp = 0, .hl = 0 };
    }

    pub fn ensureDirtyCapacity(self: *Grid, rows: u32) !void {
        // Keep bitset length == rows. Initialize new bits as "clean" (false).
        const r: usize = @as(usize, rows);
        if (self.dirty_rows.bit_length >= r) return;
        try self.dirty_rows.resize(self.alloc, r, false);
    }
    
    pub fn markDirtyRow(self: *Grid, row: u32) void {
        if (row >= self.rows) return;
        // When dirty_all is true, per-row bits are not necessary.
        if (self.dirty_all) return;
        self.dirty_rows.set(@as(usize, row));
    }
    
    pub fn markDirtyRect(self: *Grid, top: u32, bot: u32) void {
        if (self.dirty_all) return;
        const start: usize = @as(usize, top);
        const end: usize = @as(usize, @min(bot, self.rows));
        if (start >= end) return;
        const clamped_end: usize = @min(end, self.dirty_rows.bit_length);
        if (start < clamped_end) {
            self.dirty_rows.setRangeValue(.{ .start = start, .end = clamped_end }, true);
        }
    }
    
    pub fn markAllDirty(self: *Grid) void {
        // Fast path: avoid setting all bits; dirty_all dominates.
        self.dirty_all = true;
    }

    /// Shift previously-recorded touched rows by a new scroll delta.
    /// Rows that scroll out of the [top, bot) region are removed.
    /// Coordinates are in global grid space (win_pos_row already applied).
    fn shiftTouchedRows(self: *Grid, scroll_rows: i32, top: u32, bot: u32, win_pos_row: u32) void {
        const main_top: i32 = @intCast(top + win_pos_row);
        const main_bot: i32 = @intCast(bot + win_pos_row);
        var write: u8 = 0;
        for (self.scroll_touched_rows[0..self.scroll_touched_count]) |tr| {
            const shifted: i32 = @as(i32, @intCast(tr)) - scroll_rows;
            if (shifted >= main_top and shifted < main_bot) {
                self.scroll_touched_rows[write] = @intCast(shifted);
                write += 1;
            }
        }
        self.scroll_touched_count = write;
    }

    /// Record a row touched by grid_line while a pending_scroll is active.
    /// Uses global grid coordinates. Deduplicates entries.
    /// On overflow, invalidates pending_scroll (too many touched rows for fast path).
    fn recordScrollTouchedRow(self: *Grid, row: u32) void {
        if (self.pending_scroll == null) return;

        // Deduplicate: check if already recorded
        for (self.scroll_touched_rows[0..self.scroll_touched_count]) |r| {
            if (r == row) return;
        }

        // Overflow: too many distinct touched rows, invalidate scroll optimization
        if (self.scroll_touched_count >= self.scroll_touched_rows.len) {
            self.pending_scroll = null;
            self.scroll_touched_count = 0;
            return;
        }

        self.scroll_touched_rows[self.scroll_touched_count] = row;
        self.scroll_touched_count += 1;
    }
    
    pub fn clearDirty(self: *Grid) void {
        self.dirty_all = false;
        // Make all bits clean.
        if (self.dirty_rows.bit_length != 0) {
            self.dirty_rows.unsetAll();
        }
    }

    /// Clear scroll-aware flush provenance (pending_scroll, touched rows, prev cursor).
    /// Called by flush after successful vertex emission, NOT on abort/retry.
    pub fn clearScrollState(self: *Grid) void {
        self.pending_scroll = null;
        self.scroll_fast_path_blocked = false;
        self.scroll_touched_count = 0;
        self.prev_cursor_row = null;
        self.prev_cursor_grid = null;
    }

    pub fn clear(self: *Grid) void {
        @memset(self.cells, .{ .cp = ' ', .hl = 0 });
    }

    pub fn resize(self: *Grid, rows: u32, cols: u32) !void {
        const new_len: usize = @as(usize, rows) * @as(usize, cols);
        const new_cells = try self.alloc.alloc(Cell, new_len);

        // Fill new buffer with spaces using vectorized memset.
        @memset(new_cells, .{ .cp = ' ', .hl = 0 });

        const min_rows = @min(self.rows, rows);
        const min_cols = @min(self.cols, cols);

        if (self.cells.len != 0) {
            // Row-level @memcpy instead of per-cell copy
            var r: u32 = 0;
            while (r < min_rows) : (r += 1) {
                const old_start: usize = @as(usize, r) * @as(usize, self.cols);
                const new_start: usize = @as(usize, r) * @as(usize, cols);
                @memcpy(new_cells[new_start..new_start + min_cols], self.cells[old_start..old_start + min_cols]);
            }
            self.alloc.free(self.cells);
        }

        self.cells = new_cells;
        self.rows = rows;
        self.cols = cols;

        // --- ./src/shared/grid.zig ---
        // INSERT in pub fn resize(...) !void, after:
        //   self.rows = rows;
        //   self.cols = cols;
        
        try self.ensureDirtyCapacity(rows);
        self.clearDirty();    // reset bitset
        self.markAllDirty();  // everything needs redraw after resize
    }

    pub fn putCell(self: *Grid, row: u32, col: u32, cp: u32, hl: u32) void {
        if (row >= self.rows or col >= self.cols) return;

        const idx: usize = @as(usize, row) * @as(usize, self.cols) + @as(usize, col);

        // If no actual change, do nothing (avoid increasing dirty state)
        const old = self.cells[idx];
        if (old.cp == cp and old.hl == hl) return;

        // Apply the change only when it actually differs
        self.cells[idx] = .{ .cp = cp, .hl = hl };

        // Treat only actual changes as dirty
        self.markDirtyRow(row);

        // Record touched row for scroll-aware flush (global grid coordinate)
        self.recordScrollTouchedRow(row);

        // Advance content_rev only on cell changes (defined in Grid)
        self.content_rev +%= 1;

        // Advance cursor_rev if cursor is on this cell (to update cursor text)
        if (self.cursor_grid == 1 and self.cursor_row == row and self.cursor_col == col) {
            self.cursor_rev +%= 1;
        }
    }

    /// Implements the "grid_scroll" UI event by copying a rectangular region.
    /// Note: 'cols' is reserved (currently always 0 in Nvim); checked for no-op detection but not used in scroll logic.
    pub fn scroll(
        self: *Grid,
        top_in: u32,
        bot_in: u32,
        left_in: u32,
        right_in: u32,
        rows: i32,
        cols: i32,
    ) void {
        if (self.rows == 0 or self.cols == 0) return;
        if (rows == 0 and cols == 0) return;

        const top: u32 = if (top_in > self.rows) self.rows else top_in;
        const bot: u32 = if (bot_in > self.rows) self.rows else bot_in;
        const left: u32 = if (left_in > self.cols) self.cols else left_in;
        const right: u32 = if (right_in > self.cols) self.cols else right_in;

        if (top >= bot or left >= right) return;

        const height: u32 = bot - top;
        const width: u32 = right - left;


        if (rows == 0) return;

        const shift: u32 = blk: {
            // Handle minInt safely (treat as very large shift => clears region)
            if (rows == std.math.minInt(i32)) break :blk height;
            const a: i32 = if (rows < 0) -rows else rows;
            break :blk @as(u32, @intCast(a));
        };

        // If the shift exceeds region height, everything is scrolled out.
        if (shift >= height) {
            var rr: u32 = top;
            while (rr < bot) : (rr += 1) {
                const off: usize = @as(usize, rr) * @as(usize, self.cols) + @as(usize, left);
                const slice = self.cells[off .. off + @as(usize, width)];
                @memset(slice, .{ .cp = ' ', .hl = 0 });
            }
            return;
        }

        if (rows > 0) {
            // Move up by 'shift'.
            var r: u32 = 0;
            while (r < height - shift) : (r += 1) {
                const src_row = top + shift + r;
                const dst_row = top + r;

                const src_off: usize = @as(usize, src_row) * @as(usize, self.cols) + @as(usize, left);
                const dst_off: usize = @as(usize, dst_row) * @as(usize, self.cols) + @as(usize, left);

                std.mem.copyForwards(
                    Cell,
                    self.cells[dst_off .. dst_off + @as(usize, width)],
                    self.cells[src_off .. src_off + @as(usize, width)],
                );
            }

            // Clear scrolled-in area at bottom (optional but safe).
            var rr: u32 = bot - shift;
            while (rr < bot) : (rr += 1) {
                const off: usize = @as(usize, rr) * @as(usize, self.cols) + @as(usize, left);
                const slice = self.cells[off .. off + @as(usize, width)];
                @memset(slice, .{ .cp = ' ', .hl = 0 });
            }
        } else {
            // Move down by 'shift' (copy bottom-up to avoid overwriting).
            var r: u32 = height - shift;
            while (r > 0) {
                r -= 1;

                const src_row = top + r;
                const dst_row = top + shift + r;

                const src_off: usize = @as(usize, src_row) * @as(usize, self.cols) + @as(usize, left);
                const dst_off: usize = @as(usize, dst_row) * @as(usize, self.cols) + @as(usize, left);

                std.mem.copyForwards(
                    Cell,
                    self.cells[dst_off .. dst_off + @as(usize, width)],
                    self.cells[src_off .. src_off + @as(usize, width)],
                );
            }

            // Clear scrolled-in area at top (optional but safe).
            var rr: u32 = top;
            while (rr < top + shift) : (rr += 1) {
                const off: usize = @as(usize, rr) * @as(usize, self.cols) + @as(usize, left);
                const slice = self.cells[off .. off + @as(usize, width)];
                @memset(slice, .{ .cp = ' ', .hl = 0 });
            }
        }

        self.markDirtyRect(top, bot);
    }

    fn getOrCreateSub(self: *Grid, grid_id: i64) !*GridBuf {
        // grid_id == 1 is the global grid; caller must not request it here
        const gop = try self.sub_grids.getOrPut(self.alloc, grid_id);
        if (!gop.found_existing) {
            gop.value_ptr.* = .{};
        }
        return gop.value_ptr;
    }

    pub fn resizeGrid(self: *Grid, grid_id: i64, rows: u32, cols: u32) !void {
        if (grid_id == 1) {
            self.content_rev +%= 1;
            try self.resize(rows, cols);
            self.markAllDirty();
            return;
        }
        const sg = try self.getOrCreateSub(grid_id);
        try sg.resize(self.alloc, rows, cols);

        // Only affect global grid state for composited grids (in win_pos).
        // External grids (not in win_pos) are rendered independently.
        if (self.win_pos.contains(grid_id)) {
            self.content_rev +%= 1;
            self.markAllDirty();
        }
    }

    pub fn clearGrid(self: *Grid, grid_id: i64) void {
        if (grid_id == 1) {
            self.content_rev +%= 1;
            self.clear();
            self.markAllDirty();
            return;
        }
        if (self.sub_grids.getPtr(grid_id)) |sg| sg.clear();

        // Only affect global grid state for composited grids.
        if (self.win_pos.contains(grid_id)) {
            self.content_rev +%= 1;
        }
    }
    
    pub fn putCellGrid(self: *Grid, grid_id: i64, row: u32, col: u32, cp: u32, hl: u32) void {
        if (grid_id == 1) {
            self.putCell(row, col, cp, hl);
            // Note: putCell already updates content_rev when cell changes
            return;
        }
        if (self.sub_grids.getPtr(grid_id)) |sg| {
            const changed = sg.putCell(row, col, cp, hl);
            if (changed) {
                if (self.win_pos.get(grid_id)) |p| {
                    // Composited on global grid: affect global grid dirty state
                    self.content_rev +%= 1;
                    const tr = p.row + row;
                    self.markDirtyRow(tr);
                    self.recordScrollTouchedRow(tr);
                }
                // External grids (not in win_pos) do not affect global grid
                // content_rev or dirty state.

                // Advance cursor_rev if cursor is on this cell (to update cursor text)
                if (self.cursor_grid == grid_id and self.cursor_row == row and self.cursor_col == col) {
                    self.cursor_rev +%= 1;
                }
            }
        }
    }

    pub fn scrollGrid(
        self: *Grid,
        grid_id: i64,
        top: u32, bot: u32, left: u32, right: u32,
        rows: i32, cols: i32,
    ) void {
        // Advance cursor_rev if cursor is in scroll region (cursor text may change)
        if (self.cursor_grid == grid_id and
            self.cursor_row >= top and self.cursor_row < bot and
            self.cursor_col >= left and self.cursor_col < right)
        {
            self.cursor_rev +%= 1;
        }

        if (grid_id == 1) {
            self.content_rev +%= 1;
            if (self.pending_scroll) |*ps| {
                if (ps.grid_id == grid_id and ps.top == top and ps.bot == bot and
                    ps.left == left and ps.right == right and cols == 0)
                {
                    // Same grid, same region: accumulate scroll delta.
                    // Shift previously-recorded touched rows by the new scroll amount.
                    self.shiftTouchedRows(rows, top, bot, 0);
                    self.scroll(top, bot, left, right, rows, cols);
                    self.recordScrolledGrid(grid_id);
                    ps.rows += rows;
                    return;
                }
                // Different grid or region: block fast path.
                self.scroll_fast_path_blocked = true;
                self.scroll_touched_count = 0;
            }
            self.scroll(top, bot, left, right, rows, cols);
            self.recordScrolledGrid(grid_id);
            self.pending_scroll = .{
                .grid_id = grid_id,
                .top = top, .bot = bot, .left = left, .right = right,
                .rows = rows, .cols = cols,
                .target_rows = self.rows, .target_cols = self.cols,
                .win_pos_row = 0,
            };
            self.scroll_touched_count = 0;
            return;
        }
        if (self.sub_grids.getPtr(grid_id)) |sg| {
            sg.scroll(top, bot, left, right, rows, cols);
            // Multiple scrolls in same batch block the fast path (same as global grid)
            if (sg.last_scroll_op != null) {
                sg.scroll_fast_path_blocked = true;
            }
            sg.last_scroll_op = .{
                .top = top, .bot = bot, .left = left, .right = right,
                .rows = rows, .cols = cols,
            };
            if (self.win_pos.get(grid_id)) |p| {
                self.content_rev +%= 1;
                if (self.pending_scroll) |*ps| {
                    if (ps.grid_id == grid_id and ps.top == top and ps.bot == bot and
                        ps.left == left and ps.right == right and cols == 0)
                    {
                        // Same grid, same region: accumulate scroll delta.
                        self.shiftTouchedRows(rows, top, bot, p.row);
                        self.markDirtyRect(p.row + top, p.row + bot);
                        ps.rows += rows;
                        return;
                    }
                    // Different grid or region: block fast path.
                    self.scroll_fast_path_blocked = true;
                    self.scroll_touched_count = 0;
                }
                self.markDirtyRect(p.row + top, p.row + bot);
                self.pending_scroll = .{
                    .grid_id = grid_id,
                    .top = top, .bot = bot, .left = left, .right = right,
                    .rows = rows, .cols = cols,
                    .target_rows = sg.rows, .target_cols = sg.cols,
                    .win_pos_row = p.row,
                };
                self.scroll_touched_count = 0;
            }
            // External grids (not in win_pos) do not affect global grid
            // content_rev, dirty state, or pending_scroll.

            self.recordScrolledGrid(grid_id);
        }
    }

    /// Record that a grid received a scroll event (for frontend pixel offset clearing).
    /// Avoids duplicates within the same flush batch.
    fn recordScrolledGrid(self: *Grid, grid_id: i64) void {
        // Check if already recorded
        for (self.scrolled_grid_ids[0..self.scrolled_grid_count]) |id| {
            if (id == grid_id) return;
        }
        // Add if space available
        if (self.scrolled_grid_count < self.scrolled_grid_ids.len) {
            self.scrolled_grid_ids[self.scrolled_grid_count] = grid_id;
            self.scrolled_grid_count += 1;
        }
    }

    /// Clear scrolled grid tracking (called after flush notification).
    pub fn clearScrolledGrids(self: *Grid) void {
        self.scrolled_grid_count = 0;
    }
    
    pub fn noteGridLine(self: *Grid, grid_id: i64) void {
        // Only advance content_rev for grids composited on the main window.
        // grid_id==1 is the global grid (always composited).
        // Other grids are composited when they have a win_pos entry.
        // External grids (not in win_pos) don't affect main window rendering.
        if (grid_id == 1 or self.win_pos.contains(grid_id)) {
            self.content_rev +%= 1;
        }

        if (grid_id == 1) return;

        if (self.win_layer.getPtr(grid_id)) |layer| {
            self.layer_order_counter +%= 1;
            layer.order = self.layer_order_counter;
        }
    }

    pub fn destroyGrid(self: *Grid, grid_id: i64) void {
        if (grid_id == 1) {
            self.deinit();
            return;
        }
        if (self.sub_grids.fetchRemove(grid_id)) |kv| {
            var buf = kv.value;
            buf.deinit(self.alloc);
        }
        _ = self.win_pos.remove(grid_id);
        _ = self.grid_win_ids.remove(grid_id);
        _ = self.win_layer.remove(grid_id);
        // Clean up per-grid metadata that was previously leaked on destroy.
        _ = self.grid_metrics.remove(grid_id);
        _ = self.viewport.remove(grid_id);
        _ = self.viewport_margins.remove(grid_id);
        _ = self.external_grids.remove(grid_id);
        _ = self.pending_ext_window_grids.remove(grid_id);
        _ = self.ext_windows_grids.remove(grid_id);
        _ = self.external_grid_target_sizes.remove(grid_id);
        self.markAllDirty();

        if (self.cursor_grid == grid_id) {
            self.cursor_valid = false;
            self.cursor_rev +%= 1;
        }
    }

    pub fn setWinPos(self: *Grid, grid_id: i64, win_id: i64, row: u32, col: u32) !void {
        // Positions are only meaningful for sub-grids (windows)
        if (grid_id == 1) return;

        // Store grid_id -> winid mapping
        try self.grid_win_ids.put(self.alloc, grid_id, win_id);

        // If this grid is external (ext_windows split), keep it external.
        // win_pos events still arrive for external grids but should not
        // pull them back into the composited layout.
        if (self.external_grids.contains(grid_id)) return;

        const old_pos_opt = self.win_pos.get(grid_id);
        if (old_pos_opt) |old_pos| {
            // If no actual change, do nothing (avoid increasing dirty state)
            if (old_pos.row == row and old_pos.col == col) return;
        }

        // First dirty the old range (position changed, so exposed area needs recomposition)
        if (old_pos_opt) |old_pos| {
            const h_old: u32 = if (self.sub_grids.get(grid_id)) |sg| sg.rows else 1;
            self.markDirtyRect(old_pos.row, old_pos.row + h_old);
        }

        try self.win_pos.put(self.alloc, grid_id, .{ .row = row, .col = col });

        // Dirty the new range
        const h_new: u32 = if (self.sub_grids.get(grid_id)) |sg| sg.rows else 1;
        self.markDirtyRect(row, row + h_new);

        // Only advance cursor_rev if cursor is on this grid
        if (self.cursor_grid == grid_id and self.cursor_valid) {
            self.cursor_rev +%= 1;
        }

        // NOTE: Do not call markAllDirty here
    }




    pub fn setWinFloatPos(
        self: *Grid,
        grid_id: i64,
        win_id: i64,
        row: u32,
        col: u32,
        zindex: i64,
        compindex: i64,
        anchor_grid: i64,
    ) !void {
        if (grid_id == 1) return;

        // Store grid_id -> winid mapping (skip for grids without a real window, e.g. msg_set_pos)
        if (win_id > 0) {
            try self.grid_win_ids.put(self.alloc, grid_id, win_id);
        }

        // If this grid was external, remove it from external_grids.
        // This allows a grid to transition from external back to float.
        _ = self.external_grids.remove(grid_id);

        // Mark old position dirty if this float is moving
        const old_pos_opt = self.win_pos.get(grid_id);
        if (old_pos_opt) |old_pos| {
            if (old_pos.anchor_grid == 1) {
                const h_old: u32 = if (self.sub_grids.get(grid_id)) |sg| sg.rows else 1;
                self.markDirtyRect(old_pos.row, old_pos.row + h_old);
            }
        }

        try self.win_pos.put(self.alloc, grid_id, .{ .row = row, .col = col, .anchor_grid = anchor_grid });

        // Mark new position dirty so row-mode recomposes with float overlay
        if (anchor_grid == 1) {
            const h_new: u32 = if (self.sub_grids.get(grid_id)) |sg| sg.rows else 1;
            self.markDirtyRect(row, row + h_new);
        }

        // Preserve existing order if present.
        var ord: u64 = 0;
        if (self.win_layer.get(grid_id)) |old| {
            ord = old.order;
        }
        try self.win_layer.put(self.alloc, grid_id, .{
            .zindex = zindex,
            .compindex = compindex,
            .order = ord,
        });
        if (self.cursor_grid == grid_id and self.cursor_valid) {
            self.cursor_rev +%= 1;
        }
    }

    pub fn hideWin(self: *Grid, grid_id: i64) void {
        // Mark the rows this grid was covering as dirty before removal,
        // so they get recomposed with the underlying grid=1 content
        // (e.g., window separators that were previously overlaid).
        // Only bump content_rev when win_pos existed (grid was composited);
        // external-only grids don't affect global grid composition.
        if (self.win_pos.get(grid_id)) |pos| {
            if (self.sub_grids.get(grid_id)) |sg| {
                self.markDirtyRect(pos.row, pos.row + sg.rows);
            } else {
                self.markAllDirty();
            }
            self.content_rev +%= 1;
        }
        _ = self.win_pos.remove(grid_id);
        _ = self.grid_win_ids.remove(grid_id);
        _ = self.win_layer.remove(grid_id);
        _ = self.external_grids.remove(grid_id);
        if (self.cursor_grid == grid_id) {
            self.cursor_valid = false;
            self.cursor_rev +%= 1;
        }
    }

    /// Mark a grid as external (displayed in a separate top-level window).
    /// Returns true if this is a new external grid, false if it was already external.
    pub fn setWinExternalPos(self: *Grid, grid_id: i64, win: i64) !bool {
        if (grid_id == 1) return false; // Global grid cannot be external

        // Store grid_id -> winid mapping
        try self.grid_win_ids.put(self.alloc, grid_id, win);

        // Check if already external
        if (self.external_grids.contains(grid_id)) {
            // Update the win handle (might be different window), preserve position
            if (self.external_grids.getPtr(grid_id)) |info| {
                info.win = win;
            }
            return false;
        }

        // Save position and mark covered rows dirty before removal.
        // Only bump content_rev when win_pos existed (grid was composited).
        var start_row: i32 = -1;
        var start_col: i32 = -1;
        if (self.win_pos.get(grid_id)) |pos| {
            start_row = @intCast(pos.row);
            start_col = @intCast(pos.col);
            if (self.sub_grids.get(grid_id)) |sg| {
                self.markDirtyRect(pos.row, pos.row + sg.rows);
            } else {
                self.markAllDirty();
            }
            self.content_rev +%= 1;
        }

        // Remove from regular win_pos/win_layer (external grids are not composited)
        _ = self.win_pos.remove(grid_id);
        _ = self.win_layer.remove(grid_id);

        // Mark as external with position info
        try self.external_grids.put(self.alloc, grid_id, .{
            .win = win,
            .start_row = start_row,
            .start_col = start_col,
        });

        // If cursor is on this grid, increment cursor_rev to trigger global grid cursor clear
        if (self.cursor_grid == grid_id) {
            self.cursor_rev +%= 1;
        }

        return true;
    }

    /// Update position for a grid that is already external.
    /// Called when win_pos arrives after the grid was registered by win_split.
    pub fn updateExternalGridPos(self: *Grid, grid_id: i64, row: u32, col: u32) void {
        if (self.external_grids.getPtr(grid_id)) |info| {
            info.start_row = @intCast(row);
            info.start_col = @intCast(col);
        }
    }

    /// Check if a grid is external.
    pub fn isExternalGrid(self: *const Grid, grid_id: i64) bool {
        return self.external_grids.contains(grid_id);
    }

    pub fn setCursor(self: *Grid, grid_id: i64, row: u32, col: u32) void {
        const changed =
            (!self.cursor_valid) or
            (self.cursor_grid != grid_id) or
            (self.cursor_row != row) or
            (self.cursor_col != col);

        // Record previous cursor row for scroll-aware flush (only first move per batch).
        // Stored as global grid coordinate (offset by win_pos for sub-grids).
        if (changed and self.prev_cursor_row == null and self.cursor_valid) {
            const win_offset: u32 = if (self.cursor_grid != 1)
                if (self.win_pos.get(self.cursor_grid)) |p| p.row else 0
            else
                0;
            self.prev_cursor_row = win_offset + self.cursor_row;
            self.prev_cursor_grid = self.cursor_grid;

            // Note: sub_grid prev_cursor_row is NOT set here because external
            // grids render cursor as a separate layer (not inline in row vertices),
            // so no row regeneration is needed when cursor moves.
        }

        self.cursor_grid = grid_id;
        self.cursor_row = row;
        self.cursor_col = col;
        self.cursor_valid = true;

        if (changed) self.cursor_rev +%= 1;
    }

    /// Return the current cursor row in global-grid coordinates when the cursor is
    /// on the specified grid. Returns null if the cursor is hidden or on another grid.
    pub fn currentCursorMainRow(self: *const Grid, grid_id: i64) ?u32 {
        if (!self.cursor_valid or self.cursor_grid != grid_id) return null;

        const win_offset: u32 = if (grid_id != 1)
            if (self.win_pos.get(grid_id)) |p| p.row else 0
        else
            0;

        return win_offset + self.cursor_row;
    }

    /// Return the previous cursor row after applying the active scroll operation.
    /// This converts the pre-scroll screen row into the post-scroll screen row,
    /// which is the row that must be regenerated to clear old cursor text.
    pub fn prevCursorMainRowAfterScroll(self: *const Grid, scroll_op: ScrollOp) ?u32 {
        const prev_row = self.prev_cursor_row orelse return null;
        const prev_grid = self.prev_cursor_grid orelse return null;
        if (prev_grid != scroll_op.grid_id) return prev_row;

        const shifted = @as(i64, prev_row) - @as(i64, scroll_op.rows);
        if (shifted < 0) return null;

        const max_rows = @as(i64, scroll_op.win_pos_row) + @as(i64, scroll_op.target_rows);
        if (shifted >= max_rows) return null;

        return @intCast(shifted);
    }

    /// Set viewport info from win_viewport event.
    pub fn setViewport(
        self: *Grid,
        grid_id: i64,
        topline: i64,
        botline: i64,
        curline: i64,
        curcol: i64,
        line_count: i64,
        scroll_delta: i64,
    ) !void {
        try self.viewport.put(self.alloc, grid_id, .{
            .topline = topline,
            .botline = botline,
            .curline = curline,
            .curcol = curcol,
            .line_count = line_count,
            .scroll_delta = scroll_delta,
        });
    }

    /// Set viewport margins from win_viewport_margins event.
    pub fn setViewportMargins(
        self: *Grid,
        grid_id: i64,
        top: u32,
        bottom: u32,
        left: u32,
        right: u32,
    ) !void {
        try self.viewport_margins.put(self.alloc, grid_id, .{
            .top = top,
            .bottom = bottom,
            .left = left,
            .right = right,
        });
    }

    /// Get viewport margins for a grid. Returns default (all zeros) if not set.
    pub fn getViewportMargins(self: *const Grid, grid_id: i64) ViewportMargins {
        return self.viewport_margins.get(grid_id) orelse .{};
    }

    /// Get viewport for a grid. Returns null if not set.
    /// If grid_id is -1, returns viewport for the cursor's current grid.
    pub fn getViewport(self: *const Grid, grid_id: i64) ?Viewport {
        const effective_id = if (grid_id == -1) self.cursor_grid else grid_id;
        return self.viewport.get(effective_id);
    }

    /// Get Neovim window handle (winid) for a grid.
    /// If grid_id is -1, returns winid for the cursor's current grid.
    /// Returns null if the mapping is not available.
    pub fn getWinId(self: *const Grid, grid_id: i64) ?i64 {
        const effective_id = if (grid_id == -1) self.cursor_grid else grid_id;
        return self.grid_win_ids.get(effective_id);
    }

    // =========================================================================
    // ext_cmdline methods
    // =========================================================================

    /// Handle cmdline_show event.
    pub fn setCmdlineShow(
        self: *Grid,
        content: []const CmdlineChunk,
        pos: u32,
        firstc: u8,
        prompt: []const u8,
        indent: u32,
        level: u32,
        prompt_hl_id: u32,
    ) !void {
        const gop = try self.cmdline_states.getOrPut(self.alloc, level);
        if (!gop.found_existing) {
            gop.value_ptr.* = CmdlineState{};
        }

        const state = gop.value_ptr;

        // Free previous content text before clearing
        for (state.content.items) |chunk| {
            if (chunk.text.len > 0) {
                self.alloc.free(chunk.text);
            }
        }
        state.content.clearRetainingCapacity();

        // Dup and append each chunk's text (arena memory may be freed later)
        for (content) |chunk| {
            const duped_text = try self.alloc.dupe(u8, chunk.text);
            errdefer self.alloc.free(duped_text);
            try state.content.append(self.alloc, CmdlineChunk{
                .hl_id = chunk.hl_id,
                .text = duped_text,
            });
        }

        state.pos = pos;
        state.firstc = firstc;

        // Dupe new prompt first, then free old one (avoid dangling on OOM)
        const new_prompt = if (prompt.len > 0) try self.alloc.dupe(u8, prompt) else "";
        if (state.prompt.len > 0) {
            self.alloc.free(state.prompt);
        }
        state.prompt = new_prompt;

        state.indent = indent;
        state.level = level;
        state.prompt_hl_id = prompt_hl_id;
        state.visible = true;
        // Note: Do NOT reset special_char here!
        // special_char is set by cmdline_special_char event and should persist
        // until cleared by another cmdline_special_char event or cmdline_hide.

        self.cmdline_dirty = true;
    }

    /// Handle cmdline_hide event.
    pub fn setCmdlineHide(self: *Grid, level: u32) void {
        if (self.cmdline_states.getPtr(level)) |state| {
            state.visible = false;
            state.special_char_len = 0;
            state.special_shift = false;
        }
        self.cmdline_dirty = true;
    }

    /// Handle cmdline_pos event.
    pub fn setCmdlinePos(self: *Grid, pos: u32, level: u32) void {
        if (self.cmdline_states.getPtr(level)) |state| {
            state.pos = pos;
        }
        self.cmdline_dirty = true;
    }

    /// Handle cmdline_special_char event.
    pub fn setCmdlineSpecialChar(self: *Grid, c: []const u8, shift: bool, level: u32) void {
        if (self.cmdline_states.getPtr(level)) |state| {
            state.setSpecialChar(c);
            state.special_shift = shift;
        }
        self.cmdline_dirty = true;
    }

    /// Handle cmdline_block_show event.
    pub fn setCmdlineBlockShow(self: *Grid, lines: []const []const CmdlineChunk) !void {
        self.cmdline_block.clear(self.alloc);
        for (lines) |line| {
            var line_chunks: std.ArrayListUnmanaged(CmdlineChunk) = .{};
            errdefer {
                for (line_chunks.items) |chunk| {
                    if (chunk.text.len > 0) self.alloc.free(chunk.text);
                }
                line_chunks.deinit(self.alloc);
            }
            // Dup each chunk's text (arena memory may be freed later)
            for (line) |chunk| {
                const duped_text = try self.alloc.dupe(u8, chunk.text);
                errdefer self.alloc.free(duped_text);
                try line_chunks.append(self.alloc, CmdlineChunk{
                    .hl_id = chunk.hl_id,
                    .text = duped_text,
                });
            }
            try self.cmdline_block.lines.append(self.alloc, line_chunks);
        }
        self.cmdline_block.visible = true;
        self.cmdline_dirty = true;
    }

    /// Handle cmdline_block_append event.
    pub fn appendCmdlineBlock(self: *Grid, line: []const CmdlineChunk) !void {
        var line_chunks: std.ArrayListUnmanaged(CmdlineChunk) = .{};
        errdefer {
            for (line_chunks.items) |chunk| {
                if (chunk.text.len > 0) self.alloc.free(chunk.text);
            }
            line_chunks.deinit(self.alloc);
        }
        // Dup each chunk's text (arena memory may be freed later)
        for (line) |chunk| {
            const duped_text = try self.alloc.dupe(u8, chunk.text);
            errdefer self.alloc.free(duped_text);
            try line_chunks.append(self.alloc, CmdlineChunk{
                .hl_id = chunk.hl_id,
                .text = duped_text,
            });
        }
        try self.cmdline_block.lines.append(self.alloc, line_chunks);
        self.cmdline_dirty = true;
    }

    /// Handle cmdline_block_hide event.
    pub fn hideCmdlineBlock(self: *Grid) void {
        self.cmdline_block.visible = false;
        self.cmdline_dirty = true;
    }

    /// Get cmdline state for a level.
    pub fn getCmdlineState(self: *const Grid, level: u32) ?*const CmdlineState {
        return self.cmdline_states.getPtr(level);
    }

    /// Check if any cmdline is visible.
    pub fn isCmdlineVisible(self: *const Grid) bool {
        var it = self.cmdline_states.iterator();
        while (it.next()) |e| {
            if (e.value_ptr.visible) return true;
        }
        return false;
    }

    /// Clear cmdline dirty flag.
    pub fn clearCmdlineDirty(self: *Grid) void {
        self.cmdline_dirty = false;
    }

    // --- ext_popupmenu functions ---

    /// Handle popupmenu_show event.
    pub fn setPopupmenuShow(
        self: *Grid,
        items: []const PopupmenuItem,
        selected: i32,
        row: i32,
        col: i32,
        grid_id: i64,
    ) !void {
        // Clear previous items
        self.popupmenu.clear(self.alloc);

        // Copy items (dup strings from arena memory)
        for (items) |item| {
            const duped_word = if (item.word.len > 0) try self.alloc.dupe(u8, item.word) else "";
            errdefer if (duped_word.len > 0) self.alloc.free(duped_word);
            const duped_kind = if (item.kind.len > 0) try self.alloc.dupe(u8, item.kind) else "";
            errdefer if (duped_kind.len > 0) self.alloc.free(duped_kind);
            const duped_menu = if (item.menu.len > 0) try self.alloc.dupe(u8, item.menu) else "";
            errdefer if (duped_menu.len > 0) self.alloc.free(duped_menu);
            const duped_info = if (item.info.len > 0) try self.alloc.dupe(u8, item.info) else "";
            errdefer if (duped_info.len > 0) self.alloc.free(duped_info);
            try self.popupmenu.items.append(self.alloc, PopupmenuItem{
                .word = duped_word,
                .kind = duped_kind,
                .menu = duped_menu,
                .info = duped_info,
            });
        }

        self.popupmenu.selected = selected;
        self.popupmenu.row = row;
        self.popupmenu.col = col;
        self.popupmenu.grid_id = grid_id;
        self.popupmenu.visible = true;
        self.popupmenu.changed = true;
    }

    /// Handle popupmenu_hide event.
    pub fn setPopupmenuHide(self: *Grid) void {
        self.popupmenu.visible = false;
        self.popupmenu.changed = true;
    }

    /// Handle popupmenu_select event.
    pub fn setPopupmenuSelect(self: *Grid, selected: i32) void {
        self.popupmenu.selected = selected;
        self.popupmenu.changed = true;
    }

    /// Clear popupmenu changed flag.
    pub fn clearPopupmenuChanged(self: *Grid) void {
        self.popupmenu.changed = false;
    }

    // --- ext_tabline methods ---

    /// Handle tabline_update event.
    /// Uses build-then-swap: new data is fully constructed before touching
    /// old state. On allocation failure the old state and dirty flag are
    /// preserved unchanged so the frontend keeps the previous (correct) view.
    pub fn setTablineUpdate(
        self: *Grid,
        curtab: i64,
        tabs: []const TabEntry,
        curbuf: i64,
        buffers: []const BufferEntry,
    ) !void {
        // --- Phase 1: build new tab list (old state untouched on error) ---
        var new_tabs: std.ArrayListUnmanaged(TabEntry) = .{};
        errdefer {
            for (new_tabs.items) |t| {
                if (t.name.len > 0) self.alloc.free(t.name);
            }
            new_tabs.deinit(self.alloc);
        }
        for (tabs) |tab| {
            const duped_name = if (tab.name.len > 0) try self.alloc.dupe(u8, tab.name) else "";
            new_tabs.append(self.alloc, TabEntry{
                .tab_handle = tab.tab_handle,
                .name = duped_name,
            }) catch |e| {
                if (duped_name.len > 0) self.alloc.free(duped_name);
                return e;
            };
        }

        // --- Phase 2: build new buffer list (old state untouched on error) ---
        var new_bufs: std.ArrayListUnmanaged(BufferEntry) = .{};
        errdefer {
            for (new_bufs.items) |b| {
                if (b.name.len > 0) self.alloc.free(b.name);
            }
            new_bufs.deinit(self.alloc);
        }
        for (buffers) |buf| {
            const duped_name = if (buf.name.len > 0) try self.alloc.dupe(u8, buf.name) else "";
            new_bufs.append(self.alloc, BufferEntry{
                .buffer_handle = buf.buffer_handle,
                .name = duped_name,
            }) catch |e| {
                if (duped_name.len > 0) self.alloc.free(duped_name);
                return e;
            };
        }

        // --- Phase 3: all allocations succeeded → free old state, install new ---
        for (self.tabline_state.tabs.items) |t| {
            if (t.name.len > 0) self.alloc.free(t.name);
        }
        self.tabline_state.tabs.deinit(self.alloc);
        for (self.tabline_state.buffers.items) |b| {
            if (b.name.len > 0) self.alloc.free(b.name);
        }
        self.tabline_state.buffers.deinit(self.alloc);

        self.tabline_state.tabs = new_tabs;
        self.tabline_state.buffers = new_bufs;
        self.tabline_state.current_tab = curtab;
        self.tabline_state.current_buffer = curbuf;
        self.tabline_state.visible = tabs.len > 0;
        self.tabline_state.dirty = true;
    }

    /// Clear tabline dirty flag.
    pub fn clearTablineDirty(self: *Grid) void {
        self.tabline_state.dirty = false;
    }

    // --- ext_messages methods ---

    /// Handle msg_show event.
    /// content: array of [attr_id, text_chunk, hl_id] tuples
    pub fn setMsgShow(
        self: *Grid,
        kind: []const u8,
        content: []const MsgChunk,
        replace_last: bool,
        history: bool,
        append: bool,
        msg_id: i64,
    ) !void {
        // Discard empty messages (chunks=0). Neovim sends these (e.g., kind="empty")
        // as no-op events that should not create visible display.
        if (content.len == 0) return;

        // Route confirm/confirm_sub to singleton ConfirmMessage (noice.nvim pattern:
        // confirm lifecycle = cmdline lifecycle, stored separately from messages list).
        const is_confirm = std.mem.eql(u8, kind, "confirm") or
            std.mem.eql(u8, kind, "confirm_sub");
        if (is_confirm) {
            var cm = &self.message_state.confirm_msg;

            if (append and cm.active) {
                // Append to existing confirm (e.g., confirm_sub continuation)
                for (content) |chunk| {
                    cm.appendText(chunk.text);
                }
                if (msg_id != 0) cm.id = msg_id;
            } else {
                // New or replace confirm message
                if (!replace_last) cm.clear();
                // Copy kind
                const klen = @min(kind.len, cm.kind.len);
                @memcpy(cm.kind[0..klen], kind[0..klen]);
                cm.kind_len = klen;
                // Copy text from chunks
                if (replace_last) cm.text_len = 0; // Reset text for replace
                var primary_hl: u32 = cm.hl_id;
                for (content) |chunk| {
                    if (primary_hl == 0) primary_hl = chunk.hl_id;
                    const clen = @min(chunk.text.len, cm.text.len - cm.text_len);
                    @memcpy(cm.text[cm.text_len..][0..clen], chunk.text[0..clen]);
                    cm.text_len += clen;
                    if (cm.text_len >= cm.text.len) break;
                }
                cm.hl_id = primary_hl;
                cm.id = msg_id;
                cm.active = true;
            }

            self.message_state.confirm_dirty = true;
            return; // Do NOT add to messages list
        }

        // Singleton display for non-accumulating message kinds.
        // Neovim sends consecutive msg_show (e.g., undo) without msg_clear,
        // expecting the UI to show only the latest (like terminal command line behavior).
        // Shell output, list_cmd, and return_prompt accumulate by design.
        if (!append and !replace_last) {
            const is_accumulating =
                std.mem.eql(u8, kind, "shell_out") or
                std.mem.eql(u8, kind, "shell_err") or
                std.mem.eql(u8, kind, "list_cmd") or
                std.mem.eql(u8, kind, "return_prompt");
            if (!is_accumulating) {
                self.message_state.clearMessages(self.alloc);
            }
        }

        // If replace_last is true, replace the last message (or find by msg_id if non-zero)
        if (replace_last and self.message_state.messages.items.len > 0) {
            // Find message to replace: by msg_id if non-zero, otherwise last message
            var msg_to_replace: ?*Message = null;
            if (msg_id != 0) {
                for (self.message_state.messages.items) |*msg| {
                    if (msg.id == msg_id) {
                        msg_to_replace = msg;
                        break;
                    }
                }
            }
            // If not found by msg_id, replace last message
            if (msg_to_replace == null) {
                msg_to_replace = &self.message_state.messages.items[self.message_state.messages.items.len - 1];
            }

            if (msg_to_replace) |msg| {
                // Clear existing content
                for (msg.content.items) |chunk| {
                    if (chunk.text.len > 0) self.alloc.free(chunk.text);
                }
                msg.content.clearRetainingCapacity();

                // Copy new content
                for (content) |chunk| {
                    const duped_text = try self.alloc.dupe(u8, chunk.text);
                    errdefer self.alloc.free(duped_text);
                    try msg.content.append(self.alloc, MsgChunk{
                        .hl_id = chunk.hl_id,
                        .text = duped_text,
                    });
                }
                msg.history = history;
                msg.append = append;
                self.message_state.visible = true;
                self.message_state.msg_dirty = true;
                return;
            }
        }

        // If append is true, append to last message
        if (append and self.message_state.messages.items.len > 0) {
            const last_msg = &self.message_state.messages.items[self.message_state.messages.items.len - 1];
            for (content) |chunk| {
                const duped_text = try self.alloc.dupe(u8, chunk.text);
                errdefer self.alloc.free(duped_text);
                try last_msg.content.append(self.alloc, MsgChunk{
                    .hl_id = chunk.hl_id,
                    .text = duped_text,
                });
            }
            self.message_state.visible = true;
            self.message_state.msg_dirty = true;
            return;
        }

        // Cap accumulating messages to prevent unbounded memory growth.
        // Only evict when actually creating a new message (not on append/replace_last
        // which reuse existing entries and don't increase count).
        const max_messages = 1000;
        while (self.message_state.messages.items.len >= max_messages) {
            var oldest = self.message_state.messages.orderedRemove(0);
            oldest.deinit(self.alloc);
        }

        // Create new message
        var new_msg = Message{
            .id = msg_id,
            .kind = if (kind.len > 0) try self.alloc.dupe(u8, kind) else "",
            .history = history,
            .append = append,
            .replace_last = replace_last,
        };
        errdefer new_msg.deinit(self.alloc);

        // Copy content
        for (content) |chunk| {
            const duped_text = try self.alloc.dupe(u8, chunk.text);
            errdefer self.alloc.free(duped_text);
            try new_msg.content.append(self.alloc, MsgChunk{
                .hl_id = chunk.hl_id,
                .text = duped_text,
            });
        }

        try self.message_state.messages.append(self.alloc, new_msg);
        self.message_state.visible = true;
        self.message_state.msg_dirty = true;

        // Save snapshot for pending messages (survives msg_clear)
        if (self.message_state.pending_count < self.message_state.pending_messages.len) {
            var pm = &self.message_state.pending_messages[self.message_state.pending_count];
            pm.* = .{}; // Reset
            const kind_copy_len = @min(kind.len, pm.kind.len);
            @memcpy(pm.kind[0..kind_copy_len], kind[0..kind_copy_len]);
            pm.kind_len = kind_copy_len;

            // Build text from chunks
            var text_len: usize = 0;
            var primary_hl_id: u32 = 0;
            for (content) |chunk| {
                if (primary_hl_id == 0) primary_hl_id = chunk.hl_id;
                const copy_len = @min(chunk.text.len, pm.text.len - text_len);
                @memcpy(pm.text[text_len..][0..copy_len], chunk.text[0..copy_len]);
                text_len += copy_len;
                if (text_len >= pm.text.len) break;
            }
            pm.text_len = text_len;
            pm.hl_id = primary_hl_id;
            pm.replace_last = replace_last;
            pm.history = history;
            pm.append = append;
            pm.id = msg_id;
            self.message_state.pending_count += 1;
        }
    }

    /// Handle msg_clear event.
    /// Per Neovim docs, msg_clear only clears msg_show content (not showmode/showcmd/ruler).
    pub fn setMsgClear(self: *Grid) void {
        self.message_state.clearMessages(self.alloc);
        self.message_state.msg_dirty = true;
        self.message_state.msg_cleared_in_batch = true;
        if (self.message_state.confirm_msg.active) {
            self.message_state.confirm_msg.clear();
            self.message_state.confirm_dirty = true;
        }
        // Note: Do NOT clear pending_show here - it should survive msg_clear
    }

    /// Handle msg_showmode event.
    pub fn setMsgShowmode(self: *Grid, content: []const MsgChunk) !void {
        // Clear existing content
        for (self.message_state.showmode_content.items) |chunk| {
            if (chunk.text.len > 0) self.alloc.free(chunk.text);
        }
        self.message_state.showmode_content.clearRetainingCapacity();

        // Copy new content
        for (content) |chunk| {
            const duped_text = try self.alloc.dupe(u8, chunk.text);
            errdefer self.alloc.free(duped_text);
            try self.message_state.showmode_content.append(self.alloc, MsgChunk{
                .hl_id = chunk.hl_id,
                .text = duped_text,
            });
        }
        self.message_state.showmode_dirty = true;
    }

    /// Handle msg_showcmd event.
    pub fn setMsgShowcmd(self: *Grid, content: []const MsgChunk) !void {
        // Clear existing content
        for (self.message_state.showcmd_content.items) |chunk| {
            if (chunk.text.len > 0) self.alloc.free(chunk.text);
        }
        self.message_state.showcmd_content.clearRetainingCapacity();

        // Copy new content
        for (content) |chunk| {
            const duped_text = try self.alloc.dupe(u8, chunk.text);
            errdefer self.alloc.free(duped_text);
            try self.message_state.showcmd_content.append(self.alloc, MsgChunk{
                .hl_id = chunk.hl_id,
                .text = duped_text,
            });
        }
        self.message_state.showcmd_dirty = true;
    }

    /// Handle msg_ruler event.
    pub fn setMsgRuler(self: *Grid, content: []const MsgChunk) !void {
        // Clear existing content
        for (self.message_state.ruler_content.items) |chunk| {
            if (chunk.text.len > 0) self.alloc.free(chunk.text);
        }
        self.message_state.ruler_content.clearRetainingCapacity();

        // Copy new content
        for (content) |chunk| {
            const duped_text = try self.alloc.dupe(u8, chunk.text);
            errdefer self.alloc.free(duped_text);
            try self.message_state.ruler_content.append(self.alloc, MsgChunk{
                .hl_id = chunk.hl_id,
                .text = duped_text,
            });
        }
        self.message_state.ruler_dirty = true;
    }

    /// Handle msg_history_show event.
    pub fn setMsgHistoryShow(self: *Grid, entries: []const MsgHistoryEntry, prev_cmd: bool) !void {
        // Clear existing state
        self.msg_history_state.clear(self.alloc);

        // Copy entries
        for (entries) |entry| {
            var new_entry = MsgHistoryEntry{
                .kind = if (entry.kind.len > 0) try self.alloc.dupe(u8, entry.kind) else "",
                .append = entry.append,
            };
            errdefer new_entry.deinit(self.alloc);
            for (entry.content.items) |chunk| {
                const duped_text = try self.alloc.dupe(u8, chunk.text);
                errdefer self.alloc.free(duped_text);
                try new_entry.content.append(self.alloc, MsgChunk{
                    .hl_id = chunk.hl_id,
                    .text = duped_text,
                });
            }
            try self.msg_history_state.entries.append(self.alloc, new_entry);
        }

        self.msg_history_state.prev_cmd = prev_cmd;
        self.msg_history_state.dirty = true;
    }

    /// Clear msg_history_show dirty flag.
    pub fn clearMsgHistoryDirty(self: *Grid) void {
        self.msg_history_state.dirty = false;
    }

    /// Handle msg_history_clear event - clears history and marks dirty for UI update.
    pub fn setMsgHistoryClear(self: *Grid) void {
        self.msg_history_state.clear(self.alloc);
        self.msg_history_state.dirty = true; // Mark dirty so sendMsgHistoryShow gets called
    }

    /// Clear message dirty flags.
    pub fn clearMessageDirty(self: *Grid) void {
        self.message_state.msg_dirty = false;
        self.message_state.confirm_dirty = false;
        self.message_state.showmode_dirty = false;
        self.message_state.showcmd_dirty = false;
        self.message_state.ruler_dirty = false;
    }
};
