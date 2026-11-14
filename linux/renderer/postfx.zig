//! The main window's post-processing: the neon glow bloom
//! (vim.g.zonvie_glow) and the custom shader chain ([shaders] in
//! config.toml). When either is active the grid is drawn into an offscreen
//! texture, stored top-down as the Shadertoy preamble's vUV expects; the
//! bloom is added onto it, then each custom shader reads the previous
//! output and the last one writes the GLArea's framebuffer. Same passes as
//! the D3D11 renderer (windows/shaders/main.hlsl, PSKawase*); the chain's
//! geometry is the core's (glow_chain.zig). Each PostFx belongs to one GL
//! context and is used only on the thread that has it current: a GLArea's
//! on the GTK main thread, the render thread's on that thread.

const std = @import("std");
const core = @import("zonvie_core");
const clock = core.clock;
const gl = @import("../gl.zig");
const App = @import("../app.zig").App;
const gl_renderer = @import("gl_renderer.zig");
const applog = @import("../app_log.zig");

const glow_chain = core.glow_chain;
const Uniforms = core.zonvie_shader_uniforms;

/// A colour target: a texture and the framebuffer that renders into it.
const Rt = struct {
    fbo: u32 = 0,
    tex: u32 = 0,
    w: u32 = 0,
    h: u32 = 0,

    /// (Re)allocates at w x h; a no-op at that size already.
    fn ensure(self: *Rt, w: u32, h: u32) void {
        if (self.tex != 0 and self.w == w and self.h == h) return;
        if (self.tex == 0) gl.glGenTextures(1, &self.tex);
        if (self.fbo == 0) gl.glGenFramebuffers(1, &self.fbo);
        gl.glBindTexture(gl.GL_TEXTURE_2D, self.tex);
        gl.glTexImage2D(gl.GL_TEXTURE_2D, 0, gl.GL_RGBA8, @intCast(w), @intCast(h), 0, gl.GL_RGBA, gl.GL_UNSIGNED_BYTE, null);
        gl.glTexParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_MIN_FILTER, gl.GL_LINEAR);
        gl.glTexParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_MAG_FILTER, gl.GL_LINEAR);
        gl.glTexParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_WRAP_S, gl.GL_CLAMP_TO_EDGE);
        gl.glTexParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_WRAP_T, gl.GL_CLAMP_TO_EDGE);
        gl.glBindFramebuffer(gl.GL_FRAMEBUFFER, self.fbo);
        gl.glFramebufferTexture2D(gl.GL_FRAMEBUFFER, gl.GL_COLOR_ATTACHMENT0, gl.GL_TEXTURE_2D, self.tex, 0);
        // A new texture holds garbage; iPrevFrame reads it before any pass
        // has written it.
        gl.glClearColor(0, 0, 0, 0);
        gl.glClear(gl.GL_COLOR_BUFFER_BIT);
        self.w = w;
        self.h = h;
    }

    fn deinit(self: *Rt) void {
        if (self.fbo != 0) gl.glDeleteFramebuffers(1, &self.fbo);
        if (self.tex != 0) gl.glDeleteTextures(1, &self.tex);
        self.* = .{};
    }
};

/// A fullscreen pass program: our vertex stage and a fragment stage.
const Pass = struct {
    prog: u32 = 0,
    u_to_screen: i32 = -1,
    u_tex: i32 = -1,
    u_scale: i32 = -1,
    u_radius: i32 = -1,
};

/// One compiled custom shader.
const Custom = struct {
    pass: Pass = .{},
    u_prev: i32 = -1,
    u_age: i32 = -1,
    needs_animation: bool = false,
    /// Reads iPrevFrame (frontend_rules.shaderUsesPrevFrame).
    uses_prev: bool = false,
    /// Reads iCellAge or its companions (frontend_rules.shaderUsesEditInputs).
    uses_edit: bool = false,
};

const max_custom = 8;

pub const PostFx = struct {
    ready: bool = false,
    failed: bool = false,
    vao: u32 = 0,
    copy: Pass = .{},
    down: Pass = .{},
    up: Pass = .{},
    scene: Rt = .{},
    extract: Rt = .{},
    mips: [glow_chain.mip_count]Rt = @splat(.{}),
    ping: [2]Rt = @splat(.{}),
    custom: [max_custom]Custom = @splat(.{}),
    custom_len: usize = 0,
    ubo: u32 = 0,
    /// 1x1 black: what iPrevFrame and iCellAge read when no shader uses them.
    black: u32 = 0,
    /// The previous frame's final output, top-down, when a shader reads
    /// iPrevFrame; `out` takes this frame's, and the two swap.
    prev: Rt = .{},
    out: Rt = .{},
    uses_prev: bool = false,
    /// This surface's iCellAge: cols x rows R32F of edit times, when a shader
    /// reads it.
    age_tex: u32 = 0,
    age_cols: u32 = 0,
    age_rows: u32 = 0,
    age_cache: core.cell_age_store.SyncCache = .{},
    uses_edit: bool = false,
    /// Some shader reads time: the frame clock keeps drawing.
    animating: bool = false,
    start_ns: i128 = 0,
    last_ns: i128 = 0,
    frame: i32 = 0,
    uniforms: Uniforms = .{},
    cursor_cur: [4]f32 = .{ 0, 0, 0, 0 },
};

/// Whether a surface drawn with `p` needs the offscreen path this frame.
pub fn active(app: *App, p: *const PostFx) bool {
    if (p.failed) return false;
    if (app.shader_paths.len != 0) return true;
    const cp = app.corep orelse return false;
    return core.zonvie_core_get_glow_enabled(cp);
}

const vertex_src =
    \\#version 330 core
    \\// A triangle covering the target. UV is top-left origin, as the
    \\// Shadertoy preamble expects: offscreen textures are stored top-down,
    \\// and the screen (row 0 at the bottom) flips it back.
    \\uniform int u_to_screen;
    \\out vec2 vUV;
    \\void main() {
    \\    vec2 p = vec2(gl_VertexID == 1 ? 3.0 : -1.0, gl_VertexID == 2 ? 3.0 : -1.0);
    \\    gl_Position = vec4(p, 0.0, 1.0);
    \\    vec2 uv = (p + 1.0) * 0.5;
    \\    vUV = u_to_screen == 1 ? vec2(uv.x, 1.0 - uv.y) : uv;
    \\}
;

const copy_src =
    \\#version 330 core
    \\uniform sampler2D u_tex;
    \\uniform float u_scale;
    \\in vec2 vUV;
    \\out vec4 o;
    \\void main() { o = texture(u_tex, vUV) * u_scale; }
;

// Dual Kawase, as PSKawaseDown / PSKawaseUp; u_radius stretches the taps.
const down_src =
    \\#version 330 core
    \\uniform sampler2D u_tex;
    \\uniform float u_radius;
    \\in vec2 vUV;
    \\out vec4 o;
    \\void main() {
    \\    vec2 hp = (0.5 * u_radius) / vec2(textureSize(u_tex, 0));
    \\    vec4 s = texture(u_tex, vUV) * 4.0;
    \\    s += texture(u_tex, vUV + vec2(-hp.x, -hp.y));
    \\    s += texture(u_tex, vUV + vec2( hp.x, -hp.y));
    \\    s += texture(u_tex, vUV + vec2(-hp.x,  hp.y));
    \\    s += texture(u_tex, vUV + vec2( hp.x,  hp.y));
    \\    o = s / 8.0;
    \\}
;

const up_src =
    \\#version 330 core
    \\uniform sampler2D u_tex;
    \\uniform float u_radius;
    \\in vec2 vUV;
    \\out vec4 o;
    \\void main() {
    \\    vec2 hp = (0.5 * u_radius) / vec2(textureSize(u_tex, 0));
    \\    vec4 s = vec4(0.0);
    \\    s += texture(u_tex, vUV + vec2(-hp.x * 2.0, 0.0));
    \\    s += texture(u_tex, vUV + vec2(-hp.x,  hp.y)) * 2.0;
    \\    s += texture(u_tex, vUV + vec2(0.0,  hp.y * 2.0));
    \\    s += texture(u_tex, vUV + vec2( hp.x,  hp.y)) * 2.0;
    \\    s += texture(u_tex, vUV + vec2( hp.x * 2.0, 0.0));
    \\    s += texture(u_tex, vUV + vec2( hp.x, -hp.y)) * 2.0;
    \\    s += texture(u_tex, vUV + vec2(0.0, -hp.y * 2.0));
    \\    s += texture(u_tex, vUV + vec2(-hp.x, -hp.y)) * 2.0;
    \\    o = s / 12.0;
    \\}
;

fn compileStage(kind: gl.GLenum, src: []const u8, what: []const u8) ?u32 {
    const sh = gl.glCreateShader(kind);
    const srcs = [_][*c]const u8{src.ptr};
    const lens = [_]gl.GLint{@intCast(src.len)};
    gl.glShaderSource(sh, 1, &srcs, &lens);
    gl.glCompileShader(sh);
    var ok: gl.GLint = 0;
    gl.glGetShaderiv(sh, gl.GL_COMPILE_STATUS, &ok);
    if (ok != 0) return sh;
    var buf: [2048]u8 = undefined;
    var n: gl.GLsizei = 0;
    gl.glGetShaderInfoLog(sh, buf.len, &n, &buf);
    applog.appLog("[postfx] {s} compile failed: {s}\n", .{ what, buf[0..@intCast(n)] });
    gl.glDeleteShader(sh);
    return null;
}

fn link(fs_src: []const u8, what: []const u8) ?Pass {
    const vs = compileStage(gl.GL_VERTEX_SHADER, vertex_src, "fullscreen vertex") orelse return null;
    defer gl.glDeleteShader(vs);
    const fs = compileStage(gl.GL_FRAGMENT_SHADER, fs_src, what) orelse return null;
    defer gl.glDeleteShader(fs);
    const prog = gl.glCreateProgram();
    gl.glAttachShader(prog, vs);
    gl.glAttachShader(prog, fs);
    gl.glLinkProgram(prog);
    var ok: gl.GLint = 0;
    gl.glGetProgramiv(prog, gl.GL_LINK_STATUS, &ok);
    if (ok == 0) {
        var buf: [2048]u8 = undefined;
        var n: gl.GLsizei = 0;
        gl.glGetProgramInfoLog(prog, buf.len, &n, &buf);
        applog.appLog("[postfx] {s} link failed: {s}\n", .{ what, buf[0..@intCast(n)] });
        gl.glDeleteProgram(prog);
        return null;
    }
    return .{
        .prog = prog,
        .u_to_screen = gl.glGetUniformLocation(prog, "u_to_screen"),
        .u_tex = gl.glGetUniformLocation(prog, "u_tex"),
        .u_scale = gl.glGetUniformLocation(prog, "u_scale"),
        .u_radius = gl.glGetUniformLocation(prog, "u_radius"),
    };
}

/// Builds the passes and compiles the configured shaders. Once per context;
/// a failure turns post-processing off rather than drawing nothing.
fn setup(app: *App, p: *PostFx) bool {
    if (p.ready) return true;
    if (p.failed) return false;
    p.failed = true;
    gl.glGenVertexArrays(1, &p.vao);
    p.copy = link(copy_src, "copy") orelse return false;
    p.down = link(down_src, "kawase down") orelse return false;
    p.up = link(up_src, "kawase up") orelse return false;
    gl.glGenBuffers(1, &p.ubo);
    gl.glBindBuffer(gl.GL_UNIFORM_BUFFER, p.ubo);
    gl.glBufferData(gl.GL_UNIFORM_BUFFER, @sizeOf(Uniforms), null, gl.GL_DYNAMIC_DRAW);
    gl.glGenTextures(1, &p.black);
    gl.glBindTexture(gl.GL_TEXTURE_2D, p.black);
    const zero = [_]u8{ 0, 0, 0, 0 };
    gl.glTexImage2D(gl.GL_TEXTURE_2D, 0, gl.GL_RGBA8, 1, 1, 0, gl.GL_RGBA, gl.GL_UNSIGNED_BYTE, &zero);
    for (app.shader_paths) |path| {
        if (p.custom_len == max_custom) break;
        if (loadCustom(app, path)) |c| {
            p.custom[p.custom_len] = c;
            p.custom_len += 1;
            if (c.needs_animation) p.animating = true;
            if (c.uses_prev) p.uses_prev = true;
            if (c.uses_edit) p.uses_edit = true;
        }
    }
    // The core records no stamps until a shader wants them. Every window
    // compiles the same config, so the answer is the same for all.
    if (p.uses_edit) {
        if (app.corep) |cp| core.zonvie_core_set_shader_inputs_enabled(cp, 1);
    }
    p.ready = true;
    p.failed = false;
    return true;
}

/// One configured shader file: GLSL cross-compiled by the core to GLSL 330
/// (zonvie_shader_compile_glsl), linked against our vertex stage, its
/// samplers and uniform block bound by name.
fn loadCustom(app: *App, path: []const u8) ?Custom {
    const src = std.Io.Dir.cwd().readFileAlloc(clock.io(), path, app.alloc, .limited(4 * 1024 * 1024)) catch {
        applog.appLog("[postfx] cannot read shader {s}\n", .{path});
        return null;
    };
    defer app.alloc.free(src);
    // [shaders] preserve_alpha: the core's Shadertoy bridge keeps the
    // terminal's alpha under this define, as Windows compiles it. Only for
    // Shadertoy-style sources; a raw shader must start with #version.
    var with_define: ?[]u8 = null;
    defer if (with_define) |b| app.alloc.free(b);
    const define = "#define ZONVIE_PRESERVE_ALPHA 1\n";
    if (app.shader_preserve_alpha and std.mem.indexOf(u8, src, "mainImage") != null) {
        if (app.alloc.alloc(u8, define.len + src.len)) |b| {
            @memcpy(b[0..define.len], define);
            @memcpy(b[define.len..], src);
            with_define = b;
        } else |_| {}
    }
    const compile_src = with_define orelse src;
    var result = core.zonvie_shader_compile_glsl(compile_src.ptr, compile_src.len, .glsl);
    defer core.zonvie_shader_result_destroy(&result);
    const data = result.data orelse {
        applog.appLog("[postfx] {s}: {s}\n", .{ path, if (result.error_msg) |m| std.mem.span(m) else "compile failed" });
        return null;
    };
    const pass = link(data[0..result.data_len], path) orelse return null;
    const block = gl.glGetUniformBlockIndex(pass.prog, "ZonvieShaderUniforms");
    if (block != gl.GL_INVALID_INDEX) gl.glUniformBlockBinding(pass.prog, block, 1);
    gl.glUseProgram(pass.prog);
    gl.glUniform1i(gl.glGetUniformLocation(pass.prog, "zonvie_iChannel0Tex"), 0);
    const u_prev = gl.glGetUniformLocation(pass.prog, "zonvie_iPrevFrameTex");
    const u_age = gl.glGetUniformLocation(pass.prog, "iCellAge");
    if (u_prev >= 0) gl.glUniform1i(u_prev, 2);
    if (u_age >= 0) gl.glUniform1i(u_age, 3);
    applog.appLog("[postfx] loaded shader {s}\n", .{path});
    return .{
        .pass = pass,
        .u_prev = u_prev,
        .u_age = u_age,
        .needs_animation = core.zonvie_core_shader_needs_animation(src.ptr, src.len),
        .uses_prev = core.frontend_rules.shaderUsesPrevFrame(src),
        .uses_edit = core.frontend_rules.shaderUsesEditInputs(src),
    };
}

fn drawFullscreen(pass: Pass, tex: u32, to_screen: bool) void {
    gl.glUseProgram(pass.prog);
    if (pass.u_to_screen >= 0) gl.glUniform1i(pass.u_to_screen, @intFromBool(to_screen));
    if (pass.u_tex >= 0) gl.glUniform1i(pass.u_tex, 0);
    gl.glActiveTexture(gl.GL_TEXTURE0);
    gl.glBindTexture(gl.GL_TEXTURE_2D, tex);
    gl.glDrawArrays(gl.GL_TRIANGLES, 0, 3);
}

fn chainTex(p: *PostFx, idx: i32) *Rt {
    return if (idx == glow_chain.extract_target) &p.extract else &p.mips[@intCast(idx)];
}

/// Bloom over `p.scene`: extract the glow glyphs at half resolution, blur
/// down and up the core's chain, and add the result at the glow intensity.
fn bloom(app: *App, t: *gl_renderer.Target, p: *PostFx, cp: *core.zonvie_core, surface_id: i64) void {
    const radius = core.zonvie_core_get_glow_radius_scale(cp);
    const chain = glow_chain.plan(t.w_px, t.h_px, radius);
    p.extract.ensure(chain.half_w_px, chain.half_h_px);
    for (&p.mips, 0..) |*m, i| m.ensure(chain.mip_w_px[i], chain.mip_h_px[i]);

    gl.glBindFramebuffer(gl.GL_FRAMEBUFFER, p.extract.fbo);
    gl_renderer.drawGlowExtract(app, t, @as(f32, @floatFromInt(chain.half_w_px)) / @as(f32, @floatFromInt(@max(1, t.w_px))), surface_id);

    gl.glBindVertexArray(p.vao);
    gl.glDisable(gl.GL_BLEND);
    for ([_]bool{ true, false }) |going_down| {
        const passes = if (going_down) chain.down else chain.up;
        const prog = if (going_down) p.down else p.up;
        gl.glUseProgram(prog.prog);
        gl.glUniform1f(prog.u_radius, radius);
        for (passes[0..chain.level_count]) |pass| {
            const dst = chainTex(p, pass.dst);
            gl.glBindFramebuffer(gl.GL_FRAMEBUFFER, dst.fbo);
            gl.glViewport(0, 0, @intCast(pass.dst_w_px), @intCast(pass.dst_h_px));
            drawFullscreen(prog, chainTex(p, pass.src).tex, false);
        }
    }

    gl.glBindFramebuffer(gl.GL_FRAMEBUFFER, p.scene.fbo);
    gl.glViewport(0, 0, @intCast(t.w_px), @intCast(t.h_px));
    gl.glEnable(gl.GL_BLEND);
    gl.glBlendFunc(gl.GL_ONE, gl.GL_ONE);
    gl.glUseProgram(p.copy.prog);
    gl.glUniform1f(p.copy.u_scale, core.zonvie_core_get_glow_intensity(cp));
    drawFullscreen(p.copy, p.extract.tex, false);
}

/// The cursor as Ghostty's uniforms carry it: (left, bottom, w, h) in
/// drawable px, y down, and its colour; null when it is not on this surface.
/// Takes App.mu.
fn cursorState(app: *App, surface_id: i64) ?struct { rect: [4]f32, color: [4]f32 } {
    app.mu.lockUncancelable(clock.io());
    defer app.mu.unlock(clock.io());
    const cur = app.surface.committedCursor();
    if (cur.verts.len == 0) return null;
    const layer = for (app.surface.committedSurfaceLayers(surface_id)) |l| {
        if (l.grid_id == cur.grid_id) break l;
    } else return null;
    const b = core.cursor_rect.bounds(core.Vertex, cur.verts, @floatFromInt(layer.x_px), @floatFromInt(layer.y_px)) orelse return null;
    return .{ .rect = .{ b.left, b.bottom, b.width(), b.height() }, .color = cur.verts[0].color };
}

fn fillUniforms(app: *App, t: *const gl_renderer.Target, p: *PostFx, surface_id: i64) void {
    const now = clock.nowNs();
    if (p.start_ns == 0) {
        p.start_ns = now;
        p.last_ns = now;
    }
    const u = &p.uniforms;
    const w: f32 = @floatFromInt(t.w_px);
    const h: f32 = @floatFromInt(t.h_px);
    u.iResolution = .{ w, h, 1 };
    // From the app's epoch, shared with every window and the cell-age stamps.
    u.iTime = @floatCast(@as(f64, @floatFromInt(now - app.shader_epoch_ns)) / std.time.ns_per_s);
    u.iTimeDelta = @floatCast(@as(f64, @floatFromInt(now - p.last_ns)) / std.time.ns_per_s);
    if (u.iTimeDelta > 0) u.iFrameRate = 0.9 * u.iFrameRate + 0.1 * (1.0 / u.iTimeDelta);
    p.last_ns = now;
    u.iFrame = p.frame;
    p.frame +%= 1;
    u.iWindowOffset = .{ 0, 0 };
    u.iWindowSize = .{ w, h };
    const cursor = cursorState(app, surface_id);
    if (cursor) |c| {
        if (!std.mem.eql(f32, &c.rect, &p.cursor_cur)) {
            u.iPreviousCursor = u.iCurrentCursor;
            u.iPreviousCursorColor = u.iCurrentCursorColor;
            u.iTimeCursorChange = u.iTime;
            p.cursor_cur = c.rect;
        }
        u.iCurrentCursor = c.rect;
        u.iCurrentCursorColor = c.color;
    }
    // The rest by the core's rule, cursor styles included. The root grid
    // starts at the surface's corner.
    core.fillEditUniforms(
        u,
        @floatFromInt(app.cell_w_px),
        @floatFromInt(app.cell_h_px),
        .{ 0, 0 },
        p.age_cache.last_edit,
        cursor != null,
        p.uses_edit,
    );
}

/// The main surface (with its overlays), or an external window's.
fn scene(app: *App, t: *gl_renderer.Target, surface_id: i64) gl_renderer.Frame {
    return if (surface_id == 1) gl_renderer.renderMain(app, t) else gl_renderer.renderExternalScene(app, t, surface_id);
}

/// A surface through the bloom and the shader chain, ending in the
/// framebuffer bound on entry: a GLArea's (bottom-up), or the render
/// thread's dmabuf, top-down as `t.flip_y` says.
pub fn renderFrame(app: *App, t: *gl_renderer.Target, p: *PostFx, surface_id: i64) gl_renderer.Frame {
    var screen_fbo: gl.GLint = 0;
    gl.glGetIntegerv(gl.GL_FRAMEBUFFER_BINDING, &screen_fbo);
    if (!setup(app, p) or t.w_px == 0 or t.h_px == 0) return scene(app, t, surface_id);

    // Offscreen textures are top-down already; only a bottom-up screen
    // needs the final pass to flip.
    const screen_top_down = t.flip_y;
    const to_screen = !screen_top_down;
    p.scene.ensure(t.w_px, t.h_px);
    gl.glBindFramebuffer(gl.GL_FRAMEBUFFER, p.scene.fbo);
    t.flip_y = true;
    const f = scene(app, t, surface_id);
    if (app.corep) |cp| {
        if (core.zonvie_core_get_glow_enabled(cp)) bloom(app, t, p, cp, surface_id);
    }
    t.flip_y = screen_top_down;

    gl.glBindVertexArray(p.vao);
    gl.glDisable(gl.GL_BLEND);
    gl.glViewport(0, 0, @intCast(t.w_px), @intCast(t.h_px));
    if (p.custom_len == 0) {
        gl.glBindFramebuffer(gl.GL_FRAMEBUFFER, @intCast(screen_fbo));
        gl.glUseProgram(p.copy.prog);
        gl.glUniform1f(p.copy.u_scale, 1);
        drawFullscreen(p.copy, p.scene.tex, to_screen);
        return f;
    }

    if (p.uses_prev) {
        p.prev.ensure(t.w_px, t.h_px);
        p.out.ensure(t.w_px, t.h_px);
    }
    const age = if (p.uses_edit) syncCellAge(app, p, surface_id) else 0;
    fillUniforms(app, t, p, surface_id);
    gl.glBindBuffer(gl.GL_UNIFORM_BUFFER, p.ubo);
    gl.glBufferSubData(gl.GL_UNIFORM_BUFFER, 0, @sizeOf(Uniforms), &p.uniforms);
    gl.glBindBufferBase(gl.GL_UNIFORM_BUFFER, 1, p.ubo);
    gl.glActiveTexture(gl.GL_TEXTURE2);
    gl.glBindTexture(gl.GL_TEXTURE_2D, if (p.uses_prev) p.prev.tex else p.black);
    gl.glActiveTexture(gl.GL_TEXTURE3);
    gl.glBindTexture(gl.GL_TEXTURE_2D, if (age != 0) age else p.black);
    var src = p.scene.tex;
    for (p.custom[0..p.custom_len], 0..) |c, i| {
        const last = i + 1 == p.custom_len;
        if (last) {
            gl.glBindFramebuffer(gl.GL_FRAMEBUFFER, if (p.uses_prev) p.out.fbo else @intCast(screen_fbo));
        } else {
            const dst = &p.ping[i % 2];
            dst.ensure(t.w_px, t.h_px);
            gl.glBindFramebuffer(gl.GL_FRAMEBUFFER, dst.fbo);
        }
        drawFullscreen(c.pass, src, last and to_screen and !p.uses_prev);
        if (!last) src = p.ping[i % 2].tex;
    }
    if (p.uses_prev) {
        // The output is kept offscreen, top-down, for next frame's
        // iPrevFrame and copied to the screen from there; a blit out of the
        // render thread's dmabuf reads nothing on some drivers.
        gl.glBindFramebuffer(gl.GL_FRAMEBUFFER, @intCast(screen_fbo));
        gl.glUseProgram(p.copy.prog);
        gl.glUniform1f(p.copy.u_scale, 1);
        drawFullscreen(p.copy, p.out.tex, to_screen);
        std.mem.swap(Rt, &p.prev, &p.out);
    }
    return f;
}

/// This surface's iCellAge texture, uploaded when the core stamped it since
/// the last frame; 0 when it cannot be bound. Its size is the surface's
/// root grid: the main window's screen-space cells (texture 1), or the
/// external window's own grid.
fn syncCellAge(app: *App, p: *PostFx, surface_id: i64) u32 {
    app.mu.lockUncancelable(clock.io());
    const layers = app.surface.committedSurfaceLayers(surface_id);
    const root: ?core.Layer = for (layers) |l| {
        if (l.grid_id == surface_id) break l;
    } else null;
    app.mu.unlock(clock.io());
    const r = root orelse return 0;
    const fresh = p.age_tex == 0 or p.age_cols != r.cols or p.age_rows != r.rows;
    var values: []const f32 = &.{};
    switch (app.cell_age.sync(surface_id, r.cols, r.rows, fresh, &p.age_cache, &values)) {
        .unavailable => return 0,
        .clean => {},
        .dirty => {
            defer app.cell_age.endUpload();
            if (p.age_tex == 0) gl.glGenTextures(1, &p.age_tex);
            gl.glBindTexture(gl.GL_TEXTURE_2D, p.age_tex);
            gl.glTexParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_MIN_FILTER, gl.GL_NEAREST);
            gl.glTexParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_MAG_FILTER, gl.GL_NEAREST);
            gl.glTexImage2D(gl.GL_TEXTURE_2D, 0, gl.GL_R32F, @intCast(r.cols), @intCast(r.rows), 0, gl.GL_RED, gl.GL_FLOAT, values.ptr);
            p.age_cols = r.cols;
            p.age_rows = r.rows;
        },
    }
    return p.age_tex;
}

/// Frees the context's objects; the next realize builds them again.
pub fn unrealize(p: *PostFx) void {
    p.scene.deinit();
    p.extract.deinit();
    for (&p.mips) |*m| m.deinit();
    for (&p.ping) |*r| r.deinit();
    p.prev.deinit();
    p.out.deinit();
    if (p.age_tex != 0) gl.glDeleteTextures(1, &p.age_tex);
    for (p.custom[0..p.custom_len]) |c| gl.glDeleteProgram(c.pass.prog);
    for ([_]Pass{ p.copy, p.down, p.up }) |pass| if (pass.prog != 0) gl.glDeleteProgram(pass.prog);
    if (p.ubo != 0) gl.glDeleteBuffers(1, &p.ubo);
    if (p.black != 0) gl.glDeleteTextures(1, &p.black);
    if (p.vao != 0) gl.glDeleteVertexArrays(1, &p.vao);
    p.* = .{};
}
