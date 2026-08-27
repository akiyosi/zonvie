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

/// Overflow map key: grid_id (full i64) combined with row and col.
/// Uses a struct key with AutoHashMap's default hashing to avoid
/// bit-packing collisions between negative reserved grid IDs and
/// positive Neovim grid IDs.
pub const OverflowKey = struct {
    grid_id: i64,
    row: u32,
    col: u32,
};

/// An overflow entry re-keyed by scrollOverflow after every source key has
/// been staged. Values are inline, so this owns no per-entry allocation.
const OverflowMoved = struct {
    new_key: OverflowKey,
    value: OverflowExtras,
};

/// Per-grid sparse index for `cell_overflow`. The global map remains the
/// value store, while this index makes grid-local probes and scroll/lifecycle
/// operations independent of overflow entries owned by unrelated grids.
const OverflowGridIndex = struct {
    keys: std.ArrayListUnmanaged(OverflowKey) = .empty,
    positions: std.AutoHashMapUnmanaged(OverflowKey, usize) = .{},

    fn deinit(self: *OverflowGridIndex, alloc: std.mem.Allocator) void {
        self.keys.deinit(alloc);
        self.positions.deinit(alloc);
    }

    fn clearRetainingCapacity(self: *OverflowGridIndex) void {
        self.keys.clearRetainingCapacity();
        self.positions.clearRetainingCapacity();
    }
};

/// Inline storage for extra codepoints (after the first) in a multi-codepoint cell.
/// Fixed-size to eliminate per-cell heap allocation on the redraw hot path.
/// 15 elements matches scanEmojiCluster extras and emoji_cluster_buf capacity,
/// covering the longest ZWJ sequences (e.g., kiss with skin tones = 9 extras).
pub const OverflowExtras = struct {
    buf: [15]u32 = undefined,
    len: u8 = 0,

    pub fn slice(self: *const OverflowExtras) []const u32 {
        return self.buf[0..self.len];
    }

    pub fn fromSlice(src: []const u32) !OverflowExtras {
        var e = OverflowExtras{};
        if (src.len > e.buf.len) return error.CellClusterTooLong;
        const n: u8 = @intCast(src.len);
        for (0..n) |i| e.buf[i] = src[i];
        e.len = n;
        return e;
    }
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
    content: std.ArrayListUnmanaged(CmdlineChunk) = .empty,
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
    scroll_offset: u32 = 0, // horizontal scroll for cursor-tracking

    pub fn deinit(self: *CmdlineState, alloc: std.mem.Allocator) void {
        // Free all duped text in chunks
        for (self.content.items) |chunk| {
            if (chunk.text.len > 0) {
                alloc.free(chunk.text);
            }
        }
        self.content.deinit(alloc);
        self.content = .empty;
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
    lines: std.ArrayListUnmanaged(std.ArrayListUnmanaged(CmdlineChunk)) = .empty,
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
        self.lines = .empty;
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

fn cmdlineContentByteLen(content: []const CmdlineChunk) u32 {
    var total: usize = 0;
    for (content) |chunk| total +|= chunk.text.len;
    return std.math.cast(u32, total) orelse std.math.maxInt(u32);
}

// ext_messages types

/// Reserved grid ID for ext_messages (displayed as external window).
pub const MESSAGE_GRID_ID: i64 = -102;

/// Reserved grid ID for msg_history_show (displayed as external window).
pub const MSG_HISTORY_GRID_ID: i64 = -103;

// Neovim supplies grid dimensions over RPC. Bound them before multiplying or
// allocating so a malformed/hostile peer cannot request multi-gigabyte grids.
// The row/column caps match the frontend row-storage safety limit; the cell cap
// still permits far more than any practical terminal (for example 4096x1024).
pub const MAX_GRID_ROWS: u32 = 20_000;
pub const MAX_GRID_COLS: u32 = 20_000;
pub const MAX_GRID_CELLS: usize = 4 * 1024 * 1024;
pub const MAX_TOTAL_GRID_CELLS: usize = 16 * 1024 * 1024;
// Sub-grid map entries retain independent metadata even when either dimension
// is zero and no cells are allocated. Bound that storage separately from the
// cell and placement budgets.
pub const MAX_SUBGRIDS: usize = 32 * 1024;
const MAX_SUBGRID_METADATA_BYTES: usize = 16 * 1024 * 1024;
pub const MAX_MAIN_SUBGRID_ROW_INDEX_BYTES: usize = 8 * 1024 * 1024;
const MAIN_SUBGRID_ROW_LAYOUT_BYTES: usize = @sizeOf(i64) + 2 * @sizeOf(u32);
// Window placements have independent storage even when the peer never creates
// a backing sub-grid (or creates a zero-cell grid). Bound their maps separately
// from MAX_TOTAL_GRID_CELLS so hostile win_pos/win_float_pos streams cannot
// grow placement and external-float scratch state until allocator exhaustion.
// 64K also keeps every placement-derived scratch list within its share of the
// core flush path's aggregate 8 MiB external-float budget.
pub const MAX_WINDOW_PLACEMENTS: usize = 64 * 1024;
// Overflow values are inline 15-scalar clusters stored in a hash map. Bound
// their independent memory footprint even when a hostile peer fills every
// otherwise-valid grid cell with a multi-scalar sequence. At current key/value
// sizes this keeps the map in the tens-of-megabytes range, including load-factor
// overhead, while allowing far more clusters than a practical visible surface.
pub const MAX_CELL_OVERFLOW_ENTRIES: usize = 128 * 1024;

pub fn windowPlacementInsertFits(current_count: usize, inserts_new_key: bool) bool {
    return !inserts_new_key or current_count < MAX_WINDOW_PLACEMENTS;
}

fn subgridInsertFits(current_count: usize, inserts_new_key: bool) bool {
    return !inserts_new_key or current_count < MAX_SUBGRIDS;
}

/// Frontend ABI placement fields are i32. Keep every read-side conversion
/// defined even if a caller bypasses the normal validated redraw ingestion.
pub fn saturatingI32FromU32(v: u32) i32 {
    return @intCast(@min(v, @as(u32, std.math.maxInt(i32))));
}

fn gridCoordFitsFrontend(v: u32) bool {
    return v <= @as(u32, std.math.maxInt(i32));
}

fn checkedGridCellCount(rows: u32, cols: u32) !usize {
    if (rows > MAX_GRID_ROWS or cols > MAX_GRID_COLS) return error.GridTooLarge;
    const count = std.math.mul(usize, @as(usize, rows), @as(usize, cols)) catch
        return error.GridTooLarge;
    if (count > MAX_GRID_CELLS) return error.GridTooLarge;
    return count;
}

fn cellOverflowInsertFits(current_count: usize, inserts_new_key: bool) bool {
    return !inserts_new_key or current_count < MAX_CELL_OVERFLOW_ENTRIES;
}

fn scrollChangesCells(
    grid_rows: u32,
    grid_cols: u32,
    top: u32,
    bot: u32,
    left: u32,
    right: u32,
    rows_delta: i32,
) bool {
    if (rows_delta == 0 or grid_rows == 0 or grid_cols == 0) return false;
    return @min(top, grid_rows) < @min(bot, grid_rows) and
        @min(left, grid_cols) < @min(right, grid_cols);
}

/// A single highlighted chunk in message content (same structure as CmdlineChunk).
pub const MsgChunk = struct {
    hl_id: u32,
    text: []const u8,
};

// A single displayed message is retained as a bounded logical tail. This
// covers :echon's append stream without letting one Message bypass the
// message-count cap indefinitely. The limits are intentionally fixed: there
// is no second caller that needs configurability, and frontend callbacks
// already consume message chunks as a finite snapshot.
const MAX_MESSAGE_BYTES: usize = 64 * 1024;
const MAX_MESSAGE_CHUNKS: usize = 256;

// cmdline_show carries a peer-supplied nesting level that keys a map with no
// other bound. Real nesting is a handful deep; this only stops a malformed or
// hostile stream from growing the map without limit.
const MAX_CMDLINE_LEVELS: usize = 64;

const MessageTailRef = struct {
    hl_id: u32,
    text: []const u8,
    old_index: ?usize,
};

fn utf8TailStart(text: []const u8, requested_start: usize) usize {
    var start = requested_start;
    while (start < text.len and text[start] & 0xC0 == 0x80) : (start += 1) {}
    return start;
}

fn collectMessageTailRef(
    refs_reversed: *[MAX_MESSAGE_CHUNKS]MessageTailRef,
    ref_count: *usize,
    bytes_remaining: *usize,
    chunk: MsgChunk,
    old_index: ?usize,
) bool {
    if (chunk.text.len == 0) return true;
    if (ref_count.* >= refs_reversed.len or bytes_remaining.* == 0) return false;

    const requested_start = chunk.text.len - @min(chunk.text.len, bytes_remaining.*);
    const start = utf8TailStart(chunk.text, requested_start);
    if (start == chunk.text.len) return false;
    const retained = chunk.text[start..];
    refs_reversed[ref_count.*] = .{
        .hl_id = chunk.hl_id,
        .text = retained,
        .old_index = if (start == 0) old_index else null,
    };
    ref_count.* += 1;
    bytes_remaining.* -= retained.len;

    // A partial chunk is the oldest retained byte range. Even if advancing to
    // a UTF-8 boundary left a few spare bytes, taking older content would no
    // longer produce a suffix of the logical message.
    return start == 0;
}

fn setMessageContentBounded(
    msg: *Message,
    alloc: std.mem.Allocator,
    incoming: []const MsgChunk,
    append: bool,
) !void {
    var refs_reversed: [MAX_MESSAGE_CHUNKS]MessageTailRef = undefined;
    var ref_count: usize = 0;
    var bytes_remaining = MAX_MESSAGE_BYTES;

    var i = incoming.len;
    while (i > 0) {
        i -= 1;
        if (!collectMessageTailRef(
            &refs_reversed,
            &ref_count,
            &bytes_remaining,
            incoming[i],
            null,
        )) break;
    }
    if (append and ref_count < refs_reversed.len and bytes_remaining != 0) {
        i = msg.content.items.len;
        while (i > 0) {
            i -= 1;
            if (!collectMessageTailRef(
                &refs_reversed,
                &ref_count,
                &bytes_remaining,
                msg.content.items[i],
                i,
            )) break;
        }
    }

    // Capacity growth and every required text duplication happen before any
    // owned old chunk is freed or the logical length changes. A failure may
    // increase spare capacity, but the observable Message remains unchanged.
    try msg.content.ensureTotalCapacity(alloc, ref_count);
    var final_chunks: [MAX_MESSAGE_CHUNKS]MsgChunk = undefined;
    var final_owned: [MAX_MESSAGE_CHUNKS]bool = .{false} ** MAX_MESSAGE_CHUNKS;
    var min_reused_old_index = msg.content.items.len;
    var final_count: usize = 0;
    while (final_count < ref_count) : (final_count += 1) {
        const ref = refs_reversed[ref_count - 1 - final_count];
        if (ref.old_index) |old_index| {
            final_chunks[final_count] = .{ .hl_id = ref.hl_id, .text = ref.text };
            min_reused_old_index = @min(min_reused_old_index, old_index);
        } else {
            const duped = alloc.dupe(u8, ref.text) catch |err| {
                for (final_chunks[0..final_count], final_owned[0..final_count]) |built, owned| {
                    if (owned and built.text.len != 0) alloc.free(built.text);
                }
                return err;
            };
            final_chunks[final_count] = .{ .hl_id = ref.hl_id, .text = duped };
            final_owned[final_count] = true;
        }
    }

    for (msg.content.items[0..min_reused_old_index]) |old| {
        if (old.text.len != 0) alloc.free(old.text);
    }
    msg.content.items.len = final_count;
    @memcpy(msg.content.items[0..final_count], final_chunks[0..final_count]);
}

fn messageRetainedBytes(msg: *const Message) usize {
    var total: usize = 0;
    for (msg.content.items) |chunk| total += chunk.text.len;
    return total;
}

/// A single message from Neovim's ext_messages.
pub const Message = struct {
    id: i64 = 0, // msg_id from Neovim
    kind: []const u8 = "", // "emsg", "echo", etc.
    content: std.ArrayListUnmanaged(MsgChunk) = .empty,
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
        self.content = .empty;
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
    messages: std.ArrayListUnmanaged(Message) = .empty,
    showmode_content: std.ArrayListUnmanaged(MsgChunk) = .empty,
    showcmd_content: std.ArrayListUnmanaged(MsgChunk) = .empty,
    ruler_content: std.ArrayListUnmanaged(MsgChunk) = .empty,
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
        self.messages = .empty;

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

    fn evictOldestMessages(self: *MessageState, alloc: std.mem.Allocator, requested: usize) void {
        const drop_count = @min(requested, self.messages.items.len);
        if (drop_count == 0) return;
        for (self.messages.items[0..drop_count]) |*msg| msg.deinit(alloc);

        const remain = self.messages.items.len - drop_count;
        std.mem.copyForwards(
            Message,
            self.messages.items[0..remain],
            self.messages.items[drop_count..],
        );
        self.messages.items.len = remain;
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
    content: std.ArrayListUnmanaged(MsgChunk) = .empty,
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
    entries: std.ArrayListUnmanaged(MsgHistoryEntry) = .empty,
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
    items: std.ArrayListUnmanaged(PopupmenuItem) = .empty,
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
        self.items = .empty;
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
    tabs: std.ArrayListUnmanaged(TabEntry) = .empty,
    buffers: std.ArrayListUnmanaged(BufferEntry) = .empty,
    current_tab: i64 = 0,
    current_buffer: i64 = 0,
    visible: bool = false,
    dirty: bool = false,

    pub fn deinit(self: *TablineState, alloc: std.mem.Allocator) void {
        for (self.tabs.items) |tab| {
            if (tab.name.len > 0) alloc.free(tab.name);
        }
        self.tabs.deinit(alloc);
        self.tabs = .empty;
        for (self.buffers.items) |buf| {
            if (buf.name.len > 0) alloc.free(buf.name);
        }
        self.buffers.deinit(alloc);
        self.buffers = .empty;
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
    blink_wait_ms: u32 = 0, // wait time before blink starts (ms), 0=no blink
    blink_on_ms: u32 = 0, // on time for blink cycle (ms)
    blink_off_ms: u32 = 0, // off time for blink cycle (ms)
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
    scroll_notify_pending: bool = false, // Independent of row-shift provenance; survives a pre-dispatch flush abort
    scroll_notify_rows: i32 = 0, // Signed rows accumulated for the pending notification; one event can cover several scrolls
    row_scroll_notify_pending: bool = false, // Consumed separately from on_grid_scroll notification delivery
    scroll_fast_path_blocked: bool = false, // True when multiple scrolls in same batch
    prev_cursor_row: ?u32 = null, // Previous cursor row (grid-relative) for erasing old cursor
    // Last submitted main-layer vertex count per row. Rendering uses this to
    // enforce actual-output budgets without rescanning every retained row.
    vertex_row_counts: []usize = &[_]usize{},
    surface_vertex_count: usize = 0,
    vertex_row_ledger_valid: bool = true,
    vertex_budget_touched: bool = false,
    vertex_budget_touched_next: ?i64 = null,

    fn deinit(self: *GridBuf, alloc: std.mem.Allocator) void {
        self.dirty_rows.deinit(alloc);
        if (self.cells.len != 0) alloc.free(self.cells);
        if (self.vertex_row_counts.len != 0) alloc.free(self.vertex_row_counts);
        self.cells = &[_]Cell{};
        self.vertex_row_counts = &[_]usize{};
        self.surface_vertex_count = 0;
        self.vertex_row_ledger_valid = true;
        self.vertex_budget_touched = false;
        self.vertex_budget_touched_next = null;
        self.rows = 0;
        self.cols = 0;
    }

    fn resize(self: *GridBuf, alloc: std.mem.Allocator, rows: u32, cols: u32) !void {
        const new_len = try checkedGridCellCount(rows, cols);
        const new_cells: []Cell = if (new_len == 0)
            &[_]Cell{}
        else
            try alloc.alloc(Cell, new_len);
        errdefer if (new_cells.len != 0) alloc.free(new_cells);
        if (new_cells.len != 0) @memset(new_cells, .{ .cp = ' ', .hl = 0 });
        // A zero-column grid cannot submit row vertices. Keep its ledger lazy
        // so repeated tall, zero-cell subgrids cannot bypass the cell budget
        // with rows * sizeof(usize) allocations.
        const new_vertex_row_counts: []usize = if (cols == 0 or rows == 0)
            &[_]usize{}
        else
            try alloc.alloc(usize, rows);
        errdefer if (new_vertex_row_counts.len != 0) alloc.free(new_vertex_row_counts);
        if (new_vertex_row_counts.len != 0) @memset(new_vertex_row_counts, 0);

        // Keep row metadata lazy for every zero-cell shape. Allocate a fresh
        // bitset before publishing any part of the resize so OOM preserves the
        // previous GridBuf in full.
        //
        // Note this leaves `bit_length` at 0 while `rows` is whatever was
        // asked for, so `bit_length >= rows` is NOT an invariant here the way
        // it is on Grid (see Grid.ensureDirtyCapacity). Anything reading
        // `dirty_rows` off a GridBuf has to check `bit_length` first.
        var new_dirty_rows: std.DynamicBitSetUnmanaged = .{};
        errdefer new_dirty_rows.deinit(alloc);
        if (new_len != 0) try new_dirty_rows.resize(alloc, rows, true);

        const min_rows = @min(self.rows, rows);
        const min_cols = @min(self.cols, cols);

        if (self.cells.len != 0) {
            // Row-level @memcpy instead of per-cell copy
            var r: u32 = 0;
            while (r < min_rows) : (r += 1) {
                const old_start: usize = @as(usize, r) * @as(usize, self.cols);
                const new_start: usize = @as(usize, r) * @as(usize, cols);
                @memcpy(new_cells[new_start .. new_start + min_cols], self.cells[old_start .. old_start + min_cols]);
            }
        }

        if (self.cells.len != 0) alloc.free(self.cells);
        if (self.vertex_row_counts.len != 0) alloc.free(self.vertex_row_counts);
        self.dirty_rows.deinit(alloc);
        self.cells = new_cells;
        self.vertex_row_counts = new_vertex_row_counts;
        self.dirty_rows = new_dirty_rows;
        self.surface_vertex_count = 0;
        self.vertex_row_ledger_valid = true;
        self.vertex_budget_touched = false;
        self.vertex_budget_touched_next = null;
        self.rows = rows;
        self.cols = cols;
        self.dirty = true;

        const dirty_end = @min(rows, self.dirty_rows.bit_length);
        self.dirty_rows.setRangeValue(.{ .start = 0, .end = dirty_end }, true);
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

        // Keep the last-submitted vertex ledger aligned with the frontend's
        // row-slot scroll. This is allocation-free and touches only the same
        // row interval already being moved below.
        if (self.vertex_row_ledger_valid and self.vertex_row_counts.len >= self.rows) {
            if (shift >= height) {
                for (top..bot) |row| {
                    self.surface_vertex_count -|= self.vertex_row_counts[row];
                    self.vertex_row_counts[row] = 0;
                }
            } else if (rows > 0) {
                for (top..top + shift) |row| {
                    self.surface_vertex_count -|= self.vertex_row_counts[row];
                }
                var row = top;
                while (row + shift < bot) : (row += 1) {
                    self.vertex_row_counts[row] = self.vertex_row_counts[row + shift];
                }
                for (bot - shift..bot) |vacated| self.vertex_row_counts[vacated] = 0;
            } else {
                for (bot - shift..bot) |row| {
                    self.surface_vertex_count -|= self.vertex_row_counts[row];
                }
                var row = bot;
                while (row > top + shift) {
                    row -= 1;
                    self.vertex_row_counts[row] = self.vertex_row_counts[row - shift];
                }
                for (top..top + shift) |vacated| self.vertex_row_counts[vacated] = 0;
            }
        }

        if (shift >= height) {
            var rr: u32 = top;
            while (rr < bot) : (rr += 1) {
                const off: usize = @as(usize, rr) * @as(usize, self.cols) + @as(usize, left);
                const slice = self.cells[off .. off + @as(usize, width)];
                @memset(slice, .{ .cp = ' ', .hl = 0 });
                // The entire scrolled region is vacated (no surviving shifted
                // content), unlike the shift < height case below — mark every
                // row dirty here too, or these blanked cells never reach the
                // frontend and the GPU-side region keeps its stale pre-scroll
                // content forever (core and GPU permanently disagree).
                if (rr < self.dirty_rows.bit_length) {
                    self.dirty_rows.set(rr);
                }
            }
            self.dirty = true;
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

    /// Clear content dirty flags after vertex generation. Scroll provenance is
    /// committed separately after on_flush_end accepts the whole transaction.
    pub fn clearDirtyContent(self: *GridBuf) void {
        self.dirty = false;
        if (self.dirty_rows.bit_length > 0) {
            self.dirty_rows.setRangeValue(.{ .start = 0, .end = self.dirty_rows.bit_length }, false);
        }
    }

    pub fn clearScrollState(self: *GridBuf) void {
        self.last_scroll_op = null;
        self.row_scroll_notify_pending = false;
        self.scroll_fast_path_blocked = false;
        self.prev_cursor_row = null;
    }

    /// Clear all state after a non-transactional caller has consumed it.
    pub fn clearDirty(self: *GridBuf) void {
        self.clearDirtyContent();
        self.clearScrollState();
    }

    /// Mark the entire sub-grid dirty: every row must be regenerated.
    /// Used by atlas-reset recovery paths where per-row UV invalidation
    /// cannot be attributed to specific rows. Mirrors the dirty-marking
    /// half of clear() (grid.zig `clear()`), without touching cell contents.
    /// No allocation: dirty_rows capacity is already sized to `rows` by
    /// resize(), so this is a pure bit-flip.
    pub fn markAllDirty(self: *GridBuf) void {
        self.dirty = true;
        if (self.dirty_rows.bit_length > 0) {
            self.dirty_rows.setRangeValue(.{ .start = 0, .end = self.dirty_rows.bit_length }, true);
        }
    }
};

// AutoHashMap's current maximum load is comfortably above 50%; charging two
// complete key/value/control slots per live entry is a conservative bound for
// both supported 64-bit frontends. Keep the fixed count cap within its private
// aggregate metadata budget as GridBuf evolves.
const SUBGRID_HASH_ENTRY_WORST_CASE_BYTES: usize = 2 * (@sizeOf(i64) + @sizeOf(GridBuf) + 1);
comptime {
    if (MAX_SUBGRIDS * SUBGRID_HASH_ENTRY_WORST_CASE_BYTES > MAX_SUBGRID_METADATA_BYTES) {
        @compileError("MAX_SUBGRIDS exceeds the aggregate sub-grid metadata budget");
    }
}

pub const GridPos = struct {
    row: u32,
    col: u32,
    anchor_grid: i64 = 1, // which grid this float is anchored to (1 = global grid)
    follows_scroll: bool = false, // float has been repositioned (row changed) after creation
};

const LayoutAccounting = struct {
    refs: usize = 0,
    layouts: usize = 0,
};

const LayoutProspective = struct {
    target_grid: ?i64 = null,
    position_set: bool = false,
    position: ?GridPos = null,
    external: ?bool = null,
    rows: ?u32 = null,
    cols: ?u32 = null,
    main_rows: ?u32 = null,
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
    // Coverage invalidation is needed once per top-level redraw notification,
    // while order above still advances for every grid_line tuple.
    coverage_dirty_epoch: u64 = 0,
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
    /// Neovim window handle this grid belongs to, from win_viewport. 0 until a
    /// win_viewport has been seen. Needed to address window-local options.
    win: i64 = 0,
    topline: i64 = 0,
    botline: i64 = 0,
    curline: i64 = 0,
    curcol: i64 = 0,
    line_count: i64 = 0,
    scroll_delta: i64 = 0,
    /// Screen rows the view moved that no grid_scroll accounted for, summed
    /// until the flush delivers them through on_grid_scroll and clears this.
    /// (The frontend used to poll for them; it no longer can, since a poll
    /// from inside a flush bracket would find grid_mu already held.)
    /// win_viewport's scroll_delta counts
    /// screen rows, so under 'smoothscroll' — where Neovim repaints instead of
    /// emitting grid_scroll — this is the only signal that content moved.
    /// Normal scrolling makes the two agree and this stays at 0.
    uncovered_scroll_rows: i64 = 0,
    /// A grid_scroll described this batch's movement. Set independently of the
    /// accumulator above because Neovim's ordering of grid_scroll against
    /// win_viewport within a batch is not fixed, and doing this with arithmetic
    /// made the result depend on which arrived first.
    scroll_covered: bool = false,
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

/// Main-grid dirty state remembered across one flush attempt, so a frontend
/// rejection can restore exactly what that flush consumed.
pub const DirtySnapshot = struct {
    dirty_all: bool = false,
    rows: std.DynamicBitSetUnmanaged = .{},

    pub fn deinit(self: *DirtySnapshot, alloc: std.mem.Allocator) void {
        self.rows.deinit(alloc);
        self.rows = .{};
    }
};

pub const Grid = struct {
    // Capacity of scroll_touched_rows below (declarations cannot be
    // interspersed between container fields, so this lives at the top of
    // the struct). flush.zig's regen_rows array has a comptime assertion
    // tying its size to this constant plus margin for cursor-row appends.
    pub const SCROLL_TOUCHED_ROWS_CAP: usize = 32;

    alloc: std.mem.Allocator,

    content_rev: u64 = 0, // cells / layering / resize / scroll etc
    // Materialized main row-index semantics: placement coverage and layer
    // order. Zero is reserved so wrap can reset per-layer epoch stamps.
    layout_generation: u64 = 1,
    // Completed vertex count across standalone subgrid surfaces. Membership,
    // resize, and row replacement update this incrementally so flush begin
    // never rescans every external grid after a layout generation change.
    subgrid_surface_vertex_count: usize = 0,
    main_row_index_ref_count: usize = 0,
    main_row_index_layout_count: usize = 0,
    row_index_budget_enabled: bool = false,
    redraw_epoch: u64 = 1,
    redraw_epoch_override: ?u64 = null,
    // Monotonic revision of the visible glyph working set across every
    // surface. Unlike content_rev, this includes external-only grids. It is
    // used only to retry atlas-capacity negative entries after content or
    // visibility really changes; dirty invalidation itself must not bump it.
    glyph_working_set_rev: u64 = 0,
    cursor_rev: u64 = 0, // cursor position/shape/attr/visibility

    // IME off request (set by mode_change, cleared after callback is called)
    ime_off_requested: bool = false,

    rows: u32 = 0,
    cols: u32 = 0,

    // Screen width in cells (for cmdline max width). Set by frontend.
    screen_cols: u32 = 0,
    // Cmdline width in cells before its content needs more (for cmdline min
    // width). Only the frontend knows how much window chrome sits beside the
    // cmdline grid, so it derives this from the main window width. 0 = fall
    // back to the main grid's cols.
    cmdline_default_cols: u32 = 0,
    // Dirty tracking (global grid only)
    dirty_all: bool = true,
    dirty_rows: std.DynamicBitSetUnmanaged = .{},

    cells: []Cell = &[_]Cell{},
    // O(1) aggregate allocation budget accounting for cells plus every
    // sub-grid. Updated only after a resize/destroy transaction commits.
    total_grid_cells: usize = 0,

    /// Extra codepoints for cells with multi-codepoint sequences (e.g., U+26A0 + U+FE0F).
    /// Key: OverflowKey{grid_id, row, col}. Value: heap-allocated slice of extra codepoints
    /// (codepoints after the first, which is stored in Cell.cp).
    /// Only populated for the rare cells where Neovim sends >1 codepoint per cell.
    cell_overflow: std.AutoHashMapUnmanaged(OverflowKey, OverflowExtras) = .{},

    /// Sparse keys partitioned by source grid. Child buffers retain capacity
    /// across cell redraw removals so scrolling stays allocation-free, but are
    /// released with their grid on clear/destroy/session reset.
    overflow_by_grid: std.AutoHashMapUnmanaged(i64, OverflowGridIndex) = .{},

    /// Bounded high-water scratch for sparse overflow scrolling. Capacity is
    /// reserved before each new map entry is published, making scroll itself
    /// allocation-free. MAX_CELL_OVERFLOW_ENTRIES bounds the combined scratch
    /// to roughly 15 MiB with the current Zig ArrayList growth policy and
    /// inline value layout.
    overflow_key_scratch: std.ArrayListUnmanaged(OverflowKey) = .empty,
    overflow_moved_scratch: std.ArrayListUnmanaged(OverflowMoved) = .empty,

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
    cursor_blink_wait_ms: u32 = 0, // wait time before blink starts (ms), 0=no blink
    cursor_blink_on_ms: u32 = 0, // on time for blink cycle (ms)
    cursor_blink_off_ms: u32 = 0, // off time for blink cycle (ms)

    cursor_style_enabled: bool = false,
    mode_infos: std.ArrayListUnmanaged(ModeInfo) = .empty,
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
    pending_grid_resizes: std.ArrayListUnmanaged(PendingGridResize) = .empty,

    // Last grid_resize seen for the global grid (id=1) in the current redraw
    // batch. Core compares it against the layout it last requested to detect
    // a Neovim-initiated resize (`:set columns=` / `:set lines=`).
    pending_main_grid_size: ?GridSize = null,

    // ext_windows: pending layout operations (win_move, win_exchange, etc.)
    pending_win_ops: std.ArrayListUnmanaged(PendingWinOp) = .empty,

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
    main_scroll_notify_pending: bool = false,
    main_scroll_notify_rows: i32 = 0,
    // More than 16 distinct grids can scroll in one redraw batch (many
    // external windows/floats). In that case flush derives the complete set
    // from the allocation-free per-grid scroll_notify_pending bits instead of
    // silently dropping callbacks.
    scrolled_grid_overflow: bool = false,

    // Pending scroll operation for scroll-aware flush optimization.
    // Set by scrollGrid(), consumed by flush, and cleared at transaction end.
    // When present, flush can potentially reuse row cache instead of recomposing all rows.
    // A second grid_scroll in the same batch disables fast path for that flush.
    pending_scroll: ?ScrollOp = null,

    // True when this batch observed multiple grid_scroll events and must not use
    // the scroll fast path. Cleared after flush via clearScrollState().
    scroll_fast_path_blocked: bool = false,

    // Rows touched by grid_line (via putCell/putCellGrid) AFTER pending_scroll was set.
    // These are global grid coordinates (already offset by win_pos for sub-grids).
    // Tracked as a fixed-size array to avoid allocation.  Capacity covers
    // high-speed mouse wheel batches (e.g. 10 grid_scroll × 3 grid_line rows).
    // Overflow blocks fast path but preserves pending_scroll for delta accumulation.
    // NOTE: flush.zig's regen_rows array has a comptime assertion tying its size
    // to SCROLL_TOUCHED_ROWS_CAP (declared above, near the top of this struct)
    // plus margin for cursor-row appends — if you raise this, that assertion
    // will fail to compile until regen_rows is resized too.
    scroll_touched_rows: [SCROLL_TOUCHED_ROWS_CAP]u32 = undefined,
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

    pub fn beginRedrawBatch(self: *Grid) u64 {
        self.redraw_epoch +%= 1;
        if (self.redraw_epoch == 0) {
            self.redraw_epoch = 1;
            var layer_it = self.win_layer.valueIterator();
            while (layer_it.next()) |layer| layer.coverage_dirty_epoch = 0;
        }
        return self.redraw_epoch;
    }

    fn advanceLayoutGeneration(self: *Grid) void {
        self.layout_generation +%= 1;
        if (self.layout_generation == 0) self.layout_generation = 1;
    }

    fn invalidateSubgridVertexSurface(self: *Grid, grid_id: i64) void {
        const sg = self.sub_grids.getPtr(grid_id) orelse return;
        self.subgrid_surface_vertex_count -|= sg.surface_vertex_count;
        sg.surface_vertex_count = 0;
        sg.vertex_row_ledger_valid = false;
    }

    pub fn setRowIndexBudgetEnabled(self: *Grid, enabled: bool) void {
        self.row_index_budget_enabled = enabled;
    }

    fn mainRowIndexByteSize(rows: u32, refs: usize, layouts: usize) ?usize {
        const row_count: usize = rows;
        const offset_count = std.math.add(usize, row_count, 1) catch return null;
        const row_slots = std.math.add(usize, offset_count, row_count) catch return null;
        const usize_count = std.math.add(usize, row_slots, refs) catch return null;
        const usize_bytes = std.math.mul(usize, usize_count, @sizeOf(usize)) catch return null;
        const layout_bytes = std.math.mul(usize, layouts, MAIN_SUBGRID_ROW_LAYOUT_BYTES) catch return null;
        return std.math.add(usize, usize_bytes, layout_bytes) catch null;
    }

    fn prospectiveExternal(self: *const Grid, grid_id: i64, prospective: LayoutProspective) bool {
        if (prospective.target_grid == grid_id) {
            if (prospective.external) |external| return external;
        }
        return self.external_grids.contains(grid_id);
    }

    fn prospectiveGridSize(self: *const Grid, grid_id: i64, prospective: LayoutProspective) ?GridSize {
        if (prospective.target_grid == grid_id and (prospective.rows != null or prospective.cols != null)) {
            const current = self.sub_grids.get(grid_id);
            return .{
                .rows = prospective.rows orelse if (current) |sg| sg.rows else 0,
                .cols = prospective.cols orelse if (current) |sg| sg.cols else 0,
            };
        }
        const sg = self.sub_grids.get(grid_id) orelse return null;
        return .{ .rows = sg.rows, .cols = sg.cols };
    }

    fn layoutContribution(
        self: *const Grid,
        grid_id: i64,
        pos: GridPos,
        prospective: LayoutProspective,
    ) LayoutAccounting {
        if (grid_id == 1 or self.prospectiveExternal(grid_id, prospective)) return .{};
        if (self.prospectiveExternal(pos.anchor_grid, prospective)) return .{};
        const size = self.prospectiveGridSize(grid_id, prospective) orelse return .{};
        if (size.rows == 0 or size.cols == 0) return .{};
        const main_rows = prospective.main_rows orelse self.rows;
        const start: usize = @min(@as(usize, pos.row), @as(usize, main_rows));
        const end: usize = @min(@as(usize, pos.row +| size.rows), @as(usize, main_rows));
        if (start >= end) return .{};
        return .{ .refs = end - start, .layouts = 1 };
    }

    fn computeLayoutAccounting(self: *const Grid, prospective: LayoutProspective) !LayoutAccounting {
        var accounting = LayoutAccounting{};
        var saw_target = false;
        var it = self.win_pos.iterator();
        while (it.next()) |entry| {
            const grid_id = entry.key_ptr.*;
            var pos = entry.value_ptr.*;
            if (prospective.target_grid == grid_id and prospective.position_set) {
                saw_target = true;
                pos = prospective.position orelse continue;
            } else if (prospective.target_grid == grid_id) {
                saw_target = true;
            }
            const contribution = self.layoutContribution(grid_id, pos, prospective);
            accounting.refs = std.math.add(usize, accounting.refs, contribution.refs) catch
                return error.LayoutTooComplex;
            accounting.layouts = std.math.add(usize, accounting.layouts, contribution.layouts) catch
                return error.LayoutTooComplex;
        }
        if (prospective.target_grid) |grid_id| {
            if (prospective.position_set and !saw_target) {
                if (prospective.position) |pos| {
                    const contribution = self.layoutContribution(grid_id, pos, prospective);
                    accounting.refs = std.math.add(usize, accounting.refs, contribution.refs) catch
                        return error.LayoutTooComplex;
                    accounting.layouts = std.math.add(usize, accounting.layouts, contribution.layouts) catch
                        return error.LayoutTooComplex;
                }
            }
        }
        return accounting;
    }

    fn validateLayoutAccounting(self: *const Grid, accounting: LayoutAccounting, main_rows: u32) !void {
        if (!self.row_index_budget_enabled) return;
        const bytes = mainRowIndexByteSize(main_rows, accounting.refs, accounting.layouts) orelse
            return error.LayoutTooComplex;
        if (bytes > MAX_MAIN_SUBGRID_ROW_INDEX_BYTES) return error.LayoutTooComplex;
    }

    fn prospectiveLayoutAccounting(self: *const Grid, prospective: LayoutProspective) !LayoutAccounting {
        const accounting = try self.computeLayoutAccounting(prospective);
        try self.validateLayoutAccounting(accounting, prospective.main_rows orelse self.rows);
        return accounting;
    }

    fn layoutAccountingAfterDelta(
        self: *const Grid,
        old: LayoutAccounting,
        new: LayoutAccounting,
    ) !LayoutAccounting {
        if (old.refs > self.main_row_index_ref_count or old.layouts > self.main_row_index_layout_count) {
            return error.LayoutTooComplex;
        }
        var accounting = LayoutAccounting{
            .refs = self.main_row_index_ref_count - old.refs,
            .layouts = self.main_row_index_layout_count - old.layouts,
        };
        accounting.refs = std.math.add(usize, accounting.refs, new.refs) catch
            return error.LayoutTooComplex;
        accounting.layouts = std.math.add(usize, accounting.layouts, new.layouts) catch
            return error.LayoutTooComplex;
        try self.validateLayoutAccounting(accounting, self.rows);
        return accounting;
    }

    fn commitLayoutAccounting(self: *Grid, accounting: LayoutAccounting) void {
        self.main_row_index_ref_count = accounting.refs;
        self.main_row_index_layout_count = accounting.layouts;
        self.advanceLayoutGeneration();
    }

    pub fn currentMainRowIndexByteSize(self: *const Grid) ?usize {
        return mainRowIndexByteSize(
            self.rows,
            self.main_row_index_ref_count,
            self.main_row_index_layout_count,
        );
    }

    fn checkedAggregateCellCount(self: *const Grid, old_len: usize, new_len: usize) !usize {
        if (old_len > self.total_grid_cells) return error.GridTooLarge;
        var total = self.total_grid_cells - old_len;
        total = std.math.add(usize, total, new_len) catch return error.GridTooLarge;
        if (total > MAX_TOTAL_GRID_CELLS) return error.GridTooLarge;
        return total;
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
        self.total_grid_cells = 0;

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

        // cell overflow (values are inline, no per-entry free needed)
        self.cell_overflow.deinit(self.alloc);
        var overflow_grid_it = self.overflow_by_grid.valueIterator();
        while (overflow_grid_it.next()) |index| index.deinit(self.alloc);
        self.overflow_by_grid.deinit(self.alloc);
        self.overflow_key_scratch.deinit(self.alloc);
        self.overflow_moved_scratch.deinit(self.alloc);
    }

    /// Reset all channel-bound state for a new RPC session (`:restart`,
    /// `:connect`, hot-swap connect, etc.).
    ///
    /// The new server uses a fresh grid_id space and never sends
    /// `grid_destroy` / `cmdline_hide` / `popupmenu_hide` / `tabline_hide`
    /// / `msg_clear` for the previous session's UI overlays. Without an
    /// explicit teardown, any leftover entry in `sub_grids` / `win_pos` /
    /// `win_layer` is rendered as a stale composited float by
    /// flush.zig:rebuildMain and reported as a visible grid by
    /// nvim_core.zig:getVisibleGridsLocked (hit-testing). The same logic
    /// applies to ext UI state that survives across the channel close.
    ///
    /// Preserves intentionally:
    ///   - global grid (id=1) cells / dimensions: the new session's
    ///     `grid_resize 1` + `grid_line` overwrite progressively, and the
    ///     frontend's last committed frame keeps the screen stable
    ///     between sessions (no flush runs in the gap).
    ///   - `hl` highlight table: owned outside this struct and reset by the
    ///     caller; the new session redefines hl_ids via hl_attr_define.
    ///   - mode info / cursor shape: redefined by the new session's
    ///     `mode_info_set` + `mode_change`.
    ///   - dirty bitmap state: `markAllDirty()` is invoked so the first
    ///     post-attach flush of the new session unconditionally rebuilds.
    ///
    /// Most clears retain capacity so the next session does not pay
    /// reallocation cost for typical workloads. Placement maps are released:
    /// their independent hostile-input limit is intentionally large, and a
    /// previous session's high-water allocation must not remain resident.
    pub fn resetForNewSession(self: *Grid) void {
        // Composited / multigrid layout: stale entries here would be
        // emitted as floats by flush.zig:rebuildMain (iterating win_pos)
        // and counted as visible by getVisibleGridsLocked.
        var sg_it = self.sub_grids.iterator();
        while (sg_it.next()) |e| {
            e.value_ptr.deinit(self.alloc);
        }
        self.sub_grids.deinit(self.alloc);
        self.sub_grids = .{};
        self.total_grid_cells = self.cells.len;
        self.win_pos.deinit(self.alloc);
        self.win_pos = .{};
        self.grid_win_ids.deinit(self.alloc);
        self.grid_win_ids = .{};
        self.win_layer.deinit(self.alloc);
        self.win_layer = .{};
        self.viewport.clearRetainingCapacity();
        self.viewport_margins.clearRetainingCapacity();
        self.grid_metrics.clearRetainingCapacity();
        self.clearAllOverflow();
        self.layer_order_counter = 0;
        self.layout_generation = 1;
        self.subgrid_surface_vertex_count = 0;
        self.main_row_index_ref_count = 0;
        self.main_row_index_layout_count = 0;
        self.redraw_epoch = 1;
        self.redraw_epoch_override = null;
        self.composited_win_closed = false;

        // Cursor: a stale `cursor_grid` pointing at a now-deleted sub_grid
        // would briefly drive cursor rendering at a stale offset before
        // the new session's first grid_cursor_goto arrives.
        self.cursor_grid = 1;
        self.cursor_row = 0;
        self.cursor_col = 0;
        self.cursor_valid = false;
        self.prev_cursor_row = null;
        self.prev_cursor_grid = null;

        // ext_cmdline: the new server has no notion of these levels.
        // Mark dirty so the next flush re-emits hide based on absence
        // of any visible level.
        var cm_it = self.cmdline_states.iterator();
        while (cm_it.next()) |e| {
            e.value_ptr.deinit(self.alloc);
        }
        self.cmdline_states.clearRetainingCapacity();
        self.cmdline_block.clear(self.alloc);
        self.cmdline_dirty = true;

        // ext_popupmenu / ext_tabline / ext_messages.
        self.popupmenu.clear(self.alloc);
        self.tabline_state.clear(self.alloc);
        self.message_state.clear(self.alloc);
        self.msg_history_state.clear(self.alloc);

        // Scroll bookkeeping: a pending op refers to the old session's
        // grid_id and would apply to an unrelated grid in the new
        // session if grid_ids overlap.
        self.pending_scroll = null;
        self.scroll_fast_path_blocked = false;
        self.scrolled_grid_count = 0;
        self.scrolled_grid_overflow = false;
        self.main_scroll_notify_pending = false;
        self.main_scroll_notify_rows = 0;
        var scroll_it = self.sub_grids.valueIterator();
        while (scroll_it.next()) |sg| {
            sg.scroll_notify_pending = false;
            sg.scroll_notify_rows = 0;
            sg.row_scroll_notify_pending = false;
        }
        self.scroll_touched_count = 0;

        // Bump revs so any rev-equality short-circuit (e.g. last_sent_*
        // tracking on the Core side) cannot match the new session's
        // first frame against the old session's last frame.
        self.content_rev +%= 1;
        self.glyph_working_set_rev +%= 1;
        self.cursor_rev +%= 1;

        // Force the first flush of the new session to redraw grid 1.
        // grid_resize will markAllDirty too, but this is the no-op-resize
        // case (same dimensions) where redraw_handler doesn't reach
        // resizeGrid.
        self.dirty_all = true;
    }

    // ── Cell overflow helpers ────────────────────────────────────────

    /// Get extra codepoints for a cell, or null if it has only one codepoint.
    pub fn getOverflow(self: *const Grid, grid_id: i64, row: u32, col: u32) ?[]const u32 {
        // Do not let an overflow cluster in another grid force a per-cell
        // lookup in this grid.
        if (self.overflowCountForGrid(grid_id) == 0) return null;
        if (self.cell_overflow.getPtr(.{ .grid_id = grid_id, .row = row, .col = col })) |v| {
            return v.slice();
        }
        return null;
    }

    pub fn overflowCountForGrid(self: *const Grid, grid_id: i64) usize {
        const index = self.overflow_by_grid.get(grid_id) orelse return 0;
        return index.keys.items.len;
    }

    fn ensureOverflowGridIndexCapacity(self: *Grid, key: OverflowKey) !void {
        const gop = try self.overflow_by_grid.getOrPut(self.alloc, key.grid_id);
        if (!gop.found_existing) gop.value_ptr.* = .{};
        try gop.value_ptr.keys.ensureUnusedCapacity(self.alloc, 1);
        try gop.value_ptr.positions.ensureUnusedCapacity(self.alloc, 1);
    }

    fn addOverflowIndexAssumeCapacity(self: *Grid, key: OverflowKey) void {
        const index = self.overflow_by_grid.getPtr(key.grid_id).?;
        std.debug.assert(!index.positions.contains(key));
        const pos = index.keys.items.len;
        index.keys.appendAssumeCapacity(key);
        index.positions.putAssumeCapacity(key, pos);
    }

    fn removeOverflowIndex(self: *Grid, key: OverflowKey) void {
        const index = self.overflow_by_grid.getPtr(key.grid_id) orelse return;
        const pos = index.positions.get(key) orelse return;
        const last_pos = index.keys.items.len - 1;
        const last_key = index.keys.items[last_pos];
        _ = index.positions.remove(key);
        index.keys.items.len = last_pos;
        if (pos != last_pos) {
            index.keys.items[pos] = last_key;
            index.positions.getPtr(last_key).?.* = pos;
        }
    }

    fn removeOverflowKey(self: *Grid, key: OverflowKey) bool {
        if (!self.cell_overflow.remove(key)) return false;
        self.removeOverflowIndex(key);
        return true;
    }

    fn releaseOverflowIndexForGrid(self: *Grid, grid_id: i64) void {
        if (self.overflow_by_grid.fetchRemove(grid_id)) |removed| {
            var index = removed.value;
            index.deinit(self.alloc);
        }
    }

    /// Remove overflow entry for a single cell.
    pub fn removeOverflow(self: *Grid, grid_id: i64, row: u32, col: u32) void {
        if (self.overflowCountForGrid(grid_id) == 0) return;
        _ = self.removeOverflowKey(.{ .grid_id = grid_id, .row = row, .col = col });
    }

    /// Remove all overflow entries.
    pub fn clearAllOverflow(self: *Grid) void {
        self.cell_overflow.clearRetainingCapacity();
        var it = self.overflow_by_grid.valueIterator();
        while (it.next()) |index| index.deinit(self.alloc);
        self.overflow_by_grid.deinit(self.alloc);
        self.overflow_by_grid = .{};
    }

    fn ensureOverflowScratchCapacity(self: *Grid, entry_count: usize) !void {
        try self.overflow_key_scratch.ensureTotalCapacity(self.alloc, entry_count);
        try self.overflow_moved_scratch.ensureTotalCapacity(self.alloc, entry_count);
    }

    /// Remove matching entries in one allocation-free map pass. Removing the
    /// iterator's current entry only marks that slot as a tombstone; the
    /// iterator's metadata storage and next index remain valid.
    fn removeOverflowMatching(self: *Grid, grid_id: i64, ctx: anytype, comptime match: fn (@TypeOf(ctx), OverflowKey) bool) void {
        const index = self.overflow_by_grid.getPtr(grid_id) orelse return;
        var i: usize = 0;
        while (i < index.keys.items.len) {
            const key = index.keys.items[i];
            if (match(ctx, key)) {
                _ = self.removeOverflowKey(key);
            } else {
                i += 1;
            }
        }
    }

    /// Remove all overflow entries for a specific grid_id.
    pub fn clearOverflowForGrid(self: *Grid, grid_id: i64) void {
        if (self.overflowCountForGrid(grid_id) != 0) {
            const Ctx = struct {
                grid_id: i64,
                fn match(c: @This(), k: OverflowKey) bool {
                    return k.grid_id == c.grid_id;
                }
            };
            self.removeOverflowMatching(grid_id, Ctx{ .grid_id = grid_id }, Ctx.match);
        }
        // Unlike per-cell removal, grid lifecycle operations must release the
        // child allocations and parent entry. Otherwise a stream of distinct
        // destroyed grid IDs retains every historical high-water capacity.
        self.releaseOverflowIndexForGrid(grid_id);
    }

    /// Remove overflow entries for a grid that fall outside [0, rows) x [0, cols).
    /// Entries within the overlap region are preserved (matching resize cell copy).
    pub fn trimOverflowForGrid(self: *Grid, grid_id: i64, rows: u32, cols: u32) void {
        if (self.overflowCountForGrid(grid_id) == 0) return;
        const Ctx = struct {
            grid_id: i64,
            rows: u32,
            cols: u32,
            fn match(c: @This(), k: OverflowKey) bool {
                return k.grid_id == c.grid_id and (k.row >= c.rows or k.col >= c.cols);
            }
        };
        self.removeOverflowMatching(grid_id, Ctx{ .grid_id = grid_id, .rows = rows, .cols = cols }, Ctx.match);
    }

    /// Move overflow entries during a scroll operation.
    /// Entries in the scroll region are shifted by `shift_rows`, entries in the
    /// vacated band are removed.
    pub fn scrollOverflow(self: *Grid, grid_id: i64, top: u32, bot: u32, left: u32, right: u32, rows_delta: i32) void {
        const grid_overflow_count = self.overflowCountForGrid(grid_id);
        if (grid_overflow_count == 0) return;
        if (rows_delta == 0 or top >= bot or left >= right) return;

        const shift: u32 = blk: {
            if (rows_delta == std.math.minInt(i32)) break :blk bot - top;
            const a: i32 = if (rows_delta < 0) -rows_delta else rows_delta;
            break :blk @as(u32, @intCast(a));
        };
        const height = bot - top;
        if (shift >= height) {
            self.clearOverflowRect(grid_id, top, bot, left, right);
            return;
        }

        // Collect only sparse overflow entries, not every cell in the scroll
        // rectangle. Scratch capacity is guaranteed at insertion time, so no
        // allocation or OOM branch exists after base cells have moved.
        std.debug.assert(self.overflow_key_scratch.capacity >= grid_overflow_count);
        std.debug.assert(self.overflow_moved_scratch.capacity >= grid_overflow_count);
        self.overflow_key_scratch.clearRetainingCapacity();
        self.overflow_moved_scratch.clearRetainingCapacity();
        const index = self.overflow_by_grid.getPtr(grid_id).?;
        for (index.keys.items) |key| {
            if (key.row < top or key.row >= bot or
                key.col < left or key.col >= right) continue;
            self.overflow_key_scratch.appendAssumeCapacity(key);

            const survives = if (rows_delta > 0)
                key.row >= top + shift
            else
                key.row < bot - shift;
            if (!survives) continue;
            self.overflow_moved_scratch.appendAssumeCapacity(.{
                .new_key = .{
                    .grid_id = grid_id,
                    .row = if (rows_delta > 0) key.row - shift else key.row + shift,
                    .col = key.col,
                },
                .value = self.cell_overflow.get(key).?,
            });
        }

        // Remove every original in the rectangle before re-inserting moved
        // values. The final count cannot exceed the pre-scroll count, so each
        // putAssumeCapacity is infallible even with tombstones.
        for (self.overflow_key_scratch.items) |key| {
            _ = self.removeOverflowKey(key);
        }
        for (self.overflow_moved_scratch.items) |moved| {
            self.cell_overflow.putAssumeCapacity(moved.new_key, moved.value);
            self.addOverflowIndexAssumeCapacity(moved.new_key);
        }
        self.overflow_moved_scratch.clearRetainingCapacity();
    }

    /// Remove overflow entries in a rectangular cell region.
    pub fn clearOverflowRect(self: *Grid, grid_id: i64, row_start: u32, row_end: u32, col_start: u32, col_end: u32) void {
        if (self.overflowCountForGrid(grid_id) == 0) return;
        const Ctx = struct {
            grid_id: i64,
            row_start: u32,
            row_end: u32,
            col_start: u32,
            col_end: u32,
            fn match(c: @This(), k: OverflowKey) bool {
                return k.grid_id == c.grid_id and
                    k.row >= c.row_start and k.row < c.row_end and
                    k.col >= c.col_start and k.col < c.col_end;
            }
        };
        self.removeOverflowMatching(grid_id, Ctx{
            .grid_id = grid_id,
            .row_start = row_start,
            .row_end = row_end,
            .col_start = col_start,
            .col_end = col_end,
        }, Ctx.match);
    }

    // ── End cell overflow helpers ────────────────────────────────────

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

    /// Grow `dirty_rows` to cover `rows`, leaving new bits clean.
    ///
    /// `Grid.resize` calls this unconditionally, which is what lets readers
    /// index `dirty_rows` by row without a length check first:
    /// `bit_length >= rows` holds for the global grid at all times. `GridBuf`
    /// gives no such guarantee — it skips the bitset entirely for a zero-cell
    /// shape while still updating `rows` — so its readers do have to test
    /// `bit_length` before `isSet`.
    pub fn ensureDirtyCapacity(self: *Grid, rows: u32) !void {
        // Grow only: a shrink leaves the bitset longer than `rows`, which the
        // `>=` invariant above allows. Initialize new bits as "clean" (false).
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
        // Clamping to `rows` is enough: `bit_length >= rows` holds for the
        // global grid at all times (see Grid.ensureDirtyCapacity), which is
        // the same invariant markDirtyRow relies on to set a bit unguarded.
        const end: usize = @as(usize, @min(bot, self.rows));
        if (start >= end) return;
        self.dirty_rows.setRangeValue(.{ .start = start, .end = end }, true);
    }

    pub fn markAllDirty(self: *Grid) void {
        // Fast path: avoid setting all bits; dirty_all dominates.
        self.dirty_all = true;
    }

    /// Shift previously-recorded touched rows by a new scroll delta.
    /// Rows that scroll out of the [top, bot) region are removed.
    /// Coordinates are in global grid space (win_pos_row already applied).
    fn shiftTouchedRows(self: *Grid, scroll_rows: i32, top: u32, bot: u32, win_pos_row: u32) void {
        // i64 covers every u32 grid coordinate plus an i32 scroll delta.
        // Keeping the comparison wide avoids both the old u32->i32 cast trap
        // and signed subtraction overflow for a hostile stored position.
        const main_top = @as(i64, top) + @as(i64, win_pos_row);
        const main_bot = @as(i64, bot) + @as(i64, win_pos_row);
        var write: u8 = 0;
        for (self.scroll_touched_rows[0..self.scroll_touched_count]) |tr| {
            const shifted = @as(i64, tr) - @as(i64, scroll_rows);
            if (shifted >= main_top and shifted < main_bot) {
                self.scroll_touched_rows[write] = @intCast(shifted);
                write += 1;
            }
        }
        self.scroll_touched_count = write;
    }

    /// Record a row touched by grid_line while a pending_scroll is active.
    /// Uses global grid coordinates. Deduplicates entries.
    /// On overflow, blocks fast path but preserves pending_scroll for delta accumulation.
    ///
    /// Overflow fallback behaviour per frontend:
    ///   macOS  – applyMainRowScrollRaw (MetalTerminalRenderer.swift) is NOT called;
    ///            fallback clears back texture and redraws all dirty rows from scratch.
    ///   Windows – onMainRowScroll (callbacks.zig) is NOT called;
    ///            fallback regenerates all dirty rows via on_vertices_row.
    /// Both paths produce correct output because the full dirty set covers
    /// every row affected by the accumulated scroll.
    fn recordScrollTouchedRow(self: *Grid, row: u32) void {
        if (self.pending_scroll == null) return;

        // Deduplicate: check if already recorded
        for (self.scroll_touched_rows[0..self.scroll_touched_count]) |r| {
            if (r == row) return;
        }

        // Overflow: too many distinct touched rows for fast path tracking.
        // Block fast path but KEEP pending_scroll so the accumulated delta
        // is preserved for subsequent grid_scroll events in the same batch.
        // Setting pending_scroll = null here would lose the accumulated rows
        // delta; the next grid_scroll would create a fresh pending_scroll
        // with only its own partial delta, causing the scroll cache fast
        // path to shift by the wrong amount.
        if (self.scroll_touched_count >= self.scroll_touched_rows.len) {
            self.scroll_fast_path_blocked = true;
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

    /// Copy the current main-grid dirty state into `out`, growing it only when
    /// the row count changed. Used to remember what a flush consumed so a
    /// frontend rejection can restore exactly that instead of resending every
    /// row. Allocation happens on layout change only, never per flush.
    pub fn snapshotDirty(self: *const Grid, alloc: std.mem.Allocator, out: *DirtySnapshot) !void {
        out.dirty_all = self.dirty_all;
        const len = self.dirty_rows.bit_length;
        if (out.rows.bit_length != len) {
            out.rows.deinit(alloc);
            out.rows = .{};
            out.rows = try std.DynamicBitSetUnmanaged.initEmpty(alloc, len);
        } else if (len != 0) {
            out.rows.unsetAll();
        }
        if (len == 0) return;
        var it = self.dirty_rows.iterator(.{});
        while (it.next()) |bit| out.rows.set(bit);
    }

    /// Re-apply a snapshot on top of the current state. Bits set since the
    /// snapshot stay set: a rejected flush must resend what it consumed plus
    /// anything that changed afterwards.
    pub fn restoreDirty(self: *Grid, snapshot: *const DirtySnapshot) void {
        if (snapshot.dirty_all) self.dirty_all = true;
        if (snapshot.rows.bit_length == 0 or self.dirty_rows.bit_length == 0) return;
        const len = @min(snapshot.rows.bit_length, self.dirty_rows.bit_length);
        var it = snapshot.rows.iterator(.{});
        while (it.next()) |bit| {
            if (bit >= len) break;
            self.dirty_rows.set(bit);
        }
    }

    /// Clear scroll-aware flush provenance (pending_scroll, touched rows, prev cursor).
    /// Called by flush after success, and on abort after forcing a full redraw.
    /// Notification provenance is separate and may survive a begin rejection.
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
        const new_len = try checkedGridCellCount(rows, cols);
        const new_total = try self.checkedAggregateCellCount(self.cells.len, new_len);
        const new_cells = try self.alloc.alloc(Cell, new_len);
        errdefer self.alloc.free(new_cells);

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
                @memcpy(new_cells[new_start .. new_start + min_cols], self.cells[old_start .. old_start + min_cols]);
            }
        }

        // The dirty bitset is part of the published grid shape. Grow it
        // before releasing the old cells so OOM leaves rows/cols/cells and
        // dirty metadata describing the same old grid.
        try self.ensureDirtyCapacity(rows);

        if (self.cells.len != 0) self.alloc.free(self.cells);
        self.cells = new_cells;
        self.rows = rows;
        self.cols = cols;
        self.total_grid_cells = new_total;
        self.clearDirty(); // reset bitset
        self.markAllDirty(); // everything needs redraw after resize
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
        self.glyph_working_set_rev +%= 1;

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
            // Clear overflow for the entire scrolled-out region
            self.clearOverflowRect(1, top, bot, left, right);
            // Mark every row in the region dirty. The caller (scrollGrid)
            // already bumps content_rev unconditionally, but need_main
            // alone is not enough: the row-mode flush's per-row loop skips
            // any row whose dirty_rows bit isn't set (checkScrollFastPath
            // already makes the fast path ineligible here — abs_rows >
            // region_height/2 — so it falls to the plain per-row dirty
            // check, not a full-region regen). Without this, the just-
            // cleared cells never get resent and the pre-scroll glyph
            // vertices stay on screen.
            self.markDirtyRect(top, bot);
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

        // Move overflow entries with the scrolled cells
        self.scrollOverflow(1, top, bot, left, right, rows);
    }

    pub fn resizeGrid(self: *Grid, grid_id: i64, rows: u32, cols: u32) !void {
        // Validate before getOrCreateSub so an invalid request cannot leave a
        // phantom empty sub-grid behind.
        _ = try checkedGridCellCount(rows, cols);
        if (grid_id == 1) {
            const shape_changed = self.rows != rows or self.cols != cols;
            const row_shape_changed = self.rows != rows;
            const new_accounting = if (row_shape_changed)
                try self.prospectiveLayoutAccounting(.{ .main_rows = rows })
            else
                LayoutAccounting{};
            try self.resize(rows, cols);
            if (row_shape_changed) self.commitLayoutAccounting(new_accounting);
            if (shape_changed) self.glyph_working_set_rev +%= 1;
            self.content_rev +%= 1;
            // Remove overflow entries that fall outside the new dimensions.
            // Entries within [0, rows) x [0, cols) are preserved (matching
            // the cell copy behavior of resize()).
            self.trimOverflowForGrid(grid_id, rows, cols);
            self.markAllDirty();
            return;
        }
        if (self.sub_grids.getPtr(grid_id)) |sg| {
            const old_rows = sg.rows;
            const shape_changed = sg.rows != rows or sg.cols != cols;
            const old_contribution = if (self.win_pos.get(grid_id)) |pos|
                self.layoutContribution(grid_id, pos, .{})
            else
                LayoutAccounting{};
            const size_prospective = LayoutProspective{
                .target_grid = grid_id,
                .rows = rows,
                .cols = cols,
            };
            const new_contribution = if (self.win_pos.get(grid_id)) |pos|
                self.layoutContribution(grid_id, pos, size_prospective)
            else
                LayoutAccounting{};
            const new_accounting = try self.layoutAccountingAfterDelta(old_contribution, new_contribution);
            const new_len = try checkedGridCellCount(rows, cols);
            const new_total = try self.checkedAggregateCellCount(sg.cells.len, new_len);
            const old_surface_vertex_count = sg.surface_vertex_count;
            try sg.resize(self.alloc, rows, cols);
            self.subgrid_surface_vertex_count -|= old_surface_vertex_count;
            if (old_contribution.refs != new_contribution.refs or
                old_contribution.layouts != new_contribution.layouts)
            {
                self.commitLayoutAccounting(new_accounting);
            }
            if (shape_changed and (self.win_pos.contains(grid_id) or self.external_grids.contains(grid_id))) {
                self.glyph_working_set_rev +%= 1;
            }
            self.total_grid_cells = new_total;
            self.trimOverflowForGrid(grid_id, rows, cols);

            // Only affect global grid state for composited grids (in win_pos).
            // External grids (not in win_pos) are rendered independently.
            if (self.win_pos.get(grid_id)) |p| {
                if (self.external_grids.contains(p.anchor_grid)) {
                    const h = @max(old_rows, rows);
                    var r: u32 = 0;
                    while (r < h) : (r += 1) self.dirtyCompositedRow(p, r);
                } else {
                    self.content_rev +%= 1;
                    self.markAllDirty();
                }
            }
            return;
        }

        const new_len = try checkedGridCellCount(rows, cols);
        const new_total = try self.checkedAggregateCellCount(0, new_len);
        if (!subgridInsertFits(self.sub_grids.count(), true)) return error.TooManySubgrids;
        const size_prospective = LayoutProspective{
            .target_grid = grid_id,
            .rows = rows,
            .cols = cols,
        };
        const new_contribution = if (self.win_pos.get(grid_id)) |pos|
            self.layoutContribution(grid_id, pos, size_prospective)
        else
            LayoutAccounting{};
        const new_accounting = try self.layoutAccountingAfterDelta(.{}, new_contribution);
        const sg = blk: {
            var new_grid: GridBuf = .{};
            errdefer new_grid.deinit(self.alloc);
            try new_grid.resize(self.alloc, rows, cols);
            try self.sub_grids.put(self.alloc, grid_id, new_grid);
            break :blk self.sub_grids.getPtr(grid_id).?;
        };
        _ = sg;
        if (new_contribution.layouts != 0) self.commitLayoutAccounting(new_accounting);
        self.total_grid_cells = new_total;
        if (self.win_pos.contains(grid_id) or self.external_grids.contains(grid_id)) {
            self.glyph_working_set_rev +%= 1;
        }
        self.trimOverflowForGrid(grid_id, rows, cols);
        if (self.win_pos.get(grid_id)) |p| {
            if (self.external_grids.contains(p.anchor_grid)) {
                var r: u32 = 0;
                while (r < rows) : (r += 1) self.dirtyCompositedRow(p, r);
            } else {
                self.content_rev +%= 1;
                self.markAllDirty();
            }
        }
    }

    pub fn clearGrid(self: *Grid, grid_id: i64) void {
        if (grid_id == 1) {
            self.glyph_working_set_rev +%= 1;
            self.content_rev +%= 1;
            self.clear();
            self.clearOverflowForGrid(1);
            self.markAllDirty();
            return;
        }
        if (self.sub_grids.getPtr(grid_id)) |sg| {
            sg.clear();
            if (self.win_pos.contains(grid_id) or self.external_grids.contains(grid_id)) {
                self.glyph_working_set_rev +%= 1;
            }
        }
        self.clearOverflowForGrid(grid_id);

        // Only affect global grid state for composited grids. A float anchored
        // to an external grid composites into that grid's window instead: dirty
        // the anchor's rows covered by the float (anchor-local translation is
        // handled by dirtyCompositedRow), not the main grid.
        if (self.win_pos.get(grid_id)) |p| {
            const h: u32 = if (self.sub_grids.get(grid_id)) |fsg| fsg.rows else 1;
            var r: u32 = 0;
            while (r < h) : (r += 1) {
                self.dirtyCompositedRow(p, r);
            }
        }
    }

    /// Route a composited grid's cell-change dirty state to the correct target.
    /// A win_pos grid normally composites into the MAIN grid: dirty the main
    /// row at p.row + row and bump content_rev. A float anchored to an
    /// EXTERNAL grid is instead composited into that anchor grid's own window
    /// (flush.zig ext composite path), so the ANCHOR subgrid must be dirtied —
    /// dirtying the main grid there would rebuild it spuriously at rows
    /// translated into the wrong coordinate space, while the float's real
    /// renderer keeps showing stale content.
    fn dirtyCompositedRow(self: *Grid, p: GridPos, row: u32) void {
        if (self.external_grids.get(p.anchor_grid)) |ext| {
            // win_pos.row for ext-anchored floats is stored in GLOBAL grid
            // units (redraw_handler adds ext start_row before setWinFloatPos),
            // while the ext composite recomposes anchor-LOCAL rows via
            // `float_pos.row - start_row` (flush.zig ext overlay). Translate
            // the same way here: marking the global row would dirty rows
            // offset by start_row (or nothing at all) and leave the truly
            // composited rows stale.
            if (ext.start_row < 0) return; // no position info: composite disabled
            if (self.sub_grids.getPtr(p.anchor_grid)) |asg| {
                asg.dirty = true;
                const local: i64 = @as(i64, p.row) + @as(i64, row) - @as(i64, ext.start_row);
                if (local >= 0 and local < @as(i64, @intCast(asg.dirty_rows.bit_length))) {
                    asg.dirty_rows.set(@intCast(local));
                }
            }
            return;
        }
        self.content_rev +%= 1;
        // Saturating: see shiftTouchedRows' guard above — markDirtyRow
        // clamps against self.rows, so a saturated value is simply ignored
        // instead of overflow-panicking or wrapping into an in-range row.
        const tr = p.row +| row;
        self.markDirtyRow(tr);
        self.recordScrollTouchedRow(tr);
    }

    /// Force-mark a cell's row dirty (for overflow-only changes where putCellGrid
    /// would no-op because cp+hl are unchanged).
    /// Also advances cursor_rev when the cursor is on this cell.
    pub fn markDirtyCellGrid(self: *Grid, grid_id: i64, row: u32, col: u32) void {
        if (grid_id == 1) {
            self.glyph_working_set_rev +%= 1;
            self.content_rev +%= 1;
            self.markDirtyRow(row);
            self.recordScrollTouchedRow(row);
            if (self.cursor_grid == 1 and self.cursor_row == row and self.cursor_col == col) {
                self.cursor_rev +%= 1;
            }
            return;
        }
        if (self.sub_grids.getPtr(grid_id)) |sg| {
            if (self.win_pos.contains(grid_id) or self.external_grids.contains(grid_id)) {
                self.glyph_working_set_rev +%= 1;
            }
            sg.dirty = true;
            if (sg.dirty_rows.bit_length > row) {
                sg.dirty_rows.set(row);
            }
            if (self.win_pos.get(grid_id)) |p| {
                self.dirtyCompositedRow(p, row);
            }
            if (self.cursor_grid == grid_id and self.cursor_row == row and self.cursor_col == col) {
                self.cursor_rev +%= 1;
            }
        }
    }

    pub fn putCellGrid(self: *Grid, grid_id: i64, row: u32, col: u32, cp: u32, hl: u32) void {
        if (grid_id == 1) {
            self.putCell(row, col, cp, hl);
            // Note: putCell already updates content_rev when cell changes
            return;
        }
        if (self.sub_grids.getPtr(grid_id)) |sg| {
            self.putCellSubGrid(sg, grid_id, row, col, cp, hl);
        }
    }

    fn putCellSubGrid(self: *Grid, sg: *GridBuf, grid_id: i64, row: u32, col: u32, cp: u32, hl: u32) void {
        const changed = sg.putCell(row, col, cp, hl);
        if (changed) {
            if (self.win_pos.contains(grid_id) or self.external_grids.contains(grid_id)) {
                self.glyph_working_set_rev +%= 1;
            }
            if (self.win_pos.get(grid_id)) |p| {
                // Composited grid: dirty the main grid, or the anchor
                // external grid for ext-anchored floats.
                self.dirtyCompositedRow(p, row);
            }
            // External grids (not in win_pos) do not affect global grid
            // content_rev or dirty state.

            // Advance cursor_rev if cursor is on this cell (to update cursor text)
            if (self.cursor_grid == grid_id and self.cursor_row == row and self.cursor_col == col) {
                self.cursor_rev +%= 1;
            }
        }
    }

    /// Atomically update a cell and its trailing cluster codepoints.
    /// Scratch/map growth happens before the base cell changes, so OOM cannot
    /// pair a new base scalar with stale/missing variation selectors, combining
    /// marks, or ZWJ components. At the bounded overflow limit, a new cluster
    /// degrades visibly to U+FFFD without aborting the surrounding redraw batch.
    pub fn putCellGridCluster(
        self: *Grid,
        grid_id: i64,
        row: u32,
        col: u32,
        cp: u32,
        hl: u32,
        extras: []const u32,
    ) !void {
        const sub_grid: ?*GridBuf = if (grid_id == 1)
            null
        else
            self.sub_grids.getPtr(grid_id) orelse return;
        if (grid_id == 1) {
            if (row >= self.rows or col >= self.cols) return;
        } else if (row >= sub_grid.?.rows or col >= sub_grid.?.cols) return;

        const key = OverflowKey{ .grid_id = grid_id, .row = row, .col = col };
        var overflow_changed = false;
        if (extras.len != 0) {
            const old = self.cell_overflow.getPtr(key);
            const is_new = old == null;
            if (!cellOverflowInsertFits(self.cell_overflow.count(), is_new)) {
                if (grid_id == 1) {
                    self.putCell(row, col, 0xFFFD, hl);
                } else {
                    self.putCellSubGrid(sub_grid.?, grid_id, row, col, 0xFFFD, hl);
                }
                return;
            }
            // Reject at the storage boundary too: callers other than redraw
            // decoding must never be able to reintroduce silent truncation.
            const value = try OverflowExtras.fromSlice(extras);
            overflow_changed = if (old) |old_value|
                !std.mem.eql(u32, old_value.slice(), value.slice())
            else
                true;
            // scrollOverflow must stay allocation-free after cells move. Grow
            // its bounded sparse scratch before publishing a new map entry.
            try self.ensureOverflowScratchCapacity(self.cell_overflow.count() + @intFromBool(is_new));
            if (is_new) try self.ensureOverflowGridIndexCapacity(key);
            // Publish overflow before the infallible base-cell mutation.
            // AutoHashMap.put leaves an old entry intact on OOM.
            try self.cell_overflow.put(self.alloc, key, value);
            if (is_new) self.addOverflowIndexAssumeCapacity(key);
        } else if (self.overflowCountForGrid(grid_id) != 0) {
            // Single-scalar cells dominate grid_line. Preserve the empty-map
            // fast path: no hash at all, and only one lookup when non-empty.
            overflow_changed = self.removeOverflowKey(key);
        }

        if (grid_id == 1) {
            self.putCell(row, col, cp, hl);
        } else {
            self.putCellSubGrid(sub_grid.?, grid_id, row, col, cp, hl);
        }
        if (overflow_changed) self.markDirtyCellGrid(grid_id, row, col);
    }

    pub fn scrollGrid(
        self: *Grid,
        grid_id: i64,
        top_in: u32,
        bot_in: u32,
        left_in: u32,
        right_in: u32,
        rows_in: i32,
        cols: i32,
    ) void {
        var target_rows = self.rows;
        var target_cols = self.cols;
        if (grid_id != 1) {
            const target = self.sub_grids.get(grid_id) orelse return;
            target_rows = target.rows;
            target_cols = target.cols;
        }
        if (target_rows == 0 or target_cols == 0 or rows_in == 0) return;

        // Establish one normalized region/delta used by cells, overflow
        // clusters, dirty tracking, and pending-scroll provenance. Previously
        // each layer clamped independently, so a full clear could leave stale
        // overflow entries or record impossible fast-path coordinates.
        const top = @min(top_in, target_rows);
        const bot = @min(bot_in, target_rows);
        const left = @min(left_in, target_cols);
        const right = @min(right_in, target_cols);
        if (top >= bot or left >= right) return;

        const height_i32: i32 = @intCast(bot - top);
        var rows = rows_in;
        if (rows > height_i32) rows = height_i32;
        if (rows < -height_i32) rows = -height_i32;

        if (grid_id == 1) {
            if (scrollChangesCells(self.rows, self.cols, top, bot, left, right, rows)) {
                self.glyph_working_set_rev +%= 1;
            }
        } else if (self.sub_grids.get(grid_id)) |sg| {
            if ((self.win_pos.contains(grid_id) or self.external_grids.contains(grid_id)) and
                scrollChangesCells(sg.rows, sg.cols, top, bot, left, right, rows))
            {
                self.glyph_working_set_rev +%= 1;
            }
        }

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
                    self.recordScrolledGrid(grid_id, rows);
                    ps.rows = std.math.add(i32, ps.rows, rows) catch {
                        self.scroll_fast_path_blocked = true;
                        self.scroll_touched_count = 0;
                        return;
                    };
                    return;
                }
                // Different grid or region: block fast path.
                self.scroll_fast_path_blocked = true;
                self.scroll_touched_count = 0;
            }
            self.scroll(top, bot, left, right, rows, cols);
            self.recordScrolledGrid(grid_id, rows);
            self.pending_scroll = .{
                .grid_id = grid_id,
                .top = top,
                .bot = bot,
                .left = left,
                .right = right,
                .rows = rows,
                .cols = cols,
                .target_rows = self.rows,
                .target_cols = self.cols,
                .win_pos_row = 0,
            };
            self.scroll_touched_count = 0;
            return;
        }
        if (self.sub_grids.getPtr(grid_id)) |sg| {
            const old_surface_vertex_count = sg.surface_vertex_count;
            sg.scroll(top, bot, left, right, rows, cols);
            self.subgrid_surface_vertex_count -|=
                old_surface_vertex_count -| sg.surface_vertex_count;
            self.scrollOverflow(grid_id, top, bot, left, right, rows);
            // Multiple scrolls in same batch block the fast path (same as global grid)
            if (sg.last_scroll_op != null) {
                sg.scroll_fast_path_blocked = true;
            }
            sg.last_scroll_op = .{
                .top = top,
                .bot = bot,
                .left = left,
                .right = right,
                .rows = rows,
                .cols = cols,
            };
            if (self.win_pos.get(grid_id)) |p| {
                if (self.external_grids.contains(p.anchor_grid)) {
                    // Float anchored to an EXTERNAL grid: it composites into
                    // that grid's own window, not the main grid. Dirty the
                    // scrolled region on the anchor (anchor-local rows via
                    // dirtyCompositedRow) instead of spuriously rebuilding
                    // the main grid at mistranslated rows and installing a
                    // main-grid pending_scroll for a float it never draws.
                    var r: u32 = top;
                    while (r < bot) : (r += 1) {
                        self.dirtyCompositedRow(p, r);
                    }
                    self.recordScrolledGrid(grid_id, rows);
                    return;
                }
                self.content_rev +%= 1;
                if (self.pending_scroll) |*ps| {
                    if (ps.grid_id == grid_id and ps.top == top and ps.bot == bot and
                        ps.left == left and ps.right == right and cols == 0)
                    {
                        // Same grid, same region: accumulate scroll delta.
                        self.shiftTouchedRows(rows, top, bot, p.row);
                        // Saturating: see shiftTouchedRows' guard above.
                        self.markDirtyRect(p.row +| top, p.row +| bot);
                        // Record here as well as on the fallthrough below: the
                        // notification carries the distance the content moved,
                        // and every accumulated scroll of this region moves it.
                        self.recordScrolledGrid(grid_id, rows);
                        ps.rows = std.math.add(i32, ps.rows, rows) catch {
                            self.scroll_fast_path_blocked = true;
                            self.scroll_touched_count = 0;
                            return;
                        };
                        return;
                    }
                    // Different grid or region: block fast path.
                    self.scroll_fast_path_blocked = true;
                    self.scroll_touched_count = 0;
                }
                // Saturating: see shiftTouchedRows' guard above.
                self.markDirtyRect(p.row +| top, p.row +| bot);
                self.pending_scroll = .{
                    .grid_id = grid_id,
                    .top = top,
                    .bot = bot,
                    .left = left,
                    .right = right,
                    .rows = rows,
                    .cols = cols,
                    .target_rows = sg.rows,
                    .target_cols = sg.cols,
                    .win_pos_row = p.row,
                };
                self.scroll_touched_count = 0;
            }
            // External grids (not in win_pos) do not affect global grid
            // content_rev, dirty state, or pending_scroll.

            self.recordScrolledGrid(grid_id, rows);
        }
    }

    /// Record that a grid received a scroll event (for frontend pixel offset clearing).
    /// Avoids duplicates within the same flush batch: several scrolls of the
    /// same grid produce one notification, so the rows they moved are summed
    /// into it. A frontend holding a sub-cell scroll offset has to give back
    /// exactly the distance the content travelled, which the notification alone
    /// could not tell it.
    fn recordScrolledGrid(self: *Grid, grid_id: i64, rows_delta: i32) void {
        if (grid_id == 1) {
            self.main_scroll_notify_pending = true;
            self.main_scroll_notify_rows +|= rows_delta;
        } else if (self.sub_grids.getPtr(grid_id)) |sg| {
            sg.scroll_notify_pending = true;
            sg.scroll_notify_rows +|= rows_delta;
            sg.row_scroll_notify_pending = true;
        }

        // Check if already recorded
        for (self.scrolled_grid_ids[0..self.scrolled_grid_count]) |id| {
            if (id == grid_id) return;
        }
        // Add if space available. Once full, the flush path scans authoritative
        // per-grid notification bits and ignores this partial prefix, avoiding both
        // dropped and duplicate notifications.
        if (self.scrolled_grid_count < self.scrolled_grid_ids.len) {
            self.scrolled_grid_ids[self.scrolled_grid_count] = grid_id;
            self.scrolled_grid_count += 1;
        } else {
            self.scrolled_grid_overflow = true;
        }
    }

    /// Signed rows accumulated for a grid's pending scroll notification.
    /// Zero for a grid with nothing pending, which is also what a caller that
    /// asks about an unknown grid gets.
    pub fn scrolledGridNotifyRows(self: *const Grid, grid_id: i64) i32 {
        if (grid_id == 1) return self.main_scroll_notify_rows;
        if (self.sub_grids.get(grid_id)) |sg| return sg.scroll_notify_rows;
        return 0;
    }

    /// Clear scrolled grid tracking (called after flush notification).
    pub fn clearScrolledGrids(self: *Grid) void {
        self.scrolled_grid_count = 0;
        self.scrolled_grid_overflow = false;
        self.main_scroll_notify_pending = false;
        self.main_scroll_notify_rows = 0;
        var sg_it = self.sub_grids.valueIterator();
        while (sg_it.next()) |sg| {
            sg.scroll_notify_pending = false;
            sg.scroll_notify_rows = 0;
            sg.row_scroll_notify_pending = false;
        }
    }

    /// Consume one successfully-invoked on_grid_scroll notification. Compact
    /// the fixed prefix so a mid-dispatch abort retries only IDs whose callback
    /// was not reached. In overflow mode the authoritative per-grid bits remain
    /// the source of truth; compacting still keeps diagnostics consistent.
    pub fn consumeScrolledGridNotification(self: *Grid, grid_id: i64) void {
        if (grid_id == 1) {
            self.main_scroll_notify_pending = false;
            self.main_scroll_notify_rows = 0;
        } else if (self.sub_grids.getPtr(grid_id)) |sg| {
            sg.scroll_notify_pending = false;
            sg.scroll_notify_rows = 0;
        }

        var index: usize = 0;
        while (index < self.scrolled_grid_count) : (index += 1) {
            if (self.scrolled_grid_ids[index] != grid_id) continue;
            var shift = index;
            while (shift + 1 < self.scrolled_grid_count) : (shift += 1) {
                self.scrolled_grid_ids[shift] = self.scrolled_grid_ids[shift + 1];
            }
            self.scrolled_grid_count -= 1;
            return;
        }
    }

    pub fn noteGridLine(self: *Grid, grid_id: i64, redraw_epoch: u64) void {
        // Only advance content_rev for grids composited on the main window.
        // grid_id==1 is the global grid (always composited).
        // Other grids are composited when they have a win_pos entry — except
        // floats anchored to an external grid, which composite into that
        // grid's own window: mark the anchor dirty instead of forcing a
        // spurious main rebuild.
        // External grids (not in win_pos) don't affect main window rendering.
        if (grid_id == 1) {
            self.content_rev +%= 1;
        } else if (self.win_pos.get(grid_id)) |p| {
            if (self.external_grids.contains(p.anchor_grid)) {
                if (self.sub_grids.getPtr(p.anchor_grid)) |asg| asg.dirty = true;
            } else {
                self.content_rev +%= 1;
            }
        }

        if (grid_id == 1) return;

        if (self.win_layer.getPtr(grid_id)) |layer| {
            self.layer_order_counter +%= 1;
            layer.order = self.layer_order_counter;
            self.glyph_working_set_rev +%= 1;
            self.advanceLayoutGeneration();

            if (layer.coverage_dirty_epoch == redraw_epoch) return;
            layer.coverage_dirty_epoch = redraw_epoch;

            // Changing the tie-break order can change overlap results across
            // the float's entire coverage, not only the grid_line row that
            // triggered this update. Recompose every covered row in the
            // actual target surface (main or an external anchor).
            if (self.win_pos.get(grid_id)) |p| {
                const h: u32 = if (self.sub_grids.get(grid_id)) |sg| sg.rows else 1;
                if (self.external_grids.contains(p.anchor_grid)) {
                    var r: u32 = 0;
                    while (r < h) : (r += 1) {
                        self.dirtyCompositedRow(p, r);
                    }
                } else {
                    self.markDirtyRect(p.row, p.row +| h);
                }
            }
        }
    }

    pub fn destroyGrid(self: *Grid, grid_id: i64) !void {
        if (grid_id == 1) {
            // Neovim's UI protocol never destroys the main grid (grid_id=1);
            // only a malformed/malicious server would send this. Calling
            // deinit() here would free all grid state without resetting it
            // to a safe empty value, so any later redraw event (or the
            // Core.stop() shutdown path, which also calls grid.deinit()
            // unconditionally) would operate on freed hashmap/array
            // metadata. Reject instead of destroying.
            return;
        }
        const was_visible = self.win_pos.contains(grid_id) or self.external_grids.contains(grid_id);
        const new_accounting = if (was_visible)
            try self.prospectiveLayoutAccounting(.{
                .target_grid = grid_id,
                .position_set = true,
                .position = null,
                .external = false,
            })
        else
            LayoutAccounting{};

        // Capture before removal below: needed to dirty the right target
        // (main grid vs. an external anchor) once grid_id's own state is gone.
        const old_pos = self.win_pos.get(grid_id);
        const old_rows: u32 = if (self.sub_grids.get(grid_id)) |sg| sg.rows else 1;

        if (self.sub_grids.fetchRemove(grid_id)) |kv| {
            var buf = kv.value;
            self.total_grid_cells -= buf.cells.len;
            self.subgrid_surface_vertex_count -|= buf.surface_vertex_count;
            buf.deinit(self.alloc);
        }
        self.clearOverflowForGrid(grid_id);
        _ = self.win_pos.remove(grid_id);
        _ = self.grid_win_ids.remove(grid_id);
        _ = self.win_layer.remove(grid_id);
        // Clean up per-grid metadata that was previously leaked on destroy.
        _ = self.grid_metrics.remove(grid_id);
        _ = self.viewport.remove(grid_id);
        _ = self.viewport_margins.remove(grid_id);
        self.invalidateSubgridVertexSurface(grid_id);
        _ = self.external_grids.remove(grid_id);
        _ = self.pending_ext_window_grids.remove(grid_id);
        _ = self.ext_windows_grids.remove(grid_id);
        _ = self.external_grid_target_sizes.remove(grid_id);

        if (old_pos) |p| {
            if (self.external_grids.contains(p.anchor_grid)) {
                // Float anchored to an external grid: composites into that
                // grid's own window (same reasoning as clearGrid/hideWin/
                // resizeGrid above). markAllDirty() only touches the MAIN
                // grid and would do nothing for this float's actual
                // container, leaving its last-drawn pixels on screen forever.
                var r: u32 = 0;
                while (r < old_rows) : (r += 1) {
                    self.dirtyCompositedRow(p, r);
                }
            } else {
                self.markAllDirty();
            }
        } else {
            self.markAllDirty();
        }

        if (self.cursor_grid == grid_id) {
            self.cursor_valid = false;
            self.cursor_rev +%= 1;
        }
        if (was_visible) self.glyph_working_set_rev +%= 1;
        if (was_visible) self.commitLayoutAccounting(new_accounting);
    }

    pub fn setWinPos(self: *Grid, grid_id: i64, win_id: i64, row: u32, col: u32) !void {
        // Positions are only meaningful for sub-grids (windows)
        if (grid_id == 1) return;
        if (!gridCoordFitsFrontend(row) or !gridCoordFitsFrontend(col)) return;

        const is_external = self.external_grids.contains(grid_id);
        const grid_win_is_new = !self.grid_win_ids.contains(grid_id);
        const win_pos_is_new = !is_external and !self.win_pos.contains(grid_id);
        if (!windowPlacementInsertFits(self.grid_win_ids.count(), grid_win_is_new) or
            !windowPlacementInsertFits(self.win_pos.count(), win_pos_is_new))
        {
            return error.TooManyWindowPlacements;
        }

        // Reserve every fallible insertion before changing composition. An
        // allocation failure must not remove a float layer or dirty its old
        // coverage while leaving the replacement position unrecorded.
        if (grid_win_is_new) try self.grid_win_ids.ensureUnusedCapacity(self.alloc, 1);
        if (win_pos_is_new) try self.win_pos.ensureUnusedCapacity(self.alloc, 1);

        // win_pos is only ever sent for non-floating positioning (floats use
        // win_float_pos). If this grid_id is currently tracked as a float
        // (present in win_layer), this event means Neovim just converted it
        // into a normal split (e.g. `:wincmd J` on a floating picker) with no
        // intervening win_close/grid_destroy. Remove the stale float-layer
        // entry so composition z-ordering (flush.zig), external-window
        // promotion (rpc_session.zig), and composited_win_closed detection
        // (redraw_handler.zig) stop treating this grid as a float.
        const was_float = self.win_layer.contains(grid_id);
        const old_pos_before = self.win_pos.get(grid_id);
        const old_contribution = if (old_pos_before) |old_pos|
            self.layoutContribution(grid_id, old_pos, .{})
        else
            LayoutAccounting{};
        const new_pos = GridPos{ .row = row, .col = col };
        const new_contribution = if (!is_external)
            self.layoutContribution(grid_id, new_pos, .{})
        else
            LayoutAccounting{};
        const new_accounting = if (!is_external)
            try self.layoutAccountingAfterDelta(old_contribution, new_contribution)
        else
            LayoutAccounting{};

        // Store grid_id -> winid mapping
        if (grid_win_is_new) {
            self.grid_win_ids.putAssumeCapacityNoClobber(grid_id, win_id);
        } else if (self.grid_win_ids.getPtr(grid_id)) |win_id_ptr| {
            win_id_ptr.* = win_id;
        }

        _ = self.win_layer.remove(grid_id);

        // If this grid is external (ext_windows split), keep it external.
        // win_pos events still arrive for external grids but should not
        // pull them back into the composited layout.
        if (is_external) return;

        const old_pos_opt = old_pos_before;
        if (old_pos_opt) |old_pos| {
            // If no actual change, do nothing (avoid increasing dirty state)
            if (old_pos.row == row and old_pos.col == col and !was_float) return;
        }

        // First dirty the old range (position changed, so exposed area needs recomposition)
        if (old_pos_opt) |old_pos| {
            const h_old: u32 = if (self.sub_grids.get(grid_id)) |sg| sg.rows else 1;
            self.markDirtyRect(old_pos.row, old_pos.row +| h_old);
        }

        if (win_pos_is_new) {
            self.win_pos.putAssumeCapacityNoClobber(grid_id, new_pos);
        } else if (self.win_pos.getPtr(grid_id)) |pos_ptr| {
            pos_ptr.* = new_pos;
        }

        // Dirty the new range
        const h_new: u32 = if (self.sub_grids.get(grid_id)) |sg| sg.rows else 1;
        self.markDirtyRect(row, row +| h_new);

        // Bump content_rev so the next flush's need_main is true and actually
        // recomposes the window at its new position. markDirtyRect alone is
        // insufficient: need_main gates the whole main rebuild on content_rev,
        // so a win_pos-only batch (layout reshuffle with unchanged content)
        // would otherwise be dropped by the flush, which also clears the dirty
        // rows just marked above. Mirrors the setWinFloatPos fix below.
        self.content_rev +%= 1;
        self.glyph_working_set_rev +%= 1;
        self.commitLayoutAccounting(new_accounting);

        // Only advance cursor_rev if cursor is on this grid
        if (self.cursor_grid == grid_id and self.cursor_valid) {
            self.cursor_rev +%= 1;
        }

        // NOTE: Do not call markAllDirty here
    }

    /// Transactionally move an external grid back into the main composite.
    /// Ordinary win_pos events intentionally keep external grids external;
    /// ext_windows promotion is the explicit exception.
    pub fn promoteExternalToWinPos(self: *Grid, grid_id: i64, win_id: i64, row: u32, col: u32) !void {
        if (!gridCoordFitsFrontend(row) or !gridCoordFitsFrontend(col)) return;
        if (!self.external_grids.contains(grid_id)) {
            return self.setWinPos(grid_id, win_id, row, col);
        }

        const new_pos = GridPos{ .row = row, .col = col };
        const new_accounting = try self.prospectiveLayoutAccounting(.{
            .target_grid = grid_id,
            .position_set = true,
            .position = new_pos,
            .external = false,
        });

        // setWinPos becomes infallible once both possible insertions have
        // capacity. Reserve before removing external visibility so OOM leaves
        // the old surface and all placement metadata untouched.
        if (!self.grid_win_ids.contains(grid_id)) {
            if (!windowPlacementInsertFits(self.grid_win_ids.count(), true)) {
                return error.TooManyWindowPlacements;
            }
            try self.grid_win_ids.ensureUnusedCapacity(self.alloc, 1);
        }
        if (!self.win_pos.contains(grid_id)) {
            if (!windowPlacementInsertFits(self.win_pos.count(), true)) {
                return error.TooManyWindowPlacements;
            }
            try self.win_pos.ensureUnusedCapacity(self.alloc, 1);
        }

        self.invalidateSubgridVertexSurface(grid_id);
        _ = self.external_grids.remove(grid_id);
        try self.setWinPos(grid_id, win_id, row, col);
        // setWinPos accounts for this grid's new placement. Removing the
        // external classification can also move floats anchored to this grid
        // into the main composite, so publish the exact prevalidated totals.
        self.main_row_index_ref_count = new_accounting.refs;
        self.main_row_index_layout_count = new_accounting.layouts;
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
        if (!gridCoordFitsFrontend(row) or !gridCoordFitsFrontend(col)) return;

        const was_external = self.external_grids.contains(grid_id);
        const old_pos_before = self.win_pos.get(grid_id);
        const old_layer_before = self.win_layer.get(grid_id);
        const working_set_changed = was_external or old_pos_before == null or
            old_pos_before.?.row != row or old_pos_before.?.col != col or
            old_pos_before.?.anchor_grid != anchor_grid or old_layer_before == null or
            old_layer_before.?.zindex != zindex or old_layer_before.?.compindex != compindex;

        const follows_scroll = if (old_pos_before) |old_pos|
            old_pos.follows_scroll or (old_pos.row != row)
        else
            false;
        const prospective_pos = GridPos{
            .row = row,
            .col = col,
            .anchor_grid = anchor_grid,
            .follows_scroll = follows_scroll,
        };
        const old_contribution = if (old_pos_before) |old_pos|
            self.layoutContribution(grid_id, old_pos, .{})
        else
            LayoutAccounting{};
        const new_accounting = if (was_external)
            try self.prospectiveLayoutAccounting(.{
                .target_grid = grid_id,
                .position_set = true,
                .position = prospective_pos,
                .external = false,
            })
        else blk: {
            const new_contribution = self.layoutContribution(grid_id, prospective_pos, .{});
            break :blk try self.layoutAccountingAfterDelta(old_contribution, new_contribution);
        };

        const grid_win_is_new = win_id > 0 and !self.grid_win_ids.contains(grid_id);
        const win_pos_is_new = old_pos_before == null;
        const win_layer_is_new = old_layer_before == null;

        if (!windowPlacementInsertFits(self.grid_win_ids.count(), grid_win_is_new) or
            !windowPlacementInsertFits(self.win_pos.count(), win_pos_is_new) or
            !windowPlacementInsertFits(self.win_layer.count(), win_layer_is_new))
        {
            return error.TooManyWindowPlacements;
        }

        // The three maps form one logical placement update. Grow all of them
        // before removing an external registration or dirtying either the old
        // or new coverage, so OOM leaves the previous placement intact.
        if (grid_win_is_new) try self.grid_win_ids.ensureUnusedCapacity(self.alloc, 1);
        if (win_pos_is_new) try self.win_pos.ensureUnusedCapacity(self.alloc, 1);
        if (win_layer_is_new) try self.win_layer.ensureUnusedCapacity(self.alloc, 1);

        // Store grid_id -> winid mapping (skip for grids without a real window, e.g. msg_set_pos)
        if (win_id > 0) {
            if (grid_win_is_new) {
                self.grid_win_ids.putAssumeCapacityNoClobber(grid_id, win_id);
            } else if (self.grid_win_ids.getPtr(grid_id)) |win_id_ptr| {
                win_id_ptr.* = win_id;
            }
        }

        // If this grid was external, remove it from external_grids.
        // This allows a grid to transition from external back to float.
        self.invalidateSubgridVertexSurface(grid_id);
        _ = self.external_grids.remove(grid_id);

        // Mark old position dirty if this float is moving
        var affects_main = false;
        // Sticky "buffer-tracking" flag: a float that is repositioned to a new
        // row after creation (e.g. to track a buffer line as the window scrolls)
        // may pixel-follow smooth scroll. A truly fixed float never changes row
        // and so must not pixel-shift. Only set on an actual reposition (old_pos
        // exists), never on the initial placement.
        const old_pos_opt = self.win_pos.get(grid_id);
        if (old_pos_opt) |old_pos| {
            const h_old: u32 = if (self.sub_grids.get(grid_id)) |sg| sg.rows else 1;
            // Affects the main composite unless anchored to an external grid
            // (those float over a separate top-level window, not the main grid).
            if (!self.external_grids.contains(old_pos.anchor_grid)) {
                self.markDirtyRect(old_pos.row, old_pos.row +| h_old);
                affects_main = true;
            } else {
                // Dirty the OLD coverage on the anchor's own sub_grid — a
                // move/hide-then-show with no accompanying cell change would
                // otherwise leave the vacated overlay area on that external
                // window showing stale float pixels forever (only cell
                // updates dirty the anchor today, via dirtyCompositedRow).
                var r: u32 = 0;
                while (r < h_old) : (r += 1) {
                    self.dirtyCompositedRow(old_pos, r);
                }
            }
        }

        const new_pos = prospective_pos;
        if (win_pos_is_new) {
            self.win_pos.putAssumeCapacityNoClobber(grid_id, new_pos);
        } else if (self.win_pos.getPtr(grid_id)) |pos_ptr| {
            pos_ptr.* = new_pos;
        }

        // Mark new position dirty so row-mode recomposes with float overlay.
        // Covers editor-anchored (anchor_grid==1) and window-anchored floats
        // (e.g. bufpos, anchor_grid>1) alike — both are composited into the main
        // grid, so creating/moving them must trigger a recompose.
        const h_new: u32 = if (self.sub_grids.get(grid_id)) |sg| sg.rows else 1;
        if (!self.external_grids.contains(anchor_grid)) {
            self.markDirtyRect(row, row +| h_new);
            affects_main = true;
        } else {
            // Same reasoning as the old-position branch above, for the NEW
            // coverage on an external anchor.
            var r: u32 = 0;
            while (r < h_new) : (r += 1) {
                self.dirtyCompositedRow(new_pos, r);
            }
        }

        // Bump content_rev so the next flush's need_main is true and actually
        // recomposes the float overlay at its new position. markDirtyRect alone
        // is insufficient: need_main gates the whole main rebuild on content_rev,
        // so a win_float_pos arriving without any accompanying content change
        // would otherwise leave the float composited at its stale row.
        if (affects_main) self.content_rev +%= 1;

        // Preserve existing order if present.
        const new_layer = WinLayer{
            .zindex = zindex,
            .compindex = compindex,
            .order = if (old_layer_before) |old| old.order else 0,
            .coverage_dirty_epoch = if (old_layer_before) |old| old.coverage_dirty_epoch else 0,
        };
        if (win_layer_is_new) {
            self.win_layer.putAssumeCapacityNoClobber(grid_id, new_layer);
        } else if (self.win_layer.getPtr(grid_id)) |layer_ptr| {
            layer_ptr.* = new_layer;
        }
        if (working_set_changed) self.glyph_working_set_rev +%= 1;
        if (working_set_changed) self.commitLayoutAccounting(new_accounting);
        if (self.cursor_grid == grid_id and self.cursor_valid) {
            self.cursor_rev +%= 1;
        }
    }

    pub fn hideWin(self: *Grid, grid_id: i64) !void {
        const was_visible = self.win_pos.contains(grid_id) or self.external_grids.contains(grid_id);
        const new_accounting = if (was_visible)
            try self.prospectiveLayoutAccounting(.{
                .target_grid = grid_id,
                .position_set = true,
                .position = null,
                .external = false,
            })
        else
            LayoutAccounting{};
        // Mark the rows this grid was covering as dirty before removal,
        // so they get recomposed with the underlying grid=1 content
        // (e.g., window separators that were previously overlaid).
        // Only bump content_rev when win_pos existed (grid was composited);
        // external-only grids don't affect global grid composition.
        if (self.win_pos.get(grid_id)) |pos| {
            if (self.external_grids.contains(pos.anchor_grid)) {
                // Float anchored to an external grid: it composites into
                // that grid's own window, not the main grid (same reasoning
                // as dirtyCompositedRow/setWinFloatPos). Dirtying the main
                // grid here would rebuild it spuriously at the wrong rows
                // while leaving the anchor's real overlay stale.
                const h: u32 = if (self.sub_grids.get(grid_id)) |sg| sg.rows else 1;
                var r: u32 = 0;
                while (r < h) : (r += 1) {
                    self.dirtyCompositedRow(pos, r);
                }
            } else {
                if (self.sub_grids.get(grid_id)) |sg| {
                    self.markDirtyRect(pos.row, pos.row +| sg.rows);
                } else {
                    self.markAllDirty();
                }
                self.content_rev +%= 1;
            }
        }
        _ = self.win_pos.remove(grid_id);
        _ = self.grid_win_ids.remove(grid_id);
        _ = self.win_layer.remove(grid_id);
        self.invalidateSubgridVertexSurface(grid_id);
        _ = self.external_grids.remove(grid_id);
        if (self.cursor_grid == grid_id) {
            self.cursor_valid = false;
            self.cursor_rev +%= 1;
        }
        if (was_visible) self.glyph_working_set_rev +%= 1;
        if (was_visible) self.commitLayoutAccounting(new_accounting);
    }

    /// Mark a grid as external (displayed in a separate top-level window).
    /// Returns true if this is a new external grid, false if it was already external.
    pub fn setWinExternalPos(self: *Grid, grid_id: i64, win: i64) !bool {
        if (grid_id == 1) return false; // Global grid cannot be external

        // Reserve every fallible map insertion before changing composition.
        // In particular, an external_grids OOM must not leave win_pos removed
        // while the grid is absent from the external registry.
        const grid_win_is_new = !self.grid_win_ids.contains(grid_id);
        if (!windowPlacementInsertFits(self.grid_win_ids.count(), grid_win_is_new) or
            !windowPlacementInsertFits(self.external_grids.count(), !self.external_grids.contains(grid_id)))
        {
            return error.TooManyWindowPlacements;
        }
        if (grid_win_is_new) try self.grid_win_ids.ensureUnusedCapacity(self.alloc, 1);

        // Check if already external
        if (self.external_grids.contains(grid_id)) {
            if (grid_win_is_new) {
                self.grid_win_ids.putAssumeCapacityNoClobber(grid_id, win);
            } else if (self.grid_win_ids.getPtr(grid_id)) |win_ptr| {
                win_ptr.* = win;
            }
            // Update the win handle (might be different window), preserve position
            if (self.external_grids.getPtr(grid_id)) |info| {
                info.win = win;
            }
            return false;
        }
        const new_accounting = try self.prospectiveLayoutAccounting(.{
            .target_grid = grid_id,
            .position_set = true,
            .position = null,
            .external = true,
        });
        try self.external_grids.ensureUnusedCapacity(self.alloc, 1);

        if (grid_win_is_new) {
            self.grid_win_ids.putAssumeCapacityNoClobber(grid_id, win);
        } else if (self.grid_win_ids.getPtr(grid_id)) |win_ptr| {
            win_ptr.* = win;
        }

        // Save position and mark covered rows dirty before removal.
        // Only bump content_rev when win_pos existed (grid was composited).
        var start_row: i32 = -1;
        var start_col: i32 = -1;
        if (self.win_pos.get(grid_id)) |pos| {
            start_row = saturatingI32FromU32(pos.row);
            start_col = saturatingI32FromU32(pos.col);
            if (self.sub_grids.get(grid_id)) |sg| {
                self.markDirtyRect(pos.row, pos.row +| sg.rows);
            } else {
                self.markAllDirty();
            }
            self.content_rev +%= 1;
        }

        // Remove from regular win_pos/win_layer (external grids are not composited)
        _ = self.win_pos.remove(grid_id);
        _ = self.win_layer.remove(grid_id);

        // Mark as external with position info
        self.invalidateSubgridVertexSurface(grid_id);
        self.external_grids.putAssumeCapacityNoClobber(grid_id, .{
            .win = win,
            .start_row = start_row,
            .start_col = start_col,
        });
        self.glyph_working_set_rev +%= 1;
        self.commitLayoutAccounting(new_accounting);

        // A newly registered frontend surface has no reusable vertex state,
        // even when the GridBuf stayed clean across win_hide (tab switch).
        // Regenerate every row in this flush so the new top-level window is
        // never left blank waiting for an unrelated Neovim update.
        if (self.sub_grids.getPtr(grid_id)) |sg| sg.markAllDirty();

        // If cursor is on this grid, increment cursor_rev to trigger global grid cursor clear
        if (self.cursor_grid == grid_id) {
            self.cursor_rev +%= 1;
        }

        return true;
    }

    /// Register an ext_windows grid and publish the position carried by the
    /// same win_pos event without inserting a transient composited placement.
    pub fn setWinExternalPosAt(self: *Grid, grid_id: i64, win: i64, row: u32, col: u32) !bool {
        if (!gridCoordFitsFrontend(row) or !gridCoordFitsFrontend(col)) return false;
        const is_new = try self.setWinExternalPos(grid_id, win);
        self.updateExternalGridPos(grid_id, row, col);
        return is_new;
    }

    /// Register/update a Core-owned synthetic external surface (cmdline,
    /// popupmenu, or message UI). Position-only updates keep the same visible
    /// glyph working set; first publication advances the atlas-recovery input.
    pub fn putSyntheticExternal(self: *Grid, grid_id: i64, info: ExternalGridInfo) !void {
        const is_new = !self.external_grids.contains(grid_id);
        if (!windowPlacementInsertFits(self.external_grids.count(), is_new)) {
            return error.TooManyWindowPlacements;
        }
        const new_accounting = if (is_new)
            try self.prospectiveLayoutAccounting(.{
                .target_grid = grid_id,
                .external = true,
            })
        else
            LayoutAccounting{};
        if (is_new) self.invalidateSubgridVertexSurface(grid_id);
        try self.external_grids.put(self.alloc, grid_id, info);
        if (is_new) {
            self.glyph_working_set_rev +%= 1;
            self.commitLayoutAccounting(new_accounting);
        }
    }

    /// Hide a Core-owned synthetic external surface. Returns whether it was
    /// visible, and advances the atlas-recovery input only on a real removal.
    pub fn removeSyntheticExternal(self: *Grid, grid_id: i64) !bool {
        if (!self.external_grids.contains(grid_id)) return false;
        const new_accounting = try self.prospectiveLayoutAccounting(.{
            .target_grid = grid_id,
            .external = false,
        });
        self.invalidateSubgridVertexSurface(grid_id);
        if (self.external_grids.fetchRemove(grid_id) == null) return false;
        self.glyph_working_set_rev +%= 1;
        self.commitLayoutAccounting(new_accounting);
        return true;
    }

    /// Update position for a grid that is already external.
    /// Called when win_pos arrives after the grid was registered by win_split.
    pub fn updateExternalGridPos(self: *Grid, grid_id: i64, row: u32, col: u32) void {
        if (!gridCoordFitsFrontend(row) or !gridCoordFitsFrontend(col)) return;
        if (self.external_grids.getPtr(grid_id)) |info| {
            info.start_row = saturatingI32FromU32(row);
            info.start_col = saturatingI32FromU32(col);
        }
    }

    /// Check if a grid is external.
    pub fn isExternalGrid(self: *const Grid, grid_id: i64) bool {
        return self.external_grids.contains(grid_id);
    }

    pub fn setCursor(self: *Grid, grid_id: i64, row: u32, col: u32) void {
        if (grid_id == 1) {
            if (row >= self.rows or col >= self.cols) return;
        } else {
            const sub_grid = self.sub_grids.get(grid_id) orelse return;
            if (row >= sub_grid.rows or col >= sub_grid.cols) return;
        }

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
            self.prev_cursor_row = win_offset +| self.cursor_row;
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

        return win_offset +| self.cursor_row;
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
        win: i64,
        topline: i64,
        botline: i64,
        curline: i64,
        curcol: i64,
        line_count: i64,
        scroll_delta: i64,
    ) !void {
        // Neovim emits viewport metadata for a live grid. Ignore malformed
        // unknown IDs instead of creating an independently unbounded map that
        // bypasses the subgrid count and metadata budgets.
        if (grid_id != 1 and !self.sub_grids.contains(grid_id)) return;
        // A movement larger than the window is a jump (gg, G, a tag jump), not
        // a scroll: Neovim documents scroll_delta as approximate past a screen,
        // nothing scrolled off the edge to retain, and a sub-cell offset cannot
        // smooth it anyway. Such a jump also invalidates any remainder still
        // waiting, so the running total restarts from it rather than carrying
        // a stale one that would later be reported as movement.
        const window_rows: i64 = if (grid_id == 1)
            @intCast(self.rows)
        else if (self.sub_grids.get(grid_id)) |sg| @intCast(sg.rows) else 0;
        const is_jump = window_rows > 0 and (scroll_delta > window_rows or scroll_delta < -window_rows);
        const previous = self.viewport.get(grid_id);
        const carried: i64 = if (is_jump)
            0
        else if (previous) |vp| vp.uncovered_scroll_rows else 0;
        const carried_covered = !is_jump and if (previous) |vp| vp.scroll_covered else false;
        try self.viewport.put(self.alloc, grid_id, .{
            .win = win,
            .topline = topline,
            .botline = botline,
            .curline = curline,
            .curcol = curcol,
            .line_count = line_count,
            .scroll_delta = scroll_delta,
            .uncovered_scroll_rows = if (is_jump) 0 else carried +| scroll_delta,
            .scroll_covered = carried_covered,
        });
    }

    /// A grid_scroll describes this batch's movement, so it is the authority
    /// for it and nothing is left over.
    ///
    /// Deliberately not `-= rows`: win_viewport's scroll_delta is documented as
    /// approximate once the movement passes a screen, and measured at 21 for a
    /// 24-row scroll of a 24-row window. Subtracting one from the other then
    /// leaves a phantom remainder that would be reported as movement of its
    /// own. Only a batch where grid_scroll said nothing at all — Neovim
    /// repainting a 'smoothscroll' window instead of shifting rows — leaves the
    /// viewport report as the sole description.
    pub fn creditScrollCoverage(self: *Grid, grid_id: i64, rows: i64) void {
        _ = rows;
        if (self.viewport.getPtr(grid_id)) |vp| {
            vp.scroll_covered = true;
        }
    }

    /// Take the leftover uncovered movement for a grid, clearing it.
    pub fn takeUncoveredScrollRows(self: *Grid, grid_id: i64) i64 {
        if (self.viewport.getPtr(grid_id)) |vp| {
            const rows = vp.uncovered_scroll_rows;
            vp.uncovered_scroll_rows = 0;
            return rows;
        }
        return 0;
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
        // Kept even for a grid that does not exist yet. Neovim announces a new
        // window's margins BEFORE the grid_resize that creates it — measured,
        // 2.6 ms before — and only resends them when they change, so dropping
        // them here left that window's winbar row inside the scrollable area
        // for the rest of the session. Bounded by the same budget as the
        // sub-grid metadata it accompanies.
        if (grid_id != 1 and !self.sub_grids.contains(grid_id)) {
            const inserts_new = !self.viewport_margins.contains(grid_id);
            if (!subgridInsertFits(self.viewport_margins.count(), inserts_new)) return;
            try self.viewport_margins.put(self.alloc, grid_id, .{
                .top = top,
                .bottom = bottom,
                .left = left,
                .right = right,
            });
            return;
        }
        // Stored as reported; getViewportMargins clamps against the grid's
        // current size. Clamping here instead would bake in whatever size the
        // grid happened to have when the margins arrived, and Neovim does not
        // resend them when the window is merely resized.
        const new_margins = ViewportMargins{
            .top = top,
            .bottom = bottom,
            .left = left,
            .right = right,
        };
        const old_margins = self.viewport_margins.get(grid_id) orelse ViewportMargins{};
        if (std.meta.eql(old_margins, new_margins)) return;

        // Publish the metadata before dirtying its consumers. If the map grows
        // and allocation fails, the previous margins and vertex state remain a
        // consistent pair and the redraw batch can be retried safely.
        try self.viewport_margins.put(self.alloc, grid_id, new_margins);

        if (grid_id == 1) {
            self.content_rev +%= 1;
            self.markAllDirty();
            return;
        }

        const sg = self.sub_grids.getPtr(grid_id) orelse return;
        // Standalone external grids consume this bitmap directly. It is also
        // harmless for composited grids, whose containing rows are dirtied
        // below so retained main/external-anchor row buffers are replaced.
        sg.markAllDirty();
        if (self.win_pos.get(grid_id)) |p| {
            var row: u32 = 0;
            while (row < sg.rows) : (row += 1) {
                self.dirtyCompositedRow(p, row);
            }
        }
    }

    /// Get viewport margins for a grid. Returns default (all zeros) if not set.
    pub fn getViewportMargins(self: *const Grid, grid_id: i64) ViewportMargins {
        const stored = self.viewport_margins.get(grid_id) orelse return .{};
        // Clamped on the way out, not on the way in: margins can be kept for a
        // grid whose size has not arrived yet, and clamping them against a size
        // of zero would erase them permanently.
        var rows = self.rows;
        var cols = self.cols;
        if (grid_id != 1) {
            const sg = self.sub_grids.get(grid_id) orelse return .{};
            rows = sg.rows;
            cols = sg.cols;
        }
        return .{
            .top = @min(stored.top, rows),
            .bottom = @min(stored.bottom, rows),
            .left = @min(stored.left, cols),
            .right = @min(stored.right, cols),
        };
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
        if (!self.cmdline_states.contains(level) and
            self.cmdline_states.count() >= MAX_CMDLINE_LEVELS)
        {
            // Dropped, not raised as an error: an error here propagates out of
            // handleRedraw and, not being classified as a hard render failure,
            // drives a detach/reattach cycle that ends in session termination
            // after two attempts. The sibling caps in this file (message bytes
            // and chunks) drop or truncate for the same reason.
            self.cmdline_dirty = true;
            return;
        }
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

        state.pos = @min(pos, cmdlineContentByteLen(state.content.items));
        state.firstc = firstc;

        // Dupe new prompt first, then free old one (avoid dangling on OOM)
        const new_prompt = if (prompt.len > 0) try self.alloc.dupe(u8, prompt) else "";
        if (state.prompt.len > 0) {
            self.alloc.free(state.prompt);
        }
        state.prompt = new_prompt;

        const indent_limit = if (self.screen_cols != 0)
            @min(self.screen_cols, MAX_GRID_COLS)
        else if (self.cols != 0)
            @min(self.cols, MAX_GRID_COLS)
        else
            MAX_GRID_COLS;
        state.indent = @min(indent, indent_limit);
        state.level = level;
        state.prompt_hl_id = prompt_hl_id;
        state.visible = true;
        // Per Neovim UI protocol (:help ui-cmdline), cmdline_special_char
        // "should be hidden at next cmdline_show". Clear on every show event.
        state.special_char_len = 0;

        self.cmdline_dirty = true;
    }

    /// Handle cmdline_hide event.
    pub fn setCmdlineHide(self: *Grid, level: u32) void {
        if (self.cmdline_states.getPtr(level)) |state| {
            state.visible = false;
            state.special_char_len = 0;
            state.special_shift = false;
            state.scroll_offset = 0;
            // Release the duped text too: the entry itself is kept so lookups
            // still see a hidden level, but a hidden cmdline held its content
            // and prompt until the next cmdline_show for the same level, which
            // for a level that never returns is never.
            for (state.content.items) |chunk| {
                if (chunk.text.len > 0) self.alloc.free(chunk.text);
            }
            state.content.clearRetainingCapacity();
            state.pos = 0;
            if (state.prompt.len > 0) {
                self.alloc.free(state.prompt);
                state.prompt = "";
            }
        }
        self.cmdline_dirty = true;
    }

    /// Handle cmdline_pos event.
    pub fn setCmdlinePos(self: *Grid, pos: u32, level: u32) void {
        if (self.cmdline_states.getPtr(level)) |state| {
            state.pos = @min(pos, cmdlineContentByteLen(state.content.items));
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
            var line_chunks: std.ArrayListUnmanaged(CmdlineChunk) = .empty;
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
        var line_chunks: std.ArrayListUnmanaged(CmdlineChunk) = .empty;
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
        var new_tabs: std.ArrayListUnmanaged(TabEntry) = .empty;
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
        var new_bufs: std.ArrayListUnmanaged(BufferEntry) = .empty;
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
        const is_accumulating =
            std.mem.eql(u8, kind, "shell_out") or
            std.mem.eql(u8, kind, "shell_err") or
            std.mem.eql(u8, kind, "list_cmd") or
            std.mem.eql(u8, kind, "return_prompt");
        const clear_existing = !append and !replace_last and !is_accumulating;

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
                try setMessageContentBounded(msg, self.alloc, content, false);
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
            try setMessageContentBounded(last_msg, self.alloc, content, true);
            self.message_state.visible = true;
            self.message_state.msg_dirty = true;
            return;
        }

        // Cap accumulating messages to prevent unbounded memory growth.
        // Only evict when actually creating a new message (not on append/replace_last
        // which reuse existing entries and don't increase count).
        const max_messages = 1000;
        const eviction_chunk = 256;
        const eviction_count = if (!clear_existing and self.message_state.messages.items.len >= max_messages) blk: {
            const required_drop = self.message_state.messages.items.len - (max_messages - 1);
            break :blk @min(
                @max(eviction_chunk, required_drop),
                self.message_state.messages.items.len,
            );
        } else 0;

        // Create new message
        var new_msg = Message{
            .id = msg_id,
            .kind = if (kind.len > 0) try self.alloc.dupe(u8, kind) else "",
            .history = history,
            .append = append,
            .replace_last = replace_last,
        };
        errdefer new_msg.deinit(self.alloc);

        try setMessageContentBounded(&new_msg, self.alloc, content, false);

        // Complete every fallible operation before changing the visible list.
        // This keeps both singleton replacement and accumulating eviction
        // transactional under allocator failure.
        const retained_count = if (clear_existing)
            0
        else
            self.message_state.messages.items.len - eviction_count;
        try self.message_state.messages.ensureTotalCapacity(self.alloc, retained_count + 1);
        if (clear_existing) {
            self.message_state.clearMessages(self.alloc);
        } else if (eviction_count != 0) {
            self.message_state.evictOldestMessages(self.alloc, eviction_count);
        }
        self.message_state.messages.appendAssumeCapacity(new_msg);
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

test "the global grid always has a dirty bit per row, a sub-grid may not" {
    var grid = Grid.init(std.testing.allocator);
    defer grid.deinit();

    // Grid.resize goes through ensureDirtyCapacity every time, so readers can
    // index dirty_rows by row with no length check. Callers in flush.zig rely
    // on this; if it ever stops holding they index past the bitset.
    try grid.resize(24, 80);
    try std.testing.expect(grid.dirty_rows.bit_length >= grid.rows);
    try grid.resize(50, 80); // grow
    try std.testing.expect(grid.dirty_rows.bit_length >= grid.rows);
    try grid.resize(10, 80); // shrink: the bitset is allowed to stay long
    try std.testing.expect(grid.dirty_rows.bit_length >= grid.rows);

    // The zero-cell shape needs its own grid. Reaching it after a larger
    // resize proves nothing: the bitset only ever grows, so a stale length
    // from an earlier shape would satisfy the assertion on its own.
    var zero_cols = Grid.init(std.testing.allocator);
    defer zero_cols.deinit();
    try zero_cols.resize(30, 0);
    try std.testing.expectEqual(@as(u32, 30), zero_cols.rows);
    try std.testing.expect(zero_cols.dirty_rows.bit_length >= zero_cols.rows);

    // GridBuf makes no such promise: a zero-cell shape skips the bitset while
    // rows keeps the requested value. This is why the sub-grid paths in
    // flush.zig test bit_length before isSet.
    try grid.resizeGrid(2, 8, 0);
    const sub = grid.sub_grids.getPtr(2).?;
    try std.testing.expectEqual(@as(u32, 8), sub.rows);
    try std.testing.expectEqual(@as(usize, 0), sub.dirty_rows.bit_length);
}

test "reopening a clean external grid regenerates every row" {
    var grid = Grid.init(std.testing.allocator);
    defer grid.deinit();

    try grid.resizeGrid(2, 4, 8);
    try std.testing.expect(try grid.setWinExternalPos(2, 42));

    const sub_grid = grid.sub_grids.getPtr(2).?;
    sub_grid.clearDirty();
    try std.testing.expect(!sub_grid.dirty);

    try grid.hideWin(2);
    try std.testing.expect(try grid.setWinExternalPos(2, 42));
    try std.testing.expect(sub_grid.dirty);
    var dirty_rows = sub_grid.dirty_rows.iterator(.{});
    var dirty_count: usize = 0;
    while (dirty_rows.next()) |_| dirty_count += 1;
    try std.testing.expectEqual(@as(usize, 4), dirty_count);
}

fn checkExternalRegistrationAllocationFailure(alloc: std.mem.Allocator) !void {
    var grid = Grid.init(alloc);
    defer grid.deinit();

    try grid.resizeGrid(1, 8, 16);
    try grid.resizeGrid(2, 3, 5);
    try grid.setWinPos(2, 42, 2, 4);
    // Exercise both map reservations in setWinExternalPos while preserving the
    // composited position whose transactional removal is under test.
    _ = grid.grid_win_ids.remove(2);
    const old_pos = grid.win_pos.get(2).?;
    const old_rev = grid.content_rev;

    _ = grid.setWinExternalPos(2, 42) catch |err| {
        try std.testing.expect(!grid.external_grids.contains(2));
        try std.testing.expect(!grid.grid_win_ids.contains(2));
        try std.testing.expectEqual(old_pos, grid.win_pos.get(2).?);
        try std.testing.expectEqual(old_rev, grid.content_rev);
        return err;
    };
}

test "external registration OOM preserves composited state" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, checkExternalRegistrationAllocationFailure, .{});
}

fn checkExternalPromotionAllocationFailure(alloc: std.mem.Allocator) !void {
    var grid = Grid.init(alloc);
    defer grid.deinit();

    try grid.resizeGrid(1, 8, 16);
    try grid.resizeGrid(2, 3, 5);
    try std.testing.expect(try grid.setWinExternalPos(2, 42));
    _ = grid.grid_win_ids.remove(2);
    const old_external = grid.external_grids.get(2).?;
    const old_rev = grid.glyph_working_set_rev;

    grid.promoteExternalToWinPos(2, 42, 1, 2) catch |err| {
        try std.testing.expectEqual(old_external, grid.external_grids.get(2).?);
        try std.testing.expect(!grid.win_pos.contains(2));
        try std.testing.expect(!grid.grid_win_ids.contains(2));
        try std.testing.expectEqual(old_rev, grid.glyph_working_set_rev);
        return err;
    };
}

test "external promotion OOM preserves external state" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, checkExternalPromotionAllocationFailure, .{});
}

test "message eviction compacts a chunk while preserving order" {
    var state: MessageState = .{};
    defer state.deinit(std.testing.allocator);

    for (0..10) |id| {
        try state.messages.append(std.testing.allocator, .{ .id = @intCast(id) });
    }
    state.evictOldestMessages(std.testing.allocator, 4);

    try std.testing.expectEqual(@as(usize, 6), state.messages.items.len);
    for (state.messages.items, 4..) |msg, expected_id| {
        try std.testing.expectEqual(@as(i64, @intCast(expected_id)), msg.id);
    }
}

test "message append keeps a bounded highlighted tail" {
    var grid = Grid.init(std.testing.allocator);
    defer grid.deinit();

    const initial = [_]MsgChunk{.{ .hl_id = 1, .text = "old-prefix" }};
    try grid.setMsgShow("echo", &initial, false, false, false, 1);

    const oversized_len = MAX_MESSAGE_BYTES + 16;
    const oversized = try std.testing.allocator.alloc(u8, oversized_len);
    defer std.testing.allocator.free(oversized);
    @memset(oversized, 'a');
    @memcpy(oversized[oversized.len - 8 ..], "TAILMARK");
    const oversized_append = [_]MsgChunk{.{ .hl_id = 7, .text = oversized }};
    try grid.setMsgShow("echo", &oversized_append, false, false, true, 1);

    const msg = &grid.message_state.messages.items[0];
    try std.testing.expectEqual(@as(usize, MAX_MESSAGE_BYTES), messageRetainedBytes(msg));
    try std.testing.expectEqual(@as(usize, 1), msg.content.items.len);
    try std.testing.expectEqual(@as(u32, 7), msg.content.items[0].hl_id);
    try std.testing.expectEqualSlices(u8, "TAILMARK", msg.content.items[0].text[msg.content.items[0].text.len - 8 ..]);
    try std.testing.expectEqualSlices(u8, oversized[16..], msg.content.items[0].text);

    // Chunk count is independently bounded. The newest highlighted chunks
    // survive in their original order when the byte limit is not involved.
    const reset = [_]MsgChunk{.{ .hl_id = 0, .text = "reset" }};
    try grid.setMsgShow("echo", &reset, false, false, false, 2);
    var many: [MAX_MESSAGE_CHUNKS + 44]MsgChunk = undefined;
    for (&many, 0..) |*chunk, index| {
        chunk.* = .{ .hl_id = @intCast(index), .text = "x" };
    }
    try grid.setMsgShow("echo", &many, false, false, true, 2);
    const bounded = &grid.message_state.messages.items[0];
    try std.testing.expectEqual(@as(usize, MAX_MESSAGE_CHUNKS), bounded.content.items.len);
    try std.testing.expectEqual(@as(u32, 44), bounded.content.items[0].hl_id);
    try std.testing.expectEqual(@as(u32, MAX_MESSAGE_CHUNKS + 43), bounded.content.items[bounded.content.items.len - 1].hl_id);
}

fn checkMessageAppendAllocationFailure(alloc: std.mem.Allocator) !void {
    var grid = Grid.init(alloc);
    defer grid.deinit();

    const initial = [_]MsgChunk{.{ .hl_id = 1, .text = "base" }};
    try grid.setMsgShow("echo", &initial, false, false, false, 1);
    const before = grid.message_state.messages.items[0].content.items[0];
    const appended = [_]MsgChunk{
        .{ .hl_id = 2, .text = "first" },
        .{ .hl_id = 3, .text = "second" },
    };

    grid.setMsgShow("echo", &appended, false, false, true, 1) catch |err| {
        const msg = &grid.message_state.messages.items[0];
        try std.testing.expectEqual(@as(usize, 1), msg.content.items.len);
        try std.testing.expectEqual(before.text.ptr, msg.content.items[0].text.ptr);
        try std.testing.expectEqualSlices(u8, "base", msg.content.items[0].text);
        return err;
    };

    const msg = &grid.message_state.messages.items[0];
    try std.testing.expectEqual(@as(usize, 3), msg.content.items.len);
    try std.testing.expectEqualSlices(u8, "base", msg.content.items[0].text);
    try std.testing.expectEqualSlices(u8, "first", msg.content.items[1].text);
    try std.testing.expectEqualSlices(u8, "second", msg.content.items[2].text);
}

test "message append OOM preserves the previous logical content" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        checkMessageAppendAllocationFailure,
        .{},
    );
}

fn checkMessageSingletonReplacementAllocationFailure(alloc: std.mem.Allocator) !void {
    var grid = Grid.init(alloc);
    defer grid.deinit();

    const initial = [_]MsgChunk{.{ .hl_id = 1, .text = "old-visible" }};
    try grid.setMsgShow("echo", &initial, false, false, false, 11);
    grid.message_state.msg_dirty = false;
    const before = grid.message_state.messages.items[0].content.items[0];
    const pending_count = grid.message_state.pending_count;
    const replacement = [_]MsgChunk{.{ .hl_id = 2, .text = "new-visible" }};

    grid.setMsgShow("echo", &replacement, false, false, false, 12) catch |err| {
        try std.testing.expectEqual(@as(usize, 1), grid.message_state.messages.items.len);
        const msg = &grid.message_state.messages.items[0];
        try std.testing.expectEqual(@as(i64, 11), msg.id);
        try std.testing.expectEqualSlices(u8, "echo", msg.kind);
        try std.testing.expectEqual(@as(usize, 1), msg.content.items.len);
        try std.testing.expectEqual(before.text.ptr, msg.content.items[0].text.ptr);
        try std.testing.expectEqualSlices(u8, "old-visible", msg.content.items[0].text);
        try std.testing.expect(grid.message_state.visible);
        try std.testing.expect(!grid.message_state.msg_dirty);
        try std.testing.expectEqual(pending_count, grid.message_state.pending_count);
        return err;
    };

    try std.testing.expectEqual(@as(usize, 1), grid.message_state.messages.items.len);
    try std.testing.expectEqual(@as(i64, 12), grid.message_state.messages.items[0].id);
    try std.testing.expectEqualSlices(u8, "new-visible", grid.message_state.messages.items[0].content.items[0].text);
}

test "message singleton replacement OOM preserves the previous visible message" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        checkMessageSingletonReplacementAllocationFailure,
        .{},
    );
}

fn checkMessageEvictionAllocationFailure(alloc: std.mem.Allocator) !void {
    var grid = Grid.init(alloc);
    defer grid.deinit();

    try grid.message_state.messages.ensureTotalCapacity(alloc, 1000);
    for (0..1000) |id| {
        grid.message_state.messages.appendAssumeCapacity(.{ .id = @intCast(id) });
    }
    grid.message_state.visible = true;
    const incoming = [_]MsgChunk{.{ .hl_id = 3, .text = "new-tail" }};

    grid.setMsgShow("shell_out", &incoming, false, false, false, 1000) catch |err| {
        try std.testing.expectEqual(@as(usize, 1000), grid.message_state.messages.items.len);
        try std.testing.expectEqual(@as(i64, 0), grid.message_state.messages.items[0].id);
        try std.testing.expectEqual(@as(i64, 999), grid.message_state.messages.items[999].id);
        try std.testing.expect(grid.message_state.visible);
        return err;
    };

    try std.testing.expectEqual(@as(usize, 745), grid.message_state.messages.items.len);
    try std.testing.expectEqual(@as(i64, 256), grid.message_state.messages.items[0].id);
    try std.testing.expectEqual(@as(i64, 1000), grid.message_state.messages.items[744].id);
}

test "message max-count eviction OOM preserves every previous message" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        checkMessageEvictionAllocationFailure,
        .{},
    );
}

test "subgrid clear dirties every covered main row" {
    var grid = Grid.init(std.testing.allocator);
    defer grid.deinit();

    try grid.resizeGrid(1, 6, 8);
    try grid.resizeGrid(2, 2, 3);
    try grid.setWinPos(2, 42, 2, 1);
    grid.clearDirty();
    grid.sub_grids.getPtr(2).?.clearDirty();
    const old_rev = grid.content_rev;

    grid.clearGrid(2);

    try std.testing.expect(grid.content_rev != old_rev);
    try std.testing.expect(!grid.dirty_rows.isSet(0));
    try std.testing.expect(!grid.dirty_rows.isSet(1));
    try std.testing.expect(grid.dirty_rows.isSet(2));
    try std.testing.expect(grid.dirty_rows.isSet(3));
    try std.testing.expect(!grid.dirty_rows.isSet(4));
    try std.testing.expect(!grid.dirty_rows.isSet(5));
}

test "grid line coverage is dirtied once per redraw epoch while order advances" {
    var grid = Grid.init(std.testing.allocator);
    defer grid.deinit();

    try grid.resizeGrid(1, 6, 8);
    try grid.resizeGrid(2, 2, 3);
    try grid.setWinFloatPos(2, 42, 2, 1, 10, 0, 1);
    grid.clearDirty();

    const epoch = grid.beginRedrawBatch();
    const order_before = grid.win_layer.get(2).?.order;
    const generation_before = grid.layout_generation;
    grid.noteGridLine(2, epoch);
    try std.testing.expect(grid.dirty_rows.isSet(2));
    try std.testing.expect(grid.dirty_rows.isSet(3));
    const first_order = grid.win_layer.get(2).?.order;
    try std.testing.expect(first_order != order_before);

    grid.clearDirty();
    grid.noteGridLine(2, epoch);
    try std.testing.expect(!grid.dirty_rows.isSet(2));
    try std.testing.expect(!grid.dirty_rows.isSet(3));
    try std.testing.expect(grid.win_layer.get(2).?.order != first_order);
    try std.testing.expect(grid.layout_generation != generation_before);

    grid.noteGridLine(2, grid.beginRedrawBatch());
    try std.testing.expect(grid.dirty_rows.isSet(2));
    try std.testing.expect(grid.dirty_rows.isSet(3));
}

test "main row index accounting follows placement and external anchor visibility" {
    var grid = Grid.init(std.testing.allocator);
    defer grid.deinit();
    grid.setRowIndexBudgetEnabled(true);

    try grid.resizeGrid(1, 4, 1);
    try grid.resizeGrid(2, 2, 1);
    try grid.resizeGrid(3, 1, 1);
    try grid.setWinPos(2, 42, 1, 0);
    try grid.setWinFloatPos(3, 43, 2, 0, 10, 0, 2);
    try std.testing.expectEqual(@as(usize, 3), grid.main_row_index_ref_count);
    try std.testing.expectEqual(@as(usize, 2), grid.main_row_index_layout_count);

    _ = try grid.setWinExternalPos(2, 42);
    try std.testing.expectEqual(@as(usize, 0), grid.main_row_index_ref_count);
    try std.testing.expectEqual(@as(usize, 0), grid.main_row_index_layout_count);

    try grid.promoteExternalToWinPos(2, 42, 1, 0);
    try std.testing.expectEqual(@as(usize, 3), grid.main_row_index_ref_count);
    try std.testing.expectEqual(@as(usize, 2), grid.main_row_index_layout_count);
}

test "row index budget rejects a placement without changing the accepted layout" {
    var grid = Grid.init(std.testing.allocator);
    defer grid.deinit();
    grid.setRowIndexBudgetEnabled(true);

    const main_rows = MAX_GRID_ROWS;
    try grid.resizeGrid(1, main_rows, 1);
    const base_bytes = Grid.mainRowIndexByteSize(main_rows, 0, 0).?;
    const one_layout_bytes = Grid.mainRowIndexByteSize(main_rows, main_rows, 1).? - base_bytes;
    const fitting_layouts = (MAX_MAIN_SUBGRID_ROW_INDEX_BYTES - base_bytes) / one_layout_bytes;
    try std.testing.expect(fitting_layouts > 0);

    for (0..fitting_layouts) |index| {
        const grid_id: i64 = @intCast(index + 2);
        try grid.resizeGrid(grid_id, main_rows, 1);
        try grid.setWinPos(grid_id, grid_id, 0, 0);
    }
    try std.testing.expectEqual(fitting_layouts, grid.main_row_index_layout_count);
    try std.testing.expectEqual(fitting_layouts * @as(usize, main_rows), grid.main_row_index_ref_count);

    const rejected_grid_id: i64 = @intCast(fitting_layouts + 2);
    try grid.resizeGrid(rejected_grid_id, main_rows, 1);
    const accepted_refs = grid.main_row_index_ref_count;
    const accepted_layouts = grid.main_row_index_layout_count;
    const accepted_generation = grid.layout_generation;
    try std.testing.expectError(
        error.LayoutTooComplex,
        grid.setWinPos(rejected_grid_id, rejected_grid_id, 0, 0),
    );
    try std.testing.expect(!grid.win_pos.contains(rejected_grid_id));
    try std.testing.expect(!grid.grid_win_ids.contains(rejected_grid_id));
    try std.testing.expectEqual(accepted_refs, grid.main_row_index_ref_count);
    try std.testing.expectEqual(accepted_layouts, grid.main_row_index_layout_count);
    try std.testing.expectEqual(accepted_generation, grid.layout_generation);
}

test "viewport margin changes invalidate their vertex consumers" {
    var grid = Grid.init(std.testing.allocator);
    defer grid.deinit();

    try grid.resizeGrid(1, 6, 8);
    grid.clearDirty();
    const main_rev = grid.content_rev;
    try grid.setViewportMargins(1, 1, 1, 1, 1);
    try std.testing.expect(grid.content_rev != main_rev);
    try std.testing.expect(grid.dirty_all);

    grid.clearDirty();
    const unchanged_rev = grid.content_rev;
    try grid.setViewportMargins(1, 1, 1, 1, 1);
    try std.testing.expectEqual(unchanged_rev, grid.content_rev);
    try std.testing.expect(!grid.dirty_all);

    try grid.resizeGrid(2, 2, 3);
    try grid.setWinPos(2, 42, 2, 1);
    grid.clearDirty();
    grid.sub_grids.getPtr(2).?.clearDirty();
    try grid.setViewportMargins(2, 0, 0, 1, 1);
    try std.testing.expect(grid.dirty_rows.isSet(2));
    try std.testing.expect(grid.dirty_rows.isSet(3));
    try std.testing.expect(grid.sub_grids.get(2).?.dirty);
}

test "grid resize rejects oversized and aggregate dimensions transactionally" {
    var grid = Grid.init(std.testing.allocator);
    defer grid.deinit();

    try grid.resizeGrid(1, 2, 3);
    const old_cells = grid.cells.ptr;
    const old_total = grid.total_grid_cells;
    try std.testing.expectError(error.GridTooLarge, grid.resizeGrid(1, MAX_GRID_ROWS + 1, 1));
    try std.testing.expectEqual(@as(u32, 2), grid.rows);
    try std.testing.expectEqual(@as(u32, 3), grid.cols);
    try std.testing.expectEqual(old_cells, grid.cells.ptr);
    try std.testing.expectEqual(old_total, grid.total_grid_cells);
    try std.testing.expectError(error.GridTooLarge, grid.checkedAggregateCellCount(0, MAX_TOTAL_GRID_CELLS + 1));
}

test "window placements are bounded independently of grid cells" {
    try std.testing.expect(windowPlacementInsertFits(MAX_WINDOW_PLACEMENTS - 1, true));
    try std.testing.expect(!windowPlacementInsertFits(MAX_WINDOW_PLACEMENTS, true));
    try std.testing.expect(windowPlacementInsertFits(MAX_WINDOW_PLACEMENTS, false));

    var grid = Grid.init(std.testing.allocator);
    defer grid.deinit();
    try grid.resizeGrid(1, 1, 1);
    // A placement with no corresponding sub-grid still consumes the bounded
    // placement maps; it must not be coupled to aggregate cell accounting.
    try grid.setWinFloatPos(2, 0, 0, 0, 10, 0, 1);
    try std.testing.expectEqual(@as(usize, 1), grid.win_pos.count());
    try std.testing.expectEqual(@as(usize, 1), grid.win_layer.count());
    try std.testing.expectEqual(@as(usize, 1), grid.total_grid_cells);
}

test "subgrid count is bounded independently of cells and placements" {
    try std.testing.expect(subgridInsertFits(MAX_SUBGRIDS - 1, true));
    try std.testing.expect(!subgridInsertFits(MAX_SUBGRIDS, true));
    try std.testing.expect(subgridInsertFits(MAX_SUBGRIDS, false));
    try std.testing.expect(MAX_SUBGRIDS * SUBGRID_HASH_ENTRY_WORST_CASE_BYTES <= MAX_SUBGRID_METADATA_BYTES);
}

fn checkResizeAllocationFailure(alloc: std.mem.Allocator) !void {
    var grid = Grid.init(alloc);
    defer grid.deinit();
    try grid.resizeGrid(1, 2, 3);
    const old_cells = grid.cells.ptr;
    const old_total = grid.total_grid_cells;

    grid.resizeGrid(1, 100, 100) catch |err| {
        try std.testing.expectEqual(@as(u32, 2), grid.rows);
        try std.testing.expectEqual(@as(u32, 3), grid.cols);
        try std.testing.expectEqual(old_cells, grid.cells.ptr);
        try std.testing.expectEqual(old_total, grid.total_grid_cells);
        return err;
    };
}

test "grid resize OOM preserves old shape and cells" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, checkResizeAllocationFailure, .{});
}

fn checkSubgridResizeAllocationFailure(alloc: std.mem.Allocator) !void {
    var grid_buf: GridBuf = .{};
    defer grid_buf.deinit(alloc);
    try grid_buf.resize(alloc, 2, 3);
    const old_cells = grid_buf.cells.ptr;
    const old_dirty_words = grid_buf.dirty_rows.masks;
    const old_counts = grid_buf.vertex_row_counts.ptr;

    grid_buf.resize(alloc, 100, 100) catch |err| {
        try std.testing.expectEqual(@as(u32, 2), grid_buf.rows);
        try std.testing.expectEqual(@as(u32, 3), grid_buf.cols);
        try std.testing.expectEqual(old_cells, grid_buf.cells.ptr);
        try std.testing.expectEqual(old_dirty_words, grid_buf.dirty_rows.masks);
        try std.testing.expectEqual(old_counts, grid_buf.vertex_row_counts.ptr);
        return err;
    };
}

test "subgrid resize OOM preserves cells and row metadata" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, checkSubgridResizeAllocationFailure, .{});
}

test "grid position setters reject frontend-unrepresentable coordinates" {
    var grid = Grid.init(std.testing.allocator);
    defer grid.deinit();

    try grid.resizeGrid(1, 4, 4);
    try grid.resizeGrid(2, 2, 2);
    try grid.setWinPos(2, 42, std.math.maxInt(u32), 0);
    try std.testing.expect(!grid.win_pos.contains(2));
    try std.testing.expect(!grid.grid_win_ids.contains(2));

    try grid.setWinPos(2, 42, 1, 1);
    const old_pos = grid.win_pos.get(2).?;
    try grid.setWinFloatPos(2, 42, std.math.maxInt(u32), 1, 10, 0, 1);
    try std.testing.expectEqual(old_pos, grid.win_pos.get(2).?);
    try std.testing.expect(!grid.win_layer.contains(2));
}

test "grid cursor rejects coordinates outside its target dimensions" {
    var grid = Grid.init(std.testing.allocator);
    defer grid.deinit();

    try grid.resizeGrid(1, 4, 4);
    try grid.resizeGrid(2, 2, 3);
    grid.setCursor(2, 1, 2);
    const old_rev = grid.cursor_rev;

    grid.setCursor(2, std.math.maxInt(u32), 0);
    grid.setCursor(2, 0, std.math.maxInt(u32));
    try std.testing.expectEqual(@as(i64, 2), grid.cursor_grid);
    try std.testing.expectEqual(@as(u32, 1), grid.cursor_row);
    try std.testing.expectEqual(@as(u32, 2), grid.cursor_col);
    try std.testing.expectEqual(old_rev, grid.cursor_rev);
}

test "cmdline and viewport state normalize hostile dimensions" {
    var grid = Grid.init(std.testing.allocator);
    defer grid.deinit();

    try grid.resizeGrid(1, 4, 5);
    const content = [_]CmdlineChunk{.{ .hl_id = 0, .text = "abc" }};
    try grid.setCmdlineShow(&content, std.math.maxInt(u32), 0, "", std.math.maxInt(u32), 1, 0);
    const state = grid.getCmdlineState(1).?;
    try std.testing.expectEqual(@as(u32, 3), state.pos);
    try std.testing.expectEqual(@as(u32, 5), state.indent);
    grid.setCmdlinePos(std.math.maxInt(u32), 1);
    try std.testing.expectEqual(@as(u32, 3), grid.getCmdlineState(1).?.pos);

    try grid.setViewportMargins(1, std.math.maxInt(u32), std.math.maxInt(u32), std.math.maxInt(u32), std.math.maxInt(u32));
    try std.testing.expectEqual(ViewportMargins{ .top = 4, .bottom = 4, .left = 5, .right = 5 }, grid.getViewportMargins(1));
}

fn checkClusterAllocationFailure(alloc: std.mem.Allocator) !void {
    var grid = Grid.init(alloc);
    defer grid.deinit();

    try grid.resizeGrid(1, 1, 1);
    grid.putCellGrid(1, 0, 0, 'A', 7);

    grid.putCellGridCluster(1, 0, 0, 0x26A0, 9, &.{0xFE0F}) catch |err| {
        // The base cell and overflow tail form one semantic glyph. Neither
        // side may publish if hash-map growth fails.
        try std.testing.expectEqual(Cell{ .cp = 'A', .hl = 7 }, grid.getCellGrid(1, 0, 0));
        try std.testing.expect(grid.getOverflow(1, 0, 0) == null);
        return err;
    };

    try std.testing.expectEqual(Cell{ .cp = 0x26A0, .hl = 9 }, grid.getCellGrid(1, 0, 0));
    try std.testing.expectEqualSlices(u32, &.{0xFE0F}, grid.getOverflow(1, 0, 0).?);
}

test "cluster OOM preserves base cell and overflow atomically" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, checkClusterAllocationFailure, .{});
}

fn checkOverflowLifecycleAllocationFailure(alloc: std.mem.Allocator) !void {
    var grid = Grid.init(alloc);
    defer grid.deinit();

    try grid.resizeGrid(1, 3, 1);
    try grid.putCellGridCluster(1, 1, 0, 0x26A0, 7, &.{0xFE0F});
    try grid.putCellGridCluster(1, 2, 0, 'a', 8, &.{0x0301});

    // Once an overflow entry is published, scroll must be allocation-free:
    // allocator failure may not move the base cells while leaving tails at
    // their old keys.
    grid.scrollGrid(1, 0, 3, 0, 1, 1, 0);
    try std.testing.expectEqual(Cell{ .cp = 0x26A0, .hl = 7 }, grid.getCellGrid(1, 0, 0));
    try std.testing.expectEqualSlices(u32, &.{0xFE0F}, grid.getOverflow(1, 0, 0).?);
    try std.testing.expectEqual(Cell{ .cp = 'a', .hl = 8 }, grid.getCellGrid(1, 1, 0));
    try std.testing.expectEqualSlices(u32, &.{0x0301}, grid.getOverflow(1, 1, 0).?);
    try std.testing.expect(grid.getOverflow(1, 2, 0) == null);

    grid.clearGrid(1);
    try std.testing.expectEqual(@as(usize, 0), grid.cell_overflow.count());

    // Resize trimming and destroy also use the same allocation-free removal
    // invariant; a later reuse of the grid ID must not resurrect a stale tail.
    try grid.resizeGrid(2, 2, 1);
    try grid.putCellGridCluster(2, 1, 0, 'b', 9, &.{0x0302});
    try grid.resizeGrid(2, 1, 1);
    try std.testing.expect(grid.getOverflow(2, 1, 0) == null);
    try grid.resizeGrid(2, 2, 1);
    try std.testing.expect(grid.getOverflow(2, 1, 0) == null);

    try grid.putCellGridCluster(2, 0, 0, 0x2764, 10, &.{0xFE0F});
    try grid.destroyGrid(2);
    try std.testing.expect(grid.getOverflow(2, 0, 0) == null);
    try grid.resizeGrid(2, 1, 1);
    try std.testing.expect(grid.getOverflow(2, 0, 0) == null);
}

test "overflow scroll and lifecycle remain atomic under allocator failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        checkOverflowLifecycleAllocationFailure,
        .{},
    );
}

test "overflow index isolates unrelated grids during scroll and lookup" {
    var grid = Grid.init(std.testing.allocator);
    defer grid.deinit();

    try grid.resizeGrid(1, 3, 1);
    try grid.resizeGrid(2, 3, 1);
    try grid.putCellGridCluster(1, 1, 0, 'a', 0, &.{0x0301});
    try grid.putCellGridCluster(2, 1, 0, 'b', 0, &.{0x0302});
    try std.testing.expectEqual(@as(usize, 1), grid.overflowCountForGrid(1));
    try std.testing.expectEqual(@as(usize, 1), grid.overflowCountForGrid(2));
    try std.testing.expectEqual(@as(usize, 0), grid.overflowCountForGrid(3));

    grid.scrollOverflow(1, 0, 3, 0, 1, 1);
    try std.testing.expectEqualSlices(u32, &.{0x0301}, grid.getOverflow(1, 0, 0).?);
    try std.testing.expectEqualSlices(u32, &.{0x0302}, grid.getOverflow(2, 1, 0).?);
    try std.testing.expect(grid.getOverflow(2, 0, 0) == null);

    grid.clearOverflowForGrid(1);
    try std.testing.expectEqual(@as(usize, 0), grid.overflowCountForGrid(1));
    try std.testing.expect(!grid.overflow_by_grid.contains(1));
    try std.testing.expectEqual(@as(usize, 1), grid.overflowCountForGrid(2));

    try grid.destroyGrid(2);
    try std.testing.expect(!grid.overflow_by_grid.contains(2));
}

test "subgrid scroll keeps submitted vertex counts aligned with row slots" {
    var grid_buf: GridBuf = .{};
    defer grid_buf.deinit(std.testing.allocator);
    try grid_buf.resize(std.testing.allocator, 4, 1);
    @memcpy(grid_buf.vertex_row_counts, &[_]usize{ 10, 20, 30, 40 });
    grid_buf.surface_vertex_count = 100;

    grid_buf.scroll(0, 4, 0, 1, 1, 0);
    try std.testing.expectEqualSlices(usize, &.{ 20, 30, 40, 0 }, grid_buf.vertex_row_counts);
    try std.testing.expectEqual(@as(usize, 90), grid_buf.surface_vertex_count);

    grid_buf.scroll(0, 4, 0, 1, -1, 0);
    try std.testing.expectEqualSlices(usize, &.{ 0, 20, 30, 40 }, grid_buf.vertex_row_counts);
    try std.testing.expectEqual(@as(usize, 90), grid_buf.surface_vertex_count);
}

test "viewport metadata ignores unknown grids, except margins" {
    var grid = Grid.init(std.testing.allocator);
    defer grid.deinit();

    try grid.resizeGrid(1, 2, 2);
    try grid.setViewport(99, 7, 1, 2, 3, 4, 5, 6);
    try grid.setViewportMargins(99, 1, 1, 1, 1);
    try std.testing.expectEqual(@as(usize, 0), grid.viewport.count());
    // Margins are the exception: Neovim announces a window's margins before the
    // grid_resize that creates it, and never resends them, so they are kept
    // against the grid's arrival. They read as nothing until it does.
    try std.testing.expectEqual(@as(usize, 1), grid.viewport_margins.count());
    try std.testing.expectEqual(@as(u32, 0), grid.getViewportMargins(99).top);

    try grid.resizeGrid(99, 1, 1);
    // Now that the grid exists, what was announced earlier takes effect.
    try std.testing.expectEqual(@as(u32, 1), grid.getViewportMargins(99).top);
    try grid.setViewport(99, 7, 1, 2, 3, 4, 5, 6);
    try grid.setViewportMargins(99, 1, 1, 1, 1);
    try std.testing.expectEqual(@as(usize, 1), grid.viewport.count());
    try std.testing.expectEqual(@as(usize, 1), grid.viewport_margins.count());
}

test "zero-column subgrid defers submitted vertex row ledger" {
    var grid_buf: GridBuf = .{};
    defer grid_buf.deinit(std.testing.allocator);

    try grid_buf.resize(std.testing.allocator, MAX_GRID_ROWS, 0);
    try std.testing.expectEqual(@as(usize, 0), grid_buf.vertex_row_counts.len);
    try std.testing.expectEqual(@as(usize, 0), grid_buf.dirty_rows.bit_length);

    try grid_buf.resize(std.testing.allocator, 0, MAX_GRID_COLS);
    try std.testing.expectEqual(@as(usize, 0), grid_buf.vertex_row_counts.len);
    try std.testing.expectEqual(@as(usize, 0), grid_buf.dirty_rows.bit_length);

    try grid_buf.resize(std.testing.allocator, 4, 1);
    try std.testing.expectEqual(@as(usize, 4), grid_buf.vertex_row_counts.len);
    try std.testing.expectEqual(@as(usize, 4), grid_buf.dirty_rows.bit_length);
    try std.testing.expectEqualSlices(usize, &.{ 0, 0, 0, 0 }, grid_buf.vertex_row_counts);
}

test "cluster storage rejects more than fifteen trailing scalars atomically" {
    var grid = Grid.init(std.testing.allocator);
    defer grid.deinit();
    try grid.resizeGrid(1, 1, 1);
    grid.putCellGrid(1, 0, 0, 'A', 7);

    const extras = [_]u32{0x0300} ** 16;
    try std.testing.expectError(error.CellClusterTooLong, OverflowExtras.fromSlice(&extras));
    try std.testing.expectError(
        error.CellClusterTooLong,
        grid.putCellGridCluster(1, 0, 0, 'B', 9, &extras),
    );
    try std.testing.expectEqual(Cell{ .cp = 'A', .hl = 7 }, grid.getCellGrid(1, 0, 0));
    try std.testing.expect(grid.getOverflow(1, 0, 0) == null);

    try std.testing.expect(cellOverflowInsertFits(MAX_CELL_OVERFLOW_ENTRIES - 1, true));
    try std.testing.expect(!cellOverflowInsertFits(MAX_CELL_OVERFLOW_ENTRIES, true));
    // Replacing an existing key does not grow the bounded map.
    try std.testing.expect(cellOverflowInsertFits(MAX_CELL_OVERFLOW_ENTRIES, false));
}

test "synthetic external visibility advances glyph working set revision" {
    var grid = Grid.init(std.testing.allocator);
    defer grid.deinit();

    const initial = grid.glyph_working_set_rev;
    try grid.putSyntheticExternal(POPUPMENU_GRID_ID, .{ .win = 1, .start_row = 2, .start_col = 3 });
    try std.testing.expectEqual(initial +% 1, grid.glyph_working_set_rev);

    // Position-only updates do not change which glyphs are visible.
    try grid.putSyntheticExternal(POPUPMENU_GRID_ID, .{ .win = 1, .start_row = 4, .start_col = 5 });
    try std.testing.expectEqual(initial +% 1, grid.glyph_working_set_rev);

    try std.testing.expect(try grid.removeSyntheticExternal(POPUPMENU_GRID_ID));
    try std.testing.expectEqual(initial +% 2, grid.glyph_working_set_rev);
    try std.testing.expect(!try grid.removeSyntheticExternal(POPUPMENU_GRID_ID));
    try std.testing.expectEqual(initial +% 2, grid.glyph_working_set_rev);
}

test "scroll notification overflow retains main provenance across pending overwrite" {
    var grid = Grid.init(std.testing.allocator);
    defer grid.deinit();

    try grid.resizeGrid(1, 3, 3);
    var grid_id: i64 = 2;
    while (grid_id <= 18) : (grid_id += 1) {
        try grid.resizeGrid(grid_id, 3, 3);
        try grid.setWinPos(grid_id, grid_id, 0, 0);
    }

    // Fill the fixed prefix with sixteen subgrids, then place main beyond it.
    grid_id = 2;
    while (grid_id <= 17) : (grid_id += 1) {
        grid.scrollGrid(grid_id, 0, 3, 0, 3, 1, 0);
    }
    try std.testing.expectEqual(@as(u8, 16), grid.scrolled_grid_count);
    try std.testing.expect(!grid.scrolled_grid_overflow);

    grid.scrollGrid(1, 0, 3, 0, 3, 1, 0);
    grid.scrollGrid(18, 0, 3, 0, 3, 1, 0);
    try std.testing.expect(grid.scrolled_grid_overflow);
    try std.testing.expect(grid.main_scroll_notify_pending);
    try std.testing.expect(grid.sub_grids.get(18).?.scroll_notify_pending);
    try std.testing.expectEqual(@as(i64, 18), grid.pending_scroll.?.grid_id);

    // A pre-dispatch retry discards row-shift state but must retain offset
    // notification provenance independently.
    grid.clearScrollState();
    var sg_it = grid.sub_grids.valueIterator();
    while (sg_it.next()) |sg| sg.clearScrollState();
    try std.testing.expect(grid.main_scroll_notify_pending);
    try std.testing.expect(grid.sub_grids.get(18).?.scroll_notify_pending);

    grid.clearScrolledGrids();
    try std.testing.expect(!grid.main_scroll_notify_pending);
    try std.testing.expect(!grid.sub_grids.get(18).?.scroll_notify_pending);
}
