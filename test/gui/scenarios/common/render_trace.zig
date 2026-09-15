// Verify that the real frontend stamps core and consumer logs with one ID.
const std = @import("std");
const builtin = @import("builtin");
const Gui = @import("../../driver.zig").Gui;
const gui_io = @import("../../gui_io.zig");

fn flushId(line: []const u8) ?u64 {
    const start = (std.mem.indexOf(u8, line, "flush=") orelse return null) + 6;
    const tail = line[start..];
    const end = std.mem.indexOfScalar(u8, tail, ' ') orelse tail.len;
    return std.fmt.parseInt(u64, tail[0..end], 10) catch null;
}

pub fn run(alloc: std.mem.Allocator) !void {
    const path = "tmp/gui_render_trace.log";
    try std.Io.Dir.cwd().createDirPath(gui_io.io(), "tmp");
    std.Io.Dir.cwd().deleteFile(gui_io.io(), path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    var g = try Gui.init(alloc, .{
        .app_args = &.{ "--log", path },
        .config_dir = "test/gui/fixtures/config_render_trace",
    });
    defer g.deinit();
    const base = g.windowCount();
    const opened = try g.remoteExpr("luaeval('(function() _G.trace_win = vim.api.nvim_open_win(vim.api.nvim_create_buf(false, true), true, {external=true, width=30, height=10}) return 1 end)()')");
    alloc.free(opened);
    try g.waitWindowCount(base + 1, 10_000);
    const closed = try g.remoteExpr("luaeval('(function() vim.api.nvim_win_close(_G.trace_win, true) return 1 end)()')");
    alloc.free(closed);
    try g.waitWindowCount(base, 10_000);
    var timer = gui_io.Timer.start();
    while (timer.read() < 5 * std.time.ns_per_s) {
        const data = try std.Io.Dir.cwd().readFileAlloc(gui_io.io(), path, alloc, .limited(64 * 1024 * 1024));
        defer alloc.free(data);
        const frontend = if (builtin.os.tag == .windows) "side=windows" else "side=macos";
        var lines = std.mem.splitScalar(u8, data, '\n');
        while (lines.next()) |line| {
            if (std.mem.indexOf(u8, line, "side=core") == null or
                std.mem.indexOf(u8, line, "event=destroy_release") == null) continue;
            const id = flushId(line) orelse return error.MissingCoreFlushId;
            var saw_stage = false;
            var saw_commit = false;
            var saw_release = false;
            var others = std.mem.splitScalar(u8, data, '\n');
            while (others.next()) |other| {
                if (flushId(other) != id or std.mem.indexOf(u8, other, frontend) == null) continue;
                if (std.mem.indexOf(u8, other, "event=destroy_stage") != null) saw_stage = true;
                if (std.mem.indexOf(u8, other, "event=end outcome=commit") != null) saw_commit = true;
                if (std.mem.indexOf(u8, other, "event=destroy_release") != null) saw_release = true;
            }
            if (saw_stage and saw_commit and saw_release) {
                std.debug.print("[gui] render_trace: matching core/frontend destruction commit flush={d}\n", .{id});
                return;
            }
        }
        gui_io.sleepNs(100 * std.time.ns_per_ms);
    }
    return error.MissingCorrelatedRenderTrace;
}
