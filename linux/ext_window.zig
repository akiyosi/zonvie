//! `--extwindows`: each external grid in an OS window of its own, a further
//! toplevel of this client drawn with the main window's GL context
//! (wl/window.c zwl_ext_*). Main thread, except queueApply, queueRefit and
//! findWindow.
//!
//! What Wayland leaves out: a client neither reads nor sets where its
//! windows are, so the window-layout operations (`<C-w>H`, `<C-w>x`, ...)
//! and the move of the cursor to the window in a direction have nothing to
//! work with, and a window cannot raise itself.

const std = @import("std");
const core = @import("zonvie_core");
const clock = core.clock;
const App = @import("app.zig").App;
const glib = @import("glib.zig");
const gl_renderer = @import("renderer/gl_renderer.zig");
const postfx = @import("renderer/postfx.zig");
const pointer = @import("pointer.zig");
const applog = @import("app_log.zig");
const scrollbar = @import("scrollbar.zig");
const win_layout = core.win_layout;

extern "c" fn zwl_ext_open(id: i64, app_id: [*:0]const u8, title: [*:0]const u8, w_px: i32, h_px: i32, scale: i32) c_int;
extern "c" fn zwl_ext_close(id: i64) void;
extern "c" fn zwl_ext_resize(id: i64, w_px: i32, h_px: i32) void;
extern "c" fn zwl_ext_make_current(id: i64) c_int;
extern "c" fn zwl_ext_swap(id: i64) c_int;
extern "c" fn zwl_ext_request_frame(id: i64) void;
extern "c" fn zwl_ext_frame_pending(id: i64) c_int;
extern "c" fn zwl_dispatch_pending() c_int;
extern "c" fn zwl_flush() c_int;

const app_id = "io.github.akiyosi.zonvie";

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
    /// from the window showing `source_grid` (null: the main window).
    layout_op: win_layout.Op = .move,
    arg: i32 = 0,
    count: i32 = 0,
    source_grid: ?i64 = null,
};

pub const ExtWindow = struct {
    app: *App,
    grid_id: i64,
    gl: gl_renderer.Target = .{},
    postfx: postfx.PostFx = .{},
    pointer: pointer.Pointer,
    scrollbar: scrollbar.State = .{},
    /// The grid's size as the core last opened or updated it.
    rows: u32,
    cols: u32,
    /// The Neovim window handle.
    win: i64,
    /// The size its buffer is drawn at, device px.
    w_px: u32 = 0,
    h_px: u32 = 0,
    /// A configure arrived, so a buffer may be attached.
    configured: bool = false,
    realized: bool = false,
    /// A change waits for the frame callback of the frame before it.
    dirty: bool = false,
    /// Placeholder for the callers that test for a widget (scrollbar.zig).
    area: ?*anyopaque = null,
};

/// The window the pointer is in, null for the main one (main.zig routes the
/// pointer by it).
pub var pointer_target: ?*ExtWindow = null;

/// Callable from any thread; at most one idle is outstanding.
pub fn queueApply(app: *App) void {
    if (app.ext_idle_queued.swap(true, .acq_rel)) return;
    _ = glib.g_idle_add(&idleApply, app);
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
        // No window positions on Wayland: nothing to arrange.
        .layout => {},
    };
    return 0;
}

/// The cell `grid_id` is laid out in: its own font's when it has one
/// (on_grid_font), else the global cell.
fn cellPx(app: *App, grid_id: i64) struct { w: u32, h: u32, scale: f32 } {
    app.mu.lockUncancelable(clock.io());
    defer app.mu.unlock(clock.io());
    if (app.surface.gridFont(grid_id)) |f| return .{ .w = f.cell_w_px, .h = f.cell_h_px, .scale = app.scale };
    return .{ .w = app.cell_w_px, .h = app.cell_h_px, .scale = app.scale };
}

/// Device px for a grid of rows x cols in the grid's own cell, with the
/// "column" scrollbar's strip beside it, rounded up to whole logical px.
fn sizePx(app: *App, grid_id: i64, rows: u32, cols: u32) [2]u32 {
    const c = cellPx(app, grid_id);
    const s: u32 = @max(1, @as(u32, @intFromFloat(c.scale)));
    const strip = scrollbar.columnStripPx(app.scrollbar_cfg, c.scale);
    const w = cols * c.w + strip;
    const h = rows * c.h;
    return .{ (w + s - 1) / s * s, (h + s - 1) / s * s };
}

fn open(app: *App, op: Op) void {
    if (app.ext_windows.get(op.grid_id)) |w| {
        w.win = op.win;
        // A repeat is an update of the same window: follow a size Neovim
        // chose (a :resize), which the window did not ask for.
        if (w.rows != op.rows or w.cols != op.cols) {
            w.rows = op.rows;
            w.cols = op.cols;
            const sz = sizePx(app, op.grid_id, op.rows, op.cols);
            setSize(w, sz[0], sz[1]);
            if (w.configured) draw(w);
        }
        return;
    }
    const w = app.alloc.create(ExtWindow) catch return;
    w.* = .{ .app = app, .grid_id = op.grid_id, .rows = op.rows, .cols = op.cols, .win = op.win, .pointer = .{ .app = app, .surface_id = op.grid_id, .press_grid_id = op.grid_id } };
    const sz = sizePx(app, op.grid_id, op.rows, op.cols);
    w.w_px = sz[0];
    w.h_px = sz[1];
    // "Window N", as macOS and Windows title them.
    var title: [32]u8 = undefined;
    const t: [:0]const u8 = std.fmt.bufPrintZ(&title, "Window {d}", .{op.win}) catch "zonvie";
    const scale: i32 = @max(1, @as(i32, @intFromFloat(cellPx(app, op.grid_id).scale)));
    if (zwl_ext_open(op.grid_id, app_id, t.ptr, @intCast(sz[0]), @intCast(sz[1]), scale) != 0) {
        app.alloc.destroy(w);
        return;
    }
    app.ext_windows.put(app.alloc, op.grid_id, w) catch {
        zwl_ext_close(op.grid_id);
        app.alloc.destroy(w);
        return;
    };
    // The GUI harness's marker for a new external window (test/gui/app_log.zig).
    applog.appLog("[external_window] open gridId={d} rows={d} cols={d}\n", .{ op.grid_id, op.rows, op.cols });
}

fn close(app: *App, grid_id: i64) void {
    const kv = app.ext_windows.fetchRemove(grid_id) orelse return;
    const w = kv.value;
    if (pointer_target == w) pointer_target = null;
    @import("panel_popup.zig").surfaceClosing(app, grid_id);
    scrollbar.cancelTimers(&w.scrollbar);
    // A later window reusing this grid id starts unedited.
    app.cell_age.drop(grid_id);
    if (w.realized and zwl_ext_make_current(grid_id) == 0) {
        postfx.unrealize(&w.postfx);
        gl_renderer.unrealize(&w.gl);
    }
    // Leaves the main window's surface current.
    zwl_ext_close(grid_id);
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

fn setSize(w: *ExtWindow, w_px: u32, h_px: u32) void {
    w.w_px = w_px;
    w.h_px = h_px;
    zwl_ext_resize(w.grid_id, @intCast(w_px), @intCast(h_px));
}

/// Draws the window's surface now and leaves the main window's current.
fn draw(w: *ExtWindow) void {
    if (!w.configured or w.w_px == 0 or w.h_px == 0) return;
    if (zwl_ext_make_current(w.grid_id) != 0) return;
    defer _ = zwl_ext_make_current(0);
    if (!w.realized) {
        if (!gl_renderer.realize(&w.gl)) return;
        w.realized = true;
    }
    w.dirty = false;
    w.gl.w_px = w.w_px;
    w.gl.h_px = w.h_px;
    w.gl.fb_w_px = w.w_px;
    w.gl.fb_h_px = w.h_px;
    gl_renderer.renderExternal(w.app, &w.gl, &w.postfx, w.grid_id);
    zwl_ext_request_frame(w.grid_id);
    _ = zwl_ext_swap(w.grid_id);
    // EGL reads the socket too: what it read for this queue is dispatched.
    _ = zwl_dispatch_pending();
    _ = zwl_flush();
}

/// Something changed (a flush, a blink, an eased frame): every window
/// draws, now or at its frame callback. main.zig's queueRender.
pub fn renderAll(app: *App) void {
    var it = app.ext_windows.valueIterator();
    while (it.next()) |wp| {
        const w = wp.*;
        if (zwl_ext_frame_pending(w.grid_id) != 0) w.dirty = true else draw(w);
    }
}

/// Asks Neovim for the grid that fills the window at the current cell.
fn fit(w: *ExtWindow) void {
    const c = cellPx(w.app, w.grid_id);
    if (c.w == 0 or c.h == 0) return;
    const rows: u32 = @max(1, w.h_px / c.h);
    const cols: u32 = @max(1, scrollbar.gridWidthPx(w.app.scrollbar_cfg, w.w_px, c.scale) / c.w);
    if (rows == w.rows and cols == w.cols) return;
    const cp = w.app.corep orelse return;
    core.zonvie_core_try_resize_grid(cp, w.grid_id, rows, cols);
}

/// wl/window.c: the window was configured, logical px; 0 leaves that
/// dimension to the client.
pub fn onConfigure(app: *App, id: i64, w_logical: i32, h_logical: i32) void {
    const w = app.ext_windows.get(id) orelse return;
    const s: u32 = @max(1, @as(u32, @intFromFloat(cellPx(app, id).scale)));
    w.configured = true;
    if (w_logical > 0 and h_logical > 0) {
        // A size the compositor or the user chose asks Neovim for the grid
        // that fills it; the core answers with on_external_window.
        setSize(w, @as(u32, @intCast(w_logical)) * s, @as(u32, @intCast(h_logical)) * s);
        fit(w);
    }
    draw(w);
}

/// wl/window.c: the window goes only when Neovim confirms the close
/// (on_external_window_close).
pub fn onClose(app: *App, id: i64) void {
    const cp = app.corep orelse return;
    const sent = core.zonvie_core_request_win_close(cp, id);
    applog.appLog("[linux] ext window close requested grid={d} sent={d}\n", .{ id, sent });
}

pub fn onFrame(app: *App, id: i64) void {
    const w = app.ext_windows.get(id) orelse return;
    if (w.dirty) draw(w);
}

/// wl/window.c: the pointer entered window `id` (0: the main one).
pub fn onPointerWindow(app: *App, id: i64) void {
    pointer_target = if (id == 0) null else app.ext_windows.get(id);
}

/// Callable from any thread: the cell size changed, and every external
/// window takes the size its grid's rows and columns now need.
pub fn queueRefit(app: *App) void {
    _ = glib.g_idle_add(&idleRefit, app);
}

fn idleRefit(data: ?*anyopaque) callconv(.c) c_int {
    const app: *App = @ptrCast(@alignCast(data.?));
    var it = app.ext_windows.valueIterator();
    while (it.next()) |wp| {
        const w = wp.*;
        const sz = sizePx(app, w.grid_id, w.rows, w.cols);
        if (sz[0] == w.w_px and sz[1] == w.h_px) continue;
        setSize(w, sz[0], sz[1]);
        draw(w);
    }
    return 0;
}

/// The cursor moved to `grid_id` from another window. A Wayland client
/// cannot raise its own window: the compositor's focus stays where it is.
pub fn focusGrid(_: *App, _: i64) void {}

/// on_win_move_cursor: the Neovim window in a direction by screen geometry.
/// 0, none: Wayland gives no geometry, and Neovim then moves within its own
/// layout, as with no callback.
pub fn findWindow(_: *App, _: i64, _: i32, _: i32, _: i64) i64 {
    return 0;
}
