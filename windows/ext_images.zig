// ext_images.zig — image store for Neovim's experimental ext_images extension.
//
// Holds the PNG payloads transmitted by img_data, decoded to premultiplied
// RGBA via WIC, and rasterizes the cell-sized tiles the core requests for
// virtual (U+10EEEE placeholder) placements. Mirrors the macOS ExtImageStore
// design: the placement is scaled ONCE into a cached buffer and tiles are
// memcpy'd out, so first display costs one scaled resample instead of one
// whole-image raster per tile.
//
// Threading: every entry point runs on the core's redraw/flush callback
// thread (img_data / img_del arrive during redraw dispatch, tile
// rasterization during flush), the same single thread — no lock.
//
// Direct placements are NOT handled here yet: on_image_set is left unwired on
// Windows, so direct placements simply do not display. That loses nothing
// relative to the pre-ext_images state (the kitty termcode fallback has no
// terminal to draw into under a GUI), while virtual placements — the
// buffer/editor-anchored path — render through the shared core tile pipeline.

const std = @import("std");
const core = @import("zonvie_core");
const c = @import("win32.zig").c;
const applog = @import("app_log.zig");
const resample = @import("ext_images_resample.zig");

// Hand-declared COM identifiers, matching the renderer's convention of local
// GUID literals instead of pulling in the uuid import library.
const GUID = extern struct {
    Data1: u32,
    Data2: u16,
    Data3: u16,
    Data4: [8]u8,
};

// {CACAF262-9370-4615-A13B-9F5539DA4C0A}
const CLSID_WICImagingFactory_ZONVIE: GUID = .{
    .Data1 = 0xCACAF262,
    .Data2 = 0x9370,
    .Data3 = 0x4615,
    .Data4 = .{ 0xA1, 0x3B, 0x9F, 0x55, 0x39, 0xDA, 0x4C, 0x0A },
};

// {EC5EC8A9-C395-4314-9C77-54D7A935FF70}
const IID_IWICImagingFactory_ZONVIE: GUID = .{
    .Data1 = 0xEC5EC8A9,
    .Data2 = 0xC395,
    .Data3 = 0x4314,
    .Data4 = .{ 0x9C, 0x77, 0x54, 0xD7, 0xA9, 0x35, 0xFF, 0x70 },
};

// {6FDDC324-4E03-4BFE-B185-3D77768DC910}
// The WIC pixel-format GUIDs differ only in the last byte (0x0D would be
// 24bppRGB, and that conversion SUCCEEDS — silently producing sheared
// garbage). Verified byte-for-byte against mingw-w64 wincodec.h.
const GUID_WICPixelFormat32bppPBGRA_ZONVIE: GUID = .{
    .Data1 = 0x6FDDC324,
    .Data2 = 0x4E03,
    .Data3 = 0x4BFE,
    .Data4 = .{ 0xB1, 0x85, 0x3D, 0x77, 0x76, 0x8D, 0xC9, 0x10 },
};

/// One transmitted image, decoded at its native pixel size.
/// Premultiplied RGBA, matching the 4bpp (color emoji) atlas upload path.
const DecodedImage = struct {
    pixels: []u8,
    width_px: u32,
    height_px: u32,
};

/// One placement pre-scaled to its full cell box, tiles memcpy out of it.
/// Keyed by image ID rather than buffer identity: that is sound only because
/// every mutation of `images` (setImage/remove/reset) also drops this cache.
const ScaledPlacement = struct {
    id: i64,
    tile_rows: u16,
    tile_cols: u16,
    px_w: u32,
    px_h: u32,
    pixels: []u8, // (tile_cols*px_w) x (tile_rows*px_h) RGBA
};

/// Full-box budget for the pre-scale buffer; a placement above it (the
/// placeholder scheme allows 297x297 cells) is refused rather than holding a
/// huge intermediate — the tile then renders blank, exactly as an image whose
/// data never arrived does.
const scaled_budget_bytes: usize = 64 << 20;

pub const Store = struct {
    images: std.AutoHashMapUnmanaged(i64, DecodedImage) = .{},
    scaled: ?ScaledPlacement = null,
    tile_scratch: std.ArrayListUnmanaged(u8) = .empty,
    wic_factory: ?*c.IWICImagingFactory = null,
    com_init_attempted: bool = false,

    /// Decode and store (or replace) image `id`. A payload WIC cannot decode
    /// keeps the previous image, matching the macOS store: only img_del and
    /// img_set change what is displayed.
    pub fn setImage(self: *Store, alloc: std.mem.Allocator, id: i64, data: []const u8) void {
        const decoded = self.decodePng(alloc, data) orelse {
            if (applog.isEnabled()) applog.appLog(
                "[ext_images] image {d}: undecodable payload ({d} bytes), keeping previous\n",
                .{ id, data.len },
            );
            return;
        };
        const gop = self.images.getOrPut(alloc, id) catch {
            alloc.free(decoded.pixels);
            return;
        };
        if (gop.found_existing) alloc.free(gop.value_ptr.pixels);
        gop.value_ptr.* = decoded;
        self.dropScaled(alloc);
    }

    pub fn remove(self: *Store, alloc: std.mem.Allocator, id: i64) void {
        if (self.images.fetchRemove(id)) |kv| alloc.free(kv.value.pixels);
        self.dropScaled(alloc);
    }

    /// Drop every image. Neovim never retransmits, so a new session (restart
    /// or :connect hot-swap) must not inherit the previous one's images.
    pub fn reset(self: *Store, alloc: std.mem.Allocator) void {
        var it = self.images.valueIterator();
        while (it.next()) |img| alloc.free(img.pixels);
        self.images.clearRetainingCapacity();
        self.dropScaled(alloc);
    }

    pub fn deinit(self: *Store, alloc: std.mem.Allocator) void {
        self.reset(alloc);
        self.images.deinit(alloc);
        self.tile_scratch.deinit(alloc);
        if (self.wic_factory) |f| {
            _ = f.*.lpVtbl.*.Release.?(f);
            self.wic_factory = null;
        }
    }

    /// Rasterize the (tile_row, tile_col) tile of image `id` into `out`,
    /// scaled so the whole image fills the tile_cols x tile_rows cell box.
    /// out.pixels points into the store's scratch and stays valid until the
    /// NEXT call — the same contract as on_rasterize_glyph.
    pub fn rasterizeTile(
        self: *Store,
        alloc: std.mem.Allocator,
        id: i64,
        tile_row: u16,
        tile_col: u16,
        tile_rows: u16,
        tile_cols: u16,
        px_w: u32,
        px_h: u32,
        out: *core.GlyphBitmap,
    ) bool {
        if (px_w == 0 or px_h == 0 or tile_rows == 0 or tile_cols == 0) return false;
        if (tile_row >= tile_rows or tile_col >= tile_cols) return false;
        const img = self.images.get(id) orelse return false;

        const full_w: usize = @as(usize, px_w) * tile_cols;
        const full_h: usize = @as(usize, px_h) * tile_rows;
        const full_bytes = full_w * full_h * 4;
        if (full_bytes > scaled_budget_bytes) return false;

        // (Re)build the pre-scaled placement buffer on a miss.
        const cache_ok = if (self.scaled) |s|
            s.id == id and s.tile_rows == tile_rows and s.tile_cols == tile_cols and
                s.px_w == px_w and s.px_h == px_h
        else
            false;
        if (!cache_ok) {
            self.dropScaled(alloc);
            const pixels = alloc.alloc(u8, full_bytes) catch return false;
            resample.scalePRGBA(alloc, img.pixels, img.width_px, img.height_px, pixels, @intCast(full_w), @intCast(full_h)) catch {
                // The halving chain's intermediates failed to allocate; the
                // 2x2-footprint fallback is coarser, never wrong.
                resample.bilinearPRGBA(img.pixels, img.width_px, img.height_px, pixels, @intCast(full_w), @intCast(full_h));
            };
            self.scaled = .{
                .id = id,
                .tile_rows = tile_rows,
                .tile_cols = tile_cols,
                .px_w = px_w,
                .px_h = px_h,
                .pixels = pixels,
            };
            if (applog.isEnabled()) applog.appLog(
                "[ext_images] pre-scaled placement {d}x{d} tiles ({d} bytes)\n",
                .{ tile_cols, tile_rows, full_bytes },
            );
        }
        const cache = &(self.scaled.?);

        const tile_bytes: usize = @as(usize, px_w) * 4 * px_h;
        self.tile_scratch.resize(alloc, tile_bytes) catch return false;
        const full_row_bytes = full_w * 4;
        const tile_row_bytes: usize = @as(usize, px_w) * 4;
        var row: usize = 0;
        while (row < px_h) : (row += 1) {
            const src_off = (@as(usize, tile_row) * px_h + row) * full_row_bytes + @as(usize, tile_col) * tile_row_bytes;
            const dst_off = row * tile_row_bytes;
            @memcpy(
                self.tile_scratch.items[dst_off .. dst_off + tile_row_bytes],
                cache.pixels[src_off .. src_off + tile_row_bytes],
            );
        }

        out.* = .{
            .pixels = self.tile_scratch.items.ptr,
            .width = px_w,
            .height = px_h,
            .pitch = @intCast(tile_row_bytes),
            .bearing_x = 0,
            .bearing_y = 0,
            .advance_26_6 = @intCast(px_w * 64),
            .ascent_px = 0,
            .descent_px = 0,
            .bytes_per_pixel = 4,
        };
        return true;
    }

    fn dropScaled(self: *Store, alloc: std.mem.Allocator) void {
        if (self.scaled) |s| {
            alloc.free(s.pixels);
            self.scaled = null;
        }
    }

    // -- WIC decoding ------------------------------------------------------

    fn ensureFactory(self: *Store) ?*c.IWICImagingFactory {
        if (self.wic_factory) |f| return f;
        if (!self.com_init_attempted) {
            self.com_init_attempted = true;
            // The core callback thread has no COM apartment of its own.
            // S_FALSE (already initialized) and RPC_E_CHANGED_MODE (someone
            // initialized it STA) both still permit CoCreateInstance.
            _ = c.CoInitializeEx(null, c.COINIT_MULTITHREADED);
        }
        var factory: ?*c.IWICImagingFactory = null;
        const hr = c.CoCreateInstance(
            @ptrCast(&CLSID_WICImagingFactory_ZONVIE),
            null,
            c.CLSCTX_INPROC_SERVER,
            @ptrCast(&IID_IWICImagingFactory_ZONVIE),
            @ptrCast(&factory),
        );
        if (hr != c.S_OK or factory == null) {
            if (applog.isEnabled()) applog.appLog("[ext_images] WIC factory creation failed hr=0x{x}\n", .{@as(u32, @bitCast(hr))});
            return null;
        }
        self.wic_factory = factory;
        return factory;
    }

    /// Decode `data` (PNG per the protocol; WIC sniffs the container) into a
    /// premultiplied-RGBA buffer owned by the caller's allocator.
    fn decodePng(self: *Store, alloc: std.mem.Allocator, data: []const u8) ?DecodedImage {
        const factory = self.ensureFactory() orelse return null;
        const fv = factory.*.lpVtbl;

        var stream: ?*c.IWICStream = null;
        if (fv.*.CreateStream.?(factory, &stream) != c.S_OK or stream == null) return null;
        defer _ = stream.?.*.lpVtbl.*.Release.?(stream.?);
        // InitializeFromMemory does not copy; the buffer must outlive the
        // decode, which completes inside this function.
        if (stream.?.*.lpVtbl.*.InitializeFromMemory.?(stream.?, @constCast(data.ptr), @intCast(data.len)) != c.S_OK) return null;

        var decoder: ?*c.IWICBitmapDecoder = null;
        if (fv.*.CreateDecoderFromStream.?(
            factory,
            @ptrCast(stream.?),
            null,
            c.WICDecodeMetadataCacheOnDemand,
            &decoder,
        ) != c.S_OK or decoder == null) return null;
        defer _ = decoder.?.*.lpVtbl.*.Release.?(decoder.?);

        var frame: ?*c.IWICBitmapFrameDecode = null;
        if (decoder.?.*.lpVtbl.*.GetFrame.?(decoder.?, 0, &frame) != c.S_OK or frame == null) return null;
        defer _ = frame.?.*.lpVtbl.*.Release.?(frame.?);

        var conv: ?*c.IWICFormatConverter = null;
        if (fv.*.CreateFormatConverter.?(factory, &conv) != c.S_OK or conv == null) return null;
        defer _ = conv.?.*.lpVtbl.*.Release.?(conv.?);
        if (conv.?.*.lpVtbl.*.Initialize.?(
            conv.?,
            @ptrCast(frame.?),
            @ptrCast(&GUID_WICPixelFormat32bppPBGRA_ZONVIE),
            c.WICBitmapDitherTypeNone,
            null,
            0.0,
            c.WICBitmapPaletteTypeCustom,
        ) != c.S_OK) return null;

        var w: c.UINT = 0;
        var h: c.UINT = 0;
        if (conv.?.*.lpVtbl.*.GetSize.?(conv.?, &w, &h) != c.S_OK) return null;
        if (w == 0 or h == 0) return null;
        // Cap the decoded pixel store: nothing bounds it otherwise (the 64MB
        // budget guards only the placement buffer), and the UINT casts below
        // must never see a >4GB total. 16384px covers any sane image.
        if (w > 16384 or h > 16384) {
            if (applog.isEnabled()) applog.appLog("[ext_images] rejecting oversized image {d}x{d}\n", .{ w, h });
            return null;
        }

        const stride: usize = @as(usize, w) * 4;
        const total = stride * h;
        const pixels = alloc.alloc(u8, total) catch return null;
        if (conv.?.*.lpVtbl.*.CopyPixels.?(conv.?, null, @intCast(stride), @intCast(total), pixels.ptr) != c.S_OK) {
            alloc.free(pixels);
            return null;
        }

        // PBGRA -> premultiplied RGBA, the byte order the atlas's 4bpp
        // (color emoji) path stores.
        var i: usize = 0;
        while (i < total) : (i += 4) {
            const b = pixels[i];
            pixels[i] = pixels[i + 2];
            pixels[i + 2] = b;
        }

        return .{ .pixels = pixels, .width_px = w, .height_px = h };
    }
};
