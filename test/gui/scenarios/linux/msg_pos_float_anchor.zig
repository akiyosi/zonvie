// msg_pos_float_anchor — Linux counterpart of mini_message_position and
// extfloat_message_position: with msg_pos = "grid" and the cursor in an
// editor-anchored float, a mini (search count) hangs from the editor's
// bottom-right and an ext-float message (an error) from its top-right, not
// from the float's corners. Linux draws both inside the main window, so the
// harness reads their places from the log instead of from new OS windows.
//
// Linux-only: linux/ui_widgets.zig placeMessages and the overlay panels.

const std = @import("std");
const driver = @import("../../driver.zig");
const Gui = driver.Gui;
const app_log = @import("../../app_log.zig");
const gui_io = @import("../../gui_io.zig");

const log_path = "tmp/gui_msg_pos_float_anchor.log";

pub fn run(alloc: std.mem.Allocator) !void {
    std.Io.Dir.cwd().createDirPath(gui_io.io(), "tmp") catch {};
    std.Io.Dir.cwd().deleteFile(gui_io.io(), log_path) catch {};
    var g = try Gui.init(alloc, .{
        .app_args = &.{ "--extmessages", "--log", log_path },
        .config_dir = "test/gui/fixtures/config_msgpos_grid",
    });
    defer g.deinit();
    g.activateApp();
    try app_log.waitFramesAfter(alloc, log_path, 1, 1, 0, 10_000);

    // An editor-anchored float under the cursor, 30 columns wide at column 3:
    // its right edge is far from the editor's.
    try g.exec(
        "luaeval('(function() local b = vim.api.nvim_create_buf(false, true) " ++
            "vim.api.nvim_buf_set_lines(b, 0, -1, true, {\"alpha zonvie beta\", \"gamma zonvie delta\"}) " ++
            "vim.api.nvim_open_win(b, true, {relative=\"editor\", row=3, col=3, width=30, height=5}) " ++
            "return 1 end)()')",
    );
    gui_io.sleepNs(300 * std.time.ns_per_ms);
    const cell_line = (try app_log.lastLineSince(alloc, log_path, "[cell_metrics]", 0)) orelse return error.NoCellMetrics;
    defer alloc.free(cell_line);
    const cell_w = app_log.field(cell_line, "cellW") orelse return error.NoCellMetrics;

    // search_count goes to the mini view. Its place is logged on a change
    // only: hanging from the editor it keeps the place it had before the
    // float, so the last line is the answer either way.
    try g.remoteSend("/zonvie<CR>");
    gui_io.sleepNs(600 * std.time.ns_per_ms);
    const mini = (try app_log.lastLineSince(alloc, log_path, "[mini_pos]", 0)) orelse return error.NoMiniPlace;
    defer alloc.free(mini);
    const mini_end = app_log.field(mini, "end").?;

    // An error goes to the ext-float view: the msg_show panel.
    const t_err = try app_log.nowMs(alloc, log_path);
    try g.remoteSend(":echoerr 'zonvie anchor check'<CR>");
    try app_log.waitForSince(alloc, log_path, "[overlay] msg_show", t_err, 5000);
    const panel = (try app_log.lastLineSince(alloc, log_path, "[overlay] msg_show", t_err)).?;
    defer alloc.free(panel);
    const right = app_log.field(panel, "x").? + app_log.field(panel, "w").?;
    const top = app_log.field(panel, "y").?;
    // The float's right edge in px: its border and 30 columns from column 3.
    const float_right = (3 + 30 + 2) * cell_w;

    std.debug.print("[gui] mini end margin={d} panel right={d} top={d} float right={d}\n", .{ mini_end, right, top, float_right });
    // Hanging from the editor, the mini sits within a cell (plus the 10 px
    // margin) of the view's right edge; from the float it would be far in.
    if (mini_end > 10 + cell_w) return error.MiniAnchoredToFloat;
    if (right < float_right + 10 * cell_w) return error.ExtFloatAnchoredToFloat;
}
