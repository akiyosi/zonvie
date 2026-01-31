// zonvie_msdf.h - C ABI wrapper for MSDF generation
// Part of Zonvie - High-performance Neovim GUI
//
// This wraps msdf_c (MIT License) for use from Swift/Zig frontends.

#pragma once

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

// Error codes
#define ZONVIE_MSDF_OK              0
#define ZONVIE_MSDF_ERR_INVALID_ARG 1
#define ZONVIE_MSDF_ERR_FONT_LOAD   2
#define ZONVIE_MSDF_ERR_NO_GLYPH    3
#define ZONVIE_MSDF_ERR_GENERATE    4

// Generate MSDF for a single glyph from TTF/OTF font data.
//
// Parameters:
//   ttf_data    - Pointer to TTF/OTF font file data
//   ttf_len     - Length of font data in bytes
//   codepoint   - Unicode codepoint to render
//   font_size   - Font em-height in pixels (controls glyph scale)
//   pixel_range - SDF pixel range (typically 4.0 for good quality)
//   width       - Output buffer width in pixels
//   height      - Output buffer height in pixels
//   out_rgb     - Output buffer for RGB data (must be width * height * 3 bytes)
//   out_metrics - Output metrics (may be NULL if not needed)
//
// Returns:
//   ZONVIE_MSDF_OK on success, error code otherwise.
//
// Notes:
//   - font_size controls glyph scaling (em-height), width/height are buffer dimensions
//   - The output is RGB where each channel encodes distance to an edge
//   - Use median(R,G,B) in shader to reconstruct signed distance
//   - Alpha channel is NOT used; caller should store separately if needed
int zonvie_msdf_generate(
    const uint8_t* ttf_data,
    size_t ttf_len,
    uint32_t codepoint,
    float font_size,         // font em-height in pixels (for consistent scaling)
    float pixel_range,
    int width,
    int height,
    uint8_t* out_rgb,
    float* out_advance,      // horizontal advance in pixels (may be NULL)
    float* out_left_bearing, // left side bearing in pixels (may be NULL)
    float* out_top_bearing   // top bearing (ascent from baseline) in pixels (may be NULL)
);

// Get font metrics for scaling calculations.
//
// Parameters:
//   ttf_data   - Pointer to TTF/OTF font file data
//   ttf_len    - Length of font data in bytes
//   pixel_size - Desired pixel size for metrics
//   out_ascent  - Output: ascent in pixels (may be NULL)
//   out_descent - Output: descent in pixels (may be NULL)
//   out_line_gap - Output: line gap in pixels (may be NULL)
//
// Returns:
//   ZONVIE_MSDF_OK on success, error code otherwise.
int zonvie_msdf_get_font_metrics(
    const uint8_t* ttf_data,
    size_t ttf_len,
    float pixel_size,
    float* out_ascent,
    float* out_descent,
    float* out_line_gap
);

#ifdef __cplusplus
}
#endif
