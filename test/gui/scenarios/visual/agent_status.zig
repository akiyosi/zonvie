// visual/agent_status — verify the AI-agent "working" glyph paints on the tab.
//
// The core forwards the per-tab `state` straight to the frontend, which owns
// the indicator glyph + spinner animation (the core does not decorate names).
// We exercise the core->render path directly by broadcasting the
// zonvie_agent_status notification (no real agent needed), then capture the
// tab bar so the result can be inspected.

const std = @import("std");
const driver = @import("../../driver.zig");
const fixture = @import("fixture.zig");
const capture = driver.capture;
const Gui = driver.Gui;

pub fn run(alloc: std.mem.Allocator) !void {
    // This scenario needs its own config_dir, so it builds the Gui itself
    // instead of going through fixture.open() — but it captures just the same
    // and must skip on a host without Screen Recording permission.
    try fixture.requireScreenAccess();
    var g = try Gui.init(alloc, .{
        .config_dir = "test/gui/fixtures/config_tabline",
        .app_args = &.{ "--log", "tmp/gui_agent.log" },
    });
    defer g.deinit();

    driver.platform.pinWindow(g.app_pid, 80, 80);
    try g.exec("execute('set guicursor+=a:blinkon0')");
    try g.exec("execute('set guifont=Menlo:h13')");
    try g.exec("execute('set showtabline=2')");
    // A named buffer so the single tab has a visible label.
    try g.exec("execute('edit agentwork.txt')");

    // Mark tabpage handle 1 (the first/only tabpage) as a working agent,
    // bypassing the OSC reporter to test rendering directly. state=3 is the
    // generic/braille "working" spinner (the parser reads an integer `state`).
    try g.exec("rpcnotify(0, 'zonvie_agent_status', {'tab': 1, 'state': 3})");
    // Force a redraw so the dirty tabline re-emits with the indicator.
    try g.exec("execute('redraw!')");

    var img = try g.captureStable(.{ .w_pt = 900, .h_pt = 140 }, 8000);
    defer img.deinit(alloc);
    try capture.writeImage(alloc, "tmp/agent_status_actual.png", img);
    std.debug.print("[gui] wrote tmp/agent_status_actual.png ({d}x{d})\n", .{ img.w, img.h });
}
