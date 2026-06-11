// runner.zig — entrypoint for `zig build gui-test` (macOS and Windows hosts).
//
// Launches the REAL zonvie app: windows will appear on the current
// desktop while tests run. Local-only; skips cleanly when the app build
// or nvim is missing.

const std = @import("std");
const builtin = @import("builtin");
const driver = @import("driver.zig");
const testing = std.testing;

fn requirePrereqs() !void {
    const nvim = driver.resolveNvim(testing.allocator) catch |e| switch (e) {
        error.NvimNotFound => {
            std.debug.print("[gui] skipped: nvim not found (set ZONVIE_TEST_NVIM)\n", .{});
            return error.SkipZigTest;
        },
        else => return e,
    };
    testing.allocator.free(nvim);
    const app = driver.resolveApp(testing.allocator) catch |e| switch (e) {
        error.AppNotFound => {
            std.debug.print(
                "[gui] skipped: zonvie app not built at {s} (set ZONVIE_TEST_APP or build it first)\n",
                .{driver.default_app_rel_path},
            );
            return error.SkipZigTest;
        },
        else => return e,
    };
    testing.allocator.free(app);
}

// Scenarios are grouped by platform applicability:
//   common/  — run on every host (behavior-level, driven via nvim RPC)
//   macos/   — macOS-only behavior
//   windows/ — Windows-only behavior
// Platform-specific tests gate the @import behind a comptime os check so
// the host that cannot run them never analyzes their platform-only code.

test "gui:cmdline_window" {
    try requirePrereqs();
    try @import("scenarios/common/cmdline_window.zig").run(testing.allocator);
}

test "gui:external_window" {
    try requirePrereqs();
    try @import("scenarios/common/external_window.zig").run(testing.allocator);
}

test "gui:window_frame_stability" {
    // macOS only: the Windows frontend does not persist the main window
    // frame across launches, so the 44705f8 regression cannot occur there.
    if (comptime builtin.os.tag == .macos) {
        try requirePrereqs();
        try @import("scenarios/macos/window_frame_stability.zig").run(testing.allocator);
    } else {
        return error.SkipZigTest;
    }
}

test "gui:wheel_scroll" {
    // Windows only: synthesizes WM_MOUSEWHEEL into the real frontend wheel
    // handler (7b37537). No macOS equivalent in this driver.
    if (comptime builtin.os.tag == .windows) {
        try requirePrereqs();
        try @import("scenarios/windows/wheel_scroll.zig").run(testing.allocator);
    } else {
        return error.SkipZigTest;
    }
}

test "gui:visual_baseline" {
    // Visual scenarios run wherever the screenshot layer is implemented.
    if (comptime driver.capture.supported) {
        try requirePrereqs();
        try @import("scenarios/visual/baseline.zig").run(testing.allocator);
    } else {
        std.debug.print("[gui] skipped: screenshot capture not implemented on this host\n", .{});
        return error.SkipZigTest;
    }
}

test "gui:visual_split" {
    if (comptime driver.capture.supported) {
        try requirePrereqs();
        try @import("scenarios/visual/split.zig").run(testing.allocator);
    } else {
        return error.SkipZigTest;
    }
}

test "gui:visual_float" {
    if (comptime driver.capture.supported) {
        try requirePrereqs();
        try @import("scenarios/visual/float.zig").run(testing.allocator);
    } else {
        return error.SkipZigTest;
    }
}

test "gui:visual_float_border_continuity" {
    if (comptime driver.capture.supported) {
        try requirePrereqs();
        try @import("scenarios/visual/float_border_continuity.zig").run(testing.allocator);
    } else {
        return error.SkipZigTest;
    }
}

test "gui:visual_pmenusel_bounds" {
    if (comptime driver.capture.supported) {
        try requirePrereqs();
        try @import("scenarios/visual/pmenusel_bounds.zig").run(testing.allocator);
    } else {
        return error.SkipZigTest;
    }
}

test "gui:visual_vertical_cursor_width" {
    if (comptime driver.capture.supported) {
        try requirePrereqs();
        try @import("scenarios/visual/vertical_cursor_width.zig").run(testing.allocator);
    } else {
        return error.SkipZigTest;
    }
}

test "gui:visual_cmdline_cursor_animation" {
    if (comptime driver.capture.supported) {
        try requirePrereqs();
        try @import("scenarios/visual/cmdline_cursor_animation.zig").run(testing.allocator);
    } else {
        return error.SkipZigTest;
    }
}
