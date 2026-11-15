//! ext_windows: a Neovim window the core surfaces as a window of its own
//! (on_external_window with a Neovim grid id) gets a GTK toplevel with its
//! own GLArea, drawing the surface rooted at that grid. Under X11 a window
//! opens at a torn-off tab's drop point, else at the cell win_pos names, and
//! `wincmd` rearranges the windows (x11_place); Wayland places toplevels
//! itself, so there neither is honoured. The core thread queues opens,
//! closes and layout operations (`Op`); the GTK thread applies them.

const std = @import("std");
const core = @import("zonvie_core");
const clock = core.clock;
const App = @import("app.zig").App;
const gtk = @import("gtk_bindings.zig");
const gl_renderer = @import("renderer/gl_renderer.zig");
const postfx = @import("renderer/postfx.zig");
const input = @import("input.zig");
const applog = @import("app_log.zig");
const blink = @import("blink.zig");
const scrollbar = @import("scrollbar.zig");
const blur = @import("blur.zig");
const chrome = @import("chrome.zig");
const panel_popup = @import("panel_popup.zig");
const ui_widgets = @import("ui_widgets.zig");
const x11_place = @import("x11_place.zig");
const win_layout = core.win_layout;

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
    layout_op: win_layout.Op = .move,
    arg: i32 = 0,
    count: i32 = 0,
    source_grid: ?i64 = null,
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
    scrollbar: scrollbar.State = .{},
    /// The grid's size as the core last opened or updated it.
    rows: u32,
    cols: u32,
    /// The Neovim window handle, what on_win_move_cursor answers.
    win: i64,
    /// The session it opened in (App.session_generation): grid ids restart
    /// with each server, so a saved origin belongs to its session.
    generation: u64 = 0,
    /// Its captionless band (titlebar_style = "hidden"), as the main window's.
    hover: chrome.Hover = .{},
    /// Where x11_place puts the window as it is first shown, root px.
    place_pos: ?[2]i32 = null,
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
        .layout => applyLayout(app, op),
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

/// Logical px for a grid of rows x cols in the grid's own cell, with the
/// "column" scrollbar's strip beside it, on a surface of `scale`: the
/// window's own, whose GLArea reports device px at it. The glyphs are the
/// one atlas's, rasterized at the main window's scale.
fn logicalSize(app: *App, grid_id: i64, rows: u32, cols: u32, scale: f32) [2]c_int {
    const c = cellPx(app, grid_id);
    const strip = scrollbar.columnStripPx(app.scrollbar_cfg, scale);
    return .{
        @intFromFloat(@ceil(@as(f32, @floatFromInt(cols * c.w + strip)) / scale)),
        @intFromFloat(@ceil(@as(f32, @floatFromInt(rows * c.h)) / scale)),
    };
}

/// The scale of `w`'s surface: its area's, once it has one; until then the
/// main window's, the closest guess for where it will open.
fn windowScale(w: *const ExtWindow) f32 {
    if (w.area) |a| if (gtk.gtk_widget_get_realized(a) != 0) return @floatFromInt(@max(1, gtk.gtk_widget_get_scale_factor(a)));
    w.app.mu.lockUncancelable(clock.io());
    defer w.app.mu.unlock(clock.io());
    return w.app.scale;
}

fn open(app: *App, op: Op) void {
    if (app.ext_windows.get(op.grid_id)) |w| {
        w.win = op.win;
        // A repeat is an update of the same window: follow a size Neovim
        // chose (a :resize), which the window did not ask for.
        if (w.rows != op.rows or w.cols != op.cols) {
            w.rows = op.rows;
            w.cols = op.cols;
            const sz = logicalSize(app, op.grid_id, op.rows, op.cols, windowScale(w));
            if (w.window) |win| gtk.gtk_window_set_default_size(win, sz[0], sz[1]);
        }
        return;
    }
    const w = app.alloc.create(ExtWindow) catch return;
    w.* = .{ .app = app, .grid_id = op.grid_id, .rows = op.rows, .cols = op.cols, .win = op.win, .generation = app.session_generation, .pointer = .{ .app = app, .surface_id = op.grid_id, .press_grid_id = op.grid_id } };
    app.ext_windows.put(app.alloc, op.grid_id, w) catch {
        app.alloc.destroy(w);
        return;
    };

    const win = gtk.gtk_window_new() orelse return;
    w.window = win;
    if (app.gtk_app) |a| gtk.gtk_window_set_application(win, a);
    if (app.translucent()) gtk.gtk_widget_add_css_class(win, "zonvie-translucent");
    if (app.window_cfg.blur) blur.watch(app, win);
    // "Window N", as macOS and Windows title them.
    var title: [32]u8 = undefined;
    const t: [:0]const u8 = std.fmt.bufPrintZ(&title, "Window {d}", .{op.win}) catch "zonvie";
    gtk.gtk_window_set_title(win, t.ptr);
    const sz = logicalSize(app, op.grid_id, op.rows, op.cols, windowScale(w));
    gtk.gtk_window_set_default_size(win, sz[0], sz[1]);
    if (x11_place.active()) {
        w.place_pos = openOrigin(app, op, sz[0]);
        if (w.place_pos != null) x11_place.placeWhenShown(win, &w.place_pos);
    }

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
    // The area under an overlay that holds its preedit label, as the main
    // window's view does, and watches the pointer over the panels drawn
    // there.
    const view = gtk.gtk_overlay_new() orelse return;
    gtk.gtk_overlay_set_child(view, area);
    input.attachPanelHover(&w.pointer, view);
    if (ui_widgets.newPreeditLabel()) |label| {
        w.pointer.preedit_label = label;
        gtk.gtk_overlay_add_overlay(view, label);
    }
    gtk.gtk_window_set_child(win, chrome.decorateExternal(app, win, view, &w.pointer, &w.hover));
    _ = gtk.g_signal_connect(win, "close-request", @ptrCast(&onCloseRequest), w);
    blink.watchWindow(app, win);
    gtk.gtk_window_present(win);
    _ = gtk.gtk_widget_grab_focus(area);
    // The GUI harness's marker for a new external window (test/gui/app_log.zig).
    applog.appLog("[external_window] open gridId={d} rows={d} cols={d}\n", .{ op.grid_id, op.rows, op.cols });
}

fn close(app: *App, grid_id: i64) void {
    const kv = app.ext_windows.fetchRemove(grid_id) orelse return;
    const w = kv.value;
    scrollbar.cancelTimers(&w.scrollbar);
    // A later window reusing this grid id starts unedited.
    app.cell_age.drop(grid_id);
    chrome.releaseHover(&w.hover);
    // Where it was, for the same grid reopening in this session (X11 only:
    // Wayland gives no position).
    if (w.window) |win| if (x11_place.frame(win)) |f|
        app.ext_placement.save(grid_id, @floatFromInt(f.x), @floatFromInt(f.y), w.generation, app.session_generation);
    // Panel popups and message widgets over this window go back to the
    // main view.
    panel_popup.surfaceClosing(app, grid_id);
    ui_widgets.surfaceClosing(app, grid_id);
    // Destroying unrealizes the area, which still reads `w`.
    if (w.window) |win| gtk.gtk_window_destroy(win);
    w.gl.deinit(app.alloc);
    app.alloc.destroy(w);
    applog.appLog("[linux] ext window closed grid={d}\n", .{grid_id});
}

/// Callable from any thread: the cell size changed, and every external
/// window takes the size its grid's rows and columns now need.
pub fn queueRefit(app: *App) void {
    _ = gtk.g_idle_add(&idleRefit, app);
}

fn idleRefit(data: ?*anyopaque) callconv(.c) c_int {
    refitAll(@ptrCast(@alignCast(data.?)));
    return 0;
}

/// Brings forward the OS window showing `grid_id` when the cursor moved
/// there from another window (`<C-w>w` into an external window), as macOS
/// and Windows do. The compositor may still refuse a focus change. GTK
/// main thread.
pub fn focusGrid(app: *App, grid_id: i64) void {
    const target = if (app.ext_windows.get(grid_id)) |w| w.window else ownerWindow(app, grid_id);
    const win = target orelse return;
    if (gtk.gtk_window_is_active(win) != 0) return;
    // Only from another of this app's windows: never steal focus from
    // another application.
    if (!anyActive(app)) return;
    gtk.gtk_window_present(win);
}

/// The window whose surface holds `grid_id`: an external window that
/// composites it, else the main window.
fn ownerWindow(app: *App, grid_id: i64) ?*anyopaque {
    app.mu.lockUncancelable(clock.io());
    defer app.mu.unlock(clock.io());
    var it = app.ext_windows.valueIterator();
    while (it.next()) |w| {
        for (app.surface.committedSurfaceLayers(w.*.grid_id)) |l| {
            if (l.grid_id == grid_id) return w.*.window;
        }
    }
    return app.window;
}

fn anyActive(app: *App) bool {
    if (app.window) |m| if (gtk.gtk_window_is_active(m) != 0) return true;
    var it = app.ext_windows.valueIterator();
    while (it.next()) |w| if (w.*.window) |win| if (gtk.gtk_window_is_active(win) != 0) return true;
    return false;
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
    if (postfx.active(w.app, &w.postfx)) noteWindowOffset(w);
    gl_renderer.renderExternal(w.app, &w.gl, &w.postfx, w.grid_id);
    return 1;
}

/// The shader's iWindowOffset for `w`, read again when due (X11 only).
fn noteWindowOffset(w: *ExtWindow) void {
    if (!x11_place.active()) return;
    const now = clock.nowNs();
    if (!x11_place.windowOffsetDue(now, w.postfx.window_offset_ns)) return;
    w.postfx.window_offset_ns = now;
    const app = w.app;
    const off = x11_place.windowOffset(w.window orelse return, w.area orelse return, app.window orelse return, app.gl_area orelse return) orelse return;
    w.postfx.window_offset_px = off;
}

/// `w_px`/`h_px` are device px. A size the user dragged to asks Neovim for
/// the grid that fills it; the core answers with on_external_window.
fn onResize(area: ?*anyopaque, w_px: c_int, h_px: c_int, data: ?*anyopaque) callconv(.c) void {
    _ = area;
    const w = extFrom(data);
    if (w_px <= 0 or h_px <= 0) return;
    w.gl.w_px = @intCast(w_px);
    w.gl.h_px = @intCast(h_px);
    fit(w);
}

/// Asks Neovim for the grid that fills the area at the current cell.
fn fit(w: *ExtWindow) void {
    if (w.gl.w_px == 0 or w.gl.h_px == 0) return;
    const c = cellPx(w.app, w.grid_id);
    if (c.w == 0 or c.h == 0) return;
    const rows: u32 = @max(1, w.gl.h_px / c.h);
    const cols: u32 = @max(1, scrollbar.gridWidthPx(w.app.scrollbar_cfg, w.gl.w_px, windowScale(w)) / c.w);
    if (rows == w.rows and cols == w.cols) return;
    const cp = w.app.corep orelse return;
    core.zonvie_core_try_resize_grid(cp, w.grid_id, rows, cols);
}

/// After the cell changed (guifont, linespace, the main window's scale):
/// every external window keeps its grid's rows and columns and takes the
/// size they now need, as macOS and Windows resize theirs. GTK main thread.
pub fn refitAll(app: *App) void {
    var it = app.ext_windows.valueIterator();
    while (it.next()) |w| {
        const win = w.*.window orelse continue;
        const sz = logicalSize(app, w.*.grid_id, w.*.rows, w.*.cols, windowScale(w.*));
        gtk.gtk_window_set_default_size(win, sz[0], sz[1]);
    }
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

// =========================================================================
// Placement and window-layout operations (X11 only; x11_place)
// =========================================================================

/// Where the window of `op` opens, root px, `w_logical` wide: a torn-off
/// tab's drop point, else the global cell win_pos named, else null for the
/// window manager's choice. GTK main thread, X11 session.
fn openOrigin(app: *App, op: Op, w_logical: c_int) ?[2]i32 {
    const main = app.window orelse return null;
    const now_ms: i64 = @intCast(@divTrunc(clock.nowNs(), std.time.ns_per_ms));
    const placement = app.ext_placement.take(op.grid_id, app.session_generation, now_ms);
    const view: ?[2]f64 = if (app.widgets.overlay) |v| x11_place.widgetPoint(main, v, 0, 0) else null;
    app.mu.lockUncancelable(clock.io());
    const cw = app.cell_w_px;
    const ch = app.cell_h_px;
    app.mu.unlock(clock.io());
    const o = x11_place.extOrigin(placement, op.start_row, op.start_col, view, cw, ch, w_logical * x11_place.scale(main));
    const from: []const u8 = if (placement) |p| (if (p.kind == .pending) "drop point" else "saved") else "win_pos";
    if (o) |p| applog.appLog("[x11_place] ext window grid={d} opens at ({d},{d}) from {s}\n", .{ op.grid_id, p[0], p[1], from });
    return o;
}

/// The surface of the OS window showing `grid_id`: the external window
/// that is the grid or composites it, else the main window (1). GTK main
/// thread.
fn showingSurface(app: *App, grid_id: i64) i64 {
    if (app.ext_windows.contains(grid_id)) return grid_id;
    app.mu.lockUncancelable(clock.io());
    defer app.mu.unlock(clock.io());
    var it = app.ext_windows.valueIterator();
    while (it.next()) |w| {
        for (app.surface.committedSurfaceLayers(w.*.grid_id)) |l| {
            if (l.grid_id == grid_id) return w.*.grid_id;
        }
    }
    return 1;
}

/// The windows a layout operation arranges, as macOS and Windows collect
/// them: the main window, then each external window shown and not
/// minimized. `frames[i]` is window i's visible rect, with id i.
const Arranged = struct {
    n: usize = 0,
    wins: [win_layout.max_frames]*anyopaque = undefined,
    surface: [win_layout.max_frames]i64 = undefined,
    win_ids: [win_layout.max_frames]i64 = undefined,
    frames: [win_layout.max_frames]win_layout.Frame = undefined,

    fn add(self: *Arranged, win: *anyopaque, surface: i64, win_id: i64) void {
        if (self.n == win_layout.max_frames) return;
        if (gtk.gtk_widget_get_visible(win) == 0) return;
        if (gtk.gtk_native_get_surface(win)) |s| {
            if (gtk.gdk_toplevel_get_state(s) & gtk.GDK_TOPLEVEL_STATE_MINIMIZED != 0) return;
        }
        const r = x11_place.frame(win) orelse return;
        self.wins[self.n] = win;
        self.surface[self.n] = surface;
        self.win_ids[self.n] = win_id;
        self.frames[self.n] = .{ .id = @intCast(self.n), .x = @floatFromInt(r.x), .y = @floatFromInt(r.y), .w = @floatFromInt(r.w), .h = @floatFromInt(r.h) };
        self.n += 1;
    }

    fn indexOf(self: *const Arranged, surface: i64) ?usize {
        for (self.surface[0..self.n], 0..) |s, i| if (s == surface) return i;
        return null;
    }
};

/// Empty on Wayland, where x11_place reads no frame. The main window's
/// Neovim window is left 0: findWindow's caller resolves it.
fn arrange(app: *App, out: *Arranged) void {
    if (app.window) |m| out.add(m, 1, 0);
    var it = app.ext_windows.valueIterator();
    while (it.next()) |w| if (w.*.window) |win| out.add(win, w.*.grid_id, w.*.win);
}

/// Rows whose centres are closer than this read as one row: macOS's 20pt,
/// in root px, as Windows scales it.
fn rowBandPx(app: *App) f64 {
    const main = app.window orelse return 20;
    return @floatFromInt(20 * x11_place.scale(main));
}

/// Plans `op` over every arranged window with the core's rule and moves or
/// resizes the ones it changed. GTK main thread.
fn applyLayout(app: *App, op: Op) void {
    var a: Arranged = .{};
    arrange(app, &a);
    const source: usize = if (op.source_grid) |g| (a.indexOf(showingSurface(app, g)) orelse return) else 0;
    const before = a.frames;
    if (!win_layout.plan(op.layout_op, op.arg, op.count, @intCast(source), rowBandPx(app), a.frames[0..a.n])) return;
    var changed: usize = 0;
    for (a.frames[0..a.n], before[0..a.n], 0..) |f, b, i| {
        const r = roundRect(f);
        const old = roundRect(b);
        if (std.meta.eql(r, old)) continue;
        x11_place.place(a.wins[i], r, r.w == old.w and r.h == old.h);
        changed += 1;
    }
    applog.appLog("[x11_place] layout {s} arg={d} count={d}: {d} of {d} windows changed\n", .{ @tagName(op.layout_op), op.arg, op.count, changed, a.n });
}

fn roundRect(f: win_layout.Frame) x11_place.Rect {
    return .{ .x = @intFromFloat(@round(f.x)), .y = @intFromFloat(@round(f.y)), .w = @intFromFloat(@round(f.w)), .h = @intFromFloat(@round(f.h)) };
}

const FindTask = struct {
    app: *App,
    seq: u64,
    cursor_grid: i64,
    direction: i32,
    count: i32,
    main_win: i64,
};

/// on_win_move_cursor: the Neovim window `count` windows from the cursor's
/// OS window in `direction` by screen geometry, or 0 for none (Neovim then
/// moves within its own layout, as with no callback). Core thread,
/// grid_mu not held; the geometry is read on the GTK thread, waited for up
/// to 5 s as the clipboard is. `main_win` is the Neovim window a move into
/// the main window lands on.
pub fn findWindow(app: *App, cursor_grid: i64, direction: i32, count: i32, main_win: i64) i64 {
    const io = clock.io();
    app.win_find_mu.lockUncancelable(io);
    app.win_find_ready = false;
    app.win_find_result = 0;
    app.win_find_seq +%= 1;
    const seq = app.win_find_seq;
    app.win_find_mu.unlock(io);
    const task = app.alloc.create(FindTask) catch return 0;
    task.* = .{ .app = app, .seq = seq, .cursor_grid = cursor_grid, .direction = direction, .count = count, .main_win = main_win };
    _ = gtk.g_idle_add(&idleFind, task);

    app.win_find_mu.lockUncancelable(io);
    defer app.win_find_mu.unlock(io);
    // std.Io.Condition has no timed wait: poll, releasing the mutex.
    const deadline_ns = clock.nowNs() + 5 * std.time.ns_per_s;
    while (!app.win_find_ready and clock.nowNs() < deadline_ns) {
        app.win_find_mu.unlock(io);
        std.Io.sleep(io, .{ .nanoseconds = std.time.ns_per_ms }, .awake) catch {};
        app.win_find_mu.lockUncancelable(io);
    }
    if (!app.win_find_ready) {
        // A late answer must not satisfy the next request.
        app.win_find_seq +%= 1;
        applog.appLog("[x11_place] win_move_cursor: timeout\n", .{});
    }
    return app.win_find_result;
}

fn idleFind(data: ?*anyopaque) callconv(.c) c_int {
    const task: *FindTask = @ptrCast(@alignCast(data.?));
    const app = task.app;
    defer app.alloc.destroy(task);
    var a: Arranged = .{};
    arrange(app, &a);
    const result: i64 = blk: {
        const current = a.indexOf(showingSurface(app, task.cursor_grid)) orelse break :blk 0;
        const t = win_layout.findInDirection(a.frames[0..a.n], @intCast(current), @enumFromInt(task.direction), task.count) orelse break :blk 0;
        break :blk if (a.surface[t] == 1) task.main_win else a.win_ids[t];
    };
    applog.appLog("[x11_place] win_move_cursor direction={d} count={d} -> win={d}\n", .{ task.direction, task.count, result });
    app.win_find_mu.lockUncancelable(clock.io());
    defer app.win_find_mu.unlock(clock.io());
    if (app.win_find_seq != task.seq) return 0;
    app.win_find_result = result;
    app.win_find_ready = true;
    return 0;
}

/// Releases a core thread waiting in findWindow with "none", as its
/// timeout would, once the main loop no longer serves its idle.
pub fn abandonFindWait(app: *App) void {
    app.win_find_mu.lockUncancelable(clock.io());
    defer app.win_find_mu.unlock(clock.io());
    app.win_find_seq +%= 1;
    app.win_find_result = 0;
    app.win_find_ready = true;
}
