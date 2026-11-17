//! Two seams the modules that face the core cross (callbacks.zig, app.zig,
//! renderer/gl_renderer.zig, scrollbar.zig):
//!
//! - `window`: main.zig's entry points, where they ask the window itself for
//!   something: a frame, frames while a grid eases, a selection, the end of
//!   the loop. Through the root module, so the tests (another root) never
//!   pull the window in.
//! - everything else: the pieces listed in unbuilt.zig, and chrome.zig's
//!   titlebar rules.

const unbuilt = @import("unbuilt.zig");

pub const window = @import("root");

pub const input = unbuilt.input;
pub const ui_widgets = unbuilt.ui_widgets;
pub const ext_window = @import("ext_window.zig");
pub const panel_popup = @import("panel_popup.zig");
pub const blink = @import("blink.zig");
pub const font_picker = @import("font_picker.zig");
pub const window_size = unbuilt.window_size;
pub const ime_off = unbuilt.ime_off;
pub const session = unbuilt.session;
pub const tray = @import("tray.zig");
pub const notify = @import("notify.zig");
pub const chrome = @import("chrome.zig");
