#pragma once
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Opaque handle that owns FreeType + HarfBuzz objects.
typedef struct zonvie_ft_hb_font zonvie_ft_hb_font;

// face_index is the TTC/collection face index (CoreText kCTFontIndexAttribute).
zonvie_ft_hb_font* zonvie_ft_hb_font_create(const uint8_t* font_bytes, size_t font_len, uint32_t pixel_size, uint32_t face_index);
void zonvie_ft_hb_font_destroy(zonvie_ft_hb_font* f);

// Shape UTF-32 scalars.
// Outputs are HarfBuzz position values in 26.6 fixed-point pixels (1px = 64).
// Returns glyph_count written to outputs (<= out_cap). If out_cap is too small, returns needed count.
size_t zonvie_hb_shape_utf32(
    zonvie_ft_hb_font* f,
    const uint32_t* scalars,
    size_t scalar_count,
    uint32_t* out_glyph_ids,
    uint32_t* out_clusters,      // NEW: hb_glyph_info_t.cluster (input index)
    int32_t* out_x_advance,
    int32_t* out_y_advance,
    int32_t* out_x_offset,
    int32_t* out_y_offset,
    size_t out_cap,
    int32_t* out_font_ascender,
    int32_t* out_font_descender,
    int32_t* out_font_height
);

// Render a glyph to an 8-bit grayscale bitmap (FT_RENDER_MODE_NORMAL).
// The returned buffer pointer is valid until the next render call on the same font handle.
int zonvie_ft_render_glyph(
    zonvie_ft_hb_font* f,
    uint32_t glyph_id,
    const uint8_t** out_buffer,
    int* out_width,
    int* out_height,
    int* out_pitch,
    int* out_left,
    int* out_top,
    int32_t* out_advance_x_26_6
);

#ifdef __cplusplus
}
#endif

