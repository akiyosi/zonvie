//! ext_windows: a Neovim window the core surfaces as a window of its own
//! (on_external_window with a Neovim grid id) gets a GTK toplevel with its
//! own GLArea, drawing the surface rooted at that grid. Wayland places
//! toplevels itself, so win_pos is not honoured. The core thread queues
//! opens and closes (`Op`); the GTK thread applies them.

const std = @import("std");
const core = @import("zonvie_core");
const clock = core.clock;
const App = @import("app.zig").App;
const gtk = @import("gtk_bindings.zig");
const gl_renderer = @import("renderer/gl_renderer.zig");
const postfx = @import("renderer/postfx.zig");
const input = @import("input.zig");
const applog = @import("app_log.zig");

pub const Op = struct {
    kind: enum { open, close },
    grid_id: i64,
    rows: u32 = 0,
    cols: u32 = 0,
};

pub const ExtWindow = struct {
    app: *App,
    grid_id: i64,
    window: ?*anyopaque = null,
    area: ?*anyopaque = null,
    gl: gl_renderer.Target = .{},
    /// Its own bloom and shader chain: GL objects belong to one context.
    postfx: postfx.PostFx = .{},
    pointer: input.Pointer,
    /// The grid's size as the core last opened or updated it.
    rows: u32,
    cols: u32,
};

fn extFrom(data: ?*anyopaque) *ExtWindow {
    return @ptrCast(@alignCast(data.?));
}

/// Callable from any thread; at most one idle is outstanding.
pub fn queueApply(app: *App) void {
    if (app.ext_idle_queued.swap(true, .acq_rel)) return;
    _ = gtk.g_idle_add(&idleApply, app);
}

fn idleApply(data: ?*anyopaque) callconv(.c) c_int {
    const app: *App = @ptrCast(@alignCast(data.?));
    app.ext_idle_queued.store(false, .release);
    app.mu.lockUncancelable(clock.io());
    std.mem.swap(std.ArrayListUnmanaged(Op), &app.ext_ops, &app.ext_ops_gtk);
    app.mu.unlock(clock.io());
    defer app.ext_ops_gtk.clearRetainingCapacity();
    for (app.ext_ops_gtk.items) |op| switch (op.kind) {
        .open => open(app, op),
        .close => close(app, op.grid_id),
    };
    return 0;
}

fn cellPx(app: *App) struct { w: u32, h: u32, scale: f32 } {
    app.mu.lockUncancelable(clock.io());
    defer app.mu.unlock(clock.io());
    return .{ .w = app.cell_w_px, .h = app.cell_h_px, .scale = app.scale };
}

/// Logical px for a grid of rows x cols.
fn logicalSize(app: *App, rows: u32, cols: u32) [2]c_int {
    const c = cellPx(app);
    return .{
        @intFromFloat(@ceil(@as(f32, @floatFromInt(cols * c.w)) / c.scale)),
        @intFromFloat(@ceil(@as(f32, @floatFromInt(rows * c.h)) / c.scale)),
    };
}

fn open(app: *App, op: Op) void {
    if (app.ext_windows.get(op.grid_id)) |w| {
        // A repeat is an update of the same window: follow a size Neovim
        // chose (a :resize), which the window did not ask for.
        if (w.rows != op.rows or w.cols != op.cols) {
            w.rows = op.rows;
            w.cols = op.cols;
            const sz = logicalSize(app, op.rows, op.cols);
            if (w.window) |win| gtk.gtk_window_set_default_size(win, sz[0], sz[1]);
        }
        return;
    }
    const w = app.alloc.create(ExtWindow) catch return;
    w.* = .{ .app = app, .grid_id = op.grid_id, .rows = op.rows, .cols = op.cols, .pointer = .{ .app = app, .surface_id = op.grid_id, .press_grid_id = op.grid_id } };
    app.ext_windows.put(app.alloc, op.grid_id, w) catch {
        app.alloc.destroy(w);
        return;
    };

    const win = gtk.gtk_window_new() orelse return;
    w.window = win;
    if (app.gtk_app) |a| gtk.gtk_window_set_application(win, a);
    gtk.gtk_window_set_title(win, "zonvie");
    const sz = logicalSize(app, op.rows, op.cols);
    gtk.gtk_window_set_default_size(win, sz[0], sz[1]);

    const area = gtk.gtk_gl_area_new() orelse return;
    w.area = area;
    gtk.gtk_gl_area_set_required_version(area, 3, 3);
    gtk.gtk_gl_area_set_has_depth_buffer(area, 0);
    gtk.gtk_gl_area_set_allowed_apis(area, gtk.GDK_GL_API_GL);
    gtk.gtk_widget_set_focusable(area, 1);
    _ = gtk.g_signal_connect(area, "realize", @ptrCast(&onRealize), w);
    _ = gtk.g_signal_connect(area, "unrealize", @ptrCast(&onUnrealize), w);
    _ = gtk.g_signal_connect(area, "render", @ptrCast(&onRender), w);
    _ = gtk.g_signal_connect(area, "resize", @ptrCast(&onResize), w);
    input.attach(&w.pointer, area);
    gtk.gtk_window_set_child(win, area);
    _ = gtk.g_signal_connect(win, "close-request", @ptrCast(&onCloseRequest), w);
    gtk.gtk_window_present(win);
    _ = gtk.gtk_widget_grab_focus(area);
    // The GUI harness's marker for a new external window (test/gui/app_log.zig).
    applog.appLog("[external_window] open gridId={d} rows={d} cols={d}\n", .{ op.grid_id, op.rows, op.cols });
}

fn close(app: *App, grid_id: i64) void {
    const kv = app.ext_windows.fetchRemove(grid_id) orelse return;
    const w = kv.value;
    // Destroying unrealizes the area, which still reads `w`.
    if (w.window) |win| gtk.gtk_window_destroy(win);
    w.gl.deinit(app.alloc);
    app.alloc.destroy(w);
    applog.appLog("[linux] ext window closed grid={d}\n", .{grid_id});
}

/// Every window still open at shutdown, before the App goes.
pub fn closeAll(app: *App) void {
    while (true) {
        var it = app.ext_windows.keyIterator();
        const id = (it.next() orelse break).*;
        close(app, id);
    }
    app.ext_windows.deinit(app.alloc);
}

fn onRealize(widget: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const w = extFrom(data);
    gtk.gtk_gl_area_make_current(widget.?);
    if (gtk.gtk_gl_area_get_error(widget.?) != null) {
        applog.appLog("[linux] ext GLArea realize error grid={d}\n", .{w.grid_id});
        return;
    }
    _ = gl_renderer.realize(&w.gl);
}

fn onUnrealize(widget: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    gtk.gtk_gl_area_make_current(widget.?);
    const w = extFrom(data);
    postfx.unrealize(&w.postfx);
    gl_renderer.unrealize(&w.gl);
}

fn onRender(area: ?*anyopaque, context: ?*anyopaque, data: ?*anyopaque) callconv(.c) c_int {
    _ = area;
    _ = context;
    const w = extFrom(data);
    gl_renderer.renderExternal(w.app, &w.gl, &w.postfx, w.grid_id);
    return 1;
}

/// `w_px`/`h_px` are device px. A size the user dragged to asks Neovim for
/// the grid that fills it; the core answers with on_external_window.
fn onResize(area: ?*anyopaque, w_px: c_int, h_px: c_int, data: ?*anyopaque) callconv(.c) void {
    _ = area;
    const w = extFrom(data);
    if (w_px <= 0 or h_px <= 0) return;
    w.gl.w_px = @intCast(w_px);
    w.gl.h_px = @intCast(h_px);
    const c = cellPx(w.app);
    if (c.w == 0 or c.h == 0) return;
    const rows: u32 = @max(1, @as(u32, @intCast(h_px)) / c.h);
    const cols: u32 = @max(1, @as(u32, @intCast(w_px)) / c.w);
    if (rows == w.rows and cols == w.cols) return;
    const cp = w.app.corep orelse return;
    core.zonvie_core_try_resize_grid(cp, w.grid_id, rows, cols);
}

/// The window goes only when Neovim confirms the close
/// (on_external_window_close): `close` owns the widgets' lifetime, so GTK is
/// never let to destroy them itself.
fn onCloseRequest(window: ?*anyopaque, data: ?*anyopaque) callconv(.c) c_int {
    _ = window;
    const w = extFrom(data);
    if (w.app.corep) |cp| {
        const sent = core.zonvie_core_request_win_close(cp, w.grid_id);
        applog.appLog("[linux] ext window close requested grid={d} sent={d}\n", .{ w.grid_id, sent });
    }
    return 1;
}
