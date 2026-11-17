//! What the frontend draws itself, over and around the editor: the message
//! labels (minis, toast, confirm), the IME's composition, and the pieces
//! chrome.zig adds around the view. Everything is rebuilt into one UI layer
//! (ui_layer.zig) whenever its inputs change, and the renderer draws that
//! layer after the editor. Main thread only, except queueRefresh.

const std = @import("std");
const core = @import("zonvie_core");
const clock = core.clock;
const rules = core.frontend_rules;
const App = @import("app.zig").App;
const glib = @import("glib.zig");
const applog = @import("app_log.zig");
const ui_state = @import("ui_state.zig");
const ui_layer = @import("ui_layer.zig");
const overlay_layout = @import("overlay_layout.zig");
const notify = @import("notify.zig");
const gl_renderer = @import("renderer/gl_renderer.zig");
const seam = @import("ui.zig");
const chrome = @import("chrome.zig");
const lifecycle = @import("lifecycle.zig");
const Builder = ui_layer.Builder;
const Rect = ui_layer.Rect;

/// Gap between a label and the edge it hangs from, logical px.
const margin_pt = 10;
/// A label's padding around its text, logical px.
const pad_x_pt = 12;
const pad_y_pt = 6;

/// What a hit region of the layer does when pressed (ui_layer.Hit.id).
pub const HitId = enum(u32) {
    /// Copies a panel's text; `arg` is its overlay_layout.Kind.
    copy,
    _,
};

const copy_glyph = "\u{29c9}";
const copied_glyph = "\u{2713}";
const copied_ms = 800;
const copy_retry_ms = 16;
const copy_tries = 10;

/// Callable from any thread; at most one refresh is outstanding.
pub fn queueRefresh(app: *App) void {
    if (app.ui_idle_queued.swap(true, .acq_rel)) return;
    _ = glib.g_idle_add(&idleRefresh, app);
}

fn idleRefresh(data: ?*anyopaque) callconv(.c) c_int {
    const app: *App = @ptrCast(@alignCast(data.?));
    app.ui_idle_queued.store(false, .release);
    // What is announced once leaves with this pass.
    var done: [8]ui_state.Completion = undefined;
    var done_count: usize = 0;
    var notice: [1025]u8 = undefined;
    var notice_len: usize = 0;
    var toast_timer: u32 = 0;
    var mini_timer: u32 = 0;
    {
        app.mu.lockUncancelable(clock.io());
        defer app.mu.unlock(clock.io());
        const ui = &app.ui;
        done_count = @min(ui.done_count, done.len);
        @memcpy(done[0..done_count], ui.done[0..done_count]);
        ui.done_count = 0;
        if (ui.notice_pending) {
            const t = ui.notice.text();
            notice_len = @min(t.len, notice.len - 1);
            @memcpy(notice[0..notice_len], t[0..notice_len]);
        }
        ui.notice_pending = false;
        // timeout 0 stays (errors). A timer hides only the message that set it.
        if (ui.toast_count != 0 and ui.toast_timeout_ms != 0 and app.toast_timer_seq != ui.toast_seq) {
            app.toast_timer_seq = ui.toast_seq;
            toast_timer = ui.toast_timeout_ms;
        }
        if (ui.minis[@intFromEnum(ui_state.Mini.message)].len != 0 and ui.mini_timeout_ms != 0 and app.mini_timer_seq != ui.mini_seq) {
            app.mini_timer_seq = ui.mini_seq;
            mini_timer = ui.mini_timeout_ms;
        }
    }
    if (toast_timer != 0) _ = glib.g_timeout_add(toast_timer, &onToastTimeout, app);
    if (mini_timer != 0) _ = glib.g_timeout_add(mini_timer, &onMiniTimeout, app);
    if (done_count != 0) {
        // The OS notification for agent completions ([tabline]
        // agent_notification), sent always: the agent runs in this app's own
        // terminal, so focus says nothing about whether the user saw it.
        var buf: [320]u8 = undefined;
        notify.send(app, .agent, "Zonvie", ui_state.completionMessage(buf[0 .. buf.len - 1], done[0..done_count]));
    }
    if (notice_len != 0) notify.send(app, .none, "Neovim", notice[0..notice_len]);
    rebuild(app, true);
    return 0;
}

/// Hides the toast that set this timer, unless a newer one replaced it.
fn onToastTimeout(data: ?*anyopaque) callconv(.c) c_int {
    const app: *App = @ptrCast(@alignCast(data.?));
    app.mu.lockUncancelable(clock.io());
    const current = app.ui.toast_seq == app.toast_timer_seq;
    if (current) app.ui.toast_count = 0;
    app.mu.unlock(clock.io());
    if (current) queueRefresh(app);
    return 0;
}

/// Hides the mini-routed message that set this timer, unless a newer one
/// replaced it.
fn onMiniTimeout(data: ?*anyopaque) callconv(.c) c_int {
    const app: *App = @ptrCast(@alignCast(data.?));
    app.mu.lockUncancelable(clock.io());
    const current = app.ui.mini_seq == app.mini_timer_seq;
    if (current) app.ui.minis[@intFromEnum(ui_state.Mini.message)].clear();
    app.mu.unlock(clock.io());
    if (current) queueRefresh(app);
    return 0;
}

fn rgba(c: u32, a: f32) [4]f32 {
    return .{
        @as(f32, @floatFromInt((c >> 16) & 0xff)) / 255.0,
        @as(f32, @floatFromInt((c >> 8) & 0xff)) / 255.0,
        @as(f32, @floatFromInt(c & 0xff)) / 255.0,
        a,
    };
}

/// What a build reads, taken under App.mu so the build runs without it.
const Inputs = struct {
    ui: ui_state.UiState,
    fg: u32,
    bg: u32,
    scale: i32,
    /// The editor view in the window, device px.
    view: Rect,
    win_w: i32,
    win_h: i32,
    cell_w: i32,
    cell_h: i32,
    anchor: ?core.MsgAnchor,
    pos: core.config.Config.MsgPosConfig,
    ext_cmdline: bool,
};

/// A label: a filled box with a border and lines of text in it.
const Look = struct { fill: [4]f32, border: [4]f32, text: [4]f32 };

/// The label's colours for a message tone (zonvie_core_msg_kind_tone: 1
/// error, 2 warn, 3 prompt, 4 search).
fn look(in: *const Inputs, tone: u8) Look {
    const bg = rgba(in.bg, 1);
    const p = rules.panelBg(bg[0], bg[1], bg[2]);
    const fg = rgba(in.fg, 1);
    const dim: [4]f32 = .{ fg[0], fg[1], fg[2], 0.25 };
    return switch (tone) {
        1 => .{ .fill = .{ p[0], p[1], p[2], 1 }, .border = rgba(0xff4d4d, 1), .text = rgba(0xff6666, 1) },
        2 => .{ .fill = .{ p[0], p[1], p[2], 1 }, .border = rgba(0xffcc4d, 1), .text = rgba(0xffd966, 1) },
        3 => .{ .fill = .{ p[0], p[1], p[2], 1 }, .border = rgba(0x4d99ff, 1), .text = rgba(0x99ccff, 1) },
        4 => .{ .fill = .{ p[0], p[1], p[2], 1 }, .border = dim, .text = rgba(0x99ff99, 1) },
        else => .{ .fill = .{ p[0], p[1], p[2], 1 }, .border = dim, .text = fg },
    };
}

/// `text` as lines no wider than `max_cells`: at its newlines, then by width.
/// A line is a slice of `text`. Returns how many fit `out`.
fn wrap(text: []const u8, max_cells: usize, out: [][]const u8) usize {
    var n: usize = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        var rest = line;
        while (true) {
            if (n == out.len) return n;
            // Cut on a character boundary at most max_cells characters in.
            var cells: usize = 0;
            var i: usize = 0;
            while (i < rest.len and cells < max_cells) {
                const len = std.unicode.utf8ByteSequenceLength(rest[i]) catch 1;
                i = @min(rest.len, i + len);
                cells += 1;
            }
            out[n] = rest[0..i];
            n += 1;
            rest = rest[i..];
            if (rest.len == 0) break;
        }
    }
    return n;
}

/// Draws `lines` in a label whose top-left is (x, y); returns its rect.
fn label(b: *Builder, in: *const Inputs, x: i32, y: i32, lines: []const []const u8, l: Look) Rect {
    const pad_x = pad_x_pt * in.scale;
    const pad_y = pad_y_pt * in.scale;
    var w: i32 = 0;
    for (lines) |line| w = @max(w, b.textWidth(line));
    const r: Rect = .{ .x = x, .y = y, .w = w + 2 * pad_x, .h = @as(i32, @intCast(lines.len)) * in.cell_h + 2 * pad_y };
    b.rect(r, l.border);
    b.rect(.{ .x = r.x + in.scale, .y = r.y + in.scale, .w = r.w - 2 * in.scale, .h = r.h - 2 * in.scale }, l.fill);
    for (lines, 0..) |line, i| _ = b.text(r.x + pad_x, r.y + pad_y + @as(i32, @intCast(i)) * in.cell_h, w, line, l.text, .{});
    return r;
}

/// The size `lines` take as a label.
fn labelSize(b: *Builder, in: *const Inputs, lines: []const []const u8) [2]i32 {
    var w: i32 = 0;
    for (lines) |line| w = @max(w, b.textWidth(line));
    return .{ w + 2 * pad_x_pt * in.scale, @as(i32, @intCast(lines.len)) * in.cell_h + 2 * pad_y_pt * in.scale };
}

/// The toast hangs from the top-right of msg_pos.ext_float's target, the
/// minis from the bottom-right of msg_pos.mini's, as macOS and Windows
/// place them; the confirm prompt is centred across the view.
fn buildMessages(app: *App, b: *Builder, in: *const Inputs) void {
    const m = margin_pt * in.scale;
    const cw = @max(1, in.cell_w);
    var lines: [64][]const u8 = undefined;

    // Minis: one label each, stacked upwards from the corner.
    {
        const r = overlay_layout.msgTargetOn(1, in.pos.mini, in.anchor, in.view.w, in.view.h, in.cell_w, in.cell_h);
        var bottom = in.view.y + r.bottom - m;
        var i: usize = in.ui.minis.len;
        while (i > 0) {
            i -= 1;
            const text = in.ui.minis[i].text();
            if (text.len == 0) continue;
            const max_cells: usize = @intCast(@max(8, @divTrunc(r.right - r.left - 2 * m - 2 * pad_x_pt * in.scale, cw)));
            const n = wrap(text, max_cells, &lines);
            const size = labelSize(b, in, lines[0..n]);
            const tone: u8 = 0;
            _ = label(b, in, in.view.x + r.right - m - size[0], bottom - size[1], lines[0..n], look(in, tone));
            bottom -= size[1] + 2 * in.scale;
        }
    }

    // Toast: at most 0.8 of the target and 600 logical px wide.
    if (in.ui.toast_count != 0) {
        var buf: [5 * 1025 + 3 * 257]u8 = undefined;
        const text = in.ui.toastText(&buf);
        if (text.len != 0) {
            const r = overlay_layout.msgTargetOn(1, in.pos.ext_float, in.anchor, in.view.w, in.view.h, in.cell_w, in.cell_h);
            const max_px = @min(@divTrunc((r.right - r.left) * 8, 10), 600 * in.scale) - 2 * pad_x_pt * in.scale;
            const n = wrap(text, @intCast(@max(8, @divTrunc(max_px, cw))), &lines);
            const size = labelSize(b, in, lines[0..n]);
            _ = label(b, in, in.view.x + r.right - m - size[0], in.view.y + r.top + m, lines[0..n], look(in, in.ui.toastTone()));
        }
    }

    // Confirm: at most the view less 40 logical px, and 800.
    var confirm_rect: ?overlay_layout.Rect = null;
    const confirm = in.ui.confirm.text();
    if (confirm.len != 0) {
        const max_px = @min(in.view.w - 40 * in.scale, 800 * in.scale) - 2 * pad_x_pt * in.scale;
        const n = wrap(confirm, @intCast(@max(8, @divTrunc(max_px, cw))), &lines);
        const size = labelSize(b, in, lines[0..n]);
        const top_logical = overlay_layout.confirmTop(@divTrunc(in.view.h, in.scale), @divTrunc(size[1], in.scale), @divTrunc(in.cell_h, in.scale), in.ext_cmdline);
        const x = @divTrunc(in.view.w - size[0], 2);
        const y = top_logical * in.scale;
        _ = label(b, in, in.view.x + x, in.view.y + y, lines[0..n], look(in, 3));
        confirm_rect = .{ .x = x, .y = y, .w = size[0], .h = size[1] };
    }
    app.mu.lockUncancelable(clock.io());
    app.confirm_rect = confirm_rect;
    app.mu.unlock(clock.io());
}

/// A copy button on each panel that has room for one (the cmdline, the
/// message panels): where the renderer left that room
/// (overlay_layout.copyButtonRect). It shows a check for a moment after a
/// copy that happened.
fn buildCopyButtons(app: *App, b: *Builder, in: *const Inputs) void {
    var boxes: [4]?overlay_layout.Rect = @splat(null);
    {
        app.mu.lockUncancelable(clock.io());
        defer app.mu.unlock(clock.io());
        if (app.drawable_w_px == 0) return;
        const oin = gl_renderer.overlayInputs(app, 1, app.drawable_w_px, app.drawable_h_px);
        const rects = overlay_layout.place(&app.overlays, oin);
        for (rects, 0..) |r, i| {
            if (r) |rect| boxes[i] = overlay_layout.copyButtonRect(@enumFromInt(i), rect, oin);
        }
    }
    const fg = rgba(in.fg, 1);
    for (boxes, 0..) |box, i| {
        const r = box orelse continue;
        const glyph: []const u8 = if (app.copied_kind == i) copied_glyph else copy_glyph;
        const w = b.textWidth(glyph);
        const at: Rect = .{ .x = in.view.x + r.x, .y = in.view.y + r.y, .w = r.w, .h = r.h };
        _ = b.text(at.x + @divTrunc(at.w - w, 2), at.y + @divTrunc(at.h - in.cell_h, 2), w, glyph, .{ fg[0], fg[1], fg[2], 0.75 }, .{});
        b.hit(at, @intFromEnum(HitId.copy), @intCast(i));
    }
}

/// A press on one of the layer's hit regions, at (x, y) window px.
pub fn press(app: *App, hit: ui_layer.Hit, x: i32, y: i32, left: bool, middle: bool) void {
    if (hit.id >= @intFromEnum(chrome.Id.drag_area)) return chrome.press(app, hit, x, y, left, middle);
    if (!left) return;
    switch (@as(HitId, @enumFromInt(hit.id))) {
        .copy => {
            app.copy_grid = overlay_layout.gridId(@enumFromInt(hit.arg));
            app.copy_tries = copy_tries;
            _ = copyAttempt(app);
        },
        _ => {},
    }
}

/// The panel's text, as the core's grid holds it, onto the clipboard. A busy
/// grid lock retries a few times (the macOS and Windows rule); the button
/// shows a check only for a copy that happened.
fn copyAttempt(data: ?*anyopaque) callconv(.c) c_int {
    const app: *App = @ptrCast(@alignCast(data.?));
    const cp = app.corep orelse return 0;
    var stack: [4096]u8 = undefined;
    var heap: ?[]u8 = null;
    defer if (heap) |h| app.alloc.free(h);
    var needed = core.zonvie_core_try_get_grid_text(cp, app.copy_grid, &stack, stack.len - 1);
    var buf: []u8 = &stack;
    if (needed > 0 and @as(usize, @intCast(needed)) > stack.len - 1) {
        heap = app.alloc.alloc(u8, @as(usize, @intCast(needed)) + 1) catch return 0;
        buf = heap.?;
        needed = core.zonvie_core_try_get_grid_text(cp, app.copy_grid, buf.ptr, buf.len - 1);
    }
    if (needed < 0) {
        if (app.copy_tries > 0) {
            app.copy_tries -= 1;
            _ = glib.g_timeout_add(copy_retry_ms, &copyAttempt, app);
        }
        return 0;
    }
    if (needed == 0) return 0;
    const n: usize = @min(@as(usize, @intCast(needed)), buf.len - 1);
    if (!seam.window.selectionSet(false, buf[0..n])) return 0;
    const kind = overlay_layout.kindOf(app.copy_grid) orelse return 0;
    app.copied_kind = @intFromEnum(kind);
    rebuild(app, true);
    _ = glib.g_timeout_add(copied_ms, &onCopiedRevert, app);
    return 0;
}

fn onCopiedRevert(data: ?*anyopaque) callconv(.c) c_int {
    const app: *App = @ptrCast(@alignCast(data.?));
    app.copied_kind = null;
    rebuild(app, true);
    return 0;
}

/// The IME's composition at the text cursor, while the core does not show
/// it in the buffer ([input] ime_preedit_mode = "overlay", or outside insert
/// mode): the text on the editor's background, underlined, the clause being
/// converted underlined heavier.
fn buildPreedit(app: *App, b: *Builder, in: *const Inputs) void {
    const text = app.preedit_text[0..app.preedit_len];
    if (text.len == 0) return;
    const at = cursorOrigin(app) orelse return;
    const x = in.view.x + at[0];
    const y = in.view.y + at[1];
    const w = b.textWidth(text);
    b.rect(.{ .x = x, .y = y, .w = w, .h = in.cell_h }, rgba(in.bg, 1));
    _ = b.text(x, y, w, text, rgba(in.fg, 1), .{});
    const line = @max(1, in.scale);
    b.rect(.{ .x = x, .y = y + in.cell_h - line, .w = w, .h = line }, rgba(in.fg, 1));
    const c = app.preedit_clause;
    if (c[1] > c[0] and c[1] <= text.len) {
        const cx = x + b.textWidth(text[0..c[0]]);
        const cw = b.textWidth(text[c[0]..c[1]]);
        b.rect(.{ .x = cx, .y = y + in.cell_h - 2 * line, .w = cw, .h = 2 * line }, rgba(in.fg, 1));
    }
}

/// The committed cursor's top-left in the view, device px.
fn cursorOrigin(app: *App) ?[2]i32 {
    app.mu.lockUncancelable(clock.io());
    defer app.mu.unlock(clock.io());
    const cur = app.surface.committedCursor();
    if (cur.verts.len == 0) return null;
    const layer = for (app.surface.committedSurfaceLayers(1)) |l| {
        if (l.grid_id == cur.grid_id) break l;
    } else return null;
    var x0: f32 = std.math.floatMax(f32);
    var y0: f32 = std.math.floatMax(f32);
    for (cur.verts) |v| {
        x0 = @min(x0, v.position[0]);
        y0 = @min(y0, v.position[1]);
    }
    // The cell's top, whatever part of it the cursor's shape covers.
    const ch: f32 = @floatFromInt(@max(1, app.cell_h_px));
    return .{ @as(i32, @intFromFloat(x0)) + layer.x_px, @as(i32, @intFromFloat(@floor(y0 / ch) * ch)) + layer.y_px };
}

/// What the frontend's own chrome takes of the window around the editor
/// view, device px.
pub const Insets = struct { top: i32 = 0, left: i32 = 0, right: i32 = 0, bottom: i32 = 0 };

pub fn insets(app: *App) Insets {
    app.mu.lockUncancelable(clock.io());
    const tabline_visible = app.ui.tabline_visible;
    app.mu.unlock(clock.io());
    const c = chrome.insets(app, tabline_visible);
    return .{ .top = c.top, .left = c.left, .right = c.right, .bottom = c.bottom };
}

/// A relayout the build asked for is under way: its own build must not ask
/// again.
var relayout_running = false;

/// Builds the UI layer from the state as it is now and hands it to the
/// renderer. Cheap when there is nothing to show.
pub fn rebuild(app: *App, request_frame: bool) void {
    var in: Inputs = undefined;
    var title_buf: [384]u8 = undefined;
    var title: []const u8 = "";
    {
        app.mu.lockUncancelable(clock.io());
        defer app.mu.unlock(clock.io());
        title = lifecycle.sessionTitle(&title_buf, app.title[0..app.title_len], app.session_name);
        in = .{
            .ui = app.ui,
            .fg = app.default_fg,
            .bg = app.default_bg,
            .scale = @max(1, @as(i32, @intFromFloat(app.scale))),
            .view = .{ .x = app.view_x_px, .y = app.view_y_px, .w = @intCast(app.drawable_w_px), .h = @intCast(app.drawable_h_px) },
            .win_w = @intCast(if (app.win_w_px != 0) app.win_w_px else app.drawable_w_px),
            .win_h = @intCast(if (app.win_h_px != 0) app.win_h_px else app.drawable_h_px),
            .cell_w = @intCast(app.cell_w_px),
            .cell_h = @intCast(app.cell_h_px),
            .anchor = app.msg_anchor,
            .pos = app.msg_pos,
            .ext_cmdline = app.ext_cmdline,
        };
    }
    if (in.cell_w == 0 or in.cell_h == 0 or in.view.w == 0) return;
    // Before Neovim has named its colors (a start still in progress) both
    // are 0: the progress text is drawn light on the dark ground.
    if (in.fg == in.bg) in.fg = 0xd8d8d8;
    // The chrome's share of the window follows the tab line coming and
    // going: the window is laid out again, which ends in a build of its own.
    const want = chrome.insets(app, in.ui.tabline_visible);
    if (want.top != in.view.y or want.left != in.view.x or in.win_w - in.view.w != want.left + want.right) {
        if (!relayout_running) {
            relayout_running = true;
            defer relayout_running = false;
            return seam.window.relayout();
        }
    }
    chrome.updateSpinner(app, app.tabline_cfg.agent_indicator and in.ui.tabline_visible and in.ui.anyWorking());
    const layer = &app.chrome_back;
    var b = Builder.begin(app, layer);
    chrome.build(app, &b, &.{
        .ui = &in.ui,
        .fg = in.fg,
        .bg = in.bg,
        .scale = in.scale,
        .view = in.view,
        .win_w = in.win_w,
        .win_h = in.win_h,
        .cell_w = in.cell_w,
        .cell_h = in.cell_h,
        .title = title,
    });
    buildMessages(app, &b, &in);
    buildCopyButtons(app, &b, &in);
    buildPreedit(app, &b, &in);
    if (app.progress.len != 0) {
        const size = labelSize(&b, &in, &.{app.progress});
        _ = label(&b, &in, in.view.x + @divTrunc(in.view.w - size[0], 2), in.view.y + @divTrunc(in.view.h - size[1], 2), &.{app.progress}, look(&in, 0));
    }
    b.end();

    app.mu.lockUncancelable(clock.io());
    const was_empty = app.chrome_layer.solid.items.len == 0 and app.chrome_layer.text.items.len == 0;
    std.mem.swap(ui_layer.Layer, &app.chrome_layer, &app.chrome_back);
    const is_empty = app.chrome_layer.solid.items.len == 0 and app.chrome_layer.text.items.len == 0;
    app.mu.unlock(clock.io());
    if (request_frame and !(was_empty and is_empty)) app.queueRenderGtk();
}
