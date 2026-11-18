// tab_tearoff — a tab dragged out of the titlebar strip (past the tear-off
// distance) becomes an external window holding the tab's buffer, as on
// macOS and Windows: an external float (nvim_open_win external=true), which
// a stock Neovim gives through ext_multigrid. Driven through the
// compositor's virtual pointer.
//
// Linux-only: linux/chrome.zig's tear-off.

const std = @import("std");
const driver = @import("../../driver.zig");
const platform = driver.platform;
const app_log = @import("../../app_log.zig");
const gui_io = @import("../../gui_io.zig");
const btn_left = @import("../../linux_pointer.zig").btn_left;

const log_path = "tmp/gui_tab_tearoff.log";
/// Where the first tab starts and the strip's middle, logical px (as
/// tabline_pointer.zig measures them).
const strip_inset = 16;
const strip_mid_y = 14;
const plus_w = 40;

pub fn run(alloc: std.mem.Allocator) !void {
    var ptr = platform.pointer() orelse {
        std.debug.print("[gui] skipped: no virtual pointer on this compositor\n", .{});
        return error.SkipZigTest;
    };
    defer ptr.deinit();

    std.Io.Dir.cwd().createDirPath(gui_io.io(), "tmp") catch {};
    std.Io.Dir.cwd().deleteFile(gui_io.io(), log_path) catch {};
    var g = try driver.Gui.init(alloc, .{
        .app_args = &.{ "--log", log_path },
        .config_dir = "test/gui/fixtures/config_tabline",
    });
    defer g.deinit();
    g.activateApp();
    try app_log.waitFramesAfter(alloc, log_path, 1, 1, 0, 10_000);

    try g.exec("execute('silent! tabonly | enew | file one | tabnew | file two | 1tabnext')");
    gui_io.sleepNs(600 * std.time.ns_per_ms);
    const b = g.mainWindowBounds() orelse return error.MainWindowNotFound;
    const tab_w = std.math.clamp(@floor((b.w - strip_inset - plus_w) / 2), 100, 200);
    const from: [2]f64 = .{ b.x + strip_inset + tab_w * 1.4, b.y + strip_mid_y };

    const mark = try app_log.lineMark(alloc, log_path);
    // Down into the editor, well past the strip's tear-off distance.
    ptr.drag(from, .{ from[0], from[1] + 220 }, 20);
    try app_log.waitAfter(alloc, log_path, "[external_window] open", mark, 5_000);
    gui_io.sleepNs(500 * std.time.ns_per_ms);

    const ext_buf = try g.remoteExpr("luaeval('(function() for _, w in ipairs(vim.api.nvim_list_wins()) do if vim.api.nvim_win_get_config(w).external then return vim.fn.bufname(vim.api.nvim_win_get_buf(w)) end end return \"\" end)()')");
    defer alloc.free(ext_buf);
    const name = std.mem.trim(u8, ext_buf, " \n");
    std.debug.print("[gui] tear-off: external window shows \"{s}\"\n", .{name});
    if (!std.mem.eql(u8, name, "two")) return error.TornOffTabNotExternal;
}
