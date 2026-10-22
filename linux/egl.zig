// egl.zig — Hand-written EGL and GBM declarations for the render thread
// (render_thread.zig), as gl.zig and fc.zig are for GL and fontconfig.
// Extension entry points are resolved with eglGetProcAddress.

pub const EGLDisplay = ?*anyopaque;
pub const EGLContext = ?*anyopaque;
pub const EGLImage = ?*anyopaque;
pub const EGLint = i32;
pub const EGLenum = u32;
pub const EGLBoolean = u32;
pub const EGLAttrib = isize;

pub const EGL_NO_CONTEXT: EGLContext = null;
pub const EGL_NO_IMAGE: EGLImage = null;
pub const EGL_NONE: EGLint = 0x3038;
pub const EGL_OPENGL_API: EGLenum = 0x30A2;
pub const EGL_EXTENSIONS: EGLint = 0x3055;
pub const EGL_PLATFORM_GBM_KHR: EGLenum = 0x31D7;
pub const EGL_CONTEXT_MAJOR_VERSION: EGLint = 0x3098;
pub const EGL_CONTEXT_MINOR_VERSION: EGLint = 0x30FB;
pub const EGL_CONTEXT_OPENGL_PROFILE_MASK: EGLint = 0x30FD;
pub const EGL_CONTEXT_OPENGL_CORE_PROFILE_BIT: EGLint = 0x1;
pub const EGL_LINUX_DMA_BUF_EXT: EGLenum = 0x3270;
pub const EGL_WIDTH: EGLint = 0x3057;
pub const EGL_HEIGHT: EGLint = 0x3056;
pub const EGL_LINUX_DRM_FOURCC_EXT: EGLint = 0x3271;
pub const EGL_DMA_BUF_PLANE0_FD_EXT: EGLint = 0x3272;
pub const EGL_DMA_BUF_PLANE0_OFFSET_EXT: EGLint = 0x3273;
pub const EGL_DMA_BUF_PLANE0_PITCH_EXT: EGLint = 0x3274;
pub const EGL_DMA_BUF_PLANE0_MODIFIER_LO_EXT: EGLint = 0x3443;
pub const EGL_DMA_BUF_PLANE0_MODIFIER_HI_EXT: EGLint = 0x3444;

pub extern "c" fn eglGetProcAddress(name: [*:0]const u8) ?*const anyopaque;
pub extern "c" fn eglInitialize(dpy: EGLDisplay, major: ?*EGLint, minor: ?*EGLint) EGLBoolean;
pub extern "c" fn eglTerminate(dpy: EGLDisplay) EGLBoolean;
pub extern "c" fn eglQueryString(dpy: EGLDisplay, name: EGLint) ?[*:0]const u8;
pub extern "c" fn eglBindAPI(api: EGLenum) EGLBoolean;
pub extern "c" fn eglCreateContext(dpy: EGLDisplay, config: ?*anyopaque, share: EGLContext, attribs: [*]const EGLint) EGLContext;
pub extern "c" fn eglDestroyContext(dpy: EGLDisplay, ctx: EGLContext) EGLBoolean;
pub extern "c" fn eglMakeCurrent(dpy: EGLDisplay, draw: ?*anyopaque, read: ?*anyopaque, ctx: EGLContext) EGLBoolean;
pub extern "c" fn eglReleaseThread() EGLBoolean;

pub const PfnGetPlatformDisplay = *const fn (platform: EGLenum, native: ?*anyopaque, attribs: ?[*]const EGLint) callconv(.c) EGLDisplay;
pub const PfnCreateImage = *const fn (dpy: EGLDisplay, ctx: EGLContext, target: EGLenum, buffer: ?*anyopaque, attribs: [*]const EGLint) callconv(.c) EGLImage;
pub const PfnDestroyImage = *const fn (dpy: EGLDisplay, image: EGLImage) callconv(.c) EGLBoolean;
pub const PfnImageTargetTexture2D = *const fn (target: u32, image: EGLImage) callconv(.c) void;

pub fn proc(comptime T: type, name: [*:0]const u8) ?T {
    const p = eglGetProcAddress(name) orelse return null;
    return @ptrCast(@alignCast(p));
}

// =========================================================================
// GBM
// =========================================================================

pub const gbm_device = opaque {};
pub const gbm_bo = opaque {};
/// DRM_FORMAT_XRGB8888 ('XR24'): opaque, so the compositor need not blend.
pub const GBM_FORMAT_XRGB8888: u32 = 0x34325258;
pub const GBM_BO_USE_RENDERING: u32 = 1 << 2;

pub extern "c" fn gbm_create_device(fd: c_int) ?*gbm_device;
pub extern "c" fn gbm_device_destroy(gbm: *gbm_device) void;
pub extern "c" fn gbm_bo_create(gbm: *gbm_device, width: u32, height: u32, format: u32, flags: u32) ?*gbm_bo;
pub extern "c" fn gbm_bo_destroy(bo: *gbm_bo) void;
pub extern "c" fn gbm_bo_get_fd(bo: *gbm_bo) c_int;
pub extern "c" fn gbm_bo_get_stride(bo: *gbm_bo) u32;
pub extern "c" fn gbm_bo_get_offset(bo: *gbm_bo, plane: c_int) u32;
pub extern "c" fn gbm_bo_get_modifier(bo: *gbm_bo) u64;
