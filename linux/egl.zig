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
/// eglQueryDmaBufModifiersEXT: `external_only[i]` is set for a modifier that
/// can be sampled but not rendered to.
pub const PfnQueryDmaBufModifiers = *const fn (dpy: EGLDisplay, format: EGLint, max: EGLint, modifiers: ?[*]u64, external_only: ?[*]EGLBoolean, num: *EGLint) callconv(.c) EGLBoolean;
pub const EGLSync = ?*anyopaque;
/// EGL_ANDROID_native_fence_sync: a fence exported as a sync_file fd.
pub const EGL_SYNC_NATIVE_FENCE_ANDROID: EGLenum = 0x3144;
pub const PfnCreateSync = *const fn (dpy: EGLDisplay, type: EGLenum, attribs: ?[*]const EGLint) callconv(.c) EGLSync;
pub const PfnDestroySync = *const fn (dpy: EGLDisplay, sync: EGLSync) callconv(.c) EGLBoolean;
pub const PfnDupNativeFenceFd = *const fn (dpy: EGLDisplay, sync: EGLSync) callconv(.c) EGLint;
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
/// DRM_FORMAT_ARGB8888 ('AR24'), premultiplied as Wayland takes it. Not
/// XRGB, though the frames are opaque unless the window is translucent:
/// Hyprland (0.56) draws a window whose XRGB subsurface lies below it in
/// white wherever the window itself is clear, over the subsurface too.
pub const GBM_FORMAT_ARGB8888: u32 = 0x34325241;
/// DRM_FORMAT_MOD_INVALID: an implicit modifier, the layout being the
/// driver's own business.
pub const DRM_FORMAT_MOD_INVALID: u64 = 0x00ffffffffffffff;
pub const GBM_BO_USE_RENDERING: u32 = 1 << 2;

pub extern "c" fn gbm_create_device(fd: c_int) ?*gbm_device;
pub extern "c" fn gbm_device_destroy(gbm: *gbm_device) void;
pub extern "c" fn gbm_bo_create(gbm: *gbm_device, width: u32, height: u32, format: u32, flags: u32) ?*gbm_bo;
/// A buffer in one of `modifiers`, which gbm_bo_get_modifier then names.
pub extern "c" fn gbm_bo_create_with_modifiers2(gbm: *gbm_device, width: u32, height: u32, format: u32, modifiers: [*]const u64, count: c_uint, flags: u32) ?*gbm_bo;
pub extern "c" fn gbm_bo_destroy(bo: *gbm_bo) void;
pub extern "c" fn gbm_bo_get_fd(bo: *gbm_bo) c_int;
pub extern "c" fn gbm_bo_get_stride(bo: *gbm_bo) u32;
pub extern "c" fn gbm_bo_get_offset(bo: *gbm_bo, plane: c_int) u32;
pub extern "c" fn gbm_bo_get_modifier(bo: *gbm_bo) u64;

/// The modifiers a buffer may be allocated with so that both sides take it:
/// those of `compositor` the driver lists in `driver` as renderable
/// (`external_only[i]` unset), into `out`, in the compositor's order.
/// `driver` and `external_only` are parallel.
pub fn sharedRenderable(compositor: []const u64, driver: []const u64, external_only: []const EGLBoolean, out: []u64) []u64 {
    var n: usize = 0;
    for (compositor) |m| {
        if (n == out.len) break;
        for (driver, external_only) |d, ext| {
            if (d == m and ext == 0) {
                out[n] = m;
                n += 1;
                break;
            }
        }
    }
    return out[0..n];
}

test "sharedRenderable keeps what the compositor imports and the driver renders to" {
    const testing = @import("std").testing;
    var out: [4]u64 = undefined;
    // 7 is sample-only for the driver, 9 unknown to it, 5 to the compositor.
    try testing.expectEqualSlices(u64, &.{ 3, 1 }, sharedRenderable(&.{ 3, 7, 9, 1 }, &.{ 1, 3, 5, 7 }, &.{ 0, 0, 0, 1 }, &out));
    try testing.expectEqualSlices(u64, &.{}, sharedRenderable(&.{}, &.{1}, &.{0}, &out));
    try testing.expectEqualSlices(u64, &.{}, sharedRenderable(&.{1}, &.{}, &.{}, &out));
    var one: [1]u64 = undefined;
    try testing.expectEqualSlices(u64, &.{1}, sharedRenderable(&.{ 1, 3 }, &.{ 1, 3 }, &.{ 0, 0 }, &one));
}
