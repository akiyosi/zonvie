//! Process-wide `std.Io` provider for the Zig core.
//!
//! Zig 0.16 routes time, sleep, synchronization, process, and net through the
//! `std.Io` interface. zonvie's core is a C-ABI library with no `main(init)`
//! entry point, so we own a single process-wide `std.Io` backed by a
//! `std.Io.Threaded`. The backing implementation is constructed lazily on first
//! use (and eagerly at the real entry points via `init`).
//!
//! NOTE: on POSIX, `std.Io.Threaded.init` installs process-global SIGPIPE and
//! SIGIO handlers (replacing the host app's dispositions; never restored, since
//! the instance lives for the process lifetime). This is benign for zonvie —
//! SIGPIPE is ignored (desirable for the RPC socket/pipe writes) and zonvie
//! does not rely on SIGIO — but it is a side effect of embedding this Io, not
//! a no-op.

const std = @import("std");
const builtin = @import("builtin");

var threaded_storage: std.Io.Threaded = undefined;
var g_io: std.Io = undefined;

// 0 = uninitialized, 1 = initializing, 2 = ready.
var state: std.atomic.Value(u8) = .init(0);

/// The live process environment, as a std.process.Environ for the Threaded Io.
/// CRITICAL: std.process.spawn uses the *Io's* environ (InitOptions.environ),
/// which defaults to `.empty`. Spawning the nvim child through `io()` with an
/// empty environ leaves it with no HOME/PATH (git not found, `~/.local` becomes
/// `/.local`). zonvie's core is a C-ABI library — it never receives `envp` from
/// a Zig `main`, so capture the live environment from libc's `environ` global.
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
    // Win the right to initialize; losers spin until ready.
    if (state.cmpxchgStrong(0, 1, .acq_rel, .acquire) == null) {
        // The Threaded allocator is only used by async/concurrent paths, which
        // the time/sleep/mutex usage here never exercises, so page_allocator is
        // a safe, never-freed backing store. The environ must be the live
        // process environment so spawned children (nvim) inherit HOME/PATH.
        threaded_storage = .init(std.heap.page_allocator, .{ .environ = processEnviron() });
        g_io = threaded_storage.io();
        state.store(2, .release);
        return;
    }
    while (state.load(.acquire) != 2) std.atomic.spinLoopHint();
}

/// Eagerly initialize the shared Io. Optional — call at process entry points
/// (e.g. `zonvie_core_create`, the Windows `main`) before threads spawn so the
/// lazy path never races. Idempotent.
pub fn init() void {
    ensureInit();
}

/// The shared `std.Io`. Used for mutexes, conditions, sleep, process, and net.
pub fn io() std.Io {
    ensureInit();
    return g_io;
}

/// Wall-clock nanoseconds since the Unix epoch (`Clock.real`). This is the exact
/// behavioral equivalent of Zig 0.15's `std.time.nanoTimestamp()` and is the
/// single drop-in replacement used project-wide for that call. Returns `i128`.
pub fn nowNs() i128 {
    ensureInit();
    return std.Io.Timestamp.now(g_io, .real).nanoseconds;
}

