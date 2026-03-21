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
    gl.glTexParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_MIN_FILTER, gl.GL_LINEAR);
    gl.glTexParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_MAG_FILTER, gl.GL_LINEAR);
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
    gl.glTexParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_MIN_FILTER, gl.GL_LINEAR);
    gl.glTexParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_MAG_FILTER, gl.GL_LINEAR);
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
        gl.glBlendFunc(gl.GL_SRC_ALPHA, gl.GL_ONE_MINUS_SRC_ALPHA);

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

    // Draw cursor
    if (vs.cursor_verts.items.len > 0) {
        gl.glUseProgram(app.gl_program_main);
        gl.glBlendFunc(gl.GL_SRC_ALPHA, gl.GL_ONE_MINUS_SRC_ALPHA);

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

    gl.glBindVertexArray(0);
    gl.glBindTexture(gl.GL_TEXTURE_2D, 0);
    gl.glDisable(gl.GL_BLEND);

    return true;
}

/// Render using row-mode vertex buffers (per-row VBOs with scroll optimization).
fn renderRowMode(app: *App, vs: *const app_mod.VertexSet, w: u32, h: u32) void {
    _ = w;
    gl.glUseProgram(app.gl_program_main);
    gl.glBlendFunc(gl.GL_SRC_ALPHA, gl.GL_ONE_MINUS_SRC_ALPHA);

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
