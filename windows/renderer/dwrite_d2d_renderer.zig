const std = @import("std");
const core = @import("zonvie_core");
const c = @import("../win32.zig").c;
const applog = @import("../app_log.zig");

// Move outside Renderer (Zig cannot have const declarations between container fields)
// Must match core's atlas_w/atlas_h (nvim_core.zig) for Phase 2 UV consistency.
const AtlasW: u32 = 2048;
const AtlasH: u32 = 2048;

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

// Styled glyph logging stats (global)
var g_log_styled_hits: u64 = 0;
var g_log_styled_misses: u64 = 0;
var g_log_styled_fallbacks: u64 = 0;
var g_log_styled_last_report_ns: i128 = 0;

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

    // CPU-side atlas (full size: AtlasW * AtlasH). Always keeps the whole atlas.
    atlas_cpu: std.ArrayListUnmanaged(u8) = .{},
    
    // temporary buffer for a single glyph (padded) generation
    glyph_tmp: std.ArrayListUnmanaged(u8) = .{},
    
    // pending dirty rects to upload into atlas_bitmap (flushed before BeginDraw)
    pending_uploads: std.ArrayListUnmanaged(c.D2D1_RECT_U) = .{},

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

    pub fn init(alloc: std.mem.Allocator, hwnd: c.HWND, initial_font: []const u8, initial_pt: f32) !Renderer {
        // Timing for init steps
        var freq: c.LARGE_INTEGER = undefined;
        var t0: c.LARGE_INTEGER = undefined;
        var t1: c.LARGE_INTEGER = undefined;
        _ = c.QueryPerformanceFrequency(&freq);

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
        _ = c.QueryPerformanceCounter(&t0);
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
        _ = c.QueryPerformanceCounter(&t1);
        applog.appLog("[d2d] [TIMING] D2D1CreateFactory: {d}ms\n", .{@divTrunc((t1.QuadPart - t0.QuadPart) * 1000, freq.QuadPart)});

        // DWrite factory
        _ = c.QueryPerformanceCounter(&t0);
        var dw_factory: ?*c.IDWriteFactory = null;
        const hr_dw = c.DWriteCreateFactory(
            c.DWRITE_FACTORY_TYPE_SHARED,
            @as(*const c.GUID, @ptrCast(&IID_IDWriteFactory_ZONVIE)),
            @ptrCast(&dw_factory),
        );
        if (hr_dw != 0 or dw_factory == null) return error.DWriteFactoryCreateFailed;
        self.dwrite_factory = dw_factory;
        errdefer safeRelease(self.dwrite_factory);
        _ = c.QueryPerformanceCounter(&t1);
        applog.appLog("[d2d] [TIMING] DWriteCreateFactory: {d}ms\n", .{@divTrunc((t1.QuadPart - t0.QuadPart) * 1000, freq.QuadPart)});

        // Create render target for hwnd
        _ = c.QueryPerformanceCounter(&t0);
        try self.recreateRenderTarget();
        errdefer safeRelease(self.rt);
        _ = c.QueryPerformanceCounter(&t1);
        applog.appLog("[d2d] [TIMING] recreateRenderTarget: {d}ms\n", .{@divTrunc((t1.QuadPart - t0.QuadPart) * 1000, freq.QuadPart)});

        // Initial font (from config or OS default)
        _ = c.QueryPerformanceCounter(&t0);
        self.setFontUtf8(initial_font, initial_pt) catch |e| {
            // Fallback to OS default if initial font fails
            applog.appLog("[d2d] initial font '{s}' failed: {any}, trying Consolas\n", .{ initial_font, e });
            try self.setFontUtf8("Consolas", 14.0);
        };
        _ = c.QueryPerformanceCounter(&t1);
        applog.appLog("[d2d] [TIMING] setFontUtf8: {d}ms\n", .{@divTrunc((t1.QuadPart - t0.QuadPart) * 1000, freq.QuadPart)});

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
        applog.appLog("[atlas] resetAtlas: clearing {d} glyphs + {d} styled glyphs\n", .{
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

        // Clear pending uploads (they're now invalid)
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
        _ = c.QueryPerformanceFrequency(&freq);

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

        _ = c.QueryPerformanceCounter(&t0);
        const hr = create_fn(
            factory,
            &rt_props,
            &hwnd_props,
            &rt,
        );
        _ = c.QueryPerformanceCounter(&t1);
        applog.appLog("[d2d] [TIMING]   CreateHwndRenderTarget: {d}ms\n", .{@divTrunc((t1.QuadPart - t0.QuadPart) * 1000, freq.QuadPart)});

        if (hr != 0 or rt == null) return error.D2DCreateHwndRenderTargetFailed;

        self.rt = rt;
        errdefer {
            safeRelease(self.rt);
            self.rt = null;
        }

        _ = c.QueryPerformanceCounter(&t0);
        try self.createAtlasResources();
        _ = c.QueryPerformanceCounter(&t1);
        applog.appLog("[d2d] [TIMING]   createAtlasResources: {d}ms\n", .{@divTrunc((t1.QuadPart - t0.QuadPart) * 1000, freq.QuadPart)});
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
        const sz = c.D2D1_SIZE_U{ .width = AtlasW, .height = AtlasH };

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
            applog.appLog("[d2d] CreateBitmap missing on vtbl\n", .{});
            return error.CreateAtlasFailed;
        };
        
        if (c.FAILED(hr) or bmp == null) {
            const hr_u: u32 = @bitCast(hr);
            applog.appLog("[d2d] CreateBitmap(A8) FAILED hr=0x{x} bmp={*}\n", .{ hr_u, bmp });
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
        const total = @as(usize, AtlasW) * @as(usize, AtlasH) * 4;
        try self.atlas_cpu.resize(self.alloc, total);
        @memset(self.atlas_cpu.items, 0);

        self.pending_uploads.clearRetainingCapacity();

        const bmp_ptr = self.atlas_bitmap orelse return error.CreateAtlasFailed;
        const bvtbl = bmp_ptr.lpVtbl.*;
        const copy_fn = bvtbl.CopyFromMemory orelse return error.BitmapMissingCopyFromMemory;

        const rect = c.D2D1_RECT_U{ .left = 0, .top = 0, .right = AtlasW, .bottom = AtlasH };

        const hr3 = copy_fn(
            bmp_ptr,
            &rect,
            self.atlas_cpu.items.ptr,
            AtlasW * 4, // bytes per row (RGBA)
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
    const fvtbl = face.lpVtbl.*; // IMPORTANT: dereference vtbl

    // --- 1) scalar -> glyph_index ---
    var codepoints: [1]c.UINT32 = .{ @as(c.UINT32, @intCast(scalar)) };
    var glyph_index: c.UINT16 = 0;

    const get_glyph_indices_fn = fvtbl.GetGlyphIndicesW orelse
        return error.DWriteFontFaceMissingGetGlyphIndicesW;

    const hr_gi = get_glyph_indices_fn(
        face,
        codepoints[0..].ptr,
        1,
        &glyph_index,
    );

    if (c.FAILED(hr_gi)) {
        if (applog.isEnabled()) applog.appLog("[dwrite] GetGlyphIndicesW FAILED hr=0x{x} scalar=0x{x}\n", .{
            @as(u32, @bitCast(hr_gi)),
            scalar,
        });

        if (log_enabled) {
            const log_end_ns: i128 = std.time.nanoTimestamp();
            const log_dur_ns_u64: u64 = @intCast(@max(@as(i128, 0), log_end_ns - log_start_ns));
            if (log_dur_ns_u64 > self.log_atlas_ensure_slowest_ns) self.log_atlas_ensure_slowest_ns = log_dur_ns_u64;
            applog.appLog("[atlas] ensureGlyph MISS scalar=0x{x} dur_ms={d}\n", .{ scalar, log_dur_ns_u64 / 1_000_000 });
        }

        return error.DWriteGetGlyphIndicesFailed;
    }

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
    if (self.atlas_next_x + packed_w + 1 >= AtlasW) {
        self.atlas_next_x = 1;
        self.atlas_next_y += self.atlas_row_h + 1;
        self.atlas_row_h = 0;
    }
    // If atlas is full, reset and retry (simple eviction strategy)
    if (self.atlas_next_y + packed_h + 1 >= AtlasH) {
        if (applog.isEnabled()) applog.appLog("[atlas] ensureGlyph scalar=0x{x}: atlas full, resetting\n", .{scalar});
        self.resetAtlas();

        // After reset, re-check row wrap (should start at x=1, y=1)
        if (self.atlas_next_x + packed_w + 1 >= AtlasW) {
            self.atlas_next_x = 1;
            self.atlas_next_y += self.atlas_row_h + 1;
            self.atlas_row_h = 0;
        }
        // If still doesn't fit after reset, glyph is too large for atlas
        if (self.atlas_next_y + packed_h + 1 >= AtlasH) {
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
            const row_off = ((@as(usize, place_y + y) * @as(usize, AtlasW)) + @as(usize, place_x)) * 4;
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
                const dst_off = ((@as(usize, place_y + pad + y) * @as(usize, AtlasW)) + @as(usize, place_x + pad + x)) * 4;

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
    const uv_u0 = @as(f32, @floatFromInt(place_x + pad)) / @as(f32, @floatFromInt(AtlasW));
    const uv_v0 = @as(f32, @floatFromInt(place_y + pad)) / @as(f32, @floatFromInt(AtlasH));
    const uv_u1 = @as(f32, @floatFromInt(place_x + pad + bw)) / @as(f32, @floatFromInt(AtlasW));
    const uv_v1 = @as(f32, @floatFromInt(place_y + pad + bh)) / @as(f32, @floatFromInt(AtlasH));

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
        const now_ns: i128 = std.time.nanoTimestamp();
        if (g_log_styled_last_report_ns == 0) g_log_styled_last_report_ns = now_ns;
        if (now_ns - g_log_styled_last_report_ns >= @as(i128, 1_000_000_000)) {
            if (applog.isEnabled()) applog.appLog("[styled] stats: hits={d} misses={d} fallbacks={d}\n", .{ g_log_styled_hits, g_log_styled_misses, g_log_styled_fallbacks });
            g_log_styled_hits = 0;
            g_log_styled_misses = 0;
            g_log_styled_fallbacks = 0;
            g_log_styled_last_report_ns = now_ns;
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
        const fvtbl = face.lpVtbl.*;

        // --- 1) scalar -> glyph_index ---
        var codepoints: [1]c.UINT32 = .{@as(c.UINT32, @intCast(scalar))};
        var glyph_index: c.UINT16 = 0;

        const get_glyph_indices_fn = fvtbl.GetGlyphIndicesW orelse
            return error.DWriteFontFaceMissingGetGlyphIndicesW;

        const hr_gi = get_glyph_indices_fn(
            face,
            codepoints[0..].ptr,
            1,
            &glyph_index,
        );

        if (c.FAILED(hr_gi)) {
            return error.DWriteGetGlyphIndicesFailed;
        }

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
        if (self.atlas_next_x + packed_w + 1 >= AtlasW) {
            self.atlas_next_x = 1;
            self.atlas_next_y += self.atlas_row_h + 1;
            self.atlas_row_h = 0;
        }
        // If atlas is full, reset and retry (simple eviction strategy)
        if (self.atlas_next_y + packed_h + 1 >= AtlasH) {
            if (applog.isEnabled()) applog.appLog("[atlas] renderGlyphWithFace scalar=0x{x}: atlas full, resetting\n", .{scalar});
            self.resetAtlas();

            // After reset, re-check row wrap
            if (self.atlas_next_x + packed_w + 1 >= AtlasW) {
                self.atlas_next_x = 1;
                self.atlas_next_y += self.atlas_row_h + 1;
                self.atlas_row_h = 0;
            }
            // If still doesn't fit after reset, glyph is too large
            if (self.atlas_next_y + packed_h + 1 >= AtlasH) {
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
                const row_off = ((@as(usize, place_y + y) * @as(usize, AtlasW)) + @as(usize, place_x)) * 4;
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
                    const dst_off = ((@as(usize, place_y + pad + y) * @as(usize, AtlasW)) + @as(usize, place_x + pad + x)) * 4;

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
        const uv_u0 = @as(f32, @floatFromInt(place_x + pad)) / @as(f32, @floatFromInt(AtlasW));
        const uv_v0 = @as(f32, @floatFromInt(place_y + pad)) / @as(f32, @floatFromInt(AtlasH));
        const uv_u1 = @as(f32, @floatFromInt(place_x + pad + bw)) / @as(f32, @floatFromInt(AtlasW));
        const uv_v1 = @as(f32, @floatFromInt(place_y + pad + bh)) / @as(f32, @floatFromInt(AtlasH));

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

        const fvtbl = face.lpVtbl.*;

        // scalar -> glyph_index
        var codepoints: [1]c.UINT32 = .{@as(c.UINT32, @intCast(scalar))};
        var glyph_index: c.UINT16 = 0;
        const get_glyph_indices_fn = fvtbl.GetGlyphIndicesW orelse return error.DWriteFontFaceMissingGetGlyphIndicesW;
        const hr_gi = get_glyph_indices_fn(face, codepoints[0..].ptr, 1, &glyph_index);
        if (c.FAILED(hr_gi)) return error.DWriteGetGlyphIndicesFailed;

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
            var x: u32 = 0;
            while (x < width) : (x += 1) {
                const dst_off = ((@as(usize, dest_y + y) * @as(usize, AtlasW)) + @as(usize, dest_x + x)) * 4;

                if (bpp == 3) {
                    // ClearType RGB -> RGBA
                    const src_off = src_row * pitch + @as(usize, x) * 3;
                    const r = pixels[src_off];
                    const g = pixels[src_off + 1];
                    const b = pixels[src_off + 2];
                    self.atlas_cpu.items[dst_off + 0] = r;
                    self.atlas_cpu.items[dst_off + 1] = g;
                    self.atlas_cpu.items[dst_off + 2] = b;
                    self.atlas_cpu.items[dst_off + 3] = @max(r, @max(g, b));
                } else {
                    // Grayscale or other: replicate to RGBA
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

        // Core's atlas dimensions must match our compile-time constants.
        // If this fires, update AtlasW/AtlasH to match core's atlas_w/atlas_h.
        std.debug.assert(atlas_w == AtlasW);
        std.debug.assert(atlas_h == AtlasH);

        // Clear caches
        self.glyph_map.clearRetainingCapacity();
        self.styled_glyph_map.clearRetainingCapacity();

        // Reset packer
        self.atlas_next_x = 1;
        self.atlas_next_y = 1;
        self.atlas_row_h = 0;

        // Clear pending uploads
        self.pending_uploads.clearRetainingCapacity();

        // Clear CPU atlas
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
    
        _ = self;
    
        const rtv = rt.lpVtbl.*;
    
        // Avoid GetSize (it can crash in some states); use caller-provided client size.
        const w: f32 = client_w;
        const h: f32 = client_h;
    
        // IMPORTANT: Do NOT call atlas->GetPixelSize().
        // Use compile-time atlas size constants to avoid COM/VTBL mismatch crashes.
        const atlas_w: f32 = @floatFromInt(AtlasW);
        const atlas_h: f32 = @floatFromInt(AtlasH);
    
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
            if (i < 24) {
                applog.appLog(
                    "[d2d] quad{d} any_bg={any} uv(min/max)=({d},{d})..({d},{d})\n",
                    .{ i / 6, any_bg_marker, min_u, min_v, max_u, max_v },
                );
            }
    
            // BG quad: FillRectangle
            if (any_bg_marker) {
                if (i == 0) {
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
                if (i < 24) {
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
                if (i < 24) {
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
    
                if (i < 24) {
                    applog.appLog("[d2d] quad{d} FillOpacityMask returned\n", .{ i / 6 });
                }
            }
        }

        // DEBUG: count glyph vertices inside THIS vertex list (texCoord >= 0)
        var glyph_vtx: usize = 0;
        for (verts) |v| {
            if (v.texCoord[0] >= 0.0 and v.texCoord[1] >= 0.0) {
                glyph_vtx += 1;
            }
        }
        applog.appLog("[d2d] drawVertexList: total_vtx={d} glyph_vtx={d}\n", .{ verts.len, glyph_vtx });
    }

    fn flushPendingAtlasUploadsLocked(self: *Renderer) void {
        const bmp = self.atlas_bitmap orelse return;
        if (self.pending_uploads.items.len == 0) return;
    
        const bvtbl = bmp.lpVtbl.*;
        const copy_fn = bvtbl.CopyFromMemory orelse return;
    
        for (self.pending_uploads.items) |r| {
            // RGBA format: 4 bytes per pixel
            const src_off = (@as(usize, r.top) * @as(usize, AtlasW) + @as(usize, r.left)) * 4;
            _ = copy_fn(
                bmp,
                &r,
                self.atlas_cpu.items.ptr + src_off,
                AtlasW * 4, // bytes per row (RGBA)
            );
        }
    
        self.pending_uploads.clearRetainingCapacity();
    }
    
    fn flushPendingAtlasUploads(self: *Renderer) void {
        self.mu.lock();
        defer self.mu.unlock();
        self.flushPendingAtlasUploadsLocked();
    }





    pub fn flushPendingAtlasUploadsToD3DLocked(
        self: *Renderer,
        d3d: anytype, // expects: d3d.atlasUploadRect(x,y,w,h,data,row_pitch)
    ) u32 {
        if (self.pending_uploads.items.len == 0) return 0;
    
        applog.appLog(
            "[atlas] cpu_atlas: len={d} cap={d} ptr=0x{x}\n",
            .{
                self.atlas_cpu.items.len,
                self.atlas_cpu.capacity,
                @intFromPtr(self.atlas_cpu.items.ptr),
            },
        );
    
        const total: u32 = @intCast(self.pending_uploads.items.len);
        var idx: usize = 0;
        for (self.pending_uploads.items) |r| {
            const w: u32 = r.right - r.left;
            const h: u32 = r.bottom - r.top;
            if (w == 0 or h == 0) continue;
    
            if (idx < 8) {
                applog.appLog(
                    "[atlas]   upload[{d}] (x={d},y={d},w={d},h={d})\n",
                    .{ idx, r.left, r.top, w, h },
                );
            }
            idx += 1;
    
            // RGBA format: 4 bytes per pixel
            const src_off = (@as(usize, r.top) * @as(usize, AtlasW) + @as(usize, r.left)) * 4;
            const src_ptr: [*]const u8 = self.atlas_cpu.items.ptr + src_off;

            // row_pitch is AtlasW * 4 bytes because atlas_cpu is RGBA
            d3d.atlasUploadRect(r.left, r.top, w, h, src_ptr, AtlasW * 4);
        }
    
        self.pending_uploads.clearRetainingCapacity();
        return total;
    }










pub fn flushPendingAtlasUploadsToD3D(self: *Renderer, d3d: anytype) u32 {
    self.mu.lock();
    defer self.mu.unlock();
    return self.flushPendingAtlasUploadsToD3DLocked(d3d);
}

/// Upload the entire atlas to a D3D11 renderer.
/// Use this for external windows that need the full atlas texture.
pub fn uploadFullAtlasToD3D(self: *Renderer, d3d: anytype) void {
    self.mu.lock();
    defer self.mu.unlock();

    if (self.atlas_cpu.items.len == 0) return;

    applog.appLog(
        "[atlas] uploadFullAtlasToD3D: uploading full atlas {d}x{d}\n",
        .{ AtlasW, AtlasH },
    );

    // Upload the entire atlas as a single rect
    d3d.atlasUploadRect(0, 0, AtlasW, AtlasH, self.atlas_cpu.items.ptr, AtlasW * 4);
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
        self.mu.lock();
        defer self.mu.unlock();

        if (self.dwrite_factory == null) return error.NotInitialized;
    
        const name_w = try utf8ToUtf16Alloc(self.alloc, name_utf8);
        defer self.alloc.free(name_w);
    
        const factory = self.dwrite_factory orelse return error.NotInitialized;
    
        // --- build new resources into locals first (transaction) ---
        var new_fmt: ?*c.IDWriteTextFormat = null;
        var new_face: ?*c.IDWriteFontFace = null;
    
        // If we fail after creating something, release locals.
        errdefer safeRelease(new_fmt);
        errdefer safeRelease(new_face);
    
        // CreateTextFormat
        const vtbl = factory.lpVtbl.*;
        const create_fn = vtbl.CreateTextFormat orelse return error.DWriteFactoryMissingCreateTextFormat;
    
        const hr = create_fn(
            factory,
            @ptrCast(name_w.ptr),
            null,
            c.DWRITE_FONT_WEIGHT_NORMAL,
            c.DWRITE_FONT_STYLE_NORMAL,
            c.DWRITE_FONT_STRETCH_NORMAL,
            point_size,
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

        // NOTE: Bold/Italic/Bold+Italic font variants are lazy-loaded on first use
        // in ensureStyledFontFaces() to improve startup time (~10ms savings)

        // Compute ascent/descent in pixels from design units.
        var fm: c.DWRITE_FONT_METRICS = undefined;
        const get_metrics_face_fn = new_face.?.lpVtbl.*.GetMetrics orelse return error.DWriteFontFaceMissingGetMetrics;
        get_metrics_face_fn(new_face.?, &fm);
    
        var new_ascent_px: f32 = 0.0;
        var new_descent_px: f32 = 0.0;
    
        const du_per_em: f32 = @floatFromInt(fm.designUnitsPerEm);
        if (du_per_em > 0.0) {
            new_ascent_px = point_size * (@as(f32, @floatFromInt(fm.ascent)) / du_per_em);
            new_descent_px = point_size * (@as(f32, @floatFromInt(fm.descent)) / du_per_em);
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
    
        self.font_em_size = point_size;
        self.ascent_px = new_ascent_px;
        self.descent_px = new_descent_px;

        // Store font name for IME overlay (copy up to 63 chars + null)
        @memset(&self.font_name, 0);
        const copy_len = @min(name_w.len, self.font_name.len - 1);
        @memcpy(self.font_name[0..copy_len], name_w[0..copy_len]);

        try self.recomputeCellMetrics();

        // Clear glyph cache - old glyphs have wrong metrics/UVs for new font.
        self.glyph_map.clearRetainingCapacity();
        self.styled_glyph_map.clearRetainingCapacity();
        self.atlas_next_x = 1;
        self.atlas_next_y = 1;
        self.atlas_row_h = 0;
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
                        applog.appLog("[dwrite] Bold font face created (lazy)\n", .{});
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
                        applog.appLog("[dwrite] Italic font face created (lazy)\n", .{});
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
                        applog.appLog("[dwrite] Bold+Italic font face created (lazy)\n", .{});
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
