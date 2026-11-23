// gui_doc — the use cases of Neovim's `gui.txt`, from "Stop or detach the
// current UI" to the end, driven through the real core against a real nvim.
//
// One `run*` per use case, so a run reports each on its own line. Commands the
// server lacks (`:detach!`, `:connect`, `:restart` are 0.12+/0.13) skip.
//
// The frontend half of these (a real window surviving :restart, real pointer
// events, a real file drag) is test/gui/scenarios/macos/gui_doc_*.zig.

const std = @import("std");
const zc = @import("zonvie_core");
const harness = @import("../harness.zig");
const Harness = harness.Harness;

const wait_ms = 8000;

fn sleepMs(ms: u64) void {
    std.Io.sleep(zc.clock.io(), .{ .nanoseconds = ms * std.time.ns_per_ms }, .awake) catch {};
}

fn tmpAbsAlloc(alloc: std.mem.Allocator) ![:0]u8 {
    std.Io.Dir.cwd().createDirPath(zc.clock.io(), "tmp") catch {};
    return std.Io.Dir.cwd().realPathFileAlloc(zc.clock.io(), "tmp", alloc);
}

var unique_seq: u32 = 0;

/// An absolute path under tmp/ no other scenario or run uses.
fn tmpPathAlloc(alloc: std.mem.Allocator, tag: []const u8) ![]u8 {
    const tmp_abs = try tmpAbsAlloc(alloc);
    defer alloc.free(tmp_abs);
    unique_seq += 1;
    return std.fmt.allocPrint(alloc, "{s}/gd_{d}_{d}_{s}", .{ tmp_abs, std.c.getpid(), unique_seq, tag });
}

fn readFileTrimmedAlloc(alloc: std.mem.Allocator, path: []const u8) ![]u8 {
    const data = try std.Io.Dir.cwd().readFileAlloc(zc.clock.io(), path, alloc, .limited(1 << 16));
    defer alloc.free(data);
    return alloc.dupe(u8, std.mem.trim(u8, data, " \t\r\n"));
}

fn waitFileAlloc(alloc: std.mem.Allocator, path: []const u8, timeout_ms: u64) ![]u8 {
    const t0 = zc.clock.nowNs();
    while (true) {
        if (readFileTrimmedAlloc(alloc, path)) |text| return text else |_| {}
        if (@as(u64, @intCast(zc.clock.nowNs() - t0)) / std.time.ns_per_ms >= timeout_ms) return error.Timeout;
        sleepMs(20);
    }
}

/// `tostring(<lua_expr>)` as the attached server evaluates it. The server
/// writes the value to a file (renamed into place, so a read never sees half
/// of it): the answer does not depend on which grid a message lands in.
fn evalAlloc(h: *Harness, alloc: std.mem.Allocator, lua_expr: []const u8) ![]u8 {
    const path = try tmpPathAlloc(alloc, "eval.txt");
    defer alloc.free(path);
    const cmd = try std.fmt.allocPrint(
        alloc,
        "lua vim.fn.writefile({{tostring({s})}}, '{s}.part') vim.uv.fs_rename('{s}.part', '{s}')",
        .{ lua_expr, path, path, path },
    );
    defer alloc.free(cmd);
    try h.command(cmd);
    const text = waitFileAlloc(alloc, path, wait_ms) catch |e| {
        std.debug.print("[e2e] gui_doc: no answer for `{s}`\n", .{lua_expr});
        return e;
    };
    std.Io.Dir.cwd().deleteFile(zc.clock.io(), path) catch {};
    return text;
}

fn evalInt(h: *Harness, alloc: std.mem.Allocator, lua_expr: []const u8) !i64 {
    const text = try evalAlloc(h, alloc, lua_expr);
    defer alloc.free(text);
    return std.fmt.parseInt(i64, text, 10);
}

fn expectEval(h: *Harness, alloc: std.mem.Allocator, lua_expr: []const u8, expected: []const u8) !void {
    const text = try evalAlloc(h, alloc, lua_expr);
    defer alloc.free(text);
    if (!std.mem.eql(u8, text, expected)) {
        std.debug.print("[e2e] gui_doc: `{s}` is \"{s}\", expected \"{s}\"\n", .{ lua_expr, text, expected });
        return error.UnexpectedValue;
    }
}

/// Poll `lua_expr` until it is `expected`: for state a mouse or key event
/// changes, which has no flush of its own to wait on.
fn waitEval(h: *Harness, alloc: std.mem.Allocator, lua_expr: []const u8, expected: []const u8) !void {
    const t0 = zc.clock.nowNs();
    while (true) {
        const text = try evalAlloc(h, alloc, lua_expr);
        defer alloc.free(text);
        if (std.mem.eql(u8, text, expected)) return;
        if (@as(u64, @intCast(zc.clock.nowNs() - t0)) / std.time.ns_per_ms >= wait_ms) {
            std.debug.print("[e2e] gui_doc: `{s}` stayed \"{s}\", expected \"{s}\"\n", .{ lua_expr, text, expected });
            return error.Timeout;
        }
        sleepMs(30);
    }
}

fn killProcess(alloc: std.mem.Allocator, pid: i64) void {
    var pid_buf: [24]u8 = undefined;
    const pid_str = std.fmt.bufPrint(&pid_buf, "{d}", .{pid}) catch return;
    const result = std.process.run(alloc, zc.clock.io(), .{ .argv = &.{ "kill", "-9", pid_str } }) catch return;
    alloc.free(result.stdout);
    alloc.free(result.stderr);
}

/// `kill -0 pid`: exit 0 while the process exists. Only for processes this
/// test did not spawn itself; an unreaped child of ours would read as alive.
fn processAlive(alloc: std.mem.Allocator, pid: i64) !bool {
    var pid_buf: [24]u8 = undefined;
    const pid_str = try std.fmt.bufPrint(&pid_buf, "{d}", .{pid});
    const result = try std.process.run(alloc, zc.clock.io(), .{ .argv = &.{ "kill", "-0", pid_str } });
    alloc.free(result.stdout);
    alloc.free(result.stderr);
    return switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };
}

fn waitProcessGone(alloc: std.mem.Allocator, pid: i64, timeout_ms: u64) !bool {
    const t0 = zc.clock.nowNs();
    while (try processAlive(alloc, pid)) {
        if (@as(u64, @intCast(zc.clock.nowNs() - t0)) / std.time.ns_per_ms >= timeout_ms) return false;
        sleepMs(50);
    }
    return true;
}

/// A headless server of our own, for the UI to attach, detach and connect to.
const Server = struct {
    alloc: std.mem.Allocator,
    nvim: []u8,
    child: std.process.Child,
    /// Empty when the server picked its own address (so `serverlist()` of a
    /// peer finds it).
    addr: []u8,

    fn start(alloc: std.mem.Allocator, listen: bool, startup_cmd: []const u8) !Server {
        const nvim = try harness.resolveNvim(alloc);
        errdefer alloc.free(nvim);
        const addr = if (listen) try tmpPathAlloc(alloc, "srv.sock") else try alloc.dupe(u8, "");
        errdefer alloc.free(addr);
        const child = if (listen)
            try std.process.spawn(zc.clock.io(), .{
                .argv = &.{ nvim, "--clean", "-n", "--headless", "--listen", addr, "-c", startup_cmd },
                .stdin = .ignore,
                .stdout = .ignore,
                .stderr = .ignore,
            })
        else
            try std.process.spawn(zc.clock.io(), .{
                .argv = &.{ nvim, "--clean", "-n", "--headless", "-c", startup_cmd },
                .stdin = .ignore,
                .stdout = .ignore,
                .stderr = .ignore,
            });
        var s: Server = .{ .alloc = alloc, .nvim = nvim, .child = child, .addr = addr };
        errdefer s.child.kill(zc.clock.io());
        if (listen) {
            const t0 = zc.clock.nowNs();
            while (true) {
                if (s.exprAlloc("1")) |out| {
                    alloc.free(out);
                    break;
                } else |_| {}
                if (@as(u64, @intCast(zc.clock.nowNs() - t0)) / std.time.ns_per_ms >= wait_ms) return error.Timeout;
                sleepMs(50);
            }
        }
        return s;
    }

    fn pid(s: *const Server) i64 {
        return @intCast(s.child.id.?);
    }

    /// `--remote-expr`: also this server's liveness probe.
    fn exprAlloc(s: *const Server, expr: []const u8) ![]u8 {
        const result = try std.process.run(s.alloc, zc.clock.io(), .{
            .argv = &.{ s.nvim, "--server", s.addr, "--remote-expr", expr },
        });
        s.alloc.free(result.stderr);
        errdefer s.alloc.free(result.stdout);
        switch (result.term) {
            .exited => |code| if (code != 0) return error.RemoteExprFailed,
            else => return error.RemoteExprFailed,
        }
        return result.stdout;
    }

    fn expectExpr(s: *const Server, expr: []const u8, expected: []const u8) !void {
        const out = try s.exprAlloc(expr);
        defer s.alloc.free(out);
        const text = std.mem.trim(u8, out, " \t\r\n");
        if (!std.mem.eql(u8, text, expected)) {
            std.debug.print("[e2e] gui_doc: server `{s}` is \"{s}\", expected \"{s}\"\n", .{ expr, text, expected });
            return error.UnexpectedValue;
        }
    }

    fn stop(s: *Server) void {
        s.child.kill(zc.clock.io());
        if (s.addr.len != 0) std.Io.Dir.cwd().deleteFile(zc.clock.io(), s.addr) catch {};
        s.alloc.free(s.addr);
        s.alloc.free(s.nvim);
    }
};

fn requireCommand(h: *Harness, alloc: std.mem.Allocator, name: []const u8) !void {
    const expr = try std.fmt.allocPrint(alloc, "vim.fn.exists(':{s}')", .{name});
    defer alloc.free(expr);
    if (try evalInt(h, alloc, expr) != 2) {
        std.debug.print("[e2e] gui_doc: skipped, server has no :{s}\n", .{name});
        return error.SkipZigTest;
    }
}

/// Run a `:restart` variant and wait for the UI to be attached to the new
/// server. Valid once per harness: the wait keys on the first move to a socket.
fn restartAndWait(h: *Harness, cmd: []const u8) !void {
    const flush_before = h.flush_seq.load(.seq_cst);
    try h.command(cmd);
    try h.waitUntil(flush_before, struct {
        fn check(before: u64, hh: *Harness) bool {
            return hh.core.transport_kind == .socket and hh.flush_seq.load(.seq_cst) > before;
        }
    }.check, wait_ms);
}

/// The UI is on a socket and showing the buffer of the server it moved to.
fn waitConnected(h: *Harness) !void {
    h.waitUntil({}, struct {
        fn check(_: void, hh: *Harness) bool {
            return hh.core.transport_kind == .socket and hh.screenContains("server-b");
        }
    }.check, wait_ms) catch |e| {
        std.debug.print("[e2e] gui_doc: the UI did not reach the other server (exited={})\n", .{h.exited.load(.seq_cst)});
        h.dumpScreen();
        return e;
    };
}

fn waitScreen(h: *Harness, needle: []const u8) !void {
    h.waitUntil(needle, struct {
        fn check(n: []const u8, hh: *Harness) bool {
            return hh.screenContains(n);
        }
    }.check, wait_ms) catch |e| {
        std.debug.print("[e2e] gui_doc: \"{s}\" never appeared on any grid\n", .{needle});
        h.dumpScreen();
        return e;
    };
}

// ── :detach ────────────────────────────────────────────────────────────

/// `:detach` from the embedded server zonvie spawned: the UI ends, the server
/// keeps running, and a UI can attach to it again at v:servername.
pub fn runDetachEmbedded(alloc: std.mem.Allocator) !void {
    var h = try Harness.init(alloc, .{});
    var live = true;
    defer if (live) h.deinit();
    try requireCommand(h, alloc, "detach");

    try h.input("idetach-marker<Esc>");
    try h.waitRowText(h.winGrid(), 0, "detach-marker", wait_ms);
    const pid = try evalInt(h, alloc, "vim.fn.getpid()");
    defer killProcess(alloc, pid);
    const addr = try evalAlloc(h, alloc, "vim.v.servername");
    defer alloc.free(addr);

    try h.command("detach");
    h.waitExit(wait_ms) catch {
        std.debug.print("[e2e] gui_doc: the UI never saw its session end after :detach\n", .{});
        return error.UiHangsAfterDetach;
    };
    if (!try processAlive(alloc, pid)) return error.ServerDiedOnDetach;

    // What quitting the GUI does next must not take the server with it.
    live = false;
    h.deinit();
    sleepMs(500);
    if (!try processAlive(alloc, pid)) return error.ServerDiedOnUiTeardown;

    // Attached again, and its input reaches the server it left. What the
    // reattached UI shows is runReattachShowsWindowContent's.
    var h2 = try Harness.init(alloc, .{ .connect_addr = addr });
    defer h2.deinit();
    try expectEval(h2, alloc, "#vim.api.nvim_list_uis()", "1");
    try expectEval(h2, alloc, "vim.fn.getpid()", blk: {
        var buf: [24]u8 = undefined;
        break :blk try std.fmt.bufPrint(&buf, "{d}", .{pid});
    });
    try h2.input("oafter-reattach<Esc>");
    try waitEval(h2, alloc, "vim.fn.getline(2)", "after-reattach");
}

/// `:detach` from a `--remote-ui` session, then reattach to the same server.
pub fn runDetachRemoteThenReattach(alloc: std.mem.Allocator) !void {
    var s = try Server.start(alloc, true, "call setline(1, 'server-marker')");
    defer s.stop();
    {
        var h = try Harness.init(alloc, .{ .connect_addr = s.addr });
        defer h.deinit();
        try requireCommand(h, alloc, "detach");
        try waitScreen(h, "server-marker");
        try h.input("ccwritten-by-ui<Esc>");
        try waitScreen(h, "written-by-ui");

        try h.command("detach");
        h.waitExit(wait_ms) catch return error.UiHangsAfterDetach;
    }
    try s.expectExpr("getline(1)", "written-by-ui");
    try s.expectExpr("len(nvim_list_uis())", "0");

    // Attached again, and its input reaches the server. What the reattached
    // UI shows is runReattachShowsWindowContent's.
    var h2 = try Harness.init(alloc, .{ .connect_addr = s.addr });
    defer h2.deinit();
    try s.expectExpr("len(nvim_list_uis())", "1");
    try h2.input("oafter-reattach<Esc>");
    try waitEval(h2, alloc, "vim.fn.getline(2)", "after-reattach");
}

/// A UI that attaches to a server another multigrid UI has left sees the
/// windows as that UI did.
///
/// NEOVIM BUG, fixed by neovim/neovim#42667 ("resend window-grids on
/// multigrid UI-attach"): a server without it keeps the window grids it
/// allocated for the previous multigrid UI and sends the new one only the
/// cells that differ from them. At the same size that is `grid_resize` with
/// no `win_pos` and no `grid_line`, so the window stays empty and `:mode`
/// does not bring it back; at another size only the cells the resize changed
/// arrive. A raw msgpack client with no zonvie code in it gets the same
/// events. Skips on a server that still does that (0.12.2, and a 0.13-dev
/// older than the fix), and passes on one that has it.
pub fn runReattachShowsWindowContent(alloc: std.mem.Allocator) !void {
    var s = try Server.start(alloc, true, "call setline(1, 'server-marker')");
    defer s.stop();
    {
        var h = try Harness.init(alloc, .{ .connect_addr = s.addr });
        defer h.deinit();
        try requireCommand(h, alloc, "detach");
        try waitScreen(h, "server-marker");
        try h.command("detach");
        h.waitExit(wait_ms) catch return error.UiHangsAfterDetach;
    }

    var same = try Harness.init(alloc, .{ .connect_addr = s.addr });
    defer same.deinit();
    try s.expectExpr("len(nvim_list_uis())", "1");
    same.waitUntil({}, struct {
        fn check(_: void, hh: *Harness) bool {
            return hh.screenContains("server-marker");
        }
    }.check, 3000) catch {
        std.debug.print("[e2e] gui_doc: skipped, server lacks neovim#42667: no window content on a same-size multigrid reattach\n", .{});
        return error.SkipZigTest;
    };
}

/// `:%detach` detaches every UI but the one that ran it.
pub fn runDetachOthers(alloc: std.mem.Allocator) !void {
    var s = try Server.start(alloc, true, "call setline(1, 'shared')");
    defer s.stop();
    var a = try Harness.init(alloc, .{ .connect_addr = s.addr });
    defer a.deinit();
    try requireCommand(a, alloc, "detach");
    var b = try Harness.init(alloc, .{ .connect_addr = s.addr });
    defer b.deinit();
    // Not asserted here: what either UI shows. A second UI attaching at the
    // size of the first gets no window content from the server, which
    // runDetachRemoteThenReattach pins on its own.
    try s.expectExpr("len(nvim_list_uis())", "2");

    // "Current" is the UI that last sent input or attached, and `b` attached
    // last. Typing in `a` is what makes it the one the command is run from.
    try a.input("<Esc>");
    try a.command("%detach");
    b.waitExit(wait_ms) catch return error.OtherUiNotDetached;
    try s.expectExpr("len(nvim_list_uis())", "1");

    try a.input("ccstill-attached<Esc>");
    try waitScreen(a, "still-attached");
}

const ui_detach = "vim.api.nvim_get_chan_info(vim.api.nvim_list_uis()[1].chan).detach";

/// `:detach!` keeps the UI attached and marks its channel detachable. That
/// the server then outlives a UI that dies is asserted where a UI can die:
/// on the socket session below, and by killing the real app (the gui tier).
/// Here Core.stop() is the only way out, and it ends its own child on purpose.
pub fn runDetachBang(alloc: std.mem.Allocator) !void {
    var h = try Harness.init(alloc, .{});
    defer h.deinit();
    if (try evalInt(h, alloc, "vim.api.nvim_chan_set and 1 or 0") != 1) {
        std.debug.print("[e2e] gui_doc: skipped, server has no :detach!\n", .{});
        return error.SkipZigTest;
    }
    try expectEval(h, alloc, ui_detach, "false");

    try h.command("silent detach!");
    try expectEval(h, alloc, ui_detach, "true");
    try h.input("istill-here<Esc>");
    try h.waitRowText(h.winGrid(), 0, "still-here", wait_ms);
}

/// `:detach!` is preserved across `:restart`.
pub fn runDetachBangSurvivesRestart(alloc: std.mem.Allocator) !void {
    var h = try Harness.init(alloc, .{});
    var live = true;
    defer if (live) h.deinit();
    if (try evalInt(h, alloc, "vim.api.nvim_chan_set and 1 or 0") != 1) {
        std.debug.print("[e2e] gui_doc: skipped, server has no :detach!\n", .{});
        return error.SkipZigTest;
    }
    try h.command("silent detach!");
    try expectEval(h, alloc, ui_detach, "true");

    try restartAndWait(h, "restart");
    const pid = try evalInt(h, alloc, "vim.fn.getpid()");
    defer killProcess(alloc, pid);
    try expectEval(h, alloc, ui_detach, "true");

    live = false;
    h.deinit();
    sleepMs(1500);
    if (!try processAlive(alloc, pid)) return error.ServerDiedDespiteDetachBang;
}

// ── :restart ───────────────────────────────────────────────────────────

/// `:restart` saves and restores the session, starts a new server and
/// attaches the UI to it; v:startreason and v:exitreason say why.
pub fn runRestartRestoresSession(alloc: std.mem.Allocator) !void {
    var h = try Harness.init(alloc, .{});
    defer h.deinit();
    try requireCommand(h, alloc, "restart");

    const file = try tmpPathAlloc(alloc, "restart.txt");
    defer alloc.free(file);
    defer std.Io.Dir.cwd().deleteFile(zc.clock.io(), file) catch {};
    const exit_file = try tmpPathAlloc(alloc, "exitreason.txt");
    defer alloc.free(exit_file);
    defer std.Io.Dir.cwd().deleteFile(zc.clock.io(), exit_file) catch {};

    const edit = try std.fmt.allocPrint(alloc, "edit {s}", .{file});
    defer alloc.free(edit);
    try h.command(edit);
    try h.input("isession-line<Esc>");
    try h.waitRowText(h.winGrid(), 0, "session-line", wait_ms);
    try h.command("write");
    try h.command("vsplit");
    try h.waitWindowCount(2, wait_ms);
    const au = try std.fmt.allocPrint(alloc, "autocmd VimLeavePre * call writefile([v:exitreason], '{s}')", .{exit_file});
    defer alloc.free(au);
    try h.command(au);
    const old_pid = try evalInt(h, alloc, "vim.fn.getpid()");
    try expectEval(h, alloc, "vim.v.startreason", "normal");

    try restartAndWait(h, "restart");
    const new_pid = try evalInt(h, alloc, "vim.fn.getpid()");
    defer killProcess(alloc, new_pid);
    if (new_pid == old_pid) return error.ServerNotReplaced;
    if (!try waitProcessGone(alloc, old_pid, wait_ms)) return error.OldServerStillAlive;

    try expectEval(h, alloc, "vim.v.startreason", "restart");
    try expectEval(h, alloc, "vim.fn.expand('%:p')", file);
    try expectEval(h, alloc, "vim.fn.winnr('$')", "2");
    try h.waitRowText(h.winGrid(), 0, "session-line", wait_ms);
    const reason = try waitFileAlloc(alloc, exit_file, wait_ms);
    defer alloc.free(reason);
    try std.testing.expectEqualStrings("restart", reason);

    // The reattached UI still takes input.
    try h.input("oafter-restart<Esc>");
    try h.waitRowText(h.winGrid(), 1, "after-restart", wait_ms);
    try h.command("write");
}

/// `:restart!` starts a new server without restoring the session.
pub fn runRestartBangDropsSession(alloc: std.mem.Allocator) !void {
    var h = try Harness.init(alloc, .{});
    defer h.deinit();
    try requireCommand(h, alloc, "restart");

    const file = try tmpPathAlloc(alloc, "restart_bang.txt");
    defer alloc.free(file);
    defer std.Io.Dir.cwd().deleteFile(zc.clock.io(), file) catch {};
    const edit = try std.fmt.allocPrint(alloc, "edit {s}", .{file});
    defer alloc.free(edit);
    try h.command(edit);
    try h.command("write");
    try h.command("vsplit");
    try h.waitWindowCount(2, wait_ms);
    const old_pid = try evalInt(h, alloc, "vim.fn.getpid()");

    try restartAndWait(h, "restart!");
    const new_pid = try evalInt(h, alloc, "vim.fn.getpid()");
    defer killProcess(alloc, new_pid);
    if (new_pid == old_pid) return error.ServerNotReplaced;
    try expectEval(h, alloc, "vim.v.startreason", "restart!");
    try expectEval(h, alloc, "vim.fn.expand('%:p')", "");
    try expectEval(h, alloc, "vim.fn.winnr('$')", "1");
}

/// A modified buffer stops the default `:qall`; `:restart +qall!` goes through.
pub fn runRestartPlusCmd(alloc: std.mem.Allocator) !void {
    var h = try Harness.init(alloc, .{});
    defer h.deinit();
    try requireCommand(h, alloc, "restart");

    try h.input("iunsaved<Esc>");
    try h.waitRowText(h.winGrid(), 0, "unsaved", wait_ms);
    const old_pid = try evalInt(h, alloc, "vim.fn.getpid()");

    try h.command("restart");
    sleepMs(1000);
    // Still the same server, and the UI is still attached to it.
    if (try evalInt(h, alloc, "vim.fn.getpid()") != old_pid) return error.RestartIgnoredModifiedBuffer;
    try h.input("o-still-attached<Esc>");
    try h.waitRowText(h.winGrid(), 1, "-still-attached", wait_ms);

    try restartAndWait(h, "restart +qall!");
    const new_pid = try evalInt(h, alloc, "vim.fn.getpid()");
    defer killProcess(alloc, new_pid);
    if (new_pid == old_pid) return error.ServerNotReplaced;
}

/// `:restart {command}` runs the command on the new server once UIs attached.
pub fn runRestartThenCommand(alloc: std.mem.Allocator) !void {
    var h = try Harness.init(alloc, .{});
    defer h.deinit();
    try requireCommand(h, alloc, "restart");
    const old_pid = try evalInt(h, alloc, "vim.fn.getpid()");

    try restartAndWait(h, "restart let g:gd_after_restart = len(nvim_list_uis())");
    const new_pid = try evalInt(h, alloc, "vim.fn.getpid()");
    defer killProcess(alloc, new_pid);
    if (new_pid == old_pid) return error.ServerNotReplaced;
    // The command saw the UI already attached.
    try waitEval(h, alloc, "vim.g.gd_after_restart", "1");
}

// ── :connect ───────────────────────────────────────────────────────────

/// `:connect {address}`: the UI moves to the other server, and the one it
/// left stops, having no other UI and nothing unsaved.
pub fn runConnectAddress(alloc: std.mem.Allocator) !void {
    var s = try Server.start(alloc, true, "call setline(1, 'server-b')");
    defer s.stop();
    var h = try Harness.init(alloc, .{});
    defer h.deinit();
    try requireCommand(h, alloc, "connect");
    try h.input("iserver-a<Esc>");
    try h.waitRowText(h.winGrid(), 0, "server-a", wait_ms);
    try h.command("set nomodified");
    const old_pid = try evalInt(h, alloc, "vim.fn.getpid()");
    defer killProcess(alloc, old_pid);

    const cmd = try std.fmt.allocPrint(alloc, "connect {s}", .{s.addr});
    defer alloc.free(cmd);
    try h.command(cmd);
    try waitConnected(h);
    try expectEval(h, alloc, "vim.fn.getpid()", blk: {
        var buf: [24]u8 = undefined;
        break :blk try std.fmt.bufPrint(&buf, "{d}", .{s.pid()});
    });
    try s.expectExpr("len(nvim_list_uis())", "1");
    try h.input("o-typed-on-b<Esc>");
    try s.expectExpr("getline(2)", "-typed-on-b");

    if (!try waitProcessGone(alloc, old_pid, wait_ms)) return error.OldServerStillAlive;
}

/// `:connect {address}` from the last UI of a server with unsaved changes is
/// refused (ex_connect: check_changed_any), and the UI stays where it was.
pub fn runConnectRefusedWithUnsavedChanges(alloc: std.mem.Allocator) !void {
    var s = try Server.start(alloc, true, "call setline(1, 'server-b')");
    defer s.stop();
    var h = try Harness.init(alloc, .{});
    defer h.deinit();
    try requireCommand(h, alloc, "connect");
    try h.input("iunsaved-on-a<Esc>");
    try h.waitRowText(h.winGrid(), 0, "unsaved-on-a", wait_ms);
    const old_pid = try evalInt(h, alloc, "vim.fn.getpid()");
    defer killProcess(alloc, old_pid);

    const cmd = try std.fmt.allocPrint(alloc, "connect {s}", .{s.addr});
    defer alloc.free(cmd);
    try h.command(cmd);
    sleepMs(1500);
    if (h.core.transport_kind != .pipes) return error.UiLeftModifiedServer;
    try s.expectExpr("len(nvim_list_uis())", "0");
    try expectEval(h, alloc, "vim.fn.getpid()", blk: {
        var buf: [24]u8 = undefined;
        break :blk try std.fmt.bufPrint(&buf, "{d}", .{old_pid});
    });
    try h.input("o-still-on-a<Esc>");
    try h.waitRowText(h.winGrid(), 1, "-still-on-a", wait_ms);
}

/// `:connect` with no argument offers the running servers in a menu.
pub fn runConnectMenu(alloc: std.mem.Allocator) !void {
    // No --listen: only a server at its default address is in serverlist().
    var s = try Server.start(alloc, false, "call setline(1, 'server-b')");
    defer s.stop();
    var h = try Harness.init(alloc, .{ .cols = 200, .rows = 40 });
    defer h.deinit();
    try requireCommand(h, alloc, "connect");
    const old_pid = try evalInt(h, alloc, "vim.fn.getpid()");
    defer killProcess(alloc, old_pid);

    var needle_buf: [32]u8 = undefined;
    const needle = try std.fmt.bufPrint(&needle_buf, "nvim.{d}.", .{s.pid()});
    // The peer has to be listening before the menu is built.
    const peers = "#vim.tbl_filter(function(a) return a:find('" ++ "{s}" ++ "', 1, true) end, vim.fn.serverlist({{ peer = true }}))";
    const peers_expr = try std.fmt.allocPrint(alloc, peers, .{needle});
    defer alloc.free(peers_expr);
    try waitEval(h, alloc, peers_expr, "1");

    try h.input(":connect<CR>");
    try waitScreen(h, needle);
    const line = (try h.screenLineAlloc(alloc, needle)) orelse return error.MenuEntryVanished;
    defer alloc.free(line);
    // inputlist() numbers its entries: "3: /path/to/nvim.<pid>.0".
    const trimmed = std.mem.trimStart(u8, line, " ");
    const colon = std.mem.indexOfScalar(u8, trimmed, ':') orelse {
        std.debug.print("[e2e] gui_doc: unnumbered menu entry: \"{s}\"\n", .{line});
        return error.UnexpectedMenuFormat;
    };
    const choice = try std.fmt.allocPrint(alloc, "{s}<CR>", .{trimmed[0..colon]});
    defer alloc.free(choice);
    try h.input(choice);

    try waitConnected(h);
}

// ── GUI commands ───────────────────────────────────────────────────────

/// `:winpos` and `getwinpos()`: Neovim has no UI event for either, so the
/// answer is the server's own and no GUI can supply one. Pinned so a server
/// that starts asking the UI fails here.
pub fn runWinposCommands(alloc: std.mem.Allocator) !void {
    var h = try Harness.init(alloc, .{});
    defer h.deinit();
    const run = "(function(c) local ok, r = pcall(vim.api.nvim_exec2, c, { output = true }) return ok and ('ok:' .. r.output) or r end)";
    const winpos = try evalAlloc(h, alloc, run ++ "('winpos')");
    defer alloc.free(winpos);
    const winpos_set = try evalAlloc(h, alloc, run ++ "('winpos 10 20')");
    defer alloc.free(winpos_set);
    const getwinpos = try evalAlloc(h, alloc, "vim.inspect(vim.fn.getwinpos())");
    defer alloc.free(getwinpos);
    try std.testing.expect(std.mem.indexOf(u8, winpos, "E319") != null);
    try std.testing.expect(std.mem.indexOf(u8, winpos_set, "E319") != null);
    try std.testing.expectEqualStrings("{ -1, -1 }", getwinpos);
}

/// `:set lines= columns=` (what the doc gives in place of `:winsize`) resizes
/// the UI's grid.
pub fn runLinesColumns(alloc: std.mem.Allocator) !void {
    var h = try Harness.init(alloc, .{});
    defer h.deinit();
    try h.command("set lines=11 columns=22");
    try h.waitUntil({}, struct {
        fn check(_: void, hh: *Harness) bool {
            hh.core.grid_mu.lockUncancelable(zc.clock.io());
            defer hh.core.grid_mu.unlock(zc.clock.io());
            return hh.core.grid.rows == 11 and hh.core.grid.cols == 22;
        }
    }.check, wait_ms);
}

// ── Mouse ──────────────────────────────────────────────────────────────

/// One pointer event, then a pause a real pointer would also leave.
/// nvim_input_mouse is documented as real-time input, not a script: of
/// several calls handled in one batch only the last position survives, so a
/// press and its first drag sent back to back can lose where the press was.
fn mouse(h: *Harness, button: []const u8, action: []const u8, modifier: []const u8, grid: i64, row: i32, col: i32) void {
    h.core.sendMouseInput(button, action, modifier, grid, row, col);
    sleepMs(25);
}

fn click(h: *Harness, button: []const u8, modifier: []const u8, grid: i64, row: i32, col: i32) void {
    mouse(h,button, "press", modifier, grid, row, col);
    mouse(h,button, "release", modifier, grid, row, col);
}

fn mouseBuffer(h: *Harness) !i64 {
    try h.command("set mouse=a");
    try h.command("call setline(1, ['alpha beta gamma', 'delta epsilon', 'zeta'])");
    const g = h.winGrid();
    try h.waitRowText(g, 2, "zeta", wait_ms);
    return g;
}

/// A click places the cursor; a drag selects.
pub fn runMouseClickAndDrag(alloc: std.mem.Allocator) !void {
    var h = try Harness.init(alloc, .{});
    defer h.deinit();
    const g = try mouseBuffer(h);

    click(h, "left", "", g, 1, 6);
    try h.waitCursor(1, 6, wait_ms);

    mouse(h,"left", "press", "", g, 0, 6);
    mouse(h,"left", "drag", "", g, 0, 8);
    mouse(h,"left", "drag", "", g, 0, 9);
    mouse(h,"left", "release", "", g, 0, 9);
    try waitEval(h, alloc, "vim.fn.mode()", "v");
    try h.input("y");
    try waitEval(h, alloc, "vim.fn.getreg('\"')", "beta");
}

/// Double, triple and quadruple clicks select a word, a line and a block.
pub fn runMouseMultiClick(alloc: std.mem.Allocator) !void {
    var h = try Harness.init(alloc, .{});
    defer h.deinit();
    const g = try mouseBuffer(h);

    click(h, "left", "", g, 0, 7);
    click(h, "left", "", g, 0, 7);
    try waitEval(h, alloc, "vim.fn.mode()", "v");
    try h.input("y");
    try waitEval(h, alloc, "vim.fn.getreg('\"')", "beta");

    // Past 'mousetime', so the next press starts a new count.
    sleepMs(700);
    click(h, "left", "", g, 1, 2);
    click(h, "left", "", g, 1, 2);
    click(h, "left", "", g, 1, 2);
    try waitEval(h, alloc, "vim.fn.mode()", "V");
    try h.input("<Esc>");

    sleepMs(700);
    click(h, "left", "", g, 1, 2);
    click(h, "left", "", g, 1, 2);
    click(h, "left", "", g, 1, 2);
    click(h, "left", "", g, 1, 2);
    try waitEval(h, alloc, "vim.fn.mode():byte()", "22");
    try h.input("<Esc>");
}

/// The mouse keycodes the doc tabulates reach mappings: the X buttons, the
/// middle button, a release, a double click, and a modifier.
pub fn runMouseKeycodeMappings(alloc: std.mem.Allocator) !void {
    var h = try Harness.init(alloc, .{});
    defer h.deinit();
    const g = try mouseBuffer(h);
    try h.command("let g:gd_seen = []");
    inline for (.{
        "X1Mouse",     "X1Release", "X2Mouse",       "X2Drag",       "MiddleMouse",
        "MiddleRelease", "RightDrag", "2-LeftMouse", "S-LeftMouse", "C-RightMouse",
    }) |key| {
        try h.command("noremap <" ++ key ++ "> <Cmd>call add(g:gd_seen, '" ++ key ++ "')<CR>");
    }

    click(h, "x1", "", g, 0, 0);
    mouse(h,"x2", "press", "", g, 0, 0);
    mouse(h,"x2", "drag", "", g, 0, 3);
    mouse(h,"x2", "release", "", g, 0, 3);
    click(h, "middle", "", g, 0, 0);
    try h.command("set mousemodel=extend");
    mouse(h,"right", "press", "", g, 1, 0);
    mouse(h,"right", "drag", "", g, 1, 3);
    mouse(h,"right", "release", "", g, 1, 3);
    try h.input("<Esc>");
    sleepMs(700);
    click(h, "left", "", g, 2, 0);
    click(h, "left", "", g, 2, 0);
    sleepMs(700);
    click(h, "left", "S", g, 0, 0);
    click(h, "right", "C", g, 0, 0);

    try waitEval(
        h,
        alloc,
        "table.concat(vim.g.gd_seen, ' ')",
        "X1Mouse X1Release X2Mouse X2Drag MiddleMouse MiddleRelease RightDrag 2-LeftMouse S-LeftMouse C-RightMouse",
    );
}

/// The doc's own examples: the X buttons as jump keys, a release that yanks,
/// a middle click that pastes the clipboard where it was clicked.
pub fn runMouseDocExamples(alloc: std.mem.Allocator) !void {
    var h = try Harness.init(alloc, .{});
    defer h.deinit();
    const g = try mouseBuffer(h);

    // :map <X1Mouse> <C-O> / :map <X2Mouse> <C-I>
    try h.command("map <X1Mouse> <C-O>");
    try h.command("map <X2Mouse> <C-I>");
    try h.input("gg");
    try h.input("G");
    try h.waitCursor(2, 0, wait_ms);
    click(h, "x1", "", g, 0, 0);
    try h.waitCursor(0, 0, wait_ms);
    click(h, "x2", "", g, 0, 0);
    try h.waitCursor(2, 0, wait_ms);

    // :noremap <LeftRelease> <LeftRelease>y
    try h.command("noremap <LeftRelease> <LeftRelease>y");
    mouse(h,"left", "press", "", g, 1, 0);
    mouse(h,"left", "drag", "", g, 1, 4);
    mouse(h,"left", "release", "", g, 1, 4);
    try waitEval(h, alloc, "vim.fn.getreg('\"')", "delta");
    try h.command("unmap <LeftRelease>");

    // :noremap <MiddleMouse> <LeftMouse><MiddleMouse>
    try h.setClipboard("PASTED");
    try h.command("noremap <MiddleMouse> <LeftMouse><MiddleMouse>");
    click(h, "middle", "", g, 2, 0);
    try h.waitRowText(g, 2, "PASTEDzeta", wait_ms);

    // Swapped left and right buttons, the first line of the doc's block.
    try h.command("set mousemodel=extend");
    try h.command("noremap <RightMouse> <LeftMouse>");
    click(h, "right", "", g, 0, 6);
    try h.waitCursor(0, 6, wait_ms);
}

// ── Menus ──────────────────────────────────────────────────────────────

/// `:amenu` defines, `:emenu` executes, `:tmenu` and `:unmenu` are accepted,
/// and menu_get() is what a UI would build a menu bar from.
pub fn runMenuCommands(alloc: std.mem.Allocator) !void {
    var h = try Harness.init(alloc, .{});
    defer h.deinit();
    try h.command("amenu 10.340 &File.&Save<Tab>:w <Cmd>let g:gd_menu = 'hit'<CR>");
    try h.command("tmenu File.Save Write the file");
    try h.command("amenu File.-SEP1- <Nop>");
    try h.command("emenu File.Save");
    try waitEval(h, alloc, "vim.g.gd_menu", "hit");
    try expectEval(h, alloc, "vim.fn.menu_get('File')[1].submenus[1].name", "Save");
    try expectEval(h, alloc, "vim.fn.menu_get('File')[1].submenus[1].actext", ":w");
    try h.command("aunmenu File.Save");
    try h.command("tunmenu File.Save");
    try expectEval(h, alloc, "#vim.fn.menu_get('File')[1].submenus", "1");
}

/// The default PopUp menu opens on a right click, and choosing an entry with
/// the mouse runs it.
pub fn runPopupMenuByRightClick(alloc: std.mem.Allocator) !void {
    var h = try Harness.init(alloc, .{});
    defer h.deinit();
    const g = try mouseBuffer(h);
    try expectEval(h, alloc, "vim.o.mousemodel", "popup_setpos");

    click(h, "right", "", g, 1, 6);
    try waitScreen(h, "Select All");
    // popup_setpos: the click also moved the cursor.
    try h.waitCursor(1, 6, wait_ms);

    const menu = try menuGridOf(h, alloc, "Select All");
    click(h, "left", "", menu.grid, menu.row, 2);
    try waitEval(h, alloc, "vim.fn.mode()", "V");
    try h.input("y");
    try waitEval(h, alloc, "#vim.fn.getreg('\"')", "36");
}

/// `:popup {name}` opens a user menu at the cursor.
pub fn runPopupCommand(alloc: std.mem.Allocator) !void {
    var h = try Harness.init(alloc, .{});
    defer h.deinit();
    _ = try mouseBuffer(h);
    try h.command("amenu ]GdHidden.First\\ Entry <Cmd>let g:gd_popup = 'first'<CR>");
    try h.command("amenu ]GdHidden.Second\\ Entry <Cmd>let g:gd_popup = 'second'<CR>");
    try h.input(":popup ]GdHidden<CR>");
    try waitScreen(h, "Second Entry");
    try h.input("<Down><Down><CR>");
    try waitEval(h, alloc, "vim.g.gd_popup", "second");
}

/// The grid and row showing `needle`, for clicking a popup menu entry.
fn menuGridOf(h: *Harness, alloc: std.mem.Allocator, needle: []const u8) !struct { grid: i64, row: i32 } {
    const ids = try h.positionedGridsAlloc(alloc);
    defer alloc.free(ids);
    for (ids) |id| {
        const size = h.subGridSize(id) orelse continue;
        var row: u32 = 0;
        while (row < size.rows) : (row += 1) {
            const text = try h.rowTextAlloc(alloc, id, row);
            defer alloc.free(text);
            if (std.mem.indexOf(u8, text, needle) != null) return .{ .grid = id, .row = @intCast(row) };
        }
    }
    return error.MenuGridNotFound;
}

// ── Drag and drop ──────────────────────────────────────────────────────

fn touch(path: []const u8, text: []const u8) !void {
    try std.Io.Dir.cwd().writeFile(zc.clock.io(), .{ .sub_path = path, .data = text });
}

/// Dropped files open as with `:drop`: the first becomes current, the rest
/// join the argument list, names needing escapes included.
pub fn runDropFiles(alloc: std.mem.Allocator) !void {
    var h = try Harness.init(alloc, .{});
    defer h.deinit();
    const a = try tmpPathAlloc(alloc, "drop a.txt");
    defer alloc.free(a);
    const b = try tmpPathAlloc(alloc, "drop%b|.txt");
    defer alloc.free(b);
    defer std.Io.Dir.cwd().deleteFile(zc.clock.io(), a) catch {};
    defer std.Io.Dir.cwd().deleteFile(zc.clock.io(), b) catch {};
    try touch(a, "dropped-a\n");
    try touch(b, "dropped-b\n");

    try h.core.requestDropPaths(&.{ a, b }, false);
    try h.waitRowText(h.winGrid(), 0, "dropped-a", wait_ms);
    try expectEval(h, alloc, "vim.fn.expand('%:p')", a);
    try expectEval(h, alloc, "vim.fn.argc()", "2");
    try expectEval(h, alloc, "vim.fn.fnamemodify(vim.fn.argv(1), ':p')", b);
    try expectEval(h, alloc, "vim.fn.winnr('$')", "1");
}

/// The doc: a drop opens a new window only when the current buffer is
/// modified.
pub fn runDropOnModifiedBuffer(alloc: std.mem.Allocator) !void {
    var h = try Harness.init(alloc, .{});
    defer h.deinit();
    const a = try tmpPathAlloc(alloc, "drop_mod.txt");
    defer alloc.free(a);
    defer std.Io.Dir.cwd().deleteFile(zc.clock.io(), a) catch {};
    try touch(a, "dropped-a\n");

    try h.input("iunsaved<Esc>");
    try h.waitRowText(h.winGrid(), 0, "unsaved", wait_ms);
    try h.core.requestDropPaths(&.{a}, false);
    try h.waitWindowCount(2, wait_ms);
    try expectEval(h, alloc, "vim.fn.expand('%:p')", a);
}

/// The doc: dropping a directory starts the explorer plugin on it.
pub fn runDropDirectory(alloc: std.mem.Allocator) !void {
    var h = try Harness.init(alloc, .{});
    defer h.deinit();
    const dir = try tmpPathAlloc(alloc, "dropdir");
    defer alloc.free(dir);
    defer std.Io.Dir.cwd().deleteTree(zc.clock.io(), dir) catch {};
    try std.Io.Dir.cwd().createDirPath(zc.clock.io(), dir);
    const inner = try std.fmt.allocPrint(alloc, "{s}/inside.txt", .{dir});
    defer alloc.free(inner);
    try touch(inner, "x\n");

    try h.core.requestDropPaths(&.{dir}, false);
    // Which explorer is the server's business (netrw, or the built-in
    // directory browser of newer servers); that one lists the directory is not.
    try waitScreen(h, "inside.txt");
    const ft = try evalAlloc(h, alloc, "vim.bo.filetype");
    defer alloc.free(ft);
    try std.testing.expect(ft.len != 0);
}

/// The doc: with the command line open, a drop inserts the names there.
/// The frontend asks the core's rule, then types the escaped paths.
pub fn runDropIntoCmdline(alloc: std.mem.Allocator) !void {
    var h = try Harness.init(alloc, .{});
    defer h.deinit();
    try std.testing.expect(zc.frontend_rules.dropInsertsPath("cmdline_normal", false, false));
    try std.testing.expect(!zc.frontend_rules.dropInsertsPath("normal", false, false));

    try h.input(":let g:gd_dropped = '");
    h.core.sendInput("/tmp/some file.txt");
    try h.input("'<CR>");
    try waitEval(h, alloc, "vim.g.gd_dropped", "/tmp/some file.txt");
}
