#pragma once
/* Helpers both frontends call to share an implementation, not part of the
   contract between the core and a frontend (zonvie_core.h). They take no core
   handle and hold no state of the core's: geometry, layout, parsing and the
   small per-surface state machines that both frontends used to write out
   themselves. The Windows frontend calls the same code as Zig. */
#include "zonvie_core.h"

#ifdef __cplusplus
extern "C" {
#endif

/* ---------------------------------------------------------------------------
   Row-scroll blit arithmetic.

   Where a GPU row-scroll copy reads and writes, how far it may go inside the
   frontend's back texture, which band it vacates, and which rows the caller
   must redraw. Stateless: the answer depends only on the geometry passed in,
   so these take no core handle.

   The scrolled rectangle is a sub-rectangle of the back texture at
   (origin_x_px, origin_y_px), width_px wide: origin zero and the full drawable
   width for a whole surface, the layer's own origin and width for one layer.

   The row count a scroll callback reports can outlive the texture -- a window
   shrink, or a guifont/linespace change growing the cell height before
   try_resize round-trips -- so row_end is clamped to the rows that fit below
   the origin, and the copy, the vacated band and the dirty expansion all stop
   at that same clamped row. Getting that wrong leaves part of the band the
   blit cleared blank until the next full redraw. */
typedef struct zonvie_row_scroll_plan {
    /* The scrolled rectangle's left edge, which the encoder copies at. */
    int32_t origin_x_px;
    /* The top edge, already folded into every Y below. Subtract it to draw
       under a layer transform, whose pixel space starts at the origin. */
    int32_t origin_y_px;
    int32_t src_y_px;
    int32_t dst_y_px;
    int32_t copy_w_px;
    int32_t copy_h_px;
    /* The band the copy vacated, which the caller clears to the background. */
    int32_t clear_top_px;
    int32_t clear_bottom_px;
    /* row_end clamped to the texture: where the blit stopped. */
    uint32_t clamped_row_end;
    /* Rows the caller must redraw: the band vacated by an accumulated delta D,
       plus another D for rows an intermediate scroll step copied and a later
       one overwrote, which are stale in the back buffer. Half-open and
       grid-local -- rows are numbered within the scroll region, which
       origin_y_px moves the pixels of but does not renumber. */
    uint32_t dirty_row_start;
    uint32_t dirty_row_end;
} zonvie_row_scroll_plan;

/* Fills *out and returns true when a blit is worth encoding. False means the
   caller redraws the region from scratch instead: no shift, a shift that fills
   or exceeds the region, a degenerate geometry, or a rectangle with nothing
   left inside the texture. *out is untouched when false. */
ZONVIE_API bool zonvie_core_row_scroll_plan_make(
    uint32_t row_start,
    uint32_t row_end,
    int32_t rows_delta,
    int32_t origin_x_px,
    int32_t origin_y_px,
    int32_t width_px,
    int32_t texture_width_px,
    int32_t texture_height_px,
    int32_t row_height_px,
    zonvie_row_scroll_plan *out
);

/* The rows to redraw when the blit never ran: nothing was shifted, so every
   row of the scroll region is stale and the core will not re-send them (it
   vacates only the band, assuming the frontend shifts the rest). Half-open and
   grid-local like dirty_row_start/dirty_row_end, still stopping at the rows
   that fit below origin_y_px. False when nothing of the region is inside the
   texture; the out params are untouched then. */
ZONVIE_API bool zonvie_core_row_scroll_dirty_rows_without_blit(
    uint32_t row_start,
    uint32_t row_end,
    int32_t origin_y_px,
    int32_t texture_height_px,
    int32_t row_height_px,
    uint32_t *out_row_start,
    uint32_t *out_row_end
);

/* A vertical span of surface pixels, [top_px, bottom_px). */
typedef struct zonvie_damage_band {
    int32_t top_px;
    int32_t bottom_px;
} zonvie_damage_band;

/* The bands a partial frame redraws. `spans` are the surface pixels owed (a
   layer's changed rows, a moved layer's old and new extent, the rows a row
   scroll left stale), clamped to [0, surface_height_px). Spans are widened by
   one row each way and joined into bands written to `out`; the count is
   returned. A frame repaints each band whole: every layer that meets it, back
   to front, draws the rows zonvie_core_damage_band_layer_rows names, clipped
   to the band. That equals a full redraw for glyph ink crossing at most one
   row boundary. Bands span the whole surface width, so a lower layer's repaint
   needs no separate propagation to the layers over it. Bands closer than
   three rows are joined, so no layer row reaches two of them. When
   `out_capacity` is too small the last band absorbs the rest. */
ZONVIE_API size_t zonvie_core_damage_bands(
    const zonvie_damage_band *spans,
    size_t span_count,
    int32_t row_height_px,
    int32_t surface_height_px,
    zonvie_damage_band *out,
    size_t out_capacity
);

/* The rows of a layer one band repaints, inclusive: those meeting the band
   widened by one row each way. False when none; the out params are untouched
   then. */
ZONVIE_API bool zonvie_core_damage_band_layer_rows(
    zonvie_damage_band band,
    int32_t origin_y_px,
    uint32_t layer_rows,
    int32_t row_height_px,
    uint32_t *out_first_row,
    uint32_t *out_last_row
);

/* The band of `bands` a layer's `row` is drawn in, the one
   zonvie_core_damage_band_layer_rows names it for. False when none. */
ZONVIE_API bool zonvie_core_damage_band_for_layer_row(
    const zonvie_damage_band *bands,
    size_t band_count,
    int32_t origin_y_px,
    uint32_t row,
    int32_t row_height_px,
    zonvie_damage_band *out_band
);

/* Inclusive row ranges naming the damage an accepted per-layer row-scroll blit
   does to a layer drawn on top of it. Each range is valid only when its
   has_* flag is non-zero.

   The blit rewrites every pixel of its rectangle R. For a layer M above it:
   M's own pixels inside R moved, so every row of M meeting R is redrawn
   (above_*); and what they covered moved with them, so the rows of the
   scrolled layer they were dragged into (under_*) plus the rows those pixels
   came from (shifted_*, the same rows shifted back by rows_delta) are redrawn
   from the scrolled layer's vertices. Both ranges come from a pixel
   intersection, so a layer off the cell grid gets both rows a boundary
   straddles. Only layers ABOVE need this: R lies inside the scrolled layer's
   own rectangle, and a marked layer repaints after it, which is screen order. */
typedef struct zonvie_over_blit_rows {
    uint32_t above_first;
    uint32_t above_last;
    uint32_t under_first;
    uint32_t under_last;
    uint32_t shifted_first;
    uint32_t shifted_last;
    uint32_t has_above;
    uint32_t has_under;
    uint32_t has_shifted;
} zonvie_over_blit_rows;

/* Fills *out and returns true when the covering layer's rectangle meets the
   blit's. False means it does not and there is nothing to mark; *out is
   untouched then. `plan` is a plan zonvie_core_row_scroll_plan_make filled,
   and the covering layer's origin is in the same pixel space as its
   origin_x_px/origin_y_px. */
ZONVIE_API bool zonvie_core_row_scroll_over_blit_rows(
    const zonvie_row_scroll_plan *plan,
    int32_t rows_delta,
    int32_t above_left_px,
    int32_t above_top_px,
    uint32_t above_rows,
    uint32_t above_cols,
    int32_t cell_width_px,
    int32_t row_height_px,
    zonvie_over_blit_rows *out
);

/* A row scroll staged for one grid, waiting for the flush that will spend it.
   col_start/col_end are the columns the shift covers: the macOS main surface
   stages a shift only when it spans the full width and redraws otherwise, and
   a caller that does not track columns passes the whole grid. */
typedef struct zonvie_row_scroll {
    int32_t row_start;
    int32_t row_end;
    int32_t col_start;
    int32_t col_end;
    int32_t rows_delta;
    int32_t total_rows;
    int32_t total_cols;
} zonvie_row_scroll;

typedef struct zonvie_row_scroll_merge {
    /* What the caller stages in place of whatever it held. */
    zonvie_row_scroll staged;
    /* A region the staged one displaced, whose rows the caller must mark dirty
       because nothing will move their pixels now. Meaningful only when
       has_superseded is non-zero: that is false when the incoming shift
       continued the staged one, and when the displaced region was empty. */
    zonvie_row_scroll superseded;
    uint32_t has_superseded;
    uint32_t reserved;
} zonvie_row_scroll_merge;

/* Fold a new row scroll into whatever is already staged for the same grid.
   Two shifts of the SAME region in one flush are one shift and their deltas
   add; two shifts of DIFFERENT regions are not, and the displaced one's rows
   come back in `superseded` for the caller to repaint.

   `existing` is null when nothing is staged. Returns false, leaving *out
   untouched, only when `incoming` or `out` is null. */
ZONVIE_API bool zonvie_core_row_scroll_merge(
    const zonvie_row_scroll *existing,
    const zonvie_row_scroll *incoming,
    zonvie_row_scroll_merge *out
);

/* The cursor's rectangle on a surface, in surface pixels with y down; right
   and bottom are exclusive. Both frontends computed this from the cursor's
   grid-local vertices themselves, and the Windows main driver twice (an
   integer rectangle for present damage, a float one for the shader uniform);
   one bounds now. */
typedef struct zonvie_cursor_rect {
    float left;
    float top;
    float right;
    float bottom;
} zonvie_cursor_rect;

/* Fills *out with the vertex box moved by (origin_x_px, origin_y_px) -- the
   origin that places the cursor's grid on the surface, a layer origin plus
   any viewport offset. False, leaving *out untouched, when count is 0. */
ZONVIE_API bool zonvie_core_cursor_rect(
    const zonvie_vertex *verts,
    size_t count,
    float origin_x_px,
    float origin_y_px,
    zonvie_cursor_rect *out
);

/* Where a pointer lands, filled by zonvie_core_resolve_pointer_grid. `row`
   and `col` are in the named grid's own cells. */
typedef struct zonvie_pointer_hit {
    int64_t grid_id;
    int32_t row;
    int32_t col;
} zonvie_pointer_hit;

/* Which grid a pointer at (row, col) of `surface_id` names, out of the grids
   the caller already has. `surface_id` is 1 for the main window and the grid
   id of an external window for its own surface.

   The rule this applies was written out in each frontend and the two drifted:
   one hit-tested floats another surface hosts, the other ignored the mouse
   flag and the scrollability rule. It skips an external grid, a grid some
   other surface composites, and a grid that refuses the mouse; it takes the
   front-most of what is left by (layer_z, grid_id): the order its surface
   last published.

   `require_scrollable` is the wheel's extra rule: a float showing all of its
   content does not capture scroll, and is skipped so a scrollable grid beneath
   it still takes the event. Pass 0 for a click.

   Pure — no core pointer, no lock — so it is safe on the input path with the
   non-blocking cached grid snapshot. Returns 1 and fills `out` on a hit, 0
   when nothing matches; on 0 the caller keeps its own surface's grid and the
   position it was given. */
ZONVIE_API int zonvie_core_resolve_pointer_grid(
    const zonvie_grid_info *grids,
    size_t count,
    int64_t surface_id,
    int32_t row,
    int32_t col,
    int require_scrollable,
    zonvie_pointer_hit *out);

/* Whether a float can scroll its own content: it holds more buffer lines than
   its content area shows, margins excluded. A float that already shows every
   line is transparent to a wheel event, which reaches what is drawn under it.

   zonvie_core_resolve_pointer_grid applies this itself when `require_scrollable`
   is set. This is for a frontend that resolves a pointer against its own DRAWN
   geometry instead of the cell positions that rule reads, and so needs the
   predicate on its own.

   Pure — no core pointer, no lock. */
ZONVIE_API int zonvie_core_captures_scroll(
    int32_t rows,
    int32_t margin_top,
    int32_t margin_bottom,
    int64_t line_count);

/* How a viewport's scrollbar should look, filled by
   zonvie_core_scrollbar_metrics. Fractions, not pixels: the track rectangle
   and a minimum knob height are chrome and stay with the frontend. */
typedef struct zonvie_scrollbar_metrics {
    /* 1 when the buffer holds more lines than the viewport shows. */
    uint8_t is_scrollable;
    /* Where the knob sits along its travel: 0 at the top, 1 at the bottom.
       Defined even when nothing scrolls, where it is 0. */
    double scroll_position;
    /* How much of the track the knob covers, 0..1. */
    double knob_proportion;
} zonvie_scrollbar_metrics;

/* Whether a viewport needs a scrollbar and where its knob sits.

   `botline` is exclusive, and Neovim reports it past `line_count` for a window
   showing the region beyond the last line.

   Both frontends had this arithmetic written out and their answers differed at
   three corners: a zero-row viewport (one called it scrollable), a window
   showing its whole buffer (one reported `topline` as the position rather than
   0), and a window scrolled past EOF (neither clamped, and one drew its knob
   below the bottom of its own track).

   Pure — no core pointer, no lock. */
ZONVIE_API void zonvie_core_scrollbar_metrics(
    int64_t topline,
    int64_t botline,
    int64_t line_count,
    zonvie_scrollbar_metrics *out);

/* Where a knob dragged to `ratio` of its travel (0 top, 1 bottom) asks the
   window to scroll, filled by zonvie_core_scrollbar_drag_target. */
typedef struct zonvie_scrollbar_drag_target {
    /* 1-based buffer line to bring to the edge `use_bottom` names. */
    int64_t line;
    /* 1 to align `line` with the window's bottom (zb), 0 with its top (zt).
       The lower half of the travel aligns to the bottom, the only way the
       last line of the buffer can be reached. */
    uint8_t use_bottom;
} zonvie_scrollbar_drag_target;

/* The line a knob at `ratio` of its travel names, for a viewport reported as
   (topline, botline exclusive, line_count). `ratio` is clamped to 0..1.
   Pass the result to zonvie_core_scroll_to_line.

   Pure — no core pointer, no lock. */
ZONVIE_API void zonvie_core_scrollbar_drag_target(
    double ratio,
    int64_t topline,
    int64_t botline,
    int64_t line_count,
    zonvie_scrollbar_drag_target *out);

/* One OS window for the window-layout plan: top-left origin, Y growing down,
   in whatever unit the frontend uses (only comparisons and top-left positions
   matter, so a Y-up frontend passes y = -maxY). `id` is the frontend's own. */
typedef struct zonvie_win_frame {
    int64_t id;
    double x;
    double y;
    double w;
    double h;
} zonvie_win_frame;

enum {
    ZONVIE_WIN_LAYOUT_MOVE = 0,         /* arg: direction 0=down 1=up 2=right 3=left */
    ZONVIE_WIN_LAYOUT_EXCHANGE = 1,     /* count: steps in reading order, 0 = 1 */
    ZONVIE_WIN_LAYOUT_ROTATE = 2,       /* arg: 0 = forward; count < 0 refused, reduced mod n */
    ZONVIE_WIN_LAYOUT_RESIZE_EQUAL = 3, /* average sizes, top-left corners kept */
};

/* Plan a window-layout operation (win_move / win_exchange / win_rotate /
   win_resize_equal) over `frames` IN PLACE: each frame keeps its id and gets
   the position and size it should take. Returns true when the frontend should
   apply them. `row_band` is how far apart two centres may be and still read as
   one row in reading order (macOS uses 20pt; Windows the same scaled).
   At most 64 frames; more is refused.

   Pure — no core pointer, no lock — so it may be called from the callback that
   delivered the event, grid_mu held or not. */
ZONVIE_API bool zonvie_core_win_layout_plan(
    int32_t op,
    int32_t arg,
    int32_t count,
    int64_t source_id,
    double row_band,
    zonvie_win_frame *frames,
    size_t frame_count);

/* The index into `frames` of the window win_move_cursor lands on from
   `source_id`: the count-th nearest in `direction` (count 0 = 1; past the last
   candidate, the nearest), else the nearest overall. -1 when none. Pure. */
ZONVIE_API int64_t zonvie_core_win_layout_find(
    int64_t source_id,
    int32_t direction,
    int32_t count,
    const zonvie_win_frame *frames,
    size_t frame_count);

/* The top edge of an external popupmenu window, Y growing downward: below
   the anchor cell (anchor_top + anchor_height) when the popup ends at or
   above ref_bottom — the bottom of the window the anchor is in — else above
   the anchor (anchor_top - popup_height) when that starts at or below
   screen_top, else below. Neovim's own popupmenu flips on the editor's room,
   not the screen's.

   Pure — no core pointer, no lock. */
ZONVIE_API int32_t zonvie_core_popupmenu_top(
    int32_t anchor_top,
    int32_t anchor_height,
    int32_t popup_height,
    int32_t ref_bottom,
    int32_t screen_top);

/* Parse a comma-separated OpenType feature list ("+liga,-calt,ss01=2,zero")
   into out_features, whose entries have the layout of zonvie_font_feature
   (zonvie_hbft.h: char tag[4]; int32_t value). Writes at most cap entries and
   returns how many. Tokens that are not a feature are skipped.

   Pure — no core pointer, no lock. */
ZONVIE_API size_t zonvie_core_parse_font_features(
    const char *list, size_t len, void *out_features, size_t cap);

/* Read one "<name>\t<size>[\t<features>]" line of a font candidate list (the
   on_guifont payload, or the config font_family list): the name is
   line[0..*out_name_len], the feature list line[*out_features_offset..] of
   *out_features_len bytes. The size is the line's unless size_explicit
   ([font] size wins over guifont) or the line carries none, then default_pt.
   Returns false for a line with no name or no size field.

   Pure — no core pointer, no lock. */
ZONVIE_API bool zonvie_core_parse_font_candidate(
    const char *line, size_t len, float default_pt, bool size_explicit,
    size_t *out_name_len, float *out_point_size,
    size_t *out_features_offset, size_t *out_features_len);

/* A saved window origin kept inside an area (the work area of the monitor
   holding it): each axis clamped to [area_min, area_max - size]. The axes
   carry no direction, so Y may grow up or down.

   Pure — no core pointer, no lock. */
ZONVIE_API void zonvie_core_clamp_window_origin(
    int32_t x, int32_t y, int32_t w, int32_t h,
    int32_t area_min_x, int32_t area_min_y,
    int32_t area_max_x, int32_t area_max_y,
    int32_t *out_x, int32_t *out_y);

/* The left edge of an external popupmenu window: anchor_left - text_inset
   (so the popup's text lines up with the anchor column), shifted left to end
   at screen_right when it would run past it -- as Neovim's own popupmenu
   does -- and never left of screen_left. Any unit, X growing rightward.

   Pure — no core pointer, no lock. */
ZONVIE_API int32_t zonvie_core_popupmenu_left(
    int32_t anchor_left,
    int32_t popup_width,
    int32_t text_inset,
    int32_t screen_left,
    int32_t screen_right);

/* How one msg_show changes a frontend's stack of `stack_len` messages shown
   together: returns ZONVIE_MSG_STACK_PUSH (add at the end),
   ZONVIE_MSG_STACK_REPLACE_LAST (put it in place of the last entry; the other
   visible messages stay, per the UI spec's replace_last) or
   ZONVIE_MSG_STACK_APPEND_TO_LAST (append its text to the last entry), and
   writes how many oldest entries to drop afterwards (the stack holds 5).

   Pure — no core pointer, no lock. */
enum {
    ZONVIE_MSG_STACK_PUSH = 0,
    ZONVIE_MSG_STACK_REPLACE_LAST = 1,
    ZONVIE_MSG_STACK_APPEND_TO_LAST = 2,
};
ZONVIE_API int zonvie_core_msg_stack_plan(
    size_t stack_len,
    int replace_last,
    int append,
    size_t *out_evict_oldest);

/* The top edge of the cmdline completion popup, Y growing downward: `gap`
   above the cmdline window (cmdline_top - gap - popup_height) when that starts
   at or below screen_top, else `gap` below it (cmdline_bottom + gap).

   Pure — no core pointer, no lock. */
ZONVIE_API int32_t zonvie_core_cmdline_popupmenu_top(
    int32_t cmdline_top,
    int32_t cmdline_bottom,
    int32_t popup_height,
    int32_t gap,
    int32_t screen_top);

/* Where an open cmdline window goes when its size changes, Y growing
   downward: it keeps the centre of `old_*`, is centred in the area once it is
   90% of the area's width, and stays inside the area.

   Pure — no core pointer, no lock. */
ZONVIE_API void zonvie_core_cmdline_origin(
    int32_t old_left, int32_t old_top, int32_t old_right, int32_t old_bottom,
    int32_t new_w, int32_t new_h,
    int32_t area_left, int32_t area_top, int32_t area_right, int32_t area_bottom,
    int32_t *out_x, int32_t *out_y);

/* The cmdline's width budget in cells, for zonvie_core_set_screen_cols and
   zonvie_core_set_cmdline_default_cols (or try_update_layout_px): the work
   area less `chrome_px` (beside the grid in the cmdline window) and
   `margin_px`, at least 40; and 95% of the main window less the chrome, at
   least 20. Widths are in the caller's pixels; a zero width gives 0.

   Pure — no core pointer, no lock. */
ZONVIE_API void zonvie_core_cmdline_cols(
    uint32_t work_w_px, uint32_t main_w_px, uint32_t chrome_px,
    uint32_t margin_px, uint32_t cell_w_px,
    uint32_t *out_screen_cols, uint32_t *out_default_cols);

/* The top-left corner of msg_show / msg_history, Y growing downward: `margin`
   in from the target rect's top-right corner, or, for msg_show while
   msg_history is up (has_history), `gap` below history_bottom. Margins are in
   the caller's (scaled) pixels.

   Pure — no core pointer, no lock. */
ZONVIE_API void zonvie_core_msg_float_origin(
    int32_t target_left, int32_t target_top, int32_t target_right, int32_t target_bottom,
    int32_t window_w, bool has_history, int32_t history_bottom,
    int32_t margin, int32_t gap,
    int32_t *out_x, int32_t *out_y);

/* Whether a key code from send_key_event's encoding (a macOS virtual key
   code, or 0x10000 | Windows VK) is a special key the core names (<Left>,
   <CR>, <F1>, ...): such keys go straight to send_key_event rather than
   through the platform's text input.

   Pure — no core pointer, no lock. */
ZONVIE_API bool zonvie_core_key_is_special(uint32_t keycode);

/* The modifier string of a mouse event ("S", "C", "A", "D", in that order)
   for a ZONVIE_MOD_* bitmask, NUL-terminated into out (5 bytes). Returns its
   length.

   Pure — no core pointer, no lock. */
ZONVIE_API size_t zonvie_core_mouse_modifiers(uint32_t mods, char out[5]);

/* Split a `--ssh user@host[:port]` value: the host is value[0..*out_host_len]
   and *out_port the port after the last colon, or -1 when what follows it is
   not a port number (the colon then stays in the host).

   Pure — no core pointer, no lock. */
ZONVIE_API void zonvie_core_parse_ssh_target(
    const char *value, size_t len, size_t *out_host_len, int32_t *out_port);

/* Whether a bare flag (`--ssh host`) takes the token after it as its value:
   true for a token that is not itself a flag; false for a flag or for NULL
   (no next token).

   Pure — no core pointer, no lock. */
ZONVIE_API bool zonvie_core_cli_next_is_value(const char *next, size_t len);

/* A surface's pointer claim: which buttons have had a press sent, and which
   one's press chose the grid every release and drag goes to. Buttons are 1
   left, 2 right, 3 middle, 4 x1, 5 x2. A left press takes the claim, another
   button's unless left holds it; every sent press gets its release, to the
   claim's grid, in any release order; the claim ends with the last held
   button. `owner` is the button drags are reported as, 0 when none. Zero it
   to start (or when the platform cancels the capture).

   Pure — no core pointer, no lock. */
typedef struct zonvie_press_claim {
    uint8_t held_mask;
    uint8_t owner;
} zonvie_press_claim;

/* Records a sent press; true when it takes the claim (pin its grid). */
ZONVIE_API bool zonvie_core_press_claim_press(zonvie_press_claim *claim, uint8_t button);

#define ZONVIE_PRESS_RELEASE_SEND 1u
#define ZONVIE_PRESS_RELEASE_ENDS 2u
/* A release: SEND when its press was sent (send it to the claim's grid),
   ENDS when no button is held after it. */
ZONVIE_API uint8_t zonvie_core_press_claim_release(zonvie_press_claim *claim, uint8_t button);

/* Mini window content as shown: a trailing newline dropped, and past ten
   lines the first nine plus a "…(N more lines)" line. Written to `out`
   (UTF-8, not NUL-terminated), cut at a UTF-8 boundary with '…' when it does
   not fit `cap`; returns the bytes written. `len + 48` always fits.

   Pure — no core pointer, no lock. */
ZONVIE_API size_t zonvie_core_clamp_mini_content(const char *content, size_t len, char *out, size_t cap);

/* A message or cmdline panel's background from Normal's (sRGB, 0..1): HSB
   brightness moved 0.05 toward the middle, hue and saturation kept. `out`
   receives r, g, b.

   Pure — no core pointer, no lock. */
ZONVIE_API void zonvie_core_panel_bg(float r, float g, float b, float out[3]);

/* The colour family a message panel draws a msg_show `kind` in; the RGB of
   each is the frontend's, NORMAL meaning Normal's foreground. Errors (emsg,
   echoerr, lua_error, rpc_error), wmsg, prompts (confirm, confirm_sub,
   number_prompt, return_prompt) and search_count.

   Pure — no core pointer, no lock. */
#define ZONVIE_MSG_TONE_NORMAL 0u
#define ZONVIE_MSG_TONE_ERROR 1u
#define ZONVIE_MSG_TONE_WARN 2u
#define ZONVIE_MSG_TONE_PROMPT 3u
#define ZONVIE_MSG_TONE_SEARCH 4u
ZONVIE_API uint8_t zonvie_core_msg_kind_tone(const char *kind, size_t len);

/* Whether msg_show `kind` blocks Neovim until the user answers (confirm,
   confirm_sub, number_prompt): the kinds the core pins to the confirm view.
   Unlike the PROMPT tone, excludes return_prompt, which the core answers.
   Pure — no core pointer, no lock. */
ZONVIE_API bool zonvie_core_msg_kind_is_interactive(const char *kind, size_t len);

/* Whether `arg` is a file argument to nvim: not a flag (`-`), not a command
   (`+`), not the value of the option `prev` names (`-u NONE`, `--cmd x`);
   `prev` may be NULL. After `--` every token but `-` (stdin) is a file.

   Pure — no core pointer, no lock. */
ZONVIE_API bool zonvie_core_nvim_arg_is_file(const char *prev, size_t prev_len,
                                             const char *arg, size_t arg_len,
                                             bool after_dash_dash);

/* The cells UTF-8 `text` takes on the grid: 2 per wide (CJK, Hangul,
   fullwidth) character and per emoji cluster, 2 per control character (^X,
   a TAB included), 1 otherwise. The rule the core lays out the cmdline with;
   its message panels run a TAB to the next multiple of 8 and its popupmenu
   draws it as two spaces.

   Pure — no core pointer, no lock. */
ZONVIE_API uint32_t zonvie_core_display_width(const char *text, size_t len);

/* How one argument goes into the command string zonvie_core_start takes, so
   its tokenizer hands it back unchanged: 0 bare, else the quote character
   (' or ") to wrap it in; -1 when it needs quoting (a space or a leading
   quote) and neither quote can carry it (empty, both quote kinds, or a
   trailing backslash that would escape the closing quote).

   Pure — no core pointer, no lock. */
ZONVIE_API int32_t zonvie_core_spawn_arg_quote(const char *arg, size_t len);

/* The window's terminal-area size in `desired_px`, in pixels along one axis,
   shrunk to the largest multiple of `cell_px` that still fits (at least one
   cell when desired_px > 0). Apply it to a size that only a user or system
   resize updates, never to the frontend's own snap result: snapping a snap
   is not idempotent across two different cell sizes, and would lose a strip
   on every reapply.

   Pure — no core pointer, no lock. */
ZONVIE_API uint32_t zonvie_core_snap_terminal_px(uint32_t desired_px, uint32_t cell_px);

/* The CONFIG section of `--help` (every key this platform reads, with its
   defaults; lines indented four spaces) and the commented-out config.toml
   `--install` writes (each value this platform's default). Static,
   NUL-terminated.

   Pure — no core pointer, no lock. */
ZONVIE_API const char *zonvie_core_config_help(void);
ZONVIE_API const char *zonvie_core_default_config_toml(void);

/* The `devcontainer exec --workspace-folder "<workspace>" [--config
   "<config>"] --remote-env XDG_CONFIG_HOME=/nvim-config nvim --embed` command
   line, NUL-terminated into out (cap bytes); returns its length. Each path
   loses one pair of surrounding quotes and any trailing backslashes (a drive
   root becomes `C:\.`), so it survives its own quotes. config_path may be
   NULL. A command that does not fit is cut short and fails at the spawn.

   Pure — no core pointer, no lock. */
ZONVIE_API size_t zonvie_core_devcontainer_exec_cmd(
    char *out, size_t cap,
    const char *workspace, size_t workspace_len,
    const char *config_path, size_t config_len);

/* The `devcontainer up` arguments that follow `--workspace-folder` and
   `--config`: `--additional-features <neovim feature json>`, `--mount
   type=bind,source=<nvim_config_dir>,target=/nvim-config/nvim` and, with
   rebuild, `--remove-existing-container`. Each argument is written to out
   NUL-terminated, in order, for the caller's own shell quoting; returns the
   total length. A list that does not fit in cap is cut short.

   Pure — no core pointer, no lock. */
ZONVIE_API size_t zonvie_core_devcontainer_up_args(
    char *out, size_t cap,
    const char *nvim_config_dir, size_t dir_len, bool rebuild);

/* Whether a file drop inserts the path into the command line rather than
   opening the file: always on the external cmdline window itself (force);
   never on a buffer surface while the cmdline has its own window
   (has_external_cmdline); otherwise while mode (zonvie_core_get_current_mode)
   starts with "cmdline".

   Pure — no core pointer, no lock. */
ZONVIE_API bool zonvie_core_drop_inserts_path(const char *mode, size_t len, bool has_external_cmdline, bool force);

/* path (len bytes) escaped as Neovim's fnameescape() escapes a `:e`
   argument: space, tab, newline and `*?[{`$\%#'"|!<` backslashed, plus a
   leading `>`, `+` or lone `-`. With backslash_is_separator (a Windows
   server) `$`, `\`, `[`, `{` and `!` are plain path bytes. Written to out,
   NOT NUL-terminated; returns the length, or 0 when cap is too small (cap >=
   2 * len + 1 always fits) or the path is empty.

   Pure — no core pointer, no lock. */
ZONVIE_API size_t zonvie_core_escape_path_for_cmdline(
    const char *path, size_t len, bool backslash_is_separator,
    char *out, size_t cap);

/* Whether a custom shader's source reads a uniform that changes every frame
   (iTime, iTimeDelta, iFrame, iFrameRate, iDate), so its surface keeps
   drawing while nothing else changes.

   Pure — no core pointer, no lock. */
ZONVIE_API bool zonvie_core_shader_needs_animation(const char *source, size_t len);

/* The insertion index a tab drag at `pos` drops on: the first of `count`
   equal tabs (tab i starts at origin + i*stride and is `size` long) whose
   centre is past `pos`, else `count`. One axis: x on a tab bar, y down a
   sidebar.

   Pure — no core pointer, no lock. */
ZONVIE_API uint32_t zonvie_core_tab_drop_index(double pos, uint32_t count, double origin, double stride, double size);

/* Where the next external window goes, in the frontend's screen units. A tab
   drag's drop point (set_pending) is good for 500 ms and beats the origin the
   grid's window had when it closed (save), which is kept only while the
   session generation that created the window is current: grid ids restart
   per server. take consumes a pending point, keeps a saved origin for the
   next reopen, and drops one from another session; it returns
   ZONVIE_PLACEMENT_NONE, _PENDING or _SAVED and writes the point. 100 saved
   origins are held; a new one past that evicts the smallest grid id.
   Zero-initialise the struct and never read its fields.

   Pure — no core pointer, no lock. */
typedef struct {
    int64_t grid_id;
    double x;
    double y;
    uint64_t generation;
} zonvie_saved_origin;
typedef struct {
    zonvie_saved_origin saved[101];
    size_t saved_len;
    double pending_x;
    double pending_y;
    int64_t pending_set_ms;
    bool has_pending;
} zonvie_placement_memory;
enum {
    ZONVIE_PLACEMENT_NONE = 0,
    ZONVIE_PLACEMENT_PENDING = 1,
    ZONVIE_PLACEMENT_SAVED = 2,
};
ZONVIE_API void zonvie_placement_set_pending(zonvie_placement_memory *m, double x, double y, int64_t now_ms);
ZONVIE_API void zonvie_placement_save(
    zonvie_placement_memory *m, int64_t grid_id, double x, double y,
    uint64_t generation, uint64_t current_generation);
ZONVIE_API int zonvie_placement_take(
    zonvie_placement_memory *m, int64_t grid_id, uint64_t generation, int64_t now_ms,
    double *out_x, double *out_y);

/* A surface's cursor blink cadence from guicursor's blinkwait/blinkon/blinkoff.
   Blinks when blinkon and blinkoff are both non-zero; a zero blinkwait (what
   Neovim sends for an entry guicursor leaves out) starts the cycle at once.
   Each call returns the delay in ms to the next zonvie_blink_tick, or 0 for no
   timer. `visible` is whether the cursor is drawn. Initialise every field
   to zero except visible = true (the cursor starts drawn).

   Pure — no core pointer, no lock. */
typedef struct {
    uint32_t wait_ms;
    uint32_t on_ms;
    uint32_t off_ms;
    uint8_t phase;
    bool visible;
} zonvie_blink;
ZONVIE_API uint32_t zonvie_blink_start(zonvie_blink *blink, uint32_t wait_ms, uint32_t on_ms, uint32_t off_ms);
ZONVIE_API uint32_t zonvie_blink_tick(zonvie_blink *blink);
ZONVIE_API void zonvie_blink_stop(zonvie_blink *blink);

/* ---------------------------------------------------------------------------
   Bloom chain geometry.

   How large each of the bloom's scratch textures is, and which one every pass
   reads and writes. The chain runs at half the surface's resolution and halves
   again at each level, down and then back up to the extract texture the
   composite samples. Stateless: it depends only on the surface size and the
   radius scale, so it takes no core handle.

   How deep it goes is the radius's call: a tight radius stops one level short,
   because reaching a sixteenth of the surface makes the light redistribute on
   every pixel of content motion. Run exactly `level_count` of `down` and then
   `level_count` of `up`; the entries past that are padding. The extents never
   move with the radius, so the textures need no resize when it changes.

   `src` and `dst` name a texture: ZONVIE_GLOW_TARGET_EXTRACT for the
   half-resolution extract texture, otherwise a mip index in
   [0, ZONVIE_GLOW_MIP_COUNT). Every extent is floored at one pixel, because a
   surface narrow enough for a level to round to zero still has to produce a
   texture the passes can bind. */
#define ZONVIE_GLOW_MIP_COUNT 3
#define ZONVIE_GLOW_TARGET_EXTRACT (-1)

typedef struct zonvie_glow_pass {
    int32_t src;
    int32_t dst;
    uint32_t dst_w_px;
    uint32_t dst_h_px;
} zonvie_glow_pass;

typedef struct zonvie_glow_chain {
    uint32_t half_w_px;
    uint32_t half_h_px;
    uint32_t mip_w_px[ZONVIE_GLOW_MIP_COUNT];
    uint32_t mip_h_px[ZONVIE_GLOW_MIP_COUNT];
    zonvie_glow_pass down[ZONVIE_GLOW_MIP_COUNT];
    zonvie_glow_pass up[ZONVIE_GLOW_MIP_COUNT];
    /* How many of down/up to run, in [1, ZONVIE_GLOW_MIP_COUNT]. */
    uint32_t level_count;
} zonvie_glow_chain;

/* Fills *out. Does nothing when out is null.
   radius_scale is zonvie_core_get_glow_radius_scale()'s value. */
ZONVIE_API void zonvie_core_glow_chain_plan(
    uint32_t surface_w_px,
    uint32_t surface_h_px,
    float radius_scale,
    zonvie_glow_chain *out
);

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
