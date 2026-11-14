//! zonvie as ssh's SSH_ASKPASS helper. The SSH session sets
//! ZONVIE_ASKPASS_MODE and points SSH_ASKPASS at this executable; ssh runs it
//! with the prompt as its argument whenever it needs a password or a key
//! passphrase, and reads the answer from stdout. The windows/main.zig
//! askpass mode, with a GTK dialog.

const std = @import("std");
const gtk = @import("gtk_bindings.zig");

pub const env_mode = "ZONVIE_ASKPASS_MODE";

pub fn requested() bool {
    return std.c.getenv(env_mode) != null;
}

const Dialog = struct {
    entry: *anyopaque,
    done: bool = false,
    ok: bool = false,
};

fn onOk(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const d: *Dialog = @ptrCast(@alignCast(data.?));
    d.ok = true;
    d.done = true;
}

fn onCancel(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const d: *Dialog = @ptrCast(@alignCast(data.?));
    d.done = true;
}

fn onClose(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) c_int {
    onCancel(null, data);
    return 1;
}

/// Asks for the answer to `prompt`, writes it to stdout with a newline, and
/// returns the exit code ssh reads: 0 answered, 1 cancelled.
pub fn run(prompt: []const u8) u8 {
    gtk.gtk_init();
    const win = gtk.gtk_window_new() orelse return 1;
    gtk.gtk_window_set_title(win, "zonvie: SSH");
    gtk.gtk_window_set_resizable(win, 0);

    const box = gtk.gtk_box_new(gtk.GTK_ORIENTATION_VERTICAL, 8).?;
    for ([_]*const fn (*anyopaque, c_int) callconv(.c) void{
        gtk.gtk_widget_set_margin_start,
        gtk.gtk_widget_set_margin_end,
        gtk.gtk_widget_set_margin_top,
        gtk.gtk_widget_set_margin_bottom,
    }) |set| set(box, 16);

    var buf: [1024]u8 = undefined;
    const n = @min(prompt.len, buf.len - 1);
    @memcpy(buf[0..n], prompt[0..n]);
    buf[n] = 0;
    const label = gtk.gtk_label_new(@ptrCast(&buf)).?;
    gtk.gtk_label_set_wrap(label, 1);
    gtk.gtk_box_append(box, label);

    const entry = gtk.gtk_password_entry_new().?;
    gtk.gtk_box_append(box, entry);

    const buttons = gtk.gtk_box_new(gtk.GTK_ORIENTATION_HORIZONTAL, 8).?;
    gtk.gtk_widget_set_halign(buttons, gtk.GTK_ALIGN_END);
    const cancel = gtk.gtk_button_new_with_label("Cancel").?;
    const ok = gtk.gtk_button_new_with_label("OK").?;
    gtk.gtk_box_append(buttons, cancel);
    gtk.gtk_box_append(buttons, ok);
    gtk.gtk_box_append(box, buttons);
    gtk.gtk_window_set_child(win, box);

    var d: Dialog = .{ .entry = entry };
    _ = gtk.g_signal_connect(ok, "clicked", @ptrCast(&onOk), &d);
    _ = gtk.g_signal_connect(entry, "activate", @ptrCast(&onOk), &d);
    _ = gtk.g_signal_connect(cancel, "clicked", @ptrCast(&onCancel), &d);
    _ = gtk.g_signal_connect(win, "close-request", @ptrCast(&onClose), &d);
    gtk.gtk_window_present(win);
    _ = gtk.gtk_widget_grab_focus(entry);

    while (!d.done) _ = gtk.g_main_context_iteration(null, 1);

    var code: u8 = 1;
    if (d.ok) {
        const text = std.mem.span(gtk.gtk_editable_get_text(entry));
        writeAll(text);
        writeAll("\n");
        code = 0;
    }
    gtk.gtk_window_destroy(win);
    while (gtk.g_main_context_iteration(null, 0) != 0) {}
    return code;
}

fn writeAll(s: []const u8) void {
    var rest = s;
    while (rest.len > 0) {
        const w = std.c.write(1, rest.ptr, rest.len);
        if (w <= 0) return;
        rest = rest[@intCast(w)..];
    }
}
