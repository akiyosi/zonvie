//! All Linux frontend state. Core callbacks write it on the core thread;
//! the GTK main thread reads it. `mu` guards everything both threads touch.

const std = @import("std");
const core = @import("zonvie_core");
const SurfaceStore = @import("surface_store.zig").SurfaceStore;
const Fonts = @import("renderer/font.zig").Fonts;
const scroll_ease = core.scroll_ease;
const overlay_layout = @import("overlay_layout.zig");
const ui_state = @import("ui_state.zig");
const ui_widgets = @import("ui_widgets.zig");
const gl_renderer = @import("renderer/gl_renderer.zig");
const input = @import("input.zig");
const ext_window = @import("ext_window.zig");
const panel_popup = @import("panel_popup.zig");
const gtk = @import("gtk_bindings.zig");
const render_thread = @import("render_thread.zig");
const postfx = @import("renderer/postfx.zig");
const scrollbar = @import("scrollbar.zig");
const window_size = @import("window_size.zig");
const lifecycle = @import("lifecycle.zig");
const tray = @import("tray.zig");

pub const AtlasUpload = struct { x: u32, y: u32, w: u32, h: u32, offset: usize };

/// Atlas work for the GL thread. Not transactional: an upload that returned
/// normally is cached by the core (zonvie_core.h on_atlas_upload), so a failed
/// flush must never drop it. Guarded by App.mu.
pub const AtlasOps = struct {
    /// Set by on_atlas_create; the GL side recreates a zeroed w x h texture
    /// before applying `uploads`.
    recreate: bool = false,
    w: u32 = 0,
    h: u32 = 0,
    uploads: std.ArrayListUnmanaged(AtlasUpload) = .empty,
    /// RGBA8 pixels of `uploads`, back to back.
    pixels: std.ArrayListUnmanaged(u8) = .empty,
    /// The whole atlas as RGBA8, w*h*4. A GL context realized again starts
    /// with an empty texture; uploading this restores what the core caches.
    mirror: std.ArrayListUnmanaged(u8) = .empty,
    /// Bumped by every create and upload; external windows resync from
    /// `mirror` when theirs differs.
    gen: u64 = 0,

    pub fn clearQueued(self: *AtlasOps) void {
        self.uploads.clearRetainingCapacity();
        self.pixels.clearRetainingCapacity();
    }

    pub fn deinit(self: *AtlasOps, alloc: std.mem.Allocator) void {
        self.uploads.deinit(alloc);
        self.pixels.deinit(alloc);
        self.mirror.deinit(alloc);
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
    /// [server] open_mode = "current": a single forwarded file replaces the
    /// current window instead of opening a tab.
    open_mode_current: bool = false,
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
    /// The notification server's ids per slot. GTK main thread.
    notify: @import("notify.zig").State = .{},
    /// The grid the cursor last moved to (on_cursor_grid_changed).
    cursor_grid_focus: i64 = 1,
    /// The main window's size against the cell grid. GTK main thread.
    window_size: window_size.State = .{},
    /// ext_cmdline is on (config.toml or --extcmdline); without it Neovim
    /// draws its cmdline on the grid's last row.
    ext_cmdline: bool = false,
    /// config.toml's [scrollbar], and the main window's bar.
    scrollbar_cfg: core.config.Config.ScrollbarConfig = .{},
    scrollbar: scrollbar.State = .{},
    scrollbar_retry_queued: bool = false,
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
    /// The next guifont broadcast is a font-dialog pick (font_picker.zig),
    /// which wins over an explicit [font] family and size.
    font_picked: std.atomic.Value(bool) = .init(false),
    /// The weight and slant of that pick (Pango: weight >= semibold, slant
    /// not normal), applied with it as the regular face's style.
    picked_bold: std.atomic.Value(bool) = .init(false),
    picked_italic: std.atomic.Value(bool) = .init(false),
    /// config.toml's [messages] msg_pos.
    msg_pos: core.config.Config.MsgPosConfig = .{},
    /// The core's message anchor as of the last committed flush; null before
    /// the first (zonvie_core_msg_anchor). Written on the GTK main thread
    /// under `mu`.
    msg_anchor: ?core.MsgAnchor = null,
    /// The confirm dialog's box in surface px while it shows; written by
    /// ui_widgets.placeMessages on the GTK thread under `mu`, read by the
    /// overlay layout wherever the frame is drawn.
    confirm_rect: ?overlay_layout.Rect = null,
    /// config.toml's [font]; `family` borrows the Config, which outlives the app.
    font_cfg: core.config.Config.FontConfig = .{},
    /// GLArea size in device pixels and its integer scale factor; written by
    /// the GTK thread, read by the core thread, both under `mu`.
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
    /// session (overlay_layout.Inputs.cmdline_user). GTK thread writes, the
    /// paint reads; under `mu`.
    cmdline_user: ?overlay_layout.Rect = null,
    /// msg_show's pointer and pin (frontend_rules.MsgShowChrome) and the
    /// corner it is pinned at; reset when it closes. Under `mu`.
    msg_chrome: core.frontend_rules.MsgShowChrome = .{},
    msg_show_user: ?[2]i32 = null,
    /// The main view's panels are popup surfaces (panel_popup.zig), not
    /// drawn in the view. GTK thread writes, the paint reads; under `mu`.
    panel_popups: bool = false,
    /// The width of the output the main window is on, device px; 0 until
    /// known (panel_popup.noteMonitor). Under `mu`.
    monitor_w_px: u32 = 0,
    /// The frontend-drawn ext UI: messages, minis, the tabline.
    ui: ui_state.UiState = .{},
    /// Pmenu's background from on_popupmenu_show; the popupmenu panel's fill.
    pmenu_bg: u32 = 0,
    /// The cmdline's firstc from on_cmdline_show: '/' and '?' get the
    /// search icon, the rest the chevron.
    cmdline_firstc: u8 = 0,
    /// Search bg (the cmdline and popupmenu border) and Comment fg (the
    /// cmdline icon, the close badge's tint), as Windows and macOS colour
    /// them; read on the GTK thread when a cmdline shows and after a flush
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

    /// The main GLArea's GL objects; GTK main thread only.
    gl: gl_renderer.Target = .{},
    /// The main GLArea's bloom and custom shader chain; GTK main thread only.
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
    /// Bumped by every committed flush (under `mu`), so a frame can say
    /// which commit it shows.
    flush_seq: u64 = 0,
    /// flush_seq of the frame the main window last handed to GTK; GTK main
    /// thread only.
    presented_seq: u64 = 0,
    /// When presented_seq last moved, for the latency bench's breakdown.
    presented_ns: i128 = 0,

    // GTK objects; written and read only on the GTK main thread.
    gl_area: ?*anyopaque = null,
    /// Set when the render thread draws the main window instead of a GLArea.
    render_thread: ?*render_thread.RenderThread = null,
    /// The widget whose frame clock paces the main window: the GLArea, or
    /// the picture the render thread's frames are shown in.
    frame_widget: ?*anyopaque = null,
    window: ?*anyopaque = null,
    gtk_app: ?*anyopaque = null,
    /// The main window's input; set up with the window.
    pointer: input.Pointer = undefined,
    /// The panel popups, by overlay_layout.Kind; GTK main thread only.
    popups: [4]?*panel_popup.Popup = @splat(null),
    /// ext_windows by root grid id; GTK main thread only.
    ext_windows: std.AutoHashMapUnmanaged(i64, *ext_window.ExtWindow) = .empty,
    /// Opens and closes the core queued (under `mu`), and the list the GTK
    /// idle swaps them into, so neither side allocates while the other reads.
    ext_ops: std.ArrayListUnmanaged(ext_window.Op) = .empty,
    ext_ops_gtk: std.ArrayListUnmanaged(ext_window.Op) = .empty,
    ext_idle_queued: std.atomic.Value(bool) = .init(false),
    /// A torn-off tab's drop point for the next external window (X11 only;
    /// x11_place). GTK main thread only.
    ext_placement: core.frontend_rules.PlacementMemory = .{},
    /// Bumped by every :restart / reconnect (on_restart, on_connect): grid
    /// ids restart with the server. GTK main thread.
    session_generation: u64 = 0,
    /// A frame-clock tick callback is installed and redraws every frame
    /// while some grid eases.
    ease_tick_active: bool = false,
    widgets: ui_widgets.Widgets = .{},
    /// ui_widgets' copy of `ui`, taken under `mu` and applied without it.
    ui_snapshot: ui_widgets.SnapshotStorage = undefined,
    /// NUL-terminated label text, sized for the largest ui_state buffer.
    ui_text_scratch: [4097]u8 = undefined,
    /// The toast_seq a hide timer is pending for.
    toast_timer_seq: u32 = 0,
    /// The mini_seq a hide timer is pending for.
    mini_timer_seq: u32 = 0,
    ui_idle_queued: std.atomic.Value(bool) = .init(false),
    /// Coalesces queue-render idles to at most one outstanding.
    render_idle_queued: std.atomic.Value(bool) = .init(false),
    /// on_quit_requested's argument, read by its idle.
    quit_has_unsaved: std.atomic.Value(bool) = .init(false),

    // Lifecycle (session.zig); GTK main thread only.
    /// The close / quit-timeout state machine.
    quit: lifecycle.Quit = .{},
    /// The armed quit timeout's source id, 0 when none.
    quit_timer: c_uint = 0,
    /// Set while `devcontainer up` runs before the core starts; cancelling
    /// it abandons the start (the `up` itself keeps running, as on macOS
    /// and Windows).
    dc_up_cancel: ?*anyopaque = null,
    /// Neovim drew its first frame: the window is shown (if it waited for
    /// that) and queued file opens are sent.
    nvim_ready: bool = false,
    /// The main window stays hidden until `nvim_ready` (SSH, --connect-nvim).
    show_when_ready: bool = false,
    /// Where this session's nvim runs; decides what an early exit shows.
    start_kind: lifecycle.StartKind = .local,
    /// The timeout that shows a hidden start's window with its progress
    /// (lifecycle.connect_reveal_ms); 0 when none is armed.
    reveal_timer: c_uint = 0,
    /// stderr of the starting process, for the early-exit alert. Written
    /// from the core's stderr thread (its own lock).
    start_output: lifecycle.StartOutput = .{},
    /// Files handed over before nvim could take them, owned by `alloc`.
    pending_opens: std.ArrayListUnmanaged([:0]u8) = .empty,
    /// The connection dialog's "Name", else one from the connection
    /// (lifecycle.defaultSessionName), shown in the window title; borrowed
    /// from main's arena, which outlives the App.
    session_name: []const u8 = "",
    /// The main window is minimized or suspended (occluded).
    window_hidden: bool = false,
    /// [server] close_to_tray, and the tray item when it registered.
    close_to_tray: bool = false,
    tray: tray.Tray = .{},

    // Window and input state; GTK main thread only.
    /// main.zig's Startup, alive for the whole GTK run.
    startup: ?*anyopaque = null,
    gl_realized_once: bool = false,
    layout_ready_sent: bool = false,
    layout_retry_queued: bool = false,
    start_failed: bool = false,
    preedit_active: bool = false,
    /// preedit_active, for the renderer, which may draw on another thread
    /// (input.setComposing writes both).
    ime_composing: std.atomic.Value(bool) = .init(false),
    /// Cursor blink phase; `visible` is read by the renderer under `mu`.
    cursor_blink: core.frontend_rules.Blink = .{},
    /// GTK main thread only, as are the fields below (blink.zig).
    blink_timer: c_uint = 0,
    blink_retry_queued: bool = false,
    /// Some window of the app has focus.
    app_active: bool = false,
    active_idle_queued: bool = false,
    /// Last complete visible-grid snapshot for pointer hit tests; kept when
    /// the non-blocking query finds grid_mu busy.
    pointer_grids: [32]core.GridInfo = undefined,
    pointer_grids_len: usize = 0,

    /// core_timers.zig. GTK main thread only.
    msg_timer: c_uint = 0,
    flush_retry_timer: c_uint = 0,
    flush_retry_delay_ms: c_uint = 16,
    /// What the flushes since core_timers last looked came to; the last one
    /// wins, since a commit after an abort carries the aborted rows.
    flush_outcome: std.atomic.Value(FlushOutcome) = .init(.none),

    // The flushing thread only: the core thread, or the GTK thread while a
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
    /// Bumped per clipboard operation; a GTK completion whose seq is stale
    /// belongs to a caller that timed out and must not signal.
    clipboard_seq: u64 = 0,

    /// on_win_move_cursor's answer from the GTK thread (X11 only), as the
    /// clipboard's: the core thread polls `win_find_ready` under
    /// `win_find_mu`; an answer whose seq is stale is dropped.
    win_find_mu: std.Io.Mutex = .init,
    win_find_ready: bool = false,
    win_find_result: i64 = 0,
    win_find_seq: u64 = 0,

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
        self.ext_ops_gtk.deinit(self.alloc);
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

    fn titlebarLayout(self: *const App) core.config.Config.TitlebarLayout {
        const Config = core.config.Config;
        const tabline: Config.TablinePlacement = if (!self.ext_tabline)
            .other
        else if (std.mem.eql(u8, self.tabline_cfg.style, "sidebar"))
            .sidebar
        else if (std.mem.eql(u8, self.tabline_cfg.style, "titlebar"))
            .titlebar
        else
            .other;
        return .{ .style = self.window_cfg.titlebar_style, .tabline = tabline };
    }

    /// GTK main thread: every window draws the committed frame.
    pub fn translucent(self: *const App) bool {
        return self.window_cfg.opacity < 1.0 or self.window_cfg.blur;
    }

    pub fn queueRenderAll(self: *App) void {
        if (self.render_thread) |rt| rt.request();
        if (self.gl_area) |a| gtk.gtk_gl_area_queue_render(a);
        var it = self.ext_windows.valueIterator();
        while (it.next()) |w| if (w.*.area) |a| gtk.gtk_gl_area_queue_render(a);
        panel_popup.queueRender(self);
    }
};
