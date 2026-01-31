const std = @import("std");
const shared_config = @import("zonvie_core").config;

// Re-export types from shared config
pub const Config = shared_config.Config;
pub const MsgEvent = shared_config.MsgEvent;
pub const MsgViewType = shared_config.MsgViewType;
pub const MsgPosition = shared_config.MsgPosition;
pub const MsgRoute = shared_config.MsgRoute;
pub const RouteResult = shared_config.RouteResult;

/// Windows-specific config loader that finds the config path and delegates to shared config
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

/// Get config file path: %APPDATA%\zonvie\config.toml or %USERPROFILE%\.config\zonvie\config.toml
pub fn getConfigFilePath(alloc: std.mem.Allocator) ![]const u8 {
    // Try %APPDATA%\zonvie\config.toml first
    if (std.process.getEnvVarOwned(alloc, "APPDATA")) |appdata| {
        defer alloc.free(appdata);
        const path = try std.fs.path.join(alloc, &.{ appdata, "zonvie", "config.toml" });

        // Check if file exists
        if (std.fs.accessAbsolute(path, .{})) |_| {
            return path;
        } else |_| {
            alloc.free(path);
        }
    } else |_| {}

    // Fallback to %USERPROFILE%\.config\zonvie\config.toml
    if (std.process.getEnvVarOwned(alloc, "USERPROFILE")) |userprofile| {
        defer alloc.free(userprofile);
        const path = try std.fs.path.join(alloc, &.{ userprofile, ".config", "zonvie", "config.toml" });
        return path;
    } else |_| {}

    return error.NoConfigPath;
}
