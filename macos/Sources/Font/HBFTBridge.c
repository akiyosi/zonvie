#include "../../../include/zonvie_hbft.h"

#include <stdlib.h>
#include <string.h>

#include <ft2build.h>
#include FT_FREETYPE_H

#include <harfbuzz/hb.h>
#include <harfbuzz/hb-ft.h>
#include <harfbuzz/hb-ot.h>

struct zonvie_ft_hb_font {
  FT_Library ft_lib;
  FT_Face ft_face;

  hb_font_t* hb_font;
  hb_buffer_t* hb_buf;

  uint8_t* font_bytes_owned;
  size_t font_len;

  // OpenType features for shaping (set via zonvie_ft_hb_font_set_features).
  hb_feature_t features[ZONVIE_MAX_FONT_FEATURES];
  size_t feature_count;

  // ASCII fast path tables (built at create + set_features time).
  // Uses hb_font_get_glyph_h_advance() for individual codepoints, so GPOS
  // pair-kerning is intentionally not reflected. This is correct for monospace
  // fonts (all advances uniform) which is the expected terminal use case.
  uint32_t ascii_glyph_ids[128];    // codepoint -> glyph ID (0 = unmapped)
  int32_t  ascii_x_advances[128];   // codepoint -> x_advance in 26.6 fixed-point
  uint8_t  ascii_lig_triggers[128]; // 1 = codepoint participates in active GSUB substitutions
  int      ascii_tables_valid;      // 1 if tables are populated

  // Last rendered glyph bitmap is owned by FreeType (ft_face->glyph->bitmap).
};

// Build ASCII glyph tables and ligature trigger bitset from GSUB introspection.
// Called at font creation time and when features change.
static void build_ascii_tables(zonvie_ft_hb_font* f) {
  if (!f || !f->hb_font) return;

  // 1) Build glyph_id + x_advance tables for ASCII 0-127
  memset(f->ascii_glyph_ids, 0, sizeof(f->ascii_glyph_ids));
  memset(f->ascii_x_advances, 0, sizeof(f->ascii_x_advances));
  memset(f->ascii_lig_triggers, 0, sizeof(f->ascii_lig_triggers));

  for (uint32_t cp = 0; cp < 128; cp++) {
    hb_codepoint_t gid = 0;
    if (hb_font_get_glyph(f->hb_font, cp, 0, &gid)) {
      f->ascii_glyph_ids[cp] = gid;
      f->ascii_x_advances[cp] = hb_font_get_glyph_h_advance(f->hb_font, gid);
    }
  }

  // 2) Build ligature trigger bitset from GSUB table
  hb_face_t* face = hb_font_get_face(f->hb_font);
  if (!face) { f->ascii_tables_valid = 1; return; }

  // Feature tags that can produce ligature/contextual substitutions
  const hb_tag_t lig_features[] = {
    HB_TAG('l','i','g','a'),  // Standard ligatures (default on)
    HB_TAG('c','a','l','t'),  // Contextual alternates (default on)
    HB_TAG('r','l','i','g'),  // Required ligatures (always on)
    HB_TAG('c','l','i','g'),  // Contextual ligatures (default off)
    HB_TAG('d','l','i','g'),  // Discretionary ligatures (default off)
  };
  const int num_features = 5;
  // Default activation: liga=on, calt=on, rlig=on, clig=off, dlig=off
  int feature_active[] = { 1, 1, 1, 0, 0 };

  // Override defaults based on user-set features
  for (size_t fi = 0; fi < f->feature_count; fi++) {
    for (int li = 0; li < num_features; li++) {
      if (f->features[fi].tag == lig_features[li]) {
        feature_active[li] = (f->features[fi].value != 0) ? 1 : 0;
      }
    }
  }

  // Collect GSUB lookup indices for all active ligature features
  hb_set_t* lookups = hb_set_create();
  for (int li = 0; li < num_features; li++) {
    if (!feature_active[li]) continue;
    const hb_tag_t tags[] = { lig_features[li], HB_TAG_NONE };
    hb_ot_layout_collect_lookups(face, HB_OT_TAG_GSUB, NULL, NULL, tags, lookups);
  }

  // For each lookup, collect input glyphs and map back to ASCII codepoints
  hb_set_t* input_glyphs = hb_set_create();
  hb_codepoint_t lookup_idx = HB_SET_VALUE_INVALID;
  while (hb_set_next(lookups, &lookup_idx)) {
    hb_set_clear(input_glyphs);
    hb_ot_layout_lookup_collect_glyphs(face, HB_OT_TAG_GSUB, lookup_idx,
        NULL, input_glyphs, NULL, NULL);

    for (uint32_t cp = 0x20; cp <= 0x7E; cp++) {
      if (f->ascii_glyph_ids[cp] != 0 &&
          hb_set_has(input_glyphs, f->ascii_glyph_ids[cp])) {
        f->ascii_lig_triggers[cp] = 1;
      }
    }
  }

  hb_set_destroy(input_glyphs);
  hb_set_destroy(lookups);
  f->ascii_tables_valid = 1;
}

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

  build_ascii_tables(f);

  return f;

fail:
  zonvie_ft_hb_font_destroy(f);
  return NULL;
}

void zonvie_ft_hb_font_set_features(zonvie_ft_hb_font* f, const zonvie_font_feature* features, size_t count) {
  if (!f) return;
  size_t n = count < ZONVIE_MAX_FONT_FEATURES ? count : ZONVIE_MAX_FONT_FEATURES;
  f->feature_count = n;
  for (size_t i = 0; i < n; i++) {
    f->features[i].tag = HB_TAG(features[i].tag[0], features[i].tag[1],
                                 features[i].tag[2], features[i].tag[3]);
    f->features[i].value = features[i].value;
    f->features[i].start = 0;
    f->features[i].end = (unsigned int)-1;
  }
  build_ascii_tables(f);
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

  hb_shape(f->hb_font, f->hb_buf,
           f->feature_count > 0 ? f->features : NULL,
           (unsigned int)f->feature_count);

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

int zonvie_ft_hb_get_ascii_glyph_ids(zonvie_ft_hb_font* f, uint32_t* out_glyph_ids) {
  if (!f || !f->ascii_tables_valid || !out_glyph_ids) return 0;
  memcpy(out_glyph_ids, f->ascii_glyph_ids, sizeof(f->ascii_glyph_ids));
  return 1;
}

int zonvie_ft_hb_get_ascii_x_advances(zonvie_ft_hb_font* f, int32_t* out_x_advances) {
  if (!f || !f->ascii_tables_valid || !out_x_advances) return 0;
  memcpy(out_x_advances, f->ascii_x_advances, sizeof(f->ascii_x_advances));
  return 1;
}

int zonvie_ft_hb_get_ascii_lig_triggers(zonvie_ft_hb_font* f, uint8_t* out_lig_triggers) {
  if (!f || !f->ascii_tables_valid || !out_lig_triggers) return 0;
  memcpy(out_lig_triggers, f->ascii_lig_triggers, sizeof(f->ascii_lig_triggers));
  return 1;
}

