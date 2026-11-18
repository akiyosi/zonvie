//! The seams the modules that face the core cross (callbacks.zig, app.zig,
//! renderer/gl_renderer.zig, scrollbar.zig) to reach the window and what is
//! drawn around the editor:
//!
//! - `window`: main.zig's entry points, where they ask the window itself for
//!   something: a frame, frames while a grid eases, a selection, the end of
//!   the loop. Through the root module, so the tests (another root) never
//!   pull the window in.
//! - the namespaces below it: calls forwarded to main.zig, shell.zig and
//!   pointer.zig, resolved only where they are made.

const std = @import("std");
const core = @import("zonvie_core");
const App = @import("app.zig").App;
const pointer = @import("pointer.zig");

pub const window = @import("root");

pub const ext_window = @import("ext_window.zig");
pub const panel_popup = @import("panel_popup.zig");
pub const blink = @import("blink.zig");
pub const font_picker = @import("font_picker.zig");
pub const tray = @import("tray.zig");
pub const notify = @import("notify.zig");
pub const chrome = @import("chrome.zig");

pub const input = struct {
    pub const Pointer = pointer.Pointer;
    pub fn refreshPanelHover(app: *App) void {
        pointer.refreshPanelHover(app);
    }
    /// main.zig's own.
    pub fn updateImeCursor(app: *App) void {
        @import("root").updateImeCursor(app);
    }
};

/// shell.zig's rebuilds, as the core-facing modules ask for them.
pub const shell = struct {
    /// Neovim has drawn: the start's progress text goes (shell.zig draws it).
    pub fn hideProgress(app: *App) void {
        if (app.progress.len == 0) return;
        app.progress = "";
        @import("shell.zig").rebuild(app, true);
    }
    /// After a flush: the labels follow the cursor's window, and the frame
    /// the flush queues draws them (shell.zig).
    pub fn placeMessages(app: *App) void {
        @import("shell.zig").rebuild(app, false);
    }
    pub fn queueRefresh(app: *App) void {
        @import("shell.zig").queueRefresh(app);
    }
};

pub const window_size = struct {
    /// main.zig's own.
    pub fn queueSnap(app: *App) void {
        @import("root").queueSnap(app);
    }
    pub fn resizeToGrid(app: *App, rows: u32, cols: u32) void {
        @import("root").resizeToGrid(app, rows, cols);
    }
};

pub const ime_off = struct {
    /// main.zig's own.
    pub fn off() void {
        @import("root").imeOff();
    }
};

pub const session = struct {
    /// main.zig's own.
    pub fn applyTitle(app: *App, title: []const u8) void {
        @import("root").setTitle(app, title);
    }
    /// A remote start that ended before its first frame: what the process
    /// printed goes to stderr and into a report window, and the caller
    /// quits as for any exit.
    pub fn failEarlyExit(app: *App, exit_code: i32) bool {
        const lifecycle = @import("lifecycle.zig");
        if (app.nvim_ready) return false;
        const heading = lifecycle.earlyExitHeading(app.start_kind) orelse return false;
        app.start_output.open.store(false, .release);
        var out_buf: [4096]u8 = undefined;
        const out = app.start_output.copy(core.clock.io(), &out_buf);
        var detail_buf: [1024]u8 = undefined;
        const detail = lifecycle.earlyExitDetail(&detail_buf, out, exit_code);
        std.debug.print("zonvie: {s}: {s}\n", .{ heading, detail });
        var text: [1200]u8 = undefined;
        if (std.fmt.bufPrintZ(&text, "{s}\n\n{s}", .{ heading, detail })) |t| @import("crash.zig").showReport(t) else |_| {}
        return false;
    }
    pub fn onReady(app: *App) void {
        @import("session.zig").onReady(app);
    }
};
