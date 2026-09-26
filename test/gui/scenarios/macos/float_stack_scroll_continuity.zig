// float_stack_scroll_continuity — a stack of buffer-anchored floats over a
// window being pixel-scrolled must travel, not teleport.
//
// Two defects this pins, both of which only ever showed up as "the floats
// look wrong while I scroll" and neither of which any existing test could
// see:
//
//   1. Each layer was scissored to its committed rectangle while the vertex
//      stage displaced it bodily, so the leading band of every float was cut
//      off for the whole ease. Floats are drawn at a shifted origin now
//      (displacedLayerOriginPx), which is what keeps clip and geometry in one
//      space.
//   2. A float's placement (win_float_pos) and its anchor's landing
//      compensation reach the frontend on different frames, so for one frame
//      the float carried a compensation for a step it had not taken and was
//      drawn a whole 'mousescroll' step away. The debt ledger withholds that
//      part until the float's own placement arrives.
//
// Both are failures of the SAME property: the drawn Y of a float must move
// by less than a cell between consecutive frames, because a smooth scroll is
// sub-cell motion by construction. That is what this asserts, from the app's
// own [layer_draw] log line — pixels cannot serve here, since the floats
// legitimately move and a golden would have to encode the ease itself.
//
// `bufpos` is what makes the floats follow: Neovim recomputes a bufpos float's
// position as the window scrolls, which is also what sets the core's
// follows_scroll and puts the float on the path under test. A float that is
// never repositioned is a fixed overlay and is correctly left alone, so the
// anti-vacuity gate below insists the placements really did move.
//
// macOS-only: it drives real trackpad pixel gestures.

const std = @import("std");
const driver = @import("../../driver.zig");
const platform = driver.platform;
const Gui = driver.Gui;
const app_log = @import("../../app_log.zig");
const gui_io = @import("../../gui_io.zig");
const layer_draw = @import("layer_draw.zig");

const log_path = "tmp/gui_float_stack_scroll_continuity.log";
const draw_marker = "[layer_draw]";
const scroll_marker = "[renderer] scroll offset:";

const float_count = 6;
/// Buffer lines the floats anchor to, three rows apart so they stack edge to
/// edge the way diagnostic floats do — the arrangement under which a widened
/// scissor reached its neighbour.
const float_stride_lines = 3;
const float_first_line = 4;
const float_rows = 2;
const float_cols = 30;

const step_px: f64 = -6;
const steps_per_gesture: u32 = 8;
const gestures: u32 = 6;
const max_windows = 16;

/// Violations tolerated before the run is called a failure. A frame can be
/// missed or doubled by the capture clock, and the established convention in
/// this directory is a small threshold rather than zero (see
/// main_float_margin_scroll_flicker's margin_hit_threshold).
const jump_threshold: usize = 2;

/// Cell height in pixels, from the app's own scroll-offset line: cellNDC is
/// two units per viewport, so cellPx = cellNDC * vpH / 2. Read rather than
/// assumed, because it depends on the font the host happens to resolve.
fn cellHeightPx(alloc: std.mem.Allocator, since_ms: f64) !f64 {
    const line = (try app_log.lastLineSince(alloc, log_path, scroll_marker, since_ms)) orelse
        return error.NoScrollOffsetLogged;
    defer alloc.free(line);
    const cell_ndc = app_log.field(line, "cellNDC") orelse return error.ScrollOffsetUnparsable;
    const vp_h = app_log.field(line, "vpH") orelse return error.ScrollOffsetUnparsable;
    if (cell_ndc <= 0 or vp_h <= 0) return error.ScrollOffsetUnparsable;
    return cell_ndc * vp_h / 2;
}

pub fn run(alloc: std.mem.Allocator) !void {
    if (!platform.accessibilityTrusted()) {
        std.debug.print(
            "[gui] skipped: not trusted for Accessibility, so scroll gestures cannot target the window.\n",
            .{},
        );
        return error.SkipZigTest;
    }

    std.Io.Dir.cwd().createDirPath(gui_io.io(), "tmp") catch {};
    std.Io.Dir.cwd().deleteFile(gui_io.io(), log_path) catch {};

    var g = try Gui.init(alloc, .{
        .app_args = &.{ "--log", log_path },
        .config_dir = "test/gui/fixtures/config_static_shader",
    });
    defer g.deinit();
    g.activateApp();

    // A long buffer in the main window, then a stack of bufpos-anchored
    // floats over it. They are unfocused so the wheel scrolls the buffer
    // underneath rather than a float's own contents.
    try g.exec(
        "luaeval('(function() " ++
            "local lines = {} for i = 1, 800 do lines[i] = string.rep(\"line \" .. i .. \" \", 8) end " ++
            "vim.api.nvim_buf_set_lines(0, 0, -1, true, lines) " ++
            "local w = vim.api.nvim_get_current_win() " ++
            "_G.e2e_floats = {} " ++
            "for k = 0, " ++ std.fmt.comptimePrint("{d}", .{float_count - 1}) ++ " do " ++
            "local b = vim.api.nvim_create_buf(false, true) " ++
            "vim.api.nvim_buf_set_lines(b, 0, -1, true, {\"float \" .. k, \"anchored\"}) " ++
            "_G.e2e_floats[k + 1] = vim.api.nvim_open_win(b, false, " ++
            "{relative=\"win\", win=w, bufpos={" ++ std.fmt.comptimePrint("{d}", .{float_first_line}) ++
            " + k * " ++ std.fmt.comptimePrint("{d}", .{float_stride_lines}) ++ ", 0}, " ++
            "row=0, col=2, width=" ++ std.fmt.comptimePrint("{d}", .{float_cols}) ++
            ", height=" ++ std.fmt.comptimePrint("{d}", .{float_rows}) ++
            ", focusable=false, zindex=50, style=\"minimal\"}) end " ++
            "return 1 end)()')",
    );
    gui_io.sleepNs(800 * std.time.ns_per_ms);

    const open_floats = try g.evalInt("luaeval('#_G.e2e_floats')");
    if (open_floats != float_count) {
        std.debug.print("[gui] opened {d} floats, expected {d}\n", .{ open_floats, float_count });
        return error.FloatsNotOpen;
    }

    var win_buf: [max_windows]platform.MainWindow = undefined;
    const wins = win_buf[0..platform.windowsForPid(g.app_pid, &win_buf)];
    var main_win: ?platform.MainWindow = null;
    for (wins) |w| {
        if (w.bounds.w >= 150 and w.bounds.h >= 150) {
            main_win = w;
            break;
        }
    }
    const window = main_win orelse return error.MainWindowNotFound;

    const t0 = try app_log.nowMs(alloc, log_path);

    // An arming nudge, so the app logs a scroll-offset line to take the cell
    // height from before the measured gestures start.
    if (!platform.scrollBegin(g.app_pid, window)) return error.ScrollRefused;
    platform.scrollStep(step_px);
    gui_io.sleepNs(16 * std.time.ns_per_ms);
    platform.scrollEnd();

    var cell_px: f64 = 0;
    var tries: u32 = 0;
    while (tries < 50) : (tries += 1) {
        if (cellHeightPx(alloc, t0)) |c| {
            cell_px = c;
            break;
        } else |_| {}
        gui_io.sleepNs(100 * std.time.ns_per_ms);
    }
    if (cell_px <= 0) return error.NoScrollOffsetLogged;
    gui_io.sleepNs(700 * std.time.ns_per_ms);

    // Measure from here: the arming nudge's own ease is finished.
    const t1 = try app_log.nowMs(alloc, log_path);

    var gesture: u32 = 0;
    while (gesture < gestures) : (gesture += 1) {
        // Alternate direction. A reversal mid-ease was the case that broke an
        // earlier attempt at this fix, so it belongs in the exercise.
        const dir: f64 = if (gesture % 2 == 0) 1 else -1;
        if (!platform.scrollBegin(g.app_pid, window)) return error.ScrollRefused;
        var n: u32 = 0;
        while (n < steps_per_gesture) : (n += 1) {
            platform.scrollStep(step_px * dir);
            gui_io.sleepNs(16 * std.time.ns_per_ms);
        }
        platform.scrollEnd();
        gui_io.sleepNs(500 * std.time.ns_per_ms);
    }

    const t = try layer_draw.tally(alloc, log_path, draw_marker, t1, cell_px);
    std.debug.print(
        "[gui] float stack: cell={d:.1}px period={d:.1}ms displaced_frames={d} late={d} grids={d} replacements={d} jumps={d} worst={d:.1}px\n",
        .{ cell_px, t.period_ms, t.displaced, t.late, t.grids, t.replacements, t.jumps, t.worst },
    );

    // Anti-vacuity gates. Each one names a way this scenario could pass while
    // proving nothing, and every one of them has to hold before the jump
    // count means anything.
    if (t.period_ms <= 0) {
        std.debug.print("[gui] no frame period could be measured — nothing was drawn\n", .{});
        return error.TooFewDisplacedFrames;
    }
    if (t.displaced < 60) {
        std.debug.print("[gui] too few displaced frames — the ease never ran\n", .{});
        return error.TooFewDisplacedFrames;
    }
    if (t.grids < 2) {
        std.debug.print("[gui] fewer than two floats were displaced — not a stack\n", .{});
        return error.FloatStackNotDisplaced;
    }
    if (t.replacements < 2) {
        std.debug.print("[gui] Neovim never re-placed a float — bufpos anchoring is not live, " ++
            "so the split-step path is untested\n", .{});
        return error.FloatsNeverReplaced;
    }

    if (t.jumps > jump_threshold) {
        std.debug.print(
            "[gui] a float's drawn Y jumped a whole cell {d} times within one frame period " ++
                "(worst {d:.1}px, cell {d:.1}px, period {d:.1}ms)\n",
            .{ t.jumps, t.worst, cell_px, t.period_ms },
        );
        return error.FloatPositionDiscontinuous;
    }
}
