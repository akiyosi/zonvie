// messages.zig — ext_messages UI for Linux frontend.
//
// Floating message overlays with configurable routing.
//
// TODO: Implement message rendering:
// - Floating overlay windows for messages (ext-float view)
// - Mini message bar at bottom (mini view)
// - Message history split view
// - Auto-hide with timeout via g_timeout_add
// - Configurable routing per message type

const std = @import("std");
const app_mod = @import("../app.zig");

pub const MessageState = struct {
    visible: bool = false,
    // TODO: message content, routing state
};
