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

// Icon type markers (special uv.x values)
#define ICON_CIRCLE      (-2.0)
#define ICON_CHEVRON     (-3.0)
#define ICON_HANDLE      (-4.0)

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
