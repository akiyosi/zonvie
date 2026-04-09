const std = @import("std");
const builtin = @import("builtin");
const core = @import("zonvie_core");
const c = @import("../win32.zig").c;
const applog = @import("../app_log.zig");
const compiled_shaders = @import("../shaders/compiled_shaders.zig");

const MaxSwapchainBuffers: usize = 4;

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
    const get_sz  = p.lpVtbl.GetBufferSize orelse return;

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
    ctx_mu: std.Thread.Mutex = .{},

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

    // Persistent back buffer (like macOS backBuffer)
    back_tex: ?*c.ID3D11Texture2D = null,
    back_rtv: ?*c.ID3D11RenderTargetView = null,

    // Staging texture for back_tex scroll (same size/format, lazily created)
    scroll_staging_tex: ?*c.ID3D11Texture2D = null,

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
    ps_glow_extract: ?*c.ID3D11PixelShader = null,
    ps_kawase_down: ?*c.ID3D11PixelShader = null,
    ps_kawase_up: ?*c.ID3D11PixelShader = null,
    ps_glow_composite: ?*c.ID3D11PixelShader = null,
    additive_blend: ?*c.ID3D11BlendState = null,
    bilinear_sampler: ?*c.ID3D11SamplerState = null,
    glow_cb: ?*c.ID3D11Buffer = null,

    // Sizing
    width: u32 = 1,
    height: u32 = 1,
    has_presented_once: bool = false,

    infoq: ?*c.ID3D11InfoQueue = null,
    dbg: ?*c.ID3D11Debug = null,

    // Background transparency (0.0-1.0, 1.0 = opaque)
    opacity: f32 = 1.0,

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
            dev = null;
            ctx = null;
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
        dbgLog("[d3d] createDeviceOnly: ok dev=0x{x} fl=0x{x}\n", .{@intFromPtr(dev.?), fl});
        return .{ .device = dev.?, .ctx = ctx.? };
    }

    /// Initialize with a pre-created D3D11 device (from createDeviceOnly).
    pub fn initWithDevice(alloc: std.mem.Allocator, hwnd: c.HWND, opacity: f32, device: *c.ID3D11Device, device_ctx: *c.ID3D11DeviceContext) !Renderer {
        var self: Renderer = .{
            .alloc = alloc,
            .hwnd = hwnd,
            .opacity = opacity,
            .device = device,
            .ctx = device_ctx,
        };

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
        self.ctx_mu.lock();
    }

    /// Unlock the D3D11 device context.
    pub fn unlockContext(self: *Renderer) void {
        self.ctx_mu.unlock();
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
        safeRelease(&self.ps_glow_extract);
        safeRelease(&self.ps_kawase_down);
        safeRelease(&self.ps_kawase_up);
        safeRelease(&self.ps_glow_composite);
        safeRelease(&self.additive_blend);
        safeRelease(&self.bilinear_sampler);
        safeRelease(&self.glow_cb);

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
                    applog.appLog("[d3d] GetCurrentBackBufferIndex -> {d}\n", .{ idx });
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

    pub fn resize(self: *Renderer) !void {
        var rc: c.RECT = undefined;
        _ = c.GetClientRect(self.hwnd, &rc);

        if (applog.isEnabled()) {
            applog.appLog(
                "[d3d] resize: client=({d},{d})-({d},{d}) cur_wh=({d},{d}) bb_tex=0x{x} bb_rtv=0x{x} back_tex=0x{x} back_rtv=0x{x} sc=0x{x} ctx=0x{x}\n",
                .{
                    rc.left, rc.top, rc.right, rc.bottom,
                    self.width, self.height,
                    if (self.bb_tex) |p| @intFromPtr(p) else 0,
                    if (self.bb_rtv) |p| @intFromPtr(p) else 0,
                    if (self.back_tex) |p| @intFromPtr(p) else 0,
                    if (self.back_rtv) |p| @intFromPtr(p) else 0,
                    if (self.swapchain) |p| @intFromPtr(p) else 0,
                    if (self.ctx) |p| @intFromPtr(p) else 0,
                },
            );
        }

        const w: u32 = @intCast(@max(1, rc.right - rc.left));
        const h: u32 = @intCast(@max(1, rc.bottom - rc.top));
        if (w == self.width and h == self.height) return;
    
        self.width = w;
        self.height = h;
        self.has_presented_once = false;
        self.swapchain_buf_index = 0;

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
                var null_srvs: [1]?*c.ID3D11ShaderResourceView = .{ null };
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

        const sc = self.swapchain.?;
        const sc_vtbl = sc.*.lpVtbl;
        const resize_buf = sc_vtbl.*.ResizeBuffers orelse return error.D3DResizeBuffersFailed;
    
        const hr_rb = resize_buf(sc, 0, w, h, c.DXGI_FORMAT_UNKNOWN, 0);
        if (c.FAILED(hr_rb)) return error.D3DResizeBuffersFailed;

        try self.createBackTargets();
    }

    pub fn atlasUploadRect(self: *Renderer, x: u32, y: u32, w: u32, h: u32, data: [*]const u8, row_pitch: u32) void {
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
            return;
        };
        const ctx = self.ctx orelse {
            if (applog.isEnabled()) applog.appLog("[d3d] atlasUploadRect: ctx is null -> skip\n", .{});
            return;
        };

        if (applog.isEnabled()) {
            // vtbl sanity log (dangling ctx often dies at ctx.*)
            const ctx_vtbl_ptr: usize = @intFromPtr(ctx.*.lpVtbl);
            applog.appLog("[d3d] atlasUploadRect: ctx.vtbl=0x{x}\n", .{ctx_vtbl_ptr});
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
            return;
        };
    
        const dst_res: *c.ID3D11Resource = @ptrCast(tex);
        upd(ctx, dst_res, 0, &box, data, row_pitch, 0);
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
        if (applog.isEnabled()) t_draw_start = std.time.nanoTimestamp();

        try self.resize();

        if (applog.isEnabled()) {
            applog.appLog(
                "[d3d] draw: w={d} h={d} main={d} cursor={d} dirty={s} vs={s} ps={s} il={s} srv={s} samp={s} blend={s}\n",
                .{
                    self.width, self.height,
                    main.len, cursor.len,
                    if (dirty_rect == null) "null" else "rect",
                    if (self.vs == null) "null" else "ok",
                    if (self.ps == null) "null" else "ok",
                    if (self.il == null) "null" else "ok",
                    if (self.atlas_srv == null) "null" else "ok",
                    if (self.sampler == null) "null" else "ok",
                    if (self.blend == null) "null" else "ok",
                },
            );
        }

        const ctx = self.ctx.?;
        const sc = self.swapchain.?;
    
        const back_rtv = self.back_rtv.?; // persistent back buffer RTV
        const bb_tex = self.currentBackBufferTex(); // swapchain backbuffer texture
        const back_tex = self.back_tex.?; // persistent back buffer texture
    
        const ctx_vtbl = ctx.*.lpVtbl;
    
        // ---- Bind persistent back buffer as render target ----
        {
            const om_set_rt = ctx_vtbl.*.OMSetRenderTargets orelse return;
    
            var rtvs: [1]?*c.ID3D11RenderTargetView = .{ back_rtv };
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
                (self.opacity < 1.0)
            );

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
            const clear_rtv = ctx_vtbl.*.ClearRenderTargetView orelse return;
            clear_rtv(ctx, back_rtv, &clear);
        } else if (self.opacity < 1.0) {
            // Force clear in transparency mode even if should_clear is false
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
                    .left = x_off_i + r.left,
                    .top = y_off_i + r.top,
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
            var srvs: [1]?*c.ID3D11ShaderResourceView = .{ srv };
            const pp_srvs: [*c]?*c.ID3D11ShaderResourceView =
                @as([*c]?*c.ID3D11ShaderResourceView, @ptrCast(&srvs));
            ps_set_srv(ctx, 0, 1, pp_srvs);
    
            // PS Sampler
            const ps_set_samp = ctx_vtbl.*.PSSetSamplers orelse return;
            const samp = self.sampler.?;
            var samps: [1]?*c.ID3D11SamplerState = .{ samp };
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
                        .left = x_off_t + r.left,
                        .top = y_off_t + r.top,
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
                            .left = x_off_r + r.left,
                            .top = y_off_r + r.top,
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
            var srvs: [1]?*c.ID3D11ShaderResourceView = .{ self.atlas_srv };
            ps_set_srv(ctx, 0, 1, @ptrCast(&srvs));
        }

        // ---- Draw in two batches ----
        try self.drawVertices(main);
        try self.drawVertices(cursor);

        // ---- Post-process bloom (neon glow) ----
        if (opts.glow_enabled and self.vs_fullscreen != null and self.ps_glow_extract != null) {
            self.ensureGlowTextures();
            if (self.glowTexturesComplete()) {
                self.drawBloomPasses(ctx, ctx_vtbl, main, cursor, opts.glow_intensity, viewport_x_offset, viewport_y_offset, viewport_width, viewport_height);
            }
        }

        if (opts.present) {
            const dst_bb: *c.ID3D11Resource = @ptrCast(bb_tex);
            const src_back: *c.ID3D11Resource = @ptrCast(back_tex);
        
            // Helper: clamp RECT to valid client area (avoid negative / out-of-bounds).
            const clampRect = struct {
                fn f(r: c.RECT, w: u32, h: u32) ?c.RECT {
                    var rr = r;
        
                    if (rr.left < 0) rr.left = 0;
                    if (rr.top < 0) rr.top = 0;
        
                    const w_i: i32 = @intCast(w);
                    const h_i: i32 = @intCast(h);
        
                    if (rr.right > w_i) rr.right = w_i;
                    if (rr.bottom > h_i) rr.bottom = h_i;
        
                    if (rr.right <= rr.left or rr.bottom <= rr.top) return null;
                    return rr;
                }
            }.f;
        
            // ---- Copy persistent back buffer -> swapchain backbuffer ----
            // When dirty_rect exists, use partial copy regardless of Present1 availability
            if (effective_dirty) |r0| {
                if (clampRect(r0, self.width, self.height)) |dr| {
                    var box: c.D3D11_BOX = .{
                        .left = @intCast(dr.left),
                        .top = @intCast(dr.top),
                        .front = 0,
                        .right = @intCast(dr.right),
                        .bottom = @intCast(dr.bottom),
                        .back = 1,
                    };
        
                    const copy_sub = ctx_vtbl.*.CopySubresourceRegion orelse return;
                    // Align dstX/dstY to dirty rect top-left
                    copy_sub(
                        ctx,
                        dst_bb, 0,
                        @intCast(dr.left), @intCast(dr.top), 0,
                        src_back, 0,
                        &box,
                    );
                } else {
                    // Fall back to full copy if clamp collapses
                    const copy_res = ctx_vtbl.*.CopyResource orelse return;
                    copy_res(ctx, dst_bb, src_back);
                }
            } else {
                // dirty_rect==null means full update, so full copy
                const copy_res = ctx_vtbl.*.CopyResource orelse return;
                copy_res(ctx, dst_bb, src_back);
            }
        
            // ---- Present ----
            {
                const sc_vtbl = sc.*.lpVtbl;
                const present = sc_vtbl.*.Present orelse return;
        
                const hrp: c.HRESULT = present(sc, 0, 0);
                if (c.FAILED(hrp)) {
                    if (applog.isEnabled()) {
                        applog.appLog("[d3d] Present FAILED hr=0x{x}\n", .{ @as(u32, @bitCast(hrp)) });
        
                        if (self.device) |dev| {
                            const dev_vtbl = dev.*.lpVtbl;
                            if (dev_vtbl.*.GetDeviceRemovedReason) |f| {
                                const hrr = f(dev);
                                applog.appLog(
                                    "[d3d] DeviceRemovedReason hr=0x{x}\n",
                                    .{ @as(u32, @bitCast(hrr)) },
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
            }
        }
        if (opts.present) {
            self.advanceSwapchainIndex();
        }

        // Performance log: draw_total
        if (applog.isEnabled() and t_draw_start != 0) {
            const t_draw_end = std.time.nanoTimestamp();
            const dur_us = @divTrunc(@max(0, t_draw_end - t_draw_start), 1000);
            applog.appLog("[perf] draw_total main={d} cursor={d} us={d}\n", .{ main.len, cursor.len, dur_us });
        }
    }

    pub fn presentOnlyFromBack(self: *Renderer, dirty_rect: ?c.RECT) !void {
        try self.resize();

        const ctx = self.ctx orelse return error.NoContext;
        const sc = self.swapchain orelse return error.NoSwapchain;

        const bb_tex = self.currentBackBufferTex();
        const back_tex = self.back_tex orelse return error.NoBackTex;

        const ctx_vtbl = ctx.*.lpVtbl;

        if (!self.has_presented_once or dirty_rect == null) {
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
                    bb_res, 0,
                    @intCast(dr.left), @intCast(dr.top), 0,
                    back_res, 0,
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
        }
        self.advanceSwapchainIndex();
    }

    pub fn presentOnlyFromBackRects(self: *Renderer, rects: []const c.RECT) !void {
        try self.resize();

        const ctx = self.ctx orelse return error.NoContext;
        const sc = self.swapchain orelse return error.NoSwapchain;

        const bb_tex = self.currentBackBufferTex();
        const back_tex = self.back_tex orelse return error.NoBackTex;

        const ctx_vtbl = ctx.*.lpVtbl;

        const copy_sub_opt = ctx_vtbl.*.CopySubresourceRegion;
        const copy_res_opt = ctx_vtbl.*.CopyResource;

        const bb_res: *c.ID3D11Resource = @ptrCast(bb_tex);
        const back_res: *c.ID3D11Resource = @ptrCast(back_tex);

        // If rects is empty (or first present after resize), use full copy.
        if (!self.has_presented_once or rects.len == 0) {
            const copy_res = copy_res_opt orelse return;
            copy_res(ctx, bb_res, back_res);
        } else {
            const w_i32: i32 = @intCast(self.width);
            const h_i32: i32 = @intCast(self.height);

            if (copy_sub_opt == null) return;
            const copy_sub = copy_sub_opt.?;

            var i: usize = 0;
            while (i < rects.len) : (i += 1) {
                var dr = rects[i];

                if (dr.left < 0) dr.left = 0;
                if (dr.top < 0) dr.top = 0;
                if (dr.right > w_i32) dr.right = w_i32;
                if (dr.bottom > h_i32) dr.bottom = h_i32;

                const valid =
                    (dr.left < dr.right) and (dr.top < dr.bottom) and
                    (dr.left >= 0) and (dr.top >= 0) and
                    (dr.right <= w_i32) and (dr.bottom <= h_i32);

                if (!valid) continue;

                const box: c.D3D11_BOX = .{
                    .left = @intCast(dr.left),
                    .top = @intCast(dr.top),
                    .front = 0,
                    .right = @intCast(dr.right),
                    .bottom = @intCast(dr.bottom),
                    .back = 1,
                };

                copy_sub(
                    ctx,
                    bb_res, 0,
                    @intCast(dr.left), @intCast(dr.top), 0,
                    back_res, 0,
                    &box,
                );
            }
        }

        const sc_vtbl = sc.*.lpVtbl;
        const present = sc_vtbl.*.Present orelse return;
        const hrp: c.HRESULT = present(sc, 0, 0);
        if (!c.FAILED(hrp)) {
            self.has_presented_once = true;
        }
        self.advanceSwapchainIndex();
    }

    pub fn presentOnlyFromBackRectsNoResize(self: *Renderer, rects: []const c.RECT) !void {
        var t_present_start: i128 = 0;
        if (applog.isEnabled()) t_present_start = std.time.nanoTimestamp();

        const ctx = self.ctx orelse return error.NoContext;
        const sc = self.swapchain orelse return error.NoSwapchain;

        const bb_tex = self.currentBackBufferTex();
        const back_tex = self.back_tex orelse return error.NoBackTex;

        const ctx_vtbl = ctx.*.lpVtbl;

        // If rects is empty (or first present after resize), equivalent to full screen
        if (!self.has_presented_once or rects.len == 0) {
            const copy_res = ctx_vtbl.*.CopyResource orelse return;
    
            const bb_res: *c.ID3D11Resource = @ptrCast(bb_tex);
            const back_res: *c.ID3D11Resource = @ptrCast(back_tex);
    
            copy_res(ctx, bb_res, back_res);
        } else {
            // Clamp each rect and CopySubresourceRegion
            var i: usize = 0;
            while (i < rects.len) : (i += 1) {
                var dr = rects[i];
    
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
                        bb_res, 0,
                        @intCast(dr.left), @intCast(dr.top), 0,
                        back_res, 0,
                        &box,
                    );
                } else {
                    // If still broken after clamp, full copy as fallback
                    const copy_res = ctx_vtbl.*.CopyResource orelse return;
    
                    const bb_res: *c.ID3D11Resource = @ptrCast(bb_tex);
                    const back_res: *c.ID3D11Resource = @ptrCast(back_tex);
    
                    copy_res(ctx, bb_res, back_res);
                    break;
                }
            }
        }
    
        const sc_vtbl = sc.*.lpVtbl;
        const present = sc_vtbl.*.Present orelse return;
    
        // sync interval: 0 (no vsync wait)
        const hrp: c.HRESULT = present(sc, 0, 0);
    
        if (!c.FAILED(hrp)) {
            self.has_presented_once = true;
        }
        self.advanceSwapchainIndex();

        // Performance log: present
        if (applog.isEnabled() and t_present_start != 0) {
            const t_present_end = std.time.nanoTimestamp();
            const present_us = @divTrunc(@max(0, t_present_end - t_present_start), 1000);
            applog.appLog("[perf] present rects={d} us={d}\n", .{ rects.len, present_us });
        }
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
        const ctx = self.ctx orelse return error.NoContext;
        const sc = self.swapchain orelse return error.NoSwapchain;

        const back_tex = self.back_tex orelse return error.NoBackTex;
        const buf_count_u32: u32 = if (self.swapchain_buf_count == 0) 1 else self.swapchain_buf_count;
        const buf_count: usize = @intCast(buf_count_u32);
        const fallback_bb = self.currentBackBufferTex();

        const ctx_vtbl = ctx.*.lpVtbl;
        const log_enabled = applog.isEnabled();
        var did_full_copy: bool = false;
        var t0_ns: i128 = 0;
        var t_copy_ns: i128 = 0;
        var t_cursor_ns: i128 = 0;
        if (log_enabled) {
            t0_ns = std.time.nanoTimestamp();
        }

        const force_full_copy_effective = force_full_copy or !self.has_presented_once;

        // If rects is empty, equivalent to full screen
        if (force_full_copy_effective or rects.len == 0) {
            const copy_res = ctx_vtbl.*.CopyResource orelse return;

            const back_res: *c.ID3D11Resource = @ptrCast(back_tex);

            var bi: usize = 0;
            while (bi < buf_count) : (bi += 1) {
                const bb_tex = self.bb_texs[bi] orelse fallback_bb;
                const bb_res: *c.ID3D11Resource = @ptrCast(bb_tex);
                copy_res(ctx, bb_res, back_res);
            }
            did_full_copy = true;
        } else {
            // Clamp each rect and CopySubresourceRegion
            var i: usize = 0;
            while (i < rects.len) : (i += 1) {
                var dr = rects[i];

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
                    const back_res: *c.ID3D11Resource = @ptrCast(back_tex);

                    var bi: usize = 0;
                    while (bi < buf_count) : (bi += 1) {
                        const bb_tex = self.bb_texs[bi] orelse fallback_bb;
                        const bb_res: *c.ID3D11Resource = @ptrCast(bb_tex);
                        copy_sub(
                            ctx,
                            bb_res, 0,
                            @intCast(dr.left), @intCast(dr.top), 0,
                            back_res, 0,
                            &box,
                        );
                    }
                } else {
                    // If still broken after clamp, full copy as fallback
                    const copy_res = ctx_vtbl.*.CopyResource orelse return;

                    const back_res: *c.ID3D11Resource = @ptrCast(back_tex);

                    var bi: usize = 0;
                    while (bi < buf_count) : (bi += 1) {
                        const bb_tex = self.bb_texs[bi] orelse fallback_bb;
                        const bb_res: *c.ID3D11Resource = @ptrCast(bb_tex);
                        copy_res(ctx, bb_res, back_res);
                    }
                    did_full_copy = true;
                    break;
                }
            }
        }
        if (log_enabled) {
            t_copy_ns = std.time.nanoTimestamp();
        }

        _ = cursor_vb;
        _ = cursor_vert_count;
        _ = cursor_scissor;
        if (log_enabled) {
            t_cursor_ns = std.time.nanoTimestamp();
        }

        var hrp: c.HRESULT = 0;
        if (self.swapchain1) |sc1p| {
            const sc1_vtbl = sc1p.*.lpVtbl;
            if (sc1_vtbl.*.Present1) |present1| {
                var params: c.DXGI_PRESENT_PARAMETERS = std.mem.zeroes(c.DXGI_PRESENT_PARAMETERS);
                if (!force_full_copy_effective and rects.len != 0) {
                    params.DirtyRectsCount = @intCast(rects.len);
                    params.pDirtyRects = @constCast(rects.ptr);
                }
                if (!force_full_copy_effective) {
                    if (scroll_rect) |sr| {
                        params.pScrollRect = @constCast(sr);
                    }
                    if (scroll_offset) |so| {
                        params.pScrollOffset = @constCast(so);
                    }
                }
                hrp = present1(sc1p, 0, 0, &params);
                if (c.FAILED(hrp)) {
                    if (applog.isEnabled()) applog.appLog("[d3d] Present1 FAILED hr=0x{x}, disabling swapchain1\n", .{ @as(u32, @bitCast(hrp)) });
                    self.swapchain1 = null;
                }
            } else {
                const sc_vtbl = sc.*.lpVtbl;
                const present = sc_vtbl.*.Present orelse return;
                hrp = present(sc, 0, 0);
            }
        } else {
            const sc_vtbl = sc.*.lpVtbl;
            const present = sc_vtbl.*.Present orelse return;
            hrp = present(sc, 0, 0);
        }

        if (!c.FAILED(hrp)) {
            self.has_presented_once = true;
        }

        if (log_enabled and did_full_copy) {
            applog.appLog("[d3d] presentFromBackRects: full copy fallback\n", .{});
        }
        if (log_enabled) {
            const t_done_ns: i128 = std.time.nanoTimestamp();
            const copy_us: u64 = @intCast(@divTrunc(@max(0, t_copy_ns - t0_ns), 1000));
            const cursor_us: u64 = @intCast(@divTrunc(@max(0, t_cursor_ns - t_copy_ns), 1000));
            const present_us: u64 = @intCast(@divTrunc(@max(0, t_done_ns - t_cursor_ns), 1000));
            const total_us: u64 = copy_us + cursor_us + present_us;
            applog.appLog(
                "[perf] present_detail rects={d} copy_us={d} cursor_us={d} present_us={d} total_us={d}\n",
                .{ rects.len, copy_us, cursor_us, present_us, total_us },
            );
        }
        self.advanceSwapchainIndex();
    }

    /// Draw multiple dirty rects.
    /// - rects.len == 0: treated as dirty_rect == null
    /// - Only the last rect will perform Present (opts.present), others draw into persistent back buffer only.
    pub fn drawExRects(
        self: *Renderer,
        main: []const core.Vertex,
        cursor: []const core.Vertex,
        rects: []const c.RECT,
        opts: DrawOpts,
    ) !void {
        if (rects.len == 0) {
            try self.drawEx(main, cursor, null, opts);
            return;
        }

        var i: usize = 0;
        while (i < rects.len) : (i += 1) {
            var local_opts = opts;
            // Present only once at the end.
            local_opts.present = opts.present and (i + 1 == rects.len);
            try self.drawEx(main, cursor, rects[i], local_opts);
        }
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
            // Release old resources
            safeRelease(&self.tabline_srv);
            safeRelease(&self.tabline_tex);

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
            safeRelease(&self.sidebar_srv);
            safeRelease(&self.sidebar_tex);

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

            self.sidebar_tex = tex;
            self.sidebar_srv = srv;
            self.sidebar_width_tex = width;
            self.sidebar_height_tex = height;

            if (applog.isEnabled()) applog.appLog("[d3d] updateSidebarTexture: created texture {d}x{d}\n", .{ width, height });
        } else {
            const tex = self.sidebar_tex orelse return;
            const ctx_vtbl = ctx.*.lpVtbl;
            const update_subres = ctx_vtbl.*.UpdateSubresource orelse return error.NoUpdateSubresource;

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
                    v0.position[0], v0.position[1],
                    v0.texCoord[0], v0.texCoord[1],
                    v0.color[0], v0.color[1], v0.color[2], v0.color[3],
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
        if (applog.isEnabled()) t_vb_start = std.time.nanoTimestamp();

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
            const t_vb_end = std.time.nanoTimestamp();
            const vb_us = @divTrunc(@max(0, t_vb_end - t_vb_start), 1000);
            applog.appLog("[perf] draw_vb_upload bytes={d} us={d}\n", .{ bytes, vb_us });
        }

        // ---- Bind VB + issue draw ----
        const ctx_vtbl = ctx.*.lpVtbl;

        // IA: vertex buffer
        const ia_set_vb = ctx_vtbl.*.IASetVertexBuffers orelse return error.D3DIASetVertexBuffersMissing;
        var stride: c.UINT = @sizeOf(core.Vertex);
        var offset: c.UINT = 0;

        var vbs: [1]?*c.ID3D11Buffer = .{ vb };
        const pp_vbs: [*c]?*c.ID3D11Buffer = @ptrCast(&vbs);
        ia_set_vb(ctx, 0, 1, pp_vbs, &stride, &offset);

        // IA: topology
        const ia_set_top = ctx_vtbl.*.IASetPrimitiveTopology orelse return error.D3DIASetTopologyMissing;
        ia_set_top(ctx, c.D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);

        // Performance: Draw call timing
        var t_draw_start: i128 = 0;
        if (applog.isEnabled()) t_draw_start = std.time.nanoTimestamp();

        // Draw
        const draw_fn = ctx_vtbl.*.Draw orelse return error.D3DDrawMissing;
        draw_fn(ctx, @intCast(verts.len), 0);

        // Performance log: Draw call
        if (applog.isEnabled() and t_draw_start != 0) {
            const t_draw_end = std.time.nanoTimestamp();
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

        // Release old
        safeRelease(vb_ptr);

        const dev = self.device orelse return error.NoDevice;

        var desc: c.D3D11_BUFFER_DESC = std.mem.zeroes(c.D3D11_BUFFER_DESC);
        desc.ByteWidth = @intCast(need_bytes);
        desc.Usage = c.D3D11_USAGE_DYNAMIC;
        desc.BindFlags = c.D3D11_BIND_VERTEX_BUFFER;
        desc.CPUAccessFlags = c.D3D11_CPU_ACCESS_WRITE;

        var buf: ?*c.ID3D11Buffer = null;
        const vtbl = dev.*.lpVtbl;
        const create = vtbl.*.CreateBuffer orelse return error.D3DCreateBufferMissing;

        const hr = create(dev, &desc, null, @ptrCast(&buf));
        if (c.FAILED(hr) or buf == null) return error.D3DCreateBufferFailed;

        vb_ptr.* = buf;
        vb_bytes_ptr.* = need_bytes;
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
        if (c.FAILED(hr)) return error.D3DMapFailed;

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
        var vbs: [1]?*c.ID3D11Buffer = .{ vb };
        const pp_vbs: [*c]?*c.ID3D11Buffer = @ptrCast(&vbs);
        ia_set_vb(ctx, 0, 1, pp_vbs, &stride, &offset);

        const ia_set_top = ctx_vtbl.*.IASetPrimitiveTopology orelse return error.D3DIASetTopologyMissing;
        ia_set_top(ctx, c.D3D11_PRIMITIVE_TOPOLOGY_TRIANGLELIST);

        const draw_fn = ctx_vtbl.*.Draw orelse return error.D3DDrawMissing;
        draw_fn(ctx, @intCast(vert_count), 0);
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

    /// Create swap chain and DirectComposition using the pre-set self.device/self.ctx.
    fn createSwapchainOnly(self: *Renderer) !void {
        var rc: c.RECT = undefined;
        _ = c.GetClientRect(self.hwnd, &rc);
        self.width = @intCast(@max(1, rc.right - rc.left));
        self.height = @intCast(@max(1, rc.bottom - rc.top));

        const dev = self.device;
        var hr: c.HRESULT = 0;

        // Skip device creation -- jump straight to swap chain.
        // Feature level was determined at device creation time.
        dbgLog("[d3d] createSwapchainOnly: begin (device=0x{x})\n", .{if (dev) |p| @intFromPtr(p) else 0});

        const enable_flip_model = true;

        var sc1: ?*c.IDXGISwapChain1 = null;
        var sc0: ?*c.IDXGISwapChain = null;
        var sc1_buf_count: u32 = 3;
        var dxgi_dev: ?*c.IDXGIDevice = null;
        var adapter: ?*c.IDXGIAdapter = null;
        var factory2: ?*c.IDXGIFactory2 = null;

        const dev_unk: *c.IUnknown = @ptrCast(dev.?);
        const dev_vtbl = dev_unk.*.lpVtbl;
        const qi = dev_vtbl.*.QueryInterface orelse return error.D3DCreateFailed;

        if (!c.FAILED(qi(dev_unk, &c.IID_IDXGIDevice, @ptrCast(&dxgi_dev))) and dxgi_dev != null) {
            const dxgi_vtbl = dxgi_dev.?.lpVtbl;
            if (dxgi_vtbl.*.GetAdapter) |get_adapter| {
                if (!c.FAILED(get_adapter(dxgi_dev.?, @ptrCast(&adapter))) and adapter != null) {
                    const adap_vtbl = adapter.?.lpVtbl;
                    if (adap_vtbl.*.GetParent) |get_parent| {
                        _ = get_parent(adapter.?, &c.IID_IDXGIFactory2, @ptrCast(&factory2));
                    }
                }
            }
        }

        if (enable_flip_model and factory2 != null) {
            var sd1: c.DXGI_SWAP_CHAIN_DESC1 = std.mem.zeroes(c.DXGI_SWAP_CHAIN_DESC1);
            sd1.Width = self.width;
            sd1.Height = self.height;
            sd1.Format = c.DXGI_FORMAT_B8G8R8A8_UNORM;
            sd1.SampleDesc.Count = 1;
            sd1.BufferUsage = c.DXGI_USAGE_RENDER_TARGET_OUTPUT;
            sd1.BufferCount = 3;
            sd1.SwapEffect = c.DXGI_SWAP_EFFECT_FLIP_SEQUENTIAL;
            sd1.Scaling = c.DXGI_SCALING_STRETCH;
            sd1.AlphaMode = c.DXGI_ALPHA_MODE_PREMULTIPLIED;
            sc1_buf_count = @intCast(sd1.BufferCount);

            const fac_vtbl = factory2.?.lpVtbl;
            if (fac_vtbl.*.CreateSwapChainForComposition) |create_sc_comp| {
                hr = create_sc_comp(factory2.?, @ptrCast(dev.?), &sd1, null, @ptrCast(&sc1));
                if (!c.FAILED(hr) and sc1 != null) {
                    const sc1_vtbl = sc1.?.lpVtbl;
                    if (sc1_vtbl.*.QueryInterface) |sc_qi| {
                        _ = sc_qi(sc1.?, &c.IID_IDXGISwapChain, @ptrCast(&sc0));
                    }
                }
            }
        }

        // Always initialize DirectComposition.
        if (sc1 != null and dxgi_dev != null) {
            var dcomp_dev: ?*IDCompositionDevice = null;
            const dcomp_hr = DCompositionCreateDevice(dxgi_dev, &IID_IDCompositionDevice, &dcomp_dev);
            if (!c.FAILED(dcomp_hr) and dcomp_dev != null) {
                self.dcomp_device = dcomp_dev;
                const vtbl = dcomp_dev.?.lpVtbl;
                var dcomp_target: ?*IDCompositionTarget = null;
                const target_hr = vtbl.CreateTargetForHwnd(dcomp_dev.?, self.hwnd, c.TRUE, &dcomp_target);
                if (!c.FAILED(target_hr) and dcomp_target != null) {
                    self.dcomp_target = dcomp_target;
                    var dcomp_visual: ?*IDCompositionVisual = null;
                    const visual_hr = vtbl.CreateVisual(dcomp_dev.?, &dcomp_visual);
                    if (!c.FAILED(visual_hr) and dcomp_visual != null) {
                        self.dcomp_visual = dcomp_visual;
                        const sc_unk: *c.IUnknown = @ptrCast(sc1.?);
                        _ = dcomp_visual.?.lpVtbl.SetContent(dcomp_visual.?, sc_unk);
                        _ = dcomp_target.?.lpVtbl.SetRoot(dcomp_target.?, dcomp_visual);
                        _ = vtbl.Commit(dcomp_dev.?);
                    }
                }
            }
        }

        if (dxgi_dev) |p| { const rel = p.lpVtbl.*.Release orelse null; if (rel) |f| _ = f(p); }
        if (adapter) |p| { const rel = p.lpVtbl.*.Release orelse null; if (rel) |f| _ = f(p); }
        if (factory2) |p| { const rel = p.lpVtbl.*.Release orelse null; if (rel) |f| _ = f(p); }

        if (sc1 == null or sc0 == null) {
            if (sc1) |p| { const rel = p.lpVtbl.*.Release orelse null; if (rel) |f| _ = f(p); }
            return error.D3DCreateFailed;
        }

        self.swapchain = sc0;
        self.swapchain1 = sc1;
        self.swapchain_buf_count = sc1_buf_count;
        self.swapchain_buf_index = 0;
        self.swapchain3 = null;

        if (sc0) |sc0p| {
            const sc0_vtbl = sc0p.*.lpVtbl;
            if (sc0_vtbl.*.QueryInterface) |sc_qi| {
                var sc3: ?*c.IDXGISwapChain3 = null;
                const hr_sc3 = sc_qi(sc0p, &c.IID_IDXGISwapChain3, @ptrCast(&sc3));
                if (!c.FAILED(hr_sc3) and sc3 != null) {
                    self.swapchain3 = sc3;
                }
            }
        }
    }

    fn createDeviceAndSwapchain(self: *Renderer) !void {
        var rc: c.RECT = undefined;
        _ = c.GetClientRect(self.hwnd, &rc);
        self.width = @intCast(@max(1, rc.right - rc.left));
        self.height = @intCast(@max(1, rc.bottom - rc.top));

        dbgLog("[d3d] init: createDeviceAndSwapchain begin\n", .{});

        var dev: ?*c.ID3D11Device = null;
        var ctx: ?*c.ID3D11DeviceContext = null;
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
            dev = null;
            ctx = null;

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
            dbgLog("[d3d] init: D3D11CreateDevice failed hr=0x{x}\n", .{ @as(u32, @bitCast(hr)) });
            return error.D3DCreateFailed;
        }
        dbgLog("[d3d] init: D3D11CreateDevice ok dev=0x{x} ctx=0x{x} fl=0x{x}\n", .{ if (dev) |p| @intFromPtr(p) else 0, if (ctx) |p| @intFromPtr(p) else 0, fl });
        self.feature_level = fl;

        const enable_flip_model = true;

        // Try flip-model swapchain (IDXGIFactory2)
        var sc1: ?*c.IDXGISwapChain1 = null;
        var sc0: ?*c.IDXGISwapChain = null;
        var sc1_buf_count: u32 = 3;
        var dxgi_dev: ?*c.IDXGIDevice = null;
        var adapter: ?*c.IDXGIAdapter = null;
        var factory2: ?*c.IDXGIFactory2 = null;

        const dev_unk: *c.IUnknown = @ptrCast(dev.?);
        const dev_vtbl = dev_unk.*.lpVtbl;
        const qi = dev_vtbl.*.QueryInterface orelse return;

        if (!c.FAILED(qi(dev_unk, &c.IID_IDXGIDevice, @ptrCast(&dxgi_dev))) and dxgi_dev != null) {
            const dxgi_vtbl = dxgi_dev.?.lpVtbl;
            if (dxgi_vtbl.*.GetAdapter) |get_adapter| {
                if (!c.FAILED(get_adapter(dxgi_dev.?, @ptrCast(&adapter))) and adapter != null) {
                    const adap_vtbl = adapter.?.lpVtbl;
                    if (adap_vtbl.*.GetParent) |get_parent| {
                        _ = get_parent(adapter.?, &c.IID_IDXGIFactory2, @ptrCast(&factory2));
                    }
                }
            }
        }
        dbgLog("[d3d] init: factory2=0x{x}\n", .{ if (factory2) |p| @intFromPtr(p) else 0 });

        if (enable_flip_model and factory2 != null) {
            var sd1: c.DXGI_SWAP_CHAIN_DESC1 = std.mem.zeroes(c.DXGI_SWAP_CHAIN_DESC1);
            sd1.Width = self.width;
            sd1.Height = self.height;
            sd1.Format = c.DXGI_FORMAT_B8G8R8A8_UNORM;
            sd1.SampleDesc.Count = 1;
            sd1.BufferUsage = c.DXGI_USAGE_RENDER_TARGET_OUTPUT;
            sd1.BufferCount = 3;
            sd1.SwapEffect = c.DXGI_SWAP_EFFECT_FLIP_SEQUENTIAL;
            sd1.Scaling = c.DXGI_SCALING_STRETCH;
            // Always premultiplied alpha: WS_EX_NOREDIRECTIONBITMAP requires composition path.
            sd1.AlphaMode = c.DXGI_ALPHA_MODE_PREMULTIPLIED;
            sc1_buf_count = @intCast(sd1.BufferCount);

            const fac_vtbl = factory2.?.lpVtbl;

            // Always use CreateSwapChainForComposition (required by WS_EX_NOREDIRECTIONBITMAP).
            if (applog.isEnabled()) applog.appLog("[d3d] Attempting CreateSwapChainForComposition...\n", .{});
            if (fac_vtbl.*.CreateSwapChainForComposition) |create_sc_comp| {
                hr = create_sc_comp(factory2.?, @ptrCast(dev.?), &sd1, null, @ptrCast(&sc1));
                if (applog.isEnabled()) applog.appLog("[d3d] CreateSwapChainForComposition hr=0x{x} sc1=0x{x}\n", .{ @as(u32, @bitCast(hr)), if (sc1) |p| @intFromPtr(p) else 0 });
                if (!c.FAILED(hr) and sc1 != null) {
                    const sc1_vtbl = sc1.?.lpVtbl;
                    if (sc1_vtbl.*.QueryInterface) |sc_qi| {
                        _ = sc_qi(sc1.?, &c.IID_IDXGISwapChain, @ptrCast(&sc0));
                    }
                }
            } else {
                if (applog.isEnabled()) applog.appLog("[d3d] CreateSwapChainForComposition is NULL!\n", .{});
            }
        }

        // Always initialize DirectComposition (required by WS_EX_NOREDIRECTIONBITMAP).
        if (applog.isEnabled()) applog.appLog("[d3d] DirectComposition: sc1={} dxgi_dev={}\n", .{ sc1 != null, dxgi_dev != null });
        if (sc1 != null and dxgi_dev != null) {
            var dcomp_dev: ?*IDCompositionDevice = null;
            const dcomp_hr = DCompositionCreateDevice(dxgi_dev, &IID_IDCompositionDevice, &dcomp_dev);
            if (applog.isEnabled()) applog.appLog("[d3d] DCompositionCreateDevice hr=0x{x} dev=0x{x}\n", .{ @as(u32, @bitCast(dcomp_hr)), if (dcomp_dev) |d| @intFromPtr(d) else 0 });

            if (!c.FAILED(dcomp_hr) and dcomp_dev != null) {
                self.dcomp_device = dcomp_dev;
                const vtbl = dcomp_dev.?.lpVtbl;
                if (applog.isEnabled()) applog.appLog("[d3d] dcomp lpVtbl=0x{x}\n", .{@intFromPtr(vtbl)});

                // Create target for HWND (direct call without optional unwrapping)
                var dcomp_target: ?*IDCompositionTarget = null;
                const target_hr = vtbl.CreateTargetForHwnd(dcomp_dev.?, self.hwnd, c.TRUE, &dcomp_target);
                if (applog.isEnabled()) applog.appLog("[d3d] CreateTargetForHwnd hr=0x{x}\n", .{@as(u32, @bitCast(target_hr))});

                if (!c.FAILED(target_hr) and dcomp_target != null) {
                    self.dcomp_target = dcomp_target;

                    // Create visual (direct call)
                    var dcomp_visual: ?*IDCompositionVisual = null;
                    const visual_hr = vtbl.CreateVisual(dcomp_dev.?, &dcomp_visual);
                    if (applog.isEnabled()) applog.appLog("[d3d] CreateVisual hr=0x{x}\n", .{@as(u32, @bitCast(visual_hr))});

                    if (!c.FAILED(visual_hr) and dcomp_visual != null) {
                        self.dcomp_visual = dcomp_visual;

                        // Set swapchain as visual content (direct call)
                        const sc_unk: *c.IUnknown = @ptrCast(sc1.?);
                        _ = dcomp_visual.?.lpVtbl.SetContent(dcomp_visual.?, sc_unk);

                        // Set visual as root of target (direct call)
                        _ = dcomp_target.?.lpVtbl.SetRoot(dcomp_target.?, dcomp_visual);

                        // Commit changes (direct call)
                        _ = vtbl.Commit(dcomp_dev.?);

                        if (applog.isEnabled()) applog.appLog("[d3d] DirectComposition setup complete\n", .{});
                    }
                }
            }
        }

        if (dxgi_dev) |p| {
            const rel = p.lpVtbl.*.Release orelse null;
            if (rel) |f| _ = f(p);
        }
        if (adapter) |p| {
            const rel = p.lpVtbl.*.Release orelse null;
            if (rel) |f| _ = f(p);
        }
        if (factory2) |p| {
            const rel = p.lpVtbl.*.Release orelse null;
            if (rel) |f| _ = f(p);
        }

        if (sc1 == null or sc0 == null) {
            if (sc1) |p| {
                const rel = p.lpVtbl.*.Release orelse null;
                if (rel) |f| _ = f(p);
            }

            // Fallback to legacy swapchain creation
            var sd: c.DXGI_SWAP_CHAIN_DESC = std.mem.zeroes(c.DXGI_SWAP_CHAIN_DESC);
            sd.BufferCount = 1;
            sd.BufferDesc.Width = self.width;
            sd.BufferDesc.Height = self.height;
            sd.BufferDesc.Format = c.DXGI_FORMAT_B8G8R8A8_UNORM;
            sd.BufferUsage = c.DXGI_USAGE_RENDER_TARGET_OUTPUT;
            sd.OutputWindow = self.hwnd;
            sd.SampleDesc.Count = 1;
            sd.Windowed = c.TRUE;
            sd.SwapEffect = c.DXGI_SWAP_EFFECT_SEQUENTIAL;

            var dev2: ?*c.ID3D11Device = null;
            var ctx2: ?*c.ID3D11DeviceContext = null;
            var sc_fallback: ?*c.IDXGISwapChain = null;
            hr = c.D3D11CreateDeviceAndSwapChain(
                null,
                c.D3D_DRIVER_TYPE_HARDWARE,
                null,
                flags,
                null,
                0,
                c.D3D11_SDK_VERSION,
                &sd,
                @ptrCast(&sc_fallback),
                @ptrCast(&dev2),
                null,
                @ptrCast(&ctx2),
            );
            if (hr != 0 or dev2 == null or ctx2 == null or sc_fallback == null) {
                dbgLog("[d3d] init: CreateDeviceAndSwapChain fallback failed hr=0x{x}\n", .{ @as(u32, @bitCast(hr)) });
                return error.D3DCreateFailed;
            }
            dbgLog("[d3d] init: fallback swapchain ok sc=0x{x}\n", .{ if (sc_fallback) |p| @intFromPtr(p) else 0 });
            // Release original device/context before overwriting to avoid COM leak.
            safeRelease(&dev);
            safeRelease(&ctx);
            dev = dev2;
            ctx = ctx2;
            sc0 = sc_fallback;
        }

        self.device = dev;
        self.ctx = ctx;
        self.swapchain = sc0;
        self.swapchain1 = sc1;
        // swapchain3 is derived from swapchain (if supported)
        self.swapchain_buf_count = if (sc1 != null) sc1_buf_count else 1;
        self.swapchain_buf_index = 0;
        self.swapchain3 = null;

        if (sc0) |sc0p| {
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

        // ★ Added: If Debug layer enabled, get InfoQueue and break on critical messages
        const is_debug2 = (@import("builtin").mode == .Debug);
        if (is_debug2) {
            const unk: *c.IUnknown = @ptrCast(dev.?);
            const unk_vtbl = unk.*.lpVtbl;
            const qi2 = unk_vtbl.*.QueryInterface orelse return;
        
            var infoq: ?*c.ID3D11InfoQueue = null;
            var dbg: ?*c.ID3D11Debug = null;
        
            // Query ID3D11InfoQueue
            if (!c.FAILED(qi2(unk, &c.IID_ID3D11InfoQueue, @ptrCast(&infoq))) and infoq != null) {
                self.infoq = infoq;

                // Break on high severity (will Dump later so visible in logs even without debugger)
                _ = infoq.?.lpVtbl.*.SetBreakOnSeverity.?(infoq.?, c.D3D11_MESSAGE_SEVERITY_CORRUPTION, c.TRUE);
                _ = infoq.?.lpVtbl.*.SetBreakOnSeverity.?(infoq.?, c.D3D11_MESSAGE_SEVERITY_ERROR, c.TRUE);
        
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
                applog.appLog("[d3d] GetBuffer idx={d}\n", .{ i });
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
    }

    /// Shift the retained content in back_tex by `dy_px` pixels vertically.
    /// Positive dy_px = content moves down (scroll up / rows_delta < 0).
    /// Negative dy_px = content moves up (scroll down / rows_delta > 0).
    /// Uses a staging texture to avoid overlapping self-copy.
    pub fn scrollBackTex(self: *Renderer, scroll_rect: c.RECT, dy_px: i32) void {
        if (dy_px == 0) return;
        const ctx = self.ctx orelse return;
        const back_tex = self.back_tex orelse return;
        const dev = self.device orelse return;

        const w: u32 = self.width;
        const h: u32 = self.height;
        if (w == 0 or h == 0) return;

        // Clamp scroll_rect to texture bounds
        const sr_left: u32 = @intCast(@max(0, scroll_rect.left));
        const sr_top: u32 = @intCast(@max(0, scroll_rect.top));
        const sr_right: u32 = @intCast(@min(@as(i32, @intCast(w)), scroll_rect.right));
        const sr_bottom: u32 = @intCast(@min(@as(i32, @intCast(h)), scroll_rect.bottom));
        if (sr_left >= sr_right or sr_top >= sr_bottom) return;

        // Source region: the part of scroll_rect that will be preserved after shift
        var src_top: u32 = undefined;
        var src_bottom: u32 = undefined;
        var dst_y: u32 = undefined;

        if (dy_px > 0) {
            // Content moves down: source is top portion, destination is shifted down
            const shift: u32 = @intCast(dy_px);
            if (shift >= sr_bottom - sr_top) return; // shift larger than region
            src_top = sr_top;
            src_bottom = sr_bottom - shift;
            dst_y = sr_top + shift;
        } else {
            // Content moves up: source is bottom portion, destination is shifted up
            const shift: u32 = @intCast(-dy_px);
            if (shift >= sr_bottom - sr_top) return;
            src_top = sr_top + shift;
            src_bottom = sr_bottom;
            dst_y = sr_top;
        }

        // Lazy-create staging texture matching back_tex format and dimensions
        if (self.scroll_staging_tex == null) {
            // Query back_tex format to ensure CopySubresourceRegion compatibility
            var back_desc: c.D3D11_TEXTURE2D_DESC = undefined;
            const back_vtbl = back_tex.*.lpVtbl;
            const get_desc = back_vtbl.*.GetDesc orelse return;
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
            const create_tex = dev_vtbl.*.CreateTexture2D orelse return;
            var staging: ?*c.ID3D11Texture2D = null;
            const hr = create_tex(dev, &desc, null, @ptrCast(&staging));
            if (c.FAILED(hr) or staging == null) return;
            self.scroll_staging_tex = staging;
        }

        const staging_tex = self.scroll_staging_tex.?;
        const ctx_vtbl = ctx.*.lpVtbl;
        const copy_sub = ctx_vtbl.*.CopySubresourceRegion orelse return;

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

            var rtvs: [1]?*c.ID3D11RenderTargetView = .{ self.glow_extract_rtv.? };
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

            self.drawVertices(main) catch return;
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

        var samps: [1]?*c.ID3D11SamplerState = .{ self.bilinear_sampler.? };
        ps_set_samp(ctx, 1, 1, @ptrCast(&samps));

        // --- Downsample chain: extract → mip[0] → mip[1] → mip[2] ---
        for (0..3) |level| {
            // Unbind SRV slot 1 to avoid RTV/SRV hazard
            var null_srvs: [1]?*c.ID3D11ShaderResourceView = .{ null };
            ps_set_srv(ctx, 1, 1, @ptrCast(&null_srvs));

            var rtvs: [1]?*c.ID3D11RenderTargetView = .{ self.glow_mip_rtv[level].? };
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
            var srvs: [1]?*c.ID3D11ShaderResourceView = .{ src_srv };
            ps_set_srv(ctx, 1, 1, @ptrCast(&srvs));

            ps_set_fn(ctx, self.ps_kawase_down.?, null, 0);
            draw_fn(ctx, 3, 0);
        }

        // --- Upsample chain: mip[2] → mip[1] → mip[0] → extractTex ---
        for (0..3) |i| {
            const level = 2 - i;

            // Unbind SRV slot 1
            var null_srvs: [1]?*c.ID3D11ShaderResourceView = .{ null };
            ps_set_srv(ctx, 1, 1, @ptrCast(&null_srvs));

            // Destination: mip[level-1] for level > 0, extract for level 0
            const dst_rtv = if (level == 0) self.glow_extract_rtv.? else self.glow_mip_rtv[level - 1].?;
            var rtvs: [1]?*c.ID3D11RenderTargetView = .{ dst_rtv };
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
            var srvs: [1]?*c.ID3D11ShaderResourceView = .{ self.glow_mip_srv[level].? };
            ps_set_srv(ctx, 1, 1, @ptrCast(&srvs));

            ps_set_fn(ctx, self.ps_kawase_up.?, null, 0);
            draw_fn(ctx, 3, 0);
        }

        // --- Composite → back buffer (additive blend) ---
        {
            var null_srvs: [1]?*c.ID3D11ShaderResourceView = .{ null };
            ps_set_srv(ctx, 1, 1, @ptrCast(&null_srvs));

            var rtvs: [1]?*c.ID3D11RenderTargetView = .{ self.back_rtv.? };
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

            var srvs: [1]?*c.ID3D11ShaderResourceView = .{ self.glow_extract_srv.? };
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
            var cbs: [1]?*c.ID3D11Buffer = .{ self.glow_cb.? };
            ps_set_cb(ctx, 0, 1, @ptrCast(&cbs));

            om_set_blend(ctx, self.additive_blend.?, &blend_factor, 0xFFFFFFFF);

            ps_set_fn(ctx, self.ps_glow_composite.?, null, 0);

            draw_fn(ctx, 3, 0);

            // --- Restore state ---
            ps_set_srv(ctx, 1, 1, @ptrCast(&null_srvs));

            var null_cbs: [1]?*c.ID3D11Buffer = .{ null };
            ps_set_cb(ctx, 0, 1, @ptrCast(&null_cbs));

            vs_set_fn(ctx, self.vs.?, null, 0);
            ps_set_fn(ctx, self.ps.?, null, 0);
            om_set_blend(ctx, self.blend.?, &blend_factor, 0xFFFFFFFF);
            ia_set_il(ctx, self.il.?);

            var atlas_srvs: [1]?*c.ID3D11ShaderResourceView = .{ self.atlas_srv };
            ps_set_srv(ctx, 0, 1, @ptrCast(&atlas_srvs));
        }
    }

    /// Public entry point for bloom passes (used by row-mode rendering).
    /// Requires vertices to be passed in (collected from row VBs).
    pub fn drawBloomFromVerts(self: *Renderer, main: []const core.Vertex, cursor: []const core.Vertex, intensity: f32, vp_x: u32, vp_y: u32, vp_w: u32, vp_h: u32) void {
        if (self.vs_fullscreen == null or self.ps_glow_extract == null) return;
        self.ensureGlowTextures();
        if (!self.glowTexturesComplete()) return;
        const ctx = self.ctx orelse return;
        const ctx_vtbl = ctx.*.lpVtbl;
        self.drawBloomPasses(ctx, ctx_vtbl, main, cursor, intensity, vp_x, vp_y, vp_w, vp_h);
    }

    fn createAtlasTexture(self: *Renderer, w: u32, h: u32) !void {
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
        self.atlas_tex = tex;
    
        // ID3D11Device::CreateShaderResourceView (vtbl call)
        var srv: ?*c.ID3D11ShaderResourceView = null;
        const create_srv = dev_vtbl.*.CreateShaderResourceView orelse return error.D3DCreateAtlasSRVFailed;
    
        // pResource expects ID3D11Resource*
        const hr_srv = create_srv(dev, @ptrCast(tex.?), null, @ptrCast(&srv));
        if (c.FAILED(hr_srv) or srv == null) return error.D3DCreateAtlasSRVFailed;
        self.atlas_srv = srv;
    }


    /// Return the maximum 2D texture dimension supported by the device's feature level.
    pub fn maxTextureSize(self: *const Renderer) u32 {
        // D3D_FEATURE_LEVEL enum values: 9_1=0x9100, 9_2=0x9200, 9_3=0x9300, 10_0=0xa000, 11_0=0xb000
        if (self.feature_level >= 0xb000) return 16384; // FL 11_0+
        if (self.feature_level >= 0xa000) return 8192; // FL 10_0+
        if (self.feature_level >= 0x9300) return 4096; // FL 9_3
        return 2048; // FL 9_1, 9_2
    }

    /// Recreate atlas texture if dimensions changed. No-op for same-size resets.
    /// Returns error if D3D texture creation fails (caller should terminate).
    pub fn recreateAtlasTextureIfNeeded(self: *Renderer, w: u32, h: u32) !void {
        if (w == self.atlas_w and h == self.atlas_h) return;

        // Release old resources
        safeRelease(&self.atlas_srv);
        safeRelease(&self.atlas_tex);

        try self.createAtlasTexture(w, h);
        self.atlas_w = w;
        self.atlas_h = h;
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
            .{ .SemanticName = "BLENDINDICES", .SemanticIndex = 0, .Format = c.DXGI_FORMAT_R32G32_SINT, .InputSlot = 0, .AlignedByteOffset = 32, .InputSlotClass = c.D3D11_INPUT_PER_VERTEX_DATA, .InstanceDataStepRate = 0 },  // grid_id (i64 as int2)
            .{ .SemanticName = "BLENDINDICES", .SemanticIndex = 1, .Format = c.DXGI_FORMAT_R32_UINT, .InputSlot = 0, .AlignedByteOffset = 40, .InputSlotClass = c.D3D11_INPUT_PER_VERTEX_DATA, .InstanceDataStepRate = 0 },  // deco_flags
            .{ .SemanticName = "TEXCOORD", .SemanticIndex = 1, .Format = c.DXGI_FORMAT_R32_FLOAT, .InputSlot = 0, .AlignedByteOffset = 44, .InputSlotClass = c.D3D11_INPUT_PER_VERTEX_DATA, .InstanceDataStepRate = 0 },  // deco_phase
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
            rd.CullMode = c.D3D11_CULL_NONE;          // ★ Without this, CW-generated quads are all culled
            rd.ScissorEnable = c.TRUE;                // ★ For dirty rect (enable RSSetScissorRects)
            rd.DepthClipEnable = c.TRUE;

            var rs: ?*c.ID3D11RasterizerState = null;
            const hr = create_rs(dev, &rd, &rs);
            if (c.FAILED(hr) or rs == null) return error.D3DCreateRasterizerFailed;
            self.rs = rs;
        }

        // --- Bloom shaders (runtime compile only, no pre-compiled bytecode) ---
        {
            const create_vs_fn = dev_vtbl.*.CreateVertexShader orelse return error.D3DCreateVSFailed;
            const create_ps_fn = dev_vtbl.*.CreatePixelShader orelse return error.D3DCreatePSFailed;

            const BloomEntry = struct {
                entry: [*:0]const u8,
                target: [*:0]const u8,
                is_vs: bool,
            };
            const bloom_entries = [_]BloomEntry{
                .{ .entry = "VSFullscreen", .target = "vs_5_0", .is_vs = true },
                .{ .entry = "PSGlowExtract", .target = "ps_5_0", .is_vs = false },
                .{ .entry = "PSKawaseDown", .target = "ps_5_0", .is_vs = false },
                .{ .entry = "PSKawaseUp", .target = "ps_5_0", .is_vs = false },
                .{ .entry = "PSGlowComposite", .target = "ps_5_0", .is_vs = false },
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
                    return; // Non-fatal: bloom just won't work
                }
                bloom_blobs[idx] = blob;
            }

            // Create shader objects
            const bp0 = blobPtr(bloom_blobs[0]) orelse return;
            const bs0 = blobSize(bloom_blobs[0]);
            var vs_fs: ?*c.ID3D11VertexShader = null;
            if (c.FAILED(create_vs_fn(dev, bp0, bs0, null, &vs_fs)) or vs_fs == null) return;
            self.vs_fullscreen = vs_fs;

            inline for (.{ 1, 2, 3, 4 }, .{ &self.ps_glow_extract, &self.ps_kawase_down, &self.ps_kawase_up, &self.ps_glow_composite }) |idx, field| {
                const bp = blobPtr(bloom_blobs[idx]) orelse return;
                const bs = blobSize(bloom_blobs[idx]);
                var ps_out: ?*c.ID3D11PixelShader = null;
                if (c.FAILED(create_ps_fn(dev, bp, bs, null, &ps_out)) or ps_out == null) return;
                field.* = ps_out;
            }
        }

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
