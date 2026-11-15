//! The main window's size against the cell grid: snapped to whole cells when
//! the cell size changes (guifont, linespace) and after the user resizes it,
//! sized to `:set lines` / `:set columns`, and remembered across runs. The
//! position is remembered and restored too under X11; Wayland lets no client
//! read or set a toplevel's position, so there only the size is. GTK main thread,
//! except `noteResize`, called from the view's resize on the GTK thread too.

const std = @import("std");
const core = @import("zonvie_core");
const clock = core.clock;
const rules = core.frontend_rules;
const App = @import("app.zig").App;
const gtk = @import("gtk_bindings.zig");
const applog = @import("app_log.zig");
const scrollbar = @import("scrollbar.zig");
const x11_place = @import("x11_place.zig");

/// macOS's debounce before a resize ends in a snap.
const settle_ms = 300;

pub const State = struct {
    /// The view size the user (or the compositor) last chose, device px;
    /// a snap's own echo never overwrites it, so a snap chained on a snap
    /// can grow back (frontend_rules.snapTerminalPx).
    desired_w_px: u32 = 0,
    desired_h_px: u32 = 0,
    /// The view size the last snap asked for.
    snapped_w_px: u32 = 0,
    snapped_h_px: u32 = 0,
    settle_timer: c_uint = 0,
    /// A snap asked the window for a size whose resize has not arrived, until
    /// this clock time (ns); 0 for none. The view is stale meanwhile, and a
    /// second snap from it would take the remainder off again.
    pending_until_ns: i64 = 0,
    /// The window's chrome is final: the stylesheet that gives the editor
    /// card its margins is loaded. A snap before it measures a view that is
    /// about to shrink, and takes off what the card then takes again.
    chrome_ready: bool = false,
    /// A snap idle is queued (queueSnap runs on the core thread).
    snap_queued: std.atomic.Value(bool) = .init(false),
    /// The position restorePosition still has to apply, X11 root px.
    restore_pos: ?[2]i32 = null,
    /// What the window adds around the view (titlebar, tabs, sidebar, card),
    /// device px, measured when a resize arrived: the one moment the view
    /// and the window's size describe the same layout. Null before the first.
    chrome_px: ?[2]i32 = null,
    /// The window's size at the last resize, device px: a view resize with
    /// the window's size unchanged is the chrome's (a sidebar slide), not
    /// the user's, and is not snapped.
    outer_px: [2]i32 = .{ 0, 0 },
};

/// The editor view's new size, device px. Records a size not of a snap's
/// making and snaps once resizing settles.
pub fn noteResize(app: *App, w_px: u32, h_px: u32) void {
    const s = &app.window_size;
    s.pending_until_ns = 0;
    const win = app.window orelse return;
    app.mu.lockUncancelable(clock.io());
    const scale = app.scale;
    app.mu.unlock(clock.io());
    const outer = defaultSizePx(win, scale);
    s.chrome_px = chromePx(outer, .{ w_px, h_px });
    const user_resize = !std.mem.eql(i32, &outer, &s.outer_px);
    s.outer_px = outer;
    if (w_px == s.snapped_w_px and h_px == s.snapped_h_px) return;
    s.desired_w_px = w_px;
    s.desired_h_px = h_px;
    // The chrome took or gave back room: the window keeps its size, and the
    // view is what the user's window now holds.
    if (!user_resize) return;
    if (s.settle_timer != 0) _ = gtk.g_source_remove(s.settle_timer);
    s.settle_timer = gtk.g_timeout_add(settle_ms, &onSettled, app);
}

/// What a window of `outer_px` adds around a view of `view_px`, device px.
pub fn chromePx(outer_px: [2]i32, view_px: [2]u32) [2]i32 {
    return .{ outer_px[0] - @as(i32, @intCast(view_px[0])), outer_px[1] - @as(i32, @intCast(view_px[1])) };
}

fn onSettled(data: ?*anyopaque) callconv(.c) c_int {
    const app: *App = @ptrCast(@alignCast(data.?));
    app.window_size.settle_timer = 0;
    snap(app);
    return 0;
}

/// Callable from any thread: the cell size changed.
pub fn queueSnap(app: *App) void {
    if (app.window_size.snap_queued.swap(true, .acq_rel)) return;
    _ = gtk.g_idle_add(&idleSnap, app);
}

fn idleSnap(data: ?*anyopaque) callconv(.c) c_int {
    const app: *App = @ptrCast(@alignCast(data.?));
    app.window_size.snap_queued.store(false, .release);
    snap(app);
    return 0;
}

/// The stylesheet is loaded: the chrome around the view is final, and the
/// view's next size is what a snap may measure. GTK main thread.
pub fn chromeReady(app: *App) void {
    if (app.window_size.chrome_ready) return;
    app.window_size.chrome_ready = true;
    // The resize the stylesheet causes settles into a snap (noteResize).
}

/// How long a requested size may take to arrive before the compositor is
/// taken to have refused it (a tiled window).
const pending_timeout_ns: i64 = 500 * std.time.ns_per_ms;

/// A snap may run at `now_ns`: no requested size is still on its way.
pub fn snapAllowed(pending_until_ns: i64, now_ns: i64) bool {
    return pending_until_ns == 0 or now_ns >= pending_until_ns;
}

test "no snap while a requested size is on its way" {
    try std.testing.expect(snapAllowed(0, 5));
    try std.testing.expect(!snapAllowed(100, 99));
    try std.testing.expect(snapAllowed(100, 100));
}

/// The window may be sized by the app: not maximized, fullscreen or tiled,
/// where the compositor owns the size.
fn freeSized(win: *anyopaque) bool {
    const surface = gtk.gtk_native_get_surface(win) orelse return false;
    const st = gtk.gdk_toplevel_get_state(surface);
    return st & (gtk.GDK_TOPLEVEL_STATE_MAXIMIZED | gtk.GDK_TOPLEVEL_STATE_FULLSCREEN | gtk.GDK_TOPLEVEL_STATE_TILED) == 0;
}

/// Shrinks or grows the window so the view holds whole cells of the
/// desired size, the chrome around it unchanged.
fn snap(app: *App) void {
    const win = app.window orelse return;
    if (!freeSized(win)) return;
    if (!app.window_size.chrome_ready) return;
    if (!snapAllowed(app.window_size.pending_until_ns, @intCast(clock.nowNs()))) return;
    app.mu.lockUncancelable(clock.io());
    const cw = app.cell_w_px;
    const ch = app.cell_h_px;
    const vw = app.drawable_w_px;
    const vh = app.drawable_h_px;
    const scale = app.scale;
    app.mu.unlock(clock.io());
    const s = &app.window_size;
    const outer = defaultSizePx(win, scale);
    const outer_w = outer[0];
    const outer_h = outer[1];
    // The cells are the grid's: a "column" scrollbar's strip stays as it is.
    const strip = vw - scrollbar.gridWidthPx(app.scrollbar_cfg, vw, scale);
    const r = rules.snapMainWindowOuterSize(outer_w, outer_h, vw - strip, vh, s.desired_w_px -| strip, s.desired_h_px, cw, ch) orelse return;
    s.pending_until_ns = @as(i64, @intCast(clock.nowNs())) + pending_timeout_ns;
    s.snapped_w_px = r.snapped_content_w + strip;
    s.snapped_h_px = r.snapped_content_h;
    applog.appLog("[window_snap] view={d}x{d} desired={d}x{d} snapped={d}x{d}\n", .{ vw, vh, s.desired_w_px, s.desired_h_px, r.snapped_content_w, r.snapped_content_h });
    setOuterPx(win, r.outer_w, r.outer_h, scale);
}

/// The window's default size, device px: what setOuterPx sets, and what GTK
/// keeps at the window's current size. The widget's own size differs from it
/// by client-side decoration margins under X11, so a size computed from the
/// widget and applied as the default size drifts by them on every resize.
fn defaultSizePx(win: *anyopaque, scale: f32) [2]i32 {
    var w: c_int = 0;
    var h: c_int = 0;
    gtk.gtk_window_get_default_size(win, &w, &h);
    return .{ @intFromFloat(@as(f32, @floatFromInt(w)) * scale), @intFromFloat(@as(f32, @floatFromInt(h)) * scale) };
}

fn setOuterPx(win: *anyopaque, w_px: i32, h_px: i32, scale: f32) void {
    const w: c_int = @intFromFloat(@ceil(@as(f32, @floatFromInt(w_px)) / scale));
    const h: c_int = @intFromFloat(@ceil(@as(f32, @floatFromInt(h_px)) / scale));
    gtk.gtk_window_set_default_size(win, w, h);
}

/// The window's size, device px, for a view of `rows` x `cols` cells and a
/// `strip_px` wide scrollbar column, with `chrome_px` around the view.
pub fn outerForGrid(chrome_px: [2]i32, strip_px: u32, rows: u32, cols: u32, cell_w_px: u32, cell_h_px: u32) [2]i32 {
    return .{
        chrome_px[0] + @as(i32, @intCast(cols * cell_w_px + strip_px)),
        chrome_px[1] + @as(i32, @intCast(rows * cell_h_px)),
    };
}

test "a grid size keeps the chrome around the view" {
    try std.testing.expectEqual([2]i32{ 940, 660 }, outerForGrid(chromePx(.{ 1040, 760 }, .{ 1000, 700 }), 0, 30, 100, 9, 20));
}

test "two grid sizes in a row give the second size, not twice the change" {
    // :set lines=24 columns=80 sends two sizes before any resize arrives:
    // the chrome measured at the last resize serves both.
    const chrome = chromePx(.{ 1040, 760 }, .{ 1000, 700 });
    _ = outerForGrid(chrome, 0, 24, 100, 9, 20);
    try std.testing.expectEqual([2]i32{ 40 + 80 * 9, 60 + 24 * 20 }, outerForGrid(chrome, 0, 24, 80, 9, 20));
}

/// Neovim resized its grid (`:set lines` / `:set columns`): the window
/// follows, in either renderer mode.
pub fn resizeToGrid(app: *App, rows: u32, cols: u32) void {
    const win = app.window orelse return;
    app.mu.lockUncancelable(clock.io());
    const cw = app.cell_w_px;
    const ch = app.cell_h_px;
    const vw = app.drawable_w_px;
    const vh = app.drawable_h_px;
    const scale = app.scale;
    app.mu.unlock(clock.io());
    if (rows == 0 or cols == 0 or cw == 0 or ch == 0 or vw == 0 or vh == 0) return;
    // The chrome of the last resize, not this moment's window and view: a
    // size asked a moment ago has changed the window but not yet the view.
    const chrome = app.window_size.chrome_px orelse chromePx(defaultSizePx(win, scale), .{ vw, vh });
    const strip = vw - scrollbar.gridWidthPx(app.scrollbar_cfg, vw, scale);
    const o = outerForGrid(chrome, strip, rows, cols, cw, ch);
    // The asked size is what a later snap starts from.
    app.window_size.desired_w_px = cols * cw + strip;
    app.window_size.desired_h_px = rows * ch;
    applog.appLog("[window_size] grid {d}x{d} -> window {d}x{d} px (chrome {d}x{d})\n", .{ rows, cols, o[0], o[1], chrome[0], chrome[1] });
    setOuterPx(win, o[0], o[1], scale);
}

// =========================================================================
// Remembered size
// =========================================================================

/// `$XDG_STATE_HOME/zonvie/window` (else `~/.local/state/zonvie/window`).
fn statePath(buf: []u8) ?[:0]const u8 {
    if (std.c.getenv("XDG_STATE_HOME")) |d| return std.fmt.bufPrintZ(buf, "{s}/zonvie/window", .{std.mem.span(d)}) catch null;
    const home = std.c.getenv("HOME") orelse return null;
    return std.fmt.bufPrintZ(buf, "{s}/.local/state/zonvie/window", .{std.mem.span(home)}) catch null;
}

/// What the state file holds: the size, logical px, and under X11 the
/// visible frame's top-left, X11 root px (x11_place).
pub const Saved = struct {
    size: [2]c_int,
    pos: ?[2]i32 = null,
};

/// "W H" or "W H X Y". Null for a malformed size or one below the window's
/// floor; a malformed or absent position leaves `pos` null.
pub fn parseState(text: []const u8) ?Saved {
    var it = std.mem.tokenizeAny(u8, text, " \t\r\n");
    const w = std.fmt.parseInt(c_int, it.next() orelse return null, 10) catch return null;
    const h = std.fmt.parseInt(c_int, it.next() orelse return null, 10) catch return null;
    if (w < 200 or h < 150 or w > 16384 or h > 16384) return null;
    var s: Saved = .{ .size = .{ w, h } };
    const xs = it.next() orelse return s;
    const ys = it.next() orelse return s;
    const x = std.fmt.parseInt(i32, xs, 10) catch return s;
    const y = std.fmt.parseInt(i32, ys, 10) catch return s;
    if (@abs(x) > 1 << 20 or @abs(y) > 1 << 20) return s;
    s.pos = .{ x, y };
    return s;
}

/// The file's text for `s`, read back by parseState.
pub fn formatState(buf: []u8, s: Saved) ?[]const u8 {
    if (s.pos) |p| return std.fmt.bufPrint(buf, "{d} {d} {d} {d}\n", .{ s.size[0], s.size[1], p[0], p[1] }) catch null;
    return std.fmt.bufPrint(buf, "{d} {d}\n", .{ s.size[0], s.size[1] }) catch null;
}

test "a remembered size is two numbers within bounds" {
    try std.testing.expectEqual([2]c_int{ 1000, 700 }, parseState("1000 700\n").?.size);
    try std.testing.expect(parseState("1000 700\n").?.pos == null);
    try std.testing.expect(parseState("1000") == null);
    try std.testing.expect(parseState("10 700") == null);
    try std.testing.expect(parseState("a b") == null);
}

test "a remembered position follows the size and may be negative" {
    const s = parseState("1000 700 -1200 40\n").?;
    try std.testing.expectEqual([2]c_int{ 1000, 700 }, s.size);
    try std.testing.expectEqual([2]i32{ -1200, 40 }, s.pos.?);
    // A broken position keeps the size.
    try std.testing.expect(parseState("1000 700 5").?.pos == null);
    try std.testing.expect(parseState("1000 700 x 5").?.pos == null);
    try std.testing.expect(parseState("1000 700 99999999 5").?.pos == null);
}

test "the state text reads back as written" {
    var buf: [48]u8 = undefined;
    const with_pos: Saved = .{ .size = .{ 1000, 700 }, .pos = .{ 30, -4 } };
    try std.testing.expectEqualStrings("1000 700 30 -4\n", formatState(&buf, with_pos).?);
    try std.testing.expectEqual(with_pos.pos.?, parseState(formatState(&buf, with_pos).?).?.pos.?);
    try std.testing.expectEqualStrings("1000 700\n", formatState(&buf, .{ .size = .{ 1000, 700 } }).?);
}

/// What the last run closed with.
pub fn restored() ?Saved {
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const path = statePath(&pbuf) orelse return null;
    var buf: [64]u8 = undefined;
    const io = clock.io();
    const f = std.Io.Dir.openFileAbsolute(io, path, .{}) catch return null;
    defer f.close(io);
    var r = f.reader(io, &.{});
    const n = r.interface.readSliceShort(&buf) catch return null;
    return parseState(buf[0..n]);
}

/// Remembers the window's size, and its position under X11, for the next
/// run; a maximized, fullscreen or tiled window keeps the last free size.
pub fn save(app: *App) void {
    const win = app.window orelse return;
    if (!freeSized(win)) return;
    // The default size, which GTK keeps at the window's current size: the
    // quantity `restored` hands back to gtk_window_set_default_size. The
    // widget's own width differs from it by client-side decoration margins
    // under X11, and saving that shrank the window every run.
    var w: c_int = 0;
    var h: c_int = 0;
    gtk.gtk_window_get_default_size(win, &w, &h);
    if (w <= 0 or h <= 0) return;
    var s: Saved = .{ .size = .{ w, h } };
    if (x11_place.frame(win)) |f| s.pos = .{ f.x, f.y };
    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const path = statePath(&pbuf) orelse return;
    const io = clock.io();
    if (std.fs.path.dirname(path)) |dir| std.Io.Dir.cwd().createDirPath(io, dir) catch return;
    const f = std.Io.Dir.createFileAbsolute(io, path, .{}) catch return;
    defer f.close(io);
    var buf: [48]u8 = undefined;
    const text = formatState(&buf, s) orelse return;
    f.writeStreamingAll(io, text) catch {};
    applog.appLog("[window_state] saved {s}", .{text});
}

/// Under X11, puts the main window back at `pos` (x11_place root px) as it
/// is first shown; a position off every attached monitor is dropped.
/// Nothing on Wayland.
pub fn restorePosition(app: *App, win: *anyopaque, pos: [2]i32) void {
    if (!x11_place.active()) return;
    app.window_size.restore_pos = pos;
    x11_place.placeWhenShown(win, &app.window_size.restore_pos);
}
