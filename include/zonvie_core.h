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
    float ascent_px;             /* baseline offset from the cell top; see zonvie_glyph_bitmap */
    float descent_px;
    uint32_t bytes_per_pixel;    /* 1=grayscale, 3=ClearType RGB, 4=RGBA color (emoji) */
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
    float    ascent_px;          /* baseline offset in pixels from the cell top: the core
                                    places the text baseline at row_top + top_pad + ascent_px.
                                    Need not equal the font's nominal ascent — the frontend may
                                    re-balance it so ascent + descent fits the cell height
                                    (macOS centres the ink box; Windows sends DWrite's ascent). */
    float    descent_px;         /* font descent in pixels (stored; not used for placement) */
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
#define ZONVIE_DECO_COLOR_EMOJI   (1u << 10) /* Color glyph (emoji): sample RGBA, not coverage */
/* Solid-color quad that is foreground text, not background: block elements
   (U+2580..U+259F and friends) the core fills geometrically instead of
   rasterizing. Without it a frontend cannot tell them from a background
   cell, and fades them to the window's background alpha under blur while
   the atlas glyphs beside them stay opaque. */
#define ZONVIE_DECO_SOLID_GLYPH   (1u << 11)

typedef struct __attribute__((aligned(16))) zonvie_vertex {
    /* Grid-local pixels: the origin is the top-left of the grid this vertex
       belongs to and +y points down. The frontend converts to clip space with
       its own layer transform (scale 2/extent, -2/extent; offset -1, +1),
       where extent is cols*cell_w_px by rows*cell_h_px. Frontend-authored
       chrome may still be submitted in clip space under an identity layer
       transform. */
    float position[2];
    float texCoord[2];
    float color[4] __attribute__((aligned(16)));  /* 16-byte aligned to match Swift simd_float4 */
    int64_t grid_id;  /* 1 = global grid, >1 = sub-grid (float window) */
    uint32_t deco_flags;  /* ZONVIE_DECO_* flags for decoration type */
    float deco_phase;     /* phase offset for undercurl (cell column position) */
} zonvie_vertex;

/* Which layer an on_vertices_row callback carries */
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

/* on_vertices_row layers are independent:
   - When MAIN is not set, existing row contents must be retained.
   - CURSOR set carries the complete cursor layer for that grid; vert_count=0
     clears it. A cursor-only callback must not replace row contents.
   A MAIN callback with row_count=0, verts=NULL, and vert_count=0 publishes
   a layout-only zero-cell transition. total_rows/total_cols are authoritative,
   and at least one is zero. It clears the logical MAIN surface without
   treating a nonexistent row as row content. */

/* External grid (sub-grid) row scroll notification.
   Notifies the frontend that a sub-grid received a grid_scroll event.
   Fired once per grid per flush batch, only when a single scroll occurred
   in that batch (multiple scrolls in one batch are suppressed).
   This is a best-effort hint — the consumer MUST perform its own eligibility
   checks (e.g. abs(rows_delta) == 1, full-width region, no horizontal scroll)
   before applying any fast-path optimization such as row remapping or GPU blit.
   Fired after abort check, before clearDirty. */
typedef void (*zonvie_on_grid_row_scroll_fn)(
    void* ctx,
    int64_t grid_id,
    uint32_t row_start,
    uint32_t row_end,
    uint32_t col_start,
    uint32_t col_end,
    int32_t rows_delta,
    uint32_t total_rows,
    uint32_t total_cols
);

/* Modifier bitmask for zonvie_core_send_key_event.mods */
#define ZONVIE_MOD_CTRL  (1u << 0)
#define ZONVIE_MOD_ALT   (1u << 1) /* Meta/Alt */
#define ZONVIE_MOD_SHIFT (1u << 2)
#define ZONVIE_MOD_SUPER (1u << 3) /* Command on macOS, Win key on Windows */

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
   pixels of extra line spacing (Neovim 'linespace' option). May be negative —
   Neovim documents negative values for fonts that leave too much room between
   lines. The value is delivered unclamped; the frontend adds it to the font's
   cell height and floors the resulting row height at 1px. */
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

/* Called when Neovim sends the `restart` UI event (`:restart` command).
   listen_addr is the new server's listen address (TCP host:port or
   Unix socket path). Informational only — the core handles the actual
   reconnect; the frontend MUST NOT close its window or treat this as
   `on_exit`. The matching `on_exit` will not fire for this transition. */
typedef void (*zonvie_on_restart_fn)(
    void* ctx,
    const uint8_t* listen_addr, size_t listen_addr_len
);

/* Called when Neovim sends the `connect` UI event (`:connect <addr>`).
   server_addr is the address the UI is being hot-swapped to. Same
   reconnect semantics as `on_restart`; the only difference is that the
   previous server keeps running headless instead of dying. The frontend
   may use this to distinguish hot-swap (`:connect`) from server
   replacement (`:restart`) for logging or status display. */
typedef void (*zonvie_on_connect_fn)(
    void* ctx,
    const uint8_t* server_addr, size_t server_addr_len
);

/* Called when a grid should be displayed in an external window.
   grid_id: the grid to display externally
   win: Neovim window handle (for reference)
   rows, cols: dimensions of the grid
   start_row, start_col: position in global grid cell units (from win_pos/win_float_pos)
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

/* One grid placed on one surface. A surface is a single drawable: the main
   window, or one external window. Its surface_id is the id of its root grid
   (1 for the main window). layers[0] is always the root grid at (0,0). */
#define ZONVIE_LAYER_FOLLOWS_SCROLL (1u << 0)

typedef struct zonvie_layer {
    int64_t  grid_id;
    int64_t  anchor_grid;  /* grid this float is anchored to; == surface_id for the root */
    int32_t  x_px;         /* surface-local, top-left origin */
    int32_t  y_px;
    uint32_t rows;
    uint32_t cols;
    int32_t  z;            /* back-to-front index; 0 == root grid */
    uint32_t flags;        /* ZONVIE_LAYER_* */
} zonvie_layer;

/* Full replacement of the layer list for one surface. Fired inside the flush
   bracket, after on_external_window for a new surface and before that
   surface's row vertices, and only when the list changed. A grid missing from
   every surface keeps its buffers until on_grid_destroy; the frontend must
   tolerate a layer whose grid has no committed rows yet, and rows arriving for
   a grid that is in no layer. */
typedef void (*zonvie_on_surface_layout_fn)(
    void* ctx,
    int64_t surface_id,
    const zonvie_layer* layers,
    size_t count,
    uint32_t surface_rows,
    uint32_t surface_cols
);

/* Neovim destroyed the grid; the frontend may release its buffers. */
typedef void (*zonvie_on_grid_destroy_fn)(
    void* ctx,
    int64_t grid_id
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

/* Resolved Pmenu / PmenuSel colors (0x00RRGGBB).
   Passed alongside popupmenu_show so the frontend can style the container
   and selection without reverse-engineering colors from vertex data. */
typedef struct zonvie_popupmenu_colors {
    uint32_t pmenu_bg;
    uint32_t pmenu_fg;
    uint32_t pmenu_sel_bg;
    uint32_t pmenu_sel_fg;
} zonvie_popupmenu_colors;

/* Called when popup menu should be shown.
   items: array of completion items, or NULL when the core renders
          popup content via grid vertices (item_count is 0 in that case)
   item_count: number of items (0 when items is NULL)
   selected: currently selected item index (-1 if none)
   row: anchor row position
   col: anchor column position
   grid_id: which grid the popup is anchored to (1 = main, -100 = cmdline)
   colors: resolved Pmenu / PmenuSel highlight colors */
typedef void (*zonvie_on_popupmenu_show_fn)(
    void* ctx,
    const zonvie_popupmenu_item* items, size_t item_count,
    int32_t selected,
    int32_t row,
    int32_t col,
    int64_t grid_id,
    const zonvie_popupmenu_colors* colors
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

/* AI-agent work state for a tabpage (from the zonvie_agent_status RPC
   notification). Low 7 bits of state: 0=none, 1=idle (agent present, done),
   2=working/claude, 3=working/braille (codex & generic), 4=waiting for user
   input (a decision prompt is on screen). Bit 7 (0x80) is a "fire the OS
   notification now" flag set by the core when it detects a completion edge
   (only ever combined with base 1 or 4: 1="finished", 4="needs input").
   The frontend must render/animate the per-tab indicator from `state & 0x7F`
   only, and must NOT edge-detect notifications itself from successive calls
   -- a flagged report can target a tab that is not currently displaying the
   agent's terminal (the agent's buffer may be hidden). Fired immediately on
   change (not coupled to redraw, so a background-tab agent still updates). */
typedef void (*zonvie_on_agent_status_fn)(void* ctx, int64_t tab_handle, uint8_t state, const char* title, size_t title_len);

/* --- Clipboard callbacks --- */

/* Called to get clipboard content.
   register_name: "+" or "*" (system clipboard register)
   out_buf: output buffer for clipboard content (UTF-8); may be NULL when
            max_len is 0, in which case nothing is written and only the size
            is reported.
   out_len: on success, the TOTAL number of bytes available — not the number
            written. The implementation writes min(*out_len, max_len) bytes.
   max_len: capacity of out_buf in bytes
   Returns: 1 on success, 0 on failure

   Reporting the full size rather than the clamped one lets the caller detect
   truncation (*out_len > max_len) and retry with a large enough buffer, so a
   register bigger than any fixed staging buffer is delivered whole instead of
   being silently cut. Implementations must not clamp *out_len to max_len. */
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
    zonvie_on_vertices_row_fn on_vertices_row;
    zonvie_atlas_ensure_glyph_fn on_atlas_ensure_glyph;
    zonvie_atlas_ensure_glyph_styled_fn on_atlas_ensure_glyph_styled;
    zonvie_on_log_fn on_log;
    zonvie_on_guifont_fn on_guifont;
    zonvie_on_linespace_fn on_linespace;

    zonvie_on_exit_fn on_exit;
    zonvie_on_set_title_fn on_set_title;

    /* External window callbacks (ext_multigrid) */
    zonvie_on_external_window_fn on_external_window;
    zonvie_on_external_window_close_fn on_external_window_close;

    /* Called when cursor moves to a different grid.
       grid_id: the grid where cursor now resides (1 = global grid).
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
       Called when a grid receives a grid_scroll event from Neovim, so a
       frontend holding a pixel-based smooth scroll offset can reconcile it
       against content that has already moved (leaving both applied would
       double-shift the picture).

       rows_delta is the signed distance the content moved, in rows, positive
       when it moved up. Several scrolls of one grid within a redraw batch
       produce a single notification, and rows_delta is their sum — it is not
       always +/-1, and the count of notifications does not describe how far
       the content travelled. Reconcile against this value, not against the
       number of calls.

       Not every notification corresponds to a Neovim grid_scroll event. Where
       the view moved but Neovim repainted instead of shifting rows — which is
       what 'smoothscroll' does on a wrapped line — the movement win_viewport
       reported and no grid_scroll described is delivered here too, so this is
       the single report of "the content of this grid moved N screen rows"
       however Neovim chose to express it. A frontend holding a sub-cell scroll
       offset must give back that distance and retain the rows that left in
       both cases; one that only shifts whole rows can ignore the distinction,
       since the repainted rows arrive as ordinary row updates. */
    void (*on_grid_scroll)(void* ctx, int64_t grid_id, int32_t rows_delta);

    /* IME off notification callback.
       Called when IME should be turned off (e.g., on mode change when
       input.ime_disable_on_modechange is enabled, or via RPC zonvie_ime_off). */
    void (*on_ime_off)(void* ctx);

    /* Quit request callback (window close with unsaved check). */
    zonvie_on_quit_requested_fn on_quit_requested;

    /* Phase 2: Core-managed atlas callbacks.
       When all three are non-NULL, core owns shelf packing and UV computation.
       The old on_atlas_ensure_glyph / on_atlas_ensure_glyph_styled are not called.
       When any is NULL, falls back to Phase 1 (frontend-managed atlas). The
       core keeps that fallback implemented and test-covered, but both bundled
       frontends register all three and no longer ship a Phase 1 atlas of
       their own -- Phase 1 exists for embedders and older callers. */
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

    /* Main row-buffer scroll fast path notification.
       Optional optimization used by row-mode frontends to shift existing main-row
       buffers instead of receiving cached rows one by one via on_vertices_row. */

    /* External grid (sub-grid) row scroll notification (best-effort hint).
       Suppressed when multiple scrolls occur in the same batch.
       Consumer must validate eligibility before applying optimizations. */
    zonvie_on_grid_row_scroll_fn on_grid_row_scroll;

    /* Restart UI event observer (informational; core handles reconnect).
       Appended at the end of the struct to preserve ABI for older callers
       that pass a smaller callbacks_size to zonvie_core_create. */
    zonvie_on_restart_fn on_restart;

    /* Connect UI event observer (informational; core handles reconnect).
       Appended after on_restart for the same ABI-compat reason. */
    zonvie_on_connect_fn on_connect;

    /* AI-agent work state per tab. Appended at the end for ABI compat. */
    zonvie_on_agent_status_fn on_agent_status;

    /* Neovim-initiated main grid resize (`:set columns=` / `:set lines=`).
       Fired only when grid 1's reported size differs from the size the
       frontend last supplied via zonvie_core_update_layout_px, i.e. Neovim
       changed it rather than echoing the UI's own resize request.
       The frontend should resize its main window so the terminal area becomes
       cols x rows cells. The resulting zonvie_core_update_layout_px is what
       makes Neovim repaint at the new size, so the frontend must keep
       reporting the layout as usual after the resize.
       Runs on the core thread with grid_mu held: frontends must not perform
       blocking window work inline (post/dispatch to the UI thread instead).
       Appended at the end for ABI compat. */
    void (*on_main_grid_size)(void* ctx, uint32_t rows, uint32_t cols);

    /* Per-surface layer placement, and grid buffer lifetime. Appended at the
       end for ABI compat. */
    zonvie_on_surface_layout_fn on_surface_layout;
    zonvie_on_grid_destroy_fn on_grid_destroy;
} zonvie_callbacks;

void zonvie_core_set_log_enabled(zonvie_core *core, int enabled);

/* When enabled is non-zero, only [perf...] tagged log lines are emitted via
 * the on_log callback; all other debug logs are dropped at the Logger.write
 * boundary. Independent of zonvie_core_set_log_enabled — caller must still
 * enable logging for any output to appear. Intended for low-noise hot-path
 * profiling. */
void zonvie_core_set_log_perf_only(zonvie_core *core, int enabled);

/* Scroll-pipeline analysis mode: when enabled is non-zero, only [perf...]
 * and [scroll_debug] log lines are emitted, so the input -> grid_scroll ->
 * flush -> commit -> draw chain can be traced without other debug noise.
 * Takes precedence over zonvie_core_set_log_perf_only when both are set.
 * Independent of zonvie_core_set_log_enabled — caller must still enable
 * logging for any output to appear. */
void zonvie_core_set_log_scroll_only(zonvie_core *core, int enabled);

/* Verbose tier: when enabled is non-zero, the highest-frequency per-row /
 * per-glyph log lines ([perf] row_mode / row_mode_post, [shape_dump],
 * [glyph_quad]) are also emitted. Off by default because their formatting
 * and I/O cost is heavy enough to perturb the measured pipeline (~1-2ms per
 * flush). Independent of zonvie_core_set_log_enabled — caller must still
 * enable logging for any output to appear. */
void zonvie_core_set_log_verbose(zonvie_core *core, int enabled);

/* Enable ext_cmdline UI extension (must call before zonvie_core_start).
 * When enabled, cmdline is rendered as a separate external window. */
void zonvie_core_set_ext_cmdline(zonvie_core *core, int enabled);

/* Enable ext_popupmenu UI extension (must call before zonvie_core_start).
 * When enabled, popup menu events are sent to frontend callbacks. */
void zonvie_core_set_ext_popupmenu(zonvie_core *core, int enabled);

/* Enable ext_messages UI extension (must call before zonvie_core_start).
 * When enabled, message events are sent to frontend callbacks instead of
 * being rendered in the global grid. Messages are displayed as external
 * floating windows. */
void zonvie_core_set_ext_messages(zonvie_core *core, int enabled);

/* Enable ext_tabline UI extension (must call before zonvie_core_start).
 * When enabled, tabline_update events are sent to frontend callbacks
 * for Chrome-style tab rendering in titlebar. */
void zonvie_core_set_ext_tabline(zonvie_core *core, int enabled);

/* Enable ext_windows UI extension (must call before zonvie_core_start).
 * When enabled, Neovim external windows are rendered as separate OS windows. */
ZONVIE_API void zonvie_core_set_ext_windows(zonvie_core *core, int enabled);

/* Process due message timeouts and render-maintenance retries. Frontends
 * normally drive this from the one-shot deadline returned below so messages
 * and transient glyph failures recover while Neovim is idle. */
void zonvie_core_tick_msg_throttle(zonvie_core *core);

/* Returns milliseconds until the earliest pending message or render-
 * maintenance deadline, clamped to >= 0. Returns -1 if no timeout is armed.
 * Lets the frontend schedule a single one-shot timer instead of calling the
 * tick function every frame. */
int64_t zonvie_core_next_msg_timeout_ms(zonvie_core *core);

/* Non-blocking version of zonvie_core_next_msg_timeout_ms.
 * Returns the same values on success, or -2 if the core's grid lock could
 * not be acquired without blocking. -2 must NOT be treated as "nothing
 * pending" (that is -1, a real answer) -- on -2 the caller should re-arm
 * its timer for a short fixed retry instead of trusting a stale value. */
int64_t zonvie_core_try_next_msg_timeout_ms(zonvie_core *core);

/* Report whether the pointer rests on a message ext_float window (grid -102 or
 * -103; any other grid_id is ignored). While hovered the view's auto-hide
 * countdown is stopped -- the user is reading it, or reaching for its copy
 * button -- and leaving restarts it at full length.
 * Both transitions move the earliest pending deadline, so the caller must
 * re-arm its one-shot timer from zonvie_core_next_msg_timeout_ms afterwards. */
void zonvie_core_set_msg_hover(zonvie_core *core, int64_t grid_id, int hovered);

/* Enable blur transparency for background (macOS only).
 * When enabled, default background uses semi-transparent alpha for blur effect.
 * Windows should NOT enable this (causes rendering artifacts). */
void zonvie_core_set_blur_enabled(zonvie_core *core, int enabled);

/* Set inherit_cwd flag (must call before zonvie_core_start).
 * When enabled, child process inherits parent's CWD instead of $HOME. */
void zonvie_core_set_inherit_cwd(zonvie_core *core, int enabled);

/* Set the window background opacity used for the default background colour.
 * Clamped to [0.0, 1.0]; 1.0 (fully opaque) is the default. */
void zonvie_core_set_background_opacity(zonvie_core *core, float opacity);

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
                   Must be non-zero when cb is non-NULL: a zero size cannot
                   bound the read, so the core installs no callbacks at all.
   ctx:            opaque frontend context forwarded to all callbacks. */
zonvie_core *zonvie_core_create(zonvie_callbacks *cb, size_t callbacks_size, void *ctx);
/* Must be called from a lifecycle thread which is not currently executing a
   Zonvie callback. Calling destroy re-entrantly from a callback only requests
   shutdown and retains the handle to avoid self-join and callback-context
   use-after-free; the frontend must call destroy again later from its
   lifecycle thread to release the handle. That final call must occur only
   after the callback and the enclosing Core API invocation have both fully
   returned, with no other Core API call in flight. It must have exactly one
   externally serialized owner; concurrent lifecycle destroy calls are
   unsupported. No new API call may start after the callback-thread request,
   and no API may use the handle after a valid lifecycle-thread destroy
   returns. */
void zonvie_core_destroy(zonvie_core *core);

int  zonvie_core_start(zonvie_core *core, const char *nvim_path, unsigned rows, unsigned cols);

/* Start in connect mode: attach to a running Neovim server at
   `listen_addr` instead of spawning a child. Same lifecycle and
   callbacks as `zonvie_core_start`; the only difference is the
   initial transport.

   Address formats by platform:
       POSIX (macOS, Linux): TCP "host:port" or Unix socket path
       Windows:              named pipe path, e.g. "\\\\.\\pipe\\nvim.31920.0"
                             (TCP and Unix sockets are not yet supported)

   Returns 0 on success, negative on error:
       -1 invalid handle, -2 thread spawn failed, -3 invalid address.
   Address validity is checked synchronously: parse failures and
   platform-unsupported forms (e.g. TCP on Windows) return -3 before
   the run loop is started. */
int  zonvie_core_start_connect(
    zonvie_core *core,
    const uint8_t *listen_addr, size_t listen_addr_len,
    unsigned rows, unsigned cols);

/* Callback-safe. A callback-thread call requests shutdown without waiting;
   resource teardown is completed by a later lifecycle-thread stop/destroy. */
void zonvie_core_stop(zonvie_core *core);

/* Notify the core that actual layout dimensions are ready.
   Must be called from the UI thread after the renderer is initialized and the
   real rows/cols are computed. This unblocks the RPC thread so it sends
   nvim_ui_attach with the correct size, preventing Neovim from rendering the
   initial splash at the wrong position before a subsequent resize corrects it.
   Must be called after zonvie_core_start() (including devcontainer restarts). */
void zonvie_core_notify_layout_ready(zonvie_core *core, unsigned rows, unsigned cols);

/* Acquire / release the core's grid mutex from a frontend (UI) thread.
   Lets a frontend run a multi-step state mutation (e.g. font change +
   layout update + glyph cache invalidation) atomically with respect to
   the RPC thread's redraw cycle, in the same way that the in-flush
   onGuifont path is atomic.
   Every lock MUST be balanced with an unlock; while holding the lock,
   the caller MUST NOT call any core API that itself acquires grid_mu
   (use zonvie_core_update_layout_px_locked instead of the regular
   updateLayoutPx wrapper, etc.). */
void zonvie_core_lock_grid(zonvie_core *core);
void zonvie_core_unlock_grid(zonvie_core *core);

/* updateLayoutPx variant for callers that already hold grid_mu via
   zonvie_core_lock_grid. Skips the redraw_thread_id check and the
   internal grid_mu acquisition that the regular API performs. A standalone
   caller must request a full core flush after releasing grid_mu. */
void zonvie_core_update_layout_px_locked(
    zonvie_core *core,
    unsigned drawable_w_px,
    unsigned drawable_h_px,
    unsigned cell_w_px,
    unsigned cell_h_px
);

void zonvie_core_send_input(zonvie_core *core, const unsigned char *data, int len);

/* Timestamp helper for perf-log correlation across frontend/core stages. */
ZONVIE_API int64_t zonvie_core_perf_now_ns(void);

/* Build-time version string (from `git describe`), e.g. "v0.3.21" or
   "v0.3.21-9-g4eb0177". The returned pointer is static and null-terminated;
   never null. Not tied to a core instance. */
ZONVIE_API const char *zonvie_version(void);

/* Record the latest frontend input trace marker for redraw/flush correlation. */
ZONVIE_API void zonvie_core_note_input_trace(
    zonvie_core *core,
    uint64_t seq,
    int64_t sent_ns
);

/* Non-blocking version of zonvie_core_note_input_trace. Drops the sample
   (no [perf_input] trace line for this seq) if the core's grid lock could
   not be acquired without blocking, rather than blocking the input-send
   path with the very lock this trace exists to measure contention on.
   Returns true if the sample was recorded. */
ZONVIE_API bool zonvie_core_try_note_input_trace(
    zonvie_core *core,
    uint64_t seq,
    int64_t sent_ns
);

/* Notify Neovim of window focus change via nvim_ui_set_focus.
   Triggers FocusGained/FocusLost autocommands in Neovim.
   gained: true when window gains focus, false when it loses focus */
ZONVIE_API void zonvie_core_set_focus(zonvie_core *core, bool gained);

/* Set a global Neovim option via nvim_set_option_value.
   Used by frontends to sync the effective `guifont` back to Neovim so
   `:set guifont?` reports what the frontend is actually rendering.
   name: option name (e.g. "guifont")
   value: option value string */
ZONVIE_API void zonvie_core_set_option_value(
    zonvie_core *core,
    const unsigned char *name,
    size_t name_len,
    const unsigned char *value,
    size_t value_len);

/* Send a command to Neovim via nvim_command RPC (does not show in cmdline).
   cmd: command string (e.g., "lua vim.notify('hello')")
   len: length of command string */
ZONVIE_API void zonvie_core_send_command(zonvie_core *core, const unsigned char *cmd, size_t len);

/* Set/update IME preedit (composition) text.
   text: UTF-8 preedit string; len: its byte length.
   target_start/target_end: UTF-8 byte offsets into text marking the clause
   being converted (highlighted distinctly). Pass target_start >= target_end
   when there is no target clause.
   Returns 1 if the core placed the preedit as an inline extmark (frontend
   should hide its own preedit overlay), 0 if the frontend should display the
   preedit itself (extmark mode disabled, or not in insert/replace mode). */
ZONVIE_API int zonvie_core_set_preedit(zonvie_core *core, const unsigned char *text, size_t len,
                                       size_t target_start, size_t target_end);

/* Clear any inline preedit extmark (call on IME commit or cancel). */
ZONVIE_API void zonvie_core_clear_preedit(zonvie_core *core);

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
    /* Total buffer line count for this grid (from win_viewport), 0 if unknown.
     * Lets a frontend decide logical scrollability (line_count > content rows)
     * without a blocking viewport query on the input path. */
    int64_t line_count;
    /* For float sub-grids, the grid this float is anchored to (1 = editor/global).
     * Lets a frontend route smooth-scroll following: a window-anchored float
     * follows only that window, not any window it merely overlaps. */
    int64_t anchor_grid;
    /* 1 if this float has been repositioned (row changed) since creation, i.e. it
     * tracks the buffer on scroll. A fixed float stays 0 and must not pixel-shift. */
    int32_t follows_scroll;
    /* 1 if this grid is an external (separate top-level) window. Such grids are
     * reported with start (0,0) and must be excluded from main-window hit-testing. */
    int32_t is_external;
} zonvie_grid_info;

/* Viewport info for scrollbar rendering */
typedef struct zonvie_viewport_info {
    int64_t grid_id;      /* Grid ID (1 = global grid) */
    int64_t topline;      /* First visible line (0-based) */
    int64_t botline;      /* First line below window (exclusive) */
    int64_t line_count;   /* Total lines in buffer */
    int64_t curline;      /* Current cursor line */
    int64_t curcol;       /* Current cursor column */
    int64_t scroll_delta; /* Screen rows scrolled since last update. Counts
                             displayed rows, not buffer lines: with 'wrap' a
                             one-line scroll reports every row the view moved,
                             and under 'smoothscroll' it reports single rows
                             while topline stays put. Positive = scrolled down. */
} zonvie_viewport_info;

/* Get viewport info for a specific grid (for scrollbar rendering).
   Returns 1 if found, 0 if not found or grid has no viewport info. */
ZONVIE_API int zonvie_core_get_viewport(
    zonvie_core *core,
    int64_t grid_id,
    zonvie_viewport_info *out_viewport
);

/* Non-blocking version of zonvie_core_get_viewport for input/render paths.
   Returns 1 if found, 0 if not found, or -1 if the grid lock could not be
   acquired (caller should reuse its last cached value). */
ZONVIE_API int32_t zonvie_core_try_get_viewport(
    zonvie_core *core,
    int64_t grid_id,
    zonvie_viewport_info *out_viewport
);

/* Borrow 'smoothscroll' for a grid's window while a trackpad gesture runs, and
   hand it back when it ends (enable=0).

   A 'wrap'ped window can otherwise only move a whole buffer line at a time,
   however many screen rows that line occupies — one wheel event books
   'mousescroll' rows and moves every row those lines span. With 'smoothscroll'
   the quantum is one screen row and a wheel event moves exactly the
   'mousescroll' count, so a sub-cell scroll model's booking and the movement it
   gets back agree.

   The previous value is stashed in a window variable and restored from it, so a
   restore arriving twice is harmless. Windows without 'wrap' are skipped: the
   option does nothing there.

   No-op off macOS (sub-cell trackpad scrolling is a macOS frontend feature).
   Returns 1 when the request was issued, 0 when it could not be (grid lock
   busy, or no window known for the grid yet) — the caller must try again, which
   matters most for the restore. */
ZONVIE_API int32_t zonvie_core_set_gesture_smooth_scroll(
    zonvie_core *core,
    int64_t grid_id,
    bool enable
);

/* Get list of visible grids for hit-testing.
   Returns number of grids written (up to max_count).
   Global grid (id=1) is always included first. */
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

/* Non-blocking complete visible-grid snapshot for fixed-capacity caches.
   On success, returns the number of initialized entries in out_grids and
   writes the total visible-grid count from the same grid-lock snapshot to
   out_total_count. A return value smaller than *out_total_count means the
   output was truncated. max_count may be zero with out_grids=NULL for a
   count-only query, and must not exceed INT32_MAX.

   Returns -1 when the grid lock is busy or any argument is invalid. On -1,
   out_grids and *out_total_count are left unchanged. There is deliberately no
   blocking counterpart: render/input callers should retain their last complete
   cache rather than stall behind redraw. */
ZONVIE_API int32_t zonvie_core_try_get_visible_grids_complete(
    zonvie_core *core,
    zonvie_grid_info *out_grids,
    size_t max_count,
    size_t *out_total_count
);

/* Get current cursor position.
   Returns cursor row and column (0-based) in out_row and out_col.
   Returns the grid_id of the cursor (1 = global grid). */
ZONVIE_API int64_t zonvie_core_get_cursor_position(
    zonvie_core *core,
    int32_t *out_row,
    int32_t *out_col
);

/* Non-blocking version of zonvie_core_get_cursor_position.
   Returns the grid_id of the cursor on success, or -2 if the core's grid
   lock could not be acquired without blocking, or if core is null
   (grid_id is always >= 1, so -2 is unambiguous either way). Note this
   differs from the blocking zonvie_core_get_cursor_position above, which
   reserves -1 specifically for a null core. */
ZONVIE_API int64_t zonvie_core_try_get_cursor_position(
    zonvie_core *core,
    int32_t *out_row,
    int32_t *out_col
);

/* Get Neovim window handle (winid) for a grid.
   Pass grid_id=-1 to get the winid for the cursor's current grid.
   Returns 0 if the mapping is not available. */
ZONVIE_API int64_t zonvie_core_get_win_id(zonvie_core *core, int64_t grid_id);

/* Get current mode name (e.g., "normal", "insert", "terminal").
   Returns a thread-local null-terminated snapshot. Do not free. The pointer
   remains valid until the next call on the same thread.
   Returns empty string if core is null. */
ZONVIE_API const char* zonvie_core_get_current_mode(zonvie_core *core);

/* Get/set option_as_meta value (0=both, 1=none, 2=only_left, 3=only_right).
   Settable via config (initial) or RPC notification "zonvie_option_as_meta" (runtime). */
ZONVIE_API uint8_t zonvie_core_get_option_as_meta(zonvie_core *core);
ZONVIE_API void zonvie_core_set_option_as_meta(zonvie_core *core, uint8_t value);

/* Rows one mouse-wheel event scrolls: the 'ver' component of Neovim's
   'mousescroll'. Reported by an auto-injected reporter and refreshed when the
   option changes, so sub-cell scrolling can account an event as the N rows it
   is actually worth. 'ver:0' disables mouse scrolling in Neovim altogether —
   it is not a page-relative setting — and reports 0, as does a null core.
   The reporter is installed on macOS only; elsewhere this returns Neovim's
   default (3) and should not be relied on. */
ZONVIE_API uint32_t zonvie_core_get_mousescroll_ver(zonvie_core *core);

/* Check if cursor is visible.
   Returns false during busy_start, true after busy_stop. */
ZONVIE_API bool zonvie_core_is_cursor_visible(zonvie_core *core);

/* Non-blocking combined read of current mode name + cursor visibility.
   Copies the null-terminated mode name into out_mode_buf (truncated to fit
   buf_len, including the terminator) and writes cursor visibility to
   *out_cursor_visible. Unlike zonvie_core_get_current_mode, the string is
   copied while the lock is held rather than returning a pointer into core
   memory that could be concurrently rewritten after unlock.
   Returns 1 on success, -1 if the core's grid lock could not be acquired
   without blocking (caller should keep using its last-known cached
   mode/visibility in that case). -1 is also returned for invalid arguments
   (null core, null out_mode_buf, buf_len == 0, or null out_cursor_visible)
   -- these share the busy sentinel rather than a distinct value since no
   caller is expected to pass invalid arguments in practice. */
ZONVIE_API int32_t zonvie_core_try_get_mode_state(
    zonvie_core *core,
    char *out_mode_buf,
    size_t buf_len,
    bool *out_cursor_visible
);

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

/* Non-blocking version of zonvie_core_get_cursor_blink. On success, fills
   all three out params and returns true. On busy, leaves every out param
   UNTOUCHED (no "safe default" is written) -- callers should pre-seed the
   out params with their own last-known values before calling, so an
   untouched param naturally means "serve the cached value". Returns false
   if the lock could not be acquired without blocking, or core is null. */
ZONVIE_API bool zonvie_core_try_get_cursor_blink(
    zonvie_core *core,
    uint32_t *out_blink_wait_ms,
    uint32_t *out_blink_on_ms,
    uint32_t *out_blink_off_ms
);

/* Send mouse scroll event to Neovim.
   direction: "up", "down", "left", or "right"
   modifier: "" or combination of "S" (shift), "C" (ctrl), "A" (alt), "D" (super/command)
   grid_id: target grid (1 = global grid)
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

/* Same operation, returning true while an aborted/throttled update still
   needs another frontend timer retry. */
ZONVIE_API bool zonvie_core_process_pending_msg_scroll_retry_needed(
    zonvie_core *core
);

/* Send mouse input event to Neovim (click, drag, release).
   button: "left", "right", "middle", "x1", "x2"
   action: "press", "drag", "release"
   modifier: "" or combination of "S" (shift), "C" (ctrl), "A" (alt), "D" (super/command)
   grid_id: target grid (1 = global grid)
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

// Non-blocking version of zonvie_core_update_layout_px, for callers that must
// not stall (e.g. drag-resize on the UI thread) if the core thread is
// mid-flush holding grid_mu. Returns false ("busy", grid_mu not acquired) if
// the caller must retry shortly -- unlike a read-only trace, a resize is a
// write that must not be silently dropped on contention. A NULL core returns
// true (nothing to do); "busy" is reserved for genuine lock contention, so a
// caller can retry on false without risking an infinite loop.
//
// screen_cols folds zonvie_core_set_screen_cols into the same lock: pass 0 to
// keep the drawable-width-derived value, or a display-derived cell count to
// override it (macOS cmdline max width). Calling the blocking
// zonvie_core_set_screen_cols afterwards would re-acquire grid_mu and negate
// the non-blocking guarantee. cmdline_default_cols folds
// zonvie_core_set_cmdline_default_cols in for the same reason; 0 keeps the
// current value.
//
// Safe to call from a redraw callback on the core thread: that path applies
// the layout under the already-held grid_mu and skips the flush retry, which
// the in-progress batch performs anyway.
ZONVIE_API bool zonvie_core_try_update_layout_px(
    zonvie_core *core,
    uint32_t drawable_w_px,
    uint32_t drawable_h_px,
    uint32_t cell_w_px,
    uint32_t cell_h_px,
    uint32_t screen_cols,
    uint32_t cmdline_default_cols
);

// Set screen width in cells (for cmdline max width).
// This should be called when screen size or cell size changes.
ZONVIE_API void zonvie_core_set_screen_cols(zonvie_core *core, uint32_t cols);

// Set the cmdline's default width in cells: the width it shows before its
// content needs more, clamped up by zonvie_core_set_screen_cols. Only the
// frontend knows the window chrome beside the cmdline grid, so it derives this
// from the main window width. Pass 0 to fall back to the main grid's width.
ZONVIE_API void zonvie_core_set_cmdline_default_cols(zonvie_core *core, uint32_t cols);

// Get highlight colors by group name (e.g., "Search", "Normal").
// Returns 1 if found, 0 if not found.
// fg_rgb and bg_rgb are output parameters (0x00RRGGBB format).
ZONVIE_API int zonvie_core_get_hl_by_name(
    zonvie_core *core,
    const char* name,
    uint32_t* fg_rgb,
    uint32_t* bg_rgb
);

// Batched version of zonvie_core_get_hl_by_name: looks up `count` group
// names under a single grid_mu acquisition instead of one lock round-trip
// per name. names/out_fg_rgb/out_bg_rgb/out_found must each have length
// count. A null entry in names writes 0/0/0 to its out slots rather than
// leaving them untouched, so the out arrays may be passed uninitialized.
// Returns 1 on success, 0 if core/arrays are null.
ZONVIE_API int zonvie_core_get_hl_by_names_batch(
    zonvie_core *core,
    const char *const *names,
    uint32_t *out_fg_rgb,
    uint32_t *out_bg_rgb,
    int *out_found,
    size_t count
);

// Return Neovim default background color as 0x00RRGGBB.
// Safe to call from within callbacks (no lock acquisition).
ZONVIE_API uint32_t zonvie_core_get_default_bg(zonvie_core *core);

// Check whether an external grid originated from a floating window
// (nvim_open_win with external=true) vs a regular split externalized by ext_windows.
// Returns 1 if float-origin external, 0 otherwise.
ZONVIE_API int zonvie_core_is_float_external(zonvie_core *core, int64_t grid_id);

// Get the current emoji cluster context during flush.
// Returns a pointer to the cluster scalars (uint32_t codepoints) and writes the
// count to *out_len.  Valid only during on_rasterize_glyph callbacks.
// Returns NULL with *out_len=0 when no cluster context is active.
ZONVIE_API const uint32_t *zonvie_core_get_emoji_cluster(zonvie_core *core, uint8_t *out_len);

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
    /* Newline-separated candidate list in the same form the
       `on_guifont` callback delivers:
           "<name>\t<size>[\t<features>]\n<name>\t<size>...".
       Built from [font] family with the same parsing rules as nvim's
       `guifont` (comma-separated, backslash escapes, per-entry `:hN`
       for size, `+ss01`/`-liga`/`cv02=3` for OpenType features).
       Entries without `:hN` inherit `font_size`. The frontend should
       try each candidate in order and pick the first one that loads
       on the system. */
    const char* font_family;
    float font_size;
    int32_t font_linespace;
    /* True when the user explicitly set [font] family / size in config.toml.
       Frontends should prefer config over nvim's default `guifont` (which
       nvim sends at ui_attach even when the user hasn't set one). */
    bool font_family_explicit;
    bool font_size_explicit;
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
    bool cmdline_copy_button;
    bool popup_external;
    bool messages_external;
    bool messages_copy_button;
    int32_t messages_ext_float_pos; // 0=window, 1=grid, 2=display
    int32_t messages_mini_pos;      // 0=window, 1=grid, 2=display
    bool tabline_external;
    const char* tabline_style;
    const char* tabline_sidebar_position;
    int32_t tabline_sidebar_width;
    bool tabline_agent_indicator;
    bool tabline_agent_notification;
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
    bool log_perf_only;               /* true = drop non-[perf...] lines */
    bool log_scroll_only;             /* true = [perf...] + [scroll_debug] only */
    bool log_verbose;                 /* true = also emit per-row/per-glyph lines */
    // performance
    int32_t perf_glyph_cache_ascii;
    int32_t perf_glyph_cache_non_ascii;
    int32_t perf_hl_cache_size;
    int32_t perf_shape_cache_size;
    int32_t perf_atlas_size;
    // ime
    bool ime_disable_on_activate;
    bool ime_disable_on_modechange;
    uint8_t ime_option_as_meta;  // 0=both, 1=none, 2=only_left, 3=only_right
    // shaders (custom post-process). Path array accessed via
    // zonvie_config_get_shader_count / zonvie_config_get_shader_path.
    bool shader_enabled;
    uint8_t shader_post_process;  // 0=after_bloom, 1=before_bloom, 2=replace_bloom
    bool shader_preserve_alpha;   // keep terminal alpha through the shader bridge
    // input
    bool input_swap_colon_semicolon;  // swap `:` and `;` on single keypresses
    // server (single-instance file open). single_instance is Windows-only and
    // read directly from the parsed config by the Windows frontend, so it is
    // not exposed here.
    const char* server_open_mode;  // "tab" or "current"
} zonvie_config_values;

/* Load config from TOML file. path may be NULL for defaults only.
   Returns opaque handle; call zonvie_config_destroy when done.
   Strings in zonvie_config_values are valid until zonvie_config_destroy. */
ZONVIE_API zonvie_config* zonvie_config_load(const char* path);

/* Get flat config values from handle. */
ZONVIE_API zonvie_config_values zonvie_config_get_values(const zonvie_config* config);

/* Free config handle and all associated memory. */
ZONVIE_API void zonvie_config_destroy(zonvie_config* config);

/* Number of custom shader passes configured in [shaders].paths. */
ZONVIE_API uint32_t zonvie_config_get_shader_count(const zonvie_config* config);

/* Get the i-th custom shader path. Returns NULL if index is out of range.
   String is valid until zonvie_config_destroy. */
ZONVIE_API const char* zonvie_config_get_shader_path(const zonvie_config* config, uint32_t index);

/* Non-blocking check whether a cell's highlight has a URL attribute.
   Returns: 1 = has url, 0 = no url, -1 = lock unavailable.
   Use from UI thread to avoid blocking when core is in handleRedraw. */
ZONVIE_API int32_t zonvie_core_try_cell_has_url(
    zonvie_core *core, int64_t grid_id, int32_t row, int32_t col);

/* Non-blocking extraction of a grid's rendered text as UTF-8 (no NUL is
   written). Rows are joined with '\n', each row is trimmed of trailing
   blanks, leading/trailing blank rows are dropped, and a wide glyph's
   continuation cell contributes nothing.
   Returns the byte length the full text needs, or -1 when the grid lock is
   unavailable. When the return value is <= out_cap, out_buf holds the
   complete text; otherwise retry with a buffer of the returned size.
   Use from the UI thread: a blocking lock would deadlock against
   handleRedraw callbacks that wait on the UI thread. */
ZONVIE_API intptr_t zonvie_core_try_get_grid_text(
    zonvie_core *core, int64_t grid_id, uint8_t *out_buf, size_t out_cap);

/* Invalidate glyph cache, shape cache, and atlas state.
   Call when frontend font/scale parameters change outside of guifont flow.
   Must be called on core thread (e.g. from on_flush_begin callback).
   Triggers on_atlas_create callback to recreate atlas texture. */
ZONVIE_API void zonvie_core_invalidate_glyph_cache(zonvie_core *core);

/* Abort the current flush cycle.
   Call from on_flush_begin or on_flush_end when the frontend cannot accept
   this flush (e.g. no free buffer set, or a late buffer commit failed).
   Sets an internal flag that causes the flush pipeline to skip vertex generation,
   atlas operations, and vertex submission when called before those stages.
   An on_flush_end abort invalidates the current core accounting ledger and
   restores dirty state before the flush transaction returns.
   on_flush_end is still called (via defer) so the frontend can clean up.
   The aborted flush's dirty state is preserved — next flush retries everything. */
ZONVIE_API void zonvie_core_abort_flush(zonvie_core *core);

/* Mark the current UI session failed after a frontend-side fixed physical
   rendering-resource budget rejects capacity provisioning. Frontend physical
   storage is independent of the core's logical vertex budgets because
   buffering and copy-on-write may retain multiple copies. A core-valid frame
   is therefore not guaranteed to fit every frontend's physical representation.
   This is terminal for the session; callers must not schedule another flush
   retry. */
ZONVIE_API void zonvie_core_fail_render_budget(zonvie_core *core);

/* Returns true when the flush that JUST ran detected an atlas reset during
   the deferred external-grid pass, after main vertices for this same flush
   were already dispatched with pre-reset UVs. Call from on_flush_end,
   BEFORE committing, while grid_mu is still held. When true, the frontend
   must cancel this flush's commit entirely (same handling as an allocation
   failure: cancel brackets instead of publishing) — committing would
   present main-grid vertices sampling the wrong (freshly repacked) atlas
   for one frame. The core has already scheduled a corrected full resend for
   the next flush; cancelling here only prevents showing the corrupted
   frame, no data is lost. */
ZONVIE_API bool zonvie_core_flush_had_atlas_corruption(zonvie_core *core);

/* Returns true when the flush that JUST ran was aborted — either by an
   explicit frontend zonvie_core_abort_flush() call, or by an internal Zig
   error (e.g. OOM growing a persistent composition buffer) caught inside
   onFlush itself. Call from on_flush_end, BEFORE committing, while grid_mu
   is still held. When true, the frontend must cancel this flush's commit —
   whatever partial write-set was composed before the abort is incomplete
   and must not be presented as a full frame. Dirty state is preserved
   either way, so cancelling loses no data; call zonvie_core_retry_flush
   once frontend capacity recovers (or after an internal-error backoff) to
   resend it. */
ZONVIE_API bool zonvie_core_flush_was_aborted(zonvie_core *core);

/* Returns false when the last abort was a fixed resource-limit violation.
   Such a flush must be cancelled but not scheduled for automatic retry. */
ZONVIE_API bool zonvie_core_flush_is_retryable(zonvie_core *core);

/* Retry a flush that was previously aborted via zonvie_core_abort_flush.
   Flushes are normally driven by incoming Neovim redraw batches; an abort
   preserves dirty state but does NOT by itself cause another flush attempt.
   If the condition that caused the abort (no free buffer set, OOM) clears
   with no further redraw event arriving, content would stay unflushed
   forever without this. Call once frontend capacity is recovered — a
   one-shot retry timer armed right after the abort (matching the existing
   grid_mu-contention retry idiom) is the expected usage pattern.
   Calls onFlush() unconditionally — it already short-circuits into
   near-zero work when nothing is actually dirty (main, cursor, or any
   subgrid/external state), same as any no-op Neovim redraw batch. */
ZONVIE_API void zonvie_core_retry_flush(zonvie_core *core);

/* Same effect as zonvie_core_retry_flush, for a caller that ALREADY holds
   grid_mu via zonvie_core_lock_grid. This allows a frontend retry timer to
   acquire grid_mu, revalidate that its retry generation is still current,
   and execute the flush without reopening a race against a normal redraw.
   The caller must release grid_mu with zonvie_core_unlock_grid afterward. */
ZONVIE_API void zonvie_core_retry_flush_locked(zonvie_core *core);

/* Force every grid to be treated as dirty on the next flush attempt.
   For failures discovered outside the on_flush_begin/on_flush_end transaction,
   after onFlush has returned and already cleared its dirty state. Call
   zonvie_core_retry_flush afterward (or rely on the next Neovim redraw) to
   actually drive the next attempt.
   Takes grid_mu itself — call ONLY from a context that does not already
   hold it (e.g. a main-thread retry timer). Do NOT call from
   on_flush_begin/on_flush_end (core/RPC thread, grid_mu held for the
   entire handleRedraw duration) — use zonvie_core_force_resend_locked
   there instead, or this self-deadlocks on the non-recursive grid_mu. */
ZONVIE_API void zonvie_core_force_resend(zonvie_core *core);

/* Same effect as zonvie_core_force_resend, for callers that ALREADY hold
   grid_mu — specifically on_flush_begin/on_flush_end. */
ZONVIE_API void zonvie_core_force_resend_locked(zonvie_core *core);

/* ========================================================================
   Custom shader cross-compilation (Shadertoy / Ghostty compatible GLSL)
   ======================================================================== */

typedef enum {
    ZONVIE_SHADER_TARGET_MSL  = 0, /* Metal Shading Language (macOS) */
    ZONVIE_SHADER_TARGET_HLSL = 1, /* High-Level Shading Language (D3D11 on Windows) */
} zonvie_shader_target;

/* Per-frame uniforms made available to custom shaders. Layout mirrors the
   `layout(std140, binding = 1) uniform ZonvieShaderUniforms { ... }` block
   declared by the Shadertoy preamble in `src/core/shader_compiler.zig`.
   Frontends populate this struct in place and upload 160 bytes to the
   uniform buffer each frame.

   Field order and offsets are load-bearing; do not reorder. std140 lays
   iTime into the trailing 4 bytes of iResolution's 16-byte slot.

   iResolution is the MAIN window's drawable size for every view (so the
   shader sees one unified coordinate space across windows). iWindowOffset
   and iWindowSize describe the view's rectangle within that coordinate
   space in pixels, with top-left origin. For the main window itself,
   iWindowOffset is (0,0) and iWindowSize equals iResolution.xy. */
typedef struct zonvie_shader_uniforms {
    float    iResolution[3];          /* 0..11   xy = main window drawable px, z = pixel aspect */
    float    iTime;                   /* 12..15  seconds since shader start */
    float    iMouse[4];               /* 16..31  Shadertoy iMouse (xy = cursor px, zw = click px).
                                                   NOT implemented — always zero. Mouse plumbing
                                                   lands in a later revision; shaders that read iMouse
                                                   see (0, 0, 0, 0) today. */
    float    iDate[4];                /* 32..47  year, month, day, seconds in day */
    float    iTimeDelta;              /* 48..51  seconds since previous frame */
    int32_t  iFrame;                  /* 52..55  frame counter */
    float    iSampleRate;             /* 56..59  not used; always 44100 */
    float    iFrameRate;              /* 60..63  frames per second (running average) */
    float    iWindowOffset[2];        /* 64..71  this view's top-left in main drawable px */
    float    iWindowSize[2];          /* 72..79  this view's own drawable size in px */
    /* Ghostty 1.1+ cursor uniforms.
       iCurrentCursor/iPreviousCursor: (x, y, w, h) in drawable px.
       iCurrentCursorColor/iPreviousCursorColor: straight RGBA in [0, 1].
       iTimeCursorChange: iTime value at the last cursor move/change. */
    float    iCurrentCursor[4];       /*  80..95  */
    float    iPreviousCursor[4];      /*  96..111 */
    float    iCurrentCursorColor[4];  /* 112..127 */
    float    iPreviousCursorColor[4]; /* 128..143 */
    float    iTimeCursorChange;       /* 144..147 */
    float    _pad_cursor[3];          /* 148..159 — UBO size must be 16-aligned */
} zonvie_shader_uniforms;

/* Result of a GLSL -> target shading language compile.
   Owns an internal allocation; pass to zonvie_shader_result_destroy. */
typedef struct zonvie_shader_result {
    const char *data;        /* Null-terminated compiled source; NULL on error. */
    size_t      data_len;    /* Length of data, excluding null terminator. */
    const char *error_msg;   /* Null-terminated error message; NULL on success. */
    void       *internal;    /* Opaque cleanup pointer. */
} zonvie_shader_result;

/* Compile a Shadertoy/Ghostty style GLSL fragment shader to the target
   shading language. Caller must release the result with
   zonvie_shader_result_destroy. */
ZONVIE_API zonvie_shader_result zonvie_shader_compile_glsl(
    const char *glsl_source,
    size_t      glsl_len,
    zonvie_shader_target target
);

/* Release all memory owned by a zonvie_shader_result. Safe to call on a
   zero-initialized or already-destroyed result. */
ZONVIE_API void zonvie_shader_result_destroy(zonvie_shader_result *result);

#ifdef __cplusplus
}
#endif
