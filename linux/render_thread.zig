//! The main window's renderer off the GTK thread (--renderer=thread). A
//! thread owns a surfaceless EGL context on the GBM render node and draws
//! each frame into one of a few dmabufs. on_flush_end wakes the thread
//! directly from the core thread, so a commit is drawn without waiting for
//! the GTK loop.
//!
//! On Wayland the thread commits each buffer itself to a subsurface below
//! the window (wl_dmabuf.c), desynchronized from it: a frame reaches the
//! compositor as soon as it is drawn, without GTK's frame cycle, as a
//! client drawing its own surface does. The window above leaves the view
//! clear (.zonvie-subsurface), so its widgets stay over the frames. The
//! compositor is never handed a buffer it did not list: each has a
//! modifier the compositor lists and the driver renders to, or an implicit
//! one where the compositor takes those. Elsewhere (X11, nothing shared,
//! a buffer refused) GTK shows the newest buffer as a GdkDmabufTexture in
//! a GtkPicture, and the GTK thread only swaps the texture.
//!
//! A buffer is free, rendering (the thread draws into it), attached (on
//! the subsurface until the compositor releases it), ready (drawn, waiting
//! for the GTK idle) or shown (a GdkTexture holds it). The texture's
//! destroy notify frees it; a ready buffer a newer one overtook is freed at
//! once. Buffer states, `requested`, the wanted size and `ready` are guarded
//! by `mu`; GL and GBM objects belong to the thread. `frames` and the
//! buffers' wl_buffers are guarded by `frames_mu`, taken before `mu`.

const std = @import("std");
const core = @import("zonvie_core");
const clock = core.clock;
const App = @import("app.zig").App;
const gl = @import("gl.zig");
const egl = @import("egl.zig");
const gtk = @import("gtk_bindings.zig");
const gl_renderer = @import("renderer/gl_renderer.zig");
const postfx = @import("renderer/postfx.zig");
const applog = @import("app_log.zig");

const pool_len = 3;
const max_modifiers = 64;

extern "c" fn zonvie_wl_dmabuf_modifiers(display: *anyopaque, fourcc: u32, out: [*]u64, cap: c_int, implicit: *c_int) c_int;
extern "c" fn gdk_display_get_default() ?*anyopaque;
extern "c" fn gdk_wayland_display_get_type() usize;
extern "c" fn gdk_wayland_display_get_wl_display(display: *anyopaque) ?*anyopaque;
extern "c" fn g_type_check_instance_is_a(instance: ?*anyopaque, gtype: usize) c_int;
extern "c" fn gdk_wayland_display_get_wl_compositor(display: *anyopaque) ?*anyopaque;
extern "c" fn gdk_wayland_surface_get_wl_surface(surface: *anyopaque) ?*anyopaque;
extern "c" fn zonvie_wl_frames_create(display: *anyopaque, compositor: *anyopaque, parent: *anyopaque) ?*anyopaque;
extern "c" fn zonvie_wl_frames_destroy(f: *anyopaque) void;
extern "c" fn zonvie_wl_frames_position(f: *anyopaque, x: i32, y: i32) void;
extern "c" fn zonvie_wl_frames_buffer(f: *anyopaque, fd: c_int, w: u32, h: u32, stride: u32, offset: u32, modifier: u64, fourcc: u32, release: *const fn (?*anyopaque) callconv(.c) void, data: ?*anyopaque) ?*anyopaque;
extern "c" fn zonvie_wl_frames_destroy_buffer(buffer: *anyopaque) void;
extern "c" fn zonvie_wl_frames_present(f: *anyopaque, buffer: *anyopaque, scale: i32) void;
extern "c" fn zonvie_wl_frames_dispatch(f: *anyopaque, timeout_ms: c_int) c_int;

/// How long the thread waits at a time for the compositor to release a
/// buffer when all are taken: short, as it holds frames_mu meanwhile.
const release_wait_ms = 2;

const State = enum { free, rendering, attached, ready, shown };

const Buffer = struct {
    rt: *RenderThread,
    state: State = .free,
    /// App.flush_seq the buffer was drawn from.
    seq: u64 = 0,
    // Render thread only.
    bo: ?*egl.gbm_bo = null,
    fd: c_int = -1,
    stride: u32 = 0,
    offset: u32 = 0,
    modifier: u64 = 0,
    /// The compositor imports this buffer: its modifier is one of
    /// RenderThread.modifiers, or implicit where RenderThread.implicit.
    shared: bool = false,
    image: egl.EGLImage = null,
    tex: u32 = 0,
    fbo: u32 = 0,
    w: u32 = 0,
    h: u32 = 0,
    /// Buffer px per surface px.
    scale: u32 = 1,
    /// The compositor's handle on the buffer, made the first time it goes
    /// to the subsurface. Guarded by RenderThread.frames_mu.
    wl_buffer: ?*anyopaque = null,
};

pub const RenderThread = struct {
    app: *App,
    thread: ?std.Thread = null,
    mu: std.Io.Mutex = .init,
    cond: std.Io.Condition = .init,
    requested: bool = false,
    quit: bool = false,
    want_w: u32 = 0,
    want_h: u32 = 0,
    want_scale: u32 = 1,
    buffers: [pool_len]Buffer = undefined,
    ready: ?usize = null,
    present_queued: std.atomic.Value(bool) = .init(false),
    /// When the latest frame finished, for the handoff log.
    ready_ns: i128 = 0,
    ease_queued: std.atomic.Value(bool) = .init(false),

    drm_fd: c_int = -1,
    gbm: ?*egl.gbm_device = null,
    dpy: egl.EGLDisplay = null,
    ctx: egl.EGLContext = null,
    create_image: egl.PfnCreateImage = undefined,
    destroy_image: egl.PfnDestroyImage = undefined,
    image_target: egl.PfnImageTargetTexture2D = undefined,
    /// EGL_ANDROID_native_fence_sync, where the driver has it.
    fence: ?struct {
        create: egl.PfnCreateSync,
        destroy: egl.PfnDestroySync,
        dup_fd: egl.PfnDupNativeFenceFd,
    } = null,
    target: gl_renderer.Target = .{ .flip_y = true },
    /// The bloom and shader chain in this thread's context.
    postfx: postfx.PostFx = .{},
    /// Some shader reads time; the GTK tick keeps requesting frames.
    animating: std.atomic.Value(bool) = .init(false),

    /// What a buffer may be allocated with for the compositor to import
    /// it; none off Wayland. Fixed once created.
    modifiers: [max_modifiers]u64 = undefined,
    modifiers_len: usize = 0,
    /// The compositor imports a buffer with an implicit modifier. Fixed
    /// once created.
    implicit: bool = false,

    frames_mu: std.Io.Mutex = .init,
    /// The subsurface while the window is mapped on Wayland. Set and
    /// cleared on the GTK thread, under frames_mu.
    frames: ?*anyopaque = null,
    /// The newest frame committed to the subsurface, for the GTK idle
    /// that reports it. Guarded by `mu`.
    committed_seq: u64 = 0,
    committed_ns: i128 = 0,
    committed_queued: std.atomic.Value(bool) = .init(false),
    /// The compositor refused a buffer: the frames stay with GTK.
    refused: std.atomic.Value(bool) = .init(false),

    // GTK thread only.
    picture: ?*anyopaque = null,
    window: ?*anyopaque = null,
    /// The window's frame clock and its layout handler while attached.
    clock: ?*anyopaque = null,
    layout_handler: c_ulong = 0,
    /// Where the subsurface was last placed, in the window's surface.
    pos: ?[2]i32 = null,

    /// Callable from any thread: draw the committed frame soon.
    pub fn request(self: *RenderThread) void {
        self.mu.lockUncancelable(clock.io());
        self.requested = true;
        self.mu.unlock(clock.io());
        self.cond.signal(clock.io());
    }

    /// GTK thread: the picture's size in device px, `scale` of them to
    /// its logical px.
    pub fn resize(self: *RenderThread, w_px: u32, h_px: u32, scale: u32) void {
        self.mu.lockUncancelable(clock.io());
        self.want_w = w_px;
        self.want_h = h_px;
        self.want_scale = scale;
        self.requested = true;
        self.mu.unlock(clock.io());
        self.cond.signal(clock.io());
    }
};

/// Opens EGL on the render node and starts the thread. Null when this
/// system cannot render into dmabufs; the caller falls back to the GLArea.
pub fn create(app: *App, picture: *anyopaque) ?*RenderThread {
    const rt = app.alloc.create(RenderThread) catch return null;
    rt.* = .{ .app = app, .picture = picture };
    for (&rt.buffers) |*b| b.* = .{ .rt = rt };
    if (!initEgl(rt)) {
        teardownEgl(rt);
        app.alloc.destroy(rt);
        return null;
    }
    rt.thread = std.Thread.spawn(.{}, run, .{rt}) catch {
        teardownEgl(rt);
        app.alloc.destroy(rt);
        return null;
    };
    return rt;
}

/// Stops the thread and frees everything it owns. GTK thread, after the
/// picture no longer shows a frame (its textures may still be alive: their
/// destroy notify then touches nothing but freed state, so drop the
/// picture's paintable first).
pub fn destroy(rt: *RenderThread) void {
    rt.mu.lockUncancelable(clock.io());
    rt.quit = true;
    rt.mu.unlock(clock.io());
    rt.cond.signal(clock.io());
    if (rt.thread) |t| t.join();
    // The window's unmap detached it; here only if that never ran. The
    // thread destroyed the wl_buffers with the buffers.
    if (rt.frames) |f| zonvie_wl_frames_destroy(f);
    rt.frames = null;
    teardownEgl(rt);
    rt.app.alloc.destroy(rt);
}

fn initEgl(rt: *RenderThread) bool {
    rt.drm_fd = std.c.open("/dev/dri/renderD128", .{ .ACCMODE = .RDWR, .CLOEXEC = true });
    if (rt.drm_fd < 0) return fail("no render node");
    rt.gbm = egl.gbm_create_device(rt.drm_fd) orelse return fail("gbm_create_device");
    const gpd = egl.proc(egl.PfnGetPlatformDisplay, "eglGetPlatformDisplayEXT") orelse return fail("eglGetPlatformDisplayEXT");
    rt.dpy = gpd(egl.EGL_PLATFORM_GBM_KHR, rt.gbm, null);
    if (rt.dpy == null or egl.eglInitialize(rt.dpy, null, null) == 0) return fail("eglInitialize");
    const ext = std.mem.span(egl.eglQueryString(rt.dpy, egl.EGL_EXTENSIONS) orelse return fail("extensions"));
    for ([_][]const u8{ "EGL_KHR_surfaceless_context", "EGL_EXT_image_dma_buf_import", "EGL_EXT_image_dma_buf_import_modifiers" }) |e| {
        if (std.mem.indexOf(u8, ext, e) == null) return fail(e);
    }
    queryModifiers(rt);
    if (std.mem.indexOf(u8, ext, "EGL_ANDROID_native_fence_sync") != null) {
        if (egl.proc(egl.PfnCreateSync, "eglCreateSyncKHR")) |create_sync|
            if (egl.proc(egl.PfnDestroySync, "eglDestroySyncKHR")) |destroy_sync|
                if (egl.proc(egl.PfnDupNativeFenceFd, "eglDupNativeFenceFDANDROID")) |dup_fd| {
                    rt.fence = .{ .create = create_sync, .destroy = destroy_sync, .dup_fd = dup_fd };
                };
    }
    rt.create_image = egl.proc(egl.PfnCreateImage, "eglCreateImageKHR") orelse return fail("eglCreateImageKHR");
    rt.destroy_image = egl.proc(egl.PfnDestroyImage, "eglDestroyImageKHR") orelse return fail("eglDestroyImageKHR");
    rt.image_target = egl.proc(egl.PfnImageTargetTexture2D, "glEGLImageTargetTexture2DOES") orelse return fail("glEGLImageTargetTexture2DOES");
    if (egl.eglBindAPI(egl.EGL_OPENGL_API) == 0) return fail("eglBindAPI");
    const attribs = [_]egl.EGLint{
        egl.EGL_CONTEXT_MAJOR_VERSION,       3,
        egl.EGL_CONTEXT_MINOR_VERSION,       3,
        egl.EGL_CONTEXT_OPENGL_PROFILE_MASK, egl.EGL_CONTEXT_OPENGL_CORE_PROFILE_BIT,
        egl.EGL_NONE,
    };
    rt.ctx = egl.eglCreateContext(rt.dpy, null, egl.EGL_NO_CONTEXT, &attribs);
    if (rt.ctx == null) return fail("eglCreateContext");
    return true;
}

/// Fills rt.modifiers and rt.implicit: nothing unless this is a Wayland
/// session.
fn queryModifiers(rt: *RenderThread) void {
    const display = gdk_display_get_default() orelse return;
    if (g_type_check_instance_is_a(display, gdk_wayland_display_get_type()) == 0) return;
    const wl_display = gdk_wayland_display_get_wl_display(display) orelse return;
    var compositor: [max_modifiers]u64 = undefined;
    var implicit: c_int = 0;
    const n_compositor: usize = @intCast(zonvie_wl_dmabuf_modifiers(wl_display, egl.GBM_FORMAT_ARGB8888, &compositor, max_modifiers, &implicit));
    rt.implicit = implicit != 0;
    var driver: [max_modifiers]u64 = undefined;
    var external_only: [max_modifiers]egl.EGLBoolean = undefined;
    var n_driver: egl.EGLint = 0;
    if (egl.proc(egl.PfnQueryDmaBufModifiers, "eglQueryDmaBufModifiersEXT")) |query| {
        if (query(rt.dpy, @bitCast(egl.GBM_FORMAT_ARGB8888), max_modifiers, &driver, &external_only, &n_driver) == 0) n_driver = 0;
    }
    const n: usize = @intCast(n_driver);
    rt.modifiers_len = egl.sharedRenderable(compositor[0..n_compositor], driver[0..n], external_only[0..n], &rt.modifiers).len;
    applog.appLog("[render_thread] modifiers: compositor={d} driver={d} shared={d} implicit={}\n", .{ n_compositor, n, rt.modifiers_len, rt.implicit });
}

fn fail(what: []const u8) bool {
    applog.appLog("[render_thread] unavailable: {s}\n", .{what});
    return false;
}

fn teardownEgl(rt: *RenderThread) void {
    if (rt.ctx != null) _ = egl.eglDestroyContext(rt.dpy, rt.ctx);
    if (rt.dpy != null) _ = egl.eglTerminate(rt.dpy);
    if (rt.gbm) |g| egl.gbm_device_destroy(g);
    if (rt.drm_fd >= 0) _ = std.c.close(rt.drm_fd);
}

fn run(rt: *RenderThread) void {
    if (egl.eglMakeCurrent(rt.dpy, null, null, rt.ctx) == 0 or !gl_renderer.realize(&rt.target)) {
        applog.appLog("[render_thread] context setup failed\n", .{});
        return;
    }
    const io = clock.io();
    while (true) {
        rt.mu.lockUncancelable(io);
        var idx: ?usize = null;
        while (!rt.quit) {
            if (rt.requested and rt.want_w != 0 and rt.want_h != 0) {
                idx = for (rt.buffers, 0..) |b, i| {
                    if (b.state == .free) break i;
                } else null;
                if (idx != null) break;
                const attached = for (rt.buffers) |b| {
                    if (b.state == .attached) break true;
                } else false;
                if (attached) {
                    // Only the compositor frees one now.
                    rt.mu.unlock(io);
                    pump(rt, release_wait_ms);
                    rt.mu.lockUncancelable(io);
                    continue;
                }
            }
            rt.cond.waitUncancelable(io, &rt.mu);
        }
        if (rt.quit) {
            rt.mu.unlock(io);
            break;
        }
        rt.requested = false;
        const i = idx.?;
        rt.buffers[i].state = .rendering;
        const w = rt.want_w;
        const h = rt.want_h;
        const scale = rt.want_scale;
        rt.mu.unlock(io);

        const b = &rt.buffers[i];
        if (!ensureBuffer(rt, b, w, h, scale)) {
            setState(rt, b, .free);
            continue;
        }
        const t_start = clock.nowNs();
        gl.glBindFramebuffer(gl.GL_FRAMEBUFFER, b.fbo);
        rt.target.w_px = w;
        rt.target.h_px = h;
        const f = if (postfx.active(rt.app, &rt.postfx))
            postfx.renderFrame(rt.app, &rt.target, &rt.postfx, 1)
        else
            gl_renderer.renderMain(rt.app, &rt.target);
        rt.animating.store(rt.postfx.animating, .release);
        const t_drawn = clock.nowNs();
        // The dmabuf goes to another process: the frame must be complete
        // before it is read there.
        if (!fenceBuffer(rt, b)) gl.glFinish();
        if (applog.isEnabled()) applog.appLog("[perf] render_thread draw_us={d} finish_us={d}\n", .{ @divTrunc(t_drawn - t_start, 1000), @divTrunc(clock.nowNs() - t_drawn, 1000) });
        rt.ready_ns = clock.nowNs();

        if (!presentSubsurface(rt, b, f.flush_seq)) {
            rt.mu.lockUncancelable(io);
            b.seq = f.flush_seq;
            if (rt.ready) |old| rt.buffers[old].state = .free;
            rt.ready = i;
            b.state = .ready;
            rt.mu.unlock(io);
            if (!rt.present_queued.swap(true, .acq_rel)) _ = gtk.g_idle_add(&idlePresent, rt);
        }
        if ((f.moving or rt.postfx.animating) and !rt.ease_queued.swap(true, .acq_rel)) _ = gtk.g_idle_add(&idleStartEase, rt);
    }
    for (&rt.buffers) |*b| freeBuffer(rt, b);
    postfx.unrealize(&rt.postfx);
    gl_renderer.unrealize(&rt.target);
    rt.target.deinit(rt.app.alloc);
    _ = egl.eglMakeCurrent(rt.dpy, null, null, egl.EGL_NO_CONTEXT);
    _ = egl.eglReleaseThread();
}

/// DMA_BUF_IOCTL_IMPORT_SYNC_FILE (Linux 6.0): adds a sync_file to the
/// buffer's implicit fences; DMA_BUF_SYNC_WRITE makes readers wait for it.
const DMA_BUF_IOCTL_IMPORT_SYNC_FILE: u32 = 0x40086203;
const DMA_BUF_SYNC_WRITE: u32 = 2;
const ImportSyncFile = extern struct { flags: u32, fd: i32 };

/// Hands the frame's completion to the buffer instead of waiting for it:
/// the GPU fence of the commands just queued goes into the dmabuf's
/// implicit fences, which GTK's import and the compositor wait on. False
/// (nothing done) when the driver or kernel cannot, and the caller waits.
fn fenceBuffer(rt: *RenderThread, b: *Buffer) bool {
    const f = rt.fence orelse return false;
    const sync = f.create(rt.dpy, egl.EGL_SYNC_NATIVE_FENCE_ANDROID, null) orelse return false;
    // The fence's fd exists once the commands are submitted.
    gl.glFlush();
    const fd = f.dup_fd(rt.dpy, sync);
    _ = f.destroy(rt.dpy, sync);
    if (fd < 0) return false;
    defer _ = std.c.close(fd);
    var arg: ImportSyncFile = .{ .flags = DMA_BUF_SYNC_WRITE, .fd = fd };
    const rc = std.os.linux.ioctl(b.fd, DMA_BUF_IOCTL_IMPORT_SYNC_FILE, @intFromPtr(&arg));
    if (std.os.linux.errno(rc) != .SUCCESS) {
        // An older kernel: it stays so.
        rt.fence = null;
        applog.appLog("[render_thread] no sync_file import; waiting for each frame\n", .{});
        return false;
    }
    return true;
}

fn setState(rt: *RenderThread, b: *Buffer, s: State) void {
    rt.mu.lockUncancelable(clock.io());
    b.state = s;
    rt.mu.unlock(clock.io());
    rt.cond.signal(clock.io());
}

/// A buffer of w x h: kept when it already is one, else made anew. A buffer
/// is only resized while free, so GTK never shows one being replaced.
fn ensureBuffer(rt: *RenderThread, b: *Buffer, w: u32, h: u32, scale: u32) bool {
    // Whole surface px: a scale that does not divide the buffer is a
    // protocol error.
    b.scale = if (scale > 1 and w % scale == 0 and h % scale == 0) scale else 1;
    if (b.fbo != 0 and b.w == w and b.h == h) return true;
    freeBuffer(rt, b);
    const mods = rt.modifiers[0..rt.modifiers_len];
    const explicit = if (mods.len != 0) egl.gbm_bo_create_with_modifiers2(rt.gbm.?, w, h, egl.GBM_FORMAT_ARGB8888, mods.ptr, @intCast(mods.len), egl.GBM_BO_USE_RENDERING) else null;
    const bo = explicit orelse egl.gbm_bo_create(rt.gbm.?, w, h, egl.GBM_FORMAT_ARGB8888, egl.GBM_BO_USE_RENDERING) orelse return false;
    b.bo = bo;
    b.fd = egl.gbm_bo_get_fd(bo);
    if (b.fd < 0) return false;
    b.stride = egl.gbm_bo_get_stride(bo);
    b.offset = egl.gbm_bo_get_offset(bo, 0);
    // GBM names no layout for a buffer it chose one for itself.
    b.modifier = if (explicit == null and rt.implicit) egl.DRM_FORMAT_MOD_INVALID else egl.gbm_bo_get_modifier(bo);
    b.shared = if (explicit == null) rt.implicit else std.mem.indexOfScalar(u64, mods, b.modifier) != null;
    var attribs = [_]egl.EGLint{
        egl.EGL_WIDTH,                          @intCast(w),
        egl.EGL_HEIGHT,                         @intCast(h),
        egl.EGL_LINUX_DRM_FOURCC_EXT,           @bitCast(egl.GBM_FORMAT_ARGB8888),
        egl.EGL_DMA_BUF_PLANE0_FD_EXT,          b.fd,
        egl.EGL_DMA_BUF_PLANE0_OFFSET_EXT,      @intCast(b.offset),
        egl.EGL_DMA_BUF_PLANE0_PITCH_EXT,       @intCast(b.stride),
        egl.EGL_DMA_BUF_PLANE0_MODIFIER_LO_EXT, @bitCast(@as(u32, @truncate(b.modifier))),
        egl.EGL_DMA_BUF_PLANE0_MODIFIER_HI_EXT, @bitCast(@as(u32, @truncate(b.modifier >> 32))),
        egl.EGL_NONE,
    };
    // An implicit modifier is given by naming none: the list ends before it.
    if (b.modifier == egl.DRM_FORMAT_MOD_INVALID) attribs[12] = egl.EGL_NONE;
    b.image = rt.create_image(rt.dpy, egl.EGL_NO_CONTEXT, egl.EGL_LINUX_DMA_BUF_EXT, null, &attribs);
    if (b.image == null) return false;
    gl.glGenTextures(1, &b.tex);
    gl.glBindTexture(gl.GL_TEXTURE_2D, b.tex);
    rt.image_target(gl.GL_TEXTURE_2D, b.image);
    gl.glGenFramebuffers(1, &b.fbo);
    gl.glBindFramebuffer(gl.GL_FRAMEBUFFER, b.fbo);
    gl.glFramebufferTexture2D(gl.GL_FRAMEBUFFER, gl.GL_COLOR_ATTACHMENT0, gl.GL_TEXTURE_2D, b.tex, 0);
    if (gl.glCheckFramebufferStatus(gl.GL_FRAMEBUFFER) != gl.GL_FRAMEBUFFER_COMPLETE) return false;
    b.w = w;
    b.h = h;
    return true;
}

fn freeBuffer(rt: *RenderThread, b: *Buffer) void {
    rt.frames_mu.lockUncancelable(clock.io());
    if (b.wl_buffer) |wb| zonvie_wl_frames_destroy_buffer(wb);
    b.wl_buffer = null;
    rt.frames_mu.unlock(clock.io());
    if (b.fbo != 0) gl.glDeleteFramebuffers(1, &b.fbo);
    if (b.tex != 0) gl.glDeleteTextures(1, &b.tex);
    if (b.image != null) _ = rt.destroy_image(rt.dpy, b.image);
    if (b.fd >= 0) _ = std.c.close(b.fd);
    if (b.bo) |bo| egl.gbm_bo_destroy(bo);
    b.fbo = 0;
    b.tex = 0;
    b.image = null;
    b.fd = -1;
    b.bo = null;
    b.w = 0;
    b.h = 0;
}

/// GTK thread: show the newest drawn buffer.
fn idlePresent(data: ?*anyopaque) callconv(.c) c_int {
    const rt: *RenderThread = @ptrCast(@alignCast(data.?));
    rt.present_queued.store(false, .release);
    rt.mu.lockUncancelable(clock.io());
    const idx = rt.ready orelse {
        rt.mu.unlock(clock.io());
        return 0;
    };
    rt.ready = null;
    const b = &rt.buffers[idx];
    b.state = .shown;
    const seq = b.seq;
    // Fixed while shown: the thread resizes only free buffers.
    const w = b.w;
    const h = b.h;
    const fd = b.fd;
    const stride = b.stride;
    const offset = b.offset;
    const modifier = b.modifier;
    rt.mu.unlock(clock.io());

    const picture = rt.picture orelse return 0;
    const builder = gtk.gdk_dmabuf_texture_builder_new() orelse return releaseShown(b);
    defer gtk.g_object_unref(builder);
    gtk.gdk_dmabuf_texture_builder_set_display(builder, gtk.gtk_widget_get_display(picture));
    gtk.gdk_dmabuf_texture_builder_set_width(builder, w);
    gtk.gdk_dmabuf_texture_builder_set_height(builder, h);
    gtk.gdk_dmabuf_texture_builder_set_fourcc(builder, egl.GBM_FORMAT_ARGB8888);
    gtk.gdk_dmabuf_texture_builder_set_modifier(builder, modifier);
    gtk.gdk_dmabuf_texture_builder_set_n_planes(builder, 1);
    gtk.gdk_dmabuf_texture_builder_set_fd(builder, 0, fd);
    gtk.gdk_dmabuf_texture_builder_set_stride(builder, 0, stride);
    gtk.gdk_dmabuf_texture_builder_set_offset(builder, 0, offset);
    var err: ?*anyopaque = null;
    const tex = gtk.gdk_dmabuf_texture_builder_build(builder, &onTextureDestroy, b, &err) orelse {
        if (err) |e| gtk.g_error_free(e);
        applog.appLog("[render_thread] dmabuf texture build failed\n", .{});
        return releaseShown(b);
    };
    gtk.gtk_picture_set_paintable(picture, tex);
    // In the frame cycle the new paintable starts (callbacks.idleQueueRender).
    @import("input.zig").updateImeCursor(rt.app);
    if (applog.isEnabled()) applog.appLog("[perf] render_thread handoff_us={d}\n", .{@divTrunc(clock.nowNs() - rt.ready_ns, 1000)});
    gtk.g_object_unref(tex);
    rt.app.presented_seq = seq;
    rt.app.presented_ns = clock.nowNs();
    if (applog.isEnabled()) applog.appLog("[trace] event=frame_done surface=1\n", .{});
    return 0;
}

// ---------------------------------------------------------------------------
// The subsurface

/// Render thread: commits `b`, just drawn from commit `seq`, to the
/// subsurface. False when there is none, or the compositor cannot take
/// this buffer (the frames then go to GTK from now on).
fn presentSubsurface(rt: *RenderThread, b: *Buffer, seq: u64) bool {
    const io = clock.io();
    rt.frames_mu.lockUncancelable(io);
    defer rt.frames_mu.unlock(io);
    const f = rt.frames orelse return false;
    if (b.wl_buffer == null and b.shared)
        b.wl_buffer = zonvie_wl_frames_buffer(f, b.fd, b.w, b.h, b.stride, b.offset, b.modifier, egl.GBM_FORMAT_ARGB8888, &onRelease, b);
    const wb = b.wl_buffer orelse {
        if (!rt.refused.swap(true, .acq_rel)) {
            applog.appLog("[render_thread] the compositor cannot take a buffer; frames go through GTK\n", .{});
            _ = gtk.g_idle_add(&idleRefused, rt);
        }
        return false;
    };
    rt.mu.lockUncancelable(io);
    b.seq = seq;
    b.state = .attached;
    rt.mu.unlock(io);
    zonvie_wl_frames_present(f, wb, @intCast(b.scale));
    rt.mu.lockUncancelable(io);
    rt.committed_seq = seq;
    rt.committed_ns = clock.nowNs();
    rt.mu.unlock(io);
    if (!rt.committed_queued.swap(true, .acq_rel)) _ = gtk.g_idle_add(&idleCommitted, rt);
    return true;
}

/// The compositor is done with a buffer: on the render thread, inside its
/// dispatch of the subsurface's queue (pump).
fn onRelease(data: ?*anyopaque) callconv(.c) void {
    const b: *Buffer = @ptrCast(@alignCast(data.?));
    b.rt.mu.lockUncancelable(clock.io());
    if (b.state == .attached) b.state = .free;
    b.rt.mu.unlock(clock.io());
}

/// Render thread: takes the compositor's releases, waiting up to
/// `timeout_ms` for one.
fn pump(rt: *RenderThread, timeout_ms: c_int) void {
    rt.frames_mu.lockUncancelable(clock.io());
    defer rt.frames_mu.unlock(clock.io());
    const f = rt.frames orelse return;
    if (zonvie_wl_frames_dispatch(f, timeout_ms) < 0) applog.appLog("[render_thread] subsurface dispatch failed\n", .{});
}

/// GTK thread: reports the newest commit to the subsurface, as idlePresent
/// does a frame GTK shows.
fn idleCommitted(data: ?*anyopaque) callconv(.c) c_int {
    const rt: *RenderThread = @ptrCast(@alignCast(data.?));
    rt.committed_queued.store(false, .release);
    rt.mu.lockUncancelable(clock.io());
    const seq = rt.committed_seq;
    const ns = rt.committed_ns;
    rt.mu.unlock(clock.io());
    // The subsurface shows from here: the picture over it would hide it.
    if (rt.picture) |p| gtk.gtk_picture_set_paintable(p, null);
    rt.app.presented_seq = seq;
    rt.app.presented_ns = ns;
    @import("latency_bench.zig").presented(rt.app);
    @import("input.zig").updateImeCursor(rt.app);
    if (applog.isEnabled()) applog.appLog("[trace] event=frame_done surface=1\n", .{});
    return 0;
}

fn idleRefused(data: ?*anyopaque) callconv(.c) c_int {
    const rt: *RenderThread = @ptrCast(@alignCast(data.?));
    detach(rt);
    rt.request();
    return 0;
}

/// GTK thread: places the frames under `window` from its every map, on a
/// Wayland session where the compositor takes the thread's buffers.
pub fn attachWindow(rt: *RenderThread, window: *anyopaque) void {
    rt.window = window;
    if (rt.modifiers_len == 0 and !rt.implicit) return;
    _ = gtk.g_signal_connect(window, "map", @ptrCast(&onMap), rt);
    _ = gtk.g_signal_connect(window, "unmap", @ptrCast(&onUnmap), rt);
}

fn onMap(window: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const rt: *RenderThread = @ptrCast(@alignCast(data.?));
    if (rt.refused.load(.acquire) or rt.frames != null) return;
    const win = window.?;
    const display = gtk.gtk_widget_get_display(win) orelse return;
    const wl_display = gdk_wayland_display_get_wl_display(display) orelse return;
    const compositor = gdk_wayland_display_get_wl_compositor(display) orelse return;
    const surface = gtk.gtk_native_get_surface(win) orelse return;
    const parent = gdk_wayland_surface_get_wl_surface(surface) orelse return;
    const f = zonvie_wl_frames_create(wl_display, compositor, parent) orelse {
        applog.appLog("[render_thread] no subsurface: the compositor lacks dmabuf or subsurfaces\n", .{});
        return;
    };
    rt.frames_mu.lockUncancelable(clock.io());
    rt.frames = f;
    rt.frames_mu.unlock(clock.io());
    rt.pos = null;
    place(rt);
    if (gtk.gdk_surface_get_frame_clock(surface)) |fc| {
        rt.clock = gtk.g_object_ref(fc);
        rt.layout_handler = gtk.g_signal_connect(fc, "layout", @ptrCast(&onLayout), rt);
    }
    gtk.gtk_widget_add_css_class(win, "zonvie-subsurface");
    applog.appLog("[render_thread] subsurface attached\n", .{});
    rt.request();
}

fn onUnmap(window: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    _ = window;
    detach(@ptrCast(@alignCast(data.?)));
}

/// GTK thread: the subsurface goes, and the buffers it held are free; the
/// window covers the view again.
fn detach(rt: *RenderThread) void {
    const io = clock.io();
    rt.frames_mu.lockUncancelable(io);
    const f = rt.frames orelse {
        rt.frames_mu.unlock(io);
        return;
    };
    for (&rt.buffers) |*b| if (b.wl_buffer) |wb| {
        zonvie_wl_frames_destroy_buffer(wb);
        b.wl_buffer = null;
    };
    zonvie_wl_frames_destroy(f);
    rt.frames = null;
    rt.mu.lockUncancelable(io);
    for (&rt.buffers) |*b| if (b.state == .attached) {
        b.state = .free;
    };
    rt.mu.unlock(io);
    rt.frames_mu.unlock(io);
    rt.cond.signal(io);
    if (rt.clock) |fc| {
        gtk.g_signal_handler_disconnect(fc, rt.layout_handler);
        gtk.g_object_unref(fc);
    }
    rt.clock = null;
    if (rt.window) |w| gtk.gtk_widget_remove_css_class(w, "zonvie-subsurface");
    applog.appLog("[render_thread] subsurface detached\n", .{});
}

/// Each frame GTK lays out: the subsurface follows the view, from the
/// commit of the frame that moved it.
fn onLayout(frame_clock: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    _ = frame_clock;
    place(@ptrCast(@alignCast(data.?)));
}

/// GTK thread: moves the subsurface under the picture, in the window
/// surface's coordinates (the window may sit inset in its surface).
fn place(rt: *RenderThread) void {
    const f = rt.frames orelse return;
    const win = rt.window orelse return;
    const picture = rt.picture orelse return;
    var r: gtk.GrapheneRect = .{};
    if (gtk.gtk_widget_compute_bounds(picture, win, &r) == 0) return;
    var sx: f64 = 0;
    var sy: f64 = 0;
    gtk.gtk_native_get_surface_transform(win, &sx, &sy);
    const pos: [2]i32 = .{ @intFromFloat(@round(sx + r.x)), @intFromFloat(@round(sy + r.y)) };
    if (rt.pos) |p| if (p[0] == pos[0] and p[1] == pos[1]) return;
    rt.pos = pos;
    zonvie_wl_frames_position(f, pos[0], pos[1]);
}

fn releaseShown(b: *Buffer) c_int {
    setState(b.rt, b, .free);
    return 0;
}

/// GDK dropped the texture: its buffer may be drawn into again.
fn onTextureDestroy(data: ?*anyopaque) callconv(.c) void {
    const b: *Buffer = @ptrCast(@alignCast(data.?));
    setState(b.rt, b, .free);
}

fn idleStartEase(data: ?*anyopaque) callconv(.c) c_int {
    const rt: *RenderThread = @ptrCast(@alignCast(data.?));
    rt.ease_queued.store(false, .release);
    gl_renderer.startEaseTick(rt.app);
    return 0;
}
