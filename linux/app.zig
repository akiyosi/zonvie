//! All Linux frontend state. Core callbacks write it on the core thread;
//! the main thread reads it. `mu` guards everything both threads touch.

const std = @import("std");
const core = @import("zonvie_core");
const SurfaceStore = @import("surface_store.zig").SurfaceStore;
const Fonts = @import("renderer/font.zig").Fonts;
const scroll_ease = core.scroll_ease;
const overlay_layout = @import("overlay_layout.zig");
const ui_state = @import("ui_state.zig");
const ui_widgets = @import("ui.zig").ui_widgets;
const gl_renderer = @import("renderer/gl_renderer.zig");
const input = @import("ui.zig").input;
const ext_window = @import("ui.zig").ext_window;
const panel_popup = @import("ui.zig").panel_popup;
const ui = @import("ui.zig");
const ui_layer = @import("ui_layer.zig");
const postfx = @import("renderer/postfx.zig");
const scrollbar = @import("scrollbar.zig");
const window_size = @import("ui.zig").window_size;
const lifecycle = @import("lifecycle.zig");
const tray = @import("ui.zig").tray;

pub const AtlasUpload = struct { x: u32, y: u32, w: u32, h: u32, offset: usize };

/// Atlas work for the GL thread. Not transactional: an upload that returned
/// normally is cached by the core (zonvie_core.h on_atlas_upload), so a failed
/// flush must never drop it. Guarded by App.mu.
pub const AtlasOps = struct {
    /// Set by on_atlas_create; the GL side recreates a zeroed w x h texture
    /// before applying `uploads`.
    recreate: bool = false,
    /// Set with `recreate`, cleared when a flush commits. Until then the
    /// committed rows carry UVs of the texture being replaced, so the GL
    /// side keeps drawing them with that texture and applies nothing.
    held: bool = false,
    w: u32 = 0,
    h: u32 = 0,
    uploads: std.ArrayListUnmanaged(AtlasUpload) = .empty,
    /// RGBA8 pixels of `uploads`, back to back.
    pixels: std.ArrayListUnmanaged(u8) = .empty,
    /// The whole atlas as RGBA8, w*h*4. A GL context realized again starts
    /// with an empty texture; uploading this restores what the core caches.
    /// Anonymous pages (on_atlas_create), so a new atlas costs nothing
    /// until glyphs are written.
    mirror: []u8 = &.{},
    /// `mirror` is zero from this row down.
    dirty_rows: u32 = 0,
    /// Bumped by every create and upload; external windows resync from
    /// `mirror` when theirs differs.
    gen: u64 = 0,

    pub fn clearQueued(self: *AtlasOps) void {
        self.uploads.clearRetainingCapacity();
        self.pixels.clearRetainingCapacity();
    }

    pub fn unmapMirror(self: *AtlasOps) void {
        if (self.mirror.len != 0) _ = std.c.munmap(@ptrCast(@alignCast(self.mirror.ptr)), self.mirror.len);
        self.mirror = &.{};
    }

    pub fn deinit(self: *AtlasOps, alloc: std.mem.Allocator) void {
        self.uploads.deinit(alloc);
        self.pixels.deinit(alloc);
        self.unmapMirror();
    }
};

pub const FlushOutcome = enum(u8) { none, committed, aborted };

pub const App = struct {
    alloc: std.mem.Allocator,
    mu: std.Io.Mutex = .init,
    surface: SurfaceStore = .{},
    corep: ?*core.zonvie_core = null,

    cell_w_px: u32 = 0,
    /// Font cell height plus linespace, as sent to the core.
    cell_h_px: u32 = 0,
    linespace_px: i32 = 0,
    /// config.toml's [window]. Below 1 opacity, or with blur, the windows
    /// are translucent and the compositor blurs what shows through.
    window_cfg: core.config.Config.WindowConfig = .{},
    /// The desktop draws a titlebar for "native" (chrome.desktopDrawsTitlebar).
    /// Fixed at startup.
    desktop_titlebar: bool = true,
    /// config.toml [log] perf_only / scroll_only, applied to the core.
    log_perf_only: bool = false,
    log_scroll_only: bool = false,
    /// [cmdline] / [messages] copy_button.
    copy_cmdline: bool = true,
    copy_messages: bool = true,
    /// config.toml's [tabline].
    tabline_cfg: core.config.Config.TablineConfig = .{},
    /// ext_tabline is on (config.toml or --exttabline).
    ext_tabline: bool = false,
    /// ext_cmdline is on (config.toml or --extcmdline); without it Neovim
    /// draws its cmdline on the grid's last row.
    ext_cmdline: bool = false,
    /// config.toml's [scrollbar], and the main window's bar.
    scrollbar_cfg: core.config.Config.ScrollbarConfig = .{},
    scrollbar: scrollbar.State = .{},
    /// config.toml's [input].
    input_cfg: core.config.Config.InputConfig = .{},
    /// The editor font as the preedit label draws it: family and logical px.
    /// Written with the metrics under `mu`.
    preedit_family: [128]u8 = undefined,
    preedit_family_len: usize = 0,
    preedit_px: f32 = 0,
    /// The same for each per-grid font slot (on_font_slot_load), for a
    /// composition in a grid with its own font; px 0 while the slot is
    /// empty. Under `mu`.
    slot_preedit: [core.font_slots.max_slots]ui_widgets.PreeditFont = @splat(.{}),
    /// The size the font in use was loaded at, in points; under `mu`.
    font_pt: f32 = 0,
    /// What the global faces were loaded from (callbacks.fontRequestKey), 0
    /// for none. Core thread, or any thread before zonvie_core_start.
    font_request: u64 = 0,
    /// The next guifont broadcast is a font-dialog pick (font_picker.zig),
    /// which wins over an explicit [font] family and size.
    font_picked: std.atomic.Value(bool) = .init(false),
    /// The weight and slant of that pick (Pango: weight >= semibold, slant
    /// not normal), applied with it as the regular face's style.
    picked_bold: std.atomic.Value(bool) = .init(false),
    picked_italic: std.atomic.Value(bool) = .init(false),
    /// config.toml's [messages] msg_pos.
    msg_pos: core.config.Config.MsgPosConfig = .{},
    /// The core's message anchor (zonvie_core_msg_anchor); null before the
    /// first. Written under `mu` with each commit, on the core thread, so a
    /// frame drawn from it has both, and again by the main thread's idle
    /// that places the panels.
    msg_anchor: ?core.MsgAnchor = null,
    /// The confirm dialog's box in surface px while it shows; written by
    /// ui_widgets.placeMessages on the main thread under `mu`, read by the
    /// overlay layout wherever the frame is drawn.
    confirm_rect: ?overlay_layout.Rect = null,
    /// config.toml's [font]; `family` borrows the Config, which outlives the app.
    font_cfg: core.config.Config.FontConfig = .{},
    /// The window's size in device pixels and its integer scale factor; written by
    /// the main thread, read by the core thread, both under `mu`.
    drawable_w_px: u32 = 0,
    drawable_h_px: u32 = 0,
    scale: f32 = 1.0,
    default_fg: u32 = 0xffffff,
    default_bg: u32 = 0,
    /// Neovim-requested grid size, consumed by the window.
    requested_rows: u32 = 0,
    requested_cols: u32 = 0,
    /// The core-owned ext UI surfaces, by overlay_layout.Kind; written by
    /// on_external_window and its close, read by the paint.
    overlays: [4]overlay_layout.Surface = @splat(.{}),
    /// The cmdline panel where the user dropped it, for the rest of the
    /// session (overlay_layout.Inputs.cmdline_user). main thread writes, the
    /// paint reads; under `mu`.
    cmdline_user: ?overlay_layout.Rect = null,
    /// msg_show's pointer and pin (frontend_rules.MsgShowChrome) and the
    /// corner it is pinned at; reset when it closes. Under `mu`.
    msg_chrome: core.frontend_rules.MsgShowChrome = .{},
    msg_show_user: ?[2]i32 = null,
    /// The main view's panels are popup surfaces (panel_popup.zig), not
    /// drawn in the view. main thread writes, the paint reads; under `mu`.
    panel_popups: bool = false,
    /// The panels' popups by overlay_layout.Kind. Main thread.
    popups: [4]panel_popup.Popup = undefined,
    /// The frontend-drawn ext UI: messages, minis, the tabline.
    ui: ui_state.UiState = .{},
    /// Pmenu's background from on_popupmenu_show; the popupmenu panel's fill.
    pmenu_bg: u32 = 0,
    /// The cmdline's firstc from on_cmdline_show: '/' and '?' get the
    /// search icon, the rest the chevron.
    cmdline_firstc: u8 = 0,
    /// Search bg (the cmdline and popupmenu border) and Comment fg (the
    /// cmdline icon, the close badge's tint), as Windows and macOS colour
    /// them; read on the main thread when a cmdline shows and after a flush
    /// that follows a default-colour change, since a core callback cannot.
    cmdline_border_rgb: u32 = 0xffff00,
    cmdline_icon_rgb: u32 = 0x808080,
    panel_colors_queued: std.atomic.Value(bool) = .init(false),
    /// The default colours changed (a colourscheme, or Neovim's first
    /// redraw) and the panel colours are read again once the flush carrying
    /// the batch's highlight definitions has committed. Guarded by mu.
    panel_colors_stale: bool = false,
    /// config.scroll.large_jump_behavior; set before the core starts.
    large_jump: scroll_ease.LargeJumpBehavior = .snap,
    title: [256]u8 = undefined,
    title_len: usize = 0,
    exit_code: ?i32 = null,

    atlas_pending: AtlasOps = .{},

    /// The main window's GL objects; main thread only.
    gl: gl_renderer.Target = .{},
    /// The main window's bloom and custom shader chain; main thread only.
    postfx: postfx.PostFx = .{},
    /// config.toml [shaders] paths when enabled; borrowed from the config,
    /// which outlives the App.
    shader_paths: []const []const u8 = &.{},
    /// [shaders] preserve_alpha.
    shader_preserve_alpha: bool = false,
    /// iTime's origin for every window's shaders, and the clock cell-age
    /// stamps are taken on, so `iTime - stamp` is an age.
    shader_epoch_ns: i128 = 0,
    /// iCellAge mirrors (main and external windows); the core thread writes
    /// them from on_cell_age_stamps, each window's draw uploads its own.
    cell_age: core.cell_age_store.Stores = undefined,

    // Window-side state; written and read only on the main thread.
    /// The main window's input; set up with the window.
    pointer: input.Pointer = undefined,
    /// ext_windows by root grid id; main thread only.
    ext_windows: std.AutoHashMapUnmanaged(i64, *ext_window.ExtWindow) = .empty,
    /// An idle that applies `ext_ops` is queued.
    ext_idle_queued: std.atomic.Value(bool) = .init(false),
    /// Opens and closes the core queued (under `mu`), and the list the main
    /// thread's idle swaps them into, so neither side allocates while the other reads.
    ext_ops: std.ArrayListUnmanaged(ext_window.Op) = .empty,
    ext_ops_main: std.ArrayListUnmanaged(ext_window.Op) = .empty,
    /// Coalesces queue-render idles to at most one outstanding.
    render_idle_queued: std.atomic.Value(bool) = .init(false),
    /// on_quit_requested's argument, read by its idle.
    quit_has_unsaved: std.atomic.Value(bool) = .init(false),

    // Lifecycle (session.zig); main thread only.
    /// The close / quit-timeout state machine.
    quit: lifecycle.Quit = .{},
    /// Neovim drew its first frame: the window is shown (if it waited for
    /// that) and queued file opens are sent.
    nvim_ready: bool = false,
    /// The main window stays hidden until `nvim_ready` (SSH, --connect-nvim).
    show_when_ready: bool = false,
    /// Where this session's nvim runs; decides what an early exit shows.
    start_kind: lifecycle.StartKind = .local,
    /// stderr of the starting process, for the early-exit alert. Written
    /// from the core's stderr thread (its own lock).
    start_output: lifecycle.StartOutput = .{},
    /// Files handed over before nvim could take them, owned by `alloc`.
    pending_opens: std.ArrayListUnmanaged([:0]u8) = .empty,
    /// The connection dialog's "Name", else one from the connection
    /// (lifecycle.defaultSessionName), shown in the window title; borrowed
    /// from main's arena, which outlives the App.
    session_name: []const u8 = "",
    /// [server] close_to_tray, and the tray item when it registered.
    close_to_tray: bool = false,
    tray: tray.Tray = .{},

    // Window and input state; main thread only.
    preedit_active: bool = false,
    /// preedit_active, for the renderer, which may draw on another thread
    /// (input.setComposing writes both).
    ime_composing: std.atomic.Value(bool) = .init(false),
    /// Cursor blink phase; `visible` is read by the renderer under `mu`.
    cursor_blink: core.frontend_rules.Blink = .{},
    /// Last complete visible-grid snapshot for pointer hit tests; kept when
    /// the non-blocking query finds grid_mu busy.
    pointer_grids: [32]core.GridInfo = undefined,
    pointer_grids_len: usize = 0,

    /// core_timers.zig. main thread only.
    msg_timer: c_uint = 0,
    flush_retry_timer: c_uint = 0,
    flush_retry_delay_ms: c_uint = 16,
    /// What the flushes since core_timers last looked came to; the last one
    /// wins, since a commit after an abort carries the aborted rows.
    flush_outcome: std.atomic.Value(FlushOutcome) = .init(.none),

    // The flushing thread only: the core thread, or the main thread while a
    // core_timers tick runs a flush. grid_mu is held either way.
    flush_failed: bool = false,
    /// Between on_flush_begin and on_flush_end.
    in_flush: bool = false,
    /// Counts on_flush_begin, as the core counts its flushes, so render
    /// traces of both sides carry one id.
    trace_flush: u64 = 0,
    fonts: Fonts = .{},
    /// Per-grid fonts by font_id (on_font_slot_load); [0] is unused, the
    /// global font being `fonts`. Same discipline as `fonts`: touched only
    /// with grid_mu held.
    slot_fonts: [core.font_slots.max_slots]?*Fonts = @splat(null),

    clipboard_mu: std.Io.Mutex = .init,
    /// A get's whole text; out_len reports its full size (zonvie_core.h).
    clipboard_text: std.ArrayListUnmanaged(u8) = .empty,
    clipboard_result: c_int = 0,
    clipboard_ready: bool = false,
    /// [server] open_mode = "current": a single forwarded file replaces the
    /// current window instead of opening a tab.
    open_mode_current: bool = false,
    /// The notification server's ids per slot. Main thread.
    notify: ui.notify.State = .{},
    /// The toast and mini timers' sequence numbers, so a timer hides only
    /// the message that set it (shell.zig). Main thread.
    toast_timer_seq: u32 = 0,
    mini_timer_seq: u32 = 0,
    ui_idle_queued: std.atomic.Value(bool) = .init(false),
    /// The panel grid a copy button's press reads, the retries left while
    /// the core's lock is busy, and the panel whose button shows the check
    /// (shell.zig). Main thread.
    copy_grid: i64 = 0,
    copy_tries: u8 = 0,
    copied_kind: ?usize = null,
    /// The IME's composition while the core does not show it in the buffer:
    /// shell.zig draws it at the cursor. Main thread.
    preedit_text: [512]u8 = undefined,
    preedit_len: usize = 0,
    preedit_clause: [2]usize = .{ 0, 0 },
    /// The window's framebuffer, device px, and the editor view's top-left
    /// in it: the view is `drawable_w_px` x `drawable_h_px`, and the rest of
    /// the window is the UI layer's (title bar, tab strip). Under `mu`.
    win_w_px: u32 = 0,
    win_h_px: u32 = 0,
    view_x_px: i32 = 0,
    view_y_px: i32 = 0,
    /// What a slow start says in the middle of the window until Neovim
    /// draws (a static string; empty: nothing). Main thread.
    progress: []const u8 = "",
    /// The title bar, the tab strip and the menus (chrome.zig). Main thread.
    chrome: ui.chrome.State = .{},
    /// The UI layer the renderer draws (under `mu`), the one being built
    /// (main thread), and their glyphs (main thread). shell.zig.
    chrome_layer: ui_layer.Layer = .{},
    chrome_back: ui_layer.Layer = .{},
    ui_atlas: ui_layer.Atlas = .{},
    /// The cursor blink's one-shot timer (0: none) and its lock retry
    /// (blink.zig); main thread only.
    blink_timer: c_uint = 0,
    blink_retry_queued: bool = false,
    /// One of the app's windows has the keyboard focus. Main thread.
    app_active: bool = false,
    /// Bumped per clipboard operation; a completion whose seq is stale
    /// belongs to a caller that timed out and must not signal.
    clipboard_seq: u64 = 0,


    pub fn deinit(self: *App) void {
        self.surface.deinit(self.alloc);
        self.atlas_pending.deinit(self.alloc);
        self.gl.deinit(self.alloc);
        self.fonts.deinit(self.alloc);
        for (&self.slot_fonts) |*slot| {
            if (slot.*) |f| {
                f.deinit(self.alloc);
                self.alloc.destroy(f);
            }
            slot.* = null;
        }
        self.clipboard_text.deinit(self.alloc);
        self.ext_ops.deinit(self.alloc);
        self.ext_ops_main.deinit(self.alloc);
        self.chrome_layer.deinit(self.alloc);
        self.chrome_back.deinit(self.alloc);
        self.ui_atlas.deinit(self.alloc);
        self.cell_age.deinit();
        for (self.pending_opens.items) |p| self.alloc.free(p);
        self.pending_opens.deinit(self.alloc);
    }

    /// The main window draws its grid in a rounded card on a ground colour
    /// (Config.TitlebarLayout.island; the rest of the layout is
    /// linux/chrome.zig's). Fixed at startup.
    pub fn island(self: *const App) bool {
        return self.titlebarLayout().island();
    }

    /// No caption band: the editor reaches the window top under the band
    /// the window buttons reveal in (Config.TitlebarLayout.captionless).
    /// Fixed at startup.
    pub fn captionless(self: *const App) bool {
        return self.titlebarLayout().captionless();
    }

    /// The chrome's layout: the configured style as the desktop allows it
    /// (chrome.effectiveStyle). Fixed at startup.
    pub fn titlebarLayout(self: *const App) core.config.Config.TitlebarLayout {
        const Config = core.config.Config;
        const tabline: Config.TablinePlacement = if (!self.ext_tabline)
            .other
        else if (std.mem.eql(u8, self.tabline_cfg.style, "sidebar"))
            .sidebar
        else if (std.mem.eql(u8, self.tabline_cfg.style, "titlebar"))
            .titlebar
        else
            .other;
        return .{ .style = @import("ui.zig").chrome.effectiveStyle(self.window_cfg.titlebar_style, tabline, self.desktop_titlebar), .tabline = tabline };
    }

    /// main thread: every window draws the committed frame.
    pub fn translucent(self: *const App) bool {
        return self.window_cfg.opacity < 1.0 or self.window_cfg.blur;
    }

    pub fn queueRenderAll(self: *App) void {
        ui.window.queueRender(self);
    }
};
