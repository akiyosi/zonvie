const std = @import("std");
const shared_config = @import("zonvie_core").config;
const clock = @import("zonvie_core").clock;
const scroll_policy = @import("scroll/settle_policy.zig");

// Re-export types from shared config
pub const Config = shared_config.Config;
pub const MsgEvent = shared_config.MsgEvent;
pub const MsgViewType = shared_config.MsgViewType;
pub const MsgPosition = shared_config.MsgPosition;
pub const MsgRoute = shared_config.MsgRoute;
pub const RouteResult = shared_config.RouteResult;
pub const LargeJumpBehavior = scroll_policy.LargeJumpBehavior;

/// Windows-specific config loader that finds the config path and delegates to shared config
pub fn load(alloc: std.mem.Allocator) Config {
    const result = loadWithPath(alloc);
    if (result.path) |p| alloc.free(p);
    return result.config;
}

/// Load config and return both config and path (caller must free path)
pub fn loadWithPath(alloc: std.mem.Allocator) struct {
    config: Config,
    path: ?[]const u8,
    large_jump_behavior: LargeJumpBehavior,
    large_jump_behavior_invalid: bool,
} {
    const config_path = getConfigFilePath(alloc) catch return .{ .config = Config{ .alloc = alloc }, .path = null, .large_jump_behavior = .partial, .large_jump_behavior_invalid = false };
    const config = Config.loadFromPath(alloc, config_path);
    const behavior = scroll_policy.parseBehaviorString(config.scroll.large_jump_behavior);
    return .{ .config = config, .path = config_path, .large_jump_behavior = behavior.behavior, .large_jump_behavior_invalid = behavior.invalid };
}

/// Get config file path: %APPDATA%\zonvie\config.toml or %USERPROFILE%\.config\zonvie\config.toml
pub fn getConfigFilePath(alloc: std.mem.Allocator) ![]const u8 {
    // Try %APPDATA%\zonvie\config.toml first
    // 0.16: std.process.getEnvVarOwned was removed; env access goes through
    // std.process.Environ. On Windows `.block = .global` reads the PEB-backed
    // environment, and getAlloc returns owned memory freed with alloc.free.
    if ((std.process.Environ{ .block = .global }).getAlloc(alloc, "APPDATA")) |appdata| {
        defer alloc.free(appdata);
        const path = try std.fs.path.join(alloc, &.{ appdata, "zonvie", "config.toml" });

        // Check if file exists
        if (std.Io.Dir.accessAbsolute(clock.io(), path, .{})) |_| {
            return path;
        } else |_| {
            alloc.free(path);
        }
    } else |_| {}

    // Fallback to %USERPROFILE%\.config\zonvie\config.toml
    if ((std.process.Environ{ .block = .global }).getAlloc(alloc, "USERPROFILE")) |userprofile| {
        defer alloc.free(userprofile);
        const path = try std.fs.path.join(alloc, &.{ userprofile, ".config", "zonvie", "config.toml" });

        if (std.Io.Dir.accessAbsolute(clock.io(), path, .{})) |_| {
            return path;
        } else |_| {
            alloc.free(path);
        }
    } else |_| {}

    return error.NoConfigPath;
}
