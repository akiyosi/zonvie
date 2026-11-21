//! OpenGL 3.3 painter for the committed surface snapshot. Runs on the main
//! thread with the window's EGL context current and its framebuffer bound
//! (wl/window.c). The window owns a Target: its GL objects.

const std = @import("std");
const core = @import("zonvie_core");
const clock = core.clock;
const gl = @import("../gl.zig");
const App = @import("../app.zig").App;
const transform = @import("../transform.zig");
const applog = @import("../app_log.zig");
const ui = @import("../ui.zig");
const ui_layer = @import("../ui_layer.zig");
const surface_store = @import("../surface_store.zig");
const GridRows = surface_store.GridRows;
const Row = surface_store.Row;
const overlay_layout = @import("../overlay_layout.zig");
const rules = core.frontend_rules;
const postfx = @import("postfx.zig");
const scrollbar = @import("../scrollbar.zig");
const layer_geom = @import("../layer_geom.zig");
const chrome = @import("../ui.zig").chrome;
const frame_damage = @import("../frame_damage.zig");
const Band = frame_damage.Band;

const shader_src = @embedFile("../shaders/main.glsl");
const initial_vbo_bytes: usize = 64 * 1024;

/// One window's GL objects, valid between realize and unrealize, and the
/// size it draws at (device px), set before each draw.
pub const Target = struct {
    /// Where this view sits in the window's framebuffer: its top-left, in
    /// px from the framebuffer's top-left, and the framebuffer's size. All 0
    /// while the target is a framebuffer of the view's own size (an FBO).
    ox_px: i32 = 0,
    oy_px: i32 = 0,
    fb_w_px: u32 = 0,
    fb_h_px: u32 = 0,
    /// The UI layer's atlas (ui_layer.zig) and the Atlas.gen it holds.
    ui_tex: u32 = 0,
    ui_gen: u64 = 0,
    program: u32 = 0,
    vao: u32 = 0,
    vbo: u32 = 0,
    vbo_cap_bytes: usize = 0,
    /// The pipeline has drawn once (renderMain).
    warmed: bool = false,
    u_scale: i32 = -1,
    u_offset: i32 = -1,
    u_scroll_offset: i32 = -1,
    u_layer_origin_x: i32 = -1,
    u_separator_fade: i32 = -1,
    u_mode: i32 = -1,
    u_clear_bg: i32 = -1,
    w_px: u32 = 0,
    h_px: u32 = 0,
    /// Row 0 of the framebuffer is the image's top. A window's framebuffer
    /// is bottom-up, so this stays false.
    flip_y: bool = false,
    /// Framebuffer px per surface px: 0.5 while the bloom extracts into its
    /// half-resolution texture, so scissors land on the same content.
    px_scale: f32 = 1,
    /// A `@zonvie-owns-cursor` shader draws the cursor over this frame
    /// (postfx.renderFrame): the native cursor pass is skipped.
    skip_cursor: bool = false,
    /// The iBelowFloats pass (postfx.renderFrame): win_float_pos layers
    /// (FLOAT without MSG) are not drawn, and the eases this frame's scene
    /// pass planned are reused rather than planned again.
    skip_floats: bool = false,
    /// One layer's rows concatenated for a single upload; capacity reused
    /// across frames.
    scratch: std.ArrayListUnmanaged(core.Vertex) = .empty,
    /// Set while a partial frame repaints one band: every scissor is cut to
    /// `clip` (framebuffer px, top-down: x0, y0, x1, y1), and each layer
    /// draws only its rows that meet `band` (view px).
    clip: ?[4]i32 = null,
    band: ?Band = null,
    /// The main view's frames so far, for its back buffer's age.
    history: frame_damage.History = .{},
    /// What the last main frame drew besides committed rows (frameKey);
    /// another value draws the frame whole.
    last_key: u64 = 0,
    /// Where the last main frame drew the cursor, view px; null for nowhere.
    last_cursor: ?Band = null,
    /// A partial frame's bands: those it changed, and those it repaints
    /// (those, and what the back buffer missed).
    own_bands: [frame_damage.max_bands]Band = undefined,
    draw_bands: [frame_damage.max_bands]Band = undefined,
    /// The swap's damage, x, y, w, h in buffer px from the bottom-left.
    swap_rects: [frame_damage.max_bands][4]i32 = undefined,

    pub fn deinit(self: *Target, alloc: std.mem.Allocator) void {
        self.scratch.deinit(alloc);
    }
};

/// The glyph atlas texture (App.glyph_tex). Every window draws with the one
/// EGL context (wl/window.c), so all targets sample this texture and
/// AtlasOps.uploads has a single consumer, syncAtlas. It lives as long as
/// that context.
pub const GlyphTexture = struct {
    tex: u32 = 0,
    /// Size the texture was allocated at; 0 until it holds the atlas.
    w: u32 = 0,
    h: u32 = 0,
    /// Rows of the texture, from the top, that hold the mirror's pixels;
    /// the rest has storage only.
    rows: u32 = 0,
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
    t.u_separator_fade = gl.glGetUniformLocation(prog, "u_separator_fade_px");
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

    gl.glGenTextures(1, &t.ui_tex);
    gl.glBindTexture(gl.GL_TEXTURE_2D, t.ui_tex);
    gl.glTexParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_MIN_FILTER, gl.GL_NEAREST);
    gl.glTexParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_MAG_FILTER, gl.GL_NEAREST);
    return true;
}

pub fn unrealize(t: *Target) void {
    if (t.ui_tex != 0) gl.glDeleteTextures(1, &t.ui_tex);
    if (t.vbo != 0) gl.glDeleteBuffers(1, &t.vbo);
    if (t.vao != 0) gl.glDeleteVertexArrays(1, &t.vao);
    if (t.program != 0) gl.glDeleteProgram(t.program);
    const w = t.w_px;
    const h = t.h_px;
    const flip = t.flip_y;
    const scratch = t.scratch;
    t.* = .{ .w_px = w, .h_px = h, .flip_y = flip, .scratch = scratch };
}

/// Binds the glyph atlas texture to unit 0 with the queued uploads applied,
/// for whichever window draws first. Caller holds App.mu.
fn syncAtlas(app: *App) void {
    const ops = &app.atlas_pending;
    const g = &app.glyph_tex;
    gl.glActiveTexture(gl.GL_TEXTURE0);
    if (g.tex == 0) {
        gl.glGenTextures(1, &g.tex);
        gl.glBindTexture(gl.GL_TEXTURE_2D, g.tex);
        // Point sampling and clamp, as the D3D11 atlas sampler.
        gl.glTexParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_MIN_FILTER, gl.GL_NEAREST);
        gl.glTexParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_MAG_FILTER, gl.GL_NEAREST);
        gl.glTexParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_WRAP_S, gl.GL_CLAMP_TO_EDGE);
        gl.glTexParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_WRAP_T, gl.GL_CLAMP_TO_EDGE);
    }
    gl.glBindTexture(gl.GL_TEXTURE_2D, g.tex);
    // The committed rows still sample the atlas being replaced
    // (AtlasOps.held). A texture without storage has nothing to keep.
    if (ops.held and g.w != 0) return;
    gl.glPixelStorei(gl.GL_UNPACK_ALIGNMENT, 1);
    // On atlas create, or a texture without storage yet, the texture gets
    // new storage and no pixels: the rows the mirror has glyphs in follow
    // below, and no glyph samples a row past them.
    if (ops.recreate or (ops.w != 0 and (g.w != ops.w or g.h != ops.h))) {
        if (ops.w != 0 and ops.h != 0) {
            gl.glTexImage2D(gl.GL_TEXTURE_2D, 0, gl.GL_RGBA8, @intCast(ops.w), @intCast(ops.h), 0, gl.GL_RGBA, gl.GL_UNSIGNED_BYTE, null);
            g.w = ops.w;
            g.h = ops.h;
            g.rows = 0;
            ops.clearQueued();
        }
        ops.recreate = false;
    }
    if (g.w != 0) {
        // Rows the uploads reached for the first time come whole from the
        // mirror, which already holds those uploads and is zero around them;
        // one row more is the last glyph row's padding.
        const first_new_row = g.rows;
        const rows = if (ops.dirty_rows == 0) 0 else @min(ops.h, ops.dirty_rows + 1);
        if (rows > first_new_row) {
            const stride = @as(usize, ops.w) * 4;
            gl.glTexSubImage2D(gl.GL_TEXTURE_2D, 0, 0, @intCast(first_new_row), @intCast(ops.w), @intCast(rows - first_new_row), gl.GL_RGBA, gl.GL_UNSIGNED_BYTE, ops.mirror[stride * first_new_row ..].ptr);
            g.rows = rows;
        }
        for (ops.uploads.items) |u| {
            if (u.y >= first_new_row) continue;
            gl.glTexSubImage2D(gl.GL_TEXTURE_2D, 0, @intCast(u.x), @intCast(u.y), @intCast(u.w), @intCast(u.h), gl.GL_RGBA, gl.GL_UNSIGNED_BYTE, ops.pixels.items[u.offset..].ptr);
        }
        ops.clearQueued();
    }
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
    // Separators are the root grid's, which only the main view holds.
    const fade_px = if (layer.grid_id == 1) layer_geom.separatorFadePx(app.captionless(), chrome.band_pt, app.scale) else 0;
    gl.glUniform1f(t.u_separator_fade, fade_px);
    gl.glDrawArrays(gl.GL_TRIANGLES, 0, @intCast(verts.len));
}

/// Clips to a rect given top-down in surface px, within the band a partial
/// frame repaints.
fn scissor(t: *const Target, x: i32, top: i32, w: i32, h: i32) void {
    var x0 = x + t.ox_px;
    var y0 = top + t.oy_px;
    var x1 = x0 + w;
    var y1 = y0 + @max(0, h);
    if (t.clip) |c| {
        x0 = @max(x0, c[0]);
        y0 = @max(y0, c[1]);
        x1 = @max(x0, @min(x1, c[2]));
        y1 = @max(y0, @min(y1, c[3]));
    }
    // Bottom-up in the framebuffer, which the view may be a part of.
    const fb_h: i32 = @intCast(if (t.fb_h_px != 0) t.fb_h_px else t.h_px);
    const y = if (t.flip_y) y0 else fb_h - y1;
    const s = t.px_scale;
    const f = struct {
        fn px(v: i32, k: f32) i32 {
            return @intFromFloat(@round(@as(f32, @floatFromInt(v)) * k));
        }
    }.px;
    gl.glScissor(f(x0, s), f(y, s), f(x1 - x0, s), f(y1 - y0, s));
}

/// Ends a clip `scissor` set: back to the band a partial frame repaints, or
/// none.
fn endScissor(t: *const Target) void {
    const c = t.clip orelse return gl.glDisable(gl.GL_SCISSOR_TEST);
    gl.glEnable(gl.GL_SCISSOR_TEST);
    scissor(t, c[0] - t.ox_px, c[1] - t.oy_px, c[2] - c[0], c[3] - c[1]);
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

/// Rows [start, end) of `layer`'s `len` that the band being repainted
/// reaches (damage_bands.layerRowsForBand); all of them outside a partial
/// frame.
fn bandRows(app: *const App, t: *const Target, layer: core.Layer, len: usize) [2]usize {
    const b = t.band orelse return .{ 0, len };
    const g = layerGeom(app, layer);
    const r = core.damage_bands.layerRowsForBand(b, layer.y_px, @intCast(len), @intCast(g.row_h_px)) orelse return .{ 0, 0 };
    return .{ r[0], r[1] + 1 };
}

/// Appends rows [start, end) to the target's scratch buffer; none when the
/// range is empty.
fn gatherRows(app: *App, t: *Target, rows: []const Row, start: usize, end: usize) void {
    if (start >= end) return;
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
    const span = bandRows(app, t, layer, rows.len);
    var total: usize = 0;
    const boxed = layerGeom(app, layer).extent != null;
    if (boxed) {
        gl.glEnable(gl.GL_SCISSOR_TEST);
        scissorRows(app, t, layer, 0, layer.rows);
    }
    defer if (boxed) endScissor(t);

    t.scratch.clearRetainingCapacity();
    gatherRows(app, t, rows, span[0], @min(r0, span[1]));
    gatherRows(app, t, rows, @max(r1, span[0]), span[1]);
    total += t.scratch.items.len;
    drawVerts(app, t, t.scratch.items, layer, 0);
    if (r0 == r1) return total;

    t.scratch.clearRetainingCapacity();
    gatherRows(app, t, rows, @max(r0, span[0]), @min(r1, span[1]));
    for (grid.retainedRows()) |r| {
        if (!r.live) continue;
        t.scratch.appendSlice(app.alloc, r.verts.items) catch break;
    }
    total += t.scratch.items.len;
    gl.glEnable(gl.GL_SCISSOR_TEST);
    scissorRows(app, t, layer, @intCast(r0), @intCast(r1));
    drawVerts(app, t, t.scratch.items, layer, offset_px);
    endScissor(t);
    return total;
}

/// The view's rectangle in the framebuffer it is drawn into.
pub fn viewport(t: *const Target) void {
    const fb_h: i32 = @intCast(if (t.fb_h_px != 0) t.fb_h_px else t.h_px);
    gl.glViewport(t.ox_px, fb_h - t.oy_px - @as(i32, @intCast(t.h_px)), @intCast(t.w_px), @intCast(t.h_px));
}

/// Clears the target and binds its pipeline. False when there is nothing to
/// draw with yet.
fn begin(app: *App, t: *Target) bool {
    viewport(t);
    // The clear takes the view alone: the window around it is the UI
    // layer's (drawUi).
    gl.glEnable(gl.GL_SCISSOR_TEST);
    scissor(t, 0, 0, @intCast(t.w_px), @intCast(t.h_px));
    defer endScissor(t);
    clearToBg(app);
    return bind(app, t);
}

/// Clears what the scissor leaves to the editor's background. Caller holds
/// App.mu.
fn clearToBg(app: *const App) void {
    const bg = app.default_bg;
    // Premultiplied: [window] opacity is the background's alpha, as Windows
    // clears its swapchain.
    const a = std.math.clamp(app.window_cfg.opacity, 0, 1);
    gl.glClearColor(
        @as(f32, @floatFromInt((bg >> 16) & 0xff)) / 255.0 * a,
        @as(f32, @floatFromInt((bg >> 8) & 0xff)) / 255.0 * a,
        @as(f32, @floatFromInt(bg & 0xff)) / 255.0 * a,
        a,
    );
    gl.glClear(gl.GL_COLOR_BUFFER_BIT);
}

/// The editor card's padding (App.island): the editor's background around
/// the view, cleared as the view is. The UI layer paints only what lies
/// outside the card and its corners. Takes App.mu.
fn clearCardPadding(app: *App, t: *const Target) void {
    const pad = chrome.cardPaddingPx(app);
    app.mu.lockUncancelable(clock.io());
    defer app.mu.unlock(clock.io());
    gl.glEnable(gl.GL_SCISSOR_TEST);
    defer gl.glDisable(gl.GL_SCISSOR_TEST);
    scissor(t, -pad, -pad, @as(i32, @intCast(t.w_px)) + 2 * pad, @as(i32, @intCast(t.h_px)) + 2 * pad);
    clearToBg(app);
}

/// Binds the target's pipeline over what the caller cleared. False when
/// there is nothing to draw with yet.
fn bind(app: *const App, t: *Target) bool {
    if (app.glyph_tex.w == 0 or t.w_px == 0 or t.h_px == 0) return false;
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
        endScissor(t);
    }
    // The core sends layers back-to-front; draw in order (windows/app.zig:4432).
    for (layers) |layer| {
        if (t.skip_floats and layer.flags & core.LAYER_FLOAT != 0 and layer.flags & core.LAYER_MSG == 0) continue;
        const grid = app.surface.committedGrid(layer.grid_id) orelse continue;
        const ease = app.surface.gridEase(layer.grid_id).?;
        if (!t.skip_floats) ease.plan(now_ns, layerGeom(app, layer).row_h_px, grid.committedRows().len);
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
        endScissor(t);
        break;
    }
    return out;
}

pub const Frame = struct {
    /// Some grid eases: the caller keeps frames coming (startEaseTick).
    moving: bool = false,
};

/// The main surface and its overlays into `t`, sized `t.w_px` x `t.h_px`.
/// Takes App.mu. The thread with `t`'s context current.
pub fn renderMain(app: *App, t: *Target) Frame {
    if (t.program == 0) return .{};
    const t0 = clock.nowNs();
    app.mu.lockUncancelable(clock.io());
    defer app.mu.unlock(clock.io());
    return renderMainLocked(app, t, t0);
}

/// renderMain with App.mu held by the caller (postfx.renderFrame, which
/// snapshots the shader inputs under the same hold).
pub fn renderMainLocked(app: *App, t: *Target, t0: i128) Frame {
    if (t.program == 0) return .{};
    syncAtlas(app);
    if (!begin(app, t)) return .{};
    if (!t.warmed) {
        // A driver may finish compiling the program only at its first draw.
        // One zero-area triangle makes that happen in the frame before
        // Neovim's first one, which is empty, instead of delaying its content.
        t.warmed = true;
        const zero: [3 * @sizeOf(core.Vertex)]u8 = @splat(0);
        gl.glBufferSubData(gl.GL_ARRAY_BUFFER, 0, zero.len, &zero);
        gl.glDrawArrays(gl.GL_TRIANGLES, 0, 3);
    }

    const layers = app.surface.committedLayers();
    const d = drawSurface(app, t, layers, @intCast(t0));
    drawScrollbar(app, t, &app.scrollbar, 1);
    const overlay_verts = drawOverlays(app, t, 1);

    if (applog.isEnabled()) {
        const us = @divTrunc(clock.nowNs() - t0, 1000);
        applog.appLog("[perf] linux_render us={d} layers={d} verts={d} easing={}\n", .{ us, layers.len, d.verts + overlay_verts, d.moving });
    }
    return .{ .moving = d.moving };
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
    gl.glBindTexture(gl.GL_TEXTURE_2D, app.glyph_tex.tex);
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

/// What a main frame hands the swap.
pub const Swap = struct {
    /// Nothing on the window changed: there is no buffer to present.
    skip: bool = false,
    /// The rects the frame changed (Target.swap_rects); empty for all.
    rects: []const [4]i32 = &.{},
};

/// One frame of the main window (main.zig draw), into a back buffer that
/// holds the frame drawn `buffer_age` frames ago (0: unknown contents).
pub fn render(app: *App, buffer_age: u32) Swap {
    const t = &app.gl;
    t.w_px = app.drawable_w_px;
    t.h_px = app.drawable_h_px;
    t.ox_px = app.view_x_px;
    t.oy_px = app.view_y_px;
    t.fb_w_px = if (app.win_w_px != 0) app.win_w_px else t.w_px;
    t.fb_h_px = if (app.win_h_px != 0) app.win_h_px else t.h_px;
    const fx = postfx.active(app, &app.postfx);
    var out: Swap = .{};
    switch (planFrame(app, t, fx, buffer_age)) {
        .whole => |own| {
            if (app.island()) clearCardPadding(app, t);
            const f = if (fx) postfx.renderFrame(app, t, &app.postfx, 1) else renderMain(app, t);
            drawUi(app, t);
            // Drawn whole for a buffer that missed more, it still changed
            // only its own bands.
            if (own) |n| {
                t.history.pushBands(t.own_bands[0..n]);
                out.rects = swapRects(t, n);
            } else t.history.pushFull();
            if (app.test_full_redraw) {
                app.test_full_redraw = false;
                applog.appLog("[trace] event=full_frame_done surface=1\n", .{});
            }
            if (f.moving or app.postfx.animating) startEaseTick(app);
        },
        .none => out.skip = true,
        .bands => |n| {
            // Each band is the whole frame clipped to it: the view's rows
            // across its width, the panels and the UI layer over them.
            var moving = false;
            for (t.draw_bands[0..n.draw]) |b| {
                t.band = b;
                t.clip = .{ t.ox_px, t.oy_px + b.top_px, t.ox_px + @as(i32, @intCast(t.w_px)), t.oy_px + b.bottom_px };
                endScissor(t);
                if (renderMain(app, t).moving) moving = true;
                drawUi(app, t);
            }
            t.band = null;
            t.clip = null;
            gl.glDisable(gl.GL_SCISSOR_TEST);
            t.history.pushBands(t.own_bands[0..n.own]);
            out.rects = swapRects(t, n.own);
            if (applog.isEnabled()) applog.appLog("[trace] event=partial_frame own={d} drawn={d} age={d}\n", .{ n.own, n.draw, buffer_age });
            // A commit between the plan and the draw may start a scroll.
            if (moving) startEaseTick(app);
        },
    }
    if (applog.isEnabled()) applog.appLog("[trace] event=frame_done surface=1\n", .{});
    return out;
}

/// The first `n` own bands as the swap's damage.
fn swapRects(t: *Target, n: usize) []const [4]i32 {
    const fb_h: i32 = @intCast(t.fb_h_px);
    for (t.own_bands[0..n], 0..) |b, i| {
        t.swap_rects[i] = .{ t.ox_px, fb_h - (t.oy_px + b.bottom_px), @intCast(t.w_px), b.bottom_px - b.top_px };
    }
    return t.swap_rects[0..n];
}

const Plan = union(enum) {
    /// The count of Target.own_bands when the frame changed only those,
    /// and is drawn whole for a back buffer that missed more.
    whole: ?usize,
    /// Nothing changed since the last frame.
    none,
    /// Counts of Target.own_bands and Target.draw_bands.
    bands: struct { own: usize, draw: usize },
};

/// Whether this main frame repaints the whole window or bands of the view:
/// the rows the commits since the last frame sent and the cursor's moves,
/// joined with what the back buffer missed. Anything else that changed what
/// the frame draws draws it whole. Takes App.mu.
fn planFrame(app: *App, t: *Target, fx: bool, buffer_age: u32) Plan {
    app.mu.lockUncancelable(clock.io());
    defer app.mu.unlock(clock.io());
    var owed = app.surface.damage.take();
    const cur = cursorBand(app, t);
    if (app.surface.cursor_changed or !std.meta.eql(cur, t.last_cursor)) {
        if (t.last_cursor) |b| owed.add(b.top_px, b.bottom_px);
        if (cur) |b| owed.add(b.top_px, b.bottom_px);
    }
    app.surface.cursor_changed = false;
    t.last_cursor = cur;
    const key = frameKey(app, t, fx);
    const key_changed = key != t.last_key;
    t.last_key = key;
    if (owed.full or key_changed or fx or app.test_full_redraw or t.program == 0 or app.glyph_tex.w == 0) return .{ .whole = null };
    // A scroll moves rows no commit sends, and so does the frame that ends it.
    for (app.surface.committedLayers()) |l| {
        const e = app.surface.gridEase(l.grid_id) orelse continue;
        if (e.easing or e.moving() or e.offset_px != 0) return .{ .whole = null };
    }
    // A panel over the view changes with no row of the view.
    if (!app.panel_popups) for (app.overlays) |o| if (o.open) return .{ .whole = null };
    if (owed.isEmpty()) return .none;
    const row_h: i32 = @intCast(app.cell_h_px);
    const h: i32 = @intCast(t.h_px);
    const own = core.damage_bands.bands(owed.spans[0..owed.n], row_h, h, &t.own_bands);
    if (own == 0) return .none;
    if (!t.history.catchUp(buffer_age, &owed)) return .{ .whole = own };
    const draw = core.damage_bands.bands(owed.spans[0..owed.n], row_h, h, &t.draw_bands);
    return .{ .bands = .{ .own = own, .draw = draw } };
}

/// Where the main view draws the cursor this frame, view px; null for
/// nowhere. Caller holds App.mu.
fn cursorBand(app: *App, t: *const Target) ?Band {
    const cur = app.surface.committedCursor();
    if (cur.verts.len == 0 or !app.cursor_blink.visible or t.skip_cursor) return null;
    const layers = app.surface.committedLayers();
    for (layers) |placed| {
        if (placed.grid_id != cur.grid_id) continue;
        const layer = followed(app, placed, layers);
        var lo: f32 = std.math.inf(f32);
        var hi: f32 = -std.math.inf(f32);
        for (cur.verts) |v| {
            lo = @min(lo, v.position[1]);
            hi = @max(hi, v.position[1]);
        }
        return .{ .top_px = layer.y_px + @as(i32, @intFromFloat(@floor(lo))), .bottom_px = layer.y_px + @as(i32, @intFromFloat(@ceil(hi))) };
    }
    return null;
}

/// What the main frame draws besides the committed rows, the cursor and the
/// panels: the frame is drawn whole when it differs from the last frame's.
/// Caller holds App.mu.
fn frameKey(app: *App, t: *const Target, fx: bool) u64 {
    var h = std.hash.Wyhash.init(0);
    const sb = scrollbar.drawn(app, &app.scrollbar, 1);
    const view = sb orelse surface_store.ScrollView{ .topline = 0, .botline = 0, .line_count = 0 };
    const parts = .{
        t.w_px,                     t.h_px,                  t.ox_px,              t.oy_px,        t.fb_w_px,        t.fb_h_px,
        app.cell_w_px,              app.cell_h_px,           app.scale,            app.island(),   app.captionless(), app.default_bg,
        app.window_cfg.opacity,     app.window_cfg.blur,     fx,                   app.panel_popups,
        // The UI layer and the textures the frame samples.
        app.chrome_gen,             app.ui_atlas.gen,        app.atlas_pending.gen,
        sb != null,                 view.grid,               view.topline,         view.botline,   view.line_count,  app.scrollbar.alpha,
    };
    inline for (parts) |v| {
        const x = v;
        h.update(std.mem.asBytes(&x));
    }
    return h.final();
}

/// The UI layer over the whole window: its solid quads, then its text from
/// its own atlas. Takes App.mu. The window's context current.
fn drawUi(app: *App, t: *Target) void {
    drawUiAt(app, t, t.fb_w_px, t.fb_h_px, 0, 0);
}

/// The main window's UI layer into a surface whose top-left is (x_px, y_px)
/// of that window (a panel's popup): what of the layer lies over it.
pub fn drawUiShifted(app: *App, t: *Target, x_px: i32, y_px: i32) void {
    drawUiAt(app, t, app.win_w_px, app.win_h_px, -x_px, -y_px);
}

/// The layer, laid out for a window of win_w x win_h px, with that window's
/// top-left at (ox, oy) of the target's framebuffer.
fn drawUiAt(app: *App, t: *Target, win_w: u32, win_h: u32, ox: i32, oy: i32) void {
    if (t.program == 0 or win_w == 0 or win_h == 0 or t.fb_h_px == 0) return;
    app.mu.lockUncancelable(clock.io());
    defer app.mu.unlock(clock.io());
    const layer = &app.chrome_layer;
    if (layer.solid.items.len == 0 and layer.text.items.len == 0) return;
    // The window is the target for this pass.
    const view = .{ t.w_px, t.h_px, t.ox_px, t.oy_px };
    t.w_px = win_w;
    t.h_px = win_h;
    t.ox_px = ox;
    t.oy_px = oy;
    defer {
        t.w_px = view[0];
        t.h_px = view[1];
        t.ox_px = view[2];
        t.oy_px = view[3];
    }
    viewport(t);
    gl.glUseProgram(t.program);
    gl.glUniform1i(t.u_mode, 0);
    gl.glBindVertexArray(t.vao);
    gl.glBindBuffer(gl.GL_ARRAY_BUFFER, t.vbo);
    gl.glEnable(gl.GL_BLEND);
    gl.glBlendFunc(gl.GL_ONE, gl.GL_ONE_MINUS_SRC_ALPHA);
    endScissor(t);
    drawVerts(app, t, layer.solid.items, surface_layer, 0);
    if (layer.round.items.len != 0) {
        gl.glUniform1i(t.u_mode, 2);
        drawVerts(app, t, layer.round.items, surface_layer, 0);
        gl.glUniform1i(t.u_mode, 0);
    }
    if (layer.text.items.len == 0) return;
    const a = &app.ui_atlas;
    if (a.pixels.len == 0) return;
    gl.glActiveTexture(gl.GL_TEXTURE0);
    gl.glBindTexture(gl.GL_TEXTURE_2D, t.ui_tex);
    if (t.ui_gen != a.gen) {
        gl.glPixelStorei(gl.GL_UNPACK_ALIGNMENT, 1);
        gl.glTexImage2D(gl.GL_TEXTURE_2D, 0, gl.GL_RGBA8, ui_layer.atlas_size, ui_layer.atlas_size, 0, gl.GL_RGBA, gl.GL_UNSIGNED_BYTE, a.pixels.ptr);
        t.ui_gen = a.gen;
    }
    drawVerts(app, t, layer.text.items, surface_layer, 0);
    gl.glBindTexture(gl.GL_TEXTURE_2D, app.glyph_tex.tex);
}

/// An external window: the surface rooted at `surface_id`.
/// An external surface into `t`, with the panels anchored in it (a
/// popupmenu, message panels by msg_pos). Takes App.mu.
pub fn renderExternalScene(app: *App, t: *Target, surface_id: i64) Frame {
    if (t.program == 0) return .{};
    const t0 = clock.nowNs();
    app.mu.lockUncancelable(clock.io());
    defer app.mu.unlock(clock.io());
    return renderExternalSceneLocked(app, t, surface_id, t0);
}

/// renderExternalScene with App.mu held by the caller.
pub fn renderExternalSceneLocked(app: *App, t: *Target, surface_id: i64, t0: i128) Frame {
    if (t.program == 0) return .{};
    syncAtlas(app);
    if (!begin(app, t)) return .{};
    const d = drawSurface(app, t, app.surface.committedSurfaceLayers(surface_id), @intCast(t0));
    if (app.ext_windows.get(surface_id)) |w| drawScrollbar(app, t, &w.scrollbar, surface_id);
    _ = drawOverlays(app, t, surface_id);
    return .{ .moving = d.moving };
}

/// iBelowFloats into the bound framebuffer: the surface as this frame's
/// scene pass drew it, without win_float_pos layers, the cursor, the
/// scrollbar or the ext UI overlays. Runs after that pass in the same App.mu
/// hold, with `t.skip_floats` and `t.skip_cursor` set by the caller. False
/// when nothing could be drawn.
pub fn renderBelowFloatsLocked(app: *App, t: *Target, surface_id: i64) bool {
    if (t.program == 0 or !begin(app, t)) return false;
    const layers = if (surface_id == 1) app.surface.committedLayers() else app.surface.committedSurfaceLayers(surface_id);
    _ = drawSurface(app, t, layers, 0);
    return true;
}

/// The surface's scrollbar over its grids, under the ext UI overlays.
/// Caller holds App.mu.
fn drawScrollbar(app: *App, t: *Target, st: *const scrollbar.State, surface_id: i64) void {
    const vp = scrollbar.drawn(app, st, surface_id) orelse return;
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
/// True when a grid of it eases or its shader animates: the window draws
/// the frame after this one too.
pub fn renderExternal(app: *App, t: *Target, p: *postfx.PostFx, surface_id: i64) bool {
    const f = if (postfx.active(app, p))
        postfx.renderFrame(app, t, p, surface_id)
    else
        renderExternalScene(app, t, surface_id);
    if (applog.isEnabled()) applog.appLog("[trace] event=frame_done surface={d}\n", .{surface_id});
    return f.moving or p.animating;
}

/// A panel popup's render signal (panel_popup.zig): panel `kind` at
/// `inner` (target px) over a transparent clear, so its shadow falls on
/// whatever is under the popup; `view` is where the panel is on the main
/// view. Takes App.mu.
pub fn renderPanel(app: *App, t: *Target, kind: overlay_layout.Kind, inner: overlay_layout.Rect, view: overlay_layout.Rect) void {
    if (t.program == 0) return;
    app.mu.lockUncancelable(clock.io());
    defer app.mu.unlock(clock.io());
    syncAtlas(app);
    gl.glViewport(0, 0, @intCast(t.w_px), @intCast(t.h_px));
    gl.glClearColor(0, 0, 0, 0);
    gl.glClear(gl.GL_COLOR_BUFFER_BIT);
    if (!bind(app, t)) return;
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

/// The surface msg_pos `mode` hangs message boxes on
/// (overlay_layout.msgSurface). Caller holds App.mu.
pub fn msgSurface(app: *const App, mode: core.config.MsgPosition) i64 {
    return overlay_layout.msgSurface(mode, app.msg_anchor, app, surfaceOpen);
}

/// What places the ext UI panels on surface `surface_id` (1, the main view,
/// or an external window), `w_px` x `h_px`: the one answer for the panels
/// drawn here, the copy buttons over them (shell.zig buildCopyButtons) and
/// the pointer's hit tests. Caller holds App.mu.
pub fn overlayInputs(app: *const App, surface_id: i64, w_px: u32, h_px: u32) overlay_layout.Inputs {
    const w: i32 = @intCast(w_px);
    const h: i32 = @intCast(h_px);
    const cw: i32 = @intCast(app.cell_w_px);
    const ch: i32 = @intCast(app.cell_h_px);
    const main = surface_id == 1;
    const msg_surface = msgSurface(app, app.msg_pos.ext_float);
    // The cmdline goes where the keyboard is, as typing there opened it.
    const cmdline_surface = if (app.focus_surface != 1 and surfaceOpen(app, app.focus_surface)) app.focus_surface else 1;
    return .{
        .surface_id = surface_id,
        .main_w_px = w,
        .main_h_px = h,
        .cell_w_px = cw,
        .cell_h_px = ch,
        .scale = @intFromFloat(app.scale),
        .msg_target = overlay_layout.msgTargetOn(surface_id, app.msg_pos.ext_float, app.msg_anchor, w, h, cw, ch),
        .cmdline_surface = cmdline_surface,
        .pum_surface = overlay_layout.popupSurface(app.overlays[@intFromEnum(overlay_layout.Kind.popupmenu)], app, surfaceOpen),
        .msg_surface = msg_surface,
        // A copy button sits over the surface its panel is on: the
        // cmdline's the main view.
        .copy_cmdline = app.copy_cmdline and main,
        .copy_messages = app.copy_messages and surface_id == msg_surface,
        .confirm = if (main) app.confirm_rect else null,
        .cmdline_user = if (app.cmdline_user_surface == cmdline_surface) app.cmdline_user else null,
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
            if (cur.verts.len != 0 and cur.grid_id == layer.grid_id and app.cursor_blink.visible and !t.skip_cursor and
                overlay_layout.panelCursorShown(kind, app.ime_composing.load(.acquire)))
            {
                total += cur.verts.len;
                drawVerts(app, t, cur.verts, placed, 0);
            }
        }
        endScissor(t);
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

/// Some grid eases, or a shader animates: the window draws the frame after
/// this one too, and so on until a frame finds everything at rest. Called
/// from inside a draw. Main thread.
pub fn startEaseTick(app: *App) void {
    ui.window.keepFrames(app);
}
