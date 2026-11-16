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
pub const ext_window = unbuilt.ext_window;
pub const panel_popup = unbuilt.panel_popup;
pub const blink = unbuilt.blink;
pub const font_picker = unbuilt.font_picker;
pub const window_size = unbuilt.window_size;
pub const ime_off = unbuilt.ime_off;
pub const session = unbuilt.session;
pub const render_thread = unbuilt.render_thread;
pub const tray = unbuilt.tray;
pub const notify = unbuilt.notify;
pub const chrome = @import("chrome.zig");
