// visual/sidebar_cards — multi-line 'guitablabel' cards in the macOS sidebar.
//
// Three tabs with a three-line label make three cards taller than the old
// fixed 28pt row. Hit testing must follow the card heights: a click at the
// vertical middle of card 2 selects tab 2, and the "+" button sits below
// card 3 (a click there opens a fourth tab). With the old fixed rows the
// first click would land on "+" instead.
//
// Needs an nvim that sends `name_chunks` for 'guitablabel' (upstream branch
// feat/ext-tabline-guitablabel); skipped on an nvim where the option is
// still an immutable stub.

const std = @import("std");
const driver = @import("../../driver.zig");
const fixture = @import("fixture.zig");
const capture = driver.capture;
const platform = driver.platform;
const gui_io = @import("../../gui_io.zig");
const Gui = driver.Gui;

/// Mirrors the macOS frontend: TitlebarBand.heightPt (the list's top inset
/// under a unified titlebar) and TabCardLayout (16pt lines + 12pt padding,
/// + 8pt for a multi-line card).
const band_pt: f64 = 44;
const card_pt: f64 = 3 * 16 + 12 + 8;
const new_tab_button_pt: f64 = 32;
/// Inside the sidebar, left of the close button.
const click_x_pt: f64 = 60;

pub fn run(alloc: std.mem.Allocator) !void {
    try fixture.requireScreenAccess();
    if (!platform.accessibilityTrusted()) {
        std.debug.print("[gui] skipped: not trusted for Accessibility, so clicks cannot be posted.\n", .{});
        return error.SkipZigTest;
    }
    var g = try Gui.init(alloc, .{
        .config_dir = "test/gui/fixtures/config_sidebar_cards",
        .app_args = &.{ "--log", "tmp/gui_sidebar_cards.log" },
    });
    defer g.deinit();

    if (try g.evalInt("exists('+guitablabel')") == 0) {
        std.debug.print("[gui] skipped: this nvim cannot set 'guitablabel'.\n", .{});
        return error.SkipZigTest;
    }

    driver.platform.pinWindow(g.app_pid, 80, 80);
    g.activateApp();
    try g.exec("execute('set guicursor+=a:blinkon0')");
    try g.exec("execute('set showtabline=2')");
    try g.exec("execute('let &guitablabel = \"tab %N\\nsecond line\\nthird line\"')");
    try g.exec("execute('tabnew')");
    try g.exec("execute('tabnew')");
    try g.exec("execute('1tabnext')");
    try g.exec("execute('redraw!')");

    var img = try g.captureStable(.{ .w_pt = 400, .h_pt = 400 }, 8000);
    defer img.deinit(alloc);
    try capture.writeImage(alloc, "tmp/sidebar_cards_actual.png", img);
    std.debug.print("[gui] wrote tmp/sidebar_cards_actual.png ({d}x{d})\n", .{ img.w, img.h });

    const win = g.mainWindowBounds() orelse return error.NoMainWindow;
    const x = win.x + click_x_pt;

    // Vertical middle of card 2.
    if (!platform.clickAt(g.app_pid, x, win.y + band_pt + card_pt * 1.5)) return error.ClickRefused;
    try waitInt(g, "tabpagenr()", 2);
    try std.testing.expectEqual(@as(i64, 3), try g.evalInt("tabpagenr('$')"));

    // The "+" button starts at the bottom of card 3.
    if (!platform.clickAt(g.app_pid, x, win.y + band_pt + card_pt * 3 + new_tab_button_pt / 2)) return error.ClickRefused;
    try waitInt(g, "tabpagenr('$')", 4);
}

fn waitInt(g: *Gui, expr: []const u8, want: i64) !void {
    var waited_ms: u64 = 0;
    while (waited_ms < 3000) : (waited_ms += 50) {
        if (try g.evalInt(expr) == want) return;
        gui_io.sleepNs(50 * std.time.ns_per_ms);
    }
    std.debug.print("[gui] {s}: got {d}, want {d}\n", .{ expr, try g.evalInt(expr), want });
    return error.TestUnexpectedResult;
}
