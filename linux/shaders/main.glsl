// Zonvie main shaders (GLSL 4.50)
// Ported from windows/shaders/main.hlsl and macos/Sources/Rendering/Shaders.metal

// ============================================================================
// Vertex Shader (shared by all main passes)
// ============================================================================
#ifdef VERTEX_SHADER

layout(location = 0) in vec2 a_position;   // NDC (-1..1)
layout(location = 1) in vec2 a_texCoord;
layout(location = 2) in vec4 a_color;       // 16-byte aligned
layout(location = 3) in ivec2 a_grid_id;    // i64 as ivec2
layout(location = 4) in uint a_deco_flags;
layout(location = 5) in float a_deco_phase;

out vec2 v_uv;
out vec4 v_col;
flat out uint v_deco_flags;
out float v_deco_phase;

void main() {
    gl_Position = vec4(a_position.xy, 0.0, 1.0);
    v_uv = a_texCoord;
    v_col = a_color;
    v_deco_flags = a_deco_flags;
    v_deco_phase = a_deco_phase;
}

#endif // VERTEX_SHADER

// ============================================================================
// Fragment Shader — Main (glyph + decoration + background)
// ============================================================================
#ifdef FRAGMENT_SHADER_MAIN

in vec2 v_uv;
in vec4 v_col;
flat in uint v_deco_flags;
in float v_deco_phase;

uniform sampler2D u_atlas;

layout(location = 0) out vec4 frag_color;

#define DECO_UNDERCURL     (1u << 0)
#define DECO_UNDERLINE     (1u << 1)
#define DECO_UNDERDOUBLE   (1u << 2)
#define DECO_UNDERDOTTED   (1u << 3)
#define DECO_UNDERDASHED   (1u << 4)
#define DECO_STRIKETHROUGH (1u << 5)
#define DECO_OVERLINE      (1u << 8)
#define DECO_GLOW          (1u << 9)
#define DECO_COLOR_EMOJI   (1u << 10)

// Icon type markers (special uv.x values)
#define ICON_CIRCLE      (-2.0)
#define ICON_CHEVRON     (-3.0)
#define ICON_HANDLE      (-4.0)
#define TABLINE_TEXTURE  (-5.0)

vec4 premultiply(vec4 c) {
    return vec4(c.rgb * c.a, c.a);
}

// SDF helper: circle
float sdCircle(vec2 p, float radius) {
    return length(p) - radius;
}

// SDF helper: line segment distance
float sdSegment(vec2 p, vec2 a, vec2 b) {
    vec2 pa = p - a;
    vec2 ba = b - a;
    float h = clamp(dot(pa, ba) / dot(ba, ba), 0.0, 1.0);
    return length(pa - ba * h);
}

// SDF helper: oriented box
float sdOrientedBox(vec2 p, vec2 a, vec2 b, float th) {
    float len = length(b - a);
    if (len < 0.001) return 1000.0;
    vec2 d = (b - a) / len;
    vec2 q = p - (a + b) * 0.5;
    q = vec2(dot(q, vec2(d.y, -d.x)), dot(q, d));
    q = abs(q) - vec2(th, len) * 0.5;
    return length(max(q, vec2(0.0))) + min(max(q.x, q.y), 0.0);
}

// Render icon with SDF + anti-aliasing
vec4 renderIconSDF(vec4 col, float sdf) {
    float aa = fwidth(sdf) * 1.5;
    float alpha = col.a * (1.0 - smoothstep(-aa, aa, sdf));
    return vec4(col.rgb * alpha, alpha);
}

void main() {
    // Tabline texture mode
    if (v_uv.x <= TABLINE_TEXTURE + 0.1 && v_uv.x >= TABLINE_TEXTURE - 0.1) {
        vec2 tablineUV = vec2(v_uv.y, v_deco_phase);
        vec4 tex = texture(u_atlas, tablineUV);
        frag_color = vec4(tex.rgb * tex.a, tex.a);
        return;
    }

    // Background quads use sentinel uv.x < 0
    if (v_uv.x < 0.0) {
        // Icon rendering with SDF
        if (v_uv.x <= ICON_CIRCLE + 0.1) {
            vec2 localUV = vec2(v_uv.y, v_deco_phase);

            if (v_uv.x >= ICON_CIRCLE - 0.1) {
                vec2 center = vec2(0.42, 0.42);
                float radius = 0.32;
                float sdf = sdCircle(localUV - center, radius);
                frag_color = renderIconSDF(v_col, sdf);
                return;
            }
            if (v_uv.x >= ICON_CHEVRON - 0.1 && v_uv.x <= ICON_CHEVRON + 0.1) {
                vec2 tip = vec2(0.75, 0.5);
                vec2 topLeft = vec2(0.25, 0.2);
                vec2 botLeft = vec2(0.25, 0.8);
                float thickness = 0.08;
                float d1 = sdSegment(localUV, topLeft, tip) - thickness;
                float d2 = sdSegment(localUV, botLeft, tip) - thickness;
                float sdf = min(d1, d2);
                frag_color = renderIconSDF(v_col, sdf);
                return;
            }
            if (v_uv.x >= ICON_HANDLE - 0.1 && v_uv.x <= ICON_HANDLE + 0.1) {
                vec2 start = vec2(0.5, 0.5);
                vec2 endpt = vec2(0.92, 0.92);
                float thickness = 0.12;
                float sdf = sdOrientedBox(localUV, start, endpt, thickness);
                frag_color = renderIconSDF(v_col, sdf);
                return;
            }
        }

        // Decorations
        if (v_deco_flags != 0u) {
            if ((v_deco_flags & DECO_UNDERCURL) != 0u) {
                float wave_freq = 3.14159265 * 2.0;
                float wave_amp = 0.35;
                float cell_width = 8.0;
                float wave_x = (gl_FragCoord.x / cell_width) + v_deco_phase;
                float wave_y = sin(wave_x * wave_freq) * wave_amp;
                float local_y = v_uv.y;
                float wave_center = 0.5 + wave_y;
                float dist = abs(local_y - wave_center);
                if (dist > 0.25) {
                    discard;
                }
                float alpha = v_col.a * (1.0 - smoothstep(0.0, 0.25, dist));
                frag_color = vec4(v_col.rgb * alpha, alpha);
                return;
            }
            if ((v_deco_flags & DECO_UNDERDOTTED) != 0u) {
                float x_mod = mod(gl_FragCoord.x, 4.0);
                if (x_mod >= 2.0) {
                    discard;
                }
                frag_color = premultiply(v_col);
                return;
            }
            if ((v_deco_flags & DECO_UNDERDASHED) != 0u) {
                float x_mod = mod(gl_FragCoord.x, 8.0);
                if (x_mod >= 5.0) {
                    discard;
                }
                frag_color = premultiply(v_col);
                return;
            }
            if ((v_deco_flags & DECO_UNDERDOUBLE) != 0u) {
                float local_y = v_uv.y;
                float line1_center = 0.2;
                float line2_center = 0.8;
                float line_thickness = 0.15;
                float dist1 = abs(local_y - line1_center);
                float dist2 = abs(local_y - line2_center);
                if (dist1 > line_thickness && dist2 > line_thickness) {
                    discard;
                }
                frag_color = premultiply(v_col);
                return;
            }
            // Underline, strikethrough, overline: solid line
            frag_color = premultiply(v_col);
            return;
        }
        // Regular solid color (background)
        frag_color = premultiply(v_col);
        return;
    }

    // Color emoji: sample RGBA directly
    if ((v_deco_flags & DECO_COLOR_EMOJI) != 0u) {
        vec4 emoji = texture(u_atlas, v_uv);
        frag_color = emoji;
        return;
    }

    // Grayscale glyph rendering (FreeType output is linear, no gamma correction needed)
    vec4 foreground = premultiply(v_col);
    vec4 tex = texture(u_atlas, v_uv);
    float glyph_a = tex.r;  // FreeType grayscale stored in R channel
    frag_color = glyph_a * foreground;
}

#endif // FRAGMENT_SHADER_MAIN

// ============================================================================
// Fullscreen triangle vertex shader (no vertex buffer needed)
// ============================================================================
#ifdef VERTEX_SHADER_FULLSCREEN

out vec2 v_uv;

void main() {
    // Oversize triangle trick: 3 vertices cover entire screen
    vec2 uv = vec2((gl_VertexID << 1) & 2, gl_VertexID & 2);
    gl_Position = vec4(uv * vec2(2, -2) + vec2(-1, 1), 0, 1);
    v_uv = uv;
}

#endif // VERTEX_SHADER_FULLSCREEN

// ============================================================================
// Glow Extract Fragment Shader
// ============================================================================
#ifdef FRAGMENT_SHADER_GLOW_EXTRACT

in vec2 v_uv;
in vec4 v_col;
flat in uint v_deco_flags;
in float v_deco_phase;

uniform sampler2D u_atlas;

layout(location = 0) out vec4 frag_color;

#define DECO_GLOW          (1u << 9)
#define DECO_COLOR_EMOJI   (1u << 10)

void main() {
    if ((v_deco_flags & DECO_GLOW) == 0u) discard;
    if (v_uv.x < 0.0) discard;

    if ((v_deco_flags & DECO_COLOR_EMOJI) != 0u) {
        vec4 emoji = texture(u_atlas, v_uv);
        frag_color = vec4(emoji.rgb, emoji.a);
        return;
    }

    vec4 tex = texture(u_atlas, v_uv);
    float cov = tex.r;
    frag_color = vec4(v_col.rgb * cov, cov);
}

#endif // FRAGMENT_SHADER_GLOW_EXTRACT

// ============================================================================
// Dual Kawase Downsample (5 taps)
// ============================================================================
#ifdef FRAGMENT_SHADER_KAWASE_DOWN

in vec2 v_uv;
uniform sampler2D u_glow_tex;
layout(location = 0) out vec4 frag_color;

void main() {
    vec2 tex_size = vec2(textureSize(u_glow_tex, 0));
    vec2 halfpixel = 0.5 / tex_size;

    vec4 sum = texture(u_glow_tex, v_uv) * 4.0;
    sum += texture(u_glow_tex, v_uv + vec2(-halfpixel.x, -halfpixel.y));
    sum += texture(u_glow_tex, v_uv + vec2( halfpixel.x, -halfpixel.y));
    sum += texture(u_glow_tex, v_uv + vec2(-halfpixel.x,  halfpixel.y));
    sum += texture(u_glow_tex, v_uv + vec2( halfpixel.x,  halfpixel.y));
    frag_color = sum / 8.0;
}

#endif // FRAGMENT_SHADER_KAWASE_DOWN

// ============================================================================
// Dual Kawase Upsample (9 taps)
// ============================================================================
#ifdef FRAGMENT_SHADER_KAWASE_UP

in vec2 v_uv;
uniform sampler2D u_glow_tex;
layout(location = 0) out vec4 frag_color;

void main() {
    vec2 tex_size = vec2(textureSize(u_glow_tex, 0));
    vec2 halfpixel = 0.5 / tex_size;

    vec4 sum = vec4(0.0);
    sum += texture(u_glow_tex, v_uv + vec2(-halfpixel.x * 2.0, 0.0));
    sum += texture(u_glow_tex, v_uv + vec2(-halfpixel.x,  halfpixel.y)) * 2.0;
    sum += texture(u_glow_tex, v_uv + vec2(0.0,  halfpixel.y * 2.0));
    sum += texture(u_glow_tex, v_uv + vec2( halfpixel.x,  halfpixel.y)) * 2.0;
    sum += texture(u_glow_tex, v_uv + vec2( halfpixel.x * 2.0, 0.0));
    sum += texture(u_glow_tex, v_uv + vec2( halfpixel.x, -halfpixel.y)) * 2.0;
    sum += texture(u_glow_tex, v_uv + vec2(0.0, -halfpixel.y * 2.0));
    sum += texture(u_glow_tex, v_uv + vec2(-halfpixel.x, -halfpixel.y)) * 2.0;
    frag_color = sum / 12.0;
}

#endif // FRAGMENT_SHADER_KAWASE_UP

// ============================================================================
// Glow Composite Fragment Shader
// ============================================================================
#ifdef FRAGMENT_SHADER_GLOW_COMPOSITE

in vec2 v_uv;
uniform sampler2D u_glow_tex;
uniform float u_glow_intensity;

layout(location = 0) out vec4 frag_color;

void main() {
    frag_color = texture(u_glow_tex, v_uv) * u_glow_intensity;
}

#endif // FRAGMENT_SHADER_GLOW_COMPOSITE
