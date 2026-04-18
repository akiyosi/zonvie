// redraw_parity_test.zig — parity between the two redraw decode paths.
//
// Feeds identical synthesised MessagePack redraw-notification byte
// streams through both:
//
//   old path: mp.decode(arena) → extract params[]Value → handleRedraw
//   new path: InnerDecoder → handleRedrawStream (grid_line streams,
//             others materialise one event at a time via decodeFromStream
//             and call handleRedraw)
//
// and asserts that observable side effects match bit-for-bit:
//
//   * every cell's (cp, hl_id) and overflow-tail content
//   * dirty_rows / dirty_all
//   * cursor row/col/rev/visible
//   * highlight map (per-id attrs) and the default_fg/bg/sp triple
//   * flush callback invocation count and (rows, cols) arguments
//
// These are the smallest assertions that catch the realistic regression
// modes of the streaming path: wrong cell writes, missed dirty marks,
// stale hl_state stickiness, dropped or duplicated flush callbacks,
// hl_attr_define not reaching the hl map, mode_change not updating
// cursor state.

const std = @import("std");
const zc = @import("zonvie_core");

const mp = zc.msgpack;
const mps = zc.mpack_stream;
const redraw = zc.redraw_handler;
const Grid = zc.grid_mod.Grid;
const Highlights = zc.highlight.Highlights;
const Logger = zc.log_mod.Logger;

const testing = std.testing;

// ---------------------------------------------------------------------------
// Stub callbacks. handleRedraw takes function pointers for flush, guifont,
// linespace, set_title, default_colors. We count calls and snapshot args.
// ---------------------------------------------------------------------------

const Stub = struct {
    flush_calls: u32 = 0,
    last_flush_rows: u32 = 0,
    last_flush_cols: u32 = 0,

    guifont_calls: u32 = 0,
    linespace_calls: u32 = 0,
    last_linespace_px: i32 = 0,
    set_title_calls: u32 = 0,
    default_colors_calls: u32 = 0,

    fn onFlush(ctx: *Stub, rows: u32, cols: u32) anyerror!void {
        ctx.flush_calls += 1;
        ctx.last_flush_rows = rows;
        ctx.last_flush_cols = cols;
    }
    fn onGuifont(ctx: *Stub, _: []const u8) anyerror!void {
        ctx.guifont_calls += 1;
    }
    fn onLinespace(ctx: *Stub, px: i32) anyerror!void {
        ctx.linespace_calls += 1;
        ctx.last_linespace_px = px;
    }
    fn onSetTitle(ctx: *Stub, _: []const u8) anyerror!void {
        ctx.set_title_calls += 1;
    }
    fn onDefaultColors(ctx: *Stub, _: u32, _: u32) anyerror!void {
        ctx.default_colors_calls += 1;
    }
};

// ---------------------------------------------------------------------------
// Test harness per path.
// ---------------------------------------------------------------------------

const World = struct {
    grid: Grid,
    hl: Highlights,
    stub: Stub,
    arena: std.heap.ArenaAllocator,
    log: Logger = .{},

    fn init(alloc: std.mem.Allocator, rows: u32, cols: u32) !World {
        var g = Grid.init(alloc);
        try g.resize(rows, cols);
        return .{
            .grid = g,
            .hl = Highlights.init(alloc),
            .stub = .{},
            .arena = std.heap.ArenaAllocator.init(alloc),
        };
    }

    fn deinit(self: *World) void {
        self.grid.deinit();
        self.hl.deinit();
        self.arena.deinit();
    }
};

const SliceReader = struct {
    data: []const u8,
    i: usize = 0,

    pub fn readByte(self: *SliceReader) anyerror!u8 {
        if (self.i >= self.data.len) return error.EndOfStream;
        const b = self.data[self.i];
        self.i += 1;
        return b;
    }

    pub fn readNoEof(self: *SliceReader, buf: []u8) anyerror!void {
        if (self.i + buf.len > self.data.len) return error.EndOfStream;
        @memcpy(buf, self.data[self.i .. self.i + buf.len]);
        self.i += buf.len;
    }
};

/// Feed `frame_bytes` (a full `[2, "redraw", [events...]]` frame) through
/// the Value-tree path, exactly as `rpc_session` does today.
fn runValueTreePath(frame_bytes: []const u8, w: *World) !void {
    var sr = SliceReader{ .data = frame_bytes };
    const root = try mp.decode(w.arena.allocator(), &sr);
    try testing.expect(root == .arr);
    const top = root.arr;
    try testing.expect(top.len >= 3);
    try testing.expect(top[2] == .arr);
    const params = top[2].arr;

    try redraw.handleRedraw(
        &w.grid,
        &w.hl,
        w.arena.allocator(),
        params,
        &w.log,
        &w.stub,
        Stub.onFlush,
        &w.stub,
        Stub.onGuifont,
        &w.stub,
        Stub.onLinespace,
        Stub.onSetTitle,
        Stub.onDefaultColors,
    );
}

/// Feed the same `frame_bytes` through the streaming path.
fn runStreamingPath(frame_bytes: []const u8, w: *World) !void {
    var in = mps.InnerDecoder{ .data = frame_bytes };
    const top_n = try in.expectArray();
    try testing.expectEqual(@as(u32, 3), top_n);
    _ = try in.expectUInt(); // msg_type = 2
    _ = try in.expectString(); // "redraw"
    const n_events = try in.expectArray();

    try redraw.handleRedrawStream(
        &w.grid,
        &w.hl,
        w.arena.allocator(),
        &in,
        n_events,
        &w.log,
        &w.stub,
        Stub.onFlush,
        &w.stub,
        Stub.onGuifont,
        &w.stub,
        Stub.onLinespace,
        Stub.onSetTitle,
        Stub.onDefaultColors,
    );
}

// ---------------------------------------------------------------------------
// Assertions.
// ---------------------------------------------------------------------------

fn expectBitSetParity(a: *const std.DynamicBitSetUnmanaged, b: *const std.DynamicBitSetUnmanaged) !void {
    try testing.expectEqual(a.bit_length, b.bit_length);
    var i: usize = 0;
    while (i < a.bit_length) : (i += 1) {
        testing.expectEqual(a.isSet(i), b.isSet(i)) catch |e| {
            std.debug.print("dirty_rows bit {d} diverged a={} b={}\n", .{ i, a.isSet(i), b.isSet(i) });
            return e;
        };
    }
}

fn expectGridParity(a: *const Grid, b: *const Grid) !void {
    try testing.expectEqual(a.rows, b.rows);
    try testing.expectEqual(a.cols, b.cols);
    try testing.expectEqual(a.cells.len, b.cells.len);

    for (a.cells, b.cells, 0..) |ca, cb, i| {
        testing.expectEqual(ca.cp, cb.cp) catch |e| {
            std.debug.print("cell {d}: cp diverged a={d} b={d}\n", .{ i, ca.cp, cb.cp });
            return e;
        };
        testing.expectEqual(ca.hl, cb.hl) catch |e| {
            std.debug.print("cell {d}: hl diverged a={d} b={d}\n", .{ i, ca.hl, cb.hl });
            return e;
        };
    }

    try testing.expectEqual(a.dirty_all, b.dirty_all);
    try expectBitSetParity(&a.dirty_rows, &b.dirty_rows);

    try testing.expectEqual(a.content_rev, b.content_rev);
    try testing.expectEqual(a.cursor_row, b.cursor_row);
    try testing.expectEqual(a.cursor_col, b.cursor_col);
    try testing.expectEqual(a.cursor_grid, b.cursor_grid);
    try testing.expectEqual(a.cursor_visible, b.cursor_visible);
    try testing.expectEqual(a.cursor_rev, b.cursor_rev);

    // Overflow map: value is a value-typed OverflowExtras (inline [15]u32 buf +
    // len). Compare via its `slice()` helper; the trailing garbage bytes of
    // `buf` must not contribute to equality.
    try testing.expectEqual(a.cell_overflow.count(), b.cell_overflow.count());
    var it = a.cell_overflow.iterator();
    while (it.next()) |ea| {
        const vb_ptr = b.cell_overflow.getPtr(ea.key_ptr.*) orelse {
            std.debug.print("overflow key (grid={d} row={d} col={d}) missing in b\n", .{
                ea.key_ptr.grid_id, ea.key_ptr.row, ea.key_ptr.col,
            });
            return error.OverflowMapDiverged;
        };
        try testing.expectEqualSlices(u32, ea.value_ptr.slice(), vb_ptr.slice());
    }
}

fn expectHlParity(a: *const Highlights, b: *const Highlights) !void {
    try testing.expectEqual(a.default_fg, b.default_fg);
    try testing.expectEqual(a.default_bg, b.default_bg);
    try testing.expectEqual(a.default_sp, b.default_sp);
    try testing.expectEqual(a.default_colors_changed, b.default_colors_changed);
    try testing.expectEqual(a.groups_changed, b.groups_changed);

    try testing.expectEqual(a.map.count(), b.map.count());
    var it = a.map.iterator();
    while (it.next()) |ea| {
        const vb = b.map.get(ea.key_ptr.*) orelse {
            std.debug.print("hl id {d} missing in b\n", .{ea.key_ptr.*});
            return error.HlMapDiverged;
        };
        // Attr is a plain struct; std.testing.expectEqual compares field-by-field.
        try testing.expectEqual(ea.value_ptr.*, vb);
    }
}

fn expectStubParity(a: *const Stub, b: *const Stub) !void {
    try testing.expectEqual(a.flush_calls, b.flush_calls);
    try testing.expectEqual(a.last_flush_rows, b.last_flush_rows);
    try testing.expectEqual(a.last_flush_cols, b.last_flush_cols);
    try testing.expectEqual(a.guifont_calls, b.guifont_calls);
    try testing.expectEqual(a.linespace_calls, b.linespace_calls);
    try testing.expectEqual(a.last_linespace_px, b.last_linespace_px);
    try testing.expectEqual(a.set_title_calls, b.set_title_calls);
    try testing.expectEqual(a.default_colors_calls, b.default_colors_calls);
}

// ---------------------------------------------------------------------------
// MessagePack frame builders. All build a full `[2, "redraw", [events]]`
// top frame so both paths see identical bytes.
// ---------------------------------------------------------------------------

const BufList = std.ArrayListUnmanaged(u8);

fn wArrHead(b: *BufList, alloc: std.mem.Allocator, n: u32) !void {
    if (n <= 15) {
        try b.append(alloc, 0x90 | @as(u8, @intCast(n)));
    } else if (n <= 0xFFFF) {
        try b.append(alloc, 0xdc);
        try b.append(alloc, @intCast((n >> 8) & 0xFF));
        try b.append(alloc, @intCast(n & 0xFF));
    } else {
        try b.append(alloc, 0xdd);
        try b.append(alloc, @intCast((n >> 24) & 0xFF));
        try b.append(alloc, @intCast((n >> 16) & 0xFF));
        try b.append(alloc, @intCast((n >> 8) & 0xFF));
        try b.append(alloc, @intCast(n & 0xFF));
    }
}

fn wMapHead(b: *BufList, alloc: std.mem.Allocator, n: u32) !void {
    if (n <= 15) {
        try b.append(alloc, 0x80 | @as(u8, @intCast(n)));
    } else {
        try b.append(alloc, 0xde);
        try b.append(alloc, @intCast((n >> 8) & 0xFF));
        try b.append(alloc, @intCast(n & 0xFF));
    }
}

fn wStr(b: *BufList, alloc: std.mem.Allocator, s: []const u8) !void {
    if (s.len <= 31) {
        try b.append(alloc, 0xa0 | @as(u8, @intCast(s.len)));
    } else {
        try b.append(alloc, 0xd9);
        try b.append(alloc, @intCast(s.len));
    }
    try b.appendSlice(alloc, s);
}

fn wPositiveFixint(b: *BufList, alloc: std.mem.Allocator, v: u8) !void {
    std.debug.assert(v <= 0x7f);
    try b.append(alloc, v);
}

fn wNegFixint(b: *BufList, alloc: std.mem.Allocator, v: i8) !void {
    // -32..-1 range uses 0xe0..0xff
    std.debug.assert(v < 0 and v >= -32);
    const u: u8 = @bitCast(v);
    try b.append(alloc, u);
}

fn wUInt8(b: *BufList, alloc: std.mem.Allocator, v: u8) !void {
    if (v <= 0x7f) {
        try b.append(alloc, v);
    } else {
        try b.append(alloc, 0xcc);
        try b.append(alloc, v);
    }
}

/// Open a redraw notification: writes `[2, "redraw", [` and records the
/// count position so it can be backfilled after all events are appended.
fn startRedrawFrame(b: *BufList, alloc: std.mem.Allocator, n_events: u32) !void {
    try wArrHead(b, alloc, 3);
    try b.append(alloc, 0x02); // msg_type = 2
    try wStr(b, alloc, "redraw");
    try wArrHead(b, alloc, n_events);
}

/// Emit a single-tuple grid_line event. The tuple carries grid, row, col,
/// cells, wrap (hardcoded to false for simplicity).
fn emitGridLineEvent(
    b: *BufList,
    alloc: std.mem.Allocator,
    comptime Cell: type,
    grid_id: u8,
    row: u8,
    col: u8,
    cells: []const Cell,
) !void {
    try wArrHead(b, alloc, 2); // event = [name, tuple1]
    try wStr(b, alloc, "grid_line");

    try wArrHead(b, alloc, 5); // tuple = [grid, row, col, cells, wrap]
    try wPositiveFixint(b, alloc, grid_id);
    try wPositiveFixint(b, alloc, row);
    try wPositiveFixint(b, alloc, col);

    try wArrHead(b, alloc, @intCast(cells.len));
    for (cells) |c| {
        try c.emit(b, alloc);
    }

    try b.append(alloc, 0xc2); // wrap = false
}

/// Cell with only text (`c_n == 1`). hl_state carries over, repeat = 1.
const Cell1 = struct {
    text: []const u8,
    fn emit(self: Cell1, b: *BufList, alloc: std.mem.Allocator) !void {
        try wArrHead(b, alloc, 1);
        try wStr(b, alloc, self.text);
    }
};

/// Cell with text + hl_id (`c_n == 2`).
const Cell2 = struct {
    text: []const u8,
    hl: i16,
    fn emit(self: Cell2, b: *BufList, alloc: std.mem.Allocator) !void {
        try wArrHead(b, alloc, 2);
        try wStr(b, alloc, self.text);
        try wInt(b, alloc, self.hl);
    }
};

/// Cell with text + hl_id + repeat (`c_n == 3`).
const Cell3 = struct {
    text: []const u8,
    hl: i16,
    repeat: i16,
    fn emit(self: Cell3, b: *BufList, alloc: std.mem.Allocator) !void {
        try wArrHead(b, alloc, 3);
        try wStr(b, alloc, self.text);
        try wInt(b, alloc, self.hl);
        try wInt(b, alloc, self.repeat);
    }
};

fn wInt(b: *BufList, alloc: std.mem.Allocator, v: i16) !void {
    if (v >= 0 and v <= 0x7f) {
        try b.append(alloc, @intCast(v));
    } else if (v >= -32 and v < 0) {
        try b.append(alloc, @bitCast(@as(i8, @intCast(v))));
    } else if (v >= 0) {
        try b.append(alloc, 0xcd); // uint16
        try b.append(alloc, @intCast((v >> 8) & 0xFF));
        try b.append(alloc, @intCast(v & 0xFF));
    } else {
        try b.append(alloc, 0xd1); // int16
        const u: u16 = @bitCast(v);
        try b.append(alloc, @intCast((u >> 8) & 0xFF));
        try b.append(alloc, @intCast(u & 0xFF));
    }
}

fn emitFlushEvent(b: *BufList, alloc: std.mem.Allocator) !void {
    try wArrHead(b, alloc, 1); // event = [name]  (flush has no tuples per Neovim API)
    try wStr(b, alloc, "flush");
}

fn emitHlAttrDefine(b: *BufList, alloc: std.mem.Allocator, id: u8, fg: u32) !void {
    try wArrHead(b, alloc, 2); // event = [name, tuple]
    try wStr(b, alloc, "hl_attr_define");

    // tuple: [id, rgb_attrs, cterm_attrs, info]
    try wArrHead(b, alloc, 4);
    try wPositiveFixint(b, alloc, id);

    // rgb_attrs map: { "foreground" → fg }
    try wMapHead(b, alloc, 1);
    try wStr(b, alloc, "foreground");
    try b.append(alloc, 0xce); // uint32
    try b.append(alloc, @intCast((fg >> 24) & 0xFF));
    try b.append(alloc, @intCast((fg >> 16) & 0xFF));
    try b.append(alloc, @intCast((fg >> 8) & 0xFF));
    try b.append(alloc, @intCast(fg & 0xFF));

    // cterm_attrs: empty map
    try wMapHead(b, alloc, 0);
    // info: empty array
    try wArrHead(b, alloc, 0);
}

fn emitGridCursorGoto(b: *BufList, alloc: std.mem.Allocator, grid_id: u8, row: u8, col: u8) !void {
    try wArrHead(b, alloc, 2);
    try wStr(b, alloc, "grid_cursor_goto");
    try wArrHead(b, alloc, 3);
    try wPositiveFixint(b, alloc, grid_id);
    try wPositiveFixint(b, alloc, row);
    try wPositiveFixint(b, alloc, col);
}

// ---------------------------------------------------------------------------
// Parity runner. Builds frame_bytes once, then replays it through both
// worlds with fresh state and compares side effects.
// ---------------------------------------------------------------------------

fn runParity(alloc: std.mem.Allocator, frame_bytes: []const u8, rows: u32, cols: u32) !void {
    var a = try World.init(alloc, rows, cols);
    defer a.deinit();
    var bw = try World.init(alloc, rows, cols);
    defer bw.deinit();

    try runValueTreePath(frame_bytes, &a);
    try runStreamingPath(frame_bytes, &bw);

    try expectGridParity(&a.grid, &bw.grid);
    try expectHlParity(&a.hl, &bw.hl);
    try expectStubParity(&a.stub, &bw.stub);
}

// ---------------------------------------------------------------------------
// Scenarios.
// ---------------------------------------------------------------------------

test "parity: grid_line single cell simple" {
    const gpa = testing.allocator;
    var b: BufList = .empty;
    defer b.deinit(gpa);

    try startRedrawFrame(&b, gpa, 1);
    const cells = [_]Cell2{.{ .text = "x", .hl = 5 }};
    try emitGridLineEvent(&b, gpa, Cell2, 1, 0, 0, cells[0..]);

    try runParity(gpa, b.items, 10, 80);
}

test "parity: grid_line 1000 cells" {
    const gpa = testing.allocator;
    var b: BufList = .empty;
    defer b.deinit(gpa);

    try startRedrawFrame(&b, gpa, 1);

    var cells_arr: [1000]Cell2 = undefined;
    for (&cells_arr, 0..) |*c, i| {
        c.* = .{ .text = "a", .hl = @intCast((i % 10) + 1) };
    }
    try emitGridLineEvent(&b, gpa, Cell2, 1, 0, 0, cells_arr[0..]);

    try runParity(gpa, b.items, 10, 1200);
}

test "parity: grid_line repeat=0 must skip cell entirely" {
    const gpa = testing.allocator;
    var b: BufList = .empty;
    defer b.deinit(gpa);

    try startRedrawFrame(&b, gpa, 1);

    const cells = [_]Cell3{
        .{ .text = "a", .hl = 1, .repeat = 3 }, // writes cols 0,1,2
        .{ .text = "b", .hl = 2, .repeat = 0 }, // NO-OP, does not advance col
        .{ .text = "c", .hl = 3, .repeat = 2 }, // writes cols 3,4 — col did NOT advance past "b"
    };
    try emitGridLineEvent(&b, gpa, Cell3, 1, 0, 0, cells[0..]);

    try runParity(gpa, b.items, 10, 80);
}

test "parity: grid_line hl=-1 inherits from left except col 0" {
    const gpa = testing.allocator;
    var b: BufList = .empty;
    defer b.deinit(gpa);

    try startRedrawFrame(&b, gpa, 1);

    // Start with hl=7, then one cell with hl=-1 at col 1 (inherits 7),
    // then continue with hl=-1 at cols 2+ (still inherits from left = 7).
    const cells = [_]Cell2{
        .{ .text = "a", .hl = 7 },
        .{ .text = "b", .hl = -1 },
        .{ .text = "c", .hl = -1 },
    };
    try emitGridLineEvent(&b, gpa, Cell2, 1, 0, 0, cells[0..]);

    try runParity(gpa, b.items, 10, 80);
}

test "parity: grid_line hl=-1 at col 0 treated as 0" {
    const gpa = testing.allocator;
    var b: BufList = .empty;
    defer b.deinit(gpa);

    try startRedrawFrame(&b, gpa, 1);

    // First cell has hl=-1 at col=0 → should be written with hl=0.
    const cells = [_]Cell2{
        .{ .text = "a", .hl = -1 },
        .{ .text = "b", .hl = -1 }, // col 1, inherits from col 0 = 0
    };
    try emitGridLineEvent(&b, gpa, Cell2, 1, 0, 0, cells[0..]);

    try runParity(gpa, b.items, 10, 80);
}

test "parity: grid_line multi-codepoint overflow" {
    const gpa = testing.allocator;
    var b: BufList = .empty;
    defer b.deinit(gpa);

    try startRedrawFrame(&b, gpa, 1);

    // ⚠️ = U+26A0 + U+FE0F (2 codepoints). Overflow map should record FE0F.
    const cells = [_]Cell2{
        .{ .text = "\xE2\x9A\xA0\xEF\xB8\x8F", .hl = 1 },
        .{ .text = "x", .hl = 1 }, // simple cell — overflow at col 1 must NOT exist
    };
    try emitGridLineEvent(&b, gpa, Cell2, 1, 0, 0, cells[0..]);

    try runParity(gpa, b.items, 10, 80);
}

test "parity: grid_line + flush fires callback exactly once" {
    const gpa = testing.allocator;
    var b: BufList = .empty;
    defer b.deinit(gpa);

    try startRedrawFrame(&b, gpa, 2);

    const cells = [_]Cell2{
        .{ .text = "a", .hl = 1 },
        .{ .text = "b", .hl = 2 },
    };
    try emitGridLineEvent(&b, gpa, Cell2, 1, 0, 0, cells[0..]);
    try emitFlushEvent(&b, gpa);

    try runParity(gpa, b.items, 10, 80);
}

test "parity: hl_attr_define + grid_line + flush" {
    const gpa = testing.allocator;
    var b: BufList = .empty;
    defer b.deinit(gpa);

    try startRedrawFrame(&b, gpa, 3);

    try emitHlAttrDefine(&b, gpa, 42, 0xFF00FF);
    const cells = [_]Cell2{.{ .text = "a", .hl = 42 }};
    try emitGridLineEvent(&b, gpa, Cell2, 1, 0, 0, cells[0..]);
    try emitFlushEvent(&b, gpa);

    try runParity(gpa, b.items, 10, 80);
}

test "parity: grid_cursor_goto + grid_line + flush" {
    const gpa = testing.allocator;
    var b: BufList = .empty;
    defer b.deinit(gpa);

    try startRedrawFrame(&b, gpa, 3);

    try emitGridCursorGoto(&b, gpa, 1, 2, 3);
    const cells = [_]Cell2{.{ .text = "X", .hl = 1 }};
    try emitGridLineEvent(&b, gpa, Cell2, 1, 2, 3, cells[0..]);
    try emitFlushEvent(&b, gpa);

    try runParity(gpa, b.items, 10, 80);
}

test "parity: two grid_line batches on same grid + flush" {
    const gpa = testing.allocator;
    var b: BufList = .empty;
    defer b.deinit(gpa);

    try startRedrawFrame(&b, gpa, 3);

    const cells_a = [_]Cell2{ .{ .text = "a", .hl = 1 }, .{ .text = "b", .hl = 1 } };
    try emitGridLineEvent(&b, gpa, Cell2, 1, 0, 0, cells_a[0..]);

    const cells_b = [_]Cell2{ .{ .text = "c", .hl = 2 }, .{ .text = "d", .hl = 2 } };
    try emitGridLineEvent(&b, gpa, Cell2, 1, 1, 0, cells_b[0..]);

    try emitFlushEvent(&b, gpa);

    try runParity(gpa, b.items, 10, 80);
}

test "parity: c_n==1 cell keeps hl_state from previous cell" {
    const gpa = testing.allocator;
    var b: BufList = .empty;
    defer b.deinit(gpa);

    try startRedrawFrame(&b, gpa, 1);

    // Build a mixed cells array: [Cell2, Cell1, Cell1] — first sets hl_state
    // to 7, remaining two should inherit that hl_state.
    try wArrHead(&b, gpa, 2);
    try wStr(&b, gpa, "grid_line");
    try wArrHead(&b, gpa, 5);
    try wPositiveFixint(&b, gpa, 1);
    try wPositiveFixint(&b, gpa, 0);
    try wPositiveFixint(&b, gpa, 0);
    try wArrHead(&b, gpa, 3);
    try (Cell2{ .text = "a", .hl = 7 }).emit(&b, gpa);
    try (Cell1{ .text = "b" }).emit(&b, gpa);
    try (Cell1{ .text = "c" }).emit(&b, gpa);
    try b.append(gpa, 0xc2); // wrap

    try runParity(gpa, b.items, 10, 80);
}
