// The Wayland backend's window (window.c), as main.zig sees it.
#ifndef ZONVIE_WL_WINDOW_H
#define ZONVIE_WL_WINDOW_H

#include <stdint.h>
#include <stddef.h>

typedef struct {
    // A configure was acked. Logical px; 0 leaves that dimension to the client.
    void (*configure)(void* data, int32_t w, int32_t h);
    void (*close)(void* data);
    void (*focus)(void* data, int focused);
    // `sym` / `base_sym`: the key's keysym, and the one it has with no
    // modifier held; `utf32` / `base_utf32` their characters or 0. `mods`:
    // keymap.zig's modifier masks.
    void (*key)(void* data, uint32_t key, uint32_t sym, uint32_t base_sym, uint32_t utf32, uint32_t base_utf32,
                uint32_t mods, int pressed, int repeats);
    // The frame callback asked for with zwl_request_frame fired.
    void (*frame)(void* data);
    // Surface-local logical px.
    void (*pointer_motion)(void* data, double x, double y);
    void (*pointer_leave)(void* data);
    // `button`: a Linux input code (BTN_LEFT is 0x110).
    void (*pointer_button)(void* data, uint32_t button, int pressed, uint32_t mods);
    // One frame's scroll: logical px along each axis, positive right / down,
    // and a wheel's notches (0 for a touchpad).
    void (*pointer_axis)(void* data, double dx, double dy, int32_t steps_x, int32_t steps_y, uint32_t mods);
    // A touchpad's fingers lifted while moving at (vx, vy) logical px/s.
    void (*pointer_axis_stop)(void* data, double vx, double vy);
    // The input method's composition, UTF-8: "" ends it. `begin` / `end`:
    // the cursor's byte range within it.
    void (*ime_preedit)(void* data, const char* text, int32_t begin, int32_t end);
    // Text the input method commits.
    void (*ime_commit)(void* data, const char* text);
    // The keymap changed: no key counts as held any more.
    void (*keys_reset)(void* data);
    // Files dropped on the window: a text/uri-list of `len` bytes.
    void (*drop)(void* data, const char* uri_list, size_t len);
    // An external window (zwl_ext_open) was configured, asked to close, or
    // had its frame shown. `id` is the one it was opened with.
    void (*ext_configure)(void* data, int64_t id, int32_t w, int32_t h);
    void (*ext_close)(void* data, int64_t id);
    void (*ext_frame)(void* data, int64_t id);
    // The pointer entered a window: the events after it are that window's.
    // 0 is the main window.
    void (*pointer_window)(void* data, int64_t id);
} zwl_listener;

// Connects and binds the globals. 0, or -1 when no compositor answers.
int zwl_open(const zwl_listener* l, void* data);
int zwl_fd(void);
// The largest scale among the outputs, known once zwl_open returned.
int zwl_scale(void);
// The surface and its toplevel, committed without a buffer. With
// `server_decorations` the compositor is asked to draw the title bar.
int zwl_window(const char* app_id, const char* title, int server_decorations);
void zwl_set_title(const char* title);
// The compositor sizes the window: maximized, fullscreen or tiled.
int zwl_placed(void);
// Blur behind the window, where the compositor offers it.
void zwl_blur(void);
void zwl_set_buffer_scale(int32_t scale);
void zwl_request_frame(void);
int zwl_frame_pending(void);
// Unmaps the window, and maps it again (a configure follows; no buffer may
// be attached between the two).
void zwl_hide(void);
void zwl_show(const char* app_id, const char* title);
void zwl_repeat_info(int32_t* rate, int32_t* delay);
// The pointer's shape over the window: a wp_cursor_shape_device_v1.shape
// (1 default, 4 pointer, 9 text, 18..25 the resize edges); 0 is text.
void zwl_cursor(int shape);
// The frontend's own title bar: a move or a resize the compositor takes over
// (`edge`: xdg_toplevel.resize_edge), from the button press last seen.
void zwl_move(void);
void zwl_resize(uint32_t edge);
void zwl_toggle_maximize(void);
void zwl_minimize(void);
int zwl_maximized(void);
// The compositor offers to draw the title bar (xdg-decoration).
int zwl_server_decorations(void);
// The modifiers held, as the masks keymap.zig takes.
uint32_t zwl_mods(void);

// The clipboard, or with `primary` the primary selection. Setting takes the
// serial of the last key or button press. zwl_selection_get returns malloc'ed
// text of *out_len bytes, or NULL when the selection holds none.
int zwl_selection_set(int primary, const char* text, size_t len);
char* zwl_selection_get(int primary, size_t* out_len);

// Where the text cursor is, surface-local logical px: the input method
// places its candidate window by it.
void zwl_ime_cursor(int32_t x, int32_t y, int32_t width, int32_t height);
// Drops the composition under way.
void zwl_ime_reset(void);

// A GL 3.3 core context current on the window's surface.
int zwl_egl_init(int32_t w_px, int32_t h_px);
void zwl_egl_resize(int32_t w_px, int32_t h_px);
int zwl_swap(void);
// The main surface's back buffer: how many frames old its contents are, 0
// when unknown (a new buffer, or no EGL_EXT_buffer_age).
int zwl_buffer_age(void);
// A swap that tells the compositor only `n` rects changed: x, y, w, h each,
// buffer px from the bottom-left. Falls back to a plain swap.
int zwl_swap_damage(const int32_t* rects, int32_t n);

int zwl_dispatch(void);
int zwl_dispatch_pending(void);
int zwl_flush(void);

// External windows: further toplevels of the same client, drawn with the main
// window's GL context. `id` is nonzero and the caller's own. The window is
// committed without a buffer; ext_configure says when to draw.
int zwl_ext_open(int64_t id, const char* app_id, const char* title, int32_t w_px, int32_t h_px, int32_t scale);
void zwl_ext_close(int64_t id);
// A popup of window `parent_id` (0: the main window) in the same table as
// the external windows, without a grab: its top-left (x, y) from the
// parent's, logical px, the anchor a point inside the parent. ext_configure
// follows with its size; ext_close when the compositor dismisses it.
int zwl_popup_open(int64_t id, int64_t parent_id, int32_t x, int32_t y, int32_t w_logical, int32_t h_logical,
                   int32_t anchor_x, int32_t anchor_y, int32_t scale);
void zwl_ext_resize(int64_t id, int32_t w_px, int32_t h_px);
// The compositor sizes window `id`: maximized, fullscreen or tiled.
int zwl_ext_placed(int64_t id);
// Makes the window's surface the one GL draws to; id 0 is the main window.
int zwl_ext_make_current(int64_t id);
int zwl_ext_swap(int64_t id);
void zwl_ext_request_frame(int64_t id);
int zwl_ext_frame_pending(int64_t id);

#endif
