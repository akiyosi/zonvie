// MessagePack encoding/decoding tests for Zonvie.
// Tests the rpc_encode.zig (pack*) and msgpack.zig (decode) functions.

const std = @import("std");
const mp = @import("zonvie_core").msgpack;
const rpc = @import("zonvie_core").rpc_encode;

// ============================================================================
// Test Helpers
// ============================================================================

fn decodeFromSlice(alloc: std.mem.Allocator, data: []const u8) !mp.Value {
    var reader = SliceReader{ .data = data };
    return mp.decode(alloc, &reader);
}

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

// ============================================================================
// Encoding Tests: packNil
// ============================================================================

test "encode nil" {
    var buf: rpc.Buf = .empty;
    defer buf.deinit(std.testing.allocator);

    try rpc.packNil(&buf, std.testing.allocator);

    try std.testing.expectEqualSlices(u8, &[_]u8{0xc0}, buf.items);
}

// ============================================================================
// Encoding Tests: packBool
// ============================================================================

test "encode bool false" {
    var buf: rpc.Buf = .empty;
    defer buf.deinit(std.testing.allocator);

    try rpc.packBool(&buf, std.testing.allocator, false);

    try std.testing.expectEqualSlices(u8, &[_]u8{0xc2}, buf.items);
}

test "encode bool true" {
    var buf: rpc.Buf = .empty;
    defer buf.deinit(std.testing.allocator);

    try rpc.packBool(&buf, std.testing.allocator, true);

    try std.testing.expectEqualSlices(u8, &[_]u8{0xc3}, buf.items);
}

// ============================================================================
// Encoding Tests: packInt
// ============================================================================

test "encode positive fixint 0" {
    var buf: rpc.Buf = .empty;
    defer buf.deinit(std.testing.allocator);

    try rpc.packInt(&buf, std.testing.allocator, 0);

    try std.testing.expectEqualSlices(u8, &[_]u8{0x00}, buf.items);
}

test "encode positive fixint 127" {
    var buf: rpc.Buf = .empty;
    defer buf.deinit(std.testing.allocator);

    try rpc.packInt(&buf, std.testing.allocator, 127);

    try std.testing.expectEqualSlices(u8, &[_]u8{0x7f}, buf.items);
}

test "encode negative fixint -1" {
    var buf: rpc.Buf = .empty;
    defer buf.deinit(std.testing.allocator);

    try rpc.packInt(&buf, std.testing.allocator, -1);

    try std.testing.expectEqualSlices(u8, &[_]u8{0xff}, buf.items);
}

test "encode negative fixint -32" {
    var buf: rpc.Buf = .empty;
    defer buf.deinit(std.testing.allocator);

    try rpc.packInt(&buf, std.testing.allocator, -32);

    try std.testing.expectEqualSlices(u8, &[_]u8{0xe0}, buf.items);
}

test "encode uint8 128" {
    var buf: rpc.Buf = .empty;
    defer buf.deinit(std.testing.allocator);

    try rpc.packInt(&buf, std.testing.allocator, 128);

    try std.testing.expectEqualSlices(u8, &[_]u8{ 0xcc, 0x80 }, buf.items);
}

test "encode uint8 255" {
    var buf: rpc.Buf = .empty;
    defer buf.deinit(std.testing.allocator);

    try rpc.packInt(&buf, std.testing.allocator, 255);

    try std.testing.expectEqualSlices(u8, &[_]u8{ 0xcc, 0xff }, buf.items);
}

test "encode uint16 256" {
    var buf: rpc.Buf = .empty;
    defer buf.deinit(std.testing.allocator);

    try rpc.packInt(&buf, std.testing.allocator, 256);

    try std.testing.expectEqualSlices(u8, &[_]u8{ 0xcd, 0x01, 0x00 }, buf.items);
}

test "encode uint16 65535" {
    var buf: rpc.Buf = .empty;
    defer buf.deinit(std.testing.allocator);

    try rpc.packInt(&buf, std.testing.allocator, 65535);

    try std.testing.expectEqualSlices(u8, &[_]u8{ 0xcd, 0xff, 0xff }, buf.items);
}

test "encode uint32 65536" {
    var buf: rpc.Buf = .empty;
    defer buf.deinit(std.testing.allocator);

    try rpc.packInt(&buf, std.testing.allocator, 65536);

    try std.testing.expectEqualSlices(u8, &[_]u8{ 0xce, 0x00, 0x01, 0x00, 0x00 }, buf.items);
}

test "encode uint64 large" {
    var buf: rpc.Buf = .empty;
    defer buf.deinit(std.testing.allocator);

    try rpc.packInt(&buf, std.testing.allocator, 0x100000000);

    try std.testing.expectEqualSlices(u8, &[_]u8{ 0xcf, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00 }, buf.items);
}

test "encode int8 -33" {
    var buf: rpc.Buf = .empty;
    defer buf.deinit(std.testing.allocator);

    try rpc.packInt(&buf, std.testing.allocator, -33);

    try std.testing.expectEqualSlices(u8, &[_]u8{ 0xd0, 0xdf }, buf.items);
}

test "encode int8 -128" {
    var buf: rpc.Buf = .empty;
    defer buf.deinit(std.testing.allocator);

    try rpc.packInt(&buf, std.testing.allocator, -128);

    try std.testing.expectEqualSlices(u8, &[_]u8{ 0xd0, 0x80 }, buf.items);
}

test "encode int16 -129" {
    var buf: rpc.Buf = .empty;
    defer buf.deinit(std.testing.allocator);

    try rpc.packInt(&buf, std.testing.allocator, -129);

    try std.testing.expectEqualSlices(u8, &[_]u8{ 0xd1, 0xff, 0x7f }, buf.items);
}

test "encode int32 -32769" {
    var buf: rpc.Buf = .empty;
    defer buf.deinit(std.testing.allocator);

    try rpc.packInt(&buf, std.testing.allocator, -32769);

    try std.testing.expectEqualSlices(u8, &[_]u8{ 0xd2, 0xff, 0xff, 0x7f, 0xff }, buf.items);
}

// ============================================================================
// Encoding Tests: packStr
// ============================================================================

test "encode empty string" {
    var buf: rpc.Buf = .empty;
    defer buf.deinit(std.testing.allocator);

    try rpc.packStr(&buf, std.testing.allocator, "");

    try std.testing.expectEqualSlices(u8, &[_]u8{0xa0}, buf.items);
}

test "encode fixstr hello" {
    var buf: rpc.Buf = .empty;
    defer buf.deinit(std.testing.allocator);

    try rpc.packStr(&buf, std.testing.allocator, "hello");

    try std.testing.expectEqualSlices(u8, &[_]u8{ 0xa5, 'h', 'e', 'l', 'l', 'o' }, buf.items);
}

test "encode fixstr max length 31" {
    var buf: rpc.Buf = .empty;
    defer buf.deinit(std.testing.allocator);

    const s = "1234567890123456789012345678901"; // 31 chars
    try rpc.packStr(&buf, std.testing.allocator, s);

    try std.testing.expectEqual(@as(u8, 0xa0 | 31), buf.items[0]);
    try std.testing.expectEqualStrings(s, buf.items[1..]);
}

test "encode str8 32 bytes" {
    var buf: rpc.Buf = .empty;
    defer buf.deinit(std.testing.allocator);

    const s = "12345678901234567890123456789012"; // 32 chars
    try rpc.packStr(&buf, std.testing.allocator, s);

    try std.testing.expectEqual(@as(u8, 0xd9), buf.items[0]);
    try std.testing.expectEqual(@as(u8, 32), buf.items[1]);
    try std.testing.expectEqualStrings(s, buf.items[2..]);
}

test "encode UTF-8 string" {
    var buf: rpc.Buf = .empty;
    defer buf.deinit(std.testing.allocator);

    try rpc.packStr(&buf, std.testing.allocator, "日本語");

    // "日本語" is 9 bytes in UTF-8
    try std.testing.expectEqual(@as(u8, 0xa9), buf.items[0]);
    try std.testing.expectEqualStrings("日本語", buf.items[1..]);
}

// ============================================================================
// Encoding Tests: packArray
// ============================================================================

test "encode fixarray empty" {
    var buf: rpc.Buf = .empty;
    defer buf.deinit(std.testing.allocator);

    try rpc.packArray(&buf, std.testing.allocator, 0);

    try std.testing.expectEqualSlices(u8, &[_]u8{0x90}, buf.items);
}

test "encode fixarray 15 elements" {
    var buf: rpc.Buf = .empty;
    defer buf.deinit(std.testing.allocator);

    try rpc.packArray(&buf, std.testing.allocator, 15);

    try std.testing.expectEqualSlices(u8, &[_]u8{0x9f}, buf.items);
}

test "encode array16 16 elements" {
    var buf: rpc.Buf = .empty;
    defer buf.deinit(std.testing.allocator);

    try rpc.packArray(&buf, std.testing.allocator, 16);

    try std.testing.expectEqualSlices(u8, &[_]u8{ 0xdc, 0x00, 0x10 }, buf.items);
}

// ============================================================================
// Encoding Tests: packMap
// ============================================================================

test "encode fixmap empty" {
    var buf: rpc.Buf = .empty;
    defer buf.deinit(std.testing.allocator);

    try rpc.packMap(&buf, std.testing.allocator, 0);

    try std.testing.expectEqualSlices(u8, &[_]u8{0x80}, buf.items);
}

test "encode fixmap 15 pairs" {
    var buf: rpc.Buf = .empty;
    defer buf.deinit(std.testing.allocator);

    try rpc.packMap(&buf, std.testing.allocator, 15);

    try std.testing.expectEqualSlices(u8, &[_]u8{0x8f}, buf.items);
}

test "encode map16 16 pairs" {
    var buf: rpc.Buf = .empty;
    defer buf.deinit(std.testing.allocator);

    try rpc.packMap(&buf, std.testing.allocator, 16);

    try std.testing.expectEqualSlices(u8, &[_]u8{ 0xde, 0x00, 0x10 }, buf.items);
}

// ============================================================================
// Decoding Tests: nil
// ============================================================================

test "decode nil" {
    const data = [_]u8{0xc0};
    const val = try decodeFromSlice(std.testing.allocator, &data);

    try std.testing.expect(val == .nil);
}

// ============================================================================
// Decoding Tests: bool
// ============================================================================

test "decode bool false" {
    const data = [_]u8{0xc2};
    const val = try decodeFromSlice(std.testing.allocator, &data);

    try std.testing.expect(val == .bool);
    try std.testing.expectEqual(false, val.bool);
}

test "decode bool true" {
    const data = [_]u8{0xc3};
    const val = try decodeFromSlice(std.testing.allocator, &data);

    try std.testing.expect(val == .bool);
    try std.testing.expectEqual(true, val.bool);
}

// ============================================================================
// Decoding Tests: int
// ============================================================================

test "decode positive fixint 0" {
    const data = [_]u8{0x00};
    const val = try decodeFromSlice(std.testing.allocator, &data);

    try std.testing.expect(val == .int);
    try std.testing.expectEqual(@as(i64, 0), val.int);
}

test "decode positive fixint 127" {
    const data = [_]u8{0x7f};
    const val = try decodeFromSlice(std.testing.allocator, &data);

    try std.testing.expect(val == .int);
    try std.testing.expectEqual(@as(i64, 127), val.int);
}

test "decode negative fixint -1" {
    const data = [_]u8{0xff};
    const val = try decodeFromSlice(std.testing.allocator, &data);

    try std.testing.expect(val == .int);
    try std.testing.expectEqual(@as(i64, -1), val.int);
}

test "decode negative fixint -32" {
    const data = [_]u8{0xe0};
    const val = try decodeFromSlice(std.testing.allocator, &data);

    try std.testing.expect(val == .int);
    try std.testing.expectEqual(@as(i64, -32), val.int);
}

test "decode uint8" {
    const data = [_]u8{ 0xcc, 0xff };
    const val = try decodeFromSlice(std.testing.allocator, &data);

    try std.testing.expect(val == .int);
    try std.testing.expectEqual(@as(i64, 255), val.int);
}

test "decode uint16" {
    const data = [_]u8{ 0xcd, 0x01, 0x00 };
    const val = try decodeFromSlice(std.testing.allocator, &data);

    try std.testing.expect(val == .int);
    try std.testing.expectEqual(@as(i64, 256), val.int);
}

test "decode uint32" {
    const data = [_]u8{ 0xce, 0x00, 0x01, 0x00, 0x00 };
    const val = try decodeFromSlice(std.testing.allocator, &data);

    try std.testing.expect(val == .int);
    try std.testing.expectEqual(@as(i64, 65536), val.int);
}

test "decode int8" {
    const data = [_]u8{ 0xd0, 0x80 };
    const val = try decodeFromSlice(std.testing.allocator, &data);

    try std.testing.expect(val == .int);
    try std.testing.expectEqual(@as(i64, -128), val.int);
}

test "decode int16" {
    const data = [_]u8{ 0xd1, 0xff, 0x7f };
    const val = try decodeFromSlice(std.testing.allocator, &data);

    try std.testing.expect(val == .int);
    try std.testing.expectEqual(@as(i64, -129), val.int);
}

// ============================================================================
// Decoding Tests: float
// ============================================================================

test "decode float32" {
    // 3.14 as float32: 0x4048f5c3
    const data = [_]u8{ 0xca, 0x40, 0x48, 0xf5, 0xc3 };
    const val = try decodeFromSlice(std.testing.allocator, &data);

    try std.testing.expect(val == .float);
    try std.testing.expectApproxEqAbs(@as(f64, 3.14), val.float, 0.001);
}

test "decode float64" {
    // 3.141592653589793 as float64
    const data = [_]u8{ 0xcb, 0x40, 0x09, 0x21, 0xfb, 0x54, 0x44, 0x2d, 0x18 };
    const val = try decodeFromSlice(std.testing.allocator, &data);

    try std.testing.expect(val == .float);
    try std.testing.expectApproxEqAbs(@as(f64, 3.141592653589793), val.float, 0.0000001);
}

// ============================================================================
// Decoding Tests: str
// ============================================================================

test "decode empty fixstr" {
    const data = [_]u8{0xa0};
    const val = try decodeFromSlice(std.testing.allocator, &data);
    defer mp.freeValue(std.testing.allocator, val);

    try std.testing.expect(val == .str);
    try std.testing.expectEqualStrings("", val.str);
}

test "decode fixstr hello" {
    const data = [_]u8{ 0xa5, 'h', 'e', 'l', 'l', 'o' };
    const val = try decodeFromSlice(std.testing.allocator, &data);
    defer mp.freeValue(std.testing.allocator, val);

    try std.testing.expect(val == .str);
    try std.testing.expectEqualStrings("hello", val.str);
}

test "decode str8" {
    var data: [34]u8 = undefined;
    data[0] = 0xd9;
    data[1] = 32;
    @memset(data[2..], 'x');

    const val = try decodeFromSlice(std.testing.allocator, &data);
    defer mp.freeValue(std.testing.allocator, val);

    try std.testing.expect(val == .str);
    try std.testing.expectEqual(@as(usize, 32), val.str.len);
}

// ============================================================================
// Decoding Tests: bin (stored as str)
// ============================================================================

test "decode bin8" {
    const data = [_]u8{ 0xc4, 0x03, 0x01, 0x02, 0x03 };
    const val = try decodeFromSlice(std.testing.allocator, &data);
    defer mp.freeValue(std.testing.allocator, val);

    try std.testing.expect(val == .str);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x01, 0x02, 0x03 }, val.str);
}

// ============================================================================
// Decoding Tests: array
// ============================================================================

test "decode empty fixarray" {
    const data = [_]u8{0x90};
    const val = try decodeFromSlice(std.testing.allocator, &data);
    defer mp.freeValue(std.testing.allocator, val);

    try std.testing.expect(val == .arr);
    try std.testing.expectEqual(@as(usize, 0), val.arr.len);
}

test "decode fixarray with integers" {
    // [1, 2, 3]
    const data = [_]u8{ 0x93, 0x01, 0x02, 0x03 };
    const val = try decodeFromSlice(std.testing.allocator, &data);
    defer mp.freeValue(std.testing.allocator, val);

    try std.testing.expect(val == .arr);
    try std.testing.expectEqual(@as(usize, 3), val.arr.len);
    try std.testing.expectEqual(@as(i64, 1), val.arr[0].int);
    try std.testing.expectEqual(@as(i64, 2), val.arr[1].int);
    try std.testing.expectEqual(@as(i64, 3), val.arr[2].int);
}

test "decode nested array" {
    // [[1, 2], [3, 4]]
    const data = [_]u8{ 0x92, 0x92, 0x01, 0x02, 0x92, 0x03, 0x04 };
    const val = try decodeFromSlice(std.testing.allocator, &data);
    defer mp.freeValue(std.testing.allocator, val);

    try std.testing.expect(val == .arr);
    try std.testing.expectEqual(@as(usize, 2), val.arr.len);
    try std.testing.expectEqual(@as(usize, 2), val.arr[0].arr.len);
    try std.testing.expectEqual(@as(i64, 1), val.arr[0].arr[0].int);
}

// ============================================================================
// Decoding Tests: map
// ============================================================================

test "decode empty fixmap" {
    const data = [_]u8{0x80};
    const val = try decodeFromSlice(std.testing.allocator, &data);
    defer mp.freeValue(std.testing.allocator, val);

    try std.testing.expect(val == .map);
    try std.testing.expectEqual(@as(usize, 0), val.map.len);
}

test "decode fixmap with string keys" {
    // {"a": 1}
    const data = [_]u8{ 0x81, 0xa1, 'a', 0x01 };
    const val = try decodeFromSlice(std.testing.allocator, &data);
    defer mp.freeValue(std.testing.allocator, val);

    try std.testing.expect(val == .map);
    try std.testing.expectEqual(@as(usize, 1), val.map.len);
    try std.testing.expectEqualStrings("a", val.map[0].key.str);
    try std.testing.expectEqual(@as(i64, 1), val.map[0].val.int);
}

// ============================================================================
// Decoding Tests: ext (Neovim handles)
// ============================================================================

test "decode fixext1 as integer" {
    // fixext1 with type=0 and data=0x2a (42)
    const data = [_]u8{ 0xd4, 0x00, 0x2a };
    const val = try decodeFromSlice(std.testing.allocator, &data);

    // ext with single-byte integer payload is decoded as .int
    try std.testing.expect(val == .int);
    try std.testing.expectEqual(@as(i64, 42), val.int);
}

// ============================================================================
// Round-trip Tests: encode then decode
// ============================================================================

test "roundtrip nil" {
    var buf: rpc.Buf = .empty;
    defer buf.deinit(std.testing.allocator);

    try rpc.packNil(&buf, std.testing.allocator);

    const val = try decodeFromSlice(std.testing.allocator, buf.items);
    try std.testing.expect(val == .nil);
}

test "roundtrip bool true" {
    var buf: rpc.Buf = .empty;
    defer buf.deinit(std.testing.allocator);

    try rpc.packBool(&buf, std.testing.allocator, true);

    const val = try decodeFromSlice(std.testing.allocator, buf.items);
    try std.testing.expect(val == .bool);
    try std.testing.expectEqual(true, val.bool);
}

test "roundtrip bool false" {
    var buf: rpc.Buf = .empty;
    defer buf.deinit(std.testing.allocator);

    try rpc.packBool(&buf, std.testing.allocator, false);

    const val = try decodeFromSlice(std.testing.allocator, buf.items);
    try std.testing.expect(val == .bool);
    try std.testing.expectEqual(false, val.bool);
}

test "roundtrip positive int" {
    var buf: rpc.Buf = .empty;
    defer buf.deinit(std.testing.allocator);

    try rpc.packInt(&buf, std.testing.allocator, 12345);

    const val = try decodeFromSlice(std.testing.allocator, buf.items);
    try std.testing.expect(val == .int);
    try std.testing.expectEqual(@as(i64, 12345), val.int);
}

test "roundtrip negative int" {
    var buf: rpc.Buf = .empty;
    defer buf.deinit(std.testing.allocator);

    try rpc.packInt(&buf, std.testing.allocator, -9999);

    const val = try decodeFromSlice(std.testing.allocator, buf.items);
    try std.testing.expect(val == .int);
    try std.testing.expectEqual(@as(i64, -9999), val.int);
}

test "roundtrip string" {
    var buf: rpc.Buf = .empty;
    defer buf.deinit(std.testing.allocator);

    try rpc.packStr(&buf, std.testing.allocator, "Hello, 世界!");

    const val = try decodeFromSlice(std.testing.allocator, buf.items);
    defer mp.freeValue(std.testing.allocator, val);

    try std.testing.expect(val == .str);
    try std.testing.expectEqualStrings("Hello, 世界!", val.str);
}

test "roundtrip array of integers" {
    var buf: rpc.Buf = .empty;
    defer buf.deinit(std.testing.allocator);

    try rpc.packArray(&buf, std.testing.allocator, 3);
    try rpc.packInt(&buf, std.testing.allocator, 10);
    try rpc.packInt(&buf, std.testing.allocator, 20);
    try rpc.packInt(&buf, std.testing.allocator, 30);

    const val = try decodeFromSlice(std.testing.allocator, buf.items);
    defer mp.freeValue(std.testing.allocator, val);

    try std.testing.expect(val == .arr);
    try std.testing.expectEqual(@as(usize, 3), val.arr.len);
    try std.testing.expectEqual(@as(i64, 10), val.arr[0].int);
    try std.testing.expectEqual(@as(i64, 20), val.arr[1].int);
    try std.testing.expectEqual(@as(i64, 30), val.arr[2].int);
}

test "roundtrip map" {
    var buf: rpc.Buf = .empty;
    defer buf.deinit(std.testing.allocator);

    try rpc.packMap(&buf, std.testing.allocator, 2);
    try rpc.packStr(&buf, std.testing.allocator, "key1");
    try rpc.packInt(&buf, std.testing.allocator, 100);
    try rpc.packStr(&buf, std.testing.allocator, "key2");
    try rpc.packStr(&buf, std.testing.allocator, "value2");

    const val = try decodeFromSlice(std.testing.allocator, buf.items);
    defer mp.freeValue(std.testing.allocator, val);

    try std.testing.expect(val == .map);
    try std.testing.expectEqual(@as(usize, 2), val.map.len);
    try std.testing.expectEqualStrings("key1", val.map[0].key.str);
    try std.testing.expectEqual(@as(i64, 100), val.map[0].val.int);
    try std.testing.expectEqualStrings("key2", val.map[1].key.str);
    try std.testing.expectEqualStrings("value2", val.map[1].val.str);
}

test "roundtrip RPC request structure" {
    // Simulate Neovim RPC request: [0, msgid, method, args]
    var buf: rpc.Buf = .empty;
    defer buf.deinit(std.testing.allocator);

    try rpc.packArray(&buf, std.testing.allocator, 4);
    try rpc.packInt(&buf, std.testing.allocator, 0); // type = request
    try rpc.packInt(&buf, std.testing.allocator, 42); // msgid
    try rpc.packStr(&buf, std.testing.allocator, "nvim_input"); // method
    try rpc.packArray(&buf, std.testing.allocator, 1); // args
    try rpc.packStr(&buf, std.testing.allocator, "<CR>"); // keys

    const val = try decodeFromSlice(std.testing.allocator, buf.items);
    defer mp.freeValue(std.testing.allocator, val);

    try std.testing.expect(val == .arr);
    try std.testing.expectEqual(@as(usize, 4), val.arr.len);
    try std.testing.expectEqual(@as(i64, 0), val.arr[0].int);
    try std.testing.expectEqual(@as(i64, 42), val.arr[1].int);
    try std.testing.expectEqualStrings("nvim_input", val.arr[2].str);
    try std.testing.expectEqual(@as(usize, 1), val.arr[3].arr.len);
    try std.testing.expectEqualStrings("<CR>", val.arr[3].arr[0].str);
}

// ============================================================================
// Edge Cases
// ============================================================================

test "decode non-UTF8 binary data" {
    // Binary data with invalid UTF-8 sequences (stored as .str)
    const data = [_]u8{ 0xc4, 0x04, 0xc3, 0x28, 0xff, 0xfe };
    const val = try decodeFromSlice(std.testing.allocator, &data);
    defer mp.freeValue(std.testing.allocator, val);

    try std.testing.expect(val == .str);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0xc3, 0x28, 0xff, 0xfe }, val.str);
}

test "encode large array header" {
    var buf: rpc.Buf = .empty;
    defer buf.deinit(std.testing.allocator);

    try rpc.packArray(&buf, std.testing.allocator, 1000);

    try std.testing.expectEqual(@as(u8, 0xdc), buf.items[0]); // array16
    try std.testing.expectEqual(@as(u8, 0x03), buf.items[1]);
    try std.testing.expectEqual(@as(u8, 0xe8), buf.items[2]); // 1000 = 0x03e8
}
