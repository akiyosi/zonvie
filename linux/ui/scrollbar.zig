// scrollbar.zig — Custom GL-rendered scrollbar overlay for Linux frontend.
//
// TODO: Implement scrollbar:
// - GL-rendered overlay (not native GTK scrollbar)
// - Show modes: always, hover, scroll
// - Opacity animation via g_timeout_add
// - Viewport query via zonvie_core_get_viewport
// - Knob drag for direct position control

const std = @import("std");
const app_mod = @import("../app.zig");

pub const ScrollbarState = struct {
    visible: bool = false,
    alpha: f32 = 0.0,
    knob_top: f32 = 0.0,
    knob_height: f32 = 0.0,
    dragging: bool = false,
};
