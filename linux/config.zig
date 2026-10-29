// config.zig — Linux-specific config loader (XDG paths).
// Delegates to shared config from core.

const std = @import("std");
const shared_config = @import("zonvie_core").config;
const clock = @import("zonvie_core").clock;

// Re-export types from shared config
pub const Config = shared_config.Config;
pub const MsgEvent = shared_config.MsgEvent;
pub const MsgViewType = shared_config.MsgViewType;
pub const MsgPosition = shared_config.MsgPosition;
pub const MsgRoute = shared_config.MsgRoute;
pub const RouteResult = shared_config.RouteResult;

/// Linux-specific config loader that finds the config path and delegates to shared config
pub fn load(alloc: std.mem.Allocator) Config {
    const result = loadWithPath(alloc);
    if (result.path) |p| alloc.free(p);
    return result.config;
}

/// Load config and return both config and path (caller must free path)
pub fn loadWithPath(alloc: std.mem.Allocator) struct { config: Config, path: ?[]const u8 } {
    const config_path = getConfigFilePath(alloc) catch return .{ .config = Config{ .alloc = alloc }, .path = null };
    return .{
        .config = Config.loadFromPath(alloc, config_path),
        .path = config_path,
    };
}

/// Get config file path: $XDG_CONFIG_HOME/zonvie/config.toml or ~/.config/zonvie/config.toml
pub fn getConfigFilePath(alloc: std.mem.Allocator) ![]const u8 {
    // Try $XDG_CONFIG_HOME/zonvie/config.toml first
    // std.process.Environ needs the block handed to main on POSIX; libc's
    // getenv reads the same environment without threading it through.
    if (std.c.getenv("XDG_CONFIG_HOME")) |xdg| {
        const path = try std.fs.path.join(alloc, &.{ std.mem.span(xdg), "zonvie", "config.toml" });

        // Check if file exists
        if (std.Io.Dir.accessAbsolute(clock.io(), path, .{})) |_| {
            return path;
        } else |_| {
            alloc.free(path);
        }
    }

    // Fallback to ~/.config/zonvie/config.toml
    if (std.c.getenv("HOME")) |home| {
        const path = try std.fs.path.join(alloc, &.{ std.mem.span(home), ".config", "zonvie", "config.toml" });

        if (std.Io.Dir.accessAbsolute(clock.io(), path, .{})) |_| {
            return path;
        } else |_| {
            alloc.free(path);
        }
    }

    return error.NoConfigPath;
}
