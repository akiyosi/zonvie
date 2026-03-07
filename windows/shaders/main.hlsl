// Zonvie main shader
// Compile with: fxc /T vs_5_0 /E VSMain /Fo vs_main.cso main.hlsl
//               fxc /T ps_5_0 /E PSMain /Fo ps_main.cso main.hlsl

struct VSIn {
    float2 pos : POSITION;   // NDC (-1..1)
    float2 uv  : TEXCOORD0;
    float4 col : COLOR0;
    int2 grid_id : BLENDINDICES0;  // i64 as int2
    uint deco_flags : BLENDINDICES1;
    float deco_phase : TEXCOORD1;
};

struct VSOut {
    float4 pos : SV_Position;
    float2 uv  : TEXCOORD0;
    float4 col : COLOR0;
    uint deco_flags : BLENDINDICES0;
    float deco_phase : TEXCOORD1;
};

VSOut VSMain(VSIn i) {
    VSOut o;
    o.pos = float4(i.pos.xy, 0.0, 1.0);
    o.uv  = i.uv;
    o.col = i.col;
    o.deco_flags = i.deco_flags;
    o.deco_phase = i.deco_phase;
    return o;
}

Texture2D atlasTex : register(t0);
SamplerState samp0 : register(s0);

#define DECO_UNDERCURL     (1u << 0)
#define DECO_UNDERLINE     (1u << 1)
#define DECO_UNDERDOUBLE   (1u << 2)
#define DECO_UNDERDOTTED   (1u << 3)
#define DECO_UNDERDASHED   (1u << 4)
#define DECO_STRIKETHROUGH (1u << 5)
#define DECO_OVERLINE      (1u << 8)
#define DECO_GLOW          (1u << 9)

// Icon type markers (special uv.x values)
#define ICON_CIRCLE      (-2.0)
#define ICON_CHEVRON     (-3.0)
#define ICON_HANDLE      (-4.0)
#define TABLINE_TEXTURE  (-5.0)  // BGRA texture sampling mode

// Premultiply helper for consistent blending
float4 premultiply(float4 c) {
    return float4(c.rgb * c.a, c.a);
}

// DirectWrite gamma correction (from Windows Terminal)
// Gamma 1.8 ratios
static const float4 gammaRatios = float4(0.148054421, -0.894594550, 1.47590804, -0.324668258);

float DWrite_EnhanceContrast(float a, float k) {
    return a * (k + 1.0) / (a * k + 1.0);
}

float DWrite_ApplyAlphaCorrection(float a, float f, float4 g) {
    return a + a * (1.0 - a) * ((g.x * f + g.y) * a + (g.z * f + g.w));
}

float DWrite_CalcColorIntensity(float3 c) {
    return dot(c, float3(0.30, 0.59, 0.11));
}

float DWrite_ApplyLightOnDarkContrastAdjustment(float k, float3 c) {
    return k * saturate(dot(c, float3(0.30, 0.59, 0.11) * -4.0) + 3.0);
}

// SDF helper: circle
float sdCircle(float2 p, float radius) {
    return length(p) - radius;
}

// SDF helper: line segment distance
float sdSegment(float2 p, float2 a, float2 b) {
    float2 pa = p - a;
    float2 ba = b - a;
    float h = saturate(dot(pa, ba) / dot(ba, ba));
    return length(pa - ba * h);
}

// SDF helper: oriented box (for handle)
float sdOrientedBox(float2 p, float2 a, float2 b, float th) {
    float len = length(b - a);
    if (len < 0.001) return 1000.0; // Avoid division by zero
    float2 d = (b - a) / len;
    float2 q = p - (a + b) * 0.5;
    q = float2(dot(q, float2(d.y, -d.x)), dot(q, d));
    q = abs(q) - float2(th, len) * 0.5;
    return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0);
}

// Render icon with SDF + anti-aliasing
float4 renderIconSDF(float4 col, float sdf) {
    float aa = fwidth(sdf) * 1.5;
    float alpha = col.a * (1.0 - smoothstep(-aa, aa, sdf));
    return float4(col.rgb * alpha, alpha);
}

float4 PSMain(VSOut i) : SV_Target {
    // Tabline texture mode: sample BGRA texture directly
    if (i.uv.x <= TABLINE_TEXTURE + 0.1 && i.uv.x >= TABLINE_TEXTURE - 0.1) {
        // UV coordinates stored in (uv.y, deco_phase) for tabline texture
        float2 tablineUV = float2(i.uv.y, i.deco_phase);
        float4 tex = atlasTex.Sample(samp0, tablineUV);
        // BGRA texture: return as-is with premultiplied alpha
        return float4(tex.rgb * tex.a, tex.a);
    }

    // Background quads use sentinel uv.x < 0 in current vertexgen.
    // For decorations, uv.y contains the local Y position within the quad (0.0 at top, 1.0 at bottom)
    if (i.uv.x < 0.0) {
        // Icon rendering with SDF (uv.x <= -1.9)
        // Local UV: uv.y = local_x (0-1), deco_phase = local_y (0-1)
        if (i.uv.x <= ICON_CIRCLE + 0.1) {
            float2 localUV = float2(i.uv.y, i.deco_phase);

            // Circle icon (magnifying glass lens)
            if (i.uv.x >= ICON_CIRCLE - 0.1) {
                float2 center = float2(0.42, 0.42);
                float radius = 0.32;
                float sdf = sdCircle(localUV - center, radius);
                return renderIconSDF(i.col, sdf);
            }
            // Chevron icon (>)
            if (i.uv.x >= ICON_CHEVRON - 0.1 && i.uv.x <= ICON_CHEVRON + 0.1) {
                float2 tip = float2(0.75, 0.5);
                float2 topLeft = float2(0.25, 0.2);
                float2 botLeft = float2(0.25, 0.8);
                float thickness = 0.08;
                float d1 = sdSegment(localUV, topLeft, tip) - thickness;
                float d2 = sdSegment(localUV, botLeft, tip) - thickness;
                float sdf = min(d1, d2);
                return renderIconSDF(i.col, sdf);
            }
            // Handle icon (rotated rectangle)
            if (i.uv.x >= ICON_HANDLE - 0.1 && i.uv.x <= ICON_HANDLE + 0.1) {
                float2 start = float2(0.5, 0.5);
                float2 endpt = float2(0.92, 0.92);
                float thickness = 0.12;
                float sdf = sdOrientedBox(localUV, start, endpt, thickness);
                return renderIconSDF(i.col, sdf);
            }
        }

        // Handle decorations
        if (i.deco_flags != 0) {
            // Undercurl: sine wave
            if (i.deco_flags & DECO_UNDERCURL) {
                float wave_freq = 3.14159265 * 2.0;
                float wave_amp = 0.35;  // Normalized amplitude (0-1 range for quad height)
                float cell_width = 8.0;
                float wave_x = (i.pos.x / cell_width) + i.deco_phase;
                float wave_y = sin(wave_x * wave_freq) * wave_amp;
                // Local Y from UV (0.0 at top, 1.0 at bottom), wave center at 0.5
                float local_y = i.uv.y;
                float wave_center = 0.5 + wave_y;
                float dist = abs(local_y - wave_center);
                // Line thickness ~0.15 in normalized coordinates
                if (dist > 0.25) {
                    discard;
                }
                float alpha = i.col.a * (1.0 - smoothstep(0.0, 0.25, dist));
                return float4(i.col.rgb * alpha, alpha);
            }
            // Underdotted: dotted pattern
            if (i.deco_flags & DECO_UNDERDOTTED) {
                float x_mod = fmod(i.pos.x, 4.0);
                if (x_mod >= 2.0) {
                    discard;
                }
                return premultiply(i.col);
            }
            // Underdashed: dashed pattern
            if (i.deco_flags & DECO_UNDERDASHED) {
                float x_mod = fmod(i.pos.x, 8.0);
                if (x_mod >= 5.0) {
                    discard;
                }
                return premultiply(i.col);
            }
            // Underdouble: two parallel lines
            if (i.deco_flags & DECO_UNDERDOUBLE) {
                float local_y = i.uv.y;  // 0.0 at top, 1.0 at bottom
                // Draw two lines: one at ~0.2 and one at ~0.8 of the quad height
                float line1_center = 0.2;
                float line2_center = 0.8;
                float line_thickness = 0.15;
                float dist1 = abs(local_y - line1_center);
                float dist2 = abs(local_y - line2_center);
                // Keep pixel if it's close to either line
                if (dist1 > line_thickness && dist2 > line_thickness) {
                    discard;
                }
                return premultiply(i.col);
            }
            // Underline, strikethrough: solid line
            return premultiply(i.col);
        }
        // Regular solid color (background)
        return premultiply(i.col);
    }
    // Grayscale rendering with DirectWrite gamma correction (Windows Terminal style)
    float4 foreground = premultiply(i.col);
    float enhancedContrast = 1.0; // Default contrast boost
    float blendEnhancedContrast = DWrite_ApplyLightOnDarkContrastAdjustment(enhancedContrast, i.col.rgb);
    float intensity = DWrite_CalcColorIntensity(i.col.rgb);
    float4 tex = atlasTex.Sample(samp0, i.uv);
    // Use luminance of RGB for grayscale alpha
    float glyph_a = dot(tex.rgb, float3(0.299, 0.587, 0.114));
    float contrasted = DWrite_EnhanceContrast(glyph_a, blendEnhancedContrast);
    float alphaCorrected = DWrite_ApplyAlphaCorrection(contrasted, intensity, gammaRatios);
    return alphaCorrected * foreground;
}

// ============================================================================
// Post-Process Bloom Shaders (Neon Glow)
// ============================================================================
// Bloom pipeline: extract → Dual Kawase downsample/upsample → composite (additive)
// Uses progressive mip chain (1/4 → 1/32) for smooth, grid-pattern-free blur.
// ============================================================================

// Fullscreen triangle vertex shader (no vertex buffer needed, use Draw(3,0))
struct FSQuadVSOut {
    float4 pos : SV_Position;
    float2 uv  : TEXCOORD0;
};

FSQuadVSOut VSFullscreen(uint id : SV_VertexID) {
    FSQuadVSOut o;
    // Oversize triangle trick: 3 vertices cover entire screen
    float2 uv = float2((id << 1) & 2, id & 2);
    o.pos = float4(uv * float2(2, -2) + float2(-1, 1), 0, 1);
    o.uv = uv;
    return o;
}

// Glow extract: render only DECO_GLOW glyphs with original foreground color.
// Non-glow vertices and non-glyph vertices are discarded.
// Output is premultiplied alpha.
float4 PSGlowExtract(VSOut i) : SV_Target {
    // Only extract DECO_GLOW flagged glyphs
    if (!(i.deco_flags & DECO_GLOW)) discard;
    // Skip non-glyph quads (backgrounds/decorations have uv.x < 0)
    if (i.uv.x < 0.0) discard;

    float4 tex = atlasTex.Sample(samp0, i.uv);
    float cov = dot(tex.rgb, float3(0.299, 0.587, 0.114));
    return float4(i.col.rgb * cov, cov);
}

// Glow texture + sampler (register t1/s1 to avoid conflict with atlas t0/s0)
Texture2D glowTex : register(t1);
SamplerState glowSamp : register(s1);

// Dual Kawase downsample (5 taps)
float4 PSKawaseDown(FSQuadVSOut i) : SV_Target {
    uint w, h;
    glowTex.GetDimensions(w, h);
    float2 halfpixel = 0.5 / float2(w, h);

    float4 sum = glowTex.Sample(glowSamp, i.uv) * 4.0;
    sum += glowTex.Sample(glowSamp, i.uv + float2(-halfpixel.x, -halfpixel.y));
    sum += glowTex.Sample(glowSamp, i.uv + float2( halfpixel.x, -halfpixel.y));
    sum += glowTex.Sample(glowSamp, i.uv + float2(-halfpixel.x,  halfpixel.y));
    sum += glowTex.Sample(glowSamp, i.uv + float2( halfpixel.x,  halfpixel.y));
    return sum / 8.0;
}

// Dual Kawase upsample (9 taps)
float4 PSKawaseUp(FSQuadVSOut i) : SV_Target {
    uint w, h;
    glowTex.GetDimensions(w, h);
    float2 halfpixel = 0.5 / float2(w, h);

    float4 sum = 0;
    sum += glowTex.Sample(glowSamp, i.uv + float2(-halfpixel.x * 2.0, 0.0));
    sum += glowTex.Sample(glowSamp, i.uv + float2(-halfpixel.x,  halfpixel.y)) * 2.0;
    sum += glowTex.Sample(glowSamp, i.uv + float2(0.0,  halfpixel.y * 2.0));
    sum += glowTex.Sample(glowSamp, i.uv + float2( halfpixel.x,  halfpixel.y)) * 2.0;
    sum += glowTex.Sample(glowSamp, i.uv + float2( halfpixel.x * 2.0, 0.0));
    sum += glowTex.Sample(glowSamp, i.uv + float2( halfpixel.x, -halfpixel.y)) * 2.0;
    sum += glowTex.Sample(glowSamp, i.uv + float2(0.0, -halfpixel.y * 2.0));
    sum += glowTex.Sample(glowSamp, i.uv + float2(-halfpixel.x, -halfpixel.y)) * 2.0;
    return sum / 12.0;
}

// Glow composite: blend blurred glow onto back buffer with additive blending.
// Pipeline uses additive blend state (ONE, ONE), so we just scale by intensity.
cbuffer GlowParams : register(b0) {
    float glowIntensity;
    float3 _pad;
};

float4 PSGlowComposite(FSQuadVSOut i) : SV_Target {
    return glowTex.Sample(glowSamp, i.uv) * glowIntensity;
}
