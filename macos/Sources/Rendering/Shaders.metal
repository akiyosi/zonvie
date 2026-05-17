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
#define DECO_GLOW          (1u << 9)
#define DECO_COLOR_EMOJI   (1u << 10)

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
                     constant uint& scrollOffsetCount [[buffer(2)]],
                     constant float& rowTranslationY [[buffer(3)]]) {
    VSOut o;
    float2 pos = in.position;

    // Apply row translation first so scroll boundary pin checks compare
    // against the logical row position, not the source row position.
    // Without this, remapped rows (from on_main_row_scroll) fail the
    // content_top_y / content_bottom_y pin test during smooth scrolling,
    // causing edge rows to be clipped instead of stretched.
    pos.y += rowTranslationY;

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

    // Color emoji: sample RGBA directly (premultiplied alpha)
    if (in.deco_flags & DECO_COLOR_EMOJI) {
        float4 emoji = tex.sample(samp, uv);
        return float4(emoji.rgb, emoji.a);
    }

    // Grayscale glyph: RGBA atlas stores coverage in .r (all channels equal)
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

    // Discard glow quads (rendered in glyph pass, not background pass)
    if (in.deco_flags & DECO_GLOW) {
        discard_fragment();
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

    // Color emoji: sample RGBA directly
    if (in.deco_flags & DECO_COLOR_EMOJI) {
        float4 emoji = tex.sample(samp, uv);
        return float4(emoji.rgb, emoji.a);
    }

    // Grayscale glyph: coverage in .r
    float cov = tex.sample(samp, uv).r;
    return float4(in.color.rgb, in.color.a * cov);
}

// ============================================================================
// Unified single-pass shader for blur backgrounds via programmable blending
// ============================================================================
// Replaces the ps_background + ps_glyph 2-pass rendering. Tile memory access
// via [[color(0), raster_order_group(0)]] lets the fragment shader read the
// already-written pixel from the same render pass and do alpha blending in
// shader code. With pipeline blend disabled (one, zero) the output is written
// straight to the tile, matching the previous 2-pass result without doubling
// fragment shader invocations from the discard pattern of two-pass overdraw.
//
// Vertex submission order (bg → underline → glyph → strike → overline) is
// preserved by raster_order_group, so glyph/decoration fragments observe the
// already-written background color when they read the tile.
fragment float4 ps_unified_blur(VSOut in [[stage_in]],
                                 float4 current [[color(0), raster_order_group(0)]],
                                 texture2d<float> tex [[texture(0)]],
                                 sampler samp [[sampler(0)]],
                                 constant DrawableSize& drawableSize [[buffer(0)]],
                                 constant float& backgroundAlpha [[buffer(1)]],
                                 constant uint& cursorBlinkVisible [[buffer(2)]]) {
    // ── Common discards (apply to every quad type) ─────────────────────
    if ((in.deco_flags & DECO_CURSOR) && cursorBlinkVisible == 0) {
        discard_fragment();
    }
    float ndc_y = 1.0 - (in.position.y / drawableSize.height) * 2.0;
    if (in.was_content > 0.5) {
        if (ndc_y > in.content_top_y || ndc_y < in.content_bottom_y) {
            discard_fragment();
        }
    }

    // ── Branch by quad type ─────────────────────────────────────────────
    // - bg-only quad: uv.x < 0, no visual decoration, no glow flag
    // - decoration quad: uv.x < 0, visual decoration flag set
    // - glyph quad: uv.x >= 0 (atlas sample) — also catches glow quads that
    //   carry an atlas UV
    // - solid-color glow quad: glow flag set, treated as alpha-blended layer
    bool is_bg = (in.uv.x < 0.0)
                 && ((in.deco_flags & DECO_VISUAL_MASK) == 0)
                 && ((in.deco_flags & DECO_GLOW) == 0);

    if (is_bg) {
        // Background path: overwrite tile with new bg color (matches the
        // previous (one, zero) blend behavior of ps_background).
        if (backgroundAlpha <= 0.0) {
            // Same semantics as ps_background's discard: don't paint over
            // the underlying NSVisualEffectView. Returning `current` keeps
            // tile content untouched under our overwrite-blend pipeline.
            return current;
        }
        if (backgroundAlpha >= 1.0) {
            return float4(in.color.rgb, 1.0);
        }
        return float4(in.color.rgb, backgroundAlpha);
    }

    bool is_decoration = (in.uv.x < 0.0) && ((in.deco_flags & DECO_VISUAL_MASK) != 0);
    if (is_decoration) {
        // Compute the decoration's source color the same way ps_glyph does,
        // then manually alpha-blend onto the already-written bg tile pixel.
        float4 deco;
        if (in.deco_flags & DECO_UNDERCURL) {
            float wave_freq = 3.14159265 * 2.0;
            float wave_amp = 0.35;
            float cell_width = 8.0;
            float wave_x = (in.position.x / cell_width) + in.deco_phase;
            float wave_y = sin(wave_x * wave_freq) * wave_amp;
            float local_y = in.uv.y;
            float dist = abs(local_y - (0.5 + wave_y));
            if (dist > 0.25) {
                return current;  // outside the curve → preserve tile
            }
            float a = 1.0 - smoothstep(0.0, 0.25, dist);
            deco = float4(in.color.rgb, in.color.a * a);
        } else if (in.deco_flags & DECO_UNDERDOTTED) {
            float x_mod = fmod(in.position.x, 4.0);
            if (x_mod >= 2.0) {
                return current;
            }
            deco = in.color;
        } else if (in.deco_flags & DECO_UNDERDASHED) {
            float x_mod = fmod(in.position.x, 8.0);
            if (x_mod >= 5.0) {
                return current;
            }
            deco = in.color;
        } else if (in.deco_flags & DECO_UNDERDOUBLE) {
            float local_y = in.uv.y;
            float line_thickness = 0.15;
            float dist1 = abs(local_y - 0.2);
            float dist2 = abs(local_y - 0.8);
            if (dist1 > line_thickness && dist2 > line_thickness) {
                return current;
            }
            deco = in.color;
        } else {
            // solid line: underline / strikethrough / overline / cursor
            deco = in.color;
        }
        float a = deco.a;
        return float4(mix(current.rgb, deco.rgb, a), a + current.a * (1.0 - a));
    }

    // Glyph (or atlas-textured glow) quad: sample atlas, manual alpha blend.
    float2 uv = in.uv;
    float4 src;
    if (in.deco_flags & DECO_COLOR_EMOJI) {
        float4 emoji = tex.sample(samp, uv);
        src = float4(emoji.rgb, emoji.a);
    } else {
        float cov = tex.sample(samp, uv).r;
        src = float4(in.color.rgb, in.color.a * cov);
    }
    float a = src.a;
    return float4(mix(current.rgb, src.rgb, a), a + current.a * (1.0 - a));
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

// Vertex shader paired with user-supplied fragment shaders compiled from
// GLSL via glslang + SPIRV-Cross. SPIRV-Cross emits fragment inputs with
// explicit `[[user(locnN)]]` attributes derived from `layout(location=N)` in
// GLSL, so we must match that convention here instead of reusing `vs_copy`
// (whose `uv` field has no explicit location).
struct CustomPostVSOut {
    float4 position [[position]];
    float2 vUV [[user(locn0)]];
};

vertex CustomPostVSOut vs_custom_post(CopyVertexIn in [[stage_in]]) {
    CustomPostVSOut out;
    out.position = float4(in.position, 0.0, 1.0);
    out.vUV = in.texCoord;
    return out;
}

// ============================================================================
// Post-Process Bloom Shaders (Neon Glow)
// ============================================================================
// Bloom pipeline: extract → Dual Kawase downsample/upsample → composite (additive)
// Uses progressive mip chain (1/4 → 1/32) for smooth, grid-pattern-free blur.
// ============================================================================

/// Glow extract: render only DECO_GLOW glyphs with their original foreground color.
/// Non-glow vertices and non-glyph vertices are discarded.
/// Output is premultiplied alpha (color.rgb * coverage, coverage).
///
/// No scroll clipping here — unlike ps_main, the bloom blur naturally fades
/// glow at edges, so hard-clipping at content bounds creates unnatural seams
/// at margin/grid boundaries (especially visible on cmdline and float windows).
fragment float4 ps_glow_extract(VSOut in [[stage_in]],
                                 texture2d<float> tex [[texture(0)]],
                                 sampler samp [[sampler(0)]]) {
    // Only extract DECO_GLOW flagged glyphs
    if (!(in.deco_flags & DECO_GLOW)) discard_fragment();
    // Skip non-glyph quads (backgrounds/decorations have uv.x < 0)
    if (in.uv.x < 0.0) discard_fragment();

    // Color emoji: use texture color directly
    if (in.deco_flags & DECO_COLOR_EMOJI) {
        float4 emoji = tex.sample(samp, in.uv);
        return float4(emoji.rgb, emoji.a);
    }

    float cov = tex.sample(samp, in.uv).r;
    return float4(in.color.rgb * cov, cov);
}

/// Dual Kawase downsample (5 taps).
/// Each pass halves resolution, progressively eliminating grid patterns.
fragment float4 ps_kawase_down(CopyVSOut in [[stage_in]],
                                texture2d<float> src [[texture(0)]],
                                sampler samp [[sampler(0)]]) {
    float2 halfpixel = 0.5 / float2(src.get_width(), src.get_height());

    float4 sum = src.sample(samp, in.uv) * 4.0;
    sum += src.sample(samp, in.uv + float2(-halfpixel.x, -halfpixel.y));
    sum += src.sample(samp, in.uv + float2( halfpixel.x, -halfpixel.y));
    sum += src.sample(samp, in.uv + float2(-halfpixel.x,  halfpixel.y));
    sum += src.sample(samp, in.uv + float2( halfpixel.x,  halfpixel.y));
    return sum / 8.0;
}

/// Dual Kawase upsample (9 taps).
/// Each pass doubles resolution, accumulating smooth blur.
fragment float4 ps_kawase_up(CopyVSOut in [[stage_in]],
                              texture2d<float> src [[texture(0)]],
                              sampler samp [[sampler(0)]]) {
    float2 halfpixel = 0.5 / float2(src.get_width(), src.get_height());

    float4 sum = 0;
    sum += src.sample(samp, in.uv + float2(-halfpixel.x * 2.0, 0.0));
    sum += src.sample(samp, in.uv + float2(-halfpixel.x,  halfpixel.y)) * 2.0;
    sum += src.sample(samp, in.uv + float2(0.0,  halfpixel.y * 2.0));
    sum += src.sample(samp, in.uv + float2( halfpixel.x,  halfpixel.y)) * 2.0;
    sum += src.sample(samp, in.uv + float2( halfpixel.x * 2.0, 0.0));
    sum += src.sample(samp, in.uv + float2( halfpixel.x, -halfpixel.y)) * 2.0;
    sum += src.sample(samp, in.uv + float2(0.0, -halfpixel.y * 2.0));
    sum += src.sample(samp, in.uv + float2(-halfpixel.x, -halfpixel.y)) * 2.0;
    return sum / 12.0;
}

/// Glow composite: blend blurred glow onto back buffer with additive blending.
/// Pipeline uses additive blend state (ONE, ONE).
fragment float4 ps_glow_composite(CopyVSOut in [[stage_in]],
                                   texture2d<float> src [[texture(0)]],
                                   sampler samp [[sampler(0)]],
                                   constant float& intensity [[buffer(0)]]) {
    return src.sample(samp, in.uv) * intensity;
}
