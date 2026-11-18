//! The main window's post-processing: the neon glow bloom
//! (vim.g.zonvie_glow) and the custom shader chain ([shaders] in
//! config.toml). When either is active the grid is drawn into an offscreen
//! texture, stored top-down as the Shadertoy preamble's vUV expects; the
//! bloom is added onto it, then each custom shader reads the previous
//! output and the last one writes the window's framebuffer. Same passes as
//! the D3D11 renderer (windows/shaders/main.hlsl, PSKawase*); the chain's
//! geometry is the core's (glow_chain.zig). Each PostFx belongs to one GL
//! context and is used only with it current, on the main thread.

const std = @import("std");
const core = @import("zonvie_core");
const clock = core.clock;
const gl = @import("../gl.zig");
const App = @import("../app.zig").App;
const gl_renderer = @import("gl_renderer.zig");
const applog = @import("../app_log.zig");
const shader_inputs = @import("../shader_inputs.zig");

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
    /// Reads iCellText (frontend_rules.shaderUsesCellText).
    uses_cell_text: bool = false,
    /// Declares `@zonvie-owns-cursor` (frontend_rules.shaderOwnsCursor).
    owns_cursor: bool = false,
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
    /// This surface's iCellText: the store's cols x rows R32UI codepoints,
    /// when a shader reads it; `zero_text` (1x1 R32UI) until a row arrives.
    text_tex: u32 = 0,
    text_cols: u32 = 0,
    text_rows: u32 = 0,
    text_cache: core.cell_text_store.SyncCache = .{},
    zero_text: u32 = 0,
    uses_cell_text: bool = false,
    /// The store's mirror, copied under the App.mu hold that drew the scene
    /// and uploaded after it; grows only with the cell grid.
    text_scratch: std.ArrayListUnmanaged(u32) = .empty,
    /// The scratch holds a copy not yet uploaded.
    text_staged: bool = false,
    /// A copy could not be taken: the next frame forces a full sync.
    text_lost: bool = false,
    /// iRowOffset, sized like iCellAge, when a shader reads edit inputs.
    row_offsets: shader_inputs.RowOffsets = .{},
    row_tex: u32 = 0,
    row_cols: u32 = 0,
    row_rows: u32 = 0,
    /// Some loaded shader draws the cursor itself.
    owns_cursor: bool = false,
    /// iDate's date fields and the wall-clock second they were taken at:
    /// localtime runs at most once a second.
    date_second: i64 = -1,
    date_ymds: [4]f32 = .{ 0, 0, 0, 0 },
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
            if (c.uses_cell_text) p.uses_cell_text = true;
            if (c.owns_cursor) p.owns_cursor = true;
        }
    }
    if (p.uses_cell_text) {
        // An unsigned sampler must not read the RGBA8 `black`.
        gl.glGenTextures(1, &p.zero_text);
        gl.glBindTexture(gl.GL_TEXTURE_2D, p.zero_text);
        const zero_u = [_]u32{0};
        gl.glTexImage2D(gl.GL_TEXTURE_2D, 0, gl.GL_R32UI, 1, 1, 0, gl.GL_RED_INTEGER, gl.GL_UNSIGNED_INT, &zero_u);
        nearest();
        app.shader_wants_cell_text.store(true, .release);
    }
    // The core records no stamps until a shader wants them. Every window
    // compiles the same config, so the answer is the same for all.
    if (p.uses_edit or p.uses_cell_text) {
        var flags: i32 = @intCast(core.SHADER_INPUT_CELL_AGE);
        if (p.uses_cell_text) flags |= @intCast(core.SHADER_INPUT_CELL_TEXT);
        if (app.corep) |cp| core.zonvie_core_set_shader_inputs_enabled(cp, flags);
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
    const u_text = gl.glGetUniformLocation(pass.prog, "iCellText");
    const u_row = gl.glGetUniformLocation(pass.prog, "iRowOffset");
    if (u_prev >= 0) gl.glUniform1i(u_prev, 2);
    if (u_age >= 0) gl.glUniform1i(u_age, 3);
    if (u_text >= 0) gl.glUniform1i(u_text, 4);
    if (u_row >= 0) gl.glUniform1i(u_row, 5);
    applog.appLog("[postfx] loaded shader {s}\n", .{path});
    return .{
        .pass = pass,
        .u_prev = u_prev,
        .u_age = u_age,
        .needs_animation = core.zonvie_core_shader_needs_animation(src.ptr, src.len),
        .uses_prev = core.frontend_rules.shaderUsesPrevFrame(src),
        .uses_edit = core.frontend_rules.shaderUsesEditInputs(src),
        .uses_cell_text = core.frontend_rules.shaderUsesCellText(src),
        .owns_cursor = core.frontend_rules.shaderOwnsCursor(src),
    };
}

/// True when a `@zonvie-owns-cursor` shader draws the cursor this frame, so
/// the native cursor must not be drawn. Until it has been given a cursor
/// rect the native pass stays in charge (windows d3d11_renderer
/// shaderDrawsCursorNow).
fn shaderDrawsCursor(p: *const PostFx) bool {
    const r = p.uniforms.iCurrentCursor;
    return p.owns_cursor and p.custom_len != 0 and r[2] > 0 and r[3] > 0;
}

const Tm = extern struct {
    sec: c_int,
    min: c_int,
    hour: c_int,
    mday: c_int,
    mon: c_int,
    year: c_int,
    wday: c_int,
    yday: c_int,
    isdst: c_int,
    gmtoff: c_long,
    zone: ?[*:0]const u8,
};
extern "c" fn localtime_r(t: *const c_long, out: *Tm) ?*Tm;

/// Shadertoy's iDate: (year, month 1..12, day, seconds since local
/// midnight), as Windows and macOS fill it; the sub-second part runs every
/// frame, the date fields are taken once per wall-clock second.
fn fillDate(p: *PostFx, u: *Uniforms) void {
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(.REALTIME, &ts) != 0) return;
    const sec: i64 = @intCast(ts.sec);
    if (sec != p.date_second) {
        const t: c_long = @intCast(sec);
        var tm: Tm = undefined;
        if (localtime_r(&t, &tm) == null) return;
        p.date_second = sec;
        p.date_ymds = .{
            @floatFromInt(tm.year + 1900),
            @floatFromInt(tm.mon + 1),
            @floatFromInt(tm.mday),
            @floatFromInt(tm.hour * 3600 + tm.min * 60 + tm.sec),
        };
    }
    u.iDate = p.date_ymds;
    u.iDate[3] += @as(f32, @floatFromInt(ts.nsec)) / std.time.ns_per_s;
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
/// Caller holds App.mu.
/// `shown`: the cursor is lit, not in the off phase of a `guicursor` blink.
const CursorState = struct { rect: [4]f32, color: [4]f32, cell: [2]f32, shown: bool };
fn cursorState(app: *App, surface_id: i64) ?CursorState {
    const cur = app.surface.committedCursor();
    if (cur.verts.len == 0) return null;
    const layer = for (app.surface.committedSurfaceLayers(surface_id)) |l| {
        if (l.grid_id == cur.grid_id) break l;
    } else return null;
    const b = core.cursor_rect.bounds(core.Vertex, cur.verts, @floatFromInt(layer.x_px), @floatFromInt(layer.y_px)) orelse return null;
    // The cursor's cell is its grid's: a per-grid font's when it has one.
    const f = app.surface.gridFont(cur.grid_id);
    const cell: [2]f32 = .{
        @floatFromInt(if (f) |g| g.cell_w_px else app.cell_w_px),
        @floatFromInt(if (f) |g| g.cell_h_px else app.cell_h_px),
    };
    return .{ .rect = .{ b.left, b.bottom, b.width(), b.height() }, .color = cur.verts[0].color, .cell = cell, .shown = app.cursor_blink.visible };
}

/// What a shaded frame reads of App state, taken under the App.mu hold that
/// drew the scene, so a frame never pairs one flush's rows with another's
/// inputs. iLayers is written into `uniforms` and iRowOffset into
/// `row_offsets` in that hold too.
const Snapshot = struct {
    cursor: ?CursorState = null,
    lattice: [2]u32 = .{ 0, 0 },
    age_root: ?core.Layer = null,
};

/// Caller holds App.mu.
fn snapshotLocked(app: *App, p: *PostFx, surface_id: i64) Snapshot {
    var s: Snapshot = .{ .cursor = cursorState(app, surface_id) };
    // iCellSize is the surface lattice's cell: an external window whose
    // root grid has its own font is laid out in that font.
    s.lattice = shader_inputs.latticeCell(app.surface.gridFont(surface_id), app.cell_w_px, app.cell_h_px);
    const layers = app.surface.committedSurfaceLayers(surface_id);
    if (p.uses_edit) {
        shader_inputs.fillLayers(&p.uniforms, layers, &app.surface, app.cell_w_px, app.cell_h_px);
        p.row_offsets.fill(app.alloc, layers, &app.surface, s.lattice);
        s.age_root = for (layers) |l| {
            if (l.grid_id == surface_id) break l;
        } else null;
    }
    if (p.uses_cell_text) stageCellText(app, p, surface_id);
    return s;
}

fn fillUniforms(app: *App, t: *const gl_renderer.Target, p: *PostFx, s: *const Snapshot) void {
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
    fillDate(p, u);
    // Wayland gives a client no window position, its own or another's:
    // every window is its own origin.
    u.iWindowOffset = .{ 0, 0 };
    u.iWindowSize = .{ w, h };
    const cursor = s.cursor;
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
    const lattice = s.lattice;
    // The rest by the core's rule, cursor styles included. The root grid
    // starts at the surface's corner.
    const cell: [2]f32 = if (cursor) |c| c.cell else .{ @floatFromInt(app.cell_w_px), @floatFromInt(app.cell_h_px) };
    core.fillEditUniforms(
        u,
        @floatFromInt(lattice[0]),
        @floatFromInt(lattice[1]),
        cell,
        .{ 0, 0 },
        p.age_cache.last_edit,
        // Blinked off as macOS and Windows pass it: a shader that draws the
        // cursor itself (@zonvie-owns-cursor) blinks it from here.
        if (cursor) |c| c.shown else false,
        p.uses_edit,
    );
}

/// The main surface (with its overlays), or an external window's.
fn scene(app: *App, t: *gl_renderer.Target, surface_id: i64) gl_renderer.Frame {
    return if (surface_id == 1) gl_renderer.renderMain(app, t) else gl_renderer.renderExternalScene(app, t, surface_id);
}

/// A surface through the bloom and the shader chain, ending in the
/// framebuffer bound on entry: bottom-up, or top-down as `t.flip_y` says.
pub fn renderFrame(app: *App, t: *gl_renderer.Target, p: *PostFx, surface_id: i64) gl_renderer.Frame {
    var screen_fbo: gl.GLint = 0;
    gl.glGetIntegerv(gl.GL_FRAMEBUFFER_BINDING, &screen_fbo);
    if (!setup(app, p) or t.w_px == 0 or t.h_px == 0) return scene(app, t, surface_id);
    // The passes below draw into framebuffers of the view's own size; only
    // the last one lands in the window, at the view's place in it
    // (`in_window`).
    const in_window = t.*;
    t.ox_px = 0;
    t.oy_px = 0;
    t.fb_w_px = 0;
    t.fb_h_px = 0;
    defer {
        t.ox_px = in_window.ox_px;
        t.oy_px = in_window.oy_px;
        t.fb_w_px = in_window.fb_w_px;
        t.fb_h_px = in_window.fb_h_px;
    }

    // Offscreen textures are top-down already; only a bottom-up screen
    // needs the final pass to flip.
    const screen_top_down = t.flip_y;
    const to_screen = !screen_top_down;
    p.scene.ensure(t.w_px, t.h_px);
    gl.glBindFramebuffer(gl.GL_FRAMEBUFFER, p.scene.fbo);
    t.flip_y = true;
    t.skip_cursor = shaderDrawsCursor(p);
    // One App.mu hold draws the scene's rows and snapshots the shader
    // inputs; the GL uploads run from the snapshot after it.
    const t0 = clock.nowNs();
    app.mu.lockUncancelable(clock.io());
    const f = if (surface_id == 1) gl_renderer.renderMainLocked(app, t, t0) else gl_renderer.renderExternalSceneLocked(app, t, surface_id, t0);
    const snap: Snapshot = if (p.custom_len != 0) snapshotLocked(app, p, surface_id) else .{};
    app.mu.unlock(clock.io());
    t.skip_cursor = false;
    if (app.corep) |cp| {
        if (core.zonvie_core_get_glow_enabled(cp)) bloom(app, t, p, cp, surface_id);
    }
    t.flip_y = screen_top_down;

    gl.glBindVertexArray(p.vao);
    gl.glDisable(gl.GL_BLEND);
    gl.glViewport(0, 0, @intCast(t.w_px), @intCast(t.h_px));
    if (p.custom_len == 0) {
        gl.glBindFramebuffer(gl.GL_FRAMEBUFFER, @intCast(screen_fbo));
        gl_renderer.viewport(&in_window);
        gl.glUseProgram(p.copy.prog);
        gl.glUniform1f(p.copy.u_scale, 1);
        drawFullscreen(p.copy, p.scene.tex, to_screen);
        return f;
    }

    if (p.uses_prev) {
        p.prev.ensure(t.w_px, t.h_px);
        p.out.ensure(t.w_px, t.h_px);
    }
    const age = if (p.uses_edit) syncCellAge(app, p, surface_id, snap.age_root) else 0;
    const rows = if (p.uses_edit) uploadRowOffsets(p) else 0;
    const text = if (p.uses_cell_text) uploadCellText(p) else 0;
    fillUniforms(app, t, p, &snap);
    gl.glBindBuffer(gl.GL_UNIFORM_BUFFER, p.ubo);
    gl.glBufferSubData(gl.GL_UNIFORM_BUFFER, 0, @sizeOf(Uniforms), &p.uniforms);
    gl.glBindBufferBase(gl.GL_UNIFORM_BUFFER, 1, p.ubo);
    gl.glActiveTexture(gl.GL_TEXTURE2);
    gl.glBindTexture(gl.GL_TEXTURE_2D, if (p.uses_prev) p.prev.tex else p.black);
    gl.glActiveTexture(gl.GL_TEXTURE3);
    gl.glBindTexture(gl.GL_TEXTURE_2D, if (age != 0) age else p.black);
    if (p.uses_cell_text) {
        gl.glActiveTexture(gl.GL_TEXTURE4);
        gl.glBindTexture(gl.GL_TEXTURE_2D, if (text != 0) text else p.zero_text);
    }
    if (p.uses_edit) {
        gl.glActiveTexture(gl.GL_TEXTURE5);
        gl.glBindTexture(gl.GL_TEXTURE_2D, if (rows != 0) rows else p.black);
    }
    var src = p.scene.tex;
    for (p.custom[0..p.custom_len], 0..) |c, i| {
        const last = i + 1 == p.custom_len;
        if (last) {
            gl.glBindFramebuffer(gl.GL_FRAMEBUFFER, if (p.uses_prev) p.out.fbo else @intCast(screen_fbo));
            if (!p.uses_prev) gl_renderer.viewport(&in_window);
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
        // iPrevFrame and copied to the screen from there.
        gl.glBindFramebuffer(gl.GL_FRAMEBUFFER, @intCast(screen_fbo));
        gl_renderer.viewport(&in_window);
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
fn syncCellAge(app: *App, p: *PostFx, surface_id: i64, root: ?core.Layer) u32 {
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

fn nearest() void {
    gl.glTexParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_MIN_FILTER, gl.GL_NEAREST);
    gl.glTexParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_MAG_FILTER, gl.GL_NEAREST);
}

/// Copy this surface's iCellText mirror into `text_scratch` when its store
/// changed since the last frame. Caller holds App.mu, the lock the flush
/// commits the text under, and the same hold drew the scene's rows: the copy
/// pairs with that commit. The store's leaf lock is held only for the copy.
fn stageCellText(app: *App, p: *PostFx, surface_id: i64) void {
    var values: []const u32 = &.{};
    const force = p.text_tex == 0 or p.text_lost;
    switch (app.cell_text.sync(shader_inputs.cellTextGrid(surface_id), force, &p.text_cache, &values)) {
        .unavailable, .clean => return,
        .dirty => {},
    }
    defer app.cell_text.endUpload();
    // Grows only when the cell grid does; a frame at a known size allocates nothing.
    p.text_scratch.ensureTotalCapacity(app.alloc, values.len) catch {
        p.text_lost = true;
        return;
    };
    p.text_scratch.clearRetainingCapacity();
    p.text_scratch.appendSliceAssumeCapacity(values);
    p.text_staged = true;
    p.text_lost = false;
}

/// This surface's iCellText texture, uploaded from the staged copy; 0 until
/// a row has arrived. Created only when the store's cell grid changes.
fn uploadCellText(p: *PostFx) u32 {
    if (!p.text_staged) return p.text_tex;
    p.text_staged = false;
    const values = p.text_scratch.items;
    const cols = p.text_cache.cols;
    const rows = p.text_cache.rows;
    if (p.text_tex == 0 or p.text_cols != cols or p.text_rows != rows) {
        if (p.text_tex == 0) gl.glGenTextures(1, &p.text_tex);
        gl.glBindTexture(gl.GL_TEXTURE_2D, p.text_tex);
        nearest();
        gl.glTexImage2D(gl.GL_TEXTURE_2D, 0, gl.GL_R32UI, @intCast(cols), @intCast(rows), 0, gl.GL_RED_INTEGER, gl.GL_UNSIGNED_INT, values.ptr);
        p.text_cols = cols;
        p.text_rows = rows;
    } else {
        gl.glBindTexture(gl.GL_TEXTURE_2D, p.text_tex);
        gl.glTexSubImage2D(gl.GL_TEXTURE_2D, 0, 0, 0, @intCast(cols), @intCast(rows), gl.GL_RED_INTEGER, gl.GL_UNSIGNED_INT, values.ptr);
    }
    return p.text_tex;
}

/// This surface's iRowOffset texture from the offsets snapshotted with the
/// scene (Snapshot); uploaded only when an offset changed. 0 with no root.
fn uploadRowOffsets(p: *PostFx) u32 {
    const ro = &p.row_offsets;
    if (ro.cols == 0 or ro.rows == 0) return 0;
    if (p.row_tex == 0 or p.row_cols != ro.cols or p.row_rows != ro.rows) {
        if (p.row_tex == 0) gl.glGenTextures(1, &p.row_tex);
        gl.glBindTexture(gl.GL_TEXTURE_2D, p.row_tex);
        nearest();
        gl.glTexImage2D(gl.GL_TEXTURE_2D, 0, gl.GL_R32F, @intCast(ro.cols), @intCast(ro.rows), 0, gl.GL_RED, gl.GL_FLOAT, ro.values.items.ptr);
        p.row_cols = ro.cols;
        p.row_rows = ro.rows;
        ro.dirty = false;
    } else if (ro.dirty) {
        gl.glBindTexture(gl.GL_TEXTURE_2D, p.row_tex);
        gl.glTexSubImage2D(gl.GL_TEXTURE_2D, 0, 0, 0, @intCast(ro.cols), @intCast(ro.rows), gl.GL_RED, gl.GL_FLOAT, ro.values.items.ptr);
        ro.dirty = false;
    }
    return p.row_tex;
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
    if (p.text_tex != 0) gl.glDeleteTextures(1, &p.text_tex);
    if (p.zero_text != 0) gl.glDeleteTextures(1, &p.zero_text);
    if (p.row_tex != 0) gl.glDeleteTextures(1, &p.row_tex);
    for (p.custom[0..p.custom_len]) |c| gl.glDeleteProgram(c.pass.prog);
    for ([_]Pass{ p.copy, p.down, p.up }) |pass| if (pass.prog != 0) gl.glDeleteProgram(pass.prog);
    if (p.ubo != 0) gl.glDeleteBuffers(1, &p.ubo);
    if (p.black != 0) gl.glDeleteTextures(1, &p.black);
    if (p.vao != 0) gl.glDeleteVertexArrays(1, &p.vao);
    // CPU memory, not the context's: freed by the owner (deinit).
    const row_offsets = p.row_offsets;
    var text_scratch = p.text_scratch;
    text_scratch.clearRetainingCapacity();
    p.* = .{ .row_offsets = row_offsets, .text_scratch = text_scratch };
}

/// Frees what outlives the context: the row offsets' and cell text's buffers.
pub fn deinit(p: *PostFx, alloc: std.mem.Allocator) void {
    p.row_offsets.deinit(alloc);
    p.text_scratch.deinit(alloc);
}
