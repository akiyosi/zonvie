// runner.zig — entrypoint for `zig build e2e`.
//
// Each scenario spawns its own `nvim --embed --clean` for isolation.
// When no usable nvim binary is found, every test skips with a clear
// message instead of failing (CI machines without nvim stay green).

const std = @import("std");
const harness = @import("harness.zig");
const testing = std.testing;

fn requireNvim() !void {
    const path = harness.resolveNvim(testing.allocator) catch |e| switch (e) {
        error.NvimNotFound => {
            std.debug.print("[e2e] skipped: nvim not found (set ZONVIE_TEST_NVIM)\n", .{});
            return error.SkipZigTest;
        },
        else => return e,
    };
    testing.allocator.free(path);
}

test "e2e:insert_basic" {
    try requireNvim();
    try @import("scenarios/insert_basic.zig").run(testing.allocator);
}

test "e2e:edit_dd" {
    try requireNvim();
    try @import("scenarios/edit_dd.zig").run(testing.allocator);
}

test "e2e:scroll" {
    try requireNvim();
    try @import("scenarios/scroll.zig").run(testing.allocator);
}

test "e2e:float_window" {
    try requireNvim();
    try @import("scenarios/float_window.zig").run(testing.allocator);
}

test "e2e:multigrid_resize" {
    try requireNvim();
    try @import("scenarios/multigrid_resize.zig").run(testing.allocator);
}

test "e2e:wide_chars" {
    try requireNvim();
    try @import("scenarios/wide_chars.zig").run(testing.allocator);
}

test "e2e:highlight_change" {
    try requireNvim();
    try @import("scenarios/highlight_change.zig").run(testing.allocator);
}

test "e2e:external_window_cursor" {
    try requireNvim();
    try @import("scenarios/external_window_cursor.zig").run(testing.allocator);
}

test "e2e:float_move_recompose" {
    try requireNvim();
    try @import("scenarios/float_move_recompose.zig").run(testing.allocator);
}

test "e2e:ime_preedit_extmark" {
    try requireNvim();
    try @import("scenarios/ime_preedit_extmark.zig").run(testing.allocator);
}

test "e2e:search_highlight" {
    try requireNvim();
    try @import("scenarios/search_highlight.zig").run(testing.allocator);
}

test "e2e:cursorline" {
    try requireNvim();
    try @import("scenarios/cursorline.zig").run(testing.allocator);
}

test "e2e:visual_selection" {
    try requireNvim();
    try @import("scenarios/visual_selection.zig").run(testing.allocator);
}

test "e2e:undo_redo" {
    try requireNvim();
    try @import("scenarios/undo_redo.zig").run(testing.allocator);
}

test "e2e:substitute" {
    try requireNvim();
    try @import("scenarios/substitute.zig").run(testing.allocator);
}

test "e2e:tab_switch" {
    try requireNvim();
    try @import("scenarios/tab_switch.zig").run(testing.allocator);
}

test "e2e:goto_line" {
    try requireNvim();
    try @import("scenarios/goto_line.zig").run(testing.allocator);
}

test "e2e:copy_paste_yank" {
    try requireNvim();
    try @import("scenarios/copy_paste_yank.zig").run(testing.allocator);
}

test "e2e:marks_navigate" {
    try requireNvim();
    try @import("scenarios/marks_navigate.zig").run(testing.allocator);
}

test "e2e:word_boundary_motion" {
    try requireNvim();
    try @import("scenarios/word_boundary_motion.zig").run(testing.allocator);
}
