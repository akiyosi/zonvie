// font_picker — `:set guifont=*` asks for the font in Neovim itself: the
// installed monospace families through vim.ui.select, the size through
// vim.ui.input, and the answer becomes 'guifont'. Answered here as a user
// would, by keys: the first family, then the size offered.
//
// Linux-only: linux/font_picker.zig.

const std = @import("std");
const driver = @import("../../driver.zig");
const Gui = driver.Gui;
const app_log = @import("../../app_log.zig");
const gui_io = @import("../../gui_io.zig");

const log_path = "tmp/gui_font_picker.log";

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

    // The list of families is longer than the screen: no pager before the
    // prompt that takes the number.
    try g.exec("execute('set nomore')");
    try g.exec("execute('set guifont=monospace:h13')");
    gui_io.sleepNs(300 * std.time.ns_per_ms);
    try g.exec("execute('set guifont=*')");
    gui_io.sleepNs(800 * std.time.ns_per_ms);

    // The first family of the list, then the size as offered (13).
    try g.remoteSend("1<CR>");
    gui_io.sleepNs(500 * std.time.ns_per_ms);
    try g.remoteSend("<CR>");
    gui_io.sleepNs(800 * std.time.ns_per_ms);

    const gf = try g.remoteExpr("&guifont");
    defer alloc.free(gf);
    const value = std.mem.trim(u8, gf, " \n");
    std.debug.print("[gui] guifont after the pick: \"{s}\"\n", .{value});
    if (std.mem.eql(u8, value, "*")) return error.FontPickerLeftTheAsterisk;
    if (std.mem.eql(u8, value, "monospace:h13")) return error.FontNotChosen;
    if (!std.mem.endsWith(u8, value, ":h13")) return error.FontSizeNotKept;
}
