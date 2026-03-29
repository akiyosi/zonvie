// tabbar.zig — ext_tabline UI for Linux frontend.
//
// GL-rendered tab bar matching Windows/macOS visual style.
// Tabs are rendered as colored quads at the top of the main GLArea.

const std = @import("std");
const app_mod = @import("../app.zig");

pub const TAB_BAR_HEIGHT: u32 = 36;

pub const TablineState = struct {
    tabs: std.ArrayListUnmanaged(TabInfo) = .{},
    current_tab: i64 = 0,
    visible: bool = false,

    pub fn deinit(self: *TablineState, alloc: std.mem.Allocator) void {
        for (self.tabs.items) |*tab| {
            if (tab.name_owned) {
                alloc.free(tab.name);
            }
        }
        self.tabs.deinit(alloc);
    }

    pub fn clear(self: *TablineState, alloc: std.mem.Allocator) void {
        for (self.tabs.items) |*tab| {
            if (tab.name_owned) {
                alloc.free(tab.name);
            }
        }
        self.tabs.clearRetainingCapacity();
    }
};

pub const TabInfo = struct {
    tab_handle: i64 = 0,
    name: []const u8 = "",
    name_owned: bool = false,
};
