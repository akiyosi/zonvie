// The Wayland backend's window (window.c), as main_wl.zig sees it.
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
    // The input method's composition, UTF-8: "" ends it. `begin` / `end`:
    // the cursor's byte range within it.
    void (*ime_preedit)(void* data, const char* text, int32_t begin, int32_t end);
    // Text the input method commits.
    void (*ime_commit)(void* data, const char* text);
    // The keymap changed: no key counts as held any more.
    void (*keys_reset)(void* data);
    // Files dropped on the window: a text/uri-list of `len` bytes.
    void (*drop)(void* data, const char* uri_list, size_t len);
} zwl_listener;

// Connects and binds the globals. 0, or -1 when no compositor answers.
int zwl_open(const zwl_listener* l, void* data);
int zwl_fd(void);
// The largest scale among the outputs, known once zwl_open returned.
int zwl_scale(void);
// The surface and its toplevel, committed without a buffer.
int zwl_window(const char* app_id, const char* title);
void zwl_set_title(const char* title);
// The compositor sizes the window: maximized, fullscreen or tiled.
int zwl_placed(void);
// Blur behind the window, where the compositor offers it.
void zwl_blur(void);
void zwl_set_buffer_scale(int32_t scale);
void zwl_request_frame(void);
int zwl_frame_pending(void);
void zwl_repeat_info(int32_t* rate, int32_t* delay);
// The pointer's shape over the window.
enum { ZWL_CURSOR_TEXT = 0, ZWL_CURSOR_HAND = 1 };
void zwl_cursor(int shape);
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

int zwl_dispatch(void);
int zwl_dispatch_pending(void);
int zwl_flush(void);
int zwl_roundtrip(void);

#endif
