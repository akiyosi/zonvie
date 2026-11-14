// copy_button_pointer — the copy button on an ext-float message puts the
// message's text on the clipboard. Clicked through the compositor's virtual
// pointer; read back through Neovim's `+` register, which this frontend
// serves from the same clipboard.
//
// Linux-only: linux/ui_widgets.zig's copy buttons.

const std = @import("std");
const driver = @import("../../driver.zig");
const platform = driver.platform;
const Gui = driver.Gui;
const app_log = @import("../../app_log.zig");
const gui_io = @import("../../gui_io.zig");
const btn_left = @import("../../linux_pointer.zig").btn_left;

const log_path = "tmp/gui_copy_button_pointer.log";
const text = "copy me 12345";

pub fn run(alloc: std.mem.Allocator) !void {
    var ptr = platform.pointer() orelse {
        std.debug.print("[gui] skipped: no virtual pointer on this compositor\n", .{});
        return error.SkipZigTest;
    };
    defer ptr.deinit();

    std.Io.Dir.cwd().createDirPath(gui_io.io(), "tmp") catch {};
    std.Io.Dir.cwd().deleteFile(gui_io.io(), log_path) catch {};
    var g = try Gui.init(alloc, .{
        .app_args = &.{ "--extmessages", "--log", log_path },
        .config_dir = "test/gui/fixtures/config_render_trace",
    });
    defer g.deinit();
    g.activateApp();
    try app_log.waitFramesAfter(alloc, log_path, 1, 1, 0, 10_000);

    try g.exec("execute('let @+ = \"\"')");
    try g.exec("nvim_echo([['" ++ text ++ "']], v:true, {})");
    gui_io.sleepNs(500 * std.time.ns_per_ms);
    const b = g.mainWindowBounds() orelse return error.MainWindowNotFound;

    // The message panel hangs 10 px in from the top-right corner of the
    // editor view, which sits inside the card's margin and padding; its copy
    // button is 18 px square, 8 px in from the panel's top and right edges
    // (overlay_layout.copyButtonRect). The card's inset is
    // frontend_rules.island_margin_pt + island_padding_pt, logical px.
    const card = 12;
    ptr.click(b.x + b.w - card - 10 - 8 - 9, b.y + card + 10 + 8 + 9, btn_left);
    gui_io.sleepNs(400 * std.time.ns_per_ms);
    const got = try g.remoteExpr("getreg('+')");
    defer alloc.free(got);

    std.debug.print("[gui] clipboard after copy click: \"{s}\"\n", .{std.mem.trim(u8, got, " \n")});
    if (std.mem.indexOf(u8, got, text) == null) return error.CopyButtonDidNotCopy;
}
