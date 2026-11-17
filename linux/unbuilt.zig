//! The other end of calls the core-facing modules (callbacks.zig, app.zig,
//! renderer/gl_renderer.zig) make through ui.zig for pieces that are main.zig's
//! or shell.zig's own here.

const std = @import("std");
const core = @import("zonvie_core");
const App = @import("app.zig").App;
const pointer = @import("pointer.zig");

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

pub const ui_widgets = struct {
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
