// tabline_hover — the Linux ext_tabline strip shows the pointer where it
// would act: resting on a tab's × or on + paints a wash behind it. The strip
// drops the theme's button look, hover included, so this is the frontend's
// own rule to keep. Driven through the compositor's virtual pointer.
//
// Linux-only: linux/ui_widgets.zig's tab strip.

const std = @import("std");
const driver = @import("../../driver.zig");
const platform = driver.platform;
const Gui = driver.Gui;
const app_log = @import("../../app_log.zig");
const gui_io = @import("../../gui_io.zig");
const visual = @import("../../visual.zig");

const log_path = "tmp/gui_tabline_hover.log";

/// The strip's geometry, logical px, as tabline_pointer.zig has it: two tabs
/// at their 200 cap, starting past the editor card's corner, + after them.
const strip_inset = 16;
const tab_w = 200;
const plus_w = 40;
const strip_h = 28;
/// Fraction of a button's box the wash must change.
const min_changed = 0.3;

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
        .config_dir = "test/gui/fixtures/config_tabline",
    });
    defer g.deinit();
    g.activateApp();
    try app_log.waitFramesAfter(alloc, log_path, 1, 1, 0, 10_000);

    try g.exec("execute('silent! tabonly | enew | file one | tabnew | file two')");
    gui_io.sleepNs(600 * std.time.ns_per_ms);
    const b = g.mainWindowBounds() orelse return error.MainWindowNotFound;
    const tabs_end = strip_inset + 2 * tab_w;
    const y = b.y + strip_h / 2;

    // Away from the strip: nothing hovered.
    ptr.moveTo(b.x + b.w / 2, b.y + b.h / 2);
    gui_io.sleepNs(400 * std.time.ns_per_ms);
    var idle = try g.captureStable(null, 5_000);
    defer idle.deinit(alloc);

    ptr.moveTo(b.x + tabs_end + plus_w / 2, y);
    gui_io.sleepNs(400 * std.time.ns_per_ms);
    var on_plus = try g.captureStable(null, 5_000);
    defer on_plus.deinit(alloc);

    // The current tab's ×, at its trailing edge.
    ptr.moveTo(b.x + tabs_end - 14, y);
    gui_io.sleepNs(400 * std.time.ns_per_ms);
    var on_close = try g.captureStable(null, 5_000);
    defer on_close.deinit(alloc);

    const y1 = strip_h / b.h;
    const plus: visual.Region = .{ .x0 = (tabs_end + 8) / b.w, .x1 = (tabs_end + plus_w - 8) / b.w, .y0 = 0, .y1 = y1 };
    const close: visual.Region = .{ .x0 = (tabs_end - 22) / b.w, .x1 = (tabs_end - 6) / b.w, .y0 = 0, .y1 = y1 };
    const plus_changed = visual.regionDiffRatio(idle, on_plus, plus, 6);
    const close_changed = visual.regionDiffRatio(idle, on_close, close, 6);
    std.debug.print("[gui] hover changed: + {d:.3} close {d:.3} (min {d:.2})\n", .{ plus_changed, close_changed, min_changed });
    if (plus_changed < min_changed) return error.NewTabButtonHoverNotShown;
    if (close_changed < min_changed) return error.CloseButtonHoverNotShown;
}
