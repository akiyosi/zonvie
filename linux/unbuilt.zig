//! What this frontend has not built yet. The modules that face the core
//! (callbacks.zig, app.zig, renderer/gl_renderer.zig) were written against a
//! toolkit that drew these pieces; they still call them, through ui.zig, and
//! each name here is that call's other end.
//!
//! - A function that does nothing is a feature that does not exist: external
//!   windows, the tab line, panels in their own surfaces, the tray,
//!   notifications, a font dialog, an overlay for the IME's composition.
//!   Building the feature is writing the function.
//! - A type holds the state the callers keep for such a piece, cut down to
//!   the fields they read.

const std = @import("std");
const core = @import("zonvie_core");
const App = @import("app.zig").App;
const scrollbar = @import("scrollbar.zig");
const pointer = @import("pointer.zig");

pub const input = struct {
    pub const Pointer = pointer.Pointer;
    /// A panel under a pointer that did not move (ext UI panels take no
    /// pointer yet).
    pub fn refreshPanelHover(_: *App) void {}
    /// main.zig's own.
    pub fn updateImeCursor(app: *App) void {
        @import("root").updateImeCursor(app);
    }
};

pub const ui_widgets = struct {
    /// The widgets over the editor: none.
    pub const Widgets = struct {};
    pub const SnapshotStorage = struct {};
    /// A font the IME's composition would be drawn in: family and logical px.
    pub const PreeditFont = struct {
        family: [128]u8 = undefined,
        family_len: usize = 0,
        /// 0: no font.
        px: f32 = 0,

        /// `family` (cut to 128 bytes) at `pixel_size` device px on a `scale`
        /// display. Pre: scale > 0.
        pub fn of(family: []const u8, pixel_size: u32, scale: f32) PreeditFont {
            std.debug.assert(scale > 0);
            var f: PreeditFont = .{ .family_len = @min(family.len, 128), .px = @as(f32, @floatFromInt(pixel_size)) / scale };
            @memcpy(f.family[0..f.family_len], family[0..f.family_len]);
            return f;
        }
    };
    pub fn hideProgress(_: *App) void {}
    pub fn placeCopyButtons(_: *App) void {}
    pub fn placeMessages(_: *App) void {}
    pub fn queueRefresh(_: *App) void {}
};

pub const ext_window = struct {
    /// An external grid's own OS window: none is ever opened.
    pub const ExtWindow = struct {
        area: ?*anyopaque = null,
        scrollbar: scrollbar.State = .{},
    };
    pub const Op = struct {
        kind: enum { open, close, layout },
        grid_id: i64 = 0,
        /// The Neovim window handle, which names the OS window ("Window N").
        win: i64 = 0,
        rows: u32 = 0,
        cols: u32 = 0,
        /// on_external_window's global cell, -1 for none.
        start_row: i32 = -1,
        start_col: i32 = -1,
        /// `.layout`: a win_move / win_exchange / win_rotate / win_resize_equal
        /// for win_layout.plan, from the window showing `source_grid` (null:
        /// the main window).
        layout_op: core.win_layout.Op = .move,
        arg: i32 = 0,
        count: i32 = 0,
        source_grid: ?i64 = null,
    };
    pub fn findWindow(_: *App, _: i64, _: i32, _: i32, main_win: i64) i64 {
        return main_win;
    }
    pub fn focusGrid(_: *App, _: i64) void {}
    pub fn queueApply(_: *App) void {}
    pub fn queueRefit(_: *App) void {}
};

pub const panel_popup = struct {
    /// A panel in a popup surface of its own: panels are drawn in the main
    /// view only.
    pub const Popup = struct {};
    pub fn noteMonitor(_: *App) void {}
    pub fn queueRender(_: *App) void {}
    pub fn update(_: *App) void {}
};

pub const blink = struct {
    pub fn focusedImContext(_: *App) ?*anyopaque {
        return null;
    }
    pub fn update(_: *App) void {}
};

pub const font_picker = struct {
    /// `:set guifont=*`: no font dialog.
    pub fn request(_: *App) void {}
};

pub const window_size = struct {
    /// The window follows a grid size Neovim asks for: not yet.
    pub fn queueSnap(_: *App) void {}
    pub fn resizeToGrid(_: *App, _: u32, _: u32) void {}
    /// main.zig saves the size itself, when its loop ends.
    pub fn save(_: *App) void {}
};

pub const ime_off = struct {
    /// main.zig's own.
    pub fn off(_: ?*anyopaque) void {
        @import("root").imeOff();
    }
};

pub const session = struct {
    /// main.zig's own.
    pub fn applyTitle(app: *App, title: []const u8) void {
        @import("root").setTitle(app, title);
    }
    /// A remote start that ended before its first frame: no alert, the
    /// reason is on stderr.
    pub fn failEarlyExit(_: *App, _: i32) bool {
        return false;
    }
    pub fn onReady(_: *App) void {}
};

pub const render_thread = struct {
    /// A thread that presents by itself, off the window's frame cycle: none.
    pub const RenderThread = struct {
        animating: std.atomic.Value(bool) = .init(false),
        pub fn request(_: *RenderThread) void {}
    };
    pub fn idlePresent(_: ?*anyopaque) callconv(.c) c_int {
        return 0;
    }
};

pub const tray = struct {
    pub const Tray = struct {};
};

pub const notify = struct {
    pub const State = struct {};
};
