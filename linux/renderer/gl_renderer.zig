//! OpenGL 3.3 painter for the committed surface snapshot. Runs on the GTK
//! main thread with the GtkGLArea context current and its FBO bound.

const std = @import("std");
const core = @import("zonvie_core");
const clock = core.clock;
const gl = @import("../gl.zig");
const App = @import("../app.zig").App;
const transform = @import("../transform.zig");
const applog = @import("../app_log.zig");

const shader_src = @embedFile("../shaders/main.glsl");
const initial_vbo_bytes: usize = 64 * 1024;

fn compile(kind: gl.GLenum, prefix: [:0]const u8) ?gl.GLuint {
    const sh = gl.glCreateShader(kind);
    const srcs = [_][*c]const u8{ prefix.ptr, shader_src.ptr };
    const lens = [_]gl.GLint{ @intCast(prefix.len), @intCast(shader_src.len) };
    gl.glShaderSource(sh, 2, &srcs, &lens);
    gl.glCompileShader(sh);
    var ok: gl.GLint = 0;
    gl.glGetShaderiv(sh, gl.GL_COMPILE_STATUS, &ok);
    if (ok == 0) {
        var buf: [2048]u8 = undefined;
        var n: gl.GLsizei = 0;
        gl.glGetShaderInfoLog(sh, buf.len, &n, &buf);
        applog.appLog("[gl] shader compile failed ({s}): {s}\n", .{ prefix, buf[0..@intCast(n)] });
        gl.glDeleteShader(sh);
        return null;
    }
    return sh;
}

pub fn realize(app: *App) bool {
    const vs = compile(gl.GL_VERTEX_SHADER, "#version 330 core\n#define VERTEX\n") orelse return false;
    defer gl.glDeleteShader(vs);
    const fs = compile(gl.GL_FRAGMENT_SHADER, "#version 330 core\n#define FRAGMENT\n") orelse return false;
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
        applog.appLog("[gl] program link failed: {s}\n", .{buf[0..@intCast(n)]});
        gl.glDeleteProgram(prog);
        return false;
    }
    app.gl_program = prog;
    app.gl_u_scale = gl.glGetUniformLocation(prog, "u_scale");
    app.gl_u_offset = gl.glGetUniformLocation(prog, "u_offset");
    gl.glUseProgram(prog);
    gl.glUniform1i(gl.glGetUniformLocation(prog, "u_atlas"), 0);

    gl.glGenVertexArrays(1, &app.gl_vao);
    gl.glBindVertexArray(app.gl_vao);
    gl.glGenBuffers(1, &app.gl_vbo);
    gl.glBindBuffer(gl.GL_ARRAY_BUFFER, app.gl_vbo);
    gl.glBufferData(gl.GL_ARRAY_BUFFER, @intCast(initial_vbo_bytes), null, gl.GL_DYNAMIC_DRAW);
    app.gl_vbo_cap_bytes = initial_vbo_bytes;
    const stride: gl.GLsizei = @sizeOf(core.Vertex);
    gl.glEnableVertexAttribArray(0);
    gl.glVertexAttribPointer(0, 2, gl.GL_FLOAT, gl.GL_FALSE, stride, @ptrFromInt(@offsetOf(core.Vertex, "position")));
    gl.glEnableVertexAttribArray(1);
    gl.glVertexAttribPointer(1, 2, gl.GL_FLOAT, gl.GL_FALSE, stride, @ptrFromInt(@offsetOf(core.Vertex, "texCoord")));
    gl.glEnableVertexAttribArray(2);
    gl.glVertexAttribPointer(2, 4, gl.GL_FLOAT, gl.GL_FALSE, stride, @ptrFromInt(@offsetOf(core.Vertex, "color")));
    gl.glEnableVertexAttribArray(3);
    gl.glVertexAttribIPointer(3, 1, gl.GL_UNSIGNED_INT, stride, @ptrFromInt(@offsetOf(core.Vertex, "deco_flags")));

    gl.glGenTextures(1, &app.gl_atlas_tex);
    gl.glBindTexture(gl.GL_TEXTURE_2D, app.gl_atlas_tex);
    // Point sampling and clamp, as the D3D11 atlas sampler.
    gl.glTexParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_MIN_FILTER, gl.GL_NEAREST);
    gl.glTexParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_MAG_FILTER, gl.GL_NEAREST);
    gl.glTexParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_WRAP_S, gl.GL_CLAMP_TO_EDGE);
    gl.glTexParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_WRAP_T, gl.GL_CLAMP_TO_EDGE);
    // A fresh texture has no storage; the first render allocates it.
    app.gl_atlas_w = 0;
    app.gl_atlas_h = 0;
    return true;
}

pub fn unrealize(app: *App) void {
    if (app.gl_atlas_tex != 0) gl.glDeleteTextures(1, &app.gl_atlas_tex);
    if (app.gl_vbo != 0) gl.glDeleteBuffers(1, &app.gl_vbo);
    if (app.gl_vao != 0) gl.glDeleteVertexArrays(1, &app.gl_vao);
    if (app.gl_program != 0) gl.glDeleteProgram(app.gl_program);
    app.gl_atlas_tex = 0;
    app.gl_vbo = 0;
    app.gl_vao = 0;
    app.gl_program = 0;
    app.gl_vbo_cap_bytes = 0;
    app.gl_atlas_w = 0;
    app.gl_atlas_h = 0;
}

/// Caller holds App.mu.
fn drainAtlas(app: *App) void {
    const ops = &app.atlas_pending;
    gl.glActiveTexture(gl.GL_TEXTURE0);
    gl.glBindTexture(gl.GL_TEXTURE_2D, app.gl_atlas_tex);
    gl.glPixelStorei(gl.GL_UNPACK_ALIGNMENT, 1);
    // A context realized after the atlas was created has no storage yet.
    if (ops.recreate or (ops.w != 0 and (app.gl_atlas_w != ops.w or app.gl_atlas_h != ops.h))) {
        if (ops.w != 0 and ops.h != 0) {
            // Zeroed contents; runs only on atlas create, never per frame.
            const bytes = @as(usize, ops.w) * ops.h * 4;
            const zeros = app.alloc.alloc(u8, bytes) catch null;
            defer if (zeros) |z| app.alloc.free(z);
            if (zeros) |z| @memset(z, 0);
            gl.glTexImage2D(gl.GL_TEXTURE_2D, 0, gl.GL_RGBA8, @intCast(ops.w), @intCast(ops.h), 0, gl.GL_RGBA, gl.GL_UNSIGNED_BYTE, if (zeros) |z| z.ptr else null);
            app.gl_atlas_w = ops.w;
            app.gl_atlas_h = ops.h;
        }
        ops.recreate = false;
    }
    if (app.gl_atlas_w != 0) {
        for (ops.uploads.items) |u| {
            gl.glTexSubImage2D(gl.GL_TEXTURE_2D, 0, @intCast(u.x), @intCast(u.y), @intCast(u.w), @intCast(u.h), gl.GL_RGBA, gl.GL_UNSIGNED_BYTE, ops.pixels.items[u.offset..].ptr);
        }
        ops.clearQueued();
    }
}

/// Uploads `verts` into the persistent VBO and draws them as triangles.
fn drawVerts(app: *App, verts: []const core.Vertex, layer: core.Layer) void {
    if (verts.len == 0) return;
    const bytes = verts.len * @sizeOf(core.Vertex);
    if (bytes > app.gl_vbo_cap_bytes) {
        var cap = @max(app.gl_vbo_cap_bytes, initial_vbo_bytes);
        while (cap < bytes) cap *= 2;
        gl.glBufferData(gl.GL_ARRAY_BUFFER, @intCast(cap), null, gl.GL_DYNAMIC_DRAW);
        app.gl_vbo_cap_bytes = cap;
    }
    gl.glBufferSubData(gl.GL_ARRAY_BUFFER, 0, @intCast(bytes), verts.ptr);
    const t = transform.layerXform(layer, app.cell_w_px, app.cell_h_px, app.drawable_w_px, app.drawable_h_px);
    gl.glUniform2f(app.gl_u_scale, t.scale[0], t.scale[1]);
    gl.glUniform2f(app.gl_u_offset, t.offset[0], t.offset[1]);
    gl.glDrawArrays(gl.GL_TRIANGLES, 0, @intCast(verts.len));
}

pub fn render(app: *App) void {
    if (app.gl_program == 0) return;
    const t0 = clock.nowNs();
    app.mu.lockUncancelable(clock.io());
    defer app.mu.unlock(clock.io());

    drainAtlas(app);

    const bg = app.default_bg;
    gl.glViewport(0, 0, @intCast(app.drawable_w_px), @intCast(app.drawable_h_px));
    gl.glClearColor(
        @as(f32, @floatFromInt((bg >> 16) & 0xff)) / 255.0,
        @as(f32, @floatFromInt((bg >> 8) & 0xff)) / 255.0,
        @as(f32, @floatFromInt(bg & 0xff)) / 255.0,
        1.0,
    );
    gl.glClear(gl.GL_COLOR_BUFFER_BIT);
    if (app.gl_atlas_w == 0 or app.drawable_w_px == 0 or app.drawable_h_px == 0) return;

    gl.glUseProgram(app.gl_program);
    gl.glBindVertexArray(app.gl_vao);
    gl.glBindBuffer(gl.GL_ARRAY_BUFFER, app.gl_vbo);
    gl.glEnable(gl.GL_BLEND);
    gl.glBlendFunc(gl.GL_ONE, gl.GL_ONE_MINUS_SRC_ALPHA);

    var verts_total: usize = 0;
    const layers = app.surface.committedLayers();
    // The core sends layers back-to-front; draw in order (windows/app.zig:4432).
    for (layers) |layer| {
        const grid = app.surface.committedGrid(layer.grid_id) orelse continue;
        app.gl_scratch.clearRetainingCapacity();
        for (grid.committedRows()) |row| {
            app.gl_scratch.appendSlice(app.alloc, row.verts.items) catch break;
        }
        verts_total += app.gl_scratch.items.len;
        drawVerts(app, app.gl_scratch.items, layer);
    }
    const cur = app.surface.committedCursor();
    if (cur.verts.len != 0) {
        for (layers) |layer| {
            if (layer.grid_id != cur.grid_id) continue;
            verts_total += cur.verts.len;
            drawVerts(app, cur.verts, layer);
            break;
        }
    }

    if (applog.isEnabled()) {
        const us = @divTrunc(clock.nowNs() - t0, 1000);
        applog.appLog("[perf] linux_render us={d} layers={d} verts={d}\n", .{ us, layers.len, verts_total });
    }
}
