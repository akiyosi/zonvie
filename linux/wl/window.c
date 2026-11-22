// The Wayland backend's window: one xdg_toplevel with an EGL surface, its
// keyboard through xkbcommon, and the protocol's event pump. main.zig
// drives it; nothing here knows the core.
//
// The build has no wayland-scanner step, so xdg-shell's three interfaces are
// written out as the scanner would emit them from xdg-shell.xml, at version
// 2, which adds only the tiled states to version 1: a later version adds
// events this backend has no use for yet.

#define _GNU_SOURCE
#include <stdint.h>
#include <stddef.h>
#include <string.h>
#include <stdlib.h>
#include <unistd.h>
#include <sys/mman.h>
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <time.h>
#include <wayland-client.h>
#include <wayland-egl.h>
#include <wayland-cursor.h>
#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <xkbcommon/xkbcommon.h>

#include "window.h"

// ---------------------------------------------------------------------------
// xdg-shell, version 1
// ---------------------------------------------------------------------------

static const struct wl_interface xdg_surface_interface;
static const struct wl_interface decoration_manager_interface;
static const struct wl_interface xdg_toplevel_interface;
static const struct wl_interface xdg_popup_interface;
static const struct wl_interface xdg_positioner_interface;

static const struct wl_interface* xdg_types[] = {
    NULL, NULL, NULL, NULL,
    // xdg_wm_base.get_xdg_surface
    &xdg_surface_interface, &wl_surface_interface,
    // xdg_surface.get_toplevel
    &xdg_toplevel_interface,
    // xdg_surface.get_popup
    &xdg_popup_interface, &xdg_surface_interface, &xdg_positioner_interface,
    // xdg_toplevel.set_parent
    &xdg_toplevel_interface,
    // xdg_toplevel.show_window_menu
    &wl_seat_interface, NULL, NULL, NULL,
    // xdg_toplevel.move
    &wl_seat_interface, NULL,
    // xdg_toplevel.resize
    &wl_seat_interface, NULL, NULL,
    // xdg_toplevel.set_fullscreen
    &wl_output_interface,
    // xdg_wm_base.create_positioner (21)
    &xdg_positioner_interface,
    // xdg_popup.grab (22)
    &wl_seat_interface, NULL,
};

static const struct wl_message xdg_wm_base_requests[] = {
    { "destroy", "", xdg_types + 0 },
    { "create_positioner", "n", xdg_types + 21 },
    { "get_xdg_surface", "no", xdg_types + 4 },
    { "pong", "u", xdg_types + 0 },
};
static const struct wl_message xdg_wm_base_events[] = {
    { "ping", "u", xdg_types + 0 },
};
static const struct wl_interface xdg_wm_base_interface = {
    "xdg_wm_base", 2, 4, xdg_wm_base_requests, 1, xdg_wm_base_events,
};

static const struct wl_message xdg_surface_requests[] = {
    { "destroy", "", xdg_types + 0 },
    { "get_toplevel", "n", xdg_types + 6 },
    { "get_popup", "n?oo", xdg_types + 7 },
    { "set_window_geometry", "iiii", xdg_types + 0 },
    { "ack_configure", "u", xdg_types + 0 },
};
static const struct wl_message xdg_surface_events[] = {
    { "configure", "u", xdg_types + 0 },
};
static const struct wl_interface xdg_surface_interface = {
    "xdg_surface", 2, 5, xdg_surface_requests, 1, xdg_surface_events,
};

static const struct wl_message xdg_toplevel_requests[] = {
    { "destroy", "", xdg_types + 0 },
    { "set_parent", "?o", xdg_types + 10 },
    { "set_title", "s", xdg_types + 0 },
    { "set_app_id", "s", xdg_types + 0 },
    { "show_window_menu", "ouii", xdg_types + 11 },
    { "move", "ou", xdg_types + 15 },
    { "resize", "ouu", xdg_types + 17 },
    { "set_max_size", "ii", xdg_types + 0 },
    { "set_min_size", "ii", xdg_types + 0 },
    { "set_maximized", "", xdg_types + 0 },
    { "unset_maximized", "", xdg_types + 0 },
    { "set_fullscreen", "?o", xdg_types + 20 },
    { "unset_fullscreen", "", xdg_types + 0 },
    { "set_minimized", "", xdg_types + 0 },
};
static const struct wl_message xdg_toplevel_events[] = {
    { "configure", "iia", xdg_types + 0 },
    { "close", "", xdg_types + 0 },
};
static const struct wl_interface xdg_toplevel_interface = {
    "xdg_toplevel", 2, 14, xdg_toplevel_requests, 2, xdg_toplevel_events,
};

static const struct wl_message xdg_positioner_requests[] = {
    { "destroy", "", xdg_types + 0 },
    { "set_size", "ii", xdg_types + 0 },
    { "set_anchor_rect", "iiii", xdg_types + 0 },
    { "set_anchor", "u", xdg_types + 0 },
    { "set_gravity", "u", xdg_types + 0 },
    { "set_constraint_adjustment", "u", xdg_types + 0 },
    { "set_offset", "ii", xdg_types + 0 },
};
static const struct wl_interface xdg_positioner_interface = {
    "xdg_positioner", 2, 7, xdg_positioner_requests, 0, NULL,
};

static const struct wl_message xdg_popup_requests[] = {
    { "destroy", "", xdg_types + 0 },
    { "grab", "ou", xdg_types + 22 },
};
static const struct wl_message xdg_popup_events[] = {
    { "configure", "iiii", xdg_types + 0 },
    { "popup_done", "", xdg_types + 0 },
};
static const struct wl_interface xdg_popup_interface = {
    "xdg_popup", 2, 2, xdg_popup_requests, 2, xdg_popup_events,
};

enum { XDG_WM_BASE_CREATE_POSITIONER = 1, XDG_WM_BASE_GET_XDG_SURFACE = 2, XDG_WM_BASE_PONG = 3 };
enum { XDG_SURFACE_GET_POPUP = 2 };
enum { XDG_SURFACE_GET_TOPLEVEL = 1, XDG_SURFACE_ACK_CONFIGURE = 4 };
enum { XDG_TOPLEVEL_SET_TITLE = 2, XDG_TOPLEVEL_SET_APP_ID = 3 };

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------

#define MAX_OUTPUTS 8
#define MAX_EXT 16

static struct {
    const zwl_listener* l;
    void* data;

    struct wl_display* display;
    struct wl_registry* registry;
    struct wl_compositor* compositor;
    struct wl_proxy* wm_base;
    struct wl_seat* seat;
    struct wl_keyboard* keyboard;
    struct wl_pointer* pointer;
    struct wl_shm* shm;
    struct wl_proxy* cursor_shape_manager;
    struct wl_proxy* cursor_shape_device;
    struct wl_cursor_theme* cursor_theme;
    struct wl_surface* cursor_surface;
    // The serial of the pointer's enter, which a cursor change names.
    uint32_t pointer_serial;
    int cursor_shape;
    // The serial of the last key or button press: what a selection is set with.
    uint32_t input_serial;
    // The surface that has the keyboard; NULL while none of ours has it.
    struct wl_surface* kb_surface;
    struct wl_proxy* activation;
    struct wl_proxy* text_input_manager;
    struct wl_proxy* text_input;
    int ime_entered;
    int32_t ime_rect[4];
    // What the IME sent since its last `done`.
    char* ime_preedit;
    int32_t ime_preedit_begin, ime_preedit_end;
    char* ime_commit;
    // [0] the clipboard, [1] the primary selection.
    struct wl_data_device_manager* data_manager;
    struct wl_data_device* data_device;
    struct wl_proxy* primary_manager;
    struct wl_proxy* primary_device;
    struct selection {
        // The offer being announced, and whether it has text.
        void* incoming;
        int incoming_text;
        int incoming_uris;
        // The selection as last announced; NULL for none.
        void* offer;
        int offer_text;
        // What this client set, while it owns the selection.
        void* source;
        char* own;
        size_t own_len;
    } sel[2];
    // One pointer frame's scroll: px, and wheel notches when a wheel sent it.
    double axis_px[2];
    int32_t axis_steps[2];
    int axis_seen;
    // A touchpad's recent travel, for the speed the fingers lift at.
    struct axis_sample { uint32_t time_ms; double px[2]; } axis_recent[8];
    int axis_recent_n;
    int axis_finger, axis_stopped;
    struct wl_output* outputs[MAX_OUTPUTS];
    int32_t output_scale[MAX_OUTPUTS];
    int n_outputs;

    struct wl_surface* surface;
    struct wl_proxy* xdg_surface;
    struct wl_proxy* toplevel;
    struct wl_proxy* decoration;
    int server_decorations;
    struct wl_callback* frame;
    int32_t pending_w, pending_h;
    // The compositor sizes the window (maximized, fullscreen or tiled).
    int pending_placed, placed;
    int pending_maximized, maximized;
    // The serial of the last pointer button press: a move or a resize the
    // compositor takes over names it.
    uint32_t button_serial;
    struct wl_proxy* decoration_manager;

    struct wl_egl_window* egl_window;
    // The size the window's buffers were last asked for, device px.
    int32_t egl_w_px, egl_h_px;
    EGLDisplay egl_display;
    EGLContext egl_context;
    EGLSurface egl_surface;
    EGLConfig egl_config;
    // EGL_EXT_buffer_age, and the swap that names the damage (KHR or EXT);
    // without them every frame is drawn whole.
    int has_buffer_age;
    PFNEGLSWAPBUFFERSWITHDAMAGEKHRPROC swap_with_damage;

    // External windows (zwl_ext_open).
    struct zwl_ext {
        int64_t id; // 0: free
        struct wl_surface* surface;
        struct wl_proxy* xdg_surface;
        struct wl_proxy* toplevel;
        // A popup of another window instead of a toplevel.
        struct wl_proxy* popup;
        struct wl_proxy* decoration;
        struct wl_callback* frame;
        struct wl_egl_window* egl_window;
        EGLSurface egl_surface;
        // Its swap interval is zero (zwl_ext_make_current).
        int swap_unpaced;
        int32_t pending_w, pending_h;
        // The compositor sizes the window (maximized, fullscreen or tiled).
        int pending_placed, placed;
    } ext[MAX_EXT];

    struct xkb_context* xkb;
    struct xkb_keymap* keymap;
    struct xkb_state* xkb_state;
    int32_t repeat_rate, repeat_delay;
} w;

// ---------------------------------------------------------------------------
// Outputs: the scale is known before the window exists.
// ---------------------------------------------------------------------------

static struct zwl_ext* ext_of_surface(struct wl_surface* s) {
    for (int i = 0; i < MAX_EXT; i++) if (w.ext[i].id && w.ext[i].surface == s) return &w.ext[i];
    return NULL;
}
static struct zwl_ext* ext_of_id(int64_t id) {
    if (!id) return NULL;
    for (int i = 0; i < MAX_EXT; i++) if (w.ext[i].id == id) return &w.ext[i];
    return NULL;
}

static void output_geometry(void* d, struct wl_output* o, int32_t x, int32_t y, int32_t pw, int32_t ph,
                            int32_t sub, const char* make, const char* model, int32_t tr) {
    (void)d; (void)o; (void)x; (void)y; (void)pw; (void)ph; (void)sub; (void)make; (void)model; (void)tr;
}
static void output_mode(void* d, struct wl_output* o, uint32_t f, int32_t wd, int32_t h, int32_t r) {
    (void)d; (void)o; (void)f; (void)wd; (void)h; (void)r;
}
static void output_done(void* d, struct wl_output* o) { (void)d; (void)o; }
static void output_scale(void* d, struct wl_output* o, int32_t factor) {
    (void)d;
    for (int i = 0; i < w.n_outputs; i++) {
        if (w.outputs[i] == o) w.output_scale[i] = factor;
    }
}
static const struct wl_output_listener output_listener = {
    output_geometry, output_mode, output_done, output_scale,
};

int zwl_scale(void) {
    int32_t s = 1;
    for (int i = 0; i < w.n_outputs; i++) {
        if (w.output_scale[i] > s) s = w.output_scale[i];
    }
    return s;
}

// ---------------------------------------------------------------------------
// Keyboard
// ---------------------------------------------------------------------------

// The masks keymap.zig takes.
#define MASK_SHIFT (1u << 0)
#define MASK_CTRL (1u << 2)
#define MASK_ALT (1u << 3)
#define MASK_SUPER (1u << 26)

static uint32_t mods_mask(void) {
    if (!w.xkb_state) return 0;
    uint32_t m = 0;
    if (xkb_state_mod_name_is_active(w.xkb_state, XKB_MOD_NAME_SHIFT, XKB_STATE_MODS_EFFECTIVE) > 0) m |= MASK_SHIFT;
    if (xkb_state_mod_name_is_active(w.xkb_state, XKB_MOD_NAME_CTRL, XKB_STATE_MODS_EFFECTIVE) > 0) m |= MASK_CTRL;
    if (xkb_state_mod_name_is_active(w.xkb_state, XKB_MOD_NAME_ALT, XKB_STATE_MODS_EFFECTIVE) > 0) m |= MASK_ALT;
    if (xkb_state_mod_name_is_active(w.xkb_state, XKB_MOD_NAME_LOGO, XKB_STATE_MODS_EFFECTIVE) > 0) m |= MASK_SUPER;
    return m;
}

static void kb_keymap(void* d, struct wl_keyboard* k, uint32_t format, int32_t fd, uint32_t size) {
    (void)d; (void)k;
    if (format != WL_KEYBOARD_KEYMAP_FORMAT_XKB_V1) { close(fd); return; }
    char* map = mmap(NULL, size, PROT_READ, MAP_PRIVATE, fd, 0);
    close(fd);
    if (map == MAP_FAILED) return;
    struct xkb_keymap* km = xkb_keymap_new_from_buffer(w.xkb, map, strnlen(map, size), XKB_KEYMAP_FORMAT_TEXT_V1,
                                                      XKB_KEYMAP_COMPILE_NO_FLAGS);
    munmap(map, size);
    if (!km) return;
    struct xkb_state* st = xkb_state_new(km);
    if (!st) { xkb_keymap_unref(km); return; }
    if (w.xkb_state) xkb_state_unref(w.xkb_state);
    if (w.keymap) xkb_keymap_unref(w.keymap);
    w.keymap = km;
    w.xkb_state = st;
    // The keys held belong to the keymap before: a release may never come
    // (a virtual keyboard that went away with its keymap).
    if (w.l->keys_reset) w.l->keys_reset(w.data);
}
static void kb_enter(void* d, struct wl_keyboard* k, uint32_t serial, struct wl_surface* s, struct wl_array* keys) {
    (void)d; (void)k; (void)serial; (void)keys;
    w.kb_surface = s;
    struct zwl_ext* e = s == w.surface ? NULL : ext_of_surface(s);
    if (w.l->focus) w.l->focus(w.data, 1, s == w.surface ? 1 : e ? e->id : 0);
}
static void kb_leave(void* d, struct wl_keyboard* k, uint32_t serial, struct wl_surface* s) {
    (void)d; (void)k; (void)serial; (void)s;
    w.kb_surface = NULL;
    if (w.l->focus) w.l->focus(w.data, 0, 0);
}
static void kb_key(void* d, struct wl_keyboard* k, uint32_t serial, uint32_t time, uint32_t key, uint32_t state) {
    (void)d; (void)k; (void)time;
    if (state == WL_KEYBOARD_KEY_STATE_PRESSED) w.input_serial = serial;
    if (!w.xkb_state || !w.l->key) return;
    const xkb_keycode_t code = key + 8;
    const xkb_keysym_t sym = xkb_state_key_get_one_sym(w.xkb_state, code);
    // The key with no modifier held, in the active layout.
    xkb_keysym_t base = sym;
    const xkb_keysym_t* syms = NULL;
    const xkb_layout_index_t layout = xkb_state_key_get_layout(w.xkb_state, code);
    if (xkb_keymap_key_get_syms_by_level(w.keymap, code, layout, 0, &syms) > 0) base = syms[0];
    w.l->key(w.data, key, sym, base, xkb_keysym_to_utf32(sym), xkb_keysym_to_utf32(base), mods_mask(),
             state == WL_KEYBOARD_KEY_STATE_PRESSED, xkb_keymap_key_repeats(w.keymap, code));
}
static void kb_modifiers(void* d, struct wl_keyboard* k, uint32_t serial, uint32_t dep, uint32_t lat, uint32_t lock,
                         uint32_t group) {
    (void)d; (void)k; (void)serial;
    if (w.xkb_state) xkb_state_update_mask(w.xkb_state, dep, lat, lock, 0, 0, group);
}
static void kb_repeat_info(void* d, struct wl_keyboard* k, int32_t rate, int32_t delay) {
    (void)d; (void)k;
    w.repeat_rate = rate;
    w.repeat_delay = delay;
}
static const struct wl_keyboard_listener keyboard_listener = {
    kb_keymap, kb_enter, kb_leave, kb_key, kb_modifiers, kb_repeat_info,
};

uint32_t zwl_mods(void) { return mods_mask(); }

void zwl_repeat_info(int32_t* rate, int32_t* delay) {
    *rate = w.repeat_rate;
    *delay = w.repeat_delay;
}

// ---------------------------------------------------------------------------
// Pointer
// ---------------------------------------------------------------------------

// cursor-shape-v1, version 1, as the scanner would emit it: the compositor
// draws a named cursor. Without it the cursor comes from the cursor theme.
static const struct wl_interface cursor_shape_device_interface;
static const struct wl_interface* cursor_shape_types[] = {
    NULL, NULL,
    &cursor_shape_device_interface, &wl_pointer_interface,
    &cursor_shape_device_interface, NULL,
};
static const struct wl_message cursor_shape_manager_requests[] = {
    { "destroy", "", cursor_shape_types + 0 },
    { "get_pointer", "no", cursor_shape_types + 2 },
    { "get_tablet_tool_v2", "no", cursor_shape_types + 4 },
};
static const struct wl_interface cursor_shape_manager_interface = {
    "wp_cursor_shape_manager_v1", 1, 3, cursor_shape_manager_requests, 0, NULL,
};
static const struct wl_message cursor_shape_device_requests[] = {
    { "destroy", "", cursor_shape_types + 0 },
    { "set_shape", "uu", cursor_shape_types + 0 },
};
static const struct wl_interface cursor_shape_device_interface = {
    "wp_cursor_shape_device_v1", 1, 2, cursor_shape_device_requests, 0, NULL,
};
enum { CURSOR_SHAPE_MANAGER_GET_POINTER = 1, CURSOR_SHAPE_DEVICE_SET_SHAPE = 1 };

// xdg-activation-v1, version 1, as the scanner would emit it: a window of
// this client asks for the keyboard, with a token naming the input that
// asked for it.
static const struct wl_interface activation_token_interface;
static const struct wl_interface* activation_types[] = {
    NULL,
    &activation_token_interface,
    NULL, &wl_surface_interface,
    NULL, &wl_seat_interface,
    &wl_surface_interface,
};
static const struct wl_message activation_requests[] = {
    { "destroy", "", activation_types + 0 },
    { "get_activation_token", "n", activation_types + 1 },
    { "activate", "so", activation_types + 2 },
};
static const struct wl_interface activation_interface = {
    "xdg_activation_v1", 1, 3, activation_requests, 0, NULL,
};
static const struct wl_message activation_token_requests[] = {
    { "set_serial", "uo", activation_types + 4 },
    { "set_app_id", "s", activation_types + 0 },
    { "set_surface", "o", activation_types + 6 },
    { "commit", "", activation_types + 0 },
    { "destroy", "", activation_types + 0 },
};
static const struct wl_message activation_token_events[] = {
    { "done", "s", activation_types + 0 },
};
static const struct wl_interface activation_token_interface = {
    "xdg_activation_token_v1", 1, 5, activation_token_requests, 1, activation_token_events,
};
enum {
    ACTIVATION_GET_TOKEN = 1,
    ACTIVATION_ACTIVATE = 2,
    ACTIVATION_TOKEN_SET_SERIAL = 0,
    ACTIVATION_TOKEN_SET_SURFACE = 2,
    ACTIVATION_TOKEN_COMMIT = 3,
    ACTIVATION_TOKEN_DESTROY = 4,
};
// The cursor theme's name for a wp_cursor_shape_device_v1.shape, with an
// older name some themes still carry.
static void cursor_names(int shape, const char** name, const char** old) {
    switch (shape) {
    case 1: *name = "default"; *old = "left_ptr"; break;
    case 4: *name = "pointer"; *old = "hand2"; break;
    case 13: *name = "move"; *old = "fleur"; break;
    case 18: *name = "e-resize"; *old = "right_side"; break;
    case 19: *name = "n-resize"; *old = "top_side"; break;
    case 20: *name = "ne-resize"; *old = "top_right_corner"; break;
    case 21: *name = "nw-resize"; *old = "top_left_corner"; break;
    case 22: *name = "s-resize"; *old = "bottom_side"; break;
    case 23: *name = "se-resize"; *old = "bottom_right_corner"; break;
    case 24: *name = "sw-resize"; *old = "bottom_left_corner"; break;
    case 25: *name = "w-resize"; *old = "left_side"; break;
    case 26: *name = "ew-resize"; *old = "sb_h_double_arrow"; break;
    default: *name = "text"; *old = "xterm"; break;
    }
}

static void set_cursor(uint32_t serial) {
    const int shape = w.cursor_shape ? w.cursor_shape : 9;
    if (w.cursor_shape_manager) {
        if (!w.cursor_shape_device) {
            w.cursor_shape_device = wl_proxy_marshal_flags(w.cursor_shape_manager, CURSOR_SHAPE_MANAGER_GET_POINTER,
                                                           &cursor_shape_device_interface, 1, 0, NULL, w.pointer);
        }
        wl_proxy_marshal_flags(w.cursor_shape_device, CURSOR_SHAPE_DEVICE_SET_SHAPE, NULL, 1, 0, serial,
                               (uint32_t)shape);
        return;
    }
    if (!w.shm) return;
    const int scale = zwl_scale();
    if (!w.cursor_theme) w.cursor_theme = wl_cursor_theme_load(NULL, 24 * scale, w.shm);
    if (!w.cursor_theme) return;
    const char* name;
    const char* old;
    cursor_names(shape, &name, &old);
    struct wl_cursor* c = wl_cursor_theme_get_cursor(w.cursor_theme, name);
    if (!c) c = wl_cursor_theme_get_cursor(w.cursor_theme, old);
    if (!c) c = wl_cursor_theme_get_cursor(w.cursor_theme, "left_ptr");
    if (!c || c->image_count == 0) return;
    struct wl_cursor_image* img = c->images[0];
    if (!w.cursor_surface) w.cursor_surface = wl_compositor_create_surface(w.compositor);
    wl_surface_set_buffer_scale(w.cursor_surface, scale);
    wl_surface_attach(w.cursor_surface, wl_cursor_image_get_buffer(img), 0, 0);
    wl_surface_damage(w.cursor_surface, 0, 0, img->width, img->height);
    wl_surface_commit(w.cursor_surface);
    wl_pointer_set_cursor(w.pointer, serial, w.cursor_surface, img->hotspot_x / scale, img->hotspot_y / scale);
}

static void ptr_enter(void* d, struct wl_pointer* p, uint32_t serial, struct wl_surface* s, wl_fixed_t x, wl_fixed_t y) {
    (void)d; (void)p;
    w.pointer_serial = serial;
    set_cursor(serial);
    struct zwl_ext* e = ext_of_surface(s);
    if (w.l->pointer_window) w.l->pointer_window(w.data, e ? e->id : 0);
    if (w.l->pointer_motion) w.l->pointer_motion(w.data, wl_fixed_to_double(x), wl_fixed_to_double(y));
}
void zwl_cursor(int shape) {
    if (w.cursor_shape == shape) return;
    w.cursor_shape = shape;
    if (w.pointer) set_cursor(w.pointer_serial);
}

static void ptr_leave(void* d, struct wl_pointer* p, uint32_t serial, struct wl_surface* s) {
    (void)d; (void)p; (void)serial; (void)s;
    if (w.l->pointer_leave) w.l->pointer_leave(w.data);
}
static void ptr_motion(void* d, struct wl_pointer* p, uint32_t time, wl_fixed_t x, wl_fixed_t y) {
    (void)d; (void)p; (void)time;
    if (w.l->pointer_motion) w.l->pointer_motion(w.data, wl_fixed_to_double(x), wl_fixed_to_double(y));
}
static void ptr_button(void* d, struct wl_pointer* p, uint32_t serial, uint32_t time, uint32_t button, uint32_t state) {
    (void)d; (void)p; (void)time;
    const int pressed = state == WL_POINTER_BUTTON_STATE_PRESSED;
    if (pressed) {
        w.input_serial = serial;
        w.button_serial = serial;
    }
    if (w.l->pointer_button) w.l->pointer_button(w.data, button, pressed, mods_mask());
}
static void ptr_axis(void* d, struct wl_pointer* p, uint32_t time, uint32_t axis, wl_fixed_t value) {
    (void)d; (void)p; (void)time;
    if (axis > 1) return;
    const double px = wl_fixed_to_double(value);
    w.axis_px[axis] += px;
    w.axis_seen = 1;
    // One sample per event time: both axes of a frame share it.
    const int n = w.axis_recent_n;
    if (n > 0 && w.axis_recent[n - 1].time_ms == time) {
        w.axis_recent[n - 1].px[axis] += px;
        return;
    }
    const int cap = (int)(sizeof w.axis_recent / sizeof *w.axis_recent);
    if (n == cap) memmove(w.axis_recent, w.axis_recent + 1, (size_t)(cap - 1) * sizeof *w.axis_recent);
    struct axis_sample* s = &w.axis_recent[n == cap ? cap - 1 : n];
    if (n < cap) w.axis_recent_n = n + 1;
    s->time_ms = time;
    s->px[0] = s->px[1] = 0;
    s->px[axis] = px;
}
static void ptr_frame(void* d, struct wl_pointer* p) {
    (void)d; (void)p;
    if (w.axis_stopped) {
        // The fingers left the pad: their speed over the last tenth of a
        // second, in px/s, is what a flick carries on with.
        w.axis_stopped = 0;
        double sum[2] = { 0, 0 };
        uint32_t first = 0, last = 0;
        int used = 0;
        const struct axis_sample* oldest = NULL;
        for (int i = w.axis_recent_n - 1; i >= 0; i--) {
            const struct axis_sample* s = &w.axis_recent[i];
            if (used == 0) last = s->time_ms;
            if (last - s->time_ms > 100) break;
            first = s->time_ms;
            sum[0] += s->px[0];
            sum[1] += s->px[1];
            oldest = s;
            used++;
        }
        // A sample holds the travel since the one before it: the oldest
        // one's was covered before `first`, outside the time divided by.
        if (oldest) {
            sum[0] -= oldest->px[0];
            sum[1] -= oldest->px[1];
        }
        w.axis_recent_n = 0;
        if (w.axis_finger && used >= 2 && last > first && w.l->pointer_axis_stop) {
            const double dt = (double)(last - first) / 1000.0;
            w.l->pointer_axis_stop(w.data, sum[1] / dt, sum[0] / dt);
        }
    }
    if (!w.axis_seen) return;
    // Vertical is axis 0, horizontal axis 1.
    if (w.l->pointer_axis) {
        w.l->pointer_axis(w.data, w.axis_px[1], w.axis_px[0], w.axis_steps[1], w.axis_steps[0], mods_mask());
    }
    w.axis_px[0] = w.axis_px[1] = 0;
    w.axis_steps[0] = w.axis_steps[1] = 0;
    w.axis_seen = 0;
}
static void ptr_axis_source(void* d, struct wl_pointer* p, uint32_t source) {
    (void)d; (void)p;
    w.axis_finger = source == WL_POINTER_AXIS_SOURCE_FINGER;
}
static void ptr_axis_stop(void* d, struct wl_pointer* p, uint32_t time, uint32_t axis) {
    (void)d; (void)p; (void)time; (void)axis;
    w.axis_stopped = 1;
}
static void ptr_axis_discrete(void* d, struct wl_pointer* p, uint32_t axis, int32_t discrete) {
    (void)d; (void)p;
    if (axis > 1) return;
    w.axis_steps[axis] += discrete;
    w.axis_seen = 1;
}
static const struct wl_pointer_listener pointer_listener = {
    ptr_enter, ptr_leave, ptr_motion, ptr_button, ptr_axis, ptr_frame, ptr_axis_source, ptr_axis_stop,
    ptr_axis_discrete,
};

// ---------------------------------------------------------------------------
// Selections: the clipboard (wl_data_device) and the primary selection
// (zwp_primary_selection_unstable_v1, written out as the scanner would).
// ---------------------------------------------------------------------------

static const char* const text_mimes[] = { "text/plain;charset=utf-8", "UTF8_STRING", "text/plain" };

static int is_text_mime(const char* mime) {
    for (size_t i = 0; i < sizeof text_mimes / sizeof *text_mimes; i++) {
        if (strcmp(mime, text_mimes[i]) == 0) return 1;
    }
    return 0;
}

static void write_all(int fd, const char* p, size_t n) {
    // The reader may be slow or gone: blocking writes, EPIPE ends them.
    fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) & ~O_NONBLOCK);
    while (n > 0) {
        const ssize_t k = write(fd, p, n);
        if (k < 0) {
            if (errno == EINTR) continue;
            break;
        }
        p += k;
        n -= (size_t)k;
    }
    close(fd);
}

static void source_gone(int kind, void* source) {
    struct selection* s = &w.sel[kind];
    if (s->source != source) return;
    s->source = NULL;
    free(s->own);
    s->own = NULL;
    s->own_len = 0;
}

// --- clipboard ---

static void offer_offer(void* d, struct wl_data_offer* o, const char* mime) {
    (void)d;
    if (w.sel[0].incoming != o) return;
    if (is_text_mime(mime)) w.sel[0].incoming_text = 1;
    if (strcmp(mime, "text/uri-list") == 0) w.sel[0].incoming_uris = 1;
}
static void offer_source_actions(void* d, struct wl_data_offer* o, uint32_t a) { (void)d; (void)o; (void)a; }
static void offer_action(void* d, struct wl_data_offer* o, uint32_t a) { (void)d; (void)o; (void)a; }
static const struct wl_data_offer_listener offer_listener = { offer_offer, offer_source_actions, offer_action };

static void dev_data_offer(void* d, struct wl_data_device* dev, struct wl_data_offer* o) {
    (void)d; (void)dev;
    w.sel[0].incoming = o;
    w.sel[0].incoming_text = 0;
    w.sel[0].incoming_uris = 0;
    wl_data_offer_add_listener(o, &offer_listener, NULL);
}
// Reads `fd` to its end, for at most a second: malloc'ed, or NULL.
static char* read_pipe(int fd, size_t* out_len) {
    struct timespec t0;
    clock_gettime(CLOCK_MONOTONIC, &t0);
    size_t cap = 4096, n = 0;
    char* out = malloc(cap);
    while (out) {
        struct timespec now;
        clock_gettime(CLOCK_MONOTONIC, &now);
        const long left_ms = 1000 - ((now.tv_sec - t0.tv_sec) * 1000 + (now.tv_nsec - t0.tv_nsec) / 1000000);
        struct pollfd pfd = { fd, POLLIN, 0 };
        if (left_ms <= 0 || poll(&pfd, 1, (int)left_ms) <= 0) break;
        if (n == cap) {
            cap *= 2;
            char* grown = realloc(out, cap);
            if (!grown) { free(out); out = NULL; break; }
            out = grown;
        }
        const ssize_t k = read(fd, out + n, cap - n);
        if (k < 0 && errno == EINTR) continue;
        if (k <= 0) break;
        n += (size_t)k;
    }
    close(fd);
    if (out) *out_len = n;
    return out;
}

// A drag over the window: its offer is not the selection's. Only files are
// taken (text/uri-list); anything else is refused, so the source shows it.
static struct wl_data_offer* drag_offer;
static int drag_uris;
static void dev_enter(void* d, struct wl_data_device* dev, uint32_t serial, struct wl_surface* s, wl_fixed_t x,
                      wl_fixed_t y, struct wl_data_offer* o) {
    (void)d; (void)dev; (void)s; (void)x; (void)y;
    drag_offer = o;
    drag_uris = o && w.sel[0].incoming == o && w.sel[0].incoming_uris;
    if (w.sel[0].incoming == o) w.sel[0].incoming = NULL;
    if (!o) return;
    wl_data_offer_accept(o, serial, drag_uris ? "text/uri-list" : NULL);
    if (drag_uris && wl_proxy_get_version((struct wl_proxy*)o) >= 3) {
        wl_data_offer_set_actions(o, WL_DATA_DEVICE_MANAGER_DND_ACTION_COPY, WL_DATA_DEVICE_MANAGER_DND_ACTION_COPY);
    }
}
static void dev_leave(void* d, struct wl_data_device* dev) {
    (void)d; (void)dev;
    if (drag_offer) wl_data_offer_destroy(drag_offer);
    drag_offer = NULL;
}
static void dev_motion(void* d, struct wl_data_device* dev, uint32_t t, wl_fixed_t x, wl_fixed_t y) {
    (void)d; (void)dev; (void)t; (void)x; (void)y;
}
static void dev_drop(void* d, struct wl_data_device* dev) {
    (void)d; (void)dev;
    struct wl_data_offer* o = drag_offer;
    drag_offer = NULL;
    if (!o) return;
    if (drag_uris) {
        int fds[2];
        if (pipe2(fds, O_CLOEXEC) == 0) {
            wl_data_offer_receive(o, "text/uri-list", fds[1]);
            close(fds[1]);
            wl_display_flush(w.display);
            size_t n = 0;
            char* uris = read_pipe(fds[0], &n);
            if (uris && w.l->drop) w.l->drop(w.data, uris, n);
            free(uris);
        }
        if (wl_proxy_get_version((struct wl_proxy*)o) >= 3) wl_data_offer_finish(o);
    }
    wl_data_offer_destroy(o);
}
static void dev_selection(void* d, struct wl_data_device* dev, struct wl_data_offer* o) {
    (void)d; (void)dev;
    struct selection* s = &w.sel[0];
    if (s->offer && s->offer != o) wl_data_offer_destroy(s->offer);
    s->offer = o;
    s->offer_text = o && s->incoming == o ? s->incoming_text : 0;
    s->incoming = NULL;
}
static const struct wl_data_device_listener data_device_listener = {
    dev_data_offer, dev_enter, dev_leave, dev_motion, dev_drop, dev_selection,
};

static void src_target(void* d, struct wl_data_source* s, const char* mime) { (void)d; (void)s; (void)mime; }
static void src_send(void* d, struct wl_data_source* s, const char* mime, int32_t fd) {
    (void)d; (void)mime;
    if (w.sel[0].source == s && w.sel[0].own) write_all(fd, w.sel[0].own, w.sel[0].own_len);
    else close(fd);
}
static void src_cancelled(void* d, struct wl_data_source* s) {
    (void)d;
    source_gone(0, s);
    wl_data_source_destroy(s);
}
static void src_dnd_drop(void* d, struct wl_data_source* s) { (void)d; (void)s; }
static void src_dnd_finished(void* d, struct wl_data_source* s) { (void)d; (void)s; }
static void src_action(void* d, struct wl_data_source* s, uint32_t a) { (void)d; (void)s; (void)a; }
static const struct wl_data_source_listener data_source_listener = {
    src_target, src_send, src_cancelled, src_dnd_drop, src_dnd_finished, src_action,
};

// --- primary selection ---

static const struct wl_interface primary_source_interface;
static const struct wl_interface primary_device_interface;
static const struct wl_interface primary_offer_interface;
static const struct wl_interface* primary_types[] = {
    NULL, NULL,
    &primary_source_interface,
    &primary_device_interface, &wl_seat_interface,
    &primary_source_interface, NULL,
    &primary_offer_interface,
};
static const struct wl_message primary_manager_requests[] = {
    { "create_source", "n", primary_types + 2 },
    { "get_device", "no", primary_types + 3 },
    { "destroy", "", primary_types + 0 },
};
static const struct wl_interface primary_manager_interface = {
    "zwp_primary_selection_device_manager_v1", 1, 3, primary_manager_requests, 0, NULL,
};
static const struct wl_message primary_device_requests[] = {
    { "set_selection", "?ou", primary_types + 5 },
    { "destroy", "", primary_types + 0 },
};
static const struct wl_message primary_device_events[] = {
    { "data_offer", "n", primary_types + 7 },
    { "selection", "?o", primary_types + 7 },
};
static const struct wl_interface primary_device_interface = {
    "zwp_primary_selection_device_v1", 1, 2, primary_device_requests, 2, primary_device_events,
};
static const struct wl_message primary_offer_requests[] = {
    { "receive", "sh", primary_types + 0 },
    { "destroy", "", primary_types + 0 },
};
static const struct wl_message primary_offer_events[] = {
    { "offer", "s", primary_types + 0 },
};
static const struct wl_interface primary_offer_interface = {
    "zwp_primary_selection_offer_v1", 1, 2, primary_offer_requests, 1, primary_offer_events,
};
static const struct wl_message primary_source_requests[] = {
    { "offer", "s", primary_types + 0 },
    { "destroy", "", primary_types + 0 },
};
static const struct wl_message primary_source_events[] = {
    { "send", "sh", primary_types + 0 },
    { "cancelled", "", primary_types + 0 },
};
static const struct wl_interface primary_source_interface = {
    "zwp_primary_selection_source_v1", 1, 2, primary_source_requests, 2, primary_source_events,
};
enum { PRIMARY_MANAGER_CREATE_SOURCE = 0, PRIMARY_MANAGER_GET_DEVICE = 1 };
enum { PRIMARY_DEVICE_SET_SELECTION = 0 };
enum { PRIMARY_OFFER_RECEIVE = 0, PRIMARY_OFFER_DESTROY = 1 };
enum { PRIMARY_SOURCE_OFFER = 0, PRIMARY_SOURCE_DESTROY = 1 };

static void p_offer_offer(void* d, struct wl_proxy* o, const char* mime) {
    (void)d;
    if (w.sel[1].incoming == o && is_text_mime(mime)) w.sel[1].incoming_text = 1;
}
static const struct { void (*offer)(void*, struct wl_proxy*, const char*); } primary_offer_listener = { p_offer_offer };

static void p_dev_data_offer(void* d, struct wl_proxy* dev, struct wl_proxy* o) {
    (void)d; (void)dev;
    w.sel[1].incoming = o;
    w.sel[1].incoming_text = 0;
    wl_proxy_add_listener(o, (void (**)(void))&primary_offer_listener, NULL);
}
static void p_dev_selection(void* d, struct wl_proxy* dev, struct wl_proxy* o) {
    (void)d; (void)dev;
    struct selection* s = &w.sel[1];
    if (s->offer && s->offer != o) {
        wl_proxy_marshal_flags(s->offer, PRIMARY_OFFER_DESTROY, NULL, 1, WL_MARSHAL_FLAG_DESTROY);
    }
    s->offer = o;
    s->offer_text = o && s->incoming == o ? s->incoming_text : 0;
    s->incoming = NULL;
}
static const struct {
    void (*data_offer)(void*, struct wl_proxy*, struct wl_proxy*);
    void (*selection)(void*, struct wl_proxy*, struct wl_proxy*);
} primary_device_listener = { p_dev_data_offer, p_dev_selection };

static void p_src_send(void* d, struct wl_proxy* s, const char* mime, int32_t fd) {
    (void)d; (void)mime;
    if (w.sel[1].source == s && w.sel[1].own) write_all(fd, w.sel[1].own, w.sel[1].own_len);
    else close(fd);
}
static void p_src_cancelled(void* d, struct wl_proxy* s) {
    (void)d;
    source_gone(1, s);
    wl_proxy_marshal_flags(s, PRIMARY_SOURCE_DESTROY, NULL, 1, WL_MARSHAL_FLAG_DESTROY);
}
static const struct {
    void (*send)(void*, struct wl_proxy*, const char*, int32_t);
    void (*cancelled)(void*, struct wl_proxy*);
} primary_source_listener = { p_src_send, p_src_cancelled };

// --- both ---

static void selection_devices(void) {
    if (!w.seat) return;
    if (w.data_manager && !w.data_device) {
        w.data_device = wl_data_device_manager_get_data_device(w.data_manager, w.seat);
        wl_data_device_add_listener(w.data_device, &data_device_listener, NULL);
    }
    if (w.primary_manager && !w.primary_device) {
        w.primary_device = wl_proxy_marshal_flags(w.primary_manager, PRIMARY_MANAGER_GET_DEVICE,
                                                  &primary_device_interface, 1, 0, NULL, w.seat);
        wl_proxy_add_listener(w.primary_device, (void (**)(void))&primary_device_listener, NULL);
    }
}

int zwl_selection_set(int primary, const char* text, size_t len) {
    const int kind = primary ? 1 : 0;
    struct selection* s = &w.sel[kind];
    char* copy = malloc(len ? len : 1);
    if (!copy) return -1;
    memcpy(copy, text, len);
    void* source;
    if (kind == 0) {
        if (!w.data_manager || !w.data_device) { free(copy); return -1; }
        struct wl_data_source* src = wl_data_device_manager_create_data_source(w.data_manager);
        wl_data_source_add_listener(src, &data_source_listener, NULL);
        for (size_t i = 0; i < sizeof text_mimes / sizeof *text_mimes; i++) wl_data_source_offer(src, text_mimes[i]);
        wl_data_device_set_selection(w.data_device, src, w.input_serial);
        source = src;
    } else {
        if (!w.primary_manager || !w.primary_device) { free(copy); return -1; }
        struct wl_proxy* src = wl_proxy_marshal_flags(w.primary_manager, PRIMARY_MANAGER_CREATE_SOURCE,
                                                      &primary_source_interface, 1, 0, NULL);
        wl_proxy_add_listener(src, (void (**)(void))&primary_source_listener, NULL);
        for (size_t i = 0; i < sizeof text_mimes / sizeof *text_mimes; i++) {
            wl_proxy_marshal_flags(src, PRIMARY_SOURCE_OFFER, NULL, 1, 0, text_mimes[i]);
        }
        wl_proxy_marshal_flags(w.primary_device, PRIMARY_DEVICE_SET_SELECTION, NULL, 1, 0, src, w.input_serial);
        source = src;
    }
    // The source this one replaces is cancelled by the compositor, which
    // frees it (source_gone keeps this text: its source differs by then).
    free(s->own);
    s->own = copy;
    s->own_len = len;
    s->source = source;
    wl_display_flush(w.display);
    return 0;
}

// The selection's text, malloc'ed, or NULL when it holds none. Reads another
// client's selection through a pipe, for at most a second.
char* zwl_selection_get(int primary, size_t* out_len) {
    const int kind = primary ? 1 : 0;
    struct selection* s = &w.sel[kind];
    *out_len = 0;
    // Its own selection: reading it back through the compositor would wait
    // on this very thread to serve it.
    if (s->source && s->own) {
        char* out = malloc(s->own_len ? s->own_len : 1);
        if (!out) return NULL;
        memcpy(out, s->own, s->own_len);
        *out_len = s->own_len;
        return out;
    }
    if (!s->offer || !s->offer_text) return NULL;
    int fds[2];
    if (pipe2(fds, O_CLOEXEC) != 0) return NULL;
    if (kind == 0) wl_data_offer_receive(s->offer, text_mimes[0], fds[1]);
    else wl_proxy_marshal_flags(s->offer, PRIMARY_OFFER_RECEIVE, NULL, 1, 0, text_mimes[0], fds[1]);
    close(fds[1]);
    wl_display_flush(w.display);
    return read_pipe(fds[0], out_len);
}

// ---------------------------------------------------------------------------
// The input method: text-input-unstable-v3, written out as the scanner would.
// ---------------------------------------------------------------------------

static const struct wl_interface text_input_interface;
static const struct wl_interface* text_input_types[] = {
    NULL, NULL, NULL, NULL,
    &text_input_interface, &wl_seat_interface,
    &wl_surface_interface,
};
static const struct wl_message text_input_manager_requests[] = {
    { "destroy", "", text_input_types + 0 },
    { "get_text_input", "no", text_input_types + 4 },
};
static const struct wl_interface text_input_manager_interface = {
    "zwp_text_input_manager_v3", 1, 2, text_input_manager_requests, 0, NULL,
};
static const struct wl_message text_input_requests[] = {
    { "destroy", "", text_input_types + 0 },
    { "enable", "", text_input_types + 0 },
    { "disable", "", text_input_types + 0 },
    { "set_surrounding_text", "sii", text_input_types + 0 },
    { "set_text_change_cause", "u", text_input_types + 0 },
    { "set_content_type", "uu", text_input_types + 0 },
    { "set_cursor_rectangle", "iiii", text_input_types + 0 },
    { "commit", "", text_input_types + 0 },
};
static const struct wl_message text_input_events[] = {
    { "enter", "o", text_input_types + 6 },
    { "leave", "o", text_input_types + 6 },
    { "preedit_string", "?sii", text_input_types + 0 },
    { "commit_string", "?s", text_input_types + 0 },
    { "delete_surrounding_text", "uu", text_input_types + 0 },
    { "done", "u", text_input_types + 0 },
};
static const struct wl_interface text_input_interface = {
    "zwp_text_input_v3", 1, 8, text_input_requests, 6, text_input_events,
};
enum { TEXT_INPUT_MANAGER_GET = 1 };
enum { TEXT_INPUT_ENABLE = 1, TEXT_INPUT_DISABLE = 2, TEXT_INPUT_SET_CURSOR_RECTANGLE = 6, TEXT_INPUT_COMMIT = 7 };

static void ime_send_rect(void) {
    wl_proxy_marshal_flags(w.text_input, TEXT_INPUT_SET_CURSOR_RECTANGLE, NULL, 1, 0, w.ime_rect[0], w.ime_rect[1],
                           w.ime_rect[2], w.ime_rect[3]);
}

static void ti_enter(void* d, struct wl_proxy* ti, struct wl_surface* s) {
    (void)d; (void)s;
    w.ime_entered = 1;
    wl_proxy_marshal_flags(ti, TEXT_INPUT_ENABLE, NULL, 1, 0);
    ime_send_rect();
    wl_proxy_marshal_flags(ti, TEXT_INPUT_COMMIT, NULL, 1, 0);
}
static void ti_leave(void* d, struct wl_proxy* ti, struct wl_surface* s) {
    (void)d; (void)s;
    w.ime_entered = 0;
    wl_proxy_marshal_flags(ti, TEXT_INPUT_DISABLE, NULL, 1, 0);
    wl_proxy_marshal_flags(ti, TEXT_INPUT_COMMIT, NULL, 1, 0);
    // A composition does not survive the focus.
    if (w.l->ime_preedit) w.l->ime_preedit(w.data, "", 0, 0);
}
static void ti_preedit(void* d, struct wl_proxy* ti, const char* text, int32_t begin, int32_t end) {
    (void)d; (void)ti;
    free(w.ime_preedit);
    w.ime_preedit = text ? strdup(text) : NULL;
    w.ime_preedit_begin = begin;
    w.ime_preedit_end = end;
}
static void ti_commit(void* d, struct wl_proxy* ti, const char* text) {
    (void)d; (void)ti;
    free(w.ime_commit);
    w.ime_commit = text ? strdup(text) : NULL;
}
static void ti_delete(void* d, struct wl_proxy* ti, uint32_t before, uint32_t after) {
    (void)d; (void)ti; (void)before; (void)after;
}
// `done` applies what came since the last one: the commit first, then the
// preedit that replaces the one before it (none sent: none left). A bare
// `done` is how an input method cancels its composition, so it must clear
// the preedit too.
static void ti_done(void* d, struct wl_proxy* ti, uint32_t serial) {
    (void)d; (void)ti; (void)serial;
    char* commit = w.ime_commit;
    char* preedit = w.ime_preedit;
    w.ime_commit = NULL;
    w.ime_preedit = NULL;
    if (commit && w.l->ime_commit) w.l->ime_commit(w.data, commit);
    if (w.l->ime_preedit) w.l->ime_preedit(w.data, preedit ? preedit : "", w.ime_preedit_begin, w.ime_preedit_end);
    free(commit);
    free(preedit);
}
static const struct {
    void (*enter)(void*, struct wl_proxy*, struct wl_surface*);
    void (*leave)(void*, struct wl_proxy*, struct wl_surface*);
    void (*preedit)(void*, struct wl_proxy*, const char*, int32_t, int32_t);
    void (*commit)(void*, struct wl_proxy*, const char*);
    void (*delete_surrounding)(void*, struct wl_proxy*, uint32_t, uint32_t);
    void (*done)(void*, struct wl_proxy*, uint32_t);
} text_input_listener = { ti_enter, ti_leave, ti_preedit, ti_commit, ti_delete, ti_done };

static void text_input_create(void) {
    if (!w.text_input_manager || !w.seat || w.text_input) return;
    w.text_input = wl_proxy_marshal_flags(w.text_input_manager, TEXT_INPUT_MANAGER_GET, &text_input_interface, 1, 0,
                                          NULL, w.seat);
    wl_proxy_add_listener(w.text_input, (void (**)(void))&text_input_listener, NULL);
}

// Drops the composition: text-input-v3 has no reset, but an input method
// starts over when its text input is disabled and enabled again.
void zwl_ime_reset(void) {
    if (!w.text_input || !w.ime_entered) return;
    wl_proxy_marshal_flags(w.text_input, TEXT_INPUT_DISABLE, NULL, 1, 0);
    wl_proxy_marshal_flags(w.text_input, TEXT_INPUT_COMMIT, NULL, 1, 0);
    wl_proxy_marshal_flags(w.text_input, TEXT_INPUT_ENABLE, NULL, 1, 0);
    ime_send_rect();
    wl_proxy_marshal_flags(w.text_input, TEXT_INPUT_COMMIT, NULL, 1, 0);
    wl_display_flush(w.display);
}

void zwl_ime_cursor(int32_t x, int32_t y, int32_t width, int32_t height) {
    if (w.ime_rect[0] == x && w.ime_rect[1] == y && w.ime_rect[2] == width && w.ime_rect[3] == height) return;
    w.ime_rect[0] = x;
    w.ime_rect[1] = y;
    w.ime_rect[2] = width;
    w.ime_rect[3] = height;
    if (!w.text_input || !w.ime_entered) return;
    ime_send_rect();
    wl_proxy_marshal_flags(w.text_input, TEXT_INPUT_COMMIT, NULL, 1, 0);
}

static void seat_capabilities(void* d, struct wl_seat* seat, uint32_t caps) {
    (void)d;
    if ((caps & WL_SEAT_CAPABILITY_POINTER) && !w.pointer) {
        w.pointer = wl_seat_get_pointer(seat);
        wl_pointer_add_listener(w.pointer, &pointer_listener, NULL);
    }
    if ((caps & WL_SEAT_CAPABILITY_KEYBOARD) && !w.keyboard) {
        w.keyboard = wl_seat_get_keyboard(seat);
        wl_keyboard_add_listener(w.keyboard, &keyboard_listener, NULL);
    }
}
static void seat_name(void* d, struct wl_seat* seat, const char* name) { (void)d; (void)seat; (void)name; }
static const struct wl_seat_listener seat_listener = { seat_capabilities, seat_name };

// ---------------------------------------------------------------------------
// Registry
// ---------------------------------------------------------------------------

static void wm_base_ping(void* d, struct wl_proxy* base, uint32_t serial) {
    (void)d;
    wl_proxy_marshal_flags(base, XDG_WM_BASE_PONG, NULL, 1, 0, serial);
}
static const struct { void (*ping)(void*, struct wl_proxy*, uint32_t); } wm_base_listener = { wm_base_ping };

static void on_global(void* d, struct wl_registry* reg, uint32_t name, const char* iface, uint32_t version) {
    (void)d;
    if (strcmp(iface, wl_compositor_interface.name) == 0) {
        w.compositor = wl_registry_bind(reg, name, &wl_compositor_interface, version < 4 ? version : 4);
    } else if (strcmp(iface, xdg_wm_base_interface.name) == 0) {
        w.wm_base = wl_registry_bind(reg, name, &xdg_wm_base_interface, version < 2 ? version : 2);
        wl_proxy_add_listener(w.wm_base, (void (**)(void))&wm_base_listener, NULL);
    } else if (strcmp(iface, wl_seat_interface.name) == 0 && !w.seat) {
        // 5: pointer events come in frames, a wheel's notches with them.
        if (version < 5) return;
        w.seat = wl_registry_bind(reg, name, &wl_seat_interface, 5);
        wl_seat_add_listener(w.seat, &seat_listener, NULL);
    } else if (strcmp(iface, "zxdg_decoration_manager_v1") == 0) {
        w.decoration_manager = wl_registry_bind(reg, name, &decoration_manager_interface, 1);
    } else if (strcmp(iface, text_input_manager_interface.name) == 0) {
        w.text_input_manager = wl_registry_bind(reg, name, &text_input_manager_interface, 1);
    } else if (strcmp(iface, wl_data_device_manager_interface.name) == 0) {
        w.data_manager = wl_registry_bind(reg, name, &wl_data_device_manager_interface, version < 3 ? version : 3);
    } else if (strcmp(iface, primary_manager_interface.name) == 0) {
        w.primary_manager = wl_registry_bind(reg, name, &primary_manager_interface, 1);
    } else if (strcmp(iface, wl_shm_interface.name) == 0) {
        w.shm = wl_registry_bind(reg, name, &wl_shm_interface, 1);
    } else if (strcmp(iface, cursor_shape_manager_interface.name) == 0) {
        w.cursor_shape_manager = wl_registry_bind(reg, name, &cursor_shape_manager_interface, 1);
    } else if (strcmp(iface, activation_interface.name) == 0) {
        w.activation = wl_registry_bind(reg, name, &activation_interface, 1);
    } else if (strcmp(iface, wl_output_interface.name) == 0 && w.n_outputs < MAX_OUTPUTS && version >= 2) {
        const int i = w.n_outputs++;
        w.outputs[i] = wl_registry_bind(reg, name, &wl_output_interface, 2);
        w.output_scale[i] = 1;
        wl_output_add_listener(w.outputs[i], &output_listener, NULL);
    }
}
static void on_global_remove(void* d, struct wl_registry* reg, uint32_t name) { (void)d; (void)reg; (void)name; }
static const struct wl_registry_listener registry_listener = { on_global, on_global_remove };

int zwl_open(const zwl_listener* l, void* data) {
    w.l = l;
    w.data = data;
    w.repeat_rate = 25;
    w.repeat_delay = 600;
    w.display = wl_display_connect(NULL);
    if (!w.display) return -1;
    w.xkb = xkb_context_new(XKB_CONTEXT_NO_FLAGS);
    w.registry = wl_display_get_registry(w.display);
    wl_registry_add_listener(w.registry, &registry_listener, NULL);
    // The globals, then what binding them sends back (output scales, the
    // seat's capabilities).
    if (wl_display_roundtrip(w.display) < 0) return -1;
    if (wl_display_roundtrip(w.display) < 0) return -1;
    if (!w.compositor || !w.wm_base) return -1;
    selection_devices();
    text_input_create();
    return 0;
}

int zwl_fd(void) { return wl_display_get_fd(w.display); }

// ---------------------------------------------------------------------------
// The window
// ---------------------------------------------------------------------------

static void toplevel_configure(void* d, struct wl_proxy* t, int32_t width, int32_t height, struct wl_array* states) {
    (void)d; (void)t;
    w.pending_w = width;
    w.pending_h = height;
    w.pending_placed = 0;
    w.pending_maximized = 0;
    // 1 maximized, 2 fullscreen, 5..8 tiled on an edge.
    const uint32_t* st;
    wl_array_for_each(st, states) {
        if (*st == 1 || *st == 2 || (*st >= 5 && *st <= 8)) w.pending_placed = 1;
        if (*st == 1) w.pending_maximized = 1;
    }
}
static void toplevel_close(void* d, struct wl_proxy* t) {
    (void)d; (void)t;
    if (w.l->close) w.l->close(w.data);
}
static const struct {
    void (*configure)(void*, struct wl_proxy*, int32_t, int32_t, struct wl_array*);
    void (*close)(void*, struct wl_proxy*);
} toplevel_listener = { toplevel_configure, toplevel_close };

static void xdg_surface_configure(void* d, struct wl_proxy* s, uint32_t serial) {
    (void)d;
    wl_proxy_marshal_flags(s, XDG_SURFACE_ACK_CONFIGURE, NULL, 1, 0, serial);
    w.placed = w.pending_placed;
    w.maximized = w.pending_maximized;
    if (w.l->configure) w.l->configure(w.data, w.pending_w, w.pending_h);
}
static const struct { void (*configure)(void*, struct wl_proxy*, uint32_t); } xdg_surface_listener = {
    xdg_surface_configure,
};

// xdg-decoration-unstable-v1, written out as the scanner would: the
// compositor is asked to draw the title bar. One that has no such protocol
// (GNOME) leaves the window bare.
static const struct wl_interface toplevel_decoration_interface;
static const struct wl_interface* decoration_types[] = {
    NULL,
    &toplevel_decoration_interface, &xdg_toplevel_interface,
};
static const struct wl_message decoration_manager_requests[] = {
    { "destroy", "", decoration_types + 0 },
    { "get_toplevel_decoration", "no", decoration_types + 1 },
};
static const struct wl_interface decoration_manager_interface = {
    "zxdg_decoration_manager_v1", 1, 2, decoration_manager_requests, 0, NULL,
};
static const struct wl_message toplevel_decoration_requests[] = {
    { "destroy", "", decoration_types + 0 },
    { "set_mode", "u", decoration_types + 0 },
    { "unset_mode", "", decoration_types + 0 },
};
static const struct wl_message toplevel_decoration_events[] = {
    { "configure", "u", decoration_types + 0 },
};
static const struct wl_interface toplevel_decoration_interface = {
    "zxdg_toplevel_decoration_v1", 1, 3, toplevel_decoration_requests, 1, toplevel_decoration_events,
};
static void decoration_configure(void* d, struct wl_proxy* dec, uint32_t mode) { (void)d; (void)dec; (void)mode; }
static const struct { void (*configure)(void*, struct wl_proxy*, uint32_t); } decoration_listener = {
    decoration_configure,
};

int zwl_placed(void) { return w.placed; }
int zwl_maximized(void) { return w.maximized; }
int zwl_server_decorations(void) { return w.decoration_manager != NULL; }

// xdg_toplevel requests the frontend's own title bar makes: the compositor
// takes the pointer over for a move or a resize (`edge`: xdg_toplevel's
// resize_edge), started by the button press last seen.
void zwl_move(void) {
    if (w.toplevel && w.seat) wl_proxy_marshal_flags(w.toplevel, 5, NULL, 1, 0, w.seat, w.button_serial);
}
void zwl_resize(uint32_t edge) {
    if (w.toplevel && w.seat) wl_proxy_marshal_flags(w.toplevel, 6, NULL, 1, 0, w.seat, w.button_serial, edge);
}
void zwl_toggle_maximize(void) {
    if (w.toplevel) wl_proxy_marshal_flags(w.toplevel, w.maximized ? 10 : 9, NULL, 1, 0);
}
void zwl_minimize(void) {
    if (w.toplevel) wl_proxy_marshal_flags(w.toplevel, 13, NULL, 1, 0);
}

void* zonvie_wl_blur_surface(struct wl_surface* surface, struct wl_compositor* compositor);
int zonvie_wl_blur_init(struct wl_display* display);

// Asks the compositor to blur what shows through the window (wl_blur.c).
void zwl_blur(void) {
    if (zonvie_wl_blur_init(w.display) != 0) zonvie_wl_blur_surface(w.surface, w.compositor);
}

// Gives the surface its toplevel role and commits it without a buffer: the
// compositor answers with a configure.
static void make_toplevel(const char* app_id, const char* title) {
    w.xdg_surface = wl_proxy_marshal_flags(w.wm_base, XDG_WM_BASE_GET_XDG_SURFACE, &xdg_surface_interface, 1, 0, NULL,
                                           w.surface);
    wl_proxy_add_listener(w.xdg_surface, (void (**)(void))&xdg_surface_listener, NULL);
    w.toplevel = wl_proxy_marshal_flags(w.xdg_surface, XDG_SURFACE_GET_TOPLEVEL, &xdg_toplevel_interface, 1, 0, NULL);
    wl_proxy_add_listener(w.toplevel, (void (**)(void))&toplevel_listener, NULL);
    wl_proxy_marshal_flags(w.toplevel, XDG_TOPLEVEL_SET_APP_ID, NULL, 1, 0, app_id);
    wl_proxy_marshal_flags(w.toplevel, XDG_TOPLEVEL_SET_TITLE, NULL, 1, 0, title);
    // No decoration object: the compositor leaves the title bar to the client.
    if (w.decoration_manager && w.server_decorations) {
        w.decoration = wl_proxy_marshal_flags(w.decoration_manager, 1, &toplevel_decoration_interface, 1, 0, NULL,
                                              w.toplevel);
        wl_proxy_add_listener(w.decoration, (void (**)(void))&decoration_listener, NULL);
        // 2: server-side.
        wl_proxy_marshal_flags(w.decoration, 1, NULL, 1, 0, 2);
    }
    wl_surface_commit(w.surface);
    wl_display_flush(w.display);
}

int zwl_window(const char* app_id, const char* title, int server_decorations) {
    w.surface = wl_compositor_create_surface(w.compositor);
    if (!w.surface) return -1;
    w.server_decorations = server_decorations;
    make_toplevel(app_id, title);
    return 0;
}

void zwl_set_title(const char* title) {
    if (w.toplevel) wl_proxy_marshal_flags(w.toplevel, XDG_TOPLEVEL_SET_TITLE, NULL, 1, 0, title);
}

void zwl_set_buffer_scale(int32_t scale) {
    if (w.surface) wl_surface_set_buffer_scale(w.surface, scale);
}

static void frame_done(void* d, struct wl_callback* cb, uint32_t time) {
    (void)d; (void)time;
    wl_callback_destroy(cb);
    w.frame = NULL;
    if (w.l->frame) w.l->frame(w.data);
}
static const struct wl_callback_listener frame_listener = { frame_done };

void zwl_request_frame(void) {
    if (w.frame || !w.surface) return;
    w.frame = wl_surface_frame(w.surface);
    wl_callback_add_listener(w.frame, &frame_listener, NULL);
}

int zwl_frame_pending(void) { return w.frame != NULL; }

// Unmaps the window: its toplevel role is given up and the buffer taken
// off. No frame callback comes for a surface that is not shown.
void zwl_hide(void) {
    if (!w.toplevel) return;
    if (w.frame) {
        wl_callback_destroy(w.frame);
        w.frame = NULL;
    }
    // Opcode 0 is destroy in each of the three interfaces.
    if (w.decoration) wl_proxy_marshal_flags(w.decoration, 0, NULL, 1, WL_MARSHAL_FLAG_DESTROY);
    wl_proxy_marshal_flags(w.toplevel, 0, NULL, 1, WL_MARSHAL_FLAG_DESTROY);
    wl_proxy_marshal_flags(w.xdg_surface, 0, NULL, 1, WL_MARSHAL_FLAG_DESTROY);
    w.decoration = NULL;
    w.toplevel = NULL;
    w.xdg_surface = NULL;
    wl_surface_attach(w.surface, NULL, 0, 0);
    wl_surface_commit(w.surface);
    wl_display_flush(w.display);
}

// Maps it again: a new toplevel, whose first configure the buffer follows.
void zwl_show(const char* app_id, const char* title) {
    if (w.toplevel || !w.surface) return;
    make_toplevel(app_id, title);
}

// ---------------------------------------------------------------------------
// EGL
// ---------------------------------------------------------------------------

int zwl_egl_init(int32_t w_px, int32_t h_px) {
    w.egl_display = eglGetDisplay((EGLNativeDisplayType)w.display);
    if (w.egl_display == EGL_NO_DISPLAY) return -1;
    if (!eglInitialize(w.egl_display, NULL, NULL)) return -1;
    if (!eglBindAPI(EGL_OPENGL_API)) return -1;
    const EGLint config_attribs[] = {
        EGL_SURFACE_TYPE, EGL_WINDOW_BIT,
        EGL_RENDERABLE_TYPE, EGL_OPENGL_BIT,
        EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8, EGL_BLUE_SIZE, 8, EGL_ALPHA_SIZE, 8,
        EGL_NONE,
    };
    EGLint n = 0;
    if (!eglChooseConfig(w.egl_display, config_attribs, &w.egl_config, 1, &n) || n < 1) return -1;
    const EGLint context_attribs[] = {
        EGL_CONTEXT_MAJOR_VERSION, 3,
        EGL_CONTEXT_MINOR_VERSION, 3,
        EGL_CONTEXT_OPENGL_PROFILE_MASK, EGL_CONTEXT_OPENGL_CORE_PROFILE_BIT,
        EGL_NONE,
    };
    w.egl_context = eglCreateContext(w.egl_display, w.egl_config, EGL_NO_CONTEXT, context_attribs);
    if (w.egl_context == EGL_NO_CONTEXT) return -1;
    w.egl_window = wl_egl_window_create(w.surface, w_px, h_px);
    if (!w.egl_window) return -1;
    w.egl_w_px = w_px;
    w.egl_h_px = h_px;
    w.egl_surface = eglCreateWindowSurface(w.egl_display, w.egl_config, (EGLNativeWindowType)w.egl_window, NULL);
    if (w.egl_surface == EGL_NO_SURFACE) return -1;
    if (!eglMakeCurrent(w.egl_display, w.egl_surface, w.egl_surface, w.egl_context)) return -1;
    // Frames are paced by the surface's frame callback, never by a swap that
    // blocks the loop.
    eglSwapInterval(w.egl_display, 0);
    const char* exts = eglQueryString(w.egl_display, EGL_EXTENSIONS);
    if (exts && strstr(exts, "EGL_EXT_buffer_age")) {
        if (strstr(exts, "EGL_KHR_swap_buffers_with_damage"))
            w.swap_with_damage = (PFNEGLSWAPBUFFERSWITHDAMAGEKHRPROC)eglGetProcAddress("eglSwapBuffersWithDamageKHR");
        else if (strstr(exts, "EGL_EXT_swap_buffers_with_damage"))
            w.swap_with_damage = (PFNEGLSWAPBUFFERSWITHDAMAGEKHRPROC)eglGetProcAddress("eglSwapBuffersWithDamageEXT");
        w.has_buffer_age = w.swap_with_damage != NULL;
    }
    return 0;
}

void zwl_egl_resize(int32_t w_px, int32_t h_px) {
    if (!w.egl_window) return;
    wl_egl_window_resize(w.egl_window, w_px, h_px, 0, 0);
    w.egl_w_px = w_px;
    w.egl_h_px = h_px;
}

int zwl_buffer_stale(void) {
    // Only a buffer age query takes the back buffer, which the size below
    // then is; without one it is the size the next buffer will get.
    if (!w.has_buffer_age) return 0;
    EGLint bw = 0, bh = 0;
    if (!eglQuerySurface(w.egl_display, w.egl_surface, EGL_WIDTH, &bw) ||
        !eglQuerySurface(w.egl_display, w.egl_surface, EGL_HEIGHT, &bh))
        return 0;
    return bw != w.egl_w_px || bh != w.egl_h_px;
}

int zwl_swap(void) {
    return eglSwapBuffers(w.egl_display, w.egl_surface) ? 0 : -1;
}

int zwl_buffer_age(void) {
    if (!w.has_buffer_age) return 0;
    EGLint age = 0;
    if (!eglQuerySurface(w.egl_display, w.egl_surface, EGL_BUFFER_AGE_EXT, &age)) return 0;
    return age;
}

int zwl_swap_damage(const int32_t* rects, int32_t n) {
    if (!w.swap_with_damage || n <= 0) return zwl_swap();
    return w.swap_with_damage(w.egl_display, w.egl_surface, (EGLint*)rects, n) ? 0 : -1;
}

// ---------------------------------------------------------------------------
// External windows
// ---------------------------------------------------------------------------

static void ext_toplevel_configure(void* d, struct wl_proxy* t, int32_t width, int32_t height, struct wl_array* states) {
    (void)t;
    struct zwl_ext* e = d;
    e->pending_w = width;
    e->pending_h = height;
    e->pending_placed = 0;
    // As toplevel_configure: 1 maximized, 2 fullscreen, 5..8 tiled on an edge.
    const uint32_t* st;
    wl_array_for_each(st, states) {
        if (*st == 1 || *st == 2 || (*st >= 5 && *st <= 8)) e->pending_placed = 1;
    }
}
static void ext_toplevel_close(void* d, struct wl_proxy* t) {
    (void)t;
    struct zwl_ext* e = d;
    if (w.l->ext_close) w.l->ext_close(w.data, e->id);
}
static const struct {
    void (*configure)(void*, struct wl_proxy*, int32_t, int32_t, struct wl_array*);
    void (*close)(void*, struct wl_proxy*);
} ext_toplevel_listener = { ext_toplevel_configure, ext_toplevel_close };

static void ext_surface_configure(void* d, struct wl_proxy* s, uint32_t serial) {
    struct zwl_ext* e = d;
    wl_proxy_marshal_flags(s, XDG_SURFACE_ACK_CONFIGURE, NULL, 1, 0, serial);
    e->placed = e->pending_placed;
    if (w.l->ext_configure) w.l->ext_configure(w.data, e->id, e->pending_w, e->pending_h);
}
static const struct { void (*configure)(void*, struct wl_proxy*, uint32_t); } ext_surface_listener = {
    ext_surface_configure,
};

static void ext_frame_done(void* d, struct wl_callback* cb, uint32_t time) {
    (void)time;
    struct zwl_ext* e = d;
    wl_callback_destroy(cb);
    e->frame = NULL;
    if (w.l->ext_frame) w.l->ext_frame(w.data, e->id);
}
static const struct wl_callback_listener ext_frame_listener = { ext_frame_done };

int zwl_ext_open(int64_t id, const char* app_id, const char* title, int32_t w_px, int32_t h_px, int32_t scale) {
    if (!id || ext_of_id(id) || w.egl_context == EGL_NO_CONTEXT) return -1;
    struct zwl_ext* e = NULL;
    for (int i = 0; i < MAX_EXT && !e; i++) if (!w.ext[i].id) e = &w.ext[i];
    if (!e) return -1;
    memset(e, 0, sizeof *e);
    e->surface = wl_compositor_create_surface(w.compositor);
    if (!e->surface) return -1;
    wl_surface_set_buffer_scale(e->surface, scale);
    e->egl_window = wl_egl_window_create(e->surface, w_px, h_px);
    e->egl_surface = e->egl_window
        ? eglCreateWindowSurface(w.egl_display, w.egl_config, (EGLNativeWindowType)e->egl_window, NULL)
        : EGL_NO_SURFACE;
    if (e->egl_surface == EGL_NO_SURFACE) {
        if (e->egl_window) wl_egl_window_destroy(e->egl_window);
        wl_surface_destroy(e->surface);
        return -1;
    }
    e->id = id;
    e->xdg_surface = wl_proxy_marshal_flags(w.wm_base, XDG_WM_BASE_GET_XDG_SURFACE, &xdg_surface_interface, 1, 0, NULL,
                                            e->surface);
    wl_proxy_add_listener(e->xdg_surface, (void (**)(void))&ext_surface_listener, e);
    e->toplevel = wl_proxy_marshal_flags(e->xdg_surface, XDG_SURFACE_GET_TOPLEVEL, &xdg_toplevel_interface, 1, 0, NULL);
    wl_proxy_add_listener(e->toplevel, (void (**)(void))&ext_toplevel_listener, e);
    wl_proxy_marshal_flags(e->toplevel, XDG_TOPLEVEL_SET_APP_ID, NULL, 1, 0, app_id);
    wl_proxy_marshal_flags(e->toplevel, XDG_TOPLEVEL_SET_TITLE, NULL, 1, 0, title);
    // The desktop's title bar where it draws one: these windows have no
    // header of their own.
    if (w.decoration_manager) {
        e->decoration = wl_proxy_marshal_flags(w.decoration_manager, 1, &toplevel_decoration_interface, 1, 0, NULL,
                                               e->toplevel);
        wl_proxy_add_listener(e->decoration, (void (**)(void))&decoration_listener, NULL);
        wl_proxy_marshal_flags(e->decoration, 1, NULL, 1, 0, 2);
    }
    wl_surface_commit(e->surface);
    wl_display_flush(w.display);
    return 0;
}

static void popup_configure(void* d, struct wl_proxy* p, int32_t x, int32_t y, int32_t width, int32_t height) {
    (void)p; (void)x; (void)y;
    struct zwl_ext* e = d;
    e->pending_w = width;
    e->pending_h = height;
}
static void popup_done(void* d, struct wl_proxy* p) {
    (void)p;
    struct zwl_ext* e = d;
    if (w.l->ext_close) w.l->ext_close(w.data, e->id);
}
static const struct {
    void (*configure)(void*, struct wl_proxy*, int32_t, int32_t, int32_t, int32_t);
    void (*popup_done)(void*, struct wl_proxy*);
} popup_listener = { popup_configure, popup_done };

int zwl_popup_open(int64_t id, int64_t parent_id, int32_t x, int32_t y, int32_t w_logical, int32_t h_logical,
                   int32_t anchor_x, int32_t anchor_y, int32_t scale) {
    if (!id || ext_of_id(id) || w.egl_context == EGL_NO_CONTEXT) return -1;
    struct zwl_ext* parent = ext_of_id(parent_id);
    struct wl_proxy* parent_surface = parent ? parent->xdg_surface : w.xdg_surface;
    if (!parent_surface || (parent_id && !parent)) return -1;
    struct zwl_ext* e = NULL;
    for (int i = 0; i < MAX_EXT && !e; i++) if (!w.ext[i].id) e = &w.ext[i];
    if (!e) return -1;
    memset(e, 0, sizeof *e);
    e->surface = wl_compositor_create_surface(w.compositor);
    if (!e->surface) return -1;
    wl_surface_set_buffer_scale(e->surface, scale);
    e->egl_window = wl_egl_window_create(e->surface, w_logical * scale, h_logical * scale);
    e->egl_surface = e->egl_window
        ? eglCreateWindowSurface(w.egl_display, w.egl_config, (EGLNativeWindowType)e->egl_window, NULL)
        : EGL_NO_SURFACE;
    if (e->egl_surface == EGL_NO_SURFACE) {
        if (e->egl_window) wl_egl_window_destroy(e->egl_window);
        wl_surface_destroy(e->surface);
        return -1;
    }
    e->id = id;
    // The popup's top-left goes (x, y) from the parent's: the anchor is a
    // point inside the parent, as the positioner wants, and the offset
    // carries the rest. Past an output's edge the compositor slides it.
    struct wl_proxy* pos = wl_proxy_marshal_flags(w.wm_base, XDG_WM_BASE_CREATE_POSITIONER, &xdg_positioner_interface,
                                                  1, 0, NULL);
    wl_proxy_marshal_flags(pos, 1, NULL, 1, 0, w_logical, h_logical);
    wl_proxy_marshal_flags(pos, 2, NULL, 1, 0, anchor_x, anchor_y, 1, 1);
    wl_proxy_marshal_flags(pos, 3, NULL, 1, 0, 5); // anchor: top_left
    wl_proxy_marshal_flags(pos, 4, NULL, 1, 0, 8); // gravity: bottom_right
    wl_proxy_marshal_flags(pos, 5, NULL, 1, 0, 1 | 2); // slide_x | slide_y
    wl_proxy_marshal_flags(pos, 6, NULL, 1, 0, x - anchor_x, y - anchor_y);
    e->xdg_surface = wl_proxy_marshal_flags(w.wm_base, XDG_WM_BASE_GET_XDG_SURFACE, &xdg_surface_interface, 1, 0, NULL,
                                            e->surface);
    wl_proxy_add_listener(e->xdg_surface, (void (**)(void))&ext_surface_listener, e);
    e->popup = wl_proxy_marshal_flags(e->xdg_surface, XDG_SURFACE_GET_POPUP, &xdg_popup_interface, 1, 0, NULL,
                                      parent_surface, pos);
    wl_proxy_add_listener(e->popup, (void (**)(void))&popup_listener, e);
    wl_proxy_marshal_flags(pos, 0, NULL, 1, WL_MARSHAL_FLAG_DESTROY);
    // No input region for keys: a popup without a grab never has the focus.
    wl_surface_commit(e->surface);
    wl_display_flush(w.display);
    return 0;
}

void zwl_ext_close(int64_t id) {
    struct zwl_ext* e = ext_of_id(id);
    if (!e) return;
    if (w.kb_surface == e->surface) w.kb_surface = NULL;
    // The surface GL draws to goes with the window: back to the main one.
    eglMakeCurrent(w.egl_display, w.egl_surface, w.egl_surface, w.egl_context);
    if (e->frame) wl_callback_destroy(e->frame);
    eglDestroySurface(w.egl_display, e->egl_surface);
    wl_egl_window_destroy(e->egl_window);
    if (e->decoration) wl_proxy_marshal_flags(e->decoration, 0, NULL, 1, WL_MARSHAL_FLAG_DESTROY);
    if (e->toplevel) wl_proxy_marshal_flags(e->toplevel, 0, NULL, 1, WL_MARSHAL_FLAG_DESTROY);
    if (e->popup) wl_proxy_marshal_flags(e->popup, 0, NULL, 1, WL_MARSHAL_FLAG_DESTROY);
    wl_proxy_marshal_flags(e->xdg_surface, 0, NULL, 1, WL_MARSHAL_FLAG_DESTROY);
    wl_surface_destroy(e->surface);
    e->id = 0;
    wl_display_flush(w.display);
}

void zwl_ext_resize(int64_t id, int32_t w_px, int32_t h_px) {
    struct zwl_ext* e = ext_of_id(id);
    if (e) wl_egl_window_resize(e->egl_window, w_px, h_px, 0, 0);
}

int zwl_ext_placed(int64_t id) {
    struct zwl_ext* e = ext_of_id(id);
    return e ? e->placed : 0;
}

// The token for zwl_activate: window `d` (1, or an external window's id)
// asks for the keyboard with it, if it is still there.
static void activation_token_done(void* d, struct wl_proxy* tok, const char* token) {
    const int64_t id = (int64_t)(intptr_t)d;
    struct zwl_ext* e = id == 1 ? NULL : ext_of_id(id);
    struct wl_surface* s = id == 1 ? w.surface : e ? e->surface : NULL;
    if (s) wl_proxy_marshal_flags(w.activation, ACTIVATION_ACTIVATE, NULL, 1, 0, token, s);
    wl_proxy_marshal_flags(tok, ACTIVATION_TOKEN_DESTROY, NULL, 1, WL_MARSHAL_FLAG_DESTROY);
    wl_display_flush(w.display);
}
static const struct { void (*done)(void*, struct wl_proxy*, const char*); } activation_token_listener = {
    activation_token_done,
};

int zwl_activate(int64_t id) {
    if (!w.activation || (id != 1 && !ext_of_id(id))) return -1;
    struct wl_proxy* tok = wl_proxy_marshal_flags(w.activation, ACTIVATION_GET_TOKEN, &activation_token_interface, 1, 0,
                                                  NULL);
    if (!tok) return -1;
    wl_proxy_add_listener(tok, (void (**)(void))&activation_token_listener, (void*)(intptr_t)id);
    // The input that moved the cursor, on the surface that had the keyboard:
    // what a compositor checks before it hands the keyboard over.
    if (w.input_serial && w.seat)
        wl_proxy_marshal_flags(tok, ACTIVATION_TOKEN_SET_SERIAL, NULL, 1, 0, w.input_serial, w.seat);
    if (w.kb_surface) wl_proxy_marshal_flags(tok, ACTIVATION_TOKEN_SET_SURFACE, NULL, 1, 0, w.kb_surface);
    wl_proxy_marshal_flags(tok, ACTIVATION_TOKEN_COMMIT, NULL, 1, 0);
    wl_display_flush(w.display);
    return 0;
}

int zwl_ext_make_current(int64_t id) {
    struct zwl_ext* e = ext_of_id(id);
    EGLSurface s = e ? e->egl_surface : w.egl_surface;
    if (id && !e) return -1;
    if (!eglMakeCurrent(w.egl_display, s, s, w.egl_context)) return -1;
    // As the main surface (zwl_egl_init): paced by its frame callback, never
    // by a swap that blocks the loop. The interval is the current surface's
    // own and starts at one, where a swap waits for the last frame to be
    // shown: forever, on a window no output shows.
    if (e && !e->swap_unpaced) {
        eglSwapInterval(w.egl_display, 0);
        e->swap_unpaced = 1;
    }
    return 0;
}

int zwl_ext_swap(int64_t id) {
    struct zwl_ext* e = ext_of_id(id);
    if (!e) return -1;
    return eglSwapBuffers(w.egl_display, e->egl_surface) ? 0 : -1;
}

void zwl_ext_request_frame(int64_t id) {
    struct zwl_ext* e = ext_of_id(id);
    if (!e || e->frame) return;
    e->frame = wl_surface_frame(e->surface);
    wl_callback_add_listener(e->frame, &ext_frame_listener, e);
}

int zwl_ext_frame_pending(int64_t id) {
    struct zwl_ext* e = ext_of_id(id);
    return e && e->frame != NULL;
}

// ---------------------------------------------------------------------------
// Event pump
// ---------------------------------------------------------------------------

// Reads what the socket has and dispatches it. Called when the socket is
// readable, it never waits: what was read may hold nothing for this queue
// (an event for EGL's queue, a delete_id), and wl_display_dispatch would
// then sleep until something for it came.
int zwl_dispatch(void) {
    while (wl_display_prepare_read(w.display) != 0) {
        if (wl_display_dispatch_pending(w.display) < 0) return -1;
    }
    wl_display_flush(w.display);
    if (wl_display_read_events(w.display) < 0) return -1;
    return wl_display_dispatch_pending(w.display);
}
int zwl_dispatch_pending(void) { return wl_display_dispatch_pending(w.display); }
int zwl_flush(void) { return wl_display_flush(w.display); }
