// mpack_stream.zig — Zero-copy streaming MessagePack decoder.
//
// Unlike msgpack.zig which materializes a full `Value` tree into an allocator,
// this module decodes MessagePack by advancing through an in-memory byte slice
// and returning zero-copy views (for strings/bin/ext payloads) into that slice.
// This is intended for the RPC hot path (`redraw` notifications) where the
// previous Value-tree approach allocated per-cell and per-field.
//
// Design mirrors the two-layer pattern from nvim-ui-client:
//
//   - `InnerDecoder` operates on `[]const u8`. On any short-read it returns
//     `EOFError` and leaves the decoder in an undefined, unusable state.
//   - `SkipDecoder` is a safe outer layer that hands out a fresh InnerDecoder
//     only when no outstanding item/byte work is queued. On `EOFError` callers
//     discard the InnerDecoder and try again once more bytes have been buffered.
//
// Zero-copy guarantee: all `[]const u8` values returned from `expectString`,
// `expectBin`, and `expectExt` are sub-slices of the caller-owned input buffer.
// The caller must not free or overwrite that buffer while these views are in
// use. For RPC streaming, the ring buffer must guarantee the decoded frame
// stays resident until the handler for that frame returns.

const std = @import("std");

pub const ExtHead = struct {
    kind: i8,
    size: u32,
};

pub const SmallExt = struct {
    kind: i8,
    data: []const u8,
};

pub const ValueHead = union(enum) {
    Null,
    Bool: bool,
    Int: i64,
    UInt: u64,
    Float32: f32,
    Float64: f64,
    Array: u32,
    Map: u32,
    Str: u32,
    Bin: u32,
    Ext: ExtHead,

    /// Returns the remaining work (nested items + trailing bytes) that a call
    /// to `skipAny` would need to consume after reading this head. Used by
    /// `SkipDecoder.skipData` to advance past ignored subtrees iteratively.
    pub fn itemSize(head: ValueHead) struct { bytes: u32, items: usize } {
        return switch (head) {
            .Str => |size| .{ .bytes = size, .items = 0 },
            .Bin => |size| .{ .bytes = size, .items = 0 },
            .Ext => |ext| .{ .bytes = ext.size, .items = 0 },
            .Array => |size| .{ .bytes = 0, .items = size },
            .Map => |size| .{ .bytes = 0, .items = 2 * size },
            else => .{ .bytes = 0, .items = 0 },
        };
    }
};

pub const MpackError = error{
    MalformatedDataError,
    // Recoverable: retry once more bytes are buffered.
    EOFError,
    UnexpectedTagError,
    InvalidDecodeOperation,
};

pub const EOFError = error{EOFError};

/// Unsafe zero-copy decoder. On any `EOFError` the caller must discard this
/// instance and retry from a fresh `SkipDecoder.inner()`.
pub const InnerDecoder = struct {
    data: []const u8,

    const Self = @This();

    fn readBytes(self: *Self, size: usize) EOFError![]const u8 {
        if (self.data.len < size) return error.EOFError;
        const slice = self.data[0..size];
        self.data = self.data[size..];
        return slice;
    }

    fn readIntT(self: *Self, comptime T: type) EOFError!T {
        const slice = try self.readBytes(@sizeOf(T));
        return std.mem.readInt(T, slice[0..@sizeOf(T)], .big);
    }

    fn readFloat(self: *Self, comptime T: type) EOFError!T {
        const utype = if (T == f32) u32 else if (T == f64) u64 else @compileError("unsupported float type");
        const int = try self.readIntT(utype);
        return @bitCast(int);
    }

    fn readFixExt(self: *Self, size: u32) EOFError!ExtHead {
        const kind = try self.readIntT(i8);
        return .{ .kind = kind, .size = size };
    }

    fn readExt(self: *Self, comptime sizetype: type) EOFError!ExtHead {
        const size = try self.readIntT(sizetype);
        return try self.readFixExt(size);
    }

    /// Read one MessagePack value head (tag byte plus length/payload prefix).
    /// For Str/Bin/Ext the payload bytes follow in `self.data` — use
    /// `expectString` / `expectBin` / `expectExt` to consume them as slices.
    pub fn readHead(self: *Self) MpackError!ValueHead {
        const first_byte = (try self.readBytes(1))[0];
        return switch (first_byte) {
            0x00...0x7f => .{ .Int = first_byte },
            0x80...0x8f => .{ .Map = (first_byte - 0x80) },
            0x90...0x9f => .{ .Array = (first_byte - 0x90) },
            0xa0...0xbf => .{ .Str = (first_byte - 0xa0) },
            0xc0 => .Null,
            0xc1 => error.MalformatedDataError,
            0xc2 => .{ .Bool = false },
            0xc3 => .{ .Bool = true },
            0xc4 => .{ .Bin = try self.readIntT(u8) },
            0xc5 => .{ .Bin = try self.readIntT(u16) },
            0xc6 => .{ .Bin = try self.readIntT(u32) },
            0xc7 => .{ .Ext = try self.readExt(u8) },
            0xc8 => .{ .Ext = try self.readExt(u16) },
            0xc9 => .{ .Ext = try self.readExt(u32) },
            0xca => .{ .Float32 = try self.readFloat(f32) },
            0xcb => .{ .Float64 = try self.readFloat(f64) },
            0xcc => .{ .UInt = try self.readIntT(u8) },
            0xcd => .{ .UInt = try self.readIntT(u16) },
            0xce => .{ .UInt = try self.readIntT(u32) },
            0xcf => .{ .UInt = try self.readIntT(u64) },
            0xd0 => .{ .Int = try self.readIntT(i8) },
            0xd1 => .{ .Int = try self.readIntT(i16) },
            0xd2 => .{ .Int = try self.readIntT(i32) },
            0xd3 => .{ .Int = try self.readIntT(i64) },
            0xd4 => .{ .Ext = try self.readFixExt(1) },
            0xd5 => .{ .Ext = try self.readFixExt(2) },
            0xd6 => .{ .Ext = try self.readFixExt(4) },
            0xd7 => .{ .Ext = try self.readFixExt(8) },
            0xd8 => .{ .Ext = try self.readFixExt(16) },
            0xd9 => .{ .Str = try self.readIntT(u8) },
            0xda => .{ .Str = try self.readIntT(u16) },
            0xdb => .{ .Str = try self.readIntT(u32) },
            0xdc => .{ .Array = try self.readIntT(u16) },
            0xdd => .{ .Array = try self.readIntT(u32) },
            0xde => .{ .Map = try self.readIntT(u16) },
            0xdf => .{ .Map = try self.readIntT(u32) },
            0xe0...0xff => .{ .Int = @as(i64, @as(i8, @bitCast(first_byte))) },
        };
    }

    pub fn expectArray(self: *Self) MpackError!u32 {
        return switch (try self.readHead()) {
            .Array => |n| n,
            else => error.UnexpectedTagError,
        };
    }

    pub fn expectMap(self: *Self) MpackError!u32 {
        return switch (try self.readHead()) {
            .Map => |n| n,
            else => error.UnexpectedTagError,
        };
    }

    pub fn expectUInt(self: *Self) MpackError!u64 {
        return switch (try self.readHead()) {
            .UInt => |v| v,
            .Int => |v| if (v < 0) error.UnexpectedTagError else @intCast(v),
            else => error.UnexpectedTagError,
        };
    }

    pub fn expectInt(self: *Self) MpackError!i64 {
        return switch (try self.readHead()) {
            .UInt => |v| if (v > std.math.maxInt(i64)) error.UnexpectedTagError else @intCast(v),
            .Int => |v| v,
            else => error.UnexpectedTagError,
        };
    }

    pub fn expectBool(self: *Self) MpackError!bool {
        return switch (try self.readHead()) {
            .Bool => |b| b,
            else => error.UnexpectedTagError,
        };
    }

    pub fn expectNil(self: *Self) MpackError!void {
        return switch (try self.readHead()) {
            .Null => {},
            else => error.UnexpectedTagError,
        };
    }

    pub fn expectFloat(self: *Self) MpackError!f64 {
        return switch (try self.readHead()) {
            .Float32 => |v| @floatCast(v),
            .Float64 => |v| v,
            .UInt => |v| @floatFromInt(v),
            .Int => |v| @floatFromInt(v),
            else => error.UnexpectedTagError,
        };
    }

    /// Returns a zero-copy slice. Accepts both Str and Bin tags since Neovim
    /// sometimes sends Bin for opaque byte strings.
    pub fn expectString(self: *Self) MpackError![]const u8 {
        const size: usize = switch (try self.readHead()) {
            .Str => |n| n,
            .Bin => |n| n,
            else => return error.UnexpectedTagError,
        };
        if (self.data.len < size) return error.EOFError;
        const slice = self.data[0..size];
        self.data = self.data[size..];
        return slice;
    }

    pub fn expectBin(self: *Self) MpackError![]const u8 {
        const size: usize = switch (try self.readHead()) {
            .Bin => |n| n,
            .Str => |n| n,
            else => return error.UnexpectedTagError,
        };
        if (self.data.len < size) return error.EOFError;
        const slice = self.data[0..size];
        self.data = self.data[size..];
        return slice;
    }

    pub fn expectExt(self: *Self) MpackError!SmallExt {
        const hdr = switch (try self.readHead()) {
            .Ext => |e| e,
            else => return error.UnexpectedTagError,
        };
        if (self.data.len < hdr.size) return error.EOFError;
        const slice = self.data[0..hdr.size];
        self.data = self.data[hdr.size..];
        return .{ .kind = hdr.kind, .data = slice };
    }

    /// Skip `nitems` MessagePack values, including nested arrays/maps/strings.
    pub fn skipAny(self: *Self, nitems: u64) MpackError!void {
        var bytes: u64 = 0;
        var items: u64 = nitems;
        while (bytes > 0 or items > 0) {
            if (bytes > 0) {
                if (self.data.len < bytes) return error.EOFError;
                self.data = self.data[@intCast(bytes)..];
                bytes = 0;
            } else {
                const head = try self.readHead();
                const sz = head.itemSize();
                items += sz.items;
                items -= 1;
                bytes += sz.bytes;
            }
        }
    }
};

/// Neovim sends window/tab/buffer handles as MessagePack EXT with the payload
/// encoded as a nested MessagePack integer. This helper unwraps that integer.
/// Returns 0 if the payload is empty or malformed.
pub fn parseExtHandle(ext: SmallExt) i64 {
    if (ext.data.len == 0) return 0;
    var d = InnerDecoder{ .data = ext.data };
    const head = d.readHead() catch return 0;
    return switch (head) {
        .Int => |v| v,
        .UInt => |v| if (v > std.math.maxInt(i64)) 0 else @intCast(v),
        else => 0,
    };
}

/// Safe outer layer. Maintains a "pending skip" counter so that when an EOF
/// occurs mid-frame the caller can retry `skipData()` once more bytes have
/// been buffered into `data`. Only hand out `inner()` when the skip state is
/// drained — otherwise the indexes into `data` are out of sync with any
/// decoder state the caller might hold.
pub const SkipDecoder = struct {
    data: []const u8,
    bytes: u64 = 0,
    items: u64 = 0,

    const Self = @This();

    pub fn init(data: []const u8) Self {
        return .{ .data = data };
    }

    fn rawInner(self: *Self) InnerDecoder {
        return .{ .data = self.data };
    }

    /// Hand out a fresh InnerDecoder. Fails if skip work is still pending.
    pub fn inner(self: *Self) MpackError!InnerDecoder {
        if (self.bytes > 0 or self.items > 0) return error.InvalidDecodeOperation;
        return self.rawInner();
    }

    /// Commit the InnerDecoder's advance position back to this outer layer.
    /// Call this only after a successful (non-EOF) read sequence.
    pub fn consumed(self: *Self, c: InnerDecoder) void {
        self.data = c.data;
    }

    /// Drain pending skip work. Safe to retry after EOFError.
    pub fn skipData(self: *Self) MpackError!void {
        while (self.bytes > 0 or self.items > 0) {
            if (self.bytes > 0) {
                if (self.data.len == 0) return error.EOFError;
                const skip = @min(self.bytes, self.data.len);
                self.data = self.data[@intCast(skip)..];
                self.bytes -= skip;
            } else {
                var d = self.rawInner();
                const head = try d.readHead();
                self.consumed(d);
                const sz = head.itemSize();
                self.items += sz.items;
                self.items -= 1;
                self.bytes += sz.bytes;
            }
        }
    }

    /// Queue up `n` items for skipping. Subsequent `skipData()` drains them.
    pub fn toSkip(self: *Self, n: u64) void {
        self.items += n;
    }

    /// How many unconsumed bytes remain in the view.
    pub fn remaining(self: *const Self) usize {
        return self.data.len;
    }
};

// -----------------------------------------------------------------------------
// Tests
// -----------------------------------------------------------------------------

test "readHead: fixint, fixstr, fixarray" {
    const data = [_]u8{
        0x03, // positive fixint 3
        0xa5, 'h', 'e', 'l', 'l', 'o', // fixstr "hello"
        0x93, 0x01, 0x02, 0x03, // fixarray [1,2,3]
    };
    var d = InnerDecoder{ .data = data[0..] };

    try std.testing.expectEqual(@as(i64, 3), (try d.readHead()).Int);
    const s = try d.expectString();
    try std.testing.expectEqualStrings("hello", s);
    try std.testing.expectEqual(@as(u32, 3), try d.expectArray());
    try std.testing.expectEqual(@as(u64, 1), try d.expectUInt());
    try std.testing.expectEqual(@as(u64, 2), try d.expectUInt());
    try std.testing.expectEqual(@as(u64, 3), try d.expectUInt());
    try std.testing.expectEqual(@as(usize, 0), d.data.len);
}

test "readHead: int widths" {
    const data = [_]u8{
        0xcc, 0xff, // uint8 255
        0xcd, 0x01, 0x00, // uint16 256
        0xce, 0x00, 0x01, 0x00, 0x00, // uint32 65536
        0xd0, 0xff, // int8 -1
        0xd1, 0x80, 0x00, // int16 -32768
        0xff, // negative fixint -1
    };
    var d = InnerDecoder{ .data = data[0..] };
    try std.testing.expectEqual(@as(u64, 255), try d.expectUInt());
    try std.testing.expectEqual(@as(u64, 256), try d.expectUInt());
    try std.testing.expectEqual(@as(u64, 65536), try d.expectUInt());
    try std.testing.expectEqual(@as(i64, -1), try d.expectInt());
    try std.testing.expectEqual(@as(i64, -32768), try d.expectInt());
    try std.testing.expectEqual(@as(i64, -1), try d.expectInt());
}

test "EOF on truncated string" {
    const data = [_]u8{ 0xa5, 'h', 'i' };
    var d = InnerDecoder{ .data = data[0..] };
    try std.testing.expectError(error.EOFError, d.expectString());
}

test "SkipDecoder recovers after EOF" {
    const full = [_]u8{
        0x92, // array len 2
        0xa5, 'h', 'e', 'l', 'l', 'o', // "hello"
        0x2a, // 42
    };
    // Simulate two-phase read: first only the first 3 bytes arrive.
    var sd = SkipDecoder.init(full[0..3]);

    // First attempt: decoder walks into the array header, then hits EOF
    // trying to read the string payload.
    var in = try sd.inner();
    const n = try in.expectArray();
    try std.testing.expectEqual(@as(u32, 2), n);
    try std.testing.expectError(error.EOFError, in.expectString());
    // Don't commit; the InnerDecoder is now in undefined state.

    // More bytes arrive. Re-initialise with the full buffer, starting where
    // we left off — the SkipDecoder has already consumed `0x92` via its own
    // state? No: we never called `consumed`, so sd.data is still the original
    // 3 bytes. In the real RPC loop, the ring buffer supplies a growing view.
    sd = SkipDecoder.init(full[0..]);

    var in2 = try sd.inner();
    try std.testing.expectEqual(@as(u32, 2), try in2.expectArray());
    try std.testing.expectEqualStrings("hello", try in2.expectString());
    try std.testing.expectEqual(@as(u64, 42), try in2.expectUInt());
    sd.consumed(in2);
    try std.testing.expectEqual(@as(usize, 0), sd.remaining());
}

test "skipAny: nested array" {
    const data = [_]u8{
        0x92, // array len 2
        0x93, 0x01, 0x02, 0x03, // inner array [1,2,3]
        0xa3, 'b', 'y', 'e', // "bye"
        0x7f, // trailing fixint 127
    };
    var d = InnerDecoder{ .data = data[0..] };
    try std.testing.expectEqual(@as(u32, 2), try d.expectArray());
    try d.skipAny(2);
    try std.testing.expectEqual(@as(i64, 127), (try d.readHead()).Int);
}

test "expectExt: fixext" {
    const data = [_]u8{
        0xd4, 0x01, 0x2a, // fixext1: kind=1, data=[0x2a]
    };
    var d = InnerDecoder{ .data = data[0..] };
    const ext = try d.expectExt();
    try std.testing.expectEqual(@as(i8, 1), ext.kind);
    try std.testing.expectEqual(@as(usize, 1), ext.data.len);
    try std.testing.expectEqual(@as(u8, 0x2a), ext.data[0]);
}

test "parseExtHandle: nested uint" {
    // ext payload is a MessagePack uint8 encoding of 7
    const data = [_]u8{ 0xcc, 0x07 };
    const h = parseExtHandle(.{ .kind = 1, .data = data[0..] });
    try std.testing.expectEqual(@as(i64, 7), h);
}
