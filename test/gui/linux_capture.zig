// linux_capture.zig — capture the app's windows on Linux and read/write the
// image as binary PPM. Counterpart to macos_capture.zig.
//
// Capture runs grim over the window's region of the composited screen, at
// the output's scale. A window above the app (a notification) is captured
// too, as with any screen-region grab. Goldens are per-environment and
// gitignored, so PPM, which needs no codec, is the on-disk format here.
//
// Test-only code: heap allocation is fine here.

const std = @import("std");
const gui_io = @import("gui_io.zig");
const win = @import("linux_window.zig");

pub const supported = true;

pub const image_ext = ".ppm";

/// grim on PATH and a compositor that can name the windows.
pub fn hasScreenAccess() bool {
    if (!win.available()) return false;
    const r = std.process.run(std.heap.page_allocator, gui_io.io(), .{ .argv = &.{ "grim", "-h" } }) catch return false;
    std.heap.page_allocator.free(r.stdout);
    std.heap.page_allocator.free(r.stderr);
    return true;
}

/// A top-left region in logical px.
pub const Crop = struct { w_pt: f64, h_pt: f64 };

pub const Image = struct {
    w: u32,
    h: u32,
    rgba: []u8, // w*h*4, R,G,B,A order, top-down

    pub fn deinit(self: *Image, alloc: std.mem.Allocator) void {
        alloc.free(self.rgba);
        self.* = undefined;
    }
};

pub fn captureMainWindow(alloc: std.mem.Allocator, pid: i32, crop: ?Crop) !Image {
    const b = win.mainWindowBoundsForPid(pid) orelse return error.WindowNotFound;
    return grab(alloc, b, crop);
}

pub fn captureWindow(alloc: std.mem.Allocator, window_number: u32) !Image {
    const b = win.boundsOf(window_number) orelse return error.WindowNotFound;
    return grab(alloc, b, null);
}

fn grab(alloc: std.mem.Allocator, b: win.Bounds, crop: ?Crop) !Image {
    const w = if (crop) |c| @min(c.w_pt, b.w) else b.w;
    const h = if (crop) |c| @min(c.h_pt, b.h) else b.h;
    var geo_buf: [64]u8 = undefined;
    const geo = try std.fmt.bufPrint(&geo_buf, "{d:.0},{d:.0} {d:.0}x{d:.0}", .{ b.x, b.y, w, h });
    const result = try std.process.run(alloc, gui_io.io(), .{
        .argv = &.{ "grim", "-t", "ppm", "-g", geo, "-" },
        .stdout_limit = .limited(512 * 1024 * 1024),
    });
    defer alloc.free(result.stdout);
    defer alloc.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code != 0) return error.CaptureFailed,
        else => return error.CaptureFailed,
    }
    return decodePpm(alloc, result.stdout);
}

pub fn writeImage(alloc: std.mem.Allocator, path: []const u8, img: Image) !void {
    var header_buf: [64]u8 = undefined;
    const header = try std.fmt.bufPrint(&header_buf, "P6\n{d} {d}\n255\n", .{ img.w, img.h });
    const n = @as(usize, img.w) * img.h;
    const buf = try alloc.alloc(u8, header.len + n * 3);
    defer alloc.free(buf);
    @memcpy(buf[0..header.len], header);
    for (0..n) |i| @memcpy(buf[header.len + i * 3 ..][0..3], img.rgba[i * 4 ..][0..3]);
    try std.Io.Dir.cwd().writeFile(gui_io.io(), .{ .sub_path = path, .data = buf });
}

pub fn readImage(alloc: std.mem.Allocator, path: []const u8) !Image {
    const data = try std.Io.Dir.cwd().readFileAlloc(gui_io.io(), path, alloc, .limited(512 * 1024 * 1024));
    defer alloc.free(data);
    return decodePpm(alloc, data);
}

/// Binary PPM (P6, maxval 255), as grim writes it.
fn decodePpm(alloc: std.mem.Allocator, data: []const u8) !Image {
    var pos: usize = 0;
    var fields: [4]u32 = undefined;
    var nf: usize = 0;
    while (nf < 4) {
        while (pos < data.len and (std.ascii.isWhitespace(data[pos]) or data[pos] == '#')) {
            if (data[pos] == '#') {
                while (pos < data.len and data[pos] != '\n') pos += 1;
            } else pos += 1;
        }
        const start = pos;
        while (pos < data.len and !std.ascii.isWhitespace(data[pos])) pos += 1;
        const tok = data[start..pos];
        if (nf == 0) {
            if (!std.mem.eql(u8, tok, "P6")) return error.BadPpm;
            fields[0] = 0;
        } else fields[nf] = std.fmt.parseInt(u32, tok, 10) catch return error.BadPpm;
        nf += 1;
    }
    pos += 1; // the single whitespace before the raster
    const w = fields[1];
    const h = fields[2];
    if (fields[3] != 255) return error.UnsupportedPpm;
    const n = @as(usize, w) * h;
    if (data.len < pos + n * 3) return error.TruncatedPpm;
    const rgba = try alloc.alloc(u8, n * 4);
    for (0..n) |i| {
        @memcpy(rgba[i * 4 ..][0..3], data[pos + i * 3 ..][0..3]);
        rgba[i * 4 + 3] = 255;
    }
    return .{ .w = w, .h = h, .rgba = rgba };
}

test "a PPM round-trips through decode" {
    const alloc = std.testing.allocator;
    const ppm = "P6\n# c\n2 1\n255\n" ++ "\x01\x02\x03\x04\x05\x06";
    var img = try decodePpm(alloc, ppm);
    defer img.deinit(alloc);
    try std.testing.expectEqual(@as(u32, 2), img.w);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 255, 4, 5, 6, 255 }, img.rgba);
}
