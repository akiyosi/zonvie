// visual/extwin_glyphs_added_while_open — glyphs the atlas gains while an
// external window is open must show in that window.
//
// Every window samples one atlas texture, fed from one upload queue. Two
// orders reach it: glyphs the main window drew first (it applied the queue),
// then shown in the external window; and glyphs only the external window
// shows (it applies the queue itself). Each batch is CJK the session has not
// drawn yet, so each one adds atlas uploads.
//
// The oracle is ink: the share of the external window's pixels far from
// `Normal`'s background. A glyph whose pixels never reached the texture
// samples zeros and draws nothing, so a batch that lost its uploads shows
// far less ink than the first one.

const std = @import("std");
const driver = @import("../../driver.zig");
const capture = driver.capture;
const fixture = @import("fixture.zig");
const gui_io = @import("../../gui_io.zig");
const app_log = @import("../../app_log.zig");

const log_path = "tmp/gui_extwin_glyphs_added.log";
const rows = 8;
const cols = 12;

/// Pixels whose channels sum this far from black (Normal's background).
fn ink(img: capture.Image) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (i + 3 < img.rgba.len) : (i += 4) {
        const s = @as(u32, img.rgba[i]) + img.rgba[i + 1] + img.rgba[i + 2];
        if (s > 192) n += 1;
    }
    return n;
}

/// A Lua list of `rows` lines of `cols` CJK ideographs from `first`.
fn linesLua(buf: []u8, first: u32) ![]const u8 {
    return std.fmt.bufPrint(buf, "(function() local t = {{}} for r = 0, {d} do local s = \"\" for c = 0, {d} do s = s .. vim.fn.nr2char({d} + r * {d} + c) end t[#t + 1] = s end return t end)()", .{ rows - 1, cols - 1, first, cols });
}

fn captureExt(alloc: std.mem.Allocator, number: u32, name: []const u8, mark: usize) !usize {
    try app_log.waitFramesAfter(alloc, log_path, app_log.any_external_surface, 2, mark, 10_000);
    var img = try capture.captureWindow(alloc, number);
    defer img.deinit(alloc);
    var path_buf: [128]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "tmp/extwin_glyphs_{s}" ++ capture.image_ext, .{name});
    capture.writeImage(alloc, path, img) catch {};
    const n = ink(img);
    std.debug.print("[gui] extwin_glyphs_added_while_open: {s}: {d}x{d}, ink {d}\n", .{ name, img.w, img.h, n });
    return n;
}

pub fn run(alloc: std.mem.Allocator) !void {
    try fixture.requireScreenAccess();
    std.Io.Dir.cwd().createDirPath(gui_io.io(), "tmp") catch {};
    std.Io.Dir.cwd().deleteFile(gui_io.io(), log_path) catch {};

    var g = try fixture.openWithLogAndConfig(alloc, log_path, "test/gui/fixtures/config_hosted_opaque");
    defer g.deinit();
    g.activateApp();

    try g.exec("execute('set laststatus=0 noruler noshowcmd showtabline=0 nowrap noswapfile')");
    try g.exec("execute('highlight Normal guibg=#000000 guifg=#ffffff')");
    try g.exec("execute('highlight NormalFloat guibg=#000000 guifg=#ffffff')");

    var lua: [512]u8 = undefined;
    var cmd: [1024]u8 = undefined;

    // Batch A, drawn by the main window first.
    var mark = try app_log.lineMark(alloc, log_path);
    try g.exec(try std.fmt.bufPrint(&cmd, "luaeval('(function() _G.z_buf = vim.api.nvim_create_buf(false, true) vim.api.nvim_buf_set_lines(_G.z_buf, 0, -1, false, {s}) vim.api.nvim_win_set_buf(0, _G.z_buf) return 1 end)()')", .{try linesLua(&lua, 0x5000)}));
    try app_log.waitFramesAfter(alloc, log_path, 1, 2, mark, 10_000);

    // An external window on a buffer of its own showing batch A.
    const before = driver.snapshotWindows(g.app_pid);
    mark = try app_log.lineMark(alloc, log_path);
    try g.exec(try std.fmt.bufPrint(&cmd, "luaeval('(function() local b = vim.api.nvim_create_buf(false, true) vim.api.nvim_buf_set_lines(b, 0, -1, false, {s}) _G.z_ext = vim.api.nvim_open_win(b, false, {{external=true, width={d}, height={d}}}) return 1 end)()')", .{ try linesLua(&lua, 0x5000), cols * 2 + 2, rows + 1 }));
    const ext = try driver.waitNewWindow(g.app_pid, before.slice(), 100);
    const ink_a = try captureExt(alloc, ext.number, "a", mark);
    if (ink_a < 500) {
        std.debug.print("[gui] the external window shows almost no text for glyphs the main window drew first\n", .{});
        return error.ExternalWindowMissingGlyphs;
    }

    // Batches B and C, which only the external window shows.
    for ([_]u32{ 0x6000, 0x7000 }, [_][]const u8{ "b", "c" }) |first, name| {
        mark = try app_log.lineMark(alloc, log_path);
        try g.exec(try std.fmt.bufPrint(&cmd, "luaeval('(function() vim.api.nvim_buf_set_lines(vim.api.nvim_win_get_buf(_G.z_ext), 0, -1, false, {s}) return 1 end)()')", .{try linesLua(&lua, first)}));
        const n = try captureExt(alloc, ext.number, name, mark);
        if (n * 2 < ink_a) {
            std.debug.print("[gui] batch {s} shows less than half batch a's ink: its glyphs did not reach the external window\n", .{name});
            return error.ExternalWindowMissingGlyphs;
        }
    }
}
