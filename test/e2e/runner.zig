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

test "e2e:mousescroll_ver" {
    try requireNvim();
    try @import("scenarios/mousescroll_ver.zig").run(testing.allocator);
}

test "e2e:grid_scroll_abort_delivery" {
    try requireNvim();
    try @import("scenarios/grid_scroll_abort_delivery.zig").run(testing.allocator);
}

test "e2e:gesture_smoothscroll_borrow" {
    try requireNvim();
    try @import("scenarios/gesture_smoothscroll_borrow.zig").run(testing.allocator);
}

test "e2e:mousescroll_wrap_rows" {
    try requireNvim();
    try @import("scenarios/mousescroll_wrap_rows.zig").run(testing.allocator);
}

test "e2e:smoothscroll_viewport_delta" {
    try requireNvim();
    try @import("scenarios/smoothscroll_viewport_delta.zig").run(testing.allocator);
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

test "e2e:startup_error_surface" {
    try requireNvim();
    try @import("scenarios/startup_error_surface.zig").run(testing.allocator);
}

test "e2e:linespace_geometry_persist" {
    try requireNvim();
    try @import("scenarios/linespace_geometry_persist.zig").run(testing.allocator);
}

test "e2e:guifont_init_order" {
    try requireNvim();
    try @import("scenarios/guifont_init_order.zig").run(testing.allocator);
}

test "e2e:restart_preedit_cleanup" {
    try requireNvim();
    try @import("scenarios/restart_preedit_cleanup.zig").run(testing.allocator);
}

test "e2e:float_lifecycle" {
    try requireNvim();
    try @import("scenarios/float_lifecycle.zig").run(testing.allocator);
}

test "e2e:flush_order_correctness" {
    try requireNvim();
    try @import("scenarios/flush_order_correctness.zig").run(testing.allocator);
}

test "e2e:scrollbar_first_line" {
    try requireNvim();
    try @import("scenarios/scrollbar_first_line.zig").run(testing.allocator);
}

test "e2e:ligature_performance_baseline" {
    try requireNvim();
    try @import("scenarios/ligature_performance_baseline.zig").run(testing.allocator);
}

test "e2e:horizontal_scroll_alt_wheel" {
    try requireNvim();
    try @import("scenarios/horizontal_scroll_alt_wheel.zig").run(testing.allocator);
}

test "e2e:rendering_glitch_event_buffering" {
    try requireNvim();
    try @import("scenarios/rendering_glitch_event_buffering.zig").run(testing.allocator);
}

test "e2e:braille_emoji_rendering" {
    try requireNvim();
    try @import("scenarios/braille_emoji_rendering.zig").run(testing.allocator);
}

test "e2e:input_latency_performance" {
    try requireNvim();
    try @import("scenarios/input_latency_performance.zig").run(testing.allocator);
}

test "e2e:extmessage_window_bounds" {
    try requireNvim();
    try @import("scenarios/extmessage_window_bounds.zig").run(testing.allocator);
}

test "e2e:scroll_selection_artifacts" {
    try requireNvim();
    try @import("scenarios/scroll_selection_artifacts.zig").run(testing.allocator);
}

test "e2e:float_border_continuity" {
    try requireNvim();
    try @import("scenarios/float_border_continuity.zig").run(testing.allocator);
}

test "e2e:pmenusel_bounds" {
    try requireNvim();
    try @import("scenarios/pmenusel_bounds.zig").run(testing.allocator);
}

test "e2e:float_position_update_race" {
    try requireNvim();
    try @import("scenarios/float_position_update_race.zig").run(testing.allocator);
}

test "e2e:cursor_position_after_delete" {
    try requireNvim();
    try @import("scenarios/cursor_position_after_delete.zig").run(testing.allocator);
}

test "e2e:grid_resize_artifact" {
    try requireNvim();
    try @import("scenarios/grid_resize_artifact.zig").run(testing.allocator);
}

test "e2e:highlight_change_async" {
    try requireNvim();
    try @import("scenarios/highlight_change_async.zig").run(testing.allocator);
}

test "e2e:message_state_corruption" {
    try requireNvim();
    try @import("scenarios/message_state_corruption.zig").run(testing.allocator);
}

test "e2e:agent_status_notify" {
    try requireNvim();
    try @import("scenarios/agent_status_notify.zig").run(testing.allocator);
}

// ext_messages. These attach with ext_messages on and observe the message
// callbacks plus the real Neovim windows the split view creates.

test "e2e:msg_route_defaults" {
    try requireNvim();
    try @import("scenarios/msg_route_defaults.zig").run(testing.allocator);
}

test "e2e:msg_split_lifecycle" {
    try requireNvim();
    try @import("scenarios/msg_split_lifecycle.zig").run(testing.allocator);
}

test "e2e:msg_split_timeout" {
    try requireNvim();
    try @import("scenarios/msg_split_timeout.zig").run(testing.allocator);
}

test "e2e:msg_history_split" {
    try requireNvim();
    try @import("scenarios/msg_history_split.zig").run(testing.allocator);
}

test "e2e:msg_split_quit" {
    try requireNvim();
    try @import("scenarios/msg_split_quit.zig").run(testing.allocator);
}

test "e2e:msg_split_quit_other_tab" {
    try requireNvim();
    try @import("scenarios/msg_split_quit_other_tab.zig").run(testing.allocator);
}

test "e2e:msg_return_prompt" {
    try requireNvim();
    try @import("scenarios/msg_return_prompt.zig").run(testing.allocator);
}

test "e2e:msg_no_accumulation" {
    try requireNvim();
    try @import("scenarios/msg_no_accumulation.zig").run(testing.allocator);
}

test "e2e:msg_default_views" {
    try requireNvim();
    try @import("scenarios/msg_default_views.zig").run(testing.allocator);
}

test "e2e:msg_ext_float_timeout" {
    try requireNvim();
    try @import("scenarios/msg_ext_float_timeout.zig").run(testing.allocator);
}

test "e2e:msg_ext_float_width_shrink" {
    try requireNvim();
    try @import("scenarios/msg_ext_float_width_shrink.zig").run(testing.allocator);
}

test "e2e:msg_repeat_updates" {
    try requireNvim();
    try @import("scenarios/msg_repeat_updates.zig").run(testing.allocator);
}

test "e2e:msg_split_close_key" {
    try requireNvim();
    try @import("scenarios/msg_split_close_key.zig").run(testing.allocator);
}

test "e2e:msg_split_enter" {
    try requireNvim();
    try @import("scenarios/msg_split_enter.zig").run(testing.allocator);
}

test "e2e:msg_history_content" {
    try requireNvim();
    try @import("scenarios/msg_history_content.zig").run(testing.allocator);
}

test "e2e:msg_history_repeat" {
    try requireNvim();
    try @import("scenarios/msg_history_repeat.zig").run(testing.allocator);
}

test "e2e:msg_mini_then_split" {
    try requireNvim();
    try @import("scenarios/msg_mini_then_split.zig").run(testing.allocator);
}

test "e2e:msg_backoff_delivery" {
    try requireNvim();
    try @import("scenarios/msg_backoff_delivery.zig").run(testing.allocator);
}

test "e2e:msg_split_payload_ceiling" {
    try requireNvim();
    try @import("scenarios/msg_split_payload_ceiling.zig").run(testing.allocator);
}
