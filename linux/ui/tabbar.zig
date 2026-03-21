// tabbar.zig — ext_tabline UI for Linux frontend.
//
// GL-rendered tab bar (not native GTK tabs) matching Windows/macOS visual style.
//
// TODO: Implement tab bar rendering:
// - Render tabs as GL quads in the main GLArea (top region)
// - Tab state from on_tabline_update callback
// - Click/drag handling via GTK gesture controllers
// - Support titlebar and sidebar modes

const std = @import("std");
const app_mod = @import("../app.zig");

pub const TAB_BAR_HEIGHT: u32 = 36;

pub const TablineState = struct {
    tabs: std.ArrayListUnmanaged(TabEntry) = .{},
    current_tab: i64 = 0,
    visible: bool = false,

    pub fn deinit(self: *TablineState, alloc: std.mem.Allocator) void {
        self.tabs.deinit(alloc);
    }
};

pub const TabEntry = struct {
    tab_handle: i64,
    name: []const u8 = "",
};
