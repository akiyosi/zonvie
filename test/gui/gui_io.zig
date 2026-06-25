//! Local std.Io provider for the GUI test driver.
//!
//! The GUI tests are standalone test binaries that do not import the zonvie
//! core package, so they cannot reach `core.clock`. Zig 0.16 routes time and
//! sleep through std.Io, so this module owns a small process-wide Io (lazily
//! constructed) plus a std.time.Timer-compatible shim, keeping the call sites
//! in driver.zig and the scenarios almost unchanged.

const std = @import("std");
const builtin = @import("builtin");

var threaded_storage: std.Io.Threaded = undefined;
var g_io: std.Io = undefined;
var state: std.atomic.Value(u8) = .init(0);

// The Io's environ (default `.empty`) is what std.process.spawn gives a child.
// The driver spawns nvim/zonvie through this Io, so it must carry the live
// process environment (HOME/PATH) — otherwise nvim starts with an empty env.
fn processEnviron() std.process.Environ {
    switch (builtin.os.tag) {
        .windows => return .{ .block = .global },
        else => {
            const c_env = std.c.environ;
            var n: usize = 0;
            while (c_env[n] != null) : (n += 1) {}
            return .{ .block = .{ .slice = @ptrCast(c_env[0..n :null]) } };
        },
    }
}

fn ensureInit() void {
    if (state.load(.acquire) == 2) return;
    if (state.cmpxchgStrong(0, 1, .acq_rel, .acquire) == null) {
        threaded_storage = .init(std.heap.page_allocator, .{ .environ = processEnviron() });
        g_io = threaded_storage.io();
        state.store(2, .release);
        return;
    }
    while (state.load(.acquire) != 2) std.atomic.spinLoopHint();
}

pub fn io() std.Io {
    ensureInit();
    return g_io;
}

/// Sleep for the given number of nanoseconds (drop-in for std.Thread.sleep).
pub fn sleepNs(ns: u64) void {
    ensureInit();
    std.Io.sleep(g_io, .{ .nanoseconds = @intCast(ns) }, .awake) catch {};
}

/// Monotonic-elapsed timer, API-compatible with the parts of std.time.Timer
/// the GUI driver uses (`start()` + `read()` returning elapsed nanoseconds).
pub const Timer = struct {
    start_ns: i128,

    pub fn start() Timer {
        ensureInit();
        return .{ .start_ns = std.Io.Timestamp.now(g_io, .awake).nanoseconds };
    }

    pub fn read(self: Timer) u64 {
        ensureInit();
        return @intCast(std.Io.Timestamp.now(g_io, .awake).nanoseconds - self.start_ns);
    }
};
