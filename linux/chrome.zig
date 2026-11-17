//! The window's chrome, by `[window] titlebar_style` and the tabline's
//! placement (core.config.Config.TitlebarLayout): a header holding the title
//! or the titlebar tabs, a title band, or no caption at all with the window
//! buttons revealed over the top band; the tab strip along the header or
//! down a sidebar; the app menu (New Session, About, Quit) and, for
//! `[tabline] style = "menu"`, the Tabs menu. All of it is drawn into the UI
//! layer (shell.zig) and acts through the layer's hit regions. Main thread.

const std = @import("std");
const core = @import("zonvie_core");
const clock = core.clock;
const rules = core.frontend_rules;
const Config = core.config.Config;
const App = @import("app.zig").App;
const glib = @import("glib.zig");
const ui_state = @import("ui_state.zig");
const ui_layer = @import("ui_layer.zig");
const lifecycle = @import("lifecycle.zig");
const seam = @import("ui.zig");
const Builder = ui_layer.Builder;
const Rect = ui_layer.Rect;

/// What sits where the desktop's titlebar would.
pub const Header = enum {
    /// The desktop's own titlebar (titlebar_style = "native" without
    /// titlebar tabs): nothing is drawn in its place. A sidebar's toggle and
    /// the menus go on a rail beside it, the menu tab style's menus in a bar
    /// over the editor.
    desktop,
    /// A bar of the titlebar tabs, the menus and the window buttons in the
    /// caption's place.
    header_bar,
    /// No caption: the editor reaches the window top; the window buttons
    /// and a drag bar show after the pointer rests in the top band.
    captionless,
    /// A band above the editor with the title in the editor's colours; with
    /// a sidebar it spans the window, the sidebar's toggle in its corner.
    title_band,
};

/// The header's colours.
pub const Tint = enum { theme, ground, editor_bg };

pub const Plan = struct {
    header: Header,
    /// The header holds the tab strip.
    tabs_in_header: bool,
    tint: Tint,
};

/// The chrome `layout` yields, as the table on Config.TitlebarLayout says.
/// Titlebar tabs take the caption's place on the card's ground, or in the
/// editor's bg without a card.
pub fn plan(layout: Config.TitlebarLayout) Plan {
    if (layout.tabline == .titlebar) return .{
        .header = .header_bar,
        .tabs_in_header = true,
        .tint = if (layout.island()) .ground else .editor_bg,
    };
    if (layout.captionless()) return .{ .header = .captionless, .tabs_in_header = false, .tint = .editor_bg };
    if (layout.titleBand()) return .{ .header = .title_band, .tabs_in_header = false, .tint = .ground };
    return .{ .header = .desktop, .tabs_in_header = false, .tint = .theme };
}

test "the chrome follows the titlebar layout table" {
    const P = Config.TablinePlacement;
    const S = Config.TitlebarStyle;
    const at = struct {
        fn f(s: S, t: P) Plan {
            return plan(.{ .style = s, .tabline = t });
        }
    }.f;
    try std.testing.expectEqual(Plan{ .header = .header_bar, .tabs_in_header = true, .tint = .ground }, at(.native, .titlebar));
    try std.testing.expectEqual(Plan{ .header = .header_bar, .tabs_in_header = true, .tint = .editor_bg }, at(.hidden, .titlebar));
    try std.testing.expectEqual(Plan{ .header = .header_bar, .tabs_in_header = true, .tint = .ground }, at(.unified, .titlebar));
    try std.testing.expectEqual(Plan{ .header = .desktop, .tabs_in_header = false, .tint = .theme }, at(.native, .sidebar));
    try std.testing.expectEqual(Header.captionless, at(.hidden, .sidebar).header);
    try std.testing.expectEqual(Header.captionless, at(.hidden, .other).header);
    try std.testing.expectEqual(Header.title_band, at(.unified, .sidebar).header);
    try std.testing.expectEqual(Header.title_band, at(.unified, .other).header);
    try std.testing.expectEqual(Header.desktop, at(.native, .other).header);
}

/// The top band of a captionless window, logical px: where the window
/// buttons reveal and the drag bar shows.
pub const band_pt = 32;

/// Desktops that draw no titlebar for a client that asks for one (tiling
/// compositors that grant server-side decorations and draw only a border).
/// `xdg_current_desktop` is $XDG_CURRENT_DESKTOP, a colon-separated list.
pub fn desktopDrawsTitlebar(xdg_current_desktop: ?[]const u8) bool {
    const list = xdg_current_desktop orelse return true;
    var it = std.mem.splitScalar(u8, list, ':');
    while (it.next()) |name| {
        for ([_][]const u8{ "Hyprland", "niri", "river" }) |bare|
            if (std.ascii.eqlIgnoreCase(name, bare)) return false;
    }
    return true;
}

/// The style the chrome follows: "native" asks for the desktop's titlebar,
/// and where the desktop draws none the window gets "hidden"'s caption (and
/// its edge-to-edge editor) rather than no caption at all. Titlebar tabs
/// draw their own bar and keep "native".
pub fn effectiveStyle(style: Config.TitlebarStyle, tabline: Config.TablinePlacement, desktop_titlebar: bool) Config.TitlebarStyle {
    if (style == .native and tabline != .titlebar and !desktop_titlebar) return .hidden;
    return style;
}

test "native falls back to hidden where the desktop draws no titlebar" {
    try std.testing.expect(!desktopDrawsTitlebar("Hyprland"));
    try std.testing.expect(!desktopDrawsTitlebar("ubuntu:niri"));
    try std.testing.expect(desktopDrawsTitlebar("KDE"));
    try std.testing.expect(desktopDrawsTitlebar("ubuntu:GNOME"));
    try std.testing.expect(desktopDrawsTitlebar("sway"));
    try std.testing.expect(desktopDrawsTitlebar(null));
    try std.testing.expectEqual(Config.TitlebarStyle.hidden, effectiveStyle(.native, .sidebar, false));
    try std.testing.expectEqual(Config.TitlebarStyle.hidden, effectiveStyle(.native, .other, false));
    try std.testing.expectEqual(Config.TitlebarStyle.native, effectiveStyle(.native, .titlebar, false));
    try std.testing.expectEqual(Config.TitlebarStyle.native, effectiveStyle(.native, .sidebar, true));
    try std.testing.expectEqual(Config.TitlebarStyle.unified, effectiveStyle(.unified, .sidebar, false));
}

// =========================================================================
// State
// =========================================================================

/// The header bar's and the title band's height, logical px.
pub const header_pt = 36;
/// A window button's box, logical px.
const button_pt = 30;
/// The sidebar's width handle, logical px.
const handle_pt = 5;
/// How long the pointer rests in a captionless window's top band before the
/// window buttons and the drag bar show.
const reveal_ms = 2000;
const spinner_interval_ms = 120;
const drag_threshold_px = 6;
/// How far off the strip, across it, a dragged tab is let go to become a
/// window of its own.
const tear_off_pt = 48;

/// What a hit region of the chrome does (ui_layer.Hit.id). Above shell.zig's.
pub const Id = enum(u32) {
    drag_area = 100,
    win_close,
    win_max,
    win_min,
    /// `arg`: the tab's index.
    tab,
    tab_close,
    tab_new,
    sidebar_toggle,
    sidebar_handle,
    menu_app,
    menu_tabs,
    /// `arg`: the item (Item).
    menu_item,
    /// Anywhere outside an open menu: closes it.
    menu_backdrop,
    _,
};

const Menu = enum { none, app, tabs };

/// Menu items past the tabs' own (`select_tab_base + index`).
const Item = struct {
    const new_session = 0;
    const about = 1;
    const quit = 2;
    const new_tab = 3;
    const close_tab = 4;
    const select_tab_base = 100;
};

pub const State = struct {
    /// The sidebar is slid in.
    sidebar_shown: bool = true,
    /// Its width, logical px; 0 until the config's is taken.
    sidebar_w_pt: i32 = 0,
    menu: Menu = .none,
    /// Where the open menu hangs from: its button's bottom-left, window px.
    menu_at: [2]i32 = .{ 0, 0 },
    /// Captionless: the window buttons and the drag bar are shown.
    revealed: bool = false,
    reveal_timer: c_uint = 0,
    spinner_frame: u32 = 0,
    spinner_timer: c_uint = 0,
    /// The region under the pointer, for its highlight.
    hot: ?ui_layer.Hit = null,
    /// A left press on a tab: where, and whether it has become a reorder.
    tab_drag: ?TabDrag = null,
    /// A press on the sidebar's handle: the width and the pointer then.
    handle_drag: ?struct { from_w: i32, from_x: i32 } = null,
    /// The tabs as last drawn, along the strip, window px: a drop finds its
    /// index among them.
    tab_starts: [ui_state.tab_cap]i32 = undefined,
    tab_ends: [ui_state.tab_cap]i32 = undefined,
    tab_n: usize = 0,
    /// When the header's drag area was last pressed, for the double click
    /// that maximizes.
    last_drag_press_ns: i128 = 0,
};

const TabDrag = struct { from: u32, start: [2]i32, reorder: bool = false, at: [2]i32 = .{ 0, 0 } };

// =========================================================================
// Layout
// =========================================================================

fn sidebarStyle(app: *const App) bool {
    return app.ext_tabline and std.mem.eql(u8, app.tabline_cfg.style, "sidebar");
}

fn menuStyle(app: *const App) bool {
    return app.ext_tabline and std.mem.eql(u8, app.tabline_cfg.style, "menu");
}

fn sidebarRight(app: *const App) bool {
    return std.mem.eql(u8, app.tabline_cfg.sidebar_position, "right");
}

fn sidebarWidthPt(app: *App) i32 {
    if (app.chrome.sidebar_w_pt == 0) app.chrome.sidebar_w_pt = @intCast(app.tabline_cfg.sidebar_width);
    return app.chrome.sidebar_w_pt;
}

/// The frontend draws the window buttons: there is a header of its own, or
/// none at all.
fn ownButtons(p: Plan) bool {
    return p.header != .desktop;
}

/// What the chrome takes of the window around the editor view, device px.
/// `tabline_visible`: Neovim shows a tab line ('showtabline').
pub fn insets(app: *App, tabline_visible: bool) struct { top: i32, left: i32, right: i32, bottom: i32 } {
    const scale: i32 = @max(1, @as(i32, @intFromFloat(app.scale)));
    const p = plan(app.titlebarLayout());
    var top: i32 = 0;
    var left: i32 = 0;
    var right: i32 = 0;
    if (p.header == .header_bar or p.header == .title_band) top = header_pt * scale;
    // The menu tab style's bar over the editor, under a desktop's titlebar.
    if (p.header == .desktop and menuStyle(app)) top = header_pt * scale;
    if (sidebarStyle(app) and tabline_visible and app.chrome.sidebar_shown) {
        const w = sidebarWidthPt(app) * scale;
        if (sidebarRight(app)) right = w else left = w;
    }
    var bottom: i32 = 0;
    if (app.island()) {
        // The card's margin of ground, then its padding, on every side.
        // Titlebar tabs sit on the card's top edge, with no ground between.
        const pad = cardPaddingPx(app);
        const frame = rules.island_margin_pt * scale + pad;
        top += if (p.tabs_in_header and tabline_visible) pad else frame;
        left += frame;
        right += frame;
        bottom = frame;
    }
    return .{ .top = top, .left = left, .right = right, .bottom = bottom };
}

/// The editor's background between the card's edge and the view, device px.
pub fn cardPaddingPx(app: *const App) i32 {
    return rules.island_padding_pt * @max(1, @as(i32, @intFromFloat(app.scale)));
}

// =========================================================================
// Drawing
// =========================================================================

const Palette = struct {
    strip: [4]f32,
    header: [4]f32,
    text: [4]f32,
    text_selected: [4]f32,
    separator: [4]f32,
    hover: [4]f32,
    selected: [4]f32,
    close: [4]f32,
};

fn rgb3(c: u32) [3]f32 {
    return .{ @as(f32, @floatFromInt((c >> 16) & 0xff)) / 255.0, @as(f32, @floatFromInt((c >> 8) & 0xff)) / 255.0, @as(f32, @floatFromInt(c & 0xff)) / 255.0 };
}

fn op(c: [3]f32) [4]f32 {
    return .{ c[0], c[1], c[2], 1 };
}

/// `island`: the strip and a ground-tinted header take the card's ground.
fn palette(fg: u32, bg: u32, tint: Tint, island: bool) Palette {
    const b = rgb3(bg);
    const ground: ?[3]f32 = if (island) rules.oklabLightnessShifted(b, .island_ground) else null;
    const sb = rules.sidebarPalette(rgb3(fg), b, ground);
    return .{
        .strip = op(sb.bg),
        .header = if (tint == .editor_bg) op(b) else op(sb.bg),
        .text = op(sb.text),
        .text_selected = op(sb.text_selected),
        .separator = op(sb.separator),
        .hover = op(sb.hover),
        .selected = op(sb.selected),
        .close = op(sb.close),
    };
}

/// What a build reads of the app, taken by shell.zig under App.mu.
pub const Inputs = struct {
    ui: *const ui_state.UiState,
    fg: u32,
    bg: u32,
    scale: i32,
    view: Rect,
    win_w: i32,
    win_h: i32,
    cell_w: i32,
    cell_h: i32,
    title: []const u8,
};

fn isHot(app: *const App, id: Id, arg: i32) bool {
    const h = app.chrome.hot orelse return false;
    return h.id == @intFromEnum(id) and h.arg == arg;
}

/// A button: its glyph centred in `r`, washed while the pointer is on it.
fn button(app: *App, b: *Builder, in: *const Inputs, pal: *const Palette, r: Rect, glyph: []const u8, id: Id, arg: i32) void {
    if (isHot(app, id, arg)) b.rect(r, pal.hover);
    const w = b.textWidth(glyph);
    _ = b.text(r.x + @divTrunc(r.w - w, 2), r.y + @divTrunc(r.h - in.cell_h, 2), w, glyph, pal.text_selected, .{});
    b.hit(r, @intFromEnum(id), arg);
}

/// The window buttons, right-aligned in `band`; returns the x they start at.
fn windowButtons(app: *App, b: *Builder, in: *const Inputs, pal: *const Palette, band: Rect) i32 {
    const box = button_pt * in.scale;
    const y = band.y + @divTrunc(band.h - box, 2);
    var x = band.x + band.w - box - 2 * in.scale;
    button(app, b, in, pal, .{ .x = x, .y = y, .w = box, .h = box }, "\u{00d7}", .win_close, 0);
    x -= box;
    button(app, b, in, pal, .{ .x = x, .y = y, .w = box, .h = box }, if (seam.window.isMaximized()) "\u{29c9}" else "\u{25a1}", .win_max, 0);
    x -= box;
    button(app, b, in, pal, .{ .x = x, .y = y, .w = box, .h = box }, "\u{2212}", .win_min, 0);
    return x;
}

const claude_frames = [_][]const u8{ "\u{00b7}", "\u{2722}", "\u{2733}", "\u{2736}", "\u{273b}", "\u{273d}" };
const braille_frames = [_][]const u8{ "\u{280b}", "\u{2819}", "\u{2839}", "\u{2838}", "\u{283c}", "\u{2834}", "\u{2826}", "\u{2827}", "\u{2807}", "\u{280f}" };

/// The per-tab indicator for an agent state: a robot when done, a pause
/// sign while it waits for input, a spinner while it works.
pub fn indicatorGlyph(state: u8, frame: u32) []const u8 {
    return switch (state) {
        1 => "\u{1f916}",
        2 => claude_frames[frame % claude_frames.len],
        3 => braille_frames[frame % braille_frames.len],
        4 => "\u{23f8}",
        else => "",
    };
}

/// One line of a tab's label within `max_w`: `line` of its 'guitablabel'
/// chunks in their styles, or its name when no chunks came.
fn tabLine(b: *Builder, x: i32, y: i32, max_w: i32, t: *const ui_state.Tab, line: u8, fallback: [4]f32) void {
    if (t.label.line_count == 0) {
        if (line != 0) return;
        _ = b.text(x, y, max_w, if (t.name.len == 0) "[No Name]" else t.name.text(), fallback, .{});
        return;
    }
    var text: [ui_state.label_text_cap + 1]u8 = undefined;
    var spans: [core.tab_label.TabLabel.MAX_RUNS]ui_state.LabelSpan = undefined;
    const ll = ui_state.labelLines(&t.label, text[0 .. text.len - 1], &spans);
    const hl = core.highlight;
    var pen = x;
    for (ll.spans) |sp| {
        if (sp.line != line) continue;
        const left = max_w - (pen - x);
        if (left <= 0) break;
        const color: [4]f32 = if (sp.flags & hl.TAB_CHUNK_HAS_FG != 0) op(rgb3(sp.fg_rgb)) else fallback;
        const w = b.text(pen, y, left, ll.text[sp.start..sp.end], color, .{ .bold = sp.flags & hl.TAB_CHUNK_BOLD != 0, .italic = sp.flags & hl.TAB_CHUNK_ITALIC != 0 });
        if (sp.flags & hl.TAB_CHUNK_UNDERLINE != 0) b.rect(.{ .x = pen, .y = y + b.cell_h - 2, .w = w, .h = 1 }, color);
        if (sp.flags & hl.TAB_CHUNK_STRIKETHROUGH != 0) b.rect(.{ .x = pen, .y = y + @divTrunc(b.cell_h, 2), .w = w, .h = 1 }, color);
        pen += w;
    }
}

/// The tabs along `strip` (a header's part), each `tab_w` wide with its
/// indicator, first label line and close button, then "+".
fn headerTabs(app: *App, b: *Builder, in: *const Inputs, pal: *const Palette, strip: Rect, selected: [4]f32) void {
    const ui = in.ui;
    const st = &app.chrome;
    const plus_w = button_pt * in.scale;
    const count: i32 = @intCast(ui.tab_count);
    if (count == 0) return;
    const tw = rules.titlebarTabWidth(@divTrunc(strip.w - plus_w, in.scale), count, rules.tab_min_width_pt, rules.tab_max_width_pt) * in.scale;
    const pad = 8 * in.scale;
    var x = strip.x;
    st.tab_n = 0;
    for (ui.tabs[0..ui.tab_count], 0..) |*t, i| {
        if (x + tw > strip.x + strip.w - plus_w) break;
        const r: Rect = .{ .x = x, .y = strip.y + 3 * in.scale, .w = tw - 2 * in.scale, .h = strip.h - 3 * in.scale };
        const current = t.handle == ui.curtab;
        if (current) b.rect(r, selected) else if (isHot(app, .tab, @intCast(i))) b.rect(r, pal.hover);
        b.hit(r, @intFromEnum(Id.tab), @intCast(i));
        var tx = r.x + pad;
        const ty = r.y + @divTrunc(r.h - in.cell_h, 2);
        if (app.tabline_cfg.agent_indicator) {
            const g = indicatorGlyph(ui.agentState(t.handle), st.spinner_frame);
            if (g.len != 0) tx += b.text(tx, ty, r.w, g, pal.text_selected, .{}) + in.cell_w;
        }
        const close_w = in.cell_w * 2;
        tabLine(b, tx, ty, r.x + r.w - close_w - pad - tx, t, 0, if (current) pal.text_selected else pal.text);
        const cr: Rect = .{ .x = r.x + r.w - close_w - @divTrunc(pad, 2), .y = ty, .w = close_w, .h = in.cell_h };
        if (isHot(app, .tab_close, @intCast(i))) b.rect(cr, pal.hover);
        _ = b.text(cr.x + @divTrunc(cr.w - in.cell_w, 2), cr.y, cr.w, "\u{00d7}", pal.close, .{});
        b.hit(cr, @intFromEnum(Id.tab_close), @intCast(i));
        st.tab_starts[st.tab_n] = x;
        st.tab_ends[st.tab_n] = x + tw;
        st.tab_n += 1;
        x += tw;
    }
    button(app, b, in, pal, .{ .x = x, .y = strip.y + @divTrunc(strip.h - plus_w, 2), .w = plus_w, .h = plus_w }, "+", .tab_new, 0);
}

/// The tabs down the sidebar: a row each, with every label line when
/// [tabline] cards allows it, then "+".
fn sidebarTabs(app: *App, b: *Builder, in: *const Inputs, pal: *const Palette, area: Rect) void {
    const ui = in.ui;
    const st = &app.chrome;
    const pad = 8 * in.scale;
    var y = area.y + pad;
    st.tab_n = 0;
    for (ui.tabs[0..ui.tab_count], 0..) |*t, i| {
        const lines: i32 = if (app.tabline_cfg.cards and t.label.line_count != 0) @intCast(t.label.line_count) else 1;
        const row_h = lines * in.cell_h + pad;
        if (y + row_h > area.y + area.h) break;
        const r: Rect = .{ .x = area.x + @divTrunc(pad, 2), .y = y, .w = area.w - pad, .h = row_h };
        const current = t.handle == ui.curtab;
        if (current) b.rect(r, pal.selected) else if (isHot(app, .tab, @intCast(i))) b.rect(r, pal.hover);
        b.hit(r, @intFromEnum(Id.tab), @intCast(i));
        var tx = r.x + pad;
        const ty = r.y + @divTrunc(pad, 2);
        if (app.tabline_cfg.agent_indicator) {
            const g = indicatorGlyph(ui.agentState(t.handle), st.spinner_frame);
            if (g.len != 0) tx += b.text(tx, ty, r.w, g, pal.text_selected, .{}) + in.cell_w;
        }
        const close_w = in.cell_w * 2;
        var line: u8 = 0;
        while (line < lines) : (line += 1) {
            tabLine(b, tx, ty + @as(i32, line) * in.cell_h, r.x + r.w - close_w - pad - tx, t, line, if (current) pal.text_selected else pal.text);
        }
        const cr: Rect = .{ .x = r.x + r.w - close_w - @divTrunc(pad, 2), .y = ty, .w = close_w, .h = in.cell_h };
        if (isHot(app, .tab_close, @intCast(i))) b.rect(cr, pal.hover);
        _ = b.text(cr.x + @divTrunc(cr.w - in.cell_w, 2), cr.y, cr.w, "\u{00d7}", pal.close, .{});
        b.hit(cr, @intFromEnum(Id.tab_close), @intCast(i));
        st.tab_starts[st.tab_n] = y;
        st.tab_ends[st.tab_n] = y + row_h;
        st.tab_n += 1;
        y += row_h + 2 * in.scale;
    }
    const box = button_pt * in.scale;
    if (y + box <= area.y + area.h) button(app, b, in, pal, .{ .x = area.x + @divTrunc(pad, 2), .y = y, .w = box, .h = box }, "+", .tab_new, 0);
}

/// A menu's rows hanging from `at`: each a label and what pressing it does.
fn menuBox(app: *App, b: *Builder, in: *const Inputs, pal: *const Palette, labels: []const []const u8, items: []const i32) void {
    const pad = 10 * in.scale;
    var w: i32 = 0;
    for (labels) |l| w = @max(w, b.textWidth(l));
    const row_h = in.cell_h + pad;
    const at = app.chrome.menu_at;
    const box: Rect = .{ .x = @min(at[0], in.win_w - w - 2 * pad - in.scale), .y = at[1], .w = w + 2 * pad, .h = @as(i32, @intCast(labels.len)) * row_h + in.scale };
    // Anything else in the window closes the menu.
    b.hit(.{ .x = 0, .y = 0, .w = in.win_w, .h = in.win_h }, @intFromEnum(Id.menu_backdrop), 0);
    b.rect(box, pal.separator);
    b.rect(.{ .x = box.x + in.scale, .y = box.y + in.scale, .w = box.w - 2 * in.scale, .h = box.h - 2 * in.scale }, pal.strip);
    for (labels, items, 0..) |l, item, i| {
        const r: Rect = .{ .x = box.x + in.scale, .y = box.y + @as(i32, @intCast(i)) * row_h, .w = box.w - 2 * in.scale, .h = row_h };
        if (isHot(app, .menu_item, item)) b.rect(r, pal.hover);
        _ = b.text(r.x + pad, r.y + @divTrunc(pad, 2), w, l, pal.text_selected, .{});
        b.hit(r, @intFromEnum(Id.menu_item), item);
    }
}

/// The editor card (Config.TitlebarLayout.island): the ground around the
/// card, then its edge and rounded corners. The card's inside, the view and
/// the padding around it, is the renderer's (gl_renderer clearCardPadding).
fn card(app: *const App, b: *Builder, in: *const Inputs, pal: *const Palette) void {
    const s = in.scale;
    const pad = cardPaddingPx(app);
    const r = rules.island_radius_pt * s;
    const c: Rect = .{ .x = in.view.x - pad, .y = in.view.y - pad, .w = in.view.w + 2 * pad, .h = in.view.h + 2 * pad };
    const x1 = c.x + c.w;
    const y1 = c.y + c.h;
    const ground = pal.strip;
    b.rect(.{ .x = 0, .y = 0, .w = in.win_w, .h = c.y }, ground);
    b.rect(.{ .x = 0, .y = y1, .w = in.win_w, .h = in.win_h - y1 }, ground);
    b.rect(.{ .x = 0, .y = c.y, .w = c.x, .h = c.h }, ground);
    b.rect(.{ .x = x1, .y = c.y, .w = in.win_w - x1, .h = c.h }, ground);
    // The card's outermost device pixel, as the other frontends' shaders
    // draw it (Shaders.metal ps_island).
    const edge = op(rules.islandBorder(rgb3(in.bg)));
    b.rect(.{ .x = c.x + r, .y = c.y, .w = c.w - 2 * r, .h = 1 }, edge);
    b.rect(.{ .x = c.x + r, .y = y1 - 1, .w = c.w - 2 * r, .h = 1 }, edge);
    b.rect(.{ .x = c.x, .y = c.y + r, .w = 1, .h = c.h - 2 * r }, edge);
    b.rect(.{ .x = x1 - 1, .y = c.y + r, .w = 1, .h = c.h - 2 * r }, edge);
    const corners = [_]struct { centre: [2]i32, dir: [2]i32 }{
        .{ .centre = .{ c.x + r, c.y + r }, .dir = .{ -1, -1 } },
        .{ .centre = .{ x1 - r, c.y + r }, .dir = .{ 1, -1 } },
        .{ .centre = .{ c.x + r, y1 - r }, .dir = .{ -1, 1 } },
        .{ .centre = .{ x1 - r, y1 - r }, .dir = .{ 1, 1 } },
    };
    for (corners) |k| {
        b.corner(k.centre, k.dir, r, ground, 0);
        b.corner(k.centre, k.dir, r, edge, 1);
    }
}

/// Draws the chrome around `in.view` and its hit regions.
pub fn build(app: *App, b: *Builder, in: *const Inputs) void {
    const st = &app.chrome;
    const p = plan(app.titlebarLayout());
    const island = app.island();
    const pal = palette(in.fg, in.bg, p.tint, island);
    const tabs_shown = in.ui.tabline_visible;
    const scale = in.scale;
    const header_h = header_pt * scale;

    // Under everything else: the sidebar and the header are on its ground.
    if (island) card(app, b, in, &pal);

    // The sidebar: the strip's ground, its tabs, its toggle and width handle.
    if (sidebarStyle(app) and tabs_shown and st.sidebar_shown) {
        const w = sidebarWidthPt(app) * scale;
        const right = sidebarRight(app);
        const top: i32 = if (p.header == .title_band) header_h else 0;
        const area: Rect = .{ .x = if (right) in.win_w - w else 0, .y = top, .w = w, .h = in.win_h - top };
        b.rect(area, pal.strip);
        // On a card's ground the card's margin sets the sidebar apart.
        const edge_x = if (right) area.x else area.x + area.w - scale;
        if (!island) b.rect(.{ .x = edge_x, .y = area.y, .w = scale, .h = area.h }, pal.separator);
        sidebarTabs(app, b, in, &pal, area);
        const hw = handle_pt * scale;
        b.hit(.{ .x = if (right) area.x - @divTrunc(hw, 2) else area.x + area.w - @divTrunc(hw, 2), .y = area.y, .w = hw, .h = area.h }, @intFromEnum(Id.sidebar_handle), 0);
    }

    // The header: a bar with the tabs, or a band with the title.
    if (p.header == .header_bar or p.header == .title_band) {
        const band: Rect = .{ .x = 0, .y = 0, .w = in.win_w, .h = header_h };
        b.rect(band, pal.header);
        if (!island) b.rect(.{ .x = 0, .y = header_h - scale, .w = in.win_w, .h = scale }, pal.separator);
        b.hit(band, @intFromEnum(Id.drag_area), 0);
        const buttons_x = windowButtons(app, b, in, &pal, band);
        const box = button_pt * scale;
        const menu_r: Rect = .{ .x = buttons_x - box - 4 * scale, .y = @divTrunc(header_h - box, 2), .w = box, .h = box };
        button(app, b, in, &pal, menu_r, "\u{2261}", .menu_app, 0);
        var left = 4 * scale;
        if (sidebarStyle(app) and tabs_shown) {
            button(app, b, in, &pal, .{ .x = left, .y = @divTrunc(header_h - box, 2), .w = box, .h = box }, "\u{25e7}", .sidebar_toggle, 0);
            left += box + 4 * scale;
        }
        if (menuStyle(app)) {
            const label = "Tabs";
            const w = b.textWidth(label) + 16 * scale;
            button(app, b, in, &pal, .{ .x = left, .y = @divTrunc(header_h - box, 2), .w = w, .h = box }, label, .menu_tabs, 0);
            left += w + 4 * scale;
        }
        const tabs = p.tabs_in_header and tabs_shown;
        // On a card the current tab is the card's colour and reaches its top
        // edge, so the first tab starts clear of the card's corner.
        const joined = tabs and island;
        if (joined) left = @max(left, (rules.island_margin_pt + rules.island_radius_pt) * scale);
        const strip: Rect = .{ .x = left, .y = 0, .w = menu_r.x - left - 4 * scale, .h = if (joined) header_h else header_h - scale };
        if (tabs) {
            headerTabs(app, b, in, &pal, strip, if (joined) op(rgb3(in.bg)) else pal.selected);
        } else {
            const w = @min(b.textWidth(in.title), strip.w);
            _ = b.text(strip.x + @divTrunc(strip.w - w, 2), @divTrunc(header_h - in.cell_h, 2), strip.w, in.title, pal.text_selected, .{});
        }
    } else if (p.header == .desktop and menuStyle(app)) {
        // Under the desktop's titlebar: the app and Tabs menus in a bar.
        const band: Rect = .{ .x = 0, .y = 0, .w = in.win_w, .h = header_h };
        b.rect(band, pal.header);
        if (!island) b.rect(.{ .x = 0, .y = header_h - scale, .w = in.win_w, .h = scale }, pal.separator);
        const box = button_pt * scale;
        var x = 4 * scale;
        for ([_]struct { l: []const u8, id: Id }{ .{ .l = "Zonvie", .id = .menu_app }, .{ .l = "Tabs", .id = .menu_tabs } }) |m| {
            const w = b.textWidth(m.l) + 16 * scale;
            button(app, b, in, &pal, .{ .x = x, .y = @divTrunc(header_h - box, 2), .w = w, .h = box }, m.l, m.id, 0);
            x += w + 4 * scale;
        }
    } else if (p.header == .captionless) {
        // No caption: the top band drags the window once revealed, and the
        // window buttons sit over the editor's corner.
        if (st.revealed) {
            const band: Rect = .{ .x = in.view.x, .y = 0, .w = in.view.w, .h = band_pt * scale };
            const fg = rgb3(in.fg);
            b.rect(band, .{ fg[0] * 0.12, fg[1] * 0.12, fg[2] * 0.12, 0.12 });
            b.hit(band, @intFromEnum(Id.drag_area), 0);
            const x = windowButtons(app, b, in, &pal, band);
            const box = button_pt * scale;
            button(app, b, in, &pal, .{ .x = x - box, .y = @divTrunc(band.h - box, 2), .w = box, .h = box }, "\u{2261}", .menu_app, 0);
            if (sidebarStyle(app) and tabs_shown) button(app, b, in, &pal, .{ .x = band.x + 4 * scale, .y = @divTrunc(band.h - box, 2), .w = box, .h = box }, "\u{25e7}", .sidebar_toggle, 0);
        }
    }

    // A tab being moved: the line where it would land.
    if (st.tab_drag) |d| if (d.reorder and st.tab_n != 0 and !tornOff(app, d.at)) {
        const along = if (sidebarStyle(app)) d.at[1] else d.at[0];
        const idx = dropIndex(st, along);
        const pos = if (idx < st.tab_n) st.tab_starts[idx] else st.tab_ends[st.tab_n - 1];
        if (sidebarStyle(app)) {
            const w = sidebarWidthPt(app) * scale;
            b.rect(.{ .x = if (sidebarRight(app)) in.win_w - w else 0, .y = pos - scale, .w = w, .h = 2 * scale }, pal.text_selected);
        } else {
            b.rect(.{ .x = pos - scale, .y = 0, .w = 2 * scale, .h = header_h }, pal.text_selected);
        }
    };

    // The open menu, over everything.
    switch (st.menu) {
        .none => {},
        .app => menuBox(app, b, in, &pal, &.{ "New Session", "About Zonvie", "Quit" }, &.{ Item.new_session, Item.about, Item.quit }),
        .tabs => {
            var labels: [ui_state.tab_cap + 2][]const u8 = undefined;
            var items: [ui_state.tab_cap + 2]i32 = undefined;
            labels[0] = "New Tab";
            items[0] = Item.new_tab;
            labels[1] = "Close Tab";
            items[1] = Item.close_tab;
            var n: usize = 2;
            for (in.ui.tabs[0..in.ui.tab_count], 0..) |*t, i| {
                labels[n] = if (t.name.len == 0) "[No Name]" else t.name.text();
                items[n] = Item.select_tab_base + @as(i32, @intCast(i));
                n += 1;
            }
            menuBox(app, b, in, &pal, labels[0..n], items[0..n]);
        },
    }
}

/// The insertion index a drop at `along` (px along the strip) names: before
/// the first tab whose middle lies past it.
fn dropIndex(st: *const State, along: i32) u32 {
    for (0..st.tab_n) |i| {
        if (along < @divTrunc(st.tab_starts[i] + st.tab_ends[i], 2)) return @intCast(i);
    }
    return @intCast(st.tab_n);
}

// =========================================================================
// Pointer
// =========================================================================

fn command(app: *App, cmd: []const u8) void {
    const cp = app.corep orelse return;
    core.zonvie_core_send_command(cp, cmd.ptr, cmd.len);
}

fn tabCommand(app: *App, comptime fmt: []const u8, index: i32) void {
    var buf: [32]u8 = undefined;
    command(app, std.fmt.bufPrint(&buf, fmt, .{index + 1}) catch return);
}

/// A press on one of the chrome's regions, at (x, y) window px. `middle`: a
/// middle press, which closes a tab.
pub fn press(app: *App, hit: ui_layer.Hit, x: i32, y: i32, left: bool, middle: bool) void {
    const st = &app.chrome;
    const id: Id = @enumFromInt(hit.id);
    if (middle) {
        if (id == .tab) tabCommand(app, "{d}tabclose", hit.arg);
        return;
    }
    if (!left) return;
    const scale: i32 = @max(1, @as(i32, @intFromFloat(app.scale)));
    switch (id) {
        .drag_area => {
            // A second press within the double-click time maximizes.
            const now = clock.nowNs();
            if (now - st.last_drag_press_ns < 400 * std.time.ns_per_ms) {
                st.last_drag_press_ns = 0;
                seam.window.toggleMaximize();
            } else {
                st.last_drag_press_ns = now;
                seam.window.beginMove();
            }
        },
        .win_close => seam.window.closeWindow(),
        .win_max => seam.window.toggleMaximize(),
        .win_min => seam.window.minimize(),
        .tab => {
            tabCommand(app, "{d}tabnext", hit.arg);
            st.tab_drag = .{ .from = @intCast(hit.arg), .start = .{ x, y } };
        },
        .tab_close => tabCommand(app, "{d}tabclose", hit.arg),
        .tab_new => command(app, "tabnew"),
        .sidebar_toggle => {
            st.sidebar_shown = !st.sidebar_shown;
            seam.window.relayout();
        },
        .sidebar_handle => st.handle_drag = .{ .from_w = sidebarWidthPt(app), .from_x = x },
        .menu_app, .menu_tabs => {
            const want: Menu = if (id == .menu_app) .app else .tabs;
            st.menu = if (st.menu == want) .none else want;
            st.menu_at = .{ hit.rect.x, hit.rect.y + hit.rect.h + scale };
        },
        .menu_backdrop => st.menu = .none,
        .menu_item => {
            st.menu = .none;
            switch (hit.arg) {
                Item.new_session => seam.window.openNewSession(),
                Item.about => seam.window.showAbout(),
                Item.quit => seam.window.quitApp(),
                Item.new_tab => command(app, "tabnew"),
                Item.close_tab => command(app, "tabclose"),
                else => if (hit.arg >= Item.select_tab_base) tabCommand(app, "{d}tabnext", hit.arg - Item.select_tab_base),
            }
        },
        _ => {},
    }
    seam.window.rebuildChrome();
}

/// The pointer moved to (x, y) window px. Returns whether the chrome holds
/// a press of its own, so the editor under it gets nothing.
pub fn motion(app: *App, x: i32, y: i32, hit: ?ui_layer.Hit) bool {
    const st = &app.chrome;
    const scale: i32 = @max(1, @as(i32, @intFromFloat(app.scale)));
    if (st.handle_drag) |d| {
        // The handle follows the pointer's whole travel, within the bounds
        // the config's own width has.
        const dx = @divTrunc(x - d.from_x, scale);
        const w = std.math.clamp(d.from_w + (if (sidebarRight(app)) -dx else dx), 100, 500);
        if (w != st.sidebar_w_pt) {
            st.sidebar_w_pt = w;
            seam.window.relayout();
        }
        return true;
    }
    if (st.tab_drag) |*d| {
        if (!d.reorder and @abs(x - d.start[0]) < drag_threshold_px * scale and @abs(y - d.start[1]) < drag_threshold_px * scale) return true;
        d.reorder = true;
        d.at = .{ x, y };
        seam.window.rebuildChrome();
        return true;
    }
    const same = if (st.hot) |h| (if (hit) |n| h.id == n.id and h.arg == n.arg else false) else hit == null;
    if (!same) {
        st.hot = hit;
        seam.window.rebuildChrome();
    }
    // Captionless: the pointer resting in the top band reveals the window
    // buttons and the drag bar; leaving it hides them again.
    if (plan(app.titlebarLayout()).header == .captionless) {
        const in_band = y >= 0 and y < band_pt * scale;
        if (in_band and !st.revealed and st.reveal_timer == 0) {
            st.reveal_timer = glib.g_timeout_add(reveal_ms, &onReveal, app);
        } else if (!in_band) {
            cancelReveal(app);
        }
    }
    return false;
}

fn onReveal(data: ?*anyopaque) callconv(.c) c_int {
    const app: *App = @ptrCast(@alignCast(data.?));
    app.chrome.reveal_timer = 0;
    app.chrome.revealed = true;
    seam.window.rebuildChrome();
    return 0;
}

fn cancelReveal(app: *App) void {
    const st = &app.chrome;
    if (st.reveal_timer != 0) {
        _ = glib.g_source_remove(st.reveal_timer);
        st.reveal_timer = 0;
    }
    if (st.revealed and st.menu == .none) {
        st.revealed = false;
        seam.window.rebuildChrome();
    }
}

/// The pointer left the window.
pub fn leave(app: *App) void {
    cancelReveal(app);
    if (app.chrome.hot != null) {
        app.chrome.hot = null;
        seam.window.rebuildChrome();
    }
}

/// The left button was let go. Returns whether the chrome held the press.
pub fn release(app: *App) bool {
    const st = &app.chrome;
    if (st.handle_drag != null) {
        st.handle_drag = null;
        return true;
    }
    const d = st.tab_drag orelse return false;
    st.tab_drag = null;
    if (d.reorder) {
        if (app.corep) |cp| {
            const side = sidebarStyle(app);
            if (tornOff(app, d.at)) {
                // Let go away from the strip: the tab's window becomes an
                // external one (refused by Neovim for a tab with a split).
                core.zonvie_core_externalize_tab(cp, d.from);
            } else {
                // Selects the dragged tab and moves it in one command;
                // nothing for a drop onto its own slot.
                _ = core.zonvie_core_tab_move(cp, d.from, dropIndex(st, if (side) d.at[1] else d.at[0]), @intCast(st.tab_n));
            }
        }
        seam.window.rebuildChrome();
    }
    return true;
}

/// The drop point `at` (window px) is off the tab strip by more than
/// `tear_off_pt` across it.
fn tornOff(app: *App, at: [2]i32) bool {
    const scale: i32 = @max(1, @as(i32, @intFromFloat(app.scale)));
    const far = tear_off_pt * scale;
    if (!sidebarStyle(app)) return at[1] > header_pt * scale + far;
    const w = sidebarWidthPt(app) * scale;
    if (sidebarRight(app)) return at[0] < @as(i32, @intCast(app.win_w_px)) - w - far;
    return at[0] > w + far;
}

/// Runs the spinner while some agent works. Called with each build's state.
pub fn updateSpinner(app: *App, working: bool) void {
    const st = &app.chrome;
    if (working and st.spinner_timer == 0) {
        st.spinner_timer = glib.g_timeout_add(spinner_interval_ms, &onSpinner, app);
    } else if (!working and st.spinner_timer != 0) {
        _ = glib.g_source_remove(st.spinner_timer);
        st.spinner_timer = 0;
    }
}

fn onSpinner(data: ?*anyopaque) callconv(.c) c_int {
    const app: *App = @ptrCast(@alignCast(data.?));
    app.chrome.spinner_frame +%= 1;
    seam.window.rebuildChrome();
    return 1;
}

test "a drop names the slot before the first tab whose middle lies past it" {
    var st: State = .{};
    st.tab_n = 3;
    st.tab_starts[0] = 0;
    st.tab_ends[0] = 100;
    st.tab_starts[1] = 100;
    st.tab_ends[1] = 200;
    st.tab_starts[2] = 200;
    st.tab_ends[2] = 300;
    try std.testing.expectEqual(@as(u32, 0), dropIndex(&st, -5));
    try std.testing.expectEqual(@as(u32, 0), dropIndex(&st, 49));
    try std.testing.expectEqual(@as(u32, 1), dropIndex(&st, 50));
    try std.testing.expectEqual(@as(u32, 2), dropIndex(&st, 199));
    try std.testing.expectEqual(@as(u32, 3), dropIndex(&st, 250));
    try std.testing.expectEqual(@as(u32, 3), dropIndex(&st, 10_000));
}

test "the indicator spins only while an agent works" {
    try std.testing.expectEqualStrings("", indicatorGlyph(0, 3));
    try std.testing.expectEqualStrings(indicatorGlyph(1, 0), indicatorGlyph(1, 5));
    try std.testing.expect(!std.mem.eql(u8, indicatorGlyph(2, 0), indicatorGlyph(2, 1)));
    try std.testing.expectEqualStrings(indicatorGlyph(3, 0), indicatorGlyph(3, braille_frames.len));
}
