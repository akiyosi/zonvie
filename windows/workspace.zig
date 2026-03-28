// workspace.zig — Workspace tile manager for multi-core nvim instances.
//
// Provides the WorkspaceState type that manages multiple zonvie_core instances
// as independent tiles. Each tile has its own core, snapshot texture, and
// connection metadata.
//
// Phase 1: Type definitions and basic lifecycle. The existing App.corep field
// is preserved for backward compatibility; workspace.activeCorep() returns
// the same pointer. Future phases will migrate all corep references.

const std = @import("std");
const c = @import("win32.zig").c;
const core = @import("zonvie_core");
const d3d11 = @import("renderer/d3d11_renderer.zig");

pub const zonvie_core = core.zonvie_core;

pub const ConnectionConfig = struct {
    name_buf: [128]u8 = .{0} ** 128,
    name_len: usize = 0,
    nvim_path_buf: [512]u8 = .{0} ** 512,
    nvim_path_len: usize = 0,
    ssh_host_buf: [256]u8 = .{0} ** 256,
    ssh_host_len: usize = 0,
    ssh_port: ?u16 = null,
    ssh_identity_buf: [512]u8 = .{0} ** 512,
    ssh_identity_len: usize = 0,
    devcontainer_workspace_buf: [512]u8 = .{0} ** 512,
    devcontainer_workspace_len: usize = 0,
    devcontainer_config_buf: [512]u8 = .{0} ** 512,
    devcontainer_config_len: usize = 0,
    ext_cmdline: bool = false,
    ext_popupmenu: bool = false,
    ext_messages: bool = false,
    ext_tabline: bool = false,
    ext_windows: bool = false,
    devcontainer_rebuild: bool = false,

    pub fn setName(self: *ConnectionConfig, value: []const u8) void {
        self.name_len = copyInto(&self.name_buf, value);
    }

    pub fn setNvimPath(self: *ConnectionConfig, value: []const u8) void {
        self.nvim_path_len = copyInto(&self.nvim_path_buf, value);
    }

    pub fn setSSHHost(self: *ConnectionConfig, value: []const u8) void {
        self.ssh_host_len = copyInto(&self.ssh_host_buf, value);
    }

    pub fn setSSHIdentity(self: *ConnectionConfig, value: []const u8) void {
        self.ssh_identity_len = copyInto(&self.ssh_identity_buf, value);
    }

    pub fn setDevcontainerWorkspace(self: *ConnectionConfig, value: []const u8) void {
        self.devcontainer_workspace_len = copyInto(&self.devcontainer_workspace_buf, value);
    }

    pub fn setDevcontainerConfig(self: *ConnectionConfig, value: []const u8) void {
        self.devcontainer_config_len = copyInto(&self.devcontainer_config_buf, value);
    }

    pub fn name(self: *const ConnectionConfig) []const u8 {
        return self.name_buf[0..self.name_len];
    }

    pub fn nvimPath(self: *const ConnectionConfig) []const u8 {
        return self.nvim_path_buf[0..self.nvim_path_len];
    }

    pub fn sshHost(self: *const ConnectionConfig) []const u8 {
        return self.ssh_host_buf[0..self.ssh_host_len];
    }

    pub fn sshIdentity(self: *const ConnectionConfig) []const u8 {
        return self.ssh_identity_buf[0..self.ssh_identity_len];
    }

    pub fn devcontainerWorkspace(self: *const ConnectionConfig) []const u8 {
        return self.devcontainer_workspace_buf[0..self.devcontainer_workspace_len];
    }

    pub fn devcontainerConfig(self: *const ConnectionConfig) []const u8 {
        return self.devcontainer_config_buf[0..self.devcontainer_config_len];
    }

    pub fn isSSH(self: *const ConnectionConfig) bool {
        return self.ssh_host_len != 0;
    }

    pub fn isDevcontainer(self: *const ConnectionConfig) bool {
        return self.devcontainer_workspace_len != 0;
    }

    pub fn connectionType(self: *const ConnectionConfig) ConnectionType {
        if (self.isSSH()) return .ssh;
        if (self.isDevcontainer()) return .devcontainer;
        return .local;
    }

    pub fn displayName(self: *const ConnectionConfig, buf: []u8) []const u8 {
        if (self.name_len != 0) return self.name();
        if (self.ssh_host_len != 0) {
            return std.fmt.bufPrint(buf, "SSH: {s}", .{self.sshHost()}) catch "SSH";
        }
        if (self.devcontainer_workspace_len != 0) {
            return std.fmt.bufPrint(buf, "Dev: {s}", .{self.devcontainerWorkspace()}) catch "Devcontainer";
        }
        return "Local";
    }
};

/// How this tile connects to nvim.
pub const ConnectionType = enum(u8) {
    local = 0,
    ssh = 1,
    devcontainer = 2,
};

/// Per-tile callback context. Passed as the `ctx` parameter to
/// zonvie_core_create so that callbacks can identify which tile they
/// belong to.
pub const TileContext = struct {
    app: *anyopaque, // *App (avoid circular import)
    tile_index: u8,
};

/// One workspace slot.
pub const Tile = struct {
    corep: ?*zonvie_core = null,
    ctx: ?*TileContext = null,
    connection: ConnectionType = .local,
    config: ConnectionConfig = .{},
    started: bool = false,
    is_suspended: bool = false,

    // Title from nvim (set_title callback)
    title_buf: [256]u8 = .{0} ** 256,
    title_len: usize = 0,

    // Snapshot of tile content for workspace overlay thumbnail display
    snapshot: ?d3d11.Renderer.SnapshotTexture = null,

    pub fn isOccupied(self: *const Tile) bool {
        return self.corep != null and self.started;
    }
};

/// Manages multiple tiles, each holding an independent nvim process.
pub const WorkspaceState = struct {
    alloc: std.mem.Allocator,
    tiles: std.ArrayListUnmanaged(Tile) = .{},
    active_tile: u8 = 0,
    scale: f32 = 1.0,
    scale_step: f32 = 0.2,
    max_tiles: u8 = 9,
    system_menu_added_items: u8 = 0,

    // Scale animation state (driven by TIMER_WORKSPACE_ANIM in window.zig).
    // When animating=true, `scale` is lerped from anim_start_scale toward
    // anim_target_scale over anim_duration_ms starting at anim_start_tick_ms.
    animating: bool = false,
    anim_start_scale: f32 = 1.0,
    anim_target_scale: f32 = 1.0,
    anim_start_tick_ms: u32 = 0,
    anim_duration_ms: u32 = 220,

    pub fn init(alloc: std.mem.Allocator) WorkspaceState {
        var ws = WorkspaceState{ .alloc = alloc };
        // Pre-create the first tile (populated during core creation)
        ws.tiles.append(alloc, .{}) catch {};
        return ws;
    }

    pub fn deinit(self: *WorkspaceState) void {
        // Note: core destruction is handled by the caller (App.deinit)
        // because it needs to happen in the correct order relative to
        // renderer/atlas cleanup.
        for (self.tiles.items) |*tile| {
            if (tile.snapshot) |*snap| {
                d3d11.Renderer.releaseSnapshot(snap);
                tile.snapshot = null;
            }
            if (tile.ctx) |ctx_ptr| {
                const typed: *TileContext = @ptrCast(@alignCast(ctx_ptr));
                self.alloc.destroy(typed);
                tile.ctx = null;
            }
        }
        self.tiles.deinit(self.alloc);
    }

    /// Return the core pointer for the active tile (may be null if empty).
    pub fn activeCorep(self: *const WorkspaceState) ?*zonvie_core {
        if (self.active_tile >= self.tiles.items.len) return null;
        return self.tiles.items[self.active_tile].corep;
    }

    /// Return a mutable reference to the active tile.
    pub fn activeTile(self: *WorkspaceState) *Tile {
        return &self.tiles.items[self.active_tile];
    }

    /// Add a new empty tile. Returns the index, or error if at capacity.
    pub fn addTile(self: *WorkspaceState, connection: ConnectionType) !u8 {
        if (self.tiles.items.len >= self.max_tiles) return error.MaxTilesReached;
        try self.tiles.append(self.alloc, .{ .connection = connection });
        return @intCast(self.tiles.items.len - 1);
    }

    /// Attach a core to an existing tile.
    pub fn attachCore(self: *WorkspaceState, index: u8, corep: *zonvie_core) void {
        if (index >= self.tiles.items.len) return;
        self.tiles.items[index].corep = corep;
    }

    pub fn setTileConfig(self: *WorkspaceState, index: u8, config: ConnectionConfig) void {
        if (index >= self.tiles.items.len) return;
        self.tiles.items[index].config = config;
        self.tiles.items[index].connection = config.connectionType();
    }

    pub fn setTileStarted(self: *WorkspaceState, index: u8, started: bool) void {
        if (index >= self.tiles.items.len) return;
        self.tiles.items[index].started = started;
    }

    pub fn setTileTitle(self: *WorkspaceState, index: u8, title: []const u8) void {
        if (index >= self.tiles.items.len) return;
        const tile = &self.tiles.items[index];
        tile.title_len = copyInto(&tile.title_buf, title);
    }

    /// Remove a tile and clean up its TileContext. Core destruction is
    /// the caller's responsibility.
    pub fn removeTile(self: *WorkspaceState, index: u8) void {
        if (index >= self.tiles.items.len) return;
        if (self.tiles.items.len <= 1) return; // keep at least one

        var tile = &self.tiles.items[index];
        if (tile.ctx) |ctx_ptr| {
            const typed: *TileContext = @ptrCast(@alignCast(ctx_ptr));
            self.alloc.destroy(typed);
            tile.ctx = null;
        }
        _ = self.tiles.orderedRemove(index);

        if (self.active_tile >= self.tiles.items.len) {
            self.active_tile = @intCast(self.tiles.items.len - 1);
        }
    }

    /// Switch the active tile index. The caller is responsible for
    /// snapshot capture and core/view rewiring.
    pub fn switchToTile(self: *WorkspaceState, index: u8) void {
        if (index >= self.tiles.items.len) return;
        self.active_tile = index;
    }

    // Scale control for workspace overview
    pub fn scaleIn(self: *WorkspaceState) void {
        self.scale = @min(1.0, self.scale + self.scale_step);
    }

    pub fn scaleOut(self: *WorkspaceState) void {
        self.scale = @max(0.0, self.scale - self.scale_step);
    }

    pub fn isOverviewVisible(self: *const WorkspaceState) bool {
        return self.scale <= 0.999 or self.animating;
    }

    /// Begin a smooth scale animation to `target` over `duration_ms`.
    /// Caller is responsible for starting the per-tick timer.
    pub fn beginScaleAnim(self: *WorkspaceState, target: f32, duration_ms: u32, now_ms: u32) void {
        self.anim_start_scale = self.scale;
        self.anim_target_scale = target;
        self.anim_start_tick_ms = now_ms;
        self.anim_duration_ms = if (duration_ms == 0) 1 else duration_ms;
        self.animating = true;
    }

    /// Advance the scale animation. Returns true while still animating,
    /// false when the target has been reached (caller should stop its timer).
    pub fn tickScaleAnim(self: *WorkspaceState, now_ms: u32) bool {
        if (!self.animating) return false;
        const elapsed: u32 = now_ms -% self.anim_start_tick_ms;
        if (elapsed >= self.anim_duration_ms) {
            self.scale = self.anim_target_scale;
            self.animating = false;
            return false;
        }
        const t: f32 = @as(f32, @floatFromInt(elapsed)) / @as(f32, @floatFromInt(self.anim_duration_ms));
        // Ease-in-out cubic
        const eased: f32 = if (t < 0.5)
            4.0 * t * t * t
        else blk: {
            const u = -2.0 * t + 2.0;
            break :blk 1.0 - (u * u * u) * 0.5;
        };
        self.scale = self.anim_start_scale + (self.anim_target_scale - self.anim_start_scale) * eased;
        return true;
    }

    // MARK: - Window system menu (title bar icon / Alt+Space)

    // Command IDs for system menu items (must not collide with SC_* constants).
    // SC_* values are in the 0xF000+ range; we use 0xE000+.
    pub const SC_WS_NEW_SESSION: c_uint = 0xE001;
    pub const SC_WS_SESSION_BASE: c_uint = 0xE100; // + tile index

    /// Populate the system menu with workspace items.
    /// Called on WM_CREATE and can be called again to refresh.
    pub fn updateSystemMenu(self: *WorkspaceState, hwnd: c.HWND) void {
        const sys_menu = c.GetSystemMenu(hwnd, 0); // FALSE = get current menu
        if (sys_menu == null) return;

        var remaining = self.system_menu_added_items;
        while (remaining > 0) : (remaining -= 1) {
            const count = c.GetMenuItemCount(sys_menu);
            if (count <= 0) break;
            _ = c.RemoveMenu(sys_menu, @intCast(count - 1), c.MF_BYPOSITION);
        }
        self.system_menu_added_items = 0;

        // Separator
        _ = c.AppendMenuW(sys_menu, c.MF_SEPARATOR, 0, null);
        self.system_menu_added_items += 1;

        // "New Session..."
        _ = c.AppendMenuW(sys_menu, c.MF_STRING, SC_WS_NEW_SESSION, toWide("New Session..."));
        self.system_menu_added_items += 1;

        // Active sessions
        for (self.tiles.items, 0..) |tile, i| {
            if (!tile.isOccupied()) continue;
            var buf: [300]u16 = undefined;
            var display_name_buf: [576]u8 = undefined;
            const prefix: []const u8 = if (i == self.active_tile) "\xE2\x97\x8F " else "  "; // ● or spaces
            const title = if (tile.title_len > 0) tile.title_buf[0..tile.title_len] else tile.config.displayName(&display_name_buf);
            var pos: usize = 0;
            for (prefix) |byte| {
                if (pos >= buf.len - 1) break;
                buf[pos] = byte;
                pos += 1;
            }
            for (title) |byte| {
                if (pos >= buf.len - 1) break;
                buf[pos] = byte;
                pos += 1;
            }
            buf[pos] = 0;
            _ = c.AppendMenuW(sys_menu, c.MF_STRING, SC_WS_SESSION_BASE + @as(c_uint, @intCast(i)), &buf);
            self.system_menu_added_items += 1;
        }
    }

    fn toWide(comptime s: []const u8) [*:0]const u16 {
        const buf = comptime blk: {
            var b: [s.len:0]u16 = undefined;
            for (s, 0..) |byte, i| {
                b[i] = byte;
            }
            break :blk b;
        };
        return &buf;
    }
};

fn copyInto(dest: []u8, src: []const u8) usize {
    if (dest.len == 0) return 0;
    const copy_len = @min(src.len, dest.len);
    @memset(dest, 0);
    @memcpy(dest[0..copy_len], src[0..copy_len]);
    return copy_len;
}
