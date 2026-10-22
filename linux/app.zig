//! All Linux frontend state. Core callbacks write it on the core thread;
//! the GTK main thread reads it. `mu` guards everything both threads touch.

const std = @import("std");
const core = @import("zonvie_core");
const SurfaceStore = @import("surface_store.zig").SurfaceStore;
const Fonts = @import("renderer/font.zig").Fonts;
const scroll_ease = core.scroll_ease;

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

pub const App = struct {
    alloc: std.mem.Allocator,
    mu: std.Io.Mutex = .init,
    surface: SurfaceStore = .{},
    corep: ?*core.zonvie_core = null,

    cell_w_px: u32 = 0,
    /// Font cell height plus linespace, as sent to the core.
    cell_h_px: u32 = 0,
    linespace_px: i32 = 0,
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
    /// config.scroll.large_jump_behavior; set before the core starts.
    large_jump: scroll_ease.LargeJumpBehavior = .snap,
    title: [256]u8 = undefined,
    title_len: usize = 0,
    exit_code: ?i32 = null,

    atlas_pending: AtlasOps = .{},

    // GL objects; GTK main thread only, valid between realize and unrealize.
    gl_program: u32 = 0,
    gl_vao: u32 = 0,
    gl_vbo: u32 = 0,
    gl_vbo_cap_bytes: usize = 0,
    gl_atlas_tex: u32 = 0,
    /// Size the GL texture was allocated at; 0 until the first atlas create lands.
    gl_atlas_w: u32 = 0,
    gl_atlas_h: u32 = 0,
    gl_u_scale: i32 = -1,
    gl_u_offset: i32 = -1,
    gl_u_scroll_offset: i32 = -1,
    gl_u_layer_origin_x: i32 = -1,
    /// One layer's rows concatenated for a single upload; capacity reused across frames.
    gl_scratch: std.ArrayListUnmanaged(core.Vertex) = .empty,

    // GTK objects; written and read only on the GTK main thread.
    gl_area: ?*anyopaque = null,
    window: ?*anyopaque = null,
    gtk_app: ?*anyopaque = null,
    im_context: ?*anyopaque = null,
    /// A frame-clock tick callback is installed and redraws every frame
    /// while some grid eases.
    ease_tick_active: bool = false,
    /// Coalesces queue-render idles to at most one outstanding.
    render_idle_queued: std.atomic.Value(bool) = .init(false),
    /// on_quit_requested's argument, read by its idle.
    quit_has_unsaved: std.atomic.Value(bool) = .init(false),

    // Window and input state; GTK main thread only.
    /// main.zig's Startup, alive for the whole GTK run.
    startup: ?*anyopaque = null,
    gl_realized_once: bool = false,
    layout_ready_sent: bool = false,
    layout_retry_queued: bool = false,
    start_failed: bool = false,
    preedit_active: bool = false,
    /// Logical widget px of the last pointer motion; the wheel has no position.
    pointer_x: f64 = 0,
    pointer_y: f64 = 0,
    /// Button held since a press, and the grid that press chose.
    held_button: ?[*:0]const u8 = null,
    press_grid_id: i64 = 1,
    drag_row: i32 = -1,
    drag_col: i32 = -1,
    /// Last complete visible-grid snapshot for pointer hit tests; kept when
    /// the non-blocking query finds grid_mu busy.
    pointer_grids: [32]core.GridInfo = undefined,
    pointer_grids_len: usize = 0,

    // Core thread only.
    flush_failed: bool = false,
    fonts: Fonts = .{},
    foreign_surface_logged: bool = false,

    clipboard_mu: std.Io.Mutex = .init,
    /// A get's whole text; out_len reports its full size (zonvie_core.h).
    clipboard_text: std.ArrayListUnmanaged(u8) = .empty,
    clipboard_result: c_int = 0,
    clipboard_ready: bool = false,
    /// Bumped per clipboard operation; a GTK completion whose seq is stale
    /// belongs to a caller that timed out and must not signal.
    clipboard_seq: u64 = 0,

    pub fn deinit(self: *App) void {
        self.surface.deinit(self.alloc);
        self.atlas_pending.deinit(self.alloc);
        self.gl_scratch.deinit(self.alloc);
        self.fonts.deinit(self.alloc);
        self.clipboard_text.deinit(self.alloc);
    }
};
