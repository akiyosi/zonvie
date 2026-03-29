// gl_renderer.zig — OpenGL 4.5 renderer for Linux frontend.
//
// Manages GL state, shader compilation, VAO setup, atlas texture,
// glow FBOs, and per-frame rendering.
//
// Uses hand-written OpenGL bindings from linux/gl.zig (no @cImport).

const std = @import("std");
const app_mod = @import("../app.zig");
const App = app_mod.App;
const Vertex = app_mod.Vertex;
const gl = app_mod.gl;
const applog = app_mod.applog;
const shaders = @import("../shaders/compiled_shaders.zig");
const main_mod = @import("../main.zig");

// =========================================================================
// Shader compilation helpers
// =========================================================================

fn compileShader(shader_type: gl.GLenum, source: []const u8) ?gl.GLuint {
    const shader = gl.glCreateShader(shader_type);
    if (shader == 0) return null;

    const src_ptr: [*c]const gl.GLchar = @ptrCast(source.ptr);
    const src_len: gl.GLint = @intCast(source.len);
    gl.glShaderSource(shader, 1, &src_ptr, &src_len);
    gl.glCompileShader(shader);

    var status: gl.GLint = 0;
    gl.glGetShaderiv(shader, gl.GL_COMPILE_STATUS, &status);
    if (status == 0) {
        var log_buf: [4096]u8 = undefined;
        var log_len: gl.GLsizei = 0;
        gl.glGetShaderInfoLog(shader, log_buf.len, &log_len, &log_buf);
        if (log_len > 0) {
            const log_slice: []const u8 = log_buf[0..@intCast(log_len)];
            applog.appLog("[gl] Shader compile error: {s}\n", .{log_slice});
        }
        gl.glDeleteShader(shader);
        return null;
    }
    return shader;
}

fn linkProgram(vs: gl.GLuint, fs: gl.GLuint) ?gl.GLuint {
    const program = gl.glCreateProgram();
    if (program == 0) return null;

    gl.glAttachShader(program, vs);
    gl.glAttachShader(program, fs);
    gl.glLinkProgram(program);

    var status: gl.GLint = 0;
    gl.glGetProgramiv(program, gl.GL_LINK_STATUS, &status);
    if (status == 0) {
        var log_buf: [4096]u8 = undefined;
        var log_len: gl.GLsizei = 0;
        gl.glGetProgramInfoLog(program, log_buf.len, &log_len, &log_buf);
        if (log_len > 0) {
            const log_slice: []const u8 = log_buf[0..@intCast(log_len)];
            applog.appLog("[gl] Program link error: {s}\n", .{log_slice});
        }
        gl.glDeleteProgram(program);
        return null;
    }
    return program;
}

fn createProgram(vs_source: []const u8, fs_source: []const u8) ?gl.GLuint {
    const vs = compileShader(gl.GL_VERTEX_SHADER, vs_source) orelse return null;
    defer gl.glDeleteShader(vs);
    const fs = compileShader(gl.GL_FRAGMENT_SHADER, fs_source) orelse return null;
    defer gl.glDeleteShader(fs);
    return linkProgram(vs, fs);
}

// =========================================================================
// Initialization
// =========================================================================

/// Initialize all GL resources: shaders, VAO, atlas texture.
/// Called from GLArea "realize" signal (GL context is current).
pub fn init(app: *App) bool {
    if (applog.isEnabled()) applog.appLog("[gl] Initializing OpenGL renderer\n", .{});

    // Compile shader programs
    app.gl_program_main = createProgram(shaders.vs_main, shaders.fs_main) orelse {
        applog.appLog("[gl] Failed to create main shader program\n", .{});
        return false;
    };

    app.gl_program_glow_extract = createProgram(shaders.vs_main, shaders.fs_glow_extract) orelse {
        applog.appLog("[gl] Failed to create glow extract shader program\n", .{});
        return false;
    };

    app.gl_program_kawase_down = createProgram(shaders.vs_fullscreen, shaders.fs_kawase_down) orelse {
        applog.appLog("[gl] Failed to create kawase down shader program\n", .{});
        return false;
    };

    app.gl_program_kawase_up = createProgram(shaders.vs_fullscreen, shaders.fs_kawase_up) orelse {
        applog.appLog("[gl] Failed to create kawase up shader program\n", .{});
        return false;
    };

    app.gl_program_glow_composite = createProgram(shaders.vs_fullscreen, shaders.fs_glow_composite) orelse {
        applog.appLog("[gl] Failed to create glow composite shader program\n", .{});
        return false;
    };

    // Create VAO with vertex format matching zonvie_vertex
    gl.glGenVertexArrays(1, &app.gl_vao);
    gl.glBindVertexArray(app.gl_vao);

    // Vertex layout: matches sizeof(zonvie_vertex) = 48 bytes
    // location 0: vec2 position     (offset 0,  8 bytes)
    // location 1: vec2 texCoord     (offset 8,  8 bytes)
    // location 2: vec4 color        (offset 16, 16 bytes, aligned to 16)
    // location 3: ivec2 grid_id     (offset 32, 8 bytes, i64 as ivec2)
    // location 4: uint deco_flags   (offset 40, 4 bytes)
    // location 5: float deco_phase  (offset 44, 4 bytes)
    // stride: 48 bytes

    // Note: VAO attribute format will be set when VBOs are bound during rendering.
    // We define the format here but actual binding happens per-draw.

    gl.glBindVertexArray(0);

    if (applog.isEnabled()) applog.appLog("[gl] OpenGL renderer initialized\n", .{});
    return true;
}

/// Set up vertex attribute pointers for the current VBO.
/// Must be called with gl_vao bound and a VBO bound to GL_ARRAY_BUFFER.
pub fn setupVertexAttribs() void {
    const stride: gl.GLsizei = @sizeOf(Vertex);

    // location 0: vec2 position (offset 0)
    gl.glEnableVertexAttribArray(0);
    gl.glVertexAttribPointer(0, 2, gl.GL_FLOAT, gl.GL_FALSE, stride, @ptrFromInt(0));

    // location 1: vec2 texCoord (offset 8)
    gl.glEnableVertexAttribArray(1);
    gl.glVertexAttribPointer(1, 2, gl.GL_FLOAT, gl.GL_FALSE, stride, @ptrFromInt(8));

    // location 2: vec4 color (offset 16)
    gl.glEnableVertexAttribArray(2);
    gl.glVertexAttribPointer(2, 4, gl.GL_FLOAT, gl.GL_FALSE, stride, @ptrFromInt(16));

    // location 3: ivec2 grid_id (offset 32, i64 as ivec2)
    gl.glEnableVertexAttribArray(3);
    gl.glVertexAttribIPointer(3, 2, gl.GL_INT, stride, @ptrFromInt(32));

    // location 4: uint deco_flags (offset 40)
    gl.glEnableVertexAttribArray(4);
    gl.glVertexAttribIPointer(4, 1, gl.GL_UNSIGNED_INT, stride, @ptrFromInt(40));

    // location 5: float deco_phase (offset 44)
    gl.glEnableVertexAttribArray(5);
    gl.glVertexAttribPointer(5, 1, gl.GL_FLOAT, gl.GL_FALSE, stride, @ptrFromInt(44));
}

// =========================================================================
// Atlas texture management
// =========================================================================

/// Create or recreate the atlas texture at the given dimensions.
pub fn createAtlasTexture(app: *App, atlas_w: u32, atlas_h: u32) void {
    if (app.gl_atlas_texture != 0) {
        gl.glDeleteTextures(1, &app.gl_atlas_texture);
    }

    gl.glGenTextures(1, &app.gl_atlas_texture);
    gl.glBindTexture(gl.GL_TEXTURE_2D, app.gl_atlas_texture);
    gl.glTexImage2D(
        gl.GL_TEXTURE_2D,
        0,
        gl.GL_RGBA8,
        @intCast(atlas_w),
        @intCast(atlas_h),
        0,
        gl.GL_RGBA,
        gl.GL_UNSIGNED_BYTE,
        null, // cleared to zero
    );
    gl.glTexParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_MIN_FILTER, gl.GL_NEAREST);
    gl.glTexParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_MAG_FILTER, gl.GL_NEAREST);
    gl.glTexParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_WRAP_S, gl.GL_CLAMP_TO_EDGE);
    gl.glTexParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_WRAP_T, gl.GL_CLAMP_TO_EDGE);
    gl.glBindTexture(gl.GL_TEXTURE_2D, 0);

    app.atlas_w = atlas_w;
    app.atlas_h = atlas_h;

    if (applog.isEnabled()) applog.appLog("[gl] Created atlas texture {d}x{d}\n", .{ atlas_w, atlas_h });
}

/// Upload a glyph bitmap region to the atlas texture.
pub fn uploadAtlasRegion(
    app: *App,
    dest_x: u32,
    dest_y: u32,
    width: u32,
    height: u32,
    bitmap: *const app_mod.GlyphBitmap,
) void {
    if (app.gl_atlas_texture == 0) return;
    if (bitmap.pixels == null) return;
    if (width == 0 or height == 0) return;

    gl.glBindTexture(gl.GL_TEXTURE_2D, app.gl_atlas_texture);

    // Set unpack alignment based on bytes per pixel
    const bpp = bitmap.bytes_per_pixel;
    if (bpp == 1) {
        gl.glPixelStorei(gl.GL_UNPACK_ALIGNMENT, 1);
    } else {
        gl.glPixelStorei(gl.GL_UNPACK_ALIGNMENT, 4);
    }

    // Set row length for pitch != width * bpp
    const expected_pitch: i32 = @intCast(width * bpp);
    if (bitmap.pitch != expected_pitch and bitmap.pitch > 0) {
        gl.glPixelStorei(gl.GL_UNPACK_ROW_LENGTH, @divTrunc(bitmap.pitch, @as(i32, @intCast(bpp))));
    }

    const format: gl.GLenum = if (bpp == 1) gl.GL_RED else gl.GL_RGBA;

    gl.glTexSubImage2D(
        gl.GL_TEXTURE_2D,
        0,
        @intCast(dest_x),
        @intCast(dest_y),
        @intCast(width),
        @intCast(height),
        format,
        gl.GL_UNSIGNED_BYTE,
        bitmap.pixels,
    );

    // Reset unpack state
    gl.glPixelStorei(gl.GL_UNPACK_ROW_LENGTH, 0);
    gl.glPixelStorei(gl.GL_UNPACK_ALIGNMENT, 4);

    gl.glBindTexture(gl.GL_TEXTURE_2D, 0);
}

// =========================================================================
// Glow FBO management
// =========================================================================

/// Create glow pipeline FBOs and textures at the given resolution.
pub fn createGlowResources(app: *App, width: u32, height: u32) void {
    // Clean up existing
    destroyGlowResources(app);

    // Extract FBO at half resolution
    var half_w = @max(1, width / 2);
    var half_h = @max(1, height / 2);

    createFboWithTexture(&app.glow_extract_fbo, &app.glow_extract_tex, half_w, half_h);

    // Mip chain: 1/4, 1/8, 1/16
    for (0..3) |i| {
        half_w = @max(1, half_w / 2);
        half_h = @max(1, half_h / 2);
        createFboWithTexture(&app.glow_mip_fbo[i], &app.glow_mip_tex[i], half_w, half_h);
    }
}

fn createFboWithTexture(fbo: *u32, tex: *u32, w: u32, h: u32) void {
    gl.glGenTextures(1, tex);
    gl.glBindTexture(gl.GL_TEXTURE_2D, tex.*);
    gl.glTexImage2D(gl.GL_TEXTURE_2D, 0, gl.GL_RGBA16F, @intCast(w), @intCast(h), 0, gl.GL_RGBA, gl.GL_UNSIGNED_BYTE, null);
    gl.glTexParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_MIN_FILTER, gl.GL_NEAREST);
    gl.glTexParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_MAG_FILTER, gl.GL_NEAREST);
    gl.glTexParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_WRAP_S, gl.GL_CLAMP_TO_EDGE);
    gl.glTexParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_WRAP_T, gl.GL_CLAMP_TO_EDGE);

    gl.glGenFramebuffers(1, fbo);
    gl.glBindFramebuffer(gl.GL_FRAMEBUFFER, fbo.*);
    gl.glFramebufferTexture2D(gl.GL_FRAMEBUFFER, gl.GL_COLOR_ATTACHMENT0, gl.GL_TEXTURE_2D, tex.*, 0);
    gl.glBindFramebuffer(gl.GL_FRAMEBUFFER, 0);
    gl.glBindTexture(gl.GL_TEXTURE_2D, 0);
}

pub fn destroyGlowResources(app: *App) void {
    if (app.glow_extract_fbo != 0) {
        gl.glDeleteFramebuffers(1, &app.glow_extract_fbo);
        app.glow_extract_fbo = 0;
    }
    if (app.glow_extract_tex != 0) {
        gl.glDeleteTextures(1, &app.glow_extract_tex);
        app.glow_extract_tex = 0;
    }
    for (0..3) |i| {
        if (app.glow_mip_fbo[i] != 0) {
            gl.glDeleteFramebuffers(1, &app.glow_mip_fbo[i]);
            app.glow_mip_fbo[i] = 0;
        }
        if (app.glow_mip_tex[i] != 0) {
            gl.glDeleteTextures(1, &app.glow_mip_tex[i]);
            app.glow_mip_tex[i] = 0;
        }
    }
}

// =========================================================================
// Per-frame rendering
// =========================================================================

/// Flush pending atlas operations queued from the core thread.
/// Must be called on the GL thread (during render signal).
pub fn flushPendingAtlasOps(app: *App) void {
    app.atlas_mu.lock();
    const ops = app.pending_atlas_ops.items;
    // Move ownership: take the current list and replace with empty
    var pending = app.pending_atlas_ops;
    app.pending_atlas_ops = .{};
    app.atlas_mu.unlock();

    if (applog.isEnabled() and ops.len > 0) {
        applog.appLog("[gl] flushPendingAtlasOps: {d} ops\n", .{ops.len});
    }

    for (ops) |op| {
        switch (op) {
            .create => |c| {
                if (applog.isEnabled()) applog.appLog("[gl] deferred atlas create {d}x{d}\n", .{ c.w, c.h });
                createAtlasTexture(app, c.w, c.h);
            },
            .upload => |u| {
                // Reconstruct a GlyphBitmap for uploadAtlasRegion
                var bmp: app_mod.GlyphBitmap = .{
                    .pixels = @ptrCast(u.pixels.ptr),
                    .width = @intCast(u.width),
                    .height = @intCast(u.height),
                    .pitch = u.pitch,
                    .bearing_x = 0,
                    .bearing_y = 0,
                    .advance_26_6 = 0,
                    .ascent_px = 0,
                    .descent_px = 0,
                    .bytes_per_pixel = u.bpp,
                };
                uploadAtlasRegion(app, u.dest_x, u.dest_y, u.width, u.height, &bmp);
                app.alloc.free(u.pixels);
            },
        }
    }

    pending.deinit(app.alloc);
}

/// Main render function called from GLArea "render" signal.
/// Returns true to stop other handlers (standard GTK pattern).
pub fn render(app: *App, width: i32, height: i32) bool {
    if (width <= 0 or height <= 0) return true;

    // Flush deferred atlas operations (created/uploaded from core thread)
    flushPendingAtlasOps(app);

    const w: u32 = @intCast(width);
    const h: u32 = @intCast(height);

    // Handle deferred resize (GL context is current here)
    if (app.gl_needs_resize) {
        app.gl_needs_resize = false;
        createGlowResources(app, w, h);
        // Invalidate all cached row VBOs so they re-upload with new NDC coordinates
        for (app.row_vbs.items) |*rvb| {
            rvb.uploaded_slot = app_mod.SLOT_NONE;
        }
    }

    // Extract default background color
    const bg = app.default_bg;
    const bg_r: f32 = @as(f32, @floatFromInt((bg >> 16) & 0xFF)) / 255.0;
    const bg_g: f32 = @as(f32, @floatFromInt((bg >> 8) & 0xFF)) / 255.0;
    const bg_b: f32 = @as(f32, @floatFromInt(bg & 0xFF)) / 255.0;

    // Clear with default background
    gl.glViewport(0, 0, @intCast(w), @intCast(h));
    gl.glClearColor(bg_r, bg_g, bg_b, 1.0);
    gl.glClear(gl.GL_COLOR_BUFFER_BIT);

    // Acquire committed vertex set from triple buffer
    const snapshot = app.tbs.acquireForPaint();
    defer {
        const needs_redraw = app.tbs.releaseFromPaint(snapshot.committed_index);
        if (needs_redraw) {
            if (app.gl_area) |area| {
                main_mod.gtk_externs.widget_queue_draw(area);
            }
        }
    }

    const vs = &app.tbs.sets[snapshot.committed_index];

    if (applog.isEnabled()) {
        const flat_count = vs.flat_verts.items.len;
        const cursor_count = vs.cursor_verts.items.len;
        const row_count = vs.row_map.items.len;
        const rm: u8 = if (vs.row_mode) 1 else 0;
        applog.appLog("[gl] render: row_mode={d}, flat={d}, cursor={d}, rows={d}, atlas_tex={d}\n", .{
            rm, flat_count, cursor_count, row_count, app.gl_atlas_texture,
        });
    }

    // Bind atlas texture
    gl.glActiveTexture(gl.GL_TEXTURE0);
    gl.glBindTexture(gl.GL_TEXTURE_2D, app.gl_atlas_texture);

    // Enable blending
    gl.glEnable(gl.GL_BLEND);

    // Bind VAO
    gl.glBindVertexArray(app.gl_vao);

    // Draw all rows
    if (vs.row_mode) {
        renderRowMode(app, vs, w, h);
    } else if (vs.flat_verts.items.len > 0) {
        // Flat mode: single draw call
        gl.glUseProgram(app.gl_program_main);
        gl.glBlendFunc(gl.GL_ONE, gl.GL_ONE_MINUS_SRC_ALPHA);

        var vbo: gl.GLuint = 0;
        gl.glGenBuffers(1, &vbo);
        gl.glBindBuffer(gl.GL_ARRAY_BUFFER, vbo);
        gl.glBufferData(
            gl.GL_ARRAY_BUFFER,
            @intCast(vs.flat_verts.items.len * @sizeOf(Vertex)),
            @ptrCast(vs.flat_verts.items.ptr),
            gl.GL_STREAM_DRAW,
        );
        setupVertexAttribs();
        gl.glDrawArrays(gl.GL_TRIANGLES, 0, @intCast(vs.flat_verts.items.len));
        gl.glDeleteBuffers(1, &vbo);
    }

    // Draw cursor (skip when blink state is off)
    if (vs.cursor_verts.items.len > 0 and app.cursor_blink_state) {
        gl.glUseProgram(app.gl_program_main);
        gl.glBlendFunc(gl.GL_ONE, gl.GL_ONE_MINUS_SRC_ALPHA);

        var cursor_vbo: gl.GLuint = 0;
        gl.glGenBuffers(1, &cursor_vbo);
        gl.glBindBuffer(gl.GL_ARRAY_BUFFER, cursor_vbo);
        gl.glBufferData(
            gl.GL_ARRAY_BUFFER,
            @intCast(vs.cursor_verts.items.len * @sizeOf(Vertex)),
            @ptrCast(vs.cursor_verts.items.ptr),
            gl.GL_STREAM_DRAW,
        );
        setupVertexAttribs();
        gl.glDrawArrays(gl.GL_TRIANGLES, 0, @intCast(vs.cursor_verts.items.len));
        gl.glDeleteBuffers(1, &cursor_vbo);
    }

    // Draw cmdline overlay (ext_cmdline rendered on main GLArea)
    renderCmdlineOverlay(app, w, h);

    // Draw popupmenu overlay (ext_popupmenu rendered on main GLArea)
    renderPopupmenuOverlay(app, w, h);

    // Draw message overlay (ext_messages rendered on main GLArea)
    renderMessageOverlay(app, w, h);

    // Tab bar is rendered by GTK widgets (see callbacks.zig idleUpdateTabBar)

    // Draw scrollbar
    renderScrollbar(app, w, h);

    gl.glBindVertexArray(0);
    gl.glBindTexture(gl.GL_TEXTURE_2D, 0);
    gl.glDisable(gl.GL_BLEND);

    return true;
}

/// Render ext_cmdline overlay on the main GLArea.
/// The cmdline grid vertices are stored in external_windows[CMDLINE_GRID_ID]
/// using row_mode (per-row slots in the TripleBufferedSurface pool).
fn renderCmdlineOverlay(app: *App, viewport_w: u32, viewport_h: u32) void {
    app.mu.lock();
    const visible = app.cmdline_visible;
    const ext_ptr = app.external_windows.getPtr(app_mod.CMDLINE_GRID_ID);
    if (!visible or ext_ptr == null) {
        app.mu.unlock();
        return;
    }
    const ext = ext_ptr.?;

    // Acquire committed vertex set
    const snapshot = ext.tbs.acquireForPaint();
    const ext_vs = &ext.tbs.sets[snapshot.committed_index];

    // Collect all row vertices into a flat list
    var total_vert_count: usize = 0;
    const row_count = ext_vs.row_map.items.len;
    for (ext_vs.row_map.items[0..row_count]) |mapping| {
        if (mapping.slot == app_mod.SLOT_NONE) continue;
        if (mapping.slot >= ext.tbs.pool.slots.items.len) continue;
        total_vert_count += ext.tbs.pool.slots.items[mapping.slot].verts.items.len;
    }
    // Also check cursor verts
    total_vert_count += ext_vs.cursor_verts.items.len;

    if (total_vert_count == 0) {
        _ = ext.tbs.releaseFromPaint(snapshot.committed_index);
        app.mu.unlock();
        return;
    }

    const content_rows = ext_vs.rows;
    const content_cols = ext_vs.cols;
    const cell_w = app.cell_w_px;
    const cell_h = app.cell_h_px + app.linespace_px;
    const firstc = app.cmdline_firstc;
    const border_color = app.cmdline_border_color;
    const icon_color = app.cmdline_icon_color;
    app.mu.unlock();

    if (content_rows == 0 or content_cols == 0) {
        app.mu.lock();
        _ = ext.tbs.releaseFromPaint(snapshot.committed_index);
        app.mu.unlock();
        return;
    }

    const vp_w: f32 = @floatFromInt(viewport_w);
    const vp_h: f32 = @floatFromInt(viewport_h);
    if (!(vp_w > 0 and vp_h > 0)) {
        app.mu.lock();
        _ = ext.tbs.releaseFromPaint(snapshot.committed_index);
        app.mu.unlock();
        return;
    }

    const content_w_px: f32 = @floatFromInt(content_cols * cell_w);
    const content_h_px: f32 = @floatFromInt(content_rows * cell_h);

    // Calculate total window dimensions including padding and icon
    const icon_total_w: f32 = @floatFromInt(app_mod.CMDLINE_ICON_MARGIN_LEFT + app_mod.CMDLINE_ICON_SIZE + app_mod.CMDLINE_ICON_MARGIN_RIGHT);
    const padding: f32 = @floatFromInt(app_mod.CMDLINE_PADDING);
    const total_w_px: f32 = @min(content_w_px + icon_total_w + padding * 2.0, vp_w);
    const total_h_px: f32 = content_h_px + padding * 2.0;

    // Center horizontally, position at 1/3 from top
    const box_x_px: f32 = (vp_w - total_w_px) / 2.0;
    const box_y_px: f32 = vp_h / 3.0;

    // Convert box position to NDC
    const box_left_ndc: f32 = box_x_px / vp_w * 2.0 - 1.0;
    const box_top_ndc: f32 = 1.0 - box_y_px / vp_h * 2.0;
    const box_w_ndc: f32 = total_w_px / vp_w * 2.0;
    const box_h_ndc: f32 = total_h_px / vp_h * 2.0;

    // Content area within the box (offset by padding + icon)
    const content_left_px: f32 = box_x_px + padding + icon_total_w;
    const content_top_px: f32 = box_y_px + padding;

    // Transform source vertices from their NDC space [-1, 1] to content area in viewport NDC
    const content_w_ndc: f32 = content_w_px / vp_w * 2.0;
    const content_h_ndc: f32 = content_h_px / vp_h * 2.0;
    const content_left_ndc: f32 = content_left_px / vp_w * 2.0 - 1.0;
    const content_top_ndc: f32 = 1.0 - content_top_px / vp_h * 2.0;

    const scale_x: f32 = content_w_ndc / 2.0;
    const scale_y: f32 = content_h_ndc / 2.0;
    const offset_x: f32 = content_left_ndc + content_w_ndc / 2.0;
    const offset_y: f32 = content_top_ndc - content_h_ndc / 2.0;

    // Allocate: bg(6) + transformed verts + border(24) + icon(12)
    const extra_count: usize = 6 + 24 + 12;
    const total_alloc = total_vert_count + extra_count;
    var cmdline_verts = app.alloc.alloc(Vertex, total_alloc) catch {
        app.mu.lock();
        _ = ext.tbs.releaseFromPaint(snapshot.committed_index);
        app.mu.unlock();
        return;
    };
    defer app.alloc.free(cmdline_verts);

    // Extract original background color from row vertices
    var orig_bg_r: f32 = 0.0;
    var orig_bg_g: f32 = 0.0;
    var orig_bg_b: f32 = 0.0;
    var found_bg = false;
    for (ext_vs.row_map.items[0..row_count]) |mapping| {
        if (found_bg) break;
        if (mapping.slot == app_mod.SLOT_NONE) continue;
        if (mapping.slot >= ext.tbs.pool.slots.items.len) continue;
        for (ext.tbs.pool.slots.items[mapping.slot].verts.items) |v| {
            if (v.texCoord[0] < 0) {
                orig_bg_r = v.color[0];
                orig_bg_g = v.color[1];
                orig_bg_b = v.color[2];
                found_bg = true;
                break;
            }
        }
    }
    if (!found_bg) {
        const bg = app.default_bg;
        orig_bg_r = @as(f32, @floatFromInt((bg >> 16) & 0xFF)) / 255.0;
        orig_bg_g = @as(f32, @floatFromInt((bg >> 8) & 0xFF)) / 255.0;
        orig_bg_b = @as(f32, @floatFromInt(bg & 0xFF)) / 255.0;
    }

    // Background fill (slightly adjusted brightness)
    const adjusted = app_mod.adjustBrightnessForCmdline(orig_bg_r, orig_bg_g, orig_bg_b);
    const bg_color: [4]f32 = .{ adjusted[0], adjusted[1], adjusted[2], 1.0 };
    const bg_tex: [2]f32 = .{ -1.0, -1.0 };
    var idx: usize = 0;
    idx = app_mod.addRectVerts(cmdline_verts, idx, box_left_ndc, box_top_ndc, box_w_ndc, box_h_ndc, bg_color, bg_tex, app_mod.CMDLINE_GRID_ID);

    // Transform and copy content vertices from all rows
    const tolerance: f32 = 0.005;
    const deco_cursor = app_mod.DECO_CURSOR;
    for (ext_vs.row_map.items[0..row_count]) |mapping| {
        if (mapping.slot == app_mod.SLOT_NONE) continue;
        if (mapping.slot >= ext.tbs.pool.slots.items.len) continue;
        for (ext.tbs.pool.slots.items[mapping.slot].verts.items) |v| {
            var vert = v;
            vert.position[0] = v.position[0] * scale_x + offset_x;
            vert.position[1] = v.position[1] * scale_y + offset_y;

            // Hide bg cells that match the original background
            if ((v.deco_flags & deco_cursor) == 0 and v.texCoord[0] < 0) {
                const matches_bg = @abs(v.color[0] - orig_bg_r) < tolerance and
                    @abs(v.color[1] - orig_bg_g) < tolerance and
                    @abs(v.color[2] - orig_bg_b) < tolerance;
                if (matches_bg) vert.color[3] = 0.0;
            }

            if (idx < total_alloc) {
                cmdline_verts[idx] = vert;
                idx += 1;
            }
        }
    }

    // Also add cursor vertices
    for (ext_vs.cursor_verts.items) |v| {
        var vert = v;
        vert.position[0] = v.position[0] * scale_x + offset_x;
        vert.position[1] = v.position[1] * scale_y + offset_y;
        if (idx < total_alloc) {
            cmdline_verts[idx] = vert;
            idx += 1;
        }
    }

    // Border (4 edges)
    const border_w_ndc: f32 = @as(f32, @floatFromInt(app_mod.CMDLINE_BORDER_WIDTH)) / (vp_w / 2.0);
    const border_h_ndc: f32 = @as(f32, @floatFromInt(app_mod.CMDLINE_BORDER_WIDTH)) / (vp_h / 2.0);
    const bc: [4]f32 = .{ border_color[0], border_color[1], border_color[2], 1.0 };
    const bt: [2]f32 = .{ -1.0, -1.0 };
    const gid = app_mod.CMDLINE_GRID_ID;
    // Top
    idx = app_mod.addRectVerts(cmdline_verts, idx, box_left_ndc, box_top_ndc, box_w_ndc, border_h_ndc, bc, bt, gid);
    // Bottom
    idx = app_mod.addRectVerts(cmdline_verts, idx, box_left_ndc, box_top_ndc - box_h_ndc + border_h_ndc, box_w_ndc, border_h_ndc, bc, bt, gid);
    // Left
    idx = app_mod.addRectVerts(cmdline_verts, idx, box_left_ndc, box_top_ndc - border_h_ndc, border_w_ndc, box_h_ndc - 2.0 * border_h_ndc, bc, bt, gid);
    // Right
    idx = app_mod.addRectVerts(cmdline_verts, idx, box_left_ndc + box_w_ndc - border_w_ndc, box_top_ndc - border_h_ndc, border_w_ndc, box_h_ndc - 2.0 * border_h_ndc, bc, bt, gid);

    // Icon (search for / or ?, chevron otherwise)
    const icon_size_px: f32 = @floatFromInt(app_mod.CMDLINE_ICON_SIZE);
    const icon_x_px: f32 = box_x_px + padding + @as(f32, @floatFromInt(app_mod.CMDLINE_ICON_MARGIN_LEFT));
    const icon_y_px: f32 = box_y_px + (total_h_px - icon_size_px) / 2.0;
    const icon_x_ndc: f32 = icon_x_px / (vp_w / 2.0) - 1.0;
    const icon_y_ndc: f32 = 1.0 - icon_y_px / (vp_h / 2.0);
    const icon_w_ndc: f32 = icon_size_px / (vp_w / 2.0);
    const icon_h_ndc: f32 = icon_size_px / (vp_h / 2.0);
    const ic: [4]f32 = .{ icon_color[0], icon_color[1], icon_color[2], 1.0 };

    if (firstc == '/' or firstc == '?') {
        idx = app_mod.addSearchIconVerts(cmdline_verts, idx, icon_x_ndc, icon_y_ndc, icon_w_ndc, icon_h_ndc, ic, gid);
    } else {
        idx = app_mod.addChevronIconVerts(cmdline_verts, idx, icon_x_ndc, icon_y_ndc, icon_w_ndc, icon_h_ndc, ic, gid);
    }

    // Draw the cmdline overlay
    gl.glUseProgram(app.gl_program_main);
    gl.glBlendFunc(gl.GL_ONE, gl.GL_ONE_MINUS_SRC_ALPHA);

    var vbo: gl.GLuint = 0;
    gl.glGenBuffers(1, &vbo);
    gl.glBindBuffer(gl.GL_ARRAY_BUFFER, vbo);
    gl.glBufferData(
        gl.GL_ARRAY_BUFFER,
        @intCast(idx * @sizeOf(Vertex)),
        @ptrCast(cmdline_verts.ptr),
        gl.GL_STREAM_DRAW,
    );
    setupVertexAttribs();
    gl.glDrawArrays(gl.GL_TRIANGLES, 0, @intCast(idx));
    gl.glDeleteBuffers(1, &vbo);

    // Release the paint snapshot
    app.mu.lock();
    if (app.external_windows.getPtr(app_mod.CMDLINE_GRID_ID)) |ext2| {
        _ = ext2.tbs.releaseFromPaint(snapshot.committed_index);
    }
    app.mu.unlock();
}

/// Render ext_popupmenu overlay on the main GLArea.
/// Position is calculated from anchor (row, col, grid_id) saved from onPopupmenuShow.
fn renderPopupmenuOverlay(app: *App, viewport_w: u32, viewport_h: u32) void {
    app.mu.lock();
    const visible = app.popupmenu_visible;
    const ext_ptr = app.external_windows.getPtr(app_mod.POPUPMENU_GRID_ID);
    if (!visible or ext_ptr == null) {
        app.mu.unlock();
        return;
    }
    const ext = ext_ptr.?;

    const snapshot = ext.tbs.acquireForPaint();
    const ext_vs = &ext.tbs.sets[snapshot.committed_index];

    // Collect row vertices
    var total_vert_count: usize = 0;
    const row_count = ext_vs.row_map.items.len;
    for (ext_vs.row_map.items[0..row_count]) |mapping| {
        if (mapping.slot == app_mod.SLOT_NONE) continue;
        if (mapping.slot >= ext.tbs.pool.slots.items.len) continue;
        total_vert_count += ext.tbs.pool.slots.items[mapping.slot].verts.items.len;
    }
    total_vert_count += ext_vs.cursor_verts.items.len;

    if (total_vert_count == 0) {
        _ = ext.tbs.releaseFromPaint(snapshot.committed_index);
        app.mu.unlock();
        return;
    }

    const content_rows = ext_vs.rows;
    const content_cols = ext_vs.cols;
    const cell_w = app.cell_w_px;
    const cell_h = app.cell_h_px + app.linespace_px;
    const anchor_row = app.popupmenu_anchor_row;
    const anchor_col = app.popupmenu_anchor_col;
    const border_color = app.cmdline_border_color;
    app.mu.unlock();

    if (content_rows == 0 or content_cols == 0) {
        app.mu.lock();
        _ = ext.tbs.releaseFromPaint(snapshot.committed_index);
        app.mu.unlock();
        return;
    }

    const vp_w: f32 = @floatFromInt(viewport_w);
    const vp_h: f32 = @floatFromInt(viewport_h);
    if (!(vp_w > 0 and vp_h > 0)) {
        app.mu.lock();
        _ = ext.tbs.releaseFromPaint(snapshot.committed_index);
        app.mu.unlock();
        return;
    }

    const content_w_px: f32 = @floatFromInt(content_cols * cell_w);
    const content_h_px: f32 = @floatFromInt(content_rows * cell_h);

    // Calculate position from anchor
    var box_x_px: f32 = undefined;
    var box_y_px: f32 = undefined;

    if (anchor_row == -1) {
        // Cmdline completion: position above/below cmdline overlay
        const cmdline_ext = app.external_windows.getPtr(app_mod.CMDLINE_GRID_ID);
        const cmdline_rows: u32 = if (cmdline_ext) |ce| ce.rows else 1;
        const cmdline_h_px: f32 = @floatFromInt(cmdline_rows * cell_h);
        const icon_total_w: f32 = @floatFromInt(app_mod.CMDLINE_ICON_MARGIN_LEFT + app_mod.CMDLINE_ICON_SIZE + app_mod.CMDLINE_ICON_MARGIN_RIGHT);
        const padding: f32 = @floatFromInt(app_mod.CMDLINE_PADDING);
        const cmdline_total_h: f32 = cmdline_h_px + padding * 2.0;
        const cmdline_y: f32 = vp_h / 3.0;

        // Position above cmdline with a 4px gap
        box_y_px = cmdline_y - content_h_px - 4.0;
        if (box_y_px < 0) box_y_px = cmdline_y + cmdline_total_h + 4.0; // below if no room

        // X: cmdline content area + anchor col offset
        const cmdline_cols: u32 = if (cmdline_ext) |ce| ce.cols else 80;
        const cmdline_content_w: f32 = @floatFromInt(cmdline_cols * cell_w);
        const cmdline_total_w: f32 = @min(cmdline_content_w + icon_total_w + padding * 2.0, vp_w);
        const cmdline_x: f32 = (vp_w - cmdline_total_w) / 2.0;
        const col_f: f32 = if (anchor_col >= 0) @floatFromInt(anchor_col) else 0;
        box_x_px = cmdline_x + padding + icon_total_w + col_f * @as(f32, @floatFromInt(cell_w));
    } else {
        // Anchored to main grid or other grid
        const col_f: f32 = if (anchor_col >= 0) @floatFromInt(anchor_col) else 0;
        const row_f: f32 = if (anchor_row >= 0) @floatFromInt(anchor_row) else 0;
        box_x_px = col_f * @as(f32, @floatFromInt(cell_w));
        // Position below the anchor row (+ 1 row for the line itself)
        box_y_px = (row_f + 1.0) * @as(f32, @floatFromInt(cell_h));

        // If popupmenu would go off-screen bottom, show above anchor
        if (box_y_px + content_h_px > vp_h) {
            box_y_px = row_f * @as(f32, @floatFromInt(cell_h)) - content_h_px;
            if (box_y_px < 0) box_y_px = 0;
        }
    }

    // Clamp to viewport
    if (box_x_px + content_w_px > vp_w) box_x_px = vp_w - content_w_px;
    if (box_x_px < 0) box_x_px = 0;

    // NDC conversion
    const box_left_ndc: f32 = box_x_px / vp_w * 2.0 - 1.0;
    const box_top_ndc: f32 = 1.0 - box_y_px / vp_h * 2.0;
    const box_w_ndc: f32 = content_w_px / vp_w * 2.0;
    const box_h_ndc: f32 = content_h_px / vp_h * 2.0;

    // Transform scale/offset for content vertices
    const scale_x: f32 = box_w_ndc / 2.0;
    const scale_y: f32 = box_h_ndc / 2.0;
    const offset_x: f32 = box_left_ndc + box_w_ndc / 2.0;
    const offset_y: f32 = box_top_ndc - box_h_ndc / 2.0;

    // Allocate: content verts + border(24)
    const extra_count: usize = 24;
    const total_alloc = total_vert_count + extra_count;
    var pum_verts = app.alloc.alloc(Vertex, total_alloc) catch {
        app.mu.lock();
        _ = ext.tbs.releaseFromPaint(snapshot.committed_index);
        app.mu.unlock();
        return;
    };
    defer app.alloc.free(pum_verts);

    // Transform and copy content vertices from all rows
    var idx: usize = 0;
    for (ext_vs.row_map.items[0..row_count]) |mapping| {
        if (mapping.slot == app_mod.SLOT_NONE) continue;
        if (mapping.slot >= ext.tbs.pool.slots.items.len) continue;
        for (ext.tbs.pool.slots.items[mapping.slot].verts.items) |v| {
            var vert = v;
            vert.position[0] = v.position[0] * scale_x + offset_x;
            vert.position[1] = v.position[1] * scale_y + offset_y;
            if (idx < total_alloc) {
                pum_verts[idx] = vert;
                idx += 1;
            }
        }
    }

    // Cursor vertices
    for (ext_vs.cursor_verts.items) |v| {
        var vert = v;
        vert.position[0] = v.position[0] * scale_x + offset_x;
        vert.position[1] = v.position[1] * scale_y + offset_y;
        if (idx < total_alloc) {
            pum_verts[idx] = vert;
            idx += 1;
        }
    }

    // Border (4 edges) using same border color as cmdline
    const border_w_ndc: f32 = @as(f32, @floatFromInt(app_mod.CMDLINE_BORDER_WIDTH)) / (vp_w / 2.0);
    const border_h_ndc: f32 = @as(f32, @floatFromInt(app_mod.CMDLINE_BORDER_WIDTH)) / (vp_h / 2.0);
    const bc: [4]f32 = .{ border_color[0], border_color[1], border_color[2], 1.0 };
    const bt: [2]f32 = .{ -1.0, -1.0 };
    const gid = app_mod.POPUPMENU_GRID_ID;
    idx = app_mod.addRectVerts(pum_verts, idx, box_left_ndc, box_top_ndc, box_w_ndc, border_h_ndc, bc, bt, gid);
    idx = app_mod.addRectVerts(pum_verts, idx, box_left_ndc, box_top_ndc - box_h_ndc + border_h_ndc, box_w_ndc, border_h_ndc, bc, bt, gid);
    idx = app_mod.addRectVerts(pum_verts, idx, box_left_ndc, box_top_ndc - border_h_ndc, border_w_ndc, box_h_ndc - 2.0 * border_h_ndc, bc, bt, gid);
    idx = app_mod.addRectVerts(pum_verts, idx, box_left_ndc + box_w_ndc - border_w_ndc, box_top_ndc - border_h_ndc, border_w_ndc, box_h_ndc - 2.0 * border_h_ndc, bc, bt, gid);

    // Draw
    gl.glUseProgram(app.gl_program_main);
    gl.glBlendFunc(gl.GL_ONE, gl.GL_ONE_MINUS_SRC_ALPHA);

    var vbo: gl.GLuint = 0;
    gl.glGenBuffers(1, &vbo);
    gl.glBindBuffer(gl.GL_ARRAY_BUFFER, vbo);
    gl.glBufferData(
        gl.GL_ARRAY_BUFFER,
        @intCast(idx * @sizeOf(Vertex)),
        @ptrCast(pum_verts.ptr),
        gl.GL_STREAM_DRAW,
    );
    setupVertexAttribs();
    gl.glDrawArrays(gl.GL_TRIANGLES, 0, @intCast(idx));
    gl.glDeleteBuffers(1, &vbo);

    // Release paint snapshot
    app.mu.lock();
    if (app.external_windows.getPtr(app_mod.POPUPMENU_GRID_ID)) |ext2| {
        _ = ext2.tbs.releaseFromPaint(snapshot.committed_index);
    }
    app.mu.unlock();
}

/// Render using row-mode vertex buffers (per-row VBOs with scroll optimization).
fn renderRowMode(app: *App, vs: *const app_mod.VertexSet, w: u32, h: u32) void {
    _ = w;
    gl.glUseProgram(app.gl_program_main);
    gl.glBlendFunc(gl.GL_ONE, gl.GL_ONE_MINUS_SRC_ALPHA);

    // Ensure we have enough RowVBs
    const needed = vs.row_map.items.len;
    while (app.row_vbs.items.len < needed) {
        app.row_vbs.append(app.alloc, .{}) catch break;
    }

    // Limit drawn rows to what fits in current viewport (cell_h_px includes linespace)
    const cell_h: u32 = @max(1, app.cell_h_px + app.linespace_px);
    const viewport_rows: usize = @intCast(h / cell_h);
    const draw_rows = @min(vs.row_map.items.len, viewport_rows);

    var total_drawn: usize = 0;
    var none_count: usize = 0;
    var empty_count: usize = 0;
    for (vs.row_map.items[0..draw_rows], 0..) |mapping, row_idx| {
        if (mapping.slot == app_mod.SLOT_NONE) { none_count += 1; continue; }

        const slot = &app.tbs.pool.slots.items[mapping.slot];
        if (slot.verts.items.len == 0) { empty_count += 1; continue; }
        total_drawn += slot.verts.items.len;

        const rvb = &app.row_vbs.items[row_idx];

        // Upload if content changed
        if (rvb.uploaded_slot != mapping.slot or rvb.uploaded_ver != slot.ver) {
            const data_bytes = slot.verts.items.len * @sizeOf(Vertex);

            if (rvb.gl_vbo == 0) {
                gl.glGenBuffers(1, &rvb.gl_vbo);
            }

            gl.glBindBuffer(gl.GL_ARRAY_BUFFER, rvb.gl_vbo);

            if (data_bytes > rvb.vbo_bytes) {
                gl.glBufferData(
                    gl.GL_ARRAY_BUFFER,
                    @intCast(data_bytes),
                    @ptrCast(slot.verts.items.ptr),
                    gl.GL_DYNAMIC_DRAW,
                );
                rvb.vbo_bytes = data_bytes;
            } else {
                gl.glBufferSubData(
                    gl.GL_ARRAY_BUFFER,
                    0,
                    @intCast(data_bytes),
                    @ptrCast(slot.verts.items.ptr),
                );
            }

            rvb.uploaded_slot = mapping.slot;
            rvb.uploaded_ver = slot.ver;
        } else {
            gl.glBindBuffer(gl.GL_ARRAY_BUFFER, rvb.gl_vbo);
        }

        setupVertexAttribs();
        gl.glDrawArrays(gl.GL_TRIANGLES, 0, @intCast(slot.verts.items.len));
    }

    if (applog.isEnabled()) {
        applog.appLog("[gl] renderRowMode: rows={d} none={d} empty={d} drawn_verts={d} pool_slots={d}\n", .{
            vs.row_map.items.len, none_count, empty_count, total_drawn, app.tbs.pool.slots.items.len,
        });
    }
}

/// Render ext_messages overlay (MESSAGE_GRID_ID / MSG_HISTORY_GRID_ID) on main GLArea.
fn renderMessageOverlay(app: *App, viewport_w: u32, viewport_h: u32) void {
    const grid_ids = [_]i64{ app_mod.MESSAGE_GRID_ID, app_mod.MSG_HISTORY_GRID_ID };
    for (grid_ids) |grid_id| {
        renderSingleMessageGrid(app, viewport_w, viewport_h, grid_id);
    }
}

fn renderSingleMessageGrid(app: *App, viewport_w: u32, viewport_h: u32, grid_id: i64) void {
    app.mu.lock();
    const ext_ptr = app.external_windows.getPtr(grid_id);
    if (ext_ptr == null) {
        app.mu.unlock();
        return;
    }
    const ext = ext_ptr.?;

    const snapshot = ext.tbs.acquireForPaint();
    const ext_vs = &ext.tbs.sets[snapshot.committed_index];

    var total_vert_count: usize = 0;
    const row_count = ext_vs.row_map.items.len;
    for (ext_vs.row_map.items[0..row_count]) |mapping| {
        if (mapping.slot == app_mod.SLOT_NONE) continue;
        if (mapping.slot >= ext.tbs.pool.slots.items.len) continue;
        total_vert_count += ext.tbs.pool.slots.items[mapping.slot].verts.items.len;
    }
    total_vert_count += ext_vs.cursor_verts.items.len;

    if (total_vert_count == 0) {
        _ = ext.tbs.releaseFromPaint(snapshot.committed_index);
        app.mu.unlock();
        return;
    }

    const content_rows = ext_vs.rows;
    const content_cols = ext_vs.cols;
    const cell_w = app.cell_w_px;
    const cell_h = app.cell_h_px + app.linespace_px;
    const start_row = ext.start_row;
    const start_col = ext.start_col;
    app.mu.unlock();

    if (content_rows == 0 or content_cols == 0) {
        app.mu.lock();
        _ = ext.tbs.releaseFromPaint(snapshot.committed_index);
        app.mu.unlock();
        return;
    }

    const vp_w: f32 = @floatFromInt(viewport_w);
    const vp_h: f32 = @floatFromInt(viewport_h);
    if (!(vp_w > 0 and vp_h > 0)) {
        app.mu.lock();
        _ = ext.tbs.releaseFromPaint(snapshot.committed_index);
        app.mu.unlock();
        return;
    }

    const content_w_px: f32 = @floatFromInt(content_cols * cell_w);
    const content_h_px: f32 = @floatFromInt(content_rows * cell_h);
    const padding: f32 = @floatFromInt(app_mod.MSG_PADDING);

    // Position from core-supplied start_row/start_col (grid coordinates)
    var box_x_px: f32 = @as(f32, @floatFromInt(start_col)) * @as(f32, @floatFromInt(cell_w));
    var box_y_px: f32 = @as(f32, @floatFromInt(start_row)) * @as(f32, @floatFromInt(cell_h));

    if (start_row < 0) box_y_px = vp_h - content_h_px - padding * 2.0;
    if (start_col < 0) box_x_px = vp_w - content_w_px - padding * 2.0;

    const total_w_px: f32 = content_w_px + padding * 2.0;
    const total_h_px: f32 = content_h_px + padding * 2.0;

    if (box_x_px + total_w_px > vp_w) box_x_px = @max(0, vp_w - total_w_px);
    if (box_y_px + total_h_px > vp_h) box_y_px = @max(0, vp_h - total_h_px);

    const box_left_ndc: f32 = box_x_px / vp_w * 2.0 - 1.0;
    const box_top_ndc: f32 = 1.0 - box_y_px / vp_h * 2.0;
    const box_w_ndc: f32 = total_w_px / vp_w * 2.0;
    const box_h_ndc: f32 = total_h_px / vp_h * 2.0;

    const content_left_px: f32 = box_x_px + padding;
    const content_top_px: f32 = box_y_px + padding;
    const content_w_ndc: f32 = content_w_px / vp_w * 2.0;
    const content_h_ndc: f32 = content_h_px / vp_h * 2.0;
    const content_left_ndc: f32 = content_left_px / vp_w * 2.0 - 1.0;
    const content_top_ndc: f32 = 1.0 - content_top_px / vp_h * 2.0;

    const scale_x: f32 = content_w_ndc / 2.0;
    const scale_y: f32 = content_h_ndc / 2.0;
    const offset_x: f32 = content_left_ndc + content_w_ndc / 2.0;
    const offset_y: f32 = content_top_ndc - content_h_ndc / 2.0;

    // bg(6) + border(24) + content
    const extra_count: usize = 6 + 24;
    const total_alloc = total_vert_count + extra_count;
    var msg_verts = app.alloc.alloc(Vertex, total_alloc) catch {
        app.mu.lock();
        _ = ext.tbs.releaseFromPaint(snapshot.committed_index);
        app.mu.unlock();
        return;
    };
    defer app.alloc.free(msg_verts);

    var idx: usize = 0;
    const bg_tex: [2]f32 = .{ -1.0, -1.0 };

    // Background
    const bg_r: f32 = @as(f32, @floatFromInt((app.default_bg >> 16) & 0xFF)) / 255.0;
    const bg_g: f32 = @as(f32, @floatFromInt((app.default_bg >> 8) & 0xFF)) / 255.0;
    const bg_b: f32 = @as(f32, @floatFromInt(app.default_bg & 0xFF)) / 255.0;
    const bg_a: f32 = 0.95;
    idx = app_mod.addRectVerts(msg_verts, idx, box_left_ndc, box_top_ndc, box_w_ndc, box_h_ndc, .{ bg_r * bg_a, bg_g * bg_a, bg_b * bg_a, bg_a }, bg_tex, grid_id);

    // Border (1px)
    const bc: f32 = 0.35;
    const ba: f32 = 0.8;
    const bw_ndc: f32 = 1.0 / vp_w * 2.0;
    const bh_ndc: f32 = 1.0 / vp_h * 2.0;
    idx = app_mod.addRectVerts(msg_verts, idx, box_left_ndc, box_top_ndc, box_w_ndc, bh_ndc, .{ bc * ba, bc * ba, bc * ba, ba }, bg_tex, grid_id);
    idx = app_mod.addRectVerts(msg_verts, idx, box_left_ndc, box_top_ndc - box_h_ndc + bh_ndc, box_w_ndc, bh_ndc, .{ bc * ba, bc * ba, bc * ba, ba }, bg_tex, grid_id);
    idx = app_mod.addRectVerts(msg_verts, idx, box_left_ndc, box_top_ndc, bw_ndc, box_h_ndc, .{ bc * ba, bc * ba, bc * ba, ba }, bg_tex, grid_id);
    idx = app_mod.addRectVerts(msg_verts, idx, box_left_ndc + box_w_ndc - bw_ndc, box_top_ndc, bw_ndc, box_h_ndc, .{ bc * ba, bc * ba, bc * ba, ba }, bg_tex, grid_id);

    // Content vertices
    for (ext_vs.row_map.items[0..row_count]) |mapping| {
        if (mapping.slot == app_mod.SLOT_NONE) continue;
        if (mapping.slot >= ext.tbs.pool.slots.items.len) continue;
        for (ext.tbs.pool.slots.items[mapping.slot].verts.items) |v| {
            var tv = v;
            tv.position[0] = v.position[0] * scale_x + offset_x;
            tv.position[1] = v.position[1] * scale_y + offset_y;
            msg_verts[idx] = tv;
            idx += 1;
        }
    }
    for (ext_vs.cursor_verts.items) |v| {
        var tv = v;
        tv.position[0] = v.position[0] * scale_x + offset_x;
        tv.position[1] = v.position[1] * scale_y + offset_y;
        msg_verts[idx] = tv;
        idx += 1;
    }

    app.mu.lock();
    _ = ext.tbs.releaseFromPaint(snapshot.committed_index);
    app.mu.unlock();

    if (idx == 0) return;

    gl.glUseProgram(app.gl_program_main);
    gl.glBlendFunc(gl.GL_ONE, gl.GL_ONE_MINUS_SRC_ALPHA);

    var vbo: gl.GLuint = 0;
    gl.glGenBuffers(1, &vbo);
    gl.glBindBuffer(gl.GL_ARRAY_BUFFER, vbo);
    gl.glBufferData(gl.GL_ARRAY_BUFFER, @intCast(idx * @sizeOf(Vertex)), @ptrCast(msg_verts.ptr), gl.GL_STREAM_DRAW);
    setupVertexAttribs();
    gl.glDrawArrays(gl.GL_TRIANGLES, 0, @intCast(idx));
    gl.glDeleteBuffers(1, &vbo);
}

/// Render scrollbar overlay on the right edge of the viewport.
fn renderScrollbar(app: *App, viewport_w: u32, viewport_h: u32) void {
    if (!app.scrollbar.visible) return;

    const vp_w: f32 = @floatFromInt(viewport_w);
    const vp_h: f32 = @floatFromInt(viewport_h);
    if (!(vp_w > 0 and vp_h > 0)) return;

    const sb_w = app_mod.scrollbarWidth(app.dpi_scale);
    const sb_margin = app_mod.scrollbarMargin(app.dpi_scale);
    const min_knob_h = app_mod.scrollbarMinKnobHeight(app.dpi_scale);

    // Track area (right edge, full height minus margins)
    const track_x_px: f32 = vp_w - sb_w - sb_margin;
    const track_y_px: f32 = sb_margin;
    const track_h_px: f32 = vp_h - sb_margin * 2.0;

    // Knob position
    const knob_y_px: f32 = track_y_px + app.scrollbar.knob_top * track_h_px;
    const knob_h_px: f32 = @max(min_knob_h, app.scrollbar.knob_height * track_h_px);

    const alpha: f32 = app.scrollbar.alpha;
    if (alpha <= 0.01) return;

    // NDC conversion
    const bg_tex: [2]f32 = .{ -1.0, -1.0 };

    // Track background (very subtle)
    const track_left_ndc: f32 = track_x_px / vp_w * 2.0 - 1.0;
    const track_top_ndc: f32 = 1.0 - track_y_px / vp_h * 2.0;
    const track_w_ndc: f32 = sb_w / vp_w * 2.0;
    const track_h_ndc: f32 = track_h_px / vp_h * 2.0;

    // Knob
    const knob_left_ndc: f32 = track_left_ndc;
    const knob_top_ndc: f32 = 1.0 - knob_y_px / vp_h * 2.0;
    const knob_w_ndc: f32 = track_w_ndc;
    const knob_h_ndc: f32 = knob_h_px / vp_h * 2.0;

    // 2 quads: track + knob = 12 verts
    var verts: [12]Vertex = undefined;
    var idx: usize = 0;

    // Track (semi-transparent)
    const ta: f32 = 0.1 * alpha;
    idx = app_mod.addRectVerts(&verts, idx, track_left_ndc, track_top_ndc, track_w_ndc, track_h_ndc, .{ ta, ta, ta, ta }, bg_tex, 0);

    // Knob
    const fg_r: f32 = @as(f32, @floatFromInt((app.default_fg >> 16) & 0xFF)) / 255.0;
    const fg_g: f32 = @as(f32, @floatFromInt((app.default_fg >> 8) & 0xFF)) / 255.0;
    const fg_b: f32 = @as(f32, @floatFromInt(app.default_fg & 0xFF)) / 255.0;
    const ka: f32 = 0.4 * alpha;
    idx = app_mod.addRectVerts(&verts, idx, knob_left_ndc, knob_top_ndc, knob_w_ndc, knob_h_ndc, .{ fg_r * ka, fg_g * ka, fg_b * ka, ka }, bg_tex, 0);

    if (idx == 0) return;

    gl.glUseProgram(app.gl_program_main);
    gl.glBlendFunc(gl.GL_ONE, gl.GL_ONE_MINUS_SRC_ALPHA);

    var vbo: gl.GLuint = 0;
    gl.glGenBuffers(1, &vbo);
    gl.glBindBuffer(gl.GL_ARRAY_BUFFER, vbo);
    gl.glBufferData(gl.GL_ARRAY_BUFFER, @intCast(idx * @sizeOf(Vertex)), @ptrCast(&verts), gl.GL_STREAM_DRAW);
    setupVertexAttribs();
    gl.glDrawArrays(gl.GL_TRIANGLES, 0, @intCast(idx));
    gl.glDeleteBuffers(1, &vbo);
}

// =========================================================================
// Cleanup
// =========================================================================

pub fn deinit(app: *App) void {
    if (app.gl_program_main != 0) gl.glDeleteProgram(app.gl_program_main);
    if (app.gl_program_glow_extract != 0) gl.glDeleteProgram(app.gl_program_glow_extract);
    if (app.gl_program_kawase_down != 0) gl.glDeleteProgram(app.gl_program_kawase_down);
    if (app.gl_program_kawase_up != 0) gl.glDeleteProgram(app.gl_program_kawase_up);
    if (app.gl_program_glow_composite != 0) gl.glDeleteProgram(app.gl_program_glow_composite);
    if (app.gl_vao != 0) gl.glDeleteVertexArrays(1, &app.gl_vao);
    if (app.gl_atlas_texture != 0) gl.glDeleteTextures(1, &app.gl_atlas_texture);

    for (app.row_vbs.items) |*rvb| {
        if (rvb.gl_vbo != 0) gl.glDeleteBuffers(1, &rvb.gl_vbo);
    }
    app.row_vbs.deinit(app.alloc);

    destroyGlowResources(app);

    app.gl_program_main = 0;
    app.gl_program_glow_extract = 0;
    app.gl_program_kawase_down = 0;
    app.gl_program_kawase_up = 0;
    app.gl_program_glow_composite = 0;
    app.gl_vao = 0;
    app.gl_atlas_texture = 0;
}
