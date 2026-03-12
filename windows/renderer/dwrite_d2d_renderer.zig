const std = @import("std");
const core = @import("zonvie_core");
const c = @import("../win32.zig").c;
const applog = @import("../app_log.zig");

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

pub const Renderer = struct {
    alloc: std.mem.Allocator,
    hwnd: c.HWND,

    mu: std.Thread.Mutex = .{},

    d2d_factory: ?*c.ID2D1Factory = null,
    rt: ?*c.ID2D1HwndRenderTarget = null,

    dwrite_factory: ?*c.IDWriteFactory = null,
    text_format: ?*c.IDWriteTextFormat = null,

    // font + metrics needed by atlasEnsureGlyphEntry()
    font_face: ?*c.IDWriteFontFace = null,
    // Font variants for bold/italic (lazy-initialized on first use)
    bold_font_face: ?*c.IDWriteFontFace = null,
    italic_font_face: ?*c.IDWriteFontFace = null,
    bold_italic_font_face: ?*c.IDWriteFontFace = null,
    styled_fonts_initialized: bool = false,
    font_em_size: f32 = 14.0,
    base_point_size: f32 = 14.0, // original point size before DPI scaling
    dpi: u32 = 96,
    ascent_px: f32 = 0.0,
    descent_px: f32 = 0.0,
    font_name: [64]u16 = [_]u16{0} ** 64, // UTF-16 font family name for IME overlay

    // metrics
    cell_w_px: u32 = 9,
    cell_h_px: u32 = 18,

    // atlas
    atlas_bitmap: ?*c.ID2D1Bitmap = null,
    atlas_next_x: u32 = 1,
    atlas_next_y: u32 = 1,
    atlas_row_h: u32 = 0,

    // Pipeline
    vs: ?*c.ID3D11VertexShader = null,
    ps: ?*c.ID3D11PixelShader = null,
    il: ?*c.ID3D11InputLayout = null,
    sampler: ?*c.ID3D11SamplerState = null,
    blend: ?*c.ID3D11BlendState = null,

    // VS constants (viewport transform)
    vs_cb: ?*c.ID3D11Buffer = null,

    // Glyph cache: scalar -> entry (aligned with core types)
    glyph_map: std.AutoHashMap(u32, core.GlyphEntry),
    // Styled glyph cache: (scalar | (style_flags << 21)) -> entry
    // style_flags uses bits 21-22 since Unicode scalars only use bits 0-20
    styled_glyph_map: std.AutoHashMap(u32, core.GlyphEntry),

    // Atlas dimensions (set by recreateAtlasTexture, default 2048x2048)
    atlas_w: u32 = 2048,
    atlas_h: u32 = 2048,

    // CPU-side atlas (full size: atlas_w * atlas_h * 4 bytes).
    atlas_cpu: std.ArrayListUnmanaged(u8) = .{},
    
    // temporary buffer for a single glyph (padded) generation
    glyph_tmp: std.ArrayListUnmanaged(u8) = .{},
    
    // Append-only queue of atlas dirty rects. Entries are appended when glyphs
    // are rasterized and consumed independently by the D2D bitmap path (renderVertices)
    // and each D3D window via per-consumer cursors. Only cleared on atlas reset.
    pending_uploads: std.ArrayListUnmanaged(c.D2D1_RECT_U) = .{},
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

    // ---- add: profiling counters for atlasEnsureGlyphEntry ----
    log_atlas_ensure_calls: u64 = 0,
    log_atlas_ensure_hits: u64 = 0,
    log_atlas_ensure_misses: u64 = 0,
    log_atlas_ensure_last_report_ns: i128 = 0,
    log_atlas_ensure_slowest_ns: u64 = 0,

    // Atlas version - incremented when new glyphs are added (for multi-context sync)
    atlas_version: u64 = 0,
    // Set when atlas is reset; signals the UI thread to request a full re-seed
    // so stale UV coordinates in cached row vertices are refreshed.
    atlas_reset_pending: bool = false,

    // OpenType font features for DWrite shaping.
    font_features: [MAX_FONT_FEATURES]DWriteFontFeature = [_]DWriteFontFeature{.{ .nameTag = 0, .parameter = 0 }} ** MAX_FONT_FEATURES,
    font_feature_count: u32 = 0,
    text_analyzer: ?*c.IDWriteTextAnalyzer = null,

    // GSUB ligature trigger cache (see GsubCacheEntry above).
    // Invalidated on font/DPI/device changes.
    gsub_cache: [4]GsubCacheEntry = [_]GsubCacheEntry{.{}} ** 4,

    pub fn init(alloc: std.mem.Allocator, hwnd: c.HWND, initial_font: []const u8, initial_pt: f32) !Renderer {
        // Timing for init steps
        var freq: c.LARGE_INTEGER = undefined;
        var t0: c.LARGE_INTEGER = undefined;
        var t1: c.LARGE_INTEGER = undefined;
        if (applog.isEnabled()) _ = c.QueryPerformanceFrequency(&freq);

        var self: Renderer = .{
            .alloc = alloc,
            .hwnd = hwnd,

            // ★ Initialize required fields (guard against missing struct fields)
            .glyph_map = std.AutoHashMap(u32, core.GlyphEntry).init(alloc),
            .styled_glyph_map = std.AutoHashMap(u32, core.GlyphEntry).init(alloc),
        };
        errdefer {
            self.glyph_map.deinit();
            self.styled_glyph_map.deinit();
        }

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
        errdefer safeRelease(self.d2d_factory);
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
        errdefer safeRelease(self.dwrite_factory);
        if (applog.isEnabled()) {
            _ = c.QueryPerformanceCounter(&t1);
            applog.appLog("[d2d] [TIMING] DWriteCreateFactory: {d}ms\n", .{@divTrunc((t1.QuadPart - t0.QuadPart) * 1000, freq.QuadPart)});
        }

        // Create render target for hwnd
        if (applog.isEnabled()) _ = c.QueryPerformanceCounter(&t0);
        try self.recreateRenderTarget();
        errdefer safeRelease(self.rt);
        if (applog.isEnabled()) {
            _ = c.QueryPerformanceCounter(&t1);
            applog.appLog("[d2d] [TIMING] recreateRenderTarget: {d}ms\n", .{@divTrunc((t1.QuadPart - t0.QuadPart) * 1000, freq.QuadPart)});
        }

        // Get DPI for the window (Per-Monitor DPI Aware V2)
        const window_dpi = GetDpiForWindow(hwnd);
        self.dpi = if (window_dpi > 0) window_dpi else 96;
        if (applog.isEnabled()) applog.appLog("[d2d] window DPI: {d}\n", .{self.dpi});

        // Initial font (from config or OS default)
        if (applog.isEnabled()) _ = c.QueryPerformanceCounter(&t0);
        self.setFontUtf8(initial_font, initial_pt) catch |e| {
            // Fallback to OS default if initial font fails
            if (applog.isEnabled()) applog.appLog("[d2d] initial font '{s}' failed: {any}, trying Consolas\n", .{ initial_font, e });
            try self.setFontUtf8("Consolas", 14.0);
        };
        if (applog.isEnabled()) {
            _ = c.QueryPerformanceCounter(&t1);
            applog.appLog("[d2d] [TIMING] setFontUtf8: {d}ms\n", .{@divTrunc((t1.QuadPart - t0.QuadPart) * 1000, freq.QuadPart)});
        }

        return self;
    }

    pub fn deinit(self: *Renderer) void {
        // ★ Added: free containers
        self.glyph_map.deinit();
        self.styled_glyph_map.deinit();

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
        safeRelease(self.dwrite_factory);
        safeRelease(self.d2d_factory);
        self.* = undefined;
    }

    /// Reset atlas when full - clears glyph caches and restarts packing
    fn resetAtlas(self: *Renderer) void {
        if (applog.isEnabled()) applog.appLog("[atlas] resetAtlas: clearing {d} glyphs + {d} styled glyphs\n", .{
            self.glyph_map.count(),
            self.styled_glyph_map.count(),
        });

        // Clear glyph caches (keep capacity for reuse)
        self.glyph_map.clearRetainingCapacity();
        self.styled_glyph_map.clearRetainingCapacity();

        // Reset atlas placement cursors
        self.atlas_next_x = 1;
        self.atlas_next_y = 1;
        self.atlas_row_h = 0;

        // Clear pending uploads (they're now invalid); advance base_seq so
        // per-window cursors that lag behind will detect the gap.
        self.pending_upload_base_seq += self.pending_uploads.items.len;
        self.pending_uploads.clearRetainingCapacity();

        // Clear CPU atlas buffer to zero (optional but cleaner)
        if (self.atlas_cpu.items.len > 0) {
            @memset(self.atlas_cpu.items, 0);
        }

        self.atlas_reset_pending = true;
    }

    pub const BgSpan = extern struct {
        row: u32,
        col_start: u32,
        col_end: u32,
        bgRGB: u32,
    };
    pub const TextRun = extern struct {
        row: u32,
        col_start: u32,
        len: u32,
        fgRGB: u32,
        bgRGB: u32,
        scalars: [*]const u32,
    };
    pub const Cursor = extern struct {
        enabled: u32,
        row: u32,
        col: u32,
        shape: u32,
        cell_percentage: u32,
        fgRGB: u32,
        bgRGB: u32,
    };

    /// Recreate the D2D render target. Caller must hold self.mu.
    fn recreateRenderTargetLocked(self: *Renderer) !void {
        // Timing for sub-steps
        var freq: c.LARGE_INTEGER = undefined;
        var t0: c.LARGE_INTEGER = undefined;
        var t1: c.LARGE_INTEGER = undefined;
        if (applog.isEnabled()) _ = c.QueryPerformanceFrequency(&freq);

        safeRelease(self.rt);
        self.rt = null;

        const hwnd: c.HWND = self.hwnd;
        var rc: c.RECT = undefined;
        _ = c.GetClientRect(hwnd, &rc);

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
            .hwnd = hwnd,
            .pixelSize = size,
            .presentOptions = c.D2D1_PRESENT_OPTIONS_NONE,
        };

        var rt: ?*c.ID2D1HwndRenderTarget = null;

        const factory = self.d2d_factory orelse return error.NotInitialized;
        const vtbl = factory.lpVtbl.*;
        const create_fn = vtbl.CreateHwndRenderTarget orelse return error.D2DFactoryMissingCreateHwndRenderTarget;

        if (applog.isEnabled()) _ = c.QueryPerformanceCounter(&t0);
        const hr = create_fn(
            factory,
            &rt_props,
            &hwnd_props,
            &rt,
        );
        if (applog.isEnabled()) {
            _ = c.QueryPerformanceCounter(&t1);
            applog.appLog("[d2d] [TIMING]   CreateHwndRenderTarget: {d}ms\n", .{@divTrunc((t1.QuadPart - t0.QuadPart) * 1000, freq.QuadPart)});
        }

        if (hr != 0 or rt == null) return error.D2DCreateHwndRenderTargetFailed;

        self.rt = rt;
        errdefer {
            safeRelease(self.rt);
            self.rt = null;
        }

        if (applog.isEnabled()) _ = c.QueryPerformanceCounter(&t0);
        try self.createAtlasResources();
        if (applog.isEnabled()) {
            _ = c.QueryPerformanceCounter(&t1);
            applog.appLog("[d2d] [TIMING]   createAtlasResources: {d}ms\n", .{@divTrunc((t1.QuadPart - t0.QuadPart) * 1000, freq.QuadPart)});
        }

        // Invalidate GSUB cache on device recreation (conservative; font faces may
        // still be valid, but atlas and glyph state have been reset).
        self.gsub_cache = [_]GsubCacheEntry{.{}} ** 4;
    }

    /// Public wrapper that acquires self.mu before recreating the render target.
    fn recreateRenderTarget(self: *Renderer) !void {
        self.mu.lock();
        defer self.mu.unlock();
        try self.recreateRenderTargetLocked();
    }

    fn createAtlasResources(self: *Renderer) !void {
        const rt = self.rt orelse return;
    
        safeRelease(self.atlas_bitmap);
        self.atlas_bitmap = null;
        
        safeRelease(self.solid_brush);
        self.solid_brush = null;
    
        self.glyph_map.clearRetainingCapacity();
        self.styled_glyph_map.clearRetainingCapacity();
        self.atlas_next_x = 1;
        self.atlas_next_y = 1;
        self.atlas_row_h = 0;
    
        // RGBA format for true ClearType subpixel rendering
        const props = c.D2D1_BITMAP_PROPERTIES{
            .pixelFormat = c.D2D1_PIXEL_FORMAT{
                .format = c.DXGI_FORMAT_R8G8B8A8_UNORM,
                .alphaMode = c.D2D1_ALPHA_MODE_PREMULTIPLIED,
            },
            .dpiX = 96.0,
            .dpiY = 96.0,
        };
    
        var bmp: ?*c.ID2D1Bitmap = null;
        const sz = c.D2D1_SIZE_U{ .width = self.atlas_w, .height = self.atlas_h };

        // ★ HwndRenderTarget vtbl doesn't expose CreateBitmap, so cast to base RenderTarget
        const rt_base: *c.ID2D1RenderTarget = @as(*c.ID2D1RenderTarget, @ptrCast(rt));
        const vtbl = rt_base.lpVtbl.*;
        
        const hr = if (vtbl.CreateBitmap) |create_bitmap_fn| blk: {
            break :blk create_bitmap_fn(
                rt_base,
                sz,
                null,
                0,
                &props,
                &bmp,
            );
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

        if (c.FAILED(hr) or bmp == null) return error.CreateAtlasFailed;
        self.atlas_bitmap = bmp;
        errdefer {
            safeRelease(self.atlas_bitmap);
            self.atlas_bitmap = null;
        }

        // brush
        var br: ?*c.ID2D1SolidColorBrush = null;
        const c0 = c.D2D1_COLOR_F{ .r = 1, .g = 1, .b = 1, .a = 1 };

        const hr2 = if (vtbl.CreateSolidColorBrush) |create_brush_fn| blk: {
            break :blk create_brush_fn(
                rt_base,
                &c0,
                null,
                &br,
            );
        } else return error.CreateBrushFailed;
        
        if (c.FAILED(hr2) or br == null) return error.CreateBrushFailed;
        self.solid_brush = br;
        errdefer {
            safeRelease(self.solid_brush);
            self.solid_brush = null;
        }

        // 4 bytes per pixel (RGBA) for true ClearType subpixel rendering
        const total = @as(usize, self.atlas_w) * @as(usize, self.atlas_h) * 4;
        try self.atlas_cpu.resize(self.alloc, total);
        @memset(self.atlas_cpu.items, 0);

        self.pending_upload_base_seq += self.pending_uploads.items.len;
        self.pending_uploads.clearRetainingCapacity();

        const bmp_ptr = self.atlas_bitmap orelse return error.CreateAtlasFailed;
        const bvtbl = bmp_ptr.lpVtbl.*;
        const copy_fn = bvtbl.CopyFromMemory orelse return error.BitmapMissingCopyFromMemory;

        const rect = c.D2D1_RECT_U{ .left = 0, .top = 0, .right = self.atlas_w, .bottom = self.atlas_h };

        const hr3 = copy_fn(
            bmp_ptr,
            &rect,
            self.atlas_cpu.items.ptr,
            self.atlas_w * 4, // bytes per row (RGBA)
        );
        
        if (c.FAILED(hr3)) return error.ClearAtlasFailed;



        if (c.FAILED(hr3)) return error.ClearAtlasFailed;
    }

pub fn atlasEnsureGlyphEntry(self: *Renderer, scalar: u32) !core.GlyphEntry {
    // Guard shared atlas state (glyph_map/atlas_cpu/pending_uploads) against
    // concurrent WM_PAINT uploads and other ensure calls.
    self.mu.lock();
    defer self.mu.unlock();

    // ---- log/profiling (aggregated) ----
    const log_enabled = applog.isEnabled();
    const log_start_ns: i128 = if (log_enabled) std.time.nanoTimestamp() else 0;

    self.log_atlas_ensure_calls += 1;

    // cache hit
    if (self.glyph_map.get(scalar)) |cached| {
        self.log_atlas_ensure_hits += 1;

        if (log_enabled) {
            const log_now_ns: i128 = std.time.nanoTimestamp();
            if (self.log_atlas_ensure_last_report_ns == 0) self.log_atlas_ensure_last_report_ns = log_now_ns;

            // once per second
            if (log_now_ns - self.log_atlas_ensure_last_report_ns >= @as(i128, 1_000_000_000)) {
                applog.appLog(
                    "[atlas] ensureGlyph stats: calls/s={d} hits/s={d} misses/s={d} cache={d} slowest_ms={d}\n",
                    .{
                        self.log_atlas_ensure_calls,
                        self.log_atlas_ensure_hits,
                        self.log_atlas_ensure_misses,
                        self.glyph_map.count(),
                        @as(u64, self.log_atlas_ensure_slowest_ns / 1_000_000),
                    },
                );
                self.log_atlas_ensure_calls = 0;
                self.log_atlas_ensure_hits = 0;
                self.log_atlas_ensure_misses = 0;
                self.log_atlas_ensure_slowest_ns = 0;
                self.log_atlas_ensure_last_report_ns = log_now_ns;
            }
        }

        return cached;
    }

    self.log_atlas_ensure_misses += 1;

    // miss-duration will be recorded on each miss-return path below
    const face = self.font_face orelse return error.NoFont;

    // --- 1) scalar -> glyph_index (with OpenType feature support) ---
    const glyph_index = self.getGlyphIndexForScalar(face, scalar) catch |e| {
        if (applog.isEnabled()) applog.appLog("[dwrite] getGlyphIndexForScalar FAILED scalar=0x{x}: {any}\n", .{
            scalar, e,
        });

        if (log_enabled) {
            const log_end_ns: i128 = std.time.nanoTimestamp();
            const log_dur_ns_u64: u64 = @intCast(@max(@as(i128, 0), log_end_ns - log_start_ns));
            if (log_dur_ns_u64 > self.log_atlas_ensure_slowest_ns) self.log_atlas_ensure_slowest_ns = log_dur_ns_u64;
            applog.appLog("[atlas] ensureGlyph MISS scalar=0x{x} dur_ms={d}\n", .{ scalar, log_dur_ns_u64 / 1_000_000 });
        }

        return error.DWriteGetGlyphIndicesFailed;
    };

    if (glyph_index == 0) {
        // 0 is possibly .notdef; log only
        if (applog.isEnabled()) applog.appLog("[dwrite] ensure WARNING: glyph_index==0 scalar=0x{x}\n", .{scalar});
    } else {
        if (applog.isEnabled()) applog.appLog("[dwrite] ensure scalar=0x{x} glyph_index={d}\n", .{ scalar, glyph_index });
    }

    // --- 2) glyph run analysis -> alpha texture bounds ---
    var glyph_run: c.DWRITE_GLYPH_RUN = std.mem.zeroes(c.DWRITE_GLYPH_RUN);
    glyph_run.fontFace = face;
    glyph_run.fontEmSize = self.font_em_size; // assumed set in setFontUtf8
    glyph_run.glyphCount = 1;

    var gi_arr: [1]c.UINT16 = .{ glyph_index };
    var adv_arr: [1]c.FLOAT = .{ @as(c.FLOAT, @floatFromInt(self.cell_w_px)) };
    var off_arr: [1]c.DWRITE_GLYPH_OFFSET = .{ .{ .advanceOffset = 0, .ascenderOffset = 0 } };

    glyph_run.glyphIndices = gi_arr[0..].ptr;
    glyph_run.glyphAdvances = adv_arr[0..].ptr;
    glyph_run.glyphOffsets = off_arr[0..].ptr;

    // CreateGlyphRunAnalysis
    const dw = self.dwrite_factory orelse return error.DWriteFactoryNotReady;
    const dwtbl = dw.lpVtbl.*;
    var analysis: ?*c.IDWriteGlyphRunAnalysis = null;

    const create_analysis_fn = dwtbl.CreateGlyphRunAnalysis orelse
        return error.DWriteFactoryMissingCreateGlyphRunAnalysis;

    // CreateGlyphRunAnalysis
    //
    // NOTE:
    // We use NATURAL_SYMMETRIC for high-quality anti-aliased rendering.
    // This produces ClearType 3x1 texture (3 bytes per pixel RGB).
    // We average RGB to get grayscale alpha for our A8 atlas.
    const hr_cgra = create_analysis_fn(
        dw,
        &glyph_run,
        1.0,
        null,
        c.DWRITE_RENDERING_MODE_NATURAL_SYMMETRIC,
        c.DWRITE_MEASURING_MODE_NATURAL,
        0.0,
        0.0,
        &analysis,
    );

    if (c.FAILED(hr_cgra) or analysis == null) {
        if (applog.isEnabled()) applog.appLog("[dwrite] CreateGlyphRunAnalysis FAILED hr=0x{x}\n", .{
            @as(u32, @bitCast(hr_cgra)),
        });

        if (log_enabled) {
            const log_end_ns: i128 = std.time.nanoTimestamp();
            const log_dur_ns_u64: u64 = @intCast(@max(@as(i128, 0), log_end_ns - log_start_ns));
            if (log_dur_ns_u64 > self.log_atlas_ensure_slowest_ns) self.log_atlas_ensure_slowest_ns = log_dur_ns_u64;
            applog.appLog("[atlas] ensureGlyph MISS scalar=0x{x} dur_ms={d}\n", .{ scalar, log_dur_ns_u64 / 1_000_000 });
        }

        return error.DWriteCreateGlyphRunAnalysisFailed;
    }

    const rel_fn = analysis.?.lpVtbl.*.Release orelse return error.DWriteGlyphRunAnalysisMissingRelease;
    defer _ = rel_fn(analysis.?);

    var bounds: c.RECT = std.mem.zeroes(c.RECT);
    const atbl = analysis.?.lpVtbl.*;

    const get_bounds_fn = atbl.GetAlphaTextureBounds orelse
        return error.DWriteGlyphRunAnalysisMissingGetAlphaTextureBounds;

    const hr_bounds = get_bounds_fn(
        analysis.?,
        c.DWRITE_TEXTURE_CLEARTYPE_3x1,
        &bounds,
    );
    if (c.FAILED(hr_bounds)) {
        if (applog.isEnabled()) applog.appLog("[dwrite] GetAlphaTextureBounds FAILED hr=0x{x}\n", .{
            @as(u32, @bitCast(hr_bounds)),
        });

        if (log_enabled) {
            const log_end_ns: i128 = std.time.nanoTimestamp();
            const log_dur_ns_u64: u64 = @intCast(@max(@as(i128, 0), log_end_ns - log_start_ns));
            if (log_dur_ns_u64 > self.log_atlas_ensure_slowest_ns) self.log_atlas_ensure_slowest_ns = log_dur_ns_u64;
            applog.appLog("[atlas] ensureGlyph MISS scalar=0x{x} dur_ms={d}\n", .{ scalar, log_dur_ns_u64 / 1_000_000 });
        }

        return error.DWriteGetAlphaTextureBoundsFailed;
    }

    const bw_i32: i32 = bounds.right - bounds.left;
    const bh_i32: i32 = bounds.bottom - bounds.top;
    const bw: u32 = if (bw_i32 > 0) @as(u32, @intCast(bw_i32)) else 0;
    const bh: u32 = if (bh_i32 > 0) @as(u32, @intCast(bh_i32)) else 0;

    if (applog.isEnabled()) {
        applog.appLog("[dwrite] bounds scalar=0x{x} rect(l={d} t={d} r={d} b={d}) w={d} h={d}\n", .{
            scalar, bounds.left, bounds.top, bounds.right, bounds.bottom, bw, bh,
        });
    }

    if (bw == 0 or bh == 0) {
        // Empty glyph (e.g. space)
        const empty = core.GlyphEntry{
            .uv_min = .{ -1, -1 },
            .uv_max = .{ -1, -1 },
            .bbox_origin_px = .{ 0, 0 },
            .bbox_size_px = .{ 0, 0 },
            .advance_px = @as(f32, @floatFromInt(self.cell_w_px)),
            .ascent_px = self.ascent_px,
            .descent_px = self.descent_px,
        };
        try self.glyph_map.put(scalar, empty);

        if (log_enabled) {
            const log_end_ns: i128 = std.time.nanoTimestamp();
            const log_dur_ns_u64: u64 = @intCast(@max(@as(i128, 0), log_end_ns - log_start_ns));
            if (log_dur_ns_u64 > self.log_atlas_ensure_slowest_ns) self.log_atlas_ensure_slowest_ns = log_dur_ns_u64;
            applog.appLog("[atlas] ensureGlyph MISS scalar=0x{x} dur_ms={d}\n", .{ scalar, log_dur_ns_u64 / 1_000_000 });

            // also allow once-per-second summary emission on miss path
            const log_now_ns: i128 = std.time.nanoTimestamp();
            if (self.log_atlas_ensure_last_report_ns == 0) self.log_atlas_ensure_last_report_ns = log_now_ns;
            if (log_now_ns - self.log_atlas_ensure_last_report_ns >= @as(i128, 1_000_000_000)) {
                applog.appLog(
                    "[atlas] ensureGlyph stats: calls/s={d} hits/s={d} misses/s={d} cache={d} slowest_ms={d}\n",
                    .{
                        self.log_atlas_ensure_calls,
                        self.log_atlas_ensure_hits,
                        self.log_atlas_ensure_misses,
                        self.glyph_map.count(),
                        @as(u64, self.log_atlas_ensure_slowest_ns / 1_000_000),
                    },
                );
                self.log_atlas_ensure_calls = 0;
                self.log_atlas_ensure_hits = 0;
                self.log_atlas_ensure_misses = 0;
                self.log_atlas_ensure_slowest_ns = 0;
                self.log_atlas_ensure_last_report_ns = log_now_ns;
            }
        }

        return empty;
    }

    // --- 3) fetch ClearType 3x1 texture (RGB, 3 bytes per pixel) ---
    const buf_size_rgb: usize = @as(usize, bw) * @as(usize, bh) * 3;
    const tmp_rgb = try self.alloc.alloc(u8, buf_size_rgb);
    defer self.alloc.free(tmp_rgb);

    const create_alpha_fn = atbl.CreateAlphaTexture orelse
        return error.DWriteGlyphRunAnalysisMissingCreateAlphaTexture;

    const hr_tex = create_alpha_fn(
        analysis.?,
        c.DWRITE_TEXTURE_CLEARTYPE_3x1,
        &bounds,
        tmp_rgb.ptr,
        @as(c.UINT32, @intCast(tmp_rgb.len)),
    );
    if (c.FAILED(hr_tex)) {
        if (applog.isEnabled()) applog.appLog("[dwrite] CreateAlphaTexture FAILED hr=0x{x}\n", .{
            @as(u32, @bitCast(hr_tex)),
        });

        if (log_enabled) {
            const log_end_ns: i128 = std.time.nanoTimestamp();
            const log_dur_ns_u64: u64 = @intCast(@max(@as(i128, 0), log_end_ns - log_start_ns));
            if (log_dur_ns_u64 > self.log_atlas_ensure_slowest_ns) self.log_atlas_ensure_slowest_ns = log_dur_ns_u64;
            applog.appLog("[atlas] ensureGlyph MISS scalar=0x{x} dur_ms={d}\n", .{ scalar, log_dur_ns_u64 / 1_000_000 });
        }

        return error.DWriteCreateAlphaTextureFailed;
    }

    // --- 4) pack into atlas CPU buffer (place_x/place_y unified) ---
    const pad: u32 = 1;
    const packed_w: u32 = bw + pad * 2;
    const packed_h: u32 = bh + pad * 2;

    // wrap to next row if needed
    if (self.atlas_next_x + packed_w + 1 >= self.atlas_w) {
        self.atlas_next_x = 1;
        self.atlas_next_y += self.atlas_row_h + 1;
        self.atlas_row_h = 0;
    }
    // If atlas is full, reset and retry (simple eviction strategy)
    if (self.atlas_next_y + packed_h + 1 >= self.atlas_h) {
        if (applog.isEnabled()) applog.appLog("[atlas] ensureGlyph scalar=0x{x}: atlas full, resetting\n", .{scalar});
        self.resetAtlas();

        // After reset, re-check row wrap (should start at x=1, y=1)
        if (self.atlas_next_x + packed_w + 1 >= self.atlas_w) {
            self.atlas_next_x = 1;
            self.atlas_next_y += self.atlas_row_h + 1;
            self.atlas_row_h = 0;
        }
        // If still doesn't fit after reset, glyph is too large for atlas
        if (self.atlas_next_y + packed_h + 1 >= self.atlas_h) {
            if (applog.isEnabled()) applog.appLog("[atlas] ensureGlyph scalar=0x{x}: glyph too large for atlas ({d}x{d})\n", .{ scalar, packed_w, packed_h });
            return error.GlyphTooLarge;
        }
    }

    // IMPORTANT: freeze placement before advancing the cursor
    const place_x: u32 = self.atlas_next_x;
    const place_y: u32 = self.atlas_next_y;

    self.atlas_next_x += packed_w + 1;
    self.atlas_row_h = @max(self.atlas_row_h, packed_h);

    // Clear padded area to 0 (outline padding) - RGBA format (4 bytes per pixel)
    {
        var y: u32 = 0;
        while (y < packed_h) : (y += 1) {
            const row_off = ((@as(usize, place_y + y) * @as(usize, self.atlas_w)) + @as(usize, place_x)) * 4;
            @memset(self.atlas_cpu.items[row_off .. row_off + packed_w * 4], 0);
        }
    }

    // Copy glyph RGB directly for true ClearType subpixel rendering
    // ClearType 3x1 format: 3 bytes per pixel (R, G, B)
    // Atlas format: RGBA (4 bytes per pixel)
    {
        var y: u32 = 0;
        while (y < bh) : (y += 1) {
            var x: u32 = 0;
            while (x < bw) : (x += 1) {
                const src_off = (@as(usize, y) * @as(usize, bw) + @as(usize, x)) * 3;
                const dst_off = ((@as(usize, place_y + pad + y) * @as(usize, self.atlas_w)) + @as(usize, place_x + pad + x)) * 4;

                // Store RGB directly for subpixel blending
                const r = tmp_rgb[src_off];
                const g = tmp_rgb[src_off + 1];
                const b = tmp_rgb[src_off + 2];

                self.atlas_cpu.items[dst_off + 0] = r; // R
                self.atlas_cpu.items[dst_off + 1] = g; // G
                self.atlas_cpu.items[dst_off + 2] = b; // B
                // Alpha = max(R, G, B) for correct alpha blending with background
                self.atlas_cpu.items[dst_off + 3] = @max(r, @max(g, b));
            }
        }
    }

    // Mark dirty rect for GPU upload (place_x/place_y)
    try self.pending_uploads.append(self.alloc, c.D2D1_RECT_U{
        .left = place_x,
        .top = place_y,
        .right = place_x + packed_w,
        .bottom = place_y + packed_h,
    });

    // Increment atlas version for multi-context sync
    self.atlas_version +%= 1;

    // UV for *actual glyph area* excluding padding
    const uv_u0 = @as(f32, @floatFromInt(place_x + pad)) / @as(f32, @floatFromInt(self.atlas_w));
    const uv_v0 = @as(f32, @floatFromInt(place_y + pad)) / @as(f32, @floatFromInt(self.atlas_h));
    const uv_u1 = @as(f32, @floatFromInt(place_x + pad + bw)) / @as(f32, @floatFromInt(self.atlas_w));
    const uv_v1 = @as(f32, @floatFromInt(place_y + pad + bh)) / @as(f32, @floatFromInt(self.atlas_h));

    const entry = core.GlyphEntry{
        .uv_min = .{ uv_u0, uv_v0 },
        .uv_max = .{ uv_u1, uv_v1 },

        // bounds are relative to baseline; left can be negative, bottom can be positive
        // vertexgen uses: y0 = baseline - (origin_y + h)
        // Setting origin_y = -bounds.bottom makes y0 = baseline + bounds.top (since top = bottom - h)
        .bbox_origin_px = .{
            @as(f32, @floatFromInt(bounds.left)),
            @as(f32, @floatFromInt(-bounds.bottom)),
        },
        .bbox_size_px = .{
            @as(f32, @floatFromInt(bw)),
            @as(f32, @floatFromInt(bh)),
        },

        .advance_px = @as(f32, @floatFromInt(self.cell_w_px)),
        .ascent_px = self.ascent_px,
        .descent_px = self.descent_px,
    };

    try self.glyph_map.put(scalar, entry);

    if (log_enabled) {
        const log_end_ns: i128 = std.time.nanoTimestamp();
        const log_dur_ns_u64: u64 = @intCast(@max(@as(i128, 0), log_end_ns - log_start_ns));
        if (log_dur_ns_u64 > self.log_atlas_ensure_slowest_ns) self.log_atlas_ensure_slowest_ns = log_dur_ns_u64;

        applog.appLog("[atlas] ensureGlyph MISS scalar=0x{x} dur_ms={d}\n", .{ scalar, log_dur_ns_u64 / 1_000_000 });

        // allow once-per-second summary emission on miss path as well
        const log_now_ns: i128 = std.time.nanoTimestamp();
        if (self.log_atlas_ensure_last_report_ns == 0) self.log_atlas_ensure_last_report_ns = log_now_ns;
        if (log_now_ns - self.log_atlas_ensure_last_report_ns >= @as(i128, 1_000_000_000)) {
            applog.appLog(
                "[atlas] ensureGlyph stats: calls/s={d} hits/s={d} misses/s={d} cache={d} slowest_ms={d}\n",
                .{
                    self.log_atlas_ensure_calls,
                    self.log_atlas_ensure_hits,
                    self.log_atlas_ensure_misses,
                    self.glyph_map.count(),
                    @as(u64, self.log_atlas_ensure_slowest_ns / 1_000_000),
                },
            );
            self.log_atlas_ensure_calls = 0;
            self.log_atlas_ensure_hits = 0;
            self.log_atlas_ensure_misses = 0;
            self.log_atlas_ensure_slowest_ns = 0;
            self.log_atlas_ensure_last_report_ns = log_now_ns;
        }
    }

    return entry;
}

    // Style flags constants (match ZONVIE_STYLE_* in zonvie_core.h)
    const STYLE_BOLD: u32 = 1 << 0;
    const STYLE_ITALIC: u32 = 1 << 1;

    /// Styled glyph lookup: selects bold/italic font variant based on style_flags
    pub fn atlasEnsureGlyphEntryStyled(self: *Renderer, scalar: u32, style_flags: u32) !core.GlyphEntry {
        // If no style flags or no variant faces available, fall back to regular
        if (style_flags == 0) {
            return self.atlasEnsureGlyphEntry(scalar);
        }

        // Guard shared atlas state against concurrent WM_PAINT uploads
        self.mu.lock();

        // Composite cache key: scalar in lower 21 bits, style_flags in upper bits
        const cache_key: u32 = scalar | (style_flags << 21);

        // Check styled glyph cache first
        if (self.styled_glyph_map.get(cache_key)) |cached| {
            g_log_styled_hits += 1;
            self.mu.unlock();
            return cached;
        }

        g_log_styled_misses += 1;

        // Lazy-load Bold/Italic/Bold+Italic font faces if not yet initialized
        self.ensureStyledFontFaces();

        // Select font face based on style flags
        const is_bold = (style_flags & STYLE_BOLD) != 0;
        const is_italic = (style_flags & STYLE_ITALIC) != 0;

        const face: ?*c.IDWriteFontFace = blk: {
            if (is_bold and is_italic) {
                break :blk self.bold_italic_font_face orelse self.bold_font_face orelse self.italic_font_face orelse self.font_face;
            } else if (is_bold) {
                break :blk self.bold_font_face orelse self.font_face;
            } else if (is_italic) {
                break :blk self.italic_font_face orelse self.font_face;
            } else {
                break :blk self.font_face;
            }
        };

        if (face == null) {
            self.mu.unlock();
            return error.NoFont;
        }

        // Render glyph with the selected font face
        // If variant font fails, fall back to regular atlasEnsureGlyphEntry (which handles edge cases better)
        const entry = self.renderGlyphWithFace(scalar, face.?) catch |err| blk: {
            g_log_styled_fallbacks += 1;
            if (applog.isEnabled()) applog.appLog("[styled] fallback scalar=0x{x} style=0x{x} err={any}\n", .{ scalar, style_flags, err });
            // Unlock before calling atlasEnsureGlyphEntry (which takes its own lock)
            self.mu.unlock();
            const fallback_entry = self.atlasEnsureGlyphEntry(scalar) catch {
                return err; // Both failed, return original error
            };
            // Re-lock to continue with caching
            self.mu.lock();
            break :blk fallback_entry;
        };

        // Log the entry details for debugging
        if (applog.isEnabled() and g_log_styled_misses < 20) {
            applog.appLog("[styled] MISS scalar=0x{x} ({c}) style=0x{x} bbox=({d:.1},{d:.1}) uv=({d:.3},{d:.3})\n", .{
                scalar,
                if (scalar >= 32 and scalar < 127) @as(u8, @intCast(scalar)) else '?',
                style_flags,
                entry.bbox_size_px[0],
                entry.bbox_size_px[1],
                entry.uv_min[0],
                entry.uv_min[1],
            });
        }

        // Periodic stats report
        if (applog.isEnabled()) {
            const now_ns: i128 = std.time.nanoTimestamp();
            if (g_log_styled_last_report_ns == 0) g_log_styled_last_report_ns = now_ns;
            if (now_ns - g_log_styled_last_report_ns >= @as(i128, 1_000_000_000)) {
                applog.appLog("[styled] stats: hits={d} misses={d} fallbacks={d}\n", .{ g_log_styled_hits, g_log_styled_misses, g_log_styled_fallbacks });
                g_log_styled_hits = 0;
                g_log_styled_misses = 0;
                g_log_styled_fallbacks = 0;
                g_log_styled_last_report_ns = now_ns;
            }
        }

        self.styled_glyph_map.put(cache_key, entry) catch {
            self.mu.unlock();
            return error.OutOfMemory;
        };
        self.mu.unlock();
        return entry;
    }

    /// Internal helper: render glyph with a specific font face
    fn renderGlyphWithFace(self: *Renderer, scalar: u32, face: *c.IDWriteFontFace) !core.GlyphEntry {
        // --- 1) scalar -> glyph_index (with OpenType feature support) ---
        const glyph_index = try self.getGlyphIndexForScalar(face, scalar);

        // glyph_index == 0 means .notdef (font doesn't have this glyph)
        // Return error so caller can fall back to regular font
        if (glyph_index == 0) {
            return error.GlyphNotFound;
        }

        // --- 2) glyph run analysis -> alpha texture bounds ---
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

        // CreateGlyphRunAnalysis
        const dw = self.dwrite_factory orelse return error.DWriteFactoryNotReady;
        const dwtbl = dw.lpVtbl.*;
        var analysis: ?*c.IDWriteGlyphRunAnalysis = null;

        const create_analysis_fn = dwtbl.CreateGlyphRunAnalysis orelse
            return error.DWriteFactoryMissingCreateGlyphRunAnalysis;

        const hr_cgra = create_analysis_fn(
            dw,
            &glyph_run,
            1.0,
            null,
            c.DWRITE_RENDERING_MODE_NATURAL_SYMMETRIC,
            c.DWRITE_MEASURING_MODE_NATURAL,
            0.0,
            0.0,
            &analysis,
        );

        if (c.FAILED(hr_cgra) or analysis == null) {
            return error.DWriteCreateGlyphRunAnalysisFailed;
        }

        const rel_fn = analysis.?.lpVtbl.*.Release orelse return error.DWriteGlyphRunAnalysisMissingRelease;
        defer _ = rel_fn(analysis.?);

        var bounds: c.RECT = std.mem.zeroes(c.RECT);
        const atbl = analysis.?.lpVtbl.*;

        const get_bounds_fn = atbl.GetAlphaTextureBounds orelse
            return error.DWriteGlyphRunAnalysisMissingGetAlphaTextureBounds;

        const hr_bounds = get_bounds_fn(
            analysis.?,
            c.DWRITE_TEXTURE_CLEARTYPE_3x1,
            &bounds,
        );
        if (c.FAILED(hr_bounds)) {
            return error.DWriteGetAlphaTextureBoundsFailed;
        }

        const bw_i32: i32 = bounds.right - bounds.left;
        const bh_i32: i32 = bounds.bottom - bounds.top;
        const bw: u32 = if (bw_i32 > 0) @as(u32, @intCast(bw_i32)) else 0;
        const bh: u32 = if (bh_i32 > 0) @as(u32, @intCast(bh_i32)) else 0;

        if (bw == 0 or bh == 0) {
            // Empty glyph bounds - return error to trigger fallback to regular font
            // (Spaces are already skipped in nvim_core.zig before reaching here)
            return error.EmptyGlyphBounds;
        }

        // --- 3) fetch ClearType 3x1 texture (RGB, 3 bytes per pixel) ---
        const buf_size_rgb: usize = @as(usize, bw) * @as(usize, bh) * 3;
        const tmp_rgb = try self.alloc.alloc(u8, buf_size_rgb);
        defer self.alloc.free(tmp_rgb);

        const create_alpha_fn = atbl.CreateAlphaTexture orelse
            return error.DWriteGlyphRunAnalysisMissingCreateAlphaTexture;

        const hr_tex = create_alpha_fn(
            analysis.?,
            c.DWRITE_TEXTURE_CLEARTYPE_3x1,
            &bounds,
            tmp_rgb.ptr,
            @as(c.UINT32, @intCast(tmp_rgb.len)),
        );
        if (c.FAILED(hr_tex)) {
            return error.DWriteCreateAlphaTextureFailed;
        }

        // --- 4) pack into atlas CPU buffer ---
        const pad: u32 = 1;
        const packed_w: u32 = bw + pad * 2;
        const packed_h: u32 = bh + pad * 2;

        // wrap to next row if needed
        if (self.atlas_next_x + packed_w + 1 >= self.atlas_w) {
            self.atlas_next_x = 1;
            self.atlas_next_y += self.atlas_row_h + 1;
            self.atlas_row_h = 0;
        }
        // If atlas is full, reset and retry (simple eviction strategy)
        if (self.atlas_next_y + packed_h + 1 >= self.atlas_h) {
            if (applog.isEnabled()) applog.appLog("[atlas] renderGlyphWithFace scalar=0x{x}: atlas full, resetting\n", .{scalar});
            self.resetAtlas();

            // After reset, re-check row wrap
            if (self.atlas_next_x + packed_w + 1 >= self.atlas_w) {
                self.atlas_next_x = 1;
                self.atlas_next_y += self.atlas_row_h + 1;
                self.atlas_row_h = 0;
            }
            // If still doesn't fit after reset, glyph is too large
            if (self.atlas_next_y + packed_h + 1 >= self.atlas_h) {
                if (applog.isEnabled()) applog.appLog("[atlas] renderGlyphWithFace scalar=0x{x}: glyph too large ({d}x{d})\n", .{ scalar, packed_w, packed_h });
                return error.GlyphTooLarge;
            }
        }

        const place_x: u32 = self.atlas_next_x;
        const place_y: u32 = self.atlas_next_y;

        self.atlas_next_x += packed_w + 1;
        self.atlas_row_h = @max(self.atlas_row_h, packed_h);

        // Clear padded area to 0 - RGBA format (4 bytes per pixel)
        {
            var y: u32 = 0;
            while (y < packed_h) : (y += 1) {
                const row_off = ((@as(usize, place_y + y) * @as(usize, self.atlas_w)) + @as(usize, place_x)) * 4;
                @memset(self.atlas_cpu.items[row_off .. row_off + packed_w * 4], 0);
            }
        }

        // Copy glyph RGB directly for true ClearType subpixel rendering
        {
            var y: u32 = 0;
            while (y < bh) : (y += 1) {
                var x: u32 = 0;
                while (x < bw) : (x += 1) {
                    const src_off = (@as(usize, y) * @as(usize, bw) + @as(usize, x)) * 3;
                    const dst_off = ((@as(usize, place_y + pad + y) * @as(usize, self.atlas_w)) + @as(usize, place_x + pad + x)) * 4;

                    const r = tmp_rgb[src_off];
                    const g = tmp_rgb[src_off + 1];
                    const b = tmp_rgb[src_off + 2];

                    self.atlas_cpu.items[dst_off + 0] = r; // R
                    self.atlas_cpu.items[dst_off + 1] = g; // G
                    self.atlas_cpu.items[dst_off + 2] = b; // B
                    self.atlas_cpu.items[dst_off + 3] = @max(r, @max(g, b)); // A
                }
            }
        }

        // Mark dirty rect for GPU upload
        try self.pending_uploads.append(self.alloc, c.D2D1_RECT_U{
            .left = place_x,
            .top = place_y,
            .right = place_x + packed_w,
            .bottom = place_y + packed_h,
        });

        // Increment atlas version for multi-context sync (styled glyphs)
        self.atlas_version +%= 1;

        // UV for actual glyph area excluding padding
        const uv_u0 = @as(f32, @floatFromInt(place_x + pad)) / @as(f32, @floatFromInt(self.atlas_w));
        const uv_v0 = @as(f32, @floatFromInt(place_y + pad)) / @as(f32, @floatFromInt(self.atlas_h));
        const uv_u1 = @as(f32, @floatFromInt(place_x + pad + bw)) / @as(f32, @floatFromInt(self.atlas_w));
        const uv_v1 = @as(f32, @floatFromInt(place_y + pad + bh)) / @as(f32, @floatFromInt(self.atlas_h));

        return core.GlyphEntry{
            .uv_min = .{ uv_u0, uv_v0 },
            .uv_max = .{ uv_u1, uv_v1 },
            .bbox_origin_px = .{
                @as(f32, @floatFromInt(bounds.left)),
                @as(f32, @floatFromInt(-bounds.bottom)),
            },
            .bbox_size_px = .{
                @as(f32, @floatFromInt(bw)),
                @as(f32, @floatFromInt(bh)),
            },
            .advance_px = @as(f32, @floatFromInt(self.cell_w_px)),
            .ascent_px = self.ascent_px,
            .descent_px = self.descent_px,
        };
    }

    // --- Phase 2: Core-managed atlas ---

    /// Phase 2: Rasterize glyph via DWrite without atlas packing.
    /// Returns ClearType 3bpp bitmap data in self.glyph_tmp.
    pub fn rasterizeGlyphOnly(self: *Renderer, scalar: u32, style_flags: u32, out_bitmap: *core.GlyphBitmap) !void {
        self.mu.lock();
        defer self.mu.unlock();

        // Select font face based on style_flags
        const face: *c.IDWriteFontFace = blk: {
            if (style_flags != 0) {
                self.ensureStyledFontFaces();
                const is_bold = (style_flags & STYLE_BOLD) != 0;
                const is_italic = (style_flags & STYLE_ITALIC) != 0;
                if (is_bold and is_italic) {
                    break :blk self.bold_italic_font_face orelse self.bold_font_face orelse self.italic_font_face orelse self.font_face orelse return error.NoFont;
                } else if (is_bold) {
                    break :blk self.bold_font_face orelse self.font_face orelse return error.NoFont;
                } else if (is_italic) {
                    break :blk self.italic_font_face orelse self.font_face orelse return error.NoFont;
                } else {
                    break :blk self.font_face orelse return error.NoFont;
                }
            } else {
                break :blk self.font_face orelse return error.NoFont;
            }
        };

        // scalar -> glyph_index (feature-aware via IDWriteTextAnalyzer when features set)
        const glyph_index = self.getGlyphIndexForScalar(face, scalar) catch |err| {
            if (applog.isEnabled()) applog.appLog("[dwrite] getGlyphIndexForScalar failed in rasterizeGlyphOnly: {any}\n", .{err});
            return err;
        };

        // glyph run analysis
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

        // Get alpha texture bounds
        var bounds: c.RECT = std.mem.zeroes(c.RECT);
        const atbl = analysis.?.lpVtbl.*;
        const get_bounds_fn = atbl.GetAlphaTextureBounds orelse return error.DWriteGlyphRunAnalysisMissingGetAlphaTextureBounds;
        const hr_bounds = get_bounds_fn(analysis.?, c.DWRITE_TEXTURE_CLEARTYPE_3x1, &bounds);
        if (c.FAILED(hr_bounds)) return error.DWriteGetAlphaTextureBoundsFailed;

        const bw_i32: i32 = bounds.right - bounds.left;
        const bh_i32: i32 = bounds.bottom - bounds.top;
        const bw: u32 = if (bw_i32 > 0) @as(u32, @intCast(bw_i32)) else 0;
        const bh: u32 = if (bh_i32 > 0) @as(u32, @intCast(bh_i32)) else 0;

        // Fill common metrics
        out_bitmap.bearing_x = bounds.left;
        out_bitmap.bearing_y = @as(i32, -bounds.top); // DWrite top -> FreeType bearing_y
        out_bitmap.advance_26_6 = @as(i32, @intCast(self.cell_w_px)) * 64;
        out_bitmap.ascent_px = self.ascent_px;
        out_bitmap.descent_px = self.descent_px;
        out_bitmap.bytes_per_pixel = 3; // ClearType RGB

        if (bw == 0 or bh == 0) {
            // Empty glyph (space etc.)
            out_bitmap.pixels = null;
            out_bitmap.width = 0;
            out_bitmap.height = 0;
            out_bitmap.pitch = 0;
            return;
        }

        // Fetch ClearType 3x1 texture (RGB, 3 bytes per pixel)
        const buf_size: usize = @as(usize, bw) * @as(usize, bh) * 3;
        try self.glyph_tmp.resize(self.alloc, buf_size);

        const create_alpha_fn = atbl.CreateAlphaTexture orelse return error.DWriteGlyphRunAnalysisMissingCreateAlphaTexture;
        const hr_tex = create_alpha_fn(analysis.?, c.DWRITE_TEXTURE_CLEARTYPE_3x1, &bounds, self.glyph_tmp.items.ptr, @as(c.UINT32, @intCast(buf_size)));
        if (c.FAILED(hr_tex)) return error.DWriteCreateAlphaTextureFailed;

        out_bitmap.pixels = self.glyph_tmp.items.ptr;
        out_bitmap.width = bw;
        out_bitmap.height = bh;
        out_bitmap.pitch = @as(i32, @intCast(bw * 3));
    }

    /// Phase 2: Upload glyph bitmap to atlas_cpu at (dest_x, dest_y).
    /// Handles ClearType RGB 3bpp -> RGBA 4bpp conversion.
    pub fn uploadAtlasRegion(self: *Renderer, dest_x: u32, dest_y: u32, width: u32, height: u32, bitmap: *const core.GlyphBitmap) !void {
        self.mu.lock();
        defer self.mu.unlock();

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
    pub fn recreateAtlasTexture(self: *Renderer, atlas_w: u32, atlas_h: u32) void {
        self.mu.lock();
        defer self.mu.unlock();

        // Resize CPU atlas buffer before updating dimensions to avoid inconsistency
        const total = @as(usize, atlas_w) * @as(usize, atlas_h) * 4;
        if (self.atlas_cpu.items.len != total) {
            self.atlas_cpu.resize(self.alloc, total) catch {
                // Resize failed: keep old dimensions, just clear and reset
                if (applog.isEnabled()) applog.appLog("[atlas] recreateAtlasTexture: resize to {d}x{d} failed, keeping {d}x{d}\n", .{ atlas_w, atlas_h, self.atlas_w, self.atlas_h });
                self.glyph_map.clearRetainingCapacity();
                self.styled_glyph_map.clearRetainingCapacity();
                self.atlas_next_x = 1;
                self.atlas_next_y = 1;
                self.atlas_row_h = 0;
                self.pending_upload_base_seq += self.pending_uploads.items.len;
                self.pending_uploads.clearRetainingCapacity();
                if (self.atlas_cpu.items.len > 0) @memset(self.atlas_cpu.items, 0);
                self.atlas_reset_pending = true;
                return;
            };
        }

        // Resize succeeded (or same size): commit new dimensions
        self.atlas_w = atlas_w;
        self.atlas_h = atlas_h;

        // Clear caches
        self.glyph_map.clearRetainingCapacity();
        self.styled_glyph_map.clearRetainingCapacity();

        // Reset packer
        self.atlas_next_x = 1;
        self.atlas_next_y = 1;
        self.atlas_row_h = 0;

        // Clear pending uploads
        self.pending_upload_base_seq += self.pending_uploads.items.len;
        self.pending_uploads.clearRetainingCapacity();

        if (self.atlas_cpu.items.len > 0) {
            @memset(self.atlas_cpu.items, 0);
        }

        self.atlas_reset_pending = true;
    }

    pub fn renderVertices(self: *Renderer, main: []const core.Vertex, cursor: []const core.Vertex) !void {
        self.mu.lock();
        defer self.mu.unlock();
    
        // Ensure RT exists (already holding self.mu)
        if (self.rt == null) {
            try self.recreateRenderTargetLocked();
        }
    
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
                _ = self.recreateRenderTargetLocked() catch {};
                return;
            }
            return error.D2DEndDrawFailed;
        }



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
    
            // Glyph quad: FillOpacityMask
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
    
            if (rtv.FillOpacityMask) |fill_mask_fn| {
                if (i < 24 and log_active) {
                    applog.appLog(
                        "[d2d] quad{d} GLYPH FillOpacityMask dst=({d},{d},{d},{d}) src=({d},{d},{d},{d})\n",
                        .{
                            i / 6,
                            dst.left, dst.top, dst.right, dst.bottom,
                            src.left, src.top, src.right, src.bottom,
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
                    applog.appLog("[d2d] quad{d} FillOpacityMask returned\n", .{ i / 6 });
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
                _ = copy_fn(
                    bmp,
                    &full_rect,
                    self.atlas_cpu.items.ptr,
                    self.atlas_w * 4,
                );
            }
            self.d2d_upload_cursor = head_seq;
            return;
        }

        const start_idx = self.d2d_upload_cursor - self.pending_upload_base_seq;
        for (self.pending_uploads.items[start_idx..]) |r| {
            const src_off = (@as(usize, r.top) * @as(usize, self.atlas_w) + @as(usize, r.left)) * 4;
            _ = copy_fn(
                bmp,
                &r,
                self.atlas_cpu.items.ptr + src_off,
                self.atlas_w * 4,
            );
        }
        self.d2d_upload_cursor = head_seq;
    }
    
    fn flushPendingAtlasUploads(self: *Renderer) void {
        self.mu.lock();
        defer self.mu.unlock();
        self.flushPendingAtlasUploadsLocked();
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
    ) u64 {
        const head_seq = self.pending_upload_base_seq + self.pending_uploads.items.len;
        if (since_seq >= head_seq) return head_seq;

        // Cursor is behind base: entries were discarded (atlas reset).
        // Caller must use uploadFullAtlasToD3D to recover.
        if (since_seq < self.pending_upload_base_seq) return head_seq;

        const start_idx = since_seq - self.pending_upload_base_seq;

        if (applog.isEnabled()) applog.appLog(
            "[atlas] flushSince: since={d} base={d} head={d} uploading={d}\n",
            .{ since_seq, self.pending_upload_base_seq, head_seq, self.pending_uploads.items.len - start_idx },
        );

        var log_idx: usize = 0;
        for (self.pending_uploads.items[start_idx..]) |r| {
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
            d3d.atlasUploadRect(r.left, r.top, w, h, src_ptr, self.atlas_w * 4);
        }

        return head_seq;
    }










/// Public wrapper: upload atlas dirty rects added since `since_seq`.
/// Returns the new head sequence for the caller to store as its cursor.
pub fn flushPendingAtlasUploadsSinceToD3D(self: *Renderer, d3d: anytype, since_seq: u64) u64 {
    self.mu.lock();
    defer self.mu.unlock();
    return self.flushPendingAtlasUploadsSinceToD3DLocked(d3d, since_seq);
}

/// Upload the entire atlas to a D3D11 renderer.
/// Use this for external windows that need the full atlas texture.
pub fn uploadFullAtlasToD3D(self: *Renderer, d3d: anytype) void {
    self.mu.lock();
    defer self.mu.unlock();

    if (self.atlas_cpu.items.len == 0) return;

    if (applog.isEnabled()) applog.appLog(
        "[atlas] uploadFullAtlasToD3D: uploading full atlas {d}x{d}\n",
        .{ self.atlas_w, self.atlas_h },
    );

    // Upload the entire atlas as a single rect
    d3d.atlasUploadRect(0, 0, self.atlas_w, self.atlas_h, self.atlas_cpu.items.ptr, self.atlas_w * 4);
}

    pub fn ascentPx(self: *Renderer) f32 { return self.ascent_px; }
    pub fn descentPx(self: *Renderer) f32 { return self.descent_px; }

    pub fn onResize(self: *Renderer) void {
        self.mu.lock();
        defer self.mu.unlock();

        if (self.rt == null) return;

        const hwnd: c.HWND = self.hwnd;
        var rc: c.RECT = undefined;
        _ = c.GetClientRect(hwnd, &rc);

        const size = c.D2D1_SIZE_U{
            .width = @intCast(@max(1, rc.right - rc.left)),
            .height = @intCast(@max(1, rc.bottom - rc.top)),
        };
        const rt = self.rt.?; // already checked non-null above
        const vtbl = rt.lpVtbl.*;
        if (vtbl.Resize) |resize_fn| {
            const hr = resize_fn(rt, &size);

            // D2DERR_RECREATE_TARGET (0x8899000C)
            const hr_u: u32 = @bitCast(hr);
            if (hr_u == 0x8899000C) {
                // Recreate RT using the new client rect size (already holding self.mu).
                _ = self.recreateRenderTargetLocked() catch {};
            }
        }
    }

    pub fn setFontUtf8(self: *Renderer, name_utf8: []const u8, point_size: f32) !void {
        return self.setFontUtf8WithFeatures(name_utf8, point_size, "");
    }

    pub fn setFontUtf8WithFeatures(self: *Renderer, name_utf8: []const u8, point_size: f32, features_str: []const u8) !void {
        self.mu.lock();
        defer self.mu.unlock();

        if (self.dwrite_factory == null) return error.NotInitialized;

        // DPI scaling: scale point size to physical pixels
        const dpi_scale: f32 = @as(f32, @floatFromInt(self.dpi)) / 96.0;
        const scaled_size: f32 = point_size * dpi_scale;

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
            c.DWRITE_FONT_WEIGHT_NORMAL,
            c.DWRITE_FONT_STYLE_NORMAL,
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
            c.DWRITE_FONT_WEIGHT_NORMAL,
            c.DWRITE_FONT_STRETCH_NORMAL,
            c.DWRITE_FONT_STYLE_NORMAL,
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
        new_fmt = null;
        new_face = null;

        self.font_em_size = scaled_size;
        self.base_point_size = point_size;
        self.ascent_px = new_ascent_px;
        self.descent_px = new_descent_px;

        // Store font name for IME overlay (copy up to 63 chars + null)
        @memset(&self.font_name, 0);
        const copy_len = @min(name_w.len, self.font_name.len - 1);
        @memcpy(self.font_name[0..copy_len], name_w[0..copy_len]);

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

        // Clear glyph cache - old glyphs have wrong metrics/UVs for new font.
        self.glyph_map.clearRetainingCapacity();
        self.styled_glyph_map.clearRetainingCapacity();
        self.atlas_next_x = 1;
        self.atlas_next_y = 1;
        self.atlas_row_h = 0;

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
        if (new_dpi == self.dpi) return;

        const old_dpi = self.dpi;
        self.dpi = new_dpi;
        if (applog.isEnabled()) applog.appLog("[d2d] DPI changed: {d} -> {d}\n", .{ old_dpi, new_dpi });

        // Re-scale font_em_size and metrics proportionally
        const scale: f32 = @as(f32, @floatFromInt(new_dpi)) / @as(f32, @floatFromInt(old_dpi));
        self.mu.lock();
        defer self.mu.unlock();

        self.font_em_size *= scale;
        self.ascent_px *= scale;
        self.descent_px *= scale;

        // Re-create TextFormat with new scaled size (needed for cell metrics)
        if (self.dwrite_factory != null and self.font_name[0] != 0) {
            safeRelease(self.text_format);
            self.text_format = null;

            const factory = self.dwrite_factory.?;
            const vtbl = factory.lpVtbl.*;
            if (vtbl.CreateTextFormat) |create_fn| {
                const dpi_scale: f32 = @as(f32, @floatFromInt(new_dpi)) / 96.0;
                const new_font_size: f32 = self.base_point_size * dpi_scale;
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

        // Clear glyph cache (old glyphs rasterized at wrong DPI)
        self.glyph_map.clearRetainingCapacity();
        self.styled_glyph_map.clearRetainingCapacity();
        self.atlas_next_x = 1;
        self.atlas_next_y = 1;
        self.atlas_row_h = 0;

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

        self.mu.lock();
        defer self.mu.unlock();

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
            // Cluster map inversion
            var char_ptr: usize = 0;
            for (0..gcount) |gi| {
                while (char_ptr + 1 < utf16_len and cluster_map[char_ptr + 1] <= @as(c.UINT16, @intCast(gi))) {
                    char_ptr += 1;
                }
                out_clusters[gi] = utf16_to_scalar_idx[char_ptr];
            }
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
        }

        // Cluster map inversion: DWrite cluster_map[char_j] → first glyph for char j
        // Core needs out_clusters[glyph_i] → source scalar index
        {
            var char_ptr: usize = 0;
            for (0..gcount) |gi| {
                while (char_ptr + 1 < utf16_len and cluster_map[char_ptr + 1] <= @as(c.UINT16, @intCast(gi))) {
                    char_ptr += 1;
                }
                out_clusters[gi] = utf16_to_scalar_idx[char_ptr];
            }
        }

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
        self.mu.lock();
        defer self.mu.unlock();

        const face = self.selectFontFace(style_flags) orelse return error.NoFont;

        // Use glyph_id directly (truncate u32 → u16 for DWrite)
        var gi_arr: [1]c.UINT16 = .{@intCast(glyph_id & 0xFFFF)};
        var adv_arr: [1]c.FLOAT = .{@as(c.FLOAT, @floatFromInt(self.cell_w_px))};
        var off_arr: [1]c.DWRITE_GLYPH_OFFSET = .{.{ .advanceOffset = 0, .ascenderOffset = 0 }};

        var glyph_run: c.DWRITE_GLYPH_RUN = std.mem.zeroes(c.DWRITE_GLYPH_RUN);
        glyph_run.fontFace = face;
        glyph_run.fontEmSize = self.font_em_size;
        glyph_run.glyphCount = 1;
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
        const atbl_a = analysis.?.lpVtbl.*;
        const get_bounds_fn = atbl_a.GetAlphaTextureBounds orelse return error.DWriteGlyphRunAnalysisMissingGetAlphaTextureBounds;
        const hr_bounds = get_bounds_fn(analysis.?, c.DWRITE_TEXTURE_CLEARTYPE_3x1, &bounds);
        if (c.FAILED(hr_bounds)) return error.DWriteGetAlphaTextureBoundsFailed;

        const bw_i32: i32 = bounds.right - bounds.left;
        const bh_i32: i32 = bounds.bottom - bounds.top;
        const bw: u32 = if (bw_i32 > 0) @as(u32, @intCast(bw_i32)) else 0;
        const bh: u32 = if (bh_i32 > 0) @as(u32, @intCast(bh_i32)) else 0;

        out_bitmap.bearing_x = bounds.left;
        out_bitmap.bearing_y = @as(i32, -bounds.top);
        out_bitmap.advance_26_6 = @as(i32, @intCast(self.cell_w_px)) * 64;
        out_bitmap.ascent_px = self.ascent_px;
        out_bitmap.descent_px = self.descent_px;
        out_bitmap.bytes_per_pixel = 3;

        if (bw == 0 or bh == 0) {
            out_bitmap.pixels = null;
            out_bitmap.width = 0;
            out_bitmap.height = 0;
            out_bitmap.pitch = 0;
            return;
        }

        const buf_size: usize = @as(usize, bw) * @as(usize, bh) * 3;
        try self.glyph_tmp.resize(self.alloc, buf_size);

        const create_alpha_fn = atbl_a.CreateAlphaTexture orelse return error.DWriteGlyphRunAnalysisMissingCreateAlphaTexture;
        const hr_tex = create_alpha_fn(analysis.?, c.DWRITE_TEXTURE_CLEARTYPE_3x1, &bounds, self.glyph_tmp.items.ptr, @as(c.UINT32, @intCast(buf_size)));
        if (c.FAILED(hr_tex)) return error.DWriteCreateAlphaTextureFailed;

        out_bitmap.pixels = self.glyph_tmp.items.ptr;
        out_bitmap.width = bw;
        out_bitmap.height = bh;
        out_bitmap.pitch = @as(i32, @intCast(bw * 3));
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
        self.mu.lock();
        defer self.mu.unlock();

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
    // Default-on features: liga, calt, rlig (matching macOS HBFTBridge.c behavior)
    // Default-off features: clig, dlig, ss01-ss20, cv01-cv99, etc.
    // User features can override defaults (enable or disable).
    const ot_liga: u32 = 0x6C696761; // 'liga' big-endian
    const ot_calt: u32 = 0x63616C74; // 'calt' big-endian
    const ot_rlig: u32 = 0x726C6967; // 'rlig' big-endian
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
        if (tag_be == ot_liga or tag_be == ot_calt or tag_be == ot_rlig) {
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
    var list = std.ArrayListUnmanaged(u16){};
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

fn rgbToD2DColor(rgb: u32) c.D2D1_COLOR_F {
    // Assumes 0xRRGGBB (alpha is implicit 1.0)
    const r8: u32 = (rgb >> 16) & 0xFF;
    const g8: u32 = (rgb >> 8) & 0xFF;
    const b8: u32 = rgb & 0xFF;

    return c.D2D1_COLOR_F{
        .r = @as(f32, @floatFromInt(r8)) / 255.0,
        .g = @as(f32, @floatFromInt(g8)) / 255.0,
        .b = @as(f32, @floatFromInt(b8)) / 255.0,
        .a = 1.0,
    };
}

fn L(comptime s: []const u8) [*:0]const u16 {
    return std.unicode.utf8ToUtf16LeStringLiteral(s);
}
