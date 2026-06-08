// windows_capture.zig — placeholder for the Windows screenshot layer.
//
// Mirrors macos_capture.zig's API so visual.zig compiles on Windows, but
// capture is not implemented yet (`supported = false`). Visual scenarios
// skip on Windows until this is built with WIC (window BitBlt/PrintWindow
// + PNG encode/decode via the Windows Imaging Component).

const std = @import("std");

pub const supported = false;

pub fn hasScreenAccess() bool {
    return true; // no per-process capture permission gate on Windows
}

pub const Image = struct {
    w: u32,
    h: u32,
    rgba: []u8,

    pub fn deinit(self: *Image, alloc: std.mem.Allocator) void {
        alloc.free(self.rgba);
        self.* = undefined;
    }
};

pub const Crop = struct { w_pt: f64, h_pt: f64 };

pub fn captureMainWindow(alloc: std.mem.Allocator, pid: i32, crop: ?Crop) !Image {
    _ = alloc;
    _ = pid;
    _ = crop;
    return error.Unsupported;
}

pub fn readPng(alloc: std.mem.Allocator, path: []const u8) !Image {
    _ = alloc;
    _ = path;
    return error.Unsupported;
}

pub fn writePng(path: []const u8, img: Image) !void {
    _ = path;
    _ = img;
    return error.Unsupported;
}
