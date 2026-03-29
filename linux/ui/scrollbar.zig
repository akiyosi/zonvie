// scrollbar.zig — Custom GL-rendered scrollbar overlay for Linux frontend.
//
// GL-rendered overlay matching Windows/macOS visual style.
// Uses viewport info from zonvie_core_get_viewport to compute knob position.

const std = @import("std");
const app_mod = @import("../app.zig");

pub const ScrollbarState = struct {
    visible: bool = false,
    alpha: f32 = 0.7,
    knob_top: f32 = 0.0,
    knob_height: f32 = 0.1,
    dragging: bool = false,
    drag_start_y: f32 = 0.0,
    drag_start_knob_top: f32 = 0.0,
    topline: i64 = 1,
    botline: i64 = 1,
    linecount: i64 = 1,

    /// Update knob geometry from viewport info
    pub fn updateFromViewport(self: *ScrollbarState, vp: app_mod.ViewportInfo) void {
        self.topline = vp.topline;
        self.botline = vp.botline;
        self.linecount = vp.line_count;

        if (vp.line_count <= 0) {
            self.knob_top = 0.0;
            self.knob_height = 1.0;
            return;
        }

        const total: f32 = @floatFromInt(@max(1, vp.line_count));
        const top: f32 = @floatFromInt(@max(0, vp.topline - 1));
        const visible_lines: f32 = @floatFromInt(@max(1, vp.botline - vp.topline + 1));

        self.knob_top = top / total;
        self.knob_height = @max(0.02, visible_lines / total);
    }
};
