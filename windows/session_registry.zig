const std = @import("std");

pub const SessionInfo = struct {
    hwnd: usize = 0,
    pid: u32 = 0,
    name_buf: [256]u8 = .{0} ** 256,
    name_len: usize = 0,
    title_buf: [256]u8 = .{0} ** 256,
    title_len: usize = 0,

    pub fn name(self: *const SessionInfo) []const u8 {
        return self.name_buf[0..self.name_len];
    }

    pub fn title(self: *const SessionInfo) []const u8 {
        return self.title_buf[0..self.title_len];
    }

    pub fn displayLabel(self: *const SessionInfo) []const u8 {
        if (self.title_len != 0) return self.title();
        if (self.name_len != 0) return self.name();
        return "Session";
    }
};

pub fn writeCurrentSession(
    alloc: std.mem.Allocator,
    pid: u32,
    hwnd: usize,
    name: []const u8,
    title: []const u8,
) void {
    const dir_path = ensureSessionsDir(alloc) catch return;
    defer alloc.free(dir_path);

    const file_name = std.fmt.allocPrint(alloc, "{d}.session", .{pid}) catch return;
    defer alloc.free(file_name);

    const file_path = std.fs.path.join(alloc, &.{ dir_path, file_name }) catch return;
    defer alloc.free(file_path);

    const file = std.fs.createFileAbsolute(file_path, .{ .truncate = true }) catch return;
    defer file.close();

    var buf: [2048]u8 = undefined;
    const text = std.fmt.bufPrint(
        &buf,
        "hwnd={d}\npid={d}\nname={s}\ntitle={s}\n",
        .{ hwnd, pid, name, title },
    ) catch return;
    file.writeAll(text) catch {};
}

pub fn removeSession(alloc: std.mem.Allocator, pid: u32) void {
    const dir_path = ensureSessionsDir(alloc) catch return;
    defer alloc.free(dir_path);

    const file_name = std.fmt.allocPrint(alloc, "{d}.session", .{pid}) catch return;
    defer alloc.free(file_name);

    const file_path = std.fs.path.join(alloc, &.{ dir_path, file_name }) catch return;
    defer alloc.free(file_path);

    std.fs.deleteFileAbsolute(file_path) catch {};
}

pub fn loadSessions(
    alloc: std.mem.Allocator,
    sessions: *std.ArrayListUnmanaged(SessionInfo),
) void {
    sessions.clearRetainingCapacity();

    const dir_path = ensureSessionsDir(alloc) catch return;
    defer alloc.free(dir_path);

    var dir = std.fs.openDirAbsolute(dir_path, .{ .iterate = true }) catch return;
    defer dir.close();

    var it = dir.iterate();
    while (it.next() catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".session")) continue;

        const data = dir.readFileAlloc(alloc, entry.name, 4096) catch continue;
        defer alloc.free(data);

        var info = SessionInfo{};
        var lines = std.mem.splitScalar(u8, data, '\n');
        while (lines.next()) |line| {
            if (std.mem.startsWith(u8, line, "hwnd=")) {
                info.hwnd = std.fmt.parseInt(usize, line["hwnd=".len..], 10) catch 0;
            } else if (std.mem.startsWith(u8, line, "pid=")) {
                info.pid = std.fmt.parseInt(u32, line["pid=".len..], 10) catch 0;
            } else if (std.mem.startsWith(u8, line, "name=")) {
                info.name_len = copyInto(&info.name_buf, line["name=".len..]);
            } else if (std.mem.startsWith(u8, line, "title=")) {
                info.title_len = copyInto(&info.title_buf, line["title=".len..]);
            }
        }

        if (info.hwnd == 0 or info.pid == 0) continue;
        sessions.append(alloc, info) catch return;
    }
}

fn ensureSessionsDir(alloc: std.mem.Allocator) ![]u8 {
    const appdata = try std.process.getEnvVarOwned(alloc, "APPDATA");
    defer alloc.free(appdata);

    const zonvie_dir = try std.fs.path.join(alloc, &.{ appdata, "zonvie" });
    defer alloc.free(zonvie_dir);
    std.fs.makeDirAbsolute(zonvie_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    const sessions_dir = try std.fs.path.join(alloc, &.{ zonvie_dir, "sessions" });
    std.fs.makeDirAbsolute(sessions_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => {
            alloc.free(sessions_dir);
            return err;
        },
    };
    return sessions_dir;
}

fn copyInto(dest: []u8, src: []const u8) usize {
    const copy_len = @min(dest.len, src.len);
    @memset(dest, 0);
    @memcpy(dest[0..copy_len], src[0..copy_len]);
    return copy_len;
}
