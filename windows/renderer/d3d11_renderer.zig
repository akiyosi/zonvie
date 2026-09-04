const std = @import("std");
const builtin = @import("builtin");
const core = @import("zonvie_core");
const c = @import("../win32.zig").c;
const applog = @import("../app_log.zig");
const render_pipeline_helpers = @import("../render_pipeline_helpers.zig");
const compiled_shaders = @import("../shaders/compiled_shaders.zig");
const custom_shader_mod = @import("custom_shader_pipeline.zig");
const CustomShaderPipeline = custom_shader_mod.CustomShaderPipeline;

const MaxSwapchainBuffers: usize = 4;
const MaxPendingBackDamageRects: usize = 64;

const BackCopyDamage = struct {
    full: bool = false,
    rect_count: usize = 0,
};

// --- d3dcompiler_47: we do NOT include d3dcompiler.h in @cImport (it tends to explode on mingw),
// so we declare only what we need here.
const HRESULT = c_long;

// Minimal ID3DBlob declaration (COM)
const ID3DBlob = extern struct {
    lpVtbl: *const Vtbl,
    const Vtbl = extern struct {
        // IUnknown
        QueryInterface: ?*const fn (*ID3DBlob, *const c.GUID, *?*anyopaque) callconv(.c) HRESULT,
        AddRef: ?*const fn (*ID3DBlob) callconv(.c) c_ulong,
        Release: ?*const fn (*ID3DBlob) callconv(.c) c_ulong,
        // ID3D10Blob
        GetBufferPointer: ?*const fn (*ID3DBlob) callconv(.c) ?*anyopaque,
        GetBufferSize: ?*const fn (*ID3DBlob) callconv(.c) usize,
    };
};

extern "d3dcompiler_47" fn D3DCompile(
    pSrcData: ?*const anyopaque,
    SrcDataSize: usize,
    pSourceName: ?[*:0]const u8,
    pDefines: ?*anyopaque, // D3D_SHADER_MACRO*
    pInclude: ?*anyopaque, // ID3DInclude*
    pEntryPoint: [*:0]const u8,
    pTarget: [*:0]const u8,
    Flags1: c_uint,
    Flags2: c_uint,
    ppCode: *?*ID3DBlob,
    ppErrorMsgs: *?*ID3DBlob,
) callconv(.c) HRESULT;

// --- DirectComposition API declarations ---
// Use non-optional function pointers to avoid Zig's optional type checking issues with COM vtables

// IDCompositionVisual
const IDCompositionVisual = extern struct {
    lpVtbl: *const Vtbl,
    const Vtbl = extern struct {
        // IUnknown
        QueryInterface: *const fn (*IDCompositionVisual, *const c.GUID, *?*anyopaque) callconv(.c) HRESULT,
        AddRef: *const fn (*IDCompositionVisual) callconv(.c) c_ulong,
        Release: *const fn (*IDCompositionVisual) callconv(.c) c_ulong,
        // IDCompositionVisual methods (in vtable order)
        SetOffsetX_1: *const anyopaque,
        SetOffsetX_2: *const anyopaque,
        SetOffsetY_1: *const anyopaque,
        SetOffsetY_2: *const anyopaque,
        SetTransform_1: *const anyopaque,
        SetTransform_2: *const anyopaque,
        SetTransformParent: *const anyopaque,
        SetEffect: *const anyopaque,
        SetBitmapInterpolationMode: *const anyopaque,
        SetBorderMode: *const anyopaque,
        SetClip_1: *const anyopaque,
        SetClip_2: *const anyopaque,
        SetContent: *const fn (*IDCompositionVisual, ?*c.IUnknown) callconv(.c) HRESULT,
    };
};

// IDCompositionTarget
const IDCompositionTarget = extern struct {
    lpVtbl: *const Vtbl,
    const Vtbl = extern struct {
        // IUnknown
        QueryInterface: *const fn (*IDCompositionTarget, *const c.GUID, *?*anyopaque) callconv(.c) HRESULT,
        AddRef: *const fn (*IDCompositionTarget) callconv(.c) c_ulong,
        Release: *const fn (*IDCompositionTarget) callconv(.c) c_ulong,
        // IDCompositionTarget
        SetRoot: *const fn (*IDCompositionTarget, ?*IDCompositionVisual) callconv(.c) HRESULT,
    };
};

// IDCompositionDevice
const IDCompositionDevice = extern struct {
    lpVtbl: *const Vtbl,
    const Vtbl = extern struct {
        // IUnknown
        QueryInterface: *const fn (*IDCompositionDevice, *const c.GUID, *?*anyopaque) callconv(.c) HRESULT,
        AddRef: *const fn (*IDCompositionDevice) callconv(.c) c_ulong,
        Release: *const fn (*IDCompositionDevice) callconv(.c) c_ulong,
        // IDCompositionDevice methods (in vtable order from dcomp.h)
        Commit: *const fn (*IDCompositionDevice) callconv(.c) HRESULT,
        WaitForCommitCompletion: *const anyopaque,
        GetFrameStatistics: *const anyopaque,
        CreateTargetForHwnd: *const fn (*IDCompositionDevice, c.HWND, c.BOOL, *?*IDCompositionTarget) callconv(.c) HRESULT,
        CreateVisual: *const fn (*IDCompositionDevice, *?*IDCompositionVisual) callconv(.c) HRESULT,
    };
};

extern "dcomp" fn DCompositionCreateDevice(
    dxgiDevice: ?*c.IDXGIDevice,
    iid: *const c.GUID,
    dcompositionDevice: *?*IDCompositionDevice,
) callconv(.c) HRESULT;

const IID_IDCompositionDevice = c.GUID{
    .Data1 = 0xC37EA93A,
    .Data2 = 0xE7AA,
    .Data3 = 0x450D,
    .Data4 = .{ 0xB1, 0x6F, 0x97, 0x46, 0xCB, 0x04, 0x07, 0xF3 },
};

fn blobRelease(b: ?*ID3DBlob) void {
    const p = b orelse return;
    const rel = p.lpVtbl.Release orelse return;
    _ = rel(p);
}

/// Does not return address 0: returns null if unavailable
fn blobPtr(b: ?*ID3DBlob) ?*const anyopaque {
    const p = b orelse return null;
    const get_ptr = p.lpVtbl.GetBufferPointer orelse return null;
    return get_ptr(p);
}

/// Returns 0 if unavailable (caller should reject)
fn blobSize(b: ?*ID3DBlob) usize {
    const p = b orelse return 0;
    const get_sz = p.lpVtbl.GetBufferSize orelse return 0;
    return @intCast(get_sz(p));
}

fn dumpBlobAsText(prefix: []const u8, b: ?*ID3DBlob) void {
    const p = b orelse return;

    const get_ptr = p.lpVtbl.GetBufferPointer orelse return;
    const get_sz = p.lpVtbl.GetBufferSize orelse return;

    const ptr = get_ptr(p) orelse return;
    const sz: usize = @intCast(get_sz(p));

    const bytes = @as([*]const u8, @ptrCast(ptr))[0..sz];
    // Customize this to match your logging function
    if (applog.isEnabled()) applog.appLog("{s}{s}\n", .{ prefix, bytes });
}

pub const Renderer = struct {
    alloc: std.mem.Allocator,
    hwnd: c.HWND,

    // Mutex to protect D3D11 device context access (context is single-threaded)
    ctx_mu: std.Io.Mutex = .init,

    // D3D11 core
    device: ?*c.ID3D11Device = null,
    ctx: ?*c.ID3D11DeviceContext = null,
    swapchain: ?*c.IDXGISwapChain = null,
    swapchain1: ?*c.IDXGISwapChain1 = null,
    swapchain3: ?*c.IDXGISwapChain3 = null,
    swapchain_buf_count: u32 = 1,
    swapchain_buf_index: u32 = 0,

    // Swapchain backbuffer RTV
    bb_tex: ?*c.ID3D11Texture2D = null,
    bb_rtv: ?*c.ID3D11RenderTargetView = null,
    bb_texs: [MaxSwapchainBuffers]?*c.ID3D11Texture2D = .{ null, null, null, null },
    bb_rtvs: [MaxSwapchainBuffers]?*c.ID3D11RenderTargetView = .{ null, null, null, null },
    // Damage not yet copied from persistent back_tex into each rotating
    // swapchain buffer. Fixed storage avoids per-present allocation.
    bb_pending_full: [MaxSwapchainBuffers]bool = .{ true, true, true, true },
    bb_pending_rect_count: [MaxSwapchainBuffers]u8 = .{ 0, 0, 0, 0 },
    bb_pending_rects: [MaxSwapchainBuffers][MaxPendingBackDamageRects]c.RECT = undefined,

    // Persistent back buffer (like macOS backBuffer)
    back_tex: ?*c.ID3D11Texture2D = null,
    back_rtv: ?*c.ID3D11RenderTargetView = null,

    // Staging texture for back_tex scroll (same size/format, lazily created)
    scroll_staging_tex: ?*c.ID3D11Texture2D = null,

    // Clean pixels covered by the alpha-blended scrollbar in back_tex.
    // This is a narrow, persistent GPU texture (track width x track height),
    // created only when the scrollbar is first shown or its geometry changes.
    // Restoring it before the next overlay avoids alpha accumulation without
    // clearing and regenerating every terminal row on each fade tick.
    scrollbar_underlay_tex: ?*c.ID3D11Texture2D = null,
    scrollbar_underlay_rect: c.RECT = std.mem.zeroes(c.RECT),
    scrollbar_underlay_state: render_pipeline_helpers.ScrollbarUnderlayState = .{},

    // Cached VB for drawing bg-fill quads on empty rows (6 verts, lazily created).
    clear_row_vb: ?*c.ID3D11Buffer = null,
    clear_row_vb_bg: u32 = 0xFFFFFFFF,

    // Pipeline
    vs: ?*c.ID3D11VertexShader = null,
    ps: ?*c.ID3D11PixelShader = null,
    il: ?*c.ID3D11InputLayout = null,
    sampler: ?*c.ID3D11SamplerState = null,
    blend: ?*c.ID3D11BlendState = null,
    rs: ?*c.ID3D11RasterizerState = null,

    // VS constant buffer (inv viewport)
    vs_cb: ?*c.ID3D11Buffer = null,

    // Dynamic vertex buffer
    vb: ?*c.ID3D11Buffer = null,
    vb_bytes: usize = 0,

    // Atlas texture (R8G8B8A8_UNORM)
    atlas_tex: ?*c.ID3D11Texture2D = null,
    atlas_srv: ?*c.ID3D11ShaderResourceView = null,
    atlas_w: u32 = 2048,
    atlas_h: u32 = 2048,

    // D3D feature level (captured at device creation)
    feature_level: u32 = 0,

    // Tabline texture (B8G8R8A8_UNORM) - rendered from GDI bitmap
    tabline_tex: ?*c.ID3D11Texture2D = null,
    tabline_srv: ?*c.ID3D11ShaderResourceView = null,
    tabline_width: u32 = 0,
    tabline_height: u32 = 0,

    // Sidebar texture (GDI offscreen -> D3D11, for sidebar mode)
    sidebar_tex: ?*c.ID3D11Texture2D = null,
    sidebar_srv: ?*c.ID3D11ShaderResourceView = null,
    sidebar_width_tex: u32 = 0,
    sidebar_height_tex: u32 = 0,

    // Post-process bloom (neon glow, Dual Kawase)
    glow_extract_tex: ?*c.ID3D11Texture2D = null,
    glow_extract_rtv: ?*c.ID3D11RenderTargetView = null,
    glow_extract_srv: ?*c.ID3D11ShaderResourceView = null,
    glow_mip_tex: [3]?*c.ID3D11Texture2D = .{ null, null, null },
    glow_mip_rtv: [3]?*c.ID3D11RenderTargetView = .{ null, null, null },
    glow_mip_srv: [3]?*c.ID3D11ShaderResourceView = .{ null, null, null },
    glow_half_w: u32 = 0,
    glow_half_h: u32 = 0,
    vs_fullscreen: ?*c.ID3D11VertexShader = null,
    /// Vertex shader paired with the user's custom post-process PS. The
    /// output struct field name is `vUV` so it matches the PS input name
    /// that SPIRV-Cross generates for `layout(location=0) in vec2 vUV`.
    vs_custom_post: ?*c.ID3D11VertexShader = null,
    ps_glow_extract: ?*c.ID3D11PixelShader = null,
    ps_kawase_down: ?*c.ID3D11PixelShader = null,
    ps_kawase_up: ?*c.ID3D11PixelShader = null,
    ps_glow_composite: ?*c.ID3D11PixelShader = null,
    bloom_prepare_attempted: bool = false,
    additive_blend: ?*c.ID3D11BlendState = null,
    bilinear_sampler: ?*c.ID3D11SamplerState = null,
    glow_cb: ?*c.ID3D11Buffer = null,
    /// Vertex-stage b0: maps a layer's vertex space to clip space. See
    /// LayerTransform in windows/shaders/main.hlsl.
    layer_cb: ?*c.ID3D11Buffer = null,
    /// Last value written to layer_cb, so redundant updates are skipped.
    layer_cb_value: [8]f32 = .{ 1, 1, 0, 0, 0, 0, 0, 0 },
    layer_cb_valid: bool = false,

    // User-supplied custom post-process shaders (Phase 2 macOS parity).
    // Loaded from config `[shaders].paths` after renderer init. Empty when
    // `shaders.enabled = false` or no paths configured.
    custom_shader_pipelines: std.ArrayListUnmanaged(CustomShaderPipeline) = .empty,
    custom_shader_post_process: u8 = 0, // 0=after_bloom, 1=before_bloom, 2=replace_bloom
    // Scratch copy of back_tex used as the pixel-shader input when running
    // the custom shader pass (reading and writing the same texture is
    // undefined in D3D11). Lazily sized and recreated on resize.
    custom_shader_scratch_tex: ?*c.ID3D11Texture2D = null,
    custom_shader_scratch_srv: ?*c.ID3D11ShaderResourceView = null,
    custom_shader_scratch_w: u32 = 0,
    custom_shader_scratch_h: u32 = 0,
    // Ping-pong render targets for multi-pass shader chains. Only
    // allocated when paths.len > 1. Each pass reads its input from
    // (scratch | pong_a | pong_b) and writes to the next pong or the
    // swapchain backbuffer on the final pass.
    custom_shader_pong_tex: [2]?*c.ID3D11Texture2D = .{ null, null },
    custom_shader_pong_srv: [2]?*c.ID3D11ShaderResourceView = .{ null, null },
    custom_shader_pong_rtv: [2]?*c.ID3D11RenderTargetView = .{ null, null },
    custom_shader_pong_w: u32 = 0,
    custom_shader_pong_h: u32 = 0,
    // Shadertoy uniform block (160 bytes, std140). Bound to register(b1)
    // in the SPIRV-Cross-emitted HLSL. Dynamic usage so UpdateSubresource
    // or Map/Unmap can refresh it each frame; single buffer is fine for
    // 160 bytes since the driver pipelines the CB write.
    custom_shader_uniforms_cb: ?*c.ID3D11Buffer = null,
    custom_shader_frame_index: i32 = 0,
    custom_shader_start_qpc: i64 = 0,
    custom_shader_last_qpc: i64 = 0,
    custom_shader_ema_frame_rate: f32 = 60.0,
    /// Ghostty 1.1+ cursor uniforms. iTimeCursorChange is in seconds
    /// relative to custom_shader_start_qpc. Updated via setCursorShaderState.
    shader_cursor_current: [4]f32 = .{ 0, 0, 0, 0 },
    shader_cursor_previous: [4]f32 = .{ 0, 0, 0, 0 },
    shader_cursor_current_color: [4]f32 = .{ 0, 0, 0, 0 },
    shader_cursor_previous_color: [4]f32 = .{ 0, 0, 0, 0 },
    shader_cursor_change_time: f32 = 0,
    /// True when any loaded custom shader references a time-varying
    /// Shadertoy uniform. The main loop reads this to decide whether to
    /// arm a ~60Hz WM_TIMER for continuous redraw; without it shaders
    /// that depend on iTime would only advance on Neovim flushes.
    any_custom_shader_needs_animation: bool = false,

    // Sizing
    width: u32 = 1,
    height: u32 = 1,
    has_presented_once: bool = false,
    needs_resize_retry: bool = false, // set true pessimistically before every
    // ResizeBuffers attempt; cleared ONLY after
    // createBackTargets() succeeds. Forces the
    // next resize() call to retry the full
    // ResizeBuffers+createBackTargets sequence
    // even if the requested size matches
    // self.width/self.height (i.e. even when a
    // prior attempt already committed the new
    // size before failing partway through).
    device_lost: bool = false, // set true when Present/ResizeBuffers/Present1
    // returns a device-lost HRESULT. Gates drawing exactly
    // like needs_resize_retry until a full re-init happens.

    /// Screen-space override for the custom shader uniforms. When
    /// non-zero, `updateCustomShaderUniforms` uses these instead of
    /// treating this HWND as its own screen. External windows set these
    /// to the main window's drawable size + the external HWND's
    /// top-left / size in main-window coordinates, so Shadertoy-style
    /// effects (starfield, glow) line up with the main window's
    /// universe instead of being re-centered per HWND.
    shader_screen_w: u32 = 0,
    shader_screen_h: u32 = 0,
    shader_window_offset_x: f32 = 0,
    shader_window_offset_y: f32 = 0,

    infoq: ?*c.ID3D11InfoQueue = null,
    dbg: ?*c.ID3D11Debug = null,

    // Background transparency (0.0-1.0, 1.0 = opaque)
    opacity: f32 = 1.0,

    // Mirrors config [window] blur for this renderer's surface. The core
    // drops the root grid's default-background run when the main surface has
    // layers AND blur is on (src/core/flush.zig, skip_default_bg), so the row
    // draw has to overwrite each band itself in that case even at opacity
    // 1.0. Only the main window sets this; external windows keep their own
    // default background run.
    blur_enabled: bool = false,

    // Neovim default background color (0x00RRGGBB), used for the
    // ClearRenderTargetView color. Without this, the bottom/right
    // remainder strip below/right of the cell-aligned NDC viewport
    // shows the hardcoded clear color (historically black) which is
    // visible whenever client_px is not an exact multiple of cell_px.
    // 0xFFFFFFFF means "not yet set" — fall back to black to match
    // pre-existing behavior until onDefaultColorsSet fires.
    // Atomic: written by RPC thread (onDefaultColorsSet), read by draw thread.
    default_bg_rgb: std.atomic.Value(u32) = std.atomic.Value(u32).init(0xFFFFFFFF),

    // DirectComposition for transparency
    dcomp_device: ?*IDCompositionDevice = null,
    dcomp_target: ?*IDCompositionTarget = null,
    dcomp_visual: ?*IDCompositionVisual = null,

    /// Create a D3D11 device without a swap chain. Returns the device and context.
    /// Called early (e.g. WM_CREATE) so the device is available for D2D context creation.
    pub fn createDeviceOnly() !struct { device: *c.ID3D11Device, ctx: *c.ID3D11DeviceContext } {
        var dev: ?*c.ID3D11Device = null;
        var ctx: ?*c.ID3D11DeviceContext = null;
        errdefer safeRelease(&dev);
        errdefer safeRelease(&ctx);
        var fl: u32 = 0;

        var flags: c.UINT = c.D3D11_CREATE_DEVICE_BGRA_SUPPORT; // Required for D2D interop
        const is_debug = (@import("builtin").mode == .Debug);
        if (is_debug) flags |= c.D3D11_CREATE_DEVICE_DEBUG;

        var hr: c.HRESULT = c.D3D11CreateDevice(
            null,
            c.D3D_DRIVER_TYPE_HARDWARE,
            null,
            flags,
            null,
            0,
            c.D3D11_SDK_VERSION,
            @ptrCast(&dev),
            @ptrCast(&fl),
            @ptrCast(&ctx),
        );

        if ((hr != 0 or dev == null or ctx == null) and is_debug) {
            safeRelease(&dev);
            safeRelease(&ctx);
            flags &= ~@as(c.UINT, c.D3D11_CREATE_DEVICE_DEBUG);
            hr = c.D3D11CreateDevice(
                null,
                c.D3D_DRIVER_TYPE_HARDWARE,
                null,
                flags,
                null,
                0,
                c.D3D11_SDK_VERSION,
                @ptrCast(&dev),
                @ptrCast(&fl),
                @ptrCast(&ctx),
            );
        }

        if (hr != 0 or dev == null or ctx == null) {
            dbgLog("[d3d] createDeviceOnly: D3D11CreateDevice failed hr=0x{x}\n", .{@as(u32, @bitCast(hr))});
            return error.D3DCreateFailed;
        }
        dbgLog("[d3d] createDeviceOnly: ok dev=0x{x} fl=0x{x}\n", .{ @intFromPtr(dev.?), fl });
        return .{ .device = dev.?, .ctx = ctx.? };
    }

    /// Initialize with a pre-created D3D11 device (from createDeviceOnly).
    pub fn initWithDevice(alloc: std.mem.Allocator, hwnd: c.HWND, opacity: f32, device: *c.ID3D11Device, device_ctx: *c.ID3D11DeviceContext) !Renderer {
        // Take our own COM reference on the App-owned device/context so this
        // renderer's deinit() can Release() without over-releasing the App's
        // reference. App creates this device via createDeviceOnly() and
        // releases its own reference separately in App.deinit() -- see
        // windows/app.zig.
        addRef(device);
        addRef(device_ctx);
        var self: Renderer = .{
            .alloc = alloc,
            .hwnd = hwnd,
            .opacity = opacity,
            .device = device,
            .ctx = device_ctx,
        };
        // Five `try` fail points follow (createSwapchainOnly/createBackTargets/
        // createPipeline/ensureVertexBuffer/createAtlasTexture). self.deinit()
        // releases the two references taken above AND whatever any earlier
        // successful step in this sequence already created (swapchain, back
        // targets, pipeline, vertex buffer) -- a narrower errdefer covering
        // only device/ctx would leak all of that on a later step's failure.
        // safeRelease no-ops on still-null fields, so calling deinit() on
        // this partially-initialized self is safe regardless of which step
        // failed.
        errdefer self.deinit();

        dbgLog("[d3d] initWithDevice: reusing pre-created device=0x{x}\n", .{@intFromPtr(device)});

        var freq: c.LARGE_INTEGER = undefined;
        var t0: c.LARGE_INTEGER = undefined;
        var t1: c.LARGE_INTEGER = undefined;
        _ = c.QueryPerformanceFrequency(&freq);

        _ = c.QueryPerformanceCounter(&t0);
        try self.createSwapchainOnly();
        _ = c.QueryPerformanceCounter(&t1);
        dbgLog("[d3d] [TIMING] createSwapchainOnly: {d}ms\n", .{@divTrunc((t1.QuadPart - t0.QuadPart) * 1000, freq.QuadPart)});

        _ = c.QueryPerformanceCounter(&t0);
        try self.createBackTargets();
        _ = c.QueryPerformanceCounter(&t1);
        dbgLog("[d3d] [TIMING] createBackTargets: {d}ms\n", .{@divTrunc((t1.QuadPart - t0.QuadPart) * 1000, freq.QuadPart)});

        _ = c.QueryPerformanceCounter(&t0);
        try self.createPipeline();
        _ = c.QueryPerformanceCounter(&t1);
        dbgLog("[d3d] [TIMING] createPipeline (shader compile): {d}ms\n", .{@divTrunc((t1.QuadPart - t0.QuadPart) * 1000, freq.QuadPart)});

        _ = c.QueryPerformanceCounter(&t0);
        try self.ensureVertexBuffer(1024 * @sizeOf(core.Vertex));
        _ = c.QueryPerformanceCounter(&t1);
        dbgLog("[d3d] [TIMING] ensureVertexBuffer: {d}ms\n", .{@divTrunc((t1.QuadPart - t0.QuadPart) * 1000, freq.QuadPart)});

        _ = c.QueryPerformanceCounter(&t0);
        try self.createAtlasTexture(self.atlas_w, self.atlas_h);
        _ = c.QueryPerformanceCounter(&t1);
        dbgLog("[d3d] [TIMING] createAtlasTexture: {d}ms\n", .{@divTrunc((t1.QuadPart - t0.QuadPart) * 1000, freq.QuadPart)});

        return self;
    }

    pub fn init(alloc: std.mem.Allocator, hwnd: c.HWND, opacity: f32) !Renderer {
        var self: Renderer = .{
            .alloc = alloc,
            .hwnd = hwnd,
            .opacity = opacity,
        };
        // Five `try` fail points follow (createDeviceAndSwapchain/
        // createBackTargets/createPipeline/ensureVertexBuffer/
        // createAtlasTexture), each building on the previous one's
        // resources. Without this, a later step's failure leaks everything
        // created by the earlier ones (device, swapchain, DComp, back
        // targets, pipeline, vertex buffer). safeRelease no-ops on
        // still-null fields, so calling deinit() on this
        // partially-initialized self is safe regardless of which step failed.
        errdefer self.deinit();

        // Log vertex struct size for diagnostics
        dbgLog("[d3d] init: Vertex size={d} align={d}\n", .{ @sizeOf(core.Vertex), @alignOf(core.Vertex) });

        // Timing for init steps
        var freq: c.LARGE_INTEGER = undefined;
        var t0: c.LARGE_INTEGER = undefined;
        var t1: c.LARGE_INTEGER = undefined;
        _ = c.QueryPerformanceFrequency(&freq);

        _ = c.QueryPerformanceCounter(&t0);
        try self.createDeviceAndSwapchain();
        _ = c.QueryPerformanceCounter(&t1);
        dbgLog("[d3d] [TIMING] createDeviceAndSwapchain: {d}ms\n", .{@divTrunc((t1.QuadPart - t0.QuadPart) * 1000, freq.QuadPart)});

        _ = c.QueryPerformanceCounter(&t0);
        try self.createBackTargets();
        _ = c.QueryPerformanceCounter(&t1);
        dbgLog("[d3d] [TIMING] createBackTargets: {d}ms\n", .{@divTrunc((t1.QuadPart - t0.QuadPart) * 1000, freq.QuadPart)});

        _ = c.QueryPerformanceCounter(&t0);
        try self.createPipeline();
        _ = c.QueryPerformanceCounter(&t1);
        dbgLog("[d3d] [TIMING] createPipeline (shader compile): {d}ms\n", .{@divTrunc((t1.QuadPart - t0.QuadPart) * 1000, freq.QuadPart)});

        _ = c.QueryPerformanceCounter(&t0);
        try self.ensureVertexBuffer(1024 * @sizeOf(core.Vertex));
        _ = c.QueryPerformanceCounter(&t1);
        dbgLog("[d3d] [TIMING] ensureVertexBuffer: {d}ms\n", .{@divTrunc((t1.QuadPart - t0.QuadPart) * 1000, freq.QuadPart)});

        _ = c.QueryPerformanceCounter(&t0);
        // Initial atlas texture (will be recreated by on_atlas_create with configured size)
        try self.createAtlasTexture(self.atlas_w, self.atlas_h);
        _ = c.QueryPerformanceCounter(&t1);
        dbgLog("[d3d] [TIMING] createAtlasTexture: {d}ms\n", .{@divTrunc((t1.QuadPart - t0.QuadPart) * 1000, freq.QuadPart)});

        return self;
    }

    /// Update the default background color used by ClearRenderTargetView.
    /// Pass 0x00RRGGBB; pass 0xFFFFFFFF to fall back to black.
    /// Thread-safe: called from RPC thread, read by draw thread.
    pub fn setDefaultBgColor(self: *Renderer, rgb: u32) void {
        self.default_bg_rgb.store(rgb, .release);
    }

    pub fn lockContext(self: *Renderer) void {
        self.ctx_mu.lockUncancelable(core.clock.io());
    }

    /// Unlock the D3D11 device context.
    pub fn unlockContext(self: *Renderer) void {
        self.ctx_mu.unlock(core.clock.io());
    }

    pub fn deinit(self: *Renderer) void {
        safeRelease(&self.atlas_srv);
        safeRelease(&self.atlas_tex);

        safeRelease(&self.tabline_srv);
        safeRelease(&self.tabline_tex);

        safeRelease(&self.sidebar_srv);
        safeRelease(&self.sidebar_tex);

        // Bloom resources
        safeRelease(&self.glow_extract_srv);
        safeRelease(&self.glow_extract_rtv);
        safeRelease(&self.glow_extract_tex);
        for (&self.glow_mip_srv) |*s| safeRelease(s);
        for (&self.glow_mip_rtv) |*r| safeRelease(r);
        for (&self.glow_mip_tex) |*t| safeRelease(t);
        safeRelease(&self.vs_fullscreen);
        safeRelease(&self.vs_custom_post);
        safeRelease(&self.ps_glow_extract);
        safeRelease(&self.ps_kawase_down);
        safeRelease(&self.ps_kawase_up);
        safeRelease(&self.ps_glow_composite);
        safeRelease(&self.additive_blend);
        safeRelease(&self.bilinear_sampler);
        safeRelease(&self.glow_cb);
        safeRelease(&self.layer_cb);

        // Custom shader resources
        for (self.custom_shader_pipelines.items) |*p| p.deinit();
        self.custom_shader_pipelines.deinit(self.alloc);
        safeRelease(&self.custom_shader_scratch_srv);
        safeRelease(&self.custom_shader_scratch_tex);
        for (&self.custom_shader_pong_srv) |*s| safeRelease(s);
        for (&self.custom_shader_pong_rtv) |*r| safeRelease(r);
        for (&self.custom_shader_pong_tex) |*t| safeRelease(t);
        safeRelease(&self.custom_shader_uniforms_cb);

        safeRelease(&self.vb);
        safeRelease(&self.rs);
        safeRelease(&self.blend);
        safeRelease(&self.sampler);
        safeRelease(&self.il);
        safeRelease(&self.ps);
        safeRelease(&self.vs);

        safeRelease(&self.vs_cb);

        safeRelease(&self.back_rtv);
        safeRelease(&self.back_tex);
        safeRelease(&self.scroll_staging_tex);
        safeRelease(&self.scrollbar_underlay_tex);
        safeRelease(&self.clear_row_vb);

        if (applog.isEnabled()) {
            applog.appLog(
                "[d3d] resize: after release bb_tex=0x{x} bb_rtv=0x{x} back_tex=0x{x} back_rtv=0x{x}\n",
                .{
                    if (self.bb_tex) |p| @intFromPtr(p) else 0,
                    if (self.bb_rtv) |p| @intFromPtr(p) else 0,
                    if (self.back_tex) |p| @intFromPtr(p) else 0,
                    if (self.back_rtv) |p| @intFromPtr(p) else 0,
                },
            );
        }

        var i: usize = 0;
        while (i < MaxSwapchainBuffers) : (i += 1) {
            safeRelease(&self.bb_rtvs[i]);
            safeRelease(&self.bb_texs[i]);
        }
        self.bb_rtv = null;
        self.bb_tex = null;

        safeRelease(&self.dcomp_visual);
        safeRelease(&self.dcomp_target);
        safeRelease(&self.dcomp_device);

        safeRelease(&self.swapchain);
        safeRelease(&self.swapchain1);
        safeRelease(&self.swapchain3);

        safeRelease(&self.infoq);
        safeRelease(&self.dbg);

        safeRelease(&self.ctx);
        safeRelease(&self.device);

        self.* = undefined;
    }

    fn currentSwapchainIndex(self: *Renderer) u32 {
        if (self.swapchain3) |sc3| {
            const vtbl = sc3.*.lpVtbl;
            if (vtbl.*.GetCurrentBackBufferIndex) |f| {
                const idx = f(sc3);
                if (applog.isEnabled()) {
                    applog.appLog("[d3d] GetCurrentBackBufferIndex -> {d}\n", .{idx});
                }
                return idx;
            }
        }
        if (self.swapchain_buf_count == 0) return 0;
        if (self.swapchain_buf_index >= self.swapchain_buf_count) return 0;
        return self.swapchain_buf_index;
    }

    fn advanceSwapchainIndex(self: *Renderer) void {
        if (self.swapchain3 != null) return;
        if (self.swapchain_buf_count <= 1) return;
        self.swapchain_buf_index = (self.swapchain_buf_index + 1) % self.swapchain_buf_count;
    }

    fn currentBackBufferTex(self: *Renderer) *c.ID3D11Texture2D {
        const idx = self.currentSwapchainIndex();
        return self.bb_texs[@intCast(idx)] orelse self.bb_tex.?;
    }

    fn resetBackBufferDamage(self: *Renderer) void {
        for (0..MaxSwapchainBuffers) |i| {
            self.bb_pending_full[i] = true;
            self.bb_pending_rect_count[i] = 0;
        }
    }

    fn clampBackDamageRect(self: *const Renderer, rect: c.RECT) ?c.RECT {
        var r = rect;
        r.left = @max(0, r.left);
        r.top = @max(0, r.top);
        r.right = @min(@as(i32, @intCast(self.width)), r.right);
        r.bottom = @min(@as(i32, @intCast(self.height)), r.bottom);
        return if (r.right > r.left and r.bottom > r.top) r else null;
    }

    fn appendBackDamage(self: *Renderer, buffer_index: usize, rect: c.RECT) void {
        if (self.bb_pending_full[buffer_index]) return;

        var merged = rect;
        var count: usize = self.bb_pending_rect_count[buffer_index];
        var i: usize = 0;
        while (i < count) {
            const old = self.bb_pending_rects[buffer_index][i];
            if (merged.left <= old.right and merged.right >= old.left and
                merged.top <= old.bottom and merged.bottom >= old.top)
            {
                merged = .{
                    .left = @min(old.left, merged.left),
                    .top = @min(old.top, merged.top),
                    .right = @max(old.right, merged.right),
                    .bottom = @max(old.bottom, merged.bottom),
                };
                count -= 1;
                self.bb_pending_rects[buffer_index][i] = self.bb_pending_rects[buffer_index][count];
                i = 0;
                continue;
            }
            i += 1;
        }

        if (count == MaxPendingBackDamageRects) {
            self.bb_pending_full[buffer_index] = true;
            self.bb_pending_rect_count[buffer_index] = 0;
            return;
        }
        self.bb_pending_rects[buffer_index][count] = merged;
        self.bb_pending_rect_count[buffer_index] = @intCast(count + 1);
    }

    fn queueBackDamage(self: *Renderer, rects: []const c.RECT, full: bool) void {
        const count: usize = @intCast(@max(@as(u32, 1), self.swapchain_buf_count));
        if (full) {
            for (0..@min(count, MaxSwapchainBuffers)) |i| {
                self.bb_pending_full[i] = true;
                self.bb_pending_rect_count[i] = 0;
            }
            return;
        }

        for (rects) |raw| {
            const rect = self.clampBackDamageRect(raw) orelse {
                for (0..@min(count, MaxSwapchainBuffers)) |i| {
                    self.bb_pending_full[i] = true;
                    self.bb_pending_rect_count[i] = 0;
                }
                return;
            };
            for (0..@min(count, MaxSwapchainBuffers)) |i| {
                self.appendBackDamage(i, rect);
            }
        }
    }

    /// Copy only the current rotating buffer, including damage accumulated
    /// since that buffer was last current. Returns the exact dirty rects that
    /// Present1 must publish; `out_rects` is fixed caller-owned scratch.
    fn copyQueuedBackDamage(
        self: *Renderer,
        ctx: *c.ID3D11DeviceContext,
        back_tex: *c.ID3D11Texture2D,
        out_rects: *[MaxPendingBackDamageRects]c.RECT,
    ) !BackCopyDamage {
        const index_u32 = self.currentSwapchainIndex();
        if (index_u32 >= @as(u32, MaxSwapchainBuffers)) return error.D3DGetBackBufferFailed;
        const index: usize = @intCast(index_u32);
        const dst_tex = self.bb_texs[index] orelse self.currentBackBufferTex();
        const dst: *c.ID3D11Resource = @ptrCast(dst_tex);
        const src: *c.ID3D11Resource = @ptrCast(back_tex);
        const vtbl = ctx.*.lpVtbl;

        if (self.bb_pending_full[index]) {
            const copy = vtbl.*.CopyResource orelse return error.RenderResourcesUnavailable;
            copy(ctx, dst, src);
            self.bb_pending_full[index] = false;
            self.bb_pending_rect_count[index] = 0;
            return .{ .full = true };
        }

        const count: usize = self.bb_pending_rect_count[index];
        if (count == 0) return .{};
        const copy = vtbl.*.CopySubresourceRegion orelse return error.RenderResourcesUnavailable;
        for (self.bb_pending_rects[index][0..count], 0..) |rect, i| {
            const box: c.D3D11_BOX = .{
                .left = @intCast(rect.left),
                .top = @intCast(rect.top),
                .front = 0,
                .right = @intCast(rect.right),
                .bottom = @intCast(rect.bottom),
                .back = 1,
            };
            copy(ctx, dst, 0, @intCast(rect.left), @intCast(rect.top), 0, src, 0, &box);
            out_rects[i] = rect;
        }
        self.bb_pending_rect_count[index] = 0;
        return .{ .rect_count = count };
    }

    /// Cheap guard: true only when the persistent back buffer and current
    /// swapchain backbuffer are all present. False right after a failed
    /// resize() (see needs_resize_retry) or while device_lost is set.
    fn resourcesReady(self: *const Renderer) bool {
        return self.back_rtv != null and self.back_tex != null and self.bb_tex != null and !self.needs_resize_retry and !self.device_lost;
    }

    pub fn resize(self: *Renderer) !void {
        var rc: c.RECT = undefined;
        _ = c.GetClientRect(self.hwnd, &rc);

        if (applog.isEnabled()) {
            applog.appLog(
                "[d3d] resize: client=({d},{d})-({d},{d}) cur_wh=({d},{d}) bb_tex=0x{x} bb_rtv=0x{x} back_tex=0x{x} back_rtv=0x{x} sc=0x{x} ctx=0x{x}\n",
                .{
                    rc.left,                                      rc.top,                                       rc.right,                                      rc.bottom,
                    self.width,                                   self.height,                                  if (self.bb_tex) |p| @intFromPtr(p) else 0,    if (self.bb_rtv) |p| @intFromPtr(p) else 0,
                    if (self.back_tex) |p| @intFromPtr(p) else 0, if (self.back_rtv) |p| @intFromPtr(p) else 0, if (self.swapchain) |p| @intFromPtr(p) else 0, if (self.ctx) |p| @intFromPtr(p) else 0,
                },
            );
        }

        const w: u32 = @intCast(@max(1, rc.right - rc.left));
        const h: u32 = @intCast(@max(1, rc.bottom - rc.top));
        if (w == self.width and h == self.height and !self.needs_resize_retry) return;

        self.width = w;
        self.height = h;
        self.has_presented_once = false;
        self.swapchain_buf_index = 0;

        // Set pessimistically BEFORE attempting ResizeBuffers. Covers all three
        // failure points below (missing ResizeBuffers vtable slot, ResizeBuffers
        // itself failing, and createBackTargets() failing) with a single flag
        // write instead of duplicating the assignment in every failure branch —
        // cleared only once the whole sequence has fully succeeded, below.
        self.needs_resize_retry = true;

        // --- ADD: Unbind pipeline references before releasing resize-related resources ---
        // If back buffer / RTV are still bound, releasing them can lead to use-after-release
        // inside subsequent D3D calls during resize/draw.
        if (self.ctx) |ctx| {
            const vtbl = ctx.*.lpVtbl;

            // Unbind render targets
            if (vtbl.*.OMSetRenderTargets) |om_set| {
                om_set(ctx, 0, null, null);
            }

            // Unbind PS SRV slot 0 (atlas SRV is usually bound there)
            if (vtbl.*.PSSetShaderResources) |ps_set| {
                var null_srvs: [1]?*c.ID3D11ShaderResourceView = .{null};
                const pp_null_srvs: [*c]?*c.ID3D11ShaderResourceView =
                    @as([*c]?*c.ID3D11ShaderResourceView, @ptrCast(&null_srvs));
                ps_set(ctx, 0, 1, pp_null_srvs);
            }

            // Ensure the driver consumes unbind commands before ResizeBuffers/release
            if (vtbl.*.Flush) |flush| {
                flush(ctx);
            }
        }

        // Release + null (avoid use-after-release)
        {
            var i: usize = 0;
            while (i < MaxSwapchainBuffers) : (i += 1) {
                safeRelease(&self.bb_rtvs[i]);
                safeRelease(&self.bb_texs[i]);
            }
            self.bb_rtv = null;
            self.bb_tex = null;
        }
        safeRelease(&self.back_rtv);
        safeRelease(&self.back_tex);
        safeRelease(&self.scroll_staging_tex);
        safeRelease(&self.scrollbar_underlay_tex);
        self.scrollbar_underlay_state.resourceFailed();
        safeRelease(&self.clear_row_vb);
        // Scratch + ping-pong textures belong to the old back buffer's
        // size/format; drop them and let the shader pass rebuild on
        // the next draw.
        safeRelease(&self.custom_shader_scratch_srv);
        safeRelease(&self.custom_shader_scratch_tex);
        self.custom_shader_scratch_w = 0;
        self.custom_shader_scratch_h = 0;
        for (&self.custom_shader_pong_srv) |*s| safeRelease(s);
        for (&self.custom_shader_pong_rtv) |*r| safeRelease(r);
        for (&self.custom_shader_pong_tex) |*t| safeRelease(t);
        self.custom_shader_pong_w = 0;
        self.custom_shader_pong_h = 0;

        const sc = self.swapchain.?;
        const sc_vtbl = sc.*.lpVtbl;
        const resize_buf = sc_vtbl.*.ResizeBuffers orelse return error.D3DResizeBuffersFailed;

        const hr_rb = resize_buf(sc, 0, w, h, c.DXGI_FORMAT_UNKNOWN, 0);
        if (c.FAILED(hr_rb)) {
            if (isDeviceLost(hr_rb)) self.device_lost = true;
            return error.D3DResizeBuffersFailed;
        }

        try self.createBackTargets();
        self.needs_resize_retry = false;
    }

    pub fn atlasUploadRect(self: *Renderer, x: u32, y: u32, w: u32, h: u32, data: [*]const u8, row_pitch: u32) bool {
        if (applog.isEnabled()) {
            const tex_ptr: usize = if (self.atlas_tex) |p| @intFromPtr(p) else 0;
            const ctx_ptr: usize = if (self.ctx) |p| @intFromPtr(p) else 0;
            applog.appLog(
                "[d3d] atlasUploadRect x={d} y={d} w={d} h={d} row_pitch={d} tex=0x{x} ctx=0x{x}\n",
                .{ x, y, w, h, row_pitch, tex_ptr, ctx_ptr },
            );
        }

        const tex = self.atlas_tex orelse {
            if (applog.isEnabled()) applog.appLog("[d3d] atlasUploadRect: atlas_tex is null -> skip\n", .{});
            return false;
        };
        const ctx = self.ctx orelse {
            if (applog.isEnabled()) applog.appLog("[d3d] atlasUploadRect: ctx is null -> skip\n", .{});
            return false;
        };

        if (applog.isEnabled()) {
            // vtbl sanity log (dangling ctx often dies at ctx.*)
            const ctx_vtbl_ptr: usize = @intFromPtr(ctx.*.lpVtbl);
            applog.appLog("[d3d] atlasUploadRect: ctx.vtbl=0x{x}\n", .{ctx_vtbl_ptr});
        }

        // Defensive bounds check: never hand UpdateSubresource a box that
        // exceeds the actual atlas texture dimensions. Uses saturating add
        // to avoid u32 overflow on an adversarial w/h before comparing.
        if (x +| w > self.atlas_w or y +| h > self.atlas_h) {
            if (applog.isEnabled()) applog.appLog(
                "[d3d] atlasUploadRect: out-of-bounds rect x={d} y={d} w={d} h={d} atlas={d}x{d} -> skip\n",
                .{ x, y, w, h, self.atlas_w, self.atlas_h },
            );
            return false;
        }

        var box: c.D3D11_BOX = .{
            .left = x,
            .top = y,
            .front = 0,
            .right = x + w,
            .bottom = y + h,
            .back = 1,
        };

        const upd = ctx.*.lpVtbl.*.UpdateSubresource orelse {
            if (applog.isEnabled()) applog.appLog("[d3d] atlasUploadRect: UpdateSubresource is null -> skip\n", .{});
            return false;
        };

        const dst_res: *c.ID3D11Resource = @ptrCast(tex);
        upd(ctx, dst_res, 0, &box, data, row_pitch, 0);
        return true;
    }

    pub const DrawOpts = struct {
        present: bool = true,

        // If dirty_rect == null but we are doing partial redraw into a persistent back buffer,
        // we must NOT clear. (Row-mode present step uses this.)
        preserve_on_null_dirty: bool = false,

        // Content width for viewport (used in "always" scrollbar mode to reserve space).
        // If null, uses full window width.
        content_width: ?u32 = null,

        // Content Y offset for viewport (used for tabline to offset content below tab bar).
        // If null, uses 0.
        content_y_offset: ?u32 = null,

        // Content X offset for viewport (used for sidebar to offset content right of sidebar).
        // If null, uses 0.
        content_x_offset: ?u32 = null,

        // Sidebar width on the right side (reduces content width from right edge).
        // If null, no right sidebar.
        sidebar_right_width: ?u32 = null,

        // Content height for viewport, snapped to cell boundaries.
        // Must match the core's NDC viewport calculation (grid_rows * cell_h).
        // If null, uses (self.height - content_y_offset).
        content_height: ?u32 = null,

        // Tabbar background color (RGBA, premultiplied alpha).
        // If non-null and content_y_offset is set, draws a solid rect in the tabbar area.
        tabbar_bg_color: ?[4]f32 = null,

        // Post-process bloom (neon glow)
        glow_enabled: bool = false,
        glow_intensity: f32 = 0.8,
    };

    pub fn drawEx(
        self: *Renderer,
        main: []const core.Vertex,
        cursor: []const core.Vertex,
        dirty_rect: ?c.RECT,
        opts: DrawOpts,
    ) !void {
        var t_draw_start: i128 = 0;
        if (applog.isEnabled()) t_draw_start = core.clock.nowNs();

        try self.resize();
        if (!self.resourcesReady()) return error.RenderResourcesUnavailable;
        // Frontend-authored vertices are already in clip space.
        self.setLayerTransform(0, 0, 0, 0);

        if (applog.isEnabled()) {
            applog.appLog(
                "[d3d] draw: w={d} h={d} main={d} cursor={d} dirty={s} vs={s} ps={s} il={s} srv={s} samp={s} blend={s}\n",
                .{
                    self.width,                                   self.height,
                    main.len,                                     cursor.len,
                    if (dirty_rect == null) "null" else "rect",   if (self.vs == null) "null" else "ok",
                    if (self.ps == null) "null" else "ok",        if (self.il == null) "null" else "ok",
                    if (self.atlas_srv == null) "null" else "ok", if (self.sampler == null) "null" else "ok",
                    if (self.blend == null) "null" else "ok",
                },
            );
        }

        const ctx = self.ctx.?;
        const sc = self.swapchain.?;

        const back_rtv = self.back_rtv.?; // persistent back buffer RTV
        const back_tex = self.back_tex.?; // persistent back buffer texture

        const ctx_vtbl = ctx.*.lpVtbl;

        // ---- Bind persistent back buffer as render target ----
        {
            const om_set_rt = ctx_vtbl.*.OMSetRenderTargets orelse return;

            var rtvs: [1]?*c.ID3D11RenderTargetView = .{back_rtv};
            const pp_rtvs: [*c]?*c.ID3D11RenderTargetView =
                @as([*c]?*c.ID3D11RenderTargetView, @ptrCast(&rtvs));

            om_set_rt(ctx, 1, pp_rtvs, null);
        }

        // ---- Clear ----
        //
        // IMPORTANT:
        // preserve_on_null_dirty==true is for row-mode present step.
        // In this case, clearing even on first frame (has_presented_once==false)
        // would erase all drawing accumulated in back_tex before present.
        //
        // Only clear when preserve is not requested.
        const should_clear =
            (!opts.preserve_on_null_dirty) and
            (
                // First frame (normal rendering) should clear
                (!self.has_presented_once) or
                    // dirty_rect==null means full redraw, so clear
                    (dirty_rect == null) or
                    // Transparency mode: always clear to prevent alpha accumulation
                    (self.opacity < 1.0));

        // Compute clear color from default bg (premultiplied alpha: RGB
        // must be multiplied by the opacity used as alpha). Falls back to
        // black before onDefaultColorsSet has fired so behavior matches
        // the previous hardcoded clear in that early window.
        const bg_rgb = self.default_bg_rgb.load(.acquire);
        const clear: [4]f32 = blk: {
            if (bg_rgb == 0xFFFFFFFF) {
                break :blk .{ 0, 0, 0, self.opacity };
            }
            const r_u: u32 = (bg_rgb >> 16) & 0xFF;
            const g_u: u32 = (bg_rgb >> 8) & 0xFF;
            const b_u: u32 = bg_rgb & 0xFF;
            const r: f32 = (@as(f32, @floatFromInt(r_u)) / 255.0) * self.opacity;
            const g: f32 = (@as(f32, @floatFromInt(g_u)) / 255.0) * self.opacity;
            const b: f32 = (@as(f32, @floatFromInt(b_u)) / 255.0) * self.opacity;
            break :blk .{ r, g, b, self.opacity };
        };

        if (should_clear) {
            // A full clear erases any baked scrollbar overlay, so its saved
            // underlay no longer belongs to the new back_tex contents.
            self.scrollbar_underlay_state.restored();
            const clear_rtv = ctx_vtbl.*.ClearRenderTargetView orelse return;
            clear_rtv(ctx, back_rtv, &clear);
        }

        // ---- Viewport ----
        // Use content_width if specified (for "always" scrollbar mode)
        // Use content_y_offset if specified (for tabline)
        // Use content_x_offset if specified (for left sidebar)
        const viewport_x_offset = opts.content_x_offset orelse 0;
        const viewport_y_offset = opts.content_y_offset orelse 0;
        const sidebar_right_w = opts.sidebar_right_width orelse 0;
        const base_width = opts.content_width orelse self.width;
        const viewport_width = if (base_width > viewport_x_offset + sidebar_right_w) base_width - viewport_x_offset - sidebar_right_w else 1;
        const viewport_height = opts.content_height orelse
            (if (self.height > viewport_y_offset) self.height - viewport_y_offset else 1);
        {
            var vp: c.D3D11_VIEWPORT = .{
                .TopLeftX = @floatFromInt(viewport_x_offset),
                .TopLeftY = @floatFromInt(viewport_y_offset),
                .Width = @floatFromInt(viewport_width),
                .Height = @floatFromInt(viewport_height),
                .MinDepth = 0,
                .MaxDepth = 1,
            };
            const rs_set_vp = ctx_vtbl.*.RSSetViewports orelse return;
            rs_set_vp(ctx, 1, &vp);
        }

        const effective_dirty: ?c.RECT = if (!self.has_presented_once) null else dirty_rect;

        // ---- Scissor ----
        // D3D11 scissor rects are in render-target absolute coordinates,
        // so they must include viewport_x_offset and viewport_y_offset.
        {
            const rs_set_sc = ctx_vtbl.*.RSSetScissorRects orelse return;
            const x_off_i: c.LONG = @intCast(viewport_x_offset);
            const y_off_i: c.LONG = @intCast(viewport_y_offset);

            if (effective_dirty) |r| {
                // Clamp scissor to viewport bounds (absolute coords)
                var sr: c.D3D11_RECT = .{
                    .left = @max(0, x_off_i + r.left),
                    .top = @max(0, y_off_i + r.top),
                    .right = @min(x_off_i + r.right, @as(c.LONG, @intCast(viewport_x_offset + viewport_width))),
                    .bottom = @min(y_off_i + r.bottom, @as(c.LONG, @intCast(viewport_y_offset + viewport_height))),
                };
                rs_set_sc(ctx, 1, &sr);
            } else {
                var sr: c.D3D11_RECT = .{
                    .left = x_off_i,
                    .top = y_off_i,
                    .right = @intCast(viewport_x_offset + viewport_width),
                    .bottom = @intCast(viewport_y_offset + viewport_height),
                };
                rs_set_sc(ctx, 1, &sr);
            }
        }

        // ---- Pipeline state ----
        {
            const ia_set_il = ctx_vtbl.*.IASetInputLayout orelse return;
            ia_set_il(ctx, self.il.?);

            // RS: rasterizer state (disable cull + enable scissor)
            const rs_set_state = ctx_vtbl.*.RSSetState orelse return;
            rs_set_state(ctx, self.rs.?);

            const vs_set = ctx_vtbl.*.VSSetShader orelse return;
            vs_set(ctx, self.vs.?, null, 0);

            const ps_set = ctx_vtbl.*.PSSetShader orelse return;
            ps_set(ctx, self.ps.?, null, 0);

            // PS SRV (skip draw if atlas was destroyed and not yet recreated)
            const ps_set_srv = ctx_vtbl.*.PSSetShaderResources orelse return;
            const srv = self.atlas_srv orelse return;
            var srvs: [1]?*c.ID3D11ShaderResourceView = .{srv};
            const pp_srvs: [*c]?*c.ID3D11ShaderResourceView =
                @as([*c]?*c.ID3D11ShaderResourceView, @ptrCast(&srvs));
            ps_set_srv(ctx, 0, 1, pp_srvs);

            // PS Sampler
            const ps_set_samp = ctx_vtbl.*.PSSetSamplers orelse return;
            const samp = self.sampler.?;
            var samps: [1]?*c.ID3D11SamplerState = .{samp};
            const pp_samps: [*c]?*c.ID3D11SamplerState =
                @as([*c]?*c.ID3D11SamplerState, @ptrCast(&samps));
            ps_set_samp(ctx, 0, 1, pp_samps);

            // Alpha blend
            const om_set_blend = ctx_vtbl.*.OMSetBlendState orelse return;
            var blend_factor: [4]f32 = .{ 0, 0, 0, 0 };
            om_set_blend(ctx, self.blend.?, &blend_factor, 0xFFFFFFFF);
        }

        // ---- Tabbar (if content_y_offset is set) ----
        // Priority: tabline texture > tabbar_bg_color > nothing
        if (opts.content_y_offset) |y_off| {
            const rs_set_vp = ctx_vtbl.*.RSSetViewports orelse return;
            const rs_set_sc = ctx_vtbl.*.RSSetScissorRects orelse return;

            // Set full-screen viewport for tabbar drawing
            var full_vp: c.D3D11_VIEWPORT = .{
                .TopLeftX = 0,
                .TopLeftY = 0,
                .Width = @floatFromInt(self.width),
                .Height = @floatFromInt(self.height),
                .MinDepth = 0,
                .MaxDepth = 1,
            };
            rs_set_vp(ctx, 1, &full_vp);

            // Set full-screen scissor
            var full_sr: c.D3D11_RECT = .{
                .left = 0,
                .top = 0,
                .right = @intCast(self.width),
                .bottom = @intCast(self.height),
            };
            rs_set_sc(ctx, 1, &full_sr);

            if (self.tabline_srv != null) {
                // Draw tabline texture (rendered from GDI offscreen)
                try self.drawTablineTexture();
            } else if (opts.tabbar_bg_color) |bg_color| {
                // Fallback: draw solid color background
                // Generate tabbar background vertices (NDC coordinates)
                // Top of screen is y=1.0, bottom is y=-1.0
                const bottom_y: f32 = 1.0 - 2.0 * (@as(f32, @floatFromInt(y_off)) / @as(f32, @floatFromInt(self.height)));
                const tabbar_verts = [6]core.Vertex{
                    // Triangle 1: top-left, top-right, bottom-left
                    .{ .position = .{ -1.0, 1.0 }, .texCoord = .{ -1.0, 0.0 }, .color = bg_color, .grid_id = 0, .deco_flags = 0, .deco_phase = 0 },
                    .{ .position = .{ 1.0, 1.0 }, .texCoord = .{ -1.0, 0.0 }, .color = bg_color, .grid_id = 0, .deco_flags = 0, .deco_phase = 0 },
                    .{ .position = .{ -1.0, bottom_y }, .texCoord = .{ -1.0, 0.0 }, .color = bg_color, .grid_id = 0, .deco_flags = 0, .deco_phase = 0 },
                    // Triangle 2: top-right, bottom-right, bottom-left
                    .{ .position = .{ 1.0, 1.0 }, .texCoord = .{ -1.0, 0.0 }, .color = bg_color, .grid_id = 0, .deco_flags = 0, .deco_phase = 0 },
                    .{ .position = .{ 1.0, bottom_y }, .texCoord = .{ -1.0, 0.0 }, .color = bg_color, .grid_id = 0, .deco_flags = 0, .deco_phase = 0 },
                    .{ .position = .{ -1.0, bottom_y }, .texCoord = .{ -1.0, 0.0 }, .color = bg_color, .grid_id = 0, .deco_flags = 0, .deco_phase = 0 },
                };
                try self.drawVertices(&tabbar_verts);
            }

            // Restore content viewport
            var content_vp: c.D3D11_VIEWPORT = .{
                .TopLeftX = @floatFromInt(viewport_x_offset),
                .TopLeftY = @floatFromInt(viewport_y_offset),
                .Width = @floatFromInt(viewport_width),
                .Height = @floatFromInt(viewport_height),
                .MinDepth = 0,
                .MaxDepth = 1,
            };
            rs_set_vp(ctx, 1, &content_vp);

            // Restore content scissor (absolute coords matching viewport)
            {
                const x_off_t: c.LONG = @intCast(viewport_x_offset);
                const y_off_t: c.LONG = @intCast(viewport_y_offset);
                if (effective_dirty) |r| {
                    var sr: c.D3D11_RECT = .{
                        .left = @max(0, x_off_t + r.left),
                        .top = @max(0, y_off_t + r.top),
                        .right = @min(x_off_t + r.right, @as(c.LONG, @intCast(viewport_x_offset + viewport_width))),
                        .bottom = @min(y_off_t + r.bottom, @as(c.LONG, @intCast(viewport_y_offset + viewport_height))),
                    };
                    rs_set_sc(ctx, 1, &sr);
                } else {
                    var sr: c.D3D11_RECT = .{
                        .left = x_off_t,
                        .top = y_off_t,
                        .right = @intCast(viewport_x_offset + viewport_width),
                        .bottom = @intCast(viewport_y_offset + viewport_height),
                    };
                    rs_set_sc(ctx, 1, &sr);
                }
            }
        }

        // ---- Sidebar (if content_x_offset or sidebar_right_width is set) ----
        if (opts.content_x_offset != null or opts.sidebar_right_width != null) {
            if (self.sidebar_srv != null) {
                const rs_set_vp_sb = ctx_vtbl.*.RSSetViewports orelse return;
                const rs_set_sc_sb = ctx_vtbl.*.RSSetScissorRects orelse return;

                // Set full-screen viewport for sidebar drawing
                var full_vp_sb: c.D3D11_VIEWPORT = .{
                    .TopLeftX = 0,
                    .TopLeftY = 0,
                    .Width = @floatFromInt(self.width),
                    .Height = @floatFromInt(self.height),
                    .MinDepth = 0,
                    .MaxDepth = 1,
                };
                rs_set_vp_sb(ctx, 1, &full_vp_sb);

                var full_sr_sb: c.D3D11_RECT = .{
                    .left = 0,
                    .top = 0,
                    .right = @intCast(self.width),
                    .bottom = @intCast(self.height),
                };
                rs_set_sc_sb(ctx, 1, &full_sr_sb);

                const is_right = opts.sidebar_right_width != null;
                try self.drawSidebarTexture(is_right);

                // Restore content viewport
                var content_vp_sb: c.D3D11_VIEWPORT = .{
                    .TopLeftX = @floatFromInt(viewport_x_offset),
                    .TopLeftY = @floatFromInt(viewport_y_offset),
                    .Width = @floatFromInt(viewport_width),
                    .Height = @floatFromInt(viewport_height),
                    .MinDepth = 0,
                    .MaxDepth = 1,
                };
                rs_set_vp_sb(ctx, 1, &content_vp_sb);

                // Restore content scissor (absolute coords matching viewport)
                {
                    const x_off_r: c.LONG = @intCast(viewport_x_offset);
                    const y_off_r: c.LONG = @intCast(viewport_y_offset);
                    if (effective_dirty) |r| {
                        var sr_sb: c.D3D11_RECT = .{
                            .left = @max(0, x_off_r + r.left),
                            .top = @max(0, y_off_r + r.top),
                            .right = @min(x_off_r + r.right, @as(c.LONG, @intCast(viewport_x_offset + viewport_width))),
                            .bottom = @min(y_off_r + r.bottom, @as(c.LONG, @intCast(viewport_y_offset + viewport_height))),
                        };
                        rs_set_sc_sb(ctx, 1, &sr_sb);
                    } else {
                        var sr_sb: c.D3D11_RECT = .{
                            .left = x_off_r,
                            .top = y_off_r,
                            .right = @intCast(viewport_x_offset + viewport_width),
                            .bottom = @intCast(viewport_y_offset + viewport_height),
                        };
                        rs_set_sc_sb(ctx, 1, &sr_sb);
                    }
                }
            }
        }

        // ---- Ensure atlas SRV is bound before drawing main/cursor ----
        // This is a safeguard in case drawTablineTexture's restore failed or was skipped.
        {
            const ps_set_srv = ctx_vtbl.*.PSSetShaderResources orelse return;
            var srvs: [1]?*c.ID3D11ShaderResourceView = .{self.atlas_srv};
            ps_set_srv(ctx, 0, 1, @ptrCast(&srvs));
        }

        // ---- Draw in two batches ----
        try self.drawVertices(main);
        try self.drawVertices(cursor);

        // ---- Post-process bloom (neon glow) ----
        if (opts.glow_enabled and self.bloomShadersReady()) {
            self.ensureGlowTextures();
            if (self.glowTexturesComplete()) {
                self.drawBloomPasses(ctx, ctx_vtbl, main, cursor, opts.glow_intensity, viewport_x_offset, viewport_y_offset, viewport_width, viewport_height, null, null);
            }
        }

        // Custom shader pass used to live here but was moved to the
        // present paths. Calling it at THIS point (before opts.present's
        // branch below) would run the shader on a back_tex that hasn't been
        // populated yet in row-mode (rows land via drawSurfaceRowsVB after
        // drawEx returns), and also leaves the pipeline state (VS/PS/slot0
        // SRV) dirty, which breaks subsequent row drawVB calls that inherit
        // that state. drawCustomShaderPass is invoked from the present paths
        // (presentFromBackRectsWithCursorNoResize, presentOnlyFromBack,
        // the opts.present branch of drawEx itself, et al.) just before the
        // back_tex -> swapchain copy, when the full frame has landed in
        // back_tex — which non-row-mode's own opts.present branch below
        // already satisfies, since non-row content is fully written to
        // back_tex before drawEx reaches that branch.

        if (opts.present) {
            // Custom post-process shader pass: runs on the fully-rendered
            // back_tex (already populated here — unlike row-mode, where rows
            // land via drawSurfaceRowsVB after drawEx returns, this present
            // branch runs after all of this frame's content is in back_tex)
            // and writes its output directly into the current swapchain bb.
            // Skip the back->bb copy below when it handled the frame,
            // matching presentFromBackRectsWithCursorNoResize's pattern —
            // otherwise the copy would overwrite the shader's output with
            // raw terminal content.
            var shader_handled = false;
            if (self.custom_shader_pipelines.items.len > 0 and self.custom_shader_post_process == 0) {
                shader_handled = self.drawCustomShaderPass(ctx, ctx_vtbl);
            }

            // Record this canonical back_tex update for every rotating buffer,
            // but copy only the current one. Each other buffer catches up from
            // its fixed-size pending damage when it next becomes current.
            if (effective_dirty) |rect| {
                self.queueBackDamage(&.{rect}, false);
            } else {
                self.queueBackDamage(&.{}, true);
            }
            if (!shader_handled) {
                var copied_rects: [MaxPendingBackDamageRects]c.RECT = undefined;
                _ = try self.copyQueuedBackDamage(ctx, back_tex, &copied_rects);
            }

            // ---- Present ----
            {
                const sc_vtbl = sc.*.lpVtbl;
                const present = sc_vtbl.*.Present orelse return;

                const hrp: c.HRESULT = present(sc, 0, 0);
                if (c.FAILED(hrp)) {
                    if (isDeviceLost(hrp)) self.device_lost = true;
                    if (applog.isEnabled()) {
                        applog.appLog("[d3d] Present FAILED hr=0x{x}\n", .{@as(u32, @bitCast(hrp))});

                        if (self.device) |dev| {
                            const dev_vtbl = dev.*.lpVtbl;
                            if (dev_vtbl.*.GetDeviceRemovedReason) |f| {
                                const hrr = f(dev);
                                applog.appLog(
                                    "[d3d] DeviceRemovedReason hr=0x{x}\n",
                                    .{@as(u32, @bitCast(hrr))},
                                );
                            }
                        }
                    }
                } else {
                    if (applog.isEnabled()) {
                        applog.appLog("[d3d] Present ok\n", .{});
                    }
                    self.has_presented_once = true;
                }

                if (applog.isEnabled()) {
                    self.dumpInfoQueue("after Present");
                }
                if (c.FAILED(hrp)) return error.PresentFailed;
            }
        }
        if (opts.present) {
            self.advanceSwapchainIndex();
        }

        // Performance log: draw_total
        if (applog.isEnabled() and t_draw_start != 0) {
            const t_draw_end = core.clock.nowNs();
            const dur_us = @divTrunc(@max(0, t_draw_end - t_draw_start), 1000);
            applog.appLog("[perf] draw_total main={d} cursor={d} us={d}\n", .{ main.len, cursor.len, dur_us });
        }
    }

    pub fn presentOnlyFromBack(self: *Renderer, dirty_rect: ?c.RECT) !void {
        try self.resize();
        if (!self.resourcesReady()) return error.RenderResourcesUnavailable;

        const ctx = self.ctx orelse return error.NoContext;
        const sc = self.swapchain orelse return error.NoSwapchain;

        const bb_tex = self.currentBackBufferTex();
        const back_tex = self.back_tex orelse return error.NoBackTex;

        const ctx_vtbl = ctx.*.lpVtbl;

        // Custom shader pass writes directly into the current bb; skip
        // the back→bb copy when it ran so terminal content isn't pasted
        // over the shader output.
        var shader_handled_po: bool = false;
        if (self.custom_shader_pipelines.items.len > 0 and self.custom_shader_post_process == 0) {
            shader_handled_po = self.drawCustomShaderPass(ctx, ctx_vtbl);
        }

        if (shader_handled_po) {
            // shader already wrote bb
        } else if (!self.has_presented_once or dirty_rect == null) {
            const copy_res = ctx_vtbl.*.CopyResource orelse return;

            const bb_res: *c.ID3D11Resource = @ptrCast(bb_tex);
            const back_res: *c.ID3D11Resource = @ptrCast(back_tex);

            copy_res(ctx, bb_res, back_res);
        } else if (dirty_rect) |r0| {
            var dr = r0;

            if (dr.left < 0) dr.left = 0;
            if (dr.top < 0) dr.top = 0;

            const w_i32: i32 = @intCast(self.width);
            const h_i32: i32 = @intCast(self.height);

            if (dr.right > w_i32) dr.right = w_i32;
            if (dr.bottom > h_i32) dr.bottom = h_i32;

            const valid =
                (dr.left < dr.right) and (dr.top < dr.bottom) and
                (dr.left >= 0) and (dr.top >= 0) and
                (dr.right <= w_i32) and (dr.bottom <= h_i32);

            if (valid) {
                const box: c.D3D11_BOX = .{
                    .left = @intCast(dr.left),
                    .top = @intCast(dr.top),
                    .front = 0,
                    .right = @intCast(dr.right),
                    .bottom = @intCast(dr.bottom),
                    .back = 1,
                };

                const copy_sub = ctx_vtbl.*.CopySubresourceRegion orelse return;
                const bb_res: *c.ID3D11Resource = @ptrCast(bb_tex);
                const back_res: *c.ID3D11Resource = @ptrCast(back_tex);

                copy_sub(
                    ctx,
                    bb_res,
                    0,
                    @intCast(dr.left),
                    @intCast(dr.top),
                    0,
                    back_res,
                    0,
                    &box,
                );
            } else {
                const copy_res = ctx_vtbl.*.CopyResource orelse return;

                const bb_res: *c.ID3D11Resource = @ptrCast(bb_tex);
                const back_res: *c.ID3D11Resource = @ptrCast(back_tex);

                copy_res(ctx, bb_res, back_res);
            }
        }

        const sc_vtbl = sc.*.lpVtbl;
        const present = sc_vtbl.*.Present orelse return;

        // sync interval: 0 (no vsync wait)
        const hrp: c.HRESULT = present(sc, 0, 0);

        if (!c.FAILED(hrp)) {
            self.has_presented_once = true;
        } else if (isDeviceLost(hrp)) {
            self.device_lost = true;
        }
        if (c.FAILED(hrp)) return error.PresentFailed;
        self.advanceSwapchainIndex();
    }

    /// Minimal "animate-only" frame: re-run the custom shader over the
    /// existing back_tex and present. Skips the full row-mode paint
    /// (no drawEx clear, no row VB draws, no cursor/scrollbar overlay)
    /// so the 60 Hz animation ticker doesn't stall input processing on
    /// the UI thread. Safe to call only after a full paint has
    /// committed content into back_tex.
    pub fn presentShaderAnimationFrame(self: *Renderer) void {
        if (!self.has_presented_once) return; // no committed back_tex yet
        if (self.custom_shader_pipelines.items.len == 0) return;
        if (self.custom_shader_post_process != 0) return;

        const ctx = self.ctx orelse return;
        const sc = self.swapchain orelse return;
        const ctx_vtbl = ctx.*.lpVtbl;

        const handled = self.drawCustomShaderPass(ctx, ctx_vtbl);
        if (!handled) return;

        const sc_vtbl = sc.*.lpVtbl;
        const present = sc_vtbl.*.Present orelse return;
        const hrp = present(sc, 0, 0);
        if (c.FAILED(hrp)) {
            if (isDeviceLost(hrp)) self.device_lost = true;
            return;
        }
        self.advanceSwapchainIndex();
    }

    pub fn presentFromBackRectsWithCursorNoResize(
        self: *Renderer,
        rects: []const c.RECT,
        cursor_vb: ?*c.ID3D11Buffer,
        cursor_vert_count: usize,
        cursor_scissor: ?c.RECT,
        force_full_copy: bool,
        scroll_rect: ?*const c.RECT,
        scroll_offset: ?*const c.POINT,
    ) !void {
        if (!self.resourcesReady()) return error.RenderResourcesUnavailable;
        const ctx = self.ctx orelse return error.NoContext;
        const sc = self.swapchain orelse return error.NoSwapchain;

        const back_tex = self.back_tex orelse return error.NoBackTex;

        const ctx_vtbl = ctx.*.lpVtbl;
        const log_enabled = applog.isEnabled();
        var did_full_copy: bool = false;
        var t0_ns: i128 = 0;
        var t_copy_ns: i128 = 0;
        var t_cursor_ns: i128 = 0;
        if (log_enabled) {
            t0_ns = core.clock.nowNs();
        }

        const force_full_copy_effective = force_full_copy or !self.has_presented_once;

        // Custom post-process shader pass: runs on the fully-rendered
        // back_tex and writes its output directly into the current
        // swapchain bb. When it returns true, the back→bb copy below
        // must be skipped — otherwise it would overwrite the shader's
        // output with raw terminal content.
        var shader_handled: bool = false;
        if (self.custom_shader_pipelines.items.len > 0 and self.custom_shader_post_process == 0) {
            shader_handled = self.drawCustomShaderPass(ctx, ctx_vtbl);
        }

        if (force_full_copy_effective or rects.len == 0) {
            self.queueBackDamage(&.{}, true);
        } else {
            self.queueBackDamage(rects, false);
        }

        var copied_rects: [MaxPendingBackDamageRects]c.RECT = undefined;
        var copied_damage: BackCopyDamage = .{};
        if (shader_handled) {
            did_full_copy = true; // shader pass wrote the full frame to bb
        } else {
            copied_damage = try self.copyQueuedBackDamage(ctx, back_tex, &copied_rects);
            did_full_copy = copied_damage.full;
        }
        if (log_enabled) {
            t_copy_ns = core.clock.nowNs();
        }

        _ = cursor_vb;
        _ = cursor_vert_count;
        _ = cursor_scissor;
        if (log_enabled) {
            t_cursor_ns = core.clock.nowNs();
        }

        // When the custom shader pass wrote the full frame, every pixel
        // of the bb was touched — passing the old partial dirty-rect
        // list to Present1 would hint DWM that only part of the
        // backbuffer changed and could leave shader output on pixels
        // outside the dirty set stale. Treat shader-handled frames as
        // full-present (no dirty rects, no scroll hint).
        const present_full_frame = force_full_copy_effective or shader_handled or copied_damage.full;
        const present_dirty_rects = copied_rects[0..copied_damage.rect_count];

        // Validate everything Present1 will read BEFORE the call — an out-of-bounds
        // dirty rect or scroll rect/offset causes Present1 to return E_INVALIDARG,
        // which today permanently disables the swapchain1 fast path for the rest of
        // the Renderer's lifetime (see bug 2 below). On any invalid input, fall back
        // to a full-frame Present1 (no dirty rects, no scroll hint) instead of risking
        // that — the current buffer copy above is complete for all accumulated
        // damage, so a full-frame present is always safe.
        var present1_full_frame = present_full_frame;
        if (!present1_full_frame and present_dirty_rects.len != 0) {
            const w_i32: i32 = @intCast(self.width);
            const h_i32: i32 = @intCast(self.height);
            var ri: usize = 0;
            while (ri < present_dirty_rects.len) : (ri += 1) {
                const r = present_dirty_rects[ri];
                if (r.left < 0 or r.top < 0 or r.right > w_i32 or r.bottom > h_i32 or
                    r.right <= r.left or r.bottom <= r.top)
                {
                    present1_full_frame = true;
                    break;
                }
            }
        }
        if (!present1_full_frame) {
            const w_i32: i32 = @intCast(self.width);
            const h_i32: i32 = @intCast(self.height);
            if (scroll_rect) |sr| {
                var scroll_valid = sr.left >= 0 and sr.top >= 0 and
                    sr.right <= w_i32 and sr.bottom <= h_i32 and
                    sr.right > sr.left and sr.bottom > sr.top;
                if (scroll_valid) {
                    if (scroll_offset) |so| {
                        // A scroll offset shifts the whole rect; validate the
                        // shifted position stays in bounds too.
                        if (sr.left + so.x < 0 or sr.top + so.y < 0 or
                            sr.right + so.x > w_i32 or sr.bottom + so.y > h_i32)
                        {
                            scroll_valid = false;
                        }
                    } else {
                        // A scroll rect without an offset is meaningless to Present1.
                        scroll_valid = false;
                    }
                }
                if (!scroll_valid) present1_full_frame = true;
            } else if (scroll_offset != null) {
                // An offset without a rect is equally meaningless.
                present1_full_frame = true;
            }
        }

        var hrp: c.HRESULT = 0;
        if (self.swapchain1) |sc1p| {
            const sc1_vtbl = sc1p.*.lpVtbl;
            if (sc1_vtbl.*.Present1) |present1| {
                var params: c.DXGI_PRESENT_PARAMETERS = std.mem.zeroes(c.DXGI_PRESENT_PARAMETERS);
                if (!present1_full_frame and present_dirty_rects.len != 0) {
                    params.DirtyRectsCount = @intCast(present_dirty_rects.len);
                    params.pDirtyRects = @constCast(present_dirty_rects.ptr);
                }
                if (!present1_full_frame) {
                    if (scroll_rect) |sr| {
                        params.pScrollRect = @constCast(sr);
                    }
                    if (scroll_offset) |so| {
                        params.pScrollOffset = @constCast(so);
                    }
                }
                hrp = present1(sc1p, 0, 0, &params);
                if (c.FAILED(hrp)) {
                    if (isDeviceLost(hrp)) self.device_lost = true;
                    if (applog.isEnabled()) applog.appLog("[d3d] Present1 FAILED hr=0x{x}, disabling swapchain1\n", .{@as(u32, @bitCast(hrp))});
                    safeRelease(&self.swapchain1);
                }
            } else {
                const sc_vtbl = sc.*.lpVtbl;
                const present = sc_vtbl.*.Present orelse return;
                hrp = present(sc, 0, 0);
                if (c.FAILED(hrp) and isDeviceLost(hrp)) self.device_lost = true;
            }
        } else {
            const sc_vtbl = sc.*.lpVtbl;
            const present = sc_vtbl.*.Present orelse return;
            hrp = present(sc, 0, 0);
            if (c.FAILED(hrp) and isDeviceLost(hrp)) self.device_lost = true;
        }

        if (!c.FAILED(hrp)) {
            self.has_presented_once = true;
        }

        if (log_enabled and did_full_copy) {
            applog.appLog("[d3d] presentFromBackRects: full copy fallback\n", .{});
        }
        if (log_enabled) {
            const t_done_ns: i128 = core.clock.nowNs();
            const copy_us: u64 = @intCast(@divTrunc(@max(0, t_copy_ns - t0_ns), 1000));
            const cursor_us: u64 = @intCast(@divTrunc(@max(0, t_cursor_ns - t_copy_ns), 1000));
            const present_us: u64 = @intCast(@divTrunc(@max(0, t_done_ns - t_cursor_ns), 1000));
            const total_us: u64 = copy_us + cursor_us + present_us;
            applog.appLog(
                "[perf] present_detail rects={d} copy_us={d} cursor_us={d} present_us={d} total_us={d}\n",
                .{ rects.len, copy_us, cursor_us, present_us, total_us },
            );
        }
        if (c.FAILED(hrp)) return error.PresentFailed;
        self.advanceSwapchainIndex();
    }

    /// Backward-compatible single-rect draw.
    pub fn draw(self: *Renderer, main: []const core.Vertex, cursor: []const core.Vertex, dirty_rect: ?c.RECT) !void {
        try self.drawEx(main, cursor, dirty_rect, .{});
    }

    /// Update tabline texture from BGRA pixel data (rendered by GDI offscreen).
    /// This allows tabline to be composited via D3D11, avoiding DWM GDI/D3D mixing issues.
    pub fn updateTablineTexture(self: *Renderer, width: u32, height: u32, pixels: []const u8) !void {
        if (width == 0 or height == 0) return;

        const device = self.device orelse return error.NoDevice;
        const ctx = self.ctx orelse return error.NoContext;

        // Recreate texture if size changed
        if (self.tabline_tex == null or self.tabline_width != width or self.tabline_height != height) {
            // The old resources are released only once both creates below have
            // succeeded — publish-after-create, as the vertex buffers already
            // do. Releasing first left the tabline blank for every frame after
            // a transient allocation failure (the post-TDR window in
            // particular), until an unrelated size change happened to succeed.

            // Create new texture
            var tex_desc: c.D3D11_TEXTURE2D_DESC = std.mem.zeroes(c.D3D11_TEXTURE2D_DESC);
            tex_desc.Width = width;
            tex_desc.Height = height;
            tex_desc.MipLevels = 1;
            tex_desc.ArraySize = 1;
            tex_desc.Format = c.DXGI_FORMAT_B8G8R8A8_UNORM;
            tex_desc.SampleDesc.Count = 1;
            tex_desc.SampleDesc.Quality = 0;
            tex_desc.Usage = c.D3D11_USAGE_DEFAULT;
            tex_desc.BindFlags = c.D3D11_BIND_SHADER_RESOURCE;
            tex_desc.CPUAccessFlags = 0;
            tex_desc.MiscFlags = 0;

            const vtbl = device.*.lpVtbl;
            const create_tex = vtbl.*.CreateTexture2D orelse return error.NoCreateTexture2D;

            var init_data: c.D3D11_SUBRESOURCE_DATA = std.mem.zeroes(c.D3D11_SUBRESOURCE_DATA);
            init_data.pSysMem = pixels.ptr;
            init_data.SysMemPitch = width * 4;

            var tex: ?*c.ID3D11Texture2D = null;
            var hr = create_tex(device, &tex_desc, &init_data, &tex);
            if (c.FAILED(hr) or tex == null) {
                if (applog.isEnabled()) applog.appLog("[d3d] updateTablineTexture: CreateTexture2D failed hr=0x{x}\n", .{@as(u32, @bitCast(hr))});
                return error.CreateTexture2DFailed;
            }

            // Create SRV
            var srv_desc: c.D3D11_SHADER_RESOURCE_VIEW_DESC = std.mem.zeroes(c.D3D11_SHADER_RESOURCE_VIEW_DESC);
            srv_desc.Format = c.DXGI_FORMAT_B8G8R8A8_UNORM;
            srv_desc.ViewDimension = c.D3D11_SRV_DIMENSION_TEXTURE2D;
            srv_desc.unnamed_0.Texture2D.MostDetailedMip = 0;
            srv_desc.unnamed_0.Texture2D.MipLevels = 1;

            const create_srv = vtbl.*.CreateShaderResourceView orelse {
                safeRelease(&tex);
                return error.NoCreateSRV;
            };

            var srv: ?*c.ID3D11ShaderResourceView = null;
            hr = create_srv(device, @ptrCast(tex), &srv_desc, &srv);
            if (c.FAILED(hr) or srv == null) {
                if (applog.isEnabled()) applog.appLog("[d3d] updateTablineTexture: CreateShaderResourceView failed hr=0x{x}\n", .{@as(u32, @bitCast(hr))});
                safeRelease(&tex);
                return error.CreateSRVFailed;
            }

            safeRelease(&self.tabline_srv);
            safeRelease(&self.tabline_tex);
            self.tabline_tex = tex;
            self.tabline_srv = srv;
            self.tabline_width = width;
            self.tabline_height = height;

            if (applog.isEnabled()) applog.appLog("[d3d] updateTablineTexture: created texture {d}x{d}\n", .{ width, height });
        } else {
            // Update existing texture
            const tex = self.tabline_tex orelse return;
            const ctx_vtbl = ctx.*.lpVtbl;
            const update_subres = ctx_vtbl.*.UpdateSubresource orelse return error.NoUpdateSubresource;

            // Defensive unbind: tabline_srv may still be bound at PS slot 0
            // from a prior drawTablineTexture call within the same frame.
            // UpdateSubresource on a texture that's an active SRV is an
            // undefined-per-spec hazard (theoretical — see LOW-6).
            if (ctx_vtbl.*.PSSetShaderResources) |ps_set_srv| {
                var null_srvs: [1]?*c.ID3D11ShaderResourceView = .{null};
                ps_set_srv(ctx, 0, 1, @ptrCast(&null_srvs));
            }

            var box: c.D3D11_BOX = .{
                .left = 0,
                .top = 0,
                .front = 0,
                .right = width,
                .bottom = height,
                .back = 1,
            };

            update_subres(ctx, @ptrCast(tex), 0, &box, pixels.ptr, width * 4, 0);
        }
    }

    /// Draw tabline texture as a full-width quad at the top of the window.
    /// Call this after clearing but before drawing main content.
    pub fn drawTablineTexture(self: *Renderer) !void {
        // Frontend-authored vertices are already in clip space.
        self.setLayerTransform(0, 0, 0, 0);
        const srv = self.tabline_srv orelse return;
        const ctx = self.ctx orelse return error.NoContext;
        const width = self.tabline_width;
        const height = self.tabline_height;

        if (width == 0 or height == 0 or self.width == 0 or self.height == 0) return;

        // Convert pixel coordinates to NDC (-1 to 1)
        // Top-left is (-1, 1), bottom-right is (1, -1) in NDC
        const ndc_left: f32 = -1.0;
        const ndc_right: f32 = 1.0;
        const ndc_top: f32 = 1.0;
        // Bottom of tabline in NDC: 1.0 - 2.0 * (height / window_height)
        const ndc_bottom: f32 = 1.0 - 2.0 * (@as(f32, @floatFromInt(height)) / @as(f32, @floatFromInt(self.height)));

        // Special UV format for tabline texture sampling:
        // uv.x = -5.0 (TABLINE_TEXTURE marker)
        // uv.y = actual U coordinate (0-1)
        // deco_phase = actual V coordinate (0-1)
        const uv_marker: f32 = -5.0;

        // White color (texture provides actual colors)
        const color: [4]f32 = .{ 1, 1, 1, 1 };

        // Two triangles (6 vertices) in NDC coordinates
        // UV coords: (marker, U) with V in deco_phase
        const verts: [6]core.Vertex = .{
            // Triangle 1: top-left, top-right, bottom-left
            .{ .position = .{ ndc_left, ndc_top }, .texCoord = .{ uv_marker, 0 }, .color = color, .grid_id = 0, .deco_flags = 0, .deco_phase = 0 },
            .{ .position = .{ ndc_right, ndc_top }, .texCoord = .{ uv_marker, 1 }, .color = color, .grid_id = 0, .deco_flags = 0, .deco_phase = 0 },
            .{ .position = .{ ndc_left, ndc_bottom }, .texCoord = .{ uv_marker, 0 }, .color = color, .grid_id = 0, .deco_flags = 0, .deco_phase = 1 },
            // Triangle 2: top-right, bottom-right, bottom-left
            .{ .position = .{ ndc_right, ndc_top }, .texCoord = .{ uv_marker, 1 }, .color = color, .grid_id = 0, .deco_flags = 0, .deco_phase = 0 },
            .{ .position = .{ ndc_right, ndc_bottom }, .texCoord = .{ uv_marker, 1 }, .color = color, .grid_id = 0, .deco_flags = 0, .deco_phase = 1 },
            .{ .position = .{ ndc_left, ndc_bottom }, .texCoord = .{ uv_marker, 0 }, .color = color, .grid_id = 0, .deco_flags = 0, .deco_phase = 1 },
        };

        // Save current atlas SRV
        const ctx_vtbl = ctx.*.lpVtbl;

        // Bind tabline texture
        const ps_set_srv = ctx_vtbl.*.PSSetShaderResources orelse return error.NoPSSetSRV;
        var srvs: [1]?*c.ID3D11ShaderResourceView = .{srv};
        ps_set_srv(ctx, 0, 1, @ptrCast(&srvs));

        // Draw the quad
        try self.drawVertices(&verts);

        // Restore atlas texture
        srvs[0] = self.atlas_srv;
        ps_set_srv(ctx, 0, 1, @ptrCast(&srvs));
    }

    /// Update sidebar texture from BGRA pixel data (rendered by GDI offscreen).
    pub fn updateSidebarTexture(self: *Renderer, width: u32, height: u32, pixels: []const u8) !void {
        if (width == 0 or height == 0) return;

        const device = self.device orelse return error.NoDevice;
        const ctx = self.ctx orelse return error.NoContext;

        if (self.sidebar_tex == null or self.sidebar_width_tex != width or self.sidebar_height_tex != height) {
            // Publish-after-create: see updateTablineTexture.
            var tex_desc: c.D3D11_TEXTURE2D_DESC = std.mem.zeroes(c.D3D11_TEXTURE2D_DESC);
            tex_desc.Width = width;
            tex_desc.Height = height;
            tex_desc.MipLevels = 1;
            tex_desc.ArraySize = 1;
            tex_desc.Format = c.DXGI_FORMAT_B8G8R8A8_UNORM;
            tex_desc.SampleDesc.Count = 1;
            tex_desc.SampleDesc.Quality = 0;
            tex_desc.Usage = c.D3D11_USAGE_DEFAULT;
            tex_desc.BindFlags = c.D3D11_BIND_SHADER_RESOURCE;
            tex_desc.CPUAccessFlags = 0;
            tex_desc.MiscFlags = 0;

            const vtbl = device.*.lpVtbl;
            const create_tex = vtbl.*.CreateTexture2D orelse return error.NoCreateTexture2D;

            var init_data: c.D3D11_SUBRESOURCE_DATA = std.mem.zeroes(c.D3D11_SUBRESOURCE_DATA);
            init_data.pSysMem = pixels.ptr;
            init_data.SysMemPitch = width * 4;

            var tex: ?*c.ID3D11Texture2D = null;
            var hr = create_tex(device, &tex_desc, &init_data, &tex);
            if (c.FAILED(hr) or tex == null) {
                if (applog.isEnabled()) applog.appLog("[d3d] updateSidebarTexture: CreateTexture2D failed hr=0x{x}\n", .{@as(u32, @bitCast(hr))});
                return error.CreateTexture2DFailed;
            }

            var srv_desc: c.D3D11_SHADER_RESOURCE_VIEW_DESC = std.mem.zeroes(c.D3D11_SHADER_RESOURCE_VIEW_DESC);
            srv_desc.Format = c.DXGI_FORMAT_B8G8R8A8_UNORM;
            srv_desc.ViewDimension = c.D3D11_SRV_DIMENSION_TEXTURE2D;
            srv_desc.unnamed_0.Texture2D.MostDetailedMip = 0;
            srv_desc.unnamed_0.Texture2D.MipLevels = 1;

            const create_srv = vtbl.*.CreateShaderResourceView orelse {
                safeRelease(&tex);
                return error.NoCreateSRV;
            };

            var srv: ?*c.ID3D11ShaderResourceView = null;
            hr = create_srv(device, @ptrCast(tex), &srv_desc, &srv);
            if (c.FAILED(hr) or srv == null) {
                if (applog.isEnabled()) applog.appLog("[d3d] updateSidebarTexture: CreateShaderResourceView failed hr=0x{x}\n", .{@as(u32, @bitCast(hr))});
                safeRelease(&tex);
                return error.CreateSRVFailed;
            }

            safeRelease(&self.sidebar_srv);
            safeRelease(&self.sidebar_tex);
            self.sidebar_tex = tex;
            self.sidebar_srv = srv;
            self.sidebar_width_tex = width;
            self.sidebar_height_tex = height;

            if (applog.isEnabled()) applog.appLog("[d3d] updateSidebarTexture: created texture {d}x{d}\n", .{ width, height });
        } else {
            const tex = self.sidebar_tex orelse return;
            const ctx_vtbl = ctx.*.lpVtbl;
            const update_subres = ctx_vtbl.*.UpdateSubresource orelse return error.NoUpdateSubresource;

            // Defensive unbind: sidebar_srv may still be bound at PS slot 0
            // from a prior drawSidebarTexture call within the same frame.
            // UpdateSubresource on a texture that's an active SRV is an
            // undefined-per-spec hazard (theoretical — see LOW-6).
            if (ctx_vtbl.*.PSSetShaderResources) |ps_set_srv| {
                var null_srvs: [1]?*c.ID3D11ShaderResourceView = .{null};
                ps_set_srv(ctx, 0, 1, @ptrCast(&null_srvs));
            }

            var box: c.D3D11_BOX = .{
                .left = 0,
                .top = 0,
                .front = 0,
                .right = width,
                .bottom = height,
                .back = 1,
            };

            update_subres(ctx, @ptrCast(tex), 0, &box, pixels.ptr, width * 4, 0);
        }
    }

    /// Draw sidebar texture as a vertical strip at left or right of window.
    pub fn drawSidebarTexture(self: *Renderer, is_right: bool) !void {
        // Frontend-authored vertices are already in clip space.
        self.setLayerTransform(0, 0, 0, 0);
        const srv = self.sidebar_srv orelse return;
        const ctx = self.ctx orelse return error.NoContext;
        const sb_width = self.sidebar_width_tex;
        const sb_height = self.sidebar_height_tex;

        if (sb_width == 0 or sb_height == 0 or self.width == 0 or self.height == 0) return;

        // NDC coordinates for sidebar strip
        const w_ratio: f32 = 2.0 * @as(f32, @floatFromInt(sb_width)) / @as(f32, @floatFromInt(self.width));
        var ndc_left: f32 = undefined;
        var ndc_right: f32 = undefined;
        if (is_right) {
            ndc_right = 1.0;
            ndc_left = 1.0 - w_ratio;
        } else {
            ndc_left = -1.0;
            ndc_right = -1.0 + w_ratio;
        }
        const ndc_top: f32 = 1.0;
        const ndc_bottom: f32 = -1.0;

        const uv_marker: f32 = -5.0;
        const color: [4]f32 = .{ 1, 1, 1, 1 };

        const verts: [6]core.Vertex = .{
            .{ .position = .{ ndc_left, ndc_top }, .texCoord = .{ uv_marker, 0 }, .color = color, .grid_id = 0, .deco_flags = 0, .deco_phase = 0 },
            .{ .position = .{ ndc_right, ndc_top }, .texCoord = .{ uv_marker, 1 }, .color = color, .grid_id = 0, .deco_flags = 0, .deco_phase = 0 },
            .{ .position = .{ ndc_left, ndc_bottom }, .texCoord = .{ uv_marker, 0 }, .color = color, .grid_id = 0, .deco_flags = 0, .deco_phase = 1 },
            .{ .position = .{ ndc_right, ndc_top }, .texCoord = .{ uv_marker, 1 }, .color = color, .grid_id = 0, .deco_flags = 0, .deco_phase = 0 },
            .{ .position = .{ ndc_right, ndc_bottom }, .texCoord = .{ uv_marker, 1 }, .color = color, .grid_id = 0, .deco_flags = 0, .deco_phase = 1 },
            .{ .position = .{ ndc_left, ndc_bottom }, .texCoord = .{ uv_marker, 0 }, .color = color, .grid_id = 0, .deco_flags = 0, .deco_phase = 1 },
        };

        const ctx_vtbl = ctx.*.lpVtbl;
        const ps_set_srv = ctx_vtbl.*.PSSetShaderResources orelse return error.NoPSSetSRV;
        var srvs: [1]?*c.ID3D11ShaderResourceView = .{srv};
        ps_set_srv(ctx, 0, 1, @ptrCast(&srvs));

        try self.drawVertices(&verts);

        srvs[0] = self.atlas_srv;
        ps_set_srv(ctx, 0, 1, @ptrCast(&srvs));
    }

    fn dumpInfoQueue(self: *Renderer, tag: []const u8) void {
        const q = self.infoq orelse return;

        const vtbl = q.*.lpVtbl;
        const VtblT = @TypeOf(vtbl.*);

        // required methods
        const get_num = if (@hasField(VtblT, "GetNumStoredMessagesAllowedByRetrievalFilter"))
            @field(vtbl.*, "GetNumStoredMessagesAllowedByRetrievalFilter") orelse return
        else
            return;

        const clear = if (@hasField(VtblT, "ClearStoredMessages"))
            @field(vtbl.*, "ClearStoredMessages") orelse return
        else
            return;

        // optional: GetMessage is missing on some mingw headers
        const get_msg_opt = if (@hasField(VtblT, "GetMessage"))
            @field(vtbl.*, "GetMessage")
        else
            null;

        if (get_msg_opt == null or get_msg_opt.? == null) {
            const n: u64 = get_num(q);
            if (n != 0) {
                if (applog.isEnabled()) {
                    applog.appLog(
                        "[d3d][infoq] {s}: {d} message(s) but GetMessage is not available in this header/toolchain; cannot dump details.\n",
                        .{ tag, n },
                    );
                }
                clear(q);
            }
            return;
        }

        const get_msg = get_msg_opt.?;

        const n: u64 = get_num(q);
        if (n == 0) return;

        if (applog.isEnabled()) applog.appLog("[d3d][infoq] {s}: {d} message(s)\n", .{ tag, n });

        var i: u64 = 0;
        while (i < n) : (i += 1) {
            var len: usize = 0;
            _ = get_msg(q, i, null, &len);
            if (len == 0) continue;

            var tmp_buf: [2048]u8 = undefined;
            if (len > tmp_buf.len) {
                if (applog.isEnabled()) applog.appLog("[d3d][infoq]   msg[{d}] too large (len={d})\n", .{ i, len });
                continue;
            }

            const msg: *c.D3D11_MESSAGE = @ptrCast(@alignCast(&tmp_buf));
            const hr = get_msg(q, i, msg, &len);
            if (c.FAILED(hr)) {
                if (applog.isEnabled()) applog.appLog("[d3d][infoq]   msg[{d}] GetMessage failed hr=0x{x}\n", .{ i, @as(u32, @bitCast(hr)) });
                continue;
            }

            const desc_ptr: [*:0]const u8 = @ptrCast(msg.pDescription);
            // NOTE: Some toolchains don't have Severity as enum, so output as u32
            if (applog.isEnabled()) {
                applog.appLog(
                    "[d3d][infoq]   {d}: sev={d} id={d} {s}\n",
                    .{ i, @as(u32, @bitCast(msg.Severity)), msg.ID, desc_ptr },
                );
            }
        }

        clear(q);
    }

    fn mapDiscard(ctx: *c.ID3D11DeviceContext, res: *c.ID3D11Resource, mapped: *c.D3D11_MAPPED_SUBRESOURCE) c.HRESULT {
        const vtbl = ctx.*.lpVtbl;
        const MapFn = vtbl.*.Map orelse return @as(c.HRESULT, @bitCast(@as(c_long, -1)));
        return MapFn(ctx, res, 0, c.D3D11_MAP_WRITE_DISCARD, 0, mapped);
    }

    fn unmap0(ctx: *c.ID3D11DeviceContext, res: *c.ID3D11Resource) void {
        const vtbl = ctx.*.lpVtbl;
        const UnmapFn = vtbl.*.Unmap orelse return;
        UnmapFn(ctx, res, 0);
    }

    fn drawVertices(self: *Renderer, verts: []const core.Vertex) !void {
        if (verts.len == 0) return;

        if (applog.isEnabled() and verts.len != 0) {
            const v0 = verts[0];
            applog.appLog(
                "[d3d] drawVertices n={d} v0 pos=({d:.3},{d:.3}) uv=({d:.3},{d:.3}) col=({d:.2},{d:.2},{d:.2},{d:.2})\n",
                .{
                    verts.len,
                    v0.position[0],
                    v0.position[1],
                    v0.texCoord[0],
                    v0.texCoord[1],
                    v0.color[0],
                    v0.color[1],
                    v0.color[2],
                    v0.color[3],
                },
            );
        }

        const ctx = self.ctx orelse return error.NoContext;

        const bytes: usize = verts.len * @sizeOf(core.Vertex);

        // ensureVertexBuffer() may recreate VB, so always re-fetch VB pointer after ensure
        try self.ensureVertexBuffer(bytes);

        const vb = self.vb orelse return error.NoVB;

        var mapped: c.D3D11_MAPPED_SUBRESOURCE = undefined;

        // ID3D11Buffer inherits ID3D11Resource, so cast to Resource
        const res: *c.ID3D11Resource = @ptrCast(vb);

        // Performance: VB upload timing
        var t_vb_start: i128 = 0;
        if (applog.isEnabled()) t_vb_start = core.clock.nowNs();

        const hr = mapDiscard(ctx, res, &mapped);
        if (c.FAILED(hr)) return error.D3DMapFailed;

        const dst_ptr: [*]u8 = @ptrCast(mapped.pData);
        const dst: []u8 = dst_ptr[0..bytes];

        const src: []const u8 = std.mem.sliceAsBytes(verts);

        // Copy vertex data to VB (without this, nothing renders)
        std.mem.copyForwards(u8, dst, src);

        // D3D11: Unmap before issuing Draw
        unmap0(ctx, res);

        // Performance log: VB upload
        if (applog.isEnabled() and t_vb_start != 0) {
            const t_vb_end = core.clock.nowNs();
            const vb_us = @divTrunc(@max(0, t_vb_end - t_vb_start), 1000);
            applog.appLog("[perf] draw_vb_upload bytes={d} us={d}\n", .{ bytes, vb_us });
        }

        // ---- Bind VB + issue draw ----
        const ctx_vtbl = ctx.*.lpVtbl;

        // IA: vertex buffer
        const ia_set_vb = ctx_vtbl.*.IASetVertexBuffers orelse return error.D3DIASetVertexBuffersMissing;
        var stride: c.UINT = @sizeOf(core.Vertex);
        var offset: c.UINT = 0;

        var vbs: [1]?*c.ID3D11Buffer = .{vb};
        const pp_vbs: [*c]?*c.ID3D11Buffer = @ptrCast(&vbs);
        ia_set_vb(ctx, 0, 1, pp_vbs, &stride, &offset);

        // IA: topology
        const ia_set_top = ctx_vtbl.*.IASetPrimitiveTopology orelse return error.D3DIASetTopologyMissing;
        ia_set_top(ctx, c.D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);

        // Performance: Draw call timing
        var t_draw_start: i128 = 0;
        if (applog.isEnabled()) t_draw_start = core.clock.nowNs();

        // Draw
        const draw_fn = ctx_vtbl.*.Draw orelse return error.D3DDrawMissing;
        draw_fn(ctx, @intCast(verts.len), 0);

        // Performance log: Draw call
        if (applog.isEnabled() and t_draw_start != 0) {
            const t_draw_end = core.clock.nowNs();
            const draw_us = @divTrunc(@max(0, t_draw_end - t_draw_start), 1000);
            applog.appLog("[perf] draw_call verts={d} us={d}\n", .{ verts.len, draw_us });
        }
    }

    pub fn ensureExternalVertexBuffer(
        self: *Renderer,
        vb_ptr: *?*c.ID3D11Buffer,
        vb_bytes_ptr: *usize,
        need_bytes: usize,
    ) !void {
        if (need_bytes == 0) return;

        // If existing is enough, reuse
        if (vb_ptr.* != null and vb_bytes_ptr.* >= need_bytes) return;

        const current_bytes = if (vb_ptr.* != null) vb_bytes_ptr.* else 0;
        const new_bytes = plannedExternalVertexBufferCapacity(
            current_bytes,
            need_bytes,
        ) orelse return error.VertexBufferTooLarge;
        try self.replaceExternalVertexBuffer(vb_ptr, vb_bytes_ptr, new_bytes);
    }

    pub fn plannedExternalVertexBufferCapacity(current_bytes: usize, need_bytes: usize) ?usize {
        // Must match MAX_VERTEX_BYTES_PER_CALLBACK in src/core/flush.zig. The
        // core rejects an oversized row itself (a deliberate, accounted
        // failure); if this ceiling is lower, the core instead hands us a
        // payload we cannot allocate and the row fails as a D3D error on every
        // retry. Growth is geometric to avoid a CreateBuffer/Release pair for
        // every small high-water bump.
        const max_buffer_bytes: usize = 256 * 1024 * 1024;
        return render_pipeline_helpers.geometricBufferCapacity(
            current_bytes,
            need_bytes,
            max_buffer_bytes,
        );
    }

    pub fn replaceExternalVertexBuffer(
        self: *Renderer,
        vb_ptr: *?*c.ID3D11Buffer,
        vb_bytes_ptr: *usize,
        new_bytes: usize,
    ) !void {
        if (new_bytes == 0 or new_bytes > 256 * 1024 * 1024) {
            return error.VertexBufferTooLarge;
        }
        const dev = self.device orelse return error.NoDevice;

        var desc: c.D3D11_BUFFER_DESC = std.mem.zeroes(c.D3D11_BUFFER_DESC);
        desc.ByteWidth = @intCast(new_bytes);
        desc.Usage = c.D3D11_USAGE_DYNAMIC;
        desc.BindFlags = c.D3D11_BIND_VERTEX_BUFFER;
        desc.CPUAccessFlags = c.D3D11_CPU_ACCESS_WRITE;

        var buf: ?*c.ID3D11Buffer = null;
        const vtbl = dev.*.lpVtbl;
        const create = vtbl.*.CreateBuffer orelse return error.D3DCreateBufferMissing;

        const hr = create(dev, &desc, null, @ptrCast(&buf));
        if (c.FAILED(hr) or buf == null) {
            if (isDeviceLost(hr)) self.device_lost = true;
            return error.D3DCreateBufferFailed;
        }

        // Publish only after creation succeeds. A transient allocation failure
        // therefore preserves the old VB and its capacity for the full-paint
        // retry path.
        safeRelease(vb_ptr);
        vb_ptr.* = buf;
        vb_bytes_ptr.* = new_bytes;
    }

    pub fn uploadVertsToVB(
        self: *Renderer,
        vb: *c.ID3D11Buffer,
        verts: []const core.Vertex,
    ) !void {
        if (verts.len == 0) return;

        const ctx = self.ctx orelse return error.NoContext;
        const bytes: usize = verts.len * @sizeOf(core.Vertex);

        var mapped: c.D3D11_MAPPED_SUBRESOURCE = undefined;
        const res: *c.ID3D11Resource = @ptrCast(vb);

        const hr = mapDiscard(ctx, res, &mapped);
        if (c.FAILED(hr)) {
            if (isDeviceLost(hr)) self.device_lost = true;
            return error.D3DMapFailed;
        }

        const dst_ptr: [*]u8 = @ptrCast(mapped.pData);
        const dst: []u8 = dst_ptr[0..bytes];
        const src: []const u8 = std.mem.sliceAsBytes(verts);
        std.mem.copyForwards(u8, dst, src);

        unmap0(ctx, res);
    }

    pub fn drawVB(self: *Renderer, vb: *c.ID3D11Buffer, vert_count: usize) !void {
        if (vert_count == 0) return;

        const ctx = self.ctx orelse return error.NoContext;
        const ctx_vtbl = ctx.*.lpVtbl;

        const ia_set_vb = ctx_vtbl.*.IASetVertexBuffers orelse return error.D3DIASetVertexBuffersMissing;

        var stride: c.UINT = @sizeOf(core.Vertex);
        var offset: c.UINT = 0;
        var vbs: [1]?*c.ID3D11Buffer = .{vb};
        const pp_vbs: [*c]?*c.ID3D11Buffer = @ptrCast(&vbs);
        ia_set_vb(ctx, 0, 1, pp_vbs, &stride, &offset);

        const ia_set_top = ctx_vtbl.*.IASetPrimitiveTopology orelse return error.D3DIASetTopologyMissing;
        ia_set_top(ctx, c.D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);

        const draw_fn = ctx_vtbl.*.Draw orelse return error.D3DDrawMissing;
        draw_fn(ctx, @intCast(vert_count), 0);
    }

    /// Draw a fullscreen bg-fill quad clipped by the current scissor rect.
    /// Used for rows with vert_count==0 ("clear row" per core contract).
    /// Lazily creates and caches a 6-vertex VB with the default bg color.
    pub fn drawClearRow(self: *Renderer) !void {
        // Frontend-authored vertices are already in clip space.
        self.setLayerTransform(0, 0, 0, 0);
        const bg_rgb = self.default_bg_rgb.load(.acquire);
        const need_rebuild = (self.clear_row_vb == null or bg_rgb != self.clear_row_vb_bg);

        if (need_rebuild) {
            // Straight-alpha (non-premultiplied) bg color.
            // Pixel shader applies premultiply(i.col) for UV==(-1,-1) vertices.
            var r_f: f32 = 0;
            var g_f: f32 = 0;
            var b_f: f32 = 0;
            if (bg_rgb != 0xFFFFFFFF) {
                r_f = @as(f32, @floatFromInt((bg_rgb >> 16) & 0xFF)) / 255.0;
                g_f = @as(f32, @floatFromInt((bg_rgb >> 8) & 0xFF)) / 255.0;
                b_f = @as(f32, @floatFromInt(bg_rgb & 0xFF)) / 255.0;
            }
            const col = [4]f32{ r_f, g_f, b_f, self.opacity };
            const verts = [6]core.Vertex{
                .{ .position = .{ -1.0, -1.0 }, .texCoord = .{ -1.0, -1.0 }, .color = col, .grid_id = 1, .deco_flags = 0, .deco_phase = 0 },
                .{ .position = .{ 1.0, -1.0 }, .texCoord = .{ -1.0, -1.0 }, .color = col, .grid_id = 1, .deco_flags = 0, .deco_phase = 0 },
                .{ .position = .{ -1.0, 1.0 }, .texCoord = .{ -1.0, -1.0 }, .color = col, .grid_id = 1, .deco_flags = 0, .deco_phase = 0 },
                .{ .position = .{ -1.0, 1.0 }, .texCoord = .{ -1.0, -1.0 }, .color = col, .grid_id = 1, .deco_flags = 0, .deco_phase = 0 },
                .{ .position = .{ 1.0, -1.0 }, .texCoord = .{ -1.0, -1.0 }, .color = col, .grid_id = 1, .deco_flags = 0, .deco_phase = 0 },
                .{ .position = .{ 1.0, 1.0 }, .texCoord = .{ -1.0, -1.0 }, .color = col, .grid_id = 1, .deco_flags = 0, .deco_phase = 0 },
            };
            if (self.clear_row_vb == null) {
                var dummy_bytes: usize = 0;
                try self.ensureExternalVertexBuffer(&self.clear_row_vb, &dummy_bytes, 6 * @sizeOf(core.Vertex));
            }
            try self.uploadVertsToVB(self.clear_row_vb.?, &verts);
            self.clear_row_vb_bg = bg_rgb;
        }
        try self.drawVB(self.clear_row_vb.?, 6);
    }

    /// drawClearRow with blending OFF: the scissored band becomes exactly
    /// (bg * opacity, opacity) instead of that blended over whatever the row
    /// held before. On a translucent surface every redraw of a row would
    /// otherwise compound its alpha toward opaque (0.5 -> 0.75 -> 0.875 ...),
    /// which is what a layer redrawn every paint did — and a glyph that
    /// vanished (a closed split's separator) would keep showing through.
    pub fn drawClearRowOverwrite(self: *Renderer) !void {
        const ctx = self.ctx orelse return error.NoContext;
        const ctx_vtbl = ctx.*.lpVtbl;
        const set_blend = ctx_vtbl.*.OMSetBlendState orelse return error.D3DBlendMissing;
        var blend_factor: [4]f32 = .{ 0, 0, 0, 0 };
        set_blend(ctx, null, &blend_factor, 0xFFFFFFFF);
        defer if (self.blend) |bl| set_blend(ctx, bl, &blend_factor, 0xFFFFFFFF);
        try self.drawClearRow();
    }

    /// Set viewport and scissor to full window size.
    /// Use this before drawing overlay elements (e.g., scrollbar in "always" mode).
    pub fn setFullViewport(self: *Renderer) void {
        const ctx = self.ctx orelse return;
        const ctx_vtbl = ctx.*.lpVtbl;

        // Viewport
        var vp: c.D3D11_VIEWPORT = .{
            .TopLeftX = 0,
            .TopLeftY = 0,
            .Width = @floatFromInt(self.width),
            .Height = @floatFromInt(self.height),
            .MinDepth = 0,
            .MaxDepth = 1,
        };
        if (ctx_vtbl.*.RSSetViewports) |f| f(ctx, 1, &vp);

        // Scissor
        var sr: c.D3D11_RECT = .{
            .left = 0,
            .top = 0,
            .right = @intCast(self.width),
            .bottom = @intCast(self.height),
        };
        if (ctx_vtbl.*.RSSetScissorRects) |f| f(ctx, 1, &sr);
    }

    /// Build a complete DirectComposition graph and publish it only after every
    /// HRESULT succeeds. The HWNDs use WS_EX_NOREDIRECTIONBITMAP, so accepting a
    /// composition swapchain without a committed visual would create a
    /// permanently blank renderer that otherwise looks initialized.
    fn createDirectComposition(self: *Renderer, sc1: *c.IDXGISwapChain1, dxgi_dev: *c.IDXGIDevice) !void {
        var dcomp_dev: ?*IDCompositionDevice = null;
        errdefer safeRelease(&dcomp_dev);
        const dcomp_hr = DCompositionCreateDevice(dxgi_dev, &IID_IDCompositionDevice, &dcomp_dev);
        if (c.FAILED(dcomp_hr) or dcomp_dev == null) return error.DCompositionCreateDeviceFailed;

        const vtbl = dcomp_dev.?.lpVtbl;
        var dcomp_target: ?*IDCompositionTarget = null;
        errdefer safeRelease(&dcomp_target);
        const target_hr = vtbl.CreateTargetForHwnd(dcomp_dev.?, self.hwnd, c.TRUE, &dcomp_target);
        if (c.FAILED(target_hr) or dcomp_target == null) return error.DCompositionCreateTargetFailed;

        var dcomp_visual: ?*IDCompositionVisual = null;
        errdefer safeRelease(&dcomp_visual);
        const visual_hr = vtbl.CreateVisual(dcomp_dev.?, &dcomp_visual);
        if (c.FAILED(visual_hr) or dcomp_visual == null) return error.DCompositionCreateVisualFailed;

        const sc_unk: *c.IUnknown = @ptrCast(sc1);
        const content_hr = dcomp_visual.?.lpVtbl.SetContent(dcomp_visual.?, sc_unk);
        if (c.FAILED(content_hr)) return error.DCompositionSetContentFailed;
        const root_hr = dcomp_target.?.lpVtbl.SetRoot(dcomp_target.?, dcomp_visual);
        if (c.FAILED(root_hr)) return error.DCompositionSetRootFailed;
        const commit_hr = vtbl.Commit(dcomp_dev.?);
        if (c.FAILED(commit_hr)) return error.DCompositionCommitFailed;

        self.dcomp_device = dcomp_dev;
        self.dcomp_target = dcomp_target;
        self.dcomp_visual = dcomp_visual;
        dcomp_dev = null;
        dcomp_target = null;
        dcomp_visual = null;
    }

    /// Create the flip-model composition swapchain for `dev` at the
    /// renderer's current size, bind it to a DirectComposition visual, and
    /// publish it on self along with the derived IDXGISwapChain3.
    ///
    /// Every Zonvie HWND carries WS_EX_NOREDIRECTIONBITMAP, so composition is
    /// the only path that can produce a visible renderer -- there is no legacy
    /// HWND fallback, and a failure here fails initialization. The DXGI
    /// device, adapter and factory are transient and released before return;
    /// on failure nothing is left owned.
    ///
    /// Caller keeps the device: createSwapchainOnly reuses one self already
    /// holds, createDeviceAndSwapchain transfers a freshly created one after
    /// this returns.
    fn createCompositionSwapchain(self: *Renderer, dev: *c.ID3D11Device) !void {
        var hr: c.HRESULT = 0;
        var sc1: ?*c.IDXGISwapChain1 = null;
        var sc0: ?*c.IDXGISwapChain = null;
        errdefer safeRelease(&sc1);
        errdefer safeRelease(&sc0);
        var sc1_buf_count: u32 = 3;
        var dxgi_dev: ?*c.IDXGIDevice = null;
        var adapter: ?*c.IDXGIAdapter = null;
        var factory2: ?*c.IDXGIFactory2 = null;
        defer safeRelease(&dxgi_dev);
        defer safeRelease(&adapter);
        defer safeRelease(&factory2);

        const dev_unk: *c.IUnknown = @ptrCast(dev);
        const dev_vtbl = dev_unk.*.lpVtbl;
        const qi = dev_vtbl.*.QueryInterface orelse return error.D3DCreateFailed;

        if (!c.FAILED(qi(dev_unk, &c.IID_IDXGIDevice, @ptrCast(&dxgi_dev))) and dxgi_dev != null) {
            const dxgi_vtbl = dxgi_dev.?.lpVtbl;
            if (dxgi_vtbl.*.GetAdapter) |get_adapter| {
                if (!c.FAILED(get_adapter(dxgi_dev.?, @ptrCast(&adapter))) and adapter != null) {
                    const adap_vtbl = adapter.?.lpVtbl;
                    if (adap_vtbl.*.GetParent) |get_parent| {
                        const parent_hr = get_parent(adapter.?, &c.IID_IDXGIFactory2, @ptrCast(&factory2));
                        if (c.FAILED(parent_hr)) safeRelease(&factory2);
                    }
                }
            }
        }
        dbgLog("[d3d] createCompositionSwapchain: factory2=0x{x}\n", .{if (factory2) |p| @intFromPtr(p) else 0});

        if (factory2 != null) {
            var sd1: c.DXGI_SWAP_CHAIN_DESC1 = std.mem.zeroes(c.DXGI_SWAP_CHAIN_DESC1);
            sd1.Width = self.width;
            sd1.Height = self.height;
            sd1.Format = c.DXGI_FORMAT_B8G8R8A8_UNORM;
            sd1.SampleDesc.Count = 1;
            sd1.BufferUsage = c.DXGI_USAGE_RENDER_TARGET_OUTPUT;
            sd1.BufferCount = 3;
            sd1.SwapEffect = c.DXGI_SWAP_EFFECT_FLIP_SEQUENTIAL;
            sd1.Scaling = c.DXGI_SCALING_STRETCH;
            // Always premultiplied alpha: WS_EX_NOREDIRECTIONBITMAP requires
            // the composition path.
            sd1.AlphaMode = c.DXGI_ALPHA_MODE_PREMULTIPLIED;
            sc1_buf_count = @intCast(sd1.BufferCount);

            const fac_vtbl = factory2.?.lpVtbl;
            if (fac_vtbl.*.CreateSwapChainForComposition) |create_sc_comp| {
                hr = create_sc_comp(factory2.?, @ptrCast(dev), &sd1, null, @ptrCast(&sc1));
                if (applog.isEnabled()) applog.appLog("[d3d] CreateSwapChainForComposition hr=0x{x} sc1=0x{x}\n", .{ @as(u32, @bitCast(hr)), if (sc1) |p| @intFromPtr(p) else 0 });
                if (!c.FAILED(hr) and sc1 != null) {
                    const sc1_vtbl = sc1.?.lpVtbl;
                    if (sc1_vtbl.*.QueryInterface) |sc_qi| {
                        const sc0_hr = sc_qi(sc1.?, &c.IID_IDXGISwapChain, @ptrCast(&sc0));
                        if (c.FAILED(sc0_hr)) safeRelease(&sc0);
                    }
                }
            } else {
                if (applog.isEnabled()) applog.appLog("[d3d] CreateSwapChainForComposition is NULL!\n", .{});
            }
        }

        if (sc1 == null or sc0 == null) return error.D3DCreateFailed;
        const composition_device = dxgi_dev orelse return error.D3DCreateFailed;
        try self.createDirectComposition(sc1.?, composition_device);

        self.swapchain = sc0;
        self.swapchain1 = sc1;
        sc0 = null;
        sc1 = null;
        self.swapchain_buf_count = sc1_buf_count;
        self.swapchain_buf_index = 0;
        self.swapchain3 = null;

        if (self.swapchain) |sc0p| {
            const sc0_vtbl = sc0p.*.lpVtbl;
            if (sc0_vtbl.*.QueryInterface) |sc_qi| {
                var sc3: ?*c.IDXGISwapChain3 = null;
                const hr_sc3 = sc_qi(sc0p, &c.IID_IDXGISwapChain3, @ptrCast(&sc3));
                if (applog.isEnabled()) {
                    applog.appLog("[d3d] QI IDXGISwapChain3 hr=0x{x} sc3=0x{x}\n", .{ @as(u32, @bitCast(hr_sc3)), if (sc3) |p| @intFromPtr(p) else 0 });
                }
                if (!c.FAILED(hr_sc3) and sc3 != null) {
                    self.swapchain3 = sc3;
                }
            }
        }
    }

    fn createSwapchainOnly(self: *Renderer) !void {
        var rc: c.RECT = undefined;
        _ = c.GetClientRect(self.hwnd, &rc);
        self.width = @intCast(@max(1, rc.right - rc.left));
        self.height = @intCast(@max(1, rc.bottom - rc.top));

        const dev = self.device;

        // Skip device creation -- jump straight to swap chain.
        // Feature level was determined at device creation time.
        dbgLog("[d3d] createSwapchainOnly: begin (device=0x{x})\n", .{if (dev) |p| @intFromPtr(p) else 0});

        try self.createCompositionSwapchain(dev.?);
    }

    fn createDeviceAndSwapchain(self: *Renderer) !void {
        var rc: c.RECT = undefined;
        _ = c.GetClientRect(self.hwnd, &rc);
        self.width = @intCast(@max(1, rc.right - rc.left));
        self.height = @intCast(@max(1, rc.bottom - rc.top));

        dbgLog("[d3d] init: createDeviceAndSwapchain begin\n", .{});

        var dev: ?*c.ID3D11Device = null;
        var ctx: ?*c.ID3D11DeviceContext = null;
        errdefer safeRelease(&dev);
        errdefer safeRelease(&ctx);
        var fl: u32 = 0;

        var flags: c.UINT = 0;
        const is_debug = (@import("builtin").mode == .Debug);
        if (is_debug) flags |= c.D3D11_CREATE_DEVICE_DEBUG;

        // 1st try (maybe with DEBUG flag)
        var hr: c.HRESULT = c.D3D11CreateDevice(
            null,
            c.D3D_DRIVER_TYPE_HARDWARE,
            null,
            flags,
            null,
            0,
            c.D3D11_SDK_VERSION,
            @ptrCast(&dev),
            @ptrCast(&fl),
            @ptrCast(&ctx),
        );

        // If debug-layer is missing, retry without DEBUG flag
        if ((hr != 0 or dev == null or ctx == null) and is_debug) {
            // A failed COM factory call may still return partial outputs.
            safeRelease(&dev);
            safeRelease(&ctx);

            flags &= ~@as(c.UINT, c.D3D11_CREATE_DEVICE_DEBUG);
            hr = c.D3D11CreateDevice(
                null,
                c.D3D_DRIVER_TYPE_HARDWARE,
                null,
                flags,
                null,
                0,
                c.D3D11_SDK_VERSION,
                @ptrCast(&dev),
                @ptrCast(&fl),
                @ptrCast(&ctx),
            );
        }

        if (hr != 0 or dev == null or ctx == null) {
            dbgLog("[d3d] init: D3D11CreateDevice failed hr=0x{x}\n", .{@as(u32, @bitCast(hr))});
            return error.D3DCreateFailed;
        }
        dbgLog("[d3d] init: D3D11CreateDevice ok dev=0x{x} ctx=0x{x} fl=0x{x}\n", .{ if (dev) |p| @intFromPtr(p) else 0, if (ctx) |p| @intFromPtr(p) else 0, fl });
        self.feature_level = fl;

        // Build the swapchain before transferring the device, so the
        // errdefers above still own dev and ctx if this fails.
        try self.createCompositionSwapchain(dev.?);

        self.device = dev;
        self.ctx = ctx;
        dev = null;
        ctx = null;

        // ★ Added: If Debug layer enabled, get InfoQueue and break on critical messages
        const is_debug2 = (@import("builtin").mode == .Debug);
        if (is_debug2) {
            const unk: *c.IUnknown = @ptrCast(self.device.?);
            const unk_vtbl = unk.*.lpVtbl;
            const qi2 = unk_vtbl.*.QueryInterface orelse return;

            var infoq: ?*c.ID3D11InfoQueue = null;
            var dbg: ?*c.ID3D11Debug = null;

            // Query ID3D11InfoQueue
            if (!c.FAILED(qi2(unk, &c.IID_ID3D11InfoQueue, @ptrCast(&infoq))) and infoq != null) {
                self.infoq = infoq;

                // Break on high severity (will Dump later so visible in logs even without debugger)
                if (infoq.?.lpVtbl.*.SetBreakOnSeverity) |f| {
                    _ = f(infoq.?, c.D3D11_MESSAGE_SEVERITY_CORRUPTION, c.TRUE);
                    _ = f(infoq.?, c.D3D11_MESSAGE_SEVERITY_ERROR, c.TRUE);
                } else if (applog.isEnabled()) {
                    applog.appLog("[d3d] SetBreakOnSeverity unavailable\n", .{});
                }

                if (applog.isEnabled()) applog.appLog("[d3d] InfoQueue enabled\n", .{});
            } else {
                if (applog.isEnabled()) applog.appLog("[d3d] InfoQueue NOT available (debug layer missing?)\n", .{});
            }

            // Query ID3D11Debug (optional: can be used for ReportLiveDeviceObjects)
            if (!c.FAILED(qi2(unk, &c.IID_ID3D11Debug, @ptrCast(&dbg))) and dbg != null) {
                self.dbg = dbg;
                if (applog.isEnabled()) applog.appLog("[d3d] ID3D11Debug available\n", .{});
            }
        }
    }

    fn createBackTargets(self: *Renderer) !void {
        const dev = self.device.?;
        const sc = self.swapchain.?;

        if (self.swapchain_buf_count > MaxSwapchainBuffers) {
            return error.D3DGetBackBufferFailed;
        }

        const vtbl = sc.*.lpVtbl;
        const get_buf = vtbl.*.GetBuffer orelse return error.D3DGetBackBufferFailed;
        var i: u32 = 0;
        while (i < self.swapchain_buf_count) : (i += 1) {
            var bb: ?*c.ID3D11Texture2D = null;
            const pp: *?*anyopaque = @ptrCast(&bb);
            if (applog.isEnabled()) {
                applog.appLog("[d3d] GetBuffer idx={d}\n", .{i});
            }
            const hr = get_buf(sc, i, &c.IID_ID3D11Texture2D, pp);
            if (c.FAILED(hr) or bb == null) return error.D3DGetBackBufferFailed;

            self.bb_texs[@intCast(i)] = bb;
            self.bb_rtvs[@intCast(i)] = null;
        }

        self.bb_tex = self.bb_texs[0];
        self.bb_rtv = null;

        // persistent back buffer texture
        var desc: c.D3D11_TEXTURE2D_DESC = undefined;

        // ID3D11Texture2D::GetDesc (call via vtbl; cimport wrapper may fail on optional fn ptr)
        const tex = self.bb_texs[0].?;
        const tex_vtbl = tex.*.lpVtbl;
        const get_desc = tex_vtbl.*.GetDesc orelse return error.D3DGetBackBufferDescFailed;
        get_desc(tex, &desc);

        if (applog.isEnabled()) {
            applog.appLog(
                "[d3d] bb_desc: {d}x{d} fmt={d} sample={d}/{d} bind=0x{x} usage={d}\n",
                .{ desc.Width, desc.Height, @as(u32, desc.Format), desc.SampleDesc.Count, desc.SampleDesc.Quality, desc.BindFlags, @as(u32, desc.Usage) },
            );
        }

        desc.BindFlags = c.D3D11_BIND_RENDER_TARGET | c.D3D11_BIND_SHADER_RESOURCE;
        desc.Usage = c.D3D11_USAGE_DEFAULT;
        desc.CPUAccessFlags = 0;

        var back: ?*c.ID3D11Texture2D = null;

        // ID3D11Device::CreateTexture2D (call via vtbl; avoids anytype/@ptrCast issues)
        const dev_vtbl3 = dev.*.lpVtbl;
        const create_tex2d = dev_vtbl3.*.CreateTexture2D orelse return error.D3DCreateBackTexFailed;

        // Signature: (This, pDesc, pInitialData, ppTexture2D) -> HRESULT
        const hr_back = create_tex2d(dev, &desc, null, @ptrCast(&back));
        if (c.FAILED(hr_back) or back == null) return error.D3DCreateBackTexFailed;

        if (applog.isEnabled()) {
            applog.appLog(
                "[d3d] back_tex_desc: {d}x{d} fmt={d} sample={d}/{d} bind=0x{x} usage={d}\n",
                .{ desc.Width, desc.Height, @as(u32, desc.Format), desc.SampleDesc.Count, desc.SampleDesc.Quality, desc.BindFlags, @as(u32, desc.Usage) },
            );
        }

        self.back_tex = back;

        var back_rtv: ?*c.ID3D11RenderTargetView = null;

        const dev_vtbl2 = dev.*.lpVtbl;
        const create_rtv2 = dev_vtbl2.*.CreateRenderTargetView orelse return error.D3DCreateBackRTVFailed;

        const hr_back_rtv = create_rtv2(
            dev,
            @ptrCast(back.?), // pResource: ID3D11Resource*
            null,
            @ptrCast(&back_rtv),
        );
        if (c.FAILED(hr_back_rtv) or back_rtv == null) return error.D3DCreateBackRTVFailed;

        self.back_rtv = back_rtv;

        // RTVs on each swapchain buffer — used by drawCustomShaderPass
        // to write shader output directly into the current bb_tex,
        // leaving back_tex untouched so animation frames can keep
        // sampling the original terminal contents instead of feeding
        // the previous shader output back into the shader's input.
        // In flip-model, only buffer 0 is accessible from D3D11, so
        // bb_rtvs[1..] creation returns E_INVALIDARG — not fatal.
        {
            var bi: u32 = 0;
            while (bi < self.swapchain_buf_count) : (bi += 1) {
                const bb_tex_i = self.bb_texs[@intCast(bi)] orelse continue;
                var bb_rtv_i: ?*c.ID3D11RenderTargetView = null;
                const hr_bb = create_rtv2(dev, @ptrCast(bb_tex_i), null, @ptrCast(&bb_rtv_i));
                if (c.FAILED(hr_bb) or bb_rtv_i == null) {
                    if (applog.isEnabled()) applog.appLog("[d3d] bb_rtvs[{d}] create hr=0x{x} (ok for non-0 in flip model)\n", .{ bi, @as(u32, @bitCast(hr_bb)) });
                    continue;
                }
                self.bb_rtvs[@intCast(bi)] = bb_rtv_i;
            }
            self.bb_rtv = self.bb_rtvs[0];
        }
        self.resetBackBufferDamage();
    }

    /// Shift the retained content in back_tex by `dy_px` pixels vertically.
    /// Positive dy_px = content moves down (scroll up / rows_delta < 0).
    /// Negative dy_px = content moves up (scroll down / rows_delta > 0).
    /// Uses a staging texture to avoid overlapping self-copy.
    ///
    /// Returns false if the copy did not run (resource/context missing,
    /// staging texture creation failed, or the shift covers the whole
    /// region). The caller (applyScrollShift, windows/app.zig) must treat
    /// false as "back_tex pixels were never shifted" and redraw the entire
    /// scroll region from current row data — the gap-row expansion it
    /// otherwise computes from the CPU-side accumulated shift only covers
    /// the vacated band, on the assumption this copy succeeded.
    pub fn scrollBackTex(self: *Renderer, scroll_rect: c.RECT, dy_px: i32) bool {
        if (dy_px == 0) return true;
        const ctx = self.ctx orelse return false;
        const back_tex = self.back_tex orelse return false;
        const dev = self.device orelse return false;

        const w: u32 = self.width;
        const h: u32 = self.height;
        if (w == 0 or h == 0) return false;

        // Reject a degenerate/negative rect BEFORE any @intCast to an
        // unsigned type below — @intCast of a negative i32 is a Zig
        // safety-checked panic, and the previous emptiness check ran too
        // late to prevent it (see MED-5).
        if (scroll_rect.right <= scroll_rect.left or scroll_rect.bottom <= scroll_rect.top) return false;

        // Clamp scroll_rect to texture bounds
        const sr_left: u32 = @intCast(@max(0, scroll_rect.left));
        const sr_top: u32 = @intCast(@max(0, scroll_rect.top));
        const sr_right: u32 = @intCast(@min(@as(i32, @intCast(w)), scroll_rect.right));
        const sr_bottom: u32 = @intCast(@min(@as(i32, @intCast(h)), scroll_rect.bottom));
        if (sr_left >= sr_right or sr_top >= sr_bottom) return false;

        // Source region: the part of scroll_rect that will be preserved after shift
        var src_top: u32 = undefined;
        var src_bottom: u32 = undefined;
        var dst_y: u32 = undefined;

        if (dy_px > 0) {
            // Content moves down: source is top portion, destination is shifted down
            const shift: u32 = @intCast(dy_px);
            if (shift >= sr_bottom - sr_top) return false; // shift larger than region
            src_top = sr_top;
            src_bottom = sr_bottom - shift;
            dst_y = sr_top + shift;
        } else {
            // Content moves up: source is bottom portion, destination is shifted up
            const shift: u32 = @intCast(-dy_px);
            if (shift >= sr_bottom - sr_top) return false;
            src_top = sr_top + shift;
            src_bottom = sr_bottom;
            dst_y = sr_top;
        }

        // Lazy-create staging texture matching back_tex format and dimensions
        if (self.scroll_staging_tex == null) {
            // Query back_tex format to ensure CopySubresourceRegion compatibility
            var back_desc: c.D3D11_TEXTURE2D_DESC = undefined;
            const back_vtbl = back_tex.*.lpVtbl;
            const get_desc = back_vtbl.*.GetDesc orelse return false;
            get_desc(back_tex, &back_desc);

            var desc: c.D3D11_TEXTURE2D_DESC = std.mem.zeroes(c.D3D11_TEXTURE2D_DESC);
            desc.Width = w;
            desc.Height = h;
            desc.MipLevels = 1;
            desc.ArraySize = 1;
            desc.Format = back_desc.Format;
            desc.SampleDesc.Count = 1;
            desc.Usage = c.D3D11_USAGE_DEFAULT;
            desc.BindFlags = 0; // staging only, no bind needed

            const dev_vtbl = dev.*.lpVtbl;
            const create_tex = dev_vtbl.*.CreateTexture2D orelse return false;
            var staging: ?*c.ID3D11Texture2D = null;
            const hr = create_tex(dev, &desc, null, @ptrCast(&staging));
            if (c.FAILED(hr) or staging == null) return false;
            self.scroll_staging_tex = staging;
        }

        const staging_tex = self.scroll_staging_tex.?;
        const ctx_vtbl = ctx.*.lpVtbl;
        const copy_sub = ctx_vtbl.*.CopySubresourceRegion orelse return false;

        // Step 1: Copy source region from back_tex to staging
        const src_box: c.D3D11_BOX = .{
            .left = sr_left,
            .top = src_top,
            .front = 0,
            .right = sr_right,
            .bottom = src_bottom,
            .back = 1,
        };
        const staging_res: *c.ID3D11Resource = @ptrCast(staging_tex);
        const back_res: *c.ID3D11Resource = @ptrCast(back_tex);
        copy_sub(ctx, staging_res, 0, sr_left, src_top, 0, back_res, 0, &src_box);

        // Step 2: Copy from staging back to back_tex at shifted position
        copy_sub(ctx, back_res, 0, sr_left, dst_y, 0, staging_res, 0, &src_box);

        if (applog.isEnabled()) {
            applog.appLog(
                "[d3d] scrollBackTex dy={d} src_top={d} src_bot={d} dst_y={d} rect=({d},{d},{d},{d})\n",
                .{ dy_px, src_top, src_bottom, dst_y, sr_left, sr_top, sr_right, sr_bottom },
            );
        }
        return true;
    }

    /// Whether back_tex currently contains a scrollbar overlay with a saved
    /// clean underlay. Callers use this to keep a fade-out-to-zero paint from
    /// taking the no-damage early return before the final restore.
    pub fn hasScrollbarUnderlay(self: *const Renderer) bool {
        return self.scrollbar_underlay_state.valid;
    }

    /// Restore the clean pixels saved before the previous scrollbar draw.
    /// The returned rectangle must be included in the next present damage.
    /// Caller must hold lockContext().
    pub fn restoreScrollbarUnderlay(self: *Renderer) !?c.RECT {
        if (!self.scrollbar_underlay_state.valid) return null;
        errdefer {
            safeRelease(&self.scrollbar_underlay_tex);
            self.scrollbar_underlay_state.resourceFailed();
        }

        const ctx = self.ctx orelse return error.ScrollbarUnderlayRestoreFailed;
        const back_tex = self.back_tex orelse return error.ScrollbarUnderlayRestoreFailed;
        const scratch = self.scrollbar_underlay_tex orelse return error.ScrollbarUnderlayRestoreFailed;
        const back_rtv = self.back_rtv orelse return error.ScrollbarUnderlayRestoreFailed;
        const rect = self.scrollbar_underlay_rect;
        if (rect.left < 0 or rect.top < 0 or rect.right <= rect.left or rect.bottom <= rect.top) {
            return error.ScrollbarUnderlayRestoreFailed;
        }

        const rect_w: u32 = @intCast(rect.right - rect.left);
        const rect_h: u32 = @intCast(rect.bottom - rect.top);
        if (rect_w != self.scrollbar_underlay_state.width or
            rect_h != self.scrollbar_underlay_state.height)
        {
            return error.ScrollbarUnderlayRestoreFailed;
        }
        if (rect.right > @as(i32, @intCast(self.width)) or
            rect.bottom > @as(i32, @intCast(self.height)))
        {
            return error.ScrollbarUnderlayRestoreFailed;
        }

        const ctx_vtbl = ctx.*.lpVtbl;
        const copy_sub = ctx_vtbl.*.CopySubresourceRegion orelse
            return error.ScrollbarUnderlayRestoreFailed;
        const om_set_rt = ctx_vtbl.*.OMSetRenderTargets orelse
            return error.ScrollbarUnderlayRestoreFailed;

        // back_tex may still be bound from the preceding paint. Explicitly
        // unbind it around the copy to avoid an RTV/copy-resource hazard.
        om_set_rt(ctx, 0, null, null);
        defer {
            var rtvs: [1]?*c.ID3D11RenderTargetView = .{back_rtv};
            om_set_rt(ctx, 1, @ptrCast(&rtvs), null);
        }

        const src_box: c.D3D11_BOX = .{
            .left = 0,
            .top = 0,
            .front = 0,
            .right = rect_w,
            .bottom = rect_h,
            .back = 1,
        };
        const dst_res: *c.ID3D11Resource = @ptrCast(back_tex);
        const src_res: *c.ID3D11Resource = @ptrCast(scratch);
        copy_sub(ctx, dst_res, 0, @intCast(rect.left), @intCast(rect.top), 0, src_res, 0, &src_box);
        self.scrollbar_underlay_state.restored();
        return rect;
    }

    /// Save the clean back_tex pixels that the next alpha-blended scrollbar
    /// draw will cover. The texture is narrow and retained across fade ticks;
    /// it is recreated only when the track geometry changes. Caller must hold
    /// lockContext(), and must restore a prior underlay before capturing again.
    pub fn captureScrollbarUnderlay(self: *Renderer, raw_rect: c.RECT) !?c.RECT {
        if (self.scrollbar_underlay_state.valid) {
            return error.ScrollbarUnderlayAlreadyValid;
        }

        const rect = self.clampBackDamageRect(raw_rect) orelse return null;
        const rect_w: u32 = @intCast(rect.right - rect.left);
        const rect_h: u32 = @intCast(rect.bottom - rect.top);
        errdefer {
            safeRelease(&self.scrollbar_underlay_tex);
            self.scrollbar_underlay_state.resourceFailed();
        }

        const ctx = self.ctx orelse return error.ScrollbarUnderlayCaptureFailed;
        const back_tex = self.back_tex orelse return error.ScrollbarUnderlayCaptureFailed;
        const back_rtv = self.back_rtv orelse return error.ScrollbarUnderlayCaptureFailed;
        const dev = self.device orelse return error.ScrollbarUnderlayCaptureFailed;

        const geometry_changed = self.scrollbar_underlay_state.geometryChanged(rect_w, rect_h);
        if (self.scrollbar_underlay_tex == null or geometry_changed) {
            safeRelease(&self.scrollbar_underlay_tex);
            self.scrollbar_underlay_state.resourceFailed();

            var back_desc: c.D3D11_TEXTURE2D_DESC = undefined;
            const get_desc = back_tex.*.lpVtbl.*.GetDesc orelse
                return error.ScrollbarUnderlayCaptureFailed;
            get_desc(back_tex, &back_desc);

            var desc: c.D3D11_TEXTURE2D_DESC = std.mem.zeroes(c.D3D11_TEXTURE2D_DESC);
            desc.Width = rect_w;
            desc.Height = rect_h;
            desc.MipLevels = 1;
            desc.ArraySize = 1;
            desc.Format = back_desc.Format;
            desc.SampleDesc.Count = 1;
            desc.Usage = c.D3D11_USAGE_DEFAULT;
            desc.BindFlags = 0;

            const create_tex = dev.*.lpVtbl.*.CreateTexture2D orelse
                return error.ScrollbarUnderlayCaptureFailed;
            var scratch: ?*c.ID3D11Texture2D = null;
            const hr = create_tex(dev, &desc, null, @ptrCast(&scratch));
            if (c.FAILED(hr) or scratch == null) {
                if (isDeviceLost(hr)) self.device_lost = true;
                if (applog.isEnabled()) applog.appLog(
                    "[d3d] scrollbar underlay allocation failed {d}x{d} hr=0x{x}\n",
                    .{ rect_w, rect_h, @as(u32, @bitCast(hr)) },
                );
                return error.ScrollbarUnderlayCaptureFailed;
            }
            self.scrollbar_underlay_tex = scratch;
        }

        const scratch = self.scrollbar_underlay_tex orelse
            return error.ScrollbarUnderlayCaptureFailed;
        const ctx_vtbl = ctx.*.lpVtbl;
        const copy_sub = ctx_vtbl.*.CopySubresourceRegion orelse
            return error.ScrollbarUnderlayCaptureFailed;
        const om_set_rt = ctx_vtbl.*.OMSetRenderTargets orelse
            return error.ScrollbarUnderlayCaptureFailed;

        om_set_rt(ctx, 0, null, null);
        defer {
            var rtvs: [1]?*c.ID3D11RenderTargetView = .{back_rtv};
            om_set_rt(ctx, 1, @ptrCast(&rtvs), null);
        }

        const src_box: c.D3D11_BOX = .{
            .left = @intCast(rect.left),
            .top = @intCast(rect.top),
            .front = 0,
            .right = @intCast(rect.right),
            .bottom = @intCast(rect.bottom),
            .back = 1,
        };
        const dst_res: *c.ID3D11Resource = @ptrCast(scratch);
        const src_res: *c.ID3D11Resource = @ptrCast(back_tex);
        copy_sub(ctx, dst_res, 0, 0, 0, 0, src_res, 0, &src_box);
        self.scrollbar_underlay_rect = rect;
        self.scrollbar_underlay_state.captured(rect_w, rect_h);
        return rect;
    }

    fn ensureGlowTextures(self: *Renderer) void {
        const hw = @max(1, self.width / 2);
        const hh = @max(1, self.height / 2);
        if (self.glow_extract_tex != null and self.glow_half_w == hw and self.glow_half_h == hh) return;

        // Release old textures
        safeRelease(&self.glow_extract_srv);
        safeRelease(&self.glow_extract_rtv);
        safeRelease(&self.glow_extract_tex);
        for (&self.glow_mip_srv) |*s| safeRelease(s);
        for (&self.glow_mip_rtv) |*r| safeRelease(r);
        for (&self.glow_mip_tex) |*t| safeRelease(t);

        const dev = self.device orelse return;
        const dev_vtbl = dev.*.lpVtbl;
        const create_tex = dev_vtbl.*.CreateTexture2D orelse return;
        const create_rtv = dev_vtbl.*.CreateRenderTargetView orelse return;
        const create_srv = dev_vtbl.*.CreateShaderResourceView orelse return;

        var td: c.D3D11_TEXTURE2D_DESC = std.mem.zeroes(c.D3D11_TEXTURE2D_DESC);
        td.MipLevels = 1;
        td.ArraySize = 1;
        td.Format = c.DXGI_FORMAT_R8G8B8A8_UNORM;
        td.SampleDesc.Count = 1;
        td.Usage = c.D3D11_USAGE_DEFAULT;
        td.BindFlags = c.D3D11_BIND_RENDER_TARGET | c.D3D11_BIND_SHADER_RESOURCE;

        // Extract texture: 1/2 resolution
        td.Width = hw;
        td.Height = hh;

        var tex1: ?*c.ID3D11Texture2D = null;
        if (c.FAILED(create_tex(dev, &td, null, &tex1)) or tex1 == null) return;
        self.glow_extract_tex = tex1;

        var rtv1: ?*c.ID3D11RenderTargetView = null;
        if (c.FAILED(create_rtv(dev, @ptrCast(tex1.?), null, &rtv1)) or rtv1 == null) return;
        self.glow_extract_rtv = rtv1;

        var srv1: ?*c.ID3D11ShaderResourceView = null;
        if (c.FAILED(create_srv(dev, @ptrCast(tex1.?), null, &srv1)) or srv1 == null) return;
        self.glow_extract_srv = srv1;

        // Mip textures: 1/4, 1/8, 1/16
        var mw = @max(1, hw / 2);
        var mh = @max(1, hh / 2);
        for (0..3) |i| {
            td.Width = mw;
            td.Height = mh;

            var tex_m: ?*c.ID3D11Texture2D = null;
            if (c.FAILED(create_tex(dev, &td, null, &tex_m)) or tex_m == null) return;
            self.glow_mip_tex[i] = tex_m;

            var rtv_m: ?*c.ID3D11RenderTargetView = null;
            if (c.FAILED(create_rtv(dev, @ptrCast(tex_m.?), null, &rtv_m)) or rtv_m == null) return;
            self.glow_mip_rtv[i] = rtv_m;

            var srv_m: ?*c.ID3D11ShaderResourceView = null;
            if (c.FAILED(create_srv(dev, @ptrCast(tex_m.?), null, &srv_m)) or srv_m == null) return;
            self.glow_mip_srv[i] = srv_m;

            mw = @max(1, mw / 2);
            mh = @max(1, mh / 2);
        }

        self.glow_half_w = hw;
        self.glow_half_h = hh;
    }

    /// Ensure a scratch texture matching the persistent back buffer exists,
    /// so the custom shader pass can sample a stable copy of `back_tex`
    /// while writing back into `back_rtv` (reading and writing the same
    /// resource is disallowed in D3D11).
    fn ensureCustomShaderScratch(self: *Renderer) void {
        if (self.custom_shader_scratch_tex != null and self.custom_shader_scratch_w == self.width and self.custom_shader_scratch_h == self.height) return;

        safeRelease(&self.custom_shader_scratch_srv);
        safeRelease(&self.custom_shader_scratch_tex);

        const dev = self.device orelse return;
        const back = self.back_tex orelse return;

        // Inherit size/format from back_tex.
        var back_desc: c.D3D11_TEXTURE2D_DESC = undefined;
        const back_vtbl = back.*.lpVtbl;
        const get_desc = back_vtbl.*.GetDesc orelse return;
        get_desc(back, &back_desc);

        var td: c.D3D11_TEXTURE2D_DESC = std.mem.zeroes(c.D3D11_TEXTURE2D_DESC);
        td.Width = back_desc.Width;
        td.Height = back_desc.Height;
        td.MipLevels = 1;
        td.ArraySize = 1;
        td.Format = back_desc.Format;
        td.SampleDesc.Count = 1;
        td.Usage = c.D3D11_USAGE_DEFAULT;
        td.BindFlags = c.D3D11_BIND_SHADER_RESOURCE;

        const dev_vtbl = dev.*.lpVtbl;
        const create_tex = dev_vtbl.*.CreateTexture2D orelse return;
        const create_srv = dev_vtbl.*.CreateShaderResourceView orelse return;

        var scratch: ?*c.ID3D11Texture2D = null;
        if (c.FAILED(create_tex(dev, &td, null, &scratch)) or scratch == null) return;
        self.custom_shader_scratch_tex = scratch;

        var srv: ?*c.ID3D11ShaderResourceView = null;
        if (c.FAILED(create_srv(dev, @ptrCast(scratch.?), null, &srv)) or srv == null) {
            safeRelease(&self.custom_shader_scratch_tex);
            return;
        }
        self.custom_shader_scratch_srv = srv;
        self.custom_shader_scratch_w = back_desc.Width;
        self.custom_shader_scratch_h = back_desc.Height;
    }

    /// Ensure two ping-pong textures (render-target + shader-resource
    /// bound) matching back_tex's size/format exist. Only needed when
    /// the custom shader chain has more than one pass.
    fn ensureCustomShaderPong(self: *Renderer) void {
        if (self.custom_shader_pong_tex[0] != null and self.custom_shader_pong_tex[1] != null and self.custom_shader_pong_w == self.width and self.custom_shader_pong_h == self.height) return;

        for (&self.custom_shader_pong_srv) |*s| safeRelease(s);
        for (&self.custom_shader_pong_rtv) |*r| safeRelease(r);
        for (&self.custom_shader_pong_tex) |*t| safeRelease(t);

        const dev = self.device orelse return;
        const back = self.back_tex orelse return;

        var back_desc: c.D3D11_TEXTURE2D_DESC = undefined;
        const back_vtbl = back.*.lpVtbl;
        const get_desc = back_vtbl.*.GetDesc orelse return;
        get_desc(back, &back_desc);

        var td: c.D3D11_TEXTURE2D_DESC = std.mem.zeroes(c.D3D11_TEXTURE2D_DESC);
        td.Width = back_desc.Width;
        td.Height = back_desc.Height;
        td.MipLevels = 1;
        td.ArraySize = 1;
        td.Format = back_desc.Format;
        td.SampleDesc.Count = 1;
        td.Usage = c.D3D11_USAGE_DEFAULT;
        td.BindFlags = c.D3D11_BIND_RENDER_TARGET | c.D3D11_BIND_SHADER_RESOURCE;

        const dev_vtbl = dev.*.lpVtbl;
        const create_tex = dev_vtbl.*.CreateTexture2D orelse return;
        const create_srv = dev_vtbl.*.CreateShaderResourceView orelse return;
        const create_rtv = dev_vtbl.*.CreateRenderTargetView orelse return;

        var i: usize = 0;
        while (i < 2) : (i += 1) {
            var tex: ?*c.ID3D11Texture2D = null;
            if (c.FAILED(create_tex(dev, &td, null, &tex)) or tex == null) {
                for (&self.custom_shader_pong_srv) |*s| safeRelease(s);
                for (&self.custom_shader_pong_rtv) |*r| safeRelease(r);
                for (&self.custom_shader_pong_tex) |*t| safeRelease(t);
                return;
            }
            var srv_i: ?*c.ID3D11ShaderResourceView = null;
            if (c.FAILED(create_srv(dev, @ptrCast(tex.?), null, &srv_i)) or srv_i == null) {
                safeRelease(&tex);
                for (&self.custom_shader_pong_srv) |*s| safeRelease(s);
                for (&self.custom_shader_pong_rtv) |*r| safeRelease(r);
                for (&self.custom_shader_pong_tex) |*t| safeRelease(t);
                return;
            }
            var rtv_i: ?*c.ID3D11RenderTargetView = null;
            if (c.FAILED(create_rtv(dev, @ptrCast(tex.?), null, &rtv_i)) or rtv_i == null) {
                safeRelease(&srv_i);
                safeRelease(&tex);
                for (&self.custom_shader_pong_srv) |*s| safeRelease(s);
                for (&self.custom_shader_pong_rtv) |*r| safeRelease(r);
                for (&self.custom_shader_pong_tex) |*t| safeRelease(t);
                return;
            }
            self.custom_shader_pong_tex[i] = tex;
            self.custom_shader_pong_srv[i] = srv_i;
            self.custom_shader_pong_rtv[i] = rtv_i;
        }
        self.custom_shader_pong_w = back_desc.Width;
        self.custom_shader_pong_h = back_desc.Height;
    }

    fn bloomShadersReady(self: *const Renderer) bool {
        return self.vs_fullscreen != null and
            self.ps_glow_extract != null and
            self.ps_kawase_down != null and
            self.ps_kawase_up != null and
            self.ps_glow_composite != null;
    }

    /// Compile the five bloom shaders before a glow-enabled paint is queued.
    /// No-op once built. Keeping this opt-in avoids the ~50 ms cost for
    /// configs that never enable glow without charging the first WM_PAINT.
    /// Returns `true` when every shader is ready to use.
    pub fn prepareBloomShaders(self: *Renderer) bool {
        if (self.bloomShadersReady()) return true;
        if (self.bloom_prepare_attempted) return false;
        self.bloom_prepare_attempted = true;

        const dev = self.device orelse return false;
        const dev_vtbl = dev.*.lpVtbl;
        const create_vs_fn = dev_vtbl.*.CreateVertexShader orelse return false;
        const create_ps_fn = dev_vtbl.*.CreatePixelShader orelse return false;
        const hlsl = @embedFile("../shaders/main.hlsl");

        const BloomEntry = struct {
            entry: [*:0]const u8,
            target: [*:0]const u8,
        };
        const bloom_entries = [_]BloomEntry{
            .{ .entry = "VSFullscreen", .target = "vs_5_0" },
            .{ .entry = "PSGlowExtract", .target = "ps_5_0" },
            .{ .entry = "PSKawaseDown", .target = "ps_5_0" },
            .{ .entry = "PSKawaseUp", .target = "ps_5_0" },
            .{ .entry = "PSGlowComposite", .target = "ps_5_0" },
        };

        var bloom_blobs: [bloom_entries.len]?*ID3DBlob = .{ null, null, null, null, null };
        defer for (&bloom_blobs) |*b| blobRelease(b.*);

        for (bloom_entries, 0..) |be, idx| {
            var blob: ?*ID3DBlob = null;
            var err_b: ?*ID3DBlob = null;
            defer blobRelease(err_b);
            const hr_b = D3DCompile(hlsl.ptr, hlsl.len, null, null, null, be.entry, be.target, 0, 0, &blob, &err_b);
            if (hr_b != 0 or blob == null) {
                dumpBlobAsText("[D3DCompile bloom] ", err_b);
                dbgLog("[d3d] WARNING: bloom shader '{s}' compile failed, bloom disabled\n", .{be.entry});
                return false;
            }
            bloom_blobs[idx] = blob;
        }

        if (self.vs_fullscreen == null) {
            const bp0 = blobPtr(bloom_blobs[0]) orelse return false;
            const bs0 = blobSize(bloom_blobs[0]);
            var vs_fs: ?*c.ID3D11VertexShader = null;
            if (c.FAILED(create_vs_fn(dev, bp0, bs0, null, &vs_fs)) or vs_fs == null) return false;
            self.vs_fullscreen = vs_fs;
        }

        inline for (.{ 1, 2, 3, 4 }, .{ &self.ps_glow_extract, &self.ps_kawase_down, &self.ps_kawase_up, &self.ps_glow_composite }) |idx, field| {
            if (field.* == null) {
                const bp = blobPtr(bloom_blobs[idx]) orelse return false;
                const bs = blobSize(bloom_blobs[idx]);
                var ps_out: ?*c.ID3D11PixelShader = null;
                if (c.FAILED(create_ps_fn(dev, bp, bs, null, &ps_out)) or ps_out == null) return false;
                field.* = ps_out;
            }
        }
        return self.bloomShadersReady();
    }

    /// Compile `VSCustomPost` from main.hlsl the first time it's needed.
    /// No-op when already built. Deferred to
    /// `loadCustomShaderPipelines` to skip the ~20 ms D3DCompile when
    /// no custom shaders are configured.
    fn ensureVsCustomPost(self: *Renderer, dev: *c.ID3D11Device) void {
        if (self.vs_custom_post != null) return;
        const dev_vtbl = dev.*.lpVtbl;
        const create_vs_fn = dev_vtbl.*.CreateVertexShader orelse return;
        const hlsl = @embedFile("../shaders/main.hlsl");
        var vcp_blob: ?*ID3DBlob = null;
        var vcp_err: ?*ID3DBlob = null;
        defer blobRelease(vcp_blob);
        defer blobRelease(vcp_err);
        const hr_vcp = D3DCompile(hlsl.ptr, hlsl.len, null, null, null, "VSCustomPost", "vs_5_0", 0, 0, &vcp_blob, &vcp_err);
        if (hr_vcp != 0 or vcp_blob == null) {
            applog.appLog("[d3d] VSCustomPost D3DCompile FAILED hr=0x{x}\n", .{@as(u32, @bitCast(hr_vcp))});
            dumpBlobAsText("[D3DCompile VSCustomPost] ", vcp_err);
            return;
        }
        const vcp_p = blobPtr(vcp_blob).?;
        const vcp_s = blobSize(vcp_blob);
        var vs_cp: ?*c.ID3D11VertexShader = null;
        if (c.FAILED(create_vs_fn(dev, vcp_p, vcp_s, null, &vs_cp)) or vs_cp == null) {
            applog.appLog("[d3d] VSCustomPost create shader FAILED\n", .{});
            return;
        }
        self.vs_custom_post = vs_cp;
        applog.appLog("[d3d] VSCustomPost compiled ok\n", .{});
    }

    /// Load user-supplied custom post-process shaders: read each GLSL file
    /// listed in config, cross-compile to HLSL via the core C ABI, then
    /// D3DCompile to a pixel shader. Called once after renderer init.
    /// Failures are logged and skipped — a missing custom shader falls
    /// back to the normal back->swapchain copy path.
    pub fn loadCustomShaderPipelines(self: *Renderer, cfg: *const core.config.Config) void {
        self.custom_shader_post_process = @intFromEnum(cfg.shaders.post_process);
        for (self.custom_shader_pipelines.items) |*p| p.deinit();
        self.custom_shader_pipelines.clearRetainingCapacity();
        self.any_custom_shader_needs_animation = false;

        if (!cfg.shaders.enabled or cfg.shaders.paths.len == 0) return;
        const dev = self.device orelse return;

        // Compile the custom-post VS lazily — only when at least one
        // user shader is about to be loaded. Skipping this in
        // shaders-disabled startups saves ~20 ms.
        self.ensureVsCustomPost(dev);

        for (cfg.shaders.paths) |path| {
            const pipeline = self.compileCustomShader(dev, path, cfg.shaders.preserve_alpha) catch |e| {
                applog.appLog("[CustomShader] skipped {s}: {any}\n", .{ path, e });
                continue;
            };
            self.custom_shader_pipelines.append(self.alloc, pipeline) catch {
                var dead = pipeline;
                dead.deinit();
                continue;
            };
            if (pipeline.needs_animation) self.any_custom_shader_needs_animation = true;
        }
        applog.appLog(
            "[CustomShader] loaded {d}/{d} custom shaders, anyNeedsAnimation={}\n",
            .{ self.custom_shader_pipelines.items.len, cfg.shaders.paths.len, self.any_custom_shader_needs_animation },
        );
    }

    const CustomShaderCompileError = error{
        FileOpenFailed,
        FileReadFailed,
        EmptySource,
        GlslCompileFailed,
        HlslCompileFailed,
        PixelShaderCreateFailed,
        OutOfMemory,
    };

    /// Rewrite SPIRV-Cross-generated HLSL so the PS input/output are
    /// passed as explicit function arguments between `main` and
    /// `frag_main`, instead of file-scope `static` globals.
    ///
    /// Observed on at least one Windows D3D11 driver: the emitted
    /// `static float2 vUV; ... void frag_main() { ...vUV... }` +
    /// `vUV = stage_input.vUV; frag_main();` pattern leaves `vUV`
    /// reading as (0, 0) inside frag_main, and the output static
    /// never populates. Inlining the values via function arguments
    /// sidesteps the issue and produces the same visual result as
    /// equivalent hand-written HLSL.
    ///
    /// Returns a newly-allocated HLSL string (caller frees) on success,
    /// or `error.PatternNotFound` if the expected SPIRV-Cross shape
    /// isn't present (leave the HLSL alone in that case).
    fn patchSpvCrossPsStaticPattern(
        alloc: std.mem.Allocator,
        hlsl: []const u8,
    ) ![]u8 {
        const static_vuv = "\nstatic float2 vUV;\n";
        const static_frag_color = "\nstatic float4 zonvie_fragColor;\n";
        const frag_main_decl = "\nvoid frag_main()\n";
        const main_body_target =
            "    vUV = stage_input.vUV;\n" ++
            "    frag_main();\n" ++
            "    SPIRV_Cross_Output stage_output;\n" ++
            "    stage_output.zonvie_fragColor = zonvie_fragColor;\n";
        const main_body_replacement =
            "    SPIRV_Cross_Output stage_output;\n" ++
            "    frag_main(stage_input.vUV, stage_output.zonvie_fragColor);\n";

        const input_struct_target =
            "struct SPIRV_Cross_Input\n" ++
            "{\n" ++
            "    float2 vUV : TEXCOORD0;\n" ++
            "};\n";
        const input_struct_replacement =
            "struct SPIRV_Cross_Input\n" ++
            "{\n" ++
            "    float4 gl_Position : SV_Position;\n" ++
            "    float2 vUV : TEXCOORD0;\n" ++
            "};\n";

        if (std.mem.indexOf(u8, hlsl, static_vuv) == null) return error.PatternNotFound;
        if (std.mem.indexOf(u8, hlsl, static_frag_color) == null) return error.PatternNotFound;
        if (std.mem.indexOf(u8, hlsl, frag_main_decl) == null) return error.PatternNotFound;
        if (std.mem.indexOf(u8, hlsl, main_body_target) == null) return error.PatternNotFound;

        // Work in an ArrayList; build up via targeted replacements.
        var out: std.ArrayListUnmanaged(u8) = .empty;
        defer out.deinit(alloc);
        try out.appendSlice(alloc, hlsl);

        const replaceOne = struct {
            fn f(a: std.mem.Allocator, buf: *std.ArrayListUnmanaged(u8), needle: []const u8, repl: []const u8) !void {
                const idx = std.mem.indexOf(u8, buf.items, needle) orelse return;
                try buf.replaceRange(a, idx, needle.len, repl);
            }
        }.f;

        try replaceOne(alloc, &out, main_body_target, main_body_replacement);
        try replaceOne(alloc, &out, static_vuv, "\n");
        try replaceOne(alloc, &out, static_frag_color, "\n");
        try replaceOne(
            alloc,
            &out,
            frag_main_decl,
            "\nvoid frag_main(float2 vUV, out float4 zonvie_fragColor)\n",
        );
        // Include SV_Position in the PS input struct so drivers that
        // strictly match VS-output / PS-input signatures accept the
        // pairing with VSCustomPost (which outputs SV_Position +
        // TEXCOORD0).
        try replaceOne(alloc, &out, input_struct_target, input_struct_replacement);

        return out.toOwnedSlice(alloc);
    }

    fn compileCustomShader(
        self: *Renderer,
        dev: *c.ID3D11Device,
        source_path: []const u8,
        preserve_alpha: bool,
    ) CustomShaderCompileError!CustomShaderPipeline {
        const file = std.Io.Dir.cwd().openFile(core.clock.io(), source_path, .{}) catch |e| {
            applog.appLog("[CustomShader] open failed {s}: {any}\n", .{ source_path, e });
            return CustomShaderCompileError.FileOpenFailed;
        };
        defer file.close(core.clock.io());
        var rbuf: [4096]u8 = undefined;
        var fr = file.reader(core.clock.io(), &rbuf);
        const glsl = fr.interface.allocRemaining(self.alloc, .limited(1024 * 1024)) catch {
            return CustomShaderCompileError.FileReadFailed;
        };
        defer self.alloc.free(glsl);
        if (glsl.len == 0) return CustomShaderCompileError.EmptySource;

        // Opt-in alpha preservation: define a macro the core's Shadertoy bridge
        // (#ifdef ZONVIE_PRESERVE_ALPHA) reads to keep the terminal's alpha.
        // Only for Shadertoy-style sources; raw shaders require #version first.
        const want_define = preserve_alpha and std.mem.indexOf(u8, glsl, "mainImage") != null;
        var combined: ?[]u8 = null;
        defer if (combined) |cb| self.alloc.free(cb);
        const src_for_compile: []const u8 = if (want_define) blk: {
            const prefix = "#define ZONVIE_PRESERVE_ALPHA 1\n";
            const buf = self.alloc.alloc(u8, prefix.len + glsl.len) catch
                return CustomShaderCompileError.OutOfMemory;
            @memcpy(buf[0..prefix.len], prefix);
            @memcpy(buf[prefix.len..], glsl);
            combined = buf;
            break :blk buf;
        } else glsl;

        var result = core.zonvie_shader_compile_glsl(
            @ptrCast(src_for_compile.ptr),
            src_for_compile.len,
            .hlsl,
        );
        defer core.zonvie_shader_result_destroy(&result);
        if (result.error_msg) |err_ptr| {
            const err_span = std.mem.span(err_ptr);
            applog.appLog("[CustomShader] GLSL->HLSL failed for {s}: {s}\n", .{ source_path, err_span });
            return CustomShaderCompileError.GlslCompileFailed;
        }
        const hlsl_ptr = result.data orelse return CustomShaderCompileError.GlslCompileFailed;
        const hlsl_len = result.data_len;

        // SPIRV-Cross emits a `static float2 vUV; ... static float4
        // zonvie_fragColor; ... void frag_main() { ... }` pattern where
        // main() writes to the statics, calls frag_main(), and copies
        // the output static into the SPIRV_Cross_Output struct. On at
        // least one Windows D3D11 driver we tested, that cross-function
        // static pattern does not propagate values between main and
        // frag_main — the PS samples iChannel0 at (0,0) for every
        // fragment (effectively `vUV == (0,0)` and later the output
        // static is uninitialized on readback). Post-process the HLSL
        // to convert the static pattern into explicit function
        // arguments, which compiles down to deterministic DXBC that
        // works across all drivers we've tested.
        const patched_hlsl = patchSpvCrossPsStaticPattern(self.alloc, hlsl_ptr[0..hlsl_len]) catch |e| blk: {
            applog.appLog("[CustomShader] patchSpvCrossPsStaticPattern failed: {any} (using original)\n", .{e});
            break :blk null;
        };
        defer if (patched_hlsl) |p| self.alloc.free(p);

        const hlsl_for_compile: []const u8 = patched_hlsl orelse hlsl_ptr[0..hlsl_len];

        applog.appLog("[CustomShader] ---- HLSL BEGIN ({s}, {d} bytes) ----\n", .{ source_path, hlsl_for_compile.len });
        applog.appLog("{s}\n", .{hlsl_for_compile});
        applog.appLog("[CustomShader] ---- HLSL END ----\n", .{});

        var ps_blob: ?*ID3DBlob = null;
        var err_blob: ?*ID3DBlob = null;
        const hr = D3DCompile(
            @ptrCast(hlsl_for_compile.ptr),
            hlsl_for_compile.len,
            null,
            null,
            null,
            "main",
            "ps_5_0",
            0,
            0,
            &ps_blob,
            &err_blob,
        );
        defer blobRelease(err_blob);
        if (c.FAILED(hr)) {
            dumpBlobAsText("[CustomShader] D3DCompile error: ", err_blob);
            applog.appLog("[CustomShader] D3DCompile hr=0x{x} for {s}\n", .{ @as(u32, @bitCast(hr)), source_path });
            return CustomShaderCompileError.HlslCompileFailed;
        }
        // Even on success, D3DCompile may emit warnings via err_blob.
        // Those would hint at unused cbuffer fields, register binding
        // collisions, etc. that can cause silent-black symptoms.
        if (err_blob != null) {
            dumpBlobAsText("[CustomShader] D3DCompile warnings: ", err_blob);
        }
        defer blobRelease(ps_blob);

        const ps_ptr = blobPtr(ps_blob) orelse return CustomShaderCompileError.HlslCompileFailed;
        const ps_size = blobSize(ps_blob);

        var ps_out: ?*c.ID3D11PixelShader = null;
        const dev_vtbl = dev.*.lpVtbl;
        const create_ps = dev_vtbl.*.CreatePixelShader orelse return CustomShaderCompileError.PixelShaderCreateFailed;
        const hr2 = create_ps(dev, ps_ptr, ps_size, null, &ps_out);
        if (c.FAILED(hr2) or ps_out == null) {
            return CustomShaderCompileError.PixelShaderCreateFailed;
        }

        const path_copy = self.alloc.dupe(u8, source_path) catch {
            if (ps_out) |ps| {
                const ps_vtbl = ps.*.lpVtbl;
                if (ps_vtbl.*.Release) |rel| _ = rel(ps);
            }
            return CustomShaderCompileError.OutOfMemory;
        };
        return .{
            .alloc = self.alloc,
            .source_path = path_copy,
            .pixel_shader = ps_out,
            .needs_animation = CustomShaderPipeline.detectNeedsAnimation(glsl),
        };
    }

    /// Update the Ghostty 1.1+ cursor uniforms. rect is (x, y, w, h)
    /// in drawable pixels within the shader "screen" universe (main
    /// window's drawable). color is straight RGBA in [0, 1]. Called
    /// on cursor position/color change only; if the incoming rect and
    /// color match the current state, the call is a no-op so shaders
    /// continue to see the last change's iTimeCursorChange.
    pub fn setCursorShaderState(self: *Renderer, rect: [4]f32, color: [4]f32) void {
        const same_rect =
            rect[0] == self.shader_cursor_current[0] and
            rect[1] == self.shader_cursor_current[1] and
            rect[2] == self.shader_cursor_current[2] and
            rect[3] == self.shader_cursor_current[3];
        const same_color =
            color[0] == self.shader_cursor_current_color[0] and
            color[1] == self.shader_cursor_current_color[1] and
            color[2] == self.shader_cursor_current_color[2] and
            color[3] == self.shader_cursor_current_color[3];
        if (same_rect and same_color) return;

        self.shader_cursor_previous = self.shader_cursor_current;
        self.shader_cursor_previous_color = self.shader_cursor_current_color;
        self.shader_cursor_current = rect;
        self.shader_cursor_current_color = color;

        // iTimeCursorChange is in the same "seconds since shader start"
        // space as iTime, so recompute from QPC here.
        if (self.custom_shader_start_qpc != 0) {
            var freq: c.LARGE_INTEGER = undefined;
            var now: c.LARGE_INTEGER = undefined;
            _ = c.QueryPerformanceFrequency(&freq);
            _ = c.QueryPerformanceCounter(&now);
            const denom: f64 = @floatFromInt(freq.QuadPart);
            self.shader_cursor_change_time =
                @floatCast(@as(f64, @floatFromInt(now.QuadPart - self.custom_shader_start_qpc)) / denom);
        } else {
            self.shader_cursor_change_time = 0;
        }
    }

    /// Populate `custom_shader_uniforms_cb` with Shadertoy-style uniforms
    /// for the current frame. Safe to call every frame; lazily creates
    /// the constant buffer on first use.
    fn updateCustomShaderUniforms(self: *Renderer, ctx: *c.ID3D11DeviceContext, ctx_vtbl: anytype) void {
        if (self.custom_shader_pipelines.items.len == 0) return;

        const dev = self.device orelse return;
        if (self.custom_shader_uniforms_cb == null) {
            var bd: c.D3D11_BUFFER_DESC = std.mem.zeroes(c.D3D11_BUFFER_DESC);
            bd.ByteWidth = @sizeOf(core.zonvie_shader_uniforms);
            bd.Usage = c.D3D11_USAGE_DYNAMIC;
            bd.BindFlags = c.D3D11_BIND_CONSTANT_BUFFER;
            bd.CPUAccessFlags = c.D3D11_CPU_ACCESS_WRITE;
            const dev_vtbl = dev.*.lpVtbl;
            const create_buf = dev_vtbl.*.CreateBuffer orelse return;
            var cb: ?*c.ID3D11Buffer = null;
            if (c.FAILED(create_buf(dev, &bd, null, &cb)) or cb == null) return;
            self.custom_shader_uniforms_cb = cb;
        }
        const cb = self.custom_shader_uniforms_cb orelse return;

        var freq: c.LARGE_INTEGER = undefined;
        var now: c.LARGE_INTEGER = undefined;
        _ = c.QueryPerformanceFrequency(&freq);
        _ = c.QueryPerformanceCounter(&now);
        if (self.custom_shader_start_qpc == 0) {
            self.custom_shader_start_qpc = now.QuadPart;
            self.custom_shader_last_qpc = now.QuadPart;
        }
        const denom: f64 = @floatFromInt(freq.QuadPart);
        const iTime: f32 = @floatCast(@as(f64, @floatFromInt(now.QuadPart - self.custom_shader_start_qpc)) / denom);
        const dt_ticks = now.QuadPart - self.custom_shader_last_qpc;
        const dt: f32 = @floatCast(@as(f64, @floatFromInt(@max(@as(i64, 0), dt_ticks))) / denom);
        self.custom_shader_last_qpc = now.QuadPart;
        if (dt > 0) {
            const instant: f32 = 1.0 / dt;
            self.custom_shader_ema_frame_rate =
                self.custom_shader_ema_frame_rate * 0.9 + instant * 0.1;
        }

        var u: core.zonvie_shader_uniforms = std.mem.zeroes(core.zonvie_shader_uniforms);
        // If an external window set the screen-space override, use it —
        // iResolution is the main window's drawable size (the shader's
        // "universe") and iWindowOffset/iWindowSize locate this HWND
        // within that universe. Otherwise the HWND is its own screen.
        if (self.shader_screen_w != 0 and self.shader_screen_h != 0) {
            u.iResolution[0] = @floatFromInt(self.shader_screen_w);
            u.iResolution[1] = @floatFromInt(self.shader_screen_h);
            u.iWindowOffset[0] = self.shader_window_offset_x;
            u.iWindowOffset[1] = self.shader_window_offset_y;
            u.iWindowSize[0] = @floatFromInt(self.width);
            u.iWindowSize[1] = @floatFromInt(self.height);
        } else {
            u.iResolution[0] = @floatFromInt(self.width);
            u.iResolution[1] = @floatFromInt(self.height);
            u.iWindowOffset[0] = 0;
            u.iWindowOffset[1] = 0;
            u.iWindowSize[0] = @floatFromInt(self.width);
            u.iWindowSize[1] = @floatFromInt(self.height);
        }
        u.iResolution[2] = 1.0;
        u.iTime = iTime;
        u.iTimeDelta = dt;
        u.iFrame = self.custom_shader_frame_index;
        u.iSampleRate = 44100.0;
        u.iFrameRate = self.custom_shader_ema_frame_rate;
        // Ghostty 1.1+ cursor uniforms.
        u.iCurrentCursor = self.shader_cursor_current;
        u.iPreviousCursor = self.shader_cursor_previous;
        u.iCurrentCursorColor = self.shader_cursor_current_color;
        u.iPreviousCursorColor = self.shader_cursor_previous_color;
        u.iTimeCursorChange = self.shader_cursor_change_time;
        // Shadertoy iDate: (year, month [1..12], day, seconds-in-day).
        // Shadertoy's howto just lists the fields as "Year, month, day,
        // time in seconds" without spelling out indexing. Forward
        // SYSTEMTIME.wMonth verbatim (already 1..12) which matches the
        // most common interpretation community shaders assume.
        {
            var st: c.SYSTEMTIME = undefined;
            c.GetLocalTime(&st);
            const secs_in_day: f32 =
                @as(f32, @floatFromInt(st.wHour)) * 3600.0 +
                @as(f32, @floatFromInt(st.wMinute)) * 60.0 +
                @as(f32, @floatFromInt(st.wSecond)) +
                @as(f32, @floatFromInt(st.wMilliseconds)) / 1000.0;
            u.iDate[0] = @floatFromInt(st.wYear);
            u.iDate[1] = @floatFromInt(st.wMonth);
            u.iDate[2] = @floatFromInt(st.wDay);
            u.iDate[3] = secs_in_day;
        }
        // iMouse unimplemented on Windows — stays zero.

        // Map / Unmap — cheap for a 160-byte dynamic CB.
        const map_fn = ctx_vtbl.*.Map orelse return;
        const unmap_fn = ctx_vtbl.*.Unmap orelse return;
        var mapped: c.D3D11_MAPPED_SUBRESOURCE = undefined;
        const hr_map = map_fn(ctx, @ptrCast(cb), 0, c.D3D11_MAP_WRITE_DISCARD, 0, &mapped);
        if (c.FAILED(hr_map)) return;
        @memcpy(@as([*]u8, @ptrCast(mapped.pData))[0..@sizeOf(core.zonvie_shader_uniforms)], @as([*]const u8, @ptrCast(&u))[0..@sizeOf(core.zonvie_shader_uniforms)]);
        unmap_fn(ctx, @ptrCast(cb), 0);

        self.custom_shader_frame_index +%= 1;
    }

    /// Apply the custom shader chain. Reads a scratch copy of back_tex
    /// through `custom_shader_scratch_srv` and writes directly into the
    /// current swapchain backbuffer. This
    /// keeps back_tex untouched between frames, so animation frames
    /// can resample the original terminal contents instead of feeding
    /// the previous shader output back into the shader input (otherwise
    /// starfield/negative recursively compound over time). Returns
    /// `true` when it wrote to the swapchain, so the caller can skip
    /// its own back→bb copy.
    fn drawCustomShaderPass(
        self: *Renderer,
        ctx: *c.ID3D11DeviceContext,
        ctx_vtbl: anytype,
    ) bool {
        const pipelines = self.custom_shader_pipelines.items;
        if (pipelines.len == 0) return false;
        const back = self.back_tex orelse {
            if (applog.isEnabled()) applog.appLog("[CustomShader] skip: back_tex null\n", .{});
            return false;
        };
        // Write into whichever swapchain buffer DXGI says is current.
        // Hardcoding index 0 mismatches the "Present uses current bb"
        // semantics in flip-model configurations where
        // GetCurrentBackBufferIndex actually rotates (IDXGISwapChain3).
        // Never fall back to RTV 0 for a different current index. Returning
        // false makes every caller perform its normal back_tex -> current-bb
        // copy; claiming shader success here would Present an untouched buffer.
        const sc_idx: usize = @intCast(self.currentSwapchainIndex());
        const out_rtv = if (sc_idx < self.bb_rtvs.len) self.bb_rtvs[sc_idx] orelse {
            if (applog.isEnabled()) applog.appLog("[CustomShader] skip: no bb_rtv for idx={d}\n", .{sc_idx});
            return false;
        } else return false;
        // Prefer the custom-post VS (output field name `vUV` matches the
        // SPIRV-Cross PS input). Fall back to VSFullscreen if the custom
        // VS failed to compile — on drivers where the name-match quirk
        // does not apply this still works correctly.
        const vs_fs = self.vs_custom_post orelse self.vs_fullscreen orelse {
            if (applog.isEnabled()) applog.appLog("[CustomShader] skip: vs_custom_post and vs_fullscreen both null\n", .{});
            return false;
        };
        const sampler = self.bilinear_sampler orelse {
            if (applog.isEnabled()) applog.appLog("[CustomShader] skip: bilinear_sampler null\n", .{});
            return false;
        };

        self.ensureCustomShaderScratch();
        if (pipelines.len > 1) self.ensureCustomShaderPong();
        self.updateCustomShaderUniforms(ctx, ctx_vtbl);
        const scratch = self.custom_shader_scratch_tex orelse {
            if (applog.isEnabled()) applog.appLog("[CustomShader] skip: scratch_tex null\n", .{});
            return false;
        };
        const scratch_srv = self.custom_shader_scratch_srv orelse {
            if (applog.isEnabled()) applog.appLog("[CustomShader] skip: scratch_srv null\n", .{});
            return false;
        };
        // For multi-pass chains we need the ping-pong render targets.
        if (pipelines.len > 1) {
            if (self.custom_shader_pong_tex[0] == null or self.custom_shader_pong_tex[1] == null) {
                if (applog.isEnabled()) applog.appLog("[CustomShader] skip: pong textures unavailable\n", .{});
                return false;
            }
        }

        if (applog.isEnabled()) {
            applog.appLog("[CustomShader] draw pass w={d} h={d} passes={d} back=0x{x} scratch=0x{x}\n", .{ self.width, self.height, pipelines.len, @intFromPtr(back), @intFromPtr(scratch) });
        }

        const set_rtvs = ctx_vtbl.*.OMSetRenderTargets orelse return false;

        // Unbind RTVs/SRVs before copying back_tex — a copy on a still-
        // bound RTV turns into hazard-tracked work that has been
        // observed leaving scratch partially populated on some Windows
        // drivers.
        set_rtvs(ctx, 0, null, null);
        if (ctx_vtbl.*.PSSetShaderResources) |set_srvs| {
            var null_srv: [1]?*c.ID3D11ShaderResourceView = .{null};
            set_srvs(ctx, 0, 1, &null_srv[0]);
        }

        // Copy back -> scratch so the first pass has a stable read
        // source. back_tex itself is never rebound as an RTV by this
        // method, so the next frame's sample still reflects the real
        // terminal content instead of our own output.
        if (ctx_vtbl.*.CopyResource) |copy_res| {
            copy_res(ctx, @ptrCast(scratch), @ptrCast(back));
        } else return false;

        // Shared pipeline/state setup (shared by every pass).
        if (ctx_vtbl.*.IASetPrimitiveTopology) |set_topo| {
            set_topo(ctx, c.D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
        }
        if (ctx_vtbl.*.IASetInputLayout) |set_il| set_il(ctx, null);
        if (ctx_vtbl.*.VSSetShader) |set_vs| set_vs(ctx, vs_fs, null, 0);
        if (ctx_vtbl.*.PSSetSamplers) |set_samplers| {
            var samps: [1]?*c.ID3D11SamplerState = .{sampler};
            set_samplers(ctx, 0, 1, &samps[0]);
        }
        if (self.custom_shader_uniforms_cb) |cb| {
            if (ctx_vtbl.*.PSSetConstantBuffers) |set_cbs| {
                var cbs: [1]?*c.ID3D11Buffer = .{cb};
                set_cbs(ctx, 1, 1, &cbs[0]);
            }
        }
        if (ctx_vtbl.*.OMSetBlendState) |set_blend| {
            set_blend(ctx, null, null, 0xFFFFFFFF);
        }
        if (ctx_vtbl.*.RSSetViewports) |set_vp| {
            var vp: c.D3D11_VIEWPORT = .{
                .TopLeftX = 0,
                .TopLeftY = 0,
                .Width = @floatFromInt(self.width),
                .Height = @floatFromInt(self.height),
                .MinDepth = 0.0,
                .MaxDepth = 1.0,
            };
            set_vp(ctx, 1, &vp);
        }
        if (ctx_vtbl.*.RSSetScissorRects) |set_sr| {
            var sr: c.D3D11_RECT = .{
                .left = 0,
                .top = 0,
                .right = @intCast(self.width),
                .bottom = @intCast(self.height),
            };
            set_sr(ctx, 1, &sr);
        }

        // Run each pass in order, ping-ponging between pong[0]/pong[1]
        // until the final pass, which writes directly to bb.
        const set_srvs_fn = ctx_vtbl.*.PSSetShaderResources orelse return false;
        const set_ps_fn = ctx_vtbl.*.PSSetShader orelse return false;
        const draw_fn = ctx_vtbl.*.Draw orelse return false;

        for (pipelines, 0..) |pipeline, i| {
            const ps_i = pipeline.pixel_shader orelse {
                if (applog.isEnabled()) applog.appLog("[CustomShader] skip pass {d}: ps null\n", .{i});
                continue;
            };

            const is_last = (i == pipelines.len - 1);
            const input_srv: *c.ID3D11ShaderResourceView = blk: {
                if (i == 0) break :blk scratch_srv;
                const prev_idx = (i - 1) % 2;
                break :blk self.custom_shader_pong_srv[prev_idx] orelse {
                    if (applog.isEnabled()) applog.appLog("[CustomShader] skip pass {d}: pong_srv[{d}] null\n", .{ i, prev_idx });
                    return false;
                };
            };
            const output_rtv: *c.ID3D11RenderTargetView = blk: {
                if (is_last) break :blk out_rtv;
                const cur_idx = i % 2;
                break :blk self.custom_shader_pong_rtv[cur_idx] orelse {
                    if (applog.isEnabled()) applog.appLog("[CustomShader] skip pass {d}: pong_rtv[{d}] null\n", .{ i, cur_idx });
                    return false;
                };
            };

            // Unbind slot 0 SRV first: the previous pass's output
            // texture must not be simultaneously an RTV and an SRV.
            var null_srv: [1]?*c.ID3D11ShaderResourceView = .{null};
            set_srvs_fn(ctx, 0, 1, &null_srv[0]);

            var rtvs_i: [1]?*c.ID3D11RenderTargetView = .{output_rtv};
            set_rtvs(ctx, 1, &rtvs_i[0], null);

            var in_srvs: [1]?*c.ID3D11ShaderResourceView = .{input_srv};
            set_srvs_fn(ctx, 0, 1, &in_srvs[0]);

            set_ps_fn(ctx, ps_i, null, 0);
            draw_fn(ctx, 3, 0);
        }

        // Restore the main grid pipeline state so later overlays /
        // next-frame prologue don't inherit the custom shader's bindings.
        var atlas_srvs: [1]?*c.ID3D11ShaderResourceView = .{self.atlas_srv};
        set_srvs_fn(ctx, 0, 1, &atlas_srvs[0]);
        if (ctx_vtbl.*.VSSetShader) |set_vs| {
            if (self.vs) |vs_main| set_vs(ctx, vs_main, null, 0);
        }
        if (ctx_vtbl.*.PSSetShader) |set_ps| {
            if (self.ps) |ps_main| set_ps(ctx, ps_main, null, 0);
        }
        if (ctx_vtbl.*.IASetInputLayout) |set_il| {
            if (self.il) |il_main| set_il(ctx, il_main);
        }
        if (ctx_vtbl.*.OMSetBlendState) |set_blend| {
            if (self.blend) |bl| {
                var blend_factor: [4]f32 = .{ 0, 0, 0, 0 };
                set_blend(ctx, bl, &blend_factor, 0xFFFFFFFF);
            }
        }
        return true;
    }

    /// Check whether all glow texture resources (tex/RTV/SRV) were fully created.
    /// Returns false if ensureGlowTextures() returned early due to a partial failure.
    fn glowTexturesComplete(self: *const Renderer) bool {
        if (self.glow_extract_rtv == null or self.glow_extract_srv == null) return false;
        for (self.glow_mip_rtv) |r| {
            if (r == null) return false;
        }
        for (self.glow_mip_srv) |s| {
            if (s == null) return false;
        }
        return true;
    }

    /// Execute post-process bloom: extract → Dual Kawase downsample/upsample → composite.
    pub const BloomRowsDrawFn = *const fn (
        ?*const anyopaque,
        *Renderer,
        *c.ID3D11DeviceContext,
        f32,
        f32,
        f32,
        f32,
    ) void;

    fn drawBloomPasses(
        self: *Renderer,
        ctx: *c.ID3D11DeviceContext,
        ctx_vtbl: anytype,
        main: []const core.Vertex,
        cursor: []const core.Vertex,
        intensity: f32,
        vp_x: u32,
        vp_y: u32,
        vp_w: u32,
        vp_h: u32,
        bloom_rows_ctx: ?*const anyopaque,
        bloom_rows_draw_fn: ?BloomRowsDrawFn,
    ) void {
        const om_set_rt = ctx_vtbl.*.OMSetRenderTargets orelse return;
        const ps_set_fn = ctx_vtbl.*.PSSetShader orelse return;
        const vs_set_fn = ctx_vtbl.*.VSSetShader orelse return;
        const ps_set_srv = ctx_vtbl.*.PSSetShaderResources orelse return;
        const ps_set_samp = ctx_vtbl.*.PSSetSamplers orelse return;
        const om_set_blend = ctx_vtbl.*.OMSetBlendState orelse return;
        const rs_set_vp = ctx_vtbl.*.RSSetViewports orelse return;
        const rs_set_sc = ctx_vtbl.*.RSSetScissorRects orelse return;
        const ia_set_top = ctx_vtbl.*.IASetPrimitiveTopology orelse return;
        const ia_set_il = ctx_vtbl.*.IASetInputLayout orelse return;
        const draw_fn = ctx_vtbl.*.Draw orelse return;
        const clear_rtv = ctx_vtbl.*.ClearRenderTargetView orelse return;

        const hw = self.glow_half_w;
        const hh = self.glow_half_h;

        // --- Pass 1: Glow extract → glow_extract_tex (1/2 res) ---
        // Apply content viewport offset (sidebar/tabline) scaled to half resolution.
        {
            const clear_black: [4]f32 = .{ 0, 0, 0, 0 };
            clear_rtv(ctx, self.glow_extract_rtv.?, &clear_black);

            var rtvs: [1]?*c.ID3D11RenderTargetView = .{self.glow_extract_rtv.?};
            om_set_rt(ctx, 1, @ptrCast(&rtvs), null);

            const ex_x: f32 = @as(f32, @floatFromInt(vp_x)) / 2.0;
            const ex_y: f32 = @as(f32, @floatFromInt(vp_y)) / 2.0;
            const ex_w: f32 = @as(f32, @floatFromInt(vp_w)) / 2.0;
            const ex_h: f32 = @as(f32, @floatFromInt(vp_h)) / 2.0;

            var vp: c.D3D11_VIEWPORT = .{
                .TopLeftX = ex_x,
                .TopLeftY = ex_y,
                .Width = ex_w,
                .Height = ex_h,
                .MinDepth = 0,
                .MaxDepth = 1,
            };
            rs_set_vp(ctx, 1, &vp);

            var sr: c.D3D11_RECT = .{
                .left = @intFromFloat(ex_x),
                .top = @intFromFloat(ex_y),
                .right = @intFromFloat(@ceil(ex_x + ex_w)),
                .bottom = @intFromFloat(@ceil(ex_y + ex_h)),
            };
            rs_set_sc(ctx, 1, &sr);

            ps_set_fn(ctx, self.ps_glow_extract.?, null, 0);

            if (bloom_rows_draw_fn) |draw_rows| {
                draw_rows(bloom_rows_ctx, self, ctx, ex_x, ex_y, ex_w, ex_h);
            } else {
                self.drawVertices(main) catch return;
            }
            self.drawVertices(cursor) catch return;

            ps_set_fn(ctx, self.ps.?, null, 0);
        }

        // Helper: compute mip dimensions
        const mip_widths: [3]u32 = .{
            @max(1, hw / 2),
            @max(1, hw / 4),
            @max(1, hw / 8),
        };
        const mip_heights: [3]u32 = .{
            @max(1, hh / 2),
            @max(1, hh / 4),
            @max(1, hh / 8),
        };

        // Setup common state for fullscreen passes
        vs_set_fn(ctx, self.vs_fullscreen.?, null, 0);
        var blend_factor: [4]f32 = .{ 0, 0, 0, 0 };
        om_set_blend(ctx, null, &blend_factor, 0xFFFFFFFF);
        ia_set_il(ctx, null);
        ia_set_top(ctx, c.D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);

        var samps: [1]?*c.ID3D11SamplerState = .{self.bilinear_sampler.?};
        ps_set_samp(ctx, 1, 1, @ptrCast(&samps));

        // --- Downsample chain: extract → mip[0] → mip[1] → mip[2] ---
        for (0..3) |level| {
            // Unbind SRV slot 1 to avoid RTV/SRV hazard
            var null_srvs: [1]?*c.ID3D11ShaderResourceView = .{null};
            ps_set_srv(ctx, 1, 1, @ptrCast(&null_srvs));

            var rtvs: [1]?*c.ID3D11RenderTargetView = .{self.glow_mip_rtv[level].?};
            om_set_rt(ctx, 1, @ptrCast(&rtvs), null);

            var vp: c.D3D11_VIEWPORT = .{
                .TopLeftX = 0,
                .TopLeftY = 0,
                .Width = @floatFromInt(mip_widths[level]),
                .Height = @floatFromInt(mip_heights[level]),
                .MinDepth = 0,
                .MaxDepth = 1,
            };
            rs_set_vp(ctx, 1, &vp);

            var sr: c.D3D11_RECT = .{
                .left = 0,
                .top = 0,
                .right = @intCast(mip_widths[level]),
                .bottom = @intCast(mip_heights[level]),
            };
            rs_set_sc(ctx, 1, &sr);

            // Source: extract for level 0, mip[level-1] otherwise
            const src_srv = if (level == 0) self.glow_extract_srv.? else self.glow_mip_srv[level - 1].?;
            var srvs: [1]?*c.ID3D11ShaderResourceView = .{src_srv};
            ps_set_srv(ctx, 1, 1, @ptrCast(&srvs));

            ps_set_fn(ctx, self.ps_kawase_down.?, null, 0);
            draw_fn(ctx, 3, 0);
        }

        // --- Upsample chain: mip[2] → mip[1] → mip[0] → extractTex ---
        for (0..3) |i| {
            const level = 2 - i;

            // Unbind SRV slot 1
            var null_srvs: [1]?*c.ID3D11ShaderResourceView = .{null};
            ps_set_srv(ctx, 1, 1, @ptrCast(&null_srvs));

            // Destination: mip[level-1] for level > 0, extract for level 0
            const dst_rtv = if (level == 0) self.glow_extract_rtv.? else self.glow_mip_rtv[level - 1].?;
            var rtvs: [1]?*c.ID3D11RenderTargetView = .{dst_rtv};
            om_set_rt(ctx, 1, @ptrCast(&rtvs), null);

            // Viewport = destination size
            const dst_w: u32 = if (level == 0) hw else mip_widths[level - 1];
            const dst_h: u32 = if (level == 0) hh else mip_heights[level - 1];

            var vp: c.D3D11_VIEWPORT = .{
                .TopLeftX = 0,
                .TopLeftY = 0,
                .Width = @floatFromInt(dst_w),
                .Height = @floatFromInt(dst_h),
                .MinDepth = 0,
                .MaxDepth = 1,
            };
            rs_set_vp(ctx, 1, &vp);

            var sr: c.D3D11_RECT = .{
                .left = 0,
                .top = 0,
                .right = @intCast(dst_w),
                .bottom = @intCast(dst_h),
            };
            rs_set_sc(ctx, 1, &sr);

            // Source: mip[level] (the smaller texture we're upsampling from)
            var srvs: [1]?*c.ID3D11ShaderResourceView = .{self.glow_mip_srv[level].?};
            ps_set_srv(ctx, 1, 1, @ptrCast(&srvs));

            ps_set_fn(ctx, self.ps_kawase_up.?, null, 0);
            draw_fn(ctx, 3, 0);
        }

        // --- Composite → back buffer (additive blend) ---
        {
            var null_srvs: [1]?*c.ID3D11ShaderResourceView = .{null};
            ps_set_srv(ctx, 1, 1, @ptrCast(&null_srvs));

            var rtvs: [1]?*c.ID3D11RenderTargetView = .{self.back_rtv.?};
            om_set_rt(ctx, 1, @ptrCast(&rtvs), null);

            var vp: c.D3D11_VIEWPORT = .{
                .TopLeftX = 0,
                .TopLeftY = 0,
                .Width = @floatFromInt(self.width),
                .Height = @floatFromInt(self.height),
                .MinDepth = 0,
                .MaxDepth = 1,
            };
            rs_set_vp(ctx, 1, &vp);

            var sr: c.D3D11_RECT = .{
                .left = 0,
                .top = 0,
                .right = @intCast(self.width),
                .bottom = @intCast(self.height),
            };
            rs_set_sc(ctx, 1, &sr);

            var srvs: [1]?*c.ID3D11ShaderResourceView = .{self.glow_extract_srv.?};
            ps_set_srv(ctx, 1, 1, @ptrCast(&srvs));

            const gcb_res: *c.ID3D11Resource = @ptrCast(self.glow_cb.?);
            var mapped: c.D3D11_MAPPED_SUBRESOURCE = undefined;
            const hr_map = mapDiscard(ctx, gcb_res, &mapped);
            if (!c.FAILED(hr_map)) {
                const dst: *[4]f32 = @ptrCast(@alignCast(mapped.pData));
                dst.* = .{ intensity, 0, 0, 0 };
                unmap0(ctx, gcb_res);
            }

            const ps_set_cb = ctx_vtbl.*.PSSetConstantBuffers orelse return;
            var cbs: [1]?*c.ID3D11Buffer = .{self.glow_cb.?};
            ps_set_cb(ctx, 0, 1, @ptrCast(&cbs));

            om_set_blend(ctx, self.additive_blend.?, &blend_factor, 0xFFFFFFFF);

            ps_set_fn(ctx, self.ps_glow_composite.?, null, 0);

            draw_fn(ctx, 3, 0);

            // --- Restore state ---
            ps_set_srv(ctx, 1, 1, @ptrCast(&null_srvs));

            var null_cbs: [1]?*c.ID3D11Buffer = .{null};
            ps_set_cb(ctx, 0, 1, @ptrCast(&null_cbs));

            vs_set_fn(ctx, self.vs.?, null, 0);
            ps_set_fn(ctx, self.ps.?, null, 0);
            om_set_blend(ctx, self.blend.?, &blend_factor, 0xFFFFFFFF);
            ia_set_il(ctx, self.il.?);

            var atlas_srvs: [1]?*c.ID3D11ShaderResourceView = .{self.atlas_srv};
            ps_set_srv(ctx, 0, 1, @ptrCast(&atlas_srvs));

            // Restore the caller's original content-offset viewport/scissor
            // (vp_x/vp_y/vp_w/vp_h, as passed in) instead of leaving the
            // full-window viewport/scissor this Composite pass just set —
            // otherwise a caller relying on drawEx's own re-set-at-entry
            // viewport (which currently masks this) would see incorrect
            // clipping if that assumption ever changes.
            var restore_vp: c.D3D11_VIEWPORT = .{
                .TopLeftX = @floatFromInt(vp_x),
                .TopLeftY = @floatFromInt(vp_y),
                .Width = @floatFromInt(vp_w),
                .Height = @floatFromInt(vp_h),
                .MinDepth = 0,
                .MaxDepth = 1,
            };
            rs_set_vp(ctx, 1, &restore_vp);

            var restore_sr: c.D3D11_RECT = .{
                .left = @intCast(vp_x),
                .top = @intCast(vp_y),
                .right = @intCast(vp_x + vp_w),
                .bottom = @intCast(vp_y + vp_h),
            };
            rs_set_sc(ctx, 1, &restore_sr);
        }
    }

    /// Public entry point for bloom passes (used by row-mode rendering).
    /// Requires vertices to be passed in (collected from row VBs).
    pub fn drawBloomFromVerts(self: *Renderer, main: []const core.Vertex, cursor: []const core.Vertex, intensity: f32, vp_x: u32, vp_y: u32, vp_w: u32, vp_h: u32) void {
        if (!self.bloomShadersReady()) return;
        self.ensureGlowTextures();
        if (!self.glowTexturesComplete()) return;
        const ctx = self.ctx orelse return;
        const ctx_vtbl = ctx.*.lpVtbl;
        self.drawBloomPasses(ctx, ctx_vtbl, main, cursor, intensity, vp_x, vp_y, vp_w, vp_h, null, null);
    }

    /// Bloom entry point for row-mode rendering. The callback redraws the
    /// already-uploaded row VBs into the extract target, avoiding a full CPU
    /// vertex gather and re-upload on every paint.
    pub fn drawBloomFromRowBuffers(
        self: *Renderer,
        rows_ctx: *const anyopaque,
        draw_rows_fn: BloomRowsDrawFn,
        cursor: []const core.Vertex,
        intensity: f32,
        vp_x: u32,
        vp_y: u32,
        vp_w: u32,
        vp_h: u32,
    ) void {
        if (!self.bloomShadersReady()) return;
        self.ensureGlowTextures();
        if (!self.glowTexturesComplete()) return;
        const ctx = self.ctx orelse return;
        const ctx_vtbl = ctx.*.lpVtbl;
        self.drawBloomPasses(ctx, ctx_vtbl, &.{}, cursor, intensity, vp_x, vp_y, vp_w, vp_h, rows_ctx, draw_rows_fn);
    }

    const AtlasTextureObjects = struct {
        tex: *c.ID3D11Texture2D,
        srv: *c.ID3D11ShaderResourceView,
    };

    fn buildAtlasTexture(self: *Renderer, w: u32, h: u32) !AtlasTextureObjects {
        const dev = self.device.?;

        var td: c.D3D11_TEXTURE2D_DESC = std.mem.zeroes(c.D3D11_TEXTURE2D_DESC);
        td.Width = w;
        td.Height = h;
        td.MipLevels = 1;
        td.ArraySize = 1;
        td.Format = c.DXGI_FORMAT_R8G8B8A8_UNORM;
        td.SampleDesc.Count = 1;
        td.Usage = c.D3D11_USAGE_DEFAULT;
        td.BindFlags = c.D3D11_BIND_SHADER_RESOURCE;

        const dev_vtbl = dev.*.lpVtbl;

        // ID3D11Device::CreateTexture2D (vtbl call)
        var tex: ?*c.ID3D11Texture2D = null;
        const create_tex2d = dev_vtbl.*.CreateTexture2D orelse return error.D3DCreateAtlasTexFailed;
        const hr_tex = create_tex2d(dev, &td, null, @ptrCast(&tex));
        if (c.FAILED(hr_tex) or tex == null) return error.D3DCreateAtlasTexFailed;
        // ID3D11Device::CreateShaderResourceView (vtbl call)
        var srv: ?*c.ID3D11ShaderResourceView = null;
        const create_srv = dev_vtbl.*.CreateShaderResourceView orelse {
            safeRelease(tex);
            return error.D3DCreateAtlasSRVFailed;
        };

        // pResource expects ID3D11Resource*
        const hr_srv = create_srv(dev, @ptrCast(tex.?), null, @ptrCast(&srv));
        if (c.FAILED(hr_srv) or srv == null) {
            safeRelease(tex);
            return error.D3DCreateAtlasSRVFailed;
        }
        return .{ .tex = tex.?, .srv = srv.? };
    }

    fn createAtlasTexture(self: *Renderer, w: u32, h: u32) !void {
        const built = try self.buildAtlasTexture(w, h);
        self.atlas_tex = built.tex;
        self.atlas_srv = built.srv;
    }

    /// Recreate atlas texture if dimensions changed. No-op for same-size resets.
    /// Returns error if D3D texture creation fails (caller should terminate).
    pub fn recreateAtlasTextureIfNeeded(self: *Renderer, w: u32, h: u32) !void {
        if (w == self.atlas_w and h == self.atlas_h) return;

        // Build first so a transient OOM/device error keeps the current atlas
        // usable and leaves the same-size request retryable.
        const built = try self.buildAtlasTexture(w, h);
        const old_srv = self.atlas_srv;
        const old_tex = self.atlas_tex;
        self.atlas_tex = built.tex;
        self.atlas_srv = built.srv;
        self.atlas_w = w;
        self.atlas_h = h;
        safeRelease(old_srv);
        safeRelease(old_tex);
        dbgLog("[d3d] recreateAtlasTextureIfNeeded: {d}x{d}\n", .{ w, h });
    }

    fn createPipeline(self: *Renderer) !void {
        const dev = self.device.?;

        // NOTE:
        // VertexGen already outputs NDC (-1..1) in Vertex.position.
        // So VS must treat POSITION as NDC and pass through.
        //
        // Decoration flags (must match ZONVIE_DECO_* in zonvie_core.h):
        // DECO_UNDERCURL     = 1 << 0
        // DECO_UNDERLINE     = 1 << 1
        // DECO_UNDERDOUBLE   = 1 << 2
        // DECO_UNDERDOTTED   = 1 << 3
        // DECO_UNDERDASHED   = 1 << 4
        // DECO_STRIKETHROUGH = 1 << 5
        // HLSL source loaded from single source of truth (main.hlsl).
        // Used only as runtime fallback when pre-compiled bytecode is not available.
        const hlsl = @embedFile("../shaders/main.hlsl");

        // Use pre-compiled bytecode if available, otherwise compile at runtime
        var vs_blob: ?*ID3DBlob = null;
        var ps_blob: ?*ID3DBlob = null;
        var err_blob: ?*ID3DBlob = null;
        defer blobRelease(err_blob);
        defer blobRelease(vs_blob);
        defer blobRelease(ps_blob);

        var vs_p: ?*const anyopaque = null;
        var vs_n: usize = 0;
        var ps_p: ?*const anyopaque = null;
        var ps_n: usize = 0;

        // Decide at comptime whether pre-compiled bytecode is usable.
        // If the HLSL source has changed since bytecodes were generated (hash mismatch),
        // fall back to runtime compilation to guarantee correctness.
        const use_precompiled = comptime blk: {
            @setEvalBranchQuota(1_000_000);
            if (compiled_shaders.vs_bytecode.len == 0 or compiled_shaders.ps_bytecode.len == 0)
                break :blk false;
            if (compiled_shaders.hlsl_sha256.len == 0)
                break :blk true; // no hash recorded — trust the bytecode
            // LF-normalize embedded HLSL and compute SHA256
            var normalized: [hlsl.len]u8 = undefined;
            var out_len: usize = 0;
            for (hlsl) |byte| {
                if (byte == '\r') continue;
                normalized[out_len] = byte;
                out_len += 1;
            }
            var h = std.crypto.hash.sha2.Sha256.init(.{});
            h.update(normalized[0..out_len]);
            const digest = h.finalResult();
            const hex_chars = "0123456789abcdef";
            var hex: [64]u8 = undefined;
            for (digest, 0..) |b, j| {
                hex[j * 2] = hex_chars[b >> 4];
                hex[j * 2 + 1] = hex_chars[b & 0x0f];
            }
            break :blk std.mem.eql(u8, &hex, compiled_shaders.hlsl_sha256);
        };

        if (use_precompiled) {
            dbgLog("[d3d] Using pre-compiled shader bytecode\n", .{});
            vs_p = @ptrCast(&compiled_shaders.vs_bytecode);
            vs_n = compiled_shaders.vs_bytecode.len;
            ps_p = @ptrCast(&compiled_shaders.ps_bytecode);
            ps_n = compiled_shaders.ps_bytecode.len;
        } else {
            // Compile at runtime (slow path)
            const has_bytecode = compiled_shaders.vs_bytecode.len > 0 and compiled_shaders.ps_bytecode.len > 0;
            if (has_bytecode) {
                dbgLog("[d3d] WARNING: main.hlsl changed since shaders were pre-compiled — falling back to runtime compilation\n", .{});
            } else {
                dbgLog("[d3d] Compiling shaders at runtime (pre-compiled bytecode not available)\n", .{});
            }

            const hr_vs = D3DCompile(hlsl.ptr, hlsl.len, null, null, null, "VSMain", "vs_5_0", 0, 0, &vs_blob, &err_blob);
            if (hr_vs != 0 or vs_blob == null) {
                dumpBlobAsText("[D3DCompile VS] ", err_blob);
                return error.D3DCompileVSFailed;
            }

            const hr_ps = D3DCompile(hlsl.ptr, hlsl.len, null, null, null, "PSMain", "ps_5_0", 0, 0, &ps_blob, &err_blob);
            if (hr_ps != 0 or ps_blob == null) {
                dumpBlobAsText("[D3DCompile PS] ", err_blob);
                return error.D3DCompilePSFailed;
            }

            vs_p = blobPtr(vs_blob) orelse return error.D3DCompileVSFailed;
            vs_n = blobSize(vs_blob);
            if (vs_n == 0) return error.D3DCompileVSFailed;

            ps_p = blobPtr(ps_blob) orelse return error.D3DCompilePSFailed;
            ps_n = blobSize(ps_blob);
            if (ps_n == 0) return error.D3DCompilePSFailed;
        }

        const dev_vtbl = dev.*.lpVtbl;

        // --- Create VS (vtbl call; avoids anytype/@ptrCast issue)
        {
            const create_vs = dev_vtbl.*.CreateVertexShader orelse return error.D3DCreateVSFailed;
            var vs: ?*c.ID3D11VertexShader = null;
            const hr = create_vs(dev, vs_p, vs_n, null, &vs);
            if (c.FAILED(hr) or vs == null) return error.D3DCreateVSFailed;
            self.vs = vs;
        }

        // --- Create PS (vtbl call)
        {
            const create_ps = dev_vtbl.*.CreatePixelShader orelse return error.D3DCreatePSFailed;
            var ps: ?*c.ID3D11PixelShader = null;
            const hr = create_ps(dev, ps_p, ps_n, null, &ps);
            if (c.FAILED(hr) or ps == null) return error.D3DCreatePSFailed;
            self.ps = ps;
        }

        // --- Input layout
        // Vertex layout (48 bytes total, must match c_api.Vertex):
        //   position:   [2]f32 @ offset 0
        //   texCoord:   [2]f32 @ offset 8
        //   color:      [4]f32 @ offset 16 (aligned to 16)
        //   grid_id:    i64    @ offset 32
        //   deco_flags: u32    @ offset 40
        //   deco_phase: f32    @ offset 44
        var il_desc: [6]c.D3D11_INPUT_ELEMENT_DESC = .{
            .{ .SemanticName = "POSITION", .SemanticIndex = 0, .Format = c.DXGI_FORMAT_R32G32_FLOAT, .InputSlot = 0, .AlignedByteOffset = 0, .InputSlotClass = c.D3D11_INPUT_PER_VERTEX_DATA, .InstanceDataStepRate = 0 },
            .{ .SemanticName = "TEXCOORD", .SemanticIndex = 0, .Format = c.DXGI_FORMAT_R32G32_FLOAT, .InputSlot = 0, .AlignedByteOffset = 8, .InputSlotClass = c.D3D11_INPUT_PER_VERTEX_DATA, .InstanceDataStepRate = 0 },
            .{ .SemanticName = "COLOR", .SemanticIndex = 0, .Format = c.DXGI_FORMAT_R32G32B32A32_FLOAT, .InputSlot = 0, .AlignedByteOffset = 16, .InputSlotClass = c.D3D11_INPUT_PER_VERTEX_DATA, .InstanceDataStepRate = 0 },
            .{ .SemanticName = "BLENDINDICES", .SemanticIndex = 0, .Format = c.DXGI_FORMAT_R32G32_SINT, .InputSlot = 0, .AlignedByteOffset = 32, .InputSlotClass = c.D3D11_INPUT_PER_VERTEX_DATA, .InstanceDataStepRate = 0 }, // grid_id (i64 as int2)
            .{ .SemanticName = "BLENDINDICES", .SemanticIndex = 1, .Format = c.DXGI_FORMAT_R32_UINT, .InputSlot = 0, .AlignedByteOffset = 40, .InputSlotClass = c.D3D11_INPUT_PER_VERTEX_DATA, .InstanceDataStepRate = 0 }, // deco_flags
            .{ .SemanticName = "TEXCOORD", .SemanticIndex = 1, .Format = c.DXGI_FORMAT_R32_FLOAT, .InputSlot = 0, .AlignedByteOffset = 44, .InputSlotClass = c.D3D11_INPUT_PER_VERTEX_DATA, .InstanceDataStepRate = 0 }, // deco_phase
        };

        {
            const create_il = dev_vtbl.*.CreateInputLayout orelse return error.D3DCreateILFailed;
            var il: ?*c.ID3D11InputLayout = null;
            const hr = create_il(dev, &il_desc, il_desc.len, vs_p, vs_n, &il);
            if (c.FAILED(hr) or il == null) return error.D3DCreateILFailed;
            self.il = il;
        }

        // --- VS constant buffer (dynamic, 16 bytes)
        {
            const create_buf = dev_vtbl.*.CreateBuffer orelse return error.D3DCreateVSCBFailed;

            var bd: c.D3D11_BUFFER_DESC = std.mem.zeroes(c.D3D11_BUFFER_DESC);
            bd.ByteWidth = 16;
            bd.Usage = c.D3D11_USAGE_DYNAMIC;
            bd.BindFlags = c.D3D11_BIND_CONSTANT_BUFFER;
            bd.CPUAccessFlags = c.D3D11_CPU_ACCESS_WRITE;

            var cb: ?*c.ID3D11Buffer = null;
            const hr = create_buf(dev, &bd, null, &cb);
            if (c.FAILED(hr) or cb == null) return error.D3DCreateVSCBFailed;
            self.vs_cb = cb;
        }

        // --- Sampler
        {
            const create_samp = dev_vtbl.*.CreateSamplerState orelse return error.D3DCreateSamplerFailed;

            var sd: c.D3D11_SAMPLER_DESC = std.mem.zeroes(c.D3D11_SAMPLER_DESC);
            sd.Filter = c.D3D11_FILTER_MIN_MAG_MIP_POINT;
            sd.AddressU = c.D3D11_TEXTURE_ADDRESS_CLAMP;
            sd.AddressV = c.D3D11_TEXTURE_ADDRESS_CLAMP;
            sd.AddressW = c.D3D11_TEXTURE_ADDRESS_CLAMP;
            sd.MaxLOD = c.D3D11_FLOAT32_MAX;

            var samp: ?*c.ID3D11SamplerState = null;
            const hr = create_samp(dev, &sd, &samp);
            if (c.FAILED(hr) or samp == null) return error.D3DCreateSamplerFailed;
            self.sampler = samp;
        }

        // --- Blend
        {
            const create_blend = dev_vtbl.*.CreateBlendState orelse return error.D3DCreateBlendFailed;

            // Premultiplied alpha blending for ClearType subpixel rendering
            // SrcBlend=ONE: use premultiplied color (fg * coverage) as-is
            // DestBlend=INV_SRC_ALPHA: blend background with (1 - alpha)
            var bd: c.D3D11_BLEND_DESC = std.mem.zeroes(c.D3D11_BLEND_DESC);
            bd.AlphaToCoverageEnable = c.FALSE;
            bd.RenderTarget[0].BlendEnable = c.TRUE;
            bd.RenderTarget[0].SrcBlend = c.D3D11_BLEND_ONE;
            bd.RenderTarget[0].DestBlend = c.D3D11_BLEND_INV_SRC_ALPHA;
            bd.RenderTarget[0].BlendOp = c.D3D11_BLEND_OP_ADD;
            bd.RenderTarget[0].SrcBlendAlpha = c.D3D11_BLEND_ONE;
            bd.RenderTarget[0].DestBlendAlpha = c.D3D11_BLEND_INV_SRC_ALPHA;
            bd.RenderTarget[0].BlendOpAlpha = c.D3D11_BLEND_OP_ADD;
            bd.RenderTarget[0].RenderTargetWriteMask = 0x0F;

            var blend: ?*c.ID3D11BlendState = null;
            const hr = create_blend(dev, &bd, &blend);
            if (c.FAILED(hr) or blend == null) return error.D3DCreateBlendFailed;
            self.blend = blend;
        }

        // --- Rasterizer (disable cull + enable scissor)
        {
            const create_rs = dev_vtbl.*.CreateRasterizerState orelse return error.D3DCreateRasterizerFailed;

            var rd: c.D3D11_RASTERIZER_DESC = std.mem.zeroes(c.D3D11_RASTERIZER_DESC);
            rd.FillMode = c.D3D11_FILL_SOLID;
            rd.CullMode = c.D3D11_CULL_NONE; // ★ Without this, CW-generated quads are all culled
            rd.ScissorEnable = c.TRUE; // ★ For dirty rect (enable RSSetScissorRects)
            rd.DepthClipEnable = c.TRUE;

            var rs: ?*c.ID3D11RasterizerState = null;
            const hr = create_rs(dev, &rd, &rs);
            if (c.FAILED(hr) or rs == null) return error.D3DCreateRasterizerFailed;
            self.rs = rs;
        }

        // Bloom shaders are compiled lazily on first use (see
        // prepareBloomShaders). Skipping 5 D3DCompile calls here keeps
        // startup quick for configs that never enable glow.

        // --- Additive blend state (ONE, ONE) for bloom composite ---
        {
            const create_blend = dev_vtbl.*.CreateBlendState orelse return error.D3DCreateBlendFailed;

            var abd: c.D3D11_BLEND_DESC = std.mem.zeroes(c.D3D11_BLEND_DESC);
            abd.RenderTarget[0].BlendEnable = c.TRUE;
            abd.RenderTarget[0].SrcBlend = c.D3D11_BLEND_ONE;
            abd.RenderTarget[0].DestBlend = c.D3D11_BLEND_ONE;
            abd.RenderTarget[0].BlendOp = c.D3D11_BLEND_OP_ADD;
            abd.RenderTarget[0].SrcBlendAlpha = c.D3D11_BLEND_ONE;
            abd.RenderTarget[0].DestBlendAlpha = c.D3D11_BLEND_ONE;
            abd.RenderTarget[0].BlendOpAlpha = c.D3D11_BLEND_OP_ADD;
            abd.RenderTarget[0].RenderTargetWriteMask = 0x0F;

            var ab: ?*c.ID3D11BlendState = null;
            const hr_ab = create_blend(dev, &abd, &ab);
            if (c.FAILED(hr_ab) or ab == null) return error.D3DCreateBlendFailed;
            self.additive_blend = ab;
        }

        // --- Bilinear sampler for bloom blur ---
        {
            const create_samp = dev_vtbl.*.CreateSamplerState orelse return error.D3DCreateSamplerFailed;

            var sd: c.D3D11_SAMPLER_DESC = std.mem.zeroes(c.D3D11_SAMPLER_DESC);
            sd.Filter = c.D3D11_FILTER_MIN_MAG_LINEAR_MIP_POINT;
            sd.AddressU = c.D3D11_TEXTURE_ADDRESS_CLAMP;
            sd.AddressV = c.D3D11_TEXTURE_ADDRESS_CLAMP;
            sd.AddressW = c.D3D11_TEXTURE_ADDRESS_CLAMP;
            sd.MaxLOD = c.D3D11_FLOAT32_MAX;

            var bsamp: ?*c.ID3D11SamplerState = null;
            const hr_bs = create_samp(dev, &sd, &bsamp);
            if (c.FAILED(hr_bs) or bsamp == null) return error.D3DCreateSamplerFailed;
            self.bilinear_sampler = bsamp;
        }

        // --- Glow constant buffer (16 bytes: float intensity + padding) ---
        {
            const create_buf = dev_vtbl.*.CreateBuffer orelse return error.D3DCreateVSCBFailed;

            var cbd: c.D3D11_BUFFER_DESC = std.mem.zeroes(c.D3D11_BUFFER_DESC);
            cbd.ByteWidth = 16;
            cbd.Usage = c.D3D11_USAGE_DYNAMIC;
            cbd.BindFlags = c.D3D11_BIND_CONSTANT_BUFFER;
            cbd.CPUAccessFlags = c.D3D11_CPU_ACCESS_WRITE;

            var gcb: ?*c.ID3D11Buffer = null;
            const hr_gcb = create_buf(dev, &cbd, null, &gcb);
            if (c.FAILED(hr_gcb) or gcb == null) return error.D3DCreateVSCBFailed;
            self.glow_cb = gcb;
        }

        // --- Layer transform constant buffer (32 bytes: 4 x float2) ---
        {
            const create_buf = dev_vtbl.*.CreateBuffer orelse return error.D3DCreateVSCBFailed;

            var cbd: c.D3D11_BUFFER_DESC = std.mem.zeroes(c.D3D11_BUFFER_DESC);
            cbd.ByteWidth = 32;
            cbd.Usage = c.D3D11_USAGE_DYNAMIC;
            cbd.BindFlags = c.D3D11_BIND_CONSTANT_BUFFER;
            cbd.CPUAccessFlags = c.D3D11_CPU_ACCESS_WRITE;

            var lcb: ?*c.ID3D11Buffer = null;
            const hr_lcb = create_buf(dev, &cbd, null, &lcb);
            if (c.FAILED(hr_lcb) or lcb == null) return error.D3DCreateVSCBFailed;
            self.layer_cb = lcb;
            self.layer_cb_valid = false;
        }
    }

    /// Bind the vertex stage's layer transform. Every draw afterwards uses it
    /// until it is set again. `extent_px` is the pixel space incoming vertices
    /// are expressed in; pass 0 for both to submit clip-space vertices under
    /// the identity transform.
    pub fn setLayerTransform(
        self: *Renderer,
        origin_x_px: f32,
        origin_y_px: f32,
        extent_w_px: f32,
        extent_h_px: f32,
    ) void {
        const value: [8]f32 = if (extent_w_px <= 0 or extent_h_px <= 0)
            .{ 1, 1, 0, 0, 0, 0, 0, 0 }
        else .{
            2.0 / extent_w_px,
            -2.0 / extent_h_px,
            origin_x_px * 2.0 / extent_w_px - 1.0,
            1.0 - origin_y_px * 2.0 / extent_h_px,
            origin_x_px,
            origin_y_px,
            0,
            0,
        };
        const ctx = self.ctx orelse return;
        const ctx_vtbl = ctx.*.lpVtbl orelse return;
        const cb = self.layer_cb orelse return;

        if (self.layer_cb_valid and std.mem.eql(f32, &self.layer_cb_value, &value)) {
            // Already resident; the binding below is idempotent but cheap.
        } else {
            const res: *c.ID3D11Resource = @ptrCast(cb);
            var mapped: c.D3D11_MAPPED_SUBRESOURCE = undefined;
            const hr = mapDiscard(ctx, res, &mapped);
            if (c.FAILED(hr)) return;
            const dst: *[8]f32 = @ptrCast(@alignCast(mapped.pData));
            dst.* = value;
            unmap0(ctx, res);
            self.layer_cb_value = value;
            self.layer_cb_valid = true;
        }

        if (ctx_vtbl.*.VSSetConstantBuffers) |set_cbs| {
            var cbs: [1]?*c.ID3D11Buffer = .{cb};
            set_cbs(ctx, 0, 1, @ptrCast(&cbs));
        }
    }

    fn ensureVertexBuffer(self: *Renderer, need_bytes: usize) !void {
        if (self.vb != null and self.vb_bytes >= need_bytes) return;

        safeRelease(&self.vb);

        self.vb_bytes = @max(need_bytes, 1024 * @sizeOf(core.Vertex));

        const dev = self.device.?;

        var bd: c.D3D11_BUFFER_DESC = std.mem.zeroes(c.D3D11_BUFFER_DESC);
        bd.ByteWidth = @intCast(self.vb_bytes);
        bd.Usage = c.D3D11_USAGE_DYNAMIC;
        bd.BindFlags = c.D3D11_BIND_VERTEX_BUFFER;
        bd.CPUAccessFlags = c.D3D11_CPU_ACCESS_WRITE;

        var vb: ?*c.ID3D11Buffer = null;
        const dev_vtbl = dev.*.lpVtbl;
        const create_buf = dev_vtbl.*.CreateBuffer orelse return error.D3DCreateVBFalied;

        const hr_vb = create_buf(dev, &bd, null, @ptrCast(&vb));
        if (c.FAILED(hr_vb) or vb == null) return error.D3DCreateVBFalied;

        self.vb = vb;
    }
};

/// Returns true if `hr` indicates the D3D device itself is gone (driver
/// crash/update/TDR). Present/ResizeBuffers/Present1 can all return these.
fn isDeviceLost(hr: c.HRESULT) bool {
    return hr == c.DXGI_ERROR_DEVICE_REMOVED or hr == c.DXGI_ERROR_DEVICE_RESET or hr == c.DXGI_ERROR_DEVICE_HUNG;
}

fn addRef(p: anytype) void {
    const unk: *c.IUnknown = @ptrCast(p);
    const vtbl = unk.*.lpVtbl;
    const ar = vtbl.*.AddRef orelse return;
    _ = ar(unk);
}

fn safeRelease(p: anytype) void {
    const T = @TypeOf(p);

    const releaseOne = struct {
        fn run(q: anytype) void {
            // Every COM interface begins with IUnknown vtbl.
            const unk: *c.IUnknown = @ptrCast(q);
            const vtbl = unk.*.lpVtbl;
            const rel = vtbl.*.Release orelse return;
            _ = rel(unk);
        }
    }.run;

    // NOTE:
    // - switch(@typeInfo(T)) is already comptime because T is comptime-known,
    //   but we must NOT use `comptime switch` (it forces comptime evaluation of runtime values).
    switch (@typeInfo(T)) {
        .pointer => |pi| {
            // Expect: pointer to optional COM pointer, e.g. *?*c.ID3D11Buffer
            const Child = pi.child;

            comptime {
                if (@typeInfo(Child) != .optional) {
                    @compileError("safeRelease: pointer must point to an optional type (e.g. *?*T)");
                }
            }

            if (p.*) |q| {
                releaseOne(q);
                p.* = null;
            }
        },
        .optional => {
            // Backward-compatible: safeRelease(self.some_optional)
            if (p) |q| {
                releaseOne(q);
            }
        },
        else => comptime {
            @compileError("safeRelease: expected optional or pointer-to-optional");
        },
    }
}
fn dbgLog(comptime fmt: []const u8, args: anytype) void {
    if (builtin.mode != .Debug) return;
    std.debug.print(fmt, args);
}
