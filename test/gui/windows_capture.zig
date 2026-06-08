// windows_capture.zig — capture the app's main window and read/write the
// image as BMP. Counterpart to macos_capture.zig.
//
// Capture uses PrintWindow(PW_RENDERFULLCONTENT), the standard way to grab
// a hardware-accelerated (D3D11 / DirectComposition) window's composited
// pixels into a GDI DC — plain BitBlt of such a window returns black.
//
// Image I/O is hand-rolled BMP (32bpp, uncompressed): no Windows Imaging
// Component / COM, which keeps this dependency-free and robust. Goldens are
// per-environment and gitignored, so the on-disk format is a local detail
// (macОС uses PNG, Windows uses BMP — selected via `image_ext`).
//
// RISK (cannot be verified from a macOS host — needs a real Windows run):
// some D3D swapchain configurations do not respond to PrintWindow and yield
// a black frame. If captured pixels come back all-black, the fallback is the
// DXGI Desktop Duplication API (heavier). Compile-verified only here.

const std = @import("std");
const W = std.os.windows;
const win = @import("windows_window.zig");

// GDI handle types not declared in std.os.windows.
const HDC = W.HDC;
const HBITMAP = W.HANDLE;
const HGDIOBJ = W.HANDLE;

extern "user32" fn GetWindowRect(hwnd: W.HWND, rect: *W.RECT) callconv(.winapi) W.BOOL;
extern "user32" fn GetDC(hwnd: ?W.HWND) callconv(.winapi) ?HDC;
extern "user32" fn ReleaseDC(hwnd: ?W.HWND, hdc: HDC) callconv(.winapi) i32;
extern "user32" fn PrintWindow(hwnd: W.HWND, hdc: HDC, flags: W.UINT) callconv(.winapi) W.BOOL;
extern "user32" fn GetDpiForWindow(hwnd: W.HWND) callconv(.winapi) W.UINT;

extern "gdi32" fn CreateCompatibleDC(hdc: ?HDC) callconv(.winapi) ?HDC;
extern "gdi32" fn DeleteDC(hdc: HDC) callconv(.winapi) W.BOOL;
extern "gdi32" fn CreateDIBSection(hdc: ?HDC, bmi: *const BITMAPINFO, usage: W.UINT, bits: *?*anyopaque, section: ?W.HANDLE, offset: W.DWORD) callconv(.winapi) ?HBITMAP;
extern "gdi32" fn SelectObject(hdc: HDC, obj: HGDIOBJ) callconv(.winapi) ?HGDIOBJ;
extern "gdi32" fn DeleteObject(obj: HGDIOBJ) callconv(.winapi) W.BOOL;

const BITMAPINFOHEADER = extern struct {
    biSize: W.DWORD,
    biWidth: i32,
    biHeight: i32,
    biPlanes: W.WORD,
    biBitCount: W.WORD,
    biCompression: W.DWORD,
    biSizeImage: W.DWORD,
    biXPelsPerMeter: i32,
    biYPelsPerMeter: i32,
    biClrUsed: W.DWORD,
    biClrImportant: W.DWORD,
};

const BITMAPINFO = extern struct {
    bmiHeader: BITMAPINFOHEADER,
    bmiColors: [1]u32 = .{0},
};

const PW_RENDERFULLCONTENT: W.UINT = 0x00000002;
const DIB_RGB_COLORS: W.UINT = 0;
const BI_RGB: W.DWORD = 0;

pub const supported = true;

/// On-disk format for goldens / dumps on this platform.
pub const image_ext = ".bmp";

pub fn hasScreenAccess() bool {
    return true; // no per-process capture permission gate on Windows
}

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

/// Capture the app's main window. With `crop`, keep only a fixed top-left
/// region (scaled by the window DPI, mirroring the macOS points behavior);
/// otherwise the whole window.
pub fn captureMainWindow(alloc: std.mem.Allocator, pid: i32, crop: ?Crop) !Image {
    const hwnd = win.mainWindowHandleForPid(pid) orelse return error.NoMainWindow;

    var rect: W.RECT = undefined;
    if (GetWindowRect(hwnd, &rect) == 0) return error.WindowRectFailed;
    const win_w: i32 = rect.right - rect.left;
    const win_h: i32 = rect.bottom - rect.top;
    if (win_w <= 0 or win_h <= 0) return error.EmptyWindow;

    // Top-down 32bpp DIB so the bits pointer is BGRA, row 0 first.
    var bmi = BITMAPINFO{ .bmiHeader = .{
        .biSize = @sizeOf(BITMAPINFOHEADER),
        .biWidth = win_w,
        .biHeight = -win_h, // negative => top-down
        .biPlanes = 1,
        .biBitCount = 32,
        .biCompression = BI_RGB,
        .biSizeImage = 0,
        .biXPelsPerMeter = 0,
        .biYPelsPerMeter = 0,
        .biClrUsed = 0,
        .biClrImportant = 0,
    } };

    const screen_dc = GetDC(null) orelse return error.GetDCFailed;
    defer _ = ReleaseDC(null, screen_dc);
    const mem_dc = CreateCompatibleDC(screen_dc) orelse return error.CreateDCFailed;
    defer _ = DeleteDC(mem_dc);

    var bits: ?*anyopaque = null;
    const hbm = CreateDIBSection(mem_dc, &bmi, DIB_RGB_COLORS, &bits, null, 0) orelse return error.DIBFailed;
    defer _ = DeleteObject(hbm);
    const old = SelectObject(mem_dc, hbm);
    defer _ = SelectObject(mem_dc, old.?);

    if (PrintWindow(hwnd, mem_dc, PW_RENDERFULLCONTENT) == 0) return error.PrintWindowFailed;

    const src: [*]const u8 = @ptrCast(bits.?);

    // Crop region in device pixels (DPI-scaled to mirror macOS points).
    const dpi = GetDpiForWindow(hwnd);
    const scale: f64 = if (dpi == 0) 1.0 else @as(f64, @floatFromInt(dpi)) / 96.0;
    const cw: u32 = if (crop) |c| @min(@as(u32, @intCast(win_w)), @as(u32, @intFromFloat(c.w_pt * scale))) else @intCast(win_w);
    const ch: u32 = if (crop) |c| @min(@as(u32, @intCast(win_h)), @as(u32, @intFromFloat(c.h_pt * scale))) else @intCast(win_h);

    const rgba = try alloc.alloc(u8, @as(usize, cw) * @as(usize, ch) * 4);
    errdefer alloc.free(rgba);
    const stride: usize = @as(usize, @intCast(win_w)) * 4;
    var y: u32 = 0;
    while (y < ch) : (y += 1) {
        var x: u32 = 0;
        while (x < cw) : (x += 1) {
            const s = @as(usize, y) * stride + @as(usize, x) * 4;
            const d = (@as(usize, y) * @as(usize, cw) + @as(usize, x)) * 4;
            rgba[d + 0] = src[s + 2]; // R <- BGRA.R
            rgba[d + 1] = src[s + 1]; // G
            rgba[d + 2] = src[s + 0]; // B
            rgba[d + 3] = 255;
        }
    }
    return .{ .w = cw, .h = ch, .rgba = rgba };
}

// ── BMP I/O (32bpp, bottom-up, BGRA; uncompressed) ──────────────────────

const bmp_file_header_size = 14;
const bmp_info_header_size = 40;

pub fn writeImage(alloc: std.mem.Allocator, path: []const u8, img: Image) !void {
    const row_bytes: usize = @as(usize, img.w) * 4;
    const pixels_size = row_bytes * @as(usize, img.h);
    const header_size = bmp_file_header_size + bmp_info_header_size;
    const file_size = header_size + pixels_size;

    const buf = try alloc.alloc(u8, file_size);
    defer alloc.free(buf);

    // BITMAPFILEHEADER (14 bytes)
    buf[0] = 'B';
    buf[1] = 'M';
    std.mem.writeInt(u32, buf[2..6], @intCast(file_size), .little);
    std.mem.writeInt(u32, buf[6..10], 0, .little); // reserved
    std.mem.writeInt(u32, buf[10..14], header_size, .little); // pixel offset
    // BITMAPINFOHEADER (40 bytes)
    std.mem.writeInt(u32, buf[14..18], bmp_info_header_size, .little);
    std.mem.writeInt(i32, buf[18..22], @intCast(img.w), .little);
    std.mem.writeInt(i32, buf[22..26], @intCast(img.h), .little); // positive => bottom-up
    std.mem.writeInt(u16, buf[26..28], 1, .little);
    std.mem.writeInt(u16, buf[28..30], 32, .little);
    std.mem.writeInt(u32, buf[30..34], BI_RGB, .little);
    std.mem.writeInt(u32, buf[34..38], @intCast(pixels_size), .little);
    std.mem.writeInt(i32, buf[38..42], 0, .little);
    std.mem.writeInt(i32, buf[42..46], 0, .little);
    std.mem.writeInt(u32, buf[46..50], 0, .little);
    std.mem.writeInt(u32, buf[50..54], 0, .little);

    // Pixels: bottom-up, BGRA.
    var row: usize = img.h;
    var dst: usize = header_size;
    while (row > 0) {
        row -= 1;
        var x: usize = 0;
        while (x < img.w) : (x += 1) {
            const o = (row * @as(usize, img.w) + x) * 4;
            buf[dst + 0] = img.rgba[o + 2]; // B
            buf[dst + 1] = img.rgba[o + 1]; // G
            buf[dst + 2] = img.rgba[o + 0]; // R
            buf[dst + 3] = 255; // X
            dst += 4;
        }
    }

    var file = try std.fs.cwd().createFile(path, .{});
    defer file.close();
    try file.writeAll(buf);
}

pub fn readImage(alloc: std.mem.Allocator, path: []const u8) !Image {
    const data = try std.fs.cwd().readFileAlloc(alloc, path, 256 * 1024 * 1024);
    defer alloc.free(data);
    if (data.len < bmp_file_header_size + bmp_info_header_size) return error.BadBmp;
    if (data[0] != 'B' or data[1] != 'M') return error.BadBmp;

    const pix_off = std.mem.readInt(u32, data[10..14], .little);
    const width = std.mem.readInt(i32, data[18..22], .little);
    const height_raw = std.mem.readInt(i32, data[22..26], .little);
    const bpp = std.mem.readInt(u16, data[28..30], .little);
    if (bpp != 32 or width <= 0) return error.UnsupportedBmp;
    const top_down = height_raw < 0;
    const height: i32 = if (top_down) -height_raw else height_raw;
    if (height <= 0) return error.UnsupportedBmp;

    const w: u32 = @intCast(width);
    const h: u32 = @intCast(height);
    const row_bytes: usize = @as(usize, w) * 4;
    if (@as(usize, pix_off) + row_bytes * @as(usize, h) > data.len) return error.TruncatedBmp;

    const rgba = try alloc.alloc(u8, @as(usize, w) * @as(usize, h) * 4);
    errdefer alloc.free(rgba);
    var y: u32 = 0;
    while (y < h) : (y += 1) {
        const src_row = if (top_down) y else (h - 1 - y);
        const s = @as(usize, pix_off) + @as(usize, src_row) * row_bytes;
        var x: u32 = 0;
        while (x < w) : (x += 1) {
            const so = s + @as(usize, x) * 4;
            const d = (@as(usize, y) * @as(usize, w) + @as(usize, x)) * 4;
            rgba[d + 0] = data[so + 2]; // R <- BGRA.R
            rgba[d + 1] = data[so + 1]; // G
            rgba[d + 2] = data[so + 0]; // B
            rgba[d + 3] = 255;
        }
    }
    return .{ .w = w, .h = h, .rgba = rgba };
}
