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
    w_px: u32 = 0,
    h_px: u32 = 0,
    /// Row 0 of the framebuffer is the image's top: an FBO over a dmabuf
    /// that GTK reads top-down, unlike a GLArea's.
    flip_y: bool = false,
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
    gl.glUseProgram(prog);
    gl.glUniform1i(gl.glGetUniformLocation(prog, "u_atlas"), 0);

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
    gl.glScissor(x, y, w, @max(0, h));
}

/// Clips to rows [row_start, row_end) of `layer`.
fn scissorRows(app: *const App, t: *const Target, layer: core.Layer, row_start: u32, row_end: u32) void {
    const h: i32 = @intCast(app.cell_h_px);
    const top = layer.y_px + @as(i32, @intCast(row_start)) * h;
    const bottom = layer.y_px + @as(i32, @intCast(row_end)) * h;
    scissor(t, layer.x_px, top, @intCast(layer.cols * app.cell_w_px), bottom - top);
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
/// into the margins around it. Returns the vertex count drawn.
fn drawLayer(app: *App, t: *Target, layer: core.Layer, grid: *const GridRows, region: [2]u32, offset_px: f32) usize {
    const rows = grid.committedRows();
    const r0: usize = @min(region[0], rows.len);
    const r1: usize = @min(region[1], rows.len);
    var total: usize = 0;

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
    gl.glViewport(0, 0, @intCast(t.w_px), @intCast(t.h_px));
    gl.glClearColor(
        @as(f32, @floatFromInt((bg >> 16) & 0xff)) / 255.0,
        @as(f32, @floatFromInt((bg >> 8) & 0xff)) / 255.0,
        @as(f32, @floatFromInt(bg & 0xff)) / 255.0,
        1.0,
    );
    gl.glClear(gl.GL_COLOR_BUFFER_BIT);
    if (t.atlas_w == 0 or t.w_px == 0 or t.h_px == 0) return false;
    gl.glUseProgram(t.program);
    gl.glBindVertexArray(t.vao);
    gl.glBindBuffer(gl.GL_ARRAY_BUFFER, t.vbo);
    gl.glEnable(gl.GL_BLEND);
    gl.glBlendFunc(gl.GL_ONE, gl.GL_ONE_MINUS_SRC_ALPHA);
    return true;
}

const SurfaceDraw = struct { verts: usize = 0, moving: bool = false };

/// One surface's layers back-to-front, eased, then the cursor when its grid
/// is on this surface. Caller holds App.mu.
fn drawSurface(app: *App, t: *Target, layers: []const core.Layer, now_ns: i64) SurfaceDraw {
    var out: SurfaceDraw = .{};
    // The core sends layers back-to-front; draw in order (windows/app.zig:4432).
    for (layers) |layer| {
        const grid = app.surface.committedGrid(layer.grid_id) orelse continue;
        const ease = app.surface.gridEase(layer.grid_id).?;
        ease.plan(now_ns, app.cell_h_px, grid.committedRows().len);
        if (ease.moving()) out.moving = true;
        out.verts += drawLayer(app, t, layer, grid, ease.region(), ease.offset_px);
    }
    const cur = app.surface.committedCursor();
    if (cur.verts.len == 0) return out;
    for (layers) |layer| {
        if (layer.grid_id != cur.grid_id) continue;
        out.verts += cur.verts.len;
        // The cursor rides its grid's ease, clipped like the region.
        const ease = app.surface.gridEase(layer.grid_id);
        const region: [2]u32 = if (ease) |e| e.region() else .{ 0, 0 };
        if (region[0] != region[1]) {
            gl.glEnable(gl.GL_SCISSOR_TEST);
            scissorRows(app, t, layer, region[0], region[1]);
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
    const overlay_verts = drawOverlays(app, t);

    if (applog.isEnabled()) {
        const us = @divTrunc(clock.nowNs() - t0, 1000);
        applog.appLog("[perf] linux_render us={d} layers={d} verts={d} easing={}\n", .{ us, layers.len, d.verts + overlay_verts, d.moving });
    }
    return .{ .moving = d.moving, .flush_seq = seq };
}

/// The main GLArea's render signal.
pub fn render(app: *App) void {
    app.gl.w_px = app.drawable_w_px;
    app.gl.h_px = app.drawable_h_px;
    const f = renderMain(app, &app.gl);
    app.presented_seq = f.flush_seq;
    if (applog.isEnabled()) applog.appLog("[trace] event=frame_done surface=1\n", .{});
    if (f.moving) startEaseTick(app);
}

/// An external window: the surface rooted at `surface_id`.
pub fn renderExternal(app: *App, t: *Target, surface_id: i64) void {
    if (t.program == 0) return;
    const t0 = clock.nowNs();
    app.mu.lockUncancelable(clock.io());
    defer app.mu.unlock(clock.io());

    syncAtlas(app, t);
    if (!begin(app, t)) return;
    const d = drawSurface(app, t, app.surface.committedSurfaceLayers(surface_id), @intCast(t0));
    if (d.moving) startEaseTick(app);
    if (applog.isEnabled()) applog.appLog("[trace] event=frame_done surface={d}\n", .{surface_id});
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

const surface_layer: core.Layer = .{ .grid_id = 0, .anchor_grid = 0, .x_px = 0, .y_px = 0, .rows = 0, .cols = 0, .z = 0, .flags = 0 };

/// The core-owned ext UI surfaces, over everything else on the main
/// surface: a panel, then the surface's layers inside its padding.
fn drawOverlays(app: *App, t: *Target) usize {
    const scale: i32 = @intFromFloat(app.scale);
    const rects = overlay_layout.place(&app.overlays, .{
        .main_w_px = @intCast(t.w_px),
        .main_h_px = @intCast(t.h_px),
        .cell_w_px = @intCast(app.cell_w_px),
        .cell_h_px = @intCast(app.cell_h_px),
        .scale = scale,
    });
    const bg = rgba(app.default_bg, 1);
    const panel = rules.panelBg(bg[0], bg[1], bg[2]);
    const border = rgba(app.default_fg, 0.25);
    const cur = app.surface.committedCursor();
    var total: usize = 0;
    for (overlay_layout.draw_order) |kind| {
        const r = rects[@intFromEnum(kind)] orelse continue;
        const gid = overlay_layout.gridId(kind);
        const layers = app.surface.committedSurfaceLayers(gid);
        if (layers.len == 0) continue;
        if (applog.isEnabled()) applog.appLog("[overlay] {s} x={d} y={d} w={d} h={d} layers={d}\n", .{ @tagName(kind), r.x, r.y, r.w, r.h, layers.len });

        const fill: [4]f32 = if (kind == .popupmenu) rgba(app.pmenu_bg, 1) else .{ panel[0], panel[1], panel[2], 1 };
        t.scratch.clearRetainingCapacity();
        pushRect(app, t, r.x - scale, r.y - scale, r.w + 2 * scale, r.h + 2 * scale, border);
        pushRect(app, t, r.x, r.y, r.w, r.h, fill);
        drawVerts(app, t, t.scratch.items, surface_layer, 0);

        // A cmdline wider than the window is clipped to its panel.
        gl.glEnable(gl.GL_SCISSOR_TEST);
        scissor(t, r.x, r.y, r.w, r.h);
        const pad = overlay_layout.paddingPx(kind, scale);
        for (layers) |layer| {
            var placed = layer;
            placed.x_px += r.x + pad;
            placed.y_px += r.y + pad;
            if (app.surface.committedGrid(layer.grid_id)) |grid| total += drawLayer(app, t, placed, grid, .{ 0, 0 }, 0);
            if (cur.verts.len != 0 and cur.grid_id == layer.grid_id) {
                total += cur.verts.len;
                drawVerts(app, t, cur.verts, placed, 0);
            }
        }
        gl.glDisable(gl.GL_SCISSOR_TEST);
    }
    return total;
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
    var moving = false;
    var it = app.surface.grids.valueIterator();
    while (it.next()) |g| {
        if (g.*.ease.moving()) moving = true;
    }
    if (!moving) app.ease_tick_active = false;
    return @intFromBool(moving);
}
