//! `:set guifont=*`: GTK's font dialog, as Windows opens ChooseFontW. The
//! "*" is always replaced by the font in use, so guifont is never left as
//! "*"; the dialog opens only once Neovim has drawn, so an initial "*" at
//! attach does not pop it. A pick is written back as "Family:hN", and that
//! broadcast wins over an explicit [font] family. GTK main thread.

const std = @import("std");
const core = @import("zonvie_core");
const clock = core.clock;
const App = @import("app.zig").App;
const gtk = @import("gtk_bindings.zig");
const applog = @import("app_log.zig");

/// From on_guifont (core thread) when the payload is "*".
pub fn request(app: *App) void {
    _ = gtk.g_idle_add(&idleOpen, app);
}

fn idleOpen(data: ?*anyopaque) callconv(.c) c_int {
    const app: *App = @ptrCast(@alignCast(data.?));
    app.mu.lockUncancelable(clock.io());
    var family: [129]u8 = undefined;
    const n = app.preedit_family_len;
    @memcpy(family[0..n], app.preedit_family[0..n]);
    const pt = app.font_pt;
    const drawn = app.surface.committedLayers().len != 0;
    app.mu.unlock(clock.io());
    writeGuifont(app, family[0..n], pt);
    if (!drawn or n == 0) return 0;

    const dialog = gtk.gtk_font_dialog_new() orelse return 0;
    // Seed with the font in use: "Family N" is Pango's description syntax.
    var seed: [160]u8 = undefined;
    const seed_z = std.fmt.bufPrintZ(&seed, "{s} {d}", .{ family[0..n], @round(pt) }) catch return 0;
    const initial = gtk.pango_font_description_from_string(seed_z.ptr);
    defer gtk.pango_font_description_free(initial);
    gtk.gtk_font_dialog_choose_font(dialog, app.window, initial, null, &onChosen, app);
    return 0;
}

fn onChosen(source: ?*anyopaque, result: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
    const app: *App = @ptrCast(@alignCast(data.?));
    defer gtk.g_object_unref(source.?);
    var err: ?*anyopaque = null;
    const desc = gtk.gtk_font_dialog_choose_font_finish(source.?, result.?, &err) orelse {
        applog.appLog("[font_picker] no font chosen\n", .{});
        return; // cancelled
    };
    defer gtk.pango_font_description_free(desc);
    const family = std.mem.span(gtk.pango_font_description_get_family(desc) orelse return);
    var size: f32 = @as(f32, @floatFromInt(gtk.pango_font_description_get_size(desc))) / @as(f32, @floatFromInt(gtk.PANGO_SCALE));
    // An absolute size is device px: GTK's 96 dpi to points.
    if (gtk.pango_font_description_get_size_is_absolute(desc) != 0) size = size * 72.0 / 96.0;
    if (size <= 0) size = app.font_pt;
    app.font_picked.store(true, .release);
    writeGuifont(app, family, size);
}

/// guifont = "Family:hN", commas in the family escaped as guifont reads them.
fn writeGuifont(app: *App, family: []const u8, pt: f32) void {
    const cp = app.corep orelse return;
    if (family.len == 0) return;
    var buf: [320]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    for (family) |ch| {
        if (ch == ',') w.writeByte('\\') catch return;
        w.writeByte(ch) catch return;
    }
    w.print(":h{d}", .{@max(1, @as(i32, @intFromFloat(@round(pt))))}) catch return;
    const value = w.buffered();
    applog.appLog("[font_picker] guifont={s}\n", .{value});
    const name = "guifont";
    core.zonvie_core_set_option_value(cp, name.ptr, name.len, value.ptr, value.len);
}
