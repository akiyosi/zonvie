//! The session's first moments and what a later launch hands it: Neovim has
//! drawn (onReady), and files to open in it ([server] single_instance,
//! single_instance.zig). Main thread only.

const std = @import("std");
const core = @import("zonvie_core");
const App = @import("app.zig").App;

/// Neovim's first screen is committed: what waited for it goes out.
pub fn onReady(app: *App) void {
    if (app.nvim_ready) return;
    app.nvim_ready = true;
    app.start_output.open.store(false, .release);
    const cp = app.corep orelse return;
    if (app.pending_opens.items.len == 0) return;
    sendOpens(app, cp, app.pending_opens.items);
    for (app.pending_opens.items) |p| app.alloc.free(p);
    app.pending_opens.clearRetainingCapacity();
}

/// Files a later launch handed over: `:drop`ped through the core, each in a
/// tab unless open_mode is "current" for a single file; queued until nvim
/// can take them (the core cannot send before it is attached).
pub fn openPaths(app: *App, paths: []const [:0]const u8) void {
    if (paths.len == 0) return;
    if (app.nvim_ready) if (app.corep) |cp| return sendOpens(app, cp, paths);
    for (paths) |p| {
        const owned = app.alloc.dupeZ(u8, p) catch return;
        app.pending_opens.append(app.alloc, owned) catch return app.alloc.free(owned);
    }
}

fn sendOpens(app: *App, cp: *core.zonvie_core, paths: []const [:0]const u8) void {
    var ptrs: [64][*]const u8 = undefined;
    var lens: [64]usize = undefined;
    const n = @min(paths.len, ptrs.len);
    for (paths[0..n], 0..) |p, i| {
        ptrs[i] = p.ptr;
        lens[i] = p.len;
    }
    const tab_per_file = !app.open_mode_current or n > 1;
    core.zonvie_core_drop_paths(cp, &ptrs, &lens, n, @intFromBool(tab_per_file));
}
