// macos_capture.zig — capture a window's pixels and read/write PNG, using
// CoreGraphics + ImageIO (all C APIs, no Objective-C messaging). Strictly
// read-only with respect to the app: it captures on-screen pixels by
// window id and never touches the window.
//
// Capture is at device (Retina) resolution; goldens are therefore
// pixel-exact for the machine that generated them. Cross-machine /
// cross-OS comparison is not meaningful (DPI + font rendering differ) —
// goldens are per-environment, regenerated via ZONVIE_GUI_UPDATE_GOLDEN.

const std = @import("std");
const win = @import("macos_window.zig");

const CGImageRef = ?*anyopaque;
const CGContextRef = ?*anyopaque;
const CGColorSpaceRef = ?*anyopaque;
const CFURLRef = ?*anyopaque;
const CFStringRef = ?*anyopaque;
const CGImageDestinationRef = ?*anyopaque;
const CGImageSourceRef = ?*anyopaque;

const CGPoint = extern struct { x: f64, y: f64 };
const CGSize = extern struct { w: f64, h: f64 };
const CGRect = extern struct { origin: CGPoint, size: CGSize };

extern const CGRectNull: CGRect;

// Capture
extern "c" fn CGWindowListCreateImage(rect: CGRect, listOption: u32, windowID: u32, imageOption: u32) CGImageRef;
extern "c" fn CGImageGetWidth(img: CGImageRef) usize;
extern "c" fn CGImageGetHeight(img: CGImageRef) usize;
extern "c" fn CGImageRelease(img: CGImageRef) void;

// RGBA extraction via a bitmap context
extern "c" fn CGColorSpaceCreateDeviceRGB() CGColorSpaceRef;
extern "c" fn CGColorSpaceRelease(space: CGColorSpaceRef) void;
extern "c" fn CGBitmapContextCreate(data: ?*anyopaque, w: usize, h: usize, bpc: usize, bytesPerRow: usize, space: CGColorSpaceRef, bitmapInfo: u32) CGContextRef;
extern "c" fn CGBitmapContextCreateImage(ctx: CGContextRef) CGImageRef;
extern "c" fn CGContextDrawImage(ctx: CGContextRef, rect: CGRect, img: CGImageRef) void;
extern "c" fn CGContextRelease(ctx: CGContextRef) void;

// PNG via ImageIO
extern "c" fn CFStringCreateWithCString(alloc: ?*anyopaque, cstr: [*:0]const u8, encoding: u32) CFStringRef;
extern "c" fn CFURLCreateFromFileSystemRepresentation(alloc: ?*anyopaque, path: [*]const u8, len: isize, isDir: bool) CFURLRef;
extern "c" fn CFRelease(cf: *anyopaque) void;
extern "c" fn CGImageDestinationCreateWithURL(url: CFURLRef, type: CFStringRef, count: usize, options: ?*anyopaque) CGImageDestinationRef;
extern "c" fn CGImageDestinationAddImage(dest: CGImageDestinationRef, img: CGImageRef, props: ?*anyopaque) void;
extern "c" fn CGImageDestinationFinalize(dest: CGImageDestinationRef) bool;
extern "c" fn CGImageSourceCreateWithURL(url: CFURLRef, options: ?*anyopaque) CGImageSourceRef;
extern "c" fn CGImageSourceCreateImageAtIndex(src: CGImageSourceRef, index: usize, options: ?*anyopaque) CGImageRef;

// Screen Recording permission (macOS 10.15+). Preflight does NOT prompt.
extern "c" fn CGPreflightScreenCaptureAccess() bool;

const kCFStringEncodingUTF8: u32 = 0x08000100;
const kCGImageAlphaPremultipliedLast: u32 = 1;
const kCGWindowListOptionIncludingWindow: u32 = 1 << 3;
const kCGWindowImageBoundsIgnoreFraming: u32 = 1 << 0;

pub const supported = true;

/// True when the host process holds Screen Recording permission. Capturing
/// another process's window requires it on macOS 10.15+; without it
/// CGWindowListCreateImage yields no window content. Does not prompt.
pub fn hasScreenAccess() bool {
    return CGPreflightScreenCaptureAccess();
}

pub const Image = struct {
    w: u32,
    h: u32,
    rgba: []u8, // w*h*4, owned by the caller's allocator

    pub fn deinit(self: *Image, alloc: std.mem.Allocator) void {
        alloc.free(self.rgba);
        self.* = undefined;
    }
};

/// A fixed-size region (in points) anchored at the window's top-left.
/// Capturing a fixed top-left crop makes the output dimensions independent
/// of total window-height jitter — text renders from the top-left, so the
/// crop is deterministic where naive full-window capture is not.
pub const Crop = struct { w_pt: f64, h_pt: f64 };

/// Draw a CGImage into a fresh RGBA8 buffer (premultiplied, R,G,B,A order).
fn cgImageToRGBA(alloc: std.mem.Allocator, img: CGImageRef) !Image {
    const w = CGImageGetWidth(img);
    const h = CGImageGetHeight(img);
    if (w == 0 or h == 0) return error.EmptyImage;

    const rgba = try alloc.alloc(u8, w * h * 4);
    errdefer alloc.free(rgba);
    @memset(rgba, 0);

    const space = CGColorSpaceCreateDeviceRGB() orelse return error.ColorSpaceFailed;
    defer CGColorSpaceRelease(space);
    const ctx = CGBitmapContextCreate(rgba.ptr, w, h, 8, w * 4, space, kCGImageAlphaPremultipliedLast) orelse return error.ContextFailed;
    defer CGContextRelease(ctx);

    CGContextDrawImage(ctx, .{ .origin = .{ .x = 0, .y = 0 }, .size = .{ .w = @floatFromInt(w), .h = @floatFromInt(h) } }, img);

    return .{ .w = @intCast(w), .h = @intCast(h), .rgba = rgba };
}

/// Capture the app's main window by its CGWindowID (occlusion-independent).
/// With `crop`, capture only a fixed top-left region (deterministic size);
/// otherwise the whole window.
pub fn captureMainWindow(alloc: std.mem.Allocator, pid: i32, crop: ?Crop) !Image {
    if (!hasScreenAccess()) return error.ScreenRecordingPermission;
    const mw = win.mainWindowForPid(pid) orelse return error.NoMainWindow;
    const rect: CGRect = if (crop) |c|
        .{ .origin = .{ .x = mw.bounds.x, .y = mw.bounds.y }, .size = .{ .w = c.w_pt, .h = c.h_pt } }
    else
        CGRectNull;
    const img = CGWindowListCreateImage(
        rect,
        kCGWindowListOptionIncludingWindow,
        mw.number,
        kCGWindowImageBoundsIgnoreFraming,
    ) orelse return error.CaptureFailed;
    defer CGImageRelease(img);
    return cgImageToRGBA(alloc, img);
}

fn rgbaToCGImage(img: Image) !CGImageRef {
    const space = CGColorSpaceCreateDeviceRGB() orelse return error.ColorSpaceFailed;
    defer CGColorSpaceRelease(space);
    const ctx = CGBitmapContextCreate(img.rgba.ptr, img.w, img.h, 8, @as(usize, img.w) * 4, space, kCGImageAlphaPremultipliedLast) orelse return error.ContextFailed;
    defer CGContextRelease(ctx);
    return CGBitmapContextCreateImage(ctx) orelse error.ImageFromContextFailed;
}

/// Write an RGBA image to `path` as PNG.
pub fn writePng(path: []const u8, img: Image) !void {
    const cg = try rgbaToCGImage(img);
    defer CGImageRelease(cg);

    const url = CFURLCreateFromFileSystemRepresentation(null, path.ptr, @intCast(path.len), false) orelse return error.UrlFailed;
    defer CFRelease(url);
    const png_type = CFStringCreateWithCString(null, "public.png", kCFStringEncodingUTF8) orelse return error.TypeFailed;
    defer CFRelease(png_type);

    const dest = CGImageDestinationCreateWithURL(url, png_type, 1, null) orelse return error.DestFailed;
    defer CFRelease(dest);
    CGImageDestinationAddImage(dest, cg, null);
    if (!CGImageDestinationFinalize(dest)) return error.FinalizeFailed;
}

/// Read a PNG at `path` into an RGBA image.
pub fn readPng(alloc: std.mem.Allocator, path: []const u8) !Image {
    const url = CFURLCreateFromFileSystemRepresentation(null, path.ptr, @intCast(path.len), false) orelse return error.UrlFailed;
    defer CFRelease(url);
    const src = CGImageSourceCreateWithURL(url, null) orelse return error.SourceFailed;
    defer CFRelease(src);
    const img = CGImageSourceCreateImageAtIndex(src, 0, null) orelse return error.DecodeFailed;
    defer CGImageRelease(img);
    return cgImageToRGBA(alloc, img);
}
