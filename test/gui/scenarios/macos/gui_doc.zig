// gui_doc — the use cases of Neovim's `gui.txt` ("Stop or detach the current
// UI" onward) that only the real app can answer: what happens to its window
// and its process when the server restarts, is swapped, or lets the UI go,
// and whether a real pointer press reaches the cell under it.
//
// The protocol half (what the core does with the `restart` / `connect`
// events, every mouse keycode, menus, file drops) is the headless tier:
// test/e2e/scenarios/gui_doc.zig.
//
// One scenario per struct, so the runner reports each on its own line.
// macOS-only: window enumeration, capture and CGEvent clicks.

const std = @import("std");
const driver = @import("../../driver.zig");
const platform = driver.platform;
const Gui = driver.Gui;
const gui_io = @import("../../gui_io.zig");
const visual = @import("../../visual.zig");

const wait_ms = 15_000;

/// Poll an integer expression until it is `want`. A failed evaluation is a
/// reason to ask again, not to stop: the server is restarting or the UI is
/// between two of them.
fn waitInt(g: *Gui, expr: []const u8, want: i64) !void {
    var timer = gui_io.Timer.start();
    var last: ?i64 = null;
    while (true) {
        if (evalIntQuiet(g, expr)) |v| {
            if (v == want) return;
            last = v;
        }
        if (timer.read() / std.time.ns_per_ms >= wait_ms) {
            std.debug.print("[gui] gui_doc: `{s}` never became {d} (last {?d})\n", .{ expr, want, last });
            return error.Timeout;
        }
        gui_io.sleepNs(100 * std.time.ns_per_ms);
    }
}

/// evalInt without the driver's failure print, for polling across a restart.
fn evalIntQuiet(g: *Gui, expr: []const u8) ?i64 {
    const result = std.process.run(g.alloc, gui_io.io(), .{
        .argv = &.{ g.nvim_path, "--server", g.listen_addr, "--remote-expr", expr },
    }) catch return null;
    defer g.alloc.free(result.stdout);
    defer g.alloc.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code != 0) return null,
        else => return null,
    }
    return std.fmt.parseInt(i64, std.mem.trim(u8, result.stdout, " \t\r\n"), 10) catch null;
}

/// Run an ex command that acts on "the current UI" (`:detach`, `:connect`).
/// That is the channel that last sent input, attached or gained focus
/// (input_enqueue, nvim_ui_attach, nvim_ui_set_focus), so `--remote-send`
/// would name the oracle's own channel, which is no UI. A timer runs the
/// command on the server with no input from anyone: the app stays current,
/// as it is when its user types the command.
fn runAsCurrentUi(g: *Gui, comptime cmd_fmt: []const u8, args: anytype) !void {
    const expr = try std.fmt.allocPrint(g.alloc, "timer_start(100, {{-> execute('" ++ cmd_fmt ++ "')}})", args);
    defer g.alloc.free(expr);
    try g.exec(expr);
}

fn killPid(alloc: std.mem.Allocator, pid: i64) void {
    var buf: [24]u8 = undefined;
    const pid_str = std.fmt.bufPrint(&buf, "{d}", .{pid}) catch return;
    const result = std.process.run(alloc, gui_io.io(), .{ .argv = &.{ "kill", "-9", pid_str } }) catch return;
    alloc.free(result.stdout);
    alloc.free(result.stderr);
}

/// Save the main window as it is drawn now, for a person to look at: no
/// oracle on the server knows what the app put on screen.
fn snapshot(g: *Gui, comptime name: []const u8) void {
    var img = g.captureStable(null, 3_000) catch |e| {
        std.debug.print("[gui] gui_doc: no capture for {s}: {t}\n", .{ name, e });
        return;
    };
    defer img.deinit(g.alloc);
    const path = "tmp/gui_doc_" ++ name ++ driver.capture.image_ext;
    driver.capture.writeImage(g.alloc, path, img) catch return;
    std.debug.print("[gui] gui_doc: wrote {s}\n", .{path});
}

/// `:restart` — the window and the app process stay, attached to a new server
/// that has the session back.
pub const Restart = struct {
    pub fn run(alloc: std.mem.Allocator) !void {
        var g = try Gui.init(alloc, .{});
        defer g.deinit();
        if (try g.evalInt("exists(':restart')") != 2) return error.SkipZigTest;

        try g.exec("execute('edit tmp/gui_doc_restart.txt | call setline(1, \"kept across restart\") | write')");
        defer std.Io.Dir.cwd().deleteFile(gui_io.io(), "tmp/gui_doc_restart.txt") catch {};
        const app_pid = g.app_pid;
        const old_pid = try g.evalInt("getpid()");
        try waitInt(g, "len(nvim_list_uis())", 1);

        try g.remoteSend(":restart<CR>");
        var expr_buf: [128]u8 = undefined;
        const replaced = try std.fmt.bufPrint(&expr_buf, "getpid() != {d} && len(nvim_list_uis()) == 1 && v:startreason ==# 'restart'", .{old_pid});
        try waitInt(g, replaced, 1);
        const new_pid = try g.evalInt("getpid()");
        // The new server is nobody's child; nothing else would end it.
        defer killPid(alloc, new_pid);
        if (new_pid == old_pid) return error.ServerNotReplaced;

        try g.waitWindowCount(1, wait_ms);
        if (g.app_pid != app_pid) return error.AppRelaunched;
        try waitInt(g, "expand('%:t') ==# 'gui_doc_restart.txt' && getline(1) ==# 'kept across restart'", 1);
        snapshot(g, "restart");
    }
};

/// `:connect {address}` — the same window moves to the other server.
pub const Connect = struct {
    pub fn run(alloc: std.mem.Allocator) !void {
        var g = try Gui.init(alloc, .{});
        defer g.deinit();
        if (try g.evalInt("exists(':connect')") != 2) return error.SkipZigTest;

        const tmp_abs = try std.Io.Dir.cwd().realPathFileAlloc(gui_io.io(), "tmp", alloc);
        defer alloc.free(tmp_abs);
        const addr = try std.fmt.allocPrint(alloc, "{s}/gui_doc_b_{d}.sock", .{ tmp_abs, std.c.getpid() });
        defer alloc.free(addr);
        std.Io.Dir.cwd().deleteFile(gui_io.io(), addr) catch {};
        var other = try std.process.spawn(gui_io.io(), .{
            .argv = &.{ g.nvim_path, "--clean", "-n", "--headless", "--listen", addr, "-c", "call setline(1, 'the other server')" },
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .ignore,
        });
        defer {
            other.kill(gui_io.io());
            std.Io.Dir.cwd().deleteFile(gui_io.io(), addr) catch {};
        }

        const app_pid = g.app_pid;
        try waitInt(g, "len(nvim_list_uis())", 1);
        // The other server has to be listening before :connect probes it.
        {
            const first_addr = g.listen_addr;
            g.listen_addr = addr;
            defer g.listen_addr = first_addr;
            try waitInt(g, "len(nvim_list_uis())", 0);
        }
        try runAsCurrentUi(g, "connect {s}", .{addr});

        // From here the oracle is the other server.
        const first_addr = g.listen_addr;
        g.listen_addr = addr;
        defer g.listen_addr = first_addr;
        try waitInt(g, "len(nvim_list_uis())", 1);
        try g.waitWindowCount(1, wait_ms);
        if (g.app_pid != app_pid) return error.AppRelaunched;
        snapshot(g, "connect");
    }
};

/// `:detach` from a `--remote-ui` session — the app ends, the server keeps
/// running, and a new `zonvie --remote-ui` attaches to it again.
pub const DetachThenReattach = struct {
    pub fn run(alloc: std.mem.Allocator) !void {
        var g = try Gui.init(alloc, .{});
        defer g.deinit();
        if (try g.evalInt("exists(':detach')") != 2) return error.SkipZigTest;

        try g.exec("setline(1, ['line one of the detached session', 'line two', 'line three'])");
        try waitInt(g, "len(nvim_list_uis())", 1);

        try runAsCurrentUi(g, "detach", .{});
        if (!g.waitAppExit(wait_ms)) {
            std.debug.print("[gui] gui_doc: the app is still running after :detach ({d} windows)\n", .{g.windowCount()});
            return error.AppSurvivedDetach;
        }
        try waitInt(g, "len(nvim_list_uis())", 0);
        try waitInt(g, "getline(1) ==# 'line one of the detached session'", 1);

        // What the reattached window draws is ReattachShowsContent's.
        try g.relaunchApp();
        try waitInt(g, "len(nvim_list_uis())", 1);
    }
};

/// The window of an app that reattaches shows what the detached one did.
///
/// NEOVIM BUG, fixed by neovim/neovim#42667: on a server without it, a
/// multigrid UI attaching after another one is sent only the cells that
/// differ from the window grids the server already holds, so the buffer area
/// stays empty under a drawn statusline (test/e2e/scenarios/gui_doc.zig, runReattachShowsWindowContent,
/// has the event-level account). Skips while the server does that.
pub const ReattachShowsContent = struct {
    pub fn run(alloc: std.mem.Allocator) !void {
        var g = try Gui.init(alloc, .{});
        defer g.deinit();
        if (try g.evalInt("exists(':detach')") != 2) return error.SkipZigTest;

        try g.exec("setline(1, ['line one of the detached session', 'line two', 'line three'])");
        try waitInt(g, "len(nvim_list_uis())", 1);
        snapshot(g, "detach_before");
        // The text's corner, fixed in points so both captures are one size.
        const text_crop: driver.capture.Crop = .{ .w_pt = 600, .h_pt = 200 };
        var before = try g.captureStable(text_crop, 3_000);
        defer before.deinit(alloc);

        try runAsCurrentUi(g, "detach", .{});
        if (!g.waitAppExit(wait_ms)) return error.AppSurvivedDetach;
        try g.relaunchApp();
        try waitInt(g, "len(nvim_list_uis())", 1);
        gui_io.sleepNs(std.time.ns_per_s);
        snapshot(g, "detach_reattached");

        // The server's buffer did not change. No oracle on the server knows
        // what the app drew; the two captures do.
        var after = try g.captureStable(text_crop, 3_000);
        defer after.deinit(alloc);
        if (after.w != before.w or after.h != before.h) return error.CaptureSizeChanged;
        const diff = visual.regionDiffRatio(before, after, .{}, 8);
        // A blinking cursor cell is about 0.1% of the crop; three lines of
        // text missing is well over 1%.
        if (diff > 0.005) {
            std.debug.print(
                "[gui] skipped, server lacks neovim#42667: the reattached window differs from the detached one in {d:.2}% of the text corner\n",
                .{diff * 100},
            );
            return error.SkipZigTest;
        }
    }
};

/// `:detach` from a plain launch (the app's own embedded server) — the doc's
/// "the server (typically `nvim --embed`) continues running", and the app is
/// expected to end like any UI whose channel closed.
pub const DetachEmbedded = struct {
    pub fn run(alloc: std.mem.Allocator) !void {
        var g = try Gui.init(alloc, .{ .embedded = true });
        defer g.deinit();
        if (try g.evalInt("exists(':detach')") != 2) return error.SkipZigTest;
        const server_pid = try g.evalInt("getpid()");
        defer killPid(alloc, server_pid);
        try g.exec("setline(1, ['embedded session', 'detached with :detach'])");
        try waitInt(g, "len(nvim_list_uis())", 1);

        try runAsCurrentUi(g, "detach", .{});
        try waitInt(g, "len(nvim_list_uis())", 0);
        if (!g.waitAppExit(wait_ms)) {
            std.debug.print(
                "[gui] gui_doc: {d}s after :detach the app still runs with {d} window(s), attached to nothing\n",
                .{ wait_ms / 1000, g.windowCount() },
            );
            snapshot(g, "detach_embedded_stuck");
            return error.AppHangsAfterDetach;
        }
        // The server outlived its UI.
        try waitInt(g, "getline(2) ==# 'detached with :detach'", 1);
    }
};

/// `:detach!` — the server outlives an app that dies without detaching; and
/// without it, it does not.
pub const DetachBang = struct {
    pub fn run(alloc: std.mem.Allocator) !void {
        {
            var g = try Gui.init(alloc, .{ .embedded = true });
            defer g.deinit();
            if (try g.evalInt("exists('*nvim_chan_set')") != 1) return error.SkipZigTest;
            const server_pid = try g.evalInt("getpid()");
            defer killPid(alloc, server_pid);
            killPid(alloc, g.app_pid);
            var timer = gui_io.Timer.start();
            while (evalIntQuiet(g, "1") != null) {
                if (timer.read() / std.time.ns_per_ms >= wait_ms) return error.ServerOutlivedKilledApp;
                gui_io.sleepNs(100 * std.time.ns_per_ms);
            }
        }

        var g = try Gui.init(alloc, .{ .embedded = true });
        defer g.deinit();
        const server_pid = try g.evalInt("getpid()");
        defer killPid(alloc, server_pid);
        try g.exec("setline(1, 'survives the app')");
        try runAsCurrentUi(g, "silent detach!", .{});
        try waitInt(g, "nvim_get_chan_info(nvim_list_uis()[0].chan).detach ? 1 : 0", 1);

        killPid(alloc, g.app_pid);
        gui_io.sleepNs(3 * std.time.ns_per_s);
        if (evalIntQuiet(g, "getline(1) ==# 'survives the app'") != 1) return error.ServerDiedDespiteDetachBang;
        try waitInt(g, "len(nvim_list_uis())", 0);
    }
};

/// A real file drag — an AppKit dragging session from another process,
/// released over the window — opens the files as `:drop` does, and with the
/// command line up it types their names instead.
pub const FileDrop = struct {
    const source_src = "test/gui/tools/drag_source.swift";
    const source_bin = "tmp/gui_drag_source";

    pub fn run(alloc: std.mem.Allocator) !void {
        if (!platform.accessibilityTrusted()) {
            std.debug.print("[gui] skipped: not trusted for Accessibility, so a drag cannot be posted.\n", .{});
            return error.SkipZigTest;
        }
        const built = std.process.run(alloc, gui_io.io(), .{
            .argv = &.{ "swiftc", "-O", source_src, "-o", source_bin },
        }) catch {
            std.debug.print("[gui] skipped: no swiftc to build the drag source\n", .{});
            return error.SkipZigTest;
        };
        defer alloc.free(built.stdout);
        defer alloc.free(built.stderr);
        switch (built.term) {
            .exited => |code| if (code != 0) {
                std.debug.print("[gui] gui_doc: drag source did not build:\n{s}\n", .{built.stderr});
                return error.DragSourceBuildFailed;
            },
            else => return error.DragSourceBuildFailed,
        }

        const tmp_abs = try std.Io.Dir.cwd().realPathFileAlloc(gui_io.io(), "tmp", alloc);
        defer alloc.free(tmp_abs);
        const file_a = try std.fmt.allocPrint(alloc, "{s}/gui_doc_drop_a.txt", .{tmp_abs});
        defer alloc.free(file_a);
        // A name that needs escaping on a command line.
        const file_b = try std.fmt.allocPrint(alloc, "{s}/gui doc drop b.txt", .{tmp_abs});
        defer alloc.free(file_b);
        try std.Io.Dir.cwd().writeFile(gui_io.io(), .{ .sub_path = file_a, .data = "dropped a\n" });
        try std.Io.Dir.cwd().writeFile(gui_io.io(), .{ .sub_path = file_b, .data = "dropped b\n" });
        defer std.Io.Dir.cwd().deleteFile(gui_io.io(), file_a) catch {};
        defer std.Io.Dir.cwd().deleteFile(gui_io.io(), file_b) catch {};

        var g = try Gui.init(alloc, .{});
        defer g.deinit();
        g.activateApp();

        var source = try std.process.spawn(gui_io.io(), .{
            .argv = &.{ source_bin, file_a, file_b },
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .ignore,
        });
        defer source.kill(gui_io.io());
        const source_pid: i32 = @intCast(source.id.?);
        var timer = gui_io.Timer.start();
        const src = while (true) {
            if (platform.mainWindowForPid(source_pid)) |w| break w;
            if (timer.read() / std.time.ns_per_ms >= wait_ms) return error.DragSourceNoWindow;
            gui_io.sleepNs(100 * std.time.ns_per_ms);
        };
        const sx = src.bounds.x + src.bounds.w * 0.5;
        const sy = src.bounds.y + src.bounds.h * 0.5;

        // 1. Onto a buffer: the files open.
        const b = g.mainWindowBounds() orelse return error.NoMainWindow;
        const tx = b.x + b.w * 0.5;
        const ty = b.y + b.h * 0.5;
        if (!platform.dragBetween(source_pid, sx, sy, g.app_pid, tx, ty)) return error.DragRefused;
        try waitInt(g, "expand('%:t') ==# 'gui_doc_drop_a.txt' && getline(1) ==# 'dropped a'", 1);
        try waitInt(g, "argc() == 2 && fnamemodify(argv(1), ':t') ==# 'gui doc drop b.txt'", 1);

        // 2. With the command line up: the names are typed into it, escaped.
        // The app's own input opens it, as a user's `:` would.
        try g.exec("execute('enew | argdelete *')");
        try g.exec("timer_start(50, {-> feedkeys(':let g:gui_doc_dropped = [', 'n')})");
        try waitInt(g, "mode() ==# 'c'", 1);
        gui_io.sleepNs(500 * std.time.ns_per_ms);
        if (!platform.dragBetween(source_pid, sx, sy, g.app_pid, tx, ty)) return error.DragRefused;
        try waitInt(g, "getcmdline() =~# 'gui_doc_drop_a.txt' && getcmdline() =~# 'gui\\\\ doc\\\\ drop\\\\ b.txt'", 1);
        try waitInt(g, "bufname('%') ==# ''", 1);
        try g.remoteSend("<C-c>");
    }
};

/// A real press on the window places the cursor on the cell under it, and a
/// second one within 'mousetime' selects the word.
pub const MouseClick = struct {
    pub fn run(alloc: std.mem.Allocator) !void {
        if (!platform.accessibilityTrusted()) {
            std.debug.print("[gui] skipped: not trusted for Accessibility, so clicks cannot be posted.\n", .{});
            return error.SkipZigTest;
        }
        var g = try Gui.init(alloc, .{ .config_dir = "test/gui/fixtures/config_no_scrollbar" });
        defer g.deinit();
        g.activateApp();

        try g.exec("execute('set mouse=a scrolloff=0 nowrap | call setline(1, map(range(1, 200), {_, n -> repeat(\"word\" .. n .. \" \", 60)})) | set nomodified')");
        const rows = try g.evalInt("winheight(0)");
        const cols = try g.evalInt("winwidth(0)");
        const b = g.mainWindowBounds() orelse return error.NoMainWindow;
        const x = b.x + b.w * 0.5;
        const y = b.y + b.h * 0.5;

        try g.exec("cursor(1, 1)");
        var attempt: u32 = 0;
        var moved = false;
        // A press on a window that is not key only brings it forward.
        while (attempt < 3 and !moved) : (attempt += 1) {
            if (!platform.clickAt(g.app_pid, x, y)) return error.ClickRefused;
            var tries: u32 = 0;
            while (tries < 15 and !moved) : (tries += 1) {
                gui_io.sleepNs(100 * std.time.ns_per_ms);
                moved = (try g.evalInt("line('.')")) != 1;
            }
        }
        if (!moved) return error.ClickNotDelivered;
        const line = try g.evalInt("winline()");
        const col = try g.evalInt("wincol()");
        std.debug.print("[gui] gui_doc: a click on the window's middle named ({d},{d}) of {d}x{d}\n", .{ line, col, rows, cols });
        // The frame's middle sits a little below the grid's: title bar.
        if (@abs(line - @divTrunc(rows, 2)) > 3 or @abs(col - @divTrunc(cols, 2)) > 3) return error.ClickOffCentre;

        // Past 'mousetime', so the pair below is counted from one.
        gui_io.sleepNs(700 * std.time.ns_per_ms);
        if (!platform.clickAt(g.app_pid, x, y)) return error.ClickRefused;
        if (!platform.clickAt(g.app_pid, x, y)) return error.ClickRefused;
        try waitInt(g, "mode() ==# 'v'", 1);
        try g.remoteSend("<Esc>");
    }
};
