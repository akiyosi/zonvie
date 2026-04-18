const std = @import("std");

pub const Pair = struct {
    key: Value,
    val: Value,
};

pub const Ext = struct {
    type_code: i8,
    data: []const u8,
};

pub const Value = union(enum) {
    nil,
    bool: bool,
    int: i64,
    float: f64,
    str: []const u8, // Also used for MessagePack BIN payloads (raw bytes).
    arr: []Value,
    map: []Pair,
    ext: Ext,
};

fn readU8(r: anytype) anyerror!u8 {
    return try r.readByte();
}

fn readNoEof(r: anytype, buf: []u8) anyerror!void {
    try r.readNoEof(buf);
}

fn readIntBig(r: anytype, comptime T: type) anyerror!T {
    var tmp: [@sizeOf(T)]u8 = undefined;
    try readNoEof(r, tmp[0..]);
    return std.mem.readInt(T, tmp[0..], .big);
}

fn decodeInt(r: anytype, b0: u8) anyerror!i64 {
    // Positive fixint
    if ((b0 & 0x80) == 0) return @as(i64, b0);

    // Negative fixint (0xe0..0xff)
    if ((b0 & 0xE0) == 0xE0) {
        const s: i8 = @bitCast(b0);
        return @as(i64, s);
    }

    return switch (b0) {
        0xcc => @as(i64, try readIntBig(r, u8)),
        0xcd => @as(i64, try readIntBig(r, u16)),
        0xce => @as(i64, try readIntBig(r, u32)),
        0xcf => @as(i64, @intCast(try readIntBig(r, u64))),
        0xd0 => @as(i64, @as(i8, @bitCast(try readIntBig(r, u8)))),
        0xd1 => @as(i64, try readIntBig(r, i16)),
        0xd2 => @as(i64, try readIntBig(r, i32)),
        0xd3 => try readIntBig(r, i64),
        else => error.Invalid,
    };
}

fn decodeFloat(r: anytype, b0: u8) anyerror!f64 {
    return switch (b0) {
        0xca => @as(f64, @floatCast(@as(f32, @bitCast(try readIntBig(r, u32))))),
        0xcb => @as(f64, @bitCast(try readIntBig(r, u64))),
        else => error.Invalid,
    };
}

fn decodeStrLen(r: anytype, b0: u8) anyerror!usize {
    // fixstr
    if ((b0 & 0xE0) == 0xA0) return @as(usize, b0 & 0x1F);

    return switch (b0) {
        0xd9 => @as(usize, try readIntBig(r, u8)),  // str8
        0xda => @as(usize, try readIntBig(r, u16)), // str16
        0xdb => @as(usize, try readIntBig(r, u32)), // str32
        else => error.Invalid,
    };
}

fn decodeBinLen(r: anytype, b0: u8) anyerror!usize {
    return switch (b0) {
        0xc4 => @as(usize, try readIntBig(r, u8)),  // bin8
        0xc5 => @as(usize, try readIntBig(r, u16)), // bin16
        0xc6 => @as(usize, try readIntBig(r, u32)), // bin32
        else => error.Invalid,
    };
}

fn decodeArrayLen(r: anytype, b0: u8) anyerror!usize {
    // fixarray
    if ((b0 & 0xF0) == 0x90) return @as(usize, b0 & 0x0F);

    return switch (b0) {
        0xdc => @as(usize, try readIntBig(r, u16)), // array16
        0xdd => @as(usize, try readIntBig(r, u32)), // array32
        else => error.Invalid,
    };
}

fn decodeMapLen(r: anytype, b0: u8) anyerror!usize {
    // fixmap
    if ((b0 & 0xF0) == 0x80) return @as(usize, b0 & 0x0F);

    return switch (b0) {
        0xde => @as(usize, try readIntBig(r, u16)), // map16
        0xdf => @as(usize, try readIntBig(r, u32)), // map32
        else => error.Invalid,
    };
}

fn decodeExtLen(r: anytype, b0: u8) anyerror!usize {
    // fixext
    return switch (b0) {
        0xd4 => 1,
        0xd5 => 2,
        0xd6 => 4,
        0xd7 => 8,
        0xd8 => 16,
        0xc7 => @as(usize, try readIntBig(r, u8)),  // ext8
        0xc8 => @as(usize, try readIntBig(r, u16)), // ext16
        0xc9 => @as(usize, try readIntBig(r, u32)), // ext32
        else => error.Invalid,
    };
}

const SliceReader = struct {
    data: []const u8,
    i: usize = 0,

    fn readByte(self: *SliceReader) anyerror!u8 {
        if (self.i >= self.data.len) return error.EndOfStream;
        const b = self.data[self.i];
        self.i += 1;
        return b;
    }

    fn readNoEof(self: *SliceReader, buf: []u8) anyerror!void {
        if (self.i + buf.len > self.data.len) return error.EndOfStream;
        std.mem.copyForwards(u8, buf, self.data[self.i .. self.i + buf.len]);
        self.i += buf.len;
    }
};

pub fn decode(alloc: std.mem.Allocator, r: anytype) anyerror!Value {
    const b0 = try readU8(r);

    // nil
    if (b0 == 0xc0) return .nil;

    // bool
    if (b0 == 0xc2) return .{ .bool = false };
    if (b0 == 0xc3) return .{ .bool = true };

    // float
    if (b0 == 0xca or b0 == 0xcb) {
        return .{ .float = try decodeFloat(r, b0) };
    }

    // str
    if ((b0 & 0xE0) == 0xA0 or b0 == 0xd9 or b0 == 0xda or b0 == 0xdb) {
        const n = try decodeStrLen(r, b0);
        const s = try alloc.alloc(u8, n);
        try readNoEof(r, s);
        return .{ .str = s };
    }

    // bin (Neovim uses msgpack v5 BIN types; store as .str bytes)
    if (b0 == 0xc4 or b0 == 0xc5 or b0 == 0xc6) {
        const n = try decodeBinLen(r, b0);
        const s = try alloc.alloc(u8, n);
        try readNoEof(r, s);
        return .{ .str = s };
    }

    // array
    if ((b0 & 0xF0) == 0x90 or b0 == 0xdc or b0 == 0xdd) {
        const n = try decodeArrayLen(r, b0);
        const items = try alloc.alloc(Value, n);
        var i: usize = 0;
        while (i < n) : (i += 1) {
            items[i] = try decode(alloc, r);
        }
        return .{ .arr = items };
    }

    // map
    if ((b0 & 0xF0) == 0x80 or b0 == 0xde or b0 == 0xdf) {
        const n = try decodeMapLen(r, b0);
        const pairs = try alloc.alloc(Pair, n);

        var i: usize = 0;
        while (i < n) : (i += 1) {
            const k = try decode(alloc, r);
            const v = try decode(alloc, r);
            pairs[i] = .{ .key = k, .val = v };
        }
        return .{ .map = pairs };
    }

    // int
    if ((b0 & 0x80) == 0 or (b0 & 0xE0) == 0xE0 or
        b0 == 0xcc or b0 == 0xcd or b0 == 0xce or b0 == 0xcf or
        b0 == 0xd0 or b0 == 0xd1 or b0 == 0xd2 or b0 == 0xd3)
    {
        return .{ .int = try decodeInt(r, b0) };
    }

    // ext (Neovim special handle types are msgpack EXT) :contentReference[oaicite:1]{index=1}
    if (b0 == 0xd4 or b0 == 0xd5 or b0 == 0xd6 or b0 == 0xd7 or b0 == 0xd8 or
        b0 == 0xc7 or b0 == 0xc8 or b0 == 0xc9)
    {
        const n = try decodeExtLen(r, b0);
        const type_code_u8 = try readU8(r);
        const type_code: i8 = @bitCast(type_code_u8);

        const data = try alloc.alloc(u8, n);
        try readNoEof(r, data);

        // Many clients treat EXT as opaque bytes; keep them.
        // Additionally, try to decode the payload as a msgpack integer handle for convenience.
        var sr = SliceReader{ .data = data, .i = 0 };
        if (sr.readByte()) |ib0| {
            // Only accept if it parses as an integer and consumes all bytes.
            if (decodeInt(&sr, ib0)) |hid| {
                if (sr.i == data.len) {
                    alloc.free(data); // Free the temporary buffer when returning as int
                    return .{ .int = hid };
                }
            } else |_| {}
        } else |_| {}

        return .{ .ext = .{ .type_code = type_code, .data = data } };
    }

    return error.UnsupportedType;
}

pub fn freeValue(alloc: std.mem.Allocator, v: Value) void {
    switch (v) {
        .str => |s| alloc.free(s),
        .arr => |a| {
            for (a) |it| freeValue(alloc, it);
            alloc.free(a);
        },
        .map => |m| {
            for (m) |p| {
                freeValue(alloc, p.key);
                freeValue(alloc, p.val);
            }
            alloc.free(m);
        },
        .ext => |e| alloc.free(e.data),
        else => {},
    }
}

/// Bridge helper: materialize a single `Value` tree from a streaming decoder.
///
/// Not used in production: the streaming redraw fast path that exercised
/// this helper was reverted after microbenchmarks (`zig build bench`)
/// showed a 1.24x–1.94x decode-path slowdown. The helper is retained as
/// a reference implementation for any future rewrite that drops the
/// intermediate `Value` tree on the `grid_line` hot path — that future
/// design will want a stream-oriented bridge and this is the shape of
/// it. String / bin / ext payloads are duplicated into `alloc` since
/// `InnerDecoder` returns zero-copy views into the caller's input buffer
/// (e.g., `FrameReader`'s backing store, which can be moved by a later
/// `fill()`), and long-lived `Value`s must not alias that storage.
///
/// Possible errors:
///   * `error.UnsupportedType` — MessagePack `u64` values exceeding
///     `maxInt(i64)`. Neovim never emits these in practice.
///   * `Allocator.Error.OutOfMemory` — from any nested allocation.
pub fn decodeFromStream(alloc: std.mem.Allocator, in: *mps.InnerDecoder) !Value {
    const head = try in.readHead();
    return switch (head) {
        .Null => .nil,
        .Bool => |b| .{ .bool = b },
        .Int => |v| .{ .int = v },
        .UInt => |v| if (v > std.math.maxInt(i64))
            error.UnsupportedType
        else
            .{ .int = @intCast(v) },
        .Float32 => |f| .{ .float = @floatCast(f) },
        .Float64 => |f| .{ .float = f },
        .Str => |n| blk: {
            if (in.data.len < n) return error.EOFError;
            const slice = in.data[0..n];
            in.data = in.data[n..];
            const owned = try alloc.dupe(u8, slice);
            break :blk .{ .str = owned };
        },
        .Bin => |n| blk: {
            if (in.data.len < n) return error.EOFError;
            const slice = in.data[0..n];
            in.data = in.data[n..];
            const owned = try alloc.dupe(u8, slice);
            break :blk .{ .str = owned };
        },
        .Ext => |h| blk: {
            if (in.data.len < h.size) return error.EOFError;
            const slice = in.data[0..h.size];
            in.data = in.data[h.size..];
            // Match `mp.decode` behaviour: if the payload parses as a single
            // integer, unwrap it into `.int` for the Neovim handle convention.
            var probe = mps.InnerDecoder{ .data = slice };
            if (probe.readHead()) |ph| {
                switch (ph) {
                    .Int => |iv| if (probe.data.len == 0) break :blk .{ .int = iv },
                    .UInt => |uv| if (probe.data.len == 0 and uv <= std.math.maxInt(i64)) break :blk .{ .int = @intCast(uv) },
                    else => {},
                }
            } else |_| {}
            const owned = try alloc.dupe(u8, slice);
            break :blk .{ .ext = .{ .type_code = h.kind, .data = owned } };
        },
        .Array => |n| blk: {
            const items = try alloc.alloc(Value, n);
            var idx: usize = 0;
            while (idx < n) : (idx += 1) {
                items[idx] = try decodeFromStream(alloc, in);
            }
            break :blk .{ .arr = items };
        },
        .Map => |n| blk: {
            const pairs = try alloc.alloc(Pair, n);
            var idx: usize = 0;
            while (idx < n) : (idx += 1) {
                const k = try decodeFromStream(alloc, in);
                const v = try decodeFromStream(alloc, in);
                pairs[idx] = .{ .key = k, .val = v };
            }
            break :blk .{ .map = pairs };
        },
    };
}

const mps = @import("mpack_stream.zig");
