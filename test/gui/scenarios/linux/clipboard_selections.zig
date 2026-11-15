// clipboard_selections — Neovim's `*` register is the PRIMARY selection and
// `+` the CLIPBOARD, as Neovim's own Linux providers map them: each keeps
// its own text, read back through this frontend's provider.
//
// Linux-only: linux/callbacks.zig selectionFor.

const std = @import("std");
const driver = @import("../../driver.zig");
const Gui = driver.Gui;
const app_log = @import("../../app_log.zig");
const gui_io = @import("../../gui_io.zig");

const log_path = "tmp/gui_clipboard_selections.log";

fn reg(g: *Gui, name: []const u8) ![]u8 {
    var buf: [32]u8 = undefined;
    const got = try g.remoteExpr(try std.fmt.bufPrint(&buf, "getreg('{s}')", .{name}));
    std.debug.print("[gui] getreg('{s}') = \"{s}\"\n", .{ name, std.mem.trim(u8, got, " \n") });
    return got;
}

pub fn run(alloc: std.mem.Allocator) !void {
    std.Io.Dir.cwd().createDirPath(gui_io.io(), "tmp") catch {};
    std.Io.Dir.cwd().deleteFile(gui_io.io(), log_path) catch {};
    var g = try Gui.init(alloc, .{
        .app_args = &.{ "--log", log_path },
        .config_dir = "test/gui/fixtures/config_render_trace",
    });
    defer g.deinit();
    g.activateApp();
    try app_log.waitFramesAfter(alloc, log_path, 1, 1, 0, 10_000);

    try g.exec("execute('let @+ = \"plus text\"')");
    try g.exec("execute('let @* = \"star text\"')");
    gui_io.sleepNs(300 * std.time.ns_per_ms);
    const plus = try reg(g, "+");
    defer alloc.free(plus);
    const star = try reg(g, "*");
    defer alloc.free(star);
    if (std.mem.indexOf(u8, plus, "plus text") == null) return error.ClipboardLostItsText;
    if (std.mem.indexOf(u8, star, "star text") == null) return error.PrimaryLostItsText;
}
