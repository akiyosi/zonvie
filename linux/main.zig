const std = @import("std");
const clock = @import("zonvie_core").clock;
const callbacks = @import("callbacks.zig");
const App = @import("app.zig").App;
const gl_renderer = @import("renderer/gl_renderer.zig");

pub fn main(init: std.process.Init.Minimal) u8 {
    _ = init;
    clock.init();
    // Keeps the core wiring analyzed until the window (Task 8) uses it.
    std.mem.doNotOptimizeAway(callbacks.makeCallbacks());
    std.mem.doNotOptimizeAway(&App.deinit);
    std.mem.doNotOptimizeAway(&callbacks.ensureFont);
    std.mem.doNotOptimizeAway(&callbacks.queueRender);
    std.mem.doNotOptimizeAway(&gl_renderer.realize);
    std.mem.doNotOptimizeAway(&gl_renderer.render);
    std.mem.doNotOptimizeAway(&gl_renderer.unrealize);
    return 0;
}
