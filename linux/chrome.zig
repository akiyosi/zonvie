//! The titlebar rules the renderer and the layout read: the caption band's
//! height and which style a desktop ends up with. No window draws a caption
//! of its own yet; the compositor's, where it draws one, is asked for
//! (wl/window.c).

const std = @import("std");
const core = @import("zonvie_core");
const Config = core.config.Config;

/// The top band of a captionless window, logical px: where the window
/// buttons reveal and the drag bar shows.
pub const band_pt = 32;

/// Desktops that draw no titlebar for a client that asks for one (tiling
/// compositors that grant server-side decorations and draw only a border).
/// `xdg_current_desktop` is $XDG_CURRENT_DESKTOP, a colon-separated list.
pub fn desktopDrawsTitlebar(xdg_current_desktop: ?[]const u8) bool {
    const list = xdg_current_desktop orelse return true;
    var it = std.mem.splitScalar(u8, list, ':');
    while (it.next()) |name| {
        for ([_][]const u8{ "Hyprland", "niri", "river" }) |bare|
            if (std.ascii.eqlIgnoreCase(name, bare)) return false;
    }
    return true;
}

/// The style the chrome follows: "native" asks for the desktop's titlebar,
/// and where the desktop draws none the window gets "hidden"'s caption (and
/// its edge-to-edge editor) rather than no caption at all. Titlebar tabs
/// draw their own bar and keep "native".
pub fn effectiveStyle(style: Config.TitlebarStyle, tabline: Config.TablinePlacement, desktop_titlebar: bool) Config.TitlebarStyle {
    if (style == .native and tabline != .titlebar and !desktop_titlebar) return .hidden;
    return style;
}

test "native falls back to hidden where the desktop draws no titlebar" {
    try std.testing.expect(!desktopDrawsTitlebar("Hyprland"));
    try std.testing.expect(!desktopDrawsTitlebar("ubuntu:niri"));
    try std.testing.expect(desktopDrawsTitlebar("KDE"));
    try std.testing.expect(desktopDrawsTitlebar("ubuntu:GNOME"));
    try std.testing.expect(desktopDrawsTitlebar("sway"));
    try std.testing.expect(desktopDrawsTitlebar(null));
    try std.testing.expectEqual(Config.TitlebarStyle.hidden, effectiveStyle(.native, .sidebar, false));
    try std.testing.expectEqual(Config.TitlebarStyle.hidden, effectiveStyle(.native, .other, false));
    try std.testing.expectEqual(Config.TitlebarStyle.native, effectiveStyle(.native, .titlebar, false));
    try std.testing.expectEqual(Config.TitlebarStyle.native, effectiveStyle(.native, .sidebar, true));
    try std.testing.expectEqual(Config.TitlebarStyle.unified, effectiveStyle(.unified, .sidebar, false));
}
