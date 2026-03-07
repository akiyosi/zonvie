#pragma once
#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

// If you later build a DLL on Windows, you can switch this to dllexport/import.
#ifndef ZONVIE_API
#  define ZONVIE_API
#endif

typedef struct zonvie_core zonvie_core;

typedef struct zonvie_glyph_entry {
    float uv_min[2];
    float uv_max[2];
    float bbox_origin_px[2];
    float bbox_size_px[2];
    float advance_px;
    float ascent_px;
    float descent_px;
} zonvie_glyph_entry;

/* Phase 2: Core-managed atlas - bitmap descriptor returned by frontend rasterizer.
   The pixels pointer is valid until the next on_rasterize_glyph call on the same
   font handle, or until a font change. Core calls on_atlas_upload immediately
   after on_rasterize_glyph, so the pointer is always valid during upload. */
typedef struct zonvie_glyph_bitmap {
    const uint8_t* pixels;      /* rasterized bitmap data */
    uint32_t width;              /* bitmap width in pixels (0 = whitespace) */
    uint32_t height;             /* bitmap height in pixels */
    int32_t  pitch;              /* bytes per row (may differ from width) */
    int32_t  bearing_x;          /* horizontal bearing: pen to left edge (pixels) */
    int32_t  bearing_y;          /* vertical bearing: baseline to top edge (pixels, positive=up) */
    int32_t  advance_26_6;       /* horizontal advance in 26.6 fixed-point */
    float    ascent_px;          /* font ascent in pixels */
    float    descent_px;         /* font descent in pixels */
    uint32_t bytes_per_pixel;    /* 1=grayscale (R8), 3=ClearType RGB, 4=RGBA */
} zonvie_glyph_bitmap;

/* Phase 2: Rasterize a glyph without packing or uploading.
   Frontend fills out_bitmap with bitmap data and metrics.
   Returns 1 on success, 0 on failure. */
typedef int (*zonvie_rasterize_glyph_fn)(
    void* ctx,
    uint32_t scalar,
    uint32_t style_flags,        /* ZONVIE_STYLE_BOLD | ZONVIE_STYLE_ITALIC */
    zonvie_glyph_bitmap* out_bitmap
);

/* Phase 2: Upload a glyph bitmap to the atlas texture at specified coordinates.
   The bitmap pointer is the same one returned by the most recent on_rasterize_glyph.
   Frontend must upload the glyph pixels at (dest_x, dest_y) with size (width x height). */
typedef void (*zonvie_atlas_upload_fn)(
    void* ctx,
    uint32_t dest_x,
    uint32_t dest_y,
    uint32_t width,
    uint32_t height,
    const zonvie_glyph_bitmap* bitmap
);

/* Phase 2: Create or recreate the atlas texture at the given dimensions.
   Called once at init (lazily) and whenever the atlas is full.
   Frontend should destroy any existing atlas texture and create a new one,
   cleared to zero (for padding). */
typedef void (*zonvie_atlas_create_fn)(
    void* ctx,
    uint32_t atlas_w,
    uint32_t atlas_h
);

typedef int (*zonvie_atlas_ensure_glyph_fn)(
    void* ctx,
    uint32_t scalar,
    zonvie_glyph_entry* out_entry
);

/* Style flags for font variant selection */
#define ZONVIE_STYLE_BOLD   (1u << 0)
#define ZONVIE_STYLE_ITALIC (1u << 1)

/* Text-run shaping: shape multiple scalars into glyphs with positions.
   Frontend performs platform-specific shaping (HarfBuzz on macOS, DWrite on Windows).
   Returns actual glyph count. If > out_cap, caller should retry with larger buffers.
   out_clusters[i] = index of first input scalar that produced glyph i (HarfBuzz convention). */
typedef size_t (*zonvie_shape_text_run_fn)(
    void* ctx,
    const uint32_t* scalars, size_t scalar_count,
    uint32_t style_flags,
    uint32_t* out_glyph_ids, uint32_t* out_clusters,
    int32_t* out_x_advance, int32_t* out_x_offset, int32_t* out_y_offset,
    size_t out_cap
);

/* Rasterize a glyph by its glyph ID (post-shaping, skips scalar→glyph_id lookup).
   Returns 1 on success, 0 on failure. */
typedef int (*zonvie_rasterize_glyph_by_id_fn)(
    void* ctx, uint32_t glyph_id, uint32_t style_flags,
    zonvie_glyph_bitmap* out_bitmap
);

/* ASCII fast path: retrieve pre-computed shaping tables for a style variant.
   Frontend fills out_glyph_ids[128], out_x_advances[128], out_lig_triggers[128]
   from its HarfBuzz font handle for the given style.
   Returns 1 on success, 0 on failure. Called lazily by core after font change. */
typedef int (*zonvie_get_ascii_table_fn)(
    void* ctx,
    uint32_t style_flags,
    uint32_t* out_glyph_ids,    /* [128] codepoint -> glyph_id */
    int32_t* out_x_advances,    /* [128] codepoint -> x_advance (26.6 fixed-point) */
    uint8_t* out_lig_triggers   /* [128] 1=participates in GSUB substitution */
);

/* Styled glyph lookup (preferred when present) */
typedef int (*zonvie_atlas_ensure_glyph_styled_fn)(
    void* ctx,
    uint32_t scalar,
    uint32_t style_flags,  /* ZONVIE_STYLE_BOLD | ZONVIE_STYLE_ITALIC */
    zonvie_glyph_entry* out_entry
);

/* Render-ready terminal cell (resolved fg/bg already). */
typedef struct zonvie_cell {
    uint32_t scalar;   /* Unicode scalar (U+0000..U+10FFFF) */
    uint32_t fgRGB;    /* 0x00RRGGBB */
    uint32_t bgRGB;    /* 0x00RRGGBB */
} zonvie_cell;

/* --- Render plan types (data-only) --- */
typedef struct zonvie_bg_span {
    uint32_t row;        /* 0-based */
    uint32_t col_start;  /* inclusive */
    uint32_t col_end;    /* exclusive */
    uint32_t bgRGB;      /* 0x00RRGGBB */
} zonvie_bg_span;

typedef struct zonvie_text_run {
    uint32_t row;        /* 0-based */
    uint32_t col_start;  /* 0-based */
    uint32_t len;        /* number of cells (UTF-32 scalars) */
    uint32_t fgRGB;      /* 0x00RRGGBB */
    uint32_t bgRGB;      /* 0x00RRGGBB */
    const uint32_t* scalars; /* points to len UTF-32 scalars, valid only during callback */
} zonvie_text_run;

/* Cursor info for rendering. */
/* Cursor shape numeric constants for language bindings (Swift, etc.) */
#define ZONVIE_CURSOR_BLOCK_VALUE       0u
#define ZONVIE_CURSOR_VERTICAL_VALUE    1u
#define ZONVIE_CURSOR_HORIZONTAL_VALUE  2u

typedef struct zonvie_cursor {
    uint32_t enabled;            /* 0/1 */
    uint32_t row;                /* 0-based */
    uint32_t col;                /* 0-based */
    uint32_t shape;              /* data-only: ZONVIE_CURSOR_*_VALUE */
    uint32_t cell_percentage;    /* 1..100 (0 treated as 100) */
    uint32_t fgRGB;              /* 0x00RRGGBB */
    uint32_t bgRGB;              /* 0x00RRGGBB */
    uint32_t blink_wait_ms;      /* wait time before blink starts (ms), 0=no blink */
    uint32_t blink_on_ms;        /* on time for blink cycle (ms) */
    uint32_t blink_off_ms;       /* off time for blink cycle (ms) */
} zonvie_cursor;

/* Decoration flags for zonvie_vertex.deco_flags */
#define ZONVIE_DECO_UNDERCURL     (1u << 0)
#define ZONVIE_DECO_UNDERLINE     (1u << 1)
#define ZONVIE_DECO_UNDERDOUBLE   (1u << 2)
#define ZONVIE_DECO_UNDERDOTTED   (1u << 3)
#define ZONVIE_DECO_UNDERDASHED   (1u << 4)
#define ZONVIE_DECO_STRIKETHROUGH (1u << 5)
#define ZONVIE_DECO_CURSOR        (1u << 6)  /* Marker for cursor vertices (not a decoration) */
#define ZONVIE_DECO_SCROLLABLE    (1u << 7)  /* Vertex is in scrollable content area (not margin) */
#define ZONVIE_DECO_OVERLINE      (1u << 8)
#define ZONVIE_DECO_GLOW          (1u << 9)  /* Neon glow halo around glyph */

typedef struct __attribute__((aligned(16))) zonvie_vertex {
    float position[2];
    float texCoord[2];
    float color[4] __attribute__((aligned(16)));  /* 16-byte aligned to match Swift simd_float4 */
    int64_t grid_id;  /* 1 = main grid, >1 = sub-grid (float window) */
    uint32_t deco_flags;  /* ZONVIE_DECO_* flags for decoration type */
    float deco_phase;     /* phase offset for undercurl (cell column position) */
} zonvie_vertex;

typedef void (*zonvie_on_vertices_fn)(
    void* ctx,
    const zonvie_vertex* main_verts, size_t main_count,
    const zonvie_vertex* cursor_verts, size_t cursor_count
);

/* Which buffers are included in on_vertices_partial */
enum {
    ZONVIE_VERT_UPDATE_MAIN   = 1u << 0,
    ZONVIE_VERT_UPDATE_CURSOR = 1u << 1,
};

typedef void (*zonvie_on_vertices_row_fn)(
    void* ctx,
    int64_t grid_id,          // grid ID (1 = main, other = external)
    uint32_t row_start,       // inclusive
    uint32_t row_count,       // number of rows
    const zonvie_vertex* verts,
    size_t vert_count,
    uint32_t flags,           // reuse/update flags (e.g. ZONVIE_VERT_UPDATE_MAIN)
    uint32_t total_rows,      // current grid total rows (for resize detection)
    uint32_t total_cols       // current grid total cols
);

/*
  Partial vertices update:
  - If (flags & ZONVIE_VERT_UPDATE_MAIN) == 0, the frontend MUST keep previous main vertices.
  - If (flags & ZONVIE_VERT_UPDATE_CURSOR) == 0, the frontend MUST keep previous cursor vertices.
*/
typedef void (*zonvie_on_vertices_partial_fn)(
    void* ctx,
    const zonvie_vertex* main_verts, size_t main_count,
    const zonvie_vertex* cursor_verts, size_t cursor_count,
    uint32_t flags
);

/* Modifier bitmask for zonvie_core_send_key_event.mods */
#define ZONVIE_MOD_CTRL  (1u << 0)
#define ZONVIE_MOD_ALT   (1u << 1) /* Meta/Alt */
#define ZONVIE_MOD_SHIFT (1u << 2)
#define ZONVIE_MOD_SUPER (1u << 3) /* Command on macOS, Win key on Windows */

typedef void (*zonvie_on_render_plan_fn)(
    void* ctx,
    const zonvie_bg_span* bg_spans, size_t bg_span_count,
    const zonvie_text_run* text_runs, size_t text_run_count,
    uint32_t rows, uint32_t cols,
    const zonvie_cursor* cursor /* may be NULL */
);

typedef void (*zonvie_on_log_fn)(
    void* ctx,
    const uint8_t* bytes, size_t len
);

/*
  guifont notification:
    bytes = UTF-8 string formatted as: "<font_name>\t<point_size>"
    Example: "Menlo\t14"
  (Swift/Win32 side should treat it as data-only and just apply.)
*/
typedef void (*zonvie_on_guifont_fn)(
    void* ctx,
    const uint8_t* bytes, size_t len
);

/* linespace notification:
   pixels of extra line spacing (Neovim 'linespace' option). */
typedef void (*zonvie_on_linespace_fn)(
    void* ctx,
    int32_t linespace_px
);

/* Called when embedded nvim process terminates (e.g. :q).
   exit_code: process exit code
     - 0 = normal exit (:q)
     - 1-255 = error exit (:cq, :Ncq)
     - 128+N = killed by signal N (Unix only)
   May be NULL. */
typedef void (*zonvie_on_exit_fn)(void* ctx, int32_t exit_code);

/* Called when user-initiated quit is requested (window close button).
   has_unsaved: non-zero if there are unsaved buffers.
   Frontend should show a confirmation dialog if has_unsaved is true,
   then call zonvie_core_quit_confirmed() with the user's choice. */
typedef void (*zonvie_on_quit_requested_fn)(void* ctx, int has_unsaved);

/* Called when Neovim sets the window title (set_title UI event). */
typedef void (*zonvie_on_set_title_fn)(
    void* ctx,
    const uint8_t* title, size_t title_len
);

/* Called when a grid should be displayed in an external window.
   grid_id: the grid to display externally
   win: Neovim window handle (for reference)
   rows, cols: dimensions of the grid
   start_row, start_col: position in main grid cell units (from win_pos/win_float_pos)
                         Use -1 if no position info available (cmdline, etc.)
   Called on win_external_pos event. Frontend should create a separate window
   and render the grid there. */
typedef void (*zonvie_on_external_window_fn)(
    void* ctx,
    int64_t grid_id,
    int64_t win,
    uint32_t rows,
    uint32_t cols,
    int32_t start_row,
    int32_t start_col
);

/* Called when an external grid is closed (win_hide/win_close for external grid).
   Frontend should destroy the corresponding window. */
typedef void (*zonvie_on_external_window_close_fn)(
    void* ctx,
    int64_t grid_id
);

/* Called to update vertices for an external grid.
   Frontend should render these vertices in the external window for grid_id. */
typedef void (*zonvie_on_external_vertices_fn)(
    void* ctx,
    int64_t grid_id,
    const zonvie_vertex* verts,
    size_t vert_count,
    uint32_t rows,
    uint32_t cols
);

/* --- ext_windows layout operation callbacks --- */

/* Called when Neovim requests moving a window in a direction.
   flags: 0=below, 1=above, 2=right, 3=left */
typedef void (*zonvie_on_win_move_fn)(
    void* ctx,
    int64_t grid_id,
    int64_t win,
    int32_t flags
);

/* Called when Neovim requests exchanging a window with another.
   count: number of positions to exchange */
typedef void (*zonvie_on_win_exchange_fn)(
    void* ctx,
    int64_t grid_id,
    int64_t win,
    int32_t count
);

/* Called when Neovim requests rotating windows.
   direction: 0=downward, 1=upward
   count: number of rotations */
typedef void (*zonvie_on_win_rotate_fn)(
    void* ctx,
    int64_t grid_id,
    int64_t win,
    int32_t direction,
    int32_t count
);

/* Called when Neovim requests equal-sizing all windows. */
typedef void (*zonvie_on_win_resize_equal_fn)(void* ctx);

/* Called when Neovim asks which window is in a given direction.
   direction: 0=down, 1=up, 2=right, 3=left
   count: how many windows to traverse
   Returns: Neovim window handle of the target window, or 0 if none.
   NOTE: Synchronous - Neovim blocks until response is sent. */
typedef int64_t (*zonvie_on_win_move_cursor_fn)(
    void* ctx,
    int32_t direction,
    int32_t count
);

/* --- ext_cmdline types --- */

/* A single highlighted chunk in cmdline content */
typedef struct zonvie_cmdline_chunk {
    uint32_t hl_id;          /* highlight id */
    const uint8_t* text;     /* UTF-8 text */
    size_t text_len;
} zonvie_cmdline_chunk;

/* A single line in cmdline block (multi-line input) */
typedef struct zonvie_cmdline_block_line {
    const zonvie_cmdline_chunk* chunks;
    size_t chunk_count;
} zonvie_cmdline_block_line;

/* Called when cmdline should be shown.
   content: array of highlighted chunks
   pos: cursor position within content
   firstc: first character (':' '/' '?' etc.)
   prompt: custom prompt string (from input())
   indent: number of spaces to indent
   level: nesting level (1 = top level)
   prompt_hl_id: highlight id for the prompt */
typedef void (*zonvie_on_cmdline_show_fn)(
    void* ctx,
    const zonvie_cmdline_chunk* content, size_t content_count,
    uint32_t pos,
    uint8_t firstc,
    const uint8_t* prompt, size_t prompt_len,
    uint32_t indent,
    uint32_t level,
    uint32_t prompt_hl_id
);

/* Called when cmdline should be hidden. */
typedef void (*zonvie_on_cmdline_hide_fn)(void* ctx, uint32_t level);

/* Called when cmdline cursor position changes. */
typedef void (*zonvie_on_cmdline_pos_fn)(void* ctx, uint32_t pos, uint32_t level);

/* Called when a special character is shown (e.g. after Ctrl-V).
   c: the special character string
   shift: whether shift was held
   level: cmdline nesting level */
typedef void (*zonvie_on_cmdline_special_char_fn)(
    void* ctx,
    const uint8_t* c, size_t c_len,
    int shift,
    uint32_t level
);

/* Called when cmdline block (multi-line input) should be shown. */
typedef void (*zonvie_on_cmdline_block_show_fn)(
    void* ctx,
    const zonvie_cmdline_block_line* lines, size_t line_count
);

/* Called when a line is appended to cmdline block. */
typedef void (*zonvie_on_cmdline_block_append_fn)(
    void* ctx,
    const zonvie_cmdline_chunk* line, size_t chunk_count
);

/* Called when cmdline block should be hidden. */
typedef void (*zonvie_on_cmdline_block_hide_fn)(void* ctx);

/* --- ext_messages types --- */

/* View type for message display (matches config routing) */
typedef enum {
    ZONVIE_MSG_VIEW_MINI = 0,
    ZONVIE_MSG_VIEW_EXT_FLOAT = 1,
    ZONVIE_MSG_VIEW_CONFIRM = 2,
    ZONVIE_MSG_VIEW_SPLIT = 3,
    ZONVIE_MSG_VIEW_NONE = 4,
    ZONVIE_MSG_VIEW_NOTIFICATION = 5,
} zonvie_msg_view_type;

/* A single highlighted chunk in message content */
typedef struct zonvie_msg_chunk {
    uint32_t hl_id;          /* highlight id */
    const uint8_t* text;     /* UTF-8 text */
    size_t text_len;
} zonvie_msg_chunk;

/* Called when a message should be shown.
   view: routed view type from config
   kind: message kind (e.g., "echo", "emsg", "wmsg", etc.)
   content: array of highlighted chunks
   replace_last: if true, replace the most recent message
   history: if true, message was added to :messages history
   append: if true, append to previous message (for :echon)
   msg_id: unique message identifier for replacement
   timeout_ms: auto-hide timeout in milliseconds (0 = no auto-hide) */
typedef void (*zonvie_on_msg_show_fn)(
    void* ctx,
    zonvie_msg_view_type view,
    const char* kind, size_t kind_len,
    const zonvie_msg_chunk* chunks, size_t chunk_count,
    int replace_last,
    int history,
    int append,
    int64_t msg_id,
    uint32_t timeout_ms
);

/* Called when messages should be cleared. */
typedef void (*zonvie_on_msg_clear_fn)(void* ctx);

/* Called when mode info should be shown (e.g., "-- INSERT --", recording).
   view: routed view type from config
   content: array of highlighted chunks (empty to hide) */
typedef void (*zonvie_on_msg_showmode_fn)(
    void* ctx,
    zonvie_msg_view_type view,
    const zonvie_msg_chunk* chunks, size_t chunk_count
);

/* Called when showcmd info should be shown.
   view: routed view type from config
   content: array of highlighted chunks (empty to hide) */
typedef void (*zonvie_on_msg_showcmd_fn)(
    void* ctx,
    zonvie_msg_view_type view,
    const zonvie_msg_chunk* chunks, size_t chunk_count
);

/* Called when ruler info should be shown.
   view: routed view type from config
   content: array of highlighted chunks (empty to hide) */
typedef void (*zonvie_on_msg_ruler_fn)(
    void* ctx,
    zonvie_msg_view_type view,
    const zonvie_msg_chunk* chunks, size_t chunk_count
);

/* A single entry in message history */
typedef struct zonvie_msg_history_entry {
    const char* kind;            /* message kind (e.g., "echo", "emsg") */
    size_t kind_len;
    const zonvie_msg_chunk* chunks;  /* reuse existing MsgChunk type */
    size_t chunk_count;
    int append;                  /* was appended to previous message */
} zonvie_msg_history_entry;

/* Called when message history should be shown (:messages or g<).
   entries: array of history entries
   entry_count: number of entries
   prev_cmd: true if triggered by g< (show output of previous command) */
typedef void (*zonvie_on_msg_history_show_fn)(
    void* ctx,
    const zonvie_msg_history_entry* entries, size_t entry_count,
    int prev_cmd
);

/* --- ext_popupmenu types --- */

/* A single item in the popup menu */
typedef struct zonvie_popupmenu_item {
    const uint8_t* word;     /* completion word (UTF-8) */
    size_t word_len;
    const uint8_t* kind;     /* kind string (e.g., "Function", "Variable") */
    size_t kind_len;
    const uint8_t* menu;     /* extra menu info */
    size_t menu_len;
    const uint8_t* info;     /* detailed info */
    size_t info_len;
} zonvie_popupmenu_item;

/* Called when popup menu should be shown.
   items: array of completion items
   item_count: number of items
   selected: currently selected item index (-1 if none)
   row: anchor row position
   col: anchor column position
   grid_id: which grid the popup is anchored to (1 = main, -100 = cmdline) */
typedef void (*zonvie_on_popupmenu_show_fn)(
    void* ctx,
    const zonvie_popupmenu_item* items, size_t item_count,
    int32_t selected,
    int32_t row,
    int32_t col,
    int64_t grid_id
);

/* Called when popup menu should be hidden. */
typedef void (*zonvie_on_popupmenu_hide_fn)(void* ctx);

/* Called when popup menu selection changes.
   selected: new selected item index (-1 if deselected) */
typedef void (*zonvie_on_popupmenu_select_fn)(void* ctx, int32_t selected);

/* --- ext_tabline types --- */

/* A single tab entry in the tabline */
typedef struct zonvie_tab_entry {
    int64_t tab_handle;      /* Neovim tab page handle */
    const uint8_t* name;     /* Tab name (UTF-8, e.g., filename) */
    size_t name_len;
} zonvie_tab_entry;

/* A single buffer entry in the tabline */
typedef struct zonvie_buffer_entry {
    int64_t buffer_handle;   /* Neovim buffer handle */
    const uint8_t* name;     /* Buffer name (UTF-8) */
    size_t name_len;
} zonvie_buffer_entry;

/* Called when tabline should be updated (ext_tabline).
   curtab: current tab page handle
   tabs: array of tab entries
   tab_count: number of tabs
   curbuf: current buffer handle
   buffers: array of buffer entries
   buffer_count: number of buffers */
typedef void (*zonvie_on_tabline_update_fn)(
    void* ctx,
    int64_t curtab,
    const zonvie_tab_entry* tabs, size_t tab_count,
    int64_t curbuf,
    const zonvie_buffer_entry* buffers, size_t buffer_count
);

/* Called when tabline should be hidden. */
typedef void (*zonvie_on_tabline_hide_fn)(void* ctx);

/* --- Clipboard callbacks --- */

/* Called to get clipboard content.
   register_name: "+" or "*" (system clipboard register)
   out_buf: output buffer for clipboard content (UTF-8)
   out_len: output length written
   max_len: maximum buffer size
   Returns: 1 on success, 0 on failure */
typedef int (*zonvie_on_clipboard_get_fn)(
    void* ctx,
    const char* register_name,
    uint8_t* out_buf,
    size_t* out_len,
    size_t max_len
);

/* Called to set clipboard content.
   register_name: "+" or "*"
   data: clipboard content (UTF-8, newline-separated)
   len: content length
   Returns: 1 on success, 0 on failure */
typedef int (*zonvie_on_clipboard_set_fn)(
    void* ctx,
    const char* register_name,
    const uint8_t* data,
    size_t len
);

typedef struct zonvie_callbacks {
    zonvie_on_vertices_fn on_vertices;                 /* NEW: preferred when present */
    zonvie_on_vertices_partial_fn on_vertices_partial; /* NEW: optional partial update */
    zonvie_on_vertices_row_fn on_vertices_row;   /* NEW */
    zonvie_atlas_ensure_glyph_fn on_atlas_ensure_glyph;
    zonvie_atlas_ensure_glyph_styled_fn on_atlas_ensure_glyph_styled; /* NEW: styled glyph lookup */
    zonvie_on_render_plan_fn on_render_plan;
    zonvie_on_log_fn on_log;
    zonvie_on_guifont_fn on_guifont;
    zonvie_on_linespace_fn on_linespace;

    zonvie_on_exit_fn on_exit;
    zonvie_on_set_title_fn on_set_title;

    /* External window callbacks (ext_multigrid) */
    zonvie_on_external_window_fn on_external_window;
    zonvie_on_external_window_close_fn on_external_window_close;
    zonvie_on_external_vertices_fn on_external_vertices;

    /* Called when cursor moves to a different grid.
       grid_id: the grid where cursor now resides (1 = main grid).
       Frontend should activate the corresponding window. */
    void (*on_cursor_grid_changed)(void* ctx, int64_t grid_id);

    /* ext_cmdline callbacks */
    zonvie_on_cmdline_show_fn on_cmdline_show;
    zonvie_on_cmdline_hide_fn on_cmdline_hide;
    zonvie_on_cmdline_pos_fn on_cmdline_pos;
    zonvie_on_cmdline_special_char_fn on_cmdline_special_char;
    zonvie_on_cmdline_block_show_fn on_cmdline_block_show;
    zonvie_on_cmdline_block_append_fn on_cmdline_block_append;
    zonvie_on_cmdline_block_hide_fn on_cmdline_block_hide;

    /* ext_popupmenu callbacks */
    zonvie_on_popupmenu_show_fn on_popupmenu_show;
    zonvie_on_popupmenu_hide_fn on_popupmenu_hide;
    zonvie_on_popupmenu_select_fn on_popupmenu_select;

    /* ext_messages callbacks */
    zonvie_on_msg_show_fn on_msg_show;
    zonvie_on_msg_clear_fn on_msg_clear;
    zonvie_on_msg_showmode_fn on_msg_showmode;
    zonvie_on_msg_showcmd_fn on_msg_showcmd;
    zonvie_on_msg_ruler_fn on_msg_ruler;
    zonvie_on_msg_history_show_fn on_msg_history_show;

    /* Clipboard callbacks */
    zonvie_on_clipboard_get_fn on_clipboard_get;
    zonvie_on_clipboard_set_fn on_clipboard_set;

    /* SSH authentication prompt callback.
       Called when SSH mode detects a password/passphrase prompt.
       prompt: the prompt text from SSH (UTF-8)
       Frontend should display a password dialog and call
       zonvie_core_send_stdin_data with the password followed by newline. */
    void (*on_ssh_auth_prompt)(void* ctx, const uint8_t* prompt, size_t prompt_len);

    /* ext_tabline callbacks */
    zonvie_on_tabline_update_fn on_tabline_update;
    zonvie_on_tabline_hide_fn on_tabline_hide;

    /* Grid scroll notification callback.
       Called when a grid receives a grid_scroll event from Neovim.
       Frontend should clear any pixel-based smooth scroll offset for this grid
       to prevent double-shifting (grid_scroll moves content by rows, pixel offset remains). */
    void (*on_grid_scroll)(void* ctx, int64_t grid_id);

    /* IME off notification callback.
       Called when IME should be turned off (e.g., on mode change when
       ime.disable_on_modechange is enabled, or via RPC zonvie_ime_off). */
    void (*on_ime_off)(void* ctx);

    /* Quit request callback (window close with unsaved check). */
    zonvie_on_quit_requested_fn on_quit_requested;

    /* Phase 2: Core-managed atlas callbacks.
       When all three are non-NULL, core owns shelf packing and UV computation.
       The old on_atlas_ensure_glyph / on_atlas_ensure_glyph_styled are not called.
       When any is NULL, falls back to Phase 1 (frontend-managed atlas). */
    zonvie_rasterize_glyph_fn on_rasterize_glyph;
    zonvie_atlas_upload_fn on_atlas_upload;
    zonvie_atlas_create_fn on_atlas_create;

    /* Flush bracketing callbacks (for GPU buffer management).
       on_flush_begin: called before vertex generation starts.
       on_flush_end: called after all vertices (rows + cursor + external grids) are submitted.
       Frontend can use these to implement triple buffering / atomic commit. */
    void (*on_flush_begin)(void* ctx);
    void (*on_flush_end)(void* ctx);

    /* Neovim default_colors_set notification.
       Called when Neovim sends a default_colors_set redraw event (colorscheme change).
       fg/bg are 24-bit RGB (0x00RRGGBB), or 0xFFFFFFFF if not set.
       Runs on the core/redraw thread with grid_mu held. */
    void (*on_default_colors_set)(void* ctx, uint32_t fg, uint32_t bg);

    /* ext_windows layout operation callbacks */
    zonvie_on_win_move_fn on_win_move;
    zonvie_on_win_exchange_fn on_win_exchange;
    zonvie_on_win_rotate_fn on_win_rotate;
    zonvie_on_win_resize_equal_fn on_win_resize_equal;
    zonvie_on_win_move_cursor_fn on_win_move_cursor;

    /* Text-run shaping callback (NULL = per-cell fallback, no ligatures). */
    zonvie_shape_text_run_fn on_shape_text_run;

    /* Glyph-ID rasterize callback (NULL = per-cell fallback). */
    zonvie_rasterize_glyph_by_id_fn on_rasterize_glyph_by_id;

    /* ASCII fast path table callback (NULL = no fast path, always use shaping). */
    zonvie_get_ascii_table_fn on_get_ascii_table;
} zonvie_callbacks;

void zonvie_core_set_log_enabled(zonvie_core *core, int enabled);

/* Enable ext_cmdline UI extension (must call before zonvie_core_start).
 * When enabled, cmdline is rendered as a separate external window. */
void zonvie_core_set_ext_cmdline(zonvie_core *core, int enabled);

/* Enable ext_popupmenu UI extension (must call before zonvie_core_start).
 * When enabled, popup menu events are sent to frontend callbacks. */
void zonvie_core_set_ext_popupmenu(zonvie_core *core, int enabled);

/* Enable ext_messages UI extension (must call before zonvie_core_start).
 * When enabled, message events are sent to frontend callbacks instead of
 * being rendered in the main grid. Messages are displayed as external
 * floating windows. */
void zonvie_core_set_ext_messages(zonvie_core *core, int enabled);

/* Enable ext_tabline UI extension (must call before zonvie_core_start).
 * When enabled, tabline_update events are sent to frontend callbacks
 * for Chrome-style tab rendering in titlebar. */
void zonvie_core_set_ext_tabline(zonvie_core *core, int enabled);

/* Enable ext_windows UI extension (must call before zonvie_core_start).
 * When enabled, Neovim external windows are rendered as separate OS windows. */
ZONVIE_API void zonvie_core_set_ext_windows(zonvie_core *core, int enabled);

/* Check if msg_show throttle timeout has expired and process pending messages.
 * Frontend should call this periodically (e.g., every frame or 16ms) to ensure
 * messages are displayed even when Neovim is waiting for user input. */
void zonvie_core_tick_msg_throttle(zonvie_core *core);

/* Enable blur transparency for background (macOS only).
 * When enabled, default background uses semi-transparent alpha for blur effect.
 * Windows should NOT enable this (causes rendering artifacts). */
void zonvie_core_set_blur_enabled(zonvie_core *core, int enabled);

/* Set inherit_cwd flag (must call before zonvie_core_start).
 * When enabled, child process inherits parent's CWD instead of $HOME. */
void zonvie_core_set_inherit_cwd(zonvie_core *core, int enabled);

/* Set glyph cache sizes for performance tuning.
 * ascii_size: cache size for ASCII chars (0-127) × 4 style combinations (default: 512, min: 128)
 * non_ascii_size: hash table size for non-ASCII chars (default: 256, min: 64)
 * Should be called before zonvie_core_start() for best results. */
void zonvie_core_set_glyph_cache_size(zonvie_core *core, unsigned ascii_size, unsigned non_ascii_size);

/* Set glyph atlas texture size (square, both width and height).
 * size: atlas dimension in pixels (default: 2048, range: 1024-4096)
 * Must be called before zonvie_core_start(). Ignored after start. */
void zonvie_core_set_atlas_size(zonvie_core *core, unsigned size);

/* Create a new core instance.
   cb:             pointer to callback struct (may be NULL).
   callbacks_size: sizeof(zonvie_callbacks) as seen by the caller.
                   Allows the core to safely handle callers compiled
                   against an older (smaller) struct layout.
   ctx:            opaque frontend context forwarded to all callbacks. */
zonvie_core *zonvie_core_create(zonvie_callbacks *cb, size_t callbacks_size, void *ctx);
void zonvie_core_destroy(zonvie_core *core);

int  zonvie_core_start(zonvie_core *core, const char *nvim_path, unsigned rows, unsigned cols);
void zonvie_core_stop(zonvie_core *core);

void zonvie_core_send_input(zonvie_core *core, const unsigned char *data, int len);

/* Send a command to Neovim via nvim_command RPC (does not show in cmdline).
   cmd: command string (e.g., "lua vim.notify('hello')")
   len: length of command string */
ZONVIE_API void zonvie_core_send_command(zonvie_core *core, const unsigned char *cmd, size_t len);

/* Request graceful quit (called by frontend on window close button).
   This checks for unsaved buffers and calls on_quit_requested callback. */
ZONVIE_API void zonvie_core_request_quit(zonvie_core *core);

/* Confirm quit after user dialog (called after on_quit_requested).
   force: if non-zero, use :qa! (discard changes), otherwise :qa */
ZONVIE_API void zonvie_core_quit_confirmed(zonvie_core *core, int force);

/* Send raw data to child process stdin (for SSH password input).
   data: raw bytes to send (password + newline)
   len: number of bytes
   Used when on_ssh_auth_prompt callback is triggered. */
ZONVIE_API void zonvie_core_send_stdin_data(zonvie_core *core, const unsigned char *data, int len);



ZONVIE_API void zonvie_core_send_key_event(
    zonvie_core *core,
    uint32_t keycode,
    uint32_t mods,
    const unsigned char *chars_utf8, int chars_len,
    const unsigned char *chars_ignoring_mods_utf8, int chars_ign_len
);

void zonvie_core_resize(zonvie_core *core, unsigned rows, unsigned cols);

/* Request resize of a specific grid (for external windows).
 * Calls nvim_ui_try_resize_grid RPC. */
void zonvie_core_try_resize_grid(zonvie_core *core, int64_t grid_id, unsigned rows, unsigned cols);

/* --- Smooth scrolling support --- */

/* Grid info for hit-testing (which grid is under the cursor) */
typedef struct zonvie_grid_info {
    int64_t grid_id;
    int64_t zindex;
    int32_t start_row;
    int32_t start_col;
    int32_t rows;
    int32_t cols;
    /* Viewport margins (rows/cols NOT part of scrollable area, e.g. winbar) */
    int32_t margin_top;
    int32_t margin_bottom;
    int32_t margin_left;
    int32_t margin_right;
} zonvie_grid_info;

/* Viewport info for scrollbar rendering */
typedef struct zonvie_viewport_info {
    int64_t grid_id;      /* Grid ID (1 = main grid) */
    int64_t topline;      /* First visible line (0-based) */
    int64_t botline;      /* First line below window (exclusive) */
    int64_t line_count;   /* Total lines in buffer */
    int64_t curline;      /* Current cursor line */
    int64_t curcol;       /* Current cursor column */
    int64_t scroll_delta; /* Lines scrolled since last update */
} zonvie_viewport_info;

/* Get viewport info for a specific grid (for scrollbar rendering).
   Returns 1 if found, 0 if not found or grid has no viewport info. */
ZONVIE_API int zonvie_core_get_viewport(
    zonvie_core *core,
    int64_t grid_id,
    zonvie_viewport_info *out_viewport
);

/* Get list of visible grids for hit-testing.
   Returns number of grids written (up to max_count).
   Main grid (id=1) is always included first. */
ZONVIE_API size_t zonvie_core_get_visible_grids(
    zonvie_core *core,
    zonvie_grid_info *out_grids,
    size_t max_count
);

/* Non-blocking version of zonvie_core_get_visible_grids.
   Returns grid count on success, or -1 if the lock could not be acquired. */
ZONVIE_API int32_t zonvie_core_try_get_visible_grids(
    zonvie_core *core,
    zonvie_grid_info *out_grids,
    size_t max_count
);

/* Get current cursor position.
   Returns cursor row and column (0-based) in out_row and out_col.
   Returns the grid_id of the cursor (1 = main grid). */
ZONVIE_API int64_t zonvie_core_get_cursor_position(
    zonvie_core *core,
    int32_t *out_row,
    int32_t *out_col
);

/* Get Neovim window handle (winid) for a grid.
   Pass grid_id=-1 to get the winid for the cursor's current grid.
   Returns 0 if the mapping is not available. */
ZONVIE_API int64_t zonvie_core_get_win_id(zonvie_core *core, int64_t grid_id);

/* Get current mode name (e.g., "normal", "insert", "terminal").
   Returns pointer to null-terminated string. Do not free.
   Returns empty string if core is null. */
ZONVIE_API const char* zonvie_core_get_current_mode(zonvie_core *core);

/* Check if cursor is visible.
   Returns false during busy_start, true after busy_stop. */
ZONVIE_API bool zonvie_core_is_cursor_visible(zonvie_core *core);

/* Get current cursor blink parameters (in milliseconds).
   Returns 0 for all values if blinking is disabled.
   blink_wait: time before blink starts (0 = no blink)
   blink_on: cursor visible time during blink cycle
   blink_off: cursor hidden time during blink cycle */
ZONVIE_API void zonvie_core_get_cursor_blink(
    zonvie_core *core,
    uint32_t *out_blink_wait_ms,
    uint32_t *out_blink_on_ms,
    uint32_t *out_blink_off_ms
);

/* Send mouse scroll event to Neovim.
   direction: "up", "down", "left", or "right"
   modifier: "" or combination of "S" (shift), "C" (ctrl), "A" (alt), "D" (super/command)
   grid_id: target grid (1 = main grid)
   row, col: position within the grid */
ZONVIE_API void zonvie_core_send_mouse_scroll(
    zonvie_core *core,
    int64_t grid_id,
    int32_t row,
    int32_t col,
    const char *direction,
    const char *modifier
);

/* Scroll view to specified line number (1-based).
   If use_bottom is true, positions line at screen bottom (zb), otherwise at top (zt).
   Used for scrollbar dragging. */
ZONVIE_API void zonvie_core_scroll_to_line(
    zonvie_core *core,
    int64_t line,
    bool use_bottom
);

/* Scroll a window by one page using Neovim's native <C-f>/<C-b>.
   grid_id: target grid (-1 for cursor grid / current window).
   forward: true for page down, false for page up. */
ZONVIE_API void zonvie_core_page_scroll(
    zonvie_core *core,
    int64_t grid_id,
    bool forward
);

/* Process pending message scroll update (for throttled scroll).
   Call this after scroll events stop to ensure final position is rendered. */
ZONVIE_API void zonvie_core_process_pending_msg_scroll(
    zonvie_core *core
);

/* Send mouse input event to Neovim (click, drag, release).
   button: "left", "right", "middle", "x1", "x2"
   action: "press", "drag", "release"
   modifier: "" or combination of "S" (shift), "C" (ctrl), "A" (alt), "D" (super/command)
   grid_id: target grid (1 = main grid)
   row, col: position within the grid */
ZONVIE_API void zonvie_core_send_mouse_input(
    zonvie_core *core,
    const char *button,
    const char *action,
    const char *modifier,
    int64_t grid_id,
    int32_t row,
    int32_t col
);

// Notify view/cell pixel metrics to core.
// Core computes rows/cols and sends nvim_ui_try_resize internally (with suppression).
ZONVIE_API void zonvie_core_update_layout_px(
    zonvie_core *core,
    uint32_t drawable_w_px,
    uint32_t drawable_h_px,
    uint32_t cell_w_px,
    uint32_t cell_h_px
);

// Set screen width in cells (for cmdline max width).
// This should be called when screen size or cell size changes.
ZONVIE_API void zonvie_core_set_screen_cols(zonvie_core *core, uint32_t cols);

// Get highlight colors by group name (e.g., "Search", "Normal").
// Returns 1 if found, 0 if not found.
// fg_rgb and bg_rgb are output parameters (0x00RRGGBB format).
ZONVIE_API int zonvie_core_get_hl_by_name(
    zonvie_core *core,
    const char* name,
    uint32_t* fg_rgb,
    uint32_t* bg_rgb
);

// Return Neovim default background color as 0x00RRGGBB.
// Safe to call from within callbacks (no lock acquisition).
ZONVIE_API uint32_t zonvie_core_get_default_bg(zonvie_core *core);

// Query whether post-process bloom glow is currently enabled (lock-free atomic read).
// Safe to call from any thread (including the draw thread) without locking grid_mu.
ZONVIE_API bool zonvie_core_get_glow_enabled(zonvie_core *core);

// Query the glow bloom intensity (0.0–1.0) for the post-process composite pass (lock-free atomic read).
// Safe to call from any thread.
ZONVIE_API float zonvie_core_get_glow_intensity(zonvie_core *core);

// Read the current drawable/cell layout stored in core.
// Intended for use from on_flush_end callback (grid_mu is held, so the
// returned values match exactly what was used for the flush's NDC computation).
// Any output pointer may be NULL if the caller does not need that value.
ZONVIE_API void zonvie_core_get_layout(
    zonvie_core *core,
    uint32_t *out_drawable_w_px,
    uint32_t *out_drawable_h_px,
    uint32_t *out_cell_w_px,
    uint32_t *out_cell_h_px
);

// ========================================================================
// Message routing API
// ========================================================================

// Message event type
typedef enum {
    ZONVIE_MSG_EVENT_MSG_SHOW = 0,
    ZONVIE_MSG_EVENT_MSG_SHOWMODE = 1,
    ZONVIE_MSG_EVENT_MSG_SHOWCMD = 2,
    ZONVIE_MSG_EVENT_MSG_RULER = 3,
    ZONVIE_MSG_EVENT_MSG_HISTORY_SHOW = 4,
} zonvie_msg_event;

// Result of routing a message
typedef struct {
    zonvie_msg_view_type view;
    float timeout;  // -1 = no auto-hide, 0 = use default
} zonvie_route_result;

// Load config from file path.
// Returns 1 on success, 0 on failure.
ZONVIE_API int zonvie_core_load_config(
    zonvie_core *core,
    const char* path
);

// Route a message to the appropriate view based on config.
// Returns the view type and timeout for the given event, kind, and line count.
// line_count is used for min_lines/max_lines filters in routing rules.
ZONVIE_API zonvie_route_result zonvie_core_route_message(
    zonvie_core *core,
    zonvie_msg_event event,
    const char* kind,
    unsigned line_count
);

// ========================================================================
// Standalone config API (independent of zonvie_core)
// ========================================================================

typedef struct zonvie_config zonvie_config;

typedef struct zonvie_config_values {
    // font
    const char* font_family;
    float font_size;
    int32_t font_linespace;
    // window
    bool window_blur;
    float window_opacity;
    int32_t window_blur_radius;
    // scrollbar
    bool scrollbar_enabled;
    const char* scrollbar_show_mode;
    float scrollbar_opacity;
    float scrollbar_delay;
    // ext features
    bool cmdline_external;
    bool popup_external;
    bool messages_external;
    int32_t messages_ext_float_pos; // 0=window, 1=grid, 2=display
    int32_t messages_mini_pos;      // 0=window, 1=grid, 2=display
    bool tabline_external;
    const char* tabline_style;
    const char* tabline_sidebar_position;
    int32_t tabline_sidebar_width;
    bool windows_external;
    // neovim
    const char* neovim_path;
    bool neovim_ssh;
    const char* neovim_ssh_host;      /* NULL if not set */
    int32_t neovim_ssh_port;          /* 0 if not set */
    const char* neovim_ssh_identity;  /* NULL if not set */
    // log
    bool log_enabled;
    const char* log_path;             /* NULL if not set */
    // performance
    int32_t perf_glyph_cache_ascii;
    int32_t perf_glyph_cache_non_ascii;
    int32_t perf_hl_cache_size;
    int32_t perf_shape_cache_size;
    int32_t perf_atlas_size;
    // ime
    bool ime_disable_on_activate;
    bool ime_disable_on_modechange;
} zonvie_config_values;

/* Load config from TOML file. path may be NULL for defaults only.
   Returns opaque handle; call zonvie_config_destroy when done.
   Strings in zonvie_config_values are valid until zonvie_config_destroy. */
ZONVIE_API zonvie_config* zonvie_config_load(const char* path);

/* Get flat config values from handle. */
ZONVIE_API zonvie_config_values zonvie_config_get_values(const zonvie_config* config);

/* Free config handle and all associated memory. */
ZONVIE_API void zonvie_config_destroy(zonvie_config* config);

/* Non-blocking check whether a cell's highlight has a URL attribute.
   Returns: 1 = has url, 0 = no url, -1 = lock unavailable.
   Use from UI thread to avoid blocking when core is in handleRedraw. */
ZONVIE_API int32_t zonvie_core_try_cell_has_url(
    zonvie_core *core, int64_t grid_id, int32_t row, int32_t col);

/* Invalidate glyph cache, shape cache, and atlas state.
   Call when frontend font/scale parameters change outside of guifont flow.
   Must be called on core thread (e.g. from on_flush_begin callback).
   Triggers on_atlas_create callback to recreate atlas texture. */
ZONVIE_API void zonvie_core_invalidate_glyph_cache(zonvie_core *core);

/* Abort the current flush cycle.
   Call from on_flush_begin when the frontend cannot accept this flush
   (e.g. no free buffer set, or commandBuffer creation failed with pending atlas state).
   Sets an internal flag that causes the flush pipeline to skip vertex generation,
   atlas operations, and vertex submission.
   on_flush_end is still called (via defer) so the frontend can clean up.
   The aborted flush's dirty state is preserved — next flush retries everything. */
ZONVIE_API void zonvie_core_abort_flush(zonvie_core *core);

#ifdef __cplusplus
}
#endif
