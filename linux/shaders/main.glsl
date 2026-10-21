// GLSL 330 port of windows/shaders/main.hlsl VSMain + the M1 subset of PSMain.
// Compiled twice by gl_renderer.zig with `#version 330 core` and VERTEX or
// FRAGMENT prepended, so this file carries no #version line.

#define DECO_COLOR_EMOJI (1u << 10)

#ifdef VERTEX
layout(location = 0) in vec2 a_pos; // grid-local px
layout(location = 1) in vec2 a_uv;
layout(location = 2) in vec4 a_col;
layout(location = 3) in uint a_deco;

uniform vec2 u_scale;
uniform vec2 u_offset;

out vec2 v_uv;
out vec4 v_col;
flat out uint v_deco;

void main() {
    gl_Position = vec4(a_pos * u_scale + u_offset, 0.0, 1.0);
    v_uv = a_uv;
    v_col = a_col;
    v_deco = a_deco;
}
#endif

#ifdef FRAGMENT
uniform sampler2D u_atlas;

in vec2 v_uv;
in vec4 v_col;
flat in uint v_deco;

out vec4 o_color;

vec4 premultiply(vec4 c) {
    return vec4(c.rgb * c.a, c.a);
}

void main() {
    // Solid quads (backgrounds, decorations, cursor) carry uv.x < 0. Pattern
    // decorations (undercurl, dotted, dashed, double) draw solid until M2.
    if (v_uv.x < 0.0) {
        o_color = premultiply(v_col);
        return;
    }
    // The atlas holds color glyphs already premultiplied (FreeType BGRA).
    if ((v_deco & DECO_COLOR_EMOJI) != 0u) {
        o_color = texture(u_atlas, v_uv);
        return;
    }
    // Coverage is linear FreeType gray, replicated into every channel.
    o_color = premultiply(v_col) * texture(u_atlas, v_uv).r;
}
#endif
