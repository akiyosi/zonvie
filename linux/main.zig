// main.zig — Entry point for Zonvie Linux frontend.
//
// GTK4 application lifecycle: parse args, load config, create window + GLArea,
// connect signals, start core, run GTK main loop.
//
// Uses zig-gobject for GTK4 types, hand-written extern declarations for
// GTK C functions not covered by zig-gobject's generated API, and
// hand-written GL bindings (linux/gl.zig).

const std = @import("std");
const app_mod = @import("app.zig");
const App = app_mod.App;
const gtk_mod = app_mod.gtk_mod;
const applog = app_mod.applog;
const builtin = @import("builtin");
const config_mod = app_mod.config_mod;
const callbacks = @import("callbacks.zig");
const input = @import("input.zig");
const gl_renderer = @import("renderer/gl_renderer.zig");
const ft_renderer = @import("renderer/ft_renderer.zig");
const core = @import("zonvie_core");

pub const std_options = std.Options{
    .log_level = .debug,
    .enable_segfault_handler = true,
};

// =========================================================================
// GTK C function declarations (for functions not available via zig-gobject)
//
// These are resolved at link time via libgtk-4. Declaring them here avoids
// @cImport of gtk/gtk.h, enabling cross-compilation from macOS.
// =========================================================================

extern "c" fn gtk_application_new(application_id: [*:0]const u8, flags: c_uint) ?*anyopaque;
extern "c" fn gtk_application_window_new(application: *anyopaque) ?*anyopaque;
extern "c" fn gtk_window_set_title(window: *anyopaque, title: [*:0]const u8) void;
extern "c" fn gtk_window_set_default_size(window: *anyopaque, width: c_int, height: c_int) void;
extern "c" fn gtk_window_set_child(window: *anyopaque, child: ?*anyopaque) void;
extern "c" fn gtk_window_present(window: *anyopaque) void;
extern "c" fn gtk_gl_area_new() ?*anyopaque;
extern "c" fn gtk_gl_area_set_required_version(area: *anyopaque, major: c_int, minor: c_int) void;
extern "c" fn gtk_gl_area_make_current(area: *anyopaque) void;
extern "c" fn gtk_gl_area_get_error(area: *anyopaque) ?*anyopaque;
extern "c" fn gtk_widget_get_width(widget: *anyopaque) c_int;
extern "c" fn gtk_widget_get_height(widget: *anyopaque) c_int;
extern "c" fn gtk_widget_get_scale_factor(widget: *anyopaque) c_int;
extern "c" fn gtk_widget_set_focusable(widget: *anyopaque, focusable: c_int) void;
extern "c" fn gtk_widget_set_can_focus(widget: *anyopaque, can_focus: c_int) void;
extern "c" fn gtk_widget_grab_focus(widget: *anyopaque) c_int;
extern "c" fn gtk_widget_add_controller(widget: *anyopaque, controller: *anyopaque) void;
extern "c" fn gtk_widget_queue_draw(widget: *anyopaque) void;
extern "c" fn gtk_gl_area_queue_render(area: *anyopaque) void;
extern "c" fn gtk_event_controller_key_new() ?*anyopaque;
extern "c" fn gtk_event_controller_motion_new() ?*anyopaque;
extern "c" fn gtk_event_controller_scroll_new(flags: c_uint) ?*anyopaque;
extern "c" fn gtk_gesture_click_new() ?*anyopaque;
extern "c" fn gtk_im_context_reset(context: *anyopaque) void;
extern "c" fn g_signal_connect_data(instance: *anyopaque, detailed_signal: [*:0]const u8, c_handler: *const anyopaque, data: ?*anyopaque, destroy_data: ?*anyopaque, connect_flags: c_uint) c_ulong;
extern "c" fn g_application_run(application: *anyopaque, argc: c_int, argv: ?*anyopaque) c_int;
extern "c" fn g_application_quit(application: *anyopaque) void;
extern "c" fn g_object_unref(object: *anyopaque) void;
extern "c" fn gtk_css_provider_new() ?*anyopaque;
extern "c" fn gtk_css_provider_load_from_string(provider: *anyopaque, css: [*:0]const u8) void;
extern "c" fn gtk_style_context_add_provider_for_display(display: *anyopaque, provider: *anyopaque, priority: c_uint) void;
extern "c" fn gtk_widget_get_display(widget: *anyopaque) ?*anyopaque;
extern "c" fn gtk_widget_add_css_class(widget: *anyopaque, css_class: [*:0]const u8) void;
extern "c" fn gtk_im_multicontext_new() ?*anyopaque;
extern "c" fn gtk_event_controller_key_set_im_context(controller: *anyopaque, im_context: *anyopaque) void;

// Layout widgets
extern "c" fn gtk_box_new(orientation: c_int, spacing: c_int) ?*anyopaque;
extern "c" fn gtk_box_append(box: *anyopaque, child: *anyopaque) void;
extern "c" fn gtk_overlay_new() ?*anyopaque;
extern "c" fn gtk_overlay_set_child(overlay: *anyopaque, child: *anyopaque) void;
extern "c" fn gtk_overlay_add_overlay(overlay: *anyopaque, widget: *anyopaque) void;
extern "c" fn gtk_label_new(text: [*:0]const u8) ?*anyopaque;
extern "c" fn gtk_label_set_text(label: *anyopaque, text: [*:0]const u8) void;
extern "c" fn gtk_widget_set_visible(widget: *anyopaque, visible: c_int) void;
extern "c" fn gtk_widget_set_halign(widget: *anyopaque, align_val: c_int) void;
extern "c" fn gtk_widget_set_valign(widget: *anyopaque, align_val: c_int) void;
extern "c" fn gtk_widget_set_margin_end(widget: *anyopaque, margin: c_int) void;
extern "c" fn gtk_widget_set_margin_bottom(widget: *anyopaque, margin: c_int) void;
extern "c" fn gtk_widget_set_vexpand(widget: *anyopaque, expand: c_int) void;
extern "c" fn gtk_widget_set_hexpand(widget: *anyopaque, expand: c_int) void;
extern "c" fn gtk_button_new_with_label(label: [*:0]const u8) ?*anyopaque;
extern "c" fn gtk_widget_set_size_request(widget: *anyopaque, width: c_int, height: c_int) void;
extern "c" fn gtk_im_context_set_cursor_location(context: *anyopaque, area: *const GdkRectangle) void;
extern "c" fn gtk_im_context_get_preedit_string(context: *anyopaque, str: *?[*:0]u8, attrs: *?*anyopaque, cursor_pos: *c_int) void;
extern "c" fn gtk_widget_set_margin_start(widget: *anyopaque, margin: c_int) void;
extern "c" fn gtk_widget_set_margin_top(widget: *anyopaque, margin: c_int) void;
extern "c" fn gtk_label_set_markup(label: *anyopaque, markup: [*:0]const u8) void;
extern "c" fn pango_attr_list_unref(list: *anyopaque) void;

pub const GdkRectangle = extern struct {
    x: c_int = 0,
    y: c_int = 0,
    width: c_int = 0,
    height: c_int = 0,
};

// GTK event controller scroll flags
const GTK_EVENT_CONTROLLER_SCROLL_VERTICAL: c_uint = 1 << 2;
const GTK_EVENT_CONTROLLER_SCROLL_DISCRETE: c_uint = 1 << 3;

// GApplication flags
const G_APPLICATION_DEFAULT_FLAGS: c_uint = 0;

// =========================================================================
// Public GTK extern declarations (used by callbacks.zig via @import)
// =========================================================================

pub const gtk_externs = struct {
    pub const widget_queue_draw = gtk_gl_area_queue_render;
    pub const application_quit = g_application_quit;
    pub const im_context_reset = gtk_im_context_reset;
    pub const css_provider_load_from_string = gtk_css_provider_load_from_string;
    pub const label_set_text = gtk_label_set_text;
    pub const widget_set_visible = gtk_widget_set_visible;
    pub const box_append = gtk_box_append;
    pub const button_new_with_label = gtk_button_new_with_label;
    pub const widget_set_size_request = gtk_widget_set_size_request;
    pub const im_context_set_cursor_location = gtk_im_context_set_cursor_location;
    pub const im_context_get_preedit_string = gtk_im_context_get_preedit_string;
    pub const widget_set_margin_start = gtk_widget_set_margin_start;
    pub const widget_set_margin_top = gtk_widget_set_margin_top;
    pub const label_set_markup = gtk_label_set_markup;
    pub const attr_list_unref = pango_attr_list_unref;
};

/// Custom panic handler for debug builds.
pub fn panic(
    msg: []const u8,
    error_return_trace: ?*std.builtin.StackTrace,
    ret_addr: ?usize,
) noreturn {
    @branchHint(.cold);
    _ = error_return_trace;

    if (builtin.mode != .Debug) {
        std.debug.defaultPanic(msg, ret_addr);
    }

    std.debug.print("\n=== ZONVIE PANIC (Debug Build) ===\n", .{});
    std.debug.print("Panic: {s}\n", .{msg});
    if (ret_addr) |addr| {
        std.debug.print("Return address: 0x{x}\n", .{addr});
    }
    // Print stack trace
    const trace = @returnAddress();
    var it = std.debug.StackIterator.init(trace, null);
    var i: usize = 0;
    while (it.next()) |addr| {
        std.debug.print("  [{d}] 0x{x}\n", .{ i, addr });
        i += 1;
        if (i >= 20) break;
    }

    if (applog.isEnabled()) {
        applog.appLog("\n=== ZONVIE PANIC (Debug Build) ===\n", .{});
        applog.appLog("Panic: {s}\n", .{msg});
    }

    std.process.abort();
}

// =========================================================================
// GTK signal handlers
// =========================================================================

/// GLArea "realize" signal: GL context is ready, initialize renderer.
fn onRealize(widget: ?*anyopaque, user_data: ?*anyopaque) callconv(.c) void {
    const app: *App = @ptrCast(@alignCast(user_data orelse return));
    const gl_area = widget orelse return;

    gtk_gl_area_make_current(gl_area);

    if (gtk_gl_area_get_error(gl_area) != null) {
        applog.appLog("[linux] GLArea has error on realize\n", .{});
        return;
    }

    if (!gl_renderer.init(app)) {
        applog.appLog("[linux] Failed to initialize GL renderer\n", .{});
        return;
    }

    // Get initial DPI scale
    app.dpi_scale = @floatFromInt(@max(1, gtk_widget_get_scale_factor(gl_area)));

    if (applog.isEnabled()) {
        applog.appLog("[linux] GLArea realized, dpi_scale={d:.2}\n", .{app.dpi_scale});
    }

    // Start core after renderer is ready
    startCore(app);
}

/// GLArea "render" signal: called each frame.
fn onRender(area: ?*anyopaque, context: ?*anyopaque, user_data: ?*anyopaque) callconv(.c) c_int {
    _ = context;
    _ = area;
    const app: *App = @ptrCast(@alignCast(user_data orelse return 1));

    const gl_area = app.gl_area orelse return 1;
    const width = gtk_widget_get_width(gl_area);
    const height = gtk_widget_get_height(gl_area);

    _ = gl_renderer.render(app, width, height);
    return 1; // TRUE
}

/// GLArea "resize" signal: window size changed.
fn onResize(area: ?*anyopaque, width: c_int, height: c_int, user_data: ?*anyopaque) callconv(.c) void {
    _ = area;
    const app: *App = @ptrCast(@alignCast(user_data orelse return));

    if (width <= 0 or height <= 0) return;

    const w: u32 = @intCast(width);
    const h: u32 = @intCast(height);

    app.drawable_w_px = w;
    app.drawable_h_px = h;

    if (applog.isEnabled()) {
        applog.appLog("[linux] Resize: {d}x{d}\n", .{ w, h });
    }

    // Update core layout (cell height includes linespace, matching Windows behavior)
    const ch: u32 = @max(1, app.cell_h_px + app.linespace_px);
    if (app.corep != null and app.cell_w_px > 0 and ch > 0) {
        app_mod.zonvie_core_update_layout_px(
            app.corep,
            w,
            h,
            app.cell_w_px,
            ch,
        );
        callbacks.updateScreenCols(app);

        // For sub-cell resizes (drawable pixels changed but rows/cols didn't),
        // updateLayoutPx won't trigger a Neovim resize or flush.
        // Force a resize with current rows/cols to get a redraw with new NDC coords.
        const rows = @max(@as(u32, 1), h / ch);
        const cols = @max(@as(u32, 1), w / app.cell_w_px);
        app_mod.zonvie_core_resize(app.corep, rows, cols);
    }

    // Mark that GL resources need rebuild on next render (GL context not current here)
    app.gl_needs_resize = true;

    // Force full repaint
    app.tbs.pending_paint_full = true;
    if (app.gl_area) |gl_area| {
        gtk_externs.widget_queue_draw(gl_area);
    }
}

/// GtkApplication "activate" signal: create the main window.
fn onActivate(gapp: ?*anyopaque, user_data: ?*anyopaque) callconv(.c) void {
    const app: *App = @ptrCast(@alignCast(user_data orelse return));
    app.gtk_app = gapp orelse return;
    app_mod.g_app = app;

    // Create main window
    const win = gtk_application_window_new(gapp.?) orelse return;
    app.main_window = win;
    gtk_window_set_title(win, "zonvie (linux)");
    gtk_window_set_default_size(win, 1000, 700);

    // Create GLArea
    const gl_area = gtk_gl_area_new() orelse return;
    app.gl_area = gl_area;

    // Request OpenGL 4.5 core profile
    gtk_gl_area_set_required_version(gl_area, 4, 5);

    // Set GLArea CSS background to black to prevent window-color flicker during resize.
    // The css_provider is saved on App so onDefaultColorsSet can update it dynamically.
    gtk_widget_add_css_class(gl_area, "zonvie-gl");
    if (gtk_css_provider_new()) |css_provider| {
        gtk_css_provider_load_from_string(css_provider,
            \\.zonvie-gl { background-color: black; }
            \\.zonvie-mini { background-color: rgba(30,30,30,0.85); color: #cccccc;
            \\  padding: 2px 8px; border-radius: 4px; font-family: monospace; font-size: 12px; }
            \\.zonvie-tabbar { background-color: #1e1e1e; padding: 2px; }
            \\.zonvie-tabbar button { padding: 4px 12px; border-radius: 4px; min-width: 60px;
            \\  font-family: monospace; font-size: 12px; }
            \\.zonvie-tabbar button.current { background-color: #333333; color: #ffffff; }
            \\.zonvie-tabbar button:not(.current) { background-color: transparent; color: #888888; }
            \\.zonvie-preedit { background-color: rgba(40,40,40,0.95); color: #ffffff;
            \\  padding: 1px 2px; font-family: monospace; border-bottom: 2px solid #4488ff; }
        );
        if (gtk_widget_get_display(gl_area)) |display| {
            gtk_style_context_add_provider_for_display(display, css_provider, 800);
        }
        app.css_provider = css_provider;
    }

    // Connect GLArea signals
    _ = g_signal_connect_data(gl_area, "realize", @ptrCast(&onRealize), app, null, 0);
    _ = g_signal_connect_data(gl_area, "render", @ptrCast(&onRender), app, null, 0);
    _ = g_signal_connect_data(gl_area, "resize", @ptrCast(&onResize), app, null, 0);

    // Build widget hierarchy:
    //   GtkWindow → GtkBox(v) → [tab_bar_box, GtkOverlay → [GLArea, mini_label]]
    const vbox = gtk_box_new(1, 0) orelse return; // GTK_ORIENTATION_VERTICAL
    gtk_window_set_child(win, vbox);

    // Tab bar (initially hidden)
    const tab_bar_box = gtk_box_new(0, 2) orelse return; // GTK_ORIENTATION_HORIZONTAL
    gtk_widget_set_visible(tab_bar_box, 0);
    gtk_widget_add_css_class(tab_bar_box, "zonvie-tabbar");
    gtk_box_append(vbox, tab_bar_box);
    app.tab_bar_box = tab_bar_box;

    // Overlay container for GLArea + mini label
    const overlay = gtk_overlay_new() orelse return;
    gtk_widget_set_vexpand(overlay, 1);
    gtk_widget_set_hexpand(overlay, 1);
    gtk_box_append(vbox, overlay);

    // GLArea as main overlay child
    gtk_overlay_set_child(overlay, gl_area);

    // Mini label (showmode/showcmd/ruler) at bottom-right
    const mini_label = gtk_label_new("") orelse return;
    gtk_widget_set_halign(mini_label, 2); // GTK_ALIGN_END
    gtk_widget_set_valign(mini_label, 2); // GTK_ALIGN_END
    gtk_widget_set_margin_end(mini_label, 8);
    gtk_widget_set_margin_bottom(mini_label, 4);
    gtk_widget_add_css_class(mini_label, "zonvie-mini");
    gtk_overlay_add_overlay(overlay, mini_label);
    app.mini_label = mini_label;

    // Preedit label (IME composition text at cursor position)
    const preedit_label = gtk_label_new("") orelse return;
    gtk_widget_set_halign(preedit_label, 0); // GTK_ALIGN_START
    gtk_widget_set_valign(preedit_label, 0); // GTK_ALIGN_START
    gtk_widget_add_css_class(preedit_label, "zonvie-preedit");
    gtk_widget_set_visible(preedit_label, 0);
    gtk_overlay_add_overlay(overlay, preedit_label);
    app.preedit_label = preedit_label;
    app.preedit_overlay = overlay;

    // Set up IME context
    const im_context = gtk_im_multicontext_new();
    if (im_context) |im| {
        app.im_context = im;
        _ = g_signal_connect_data(im, "commit", @ptrCast(&input.onIMECommit), app, null, 0);
        _ = g_signal_connect_data(im, "preedit-changed", @ptrCast(&input.onIMEPreeditChanged), app, null, 0);
    }

    // Set up keyboard input
    const key_controller = gtk_event_controller_key_new() orelse return;
    _ = g_signal_connect_data(key_controller, "key-pressed", @ptrCast(&input.onKeyPressed), app, null, 0);
    if (im_context) |im| {
        gtk_event_controller_key_set_im_context(key_controller, im);
    }
    gtk_widget_add_controller(gl_area, key_controller);

    // Set up mouse input
    const click_gesture = gtk_gesture_click_new() orelse return;
    _ = g_signal_connect_data(click_gesture, "pressed", @ptrCast(&input.onMousePressed), app, null, 0);
    _ = g_signal_connect_data(click_gesture, "released", @ptrCast(&input.onMouseReleased), app, null, 0);
    gtk_widget_add_controller(gl_area, click_gesture);

    const motion_controller = gtk_event_controller_motion_new() orelse return;
    _ = g_signal_connect_data(motion_controller, "motion", @ptrCast(&input.onMouseMotion), app, null, 0);
    gtk_widget_add_controller(gl_area, motion_controller);

    // Set up scroll input
    const scroll_controller = gtk_event_controller_scroll_new(
        GTK_EVENT_CONTROLLER_SCROLL_VERTICAL | GTK_EVENT_CONTROLLER_SCROLL_DISCRETE,
    ) orelse return;
    _ = g_signal_connect_data(scroll_controller, "scroll", @ptrCast(&input.onScroll), app, null, 0);
    gtk_widget_add_controller(gl_area, scroll_controller);

    // Make GLArea focusable (for keyboard input)
    gtk_widget_set_focusable(gl_area, 1);
    gtk_widget_set_can_focus(gl_area, 1);

    // Connect window close-request for quit handling
    _ = g_signal_connect_data(win, "close-request", @ptrCast(&onCloseRequest), app, null, 0);

    // Show window
    gtk_window_present(win);

    // Grab focus on GLArea
    _ = gtk_widget_grab_focus(gl_area);
}

/// Window close-request signal handler.
fn onCloseRequest(win: ?*anyopaque, user_data: ?*anyopaque) callconv(.c) c_int {
    _ = win;
    const app: *App = @ptrCast(@alignCast(user_data orelse return 1));
    if (app.corep) |corep| {
        app_mod.zonvie_core_request_quit(corep);
    }
    return 1; // TRUE: prevent default close (core will call on_exit or on_quit_requested)
}

// =========================================================================
// Core startup
// =========================================================================

fn startCore(app: *App) void {
    var cb: core.Callbacks = .{
        .on_vertices = callbacks.onVertices,
        .on_vertices_partial = callbacks.onVerticesPartial,
        .on_vertices_row = callbacks.onVerticesRow,
        .on_atlas_ensure_glyph = callbacks.onAtlasEnsureGlyph,
        .on_atlas_ensure_glyph_styled = callbacks.onAtlasEnsureGlyphStyled,
        .on_render_plan = callbacks.onRenderPlan,
        .on_log = callbacks.onLog,
        .on_guifont = callbacks.onGuiFont,
        .on_linespace = callbacks.onLineSpace,
        .on_exit = callbacks.onExit,
        .on_default_colors_set = callbacks.onDefaultColorsSet,
        .on_set_title = callbacks.onSetTitle,
        .on_external_window = callbacks.onExternalWindow,
        .on_external_window_close = callbacks.onExternalWindowClose,
        .on_external_vertices = callbacks.onExternalVertices,
        .on_cursor_grid_changed = callbacks.onCursorGridChanged,
        .on_cmdline_show = callbacks.onCmdlineShow,
        .on_cmdline_hide = callbacks.onCmdlineHide,
        .on_cmdline_pos = callbacks.onCmdlinePos,
        .on_cmdline_special_char = callbacks.onCmdlineSpecialChar,
        .on_cmdline_block_show = callbacks.onCmdlineBlockShow,
        .on_cmdline_block_append = callbacks.onCmdlineBlockAppend,
        .on_cmdline_block_hide = callbacks.onCmdlineBlockHide,
        .on_popupmenu_show = callbacks.onPopupmenuShow,
        .on_popupmenu_hide = callbacks.onPopupmenuHide,
        .on_popupmenu_select = callbacks.onPopupmenuSelect,
        .on_msg_show = callbacks.onMsgShow,
        .on_msg_clear = callbacks.onMsgClear,
        .on_msg_showmode = callbacks.onMsgShowmode,
        .on_msg_showcmd = callbacks.onMsgShowcmd,
        .on_msg_ruler = callbacks.onMsgRuler,
        .on_msg_history_show = callbacks.onMsgHistoryShow,
        .on_tabline_update = callbacks.onTablineUpdate,
        .on_tabline_hide = callbacks.onTablineHide,
        .on_clipboard_get = callbacks.onClipboardGet,
        .on_clipboard_set = callbacks.onClipboardSet,
        .on_ssh_auth_prompt = callbacks.onSSHAuthPrompt,
        .on_ime_off = callbacks.onIMEOff,
        .on_quit_requested = callbacks.onQuitRequested,
        .on_rasterize_glyph = callbacks.onRasterizeGlyph,
        .on_atlas_upload = callbacks.onAtlasUpload,
        .on_atlas_create = callbacks.onAtlasCreate,
        .on_win_move = callbacks.onWinMove,
        .on_win_exchange = callbacks.onWinExchange,
        .on_win_rotate = callbacks.onWinRotate,
        .on_win_resize_equal = callbacks.onWinResizeEqual,
        .on_win_move_cursor = callbacks.onWinMoveCursor,
        .on_shape_text_run = callbacks.onShapeTextRun,
        .on_rasterize_glyph_by_id = callbacks.onRasterizeGlyphById,
        .on_get_ascii_table = callbacks.onGetAsciiTable,
        .on_flush_begin = callbacks.onFlushBegin,
        .on_flush_end = callbacks.onFlushEnd,
        .on_main_row_scroll = callbacks.onMainRowScroll,
        .on_grid_row_scroll = callbacks.onGridRowScroll,
        .on_grid_scroll = callbacks.onGridScroll,
    };

    if (applog.isEnabled()) applog.appLog("[linux] Creating core...\n", .{});

    app.corep = core.zonvie_core_create(&cb, @sizeOf(core.Callbacks), app);
    if (app.corep == null) {
        applog.appLog("[linux] ERROR: zonvie_core_create returned null\n", .{});
        return;
    }

    // Load config into core for message routing
    if (config_mod.getConfigFilePath(app.alloc)) |config_path| {
        defer app.alloc.free(config_path);
        const config_path_z = app.alloc.dupeZ(u8, config_path) catch null;
        if (config_path_z) |cpath| {
            defer app.alloc.free(cpath);
            _ = core.zonvie_core_load_config(app.corep, cpath.ptr);
        }
    } else |_| {}

    // Configure core settings
    if (applog.isEnabled()) core.zonvie_core_set_log_enabled(app.corep, 1);
    if (app.ext_cmdline_enabled) core.zonvie_core_set_ext_cmdline(app.corep, 1);
    if (app.ext_popup_enabled) core.zonvie_core_set_ext_popupmenu(app.corep, 1);
    if (app.ext_messages_enabled) core.zonvie_core_set_ext_messages(app.corep, 1);
    if (app.ext_tabline_enabled) core.zonvie_core_set_ext_tabline(app.corep, 1);

    // Performance settings
    core.zonvie_core_set_glyph_cache_size(
        app.corep,
        @intCast(app.config.performance.glyph_cache_ascii_size),
        @intCast(app.config.performance.glyph_cache_non_ascii_size),
    );
    core.zonvie_core_set_atlas_size(app.corep, @intCast(app.config.performance.atlas_size));

    // Determine nvim path
    const nvim_path: [*c]const u8 = if (app.cli_nvim_path) |p|
        @ptrCast(p.ptr)
    else if (app.config.neovim.path.len > 0)
        @ptrCast(app.config.neovim.path.ptr)
    else
        "nvim";

    // Initial grid size estimate
    const init_rows: u32 = if (app.drawable_h_px > 0 and app.cell_h_px > 0)
        app.drawable_h_px / app.cell_h_px
    else
        40;
    const init_cols: u32 = if (app.drawable_w_px > 0 and app.cell_w_px > 0)
        app.drawable_w_px / app.cell_w_px
    else
        120;

    if (applog.isEnabled()) {
        applog.appLog("[linux] Starting core: nvim_path={s}, rows={d}, cols={d}\n", .{
            std.mem.span(nvim_path),
            init_rows,
            init_cols,
        });
    }

    const start_result = core.zonvie_core_start(app.corep, nvim_path, init_rows, init_cols);
    if (start_result != 0) {
        applog.appLog("[linux] ERROR: zonvie_core_start failed with {d}\n", .{start_result});
    }
}

// =========================================================================
// Entry point
// =========================================================================

pub fn main() u8 {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    // Load configuration
    const config_result = config_mod.loadWithPath(alloc);
    var config = config_result.config;
    defer config.deinit();
    defer if (config_result.path) |p| alloc.free(p);

    // Parse command line arguments
    var ext_cmdline_enabled = config.cmdline.external;
    var ext_popup_enabled = config.popup.external;
    var ext_messages_enabled = config.messages.external;
    var ext_tabline_enabled = config.tabline.external;
    var ext_windows_enabled = config.windows.external;
    var cli_log_path: ?[]const u8 = null;
    var cli_nvim_path: ?[]const u8 = null;
    var ssh_mode: bool = config.neovim.ssh;
    var ssh_host: ?[]const u8 = config.neovim.ssh_host;
    var ssh_port: ?u16 = config.neovim.ssh_port;
    var ssh_identity: ?[]const u8 = config.neovim.ssh_identity;
    var devcontainer_mode: bool = false;
    var devcontainer_workspace: ?[]const u8 = null;
    var devcontainer_config: ?[]const u8 = null;
    var devcontainer_rebuild: bool = false;
    var nvim_extra_args = std.ArrayListUnmanaged([]const u8){};

    const args = std.process.argsAlloc(alloc) catch return 1;
    defer std.process.argsFree(alloc, args);

    // Check for --help
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            const help_msg =
                \\zonvie - A high-performance Neovim GUI
                \\
                \\USAGE:
                \\    zonvie [OPTIONS] [--] [NVIM_ARGS...]
                \\
                \\OPTIONS:
                \\    --nvim <path>                 Path to Neovim executable
                \\    --nvim=<path>                 Same as above
                \\    --log <path>                  Write application logs to file
                \\    --extcmdline                  Enable external command line UI
                \\    --extpopup                    Enable external popup menu UI
                \\    --extmessages                 Enable external messages UI
                \\    --exttabline                  Enable external tabline UI
                \\    --extwindows                  Enable external windows UI
                \\    --ssh=<user@host[:port]>      Connect to remote host via SSH
                \\    --ssh-identity=<path>         Path to SSH private key file
                \\    --devcontainer=<workspace>    Run inside a devcontainer
                \\    --devcontainer-config=<path>  Path to devcontainer.json
                \\    --devcontainer-rebuild        Rebuild devcontainer before starting
                \\    --help, -h                    Show this help message
                \\    --                            Pass remaining args to nvim
                \\
                \\CONFIG:
                \\    $XDG_CONFIG_HOME/zonvie/config.toml
                \\    or ~/.config/zonvie/config.toml
                \\
            ;
            std.debug.print("{s}", .{help_msg});
            return 0;
        }
    }

    // Parse arguments
    var pass_all_to_nvim = false;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];

        if (std.mem.eql(u8, arg, "--")) {
            pass_all_to_nvim = true;
            continue;
        }

        if (pass_all_to_nvim) {
            nvim_extra_args.append(alloc, arg) catch {};
            continue;
        }

        if (std.mem.eql(u8, arg, "--extcmdline")) {
            ext_cmdline_enabled = true;
        } else if (std.mem.eql(u8, arg, "--extpopup")) {
            ext_popup_enabled = true;
        } else if (std.mem.eql(u8, arg, "--extmessages")) {
            ext_messages_enabled = true;
        } else if (std.mem.eql(u8, arg, "--exttabline")) {
            ext_tabline_enabled = true;
        } else if (std.mem.eql(u8, arg, "--extwindows")) {
            ext_windows_enabled = true;
        } else if (std.mem.eql(u8, arg, "--nvim")) {
            if (i + 1 < args.len) {
                cli_nvim_path = args[i + 1];
                i += 1;
            }
        } else if (std.mem.startsWith(u8, arg, "--nvim=")) {
            cli_nvim_path = arg[7..];
        } else if (std.mem.eql(u8, arg, "--log")) {
            if (i + 1 < args.len) {
                cli_log_path = args[i + 1];
                i += 1;
            }
        } else if (std.mem.startsWith(u8, arg, "--ssh=")) {
            ssh_mode = true;
            const value = arg[6..];
            if (std.mem.lastIndexOfScalar(u8, value, ':')) |colon_idx| {
                const port_str = value[colon_idx + 1 ..];
                if (std.fmt.parseInt(u16, port_str, 10)) |port| {
                    ssh_host = value[0..colon_idx];
                    ssh_port = port;
                } else |_| {
                    ssh_host = value;
                }
            } else {
                ssh_host = value;
            }
        } else if (std.mem.startsWith(u8, arg, "--ssh-identity=")) {
            ssh_identity = arg[15..];
        } else if (std.mem.startsWith(u8, arg, "--devcontainer=")) {
            devcontainer_mode = true;
            devcontainer_workspace = arg[15..];
        } else if (std.mem.startsWith(u8, arg, "--devcontainer-config=")) {
            devcontainer_config = arg[22..];
        } else if (std.mem.eql(u8, arg, "--devcontainer-rebuild")) {
            devcontainer_rebuild = true;
        } else {
            nvim_extra_args.append(alloc, arg) catch {};
        }
    }

    // Enable logging
    if (cli_log_path) |path| {
        applog.setEnabled(true);
        applog.setLogPath(path);
    } else if (config.log.enabled) {
        applog.setEnabled(true);
        applog.setLogPath(config.log.path);
    }
    defer applog.deinit();

    // Create App
    const app = alloc.create(App) catch return 1;
    app.* = .{
        .alloc = alloc,
        .config = config,
        .ext_cmdline_enabled = ext_cmdline_enabled,
        .ext_popup_enabled = ext_popup_enabled,
        .ext_messages_enabled = ext_messages_enabled,
        .ext_tabline_enabled = ext_tabline_enabled,
        .ext_windows_enabled = ext_windows_enabled,
        .ssh_mode = ssh_mode,
        .ssh_host = ssh_host,
        .ssh_port = ssh_port,
        .ssh_identity = ssh_identity,
        .devcontainer_mode = devcontainer_mode,
        .devcontainer_workspace = devcontainer_workspace,
        .devcontainer_config = devcontainer_config,
        .devcontainer_rebuild = devcontainer_rebuild,
        .nvim_extra_args = nvim_extra_args,
        .cli_nvim_path = cli_nvim_path,
    };

    // Prevent config.deinit from freeing strings now owned by app
    config = .{};

    if (applog.isEnabled()) {
        applog.appLog("[linux] Starting Zonvie Linux frontend\n", .{});
    }

    // Create GTK application
    const gtk_app = gtk_application_new("com.zonvie.app", G_APPLICATION_DEFAULT_FLAGS) orelse {
        applog.appLog("[linux] ERROR: gtk_application_new returned null\n", .{});
        return 1;
    };

    _ = g_signal_connect_data(gtk_app, "activate", @ptrCast(&onActivate), app, null, 0);

    // Run GTK main loop
    const status = g_application_run(gtk_app, 0, null);
    _ = status;

    // Cleanup
    g_object_unref(gtk_app);

    if (app.corep) |corep| {
        core.zonvie_core_destroy(corep);
        app.corep = null;
    }

    ft_renderer.destroyFonts(app);
    app.tbs.deinit(alloc);
    alloc.destroy(app);

    return app_mod.g_exit_code.load(.seq_cst);
}
