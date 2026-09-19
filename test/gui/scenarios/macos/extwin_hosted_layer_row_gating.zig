// extwin_hosted_layer_row_gating — a float hosted by an EXTERNAL window must
// not encode a row of itself more than once per frame.
//
// The design this came from assumed the external surface had no per-layer
// dirty set and therefore repainted every hosted row. Measuring said
// otherwise, and worse: it DOES restrict rows, per dirty band, but it built
// one band per dirty ROW and each band expands its layer row range by a row
// at both ends for ink crossing a cell boundary. Neighbouring bands then
// overlap. On an 8-row float over an external window with 8 dirty rows:
//
//     [ext_layer_draw] surface=4 gridId=5 rows=22 of=8
//
// 22 row draws for 8 rows — 2.75x what drawing every row once would cost. The
// fix is one band per RUN of contiguous dirty rows (a run's scissor is exactly
// the union of its rows' scissors, so the clipping is unchanged) plus sorting
// and deduplicating the dirty list unconditionally rather than only before a
// scroll copy. That took the same frame to rows=8.
//
// So the assertion is "no row is encoded twice", `rows <= of`. It fails on the
// unmodified surface with 22 > 8, which is what makes it a test rather than a
// description.
//
// `[ext_layer_draw]` deliberately is not the main surface's `[layer_draw]`:
// three scenarios parse that one by field name and would silently skip a
// line shaped differently. See logHostedLayerDraw's doc comment.
//
// macOS-only: ExternalGridView is macOS frontend code.

const std = @import("std");
const driver = @import("../../driver.zig");
const Gui = driver.Gui;
const app_log = @import("../../app_log.zig");
const gui_io = @import("../../gui_io.zig");

const log_path = "tmp/gui_extwin_hosted_layer_rows.log";

const ext_rows = 20;
const ext_cols = 60;
/// Tall enough that "every row" and "one row" are far apart: a 1-row float
/// would satisfy `rows == of` trivially and prove nothing.
const float_rows = 8;
const float_cols = 24;
/// The float's row that gets rewritten. Interior, so the change cannot be
/// confused with a border or an edge effect.
const dirty_row = 4;

const Tally = struct {
    lines: usize = 0,
    /// Frames that encoded MORE row draws than the layer has rows: the same
    /// row covered by two overlapping bands.
    over: usize = 0,
    max_of: f64 = 0,
    worst_rows: f64 = 0,
};

/// Fold `[ext_layer_draw]` for one hosted grid. Every field is required: a
/// line that failed to parse must not be counted as either arm, or the
/// assertion below stops meaning anything.
fn tally(alloc: std.mem.Allocator, surface: i64, since_ms: f64) !Tally {
    var marker_buf: [64]u8 = undefined;
    const marker = try std.fmt.bufPrint(
        &marker_buf,
        "[ext_layer_draw] surface={d} ",
        .{surface},
    );
    const lines = try app_log.linesSince(alloc, log_path, marker, since_ms);
    defer alloc.free(lines);

    var t = Tally{};
    var it = std.mem.splitScalar(u8, lines, '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        const rows = app_log.field(line, "rows") orelse continue;
        const of = app_log.field(line, "of") orelse continue;
        if (of <= 0) continue;
        t.lines += 1;
        if (of > t.max_of) t.max_of = of;
        if (rows > t.worst_rows) t.worst_rows = rows;
        if (rows > of) t.over += 1;
    }
    return t;
}

pub fn run(alloc: std.mem.Allocator) !void {
    std.Io.Dir.cwd().createDirPath(gui_io.io(), "tmp") catch {};
    std.Io.Dir.cwd().deleteFile(gui_io.io(), log_path) catch {};

    var g = try Gui.init(alloc, .{
        .app_args = &.{ "--log", log_path },
        .config_dir = "test/gui/fixtures/config_render_trace",
    });
    defer g.deinit();

    const base_windows = g.windowCount();

    // An external window, then a float anchored to it. `relative='win'` over
    // an external anchor is hosted by that surface as a layer — measured, not
    // assumed: the surface= field below is the proof.
    try g.exec(
        "luaeval('(function() vim.o.cursorline = false vim.o.number = false " ++
            "local b = vim.api.nvim_create_buf(false, true) local l = {} " ++
            "for i = 1, 400 do l[i] = string.format(\"%3d anchor line\", i) end " ++
            "vim.api.nvim_buf_set_lines(b, 0, -1, false, l) " ++
            "_G.z_ext = vim.api.nvim_open_win(b, true, {external=true, width=" ++
            std.fmt.comptimePrint("{d}", .{ext_cols}) ++ ", height=" ++
            std.fmt.comptimePrint("{d}", .{ext_rows}) ++ "}) return 1 end)()')",
    );
    try g.waitWindowCount(base_windows + 1, 10_000);

    try g.exec(
        "luaeval('(function() _G.z_fbuf = vim.api.nvim_create_buf(false, true) " ++
            "local l = {} for i = 1, " ++ std.fmt.comptimePrint("{d}", .{float_rows}) ++
            " do l[i] = string.rep(\"x\", " ++ std.fmt.comptimePrint("{d}", .{float_cols}) ++ ") end " ++
            "vim.api.nvim_buf_set_lines(_G.z_fbuf, 0, -1, false, l) " ++
            "_G.z_float = vim.api.nvim_open_win(_G.z_fbuf, false, {relative=\"win\", win=_G.z_ext, " ++
            "row=4, col=4, width=" ++ std.fmt.comptimePrint("{d}", .{float_cols}) ++
            ", height=" ++ std.fmt.comptimePrint("{d}", .{float_rows}) ++ ", style=\"minimal\"}) return 1 end)()')",
    );
    // Let the float seed itself. Its first frames legitimately draw every row.
    gui_io.sleepNs(1500 * std.time.ns_per_ms);

    const ext_grid: i64 = blk: {
        const line = (try app_log.lastLineSince(alloc, log_path, "[external_window] open gridId=", 0)) orelse
            return error.NoExternalWindowOpened;
        defer alloc.free(line);
        const v = app_log.field(line, "gridId") orelse return error.ExternalGridIdUnparsable;
        break :blk @intFromFloat(v);
    };

    const t0 = try app_log.nowMs(alloc, log_path);

    // One row of the float changes. Nothing else moves: no cursor, no scroll,
    // no resize.
    var i: usize = 0;
    while (i < 4) : (i += 1) {
        var expr_buf: [512]u8 = undefined;
        const expr = try std.fmt.bufPrint(
            &expr_buf,
            "luaeval('(function() vim.api.nvim_buf_set_lines(_G.z_fbuf, {d}, {d}, false, {{string.rep(\"{c}\", {d})}}) return 1 end)()')",
            .{ dirty_row, dirty_row + 1, @as(u8, 'a' + @as(u8, @intCast(i))), float_cols },
        );
        try g.exec(expr);
        gui_io.sleepNs(250 * std.time.ns_per_ms);
    }

    const t = try tally(alloc, ext_grid, t0);

    std.debug.print(
        "[gui] extwin hosted layer: surface={d} lines={d} over={d} worst_rows={d:.0} of={d:.0}\n",
        .{ ext_grid, t.lines, t.over, t.worst_rows, t.max_of },
    );

    // Gate one: the float is hosted by THIS surface as a layer. Without a
    // line there is nothing to measure and every count below reads zero for a
    // reason that is not the behaviour.
    if (t.lines == 0) {
        std.debug.print("[gui] the external surface drew no hosted layer at all\n", .{});
        return error.NoHostedLayerDrawn;
    }
    // Gate two: the layer is tall enough for "all rows" to differ from "one".
    if (t.max_of < 2) {
        std.debug.print("[gui] the hosted layer has {d:.0} rows; nothing to gate\n", .{t.max_of});
        return error.HostedLayerTooShort;
    }

    // No row encoded twice. Overlapping bands are the only thing that can
    // push the count past the layer's own row total.
    if (t.over != 0) {
        std.debug.print(
            "[gui] {d} of {d} hosted-layer draws encoded more rows than the layer has " ++
                "(worst {d:.0} of {d:.0}) — dirty bands are overlapping again\n",
            .{ t.over, t.lines, t.worst_rows, t.max_of },
        );
        return error.HostedLayerRowsEncodedTwice;
    }
}
