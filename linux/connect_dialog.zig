//! `--dialog`: the startup dialog that picks the connection (Local / SSH /
//! Devcontainer), the Neovim path, the ext_* options and extra environment
//! before nvim starts, as macOS's ConnectionMenuViewController and the
//! Windows connection dialog do. It runs before the main window exists, on a
//! loop of its own. GTK main thread.

const std = @import("std");
const gtk = @import("gtk_bindings.zig");

pub const Mode = enum(c_int) { local = 0, ssh = 1, devcontainer = 2 };

/// What the dialog shows first and what it returns. Strings are borrowed
/// from the caller for the seed, and owned by `alloc` in the result.
pub const Choice = struct {
    /// The session's name, carried into the window title.
    name: []const u8 = "",
    mode: Mode = .local,
    nvim_path: []const u8 = "",
    ssh_host: []const u8 = "",
    ssh_port: []const u8 = "",
    ssh_identity: []const u8 = "",
    dc_workspace: []const u8 = "",
    dc_config: []const u8 = "",
    dc_rebuild: bool = false,
    /// ext_cmdline, ext_popupmenu, ext_messages, ext_tabline, ext_windows.
    ext: [5]bool = @splat(false),
    /// KEY=VALUE per line, set in this process before nvim is spawned.
    env: []const u8 = "",
};

const Ui = struct {
    win: *anyopaque,
    name: *anyopaque,
    notebook: *anyopaque,
    nvim: *anyopaque,
    host: *anyopaque,
    port: *anyopaque,
    identity: *anyopaque,
    workspace: *anyopaque,
    config: *anyopaque,
    rebuild: *anyopaque,
    ext: [5]*anyopaque,
    env_buffer: *anyopaque,
    done: bool = false,
    connect: bool = false,
};

fn entry(seed: []const u8, placeholder: [*:0]const u8, buf: []u8) *anyopaque {
    const e = gtk.gtk_entry_new().?;
    gtk.gtk_entry_set_placeholder_text(e, placeholder);
    if (seed.len != 0 and seed.len < buf.len) {
        @memcpy(buf[0..seed.len], seed);
        buf[seed.len] = 0;
        gtk.gtk_editable_set_text(e, @ptrCast(buf.ptr));
    }
    gtk.gtk_widget_set_hexpand(e, 1);
    return e;
}

/// A label/field grid: one row per pair.
fn form(rows: []const struct { [*:0]const u8, *anyopaque }) *anyopaque {
    const g = gtk.gtk_grid_new().?;
    gtk.gtk_grid_set_row_spacing(g, 6);
    gtk.gtk_grid_set_column_spacing(g, 8);
    for ([_]*const fn (*anyopaque, c_int) callconv(.c) void{
        gtk.gtk_widget_set_margin_start, gtk.gtk_widget_set_margin_end,
        gtk.gtk_widget_set_margin_top,   gtk.gtk_widget_set_margin_bottom,
    }) |set| set(g, 12);
    for (rows, 0..) |r, i| {
        const l = gtk.gtk_label_new(r[0]).?;
        gtk.gtk_label_set_xalign(l, 0);
        gtk.gtk_grid_attach(g, l, 0, @intCast(i), 1, 1);
        gtk.gtk_grid_attach(g, r[1], 1, @intCast(i), 1, 1);
    }
    return g;
}

fn onConnect(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const ui: *Ui = @ptrCast(@alignCast(data.?));
    ui.connect = true;
    ui.done = true;
}

fn onCancel(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const ui: *Ui = @ptrCast(@alignCast(data.?));
    ui.done = true;
}

fn onClose(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) c_int {
    onCancel(null, data);
    return 1;
}

fn onEscape(_: ?*anyopaque, _: ?*anyopaque, data: ?*anyopaque) callconv(.c) c_int {
    onCancel(null, data);
    return 1;
}

/// Picks the workspace folder (macOS's Browse...), starting from the one
/// typed, if any.
fn onBrowse(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const ui: *Ui = @ptrCast(@alignCast(data.?));
    const d = gtk.gtk_file_dialog_new() orelse return;
    gtk.gtk_file_dialog_set_title(d, "Choose the devcontainer workspace folder");
    const current = gtk.gtk_editable_get_text(ui.workspace);
    if (current[0] != 0) if (gtk.g_file_new_for_path(current)) |f| {
        gtk.gtk_file_dialog_set_initial_folder(d, f);
        gtk.g_object_unref(f);
    };
    gtk.gtk_file_dialog_select_folder(d, ui.win, null, &onBrowseDone, ui);
}

fn onBrowseDone(source: ?*anyopaque, result: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const ui: *Ui = @ptrCast(@alignCast(data.?));
    var err: ?*anyopaque = null;
    const file = gtk.gtk_file_dialog_select_folder_finish(source.?, result, &err);
    if (err) |e| gtk.g_error_free(e);
    gtk.g_object_unref(source.?);
    const f = file orelse return;
    defer gtk.g_object_unref(f);
    const path = gtk.g_file_get_path(f) orelse return;
    defer gtk.g_free(path);
    gtk.gtk_editable_set_text(ui.workspace, path);
}

/// The dialog's Neovim path as the spawn command can carry it (the --nvim
/// rule of macOS and the Windows dialog): one pair of matching quotes around
/// the whole path is dropped; a path still holding a quote is ignored
/// (empty, so the default applies) and `ignored` is set.
pub fn nvimPath(raw: []const u8) struct { path: []const u8, ignored: bool } {
    var p = raw;
    if (p.len >= 2 and (p[0] == '"' or p[0] == '\'') and p[p.len - 1] == p[0]) p = p[1 .. p.len - 1];
    if (std.mem.indexOfAny(u8, p, "'\"") != null) return .{ .path = "", .ignored = true };
    return .{ .path = p, .ignored = false };
}

test "the dialog's nvim path drops one pair of quotes and refuses the rest" {
    try std.testing.expectEqualStrings("/opt/my nvim", nvimPath("\"/opt/my nvim\"").path);
    try std.testing.expectEqualStrings("/a", nvimPath("'/a'").path);
    try std.testing.expectEqualStrings("/a", nvimPath("/a").path);
    try std.testing.expect(nvimPath("/a\"b").ignored);
    try std.testing.expect(nvimPath("\"/a'").ignored);
    try std.testing.expect(!nvimPath("").ignored);
}

/// Shows an alert and waits for it to be dismissed, on a loop of its own:
/// for use before the app runs. `parent` may be null.
pub fn alert(parent: ?*anyopaque, heading: [*:0]const u8, detail: [*:0]const u8) void {
    gtk.gtk_init();
    const dialog = gtk.gtk_alert_dialog_new("%s", heading) orelse return;
    defer gtk.g_object_unref(dialog);
    gtk.gtk_alert_dialog_set_detail(dialog, detail);
    var done = false;
    gtk.gtk_alert_dialog_choose(dialog, parent, null, &onAlertDone, &done);
    while (!done) _ = gtk.g_main_context_iteration(null, 1);
}

fn onAlertDone(source: ?*anyopaque, result: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    var err: ?*anyopaque = null;
    _ = gtk.gtk_alert_dialog_choose_finish(source.?, result, &err);
    if (err) |e| gtk.g_error_free(e);
    const done: *bool = @ptrCast(@alignCast(data.?));
    done.* = true;
}

fn text(alloc: std.mem.Allocator, editable: *anyopaque) ![]const u8 {
    return alloc.dupe(u8, std.mem.trim(u8, std.mem.span(gtk.gtk_editable_get_text(editable)), " \t"));
}

/// Shows the dialog seeded with `seed`; null when it is cancelled.
pub fn run(alloc: std.mem.Allocator, seed: Choice) !?Choice {
    gtk.gtk_init();
    const win = gtk.gtk_window_new() orelse return null;
    gtk.gtk_window_set_title(win, "Zonvie: Connect");
    gtk.gtk_window_set_default_size(win, 520, -1);

    var bufs: [8][1024]u8 = undefined;
    var name_buf: [1024]u8 = undefined;
    var ui: Ui = .{
        .win = win,
        .name = entry(seed.name, "My Workspace", &name_buf),
        .notebook = gtk.gtk_notebook_new().?,
        .nvim = entry(seed.nvim_path, "nvim", &bufs[0]),
        .host = entry(seed.ssh_host, "user@host", &bufs[1]),
        .port = entry(seed.ssh_port, "22", &bufs[2]),
        .identity = entry(seed.ssh_identity, "~/.ssh/id_ed25519", &bufs[3]),
        .workspace = entry(seed.dc_workspace, "/path/to/project", &bufs[4]),
        .config = entry(seed.dc_config, ".devcontainer/devcontainer.json", &bufs[5]),
        .rebuild = gtk.gtk_check_button_new_with_label("Rebuild before starting").?,
        .ext = undefined,
        .env_buffer = undefined,
    };
    gtk.gtk_check_button_set_active(ui.rebuild, @intFromBool(seed.dc_rebuild));

    const local = gtk.gtk_label_new("No additional configuration needed.\nNvim will run locally.").?;
    _ = gtk.gtk_notebook_append_page(ui.notebook, local, gtk.gtk_label_new("Local"));
    _ = gtk.gtk_notebook_append_page(ui.notebook, form(&.{ .{ "Host:", ui.host }, .{ "Port:", ui.port }, .{ "Identity:", ui.identity } }), gtk.gtk_label_new("SSH"));
    const ws_row = gtk.gtk_box_new(gtk.GTK_ORIENTATION_HORIZONTAL, 6).?;
    gtk.gtk_box_append(ws_row, ui.workspace);
    const browse = gtk.gtk_button_new_with_label("Browse...").?;
    gtk.gtk_box_append(ws_row, browse);
    _ = gtk.g_signal_connect(browse, "clicked", @ptrCast(&onBrowse), &ui);
    const dc = form(&.{ .{ "Workspace:", ws_row }, .{ "Config:", ui.config } });
    gtk.gtk_grid_attach(dc, ui.rebuild, 1, 2, 1, 1);
    _ = gtk.gtk_notebook_append_page(ui.notebook, dc, gtk.gtk_label_new("Devcontainer"));
    gtk.gtk_notebook_set_current_page(ui.notebook, @intFromEnum(seed.mode));

    const box = gtk.gtk_box_new(gtk.GTK_ORIENTATION_VERTICAL, 8).?;
    for ([_]*const fn (*anyopaque, c_int) callconv(.c) void{
        gtk.gtk_widget_set_margin_start, gtk.gtk_widget_set_margin_end,
        gtk.gtk_widget_set_margin_top,   gtk.gtk_widget_set_margin_bottom,
    }) |set| set(box, 12);
    gtk.gtk_box_append(box, form(&.{.{ "Name:", ui.name }}));
    gtk.gtk_box_append(box, ui.notebook);
    gtk.gtk_box_append(box, form(&.{.{ "Neovim path:", ui.nvim }}));

    const ext_box = gtk.gtk_box_new(gtk.GTK_ORIENTATION_HORIZONTAL, 8).?;
    const ext_names = [_][*:0]const u8{ "ext cmdline", "ext popup", "ext messages", "ext tabline", "ext windows" };
    for (&ui.ext, ext_names, seed.ext) |*c, name, on| {
        c.* = gtk.gtk_check_button_new_with_label(name).?;
        gtk.gtk_check_button_set_active(c.*, @intFromBool(on));
        gtk.gtk_box_append(ext_box, c.*);
    }
    gtk.gtk_box_append(box, ext_box);

    const env_label = gtk.gtk_label_new("Environment (KEY=VALUE per line):").?;
    gtk.gtk_label_set_xalign(env_label, 0);
    gtk.gtk_box_append(box, env_label);
    const env_view = gtk.gtk_text_view_new().?;
    gtk.gtk_widget_set_size_request(env_view, -1, 60);
    ui.env_buffer = gtk.gtk_text_view_get_buffer(env_view).?;
    gtk.gtk_box_append(box, env_view);

    const buttons = gtk.gtk_box_new(gtk.GTK_ORIENTATION_HORIZONTAL, 8).?;
    gtk.gtk_widget_set_halign(buttons, gtk.GTK_ALIGN_END);
    const cancel = gtk.gtk_button_new_with_label("Cancel").?;
    const connect = gtk.gtk_button_new_with_label("Connect").?;
    gtk.gtk_box_append(buttons, cancel);
    gtk.gtk_box_append(buttons, connect);
    gtk.gtk_box_append(box, buttons);
    gtk.gtk_window_set_child(win, box);

    _ = gtk.g_signal_connect(connect, "clicked", @ptrCast(&onConnect), &ui);
    // Enter in any field connects.
    for ([_]*anyopaque{ ui.name, ui.nvim, ui.host, ui.port, ui.identity, ui.workspace, ui.config }) |e| {
        _ = gtk.g_signal_connect(e, "activate", @ptrCast(&onConnect), &ui);
    }
    _ = gtk.g_signal_connect(cancel, "clicked", @ptrCast(&onCancel), &ui);
    _ = gtk.g_signal_connect(win, "close-request", @ptrCast(&onClose), &ui);
    // Esc cancels, as macOS's Cancel button and the Windows dialog do.
    if (gtk.gtk_shortcut_controller_new()) |sc| {
        const trigger = gtk.gtk_shortcut_trigger_parse_string("Escape");
        const action = gtk.gtk_callback_action_new(&onEscape, &ui, null);
        if (gtk.gtk_shortcut_new(trigger, action)) |sh| gtk.gtk_shortcut_controller_add_shortcut(sc, sh);
        gtk.gtk_widget_add_controller(win, sc);
    }
    gtk.gtk_window_set_default_widget(win, connect);
    gtk.gtk_window_present(win);
    // GTK would focus the notebook's tabs, which take Enter for themselves;
    // start where the seeded mode is typed into, or on Connect.
    _ = gtk.gtk_widget_grab_focus(switch (seed.mode) {
        .local => connect,
        .ssh => ui.host,
        .devcontainer => ui.workspace,
    });
    while (!ui.done) _ = gtk.g_main_context_iteration(null, 1);

    defer {
        gtk.gtk_window_destroy(win);
        while (gtk.g_main_context_iteration(null, 0) != 0) {}
    }
    if (!ui.connect) return null;

    var out: Choice = .{ .mode = @enumFromInt(gtk.gtk_notebook_get_current_page(ui.notebook)) };
    out.name = try text(alloc, ui.name);
    const nvim = nvimPath(try text(alloc, ui.nvim));
    if (nvim.ignored) alert(win, "The Neovim path contains a quote character and was ignored.", "The default Neovim is used.");
    out.nvim_path = nvim.path;
    out.ssh_host = try text(alloc, ui.host);
    out.ssh_port = try text(alloc, ui.port);
    out.ssh_identity = try text(alloc, ui.identity);
    out.dc_workspace = try text(alloc, ui.workspace);
    out.dc_config = try text(alloc, ui.config);
    out.dc_rebuild = gtk.gtk_check_button_get_active(ui.rebuild) != 0;
    for (&out.ext, ui.ext) |*o, c| o.* = gtk.gtk_check_button_get_active(c) != 0;
    var s: gtk.GtkTextIter = .{};
    var e: gtk.GtkTextIter = .{};
    gtk.gtk_text_buffer_get_bounds(ui.env_buffer, &s, &e);
    if (gtk.gtk_text_buffer_get_text(ui.env_buffer, &s, &e, 0)) |t| {
        defer gtk.g_free(t);
        out.env = try alloc.dupe(u8, std.mem.span(t));
    }
    return out;
}
