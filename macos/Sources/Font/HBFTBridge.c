#include "../../../include/zonvie_hbft.h"

#include <stdlib.h>
#include <string.h>

#include <ft2build.h>
#include FT_FREETYPE_H

#include </opt/homebrew/include/harfbuzz/hb.h>
#include </opt/homebrew/include/harfbuzz/hb-ft.h>

struct zonvie_ft_hb_font {
  FT_Library ft_lib;
  FT_Face ft_face;

  hb_font_t* hb_font;
  hb_buffer_t* hb_buf;

  uint8_t* font_bytes_owned;
  size_t font_len;

  // Last rendered glyph bitmap is owned by FreeType (ft_face->glyph->bitmap).
};

zonvie_ft_hb_font* zonvie_ft_hb_font_create(const uint8_t* font_bytes, size_t font_len, uint32_t pixel_size, uint32_t face_index) {
  if (!font_bytes || font_len == 0 || pixel_size == 0) return NULL;

  zonvie_ft_hb_font* f = (zonvie_ft_hb_font*)calloc(1, sizeof(*f));
  if (!f) return NULL;

  f->font_bytes_owned = (uint8_t*)malloc(font_len);
  if (!f->font_bytes_owned) { free(f); return NULL; }
  memcpy(f->font_bytes_owned, font_bytes, font_len);
  f->font_len = font_len;

  if (FT_Init_FreeType(&f->ft_lib) != 0) goto fail;

  // IMPORTANT: use face_index (TTC / collection face index)
  if (FT_New_Memory_Face(
        f->ft_lib,
        f->font_bytes_owned,
        (FT_Long)f->font_len,
        (FT_Long)face_index,
        &f->ft_face
      ) != 0) goto fail;

  // Use pixel size directly (already scaled by backingScale on Swift side).
  if (FT_Set_Pixel_Sizes(f->ft_face, 0, pixel_size) != 0) goto fail;

  f->hb_font = hb_ft_font_create_referenced(f->ft_face);
  if (!f->hb_font) goto fail;

  // Make HarfBuzz positions come out in 26.6 pixel units.
  hb_font_set_scale(f->hb_font, (int)(pixel_size * 64), (int)(pixel_size * 64));
  hb_ft_font_set_load_flags(f->hb_font, FT_LOAD_DEFAULT);

  f->hb_buf = hb_buffer_create();
  if (!f->hb_buf) goto fail;

  return f;

fail:
  zonvie_ft_hb_font_destroy(f);
  return NULL;
}

void zonvie_ft_hb_font_destroy(zonvie_ft_hb_font* f) {
  if (!f) return;

  if (f->hb_buf) hb_buffer_destroy(f->hb_buf);
  if (f->hb_font) hb_font_destroy(f->hb_font);

  if (f->ft_face) FT_Done_Face(f->ft_face);
  if (f->ft_lib) FT_Done_FreeType(f->ft_lib);

  if (f->font_bytes_owned) free(f->font_bytes_owned);
  free(f);
}

size_t zonvie_hb_shape_utf32(
    zonvie_ft_hb_font* f,
    const uint32_t* scalars,
    size_t scalar_count,
    uint32_t* out_glyph_ids,
    uint32_t* out_clusters,
    int32_t* out_x_advance,
    int32_t* out_y_advance,
    int32_t* out_x_offset,
    int32_t* out_y_offset,
    size_t out_cap,
    int32_t* out_font_ascender,
    int32_t* out_font_descender,
    int32_t* out_font_height
) {
  if (!f || !f->hb_font || !f->hb_buf) return 0;

  // NEW: export font v-metrics (26.6 px) if requested.
  if (f->ft_face && f->ft_face->size) {
    FT_Size_Metrics m = f->ft_face->size->metrics;
    if (out_font_ascender)  *out_font_ascender  = (int32_t)m.ascender;   // 26.6 px
    if (out_font_descender) *out_font_descender = (int32_t)m.descender;  // typically negative
    if (out_font_height)    *out_font_height    = (int32_t)m.height;     // includes line gap
  }

  // Allow "metrics-only" call: no shaping.
  if (!scalars || scalar_count == 0 || out_cap == 0) return 0;

  hb_buffer_clear_contents(f->hb_buf);
  hb_buffer_add_codepoints(f->hb_buf, scalars, (int)scalar_count, 0, (int)scalar_count);
  hb_buffer_guess_segment_properties(f->hb_buf);

  hb_shape(f->hb_font, f->hb_buf, NULL, 0);

  unsigned int glyph_count = 0;
  hb_glyph_info_t* infos = hb_buffer_get_glyph_infos(f->hb_buf, &glyph_count);
  hb_glyph_position_t* poss = hb_buffer_get_glyph_positions(f->hb_buf, &glyph_count);

  if (glyph_count > out_cap) {
    return (size_t)glyph_count; // signal "needed"
  }

  for (unsigned int i = 0; i < glyph_count; i++) {
    out_glyph_ids[i] = infos[i].codepoint;
    if (out_clusters) out_clusters[i] = infos[i].cluster;
    out_x_advance[i] = poss[i].x_advance;
    out_y_advance[i] = poss[i].y_advance;
    out_x_offset[i]  = poss[i].x_offset;
    out_y_offset[i]  = poss[i].y_offset;
  }
  return (size_t)glyph_count;
}

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
) {
  if (!f || !f->ft_face) return -1;

  if (FT_Load_Glyph(f->ft_face, glyph_id, FT_LOAD_DEFAULT) != 0) return -2;
  if (FT_Render_Glyph(f->ft_face->glyph, FT_RENDER_MODE_NORMAL) != 0) return -3;

  FT_GlyphSlot g = f->ft_face->glyph;
  FT_Bitmap* bm = &g->bitmap;

  if (out_buffer) *out_buffer = (const uint8_t*)bm->buffer;
  if (out_width)  *out_width  = (int)bm->width;
  if (out_height) *out_height = (int)bm->rows;
  if (out_pitch)  *out_pitch  = (int)bm->pitch;
  if (out_left)   *out_left   = (int)g->bitmap_left;
  if (out_top)    *out_top    = (int)g->bitmap_top;
  if (out_advance_x_26_6) *out_advance_x_26_6 = (int32_t)g->advance.x;

  return 0;
}

