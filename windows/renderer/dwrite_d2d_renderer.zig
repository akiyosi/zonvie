const std = @import("std");
const core = @import("zonvie_core");
const c = @import("../win32.zig").c;
const applog = @import("../app_log.zig");
const render_pipeline_helpers = @import("../render_pipeline_helpers.zig");

// DPI function (Windows 10 v1607+)
extern "user32" fn GetDpiForWindow(hwnd: c.HWND) callconv(.winapi) c.UINT;

const GUID = extern struct {
    Data1: u32,
    Data2: u16,
    Data3: u16,
    Data4: [8]u8,
};

// IDWriteFactory IID: {B859EE5A-D838-4B5B-A2E8-1ADC7D93DB48}
const IID_IDWriteFactory_ZONVIE: GUID = .{
    .Data1 = 0xB859EE5A,
    .Data2 = 0xD838,
    .Data3 = 0x4B5B,
    .Data4 = .{ 0xA2, 0xE8, 0x1A, 0xDC, 0x7D, 0x93, 0xDB, 0x48 },
};

// DWrite font feature struct for IDWriteTextAnalyzer::GetGlyphs.
const DWriteFontFeature = extern struct { nameTag: u32, parameter: u32 };
const MAX_FONT_FEATURES = 32;

// Styled glyph logging stats (global)
var g_log_styled_hits: u64 = 0;
var g_log_styled_misses: u64 = 0;
var g_log_styled_fallbacks: u64 = 0;
var g_log_styled_last_report_ns: i128 = 0;

// GSUB ligature trigger cache entry, keyed by IDWriteFontFace pointer.
const GsubCacheEntry = struct {
    font_face_ptr: usize = 0,
    lig_triggers: [128]u8 = [_]u8{0} ** 128,
    valid: bool = false,
};

/// Convert a `guifont` point size to the em size in device pixels.
///
/// A point is 1/72 inch. DWrite's font size parameter is in DIPs (1/96
/// inch), so a point size must be scaled by 96/72 before it is handed to
/// DWrite, and by dpi/96 to reach device pixels -- the two collapse into
/// dpi/72. Treating `:hN` as DIPs instead rendered text at 72/96 = 0.75x
/// the size every other Neovim GUI shows for the same `guifont`.
fn emSizePxForPointSize(dpi: u32, point_size: f32) f32 {
    return point_size * @as(f32, @floatFromInt(dpi)) / 72.0;
}

pub const Renderer = struct {
    alloc: std.mem.Allocator,
    hwnd: c.HWND,

    mu: std.Io.Mutex = .init,

    d2d_factory: ?*c.ID2D1Factory = null,
    d2d_factory1: ?*c.ID2D1Factory1 = null,
    d2d_device: ?*c.ID2D1Device = null,
    d2d_device_ctx: ?*c.ID2D1DeviceContext = null,
    rt: ?*c.ID2D1HwndRenderTarget = null, // legacy, kept for fallback

    dwrite_factory: ?*c.IDWriteFactory = null,
    text_format: ?*c.IDWriteTextFormat = null,

    // font + metrics needed by glyph rasterization (rasterizeGlyph and
    // the shaping paths)
    font_face: ?*c.IDWriteFontFace = null,
    // Font variants for bold/italic (lazy-initialized on first use)
    bold_font_face: ?*c.IDWriteFontFace = null,
    italic_font_face: ?*c.IDWriteFontFace = null,
    bold_italic_font_face: ?*c.IDWriteFontFace = null,
    styled_fonts_initialized: bool = false,
    /// Cached result of COLR/CBDT/sbix table presence check.
    /// null = not yet checked, true = font has color glyph tables.
    has_color_tables: ?bool = null,
    font_em_size: f32 = 14.0,
    emoji_font_size: f32 = 0, // scaled em size for Segoe UI Emoji (0 = not yet computed)
    base_point_size: f32 = 14.0, // original point size before DPI scaling
    // Base font weight/slant chosen via the font picker (`:set guifont=*`).
    // Normally regular; a picked Bold/Italic face sets these so the base font
    // renders in that style (bold/italic *runs* still come from style_flags).
    base_bold: bool = false,
    base_italic: bool = false,
    dpi: u32 = 96,
    ascent_px: f32 = 0.0,
    descent_px: f32 = 0.0,
    font_name: [64]u16 = [_]u16{0} ** 64, // UTF-16 font family name for IME overlay

    // metrics
    cell_w_px: u32 = 9,
    cell_h_px: u32 = 18,

    // atlas
    atlas_bitmap: ?*c.ID2D1Bitmap = null,

    // Pipeline
    vs: ?*c.ID3D11VertexShader = null,
    ps: ?*c.ID3D11PixelShader = null,
    il: ?*c.ID3D11InputLayout = null,
    sampler: ?*c.ID3D11SamplerState = null,
    blend: ?*c.ID3D11BlendState = null,

    // VS constants (viewport transform)
    vs_cb: ?*c.ID3D11Buffer = null,

    // Glyph cache: scalar -> entry (aligned with core types)
    // Styled glyph cache: (scalar | (style_flags << 21)) -> entry
    // style_flags uses bits 21-22 since Unicode scalars only use bits 0-20

    // Atlas dimensions (set by recreateAtlasTexture, default 2048x2048)
    atlas_w: u32 = 2048,
    atlas_h: u32 = 2048,

    // CPU-side atlas (full size: atlas_w * atlas_h * 4 bytes).
    atlas_cpu: std.ArrayListUnmanaged(u8) = .empty,

    // temporary buffer for a single glyph (padded) generation
    glyph_tmp: std.ArrayListUnmanaged(u8) = .empty,

    // Append-only queue of atlas dirty rects. Entries are appended when glyphs
    // are rasterized and consumed independently by the D2D bitmap path (renderVertices)
    // and each D3D window via per-consumer cursors. Only cleared on atlas reset.
    pending_uploads: std.ArrayListUnmanaged(c.D2D1_RECT_U) = .empty,
    // Monotonic sequence number of the first entry in pending_uploads.
    // Advances only on atlas reset (when all entries become invalid).
    // head_seq = pending_upload_base_seq + pending_uploads.items.len.
    pending_upload_base_seq: u64 = 0,
    // D2D bitmap consumer cursor (used by renderVertices / flushPendingAtlasUploadsLocked).
    d2d_upload_cursor: u64 = 0,

    // reusable brushes
    solid_brush: ?*c.ID2D1SolidColorBrush = null,

    // Off-screen render target for high-quality glyph rendering (created lazily)
    glyph_rt: ?*c.ID2D1BitmapRenderTarget = null,
    glyph_rt_size: u32 = 0, // current size (square)
    glyph_rt_brush: ?*c.ID2D1SolidColorBrush = null,

    // Atlas version - incremented when new glyphs are added (for multi-context sync)
    atlas_version: u64 = 0,
    // Set when atlas is reset; signals the UI thread to request a full re-seed
    // so stale UV coordinates in cached row vertices are refreshed.
    atlas_reset_pending: bool = false,
    // Monotonic counter incremented ONLY on a true atlas reset
    // (recreateAtlasTexture), never on a normal per-glyph upload. Used by
    // external windows to detect "do I need a full re-upload", independently
    // of atlas_version (which bumps too often for that purpose — see
    // tmp/fixplan/06-windows-atlas.md finding 3).
    atlas_reset_generation: u64 = 0,
    // Bumped for every atlas_cpu mutation. Resource rebuilds validate it
    // after running D2D Create/Copy calls outside mu.
    atlas_content_generation: u64 = 0,

    // Font change detection: track name + generation to skip redundant setFont calls
    font_name_utf8: [128]u8 = [_]u8{0} ** 128,
    font_name_utf8_len: u32 = 0,
    font_generation: u32 = 0,

    // OpenType font features for DWrite shaping.
    font_features: [MAX_FONT_FEATURES]DWriteFontFeature = [_]DWriteFontFeature{.{ .nameTag = 0, .parameter = 0 }} ** MAX_FONT_FEATURES,
    font_feature_count: u32 = 0,
    text_analyzer: ?*c.IDWriteTextAnalyzer = null,

    // GSUB ligature trigger cache (see GsubCacheEntry above).
    // Invalidated on font/DPI/device changes.
    gsub_cache: [4]GsubCacheEntry = [_]GsubCacheEntry{.{}} ** 4,

    /// Phase 1 of two-phase init: creates D2D/DWrite factories, sets font, and
    /// computes cellW/cellH. Does NOT create the D2D render target (~30ms).
    /// Call initRenderTarget() to complete initialization before rendering.
    ///
    /// `family_raw` is the user-supplied (or default) [font] family from
    /// config.toml in guifont syntax: a comma-separated fallback list with
    /// optional per-entry `:hN` size and OpenType feature tokens. This
    /// function walks each candidate and uses the first that DWrite can
    /// load. If all fail, it falls back to "Consolas" 14pt.
    /// `default_pt` is [font] size and is used for entries without `:hN`.
    /// When `size_explicit` is true, `default_pt` overrides per-entry sizes.
    pub fn initMetrics(
        alloc: std.mem.Allocator,
        hwnd: c.HWND,
        family_raw: []const u8,
        default_pt: f32,
        size_explicit: bool,
    ) !Renderer {
        var freq: c.LARGE_INTEGER = undefined;
        var t0: c.LARGE_INTEGER = undefined;
        var t1: c.LARGE_INTEGER = undefined;
        if (applog.isEnabled()) _ = c.QueryPerformanceFrequency(&freq);

        var self: Renderer = .{
            .alloc = alloc,
            .hwnd = hwnd,
        };
        errdefer self.deinit();

        // D2D factory
        if (applog.isEnabled()) _ = c.QueryPerformanceCounter(&t0);
        var d2d_factory: ?*c.ID2D1Factory = null;
        const hr_d2d = c.D2D1CreateFactory(
            c.D2D1_FACTORY_TYPE_MULTI_THREADED,
            &c.IID_ID2D1Factory,
            null,
            @ptrCast(&d2d_factory),
        );
        if (hr_d2d != 0 or d2d_factory == null) return error.D2DFactoryCreateFailed;
        self.d2d_factory = d2d_factory;

        // QueryInterface for ID2D1Factory1 (needed for D2D device context creation)
        var factory1: ?*c.ID2D1Factory1 = null;
        const fac_unk: *c.IUnknown = @ptrCast(d2d_factory.?);
        if (fac_unk.lpVtbl.*.QueryInterface) |qi| {
            _ = qi(fac_unk, &c.IID_ID2D1Factory1, @ptrCast(&factory1));
        }
        self.d2d_factory1 = factory1;
        if (applog.isEnabled()) applog.appLog("[d2d] ID2D1Factory1: {s}\n", .{if (factory1 != null) "available" else "not available"});

        if (applog.isEnabled()) {
            _ = c.QueryPerformanceCounter(&t1);
            applog.appLog("[d2d] [TIMING] D2D1CreateFactory: {d}ms\n", .{@divTrunc((t1.QuadPart - t0.QuadPart) * 1000, freq.QuadPart)});
        }

        // DWrite factory
        if (applog.isEnabled()) _ = c.QueryPerformanceCounter(&t0);
        var dw_factory: ?*c.IDWriteFactory = null;
        const hr_dw = c.DWriteCreateFactory(
            c.DWRITE_FACTORY_TYPE_SHARED,
            @as(*const c.GUID, @ptrCast(&IID_IDWriteFactory_ZONVIE)),
            @ptrCast(&dw_factory),
        );
        if (hr_dw != 0 or dw_factory == null) return error.DWriteFactoryCreateFailed;
        self.dwrite_factory = dw_factory;
        if (applog.isEnabled()) {
            _ = c.QueryPerformanceCounter(&t1);
            applog.appLog("[d2d] [TIMING] DWriteCreateFactory: {d}ms\n", .{@divTrunc((t1.QuadPart - t0.QuadPart) * 1000, freq.QuadPart)});
        }

        // Get DPI for the window (Per-Monitor DPI Aware V2)
        const window_dpi = GetDpiForWindow(hwnd);
        self.dpi = if (window_dpi > 0) window_dpi else 96;
        if (applog.isEnabled()) applog.appLog("[d2d] window DPI: {d}\n", .{self.dpi});

        // Initial font → cell metrics become valid.
        // Walk the [font] family candidate list (guifont syntax) and
        // pick the first that loads. Same fallback rule as the runtime
        // `on_guifont` path so config and nvim's payload behave alike.
        if (applog.isEnabled()) _ = c.QueryPerformanceCounter(&t0);

        var arena = std.heap.ArenaAllocator.init(alloc);
        defer arena.deinit();
        const aa = arena.allocator();

        var loaded = false;
        if (family_raw.len > 0) {
            const cands = core.config.splitFontFamilyList(aa, family_raw) catch &.{};
            for (cands) |cand_str| {
                const resolved = core.redraw_handler.parseGuiFontCandidate(aa, cand_str) catch continue;
                if (resolved.name.len == 0) continue;
                const parsed_pt: f32 = @floatCast(resolved.point_size);
                const cand_pt: f32 = if (size_explicit or parsed_pt <= 0) default_pt else parsed_pt;
                self.setFontUtf8WithFeatures(resolved.name, cand_pt, "") catch |e| {
                    if (applog.isEnabled()) applog.appLog("[d2d] initMetrics: skipped '{s}' pt={d}: {any}\n", .{ resolved.name, cand_pt, e });
                    continue;
                };
                if (applog.isEnabled()) applog.appLog("[d2d] initMetrics: selected '{s}' pt={d}\n", .{ resolved.name, cand_pt });
                loaded = true;
                break;
            }
        }
        if (!loaded) {
            if (applog.isEnabled()) applog.appLog("[d2d] initMetrics: no candidate loaded, falling back to Consolas\n", .{});
            try self.setFontUtf8("Consolas", 14.0);
        }

        if (applog.isEnabled()) {
            _ = c.QueryPerformanceCounter(&t1);
            applog.appLog("[d2d] [TIMING] setFontUtf8: {d}ms\n", .{@divTrunc((t1.QuadPart - t0.QuadPart) * 1000, freq.QuadPart)});
        }

        return self;
    }

    const D2DDeviceCtxLocal = struct {
        device: *c.ID2D1Device,
        ctx: *c.ID2D1DeviceContext,
    };

    /// Creates the ID2D1Device + ID2D1DeviceContext from a D3D11 device.
    /// Deliberately does NOT touch self or hold self.mu: CreateDevice/
    /// CreateDeviceContext are DXGI/D2D factory-level calls that can pump
    /// window messages, which can reenter WM_PAINT/WM_SIZE/close handlers
    /// (or this same recovery handler) on the UI thread — those handlers'
    /// atlas callbacks (rasterizeGlyph etc.) acquire self.mu, so
    /// running this under self.mu would self-deadlock the same way holding
    /// app.mu across it used to (see window.zig's device-lost recovery).
    /// Self-contained errdefers: on error, nothing here has touched self,
    /// so there is nothing for the caller to unwind.
    fn createD2DDeviceContextUnlocked(self: *Renderer, d3d_device: *c.ID3D11Device) !D2DDeviceCtxLocal {
        const factory1 = self.d2d_factory1 orelse return error.NoFactory1;

        var dxgi_dev: ?*c.IDXGIDevice = null;
        const dev_unk: *c.IUnknown = @ptrCast(d3d_device);
        const qi = dev_unk.lpVtbl.*.QueryInterface orelse return error.D2DDeviceContextFailed;
        const hr_dxgi = qi(dev_unk, &c.IID_IDXGIDevice, @ptrCast(&dxgi_dev));
        if (c.FAILED(hr_dxgi) or dxgi_dev == null) return error.D2DDeviceContextFailed;
        defer {
            const rel = dxgi_dev.?.lpVtbl.*.Release orelse null;
            if (rel) |f| _ = f(dxgi_dev.?);
        }

        var d2d_device: ?*c.ID2D1Device = null;
        const fac1_vtbl = factory1.lpVtbl.*;
        const create_dev_fn = fac1_vtbl.CreateDevice orelse return error.D2DDeviceContextFailed;
        const hr_dev = create_dev_fn(factory1, @ptrCast(dxgi_dev.?), @ptrCast(&d2d_device));
        if (c.FAILED(hr_dev) or d2d_device == null) return error.D2DDeviceContextFailed;
        errdefer safeRelease(d2d_device);

        var d2d_ctx: ?*c.ID2D1DeviceContext = null;
        const dev_vtbl = d2d_device.?.lpVtbl.*;
        const create_ctx_fn = dev_vtbl.CreateDeviceContext orelse return error.D2DDeviceContextFailed;
        const hr_ctx = create_ctx_fn(d2d_device.?, c.D2D1_DEVICE_CONTEXT_OPTIONS_NONE, @ptrCast(&d2d_ctx));
        if (c.FAILED(hr_ctx) or d2d_ctx == null) return error.D2DDeviceContextFailed;

        return .{ .device = d2d_device.?, .ctx = d2d_ctx.? };
    }

    const AtlasBitmapAndBrush = struct {
        bitmap: *c.ID2D1Bitmap,
        brush: *c.ID2D1SolidColorBrush,
    };

    const AtlasPixelSnapshot = struct {
        pixels: []u8,
        width: u32,
        height: u32,
        generation: u64,
    };

    fn snapshotAtlasPixels(self: *Renderer) !AtlasPixelSnapshot {
        self.mu.lockUncancelable(core.clock.io());
        defer self.mu.unlock(core.clock.io());

        const total = @as(usize, self.atlas_w) * @as(usize, self.atlas_h) * 4;
        if (self.atlas_cpu.items.len != total) {
            try self.atlas_cpu.resize(self.alloc, total);
            @memset(self.atlas_cpu.items, 0);
            self.pending_upload_base_seq += self.pending_uploads.items.len;
            self.pending_uploads.clearRetainingCapacity();
            self.atlas_content_generation +%= 1;
        }

        const pixels = try self.alloc.alloc(u8, total);
        @memcpy(pixels, self.atlas_cpu.items);
        return .{
            .pixels = pixels,
            .width = self.atlas_w,
            .height = self.atlas_h,
            .generation = self.atlas_content_generation,
        };
    }

    fn copyAtlasSnapshotUnlocked(bitmap: *c.ID2D1Bitmap, snapshot: AtlasPixelSnapshot) !void {
        const copy_fn = bitmap.lpVtbl.*.CopyFromMemory orelse return error.BitmapMissingCopyFromMemory;
        const rect = c.D2D1_RECT_U{
            .left = 0,
            .top = 0,
            .right = snapshot.width,
            .bottom = snapshot.height,
        };
        const hr = copy_fn(bitmap, &rect, snapshot.pixels.ptr, snapshot.width * 4);
        if (c.FAILED(hr)) return error.ClearAtlasFailed;
    }

    /// Creates the atlas bitmap + solid brush on the given (not-yet-shared)
    /// render target. Pure: touches no self fields, holds no lock — safe to
    /// call on a freshly-created device context BEFORE it is published to
    /// self.d2d_device_ctx, since nothing else can have a reference to it
    /// yet. CreateBitmap/CreateSolidColorBrush are D2D resource-creation
    /// calls that, per repeated review, can also pump window messages;
    /// running them under self.mu risks the exact app.mu<->self.mu
    /// lock-order inversion those reviews found (core-thread atlas
    /// callbacks take app.mu then self.mu; a UI-thread caller holding
    /// self.mu here that gets reentered into a handler needing app.mu would
    /// deadlock against it).
    fn createAtlasBitmapAndBrushUnlocked(rt_base: *c.ID2D1RenderTarget, atlas_w: u32, atlas_h: u32) !AtlasBitmapAndBrush {
        const props = c.D2D1_BITMAP_PROPERTIES{
            .pixelFormat = c.D2D1_PIXEL_FORMAT{
                .format = c.DXGI_FORMAT_R8G8B8A8_UNORM,
                .alphaMode = c.D2D1_ALPHA_MODE_PREMULTIPLIED,
            },
            .dpiX = 96.0,
            .dpiY = 96.0,
        };
        var bmp: ?*c.ID2D1Bitmap = null;
        const sz = c.D2D1_SIZE_U{ .width = atlas_w, .height = atlas_h };
        const vtbl = rt_base.lpVtbl.*;

        const hr = if (vtbl.CreateBitmap) |create_bitmap_fn| blk: {
            break :blk create_bitmap_fn(rt_base, sz, null, 0, &props, &bmp);
        } else {
            if (applog.isEnabled()) applog.appLog("[d2d] CreateBitmap missing on vtbl\n", .{});
            return error.CreateAtlasFailed;
        };
        if (c.FAILED(hr) or bmp == null) {
            if (applog.isEnabled()) {
                const hr_u: u32 = @bitCast(hr);
                applog.appLog("[d2d] CreateBitmap(A8) FAILED hr=0x{x} bmp={*}\n", .{ hr_u, bmp });
            }
            return error.CreateAtlasFailed;
        }
        errdefer safeRelease(bmp);

        var br: ?*c.ID2D1SolidColorBrush = null;
        const c0 = c.D2D1_COLOR_F{ .r = 1, .g = 1, .b = 1, .a = 1 };
        const hr2 = if (vtbl.CreateSolidColorBrush) |create_brush_fn| blk: {
            break :blk create_brush_fn(rt_base, &c0, null, &br);
        } else return error.CreateBrushFailed;
        if (c.FAILED(hr2) or br == null) return error.CreateBrushFailed;

        return .{ .bitmap = bmp.?, .brush = br.? };
    }

    /// Phase 2: Create D2D device context from a D3D11 device via DXGI.
    /// Falls back to legacy HwndRenderTarget if Factory1 is not available.
    pub fn initD2DDeviceContext(self: *Renderer, d3d_device: *c.ID3D11Device) !void {
        var freq: c.LARGE_INTEGER = undefined;
        var t0: c.LARGE_INTEGER = undefined;
        var t1: c.LARGE_INTEGER = undefined;
        if (applog.isEnabled()) _ = c.QueryPerformanceFrequency(&freq);

        if (applog.isEnabled()) _ = c.QueryPerformanceCounter(&t0);

        if (self.d2d_factory1 == null) {
            // Fallback to legacy HwndRenderTarget.
            if (applog.isEnabled()) applog.appLog("[d2d] No ID2D1Factory1, falling back to HwndRenderTarget\n", .{});
            try self.recreateRenderTarget();
            if (applog.isEnabled()) {
                _ = c.QueryPerformanceCounter(&t1);
                applog.appLog("[d2d] [TIMING] initRenderTarget (fallback): {d}ms\n", .{@divTrunc((t1.QuadPart - t0.QuadPart) * 1000, freq.QuadPart)});
            }
            return;
        }

        // Unlocked — see createD2DDeviceContextUnlocked's doc comment.
        const built = try self.createD2DDeviceContextUnlocked(d3d_device);

        if (applog.isEnabled()) applog.appLog("[d2d] D2D device context created from D3D11 device\n", .{});

        const rt_base: *c.ID2D1RenderTarget = @ptrCast(built.ctx);
        var attempt: u8 = 0;
        while (attempt < 3) : (attempt += 1) {
            const snapshot = self.snapshotAtlasPixels() catch |err| {
                safeRelease(@as(?*c.ID2D1DeviceContext, built.ctx));
                safeRelease(@as(?*c.ID2D1Device, built.device));
                return err;
            };
            const atlas_res = createAtlasBitmapAndBrushUnlocked(rt_base, snapshot.width, snapshot.height) catch |err| {
                self.alloc.free(snapshot.pixels);
                safeRelease(@as(?*c.ID2D1DeviceContext, built.ctx));
                safeRelease(@as(?*c.ID2D1Device, built.device));
                return err;
            };
            copyAtlasSnapshotUnlocked(atlas_res.bitmap, snapshot) catch |err| {
                self.alloc.free(snapshot.pixels);
                safeRelease(@as(?*c.ID2D1Bitmap, atlas_res.bitmap));
                safeRelease(@as(?*c.ID2D1SolidColorBrush, atlas_res.brush));
                safeRelease(@as(?*c.ID2D1DeviceContext, built.ctx));
                safeRelease(@as(?*c.ID2D1Device, built.device));
                return err;
            };

            var old_bitmap: ?*c.ID2D1Bitmap = null;
            var old_brush: ?*c.ID2D1SolidColorBrush = null;
            var old_ctx: ?*c.ID2D1DeviceContext = null;
            var old_device: ?*c.ID2D1Device = null;
            self.mu.lockUncancelable(core.clock.io());
            const snapshot_still_current = self.atlas_w == snapshot.width and
                self.atlas_h == snapshot.height and
                self.atlas_content_generation == snapshot.generation;
            if (snapshot_still_current) {
                old_bitmap = self.atlas_bitmap;
                old_brush = self.solid_brush;
                old_ctx = self.d2d_device_ctx;
                old_device = self.d2d_device;
                self.atlas_bitmap = atlas_res.bitmap;
                self.solid_brush = atlas_res.brush;
                self.d2d_device_ctx = built.ctx;
                self.d2d_device = built.device;
                self.d2d_upload_cursor = self.pending_upload_base_seq + self.pending_uploads.items.len;
            }
            self.mu.unlock(core.clock.io());
            self.alloc.free(snapshot.pixels);

            if (!snapshot_still_current) {
                safeRelease(@as(?*c.ID2D1Bitmap, atlas_res.bitmap));
                safeRelease(@as(?*c.ID2D1SolidColorBrush, atlas_res.brush));
                continue;
            }

            safeRelease(old_bitmap);
            safeRelease(old_brush);
            safeRelease(old_ctx);
            safeRelease(old_device);
            if (applog.isEnabled()) {
                _ = c.QueryPerformanceCounter(&t1);
                applog.appLog("[d2d] [TIMING] initD2DDeviceContext: {d}ms\n", .{@divTrunc((t1.QuadPart - t0.QuadPart) * 1000, freq.QuadPart)});
            }
            return;
        }

        safeRelease(@as(?*c.ID2D1DeviceContext, built.ctx));
        safeRelease(@as(?*c.ID2D1Device, built.device));
        return error.AtlasChangedDuringRebuild;
    }

    /// Release device-bound D2D objects so initD2DDeviceContext can rebind to
    /// a fresh D3D device after device loss. CPU atlas pixels and glyph maps
    /// are preserved (createAtlasResources keeps them when atlas_cpu is
    /// already sized), so recovery is a full GPU re-upload, not a re-raster.
    ///
    /// Acquires self.mu only to detach the pointers (swap to null) — the
    /// actual COM Release() calls run AFTER unlocking. Even Release() is
    /// not assumed message-pump-safe here: on a lost/removed device, COM
    /// teardown can synchronously pump the message queue (a documented
    /// Windows/DXGI quirk around device-removal handling), and running
    /// that under self.mu risks the same reentrant deadlock CreateDevice/
    /// CreateBitmap did before this file's other self.mu-scope fixes.
    pub fn releaseD2DDeviceObjects(self: *Renderer) void {
        var old_bitmap: ?*c.ID2D1Bitmap = null;
        var old_brush: ?*c.ID2D1SolidColorBrush = null;
        var old_ctx: ?*c.ID2D1DeviceContext = null;
        var old_device: ?*c.ID2D1Device = null;
        {
            self.mu.lockUncancelable(core.clock.io());
            defer self.mu.unlock(core.clock.io());
            old_bitmap = self.atlas_bitmap;
            self.atlas_bitmap = null;
            old_brush = self.solid_brush;
            self.solid_brush = null;
            old_ctx = self.d2d_device_ctx;
            self.d2d_device_ctx = null;
            old_device = self.d2d_device;
            self.d2d_device = null;
        }
        safeRelease(old_bitmap);
        safeRelease(old_brush);
        safeRelease(old_ctx);
        safeRelease(old_device);
    }

    /// Legacy phase 2: creates the D2D HwndRenderTarget and atlas resources.
    pub fn initRenderTarget(self: *Renderer) !void {
        var freq: c.LARGE_INTEGER = undefined;
        var t0: c.LARGE_INTEGER = undefined;
        var t1: c.LARGE_INTEGER = undefined;
        if (applog.isEnabled()) _ = c.QueryPerformanceFrequency(&freq);
        if (applog.isEnabled()) _ = c.QueryPerformanceCounter(&t0);
        try self.recreateRenderTarget();
        if (applog.isEnabled()) {
            _ = c.QueryPerformanceCounter(&t1);
            applog.appLog("[d2d] [TIMING] initRenderTarget: {d}ms\n", .{@divTrunc((t1.QuadPart - t0.QuadPart) * 1000, freq.QuadPart)});
        }
    }

    /// Full single-phase init (for callers that do not need the two-phase split).
    pub fn init(alloc: std.mem.Allocator, hwnd: c.HWND, initial_font: []const u8, initial_pt: f32) !Renderer {
        var self = try initMetrics(alloc, hwnd, initial_font, initial_pt, true);
        errdefer self.deinit();
        try self.initRenderTarget();
        return self;
    }

    pub fn deinit(self: *Renderer) void {
        self.atlas_cpu.deinit(self.alloc);
        self.glyph_tmp.deinit(self.alloc);
        self.pending_uploads.deinit(self.alloc);

        safeRelease(self.vs_cb);
        safeRelease(self.blend);
        safeRelease(self.sampler);

        safeRelease(self.solid_brush);
        safeRelease(self.glyph_rt_brush);
        safeRelease(self.glyph_rt);
        safeRelease(self.atlas_bitmap);

        safeRelease(self.text_analyzer);
        safeRelease(self.text_format);
        safeRelease(self.font_face);
        safeRelease(self.bold_font_face);
        safeRelease(self.italic_font_face);
        safeRelease(self.bold_italic_font_face);
        safeRelease(self.rt);
        safeRelease(self.d2d_device_ctx);
        safeRelease(self.d2d_device);
        safeRelease(self.d2d_factory1);
        safeRelease(self.dwrite_factory);
        safeRelease(self.d2d_factory);
        self.* = undefined;
    }

    pub const Cursor = extern struct {
        enabled: u32,
        row: u32,
        col: u32,
        shape: u32,
        cell_percentage: u32,
        fgRGB: u32,
        bgRGB: u32,
    };

    const LegacyRenderTargetResources = struct {
        rt: *c.ID2D1HwndRenderTarget,
        bitmap: *c.ID2D1Bitmap,
        brush: *c.ID2D1SolidColorBrush,
    };

    fn buildLegacyRenderTargetUnlocked(self: *Renderer, snapshot: AtlasPixelSnapshot) !LegacyRenderTargetResources {
        var rc: c.RECT = undefined;
        _ = c.GetClientRect(self.hwnd, &rc);

        const size = c.D2D1_SIZE_U{
            .width = @intCast(@max(1, rc.right - rc.left)),
            .height = @intCast(@max(1, rc.bottom - rc.top)),
        };

        const rt_props = c.D2D1_RENDER_TARGET_PROPERTIES{
            .type = c.D2D1_RENDER_TARGET_TYPE_DEFAULT,
            .pixelFormat = c.D2D1_PIXEL_FORMAT{
                .format = c.DXGI_FORMAT_B8G8R8A8_UNORM,
                .alphaMode = c.D2D1_ALPHA_MODE_IGNORE,
            },
            .dpiX = 0,
            .dpiY = 0,
            .usage = c.D2D1_RENDER_TARGET_USAGE_NONE,
            .minLevel = c.D2D1_FEATURE_LEVEL_DEFAULT,
        };

        const hwnd_props = c.D2D1_HWND_RENDER_TARGET_PROPERTIES{
            .hwnd = self.hwnd,
            .pixelSize = size,
            .presentOptions = c.D2D1_PRESENT_OPTIONS_NONE,
        };

        var rt: ?*c.ID2D1HwndRenderTarget = null;

        const factory = self.d2d_factory orelse return error.NotInitialized;
        const vtbl = factory.lpVtbl.*;
        const create_fn = vtbl.CreateHwndRenderTarget orelse return error.D2DFactoryMissingCreateHwndRenderTarget;

        const hr = create_fn(
            factory,
            &rt_props,
            &hwnd_props,
            &rt,
        );
        if (hr != 0 or rt == null) return error.D2DCreateHwndRenderTargetFailed;
        errdefer safeRelease(rt);

        const rt_base: *c.ID2D1RenderTarget = @ptrCast(rt.?);
        const atlas = try createAtlasBitmapAndBrushUnlocked(rt_base, snapshot.width, snapshot.height);
        errdefer {
            safeRelease(@as(?*c.ID2D1Bitmap, atlas.bitmap));
            safeRelease(@as(?*c.ID2D1SolidColorBrush, atlas.brush));
        }
        try copyAtlasSnapshotUnlocked(atlas.bitmap, snapshot);
        return .{ .rt = rt.?, .bitmap = atlas.bitmap, .brush = atlas.brush };
    }

    fn recreateRenderTarget(self: *Renderer) !void {
        var attempt: u8 = 0;
        while (attempt < 3) : (attempt += 1) {
            const snapshot = try self.snapshotAtlasPixels();
            const built = self.buildLegacyRenderTargetUnlocked(snapshot) catch |err| {
                self.alloc.free(snapshot.pixels);
                return err;
            };

            var old_rt: ?*c.ID2D1HwndRenderTarget = null;
            var old_bitmap: ?*c.ID2D1Bitmap = null;
            var old_brush: ?*c.ID2D1SolidColorBrush = null;
            self.mu.lockUncancelable(core.clock.io());
            const snapshot_still_current = self.atlas_w == snapshot.width and
                self.atlas_h == snapshot.height and
                self.atlas_content_generation == snapshot.generation;
            if (snapshot_still_current) {
                old_rt = self.rt;
                old_bitmap = self.atlas_bitmap;
                old_brush = self.solid_brush;
                self.rt = built.rt;
                self.atlas_bitmap = built.bitmap;
                self.solid_brush = built.brush;
                self.d2d_upload_cursor = self.pending_upload_base_seq + self.pending_uploads.items.len;
                self.gsub_cache = [_]GsubCacheEntry{.{}} ** 4;
            }
            self.mu.unlock(core.clock.io());
            self.alloc.free(snapshot.pixels);

            if (!snapshot_still_current) {
                safeRelease(@as(?*c.ID2D1Bitmap, built.bitmap));
                safeRelease(@as(?*c.ID2D1SolidColorBrush, built.brush));
                safeRelease(@as(?*c.ID2D1HwndRenderTarget, built.rt));
                continue;
            }
            safeRelease(old_bitmap);
            safeRelease(old_brush);
            safeRelease(old_rt);
            return;
        }
        return error.AtlasChangedDuringRebuild;
    }

    // Style flags constants (match ZONVIE_STYLE_* in zonvie_core.h)
    const STYLE_BOLD: u32 = 1 << 0;
    const STYLE_ITALIC: u32 = 1 << 1;

    // --- Phase 2: Core-managed atlas ---

    /// Check if the current base font face has color glyph tables (COLR, CBDT, sbix).
    /// Result is cached per font face (reset on font change).
    /// Caller must hold self.mu.
    fn hasColorTables(self: *Renderer) bool {
        if (self.has_color_tables) |cached| return cached;

        const face = self.font_face orelse {
            self.has_color_tables = false;
            return false;
        };
        const fvtbl = face.lpVtbl.*;
        const try_fn = fvtbl.TryGetFontTable orelse {
            self.has_color_tables = false;
            return false;
        };

        // Check COLR, CBDT, sbix, and SVG tables
        const tag_names = [_]*const [4]u8{ "COLR", "CBDT", "sbix", "SVG " };
        const tags = [_]u32{
            packTag("COLR"),
            packTag("CBDT"),
            packTag("sbix"),
            packTag("SVG "),
        };
        for (tags, 0..) |tag, ti| {
            var data: ?*const anyopaque = null;
            var size: c.UINT32 = 0;
            var ctx: ?*anyopaque = null;
            var exists: c.BOOL = c.FALSE;
            const hr = try_fn(face, tag, &data, &size, &ctx, &exists);
            if (applog.isEnabled()) {
                applog.appLog("[color_tables] checking {s}: hr=0x{x} exists={d} size={d}\n", .{ tag_names[ti], @as(u32, @bitCast(hr)), @as(u32, @intFromBool(exists != c.FALSE)), size });
            }
            if (ctx != null) {
                if (fvtbl.ReleaseFontTable) |rel_fn| rel_fn(face, ctx);
            }
            if (!c.FAILED(hr) and exists != c.FALSE and size > 0) {
                if (applog.isEnabled()) applog.appLog("[color_tables] FOUND {s} table, size={d}\n", .{ tag_names[ti], size });
                self.has_color_tables = true;
                return true;
            }
        }
        if (applog.isEnabled()) applog.appLog("[color_tables] no color tables found\n", .{});
        self.has_color_tables = false;
        return false;
    }

    /// Compute the DIP font size for Segoe UI Emoji that fits within cell_h_px.
    /// Uses DWrite TextLayout to measure the actual line height, then scales down
    /// if the emoji font's metrics exceed the cell height.
    fn computeEmojiFontSize(self: *Renderer, dwrite_factory: *c.IDWriteFactory, cell_h_f: f32) f32 {
        const emoji_font_name: [*:0]const u16 = std.unicode.utf8ToUtf16LeStringLiteral("Segoe UI Emoji");
        const locale: [*:0]const u16 = std.unicode.utf8ToUtf16LeStringLiteral("en-us");

        // Create a temporary text format at font_em_size to measure
        var tmp_fmt: ?*c.IDWriteTextFormat = null;
        const create_tf = dwrite_factory.lpVtbl.*.CreateTextFormat orelse return self.font_em_size;
        const hr_tf = create_tf(dwrite_factory, emoji_font_name, null, c.DWRITE_FONT_WEIGHT_NORMAL, c.DWRITE_FONT_STYLE_NORMAL, c.DWRITE_FONT_STRETCH_NORMAL, self.font_em_size, locale, &tmp_fmt);
        if (hr_tf != 0 or tmp_fmt == null) return self.font_em_size;
        defer {
            const base: *c.IUnknown = @ptrCast(tmp_fmt.?);
            _ = base.lpVtbl.*.Release.?(base);
        }

        // Measure a sample emoji character
        const sample: [2]c.WCHAR = .{ 0xD83D, 0xDE01 }; // U+1F601 😁
        var layout: ?*c.IDWriteTextLayout = null;
        const create_layout = dwrite_factory.lpVtbl.*.CreateTextLayout orelse return self.font_em_size;
        const hr_layout = create_layout(dwrite_factory, &sample, 2, tmp_fmt.?, 1000.0, 1000.0, &layout);
        if (hr_layout != 0 or layout == null) return self.font_em_size;
        defer {
            const base: *c.IUnknown = @ptrCast(layout.?);
            _ = base.lpVtbl.*.Release.?(base);
        }

        var metrics: c.DWRITE_TEXT_METRICS = std.mem.zeroes(c.DWRITE_TEXT_METRICS);
        const layout_ptr = layout.?;
        const get_metrics = layout_ptr.lpVtbl.*.GetMetrics orelse return self.font_em_size;
        if (get_metrics(layout_ptr, &metrics) != 0) return self.font_em_size;

        const measured_h = metrics.height;
        if (measured_h <= 0 or measured_h <= cell_h_f) return self.font_em_size;

        // Scale down: emoji_size = font_em_size * (cell_h / measured_h)
        return self.font_em_size * cell_h_f / measured_h;
    }

    /// D2D color emoji rendering: render a Unicode scalar (or cluster) via D2D
    /// DrawTextW into a 32-bit BGRA DIB section, then copy to glyph_tmp as RGBA.
    /// Returns true if color emoji was successfully rendered.
    fn rasterizeColorEmojiGDI(self: *Renderer, scalar: u32, corep: ?*core.zonvie_core, out_bitmap: *core.GlyphBitmap) bool {
        // Use oversized buffer so emoji glyphs are not clipped.
        // Emoji fonts often render taller than the cell height (ascent + descent
        // can exceed em size). The actual glyph bounds are scanned afterwards and
        // only the non-empty region is packed into the atlas.
        const bmp_w: i32 = @intCast(self.cell_w_px * 3);
        const bmp_h: i32 = @intCast(self.cell_h_px * 2);
        if (bmp_w <= 0 or bmp_h <= 0) return false;

        const d2d_factory = self.d2d_factory orelse return false;
        const dwrite_factory = self.dwrite_factory orelse return false;

        // Create memory DC + 32-bit BGRA DIB section for D2D DC render target
        const hdc = c.CreateCompatibleDC(null);
        if (hdc == null) return false;
        defer _ = c.DeleteDC(hdc);

        var bmi: c.BITMAPINFO = std.mem.zeroes(c.BITMAPINFO);
        bmi.bmiHeader.biSize = @sizeOf(c.BITMAPINFOHEADER);
        bmi.bmiHeader.biWidth = bmp_w;
        bmi.bmiHeader.biHeight = -bmp_h; // top-down
        bmi.bmiHeader.biPlanes = 1;
        bmi.bmiHeader.biBitCount = 32;
        bmi.bmiHeader.biCompression = c.BI_RGB;

        var bits: ?*anyopaque = null;
        const hbm = c.CreateDIBSection(hdc, &bmi, c.DIB_RGB_COLORS, &bits, null, 0);
        if (hbm == null or bits == null) return false;
        defer _ = c.DeleteObject(hbm);

        const old_bm = c.SelectObject(hdc, hbm);
        defer _ = c.SelectObject(hdc, old_bm);

        // Create D2D DC render target
        const rtp = c.D2D1_RENDER_TARGET_PROPERTIES{
            .type = c.D2D1_RENDER_TARGET_TYPE_DEFAULT,
            .pixelFormat = .{
                .format = c.DXGI_FORMAT_B8G8R8A8_UNORM,
                .alphaMode = c.D2D1_ALPHA_MODE_PREMULTIPLIED,
            },
            .dpiX = 0,
            .dpiY = 0,
            .usage = c.D2D1_RENDER_TARGET_USAGE_NONE,
            .minLevel = c.D2D1_FEATURE_LEVEL_DEFAULT,
        };

        var dc_rt: ?*c.ID2D1DCRenderTarget = null;
        const create_fn = d2d_factory.lpVtbl.*.CreateDCRenderTarget orelse return false;
        const hr_rt = create_fn(d2d_factory, &rtp, &dc_rt);
        if (hr_rt != 0 or dc_rt == null) return false;
        defer {
            const base: *c.IUnknown = @ptrCast(dc_rt.?);
            _ = base.lpVtbl.*.Release.?(base);
        }

        // Bind D2D render target to the memory DC
        var bind_rect: c.RECT = .{ .left = 0, .top = 0, .right = bmp_w, .bottom = bmp_h };
        const bind_fn = dc_rt.?.lpVtbl.*.BindDC orelse return false;
        const hr_bind = bind_fn(dc_rt.?, hdc, &bind_rect);
        if (hr_bind != 0) return false;

        // Compute emoji font size on first use: measure the actual line height
        // of Segoe UI Emoji at font_em_size and scale down if it exceeds cell_h_px.
        const cell_h_f: f32 = @floatFromInt(self.cell_h_px);
        if (self.emoji_font_size == 0) {
            self.emoji_font_size = self.computeEmojiFontSize(dwrite_factory, cell_h_f);
        }

        const emoji_font_name: [*:0]const u16 = std.unicode.utf8ToUtf16LeStringLiteral("Segoe UI Emoji");
        var text_format: ?*c.IDWriteTextFormat = null;
        const create_tf = dwrite_factory.lpVtbl.*.CreateTextFormat orelse return false;
        const hr_tf = create_tf(
            dwrite_factory,
            emoji_font_name,
            null, // font collection (system default)
            c.DWRITE_FONT_WEIGHT_NORMAL,
            c.DWRITE_FONT_STYLE_NORMAL,
            c.DWRITE_FONT_STRETCH_NORMAL,
            self.emoji_font_size,
            std.unicode.utf8ToUtf16LeStringLiteral("en-us"),
            &text_format,
        );
        if (hr_tf != 0 or text_format == null) return false;
        defer {
            const base: *c.IUnknown = @ptrCast(text_format.?);
            _ = base.lpVtbl.*.Release.?(base);
        }

        // Convert cluster scalars to UTF-16.
        // If flush set a multi-scalar cluster context, use the full cluster;
        // otherwise fall back to the single scalar argument.
        var gdi_cl_len: u8 = 0;
        const gdi_cl_ptr = core.zonvie_core_get_emoji_cluster(corep, &gdi_cl_len);
        var text_buf: [32]c.WCHAR = undefined; // max 16 scalars * 2 UTF-16 units
        var text_len: u32 = 0;
        if (gdi_cl_len > 1 and gdi_cl_ptr != null) {
            for (gdi_cl_ptr.?[0..gdi_cl_len]) |sc| {
                if (sc <= 0xFFFF) {
                    if (text_len < text_buf.len) {
                        text_buf[text_len] = @intCast(sc);
                        text_len += 1;
                    }
                } else {
                    const v = sc - 0x10000;
                    if (text_len + 1 < text_buf.len) {
                        text_buf[text_len] = @intCast(0xD800 + ((v >> 10) & 0x3FF));
                        text_buf[text_len + 1] = @intCast(0xDC00 + (v & 0x3FF));
                        text_len += 2;
                    }
                }
            }
        } else {
            if (scalar <= 0xFFFF) {
                text_buf[0] = @intCast(scalar);
                text_len = 1;
            } else {
                const v = scalar - 0x10000;
                text_buf[0] = @intCast(0xD800 + ((v >> 10) & 0x3FF));
                text_buf[1] = @intCast(0xDC00 + (v & 0x3FF));
                text_len = 2;
            }
        }

        // Draw emoji using D2D DrawText (supports color emoji natively)
        const rt_base: *c.ID2D1RenderTarget = @ptrCast(dc_rt.?);
        const vtbl = rt_base.lpVtbl.*;

        if (vtbl.BeginDraw) |f| f(rt_base);

        // Clear to transparent
        if (vtbl.Clear) |f| {
            const transparent = c.D2D1_COLOR_F{ .r = 0, .g = 0, .b = 0, .a = 0 };
            f(rt_base, &transparent);
        }

        // Create white brush for text (D2D will override with color emoji colors)
        var brush: ?*c.ID2D1SolidColorBrush = null;
        if (vtbl.CreateSolidColorBrush) |f| {
            const white = c.D2D1_COLOR_F{ .r = 1, .g = 1, .b = 1, .a = 1 };
            _ = f(rt_base, &white, null, &brush);
        }
        defer {
            if (brush) |b| {
                const base: *c.IUnknown = @ptrCast(b);
                _ = base.lpVtbl.*.Release.?(base);
            }
        }

        if (brush) |b| {
            const layout_rect = c.D2D1_RECT_F{
                .left = 0,
                .top = 0,
                .right = @floatFromInt(bmp_w),
                .bottom = @floatFromInt(bmp_h),
            };
            if (vtbl.DrawTextW) |draw_fn| {
                draw_fn(
                    rt_base,
                    &text_buf,
                    text_len,
                    text_format.?,
                    &layout_rect,
                    @ptrCast(b),
                    c.D2D1_DRAW_TEXT_OPTIONS_ENABLE_COLOR_FONT,
                    c.DWRITE_MEASURING_MODE_NATURAL,
                );
            }
        }

        var tag1: u64 = 0;
        var tag2: u64 = 0;
        if (vtbl.EndDraw) |f| {
            const hr_end = f(rt_base, &tag1, &tag2);
            if (hr_end != 0) {
                return false;
            }
        }

        // Scan the DIB to find the actual bounding box of non-zero pixels
        const pixels_ptr: [*]const u8 = @ptrCast(bits.?);
        const stride: usize = @intCast(bmp_w * 4);
        var min_x: i32 = bmp_w;
        var min_y: i32 = bmp_h;
        var max_x: i32 = 0;
        var max_y: i32 = 0;
        var y: i32 = 0;
        while (y < bmp_h) : (y += 1) {
            var x_i: i32 = 0;
            while (x_i < bmp_w) : (x_i += 1) {
                const off: usize = @intCast(y * bmp_w * 4 + x_i * 4);
                const b_val = pixels_ptr[off + 0];
                const g_val = pixels_ptr[off + 1];
                const r_val = pixels_ptr[off + 2];
                // DIB alpha channel: GDI sets this for color emoji, 0 for non-rendered
                const a_val = pixels_ptr[off + 3];
                if (r_val != 0 or g_val != 0 or b_val != 0 or a_val != 0) {
                    if (x_i < min_x) min_x = x_i;
                    if (x_i >= max_x) max_x = x_i + 1;
                    if (y < min_y) min_y = y;
                    if (y >= max_y) max_y = y + 1;
                }
            }
        }

        if (max_x <= min_x or max_y <= min_y) return false; // nothing rendered

        const gw: u32 = @intCast(max_x - min_x);
        const gh: u32 = @intCast(max_y - min_y);

        // Copy BGRA -> RGBA into glyph_tmp
        const needed: usize = @as(usize, gw) * @as(usize, gh) * 4;
        self.glyph_tmp.resize(self.alloc, needed) catch return false;

        // Tracks whether ANY pixel had genuine D2D color-font alpha (real
        // multi-hue color emoji), as opposed to every pixel needing the
        // luminance-synthesis fallback below (a plain monochrome glyph drawn
        // with the white brush — e.g. a CJK/symbol notdef fallback). This
        // distinguishes "true color emoji" from "GDI fallback for a glyph
        // missing from the base font" so the latter can be treated as a
        // normal grayscale glyph and take the highlight fg color.
        var saw_real_color_alpha = false;

        var dy: u32 = 0;
        while (dy < gh) : (dy += 1) {
            const src_y: usize = @intCast(@as(i32, @intCast(dy)) + min_y);
            var dx: u32 = 0;
            while (dx < gw) : (dx += 1) {
                const src_x: usize = @intCast(@as(i32, @intCast(dx)) + min_x);
                const src_off: usize = src_y * stride + src_x * 4;
                const dst_off: usize = @as(usize, dy) * @as(usize, gw) * 4 + @as(usize, dx) * 4;

                const b_val = pixels_ptr[src_off + 0];
                const g_val = pixels_ptr[src_off + 1];
                const r_val = pixels_ptr[src_off + 2];
                var a_val = pixels_ptr[src_off + 3];

                // GDI color emoji: alpha is set by the system.
                // Monochrome text: alpha=0 but RGB may be non-zero.
                // For monochrome, synthesize alpha from luminance.
                if (a_val == 0 and (r_val != 0 or g_val != 0 or b_val != 0)) {
                    a_val = @max(r_val, @max(g_val, b_val));
                } else if (a_val != 0) {
                    saw_real_color_alpha = true;
                }

                // BGRA → RGBA
                self.glyph_tmp.items[dst_off + 0] = r_val;
                self.glyph_tmp.items[dst_off + 1] = g_val;
                self.glyph_tmp.items[dst_off + 2] = b_val;
                self.glyph_tmp.items[dst_off + 3] = a_val;
            }
        }

        out_bitmap.pixels = self.glyph_tmp.items.ptr;
        out_bitmap.width = gw;
        out_bitmap.height = gh;
        out_bitmap.bearing_x = min_x;
        const ascent_i: i32 = @intFromFloat(@round(self.ascent_px));
        out_bitmap.bearing_y = ascent_i - min_y;
        out_bitmap.advance_26_6 = @as(i32, @intCast(self.cell_w_px)) * 64;
        out_bitmap.ascent_px = self.ascent_px;
        out_bitmap.descent_px = self.descent_px;

        if (saw_real_color_alpha) {
            // Genuine color-font glyph (real emoji): keep as RGBA.
            out_bitmap.pitch = @intCast(gw * 4);
            out_bitmap.bytes_per_pixel = 4;
        } else {
            // Monochrome fallback (notdef substitute, drawn with the white
            // brush): compact to a single grayscale/alpha channel so the
            // core does not tag it DECO_COLOR_EMOJI, and the normal
            // highlight-fg-color shader path (main.hlsl grayscale branch)
            // applies. R=G=B=A already for every pixel here (see synthesis
            // above), so the alpha channel alone is the correct grayscale
            // value — compact in place (dst index <= src index for all i).
            var i: usize = 0;
            const px_count: usize = @as(usize, gw) * @as(usize, gh);
            while (i < px_count) : (i += 1) {
                self.glyph_tmp.items[i] = self.glyph_tmp.items[i * 4 + 3];
            }
            out_bitmap.pitch = @intCast(gw);
            out_bitmap.bytes_per_pixel = 1;
        }

        return true;
    }

    /// Phase 2: Rasterize glyph via DWrite without atlas packing.
    /// Returns ClearType 3bpp bitmap data in self.glyph_tmp.
    /// What a glyph-run rasterization produced. `.empty` means DWrite gave
    /// back no coverage at all -- a space, or a colour glyph with no outline.
    /// The two callers answer that differently, so the helper does not decide.
    const GlyphRasterOutcome = enum { ok, empty };

    /// Rasterize one glyph index through DWrite. Caller must already hold
    /// self.mu.
    ///
    /// Writes bearing, advance, ascent and descent unconditionally -- both
    /// callers set those before their own empty check -- and on `.empty`
    /// leaves pixels, width, height, pitch and bytes_per_pixel untouched.
    ///
    /// `try_aliased_fallback` controls whether an empty ClearType bound is
    /// retried as ALIASED_1x1. The by-scalar path always retries; the by-id
    /// path skips it on a colour font, where the retry cannot succeed.
    fn rasterizeGlyphIndex(
        self: *Renderer,
        face: *c.IDWriteFontFace,
        glyph_index: c.UINT16,
        try_aliased_fallback: bool,
        out_bitmap: *core.GlyphBitmap,
    ) !GlyphRasterOutcome {
        var glyph_run: c.DWRITE_GLYPH_RUN = std.mem.zeroes(c.DWRITE_GLYPH_RUN);
        glyph_run.fontFace = face;
        glyph_run.fontEmSize = self.font_em_size;
        glyph_run.glyphCount = 1;
        var gi_arr: [1]c.UINT16 = .{glyph_index};
        var adv_arr: [1]c.FLOAT = .{@as(c.FLOAT, @floatFromInt(self.cell_w_px))};
        var off_arr: [1]c.DWRITE_GLYPH_OFFSET = .{.{ .advanceOffset = 0, .ascenderOffset = 0 }};
        glyph_run.glyphIndices = gi_arr[0..].ptr;
        glyph_run.glyphAdvances = adv_arr[0..].ptr;
        glyph_run.glyphOffsets = off_arr[0..].ptr;

        const dw = self.dwrite_factory orelse return error.DWriteFactoryNotReady;
        const dwtbl = dw.lpVtbl.*;
        var analysis: ?*c.IDWriteGlyphRunAnalysis = null;
        const create_analysis_fn = dwtbl.CreateGlyphRunAnalysis orelse return error.DWriteFactoryMissingCreateGlyphRunAnalysis;
        const hr_cgra = create_analysis_fn(dw, &glyph_run, 1.0, null, c.DWRITE_RENDERING_MODE_NATURAL_SYMMETRIC, c.DWRITE_MEASURING_MODE_NATURAL, 0.0, 0.0, &analysis);
        if (c.FAILED(hr_cgra) or analysis == null) return error.DWriteCreateGlyphRunAnalysisFailed;

        const rel_fn = analysis.?.lpVtbl.*.Release orelse return error.DWriteGlyphRunAnalysisMissingRelease;
        defer _ = rel_fn(analysis.?);

        var bounds: c.RECT = std.mem.zeroes(c.RECT);
        const atbl = analysis.?.lpVtbl.*;
        const get_bounds_fn = atbl.GetAlphaTextureBounds orelse return error.DWriteGlyphRunAnalysisMissingGetAlphaTextureBounds;
        const hr_bounds = get_bounds_fn(analysis.?, c.DWRITE_TEXTURE_CLEARTYPE_3x1, &bounds);
        if (c.FAILED(hr_bounds)) return error.DWriteGetAlphaTextureBoundsFailed;

        var bw_i32: i32 = bounds.right - bounds.left;
        var bh_i32: i32 = bounds.bottom - bounds.top;
        var bw: u32 = if (bw_i32 > 0) @as(u32, @intCast(bw_i32)) else 0;
        var bh: u32 = if (bh_i32 > 0) @as(u32, @intCast(bh_i32)) else 0;
        var use_aliased: bool = false;

        // ClearType returns empty bounds for color emoji (no outline).
        // Fallback to aliased (1 bpp grayscale) for monochrome emoji rendering.
        if (try_aliased_fallback and (bw == 0 or bh == 0)) {
            var aliased_bounds: c.RECT = std.mem.zeroes(c.RECT);
            const hr_aliased = get_bounds_fn(analysis.?, c.DWRITE_TEXTURE_ALIASED_1x1, &aliased_bounds);
            if (!c.FAILED(hr_aliased)) {
                bw_i32 = aliased_bounds.right - aliased_bounds.left;
                bh_i32 = aliased_bounds.bottom - aliased_bounds.top;
                bw = if (bw_i32 > 0) @as(u32, @intCast(bw_i32)) else 0;
                bh = if (bh_i32 > 0) @as(u32, @intCast(bh_i32)) else 0;
                if (bw > 0 and bh > 0) {
                    bounds = aliased_bounds;
                    use_aliased = true;
                }
            }
        }

        // Fill common metrics
        out_bitmap.bearing_x = bounds.left;
        out_bitmap.bearing_y = @as(i32, -bounds.top); // DWrite top -> FreeType bearing_y
        out_bitmap.advance_26_6 = @as(i32, @intCast(self.cell_w_px)) * 64;
        out_bitmap.ascent_px = self.ascent_px;
        out_bitmap.descent_px = self.descent_px;

        if (bw == 0 or bh == 0) return .empty;

        const create_alpha_fn = atbl.CreateAlphaTexture orelse return error.DWriteGlyphRunAnalysisMissingCreateAlphaTexture;
        const bpp: u32 = if (use_aliased) 1 else 3;
        const tex_type: c.DWRITE_TEXTURE_TYPE = if (use_aliased) c.DWRITE_TEXTURE_ALIASED_1x1 else c.DWRITE_TEXTURE_CLEARTYPE_3x1;
        const buf_size: usize = @as(usize, bw) * @as(usize, bh) * @as(usize, bpp);
        try self.glyph_tmp.resize(self.alloc, buf_size);
        const hr_tex = create_alpha_fn(analysis.?, tex_type, &bounds, self.glyph_tmp.items.ptr, @as(c.UINT32, @intCast(buf_size)));
        if (c.FAILED(hr_tex)) return error.DWriteCreateAlphaTextureFailed;

        out_bitmap.pixels = self.glyph_tmp.items.ptr;
        out_bitmap.width = bw;
        out_bitmap.height = bh;
        out_bitmap.pitch = @as(i32, @intCast(bw * bpp));
        out_bitmap.bytes_per_pixel = bpp;
        return .ok;
    }

    pub fn rasterizeGlyphOnly(self: *Renderer, scalar: u32, style_flags: u32, corep: ?*core.zonvie_core, out_bitmap: *core.GlyphBitmap) !void {
        self.mu.lockUncancelable(core.clock.io());
        defer self.mu.unlock(core.clock.io());

        const face: *c.IDWriteFontFace = self.selectFontFace(style_flags) orelse return error.NoFont;

        // scalar -> glyph_index (feature-aware via IDWriteTextAnalyzer when features set)
        const glyph_index = self.getGlyphIndexForScalar(face, scalar) catch |err| {
            if (applog.isEnabled()) applog.appLog("[dwrite] getGlyphIndexForScalar failed in rasterizeGlyphOnly: {any}\n", .{err});
            return err;
        };

        // Emoji codepoints: always prefer system color emoji (D2D + Segoe UI Emoji).
        // Also check the cluster context: flush sets emoji_cluster_len > 0 for
        // VS16-qualified and multi-scalar emoji clusters (e.g., ☀️ = U+2600 + FE0F).
        var emoji_cl_len: u8 = 0;
        _ = core.zonvie_core_get_emoji_cluster(corep, &emoji_cl_len);
        if (isEmojiPresentation(scalar) or emoji_cl_len > 0) {
            if (self.rasterizeColorEmojiGDI(scalar, corep, out_bitmap)) {
                return;
            }
        }

        // .notdef (glyph_index==0): font doesn't have this glyph.
        // Try GDI color emoji fallback for non-emoji non-ASCII scalars.
        if (glyph_index == 0 and scalar > 0xFF) {
            if (self.rasterizeColorEmojiGDI(scalar, corep, out_bitmap)) {
                return;
            }
        }

        // The by-scalar path always retries an empty ClearType bound as
        // aliased, then falls back to GDI colour emoji before giving up.
        const outcome = try self.rasterizeGlyphIndex(face, glyph_index, true, out_bitmap);
        if (outcome == .empty) {
            // DWrite produced an empty bitmap. For non-ASCII scalars this may
            // be a colour emoji that DWrite ClearType/aliased cannot render.
            if (scalar > 0xFF) {
                if (self.rasterizeColorEmojiGDI(scalar, corep, out_bitmap)) return;
            }
            // Empty glyph (space etc.)
            out_bitmap.pixels = null;
            out_bitmap.width = 0;
            out_bitmap.height = 0;
            out_bitmap.pitch = 0;
            out_bitmap.bytes_per_pixel = 3;
        }
    }

    /// Phase 2: Upload glyph bitmap to atlas_cpu at (dest_x, dest_y).
    /// Handles ClearType RGB 3bpp -> RGBA 4bpp conversion.
    pub fn uploadAtlasRegion(self: *Renderer, dest_x: u32, dest_y: u32, width: u32, height: u32, bitmap: *const core.GlyphBitmap) !void {
        self.mu.lockUncancelable(core.clock.io());
        defer self.mu.unlock(core.clock.io());

        if (dest_x +| width > self.atlas_w or dest_y +| height > self.atlas_h) {
            if (applog.isEnabled()) applog.appLog(
                "[atlas] uploadAtlasRegion: rejecting out-of-bounds region dest=({d},{d}) size={d}x{d} atlas={d}x{d}\n",
                .{ dest_x, dest_y, width, height, self.atlas_w, self.atlas_h },
            );
            return;
        }

        const pixels = bitmap.pixels orelse return;
        const bpp = bitmap.bytes_per_pixel;
        const pitch: usize = if (bitmap.pitch >= 0) @as(usize, @intCast(bitmap.pitch)) else @as(usize, @intCast(-bitmap.pitch));

        // Write to atlas_cpu (RGBA 4bpp)
        var y: u32 = 0;
        while (y < height) : (y += 1) {
            const src_row: usize = if (bitmap.pitch >= 0) @as(usize, y) else @as(usize, height - 1 - y);
            const dst_row_base: usize = @as(usize, dest_y + y) * @as(usize, self.atlas_w);

            if (bpp == 3) {
                // ClearType RGB -> RGBA (SIMD: 4 pixels per iteration)
                var x: u32 = 0;
                while (x + 4 <= width) {
                    const src_base = src_row * pitch + @as(usize, x) * 3;
                    const dst_base = (dst_row_base + @as(usize, dest_x + x)) * 4;
                    const s = pixels[src_base..];

                    // Gather RGB channels from stride-3 source
                    const r4 = @Vector(4, u8){ s[0], s[3], s[6], s[9] };
                    const g4 = @Vector(4, u8){ s[1], s[4], s[7], s[10] };
                    const b4 = @Vector(4, u8){ s[2], s[5], s[8], s[11] };
                    // Alpha = max(R, G, B) — SIMD max
                    const a4 = @max(r4, @max(g4, b4));

                    // Scatter RGBA to stride-4 destination
                    const d = self.atlas_cpu.items[dst_base..];
                    inline for (0..4) |i| {
                        d[i * 4 + 0] = r4[i];
                        d[i * 4 + 1] = g4[i];
                        d[i * 4 + 2] = b4[i];
                        d[i * 4 + 3] = a4[i];
                    }
                    x += 4;
                }
                // Scalar tail
                while (x < width) : (x += 1) {
                    const dst_off = (dst_row_base + @as(usize, dest_x + x)) * 4;
                    const src_off = src_row * pitch + @as(usize, x) * 3;
                    const r = pixels[src_off];
                    const g = pixels[src_off + 1];
                    const b = pixels[src_off + 2];
                    self.atlas_cpu.items[dst_off + 0] = r;
                    self.atlas_cpu.items[dst_off + 1] = g;
                    self.atlas_cpu.items[dst_off + 2] = b;
                    self.atlas_cpu.items[dst_off + 3] = @max(r, @max(g, b));
                }
            } else if (bpp >= 4) {
                // RGBA direct copy (color emoji)
                var x: u32 = 0;
                while (x < width) : (x += 1) {
                    const dst_off = (dst_row_base + @as(usize, dest_x + x)) * 4;
                    const src_off = src_row * pitch + @as(usize, x) * 4;
                    self.atlas_cpu.items[dst_off + 0] = pixels[src_off + 0];
                    self.atlas_cpu.items[dst_off + 1] = pixels[src_off + 1];
                    self.atlas_cpu.items[dst_off + 2] = pixels[src_off + 2];
                    self.atlas_cpu.items[dst_off + 3] = pixels[src_off + 3];
                }
            } else {
                // Grayscale or other: replicate to RGBA
                var x: u32 = 0;
                while (x < width) : (x += 1) {
                    const dst_off = (dst_row_base + @as(usize, dest_x + x)) * 4;
                    const src_off = src_row * pitch + @as(usize, x) * bpp;
                    const v = pixels[src_off];
                    self.atlas_cpu.items[dst_off + 0] = v;
                    self.atlas_cpu.items[dst_off + 1] = v;
                    self.atlas_cpu.items[dst_off + 2] = v;
                    self.atlas_cpu.items[dst_off + 3] = v;
                }
            }
        }

        self.atlas_content_generation +%= 1;

        // Mark dirty rect for GPU upload
        try self.pending_uploads.append(self.alloc, c.D2D1_RECT_U{
            .left = dest_x,
            .top = dest_y,
            .right = dest_x + width,
            .bottom = dest_y + height,
        });
        self.atlas_version +%= 1;
    }

    /// Phase 2: Recreate atlas texture with given dimensions.
    pub fn recreateAtlasTexture(self: *Renderer, atlas_w: u32, atlas_h: u32) !void {
        self.mu.lockUncancelable(core.clock.io());

        // Resize CPU atlas buffer before updating dimensions to avoid inconsistency
        const total = @as(usize, atlas_w) * @as(usize, atlas_h) * 4;
        if (self.atlas_cpu.items.len != total) {
            self.atlas_cpu.resize(self.alloc, total) catch {
                // ArrayList resize is failure-atomic. Keep the entire old
                // atlas generation intact so a queued retry does not corrupt
                // the last committed frame before any new state exists.
                if (applog.isEnabled()) applog.appLog("[atlas] recreateAtlasTexture: resize to {d}x{d} failed, keeping {d}x{d}\n", .{ atlas_w, atlas_h, self.atlas_w, self.atlas_h });
                self.mu.unlock(core.clock.io());
                return error.AtlasCpuResizeFailed;
            };
        }

        // Resize succeeded (or same size): commit new dimensions
        self.atlas_w = atlas_w;
        self.atlas_h = atlas_h;

        // Clear pending uploads
        self.pending_upload_base_seq += self.pending_uploads.items.len;
        self.pending_uploads.clearRetainingCapacity();

        if (self.atlas_cpu.items.len > 0) {
            @memset(self.atlas_cpu.items, 0);
        }
        self.atlas_content_generation +%= 1;

        const rebuild_legacy = self.rt != null and self.d2d_device_ctx == null;
        self.atlas_reset_pending = true;
        self.atlas_reset_generation +%= 1;
        self.mu.unlock(core.clock.io());

        if (rebuild_legacy) {
            try self.recreateRenderTarget();
        }
    }

    pub fn renderVertices(self: *Renderer, main: []const core.Vertex, cursor: []const core.Vertex) !void {
        self.mu.lockUncancelable(core.clock.io());
        const needs_target = self.rt == null;
        self.mu.unlock(core.clock.io());
        if (needs_target) {
            try self.recreateRenderTarget();
        }

        self.mu.lockUncancelable(core.clock.io());
        errdefer self.mu.unlock(core.clock.io());

        // IMPORTANT: Upload pending atlas dirty rects BEFORE BeginDraw.
        // NOTE: renderVertices already holds self.mu, so call the _Locked variant.
        self.flushPendingAtlasUploadsLocked();

        const rt_hwnd = self.rt orelse return error.NoRenderTarget;
        const atlas = self.atlas_bitmap orelse return error.NoAtlas;
        const brush = self.solid_brush orelse return error.NoBrush;

        const rt_base: *c.ID2D1RenderTarget = @ptrCast(rt_hwnd);
        const vtbl = rt_base.lpVtbl.*;

        // BeginDraw
        if (vtbl.BeginDraw) |begin_fn| begin_fn(rt_base);

        // ★ FillOpacityMask requirement: AntialiasMode must be ALIASED
        // Failure causes deferred draw command failure and EndDraw returns 0x88990001
        if (vtbl.SetAntialiasMode) |set_aa_fn| {
            set_aa_fn(rt_base, c.D2D1_ANTIALIAS_MODE_ALIASED);
        }

        // Client size
        var rc: c.RECT = undefined;
        _ = c.GetClientRect(self.hwnd, &rc);

        const client_w: f32 = @floatFromInt(@max(1, rc.right - rc.left));
        const client_h: f32 = @floatFromInt(@max(1, rc.bottom - rc.top));

        // Optional clear
        if (vtbl.Clear) |clear_fn| {
            const c0 = c.D2D1_COLOR_F{ .r = 0, .g = 0, .b = 0, .a = 1 };
            clear_fn(rt_base, &c0);
        }

        // Draw
        try self.drawVertexList(rt_base, atlas, brush, client_w, client_h, main);
        try self.drawVertexList(rt_base, atlas, brush, client_w, client_h, cursor);

        // EndDraw
        var tag1: u64 = 0;
        var tag2: u64 = 0;
        const hr = if (vtbl.EndDraw) |end_fn| end_fn(rt_base, &tag1, &tag2) else 0;

        if (c.FAILED(hr)) {
            const hr_u: u32 = @bitCast(hr);
            if (applog.isEnabled()) applog.appLog("[d2d] EndDraw FAILED hr=0x{x} tags=({d},{d})\n", .{ hr_u, tag1, tag2 });

            // D2DERR_RECREATE_TARGET (0x8899000C or 0x88990001)
            if (hr_u == 0x8899000C or hr_u == 0x88990001) {
                self.mu.unlock(core.clock.io());
                _ = self.recreateRenderTarget() catch {};
                return;
            }
            return error.D2DEndDrawFailed;
        }

        self.mu.unlock(core.clock.io());
    }

    fn drawVertexList(
        self: *Renderer,
        rt: *c.ID2D1RenderTarget,
        atlas: *c.ID2D1Bitmap,
        brush: *c.ID2D1SolidColorBrush,
        client_w: f32,
        client_h: f32,
        verts: []const core.Vertex,
    ) !void {
        if (verts.len < 6) return;

        const log_active = applog.isEnabled();

        const rtv = rt.lpVtbl.*;

        // Avoid GetSize (it can crash in some states); use caller-provided client size.
        const w: f32 = client_w;
        const h: f32 = client_h;

        // IMPORTANT: Do NOT call atlas->GetPixelSize().
        // Use instance atlas size fields to avoid COM/VTBL mismatch crashes.
        const atlas_w: f32 = @floatFromInt(self.atlas_w);
        const atlas_h: f32 = @floatFromInt(self.atlas_h);

        var i: usize = 0;
        while (i + 5 < verts.len) : (i += 6) {
            const quad = verts[i .. i + 6];

            // Compute bounds from all 6 vertices (do NOT assume ordering).
            var min_x: f32 = quad[0].position[0];
            var max_x: f32 = quad[0].position[0];
            var min_y: f32 = quad[0].position[1];
            var max_y: f32 = quad[0].position[1];

            var min_u: f32 = quad[0].texCoord[0];
            var max_u: f32 = quad[0].texCoord[0];
            var min_v: f32 = quad[0].texCoord[1];
            var max_v: f32 = quad[0].texCoord[1];

            // BG marker: ONLY U < 0 means BG.
            // V may legitimately be negative depending on UV conventions.
            var any_bg_marker: bool = (min_u < 0.0);

            for (quad[1..]) |vtx| {
                min_x = @min(min_x, vtx.position[0]);
                max_x = @max(max_x, vtx.position[0]);
                min_y = @min(min_y, vtx.position[1]);
                max_y = @max(max_y, vtx.position[1]);

                min_u = @min(min_u, vtx.texCoord[0]);
                max_u = @max(max_u, vtx.texCoord[0]);
                min_v = @min(min_v, vtx.texCoord[1]);
                max_v = @max(max_v, vtx.texCoord[1]);

                if (vtx.texCoord[0] < 0.0) any_bg_marker = true;
            }

            // Reject NaNs/Infs early (D2D can crash on them).
            if (!std.math.isFinite(min_x) or !std.math.isFinite(max_x) or
                !std.math.isFinite(min_y) or !std.math.isFinite(max_y) or
                !std.math.isFinite(min_u) or !std.math.isFinite(max_u) or
                !std.math.isFinite(min_v) or !std.math.isFinite(max_v))
            {
                continue;
            }

            // NDC(-1..1) -> px; flip Y for top-left origin.
            const x_left = (min_x * 0.5 + 0.5) * w;
            const x_right = (max_x * 0.5 + 0.5) * w;
            const y_top = (1.0 - (max_y * 0.5 + 0.5)) * h;
            const y_bottom = (1.0 - (min_y * 0.5 + 0.5)) * h;

            const left = @min(x_left, x_right);
            const right = @max(x_left, x_right);
            const top = @min(y_top, y_bottom);
            const bottom = @max(y_top, y_bottom);

            if (right <= left or bottom <= top) continue;

            const dst = c.D2D1_RECT_F{ .left = left, .top = top, .right = right, .bottom = bottom };

            // Color: use first vertex
            const col = quad[0].color;
            const a: f32 = std.math.clamp(col[3], 0.0, 1.0);
            const r: f32 = std.math.clamp(col[0], 0.0, 1.0);
            const g: f32 = std.math.clamp(col[1], 0.0, 1.0);
            const b: f32 = std.math.clamp(col[2], 0.0, 1.0);

            if (brush.lpVtbl.*.SetColor) |set_color_fn| {
                set_color_fn(brush, &c.D2D1_COLOR_F{ .r = r, .g = g, .b = b, .a = a });
            }

            // ---- Debug for root-cause: first 4 quads ----
            if (i < 24 and log_active) {
                applog.appLog(
                    "[d2d] quad{d} any_bg={any} uv(min/max)=({d},{d})..({d},{d})\n",
                    .{ i / 6, any_bg_marker, min_u, min_v, max_u, max_v },
                );
            }

            // BG quad: FillRectangle
            if (any_bg_marker) {
                if (i == 0 and log_active) {
                    applog.appLog("[d2d] quad0 BG FillRectangle dst=({d},{d},{d},{d})\n", .{
                        dst.left, dst.top, dst.right, dst.bottom,
                    });
                }
                if (rtv.FillRectangle) |fill_rect_fn| {
                    fill_rect_fn(rt, &dst, @as(*c.ID2D1Brush, @ptrCast(brush)));
                }
                continue;
            }

            // Glyph quad
            const u_min = std.math.clamp(min_u, 0.0, 1.0);
            const u_max = std.math.clamp(max_u, 0.0, 1.0);
            const v_min = std.math.clamp(min_v, 0.0, 1.0);
            const v_max = std.math.clamp(max_v, 0.0, 1.0);

            if (u_max <= u_min or v_max <= v_min) {
                if (i < 24 and log_active) {
                    applog.appLog(
                        "[d2d] quad{d} UV degenerate (clamped) u={d}..{d} v={d}..{d}\n",
                        .{ i / 6, u_min, u_max, v_min, v_max },
                    );
                }
                continue;
            }

            const src = c.D2D1_RECT_F{
                .left = u_min * atlas_w,
                .top = v_min * atlas_h,
                .right = u_max * atlas_w,
                .bottom = v_max * atlas_h,
            };

            const is_color_emoji = (quad[0].deco_flags & core.DECO_COLOR_EMOJI) != 0;

            if (is_color_emoji) {
                // Color emoji: use DrawBitmap to render RGBA directly from atlas
                if (rtv.DrawBitmap) |draw_bmp_fn| {
                    if (i < 24 and log_active) {
                        applog.appLog(
                            "[d2d] quad{d} COLOR_EMOJI DrawBitmap dst=({d},{d},{d},{d}) src=({d},{d},{d},{d})\n",
                            .{
                                i / 6,
                                dst.left,
                                dst.top,
                                dst.right,
                                dst.bottom,
                                src.left,
                                src.top,
                                src.right,
                                src.bottom,
                            },
                        );
                    }

                    draw_bmp_fn(
                        rt,
                        atlas,
                        &dst,
                        1.0, // opacity
                        c.D2D1_BITMAP_INTERPOLATION_MODE_LINEAR,
                        &src,
                    );
                }
            } else if (rtv.FillOpacityMask) |fill_mask_fn| {
                // Regular glyph: FillOpacityMask (alpha-only rendering with brush color)
                if (i < 24 and log_active) {
                    applog.appLog(
                        "[d2d] quad{d} GLYPH FillOpacityMask dst=({d},{d},{d},{d}) src=({d},{d},{d},{d})\n",
                        .{
                            i / 6,
                            dst.left,
                            dst.top,
                            dst.right,
                            dst.bottom,
                            src.left,
                            src.top,
                            src.right,
                            src.bottom,
                        },
                    );
                }

                fill_mask_fn(
                    rt,
                    atlas,
                    @as(*c.ID2D1Brush, @ptrCast(brush)),
                    c.D2D1_OPACITY_MASK_CONTENT_TEXT_GDI_COMPATIBLE,
                    &dst,
                    &src,
                );

                if (i < 24 and log_active) {
                    applog.appLog("[d2d] quad{d} FillOpacityMask returned\n", .{i / 6});
                }
            }
        }

        if (log_active) {
            // DEBUG: count glyph vertices inside THIS vertex list (texCoord >= 0)
            var glyph_vtx: usize = 0;
            for (verts) |v| {
                if (v.texCoord[0] >= 0.0 and v.texCoord[1] >= 0.0) {
                    glyph_vtx += 1;
                }
            }
            applog.appLog("[d2d] drawVertexList: total_vtx={d} glyph_vtx={d}\n", .{ verts.len, glyph_vtx });
        }
    }

    // Upload pending atlas rects to the D2D bitmap since the last D2D cursor.
    // Does NOT drain the queue — other consumers (D3D windows) read independently.
    fn flushPendingAtlasUploadsLocked(self: *Renderer) void {
        const bmp = self.atlas_bitmap orelse return;
        const head_seq = self.pending_upload_base_seq + self.pending_uploads.items.len;
        if (self.d2d_upload_cursor >= head_seq) return;

        const bvtbl = bmp.lpVtbl.*;
        const copy_fn = bvtbl.CopyFromMemory orelse return;

        // If cursor fell behind base (atlas reset), upload the full bitmap.
        if (self.d2d_upload_cursor < self.pending_upload_base_seq) {
            if (self.atlas_cpu.items.len > 0) {
                const full_rect = c.D2D1_RECT_U{
                    .left = 0,
                    .top = 0,
                    .right = self.atlas_w,
                    .bottom = self.atlas_h,
                };
                const hr = copy_fn(
                    bmp,
                    &full_rect,
                    self.atlas_cpu.items.ptr,
                    self.atlas_w * 4,
                );
                if (hr != 0) return;
            }
            self.d2d_upload_cursor = head_seq;
            return;
        }

        const start_idx = self.d2d_upload_cursor - self.pending_upload_base_seq;
        for (self.pending_uploads.items[start_idx..]) |r| {
            const src_off = (@as(usize, r.top) * @as(usize, self.atlas_w) + @as(usize, r.left)) * 4;
            const hr = copy_fn(
                bmp,
                &r,
                self.atlas_cpu.items.ptr + src_off,
                self.atlas_w * 4,
            );
            if (hr != 0) return;
            self.d2d_upload_cursor += 1;
        }
    }

    /// Upload atlas dirty rects added since `since_seq` to the given D3D context.
    /// Returns the new head sequence (caller should store this as its cursor).
    /// If `since_seq < pending_upload_base_seq`, entries were lost (atlas reset);
    /// the caller must do a full atlas upload via uploadFullAtlasToD3D and use the
    /// returned head_seq as its new cursor.
    fn flushPendingAtlasUploadsSinceToD3DLocked(
        self: *Renderer,
        d3d: anytype,
        since_seq: u64,
    ) D3DUploadResult {
        const head_seq = self.pending_upload_base_seq + self.pending_uploads.items.len;
        if (since_seq >= head_seq) return .{ .cursor = head_seq, .success = true };

        // Cursor is behind base: entries were discarded (atlas reset).
        // Caller must use uploadFullAtlasToD3D to recover.
        if (since_seq < self.pending_upload_base_seq) return .{ .cursor = since_seq, .success = false };

        const start_idx = since_seq - self.pending_upload_base_seq;
        const pending = self.pending_uploads.items[start_idx..];

        // Bound per-consumer GPU calls and atlas-mutex hold time. A lagging or
        // newly-created window otherwise replays every historical glyph rect.
        // Once rect count or covered area is substantial, one full upload is
        // cheaper and has deterministic call count.
        if (render_pipeline_helpers.shouldUseFullAtlasUpload(pending, self.atlas_w, self.atlas_h)) {
            if (applog.isEnabled()) applog.appLog(
                "[atlas] flushSince: coalescing {d} rects into full upload\n",
                .{pending.len},
            );
            return self.uploadFullAtlasToD3DLocked(d3d);
        }

        if (applog.isEnabled()) applog.appLog(
            "[atlas] flushSince: since={d} base={d} head={d} uploading={d}\n",
            .{ since_seq, self.pending_upload_base_seq, head_seq, self.pending_uploads.items.len - start_idx },
        );

        var log_idx: usize = 0;
        for (pending) |r| {
            const w: u32 = r.right - r.left;
            const h: u32 = r.bottom - r.top;
            if (w == 0 or h == 0) continue;

            if (log_idx < 8 and applog.isEnabled()) {
                applog.appLog(
                    "[atlas]   upload[{d}] (x={d},y={d},w={d},h={d})\n",
                    .{ log_idx, r.left, r.top, w, h },
                );
            }
            log_idx += 1;

            const src_off = (@as(usize, r.top) * @as(usize, self.atlas_w) + @as(usize, r.left)) * 4;
            const src_ptr: [*]const u8 = self.atlas_cpu.items.ptr + src_off;
            if (!d3d.atlasUploadRect(r.left, r.top, w, h, src_ptr, self.atlas_w * 4)) {
                return .{ .cursor = since_seq, .success = false };
            }
        }

        return .{ .cursor = head_seq, .success = true };
    }

    /// Public wrapper: upload atlas dirty rects added since `since_seq`.
    /// Returns the new head sequence for the caller to store as its cursor.
    pub const D3DUploadResult = struct {
        cursor: u64,
        success: bool,
    };

    pub fn flushPendingAtlasUploadsSinceToD3D(self: *Renderer, d3d: anytype, since_seq: u64) D3DUploadResult {
        self.mu.lockUncancelable(core.clock.io());
        defer self.mu.unlock(core.clock.io());
        return self.flushPendingAtlasUploadsSinceToD3DLocked(d3d, since_seq);
    }

    /// Upload the entire atlas to a D3D11 renderer.
    /// Use this for external windows that need the full atlas texture.
    pub fn uploadFullAtlasToD3D(self: *Renderer, d3d: anytype) D3DUploadResult {
        self.mu.lockUncancelable(core.clock.io());
        defer self.mu.unlock(core.clock.io());

        return self.uploadFullAtlasToD3DLocked(d3d);
    }

    fn uploadFullAtlasToD3DLocked(self: *Renderer, d3d: anytype) D3DUploadResult {
        if (self.atlas_cpu.items.len == 0) return .{ .cursor = 0, .success = false };

        if (applog.isEnabled()) applog.appLog(
            "[atlas] uploadFullAtlasToD3D: uploading full atlas {d}x{d}\n",
            .{ self.atlas_w, self.atlas_h },
        );

        // Upload the entire atlas as a single rect
        const success = d3d.atlasUploadRect(0, 0, self.atlas_w, self.atlas_h, self.atlas_cpu.items.ptr, self.atlas_w * 4);
        return .{
            .cursor = self.pending_upload_base_seq + self.pending_uploads.items.len,
            .success = success,
        };
    }

    pub fn ascentPx(self: *Renderer) f32 {
        return self.ascent_px;
    }
    pub fn descentPx(self: *Renderer) f32 {
        return self.descent_px;
    }

    pub fn onResize(self: *Renderer) void {
        self.mu.lockUncancelable(core.clock.io());
        const rt = self.rt orelse {
            self.mu.unlock(core.clock.io());
            return;
        };
        self.mu.unlock(core.clock.io());

        const hwnd: c.HWND = self.hwnd;
        var rc: c.RECT = undefined;
        _ = c.GetClientRect(hwnd, &rc);

        const size = c.D2D1_SIZE_U{
            .width = @intCast(@max(1, rc.right - rc.left)),
            .height = @intCast(@max(1, rc.bottom - rc.top)),
        };
        const vtbl = rt.lpVtbl.*;
        if (vtbl.Resize) |resize_fn| {
            const hr = resize_fn(rt, &size);

            // D2DERR_RECREATE_TARGET (0x8899000C)
            const hr_u: u32 = @bitCast(hr);
            if (hr_u == 0x8899000C) {
                _ = self.recreateRenderTarget() catch {};
            }
        }
    }

    pub fn setFontUtf8(self: *Renderer, name_utf8: []const u8, point_size: f32) !void {
        return self.setFontUtf8WithFeatures(name_utf8, point_size, "");
    }

    pub fn setFontUtf8WithFeatures(self: *Renderer, name_utf8: []const u8, point_size: f32, features_str: []const u8) !void {
        return self.setFontUtf8WithStyle(name_utf8, point_size, features_str, false, false);
    }

    /// Like setFontUtf8WithFeatures but with an explicit base weight/slant, used
    /// when the user picks a Bold/Italic face in the font panel. bold/italic
    /// map to DWrite weight/style for the base font face and text format.
    pub fn setFontUtf8WithStyle(self: *Renderer, name_utf8: []const u8, point_size: f32, features_str: []const u8, bold: bool, italic: bool) !void {
        self.mu.lockUncancelable(core.clock.io());
        defer self.mu.unlock(core.clock.io());

        if (self.dwrite_factory == null) return error.NotInitialized;

        const dw_weight: c.DWRITE_FONT_WEIGHT = if (bold) c.DWRITE_FONT_WEIGHT_BOLD else c.DWRITE_FONT_WEIGHT_NORMAL;
        const dw_style: c.DWRITE_FONT_STYLE = if (italic) c.DWRITE_FONT_STYLE_ITALIC else c.DWRITE_FONT_STYLE_NORMAL;

        // DPI scaling: scale point size to physical pixels
        const scaled_size: f32 = emSizePxForPointSize(self.dpi, point_size);

        // Early return if font is unchanged - preserve pre-warmed caches
        if (self.font_face != null and
            self.base_point_size == point_size and
            self.font_em_size == scaled_size and
            self.base_bold == bold and self.base_italic == italic and
            features_str.len == 0 and self.font_feature_count == 0 and
            self.font_name_utf8_len == @as(u32, @intCast(name_utf8.len)) and
            std.mem.eql(u8, self.font_name_utf8[0..self.font_name_utf8_len], name_utf8))
        {
            return; // font unchanged - preserve pre-warmed caches
        }

        const name_w = try utf8ToUtf16Alloc(self.alloc, name_utf8);
        defer self.alloc.free(name_w);

        const factory = self.dwrite_factory orelse return error.NotInitialized;

        // --- build new resources into locals first (transaction) ---
        var new_fmt: ?*c.IDWriteTextFormat = null;
        var new_face: ?*c.IDWriteFontFace = null;

        // If we fail after creating something, release locals.
        errdefer safeRelease(new_fmt);
        errdefer safeRelease(new_face);

        // CreateTextFormat (scaled for DPI)
        const vtbl = factory.lpVtbl.*;
        const create_fn = vtbl.CreateTextFormat orelse return error.DWriteFactoryMissingCreateTextFormat;

        const hr = create_fn(
            factory,
            @ptrCast(name_w.ptr),
            null,
            dw_weight,
            dw_style,
            c.DWRITE_FONT_STRETCH_NORMAL,
            scaled_size,
            @ptrCast(L("en-us")),
            &new_fmt,
        );
        if (hr != 0 or new_fmt == null) return error.DWriteCreateTextFormatFailed;

        // Build font_face from system font collection using the same family name.
        var sys_fc: ?*c.IDWriteFontCollection = null;
        const get_fc_fn = factory.lpVtbl.*.GetSystemFontCollection orelse
            return error.DWriteFactoryMissingGetSystemFontCollection;

        const hr_fc = get_fc_fn(factory, &sys_fc, c.FALSE);
        if (c.FAILED(hr_fc) or sys_fc == null) return error.DWriteGetSystemFontCollectionFailed;
        defer safeRelease(sys_fc);

        const fc = sys_fc.?;

        var index: u32 = 0;
        var exists: c.BOOL = c.FALSE;
        const find_fn = fc.lpVtbl.*.FindFamilyName orelse return error.DWriteFontCollectionMissingFindFamilyName;

        const hr_find = find_fn(fc, @ptrCast(name_w.ptr), &index, &exists);
        if (c.FAILED(hr_find) or exists == c.FALSE) return error.DWriteFamilyNotFound;

        var family: ?*c.IDWriteFontFamily = null;
        const get_family_fn = fc.lpVtbl.*.GetFontFamily orelse return error.DWriteFontCollectionMissingGetFontFamily;

        const hr_fam = get_family_fn(fc, index, &family);
        if (c.FAILED(hr_fam) or family == null) return error.DWriteGetFontFamilyFailed;
        defer safeRelease(family);

        var font: ?*c.IDWriteFont = null;
        const get_first_fn = family.?.lpVtbl.*.GetFirstMatchingFont orelse
            return error.DWriteFontFamilyMissingGetFirstMatchingFont;

        const hr_font = get_first_fn(
            family.?,
            dw_weight,
            c.DWRITE_FONT_STRETCH_NORMAL,
            dw_style,
            &font,
        );
        if (c.FAILED(hr_font) or font == null) return error.DWriteGetFontFailed;
        defer safeRelease(font);

        const create_face_fn = font.?.lpVtbl.*.CreateFontFace orelse return error.DWriteFontMissingCreateFontFace;
        const hr_face = create_face_fn(font.?, &new_face);
        if (c.FAILED(hr_face) or new_face == null) return error.DWriteCreateFontFaceFailed;

        // NOTE: Bold/Italic/Bold+Italic font variants are created eagerly
        // via ensureStyledFontFaces() at the end of this function.

        // Compute ascent/descent in pixels from design units.
        var fm: c.DWRITE_FONT_METRICS = undefined;
        const get_metrics_face_fn = new_face.?.lpVtbl.*.GetMetrics orelse return error.DWriteFontFaceMissingGetMetrics;
        get_metrics_face_fn(new_face.?, &fm);

        var new_ascent_px: f32 = 0.0;
        var new_descent_px: f32 = 0.0;

        const du_per_em: f32 = @floatFromInt(fm.designUnitsPerEm);
        if (du_per_em > 0.0) {
            new_ascent_px = scaled_size * (@as(f32, @floatFromInt(fm.ascent)) / du_per_em);
            new_descent_px = scaled_size * (@as(f32, @floatFromInt(fm.descent)) / du_per_em);
        }

        // --- commit (only here we touch self.*) ---
        safeRelease(self.text_format);
        safeRelease(self.font_face);
        safeRelease(self.bold_font_face);
        safeRelease(self.italic_font_face);
        safeRelease(self.bold_italic_font_face);

        self.text_format = new_fmt;
        self.font_face = new_face;
        // Reset styled fonts (will be lazy-loaded on first use)
        self.bold_font_face = null;
        self.italic_font_face = null;
        self.bold_italic_font_face = null;
        self.styled_fonts_initialized = false;
        self.has_color_tables = null; // reset — new font may differ
        new_fmt = null;
        new_face = null;

        self.font_em_size = scaled_size;
        self.emoji_font_size = 0; // reset: will be recomputed on next emoji render
        self.base_point_size = point_size;
        self.base_bold = bold;
        self.base_italic = italic;
        self.ascent_px = new_ascent_px;
        self.descent_px = new_descent_px;

        // Store font name for IME overlay (copy up to 63 chars + null)
        @memset(&self.font_name, 0);
        const copy_len = @min(name_w.len, self.font_name.len - 1);
        @memcpy(self.font_name[0..copy_len], name_w[0..copy_len]);

        // Update font change tracking (UTF-8 name + generation counter)
        const utf8_copy_len = @min(name_utf8.len, self.font_name_utf8.len);
        @memset(&self.font_name_utf8, 0);
        @memcpy(self.font_name_utf8[0..utf8_copy_len], name_utf8[0..utf8_copy_len]);
        self.font_name_utf8_len = @intCast(utf8_copy_len);
        self.font_generation +%= 1;

        // Parse and store OpenType features
        self.font_feature_count = 0;
        if (features_str.len > 0) {
            self.parseFontFeatures(features_str);
        }
        // Ensure text analyzer is available when features are set
        if (self.font_feature_count > 0 and self.text_analyzer == null) {
            const dw_factory = self.dwrite_factory orelse return error.NotInitialized;
            var analyzer: ?*c.IDWriteTextAnalyzer = null;
            const create_analyzer_fn = dw_factory.lpVtbl.*.CreateTextAnalyzer orelse return error.DWriteFactoryMissingCreateTextAnalyzer;
            const hr_ta = create_analyzer_fn(dw_factory, &analyzer);
            if (!c.FAILED(hr_ta) and analyzer != null) {
                self.text_analyzer = analyzer;
            }
        }

        try self.recomputeCellMetrics();

        // Invalidate GSUB lig trigger cache (font faces changed).
        self.gsub_cache = [_]GsubCacheEntry{.{}} ** 4;

        // Eagerly create Bold/Italic/BoldItalic font faces now instead of deferring
        // to the first flush. Moves ~4ms of DWrite font matching out of the hot path.
        self.ensureStyledFontFaces();
    }

    /// Parse comma-separated features string into font_features array.
    /// Format: "+liga,-dlig,ss01=2"
    fn parseFontFeatures(self: *Renderer, features_str: []const u8) void {
        var i: usize = 0;
        while (i < features_str.len and self.font_feature_count < MAX_FONT_FEATURES) {
            // Find next comma
            var j = i;
            while (j < features_str.len and features_str[j] != ',') : (j += 1) {}
            const tok = features_str[i..j];

            if (self.parseOneFeature(tok)) |feat| {
                self.font_features[self.font_feature_count] = feat;
                self.font_feature_count += 1;
            }

            i = if (j < features_str.len) j + 1 else j;
        }
    }

    fn parseOneFeature(_: *Renderer, tok: []const u8) ?DWriteFontFeature {
        if (tok.len == 0) return null;

        var tag_str: []const u8 = undefined;
        var value: u32 = 1;

        if (tok[0] == '+' or tok[0] == '-') {
            tag_str = tok[1..];
            value = if (tok[0] == '+') 1 else 0;
        } else if (std.mem.indexOfScalar(u8, tok, '=')) |eq| {
            tag_str = tok[0..eq];
            value = std.fmt.parseInt(u32, tok[eq + 1 ..], 10) catch return null;
        } else {
            tag_str = tok;
        }

        if (tag_str.len != 4) return null;

        // Pack 4-char tag into u32 (big-endian, matching DWRITE_FONT_FEATURE_TAG)
        const nameTag: u32 = @as(u32, tag_str[0]) |
            (@as(u32, tag_str[1]) << 8) |
            (@as(u32, tag_str[2]) << 16) |
            (@as(u32, tag_str[3]) << 24);

        return DWriteFontFeature{ .nameTag = nameTag, .parameter = value };
    }

    /// Get glyph index for a scalar, applying OpenType features if set.
    /// Falls back to GetGlyphIndicesW when no features or analyzer unavailable.
    fn getGlyphIndexForScalar(self: *Renderer, face: *c.IDWriteFontFace, scalar: u32) !c.UINT16 {
        if (self.font_feature_count > 0 and self.text_analyzer != null) {
            if (self.getGlyphIndexViaAnalyzer(face, scalar)) |gid| {
                return gid;
            } else |_| {}
        }

        // Default path: direct cmap lookup (no features)
        const fvtbl = face.lpVtbl.*;
        var codepoints: [1]c.UINT32 = .{@as(c.UINT32, @intCast(scalar))};
        var glyph_index: c.UINT16 = 0;
        const get_fn = fvtbl.GetGlyphIndicesW orelse return error.DWriteFontFaceMissingGetGlyphIndicesW;
        const hr = get_fn(face, codepoints[0..].ptr, 1, &glyph_index);
        if (c.FAILED(hr)) return error.DWriteGetGlyphIndicesFailed;
        return glyph_index;
    }

    /// Use IDWriteTextAnalyzer::GetGlyphs to get feature-aware glyph index.
    fn getGlyphIndexViaAnalyzer(self: *Renderer, face: *c.IDWriteFontFace, scalar: u32) !c.UINT16 {
        const analyzer = self.text_analyzer orelse return error.NoTextAnalyzer;
        const atbl = analyzer.lpVtbl.*;

        // Convert scalar to UTF-16
        var text_buf: [2]c.WCHAR = undefined;
        var text_len: u32 = 1;
        if (scalar <= 0xFFFF) {
            text_buf[0] = @intCast(scalar);
        } else {
            // Surrogate pair
            const v = scalar - 0x10000;
            text_buf[0] = @intCast(0xD800 + ((v >> 10) & 0x3FF));
            text_buf[1] = @intCast(0xDC00 + (v & 0x3FF));
            text_len = 2;
        }

        var script_analysis = std.mem.zeroes(c.DWRITE_SCRIPT_ANALYSIS);
        script_analysis.script = 0; // Default (Latin)
        script_analysis.shapes = c.DWRITE_SCRIPT_SHAPES_DEFAULT;

        // Build DWRITE_TYPOGRAPHIC_FEATURES from stored features
        var dw_features_arr: [MAX_FONT_FEATURES]c.DWRITE_FONT_FEATURE = undefined;
        for (0..self.font_feature_count) |fi| {
            dw_features_arr[fi] = .{
                .nameTag = @bitCast(self.font_features[fi].nameTag),
                .parameter = self.font_features[fi].parameter,
            };
        }
        var typo_features = c.DWRITE_TYPOGRAPHIC_FEATURES{
            .features = &dw_features_arr,
            .featureCount = self.font_feature_count,
        };
        var feature_ptrs: [1]*c.DWRITE_TYPOGRAPHIC_FEATURES = .{&typo_features};
        var feature_range_lengths: [1]c.UINT32 = .{text_len};

        // Output buffers
        // DWRITE_SHAPING_TEXT_PROPERTIES / DWRITE_SHAPING_GLYPH_PROPERTIES are
        // opaque in Zig's cimport (UINT16 bitfields). Use raw u16 arrays + @ptrCast.
        var cluster_map: [2]c.UINT16 = .{ 0, 0 };
        var text_props_raw: [2]u16 = .{ 0, 0 };
        var glyph_indices: [4]c.UINT16 = .{ 0, 0, 0, 0 };
        var glyph_props_raw: [4]u16 = .{ 0, 0, 0, 0 };
        var actual_glyph_count: u32 = 0;

        const get_glyphs_fn = atbl.GetGlyphs orelse return error.DWriteTextAnalyzerMissingGetGlyphs;

        const hr = get_glyphs_fn(
            analyzer,
            &text_buf,
            text_len,
            face,
            c.FALSE, // isSideways
            c.FALSE, // isRightToLeft
            &script_analysis,
            null, // localeName
            null, // numberSubstitution
            @ptrCast(&feature_ptrs),
            &feature_range_lengths,
            1, // featureRanges
            4, // maxGlyphCount
            &cluster_map,
            @ptrCast(&text_props_raw),
            &glyph_indices,
            @ptrCast(&glyph_props_raw),
            &actual_glyph_count,
        );

        if (c.FAILED(hr) or actual_glyph_count == 0) return error.DWriteGetGlyphsFailed;
        return glyph_indices[0];
    }

    // Lazy-load Bold/Italic/Bold+Italic font faces on first use.
    // This improves startup time by ~10ms since styled fonts are rarely used at launch.
    // Must be called with mu locked.
    fn ensureStyledFontFaces(self: *Renderer) void {
        if (self.styled_fonts_initialized) return;
        self.styled_fonts_initialized = true;

        const factory = self.dwrite_factory orelse return;

        // Get system font collection
        var sys_fc: ?*c.IDWriteFontCollection = null;
        const get_fc_fn = factory.lpVtbl.*.GetSystemFontCollection orelse return;
        const hr_fc = get_fc_fn(factory, &sys_fc, c.FALSE);
        if (c.FAILED(hr_fc) or sys_fc == null) return;
        defer safeRelease(sys_fc);

        const fc = sys_fc.?;

        // Find font family by name
        var index: u32 = 0;
        var exists: c.BOOL = c.FALSE;
        const find_fn = fc.lpVtbl.*.FindFamilyName orelse return;
        const hr_find = find_fn(fc, @ptrCast(&self.font_name), &index, &exists);
        if (c.FAILED(hr_find) or exists == c.FALSE) return;

        var family: ?*c.IDWriteFontFamily = null;
        const get_family_fn = fc.lpVtbl.*.GetFontFamily orelse return;
        const hr_fam = get_family_fn(fc, index, &family);
        if (c.FAILED(hr_fam) or family == null) return;
        defer safeRelease(family);

        const get_first_fn = family.?.lpVtbl.*.GetFirstMatchingFont orelse return;

        // Bold variant
        {
            var bold_font: ?*c.IDWriteFont = null;
            const hr_bold = get_first_fn(
                family.?,
                c.DWRITE_FONT_WEIGHT_BOLD,
                c.DWRITE_FONT_STRETCH_NORMAL,
                c.DWRITE_FONT_STYLE_NORMAL,
                &bold_font,
            );
            if (!c.FAILED(hr_bold) and bold_font != null) {
                const cf = bold_font.?.lpVtbl.*.CreateFontFace orelse null;
                if (cf) |make_face_fn| {
                    var new_bold_face: ?*c.IDWriteFontFace = null;
                    const hr_cf = make_face_fn(bold_font.?, &new_bold_face);
                    if (!c.FAILED(hr_cf)) {
                        self.bold_font_face = new_bold_face;
                        if (applog.isEnabled()) applog.appLog("[dwrite] Bold font face created (lazy)\n", .{});
                    }
                }
                safeRelease(bold_font);
            }
        }

        // Italic variant
        {
            var italic_font: ?*c.IDWriteFont = null;
            const hr_italic = get_first_fn(
                family.?,
                c.DWRITE_FONT_WEIGHT_NORMAL,
                c.DWRITE_FONT_STRETCH_NORMAL,
                c.DWRITE_FONT_STYLE_ITALIC,
                &italic_font,
            );
            if (!c.FAILED(hr_italic) and italic_font != null) {
                const cf = italic_font.?.lpVtbl.*.CreateFontFace orelse null;
                if (cf) |make_face_fn| {
                    var new_italic_face: ?*c.IDWriteFontFace = null;
                    const hr_cf = make_face_fn(italic_font.?, &new_italic_face);
                    if (!c.FAILED(hr_cf)) {
                        self.italic_font_face = new_italic_face;
                        if (applog.isEnabled()) applog.appLog("[dwrite] Italic font face created (lazy)\n", .{});
                    }
                }
                safeRelease(italic_font);
            }
        }

        // Bold+Italic variant
        {
            var bold_italic_font: ?*c.IDWriteFont = null;
            const hr_bi = get_first_fn(
                family.?,
                c.DWRITE_FONT_WEIGHT_BOLD,
                c.DWRITE_FONT_STRETCH_NORMAL,
                c.DWRITE_FONT_STYLE_ITALIC,
                &bold_italic_font,
            );
            if (!c.FAILED(hr_bi) and bold_italic_font != null) {
                const cf = bold_italic_font.?.lpVtbl.*.CreateFontFace orelse null;
                if (cf) |make_face_fn| {
                    var new_bold_italic_face: ?*c.IDWriteFontFace = null;
                    const hr_cf = make_face_fn(bold_italic_font.?, &new_bold_italic_face);
                    if (!c.FAILED(hr_cf)) {
                        self.bold_italic_font_face = new_bold_italic_face;
                        if (applog.isEnabled()) applog.appLog("[dwrite] Bold+Italic font face created (lazy)\n", .{});
                    }
                }
                safeRelease(bold_italic_font);
            }
        }
    }

    fn recomputeCellMetrics(self: *Renderer) !void {
        if (self.dwrite_factory == null or self.text_format == null) return;

        const sample_w = L("M");
        var layout: ?*c.IDWriteTextLayout = null;

        const factory = self.dwrite_factory orelse return error.NotInitialized;
        const vtbl = factory.lpVtbl.*;
        const create_layout_fn = vtbl.CreateTextLayout orelse return error.DWriteFactoryMissingCreateTextLayout;

        const hr = create_layout_fn(
            factory,
            sample_w,
            1,
            self.text_format.?,
            1000.0,
            1000.0,
            &layout,
        );

        if (hr != 0 or layout == null) return error.DWriteCreateTextLayoutFailed;
        defer safeRelease(layout);

        var m: c.DWRITE_TEXT_METRICS = undefined;
        const layout_ptr = layout orelse return error.DWriteCreateTextLayoutFailed;
        const lvtbl = layout_ptr.lpVtbl.*;
        const get_metrics_fn = lvtbl.GetMetrics orelse return error.DWriteGetMetricsFailed;

        const hrm = get_metrics_fn(layout_ptr, &m);
        if (hrm != 0) return error.DWriteGetMetricsFailed;

        // Round up for cell size
        const cw: u32 = @intCast(@max(1, @as(i32, @intFromFloat(std.math.ceil(m.widthIncludingTrailingWhitespace)))));
        const ch: u32 = @intCast(@max(1, @as(i32, @intFromFloat(std.math.ceil(m.height)))));

        self.cell_w_px = cw;
        self.cell_h_px = ch;
    }

    pub fn cellW(self: *const Renderer) u32 {
        return self.cell_w_px;
    }
    pub fn cellH(self: *const Renderer) u32 {
        return self.cell_h_px;
    }

    /// Update DPI and re-apply font with new scaling.
    /// Called from WM_DPICHANGED handler.
    pub fn updateDpi(self: *Renderer, new_dpi: u32) void {
        self.mu.lockUncancelable(core.clock.io());
        defer self.mu.unlock(core.clock.io());

        if (new_dpi == self.dpi) return;

        const old_dpi = self.dpi;
        self.dpi = new_dpi;
        if (applog.isEnabled()) applog.appLog("[d2d] DPI changed: {d} -> {d}\n", .{ old_dpi, new_dpi });

        // Re-scale font_em_size and metrics proportionally
        const scale: f32 = @as(f32, @floatFromInt(new_dpi)) / @as(f32, @floatFromInt(old_dpi));
        self.font_em_size *= scale;
        self.emoji_font_size = 0; // reset: will be recomputed on next emoji render
        self.ascent_px *= scale;
        self.descent_px *= scale;

        // Re-create TextFormat with new scaled size (needed for cell metrics)
        if (self.dwrite_factory != null and self.font_name[0] != 0) {
            safeRelease(self.text_format);
            self.text_format = null;

            const factory = self.dwrite_factory.?;
            const vtbl = factory.lpVtbl.*;
            if (vtbl.CreateTextFormat) |create_fn| {
                const new_font_size: f32 = emSizePxForPointSize(new_dpi, self.base_point_size);
                var new_fmt: ?*c.IDWriteTextFormat = null;
                const hr = create_fn(
                    factory,
                    @ptrCast(&self.font_name),
                    null,
                    c.DWRITE_FONT_WEIGHT_NORMAL,
                    c.DWRITE_FONT_STYLE_NORMAL,
                    c.DWRITE_FONT_STRETCH_NORMAL,
                    new_font_size,
                    @ptrCast(L("en-us")),
                    &new_fmt,
                );
                if (hr == 0 and new_fmt != null) {
                    self.text_format = new_fmt;
                }
            }
        }

        // Re-compute cell metrics with new TextFormat
        self.recomputeCellMetrics() catch {};

        // Reset styled font faces (will be lazy-reloaded)
        safeRelease(self.bold_font_face);
        safeRelease(self.italic_font_face);
        safeRelease(self.bold_italic_font_face);
        self.bold_font_face = null;
        self.italic_font_face = null;
        self.bold_italic_font_face = null;
        self.styled_fonts_initialized = false;

        // Invalidate GSUB cache (font faces released above).
        self.gsub_cache = [_]GsubCacheEntry{.{}} ** 4;
    }

    pub fn dpiValue(self: *Renderer) u32 {
        self.mu.lockUncancelable(core.clock.io());
        defer self.mu.unlock(core.clock.io());
        return self.dpi;
    }

    pub fn cellMetrics(self: *Renderer) struct { w_px: u32, h_px: u32 } {
        self.mu.lockUncancelable(core.clock.io());
        defer self.mu.unlock(core.clock.io());
        return .{ .w_px = self.cell_w_px, .h_px = self.cell_h_px };
    }

    pub fn fontGenerationValue(self: *Renderer) u64 {
        self.mu.lockUncancelable(core.clock.io());
        defer self.mu.unlock(core.clock.io());
        return self.font_generation;
    }

    // =========================================================================
    // Text-run shaping (on_shape_text_run callback)
    // =========================================================================

    const SHAPE_MAX_SCALARS = 512;
    const SHAPE_MAX_UTF16 = SHAPE_MAX_SCALARS * 2;
    const SHAPE_MAX_GLYPHS = SHAPE_MAX_SCALARS * 3;

    /// Select font face by style flags. Returns null if no font is loaded.
    /// Must be called with self.mu locked.
    fn selectFontFace(self: *Renderer, style_flags: u32) ?*c.IDWriteFontFace {
        if (style_flags != 0) {
            self.ensureStyledFontFaces();
            const is_bold = (style_flags & STYLE_BOLD) != 0;
            const is_italic = (style_flags & STYLE_ITALIC) != 0;
            if (is_bold and is_italic) {
                return self.bold_italic_font_face orelse self.bold_font_face orelse self.italic_font_face orelse self.font_face;
            } else if (is_bold) {
                return self.bold_font_face orelse self.font_face;
            } else if (is_italic) {
                return self.italic_font_face orelse self.font_face;
            }
        }
        return self.font_face;
    }

    /// Shape a text run using DWrite IDWriteTextAnalyzer.
    /// Returns glyph count on success, 0 on failure (fallback to per-cell).
    /// If glyph_count > out_cap, returns the count without filling buffers.
    pub fn shapeTextRunDWrite(
        self: *Renderer,
        scalars: [*]const u32,
        scalar_count: usize,
        style_flags: u32,
        out_glyph_ids: [*]u32,
        out_clusters: [*]u32,
        out_x_advance: [*]i32,
        out_x_offset: [*]i32,
        out_y_offset: [*]i32,
        out_cap: usize,
    ) usize {
        if (scalar_count == 0) return 0;

        self.mu.lockUncancelable(core.clock.io());
        defer self.mu.unlock(core.clock.io());

        const face = self.selectFontFace(style_flags) orelse return 0;

        // For very long runs that exceed the stack-allocated shaping buffers,
        // fall back to per-codepoint glyph lookup (correct rendering, no ligatures/kerning).
        // This avoids returning 0 which would trigger the slower per-cell path in the core.
        if (scalar_count > SHAPE_MAX_SCALARS) {
            return self.shapeFallbackPerCodepoint(face, scalars, scalar_count, out_glyph_ids, out_clusters, out_x_advance, out_x_offset, out_y_offset, out_cap);
        }

        // Ensure text analyzer exists (create lazily if needed)
        if (self.text_analyzer == null) {
            const dw_factory = self.dwrite_factory orelse return 0;
            var analyzer: ?*c.IDWriteTextAnalyzer = null;
            const create_analyzer_fn = dw_factory.lpVtbl.*.CreateTextAnalyzer orelse return 0;
            const hr_ta = create_analyzer_fn(dw_factory, &analyzer);
            if (c.FAILED(hr_ta) or analyzer == null) return 0;
            self.text_analyzer = analyzer;
        }
        const analyzer = self.text_analyzer orelse return 0;

        // --- 1) Convert UTF-32 scalars → UTF-16 ---
        var utf16_buf: [SHAPE_MAX_UTF16]c.WCHAR = undefined;
        var utf16_to_scalar_idx: [SHAPE_MAX_UTF16]u32 = undefined;
        var utf16_len: u32 = 0;

        for (0..scalar_count) |si| {
            const s = scalars[si];
            if (utf16_len >= SHAPE_MAX_UTF16) return 0;
            if (s <= 0xFFFF) {
                utf16_buf[utf16_len] = @intCast(if (s >= 0xD800 and s <= 0xDFFF) @as(u32, 0xFFFD) else s);
                utf16_to_scalar_idx[utf16_len] = @intCast(si);
                utf16_len += 1;
            } else if (s <= 0x10FFFF) {
                if (utf16_len + 1 >= SHAPE_MAX_UTF16) return 0;
                const v = s - 0x10000;
                utf16_buf[utf16_len] = @intCast(0xD800 + ((v >> 10) & 0x3FF));
                utf16_to_scalar_idx[utf16_len] = @intCast(si);
                utf16_len += 1;
                utf16_buf[utf16_len] = @intCast(0xDC00 + (v & 0x3FF));
                utf16_to_scalar_idx[utf16_len] = @intCast(si);
                utf16_len += 1;
            } else {
                // Invalid scalar → U+FFFD
                utf16_buf[utf16_len] = 0xFFFD;
                utf16_to_scalar_idx[utf16_len] = @intCast(si);
                utf16_len += 1;
            }
        }

        if (utf16_len == 0) return 0;

        // --- 2) Call GetGlyphs ---
        var script_analysis = std.mem.zeroes(c.DWRITE_SCRIPT_ANALYSIS);
        script_analysis.script = 0; // Default (Latin)
        script_analysis.shapes = c.DWRITE_SCRIPT_SHAPES_DEFAULT;

        // Build features array
        var dw_features_arr: [MAX_FONT_FEATURES]c.DWRITE_FONT_FEATURE = undefined;
        for (0..self.font_feature_count) |fi| {
            dw_features_arr[fi] = .{
                .nameTag = @bitCast(self.font_features[fi].nameTag),
                .parameter = self.font_features[fi].parameter,
            };
        }
        var typo_features = c.DWRITE_TYPOGRAPHIC_FEATURES{
            .features = &dw_features_arr,
            .featureCount = self.font_feature_count,
        };
        var feature_ptrs: [1]*c.DWRITE_TYPOGRAPHIC_FEATURES = .{&typo_features};
        var feature_range_lengths: [1]c.UINT32 = .{utf16_len};

        const has_features = self.font_feature_count > 0;

        var cluster_map: [SHAPE_MAX_UTF16]c.UINT16 = undefined;
        var text_props_raw: [SHAPE_MAX_UTF16]u16 = undefined;
        var glyph_indices: [SHAPE_MAX_GLYPHS]c.UINT16 = undefined;
        var glyph_props_raw: [SHAPE_MAX_GLYPHS]u16 = undefined;
        var actual_glyph_count: u32 = 0;

        const atbl = analyzer.lpVtbl.*;
        const get_glyphs_fn = atbl.GetGlyphs orelse return 0;

        const hr_gg = get_glyphs_fn(
            analyzer,
            &utf16_buf,
            utf16_len,
            face,
            c.FALSE, // isSideways
            c.FALSE, // isRightToLeft
            &script_analysis,
            null, // localeName
            null, // numberSubstitution
            if (has_features) @ptrCast(&feature_ptrs) else null,
            if (has_features) &feature_range_lengths else null,
            if (has_features) @as(u32, 1) else @as(u32, 0),
            SHAPE_MAX_GLYPHS,
            &cluster_map,
            @ptrCast(&text_props_raw),
            &glyph_indices,
            @ptrCast(&glyph_props_raw),
            &actual_glyph_count,
        );

        if (c.FAILED(hr_gg) or actual_glyph_count == 0) return 0;

        // If more glyphs than output capacity, signal the count
        if (actual_glyph_count > out_cap) return @intCast(actual_glyph_count);

        // --- 3) Call GetGlyphPlacements ---
        var glyph_advances: [SHAPE_MAX_GLYPHS]c.FLOAT = undefined;
        var glyph_offsets: [SHAPE_MAX_GLYPHS]c.DWRITE_GLYPH_OFFSET = undefined;

        const get_placements_fn = atbl.GetGlyphPlacements orelse {
            // Fallback: fill advances with cell_w_px, offsets with 0
            const gcount: usize = @intCast(actual_glyph_count);
            for (0..gcount) |i| {
                out_glyph_ids[i] = glyph_indices[i];
                out_x_advance[i] = @as(i32, @intCast(self.cell_w_px)) * 64;
                out_x_offset[i] = 0;
                out_y_offset[i] = 0;
            }
            render_pipeline_helpers.invertClusterMap(
                cluster_map[0..utf16_len],
                utf16_to_scalar_idx[0..utf16_len],
                gcount,
                out_clusters[0..gcount],
            );
            return gcount;
        };

        const hr_gp = get_placements_fn(
            analyzer,
            &utf16_buf,
            &cluster_map,
            @ptrCast(&text_props_raw),
            utf16_len,
            &glyph_indices,
            @ptrCast(&glyph_props_raw),
            actual_glyph_count,
            face,
            self.font_em_size,
            c.FALSE, // isSideways
            c.FALSE, // isRightToLeft
            &script_analysis,
            null, // localeName
            if (has_features) @ptrCast(&feature_ptrs) else null,
            if (has_features) &feature_range_lengths else null,
            if (has_features) @as(u32, 1) else @as(u32, 0),
            &glyph_advances,
            &glyph_offsets,
        );

        if (c.FAILED(hr_gp)) return 0;

        // --- 4) Convert outputs ---
        const gcount: usize = @intCast(actual_glyph_count);

        for (0..gcount) |i| {
            out_glyph_ids[i] = glyph_indices[i];
            // DIP → 26.6 fixed-point (font_em_size already includes DPI scaling)
            out_x_advance[i] = @intFromFloat(glyph_advances[i] * 64.0);
            out_x_offset[i] = @intFromFloat(glyph_offsets[i].advanceOffset * 64.0);
            out_y_offset[i] = @intFromFloat(glyph_offsets[i].ascenderOffset * 64.0);

            // DEBUG: log non-ASCII glyph results from DWrite shaping
        }

        // DWrite maps text position → first glyph; the core's contract is the
        // inverse, naming the cluster's first source scalar. See
        // render_pipeline_helpers.invertClusterMap for the cases.
        render_pipeline_helpers.invertClusterMap(
            cluster_map[0..utf16_len],
            utf16_to_scalar_idx[0..utf16_len],
            gcount,
            out_clusters[0..gcount],
        );

        return gcount;
    }

    /// Per-codepoint glyph fallback for runs exceeding SHAPE_MAX_SCALARS.
    /// Returns 1:1 glyph mapping with correct advances but no multi-glyph shaping.
    /// Must be called with self.mu locked.
    fn shapeFallbackPerCodepoint(
        self: *Renderer,
        face: *c.IDWriteFontFace,
        scalars: [*]const u32,
        scalar_count: usize,
        out_glyph_ids: [*]u32,
        out_clusters: [*]u32,
        out_x_advance: [*]i32,
        out_x_offset: [*]i32,
        out_y_offset: [*]i32,
        out_cap: usize,
    ) usize {
        if (scalar_count > out_cap) return scalar_count;

        const fvtbl = face.lpVtbl.*;
        const get_glyph_fn = fvtbl.GetGlyphIndicesW orelse return 0;
        const get_metrics_fn = fvtbl.GetDesignGlyphMetrics orelse {
            // No metrics available — use cell_w_px for advances
            for (0..scalar_count) |i| {
                out_glyph_ids[i] = 0;
                out_clusters[i] = @intCast(i);
                out_x_advance[i] = @as(i32, @intCast(self.cell_w_px)) * 64;
                out_x_offset[i] = 0;
                out_y_offset[i] = 0;
            }
            return scalar_count;
        };

        // Compute advance scale factor
        var fm: c.DWRITE_FONT_METRICS = undefined;
        const get_fm_fn = fvtbl.GetMetrics orelse return 0;
        get_fm_fn(face, &fm);
        const du_per_em: f32 = @floatFromInt(fm.designUnitsPerEm);
        if (du_per_em <= 0.0) return 0;
        const scale: f32 = self.font_em_size / du_per_em * 64.0;

        // Process in small batches to keep stack usage minimal
        const BATCH = 128;
        var batch_cp: [BATCH]c.UINT32 = undefined;
        var batch_gids: [BATCH]c.UINT16 = undefined;
        var batch_metrics: [BATCH]c.DWRITE_GLYPH_METRICS = undefined;

        var si: usize = 0;
        while (si < scalar_count) {
            const n = @min(BATCH, scalar_count - si);
            for (0..n) |i| batch_cp[i] = scalars[si + i];

            const hr_gi = get_glyph_fn(face, &batch_cp, @intCast(n), &batch_gids);
            if (c.FAILED(hr_gi)) {
                // Fill remaining with cell_w_px fallback
                for (si..scalar_count) |i| {
                    out_glyph_ids[i] = 0;
                    out_clusters[i] = @intCast(i);
                    out_x_advance[i] = @as(i32, @intCast(self.cell_w_px)) * 64;
                    out_x_offset[i] = 0;
                    out_y_offset[i] = 0;
                }
                return scalar_count;
            }

            const hr_gm = get_metrics_fn(face, &batch_gids, @intCast(n), &batch_metrics, c.FALSE);
            const has_metrics = !c.FAILED(hr_gm);

            for (0..n) |i| {
                out_glyph_ids[si + i] = batch_gids[i];
                out_clusters[si + i] = @intCast(si + i);
                out_x_advance[si + i] = if (has_metrics)
                    @intFromFloat(@as(f32, @floatFromInt(batch_metrics[i].advanceWidth)) * scale)
                else
                    @as(i32, @intCast(self.cell_w_px)) * 64;
                out_x_offset[si + i] = 0;
                out_y_offset[si + i] = 0;
            }
            si += n;
        }
        return scalar_count;
    }

    // =========================================================================
    // Glyph-ID rasterization (on_rasterize_glyph_by_id callback)
    // =========================================================================

    /// Rasterize a glyph by its ID (post-shaping, skips scalar→glyph lookup).
    pub fn rasterizeGlyphByIdDWrite(self: *Renderer, glyph_id: u32, style_flags: u32, out_bitmap: *core.GlyphBitmap) !void {
        self.mu.lockUncancelable(core.clock.io());
        defer self.mu.unlock(core.clock.io());

        const face = self.selectFontFace(style_flags) orelse return error.NoFont;

        // A colour font's empty ClearType bound cannot be rescued by the
        // aliased retry, so skip it there and let the caller fall through to
        // the per-scalar GDI path instead.
        const has_color = self.hasColorTables();
        const outcome = try self.rasterizeGlyphIndex(
            face,
            @intCast(glyph_id & 0xFFFF), // truncate u32 -> u16 for DWrite
            !has_color,
            out_bitmap,
        );
        if (outcome == .empty) {
            out_bitmap.pixels = null;
            out_bitmap.width = 0;
            out_bitmap.height = 0;
            out_bitmap.pitch = 0;
            // 0 tells flush.zig to retry per-scalar (→ GDI colour emoji);
            // 3 is a genuinely blank ClearType glyph.
            out_bitmap.bytes_per_pixel = if (has_color) 0 else 3;
        }
    }

    // =========================================================================
    // ASCII fast path tables (on_get_ascii_table callback)
    // =========================================================================

    /// Build ASCII fast path tables for a given style variant.
    pub fn getAsciiTableDWrite(
        self: *Renderer,
        style_flags: u32,
        out_glyph_ids: [*]u32,
        out_x_advances: [*]i32,
        out_lig_triggers: [*]u8,
    ) bool {
        if (applog.isEnabled()) applog.appLog("[ascii_table] getAsciiTableDWrite start style={d}\n", .{style_flags});
        self.mu.lockUncancelable(core.clock.io());
        defer self.mu.unlock(core.clock.io());

        const face = self.selectFontFace(style_flags) orelse {
            if (applog.isEnabled()) applog.appLog("[ascii_table] selectFontFace returned null style={d}\n", .{style_flags});
            return false;
        };
        const fvtbl = face.lpVtbl.*;
        if (applog.isEnabled()) applog.appLog("[ascii_table] selectFontFace done style={d}\n", .{style_flags});

        // --- 1) Glyph IDs: batch cmap lookup ---
        var codepoints: [128]c.UINT32 = undefined;
        for (0..128) |i| codepoints[i] = @intCast(i);

        var glyph_ids_u16: [128]c.UINT16 = undefined;
        const get_glyph_fn = fvtbl.GetGlyphIndicesW orelse return false;
        const hr_gi = get_glyph_fn(face, &codepoints, 128, &glyph_ids_u16);
        if (c.FAILED(hr_gi)) return false;

        for (0..128) |i| {
            out_glyph_ids[i] = glyph_ids_u16[i];
        }
        if (applog.isEnabled()) applog.appLog("[ascii_table] GetGlyphIndicesW done style={d}\n", .{style_flags});

        // --- 2) X Advances: design units → 26.6 fixed-point pixels ---
        var glyph_metrics: [128]c.DWRITE_GLYPH_METRICS = undefined;
        const get_metrics_fn = fvtbl.GetDesignGlyphMetrics orelse {
            // Fallback: use cell_w_px for all advances
            for (0..128) |i| {
                out_x_advances[i] = @as(i32, @intCast(self.cell_w_px)) * 64;
            }
            @memset(out_lig_triggers[0..128], 0);
            return true;
        };

        const hr_gm = get_metrics_fn(face, &glyph_ids_u16, 128, &glyph_metrics, c.FALSE);
        if (c.FAILED(hr_gm)) {
            // Fallback to cell_w_px
            for (0..128) |i| {
                out_x_advances[i] = @as(i32, @intCast(self.cell_w_px)) * 64;
            }
        } else {
            // Get designUnitsPerEm for conversion
            var fm: c.DWRITE_FONT_METRICS = undefined;
            const get_fm_fn = fvtbl.GetMetrics orelse return false;
            get_fm_fn(face, &fm);
            const du_per_em: f32 = @floatFromInt(fm.designUnitsPerEm);
            if (du_per_em <= 0.0) return false;

            const scale: f32 = self.font_em_size / du_per_em * 64.0;
            for (0..128) |i| {
                const adv_du: f32 = @floatFromInt(glyph_metrics[i].advanceWidth);
                out_x_advances[i] = @intFromFloat(adv_du * scale);
            }
        }
        if (applog.isEnabled()) applog.appLog("[ascii_table] GetDesignGlyphMetrics done style={d}\n", .{style_flags});

        // --- 3) Lig Triggers: check GSUB cache first, then parse if needed ---
        // Search ALL cache slots by font_face_ptr so that different styles sharing
        // the same IDWriteFontFace get a cross-style cache hit.
        @memset(out_lig_triggers[0..128], 0);

        const face_ptr: usize = @intFromPtr(face);
        const cache_hit: ?usize = for (self.gsub_cache, 0..) |entry, i| {
            if (entry.valid and entry.font_face_ptr == face_ptr) break i;
        } else null;

        if (cache_hit) |idx| {
            if (applog.isEnabled()) applog.appLog("[ascii_table] GSUB cache hit style={d} slot={d}\n", .{ style_flags, idx });
            @memcpy(out_lig_triggers[0..128], &self.gsub_cache[idx].lig_triggers);
        } else {
            // Cache miss: parse GSUB and store result
            if (applog.isEnabled()) applog.appLog("[ascii_table] detectLigTriggersFromGSUB start style={d}\n", .{style_flags});
            detectLigTriggersFromGSUB(
                face,
                &glyph_ids_u16,
                self.font_features[0..self.font_feature_count],
                self.font_feature_count,
                out_lig_triggers,
            );
            if (applog.isEnabled()) applog.appLog("[ascii_table] detectLigTriggersFromGSUB done style={d}\n", .{style_flags});

            // Store in the slot corresponding to this style (evicts previous entry for this slot).
            const store_slot = style_flags & 3;
            self.gsub_cache[store_slot] = .{
                .font_face_ptr = face_ptr,
                .lig_triggers = out_lig_triggers[0..128].*,
                .valid = true,
            };
        }

        return true;
    }
};

fn safeRelease(p: anytype) void {
    // Supports optional COM interface pointers like ?*c.ID2D1Bitmap etc.
    if (p) |obj| {
        // Cast to IUnknown and call Release if present (cimport may mark it optional).
        const unk: *c.IUnknown = @as(*c.IUnknown, @ptrCast(obj));
        const vtbl = unk.lpVtbl.*;
        if (vtbl.Release) |release_fn| {
            _ = release_fn(unk);
        }
    }
}

/// Check if a Unicode scalar has default emoji presentation (Emoji_Presentation=Yes).
/// Based on Unicode 15.1 emoji-data.txt. Only includes codepoints that modern
/// renderers display as color emoji without an explicit VS16 selector.
fn isEmojiPresentation(scalar: u32) bool {
    return switch (scalar) {
        // BMP: Emoji_Presentation=Yes (Unicode 15.1)
        0x231A...0x231B,
        0x23E9...0x23F3,
        0x23F8...0x23FA,
        0x25FD...0x25FE,
        0x2614...0x2615,
        0x2648...0x2653,
        0x267F,
        0x2693,
        0x26A1,
        0x26AA...0x26AB,
        0x26BD...0x26BE,
        0x26C4...0x26C5,
        0x26CE,
        0x26D4,
        0x26EA,
        0x26F2...0x26F3,
        0x26F5,
        0x26FA,
        0x26FD,
        0x2705,
        0x270A...0x270B,
        0x2728,
        0x274C,
        0x274E,
        0x2753...0x2755,
        0x2757,
        0x2795...0x2797,
        0x27A1,
        0x27B0,
        0x27BF,
        0x2934...0x2935,
        0x2B05...0x2B07,
        0x2B1B...0x2B1C,
        0x2B50,
        0x2B55,
        0x3030,
        0x303D,
        0x3297,
        0x3299,
        // SMP: Emoji_Presentation=Yes (Unicode 15.1)
        0x1F004,
        0x1F0CF,
        0x1F18E,
        0x1F191...0x1F19A,
        0x1F1E6...0x1F1FF,
        0x1F201,
        0x1F21A,
        0x1F22F,
        0x1F232...0x1F236,
        0x1F238...0x1F23A,
        0x1F250...0x1F251,
        0x1F300...0x1F320,
        0x1F32D...0x1F335,
        0x1F337...0x1F37C,
        0x1F37E...0x1F393,
        0x1F3A0...0x1F3CA,
        0x1F3CF...0x1F3D3,
        0x1F3E0...0x1F3F0,
        0x1F3F4,
        0x1F3F8...0x1F43E,
        0x1F440,
        0x1F442...0x1F4FC,
        0x1F4FF...0x1F53D,
        0x1F54B...0x1F54E,
        0x1F550...0x1F567,
        0x1F57A,
        0x1F595...0x1F596,
        0x1F5A4,
        0x1F5FB...0x1F64F,
        0x1F680...0x1F6C5,
        0x1F6CC,
        0x1F6D0...0x1F6D2,
        0x1F6D5...0x1F6D7,
        0x1F6DC...0x1F6DF,
        0x1F6EB...0x1F6EC,
        0x1F6F4...0x1F6FC,
        0x1F7E0...0x1F7EB,
        0x1F7F0,
        0x1F90C...0x1F93A,
        0x1F93C...0x1F945,
        0x1F947...0x1F9FF,
        0x1FA70...0x1FA7C,
        0x1FA80...0x1FA89,
        0x1FA8F...0x1FAC6,
        0x1FACE...0x1FADC,
        0x1FADF...0x1FAE9,
        0x1FAF0...0x1FAF8,
        => true,
        else => false,
    };
}

/// Pack a 4-char OpenType tag into u32 (little-endian, matching DWRITE_FONT_FEATURE_TAG).
fn packTag(comptime s: *const [4]u8) u32 {
    return @as(u32, s[0]) | (@as(u32, s[1]) << 8) | (@as(u32, s[2]) << 16) | (@as(u32, s[3]) << 24);
}

// =========================================================================
// OpenType GSUB table parsing helpers for lig_triggers detection
// =========================================================================

/// Read big-endian u16 from raw table bytes.
fn readU16BE(data: []const u8, off: usize) ?u16 {
    if (off + 2 > data.len) return null;
    return (@as(u16, data[off]) << 8) | @as(u16, data[off + 1]);
}

/// Read big-endian u32 from raw table bytes.
fn readU32BE(data: []const u8, off: usize) ?u32 {
    if (off + 4 > data.len) return null;
    return (@as(u32, data[off]) << 24) | (@as(u32, data[off + 1]) << 16) |
        (@as(u32, data[off + 2]) << 8) | @as(u32, data[off + 3]);
}

/// Map a glyph ID back to ASCII codepoints and mark as trigger.
fn markAsciiTrigger(gid: u16, ascii_gids: []const c.UINT16, out_triggers: [*]u8) void {
    for (0x20..0x7F) |cp| {
        if (ascii_gids[cp] != 0 and ascii_gids[cp] == gid) {
            out_triggers[cp] = 1;
        }
    }
}

/// Scan a Coverage table and mark covered ASCII glyphs as triggers.
/// `tbl` is the full GSUB table bytes, `cov_abs` is the absolute offset of the Coverage table.
fn collectCoverageGlyphs(
    tbl: []const u8,
    cov_abs: usize,
    ascii_gids: []const c.UINT16,
    out_triggers: [*]u8,
) void {
    const fmt = readU16BE(tbl, cov_abs) orelse return;
    if (fmt == 1) {
        // Coverage Format 1: list of glyph IDs
        const count = readU16BE(tbl, cov_abs + 2) orelse return;
        for (0..count) |i| {
            const gid = readU16BE(tbl, cov_abs + 4 + i * 2) orelse return;
            markAsciiTrigger(gid, ascii_gids, out_triggers);
        }
    } else if (fmt == 2) {
        // Coverage Format 2: ranges [startGlyphID, endGlyphID, startCoverageIndex]
        const range_count = readU16BE(tbl, cov_abs + 2) orelse return;
        for (0..range_count) |i| {
            const rec_off = cov_abs + 4 + i * 6;
            const start_gid = readU16BE(tbl, rec_off) orelse return;
            const end_gid = readU16BE(tbl, rec_off + 2) orelse return;
            // Use u32 to avoid u16 overflow when end_gid == 0xFFFF
            var gid: u32 = start_gid;
            while (gid <= @as(u32, end_gid)) : (gid += 1) {
                markAsciiTrigger(@intCast(gid), ascii_gids, out_triggers);
            }
        }
    }
}

/// Extract coverage from a single GSUB lookup subtable.
/// Handles lookup types 1-6 directly and type 7 (Extension) by indirection.
/// `depth` guards against malformed fonts with circular Extension references.
fn processSubtable(
    tbl: []const u8,
    subtable_abs: usize,
    lookup_type: u16,
    ascii_gids: []const c.UINT16,
    out_triggers: [*]u8,
    depth: u8,
) void {
    if (lookup_type == 7) {
        // Extension Substitution (type 7): dereference to actual subtable
        // Format: u16 substFormat, u16 extensionLookupType, u32 extensionOffset
        if (depth >= 2) return; // prevent infinite recursion on malformed fonts
        const ext_type = readU16BE(tbl, subtable_abs + 2) orelse return;
        const ext_off = readU32BE(tbl, subtable_abs + 4) orelse return;
        if (ext_off == 0) return; // self-reference guard
        const real_abs = subtable_abs + ext_off;
        if (real_abs >= tbl.len) return;
        processSubtable(tbl, real_abs, ext_type, ascii_gids, out_triggers, depth + 1);
        return;
    }

    // Types 1-4: Coverage offset is always at subtable+2 (all formats).
    // Types 5/6: Coverage location depends on substFormat:
    //   Format 1,2: Coverage offset at subtable+2 (same as types 1-4).
    //   Format 3: Different structure — field at offset 2 is GlyphCount (type 5)
    //     or BacktrackGlyphCount (type 6), NOT a coverage offset.
    //     Misinterpreting this causes pathological parsing of garbage data.
    if (lookup_type == 5 or lookup_type == 6) {
        const sub_fmt = readU16BE(tbl, subtable_abs) orelse return;
        if (sub_fmt == 3) {
            // Format 3: parse input coverage correctly.
            if (lookup_type == 6) {
                // ChainingContext format 3: skip backtrack array to find input coverage.
                // Layout: substFormat(2) + backtrackCount(2) + backtrackCov[N](2*N)
                //       + inputCount(2) + inputCov[M](2*M) + ...
                const bt_count = readU16BE(tbl, subtable_abs + 2) orelse return;
                const input_count_off = subtable_abs + 4 + @as(usize, bt_count) * 2;
                const input_count = readU16BE(tbl, input_count_off) orelse return;
                if (input_count == 0) return;
                // First input coverage offset (relative to subtable start)
                const cov_off_rel = readU16BE(tbl, input_count_off + 2) orelse return;
                const cov_abs = subtable_abs + @as(usize, cov_off_rel);
                if (cov_abs >= tbl.len) return;
                collectCoverageGlyphs(tbl, cov_abs, ascii_gids, out_triggers);
            } else {
                // Context format 3: glyphCount(2) + coverage offsets.
                // Layout: substFormat(2) + glyphCount(2) + coverageOff[G](2*G) + ...
                const glyph_count = readU16BE(tbl, subtable_abs + 2) orelse return;
                if (glyph_count == 0) return;
                // First coverage offset (relative to subtable start)
                const cov_off_rel = readU16BE(tbl, subtable_abs + 4) orelse return;
                const cov_abs = subtable_abs + @as(usize, cov_off_rel);
                if (cov_abs >= tbl.len) return;
                collectCoverageGlyphs(tbl, cov_abs, ascii_gids, out_triggers);
            }
            return;
        }
        // Format 1,2: Coverage at offset 2, fall through to common path.
    }
    const cov_off_rel = readU16BE(tbl, subtable_abs + 2) orelse return;
    const cov_abs = subtable_abs + cov_off_rel;
    if (cov_abs >= tbl.len) return;
    collectCoverageGlyphs(tbl, cov_abs, ascii_gids, out_triggers);
}

/// Detect ligature trigger characters by introspecting the font's GSUB table.
/// Matches macOS behavior (HarfBuzz `hb_ot_layout_collect_lookups` + `hb_ot_layout_lookup_collect_glyphs`).
///
/// `face`: the IDWriteFontFace to query
/// `ascii_gids`: 128-entry table of codepoint→glyph ID (from GetGlyphIndicesW)
/// `user_features`/`user_feature_count`: user-specified font features (DWrite format, little-endian tags)
/// `out_triggers`: 128-entry output, set to 1 for ASCII chars that participate in active GSUB substitutions
fn detectLigTriggersFromGSUB(
    face: *c.IDWriteFontFace,
    ascii_gids: []const c.UINT16,
    user_features: []const DWriteFontFeature,
    user_feature_count: u32,
    out_triggers: [*]u8,
) void {
    const fvtbl = face.lpVtbl.*;

    // Get raw GSUB table
    // DWrite TryGetFontTable uses DWRITE_MAKE_OPENTYPE_TAG byte order (little-endian on x86).
    // packTag("GSUB") = 'G' | ('S'<<8) | ('U'<<16) | ('B'<<24) = 0x42555347.
    const gsub_tag: u32 = packTag("GSUB");
    var table_data: ?*const anyopaque = null;
    var table_size: c.UINT32 = 0;
    var table_ctx: ?*anyopaque = null;
    var exists: c.BOOL = c.FALSE;

    if (applog.isEnabled()) applog.appLog("[gsub] TryGetFontTable calling\n", .{});
    const try_fn = fvtbl.TryGetFontTable orelse return;
    const hr = try_fn(face, gsub_tag, &table_data, &table_size, &table_ctx, &exists);
    if (applog.isEnabled()) applog.appLog("[gsub] TryGetFontTable returned hr=0x{x} exists={d} size={d}\n", .{ @as(u32, @bitCast(hr)), @as(u32, @intFromBool(exists != c.FALSE)), table_size });
    if (c.FAILED(hr) or exists == c.FALSE or table_data == null or table_size < 10) {
        // Release context if obtained
        if (table_ctx != null) {
            if (fvtbl.ReleaseFontTable) |rel_fn| rel_fn(face, table_ctx);
        }
        return;
    }

    defer {
        if (table_ctx != null) {
            if (fvtbl.ReleaseFontTable) |rel_fn| rel_fn(face, table_ctx);
        }
    }

    const tbl: []const u8 = @as([*]const u8, @ptrCast(table_data.?))[0..table_size];

    // GSUB header: majorVersion(2) + minorVersion(2) + scriptListOffset(2) + featureListOffset(2) + lookupListOffset(2)
    // Offsets: 0=majorVer, 2=minorVer, 4=scriptList, 6=featureList, 8=lookupList
    const feature_list_off = readU16BE(tbl, 6) orelse return;
    const lookup_list_off = readU16BE(tbl, 8) orelse return;

    // FeatureList: featureCount(2) + featureRecords[featureCount] each = tag(4) + offset(2)
    const fl_abs = @as(usize, feature_list_off);
    const feature_count = readU16BE(tbl, fl_abs) orelse return;

    // Determine which features are active.
    // Default-on features: liga, calt, rlig, locl, ccmp (mirrors HarfBuzz defaults
    // and macOS HBFTBridge.c). locl and ccmp can substitute ASCII glyphs in some
    // fonts (e.g. locale-specific bracket forms) so we must mark their input
    // glyphs as triggers to avoid divergent rendering between the ASCII fast
    // path and HarfBuzz output.
    // Default-off features: clig, dlig, ss01-ss20, cv01-cv99, etc.
    // User features can override defaults (enable or disable).
    const ot_liga: u32 = 0x6C696761; // 'liga' big-endian
    const ot_calt: u32 = 0x63616C74; // 'calt' big-endian
    const ot_rlig: u32 = 0x726C6967; // 'rlig' big-endian
    const ot_locl: u32 = 0x6C6F636C; // 'locl' big-endian
    const ot_ccmp: u32 = 0x63636D70; // 'ccmp' big-endian
    // Collect lookup indices from active features
    // We use a bitset for lookup indices (max 65536 lookups, but typically <500)
    // Use a fixed-size array as a simple bitset (supports up to 4096 lookups)
    const MAX_LOOKUPS = 4096;
    var lookup_active = std.mem.zeroes([MAX_LOOKUPS / 8]u8);

    for (0..feature_count) |fi| {
        const rec_off = fl_abs + 2 + fi * 6;
        const tag_be = readU32BE(tbl, rec_off) orelse continue;
        const feat_off_rel = readU16BE(tbl, rec_off + 4) orelse continue;

        // Determine if this feature is active
        var active = false;

        // Check default-on features
        if (tag_be == ot_liga or tag_be == ot_calt or tag_be == ot_rlig or
            tag_be == ot_locl or tag_be == ot_ccmp)
        {
            active = true; // default on
        }

        // Check user overrides: DWrite tags are little-endian, GSUB tags are big-endian
        for (0..user_feature_count) |ui| {
            const user_tag_le = user_features[ui].nameTag;
            // Convert LE→BE for comparison: swap bytes
            const user_tag_be = @byteSwap(user_tag_le);
            if (user_tag_be == tag_be) {
                active = (user_features[ui].parameter != 0);
                break;
            }
        }

        if (!active) continue;

        // Read Feature table: featureParams(2) + lookupCount(2) + lookupListIndices[lookupCount]
        const feat_abs = fl_abs + @as(usize, feat_off_rel);
        // Skip featureParams (2 bytes)
        const lk_count = readU16BE(tbl, feat_abs + 2) orelse continue;

        for (0..lk_count) |li| {
            const lk_idx = readU16BE(tbl, feat_abs + 4 + li * 2) orelse continue;
            if (lk_idx < MAX_LOOKUPS) {
                lookup_active[lk_idx / 8] |= @as(u8, 1) << @intCast(lk_idx % 8);
            }
        }
    }

    // LookupList: lookupCount(2) + lookupOffsets[lookupCount] (each u16)
    const ll_abs = @as(usize, lookup_list_off);
    const lookup_count = readU16BE(tbl, ll_abs) orelse return;

    // Count active lookups for logging
    var active_count: u32 = 0;
    for (0..@min(lookup_count, MAX_LOOKUPS)) |li| {
        if ((lookup_active[li / 8] & (@as(u8, 1) << @intCast(li % 8))) != 0) active_count += 1;
    }
    if (applog.isEnabled()) applog.appLog("[gsub] feature_count={d} lookup_count={d} active_lookups={d} tbl_size={d}\n", .{ feature_count, lookup_count, active_count, table_size });

    for (0..lookup_count) |li| {
        if (li >= MAX_LOOKUPS) break;
        // Check if this lookup is in our active set
        if ((lookup_active[li / 8] & (@as(u8, 1) << @intCast(li % 8))) == 0) continue;

        const lk_off_rel = readU16BE(tbl, ll_abs + 2 + li * 2) orelse continue;
        const lk_abs = ll_abs + @as(usize, lk_off_rel);

        // Lookup table: lookupType(2) + lookupFlag(2) + subTableCount(2) + subtableOffsets[]
        const lk_type = readU16BE(tbl, lk_abs) orelse continue;
        // Skip lookupFlag(2)
        const sub_count = readU16BE(tbl, lk_abs + 4) orelse continue;

        for (0..sub_count) |si| {
            const sub_off_rel = readU16BE(tbl, lk_abs + 6 + si * 2) orelse continue;
            const sub_abs = lk_abs + @as(usize, sub_off_rel);
            processSubtable(tbl, sub_abs, lk_type, ascii_gids, out_triggers, 0);
        }
    }
    if (applog.isEnabled()) applog.appLog("[gsub] parsing complete\n", .{});
}

fn encodeUtf16Scalar(scalar: u32, out: *[2]u16) usize {
    // Returns number of u16 written (1 or 2). Invalid range is replaced with U+FFFD.
    var cp: u32 = scalar;

    // Replace surrogate code points and out-of-range values.
    if ((cp >= 0xD800 and cp <= 0xDFFF) or cp > 0x10FFFF) {
        cp = 0xFFFD;
    }

    if (cp <= 0xFFFF) {
        out[0] = @intCast(cp);
        return 1;
    }

    const v = cp - 0x10000;
    out[0] = @intCast(0xD800 + ((v >> 10) & 0x3FF));
    out[1] = @intCast(0xDC00 + (v & 0x3FF));
    return 2;
}

fn utf8ToUtf16Alloc(alloc: std.mem.Allocator, s: []const u8) ![:0]u16 {
    var list: std.ArrayListUnmanaged(u16) = .empty;
    errdefer list.deinit(alloc);

    var it = (try std.unicode.Utf8View.init(s)).iterator();
    while (it.nextCodepoint()) |cp| {
        var buf: [2]u16 = undefined;
        const n = encodeUtf16Scalar(@intCast(cp), &buf);
        try list.appendSlice(alloc, buf[0..n]);
    }

    // Sentinel-terminated slice for Win32 APIs
    return try list.toOwnedSliceSentinel(alloc, 0);
}

fn L(comptime s: []const u8) [*:0]const u16 {
    return std.unicode.utf8ToUtf16LeStringLiteral(s);
}
