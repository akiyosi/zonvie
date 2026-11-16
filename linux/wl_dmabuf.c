// The editor's frames on a Wayland subsurface of their own: the render
// thread (linux/render_thread.zig) attaches each dmabuf it draws and
// commits it at once, desynchronized from the window, so a frame reaches
// the compositor without waiting for GTK's frame cycle. The subsurface
// sits below the window's surface, which leaves the view clear for it.
// Also the dmabuf modifiers the compositor imports, from
// zwp_linux_dmabuf_v1: a buffer it does not take may cost the connection.
// As in wl_blur.c, the dmabuf interfaces are written out as
// wayland-scanner would emit them.

#include <stdint.h>
#include <stddef.h>
#include <string.h>
#include <stdlib.h>
#include <poll.h>
#include <wayland-client.h>

// Version 3: the last where the compositor lists modifiers as events on
// bind (version 4 moves them into a shared-memory feedback table).
extern const struct wl_interface zonvie_buffer_params_interface;

static const struct wl_interface* dmabuf_types[] = {
    NULL,
    NULL,
    NULL,
    NULL,
    NULL,
    NULL,
    &zonvie_buffer_params_interface,
    &wl_buffer_interface,
    NULL,
    NULL,
    NULL,
    NULL,
};

static const struct wl_message params_requests[] = {
    { "destroy", "", dmabuf_types + 0 },
    { "add", "huuuuu", dmabuf_types + 0 },
    { "create", "iiuu", dmabuf_types + 0 },
    { "create_immed", "2niiuu", dmabuf_types + 7 },
};

static const struct wl_message params_events[] = {
    { "created", "n", dmabuf_types + 7 },
    { "failed", "", dmabuf_types + 0 },
};

const struct wl_interface zonvie_buffer_params_interface = {
    "zwp_linux_buffer_params_v1", 3, 4, params_requests, 2, params_events,
};

static const struct wl_message dmabuf_requests[] = {
    { "destroy", "", dmabuf_types + 0 },
    { "create_params", "n", dmabuf_types + 6 },
};

static const struct wl_message dmabuf_events[] = {
    { "format", "u", dmabuf_types + 0 },
    { "modifier", "3uuu", dmabuf_types + 0 },
};

static const struct wl_interface dmabuf_interface = {
    "zwp_linux_dmabuf_v1", 3, 2, dmabuf_requests, 2, dmabuf_events,
};

// DRM_FORMAT_MOD_INVALID: the buffer's layout is the driver's own business
// (an implicit modifier), which a compositor on the same driver imports.
#define MOD_INVALID 0x00ffffffffffffffull

struct query {
    struct wl_proxy* dmabuf;
    uint32_t fourcc;
    uint64_t* out;
    int cap;
    int len;
    int implicit;
};

static void on_global(void* data, struct wl_registry* reg, uint32_t name, const char* iface, uint32_t version) {
    struct query* q = data;
    if (q->dmabuf || version < 3 || strcmp(iface, dmabuf_interface.name) != 0) return;
    q->dmabuf = wl_registry_bind(reg, name, &dmabuf_interface, 3);
}

static void on_global_remove(void* data, struct wl_registry* reg, uint32_t name) {
    (void)data;
    (void)reg;
    (void)name;
}

static const struct wl_registry_listener registry_listener = { on_global, on_global_remove };

// A format listed with no modifier is imported with an implicit one.
static void on_format(void* data, struct wl_proxy* dmabuf, uint32_t format) {
    (void)dmabuf;
    struct query* q = data;
    if (format == q->fourcc) q->implicit = 1;
}

static void on_modifier(void* data, struct wl_proxy* dmabuf, uint32_t format, uint32_t hi, uint32_t lo) {
    (void)dmabuf;
    struct query* q = data;
    uint64_t modifier = ((uint64_t)hi << 32) | lo;
    if (format != q->fourcc) return;
    if (modifier == MOD_INVALID)
        q->implicit = 1;
    else if (q->len < q->cap)
        q->out[q->len++] = modifier;
}

static const struct {
    void (*format)(void*, struct wl_proxy*, uint32_t);
    void (*modifier)(void*, struct wl_proxy*, uint32_t, uint32_t, uint32_t);
} dmabuf_listener = { on_format, on_modifier };

// The explicit modifiers the compositor imports `fourcc` with, into `out`
// (at most `cap`); returns how many. `*implicit` is set when it also
// imports the format with an implicit modifier.
int zonvie_wl_dmabuf_modifiers(struct wl_display* display, uint32_t fourcc, uint64_t* out, int cap, int* implicit) {
    struct query q = { NULL, fourcc, out, cap, 0, 0 };
    *implicit = 0;
    // A private queue: GDK dispatches the default one, and these events
    // must be read here, now.
    struct wl_event_queue* queue = wl_display_create_queue(display);
    if (!queue) return 0;
    struct wl_display* wrapped = wl_proxy_create_wrapper(display);
    if (!wrapped) {
        wl_event_queue_destroy(queue);
        return 0;
    }
    wl_proxy_set_queue((struct wl_proxy*)wrapped, queue);
    struct wl_registry* reg = wl_display_get_registry(wrapped);
    wl_registry_add_listener(reg, &registry_listener, &q);
    wl_display_roundtrip_queue(display, queue);
    if (q.dmabuf) {
        wl_proxy_add_listener(q.dmabuf, (void (**)(void))&dmabuf_listener, &q);
        // The modifier events follow the bind.
        wl_display_roundtrip_queue(display, queue);
        wl_proxy_marshal_flags(q.dmabuf, 0, NULL, wl_proxy_get_version(q.dmabuf), WL_MARSHAL_FLAG_DESTROY);
    }
    wl_registry_destroy(reg);
    wl_proxy_wrapper_destroy(wrapped);
    wl_event_queue_destroy(queue);
    *implicit = q.implicit;
    return q.len;
}

// ---------------------------------------------------------------------------
// The subsurface.

struct zonvie_frames {
    struct wl_display* display;
    struct wl_event_queue* queue;
    struct wl_proxy* dmabuf;
    struct wl_subcompositor* subcompositor;
    struct wl_surface* surface;
    struct wl_subsurface* subsurface;
};

static void frames_global(void* data, struct wl_registry* reg, uint32_t name, const char* iface, uint32_t version) {
    struct zonvie_frames* f = data;
    if (!f->dmabuf && version >= 3 && strcmp(iface, dmabuf_interface.name) == 0)
        f->dmabuf = wl_registry_bind(reg, name, &dmabuf_interface, 3);
    else if (!f->subcompositor && strcmp(iface, wl_subcompositor_interface.name) == 0)
        f->subcompositor = wl_registry_bind(reg, name, &wl_subcompositor_interface, 1);
}

static const struct wl_registry_listener frames_registry_listener = { frames_global, on_global_remove };

void zonvie_wl_frames_destroy(struct zonvie_frames* f);

// A subsurface below `parent`, on a queue of its own (the render thread
// dispatches it; GDK the default one). NULL when the compositor lacks
// what it needs.
struct zonvie_frames* zonvie_wl_frames_create(struct wl_display* display, struct wl_compositor* compositor, struct wl_surface* parent) {
    struct zonvie_frames* f = calloc(1, sizeof *f);
    if (!f) return NULL;
    f->display = display;
    f->queue = wl_display_create_queue(display);
    struct wl_display* wrapped = f->queue ? wl_proxy_create_wrapper(display) : NULL;
    if (!wrapped) {
        zonvie_wl_frames_destroy(f);
        return NULL;
    }
    wl_proxy_set_queue((struct wl_proxy*)wrapped, f->queue);
    struct wl_registry* reg = wl_display_get_registry(wrapped);
    wl_registry_add_listener(reg, &frames_registry_listener, f);
    wl_display_roundtrip_queue(display, f->queue);
    wl_registry_destroy(reg);
    wl_proxy_wrapper_destroy(wrapped);
    struct wl_compositor* comp = f->dmabuf && f->subcompositor ? wl_proxy_create_wrapper(compositor) : NULL;
    if (!comp) {
        zonvie_wl_frames_destroy(f);
        return NULL;
    }
    wl_proxy_set_queue((struct wl_proxy*)comp, f->queue);
    f->surface = wl_compositor_create_surface(comp);
    // Input goes to the window above it.
    struct wl_region* none = wl_compositor_create_region(comp);
    wl_surface_set_input_region(f->surface, none);
    wl_region_destroy(none);
    wl_proxy_wrapper_destroy(comp);
    f->subsurface = wl_subcompositor_get_subsurface(f->subcompositor, f->surface, parent);
    wl_subsurface_place_below(f->subsurface, parent);
    wl_subsurface_set_desync(f->subsurface);
    wl_display_flush(display);
    return f;
}

void zonvie_wl_frames_destroy(struct zonvie_frames* f) {
    if (!f) return;
    if (f->subsurface) wl_subsurface_destroy(f->subsurface);
    if (f->surface) wl_surface_destroy(f->surface);
    if (f->subcompositor) wl_subcompositor_destroy(f->subcompositor);
    if (f->dmabuf) wl_proxy_marshal_flags(f->dmabuf, 0, NULL, wl_proxy_get_version(f->dmabuf), WL_MARSHAL_FLAG_DESTROY);
    if (f->display) wl_display_flush(f->display);
    if (f->queue) wl_event_queue_destroy(f->queue);
    free(f);
}

// The parent's next commit (GTK's) moves the subsurface there, in the
// parent's surface coordinates.
void zonvie_wl_frames_position(struct zonvie_frames* f, int32_t x, int32_t y) {
    wl_subsurface_set_position(f->subsurface, x, y);
    wl_display_flush(f->display);
}

struct import {
    struct wl_buffer* buffer;
    int done;
};

static void params_created(void* data, struct wl_proxy* params, struct wl_buffer* buffer) {
    (void)params;
    struct import* i = data;
    i->buffer = buffer;
    i->done = 1;
}

static void params_failed(void* data, struct wl_proxy* params) {
    (void)params;
    struct import* i = data;
    i->done = 1;
}

static const struct {
    void (*created)(void*, struct wl_proxy*, struct wl_buffer*);
    void (*failed)(void*, struct wl_proxy*);
} params_listener = { params_created, params_failed };

static void (*release_fn)(void*);

static void buffer_release(void* data, struct wl_buffer* buffer) {
    (void)buffer;
    release_fn(data);
}

static const struct wl_buffer_listener buffer_listener = { buffer_release };

// A wl_buffer of the dmabuf, or NULL when the compositor refuses it.
// `release(data)` runs, on the thread dispatching the queue, whenever the
// compositor is done with the buffer. A modifier of DRM_FORMAT_MOD_INVALID
// is the implicit one. The asynchronous create: a refusal is an event,
// where create_immed may make it a protocol error.
struct wl_buffer* zonvie_wl_frames_buffer(struct zonvie_frames* f, int fd, uint32_t w, uint32_t h, uint32_t stride, uint32_t offset,
                                          uint64_t modifier, uint32_t fourcc, void (*release)(void*), void* data) {
    struct wl_proxy* params = wl_proxy_marshal_flags(f->dmabuf, 1, &zonvie_buffer_params_interface, wl_proxy_get_version(f->dmabuf), 0, NULL);
    if (!params) return NULL;
    struct import i = { NULL, 0 };
    wl_proxy_add_listener(params, (void (**)(void))&params_listener, &i);
    wl_proxy_marshal_flags(params, 1, NULL, wl_proxy_get_version(params), 0, fd, 0u, offset, stride, (uint32_t)(modifier >> 32),
                           (uint32_t)modifier);
    wl_proxy_marshal_flags(params, 2, NULL, wl_proxy_get_version(params), 0, (int32_t)w, (int32_t)h, fourcc, 0u);
    while (!i.done)
        if (wl_display_dispatch_queue(f->display, f->queue) < 0) break;
    wl_proxy_marshal_flags(params, 0, NULL, wl_proxy_get_version(params), WL_MARSHAL_FLAG_DESTROY);
    if (i.buffer) {
        release_fn = release;
        wl_buffer_add_listener(i.buffer, &buffer_listener, data);
    }
    return i.buffer;
}

void zonvie_wl_frames_destroy_buffer(struct wl_buffer* buffer) {
    wl_buffer_destroy(buffer);
}

// Shows `buffer`, of `scale` buffer px per surface px, now.
void zonvie_wl_frames_present(struct zonvie_frames* f, struct wl_buffer* buffer, int32_t scale) {
    wl_surface_attach(f->surface, buffer, 0, 0);
    wl_surface_set_buffer_scale(f->surface, scale);
    wl_surface_damage_buffer(f->surface, 0, 0, INT32_MAX, INT32_MAX);
    wl_surface_commit(f->surface);
    wl_display_flush(f->display);
}

// Dispatches the queue's events (buffer releases), waiting at most
// `timeout_ms` for some to arrive when none is queued. The number
// dispatched; -1 on a broken connection.
int zonvie_wl_frames_dispatch(struct zonvie_frames* f, int timeout_ms) {
    int n = 0;
    while (wl_display_prepare_read_queue(f->display, f->queue) != 0) {
        int r = wl_display_dispatch_queue_pending(f->display, f->queue);
        if (r < 0) return -1;
        n += r;
    }
    if (n > 0) {
        wl_display_cancel_read(f->display);
        return n;
    }
    wl_display_flush(f->display);
    struct pollfd p = { wl_display_get_fd(f->display), POLLIN, 0 };
    if (poll(&p, 1, timeout_ms) > 0) {
        if (wl_display_read_events(f->display) < 0) return -1;
    } else {
        wl_display_cancel_read(f->display);
    }
    return wl_display_dispatch_queue_pending(f->display, f->queue);
}
