//! OpenGL 3.3 painter for the committed surface snapshot. Runs on the GTK
//! main thread with the GtkGLArea context current and its FBO bound.

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
    app.gl_u_scroll_offset = gl.glGetUniformLocation(prog, "u_scroll_offset_px");
    app.gl_u_layer_origin_x = gl.glGetUniformLocation(prog, "u_layer_origin_x_px");
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
    gl.glEnableVertexAttribArray(4);
    gl.glVertexAttribPointer(4, 1, gl.GL_FLOAT, gl.GL_FALSE, stride, @ptrFromInt(@offsetOf(core.Vertex, "deco_phase")));

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
    // On atlas create, or a context realized again (gl_atlas_w reset to 0),
    // the texture is rebuilt from the full mirror, which already holds every
    // queued upload.
    if (ops.recreate or (ops.w != 0 and (app.gl_atlas_w != ops.w or app.gl_atlas_h != ops.h))) {
        if (ops.w != 0 and ops.h != 0) {
            gl.glTexImage2D(gl.GL_TEXTURE_2D, 0, gl.GL_RGBA8, @intCast(ops.w), @intCast(ops.h), 0, gl.GL_RGBA, gl.GL_UNSIGNED_BYTE, ops.mirror.items.ptr);
            app.gl_atlas_w = ops.w;
            app.gl_atlas_h = ops.h;
            ops.clearQueued();
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

/// Uploads `verts` into the persistent VBO and draws them as triangles,
/// scrollable content `scroll_offset_px` lower.
fn drawVerts(app: *App, verts: []const core.Vertex, layer: core.Layer, scroll_offset_px: f32) void {
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
    gl.glUniform1f(app.gl_u_scroll_offset, scroll_offset_px);
    gl.glUniform1f(app.gl_u_layer_origin_x, @floatFromInt(layer.x_px));
    gl.glDrawArrays(gl.GL_TRIANGLES, 0, @intCast(verts.len));
}

/// Clips to rows [row_start, row_end) of `layer`, in GL's bottom-left origin.
fn scissorRows(app: *const App, layer: core.Layer, row_start: u32, row_end: u32) void {
    const h: i32 = @intCast(app.cell_h_px);
    const top = layer.y_px + @as(i32, @intCast(row_start)) * h;
    const bottom = layer.y_px + @as(i32, @intCast(row_end)) * h;
    gl.glScissor(
        layer.x_px,
        @as(i32, @intCast(app.drawable_h_px)) - bottom,
        @intCast(layer.cols * app.cell_w_px),
        @max(0, bottom - top),
    );
}

/// Appends rows [start, end) to the scratch buffer.
fn gatherRows(app: *App, rows: []const Row, start: usize, end: usize) void {
    for (rows[start..end]) |row| {
        app.gl_scratch.appendSlice(app.alloc, row.verts.items) catch break;
    }
}

/// Draws one layer's committed rows. An eased grid's scroll region is drawn
/// apart, under its own scissor, at the ease offset together with the rows
/// it scrolled out, so the band the offset opens is filled and nothing moves
/// into the margins around it. Returns the vertex count drawn.
fn drawLayer(app: *App, layer: core.Layer, grid: *const GridRows, region: [2]u32, offset_px: f32) usize {
    const rows = grid.committedRows();
    const r0: usize = @min(region[0], rows.len);
    const r1: usize = @min(region[1], rows.len);
    var total: usize = 0;

    app.gl_scratch.clearRetainingCapacity();
    gatherRows(app, rows, 0, r0);
    gatherRows(app, rows, r1, rows.len);
    total += app.gl_scratch.items.len;
    drawVerts(app, app.gl_scratch.items, layer, 0);
    if (r0 == r1) return total;

    app.gl_scratch.clearRetainingCapacity();
    gatherRows(app, rows, r0, r1);
    for (grid.retainedRows()) |r| {
        if (!r.live) continue;
        app.gl_scratch.appendSlice(app.alloc, r.verts.items) catch break;
    }
    total += app.gl_scratch.items.len;
    gl.glEnable(gl.GL_SCISSOR_TEST);
    scissorRows(app, layer, @intCast(r0), @intCast(r1));
    drawVerts(app, app.gl_scratch.items, layer, offset_px);
    gl.glDisable(gl.GL_SCISSOR_TEST);
    return total;
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
    var any_moving = false;
    const now_ns: i64 = @intCast(t0);
    const layers = app.surface.committedLayers();
    // The core sends layers back-to-front; draw in order (windows/app.zig:4432).
    for (layers) |layer| {
        const grid = app.surface.committedGrid(layer.grid_id) orelse continue;
        const ease = app.surface.gridEase(layer.grid_id).?;
        ease.plan(now_ns, app.cell_h_px, grid.committedRows().len);
        if (ease.moving()) any_moving = true;
        verts_total += drawLayer(app, layer, grid, ease.region(), ease.offset_px);
    }
    const cur = app.surface.committedCursor();
    if (cur.verts.len != 0) {
        for (layers) |layer| {
            if (layer.grid_id != cur.grid_id) continue;
            verts_total += cur.verts.len;
            // The cursor rides its grid's ease, clipped like the region.
            const ease = app.surface.gridEase(layer.grid_id);
            const region: [2]u32 = if (ease) |e| e.region() else .{ 0, 0 };
            if (region[0] != region[1]) {
                gl.glEnable(gl.GL_SCISSOR_TEST);
                scissorRows(app, layer, region[0], region[1]);
            }
            drawVerts(app, cur.verts, layer, if (ease) |e| e.offset_px else 0);
            gl.glDisable(gl.GL_SCISSOR_TEST);
            break;
        }
    }
    verts_total += drawOverlays(app);
    if (any_moving) startEaseTick(app);

    if (applog.isEnabled()) {
        const us = @divTrunc(clock.nowNs() - t0, 1000);
        applog.appLog("[perf] linux_render us={d} layers={d} verts={d} easing={}\n", .{ us, layers.len, verts_total, any_moving });
    }
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
fn pushRect(app: *App, x: i32, y: i32, w: i32, h: i32, color: [4]f32) void {
    const x0: f32 = @floatFromInt(x);
    const y0: f32 = @floatFromInt(y);
    const x1: f32 = @floatFromInt(x + w);
    const y1: f32 = @floatFromInt(y + h);
    const corners = [_][2]f32{ .{ x0, y0 }, .{ x1, y0 }, .{ x0, y1 }, .{ x1, y0 }, .{ x1, y1 }, .{ x0, y1 } };
    for (corners) |p| {
        app.gl_scratch.append(app.alloc, .{
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
fn drawOverlays(app: *App) usize {
    const scale: i32 = @intFromFloat(app.scale);
    const rects = overlay_layout.place(&app.overlays, .{
        .main_w_px = @intCast(app.drawable_w_px),
        .main_h_px = @intCast(app.drawable_h_px),
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
        app.gl_scratch.clearRetainingCapacity();
        pushRect(app, r.x - scale, r.y - scale, r.w + 2 * scale, r.h + 2 * scale, border);
        pushRect(app, r.x, r.y, r.w, r.h, fill);
        drawVerts(app, app.gl_scratch.items, surface_layer, 0);

        // A cmdline wider than the window is clipped to its panel.
        gl.glEnable(gl.GL_SCISSOR_TEST);
        gl.glScissor(r.x, @as(i32, @intCast(app.drawable_h_px)) - r.y - r.h, r.w, r.h);
        const pad = overlay_layout.paddingPx(kind, scale);
        for (layers) |layer| {
            var placed = layer;
            placed.x_px += r.x + pad;
            placed.y_px += r.y + pad;
            if (app.surface.committedGrid(layer.grid_id)) |grid| total += drawLayer(app, placed, grid, .{ 0, 0 }, 0);
            if (cur.verts.len != 0 and cur.grid_id == layer.grid_id) {
                total += cur.verts.len;
                drawVerts(app, cur.verts, placed, 0);
            }
        }
        gl.glDisable(gl.GL_SCISSOR_TEST);
    }
    return total;
}

/// Redraws on every frame-clock tick while some grid eases; the render that
/// finds every ease at rest lets the callback remove itself.
fn startEaseTick(app: *App) void {
    if (app.ease_tick_active) return;
    const area = app.gl_area orelse return;
    app.ease_tick_active = true;
    _ = gtk.gtk_widget_add_tick_callback(area, &onEaseTick, app, null);
}

fn onEaseTick(widget: ?*anyopaque, frame_clock: ?*anyopaque, data: ?*anyopaque) callconv(.c) c_int {
    _ = frame_clock;
    const app: *App = @ptrCast(@alignCast(data.?));
    gtk.gtk_gl_area_queue_render(widget.?);
    app.mu.lockUncancelable(clock.io());
    defer app.mu.unlock(clock.io());
    var moving = false;
    for (app.surface.committedLayers()) |layer| {
        const e = app.surface.gridEase(layer.grid_id) orelse continue;
        if (e.moving()) moving = true;
    }
    if (!moving) app.ease_tick_active = false;
    return @intFromBool(moving);
}
