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

test "gui:cmdline_window" {
    try requirePrereqs();
    try @import("scenarios/cmdline_window.zig").run(testing.allocator);
}

test "gui:external_window" {
    try requirePrereqs();
    try @import("scenarios/external_window.zig").run(testing.allocator);
}

test "gui:window_frame_stability" {
    // macOS only: the Windows frontend does not persist the main window
    // frame across launches, so the 44705f8 regression cannot occur there.
    if (comptime builtin.os.tag == .macos) {
        try requirePrereqs();
        try @import("scenarios/window_frame_stability.zig").run(testing.allocator);
    } else {
        return error.SkipZigTest;
    }
}
