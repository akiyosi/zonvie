// cursor_style_test.zig — mode_info_set must re-resolve the CURRENT mode.
//
// The grid's live cursor style fields (shape, cell_percentage, attr_id, blink
// timings) are a snapshot of one mode_infos entry. Neovim sends mode_info_set
// alone when `guicursor` changes and does NOT follow it with a mode_change, so
// resolving the style only on mode_change leaves the previous shape on screen
// until the user happens to switch modes.

const std = @import("std");
const zc = @import("zonvie_core");

const mp = zc.msgpack;
const redraw = zc.redraw_handler;
const Grid = zc.grid_mod.Grid;
const CursorShape = zc.grid_mod.CursorShape;
const Highlights = zc.highlight.Highlights;
const Logger = zc.log_mod.Logger;

const testing = std.testing;

const Stub = struct {
    fn onPreFlush(_: *Stub) anyerror!void {}
    fn onFlush(_: *Stub, _: u32, _: u32) anyerror!void {}
    fn onGuifont(_: *Stub, _: []const u8) anyerror!void {}
    fn onLinespace(_: *Stub, _: i32) anyerror!void {}
    fn onSetTitle(_: *Stub, _: []const u8) anyerror!void {}
    fn onDefaultColors(_: *Stub, _: u32, _: u32) anyerror!void {}
    fn onRestart(_: *Stub, _: []const u8) anyerror!void {}
    fn onConnect(_: *Stub, _: []const u8) anyerror!void {}
    fn onImageData(_: *Stub, _: i64, _: []const u8) anyerror!void {}
    fn onImageSet(_: *Stub, _: i64, _: bool, _: i32, _: i32, _: i32, _: i32, _: i32) anyerror!void {}
    fn onImageDel(_: *Stub, _: i64) anyerror!void {}
};

const World = struct {
    grid: Grid,
    hl: Highlights,
    stub: Stub = .{},
    arena: std.heap.ArenaAllocator,
    log: Logger = .{},

    fn init(alloc: std.mem.Allocator) !World {
        var g = Grid.init(alloc);
        try g.resize(4, 8);
        return .{
            .grid = g,
            .hl = Highlights.init(alloc),
            .arena = std.heap.ArenaAllocator.init(alloc),
        };
    }

    fn deinit(self: *World) void {
        self.grid.deinit();
        self.hl.deinit();
        self.arena.deinit();
    }

    fn feed(self: *World, params: []mp.Value) !void {
        try redraw.handleRedraw(
            &self.grid,
            &self.hl,
            self.arena.allocator(),
            params,
            &self.log,
            &self.stub,
            Stub.onPreFlush,
            Stub.onFlush,
            &self.stub,
            Stub.onGuifont,
            &self.stub,
            Stub.onLinespace,
            Stub.onSetTitle,
            Stub.onDefaultColors,
            Stub.onRestart,
            Stub.onConnect,
            Stub.onImageData,
            Stub.onImageSet,
            Stub.onImageDel,
        );
    }
};

/// ["mode_info_set", [true, [{cursor_shape: <shape>, blinkon: <blink_on>}]]]
/// A single-entry table, so mode index 0 is the only mode.
fn modeInfoSet(arena: std.mem.Allocator, shape: []const u8, blink_on: i64) ![]mp.Value {
    const entry = try arena.alloc(mp.Pair, 2);
    entry[0] = .{ .key = .{ .str = "cursor_shape" }, .val = .{ .str = shape } };
    entry[1] = .{ .key = .{ .str = "blinkon" }, .val = .{ .int = blink_on } };

    const modes = try arena.alloc(mp.Value, 1);
    modes[0] = .{ .map = entry };

    const tuple = try arena.alloc(mp.Value, 2);
    tuple[0] = .{ .bool = true }; // cursor_style_enabled
    tuple[1] = .{ .arr = modes };

    const ev = try arena.alloc(mp.Value, 2);
    ev[0] = .{ .str = "mode_info_set" };
    ev[1] = .{ .arr = tuple };

    const params = try arena.alloc(mp.Value, 1);
    params[0] = .{ .arr = ev };
    return params;
}

/// ["mode_change", ["normal", 0]]
fn modeChange(arena: std.mem.Allocator, idx: i64) ![]mp.Value {
    const tuple = try arena.alloc(mp.Value, 2);
    tuple[0] = .{ .str = "normal" };
    tuple[1] = .{ .int = idx };

    const ev = try arena.alloc(mp.Value, 2);
    ev[0] = .{ .str = "mode_change" };
    ev[1] = .{ .arr = tuple };

    const params = try arena.alloc(mp.Value, 1);
    params[0] = .{ .arr = ev };
    return params;
}

test "mode_info_set re-resolves the current mode without a mode_change" {
    var w = try World.init(testing.allocator);
    defer w.deinit();
    const arena = w.arena.allocator();

    // Establish "block" as the style of the current mode (index 0).
    try w.feed(try modeInfoSet(arena, "block", 0));
    try w.feed(try modeChange(arena, 0));
    try testing.expectEqual(CursorShape.block, w.grid.cursor_shape);

    // `:set guicursor=n-v-c:ver25` — a new table for the SAME mode, with no
    // mode_change behind it. The live shape must follow immediately.
    const rev_before = w.grid.cursor_rev;
    try w.feed(try modeInfoSet(arena, "vertical", 0));

    try testing.expectEqual(CursorShape.vertical, w.grid.cursor_shape);
    // The cursor must also be resubmitted, or the frontend keeps drawing the
    // old shape even though the core now knows the new one.
    try testing.expect(w.grid.cursor_rev != rev_before);
}

test "mode_info_set carries every live cursor field, not just the shape" {
    var w = try World.init(testing.allocator);
    defer w.deinit();
    const arena = w.arena.allocator();

    try w.feed(try modeInfoSet(arena, "block", 500));
    try w.feed(try modeChange(arena, 0));
    try testing.expectEqual(@as(u32, 500), w.grid.cursor_blink_on_ms);

    // blinkon0 must take effect without a mode change too — this is what the
    // visual test fixtures rely on to get a steady cursor.
    try w.feed(try modeInfoSet(arena, "block", 0));
    try testing.expectEqual(@as(u32, 0), w.grid.cursor_blink_on_ms);
}

test "mode_info_set leaves the style alone when cursor_style_enabled is false" {
    var w = try World.init(testing.allocator);
    defer w.deinit();
    const arena = w.arena.allocator();

    try w.feed(try modeInfoSet(arena, "block", 0));
    try w.feed(try modeChange(arena, 0));

    // enabled=false means the UI opted out of cursor styling; the shape must
    // not be touched even though a table arrives.
    const params = try modeInfoSet(arena, "vertical", 0);
    params[0].arr[1].arr[0] = .{ .bool = false };
    try w.feed(params);

    try testing.expectEqual(CursorShape.block, w.grid.cursor_shape);
}
