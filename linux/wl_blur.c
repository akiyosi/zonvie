// Compositor blur behind a window through ext-background-effect-v1, the
// Wayland protocol a compositor offers to blur what lies behind a surface
// (as macOS's NSVisualEffectView and Windows' DWM backdrop do). The build
// has no wayland-scanner step, so the two interfaces are written out here as
// the scanner would emit them from ext-background-effect-v1.xml.

#include <stdint.h>
#include <stddef.h>
#include <string.h>
#include <stdlib.h>
#include <wayland-client.h>

extern const struct wl_interface ext_background_effect_surface_v1_interface;

static const struct wl_interface* blur_types[] = {
    NULL,
    &ext_background_effect_surface_v1_interface,
    &wl_surface_interface,
    &wl_region_interface,
};

static const struct wl_message manager_requests[] = {
    { "destroy", "", blur_types + 0 },
    { "get_background_effect", "no", blur_types + 1 },
};

static const struct wl_message manager_events[] = {
    { "capabilities", "u", blur_types + 0 },
};

const struct wl_interface ext_background_effect_manager_v1_interface = {
    "ext_background_effect_manager_v1", 1, 2, manager_requests, 1, manager_events,
};

static const struct wl_message surface_requests[] = {
    { "destroy", "", blur_types + 0 },
    { "set_blur_region", "?o", blur_types + 3 },
};

const struct wl_interface ext_background_effect_surface_v1_interface = {
    "ext_background_effect_surface_v1", 1, 2, surface_requests, 0, NULL,
};

// The capability bit for blur (ext_background_effect_manager_v1.capability).
#define CAPABILITY_BLUR 1u

static struct wl_proxy* manager;
static uint32_t capabilities;

static void on_global(void* data, struct wl_registry* reg, uint32_t name, const char* iface, uint32_t version) {
    (void)data;
    (void)version;
    if (strcmp(iface, ext_background_effect_manager_v1_interface.name) != 0) return;
    manager = wl_registry_bind(reg, name, &ext_background_effect_manager_v1_interface, 1);
}

static void on_global_remove(void* data, struct wl_registry* reg, uint32_t name) {
    (void)data;
    (void)reg;
    (void)name;
}

static const struct wl_registry_listener registry_listener = { on_global, on_global_remove };

static void on_capabilities(void* data, struct wl_proxy* mgr, uint32_t flags) {
    (void)data;
    (void)mgr;
    capabilities = flags;
}

static const struct { void (*capabilities)(void*, struct wl_proxy*, uint32_t); } manager_listener = { on_capabilities };

int zonvie_wl_blur_init(struct wl_display* display) {
    if (manager) return (capabilities & CAPABILITY_BLUR) != 0;
    // A private queue: GDK dispatches the default one, and these events must
    // be read here, now.
    struct wl_event_queue* queue = wl_display_create_queue(display);
    if (!queue) return 0;
    struct wl_display* wrapped = wl_proxy_create_wrapper(display);
    if (!wrapped) {
        wl_event_queue_destroy(queue);
        return 0;
    }
    wl_proxy_set_queue((struct wl_proxy*)wrapped, queue);
    struct wl_registry* reg = wl_display_get_registry(wrapped);
    wl_registry_add_listener(reg, &registry_listener, NULL);
    wl_display_roundtrip_queue(display, queue);
    if (manager) {
        wl_proxy_add_listener(manager, (void (**)(void))&manager_listener, NULL);
        // The capabilities event follows the bind.
        wl_display_roundtrip_queue(display, queue);
        // Back on the default queue, which GDK dispatches, before this
        // queue goes: a later capabilities event still updates the bits.
        wl_proxy_set_queue(manager, NULL);
    }
    wl_registry_destroy(reg);
    wl_proxy_wrapper_destroy(wrapped);
    wl_event_queue_destroy(queue);
    return manager && (capabilities & CAPABILITY_BLUR) != 0;
}

void* zonvie_wl_blur_surface(struct wl_surface* surface, struct wl_compositor* compositor) {
    if (!manager || !(capabilities & CAPABILITY_BLUR)) return NULL;
    struct wl_proxy* effect = wl_proxy_marshal_flags(manager, 1, &ext_background_effect_surface_v1_interface,
                                                     wl_proxy_get_version(manager), 0, NULL, surface);
    if (!effect) return NULL;
    // The whole surface: the region is clipped to it.
    struct wl_region* region = wl_compositor_create_region(compositor);
    wl_region_add(region, 0, 0, INT32_MAX, INT32_MAX);
    wl_proxy_marshal_flags(effect, 1, NULL, wl_proxy_get_version(effect), 0, region);
    wl_region_destroy(region);
    // Applied with the surface's next commit, which the next frame makes.
    return effect;
}

void zonvie_wl_blur_release(void* effect) {
    if (!effect) return;
    wl_proxy_marshal_flags((struct wl_proxy*)effect, 0, NULL, wl_proxy_get_version((struct wl_proxy*)effect),
                           WL_MARSHAL_FLAG_DESTROY);
}

// A wl_display.sync whose done arrives after the compositor has handled
// every request sent before it, and after every event it sent until then:
// the boundary between pointer events relative to a popup's old position
// and those relative to its new one (linux/panel_popup.zig).

struct zonvie_sync {
    void (*done)(void*);
    void* data;
};

static void on_sync_done(void* data, struct wl_callback* cb, uint32_t serial) {
    (void)serial;
    struct zonvie_sync* s = data;
    wl_callback_destroy(cb);
    s->done(s->data);
    free(s);
}

static const struct wl_callback_listener sync_listener = { on_sync_done };

int zonvie_wl_sync(struct wl_display* display, void (*done)(void*), void* data) {
    struct zonvie_sync* s = malloc(sizeof *s);
    if (!s) return 0;
    s->done = done;
    s->data = data;
    struct wl_callback* cb = wl_display_sync(display);
    if (!cb) {
        free(s);
        return 0;
    }
    wl_callback_add_listener(cb, &sync_listener, s);
    wl_display_flush(display);
    return 1;
}
