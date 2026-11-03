// restart_chan_detach — after :restart the restored server must still exit
// when the GUI's channel closes without :qa.
//
// The embed channel is detach=false; the socket channel a restart reconnects
// to defaults to detach=true, so Neovim broadcasts the old value in the
// restart event's chan_config and the UI restores it with nvim_chan_set.
// Servers that send no chan_config (0.12.x) are skipped.

const std = @import("std");
const zc = @import("zonvie_core");
const Harness = @import("../harness.zig").Harness;

// Run via nvim_command, so inside :lua chan 0 is the internal channel, not
// ours; the UI's channel id comes from nvim_list_uis.
const ui_detach = "tostring(vim.api.nvim_get_chan_info(vim.api.nvim_list_uis()[1].chan).detach)";
const probe_pre = "lua vim.api.nvim_buf_set_lines(0,0,-1,false,{'pre '.." ++ ui_detach ++ "..(vim.api.nvim_chan_set and ' chanset' or ' nochanset')})";
const probe_post = "lua vim.api.nvim_buf_set_lines(0,0,-1,false,{'post '.." ++ ui_detach ++ "..' '..vim.fn.getpid()})";

pub fn run(alloc: std.mem.Allocator) !void {
    var h = try Harness.init(alloc, .{});
    var torn_down = false;
    defer if (!torn_down) h.deinit();

    try h.waitRowText(h.winGrid(), 0, "", h.opts.timeout_ms);
    try h.command(probe_pre);
    const pre = try waitRowPrefix(h, alloc, "pre ");
    defer alloc.free(pre);
    if (std.mem.endsWith(u8, pre, " nochanset")) {
        std.debug.print("[e2e] restart_chan_detach: skipped, server has no nvim_chan_set ({s})\n", .{pre});
        return error.SkipZigTest;
    }
    if (!std.mem.startsWith(u8, pre, "pre false ")) {
        std.debug.print("[e2e] restart_chan_detach: embed channel not detach=false: {s}\n", .{pre});
        return error.UnexpectedEmbedDetach;
    }

    // The probe modified the buffer; :restart quits with :qall, which a
    // modified buffer would refuse.
    try h.command("set nomodified");
    const flush_before = h.flush_seq.load(.seq_cst);
    try h.command("restart");
    try h.waitUntil(flush_before, struct {
        fn check(before: u64, hh: *Harness) bool {
            return hh.core.transport_kind == .socket and hh.flush_seq.load(.seq_cst) > before;
        }
    }.check, h.opts.timeout_ms);

    try h.command(probe_post);
    const post = try waitRowPrefix(h, alloc, "post ");
    defer alloc.free(post);
    // The restarted server is not the harness's child, so nothing else reaps
    // it: kill it on every exit path, including the failures below where a
    // detach=true channel keeps it alive. A no-op once it has exited.
    const pid_text = post[(std.mem.lastIndexOfScalar(u8, post, ' ') orelse return error.MalformedProbe) + 1 ..];
    const pid = try std.fmt.parseInt(std.posix.pid_t, pid_text, 10);
    defer killProcess(alloc, pid);
    if (!std.mem.startsWith(u8, post, "post false ")) {
        std.debug.print("[e2e] restart_chan_detach: detach not restored after :restart: {s}\n", .{post});
        return error.DetachNotRestored;
    }

    // Drop the channel the way a crashed GUI would: no :qa. A detach=false
    // channel closing is what makes the server exit.
    torn_down = true;
    h.deinit();
    const t0 = zc.clock.nowNs();
    while (try processAlive(alloc, pid)) {
        if (zc.clock.nowNs() - t0 > 5 * std.time.ns_per_s) {
            std.debug.print("[e2e] restart_chan_detach: restarted server pid={d} still alive after channel close\n", .{pid});
            return error.ServerOutlivedChannel;
        }
        std.Io.sleep(zc.clock.io(), .{ .nanoseconds = 50 * std.time.ns_per_ms }, .awake) catch {};
    }
}

fn killProcess(alloc: std.mem.Allocator, pid: std.posix.pid_t) void {
    var pid_buf: [16]u8 = undefined;
    const pid_str = std.fmt.bufPrint(&pid_buf, "{d}", .{pid}) catch return;
    const result = std.process.run(alloc, zc.clock.io(), .{ .argv = &.{ "kill", "-9", pid_str } }) catch return;
    alloc.free(result.stdout);
    alloc.free(result.stderr);
}

/// `kill -0 pid`: exit 0 while the process exists.
fn processAlive(alloc: std.mem.Allocator, pid: std.posix.pid_t) !bool {
    var pid_buf: [16]u8 = undefined;
    const pid_str = try std.fmt.bufPrint(&pid_buf, "{d}", .{pid});
    const result = try std.process.run(alloc, zc.clock.io(), .{ .argv = &.{ "kill", "-0", pid_str } });
    alloc.free(result.stdout);
    alloc.free(result.stderr);
    return switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };
}

/// Row 0 of the current window once it starts with `prefix`.
fn waitRowPrefix(h: *Harness, alloc: std.mem.Allocator, prefix: []const u8) ![]u8 {
    try h.waitUntil(prefix, struct {
        fn check(p: []const u8, hh: *Harness) bool {
            const text = hh.rowTextAlloc(hh.alloc, hh.winGrid(), 0) catch return false;
            defer hh.alloc.free(text);
            return std.mem.startsWith(u8, text, p);
        }
    }.check, h.opts.timeout_ms);
    const text = try h.rowTextAlloc(alloc, h.winGrid(), 0);
    return text;
}
