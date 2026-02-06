const std = @import("std");

pub const Buf = std.ArrayListUnmanaged(u8);

fn writeByte(buf: *Buf, alloc: std.mem.Allocator, b: u8) !void {
    try buf.append(alloc, b);
}

fn writeAll(buf: *Buf, alloc: std.mem.Allocator, bytes: []const u8) !void {
    try buf.appendSlice(alloc, bytes);
}

fn writeIntBig(buf: *Buf, alloc: std.mem.Allocator, comptime T: type, v: T) !void {
    var tmp: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, tmp[0..], v, .big);
    try writeAll(buf, alloc, &tmp);
}

pub fn packArray(buf: *Buf, alloc: std.mem.Allocator, n: usize) !void {
    if (n <= 15) {
        try writeByte(buf, alloc, @as(u8, 0x90) | @as(u8, @intCast(n)));
    } else if (n <= 0xffff) {
        try writeByte(buf, alloc, 0xdc);
        try writeIntBig(buf, alloc, u16, @intCast(n));
    } else {
        try writeByte(buf, alloc, 0xdd);
        try writeIntBig(buf, alloc, u32, @intCast(n));
    }
}

pub fn packMap(buf: *Buf, alloc: std.mem.Allocator, n: usize) !void {
    if (n <= 15) {
        try writeByte(buf, alloc, @as(u8, 0x80) | @as(u8, @intCast(n)));
    } else if (n <= 0xffff) {
        try writeByte(buf, alloc, 0xde);
        try writeIntBig(buf, alloc, u16, @intCast(n));
    } else {
        try writeByte(buf, alloc, 0xdf);
        try writeIntBig(buf, alloc, u32, @intCast(n));
    }
}

pub fn packBool(buf: *Buf, alloc: std.mem.Allocator, v: bool) !void {
    try writeByte(buf, alloc, if (v) 0xc3 else 0xc2);
}

pub fn packNil(buf: *Buf, alloc: std.mem.Allocator) !void {
    try writeByte(buf, alloc, 0xc0);
}

pub fn packInt(buf: *Buf, alloc: std.mem.Allocator, v: i64) !void {
    // Positive fixint
    if (v >= 0 and v <= 127) {
        try writeByte(buf, alloc, @as(u8, @intCast(v)));
        return;
    }
    // Negative fixint
    if (v >= -32 and v < 0) {
        const b: u8 = @bitCast(@as(i8, @intCast(v)));
        try writeByte(buf, alloc, b);
        return;
    }

    // Unsigned encodings (when v is non-negative)
    if (v >= 0) {
        const uv: u64 = @as(u64, @intCast(v));
        if (uv <= 0xff) {
            try writeByte(buf, alloc, 0xcc); // uint8
            try writeIntBig(buf, alloc, u8, @as(u8, @intCast(uv)));
            return;
        }
        if (uv <= 0xffff) {
            try writeByte(buf, alloc, 0xcd); // uint16
            try writeIntBig(buf, alloc, u16, @as(u16, @intCast(uv)));
            return;
        }
        if (uv <= 0xffff_ffff) {
            try writeByte(buf, alloc, 0xce); // uint32
            try writeIntBig(buf, alloc, u32, @as(u32, @intCast(uv)));
            return;
        }
        try writeByte(buf, alloc, 0xcf); // uint64
        try writeIntBig(buf, alloc, u64, uv);
        return;
    }

    // Signed encodings (v is negative and not in negative-fixint range)
    if (v >= std.math.minInt(i8) and v <= std.math.maxInt(i8)) {
        try writeByte(buf, alloc, 0xd0); // int8
        try writeIntBig(buf, alloc, i8, @as(i8, @intCast(v)));
        return;
    }
    if (v >= std.math.minInt(i16) and v <= std.math.maxInt(i16)) {
        try writeByte(buf, alloc, 0xd1); // int16
        try writeIntBig(buf, alloc, i16, @as(i16, @intCast(v)));
        return;
    }
    if (v >= std.math.minInt(i32) and v <= std.math.maxInt(i32)) {
        try writeByte(buf, alloc, 0xd2); // int32
        try writeIntBig(buf, alloc, i32, @as(i32, @intCast(v)));
        return;
    }

    // Full int64
    try writeByte(buf, alloc, 0xd3); // int64
    try writeIntBig(buf, alloc, i64, v);
}

pub fn packStr(buf: *Buf, alloc: std.mem.Allocator, s: []const u8) !void {
    if (s.len <= 31) {
        try writeByte(buf, alloc, @as(u8, 0xa0) | @as(u8, @intCast(s.len)));
    } else if (s.len <= 0xff) {
        try writeByte(buf, alloc, 0xd9);
        try writeByte(buf, alloc, @as(u8, @intCast(s.len)));
    } else if (s.len <= 0xffff) {
        try writeByte(buf, alloc, 0xda);
        try writeIntBig(buf, alloc, u16, @intCast(s.len));
    } else {
        try writeByte(buf, alloc, 0xdb);
        try writeIntBig(buf, alloc, u32, @intCast(s.len));
    }
    try writeAll(buf, alloc, s);
}
