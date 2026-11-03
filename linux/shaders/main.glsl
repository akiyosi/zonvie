// GLSL 330 port of windows/shaders/main.hlsl VSMain and the grid subset of
// PSMain. Compiled twice by gl_renderer.zig with `#version 330 core` and
// VERTEX or FRAGMENT prepended, so this file carries no #version line.

#define DECO_UNDERCURL     (1u << 0)
#define DECO_UNDERDOUBLE   (1u << 2)
#define DECO_UNDERDOTTED   (1u << 3)
#define DECO_UNDERDASHED   (1u << 4)
// Transport-only: the vertex is in the scrollable content area, not a margin.
#define DECO_SCROLLABLE    (1u << 7)
#define DECO_GLOW          (1u << 9)
#define DECO_COLOR_EMOJI   (1u << 10)

#ifdef VERTEX
layout(location = 0) in vec2 a_pos; // grid-local px
layout(location = 1) in vec2 a_uv;
layout(location = 2) in vec4 a_col;
layout(location = 3) in uint a_deco;
layout(location = 4) in float a_phase;

uniform vec2 u_scale;
uniform vec2 u_offset;
// How far a smooth scroll still draws this layer's content below where its
// rows put it, in px. Moves only DECO_SCROLLABLE vertices, so margins
// (winbar, float borders) stay put. Zero when nothing eases.
uniform float u_scroll_offset_px;

out vec2 v_uv;
out vec4 v_col;
flat out uint v_deco;
out float v_phase;

void main() {
    vec2 p = a_pos;
    if ((a_deco & DECO_SCROLLABLE) != 0u) p.y += u_scroll_offset_px;
    gl_Position = vec4(p * u_scale + u_offset, 0.0, 1.0);
    v_uv = a_uv;
    v_col = a_col;
    v_deco = a_deco;
    v_phase = a_phase;
}
#endif

#ifdef FRAGMENT
uniform sampler2D u_atlas;
// Layer left edge in surface px, so pattern decorations phase from the
// layer's own edge instead of the window's.
uniform float u_layer_origin_x_px;
// 0 draws the grid; 1 extracts the glyphs the core marked DECO_GLOW, in their
// own colour, for the bloom (windows/shaders/main.hlsl PSGlowExtract).
uniform int u_mode;

in vec2 v_uv;
in vec4 v_col;
flat in uint v_deco;
in float v_phase;

out vec4 o_color;

vec4 premultiply(vec4 c) {
    return vec4(c.rgb * c.a, c.a);
}

void main() {
    if (u_mode == 1) {
        if ((v_deco & DECO_GLOW) == 0u || v_uv.x < 0.0) discard;
        vec4 tex = texture(u_atlas, v_uv);
        if ((v_deco & DECO_COLOR_EMOJI) != 0u) {
            o_color = tex;
            return;
        }
        float cov = dot(tex.rgb, vec3(0.299, 0.587, 0.114));
        o_color = vec4(v_col.rgb * cov, cov);
        return;
    }
    // Solid quads (backgrounds, decorations, cursor) carry uv.x < 0; for
    // decorations uv.y is the local y within the quad (0 top, 1 bottom).
    if (v_uv.x < 0.0) {
        float x_px = gl_FragCoord.x - u_layer_origin_x_px;
        if ((v_deco & DECO_UNDERCURL) != 0u) {
            float cell_width = 8.0;
            float wave_y = sin((x_px / cell_width + v_phase) * 6.28318530) * 0.35;
            float dist = abs(v_uv.y - (0.5 + wave_y));
            if (dist > 0.25) discard;
            float alpha = v_col.a * (1.0 - smoothstep(0.0, 0.25, dist));
            o_color = vec4(v_col.rgb * alpha, alpha);
            return;
        }
        if ((v_deco & DECO_UNDERDOTTED) != 0u) {
            if (mod(x_px, 4.0) >= 2.0) discard;
        } else if ((v_deco & DECO_UNDERDASHED) != 0u) {
            if (mod(x_px, 8.0) >= 5.0) discard;
        } else if ((v_deco & DECO_UNDERDOUBLE) != 0u) {
            if (abs(v_uv.y - 0.2) > 0.15 && abs(v_uv.y - 0.8) > 0.15) discard;
        }
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
