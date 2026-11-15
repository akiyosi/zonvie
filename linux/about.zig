//! The About box: the app's name and the core's version, as macOS's About
//! panel and Windows' system-menu item show. GTK main thread only.

const std = @import("std");
const core = @import("zonvie_core");
const App = @import("app.zig").App;
const gtk = @import("gtk_bindings.zig");

pub fn show(app: *App) void {
    gtk.gtk_show_about_dialog(
        app.window,
        "program-name",
        @as([*:0]const u8, "zonvie"),
        "version",
        core.zonvie_version(),
        "comments",
        @as([*:0]const u8, "A high-performance Neovim GUI"),
        "website",
        @as([*:0]const u8, "https://github.com/akiyosi/zonvie"),
        "logo-icon-name",
        @as([*:0]const u8, @import("cli.zig").app_id),
        @as(?*anyopaque, null),
    );
}
