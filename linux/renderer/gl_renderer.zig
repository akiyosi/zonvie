//! OpenGL 3.3 painter for the committed surface snapshot. Runs on the GTK
//! main thread with a GtkGLArea's context current and its FBO bound. Each
//! GLArea (the main window, every external window) owns a Target: GTK gives
//! every area a context of its own, so nothing GL is shared between them.

const std = @import("std");
const core = @import("zonvie_core");
const clock = core.clock;
const gl = @import("../gl.zig");
const App = @import("../app.zig").App;
const transform = @import("../transform.zig");
const applog = @import("../app_log.zig");
const gtk = @import("../gtk_bindings.zig");
const surface_store = @import("../surface_store.zig");
const GridRows = surface_store.GridRows;
const Row = surface_store.Row;
const overlay_layout = @import("../overlay_layout.zig");
const rules = core.frontend_rules;
const postfx = @import("postfx.zig");
const scrollbar = @import("../scrollbar.zig");
const layer_geom = @import("../layer_geom.zig");

const shader_src = @embedFile("../shaders/main.glsl");
const initial_vbo_bytes: usize = 64 * 1024;

/// One GLArea's GL objects, valid between realize and unrealize, and the
/// size it draws at (device px), set by its resize handler.
pub const Target = struct {
    program: u32 = 0,
    vao: u32 = 0,
    vbo: u32 = 0,
    vbo_cap_bytes: usize = 0,
    atlas_tex: u32 = 0,
    /// Size the atlas texture was allocated at; 0 until it holds the atlas.
    atlas_w: u32 = 0,
    atlas_h: u32 = 0,
    /// AtlasOps.gen this texture matches; external windows sync by it.
    atlas_gen: u64 = 0,
    u_scale: i32 = -1,
    u_offset: i32 = -1,
    u_scroll_offset: i32 = -1,
    u_layer_origin_x: i32 = -1,
    u_mode: i32 = -1,
    u_clear_bg: i32 = -1,
    w_px: u32 = 0,
    h_px: u32 = 0,
    /// Row 0 of the framebuffer is the image's top: an FBO over a dmabuf
    /// that GTK reads top-down, unlike a GLArea's.
    flip_y: bool = false,
    /// Framebuffer px per surface px: 0.5 while the bloom extracts into its
    /// half-resolution texture, so scissors land on the same content.
    px_scale: f32 = 1,
    /// A `@zonvie-owns-cursor` shader draws the cursor over this frame
    /// (postfx.renderFrame): the native cursor pass is skipped.
    skip_cursor: bool = false,
    /// One layer's rows concatenated for a single upload; capacity reused
    /// across frames. Per target, so the render thread and the GTK thread
    /// never share one.
    scratch: std.ArrayListUnmanaged(core.Vertex) = .empty,

    pub fn deinit(self: *Target, alloc: std.mem.Allocator) void {
        self.scratch.deinit(alloc);
    }
};

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

pub fn realize(t: *Target) bool {
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
    t.program = prog;
    t.u_scale = gl.glGetUniformLocation(prog, "u_scale");
    t.u_offset = gl.glGetUniformLocation(prog, "u_offset");
    t.u_scroll_offset = gl.glGetUniformLocation(prog, "u_scroll_offset_px");
    t.u_layer_origin_x = gl.glGetUniformLocation(prog, "u_layer_origin_x_px");
    t.u_mode = gl.glGetUniformLocation(prog, "u_mode");
    t.u_clear_bg = gl.glGetUniformLocation(prog, "u_clear_bg");
    gl.glUseProgram(prog);
    gl.glUniform1i(gl.glGetUniformLocation(prog, "u_atlas"), 0);
    gl.glUniform4f(t.u_clear_bg, 0, 0, 0, -1);

    gl.glGenVertexArrays(1, &t.vao);
    gl.glBindVertexArray(t.vao);
    gl.glGenBuffers(1, &t.vbo);
    gl.glBindBuffer(gl.GL_ARRAY_BUFFER, t.vbo);
    gl.glBufferData(gl.GL_ARRAY_BUFFER, @intCast(initial_vbo_bytes), null, gl.GL_DYNAMIC_DRAW);
    t.vbo_cap_bytes = initial_vbo_bytes;
    const stride: gl.GLsizei = @sizeOf(core.Vertex);
    gl.glEnableVertexAttribArray(0);
    gl.glVertexAttribPointer(0, 2, gl.GL_FLOAT, gl.GL_FALSE, stride, @ptrFromInt(@offsetOf(core.Vertex, "position")));
    gl.glEnableVertexAttribArray(1);
    gl.glVertexAttribPointer(1, 2, gl.GL_FLOAT, gl.GL_FALSE, stride, @ptrFromInt(@offsetOf(core.Vertex, "texCoord")));
    gl.glEnableVertexAttribArray(2);
    gl.glVertexAttribPointer(2, 4, gl.GL_FLOAT, gl.GL_FALSE, stride, @ptrFromInt(@offsetOf(core.Vertex, "color")));
    gl.glEnableVertexAttribArray(3);
    gl.glVertexAttribIPointer(3, 1, gl.GL_UNSIGNED_INT, stride, @ptrFromInt(@offsetOf(core.Vertex, "deco_flags")));
    gl.glEnableVertexAttribArray(4);
    gl.glVertexAttribPointer(4, 1, gl.GL_FLOAT, gl.GL_FALSE, stride, @ptrFromInt(@offsetOf(core.Vertex, "deco_phase")));

    gl.glGenTextures(1, &t.atlas_tex);
    gl.glBindTexture(gl.GL_TEXTURE_2D, t.atlas_tex);
    // Point sampling and clamp, as the D3D11 atlas sampler.
    gl.glTexParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_MIN_FILTER, gl.GL_NEAREST);
    gl.glTexParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_MAG_FILTER, gl.GL_NEAREST);
    gl.glTexParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_WRAP_S, gl.GL_CLAMP_TO_EDGE);
    gl.glTexParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_WRAP_T, gl.GL_CLAMP_TO_EDGE);
    // A fresh texture has no storage; the first render allocates it.
    t.atlas_w = 0;
    t.atlas_h = 0;
    return true;
}

pub fn unrealize(t: *Target) void {
    if (t.atlas_tex != 0) gl.glDeleteTextures(1, &t.atlas_tex);
    if (t.vbo != 0) gl.glDeleteBuffers(1, &t.vbo);
    if (t.vao != 0) gl.glDeleteVertexArrays(1, &t.vao);
    if (t.program != 0) gl.glDeleteProgram(t.program);
    const w = t.w_px;
    const h = t.h_px;
    const flip = t.flip_y;
    const scratch = t.scratch;
    t.* = .{ .w_px = w, .h_px = h, .flip_y = flip, .scratch = scratch };
}

/// The main window's atlas: queued uploads applied as they come. Caller
/// holds App.mu.
fn drainAtlas(app: *App, t: *Target) void {
    const ops = &app.atlas_pending;
    gl.glActiveTexture(gl.GL_TEXTURE0);
    gl.glBindTexture(gl.GL_TEXTURE_2D, t.atlas_tex);
    gl.glPixelStorei(gl.GL_UNPACK_ALIGNMENT, 1);
    // On atlas create, or a context realized again (atlas_w reset to 0),
    // the texture is rebuilt from the full mirror, which already holds every
    // queued upload.
    if (ops.recreate or (ops.w != 0 and (t.atlas_w != ops.w or t.atlas_h != ops.h))) {
        if (ops.w != 0 and ops.h != 0) {
            gl.glTexImage2D(gl.GL_TEXTURE_2D, 0, gl.GL_RGBA8, @intCast(ops.w), @intCast(ops.h), 0, gl.GL_RGBA, gl.GL_UNSIGNED_BYTE, ops.mirror.items.ptr);
            t.atlas_w = ops.w;
            t.atlas_h = ops.h;
            ops.clearQueued();
        }
        ops.recreate = false;
    }
    if (t.atlas_w != 0) {
        for (ops.uploads.items) |u| {
            gl.glTexSubImage2D(gl.GL_TEXTURE_2D, 0, @intCast(u.x), @intCast(u.y), @intCast(u.w), @intCast(u.h), gl.GL_RGBA, gl.GL_UNSIGNED_BYTE, ops.pixels.items[u.offset..].ptr);
        }
        ops.clearQueued();
    }
    t.atlas_gen = ops.gen;
}

/// An external window's atlas: the whole CPU mirror, whenever the atlas
/// changed since this texture last took it. Glyphs are added rarely once a
/// session warms up, and the main window's queue is not replayed per window.
/// Caller holds App.mu.
fn syncAtlas(app: *App, t: *Target) void {
    const ops = &app.atlas_pending;
    gl.glActiveTexture(gl.GL_TEXTURE0);
    gl.glBindTexture(gl.GL_TEXTURE_2D, t.atlas_tex);
    if (ops.w == 0 or ops.h == 0) return;
    if (t.atlas_w != 0 and t.atlas_gen == ops.gen) return;
    gl.glPixelStorei(gl.GL_UNPACK_ALIGNMENT, 1);
    gl.glTexImage2D(gl.GL_TEXTURE_2D, 0, gl.GL_RGBA8, @intCast(ops.w), @intCast(ops.h), 0, gl.GL_RGBA, gl.GL_UNSIGNED_BYTE, ops.mirror.items.ptr);
    t.atlas_w = ops.w;
    t.atlas_h = ops.h;
    t.atlas_gen = ops.gen;
}

/// Uploads `verts` into the target's persistent VBO and draws them as
/// triangles, scrollable content `scroll_offset_px` lower.
fn drawVerts(app: *App, t: *Target, verts: []const core.Vertex, layer: core.Layer, scroll_offset_px: f32) void {
    if (verts.len == 0) return;
    const bytes = verts.len * @sizeOf(core.Vertex);
    if (bytes > t.vbo_cap_bytes) {
        var cap = @max(t.vbo_cap_bytes, initial_vbo_bytes);
        while (cap < bytes) cap *= 2;
        gl.glBufferData(gl.GL_ARRAY_BUFFER, @intCast(cap), null, gl.GL_DYNAMIC_DRAW);
        t.vbo_cap_bytes = cap;
    }
    gl.glBufferSubData(gl.GL_ARRAY_BUFFER, 0, @intCast(bytes), verts.ptr);
    const x = transform.layerXform(layer, app.cell_w_px, app.cell_h_px, t.w_px, t.h_px);
    const fy: f32 = if (t.flip_y) -1 else 1;
    gl.glUniform2f(t.u_scale, x.scale[0], fy * x.scale[1]);
    gl.glUniform2f(t.u_offset, x.offset[0], fy * x.offset[1]);
    gl.glUniform1f(t.u_scroll_offset, scroll_offset_px);
    gl.glUniform1f(t.u_layer_origin_x, @floatFromInt(layer.x_px));
    gl.glDrawArrays(gl.GL_TRIANGLES, 0, @intCast(verts.len));
}

/// Clips to a rect given top-down in surface px.
fn scissor(t: *const Target, x: i32, top: i32, w: i32, h: i32) void {
    const y = if (t.flip_y) top else @as(i32, @intCast(t.h_px)) - top - h;
    const s = t.px_scale;
    const f = struct {
        fn px(v: i32, k: f32) i32 {
            return @intFromFloat(@round(@as(f32, @floatFromInt(v)) * k));
        }
    }.px;
    gl.glScissor(f(x, s), f(y, s), f(w, s), f(@max(0, h), s));
}

/// `layer`'s cell and box: its grid's own font when it has one. Caller
/// holds App.mu.
fn layerGeom(app: *const App, layer: core.Layer) layer_geom.Geom {
    return layer_geom.Geom.of(layer, app.surface.gridFont(layer.grid_id), app.cell_w_px, app.cell_h_px);
}

/// Clips to rows [row_start, row_end) of `layer`.
fn scissorRows(app: *const App, t: *const Target, layer: core.Layer, row_start: u32, row_end: u32) void {
    const g = layerGeom(app, layer);
    const band = g.rowsBandPx(row_start, row_end);
    scissor(t, layer.x_px, layer.y_px + @as(i32, @intCast(band[0])), @intCast(g.widthPx()), @intCast(band[1] - band[0]));
}

/// Appends rows [start, end) to the target's scratch buffer.
fn gatherRows(app: *App, t: *Target, rows: []const Row, start: usize, end: usize) void {
    for (rows[start..end]) |row| {
        t.scratch.appendSlice(app.alloc, row.verts.items) catch break;
    }
}

/// Draws one layer's committed rows. An eased grid's scroll region is drawn
/// apart, under its own scissor, at the ease offset together with the rows
/// it scrolled out, so the band the offset opens is filled and nothing moves
/// into the margins around it. A grid in its own font is clipped to its
/// extent (zonvie_core.h on_grid_font); that clip replaces any scissor the
/// caller set, so the ext UI overlays, whose grids are no Neovim windows and
/// never get a font, are the only callers that set one. Returns the vertex
/// count drawn.
fn drawLayer(app: *App, t: *Target, layer: core.Layer, grid: *const GridRows, region: [2]u32, offset_px: f32) usize {
    const rows = grid.committedRows();
    const r0: usize = @min(region[0], rows.len);
    const r1: usize = @min(region[1], rows.len);
    var total: usize = 0;
    const boxed = layerGeom(app, layer).extent != null;
    if (boxed) {
        gl.glEnable(gl.GL_SCISSOR_TEST);
        scissorRows(app, t, layer, 0, layer.rows);
    }
    defer if (boxed) gl.glDisable(gl.GL_SCISSOR_TEST);

    t.scratch.clearRetainingCapacity();
    gatherRows(app, t, rows, 0, r0);
    gatherRows(app, t, rows, r1, rows.len);
    total += t.scratch.items.len;
    drawVerts(app, t, t.scratch.items, layer, 0);
    if (r0 == r1) return total;

    t.scratch.clearRetainingCapacity();
    gatherRows(app, t, rows, r0, r1);
    for (grid.retainedRows()) |r| {
        if (!r.live) continue;
        t.scratch.appendSlice(app.alloc, r.verts.items) catch break;
    }
    total += t.scratch.items.len;
    gl.glEnable(gl.GL_SCISSOR_TEST);
    scissorRows(app, t, layer, @intCast(r0), @intCast(r1));
    drawVerts(app, t, t.scratch.items, layer, offset_px);
    gl.glDisable(gl.GL_SCISSOR_TEST);
    return total;
}

/// Clears the target and binds its pipeline. False when there is nothing to
/// draw with yet.
fn begin(app: *App, t: *Target) bool {
    const bg = app.default_bg;
    // Premultiplied: [window] opacity is the background's alpha, as Windows
    // clears its swapchain.
    const a = std.math.clamp(app.window_cfg.opacity, 0, 1);
    gl.glViewport(0, 0, @intCast(t.w_px), @intCast(t.h_px));
    gl.glClearColor(
        @as(f32, @floatFromInt((bg >> 16) & 0xff)) / 255.0 * a,
        @as(f32, @floatFromInt((bg >> 8) & 0xff)) / 255.0 * a,
        @as(f32, @floatFromInt(bg & 0xff)) / 255.0 * a,
        a,
    );
    gl.glClear(gl.GL_COLOR_BUFFER_BIT);
    return bind(t);
}

/// Binds the target's pipeline over what the caller cleared. False when
/// there is nothing to draw with yet.
fn bind(t: *Target) bool {
    if (t.atlas_w == 0 or t.w_px == 0 or t.h_px == 0) return false;
    gl.glUseProgram(t.program);
    gl.glUniform1i(t.u_mode, 0);
    gl.glBindVertexArray(t.vao);
    gl.glBindBuffer(gl.GL_ARRAY_BUFFER, t.vbo);
    gl.glEnable(gl.GL_BLEND);
    gl.glBlendFunc(gl.GL_ONE, gl.GL_ONE_MINUS_SRC_ALPHA);
    return true;
}

const SurfaceDraw = struct { verts: usize = 0, moving: bool = false };

/// `layer` where this frame draws it: a float that tracks the buffer moves
/// bodily with its anchor window's smooth scroll, as Neovim re-places it
/// once the scroll lands (layer_geom.scrollAnchor). Caller holds App.mu; the
/// anchor, behind the float, has had its ease planned this frame.
fn followed(app: *App, layer: core.Layer, layers: []const core.Layer) core.Layer {
    const own = app.surface.gridEase(layer.grid_id);
    const anchor = layer_geom.scrollAnchor(layer, if (own) |e| e.easing else false, layers) orelse return layer;
    const e = app.surface.gridEase(anchor.grid_id) orelse return layer;
    if (!e.easing) return layer;
    var moved = layer;
    moved.y_px += @intFromFloat(@round(e.offset_px));
    return moved;
}

/// One surface's layers back-to-front, eased, then the cursor when its grid
/// is on this surface. Caller holds App.mu.
fn drawSurface(app: *App, t: *Target, layers: []const core.Layer, now_ns: i64) SurfaceDraw {
    var out: SurfaceDraw = .{};
    // A translucent target is cleared to the background at its alpha, and
    // the back layer's default-background cells carry that alpha themselves:
    // drawn over the clear the two would compound, so the clear goes from
    // under that layer. Not under blur, where the core drops those cells
    // and the clear is their background.
    if (layers.len != 0 and !app.window_cfg.blur and app.window_cfg.opacity < 1.0) {
        gl.glEnable(gl.GL_SCISSOR_TEST);
        scissorRows(app, t, layers[0], 0, layers[0].rows);
        gl.glClearColor(0, 0, 0, 0);
        gl.glClear(gl.GL_COLOR_BUFFER_BIT);
        gl.glDisable(gl.GL_SCISSOR_TEST);
    }
    // The core sends layers back-to-front; draw in order (windows/app.zig:4432).
    for (layers) |layer| {
        const grid = app.surface.committedGrid(layer.grid_id) orelse continue;
        const ease = app.surface.gridEase(layer.grid_id).?;
        ease.plan(now_ns, layerGeom(app, layer).row_h_px, grid.committedRows().len);
        if (ease.moving()) out.moving = true;
        out.verts += drawLayer(app, t, followed(app, layer, layers), grid, ease.region(), ease.offset_px);
    }
    const cur = app.surface.committedCursor();
    if (cur.verts.len == 0 or !app.cursor_blink.visible or t.skip_cursor) return out;
    for (layers) |placed| {
        if (placed.grid_id != cur.grid_id) continue;
        const layer = followed(app, placed, layers);
        out.verts += cur.verts.len;
        // The cursor rides its grid's ease, clipped like the region.
        const ease = app.surface.gridEase(layer.grid_id);
        const region: [2]u32 = if (ease) |e| e.region() else .{ 0, 0 };
        if (region[0] != region[1]) {
            gl.glEnable(gl.GL_SCISSOR_TEST);
            scissorRows(app, t, layer, region[0], region[1]);
        } else if (layerGeom(app, layer).extent != null) {
            gl.glEnable(gl.GL_SCISSOR_TEST);
            scissorRows(app, t, layer, 0, layer.rows);
        }
        drawVerts(app, t, cur.verts, layer, if (ease) |e| e.offset_px else 0);
        gl.glDisable(gl.GL_SCISSOR_TEST);
        break;
    }
    return out;
}

pub const Frame = struct {
    /// Some grid eases: the caller keeps frames coming (startEaseTick).
    moving: bool = false,
    /// App.flush_seq of the committed frame drawn.
    flush_seq: u64 = 0,
};

/// The main surface and its overlays into `t`, sized `t.w_px` x `t.h_px`.
/// Takes App.mu. Any thread with `t`'s context current: the GLArea's render
/// signal, or the render thread.
pub fn renderMain(app: *App, t: *Target) Frame {
    if (t.program == 0) return .{};
    const t0 = clock.nowNs();
    app.mu.lockUncancelable(clock.io());
    defer app.mu.unlock(clock.io());

    drainAtlas(app, t);
    const seq = app.flush_seq;
    if (!begin(app, t)) return .{ .flush_seq = seq };

    const layers = app.surface.committedLayers();
    const d = drawSurface(app, t, layers, @intCast(t0));
    drawScrollbar(app, t, &app.scrollbar);
    const overlay_verts = drawOverlays(app, t, 1);

    if (applog.isEnabled()) {
        const us = @divTrunc(clock.nowNs() - t0, 1000);
        applog.appLog("[perf] linux_render us={d} layers={d} verts={d} easing={}\n", .{ us, layers.len, d.verts + overlay_verts, d.moving });
    }
    return .{ .moving = d.moving, .flush_seq = seq };
}

/// A surface's glow-flagged glyphs, in extract mode, into the bound
/// framebuffer: `scale` of the surface's size, cleared first. The eases were
/// planned by this frame's scene pass, so the glyphs sit where it drew them.
/// Takes App.mu.
pub fn drawGlowExtract(app: *App, t: *Target, scale: f32, surface_id: i64) void {
    app.mu.lockUncancelable(clock.io());
    defer app.mu.unlock(clock.io());
    const w: i32 = @intFromFloat(@max(1, @round(@as(f32, @floatFromInt(t.w_px)) * scale)));
    const h: i32 = @intFromFloat(@max(1, @round(@as(f32, @floatFromInt(t.h_px)) * scale)));
    gl.glViewport(0, 0, w, h);
    gl.glClearColor(0, 0, 0, 0);
    gl.glClear(gl.GL_COLOR_BUFFER_BIT);
    gl.glUseProgram(t.program);
    gl.glUniform1i(t.u_mode, 1);
    gl.glBindVertexArray(t.vao);
    gl.glBindBuffer(gl.GL_ARRAY_BUFFER, t.vbo);
    gl.glActiveTexture(gl.GL_TEXTURE0);
    gl.glBindTexture(gl.GL_TEXTURE_2D, t.atlas_tex);
    gl.glEnable(gl.GL_BLEND);
    gl.glBlendFunc(gl.GL_ONE, gl.GL_ONE_MINUS_SRC_ALPHA);
    t.px_scale = scale;
    defer t.px_scale = 1;
    const layers = app.surface.committedSurfaceLayers(surface_id);
    for (layers) |layer| {
        const grid = app.surface.committedGrid(layer.grid_id) orelse continue;
        const ease = app.surface.gridEase(layer.grid_id).?;
        _ = drawLayer(app, t, followed(app, layer, layers), grid, ease.region(), ease.offset_px);
    }
    gl.glUniform1i(t.u_mode, 0);
}

/// The main GLArea's render signal.
pub fn render(app: *App) void {
    app.gl.w_px = app.drawable_w_px;
    app.gl.h_px = app.drawable_h_px;
    if (postfx.active(app, &app.postfx)) {
        const f = postfx.renderFrame(app, &app.gl, &app.postfx, 1);
        app.presented_seq = f.flush_seq;
        if (f.moving or app.postfx.animating) startEaseTick(app);
        if (applog.isEnabled()) applog.appLog("[trace] event=frame_done surface=1\n", .{});
        return;
    }
    const f = renderMain(app, &app.gl);
    app.presented_seq = f.flush_seq;
    if (applog.isEnabled()) applog.appLog("[trace] event=frame_done surface=1\n", .{});
    if (f.moving) startEaseTick(app);
}

/// An external window: the surface rooted at `surface_id`.
/// An external surface into `t`, with the panels anchored in it (a
/// popupmenu, message panels by msg_pos). Takes App.mu.
pub fn renderExternalScene(app: *App, t: *Target, surface_id: i64) Frame {
    if (t.program == 0) return .{};
    const t0 = clock.nowNs();
    app.mu.lockUncancelable(clock.io());
    defer app.mu.unlock(clock.io());

    syncAtlas(app, t);
    const seq = app.flush_seq;
    if (!begin(app, t)) return .{ .flush_seq = seq };
    const d = drawSurface(app, t, app.surface.committedSurfaceLayers(surface_id), @intCast(t0));
    if (app.ext_windows.get(surface_id)) |w| drawScrollbar(app, t, &w.scrollbar);
    _ = drawOverlays(app, t, surface_id);
    return .{ .moving = d.moving, .flush_seq = seq };
}

/// The surface's scrollbar over its grids, under the ext UI overlays.
/// Caller holds App.mu.
fn drawScrollbar(app: *App, t: *Target, st: *const scrollbar.State) void {
    const vp = scrollbar.drawn(app, st) orelse return;
    const g = scrollbar.geometry(vp, @floatFromInt(t.w_px), @floatFromInt(t.h_px), app.scale);
    if (!g.scrollable and !app.scrollbar_cfg.isAlways()) return;
    const c = scrollbar.colors(app, st.alpha);
    t.scratch.clearRetainingCapacity();
    const tl: i32 = @intFromFloat(@floor(g.track_left));
    const tw: i32 = @intFromFloat(@ceil(g.track_right - g.track_left));
    pushRect(app, t, tl, @intFromFloat(g.track_top), tw, @intFromFloat(g.track_bottom - g.track_top), c.track);
    if (g.scrollable) pushRect(app, t, tl, @intFromFloat(g.knob_top), tw, @intFromFloat(@max(1, g.knob_bottom - g.knob_top)), c.knob);
    drawVerts(app, t, t.scratch.items, surface_layer, 0);
}

/// An external window's render signal: the surface rooted at `surface_id`.
pub fn renderExternal(app: *App, t: *Target, p: *postfx.PostFx, surface_id: i64) void {
    const f = if (postfx.active(app, p))
        postfx.renderFrame(app, t, p, surface_id)
    else
        renderExternalScene(app, t, surface_id);
    if (f.moving or p.animating) startEaseTick(app);
    if (applog.isEnabled()) applog.appLog("[trace] event=frame_done surface={d}\n", .{surface_id});
}

/// A panel popup's render signal (panel_popup.zig): panel `kind` at
/// `inner` (target px) over a transparent clear, so its shadow falls on
/// whatever is under the popup; `view` is where the panel is on the main
/// view. The atlas is synced from the mirror as an external window's is.
/// Takes App.mu.
pub fn renderPanel(app: *App, t: *Target, kind: overlay_layout.Kind, inner: overlay_layout.Rect, view: overlay_layout.Rect) void {
    if (t.program == 0) return;
    app.mu.lockUncancelable(clock.io());
    defer app.mu.unlock(clock.io());
    syncAtlas(app, t);
    gl.glViewport(0, 0, @intCast(t.w_px), @intCast(t.h_px));
    gl.glClearColor(0, 0, 0, 0);
    gl.glClear(gl.GL_COLOR_BUFFER_BIT);
    if (!bind(t)) return;
    _ = drawPanel(app, t, kind, inner, view);
}

fn rgba(rgb: u32, a: f32) [4]f32 {
    return .{
        @as(f32, @floatFromInt((rgb >> 16) & 0xff)) / 255.0,
        @as(f32, @floatFromInt((rgb >> 8) & 0xff)) / 255.0,
        @as(f32, @floatFromInt(rgb & 0xff)) / 255.0,
        a,
    };
}

/// A solid quad in surface px, for the overlay panels.
fn pushRect(app: *App, t: *Target, x: i32, y: i32, w: i32, h: i32, color: [4]f32) void {
    const x0: f32 = @floatFromInt(x);
    const y0: f32 = @floatFromInt(y);
    const x1: f32 = @floatFromInt(x + w);
    const y1: f32 = @floatFromInt(y + h);
    const corners = [_][2]f32{ .{ x0, y0 }, .{ x1, y0 }, .{ x0, y1 }, .{ x1, y0 }, .{ x1, y1 }, .{ x0, y1 } };
    for (corners) |p| {
        t.scratch.append(app.alloc, .{
            .position = p,
            .texCoord = .{ -1, -1 },
            .color = color,
            .grid_id = 0,
            .deco_flags = 0,
            .deco_phase = 0,
        }) catch return;
    }
}

fn pushTri(app: *App, t: *Target, pts: [3][2]f32, color: [4]f32) void {
    for (pts) |p| {
        t.scratch.append(app.alloc, .{
            .position = p,
            .texCoord = .{ -1, -1 },
            .color = color,
            .grid_id = 0,
            .deco_flags = 0,
            .deco_phase = 0,
        }) catch return;
    }
}

/// The convex polygon `outline` filled, as a fan from `centre`.
fn pushFan(app: *App, t: *Target, centre: [2]f32, outline: [overlay_layout.outline_points][2]f32, color: [4]f32) void {
    for (outline, 0..) |p, i| pushTri(app, t, .{ centre, p, outline[(i + 1) % outline.len] }, color);
}

/// The band between two outlines of the same points, `outer` around `inner`.
fn pushRing(app: *App, t: *Target, outer: [overlay_layout.outline_points][2]f32, inner: [overlay_layout.outline_points][2]f32, color: [4]f32) void {
    for (0..outer.len) |i| {
        const j = (i + 1) % outer.len;
        pushTri(app, t, .{ outer[i], outer[j], inner[i] }, color);
        pushTri(app, t, .{ outer[j], inner[j], inner[i] }, color);
    }
}

/// A stroke from `a` to `b`, `half_w` either side, as two triangles.
fn pushSegment(app: *App, t: *Target, a: [2]f32, b: [2]f32, half_w: f32, color: [4]f32) void {
    const dx = b[0] - a[0];
    const dy = b[1] - a[1];
    const len = @sqrt(dx * dx + dy * dy);
    if (len == 0) return;
    const nx = -dy / len * half_w;
    const ny = dx / len * half_w;
    const a0: [2]f32 = .{ a[0] + nx, a[1] + ny };
    const a1: [2]f32 = .{ a[0] - nx, a[1] - ny };
    const b0: [2]f32 = .{ b[0] + nx, b[1] + ny };
    const b1: [2]f32 = .{ b[0] - nx, b[1] - ny };
    pushTri(app, t, .{ a0, b0, a1 }, color);
    pushTri(app, t, .{ b0, b1, a1 }, color);
}

/// The cmdline icon in `box`: a magnifier for a search, else a chevron.
/// The shapes and margins of the D3D11 icon SDFs (windows/shaders/main.hlsl
/// ICON_CIRCLE, ICON_HANDLE, ICON_CHEVRON), in box-local 0..1 units.
fn pushCmdlineIcon(app: *App, t: *Target, box: overlay_layout.Rect, search: bool, color: [4]f32) void {
    const margin: f32 = if (search) 0.15 else 0.18;
    const bw: f32 = @floatFromInt(box.w);
    const bh: f32 = @floatFromInt(box.h);
    const ox = @as(f32, @floatFromInt(box.x)) + bw * margin;
    const oy = @as(f32, @floatFromInt(box.y)) + bh * margin;
    const sw = bw * (1 - 2 * margin);
    const sh = bh * (1 - 2 * margin);
    const P = struct {
        fn at(x: f32, y: f32, o: [2]f32, size: [2]f32) [2]f32 {
            return .{ o[0] + x * size[0], o[1] + y * size[1] };
        }
    };
    const o: [2]f32 = .{ ox, oy };
    const sz: [2]f32 = .{ sw, sh };
    if (!search) {
        const tip = P.at(0.75, 0.5, o, sz);
        pushSegment(app, t, P.at(0.25, 0.2, o, sz), tip, 0.08 * sw, color);
        pushSegment(app, t, P.at(0.25, 0.8, o, sz), tip, 0.08 * sw, color);
        return;
    }
    const segments = 24;
    const c = P.at(0.42, 0.42, o, sz);
    const rad = 0.32 * sw;
    var i: usize = 0;
    while (i < segments) : (i += 1) {
        const a0 = @as(f32, @floatFromInt(i)) / segments * 2 * std.math.pi;
        const a1 = @as(f32, @floatFromInt(i + 1)) / segments * 2 * std.math.pi;
        pushTri(app, t, .{ c, .{ c[0] + rad * @cos(a0), c[1] + rad * @sin(a0) }, .{ c[0] + rad * @cos(a1), c[1] + rad * @sin(a1) } }, color);
    }
    pushSegment(app, t, P.at(0.5, 0.5, o, sz), P.at(0.92, 0.92, o, sz), 0.06 * sw, color);
}

const surface_layer: core.Layer = .{ .grid_id = 0, .anchor_grid = 0, .x_px = 0, .y_px = 0, .rows = 0, .cols = 0, .z = 0, .flags = 0 };

fn surfaceOpen(app: *const App, id: i64) bool {
    return app.surface.committedSurfaceLayers(id).len != 0;
}

/// What places the ext UI panels on surface `surface_id` (1, the main view,
/// or an external window), `w_px` x `h_px`: the one answer for the panels
/// drawn here, the copy buttons over them (ui_widgets.placeCopyButtons) and
/// the pointer's hit tests. Caller holds App.mu.
pub fn overlayInputs(app: *const App, surface_id: i64, w_px: u32, h_px: u32) overlay_layout.Inputs {
    const w: i32 = @intCast(w_px);
    const h: i32 = @intCast(h_px);
    const cw: i32 = @intCast(app.cell_w_px);
    const ch: i32 = @intCast(app.cell_h_px);
    const main = surface_id == 1;
    const msg_surface = overlay_layout.msgSurface(app.msg_pos.ext_float, app.msg_anchor, app, surfaceOpen);
    return .{
        .surface_id = surface_id,
        .main_w_px = w,
        .main_h_px = h,
        .cell_w_px = cw,
        .cell_h_px = ch,
        .scale = @intFromFloat(app.scale),
        .msg_target = overlay_layout.msgTargetOn(surface_id, app.msg_pos.ext_float, app.msg_anchor, w, h, cw, ch),
        .pum_surface = overlay_layout.popupSurface(app.overlays[@intFromEnum(overlay_layout.Kind.popupmenu)], app, surfaceOpen),
        .msg_surface = msg_surface,
        // The copy buttons are widgets over the main view only.
        .copy_cmdline = app.copy_cmdline and main,
        .copy_messages = app.copy_messages and main,
        .confirm = if (main) app.confirm_rect else null,
        .cmdline_user = app.cmdline_user,
        .msg_show_user = app.msg_show_user,
        .free = app.panel_popups,
    };
}

/// The core-owned ext UI surfaces that draw on surface `surface_id`, over
/// everything else there. None while the panels are popup surfaces of their
/// own (panel_popup.zig), on whichever surface they hang from: the popups
/// draw them with drawPanel.
fn drawOverlays(app: *App, t: *Target, surface_id: i64) usize {
    if (app.panel_popups) return 0;
    const rects = overlay_layout.place(&app.overlays, overlayInputs(app, surface_id, t.w_px, t.h_px));
    var total: usize = 0;
    for (overlay_layout.draw_order) |kind| {
        const r = rects[@intFromEnum(kind)] orelse continue;
        total += drawPanel(app, t, kind, r, r);
    }
    return total;
}

/// Panel `kind` at `r` (target px): its shadow, border and fill, then its
/// grid's layers inside its padding. `logged` is where it is on the view,
/// for the GUI harness's [overlay] line. Returns the vertex count; 0 with
/// nothing drawn while the panel's grid has no layers yet. Caller holds
/// App.mu, with `t`'s pipeline bound.
fn drawPanel(app: *App, t: *Target, kind: overlay_layout.Kind, r: overlay_layout.Rect, logged: overlay_layout.Rect) usize {
    const scale: i32 = @intFromFloat(app.scale);
    const bg = rgba(app.default_bg, 1);
    const panel = rules.panelBg(bg[0], bg[1], bg[2]);
    // As on Windows and macOS: the cmdline and popupmenu carry a Search-bg
    // border, the message panels none.
    const border = rgba(app.cmdline_border_rgb, 1);
    const opacity = std.math.clamp(app.window_cfg.opacity, 0, 1);
    const cur = app.surface.committedCursor();
    var total: usize = 0;
    {
        const gid = overlay_layout.gridId(kind);
        const layers = app.surface.committedSurfaceLayers(gid);
        if (layers.len == 0) return 0;
        if (applog.isEnabled()) applog.appLog("[overlay] {s} x={d} y={d} w={d} h={d} layers={d}\n", .{ @tagName(kind), logged.x, logged.y, logged.w, logged.h, layers.len });

        // The popupmenu's Pmenu goes through panelBg as the other panels'
        // Normal does, as on Windows and macOS.
        const pmenu = rgba(app.pmenu_bg, 1);
        const pmenu_panel = rules.panelBg(pmenu[0], pmenu[1], pmenu[2]);
        // At the window's opacity, as Windows paints every panel's one bg
        // rect: what is under it shows through. The compositor's blur acts
        // on the window, so under a panel it shows the editor unblurred.
        const fill: [4]f32 = if (kind == .popupmenu) .{ pmenu_panel[0], pmenu_panel[1], pmenu_panel[2], opacity } else .{ panel[0], panel[1], panel[2], opacity };
        t.scratch.clearRetainingCapacity();
        // Rounded as macOS's panels. The border is a ring around the
        // panel, not a shape under it, which a translucent fill would let
        // through.
        const radius = overlay_layout.panel_radius_pt * app.scale;
        const inner = overlay_layout.panelOutline(r, 0, radius);
        // The shadow lies outside the border, which lies outside the fill.
        const shadow_from: f32 = if (kind == .cmdline or kind == .popupmenu) @floatFromInt(scale) else 0;
        for (0..overlay_layout.shadow_rings) |i| {
            const ring = overlay_layout.shadowRing(i, overlay_layout.shadow_spread_pt, app.scale, overlay_layout.shadow_alpha * opacity);
            pushRing(app, t, overlay_layout.panelOutline(r, shadow_from + ring.outer_px, radius), overlay_layout.panelOutline(r, shadow_from + ring.inner_px, radius), .{ 0, 0, 0, ring.alpha });
        }
        if (kind == .cmdline or kind == .popupmenu) pushRing(app, t, overlay_layout.panelOutline(r, @floatFromInt(scale), radius), inner, border);
        pushFan(app, t, .{ @as(f32, @floatFromInt(r.x)) + @as(f32, @floatFromInt(r.w)) / 2, @as(f32, @floatFromInt(r.y)) + @as(f32, @floatFromInt(r.h)) / 2 }, inner, fill);
        if (kind == .cmdline) pushCmdlineIcon(app, t, overlay_layout.cmdlineIconRect(r, scale), app.cmdline_firstc == '/' or app.cmdline_firstc == '?', rgba(app.cmdline_icon_rgb, 1));
        drawVerts(app, t, t.scratch.items, surface_layer, 0);

        // A cmdline wider than the window is clipped to its panel.
        gl.glEnable(gl.GL_SCISSOR_TEST);
        scissor(t, r.x, r.y, r.w, r.h);
        const origin = overlay_layout.contentOrigin(kind, scale);
        // Cells in the panel's source colour let its fill through, so no
        // darker band shows behind the text (as on Windows).
        const src = if (kind == .popupmenu) pmenu else bg;
        gl.glUseProgram(t.program);
        gl.glUniform4f(t.u_clear_bg, src[0], src[1], src[2], 1);
        defer gl.glUniform4f(t.u_clear_bg, 0, 0, 0, -1);
        for (layers) |layer| {
            var placed = layer;
            placed.x_px += r.x + origin[0];
            placed.y_px += r.y + origin[1];
            if (app.surface.committedGrid(layer.grid_id)) |grid| total += drawLayer(app, t, placed, grid, .{ 0, 0 }, 0);
            if (cur.verts.len != 0 and cur.grid_id == layer.grid_id and app.cursor_blink.visible and !t.skip_cursor) {
                total += cur.verts.len;
                drawVerts(app, t, cur.verts, placed, 0);
            }
        }
        gl.glDisable(gl.GL_SCISSOR_TEST);
        if (overlay_layout.closeBadgeRect(kind, r, scale)) |box| {
            t.scratch.clearRetainingCapacity();
            pushCloseBadge(app, t, box, app.msg_chrome.look(), rgba(app.cmdline_icon_rgb, 1));
            drawVerts(app, t, t.scratch.items, surface_layer, 0);
        }
    }
    return total;
}

/// msg_show's close badge in `box` (frontend_rules.msgCloseBadgePaint): a
/// disc of `tint` at the look's alpha under a cross at full tint, the
/// Comment-fg tint Windows paints it with. Nothing while hidden.
fn pushCloseBadge(app: *App, t: *Target, box: overlay_layout.Rect, look: rules.MsgCloseBadgeLook, tint: [4]f32) void {
    const paint = rules.msgCloseBadgePaint(look, app.scale);
    if (paint.fill_alpha == 0) return;
    const x0: f32 = @floatFromInt(box.x);
    const y0: f32 = @floatFromInt(box.y);
    const size: f32 = @floatFromInt(box.w);
    const c: [2]f32 = .{ x0 + size / 2, y0 + size / 2 };
    const rad = size / 2;
    const disc: [4]f32 = .{ tint[0], tint[1], tint[2], paint.fill_alpha };
    const segments = 24;
    var i: usize = 0;
    while (i < segments) : (i += 1) {
        const a0 = @as(f32, @floatFromInt(i)) / segments * 2 * std.math.pi;
        const a1 = @as(f32, @floatFromInt(i + 1)) / segments * 2 * std.math.pi;
        pushTri(app, t, .{ c, .{ c[0] + rad * @cos(a0), c[1] + rad * @sin(a0) }, .{ c[0] + rad * @cos(a1), c[1] + rad * @sin(a1) } }, disc);
    }
    const lo = paint.cross_inset_px;
    const hi = size - paint.cross_inset_px;
    const half_w = paint.cross_stroke_px / 2;
    pushSegment(app, t, .{ x0 + lo, y0 + lo }, .{ x0 + hi, y0 + hi }, half_w, tint);
    pushSegment(app, t, .{ x0 + hi, y0 + lo }, .{ x0 + lo, y0 + hi }, half_w, tint);
}

/// Redraws every window on each frame-clock tick while some grid eases; the
/// tick that finds every ease at rest removes itself. GTK main thread.
pub fn startEaseTick(app: *App) void {
    if (app.ease_tick_active) return;
    const widget = app.frame_widget orelse return;
    app.ease_tick_active = true;
    _ = gtk.gtk_widget_add_tick_callback(widget, &onEaseTick, app, null);
}

fn onEaseTick(widget: ?*anyopaque, frame_clock: ?*anyopaque, data: ?*anyopaque) callconv(.c) c_int {
    _ = widget;
    _ = frame_clock;
    const app: *App = @ptrCast(@alignCast(data.?));
    app.queueRenderAll();
    app.mu.lockUncancelable(clock.io());
    defer app.mu.unlock(clock.io());
    // An animated custom shader keeps frames coming as an ease does.
    var moving = app.postfx.animating;
    if (app.render_thread) |rt| {
        if (rt.animating.load(.acquire)) moving = true;
    }
    var it = app.surface.grids.valueIterator();
    while (it.next()) |g| {
        if (g.*.ease.moving()) moving = true;
    }
    if (!moving) app.ease_tick_active = false;
    return @intFromBool(moving);
}
