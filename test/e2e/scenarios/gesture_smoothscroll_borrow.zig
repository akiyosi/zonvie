// gesture_smoothscroll_borrow — the GUI turns 'smoothscroll' on for the window
// a trackpad gesture is driving, so a 'wrap'ped buffer moves one screen row at
// a time instead of a whole buffer line, and hands it back afterwards.
//
// The option belongs to the user, so the property that matters most is the
// restore: whatever it was before must come back, including when it was already
// on. Also checks the borrow is skipped for a window without 'wrap', where the
// option would do nothing and the OptionSet autocmd would be pure noise.

const std = @import("std");
const builtin = @import("builtin");
const Harness = @import("../harness.zig").Harness;

pub fn run(alloc: std.mem.Allocator) !void {
    // The core call is compiled out off macOS.
    if (comptime builtin.os.tag != .macos) return;

    var h = try Harness.init(alloc, .{});
    defer h.deinit();

    const g = h.winGrid();
    try h.command("call setline(1, map(range(1, 200), 'string(v:val)'))");
    try h.command("set wrap nosmoothscroll");
    try waitViewport(h, g);

    // Borrowed while the gesture runs.
    try borrow(h, g, true);
    try expectOption(h, "smoothscroll", true);
    // The user's value is remembered, not guessed.
    try expectWinVar(h, "zonvie_ss_prev", "v:false");

    // Handed back.
    try borrow(h, g, false);
    try expectOption(h, "smoothscroll", false);
    try expectNoWinVar(h, "zonvie_ss_prev");

    // A user who already had it on must still have it on afterwards.
    try h.command("set smoothscroll");
    try borrow(h, g, true);
    try expectOption(h, "smoothscroll", true);
    try borrow(h, g, false);
    try expectOption(h, "smoothscroll", true);
    try expectNoWinVar(h, "zonvie_ss_prev");

    // A second borrow before a restore must not overwrite the saved value with
    // the borrowed one, or the restore would leave it on forever.
    try h.command("set nosmoothscroll");
    try borrow(h, g, true);
    try borrow(h, g, true);
    try borrow(h, g, false);
    try expectOption(h, "smoothscroll", false);

    // Without 'wrap' the option does nothing, so the borrow is skipped and the
    // window is left completely untouched.
    try h.command("set nowrap nosmoothscroll");
    try borrow(h, g, true);
    try expectOption(h, "smoothscroll", false);
    try expectNoWinVar(h, "zonvie_ss_prev");
    try borrow(h, g, false);

    std.debug.print(
        "[e2e] gesture_smoothscroll_borrow: borrowed and restored, including an already-on window\n",
        .{},
    );
}

/// The core call is fire-and-forget over the same RPC channel as the checks
/// that follow, so ordering is enough; it only has to be issued.
fn borrow(h: *Harness, g: i64, enable: bool) !void {
    var tries: usize = 0;
    while (!h.core.setGestureSmoothScroll(g, enable)) {
        tries += 1;
        if (tries > 200) return error.BorrowNeverIssued;
        try flush(h);
    }
    try flush(h);
}

fn expectOption(h: *Harness, name: []const u8, want: bool) !void {
    var buf: [128]u8 = undefined;
    const cmd = try std.fmt.bufPrint(
        &buf,
        "let g:zonvie_probe = &{s} ? 'on' : 'off'",
        .{name},
    );
    try h.command(cmd);
    try expectProbe(h, if (want) "on" else "off", name);
}

fn expectWinVar(h: *Harness, name: []const u8, want_expr: []const u8) !void {
    var buf: [192]u8 = undefined;
    const cmd = try std.fmt.bufPrint(
        &buf,
        "let g:zonvie_probe = exists('w:{s}') && w:{s} == {s} ? 'yes' : 'no'",
        .{ name, name, want_expr },
    );
    try h.command(cmd);
    try expectProbe(h, "yes", name);
}

fn expectNoWinVar(h: *Harness, name: []const u8) !void {
    var buf: [128]u8 = undefined;
    const cmd = try std.fmt.bufPrint(
        &buf,
        "let g:zonvie_probe = exists('w:{s}') ? 'present' : 'absent'",
        .{name},
    );
    try h.command(cmd);
    try expectProbe(h, "absent", name);
}

/// Reads the probe back by echoing it into the message stream is fragile, so
/// the value is written into the buffer and read from the grid instead.
fn expectProbe(h: *Harness, want: []const u8, what: []const u8) !void {
    try h.command("call setline(1, g:zonvie_probe)");
    try h.command("normal! gg");
    const g = h.winGrid();
    const Ctx = struct { g: i64, want: []const u8 };
    h.waitUntil(Ctx{ .g = g, .want = want }, struct {
        fn check(c: Ctx, hh: *Harness) bool {
            return hh.cellAt(c.g, 0, 0).cp == c.want[0];
        }
    }.check, h.opts.timeout_ms) catch {};

    var buf: [64]u8 = undefined;
    var i: usize = 0;
    while (i < want.len and i < buf.len) : (i += 1) {
        buf[i] = @intCast(h.cellAt(g, 0, @intCast(i)).cp);
    }
    if (!std.mem.eql(u8, buf[0..want.len], want)) {
        std.debug.print(
            "[e2e] gesture_smoothscroll_borrow: {s} read back as '{s}', expected '{s}'\n",
            .{ what, buf[0..want.len], want },
        );
        return error.ProbeMismatch;
    }
    // Leave the buffer as it was for the next check.
    try h.command("undo");
}

fn flush(h: *Harness) !void {
    const Ctx = struct { target: u64 };
    h.waitUntil(
        Ctx{ .target = h.flush_seq.load(.seq_cst) + 1 },
        struct {
            fn check(c: Ctx, hh: *Harness) bool {
                return hh.flush_seq.load(.seq_cst) >= c.target;
            }
        }.check,
        200,
    ) catch {};
}

/// The borrow addresses a window-local option, so it needs the handle
/// win_viewport carries.
fn waitViewport(h: *Harness, g: i64) !void {
    const Ctx = struct { g: i64 };
    try h.waitUntil(Ctx{ .g = g }, struct {
        fn check(c: Ctx, hh: *Harness) bool {
            return hh.viewportWin(c.g) != 0;
        }
    }.check, h.opts.timeout_ms);
}
