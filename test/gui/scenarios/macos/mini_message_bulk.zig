// mini_message_bulk — a bulk message routed to the mini view must stay a
// mini popup.
//
// Reported: with `msg_show` routed to mini, `:history` (~2000 lines) was
// handed to a single NSTextField inside a borderless window sized to fit,
// i.e. roughly 32,500 points tall. Laying that out blocked the main thread
// for 9.1 seconds — the log went completely silent, no draw and no present.
//
// The freeze itself is not observable from outside (the window server keeps
// compositing the last frame either way), but its cause is: the popup's
// height. A mini popup taller than the whole editor window is the bug, and
// the bound now keeps it to a handful of lines.
//
// Detection accounts for both delivery paths: the frontend REUSES a mini
// window per slot (updateMini), so if a startup-time message already pinned
// the popup open (the fixture routes every msg_show to mini with timeout 0),
// the bulk echo produces no NEW window — it resizes the existing one.
// Candidates are therefore fresh windows plus pre-existing windows whose
// height changed, which also stops an unrelated fresh window from passing
// the test vacuously.

const std = @import("std");
const gui_io = @import("../../gui_io.zig");
const driver = @import("../../driver.zig");
const platform = driver.platform;
const Gui = driver.Gui;

const max_windows = 16;
const settle_polls = 4; // bounds unchanged for 4 * 250 ms = startup settled

/// Poll until the main-window bounds stop changing, then return them.
fn waitStableMainBounds(g: *Gui) !platform.Bounds {
    var timer = gui_io.Timer.start();
    var last: ?platform.Bounds = null;
    var same: u32 = 0;
    while (true) {
        if (timer.read() / std.time.ns_per_ms >= 15_000) return error.Timeout;
        gui_io.sleepNs(250 * std.time.ns_per_ms);
        const b = platform.mainWindowBoundsForPid(g.app_pid) orelse continue;
        if (last) |l| {
            if (l.x == b.x and l.y == b.y and l.w == b.w and l.h == b.h) {
                same += 1;
                if (same >= settle_polls) return b;
            } else {
                same = 0;
            }
        }
        last = b;
    }
}

fn heightBefore(set: []const platform.MainWindow, number: u32) ?f64 {
    for (set) |w| {
        if (w.number == number) return w.bounds.h;
    }
    return null;
}

pub fn run(alloc: std.mem.Allocator) !void {
    var g = try Gui.init(alloc, .{
        .app_args = &.{ "--extmessages", "--log", "tmp/gui_app.log" },
        .config_dir = "test/gui/fixtures/config_mini_bulk",
    });
    defer g.deinit();

    const main_b = try waitStableMainBounds(g);

    var before_buf: [max_windows]platform.MainWindow = undefined;
    const before = before_buf[0..platform.windowsForPid(g.app_pid, &before_buf)];

    // 400 lines in one message. Unbounded, this asks AppKit for a window
    // several thousand points tall.
    //
    // nvim_echo, not execute('echo ...'): execute() CAPTURES the output, so
    // no msg_show is ever emitted and nothing would appear.
    try g.exec(
        "luaeval('(function() local t = {} " ++
            "for i = 1, 400 do t[#t+1] = \"bulk line \" .. i .. \" ----------\" end " ++
            "vim.api.nvim_echo({{table.concat(t, \"\\n\")}}, true, {}) return 1 end)()')",
    );

    var timer = gui_io.Timer.start();
    while (true) {
        if (timer.read() / std.time.ns_per_ms >= 15_000) {
            std.debug.print(
                "[gui] mini_message_bulk: no popup appeared or resized in 15s " ++
                    "({d} app window(s)); is the config_mini_bulk route fixture loaded?\n",
                .{platform.windowCountForPid(g.app_pid)},
            );
            return error.Timeout;
        }

        var now_buf: [max_windows]platform.MainWindow = undefined;
        const now = now_buf[0..platform.windowsForPid(g.app_pid, &now_buf)];

        // Candidates: windows the bulk echo demonstrably touched — brand new,
        // or pre-existing with a changed height. The main window is excluded
        // automatically (present in `before`, height unchanged).
        var candidates: usize = 0;
        for (now) |w| {
            const prev_h = heightBefore(before, w.number);
            const is_fresh = prev_h == null;
            const resized = prev_h != null and prev_h.? != w.bounds.h;
            if (!is_fresh and !resized) continue;
            candidates += 1;
            if (w.bounds.h > main_b.h) {
                std.debug.print(
                    "[gui] mini popup is taller than the editor window: main_h={d:.0} mini_h={d:.0}\n",
                    .{ main_b.h, w.bounds.h },
                );
                return error.MiniWindowUnbounded;
            }
            std.debug.print(
                "[gui] mini_message_bulk: popup bounded at {d:.0}pt (editor window {d:.0}pt, {s})\n",
                .{ w.bounds.h, main_b.h, if (is_fresh) "fresh" else "resized" },
            );
        }
        if (candidates > 0) return;
        gui_io.sleepNs(100 * std.time.ns_per_ms);
    }
}
