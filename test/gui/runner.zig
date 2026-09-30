// runner.zig — entrypoint for `zig build gui-test` (macOS and Windows hosts).
//
// Launches the REAL zonvie app: windows will appear on the current
// desktop while tests run. Skips cleanly when the app build or nvim is
// missing, unless ZONVIE_GUI_REQUIRE is set (the Windows CI job).

const std = @import("std");
const builtin = @import("builtin");
const driver = @import("driver.zig");
const testing = std.testing;

/// CI sets ZONVIE_GUI_REQUIRE so a runner without nvim or the app fails
/// instead of passing with nothing tested.
fn missingPrereq() error{ SkipZigTest, GuiPrereqMissing } {
    if (std.process.Environ.getAlloc(testing.environ, testing.allocator, "ZONVIE_GUI_REQUIRE")) |required| {
        testing.allocator.free(required);
        std.debug.print("[gui] ZONVIE_GUI_REQUIRE is set: failing\n", .{});
        return error.GuiPrereqMissing;
    } else |_| {}
    std.debug.print("[gui] skipped\n", .{});
    return error.SkipZigTest;
}

fn requirePrereqs() !void {
    const nvim = driver.resolveNvim(testing.allocator) catch |e| switch (e) {
        error.NvimNotFound => {
            std.debug.print("[gui] nvim not found (set ZONVIE_TEST_NVIM)\n", .{});
            return missingPrereq();
        },
        else => return e,
    };
    testing.allocator.free(nvim);
    const app = driver.resolveApp(testing.allocator) catch |e| switch (e) {
        error.AppNotFound => {
            std.debug.print(
                "[gui] zonvie app not built at {s} (set ZONVIE_TEST_APP or build it first)\n",
                .{driver.default_app_rel_path},
            );
            return missingPrereq();
        },
        else => return e,
    };
    testing.allocator.free(app);
}

// Scenarios are grouped by platform applicability:
//   common/  — run on every host (behavior-level, driven via nvim RPC)
//   macos/   — macOS-only behavior
//   windows/ — Windows-only behavior
// Platform-specific tests gate the @import behind a comptime check (see
// gated) so the host that cannot run them never analyzes their
// platform-only code.

const is_macos = builtin.os.tag == .macos;
const is_windows = builtin.os.tag == .windows;
const can_capture = driver.capture.supported;

/// Run scenario `M` when the comptime gate `ok` holds, else skip. `M.run` is
/// referenced only in the taken branch, so a host that fails the gate never
/// analyzes it.
fn gated(comptime ok: bool, comptime M: type) !void {
    if (ok) {
        try requirePrereqs();
        try M.run(testing.allocator);
    } else {
        return error.SkipZigTest;
    }
}

test "gui:cmdline_window" {
    try gated(true, @import("scenarios/common/cmdline_window.zig"));
}

test "gui:external_window" {
    try gated(true, @import("scenarios/common/external_window.zig"));
}

test "gui:render_trace" {
    try gated(true, @import("scenarios/common/render_trace.zig"));
}

test "gui:set_columns_lines" {
    try gated(true, @import("scenarios/common/set_columns_lines.zig"));
}

test "gui:window_frame_stability" {
    // macOS only: the Windows frontend does not persist the main window
    // frame across launches, so the 44705f8 regression cannot occur there.
    try gated(is_macos, @import("scenarios/macos/window_frame_stability.zig"));
}

test "gui:mini_message_position" {
    // macOS only: exercises the macOS frontend's mini-popup anchoring
    // (updateMiniPositions); the Windows frontend has its own message UI.
    try gated(is_macos, @import("scenarios/macos/mini_message_position.zig"));
}

test "gui:mini_message_bulk" {
    // macOS only: exercises the macOS frontend's mini line bound
    // (clampMiniContent / miniWindowSize).
    try gated(is_macos, @import("scenarios/macos/mini_message_bulk.zig"));
}

test "gui:extfloat_margin_scroll_flicker" {
    // macOS only: the external-window smooth-scroll path is macOS frontend.
    try gated(is_macos, @import("scenarios/macos/extfloat_margin_scroll_flicker.zig"));
}

test "gui:main_margin_scroll_flicker" {
    // macOS only: drives the macOS frontend's main-window smooth-scroll path.
    try gated(is_macos, @import("scenarios/macos/main_margin_scroll_flicker.zig"));
}

test "gui:float_stack_scroll_continuity" {
    // macOS only: it drives real trackpad pixel gestures, which Windows has
    // no equivalent for (its wheel synthesis is notch-only, so there is no
    // sub-cell ease to be discontinuous within).
    try gated(is_macos, @import("scenarios/macos/float_stack_scroll_continuity.zig"));
}

test "gui:main_float_margin_scroll_flicker" {
    // macOS only: a bordered float composited into the main window is the
    // one configuration with a real BOTTOM margin row there.
    try gated(is_macos, @import("scenarios/macos/main_float_margin_scroll_flicker.zig"));
}

test "gui:extwin_keyboard_scroll_eases" {
    // macOS only: the external-window smooth-scroll path is macOS frontend.
    try gated(is_macos, @import("scenarios/macos/extwin_keyboard_scroll_eases.zig"));
}

test "gui:extwin_trackpad_cursor_shader_tracks" {
    // macOS only: the shader cursor plumbing is macOS frontend.
    try gated(is_macos, @import("scenarios/macos/extwin_trackpad_cursor_shader_tracks.zig"));
}

test "gui:extwin_scroll_cursor_shader_stays" {
    // macOS only: the shader cursor plumbing is macOS frontend.
    try gated(is_macos, @import("scenarios/macos/extwin_scroll_cursor_shader_stays.zig"));
}

test "gui:extfloat_move_cursor_shader" {
    // macOS only: the shader cursor plumbing lives in the macOS frontend.
    try gated(is_macos, @import("scenarios/macos/extfloat_move_cursor_shader.zig"));
}

test "gui:extfloat_resize_shader_stall" {
    // macOS only: the animated-shader draw loop and the external-float
    // window plumbing this exercises live in the macOS frontend.
    try gated(is_macos, @import("scenarios/macos/extfloat_resize_shader_stall.zig"));
}

test "gui:extfloat_message_position" {
    // macOS only: exercises the macOS frontend's ext-float anchoring
    // (getExtFloatTargetFrame); the Windows frontend has its own message UI.
    try gated(is_macos, @import("scenarios/macos/extfloat_message_position.zig"));
}

test "gui:wheel_scroll" {
    // Windows only: synthesizes WM_MOUSEWHEEL into the real frontend wheel
    // handler (7b37537). No macOS equivalent in this driver.
    try gated(is_windows, @import("scenarios/windows/wheel_scroll.zig"));
}

// Visual scenarios run wherever the screenshot layer is implemented.

test "gui:visual_baseline" {
    try gated(can_capture, @import("scenarios/visual/baseline.zig"));
}

test "gui:visual_agent_status" {
    try gated(can_capture, @import("scenarios/visual/agent_status.zig"));
}

test "gui:visual_split" {
    try gated(can_capture, @import("scenarios/visual/split.zig"));
}

test "gui:visual_split_divider_survives_layer_redraw" {
    try gated(can_capture, @import("scenarios/visual/split_divider_survives_layer_redraw.zig"));
}

test "gui:visual_statusline_survives_layer_redraw" {
    try gated(can_capture, @import("scenarios/visual/statusline_survives_layer_redraw.zig"));
}

test "gui:visual_float" {
    try gated(can_capture, @import("scenarios/visual/float.zig"));
}

test "gui:visual_main_float_cursor_moves" {
    try gated(can_capture, @import("scenarios/visual/main_float_cursor_moves.zig"));
}

test "gui:visual_emoji_cursor_width" {
    try gated(can_capture, @import("scenarios/visual/emoji_cursor_width.zig"));
}

test "gui:visual_emoji_cluster_cache" {
    try gated(can_capture, @import("scenarios/visual/emoji_cluster_cache.zig"));
}

test "gui:visual_float_border_continuity" {
    try gated(can_capture, @import("scenarios/visual/float_border_continuity.zig"));
}

test "gui:visual_pmenusel_bounds" {
    try gated(can_capture, @import("scenarios/visual/pmenusel_bounds.zig"));
}

test "gui:visual_vertical_cursor_width" {
    try gated(can_capture, @import("scenarios/visual/vertical_cursor_width.zig"));
}

test "gui:visual_cmdline_cursor_animation" {
    try gated(can_capture, @import("scenarios/visual/cmdline_cursor_animation.zig"));
}

test "gui:visual_continuous_j_scroll_matches_jump" {
    // macOS only: counts the macOS frontend's [layer_row_scroll] line.
    try gated(is_macos, @import("scenarios/visual/continuous_j_scroll_matches_jump.zig"));
}

test "gui:visual_extwin_continuous_j_scroll_matches_jump" {
    // macOS only: it drives the macOS external-window surface and reads that
    // frontend's [ext_applyRowScroll] line.
    try gated(is_macos, @import("scenarios/visual/extwin_continuous_j_scroll_matches_jump.zig"));
}

test "gui:visual_incremental_scroll_matches_jump" {
    try gated(can_capture, @import("scenarios/visual/incremental_scroll_matches_jump.zig"));
}

test "gui:visual_scroll_then_cursor_move" {
    try gated(can_capture, @import("scenarios/visual/scroll_then_cursor_move.zig"));
}

test "gui:visual_scrolled_layer_row_gating" {
    try gated(can_capture, @import("scenarios/visual/scrolled_layer_row_gating.zig"));
}

test "gui:visual_float_over_scrolled_split" {
    try gated(can_capture, @import("scenarios/visual/float_over_scrolled_split.zig"));
}

test "gui:visual_extfloat_over_scrolled_anchor" {
    // macOS only: enumerates the app's OS windows to find the external one
    // and captures that window rather than the main one.
    try gated(is_macos, @import("scenarios/visual/extfloat_over_scrolled_anchor.zig"));
}

test "gui:visual_extfloat_opaque_partial" {
    if (comptime builtin.os.tag == .macos) {
        try requirePrereqs();
        try @import("scenarios/visual/extfloat_over_scrolled_anchor.zig").runOpaque(testing.allocator);
    } else return error.SkipZigTest;
}

test "gui:visual_extfloat_over_born_external_anchor" {
    // macOS only: enumerates the app's OS windows to find the external one
    // and captures that window rather than the main one.
    try gated(is_macos, @import("scenarios/visual/extfloat_over_born_external_anchor.zig"));
}

test "gui:visual_scrollbind_layers_blit_matches_jump" {
    try gated(can_capture, @import("scenarios/visual/scrollbind_layers_blit_matches_jump.zig"));
}

test "gui:visual_proportional_font_support" {
    try gated(can_capture, @import("scenarios/visual/proportional_font_support.zig"));
}

test "gui:visual_shader_covers_all_grids" {
    // macOS only: reads the macOS frontend's [resizeExternalWindows] line.
    try gated(is_macos, @import("scenarios/visual/shader_covers_all_grids.zig"));
}

test "gui:cmdline_cursor_shader_rect" {
    // macOS only: the shader cursor plumbing and the window enumeration this
    // uses live in the macOS frontend and macos_window.zig.
    try gated(is_macos, @import("scenarios/macos/cmdline_cursor_shader_rect.zig"));
}

test "gui:extfloat_hosted_cursor_shader_rect" {
    // macOS only: the shader cursor plumbing and the window enumeration this
    // uses live in the macOS frontend and macos_window.zig.
    try gated(is_macos, @import("scenarios/macos/extfloat_hosted_cursor_shader_rect.zig"));
}

test "gui:extwin_shader_preserves_alpha" {
    // macOS only: the two-variant custom shader chain (decorated vs editor)
    // exists in the macOS frontend.
    try gated(is_macos, @import("scenarios/macos/extwin_shader_preserves_alpha.zig"));
}

test "gui:visual_decorated_surface_background_alpha" {
    // macOS only: enumerates the app's OS windows to find the ext-cmdline
    // one and screenshots the desktop composite under it.
    try gated(is_macos, @import("scenarios/visual/decorated_surface_background_alpha.zig"));
}

test "gui:extwin_float_trackpad_scroll" {
    // macOS only: ExternalGridView's scroll path and the window enumeration
    // this uses live in the macOS frontend and macos_window.zig.
    try gated(is_macos, @import("scenarios/macos/extwin_float_trackpad_scroll.zig"));
}

test "gui:mini_message_hosted_float_anchor" {
    // macOS only: the external window and its compositing are macOS frontend.
    try gated(is_macos, @import("scenarios/macos/mini_message_hosted_float_anchor.zig"));
}

test "gui:scrollbar_follows_own_surface" {
    // macOS only: ExternalGridView and the window enumeration are macOS
    // frontend code.
    try gated(is_macos, @import("scenarios/macos/scrollbar_follows_own_surface.zig"));
}

test "gui:extwin_float_stack_scroll_continuity" {
    // macOS only: ExternalGridView hosts the layer and the trackpad gesture
    // is driven through macos_window.zig.
    try gated(is_macos, @import("scenarios/macos/extwin_float_stack_scroll_continuity.zig"));
}

test "gui:extwin_hosted_float_phantom_hit" {
    // macOS only: the main window's hit test and ExternalGridView are macOS
    // frontend code.
    try gated(is_macos, @import("scenarios/macos/extwin_hosted_float_phantom_hit.zig"));
}

test "gui:extwin_cursor_move_reuses_rows" {
    // macOS only: ExternalGridView is macOS frontend code.
    try gated(is_macos, @import("scenarios/macos/extwin_cursor_move_reuses_rows.zig"));
}

test "gui:extwin_hosted_layer_row_gating" {
    // macOS only: ExternalGridView is macOS frontend code.
    try gated(is_macos, @import("scenarios/macos/extwin_hosted_layer_row_gating.zig"));
}

test "gui:extwin_blink_without_cursor_skips" {
    // macOS only: ExternalGridView is macOS frontend code.
    try gated(is_macos, @import("scenarios/macos/extwin_blink_without_cursor_skips.zig"));
}

test "gui:visual_extwin_split_with_float_background" {
    // macOS only: it enumerates the app's OS windows to capture the external
    // one.
    try gated(is_macos and can_capture, @import("scenarios/visual/extwin_split_with_float_background.zig"));
}

test "gui:visual_extwin_winhighlight_hosted_float_colors" {
    // macOS only: it enumerates the app's OS windows to capture the external
    // one.
    try gated(is_macos and can_capture, @import("scenarios/visual/extwin_winhighlight_hosted_float_colors.zig"));
}

test "gui:visual_hosted_float_scroll_band" {
    // macOS only: it drives a trackpad gesture and enumerates the app's
    // windows to capture the external one.
    try gated(is_macos and can_capture, @import("scenarios/visual/hosted_float_scroll_band.zig"));
}

test "gui:visual_extwin_hosted_layer_glow" {
    // macOS only: it enumerates the app's OS windows and captures a
    // non-main one, and the bloom path under test is macOS frontend code.
    try gated(is_macos and can_capture, @import("scenarios/visual/extwin_hosted_layer_glow.zig"));
}

test "gui:main_float_mouse_disabled_scroll" {
    // macOS only: it drives a real trackpad gesture and tests the macOS
    // frontend's own hit test.
    try gated(is_macos, @import("scenarios/macos/main_float_mouse_disabled_scroll.zig"));
}

test "gui:hidden_main_parks_draw_loop" {
    // macOS only: GridSurfaceRenderer is macOS frontend code.
    try gated(is_macos, @import("scenarios/macos/hidden_main_parks_draw_loop.zig"));
}

test "gui:blink_survives_popupmenu" {
    // macOS only: the blink gate is ZonvieCore's.
    try gated(is_macos, @import("scenarios/macos/blink_survives_popupmenu.zig"));
}

test "gui:extwin_animated_shader_reuses_rows" {
    // macOS only: ExternalGridView is macOS frontend code.
    try gated(is_macos, @import("scenarios/macos/extwin_animated_shader_reuses_rows.zig"));
}

test "gui:main_idle_while_extwin_updates" {
    // macOS only: GridSurfaceRenderer is macOS frontend code.
    try gated(is_macos, @import("scenarios/macos/main_idle_while_extwin_updates.zig"));
}

test "gui:main_cursor_move_reuses_rows" {
    // macOS only: GridSurfaceRenderer is macOS frontend code.
    try gated(is_macos, @import("scenarios/macos/main_cursor_move_reuses_rows.zig"));
}

test "gui:extwin_float_follows_externalized_anchor" {
    // macOS only: external windows and their surface plumbing are frontend code.
    try gated(is_macos, @import("scenarios/macos/extwin_float_follows_externalized_anchor.zig"));
}

test "gui:extwin_float_wheel_scroll" {
    // Windows only: the external-window wheel path and the HWND-addressed
    // notch this uses live in the Windows frontend and windows_window.zig.
    try gated(is_windows, @import("scenarios/windows/extwin_float_wheel_scroll.zig"));
}
