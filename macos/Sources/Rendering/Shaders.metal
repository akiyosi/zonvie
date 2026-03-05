#include <metal_stdlib>
using namespace metal;

// Decoration flags (must match ZONVIE_DECO_* in zonvie_core.h)
#define DECO_UNDERCURL     (1u << 0)
#define DECO_UNDERLINE     (1u << 1)
#define DECO_UNDERDOUBLE   (1u << 2)
#define DECO_UNDERDOTTED   (1u << 3)
#define DECO_UNDERDASHED   (1u << 4)
#define DECO_STRIKETHROUGH (1u << 5)
#define DECO_CURSOR        (1u << 6)
#define DECO_SCROLLABLE    (1u << 7)
#define DECO_OVERLINE      (1u << 8)

// Mask for visual decoration flags (excludes transport-only flags like SCROLLABLE)
#define DECO_VISUAL_MASK (DECO_UNDERCURL | DECO_UNDERLINE | DECO_UNDERDOUBLE | DECO_UNDERDOTTED | DECO_UNDERDASHED | DECO_STRIKETHROUGH | DECO_CURSOR | DECO_OVERLINE)

struct VertexIn {
    float2 position [[attribute(0)]];
    float2 texCoord [[attribute(1)]];
    float4 color    [[attribute(2)]];
    int grid_id [[attribute(3)]];  // grid_id for smooth scrolling
    uint deco_flags [[attribute(4)]];  // decoration flags
    float deco_phase [[attribute(5)]];  // phase for undercurl
};

struct VSOut {
    float4 position [[position]];
    float2 uv;
    float4 color;
    float content_top_y;    // Content area top bound in NDC (for clipping)
    float content_bottom_y; // Content area bottom bound in NDC (for clipping)
    float was_content;      // 1.0 if this vertex was in content area (scrollable), 0.0 if margin
    uint deco_flags;        // decoration flags
    float deco_phase;       // phase for undercurl
};

// Scroll offset for smooth scrolling (per grid)
struct ScrollOffset {
    int grid_id;
    float offset_y;         // Y offset in NDC
    float content_top_y;    // Top Y of scrollable content (below margin top), in NDC
    float content_bottom_y; // Bottom Y of scrollable content (above margin bottom), in NDC
};

// Drawable size for NDC conversion in fragment shader
struct DrawableSize {
    float width;
    float height;
};

vertex VSOut vs_main(VertexIn in [[stage_in]],
                     constant ScrollOffset* scrollOffsets [[buffer(1)]],
                     constant uint& scrollOffsetCount [[buffer(2)]]) {
    VSOut o;
    float2 pos = in.position;

    // Default: no clipping needed (content bounds cover entire screen)
    o.content_top_y = 2.0;     // Above screen
    o.content_bottom_y = -2.0; // Below screen
    o.was_content = 0.0;

    // Apply scroll offset for matching grid_id, using DECO_SCROLLABLE flag
    // instead of position-based bounds. The flag is set by the Zig core during
    // vertex generation for content rows (not margin rows like tabline/statusline).
    // This avoids quad deformation when glyph vertices extend beyond cell boundaries.
    for (uint i = 0; i < scrollOffsetCount; i++) {
        if (scrollOffsets[i].grid_id == in.grid_id) {
            // Pass content bounds to fragment shader for clipping
            o.content_top_y = scrollOffsets[i].content_top_y;
            o.content_bottom_y = scrollOffsets[i].content_bottom_y;

            // Only scroll vertices flagged as scrollable (content area, not margins)
            if (in.deco_flags & DECO_SCROLLABLE) {
                float offset = scrollOffsets[i].offset_y;

                // Check if this is a plain background quad (uv.x < 0, no deco/cursor flags).
                // Check visual decoration flags; if none set → plain background.
                bool is_plain_bg = (in.texCoord.x < 0.0) && ((in.deco_flags & DECO_VISUAL_MASK) == 0);

                if (is_plain_bg) {
                    // Background quads at content area edges: keep the boundary vertex
                    // pinned so the edge row stretches to fill the gap left by scrolling.
                    // This prevents transparent gaps at top/bottom during smooth scroll.
                    // Glyph/decoration vertices always scroll uniformly (no deformation).
                    if (offset > 0.0) {
                        // Scrolling up: gap at bottom → pin bottom-boundary vertex
                        bool at_bottom = abs(pos.y - scrollOffsets[i].content_bottom_y) < 0.001;
                        if (!at_bottom) {
                            pos.y += offset;
                        }
                    } else if (offset < 0.0) {
                        // Scrolling down: gap at top → pin top-boundary vertex
                        bool at_top = abs(pos.y - scrollOffsets[i].content_top_y) < 0.001;
                        if (!at_top) {
                            pos.y += offset;
                        }
                    }
                } else {
                    // Glyph/decoration: uniform scroll (no deformation)
                    pos.y += offset;
                }
                o.was_content = 1.0;
            }
            break;
        }
    }

    o.position = float4(pos, 0.0, 1.0);
    o.uv = in.texCoord;
    o.color = in.color;
    o.deco_flags = in.deco_flags;
    o.deco_phase = in.deco_phase;
    return o;
}

fragment float4 ps_main(VSOut in [[stage_in]],
                        texture2d<float> tex [[texture(0)]],
                        sampler samp [[sampler(0)]],
                        constant DrawableSize& drawableSize [[buffer(0)]],
                        constant float& backgroundAlpha [[buffer(1)]],
                        constant uint& cursorBlinkVisible [[buffer(2)]]) {

    // Discard cursor vertices when cursor blink is off
    if ((in.deco_flags & DECO_CURSOR) && cursorBlinkVisible == 0) {
        discard_fragment();
    }

    // Clip scrolled content that ends up in margin area
    // Convert fragment position from screen coords to NDC
    // screen.y is in pixels from top, NDC.y goes from +1 (top) to -1 (bottom)
    float ndc_y = 1.0 - (in.position.y / drawableSize.height) * 2.0;

    // If this fragment came from content area and is now in margin area, discard
    if (in.was_content > 0.5) {
        if (ndc_y > in.content_top_y || ndc_y < in.content_bottom_y) {
            discard_fragment();
        }
    }

    // Background quad marker: uv.x < 0 means "solid color" or decoration
    // For decorations, uv.y contains the local Y position within the quad (0.0 at top, 1.0 at bottom)
    if (in.uv.x < 0.0) {
        // Handle decorations (keep full alpha for decorations like underlines)
        // Check visual decoration flags (excludes transport-only SCROLLABLE flag).
        if ((in.deco_flags & DECO_VISUAL_MASK) != 0) {
            // Undercurl: sine wave
            if (in.deco_flags & DECO_UNDERCURL) {
                float wave_freq = 3.14159265 * 2.0;  // One full wave per cell
                float wave_amp = 0.35;  // Normalized amplitude (0-1 range for quad height)
                float cell_width = 8.0;

                // Calculate wave x position
                float wave_x = (in.position.x / cell_width) + in.deco_phase;
                float wave_y = sin(wave_x * wave_freq) * wave_amp;

                // Local Y from UV (0.0 at top, 1.0 at bottom), wave center at 0.5
                float local_y = in.uv.y;
                float wave_center = 0.5 + wave_y;
                float dist = abs(local_y - wave_center);

                // Line thickness ~0.25 in normalized coordinates
                if (dist > 0.25) {
                    discard_fragment();
                }
                float alpha = 1.0 - smoothstep(0.0, 0.25, dist);
                return float4(in.color.rgb, in.color.a * alpha);
            }

            // Underdotted: dotted pattern
            if (in.deco_flags & DECO_UNDERDOTTED) {
                float x_mod = fmod(in.position.x, 4.0);
                if (x_mod >= 2.0) {
                    discard_fragment();
                }
                return in.color;
            }

            // Underdashed: dashed pattern
            if (in.deco_flags & DECO_UNDERDASHED) {
                float x_mod = fmod(in.position.x, 8.0);
                if (x_mod >= 5.0) {
                    discard_fragment();
                }
                return in.color;
            }

            // Underdouble: two parallel lines
            if (in.deco_flags & DECO_UNDERDOUBLE) {
                float local_y = in.uv.y;  // 0.0 at top, 1.0 at bottom
                // Draw two lines: one at ~0.2 and one at ~0.8 of the quad height
                float line1_center = 0.2;
                float line2_center = 0.8;
                float line_thickness = 0.15;

                float dist1 = abs(local_y - line1_center);
                float dist2 = abs(local_y - line2_center);

                // Keep pixel if it's close to either line
                if (dist1 > line_thickness && dist2 > line_thickness) {
                    discard_fragment();
                }
                return in.color;
            }

            // Underline, strikethrough: solid line
            return in.color;
        }

        // Regular solid color (background)
        // When blur is disabled (backgroundAlpha >= 1.0), force opaque rendering
        if (backgroundAlpha >= 1.0) {
            return float4(in.color.rgb, 1.0);
        }
        // Blur enabled: use config opacity directly (ignore Zig-side alpha)
        return float4(in.color.rgb, backgroundAlpha);
    }

    // Do not flip V here (causes vertical flip)
    float2 uv = in.uv;

    // R8Unorm atlas => coverage in .r
    float cov = tex.sample(samp, uv).r;

    // Multiply alpha by coverage (text keeps full alpha)
    return float4(in.color.rgb, in.color.a * cov);
}

// ============================================================================
// 2-Pass Rendering Shaders for Blur Support
// ============================================================================
// Problem: When using .load with semi-transparent backgrounds (alpha=0.7),
// standard alpha blending causes ghosting: newBg * 0.7 + oldContent * 0.3
//
// Solution: Separate background and glyph rendering into two passes:
// - Pass 1 (ps_background): Draw backgrounds with overwrite blending (one, zero)
// - Pass 2 (ps_glyph): Draw glyphs with standard alpha blending
// ============================================================================

/// Background-only fragment shader.
/// Draws background quads (uv.x < 0) and discards glyphs/decorations.
/// Used with overwrite blending (one, zero) to avoid ghosting.
fragment float4 ps_background(VSOut in [[stage_in]],
                               texture2d<float> tex [[texture(0)]],
                               sampler samp [[sampler(0)]],
                               constant DrawableSize& drawableSize [[buffer(0)]],
                               constant float& backgroundAlpha [[buffer(1)]]) {

    // Clip scrolled content in margin area (same as ps_main)
    float ndc_y = 1.0 - (in.position.y / drawableSize.height) * 2.0;
    if (in.was_content > 0.5) {
        if (ndc_y > in.content_top_y || ndc_y < in.content_bottom_y) {
            discard_fragment();
        }
    }

    // Only process background quads (uv.x < 0 and no visual decoration flags)
    if (in.uv.x >= 0.0 || (in.deco_flags & DECO_VISUAL_MASK) != 0) {
        discard_fragment();
    }

    // If backgroundAlpha is 0, don't draw any background (fully transparent)
    // This allows underlying views (NSVisualEffectView/paddingView) to show through
    if (backgroundAlpha <= 0.0) {
        discard_fragment();
    }

    // Regular solid color background
    // When blur is disabled (backgroundAlpha >= 1.0), force opaque rendering
    if (backgroundAlpha >= 1.0) {
        return float4(in.color.rgb, 1.0);
    }
    // Blur enabled: use config opacity directly (ignore Zig-side alpha)
    return float4(in.color.rgb, backgroundAlpha);
}

/// Glyph-only fragment shader.
/// Draws glyphs (uv.x >= 0) and decorations, discards plain backgrounds.
/// Used with standard alpha blending for correct antialiasing.
fragment float4 ps_glyph(VSOut in [[stage_in]],
                          texture2d<float> tex [[texture(0)]],
                          sampler samp [[sampler(0)]],
                          constant DrawableSize& drawableSize [[buffer(0)]],
                          constant float& backgroundAlpha [[buffer(1)]],
                          constant uint& cursorBlinkVisible [[buffer(2)]]) {

    // Discard cursor vertices when cursor blink is off
    if ((in.deco_flags & DECO_CURSOR) && cursorBlinkVisible == 0) {
        discard_fragment();
    }

    // Clip scrolled content in margin area (same as ps_main)
    float ndc_y = 1.0 - (in.position.y / drawableSize.height) * 2.0;
    if (in.was_content > 0.5) {
        if (ndc_y > in.content_top_y || ndc_y < in.content_bottom_y) {
            discard_fragment();
        }
    }

    // Handle decorations (underlines, undercurl, etc.)
    if (in.uv.x < 0.0 && (in.deco_flags & DECO_VISUAL_MASK) != 0) {
        // Undercurl: sine wave
        if (in.deco_flags & DECO_UNDERCURL) {
            float wave_freq = 3.14159265 * 2.0;
            float wave_amp = 0.35;
            float cell_width = 8.0;
            float wave_x = (in.position.x / cell_width) + in.deco_phase;
            float wave_y = sin(wave_x * wave_freq) * wave_amp;
            float local_y = in.uv.y;
            float wave_center = 0.5 + wave_y;
            float dist = abs(local_y - wave_center);
            if (dist > 0.25) {
                discard_fragment();
            }
            float alpha = 1.0 - smoothstep(0.0, 0.25, dist);
            return float4(in.color.rgb, in.color.a * alpha);
        }

        // Underdotted: dotted pattern
        if (in.deco_flags & DECO_UNDERDOTTED) {
            float x_mod = fmod(in.position.x, 4.0);
            if (x_mod >= 2.0) {
                discard_fragment();
            }
            return in.color;
        }

        // Underdashed: dashed pattern
        if (in.deco_flags & DECO_UNDERDASHED) {
            float x_mod = fmod(in.position.x, 8.0);
            if (x_mod >= 5.0) {
                discard_fragment();
            }
            return in.color;
        }

        // Underdouble: two parallel lines
        if (in.deco_flags & DECO_UNDERDOUBLE) {
            float local_y = in.uv.y;
            float line1_center = 0.2;
            float line2_center = 0.8;
            float line_thickness = 0.15;
            float dist1 = abs(local_y - line1_center);
            float dist2 = abs(local_y - line2_center);
            if (dist1 > line_thickness && dist2 > line_thickness) {
                discard_fragment();
            }
            return in.color;
        }

        // Underline, strikethrough: solid line
        return in.color;
    }

    // Discard plain background quads (handled by ps_background)
    if (in.uv.x < 0.0) {
        discard_fragment();
    }

    // Glyph rendering: sample from atlas
    float2 uv = in.uv;
    float cov = tex.sample(samp, uv).r;
    return float4(in.color.rgb, in.color.a * cov);
}

// ============================================================================
// Fullscreen Quad Copy Shader (Blit Replacement)
// ============================================================================
// Used to copy backBuffer to drawable without MTLBlitCommandEncoder.
// This avoids XPC compiler service issues after fork() since render pipelines
// can be cached via MTLBinaryArchive, but blit shaders cannot.
// ============================================================================

struct CopyVertexIn {
    float2 position [[attribute(0)]];
    float2 texCoord [[attribute(1)]];
};

struct CopyVSOut {
    float4 position [[position]];
    float2 uv;
};

/// Simple vertex shader for fullscreen quad copy.
/// Takes normalized device coordinates directly (-1 to 1).
vertex CopyVSOut vs_copy(CopyVertexIn in [[stage_in]]) {
    CopyVSOut out;
    out.position = float4(in.position, 0.0, 1.0);
    out.uv = in.texCoord;
    return out;
}

/// Simple fragment shader for texture copy.
/// Samples source texture and outputs directly (no blending needed).
fragment float4 ps_copy(CopyVSOut in [[stage_in]],
                        texture2d<float> srcTexture [[texture(0)]],
                        sampler samp [[sampler(0)]]) {
    return srcTexture.sample(samp, in.uv);
}
