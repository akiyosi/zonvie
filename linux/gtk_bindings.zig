// gtk_bindings.zig — GTK4/GDK4/GLib constants and extern declarations for Linux frontend.
//
// Defines GDK key/modifier constants and GLib helper function declarations.
// All GTK function calls use hand-written extern "c" declarations in the
// modules that need them (main.zig, external_windows.zig, etc.).
// No @cImport, no zig-gobject — enables cross-compilation from macOS.

// =========================================================================
// GDK key values (stable constants from gdk/gdkkeysyms.h)
// =========================================================================

pub const GDK_KEY_Escape = 0xff1b;
pub const GDK_KEY_Return = 0xff0d;
pub const GDK_KEY_Tab = 0xff09;
pub const GDK_KEY_BackSpace = 0xff08;
pub const GDK_KEY_Delete = 0xffff;
pub const GDK_KEY_Insert = 0xff63;
pub const GDK_KEY_Home = 0xff50;
pub const GDK_KEY_End = 0xff57;
pub const GDK_KEY_Page_Up = 0xff55;
pub const GDK_KEY_Page_Down = 0xff56;
pub const GDK_KEY_Left = 0xff51;
pub const GDK_KEY_Right = 0xff53;
pub const GDK_KEY_Up = 0xff52;
pub const GDK_KEY_Down = 0xff54;
pub const GDK_KEY_F1 = 0xffbe;
pub const GDK_KEY_F2 = 0xffbf;
pub const GDK_KEY_F3 = 0xffc0;
pub const GDK_KEY_F4 = 0xffc1;
pub const GDK_KEY_F5 = 0xffc2;
pub const GDK_KEY_F6 = 0xffc3;
pub const GDK_KEY_F7 = 0xffc4;
pub const GDK_KEY_F8 = 0xffc5;
pub const GDK_KEY_F9 = 0xffc6;
pub const GDK_KEY_F10 = 0xffc7;
pub const GDK_KEY_F11 = 0xffc8;
pub const GDK_KEY_F12 = 0xffc9;

// =========================================================================
// GDK modifier masks (from gdk/gdkenums.h, stable ABI)
// =========================================================================

pub const GDK_SHIFT_MASK: c_uint = 1 << 0;
pub const GDK_CONTROL_MASK: c_uint = 1 << 2;
pub const GDK_ALT_MASK: c_uint = 1 << 3;
pub const GDK_SUPER_MASK: c_uint = 1 << 26;

// =========================================================================
// GLib idle/timeout helpers (convenience wrappers)
// =========================================================================

/// Signature for g_idle_add / g_timeout_add callbacks.
pub const GSourceFunc = *const fn (?*anyopaque) callconv(.c) c_int;

/// Post a callback to the GTK main thread (equivalent to PostMessageW on Windows).
pub extern "c" fn g_idle_add(function: GSourceFunc, data: ?*anyopaque) c_uint;

/// Schedule a timeout callback (equivalent to SetTimer on Windows).
pub extern "c" fn g_timeout_add(interval: c_uint, function: GSourceFunc, data: ?*anyopaque) c_uint;

/// Remove a source by ID.
pub extern "c" fn g_source_remove(tag: c_uint) c_int;

pub extern "c" fn gtk_window_is_active(window: *anyopaque) c_int;

// =========================================================================
// GDK standalone functions (not available as methods in zig-gobject)
// =========================================================================

pub extern "c" fn gdk_keyval_to_unicode(keyval: c_uint) u32;

// =========================================================================
// GLib signal connection helper
// =========================================================================

/// Connect a signal handler (simplified g_signal_connect macro).
pub fn g_signal_connect(
    instance: *anyopaque,
    detailed_signal: [*:0]const u8,
    c_handler: *const anyopaque,
    data: ?*anyopaque,
) c_ulong {
    return g_signal_connect_data(instance, detailed_signal, c_handler, data, null, 0);
}

pub extern "c" fn gtk_gl_area_queue_render(area: *anyopaque) void;
pub extern "c" fn gtk_window_set_title(window: *anyopaque, title: [*:0]const u8) void;
pub extern "c" fn gtk_window_set_resizable(window: *anyopaque, resizable: c_int) void;
pub extern "c" fn gtk_init() void;
pub extern "c" fn gtk_notebook_new() ?*anyopaque;
pub extern "c" fn gtk_notebook_append_page(notebook: *anyopaque, child: *anyopaque, tab_label: ?*anyopaque) c_int;
pub extern "c" fn gtk_notebook_get_current_page(notebook: *anyopaque) c_int;
pub extern "c" fn gtk_notebook_set_current_page(notebook: *anyopaque, page: c_int) void;
pub extern "c" fn gtk_entry_new() ?*anyopaque;
pub extern "c" fn gtk_entry_set_placeholder_text(entry: *anyopaque, text: [*:0]const u8) void;
pub extern "c" fn gtk_editable_set_text(editable: *anyopaque, text: [*:0]const u8) void;
pub extern "c" fn gtk_check_button_new_with_label(label: [*:0]const u8) ?*anyopaque;
pub extern "c" fn gtk_check_button_get_active(button: *anyopaque) c_int;
pub extern "c" fn gtk_check_button_set_active(button: *anyopaque, active: c_int) void;
pub extern "c" fn gtk_text_view_new() ?*anyopaque;
pub extern "c" fn gtk_text_view_get_buffer(view: *anyopaque) ?*anyopaque;
/// GtkTextIter is a stack struct GTK fills; 80 bytes on 64-bit.
pub const GtkTextIter = extern struct { opaque_bytes: [80]u8 align(8) = undefined };
pub extern "c" fn gtk_text_buffer_get_bounds(buffer: *anyopaque, start: *GtkTextIter, end: *GtkTextIter) void;
pub extern "c" fn gtk_text_buffer_get_text(buffer: *anyopaque, start: *const GtkTextIter, end: *const GtkTextIter, include_hidden: c_int) ?[*:0]u8;
pub extern "c" fn gtk_grid_new() ?*anyopaque;
pub extern "c" fn gtk_grid_attach(grid: *anyopaque, child: *anyopaque, column: c_int, row: c_int, width: c_int, height: c_int) void;
pub extern "c" fn gtk_grid_set_row_spacing(grid: *anyopaque, spacing: c_uint) void;
pub extern "c" fn gtk_grid_set_column_spacing(grid: *anyopaque, spacing: c_uint) void;
pub extern "c" fn gtk_password_entry_new() ?*anyopaque;
pub extern "c" fn gtk_editable_get_text(editable: *anyopaque) [*:0]const u8;
pub extern "c" fn gtk_im_context_reset(context: *anyopaque) void;
pub extern "c" fn g_application_quit(application: *anyopaque) void;

pub const GAsyncReadyCallback = *const fn (?*anyopaque, ?*anyopaque, ?*anyopaque) callconv(.c) void;
pub extern "c" fn gdk_display_get_default() ?*anyopaque;
pub extern "c" fn gdk_display_get_clipboard(display: *anyopaque) ?*anyopaque;
pub extern "c" fn gtk_widget_get_clipboard(widget: *anyopaque) ?*anyopaque;
pub extern "c" fn gdk_clipboard_read_text_async(clipboard: *anyopaque, cancellable: ?*anyopaque, callback: GAsyncReadyCallback, user_data: ?*anyopaque) void;
pub extern "c" fn gdk_clipboard_read_text_finish(clipboard: *anyopaque, result: ?*anyopaque, err: *?*anyopaque) ?[*:0]u8;
pub extern "c" fn gdk_clipboard_set_text(clipboard: *anyopaque, text: [*:0]const u8) void;
pub extern "c" fn g_free(ptr: ?*anyopaque) void;
pub extern "c" fn g_strfreev(str_array: ?[*:null]?[*:0]u8) void;
pub extern "c" fn g_get_environ() ?[*:null]?[*:0]u8;
pub extern "c" fn g_environ_unsetenv(envp: ?[*:null]?[*:0]u8, variable: [*:0]const u8) ?[*:null]?[*:0]u8;
pub const GSpawnChildSetupFunc = *const fn (?*anyopaque) callconv(.c) void;
pub extern "c" fn g_spawn_async(working_directory: ?[*:0]const u8, argv: [*:null]const ?[*:0]const u8, envp: ?[*:null]?[*:0]u8, flags: c_uint, child_setup: ?GSpawnChildSetupFunc, user_data: ?*anyopaque, child_pid: ?*c_int, err: ?*?*anyopaque) c_int;

// File drops (GtkDropTarget carrying a GdkFileList).
pub const GDK_ACTION_COPY: c_uint = 1 << 0;
pub const GSList = extern struct { data: ?*anyopaque, next: ?*GSList };
pub extern "c" fn gdk_file_list_get_type() usize;
pub extern "c" fn gdk_file_list_get_files(list: *anyopaque) ?*GSList;
pub extern "c" fn gtk_drop_target_new(gtype: usize, actions: c_uint) ?*anyopaque;
pub extern "c" fn g_value_get_boxed(value: *const anyopaque) ?*anyopaque;
pub extern "c" fn g_slist_free(list: ?*GSList) void;
pub extern "c" fn g_file_get_path(file: *anyopaque) ?[*:0]u8;
pub extern "c" fn g_error_free(err: *anyopaque) void;

pub const GdkRectangle = extern struct { x: c_int, y: c_int, width: c_int, height: c_int };

pub const GDK_GL_API_GL: c_uint = 1 << 0;
pub const GTK_EVENT_CONTROLLER_SCROLL_BOTH_AXES: c_uint = (1 << 0) | (1 << 1);
pub const GTK_EVENT_CONTROLLER_SCROLL_DISCRETE: c_uint = 1 << 2;

/// gio/gioenums.h: G_APPLICATION_NON_UNIQUE = (1 << 5).
pub const G_APPLICATION_NON_UNIQUE: c_uint = 1 << 5;
/// gio/gioenums.h: G_APPLICATION_HANDLES_OPEN = (1 << 2).
pub const G_APPLICATION_HANDLES_OPEN: c_uint = 1 << 2;
pub extern "c" fn g_application_register(application: *anyopaque, cancellable: ?*anyopaque, err: ?*?*anyopaque) c_int;
pub extern "c" fn g_application_get_is_remote(application: *anyopaque) c_int;
pub extern "c" fn g_main_context_iteration(context: ?*anyopaque, may_block: c_int) c_int;
pub extern "c" fn gtk_application_new(application_id: [*:0]const u8, flags: c_uint) ?*anyopaque;
pub extern "c" fn g_application_run(application: *anyopaque, argc: c_int, argv: ?*anyopaque) c_int;
pub extern "c" fn g_object_unref(object: *anyopaque) void;
pub extern "c" fn g_object_ref_sink(object: *anyopaque) *anyopaque;
pub extern "c" fn gtk_application_window_new(application: *anyopaque) ?*anyopaque;
pub extern "c" fn gtk_window_new() ?*anyopaque;
pub extern "c" fn gtk_window_set_application(window: *anyopaque, application: ?*anyopaque) void;
pub extern "c" fn gtk_window_set_default_size(window: *anyopaque, width: c_int, height: c_int) void;
pub extern "c" fn gtk_window_set_child(window: *anyopaque, child: ?*anyopaque) void;
pub extern "c" fn gtk_window_present(window: *anyopaque) void;
pub extern "c" fn gtk_window_destroy(window: *anyopaque) void;
pub extern "c" fn gtk_gl_area_new() ?*anyopaque;
pub extern "c" fn gtk_gl_area_set_required_version(area: *anyopaque, major: c_int, minor: c_int) void;
pub extern "c" fn gtk_gl_area_set_has_depth_buffer(area: *anyopaque, has_depth_buffer: c_int) void;
pub extern "c" fn gtk_gl_area_set_allowed_apis(area: *anyopaque, apis: c_uint) void;
pub extern "c" fn gtk_gl_area_make_current(area: *anyopaque) void;
pub extern "c" fn gtk_gl_area_get_error(area: *anyopaque) ?*anyopaque;
pub extern "c" fn gtk_widget_get_width(widget: *anyopaque) c_int;
pub extern "c" fn gtk_widget_get_height(widget: *anyopaque) c_int;
pub extern "c" fn gtk_widget_get_scale_factor(widget: *anyopaque) c_int;
pub extern "c" fn gtk_widget_set_focusable(widget: *anyopaque, focusable: c_int) void;
pub extern "c" fn gtk_widget_grab_focus(widget: *anyopaque) c_int;
/// (widget, frame_clock, user_data) -> G_SOURCE_CONTINUE (1) or G_SOURCE_REMOVE (0).
pub const GtkTickCallback = *const fn (?*anyopaque, ?*anyopaque, ?*anyopaque) callconv(.c) c_int;
pub extern "c" fn gtk_widget_add_tick_callback(widget: *anyopaque, callback: GtkTickCallback, user_data: ?*anyopaque, notify: ?*anyopaque) c_uint;
pub extern "c" fn gtk_widget_add_controller(widget: *anyopaque, controller: *anyopaque) void;

pub extern "c" fn gtk_event_controller_key_new() ?*anyopaque;
pub extern "c" fn gtk_event_controller_key_set_im_context(controller: *anyopaque, im_context: *anyopaque) void;
pub extern "c" fn gtk_event_controller_focus_new() ?*anyopaque;
pub extern "c" fn gtk_event_controller_motion_new() ?*anyopaque;
pub extern "c" fn gtk_event_controller_scroll_new(flags: c_uint) ?*anyopaque;
pub extern "c" fn gtk_event_controller_get_current_event_state(controller: *anyopaque) c_uint;
pub extern "c" fn gtk_gesture_click_new() ?*anyopaque;
pub extern "c" fn gtk_gesture_single_set_button(gesture: *anyopaque, button: c_uint) void;
pub extern "c" fn gtk_gesture_single_get_current_button(gesture: *anyopaque) c_uint;

pub extern "c" fn gtk_im_multicontext_new() ?*anyopaque;
pub extern "c" fn gtk_im_context_set_client_widget(context: *anyopaque, widget: ?*anyopaque) void;
pub extern "c" fn gtk_im_context_focus_in(context: *anyopaque) void;
pub extern "c" fn gtk_im_context_focus_out(context: *anyopaque) void;
pub extern "c" fn gtk_im_context_set_cursor_location(context: *anyopaque, area: *const GdkRectangle) void;
pub extern "c" fn gtk_im_context_get_preedit_string(context: *anyopaque, str: *?[*:0]u8, attrs: ?*?*anyopaque, cursor_pos: ?*c_int) void;

pub const GTK_ORIENTATION_HORIZONTAL: c_int = 0;
pub const GTK_ORIENTATION_VERTICAL: c_int = 1;
pub const GTK_ALIGN_FILL: c_int = 0;
pub const GTK_ALIGN_START: c_int = 1;
pub const GTK_ALIGN_END: c_int = 2;
pub const GTK_ALIGN_CENTER: c_int = 3;
pub const GTK_STYLE_PROVIDER_PRIORITY_APPLICATION: c_uint = 600;
pub extern "c" fn gtk_overlay_new() ?*anyopaque;
pub extern "c" fn gtk_overlay_set_child(overlay: *anyopaque, child: ?*anyopaque) void;
pub extern "c" fn gtk_overlay_add_overlay(overlay: *anyopaque, widget: *anyopaque) void;
pub extern "c" fn gtk_box_new(orientation: c_int, spacing: c_int) ?*anyopaque;
pub extern "c" fn gtk_box_append(box: *anyopaque, child: *anyopaque) void;
pub extern "c" fn gtk_box_remove(box: *anyopaque, child: *anyopaque) void;
pub extern "c" fn gtk_label_new(str: ?[*:0]const u8) ?*anyopaque;
pub extern "c" fn gtk_label_set_text(label: *anyopaque, str: [*:0]const u8) void;
pub extern "c" fn gtk_label_set_xalign(label: *anyopaque, xalign: f32) void;
pub extern "c" fn gtk_label_set_wrap(label: *anyopaque, wrap: c_int) void;
pub extern "c" fn gtk_label_set_attributes(label: *anyopaque, attrs: ?*anyopaque) void;
pub extern "c" fn gtk_widget_get_visible(widget: *anyopaque) c_int;

pub const PANGO_SCALE: c_int = 1024;
pub extern "c" fn pango_attr_list_new() ?*anyopaque;
pub extern "c" fn pango_attr_list_copy(list: ?*anyopaque) ?*anyopaque;
pub extern "c" fn pango_attr_list_unref(list: ?*anyopaque) void;
pub extern "c" fn pango_attr_list_insert_before(list: *anyopaque, attr: *anyopaque) void;
pub extern "c" fn pango_attr_family_new(family: [*:0]const u8) ?*anyopaque;
pub extern "c" fn pango_attr_size_new_absolute(size: c_int) ?*anyopaque;
pub extern "c" fn pango_font_description_from_string(str: [*:0]const u8) ?*anyopaque;
pub extern "c" fn pango_font_description_free(desc: ?*anyopaque) void;
pub extern "c" fn pango_font_description_get_family(desc: *anyopaque) ?[*:0]const u8;
pub extern "c" fn pango_font_description_get_size(desc: *anyopaque) c_int;
pub extern "c" fn pango_font_description_get_size_is_absolute(desc: *anyopaque) c_int;
pub extern "c" fn gtk_font_dialog_new() ?*anyopaque;
pub extern "c" fn gtk_font_dialog_choose_font(dialog: *anyopaque, parent: ?*anyopaque, initial: ?*anyopaque, cancellable: ?*anyopaque, callback: GAsyncReadyCallback, user_data: ?*anyopaque) void;
pub extern "c" fn gtk_font_dialog_choose_font_finish(dialog: *anyopaque, result: *anyopaque, err: ?*?*anyopaque) ?*anyopaque;
pub extern "c" fn gtk_button_new_with_label(label: [*:0]const u8) ?*anyopaque;
pub extern "c" fn gtk_widget_set_visible(widget: *anyopaque, visible: c_int) void;
pub extern "c" fn gtk_widget_set_halign(widget: *anyopaque, a: c_int) void;
pub extern "c" fn gtk_widget_set_valign(widget: *anyopaque, a: c_int) void;
pub extern "c" fn gtk_widget_set_hexpand(widget: *anyopaque, expand: c_int) void;
pub extern "c" fn gtk_widget_set_size_request(widget: *anyopaque, width: c_int, height: c_int) void;
pub extern "c" fn gtk_box_set_homogeneous(box: *anyopaque, homogeneous: c_int) void;
pub extern "c" fn gtk_gesture_drag_new() ?*anyopaque;
pub extern "c" fn g_notification_new(title: [*:0]const u8) ?*anyopaque;
pub extern "c" fn g_notification_set_body(notification: *anyopaque, body: [*:0]const u8) void;
pub extern "c" fn g_application_send_notification(app: *anyopaque, id: ?[*:0]const u8, notification: *anyopaque) void;
pub extern "c" fn gtk_widget_set_vexpand(widget: *anyopaque, expand: c_int) void;
pub extern "c" fn gtk_widget_set_margin_top(widget: *anyopaque, m: c_int) void;
pub extern "c" fn gtk_widget_set_margin_bottom(widget: *anyopaque, m: c_int) void;
pub extern "c" fn gtk_widget_set_margin_start(widget: *anyopaque, m: c_int) void;
pub extern "c" fn gtk_widget_set_margin_end(widget: *anyopaque, m: c_int) void;
pub extern "c" fn gtk_widget_set_can_target(widget: *anyopaque, can_target: c_int) void;
pub extern "c" fn gtk_widget_add_css_class(widget: *anyopaque, css_class: [*:0]const u8) void;
pub extern "c" fn gtk_widget_get_first_child(widget: *anyopaque) ?*anyopaque;
pub extern "c" fn gtk_widget_get_next_sibling(widget: *anyopaque) ?*anyopaque;
pub extern "c" fn gtk_widget_remove_css_class(widget: *anyopaque, css_class: [*:0]const u8) void;
pub extern "c" fn gtk_button_set_label(button: *anyopaque, label: [*:0]const u8) void;
pub extern "c" fn gtk_widget_get_display(widget: *anyopaque) ?*anyopaque;
pub extern "c" fn gtk_widget_get_frame_clock(widget: *anyopaque) ?*anyopaque;
pub extern "c" fn gtk_drawing_area_new() ?*anyopaque;
pub extern "c" fn gtk_picture_new() ?*anyopaque;
pub extern "c" fn gtk_picture_set_paintable(picture: *anyopaque, paintable: ?*anyopaque) void;
pub extern "c" fn gtk_picture_set_can_shrink(picture: *anyopaque, can_shrink: c_int) void;
pub extern "c" fn gtk_picture_set_content_fit(picture: *anyopaque, fit: c_int) void;
pub const GTK_CONTENT_FIT_FILL: c_int = 0;
pub extern "c" fn gdk_dmabuf_texture_builder_new() ?*anyopaque;
pub extern "c" fn gdk_dmabuf_texture_builder_set_display(b: *anyopaque, display: ?*anyopaque) void;
pub extern "c" fn gdk_dmabuf_texture_builder_set_width(b: *anyopaque, w: c_uint) void;
pub extern "c" fn gdk_dmabuf_texture_builder_set_height(b: *anyopaque, h: c_uint) void;
pub extern "c" fn gdk_dmabuf_texture_builder_set_fourcc(b: *anyopaque, fourcc: u32) void;
pub extern "c" fn gdk_dmabuf_texture_builder_set_modifier(b: *anyopaque, modifier: u64) void;
pub extern "c" fn gdk_dmabuf_texture_builder_set_n_planes(b: *anyopaque, n: c_uint) void;
pub extern "c" fn gdk_dmabuf_texture_builder_set_fd(b: *anyopaque, plane: c_uint, fd: c_int) void;
pub extern "c" fn gdk_dmabuf_texture_builder_set_stride(b: *anyopaque, plane: c_uint, stride: c_uint) void;
pub extern "c" fn gdk_dmabuf_texture_builder_set_offset(b: *anyopaque, plane: c_uint, offset: c_uint) void;
pub const GDestroyNotify = *const fn (?*anyopaque) callconv(.c) void;
pub extern "c" fn gdk_dmabuf_texture_builder_build(b: *anyopaque, destroy: ?GDestroyNotify, data: ?*anyopaque, err: *?*anyopaque) ?*anyopaque;
pub extern "c" fn gtk_css_provider_new() ?*anyopaque;
pub extern "c" fn gtk_css_provider_load_from_string(provider: *anyopaque, str: [*:0]const u8) void;
pub extern "c" fn gtk_style_context_add_provider_for_display(display: *anyopaque, provider: *anyopaque, priority: c_uint) void;

pub extern "c" fn gtk_alert_dialog_new(format: [*:0]const u8, ...) ?*anyopaque;
pub extern "c" fn gtk_alert_dialog_set_detail(dialog: *anyopaque, detail: [*:0]const u8) void;
pub extern "c" fn gtk_alert_dialog_set_buttons(dialog: *anyopaque, labels: [*:null]const ?[*:0]const u8) void;
pub extern "c" fn gtk_alert_dialog_set_cancel_button(dialog: *anyopaque, button: c_int) void;
pub extern "c" fn gtk_alert_dialog_set_default_button(dialog: *anyopaque, button: c_int) void;
pub extern "c" fn gtk_alert_dialog_choose(dialog: *anyopaque, parent: ?*anyopaque, cancellable: ?*anyopaque, callback: GAsyncReadyCallback, user_data: ?*anyopaque) void;
pub extern "c" fn gtk_alert_dialog_choose_finish(dialog: *anyopaque, result: ?*anyopaque, err: *?*anyopaque) c_int;

extern "c" fn g_signal_connect_data(
    instance: *anyopaque,
    detailed_signal: [*:0]const u8,
    c_handler: *const anyopaque,
    data: ?*anyopaque,
    destroy_data: ?*anyopaque,
    connect_flags: c_uint,
) c_ulong;
