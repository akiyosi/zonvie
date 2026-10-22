//! The main window's renderer off the GTK thread (--renderer=thread). A
//! thread owns a surfaceless EGL context on the GBM render node and draws
//! each frame into one of a few dmabufs; GTK shows the newest as a
//! GdkDmabufTexture in a GtkPicture. on_flush_end wakes the thread directly
//! from the core thread, so a commit is drawn without waiting for the GTK
//! loop, and the GTK thread only swaps a texture.
//!
//! A buffer is free, rendering (the thread draws into it), ready (drawn,
//! waiting for the GTK idle) or shown (a GdkTexture holds it). The texture's
//! destroy notify frees it; a ready buffer a newer one overtook is freed at
//! once. Buffer states, `requested`, the wanted size and `ready` are guarded
//! by `mu`; GL and GBM objects belong to the thread.

const std = @import("std");
const core = @import("zonvie_core");
const clock = core.clock;
const App = @import("app.zig").App;
const gl = @import("gl.zig");
const egl = @import("egl.zig");
const gtk = @import("gtk_bindings.zig");
const gl_renderer = @import("renderer/gl_renderer.zig");
const applog = @import("app_log.zig");

const pool_len = 3;

const State = enum { free, rendering, ready, shown };

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
    image: egl.EGLImage = null,
    tex: u32 = 0,
    fbo: u32 = 0,
    w: u32 = 0,
    h: u32 = 0,
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
    target: gl_renderer.Target = .{ .flip_y = true },

    // GTK thread only.
    picture: ?*anyopaque = null,

    /// Callable from any thread: draw the committed frame soon.
    pub fn request(self: *RenderThread) void {
        self.mu.lockUncancelable(clock.io());
        self.requested = true;
        self.mu.unlock(clock.io());
        self.cond.signal(clock.io());
    }

    /// GTK thread: the picture's size in device px.
    pub fn resize(self: *RenderThread, w_px: u32, h_px: u32) void {
        self.mu.lockUncancelable(clock.io());
        self.want_w = w_px;
        self.want_h = h_px;
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
        rt.mu.unlock(io);

        const b = &rt.buffers[i];
        if (!ensureBuffer(rt, b, w, h)) {
            setState(rt, b, .free);
            continue;
        }
        const t_start = clock.nowNs();
        gl.glBindFramebuffer(gl.GL_FRAMEBUFFER, b.fbo);
        rt.target.w_px = w;
        rt.target.h_px = h;
        const f = gl_renderer.renderMain(rt.app, &rt.target);
        const t_drawn = clock.nowNs();
        // The dmabuf goes to another process: the frame must be complete.
        gl.glFinish();
        if (applog.isEnabled()) applog.appLog("[perf] render_thread draw_us={d} finish_us={d}\n", .{ @divTrunc(t_drawn - t_start, 1000), @divTrunc(clock.nowNs() - t_drawn, 1000) });
        rt.ready_ns = clock.nowNs();

        rt.mu.lockUncancelable(io);
        b.seq = f.flush_seq;
        if (rt.ready) |old| rt.buffers[old].state = .free;
        rt.ready = i;
        b.state = .ready;
        rt.mu.unlock(io);
        if (!rt.present_queued.swap(true, .acq_rel)) _ = gtk.g_idle_add(&idlePresent, rt);
        if (f.moving and !rt.ease_queued.swap(true, .acq_rel)) _ = gtk.g_idle_add(&idleStartEase, rt);
    }
    for (&rt.buffers) |*b| freeBuffer(rt, b);
    gl_renderer.unrealize(&rt.target);
    rt.target.deinit(rt.app.alloc);
    _ = egl.eglMakeCurrent(rt.dpy, null, null, egl.EGL_NO_CONTEXT);
    _ = egl.eglReleaseThread();
}

fn setState(rt: *RenderThread, b: *Buffer, s: State) void {
    rt.mu.lockUncancelable(clock.io());
    b.state = s;
    rt.mu.unlock(clock.io());
    rt.cond.signal(clock.io());
}

/// A buffer of w x h: kept when it already is one, else made anew. A buffer
/// is only resized while free, so GTK never shows one being replaced.
fn ensureBuffer(rt: *RenderThread, b: *Buffer, w: u32, h: u32) bool {
    if (b.fbo != 0 and b.w == w and b.h == h) return true;
    freeBuffer(rt, b);
    const bo = egl.gbm_bo_create(rt.gbm.?, w, h, egl.GBM_FORMAT_XRGB8888, egl.GBM_BO_USE_RENDERING) orelse return false;
    b.bo = bo;
    b.fd = egl.gbm_bo_get_fd(bo);
    if (b.fd < 0) return false;
    b.stride = egl.gbm_bo_get_stride(bo);
    b.offset = egl.gbm_bo_get_offset(bo, 0);
    b.modifier = egl.gbm_bo_get_modifier(bo);
    const attribs = [_]egl.EGLint{
        egl.EGL_WIDTH,                          @intCast(w),
        egl.EGL_HEIGHT,                         @intCast(h),
        egl.EGL_LINUX_DRM_FOURCC_EXT,           @bitCast(egl.GBM_FORMAT_XRGB8888),
        egl.EGL_DMA_BUF_PLANE0_FD_EXT,          b.fd,
        egl.EGL_DMA_BUF_PLANE0_OFFSET_EXT,      @intCast(b.offset),
        egl.EGL_DMA_BUF_PLANE0_PITCH_EXT,       @intCast(b.stride),
        egl.EGL_DMA_BUF_PLANE0_MODIFIER_LO_EXT, @bitCast(@as(u32, @truncate(b.modifier))),
        egl.EGL_DMA_BUF_PLANE0_MODIFIER_HI_EXT, @bitCast(@as(u32, @truncate(b.modifier >> 32))),
        egl.EGL_NONE,
    };
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
    gtk.gdk_dmabuf_texture_builder_set_fourcc(builder, egl.GBM_FORMAT_XRGB8888);
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
    if (applog.isEnabled()) applog.appLog("[perf] render_thread handoff_us={d}\n", .{@divTrunc(clock.nowNs() - rt.ready_ns, 1000)});
    gtk.g_object_unref(tex);
    rt.app.presented_seq = seq;
    rt.app.presented_ns = clock.nowNs();
    if (applog.isEnabled()) applog.appLog("[trace] event=frame_done surface=1\n", .{});
    return 0;
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
