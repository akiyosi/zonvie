const std = @import("std");
const toml = @import("toml");

/// Message event types for routing
pub const MsgEvent = enum {
    msg_show,
    msg_showmode,
    msg_showcmd,
    msg_ruler,
    msg_history_show,

    pub fn fromString(s: []const u8) ?MsgEvent {
        if (std.mem.eql(u8, s, "msg_show")) return .msg_show;
        if (std.mem.eql(u8, s, "msg_showmode")) return .msg_showmode;
        if (std.mem.eql(u8, s, "msg_showcmd")) return .msg_showcmd;
        if (std.mem.eql(u8, s, "msg_ruler")) return .msg_ruler;
        if (std.mem.eql(u8, s, "msg_history_show")) return .msg_history_show;
        return null;
    }
};

/// View types for message display
pub const MsgViewType = enum(u8) {
    mini = 0,
    ext_float = 1,
    confirm = 2,
    split = 3,
    none = 4,
    notification = 5,

    pub fn fromString(s: []const u8) ?MsgViewType {
        if (std.mem.eql(u8, s, "mini")) return .mini;
        if (std.mem.eql(u8, s, "ext-float")) return .ext_float;
        if (std.mem.eql(u8, s, "confirm")) return .confirm;
        if (std.mem.eql(u8, s, "split")) return .split;
        if (std.mem.eql(u8, s, "none")) return .none;
        if (std.mem.eql(u8, s, "notification")) return .notification;
        return null;
    }
};

/// Position anchor for message views
pub const MsgPosition = enum {
    display, // Display-based, independent of Neovim window
    window, // Neovim window-based (main or external window)
    grid, // Grid-based (current cursor grid)

    pub fn fromString(s: []const u8) ?MsgPosition {
        if (std.mem.eql(u8, s, "display")) return .display;
        if (std.mem.eql(u8, s, "window")) return .window;
        if (std.mem.eql(u8, s, "grid")) return .grid;
        return null;
    }
};

/// A single routing rule
pub const MsgRoute = struct {
    event: MsgEvent,
    kinds: ?[]const []const u8 = null, // null = match all kinds
    view: MsgViewType,
    timeout: ?f32 = null, // null = use default
    min_height: ?u32 = null, // null = no minimum line filter
    max_height: ?u32 = null, // null = no maximum line filter
    /// If true, automatically dismiss return_prompt by sending <CR>.
    /// null = use view default (split/none -> true, others -> false)
    auto_dismiss: ?bool = null,

    /// Get auto_dismiss value, using view default if not specified
    pub fn getAutoDismiss(self: MsgRoute) bool {
        if (self.auto_dismiss) |ad| return ad;
        // View defaults: split, none, notification don't show prompts, so auto-dismiss
        return switch (self.view) {
            .split, .none, .notification => true,
            .mini, .ext_float, .confirm => false,
        };
    }

    /// Check if this route matches the given event, kind, and line count
    pub fn matches(self: MsgRoute, event: MsgEvent, kind: []const u8, line_count: u32) bool {
        if (self.event != event) return false;

        // Check min_height filter
        if (self.min_height) |min| {
            if (line_count < min) return false;
        }

        // Check max_height filter
        if (self.max_height) |max| {
            if (line_count > max) return false;
        }

        // If no kind filter, match all
        if (self.kinds == null) return true;

        // Check if kind is in the list
        for (self.kinds.?) |k| {
            if (std.mem.eql(u8, k, kind)) return true;
        }
        return false;
    }
};

/// Result of routing a message
pub const RouteResult = struct {
    view: MsgViewType,
    timeout: f32, // -1 = no auto-hide, 0 = use default
    /// If true, auto-dismiss return_prompt by sending <CR> before displaying
    auto_dismiss: bool,
};

/// Default routes when none configured
pub const default_routes = [_]MsgRoute{
    // Confirm dialogs (note: confirm/confirm_sub/return_prompt are hardcoded to .confirm view)
    .{ .event = .msg_show, .kinds = &.{ "confirm", "confirm_sub", "return_prompt" }, .view = .confirm },
    // Error messages
    .{ .event = .msg_show, .kinds = &.{ "emsg", "echoerr", "lua_error", "rpc_error" }, .view = .ext_float, .timeout = 0 },
    // Warning messages
    .{ .event = .msg_show, .kinds = &.{"wmsg"}, .view = .ext_float },
    // Search count
    .{ .event = .msg_show, .kinds = &.{"search_count"}, .view = .mini, .timeout = 2.0 },
    // Normal echo (fallback for msg_show)
    .{ .event = .msg_show, .view = .ext_float },
    // Mode display
    .{ .event = .msg_showmode, .view = .mini },
    .{ .event = .msg_showcmd, .view = .mini },
    .{ .event = .msg_ruler, .view = .mini },
    // History
    .{ .event = .msg_history_show, .view = .split },
};

/// Zonvie configuration (nested structure for compatibility with existing code)
pub const Config = struct {
    neovim: NeovimConfig = .{},
    font: FontConfig = .{},
    window: WindowConfig = .{},
    scrollbar: ScrollbarConfig = .{},
    cmdline: CmdlineConfig = .{},
    popup: PopupConfig = .{},
    messages: MessagesConfig = .{},
    tabline: TablineConfig = .{},
    windows: WindowsConfig = .{},
    log: LogConfig = .{},
    performance: PerformanceConfig = .{},
    ime: IMEConfig = .{},

    // Internal state
    alloc: ?std.mem.Allocator = null,
    routes_allocated: bool = false,

    pub const NeovimConfig = struct {
        path: []const u8 = "nvim",
        wsl: bool = false,
        wsl_distro: ?[]const u8 = null,
        ssh: bool = false,
        ssh_host: ?[]const u8 = null,
        ssh_port: ?u16 = null,
        ssh_identity: ?[]const u8 = null,
    };

    pub const FontConfig = struct {
        family: []const u8 = "Consolas",
        size: f32 = 14.0,
        linespace: i32 = 0,
    };

    pub const WindowConfig = struct {
        opacity: f32 = 1.0,
        blur: bool = false,
        blur_radius: i32 = 20,
    };

    pub const ScrollbarConfig = struct {
        enabled: bool = true,
        show_mode: []const u8 = "scroll",
        opacity: f32 = 0.7,
        delay: f32 = 1.0,

        pub fn hasMode(self: ScrollbarConfig, mode: []const u8) bool {
            var it = std.mem.splitScalar(u8, self.show_mode, ',');
            while (it.next()) |part| {
                const trimmed = std.mem.trim(u8, part, " \t");
                if (std.mem.eql(u8, trimmed, mode)) return true;
            }
            return false;
        }

        pub fn isAlways(self: ScrollbarConfig) bool {
            return self.hasMode("always");
        }

        pub fn isHover(self: ScrollbarConfig) bool {
            return self.hasMode("hover");
        }

        pub fn isScroll(self: ScrollbarConfig) bool {
            return self.hasMode("scroll");
        }
    };

    pub const CmdlineConfig = struct {
        external: bool = false,
    };

    pub const PopupConfig = struct {
        external: bool = false,
    };

    pub const MsgPosConfig = struct {
        ext_float: MsgPosition = .window,
        mini: MsgPosition = .grid,
    };

    pub const MessagesConfig = struct {
        external: bool = false,
        msg_pos: MsgPosConfig = .{},
        routes: []const MsgRoute = &default_routes,
    };

    pub const TablineConfig = struct {
        external: bool = false,
    };

    pub const WindowsConfig = struct {
        external: bool = false,
    };

    pub const LogConfig = struct {
        enabled: bool = false,
        path: ?[]const u8 = null,
    };

    pub const PerformanceConfig = struct {
        glyph_cache_ascii_size: u32 = 512,
        glyph_cache_non_ascii_size: u32 = 256,
        hl_cache_size: u32 = 512,
    };

    pub const IMEConfig = struct {
        disable_on_activate: bool = false,
        disable_on_modechange: bool = false,
    };

    const Self = @This();

    /// Load configuration from TOML file
    pub fn loadFromPath(alloc: std.mem.Allocator, config_path: []const u8) Self {
        var config = Self{ .alloc = alloc };

        const file = std.fs.openFileAbsolute(config_path, .{}) catch return config;
        defer file.close();

        const content = file.readToEndAlloc(alloc, 1024 * 1024) catch return config;
        defer alloc.free(content);

        config.parseToml(content) catch {
            return config;
        };

        return config;
    }

    /// Parse TOML content using toml library
    fn parseToml(self: *Self, content: []const u8) !void {
        const alloc = self.alloc orelse return;

        var parser = toml.Parser(TomlConfig).init(alloc);
        defer parser.deinit();

        const result = parser.parseString(content) catch |err| {
            return err;
        };
        defer result.deinit();

        const cfg = result.value;

        // Apply parsed values
        if (cfg.neovim) |n| {
            if (n.path) |p| self.neovim.path = alloc.dupe(u8, p) catch self.neovim.path;
            if (n.wsl) |w| self.neovim.wsl = w;
            if (n.wsl_distro) |d| self.neovim.wsl_distro = alloc.dupe(u8, d) catch null;
            if (n.ssh) |s| self.neovim.ssh = s;
            if (n.ssh_host) |h| self.neovim.ssh_host = alloc.dupe(u8, h) catch null;
            if (n.ssh_port) |p| self.neovim.ssh_port = p;
            if (n.ssh_identity) |i| self.neovim.ssh_identity = alloc.dupe(u8, i) catch null;
        }

        if (cfg.font) |f| {
            if (f.family) |fam| self.font.family = alloc.dupe(u8, fam) catch self.font.family;
            if (f.size) |s| self.font.size = s;
            if (f.linespace) |l| self.font.linespace = l;
        }

        if (cfg.window) |w| {
            if (w.opacity) |o| self.window.opacity = @max(0.0, @min(1.0, o));
            if (w.blur) |b| self.window.blur = b;
            if (w.blur_radius) |r| self.window.blur_radius = @max(1, @min(100, r));
        }

        if (cfg.scrollbar) |s| {
            if (s.enabled) |e| self.scrollbar.enabled = e;
            if (s.show_mode) |m| self.scrollbar.show_mode = alloc.dupe(u8, m) catch self.scrollbar.show_mode;
            if (s.opacity) |o| self.scrollbar.opacity = @max(0.0, @min(1.0, o));
            if (s.delay) |d| self.scrollbar.delay = @max(0.1, @min(10.0, d));
        }

        if (cfg.cmdline) |cmd| {
            if (cmd.external) |e| self.cmdline.external = e;
        }

        if (cfg.popup) |p| {
            if (p.external) |e| self.popup.external = e;
        }

        if (cfg.messages) |m| {
            if (m.external) |e| self.messages.external = e;

            // Parse msg_pos
            if (m.msg_pos) |pos| {
                if (pos.@"ext-float") |ef| {
                    if (MsgPosition.fromString(ef)) |p| self.messages.msg_pos.ext_float = p;
                }
                if (pos.mini) |mi| {
                    if (MsgPosition.fromString(mi)) |p| self.messages.msg_pos.mini = p;
                }
            }

            // Parse routes
            if (m.routes) |routes| {
                var route_list: std.ArrayList(MsgRoute) = .{};
                for (routes) |r| {
                    if (r.event) |event_str| {
                        if (MsgEvent.fromString(event_str)) |event| {
                            const view = if (r.view) |v| MsgViewType.fromString(v) orelse .ext_float else .ext_float;

                            // Parse kinds array
                            var kinds: ?[]const []const u8 = null;
                            if (r.kind) |kind_arr| {
                                var kinds_list: std.ArrayList([]const u8) = .{};
                                for (kind_arr) |k| {
                                    kinds_list.append(alloc, alloc.dupe(u8, k) catch continue) catch continue;
                                }
                                kinds = kinds_list.toOwnedSlice(alloc) catch null;
                            }

                            route_list.append(alloc, .{
                                .event = event,
                                .kinds = kinds,
                                .view = view,
                                .timeout = r.timeout,
                                .min_height = r.min_height,
                                .max_height = r.max_height,
                            }) catch continue;
                        }
                    }
                }
                if (route_list.items.len > 0) {
                    self.messages.routes = route_list.toOwnedSlice(alloc) catch &default_routes;
                    self.routes_allocated = true;
                }
            }
        }

        if (cfg.tabline) |t| {
            if (t.external) |e| self.tabline.external = e;
        }

        if (cfg.windows) |w| {
            if (w.external) |e| self.windows.external = e;
        }

        if (cfg.log) |l| {
            if (l.enabled) |e| self.log.enabled = e;
            if (l.path) |p| self.log.path = alloc.dupe(u8, p) catch null;
        }

        if (cfg.performance) |p| {
            if (p.glyph_cache_ascii_size) |s| self.performance.glyph_cache_ascii_size = @max(128, s);
            if (p.glyph_cache_non_ascii_size) |s| self.performance.glyph_cache_non_ascii_size = @max(64, s);
            if (p.hl_cache_size) |s| self.performance.hl_cache_size = @max(64, @min(2048, s));
        }

        if (cfg.ime) |i| {
            if (i.disable_on_activate) |v| self.ime.disable_on_activate = v;
            if (i.disable_on_modechange) |v| self.ime.disable_on_modechange = v;
        }
    }

    /// Route a message to the appropriate view
    /// line_count: number of lines in the message (used for min_height/max_height filters)
    pub fn routeMessage(self: *const Self, event: MsgEvent, kind: []const u8, line_count: u32) RouteResult {
        const default_timeout: f32 = 4.0; // 4 seconds default

        // Confirm dialogs are ALWAYS routed to confirm view (hardcoded, not configurable)
        // This prevents users from accidentally routing confirm/confirm_sub/return_prompt
        // to split or other views where interactive input is not possible.
        if (event == .msg_show) {
            if (std.mem.eql(u8, kind, "confirm") or
                std.mem.eql(u8, kind, "confirm_sub") or
                std.mem.eql(u8, kind, "return_prompt"))
            {
                return .{ .view = .confirm, .timeout = 0, .auto_dismiss = false }; // timeout=0 means no auto-hide
            }
        }

        for (self.messages.routes) |route| {
            if (route.matches(event, kind, line_count)) {
                return .{
                    .view = route.view,
                    .timeout = route.timeout orelse default_timeout,
                    .auto_dismiss = route.getAutoDismiss(),
                };
            }
        }

        // No match - default to none (hide, auto-dismiss)
        return .{ .view = .none, .timeout = 0, .auto_dismiss = true };
    }

    /// Free allocated memory
    pub fn deinit(self: *Self) void {
        const alloc = self.alloc orelse return;

        // Default config for pointer comparison
        const default = Config{};

        // Free duplicated neovim strings
        if (self.neovim.path.ptr != default.neovim.path.ptr) {
            alloc.free(self.neovim.path);
        }
        if (self.neovim.wsl_distro) |s| {
            alloc.free(s);
        }
        if (self.neovim.ssh_host) |s| {
            alloc.free(s);
        }
        if (self.neovim.ssh_identity) |s| {
            alloc.free(s);
        }

        // Free duplicated font.family
        if (self.font.family.ptr != default.font.family.ptr) {
            alloc.free(self.font.family);
        }

        // Free duplicated scrollbar.show_mode
        if (self.scrollbar.show_mode.ptr != default.scrollbar.show_mode.ptr) {
            alloc.free(self.scrollbar.show_mode);
        }

        // Free duplicated log.path
        if (self.log.path) |s| {
            alloc.free(s);
        }

        // Free allocated routes
        if (self.routes_allocated) {
            for (self.messages.routes) |route| {
                if (route.kinds) |kinds| {
                    for (kinds) |k| {
                        alloc.free(k);
                    }
                    alloc.free(kinds);
                }
            }
            alloc.free(self.messages.routes);
        }
    }
};

// TOML parsing structures (match config.toml format)
const TomlConfig = struct {
    neovim: ?TomlNeovim = null,
    font: ?TomlFont = null,
    window: ?TomlWindow = null,
    scrollbar: ?TomlScrollbar = null,
    cmdline: ?TomlCmdline = null,
    popup: ?TomlPopup = null,
    messages: ?TomlMessages = null,
    tabline: ?TomlTabline = null,
    windows: ?TomlWindows = null,
    log: ?TomlLog = null,
    performance: ?TomlPerformance = null,
    ime: ?TomlIME = null,
};

const TomlNeovim = struct {
    path: ?[]const u8 = null,
    wsl: ?bool = null,
    wsl_distro: ?[]const u8 = null,
    ssh: ?bool = null,
    ssh_host: ?[]const u8 = null,
    ssh_port: ?u16 = null,
    ssh_identity: ?[]const u8 = null,
};

const TomlFont = struct {
    family: ?[]const u8 = null,
    size: ?f32 = null,
    linespace: ?i32 = null,
};

const TomlWindow = struct {
    opacity: ?f32 = null,
    blur: ?bool = null,
    blur_radius: ?i32 = null,
};

const TomlScrollbar = struct {
    enabled: ?bool = null,
    show_mode: ?[]const u8 = null,
    opacity: ?f32 = null,
    delay: ?f32 = null,
};

const TomlCmdline = struct {
    external: ?bool = null,
};

const TomlPopup = struct {
    external: ?bool = null,
};

const TomlMsgPos = struct {
    @"ext-float": ?[]const u8 = null,
    mini: ?[]const u8 = null,
};

const TomlMessages = struct {
    external: ?bool = null,
    msg_pos: ?TomlMsgPos = null,
    routes: ?[]const TomlRoute = null,
};

const TomlRoute = struct {
    event: ?[]const u8 = null,
    kind: ?[]const []const u8 = null,
    view: ?[]const u8 = null,
    timeout: ?f32 = null,
    min_height: ?u32 = null,
    max_height: ?u32 = null,
};

const TomlTabline = struct {
    external: ?bool = null,
};

const TomlWindows = struct {
    external: ?bool = null,
};

const TomlLog = struct {
    enabled: ?bool = null,
    path: ?[]const u8 = null,
};

const TomlPerformance = struct {
    glyph_cache_ascii_size: ?u32 = null,
    glyph_cache_non_ascii_size: ?u32 = null,
    hl_cache_size: ?u32 = null,
};

const TomlIME = struct {
    disable_on_activate: ?bool = null,
    disable_on_modechange: ?bool = null,
};
