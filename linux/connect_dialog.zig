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
    var ui: Ui = .{
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
    const dc = form(&.{ .{ "Workspace:", ui.workspace }, .{ "Config:", ui.config } });
    gtk.gtk_grid_attach(dc, ui.rebuild, 1, 2, 1, 1);
    _ = gtk.gtk_notebook_append_page(ui.notebook, dc, gtk.gtk_label_new("Devcontainer"));
    gtk.gtk_notebook_set_current_page(ui.notebook, @intFromEnum(seed.mode));

    const box = gtk.gtk_box_new(gtk.GTK_ORIENTATION_VERTICAL, 8).?;
    for ([_]*const fn (*anyopaque, c_int) callconv(.c) void{
        gtk.gtk_widget_set_margin_start, gtk.gtk_widget_set_margin_end,
        gtk.gtk_widget_set_margin_top,   gtk.gtk_widget_set_margin_bottom,
    }) |set| set(box, 12);
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
    for ([_]*anyopaque{ ui.nvim, ui.host, ui.port, ui.identity, ui.workspace, ui.config }) |e| {
        _ = gtk.g_signal_connect(e, "activate", @ptrCast(&onConnect), &ui);
    }
    _ = gtk.g_signal_connect(cancel, "clicked", @ptrCast(&onCancel), &ui);
    _ = gtk.g_signal_connect(win, "close-request", @ptrCast(&onClose), &ui);
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
    out.nvim_path = try text(alloc, ui.nvim);
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
