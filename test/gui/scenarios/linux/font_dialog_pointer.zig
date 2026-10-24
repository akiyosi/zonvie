// font_dialog_pointer — `:set guifont=*` opens GTK's font dialog, and a font
// chosen in it becomes guifont. Clicked through the compositor's virtual
// pointer: the first listed font, then Select.
//
// Linux-only: linux/font_picker.zig.

const std = @import("std");
const driver = @import("../../driver.zig");
const platform = driver.platform;
const Gui = driver.Gui;
const app_log = @import("../../app_log.zig");
const gui_io = @import("../../gui_io.zig");
const btn_left = @import("../../linux_pointer.zig").btn_left;

const log_path = "tmp/gui_font_dialog_pointer.log";

pub fn run(alloc: std.mem.Allocator) !void {
    var ptr = platform.pointer() orelse {
        std.debug.print("[gui] skipped: no virtual pointer on this compositor\n", .{});
        return error.SkipZigTest;
    };
    defer ptr.deinit();

    std.Io.Dir.cwd().createDirPath(gui_io.io(), "tmp") catch {};
    std.Io.Dir.cwd().deleteFile(gui_io.io(), log_path) catch {};
    var g = try Gui.init(alloc, .{
        .app_args = &.{ "--log", log_path },
        .config_dir = "test/gui/fixtures/config_render_trace",
    });
    defer g.deinit();
    g.activateApp();
    try app_log.waitFramesAfter(alloc, log_path, 1, 1, 0, 10_000);

    try g.exec("execute('set guifont=monospace:h13')");
    gui_io.sleepNs(300 * std.time.ns_per_ms);
    try g.exec("execute('set guifont=*')");
    var waited: u32 = 0;
    const d = while (waited < 5000) : (waited += 100) {
        if (platform.windowWithTitle(g.app_pid, "Font")) |b| break b;
        gui_io.sleepNs(100 * std.time.ns_per_ms);
    } else return error.FontDialogDidNotOpen;
    gui_io.sleepNs(500 * std.time.ns_per_ms);

    // The first row of the font list, then Select at the header's right.
    ptr.click(d.x + 100, d.y + 114, btn_left);
    gui_io.sleepNs(300 * std.time.ns_per_ms);
    ptr.click(d.x + d.w - 48, d.y + 23, btn_left);
    gui_io.sleepNs(800 * std.time.ns_per_ms);

    const gf = try g.remoteExpr("&guifont");
    defer alloc.free(gf);
    const value = std.mem.trim(u8, gf, " \n");
    std.debug.print("[gui] guifont after the dialog: \"{s}\"\n", .{value});
    if (platform.windowWithTitle(g.app_pid, "Font") != null) return error.FontDialogStillOpen;
    if (std.mem.eql(u8, value, "monospace:h13") or std.mem.indexOf(u8, value, ":h") == null) return error.FontNotChosen;
}
