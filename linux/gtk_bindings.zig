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
pub extern "c" fn gdk_display_get_primary_clipboard(display: *anyopaque) ?*anyopaque;
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
pub const GDK_ACTION_LINK: c_uint = 1 << 2;
pub extern "c" fn gtk_drop_target_get_current_drop(target: *anyopaque) ?*anyopaque;
pub extern "c" fn gdk_drop_get_actions(drop: *anyopaque) c_uint;
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
pub const GTK_EVENT_CONTROLLER_SCROLL_KINETIC: c_uint = 1 << 3;
/// GdkScrollUnit: a wheel reports steps, a touchpad surface px.
pub const GDK_SCROLL_UNIT_SURFACE: c_int = 1;
pub extern "c" fn gtk_event_controller_scroll_get_unit(scroll: *anyopaque) c_int;
pub extern "c" fn gdk_frame_clock_get_frame_time(frame_clock: *anyopaque) i64;
pub extern "c" fn gtk_widget_remove_tick_callback(widget: *anyopaque, id: c_uint) void;

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
pub extern "c" fn gtk_window_get_default_size(window: *anyopaque, width: ?*c_int, height: ?*c_int) void;
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
/// graphene_rect_t.
pub const GrapheneRect = extern struct { x: f32 = 0, y: f32 = 0, w: f32 = 0, h: f32 = 0 };
/// `widget`'s bounds in `target`'s coordinates; 0 when they share no ancestor.
pub extern "c" fn gtk_widget_compute_bounds(widget: *anyopaque, target: *anyopaque, out_bounds: *GrapheneRect) c_int;
pub extern "c" fn gtk_widget_get_height(widget: *anyopaque) c_int;
pub extern "c" fn gtk_widget_get_scale_factor(widget: *anyopaque) c_int;
pub extern "c" fn gtk_widget_set_focusable(widget: *anyopaque, focusable: c_int) void;
pub extern "c" fn gtk_widget_grab_focus(widget: *anyopaque) c_int;
pub extern "c" fn gtk_window_set_default_widget(window: *anyopaque, default_widget: ?*anyopaque) void;
/// (widget, frame_clock, user_data) -> G_SOURCE_CONTINUE (1) or G_SOURCE_REMOVE (0).
pub const GtkTickCallback = *const fn (?*anyopaque, ?*anyopaque, ?*anyopaque) callconv(.c) c_int;
pub extern "c" fn gtk_widget_add_tick_callback(widget: *anyopaque, callback: GtkTickCallback, user_data: ?*anyopaque, notify: ?*anyopaque) c_uint;
pub extern "c" fn gtk_widget_set_cursor_from_name(widget: *anyopaque, name: ?[*:0]const u8) void;
pub extern "c" fn gtk_widget_add_controller(widget: *anyopaque, controller: *anyopaque) void;

pub extern "c" fn gtk_event_controller_key_new() ?*anyopaque;
pub extern "c" fn gtk_event_controller_key_set_im_context(controller: *anyopaque, im_context: *anyopaque) void;
pub extern "c" fn gtk_event_controller_focus_new() ?*anyopaque;
pub extern "c" fn gtk_event_controller_motion_new() ?*anyopaque;
pub extern "c" fn gtk_event_controller_scroll_new(flags: c_uint) ?*anyopaque;
pub extern "c" fn gtk_event_controller_get_current_event(controller: *anyopaque) ?*anyopaque;
pub extern "c" fn gdk_key_event_get_layout(event: *anyopaque) c_uint;
pub extern "c" fn gdk_display_translate_key(display: *anyopaque, keycode: c_uint, state: c_uint, group: c_int, keyval: ?*c_uint, effective_group: ?*c_int, level: ?*c_int, consumed: ?*c_uint) c_int;
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
pub extern "c" fn gtk_label_set_max_width_chars(label: *anyopaque, n_chars: c_int) void;
/// GTK 4.12.
pub extern "c" fn gtk_button_set_can_shrink(button: *anyopaque, can_shrink: c_int) void;
pub extern "c" fn gtk_button_get_child(button: *anyopaque) ?*anyopaque;
pub extern "c" fn gtk_label_set_attributes(label: *anyopaque, attrs: ?*anyopaque) void;
pub extern "c" fn gtk_widget_get_visible(widget: *anyopaque) c_int;
pub const GtkRequisition = extern struct { width: c_int = 0, height: c_int = 0 };
pub extern "c" fn gtk_widget_get_preferred_size(widget: *anyopaque, minimum: ?*GtkRequisition, natural: ?*GtkRequisition) void;

pub const PANGO_SCALE: c_int = 1024;
pub const PANGO_ELLIPSIZE_END: c_int = 3;
pub const PANGO_UNDERLINE_SINGLE: c_int = 1;
pub const PANGO_UNDERLINE_DOUBLE: c_int = 2;
pub const PANGO_UNDERLINE_DOUBLE_LINE: c_int = 6;
/// The common head of every PangoAttribute; the indices are UTF-8 bytes.
pub const PangoAttribute = extern struct { klass: ?*const anyopaque, start_index: u32, end_index: u32 };
pub extern "c" fn pango_attr_list_insert(list: *anyopaque, attr: *PangoAttribute) void;
pub extern "c" fn pango_attr_foreground_new(red: u16, green: u16, blue: u16) ?*PangoAttribute;
pub extern "c" fn pango_attr_weight_new(weight: c_int) ?*PangoAttribute;
pub extern "c" fn pango_attr_style_new(style: c_int) ?*PangoAttribute;
pub extern "c" fn pango_attr_underline_new(underline: c_int) ?*PangoAttribute;
pub extern "c" fn pango_attr_strikethrough_new(strikethrough: c_int) ?*PangoAttribute;
pub extern "c" fn pango_attr_scale_new(scale_factor: f64) ?*PangoAttribute;
pub extern "c" fn gtk_label_set_ellipsize(label: *anyopaque, mode: c_int) void;
pub extern "c" fn gtk_label_set_width_chars(label: *anyopaque, n_chars: c_int) void;
pub extern "c" fn gtk_label_get_text(label: *anyopaque) [*:0]const u8;
pub const GTK_POLICY_ALWAYS: c_int = 0;
pub const GTK_POLICY_AUTOMATIC: c_int = 1;
pub const GTK_POLICY_NEVER: c_int = 2;
pub const GTK_POLICY_EXTERNAL: c_int = 3;
pub extern "c" fn gtk_scrolled_window_new() ?*anyopaque;
pub extern "c" fn gtk_scrolled_window_set_policy(sw: *anyopaque, h: c_int, v: c_int) void;
pub extern "c" fn gtk_scrolled_window_set_child(sw: *anyopaque, child: ?*anyopaque) void;
pub extern "c" fn gtk_scrolled_window_set_propagate_natural_height(sw: *anyopaque, propagate: c_int) void;
pub extern "c" fn gtk_scrolled_window_set_propagate_natural_width(sw: *anyopaque, propagate: c_int) void;
pub extern "c" fn gtk_event_controller_get_widget(controller: *anyopaque) ?*anyopaque;
pub extern "c" fn gtk_widget_pick(widget: *anyopaque, x: f64, y: f64, flags: c_uint) ?*anyopaque;
pub extern "c" fn gtk_widget_has_css_class(widget: *anyopaque, css_class: [*:0]const u8) c_int;
pub extern "c" fn gtk_widget_get_parent(widget: *anyopaque) ?*anyopaque;
pub const GTK_EVENT_SEQUENCE_CLAIMED: c_int = 1;
pub extern "c" fn gtk_gesture_set_state(gesture: *anyopaque, state: c_int) c_int;
pub extern "c" fn pango_attr_list_new() ?*anyopaque;
pub extern "c" fn pango_attr_list_copy(list: ?*anyopaque) ?*anyopaque;
pub extern "c" fn pango_attr_list_unref(list: ?*anyopaque) void;
pub extern "c" fn pango_attr_list_insert_before(list: *anyopaque, attr: *anyopaque) void;
pub extern "c" fn pango_attr_family_new(family: [*:0]const u8) ?*anyopaque;
pub extern "c" fn pango_attr_size_new_absolute(size: c_int) ?*anyopaque;
/// PangoAttrType (pango-attributes.h).
pub const PANGO_ATTR_WEIGHT: c_int = 4;
pub const PANGO_ATTR_BACKGROUND: c_int = 10;
pub const PANGO_ATTR_UNDERLINE: c_int = 11;
/// PangoAttrInt: a PangoAttribute carrying one int (weight, underline).
pub const PangoAttrInt = extern struct { attr: PangoAttribute, value: c_int };
pub extern "c" fn pango_attr_list_get_iterator(list: *anyopaque) ?*anyopaque;
pub extern "c" fn pango_attr_iterator_range(iterator: *anyopaque, start: *c_int, end: *c_int) void;
pub extern "c" fn pango_attr_iterator_get(iterator: *anyopaque, attr_type: c_int) ?*anyopaque;
pub extern "c" fn pango_attr_iterator_next(iterator: *anyopaque) c_int;
pub extern "c" fn pango_attr_iterator_destroy(iterator: *anyopaque) void;
pub extern "c" fn pango_font_description_from_string(str: [*:0]const u8) ?*anyopaque;
pub extern "c" fn pango_font_description_free(desc: ?*anyopaque) void;
pub extern "c" fn pango_font_description_get_family(desc: *anyopaque) ?[*:0]const u8;
pub extern "c" fn pango_font_description_get_size(desc: *anyopaque) c_int;
pub extern "c" fn pango_font_description_get_size_is_absolute(desc: *anyopaque) c_int;
/// PangoWeight (100..1000, PANGO_WEIGHT_SEMIBOLD = 600).
pub extern "c" fn pango_font_description_get_weight(desc: *anyopaque) c_int;
/// PangoStyle: 0 normal, 1 oblique, 2 italic.
pub extern "c" fn pango_font_description_get_style(desc: *anyopaque) c_int;
pub extern "c" fn pango_font_description_set_weight(desc: *anyopaque, weight: c_int) void;
pub extern "c" fn pango_font_description_set_style(desc: *anyopaque, style: c_int) void;
pub const PANGO_WEIGHT_NORMAL: c_int = 400;
pub const PANGO_WEIGHT_BOLD: c_int = 700;
pub const PANGO_WEIGHT_SEMIBOLD: c_int = 600;
pub const PANGO_STYLE_NORMAL: c_int = 0;
pub const PANGO_STYLE_ITALIC: c_int = 2;
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
pub const GTK_OVERFLOW_HIDDEN: c_int = 1;
pub extern "c" fn gtk_widget_set_overflow(widget: *anyopaque, overflow: c_int) void;
pub extern "c" fn gtk_widget_set_margin_top(widget: *anyopaque, m: c_int) void;
pub extern "c" fn gtk_widget_set_margin_bottom(widget: *anyopaque, m: c_int) void;
pub extern "c" fn gtk_widget_set_margin_start(widget: *anyopaque, m: c_int) void;
pub extern "c" fn gtk_widget_set_margin_end(widget: *anyopaque, m: c_int) void;
pub extern "c" fn gtk_widget_set_tooltip_text(widget: *anyopaque, text: ?[*:0]const u8) void;
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

// Window chrome (linux/chrome.zig) and size (linux/window_size.zig).
pub const GDK_TOPLEVEL_STATE_MINIMIZED: c_uint = 1 << 0;
pub const GDK_TOPLEVEL_STATE_MAXIMIZED: c_uint = 1 << 1;
pub const GDK_TOPLEVEL_STATE_FULLSCREEN: c_uint = 1 << 3;
/// TILED and each edge's *_TILED bit.
pub const GDK_TOPLEVEL_STATE_TILED: c_uint = (1 << 7) | (1 << 8) | (1 << 10) | (1 << 12) | (1 << 14);
pub extern "c" fn gtk_native_get_surface(native: *anyopaque) ?*anyopaque;
pub extern "c" fn gtk_native_get_surface_transform(native: *anyopaque, x: *f64, y: *f64) void;

// Panel popups (linux/panel_popup.zig).
pub const GTK_POS_BOTTOM: c_int = 3;
pub extern "c" fn gtk_popover_new() ?*anyopaque;
pub extern "c" fn gtk_popover_set_child(popover: *anyopaque, child: ?*anyopaque) void;
pub extern "c" fn gtk_popover_set_has_arrow(popover: *anyopaque, has_arrow: c_int) void;
pub extern "c" fn gtk_popover_set_autohide(popover: *anyopaque, autohide: c_int) void;
pub extern "c" fn gtk_popover_set_position(popover: *anyopaque, position: c_int) void;
pub extern "c" fn gtk_popover_set_pointing_to(popover: *anyopaque, rect: ?*const GdkRectangle) void;
pub extern "c" fn gtk_popover_set_offset(popover: *anyopaque, x_offset: c_int, y_offset: c_int) void;
pub extern "c" fn gtk_popover_popup(popover: *anyopaque) void;
pub extern "c" fn gtk_popover_popdown(popover: *anyopaque) void;
pub extern "c" fn gtk_popover_present(popover: *anyopaque) void;
pub extern "c" fn gtk_widget_set_parent(widget: *anyopaque, parent: *anyopaque) void;
pub extern "c" fn gtk_widget_get_mapped(widget: *anyopaque) c_int;
pub extern "c" fn gtk_widget_unparent(widget: *anyopaque) void;
pub extern "c" fn gtk_overlay_remove_overlay(overlay: *anyopaque, widget: *anyopaque) void;
pub extern "c" fn g_object_ref(object: *anyopaque) *anyopaque;
pub extern "c" fn gdk_surface_get_frame_clock(surface: *anyopaque) ?*anyopaque;
pub extern "c" fn g_signal_handler_disconnect(instance: *anyopaque, handler_id: c_ulong) void;
pub extern "c" fn gdk_popup_get_position_x(popup: *anyopaque) c_int;
pub extern "c" fn gdk_popup_get_position_y(popup: *anyopaque) c_int;
pub extern "c" fn gdk_display_get_monitor_at_surface(display: *anyopaque, surface: *anyopaque) ?*anyopaque;
pub extern "c" fn gdk_monitor_get_geometry(monitor: *anyopaque, geometry: *GdkRectangle) void;
pub extern "c" fn gdk_toplevel_get_state(toplevel: *anyopaque) c_uint;
pub const GTK_PACK_START: c_int = 0;
pub const GTK_PACK_END: c_int = 1;
pub const GTK_PHASE_CAPTURE: c_int = 1;
pub const G_BINDING_SYNC_CREATE: c_uint = 1 << 1;
pub const GTK_REVEALER_TRANSITION_TYPE_SLIDE_RIGHT: c_int = 2;
pub const GTK_REVEALER_TRANSITION_TYPE_SLIDE_LEFT: c_int = 3;
pub extern "c" fn gtk_window_set_titlebar(window: *anyopaque, titlebar: ?*anyopaque) void;
pub extern "c" fn gtk_window_close(window: *anyopaque) void;
pub extern "c" fn gtk_center_box_new() ?*anyopaque;
pub extern "c" fn gtk_center_box_set_start_widget(box: *anyopaque, child: ?*anyopaque) void;
pub extern "c" fn gtk_center_box_set_center_widget(box: *anyopaque, child: ?*anyopaque) void;
pub extern "c" fn gtk_center_box_set_end_widget(box: *anyopaque, child: ?*anyopaque) void;
pub extern "c" fn gtk_window_controls_new(side: c_int) ?*anyopaque;
pub extern "c" fn gtk_window_handle_new() ?*anyopaque;
pub extern "c" fn gtk_window_handle_set_child(handle: *anyopaque, child: ?*anyopaque) void;
pub extern "c" fn gtk_revealer_new() ?*anyopaque;
pub extern "c" fn gtk_revealer_set_child(revealer: *anyopaque, child: ?*anyopaque) void;
pub extern "c" fn gtk_revealer_set_transition_type(revealer: *anyopaque, t: c_int) void;
pub extern "c" fn gtk_revealer_set_transition_duration(revealer: *anyopaque, ms: c_uint) void;
pub extern "c" fn gtk_revealer_set_reveal_child(revealer: *anyopaque, reveal: c_int) void;
pub extern "c" fn gtk_revealer_get_reveal_child(revealer: *anyopaque) c_int;
pub extern "c" fn gtk_button_new_from_icon_name(icon_name: [*:0]const u8) ?*anyopaque;
pub extern "c" fn gtk_event_controller_set_propagation_phase(controller: *anyopaque, phase: c_int) void;
pub extern "c" fn g_object_bind_property(source: *anyopaque, source_property: [*:0]const u8, target: *anyopaque, target_property: [*:0]const u8, flags: c_uint) ?*anyopaque;
pub extern "c" fn gtk_menu_button_new() ?*anyopaque;
pub extern "c" fn gtk_menu_button_set_icon_name(button: *anyopaque, icon_name: [*:0]const u8) void;
pub extern "c" fn gtk_menu_button_set_label(button: *anyopaque, label: [*:0]const u8) void;
pub extern "c" fn gtk_menu_button_set_menu_model(button: *anyopaque, model: ?*anyopaque) void;
pub extern "c" fn g_menu_new() ?*anyopaque;
pub extern "c" fn g_menu_append(menu: *anyopaque, label: ?[*:0]const u8, detailed_action: ?[*:0]const u8) void;
pub extern "c" fn g_menu_append_section(menu: *anyopaque, label: ?[*:0]const u8, section: *anyopaque) void;
pub extern "c" fn g_menu_append_item(menu: *anyopaque, item: *anyopaque) void;
pub extern "c" fn g_menu_remove_all(menu: *anyopaque) void;
pub extern "c" fn g_menu_item_new(label: ?[*:0]const u8, detailed_action: ?[*:0]const u8) ?*anyopaque;
pub extern "c" fn g_menu_item_set_action_and_target_value(item: *anyopaque, action: ?[*:0]const u8, target: ?*anyopaque) void;
pub extern "c" fn g_simple_action_group_new() ?*anyopaque;
pub extern "c" fn g_simple_action_new(name: [*:0]const u8, parameter_type: ?*anyopaque) ?*anyopaque;
pub extern "c" fn g_simple_action_new_stateful(name: [*:0]const u8, parameter_type: ?*anyopaque, state: *anyopaque) ?*anyopaque;
pub extern "c" fn g_simple_action_set_state(action: *anyopaque, value: *anyopaque) void;
pub extern "c" fn g_action_map_add_action(map: *anyopaque, action: *anyopaque) void;
pub extern "c" fn g_variant_type_new(type_string: [*:0]const u8) ?*anyopaque;
pub extern "c" fn g_variant_new_int32(value: i32) *anyopaque;
pub extern "c" fn g_variant_get_int32(value: *anyopaque) i32;
pub extern "c" fn gtk_widget_insert_action_group(widget: *anyopaque, name: [*:0]const u8, group: ?*anyopaque) void;
pub extern "c" fn gtk_show_about_dialog(parent: ?*anyopaque, first_property_name: [*:0]const u8, ...) void;
// GDBus and GVariant (GIO), for ime_off.zig.
pub const G_BUS_TYPE_SESSION: c_int = 2;
pub const G_DBUS_CONNECTION_FLAGS_AUTHENTICATION_CLIENT: c_uint = 1 << 0;
pub const G_DBUS_CONNECTION_FLAGS_MESSAGE_BUS_CONNECTION: c_uint = 1 << 3;
pub extern "c" fn g_bus_get_sync(bus_type: c_int, cancellable: ?*anyopaque, err: ?*?*anyopaque) ?*anyopaque;
pub extern "c" fn g_dbus_connection_new_for_address_sync(address: [*:0]const u8, flags: c_uint, observer: ?*anyopaque, cancellable: ?*anyopaque, err: ?*?*anyopaque) ?*anyopaque;
pub extern "c" fn g_dbus_connection_call(
    connection: *anyopaque,
    bus_name: ?[*:0]const u8,
    object_path: [*:0]const u8,
    interface_name: ?[*:0]const u8,
    method_name: [*:0]const u8,
    parameters: ?*anyopaque,
    reply_type: ?*const anyopaque,
    flags: c_uint,
    timeout_msec: c_int,
    cancellable: ?*anyopaque,
    callback: ?GAsyncReadyCallback,
    user_data: ?*anyopaque,
) void;
pub extern "c" fn g_dbus_connection_call_finish(connection: *anyopaque, res: ?*anyopaque, err: ?*?*anyopaque) ?*anyopaque;
pub extern "c" fn g_variant_unref(value: *anyopaque) void;
pub extern "c" fn g_variant_ref_sink(value: *anyopaque) *anyopaque;
pub extern "c" fn g_variant_n_children(value: *anyopaque) usize;
pub extern "c" fn g_variant_get_child_value(value: *anyopaque, index: usize) ?*anyopaque;
pub extern "c" fn g_variant_get_variant(value: *anyopaque) ?*anyopaque;
pub extern "c" fn g_variant_get_type_string(value: *anyopaque) [*:0]const u8;
pub extern "c" fn g_variant_get_string(value: *anyopaque, length: ?*usize) ?[*:0]const u8;
pub extern "c" fn g_variant_new_string(string: [*:0]const u8) ?*anyopaque;
pub extern "c" fn g_variant_new_tuple(children: [*]const *anyopaque, n_children: usize) ?*anyopaque;
pub extern "c" fn g_getenv(variable: [*:0]const u8) ?[*:0]const u8;
pub extern "c" fn g_get_user_config_dir() [*:0]const u8;
pub extern "c" fn g_dir_open(path: [*:0]const u8, flags: c_uint, err: ?*?*anyopaque) ?*anyopaque;
pub extern "c" fn g_dir_read_name(dir: *anyopaque) ?[*:0]const u8;
pub extern "c" fn g_dir_close(dir: *anyopaque) void;
pub extern "c" fn g_file_get_contents(filename: [*:0]const u8, contents: *?[*:0]u8, length: ?*usize, err: ?*?*anyopaque) c_int;
// Window lifecycle: realizing a window before it is shown, its toplevel
// state, `devcontainer up` as a subprocess, the workspace folder picker.
pub extern "c" fn gtk_widget_realize(widget: *anyopaque) void;
pub extern "c" fn g_cancellable_new() ?*anyopaque;
pub extern "c" fn g_cancellable_cancel(cancellable: *anyopaque) void;
pub extern "c" fn g_cancellable_is_cancelled(cancellable: *anyopaque) c_int;
/// gio/gioenums.h: G_SUBPROCESS_FLAGS_STDERR_MERGE = (1u << 6).
pub const G_SUBPROCESS_FLAGS_STDERR_MERGE: c_uint = 1 << 6;
pub extern "c" fn g_subprocess_launcher_new(flags: c_uint) ?*anyopaque;
pub extern "c" fn g_subprocess_launcher_take_stdout_fd(launcher: *anyopaque, fd: c_int) void;
pub extern "c" fn g_subprocess_launcher_spawnv(launcher: *anyopaque, argv: [*:null]const ?[*:0]const u8, err: ?*?*anyopaque) ?*anyopaque;
pub extern "c" fn g_subprocess_wait_check_async(subprocess: *anyopaque, cancellable: ?*anyopaque, callback: GAsyncReadyCallback, user_data: ?*anyopaque) void;
pub extern "c" fn g_subprocess_wait_check_finish(subprocess: *anyopaque, result: ?*anyopaque, err: ?*?*anyopaque) c_int;
/// GError's public layout: domain, code, message.
pub const GError = extern struct { domain: u32, code: c_int, message: ?[*:0]const u8 };
pub extern "c" fn gtk_file_dialog_new() ?*anyopaque;
pub extern "c" fn gtk_file_dialog_set_title(dialog: *anyopaque, title: [*:0]const u8) void;
pub extern "c" fn gtk_file_dialog_set_initial_folder(dialog: *anyopaque, folder: ?*anyopaque) void;
pub extern "c" fn gtk_file_dialog_select_folder(dialog: *anyopaque, parent: ?*anyopaque, cancellable: ?*anyopaque, callback: GAsyncReadyCallback, user_data: ?*anyopaque) void;
pub extern "c" fn gtk_file_dialog_select_folder_finish(dialog: *anyopaque, result: ?*anyopaque, err: ?*?*anyopaque) ?*anyopaque;
pub extern "c" fn g_file_new_for_path(path: [*:0]const u8) ?*anyopaque;
pub extern "c" fn gtk_shortcut_controller_new() ?*anyopaque;
pub extern "c" fn gtk_shortcut_controller_add_shortcut(controller: *anyopaque, shortcut: *anyopaque) void;
pub extern "c" fn gtk_shortcut_new(trigger: ?*anyopaque, action: ?*anyopaque) ?*anyopaque;
pub extern "c" fn gtk_shortcut_trigger_parse_string(string: [*:0]const u8) ?*anyopaque;
pub const GtkShortcutFunc = *const fn (?*anyopaque, ?*anyopaque, ?*anyopaque) callconv(.c) c_int;
pub extern "c" fn gtk_callback_action_new(callback: GtkShortcutFunc, data: ?*anyopaque, destroy: ?GDestroyNotify) ?*anyopaque;

// Per-object data (linux/blur.zig).
pub extern "c" fn g_object_set_data(object: *anyopaque, key: [*:0]const u8, data: ?*anyopaque) void;
pub extern "c" fn g_object_get_data(object: *anyopaque, key: [*:0]const u8) ?*anyopaque;
pub extern "c" fn gtk_widget_queue_draw(widget: *anyopaque) void;

// Icon theme lookup (linux/tray.zig).
pub extern "c" fn gtk_icon_theme_get_for_display(display: *anyopaque) ?*anyopaque;
pub extern "c" fn gtk_icon_theme_has_icon(theme: *anyopaque, icon_name: [*:0]const u8) c_int;
pub extern "c" fn gtk_widget_get_realized(widget: *anyopaque) c_int;
pub extern "c" fn g_set_prgname(prgname: [*:0]const u8) void;
pub extern "c" fn gtk_window_set_default_icon_name(name: [*:0]const u8) void;
pub extern "c" fn gdk_event_get_position(event: *anyopaque, x: *f64, y: *f64) c_int;

// GDK drag-and-drop for the tab tear-off (linux/tab_strip.zig).
pub const G_TYPE_STRING: usize = 16 << 2;
pub const GDK_ACTION_MOVE: c_uint = 1 << 1;
pub const GDK_DRAG_CANCEL_NO_TARGET: c_int = 0;
pub const GDK_DRAG_CANCEL_USER_CANCELLED: c_int = 1;
pub const GDK_DRAG_CANCEL_ERROR: c_int = 2;
pub extern "c" fn gtk_widget_get_native(widget: *anyopaque) ?*anyopaque;
pub extern "c" fn gtk_gesture_get_device(gesture: *anyopaque) ?*anyopaque;
pub extern "c" fn gdk_content_provider_new_typed(gtype: usize, ...) ?*anyopaque;
pub extern "c" fn gdk_drag_begin(surface: *anyopaque, device: *anyopaque, content: *anyopaque, actions: c_uint, dx: f64, dy: f64) ?*anyopaque;
pub extern "c" fn gtk_drag_icon_get_for_drag(drag: *anyopaque) ?*anyopaque;
pub extern "c" fn gtk_drag_icon_set_child(icon: *anyopaque, child: ?*anyopaque) void;
pub extern "c" fn g_value_get_string(value: *const anyopaque) ?[*:0]const u8;
